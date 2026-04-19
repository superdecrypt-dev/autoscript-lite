#!/usr/bin/env python3
import argparse
import base64
import grp
import json
import os
import secrets
import subprocess
import sys
import tempfile
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import quote


ROOT = Path(os.environ.get("HYSTERIA2_ROOT", "/etc/autoscript/hysteria2"))
ENV_FILE = Path(os.environ.get("HYSTERIA2_ENV_FILE", str(ROOT / "config.env")))
USERS_FILE = Path(os.environ.get("HYSTERIA2_USERS_FILE", str(ROOT / "users.json")))
XRAY_CONFDIR = Path(os.environ.get("XRAY_CONFDIR", "/usr/local/etc/xray/conf.d"))
XRAY_HYSTERIA_FRAGMENT = Path(os.environ.get("HYSTERIA2_XRAY_FRAGMENT", str(XRAY_CONFDIR / "15-hysteria2.json")))
CONFIG_FILE = Path(os.environ.get("HYSTERIA2_CONFIG_FILE", str(XRAY_HYSTERIA_FRAGMENT)))
ACCOUNT_ROOT = Path(os.environ.get("HYSTERIA2_ACCOUNT_ROOT", "/opt/account/hysteria2"))
CERT_FULLCHAIN = os.environ.get("CERT_FULLCHAIN", "/opt/cert/fullchain.pem")
CERT_PRIVKEY = os.environ.get("CERT_PRIVKEY", "/opt/cert/privkey.pem")
DOMAIN_FILE = Path(os.environ.get("XRAY_DOMAIN_FILE", "/etc/xray/domain"))
BOOTSTRAP_USER = "__bootstrap__"
BOOTSTRAP_EMAIL = "default@hy2"
EXPIRED_CLEANER_UNIT = os.environ.get("HYSTERIA2_EXPIRED_SERVICE", "hysteria2-expired.service")
BACKEND_SERVICE = os.environ.get("HYSTERIA2_SERVICE", "xray.service")
INBOUND_TAG = os.environ.get("HYSTERIA2_INBOUND_TAG", "hy2-in")
PASSWORD_ALPHABET = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*"
HEADER_CUSTOM_CLIENT_PACKET = "HELLO"
HEADER_CUSTOM_SERVER_PACKET = "WORLD"


def now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def display_created_at(value: str) -> str:
    raw = str(value or "").strip()
    if not raw:
        return "-"
    try:
        parsed = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        return raw
    return parsed.astimezone(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")


def utc_today() -> date:
    return datetime.now(timezone.utc).date()


def parse_expired_at(value: str) -> date | None:
    raw = str(value or "").strip()
    if raw in {"", "-", "0"}:
        return None
    try:
        return date.fromisoformat(raw[:10])
    except ValueError:
        return None


def display_expired_at(value: str) -> str:
    parsed = parse_expired_at(value)
    if parsed is None:
        return "Unlimited"
    return parsed.isoformat()


def resolve_expired_at(days_text: str, explicit_date: str) -> str:
    if days_text and explicit_date:
        raise SystemExit("gunakan salah satu: --days atau --expired-at")
    if explicit_date:
        parsed = parse_expired_at(explicit_date)
        if parsed is None:
            raise SystemExit("expired_at format wajib YYYY-MM-DD")
        return parsed.isoformat()
    if not days_text:
        return "-"
    try:
        days = int(days_text)
    except ValueError as exc:
        raise SystemExit("days harus berupa angka bulat >= 0") from exc
    if days < 0:
        raise SystemExit("days harus >= 0")
    if days == 0:
        return "-"
    return (utc_today() + timedelta(days=days)).isoformat()


def load_env() -> dict[str, str]:
    data: dict[str, str] = {}
    if ENV_FILE.exists():
        for line in ENV_FILE.read_text(encoding="utf-8").splitlines():
            stripped = line.strip()
            if not stripped or stripped.startswith("#") or "=" not in stripped:
                continue
            key, value = stripped.split("=", 1)
            data[key.strip()] = value.strip()
    return data


def save_text_atomic(path: Path, text: str, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".tmp.", suffix=path.suffix or ".tmp", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise


def save_json_atomic(path: Path, data: object, mode: int = 0o600) -> None:
    save_text_atomic(path, json.dumps(data, indent=2) + "\n", mode=mode)


def generate_password(length: int) -> str:
    return "".join(secrets.choice(PASSWORD_ALPHABET) for _ in range(length))


def save_env(env: dict[str, str]) -> None:
    content = "".join(f"{key}={env[key]}\n" for key in sorted(env))
    save_text_atomic(ENV_FILE, content, mode=0o600)


def env_domain(env: dict[str, str]) -> str:
    value = str(env.get("HYSTERIA2_SERVER_NAME", "")).strip()
    if value:
        return value
    return domain_value()


def ensure_ech_server_keys(server_name: str) -> str:
    try:
        result = subprocess.run(
            ["xray", "tls", "ech", "--serverName", server_name],
            capture_output=True,
            check=False,
            text=True,
        )
    except FileNotFoundError as exc:
        raise SystemExit("xray binary tidak ditemukan untuk generate ECH server keys") from exc
    if result.returncode != 0:
        raise SystemExit(f"gagal generate ECH server keys untuk {server_name}")
    lines = result.stdout.splitlines()
    for idx, line in enumerate(lines):
        if line.strip() == "ECH server keys:" and idx + 1 < len(lines):
            value = lines[idx + 1].strip()
            if value:
                return value
    raise SystemExit(f"output xray tls ech tidak memuat ECH server keys untuk {server_name}")


def ensure_secret(env: dict[str, str], key: str, length: int) -> bool:
    current = str(env.get(key, "")).strip()
    if current:
        return False
    env[key] = generate_password(length)
    return True


def ensure_env_defaults() -> dict[str, str]:
    env = load_env()
    changed = False
    defaults = {
        "HYSTERIA2_PORT": os.environ.get("HYSTERIA2_PORT", "443"),
        "HYSTERIA2_MASQUERADE_URL": os.environ.get("HYSTERIA2_MASQUERADE_URL", "https://www.cloudflare.com/"),
        "HYSTERIA2_CONFIG_FILE": os.environ.get("HYSTERIA2_CONFIG_FILE", str(XRAY_HYSTERIA_FRAGMENT)),
        "HYSTERIA2_SERVICE": os.environ.get("HYSTERIA2_SERVICE", "xray.service"),
        "HYSTERIA2_UDPHOP_PORTS": os.environ.get("HYSTERIA2_UDPHOP_PORTS", "20000-40000"),
        "HYSTERIA2_UDPHOP_INTERVAL": os.environ.get("HYSTERIA2_UDPHOP_INTERVAL", "5"),
    }
    for key, value in defaults.items():
        current = str(env.get(key, "")).strip()
        if not current:
            env[key] = value
            changed = True
    if not str(env.get("HYSTERIA2_SERVER_NAME", "")).strip():
        env["HYSTERIA2_SERVER_NAME"] = domain_value()
        changed = True
    if not str(env.get("HYSTERIA2_TLS_SERVER_NAME", "")).strip():
        env["HYSTERIA2_TLS_SERVER_NAME"] = env["HYSTERIA2_SERVER_NAME"]
        changed = True
    if not str(env.get("HYSTERIA2_MASQUERADE_DIR", "")).strip():
        env["HYSTERIA2_MASQUERADE_DIR"] = "/var/www/html"
        changed = True
    if not str(env.get("HYSTERIA2_MASQUERADE_REWRITE_HOST", "")).strip():
        env["HYSTERIA2_MASQUERADE_REWRITE_HOST"] = "true"
        changed = True
    if not str(env.get("HYSTERIA2_MASQUERADE_STATUS_CODE", "")).strip():
        env["HYSTERIA2_MASQUERADE_STATUS_CODE"] = "200"
        changed = True
    if not str(env.get("HYSTERIA2_MASQUERADE_HEADERS", "")).strip():
        env["HYSTERIA2_MASQUERADE_HEADERS"] = json.dumps(
            {
                "Server": "nginx",
                "Content-Type": "text/html; charset=utf-8",
                "Cache-Control": "no-cache, no-store, must-revalidate",
                "X-Frame-Options": "DENY",
                "X-Content-Type-Options": "nosniff",
            },
            ensure_ascii=False,
            separators=(",", ":"),
        )
        changed = True
    if not str(env.get("HYSTERIA2_CURVE_PREFERENCES", "")).strip():
        env["HYSTERIA2_CURVE_PREFERENCES"] = "X25519MLKEM768,X25519"
        changed = True
    if not str(env.get("HYSTERIA2_ECH_FORCE_QUERY", "")).strip():
        env["HYSTERIA2_ECH_FORCE_QUERY"] = "full"
        changed = True
    changed = ensure_secret(env, "HYSTERIA2_SALAMANDER_PASSWORD", 14) or changed
    legacy_config = str(ROOT / "config.yaml")
    if str(env.get("HYSTERIA2_CONFIG_FILE", "")).strip() == legacy_config:
        env["HYSTERIA2_CONFIG_FILE"] = str(XRAY_HYSTERIA_FRAGMENT)
        changed = True
    if str(env.get("HYSTERIA2_SERVICE", "")).strip() in {"", "hysteria2.service"}:
        env["HYSTERIA2_SERVICE"] = "xray.service"
        changed = True
    if not str(env.get("HYSTERIA2_ECH_SERVER_KEYS", "")).strip():
        env["HYSTERIA2_ECH_SERVER_KEYS"] = ensure_ech_server_keys(env["HYSTERIA2_TLS_SERVER_NAME"])
        changed = True
    if "HYSTERIA2_SUDOKU_PASSWORD" in env:
        env.pop("HYSTERIA2_SUDOKU_PASSWORD", None)
        changed = True
    if changed or not ENV_FILE.exists():
        save_env(env)
    return env


def load_users() -> dict:
    if USERS_FILE.exists():
        try:
            data = json.loads(USERS_FILE.read_text(encoding="utf-8"))
        except Exception:
            data = {}
    else:
        data = {}
    if not isinstance(data, dict):
        data = {}
    users = data.get("users")
    if not isinstance(users, list):
        users = []
    data["users"] = users
    return data


def visible_users(data: dict) -> list[dict]:
    result = []
    for item in data.get("users", []):
        if not isinstance(item, dict):
            continue
        if item.get("hidden") is True:
            continue
        if item.get("username", "").startswith("__"):
            continue
        if user_is_expired(item):
            continue
        result.append(item)
    return result


def auth_users(data: dict) -> list[dict]:
    result = []
    for item in data.get("users", []):
        if not isinstance(item, dict):
            continue
        if item.get("hidden") is True or item.get("username", "").startswith("__"):
            result.append(item)
            continue
        if user_is_expired(item):
            continue
        result.append(item)
    return result


def user_is_expired(item: dict) -> bool:
    if item.get("hidden") is True or str(item.get("username", "")).startswith("__"):
        return False
    expired_at = parse_expired_at(str(item.get("expired_at", "")).strip())
    if expired_at is None:
        return False
    return utc_today() > expired_at


def prune_expired_users(data: dict) -> tuple[dict, list[dict]]:
    users = []
    removed = []
    for item in data.get("users", []):
        if not isinstance(item, dict):
            continue
        if user_is_expired(item):
            removed.append(item)
            continue
        users.append(item)
    data["users"] = users
    return data, removed


def ensure_bootstrap_user(data: dict) -> dict:
    users = [item for item in data.get("users", []) if isinstance(item, dict)]
    for item in users:
        if item.get("username") == BOOTSTRAP_USER:
            data["users"] = users
            return data
    users.append(
        {
            "username": BOOTSTRAP_USER,
            "password": generate_password(28),
            "created_at": now_iso(),
            "expired_at": "-",
            "hidden": True,
        }
    )
    data["users"] = users
    return data


def domain_value() -> str:
    if DOMAIN_FILE.exists():
        value = DOMAIN_FILE.read_text(encoding="utf-8").strip()
        if value:
            return value
    return "example.com"


def yaml_quote(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def ensure_xray_fragment_permissions(path: Path) -> None:
    try:
        gid = grp.getgrnam("xray").gr_gid
    except KeyError:
        gid = None
    try:
        if gid is not None:
            os.chown(path, 0, gid)
        os.chmod(path, 0o640)
    except OSError:
        pass


def env_port(env: dict[str, str]) -> str:
    value = str(env.get("HYSTERIA2_PORT", "443")).strip()
    return value or "443"


def account_uri(username: str, password: str, domain: str, port: str) -> str:
    return (
        f"hysteria2://{quote(password, safe='')}@{domain}:{port}/"
        f"?sni={quote(domain, safe='')}"
        f"#{quote(username + '@hy2', safe='')}"
    )


def finalmask_udp_config(env: dict[str, str]) -> list[dict]:
    salamander_password = str(env.get("HYSTERIA2_SALAMANDER_PASSWORD", "")).strip()
    items: list[dict] = []
    if salamander_password:
        items.append(
            {
                "type": "salamander",
                "settings": {
                    "password": salamander_password,
                },
            }
        )
    items.append(
        {
            "type": "header-custom",
            "settings": {
                "client": [
                    {
                        "type": "str",
                        "packet": HEADER_CUSTOM_CLIENT_PACKET,
                    }
                ],
                "server": [
                    {
                        "type": "str",
                        "packet": HEADER_CUSTOM_SERVER_PACKET,
                    }
                ],
            },
        }
    )
    return items


def quic_params_config(env: dict[str, str]) -> dict:
    udp_hop_ports = str(env.get("HYSTERIA2_UDPHOP_PORTS", "20000-40000")).strip() or "20000-40000"
    udp_hop_interval = str(env.get("HYSTERIA2_UDPHOP_INTERVAL", "5")).strip() or "5"
    return {
        "congestion": "bbr",
        "brutalUp": "50 mbps",
        "brutalDown": "100 mbps",
        "udpHop": {
            "ports": udp_hop_ports,
            "interval": udp_hop_interval,
        },
        "maxIdleTimeout": 20,
        "keepAlivePeriod": 8,
        "initStreamReceiveWindow": 4194304,
        "maxStreamReceiveWindow": 4194304,
        "disablePathMTUDiscovery": False,
    }


def xray_client_default_config(snapshot: dict[str, str], env: dict[str, str]) -> dict:
    domain = snapshot["domain"]
    port = int(snapshot["port"])
    password = snapshot["password"]
    return {
        "log": {
            "loglevel": "warning",
        },
        "inbounds": [
            {
                "tag": "socks-in",
                "listen": "127.0.0.1",
                "port": 10808,
                "protocol": "socks",
                "settings": {
                    "udp": True,
                },
            }
        ],
        "outbounds": [
            {
                "tag": "hy2-out",
                "protocol": "hysteria",
                "settings": {
                    "version": 2,
                    "address": domain,
                    "port": port,
                },
                "streamSettings": {
                    "network": "hysteria",
                    "security": "tls",
                    "tlsSettings": {
                        "serverName": domain,
                        "alpn": ["h3"],
                    },
                    "hysteriaSettings": {
                        "version": 2,
                        "auth": password,
                        "udpIdleTimeout": 60,
                        "masquerade": {
                            "type": "file",
                            "dir": str(env.get("HYSTERIA2_MASQUERADE_DIR", "/var/www/html")).strip() or "/var/www/html",
                            "rewriteHost": str(env.get("HYSTERIA2_MASQUERADE_REWRITE_HOST", "true")).strip().lower() == "true",
                            "headers": json.loads(str(env.get("HYSTERIA2_MASQUERADE_HEADERS", "{}")).strip() or "{}"),
                            "statusCode": int(str(env.get("HYSTERIA2_MASQUERADE_STATUS_CODE", "200")).strip() or "200"),
                        },
                    },
                    "finalmask": {
                        "udp": finalmask_udp_config(env),
                        "quicParams": quic_params_config(env),
                    },
                    "sockopt": {
                        "mark": 255,
                        "tcpCongestion": "bbr",
                    },
                },
            },
            {
                "tag": "direct",
                "protocol": "freedom",
            },
        ],
        "routing": {
            "rules": [
                {
                    "type": "field",
                    "inboundTag": ["socks-in"],
                    "outboundTag": "hy2-out",
                }
            ],
        },
    }


def user_snapshot(item: dict, env: dict[str, str]) -> dict[str, str]:
    username = str(item.get("username", "")).strip()
    password = str(item.get("password", "")).strip()
    created_at = str(item.get("created_at", "")).strip()
    expired_at = str(item.get("expired_at", "")).strip()
    domain = domain_value()
    port = env_port(env)
    account_file = ACCOUNT_ROOT / f"{username}@hy2.txt"
    return {
        "username": username,
        "password": password,
        "created_at": created_at,
        "expired_at": expired_at,
        "domain": domain,
        "port": port,
        "account_file": str(account_file),
        "uri": account_uri(username, password, domain, port),
    }


def systemctl_show_value(unit: str, key: str, default: str = "unknown") -> str:
    try:
        result = subprocess.run(
            ["systemctl", "show", "-p", key, unit],
            capture_output=True,
            check=False,
            text=True,
        )
    except FileNotFoundError:
        return default
    if result.returncode != 0:
        return default
    line = result.stdout.strip()
    if "=" not in line:
        return line or default
    value = line.split("=", 1)[1].strip()
    return value or default


def dual_line(left: str, right: str = "", width: int = 44) -> str:
    if not right:
        return left
    return f"{left:<{width}}{right}"


def latest_visible_snapshot(data: dict, env: dict[str, str]) -> dict[str, str] | None:
    users = visible_users(data)
    if not users:
        return None
    return user_snapshot(users[-1], env)


def render_config(env: dict[str, str], data: dict) -> None:
    port_text = env_port(env)
    try:
        port = int(port_text or "443")
    except ValueError:
        port = 443
    server_name = env_domain(env)
    tls_server_name = str(env.get("HYSTERIA2_TLS_SERVER_NAME", server_name)).strip() or server_name
    masquerade_dir = str(env.get("HYSTERIA2_MASQUERADE_DIR", "/var/www/html")).strip() or "/var/www/html"
    masquerade_rewrite_host = str(env.get("HYSTERIA2_MASQUERADE_REWRITE_HOST", "true")).strip().lower() == "true"
    try:
        masquerade_status_code = int(str(env.get("HYSTERIA2_MASQUERADE_STATUS_CODE", "200")).strip() or "200")
    except ValueError:
        masquerade_status_code = 200
    try:
        masquerade_headers = json.loads(str(env.get("HYSTERIA2_MASQUERADE_HEADERS", "{}")).strip() or "{}")
        if not isinstance(masquerade_headers, dict):
            masquerade_headers = {}
    except json.JSONDecodeError:
        masquerade_headers = {}
    ech_server_keys = str(env.get("HYSTERIA2_ECH_SERVER_KEYS", "")).strip()
    curve_preferences = [
        item.strip()
        for item in str(env.get("HYSTERIA2_CURVE_PREFERENCES", "X25519MLKEM768,X25519")).split(",")
        if item.strip()
    ]
    clients = []
    for item in auth_users(data):
        if not isinstance(item, dict):
            continue
        username = str(item.get("username", "")).strip()
        password = str(item.get("password", "")).strip()
        if not username or not password:
            continue
        if item.get("hidden") is True or username.startswith("__"):
            email = BOOTSTRAP_EMAIL
        else:
            email = f"{username}@hy2"
        clients.append(
            {
                "auth": password,
                "level": 0,
                "email": email,
            }
        )

    bootstrap = next(
        (
            item
            for item in data.get("users", [])
            if isinstance(item, dict) and item.get("username") == BOOTSTRAP_USER
        ),
        None,
    )
    bootstrap_auth = str((bootstrap or {}).get("password", "")).strip()
    if not bootstrap_auth:
        bootstrap_auth = generate_password(28)

    inbound = {
        "tag": INBOUND_TAG,
        "listen": "::",
        "port": port,
        "protocol": "hysteria",
        "settings": {
            "version": 2,
            "clients": clients,
        },
        "streamSettings": {
            "network": "hysteria",
            "hysteriaSettings": {
                "version": 2,
                "auth": bootstrap_auth,
                "udpIdleTimeout": 60,
                "masquerade": {
                    "type": "file",
                    "dir": masquerade_dir,
                    "rewriteHost": masquerade_rewrite_host,
                    "headers": masquerade_headers,
                    "statusCode": masquerade_status_code,
                },
            },
            "security": "tls",
            "tlsSettings": {
                "serverName": tls_server_name,
                "alpn": ["h3"],
                "certificates": [
                    {
                        "certificateFile": CERT_FULLCHAIN,
                        "keyFile": CERT_PRIVKEY,
                        "ocspStapling": 3600,
                    }
                ],
                "echServerKeys": ech_server_keys,
                "echForceQuery": str(env.get("HYSTERIA2_ECH_FORCE_QUERY", "full")).strip() or "full",
                "curvePreferences": curve_preferences,
            },
            "finalmask": {
                "udp": finalmask_udp_config(env),
                "quicParams": quic_params_config(env),
            },
            "sockopt": {
                "tcpCongestion": "bbr",
                "tcpFastOpen": True,
                "tcpKeepAliveIdle": 120,
                "tcpKeepAliveInterval": 30,
                "mark": 255,
            },
        },
        "sniffing": {
            "enabled": True,
            "destOverride": ["http", "tls", "quic", "fakedns"],
            "routeOnly": False,
            "metadataOnly": False,
        },
    }

    save_json_atomic(CONFIG_FILE, {"inbounds": [inbound]}, mode=0o600)
    ensure_xray_fragment_permissions(CONFIG_FILE)


def render_account_files(env: dict[str, str], data: dict) -> None:
    ACCOUNT_ROOT.mkdir(parents=True, exist_ok=True)
    domain = domain_value()
    port = env_port(env)
    visible = visible_users(data)
    keep_txt = set()
    keep_json = set()
    for item in visible:
        snapshot = user_snapshot(item, env)
        username = snapshot["username"]
        password = snapshot["password"]
        created_at = snapshot["created_at"]
        expired_at = snapshot["expired_at"]
        uri = snapshot["uri"]
        path = ACCOUNT_ROOT / f"{username}@hy2.txt"
        xray_path = ACCOUNT_ROOT / f"{username}@hy2.xray.json"
        content = [
            dual_line("=== HYSTERIA 2 ACCOUNT INFO ===", f"Domain      : {domain}"),
            f"  Username    : {username}",
            f"  Password    : {password}",
            "  Protocol    : hysteria2",
            "  Transport   : QUIC",
            "  TLS         : enabled",
            "  Auth Type   : password",
            dual_line(f"  Port UDP    : {port}", f"SNI         : {domain}"),
            f"  Masquerade  : {env.get('HYSTERIA2_MASQUERADE_URL', 'https://www.cloudflare.com/')}",
            f"  Valid Until : {display_expired_at(expired_at)}",
            f"  Created     : {display_created_at(created_at)}",
            "",
            "=== ACCESS CONFIG ===",
            "  Import Type : Xray JSON",
            f"  Xray Config : {xray_path}",
            "",
        ]
        save_text_atomic(path, "\n".join(content), mode=0o600)
        save_json_atomic(xray_path, xray_client_default_config(snapshot, env), mode=0o600)
        keep_txt.add(path.name)
        keep_json.add(xray_path.name)
    for existing in ACCOUNT_ROOT.glob("*.txt"):
        if existing.name not in keep_txt:
            existing.unlink(missing_ok=True)
    for existing in ACCOUNT_ROOT.glob("*.xray.json"):
        if existing.name not in keep_json:
            existing.unlink(missing_ok=True)


def ensure_runtime() -> tuple[dict[str, str], dict]:
    ROOT.mkdir(parents=True, exist_ok=True)
    env = ensure_env_defaults()
    data = ensure_bootstrap_user(load_users())
    save_json_atomic(USERS_FILE, data, mode=0o600)
    render_config(env, data)
    render_account_files(env, data)
    return env, data


def validate_username(value: str) -> str:
    allowed = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
    if not value or any(ch not in allowed for ch in value):
        raise SystemExit("username hanya boleh huruf, angka, titik, underscore, dan dash")
    if value.startswith("__"):
        raise SystemExit("username dengan prefix __ dicadangkan untuk runtime internal")
    return value


def add_user(args: argparse.Namespace) -> int:
    env, data = ensure_runtime()
    username = validate_username(args.username.strip())
    password = (args.password or "").strip() or generate_password(28)
    expired_at = resolve_expired_at((args.days or "").strip(), (args.expired_at or "").strip())
    users = data["users"]
    if any(isinstance(item, dict) and item.get("username") == username for item in users):
        raise SystemExit(f"user sudah ada: {username}")
    users.append(
        {
            "username": username,
            "password": password,
            "created_at": now_iso(),
            "expired_at": expired_at,
            "hidden": False,
        }
    )
    data["users"] = users
    save_json_atomic(USERS_FILE, data, mode=0o600)
    render_config(env, data)
    render_account_files(env, data)
    print(f"USERNAME={username}")
    print(f"PASSWORD={password}")
    print(f"EXPIRED_AT={display_expired_at(expired_at)}")
    return 0


def delete_user(args: argparse.Namespace) -> int:
    env, data = ensure_runtime()
    username = args.username.strip()
    new_users = []
    removed = False
    for item in data["users"]:
        if not isinstance(item, dict):
            continue
        if item.get("username") == username and not item.get("hidden"):
            removed = True
            continue
        new_users.append(item)
    if not removed:
        raise SystemExit(f"user tidak ditemukan: {username}")
    data["users"] = new_users
    save_json_atomic(USERS_FILE, data, mode=0o600)
    render_config(env, data)
    render_account_files(env, data)
    print(f"DELETED={username}")
    return 0


def list_users_cmd(_: argparse.Namespace) -> int:
    env, data = ensure_runtime()
    for item in visible_users(data):
        snapshot = user_snapshot(item, env)
        print(
            f"{snapshot['username']}\t{display_created_at(snapshot['created_at'])}\t"
            f"{display_expired_at(snapshot['expired_at'])}\t{snapshot['uri']}"
        )
    return 0


def prune_expired_cmd(_: argparse.Namespace) -> int:
    env, data = ensure_runtime()
    data, removed = prune_expired_users(data)
    if removed:
        save_json_atomic(USERS_FILE, data, mode=0o600)
    render_config(env, data)
    render_account_files(env, data)
    removed_users = ",".join(str(item.get("username", "")).strip() for item in removed if item.get("username"))
    print(f"REMOVED_COUNT={len(removed)}")
    print(f"REMOVED_USERS={removed_users}")
    return 0


def status_cmd(_: argparse.Namespace) -> int:
    env, data = ensure_runtime()
    visible = visible_users(data)
    latest = latest_visible_snapshot(data, env)
    service_unit = BACKEND_SERVICE
    print(f"SERVICE_UNIT={service_unit}")
    print(f"SERVICE_STATE={systemctl_show_value(service_unit, 'ActiveState')}")
    print(f"SERVICE_SUBSTATE={systemctl_show_value(service_unit, 'SubState')}")
    print(f"SERVICE_ENABLED={systemctl_show_value(service_unit, 'UnitFileState')}")
    print("BACKEND=Xray native inbound")
    print(f"EXPIRED_CLEANER_UNIT={EXPIRED_CLEANER_UNIT}")
    print(f"EXPIRED_CLEANER_STATE={systemctl_show_value(EXPIRED_CLEANER_UNIT, 'ActiveState')}")
    print(f"EXPIRED_CLEANER_SUBSTATE={systemctl_show_value(EXPIRED_CLEANER_UNIT, 'SubState')}")
    print(f"EXPIRED_CLEANER_ENABLED={systemctl_show_value(EXPIRED_CLEANER_UNIT, 'UnitFileState')}")
    print(f"PORT={env_port(env)}")
    print(f"DOMAIN={domain_value()}")
    print(f"MASQUERADE_URL={env.get('HYSTERIA2_MASQUERADE_URL', 'https://www.cloudflare.com/')}")
    print(f"USER_COUNT={len(visible)}")
    if latest is not None:
        print(f"LATEST_USERNAME={latest['username']}")
        print(f"LATEST_CREATED_AT={display_created_at(latest['created_at'])}")
        print(f"LATEST_EXPIRED_AT={display_expired_at(latest['expired_at'])}")
    else:
        print("LATEST_USERNAME=")
        print("LATEST_CREATED_AT=")
        print("LATEST_EXPIRED_AT=")
    print(f"CONFIG_FILE={CONFIG_FILE}")
    print(f"USERS_FILE={USERS_FILE}")
    print(f"ACCOUNT_ROOT={ACCOUNT_ROOT}")
    print(f"XRAY_FRAGMENT_FILE={CONFIG_FILE}")
    print(f"INBOUND_TAG={INBOUND_TAG}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("ensure-runtime")
    add = sub.add_parser("add-user")
    add.add_argument("--username", required=True)
    add.add_argument("--password", default="")
    add.add_argument("--days", default="")
    add.add_argument("--expired-at", default="")
    delete = sub.add_parser("delete-user")
    delete.add_argument("--username", required=True)
    sub.add_parser("list-users")
    sub.add_parser("prune-expired")
    sub.add_parser("status")
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    if args.command == "ensure-runtime":
        ensure_runtime()
        return 0
    if args.command == "add-user":
        return add_user(args)
    if args.command == "delete-user":
        return delete_user(args)
    if args.command == "list-users":
        return list_users_cmd(args)
    if args.command == "prune-expired":
        return prune_expired_cmd(args)
    if args.command == "status":
        return status_cmd(args)
    parser.error("command tidak dikenal")
    return 1


if __name__ == "__main__":
    sys.exit(main())
