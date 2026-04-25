from ..adapters import system, system_mutations
from ..utils.response import error_response, ok_response
from ..utils.validators import require_param, require_positive_int_param, require_protocol, require_username


def handle(action: str, params: dict, settings) -> dict:
    if action == "warp_status":
        title, msg = system.op_network_warp_status_report()
        return ok_response(title, msg)

    if action == "warp_restart":
        ok_op, title, msg = system_mutations.op_network_warp_restart()
        if ok_op:
            return ok_response(title, msg)
        return error_response("network_warp_restart_failed", title, msg)

    if action == "set_warp_global_mode":
        ok_m, mode_or_err = require_param(params, "mode", "Network Controls - WARP Global Mode")
        if not ok_m:
            return mode_or_err
        ok_op, title, msg = system_mutations.op_network_warp_set_global_mode(str(mode_or_err))
        if ok_op:
            return ok_response(title, msg)
        return error_response("network_warp_global_mode_failed", title, msg)

    if action == "set_warp_user_mode":
        title = "Network Controls - WARP per-user"
        ok_p, proto_or_err = require_protocol(params, title)
        if not ok_p:
            return proto_or_err
        ok_u, user_or_err = require_username(params, title)
        if not ok_u:
            return user_or_err
        ok_m, mode_or_err = require_param(params, "mode", title)
        if not ok_m:
            return mode_or_err
        ok_op, t, m = system_mutations.op_network_warp_set_user_mode(proto_or_err, user_or_err, str(mode_or_err))
        if ok_op:
            return ok_response(t, m)
        return error_response("network_warp_user_mode_failed", t, m)

    if action == "set_warp_inbound_mode":
        ok_t, tag_or_err = require_param(params, "inbound_tag", "Network Controls - WARP per-inbound")
        if not ok_t:
            return tag_or_err
        ok_m, mode_or_err = require_param(params, "mode", "Network Controls - WARP per-inbound")
        if not ok_m:
            return mode_or_err
        ok_op, title, msg = system_mutations.op_network_warp_set_inbound_mode(str(tag_or_err), str(mode_or_err))
        if ok_op:
            return ok_response(title, msg)
        return error_response("network_warp_inbound_mode_failed", title, msg)

    if action == "set_warp_domain_mode":
        ok_m, mode_or_err = require_param(params, "mode", "Network Controls - WARP per-domain")
        if not ok_m:
            return mode_or_err
        ok_e, entry_or_err = require_param(params, "entry", "Network Controls - WARP per-domain")
        if not ok_e:
            return entry_or_err
        ok_op, title, msg = system_mutations.op_network_warp_set_domain_mode(str(mode_or_err), str(entry_or_err))
        if ok_op:
            return ok_response(title, msg)
        return error_response("network_warp_domain_mode_failed", title, msg)

    if action == "warp_tier_status":
        title, msg = system.op_network_warp_tier_status()
        return ok_response(title, msg)

    if action == "warp_tier_switch_free":
        ok_op, title, msg = system_mutations.op_network_warp_tier_switch_free()
        if ok_op:
            return ok_response(title, msg)
        return error_response("network_warp_tier_switch_failed", title, msg)

    if action == "warp_tier_switch_plus":
        license_key = str(params.get("license_key", "")).strip()
        ok_op, title, msg = system_mutations.op_network_warp_tier_switch_plus(license_key)
        if ok_op:
            return ok_response(title, msg)
        return error_response("network_warp_tier_switch_failed", title, msg)

    if action == "warp_tier_reconnect":
        ok_op, title, msg = system_mutations.op_network_warp_tier_reconnect()
        if ok_op:
            return ok_response(title, msg)
        return error_response("network_warp_tier_reconnect_failed", title, msg)

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

    if action == "toggle_dns_parallel_query":
        ok_op, title, msg = system_mutations.op_network_toggle_dns_parallel_query()
        if ok_op:
            return ok_response(title, msg)
        return error_response("network_dns_parallel_toggle_failed", title, msg)

    if action == "toggle_dns_system_hosts":
        ok_op, title, msg = system_mutations.op_network_toggle_dns_system_hosts()
        if ok_op:
            return ok_response(title, msg)
        return error_response("network_dns_system_hosts_toggle_failed", title, msg)

    if action == "toggle_dns_disable_fallback":
        ok_op, title, msg = system_mutations.op_network_toggle_dns_disable_fallback()
        if ok_op:
            return ok_response(title, msg)
        return error_response("network_dns_disable_fallback_toggle_failed", title, msg)

    if action == "toggle_dns_disable_fallback_if_match":
        ok_op, title, msg = system_mutations.op_network_toggle_dns_disable_fallback_if_match()
        if ok_op:
            return ok_response(title, msg)
        return error_response("network_dns_disable_fallback_if_match_toggle_failed", title, msg)

    if action == "pin_dns_host":
        ok_d, domain_or_err = require_param(params, "domain", "Network Controls - DNS Advanced")
        if not ok_d:
            return domain_or_err
        ok_v, value_or_err = require_param(params, "value", "Network Controls - DNS Advanced")
        if not ok_v:
            return value_or_err
        ok_op, title, msg = system_mutations.op_network_pin_dns_host(str(domain_or_err), str(value_or_err))
        if ok_op:
            return ok_response(title, msg)
        return error_response("network_dns_host_pin_failed", title, msg)

    if action == "clear_dns_host_pin":
        ok_d, domain_or_err = require_param(params, "domain", "Network Controls - DNS Advanced")
        if not ok_d:
            return domain_or_err
        ok_op, title, msg = system_mutations.op_network_clear_dns_host_pin(str(domain_or_err))
        if ok_op:
            return ok_response(title, msg)
        return error_response("network_dns_host_pin_clear_failed", title, msg)

    if action == "state_file":
        title, msg = system.op_network_state_raw()
        return ok_response(title, msg)

    if action == "network_summary":
        title, msg = system.op_network_routing_summary()
        return ok_response(title, msg)

    if action == "routing_user_overrides":
        title, msg = system.op_network_routing_user_overrides()
        return ok_response(title, msg)

    if action == "routing_inbound_overrides":
        title, msg = system.op_network_routing_inbound_overrides()
        return ok_response(title, msg)

    if action == "routing_domain_buckets":
        title, msg = system.op_network_routing_domain_buckets()
        return ok_response(title, msg)

    if action == "routing_custom_lists":
        title, msg = system.op_network_routing_custom_lists()
        return ok_response(title, msg)

    if action == "routing_conflict_check":
        title, msg = system.op_network_routing_conflict_check()
        return ok_response(title, msg)

    if action == "validate_confd_json":
        title, msg = system.op_network_validate_confd_json()
        return ok_response(title, msg)

    if action == "xray_config_test":
        ok_op, title, msg = system.op_xray_test()
        if ok_op:
            return ok_response(title, msg)
        return error_response("network_xray_config_test_failed", title, msg)

    if action == "core_service_status":
        title, msg = system.op_network_core_service_status()
        return ok_response(title, msg)

    if action == "adblock_status":
        title, msg = system.op_network_adblock_status()
        return ok_response(title, msg)

    if action == "adblock_show_bound_users":
        title, msg = system.op_network_adblock_bound_users()
        return ok_response(title, msg)

    if action == "adblock_enable":
        ok_op, title, msg = system_mutations.op_network_adblock_enable()
        if ok_op:
            return ok_response(title, msg)
        return error_response("network_adblock_enable_failed", title, msg)

    if action == "adblock_disable":
        ok_op, title, msg = system_mutations.op_network_adblock_disable()
        if ok_op:
            return ok_response(title, msg)
        return error_response("network_adblock_disable_failed", title, msg)

    if action == "add_adblock_domain":
        ok_d, domain_or_err = require_param(params, "domain", "Network - Adblock Add Domain")
        if not ok_d:
            return domain_or_err
        ok_op, title, msg = system_mutations.op_network_adblock_add_domain(str(domain_or_err))
        if ok_op:
            return ok_response(title, msg)
        return error_response("network_adblock_add_domain_failed", title, msg)

    if action == "delete_adblock_domain":
        ok_d, domain_or_err = require_param(params, "domain", "Network - Adblock Delete Domain")
        if not ok_d:
            return domain_or_err
        ok_op, title, msg = system_mutations.op_network_adblock_delete_domain(str(domain_or_err))
        if ok_op:
            return ok_response(title, msg)
        return error_response("network_adblock_delete_domain_failed", title, msg)

    if action == "add_adblock_url_source":
        ok_u, url_or_err = require_param(params, "url", "Network - Adblock Add URL Source")
        if not ok_u:
            return url_or_err
        ok_op, title, msg = system_mutations.op_network_adblock_add_url_source(str(url_or_err))
        if ok_op:
            return ok_response(title, msg)
        return error_response("network_adblock_add_url_failed", title, msg)

    if action == "delete_adblock_url_source":
        ok_u, url_or_err = require_param(params, "url", "Network - Adblock Delete URL Source")
        if not ok_u:
            return url_or_err
        ok_op, title, msg = system_mutations.op_network_adblock_delete_url_source(str(url_or_err))
        if ok_op:
            return ok_response(title, msg)
        return error_response("network_adblock_delete_url_failed", title, msg)

    if action == "adblock_update":
        ok_op, title, msg = system_mutations.op_network_adblock_update()
        if ok_op:
            return ok_response(title, msg)
        return error_response("network_adblock_update_failed", title, msg)

    if action == "adblock_toggle_auto_update":
        ok_op, title, msg = system_mutations.op_network_adblock_toggle_auto_update()
        if ok_op:
            return ok_response(title, msg)
        return error_response("network_adblock_toggle_auto_update_failed", title, msg)

    if action == "adblock_set_auto_update_days":
        ok_d, days_or_err = require_positive_int_param(params, "days", "Network - Adblock Set Auto Update Interval", minimum=1)
        if not ok_d:
            return days_or_err
        ok_op, title, msg = system_mutations.op_network_adblock_set_auto_update_days(int(days_or_err))
        if ok_op:
            return ok_response(title, msg)
        return error_response("network_adblock_set_auto_update_days_failed", title, msg)

    return error_response("unknown_action", "Network Controls", f"Action tidak dikenal: {action}")
