from fastapi import Depends, FastAPI

from .auth import verify_shared_secret
from .routes.actions import router as action_router

app = FastAPI(title="bot-discord-backend", version="1.0.0")
app.include_router(action_router)


@app.get("/health", dependencies=[Depends(verify_shared_secret)])
def health() -> dict:
    return {
        "status": "ok",
        "service": "backend-py",
        "mutations_enabled": True,
    }
