from ..adapters import system, system_mutations
from ..utils.response import error_response, ok_response
from ..utils.validators import require_param


def handle(action: str, params: dict, settings) -> dict:
    if action == "overview":
        title, msg = system.op_ssh_network_overview()
        return ok_response(title, msg)

    if action == "dns_for_ssh_status":
        title, msg = system.op_ssh_network_dns_status()
        return ok_response(title, msg)

    if action == "routing_ssh_global_status":
        title, msg = system.op_ssh_network_routing_global_status()
        return ok_response(title, msg)

    if action == "routing_ssh_per_user_status":
        title, msg = system.op_ssh_network_routing_user_status()
        return ok_response(title, msg)

    if action == "warp_ssh_global_status":
        title, msg = system.op_ssh_network_warp_global_status()
        return ok_response(title, msg)

    if action == "warp_ssh_per_user_status":
        title, msg = system.op_ssh_network_warp_user_status()
        return ok_response(title, msg)

    if action == "dns_for_ssh_enable":
        ok_op, title, msg = system_mutations.op_ssh_network_dns_set_enabled(True)
        if ok_op:
            return ok_response(title, msg)
        return error_response("ssh_network_dns_enable_failed", title, msg)

    if action == "dns_for_ssh_disable":
        ok_op, title, msg = system_mutations.op_ssh_network_dns_set_enabled(False)
        if ok_op:
            return ok_response(title, msg)
        return error_response("ssh_network_dns_disable_failed", title, msg)

    if action == "dns_for_ssh_set_primary":
        ok_v, value_or_err = require_param(params, "dns", "SSH Network - Set Primary DNS")
        if not ok_v:
            return value_or_err
        ok_op, title, msg = system_mutations.op_ssh_network_dns_set_primary(str(value_or_err))
        if ok_op:
            return ok_response(title, msg)
        return error_response("ssh_network_dns_primary_failed", title, msg)

    if action == "dns_for_ssh_set_secondary":
        ok_v, value_or_err = require_param(params, "dns", "SSH Network - Set Secondary DNS")
        if not ok_v:
            return value_or_err
        ok_op, title, msg = system_mutations.op_ssh_network_dns_set_secondary(str(value_or_err))
        if ok_op:
            return ok_response(title, msg)
        return error_response("ssh_network_dns_secondary_failed", title, msg)

    if action == "dns_for_ssh_apply":
        ok_op, title, msg = system_mutations.op_ssh_network_dns_apply_runtime()
        if ok_op:
            return ok_response(title, msg)
        return error_response("ssh_network_dns_apply_failed", title, msg)

    if action == "routing_ssh_global_direct":
        ok_op, title, msg = system_mutations.op_ssh_network_set_global_mode("direct")
        if ok_op:
            return ok_response(title, msg)
        return error_response("ssh_network_global_direct_failed", title, msg)

    if action == "routing_ssh_global_warp":
        ok_op, title, msg = system_mutations.op_ssh_network_set_global_mode("warp")
        if ok_op:
            return ok_response(title, msg)
        return error_response("ssh_network_global_warp_failed", title, msg)

    if action == "routing_ssh_backend_auto":
        ok_op, title, msg = system_mutations.op_ssh_network_set_backend("auto")
        if ok_op:
            return ok_response(title, msg)
        return error_response("ssh_network_backend_auto_failed", title, msg)

    if action == "routing_ssh_backend_local_proxy":
        ok_op, title, msg = system_mutations.op_ssh_network_set_backend("local-proxy")
        if ok_op:
            return ok_response(title, msg)
        return error_response("ssh_network_backend_local_proxy_failed", title, msg)

    if action == "routing_ssh_backend_interface":
        ok_op, title, msg = system_mutations.op_ssh_network_set_backend("interface")
        if ok_op:
            return ok_response(title, msg)
        return error_response("ssh_network_backend_interface_failed", title, msg)

    if action == "routing_ssh_apply":
        ok_op, title, msg = system_mutations.op_ssh_network_apply_runtime()
        if ok_op:
            return ok_response(title, msg)
        return error_response("ssh_network_apply_failed", title, msg)

    if action in {"routing_ssh_user_inherit", "routing_ssh_user_direct", "routing_ssh_user_warp"}:
        ok_u, user_or_err = require_param(params, "username", "SSH Network - Routing SSH Per-User")
        if not ok_u:
            return user_or_err
        mode = {
            "routing_ssh_user_inherit": "inherit",
            "routing_ssh_user_direct": "direct",
            "routing_ssh_user_warp": "warp",
        }[action]
        ok_op, title, msg = system_mutations.op_ssh_network_set_user_route_mode(str(user_or_err), mode)
        if ok_op:
            return ok_response(title, msg)
        return error_response("ssh_network_user_route_failed", title, msg)

    if action == "warp_ssh_global_enable":
        ok_op, title, msg = system_mutations.op_ssh_network_set_warp_global(True)
        if ok_op:
            return ok_response(title, msg)
        return error_response("ssh_network_warp_global_enable_failed", title, msg)

    if action == "warp_ssh_global_disable":
        ok_op, title, msg = system_mutations.op_ssh_network_set_warp_global(False)
        if ok_op:
            return ok_response(title, msg)
        return error_response("ssh_network_warp_global_disable_failed", title, msg)

    if action in {"warp_ssh_user_enable", "warp_ssh_user_disable", "warp_ssh_user_inherit"}:
        ok_u, user_or_err = require_param(params, "username", "SSH Network - WARP SSH Per-User")
        if not ok_u:
            return user_or_err
        mode = {
            "warp_ssh_user_enable": "warp",
            "warp_ssh_user_disable": "direct",
            "warp_ssh_user_inherit": "inherit",
        }[action]
        ok_op, title, msg = system_mutations.op_ssh_network_set_warp_user_mode(str(user_or_err), mode)
        if ok_op:
            return ok_response(title, msg)
        return error_response("ssh_network_warp_user_failed", title, msg)

    return error_response("unknown_action", "SSH Network", f"Action tidak dikenal: {action}")
