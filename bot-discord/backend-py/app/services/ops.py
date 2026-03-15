from ..adapters import system
from ..utils.response import error_response, ok_response
from ..utils.validators import require_param, require_positive_int_param


def handle(action: str, params: dict) -> dict:
    if action == "speedtest":
        ok, title, msg = system.op_speedtest_run()
        if ok:
            return ok_response(title, msg)
        return error_response("speedtest_run_failed", title, msg)

    if action == "service_status":
        title, msg = system.op_maintenance_status()
        return ok_response(title, msg)

    if action == "restart_service":
        ok_s, service_or_err = require_param(params, "service", "Ops - Restart Service")
        if not ok_s:
            return service_or_err
        service = str(service_or_err).strip().lower()
        if service not in {"xray", "nginx"}:
            return error_response("invalid_param", "Ops", "Service restart tidak didukung.")
        ok, title, msg = system.op_restart_service(service)
        if ok:
            return ok_response(title, msg)
        return error_response("restart_service_failed", title, msg)

    if action == "traffic_overview":
        title, msg = system.op_traffic_analytics_overview()
        return ok_response(title, msg)

    if action == "traffic_top":
        title = "Traffic Analytics - Top Users"
        ok_l, limit_or_err = require_positive_int_param(params, "limit", title, minimum=1)
        if not ok_l:
            return limit_or_err
        title_top, msg_top = system.op_traffic_analytics_top_users(int(limit_or_err))
        return ok_response(title_top, msg_top)

    if action == "traffic_search":
        ok_q, query_or_err = require_param(params, "query", "Traffic Analytics - Search")
        if not ok_q:
            return query_or_err
        title_search, msg_search = system.op_traffic_analytics_search(str(query_or_err))
        return ok_response(title_search, msg_search)

    if action == "traffic_export":
        ok_export, title, msg, download = system.op_traffic_analytics_export_json()
        if ok_export and isinstance(download, dict):
            return ok_response(title, msg, data={"download_file": download})
        return error_response("traffic_export_failed", title, msg)

    return error_response("unknown_action", "Ops", f"Action tidak dikenal: {action}")
