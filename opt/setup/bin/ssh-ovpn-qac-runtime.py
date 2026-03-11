#!/usr/bin/env python3
import argparse
import datetime
import fcntl
import ipaddress
import json
import os
import pathlib
import pwd
import tempfile
import time


UNIFIED_ROOT = pathlib.Path("/opt/quota/ssh-ovpn")
UNIFIED_LOCK_ROOT = pathlib.Path("/run/autoscript/locks/ssh-ovpn-qac")
OVPN_CLIENTS_ROOT = pathlib.Path("/etc/openvpn/clients")
OVPN_CCD_ROOT = pathlib.Path("/etc/openvpn/server/ccd")
OVPN_STATUS_FILE = pathlib.Path("/var/log/openvpn/ovpn-tcp-status.log")


def norm_user(value):
    text = str(value or "").strip()
    if text.endswith("@ssh"):
        text = text[:-4]
    if "@" in text:
        text = text.split("@", 1)[0]
    return text


def valid_user(value):
    text = norm_user(value)
    if not text or len(text) > 32:
        return False
    for ch in text:
        if ch.isalnum() or ch in "._-":
            continue
        return False
    return True


def load_json(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            data = json.load(handle)
        if isinstance(data, dict):
            return data
    except Exception:
        pass
    return {}


def save_json_atomic(path, payload):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".tmp.", suffix=".json", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
    finally:
        try:
            if os.path.exists(tmp):
                os.remove(tmp)
        except Exception:
            pass


def to_int(value, default=0):
    try:
        if value is None:
            return default
        if isinstance(value, bool):
            return int(value)
        if isinstance(value, (int, float)):
            return int(value)
        text = str(value).strip()
        if not text:
            return default
        return int(float(text))
    except Exception:
        return default


def to_float(value, default=0.0):
    try:
        if value is None:
            return default
        if isinstance(value, bool):
            return float(int(value))
        if isinstance(value, (int, float)):
            return float(value)
        text = str(value).strip()
        if not text:
            return default
        return float(text)
    except Exception:
        return default


def to_bool(value, default=False):
    if value is None:
        return bool(default)
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return bool(value)
    text = str(value).strip().lower()
    if not text:
        return bool(default)
    return text in ("1", "true", "yes", "on", "y")


def norm_date(value):
    text = str(value or "").strip()
    if not text or text == "-":
        return ""
    return text[:10]


def normalize_ip(value):
    text = str(value or "").strip()
    if not text:
        return ""
    if text.startswith("[") and text.endswith("]"):
        text = text[1:-1].strip()
    try:
        return str(ipaddress.ip_address(text))
    except Exception:
        return ""


def normalize_real_ip(value):
    text = str(value or "").strip()
    if not text:
        return ""
    if text.startswith("["):
        host = text.split("]", 1)[0].strip("[]")
        return normalize_ip(host)
    if ":" in text:
        host, _, _port = text.rpartition(":")
        if host:
            parsed = normalize_ip(host)
            if parsed:
                return parsed
    return normalize_ip(text)


def normalize_ip_list(value):
    out = []
    seen = set()
    if not isinstance(value, list):
        return out
    for raw in value:
        ip = normalize_ip(raw)
        if not ip or ip in seen:
            continue
        seen.add(ip)
        out.append(ip)
    return sorted(out)


def normalize_session_rows(value, protocol):
    rows = []
    seen = set()
    if not isinstance(value, list):
        return rows
    for raw in value:
        if not isinstance(raw, dict):
            continue
        client_ip = normalize_ip(raw.get("client_ip") or raw.get("real_ip"))
        if not client_ip:
            continue
        row = {
            "protocol": str(protocol or raw.get("protocol") or "-").strip() or "-",
            "surface": str(raw.get("surface") or raw.get("transport") or "-").strip() or "-",
            "client_ip": client_ip,
            "detail": str(raw.get("detail") or raw.get("virtual_ip") or raw.get("client_cn") or "-").strip() or "-",
            "updated_at_unix": max(0, to_int(raw.get("updated_at_unix"), to_int(raw.get("updated_at"), 0))),
        }
        row_key = (row["protocol"], row["surface"], row["client_ip"], row["detail"])
        if row_key in seen:
            continue
        seen.add(row_key)
        rows.append(row)
    rows.sort(key=lambda item: (item["protocol"], item["surface"], item["client_ip"], item["detail"]))
    return rows


def user_exists(username):
    try:
        pwd.getpwnam(username)
        return True
    except KeyError:
        return False
    except Exception:
        return False


def date_is_active(value):
    text = norm_date(value)
    if not text or text == "-":
        return True
    try:
        expiry = datetime.datetime.strptime(text, "%Y-%m-%d").date()
    except Exception:
        return True
    return expiry >= datetime.date.today()


def unified_path(username):
    return UNIFIED_ROOT / f"{username}.json"


def unified_lock_path(username):
    return UNIFIED_LOCK_ROOT / f"{username}.lock"


def ovpn_state_path(username):
    return OVPN_CLIENTS_ROOT / f"{username}.json"


def current_ccd_path(client_cn):
    text = str(client_cn or "").strip()
    if not text:
        return None
    return OVPN_CCD_ROOT / text


def ensure_unified_dirs():
    UNIFIED_ROOT.mkdir(parents=True, exist_ok=True)
    UNIFIED_LOCK_ROOT.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(UNIFIED_ROOT, 0o700)
    except Exception:
        pass
    try:
        os.chmod(UNIFIED_LOCK_ROOT, 0o700)
    except Exception:
        pass


def ensure_state(username):
    username = norm_user(username)
    current = load_json(unified_path(username))
    ovpn = load_json(ovpn_state_path(username))

    current_policy = current.get("policy") if isinstance(current.get("policy"), dict) else {}
    current_runtime = current.get("runtime") if isinstance(current.get("runtime"), dict) else {}
    current_derived = current.get("derived") if isinstance(current.get("derived"), dict) else {}
    current_meta = current.get("meta") if isinstance(current.get("meta"), dict) else {}
    current_status = current.get("status") if isinstance(current.get("status"), dict) else {}

    client_cn = str(ovpn.get("client_cn") or "").strip()
    ccd_path = current_ccd_path(client_cn)
    ovpn_access = bool(ccd_path and ccd_path.exists()) if ovpn else None

    created_at = (
        norm_date(current.get("created_at"))
        or norm_date(current_meta.get("created_at"))
        or norm_date(ovpn.get("created_at"))
        or time.strftime("%Y-%m-%d", time.gmtime())
    )
    expired_at = (
        norm_date(current_policy.get("expired_at"))
        or norm_date(current.get("expired_at"))
        or norm_date(ovpn.get("expired_at"))
        or "-"
    )

    sshws_token = str(
        current.get("sshws_token")
        or current_meta.get("sshws_token")
        or ""
    ).strip().lower()

    legacy_quota_limit = max(
        0,
        to_int(
            current_policy.get("quota_limit_bytes"),
            to_int(current_policy.get("quota_limit_bytes"), 0),
        ),
    )
    quota_limit_ssh = max(0, to_int(current_policy.get("quota_limit_ssh_bytes"), legacy_quota_limit))
    quota_limit_ovpn = max(0, to_int(current_policy.get("quota_limit_ovpn_bytes"), legacy_quota_limit))
    quota_unit = str(current_policy.get("quota_unit") or "binary").strip().lower()
    if quota_unit not in ("binary", "decimal"):
        quota_unit = "binary"

    ip_limit_enabled = to_bool(current_policy.get("ip_limit_enabled"))
    ip_limit = max(0, to_int(current_policy.get("ip_limit"), 0))
    speed_limit_enabled = to_bool(current_policy.get("speed_limit_enabled"))
    speed_down = max(0.0, to_float(current_policy.get("speed_down_mbit"), 0.0))
    speed_up = max(0.0, to_float(current_policy.get("speed_up_mbit"), 0.0))

    if "access_enabled" in current_policy:
        access_enabled = to_bool(current_policy.get("access_enabled"))
    elif ovpn_access is not None:
        access_enabled = bool(ovpn_access)
    else:
        access_enabled = True

    compat_quota_used_ssh = max(0, to_int(current.get("quota_used"), 0))
    runtime = {
        "quota_used_ssh_bytes": max(
            0,
            max(
                to_int(current_runtime.get("quota_used_ssh_bytes"), 0),
                compat_quota_used_ssh,
            ),
        ),
        "quota_used_ovpn_bytes": max(0, to_int(current_runtime.get("quota_used_ovpn_bytes"), 0)),
        "active_session_ssh": max(0, to_int(current_runtime.get("active_session_ssh"), 0)),
        "active_session_ovpn": max(0, to_int(current_runtime.get("active_session_ovpn"), 0)),
        "last_seen_ssh_unix": max(0, to_int(current_runtime.get("last_seen_ssh_unix"), 0)),
        "last_seen_ovpn_unix": max(0, to_int(current_runtime.get("last_seen_ovpn_unix"), 0)),
        "distinct_ips_ssh": normalize_ip_list(current_runtime.get("distinct_ips_ssh")),
        "distinct_ips_ovpn": normalize_ip_list(current_runtime.get("distinct_ips_ovpn")),
        "sessions_ssh": normalize_session_rows(current_runtime.get("sessions_ssh"), "ssh"),
        "sessions_ovpn": normalize_session_rows(current_runtime.get("sessions_ovpn"), "ovpn"),
    }

    distinct_ips_total = sorted({*runtime["distinct_ips_ssh"], *runtime["distinct_ips_ovpn"]})
    speed_limit_active_ssh = runtime["active_session_ssh"] if speed_limit_enabled and runtime["active_session_ssh"] > 0 else 0
    speed_limit_active_ovpn = runtime["active_session_ovpn"] if speed_limit_enabled and runtime["active_session_ovpn"] > 0 else 0

    derived = {
        "quota_used_total_bytes": max(
            0,
            to_int(
                current_derived.get("quota_used_total_bytes"),
                runtime["quota_used_ssh_bytes"] + runtime["quota_used_ovpn_bytes"],
            ),
        ),
        "active_session_total": max(
            0,
            to_int(
                current_derived.get("active_session_total"),
                runtime["active_session_ssh"] + runtime["active_session_ovpn"],
            ),
        ),
        "distinct_ip_total": max(
            0,
            to_int(current_derived.get("distinct_ip_total"), len(distinct_ips_total)),
        ),
        "distinct_ips_total": distinct_ips_total,
        "ip_limit_metric": max(
            0,
            to_int(
                current_derived.get("ip_limit_metric"),
                len(distinct_ips_total) if distinct_ips_total else runtime["active_session_ssh"] + runtime["active_session_ovpn"],
            ),
        ),
        "speed_limit_active_ssh": max(0, to_int(current_derived.get("speed_limit_active_ssh"), speed_limit_active_ssh)),
        "speed_limit_active_ovpn": max(0, to_int(current_derived.get("speed_limit_active_ovpn"), speed_limit_active_ovpn)),
        "speed_limit_active_total": max(
            0,
            to_int(current_derived.get("speed_limit_active_total"), speed_limit_active_ssh + speed_limit_active_ovpn),
        ),
        "quota_exhausted": to_bool(current_derived.get("quota_exhausted")),
        "quota_exhausted_ssh": to_bool(current_derived.get("quota_exhausted_ssh")),
        "quota_exhausted_ovpn": to_bool(current_derived.get("quota_exhausted_ovpn")),
        "ip_limit_locked": to_bool(current_derived.get("ip_limit_locked")),
        "last_reason": str(current_derived.get("last_reason") or "-").strip() or "-",
        "last_reason_ssh": str(current_derived.get("last_reason_ssh") or current_derived.get("last_reason") or "-").strip() or "-",
        "last_reason_ovpn": str(current_derived.get("last_reason_ovpn") or current_derived.get("last_reason") or "-").strip() or "-",
        "access_effective": to_bool(current_derived.get("access_effective")),
        "access_effective_ssh": to_bool(current_derived.get("access_effective_ssh")),
        "access_effective_ovpn": to_bool(current_derived.get("access_effective_ovpn")),
    }

    meta = dict(current_meta)
    meta.update(
        {
            "created_at": created_at,
            "updated_at_unix": int(time.time()),
            "migrated_from_legacy": bool(current_meta.get("migrated_from_legacy")),
            "ssh_present": bool(user_exists(username) if current_meta.get("ssh_present") is not False else False),
            "ovpn_present": bool(ovpn),
            "sshws_token": sshws_token,
        }
    )

    payload = {
        "version": 1,
        "managed_by": "autoscript-manage",
        "protocol": "ssh-ovpn",
        "username": username,
        "created_at": created_at,
        "expired_at": expired_at,
        "sshws_token": sshws_token,
        "quota_limit": quota_limit_ssh,
        "quota_unit": quota_unit,
        "quota_used": runtime["quota_used_ssh_bytes"],
        "status": {
            "manual_block": bool(to_bool(current_status.get("manual_block"))),
            "quota_exhausted": bool(derived.get("quota_exhausted")),
            "ip_limit_enabled": bool(ip_limit_enabled),
            "ip_limit": ip_limit,
            "ip_limit_locked": bool(derived.get("ip_limit_locked")),
            "speed_limit_enabled": bool(speed_limit_enabled),
            "speed_down_mbit": speed_down,
            "speed_up_mbit": speed_up,
            "lock_reason": str(derived.get("last_reason") or "-").strip() or "-",
            "account_locked": bool(to_bool(current_status.get("account_locked"))),
            "lock_owner": str(current_status.get("lock_owner") or "").strip(),
            "lock_shell_restore": str(current_status.get("lock_shell_restore") or "").strip(),
        },
        "policy": {
            "quota_limit_bytes": quota_limit_ssh,
            "quota_limit_ssh_bytes": quota_limit_ssh,
            "quota_limit_ovpn_bytes": quota_limit_ovpn,
            "quota_unit": quota_unit,
            "expired_at": expired_at,
            "access_enabled": bool(access_enabled),
            "ip_limit_enabled": bool(ip_limit_enabled),
            "ip_limit": ip_limit,
            "speed_limit_enabled": bool(speed_limit_enabled),
            "speed_down_mbit": speed_down,
            "speed_up_mbit": speed_up,
        },
        "runtime": runtime,
        "derived": derived,
        "meta": meta,
    }
    evaluate_policy(payload)
    return payload


def update_derived(payload):
    runtime = payload.get("runtime") if isinstance(payload.get("runtime"), dict) else {}
    derived = payload.get("derived") if isinstance(payload.get("derived"), dict) else {}
    distinct_ips_ssh = normalize_ip_list(runtime.get("distinct_ips_ssh"))
    distinct_ips_ovpn = normalize_ip_list(runtime.get("distinct_ips_ovpn"))
    distinct_ips_total = sorted({*distinct_ips_ssh, *distinct_ips_ovpn})
    speed_limit_enabled = False
    policy = payload.get("policy") if isinstance(payload.get("policy"), dict) else {}
    if isinstance(policy, dict):
        speed_limit_enabled = to_bool(policy.get("speed_limit_enabled"))
    derived["quota_used_total_bytes"] = max(
        0,
        to_int(runtime.get("quota_used_ssh_bytes"), 0) + to_int(runtime.get("quota_used_ovpn_bytes"), 0),
    )
    derived["active_session_total"] = max(
        0,
        to_int(runtime.get("active_session_ssh"), 0) + to_int(runtime.get("active_session_ovpn"), 0),
    )
    derived["distinct_ip_total"] = len(distinct_ips_total)
    derived["distinct_ips_total"] = distinct_ips_total
    derived["ip_limit_metric"] = len(distinct_ips_total) if distinct_ips_total else max(0, to_int(derived.get("active_session_total"), 0))
    derived["speed_limit_active_ssh"] = max(
        0,
        to_int(runtime.get("active_session_ssh"), 0) if speed_limit_enabled else 0,
    )
    derived["speed_limit_active_ovpn"] = max(
        0,
        to_int(runtime.get("active_session_ovpn"), 0) if speed_limit_enabled else 0,
    )
    derived["speed_limit_active_total"] = max(
        0,
        to_int(derived.get("speed_limit_active_ssh"), 0) + to_int(derived.get("speed_limit_active_ovpn"), 0),
    )
    if not str(derived.get("last_reason") or "").strip():
        derived["last_reason"] = "-"
    payload["derived"] = derived


def evaluate_policy(payload):
    if not isinstance(payload, dict):
        return
    policy = payload.get("policy") if isinstance(payload.get("policy"), dict) else {}
    derived = payload.get("derived") if isinstance(payload.get("derived"), dict) else {}

    quota_limit_ssh = max(0, to_int(policy.get("quota_limit_ssh_bytes"), to_int(policy.get("quota_limit_bytes"), 0)))
    quota_limit_ovpn = max(0, to_int(policy.get("quota_limit_ovpn_bytes"), to_int(policy.get("quota_limit_bytes"), 0)))
    quota_used_total = max(0, to_int(derived.get("quota_used_total_bytes"), 0))
    quota_used_ssh = max(
        0,
        max(
            to_int(runtime.get("quota_used_ssh_bytes"), 0),
            to_int(payload.get("quota_used"), 0),
        ),
    ) if isinstance((runtime := payload.get("runtime")), dict) else max(0, to_int(payload.get("quota_used"), 0))
    quota_used_ovpn = max(0, to_int(runtime.get("quota_used_ovpn_bytes"), 0)) if isinstance(runtime, dict) else 0
    ip_limit_enabled = to_bool(policy.get("ip_limit_enabled"))
    ip_limit = max(0, to_int(policy.get("ip_limit"), 0))
    active_total = max(0, to_int(derived.get("active_session_total"), 0))
    distinct_ip_total = max(0, to_int(derived.get("distinct_ip_total"), 0))
    ip_limit_metric = distinct_ip_total if distinct_ip_total > 0 else active_total
    access_requested = to_bool(policy.get("access_enabled"), True)
    expired_active = date_is_active(policy.get("expired_at"))
    status = payload.get("status") if isinstance(payload.get("status"), dict) else {}
    manual_block = to_bool(status.get("manual_block"))

    quota_exhausted_ssh = bool(quota_limit_ssh > 0 and quota_used_ssh >= quota_limit_ssh)
    quota_exhausted_ovpn = bool(quota_limit_ovpn > 0 and quota_used_ovpn >= quota_limit_ovpn)
    ip_limit_locked = bool(ip_limit_enabled and ip_limit > 0 and ip_limit_metric > ip_limit)

    if manual_block:
        last_reason_ssh = "manual"
        last_reason_ovpn = "manual"
    elif not access_requested:
        last_reason_ssh = "access_off"
        last_reason_ovpn = "access_off"
    elif not expired_active:
        last_reason_ssh = "expired"
        last_reason_ovpn = "expired"
    elif ip_limit_locked:
        last_reason_ssh = "ip_limit"
        last_reason_ovpn = "ip_limit"
    else:
        last_reason_ssh = "quota_ssh" if quota_exhausted_ssh else "-"
        last_reason_ovpn = "quota_ovpn" if quota_exhausted_ovpn else "-"

    if last_reason_ssh not in ("", "-"):
        last_reason = last_reason_ssh
    elif last_reason_ovpn not in ("", "-"):
        last_reason = last_reason_ovpn
    else:
        last_reason = "-"

    shared_access = bool(access_requested and expired_active and not ip_limit_locked and not manual_block)
    derived["quota_exhausted"] = quota_exhausted_ssh
    derived["quota_exhausted_ssh"] = quota_exhausted_ssh
    derived["quota_exhausted_ovpn"] = quota_exhausted_ovpn
    derived["ip_limit_locked"] = ip_limit_locked
    derived["ip_limit_metric"] = ip_limit_metric
    derived["last_reason"] = last_reason
    derived["last_reason_ssh"] = last_reason_ssh
    derived["last_reason_ovpn"] = last_reason_ovpn
    derived["access_effective"] = bool(shared_access and not quota_exhausted_ssh)
    derived["access_effective_ssh"] = bool(shared_access and not quota_exhausted_ssh)
    derived["access_effective_ovpn"] = bool(shared_access and not quota_exhausted_ovpn)
    payload["derived"] = derived


def sync_compat_fields(payload):
    if not isinstance(payload, dict):
        return
    policy = payload.get("policy") if isinstance(payload.get("policy"), dict) else {}
    runtime = payload.get("runtime") if isinstance(payload.get("runtime"), dict) else {}
    derived = payload.get("derived") if isinstance(payload.get("derived"), dict) else {}
    meta = payload.get("meta") if isinstance(payload.get("meta"), dict) else {}
    status = payload.get("status") if isinstance(payload.get("status"), dict) else {}

    quota_limit_ssh = max(0, to_int(policy.get("quota_limit_ssh_bytes"), to_int(policy.get("quota_limit_bytes"), to_int(payload.get("quota_limit"), 0))))
    quota_limit_ovpn = max(0, to_int(policy.get("quota_limit_ovpn_bytes"), to_int(policy.get("quota_limit_bytes"), quota_limit_ssh)))
    quota_unit = str(policy.get("quota_unit") or payload.get("quota_unit") or "binary").strip().lower()
    if quota_unit not in ("binary", "decimal"):
        quota_unit = "binary"
    expired_at = norm_date(policy.get("expired_at") or payload.get("expired_at")) or "-"
    created_at = norm_date(meta.get("created_at") or payload.get("created_at")) or time.strftime("%Y-%m-%d", time.gmtime())
    sshws_token = str(payload.get("sshws_token") or meta.get("sshws_token") or "").strip().lower()
    quota_used_ssh = max(
        0,
        max(
            to_int(runtime.get("quota_used_ssh_bytes"), 0),
            to_int(payload.get("quota_used"), 0),
        ),
    )
    quota_used_ovpn = max(0, to_int(runtime.get("quota_used_ovpn_bytes"), 0))
    quota_used_total = max(0, to_int(derived.get("quota_used_total_bytes"), quota_used_ssh + quota_used_ovpn))

    status["quota_exhausted"] = to_bool(derived.get("quota_exhausted_ssh"))
    status["ip_limit_enabled"] = to_bool(policy.get("ip_limit_enabled"))
    status["ip_limit"] = max(0, to_int(policy.get("ip_limit"), 0))
    status["ip_limit_locked"] = to_bool(derived.get("ip_limit_locked"))
    status["speed_limit_enabled"] = to_bool(policy.get("speed_limit_enabled"))
    status["speed_down_mbit"] = max(0.0, to_float(policy.get("speed_down_mbit"), 0.0))
    status["speed_up_mbit"] = max(0.0, to_float(policy.get("speed_up_mbit"), 0.0))
    status["lock_reason"] = str(derived.get("last_reason") or status.get("lock_reason") or "-").strip() or "-"
    status["account_locked"] = to_bool(status.get("account_locked"))
    status["lock_owner"] = str(status.get("lock_owner") or "").strip()
    status["lock_shell_restore"] = str(status.get("lock_shell_restore") or "").strip()

    payload["managed_by"] = str(payload.get("managed_by") or "autoscript-manage").strip() or "autoscript-manage"
    payload["protocol"] = str(payload.get("protocol") or "ssh-ovpn").strip() or "ssh-ovpn"
    payload["created_at"] = created_at
    payload["expired_at"] = expired_at
    payload["sshws_token"] = sshws_token
    payload["quota_limit"] = quota_limit_ssh
    payload["quota_unit"] = quota_unit
    payload["quota_used"] = quota_used_ssh
    meta["created_at"] = created_at
    meta["sshws_token"] = sshws_token
    payload["meta"] = meta
    payload["status"] = status


def write_user_state(username, mutator):
    username = norm_user(username)
    if not valid_user(username):
        return 1
    state_path = unified_path(username)
    if not state_path.is_file():
        return 0
    ensure_unified_dirs()
    lock_path = unified_lock_path(username)
    with open(lock_path, "a+", encoding="utf-8") as lock_handle:
        fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX)
        payload = ensure_state(username)
        mutator(payload)
        update_derived(payload)
        evaluate_policy(payload)
        sync_compat_fields(payload)
        meta = payload.get("meta") if isinstance(payload.get("meta"), dict) else {}
        meta["updated_at_unix"] = int(time.time())
        payload["meta"] = meta
        save_json_atomic(unified_path(username), payload)
        fcntl.flock(lock_handle.fileno(), fcntl.LOCK_UN)
    return 0


def cmd_ssh_sync(args):
    username = norm_user(args.user)
    if not valid_user(username):
        return 1

    def mutate(payload):
        runtime = payload.get("runtime") if isinstance(payload.get("runtime"), dict) else {}
        derived = payload.get("derived") if isinstance(payload.get("derived"), dict) else {}
        if args.quota_used_ssh is not None:
            runtime["quota_used_ssh_bytes"] = max(0, to_int(args.quota_used_ssh, 0))
        if args.active_session_ssh is not None:
            runtime["active_session_ssh"] = max(0, to_int(args.active_session_ssh, 0))
        if args.last_seen_ssh is not None:
            runtime["last_seen_ssh_unix"] = max(0, to_int(args.last_seen_ssh, 0))
        if args.distinct_ips_ssh_json is not None:
            try:
                runtime["distinct_ips_ssh"] = normalize_ip_list(json.loads(args.distinct_ips_ssh_json))
            except Exception:
                runtime["distinct_ips_ssh"] = []
        if args.sessions_ssh_json is not None:
            try:
                runtime["sessions_ssh"] = normalize_session_rows(json.loads(args.sessions_ssh_json), "ssh")
            except Exception:
                runtime["sessions_ssh"] = []
        if args.quota_exhausted is not None:
            derived["quota_exhausted"] = to_bool(args.quota_exhausted)
        if args.ip_limit_locked is not None:
            derived["ip_limit_locked"] = to_bool(args.ip_limit_locked)
        if args.last_reason is not None:
            text = str(args.last_reason or "-").strip()
            derived["last_reason"] = text or "-"
        payload["runtime"] = runtime
        payload["derived"] = derived

    return write_user_state(username, mutate)


def parse_ovpn_routing(status_path):
    routes = {}
    try:
        lines = pathlib.Path(status_path).read_text(encoding="utf-8", errors="ignore").splitlines()
    except Exception:
        return routes

    mode = ""
    for raw in lines:
        line = raw.strip()
        if not line:
            continue
        if line == "ROUTING TABLE":
            mode = "v1"
            continue
        if line.startswith("HEADER,ROUTING_TABLE,"):
            mode = "v2"
            continue
        if line == "GLOBAL STATS" or line.startswith("GLOBAL_STATS,") or line == "END":
            if mode:
                break
        if mode == "v1":
            if line.startswith("Virtual Address,"):
                continue
            parts = [part.strip() for part in line.split(",")]
            if len(parts) < 2:
                continue
            virtual_ip, common_name = parts[:2]
        elif mode == "v2":
            if not line.startswith("ROUTING_TABLE,"):
                continue
            parts = [part.strip() for part in line.split(",")]
            if len(parts) < 3:
                continue
            _kind, virtual_ip, common_name = parts[:3]
        else:
            continue
        common_name = str(common_name or "").strip()
        virtual_ip = normalize_ip(virtual_ip)
        if common_name and virtual_ip:
            routes[common_name] = virtual_ip
    return routes


def parse_ovpn_status(status_path):
    sessions = []
    route_map = parse_ovpn_routing(status_path)
    try:
        lines = pathlib.Path(status_path).read_text(encoding="utf-8", errors="ignore").splitlines()
    except Exception:
        return sessions

    in_client_list = False
    client_list_v2 = False
    for raw in lines:
        line = raw.strip()
        if not line:
            continue
        if line == "OpenVPN CLIENT LIST":
            in_client_list = True
            continue
        if line.startswith("HEADER,CLIENT_LIST,"):
            client_list_v2 = True
            continue
        if not in_client_list:
            if not client_list_v2:
                continue
        if client_list_v2:
            if line.startswith("ROUTING_TABLE,") or line.startswith("HEADER,ROUTING_TABLE,") or line.startswith("GLOBAL_STATS,") or line == "END":
                break
            if not line.startswith("CLIENT_LIST,"):
                continue
            parts = [part.strip() for part in line.split(",")]
            if len(parts) < 10:
                continue
            _, cn, real_addr, _virt4, _virt6, bytes_recv, bytes_sent, connected_since, connected_since_unix, *_rest = parts
            connected_key = connected_since_unix or connected_since
        else:
            if line.startswith("Common Name,"):
                continue
            if line.startswith("ROUTING TABLE"):
                break
            parts = [part.strip() for part in line.split(",")]
            if len(parts) < 5:
                continue
            cn, real_addr, bytes_recv, bytes_sent, connected_since = parts[:5]
            connected_key = connected_since
        cn = str(cn or "").strip()
        if not cn or cn.lower() in {"updated", "common name"}:
            continue
        sessions.append(
            {
                "client_cn": cn,
                "real_addr": str(real_addr or "").strip(),
                "real_ip": normalize_real_ip(real_addr),
                "virtual_ip": route_map.get(cn, ""),
                "bytes_total": max(0, to_int(bytes_recv, 0)) + max(0, to_int(bytes_sent, 0)),
                "connected_since": str(connected_key or "").strip(),
            }
        )
    return sessions


def build_ovpn_client_map(clients_dir):
    mapping = {}
    root = pathlib.Path(clients_dir)
    if not root.is_dir():
        return mapping
    for path in sorted(root.glob("*.json"), key=lambda item: item.name.lower()):
        if path.name.startswith("."):
            continue
        data = load_json(path)
        username = norm_user(data.get("client_name") or path.stem)
        client_cn = str(data.get("client_cn") or username).strip()
        if not valid_user(username) or not client_cn:
            continue
        mapping[username] = {"client_cn": client_cn, "path": path}
    return mapping


def ovpn_access_allowed(username):
    payload = load_json(unified_path(username))
    if isinstance(payload, dict) and payload:
        derived = payload.get("derived") if isinstance(payload.get("derived"), dict) else {}
        if "access_effective_ovpn" in derived:
            return to_bool(derived.get("access_effective_ovpn"), True)
        if "access_effective" in derived:
            return to_bool(derived.get("access_effective"), True)
        policy = payload.get("policy") if isinstance(payload.get("policy"), dict) else {}
        return to_bool(policy.get("access_enabled"), True) and date_is_active(policy.get("expired_at"))
    return False


def cmd_ovpn_sync_access(args):
    clients_dir = pathlib.Path(args.clients_dir)
    ccd_dir = pathlib.Path(args.ccd_dir)
    ccd_dir.mkdir(parents=True, exist_ok=True)
    client_map = build_ovpn_client_map(clients_dir)
    for username, meta in client_map.items():
        client_cn = str(meta.get("client_cn") or "").strip()
        if not client_cn:
            continue
        ccd_path = ccd_dir / client_cn
        if ovpn_access_allowed(username):
            if not ccd_path.exists():
                ccd_path.write_text("# autoscript openvpn client\npush-reset\n", encoding="utf-8")
                try:
                    os.chmod(ccd_path, 0o644)
                except Exception:
                    pass
        else:
            try:
                ccd_path.unlink()
            except FileNotFoundError:
                pass
            except Exception:
                return 1
    return 0


def cmd_ovpn_sync_status(args):
    status_file = pathlib.Path(args.status_file)
    clients_dir = pathlib.Path(args.clients_dir)
    ccd_dir = pathlib.Path(args.ccd_dir)
    ensure_unified_dirs()

    client_map = build_ovpn_client_map(clients_dir)
    session_rows = parse_ovpn_status(status_file)
    sessions_by_user = {username: [] for username in client_map}
    cn_to_user = {}
    for username, meta in client_map.items():
        cn_to_user[str(meta.get("client_cn") or "").strip()] = username
    for row in session_rows:
        username = cn_to_user.get(str(row.get("client_cn") or "").strip())
        if not username:
            continue
        sessions_by_user.setdefault(username, []).append(row)

    now_unix = int(time.time())
    for username, meta in client_map.items():
        def mutate(payload, username=username, meta=meta):
            runtime = payload.get("runtime") if isinstance(payload.get("runtime"), dict) else {}
            meta_block = payload.get("meta") if isinstance(payload.get("meta"), dict) else {}
            snapshots = meta_block.get("ovpn_runtime_snapshots")
            if not isinstance(snapshots, dict):
                snapshots = {}

            delta_total = 0
            next_snapshots = {}
            active = 0
            distinct_ips = set()
            session_rows = []
            for row in sessions_by_user.get(username, []):
                key = "|".join(
                    [
                        str(row.get("client_cn") or ""),
                        str(row.get("real_addr") or ""),
                        str(row.get("connected_since") or ""),
                    ]
                )
                total_bytes = max(0, to_int(row.get("bytes_total"), 0))
                prev = snapshots.get(key) if isinstance(snapshots.get(key), dict) else {}
                prev_bytes = max(0, to_int(prev.get("bytes_total"), 0))
                delta_total += max(0, total_bytes - prev_bytes)
                next_snapshots[key] = {
                    "bytes_total": total_bytes,
                    "updated_at_unix": now_unix,
                }
                active += 1
                real_ip = normalize_ip(row.get("real_ip"))
                if real_ip:
                    distinct_ips.add(real_ip)
                session_rows.append(
                    {
                        "protocol": "ovpn",
                        "surface": "ovpn-tcp",
                        "client_ip": real_ip,
                        "detail": str(row.get("virtual_ip") or row.get("client_cn") or "-").strip() or "-",
                        "updated_at_unix": now_unix,
                    }
                )

            runtime["quota_used_ovpn_bytes"] = max(0, to_int(runtime.get("quota_used_ovpn_bytes"), 0) + delta_total)
            runtime["active_session_ovpn"] = max(0, active)
            runtime["distinct_ips_ovpn"] = sorted(distinct_ips)
            runtime["sessions_ovpn"] = normalize_session_rows(session_rows, "ovpn")
            if active > 0:
                runtime["last_seen_ovpn_unix"] = now_unix

            meta_block["ovpn_runtime_snapshots"] = next_snapshots
            meta_block["ovpn_present"] = True

            payload["runtime"] = runtime
            payload["meta"] = meta_block

        if write_user_state(username, mutate) != 0:
            return 1
    return 0


def build_parser():
    parser = argparse.ArgumentParser(description="Unified SSH and OVPN QAC runtime updater")
    sub = parser.add_subparsers(dest="cmd", required=True)

    ssh_sync = sub.add_parser("ssh-sync")
    ssh_sync.add_argument("--user", required=True)
    ssh_sync.add_argument("--quota-used-ssh")
    ssh_sync.add_argument("--active-session-ssh")
    ssh_sync.add_argument("--last-seen-ssh")
    ssh_sync.add_argument("--distinct-ips-ssh-json")
    ssh_sync.add_argument("--sessions-ssh-json")
    ssh_sync.add_argument("--quota-exhausted")
    ssh_sync.add_argument("--ip-limit-locked")
    ssh_sync.add_argument("--last-reason")
    ssh_sync.set_defaults(func=cmd_ssh_sync)

    ovpn_sync = sub.add_parser("ovpn-sync-status")
    ovpn_sync.add_argument("--status-file", default=str(OVPN_STATUS_FILE))
    ovpn_sync.add_argument("--clients-dir", default=str(OVPN_CLIENTS_ROOT))
    ovpn_sync.add_argument("--ccd-dir", default=str(OVPN_CCD_ROOT))
    ovpn_sync.set_defaults(func=cmd_ovpn_sync_status)

    ovpn_access = sub.add_parser("ovpn-sync-access")
    ovpn_access.add_argument("--clients-dir", default=str(OVPN_CLIENTS_ROOT))
    ovpn_access.add_argument("--ccd-dir", default=str(OVPN_CCD_ROOT))
    ovpn_access.set_defaults(func=cmd_ovpn_sync_access)
    return parser


def main():
    parser = build_parser()
    args = parser.parse_args()
    return int(args.func(args) or 0)


if __name__ == "__main__":
    raise SystemExit(main())
