from ..adapters import system, system_mutations
from ..utils.response import error_response, ok_response
from ..utils.validators import require_param


def handle(action: str, params: dict, settings) -> dict:
    if action == "warp_tier_status":
        title, msg = system.op_network_warp_tier_status()
        return ok_response(title, msg)

    if action == "warp_tier_free_plus_status":
        title, msg = system.op_network_warp_tier_free_plus_status()
        return ok_response(title, msg)

    if action == "warp_tier_zero_trust_status":
        title, msg = system.op_network_warp_tier_zero_trust_status()
        return ok_response(title, msg)

    if action == "warp_tier_zero_trust_requirements":
        title, msg = system.op_network_warp_tier_zero_trust_requirements()
        return ok_response(title, msg)

    if action == "warp_tier_zero_trust_rollout_notes":
        title, msg = system.op_network_warp_tier_zero_trust_rollout_notes()
        return ok_response(title, msg)

    if action == "warp_tier_switch_free":
        ok_op, title, msg = system_mutations.op_network_warp_tier_switch_free()
        if ok_op:
            return ok_response(title, msg)
        return error_response("warp_tier_switch_free_failed", title, msg)

    if action == "warp_tier_switch_plus":
        license_key = str(params.get("license_key", "")).strip()
        ok_op, title, msg = system_mutations.op_network_warp_tier_switch_plus(license_key)
        if ok_op:
            return ok_response(title, msg)
        return error_response("warp_tier_switch_plus_failed", title, msg)

    if action == "warp_tier_reconnect":
        ok_op, title, msg = system_mutations.op_network_warp_tier_reconnect()
        if ok_op:
            return ok_response(title, msg)
        return error_response("warp_tier_reconnect_failed", title, msg)

    if action == "warp_tier_zero_trust_set_team":
        ok_v, value_or_err = require_param(params, "team", "WARP Tier - Zero Trust Set Team")
        if not ok_v:
            return value_or_err
        ok_op, title, msg = system_mutations.op_network_warp_tier_zero_trust_set_team(str(value_or_err))
        if ok_op:
            return ok_response(title, msg)
        return error_response("warp_tier_zero_trust_set_team_failed", title, msg)

    if action == "warp_tier_zero_trust_set_client_id":
        ok_v, value_or_err = require_param(params, "client_id", "WARP Tier - Zero Trust Set Client ID")
        if not ok_v:
            return value_or_err
        ok_op, title, msg = system_mutations.op_network_warp_tier_zero_trust_set_client_id(str(value_or_err))
        if ok_op:
            return ok_response(title, msg)
        return error_response("warp_tier_zero_trust_set_client_id_failed", title, msg)

    if action == "warp_tier_zero_trust_set_client_secret":
        ok_v, value_or_err = require_param(params, "client_secret", "WARP Tier - Zero Trust Set Client Secret")
        if not ok_v:
            return value_or_err
        ok_op, title, msg = system_mutations.op_network_warp_tier_zero_trust_set_client_secret(str(value_or_err))
        if ok_op:
            return ok_response(title, msg)
        return error_response("warp_tier_zero_trust_set_client_secret_failed", title, msg)

    if action == "warp_tier_zero_trust_apply":
        ok_op, title, msg = system_mutations.op_network_warp_tier_zero_trust_apply()
        if ok_op:
            return ok_response(title, msg)
        return error_response("warp_tier_zero_trust_apply_failed", title, msg)

    if action == "warp_tier_zero_trust_disconnect":
        ok_op, title, msg = system_mutations.op_network_warp_tier_zero_trust_disconnect()
        if ok_op:
            return ok_response(title, msg)
        return error_response("warp_tier_zero_trust_disconnect_failed", title, msg)

    if action == "warp_tier_zero_trust_return_free_plus":
        ok_op, title, msg = system_mutations.op_network_warp_tier_zero_trust_return_free_plus()
        if ok_op:
            return ok_response(title, msg)
        return error_response("warp_tier_zero_trust_return_failed", title, msg)

    return error_response("unknown_action", "WARP Tier", f"Action tidak dikenal: {action}")
