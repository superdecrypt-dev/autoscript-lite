import base64
import re

from ..adapters import system, system_mutations
from ..utils.response import error_response, ok_response
from ..utils.validators import (
    parse_bool_value,
    require_param,
    require_positive_float_param,
    require_positive_int_param,
    require_protocol,
    require_username,
)

USER_PROTOCOLS = tuple(system.XRAY_PROTOCOLS)
XRAY_ONLY_PROTOCOLS = tuple(system.XRAY_PROTOCOLS)


def _fmt_number(value: float) -> str:
    if value <= 0:
        return "0"
    if abs(value - round(value)) < 1e-9:
        return str(int(round(value)))
    return f"{value:.3f}".rstrip("0").rstrip(".")


def _scope_title(scope: str, label: str) -> str:
    prefix = {
        "xray": "Xray Users",
    }.get(scope, "User Management")
    return f"{prefix} - {label}" if label else prefix


def _scope_protocols(scope: str) -> tuple[str, ...]:
    if scope == "xray":
        return XRAY_ONLY_PROTOCOLS
    return USER_PROTOCOLS


def _extract_add_user_path(message: str, label: str) -> str:
    pattern = rf"(?m)^-\s*{re.escape(label)}:\s*(.+?)\s*$"
    match = re.search(pattern, str(message or ""))
    return match.group(1).strip() if match else "-"


def _decode_download_text(download_payload: dict[str, object]) -> str:
    raw = str(download_payload.get("content_base64") or "").strip()
    if not raw:
        return ""
    try:
        text = base64.b64decode(raw).decode("utf-8", errors="ignore").strip()
        text = re.sub(
            r"(ZIVPN Password\s*:\s*[^\n]+?)\s*=== STANDARD PAYLOAD ===",
            r"\1\n\n=== STANDARD PAYLOAD ===",
            text,
        )
        return text
    except Exception:
        return ""


def _mark_account_info_render(data: dict[str, object] | None = None) -> dict[str, object]:
    payload = dict(data or {})
    payload["render_mode"] = "account_info"
    return payload


def _resolve_proto(params: dict, title: str, scope: str) -> tuple[bool, str | dict]:
    protocols = _scope_protocols(scope)
    return require_protocol(params, title, allowed=set(protocols))


def handle_scoped(action: str, params: dict, settings, *, scope: str = "all") -> dict:
    protocol_scope = _scope_protocols(scope)

    if action == "list_users":
        title, msg = system.op_user_list(protocol_scope, title=_scope_title(scope, "List"))
        return ok_response(title, msg)

    if action == "search_user":
        title = _scope_title(scope, "Search")
        ok, query_or_err = require_param(params, "query", title)
        if not ok:
            return query_or_err
        title, msg = system.op_user_search(str(query_or_err), protocol_scope, title=title)
        return ok_response(title, msg)

    if action == "add_user":
        title = _scope_title(scope, "Add User")
        ok_p, proto_or_err = _resolve_proto(params, title, scope)
        if not ok_p:
            return proto_or_err
        proto = str(proto_or_err)

        ok_u, user_or_err = require_username(params, title, max_length=64)
        if not ok_u:
            return user_or_err
        ok_d, days_or_err = require_positive_int_param(params, "days", title, minimum=1)
        if not ok_d:
            return days_or_err
        ok_q, quota_or_err = require_positive_float_param(params, "quota_gb", title)
        if not ok_q:
            return quota_or_err

        ip_enabled = bool(parse_bool_value(params.get("ip_limit_enabled"), default=False))
        ip_limit = 0
        raw_ip_limit = str(params.get("ip_limit", "")).strip()
        if raw_ip_limit:
            try:
                ip_limit = int(raw_ip_limit)
            except ValueError:
                return error_response("invalid_param", title, "Parameter 'ip_limit' harus angka bulat.")
            if ip_limit < 0:
                return error_response("invalid_param", title, "Parameter 'ip_limit' tidak boleh negatif.")
            if ip_limit > 0:
                ip_enabled = True
        if ip_enabled and ip_limit <= 0:
            return error_response("invalid_param", title, "IP limit aktif tapi nilai 'ip_limit' belum valid (>0).")

        speed_enabled = bool(parse_bool_value(params.get("speed_limit_enabled"), default=False))
        speed_down = 0.0
        speed_up = 0.0
        if speed_enabled:
            ok_sd, sd_or_err = require_positive_float_param(params, "speed_down_mbit", title)
            if not ok_sd:
                return sd_or_err
            ok_su, su_or_err = require_positive_float_param(params, "speed_up_mbit", title)
            if not ok_su:
                return su_or_err
            speed_down = float(sd_or_err)
            speed_up = float(su_or_err)

        ok_add, _title_add, msg_add = system_mutations.op_user_add(
            proto=proto,
            username=str(user_or_err),
            days=int(days_or_err),
            quota_gb=float(quota_or_err),
            ip_enabled=ip_enabled,
            ip_limit=ip_limit,
            speed_enabled=speed_enabled,
            speed_down_mbit=speed_down,
            speed_up_mbit=speed_up,
            password="",
        )
        if not ok_add:
            return error_response("user_add_failed", title, msg_add)

        ip_limit_text = "OFF"
        if ip_enabled:
            ip_limit_text = f"ON ({ip_limit})"

        speed_limit_text = "OFF"
        if speed_enabled and speed_down > 0 and speed_up > 0:
            speed_limit_text = f"ON (DOWN {_fmt_number(speed_down)} Mbps | UP {_fmt_number(speed_up)} Mbps)"

        data: dict[str, object] = {
            "add_user_summary": {
                "username": str(user_or_err),
                "protocol": proto,
                "active_days": int(days_or_err),
                "quota_gb": f"{_fmt_number(float(quota_or_err))} GB",
                "ip_limit": ip_limit_text,
                "speed_limit": speed_limit_text,
            }
        }
        ok_download, download_or_err = system_mutations.op_user_account_file_download(proto, str(user_or_err))
        if ok_download and isinstance(download_or_err, dict):
            data["download_file"] = download_or_err
        else:
            data["download_error"] = str(download_or_err)

        account_path = _extract_add_user_path(msg_add, "Account")
        quota_path = _extract_add_user_path(msg_add, "Quota")
        account_text = _decode_download_text(download_or_err) if ok_download and isinstance(download_or_err, dict) else ""
        lines = [
            "Add user sukses ✅",
            "",
            "Account file:",
            f"  {account_path}",
            "Quota metadata:",
            f"  {quota_path}",
            "",
            "XRAY ACCOUNT INFO:",
        ]
        if account_text:
            lines.append(account_text)
        else:
            lines.append(f"(XRAY ACCOUNT INFO tidak ditemukan: {account_path})")
        return ok_response(title, "\n".join(lines), data=_mark_account_info_render(data))

    if action == "delete_user":
        title = _scope_title(scope, "Delete User")
        ok_p, proto_or_err = _resolve_proto(params, title, scope)
        if not ok_p:
            return proto_or_err
        ok_u, user_or_err = require_username(params, title)
        if not ok_u:
            return user_or_err
        ok_del, _title_del, msg_del = system_mutations.op_user_delete(str(proto_or_err), str(user_or_err))
        if ok_del:
            return ok_response(title, msg_del)
        return error_response("user_delete_failed", title, msg_del)

    if action == "extend_expiry":
        title = _scope_title(scope, "Set User Expiry")
        ok_p, proto_or_err = _resolve_proto(params, title, scope)
        if not ok_p:
            return proto_or_err
        ok_u, user_or_err = require_username(params, title)
        if not ok_u:
            return user_or_err
        ok_m, mode_or_err = require_param(params, "mode", title)
        if not ok_m:
            return mode_or_err
        ok_v, value_or_err = require_param(params, "value", title)
        if not ok_v:
            return value_or_err
        proto = str(proto_or_err)
        username = str(user_or_err)
        ok_ext, _title_ext, msg_ext = system_mutations.op_user_extend_expiry(
            proto=proto,
            username=username,
            mode=str(mode_or_err),
            value=str(value_or_err),
        )
        if ok_ext:
            data: dict[str, object] = {}
            ok_download, download_or_err = system_mutations.op_user_account_file_download(proto, username)
            if ok_download and isinstance(download_or_err, dict):
                data["download_file"] = download_or_err
                if _proto_requires_sensitive_output(proto):
                    data = _allow_sensitive_output(data)
        else:
            msg_ext = f"{msg_ext}\n- Warning: file account terbaru tidak bisa diunduh ({download_or_err})"
            return ok_response(title, msg_ext, data=data)
        return error_response("user_extend_failed", title, msg_ext)

    if scope == "xray" and action == "reset_credential":
        title = _scope_title(scope, "Reset UUID/Password")
        ok_p, proto_or_err = _resolve_proto(params, title, scope)
        if not ok_p:
            return proto_or_err
        proto = str(proto_or_err)
        ok_u, user_or_err = require_username(params, title)
        if not ok_u:
            return user_or_err
        username = str(user_or_err)

        ok_reset, _title_reset, msg_reset = system_mutations.op_xray_reset_credential(proto, username)
        if not ok_reset:
            return error_response("user_reset_credential_failed", title, msg_reset)

        data: dict[str, object] = {}
        ok_download, download_or_err = system_mutations.op_user_account_file_download(proto, username)
        if ok_download and isinstance(download_or_err, dict):
            data["download_file"] = download_or_err
        else:
            msg_reset = f"{msg_reset}\n- Warning: file account terbaru tidak bisa diunduh ({download_or_err})"
        return ok_response(title, msg_reset, data=data)

    if action == "account_info":
        title = _scope_title(scope, "Account Info")
        ok_p, proto_or_err = _resolve_proto(params, title, scope)
        if not ok_p:
            return proto_or_err
        ok_u, user_or_err = require_username(params, title, max_length=64)
        if not ok_u:
            return user_or_err
        _title_info, msg_info = system.op_account_info(str(proto_or_err), str(user_or_err))
        ok_download, download_or_err = system_mutations.op_user_account_file_download(str(proto_or_err), str(user_or_err))
        if not ok_download or not isinstance(download_or_err, dict):
            msg_warn = f"{msg_info}\n\n- Warning: file account tidak bisa diunduh ({download_or_err})"
            return ok_response(title, msg_warn, data=_mark_account_info_render())

        data: dict[str, object] = {
            "download_file": download_or_err,
        }
        return ok_response(title, msg_info, data=_mark_account_info_render(data))

    return error_response("unknown_action", _scope_title(scope, ""), f"Action tidak dikenal: {action}")


def handle(action: str, params: dict, settings) -> dict:
    return handle_scoped(action, params, settings, scope="all")
