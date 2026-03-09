from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit

from dotenv import load_dotenv


BOT_ROOT = Path(__file__).resolve().parents[2]
LOCAL_ENV_FILE = BOT_ROOT / ".env"

if not os.getenv("BOT_ENV_FILE") and LOCAL_ENV_FILE.exists():
    load_dotenv(LOCAL_ENV_FILE, override=False)


@dataclass(frozen=True)
class AppConfig:
    token: str
    backend_base_url: str
    shared_secret: str
    commands_file: str
    admin_chat_ids: set[str]
    admin_user_ids: set[str]
    bot_username: str
    allow_unrestricted_access: bool
    enable_dangerous_actions: bool
    action_cooldown_seconds: float
    cleanup_cooldown_seconds: float
    max_manual_input_len: int


def _parse_set(raw: str | None) -> set[str]:
    if not raw:
        return set()
    out: set[str] = set()
    for part in raw.split(","):
        value = part.strip()
        if value:
            out.add(value)
    return out


def _parse_bool(name: str, default: bool) -> bool:
    raw = os.getenv(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on", "y", "enable", "enabled"}


def _parse_float(name: str, default: float, minimum: float, maximum: float) -> float:
    raw = (os.getenv(name) or "").strip()
    if not raw:
        return default
    try:
        value = float(raw)
    except Exception as exc:
        raise RuntimeError(f"{name} tidak valid: {raw}") from exc
    if value < minimum or value > maximum:
        raise RuntimeError(f"{name} di luar rentang {minimum}-{maximum}: {value}")
    return value


def _parse_int(name: str, default: int, minimum: int, maximum: int) -> int:
    raw = (os.getenv(name) or "").strip()
    if not raw:
        return default
    try:
        value = int(raw)
    except Exception as exc:
        raise RuntimeError(f"{name} tidak valid: {raw}") from exc
    if value < minimum or value > maximum:
        raise RuntimeError(f"{name} di luar rentang {minimum}-{maximum}: {value}")
    return value


def _parse_id_set(name: str, raw: str | None) -> set[str]:
    values = _parse_set(raw)
    invalid = [value for value in values if not value.lstrip("-").isdigit()]
    if invalid:
        bad = ", ".join(sorted(invalid)[:5])
        raise RuntimeError(f"{name} berisi ID tidak valid: {bad}")
    return values


def _require_env(name: str) -> str:
    value = (os.getenv(name) or "").strip()
    if not value:
        raise RuntimeError(f"{name} belum diset.")
    return value


def _default_commands_file() -> str:
    raw = (os.getenv("BOT_HOME") or "").strip()
    bot_home = Path(raw) if raw else BOT_ROOT
    return str(bot_home / "shared" / "commands.json")


def _format_host_for_url(host: str) -> str:
    if ":" in host and not host.startswith("[") and not host.endswith("]"):
        return f"[{host}]"
    return host


def _normalize_backend_base_url(raw: str) -> str:
    value = (raw or "").strip()
    if not value:
        raise RuntimeError("BACKEND_BASE_URL belum diset.")

    parsed = urlsplit(value)
    if parsed.scheme not in {"http", "https"}:
        raise RuntimeError("BACKEND_BASE_URL harus memakai skema http/https.")
    if not parsed.netloc:
        raise RuntimeError("BACKEND_BASE_URL tidak memiliki host:port yang valid.")
    if parsed.username or parsed.password:
        raise RuntimeError("BACKEND_BASE_URL tidak boleh menyertakan kredensial.")
    if parsed.query or parsed.fragment:
        raise RuntimeError("BACKEND_BASE_URL tidak boleh berisi query/fragment.")
    if parsed.path not in {"", "/"}:
        raise RuntimeError("BACKEND_BASE_URL tidak boleh berisi path tambahan.")

    return urlunsplit((parsed.scheme, parsed.netloc, "", "", "")).rstrip("/")


def _resolve_backend_base_url(default_port: int) -> str:
    raw_base_url = (os.getenv("BACKEND_BASE_URL") or "").strip()
    raw_host = (os.getenv("BACKEND_HOST") or "").strip()
    raw_port = (os.getenv("BACKEND_PORT") or "").strip()

    if raw_host or raw_port:
        host = raw_host or "127.0.0.1"
        port = _parse_int("BACKEND_PORT", default_port, 1, 65535)
        derived = _normalize_backend_base_url(f"http://{_format_host_for_url(host)}:{port}")
        if raw_base_url and _normalize_backend_base_url(raw_base_url) != derived:
            raise RuntimeError("BACKEND_BASE_URL tidak sinkron dengan BACKEND_HOST/BACKEND_PORT.")
        return derived

    return _normalize_backend_base_url(raw_base_url or f"http://127.0.0.1:{default_port}")


def load_config() -> AppConfig:
    admin_chat_ids = _parse_id_set("TELEGRAM_ADMIN_CHAT_IDS", os.getenv("TELEGRAM_ADMIN_CHAT_IDS"))
    admin_user_ids = _parse_id_set("TELEGRAM_ADMIN_USER_IDS", os.getenv("TELEGRAM_ADMIN_USER_IDS"))
    allow_unrestricted_access = _parse_bool("TELEGRAM_ALLOW_UNRESTRICTED_ACCESS", False)
    if not allow_unrestricted_access and not admin_chat_ids and not admin_user_ids:
        raise RuntimeError(
            "Akses bot ditolak by default: set TELEGRAM_ADMIN_USER_IDS/TELEGRAM_ADMIN_CHAT_IDS, "
            "atau TELEGRAM_ALLOW_UNRESTRICTED_ACCESS=true untuk override eksplisit."
        )

    return AppConfig(
        token=_require_env("TELEGRAM_BOT_TOKEN"),
        backend_base_url=_resolve_backend_base_url(8081),
        shared_secret=_require_env("INTERNAL_SHARED_SECRET"),
        commands_file=(os.getenv("COMMANDS_FILE") or _default_commands_file()).strip(),
        admin_chat_ids=admin_chat_ids,
        admin_user_ids=admin_user_ids,
        bot_username=(os.getenv("TELEGRAM_BOT_USERNAME") or "").strip().lstrip("@"),
        allow_unrestricted_access=allow_unrestricted_access,
        enable_dangerous_actions=_parse_bool("ENABLE_DANGEROUS_ACTIONS", False),
        action_cooldown_seconds=_parse_float("TELEGRAM_ACTION_COOLDOWN_SECONDS", 1.0, 0.0, 30.0),
        cleanup_cooldown_seconds=_parse_float("TELEGRAM_CLEANUP_COOLDOWN_SECONDS", 30.0, 0.0, 600.0),
        max_manual_input_len=_parse_int("TELEGRAM_MAX_INPUT_LENGTH", 128, 32, 4096),
    )
