#!/usr/bin/env python3
import argparse
import json
import os
import pwd
import re
import sys
import tempfile
import time
from pathlib import Path

RUNTIME_SESSION_STALE_SEC = max(15, int(float(os.environ.get("SSHWS_RUNTIME_SESSION_STALE_SEC", "90") or 90)))
SSHWS_TOKEN_RE = re.compile(r"^[a-f0-9]{10}$")
SSHWS_DIAGNOSTIC_TOKEN = "diagnostic-probe"
SSHWS_DIAGNOSTIC_USER = "sshws-diagnostic"


def norm_user(v):
    s = str(v or "").strip()
    if s.endswith("@ssh"):
        s = s[:-4]
    if "@" in s:
        s = s.split("@", 1)[0]
    return s


def normalize_token(v):
    s = str(v or "").strip().lower()
    if s == SSHWS_DIAGNOSTIC_TOKEN or SSHWS_TOKEN_RE.fullmatch(s):
        return s
    return ""


def normalize_ip(v):
    s = str(v or "").strip()
    if not s:
        return ""
    if s.startswith("[") and s.endswith("]"):
        s = s[1:-1].strip()
    try:
        import ipaddress
        return str(ipaddress.ip_address(s))
    except Exception:
        return ""


def is_loopback_ip(v):
    s = normalize_ip(v)
    if not s:
        return False
    try:
        import ipaddress
        return ipaddress.ip_address(s).is_loopback
    except Exception:
        return False


def to_bool(v):
    if isinstance(v, bool):
        return v
    if isinstance(v, (int, float)):
        return bool(v)
    return str(v or "").strip().lower() in ("1", "true", "yes", "on", "y")


def to_int(v, default=0):
    try:
        if v is None:
            return default
        if isinstance(v, bool):
            return int(v)
        if isinstance(v, (int, float)):
            return int(v)
        s = str(v).strip()
        if not s:
            return default
        return int(float(s))
    except Exception:
        return default


def to_float(v, default=0.0):
    try:
        if v is None:
            return default
        if isinstance(v, bool):
            return float(int(v))
        if isinstance(v, (int, float)):
            return float(v)
        s = str(v).strip()
        if not s:
            return default
        return float(s)
    except Exception:
        return default


def write_json_atomic(path, payload, mode=0o600):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(payload, ensure_ascii=False, indent=2) + "\n"
    fd, tmp = tempfile.mkstemp(prefix=".tmp.", suffix=".json", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, str(path))
        try:
            os.chmod(str(path), int(mode))
        except Exception:
            pass
    finally:
        try:
            if os.path.exists(tmp):
                os.remove(tmp)
        except Exception:
            pass


def token_index_dir(state_root):
    return Path(state_root) / ".sshws-token-index"


def token_index_path(state_root, token):
    token_norm = normalize_token(token)
    if not token_norm:
        return None
    return token_index_dir(state_root) / f"{token_norm}.json"


def user_index_dir(session_root):
    return Path(session_root) / ".by-user"


def user_index_path(session_root, username):
    user = norm_user(username)
    if not user:
        return None
    return user_index_dir(session_root) / f"{user}.json"


def load_json_file(path):
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except Exception:
        return None
    return data if isinstance(data, dict) else None


def load_user_session_index(session_root, username):
    path = user_index_path(session_root, username)
    if path is None or not path.is_file():
        return {"username": norm_user(username), "sessions": {}}
    payload = load_json_file(path)
    if not isinstance(payload, dict):
        return {"username": norm_user(username), "sessions": {}}
    sessions = payload.get("sessions")
    if not isinstance(sessions, dict):
        sessions = {}
    return {"username": norm_user(username), "sessions": sessions}


def write_user_session_index(session_root, username, payload):
    path = user_index_path(session_root, username)
    if path is None:
        return
    payload = payload if isinstance(payload, dict) else {}
    payload["username"] = norm_user(username)
    sessions = payload.get("sessions")
    if not isinstance(sessions, dict):
        sessions = {}
    payload["sessions"] = sessions
    write_json_atomic(path, payload, 0o600)


def drop_user_session_index(session_root, username):
    path = user_index_path(session_root, username)
    if path is None:
        return
    try:
        path.unlink()
    except FileNotFoundError:
        pass


def remove_session_file(session_root, backend_local_port):
    path = session_path(session_root, backend_local_port)
    if path is None:
        return
    try:
        path.unlink()
    except FileNotFoundError:
        pass


def rebuild_token_index(state_root):
    root = Path(state_root)
    index_root = token_index_dir(state_root)
    try:
        if index_root.exists():
            for old in index_root.glob("*.json"):
                try:
                    old.unlink()
                except Exception:
                    pass
        index_root.mkdir(parents=True, exist_ok=True)
    except Exception:
        return {}
    resolved = {}
    if not root.is_dir():
        return resolved
    for path in sorted(root.glob("*.json"), key=lambda p: p.name.lower()):
        payload = load_state(path)
        token = normalize_token(payload.get("sshws_token"))
        if not token:
            continue
        user = norm_user(payload.get("username") or path.stem)
        if not user:
            continue
        resolved[token] = user
        write_json_atomic(index_root / f"{token}.json", {"username": user, "token": token}, 0o600)
    return resolved


def _runtime_payload_valid_basic(payload):
    if not isinstance(payload, dict):
        return False
    pid = to_int(payload.get("proxy_pid"), 0)
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        pass
    except Exception:
        return False
    updated_at = to_int(payload.get("updated_at"), 0)
    now = int(time.time())
    if updated_at <= 0 or now <= 0:
        return False
    return (now - updated_at) <= RUNTIME_SESSION_STALE_SEC


def _runtime_payload_valid(payload):
    return _runtime_payload_valid_basic(payload)


def runtime_session_stats(root, username, extra_client_ips=None):
    root_path = Path(root)
    user = norm_user(username)
    if not user or not root_path.is_dir():
        return 0, 0
    index = load_user_session_index(root, user)
    sessions = index.get("sessions") or {}
    if sessions:
        total = 0
        ips = set()
        fresh_sessions = {}
        for port, meta in sessions.items():
            session_file = root_path / f"{to_int(port, 0)}.json"
            payload = load_json_file(session_file)
            if not _runtime_payload_valid_basic(payload):
                continue
            if norm_user(payload.get("username")) != user:
                continue
            total += 1
            ip = normalize_ip(payload.get("client_ip"))
            if ip:
                ips.add(ip)
            fresh_sessions[str(to_int(port, 0))] = {
                "client_ip": ip,
                "updated_at": to_int(payload.get("updated_at"), 0),
            }
        if fresh_sessions != sessions:
            if fresh_sessions:
                write_user_session_index(root, user, {"username": user, "sessions": fresh_sessions})
            else:
                drop_user_session_index(root, user)
        for value in extra_client_ips or ():
            ip = normalize_ip(value)
            if ip:
                ips.add(ip)
        return total, len(ips)
    total = 0
    ips = set()
    fresh_sessions = {}
    for path in root_path.glob("*.json"):
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except Exception:
            continue
        if not _runtime_payload_valid(payload):
            continue
        if norm_user(payload.get("username")) != user:
            continue
        total += 1
        ip = normalize_ip(payload.get("client_ip"))
        if ip:
            ips.add(ip)
        fresh_sessions[str(to_int(payload.get("backend_local_port"), 0))] = {
            "client_ip": ip,
            "updated_at": to_int(payload.get("updated_at"), 0),
        }
    if fresh_sessions:
        write_user_session_index(root, user, {"username": user, "sessions": fresh_sessions})
    for value in extra_client_ips or ():
        ip = normalize_ip(value)
        if ip:
            ips.add(ip)
    return total, len(ips)


def runtime_session_entries(root, username=""):
    root_path = Path(root)
    target_user = norm_user(username)
    if not root_path.is_dir():
        return []

    def entry_from_payload(path, payload):
        if not _runtime_payload_valid_basic(payload):
            return None
        user = norm_user(payload.get("username"))
        if not user:
            return None
        if target_user and user != target_user:
            return None
        backend_local_port = to_int(payload.get("backend_local_port"), 0)
        return {
            "username": user,
            "backend_local_port": backend_local_port,
            "backend_port": str(backend_local_port or "-"),
            "proxy_pid": to_int(payload.get("proxy_pid"), 0),
            "created_at": to_int(payload.get("created_at"), 0),
            "updated_at": to_int(payload.get("updated_at"), 0),
            "client_ip": normalize_ip(payload.get("client_ip")),
            "backend_target": str(payload.get("backend_target") or "").strip(),
            "backend": str(payload.get("backend") or "").strip(),
            "transport": str(payload.get("transport") or "").strip(),
            "source": str(payload.get("source") or "").strip(),
            "session_file": path.name,
        }

    def refresh_index(entries):
        if target_user:
            user_entries = [item for item in entries if item.get("username") == target_user]
            if user_entries:
                sessions = {
                    str(to_int(item.get("backend_local_port"), 0)): {
                        "client_ip": item.get("client_ip") or "",
                        "updated_at": to_int(item.get("updated_at"), 0),
                    }
                    for item in user_entries
                    if to_int(item.get("backend_local_port"), 0) > 0
                }
                write_user_session_index(root, target_user, {"username": target_user, "sessions": sessions})
            else:
                drop_user_session_index(root, target_user)
            return

        per_user = {}
        for item in entries:
            user = norm_user(item.get("username"))
            if not user:
                continue
            sessions = per_user.setdefault(user, {})
            port = to_int(item.get("backend_local_port"), 0)
            if port <= 0:
                continue
            sessions[str(port)] = {
                "client_ip": item.get("client_ip") or "",
                "updated_at": to_int(item.get("updated_at"), 0),
            }
        for user, sessions in per_user.items():
            write_user_session_index(root, user, {"username": user, "sessions": sessions})

    if target_user:
        index = load_user_session_index(root, target_user)
        sessions = index.get("sessions") or {}
        if sessions:
            entries = []
            for port in sorted(sessions.keys(), key=lambda value: (to_int(value, 0), str(value))):
                session_file = root_path / f"{to_int(port, 0)}.json"
                payload = load_json_file(session_file)
                entry = entry_from_payload(session_file, payload)
                if entry is not None:
                    entries.append(entry)
            refresh_index(entries)
            entries.sort(key=lambda item: (-to_int(item.get("updated_at"), 0), item.get("username") or "", to_int(item.get("backend_local_port"), 0)))
            return entries

    entries = []
    for path in sorted(root_path.glob("*.json"), key=lambda p: p.name.lower()):
        payload = load_json_file(path)
        entry = entry_from_payload(path, payload)
        if entry is not None:
            entries.append(entry)
    refresh_index(entries)
    entries.sort(key=lambda item: (-to_int(item.get("updated_at"), 0), item.get("username") or "", to_int(item.get("backend_local_port"), 0)))
    return entries


def extract_token_from_path(path, expected_prefix):
    raw_path = str(path or "/").split("?", 1)[0].split("#", 1)[0] or "/"
    prefix = str(expected_prefix or "/").split("?", 1)[0].split("#", 1)[0] or "/"
    prefix = prefix.rstrip("/") or "/"
    if prefix == "/":
        parts = [part for part in raw_path.split("/") if part]
        if not parts or len(parts) > 2:
            return ""
        if len(parts) == 2 and parts[0] in {
            "vless-ws", "vmess-ws", "trojan-ws",
            "vless-hup", "vmess-hup", "trojan-hup",
            "vless-xhttp", "vmess-xhttp", "trojan-xhttp",
            "vless-grpc", "vmess-grpc", "trojan-grpc",
        }:
            return ""
        return normalize_token(parts[-1])
    wanted = prefix + "/"
    if not raw_path.startswith(wanted):
        return ""
    suffix = raw_path[len(wanted):].strip("/")
    if not suffix or "/" in suffix:
        return ""
    return normalize_token(suffix)


def load_state(path):
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except Exception:
        return {}
    return data if isinstance(data, dict) else {}


def resolve_state_path(state_root, username):
    user = norm_user(username)
    primary = Path(state_root) / f"{user}@ssh.json"
    if primary.is_file():
        return primary
    legacy = Path(state_root) / f"{user}.json"
    if legacy.is_file():
        return legacy
    return primary


def resolve_token(state_root, token):
    token_norm = normalize_token(token)
    if not token_norm:
        return ""
    idx_path = token_index_path(state_root, token_norm)
    if idx_path is not None and idx_path.is_file():
        payload = load_json_file(idx_path)
        user = norm_user((payload or {}).get("username"))
        if user:
            state_path = resolve_state_path(state_root, user)
            state_payload = load_state(state_path)
            if normalize_token(state_payload.get("sshws_token")) == token_norm:
                return user
    resolved = rebuild_token_index(state_root)
    return norm_user(resolved.get(token_norm))


def parse_policy(username, payload):
    st = payload.get("status")
    if not isinstance(st, dict):
        st = {}
    speed_enabled = to_bool(st.get("speed_limit_enabled"))
    speed_down = max(0.0, to_float(st.get("speed_down_mbit"), 0.0))
    speed_up = max(0.0, to_float(st.get("speed_up_mbit"), 0.0))
    if not speed_enabled:
        speed_down = 0.0
        speed_up = 0.0
    else:
        speed_enabled = bool(speed_down > 0 or speed_up > 0)
    lock_reason = str(st.get("lock_reason") or "").strip().lower()
    blocked = (
        to_bool(st.get("manual_block")) or
        to_bool(st.get("quota_exhausted")) or
        to_bool(st.get("ip_limit_locked")) or
        to_bool(st.get("account_locked")) or
        lock_reason in ("manual", "quota", "ip_limit")
    )
    return {
        "username": username,
        "blocked": blocked,
        "speed_enabled": speed_enabled,
        "speed_down_bps": int(speed_down * 125000.0) if speed_enabled else 0,
        "speed_up_bps": int(speed_up * 125000.0) if speed_enabled else 0,
    }


def cmd_admission(args):
    token = extract_token_from_path(args.path, args.expected_prefix)
    if not token:
        return {"allowed": False, "reason": "Unauthorized", "username": "", "policy": None}
    if token == SSHWS_DIAGNOSTIC_TOKEN:
        if not is_loopback_ip(args.client_ip):
            return {"allowed": False, "reason": "Unauthorized", "username": "", "policy": None}
        return {
            "allowed": True,
            "reason": "",
            "username": SSHWS_DIAGNOSTIC_USER,
            "policy": {
                "username": SSHWS_DIAGNOSTIC_USER,
                "blocked": False,
                "speed_enabled": False,
                "speed_down_bps": 0,
                "speed_up_bps": 0,
            },
        }
    username = resolve_token(args.state_root, token)
    if not username:
        return {"allowed": False, "reason": "Forbidden", "username": "", "policy": None}
    state_path = resolve_state_path(args.state_root, username)
    if not state_path.is_file():
        return {"allowed": False, "reason": "Forbidden", "username": username, "policy": None}
    payload = load_state(state_path)
    policy = parse_policy(username, payload)
    st = payload.get("status")
    if not isinstance(st, dict):
        st = {}
    lock_reason = str(st.get("lock_reason") or "").strip().lower()
    if to_bool(st.get("manual_block")) or lock_reason == "manual":
        return {"allowed": False, "reason": "Account Locked", "username": username, "policy": policy}
    quota_limit = max(0, to_int(payload.get("quota_limit"), 0))
    quota_used = max(0, to_int(payload.get("quota_used"), 0))
    if to_bool(st.get("quota_exhausted")) or lock_reason == "quota" or (quota_limit > 0 and quota_used >= quota_limit):
        return {"allowed": False, "reason": "Account Locked", "username": username, "policy": policy}
    if to_bool(st.get("account_locked")) and lock_reason not in ("", "ip_limit"):
        return {"allowed": False, "reason": "Account Locked", "username": username, "policy": policy}
    ip_enabled = to_bool(st.get("ip_limit_enabled"))
    ip_limit = max(0, to_int(st.get("ip_limit"), 0))
    if ip_enabled and ip_limit > 0:
        extras = [v for v in (args.extra_client_ips or "").split(",") if v.strip()]
        if normalize_ip(args.client_ip):
            extras.append(args.client_ip)
        active_total, active_ip_count = runtime_session_stats(args.session_root, username, extras)
        prospective_total = int(active_total) + 1 + max(0, int(args.extra_total))
        prospective_metric = max(prospective_total, int(active_ip_count or 0))
        if prospective_metric > ip_limit:
            return {"allowed": False, "reason": "IP/Login Limit Reached", "username": username, "policy": policy}
    return {"allowed": True, "reason": "", "username": username, "policy": policy}


def cmd_policy(args):
    state_path = resolve_state_path(args.state_root, args.username)
    if not state_path.is_file():
        return {"policy": None}
    payload = load_state(state_path)
    return {"policy": parse_policy(norm_user(args.username), payload)}


def session_path(session_root, backend_local_port):
    port = to_int(backend_local_port, 0)
    if port <= 0:
        return None
    return Path(session_root) / f"{port}.json"


def cmd_session_write(args):
    path = session_path(args.session_root, args.backend_local_port)
    if path is None:
        return {"ok": False}
    payload = {
        "backend_local_port": to_int(args.backend_local_port, 0),
        "backend": args.backend or "dropbear",
        "backend_target": args.backend_target or "",
        "transport": args.transport or "ssh-ws",
        "source": args.source or "sshws-proxy",
        "proxy_pid": to_int(args.proxy_pid or os.getpid(), os.getpid()),
        "created_at": to_int(args.created_at or int(time.time()), int(time.time())),
        "updated_at": int(time.time()),
    }
    user = norm_user(args.username)
    if user:
        payload["username"] = user
    ip = normalize_ip(args.client_ip)
    if ip:
        payload["client_ip"] = ip
    write_json_atomic(path, payload, 0o600)
    try:
        if user:
            index = load_user_session_index(args.session_root, user)
            sessions = index.get("sessions") or {}
            sessions[str(payload["backend_local_port"])] = {
                "client_ip": ip,
                "updated_at": payload["updated_at"],
            }
            index["sessions"] = sessions
            write_user_session_index(args.session_root, user, index)
    except Exception:
        remove_session_file(args.session_root, payload["backend_local_port"])
        raise
    return {"ok": True}


def cmd_session_touch(args):
    path = session_path(args.session_root, args.backend_local_port)
    if path is None or not path.exists():
        return {"ok": False}
    payload = load_state(path)
    if not isinstance(payload, dict):
        payload = {}
    payload["updated_at"] = int(time.time())
    write_json_atomic(path, payload, 0o600)
    user = norm_user(payload.get("username"))
    if user:
        index = load_user_session_index(args.session_root, user)
        sessions = index.get("sessions") or {}
        key = str(to_int(args.backend_local_port, 0))
        entry = sessions.get(key)
        if not isinstance(entry, dict):
            entry = {}
        entry["client_ip"] = normalize_ip(payload.get("client_ip"))
        entry["updated_at"] = payload["updated_at"]
        sessions[key] = entry
        index["sessions"] = sessions
        write_user_session_index(args.session_root, user, index)
    return {"ok": True}


def cmd_session_clear(args):
    path = session_path(args.session_root, args.backend_local_port)
    if path is None:
        return {"ok": False}
    payload = load_json_file(path)
    try:
        path.unlink()
    except FileNotFoundError:
        pass
    user = norm_user((payload or {}).get("username"))
    if user:
        index = load_user_session_index(args.session_root, user)
        sessions = index.get("sessions") or {}
        sessions.pop(str(to_int(args.backend_local_port, 0)), None)
        if sessions:
            index["sessions"] = sessions
            write_user_session_index(args.session_root, user, index)
        else:
            drop_user_session_index(args.session_root, user)
    return {"ok": True}


def cmd_session_stats(args):
    user = norm_user(args.username)
    entries = runtime_session_entries(args.session_root, user)
    ips = set()
    for item in entries:
        ip = normalize_ip(item.get("client_ip"))
        if ip:
            ips.add(ip)
    return {
        "ok": True,
        "username": user,
        "total": len(entries),
        "distinct_ips": len(ips),
    }


def cmd_session_list(args):
    user = norm_user(getattr(args, "username", ""))
    entries = runtime_session_entries(args.session_root, user)
    counts = {}
    ips = set()
    for item in entries:
        name = norm_user(item.get("username"))
        if name:
            counts[name] = int(counts.get(name, 0)) + 1
        ip = normalize_ip(item.get("client_ip"))
        if ip:
            ips.add(ip)
    return {
        "ok": True,
        "username": user,
        "total": len(entries),
        "distinct_ips": len(ips),
        "counts": counts,
        "sessions": entries,
    }


def main():
    parser = argparse.ArgumentParser(description="SSH WS control plane helper")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("admission")
    p.add_argument("--path", required=True)
    p.add_argument("--expected-prefix", default="/")
    p.add_argument("--state-root", required=True)
    p.add_argument("--session-root", required=True)
    p.add_argument("--client-ip", default="")
    p.add_argument("--extra-total", type=int, default=0)
    p.add_argument("--extra-client-ips", default="")

    p = sub.add_parser("policy")
    p.add_argument("--username", required=True)
    p.add_argument("--state-root", required=True)

    p = sub.add_parser("session-write")
    p.add_argument("--session-root", required=True)
    p.add_argument("--backend-local-port", required=True)
    p.add_argument("--backend-target", default="")
    p.add_argument("--username", default="")
    p.add_argument("--client-ip", default="")
    p.add_argument("--backend", default="dropbear")
    p.add_argument("--transport", default="ssh-ws")
    p.add_argument("--source", default="sshws-proxy")
    p.add_argument("--proxy-pid", default="")
    p.add_argument("--created-at", default="")

    p = sub.add_parser("session-touch")
    p.add_argument("--session-root", required=True)
    p.add_argument("--backend-local-port", required=True)

    p = sub.add_parser("session-clear")
    p.add_argument("--session-root", required=True)
    p.add_argument("--backend-local-port", required=True)

    p = sub.add_parser("session-stats")
    p.add_argument("--session-root", required=True)
    p.add_argument("--username", required=True)

    p = sub.add_parser("session-list")
    p.add_argument("--session-root", required=True)
    p.add_argument("--username", default="")

    args = parser.parse_args()
    if args.command == "admission":
        out = cmd_admission(args)
    elif args.command == "policy":
        out = cmd_policy(args)
    elif args.command == "session-write":
        out = cmd_session_write(args)
    elif args.command == "session-touch":
        out = cmd_session_touch(args)
    elif args.command == "session-clear":
        out = cmd_session_clear(args)
    elif args.command == "session-stats":
        out = cmd_session_stats(args)
    elif args.command == "session-list":
        out = cmd_session_list(args)
    else:
        raise SystemExit(2)
    print(json.dumps(out, ensure_ascii=False))


if __name__ == "__main__":
    main()
