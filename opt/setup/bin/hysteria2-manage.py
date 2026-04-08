#!/usr/bin/env python3
import argparse
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
CONFIG_FILE = Path(os.environ.get("HYSTERIA2_CONFIG_FILE", str(ROOT / "config.yaml")))
ACCOUNT_ROOT = Path(os.environ.get("HYSTERIA2_ACCOUNT_ROOT", "/opt/account/hysteria2"))
CERT_FULLCHAIN = os.environ.get("CERT_FULLCHAIN", "/opt/cert/fullchain.pem")
CERT_PRIVKEY = os.environ.get("CERT_PRIVKEY", "/opt/cert/privkey.pem")
DOMAIN_FILE = Path(os.environ.get("XRAY_DOMAIN_FILE", "/etc/xray/domain"))
BOOTSTRAP_USER = "__bootstrap__"
EXPIRED_CLEANER_UNIT = os.environ.get("HYSTERIA2_EXPIRED_SERVICE", "hysteria2-expired.service")


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


def ensure_env_defaults() -> dict[str, str]:
    env = load_env()
    changed = False
    defaults = {
        "HYSTERIA2_PORT": os.environ.get("HYSTERIA2_PORT", "443"),
        "HYSTERIA2_MASQUERADE_URL": os.environ.get("HYSTERIA2_MASQUERADE_URL", "https://www.cloudflare.com/"),
    }
    for key, value in defaults.items():
        if not env.get(key):
            env[key] = value
            changed = True
    if changed or not ENV_FILE.exists():
        content = "".join(f"{key}={env[key]}\n" for key in sorted(env))
        save_text_atomic(ENV_FILE, content, mode=0o600)
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
            "password": secrets.token_urlsafe(24),
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


def env_port(env: dict[str, str]) -> str:
    value = str(env.get("HYSTERIA2_PORT", "443")).strip()
    return value or "443"


def account_uri(username: str, password: str, domain: str, port: str) -> str:
    return (
        f"hysteria2://{quote(username, safe='')}:{quote(password, safe='')}@{domain}:{port}/"
        f"?sni={quote(domain, safe='')}"
        f"#{quote(username + '@hy2', safe='')}"
    )


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


def latest_visible_snapshot(data: dict, env: dict[str, str]) -> dict[str, str] | None:
    users = visible_users(data)
    if not users:
        return None
    return user_snapshot(users[-1], env)


def render_config(env: dict[str, str], data: dict) -> None:
    port = env_port(env)
    masquerade_url = env.get("HYSTERIA2_MASQUERADE_URL", "https://www.cloudflare.com/")
    lines = [
        f"listen: :{port}",
        "tls:",
        f"  cert: {yaml_quote(CERT_FULLCHAIN)}",
        f"  key: {yaml_quote(CERT_PRIVKEY)}",
        "auth:",
        "  type: userpass",
        "  userpass:",
    ]
    for item in auth_users(data):
        if not isinstance(item, dict):
            continue
        username = str(item.get("username", "")).strip()
        password = str(item.get("password", "")).strip()
        if not username or not password:
            continue
        lines.append(f"    {yaml_quote(username)}: {yaml_quote(password)}")
    lines.extend(
        [
            "masquerade:",
            "  type: proxy",
            "  proxy:",
            f"    url: {yaml_quote(masquerade_url)}",
            "    rewriteHost: true",
        ]
    )
    save_text_atomic(CONFIG_FILE, "\n".join(lines) + "\n", mode=0o600)


def render_account_files(env: dict[str, str], data: dict) -> None:
    ACCOUNT_ROOT.mkdir(parents=True, exist_ok=True)
    domain = domain_value()
    port = env_port(env)
    visible = visible_users(data)
    keep = set()
    for item in visible:
        snapshot = user_snapshot(item, env)
        username = snapshot["username"]
        password = snapshot["password"]
        created_at = snapshot["created_at"]
        expired_at = snapshot["expired_at"]
        uri = snapshot["uri"]
        path = ACCOUNT_ROOT / f"{username}@hy2.txt"
        content = [
            "=== HYSTERIA 2 ACCOUNT INFO ===",
            f"Username            : {username}",
            f"Password            : {password}",
            f"Domain              : {domain}",
            f"Port UDP            : {port}",
            f"SNI                 : {domain}",
            f"Masquerade          : {env.get('HYSTERIA2_MASQUERADE_URL', 'https://www.cloudflare.com/')}",
            f"Created At          : {display_created_at(created_at)}",
            f"Valid Until         : {display_expired_at(expired_at)}",
            f"URI                 : {uri}",
            "",
        ]
        save_text_atomic(path, "\n".join(content), mode=0o600)
        keep.add(path.name)
    for existing in ACCOUNT_ROOT.glob("*.txt"):
        if existing.name not in keep:
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
    password = (args.password or "").strip() or secrets.token_urlsafe(12)
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
    service_unit = "hysteria2.service"
    print(f"SERVICE_UNIT={service_unit}")
    print(f"SERVICE_STATE={systemctl_show_value(service_unit, 'ActiveState')}")
    print(f"SERVICE_SUBSTATE={systemctl_show_value(service_unit, 'SubState')}")
    print(f"SERVICE_ENABLED={systemctl_show_value(service_unit, 'UnitFileState')}")
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
