from ..adapters import system, system_mutations
from ..utils.response import error_response, ok_response


def handle(action: str, params: dict, settings) -> dict:
    if action == "service_status":
        title, msg = system.op_maintenance_status()
        return ok_response(title, msg)

    if action == "wireproxy_status":
        title, msg = system.op_wireproxy_status()
        return ok_response(title, msg)

    if action == "edge_gateway_status":
        title, msg = system.op_edge_gateway_status()
        return ok_response(title, msg)

    if action == "badvpn_status":
        title, msg = system.op_badvpn_status()
        return ok_response(title, msg)

    if action == "daemon_status":
        title, msg = system.op_daemon_status()
        return ok_response(title, msg)

    if action == "sshws_status":
        title, msg = system.op_sshws_status()
        return ok_response(title, msg)

    if action == "active_sshws_sessions":
        title, msg = system.op_sshws_active_sessions()
        return ok_response("Maintenance - Active SSHWS Sessions", msg)

    if action == "sshws_diagnostics":
        title, msg = system.op_sshws_diagnostics()
        return ok_response(title, msg)

    if action == "xray_logs":
        title, msg = system.op_service_log_tail("xray", lines=40)
        return ok_response(title, msg)

    if action == "nginx_logs":
        title, msg = system.op_service_log_tail("nginx", lines=40)
        return ok_response(title, msg)

    if action == "xray_daemon_logs":
        title, msg = system.op_xray_daemon_logs()
        return ok_response(title, msg)

    if action == "sshws_combined_logs":
        title, msg = system.op_sshws_combined_logs()
        return ok_response(title, msg)

    if action in {"restart_xray", "restart_nginx", "restart_wireproxy", "restart_edge_gateway", "restart_badvpn"}:
        if action == "restart_edge_gateway":
            ok, title, msg = system.op_restart_edge_gateway()
        elif action == "restart_wireproxy":
            ok, title, msg = system_mutations.op_network_warp_restart()
        else:
            svc = {
                "restart_xray": "xray",
                "restart_nginx": "nginx",
                "restart_badvpn": "badvpn-udpgw",
            }[action]
            ok, title, msg = system.op_restart_service(svc)
        if ok:
            return ok_response(title, msg)
        return error_response("restart_service_failed", title, msg)

    if action == "restart_all":
        ok, title, msg = system.op_restart_all_core()
        if ok:
            return ok_response(title, msg)
        return error_response("restart_service_failed", title, msg)

    if action == "restart_xray_daemons":
        ok, title, msg = system.op_restart_xray_daemons()
        if ok:
            return ok_response(title, msg)
        return error_response("restart_service_failed", title, msg)

    if action == "restart_sshws_stack":
        ok, title, msg = system.op_restart_sshws_stack()
        if ok:
            return ok_response(title, msg)
        return error_response("restart_service_failed", title, msg)

    return error_response("unknown_action", "Maintenance", f"Action tidak dikenal: {action}")
