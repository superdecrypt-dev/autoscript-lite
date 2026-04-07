#!/usr/bin/env bash
# shellcheck shell=bash

quota_collect_files() {
  QUOTA_FILES=()
  QUOTA_FILE_PROTOS=()

  local proto dir f base u key email
  declare -A pos=()
  declare -A has_at=()

  for proto in "${QUOTA_PROTO_DIRS[@]}"; do
    dir="${QUOTA_ROOT}/${proto}"
    [[ -d "${dir}" ]] || continue
    while IFS= read -r -d '' f; do
      base="$(basename "${f}")"
      base="${base%.json}"
      if [[ "${base}" == *"@"* ]]; then
        u="${base%%@*}"
      else
        u="${base}"
      fi

      key="${proto}:${u}"

      # Prefer canonical file "username@proto.json" if both variants exist.
      if [[ -n "${pos[${key}]:-}" ]]; then
        if [[ "${base}" == *"@"* && "${has_at[${key}]:-0}" != "1" ]]; then
          QUOTA_FILES[${pos[${key}]}]="${f}"
          QUOTA_FILE_PROTOS[${pos[${key}]}]="${proto}"
          has_at["${key}"]=1
        fi
        continue
      fi

      pos["${key}"]="${#QUOTA_FILES[@]}"
      if [[ "${base}" == *"@"* ]]; then
        has_at["${key}"]=1
      else
        has_at["${key}"]=0
      fi

      QUOTA_FILES+=("${f}")
      QUOTA_FILE_PROTOS+=("${proto}")
    done < <(find "${dir}" -maxdepth 1 -type f -name '*.json' -print0 2>/dev/null | sort -z)
  done

  for proto in "${QUOTA_PROTO_DIRS[@]}"; do
    dir="${ACCOUNT_ROOT}/${proto}"
    [[ -d "${dir}" ]] || continue
    while IFS= read -r -d '' f; do
      base="$(basename "${f}")"
      base="${base%.txt}"
      if [[ "${base}" == *"@"* ]]; then
        u="${base%%@*}"
      else
        u="${base}"
      fi
      [[ -n "${u}" ]] || continue

      key="${proto}:${u}"
      if [[ -n "${pos[${key}]:-}" ]]; then
        continue
      fi

      pos["${key}"]="${#QUOTA_FILES[@]}"
      has_at["${key}"]=1
      QUOTA_FILES+=("${QUOTA_ROOT}/${proto}/${u}@${proto}.json")
      QUOTA_FILE_PROTOS+=("${proto}")
    done < <(find "${dir}" -maxdepth 1 -type f -name '*.txt' -print0 2>/dev/null | sort -z)
  done

  while IFS= read -r email; do
    [[ -n "${email}" && "${email}" == *"@"* ]] || continue
    u="${email%%@*}"
    proto="${email##*@}"
    case "${proto}" in
      vless|vmess|trojan) ;;
      *) continue ;;
    esac

    key="${proto}:${u}"
    if [[ -n "${pos[${key}]:-}" ]]; then
      continue
    fi

    pos["${key}"]="${#QUOTA_FILES[@]}"
    has_at["${key}"]=1
    QUOTA_FILES+=("${QUOTA_ROOT}/${proto}/${u}@${proto}.json")
    QUOTA_FILE_PROTOS+=("${proto}")
  done < <(xray_inbounds_all_client_emails_get 2>/dev/null || true)
}

quota_metadata_bootstrap_if_missing() {
  # args: proto username quota_file
  local proto="$1"
  local username="$2"
  local qf="$3"
  local acc_file

  [[ -n "${proto}" && -n "${username}" && -n "${qf}" ]] || return 1
  [[ -f "${qf}" ]] && return 0

  xray_migrate_user_compat_artifacts_if_needed "${proto}" "${username}"
  acc_file="$(xray_account_info_file_path "${proto}" "${username}")"
  if [[ ! -f "${acc_file}" ]]; then
    warn "Bootstrap quota ${username}@${proto} dibatalkan: XRAY ACCOUNT INFO managed tidak ditemukan."
    return 1
  fi

  need_python3
  python3 - <<'PY' "${qf}" "${acc_file}" "${proto}" "${username}"
import fcntl
import json
import os
import sys
import tempfile
from datetime import datetime

qf, acc_file, proto, username = sys.argv[1:5]
lock_path = qf + ".lock"

payload = {
  "username": f"{username}@{proto}",
  "protocol": proto,
  "bootstrap_review_needed": True,
  "bootstrap_source": "minimal-placeholder",
  "quota_limit": 0,
  "quota_unit": "binary",
  "quota_used": 0,
  "xray_usage_bytes": 0,
  "xray_api_baseline_bytes": 0,
  "xray_usage_carry_bytes": 0,
  "xray_api_last_total_bytes": 0,
  "xray_usage_reset_pending": False,
  "created_at": datetime.now().strftime("%Y-%m-%d"),
  "expired_at": "-",
  "status": {
    "manual_block": False,
    "quota_exhausted": False,
    "ip_limit_enabled": False,
    "ip_limit": 0,
    "speed_limit_enabled": False,
    "speed_down_mbit": 0,
    "speed_up_mbit": 0,
    "ip_limit_locked": False,
    "lock_reason": "",
    "locked_at": "",
  },
}

os.makedirs(os.path.dirname(lock_path) or ".", exist_ok=True)
with open(lock_path, "a+", encoding="utf-8") as lock_handle:
  fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX)
  try:
    if os.path.exists(qf):
      raise SystemExit(0)
    os.makedirs(os.path.dirname(qf) or ".", exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".tmp.", suffix=".json", dir=os.path.dirname(qf) or ".")
    try:
      with os.fdopen(fd, "w", encoding="utf-8") as wf:
        json.dump(payload, wf, ensure_ascii=False, indent=2)
        wf.write("\n")
        wf.flush()
        os.fsync(wf.fileno())
      os.replace(tmp, qf)
      try:
        os.chmod(qf, 0o600)
      except Exception:
        pass
    finally:
      try:
        if os.path.exists(tmp):
          os.remove(tmp)
      except Exception:
        pass
  finally:
    fcntl.flock(lock_handle.fileno(), fcntl.LOCK_UN)
PY
}


quota_total_pages_for_indexes() {
  local total="${#QUOTA_VIEW_INDEXES[@]}"
  if (( total == 0 )); then
    echo 0
    return 0
  fi
  echo $(( (total + QUOTA_PAGE_SIZE - 1) / QUOTA_PAGE_SIZE ))
}

quota_build_view_indexes() {
  # Bangun index view berdasarkan QUOTA_QUERY (case-insensitive, match username/file)
  QUOTA_VIEW_INDEXES=()

  local q
  q="$(echo "${QUOTA_QUERY:-}" | tr '[:upper:]' '[:lower:]')"

  if [[ -z "${q}" ]]; then
    local i
    for i in "${!QUOTA_FILES[@]}"; do
      QUOTA_VIEW_INDEXES+=("${i}")
    done
    return 0
  fi

  local i f proto base u
  for i in "${!QUOTA_FILES[@]}"; do
    f="${QUOTA_FILES[$i]}"
    proto="${QUOTA_FILE_PROTOS[$i]}"
    base="$(basename "${f}")"
    base="${base%.json}"
    if [[ "${base}" == *"@"* ]]; then
      u="${base%%@*}"
    else
      u="${base}"
    fi
    if echo "${u}" | tr '[:upper:]' '[:lower:]' | grep -qF -- "${q}"; then
      QUOTA_VIEW_INDEXES+=("${i}")
      continue
    fi
  done
}

quota_read_summary_fields() {
  # args: json_file
  # prints: username|quota_limit_disp|quota_used_disp|expired_at_date|ip_limit_disp|block_reason|lock_state
  local qf="$1"
  need_python3
  python3 - <<'PY' "${qf}"
import json, pathlib, sys
p=pathlib.Path(sys.argv[1])
username_fallback = p.stem.split("@", 1)[0] if p.stem else "-"
try:
  d=json.load(open(p,'r',encoding='utf-8'))
except Exception:
  print(f"{username_fallback}|0 GB|0 B|-|OFF|-|OFF")
  raise SystemExit(0)
if not isinstance(d, dict):
  print(f"{username_fallback}|0 GB|0 B|-|OFF|-|OFF")
  raise SystemExit(0)

def to_int(v, default=0):
  try:
    if v is None:
      return default
    if isinstance(v, bool):
      return int(v)
    if isinstance(v, (int, float)):
      return int(v)
    s=str(v).strip()
    if s == "":
      return default
    return int(float(s))
  except Exception:
    return default

def fmt_gb(v):
  try:
    n=float(v)
  except Exception:
    n=0.0
  if n < 0:
    n=0.0
  s=f"{n:.3f}".rstrip('0').rstrip('.')
  return s if s else "0"

u=str(d.get("username") or username_fallback or "-")
if "@" in u:
  u=u.split("@", 1)[0]
ql=to_int(d.get("quota_limit"), 0)
qu=to_int(d.get("quota_used"), 0)

# Hormati quota_unit yang tersimpan di file (binary=GiB, decimal=GB)
unit=str(d.get("quota_unit") or "binary").strip().lower()
bpg=1000**3 if unit in ("decimal","gb","1000","gigabyte") else 1024**3
ql_disp=f"{fmt_gb(ql/bpg)} GB"

def used_disp(b):
  try:
    b=int(b)
  except Exception:
    b=0
  if b >= 1024**3:
    return f"{b/(1024**3):.2f} GB"
  if b >= 1024**2:
    return f"{b/(1024**2):.2f} MB"
  if b >= 1024:
    return f"{b/1024:.2f} KB"
  return f"{b} B"

qu_disp=used_disp(qu)

exp=str(d.get("expired_at") or "-")
exp_date=exp[:10] if exp and exp != "-" else "-"

st_raw=d.get("status")
st=st_raw if isinstance(st_raw, dict) else {}
ip_en=bool(st.get("ip_limit_enabled"))
try:
  ip_lim=to_int(st.get("ip_limit"), 0)
except Exception:
  ip_lim=0

ip_str="ON" if ip_en else "OFF"
if ip_en:
  ip_str += f"({ip_lim})" if ip_lim else "(ON)"

lr=str(st.get("lock_reason") or "").strip().lower()
reason="-"
if st.get("manual_block") or lr == "manual":
  reason="MANUAL"
elif st.get("quota_exhausted") or lr == "quota":
  reason="QUOTA"
elif st.get("ip_limit_locked") or lr == "ip_limit":
  reason="IP_LIMIT"

lock_disp="ON" if bool(st.get("account_locked")) else "OFF"
print(f"{u}|{ql_disp}|{qu_disp}|{exp_date}|{ip_str}|{reason}|{lock_disp}")
PY
}

quota_read_detail_fields() {
  # args: json_file
  # prints:
  # username|quota_limit_disp|quota_used_disp|expired_at_date|ip_limit_onoff|ip_limit_value|block_reason|speed_onoff|speed_down_mbit|speed_up_mbit
  local qf="$1"
  need_python3
  python3 - <<'PY' "${qf}"
import json, pathlib, sys
p=pathlib.Path(sys.argv[1])
username_fallback = p.stem.split("@", 1)[0] if p.stem else "-"
try:
  d=json.load(open(p,'r',encoding='utf-8'))
except Exception:
  print(f"{username_fallback}|0 GB|0 B|-|OFF|0|-|OFF|0|0")
  raise SystemExit(0)
if not isinstance(d, dict):
  print(f"{username_fallback}|0 GB|0 B|-|OFF|0|-|OFF|0|0")
  raise SystemExit(0)

def to_int(v, default=0):
  try:
    if v is None:
      return default
    if isinstance(v, bool):
      return int(v)
    if isinstance(v, (int, float)):
      return int(v)
    s=str(v).strip()
    if s == "":
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
    s=str(v).strip()
    if s == "":
      return default
    return float(s)
  except Exception:
    return default

def fmt_gb(v):
  try:
    n=float(v)
  except Exception:
    n=0.0
  if n < 0:
    n=0.0
  s=f"{n:.3f}".rstrip('0').rstrip('.')
  return s if s else "0"

def fmt_mbit(v):
  try:
    n=float(v)
  except Exception:
    n=0.0
  if n < 0:
    n=0.0
  s=f"{n:.3f}".rstrip('0').rstrip('.')
  return s if s else "0"

u=str(d.get("username") or username_fallback or "-")
if "@" in u:
  u=u.split("@", 1)[0]
ql=to_int(d.get("quota_limit"), 0)
qu=to_int(d.get("quota_used"), 0)

# Hormati quota_unit yang tersimpan di file
unit=str(d.get("quota_unit") or "binary").strip().lower()
bpg=1000**3 if unit in ("decimal","gb","1000","gigabyte") else 1024**3
ql_disp=f"{fmt_gb(ql/bpg)} GB"

def used_disp(b):
  try:
    b=int(b)
  except Exception:
    b=0
  if b >= 1024**3:
    return f"{b/(1024**3):.2f} GB"
  if b >= 1024**2:
    return f"{b/(1024**2):.2f} MB"
  if b >= 1024:
    return f"{b/1024:.2f} KB"
  return f"{b} B"

qu_disp=used_disp(qu)

exp=str(d.get("expired_at") or "-")
exp_date=exp[:10] if exp and exp != "-" else "-"

st_raw=d.get("status")
st=st_raw if isinstance(st_raw, dict) else {}
ip_en=bool(st.get("ip_limit_enabled"))
try:
  ip_lim=to_int(st.get("ip_limit"), 0)
except Exception:
  ip_lim=0
if ip_lim < 0:
  ip_lim = 0
lr=str(st.get("lock_reason") or "").strip().lower()
reason="-"
if st.get("manual_block") or lr == "manual":
  reason="MANUAL"
elif st.get("quota_exhausted") or lr == "quota":
  reason="QUOTA"
elif st.get("ip_limit_locked") or lr == "ip_limit":
  reason="IP_LIMIT"

speed_en=bool(st.get("speed_limit_enabled"))
speed_down=to_float(st.get("speed_down_mbit"), 0.0)
speed_up=to_float(st.get("speed_up_mbit"), 0.0)
if speed_down < 0:
  speed_down = 0.0
if speed_up < 0:
  speed_up = 0.0

print(f"{u}|{ql_disp}|{qu_disp}|{exp_date}|{'ON' if ip_en else 'OFF'}|{ip_lim}|{reason}|{'ON' if speed_en else 'OFF'}|{fmt_mbit(speed_down)}|{fmt_mbit(speed_up)}")
PY
}

quota_get_status_bool() {
  # args: json_file key
  local qf="$1"
  local key="$2"
  need_python3
  python3 - <<'PY' "${qf}" "${key}"
import json, sys
p, k = sys.argv[1:3]
try:
  d = json.load(open(p, 'r', encoding='utf-8'))
except Exception:
  print("false")
  raise SystemExit(0)
if not isinstance(d, dict):
  print("false")
  raise SystemExit(0)
st = d.get("status") or {}
if not isinstance(st, dict):
  st = {}
v = st.get(k, False)
print("true" if bool(v) else "false")
PY
}

quota_get_status_int() {
  # args: json_file key
  local qf="$1"
  local key="$2"
  need_python3
  python3 - <<'PY' "${qf}" "${key}"
import json, sys
p, k = sys.argv[1:3]
try:
  d = json.load(open(p, 'r', encoding='utf-8'))
except Exception:
  print("0")
  raise SystemExit(0)
if not isinstance(d, dict):
  print("0")
  raise SystemExit(0)
st = d.get("status") or {}
if not isinstance(st, dict):
  st = {}
v = st.get(k, 0)
try:
  print(int(v))
except Exception:
  print("0")
PY
}

quota_get_status_number() {
  # args: json_file key
  local qf="$1"
  local key="$2"
  need_python3
  python3 - <<'PY' "${qf}" "${key}"
import json, sys
p, k = sys.argv[1:3]
try:
  d = json.load(open(p, 'r', encoding='utf-8'))
except Exception:
  print("0")
  raise SystemExit(0)
if not isinstance(d, dict):
  print("0")
  raise SystemExit(0)
st = d.get("status") or {}
if not isinstance(st, dict):
  st = {}
v = st.get(k, 0)
try:
  n = float(v)
except Exception:
  n = 0.0
if n < 0:
  n = 0.0
s = f"{n:.3f}".rstrip("0").rstrip(".")
print(s if s else "0")
PY
}

quota_get_lock_reason() {
  # args: json_file
  local qf="$1"
  need_python3
  python3 - <<'PY' "${qf}"
import json, sys
p = sys.argv[1]
try:
  d = json.load(open(p, 'r', encoding='utf-8'))
except Exception:
  print("")
  raise SystemExit(0)
if not isinstance(d, dict):
  print("")
  raise SystemExit(0)
st = d.get("status") or {}
if not isinstance(st, dict):
  st = {}
v = st.get("lock_reason") or ""
print(str(v))
PY
}

quota_sync_speed_policy_for_user() {
  # args: proto username quota_file
  local proto="$1"
  local username="$2"
  local qf="$3"

  local speed_on speed_down speed_up mark
  speed_on="$(quota_get_status_bool "${qf}" "speed_limit_enabled")"
  speed_down="$(quota_get_status_number "${qf}" "speed_down_mbit")"
  speed_up="$(quota_get_status_number "${qf}" "speed_up_mbit")"

  if [[ "${speed_on}" == "true" ]]; then
    if ! speed_mbit_is_positive "${speed_down}" || ! speed_mbit_is_positive "${speed_up}"; then
      warn "Speed limit aktif, tapi nilai download/upload belum valid (> 0)."
      return 1
    fi
    if ! mark="$(speed_policy_upsert "${proto}" "${username}" "${speed_down}" "${speed_up}")"; then
      warn "Gagal menyimpan speed policy ${username}@${proto}"
      return 1
    fi
    if ! speed_policy_sync_xray; then
      warn "Gagal sinkronisasi speed policy ke xray"
      return 1
    fi
    if ! speed_policy_apply_now; then
      warn "Speed policy tersimpan, tetapi apply runtime gagal (cek service xray-speed)"
      return 1
    fi
    log "Speed policy aktif untuk ${username}@${proto} (mark=${mark}, down=${speed_down}Mbps, up=${speed_up}Mbps)"
    return 0
  fi

  if speed_policy_exists "${proto}" "${username}"; then
    if ! speed_policy_remove_checked "${proto}" "${username}"; then
      warn "Speed limit dinonaktifkan, tetapi file speed policy gagal dihapus"
      return 1
    fi
    if ! speed_policy_sync_xray; then
      warn "Speed limit dinonaktifkan, tetapi sinkronisasi speed policy ke xray gagal"
      return 1
    fi
    if ! speed_policy_apply_now; then
      warn "Speed limit dinonaktifkan, tetapi apply runtime gagal (cek service xray-speed)"
      return 1
    fi
    return 0
  fi
  if ! speed_policy_apply_now; then
    warn "Speed policy runtime gagal di-refresh (cek service xray-speed)"
    return 1
  fi
  return 0
}



quota_print_table_page() {
  # args: page
  local page="${1:-0}"
  local total="${#QUOTA_VIEW_INDEXES[@]}"
  local pages
  pages="$(quota_total_pages_for_indexes)"

  if (( total == 0 )); then
    echo "Xray accounts: 0 | page 1/1"
    if [[ -n "${QUOTA_QUERY}" ]]; then
      echo "Filter: '${QUOTA_QUERY}'"
    fi
    echo
    echo "Belum ada data Xray QAC."
    return 0
  fi

  if (( page < 0 )); then page=0; fi
  if (( pages > 0 && page >= pages )); then page=$((pages - 1)); fi

  local display_pages=1
  if (( pages > 0 )); then
    display_pages="${pages}"
  fi
  echo "Xray accounts: ${total} | page $((page + 1))/${display_pages}"
  if [[ -n "${QUOTA_QUERY}" ]]; then
    echo "Filter: '${QUOTA_QUERY}'"
  fi
  echo

  local start end i real_idx f proto fields username ql_disp qu_disp exp_date ip_disp block_reason lock_state
  start=$((page * QUOTA_PAGE_SIZE))
  end=$((start + QUOTA_PAGE_SIZE))
  if (( end > total )); then end="${total}"; fi

  printf "%-4s %-8s %-18s %-11s %-11s %-12s %-10s %-6s\n" "NO" "Proto" "Username" "Quota" "Used" "Expired" "IPLimit" "Lock"
  hr

  for (( i=start; i<end; i++ )); do
    real_idx="${QUOTA_VIEW_INDEXES[$i]}"
    f="${QUOTA_FILES[$real_idx]}"
    proto="${QUOTA_FILE_PROTOS[$real_idx]}"

    fields="$(quota_read_summary_fields "${f}")"
    IFS='|' read -r username ql_disp qu_disp exp_date ip_disp block_reason lock_state <<<"${fields}"
    printf "%-4s %-8s %-18s %-11s %-11s %-12s %-10s %-6s\n" \
      "$((i - start + 1))" \
      "${proto}" \
      "${username}" \
      "${ql_disp}" \
      "${qu_disp}" \
      "${exp_date}" \
      "${ip_disp}" \
      "${lock_state}"

  done

  echo
  echo "Halaman: $((page + 1))/${pages}  | Total metadata: ${total}"
  if (( pages > 1 )); then
    echo "Ketik: next / previous / search / clear / kembali"
  fi
}

quota_atomic_update_file() {
  # args: json_file action [action_args...]
  # Security hardening:
  # - Tidak lagi menjalankan python `exec()` dari string dinamis.
  # - Update dibatasi ke action yang sudah di-whitelist.
  local qf="$1"
  local action="${2:-}"
  local lockf="${qf}.lock"
  shift 2 || true
  need_python3

  python3 - "${qf}" "${lockf}" "${action}" "$@" <<'PY'
import fcntl
import json
import os
import re
import shutil
import sys
import tempfile
from datetime import datetime

p = sys.argv[1]
lock_path = sys.argv[2]
action = sys.argv[3]
args = sys.argv[4:]
backup_path = str(os.environ.get("QUOTA_ATOMIC_BACKUP_FILE") or "").strip()

os.makedirs(os.path.dirname(lock_path) or ".", exist_ok=True)

def now_iso():
  return datetime.now().strftime("%Y-%m-%d %H:%M")

def to_bool(raw):
  if isinstance(raw, bool):
    return raw
  if isinstance(raw, (int, float)):
    return bool(raw)
  return str(raw or "").strip().lower() in ("1", "true", "yes", "on", "y")

def parse_onoff(raw):
  v = str(raw or "").strip().lower()
  if v in ("on", "true", "1", "yes"):
    return True
  if v in ("off", "false", "0", "no"):
    return False
  raise SystemExit(f"aksi {action}: nilai on/off tidak valid: {raw}")

def parse_int(raw, name, min_value=None):
  try:
    val = int(float(str(raw).strip()))
  except Exception:
    raise SystemExit(f"aksi {action}: {name} harus angka")
  if min_value is not None and val < min_value:
    raise SystemExit(f"aksi {action}: {name} minimal {min_value}")
  return val

def parse_float(raw, name, min_value=None):
  try:
    val = float(str(raw).strip())
  except Exception:
    raise SystemExit(f"aksi {action}: {name} harus angka")
  if min_value is not None and val < min_value:
    raise SystemExit(f"aksi {action}: {name} minimal {min_value}")
  return val

def ensure_status(meta):
  st = meta.get("status")
  if not isinstance(st, dict):
    st = {}
    meta["status"] = st
  return st

def recompute_lock_reason(st):
  mb = bool(st.get("manual_block"))
  qe = bool(st.get("quota_exhausted"))
  il = bool(st.get("ip_limit_locked"))

  if mb:
    lr = "manual"
  elif qe:
    lr = "quota"
  elif il:
    lr = "ip_limit"
  else:
    lr = ""

  st["lock_reason"] = lr
  if lr:
    st["locked_at"] = str(st.get("locked_at") or now_iso())
  else:
    st["locked_at"] = ""

def recompute_limit_flags(meta, st):
  quota_limit = parse_int(meta.get("quota_limit", 0), "quota_limit", 0)
  quota_used = parse_int(meta.get("quota_used", 0), "quota_used", 0)
  st["quota_exhausted"] = bool(quota_limit > 0 and quota_used >= quota_limit)

  ip_enabled = bool(st.get("ip_limit_enabled"))
  ip_limit = parse_int(st.get("ip_limit", 0), "ip_limit", 0)
  ip_metric = parse_int(st.get("ip_limit_metric", 0), "ip_limit_metric", 0)
  st["ip_limit_locked"] = bool(ip_enabled and ip_limit > 0 and ip_metric > ip_limit)
  recompute_lock_reason(st)

with open(lock_path, "a+", encoding="utf-8") as lf:
  fcntl.flock(lf.fileno(), fcntl.LOCK_EX)
  try:
    if backup_path:
      os.makedirs(os.path.dirname(backup_path) or ".", exist_ok=True)
      shutil.copy2(p, backup_path)
      try:
        os.chmod(backup_path, 0o600)
      except Exception:
        pass
    with open(p, "r", encoding="utf-8") as f:
      d = json.load(f)
    if not isinstance(d, dict):
      raise SystemExit("quota metadata invalid: root bukan object")

    st = ensure_status(d)
    d["bootstrap_review_needed"] = to_bool(d.get("bootstrap_review_needed"))
    d["bootstrap_source"] = str(d.get("bootstrap_source") or "").strip()

    if action == "set_expired_at":
      if len(args) != 1:
        raise SystemExit("set_expired_at butuh 1 argumen (YYYY-MM-DD)")
      value = str(args[0]).strip()
      if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", value):
        raise SystemExit("set_expired_at: format tanggal wajib YYYY-MM-DD")
      d["expired_at"] = value

    elif action == "clear_quota_exhausted_recompute":
      st["quota_exhausted"] = False
      recompute_lock_reason(st)

    elif action == "set_quota_limit_recompute":
      if len(args) != 1:
        raise SystemExit("set_quota_limit_recompute butuh 1 argumen (bytes)")
      d["quota_limit"] = parse_int(args[0], "quota_limit", 0)
      recompute_limit_flags(d, st)

    elif action == "reset_quota_used_recompute":
      d["quota_used"] = 0
      d["xray_usage_bytes"] = 0
      d["xray_api_last_total_bytes"] = 0
      d["xray_usage_carry_bytes"] = 0
      d["xray_usage_reset_pending"] = True
      st["quota_exhausted"] = False
      recompute_lock_reason(st)

    elif action == "manual_block_set":
      if len(args) != 1:
        raise SystemExit("manual_block_set butuh 1 argumen (on/off)")
      enabled = parse_onoff(args[0])
      st["manual_block"] = bool(enabled)
      if enabled:
        st["lock_reason"] = "manual"
        st["locked_at"] = str(st.get("locked_at") or now_iso())
      else:
        recompute_lock_reason(st)

    elif action == "ip_limit_enabled_set":
      if len(args) != 1:
        raise SystemExit("ip_limit_enabled_set butuh 1 argumen (on/off)")
      enabled = parse_onoff(args[0])
      st["ip_limit_enabled"] = bool(enabled)
      recompute_limit_flags(d, st)

    elif action == "set_ip_limit":
      if len(args) != 1:
        raise SystemExit("set_ip_limit butuh 1 argumen (angka)")
      st["ip_limit"] = parse_int(args[0], "ip_limit", 1)
      recompute_limit_flags(d, st)

    elif action == "clear_ip_limit_locked_recompute":
      st["ip_limit_locked"] = False
      recompute_lock_reason(st)

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

    else:
      raise SystemExit(f"aksi quota_atomic_update_file tidak dikenali: {action}")

    d["bootstrap_review_needed"] = False
    d["bootstrap_source"] = ""

    out = json.dumps(d, ensure_ascii=False, indent=2) + "\n"
    dirn = os.path.dirname(p) or "."
    fd, tmp = tempfile.mkstemp(prefix=".tmp.", suffix=".json", dir=dirn)
    try:
      with os.fdopen(fd, "w", encoding="utf-8") as wf:
        wf.write(out)
        wf.flush()
        os.fsync(wf.fileno())
      os.replace(tmp, p)
    finally:
      try:
        if os.path.exists(tmp):
          os.remove(tmp)
      except Exception:
        pass
  finally:
    fcntl.flock(lf.fileno(), fcntl.LOCK_UN)
PY
  local py_rc=$?
  if (( py_rc != 0 )); then
    return "${py_rc}"
  fi

  chmod 600 "${qf}" 2>/dev/null || true
  return 0
}

quota_view_json() {
  local qf="$1"
  title
  echo "Quota metadata: ${qf}"
  hr
  if [[ ! -f "${qf}" ]]; then
    warn "Quota metadata belum ada untuk target ini."
    echo "Hint: target ini kemungkinan terdeteksi dari runtime/account file drift dan belum punya JSON quota."
    hr
    pause
    return 0
  fi
  need_python3
  if have_cmd less; then
    python3 - <<'PY' "${qf}" | less -R
import json, sys
p=sys.argv[1]
try:
  d=json.load(open(p,'r',encoding='utf-8'))
except Exception:
  print(open(p,'r',encoding='utf-8',errors='replace').read())
  raise SystemExit(0)
exp=d.get("expired_at")
if isinstance(exp, str) and exp:
  d["expired_at"]=exp[:10]
crt=d.get("created_at")
if isinstance(crt, str) and crt:
  s=crt.replace("T"," ").strip()
  if s.endswith("Z"):
    s=s[:-1]
  if len(s)>=10 and s[4:5]=="-" and s[7:8]=="-":
    d["created_at"]=s[:10]
  else:
    d["created_at"]=s
print(json.dumps(d, ensure_ascii=False, indent=2))
PY
  else
    python3 - <<'PY' "${qf}"
import json, sys
p=sys.argv[1]
try:
  d=json.load(open(p,'r',encoding='utf-8'))
except Exception:
  print(open(p,'r',encoding='utf-8',errors='replace').read())
  raise SystemExit(0)
exp=d.get("expired_at")
if isinstance(exp, str) and exp:
  d["expired_at"]=exp[:10]
crt=d.get("created_at")
if isinstance(crt, str) and crt:
  s=crt.replace("T"," ").strip()
  if s.endswith("Z"):
    s=s[:-1]
  if len(s)>=10 and s[4:5]=="-" and s[7:8]=="-":
    d["created_at"]=s[:10]
  else:
    d["created_at"]=s
print(json.dumps(d, ensure_ascii=False, indent=2))
PY
  fi
  hr
  pause
}

quota_bootstrap_status_get() {
  local qf="${1:-}"
  [[ -n "${qf}" && -f "${qf}" ]] || {
    printf 'false|\n'
    return 0
  }
  need_python3
  python3 - <<'PY' "${qf}"
import json
import sys

try:
  data = json.load(open(sys.argv[1], "r", encoding="utf-8"))
except Exception:
  print("false|")
  raise SystemExit(0)

flag = data.get("bootstrap_review_needed")
source = str(data.get("bootstrap_source") or "").strip()
if isinstance(flag, bool):
  needed = flag
elif isinstance(flag, (int, float)):
  needed = bool(flag)
else:
  needed = str(flag or "").strip().lower() in ("1", "true", "yes", "on", "y")
print(("true" if needed else "false") + "|" + source)
PY
}

quota_edit_flow() {
  # args: view_no (1-based pada halaman aktif)
  local view_no="$1"

  [[ "${view_no}" =~ ^[0-9]+$ ]] || { warn "Input bukan angka"; pause; return 0; }
  local total page pages start end rows
  total="${#QUOTA_VIEW_INDEXES[@]}"
  if (( total <= 0 )); then
    warn "Tidak ada data"
    pause
    return 0
  fi
  page="${QUOTA_PAGE:-0}"
  pages=$(( (total + QUOTA_PAGE_SIZE - 1) / QUOTA_PAGE_SIZE ))
  if (( page < 0 )); then page=0; fi
  if (( pages > 0 && page >= pages )); then page=$((pages - 1)); fi
  start=$((page * QUOTA_PAGE_SIZE))
  end=$((start + QUOTA_PAGE_SIZE))
  if (( end > total )); then end="${total}"; fi
  rows=$((end - start))

  if (( view_no < 1 || view_no > rows )); then
    warn "NO di luar range"
    pause
    return 0
  fi

  local list_pos real_idx qf proto
  list_pos=$((start + view_no - 1))
  real_idx="${QUOTA_VIEW_INDEXES[$list_pos]}"
  qf="${QUOTA_FILES[$real_idx]}"
  proto="${QUOTA_FILE_PROTOS[$real_idx]}"
  local qf_base username_hint=""
  qf_base="$(basename "${qf}")"
  qf_base="${qf_base%.json}"
  username_hint="${qf_base%%@*}"

  if [[ ! -f "${qf}" ]]; then
    warn "Quota metadata untuk ${username_hint}@${proto} belum ada."
    echo "Bootstrap akan membuat metadata placeholder minimal:"
    echo "  - quota used = 0"
    echo "  - quota limit = 0"
    echo "  - expired_at = -"
	    echo "  - ip-limit/speed limit = OFF"
	    echo "  - syarat: XRAY ACCOUNT INFO managed harus ada terlebih dahulu"
	    hr
	    if ! confirm_menu_apply_now "Buat metadata quota awal untuk ${username_hint}@${proto} sekarang?"; then
	      pause
	      return 0
	    fi
	    if ! confirm_menu_apply_now "Konfirmasi final: buat placeholder quota metadata baru untuk ${username_hint}@${proto}?"; then
	      pause
	      return 0
	    fi
	    local bootstrap_ack=""
	    read -r -p "Ketik persis 'BOOTSTRAP QUOTA ${username_hint}@${proto}' untuk lanjut bootstrap placeholder (atau kembali): " bootstrap_ack
	    if is_back_choice "${bootstrap_ack}"; then
	      pause
	      return 0
	    fi
	    if [[ "${bootstrap_ack}" != "BOOTSTRAP QUOTA ${username_hint}@${proto}" ]]; then
	      warn "Konfirmasi bootstrap placeholder quota tidak cocok. Dibatalkan."
	      pause
	      return 0
	    fi
	    if ! quota_metadata_bootstrap_if_missing "${proto}" "${username_hint}" "${qf}"; then
	      warn "Gagal membuat metadata quota awal untuk ${username_hint}@${proto}."
	      pause
      return 1
    fi
  fi

  while true; do
    title
    echo "Xray QAC > Detail"
    hr
    echo "Proto : ${proto}"
    echo "File  : ${qf}"
    hr

    local fields username ql_disp qu_disp exp_date ip_state ip_lim block_reason speed_state speed_down speed_up
    fields="$(quota_read_detail_fields "${qf}")"
    IFS='|' read -r username ql_disp qu_disp exp_date ip_state ip_lim block_reason speed_state speed_down speed_up <<<"${fields}"

    # Normalisasi username ke format email (username@proto) untuk routing calls.
    # Metadata historis mungkin hanya menyimpan "alice", bukan "alice@vless".
    local email_for_routing="${username}"
    if [[ "${email_for_routing}" != *"@"* ]]; then
      email_for_routing="${email_for_routing}@${proto}"
    fi
    local speed_username="${username}"
    if [[ "${speed_username}" == *"@"* ]]; then
      speed_username="${speed_username%%@*}"
    fi

    local label_w=14
    printf "%-${label_w}s : %s\n" "Username" "${username}"
    printf "%-${label_w}s : %s\n" "Quota Limit" "${ql_disp}"
    printf "%-${label_w}s : %s\n" "Quota Used" "${qu_disp}"
    printf "%-${label_w}s : %s\n" "Expired At" "${exp_date}"
    printf "%-${label_w}s : %s\n" "IP Limit" "${ip_state}"
    printf "%-${label_w}s : %s\n" "Block Reason" "${block_reason}"
    printf "%-${label_w}s : %s\n" "IP Limit Max" "${ip_lim}"
    printf "%-${label_w}s : %s Mbps\n" "Speed Download" "${speed_down}"
    printf "%-${label_w}s : %s Mbps\n" "Speed Upload" "${speed_up}"
    printf "%-${label_w}s : %s\n" "Speed Limit" "${speed_state}"
    local quota_bootstrap_needed quota_bootstrap_source
    IFS='|' read -r quota_bootstrap_needed quota_bootstrap_source <<<"$(quota_bootstrap_status_get "${qf}")"
    if [[ "${quota_bootstrap_needed}" == "true" ]]; then
      printf "%-${label_w}s : %s\n" "Bootstrap" "PERLU REVIEW"
      [[ -n "${quota_bootstrap_source}" ]] && printf "%-${label_w}s : %s\n" "Source" "${quota_bootstrap_source}"
    fi
    hr

    echo "  1) View JSON"
    echo "  2) Set Quota (GB)"
    echo "  3) Reset Quota"
    echo "  4) Toggle Block"
    echo "  5) Toggle IP Limit"
    echo "  6) Set IP Limit"
    echo "  7) Unlock IP"
    echo "  8) Set Speed Download"
    echo "  9) Set Speed Upload"
    echo " 10) Toggle Speed Limit"
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
        quota_view_json "${qf}"
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
        if ! confirm_menu_apply_now "Set quota limit ${username} ke ${gb_num} GB sekarang?"; then
          pause
          continue
        fi
        local apply_msg=""
        if ! apply_msg="$(xray_qac_atomic_apply "${qf}" "${proto}" "${speed_username}" "${email_for_routing}" false false set_quota_limit_recompute "${qb}")"; then
          warn "Quota limit gagal diterapkan: ${apply_msg}"
          pause
          continue
        fi
        log "Quota limit diubah: ${gb_num} GB"
        pause
        ;;
      3)
        # BUG-06 fix: read mb/il BEFORE resetting qe so lock_reason is computed correctly.
        # BUG-05 fix: correct priority quota > ip_limit.
        if ! confirm_menu_apply_now "Reset quota used ${username} ke 0 sekarang?"; then
          pause
          continue
        fi
        local apply_msg=""
        if ! apply_msg="$(xray_qac_atomic_apply "${qf}" "${proto}" "${speed_username}" "${email_for_routing}" false false reset_quota_used_recompute)"; then
          warn "Reset quota gagal diterapkan: ${apply_msg}"
          pause
          continue
        fi
        log "Quota used di-reset: 0 (status quota dibersihkan)"
        pause
        ;;
      4)
        local st_mb
        st_mb="$(quota_get_status_bool "${qf}" "manual_block")"
        if [[ "${st_mb}" == "true" ]]; then
          if ! confirm_menu_apply_now "Nonaktifkan manual block untuk ${username} sekarang?"; then
            pause
            continue
          fi
          # BUG-06 fix: evaluate qe/il BEFORE setting manual_block=False.
          # Previously mb was read AFTER being set to False, so it was always False
          # and lock_reason could never be 'manual' in this branch.
          # BUG-05 fix applied here too: correct priority is quota > ip_limit (not reversed).
          local apply_msg=""
          if ! apply_msg="$(xray_qac_atomic_apply "${qf}" "${proto}" "${speed_username}" "${email_for_routing}" false false manual_block_set off)"; then
            warn "Manual block OFF gagal diterapkan: ${apply_msg}"
            pause
            continue
          fi
          log "Manual block: OFF"
        else
          if ! confirm_menu_apply_now "Aktifkan manual block untuk ${username} sekarang?"; then
            pause
            continue
          fi
          local apply_msg=""
          if ! apply_msg="$(xray_qac_atomic_apply "${qf}" "${proto}" "${speed_username}" "${email_for_routing}" false false manual_block_set on)"; then
            warn "Manual block ON gagal diterapkan: ${apply_msg}"
            pause
            continue
          fi
          log "Manual block: ON"
        fi
        pause
        ;;
      5)
        local ip_on
        ip_on="$(quota_get_status_bool "${qf}" "ip_limit_enabled")"
        if [[ "${ip_on}" == "true" ]]; then
          if ! confirm_menu_apply_now "Nonaktifkan IP limit untuk ${username} sekarang?"; then
            pause
            continue
          fi
          # BUG-06 fix: read il BEFORE resetting ip_limit_locked, then determine lock_reason.
          # BUG-05 fix: correct priority is quota > ip_limit.
          local apply_msg=""
          if ! apply_msg="$(xray_qac_atomic_apply "${qf}" "${proto}" "${speed_username}" "${email_for_routing}" true false ip_limit_enabled_set off)"; then
            warn "IP limit OFF gagal diterapkan: ${apply_msg}"
            pause
            continue
          fi
          log "IP limit: OFF"
        else
          if ! confirm_menu_apply_now "Aktifkan IP limit untuk ${username} sekarang?"; then
            pause
            continue
          fi
          local apply_msg=""
          if ! apply_msg="$(xray_qac_atomic_apply "${qf}" "${proto}" "${speed_username}" "${email_for_routing}" true false ip_limit_enabled_set on)"; then
            warn "IP limit ON gagal diterapkan: ${apply_msg}"
            pause
            continue
          fi
          log "IP limit: ON"
        fi
        pause
        ;;
      6)
        if ! read -r -p "IP Limit (angka) (atau kembali): " lim; then
          echo
          return 0
        fi
        if is_back_word_choice "${lim}"; then
          continue
        fi
        if [[ -z "${lim}" || ! "${lim}" =~ ^[0-9]+$ || "${lim}" -le 0 ]]; then
          warn "IP limit harus angka > 0"
          pause
          continue
        fi
        if ! confirm_menu_apply_now "Set IP limit ${username} ke ${lim} sekarang?"; then
          pause
          continue
        fi
        local apply_msg=""
        if ! apply_msg="$(xray_qac_atomic_apply "${qf}" "${proto}" "${speed_username}" "${email_for_routing}" true false set_ip_limit "${lim}")"; then
          warn "Set IP limit gagal diterapkan: ${apply_msg}"
          pause
          continue
        fi
        log "IP limit diubah: ${lim}"
        pause
        ;;
      7)
        if ! confirm_menu_apply_now "Unlock IP lock untuk ${username} sekarang?"; then
          pause
          continue
        fi
        local apply_msg=""
        if ! apply_msg="$(xray_qac_unlock_ip_atomic_apply "${qf}" "${proto}" "${speed_username}" "${email_for_routing}")"; then
          warn "Unlock IP lock gagal diterapkan: ${apply_msg}"
          pause
          continue
        fi
        log "IP lock di-unlock"
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
          warn "Speed download tidak valid. Gunakan angka > 0, contoh: 20 atau 20mbit"
          pause
          continue
        fi
        if ! confirm_menu_apply_now "Set speed download ${username} ke ${speed_down_input} Mbps sekarang?"; then
          pause
          continue
        fi
        local apply_msg=""
        if ! apply_msg="$(xray_qac_atomic_apply "${qf}" "${proto}" "${speed_username}" "${email_for_routing}" false true set_speed_down "${speed_down_input}")"; then
          warn "Speed download gagal diterapkan: ${apply_msg}"
          pause
          continue
        fi
        log "Speed download diubah: ${speed_down_input} Mbps"
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
          warn "Speed upload tidak valid. Gunakan angka > 0, contoh: 10 atau 10mbit"
          pause
          continue
        fi
        if ! confirm_menu_apply_now "Set speed upload ${username} ke ${speed_up_input} Mbps sekarang?"; then
          pause
          continue
        fi
        local apply_msg=""
        if ! apply_msg="$(xray_qac_atomic_apply "${qf}" "${proto}" "${speed_username}" "${email_for_routing}" false true set_speed_up "${speed_up_input}")"; then
          warn "Speed upload gagal diterapkan: ${apply_msg}"
          pause
          continue
        fi
        log "Speed upload diubah: ${speed_up_input} Mbps"
        pause
        ;;
      10)
        local speed_on speed_down_now speed_up_now
        speed_on="$(quota_get_status_bool "${qf}" "speed_limit_enabled")"
        if [[ "${speed_on}" == "true" ]]; then
          if ! confirm_menu_apply_now "Nonaktifkan speed limit untuk ${username} sekarang?"; then
            pause
            continue
          fi
          local apply_msg=""
          if ! apply_msg="$(xray_qac_atomic_apply "${qf}" "${proto}" "${speed_username}" "${email_for_routing}" false true speed_limit_set off)"; then
            warn "Speed limit OFF gagal diterapkan: ${apply_msg}"
            pause
            continue
          fi
          log "Speed limit: OFF"
          pause
          continue
        fi

        speed_down_now="$(quota_get_status_number "${qf}" "speed_down_mbit")"
        speed_up_now="$(quota_get_status_number "${qf}" "speed_up_mbit")"

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

        if ! confirm_menu_apply_now "Aktifkan speed limit ${username} dengan DOWN ${speed_down_now} Mbps dan UP ${speed_up_now} Mbps sekarang?"; then
          pause
          continue
        fi
        local apply_msg=""
        if ! apply_msg="$(xray_qac_atomic_apply "${qf}" "${proto}" "${speed_username}" "${email_for_routing}" false true set_speed_all_enable "${speed_down_now}" "${speed_up_now}")"; then
          warn "Speed limit ON gagal diterapkan: ${apply_msg}"
          pause
          continue
        fi
        log "Speed limit: ON"
        pause
        ;;
      *)
        warn "Pilihan tidak valid"
        sleep 1
        ;;
    esac
  done
}

quota_menu() {
  # Minimal: list + search + pagination + view/edit metadata JSON
  ensure_account_quota_dirs
  need_python3

  QUOTA_PAGE=0
  QUOTA_QUERY=""

  while true; do
    ui_menu_screen_begin "2) Xray QAC"

    quota_collect_files
    quota_build_view_indexes
    quota_print_table_page "${QUOTA_PAGE}"
    hr

    echo "Masukkan NO untuk view/edit, atau ketik:"
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
      next|n)
        local pages
        pages="$(quota_total_pages_for_indexes)"
        if (( pages > 0 && QUOTA_PAGE < pages - 1 )); then
          QUOTA_PAGE=$((QUOTA_PAGE + 1))
        fi
        ;;
      previous|p|prev)
        if (( QUOTA_PAGE > 0 )); then
          QUOTA_PAGE=$((QUOTA_PAGE - 1))
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
        QUOTA_QUERY="${q}"
        QUOTA_PAGE=0
        ;;
      clear)
        QUOTA_QUERY=""
        QUOTA_PAGE=0
        ;;
      *)
        if [[ "${c}" =~ ^[0-9]+$ ]]; then
          quota_edit_flow "${c}"
        else
          warn "Pilihan tidak valid"
          sleep 1
        fi
        ;;
    esac
  done
}
