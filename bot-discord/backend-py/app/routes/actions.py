from fastapi import APIRouter, Depends

from ..adapters import system, system_mutations
from ..auth import verify_shared_secret
from ..schemas import ActionRequest, ActionResponse
from ..services import (
    domain,
    network,
    ops,
    qac,
    status,
    users,
)
from ..utils.response import error_response

router = APIRouter(tags=["actions"])


def _params_dict(payload: ActionRequest) -> dict:
    return dict(payload.params or {})


def _resolve_user_handler(params: dict):
    user_type = str(params.get("type") or params.get("proto") or "").strip().lower()
    if user_type == system.SSH_PROTOCOL:
        params["type"] = system.SSH_PROTOCOL
        return users.handle
    if user_type in set(system.XRAY_PROTOCOLS):
        params["type"] = user_type
        params["proto"] = user_type
        return users.handle
    return None


def _resolve_qac_handler(params: dict):
    scope = str(params.get("scope") or "").strip().lower()
    if scope:
        if scope not in {"xray", "ssh"}:
            return None
        return qac.handle
    return _resolve_user_handler(params) and qac.handle


@router.get("/api/users/options", dependencies=[Depends(verify_shared_secret)])
def get_user_options(proto: str | None = None) -> dict:
    proto_norm = (proto or "").strip().lower()
    if proto_norm and proto_norm not in set(system.USER_PROTOCOLS):
        return {"users": []}

    records = system.list_accounts((proto_norm,)) if proto_norm else system.list_accounts()
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


@router.get("/api/qac/summary", dependencies=[Depends(verify_shared_secret)])
def get_qac_user_summary(proto: str, username: str) -> dict:
    ok, payload = system.op_qac_user_summary(proto, username)
    if not ok:
        return {"ok": False, "error": str(payload)}
    return {"ok": True, "summary": payload}


@router.post(
    "/api/status/action",
    dependencies=[Depends(verify_shared_secret)],
    response_model=ActionResponse,
)
def run_status_action(payload: ActionRequest) -> dict:
    action_map = {
        "overview": (status.handle, "overview"),
        "tls": (status.handle, "tls_info"),
        "xray_test": (status.handle, "xray_test"),
        "services": (status.handle, "services"),
    }
    target = action_map.get(payload.action)
    if target is None:
        return error_response("unknown_action", "Status", f"Action tidak dikenal: {payload.action}")
    handler, action = target
    return handler(action, _params_dict(payload))


@router.post(
    "/api/users/action",
    dependencies=[Depends(verify_shared_secret)],
    response_model=ActionResponse,
)
def run_users_action(payload: ActionRequest) -> dict:
    params = _params_dict(payload)
    handler = _resolve_user_handler(params)
    if handler is None:
        return error_response("invalid_type", "Users", "Type user tidak valid.")

    action = str(payload.action or "").strip().lower()
    action_map = {
        "add": "add_user",
        "info": "account_info",
        "delete": "delete_user",
        "extend": "extend_expiry",
        "reset_password": "reset_password",
    }
    target_action = action_map.get(action)
    if target_action is None:
        return error_response("unknown_action", "Users", f"Action tidak dikenal: {payload.action}")

    if action == "extend":
        days = str(params.pop("days", "")).strip()
        params["mode"] = "extend"
        params["value"] = days

    if action == "reset_password" and str(params.get("type")) != "ssh":
        return error_response("invalid_type", "Users", "Reset password saat ini hanya didukung untuk SSH.")

    return handler(target_action, params)


@router.post(
    "/api/qac/action",
    dependencies=[Depends(verify_shared_secret)],
    response_model=ActionResponse,
)
def run_qac_action(payload: ActionRequest) -> dict:
    params = _params_dict(payload)
    handler = _resolve_qac_handler(params)
    if handler is None:
        return error_response("invalid_type", "QAC", "Scope atau type user tidak valid.")

    action_map = {
        "summary": "summary",
        "detail": "detail",
        "set_quota": "set_quota_limit",
        "reset_used": "reset_quota_used",
        "toggle_block": "manual_block",
        "toggle_ip_limit": "ip_limit_enable",
        "set_ip_limit": "set_ip_limit",
        "unlock_ip": "unlock_ip_lock",
        "set_speed_down": "set_speed_download",
        "set_speed_up": "set_speed_upload",
        "toggle_speed": "speed_limit",
    }
    target_action = action_map.get(str(payload.action or "").strip().lower())
    if target_action is None:
        return error_response("unknown_action", "QAC", f"Action tidak dikenal: {payload.action}")

    return handler(target_action, params)


@router.post(
    "/api/domain/action",
    dependencies=[Depends(verify_shared_secret)],
    response_model=ActionResponse,
)
def run_domain_action(payload: ActionRequest) -> dict:
    action_map = {
        "info": "domain_info",
        "server_name": "nginx_server_name",
        "set_manual": "setup_domain_custom",
        "set_auto": "setup_domain_cloudflare",
        "refresh_accounts": "refresh_account_info",
    }
    target_action = action_map.get(str(payload.action or "").strip().lower())
    if target_action is None:
        return error_response("unknown_action", "Domain", f"Action tidak dikenal: {payload.action}")
    return domain.handle(target_action, _params_dict(payload))


@router.post(
    "/api/network/action",
    dependencies=[Depends(verify_shared_secret)],
    response_model=ActionResponse,
)
def run_network_action(payload: ActionRequest) -> dict:
    action = str(payload.action or "").strip().lower()
    params = _params_dict(payload)

    network_actions = {
        "dns_summary": "dns_summary",
        "set_dns_primary": "set_dns_primary",
        "set_dns_secondary": "set_dns_secondary",
        "set_dns_strategy": "set_dns_query_strategy",
        "toggle_dns_cache": "toggle_dns_cache",
        "state_file": "state_file",
    }
    if action in network_actions:
        return network.handle(network_actions[action], params)

    domain_guard_actions = {
        "domain_guard_status": "domain_guard_status",
        "domain_guard_check": "domain_guard_check",
        "domain_guard_renew": "domain_guard_renew",
    }
    if action in domain_guard_actions:
        return network.handle(domain_guard_actions[action], params)

    return error_response("unknown_action", "Network", f"Action tidak dikenal: {payload.action}")


@router.post(
    "/api/ops/action",
    dependencies=[Depends(verify_shared_secret)],
    response_model=ActionResponse,
)
def run_ops_action(payload: ActionRequest) -> dict:
    action = str(payload.action or "").strip().lower()
    params = _params_dict(payload)

    if action == "speedtest":
        return ops.handle("speedtest", params)

    if action == "service_status":
        return ops.handle("service_status", params)

    if action == "restart_service":
        return ops.handle("restart_service", params)

    traffic_actions = {
        "traffic_overview": "overview",
        "traffic_top": "top_users",
        "traffic_search": "search_user",
        "traffic_export": "export_json",
    }
    if action in traffic_actions:
        return ops.handle(action, params)

    return error_response("unknown_action", "Ops", f"Action tidak dikenal: {payload.action}")
