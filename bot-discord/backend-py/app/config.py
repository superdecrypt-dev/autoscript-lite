import os
from dataclasses import dataclass
from pathlib import Path

from dotenv import load_dotenv


BOT_ROOT = Path(__file__).resolve().parents[2]
LOCAL_ENV_FILE = BOT_ROOT / ".env"

# In local development, allow reading bot-discord/.env without overriding
# variables that were already injected by systemd/environment.
if not os.getenv("BOT_ENV_FILE") and LOCAL_ENV_FILE.exists():
    load_dotenv(LOCAL_ENV_FILE, override=False)


@dataclass(frozen=True)
class Settings:
    internal_shared_secret: str


_SETTINGS: Settings | None = None


def get_settings() -> Settings:
    global _SETTINGS
    if _SETTINGS is None:
        _SETTINGS = Settings(
            internal_shared_secret=os.getenv("INTERNAL_SHARED_SECRET", "").strip(),
        )
    return _SETTINGS
