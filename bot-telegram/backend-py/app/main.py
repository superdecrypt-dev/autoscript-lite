import logging
import os

from fastapi import Depends, FastAPI

from .adapters import system_mutations
from .auth import verify_shared_secret
from .config import get_settings
from .routes.menus import router as menu_router

app = FastAPI(title="bot-telegram-backend", version="1.0.0")
app.include_router(menu_router)
logger = logging.getLogger("bot-telegram-backend")


@app.on_event("startup")
def startup_account_info_compat_refresh() -> None:
    enabled = str(os.getenv("BOT_TELEGRAM_STARTUP_COMPAT_REFRESH", "0")).strip().lower()
    if enabled not in {"1", "true", "yes", "on", "y"}:
        logger.info("Startup compat refresh disabled.")
        return
    try:
        ok, title, msg = system_mutations.op_account_info_compat_refresh_if_needed()
        if ok:
            logger.info("%s | %s", title, msg)
        else:
            logger.warning("%s | %s", title, msg)
    except Exception as exc:
        logger.warning("Startup compat refresh gagal: %s", exc)


@app.get("/health", dependencies=[Depends(verify_shared_secret)])
def health() -> dict:
    return {
        "status": "ok",
        "service": "backend-py",
    }
