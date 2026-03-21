from . import menu_10_backup, menu_12_traffic, menu_6_speedtest, menu_8_maintenance
from ..utils.response import error_response


SPEEDTEST_ACTIONS = {"run", "version"}
TRAFFIC_ACTIONS = {"overview", "top_users", "search_user", "export_json"}
MAINTENANCE_ACTIONS = {
    "service_status",
    "wireproxy_status",
    "edge_gateway_status",
    "badvpn_status",
    "daemon_status",
    "sshws_status",
    "active_sshws_sessions",
    "sshws_diagnostics",
    "xray_logs",
    "nginx_logs",
    "xray_daemon_logs",
    "sshws_combined_logs",
    "restart_xray",
    "restart_nginx",
    "restart_wireproxy",
    "restart_edge_gateway",
    "restart_badvpn",
    "restart_all",
    "restart_xray_daemons",
    "restart_sshws_stack",
}
BACKUP_ACTIONS = {"list_backups", "create_backup", "restore_latest", "restore_from_upload"}


def handle(action: str, params: dict, settings) -> dict:
    if action in SPEEDTEST_ACTIONS:
        return menu_6_speedtest.handle(action, params, settings)

    if action in TRAFFIC_ACTIONS:
        return menu_12_traffic.handle(action, params, settings)

    if action in MAINTENANCE_ACTIONS:
        return menu_8_maintenance.handle(action, params, settings)

    if action in BACKUP_ACTIONS:
        return menu_10_backup.handle(action, params, settings)

    return error_response("unknown_action", "Ops", f"Action tidak dikenal: {action}")
