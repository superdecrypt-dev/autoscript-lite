from __future__ import annotations

import ipaddress
import json
import re
import subprocess
import threading
import time
from datetime import date, datetime
from pathlib import Path
from typing import Any

QUOTA_ROOT = Path("/opt/quota")
ACCOUNT_INFO_ROOT = Path("/opt/account")
SSHWS_RUNTIME_SESSION_DIR = Path("/run/autoscript/sshws-sessions")
SSHWS_CONTROL_BIN = Path("/usr/local/bin/sshws-control")
XRAY_ACCESS_LOG = Path("/var/log/xray/access.log")
NGINX_CONF = Path("/etc/nginx/conf.d/xray.conf")

XRAY_PROTOCOLS = ("vless", "vmess", "trojan")
SSH_PROTOCOL = "ssh"
OPENVPN_POLICY_PROTOCOL = "openvpn"
QAC_PROTOCOLS = XRAY_PROTOCOLS + (SSH_PROTOCOL, OPENVPN_POLICY_PROTOCOL)

PORTAL_TOKEN_RE = re.compile(r"^[A-Za-z0-9_-]{10,64}$")
XRAY_EMAIL_RE = re.compile(r"(?:email|user)\s*[:=]\s*([A-Za-z0-9._%+-]{1,128}@[A-Za-z0-9._-]{1,128})")
XRAY_IP_RE = re.compile(
    r"\bfrom\s+"
    r"(?:"
    r"\[([0-9a-fA-F:]{2,39})\]:\d{1,5}"
    r"|(\d{1,3}(?:\.\d{1,3}){3}):\d{1,5}"
    r"|([0-9a-fA-F]{1,4}(?::[0-9a-fA-F]{0,4}){2,7}):\d{1,5}"
    r")"
)
XRAY_ACCESS_TS_RE = re.compile(r"^(\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2})")
XRAY_ROUTE_RE = re.compile(r"\[(?:[^\]@]+@)?([A-Za-z0-9-]+)\s*->")
EDGE_MUX_ROUTE_RE = re.compile(
    r"(?P<ts>\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}).*?"
    r"\broute=(?P<route>[a-z0-9-]+)\b.*?"
    r"\bremote=(?P<remote>\S+)"
)
EXIT_CODE_RE = re.compile(r"^\[exit (\d+)\]$")

XRAY_ACTIVE_FRESHNESS_SECONDS = 600
XRAY_ACCESS_TAIL_MAX_BYTES = 1024 * 1024
XRAY_ACCESS_TAIL_MAX_LINES = 6000
PORTAL_LOOKUP_CACHE_SECONDS = 15
PORTAL_INDEX_CACHE_SECONDS = 30
PORTAL_NEGATIVE_CACHE_SECONDS = 10
XRAY_LAST_SEEN_CACHE_SECONDS = 5
EDGE_MUX_ROUTE_CACHE_SECONDS = 5
EDGE_MUX_ROUTE_MATCH_WINDOW_SECONDS = 5
ACCOUNT_INFO_CACHE_VERSION = 1
XRAY_IMPORT_SECTION_RE = re.compile(r"^===\s+LINKS IMPORT\s+===$")
XRAY_IMPORT_LABEL_RE = re.compile(r"^\s{2,}(.+?)\s*:\s*$")
_PORTAL_LOOKUP_CACHE_LOCK = threading.Lock()
_PORTAL_LOOKUP_CACHE: dict[str, dict[str, object]] = {}
_PORTAL_INDEX_CACHE_LOCK = threading.Lock()
_PORTAL_INDEX_CACHE: dict[str, object] = {
    "expires_at": 0.0,
    "tokens": {},
    "negative": {},
}
_XRAY_LAST_SEEN_CACHE_LOCK = threading.Lock()
_XRAY_LAST_SEEN_CACHE: dict[str, dict[str, object]] = {}
_EDGE_MUX_ROUTE_CACHE_LOCK = threading.Lock()
_EDGE_MUX_ROUTE_CACHE: dict[str, object] = {"expires_at": 0.0, "events": []}

ACCESS_DETAIL_FIELDS: dict[str, tuple[str, ...]] = {
    "vless": (
        "Vless WS",
        "Vless HUP",
        "Vless XHTTP",
        "Vless gRPC",
        "Vless TCP+TLS Port",
        "Alt Port SSL/TLS",
        "Alt Port HTTP",
        "Vless Path WS",
        "Vless Path WS Alt",
        "Vless Path HUP",
        "Vless Path HUP Alt",
        "Vless Path XHTTP",
        "Vless Path XHTTP Alt",
        "Vless Path Service",
        "Vless Path Service Alt",
    ),
    "vmess": (
        "Vmess WS",
        "Vmess HUP",
        "Vmess XHTTP",
        "Vmess gRPC",
        "Alt Port SSL/TLS",
        "Alt Port HTTP",
        "Vmess Path WS",
        "Vmess Path WS Alt",
        "Vmess Path HUP",
        "Vmess Path HUP Alt",
        "Vmess Path XHTTP",
        "Vmess Path XHTTP Alt",
        "Vmess Path Service",
        "Vmess Path Service Alt",
    ),
    "trojan": (
        "Trojan WS",
        "Trojan HUP",
        "Trojan XHTTP",
        "Trojan gRPC",
        "Alt Port SSL/TLS",
        "Alt Port HTTP",
        "Trojan Path WS",
        "Trojan Path WS Alt",
        "Trojan Path HUP",
        "Trojan Path HUP Alt",
        "Trojan Path XHTTP",
        "Trojan Path XHTTP Alt",
        "Trojan Path Service",
        "Trojan Path Service Alt",
    ),
    SSH_PROTOCOL: (
        "SSH WS Port",
        "SSH Direct Port",
        "SSH SSL/TLS Port",
        "Alt Port SSL/TLS",
        "Alt Port HTTP",
        "BadVPN UDPGW",
        "SSH WS Path",
        "SSH WS Path Alt",
    ),
    OPENVPN_POLICY_PROTOCOL: (
        "OpenVPN WS Port",
        "OpenVPN TCP",
        "Alt Port SSL/TLS",
        "Alt Port HTTP",
        "OpenVPN WS Path",
        "OpenVPN WS Path Alt",
    ),
}


def _local_today() -> date:
    return datetime.now().astimezone().date()


def _local_now() -> datetime:
    return datetime.now().astimezone()


def _read_json(path: Path) -> dict[str, Any] | None:
    if not path.exists():
        return None
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None
    return payload if isinstance(payload, dict) else None


def _human_bytes(value: int) -> str:
    n = max(0, int(value))
    if n >= 1024**4:
        return f"{n / (1024**4):.2f} TiB"
    if n >= 1024**3:
        return f"{n / (1024**3):.2f} GiB"
    if n >= 1024**2:
        return f"{n / (1024**2):.2f} MiB"
    if n >= 1024:
        return f"{n / 1024:.2f} KiB"
    return f"{n} B"


def _to_int(value: object, default: int = 0) -> int:
    try:
        if value is None:
            return default
        if isinstance(value, bool):
            return int(value)
        if isinstance(value, (int, float)):
            return int(value)
        raw = str(value).strip()
        if not raw:
            return default
        return int(float(raw))
    except Exception:
        return default


def _parse_date_only(raw: object) -> date | None:
    value = str(raw or "").strip()
    if not value:
        return None
    try:
        return datetime.strptime(value[:10], "%Y-%m-%d").date()
    except Exception:
        return None


def _display_username(proto: str, username: str) -> str:
    raw = str(username or "").strip()
    suffix = f"@{proto}"
    if raw.endswith(suffix):
        raw = raw[: -len(suffix)]
    if "@" in raw and proto in XRAY_PROTOCOLS:
        raw = raw.split("@", 1)[0]
    return raw or "-"


def _run_cmd(argv: list[str], timeout: int = 20) -> tuple[bool, str]:
    try:
        proc = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, check=False)
    except FileNotFoundError:
        return False, f"Command tidak ditemukan: {argv[0]}"
    except subprocess.TimeoutExpired:
        return False, f"Timeout: {' '.join(argv)}"
    except Exception as exc:
        return False, f"Gagal menjalankan command: {exc}"

    out = ((proc.stdout or "") + ("\n" + proc.stderr if proc.stderr else "")).strip()
    if not out:
        out = "(no output)"
    if proc.returncode != 0:
        return False, f"[exit {proc.returncode}]\n{out}"
    return True, out


def _extract_exit_code(raw: object) -> int | None:
    line = str(raw or "").splitlines()[0].strip() if str(raw or "").splitlines() else ""
    match = EXIT_CODE_RE.match(line)
    if not match:
        return None
    try:
        return int(match.group(1))
    except Exception:
        return None


def _detect_public_ipv4() -> str:
    ok, out = _run_cmd(
        ["curl", "-fsSL", "--max-time", "3", "http://ip-api.com/json/?fields=status,query"],
        timeout=5,
    )
    if ok and out.strip():
        try:
            payload = json.loads(out)
        except Exception:
            payload = {}
        query = str(payload.get("query") or "").strip()
        if payload.get("status") == "success" and query:
            return query

    ok, ip_raw = _run_cmd(["ip", "-4", "-o", "addr", "show", "scope", "global"], timeout=8)
    if ok:
        match = re.search(r"\binet\s+(\d+\.\d+\.\d+\.\d+)/", ip_raw)
        if match:
            candidate = match.group(1)
            try:
                if not ipaddress.ip_address(candidate).is_private:
                    return candidate
            except Exception:
                return candidate

    ok, out = _run_cmd(["curl", "-4fsSL", "--max-time", "3", "https://api.ipify.org"], timeout=5)
    if ok and out.strip():
        candidate = out.splitlines()[0].strip()
        try:
            if ipaddress.ip_address(candidate).version == 4:
                return candidate
        except Exception:
            pass
    return "-"


def detect_domain() -> str:
    if NGINX_CONF.exists():
        for line in NGINX_CONF.read_text(encoding="utf-8", errors="ignore").splitlines():
            match = re.match(r"^\s*server_name\s+([^;]+);", line)
            if not match:
                continue
            token = match.group(1).strip().split()[0]
            if token and token != "_":
                return token
    ok, fqdn = _run_cmd(["hostname", "-f"], timeout=8)
    if ok and fqdn.strip():
        return fqdn.splitlines()[0].strip()
    ok, host = _run_cmd(["hostname"], timeout=8)
    if ok and host.strip():
        return host.splitlines()[0].strip()
    return "-"


def account_portal_public_host() -> str:
    host = detect_domain()
    if host and host != "-":
        return host
    return _detect_public_ipv4()


def account_portal_url(token: str) -> str:
    token_n = str(token or "").strip()
    if not PORTAL_TOKEN_RE.fullmatch(token_n):
        return "-"
    host = account_portal_public_host()
    if not host or host == "-":
        return "-"
    return f"https://{host}/account/{token_n}"


def _iter_proto_quota_files(proto: str) -> list[tuple[str, Path]]:
    state_dir = QUOTA_ROOT / proto
    if not state_dir.exists():
        return []

    selected: dict[str, Path] = {}
    selected_has_at: dict[str, bool] = {}
    for path in sorted(state_dir.glob("*.json")):
        stem = path.stem
        suffix = f"@{proto}"
        username = stem[: -len(suffix)] if stem.endswith(suffix) else stem
        if not username:
            continue
        has_at = "@" in stem
        prev = selected.get(username)
        if prev is not None:
            if has_at and not selected_has_at.get(username, False):
                selected[username] = path
                selected_has_at[username] = True
            continue
        selected[username] = path
        selected_has_at[username] = has_at
    return [(username, selected[username]) for username in sorted(selected)]


def _extract_xray_ip(match: re.Match[str] | None) -> str:
    if match is None:
        return ""
    return str(match.group(1) or match.group(2) or match.group(3) or "").strip()


def _is_loopback_ip(value: str) -> bool:
    raw = str(value or "").strip()
    if not raw:
        return False
    try:
        return ipaddress.ip_address(raw).is_loopback
    except Exception:
        lowered = raw.lower()
        return lowered in {"127.0.0.1", "::1", "0:0:0:0:0:0:0:1"}


def _extract_xray_route(line: str) -> str:
    match = XRAY_ROUTE_RE.search(str(line or ""))
    if not match:
        return ""
    return str(match.group(1) or "").strip().lower()


def _parse_edge_mux_remote_ip(raw: str) -> str:
    candidate = str(raw or "").strip()
    if not candidate:
        return ""
    if candidate.startswith("[") and "]:" in candidate:
        return candidate[1:].split("]:", 1)[0].strip()
    if ":" in candidate:
        head, tail = candidate.rsplit(":", 1)
        if tail.isdigit():
            return head.strip()
    return candidate


def _edge_mux_recent_routes() -> list[dict[str, object]]:
    now_ts = time.time()
    with _EDGE_MUX_ROUTE_CACHE_LOCK:
        cached_expires = float(_EDGE_MUX_ROUTE_CACHE.get("expires_at") or 0.0)
        cached_events = _EDGE_MUX_ROUTE_CACHE.get("events")
        if cached_expires > now_ts and isinstance(cached_events, list):
            return [item for item in cached_events if isinstance(item, dict)]

    since_at = _local_now().timestamp() - (XRAY_ACTIVE_FRESHNESS_SECONDS + 60)
    since_text = datetime.fromtimestamp(since_at, tz=_local_now().tzinfo).strftime("%Y-%m-%d %H:%M:%S")
    ok, out = _run_cmd(["journalctl", "-u", "edge-mux", "--since", since_text, "--no-pager", "-o", "cat"], timeout=8)
    events: list[dict[str, object]] = []
    if ok and out.strip():
        for line in out.splitlines():
            match = EDGE_MUX_ROUTE_RE.search(line)
            if not match:
                continue
            route_name = str(match.group("route") or "").strip().lower()
            if not route_name or route_name in {"http2", "http-other", "ssh-direct-timeout", "ssh-direct-unknown"}:
                continue
            remote_ip = _parse_edge_mux_remote_ip(match.group("remote"))
            if not remote_ip:
                continue
            try:
                event_ts = datetime.strptime(str(match.group("ts")), "%Y/%m/%d %H:%M:%S").replace(tzinfo=_local_now().tzinfo)
            except Exception:
                continue
            events.append({"ts": event_ts.timestamp(), "route": route_name, "ip": remote_ip})

    with _EDGE_MUX_ROUTE_CACHE_LOCK:
        _EDGE_MUX_ROUTE_CACHE["expires_at"] = now_ts + EDGE_MUX_ROUTE_CACHE_SECONDS
        _EDGE_MUX_ROUTE_CACHE["events"] = events
    return events


def _edge_mux_resolve_xray_ip(route_name: str, timestamp: datetime | None) -> str:
    route_n = str(route_name or "").strip().lower()
    if not route_n or timestamp is None:
        return "-"
    target_ts = timestamp.timestamp()
    best_ip = "-"
    best_delta: float | None = None
    best_event_ts = -1.0
    for item in _edge_mux_recent_routes():
        if str(item.get("route") or "").strip().lower() != route_n:
            continue
        event_ts = float(item.get("ts") or 0.0)
        delta = abs(event_ts - target_ts)
        if delta > EDGE_MUX_ROUTE_MATCH_WINDOW_SECONDS:
            continue
        ip_value = str(item.get("ip") or "").strip()
        if not ip_value:
            continue
        if best_delta is None or delta < best_delta or (delta == best_delta and event_ts >= best_event_ts):
            best_delta = delta
            best_event_ts = event_ts
            best_ip = ip_value
    return best_ip or "-"


def _read_tail_lines(path: Path, *, max_bytes: int = XRAY_ACCESS_TAIL_MAX_BYTES, max_lines: int = XRAY_ACCESS_TAIL_MAX_LINES) -> list[str]:
    if not path.exists():
        return []
    try:
        with path.open("rb") as handle:
            handle.seek(0, 2)
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
    return lines[-max_lines:] if max_lines > 0 else lines


def _parse_xray_access_ts(line: str) -> datetime | None:
    match = XRAY_ACCESS_TS_RE.match(str(line or "").strip())
    if not match:
        return None
    try:
        return datetime.strptime(match.group(1), "%Y/%m/%d %H:%M:%S").replace(tzinfo=_local_now().tzinfo)
    except Exception:
        return None


def _xray_last_seen_ip(email: str) -> tuple[str, str]:
    email_n = str(email or "").strip()
    if not email_n or not XRAY_ACCESS_LOG.exists():
        return "-", "-"

    now_ts = time.time()
    with _XRAY_LAST_SEEN_CACHE_LOCK:
        cached = _XRAY_LAST_SEEN_CACHE.get(email_n)
        if isinstance(cached, dict) and float(cached.get("expires_at") or 0.0) > now_ts:
            return (
                str(cached.get("ip") or "-").strip() or "-",
                str(cached.get("updated_at") or "-").strip() or "-",
            )

    cutoff = _local_now().timestamp() - XRAY_ACTIVE_FRESHNESS_SECONDS
    for line in reversed(_read_tail_lines(XRAY_ACCESS_LOG)):
        email_match = XRAY_EMAIL_RE.search(line)
        if not email_match or str(email_match.group(1) or "").strip() != email_n:
            continue
        timestamp = _parse_xray_access_ts(line)
        if timestamp is None or timestamp.timestamp() < cutoff:
            with _XRAY_LAST_SEEN_CACHE_LOCK:
                _XRAY_LAST_SEEN_CACHE[email_n] = {
                    "expires_at": now_ts + XRAY_LAST_SEEN_CACHE_SECONDS,
                    "ip": "-",
                    "updated_at": "-",
                }
            return "-", "-"
        ip_match = XRAY_IP_RE.search(line)
        ip_value = _extract_xray_ip(ip_match) or "-"
        route_name = _extract_xray_route(line)
        if _is_loopback_ip(ip_value):
            resolved_ip = _edge_mux_resolve_xray_ip(route_name, timestamp)
            ip_value = resolved_ip if resolved_ip and resolved_ip != "-" else "-"
        updated_at = timestamp.strftime("%Y-%m-%d %H:%M:%S")
        with _XRAY_LAST_SEEN_CACHE_LOCK:
            _XRAY_LAST_SEEN_CACHE[email_n] = {
                "expires_at": now_ts + XRAY_LAST_SEEN_CACHE_SECONDS,
                "ip": ip_value,
                "updated_at": updated_at,
            }
        return ip_value, updated_at
    with _XRAY_LAST_SEEN_CACHE_LOCK:
        _XRAY_LAST_SEEN_CACHE[email_n] = {
            "expires_at": now_ts + XRAY_LAST_SEEN_CACHE_SECONDS,
            "ip": "-",
            "updated_at": "-",
        }
    return "-", "-"


def _ssh_active_ip(username: str) -> str:
    if not SSHWS_RUNTIME_SESSION_DIR.exists() or not SSHWS_CONTROL_BIN.exists():
        return "-"
    ok, out = _run_cmd(
        [
            str(SSHWS_CONTROL_BIN),
            "session-list",
            "--session-root",
            str(SSHWS_RUNTIME_SESSION_DIR),
        ],
        timeout=20,
    )
    if not ok:
        return "-"
    try:
        payload = json.loads(out)
    except Exception:
        return "-"
    sessions = payload.get("sessions")
    if not isinstance(sessions, list):
        return "-"

    target = str(username or "").strip()
    best_ip = "-"
    best_ts = -1
    for item in sessions:
        if not isinstance(item, dict):
            continue
        if str(item.get("username") or "").strip() != target:
            continue
        client_ip = str(item.get("client_ip") or "").strip() or "-"
        updated_at = _to_int(item.get("updated_at"), 0)
        if updated_at >= best_ts:
            best_ts = updated_at
            best_ip = client_ip
    return best_ip


def _openvpn_active_ip(payload: dict[str, Any]) -> str:
    status = payload.get("status") if isinstance(payload.get("status"), dict) else {}
    active_total = max(0, _to_int(status.get("active_sessions_openvpn"), 0))
    if active_total <= 0:
        active_total = max(0, _to_int(status.get("active_sessions_total"), 0))
    if active_total <= 0:
        return "-"
    raw_ips = status.get("distinct_ips_openvpn")
    if not isinstance(raw_ips, list) or not raw_ips:
        raw_ips = status.get("distinct_ips")
    if not isinstance(raw_ips, list):
        return "-"
    ips = [str(item).strip() for item in raw_ips if str(item).strip()]
    return ", ".join(ips[:3]) if ips else "-"


def _portal_account_status(payload: dict[str, Any]) -> tuple[str, str]:
    status = payload.get("status") if isinstance(payload.get("status"), dict) else {}
    expired_date = _parse_date_only(payload.get("expired_at"))
    if bool(status.get("manual_block")):
        return "blocked", "Akun diblokir manual."
    if bool(status.get("quota_exhausted")):
        return "blocked", "Quota akun sudah habis."
    if bool(status.get("ip_limit_locked")) or bool(status.get("account_locked")):
        return "blocked", "Akun sedang terkunci oleh policy login."
    if expired_date is not None and expired_date < _local_today():
        return "expired", "Masa aktif akun sudah habis."
    return "active", "Akun aktif."


def _rebuild_portal_index_locked(now_ts: float) -> None:
    tokens: dict[str, dict[str, str]] = {}
    for proto in QAC_PROTOCOLS:
        for username, path in _iter_proto_quota_files(proto):
            payload = _read_json(path)
            if not isinstance(payload, dict):
                continue
            portal_token = str(payload.get("portal_token") or "").strip()
            if not PORTAL_TOKEN_RE.fullmatch(portal_token):
                continue
            tokens[portal_token] = {
                "proto": proto,
                "username": username,
                "path": str(path),
            }
    _PORTAL_INDEX_CACHE["tokens"] = tokens
    _PORTAL_INDEX_CACHE["negative"] = {}
    _PORTAL_INDEX_CACHE["expires_at"] = now_ts + PORTAL_INDEX_CACHE_SECONDS


def _portal_index_entry(token_n: str) -> dict[str, str] | None:
    now_ts = time.time()
    with _PORTAL_INDEX_CACHE_LOCK:
        expires_at = float(_PORTAL_INDEX_CACHE.get("expires_at") or 0.0)
        if expires_at <= now_ts:
            _rebuild_portal_index_locked(now_ts)
        negative = _PORTAL_INDEX_CACHE.get("negative")
        if isinstance(negative, dict):
            negative_expires = float(negative.get(token_n) or 0.0)
            if negative_expires > now_ts:
                return None
        tokens = _PORTAL_INDEX_CACHE.get("tokens")
        if isinstance(tokens, dict):
            entry = tokens.get(token_n)
            if isinstance(entry, dict):
                return {
                    "proto": str(entry.get("proto") or "").strip(),
                    "username": str(entry.get("username") or "").strip(),
                    "path": str(entry.get("path") or "").strip(),
                }
        negative_map = negative if isinstance(negative, dict) else {}
        negative_map[token_n] = now_ts + PORTAL_NEGATIVE_CACHE_SECONDS
        _PORTAL_INDEX_CACHE["negative"] = negative_map
    return None


def _portal_account_lookup(token: str) -> tuple[str, str, Path, dict[str, Any]] | None:
    token_n = str(token or "").strip()
    if not PORTAL_TOKEN_RE.fullmatch(token_n):
        return None

    now_ts = time.time()
    with _PORTAL_LOOKUP_CACHE_LOCK:
        for cached_token, meta in list(_PORTAL_LOOKUP_CACHE.items()):
            if float(meta.get("expires_at") or 0.0) <= now_ts:
                _PORTAL_LOOKUP_CACHE.pop(cached_token, None)
        cached = _PORTAL_LOOKUP_CACHE.get(token_n)
    if isinstance(cached, dict):
        expires_at = float(cached.get("expires_at") or 0.0)
        proto_cached = str(cached.get("proto") or "").strip()
        username_cached = str(cached.get("username") or "").strip()
        path_raw = str(cached.get("path") or "").strip()
        if expires_at > now_ts and proto_cached and username_cached and path_raw:
            path = Path(path_raw)
            payload = _read_json(path)
            if isinstance(payload, dict) and str(payload.get("portal_token") or "").strip() == token_n:
                return proto_cached, username_cached, path, payload
        if expires_at <= now_ts:
            with _PORTAL_LOOKUP_CACHE_LOCK:
                _PORTAL_LOOKUP_CACHE.pop(token_n, None)

    indexed = _portal_index_entry(token_n)
    if isinstance(indexed, dict):
        proto = str(indexed.get("proto") or "").strip()
        username = str(indexed.get("username") or "").strip()
        path_raw = str(indexed.get("path") or "").strip()
        if proto and username and path_raw:
            path = Path(path_raw)
            payload = _read_json(path)
            if isinstance(payload, dict) and str(payload.get("portal_token") or "").strip() == token_n:
                with _PORTAL_LOOKUP_CACHE_LOCK:
                    _PORTAL_LOOKUP_CACHE[token_n] = {
                        "proto": proto,
                        "username": username,
                        "path": str(path),
                        "expires_at": now_ts + PORTAL_LOOKUP_CACHE_SECONDS,
                    }
                return proto, username, path, payload
            with _PORTAL_INDEX_CACHE_LOCK:
                _PORTAL_INDEX_CACHE["expires_at"] = 0.0
                negative = _PORTAL_INDEX_CACHE.get("negative")
                if isinstance(negative, dict):
                    negative.pop(token_n, None)
            indexed = _portal_index_entry(token_n)
            if isinstance(indexed, dict):
                proto = str(indexed.get("proto") or "").strip()
                username = str(indexed.get("username") or "").strip()
                path_raw = str(indexed.get("path") or "").strip()
                if proto and username and path_raw:
                    path = Path(path_raw)
                    payload = _read_json(path)
                    if isinstance(payload, dict) and str(payload.get("portal_token") or "").strip() == token_n:
                        with _PORTAL_LOOKUP_CACHE_LOCK:
                            _PORTAL_LOOKUP_CACHE[token_n] = {
                                "proto": proto,
                                "username": username,
                                "path": str(path),
                                "expires_at": now_ts + PORTAL_LOOKUP_CACHE_SECONDS,
                            }
                        return proto, username, path, payload
    return None


def _account_info_path(proto: str, username: str) -> Path:
    account_dir = ACCOUNT_INFO_ROOT / proto
    return account_dir / f"{username}@{proto}.txt"


def _account_info_cache_path(proto: str, username: str) -> Path:
    account_dir = ACCOUNT_INFO_ROOT / proto
    return account_dir / f"{username}@{proto}.portal.json"


def _load_cached_account_info_bundle(proto: str, username: str, source_mtime_ns: int, allow_stale: bool = False) -> dict[str, Any] | None:
    payload = _read_json(_account_info_cache_path(proto, username))
    if not isinstance(payload, dict):
        return None
    if _to_int(payload.get("version"), 0) != ACCOUNT_INFO_CACHE_VERSION:
        return None
    cached_mtime_ns = _to_int(payload.get("source_mtime_ns"), -1)
    if not allow_stale and cached_mtime_ns != source_mtime_ns:
        return None

    fields_raw = payload.get("fields")
    import_links_raw = payload.get("import_links")
    fields = fields_raw if isinstance(fields_raw, dict) else {}
    import_links = import_links_raw if isinstance(import_links_raw, list) else []
    normalized_fields = {str(key).strip(): str(value or "").strip() for key, value in fields.items() if str(key).strip()}
    normalized_links = [
        {
            "label": str(item.get("label") or "").strip(),
            "url": str(item.get("url") or "").strip(),
        }
        for item in import_links
        if isinstance(item, dict) and str(item.get("url") or "").strip()
    ]
    if not normalized_fields and not normalized_links:
        return None
    return {
        "fields": normalized_fields,
        "import_links": normalized_links,
    }


def _store_cached_account_info_bundle(proto: str, username: str, source_mtime_ns: int, bundle: dict[str, Any]) -> None:
    fields = bundle.get("fields")
    import_links = bundle.get("import_links")
    payload = {
        "version": ACCOUNT_INFO_CACHE_VERSION,
        "source_mtime_ns": int(source_mtime_ns),
        "fields": fields if isinstance(fields, dict) else {},
        "import_links": import_links if isinstance(import_links, list) else [],
    }
    try:
        _account_info_cache_path(proto, username).write_text(
            json.dumps(payload, ensure_ascii=True, separators=(",", ":")),
            encoding="utf-8",
        )
    except Exception:
        return


def _merge_account_info_bundle(current: dict[str, Any], stale: dict[str, Any] | None) -> dict[str, Any]:
    current_fields_raw = current.get("fields")
    stale_fields_raw = stale.get("fields") if isinstance(stale, dict) else {}
    current_links_raw = current.get("import_links")
    stale_links_raw = stale.get("import_links") if isinstance(stale, dict) else []
    current_fields = current_fields_raw if isinstance(current_fields_raw, dict) else {}
    stale_fields = stale_fields_raw if isinstance(stale_fields_raw, dict) else {}
    current_links = current_links_raw if isinstance(current_links_raw, list) else []
    stale_links = stale_links_raw if isinstance(stale_links_raw, list) else []
    if not stale_fields and not stale_links:
        return {
            "fields": current_fields,
            "import_links": current_links,
        }
    merged_fields = dict(stale_fields)
    merged_fields.update({str(key).strip(): str(value or "").strip() for key, value in current_fields.items() if str(key).strip()})
    merged_links = current_links if current_links else stale_links
    return {
        "fields": merged_fields,
        "import_links": merged_links,
    }


def _read_account_info_lines(proto: str, username: str) -> list[str]:
    path = _account_info_path(proto, username)
    if not path.exists():
        return []
    try:
        return path.read_text(encoding="utf-8", errors="ignore").splitlines()
    except Exception:
        return []


def _parse_account_info_fields_from_lines(lines: list[str]) -> dict[str, str]:
    fields: dict[str, str] = {}
    for raw_line in lines:
        line = str(raw_line or "").rstrip()
        if not line or line.startswith("==="):
            continue
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        key_n = key.strip()
        value_n = value.strip()
        if key_n:
            fields[key_n] = value_n
    return fields


def _normalize_field_key(value: object) -> str:
    raw = str(value or "").strip().lower()
    return re.sub(r"[^a-z0-9]+", "", raw)


def _field_lookup(fields: dict[str, str], *candidates: str) -> str:
    if not isinstance(fields, dict):
        return ""
    normalized = {_normalize_field_key(key): str(value or "").strip() for key, value in fields.items()}
    for candidate in candidates:
        direct = str(fields.get(candidate) or "").strip()
        if direct:
            return direct
        current = normalized.get(_normalize_field_key(candidate), "")
        if current:
            return current
    return ""


def _parse_xray_import_links_from_lines(lines: list[str]) -> list[dict[str, str]]:
    items: list[dict[str, str]] = []
    in_section = False
    pending_label = ""
    for raw_line in lines:
        line = str(raw_line or "")
        if not in_section:
            if XRAY_IMPORT_SECTION_RE.match(line.strip()):
                in_section = True
            continue
        if line.startswith("==="):
            break
        label_match = XRAY_IMPORT_LABEL_RE.match(line)
        if label_match:
            pending_label = str(label_match.group(1) or "").strip()
            continue
        link = line.strip()
        if link and "://" in link:
            label = pending_label.strip()
            if not label:
                if "type=ws" in link:
                    label = "WebSocket"
                elif "type=httpupgrade" in link:
                    label = "HTTPUpgrade"
                elif "type=xhttp" in link:
                    label = "XHTTP"
                elif "type=grpc" in link:
                    label = "gRPC"
                elif "type=tcp" in link:
                    label = "TCP+TLS"
            items.append({"label": label or "Import", "url": link})
            pending_label = ""
    return items


def _account_info_bundle(proto: str, username: str) -> dict[str, Any]:
    source_path = _account_info_path(proto, username)
    if not source_path.exists():
        stale = _load_cached_account_info_bundle(proto, username, -1, allow_stale=True)
        if isinstance(stale, dict):
            return stale
        return {
            "fields": {},
            "import_links": [],
        }
    try:
        source_mtime_ns = int(source_path.stat().st_mtime_ns)
    except Exception:
        source_mtime_ns = 0
    cached = _load_cached_account_info_bundle(proto, username, source_mtime_ns)
    if isinstance(cached, dict):
        return cached
    lines = _read_account_info_lines(proto, username)
    fields = _parse_account_info_fields_from_lines(lines)
    import_links = _parse_xray_import_links_from_lines(lines) if proto in XRAY_PROTOCOLS else []
    parsed_bundle = {
        "fields": fields,
        "import_links": import_links,
    }
    stale = _load_cached_account_info_bundle(proto, username, source_mtime_ns, allow_stale=True)
    bundle = _merge_account_info_bundle(parsed_bundle, stale if isinstance(stale, dict) else None)
    if bundle.get("fields") or bundle.get("import_links"):
        _store_cached_account_info_bundle(proto, username, source_mtime_ns, bundle)
        return bundle
    if isinstance(stale, dict):
        return stale
    return bundle


def _derive_access_from_import_links(import_links: list[dict[str, str]]) -> dict[str, str]:
    domain = "-"
    ports: list[str] = []
    paths: list[str] = []
    services: list[str] = []
    for item in import_links:
        url = str(item.get("url") or "").strip()
        if not url or "://" not in url:
            continue
        try:
            after_scheme = url.split("://", 1)[1]
            before_query = after_scheme.split("?", 1)[0]
            host_port = before_query.split("@", 1)[1] if "@" in before_query else before_query
            host = host_port.rsplit(":", 1)[0].strip()
            port = host_port.rsplit(":", 1)[1].strip() if ":" in host_port else ""
            if host and domain == "-":
                domain = host
            if port and port not in ports:
                ports.append(port)
            if "path=" in url:
                raw_path = url.split("path=", 1)[1].split("&", 1)[0]
                path = raw_path.replace("%2F", "/").replace("%2f", "/")
                if path and path not in paths:
                    paths.append(path)
            if "serviceName=" in url:
                service = url.split("serviceName=", 1)[1].split("&", 1)[0]
                if service and service not in services:
                    services.append(service)
        except Exception:
            continue
    path_value = ", ".join(paths[:3]) if paths else "-"
    if services:
        path_value = ", ".join([part for part in [path_value if path_value != "-" else "", ", ".join(services[:3])] if part]).strip(", ") or ", ".join(services[:3])
    return {
        "domain": domain,
        "ports": ", ".join(ports[:4]) if ports else "-",
        "path": path_value,
    }


def _parse_xray_import_links(proto: str, username: str) -> list[dict[str, str]]:
    if proto not in XRAY_PROTOCOLS:
        return []
    return _account_info_bundle(proto, username).get("import_links") or []


def _access_summary(
    proto: str,
    username: str,
    fields: dict[str, str] | None = None,
    import_links: list[dict[str, str]] | None = None,
) -> dict[str, str]:
    if fields is None or import_links is None:
        bundle = _account_info_bundle(proto, username)
        if fields is None:
            fields = bundle.get("fields") or {}
        if import_links is None:
            import_links = bundle.get("import_links") or []
    derived = _derive_access_from_import_links(import_links)
    domain = _field_lookup(fields, "Domain") or derived.get("domain", "-") or detect_domain() or "-"
    if proto in XRAY_PROTOCOLS:
        proto_title = proto.title()
        ports = _field_lookup(fields, f"{proto_title} WS", f"{proto_title} TCP+TLS Port") or derived.get("ports", "-") or "443, 80"
        path = _field_lookup(fields, f"{proto_title} Path WS", f"{proto_title} Path XHTTP", f"{proto_title} Path Service") or derived.get("path", "-") or "-"
    elif proto == SSH_PROTOCOL:
        ports = _field_lookup(fields, "SSH WS Port", "SSH Direct Port") or derived.get("ports", "-") or "443, 80"
        path = _field_lookup(fields, "SSH WS Path") or derived.get("path", "-") or "-"
    elif proto == OPENVPN_POLICY_PROTOCOL:
        ports = _field_lookup(fields, "OpenVPN WS Port", "OpenVPN TCP") or derived.get("ports", "-") or "443, 80"
        path = _field_lookup(fields, "OpenVPN WS Path") or derived.get("path", "-") or "-"
    else:
        ports = "-"
        path = "-"
    return {
        "domain": domain,
        "ports": ports,
        "path": path,
    }


def _access_detail_items(proto: str, username: str, fields: dict[str, str] | None = None) -> list[dict[str, str]]:
    if fields is None:
        fields = _account_info_bundle(proto, username).get("fields") or {}
    selected = ACCESS_DETAIL_FIELDS.get(proto, ())
    items: list[dict[str, str]] = []
    for label in selected:
        value = _field_lookup(fields, label)
        if not value or value == "-":
            continue
        items.append({"label": label, "value": value})
    return items


def build_public_account_summary(token: str) -> dict[str, Any] | None:
    found = _portal_account_lookup(token)
    if found is None:
        return None

    proto, username, _path, payload = found
    status_code, status_text = _portal_account_status(payload)
    expired_date = _parse_date_only(payload.get("expired_at"))
    days_remaining = max(0, (expired_date - _local_today()).days) if expired_date is not None else None
    quota_limit_bytes = max(0, _to_int(payload.get("quota_limit"), 0))
    quota_used_bytes = max(0, _to_int(payload.get("quota_used"), 0))
    quota_remaining_bytes = max(0, quota_limit_bytes - quota_used_bytes) if quota_limit_bytes > 0 else 0
    status_payload = payload.get("status") if isinstance(payload.get("status"), dict) else {}
    ip_limit_enabled = bool(status_payload.get("ip_limit_enabled"))
    ip_limit_value = max(0, _to_int(status_payload.get("ip_limit"), 0))
    speed_limit_enabled = bool(status_payload.get("speed_limit_enabled"))
    speed_down_mbit = max(0, _to_int(status_payload.get("speed_down_mbit"), 0))
    speed_up_mbit = max(0, _to_int(status_payload.get("speed_up_mbit"), 0))
    active_ip = "-"
    active_ip_mode = "none"
    active_ip_updated = "-"

    if proto == SSH_PROTOCOL:
        active_ip = _ssh_active_ip(username)
        active_ip_mode = "runtime" if active_ip != "-" else "none"
    elif proto == OPENVPN_POLICY_PROTOCOL:
        active_ip = _openvpn_active_ip(payload)
        active_ip_mode = "runtime" if active_ip != "-" else "none"
    else:
        active_ip, active_ip_updated = _xray_last_seen_ip(str(payload.get("username") or f"{username}@{proto}"))
        active_ip_mode = "last_seen" if active_ip != "-" else "none"
    account_info = _account_info_bundle(proto, username)
    account_fields = account_info.get("fields") or {}
    import_links = account_info.get("import_links") or []
    access_info = _access_summary(proto, username, account_fields, import_links)
    access_details = _access_detail_items(proto, username, account_fields)

    return {
        "ok": True,
        "protocol": proto,
        "username": _display_username(proto, str(payload.get("username") or username)),
        "traffic_account_key": str(payload.get("username") or username).strip(),
        "status": status_code,
        "status_text": status_text,
        "valid_until": str(payload.get("expired_at") or "-").strip()[:10] or "-",
        "days_remaining": days_remaining,
        "quota_limit": _human_bytes(quota_limit_bytes) if quota_limit_bytes > 0 else "Unlimited",
        "quota_limit_bytes": quota_limit_bytes,
        "quota_used": _human_bytes(quota_used_bytes),
        "quota_used_bytes": quota_used_bytes,
        "quota_remaining": _human_bytes(quota_remaining_bytes) if quota_limit_bytes > 0 else "Unlimited",
        "quota_remaining_bytes": quota_remaining_bytes,
        "ip_limit_enabled": ip_limit_enabled,
        "ip_limit_value": ip_limit_value,
        "ip_limit_text": str(ip_limit_value) if ip_limit_enabled and ip_limit_value > 0 else "OFF",
        "speed_limit_enabled": speed_limit_enabled,
        "speed_down_mbit": speed_down_mbit,
        "speed_up_mbit": speed_up_mbit,
        "speed_limit_text": f"DOWN {speed_down_mbit} Mbps / UP {speed_up_mbit} Mbps" if speed_limit_enabled and (speed_down_mbit > 0 or speed_up_mbit > 0) else "OFF",
        "active_ip": active_ip,
        "active_ip_mode": active_ip_mode,
        "active_ip_last_seen_at": active_ip_updated,
        "access_domain": access_info.get("domain", "-"),
        "access_ports": access_info.get("ports", "-"),
        "access_path": access_info.get("path", "-"),
        "access_details": access_details,
        "portal_url": account_portal_url(token),
        "token": str(token or "").strip(),
        "import_links": import_links,
        "last_updated": _local_now().strftime("%Y-%m-%d %H:%M:%S"),
    }


def build_public_account_traffic_context(token: str) -> dict[str, Any] | None:
    found = _portal_account_lookup(token)
    if found is None:
        return None

    proto, username, _path, payload = found
    return {
        "protocol": proto,
        "username": _display_username(proto, str(payload.get("username") or username)),
        "traffic_account_key": str(payload.get("username") or username).strip(),
        "quota_used_bytes": max(0, _to_int(payload.get("quota_used"), 0)),
    }
