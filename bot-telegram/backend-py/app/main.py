import logging
import os

from fastapi import Depends, FastAPI

from .adapters import system_mutations
from .auth import verify_shared_secret
from .config import get_settings
from .routes.menus import router as menu_router
from .utils.redaction import configure_masked_logging

configure_masked_logging()
app = FastAPI(title="bot-telegram-backend", version="1.0.0")
app.include_router(menu_router)
logger = logging.getLogger("bot-telegram-backend")


@app.on_event("startup")
def startup_account_info_refresh() -> None:
    enabled = str(os.getenv("BOT_TELEGRAM_STARTUP_ACCOUNT_INFO_REFRESH", "0")).strip().lower()
    if enabled not in {"1", "true", "yes", "on", "y"}:
        logger.info("Startup account info refresh disabled.")
        return
    try:
        ok, title, msg = system_mutations.op_account_info_refresh_if_needed()
        if ok:
            logger.info("%s | %s", title, msg)
        else:
            logger.warning("%s | %s", title, msg)
    except Exception as exc:
        logger.warning("Startup account info refresh gagal: %s", exc)


@app.get("/health", dependencies=[Depends(verify_shared_secret)])
def health() -> dict:
    import shutil
    total, used, free = shutil.disk_usage("/")
    
    # Check core services
    xray_active, _ = system_mutations._run_cmd(["systemctl", "is-active", "xray"], timeout=5)
    nginx_active, _ = system_mutations._run_cmd(["systemctl", "is-active", "nginx"], timeout=5)
    
    return {
        "status": "ok" if (xray_active and nginx_active) else "degraded",
        "service": "backend-py",
        "disk": {
            "total_gb": round(total / (1024**3), 2),
            "used_gb": round(used / (1024**3), 2),
            "free_gb": round(free / (1024**3), 2),
            "percent_used": round((used / total) * 100, 2)
        },
        "services": {
            "xray": "active" if xray_active else "inactive",
            "nginx": "active" if nginx_active else "inactive"
        }
    }
