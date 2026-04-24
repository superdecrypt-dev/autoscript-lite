import os
import ipaddress
from dataclasses import dataclass
from pathlib import Path

from dotenv import load_dotenv


BOT_ROOT = Path(__file__).resolve().parents[2]
LOCAL_ENV_FILE = BOT_ROOT / ".env"

# In local development, allow reading bot-telegram/.env without overriding
# variables that were already injected by systemd/environment.
if not os.getenv("BOT_ENV_FILE") and LOCAL_ENV_FILE.exists():
    load_dotenv(LOCAL_ENV_FILE, override=False)


def _get_bool(name: str, default: bool) -> bool:
    raw = os.getenv(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


def _get_port(name: str, default: int) -> int:
    raw = (os.getenv(name) or str(default)).strip()
    try:
        value = int(raw)
    except Exception as exc:
        raise RuntimeError(f"{name} tidak valid: {raw}") from exc
    if value < 1 or value > 65535:
        raise RuntimeError(f"{name} di luar rentang 1-65535: {value}")
    return value


def _get_loopback_host(name: str, default: str) -> str:
    raw = (os.getenv(name) or default).strip()
    host = raw.strip("[]")
    if host.lower() == "localhost":
        return raw
    try:
        ip = ipaddress.ip_address(host)
    except ValueError as exc:
        raise RuntimeError(f"{name} harus loopback (127.0.0.1/::1/localhost): {raw}") from exc
    if not ip.is_loopback:
        raise RuntimeError(f"{name} harus loopback (127.0.0.1/::1/localhost): {raw}")
    return raw


@dataclass(frozen=True)
class Settings:
    internal_shared_secret: str
    backend_host: str
    backend_port: int
    commands_file: str


_SETTINGS: Settings | None = None


def _bot_home() -> Path:
    raw = (os.getenv("BOT_HOME") or "").strip()
    if raw:
        return Path(raw)
    return BOT_ROOT


def _default_commands_file() -> str:
    return str(_bot_home() / "shared" / "commands.json")


def get_settings() -> Settings:
    global _SETTINGS
    if _SETTINGS is None:
        _SETTINGS = Settings(
            internal_shared_secret=os.getenv("INTERNAL_SHARED_SECRET", "").strip(),
            backend_host=_get_loopback_host("BACKEND_HOST", "127.0.0.1"),
            backend_port=_get_port("BACKEND_PORT", 7081),
            commands_file=os.getenv("COMMANDS_FILE", _default_commands_file()).strip(),
        )
    return _SETTINGS
