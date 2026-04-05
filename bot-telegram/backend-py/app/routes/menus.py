import json
import re
import time
from pathlib import Path

from fastapi import APIRouter, Depends, HTTPException, Request, Response, status

from ..adapters import system, system_mutations
from ..auth import verify_shared_secret
from ..config import get_settings
from ..schemas import ActionRequest, ActionResponse
from ..services import MENU_HANDLERS
from ..utils.response import error_response

router = APIRouter(tags=["menus"])
SSH_USERNAME_RE = re.compile(r"^[a-z_][a-z0-9_-]{1,31}$")
DOWNLOAD_TOKEN_RE = re.compile(r"^[A-Za-z0-9_-]{6,32}$")


def _load_commands_file(path: str) -> dict:
    p = Path(path)
    if not p.exists():
        return {"menus": []}
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception:
        return {"menus": []}


def _filter_commands_payload(payload: dict) -> dict:
    if not isinstance(payload, dict):
        return {"menus": []}

    filtered_menus = []
    for raw_menu in payload.get("menus", []):
        if not isinstance(raw_menu, dict):
            continue

        filtered_actions = []
        for raw_action in raw_menu.get("actions", []):
            if not isinstance(raw_action, dict):
                continue
            filtered_actions.append(raw_action)

        if not filtered_actions:
            continue

        menu_copy = dict(raw_menu)
        menu_copy["actions"] = filtered_actions
        filtered_menus.append(menu_copy)

    payload_copy = dict(payload)
    payload_copy["menus"] = sorted(
        filtered_menus,
        key=lambda item: (0, int(str(item.get("id", "")).strip()))
        if str(item.get("id", "")).strip().isdigit()
        else (1, str(item.get("id", "")).strip()),
    )
    return payload_copy


def _visible_menu_count(payload: dict) -> int:
    menus = payload.get("menus")
    if not isinstance(menus, list):
        return 0
    count = 0
    for raw_menu in menus:
        if not isinstance(raw_menu, dict):
            continue
        if bool(raw_menu.get("hidden", False)):
            continue
        if not isinstance(raw_menu.get("actions"), list) or not raw_menu.get("actions"):
            continue
        count += 1
    return count


@router.api_route("/ovpn/{token}", methods=["GET", "HEAD"], dependencies=[Depends(verify_shared_secret)])
def download_openvpn_profile(token: str, request: Request) -> Response:
    token_n = str(token or "").strip()
    if not DOWNLOAD_TOKEN_RE.fullmatch(token_n):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Link download tidak valid.")
    token_path = system_mutations._openvpn_download_token_file(token_n)
    if not token_path.exists():
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Link download tidak ditemukan.")
    try:
        payload = json.loads(token_path.read_text(encoding="utf-8", errors="ignore"))
    except Exception:
        token_path.unlink(missing_ok=True)
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Token download rusak.")
    exp = int(payload.get("exp") or 0)
    user_n = str(payload.get("username") or "").strip()
    if exp < int(time.time()):
        token_path.unlink(missing_ok=True)
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Link download sudah expired.")
    if not SSH_USERNAME_RE.fullmatch(user_n):
        token_path.unlink(missing_ok=True)
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Profile tidak ditemukan.")
    ok_profile, payload_or_err = system_mutations._openvpn_manage_json("profile-download", "--username", user_n, timeout=300)
    if not ok_profile or not isinstance(payload_or_err, dict):
        token_path.unlink(missing_ok=True)
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Profile OpenVPN tidak tersedia.")
    profile_path = Path(str(payload_or_err.get("profile_path") or "").strip())
    if not profile_path.exists():
        token_path.unlink(missing_ok=True)
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Profile OpenVPN tidak ditemukan.")
    if request.method.upper() == "HEAD":
        body = b""
        content_length = profile_path.stat().st_size
    else:
        body = profile_path.read_bytes()
        content_length = len(body)
    if request.method.upper() == "GET":
        token_path.unlink(missing_ok=True)
    headers = {
        "Content-Disposition": f'attachment; filename="{user_n}@openvpn.ovpn"',
        "Content-Length": str(content_length),
        "Cache-Control": "private, no-store",
    }
    return Response(
        content=body,
        media_type="text/plain; charset=utf-8",
        headers=headers,
    )


@router.get("/api/menus", dependencies=[Depends(verify_shared_secret)])
def get_menus() -> dict:
    settings = get_settings()
    return _filter_commands_payload(_load_commands_file(settings.commands_file))


@router.get("/api/main-menu", dependencies=[Depends(verify_shared_secret)])
def get_main_menu_overview() -> dict:
    settings = get_settings()
    data = _filter_commands_payload(_load_commands_file(settings.commands_file))
    return {
        "mode": "standalone",
        "menu_count": _visible_menu_count(data),
        "header_text": system.main_menu_header_text(),
        "menus": data.get("menus", []),
    }


@router.get("/api/users/options", dependencies=[Depends(verify_shared_secret)])
def get_user_options(proto: str | None = None) -> dict:
    proto_norm = (proto or "").strip().lower()
    allowed = set(system.USER_PROTOCOLS) | {getattr(system, "OPENVPN_POLICY_PROTOCOL", "openvpn")}
    if proto_norm and proto_norm not in allowed:
        return {"users": []}

    if proto_norm == getattr(system, "OPENVPN_POLICY_PROTOCOL", "openvpn"):
        users = [{"proto": proto_norm, "username": username} for username, _path in system._iter_proto_quota_files(proto_norm)]
        return {"users": users}

    records = system.list_accounts()
    if proto_norm:
        records = [(p, u) for p, u in records if p == proto_norm]

    return {
        "users": [{"proto": p, "username": u} for p, u in records],
    }


@router.get("/api/qac/user-summary", dependencies=[Depends(verify_shared_secret)])
def get_qac_user_summary(proto: str, username: str) -> dict:
    ok, payload = system.op_qac_user_summary(proto, username)
    if not ok:
        return {"ok": False, "summary": {}, "error": str(payload)}
    return {"ok": True, "summary": payload if isinstance(payload, dict) else {}}


@router.get("/api/inbounds/options", dependencies=[Depends(verify_shared_secret)])
def get_inbound_options() -> dict:
    tags = system.list_inbound_tags()
    return {
        "inbounds": [{"tag": tag} for tag in tags],
    }


@router.get("/api/network/domain-options", dependencies=[Depends(verify_shared_secret)])
def get_network_domain_options(mode: str | None = None) -> dict:
    entries = system.list_warp_domain_options(mode=mode)
    return {
        "entries": [{"entry": item} for item in entries],
    }


@router.get("/api/network/adblock/manual-options", dependencies=[Depends(verify_shared_secret)])
def get_network_adblock_manual_options() -> dict:
    entries = system.list_adblock_manual_domains()
    return {
        "entries": [{"entry": item} for item in entries],
    }


@router.get("/api/network/adblock/url-options", dependencies=[Depends(verify_shared_secret)])
def get_network_adblock_url_options() -> dict:
    entries = system.list_adblock_url_sources()
    return {
        "entries": [{"entry": item} for item in entries],
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
