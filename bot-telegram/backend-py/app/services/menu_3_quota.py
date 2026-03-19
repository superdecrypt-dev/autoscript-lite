from ..adapters import system, system_mutations
from ..utils.response import error_response, ok_response
from ..utils.validators import (
    require_bool_param,
    require_positive_float_param,
    require_positive_int_param,
    require_protocol,
    require_username,
)

USER_PROTOCOLS = tuple(system.USER_PROTOCOLS)
XRAY_ONLY_PROTOCOLS = tuple(system.XRAY_PROTOCOLS)
SSH_ONLY_PROTOCOLS = (system.SSH_PROTOCOL,)


def _scope_title(scope: str, label: str) -> str:
    prefix = {
        "xray": "Xray QAC",
        "ssh": "SSH QAC",
    }.get(scope, "Quota & Access Control")
    return f"{prefix} - {label}" if label else prefix


def _scope_protocols(scope: str) -> tuple[str, ...]:
    if scope == "xray":
        return XRAY_ONLY_PROTOCOLS
    if scope == "ssh":
        return SSH_ONLY_PROTOCOLS
    return USER_PROTOCOLS


def _resolve_proto(params: dict, title: str, scope: str) -> tuple[bool, str | dict]:
    protocols = _scope_protocols(scope)
    if protocols == SSH_ONLY_PROTOCOLS:
        return True, system.SSH_PROTOCOL
    return require_protocol(params, title, allowed=set(protocols))


def handle_scoped(action: str, params: dict, settings, *, scope: str = "all") -> dict:
    protocol_scope = _scope_protocols(scope)

    if action == "summary":
        title, msg = system.op_quota_summary(protocol_scope, title=_scope_title(scope, "Summary"))
        return ok_response(title, msg)

    if action == "detail":
        title = _scope_title(scope, "Detail")
        ok_p, proto_or_err = _resolve_proto(params, title, scope)
        if not ok_p:
            return proto_or_err
        ok_u, user_or_err = require_username(params, title)
        if not ok_u:
            return user_or_err
        _title, msg = system.op_quota_detail(str(proto_or_err).lower(), str(user_or_err))
        data = {"allow_sensitive_output": True} if str(proto_or_err).lower() == system.SSH_PROTOCOL else None
        return ok_response(title, msg, data=data)

    if action == "set_quota_limit":
        if not settings.mutations_enabled:
            return error_response("forbidden", _scope_title(scope, ""), "Dangerous actions dinonaktifkan via env.")
        title = _scope_title(scope, "Set Quota Limit")
        ok_p, proto_or_err = _resolve_proto(params, title, scope)
        if not ok_p:
            return proto_or_err
        ok_u, user_or_err = require_username(params, title)
        if not ok_u:
            return user_or_err
        ok_q, quota_or_err = require_positive_float_param(params, "quota_gb", title)
        if not ok_q:
            return quota_or_err
        ok_m, _t, m = system_mutations.op_quota_set_limit(str(proto_or_err), str(user_or_err), float(quota_or_err))
        if ok_m:
            return ok_response(title, m)
        return error_response("quota_set_limit_failed", title, m)

    if action == "reset_quota_used":
        if not settings.mutations_enabled:
            return error_response("forbidden", _scope_title(scope, ""), "Dangerous actions dinonaktifkan via env.")
        title = _scope_title(scope, "Reset Quota Used")
        ok_p, proto_or_err = _resolve_proto(params, title, scope)
        if not ok_p:
            return proto_or_err
        ok_u, user_or_err = require_username(params, title)
        if not ok_u:
            return user_or_err
        ok_m, _t, m = system_mutations.op_quota_reset_used(str(proto_or_err), str(user_or_err))
        if ok_m:
            return ok_response(title, m)
        return error_response("quota_reset_used_failed", title, m)

    if action == "manual_block":
        if not settings.mutations_enabled:
            return error_response("forbidden", _scope_title(scope, ""), "Dangerous actions dinonaktifkan via env.")
        title = _scope_title(scope, "Manual Block")
        ok_p, proto_or_err = _resolve_proto(params, title, scope)
        if not ok_p:
            return proto_or_err
        ok_u, user_or_err = require_username(params, title)
        if not ok_u:
            return user_or_err
        ok_e, enabled_or_err = require_bool_param(params, "enabled", title)
        if not ok_e:
            return enabled_or_err
        ok_m, _t, m = system_mutations.op_quota_manual_block(str(proto_or_err), str(user_or_err), bool(enabled_or_err))
        if ok_m:
            return ok_response(title, m)
        return error_response("quota_manual_block_failed", title, m)

    if action == "ip_limit_enable":
        if not settings.mutations_enabled:
            return error_response("forbidden", _scope_title(scope, ""), "Dangerous actions dinonaktifkan via env.")
        title = _scope_title(scope, "IP/Login Limit")
        ok_p, proto_or_err = _resolve_proto(params, title, scope)
        if not ok_p:
            return proto_or_err
        ok_u, user_or_err = require_username(params, title)
        if not ok_u:
            return user_or_err
        ok_e, enabled_or_err = require_bool_param(params, "enabled", title)
        if not ok_e:
            return enabled_or_err
        ok_m, _t, m = system_mutations.op_quota_ip_limit_enable(str(proto_or_err), str(user_or_err), bool(enabled_or_err))
        if ok_m:
            return ok_response(title, m)
        return error_response("quota_ip_limit_toggle_failed", title, m)

    if action == "set_ip_limit":
        if not settings.mutations_enabled:
            return error_response("forbidden", _scope_title(scope, ""), "Dangerous actions dinonaktifkan via env.")
        title = _scope_title(scope, "Set IP/Login Limit")
        ok_p, proto_or_err = _resolve_proto(params, title, scope)
        if not ok_p:
            return proto_or_err
        ok_u, user_or_err = require_username(params, title)
        if not ok_u:
            return user_or_err
        ok_l, lim_or_err = require_positive_int_param(params, "ip_limit", title, minimum=1)
        if not ok_l:
            return lim_or_err
        ok_m, _t, m = system_mutations.op_quota_set_ip_limit(str(proto_or_err), str(user_or_err), int(lim_or_err))
        if ok_m:
            return ok_response(title, m)
        return error_response("quota_set_ip_limit_failed", title, m)

    if action == "unlock_ip_lock":
        if not settings.mutations_enabled:
            return error_response("forbidden", _scope_title(scope, ""), "Dangerous actions dinonaktifkan via env.")
        title = _scope_title(scope, "Unlock IP Lock")
        ok_p, proto_or_err = _resolve_proto(params, title, scope)
        if not ok_p:
            return proto_or_err
        ok_u, user_or_err = require_username(params, title)
        if not ok_u:
            return user_or_err
        ok_m, _t, m = system_mutations.op_quota_unlock_ip_lock(str(proto_or_err), str(user_or_err))
        if ok_m:
            return ok_response(title, m)
        return error_response("quota_unlock_ip_failed", title, m)

    if action == "set_speed_download":
        if not settings.mutations_enabled:
            return error_response("forbidden", _scope_title(scope, ""), "Dangerous actions dinonaktifkan via env.")
        title = _scope_title(scope, "Set Speed Download")
        ok_p, proto_or_err = _resolve_proto(params, title, scope)
        if not ok_p:
            return proto_or_err
        ok_u, user_or_err = require_username(params, title)
        if not ok_u:
            return user_or_err
        ok_v, val_or_err = require_positive_float_param(params, "speed_down_mbit", title)
        if not ok_v:
            return val_or_err
        ok_m, _t, m = system_mutations.op_quota_set_speed_down(str(proto_or_err), str(user_or_err), float(val_or_err))
        if ok_m:
            return ok_response(title, m)
        return error_response("quota_speed_down_failed", title, m)

    if action == "set_speed_upload":
        if not settings.mutations_enabled:
            return error_response("forbidden", _scope_title(scope, ""), "Dangerous actions dinonaktifkan via env.")
        title = _scope_title(scope, "Set Speed Upload")
        ok_p, proto_or_err = _resolve_proto(params, title, scope)
        if not ok_p:
            return proto_or_err
        ok_u, user_or_err = require_username(params, title)
        if not ok_u:
            return user_or_err
        ok_v, val_or_err = require_positive_float_param(params, "speed_up_mbit", title)
        if not ok_v:
            return val_or_err
        ok_m, _t, m = system_mutations.op_quota_set_speed_up(str(proto_or_err), str(user_or_err), float(val_or_err))
        if ok_m:
            return ok_response(title, m)
        return error_response("quota_speed_up_failed", title, m)

    if action == "speed_limit":
        if not settings.mutations_enabled:
            return error_response("forbidden", _scope_title(scope, ""), "Dangerous actions dinonaktifkan via env.")
        title = _scope_title(scope, "Speed Limit")
        ok_p, proto_or_err = _resolve_proto(params, title, scope)
        if not ok_p:
            return proto_or_err
        ok_u, user_or_err = require_username(params, title)
        if not ok_u:
            return user_or_err
        ok_e, enabled_or_err = require_bool_param(params, "enabled", title)
        if not ok_e:
            return enabled_or_err
        ok_m, _t, m = system_mutations.op_quota_speed_limit(str(proto_or_err), str(user_or_err), bool(enabled_or_err))
        if ok_m:
            return ok_response(title, m)
        return error_response("quota_speed_toggle_failed", title, m)

    return error_response("unknown_action", _scope_title(scope, ""), f"Action tidak dikenal: {action}")


def handle(action: str, params: dict, settings) -> dict:
    return handle_scoped(action, params, settings, scope="all")
