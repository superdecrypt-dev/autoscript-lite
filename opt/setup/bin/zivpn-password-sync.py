#!/usr/bin/env python3
import argparse
import json
import os
import subprocess
import tempfile
from pathlib import Path
from typing import List, Set, Tuple

MASKED_PASSWORDS = {"", "-", "(hidden)", "********"}


def atomic_write_text(path: Path, text: str, mode: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.chmod(tmp_name, mode)
        os.replace(tmp_name, path)
    finally:
        try:
            os.unlink(tmp_name)
        except FileNotFoundError:
            pass


def normalize_password(value: str) -> str:
    password = str(value or "").strip()
    if password in MASKED_PASSWORDS:
        return ""
    return password


def parse_account_info(path: Path) -> Tuple[str, str]:
    username = ""
    password = ""
    try:
        for raw_line in path.read_text(encoding="utf-8").splitlines():
            line = raw_line.strip()
            if line.startswith("Username"):
                username = line.split(":", 1)[1].strip()
            elif line.startswith("Password"):
                password = line.split(":", 1)[1].strip()
    except Exception:
        return "", ""
    return username, password


def seed_from_account_info(account_dir: Path, passwords_dir: Path) -> int:
    seeded = 0
    if not account_dir.is_dir():
        return seeded
    for acc_file in sorted(account_dir.glob("*.txt")):
        username, password = parse_account_info(acc_file)
        username = username.strip()
        password = normalize_password(password)
        if not username or not password:
            continue
        dst = passwords_dir / f"{username}.pass"
        if dst.exists():
            continue
        atomic_write_text(dst, password + "\n", 0o600)
        seeded += 1
    return seeded


def load_passwords(passwords_dir: Path) -> List[str]:
    unique: List[str] = []
    seen: Set[str] = set()
    if not passwords_dir.is_dir():
        return unique
    for path in sorted(passwords_dir.glob("*.pass")):
        try:
            password = normalize_password(path.read_text(encoding="utf-8").strip())
        except Exception:
            continue
        if not password or password in seen:
            continue
        unique.append(password)
        seen.add(password)
    return unique


def render_config(listen: str, cert: str, key: str, obfs: str, passwords: List[str]) -> str:
    payload = {
        "listen": listen,
        "cert": cert,
        "key": key,
        "obfs": obfs,
        "auth": {
            "mode": "passwords",
            "config": passwords,
        },
    }
    return json.dumps(payload, indent=2, ensure_ascii=True) + "\n"


def run_systemctl(*args: str) -> int:
    proc = subprocess.run(
        ["systemctl", *args],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    return proc.returncode


def systemctl_exists() -> bool:
    for root in os.environ.get("PATH", "").split(os.pathsep):
        candidate = Path(root) / "systemctl"
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return True
    return False


def sync_service_state(service: str, password_count: int) -> int:
    if not service or not systemctl_exists():
        return 0
    if password_count > 0:
        run_systemctl("enable", service)
        if run_systemctl("enable", "--now", service) != 0:
            return 1
        if run_systemctl("restart", service) != 0:
            return 1
        return run_systemctl("is-active", "--quiet", service)
    run_systemctl("disable", "--now", service)
    run_systemctl("reset-failed", service)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(prog="zivpn-password-sync")
    parser.add_argument("--config", required=True)
    parser.add_argument("--passwords-dir", required=True)
    parser.add_argument("--listen", required=True)
    parser.add_argument("--cert", required=True)
    parser.add_argument("--key", required=True)
    parser.add_argument("--obfs", default="zivpn")
    parser.add_argument("--account-dir", default="")
    parser.add_argument("--seed-from-account-info", action="store_true")
    parser.add_argument("--service", default="")
    parser.add_argument("--sync-service-state", action="store_true")
    args = parser.parse_args()

    config_path = Path(args.config)
    passwords_dir = Path(args.passwords_dir)
    passwords_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(passwords_dir, 0o700)

    if args.seed_from_account_info and args.account_dir:
        seed_from_account_info(Path(args.account_dir), passwords_dir)

    passwords = load_passwords(passwords_dir)
    atomic_write_text(
        config_path,
        render_config(args.listen, args.cert, args.key, args.obfs, passwords),
        0o600,
    )

    if args.sync_service_state:
        return sync_service_state(args.service, len(passwords))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
