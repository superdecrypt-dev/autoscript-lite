#!/usr/bin/env python3
import argparse
import fcntl
import json
import os
import re
import select
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

PROTO_DIRS = ("vless", "vmess", "trojan")
XRAY_ACCESS_LOG = "/var/log/xray/access.log"
QUOTA_ROOT = "/opt/quota"
SESSION_ROOT = "/run/autoscript/xray-sessions"
EDGE_MUX_SERVICE = "edge-mux"
EDGE_ROUTE_CACHE_SECONDS = 3
EDGE_ROUTE_MATCH_WINDOW_SECONDS = 5
EDGE_ROUTE_FETCH_LOOKBACK_SECONDS = 900
XRAY_PRELOAD_MAX_BYTES = 16 * 1024 * 1024
XRAY_PRELOAD_MAX_LINES = 50000
LOOPBACK_IPS = {"127.0.0.1", "::1", "0:0:0:0:0:0:0:1"}

EMAIL_RE = re.compile(r"(?:email|user)\s*[:=]\s*([A-Za-z0-9._%+-]{1,128}@[A-Za-z0-9._-]{1,128})")
IP_RE = re.compile(
    r"\bfrom\s+"
    r"(?:"
    r"\[([0-9a-fA-F:]{2,39})\]:\d{1,5}"
    r"|(\d{1,3}(?:\.\d{1,3}){3}):\d{1,5}"
    r"|([0-9a-fA-F]{1,4}(?::[0-9a-fA-F]{0,4}){2,7}):\d{1,5}"
    r")"
)
ROUTE_RE = re.compile(r"\[(?:[^\]@]+@)?([A-Za-z0-9-]+)\s*->")
EDGE_ROUTE_RE = re.compile(
    r"(?P<ts>\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}).*?"
    r"\broute=(?P<route>[a-z0-9-]+)\b.*?"
    r"\bremote=(?P<remote>\S+)"
)

EDGE_ROUTE_CACHE = {"expires_at": 0.0, "events": []}


def now_iso():
    return datetime.now().strftime("%Y-%m-%d %H:%M")


def parse_access_timestamp(line):
    try:
        prefix = str(line or "").strip()[:19]
        return datetime.strptime(prefix, "%Y/%m/%d %H:%M:%S").timestamp()
    except Exception:
        return None


def extract_route_from_line(line):
    match = ROUTE_RE.search(str(line or ""))
    if not match:
        return ""
    return str(match.group(1) or "").strip().lower()


def extract_ip_from_match(match):
    if match is None:
        return None
    return match.group(1) or match.group(2) or match.group(3)


def extract_peer_identity_from_match(match):
    if match is None:
        return None
    ip_value = extract_ip_from_match(match)
    if not ip_value:
        return None
    ip_lower = str(ip_value).strip().lower()
    if ip_lower not in LOOPBACK_IPS:
        return ip_value
    raw = match.group(0) or ""
    if not raw:
        return ip_value
    endpoint = raw.split(None, 1)[1].strip() if " " in raw else raw.strip()
    return endpoint or ip_value


def is_loopback_ip(value):
    return str(value or "").strip().lower() in LOOPBACK_IPS


def parse_remote_ip(raw):
    value = str(raw or "").strip()
    if not value:
        return ""
    if value.startswith("[") and "]:" in value:
        return value[1:].split("]:", 1)[0].strip()
    if ":" in value:
        head, tail = value.rsplit(":", 1)
        if tail.isdigit():
            return head.strip()
    return value


def read_tail_lines(path, max_bytes=XRAY_PRELOAD_MAX_BYTES, max_lines=XRAY_PRELOAD_MAX_LINES):
    if not os.path.isfile(path):
        return []
    try:
        with open(path, "rb") as handle:
            handle.seek(0, os.SEEK_END)
            size = handle.tell()
            start = max(0, size - max_bytes)
            handle.seek(start)
            payload = handle.read()
    except Exception:
        return []
    try:
        lines = payload.decode("utf-8", errors="ignore").splitlines()
    except Exception:
        return []
    if start > 0 and lines:
        lines = lines[1:]
    if max_lines > 0:
        return lines[-max_lines:]
    return lines


def edge_mux_recent_routes(service_name, now_ts=None):
    if not service_name:
        return []
    if now_ts is None:
        now_ts = time.time()
    cached_exp = float(EDGE_ROUTE_CACHE.get("expires_at") or 0.0)
    cached_events = EDGE_ROUTE_CACHE.get("events")
    if cached_exp > now_ts and isinstance(cached_events, list):
        return cached_events
    since_ts = now_ts - EDGE_ROUTE_FETCH_LOOKBACK_SECONDS
    since_text = datetime.fromtimestamp(since_ts).strftime("%Y-%m-%d %H:%M:%S")
    try:
        proc = subprocess.run(
            ["journalctl", "-u", service_name, "--since", since_text, "--no-pager", "-o", "cat"],
            capture_output=True,
            text=True,
            timeout=8,
            check=False,
        )
        output = ((proc.stdout or "") + ("\n" + proc.stderr if proc.stderr else "")).strip()
        if proc.returncode != 0:
            output = ""
    except Exception:
        output = ""
    events = []
    if output:
        for line in output.splitlines():
            match = EDGE_ROUTE_RE.search(line)
            if not match:
                continue
            route_name = str(match.group("route") or "").strip().lower()
            if not route_name:
                continue
            remote_ip = parse_remote_ip(match.group("remote"))
            if not remote_ip or is_loopback_ip(remote_ip):
                continue
            try:
                event_ts = datetime.strptime(str(match.group("ts")), "%Y/%m/%d %H:%M:%S").timestamp()
            except Exception:
                continue
            events.append({"ts": event_ts, "route": route_name, "ip": remote_ip})
    EDGE_ROUTE_CACHE["expires_at"] = now_ts + EDGE_ROUTE_CACHE_SECONDS
    EDGE_ROUTE_CACHE["events"] = events
    return events


def resolve_public_ip_from_edge(service_name, route_name, line_ts, fallback_identity):
    route_n = str(route_name or "").strip().lower()
    if not route_n or line_ts is None:
        return fallback_identity
    candidates = []
    for item in edge_mux_recent_routes(service_name, line_ts):
        if str(item.get("route") or "").strip().lower() != route_n:
            continue
        event_ts = float(item.get("ts") or 0.0)
        delta = abs(event_ts - line_ts)
        if delta > EDGE_ROUTE_MATCH_WINDOW_SECONDS:
            continue
        ip_value = str(item.get("ip") or "").strip()
        if not ip_value:
            continue
        candidates.append((delta, event_ts, ip_value))
    if not candidates:
        return fallback_identity
    unique_ips = {ip_value for _, _, ip_value in candidates}
    if len(unique_ips) != 1:
        return fallback_identity
    candidates.sort(key=lambda item: (item[0], -item[1]))
    _, _, ip_value = candidates[0]
    return ip_value or fallback_identity


def quota_paths(quota_root, username):
    paths = []
    if "@" in username:
        _, email_proto = username.split("@", 1)
        if email_proto in PROTO_DIRS:
            path = os.path.join(quota_root, email_proto, f"{username}.json")
            if os.path.isfile(path):
                paths.append(path)
        if not paths:
            for proto in PROTO_DIRS:
                if proto == email_proto:
                    continue
                path = os.path.join(quota_root, proto, f"{username}.json")
                if os.path.isfile(path) and path not in paths:
                    paths.append(path)
    else:
        for proto in PROTO_DIRS:
            for path in (
                os.path.join(quota_root, proto, f"{username}@{proto}.json"),
                os.path.join(quota_root, proto, f"{username}.json"),
            ):
                if os.path.isfile(path) and path not in paths:
                    paths.append(path)
    return paths


def load_json(path):
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def save_json_atomic(path, data):
    import tempfile

    directory = os.path.dirname(path) or "."
    os.makedirs(directory, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".tmp.", suffix=".json", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(data, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
    except Exception:
        try:
            if os.path.exists(tmp):
                os.remove(tmp)
        except Exception:
            pass
        raise


def with_status_lock(path):
    lock_path = f"{path}.lock"
    lock_file = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
    fcntl.flock(lock_file, fcntl.LOCK_EX)
    return lock_file


def release_status_lock(fd):
    try:
        fcntl.flock(fd, fcntl.LOCK_UN)
    finally:
        os.close(fd)


def update_quota_status(quota_root, username, total, peers, updated_at):
    for path in quota_paths(quota_root, username):
        lock_fd = None
        try:
            lock_fd = with_status_lock(path)
            meta = load_json(path)
            if not isinstance(meta, dict):
                continue
            status = meta.get("status") if isinstance(meta.get("status"), dict) else {}
            changed = False
            if int(status.get("active_sessions_total") or 0) != int(total):
                status["active_sessions_total"] = int(total)
                changed = True
            limited_peers = [str(item).strip() for item in peers if str(item).strip()][:16]
            if status.get("active_session_peers") != limited_peers:
                status["active_session_peers"] = limited_peers
                changed = True
            if status.get("active_sessions_updated_at") != updated_at:
                status["active_sessions_updated_at"] = updated_at
                changed = True
            if not changed:
                continue
            meta["status"] = status
            save_json_atomic(path, meta)
        except Exception:
            continue
        finally:
            if lock_fd is not None:
                release_status_lock(lock_fd)


def session_file_path(session_root, username, protocol):
    return os.path.join(session_root, protocol, f"{username}.json")


def summary_file_path(session_root):
    return os.path.join(session_root, "summary.json")


class SessionTracker:
    def __init__(self, quota_root, session_root, window_seconds):
        self.quota_root = quota_root
        self.session_root = session_root
        self.window_seconds = max(30, int(window_seconds))
        self.sessions = {}

    def load_existing(self):
        root = Path(self.session_root)
        if not root.is_dir():
            return
        for path in root.glob("*/*.json"):
            try:
                payload = load_json(str(path))
            except Exception:
                continue
            if not isinstance(payload, dict):
                continue
            username = str(payload.get("username") or "").strip()
            protocol = str(payload.get("protocol") or "").strip().lower()
            if not username or protocol not in PROTO_DIRS:
                continue
            sessions = payload.get("sessions")
            if not isinstance(sessions, list):
                continue
            user_state = self.sessions.setdefault(username, {"protocol": protocol, "sessions": {}})
            for item in sessions:
                if not isinstance(item, dict):
                    continue
                identity = str(item.get("peer_identity") or item.get("public_ip") or "").strip()
                if not identity:
                    continue
                try:
                    first_seen = float(item.get("first_seen_unix") or 0.0)
                    last_seen = float(item.get("last_seen_unix") or 0.0)
                except Exception:
                    continue
                if last_seen <= 0:
                    continue
                user_state["sessions"][identity] = {
                    "peer_identity": identity,
                    "public_ip": str(item.get("public_ip") or "").strip(),
                    "route": str(item.get("route") or "").strip().lower(),
                    "first_seen": first_seen or last_seen,
                    "last_seen": last_seen,
                }

    def record(self, username, peer_identity, public_ip, route_name, seen_ts):
        if not username or not peer_identity:
            return
        protocol = username.split("@", 1)[1].strip().lower() if "@" in username else ""
        if protocol not in PROTO_DIRS:
            return
        user_state = self.sessions.setdefault(username, {"protocol": protocol, "sessions": {}})
        session = user_state["sessions"].get(peer_identity)
        if session is None:
            session = {
                "peer_identity": peer_identity,
                "public_ip": str(public_ip or "").strip(),
                "route": str(route_name or "").strip().lower(),
                "first_seen": float(seen_ts),
                "last_seen": float(seen_ts),
            }
            user_state["sessions"][peer_identity] = session
        else:
            session["last_seen"] = float(seen_ts)
            if public_ip:
                session["public_ip"] = str(public_ip).strip()
            if route_name:
                session["route"] = str(route_name).strip().lower()

    def prune(self, now_ts=None):
        if now_ts is None:
            now_ts = time.time()
        cutoff = float(now_ts) - float(self.window_seconds)
        active_users = []
        total_sessions = 0
        for username in list(self.sessions.keys()):
            user_state = self.sessions.get(username) or {}
            sessions = user_state.get("sessions") or {}
            for identity in list(sessions.keys()):
                if float((sessions.get(identity) or {}).get("last_seen") or 0.0) < cutoff:
                    sessions.pop(identity, None)
            if not sessions:
                protocol = str(user_state.get("protocol") or "").strip().lower()
                self.remove_user(username, protocol)
                continue
            active_users.append(username)
            total_sessions += len(sessions)
            self.persist_user(username, user_state, now_ts)
        self.persist_summary(active_users, total_sessions, now_ts)

    def remove_user(self, username, protocol):
        self.sessions.pop(username, None)
        update_quota_status(self.quota_root, username, 0, [], now_iso())
        path = session_file_path(self.session_root, username, protocol) if protocol in PROTO_DIRS else ""
        if path and os.path.exists(path):
            try:
                os.remove(path)
            except Exception:
                pass

    def persist_user(self, username, user_state, now_ts):
        protocol = str(user_state.get("protocol") or "").strip().lower()
        sessions = list((user_state.get("sessions") or {}).values())
        sessions.sort(key=lambda item: (-float(item.get("last_seen") or 0.0), str(item.get("peer_identity") or "")))
        payload = {
            "username": username,
            "protocol": protocol,
            "active_sessions_total": len(sessions),
            "window_seconds": int(self.window_seconds),
            "updated_at": now_iso(),
            "updated_at_unix": int(now_ts),
            "sessions": [
                {
                    "peer_identity": str(item.get("peer_identity") or "").strip(),
                    "public_ip": str(item.get("public_ip") or "").strip(),
                    "route": str(item.get("route") or "").strip().lower(),
                    "first_seen_unix": int(float(item.get("first_seen") or 0.0)),
                    "last_seen_unix": int(float(item.get("last_seen") or 0.0)),
                    "first_seen": datetime.fromtimestamp(float(item.get("first_seen") or 0.0)).strftime("%Y-%m-%d %H:%M:%S"),
                    "last_seen": datetime.fromtimestamp(float(item.get("last_seen") or 0.0)).strftime("%Y-%m-%d %H:%M:%S"),
                }
                for item in sessions
            ],
        }
        path = session_file_path(self.session_root, username, protocol)
        save_json_atomic(path, payload)
        peers = [str(item.get("public_ip") or item.get("peer_identity") or "").strip() for item in sessions]
        update_quota_status(self.quota_root, username, len(sessions), peers, payload["updated_at"])

    def persist_summary(self, active_users, total_sessions, now_ts):
        payload = {
            "active_users_total": len(active_users),
            "active_sessions_total": int(total_sessions),
            "window_seconds": int(self.window_seconds),
            "updated_at": now_iso(),
            "updated_at_unix": int(now_ts),
            "users": sorted(active_users),
        }
        save_json_atomic(summary_file_path(self.session_root), payload)


def parse_line(line, edge_mux_service):
    email_match = EMAIL_RE.search(line)
    ip_match = IP_RE.search(line)
    if not email_match or not ip_match:
        return None
    username = str(email_match.group(1) or "").strip().lower()
    if not username or "@" not in username:
        return None
    raw_ip = extract_ip_from_match(ip_match)
    peer_identity = extract_peer_identity_from_match(ip_match)
    route_name = extract_route_from_line(line)
    line_ts = parse_access_timestamp(line) or time.time()
    if raw_ip and is_loopback_ip(raw_ip):
        resolved_ip = resolve_public_ip_from_edge(edge_mux_service, route_name, line_ts, "")
        if resolved_ip and not is_loopback_ip(resolved_ip):
            return username, resolved_ip, resolved_ip, route_name, line_ts
        return username, peer_identity, "", route_name, line_ts
    return username, peer_identity, raw_ip or "", route_name, line_ts


def tail_follow(path):
    process = subprocess.Popen(
        ["tail", "-n", "0", "-F", path],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        bufsize=1,
    )
    try:
        while True:
            if process.stdout is None:
                break
            ready, _, _ = select.select([process.stdout], [], [], 1.0)
            if ready:
                line = process.stdout.readline()
                if line:
                    yield line.rstrip("\n"), time.time()
                    continue
            if process.poll() is not None:
                break
            yield None, time.time()
    finally:
        try:
            process.terminate()
        except Exception:
            pass


def run_once(args):
    tracker = SessionTracker(args.quota_root, args.session_root, args.window_seconds)
    tracker.load_existing()
    cutoff = time.time() - float(args.window_seconds)
    for line in read_tail_lines(args.access_log):
        event = parse_line(line, args.edge_mux_service)
        if not event:
            continue
        username, peer_identity, public_ip, route_name, seen_ts = event
        if seen_ts < cutoff:
            continue
        tracker.record(username, peer_identity, public_ip, route_name, seen_ts)
    tracker.prune(time.time())
    return 0


def watch(args):
    tracker = SessionTracker(args.quota_root, args.session_root, args.window_seconds)
    tracker.load_existing()
    cutoff = time.time() - float(args.window_seconds)
    for line in read_tail_lines(args.access_log):
        event = parse_line(line, args.edge_mux_service)
        if not event:
            continue
        username, peer_identity, public_ip, route_name, seen_ts = event
        if seen_ts < cutoff:
            continue
        tracker.record(username, peer_identity, public_ip, route_name, seen_ts)
    tracker.prune(time.time())

    if args.once:
        return 0

    next_prune = time.time() + max(5, int(args.prune_interval))
    for line, now_ts in tail_follow(args.access_log):
        if line:
            event = parse_line(line, args.edge_mux_service)
            if event:
                username, peer_identity, public_ip, route_name, seen_ts = event
                tracker.record(username, peer_identity, public_ip, route_name, seen_ts)
                tracker.prune(now_ts)
                next_prune = now_ts + max(5, int(args.prune_interval))
                continue
        if now_ts >= next_prune:
            tracker.prune(now_ts)
            next_prune = now_ts + max(5, int(args.prune_interval))
    return 0


def main():
    parser = argparse.ArgumentParser(prog="xray-session")
    sub = parser.add_subparsers(dest="cmd", required=True)

    watch_parser = sub.add_parser("watch")
    watch_parser.add_argument("--access-log", default=XRAY_ACCESS_LOG)
    watch_parser.add_argument("--quota-root", default=QUOTA_ROOT)
    watch_parser.add_argument("--session-root", default=SESSION_ROOT)
    watch_parser.add_argument("--edge-mux-service", default=EDGE_MUX_SERVICE)
    watch_parser.add_argument("--window-seconds", type=int, default=300)
    watch_parser.add_argument("--prune-interval", type=int, default=15)
    watch_parser.add_argument("--once", action="store_true")

    args = parser.parse_args()
    if args.cmd == "watch":
        return watch(args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
