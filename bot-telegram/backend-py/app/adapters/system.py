import base64
import ipaddress
import json
import re
import shutil
import socket
import ssl
import subprocess
import time
from collections import Counter
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Any, List, Tuple

ACCOUNT_ROOT = Path("/opt/account")
QUOTA_ROOT = Path("/opt/quota")
SSHWS_RUNTIME_SESSION_DIR = Path("/run/autoscript/sshws-sessions")
SSHWS_CONTROL_BIN = Path("/usr/local/bin/sshws-control")
XRAY_CONFDIR = Path("/usr/local/etc/xray/conf.d")
NGINX_CONF = Path("/etc/nginx/conf.d/xray.conf")
CERT_FULLCHAIN = Path("/opt/cert/fullchain.pem")
NETWORK_STATE_FILE = Path("/var/lib/xray-manage/network_state.json")
ADBLOCK_ENV_FILE = Path("/etc/autoscript/ssh-adblock/config.env")
ADBLOCK_SYNC_BIN = Path("/usr/local/bin/adblock-sync")
ADBLOCK_DEFAULT_BLOCKLIST = Path("/etc/autoscript/ssh-adblock/blocked.domains")
ADBLOCK_DEFAULT_URLS = Path("/etc/autoscript/ssh-adblock/source.urls")
SSH_NETWORK_ENV_FILE = Path("/etc/autoscript/ssh-network/config.env")
WIREPROXY_CONF = Path("/etc/wireproxy/config.conf")
EDGE_RUNTIME_ENV_FILE = Path("/etc/default/edge-runtime")
BADVPN_RUNTIME_ENV_FILE = Path("/etc/default/badvpn-udpgw")
SSHWS_RUNTIME_ENV_FILE = Path("/etc/default/sshws-runtime")
OPENVPN_CONFIG_ENV_FILE = Path("/etc/autoscript/openvpn/config.env")
XRAY_DOMAIN_GUARD_BIN = Path("/usr/local/bin/xray-domain-guard")
XRAY_DOMAIN_GUARD_CONFIG_FILE = Path("/etc/xray-domain-guard/config.env")
XRAY_DOMAIN_GUARD_LOG_FILE = Path("/var/log/xray-domain-guard/domain-guard.log")
WARP_MODE_STATE_KEY = "warp_mode"
WARP_TIER_STATE_KEY = "warp_tier_target"
WARP_PLUS_LICENSE_STATE_KEY = "warp_plus_license_key"
WARP_ZEROTRUST_CONFIG_FILE = Path("/etc/autoscript/warp-zerotrust/config.env")
WARP_ZEROTRUST_MDM_FILE = Path("/var/lib/cloudflare-warp/mdm.xml")
WARP_ZEROTRUST_SERVICE = "warp-svc"
WARP_ZEROTRUST_PROXY_PORT = "40000"
READONLY_GEOSITE_DOMAINS = (
    "geosite:apple",
    "geosite:meta",
    "geosite:google",
    "geosite:openai",
    "geosite:spotify",
    "geosite:netflix",
    "geosite:reddit",
)
XRAY_PROTOCOLS = ("vless", "vmess", "trojan")
SSH_PROTOCOL = "ssh"
OPENVPN_POLICY_PROTOCOL = "openvpn"
USER_PROTOCOLS = XRAY_PROTOCOLS
QAC_PROTOCOLS = XRAY_PROTOCOLS
PROTOCOLS = XRAY_PROTOCOLS
QUOTA_UNIT_DECIMAL = {"decimal", "gb", "1000", "gigabyte"}
USERNAME_RE = re.compile(r"^[A-Za-z0-9._-]+$")
SSH_USERNAME_RE = re.compile(r"^[a-z_][a-z0-9_-]{1,31}$")
EXIT_CODE_RE = re.compile(r"^\[exit (\d+)\]$")
ALLOWED_SERVICES = (
    "xray",
    "nginx",
    "edge-mux",
    "wireproxy",
    "xray-expired",
    "xray-quota",
    "xray-limit-ip",
    "xray-speed",
)


def _local_today() -> date:
    return datetime.now().astimezone().date()


def _local_now() -> datetime:
    return datetime.now().astimezone()


ALLOWED_RESTART_SERVICES = set(ALLOWED_SERVICES) | {"fail2ban"}
XRAY_DAEMONS = ("xray-expired", "xray-quota", "xray-limit-ip", "xray-speed")
SSHWS_SERVICES = ("sshws-dropbear", "sshws-stunnel", "sshws-proxy")
OPENVPN_SERVICES = ("openvpn-server@autoscript-tcp", "ovpn-ws-proxy")
SSHWS_DROPBEAR_UNIT = Path("/etc/systemd/system/sshws-dropbear.service")
SSHWS_STUNNEL_CONF = Path("/etc/stunnel/sshws.conf")
SSHWS_PROXY_UNIT = Path("/etc/systemd/system/sshws-proxy.service")
MESSAGE_SOFT_LIMIT = 3500
MAIN_MENU_HEADER_CACHE_TTL_SECONDS = 180
_MAIN_MENU_HEADER_CACHE_TEXT = ""
_MAIN_MENU_HEADER_CACHE_TS = 0.0


def run_cmd(argv: List[str], timeout: int = 20) -> Tuple[bool, str]:
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


def read_json(path: Path) -> Tuple[bool, object]:
    if not path.exists():
        return False, f"File tidak ditemukan: {path}"
    try:
        return True, json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        return False, f"Gagal parse JSON {path}: {exc}"


def bytes_to_gib(value: int) -> str:
    gib = value / (1024 * 1024 * 1024)
    return f"{gib:.2f} GiB"


def memory_summary() -> str:
    meminfo = {}
    try:
        for line in Path("/proc/meminfo").read_text(encoding="utf-8").splitlines():
            if ":" not in line:
                continue
            key, raw = line.split(":", 1)
            meminfo[key.strip()] = int(raw.strip().split()[0]) * 1024
    except Exception:
        return "-"

    total = meminfo.get("MemTotal", 0)
    avail = meminfo.get("MemAvailable", 0)
    used = max(total - avail, 0)
    if total <= 0:
        return "-"
    return f"{bytes_to_gib(used)} / {bytes_to_gib(total)}"


def detect_domain() -> str:
    # Samakan prioritas dengan manage.sh: nginx server_name -> hostname -f -> hostname.
    if NGINX_CONF.exists():
        for line in NGINX_CONF.read_text(encoding="utf-8", errors="ignore").splitlines():
            m = re.match(r"^\s*server_name\s+([^;]+);", line)
            if m:
                token = m.group(1).strip().split()[0]
                if token and token != "_":
                    return token
    ok_fqdn, fqdn = run_cmd(["hostname", "-f"], timeout=8)
    if ok_fqdn and fqdn.strip():
        return fqdn.splitlines()[0].strip()
    ok_host, host = run_cmd(["hostname"], timeout=8)
    if ok_host and host.strip():
        return host.splitlines()[0].strip()
    return "-"


def detect_tls_expiry() -> str:
    if not CERT_FULLCHAIN.exists():
        return "cert tidak ditemukan"
    ok, out = run_cmd(["openssl", "x509", "-in", str(CERT_FULLCHAIN), "-noout", "-enddate"], timeout=10)
    if not ok:
        return out
    line = out.splitlines()[-1].strip()
    return line.replace("notAfter=", "")


def _main_menu_os_pretty() -> str:
    os_release = Path("/etc/os-release")
    if os_release.exists():
        try:
            for raw in os_release.read_text(encoding="utf-8", errors="ignore").splitlines():
                line = raw.strip()
                if not line.startswith("PRETTY_NAME="):
                    continue
                value = line.split("=", 1)[1].strip().strip('"').strip("'")
                if value:
                    return value
        except Exception:
            pass
    ok, out = run_cmd(["uname", "-sr"], timeout=8)
    if ok and out.strip():
        return out.splitlines()[0].strip()
    return "-"


def _main_menu_ipv4_get() -> str:
    if shutil.which("curl") is not None:
        ok, out = run_cmd(
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

    ok, ip_raw = run_cmd(["ip", "-4", "-o", "addr", "show", "scope", "global"], timeout=8)
    if ok:
        match = re.search(r"\binet\s+(\d+\.\d+\.\d+\.\d+)/", ip_raw)
        if match:
            ip = match.group(1)
            try:
                if not ipaddress.ip_address(ip).is_private:
                    return ip
            except Exception:
                return ip

    if shutil.which("curl") is not None:
        ok, out = run_cmd(["curl", "-4fsSL", "--max-time", "3", "https://api.ipify.org"], timeout=5)
        if ok and out.strip():
            return out.splitlines()[0].strip()
    return "-"


def _main_menu_geo_lookup(ip: str) -> tuple[str, str, str]:
    ip_value = str(ip or "").strip()
    if not ip_value or ip_value == "-" or shutil.which("curl") is None:
        return "-", "-", "-"

    providers = (
        (
            f"http://ip-api.com/json/{ip_value}?fields=status,query,country,isp",
            lambda payload: (
                str(payload.get("query") or "-"),
                str(payload.get("isp") or "-"),
                str(payload.get("country") or "-"),
            )
            if payload.get("status") == "success"
            else ("-", "-", "-"),
        ),
        (
            f"https://ipwho.is/{ip_value}",
            lambda payload: (
                str(payload.get("ip") or ip_value or "-"),
                str(payload.get("connection", {}).get("isp") or "-"),
                str(payload.get("country") or payload.get("country_name") or "-"),
            )
            if bool(payload.get("success"))
            else ("-", "-", "-"),
        ),
        (
            f"https://ipinfo.io/{ip_value}/json",
            lambda payload: (
                str(payload.get("ip") or ip_value or "-"),
                str(payload.get("org") or "-"),
                str(payload.get("country") or "-"),
            ),
        ),
    )

    for url, parser in providers:
        ok, out = run_cmd(["curl", "-fsSL", "--max-time", "3", url], timeout=5)
        if not ok or not out.strip():
            continue
        try:
            payload = json.loads(out)
        except Exception:
            continue
        ip_out, isp_out, country_out = parser(payload)
        ip_out = ip_out if ip_out and ip_out != "null" else "-"
        isp_out = isp_out if isp_out and isp_out != "null" else "-"
        country_out = country_out if country_out and country_out != "null" else "-"
        if ip_out != "-" or isp_out != "-" or country_out != "-":
            return ip_out, isp_out, country_out
    return ip_value, "-", "-"


def _main_menu_tls_expiry_label() -> str:
    days = _tls_expiry_days_left()
    if days is None:
        return "-"
    if days < 0:
        return "Expired"
    return f"{days} days"


def _main_menu_warp_status_label() -> str:
    if _warp_mode_state_get() == "zerotrust":
        if not service_exists(WARP_ZEROTRUST_SERVICE):
            return "Zero Trust Missing"
        if service_state(WARP_ZEROTRUST_SERVICE) != "active":
            return "Zero Trust Inactive"
        return "Active (Zero Trust)"

    if not service_exists("wireproxy"):
        return "Not Installed"
    if service_state("wireproxy") != "active":
        return "Inactive"

    live = _warp_live_tier()
    if live == "plus":
        return "Active (Plus)"
    if live == "free":
        return "Active (Free)"
    return "Active"


def main_menu_header_text() -> str:
    global _MAIN_MENU_HEADER_CACHE_TEXT, _MAIN_MENU_HEADER_CACHE_TS

    now = time.time()
    if _MAIN_MENU_HEADER_CACHE_TEXT and (now - _MAIN_MENU_HEADER_CACHE_TS) < MAIN_MENU_HEADER_CACHE_TTL_SECONDS:
        return _MAIN_MENU_HEADER_CACHE_TEXT

    ip = _main_menu_ipv4_get()
    ip, isp, country = _main_menu_geo_lookup(ip)
    ok_uptime, uptime = run_cmd(["uptime", "-p"], timeout=8)
    lines = [
        f"{'System OS':<12} : {_main_menu_os_pretty()}",
        f"{'RAM':<12} : {memory_summary()}",
        f"{'Uptime':<12} : {uptime.splitlines()[0].strip() if ok_uptime and uptime.strip() else '-'}",
        f"{'IP VPS':<12} : {ip}",
        f"{'ISP':<12} : {isp}",
        f"{'Country':<12} : {country}",
        f"{'Domain':<12} : {detect_domain()}",
        f"{'TLS Expired':<12} : {_main_menu_tls_expiry_label()}",
        f"{'WARP Status':<12} : {_main_menu_warp_status_label()}",
    ]
    _MAIN_MENU_HEADER_CACHE_TEXT = "\n".join(lines)
    _MAIN_MENU_HEADER_CACHE_TS = now
    return _MAIN_MENU_HEADER_CACHE_TEXT


def service_state(name: str) -> str:
    ok, out = run_cmd(["systemctl", "is-active", name], timeout=8)
    if ok:
        return out.splitlines()[-1].strip()
    return out.splitlines()[-1].strip() if out.strip() else "unknown"


def service_exists(name: str, unit_type: str = "service") -> bool:
    unit = f"{name}.{unit_type}"
    ok, out = run_cmd(["systemctl", "list-unit-files", unit], timeout=8)
    if not ok:
        return False
    return unit in out


def systemctl_enabled_state(name: str) -> str:
    ok, out = run_cmd(["systemctl", "is-enabled", name], timeout=8)
    if ok:
        return out.splitlines()[-1].strip()
    return out.splitlines()[-1].strip() if out.strip() else "unknown"


def _extract_exit_code(raw: str) -> int | None:
    line = str(raw or "").splitlines()[0].strip() if str(raw or "").splitlines() else ""
    m = EXIT_CODE_RE.match(line)
    if not m:
        return None
    try:
        return int(m.group(1))
    except Exception:
        return None


def _tail_lines(path: Path, limit: int = 80) -> list[str]:
    if limit < 1:
        limit = 1
    try:
        lines = path.read_text(encoding="utf-8", errors="ignore").splitlines()
    except Exception:
        return []
    return lines[-limit:]


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


def _trim_message(text: str, limit: int = MESSAGE_SOFT_LIMIT) -> str:
    raw = str(text or "")
    if len(raw) <= limit:
        return raw
    if limit < 4:
        return raw[:limit]
    return raw[: limit - 3] + "..."


def _journal_tail(unit: str, lines: int = 40) -> str:
    safe_lines = max(1, min(int(lines), 120))
    ok, out = run_cmd(["journalctl", "-u", unit, "--no-pager", "-n", str(safe_lines)], timeout=20)
    if ok:
        return _trim_message(out)
    return _trim_message(f"Gagal membaca log {unit}:\n{out}")


def _journal_last_line(unit: str) -> str:
    ok, out = run_cmd(["journalctl", "-u", unit, "--no-pager", "-n", "1"], timeout=20)
    if not ok:
        return "-"
    lines = [line.strip() for line in out.splitlines() if line.strip()]
    return lines[-1] if lines else "-"


def _systemctl_show_props(name: str, props: list[str]) -> dict[str, str]:
    if not props:
        return {}
    argv = ["systemctl", "show", name]
    for prop in props:
        argv.extend(["-p", prop])
    ok, out = run_cmd(argv, timeout=12)
    if not ok:
        return {}
    data: dict[str, str] = {}
    for raw in out.splitlines():
        if "=" not in raw:
            continue
        key, value = raw.split("=", 1)
        data[key.strip()] = value.strip()
    return data


def _unit_status_line(name: str, *, unit_type: str = "service") -> str:
    if name.endswith(f".{unit_type}"):
        unit = name
        raw_name = name[: -len(f".{unit_type}")]
    else:
        unit = f"{name}.{unit_type}"
        raw_name = name

    if not service_exists(raw_name, unit_type=unit_type):
        return f"- {unit}: not installed"

    active = service_state(unit)
    enabled = systemctl_enabled_state(unit)
    return f"- {unit}: {active} / {enabled}"


def _detect_port_from_file(path: Path, pattern: str, fallback: int) -> int:
    if path.exists():
        try:
            text = path.read_text(encoding="utf-8", errors="ignore")
        except Exception:
            text = ""
        match = re.search(pattern, text, re.MULTILINE)
        if match:
            try:
                value = int(match.group(1))
            except Exception:
                value = 0
            if 1 <= value <= 65535:
                return value
    return fallback


def _sshws_dropbear_port() -> int:
    return _detect_port_from_file(SSHWS_DROPBEAR_UNIT, r"-p\s+127\.0\.0\.1:(\d+)", 22022)


def _sshws_stunnel_port() -> int:
    return _detect_port_from_file(SSHWS_STUNNEL_CONF, r"^\s*accept\s*=\s*127\.0\.0\.1:(\d+)", 22443)


def _sshws_proxy_port() -> int:
    return _detect_port_from_file(SSHWS_PROXY_UNIT, r"--listen-port\s+(\d+)", 10015)


def _listener_present(port: int, *, host: str = "") -> bool:
    if not shutil.which("ss"):
        return False
    ok, out = run_cmd(["ss", "-lntp"], timeout=8)
    if not ok:
        return False
    if host:
        return bool(re.search(rf"{re.escape(host)}:{int(port)}(?:\s|$)", out))
    return bool(re.search(rf":{int(port)}(?:\s|$)", out))


def _udp_listener_present(port: int) -> bool:
    if not shutil.which("ss"):
        return False
    ok, out = run_cmd(["ss", "-lnup"], timeout=8)
    if not ok:
        return False
    return bool(re.search(rf":{int(port)}(?:\s|$)", out))


def _read_env_map(path: Path) -> dict[str, str]:
    data: dict[str, str] = {}
    if not path.exists():
        return data
    try:
        lines = path.read_text(encoding="utf-8", errors="ignore").splitlines()
    except Exception:
        return data
    for raw in lines:
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        data[key.strip()] = value.strip()
    return data


def _edge_runtime_env_value(key: str, default: str = "") -> str:
    return _read_env_map(EDGE_RUNTIME_ENV_FILE).get(key, default)


def _edge_runtime_ports(list_key: str, single_key: str, default_list: str, default_single: str) -> list[int]:
    raw = _edge_runtime_env_value(list_key, "") or _edge_runtime_env_value(single_key, "")
    if not raw:
        raw = default_list or default_single
    values: list[int] = []
    seen: set[int] = set()
    for token in re.split(r"[\s,]+", raw.strip()):
        if not token or not token.isdigit():
            continue
        port = int(token)
        if port in seen:
            continue
        seen.add(port)
        values.append(port)
    return values


def _edge_runtime_ports_label(ports: list[int]) -> str:
    if not ports:
        return "-"
    return ", ".join(str(port) for port in ports)


def _ws_public_ports_label() -> str:
    return "443, 80"


def _edge_runtime_provider_name(default: str = "go") -> str:
    provider = _edge_runtime_env_value("EDGE_PROVIDER", default).strip().lower()
    return provider or default


def _badvpn_runtime_env_value(key: str, default: str = "") -> str:
    return _read_env_map(BADVPN_RUNTIME_ENV_FILE).get(key, default)


def _openvpn_env_value(key: str, default: str = "") -> str:
    return _read_env_map(OPENVPN_CONFIG_ENV_FILE).get(key, default)


def _openvpn_ws_proxy_port() -> int:
    return _to_int(_openvpn_env_value("OPENVPN_WS_PROXY_PORT", "10016"), 10016)


def _openvpn_ws_public_path() -> str:
    path = str(_openvpn_env_value("OPENVPN_WS_PUBLIC_PATH", "") or "").strip()
    if not path:
        return "-"
    if not path.startswith("/"):
        path = f"/{path}"
    return path


def _openvpn_ws_alt_path() -> str:
    path = _openvpn_ws_public_path()
    if path == "-":
        return "-"
    return f"/<bebas>/{path.lstrip('/')}/<bebas>"


def _openvpn_public_tcp_ports_label() -> str:
    ports = _edge_runtime_ports(
        "EDGE_PUBLIC_TLS_PORTS",
        "EDGE_PUBLIC_TLS_PORT",
        "443,2053,2083,2087,2096,8443",
        "443",
    ) + _edge_runtime_ports(
        "EDGE_PUBLIC_HTTP_PORTS",
        "EDGE_PUBLIC_HTTP_PORT",
        "80,8080,8880,2052,2082,2086,2095",
        "80",
    )
    merged: list[int] = []
    seen: set[int] = set()
    for port in ports:
        if port in seen:
            continue
        seen.add(port)
        merged.append(port)
    if not merged:
        tcp_port = _openvpn_env_value("OPENVPN_PUBLIC_PORT_TCP", _openvpn_env_value("OPENVPN_PORT_TCP", "1194")) or "1194"
        return str(tcp_port)
    return _edge_runtime_ports_label(merged)


def _sshws_runtime_env_value(key: str, default: str = "") -> str:
    return _read_env_map(SSHWS_RUNTIME_ENV_FILE).get(key, default)


def _edge_runtime_service_name() -> str:
    provider = _edge_runtime_provider_name("go")
    if provider == "nginx-stream":
        return "nginx"
    return "edge-mux"


def _badvpn_runtime_ports() -> list[int]:
    raw = _badvpn_runtime_env_value("BADVPN_UDPGW_PORTS", "7300 7400 7500 7600 7700 7800 7900")
    values: list[int] = []
    seen: set[int] = set()
    for token in re.split(r"[\s,]+", raw.strip()):
        if not token:
            continue
        try:
            port = int(token)
        except Exception:
            continue
        if not (1 <= port <= 65535) or port in seen:
            continue
        seen.add(port)
        values.append(port)
    return values


def _badvpn_runtime_ports_label() -> str:
    ports = _badvpn_runtime_ports()
    if not ports:
        return "-"
    return ", ".join(str(port) for port in ports)


def _probe_tcp_endpoint(host: str, port: int, *, tls_mode: bool = False) -> str:
    raw_sock = None
    sock = None
    try:
        raw_sock = socket.create_connection((host, int(port)), timeout=2.5)
        raw_sock.settimeout(2.5)
        if tls_mode:
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            sock = ctx.wrap_socket(raw_sock, server_hostname=host or "localhost")
        else:
            sock = raw_sock
        return "CONNECTED"
    except Exception as exc:
        detail = str(exc).strip() or exc.__class__.__name__
        return f"FAIL ({detail})"
    finally:
        try:
            if sock is not None:
                sock.close()
        except Exception:
            pass
        try:
            if raw_sock is not None and raw_sock is not sock:
                raw_sock.close()
        except Exception:
            pass


def _probe_ws_endpoint(
    host: str,
    port: int,
    *,
    path: str = "/",
    host_header: str = "",
    tls_mode: bool = False,
    sni: str = "",
) -> str:
    raw_sock = None
    sock = None
    try:
        raw_sock = socket.create_connection((host, int(port)), timeout=3.0)
        raw_sock.settimeout(3.0)
        if tls_mode:
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            sock = ctx.wrap_socket(raw_sock, server_hostname=sni or host or "localhost")
        else:
            sock = raw_sock

        request = (
            f"GET {path or '/'} HTTP/1.1\r\n"
            f"Host: {host_header or host}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            "Sec-WebSocket-Version: 13\r\n"
            f"Sec-WebSocket-Key: {base64.b64encode(str(time.time_ns()).encode('ascii', 'ignore')).decode('ascii', 'ignore')}\r\n"
            "User-Agent: bot-telegram/sshws-diagnostics\r\n"
            "\r\n"
        ).encode("ascii", "ignore")
        sock.sendall(request)

        buf = b""
        while b"\r\n\r\n" not in buf and len(buf) < 16384:
            chunk = sock.recv(4096)
            if not chunk:
                break
            buf += chunk
        if not buf:
            return "FAIL (empty-response)"

        line = buf.split(b"\r\n", 1)[0].decode("latin1", "replace").strip()
        parts = line.split(None, 2)
        if len(parts) >= 2 and parts[1].isdigit():
            code = parts[1]
            reason = parts[2] if len(parts) >= 3 else ""
            return f"HTTP {code}" + (f" {reason}" if reason else "")
        return f"FAIL ({line or 'bad-response'})"
    except Exception as exc:
        detail = str(exc).strip() or exc.__class__.__name__
        return f"FAIL ({detail})"
    finally:
        try:
            if sock is not None:
                sock.close()
        except Exception:
            pass
        try:
            if raw_sock is not None and raw_sock is not sock:
                raw_sock.close()
        except Exception:
            pass


def _service_group_restart(services: tuple[str, ...] | list[str], title: str) -> tuple[bool, str, str]:
    lines: list[str] = []
    attempted = 0
    had_failure = False
    for service in services:
        if not service_exists(service):
            lines.append(f"- {service}: skip (unit tidak ditemukan)")
            continue
        attempted += 1
        ok, state, out = _restart_service_checked(service, timeout=25)
        if ok:
            lines.append(f"- {service}: restarted ({state})")
        else:
            had_failure = True
            brief = out.splitlines()[-1].strip() if out else "unknown error"
            lines.append(f"- {service}: gagal ({state}) - {brief}")
    if attempted == 0:
        return False, title, "Tidak ada unit yang ditemukan."
    return (not had_failure), title, "\n".join(lines)


def _sshws_post_restart_health_check() -> tuple[bool, list[str]]:
    failed: list[str] = []
    dropbear_port = _sshws_dropbear_port()
    stunnel_port = _sshws_stunnel_port()
    proxy_port = _sshws_proxy_port()
    domain = detect_domain()
    probe_path = "/diagnostic-probe"

    if (service_exists("sshws-proxy") or service_exists("sshws-stunnel")) and not _listener_present(80):
        failed.append("port-80")
    if (service_exists("sshws-proxy") or service_exists("sshws-stunnel")) and not _listener_present(443):
        failed.append("port-443")
    if service_exists("sshws-dropbear") and not _probe_tcp_endpoint("127.0.0.1", dropbear_port).startswith("CONNECTED"):
        failed.append("dropbear")
    if service_exists("sshws-proxy") and not _probe_ws_endpoint(
        "127.0.0.1",
        proxy_port,
        path=probe_path,
        host_header=f"127.0.0.1:{proxy_port}",
    ).startswith("HTTP 101"):
        failed.append("ws-proxy")
    if service_exists("sshws-stunnel") and not _probe_tcp_endpoint("127.0.0.1", stunnel_port, tls_mode=True).startswith("CONNECTED"):
        failed.append("stunnel")
    if _listener_present(80):
        probe80 = _probe_ws_endpoint("127.0.0.1", 80, path=probe_path, host_header=domain or "127.0.0.1")
        if not probe80.startswith("HTTP 101"):
            failed.append("nginx-80")
    if domain and domain != "-" and _listener_present(443):
        probe443 = _probe_ws_endpoint("127.0.0.1", 443, path=probe_path, host_header=domain, tls_mode=True, sni=domain)
        if not probe443.startswith("HTTP 101"):
            failed.append("nginx-443")
    return (len(failed) == 0), failed


def _restart_service_checked(service: str, timeout: int = 25) -> tuple[bool, str, str]:
    ok, out = run_cmd(["systemctl", "restart", service], timeout=timeout)
    state = service_state(service)
    if not ok:
        return False, state, out
    if state != "active":
        return False, state, f"Service {service} tidak aktif setelah restart (state={state})."
    return True, state, out


def _reload_service_checked(service: str, timeout: int = 25) -> tuple[bool, str, str]:
    ok, out = run_cmd(["systemctl", "reload", service], timeout=timeout)
    state = service_state(service)
    if not ok:
        return False, state, out
    if state != "active":
        return False, state, f"Service {service} tidak aktif setelah reload (state={state})."
    return True, state, out


def _fail2ban_client_available() -> bool:
    return shutil.which("fail2ban-client") is not None


def _fail2ban_jails_list() -> list[str]:
    if not _fail2ban_client_available():
        return []
    ok, out = run_cmd(["fail2ban-client", "status"], timeout=20)
    if not ok or not out.strip():
        return []
    jail_line = ""
    for raw in out.splitlines():
        match = re.search(r"[Jj]ail list\s*:\s*(.+)", raw)
        if match:
            jail_line = match.group(1).strip()
            break
    if not jail_line:
        return []
    items: list[str] = []
    for item in jail_line.replace("\r", "").split(","):
        jail = item.strip()
        if jail and jail not in items:
            items.append(jail)
    return items


def _fail2ban_jail_counts(jail: str) -> tuple[int, int]:
    if not _fail2ban_client_available():
        return 0, 0
    ok, out = run_cmd(["fail2ban-client", "status", jail], timeout=20)
    if not ok:
        return 0, 0
    cur = 0
    total = 0
    for raw in out.splitlines():
        match_cur = re.search(r"Currently banned:\s*([0-9]+)", raw)
        if match_cur:
            cur = int(match_cur.group(1))
        match_total = re.search(r"Total banned:\s*([0-9]+)", raw)
        if match_total:
            total = int(match_total.group(1))
    return cur, total


def _fail2ban_total_banned() -> int:
    return sum(_fail2ban_jail_counts(jail)[0] for jail in _fail2ban_jails_list())


def _fail2ban_jail_active(jail: str) -> bool:
    if not _fail2ban_client_available():
        return False
    ok, _ = run_cmd(["fail2ban-client", "status", jail], timeout=20)
    return ok


def _tls_expiry_days_left() -> int | None:
    if not CERT_FULLCHAIN.exists():
        return None
    ok, out = run_cmd(["openssl", "x509", "-in", str(CERT_FULLCHAIN), "-noout", "-enddate"], timeout=10)
    if not ok:
        return None
    raw = out.splitlines()[-1].strip().replace("notAfter=", "", 1).strip()
    for fmt in ("%b %d %H:%M:%S %Y %Z", "%b %d %H:%M:%S %Y GMT"):
        try:
            expiry = datetime.strptime(raw, fmt)
            return (expiry.date() - _local_today()).days
        except Exception:
            continue
    return None


def op_status_overview() -> tuple[str, str]:
    ok_uptime, uptime = run_cmd(["uptime", "-p"], timeout=8)
    ok_kernel, kernel = run_cmd(["uname", "-sr"], timeout=8)
    ok_host, host = run_cmd(["hostname"], timeout=8)
    ok_ip, ip_raw = run_cmd(["ip", "-4", "-o", "addr", "show", "scope", "global"], timeout=8)

    ip = "-"
    if ok_ip:
        m = re.search(r"\binet\s+(\d+\.\d+\.\d+\.\d+)/", ip_raw)
        if m:
            ip = m.group(1)

    service_lines = [f"- {svc}: {service_state(svc)}" for svc in ALLOWED_SERVICES]
    msg = (
        "Ringkasan Sistem\n"
        f"- Hostname : {host if ok_host else '-'}\n"
        f"- Kernel   : {kernel if ok_kernel else '-'}\n"
        f"- Uptime   : {uptime if ok_uptime else '-'}\n"
        f"- RAM      : {memory_summary()}\n"
        f"- IPv4     : {ip}\n"
        f"- Domain   : {detect_domain()}\n"
        f"- TLS Exp  : {detect_tls_expiry()}\n\n"
        "Status Service\n"
        + "\n".join(service_lines)
    )
    return "Status & Diagnostics", msg


def op_xray_test() -> tuple[bool, str, str]:
    cmd = ["xray", "run", "-test", "-confdir", str(XRAY_CONFDIR)]
    ok, out = run_cmd(cmd, timeout=20)
    title = "Xray Config Test"

    lines = [line.strip() for line in str(out or "").splitlines() if line.strip()]
    deprec_re = re.compile(r"common/errors:\s*The feature .* is deprecated", re.IGNORECASE)
    deprec_lines = [line for line in lines if deprec_re.search(line)]
    normal_lines = [line for line in lines if not deprec_re.search(line) and not line.startswith("[exit ")]

    if ok:
        msg = (
            "SUCCESS\n"
            "- Konfigurasi Xray valid.\n"
            "- Detail log tidak ditampilkan di Telegram."
        )
        if deprec_lines:
            msg += (
                f"\n- Ditemukan {len(deprec_lines)} warning deprecation transport terdepresiasi "
                "(WS/HUP/gRPC/VMess/Trojan)."
            )
        return True, title, msg

    lower_out = str(out or "").lower()
    if "command tidak ditemukan: xray" in lower_out:
        return (
            False,
            title,
            "FAILED\n"
            "- Binary `xray` tidak ditemukan di host.\n"
            "- Periksa instalasi Xray dan PATH service backend.",
        )

    if "timeout:" in lower_out:
        return (
            False,
            title,
            "FAILED\n"
            "- Test config Xray timeout.\n"
            "- Coba ulang saat beban server lebih rendah atau cek health service xray.",
        )

    error_hint = normal_lines[0] if normal_lines else ""
    if len(error_hint) > 180:
        error_hint = error_hint[:177] + "..."

    msg = (
        "FAILED\n"
        "- Test config Xray gagal dijalankan atau konfigurasi tidak valid.\n"
        "- Detail log tidak ditampilkan di Telegram.\n"
        "- Cek manual di server: xray run -test -confdir /usr/local/etc/xray/conf.d"
    )
    if deprec_lines:
        msg += (
            f"\n- Catatan: terdeteksi {len(deprec_lines)} warning deprecation transport terdepresiasi."
        )
    if error_hint:
        msg += f"\n- Ringkasan error: {error_hint}"
    return False, title, msg


def op_tls_info() -> tuple[bool, str, str]:
    if not CERT_FULLCHAIN.exists():
        return False, "TLS Certificate Info", f"File tidak ada: {CERT_FULLCHAIN}"
    ok, out = run_cmd(
        [
            "openssl",
            "x509",
            "-in",
            str(CERT_FULLCHAIN),
            "-noout",
            "-subject",
            "-issuer",
            "-serial",
            "-startdate",
            "-enddate",
            "-fingerprint",
        ],
        timeout=10,
    )
    if ok:
        return True, "TLS Certificate Info", out
    return False, "TLS Certificate Info", f"Gagal membaca cert:\n{out}"


def op_domain_guard_check() -> tuple[bool, str, str]:
    title = "Domain & Cert Guard Check"
    if not XRAY_DOMAIN_GUARD_BIN.exists():
        return False, title, "xray-domain-guard belum terpasang. Jalankan setup.sh terbaru."

    ok, out = run_cmd([str(XRAY_DOMAIN_GUARD_BIN), "check"], timeout=180)
    rc = 0 if ok else _extract_exit_code(out)

    summary = "Check selesai."
    if rc == 0:
        summary = "Domain & cert sehat."
    elif rc == 1:
        summary = "Check selesai: warning terdeteksi."
    elif rc == 2:
        summary = "Check selesai: kondisi critical terdeteksi."
    elif rc is not None:
        summary = f"Check selesai dengan status {rc}."

    lines = [
        summary,
        f"Config path : {XRAY_DOMAIN_GUARD_CONFIG_FILE}",
        f"Log path    : {XRAY_DOMAIN_GUARD_LOG_FILE}",
    ]
    if out and out != "(no output)":
        out_lines = [line for line in out.splitlines() if line.strip() and not line.strip().startswith("[exit ")]
        if out_lines:
            lines.extend(["", "Command output:", *out_lines[:40]])
    msg = "\n".join(lines)
    if rc in (None, 0):
        return True, title, msg
    return False, title, msg


def op_domain_guard_status() -> tuple[bool, str, str]:
    title = "Domain & Cert Guard Status"
    if not XRAY_DOMAIN_GUARD_BIN.exists():
        return False, title, "xray-domain-guard belum terpasang. Jalankan setup.sh terbaru."

    lines = [
        f"Binary       : {XRAY_DOMAIN_GUARD_BIN}",
        f"Config path  : {XRAY_DOMAIN_GUARD_CONFIG_FILE}",
        f"Log path     : {XRAY_DOMAIN_GUARD_LOG_FILE}",
        "",
        f"Timer active : {service_state('xray-domain-guard.timer')}",
        f"Timer enable : {systemctl_enabled_state('xray-domain-guard.timer')}",
        f"Svc active   : {service_state('xray-domain-guard.service')}",
    ]

    if XRAY_DOMAIN_GUARD_LOG_FILE.exists():
        log_tail = _tail_lines(XRAY_DOMAIN_GUARD_LOG_FILE, limit=24)
        if log_tail:
            lines.extend(["", "Domain guard log (tail):", *log_tail])

    return True, title, "\n".join(lines)


def op_domain_guard_renew_if_needed(force: bool = False) -> tuple[bool, str, str]:
    title = "Domain & Cert Guard Renew-if-Needed"
    if not XRAY_DOMAIN_GUARD_BIN.exists():
        return False, title, "xray-domain-guard belum terpasang. Jalankan setup.sh terbaru."

    cmd = [str(XRAY_DOMAIN_GUARD_BIN), "renew-if-needed"]
    if force:
        cmd.append("--force")
    ok, out = run_cmd(cmd, timeout=300)
    rc = 0 if ok else _extract_exit_code(out)

    summary = "Renew-if-needed selesai."
    if rc == 0:
        summary = "Renew-if-needed selesai, status sehat."
    elif rc == 1:
        summary = "Renew-if-needed selesai dengan warning."
    elif rc == 2:
        summary = "Renew-if-needed selesai namun masih ada kondisi critical."
    elif rc is not None:
        summary = f"Renew-if-needed selesai dengan status {rc}."

    lines = [summary, f"Log path: {XRAY_DOMAIN_GUARD_LOG_FILE}"]
    if out and out != "(no output)":
        out_lines = [line for line in out.splitlines() if line.strip() and not line.strip().startswith("[exit ")]
        if out_lines:
            lines.extend(["", "Command output:", *out_lines[:40]])
    msg = "\n".join(lines)
    if rc in (None, 0):
        return True, title, msg
    return False, title, msg


def _normalize_protocol_filter(protocols: tuple[str, ...] | list[str] | set[str] | None) -> tuple[str, ...]:
    if protocols is None:
        return USER_PROTOCOLS
    selected: list[str] = []
    for proto in protocols:
        proto_n = str(proto).strip().lower()
        if proto_n in QAC_PROTOCOLS and proto_n not in selected:
            selected.append(proto_n)
    return tuple(selected)


def list_accounts(protocols: tuple[str, ...] | list[str] | set[str] | None = None) -> list[tuple[str, str]]:
    protocol_list = _normalize_protocol_filter(protocols)
    records: list[tuple[str, str]] = []
    for proto in protocol_list:
        d = ACCOUNT_ROOT / proto
        if not d.exists():
            continue
        selected: dict[str, Path] = {}
        selected_has_at: dict[str, bool] = {}
        for path in sorted(d.glob("*.txt")):
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
        for username in sorted(selected.keys()):
            records.append((proto, username))
    return records


def _protocols_text(protocols: tuple[str, ...]) -> str:
    return ",".join(protocols)


def op_user_list(
    protocols: tuple[str, ...] | list[str] | set[str] | None = None,
    *,
    title: str = "User Management - List",
) -> tuple[str, str]:
    protocol_list = _normalize_protocol_filter(protocols)
    records = list_accounts(protocol_list)
    if not records:
        return title, f"Tidak ada data di {ACCOUNT_ROOT}/{{{_protocols_text(protocol_list)}}}"

    counts = {p: 0 for p in protocol_list}
    for proto, _ in records:
        counts[proto] += 1

    lines = [f"{i+1:03d}. {user} [{proto}]" for i, (proto, user) in enumerate(records[:250])]
    protocol_lines = "\n".join([f"- {proto}: {counts[proto]}" for proto in protocol_list])
    body = (
        f"Total user: {len(records)}\n"
        f"{protocol_lines}\n\n"
        "Daftar (maks 250):\n"
        + "\n".join(lines)
    )
    return title, body


def op_user_search(
    query: str,
    protocols: tuple[str, ...] | list[str] | set[str] | None = None,
    *,
    title: str = "User Management - Search",
) -> tuple[str, str]:
    q = query.lower().strip()
    records = list_accounts(protocols)
    hits = [(proto, user) for proto, user in records if q in user.lower()]
    if not hits:
        return title, f"Tidak ada user cocok dengan query: {query}"
    lines = [f"{i+1:03d}. {user} [{proto}]" for i, (proto, user) in enumerate(hits[:250])]
    return title, f"Hasil: {len(hits)}\n\n" + "\n".join(lines)


def _quota_candidates(proto: str, username: str) -> list[Path]:
    return [
        QUOTA_ROOT / proto / f"{username}@{proto}.json",
        QUOTA_ROOT / proto / f"{username}.json",
    ]


def _account_candidates(proto: str, username: str) -> list[Path]:
    return [
        ACCOUNT_ROOT / proto / f"{username}@{proto}.txt",
        ACCOUNT_ROOT / proto / f"{username}.txt",
    ]


def _is_valid_username(username: str) -> bool:
    return bool(USERNAME_RE.match(username))


def _is_valid_ssh_username(username: str) -> bool:
    return bool(SSH_USERNAME_RE.match(username))


def _account_info_label(proto: str) -> str:
    if proto == SSH_PROTOCOL:
        return "SSH ACCOUNT INFO"
    if proto == OPENVPN_POLICY_PROTOCOL:
        return "OPENVPN ACCOUNT INFO"
    return "XRAY ACCOUNT INFO"


def _to_int(v: object, default: int = 0) -> int:
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


def _to_float(v: object, default: float = 0.0) -> float:
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


def _fmt_number(value: float) -> str:
    if value <= 0:
        return "0"
    if abs(value - round(value)) < 1e-9:
        return str(int(round(value)))
    return f"{value:.3f}".rstrip("0").rstrip(".")


def _fmt_quota_limit_gb(data: dict) -> str:
    quota_limit = _to_int(data.get("quota_limit"), 0)
    if quota_limit <= 0:
        return "0 GB"
    unit = str(data.get("quota_unit") or "binary").strip().lower()
    bpg = 1000**3 if unit in QUOTA_UNIT_DECIMAL else 1024**3
    return f"{_fmt_number(quota_limit / bpg)} GB"


def _fmt_quota_used(data: dict) -> str:
    used = _to_int(data.get("quota_used"), 0)
    if used < 0:
        used = 0
    if used >= 1024**3:
        return f"{used / (1024**3):.2f} GB"
    if used >= 1024**2:
        return f"{used / (1024**2):.2f} MB"
    if used >= 1024:
        return f"{used / 1024:.2f} KB"
    return f"{used} B"


def _status_block_reason(status: dict) -> str:
    lock_reason = str(status.get("lock_reason") or "").strip().lower()
    if bool(status.get("manual_block")) or lock_reason == "manual":
        return "MANUAL"
    if bool(status.get("quota_exhausted")) or lock_reason == "quota":
        return "QUOTA"
    if bool(status.get("ip_limit_locked")) or lock_reason == "ip_limit":
        return "IP_LIMIT"
    return "-"


def _status_ip_limit(status: dict) -> str:
    enabled = bool(status.get("ip_limit_enabled"))
    limit = _to_int(status.get("ip_limit"), 0)
    if not enabled:
        return "OFF"
    return f"ON({limit})" if limit > 0 else "ON"


def _status_speed_limit(status: dict) -> str:
    enabled = bool(status.get("speed_limit_enabled"))
    if not enabled:
        return "OFF"
    down = _to_float(status.get("speed_down_mbit"), 0.0)
    up = _to_float(status.get("speed_up_mbit"), 0.0)
    if down <= 0 or up <= 0:
        return "OFF"
    return f"ON({_fmt_number(down)}/{_fmt_number(up)} Mbps)"


def _fmt_active_period(data: dict) -> str:
    expired_at = str(data.get("expired_at") or "").strip()[:10]
    if not expired_at:
        return "-"
    try:
        exp_date = datetime.strptime(expired_at, "%Y-%m-%d").date()
        remain = max(0, (exp_date - _local_today()).days)
        return f"{remain} hari (sampai {expired_at})"
    except Exception:
        return expired_at


def _read_account_fields(path: Path) -> dict[str, str]:
    fields: dict[str, str] = {}
    if not path.exists():
        return fields
    try:
        for raw in path.read_text(encoding="utf-8", errors="ignore").splitlines():
            if ":" not in raw:
                continue
            key, value = raw.split(":", 1)
            fields[key.strip()] = value.strip()
    except Exception:
        return {}
    return fields


def _fmt_active_period_from_account_fields(fields: dict[str, str]) -> str:
    valid_until = str(fields.get("Valid Until") or "").strip()[:10]
    if valid_until:
        try:
            exp_date = datetime.strptime(valid_until, "%Y-%m-%d").date()
            remain = max(0, (exp_date - _local_today()).days)
            return f"{remain} hari (sampai {valid_until})"
        except Exception:
            return valid_until

    expired_raw = str(fields.get("Expired") or "").strip()
    if not expired_raw:
        return "-"
    match = re.search(r"(\d+)", expired_raw)
    if not match:
        return expired_raw
    try:
        days = max(0, int(match.group(1)))
    except Exception:
        return expired_raw
    return f"{days} hari"


def _fmt_quota_limit_from_account_fields(fields: dict[str, str]) -> str:
    quota_raw = str(fields.get("Quota Limit") or "").strip()
    if not quota_raw:
        return "0 GB"
    match = re.search(r"([0-9]+(?:\.[0-9]+)?)", quota_raw)
    if not match:
        return quota_raw
    try:
        return f"{_fmt_number(float(match.group(1)))} GB"
    except Exception:
        return quota_raw


def _fmt_ip_limit_from_account_fields(fields: dict[str, str]) -> str:
    ip_raw = str(fields.get("IP Limit") or "").strip()
    if not ip_raw:
        return "OFF"
    if ip_raw.upper().startswith("OFF"):
        return "OFF"
    match = re.search(r"ON\s*\((\d+)\)", ip_raw, re.IGNORECASE)
    if match:
        return f"ON({match.group(1)})"
    if ip_raw.upper().startswith("ON"):
        return "ON"
    return ip_raw


def _fmt_speed_limit_from_account_fields(fields: dict[str, str]) -> str:
    speed_raw = str(fields.get("Speed Limit") or "").strip()
    if not speed_raw:
        return "OFF"
    if speed_raw.upper().startswith("OFF"):
        return "OFF"
    down_match = re.search(r"DOWN\s*([0-9]+(?:\.[0-9]+)?)", speed_raw, re.IGNORECASE)
    up_match = re.search(r"UP\s*([0-9]+(?:\.[0-9]+)?)", speed_raw, re.IGNORECASE)
    if down_match and up_match:
        try:
            down = _fmt_number(float(down_match.group(1)))
            up = _fmt_number(float(up_match.group(1)))
            return f"ON({down}/{up} Mbps)"
        except Exception:
            return speed_raw
    return speed_raw


def _iter_proto_quota_files(proto: str) -> list[tuple[str, Path]]:
    d = QUOTA_ROOT / proto
    if not d.exists():
        return []

    selected: dict[str, Path] = {}
    selected_has_at: dict[str, bool] = {}
    for path in sorted(d.glob("*.json")):
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
    return [(u, selected[u]) for u in sorted(selected.keys())]


def _pick_field(data: dict, keys: list[str], default: str = "-") -> str:
    for key in keys:
        if key in data and data[key] not in (None, ""):
            return str(data[key])
    return default


def op_quota_summary(
    protocols: tuple[str, ...] | list[str] | set[str] | None = None,
    *,
    title: str = "Quota & Access Control - Summary",
) -> tuple[str, str]:
    protocol_list = _normalize_protocol_filter(protocols)
    lines: list[str] = []
    count = 0
    for proto in protocol_list:
        for username, path in _iter_proto_quota_files(proto):
            ok, payload = read_json(path)
            if not ok:
                lines.append(f"- {proto}/{path.name}: invalid json")
                count += 1
                continue

            data = payload if isinstance(payload, dict) else {}
            status = data.get("status") if isinstance(data.get("status"), dict) else {}
            exp = str(_pick_field(data, ["expired_at", "expired", "expiry", "expires"]))[:10]
            quota = _fmt_quota_limit_gb(data)
            used = _fmt_quota_used(data)
            ip_limit = _status_ip_limit(status)
            speed_limit = _status_speed_limit(status)
            block = _status_block_reason(status)
            lines.append(
                f"- {username} [{proto}] limit={quota} used={used} exp={exp} ip={ip_limit} speed={speed_limit} block={block}"
            )
            count += 1
            if count >= 200:
                break
        if count >= 200:
            break

    if not lines:
        return title, f"Tidak ada file quota di {QUOTA_ROOT}/{{{_protocols_text(protocol_list)}}}"
    return title, "Maks 200 entri:\n" + "\n".join(lines)


def op_quota_detail(proto: str, username: str) -> tuple[str, str]:
    if proto not in QAC_PROTOCOLS:
        return "Quota & Access Control - Detail", f"Proto tidak valid: {proto}"
    if proto == SSH_PROTOCOL:
        if not _is_valid_ssh_username(username):
            return "Quota & Access Control - Detail", "Username SSH tidak valid. Gunakan huruf kecil/angka/_/-."
    elif not _is_valid_username(username):
        return "Quota & Access Control - Detail", "Username tidak valid. Gunakan huruf/angka/._- tanpa spasi."
    for candidate in _quota_candidates(proto, username):
        if not candidate.exists():
            continue
        ok, payload = read_json(candidate)
        if not ok:
            return "Quota & Access Control - Detail", str(payload)
        parts = [f"Quota File: {candidate}", "", json.dumps(payload, indent=2, ensure_ascii=False)]

        account_file = next((p for p in _account_candidates(proto, username) if p.exists()), None)
        account_label = _account_info_label(proto)
        if account_file is not None:
            try:
                account_text = account_file.read_text(encoding="utf-8", errors="ignore").strip()
            except Exception as exc:
                account_text = f"Gagal membaca {account_file}: {exc}"
            parts.extend(
                [
                    "",
                    f"{account_label} File: {account_file}",
                    "",
                    account_text or "(kosong)",
                ]
            )
        else:
            if proto == OPENVPN_POLICY_PROTOCOL:
                parts.extend(["", "OPENVPN ACCOUNT INFO: memakai linked profile .ovpn, tidak ada file txt terpisah di /opt/account"])
            else:
                parts.extend(["", f"{account_label}: file tidak ditemukan di /opt/account"])

        return "Quota & Access Control - Detail", "\n".join(parts)
    return "Quota & Access Control - Detail", f"File quota tidak ditemukan untuk {username} [{proto}]"


def op_account_info(proto: str, username: str) -> tuple[str, str]:
    proto_n = proto.lower().strip()
    user_n = username.strip()
    if proto_n not in USER_PROTOCOLS:
        return "User Management - Account Info", f"Proto tidak valid: {proto}"
    if proto_n == SSH_PROTOCOL:
        if not _is_valid_ssh_username(user_n):
            return "User Management - Account Info", "Username SSH tidak valid. Gunakan huruf kecil/angka/_/-."
    elif not _is_valid_username(user_n):
        return "User Management - Account Info", "Username tidak valid. Gunakan huruf/angka/._- tanpa spasi."

    for candidate in _account_candidates(proto_n, user_n):
        if not candidate.exists():
            continue
        try:
            content = candidate.read_text(encoding="utf-8", errors="ignore").strip()
        except Exception as exc:
            return "User Management - Account Info", f"Gagal membaca file {candidate}: {exc}"
        if not content:
            content = "(kosong)"
        if proto_n == SSH_PROTOCOL:
            lines = [
                f"Username : {user_n}",
                f"File     : {candidate}",
                "",
                content,
            ]
            return "User Management - Account Info", "\n".join(lines)
        lines = [
            f"Username : {user_n}",
            f"Protocol : {proto_n}",
            f"File     : {candidate}",
            "",
            content,
        ]
        return "User Management - Account Info", "\n".join(lines)
    return "User Management - Account Info", f"File account tidak ditemukan untuk {user_n} [{proto_n}]"


def op_account_info_summary(proto: str, username: str) -> tuple[bool, dict[str, str] | str]:
    proto_n = proto.lower().strip()
    user_n = username.strip()
    if proto_n not in QAC_PROTOCOLS:
        return False, f"Proto tidak valid: {proto}"
    if proto_n == SSH_PROTOCOL:
        if not _is_valid_ssh_username(user_n):
            return False, "Username SSH tidak valid. Gunakan huruf kecil/angka/_/-."
    elif not _is_valid_username(user_n):
        return False, "Username tidak valid. Gunakan huruf/angka/._- tanpa spasi."

    for candidate in _quota_candidates(proto_n, user_n):
        if not candidate.exists():
            continue
        ok, payload = read_json(candidate)
        if not ok:
            return False, str(payload)
        if not isinstance(payload, dict):
            return False, f"Format quota tidak valid: {candidate}"
        status = payload.get("status") if isinstance(payload.get("status"), dict) else {}
        return True, {
            "username": user_n,
            "protocol": proto_n,
            "active_period": _fmt_active_period(payload),
            "quota_gb": _fmt_quota_limit_gb(payload),
            "ip_limit": _status_ip_limit(status),
            "speed_limit": _status_speed_limit(status),
        }
    for candidate in _account_candidates(proto_n, user_n):
        if not candidate.exists():
            continue
        fields = _read_account_fields(candidate)
        if not fields:
            continue
        protocol = str(fields.get("Protocol") or proto_n).strip().lower()
        if protocol not in USER_PROTOCOLS:
            protocol = proto_n
        return True, {
            "username": str(fields.get("Username") or user_n).strip() or user_n,
            "protocol": protocol,
            "active_period": _fmt_active_period_from_account_fields(fields),
            "quota_gb": _fmt_quota_limit_from_account_fields(fields),
            "ip_limit": _fmt_ip_limit_from_account_fields(fields),
            "speed_limit": _fmt_speed_limit_from_account_fields(fields),
        }
    return False, f"File quota/account tidak ditemukan untuk {user_n} [{proto_n}]"


def op_qac_user_summary(proto: str, username: str) -> tuple[bool, dict[str, str] | str]:
    proto_n = proto.lower().strip()
    user_n = username.strip()
    if proto_n not in QAC_PROTOCOLS:
        return False, f"Proto tidak valid: {proto}"
    if proto_n == SSH_PROTOCOL:
        if not _is_valid_ssh_username(user_n):
            return False, "Username SSH tidak valid. Gunakan huruf kecil/angka/_/-."
    elif not _is_valid_username(user_n):
        return False, "Username tidak valid. Gunakan huruf/angka/._- tanpa spasi."

    for candidate in _quota_candidates(proto_n, user_n):
        if not candidate.exists():
            continue
        ok, payload = read_json(candidate)
        if not ok:
            return False, str(payload)
        if not isinstance(payload, dict):
            return False, f"Format quota tidak valid: {candidate}"

        status = payload.get("status") if isinstance(payload.get("status"), dict) else {}
        expired_at = str(_pick_field(payload, ["expired_at", "expired", "expiry", "expires"]))[:10] or "-"
        ip_limit_enabled = bool(status.get("ip_limit_enabled"))
        speed_limit_enabled = bool(status.get("speed_limit_enabled"))
        speed_down = _fmt_number(_to_float(status.get("speed_down_mbit"), 0.0))
        speed_up = _fmt_number(_to_float(status.get("speed_up_mbit"), 0.0))
        username_display = f"{user_n}@{proto_n}" if proto_n not in {SSH_PROTOCOL, OPENVPN_POLICY_PROTOCOL} else user_n
        summary = {
            "username": username_display,
            "quota_limit": _fmt_quota_limit_gb(payload),
            "quota_used": _fmt_quota_used(payload),
            "expired_at": expired_at,
            "ip_limit": "ON" if ip_limit_enabled else "OFF",
            "block_reason": _status_block_reason(status),
            "ip_limit_max": str(max(0, _to_int(status.get("ip_limit"), 0))),
            "speed_download": f"{speed_down} Mbps",
            "speed_upload": f"{speed_up} Mbps",
            "speed_limit": "ON" if speed_limit_enabled else "OFF",
        }
        if proto_n == SSH_PROTOCOL:
            distinct_ips_raw = status.get("distinct_ips") if isinstance(status.get("distinct_ips"), list) else []
            distinct_ips = [str(item).strip() for item in distinct_ips_raw if str(item).strip()]
            summary.update(
                {
                    "distinct_ip_count": str(max(0, _to_int(status.get("distinct_ip_count"), 0))),
                    "distinct_ips": ", ".join(distinct_ips) if distinct_ips else "-",
                    "ip_limit_metric": str(max(0, _to_int(status.get("ip_limit_metric"), 0))),
                    "account_locked": "ON" if bool(status.get("account_locked")) else "OFF",
                    "active_sessions_total": str(max(0, _to_int(status.get("active_sessions_total"), 0))),
                }
            )
        elif proto_n == OPENVPN_POLICY_PROTOCOL:
            distinct_ips_raw = status.get("distinct_ips") if isinstance(status.get("distinct_ips"), list) else []
            distinct_ips = [str(item).strip() for item in distinct_ips_raw if str(item).strip()]
            summary.update(
                {
                    "distinct_ip_count": str(max(0, _to_int(status.get("distinct_ip_count"), 0))),
                    "distinct_ips": ", ".join(distinct_ips) if distinct_ips else "-",
                    "ip_limit_metric": str(max(0, _to_int(status.get("ip_limit_metric"), 0))),
                    "account_locked": "ON" if bool(status.get("account_locked")) else "OFF",
                    "active_sessions_total": str(max(0, _to_int(status.get("active_sessions_total"), 0))),
                }
            )

        return True, summary

    return False, f"File quota tidak ditemukan untuk {user_n} [{proto_n}]"


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


def op_dns_summary() -> tuple[str, str]:
    dns_file = XRAY_CONFDIR / "02-dns.json"
    ok, payload = read_json(dns_file)
    if not ok:
        return "Network Controls - DNS", str(payload)
    if not isinstance(payload, dict):
        return "Network Controls - DNS", f"Format DNS tidak valid di {dns_file}"

    dns_obj = payload.get("dns", {})
    if not isinstance(dns_obj, dict):
        return "Network Controls - DNS", f"Objek dns tidak ditemukan di {dns_file}"

    query_strategy = dns_obj.get("queryStrategy", "-")
    servers = dns_obj.get("servers", [])
    hosts = dns_obj.get("hosts", {})

    lines = [f"queryStrategy: {query_strategy}", "servers:"]
    if isinstance(servers, list):
        for item in servers[:30]:
            lines.append(f"- {item}")
    if isinstance(hosts, dict):
        lines.append(f"hosts entries: {len(hosts)}")

    return "Network Controls - DNS", "\n".join(lines)


def op_network_state_raw() -> tuple[str, str]:
    if not NETWORK_STATE_FILE.exists():
        return "Network Controls - State File", f"File tidak ditemukan: {NETWORK_STATE_FILE}"
    ok, payload = read_json(NETWORK_STATE_FILE)
    if not ok:
        return "Network Controls - State File", str(payload)
    return "Network Controls - State File", json.dumps(payload, indent=2, ensure_ascii=False)


def _adblock_env_value(key: str, default: str = "") -> str:
    try:
        if not ADBLOCK_ENV_FILE.exists():
            return default
        for raw in ADBLOCK_ENV_FILE.read_text(encoding="utf-8", errors="ignore").splitlines():
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            env_key, env_value = line.split("=", 1)
            if env_key.strip() == key:
                value = env_value.strip()
                return value if value else default
    except Exception:
        return default
    return default


def _adblock_blocklist_file() -> Path:
    return Path(_adblock_env_value("SSH_DNS_ADBLOCK_BLOCKLIST_FILE", str(ADBLOCK_DEFAULT_BLOCKLIST)))


def _adblock_urls_file() -> Path:
    return Path(_adblock_env_value("SSH_DNS_ADBLOCK_URLS_FILE", str(ADBLOCK_DEFAULT_URLS)))


def list_adblock_manual_domains() -> list[str]:
    path = _adblock_blocklist_file()
    if not path.exists():
        return []
    seen: set[str] = set()
    domains: list[str] = []
    try:
        for raw in path.read_text(encoding="utf-8", errors="ignore").splitlines():
            line = str(raw or "").strip().lower().rstrip(".")
            if not line or line.startswith("#"):
                continue
            if line.startswith("*."):
                line = line[2:]
            if " " in line or "/" in line or ".." in line or "." not in line:
                continue
            if line in seen:
                continue
            seen.add(line)
            domains.append(line)
    except Exception:
        return []
    return domains


def list_adblock_url_sources() -> list[str]:
    path = _adblock_urls_file()
    if not path.exists():
        return []
    seen: set[str] = set()
    urls: list[str] = []
    try:
        for raw in path.read_text(encoding="utf-8", errors="ignore").splitlines():
            line = str(raw or "").strip()
            if not line or line.startswith("#"):
                continue
            if not line.startswith(("http://", "https://")):
                continue
            if line in seen:
                continue
            seen.add(line)
            urls.append(line)
    except Exception:
        return []
    return urls


def _adblock_status_map() -> dict[str, str]:
    if not ADBLOCK_SYNC_BIN.exists():
        return {
            "enabled": "0",
            "dirty": "0",
            "dns_service": "missing",
            "sync_service": "missing",
            "nft_table": "absent",
            "bound_users": "0",
            "users_count": "0",
            "manual_domains": str(len(list_adblock_manual_domains())),
            "merged_domains": "0",
            "blocklist_entries": "0",
            "source_urls": str(len(list_adblock_url_sources())),
            "dns_port": "5353",
            "rendered_file": "missing",
            "custom_dat": "missing",
            "auto_update_enabled": "0",
            "auto_update_service": "missing",
            "auto_update_timer": "missing",
            "auto_update_days": "1",
            "auto_update_schedule": "every 1 day(s)",
            "last_update": "-",
            "blocklist_file": str(_adblock_blocklist_file()),
            "urls_file": str(_adblock_urls_file()),
        }
    ok, out = run_cmd([str(ADBLOCK_SYNC_BIN), "--status"], timeout=25)
    if not ok:
        return {
            "enabled": "0",
            "dirty": "0",
            "dns_service": "error",
            "sync_service": "error",
            "nft_table": "absent",
            "bound_users": "0",
            "users_count": "0",
            "manual_domains": str(len(list_adblock_manual_domains())),
            "merged_domains": "0",
            "blocklist_entries": "0",
            "source_urls": str(len(list_adblock_url_sources())),
            "dns_port": "5353",
            "rendered_file": "missing",
            "custom_dat": "missing",
            "auto_update_enabled": "0",
            "auto_update_service": "error",
            "auto_update_timer": "error",
            "auto_update_days": "1",
            "auto_update_schedule": "every 1 day(s)",
            "last_update": f"error: {out.splitlines()[0] if out else 'status failed'}",
            "blocklist_file": str(_adblock_blocklist_file()),
            "urls_file": str(_adblock_urls_file()),
        }

    status: dict[str, str] = {}
    for raw in out.splitlines():
        line = str(raw or "").strip()
        if not line or "=" not in line:
            continue
        key, value = line.split("=", 1)
        status[key.strip()] = value.strip()

    def _looks_like_service_state(value: str) -> bool:
        return str(value or "").strip().lower() in {
            "active",
            "inactive",
            "failed",
            "activating",
            "deactivating",
            "reloading",
            "unknown",
            "missing",
            "not-found",
        }

    if _looks_like_service_state(status.get("dns_service", "")) and not status.get("dns_service_state"):
        status["dns_service_state"] = status["dns_service"]
        status["dns_service"] = "ssh-adblock-dns.service"
    if _looks_like_service_state(status.get("sync_service", "")) and not status.get("sync_service_state"):
        status["sync_service_state"] = status["sync_service"]
        status["sync_service"] = "adblock-sync.service"
    if _looks_like_service_state(status.get("auto_update_service", "")) and not status.get("auto_update_service_state"):
        status["auto_update_service_state"] = status["auto_update_service"]
        status["auto_update_service"] = "adblock-update.service"
    return status


def _adblock_xray_rule_enabled() -> bool:
    src = XRAY_CONFDIR / "30-routing.json"
    ok, payload = read_json(src)
    if not ok or not isinstance(payload, dict):
        return False
    rules = ((payload.get("routing") or {}).get("rules") or [])
    if not isinstance(rules, list):
        return False
    for item in rules:
        if not isinstance(item, dict):
            continue
        if item.get("type") != "field":
            continue
        domains = item.get("domain")
        if not isinstance(domains, list):
            continue
        if any(isinstance(val, str) and val.strip() == "ext:custom.dat:adblock" for val in domains):
            return True
    return False


def op_network_adblock_status() -> tuple[str, str]:
    title = "Network - Adblock Status"
    st = _adblock_status_map()
    xray_rule = "ON" if _adblock_xray_rule_enabled() else "OFF"
    auto_update = "ON" if st.get("auto_update_enabled", "0") == "1" else "OFF"
    lines = [
        f"Status       : {'ON' if xray_rule == 'ON' and st.get('enabled', '0') == '1' else ('PARTIAL' if xray_rule == 'ON' or st.get('enabled', '0') == '1' else 'OFF')}",
        f"Dirty        : {'YES' if st.get('dirty', '0') == '1' else 'NO'}",
        f"Manual List  : {st.get('manual_domains', '0')} domain",
        f"URL Sources  : {st.get('source_urls', '0')}",
        f"Merged List  : {st.get('merged_domains', '0')} domain",
        f"Auto Update  : {auto_update}",
        f"Update Svc   : {st.get('auto_update_service', '-')}",
        f"Update State : {st.get('auto_update_service_state', '-')}",
        f"Update Timer : {st.get('auto_update_timer', '-')}",
        f"Interval     : {st.get('auto_update_days', '1')} day(s)",
        f"Schedule     : {st.get('auto_update_schedule', '-')}",
        f"Last Update  : {st.get('last_update', '-')}",
        "",
        f"Xray Rule    : {xray_rule}",
        f"Xray Asset   : {st.get('custom_dat', '-')}",
        "Rule Entry   : ext:custom.dat:adblock",
        "",
        f"DNS Service  : {st.get('dns_service', '-')}",
        f"DNS State    : {st.get('dns_service_state', '-')}",
        f"Sync Service : {st.get('sync_service', '-')}",
        f"Sync State   : {st.get('sync_service_state', '-')}",
        f"NFT Table    : {st.get('nft_table', '-')}",
        f"Managed Users: {st.get('users_count', '0')}",
        f"Blocklist    : {st.get('blocklist_entries', '0')} entries",
        f"DNS Asset    : {st.get('rendered_file', '-')}",
        f"DNS Port     : {st.get('dns_port', '-')}",
    ]
    return title, "\n".join(lines)


def op_network_adblock_bound_users() -> tuple[str, str]:
    title = "Network - Adblock Bound Users"
    if not ADBLOCK_SYNC_BIN.exists():
        return title, "adblock-sync tidak ditemukan."
    ok, out = run_cmd([str(ADBLOCK_SYNC_BIN), "--show-users"], timeout=20)
    if not ok:
        return title, out
    rows = []
    for raw in out.splitlines():
        line = str(raw or "").strip()
        if not line or "|" not in line:
            continue
        username, uid = line.split("|", 1)
        rows.append((username.strip(), uid.strip()))
    if not rows:
        return title, "Belum ada user SSH terkelola yang terikat ke SSH Adblock."
    lines = ["Username             UID", "-------------------- --------"]
    for username, uid in rows:
        lines.append(f"{username:<20} {uid}")
    return title, "\n".join(lines)


def list_inbound_tags() -> list[str]:
    src = XRAY_CONFDIR / "10-inbounds.json"
    ok, payload = read_json(src)
    if not ok or not isinstance(payload, dict):
        return []

    out: list[str] = []
    seen: set[str] = set()
    inbounds = payload.get("inbounds")
    if not isinstance(inbounds, list):
        return []

    for item in inbounds:
        if not isinstance(item, dict):
            continue
        tag = str(item.get("tag") or "").strip()
        if not tag or tag == "api" or tag in seen:
            continue
        seen.add(tag)
        out.append(tag)
    out.sort()
    return out


def list_warp_domain_options(mode: str | None = None) -> list[str]:
    src = XRAY_CONFDIR / "30-routing.json"
    ok, payload = read_json(src)
    if not ok or not isinstance(payload, dict):
        return []

    routing = payload.get("routing")
    rules = routing.get("rules") if isinstance(routing, dict) else None
    if not isinstance(rules, list):
        return []

    def collect_custom(outbound: str, marker: str) -> list[str]:
        for rule in rules:
            if not isinstance(rule, dict):
                continue
            if rule.get("type") != "field":
                continue
            if str(rule.get("outboundTag") or "") != outbound:
                continue
            domains = rule.get("domain")
            if not isinstance(domains, list) or marker not in domains:
                continue
            found: list[str] = []
            for entry in domains:
                if not isinstance(entry, str):
                    continue
                ent = entry.strip()
                if not ent or ent == marker or ent in READONLY_GEOSITE_DOMAINS:
                    continue
                found.append(ent)
            return found
        return []

    requested = str(mode or "").strip().lower()
    selected: list[str] = []
    if requested == "direct":
        selected = collect_custom("direct", "regexp:^$")
    elif requested == "warp":
        selected = collect_custom("warp", "regexp:^$WARP")
    else:
        selected = collect_custom("direct", "regexp:^$") + collect_custom("warp", "regexp:^$WARP")

    ordered: list[str] = []
    seen: set[str] = set()
    for entry in selected:
        if entry in seen:
            continue
        seen.add(entry)
        ordered.append(entry)
    return ordered


def _warp_state_get(key: str) -> str:
    ok, payload = read_json(NETWORK_STATE_FILE)
    if not ok or not isinstance(payload, dict):
        return ""
    value = payload.get(key)
    if value is None:
        return ""
    return str(value).strip()


def _warp_mask_license(value: str) -> str:
    raw = str(value or "").strip()
    if not raw:
        return "(kosong)"
    if len(raw) <= 8:
        return raw
    return f"{raw[:4]}****{raw[-4:]}"


def _warp_mode_state_get() -> str:
    raw = _warp_state_get(WARP_MODE_STATE_KEY).strip().lower()
    if raw in {"consumer", "zerotrust"}:
        return raw
    if service_exists(WARP_ZEROTRUST_SERVICE) and service_state(WARP_ZEROTRUST_SERVICE) == "active":
        return "zerotrust"
    return "consumer"


def _warp_mode_display_get() -> str:
    if _warp_mode_state_get() == "zerotrust":
        return "Zero Trust"
    live = _warp_live_tier()
    if live == "plus":
        return "Plus"
    if live == "free":
        return "Free"
    target = _warp_state_get(WARP_TIER_STATE_KEY).strip().lower()
    if target == "plus":
        return "Plus"
    if target == "free":
        return "Free"
    return "Free/Plus"


def _warp_zero_trust_env_map() -> dict[str, str]:
    return _read_env_map(WARP_ZEROTRUST_CONFIG_FILE)


def _warp_zero_trust_env_value(key: str, default: str = "") -> str:
    return _warp_zero_trust_env_map().get(key, default)


def _warp_zero_trust_proxy_port_get() -> str:
    port = str(_warp_zero_trust_env_value("WARP_ZEROTRUST_PROXY_PORT", WARP_ZEROTRUST_PROXY_PORT)).strip()
    return port if port.isdigit() else WARP_ZEROTRUST_PROXY_PORT


def _warp_zero_trust_secret_mask(value: str) -> str:
    raw = str(value or "").strip()
    if not raw:
        return "(kosong)"
    if len(raw) <= 8:
        return "********"
    return f"{raw[:4]}****{raw[-4:]}"


def _warp_zero_trust_proxy_state_get() -> str:
    try:
        port = int(_warp_zero_trust_proxy_port_get())
    except Exception:
        return "unknown"
    return "listening" if _listener_present(port) else "not-listening"


def _warp_zero_trust_cli_first_line(*args: str) -> str:
    if shutil.which("warp-cli") is None:
        return "unknown"
    ok, out = run_cmd(["warp-cli", *args], timeout=20)
    if not ok:
        last = str(out).splitlines()[-1].strip() if str(out).splitlines() else str(out).strip()
        return last or "unknown"
    for raw in str(out).splitlines():
        line = raw.strip()
        if line:
            return line
    return "unknown"


def _wireproxy_socks_bind_address() -> str:
    if not WIREPROXY_CONF.exists():
        return "127.0.0.1:40000"
    current_section = ""
    for raw in WIREPROXY_CONF.read_text(encoding="utf-8", errors="ignore").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or line.startswith(";"):
            continue
        if line.startswith("[") and line.endswith("]"):
            current_section = line[1:-1].strip().lower()
            continue
        if current_section not in {"socks", "socks5"}:
            continue
        if "=" not in line:
            continue
        key, value = [x.strip() for x in line.split("=", 1)]
        if key.lower() == "bindaddress" and value:
            return value
    return "127.0.0.1:40000"


def _normalize_bind_address(raw: str) -> tuple[str, int | None]:
    text = str(raw or "").strip()
    if not text:
        return "", None
    text = text.split("#", 1)[0].split(";", 1)[0].strip()
    if not text:
        return "", None
    match = re.search(r":([0-9]{1,5})$", text)
    if not match:
        return text, None
    try:
        port = int(match.group(1))
    except Exception:
        return text, None
    if not (1 <= port <= 65535):
        return text, None
    return text, port


def _warp_live_tier() -> str:
    if shutil.which("curl") is None:
        return "unknown"
    bind_addr = _wireproxy_socks_bind_address()
    ok, out = run_cmd(
        [
            "curl",
            "-fsS",
            "--max-time",
            "8",
            "--socks5",
            bind_addr,
            "https://www.cloudflare.com/cdn-cgi/trace",
        ],
        timeout=12,
    )
    if not ok:
        return "unknown"
    warp_val = ""
    for raw in out.splitlines():
        line = raw.strip()
        if not line or "=" not in line:
            continue
        k, v = line.split("=", 1)
        if k.strip() == "warp":
            warp_val = v.strip().lower()
            break
    if warp_val == "plus":
        return "plus"
    if warp_val == "on":
        return "free"
    if warp_val == "off":
        return "off"
    return "unknown"


def _current_egress_mode_summary() -> str:
    rt_src = XRAY_CONFDIR / "30-routing.json"
    ok, payload = read_json(rt_src)
    if not ok or not isinstance(payload, dict):
        return "unknown"

    routing = payload.get("routing")
    rules = routing.get("rules") if isinstance(routing, dict) else None
    if not isinstance(rules, list):
        return "unknown"

    target: dict | None = None
    for rule in rules:
        if not isinstance(rule, dict):
            continue
        if rule.get("type") != "field":
            continue
        port = str(rule.get("port") or "").strip()
        if port not in {"1-65535", "0-65535"}:
            continue
        if rule.get("user") or rule.get("domain") or rule.get("ip") or rule.get("protocol"):
            continue
        target = rule
    if not isinstance(target, dict):
        return "unknown"

    outbound = str(target.get("outboundTag") or "").strip().lower()
    if outbound in {"direct", "warp"}:
        return outbound
    return "unknown"


def op_network_warp_status_report() -> tuple[str, str]:
    title = "Network Controls - WARP Status"
    rt_src = XRAY_CONFDIR / "30-routing.json"
    ok, payload = read_json(rt_src)
    if not ok or not isinstance(payload, dict):
        return title, f"Gagal baca routing: {payload}"

    routing = payload.get("routing")
    rules = routing.get("rules") if isinstance(routing, dict) else None
    if not isinstance(rules, list):
        return title, "Format routing.rules tidak valid."

    def _rule_list_user(marker: str, outbound: str) -> list[str]:
        for rule in rules:
            if not isinstance(rule, dict):
                continue
            if rule.get("type") != "field" or str(rule.get("outboundTag") or "") != outbound:
                continue
            users = rule.get("user")
            if not isinstance(users, list) or marker not in users:
                continue
            out: list[str] = []
            seen: set[str] = set()
            for item in users:
                if not isinstance(item, str):
                    continue
                value = item.strip()
                if not value or value == marker or value in seen:
                    continue
                seen.add(value)
                out.append(value)
            return out
        return []

    def _rule_list_inbound(marker: str, outbound: str) -> list[str]:
        for rule in rules:
            if not isinstance(rule, dict):
                continue
            if rule.get("type") != "field" or str(rule.get("outboundTag") or "") != outbound:
                continue
            tags = rule.get("inboundTag")
            if not isinstance(tags, list) or marker not in tags:
                continue
            out: list[str] = []
            seen: set[str] = set()
            for item in tags:
                if not isinstance(item, str):
                    continue
                value = item.strip()
                if not value or value == marker or value in seen:
                    continue
                seen.add(value)
                out.append(value)
            return out
        return []

    def _rule_list_domain(marker: str, outbound: str) -> list[str]:
        for rule in rules:
            if not isinstance(rule, dict):
                continue
            if rule.get("type") != "field" or str(rule.get("outboundTag") or "") != outbound:
                continue
            domains = rule.get("domain")
            if not isinstance(domains, list) or marker not in domains:
                continue
            out: list[str] = []
            seen: set[str] = set()
            for item in domains:
                if not isinstance(item, str):
                    continue
                value = item.strip()
                if not value or value == marker or value in seen:
                    continue
                seen.add(value)
                out.append(value)
            return out
        return []

    user_warp = _rule_list_user("dummy-warp-user", "warp")
    user_direct = _rule_list_user("dummy-direct-user", "direct")
    inb_warp = _rule_list_inbound("dummy-warp-inbounds", "warp")
    inb_direct = _rule_list_inbound("dummy-direct-inbounds", "direct")
    dom_direct = _rule_list_domain("regexp:^$", "direct")
    dom_warp = _rule_list_domain("regexp:^$WARP", "warp")

    lines = [
        f"WARP Global   : {_current_egress_mode_summary()}",
        f"wireproxy     : {service_state('wireproxy')}",
        f"User Override : warp={len(user_warp)}, direct={len(user_direct)}",
        f"Inbound Ovr   : warp={len(inb_warp)}, direct={len(inb_direct)}",
        f"Domain List   : direct={len(dom_direct)}, warp={len(dom_warp)}",
        "",
        "User warp (sample): " + (", ".join(user_warp[:8]) if user_warp else "-"),
        "User direct (sample): " + (", ".join(user_direct[:8]) if user_direct else "-"),
        "Inbound warp (sample): " + (", ".join(inb_warp[:8]) if inb_warp else "-"),
        "Inbound direct (sample): " + (", ".join(inb_direct[:8]) if inb_direct else "-"),
        "Domain direct (sample): " + (", ".join(dom_direct[:8]) if dom_direct else "-"),
        "Domain warp (sample): " + (", ".join(dom_warp[:8]) if dom_warp else "-"),
        "",
        f"Tier target   : {_warp_state_get(WARP_TIER_STATE_KEY) or 'unknown'}",
        f"Tier live     : {_warp_live_tier()}",
        f"WARP+ License : {_warp_mask_license(_warp_state_get(WARP_PLUS_LICENSE_STATE_KEY))}",
    ]
    return title, "\n".join(lines)


def op_network_warp_tier_status() -> tuple[str, str]:
    title = "Network Controls - WARP Tier Status"
    mode = _warp_mode_state_get()
    if mode == "zerotrust":
        team = _warp_zero_trust_env_value("WARP_ZEROTRUST_TEAM", "").strip().lower()
        client_id = _warp_zero_trust_env_value("WARP_ZEROTRUST_CLIENT_ID", "").strip()
        client_secret = _warp_zero_trust_env_value("WARP_ZEROTRUST_CLIENT_SECRET", "").strip()
        lines = [
            "Mode          : Zero Trust",
            "Backend       : cloudflare-warp (Zero Trust proxy)",
            f"Team Name     : {team or '(kosong)'}",
            f"Client ID     : {_warp_zero_trust_secret_mask(client_id)}",
            f"Client Secret : {_warp_zero_trust_secret_mask(client_secret)}",
            f"Config State  : {'complete' if team and client_id and client_secret else 'incomplete'}",
            f"{WARP_ZEROTRUST_SERVICE:<14} : {service_state(WARP_ZEROTRUST_SERVICE)}",
            f"MDM Policy    : {'present' if WARP_ZEROTRUST_MDM_FILE.exists() else 'missing'}",
            f"Proxy Bind    : 127.0.0.1:{_warp_zero_trust_proxy_port_get()}",
            f"Proxy State   : {_warp_zero_trust_proxy_state_get()}",
            f"CLI Status    : {_warp_zero_trust_cli_first_line('status')}",
            f"Registration  : {_warp_zero_trust_cli_first_line('registration', 'show')}",
        ]
        return title, "\n".join(lines)

    live = _warp_live_tier()
    lines = [
        f"Mode          : {_warp_mode_display_get()}",
        "Backend       : Free/Plus (wgcf + wireproxy)",
        f"Target Tier   : {_warp_state_get(WARP_TIER_STATE_KEY) or 'unknown'}",
        f"Live Tier     : {live}",
        f"wireproxy     : {service_state('wireproxy')}",
        f"SOCKS5        : {'listening' if _listener_present(_normalize_bind_address(_wireproxy_socks_bind_address())[1] or 0) else 'not-listening'}",
        "Zero Trust    : available via cloudflare-warp backend",
        f"WARP+ License : {_warp_mask_license(_warp_state_get(WARP_PLUS_LICENSE_STATE_KEY))}",
        f"WGCF Account  : {'OK' if Path('/etc/wgcf/wgcf-account.toml').exists() else 'missing'}",
        f"WGCF Profile  : {'OK' if Path('/etc/wgcf/wgcf-profile.conf').exists() else 'missing'}",
    ]
    return title, "\n".join(lines)


def op_network_warp_tier_free_plus_status() -> tuple[str, str]:
    title = "Network Controls - WARP Tier Free/Plus"
    if _warp_mode_state_get() == "zerotrust":
        zt_service_state = service_state(WARP_ZEROTRUST_SERVICE)
        lines = [
            "Current Mode  : Zero Trust (aksi di menu ini akan mengembalikan backend ke Free/Plus)",
            "",
            "Mode          : Free/Plus",
            "Backend       : Free/Plus (wgcf + wireproxy)",
            f"Free/Plus Tier: {_warp_state_get(WARP_TIER_STATE_KEY) or 'unknown'}",
            "Free/Plus Live: standby (host in Zero Trust)",
            f"wireproxy     : {service_state('wireproxy')}",
            "SOCKS5        : standby (host in Zero Trust)",
            f"Zero Trust    : {zt_service_state} on host; Free/Plus saat ini standby",
            f"WARP+ License : {_warp_mask_license(_warp_state_get(WARP_PLUS_LICENSE_STATE_KEY))}",
        ]
        return title, "\n".join(lines)
    return title, op_network_warp_tier_status()[1]


def op_network_warp_tier_zero_trust_status() -> tuple[str, str]:
    title = "Network Controls - WARP Tier Zero Trust"
    team = _warp_zero_trust_env_value("WARP_ZEROTRUST_TEAM", "").strip().lower()
    client_id = _warp_zero_trust_env_value("WARP_ZEROTRUST_CLIENT_ID", "").strip()
    client_secret = _warp_zero_trust_env_value("WARP_ZEROTRUST_CLIENT_SECRET", "").strip()
    lines = [
        f"Mode          : {_warp_mode_display_get()}",
        "Backend       : cloudflare-warp (Zero Trust proxy)",
        f"Team Name     : {team or '(kosong)'}",
        f"Client ID     : {_warp_zero_trust_secret_mask(client_id)}",
        f"Client Secret : {_warp_zero_trust_secret_mask(client_secret)}",
        f"Config State  : {'complete' if team and client_id and client_secret else 'incomplete'}",
        f"{WARP_ZEROTRUST_SERVICE:<14} : {service_state(WARP_ZEROTRUST_SERVICE)}",
        f"MDM Policy    : {'present' if WARP_ZEROTRUST_MDM_FILE.exists() else 'missing'}",
        f"Proxy Bind    : 127.0.0.1:{_warp_zero_trust_proxy_port_get()}",
        f"Proxy State   : {_warp_zero_trust_proxy_state_get()}",
        f"CLI Status    : {_warp_zero_trust_cli_first_line('status')}",
        f"Registration  : {_warp_zero_trust_cli_first_line('registration', 'show')}",
    ]
    return title, "\n".join(lines)


def op_network_warp_tier_zero_trust_requirements() -> tuple[str, str]:
    title = "Network Controls - Zero Trust Requirements"
    body = "\n".join(
        [
            "Requirement   : cloudflare-warp client dan warp-cli harus tersedia di host",
            "Requirement   : team name + service token client id/client secret harus terisi",
            f"Requirement   : backend ini memakai proxy lokal port {_warp_zero_trust_proxy_port_get()} untuk outbound Xray",
            "Requirement   : SSH Network yang memakai WARP aktif harus kompatibel dengan backend Local Proxy",
        ]
    )
    return title, body


def op_network_warp_tier_zero_trust_rollout_notes() -> tuple[str, str]:
    title = "Network Controls - Zero Trust Rollout Notes"
    body = "\n".join(
        [
            "Rollout Note  : Zero Trust diperlakukan sebagai mode backend baru",
            "Rollout Note  : Free/Plus tetap memakai wgcf + wireproxy",
            "Rollout Note  : Zero Trust difokuskan ke jalur Xray via proxy lokal",
            "Rollout Note  : SSH Network kompatibel bila backend WARP SSH memakai Local Proxy",
            "Rollout Note  : Dedicated Interface SSH tetap fallback, tetapi tidak kompatibel dengan Zero Trust",
        ]
    )
    return title, body


def _ssh_network_config_map() -> dict[str, str]:
    data = _read_env_map(SSH_NETWORK_ENV_FILE)
    global_mode = str(data.get("SSH_NETWORK_ROUTE_GLOBAL") or "direct").strip().lower()
    if global_mode not in {"direct", "warp"}:
        global_mode = "direct"

    warp_backend = str(data.get("SSH_NETWORK_WARP_BACKEND") or "auto").strip().lower()
    if warp_backend not in {"auto", "local-proxy", "interface"}:
        warp_backend = "auto"

    warp_interface = str(data.get("SSH_NETWORK_WARP_INTERFACE") or "warp-ssh0").strip()
    if not warp_interface or not re.fullmatch(r"[A-Za-z0-9._-]{1,15}", warp_interface):
        warp_interface = "warp-ssh0"

    return {
        "global_mode": global_mode,
        "warp_backend": warp_backend,
        "warp_interface": warp_interface,
    }


def _ssh_network_backend_effective(configured: str) -> str:
    backend = str(configured or "auto").strip().lower()
    if backend in {"local-proxy", "interface"}:
        return backend
    if shutil.which("xray") and shutil.which("iptables"):
        return "local-proxy"
    return "interface"


def _ssh_network_backend_pretty(backend: str) -> str:
    value = str(backend or "auto").strip().lower()
    if value == "local-proxy":
        return "Local Proxy"
    if value == "interface":
        return "Dedicated Interface"
    if value == "idle":
        return "Idle / Not Applied"
    return "Auto"


def _ssh_network_apply_path_pretty(backend: str) -> str:
    value = str(backend or "auto").strip().lower()
    if value == "interface":
        return "wg-quick dedicated interface"
    return "xray redirect + local WARP SOCKS"


def _ssh_network_global_mode_pretty(mode: str) -> str:
    value = str(mode or "direct").strip().lower()
    if value == "warp":
        return "WARP"
    return "DIRECT"


def _ssh_network_host_mode_display() -> str:
    return _warp_mode_display_get()


def _ssh_network_host_backend_display() -> str:
    host_mode = _ssh_network_host_mode_display()
    if host_mode == "Zero Trust":
        return "cloudflare-warp"
    return "wireproxy"


def _ssh_network_host_service_name() -> str:
    if _ssh_network_host_mode_display() == "Zero Trust":
        return "warp-svc"
    return "wireproxy"


def _ssh_network_host_proxy_bind() -> str:
    bind_addr = _wireproxy_socks_bind_address()
    host, port = _normalize_bind_address(bind_addr)
    if port is None:
        return bind_addr
    return host or bind_addr


def _ssh_network_host_proxy_state() -> str:
    bind_addr = _wireproxy_socks_bind_address()
    _, port = _normalize_bind_address(bind_addr)
    if port is None:
        return "unknown"
    if _listener_present(port):
        return f"listening ({bind_addr})"
    return f"not-listening ({bind_addr})"


def _ssh_network_xray_redir_state(port: int) -> str:
    if _listener_present(port):
        return "active"
    return "standby"


def _ssh_network_effective_rows() -> list[dict[str, str]]:
    cfg = _ssh_network_config_map()
    global_mode = cfg.get("global_mode", "direct")
    rows: list[dict[str, str]] = []
    ssh_quota_dir = QUOTA_ROOT / SSH_PROTOCOL

    if not ssh_quota_dir.exists():
        return rows

    for quota_path in sorted(ssh_quota_dir.glob("*.json")):
        ok, payload = read_json(quota_path)
        if not ok or not isinstance(payload, dict):
            continue

        username = str(payload.get("username") or quota_path.stem.split("@", 1)[0]).strip()
        if not username:
            continue

        network = payload.get("network")
        override = "inherit"
        if isinstance(network, dict):
          candidate = str(network.get("route_mode") or "").strip().lower()
          if candidate in {"inherit", "direct", "warp"}:
              override = candidate

        effective = global_mode if override == "inherit" else override
        rows.append(
            {
                "username": username,
                "override": override,
                "effective": effective,
            }
        )
    return rows


def op_ssh_network_overview() -> tuple[str, str]:
    title = "SSH Network"
    cfg = _ssh_network_config_map()
    backend_effective = _ssh_network_backend_effective(cfg.get("warp_backend", "auto"))
    warp_users = sum(1 for row in _ssh_network_effective_rows() if row.get("effective") == "warp")
    lines = [
        f"Global Mode        : {_ssh_network_global_mode_pretty(cfg.get('global_mode', 'direct'))}",
        f"Backend Config     : {_ssh_network_backend_pretty(cfg.get('warp_backend', 'auto'))}",
        f"Backend Target     : {_ssh_network_backend_pretty(backend_effective)}",
        f"Apply Path         : {_ssh_network_apply_path_pretty(backend_effective)}",
        f"Host WARP Mode     : {_ssh_network_host_mode_display()}",
        f"Host Backend       : {_ssh_network_host_backend_display()}",
        f"Host Service       : {_ssh_network_host_service_name()} ({service_state(_ssh_network_host_service_name())})",
        f"Host SOCKS         : {_ssh_network_host_proxy_state()}",
        f"Xray Redir IPv4    : {_ssh_network_xray_redir_state(12345)}",
        f"Xray Redir IPv6    : {_ssh_network_xray_redir_state(12346)}",
        f"WARP Iface         : {cfg.get('warp_interface', 'warp-ssh0')}",
        f"Effective Warp Users : {warp_users}",
    ]
    return title, "\n".join(lines)


def op_ssh_network_dns_status() -> tuple[str, str]:
    title = "SSH Network - DNS for SSH"
    st = _adblock_status_map()
    enabled = st.get("enabled", "0") == "1"
    lines = [
        f"DNS Steering   : {'ON' if enabled else 'OFF'}",
        f"DNS Service    : {st.get('dns_service', '-')}",
        f"DNS State      : {st.get('dns_service_state', '-')}",
        f"Sync Service   : {st.get('sync_service', '-')}",
        f"Sync State     : {st.get('sync_service_state', '-')}",
        f"NFT Table      : {st.get('nft_table', '-')}",
        f"Managed Users  : {st.get('users_count', '0')}",
        f"DNS Port       : {st.get('dns_port', '-')}",
        f"Blocklist      : {st.get('blocklist_entries', '0')} entries",
        f"Last Update    : {st.get('last_update', '-')}",
        "",
        "Backend DNS for SSH memakai SSH Adblock runtime yang sama seperti menu Adblocker.",
    ]
    return title, "\n".join(lines)


def op_ssh_network_routing_global_status() -> tuple[str, str]:
    title = "SSH Network - Routing SSH Global"
    cfg = _ssh_network_config_map()
    backend_effective = _ssh_network_backend_effective(cfg.get("warp_backend", "auto"))
    warp_users = sum(1 for row in _ssh_network_effective_rows() if row.get("effective") == "warp")
    lines = [
        f"Global Routing  : {_ssh_network_global_mode_pretty(cfg.get('global_mode', 'direct'))}",
        f"Backend Config  : {_ssh_network_backend_pretty(cfg.get('warp_backend', 'auto'))}",
        f"Backend Target  : {_ssh_network_backend_pretty(backend_effective)}",
        f"Apply Path      : {_ssh_network_apply_path_pretty(backend_effective)}",
        f"Effective Warp Users : {warp_users}",
    ]
    return title, "\n".join(lines)


def op_ssh_network_routing_user_status() -> tuple[str, str]:
    title = "SSH Network - Routing SSH Per-User"
    rows = _ssh_network_effective_rows()
    if not rows:
        return title, "Belum ada user SSH managed yang bisa dirender."

    lines = [
        "Username             Override   Effective",
        "-------------------- ---------- ----------",
    ]
    for row in rows[:20]:
        lines.append(
            f"{row['username']:<20} {row['override']:<10} {row['effective']:<10}"
        )
    if len(rows) > 20:
        lines.append(f"... {len(rows) - 20} baris lain tidak ditampilkan")
    return title, "\n".join(lines)


def op_ssh_network_warp_global_status() -> tuple[str, str]:
    title = "SSH Network - WARP SSH Global"
    cfg = _ssh_network_config_map()
    backend_effective = _ssh_network_backend_effective(cfg.get("warp_backend", "auto"))
    warp_users = sum(1 for row in _ssh_network_effective_rows() if row.get("effective") == "warp")
    lines = [
        f"Global WARP      : {'ON' if cfg.get('global_mode', 'direct') == 'warp' else 'OFF'}",
        f"Backend Config   : {_ssh_network_backend_pretty(cfg.get('warp_backend', 'auto'))}",
        f"Backend Target   : {_ssh_network_backend_pretty(backend_effective)}",
        f"Apply Path       : {_ssh_network_apply_path_pretty(backend_effective)}",
        f"Host WARP Mode   : {_ssh_network_host_mode_display()}",
        f"Host Backend     : {_ssh_network_host_backend_display()}",
        f"Host Service     : {_ssh_network_host_service_name()} ({service_state(_ssh_network_host_service_name())})",
        f"Host SOCKS       : {_ssh_network_host_proxy_state()}",
        f"Effective Warp Users : {warp_users}",
    ]
    return title, "\n".join(lines)


def op_ssh_network_warp_user_status() -> tuple[str, str]:
    title = "SSH Network - WARP SSH Per-User"
    rows = _ssh_network_effective_rows()
    if not rows:
        return title, "Belum ada user SSH managed yang bisa dirender."

    lines = [
        "State metadata SSH: network.route_mode.",
        "",
        "Username             Override   Effective",
        "-------------------- ---------- ----------",
    ]
    for row in rows[:20]:
        lines.append(
            f"{row['username']:<20} {row['override']:<10} {row['effective']:<10}"
        )
    if len(rows) > 20:
        lines.append(f"... {len(rows) - 20} baris lain tidak ditampilkan")
    return title, "\n".join(lines)


def op_domain_info() -> tuple[str, str]:
    body = (
        f"Domain aktif : {detect_domain()}\n"
        f"Cert file    : {CERT_FULLCHAIN}\n"
        f"TLS expiry   : {detect_tls_expiry()}"
    )
    return "Domain Control", body


def op_domain_nginx_server_name() -> tuple[str, str]:
    if not NGINX_CONF.exists():
        return "Domain Control - Nginx Server Name", f"File tidak ditemukan: {NGINX_CONF}"
    lines = []
    for line in NGINX_CONF.read_text(encoding="utf-8", errors="ignore").splitlines():
        if re.match(r"^\s*server_name\s+", line):
            lines.append(line.rstrip())
    if not lines:
        lines.append("(tidak ada baris server_name)")
    return "Domain Control - Nginx Server Name", "\n".join(lines)


def _traffic_analytics_dataset() -> dict[str, Any]:
    entries: list[dict[str, Any]] = []
    proto_summary: dict[str, dict[str, int]] = {
        proto: {"users": 0, "used_bytes": 0, "quota_bytes": 0}
        for proto in PROTOCOLS
    }

    for proto in PROTOCOLS:
        for username, path in _iter_proto_quota_files(proto):
            ok, payload = read_json(path)
            data = payload if ok and isinstance(payload, dict) else {}

            resolved_username = str(data.get("username") or username).strip() or username
            used_bytes = max(0, _to_int(data.get("quota_used"), 0))
            quota_bytes = max(0, _to_int(data.get("quota_limit"), 0))
            expired_at = str(data.get("expired_at") or "-").strip()[:10] or "-"

            entries.append(
                {
                    "username": resolved_username,
                    "proto": proto,
                    "used_bytes": used_bytes,
                    "quota_bytes": quota_bytes,
                    "expired_at": expired_at,
                    "source_file": str(path),
                }
            )
            proto_summary[proto]["users"] += 1
            proto_summary[proto]["used_bytes"] += used_bytes
            proto_summary[proto]["quota_bytes"] += quota_bytes

    entries.sort(
        key=lambda item: (
            -int(item.get("used_bytes", 0)),
            str(item.get("username", "")).lower(),
            str(item.get("proto", "")).lower(),
        )
    )

    total_used = sum(int(item.get("used_bytes", 0)) for item in entries)
    total_quota = sum(int(item.get("quota_bytes", 0)) for item in entries)

    return {
        "generated_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "quota_root": str(QUOTA_ROOT),
        "total_users": len(entries),
        "total_used_bytes": total_used,
        "total_quota_bytes": total_quota,
        "protocols": proto_summary,
        "top_users": entries,
    }


def _traffic_pct_text(used_bytes: int, quota_bytes: int) -> str:
    if quota_bytes <= 0:
        return "-"
    return f"{(used_bytes * 100.0 / quota_bytes):.1f}"


def op_traffic_analytics_overview() -> tuple[str, str]:
    data = _traffic_analytics_dataset()
    total_users = int(data.get("total_users") or 0)
    total_used = int(data.get("total_used_bytes") or 0)
    total_quota = int(data.get("total_quota_bytes") or 0)
    avg_used = int(total_used / total_users) if total_users > 0 else 0

    lines = [
        f"Generated UTC : {data.get('generated_at_utc') or '-'}",
        f"Total Users   : {total_users}",
        f"Total Used    : {_human_bytes(total_used)}",
        f"Total Quota   : {_human_bytes(total_quota)}",
        f"Avg/User Used : {_human_bytes(avg_used)}",
        "",
        "By Protocol:",
    ]

    protocols = data.get("protocols") if isinstance(data.get("protocols"), dict) else {}
    for proto in PROTOCOLS:
        info = protocols.get(proto) if isinstance(protocols, dict) else {}
        users = _to_int((info or {}).get("users"), 0)
        used = _to_int((info or {}).get("used_bytes"), 0)
        quota = _to_int((info or {}).get("quota_bytes"), 0)
        lines.append(
            f"  {proto.upper():<6} users={users:<4} used={_human_bytes(used):<12} quota={_human_bytes(quota)}"
        )

    top_users = data.get("top_users") if isinstance(data.get("top_users"), list) else []
    lines.extend(["", "Top 5 Users:"])
    if not top_users:
        lines.append("  (kosong)")
    else:
        for idx, row in enumerate(top_users[:5], start=1):
            username = str((row or {}).get("username") or "-")
            proto = str((row or {}).get("proto") or "-").upper()
            used = _human_bytes(_to_int((row or {}).get("used_bytes"), 0))
            lines.append(f"  {idx:>2}. {username:<20} {proto:<6} {used}")

    return "Traffic Analytics - Overview", "\n".join(lines)


def op_traffic_analytics_top_users(limit: int = 15) -> tuple[str, str]:
    cap = max(1, min(200, int(limit)))
    data = _traffic_analytics_dataset()
    rows = data.get("top_users") if isinstance(data.get("top_users"), list) else []
    if not rows:
        return "Traffic Analytics - Top Users", "Belum ada data traffic user."

    lines = [
        f"Top {cap} user berdasarkan penggunaan traffic:",
        "",
        f"{'NO':<4} {'PROTO':<8} {'USERNAME':<20} {'USED':<12} {'QUOTA':<12} {'USE%':>6} {'EXPIRED':<10}",
        f"{'-'*4:<4} {'-'*8:<8} {'-'*20:<20} {'-'*12:<12} {'-'*12:<12} {'-'*6:>6} {'-'*10:<10}",
    ]
    for idx, row in enumerate(rows[:cap], start=1):
        proto = str((row or {}).get("proto") or "-").upper()
        username = str((row or {}).get("username") or "-")[:20]
        used = _to_int((row or {}).get("used_bytes"), 0)
        quota = _to_int((row or {}).get("quota_bytes"), 0)
        exp = str((row or {}).get("expired_at") or "-")[:10]
        lines.append(
            f"{idx:<4} {proto:<8} {username:<20} {_human_bytes(used):<12} {_human_bytes(quota):<12} "
            f"{_traffic_pct_text(used, quota):>6} {exp:<10}"
        )
    return "Traffic Analytics - Top Users", "\n".join(lines)


def op_traffic_analytics_search(query: str) -> tuple[str, str]:
    needle = str(query or "").strip().lower()
    if not needle:
        return "Traffic Analytics - Search", "Keyword pencarian wajib diisi."

    data = _traffic_analytics_dataset()
    rows = data.get("top_users") if isinstance(data.get("top_users"), list) else []
    hits = [
        row
        for row in rows
        if needle in f"{str((row or {}).get('username') or '').strip()}@{str((row or {}).get('proto') or '').strip()}".lower()
    ]
    if not hits:
        return "Traffic Analytics - Search", f"Tidak ada user cocok untuk keyword: {query}"

    lines = [
        f"Ditemukan {len(hits)} user.",
        "",
        f"{'NO':<4} {'PROTO':<8} {'USERNAME':<20} {'USED':<12} {'QUOTA':<12} {'USE%':>6} {'EXPIRED':<10}",
        f"{'-'*4:<4} {'-'*8:<8} {'-'*20:<20} {'-'*12:<12} {'-'*12:<12} {'-'*6:>6} {'-'*10:<10}",
    ]
    for idx, row in enumerate(hits[:200], start=1):
        proto = str((row or {}).get("proto") or "-").upper()
        username = str((row or {}).get("username") or "-")[:20]
        used = _to_int((row or {}).get("used_bytes"), 0)
        quota = _to_int((row or {}).get("quota_bytes"), 0)
        exp = str((row or {}).get("expired_at") or "-")[:10]
        lines.append(
            f"{idx:<4} {proto:<8} {username:<20} {_human_bytes(used):<12} {_human_bytes(quota):<12} "
            f"{_traffic_pct_text(used, quota):>6} {exp:<10}"
        )
    return "Traffic Analytics - Search", "\n".join(lines)


def op_traffic_analytics_export_json() -> tuple[bool, str, str, dict[str, str] | None]:
    title = "Traffic Analytics - Export JSON"
    payload = _traffic_analytics_dataset()
    raw = json.dumps(payload, ensure_ascii=False, indent=2).encode("utf-8")
    if len(raw) > 1_900_000:
        return (
            False,
            title,
            "Dataset terlalu besar untuk lampiran Telegram (>1.9MB). Gunakan menu CLI untuk export penuh.",
            None,
        )

    filename = f"traffic-analytics-{datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S')}.json"
    download = {
        "filename": filename,
        "content_base64": base64.b64encode(raw).decode("ascii"),
        "content_type": "application/json",
    }
    msg = (
        "Dataset traffic analytics siap diunduh.\n"
        f"- File: {filename}\n"
        f"- Total users: {payload.get('total_users', 0)}"
    )
    return True, title, msg, download


def _speedtest_bin() -> str | None:
    if shutil.which("speedtest"):
        return "speedtest"
    snap_bin = Path("/snap/bin/speedtest")
    if snap_bin.exists():
        return str(snap_bin)
    return None


def _speedtest_parse_json(raw: str) -> tuple[bool, dict[str, Any] | str]:
    text = str(raw or "").strip()
    if not text:
        return False, "Output speedtest kosong."

    def has_speed_metrics(payload: dict[str, Any]) -> bool:
        ping = payload.get("ping")
        download = payload.get("download")
        upload = payload.get("upload")
        return (
            isinstance(ping, dict)
            and isinstance(download, dict)
            and isinstance(upload, dict)
            and "latency" in ping
            and "bandwidth" in download
            and "bandwidth" in upload
        )

    candidates = [line.strip() for line in text.splitlines() if line.strip()]
    fallback_dict: dict[str, Any] | None = None
    for chunk in reversed(candidates):
        if not (chunk.startswith("{") and chunk.endswith("}")):
            continue
        try:
            payload = json.loads(chunk)
        except Exception:
            continue
        if isinstance(payload, dict):
            if has_speed_metrics(payload):
                return True, payload
            if fallback_dict is None:
                fallback_dict = payload

    try:
        payload = json.loads(text)
    except Exception:
        payload = None
    if isinstance(payload, dict):
        if has_speed_metrics(payload):
            return True, payload
        if fallback_dict is None:
            fallback_dict = payload

    if fallback_dict is not None:
        # Fallback terakhir agar error message tetap informatif saat CLI speedtest
        # hanya mengembalikan log/noise tanpa metrik result.
        return True, fallback_dict

    return False, "Output speedtest tidak valid (JSON tidak ditemukan)."


def _speedtest_to_float(value: Any) -> float | None:
    try:
        num = float(value)
    except Exception:
        return None
    if not (num >= 0):
        return None
    return num


def _speedtest_latency_text(payload: dict[str, Any]) -> str:
    ping = payload.get("ping")
    if not isinstance(ping, dict):
        return "-"
    val = _speedtest_to_float(ping.get("latency"))
    if val is None:
        return "-"
    return f"{val:.2f} ms"


def _speedtest_packet_loss_text(payload: dict[str, Any]) -> str:
    val = _speedtest_to_float(payload.get("packetLoss"))
    if val is None:
        return "-"
    return f"{val:.2f} %"


def _speedtest_bandwidth_text(payload: dict[str, Any], key: str) -> str:
    block = payload.get(key)
    if not isinstance(block, dict):
        return "-"
    bandwidth = _speedtest_to_float(block.get("bandwidth"))
    if bandwidth is None:
        return "-"
    mbps = (bandwidth * 8.0) / 1_000_000.0
    return f"{mbps:.2f} Mbps"


def _speedtest_compact_summary(payload: dict[str, Any]) -> str:
    isp = str(payload.get("isp") or "-").strip() or "-"
    latency = _speedtest_latency_text(payload)
    packet_loss = _speedtest_packet_loss_text(payload)
    download = _speedtest_bandwidth_text(payload, "download")
    upload = _speedtest_bandwidth_text(payload, "upload")
    return (
        f"ISP         : {isp}\n"
        f"Latency     : {latency}\n"
        f"Packet Loss : {packet_loss}\n"
        f"Download    : {download}\n"
        f"Upload      : {upload}"
    )


def _speedtest_has_minimum_metrics(payload: dict[str, Any]) -> bool:
    latency = _speedtest_latency_text(payload)
    download = _speedtest_bandwidth_text(payload, "download")
    upload = _speedtest_bandwidth_text(payload, "upload")
    return not (latency == "-" and download == "-" and upload == "-")


def op_speedtest_run() -> tuple[bool, str, str]:
    binary = _speedtest_bin()
    if not binary:
        return False, "Speedtest", "Binary speedtest tidak ditemukan."

    ok, out = run_cmd(
        [binary, "--accept-license", "--accept-gdpr", "--progress=no", "--format=json"],
        timeout=180,
    )
    if ok:
        ok_parse, payload_or_err = _speedtest_parse_json(out)
        if not ok_parse:
            return False, "Speedtest - Run", str(payload_or_err)
        assert isinstance(payload_or_err, dict)
        summary = _speedtest_compact_summary(payload_or_err)
        if not _speedtest_has_minimum_metrics(payload_or_err):
            return False, "Speedtest - Run", f"Hasil speedtest tidak lengkap.\n{summary}"
        return True, "Speedtest - Run", summary
    return False, "Speedtest - Run", f"Gagal speedtest:\n{out}"


def op_speedtest_version() -> tuple[bool, str, str]:
    binary = _speedtest_bin()
    if not binary:
        return False, "Speedtest", "Binary speedtest tidak ditemukan."
    ok, out = run_cmd([binary, "--version"], timeout=20)
    if ok:
        return True, "Speedtest - Version", out
    return False, "Speedtest - Version", f"Gagal membaca versi speedtest:\n{out}"


def op_fail2ban_status() -> tuple[str, str]:
    title = "Security - Fail2ban Overview"
    if not _fail2ban_client_available():
        return title, "fail2ban-client tidak tersedia."

    jail_count = len(_fail2ban_jails_list())
    lines = [
        f"Service       : {service_state('fail2ban')}",
        f"Enabled       : {systemctl_enabled_state('fail2ban')}",
        f"Jail Count    : {jail_count}",
        f"Banned IP Now : {_fail2ban_total_banned()}",
    ]
    ok, out = run_cmd(["fail2ban-client", "status"], timeout=20)
    if ok:
        lines.extend(["", out])
    else:
        lines.extend(["", f"Gagal membaca status fail2ban:\n{out}"])
    return title, _trim_message("\n".join(lines))


def op_fail2ban_jail_status() -> tuple[str, str]:
    title = "Security - Fail2ban Jail Status"
    if not _fail2ban_client_available():
        return title, "fail2ban-client tidak tersedia."

    jails = _fail2ban_jails_list()
    if not jails:
        return title, "Tidak ada jail fail2ban yang terdeteksi."

    lines = [
        f"Service : {service_state('fail2ban')}",
        "",
        f"{'JAIL':<28} {'CURRENT':>7} {'TOTAL':>7}",
        f"{'-'*28:<28} {'-'*7:>7} {'-'*7:>7}",
    ]
    for jail in jails:
        current, total = _fail2ban_jail_counts(jail)
        lines.append(f"{jail:<28} {current:>7} {total:>7}")
    return title, _trim_message("\n".join(lines))


def op_fail2ban_banned_ips() -> tuple[str, str]:
    title = "Security - Fail2ban Banned IP"
    if not _fail2ban_client_available():
        return title, "fail2ban-client tidak tersedia."

    jails = _fail2ban_jails_list()
    if not jails:
        return title, "Tidak ada jail fail2ban yang terdeteksi."

    lines: list[str] = []
    for jail in jails:
        ok, out = run_cmd(["fail2ban-client", "get", jail, "banip"], timeout=20)
        lines.append(f"[{jail}]")
        if ok and out.strip():
            for ip in out.split():
                lines.append(f"- {ip}")
        else:
            lines.append("(kosong)")
        lines.append("")
    return title, _trim_message("\n".join(lines).strip())


def op_fail2ban_unban_ip(ip: str, jail: str = "") -> tuple[bool, str, str]:
    title = "Security - Fail2ban Unban IP"
    ip_text = str(ip or "").strip()
    jail_text = str(jail or "").strip()
    if not ip_text:
        return False, title, "IP wajib diisi."
    if not _fail2ban_client_available():
        return False, title, "fail2ban-client tidak tersedia."

    try:
        normalized_ip = str(ipaddress.ip_address(ip_text))
    except ValueError:
        return False, title, f"IP tidak valid: {ip_text}"

    targets = [jail_text] if jail_text else _fail2ban_jails_list()
    if not targets:
        return False, title, "Tidak ada jail fail2ban yang terdeteksi."

    success: list[str] = []
    failed: list[str] = []
    for target in targets:
        ok, out = run_cmd(["fail2ban-client", "set", target, "unbanip", normalized_ip], timeout=20)
        if ok:
            success.append(target)
        else:
            brief = out.splitlines()[-1].strip() if out else "unknown error"
            failed.append(f"{target}: {brief}")

    if success and not failed:
        lines = [
            f"IP       : {normalized_ip}",
            "Unbanned : " + ", ".join(success),
        ]
        return True, title, "\n".join(lines)

    lines = [
        f"IP       : {normalized_ip}",
    ]
    if success:
        lines.append("Berhasil : " + ", ".join(success))
    if failed:
        lines.extend(["Gagal:", *[f"- {line}" for line in failed]])
    return False, title, "\n".join(lines)


def _read_sysctl(key: str) -> str:
    path = Path("/proc/sys") / key.replace(".", "/")
    if path.exists():
        return path.read_text(encoding="utf-8", errors="ignore").strip()
    ok, out = run_cmd(["sysctl", "-n", key], timeout=8)
    return out.strip() if ok else "-"


def op_sysctl_summary() -> tuple[str, str]:
    keys = [
        "net.core.default_qdisc",
        "net.ipv4.tcp_congestion_control",
        "net.ipv4.ip_forward",
        "net.ipv4.tcp_syncookies",
    ]
    lines = [f"- {key}: {_read_sysctl(key)}" for key in keys]
    return "Security - Kernel/Network Summary", "\n".join(lines)


def op_hardening_bbr() -> tuple[str, str]:
    title = "Security - Hardening - Check BBR"
    cc = _read_sysctl("net.ipv4.tcp_congestion_control")
    qdisc = _read_sysctl("net.core.default_qdisc")
    enabled = "Enabled" if cc == "bbr" else "Disabled"
    lines = [
        f"tcp_congestion_control : {cc or '-'}",
        f"default_qdisc          : {qdisc or '-'}",
        "",
        f"BBR : {enabled}",
    ]
    return title, "\n".join(lines)


def op_hardening_swap() -> tuple[str, str]:
    title = "Security - Hardening - Check Swap"
    if not shutil.which("free"):
        return title, "Binary `free` tidak tersedia."
    ok, out = run_cmd(["free", "-h"], timeout=8)
    if not ok:
        return title, f"Gagal membaca swap:\n{out}"
    bytes_raw = "0"
    ok_b, out_b = run_cmd(["free", "-b"], timeout=8)
    if ok_b:
        match = re.search(r"^Swap:\s+([0-9]+)", out_b, re.MULTILINE)
        if match:
            bytes_raw = match.group(1)
    total_swap = int(bytes_raw) if str(bytes_raw).isdigit() else 0
    status = "Disabled" if total_swap <= 0 else f"{max(1, round(total_swap / (1024**3)))}GB Active"
    return title, "\n".join([out, "", f"Swap : {status}"])


def op_hardening_ulimit() -> tuple[str, str]:
    title = "Security - Hardening - Check Ulimit"
    ok_shell, shell_limit = run_cmd(["bash", "-lc", "ulimit -n"], timeout=8)
    xray_limit = systemctl_enabled_state("xray")
    ok_unit, xray_nofile = run_cmd(["systemctl", "show", "-p", "LimitNOFILE", "--value", "xray"], timeout=8)
    lines = [
        f"Shell ulimit -n : {shell_limit.strip() if ok_shell else '-'}",
        f"xray active     : {service_state('xray')}",
        f"xray enabled    : {xray_limit}",
        f"xray LimitNOFILE: {xray_nofile.strip() if ok_unit else '-'}",
    ]
    return title, "\n".join(lines)


def op_hardening_chrony() -> tuple[str, str]:
    title = "Security - Hardening - Check Chrony"
    unit = ""
    if service_exists("chrony"):
        unit = "chrony"
    elif service_exists("chronyd"):
        unit = "chronyd"
    if not unit:
        return title, "chrony/chronyd service tidak terdeteksi."

    ok, out = run_cmd(["systemctl", "status", unit, "--no-pager"], timeout=20)
    lines = [
        f"Service : {unit}",
        f"State   : {service_state(unit)}",
        f"Enabled : {systemctl_enabled_state(unit)}",
    ]
    if ok:
        lines.extend(["", out])
    return title, _trim_message("\n".join(lines))


def op_tls_expiry() -> tuple[str, str]:
    title = "Security - TLS Expiry"
    expiry = detect_tls_expiry()
    days = _tls_expiry_days_left()
    if days is None:
        return title, f"TLS expiry : {expiry}"
    status = "Expired" if days < 0 else f"{days} days"
    return title, f"TLS expiry : {expiry}\nDays left  : {status}"


def op_security_overview() -> tuple[str, str]:
    title = "Security - Overview"
    tls_days = _tls_expiry_days_left()
    if tls_days is None:
        tls_line = "-"
    else:
        tls_line = "Expired" if tls_days < 0 else f"{tls_days} days"

    lines = [
        f"TLS Expiry        : {tls_line}",
        f"Fail2ban          : {'Active' if service_state('fail2ban') == 'active' else 'Inactive'}",
        f"Banned IP         : {_fail2ban_total_banned() if _fail2ban_client_available() else 0}",
        f"SSH Protection    : {'Active' if _fail2ban_jail_active('sshd') else 'Inactive'}",
        (
            "Nginx Protection  : Active"
            if _fail2ban_jail_active("nginx-bad-request-access") or _fail2ban_jail_active("nginx-bad-request-error")
            else "Nginx Protection  : Inactive"
        ),
        f"Recidive          : {'Active' if _fail2ban_jail_active('recidive') else 'Inactive'}",
        f"BBR               : {'Enabled' if _read_sysctl('net.ipv4.tcp_congestion_control') == 'bbr' else 'Disabled'}",
    ]

    if shutil.which("free"):
        ok, out = run_cmd(["free", "-b"], timeout=8)
        if ok:
            match = re.search(r"^Swap:\s+([0-9]+)", out, re.MULTILINE)
            total_swap = int(match.group(1)) if match else 0
            lines.append(f"Swap              : {'Disabled' if total_swap <= 0 else f'{max(1, round(total_swap / (1024**3)))}GB Active'}")
        else:
            lines.append("Swap              : Unknown")
    else:
        lines.append("Swap              : Unknown")

    return title, "\n".join(lines)


def op_maintenance_status() -> tuple[str, str]:
    lines = [f"- {svc}: {service_state(svc)}" for svc in ALLOWED_SERVICES]
    return "Maintenance - Service Status", "\n".join(lines)


def op_restart_service(service: str) -> tuple[bool, str, str]:
    if service not in ALLOWED_RESTART_SERVICES:
        return False, "Maintenance - Restart", f"Service tidak diizinkan: {service}"
    ok, state, out = _restart_service_checked(service, timeout=25)
    if ok:
        return True, "Maintenance - Restart", f"Restart {service} berhasil.\nState: {state}"
    return False, "Maintenance - Restart", f"Restart {service} gagal.\n{out}\nState: {state}"


def op_reload_service(service: str) -> tuple[bool, str, str]:
    if service not in {"nginx"}:
        return False, "Security - Reload", f"Service reload tidak diizinkan: {service}"
    if not service_exists(service):
        return False, "Security - Reload", f"Service tidak ditemukan: {service}"
    ok, state, out = _reload_service_checked(service, timeout=25)
    if ok:
        return True, "Security - Reload", f"Reload {service} berhasil.\nState: {state}"
    return False, "Security - Reload", f"Reload {service} gagal.\n{out}\nState: {state}"


def op_restart_edge_gateway() -> tuple[bool, str, str]:
    service = _edge_runtime_service_name()
    if not service:
        return False, "Maintenance - Restart Edge Gateway", "Edge runtime service tidak terdeteksi."
    if not service_exists(service):
        return False, "Maintenance - Restart Edge Gateway", f"Service edge tidak ditemukan: {service}"
    ok, state, out = _restart_service_checked(service, timeout=25)
    if ok:
        return True, "Maintenance - Restart Edge Gateway", f"Restart {service} berhasil.\nState: {state}"
    return False, "Maintenance - Restart Edge Gateway", f"Restart {service} gagal.\n{out}\nState: {state}"


def op_restart_sshws_stack() -> tuple[bool, str, str]:
    ok, title, message = _service_group_restart(SSHWS_SERVICES, "Maintenance - Restart SSHWS Stack")
    if not ok:
        return ok, title, message
    healthy, failed = _sshws_post_restart_health_check()
    if not healthy:
        details = ", ".join(failed) if failed else "unknown"
        return False, title, f"{message}\n\nPost-restart health check gagal: {details}"
    return True, title, f"{message}\n\nPost-restart health check: OK"


def op_restart_all_core() -> tuple[bool, str, str]:
    return _service_group_restart(("xray", "nginx"), "Maintenance - Restart All")


def op_restart_xray_daemons() -> tuple[bool, str, str]:
    return _service_group_restart(XRAY_DAEMONS, "Maintenance - Restart Xray Daemons")


def op_service_log_tail(service: str, lines: int = 40) -> tuple[str, str]:
    title = f"Maintenance - Logs - {service}"
    if service not in ALLOWED_RESTART_SERVICES:
        return title, f"Service log tidak diizinkan: {service}"
    unit_type = "timer" if service.endswith(".timer") else "service"
    raw_name = service[: -len(".timer")] if unit_type == "timer" else service
    if not service_exists(raw_name, unit_type=unit_type):
        return title, f"Unit tidak ditemukan: {service}"
    return title, _journal_tail(service, lines=lines)


def op_wireproxy_status() -> tuple[str, str]:
    title = "Maintenance - Wireproxy (WARP) Status"
    if not service_exists("wireproxy"):
        return title, "wireproxy.service tidak ditemukan. Pastikan setup.sh terbaru sudah dijalankan."

    lines = [
        _unit_status_line("wireproxy"),
    ]

    ok_pid, pid = run_cmd(["systemctl", "show", "-p", "MainPID", "--value", "wireproxy"], timeout=8)
    pid_text = pid.strip() if ok_pid else ""
    if pid_text and pid_text != "0":
        lines.append(f"PID           : {pid_text}")
        ok_uptime, uptime = run_cmd(["ps", "-o", "etime=", "-p", pid_text], timeout=8)
        if ok_uptime and uptime.strip():
            lines.append(f"Uptime        : {uptime.strip()}")

    bind_addr_raw = _wireproxy_socks_bind_address()
    bind_addr, bind_port = _normalize_bind_address(bind_addr_raw)
    if not bind_addr:
        bind_addr = bind_addr_raw
    listen_text = "UNKNOWN (invalid bind address)"
    if bind_port is not None:
        listen_text = "LISTENING" if _listener_present(bind_port) else "NOT listening"
    lines.extend(
        [
            f"SOCKS5 bind   : {bind_addr}",
            f"SOCKS5 listen : {listen_text}",
        ]
    )

    if shutil.which("curl") and bind_port is not None:
        ok_ip, warp_ip = run_cmd(
            ["curl", "-fsSL", "--socks5", bind_addr, "--max-time", "5", "https://api.ipify.org"],
            timeout=12,
        )
        lines.append(f"WARP IP       : {warp_ip.strip() if ok_ip and warp_ip.strip() else 'gagal'}")
    elif bind_port is None:
        lines.append("WARP IP       : skip (bind address tidak valid)")
    else:
        lines.append("WARP IP       : curl tidak tersedia")

    lines.append(f"Config        : {WIREPROXY_CONF}")
    return title, "\n".join(lines)


def op_edge_gateway_status() -> tuple[str, str]:
    title = "Maintenance - Edge Gateway Status"
    service = _edge_runtime_service_name()
    provider = _edge_runtime_provider_name("go")
    active_flag = _edge_runtime_env_value("EDGE_ACTIVATE_RUNTIME", "false") or "false"
    http_ports = _edge_runtime_ports("EDGE_PUBLIC_HTTP_PORTS", "EDGE_PUBLIC_HTTP_PORT", "80,8080,8880,2052,2082,2086,2095", "80")
    tls_ports = _edge_runtime_ports("EDGE_PUBLIC_TLS_PORTS", "EDGE_PUBLIC_TLS_PORT", "443,2053,2083,2087,2096,8443", "443")
    http_backend = _edge_runtime_env_value("EDGE_NGINX_HTTP_BACKEND", "127.0.0.1:18080") or "127.0.0.1:18080"
    tls_backend = _edge_runtime_env_value("EDGE_NGINX_TLS_BACKEND", "127.0.0.1:18443") or "127.0.0.1:18443"
    ssh_backend = _edge_runtime_env_value("EDGE_SSH_CLASSIC_BACKEND", "127.0.0.1:22022") or "127.0.0.1:22022"
    ssh_tls_backend = _edge_runtime_env_value("EDGE_SSH_TLS_BACKEND", "127.0.0.1:22443") or "127.0.0.1:22443"
    metrics_addr = _edge_runtime_env_value("EDGE_METRICS_LISTEN", "127.0.0.1:9910") or "127.0.0.1:9910"
    lines = [
        _unit_status_line(service),
        f"Provider      : {provider}",
        f"Activate      : {active_flag}",
        f"HTTP Ports    : {_edge_runtime_ports_label(http_ports)} ({'LISTENING' if http_ports and all(_listener_present(port) for port in http_ports) else 'unknown'})",
        f"TLS Ports     : {_edge_runtime_ports_label(tls_ports)} ({'LISTENING' if tls_ports and all(_listener_present(port) for port in tls_ports) else 'unknown'})",
        f"HTTP Backend  : {http_backend}",
        f"TLS Backend   : {tls_backend}",
        f"SSH Backend   : {ssh_backend}",
        f"SSH TLS Back  : {ssh_tls_backend}",
        f"Metrics       : {metrics_addr}",
        f"Env File      : {EDGE_RUNTIME_ENV_FILE}",
    ]
    return title, "\n".join(lines)


def op_badvpn_status() -> tuple[str, str]:
    title = "Maintenance - BadVPN UDPGW Status"
    ports = _badvpn_runtime_ports()
    listener_summary = "-"
    if ports:
        # badvpn-udpgw accepts TCP client connections that encapsulate UDP payloads.
        missing = [str(port) for port in ports if not _listener_present(port)]
        listener_summary = "LISTENING" if not missing else f"MISSING {', '.join(missing)}"
    lines = [
        _unit_status_line("badvpn-udpgw"),
        f"Ports         : {_badvpn_runtime_ports_label()}",
        f"TCP Listen    : {listener_summary}",
        f"Max Clients   : {_badvpn_runtime_env_value('BADVPN_UDPGW_MAX_CLIENTS', '512') or '512'}",
        f"Max Conn/User : {_badvpn_runtime_env_value('BADVPN_UDPGW_MAX_CONNECTIONS_FOR_CLIENT', '8') or '8'}",
        f"Buffer Size   : {_badvpn_runtime_env_value('BADVPN_UDPGW_BUFFER_SIZE', '1048576') or '1048576'}",
        f"Env File      : {BADVPN_RUNTIME_ENV_FILE}",
    ]
    return title, "\n".join(lines)


def op_openvpn_status() -> tuple[str, str]:
    title = "Maintenance - OpenVPN Status"
    tcp_port = _openvpn_env_value("OPENVPN_PORT_TCP", "1194") or "1194"
    public_tcp_port = _openvpn_public_tcp_ports_label()
    ws_proxy_port = _openvpn_ws_proxy_port()
    ws_public_path = _openvpn_ws_public_path()
    ws_alt_path = _openvpn_ws_alt_path()
    lines = ["Services:"]
    for service in OPENVPN_SERVICES:
        state = service_state(service)
        enabled = systemctl_enabled_state(service)
        load = _systemctl_show_props(service, ["LoadState"]).get("LoadState") or "unknown"
        if load == "not-found":
            lines.append(f"- {service}.service: not installed")
        else:
            lines.append(f"- {service}.service: {state or '-'} / {enabled or '-'}")
    lines.extend(
        [
            "",
            "Ports:",
            f"- backend tcp {tcp_port} : {'LISTENING' if _listener_present(int(tcp_port)) else 'NOT listening'}",
            f"- public tcp {public_tcp_port} : {'ROUTED via edge-mux' if service_state(_edge_runtime_service_name() or 'edge-mux') == 'active' else 'edge gateway inactive'}",
            f"- ws proxy {ws_proxy_port} : {'LISTENING' if _listener_present(ws_proxy_port, host='127.0.0.1') else 'NOT listening'}",
            "",
            "Runtime:",
            f"- env file    : {OPENVPN_CONFIG_ENV_FILE}",
            f"- profile dir : {_openvpn_env_value('OPENVPN_PROFILE_DIR', '/opt/account/openvpn')}",
            f"- metadata dir: {_openvpn_env_value('OPENVPN_METADATA_DIR', '/var/lib/openvpn-manage/users')}",
            f"- public host : {_openvpn_env_value('OPENVPN_PUBLIC_HOST', detect_domain() or '-')}",
            f"- ws path     : {ws_public_path}",
            f"- ws path alt : {ws_alt_path}",
            f"- ws port     : {_ws_public_ports_label()}",
        ]
    )
    return title, "\n".join(lines)


def op_restart_openvpn() -> tuple[bool, str, str]:
    title = "Maintenance - Restart OpenVPN"
    lines: list[str] = []
    had_failure = False
    for service in OPENVPN_SERVICES:
        load = _systemctl_show_props(service, ["LoadState"]).get("LoadState") or "unknown"
        if load == "not-found":
            lines.append(f"- {service}: skip (unit tidak ditemukan)")
            had_failure = True
            continue
        ok, state, out = _restart_service_checked(service, timeout=25)
        if ok:
            lines.append(f"- {service}: restarted ({state})")
        else:
            had_failure = True
            brief = out.splitlines()[-1].strip() if out else "unknown error"
            lines.append(f"- {service}: gagal ({state}) - {brief}")
    if not had_failure:
        tcp_port = _openvpn_env_value("OPENVPN_PORT_TCP", "1194") or "1194"
        ws_proxy_port = _openvpn_ws_proxy_port()
        health_failures: list[str] = []
        try:
            tcp_port_int = int(tcp_port)
        except Exception:
            health_failures.append(f"backend tcp invalid ({tcp_port})")
        else:
            if not _listener_present(tcp_port_int):
                health_failures.append(f"backend tcp {tcp_port_int} tidak listening")
        if not _listener_present(ws_proxy_port, host="127.0.0.1"):
            health_failures.append(f"ws proxy {ws_proxy_port} tidak listening")
        if health_failures:
            return False, title, "\n".join(lines + ["", "Health check gagal:", *[f"- {item}" for item in health_failures]])
        lines.extend(
            [
                "",
                "Health check: OK",
                f"- backend tcp {tcp_port} listening",
                f"- ws proxy {ws_proxy_port} listening",
            ]
        )
    return (not had_failure), title, "\n".join(lines)


def op_openvpn_logs() -> tuple[str, str]:
    title = "Maintenance - OpenVPN Logs"
    chunks: list[str] = []
    for service in OPENVPN_SERVICES:
        load = _systemctl_show_props(service, ["LoadState"]).get("LoadState") or "unknown"
        if load == "not-found":
            continue
        unit = f"{service}.service"
        chunks.append(f"[{unit}]")
        chunks.append(_journal_tail(unit, lines=20))
        chunks.append("")
    if not chunks:
        return title, "Tidak ada unit OpenVPN yang terpasang."
    return title, _trim_message("\n".join(chunks).strip())


def op_daemon_status() -> tuple[str, str]:
    title = "Maintenance - Daemon Status"
    lines = ["Core Services:"]
    for service in ("xray", "nginx", "wireproxy"):
        lines.append(_unit_status_line(service))
    lines.extend(["", "Xray Daemons:"])
    for service in XRAY_DAEMONS:
        lines.append(_unit_status_line(service))
    lines.extend(["", "SSHWS Runtime:"])
    for service in SSHWS_SERVICES:
        lines.append(_unit_status_line(service))
    lines.append(_unit_status_line("sshws-qac-enforcer", unit_type="timer"))
    return title, "\n".join(lines)


def op_xray_daemon_logs() -> tuple[str, str]:
    title = "Maintenance - Xray Daemon Logs"
    chunks: list[str] = []
    for service in XRAY_DAEMONS:
        if not service_exists(service):
            continue
        chunks.append(f"[{service}]")
        chunks.append(_journal_tail(service, lines=12))
        chunks.append("")
    if not chunks:
        return title, "Tidak ada daemon Xray yang terpasang."
    return title, _trim_message("\n".join(chunks).strip())


def op_sshws_status() -> tuple[str, str]:
    title = "SSH Management - SSH WS Service Status"
    runtime_stale_sec = _sshws_runtime_env_value("SSHWS_RUNTIME_SESSION_STALE_SEC", "90") or "90"
    runtime_handshake_sec = _sshws_runtime_env_value("SSHWS_HANDSHAKE_TIMEOUT_SEC", "10") or "10"
    enforcer_state = _systemctl_show_props(
        "sshws-qac-enforcer.service",
        ["Result", "ExecMainStatus"],
    )
    enforcer_result = enforcer_state.get("Result") or "-"
    enforcer_exit = enforcer_state.get("ExecMainStatus") or "-"
    enforcer_last = _journal_last_line("sshws-qac-enforcer.service")
    lines = ["Services:"]
    for service in SSHWS_SERVICES:
        if service == "sshws-stunnel" and not service_exists(service):
            lines.append(f"- {service}.service: optional / not installed")
        else:
            lines.append(_unit_status_line(service))
    lines.append(_unit_status_line("sshws-qac-enforcer", unit_type="timer"))

    lines.extend(
        [
            "",
            "Public Ports:",
            f"- 80  : {'LISTENING' if _listener_present(80) else 'NOT listening'}",
            f"- 443 : {'LISTENING' if _listener_present(443) else 'NOT listening'}",
            "",
            "Internal Ports:",
            f"- dropbear : 127.0.0.1:{_sshws_dropbear_port()}",
            f"- stunnel  : 127.0.0.1:{_sshws_stunnel_port()}",
            f"- ws proxy : 127.0.0.1:{_sshws_proxy_port()}",
            "",
            "Runtime Env:",
            f"- env file      : {SSHWS_RUNTIME_ENV_FILE}",
            f"- stale sec     : {runtime_stale_sec}",
            f"- handshake sec : {runtime_handshake_sec}",
            "",
            "Enforcer:",
            f"- last result   : {enforcer_result}",
            f"- last exit code: {enforcer_exit}",
            f"- last journal  : {enforcer_last}",
        ]
    )
    return title, "\n".join(lines)


def op_sshws_diagnostics() -> tuple[str, str]:
    title = "Maintenance - SSH WS Diagnostics"
    domain = detect_domain()
    dropbear_port = _sshws_dropbear_port()
    stunnel_port = _sshws_stunnel_port()
    proxy_port = _sshws_proxy_port()
    probe_path = "/diagnostic-probe"

    lines = ["Services:"]
    for service in SSHWS_SERVICES:
        if service == "sshws-stunnel" and not service_exists(service):
            lines.append(f"- {service}.service: optional / not installed")
        else:
            lines.append(_unit_status_line(service))

    lines.extend(
        [
            "",
            "Internal Ports:",
            f"- dropbear : 127.0.0.1:{dropbear_port}",
            f"- stunnel  : 127.0.0.1:{stunnel_port}",
            f"- ws proxy : 127.0.0.1:{proxy_port}",
            f"- domain   : {domain}",
            f"- path     : {probe_path}",
            "",
            "Local Probes:",
            f"- dropbear tcp : {_probe_tcp_endpoint('127.0.0.1', dropbear_port)}",
            f"- proxy ws     : {_probe_ws_endpoint('127.0.0.1', proxy_port, path=probe_path, host_header=f'127.0.0.1:{proxy_port}')}",
        ]
    )
    if service_exists("sshws-stunnel"):
        lines.append(f"- stunnel tls  : {_probe_tcp_endpoint('127.0.0.1', stunnel_port, tls_mode=True)}")
    else:
        lines.append("- stunnel tls  : SKIP (optional)")

    lines.extend(["", "Public Path Probes:"])
    if _listener_present(80):
        lines.append(f"- nginx :80  : {_probe_ws_endpoint('127.0.0.1', 80, path=probe_path, host_header=domain or '127.0.0.1')}")
    else:
        lines.append("- nginx :80  : SKIP (not listening)")
    if domain and domain != "-" and _listener_present(443):
        lines.append(
            f"- nginx :443 : {_probe_ws_endpoint('127.0.0.1', 443, path=probe_path, host_header=domain, tls_mode=True, sni=domain)}"
        )
    else:
        lines.append("- nginx :443 : SKIP (domain/443 unavailable)")

    lines.extend(
        [
            "",
            "Notes:",
            "- HTTP 101 menandakan chain SSHWS sehat.",
            "- HTTP 502 biasanya berarti backend internal belum siap.",
            "- HTTP 401/403 berarti probe path ditolak oleh guard/proxy.",
        ]
    )
    return title, _trim_message("\n".join(lines))


def op_sshws_combined_logs() -> tuple[str, str]:
    title = "Maintenance - SSHWS Combined Logs"
    chunks: list[str] = []
    units = (
        ("sshws-proxy", "service", 8),
        ("sshws-qac-enforcer", "service", 8),
        ("sshws-dropbear", "service", 6),
        ("sshws-stunnel", "service", 6),
    )
    for service, unit_type, lines in units:
        if not service_exists(service, unit_type=unit_type):
            continue
        unit = f"{service}.{unit_type}"
        chunks.append(f"[{unit}]")
        chunks.append(_journal_tail(unit, lines=lines))
        chunks.append("")
    if not chunks:
        return title, "Tidak ada unit SSHWS yang terpasang."
    return title, _trim_message("\n".join(chunks).strip())


def op_sshws_active_sessions() -> tuple[str, str]:
    title = "User Management - Active SSHWS Sessions"
    if not SSHWS_RUNTIME_SESSION_DIR.exists():
        return title, f"Runtime session dir tidak ditemukan: {SSHWS_RUNTIME_SESSION_DIR}"

    if not SSHWS_CONTROL_BIN.exists():
        return title, f"Helper SSHWS tidak ditemukan: {SSHWS_CONTROL_BIN}"

    ok, out = run_cmd(
        [
            str(SSHWS_CONTROL_BIN),
            "session-list",
            "--session-root",
            str(SSHWS_RUNTIME_SESSION_DIR),
        ],
        timeout=20,
    )
    if not ok:
        return title, f"Gagal membaca sesi aktif SSHWS.\n\n{out}"
    try:
        payload = json.loads(out)
    except Exception as exc:
        return title, f"Gagal parse output helper SSHWS: {exc}"

    raw_sessions = payload.get("sessions")
    raw_counts = payload.get("counts")
    if not isinstance(raw_sessions, list):
        raw_sessions = []
    if not isinstance(raw_counts, dict):
        raw_counts = {}

    sessions: list[dict[str, str]] = []
    counts: Counter[str] = Counter()
    for item in raw_sessions:
        if not isinstance(item, dict):
            continue
        username = str(item.get("username") or "").strip()
        if not username:
            continue
        backend_port = str(item.get("backend_port") or item.get("backend_local_port") or "-").strip() or "-"
        backend_target = str(item.get("backend_target") or item.get("backend") or "-").strip() or "-"
        client_ip = str(item.get("client_ip") or "-").strip() or "-"
        proxy_pid = str(item.get("proxy_pid") or "-").strip() or "-"
        created_raw = item.get("created_at")
        created_text = "-"
        try:
            created_text = datetime.fromtimestamp(int(created_raw), tz=timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
        except Exception:
            pass
        updated_raw = item.get("updated_at")
        updated_text = "-"
        try:
            updated_text = datetime.fromtimestamp(int(updated_raw), tz=timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
        except Exception:
            pass
        counts[username] += 1
        sessions.append(
            {
                "username": username,
                "backend_port": backend_port,
                "backend_target": backend_target,
                "client_ip": client_ip,
                "proxy_pid": proxy_pid,
                "created_at": created_text,
                "updated_at": updated_text,
                "session_file": str(item.get("session_file") or "-").strip() or "-",
            }
        )

    if not counts and raw_counts:
        for username, value in raw_counts.items():
            try:
                counts[str(username)] = int(value)
            except Exception:
                continue

    if not sessions:
        return title, "Belum ada sesi aktif SSHWS."

    summary_lines = [f"- {user}: {counts[user]} sesi" for user in sorted(counts.keys())]
    detail_lines = [
        f"{idx+1:03d}. {item['username']} | ip={item['client_ip']} | port={item['backend_port']} | backend={item['backend_target']} | pid={item['proxy_pid']} | created={item['created_at']} | updated={item['updated_at']} | file={item['session_file']}"
        for idx, item in enumerate(sessions[:200])
    ]
    msg = "\n".join(
        [
            f"Total sesi aktif : {len(sessions)}",
            f"Total user aktif : {len(counts)}",
            "",
            "Ringkasan per user:",
            *summary_lines,
            "",
            "Detail sesi (maks 200):",
            *detail_lines,
        ]
    )
    return title, msg
