#!/usr/bin/env python3
import argparse
import fcntl
import importlib
import json
import os
import sys
from datetime import date, datetime
from pathlib import Path


STATE_ROOT = Path("/opt/quota/ssh")
LOCK_FILE = Path("/run/autoscript/locks/ssh-expired-cleaner.lock")
BACKEND_ROOT_CANDIDATES = (
    Path(os.getenv("AUTOSCRIPT_BACKEND_ROOT", "")).resolve() if os.getenv("AUTOSCRIPT_BACKEND_ROOT") else None,
    Path("/opt/bot-telegram/backend-py"),
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Delete expired SSH-linked users and linked OpenVPN artifacts")
    parser.add_argument("--once", action="store_true", help="run one cleanup cycle")
    parser.add_argument("--dry-run", action="store_true", help="only print candidates without deleting")
    return parser.parse_args()


def _load_system_mutations():
    last_error: Exception | None = None
    for base in BACKEND_ROOT_CANDIDATES:
        if not isinstance(base, Path):
            continue
        target = base / "app" / "adapters" / "system_mutations.py"
        if not target.exists():
            continue
        path_text = str(base)
        if path_text not in sys.path:
            sys.path.insert(0, path_text)
        try:
            return importlib.import_module("app.adapters.system_mutations")
        except Exception as exc:  # pragma: no cover - exercised via runtime/import errors
            last_error = exc
    if last_error is not None:
        raise RuntimeError(f"Gagal import backend mutation module: {last_error}")
    raise RuntimeError("Backend mutation module tidak ditemukan.")


def _parse_date_only(raw: str) -> date | None:
    value = str(raw or "").strip()[:10]
    if not value or value == "-":
        return None
    try:
        return datetime.strptime(value, "%Y-%m-%d").date()
    except Exception:
        return None


def _username_from_state(path: Path, payload: dict) -> str:
    raw = str(payload.get("username") or path.stem).strip()
    if "@" in raw:
        return raw.split("@", 1)[0].strip()
    stem = path.stem
    if "@" in stem:
        return stem.split("@", 1)[0].strip()
    return raw


def _iter_expired_candidates(today: date) -> list[tuple[str, str, Path]]:
    selected: dict[str, tuple[str, Path]] = {}
    if not STATE_ROOT.exists():
        return []
    for path in sorted(STATE_ROOT.glob("*.json")):
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except Exception:
            continue
        if not isinstance(payload, dict):
            continue
        username = _username_from_state(path, payload)
        expired_at = str(payload.get("expired_at") or "").strip()[:10]
        expired_date = _parse_date_only(expired_at)
        if not username or expired_date is None or expired_date >= today:
            continue
        selected[username] = (expired_at, path)
    return [(username, expired_at, source) for username, (expired_at, source) in sorted(selected.items())]


def run_once(*, dry_run: bool) -> int:
    today = date.today()
    candidates = _iter_expired_candidates(today)
    if not candidates:
        print(f"[ssh-expired-cleaner] no expired candidates (today={today.isoformat()})")
        return 0

    if dry_run:
        for username, expired_at, source in candidates:
            print(f"DRY-RUN {username} expired_at={expired_at} source={source}")
        return 0

    mutations = _load_system_mutations()
    failed = 0
    deleted = 0
    for username, expired_at, source in candidates:
        ok, title, message = mutations.op_user_delete("ssh", username)
        if ok:
            deleted += 1
            print(f"OK {username} expired_at={expired_at} source={source} :: {title} :: {message}")
            continue
        failed += 1
        print(f"FAIL {username} expired_at={expired_at} source={source} :: {title} :: {message}", file=sys.stderr)

    print(
        f"[ssh-expired-cleaner] completed today={today.isoformat()} candidates={len(candidates)} deleted={deleted} failed={failed}"
    )
    return 0 if failed == 0 else 1


def main() -> int:
    _ = parse_args()
    try:
        LOCK_FILE.parent.mkdir(parents=True, exist_ok=True)
        os.chmod(LOCK_FILE.parent, 0o700)
    except Exception:
        pass
    with open(LOCK_FILE, "a+", encoding="utf-8") as lock_fp:
        fcntl.flock(lock_fp.fileno(), fcntl.LOCK_EX)
        try:
            args = parse_args()
            return run_once(dry_run=bool(args.dry_run))
        finally:
            fcntl.flock(lock_fp.fileno(), fcntl.LOCK_UN)


if __name__ == "__main__":
    raise SystemExit(main())
