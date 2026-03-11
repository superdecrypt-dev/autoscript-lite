from ..adapters import system, system_mutations
from ..utils.response import error_response, ok_response
from ..utils.validators import require_param


def handle(action: str, params: dict, settings) -> dict:
    if action == "dns_summary":
        title, msg = system.op_dns_summary()
        return ok_response(title, msg)

    if action == "set_dns_primary":
        if not settings.enable_dangerous_actions:
            return error_response("forbidden", "Network Controls", "Dangerous actions dinonaktifkan via env.")
        ok_d, dns_or_err = require_param(params, "dns", "Network Controls - Set Primary DNS")
        if not ok_d:
            return dns_or_err
        ok_op, title, msg = system_mutations.op_network_set_dns_primary(str(dns_or_err))
        if ok_op:
            return ok_response(title, msg)
        return error_response("network_dns_primary_failed", title, msg)

    if action == "set_dns_secondary":
        if not settings.enable_dangerous_actions:
            return error_response("forbidden", "Network Controls", "Dangerous actions dinonaktifkan via env.")
        ok_d, dns_or_err = require_param(params, "dns", "Network Controls - Set Secondary DNS")
        if not ok_d:
            return dns_or_err
        ok_op, title, msg = system_mutations.op_network_set_dns_secondary(str(dns_or_err))
        if ok_op:
            return ok_response(title, msg)
        return error_response("network_dns_secondary_failed", title, msg)

    if action == "set_dns_query_strategy":
        if not settings.enable_dangerous_actions:
            return error_response("forbidden", "Network Controls", "Dangerous actions dinonaktifkan via env.")
        ok_q, query_or_err = require_param(params, "strategy", "Network Controls - Set DNS Query Strategy")
        if not ok_q:
            return query_or_err
        ok_op, title, msg = system_mutations.op_network_set_dns_query_strategy(str(query_or_err))
        if ok_op:
            return ok_response(title, msg)
        return error_response("network_dns_query_strategy_failed", title, msg)

    if action == "toggle_dns_cache":
        if not settings.enable_dangerous_actions:
            return error_response("forbidden", "Network Controls", "Dangerous actions dinonaktifkan via env.")
        ok_op, title, msg = system_mutations.op_network_toggle_dns_cache()
        if ok_op:
            return ok_response(title, msg)
        return error_response("network_dns_cache_toggle_failed", title, msg)

    if action == "state_file":
        title, msg = system.op_network_state_raw()
        return ok_response(title, msg)
    return error_response("unknown_action", "Network Controls", f"Action tidak dikenal: {action}")
