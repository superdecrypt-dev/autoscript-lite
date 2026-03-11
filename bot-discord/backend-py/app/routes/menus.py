import json
from pathlib import Path

from fastapi import APIRouter, Depends

from ..adapters import system, system_mutations
from ..auth import verify_shared_secret
from ..config import get_settings
from ..schemas import ActionRequest, ActionResponse
from ..services import MENU_HANDLERS
from ..utils.response import error_response

router = APIRouter(tags=["menus"])


def _load_commands_file(path: str) -> dict:
    p = Path(path)
    if not p.exists():
        return {"menus": []}
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception:
        return {"menus": []}


def _is_dangerous_action(menu_id: str, raw_action: dict) -> bool:
    del menu_id
    return bool(raw_action.get("dangerous", False))


def _filter_commands_payload(payload: dict, enable_dangerous_actions: bool) -> dict:
    if not isinstance(payload, dict):
        return {"menus": []}

    filtered_menus = []
    for raw_menu in payload.get("menus", []):
        if not isinstance(raw_menu, dict):
            continue

        menu_id = str(raw_menu.get("id") or "").strip()
        if not menu_id:
            continue

        filtered_actions = []
        for raw_action in raw_menu.get("actions", []):
            if not isinstance(raw_action, dict):
                continue
            if _is_dangerous_action(menu_id, raw_action) and not enable_dangerous_actions:
                continue
            filtered_actions.append(raw_action)

        if not filtered_actions:
            continue

        menu_copy = dict(raw_menu)
        menu_copy["actions"] = filtered_actions
        filtered_menus.append(menu_copy)

    payload_copy = dict(payload)
    payload_copy["menus"] = filtered_menus
    return payload_copy


@router.get("/api/menus", dependencies=[Depends(verify_shared_secret)])
def get_menus() -> dict:
    settings = get_settings()
    return _filter_commands_payload(
        _load_commands_file(settings.commands_file),
        settings.enable_dangerous_actions,
    )


@router.get("/api/main-menu", dependencies=[Depends(verify_shared_secret)])
def get_main_menu_overview() -> dict:
    settings = get_settings()
    data = _filter_commands_payload(
        _load_commands_file(settings.commands_file),
        settings.enable_dangerous_actions,
    )
    return {
        "mode": "standalone",
        "dangerous_actions_enabled": settings.enable_dangerous_actions,
        "menu_count": len(data.get("menus", [])),
        "menus": data.get("menus", []),
    }


@router.get("/api/users/options", dependencies=[Depends(verify_shared_secret)])
def get_user_options(proto: str | None = None) -> dict:
    proto_norm = (proto or "").strip().lower()
    if proto_norm and proto_norm not in {"vless", "vmess", "trojan"}:
        return {"users": []}

    records = system.list_accounts()
    if proto_norm:
        records = [(p, u) for p, u in records if p == proto_norm]

    return {
        "users": [{"proto": p, "username": u} for p, u in records],
    }


@router.get("/api/domain/root-options", dependencies=[Depends(verify_shared_secret)])
def get_domain_root_options() -> dict:
    roots = system_mutations.list_provided_root_domains()
    return {
        "roots": [{"root_domain": item} for item in roots],
    }


@router.post(
    "/api/menu/{menu_id}/action",
    dependencies=[Depends(verify_shared_secret)],
    response_model=ActionResponse,
)
def run_menu_action(menu_id: str, payload: ActionRequest) -> dict:
    settings = get_settings()
    handler = MENU_HANDLERS.get(menu_id)
    if handler is None:
        return error_response("unknown_menu", "Menu", f"Menu tidak dikenal: {menu_id}")

    return handler(payload.action, payload.params, settings)
