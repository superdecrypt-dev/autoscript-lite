#!/usr/bin/env python3
import argparse
import json
import os
import pwd
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path


SSH_USERNAME_RE = re.compile(r"^[a-z_][a-z0-9_-]{1,31}$")
PORTAL_TOKEN_RE = re.compile(r"^[A-Za-z0-9_-]{10,64}$")
DEFAULT_CONFIG_ENV = Path("/etc/autoscript/openvpn/config.env")
DEFAULT_DOMAIN_FILE = Path("/etc/xray/domain")
DEFAULT_DOWNLOAD_TOKEN_DIR = Path("/run/autoscript/openvpn-download-tokens")
DEFAULT_EDGE_RUNTIME_ENV = Path("/etc/default/edge-runtime")
DEFAULT_POLICY_STATE_DIR = Path("/opt/quota/openvpn")
DEFAULT_SSH_STATE_DIR = Path("/opt/quota/ssh")
DEFAULT_OPENVPN_CONNECT_POLICY_DIR = Path("/run/openvpn-connect-policy")


def die(msg: str, code: int = 1) -> None:
    print(msg, file=sys.stderr)
    raise SystemExit(code)


def read_env_map(path: Path) -> dict[str, str]:
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


def run_cmd(argv: list[str], *, cwd: Path | None = None, input_text: str | None = None, timeout: int = 120) -> tuple[bool, str]:
    try:
        proc = subprocess.run(
            argv,
            cwd=str(cwd) if cwd else None,
            input=input_text,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=timeout,
            check=False,
        )
    except Exception as exc:
        return False, str(exc)
    return proc.returncode == 0, proc.stdout.strip()


def json_out(payload: dict[str, object]) -> None:
    print(json.dumps(payload, ensure_ascii=True))


def load_config(path: Path) -> dict[str, str]:
    cfg = read_env_map(path)
    return {
        "root": cfg.get("OPENVPN_ROOT", "/etc/autoscript/openvpn"),
        "config_env": str(path),
        "domain_file": cfg.get("OPENVPN_DOMAIN_FILE", str(DEFAULT_DOMAIN_FILE)),
        "easyrsa_dir": cfg.get("OPENVPN_EASYRSA_DIR", "/etc/openvpn/easy-rsa"),
        "pki_dir": cfg.get("OPENVPN_PKI_DIR", "/etc/openvpn/easy-rsa/pki"),
        "server_dir": cfg.get("OPENVPN_SERVER_DIR", "/etc/openvpn/server"),
        "profile_dir": cfg.get("OPENVPN_PROFILE_DIR", "/opt/account/openvpn"),
        "metadata_dir": cfg.get("OPENVPN_METADATA_DIR", "/var/lib/openvpn-manage/users"),
        "server_name": cfg.get("OPENVPN_SERVER_NAME", "autoscript-server"),
        "port_tcp": cfg.get("OPENVPN_PORT_TCP", "1194"),
        "public_port_tcp": cfg.get("OPENVPN_PUBLIC_PORT_TCP", cfg.get("OPENVPN_PORT_TCP", "1194")),
        "public_host": cfg.get("OPENVPN_PUBLIC_HOST", ""),
        "state_dir": cfg.get("OPENVPN_STATE_DIR", str(DEFAULT_POLICY_STATE_DIR)),
        "ssh_state_dir": cfg.get("OPENVPN_SSH_STATE_DIR", str(DEFAULT_SSH_STATE_DIR)),
        "download_token_dir": cfg.get("OPENVPN_DOWNLOAD_TOKEN_DIR", str(DEFAULT_DOWNLOAD_TOKEN_DIR)),
        "edge_runtime_env": cfg.get("OPENVPN_EDGE_RUNTIME_ENV", str(DEFAULT_EDGE_RUNTIME_ENV)),
    }


def _parse_port_tokens(raw: str) -> list[int]:
    values: list[int] = []
    seen: set[int] = set()
    for token in re.split(r"[\s,]+", str(raw or "").strip()):
        if not token or not token.isdigit():
            continue
        port = int(token)
        if port < 1 or port > 65535 or port in seen:
            continue
        seen.add(port)
        values.append(port)
    return values


def openvpn_public_tcp_ports(cfg: dict[str, str]) -> list[int]:
    env_map = read_env_map(Path(cfg.get("edge_runtime_env") or str(DEFAULT_EDGE_RUNTIME_ENV)))
    tls_ports = _parse_port_tokens(env_map.get("EDGE_PUBLIC_TLS_PORTS") or env_map.get("EDGE_PUBLIC_TLS_PORT") or "443,2053,2083,2087,2096,8443")
    http_ports = _parse_port_tokens(env_map.get("EDGE_PUBLIC_HTTP_PORTS") or env_map.get("EDGE_PUBLIC_HTTP_PORT") or "80,8080,8880,2052,2082,2086,2095")
    fallback = _parse_port_tokens(str(cfg.get("public_port_tcp") or cfg.get("port_tcp") or "1194"))
    ports: list[int] = []
    seen: set[int] = set()
    for bucket in (tls_ports, http_ports, fallback):
        for port in bucket:
            if port in seen:
                continue
            seen.add(port)
            ports.append(port)
    return ports or [int(str(cfg.get("public_port_tcp") or cfg.get("port_tcp") or "1194"))]


def ensure_dir(path: Path, mode: int = 0o755) -> None:
    path.mkdir(parents=True, exist_ok=True)
    try:
        path.chmod(mode)
    except Exception:
        pass


def validate_username(username: str) -> str:
    value = str(username or "").strip()
    if not SSH_USERNAME_RE.fullmatch(value):
        die("Username OpenVPN tidak valid.")
    return value


def generate_portal_token() -> str:
    import secrets

    for _ in range(128):
        token = secrets.token_urlsafe(12).rstrip("=")
        if token and PORTAL_TOKEN_RE.fullmatch(token):
            return token
    raise RuntimeError("gagal membuat portal token")


def linux_user_exists(username: str) -> bool:
    try:
        pwd.getpwnam(str(username or "").strip())
        return True
    except KeyError:
        return False
    except Exception:
        return False


def detect_public_host(cfg: dict[str, str]) -> str:
    domain_file = Path(cfg["domain_file"])
    if domain_file.exists():
        try:
            value = domain_file.read_text(encoding="utf-8", errors="ignore").strip()
            if value:
                return value
        except Exception:
            pass
    explicit = str(cfg.get("public_host") or "").strip()
    if explicit:
        return explicit
    try:
        with socket.create_connection(("1.1.1.1", 53), timeout=2.0) as sock:
            local_ip = sock.getsockname()[0]
            if local_ip:
                return local_ip
    except Exception:
        pass
    return "-"


def easyrsa_bin(cfg: dict[str, str]) -> Path:
    return Path(cfg["easyrsa_dir"]) / "easyrsa"


def pki_paths(cfg: dict[str, str], username: str) -> dict[str, Path]:
    pki = Path(cfg["pki_dir"])
    return {
        "issued": pki / "issued" / f"{username}.crt",
        "private": pki / "private" / f"{username}.key",
        "req": pki / "reqs" / f"{username}.req",
        "inline": pki / "inline" / f"{username}.inline",
        "ca": pki / "ca.crt",
        "crl": pki / "crl.pem",
        "index": pki / "index.txt",
    }


def ensure_easyrsa_vars(cfg: dict[str, str]) -> None:
    easyrsa_dir = Path(cfg["easyrsa_dir"])
    vars_file = easyrsa_dir / "vars"
    example = easyrsa_dir / "vars.example"
    if vars_file.exists() or not example.exists():
        return
    shutil.copyfile(example, vars_file)


def scrub_stale_client_state(cfg: dict[str, str], username: str) -> None:
    paths = pki_paths(cfg, username)
    for key in ("issued", "private", "req", "inline"):
        try:
            paths[key].unlink(missing_ok=True)
        except Exception:
            pass


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="ignore")


def cert_body(text: str) -> str:
    match = re.search(
        r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----",
        text,
        flags=re.S,
    )
    return match.group(0).strip() if match else text.strip()


def key_body(text: str) -> str:
    match = re.search(
        r"-----BEGIN .*?PRIVATE KEY-----.*?-----END .*?PRIVATE KEY-----",
        text,
        flags=re.S,
    )
    return match.group(0).strip() if match else text.strip()


def profile_path(cfg: dict[str, str], username: str) -> Path:
    return Path(cfg["profile_dir"]) / f"{username}@openvpn.ovpn"


def metadata_path(cfg: dict[str, str], username: str) -> Path:
    return Path(cfg["metadata_dir"]) / f"{username}@openvpn.json"


def state_path(cfg: dict[str, str], username: str) -> Path:
    return Path(cfg["state_dir"]) / f"{username}@openvpn.json"


def ssh_state_candidates(cfg: dict[str, str], username: str) -> list[Path]:
    root = Path(cfg["ssh_state_dir"])
    return [
        root / f"{username}@ssh.json",
        root / f"{username}.json",
    ]


def download_token_dir(cfg: dict[str, str]) -> Path:
    return Path(cfg["download_token_dir"])


def download_token_file(cfg: dict[str, str], token: str) -> Path:
    return download_token_dir(cfg) / f"{token}.json"


def prune_download_tokens(cfg: dict[str, str], now_ts: int | None = None) -> None:
    current = int(now_ts or time.time())
    root = download_token_dir(cfg)
    ensure_dir(root, 0o700)
    for path in root.glob("*.json"):
        try:
            payload = json.loads(path.read_text(encoding="utf-8", errors="ignore"))
        except Exception:
            path.unlink(missing_ok=True)
            continue
        exp = int(payload.get("exp") or 0)
        if exp <= current:
            path.unlink(missing_ok=True)


def issue_download_token(cfg: dict[str, str], username: str, ttl_seconds: int = 3600) -> str:
    prune_download_tokens(cfg)
    root = download_token_dir(cfg)
    ensure_dir(root, 0o700)
    expires_at = int(time.time()) + max(60, int(ttl_seconds))
    for path in root.glob("*.json"):
        try:
            payload = json.loads(path.read_text(encoding="utf-8", errors="ignore"))
        except Exception:
            path.unlink(missing_ok=True)
            continue
        if str(payload.get("username") or "").strip() != username:
            continue
        exp = int(payload.get("exp") or 0)
        if exp > int(time.time()):
            return path.stem
    for _ in range(8):
        token = os.urandom(6).hex()
        path = download_token_file(cfg, token)
        if path.exists():
            continue
        payload = {"username": username, "exp": expires_at}
        write_atomic(path, json.dumps(payload, ensure_ascii=True) + "\n", 0o600)
        return token
    return ""


def delete_download_tokens_for_user(cfg: dict[str, str], username: str) -> None:
    root = download_token_dir(cfg)
    if not root.exists():
        return
    for path in root.glob("*.json"):
        try:
            payload = json.loads(path.read_text(encoding="utf-8", errors="ignore"))
        except Exception:
            path.unlink(missing_ok=True)
            continue
        if str(payload.get("username") or "").strip() != username:
            continue
        path.unlink(missing_ok=True)


def download_link(cfg: dict[str, str], username: str) -> str:
    if not linux_user_exists(username):
        return ""
    host = detect_public_host(cfg)
    if not host or host == "-":
        return ""
    token = issue_download_token(cfg, username)
    if not token:
        return ""
    return f"https://{host}/ovpn/{token}"


def profile_text(cfg: dict[str, str], username: str) -> str:
    host = detect_public_host(cfg)
    paths = pki_paths(cfg, username)
    ca = cert_body(read_text(paths["ca"]))
    public_ports = openvpn_public_tcp_ports(cfg)
    lines = [
        "setenv CLIENT_CERT 0",
        "client",
        "dev tun",
        "proto tcp",
        "resolv-retry infinite",
        "nobind",
        "persist-key",
        "persist-tun",
        "auth-user-pass",
        "auth-nocache",
        "remote-cert-tls server",
        f"verify-x509-name {cfg['server_name']} name",
        "tls-version-min 1.2",
        "auth SHA256",
        "data-ciphers AES-256-GCM:AES-128-GCM",
        "verb 3",
        "",
    ]
    for port in public_ports:
        lines.append(f"remote {host} {port}")
    lines.extend([
        "<ca>",
        ca,
        "</ca>",
    ])
    return "\n".join(lines)


def write_atomic(path: Path, content: str, mode: int = 0o600) -> None:
    ensure_dir(path.parent, 0o755)
    fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(content)
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def sync_runtime_crl(cfg: dict[str, str]) -> tuple[bool, str]:
    src = Path(cfg["pki_dir"]) / "crl.pem"
    dst = Path(cfg["server_dir"]) / "crl.pem"
    if not src.exists():
        return False, f"source crl tidak ditemukan: {src}"
    try:
        ensure_dir(dst.parent, 0o755)
        shutil.copyfile(src, dst)
        os.chmod(dst, 0o644)
    except Exception as exc:
        return False, str(exc)
    return True, str(dst)


def save_metadata(cfg: dict[str, str], username: str, profile: Path) -> None:
    ports = openvpn_public_tcp_ports(cfg)
    payload = {
        "username": username,
        "profile_path": str(profile),
        "host": detect_public_host(cfg),
        "tcp_port": int(ports[0]),
        "tcp_ports": ports,
        "backend_tcp_port": int(cfg["port_tcp"]),
        "updated_at": int(time.time()),
    }
    write_atomic(metadata_path(cfg, username), json.dumps(payload, ensure_ascii=True, indent=2) + "\n", 0o600)


def read_json_file(path: Path) -> dict[str, object]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8", errors="ignore"))
    except Exception:
        return {}
    return payload if isinstance(payload, dict) else {}


def ssh_policy_source(cfg: dict[str, str], username: str) -> dict[str, object]:
    for candidate in ssh_state_candidates(cfg, username):
        if not candidate.exists():
            continue
        payload = read_json_file(candidate)
        if payload:
            return payload
    return {}


def policy_state_int(value: object, default: int = 0) -> int:
    try:
        return max(0, int(float(value or 0)))
    except Exception:
        return default


def policy_state_float(value: object, default: float = 0.0) -> float:
    try:
        return max(0.0, float(value or 0.0))
    except Exception:
        return default


def ensure_policy_state(cfg: dict[str, str], username: str) -> Path:
    target = state_path(cfg, username)
    payload = read_json_file(target) if target.exists() else {}
    creating = not target.exists() or not payload
    source = ssh_policy_source(cfg, username)
    status_raw = source.get("status") if isinstance(source.get("status"), dict) else {}
    existing_status = payload.get("status") if isinstance(payload.get("status"), dict) else {}

    if creating:
        try:
            quota_limit = max(0, int(float(source.get("quota_limit") or 0)))
        except Exception:
            quota_limit = 0
        try:
            ip_limit = max(0, int(float(status_raw.get("ip_limit") or 0)))
        except Exception:
            ip_limit = 0
        try:
            speed_down = max(0.0, float(status_raw.get("speed_down_mbit") or 0.0))
        except Exception:
            speed_down = 0.0
        try:
            speed_up = max(0.0, float(status_raw.get("speed_up_mbit") or 0.0))
        except Exception:
            speed_up = 0.0
        payload = {
            "managed_by": "autoscript-manage",
            "username": username,
            "protocol": "openvpn",
            "created_at": str(source.get("created_at") or time.strftime("%Y-%m-%d %H:%M")).strip() or time.strftime("%Y-%m-%d %H:%M"),
            "expired_at": str(source.get("expired_at") or "-").strip()[:10] or "-",
            "quota_limit": quota_limit,
            "quota_unit": str(source.get("quota_unit") or "binary").strip().lower() or "binary",
            "quota_used": 0,
            "portal_token": generate_portal_token(),
            "status": {
                "manual_block": bool(status_raw.get("manual_block")),
                "quota_exhausted": False,
                "ip_limit_enabled": bool(status_raw.get("ip_limit_enabled")),
                "ip_limit": ip_limit,
                "ip_limit_locked": False,
                "ip_limit_metric": 0,
                "distinct_ip_count": 0,
                "distinct_ips": [],
                "active_sessions_total": 0,
                "active_sessions_openvpn": 0,
                "distinct_ip_count_openvpn": 0,
                "distinct_ips_openvpn": [],
                "speed_limit_enabled": bool(status_raw.get("speed_limit_enabled")),
                "speed_down_mbit": speed_down,
                "speed_up_mbit": speed_up,
                "lock_reason": "",
                "account_locked": False,
                "lock_owner": "",
                "lock_shell_restore": "",
            },
        }
    else:
        payload["managed_by"] = "autoscript-manage"
        payload["username"] = username
        payload["protocol"] = "openvpn"
        payload["created_at"] = str(payload.get("created_at") or "-").strip() or "-"
        payload["expired_at"] = str(payload.get("expired_at") or "-").strip()[:10] or "-"
        payload["quota_limit"] = policy_state_int(payload.get("quota_limit"), 0)
        payload["quota_unit"] = str(payload.get("quota_unit") or "binary").strip().lower() or "binary"
        if payload["quota_unit"] not in {"binary", "decimal"}:
            payload["quota_unit"] = "binary"
        payload["quota_used"] = policy_state_int(payload.get("quota_used"), 0)
        token = str(payload.get("portal_token") or "").strip()
        payload["portal_token"] = token if PORTAL_TOKEN_RE.fullmatch(token) else generate_portal_token()
        payload["status"] = {
            "manual_block": bool(existing_status.get("manual_block")),
            "quota_exhausted": bool(existing_status.get("quota_exhausted")),
            "ip_limit_enabled": bool(existing_status.get("ip_limit_enabled")),
            "ip_limit": policy_state_int(existing_status.get("ip_limit"), 0),
            "ip_limit_locked": bool(existing_status.get("ip_limit_locked")),
            "ip_limit_metric": policy_state_int(existing_status.get("ip_limit_metric"), 0),
            "distinct_ip_count": policy_state_int(existing_status.get("distinct_ip_count"), 0),
            "distinct_ips": existing_status.get("distinct_ips") if isinstance(existing_status.get("distinct_ips"), list) else [],
            "active_sessions_total": policy_state_int(existing_status.get("active_sessions_total"), 0),
            "active_sessions_openvpn": policy_state_int(existing_status.get("active_sessions_openvpn"), 0),
            "distinct_ip_count_openvpn": policy_state_int(existing_status.get("distinct_ip_count_openvpn"), 0),
            "distinct_ips_openvpn": existing_status.get("distinct_ips_openvpn") if isinstance(existing_status.get("distinct_ips_openvpn"), list) else [],
            "speed_limit_enabled": bool(existing_status.get("speed_limit_enabled")),
            "speed_down_mbit": policy_state_float(existing_status.get("speed_down_mbit"), 0.0),
            "speed_up_mbit": policy_state_float(existing_status.get("speed_up_mbit"), 0.0),
            "lock_reason": str(existing_status.get("lock_reason") or "").strip().lower(),
            "account_locked": bool(existing_status.get("account_locked")),
            "lock_owner": str(existing_status.get("lock_owner") or "").strip(),
            "lock_shell_restore": str(existing_status.get("lock_shell_restore") or "").strip(),
        }

    if source:
        payload["created_at"] = str(source.get("created_at") or payload.get("created_at") or "-").strip() or "-"
        payload["expired_at"] = str(source.get("expired_at") or payload.get("expired_at") or "-").strip()[:10] or "-"

    current_payload = read_json_file(target) if target.exists() else {}
    if payload != current_payload:
        write_atomic(target, json.dumps(payload, ensure_ascii=True, indent=2) + "\n", 0o600)
    return target


def drop_runtime_policy_artifacts(username: str) -> None:
    for path in (
        DEFAULT_OPENVPN_CONNECT_POLICY_DIR / f"{username}.json",
        DEFAULT_OPENVPN_CONNECT_POLICY_DIR / f"{username}@openvpn.json",
    ):
        try:
            path.unlink(missing_ok=True)
        except Exception:
            pass


def ensure_user(cfg: dict[str, str], username: str) -> dict[str, object]:
    username = validate_username(username)
    if not linux_user_exists(username):
        die(f"User SSH tidak ditemukan: {username}")
    ensure_dir(Path(cfg["profile_dir"]), 0o755)
    ensure_dir(Path(cfg["metadata_dir"]), 0o700)
    ensure_easyrsa_vars(cfg)
    paths = pki_paths(cfg, username)
    if not paths["ca"].exists():
        die(f"CA OpenVPN tidak ditemukan: {paths['ca']}")
    content = profile_text(cfg, username)
    target = profile_path(cfg, username)
    write_atomic(target, content, 0o600)
    save_metadata(cfg, username, target)
    policy_state = ensure_policy_state(cfg, username)
    policy_payload = read_json_file(policy_state)
    portal_token = str(policy_payload.get("portal_token") or "").strip() if isinstance(policy_payload, dict) else ""
    ports = openvpn_public_tcp_ports(cfg)
    return {
        "ok": True,
        "username": username,
        "profile_path": str(target),
        "policy_state_path": str(policy_state),
        "portal_url": f"https://{detect_public_host(cfg)}/account/{portal_token}" if portal_token else "-",
        "host": detect_public_host(cfg),
        "tcp_port": int(ports[0]),
        "tcp_ports": ports,
        "backend_tcp_port": int(cfg["port_tcp"]),
    }


def delete_user(cfg: dict[str, str], username: str) -> dict[str, object]:
    username = validate_username(username)
    easyrsa = easyrsa_bin(cfg)
    paths = pki_paths(cfg, username)
    notes: list[str] = []
    if paths["issued"].exists() and easyrsa.exists():
        ok, out = run_cmd(
            ["bash", "-lc", f'cd "{cfg["easyrsa_dir"]}" && printf "yes\\n" | "{easyrsa}" revoke "{username}"'],
            timeout=300,
        )
        if not ok and "Already revoked" not in out and "Unable to revoke" not in out and "does not exist" not in out:
            notes.append(f"revoke: {out}")
        else:
            ok_crl, out_crl = run_cmd([str(easyrsa), "gen-crl"], cwd=Path(cfg["easyrsa_dir"]), timeout=300)
            if not ok_crl:
                notes.append(f"gen-crl: {out_crl}")
            else:
                ok_sync, sync_out = sync_runtime_crl(cfg)
                if not ok_sync:
                    notes.append(f"sync-crl: {sync_out}")
    scrub_stale_client_state(cfg, username)
    delete_download_tokens_for_user(cfg, username)
    drop_runtime_policy_artifacts(username)
    for path in (profile_path(cfg, username), metadata_path(cfg, username), state_path(cfg, username)):
        try:
            if path.exists() or path.is_symlink():
                path.unlink()
        except Exception as exc:
            notes.append(f"cleanup {path.name}: {exc}")
    return {"ok": len(notes) == 0, "username": username, "notes": notes}


def linked_info(cfg: dict[str, str], username: str) -> dict[str, object]:
    username = validate_username(username)
    target = profile_path(cfg, username)
    meta = metadata_path(cfg, username)
    ports = openvpn_public_tcp_ports(cfg)
    user_exists = linux_user_exists(username)
    if user_exists:
        ensure_policy_state(cfg, username)
    policy_payload = read_json_file(state_path(cfg, username))
    portal_token = str(policy_payload.get("portal_token") or "").strip() if isinstance(policy_payload, dict) else ""
    payload: dict[str, object] = {
        "ok": True,
        "enabled": user_exists,
        "username": username,
        "password_hint": "same as SSH password",
        "policy_scope": "independent OpenVPN quota / IP limit / speed",
        "session_policy": "single active session per username (new login drops previous session)",
        "profile_path": str(target),
        "profile_exists": target.exists() if user_exists else False,
        "policy_state_path": str(state_path(cfg, username)),
        "portal_url": f"https://{detect_public_host(cfg)}/account/{portal_token}" if portal_token else "-",
        "host": detect_public_host(cfg),
        "tcp_port": int(ports[0]),
        "tcp_ports": ports,
        "backend_tcp_port": int(cfg["port_tcp"]),
        "metadata_path": str(meta),
        "download_link": download_link(cfg, username) if user_exists else "",
    }
    if meta.exists():
        try:
            meta_payload = json.loads(meta.read_text(encoding="utf-8", errors="ignore"))
            if isinstance(meta_payload, dict):
                payload["updated_at"] = meta_payload.get("updated_at")
                if isinstance(meta_payload.get("tcp_ports"), list):
                    payload["tcp_ports"] = meta_payload.get("tcp_ports")
        except Exception:
            pass
    return payload


def profile_download(cfg: dict[str, str], username: str) -> dict[str, object]:
    username = validate_username(username)
    if not linux_user_exists(username):
        die(f"User SSH tidak ditemukan: {username}")
    ensure_policy_state(cfg, username)
    target = profile_path(cfg, username)
    if not target.exists():
        ensure_user(cfg, username)
    return {
        "ok": True,
        "username": username,
        "profile_path": str(target),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Manage OpenVPN linked artifacts for autoscript")
    parser.add_argument("--config", default=str(DEFAULT_CONFIG_ENV))
    sub = parser.add_subparsers(dest="command", required=True)

    for name in ("ensure-user", "delete-user", "linked-info", "profile-download"):
        cmd = sub.add_parser(name)
        cmd.add_argument("--username", required=True)

    args = parser.parse_args()
    cfg = load_config(Path(args.config))
    if args.command == "ensure-user":
        json_out(ensure_user(cfg, args.username))
        return 0
    if args.command == "delete-user":
        json_out(delete_user(cfg, args.username))
        return 0
    if args.command == "linked-info":
        json_out(linked_info(cfg, args.username))
        return 0
    if args.command == "profile-download":
        json_out(profile_download(cfg, args.username))
        return 0
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
