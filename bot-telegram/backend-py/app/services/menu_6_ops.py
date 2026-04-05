from . import menu_10_backup, menu_12_traffic, menu_6_speedtest, menu_8_maintenance
from ..utils.response import error_response


SPEEDTEST_ACTIONS = {"run", "version"}
TRAFFIC_ACTIONS = {"overview", "top_users", "search_user", "export_json"}
MAINTENANCE_ACTIONS = {
    "service_status",
    "wireproxy_status",
    "edge_gateway_status",
    "daemon_status",
    "xray_logs",
    "nginx_logs",
    "xray_daemon_logs",
    "restart_xray",
    "restart_nginx",
    "restart_wireproxy",
    "restart_edge_gateway",
    "restart_all",
    "restart_xray_daemons",
}
BACKUP_ACTIONS = {
    "list_backups",
    "create_backup",
    "restore_latest",
    "restore_from_upload",
    "gdrive_setup_help",
    "gdrive_status",
    "gdrive_create_upload",
    "gdrive_list_backups",
    "gdrive_restore_latest",
    "gdrive_quick_setup",
    "gdrive_show_oauth_steps",
    "gdrive_paste_oauth_token",
    "gdrive_use_existing_remote",
    "gdrive_manual_rclone_config",
    "r2_setup_help",
    "r2_status",
    "r2_create_upload",
    "r2_list_backups",
    "r2_restore_latest",
    "r2_quick_setup",
    "r2_manual_rclone_config",
}


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
