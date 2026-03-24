#!/usr/bin/env bash
# shellcheck shell=bash

# SSH QAC
# -------------------------
SSH_QAC_FILES=()
SSH_QAC_PAGE_SIZE=10
SSH_QAC_PAGE=0
SSH_QAC_QUERY=""
SSH_QAC_VIEW_INDEXES=()
SSH_QAC_ENFORCER_BIN="/usr/local/bin/sshws-qac-enforcer"
SSHWS_RUNTIME_SESSION_DIR="/run/autoscript/sshws-sessions"
SSHWS_RUNTIME_ENV_FILE="/etc/default/sshws-runtime"
SSHWS_CONTROL_BIN="/usr/local/bin/sshws-control"

sshws_runtime_session_stale_sec() {
  local value="90"
  if [[ -r "${SSHWS_RUNTIME_ENV_FILE}" ]]; then
    value="$(awk -F= '/^[[:space:]]*SSHWS_RUNTIME_SESSION_STALE_SEC=/{print $2; exit}' "${SSHWS_RUNTIME_ENV_FILE}" | tr -d '[:space:]')"
  fi
  [[ "${value}" =~ ^[0-9]+$ ]] || value="90"
  if (( value < 15 )); then
    value="90"
  fi
  printf '%s\n' "${value}"
}

ssh_active_sessions_count() {
  local username="${1:-}"
  [[ -n "${username}" ]] || {
    echo "0"
    return 0
  }
  if ! id "${username}" >/dev/null 2>&1; then
    echo "0"
    return 0
  fi

  local helper_count=""
  if [[ -x "${SSHWS_CONTROL_BIN}" && -d "${SSHWS_RUNTIME_SESSION_DIR}" ]]; then
    helper_count="$("${SSHWS_CONTROL_BIN}" session-stats \
      --session-root "${SSHWS_RUNTIME_SESSION_DIR}" \
      --username "${username}" 2>/dev/null | python3 -c '
import json
import sys

try:
    payload = json.load(sys.stdin)
except Exception:
    print("")
    raise SystemExit(0)

value = payload.get("total")
if isinstance(value, bool):
    value = int(value)
elif not isinstance(value, int):
    try:
        value = int(float(str(value or "").strip()))
    except Exception:
        value = ""
print(value if isinstance(value, int) and value >= 0 else "")
' 2>/dev/null || true)"
  fi
  if [[ "${helper_count}" =~ ^[0-9]+$ ]]; then
    echo "${helper_count}"
    return 0
  fi

  local runtime_count="0"
  if [[ -d "${SSHWS_RUNTIME_SESSION_DIR}" ]]; then
    runtime_count="$(python3 - "${SSHWS_RUNTIME_SESSION_DIR}" "${username}" "$(sshws_runtime_session_stale_sec)" <<'PY' 2>/dev/null || true
import json, pathlib, sys, time
import os
root = pathlib.Path(sys.argv[1])
target = str(sys.argv[2] or "").strip()
stale_sec = int(float(sys.argv[3] or 90))
count = 0

def pid_alive(pid):
  try:
    value = int(pid)
  except Exception:
    return False
  if value <= 0:
    return False
  try:
    os.kill(value, 0)
    return True
  except ProcessLookupError:
    return False
  except PermissionError:
    return True
  except Exception:
    return False

if root.is_dir() and target:
  for path in root.glob("*.json"):
    try:
      payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
      continue
    if not isinstance(payload, dict):
      continue
    if not pid_alive(payload.get("proxy_pid")):
      continue
    try:
      updated_at = int(float(payload.get("updated_at") or 0))
    except Exception:
      continue
    now = int(time.time())
    if updated_at <= 0 or now <= 0 or (now - updated_at) > stale_sec:
      continue
    username = str(payload.get("username") or "").strip()
    if username.endswith("@ssh"):
      username = username[:-4]
    if "@" in username:
      username = username.split("@", 1)[0]
    if username == target:
      count += 1
print(count)
PY
)"
  fi
  runtime_count="${runtime_count:-0}"
  [[ "${runtime_count}" =~ ^[0-9]+$ ]] || runtime_count="0"

  local c="0"
  c="$(python3 - "${username}" <<'PY' 2>/dev/null || true
import re
import subprocess
import sys

target = str(sys.argv[1] or "").strip().lower()
if not target:
    print(0)
    raise SystemExit(0)

try:
    res = subprocess.run(
        ["ps", "-eo", "pid=,ppid=,user=,comm=,args="],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        check=False,
    )
except FileNotFoundError:
    print(0)
    raise SystemExit(0)

rows = []
for line in (res.stdout or "").splitlines():
    raw = line.strip()
    if not raw:
        continue
    parts = raw.split(None, 4)
    if len(parts) < 5:
        continue
    try:
        pid = int(parts[0])
        ppid = int(parts[1])
    except Exception:
        continue
    rows.append({"pid": pid, "ppid": ppid, "comm": parts[3], "args": parts[4]})

master_pids = set()
for row in rows:
    if row["comm"] == "dropbear" and "-p 127.0.0.1:22022" in row["args"]:
        master_pids.add(row["pid"])

session_pids = []
for row in rows:
    if row["comm"] == "dropbear" and row["ppid"] in master_pids:
        session_pids.append(row["pid"])

pat = re.compile(r"dropbear\[(\d+)\]: .*auth succeeded for '([^']+)'", re.IGNORECASE)
mapping = {}
try:
    res = subprocess.run(
        ["journalctl", "-u", "sshws-dropbear", "--no-pager", "-n", "2000"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        check=False,
    )
    for line in (res.stdout or "").splitlines():
        m = pat.search(line)
        if not m:
            continue
        try:
            pid = int(m.group(1))
        except Exception:
            continue
        mapping[pid] = str(m.group(2) or "").strip().lower()
except FileNotFoundError:
    pass

if not mapping:
    try:
        res = subprocess.run(
            ["tail", "-n", "5000", "/var/log/auth.log"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            check=False,
        )
        for line in (res.stdout or "").splitlines():
            m = pat.search(line)
            if not m:
                continue
            try:
                pid = int(m.group(1))
            except Exception:
                continue
            mapping[pid] = str(m.group(2) or "").strip().lower()
    except FileNotFoundError:
        pass

count = 0
for pid in session_pids:
    if mapping.get(pid) == target:
        count += 1
print(count)
PY
)"
  c="${c:-0}"
  [[ "${c}" =~ ^[0-9]+$ ]] || c="0"
  if (( runtime_count > c )); then
    echo "${runtime_count}"
  else
    echo "${c}"
  fi
}

ssh_qac_setup_file_trusted() {
  local file="${1:-}"
  [[ -n "${file}" && -f "${file}" && -r "${file}" ]] || return 1

  local real owner mode
  real="$(readlink -f -- "${file}" 2>/dev/null || true)"
  [[ -n "${real}" && -f "${real}" && -r "${real}" ]] || return 1

  # Saat root: source restore harus root-owned, non-symlink, dan tidak writable group/other.
  if [[ "$(id -u)" -eq 0 ]]; then
    [[ -L "${file}" || -L "${real}" ]] && return 1
    owner="$(stat -c '%u' "${real}" 2>/dev/null || echo 1)"
    mode="$(stat -c '%A' "${real}" 2>/dev/null || echo '----------')"
    [[ "${owner}" == "0" ]] || return 1
    [[ "${mode:5:1}" != "w" && "${mode:8:1}" != "w" ]] || return 1
  fi

  printf '%s\n' "${real}"
  return 0
}

ssh_qac_detect_setup_script() {
  local candidates=()
  local src_dir="" repo_root=""
  src_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P 2>/dev/null || true)"
  if [[ -n "${src_dir}" ]]; then
    repo_root="$(cd "${src_dir}/../../.." && pwd -P 2>/dev/null || true)"
    [[ -n "${repo_root}" ]] && candidates+=("${repo_root}/setup.sh")
  fi
  [[ -n "${AUTOSCRIPT_SETUP_SH:-}" ]] && candidates+=("${AUTOSCRIPT_SETUP_SH}")
  candidates+=(
    "/root/project/autoscript/setup.sh"
    "/root/autoscript/setup.sh"
    "/opt/autoscript/setup.sh"
  )

  local f trusted_real
  for f in "${candidates[@]}"; do
    trusted_real="$(ssh_qac_setup_file_trusted "${f}" || true)"
    [[ -n "${trusted_real}" ]] || continue
    echo "${trusted_real}"
    return 0
  done
  return 1
}

ssh_qac_install_enforcer_from_setup() {
  [[ -x "${SSH_QAC_ENFORCER_BIN}" ]] && return 0
  local setup_file=""
  local tmp=""
  setup_file="$(ssh_qac_detect_setup_script || true)"
  [[ -n "${setup_file}" ]] || return 1
  command -v awk >/dev/null 2>&1 || return 1

  tmp="$(mktemp)"
  if ! awk '
    index($0, "cat > /usr/local/bin/sshws-qac-enforcer <<'\''PY'\''") { capture=1; next }
    capture && $0 == "PY" { exit }
    capture { print }
  ' "${setup_file}" > "${tmp}"; then
    rm -f "${tmp}" >/dev/null 2>&1 || true
    return 1
  fi
  if [[ ! -s "${tmp}" ]]; then
    rm -f "${tmp}" >/dev/null 2>&1 || true
    return 1
  fi
  if ! head -n1 "${tmp}" | grep -q '^#!/usr/bin/env python3$'; then
    rm -f "${tmp}" >/dev/null 2>&1 || true
    return 1
  fi

  install -d -m 755 "$(dirname "${SSH_QAC_ENFORCER_BIN}")"
  install -m 755 "${tmp}" "${SSH_QAC_ENFORCER_BIN}"
  rm -f "${tmp}" >/dev/null 2>&1 || true
  [[ -x "${SSH_QAC_ENFORCER_BIN}" ]]
}

ssh_qac_enforce_now() {
  local target_user="${1:-}"
  if [[ ! -x "${SSH_QAC_ENFORCER_BIN}" ]]; then
    ssh_qac_install_enforcer_from_setup >/dev/null 2>&1 || true
  fi
  if [[ -x "${SSH_QAC_ENFORCER_BIN}" ]]; then
    if [[ -n "${target_user}" ]]; then
      "${SSH_QAC_ENFORCER_BIN}" --once --user "${target_user}" >/dev/null 2>&1
    else
      "${SSH_QAC_ENFORCER_BIN}" --once >/dev/null 2>&1
    fi
    return $?
  fi
  return 1
}

ssh_qac_enforce_now_warn() {
  local target_user="${1:-}"
  if ! ssh_qac_enforce_now "${target_user}"; then
    if [[ -n "${target_user}" ]]; then
      warn "Enforcer SSH QAC gagal untuk '${target_user}'. Pastikan '${SSH_QAC_ENFORCER_BIN}' tersedia (bisa di-restore dari setup.sh)."
    else
      warn "Enforcer SSH QAC gagal dijalankan. Pastikan '${SSH_QAC_ENFORCER_BIN}' tersedia (bisa di-restore dari setup.sh)."
    fi
    return 1
  fi
  return 0
}

ssh_qac_collect_files() {
  SSH_QAC_FILES=()
  ssh_state_dirs_prepare
  local username qf
  while IFS= read -r username; do
    [[ -n "${username}" ]] || continue
    qf="$(ssh_user_state_resolve_file "${username}")"
    SSH_QAC_FILES+=("${qf}")
  done < <(ssh_collect_candidate_users false)
}

ssh_qac_total_pages_for_indexes() {
  local total="${#SSH_QAC_VIEW_INDEXES[@]}"
  if (( total == 0 )); then
    echo 0
    return 0
  fi
  echo $(( (total + SSH_QAC_PAGE_SIZE - 1) / SSH_QAC_PAGE_SIZE ))
}

ssh_qac_build_view_indexes() {
  SSH_QAC_VIEW_INDEXES=()

  local q
  q="$(echo "${SSH_QAC_QUERY:-}" | tr '[:upper:]' '[:lower:]')"
  if [[ -z "${q}" ]]; then
    local i
    for i in "${!SSH_QAC_FILES[@]}"; do
      SSH_QAC_VIEW_INDEXES+=("${i}")
    done
    return 0
  fi

  local i f base
  for i in "${!SSH_QAC_FILES[@]}"; do
    f="${SSH_QAC_FILES[$i]}"
    base="$(basename "${f}")"
    base="${base%.json}"
    base="$(ssh_username_from_key "${base}")"
    if echo "${base}" | tr '[:upper:]' '[:lower:]' | grep -qF -- "${q}"; then
      SSH_QAC_VIEW_INDEXES+=("${i}")
    fi
  done
}

ssh_qac_read_summary_fields() {
  # args: json_file
  # prints: username|quota_limit_disp|quota_used_disp|expired_at_date|ip_limit_disp|block_reason|lock_state
  local qf="$1"
  need_python3
  python3 - <<'PY' "${qf}"
import json
import pathlib
import sys

p = pathlib.Path(sys.argv[1])
def norm_user(v):
  s = str(v or "").strip()
  if s.endswith("@ssh"):
    s = s[:-4]
  if "@" in s:
    s = s.split("@", 1)[0]
  return s

username_fallback = norm_user(p.stem) or p.stem

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

def to_bool(v):
  if isinstance(v, bool):
    return v
  if isinstance(v, (int, float)):
    return bool(v)
  s = str(v or "").strip().lower()
  return s in ("1", "true", "yes", "on", "y")

def fmt_gb(v):
  try:
    n = float(v)
  except Exception:
    n = 0.0
  if n < 0:
    n = 0.0
  s = f"{n:.3f}".rstrip("0").rstrip(".")
  return s if s else "0"

def used_disp(b):
  try:
    b = int(b)
  except Exception:
    b = 0
  if b >= 1024**3:
    return f"{b/(1024**3):.2f} GB"
  if b >= 1024**2:
    return f"{b/(1024**2):.2f} MB"
  if b >= 1024:
    return f"{b/1024:.2f} KB"
  return f"{b} B"

data = {}
try:
  loaded = json.loads(p.read_text(encoding="utf-8"))
  if isinstance(loaded, dict):
    data = loaded
except Exception:
  data = {}

username = norm_user(data.get("username") or username_fallback) or username_fallback
quota_limit = to_int(data.get("quota_limit"), 0)
quota_used = to_int(data.get("quota_used"), 0)
unit = str(data.get("quota_unit") or "binary").strip().lower()
bpg = 1000**3 if unit in ("decimal", "gb", "1000", "gigabyte") else 1024**3
quota_limit_disp = f"{fmt_gb(quota_limit / bpg)} GB"
quota_used_disp = used_disp(quota_used)
expired_at = str(data.get("expired_at") or "-").strip()
expired_date = expired_at[:10] if expired_at and expired_at != "-" else "-"

status_raw = data.get("status")
status = status_raw if isinstance(status_raw, dict) else {}
ip_enabled = to_bool(status.get("ip_limit_enabled"))
ip_limit = to_int(status.get("ip_limit"), 0)
if ip_limit < 0:
  ip_limit = 0
ip_disp = "ON({})".format(ip_limit) if ip_enabled and ip_limit > 0 else ("ON" if ip_enabled else "OFF")

reason = str(status.get("lock_reason") or "").strip().lower()
if to_bool(status.get("manual_block")):
  reason = "manual"
elif to_bool(status.get("quota_exhausted")):
  reason = "quota"
elif to_bool(status.get("ip_limit_locked")):
  reason = "ip_limit"
reason_disp = reason.upper() if reason else "-"

lock_disp = "ON" if to_bool(status.get("account_locked")) else "OFF"

print(f"{username}|{quota_limit_disp}|{quota_used_disp}|{expired_date}|{ip_disp}|{reason_disp}|{lock_disp}")
PY
}

ssh_qac_read_detail_fields() {
  # args: json_file
  # prints: username|quota_limit_disp|quota_used_disp|expired_at_date|ip_limit_onoff|ip_limit_value|block_reason|speed_onoff|speed_down_mbit|speed_up_mbit|lock_state|distinct_ip_count|ip_limit_metric|distinct_ips|active_sessions_total|active_sessions_runtime|active_sessions_dropbear
  local qf="$1"
  need_python3
  python3 - <<'PY' "${qf}"
import json
import pathlib
import sys

p = pathlib.Path(sys.argv[1])
def norm_user(v):
  s = str(v or "").strip()
  if s.endswith("@ssh"):
    s = s[:-4]
  if "@" in s:
    s = s.split("@", 1)[0]
  return s

username_fallback = norm_user(p.stem) or p.stem

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

def to_bool(v):
  if isinstance(v, bool):
    return v
  if isinstance(v, (int, float)):
    return bool(v)
  s = str(v or "").strip().lower()
  return s in ("1", "true", "yes", "on", "y")

def ips_to_text(v):
  if not isinstance(v, list):
    return "-"
  out = []
  for item in v:
    text = str(item or "").strip()
    if text:
      out.append(text)
  return ", ".join(out) if out else "-"

def fmt_gb(v):
  try:
    n = float(v)
  except Exception:
    n = 0.0
  if n < 0:
    n = 0.0
  s = f"{n:.3f}".rstrip("0").rstrip(".")
  return s if s else "0"

def fmt_mbit(v):
  try:
    n = float(v)
  except Exception:
    n = 0.0
  if n < 0:
    n = 0.0
  s = f"{n:.3f}".rstrip("0").rstrip(".")
  return s if s else "0"

def used_disp(b):
  try:
    b = int(b)
  except Exception:
    b = 0
  if b >= 1024**3:
    return f"{b/(1024**3):.2f} GB"
  if b >= 1024**2:
    return f"{b/(1024**2):.2f} MB"
  if b >= 1024:
    return f"{b/1024:.2f} KB"
  return f"{b} B"

data = {}
try:
  loaded = json.loads(p.read_text(encoding="utf-8"))
  if isinstance(loaded, dict):
    data = loaded
except Exception:
  data = {}

username = norm_user(data.get("username") or username_fallback) or username_fallback
quota_limit = to_int(data.get("quota_limit"), 0)
quota_used = to_int(data.get("quota_used"), 0)
unit = str(data.get("quota_unit") or "binary").strip().lower()
bpg = 1000**3 if unit in ("decimal", "gb", "1000", "gigabyte") else 1024**3
quota_limit_disp = f"{fmt_gb(quota_limit / bpg)} GB"
quota_used_disp = used_disp(quota_used)
expired_at = str(data.get("expired_at") or "-").strip()
expired_date = expired_at[:10] if expired_at and expired_at != "-" else "-"

status_raw = data.get("status")
status = status_raw if isinstance(status_raw, dict) else {}

ip_enabled = to_bool(status.get("ip_limit_enabled"))
ip_limit = to_int(status.get("ip_limit"), 0)
if ip_limit < 0:
  ip_limit = 0
if not ip_enabled:
  ip_limit = 0

reason = str(status.get("lock_reason") or "").strip().lower()
if to_bool(status.get("manual_block")):
  reason = "manual"
elif to_bool(status.get("quota_exhausted")):
  reason = "quota"
elif to_bool(status.get("ip_limit_locked")):
  reason = "ip_limit"
reason_disp = reason.upper() if reason else "-"

speed_enabled = to_bool(status.get("speed_limit_enabled"))
speed_down = to_float(status.get("speed_down_mbit"), 0.0)
speed_up = to_float(status.get("speed_up_mbit"), 0.0)
if speed_down < 0:
  speed_down = 0.0
if speed_up < 0:
  speed_up = 0.0

distinct_ip_count = to_int(status.get("distinct_ip_count"), 0)
if distinct_ip_count < 0:
  distinct_ip_count = 0
ip_limit_metric = to_int(status.get("ip_limit_metric"), 0)
if ip_limit_metric < 0:
  ip_limit_metric = 0
active_sessions_total = to_int(status.get("active_sessions_total"), 0)
if active_sessions_total < 0:
  active_sessions_total = 0
active_sessions_runtime = to_int(status.get("active_sessions_runtime"), 0)
if active_sessions_runtime < 0:
  active_sessions_runtime = 0
active_sessions_dropbear = to_int(status.get("active_sessions_dropbear"), 0)
if active_sessions_dropbear < 0:
  active_sessions_dropbear = 0
distinct_ips = ips_to_text(status.get("distinct_ips"))

lock_disp = "ON" if to_bool(status.get("account_locked")) else "OFF"
print(
  f"{username}|{quota_limit_disp}|{quota_used_disp}|{expired_date}|"
  f"{'ON' if ip_enabled else 'OFF'}|{ip_limit}|{reason_disp}|"
  f"{'ON' if speed_enabled else 'OFF'}|{fmt_mbit(speed_down)}|{fmt_mbit(speed_up)}|{lock_disp}|"
  f"{distinct_ip_count}|{ip_limit_metric}|{distinct_ips}|{active_sessions_total}|{active_sessions_runtime}|{active_sessions_dropbear}"
)
PY
}

ssh_qac_get_status_bool() {
  # args: json_file key
  local qf="$1"
  local key="$2"
  need_python3
  python3 - <<'PY' "${qf}" "${key}"
import json
import sys

qf, key = sys.argv[1:3]
try:
  data = json.load(open(qf, "r", encoding="utf-8"))
except Exception:
  print("false")
  raise SystemExit(0)

if not isinstance(data, dict):
  print("false")
  raise SystemExit(0)

status = data.get("status")
if not isinstance(status, dict):
  status = {}

val = status.get(key)
if isinstance(val, bool):
  print("true" if val else "false")
elif isinstance(val, (int, float)):
  print("true" if bool(val) else "false")
else:
  s = str(val or "").strip().lower()
  print("true" if s in ("1", "true", "yes", "on", "y") else "false")
PY
}

ssh_qac_get_status_number() {
  # args: json_file key
  local qf="$1"
  local key="$2"
  need_python3
  python3 - <<'PY' "${qf}" "${key}"
import json
import sys

qf, key = sys.argv[1:3]
try:
  data = json.load(open(qf, "r", encoding="utf-8"))
except Exception:
  print("0")
  raise SystemExit(0)

if not isinstance(data, dict):
  print("0")
  raise SystemExit(0)

status = data.get("status")
if not isinstance(status, dict):
  status = {}

val = status.get(key)
try:
  if val is None:
    print("0")
  elif isinstance(val, bool):
    print(str(int(val)))
  elif isinstance(val, (int, float)):
    print(str(val))
  else:
    sval = str(val).strip()
    print(sval if sval else "0")
except Exception:
  print("0")
PY
}

ssh_qac_atomic_update_file_unlocked() {
  # args: json_file action [args...]
  local qf="$1"
  local action="$2"
  local lock_file
  shift 2 || true

  ssh_state_dirs_prepare
  ssh_qac_lock_prepare
  lock_file="$(ssh_qac_lock_file)"
  need_python3
  python3 - <<'PY' "${qf}" "${action}" "${lock_file}" "$@"
import atexit
import fcntl
import json
import os
import pathlib
import re
import secrets
import sys
import tempfile
import shutil

qf = sys.argv[1]
action = sys.argv[2]
lock_file = pathlib.Path(sys.argv[3] or "/run/autoscript/locks/sshws-qac.lock")
args = sys.argv[4:]
backup_file = str(os.environ.get("SSH_QAC_ATOMIC_BACKUP_FILE") or "").strip()

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

def to_bool(v):
  if isinstance(v, bool):
    return v
  if isinstance(v, (int, float)):
    return bool(v)
  s = str(v or "").strip().lower()
  return s in ("1", "true", "yes", "on", "y")

def norm_user(v):
  s = str(v or "").strip()
  if s.endswith("@ssh"):
    s = s[:-4]
  if "@" in s:
    s = s.split("@", 1)[0]
  return s

def parse_onoff(v):
  s = str(v or "").strip().lower()
  if s in ("on", "1", "true", "yes", "y"):
    return True
  if s in ("off", "0", "false", "no", "n"):
    return False
  raise SystemExit("nilai on/off tidak valid")

def parse_int(v, key, minv=None):
  try:
    n = int(float(str(v).strip()))
  except Exception:
    raise SystemExit(f"{key} harus angka")
  if minv is not None and n < minv:
    raise SystemExit(f"{key} minimal {minv}")
  return n

def parse_float(v, key, minv=None):
  try:
    n = float(str(v).strip())
  except Exception:
    raise SystemExit(f"{key} harus angka")
  if minv is not None and n < minv:
    raise SystemExit(f"{key} minimal {minv}")
  return n

def pick_unique_token(root_dir, current_path, current_token):
  seen = set()
  current_real = os.path.realpath(current_path)
  try:
    names = sorted(os.listdir(root_dir), key=str.lower)
  except Exception:
    names = []
  for name in names:
    if name.startswith(".") or not name.endswith(".json"):
      continue
    entry = os.path.join(root_dir, name)
    if os.path.realpath(entry) == current_real:
      continue
    try:
      loaded = json.load(open(entry, "r", encoding="utf-8"))
      if not isinstance(loaded, dict):
        continue
    except Exception:
      continue
    tok = str(loaded.get("sshws_token") or "").strip().lower()
    if re.fullmatch(r"[a-f0-9]{10}", tok):
      seen.add(tok)
  tok = str(current_token or "").strip().lower()
  if re.fullmatch(r"[a-f0-9]{10}", tok) and tok not in seen:
    return tok
  for _ in range(256):
    tok = secrets.token_hex(5)
    if tok not in seen:
      return tok
  raise SystemExit("failed to allocate unique sshws token")

lock_handle = None

def release_lock():
  global lock_handle
  if lock_handle is None:
    return
  try:
    fcntl.flock(lock_handle.fileno(), fcntl.LOCK_UN)
  except Exception:
    pass
  try:
    lock_handle.close()
  except Exception:
    pass
  lock_handle = None

try:
  lock_file.parent.mkdir(parents=True, exist_ok=True)
except Exception:
  pass

lock_handle = open(lock_file, "a+", encoding="utf-8")
fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX)
atexit.register(release_lock)

payload = {}
if os.path.isfile(qf):
  if backup_file:
    backup_path = pathlib.Path(backup_file)
    backup_path.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(qf, backup_path)
    try:
      os.chmod(backup_path, 0o600)
    except Exception:
      pass
  try:
    loaded = json.load(open(qf, "r", encoding="utf-8"))
    if isinstance(loaded, dict):
      payload = loaded
  except Exception:
    payload = {}

username_fallback = os.path.basename(qf)
if username_fallback.endswith(".json"):
  username_fallback = username_fallback[:-5]
username_fallback = norm_user(username_fallback) or username_fallback

status_raw = payload.get("status")
status = status_raw if isinstance(status_raw, dict) else {}

quota_limit = to_int(payload.get("quota_limit"), 0)
if quota_limit < 0:
  quota_limit = 0
quota_used = to_int(payload.get("quota_used"), 0)
if quota_used < 0:
  quota_used = 0

speed_down = to_float(status.get("speed_down_mbit"), 0.0)
speed_up = to_float(status.get("speed_up_mbit"), 0.0)
if speed_down < 0:
  speed_down = 0.0
if speed_up < 0:
  speed_up = 0.0

ip_limit = to_int(status.get("ip_limit"), 0)
if ip_limit < 0:
  ip_limit = 0

unit = str(payload.get("quota_unit") or "binary").strip().lower()
if unit not in ("binary", "decimal"):
  unit = "binary"
token = pick_unique_token(os.path.dirname(qf) or ".", qf, payload.get("sshws_token"))

payload["managed_by"] = "autoscript-manage"
payload["protocol"] = "ssh"
payload["username"] = norm_user(payload.get("username") or username_fallback) or username_fallback
payload["created_at"] = str(payload.get("created_at") or "-").strip() or "-"
payload["expired_at"] = str(payload.get("expired_at") or "-").strip()[:10] or "-"
payload["sshws_token"] = token
payload["quota_limit"] = quota_limit
payload["quota_unit"] = unit
payload["quota_used"] = quota_used
payload["bootstrap_review_needed"] = to_bool(payload.get("bootstrap_review_needed"))
payload["bootstrap_source"] = str(payload.get("bootstrap_source") or "").strip()
payload["status"] = {
  "manual_block": to_bool(status.get("manual_block")),
  "quota_exhausted": to_bool(status.get("quota_exhausted")),
  "ip_limit_enabled": to_bool(status.get("ip_limit_enabled")),
  "ip_limit": ip_limit,
  "ip_limit_locked": to_bool(status.get("ip_limit_locked")),
  "speed_limit_enabled": to_bool(status.get("speed_limit_enabled")),
  "speed_down_mbit": speed_down,
  "speed_up_mbit": speed_up,
  "lock_reason": str(status.get("lock_reason") or "").strip().lower(),
  "account_locked": to_bool(status.get("account_locked")),
  "lock_owner": str(status.get("lock_owner") or "").strip(),
  "lock_shell_restore": str(status.get("lock_shell_restore") or "").strip(),
}
network_raw = payload.get("network")
network = network_raw if isinstance(network_raw, dict) else {}
route_mode = str(network.get("route_mode") or "inherit").strip().lower()
if route_mode not in ("inherit", "direct", "warp"):
  route_mode = "inherit"
payload["network"] = {
  "route_mode": route_mode,
}

st = payload["status"]
net = payload["network"]

if action == "bootstrap_marker_set":
  if len(args) != 1:
    raise SystemExit("bootstrap_marker_set butuh 1 argumen (source)")
  payload["bootstrap_review_needed"] = True
  payload["bootstrap_source"] = str(args[0] or "").strip()
elif action == "set_quota_limit":
  if len(args) != 1:
    raise SystemExit("set_quota_limit butuh 1 argumen (bytes)")
  payload["quota_limit"] = parse_int(args[0], "quota_limit", 0)
elif action == "reset_quota_used":
  payload["quota_used"] = 0
  st["quota_exhausted"] = False
elif action == "manual_block_set":
  if len(args) != 1:
    raise SystemExit("manual_block_set butuh 1 argumen (on/off)")
  st["manual_block"] = bool(parse_onoff(args[0]))
elif action == "ip_limit_enabled_set":
  if len(args) != 1:
    raise SystemExit("ip_limit_enabled_set butuh 1 argumen (on/off)")
  enabled = bool(parse_onoff(args[0]))
  st["ip_limit_enabled"] = enabled
  if not enabled:
    st["ip_limit_locked"] = False
elif action == "set_ip_limit":
  if len(args) != 1:
    raise SystemExit("set_ip_limit butuh 1 argumen (angka)")
  st["ip_limit"] = parse_int(args[0], "ip_limit", 1)
elif action == "clear_ip_limit_locked":
  st["ip_limit_locked"] = False
elif action == "set_speed_down":
  if len(args) != 1:
    raise SystemExit("set_speed_down butuh 1 argumen (Mbps)")
  st["speed_down_mbit"] = parse_float(args[0], "speed_down_mbit", 0.000001)
elif action == "set_speed_up":
  if len(args) != 1:
    raise SystemExit("set_speed_up butuh 1 argumen (Mbps)")
  st["speed_up_mbit"] = parse_float(args[0], "speed_up_mbit", 0.000001)
elif action == "speed_limit_set":
  if len(args) != 1:
    raise SystemExit("speed_limit_set butuh 1 argumen (on/off)")
  st["speed_limit_enabled"] = bool(parse_onoff(args[0]))
elif action == "set_speed_all_enable":
  if len(args) != 2:
    raise SystemExit("set_speed_all_enable butuh 2 argumen (down up)")
  st["speed_down_mbit"] = parse_float(args[0], "speed_down_mbit", 0.000001)
  st["speed_up_mbit"] = parse_float(args[1], "speed_up_mbit", 0.000001)
  st["speed_limit_enabled"] = True
elif action == "network_route_mode_set":
  if len(args) != 1:
    raise SystemExit("network_route_mode_set butuh 1 argumen (inherit/direct/warp)")
  mode = str(args[0] or "").strip().lower()
  if mode not in ("inherit", "direct", "warp"):
    raise SystemExit("network route mode harus inherit/direct/warp")
  net["route_mode"] = mode
else:
  raise SystemExit(f"aksi ssh_qac_atomic_update_file tidak dikenali: {action}")

if action != "bootstrap_marker_set":
  payload["bootstrap_review_needed"] = False
  payload["bootstrap_source"] = ""

payload["status"] = st
payload["network"] = net
text = json.dumps(payload, ensure_ascii=False, indent=2) + "\n"
dirn = os.path.dirname(qf) or "."
fd, tmp = tempfile.mkstemp(prefix=".tmp.", suffix=".json", dir=dirn)
try:
  with os.fdopen(fd, "w", encoding="utf-8") as f:
    f.write(text)
    f.flush()
    os.fsync(f.fileno())
  os.replace(tmp, qf)
finally:
  try:
    if os.path.exists(tmp):
      os.remove(tmp)
  except Exception:
    pass
PY
  local py_rc=$?
  if (( py_rc != 0 )); then
    return "${py_rc}"
  fi
  chmod 600 "${qf}" 2>/dev/null || true
  return 0
}

ssh_qac_atomic_update_file() {
  # args: json_file action [args...]
  local qf="$1"
  local action="$2"
  shift 2 || true
  ssh_qac_atomic_update_file_unlocked "${qf}" "${action}" "$@"
}

ssh_qac_restore_file_unlocked() {
  local src="${1:-}"
  local dst="${2:-}"
  local tmp=""
  [[ -n "${src}" && -n "${dst}" ]] || return 1
  mkdir -p "$(dirname "${dst}")" 2>/dev/null || true
  tmp="$(mktemp)" || return 1
  if ! python3 - "${src}" "${dst}" "${tmp}" <<'PY'
import json
import pathlib
import shutil
import sys

src = pathlib.Path(sys.argv[1])
dst = pathlib.Path(sys.argv[2])
tmp = pathlib.Path(sys.argv[3])

def load_json(path):
  try:
    loaded = json.loads(path.read_text(encoding="utf-8"))
    return loaded if isinstance(loaded, dict) else {}
  except Exception:
    return {}

payload = load_json(src)
if not payload:
  shutil.copyfile(src, tmp)
  raise SystemExit(0)

current = load_json(dst)
status = payload.get("status")
if not isinstance(status, dict):
  status = {}
  payload["status"] = status

current_status = current.get("status")
if not isinstance(current_status, dict):
  current_status = {}

preserve_qac_lock_context = (
  bool(current_status.get("account_locked")) and
  str(current_status.get("lock_owner") or "").strip() == "ssh_qac" and
  str(current_status.get("lock_shell_restore") or "").strip() != "" and
  not bool(status.get("account_locked")) and
  str(status.get("lock_owner") or "").strip() == "" and
  str(status.get("lock_shell_restore") or "").strip() == ""
)

if preserve_qac_lock_context:
  status["account_locked"] = True
  status["lock_owner"] = "ssh_qac"
  status["lock_shell_restore"] = str(current_status.get("lock_shell_restore") or "").strip()

tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY
  then
    rm -f -- "${tmp}" >/dev/null 2>&1 || true
    return 1
  fi
  install -m 600 "${tmp}" "${dst}" || {
    rm -f -- "${tmp}" >/dev/null 2>&1 || true
    return 1
  }
  rm -f -- "${tmp}" >/dev/null 2>&1 || true
}

ssh_qac_restore_file_locked() {
  local src="${1:-}"
  local dst="${2:-}"
  ssh_qac_run_locked ssh_qac_restore_file_unlocked "${src}" "${dst}"
}

ssh_qac_apply_with_required_enforcer() {
  # args: username json_file action [args...]
  local username="${1:-}"
  local qf="${2:-}"
  local action="${3:-}"
  shift 3 || true

  if [[ -z "${username}" || -z "${qf}" || -z "${action}" ]]; then
    warn "Helper SSH QAC dipanggil tanpa argumen lengkap."
    return 1
  fi

  if [[ "${USER_DATA_MUTATION_LOCK_HELD:-0}" != "1" ]]; then
    user_data_mutation_run_locked ssh_qac_apply_with_required_enforcer "${username}" "${qf}" "${action}" "$@"
    return $?
  fi

  local backup_file=""
  backup_file="$(mktemp "/tmp/ssh-qac.${username}.XXXXXX")" || {
    warn "Gagal menyiapkan backup state SSH."
    return 1
  }

  if ! SSH_QAC_ATOMIC_BACKUP_FILE="${backup_file}" ssh_qac_atomic_update_file "${qf}" "${action}" "$@"; then
    rm -f -- "${backup_file}"
    return 1
  fi

  if ! ssh_qac_enforce_now "${username}"; then
    warn "Enforcer SSH QAC gagal untuk '${username}'. State di-rollback."
    local -a rollback_notes=()
    if ! ssh_qac_restore_file_locked "${backup_file}" "${qf}" >/dev/null 2>&1; then
      rollback_notes+=("rollback state gagal")
    else
      if ! ssh_qac_enforce_now "${username}"; then
        rollback_notes+=("rollback enforcer gagal")
      fi
    fi
    if ! ssh_account_info_refresh_warn "${username}"; then
      rollback_notes+=("rollback account info gagal")
    fi
    rm -f -- "${backup_file}"
    if (( ${#rollback_notes[@]} > 0 )); then
      warn "Rollback SSH QAC belum sepenuhnya bersih: ${rollback_notes[*]}"
    fi
    return 1
  fi

  if ! ssh_account_info_refresh_warn "${username}"; then
    warn "Refresh SSH ACCOUNT INFO gagal untuk '${username}'. State di-rollback."
    local -a rollback_notes=()
    if ! ssh_qac_restore_file_locked "${backup_file}" "${qf}" >/dev/null 2>&1; then
      rollback_notes+=("rollback state gagal")
    else
      if ! ssh_qac_enforce_now "${username}"; then
        rollback_notes+=("rollback enforcer gagal")
      fi
      if ! ssh_account_info_refresh_warn "${username}"; then
        rollback_notes+=("rollback account info gagal")
      fi
    fi
    rm -f -- "${backup_file}"
    if (( ${#rollback_notes[@]} > 0 )); then
      warn "Rollback SSH QAC belum sepenuhnya bersih: ${rollback_notes[*]}"
    fi
    return 1
  fi
  rm -f -- "${backup_file}"
  return 0
}

ssh_qac_apply_with_required_refresh() {
  # args: username json_file action [args...]
  local username="${1:-}"
  local qf="${2:-}"
  local action="${3:-}"
  shift 3 || true

  if [[ -z "${username}" || -z "${qf}" || -z "${action}" ]]; then
    warn "Helper SSH speed/QAC dipanggil tanpa argumen lengkap."
    return 1
  fi

  if [[ "${USER_DATA_MUTATION_LOCK_HELD:-0}" != "1" ]]; then
    user_data_mutation_run_locked ssh_qac_apply_with_required_refresh "${username}" "${qf}" "${action}" "$@"
    return $?
  fi

  local backup_file=""
  backup_file="$(mktemp "/tmp/ssh-qac.${username}.XXXXXX")" || {
    warn "Gagal menyiapkan backup state SSH."
    return 1
  }

  if ! SSH_QAC_ATOMIC_BACKUP_FILE="${backup_file}" ssh_qac_atomic_update_file "${qf}" "${action}" "$@"; then
    rm -f -- "${backup_file}"
    return 1
  fi

  if ! ssh_account_info_refresh_from_state "${username}"; then
    warn "SSH ACCOUNT INFO gagal disinkronkan untuk '${username}'. State di-rollback."
    local -a rollback_notes=()
    if ! ssh_qac_restore_file_locked "${backup_file}" "${qf}" >/dev/null 2>&1; then
      rollback_notes+=("rollback state gagal")
    else
      if ! ssh_account_info_refresh_from_state "${username}"; then
        rollback_notes+=("rollback account info gagal")
      fi
    fi
    rm -f -- "${backup_file}"
    if (( ${#rollback_notes[@]} > 0 )); then
      warn "Rollback SSH speed/QAC belum sepenuhnya bersih: ${rollback_notes[*]}"
    fi
    return 1
  fi

  rm -f -- "${backup_file}"
  return 0
}

ssh_qac_view_json() {
  local qf="$1"
  title
  echo "SSH QAC metadata: ${qf}"
  hr
  need_python3
  if have_cmd less; then
    python3 - <<'PY' "${qf}" | less -R
import json
import sys

p = sys.argv[1]
try:
  d = json.load(open(p, "r", encoding="utf-8"))
except Exception:
  print(open(p, "r", encoding="utf-8", errors="replace").read())
  raise SystemExit(0)

exp = d.get("expired_at")
if isinstance(exp, str) and exp:
  d["expired_at"] = exp[:10]
print(json.dumps(d, ensure_ascii=False, indent=2))
PY
  else
    python3 - <<'PY' "${qf}"
import json
import sys

p = sys.argv[1]
try:
  d = json.load(open(p, "r", encoding="utf-8"))
except Exception:
  print(open(p, "r", encoding="utf-8", errors="replace").read())
  raise SystemExit(0)

exp = d.get("expired_at")
if isinstance(exp, str) and exp:
  d["expired_at"] = exp[:10]
print(json.dumps(d, ensure_ascii=False, indent=2))
PY
  fi
  hr
  pause
}

ssh_qac_print_table_page() {
  local page="${1:-0}"
  local total="${#SSH_QAC_VIEW_INDEXES[@]}"
  local pages=0
  local display_pages=1
  if (( total > 0 )); then
    pages=$(( (total + SSH_QAC_PAGE_SIZE - 1) / SSH_QAC_PAGE_SIZE ))
    display_pages="${pages}"
  fi
  if (( page < 0 )); then
    page=0
  fi
  if (( pages > 0 && page >= pages )); then
    page=$((pages - 1))
  fi
  SSH_QAC_PAGE="${page}"

  echo "SSH accounts: ${total} | page $((page + 1))/${display_pages}"
  if [[ -n "${SSH_QAC_QUERY}" ]]; then
    echo "Filter: '${SSH_QAC_QUERY}'"
  fi
  echo

  if (( total == 0 )); then
    echo "Belum ada data SSH QAC."
    return 0
  fi

  printf "%-4s %-18s %-11s %-11s %-12s %-10s %-6s\n" "NO" "Username" "Quota" "Used" "Expired" "IPLimit" "Lock"
  hr

  local start end i list_pos real_idx qf fields username ql qu exp ipd lock
  start=$((page * SSH_QAC_PAGE_SIZE))
  end=$((start + SSH_QAC_PAGE_SIZE))
  if (( end > total )); then
    end="${total}"
  fi
  for (( i=start; i<end; i++ )); do
    list_pos="${i}"
    real_idx="${SSH_QAC_VIEW_INDEXES[$list_pos]}"
    qf="${SSH_QAC_FILES[$real_idx]}"
    fields="$(ssh_qac_read_summary_fields "${qf}")"
    IFS='|' read -r username ql qu exp ipd _ lock <<<"${fields}"
    printf "%-4s %-18s %-11s %-11s %-12s %-10s %-6s\n" "$((i - start + 1))" "${username}" "${ql}" "${qu}" "${exp}" "${ipd}" "${lock}"
  done
}

ssh_qac_edit_flow() {
  # args: view_no (1-based pada halaman aktif)
  local view_no="$1"

  [[ "${view_no}" =~ ^[0-9]+$ ]] || { warn "Input bukan angka"; pause; return 0; }
  local total page pages start end rows
  total="${#SSH_QAC_VIEW_INDEXES[@]}"
  if (( total <= 0 )); then
    warn "Tidak ada data"
    pause
    return 0
  fi
  page="${SSH_QAC_PAGE:-0}"
  pages=$(( (total + SSH_QAC_PAGE_SIZE - 1) / SSH_QAC_PAGE_SIZE ))
  if (( page < 0 )); then page=0; fi
  if (( pages > 0 && page >= pages )); then page=$((pages - 1)); fi
  start=$((page * SSH_QAC_PAGE_SIZE))
  end=$((start + SSH_QAC_PAGE_SIZE))
  if (( end > total )); then end="${total}"; fi
  rows=$((end - start))

  if (( view_no < 1 || view_no > rows )); then
    warn "NO di luar range"
    pause
    return 0
  fi

  local list_pos real_idx qf
  list_pos=$((start + view_no - 1))
  real_idx="${SSH_QAC_VIEW_INDEXES[$list_pos]}"
  qf="${SSH_QAC_FILES[$real_idx]}"
  local qf_base username_hint=""
  qf_base="$(basename "${qf}")"
  qf_base="${qf_base%.json}"
  username_hint="$(ssh_username_from_key "${qf_base}")"

  if [[ ! -f "${qf}" ]]; then
    warn "Metadata SSH QAC untuk '${username_hint}' belum ada."
    echo "Bootstrap akan membuat state placeholder minimal:"
	    echo "  - quota used = 0"
	    echo "  - created_at = hari ini"
	    echo "  - expired_at = -"
	    hr
	    if ! confirm_menu_apply_now "Buat metadata SSH QAC awal untuk '${username_hint}' sekarang?"; then
	      pause
	      return 0
	    fi
	    if ! confirm_menu_apply_now "Konfirmasi final: buat placeholder metadata SSH QAC baru untuk '${username_hint}'?"; then
	      pause
	      return 0
	    fi
	    local bootstrap_ack=""
	    read -r -p "Ketik persis 'BOOTSTRAP SSH QAC ${username_hint}' untuk lanjut bootstrap placeholder SSH QAC (atau kembali): " bootstrap_ack
	    if is_back_choice "${bootstrap_ack}"; then
	      pause
	      return 0
	    fi
	    if [[ "${bootstrap_ack}" != "BOOTSTRAP SSH QAC ${username_hint}" ]]; then
	      warn "Konfirmasi bootstrap placeholder SSH QAC tidak cocok. Dibatalkan."
	      pause
	      return 0
	    fi
	    if ! ssh_qac_metadata_bootstrap_if_missing "${username_hint}" "${qf}"; then
	      warn "Gagal membuat metadata SSH QAC awal untuk '${username_hint}'."
	      pause
      return 1
    fi
  fi

  while true; do
    local label_w=18
    title
    echo "4) SSH QAC > Detail"
    hr
    printf "%-${label_w}s : %s\n" "File" "${qf}"
    hr

    local fields username ql_disp qu_disp exp_date ip_state ip_lim block_reason speed_state speed_down speed_up lock_state
    local distinct_ip_count ip_limit_metric distinct_ips active_sessions_total active_sessions_runtime active_sessions_dropbear
    fields="$(ssh_qac_read_detail_fields "${qf}")"
    IFS='|' read -r \
      username \
      ql_disp \
      qu_disp \
      exp_date \
      ip_state \
      ip_lim \
      block_reason \
      speed_state \
      speed_down \
      speed_up \
      lock_state \
      distinct_ip_count \
      ip_limit_metric \
      distinct_ips \
      active_sessions_total \
      active_sessions_runtime \
      active_sessions_dropbear <<<"${fields}"

    [[ "${distinct_ip_count}" =~ ^[0-9]+$ ]] || distinct_ip_count="0"
    [[ "${ip_limit_metric}" =~ ^[0-9]+$ ]] || ip_limit_metric="0"
    [[ "${active_sessions_total}" =~ ^[0-9]+$ ]] || active_sessions_total="0"
    [[ "${active_sessions_runtime}" =~ ^[0-9]+$ ]] || active_sessions_runtime="0"
    [[ "${active_sessions_dropbear}" =~ ^[0-9]+$ ]] || active_sessions_dropbear="0"
    [[ -n "${distinct_ips}" ]] || distinct_ips="-"

    printf "%-${label_w}s : %s\n" "Username" "${username}"
    printf "%-${label_w}s : %s\n" "Quota Limit" "${ql_disp}"
    printf "%-${label_w}s : %s\n" "Quota Used" "${qu_disp}"
    printf "%-${label_w}s : %s\n" "Expired At" "${exp_date}"
    printf "%-${label_w}s : %s\n" "IP/Login Limit" "${ip_state}"
    printf "%-${label_w}s : %s\n" "IP/Login Limit Max" "${ip_lim}"
    printf "%-${label_w}s : %s\n" "IP Unik Aktif" "${distinct_ip_count}"
    printf "%-${label_w}s : %s\n" "Daftar IP Aktif" "${distinct_ips}"
    printf "%-${label_w}s : %s\n" "IP/Login Metric" "${ip_limit_metric}"
    printf "%-${label_w}s : %s\n" "Block Reason" "${block_reason}"
    printf "%-${label_w}s : %s\n" "Account Locked" "${lock_state}"
    printf "%-${label_w}s : %s\n" "Sesi Aktif" "${active_sessions_total}"
    printf "%-${label_w}s : %s Mbps\n" "Speed Download" "${speed_down}"
    printf "%-${label_w}s : %s Mbps\n" "Speed Upload" "${speed_up}"
    printf "%-${label_w}s : %s\n" "Speed Limit" "${speed_state}"
    local ssh_bootstrap_needed ssh_bootstrap_source
    IFS='|' read -r ssh_bootstrap_needed ssh_bootstrap_source <<<"$(ssh_qac_bootstrap_status_get "${qf}")"
    if [[ "${ssh_bootstrap_needed}" == "true" ]]; then
      printf "%-${label_w}s : %s\n" "Bootstrap" "PERLU REVIEW"
      [[ -n "${ssh_bootstrap_source}" ]] && printf "%-${label_w}s : %s\n" "Source" "${ssh_bootstrap_source}"
    fi
    hr

    echo "  1) View JSON"
    echo "  2) Set Quota (GB)"
    echo "  3) Reset Quota"
    echo "  4) Toggle Block"
    echo "  5) Toggle IP/Login Limit"
    echo "  6) Set IP/Login Limit"
    echo "  7) Unlock IP/Login"
    echo "  8) Set Speed Download"
    echo "  9) Set Speed Upload"
    echo " 10) Speed Limit Enable/Disable (toggle)"
    echo "  0) Back"
    hr
    if ! read -r -p "Pilih: " c; then
      echo
      break
    fi
    if is_back_choice "${c}"; then
      return 0
    fi

    case "${c}" in
      1)
        ssh_qac_view_json "${qf}"
        ;;
      2)
        if ! read -r -p "Quota Limit (GB) (atau kembali): " gb; then
          echo
          return 0
        fi
        if is_back_choice "${gb}"; then
          continue
        fi
        if [[ -z "${gb}" ]]; then
          warn "Quota kosong"
          pause
          continue
        fi
        local gb_num qb
        gb_num="$(normalize_gb_input "${gb}")"
        if [[ -z "${gb_num}" ]]; then
          warn "Format quota tidak valid. Contoh: 5 atau 5GB"
          pause
          continue
        fi
        qb="$(bytes_from_gb "${gb_num}")"
        if ! confirm_menu_apply_now "Set quota limit SSH ${username} ke ${gb_num} GB sekarang?"; then
          pause
          continue
        fi
        if ! ssh_qac_apply_with_required_enforcer "${username}" "${qf}" set_quota_limit "${qb}"; then
          warn "Gagal update quota limit SSH."
          pause
          continue
        fi
        log "Quota limit SSH diubah: ${gb_num} GB"
        pause
        ;;
      3)
        if ! confirm_menu_apply_now "Reset quota used SSH ${username} ke 0 sekarang?"; then
          pause
          continue
        fi
        if ! ssh_qac_apply_with_required_enforcer "${username}" "${qf}" reset_quota_used; then
          warn "Gagal reset quota used SSH."
          pause
          continue
        fi
        log "Quota used SSH di-reset: 0"
        pause
        ;;
      4)
        local st_mb
        st_mb="$(ssh_qac_get_status_bool "${qf}" "manual_block")"
        if [[ "${st_mb}" == "true" ]]; then
          if ! confirm_menu_apply_now "Nonaktifkan manual block SSH untuk ${username} sekarang?"; then
            pause
            continue
          fi
          if ! ssh_qac_apply_with_required_enforcer "${username}" "${qf}" manual_block_set off; then
            warn "Gagal menonaktifkan manual block SSH."
            pause
            continue
          fi
          log "Manual block SSH: OFF"
        else
          if ! confirm_menu_apply_now "Aktifkan manual block SSH untuk ${username} sekarang?"; then
            pause
            continue
          fi
          if ! ssh_qac_apply_with_required_enforcer "${username}" "${qf}" manual_block_set on; then
            warn "Gagal mengaktifkan manual block SSH."
            pause
            continue
          fi
          log "Manual block SSH: ON"
        fi
        pause
        ;;
      5)
        local ip_on
        ip_on="$(ssh_qac_get_status_bool "${qf}" "ip_limit_enabled")"
        if [[ "${ip_on}" == "true" ]]; then
          if ! confirm_menu_apply_now "Nonaktifkan IP/Login limit SSH untuk ${username} sekarang?"; then
            pause
            continue
          fi
          if ! ssh_qac_apply_with_required_enforcer "${username}" "${qf}" ip_limit_enabled_set off; then
            warn "Gagal menonaktifkan IP limit SSH."
            pause
            continue
          fi
          log "IP limit SSH: OFF"
        else
          if ! confirm_menu_apply_now "Aktifkan IP/Login limit SSH untuk ${username} sekarang?"; then
            pause
            continue
          fi
          if ! ssh_qac_apply_with_required_enforcer "${username}" "${qf}" ip_limit_enabled_set on; then
            warn "Gagal mengaktifkan IP limit SSH."
            pause
            continue
          fi
          log "IP limit SSH: ON"
        fi
        pause
        ;;
      6)
        if ! read -r -p "IP limit (angka) (atau kembali): " lim; then
          echo
          return 0
        fi
        if is_back_word_choice "${lim}"; then
          continue
        fi
        if [[ -z "${lim}" || ! "${lim}" =~ ^[0-9]+$ || "${lim}" -le 0 ]]; then
          warn "Limit harus angka > 0"
          pause
          continue
        fi
        if ! confirm_menu_apply_now "Set IP/Login limit SSH ${username} ke ${lim} sekarang?"; then
          pause
          continue
        fi
        if ! ssh_qac_apply_with_required_enforcer "${username}" "${qf}" set_ip_limit "${lim}"; then
          warn "Gagal set IP limit SSH."
          pause
          continue
        fi
        log "IP limit SSH diubah: ${lim}"
        pause
        ;;
      7)
        if ! confirm_menu_apply_now "Unlock IP/Login lock SSH untuk ${username} sekarang?"; then
          pause
          continue
        fi
        if ! ssh_qac_apply_with_required_enforcer "${username}" "${qf}" clear_ip_limit_locked; then
          warn "Gagal unlock IP lock SSH."
          pause
          continue
        fi
        log "IP lock SSH di-unlock"
        pause
        ;;
      8)
        if ! read -r -p "Speed Download (Mbps) (contoh: 20 atau 20mbit) (atau kembali): " speed_down_input; then
          echo
          return 0
        fi
        if is_back_word_choice "${speed_down_input}"; then
          continue
        fi
        speed_down_input="$(normalize_speed_mbit_input "${speed_down_input}")"
        if [[ -z "${speed_down_input}" ]] || ! speed_mbit_is_positive "${speed_down_input}"; then
          warn "Speed download tidak valid. Gunakan angka > 0."
          pause
          continue
        fi
        if ! confirm_menu_apply_now "Set speed download SSH ${username} ke ${speed_down_input} Mbps sekarang?"; then
          pause
          continue
        fi
        if ! ssh_qac_apply_with_required_refresh "${username}" "${qf}" set_speed_down "${speed_down_input}"; then
          warn "Gagal set speed download SSH."
          pause
          continue
        fi
        log "Speed download SSH diubah: ${speed_down_input} Mbps"
        pause
        ;;
      9)
        if ! read -r -p "Speed Upload (Mbps) (contoh: 10 atau 10mbit) (atau kembali): " speed_up_input; then
          echo
          return 0
        fi
        if is_back_word_choice "${speed_up_input}"; then
          continue
        fi
        speed_up_input="$(normalize_speed_mbit_input "${speed_up_input}")"
        if [[ -z "${speed_up_input}" ]] || ! speed_mbit_is_positive "${speed_up_input}"; then
          warn "Speed upload tidak valid. Gunakan angka > 0."
          pause
          continue
        fi
        if ! confirm_menu_apply_now "Set speed upload SSH ${username} ke ${speed_up_input} Mbps sekarang?"; then
          pause
          continue
        fi
        if ! ssh_qac_apply_with_required_refresh "${username}" "${qf}" set_speed_up "${speed_up_input}"; then
          warn "Gagal set speed upload SSH."
          pause
          continue
        fi
        log "Speed upload SSH diubah: ${speed_up_input} Mbps"
        pause
        ;;
      10)
        local speed_on speed_down_now speed_up_now
        speed_on="$(ssh_qac_get_status_bool "${qf}" "speed_limit_enabled")"
        if [[ "${speed_on}" == "true" ]]; then
          if ! confirm_menu_apply_now "Nonaktifkan speed limit SSH untuk ${username} sekarang?"; then
            pause
            continue
          fi
          if ! ssh_qac_apply_with_required_refresh "${username}" "${qf}" speed_limit_set off; then
            warn "Gagal menonaktifkan speed limit SSH."
            pause
            continue
          fi
          log "Speed limit SSH: OFF"
          pause
          continue
        fi

        speed_down_now="$(ssh_qac_get_status_number "${qf}" "speed_down_mbit")"
        speed_up_now="$(ssh_qac_get_status_number "${qf}" "speed_up_mbit")"

        if ! speed_mbit_is_positive "${speed_down_now}"; then
          if ! read -r -p "Speed Download (Mbps) (contoh: 20 atau 20mbit) (atau kembali): " speed_down_now; then
            echo
            return 0
          fi
          if is_back_choice "${speed_down_now}"; then
            continue
          fi
          speed_down_now="$(normalize_speed_mbit_input "${speed_down_now}")"
          if [[ -z "${speed_down_now}" ]] || ! speed_mbit_is_positive "${speed_down_now}"; then
            warn "Speed download tidak valid. Speed limit tetap OFF."
            pause
            continue
          fi
        fi
        if ! speed_mbit_is_positive "${speed_up_now}"; then
          if ! read -r -p "Speed Upload (Mbps) (contoh: 10 atau 10mbit) (atau kembali): " speed_up_now; then
            echo
            return 0
          fi
          if is_back_choice "${speed_up_now}"; then
            continue
          fi
          speed_up_now="$(normalize_speed_mbit_input "${speed_up_now}")"
          if [[ -z "${speed_up_now}" ]] || ! speed_mbit_is_positive "${speed_up_now}"; then
            warn "Speed upload tidak valid. Speed limit tetap OFF."
            pause
            continue
          fi
        fi

        if ! confirm_menu_apply_now "Aktifkan speed limit SSH ${username} dengan DOWN ${speed_down_now} Mbps dan UP ${speed_up_now} Mbps sekarang?"; then
          pause
          continue
        fi
        if ! ssh_qac_apply_with_required_refresh "${username}" "${qf}" set_speed_all_enable "${speed_down_now}" "${speed_up_now}"; then
          warn "Gagal mengaktifkan speed limit SSH."
          pause
          continue
        fi
        log "Speed limit SSH: ON"
        pause
        ;;
      *)
        warn "Pilihan tidak valid"
        sleep 1
        ;;
    esac
  done
}

ssh_quota_menu() {
  ssh_state_dirs_prepare
  need_python3

  SSH_QAC_PAGE=0
  SSH_QAC_QUERY=""

  while true; do
    ui_menu_screen_begin "4) SSH QAC"
    ssh_qac_collect_files
    ssh_qac_build_view_indexes
    ssh_qac_print_table_page "${SSH_QAC_PAGE}"
    hr

    echo "Masukkan NO untuk view/edit, atau ketik:"
    echo "  sync) jalankan enforcement SSH QAC sekarang"
    echo "  search) filter username"
    echo "  clear) hapus filter"
    echo "  next / previous"
    hr
    if ! read -r -p "Pilih: " c; then
      echo
      break
    fi

    if is_back_choice "${c}"; then
      break
    fi

    case "${c}" in
      sync)
        if ! ssh_qac_enforce_now_warn; then
          warn "Sinkronisasi enforcement SSH QAC gagal."
        else
          log "Enforcement SSH QAC selesai."
        fi
        pause
        ;;
      next|n)
        local pages
        pages="$(ssh_qac_total_pages_for_indexes)"
        if (( pages > 0 && SSH_QAC_PAGE < pages - 1 )); then
          SSH_QAC_PAGE=$((SSH_QAC_PAGE + 1))
        fi
        ;;
      previous|p|prev)
        if (( SSH_QAC_PAGE > 0 )); then
          SSH_QAC_PAGE=$((SSH_QAC_PAGE - 1))
        fi
        ;;
      search)
        if ! read -r -p "Search username (atau kembali): " q; then
          echo
          break
        fi
        if is_back_choice "${q}"; then
          continue
        fi
        SSH_QAC_QUERY="${q}"
        SSH_QAC_PAGE=0
        ;;
      clear)
        SSH_QAC_QUERY=""
        SSH_QAC_PAGE=0
        ;;
      *)
        if [[ "${c}" =~ ^[0-9]+$ ]]; then
          ssh_qac_edit_flow "${c}"
        else
          warn "Pilihan tidak valid"
          sleep 1
        fi
        ;;
    esac
  done
}
