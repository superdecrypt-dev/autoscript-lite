# shellcheck shell=bash

ssh_ovpn_qac_state_root_value() {
  printf '%s\n' "${QUOTA_ROOT}/ssh-ovpn"
}

ssh_ovpn_qac_lock_root_value() {
  printf '%s\n' "/run/autoscript/locks/ssh-ovpn-qac"
}

ssh_ovpn_qac_username_valid() {
  local username="${1:-}"
  [[ "${username}" =~ ^[A-Za-z0-9._-]{1,32}$ ]]
}

ssh_ovpn_qac_prepare_dirs() {
  local state_root lock_root
  state_root="$(ssh_ovpn_qac_state_root_value)"
  lock_root="$(ssh_ovpn_qac_lock_root_value)"
  mkdir -p "${state_root}" 2>/dev/null || true
  chmod 700 "${state_root}" 2>/dev/null || true
  mkdir -p "${lock_root}" 2>/dev/null || true
  chmod 700 "${lock_root}" 2>/dev/null || true
}

ssh_ovpn_qac_state_path() {
  local username="${1:-}"
  ssh_ovpn_qac_username_valid "${username}" || return 1
  printf '%s/%s.json\n' "$(ssh_ovpn_qac_state_root_value)" "${username}"
}

ssh_ovpn_qac_lock_path() {
  local username="${1:-}"
  ssh_ovpn_qac_username_valid "${username}" || return 1
  printf '%s/%s.lock\n' "$(ssh_ovpn_qac_lock_root_value)" "${username}"
}

ssh_ovpn_qac_state_exists() {
  local username="${1:-}"
  local path
  path="$(ssh_ovpn_qac_state_path "${username}" 2>/dev/null || true)"
  [[ -n "${path}" && -s "${path}" ]]
}

ssh_ovpn_qac_with_lock() {
  local username="${1:-}"
  shift || true
  ssh_ovpn_qac_username_valid "${username}" || return 1
  (( $# > 0 )) || return 1
  ssh_ovpn_qac_prepare_dirs

  local lock_file
  lock_file="$(ssh_ovpn_qac_lock_path "${username}")"
  if have_cmd flock; then
    local fd
    exec {fd}>"${lock_file}" || return 1
    flock -x "${fd}" || {
      exec {fd}>&-
      return 1
    }
    "$@"
    local rc=$?
    flock -u "${fd}" >/dev/null 2>&1 || true
    exec {fd}>&-
    return "${rc}"
  fi

  "$@"
}

ssh_ovpn_qac_state_read_field() {
  local username="${1:-}"
  local field="${2:-}"
  local state_file
  state_file="$(ssh_ovpn_qac_state_path "${username}" 2>/dev/null || true)"
  [[ -n "${field}" && -s "${state_file}" ]] || return 1
  need_python3
  python3 - <<'PY' "${state_file}" "${field}" 2>/dev/null || true
import json
import sys

path, field = sys.argv[1:3]
try:
  with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
  if not isinstance(data, dict):
    raise SystemExit(0)
except Exception:
  raise SystemExit(0)

value = data
for part in field.split("."):
  if not isinstance(value, dict):
    raise SystemExit(0)
  value = value.get(part)
  if value is None:
    raise SystemExit(0)

if isinstance(value, (dict, list)):
  print(json.dumps(value, ensure_ascii=False))
else:
  print(str(value))
PY
}

ssh_ovpn_qac_normalize_username() {
  local username="${1:-}"
  username="${username##*/}"
  username="${username%.json}"
  username="${username%@ssh}"
  username="${username%%@*}"
  printf '%s\n' "${username}"
}

ssh_ovpn_qac_username_from_legacy_ssh_path() {
  local qf="${1:-}"
  [[ -n "${qf}" ]] || return 1
  ssh_ovpn_qac_normalize_username "${qf}"
}

ssh_ovpn_qac_format_quota_limit_display() {
  local quota_bytes="${1:-0}"
  local quota_unit="${2:-binary}"
  need_python3
  python3 - <<'PY' "${quota_bytes}" "${quota_unit}"
import sys

def fmt(v):
  s = f"{v:.3f}".rstrip("0").rstrip(".")
  return s if s else "0"

try:
  b = int(float(sys.argv[1]))
except Exception:
  b = 0
if b < 0:
  b = 0
unit = str(sys.argv[2] or "binary").strip().lower()
bpg = 1000**3 if unit in ("decimal", "gb", "1000", "gigabyte") else 1024**3
print(f"{fmt(b / bpg)} GB")
PY
}

ssh_ovpn_qac_human_bytes() {
  local bytes="${1:-0}"
  need_python3
  python3 - <<'PY' "${bytes}"
import sys
try:
  b = int(float(sys.argv[1]))
except Exception:
  b = 0
if b < 0:
  b = 0
if b >= 1024**3:
  print(f"{b/(1024**3):.2f} GB")
elif b >= 1024**2:
  print(f"{b/(1024**2):.2f} MB")
elif b >= 1024:
  print(f"{b/1024:.2f} KB")
else:
  print(f"{b} B")
PY
}

ssh_ovpn_qac_summary_raw_fields() {
  local username="${1:-}"
  local state_file
  ssh_ovpn_qac_username_valid "${username}" || return 1
  state_file="$(ssh_ovpn_qac_state_path "${username}" 2>/dev/null || true)"
  [[ -s "${state_file}" ]] || return 1
  need_python3
  python3 - <<'PY' "${state_file}" 2>/dev/null || true
import json
import sys

path = sys.argv[1]

def to_int(v, default=0):
  try:
    if v is None:
      return default
    if isinstance(v, bool):
      return int(v)
    if isinstance(v, (int, float)):
      return int(v)
    s = str(v).strip()
    if not s:
      return default
    return int(float(s))
  except Exception:
    return default

def to_float(v, default=0.0):
  try:
    if v is None:
      return default
    if isinstance(v, bool):
      return float(int(v))
    if isinstance(v, (int, float)):
      return float(v)
    s = str(v).strip()
    if not s:
      return default
    return float(s)
  except Exception:
    return default

def to_bool_str(v):
  if isinstance(v, bool):
    return "true" if v else "false"
  if isinstance(v, (int, float)):
    return "true" if bool(v) else "false"
  s = str(v or "").strip().lower()
  return "true" if s in ("1", "true", "yes", "on", "y") else "false"

try:
  with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
  if not isinstance(data, dict):
    raise SystemExit(0)
except Exception:
  raise SystemExit(0)

policy = data.get("policy") if isinstance(data.get("policy"), dict) else {}
runtime = data.get("runtime") if isinstance(data.get("runtime"), dict) else {}
derived = data.get("derived") if isinstance(data.get("derived"), dict) else {}

access_value = derived.get("access_effective") if "access_effective" in derived else policy.get("access_enabled")

quota_used_ssh = max(0, to_int(runtime.get("quota_used_ssh_bytes"), 0))
quota_used_ovpn = max(0, to_int(runtime.get("quota_used_ovpn_bytes"), 0))
quota_used_total = max(0, to_int(derived.get("quota_used_total_bytes"), quota_used_ssh + quota_used_ovpn))
active_ssh = max(0, to_int(runtime.get("active_session_ssh"), 0))
active_ovpn = max(0, to_int(runtime.get("active_session_ovpn"), 0))
active_total = max(0, to_int(derived.get("active_session_total"), active_ssh + active_ovpn))

fields = [
  str(data.get("username") or "-"),
  str(max(0, to_int(policy.get("quota_limit_bytes"), 0))),
  str(policy.get("quota_unit") or "binary"),
  str(policy.get("expired_at") or "-")[:10] or "-",
  to_bool_str(access_value),
  to_bool_str(policy.get("ip_limit_enabled")),
  str(max(0, to_int(policy.get("ip_limit"), 0))),
  to_bool_str(policy.get("speed_limit_enabled")),
  str(max(0.0, to_float(policy.get("speed_down_mbit"), 0.0))),
  str(max(0.0, to_float(policy.get("speed_up_mbit"), 0.0))),
  str(quota_used_ssh),
  str(quota_used_ovpn),
  str(quota_used_total),
  str(active_ssh),
  str(active_ovpn),
  str(active_total),
  to_bool_str(derived.get("quota_exhausted")),
  to_bool_str(derived.get("ip_limit_locked")),
  str(derived.get("last_reason") or "-"),
]
print("|".join(fields))
PY
}

ssh_ovpn_qac_state_refresh_from_legacy__locked() {
  local username="${1:-}"
  local state_file ssh_state_file ovpn_state_file ccd_file tmp
  ssh_ovpn_qac_username_valid "${username}" || return 1
  ssh_ovpn_qac_prepare_dirs

  state_file="$(ssh_ovpn_qac_state_path "${username}")"
  ssh_state_file="$(ssh_user_state_file "${username}")"
  ovpn_state_file="$(openvpn_client_state_path_value "${username}")"
  ccd_file="$(openvpn_client_ccd_path_for_cn "$(openvpn_client_cn_get "${username}")" 2>/dev/null || true)"
  tmp="$(mktemp "$(ssh_ovpn_qac_state_root_value)/.${username}.XXXXXX")" || return 1

  need_python3
  if ! python3 - <<'PY' "${state_file}" "${username}" "${ssh_state_file}" "${ovpn_state_file}" "${ccd_file}" > "${tmp}"; then
import datetime
import json
import os
import sys
import time

state_path, username, ssh_path, ovpn_path, ccd_path = sys.argv[1:6]

def load_json(path):
  if not path or not os.path.isfile(path):
    return {}
  try:
    with open(path, "r", encoding="utf-8") as f:
      data = json.load(f)
    if isinstance(data, dict):
      return data
  except Exception:
    pass
  return {}

def to_int(v, default=0):
  try:
    if v is None:
      return default
    if isinstance(v, bool):
      return int(v)
    if isinstance(v, (int, float)):
      return int(v)
    s = str(v).strip()
    if not s:
      return default
    return int(float(s))
  except Exception:
    return default

def to_float(v, default=0.0):
  try:
    if v is None:
      return default
    if isinstance(v, bool):
      return float(int(v))
    if isinstance(v, (int, float)):
      return float(v)
    s = str(v).strip()
    if not s:
      return default
    return float(s)
  except Exception:
    return default

def to_bool(v, default=False):
  if v is None:
    return bool(default)
  if isinstance(v, bool):
    return v
  if isinstance(v, (int, float)):
    return bool(v)
  s = str(v).strip().lower()
  if not s:
    return bool(default)
  return s in ("1", "true", "yes", "on", "y")

def norm_date(v):
  s = str(v or "").strip()
  if not s:
    return ""
  return s[:10]

def date_is_active(v):
  s = norm_date(v)
  if not s or s == "-":
    return True
  try:
    return datetime.datetime.strptime(s, "%Y-%m-%d").date() >= datetime.date.today()
  except Exception:
    return True

current = load_json(state_path)
ssh = load_json(ssh_path)
ovpn = load_json(ovpn_path)
if not current and not ssh and not ovpn:
  raise SystemExit(3)

current_policy = current.get("policy") if isinstance(current.get("policy"), dict) else {}
current_runtime = current.get("runtime") if isinstance(current.get("runtime"), dict) else {}
current_derived = current.get("derived") if isinstance(current.get("derived"), dict) else {}
current_meta = current.get("meta") if isinstance(current.get("meta"), dict) else {}
ssh_status = ssh.get("status") if isinstance(ssh.get("status"), dict) else {}

ssh_present = bool(ssh)
ovpn_present = bool(ovpn)

created_at = (
  norm_date(ssh.get("created_at"))
  or norm_date(ovpn.get("created_at"))
  or norm_date(current_meta.get("created_at"))
  or datetime.datetime.utcnow().strftime("%Y-%m-%d")
)

expired_at = (
  norm_date(ssh.get("expired_at"))
  or norm_date(ovpn.get("expired_at"))
  or norm_date(current_policy.get("expired_at"))
  or "-"
)

quota_limit_raw = ssh.get("quota_limit")
if quota_limit_raw is None:
  quota_limit_raw = current_policy.get("quota_limit_bytes")
quota_limit = max(0, to_int(quota_limit_raw, 0))

quota_unit = str(ssh.get("quota_unit") or current_policy.get("quota_unit") or "binary").strip().lower()
if quota_unit not in ("binary", "decimal"):
  quota_unit = "binary"

ip_limit_enabled = to_bool(
  ssh_status.get("ip_limit_enabled"),
  current_policy.get("ip_limit_enabled"),
)
ip_limit = max(0, to_int(ssh_status.get("ip_limit"), to_int(current_policy.get("ip_limit"), 0)))

speed_limit_enabled = to_bool(
  ssh_status.get("speed_limit_enabled"),
  current_policy.get("speed_limit_enabled"),
)
speed_down = max(
  0.0,
  to_float(ssh_status.get("speed_down_mbit"), to_float(current_policy.get("speed_down_mbit"), 0.0)),
)
speed_up = max(
  0.0,
  to_float(ssh_status.get("speed_up_mbit"), to_float(current_policy.get("speed_up_mbit"), 0.0)),
)

manual_block = to_bool(ssh_status.get("manual_block"))
account_locked = to_bool(ssh_status.get("account_locked"))
ovpn_access = bool(ccd_path and os.path.exists(ccd_path)) if ovpn_present else None

if "access_enabled" in current_policy:
  access_requested = to_bool(current_policy.get("access_enabled"))
elif ovpn_access is not None:
  access_requested = ovpn_access
else:
  access_requested = not manual_block and not account_locked

quota_used_ssh = max(
  0,
  to_int(ssh.get("quota_used"), to_int(current_runtime.get("quota_used_ssh_bytes"), 0)),
)
quota_used_ovpn = max(0, to_int(current_runtime.get("quota_used_ovpn_bytes"), 0))
active_session_ssh = max(0, to_int(current_runtime.get("active_session_ssh"), 0))
active_session_ovpn = max(0, to_int(current_runtime.get("active_session_ovpn"), 0))
last_seen_ssh = max(0, to_int(current_runtime.get("last_seen_ssh_unix"), 0))
last_seen_ovpn = max(0, to_int(current_runtime.get("last_seen_ovpn_unix"), 0))

quota_used_total = quota_used_ssh + quota_used_ovpn
active_session_total = active_session_ssh + active_session_ovpn
quota_exhausted = bool(quota_limit > 0 and quota_used_total >= quota_limit)
ip_limit_locked = bool(ip_limit_enabled and ip_limit > 0 and active_session_total > ip_limit)
expired_active = date_is_active(expired_at)
access_effective = bool(access_requested and expired_active and not quota_exhausted and not ip_limit_locked)
if not access_requested:
  last_reason = "access_off"
elif not expired_active:
  last_reason = "expired"
elif quota_exhausted:
  last_reason = "quota"
elif ip_limit_locked:
  last_reason = "ip_limit"
else:
  last_reason = "-"

meta = dict(current_meta)
meta.update({
  "created_at": created_at,
  "updated_at_unix": int(time.time()),
  "migrated_from_legacy": bool(ssh_present or ovpn_present),
  "ssh_present": bool(ssh_present),
  "ovpn_present": bool(ovpn_present),
})

payload = {
  "version": 1,
  "username": username,
  "policy": {
    "quota_limit_bytes": quota_limit,
    "quota_unit": quota_unit,
    "expired_at": expired_at,
    "access_enabled": bool(access_requested),
    "ip_limit_enabled": bool(ip_limit_enabled),
    "ip_limit": ip_limit,
    "speed_limit_enabled": bool(speed_limit_enabled),
    "speed_down_mbit": speed_down,
    "speed_up_mbit": speed_up,
  },
  "runtime": {
    "quota_used_ssh_bytes": quota_used_ssh,
    "quota_used_ovpn_bytes": quota_used_ovpn,
    "active_session_ssh": active_session_ssh,
    "active_session_ovpn": active_session_ovpn,
    "last_seen_ssh_unix": last_seen_ssh,
    "last_seen_ovpn_unix": last_seen_ovpn,
  },
  "derived": {
    "quota_used_total_bytes": quota_used_total,
    "active_session_total": active_session_total,
    "quota_exhausted": bool(quota_exhausted),
    "ip_limit_locked": bool(ip_limit_locked),
    "access_effective": bool(access_effective),
    "last_reason": last_reason,
  },
  "meta": meta,
}

print(json.dumps(payload, ensure_ascii=False, indent=2))
PY
    local rc=$?
    rm -f "${tmp}" >/dev/null 2>&1 || true
    return "${rc}"
  fi

  printf '\n' >> "${tmp}"
  install -m 600 "${tmp}" "${state_file}" || {
    rm -f "${tmp}" >/dev/null 2>&1 || true
    return 1
  }
  rm -f "${tmp}" >/dev/null 2>&1 || true
  return 0
}

ssh_ovpn_qac_state_refresh_from_legacy() {
  local username="${1:-}"
  ssh_ovpn_qac_username_valid "${username}" || return 1
  ssh_ovpn_qac_with_lock "${username}" ssh_ovpn_qac_state_refresh_from_legacy__locked "${username}"
}

ssh_ovpn_qac_state_remove__locked() {
  local username="${1:-}"
  local state_file
  state_file="$(ssh_ovpn_qac_state_path "${username}" 2>/dev/null || true)"
  [[ -n "${state_file}" ]] || return 1
  rm -f "${state_file}" >/dev/null 2>&1 || true
  return 0
}

ssh_ovpn_qac_state_remove() {
  local username="${1:-}"
  ssh_ovpn_qac_username_valid "${username}" || return 1
  ssh_ovpn_qac_with_lock "${username}" ssh_ovpn_qac_state_remove__locked "${username}"
}

ssh_ovpn_qac_state_sync_now() {
  local username="${1:-}"
  [[ -n "${username}" ]] || return 1
  ssh_ovpn_qac_state_refresh_from_legacy "${username}"
}

ssh_ovpn_qac_state_sync_now_warn() {
  local username="${1:-}"
  [[ -n "${username}" ]] || return 1
  if ! ssh_ovpn_qac_state_sync_now "${username}"; then
    warn "State unified SSH & OVPN QAC belum sepenuhnya tersinkron untuk '${username}'."
    return 1
  fi
  return 0
}
