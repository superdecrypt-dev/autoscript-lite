from __future__ import annotations

import ipaddress
import json
import re
import subprocess
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
EXIT_CODE_RE = re.compile(r"^\[exit (\d+)\]$")

XRAY_ACTIVE_FRESHNESS_SECONDS = 600
XRAY_ACCESS_TAIL_MAX_BYTES = 1024 * 1024
XRAY_ACCESS_TAIL_MAX_LINES = 6000
XRAY_IMPORT_SECTION_RE = re.compile(r"^===\s+LINKS IMPORT\s+===$")
XRAY_IMPORT_LABEL_RE = re.compile(r"^\s{2,}(.+?)\s*:\s*$")

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

    cutoff = _local_now().timestamp() - XRAY_ACTIVE_FRESHNESS_SECONDS
    for line in reversed(_read_tail_lines(XRAY_ACCESS_LOG)):
        email_match = XRAY_EMAIL_RE.search(line)
        if not email_match or str(email_match.group(1) or "").strip() != email_n:
            continue
        timestamp = _parse_xray_access_ts(line)
        if timestamp is None or timestamp.timestamp() < cutoff:
            return "-", "-"
        ip_match = XRAY_IP_RE.search(line)
        ip_value = _extract_xray_ip(ip_match) or "-"
        return ip_value, timestamp.strftime("%Y-%m-%d %H:%M:%S")
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


def _portal_account_lookup(token: str) -> tuple[str, str, Path, dict[str, Any]] | None:
    token_n = str(token or "").strip()
    if not PORTAL_TOKEN_RE.fullmatch(token_n):
        return None
    for proto in QAC_PROTOCOLS:
        for username, path in _iter_proto_quota_files(proto):
            payload = _read_json(path)
            if not isinstance(payload, dict):
                continue
            if str(payload.get("portal_token") or "").strip() != token_n:
                continue
            return proto, username, path, payload
    return None


def _account_info_path(proto: str, username: str) -> Path:
    account_dir = ACCOUNT_INFO_ROOT / proto
    return account_dir / f"{username}@{proto}.txt"


def _parse_account_info_fields(proto: str, username: str) -> dict[str, str]:
    path = _account_info_path(proto, username)
    if not path.exists():
        return {}
    fields: dict[str, str] = {}
    try:
        lines = path.read_text(encoding="utf-8", errors="ignore").splitlines()
    except Exception:
        return fields
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


def _parse_xray_import_links(proto: str, username: str) -> list[dict[str, str]]:
    if proto not in XRAY_PROTOCOLS:
        return []
    path = _account_info_path(proto, username)
    if not path.exists():
        return []
    try:
        lines = path.read_text(encoding="utf-8", errors="ignore").splitlines()
    except Exception:
        return []

    in_section = False
    pending_label = ""
    items: list[dict[str, str]] = []
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
        if pending_label and link and "://" in link:
            items.append({"label": pending_label, "url": link})
            pending_label = ""
    return items


def _access_summary(proto: str, username: str) -> dict[str, str]:
    fields = _parse_account_info_fields(proto, username)
    domain = str(fields.get("Domain") or detect_domain() or "-").strip() or "-"
    if proto in XRAY_PROTOCOLS:
        proto_title = proto.title()
        ports = str(fields.get(f"{proto_title} WS") or fields.get(f"{proto_title} TCP+TLS Port") or "443, 80").strip() or "-"
        path = str(fields.get(f"{proto_title} Path WS") or "-").strip() or "-"
    elif proto == SSH_PROTOCOL:
        ports = str(fields.get("SSH WS Port") or fields.get("SSH Direct Port") or "443, 80").strip() or "-"
        path = str(fields.get("SSH WS Path") or "-").strip() or "-"
    elif proto == OPENVPN_POLICY_PROTOCOL:
        ports = str(fields.get("OpenVPN WS Port") or fields.get("OpenVPN TCP") or "443, 80").strip() or "-"
        path = str(fields.get("OpenVPN WS Path") or "-").strip() or "-"
    else:
        ports = "-"
        path = "-"
    return {
        "domain": domain,
        "ports": ports,
        "path": path,
    }


def _access_detail_items(proto: str, username: str) -> list[dict[str, str]]:
    fields = _parse_account_info_fields(proto, username)
    selected = ACCESS_DETAIL_FIELDS.get(proto, ())
    items: list[dict[str, str]] = []
    for label in selected:
        value = str(fields.get(label) or "").strip()
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
    import_links = _parse_xray_import_links(proto, username)
    access_info = _access_summary(proto, username)
    access_details = _access_detail_items(proto, username)

    return {
        "ok": True,
        "protocol": proto,
        "username": _display_username(proto, str(payload.get("username") or username)),
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
