# shellcheck shell=bash

openvpn_qac_state_root_get() {
  local state_root="/opt/quota/openvpn"
  local raw=""
  if [[ -r "${OPENVPN_CONFIG_ENV_FILE}" ]]; then
    raw="$(awk -F= '$1=="OPENVPN_STATE_DIR"{print $2; exit}' "${OPENVPN_CONFIG_ENV_FILE}" 2>/dev/null | tr -d '"' | tr -d "'" | xargs || true)"
    [[ -n "${raw}" ]] && state_root="${raw}"
  fi
  printf '%s\n' "${state_root}"
}

openvpn_qac_state_dirs_prepare() {
  local root
  root="$(openvpn_qac_state_root_get)"
  mkdir -p "${root}" 2>/dev/null || true
  chmod 755 "${root}" 2>/dev/null || true
}

openvpn_qac_sync_metadata_file() {
  local qf="${1:-}"
  [[ -f "${qf}" ]] || return 0
  need_python3
  python3 - "${qf}" "${OPENVPN_CONFIG_ENV_FILE}" <<'PY'
import json
import os
import sys
import tempfile
from pathlib import Path

path = Path(sys.argv[1])
cfg_path = Path(sys.argv[2])

def read_env_map(candidate: Path) -> dict[str, str]:
    data: dict[str, str] = {}
    if not candidate.is_file():
        return data
    try:
        lines = candidate.read_text(encoding="utf-8", errors="ignore").splitlines()
    except Exception:
        return data
    for raw in lines:
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        data[key.strip()] = value.strip().strip('"').strip("'")
    return data

def read_json(candidate: Path) -> dict:
    try:
        payload = json.loads(candidate.read_text(encoding="utf-8", errors="ignore"))
    except Exception:
        return {}
    return payload if isinstance(payload, dict) else {}

def norm_date(value: object) -> str:
    text = str(value or "").strip()
    return text[:10] if text else "-"

payload = read_json(path)
username = str(payload.get("username") or path.stem).strip().replace("@openvpn", "")
if "@" in username:
    username = username.split("@", 1)[0]
if not username:
    raise SystemExit(0)

cfg = read_env_map(cfg_path)
ssh_root = Path(str(cfg.get("OPENVPN_SSH_STATE_DIR") or "/opt/quota/ssh").strip() or "/opt/quota/ssh")
source = {}
for candidate in (ssh_root / f"{username}@ssh.json", ssh_root / f"{username}.json"):
    if candidate.is_file():
        source = read_json(candidate)
        if source:
            break
if not source:
    raise SystemExit(0)

changed = False
created_at = str(source.get("created_at") or payload.get("created_at") or "-").strip() or "-"
if str(payload.get("created_at") or "").strip() != created_at:
    payload["created_at"] = created_at
    changed = True

expired_at = norm_date(source.get("expired_at"))
if str(payload.get("expired_at") or "").strip() != expired_at:
    payload["expired_at"] = expired_at
    changed = True

if not changed:
    raise SystemExit(0)

path.parent.mkdir(parents=True, exist_ok=True)
fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
with os.fdopen(fd, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, ensure_ascii=True, indent=2)
    handle.write("\n")
os.chmod(tmp, 0o600)
os.replace(tmp, path)
PY
}

openvpn_qac_need_manage_bin() {
  [[ -x "${OPENVPN_MANAGE_BIN}" ]] || {
    warn "Binary OpenVPN manage tidak ditemukan: ${OPENVPN_MANAGE_BIN}"
    return 1
  }
}

openvpn_qac_ensure_policy_for_user() {
  local username="${1:-}"
  [[ -n "${username}" ]] || return 1
  openvpn_qac_need_manage_bin || return 1
  "${OPENVPN_MANAGE_BIN}" --config "${OPENVPN_CONFIG_ENV_FILE}" ensure-user --username "${username}" >/dev/null 2>&1
}

openvpn_qac_collect_files() {
  local root path
  root="$(openvpn_qac_state_root_get)"
  OPENVPN_QAC_FILES=()
  [[ -d "${root}" ]] || return 0
  while IFS= read -r -d '' path; do
    openvpn_qac_sync_metadata_file "${path}" >/dev/null 2>&1 || true
    OPENVPN_QAC_FILES+=("${path}")
  done < <(find "${root}" -maxdepth 1 -type f -name '*.json' -print0 2>/dev/null | sort -z)
}

openvpn_qac_build_view_indexes() {
  local idx file stem username query
  OPENVPN_QAC_VIEW_INDEXES=()
  query="$(printf '%s' "${OPENVPN_QAC_QUERY:-}" | tr '[:upper:]' '[:lower:]')"
  for idx in "${!OPENVPN_QAC_FILES[@]}"; do
    file="${OPENVPN_QAC_FILES[$idx]}"
    stem="$(basename "${file}" .json)"
    username="${stem%@openvpn}"
    username="${username%%@*}"
    if [[ -n "${query}" ]]; then
      if [[ "${username,,}" != *"${query}"* ]]; then
        continue
      fi
    fi
    OPENVPN_QAC_VIEW_INDEXES+=("${idx}")
  done
}

openvpn_qac_total_pages_for_indexes() {
  local total="${#OPENVPN_QAC_VIEW_INDEXES[@]}"
  if (( total <= 0 )); then
    printf '1\n'
    return 0
  fi
  printf '%s\n' $(( (total + 9) / 10 ))
}

openvpn_qac_print_table_page() {
  local page="${1:-0}"
  local total="${#OPENVPN_QAC_VIEW_INDEXES[@]}"
  local pages start end index
  local -a selected_files=()
  pages="$(openvpn_qac_total_pages_for_indexes)"
  (( page < 0 )) && page=0
  if (( total == 0 )); then
    echo "Belum ada state OpenVPN QAC."
    echo "Gunakan 'bootstrap' untuk membuat state dari user SSH yang sudah ada."
    return 0
  fi
  if (( page >= pages )); then
    page=$((pages - 1))
  fi
  start=$(( page * 10 ))
  end=$(( start + 10 ))
  (( end > total )) && end="${total}"
  for index in "${OPENVPN_QAC_VIEW_INDEXES[@]:start:end-start}"; do
    selected_files+=("${OPENVPN_QAC_FILES[$index]}")
  done

  python3 - "${start}" "${selected_files[@]}" <<'PY'
import json
import sys
from pathlib import Path

def fmt_bytes(value):
    try:
        num = int(float(value))
    except Exception:
        num = 0
    if num <= 0:
        return "0 B"
    units = ("B", "KiB", "MiB", "GiB", "TiB")
    value_f = float(num)
    idx = 0
    while value_f >= 1024.0 and idx < len(units) - 1:
        value_f /= 1024.0
        idx += 1
    if idx == 0:
        return f"{int(value_f)} {units[idx]}"
    return f"{value_f:.1f} {units[idx]}"

start = int(sys.argv[1])
items = sys.argv[2:]
rows = []
for pos, path_str in enumerate(items, start=1):
    path = Path(path_str)
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        payload = {}
    status = payload.get("status") if isinstance(payload.get("status"), dict) else {}
    username = str(payload.get("username") or path.stem).strip()
    quota_limit = fmt_bytes(payload.get("quota_limit", 0))
    quota_used = fmt_bytes(payload.get("quota_used", 0))
    expired_at = str(payload.get("expired_at") or "-").strip()[:10] or "-"
    ip_enabled = bool(status.get("ip_limit_enabled"))
    try:
        ip_limit = max(0, int(float(status.get("ip_limit") or 0)))
    except Exception:
        ip_limit = 0
    ip_disp = f"ON({ip_limit})" if ip_enabled and ip_limit > 0 else ("ON" if ip_enabled else "OFF")
    speed_enabled = bool(status.get("speed_limit_enabled"))
    try:
        down = max(0.0, float(status.get("speed_down_mbit") or 0.0))
        up = max(0.0, float(status.get("speed_up_mbit") or 0.0))
    except Exception:
        down = 0.0
        up = 0.0
    speed_disp = f"ON({down:g}/{up:g})" if speed_enabled else "OFF"
    reason = str(status.get("lock_reason") or "").strip().lower()
    if bool(status.get("quota_exhausted")):
        reason = "quota"
    elif bool(status.get("manual_block")):
        reason = "manual"
    elif bool(status.get("ip_limit_locked")):
        reason = "ip_limit"
    reason_disp = reason or "-"
    rows.append((start + pos, username, quota_limit, quota_used, expired_at, ip_disp, speed_disp, reason_disp))

headers = ("No", "Username", "Quota", "Used", "Expired", "IP Limit", "Speed", "Lock")
widths = [len(h) for h in headers]
for row in rows:
    for idx, col in enumerate(row):
        widths[idx] = max(widths[idx], len(str(col)))

fmt = "  ".join("{:<" + str(w) + "}" for w in widths)
print(fmt.format(*headers))
print("  ".join("-" * w for w in widths))
for row in rows:
    print(fmt.format(*row))
PY
  echo
  echo "Page $((page + 1))/${pages} | total user: ${total}"
}

openvpn_qac_state_file_for_user() {
  local username="${1:-}"
  local root
  root="$(openvpn_qac_state_root_get)"
  printf '%s\n' "${root}/${username}@openvpn.json"
}

openvpn_qac_atomic_update_file() {
  local qf="${1:-}"
  local action="${2:-}"
  shift 2 || true
  need_python3
  python3 - "${qf}" "${action}" "$@" <<'PY'
import json
import os
import sys
import tempfile
from pathlib import Path

path = Path(sys.argv[1])
action = sys.argv[2]
args = sys.argv[3:]

def to_int(v, default=0):
    try:
        if v is None:
            return default
        if isinstance(v, bool):
            return int(v)
        return int(float(str(v).strip()))
    except Exception:
        return default

def to_float(v, default=0.0):
    try:
        if v is None:
            return default
        if isinstance(v, bool):
            return float(int(v))
        return float(str(v).strip())
    except Exception:
        return default

def to_bool(v):
    if isinstance(v, bool):
        return v
    return str(v or "").strip().lower() in ("1", "true", "yes", "on", "y")

try:
    payload = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    payload = {}
if not isinstance(payload, dict):
    payload = {}
status = payload.get("status")
if not isinstance(status, dict):
    status = {}

payload["managed_by"] = "autoscript-manage"
payload["protocol"] = "openvpn"
payload["username"] = str(payload.get("username") or path.stem).strip().replace("@openvpn", "")
payload["created_at"] = str(payload.get("created_at") or "-").strip() or "-"
payload["expired_at"] = str(payload.get("expired_at") or "-").strip()[:10] or "-"
payload["quota_limit"] = max(0, to_int(payload.get("quota_limit"), 0))
payload["quota_unit"] = str(payload.get("quota_unit") or "binary").strip().lower() or "binary"
payload["quota_used"] = max(0, to_int(payload.get("quota_used"), 0))

status.setdefault("manual_block", False)
status.setdefault("quota_exhausted", False)
status.setdefault("ip_limit_enabled", False)
status.setdefault("ip_limit", 0)
status.setdefault("ip_limit_locked", False)
status.setdefault("ip_limit_metric", 0)
status.setdefault("distinct_ip_count", 0)
status.setdefault("distinct_ips", [])
status.setdefault("active_sessions_total", 0)
status.setdefault("active_sessions_openvpn", 0)
status.setdefault("distinct_ip_count_openvpn", 0)
status.setdefault("distinct_ips_openvpn", [])
status.setdefault("speed_limit_enabled", False)
status.setdefault("speed_down_mbit", 0.0)
status.setdefault("speed_up_mbit", 0.0)
status.setdefault("lock_reason", "")
status.setdefault("account_locked", False)
status.setdefault("lock_owner", "")
status.setdefault("lock_shell_restore", "")

if action == "set_quota_limit":
    if len(args) != 1:
        raise SystemExit("set_quota_limit butuh 1 argumen")
    payload["quota_limit"] = max(0, to_int(args[0], 0))
elif action == "reset_quota_used":
    payload["quota_used"] = 0
    status["quota_exhausted"] = False
elif action == "manual_block_set":
    if len(args) != 1:
        raise SystemExit("manual_block_set butuh 1 argumen (on/off)")
    status["manual_block"] = to_bool(args[0])
elif action == "ip_limit_enabled_set":
    if len(args) != 1:
        raise SystemExit("ip_limit_enabled_set butuh 1 argumen (on/off)")
    enabled = to_bool(args[0])
    status["ip_limit_enabled"] = enabled
    if not enabled:
        status["ip_limit_locked"] = False
elif action == "set_ip_limit":
    if len(args) != 1:
        raise SystemExit("set_ip_limit butuh 1 argumen")
    status["ip_limit"] = max(0, to_int(args[0], 0))
elif action == "clear_ip_limit_locked":
    status["ip_limit_locked"] = False
elif action == "set_speed_down":
    if len(args) != 1:
        raise SystemExit("set_speed_down butuh 1 argumen")
    value = max(0.0, to_float(args[0], 0.0))
    if value <= 0:
        raise SystemExit("set_speed_down harus > 0")
    status["speed_down_mbit"] = value
elif action == "set_speed_up":
    if len(args) != 1:
        raise SystemExit("set_speed_up butuh 1 argumen")
    value = max(0.0, to_float(args[0], 0.0))
    if value <= 0:
        raise SystemExit("set_speed_up harus > 0")
    status["speed_up_mbit"] = value
elif action == "speed_limit_enabled_set":
    if len(args) != 1:
        raise SystemExit("speed_limit_enabled_set butuh 1 argumen (on/off)")
    enabled = to_bool(args[0])
    if enabled:
        down = max(0.0, to_float(status.get("speed_down_mbit"), 0.0))
        up = max(0.0, to_float(status.get("speed_up_mbit"), 0.0))
        if down <= 0 or up <= 0:
            raise SystemExit("Set speed down/up > 0 dulu sebelum ON.")
    status["speed_limit_enabled"] = enabled
elif action == "set_speed_all_enable":
    if len(args) != 2:
        raise SystemExit("set_speed_all_enable butuh 2 argumen")
    down = max(0.0, to_float(args[0], 0.0))
    up = max(0.0, to_float(args[1], 0.0))
    if down <= 0 or up <= 0:
        raise SystemExit("set_speed_all_enable butuh speed down/up > 0")
    status["speed_down_mbit"] = down
    status["speed_up_mbit"] = up
    status["speed_limit_enabled"] = True
else:
    raise SystemExit(f"action tidak dikenal: {action}")

payload["quota_limit"] = max(0, to_int(payload.get("quota_limit"), 0))
payload["quota_used"] = max(0, to_int(payload.get("quota_used"), 0))
status["ip_limit"] = max(0, to_int(status.get("ip_limit"), 0))
status["speed_down_mbit"] = max(0.0, to_float(status.get("speed_down_mbit"), 0.0))
status["speed_up_mbit"] = max(0.0, to_float(status.get("speed_up_mbit"), 0.0))

reason = ""
if bool(status.get("quota_exhausted")):
    reason = "quota"
elif bool(status.get("manual_block")):
    reason = "manual"
elif bool(status.get("ip_limit_locked")):
    reason = "ip_limit"
status["lock_reason"] = reason
status["account_locked"] = bool(reason)
payload["status"] = status

path.parent.mkdir(parents=True, exist_ok=True)
fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
with os.fdopen(fd, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, ensure_ascii=True, indent=2)
    handle.write("\n")
os.chmod(tmp, 0o600)
os.replace(tmp, path)
PY
}

openvpn_qac_enforce_now_user() {
  local username="${1:-}"
  [[ -n "${username}" ]] || return 1
  if [[ ! -x "/usr/local/bin/sshws-qac-enforcer" ]]; then
    warn "sshws-qac-enforcer tidak ditemukan."
    return 1
  fi
  /usr/local/bin/sshws-qac-enforcer --once --user "${username}" >/dev/null 2>&1
}

openvpn_qac_refresh_runtime() {
  if have_cmd systemctl; then
    systemctl start openvpn-speed-reconcile.service >/dev/null 2>&1 || true
  fi
}

openvpn_qac_apply_with_runtime() {
  local username="${1:-}"
  local qf="${2:-}"
  local backup=""
  shift 2 || true
  backup="$(mktemp "$(dirname "${qf}")/.$(basename "${qf}").rollback.XXXXXX" 2>/dev/null || true)"
  [[ -n "${backup}" ]] || return 1
  cp -f -- "${qf}" "${backup}" >/dev/null 2>&1 || {
    rm -f -- "${backup}" >/dev/null 2>&1 || true
    return 1
  }
  if ! openvpn_qac_atomic_update_file "${qf}" "$@"; then
    rm -f -- "${backup}" >/dev/null 2>&1 || true
    return 1
  fi
  if ! openvpn_qac_enforce_now_user "${username}"; then
    install -m 600 "${backup}" "${qf}" >/dev/null 2>&1 || cp -f -- "${backup}" "${qf}" >/dev/null 2>&1 || true
    openvpn_qac_enforce_now_user "${username}" >/dev/null 2>&1 || true
    openvpn_qac_refresh_runtime
    rm -f -- "${backup}" >/dev/null 2>&1 || true
    return 1
  fi
  openvpn_qac_refresh_runtime
  rm -f -- "${backup}" >/dev/null 2>&1 || true
  return 0
}

openvpn_qac_show_detail() {
  local username="${1:-}"
  local qf="${2:-}"
  [[ -f "${qf}" ]] || return 1
  openvpn_qac_sync_metadata_file "${qf}" >/dev/null 2>&1 || true
  python3 - "${qf}" <<'PY'
import json
import sys
from pathlib import Path

def fmt_bytes(value):
    try:
        num = int(float(value))
    except Exception:
        num = 0
    if num <= 0:
        return "0 B"
    units = ("B", "KiB", "MiB", "GiB", "TiB")
    value_f = float(num)
    idx = 0
    while value_f >= 1024.0 and idx < len(units) - 1:
        value_f /= 1024.0
        idx += 1
    if idx == 0:
        return f"{int(value_f)} {units[idx]}"
    return f"{value_f:.2f} {units[idx]}"

path = Path(sys.argv[1])
try:
    payload = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    payload = {}
status = payload.get("status") if isinstance(payload.get("status"), dict) else {}

username = str(payload.get("username") or path.stem).strip()
quota_limit = fmt_bytes(payload.get("quota_limit", 0))
quota_used = fmt_bytes(payload.get("quota_used", 0))
created_at = str(payload.get("created_at") or "-").strip() or "-"
expired_at = str(payload.get("expired_at") or "-").strip() or "-"
ip_enabled = bool(status.get("ip_limit_enabled"))
try:
    ip_limit = max(0, int(float(status.get("ip_limit") or 0)))
except Exception:
    ip_limit = 0
try:
    ip_metric = max(0, int(float(status.get("ip_limit_metric") or 0)))
except Exception:
    ip_metric = 0
speed_enabled = bool(status.get("speed_limit_enabled"))
try:
    down = max(0.0, float(status.get("speed_down_mbit") or 0.0))
    up = max(0.0, float(status.get("speed_up_mbit") or 0.0))
except Exception:
    down = 0.0
    up = 0.0
lock_reason = str(status.get("lock_reason") or "").strip() or "-"
lines = [
    f"{'Username':<16} : {username}",
    f"{'Created At':<16} : {created_at}",
    f"{'Expired At':<16} : {expired_at}",
    f"{'Quota Limit':<16} : {quota_limit}",
    f"{'Quota Used':<16} : {quota_used}",
    f"{'Quota Exhausted':<16} : {'ON' if bool(status.get('quota_exhausted')) else 'OFF'}",
    f"{'Manual Block':<16} : {'ON' if bool(status.get('manual_block')) else 'OFF'}",
    f"{'IP Limit':<16} : {'ON' if ip_enabled else 'OFF'}" + (f" ({ip_limit})" if ip_enabled and ip_limit > 0 else ""),
    f"{'IP Metric':<16} : {ip_metric}",
    f"{'IP Locked':<16} : {'ON' if bool(status.get('ip_limit_locked')) else 'OFF'}",
    f"{'Speed Limit':<16} : {'ON' if speed_enabled else 'OFF'}" + (f" ({down:g}/{up:g} Mbps)" if speed_enabled else ""),
    f"{'Lock Reason':<16} : {lock_reason}",
    f"{'Account Locked':<16} : {'ON' if bool(status.get('account_locked')) else 'OFF'}",
    f"{'Active Session':<16} : {int(status.get('active_sessions_openvpn') or 0)}",
    f"{'Distinct IP':<16} : {int(status.get('distinct_ip_count_openvpn') or 0)}",
]
print("\n".join(lines))
PY
  if openvpn_qac_need_manage_bin; then
    local info_json=""
    info_json="$("${OPENVPN_MANAGE_BIN}" --config "${OPENVPN_CONFIG_ENV_FILE}" linked-info --username "${username}" 2>/dev/null || true)"
    if [[ -n "${info_json}" ]]; then
      echo
      python3 - <<'PY' "${info_json}"
import json
import sys
try:
    payload = json.loads(sys.argv[1])
except Exception:
    payload = {}
ports = payload.get("tcp_ports") if isinstance(payload.get("tcp_ports"), list) else []
ports_disp = ", ".join(str(p) for p in ports) if ports else "-"
print(f"{'Policy Scope':<16} : {payload.get('policy_scope') or '-'}")
print(f"{'Session Policy':<16} : {payload.get('session_policy') or '-'}")
print(f"{'Host':<16} : {payload.get('host') or '-'}")
print(f"{'TCP Ports':<16} : {ports_disp}")
print(f"{'Profile Path':<16} : {payload.get('profile_path') or '-'}")
print(f"{'Download Link':<16} : {payload.get('download_link') or '-'}")
PY
    fi
  fi
}

openvpn_qac_manage_user_menu() {
  local username="${1:-}"
  local qf="${2:-}"
  local c="" qb="" lim="" speed_down_input="" speed_up_input=""
  while true; do
    ui_menu_screen_begin "OpenVPN QAC · ${username}"
    openvpn_qac_show_detail "${username}" "${qf}"
    hr
    echo "1) Set Quota"
    echo "2) Reset Used"
    echo "3) Block / Unblock"
    echo "4) Toggle IP Limit"
    echo "5) Set IP Limit"
    echo "6) Unlock IP Lock"
    echo "7) Set Speed Down"
    echo "8) Set Speed Up"
    echo "9) Toggle Speed"
    echo "0) Back"
    hr
    if ! read -r -p "Pilih: " c; then
      echo
      break
    fi
    case "${c}" in
      1)
        if ! read -r -p "Quota limit (GB biner, angka) (atau kembali): " qb; then
          echo
          break
        fi
        is_back_choice "${qb}" && continue
        if [[ -z "${qb}" || ! "${qb}" =~ ^[0-9]+$ ]]; then
          warn "Quota harus angka bulat."
          sleep 1
          continue
        fi
        qb=$(( qb * 1024 * 1024 * 1024 ))
        if ! openvpn_qac_apply_with_runtime "${username}" "${qf}" set_quota_limit "${qb}"; then
          warn "Gagal set quota OpenVPN."
        else
          log "Quota OpenVPN diperbarui."
        fi
        pause
        ;;
      2)
        if ! openvpn_qac_apply_with_runtime "${username}" "${qf}" reset_quota_used; then
          warn "Gagal reset quota used OpenVPN."
        else
          log "Quota used OpenVPN direset."
        fi
        pause
        ;;
      3)
        local block_on="false"
        block_on="$(python3 - "${qf}" <<'PY'
import json, sys
try:
    payload = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    payload = {}
status = payload.get("status") if isinstance(payload.get("status"), dict) else {}
print("true" if bool(status.get("manual_block")) else "false")
PY
)"
        if [[ "${block_on}" == "true" ]]; then
          if ! openvpn_qac_apply_with_runtime "${username}" "${qf}" manual_block_set off; then
            warn "Gagal menonaktifkan manual block OpenVPN."
          else
            log "Manual block OpenVPN: OFF"
          fi
        else
          if ! openvpn_qac_apply_with_runtime "${username}" "${qf}" manual_block_set on; then
            warn "Gagal mengaktifkan manual block OpenVPN."
          else
            log "Manual block OpenVPN: ON"
          fi
        fi
        pause
        ;;
      4)
        local ip_on="false"
        ip_on="$(python3 - "${qf}" <<'PY'
import json, sys
try:
    payload = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    payload = {}
status = payload.get("status") if isinstance(payload.get("status"), dict) else {}
print("true" if bool(status.get("ip_limit_enabled")) else "false")
PY
)"
        if [[ "${ip_on}" == "true" ]]; then
          if ! openvpn_qac_apply_with_runtime "${username}" "${qf}" ip_limit_enabled_set off; then
            warn "Gagal menonaktifkan IP limit OpenVPN."
          else
            log "IP limit OpenVPN: OFF"
          fi
        else
          if ! openvpn_qac_apply_with_runtime "${username}" "${qf}" ip_limit_enabled_set on; then
            warn "Gagal mengaktifkan IP limit OpenVPN."
          else
            log "IP limit OpenVPN: ON"
          fi
        fi
        pause
        ;;
      5)
        if ! read -r -p "IP limit OpenVPN (angka) (atau kembali): " lim; then
          echo
          break
        fi
        is_back_choice "${lim}" && continue
        if [[ -z "${lim}" || ! "${lim}" =~ ^[0-9]+$ || "${lim}" -le 0 ]]; then
          warn "IP limit harus angka > 0."
          sleep 1
          continue
        fi
        if ! openvpn_qac_apply_with_runtime "${username}" "${qf}" set_ip_limit "${lim}"; then
          warn "Gagal set IP limit OpenVPN."
        else
          log "IP limit OpenVPN diperbarui."
        fi
        pause
        ;;
      6)
        if ! openvpn_qac_apply_with_runtime "${username}" "${qf}" clear_ip_limit_locked; then
          warn "Gagal unlock IP lock OpenVPN."
        else
          log "IP lock OpenVPN dibuka."
        fi
        pause
        ;;
      7)
        if ! read -r -p "Speed download (Mbps) (atau kembali): " speed_down_input; then
          echo
          break
        fi
        is_back_choice "${speed_down_input}" && continue
        if [[ -z "${speed_down_input}" || ! "${speed_down_input}" =~ ^[0-9]+([.][0-9]+)?$ ]] \
          || ! awk -v value="${speed_down_input}" 'BEGIN { exit !(value + 0 > 0) }'; then
          warn "Speed download harus angka > 0."
          sleep 1
          continue
        fi
        if ! openvpn_qac_apply_with_runtime "${username}" "${qf}" set_speed_down "${speed_down_input}"; then
          warn "Gagal set speed download OpenVPN."
        else
          log "Speed download OpenVPN diperbarui."
        fi
        pause
        ;;
      8)
        if ! read -r -p "Speed upload (Mbps) (atau kembali): " speed_up_input; then
          echo
          break
        fi
        is_back_choice "${speed_up_input}" && continue
        if [[ -z "${speed_up_input}" || ! "${speed_up_input}" =~ ^[0-9]+([.][0-9]+)?$ ]] \
          || ! awk -v value="${speed_up_input}" 'BEGIN { exit !(value + 0 > 0) }'; then
          warn "Speed upload harus angka > 0."
          sleep 1
          continue
        fi
        if ! openvpn_qac_apply_with_runtime "${username}" "${qf}" set_speed_up "${speed_up_input}"; then
          warn "Gagal set speed upload OpenVPN."
        else
          log "Speed upload OpenVPN diperbarui."
        fi
        pause
        ;;
      9)
        local speed_on="false" speed_down_now="0" speed_up_now="0"
        read -r speed_on speed_down_now speed_up_now < <(python3 - "${qf}" <<'PY'
import json, sys
try:
    payload = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    payload = {}
status = payload.get("status") if isinstance(payload.get("status"), dict) else {}
print(
    "true" if bool(status.get("speed_limit_enabled")) else "false",
    str(float(status.get("speed_down_mbit") or 0.0)),
    str(float(status.get("speed_up_mbit") or 0.0)),
)
PY
)
        if [[ "${speed_on}" == "true" ]]; then
          if ! openvpn_qac_apply_with_runtime "${username}" "${qf}" speed_limit_enabled_set off; then
            warn "Gagal menonaktifkan speed limit OpenVPN."
          else
            log "Speed limit OpenVPN: OFF"
          fi
        else
          if ! awk -v down="${speed_down_now}" -v up="${speed_up_now}" 'BEGIN { exit !(down + 0 > 0 && up + 0 > 0) }'; then
            warn "Set speed down/up dulu sebelum mengaktifkan speed limit."
          elif ! openvpn_qac_apply_with_runtime "${username}" "${qf}" set_speed_all_enable "${speed_down_now}" "${speed_up_now}"; then
            warn "Gagal mengaktifkan speed limit OpenVPN."
          else
            log "Speed limit OpenVPN: ON"
          fi
        fi
        pause
        ;;
      0|kembali|k|back|b)
        break
        ;;
      *)
        warn "Pilihan tidak valid"
        sleep 1
        ;;
    esac
  done
}

openvpn_quota_menu() {
  openvpn_qac_state_dirs_prepare
  need_python3
  OPENVPN_QAC_PAGE=0
  OPENVPN_QAC_QUERY=""

  while true; do
    ui_menu_screen_begin "4) OpenVPN QAC"
    openvpn_qac_collect_files
    openvpn_qac_build_view_indexes
    openvpn_qac_print_table_page "${OPENVPN_QAC_PAGE}"
    hr
    echo "Masukkan NO untuk view/edit, atau ketik:"
    echo "  bootstrap) buat state OpenVPN dari user SSH"
    echo "  sync) jalankan enforcement OpenVPN sekarang"
    echo "  search) filter username"
    echo "  clear) hapus filter"
    echo "  next / previous"
    hr
    local c="" username="" qf="" pages=""
    if ! read -r -p "Pilih: " c; then
      echo
      break
    fi
    if is_back_choice "${c}"; then
      break
    fi
    case "${c}" in
      bootstrap)
        if ! read -r -p "Username SSH untuk bootstrap OpenVPN (atau kembali): " username; then
          echo
          break
        fi
        is_back_choice "${username}" && continue
        if ! openvpn_qac_ensure_policy_for_user "${username}"; then
          warn "Bootstrap OpenVPN gagal untuk ${username}."
        else
          log "State OpenVPN siap untuk ${username}."
        fi
        pause
        ;;
      sync)
        if [[ -x "/usr/local/bin/sshws-qac-enforcer" ]]; then
          if ! /usr/local/bin/sshws-qac-enforcer --once >/dev/null 2>&1; then
            warn "Sinkronisasi enforcement OpenVPN gagal."
          else
            openvpn_qac_refresh_runtime
            log "Enforcement OpenVPN selesai."
          fi
        else
          warn "sshws-qac-enforcer tidak ditemukan."
        fi
        pause
        ;;
      next|n)
        pages="$(openvpn_qac_total_pages_for_indexes)"
        if (( pages > 0 && OPENVPN_QAC_PAGE < pages - 1 )); then
          OPENVPN_QAC_PAGE=$((OPENVPN_QAC_PAGE + 1))
        fi
        ;;
      previous|p|prev)
        if (( OPENVPN_QAC_PAGE > 0 )); then
          OPENVPN_QAC_PAGE=$((OPENVPN_QAC_PAGE - 1))
        fi
        ;;
      search)
        if ! read -r -p "Search username (atau kembali): " OPENVPN_QAC_QUERY; then
          echo
          break
        fi
        is_back_choice "${OPENVPN_QAC_QUERY}" && { OPENVPN_QAC_QUERY=""; continue; }
        OPENVPN_QAC_PAGE=0
        ;;
      clear)
        OPENVPN_QAC_QUERY=""
        OPENVPN_QAC_PAGE=0
        ;;
      *)
        if [[ "${c}" =~ ^[0-9]+$ ]]; then
          local wanted=$((c - 1))
          if (( wanted < 0 || wanted >= ${#OPENVPN_QAC_VIEW_INDEXES[@]} )); then
            warn "Nomor tidak ditemukan."
            sleep 1
            continue
          fi
          qf="${OPENVPN_QAC_FILES[${OPENVPN_QAC_VIEW_INDEXES[$wanted]}]}"
          username="$(basename "${qf}" .json)"
          username="${username%@openvpn}"
          username="${username%%@*}"
          openvpn_qac_manage_user_menu "${username}" "${qf}"
        else
          warn "Pilihan tidak valid"
          sleep 1
        fi
        ;;
    esac
  done
}

ssh_openvpn_qac_menu() {
  local -a items=(
    "1|SSH QAC"
    "2|OpenVPN QAC"
    "0|Back"
  )
  while true; do
    ui_menu_screen_begin "4) SSH & OpenVPN QAC"
    ui_menu_render_options items 76
    hr
    if ! read -r -p "Pilih: " c; then
      echo
      break
    fi
    case "${c}" in
      1|ssh|ssh-qac|sshquota) run_action "SSH QAC" ssh_quota_menu ;;
      2|openvpn|ovpn|openvpn-qac|ovpn-qac) run_action "OpenVPN QAC" openvpn_quota_menu ;;
      0|kembali|k|back|b) break ;;
      *) warn "Pilihan tidak valid" ; sleep 1 ;;
    esac
  done
}
