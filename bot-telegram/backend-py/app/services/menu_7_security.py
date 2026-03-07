from ..adapters import system
from ..utils.validators import require_param
from ..utils.response import error_response, ok_response


def handle(action: str, params: dict, settings) -> dict:
    if action == "tls_info":
        ok, title, msg = system.op_tls_info()
        if ok:
            return ok_response(title, msg)
        return error_response("tls_info_failed", title, msg)
    if action == "tls_expiry":
        title, msg = system.op_tls_expiry()
        return ok_response(title, msg)
    if action == "fail2ban_status":
        title, msg = system.op_fail2ban_status()
        return ok_response(title, msg)
    if action == "fail2ban_jail_status":
        title, msg = system.op_fail2ban_jail_status()
        return ok_response(title, msg)
    if action == "fail2ban_banned_ips":
        title, msg = system.op_fail2ban_banned_ips()
        return ok_response(title, msg)
    if action == "unban_ip":
        if not settings.enable_dangerous_actions:
            return error_response("forbidden", "Security", "Dangerous actions dinonaktifkan via env.")
        title = "Security - Fail2ban Unban IP"
        ok_ip, ip_or_err = require_param(params, "ip", title)
        if not ok_ip:
            return ip_or_err
        ok, result_title, msg = system.op_fail2ban_unban_ip(str(ip_or_err), str(params.get("jail") or ""))
        if ok:
            return ok_response(result_title, msg)
        return error_response("fail2ban_unban_failed", result_title, msg)
    if action == "restart_fail2ban":
        if not settings.enable_dangerous_actions:
            return error_response("forbidden", "Security", "Dangerous actions dinonaktifkan via env.")
        ok, title, msg = system.op_restart_service("fail2ban")
        if ok:
            return ok_response(title, msg)
        return error_response("restart_service_failed", title, msg)
    if action == "sysctl_summary":
        title, msg = system.op_sysctl_summary()
        return ok_response(title, msg)
    if action == "hardening_bbr":
        title, msg = system.op_hardening_bbr()
        return ok_response(title, msg)
    if action == "hardening_swap":
        title, msg = system.op_hardening_swap()
        return ok_response(title, msg)
    if action == "hardening_ulimit":
        title, msg = system.op_hardening_ulimit()
        return ok_response(title, msg)
    if action == "hardening_chrony":
        title, msg = system.op_hardening_chrony()
        return ok_response(title, msg)
    if action == "security_overview":
        title, msg = system.op_security_overview()
        return ok_response(title, msg)
    return error_response("unknown_action", "Security", f"Action tidak dikenal: {action}")
