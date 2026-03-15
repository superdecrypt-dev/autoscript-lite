from ..adapters import system, system_mutations
from ..utils.response import error_response, ok_response
from ..utils.validators import parse_bool_value, require_param


def handle(action: str, params: dict) -> dict:
    if action == "dns_summary":
        title, msg = system.op_dns_summary()
        return ok_response(title, msg)

    if action == "set_dns_primary":
        ok_d, dns_or_err = require_param(params, "dns", "Network Controls - Set Primary DNS")
        if not ok_d:
            return dns_or_err
        ok_op, title, msg = system_mutations.op_network_set_dns_primary(str(dns_or_err))
        if ok_op:
            return ok_response(title, msg)
        return error_response("network_dns_primary_failed", title, msg)

    if action == "set_dns_secondary":
        ok_d, dns_or_err = require_param(params, "dns", "Network Controls - Set Secondary DNS")
        if not ok_d:
            return dns_or_err
        ok_op, title, msg = system_mutations.op_network_set_dns_secondary(str(dns_or_err))
        if ok_op:
            return ok_response(title, msg)
        return error_response("network_dns_secondary_failed", title, msg)

    if action == "set_dns_query_strategy":
        ok_q, query_or_err = require_param(params, "strategy", "Network Controls - Set DNS Query Strategy")
        if not ok_q:
            return query_or_err
        ok_op, title, msg = system_mutations.op_network_set_dns_query_strategy(str(query_or_err))
        if ok_op:
            return ok_response(title, msg)
        return error_response("network_dns_query_strategy_failed", title, msg)

    if action == "toggle_dns_cache":
        ok_op, title, msg = system_mutations.op_network_toggle_dns_cache()
        if ok_op:
            return ok_response(title, msg)
        return error_response("network_dns_cache_toggle_failed", title, msg)

    if action == "state_file":
        title, msg = system.op_network_state_raw()
        return ok_response(title, msg)

    if action == "domain_guard_check":
        ok_chk, title, msg = system.op_domain_guard_check()
        if ok_chk:
            return ok_response(title, msg)
        return error_response("domain_guard_check_failed", title, msg)

    if action == "domain_guard_status":
        ok_status, title, msg = system.op_domain_guard_status()
        if ok_status:
            return ok_response(title, msg)
        return error_response("domain_guard_status_failed", title, msg)

    if action == "domain_guard_renew":
        force = bool(parse_bool_value(params.get("force"), default=False))
        ok_run, title, msg = system.op_domain_guard_renew_if_needed(force=force)
        if ok_run:
            return ok_response(title, msg)
        return error_response("domain_guard_renew_failed", title, msg)

    return error_response("unknown_action", "Network Controls", f"Action tidak dikenal: {action}")
