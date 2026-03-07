from ..adapters import system
from ..utils.response import error_response, ok_response


def handle(action: str, params: dict, settings) -> dict:
    if action == "service_status":
        title, msg = system.op_maintenance_status()
        return ok_response(title, msg)

    if action == "wireproxy_status":
        title, msg = system.op_wireproxy_status()
        return ok_response(title, msg)

    if action == "daemon_status":
        title, msg = system.op_daemon_status()
        return ok_response(title, msg)

    if action == "sshws_status":
        title, msg = system.op_sshws_status()
        return ok_response(title, msg)

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

    if action in {"restart_xray", "restart_nginx", "restart_wireproxy"}:
        if not settings.enable_dangerous_actions:
            return error_response("forbidden", "Maintenance", "Dangerous actions dinonaktifkan via env.")
        svc = {
            "restart_xray": "xray",
            "restart_nginx": "nginx",
            "restart_wireproxy": "wireproxy",
        }[action]
        ok, title, msg = system.op_restart_service(svc)
        if ok:
            return ok_response(title, msg)
        return error_response("restart_service_failed", title, msg)

    if action == "restart_all":
        if not settings.enable_dangerous_actions:
            return error_response("forbidden", "Maintenance", "Dangerous actions dinonaktifkan via env.")
        ok, title, msg = system.op_restart_all_core()
        if ok:
            return ok_response(title, msg)
        return error_response("restart_service_failed", title, msg)

    if action == "restart_xray_daemons":
        if not settings.enable_dangerous_actions:
            return error_response("forbidden", "Maintenance", "Dangerous actions dinonaktifkan via env.")
        ok, title, msg = system.op_restart_xray_daemons()
        if ok:
            return ok_response(title, msg)
        return error_response("restart_service_failed", title, msg)

    if action == "restart_sshws_stack":
        if not settings.enable_dangerous_actions:
            return error_response("forbidden", "Maintenance", "Dangerous actions dinonaktifkan via env.")
        ok, title, msg = system.op_restart_sshws_stack()
        if ok:
            return ok_response(title, msg)
        return error_response("restart_service_failed", title, msg)

    return error_response("unknown_action", "Maintenance", f"Action tidak dikenal: {action}")
