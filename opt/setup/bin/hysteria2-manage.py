#!/usr/bin/env python3
import argparse
import json
import os
import secrets
import sys
import tempfile
from datetime import datetime, timezone
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


def now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


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
        result.append(item)
    return result


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


def render_config(env: dict[str, str], data: dict) -> None:
    port = env.get("HYSTERIA2_PORT", "443")
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
    for item in data.get("users", []):
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
    port = env.get("HYSTERIA2_PORT", "443")
    visible = visible_users(data)
    keep = set()
    for item in visible:
        username = str(item.get("username", "")).strip()
        password = str(item.get("password", "")).strip()
        created_at = str(item.get("created_at", "")).strip()
        uri = (
            f"hysteria2://{quote(username, safe='')}:{quote(password, safe='')}@{domain}:{port}/"
            f"?sni={quote(domain, safe='')}"
            f"#{quote(username + '@hy2', safe='')}"
        )
        path = ACCOUNT_ROOT / f"{username}@hy2.txt"
        content = [
            "=== HYSTERIA 2 ACCOUNT INFO ===",
            f"Username            : {username}",
            f"Password            : {password}",
            f"Domain              : {domain}",
            f"Port UDP            : {port}",
            f"SNI                 : {domain}",
            f"Masquerade          : {env.get('HYSTERIA2_MASQUERADE_URL', 'https://www.cloudflare.com/')}",
            f"Created At          : {created_at or '-'}",
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
    users = data["users"]
    if any(isinstance(item, dict) and item.get("username") == username for item in users):
        raise SystemExit(f"user sudah ada: {username}")
    users.append(
        {
            "username": username,
            "password": password,
            "created_at": now_iso(),
            "hidden": False,
        }
    )
    data["users"] = users
    save_json_atomic(USERS_FILE, data, mode=0o600)
    render_config(env, data)
    render_account_files(env, data)
    print(f"USERNAME={username}")
    print(f"PASSWORD={password}")
    print(f"ACCOUNT_FILE={ACCOUNT_ROOT / (username + '@hy2.txt')}")
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
    _, data = ensure_runtime()
    users = visible_users(data)
    for item in users:
        print(f"{item.get('username','')}\t{item.get('created_at','')}")
    return 0


def status_cmd(_: argparse.Namespace) -> int:
    env, data = ensure_runtime()
    visible = visible_users(data)
    print(f"PORT={env.get('HYSTERIA2_PORT', '443')}")
    print(f"DOMAIN={domain_value()}")
    print(f"MASQUERADE_URL={env.get('HYSTERIA2_MASQUERADE_URL', 'https://www.cloudflare.com/')}")
    print(f"USER_COUNT={len(visible)}")
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
    delete = sub.add_parser("delete-user")
    delete.add_argument("--username", required=True)
    sub.add_parser("list-users")
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
    if args.command == "status":
        return status_cmd(args)
    parser.error("command tidak dikenal")
    return 1


if __name__ == "__main__":
    sys.exit(main())
