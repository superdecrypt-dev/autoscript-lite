#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2005

# - WARP global: direct / warp
# - WARP: global / per-user / per-protocol (inbound)
# - Domain/Geosite: direct exceptions (editable list, template tetap readonly)
# - Adblock: custom geosite ext:custom.dat:adblock (enable/disable)
# -------------------------
xray_network_menu_title() {
  local suffix="${1:-}"
  local base="5) Xray Network"
  if [[ -n "${suffix}" ]]; then
    printf '%s > %s\n' "${base}" "${suffix}"
  else
    printf '%s\n' "${base}"
  fi
}

warp_tier_menu_title() {
  local suffix="${1:-}"
  local base="13) Tools > WARP Tier"
  if [[ "${WARP_TIER_MENU_CONTEXT:-}" == "xray" ]]; then
    base="5) Xray Network > WARP Controls > WARP Tier"
  fi
  if [[ -n "${suffix}" ]]; then
    printf '%s > %s\n' "${base}" "${suffix}"
  else
    printf '%s\n' "${base}"
  fi
}

warp_tier_free_plus_menu_title() {
  local suffix="${1:-}"
  local base
  base="$(warp_tier_menu_title "Free/Plus")"
  if [[ -n "${suffix}" ]]; then
    printf '%s > %s\n' "${base}" "${suffix}"
  else
    printf '%s\n' "${base}"
  fi
}

warp_tier_zero_trust_menu_title() {
  local suffix="${1:-}"
  local base
  base="$(warp_tier_menu_title "Zero Trust")"
  if [[ -n "${suffix}" ]]; then
    printf '%s > %s\n' "${base}" "${suffix}"
  else
    printf '%s\n' "${base}"
  fi
}

warp_mode_cli_get() {
  warp_mode_state_get
}

warp_mode_display_get() {
  local mode="" live="" target=""
  mode="$(warp_mode_state_get 2>/dev/null || true)"
  case "${mode}" in
    zerotrust)
      printf 'Zero Trust\n'
      return 0
      ;;
  esac

  live="$(warp_live_tier_get 2>/dev/null || true)"
  case "${live}" in
    free)
      printf 'Free\n'
      return 0
      ;;
    plus)
      printf 'Plus\n'
      return 0
      ;;
  esac

  target="$(warp_tier_target_effective_get 2>/dev/null || true)"
  case "${target}" in
    free)
      printf 'Free\n'
      return 0
      ;;
    plus)
      printf 'Plus\n'
      return 0
      ;;
  esac

  printf 'Free/Plus\n'
}

warp_tier_last_verified_get() {
  local last_verified=""
  last_verified="$(network_state_get "warp_tier_last_verified" 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]' || true)"
  case "${last_verified}" in
    free|plus) printf '%s\n' "${last_verified}" ;;
    *) printf '\n' ;;
  esac
}

warp_tier_last_verified_at_get() {
  network_state_get "warp_tier_last_verified_at" 2>/dev/null | tr -d '\r' || true
}

warp_tier_last_verified_age_get() {
  local last_verified_at="${1:-}"
  local now_ts="" verified_ts="" age_sec=""
  [[ -n "${last_verified_at}" ]] || return 0
  have_cmd date || return 0
  now_ts="$(date +%s 2>/dev/null || true)"
  verified_ts="$(date -d "${last_verified_at}" +%s 2>/dev/null || true)"
  if [[ "${now_ts}" =~ ^[0-9]+$ && "${verified_ts}" =~ ^[0-9]+$ && "${now_ts}" -ge "${verified_ts}" ]]; then
    age_sec="$((now_ts - verified_ts))"
    if (( age_sec < 60 )); then
      printf '%ss lalu\n' "${age_sec}"
    elif (( age_sec < 3600 )); then
      printf '%sm lalu\n' "$((age_sec / 60))"
    elif (( age_sec < 86400 )); then
      printf '%sj lalu\n' "$((age_sec / 3600))"
    else
      printf '%sh lalu\n' "$((age_sec / 86400))"
    fi
  fi
}

warp_tier_target_cached_get() {
  local target="" last_verified=""
  target="$(warp_tier_state_target_get 2>/dev/null || true)"
  case "${target}" in
    free|plus)
      printf '%s\n' "${target}"
      return 0
      ;;
  esac
  last_verified="$(warp_tier_last_verified_get)"
  case "${last_verified}" in
    free|plus)
      printf '%s\n' "${last_verified}"
      return 0
      ;;
  esac
  printf 'unknown\n'
}

warp_mode_display_cached_get() {
  local mode="" target=""
  mode="$(warp_mode_state_get 2>/dev/null || true)"
  case "${mode}" in
    zerotrust)
      printf 'Zero Trust\n'
      return 0
      ;;
  esac
  target="$(warp_tier_target_cached_get 2>/dev/null || true)"
  case "${target}" in
    free)
      printf 'Free\n'
      ;;
    plus)
      printf 'Plus\n'
      ;;
    *)
      printf 'Free/Plus\n'
      ;;
  esac
}

adblock_menu_title() {
  local suffix="${1:-}"
  local base="7) Adblocker"
  if [[ -n "${suffix}" ]]; then
    printf '%s > %s\n' "${base}" "${suffix}"
  else
    printf '%s\n' "${base}"
  fi
}

warp_status() {
  local summary_ready="true" backend_svc backend_label mode
  mode="$(warp_mode_state_get)"
  backend_svc="$(warp_backend_service_name_get)"
  backend_label="$(warp_backend_display_name_get)"
  title
  echo "WARP status (${backend_label})"
  hr
  if ! xray_json_file_require_valid "${XRAY_ROUTING_CONF}" "Xray routing config"; then
    summary_ready="false"
  fi
  if ! xray_json_file_require_valid "${XRAY_INBOUNDS_CONF}" "Xray inbounds config" "1"; then
    summary_ready="false"
  fi
  if [[ "${summary_ready}" == "true" ]]; then
    warp_controls_summary || true
    hr
  else
    warn "Ringkasan routing WARP dilewati karena konfigurasi Xray tidak valid."
    hr
  fi
  warp_tier_show_status
  hr
  if svc_exists "${backend_svc}"; then
    systemctl status "${backend_svc}" --no-pager || true
    if [[ "${mode}" == "zerotrust" ]] && have_cmd warp-cli; then
      hr
      printf 'warp-cli status      : %s\n' "$(warp_zero_trust_cli_status_line_get)"
      printf 'warp-cli registration: %s\n' "$(warp_zero_trust_cli_registration_line_get)"
    fi
  else
    warn "${backend_svc} tidak terdeteksi"
  fi
  hr
  pause
}

network_state_file() {
  echo "${WORK_DIR}/network_state.json"
}

network_state_get() {
  # args: key
  local key="$1"
  local f
  f="$(network_state_file)"
  if [[ ! -f "${f}" ]]; then
    return 0
  fi
  python3 - <<'PY' "${f}" "${key}" 2>/dev/null || true
import json, sys
path, key = sys.argv[1:3]
try:
  with open(path,'r',encoding='utf-8') as f:
    d=json.load(f)
except Exception:
  d={}
v=d.get(key)
if v is None:
  raise SystemExit(0)
print(v)
PY
}

network_state_set() {
  # args: key value
  network_state_set_many "$1" "$2"
}

network_state_set_many() {
  # args: key value [key value ...]
  local f tmp rc
  if (( $# < 2 || $# % 2 != 0 )); then
    return 1
  fi
  f="$(network_state_file)"
  tmp="$(mktemp "${WORK_DIR}/.network_state.json.tmp.XXXXXX" 2>/dev/null || true)"
  if [[ -z "${tmp}" ]]; then
    tmp="${WORK_DIR}/network_state.json.tmp.$$"
  fi
  need_python3
  python3 - <<'PY' "${f}" "${tmp}" "$@"
import json, os, sys
path, tmp, *items = sys.argv[1:]
if len(items) % 2 != 0:
  raise SystemExit(2)
d={}
try:
  if os.path.exists(path):
    with open(path,'r',encoding='utf-8') as f:
      d=json.load(f) or {}
except Exception:
  d={}
for i in range(0, len(items), 2):
  d[items[i]] = items[i + 1]
with open(tmp,'w',encoding='utf-8') as f:
  json.dump(d,f,ensure_ascii=False,indent=2)
  f.write("\n")
os.replace(tmp, path)
PY
  rc=$?
  rm -f "${tmp}" 2>/dev/null || true
  if (( rc != 0 )); then
    return "${rc}"
  fi
  chmod 600 "${f}" 2>/dev/null || true
}

warp_mode_state_get() {
  local raw=""
  raw="$(network_state_get "${WARP_MODE_STATE_KEY}" 2>/dev/null || true)"
  raw="$(printf '%s' "${raw}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  case "${raw}" in
    consumer|zerotrust)
      printf '%s\n' "${raw}"
      return 0
      ;;
  esac
  if [[ -f "${WARP_ZEROTRUST_MDM_FILE}" ]] && svc_exists "${WARP_ZEROTRUST_SERVICE}" && svc_is_active "${WARP_ZEROTRUST_SERVICE}"; then
    printf 'zerotrust\n'
  else
    printf 'consumer\n'
  fi
}

warp_mode_state_set() {
  local mode="${1:-}"
  case "${mode}" in
    consumer|zerotrust) ;;
    *) return 1 ;;
  esac
  network_state_set "${WARP_MODE_STATE_KEY}" "${mode}"
}

warp_backend_service_name_get() {
  case "$(warp_mode_state_get)" in
    zerotrust) printf '%s\n' "${WARP_ZEROTRUST_SERVICE}" ;;
    *) printf 'wireproxy\n' ;;
  esac
}

warp_backend_display_name_get() {
  case "$(warp_mode_state_get)" in
    zerotrust) printf 'cloudflare-warp\n' ;;
    *) printf 'wireproxy\n' ;;
  esac
}

warp_proxy_bind_address_get() {
  local mode bind_addr
  mode="$(warp_mode_state_get)"
  if [[ "${mode}" == "zerotrust" ]]; then
    printf '127.0.0.1:%s\n' "$(warp_zero_trust_proxy_port_get)"
    return 0
  fi
  bind_addr="$(awk -F'=' '
    /^[[:space:]]*BindAddress[[:space:]]*=/ {
      v=$2
      gsub(/[[:space:]]/, "", v)
      print v
      exit
    }
  ' "${WIREPROXY_CONF}" 2>/dev/null || true)"
  [[ -n "${bind_addr}" ]] || bind_addr="127.0.0.1:40000"
  printf '%s\n' "${bind_addr}"
}

warp_proxy_port_get() {
  local bind_addr port
  bind_addr="$(warp_proxy_bind_address_get)"
  port="${bind_addr##*:}"
  if [[ "${port}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "${port}"
  else
    printf '40000\n'
  fi
}

warp_port_is_listening() {
  local port="${1:-}"
  [[ "${port}" =~ ^[0-9]+$ ]] || return 1
  have_cmd ss || return 1
  ss -lnt 2>/dev/null | grep -Eq "(^|[[:space:]])[^[:space:]]*:${port}([[:space:]]|$)"
}

warp_port_listener_names_get() {
  local port="${1:-}"
  [[ "${port}" =~ ^[0-9]+$ ]] || return 1
  have_cmd ss || return 1
  ss -lntp "sport = :${port}" 2>/dev/null | awk '
    NR <= 1 { next }
    {
      line = $0
      while (match(line, /\("[^"]+"/)) {
        name = substr(line, RSTART + 2, RLENGTH - 3)
        if (!(name in seen)) {
          print name
          seen[name] = 1
        }
        line = substr(line, RSTART + RLENGTH)
      }
    }
  '
}

warp_port_listener_name_get() {
  local port="${1:-}"
  warp_port_listener_names_get "${port}" 2>/dev/null | awk 'NR == 1 { print; exit }'
}

warp_port_has_listener_name() {
  local port="${1:-}" name="${2:-}"
  [[ -n "${name}" ]] || return 1
  warp_port_listener_names_get "${port}" 2>/dev/null | grep -Fxq "${name}"
}

warp_port_wait_listening() {
  local port="${1:-}" timeout="${2:-20}" wait_i=0
  [[ "${port}" =~ ^[0-9]+$ ]] || return 1
  if ! [[ "${timeout}" =~ ^[0-9]+$ ]] || (( timeout <= 0 )); then
    timeout=20
  fi
  if ! have_cmd ss; then
    return 0
  fi
  for (( wait_i=0; wait_i<timeout; wait_i++ )); do
    if warp_port_is_listening "${port}"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

warp_port_wait_owned_by() {
  local port="${1:-}" name="${2:-}" timeout="${3:-20}" wait_i=0
  [[ "${port}" =~ ^[0-9]+$ ]] || return 1
  [[ -n "${name}" ]] || return 1
  if ! [[ "${timeout}" =~ ^[0-9]+$ ]] || (( timeout <= 0 )); then
    timeout=20
  fi
  if ! have_cmd ss; then
    return 0
  fi
  for (( wait_i=0; wait_i<timeout; wait_i++ )); do
    if warp_port_has_listener_name "${port}" "${name}"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

warp_proxy_port_is_listening() {
  warp_port_is_listening "$(warp_proxy_port_get)"
}

warp_proxy_wait_listening() {
  warp_port_wait_listening "$(warp_proxy_port_get)" "${1:-20}"
}

warp_zero_trust_proxy_port_get() {
  local cfg="" proxy_port=""
  cfg="$(warp_zero_trust_config_get 2>/dev/null || true)"
  proxy_port="$(printf '%s\n' "${cfg}" | awk -F'=' '/^proxy_port=/{print $2; exit}')"
  if [[ "${proxy_port}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "${proxy_port}"
  else
    printf '%s\n' "${WARP_ZEROTRUST_PROXY_PORT}"
  fi
}

warp_zero_trust_proxy_listener_name_get() {
  warp_port_listener_name_get "$(warp_zero_trust_proxy_port_get)"
}

warp_zero_trust_proxy_state_get() {
  local listener=""
  listener="$(warp_zero_trust_proxy_listener_name_get 2>/dev/null || true)"
  case "${listener}" in
    "${WARP_ZEROTRUST_SERVICE}") printf 'listening\n' ;;
    wireproxy) printf 'occupied-by-wireproxy\n' ;;
    "") printf 'not-listening\n' ;;
    *) printf 'busy-other-process\n' ;;
  esac
}

warp_zero_trust_proxy_wait_ready() {
  warp_port_wait_owned_by "$(warp_zero_trust_proxy_port_get)" "${WARP_ZEROTRUST_SERVICE}" "${1:-20}"
}

warp_zero_trust_config_get() {
  need_python3
  python3 - <<'PY' "${WARP_ZEROTRUST_CONFIG_FILE}" "${WARP_ZEROTRUST_PROXY_PORT}"
import pathlib
import sys

cfg_path = pathlib.Path(sys.argv[1])
default_port = str(sys.argv[2] or "40000").strip() or "40000"
data = {}
if cfg_path.exists():
  try:
    for line in cfg_path.read_text(encoding="utf-8").splitlines():
      line = line.strip()
      if not line or line.startswith("#") or "=" not in line:
        continue
      key, value = line.split("=", 1)
      data[key.strip()] = value.strip()
  except Exception:
    data = {}

team = str(data.get("WARP_ZEROTRUST_TEAM", "")).strip().lower()
client_id = str(data.get("WARP_ZEROTRUST_CLIENT_ID", "")).strip()
client_secret = str(data.get("WARP_ZEROTRUST_CLIENT_SECRET", "")).strip()
proxy_port = str(data.get("WARP_ZEROTRUST_PROXY_PORT", default_port)).strip() or default_port
if not proxy_port.isdigit():
  proxy_port = default_port
config_state = "complete" if team and client_id and client_secret else "incomplete"

print(f"team={team}")
print(f"client_id={client_id}")
print(f"client_secret={client_secret}")
print(f"proxy_port={proxy_port}")
print(f"config_state={config_state}")
PY
}

warp_zero_trust_config_set_values() {
  local tmp
  need_python3
  mkdir -p "${WARP_ZEROTRUST_ROOT}" 2>/dev/null || true
  touch "${WARP_ZEROTRUST_CONFIG_FILE}"
  tmp="$(mktemp "${WORK_DIR}/.warp-zerotrust-config.XXXXXX" 2>/dev/null || true)"
  [[ -n "${tmp}" ]] || tmp="${WORK_DIR}/.warp-zerotrust-config.$$"
  python3 - <<'PY' "${WARP_ZEROTRUST_CONFIG_FILE}" "${tmp}" "$@"
import pathlib
import sys

src = pathlib.Path(sys.argv[1])
dst = pathlib.Path(sys.argv[2])
items = sys.argv[3:]
if len(items) % 2 != 0:
  raise SystemExit(2)
updates = {}
for i in range(0, len(items), 2):
  updates[str(items[i])] = str(items[i + 1]).strip()

lines = []
if src.exists():
  try:
    lines = src.read_text(encoding="utf-8").splitlines()
  except Exception:
    lines = []

out = []
seen = set()
for line in lines:
  stripped = line.strip()
  if not stripped or stripped.startswith("#") or "=" not in line:
    out.append(line)
    continue
  key, _ = line.split("=", 1)
  key = key.strip()
  if key in updates:
    out.append(f"{key}={updates[key]}")
    seen.add(key)
  else:
    out.append(line)

for key, value in updates.items():
  if key in seen:
    continue
  out.append(f"{key}={value}")

dst.write_text("\n".join(out).rstrip("\n") + "\n", encoding="utf-8")
PY
  local rc=$?
  if (( rc == 0 )); then
    mv -f "${tmp}" "${WARP_ZEROTRUST_CONFIG_FILE}" || {
      rm -f "${tmp}" >/dev/null 2>&1 || true
      return 1
    }
    chmod 600 "${WARP_ZEROTRUST_CONFIG_FILE}" >/dev/null 2>&1 || true
  else
    rm -f "${tmp}" >/dev/null 2>&1 || true
  fi
  return "${rc}"
}

warp_zero_trust_secret_mask() {
  local value="${1:-}" len
  value="$(printf '%s' "${value}" | tr -d '[:space:]')"
  len="${#value}"
  if (( len == 0 )); then
    printf '(kosong)\n'
    return 0
  fi
  if (( len <= 8 )); then
    printf '%s\n' "${value}"
    return 0
  fi
  printf '%s****%s\n' "${value:0:4}" "${value:len-4:4}"
}

warp_zero_trust_cli_capture() {
  local out rc
  if ! have_cmd warp-cli; then
    return 127
  fi
  set +e
  out="$(warp-cli --accept-tos "$@" 2>&1)"
  rc=$?
  set -e
  if (( rc == 0 )); then
    printf '%s\n' "${out}"
    return 0
  fi
  set +e
  out="$(warp-cli "$@" 2>&1)"
  rc=$?
  set -e
  printf '%s\n' "${out}"
  return "${rc}"
}

warp_zero_trust_cli_first_line() {
  local out rc
  set +e
  out="$(warp_zero_trust_cli_capture "$@" 2>/dev/null)"
  rc=$?
  set -e
  [[ "${rc}" -eq 0 ]] || return "${rc}"
  printf '%s\n' "${out}" | awk 'NF{print; exit}'
}

warp_zero_trust_cli_run() {
  warp_zero_trust_cli_capture "$@" >/dev/null 2>&1
}

snapshot_file_capture() {
  local path="$1" snap_dir="$2" label="$3"
  mkdir -p "${snap_dir}" 2>/dev/null || true
  if [[ -e "${path}" ]]; then
    cp -a "${path}" "${snap_dir}/${label}.data" 2>/dev/null || return 1
    printf '1\n' > "${snap_dir}/${label}.exists"
  else
    printf '0\n' > "${snap_dir}/${label}.exists"
  fi
  return 0
}

snapshot_file_restore() {
  local path="$1" snap_dir="$2" label="$3"
  local exists="0"
  exists="$(cat "${snap_dir}/${label}.exists" 2>/dev/null || printf '0')"
  if [[ "${exists}" == "1" ]]; then
    mkdir -p "$(dirname "${path}")" 2>/dev/null || true
    cp -a "${snap_dir}/${label}.data" "${path}" 2>/dev/null || return 1
  else
    rm -f "${path}" 2>/dev/null || return 1
  fi
  return 0
}

adblock_lock_file_path() {
  printf '%s\n' "${ADBLOCK_LOCK_FILE:-/run/autoscript/locks/adblock.lock}"
}

adblock_run_locked() {
  local lock_file rc
  if [[ "${ADBLOCK_LOCK_HELD:-0}" == "1" ]]; then
    "$@"
    return $?
  fi
  lock_file="$(adblock_lock_file_path)"
  mkdir -p "$(dirname "${lock_file}")" 2>/dev/null || true
  if (
    flock -x 200 || exit 1
    export ADBLOCK_LOCK_HELD=1
    "$@"
  ) 200>"${lock_file}"; then
    return 0
  else
    rc=$?
  fi
  return "${rc}"
}

xray_dns_lock_prepare() {
  mkdir -p "$(dirname "${DNS_LOCK_FILE}")" 2>/dev/null || true
}

xray_dns_run_locked() {
  local rc
  xray_dns_lock_prepare
  if [[ "${DNS_LOCK_HELD:-0}" == "1" ]]; then
    "$@"
    return $?
  fi
  if (
    flock -x 200 || exit 1
    export DNS_LOCK_HELD=1
    "$@"
  ) 200>"${DNS_LOCK_FILE}"; then
    return 0
  else
    rc=$?
  fi
  return "${rc}"
}

xray_dns_conf_bootstrap_locked() {
  local dir base tmp
  [[ -f "${XRAY_DNS_CONF}" ]] && return 0
  dir="$(dirname "${XRAY_DNS_CONF}")"
  base="$(basename "${XRAY_DNS_CONF}")"
  mkdir -p "${dir}" 2>/dev/null || return 1
  tmp="$(mktemp "${dir}/.${base}.init.XXXXXX" 2>/dev/null || true)"
  [[ -n "${tmp}" ]] || return 1
  if ! printf '%s\n' '{"dns":{}}' > "${tmp}"; then
    rm -f "${tmp}" >/dev/null 2>&1 || true
    return 1
  fi
  chmod 600 "${tmp}" >/dev/null 2>&1 || true
  chown 0:0 "${tmp}" >/dev/null 2>&1 || true
  if ! mv -f "${tmp}" "${XRAY_DNS_CONF}"; then
    rm -f "${tmp}" >/dev/null 2>&1 || true
    return 1
  fi
  return 0
}

xray_json_file_probe() {
  local file="${1:-}"
  need_python3
  python3 - <<'PY' "${file}"
import json
import sys

path = sys.argv[1]
if not path:
  print("state=missing")
  print("error=path kosong")
  raise SystemExit(3)

try:
  with open(path, 'r', encoding='utf-8') as f:
    json.load(f)
except FileNotFoundError:
  print("state=missing")
  print("error=file tidak ditemukan")
  raise SystemExit(3)
except Exception as exc:
  print("state=invalid")
  print("error=" + str(exc).replace("\n", " "))
  raise SystemExit(2)

print("state=ok")
print("error=")
PY
}

xray_json_file_state_get() {
  local file="${1:-}"
  local probe="" rc=0 state=""
  probe="$(xray_json_file_probe "${file}" 2>/dev/null)" || rc=$?
  state="$(printf '%s\n' "${probe}" | awk -F'=' '/^state=/{print $2; exit}' 2>/dev/null || true)"
  if [[ -n "${state}" ]]; then
    printf '%s\n' "${state}"
    return 0
  fi
  if (( rc == 3 )); then
    printf 'missing\n'
  elif (( rc == 0 )); then
    printf 'ok\n'
  else
    printf 'invalid\n'
  fi
  return 0
}

xray_json_file_require_valid() {
  local file="${1:-}"
  local label="${2:-JSON file}"
  local allow_missing="${3:-0}"
  local probe="" rc=0 state="" error=""

  probe="$(xray_json_file_probe "${file}" 2>&1)" || rc=$?
  state="$(printf '%s\n' "${probe}" | awk -F'=' '/^state=/{print $2; exit}' 2>/dev/null || true)"
  error="$(printf '%s\n' "${probe}" | awk -F'=' '/^error=/{print substr($0,7); exit}' 2>/dev/null || true)"

  if (( rc == 0 )) || [[ "${state}" == "ok" ]]; then
    return 0
  fi

  if (( rc == 3 )) || [[ "${state}" == "missing" ]]; then
    if [[ "${allow_missing}" == "1" ]]; then
      return 0
    fi
    warn "${label} tidak ditemukan: ${file}"
    return 1
  fi

  warn "${label} invalid: ${file}"
  if [[ -n "${error}" ]]; then
    warn "Detail: ${error}"
  fi
  return 1
}

xray_stage_origin_meta_path() {
  local candidate="${1:-}"
  printf '%s.origin.meta\n' "${candidate}"
}

xray_file_sha256_get() {
  local file="${1:-}"
  need_python3
  python3 - <<'PY' "${file}" || return 1
import hashlib
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
if not path.is_file():
  raise SystemExit(1)

h = hashlib.sha256()
with path.open("rb") as f:
  while True:
    chunk = f.read(1024 * 1024)
    if not chunk:
      break
    h.update(chunk)

print(h.hexdigest())
PY
}

xray_stage_origin_capture() {
  local candidate="${1:-}"
  local live_path="${2:-}"
  local meta="" sha=""
  [[ -n "${candidate}" && -n "${live_path}" ]] || return 1
  meta="$(xray_stage_origin_meta_path "${candidate}")"
  if [[ -f "${live_path}" ]]; then
    sha="$(xray_file_sha256_get "${live_path}")" || return 1
    {
      printf 'exists=1\n'
      printf 'sha256=%s\n' "${sha}"
    } > "${meta}" || return 1
  else
    {
      printf 'exists=0\n'
      printf 'sha256=\n'
    } > "${meta}" || return 1
  fi
  chmod 600 "${meta}" >/dev/null 2>&1 || true
  return 0
}

xray_stage_origin_verify_live() {
  local candidate="${1:-}"
  local live_path="${2:-}"
  local label="${3:-Konfigurasi}"
  local meta="" expected_exists="" expected_sha="" actual_sha=""
  [[ -n "${candidate}" && -n "${live_path}" ]] || return 1
  meta="$(xray_stage_origin_meta_path "${candidate}")"
  if [[ ! -f "${meta}" ]]; then
    warn "Metadata staging ${label} tidak ditemukan. Buang staging lalu ulangi dari state live terbaru."
    return 1
  fi

  expected_exists="$(awk -F'=' '/^exists=/{print $2; exit}' "${meta}" 2>/dev/null || true)"
  expected_sha="$(awk -F'=' '/^sha256=/{print $2; exit}' "${meta}" 2>/dev/null || true)"

  case "${expected_exists}" in
    1)
      if [[ ! -f "${live_path}" ]]; then
        warn "${label} live berubah sejak staging dibuat (file sekarang hilang). Buang staging lalu ulangi."
        return 1
      fi
      actual_sha="$(xray_file_sha256_get "${live_path}")" || {
        warn "Gagal menghitung checksum live untuk ${label}."
        return 1
      }
      if [[ "${actual_sha}" != "${expected_sha}" ]]; then
        warn "${label} live berubah sejak staging dibuat. Buang staging lalu ulangi dari state terbaru."
        return 1
      fi
      ;;
    0)
      if [[ -e "${live_path}" ]]; then
        warn "${label} live berubah sejak staging dibuat (sebelumnya belum ada, sekarang sudah ada). Buang staging lalu ulangi."
        return 1
      fi
      ;;
    *)
      warn "Metadata staging ${label} tidak valid. Buang staging lalu ulangi."
      return 1
      ;;
  esac

  return 0
}

xray_stage_candidate_cleanup() {
  local candidate="${1:-}"
  [[ -n "${candidate}" ]] || return 0
  rm -f "${candidate}" "$(xray_stage_origin_meta_path "${candidate}")" >/dev/null 2>&1 || true
  return 0
}

warp_wireproxy_restart_checked() {
  if ! svc_exists wireproxy; then
    warn "wireproxy.service tidak terdeteksi"
    return 1
  fi
  if ! svc_restart_checked wireproxy 30 >/dev/null 2>&1; then
    warn "Restart wireproxy gagal."
    return 1
  fi
  if have_cmd ss && ! warp_proxy_wait_listening 20; then
    warn "wireproxy aktif, tetapi port SOCKS5 $(warp_proxy_port_get) belum listening setelah restart."
    return 1
  fi
  return 0
}

warp_zero_trust_service_restart_checked() {
  local cli_state=""
  if ! svc_exists "${WARP_ZEROTRUST_SERVICE}"; then
    warn "${WARP_ZEROTRUST_SERVICE} tidak terdeteksi"
    return 1
  fi
  systemctl enable "${WARP_ZEROTRUST_SERVICE}" >/dev/null 2>&1 || true
  if ! svc_restart_checked "${WARP_ZEROTRUST_SERVICE}" 30 >/dev/null 2>&1; then
    warn "Restart ${WARP_ZEROTRUST_SERVICE} gagal."
    return 1
  fi
  if have_cmd warp-cli; then
    cli_state="$(warp_zero_trust_cli_first_line status 2>/dev/null || true)"
    [[ -n "${cli_state}" ]] && log "Status awal ${WARP_ZEROTRUST_SERVICE}: ${cli_state}"
  fi
  return 0
}

warp_zero_trust_proxy_wait_connected() {
  local timeout="${1:-30}" wait_i=0 cli_state="" proxy_port="" proxy_state=""
  if ! [[ "${timeout}" =~ ^[0-9]+$ ]] || (( timeout <= 0 )); then
    timeout=30
  fi
  proxy_port="$(warp_zero_trust_proxy_port_get)"
  for (( wait_i=0; wait_i<timeout; wait_i++ )); do
    if have_cmd warp-cli; then
      warp_zero_trust_cli_run connect >/dev/null 2>&1 || true
    fi
    if warp_zero_trust_proxy_wait_ready 2; then
      return 0
    fi
    if have_cmd warp-cli; then
      cli_state="$(warp_zero_trust_cli_first_line status 2>/dev/null || true)"
      case "$(printf '%s' "${cli_state}" | tr '[:upper:]' '[:lower:]')" in
        *connected*|*proxying*|*success*)
          if warp_zero_trust_proxy_wait_ready 2; then
            return 0
          fi
          ;;
      esac
    fi
    sleep 1
  done
  proxy_state="$(warp_zero_trust_proxy_state_get)"
  warn "${WARP_ZEROTRUST_SERVICE} aktif, tetapi proxy lokal port ${proxy_port} belum dipegang backend Zero Trust."
  warn "Proxy state: ${proxy_state}"
  if [[ -n "${cli_state}" ]]; then
    warn "CLI status terakhir: ${cli_state}"
  fi
  return 1
}

warp_wireproxy_post_restart_health_check() {
  local target live tier_rc=0
  if ! warp_wireproxy_restart_checked; then
    return 1
  fi
  target="$(warp_tier_target_effective_get)"
  case "${target}" in
    free|plus)
      if ! warp_live_tier_wait_for "${target}" 20; then
        tier_rc=$?
      fi
      if (( tier_rc == 1 )); then
        warn "wireproxy hidup, tetapi egress WARP belum sehat untuk target ${target}."
        return 1
      elif (( tier_rc == 2 )); then
        warn "wireproxy hidup, tetapi probe tier WARP belum memberi jawaban pasti; lanjutkan tanpa rollback keras."
      fi
      ;;
    *)
      live="$(warp_live_tier_get)"
      case "${live}" in
        free|plus) ;;
        *)
          warn "wireproxy hidup, tetapi tier WARP live belum terdeteksi sehat."
          return 1
          ;;
      esac
      ;;
  esac
  return 0
}

warp_runtime_snapshot_capture() {
  local snap_dir="$1"
  mkdir -p "${snap_dir}" 2>/dev/null || true
  snapshot_file_capture "${WGCF_DIR}/wgcf-account.toml" "${snap_dir}" "wgcf_account" || return 1
  snapshot_file_capture "${WGCF_DIR}/wgcf-profile.conf" "${snap_dir}" "wgcf_profile" || return 1
  snapshot_file_capture "${WIREPROXY_CONF}" "${snap_dir}" "wireproxy_conf" || return 1
  snapshot_file_capture "${WARP_ZEROTRUST_CONFIG_FILE}" "${snap_dir}" "warp_zerotrust_config" || return 1
  snapshot_file_capture "${WARP_ZEROTRUST_MDM_FILE}" "${snap_dir}" "warp_zerotrust_mdm" || return 1
  snapshot_file_capture "$(network_state_file)" "${snap_dir}" "network_state" || return 1
  if svc_exists wireproxy; then
    printf '1\n' > "${snap_dir}/wireproxy.exists"
    if svc_is_active wireproxy; then
      printf '1\n' > "${snap_dir}/wireproxy.active"
    else
      printf '0\n' > "${snap_dir}/wireproxy.active"
    fi
  else
    printf '0\n' > "${snap_dir}/wireproxy.exists"
    printf '0\n' > "${snap_dir}/wireproxy.active"
  fi
  if svc_exists "${WARP_ZEROTRUST_SERVICE}"; then
    printf '1\n' > "${snap_dir}/warp_zerotrust.exists"
    if svc_is_active "${WARP_ZEROTRUST_SERVICE}"; then
      printf '1\n' > "${snap_dir}/warp_zerotrust.active"
    else
      printf '0\n' > "${snap_dir}/warp_zerotrust.active"
    fi
  else
    printf '0\n' > "${snap_dir}/warp_zerotrust.exists"
    printf '0\n' > "${snap_dir}/warp_zerotrust.active"
  fi
  return 0
}

warp_zero_trust_post_restart_health_check() {
  local cli_state=""
  if ! warp_zero_trust_service_restart_checked; then
    return 1
  fi
  if ! warp_zero_trust_proxy_wait_connected 30; then
    return 1
  fi
  if have_cmd warp-cli; then
    cli_state="$(warp_zero_trust_cli_first_line status 2>/dev/null || true)"
    if [[ -n "${cli_state}" ]]; then
      case "$(printf '%s' "${cli_state}" | tr '[:upper:]' '[:lower:]')" in
        *connected*|*proxying*|*success*)
          :
          ;;
        *)
          warn "Status ${WARP_ZEROTRUST_SERVICE} belum konklusif: ${cli_state}"
          ;;
      esac
    fi
  fi
  return 0
}

warp_backend_restart_checked() {
  case "$(warp_mode_state_get)" in
    zerotrust) warp_zero_trust_service_restart_checked ;;
    *) warp_wireproxy_restart_checked ;;
  esac
}

warp_backend_post_restart_health_check() {
  case "$(warp_mode_state_get)" in
    zerotrust) warp_zero_trust_post_restart_health_check ;;
    *) warp_wireproxy_post_restart_health_check ;;
  esac
}

warp_runtime_snapshot_restore() {
  local snap_dir="$1"
  local had_service was_active had_zt_service was_zt_active
  had_service="$(cat "${snap_dir}/wireproxy.exists" 2>/dev/null || printf '0')"
  was_active="$(cat "${snap_dir}/wireproxy.active" 2>/dev/null || printf '0')"
  had_zt_service="$(cat "${snap_dir}/warp_zerotrust.exists" 2>/dev/null || printf '0')"
  was_zt_active="$(cat "${snap_dir}/warp_zerotrust.active" 2>/dev/null || printf '0')"

  snapshot_file_restore "${WGCF_DIR}/wgcf-account.toml" "${snap_dir}" "wgcf_account" || return 1
  snapshot_file_restore "${WGCF_DIR}/wgcf-profile.conf" "${snap_dir}" "wgcf_profile" || return 1
  snapshot_file_restore "${WIREPROXY_CONF}" "${snap_dir}" "wireproxy_conf" || return 1
  snapshot_file_restore "${WARP_ZEROTRUST_CONFIG_FILE}" "${snap_dir}" "warp_zerotrust_config" || return 1
  snapshot_file_restore "${WARP_ZEROTRUST_MDM_FILE}" "${snap_dir}" "warp_zerotrust_mdm" || return 1
  snapshot_file_restore "$(network_state_file)" "${snap_dir}" "network_state" || return 1

  if [[ "${had_service}" == "1" ]]; then
    if [[ "${was_active}" == "1" ]]; then
      warp_wireproxy_restart_checked || return 1
    elif svc_exists wireproxy && svc_is_active wireproxy; then
      svc_stop_checked wireproxy 30 || return 1
    fi
  fi
  if [[ "${had_zt_service}" == "1" ]]; then
    if [[ "${was_zt_active}" == "1" ]]; then
      warp_zero_trust_service_restart_checked || return 1
    elif svc_exists "${WARP_ZEROTRUST_SERVICE}" && svc_is_active "${WARP_ZEROTRUST_SERVICE}"; then
      svc_stop_checked "${WARP_ZEROTRUST_SERVICE}" 30 || return 1
    fi
  fi
  return 0
}

warp_runtime_refresh_ssh_network_after_profile_change() {
  declare -F ssh_network_runtime_refresh_if_available >/dev/null 2>&1 || return 0
  if ! ssh_network_runtime_refresh_if_available; then
    warn "Runtime SSH Network gagal disegarkan sesudah profile WARP berubah."
    return 1
  fi
  return 0
}

warp_runtime_snapshot_restore_or_fail() {
  # args: snap_dir primary_message
  local snap_dir="$1"
  local primary_message="$2"
  if warp_runtime_snapshot_restore "${snap_dir}" >/dev/null 2>&1 \
    && warp_runtime_refresh_ssh_network_after_profile_change >/dev/null 2>&1; then
    warn "${primary_message}"
  else
    warn "${primary_message}"
    warn "Rollback WARP gagal. Runtime mungkin masih berada pada state transisi."
  fi
  rm -rf "${snap_dir}" >/dev/null 2>&1 || true
  hr
  pause
  exit 1
}

warp_runtime_snapshot_restore_on_abort() {
  local snap_dir="${1:-}"
  [[ -n "${snap_dir}" && -d "${snap_dir}" ]] || return 0
  if warp_runtime_snapshot_restore "${snap_dir}" >/dev/null 2>&1 \
    && warp_runtime_refresh_ssh_network_after_profile_change >/dev/null 2>&1; then
    warn "Transaksi WARP terputus sebelum selesai. Snapshot runtime dipulihkan."
  else
    warn "Transaksi WARP terputus sebelum selesai dan rollback snapshot gagal."
  fi
  rm -rf "${snap_dir}" >/dev/null 2>&1 || true
}


warp_global_menu() {
  local routing_candidate=""
  local pending_changes="false"
  local source_file="" c="" desired=""
  while true; do
    source_file="${routing_candidate:-${XRAY_ROUTING_CONF}}"
    if ! xray_json_file_require_valid "${source_file}" "Xray routing config"; then
      title
      echo "WARP Controls > WARP Global"
      hr
      warn "Menu diblok karena routing JSON invalid. Perbaiki dulu sebelum lanjut."
      hr
      pause
      return 0
    fi
    title
    echo "WARP Controls > WARP Global"
    hr
    printf "Status WARP Global: %s\n" "$(warp_global_mode_pretty_get "${source_file}")"
    if [[ "${pending_changes}" == "true" ]]; then
      echo "Staging           : pending apply"
    fi
    hr
    echo "  1) direct"
    echo "  2) warp"
    if [[ "${pending_changes}" == "true" ]]; then
      echo "  3) apply staged changes"
      echo "  4) discard staged changes"
    fi
    echo "  0) kembali"
    hr
    read -r -p "Pilih: " c
    case "${c}" in
      1)
        desired="direct"
        if ! confirm_yn_or_back "Stage WARP Global ke DIRECT sekarang?"; then
          warn "Stage WARP Global dibatalkan."
          pause
          continue
        fi
        if ! xray_routing_candidate_prepare routing_candidate; then
          warn "Gagal menyiapkan staging routing."
          pause
          continue
        fi
        if ! xray_routing_default_rule_set_in_file "${routing_candidate}" "${routing_candidate}" "${desired}"; then
          warn "Gagal men-stage WARP Global ke ${desired^^}."
          pause
          continue
        fi
        pending_changes="true"
        log "WARP Global di-stage ke ${desired^^}"
        pause
        ;;
      2)
        desired="warp"
        if ! confirm_yn_or_back "Stage WARP Global ke WARP sekarang?"; then
          warn "Stage WARP Global dibatalkan."
          pause
          continue
        fi
        if ! xray_routing_candidate_prepare routing_candidate; then
          warn "Gagal menyiapkan staging routing."
          pause
          continue
        fi
        if ! xray_routing_default_rule_set_in_file "${routing_candidate}" "${routing_candidate}" "${desired}"; then
          warn "Gagal men-stage WARP Global ke ${desired^^}."
          pause
          continue
        fi
        pending_changes="true"
        log "WARP Global di-stage ke ${desired^^}"
        pause
        ;;
      3)
        if [[ "${pending_changes}" != "true" ]]; then
          warn "Pilihan tidak valid"
          sleep 1
          continue
        fi
        if ! confirm_menu_apply_now "Apply staged WARP Global changes sekarang?"; then
          pause
          continue
        fi
        if ! xray_routing_apply_candidate_file "${routing_candidate}"; then
          pause
          continue
        fi
        xray_stage_candidate_cleanup "${routing_candidate}"
        routing_candidate=""
        pending_changes="false"
        log "Staged WARP Global changes diterapkan."
        pause
        ;;
      4)
        if [[ "${pending_changes}" != "true" ]]; then
          warn "Pilihan tidak valid"
          sleep 1
          continue
        fi
        if confirm_menu_apply_now "Buang staged WARP Global changes?"; then
          xray_stage_candidate_cleanup "${routing_candidate}"
          routing_candidate=""
          pending_changes="false"
          log "Staged WARP Global changes dibuang."
        fi
        pause
        ;;
      0|kembali|k|back|b)
        if [[ "${pending_changes}" == "true" ]]; then
          local back_rc=0
          if confirm_yn_or_back "Apply staged WARP Global changes sebelum keluar? Pilih no untuk membuang staging."; then
            if ! xray_routing_apply_candidate_file "${routing_candidate}"; then
              pause
              continue
            fi
          else
            back_rc=$?
            if (( back_rc == 2 )); then
              continue
            fi
          fi
        fi
        xray_stage_candidate_cleanup "${routing_candidate}"
        return 0
        ;;
      *) warn "Pilihan tidak valid" ; sleep 1 ;;
    esac
  done
}

warp_user_set_effective_mode() {
  local email="$1"
  local desired="$2" # direct|warp|inherit
  local candidate_file="${3:-}"

  if is_default_xray_email_or_tag "${email}"; then
    warn "User default Xray bersifat readonly: ${email}"
    return 0
  fi

  case "${desired}" in
    inherit) desired="off" ;;
  esac

  case "${desired}" in
    direct|warp|off)
      if [[ -n "${candidate_file}" ]]; then
        if ! xray_routing_rule_set_user_outbound_mode_in_file "${candidate_file}" "${candidate_file}" "${email}" "${desired}"; then
          warn "Gagal men-stage mode WARP per-user untuk ${email}."
          return 1
        fi
      else
        if ! menu_run_isolated xray_routing_rule_set_user_outbound_mode "${email}" "${desired}"; then
          warn "Gagal mengubah mode WARP per-user untuk ${email}."
          return 1
        fi
      fi
      ;;
    *) warn "Mode user harus direct|warp|inherit" ;;
  esac
}


warp_per_user_menu() {
  need_python3

  local page=0
  local page_size=10
  local routing_candidate=""
  local pending_changes="false"
  local source_file=""

  while true; do
    source_file="${routing_candidate:-${XRAY_ROUTING_CONF}}"
    if ! xray_json_file_require_valid "${XRAY_INBOUNDS_CONF}" "Xray inbounds config"; then
      title
      echo "WARP Controls > WARP per-user"
      hr
      warn "Menu diblok karena inbounds JSON invalid. Perbaiki dulu sebelum lanjut."
      hr
      pause
      return 0
    fi
    if ! xray_json_file_require_valid "${source_file}" "Xray routing config"; then
      title
      echo "WARP Controls > WARP per-user"
      hr
      warn "Menu diblok karena routing JSON invalid. Perbaiki dulu sebelum lanjut."
      hr
      pause
      return 0
    fi
    mapfile -t all_users_raw < <(xray_inbounds_all_client_emails_get 2>/dev/null || true)

    local all_users=()
    local u
    for u in "${all_users_raw[@]}"; do
      if is_default_xray_email_or_tag "${u}"; then
        continue
      fi
      all_users+=("${u}")
    done

    if (( ${#all_users[@]} == 0 )); then
      title
      echo "WARP Controls > WARP per-user"
      hr
      warn "Tidak menemukan user non-default dari config inbounds."
      hr
      pause
      return 0
    fi

    mapfile -t warp_override < <(xray_routing_rule_user_list_get "dummy-warp-user" "warp" "${source_file}" 2>/dev/null || true)
    mapfile -t direct_override < <(xray_routing_rule_user_list_get "dummy-direct-user" "direct" "${source_file}" 2>/dev/null || true)

    declare -A warp_set=()
    declare -A direct_set=()

    for u in "${warp_override[@]}"; do
      [[ -n "${u}" ]] && warp_set["${u}"]=1
    done
    for u in "${direct_override[@]}"; do
      [[ -n "${u}" ]] && direct_set["${u}"]=1
    done

    local global_mode default_mode user_conflicts=0
    global_mode="$(warp_global_mode_get "${source_file}" || true)"
    case "${global_mode}" in
      warp) default_mode="warp" ;;
      direct) default_mode="direct" ;;
      *) default_mode="unknown" ;;
    esac
    for u in "${all_users[@]}"; do
      if [[ -n "${direct_set[${u}]:-}" && -n "${warp_set[${u}]:-}" ]]; then
        ((user_conflicts+=1))
      fi
    done

    local total pages start end i row email status
    total="${#all_users[@]}"
    pages=$(( (total + page_size - 1) / page_size ))
    if (( page < 0 )); then page=0; fi
    if (( page >= pages )); then page=$((pages - 1)); fi
    start=$((page * page_size))
    end=$((start + page_size))
    if (( end > total )); then end=total; fi

    title
    echo "WARP Controls > WARP per-user"
    hr
    printf "WARP Global: %s\n" "$(warp_global_mode_pretty_get "${source_file}")"
    if [[ "${pending_changes}" == "true" ]]; then
      echo "Staging   : pending apply"
    fi
    hr
    printf "%-4s %-32s %-8s\n" "No" "User" "Status"
    printf "%-4s %-32s %-8s\n" "----" "--------------------------------" "--------"
    if (( user_conflicts > 0 )); then
      echo "Conflict  : ${user_conflicts} user memiliki override direct+warp sekaligus."
    fi

    for (( i=start; i<end; i++ )); do
      row=$((i - start + 1))
      email="${all_users[$i]}"

      if [[ -n "${direct_set[${email}]:-}" && -n "${warp_set[${email}]:-}" ]]; then
        status="conflict"
      elif [[ -n "${direct_set[${email}]:-}" ]]; then
        status="direct"
      elif [[ -n "${warp_set[${email}]:-}" ]]; then
        status="warp"
      else
        status="inherit:${default_mode}"
      fi

      printf "%-4s %-32s %-8s\n" "${row}" "${email}" "${status}"
    done

    echo
    echo "Halaman: $((page + 1))/${pages} | Total user: ${total}"
    echo "Toggle: next / previous / apply / discard / 0 kembali"
    hr
    read -r -p "Pilih No untuk stage (atau next/previous/apply/discard/kembali): " c

    if is_back_choice "${c}"; then
      if [[ "${pending_changes}" == "true" ]]; then
        local back_rc=0
        if confirm_yn_or_back "Apply staged WARP per-user changes sebelum keluar? Pilih no untuk membuang staging."; then
          if ! xray_routing_apply_candidate_file "${routing_candidate}"; then
            pause
            continue
          fi
        else
          back_rc=$?
          if (( back_rc == 2 )); then
            continue
          fi
        fi
      fi
      xray_stage_candidate_cleanup "${routing_candidate}"
      return 0
    fi

    case "${c}" in
      next|n)
        if (( page < pages - 1 )); then
          page=$((page + 1))
        fi
        continue
        ;;
      previous|prev|p)
        if (( page > 0 )); then
          page=$((page - 1))
        fi
        continue
        ;;
      apply)
        if [[ "${pending_changes}" != "true" ]]; then
          warn "Belum ada staged changes."
          pause
          continue
        fi
        if ! confirm_menu_apply_now "Apply staged WARP per-user changes sekarang?"; then
          pause
          continue
        fi
        if ! xray_routing_apply_candidate_file "${routing_candidate}"; then
          pause
          continue
        fi
        xray_stage_candidate_cleanup "${routing_candidate}"
        routing_candidate=""
        pending_changes="false"
        log "Staged WARP per-user changes diterapkan."
        pause
        continue
        ;;
      discard)
        if [[ "${pending_changes}" != "true" ]]; then
          warn "Belum ada staged changes."
          pause
          continue
        fi
        if confirm_menu_apply_now "Buang staged WARP per-user changes?"; then
          xray_stage_candidate_cleanup "${routing_candidate}"
          routing_candidate=""
          pending_changes="false"
          log "Staged WARP per-user changes dibuang."
        fi
        pause
        continue
        ;;
    esac

    if [[ ! "${c}" =~ ^[0-9]+$ ]]; then
      warn "Input tidak valid"
      sleep 1
      continue
    fi

    if (( c < 1 || c > (end - start) )); then
      warn "No di luar range"
      sleep 1
      continue
    fi

    email="${all_users[$((start + c - 1))]}"

    local cur_status
    if [[ -n "${direct_set[${email}]:-}" && -n "${warp_set[${email}]:-}" ]]; then
      cur_status="conflict"
    elif [[ -n "${direct_set[${email}]:-}" ]]; then
      cur_status="direct"
    elif [[ -n "${warp_set[${email}]:-}" ]]; then
      cur_status="warp"
    else
      cur_status="inherit:${default_mode}"
    fi

    while true; do
      title
      echo "WARP Controls > WARP per-user"
      hr
      echo "User   : ${email}"
      echo "Status : ${cur_status}"
      hr
      echo "  1) direct"
      echo "  2) warp"
      echo "  3) inherit (ikut global)"
      echo "  0) kembali"
      hr
      read -r -p "Pilih: " s

      if is_back_choice "${s}"; then
        break
      fi

      case "${s}" in
        1)
          if ! confirm_yn_or_back "Stage user ${email} ke DIRECT sekarang?"; then
            warn "Stage WARP per-user dibatalkan."
            pause
            continue
          fi
          if ! xray_routing_candidate_prepare routing_candidate; then
            warn "Gagal menyiapkan staging routing."
            pause
            continue
          fi
          if warp_user_set_effective_mode "${email}" direct "${routing_candidate}"; then
            pending_changes="true"
            log "Per-user di-stage DIRECT: ${email}"
            pause
            break
          fi
          pause
          ;;
        2)
          if ! confirm_yn_or_back "Stage user ${email} ke WARP sekarang?"; then
            warn "Stage WARP per-user dibatalkan."
            pause
            continue
          fi
          if ! xray_routing_candidate_prepare routing_candidate; then
            warn "Gagal menyiapkan staging routing."
            pause
            continue
          fi
          if warp_user_set_effective_mode "${email}" warp "${routing_candidate}"; then
            pending_changes="true"
            log "Per-user di-stage WARP: ${email}"
            pause
            break
          fi
          pause
          ;;
        3)
          if ! confirm_yn_or_back "Reset user ${email} ke INHERIT sekarang?"; then
            warn "Reset WARP per-user dibatalkan."
            pause
            continue
          fi
          if ! xray_routing_candidate_prepare routing_candidate; then
            warn "Gagal menyiapkan staging routing."
            pause
            continue
          fi
          if warp_user_set_effective_mode "${email}" inherit "${routing_candidate}"; then
            pending_changes="true"
            log "Per-user di-stage INHERIT: ${email}"
            pause
            break
          fi
          pause
          ;;
        *) warn "Pilihan tidak valid" ; sleep 1 ;;
      esac
    done
  done
}


warp_inbound_set_effective_mode() {
  local tag="$1"
  local desired="$2" # direct|warp|inherit
  local candidate_file="${3:-}"

  if [[ "${tag}" == "api" ]]; then
    warn "Inbound internal (api) bersifat readonly: ${tag}"
    return 0
  fi

  case "${desired}" in
    inherit) desired="off" ;;
  esac

  case "${desired}" in
    direct|warp|off)
      if [[ -n "${candidate_file}" ]]; then
        if ! xray_routing_rule_set_inbound_outbound_mode_in_file "${candidate_file}" "${candidate_file}" "${tag}" "${desired}"; then
          warn "Gagal men-stage mode WARP per-inbound untuk ${tag}."
          return 1
        fi
      else
        if ! menu_run_isolated xray_routing_rule_set_inbound_outbound_mode "${tag}" "${desired}"; then
          warn "Gagal mengubah mode WARP per-inbound untuk ${tag}."
          return 1
        fi
      fi
      ;;
    *) warn "Mode inbound harus direct|warp|inherit" ;;
  esac
}


warp_per_inbounds_menu() {
  need_python3
  local routing_candidate=""
  local pending_changes="false"
  local source_file=""

  while true; do
    source_file="${routing_candidate:-${XRAY_ROUTING_CONF}}"
    if ! xray_json_file_require_valid "${XRAY_INBOUNDS_CONF}" "Xray inbounds config"; then
      title
      echo "WARP Controls > WARP per-protocol inbounds"
      hr
      warn "Menu diblok karena inbounds JSON invalid. Perbaiki dulu sebelum lanjut."
      hr
      pause
      return 0
    fi
    if ! xray_json_file_require_valid "${source_file}" "Xray routing config"; then
      title
      echo "WARP Controls > WARP per-protocol inbounds"
      hr
      warn "Menu diblok karena routing JSON invalid. Perbaiki dulu sebelum lanjut."
      hr
      pause
      return 0
    fi
    mapfile -t all_tags_raw < <(xray_inbounds_all_tags_get 2>/dev/null || true)

    local tags=()
    local t
    for t in "${all_tags_raw[@]}"; do
      if [[ "${t}" == "api" ]]; then
        continue
      fi
      tags+=("${t}")
    done

    if (( ${#tags[@]} == 0 )); then
      title
      echo "WARP Controls > WARP per-protocol inbounds"
      hr
      warn "Tidak ada inbound yang bisa diatur."
      hr
      pause
      return 0
    fi

    mapfile -t warp_override < <(xray_routing_rule_inbound_list_get "dummy-warp-inbounds" "warp" "${source_file}" 2>/dev/null || true)
    mapfile -t direct_override < <(xray_routing_rule_inbound_list_get "dummy-direct-inbounds" "direct" "${source_file}" 2>/dev/null || true)

    declare -A warp_set=()
    declare -A direct_set=()

    for t in "${warp_override[@]}"; do
      [[ -n "${t}" ]] && warp_set["${t}"]=1
    done
    for t in "${direct_override[@]}"; do
      [[ -n "${t}" ]] && direct_set["${t}"]=1
    done

    local global_mode default_mode inbound_conflicts=0
    global_mode="$(warp_global_mode_get "${source_file}" || true)"
    case "${global_mode}" in
      warp) default_mode="warp" ;;
      direct) default_mode="direct" ;;
      *) default_mode="unknown" ;;
    esac
    for t in "${tags[@]}"; do
      if [[ -n "${direct_set[${t}]:-}" && -n "${warp_set[${t}]:-}" ]]; then
        ((inbound_conflicts+=1))
      fi
    done

    title
    echo "WARP Controls > WARP per-protocol inbounds"
    hr
    printf "WARP Global: %s\n" "$(warp_global_mode_pretty_get "${source_file}")"
    if [[ "${pending_changes}" == "true" ]]; then
      echo "Staging   : pending apply"
    fi
    hr
    printf "%-4s %-28s %-8s\n" "No" "Protocol (Inbound Tag)" "Status"
    printf "%-4s %-28s %-8s\n" "----" "----------------------------" "--------"
    if (( inbound_conflicts > 0 )); then
      echo "Conflict  : ${inbound_conflicts} inbound memiliki override direct+warp sekaligus."
    fi

    local i status
    for (( i=0; i<${#tags[@]}; i++ )); do
      t="${tags[$i]}"

      if [[ -n "${direct_set[${t}]:-}" && -n "${warp_set[${t}]:-}" ]]; then
        status="conflict"
      elif [[ -n "${direct_set[${t}]:-}" ]]; then
        status="direct"
      elif [[ -n "${warp_set[${t}]:-}" ]]; then
        status="warp"
      else
        status="inherit:${default_mode}"
      fi

      printf "%-4s %-28s %-8s\n" "$((i + 1))" "${t}" "${status}"
    done

    hr
    echo "Pilih No untuk stage (direct/warp/inherit), atau apply/discard/0 kembali"
    read -r -p "Pilih: " c

    if is_back_choice "${c}"; then
      if [[ "${pending_changes}" == "true" ]]; then
        local back_rc=0
        if confirm_yn_or_back "Apply staged WARP per-inbound changes sebelum keluar? Pilih no untuk membuang staging."; then
          if ! xray_routing_apply_candidate_file "${routing_candidate}"; then
            pause
            continue
          fi
        else
          back_rc=$?
          if (( back_rc == 2 )); then
            continue
          fi
        fi
      fi
      xray_stage_candidate_cleanup "${routing_candidate}"
      return 0
    fi

    case "${c}" in
      apply)
        if [[ "${pending_changes}" != "true" ]]; then
          warn "Belum ada staged changes."
          pause
          continue
        fi
        if ! confirm_menu_apply_now "Apply staged WARP per-inbound changes sekarang?"; then
          pause
          continue
        fi
        if ! xray_routing_apply_candidate_file "${routing_candidate}"; then
          pause
          continue
        fi
        xray_stage_candidate_cleanup "${routing_candidate}"
        routing_candidate=""
        pending_changes="false"
        log "Staged WARP per-inbound changes diterapkan."
        pause
        continue
        ;;
      discard)
        if [[ "${pending_changes}" != "true" ]]; then
          warn "Belum ada staged changes."
          pause
          continue
        fi
        if confirm_menu_apply_now "Buang staged WARP per-inbound changes?"; then
          xray_stage_candidate_cleanup "${routing_candidate}"
          routing_candidate=""
          pending_changes="false"
          log "Staged WARP per-inbound changes dibuang."
        fi
        pause
        continue
        ;;
    esac

    if [[ ! "${c}" =~ ^[0-9]+$ ]]; then
      warn "Input tidak valid"
      sleep 1
      continue
    fi
    if (( c < 1 || c > ${#tags[@]} )); then
      warn "No di luar range"
      sleep 1
      continue
    fi

    t="${tags[$((c - 1))]}"

    local cur_status
    if [[ -n "${direct_set[${t}]:-}" && -n "${warp_set[${t}]:-}" ]]; then
      cur_status="conflict"
    elif [[ -n "${direct_set[${t}]:-}" ]]; then
      cur_status="direct"
    elif [[ -n "${warp_set[${t}]:-}" ]]; then
      cur_status="warp"
    else
      cur_status="inherit:${default_mode}"
    fi

    while true; do
      title
      echo "WARP Controls > WARP per-protocol inbounds"
      hr
      echo "Inbound : ${t}"
      echo "Status  : ${cur_status}"
      hr
      echo "  1) direct"
      echo "  2) warp"
      echo "  3) inherit (ikut global)"
      echo "  0) kembali"
      hr
      read -r -p "Pilih: " s

      if is_back_choice "${s}"; then
        break
      fi

	      case "${s}" in
        1)
          if ! confirm_yn_or_back "Stage inbound ${t} ke DIRECT sekarang?"; then
            warn "Stage WARP per-inbound dibatalkan."
            pause
            continue
          fi
          if ! xray_routing_candidate_prepare routing_candidate; then
            warn "Gagal menyiapkan staging routing."
            pause
            continue
          fi
          if warp_inbound_set_effective_mode "${t}" direct "${routing_candidate}"; then
            pending_changes="true"
            log "Per-inbounds di-stage DIRECT: ${t}"
            pause
            break
          fi
	          pause
	          ;;
        2)
          if ! confirm_yn_or_back "Stage inbound ${t} ke WARP sekarang?"; then
            warn "Stage WARP per-inbound dibatalkan."
            pause
            continue
          fi
          if ! xray_routing_candidate_prepare routing_candidate; then
            warn "Gagal menyiapkan staging routing."
            pause
            continue
          fi
          if warp_inbound_set_effective_mode "${t}" warp "${routing_candidate}"; then
            pending_changes="true"
            log "Per-inbounds di-stage WARP: ${t}"
            pause
            break
          fi
	          pause
	          ;;
        3)
          if ! confirm_yn_or_back "Reset inbound ${t} ke INHERIT sekarang?"; then
            warn "Reset WARP per-inbound dibatalkan."
            pause
            continue
          fi
          if ! xray_routing_candidate_prepare routing_candidate; then
            warn "Gagal menyiapkan staging routing."
            pause
            continue
          fi
          if warp_inbound_set_effective_mode "${t}" inherit "${routing_candidate}"; then
            pending_changes="true"
            log "Per-inbounds di-stage INHERIT: ${t}"
            pause
            break
          fi
	          pause
	          ;;
	        *) warn "Pilihan tidak valid" ; sleep 1 ;;
	      esac
    done
  done
}


warp_domain_geosite_menu() {
  need_python3

  local mode="direct"
  local routing_candidate=""
  local pending_changes="false"
  local source_file="" c="" ent=""

  while true; do
    source_file="${routing_candidate:-${XRAY_ROUTING_CONF}}"
    if ! xray_json_file_require_valid "${source_file}" "Xray routing config"; then
      title
      echo "WARP Controls > WARP per-Geosite/Domain"
      hr
      warn "Menu diblok karena routing JSON invalid. Perbaiki dulu sebelum lanjut."
      hr
      pause
      return 0
    fi
    title
    echo "WARP Controls > WARP per-Geosite/Domain"
    hr
    echo "Status: ${mode}"
    if [[ "${pending_changes}" == "true" ]]; then
      echo "Staging: pending apply"
    fi
    hr

    echo "Readonly (template) geosite:"
    xray_routing_readonly_geosite_rule_print || true
    hr

    local header ent
    local -a lst_raw=()
    local -a lst=()

    if [[ "${mode}" == "warp" ]]; then
      header="Custom WARP list:"
      mapfile -t lst_raw < <(xray_routing_custom_domain_list_get "regexp:^\$WARP" "warp" "${source_file}" 2>/dev/null || true)
    else
      header="Custom DIRECT list:"
      mapfile -t lst_raw < <(xray_routing_custom_domain_list_get "regexp:^$" "direct" "${source_file}" 2>/dev/null || true)
    fi

    for ent in "${lst_raw[@]}"; do
      lst+=("${ent}")
    done

    echo "${header}"
    if (( ${#lst[@]} == 0 )); then
      echo "  (kosong)"
    else
      local i
      for (( i=0; i<${#lst[@]}; i++ )); do
        ent="${lst[$i]}"
        if is_readonly_geosite_domain "${ent}"; then
          printf "  %2d. %s (readonly)\n" "$((i + 1))" "${ent}"
        else
          printf "  %2d. %s\n" "$((i + 1))" "${ent}"
        fi
      done
    fi
    hr

    echo "  1) direct"
    echo "  2) warp"
    echo "  3) tambah domain"
    echo "  4) hapus domain"
    if [[ "${pending_changes}" == "true" ]]; then
      echo "  5) apply staged changes"
      echo "  6) discard staged changes"
    fi
    echo "  0) kembali"
    hr
    read -r -p "Pilih: " c

    if is_back_choice "${c}"; then
      if [[ "${pending_changes}" == "true" ]]; then
        local back_rc=0
        if confirm_yn_or_back "Apply staged WARP per-domain/geosite changes sebelum keluar? Pilih no untuk membuang staging."; then
          if ! xray_routing_apply_candidate_file "${routing_candidate}"; then
            pause
            continue
          fi
        else
          back_rc=$?
          if (( back_rc == 2 )); then
            continue
          fi
        fi
      fi
      xray_stage_candidate_cleanup "${routing_candidate}"
      break
    fi

    case "${c}" in
      1) mode="direct" ;;
      2) mode="warp" ;;
      3)
        read -r -p "Entry (contoh: geosite:twitter / example.com) (atau kembali): " ent
        if is_back_choice "${ent}"; then
          continue
        fi
        ent="$(echo "${ent}" | tr -d '[:space:]')"
        if [[ -z "${ent}" || "${ent}" == "regexp:^$" || "${ent}" == "regexp:^\$WARP" ]]; then
          warn "Entry tidak valid / reserved"
          pause
          continue
        fi
        if ! routing_custom_domain_entry_valid "${ent}"; then
          warn "Entry harus berupa geosite:nama atau domain yang valid."
          pause
          continue
        fi
	        if is_readonly_geosite_domain "${ent}"; then
	          warn "Readonly geosite tidak boleh diubah dari menu ini: ${ent}"
	          pause
	          continue
	        fi
	        if ! confirm_yn_or_back "Stage entry ${ent} ke mode ${mode^^} sekarang?"; then
	          warn "Perubahan WARP per-domain/geosite dibatalkan."
	          pause
	          continue
	        fi
	        if ! xray_routing_candidate_prepare routing_candidate; then
	          warn "Gagal menyiapkan staging routing."
	          pause
	          continue
	        fi
	        if ! xray_routing_custom_domain_entry_set_mode_in_file "${routing_candidate}" "${routing_candidate}" "${mode}" "${ent}"; then
	          warn "Gagal men-stage entry WARP per-domain/geosite."
	          pause
	          continue
	        fi
	        pending_changes="true"
	        log "Entry di-stage ${mode^^}: ${ent}"
	        pause
        ;;
      4)
        if (( ${#lst[@]} == 0 )); then
          warn "List kosong"
          pause
          continue
        fi
        read -r -p "Entry yang dihapus (No atau teks) (atau kembali): " ent
        if is_back_choice "${ent}"; then
          continue
        fi
        ent="$(echo "${ent}" | tr -d '[:space:]')"

        if [[ "${ent}" =~ ^[0-9]+$ ]]; then
          if (( ent < 1 || ent > ${#lst[@]} )); then
            warn "No tidak ditemukan"
            pause
            continue
          fi
          ent="${lst[$((ent - 1))]}"
        fi

        if [[ -z "${ent}" || "${ent}" == "regexp:^$" || "${ent}" == "regexp:^\$WARP" ]]; then
          warn "Entry tidak valid / reserved"
          pause
          continue
        fi
	        if is_readonly_geosite_domain "${ent}"; then
	          warn "Readonly geosite tidak bisa dihapus dari menu ini: ${ent}"
	          pause
	          continue
	        fi
	        if ! confirm_yn_or_back "Stage penghapusan entry ${ent} dari mode ${mode^^} sekarang?"; then
	          warn "Penghapusan entry WARP per-domain/geosite dibatalkan."
	          pause
	          continue
	        fi

	        if ! xray_routing_candidate_prepare routing_candidate; then
	          warn "Gagal menyiapkan staging routing."
	          pause
	          continue
	        fi
	        if ! xray_routing_custom_domain_entry_set_mode_in_file "${routing_candidate}" "${routing_candidate}" off "${ent}"; then
	          warn "Gagal men-stage penghapusan entry WARP per-domain/geosite."
	          pause
	          continue
	        fi
	        pending_changes="true"
	        log "Entry di-stage untuk dihapus: ${ent}"
        pause
        ;;
      5)
        if [[ "${pending_changes}" != "true" ]]; then
          warn "Pilihan tidak valid"
          sleep 1
          continue
        fi
        if ! confirm_menu_apply_now "Apply staged WARP per-domain/geosite changes sekarang?"; then
          pause
          continue
        fi
        if ! xray_routing_apply_candidate_file "${routing_candidate}"; then
          pause
          continue
        fi
        xray_stage_candidate_cleanup "${routing_candidate}"
        routing_candidate=""
        pending_changes="false"
        log "Staged WARP per-domain/geosite changes diterapkan."
        pause
        ;;
      6)
        if [[ "${pending_changes}" != "true" ]]; then
          warn "Pilihan tidak valid"
          sleep 1
          continue
        fi
        if confirm_menu_apply_now "Buang staged WARP per-domain/geosite changes?"; then
          xray_stage_candidate_cleanup "${routing_candidate}"
          routing_candidate=""
          pending_changes="false"
          log "Staged WARP per-domain/geosite changes dibuang."
        fi
        pause
        ;;
      *) warn "Pilihan tidak valid" ; sleep 1 ;;
    esac
  done
}



warp_tier_state_target_get() {
  local raw
  raw="$(network_state_get "${WARP_TIER_STATE_KEY}" 2>/dev/null || true)"
  raw="$(echo "${raw}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  case "${raw}" in
    free|plus) echo "${raw}" ;;
    *) echo "unknown" ;;
  esac
}

warp_plus_license_state_get() {
  network_state_get "${WARP_PLUS_LICENSE_STATE_KEY}" 2>/dev/null | tr -d '\r' || true
}

warp_plus_license_mask() {
  local key="${1:-}"
  local len
  key="$(echo "${key}" | tr -d '[:space:]')"
  len="${#key}"
  if (( len <= 8 )); then
    echo "${key}"
    return 0
  fi
  echo "${key:0:4}****${key:len-4:4}"
}

warp_trace_field_get() {
  # args: field_name
  local field="${1:-}"
  local bind_addr trace trace_url
  local -a trace_urls=(
    "https://www.cloudflare.com/cdn-cgi/trace"
    "https://cloudflare.com/cdn-cgi/trace"
    "https://1.1.1.1/cdn-cgi/trace"
    "https://1.0.0.1/cdn-cgi/trace"
  )
  [[ -n "${field}" ]] || return 0
  if ! have_cmd curl; then
    return 0
  fi
  bind_addr="$(warp_proxy_bind_address_get)"

  trace=""
  for trace_url in "${trace_urls[@]}"; do
    trace="$(curl -fsS --retry 1 --retry-delay 1 --max-time 8 --socks5 "${bind_addr}" "${trace_url}" 2>/dev/null || true)"
    [[ -n "${trace}" ]] && break
  done
  [[ -n "${trace}" ]] || return 0
  echo "${trace}" | awk -F= -v k="${field}" '$1==k {print $2; exit}'
}

warp_live_tier_get() {
  local warpv
  warpv="$(warp_trace_field_get warp | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  case "${warpv}" in
    plus) echo "plus" ;;
    on) echo "free" ;;
    off) echo "off" ;;
    *) echo "unknown" ;;
  esac
}

warp_live_tier_display_get() {
  local live target svc_state last_verified=""
  live="$(warp_live_tier_get)"
  if [[ "${live}" != "unknown" ]]; then
    printf '%s\n' "${live}"
    return 0
  fi
  last_verified="$(network_state_get "warp_tier_last_verified" 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]' || true)"
  case "${last_verified}" in
    free|plus) ;;
    *) last_verified="" ;;
  esac
  target="$(warp_tier_state_target_get)"
  if svc_exists "$(warp_backend_service_name_get)"; then
    svc_state="$(svc_state "$(warp_backend_service_name_get)")"
  else
    svc_state="not-installed"
  fi
  if [[ "${svc_state}" == "active" && ( "${target}" == "free" || "${target}" == "plus" ) ]]; then
    if [[ -n "${last_verified}" ]]; then
      printf 'unknown (estimasi %s; terakhir terverifikasi %s)\n' "${target}" "${last_verified}"
    else
      printf 'unknown (estimasi %s; probe trace belum konklusif)\n' "${target}"
    fi
    return 0
  fi
  if [[ -n "${last_verified}" ]]; then
    printf 'unknown (terakhir terverifikasi %s)\n' "${last_verified}"
  else
    printf 'unknown\n'
  fi
}

warp_live_tier_wait_for() {
  local expected="${1:-}"
  local timeout="${2:-20}"
  local checks i live saw_probe="false" socks_ready="false"
  [[ "${expected}" == "free" || "${expected}" == "plus" ]] || return 1
  if [[ ! "${timeout}" =~ ^[0-9]+$ ]] || (( timeout <= 0 )); then
    timeout=20
  fi
  checks=$(( timeout < 1 ? 1 : timeout ))
  for (( i=0; i<checks; i++ )); do
    if warp_proxy_port_is_listening; then
      socks_ready="true"
    fi
    live="$(warp_live_tier_get)"
    case "${live}" in
      free|plus|off) saw_probe="true" ;;
    esac
    [[ "${live}" == "${expected}" ]] && return 0
    sleep 1
  done
  if [[ "${saw_probe}" != "true" ]]; then
    if [[ "${socks_ready}" != "true" ]]; then
      return 1
    fi
    return 2
  fi
  return 1
}

warp_tier_target_effective_get() {
  local target live
  target="$(warp_tier_state_target_get)"
  if [[ "${target}" == "free" || "${target}" == "plus" ]]; then
    echo "${target}"
    return 0
  fi

  live="$(warp_live_tier_get)"
  case "${live}" in
    free|plus)
      echo "${live}"
      ;;
    *)
      echo "unknown"
      ;;
  esac
}

warp_tier_reconnect_target_get() {
  local mode live target
  mode="$(warp_mode_state_get 2>/dev/null || true)"
  if [[ "${mode}" == "zerotrust" ]]; then
    target="$(warp_tier_target_cached_get 2>/dev/null || true)"
    case "${target}" in
      free|plus)
        echo "${target}"
        return 0
        ;;
      *)
        echo "unknown"
        return 0
        ;;
    esac
  fi
  live="$(warp_live_tier_get)"
  case "${live}" in
    free|plus)
      echo "${live}"
      return 0
      ;;
  esac
  target="$(warp_tier_target_effective_get)"
  case "${target}" in
    free|plus) echo "${target}" ;;
    *) echo "unknown" ;;
  esac
}

warp_tier_state_seed_from_live() {
  # Status view tidak boleh mengubah persistent state.
  return 0
}

xray_routing_restart_checked() {
  local state=""

  if systemctl restart xray >/dev/null 2>&1; then
    if svc_wait_active xray 60; then
      return 0
    fi
  else
    state="$(svc_state xray)"
    if [[ "${state}" == "active" ]]; then
      return 1
    fi
  fi

  state="$(svc_state xray)"
  if [[ "${state}" == "failed" || "${state}" == "inactive" || "${state}" == "activating" || "${state}" == "deactivating" ]]; then
    systemctl reset-failed xray >/dev/null 2>&1 || true
    sleep 1
    if systemctl start xray >/dev/null 2>&1 && svc_wait_active xray 60; then
      return 0
    fi
  fi

  return 1
}

xray_routing_post_speed_sync_or_die() {
  # args: backup_routing backup_outbounds context
  local backup_rt="$1"
  local backup_out="$2"
  local context="$3"
  local rollback_notes=()
  local need_sync="false"

  if speed_policy_has_entries; then
    need_sync="true"
  elif speed_policy_artifacts_present_in_xray; then
    need_sync="true"
  fi
  if [[ "${need_sync}" != "true" ]]; then
    return 0
  fi

  if speed_policy_sync_xray && speed_policy_apply_now >/dev/null 2>&1; then
    return 0
  fi

  warn "Sinkronisasi speed policy gagal setelah ${context}. Melakukan rollback..."
  if [[ -n "${backup_rt}" ]]; then
    restore_file_if_exists "${backup_rt}" "${XRAY_ROUTING_CONF}" || rollback_notes+=("restore routing gagal")
  fi
  if [[ -n "${backup_out}" ]]; then
    restore_file_if_exists "${backup_out}" "${XRAY_OUTBOUNDS_CONF}" || rollback_notes+=("restore outbounds gagal")
  fi
  if ! xray_routing_restart_checked; then
    rollback_notes+=("restart xray rollback gagal")
  fi

  if (( ${#rollback_notes[@]} > 0 )); then
    die "Sinkronisasi speed policy gagal setelah ${context}; rollback juga bermasalah: $(IFS=' | '; echo "${rollback_notes[*]}")."
  fi
  die "Sinkronisasi speed policy gagal setelah ${context}; perubahan di-rollback ke state sebelumnya."
}

warp_wireproxy_socks_block_get() {
  if [[ ! -f "${WIREPROXY_CONF}" ]]; then
    cat <<'EOF'
[Socks5]
BindAddress = 127.0.0.1:40000
EOF
    return 0
  fi

  awk '
    BEGIN { inblk=0; found=0 }
    /^[[:space:]]*\[(Socks|Socks5)\][[:space:]]*$/ {
      inblk=1
      if (found==0) {
        print "[Socks5]"
        found=1
      }
      next
    }
    /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
      inblk=0
      next
    }
    inblk { print; next }
    END {
      if (found==0) {
        print "[Socks5]"
        print "BindAddress = 127.0.0.1:40000"
      }
    }
  ' "${WIREPROXY_CONF}" 2>/dev/null
}

warp_wireproxy_apply_profile() {
  # args: wgcf_profile_path
  local profile="${1:-}"
  local tmp backup socks_block ts
  [[ -n "${profile}" && -f "${profile}" ]] || {
    warn "Profile wgcf tidak ditemukan: ${profile}"
    return 1
  }

  (
    local restore_mode="absent"
    local restore_backup=""
    local apply_success="false"
    mkdir -p "$(dirname "${WIREPROXY_CONF}")"
    tmp="$(mktemp "${TMPDIR:-/tmp}/wireproxy-conf.XXXXXX")" || exit 1
    socks_block="$(warp_wireproxy_socks_block_get)"

    trap '
      if [[ "${apply_success}" != "true" ]]; then
        case "${restore_mode}" in
          file)
            [[ -n "${restore_backup}" && -f "${restore_backup}" ]] && install -m 600 "${restore_backup}" "'"${WIREPROXY_CONF}"'" >/dev/null 2>&1 || true
            ;;
          absent)
            rm -f "'"${WIREPROXY_CONF}"'" >/dev/null 2>&1 || true
            ;;
        esac
      fi
      rm -f "${tmp}" "${restore_backup}" >/dev/null 2>&1 || true
    ' EXIT INT TERM HUP QUIT

    awk '
      BEGIN { drop=0 }
      /^[[:space:]]*\[(Socks|Socks5)\][[:space:]]*$/ { drop=1; next }
      /^[[:space:]]*\[[^]]+\][[:space:]]*$/ { drop=0 }
      drop { next }
      { print }
    ' "${profile}" > "${tmp}"
    printf "\n%s\n" "${socks_block}" >> "${tmp}"

    if [[ -f "${WIREPROXY_CONF}" ]]; then
      ts="$(date +%Y%m%d-%H%M%S)"
      backup="${WIREPROXY_CONF}.bak.${ts}"
      cp -f "${WIREPROXY_CONF}" "${backup}" 2>/dev/null || true
      restore_backup="$(mktemp "${TMPDIR:-/tmp}/wireproxy-restore.XXXXXX" 2>/dev/null || true)"
      if [[ -n "${restore_backup}" ]] && cp -f "${WIREPROXY_CONF}" "${restore_backup}" 2>/dev/null; then
        restore_mode="file"
      else
        rm -f "${restore_backup}" >/dev/null 2>&1 || true
        restore_backup=""
        restore_mode="file"
      fi
    fi

    if ! install -m 600 "${tmp}" "${WIREPROXY_CONF}"; then
      warn "Gagal menulis wireproxy config: ${WIREPROXY_CONF}"
      exit 1
    fi
    apply_success="true"
    trap - EXIT INT TERM HUP QUIT
    rm -f "${tmp}" "${restore_backup}" >/dev/null 2>&1 || true
    exit 0
  )
  return $?
}

warp_wgcf_register_noninteractive_in_dir() {
  local target_dir="${1:-${WGCF_DIR}}"
  local reg_log
  reg_log="$(mktemp "/tmp/wgcf-register-manage.XXXXXX.log")"

  mkdir -p "${target_dir}"
  pushd "${target_dir}" >/dev/null || {
    warn "Gagal masuk ke ${target_dir}"
    return 1
  }

  if [[ -f "wgcf-account.toml" ]]; then
    popd >/dev/null || true
    return 0
  fi

  if have_cmd expect; then
    expect <<'EOF' >"${reg_log}" 2>&1 || true
set timeout 180
log_user 1
spawn wgcf register
expect {
  -re {Use the arrow keys.*} { send "\r"; exp_continue }
  -re {Do you agree.*} { send "\r"; exp_continue }
  -re {\(y/n\)} { send "y\r"; exp_continue }
  -re {Yes/No} { send "\r"; exp_continue }
  -re {accept} { send "\r"; exp_continue }
  eof
}
EOF
  else
    set +o pipefail
    yes | wgcf register >"${reg_log}" 2>&1 || true
    set -o pipefail
  fi

  popd >/dev/null || true
  if [[ ! -f "${target_dir}/wgcf-account.toml" ]]; then
    warn "wgcf register gagal. Log: ${reg_log}"
    tail -n 60 "${reg_log}" >&2 || true
    return 1
  fi
  rm -f "${reg_log}" >/dev/null 2>&1 || true
  return 0
}

warp_wgcf_register_noninteractive() {
  warp_wgcf_register_noninteractive_in_dir "${WGCF_DIR}"
}

warp_wgcf_seed_stage_from_live_account() {
  local target_dir="${1:-}"
  [[ -n "${target_dir}" ]] || return 1
  mkdir -p "${target_dir}" 2>/dev/null || return 1
  if [[ -s "${WGCF_DIR}/wgcf-account.toml" ]]; then
    install -m 600 "${WGCF_DIR}/wgcf-account.toml" "${target_dir}/wgcf-account.toml" || return 1
  fi
  return 0
}

warp_wgcf_build_profile_in_dir() {
  # args: target_dir tier [license_key]
  local target_dir="${1:-${WGCF_DIR}}"
  local tier="${2:-free}"
  local license_key="${3:-}"
  local gen_log upd_log
  gen_log="$(mktemp "/tmp/wgcf-generate-manage.XXXXXX.log")"
  upd_log="$(mktemp "/tmp/wgcf-update-manage.XXXXXX.log")"

  mkdir -p "${target_dir}"
  if [[ ! -f "${target_dir}/wgcf-account.toml" ]]; then
    if ! warp_wgcf_register_noninteractive_in_dir "${target_dir}"; then
      return 1
    fi
  fi

  pushd "${target_dir}" >/dev/null || {
    warn "Gagal masuk ke ${target_dir}"
    return 1
  }

  if [[ "${tier}" == "plus" ]]; then
    license_key="$(echo "${license_key}" | tr -d '[:space:]')"
    if [[ -z "${license_key}" ]]; then
      popd >/dev/null || true
      warn "License key WARP+ kosong"
      return 1
    fi
    if ! wgcf update --license-key "${license_key}" >"${upd_log}" 2>&1; then
      popd >/dev/null || true
      warn "wgcf update --license-key gagal. Log: ${upd_log}"
      tail -n 60 "${upd_log}" >&2 || true
      return 1
    fi
  fi

  if ! wgcf generate -p "${target_dir}/wgcf-profile.conf" >"${gen_log}" 2>&1; then
    popd >/dev/null || true
    warn "wgcf generate gagal. Log: ${gen_log}"
    tail -n 60 "${gen_log}" >&2 || true
    return 1
  fi
  popd >/dev/null || true

  if [[ ! -s "${target_dir}/wgcf-profile.conf" ]]; then
    warn "wgcf-profile.conf tidak ditemukan setelah generate"
    return 1
  fi
  rm -f "${gen_log}" "${upd_log}" >/dev/null 2>&1 || true
  return 0
}

warp_wgcf_build_profile() {
  # args: tier [license_key]
  local tier="${1:-free}"
  local license_key="${2:-}"
  warp_wgcf_build_profile_in_dir "${WGCF_DIR}" "${tier}" "${license_key}"
}

warp_wgcf_install_live_files_from_dir() {
  local source_dir="${1:-}"
  local tmp_account="" tmp_profile=""
  [[ -n "${source_dir}" ]] || return 1
  (
    local backup_account="" backup_profile=""
    local restore_account_mode="absent" restore_profile_mode="absent"
    local install_success="false"

    mkdir -p "${WGCF_DIR}" || exit 1
    [[ -s "${source_dir}/wgcf-account.toml" ]] || exit 1
    [[ -s "${source_dir}/wgcf-profile.conf" ]] || exit 1
    tmp_account="$(mktemp "${WGCF_DIR}/.wgcf-account.XXXXXX" 2>/dev/null || true)"
    tmp_profile="$(mktemp "${WGCF_DIR}/.wgcf-profile.XXXXXX" 2>/dev/null || true)"
    [[ -n "${tmp_account}" && -n "${tmp_profile}" ]] || exit 1

    trap '
      if [[ "${install_success}" != "true" ]]; then
        case "${restore_account_mode}" in
          file)
            [[ -n "${backup_account}" && -f "${backup_account}" ]] && install -m 600 "${backup_account}" "'"${WGCF_DIR}/wgcf-account.toml"'" >/dev/null 2>&1 || true
            ;;
          absent)
            rm -f "'"${WGCF_DIR}/wgcf-account.toml"'" >/dev/null 2>&1 || true
            ;;
        esac
        case "${restore_profile_mode}" in
          file)
            [[ -n "${backup_profile}" && -f "${backup_profile}" ]] && install -m 600 "${backup_profile}" "'"${WGCF_DIR}/wgcf-profile.conf"'" >/dev/null 2>&1 || true
            ;;
          absent)
            rm -f "'"${WGCF_DIR}/wgcf-profile.conf"'" >/dev/null 2>&1 || true
            ;;
        esac
      fi
      rm -f "${tmp_account}" "${tmp_profile}" "${backup_account}" "${backup_profile}" >/dev/null 2>&1 || true
    ' EXIT INT TERM HUP QUIT

    if [[ -f "${WGCF_DIR}/wgcf-account.toml" ]]; then
      backup_account="$(mktemp "${WGCF_DIR}/.wgcf-account.restore.XXXXXX" 2>/dev/null || true)"
      [[ -n "${backup_account}" ]] && cp -f "${WGCF_DIR}/wgcf-account.toml" "${backup_account}" 2>/dev/null || true
      restore_account_mode="file"
    fi
    if [[ -f "${WGCF_DIR}/wgcf-profile.conf" ]]; then
      backup_profile="$(mktemp "${WGCF_DIR}/.wgcf-profile.restore.XXXXXX" 2>/dev/null || true)"
      [[ -n "${backup_profile}" ]] && cp -f "${WGCF_DIR}/wgcf-profile.conf" "${backup_profile}" 2>/dev/null || true
      restore_profile_mode="file"
    fi

    install -m 600 "${source_dir}/wgcf-account.toml" "${tmp_account}" || exit 1
    install -m 600 "${source_dir}/wgcf-profile.conf" "${tmp_profile}" || exit 1
    mv -f "${tmp_account}" "${WGCF_DIR}/wgcf-account.toml" || exit 1
    mv -f "${tmp_profile}" "${WGCF_DIR}/wgcf-profile.conf" || exit 1

    install_success="true"
    trap - EXIT INT TERM HUP QUIT
    rm -f "${backup_account}" "${backup_profile}" >/dev/null 2>&1 || true
    exit 0
  )
  return $?
}

warp_zero_trust_cli_status_line_get() {
  local line=""
  line="$(warp_zero_trust_cli_first_line status 2>/dev/null || true)"
  [[ -n "${line}" ]] || line="unknown"
  printf '%s\n' "${line}"
}

warp_zero_trust_cli_registration_line_get() {
  local line=""
  line="$(warp_zero_trust_cli_first_line registration show 2>/dev/null || true)"
  [[ -n "${line}" ]] || line="unknown"
  printf '%s\n' "${line}"
}

warp_zero_trust_ssh_guard_state_get() {
  local st="" effective="0" backend_applied="" backend_effective=""
  if ! declare -F ssh_network_runtime_status_get >/dev/null 2>&1; then
    printf 'unknown\n'
    return 0
  fi
  st="$(ssh_network_runtime_status_get 2>/dev/null || true)"
  effective="$(printf '%s\n' "${st}" | awk -F'=' '/^effective_warp_users=/{print $2; exit}')"
  backend_applied="$(printf '%s\n' "${st}" | awk -F'=' '/^warp_backend_applied=/{print $2; exit}')"
  backend_effective="$(printf '%s\n' "${st}" | awk -F'=' '/^warp_backend_effective=/{print $2; exit}')"
  [[ -n "${backend_applied}" ]] || backend_applied="${backend_effective:-idle}"
  if [[ "${effective}" =~ ^[0-9]+$ ]] && (( effective > 0 )); then
    if [[ "${backend_applied}" == "local-proxy" ]]; then
      printf 'ok (%s effective warp users via Local Proxy)\n' "${effective}"
    else
      printf 'blocked (%s effective warp users, backend applied=%s)\n' "${effective}" "${backend_applied}"
    fi
    return 0
  fi
  if [[ "${backend_applied}" == "local-proxy" ]]; then
    printf 'ok (Local Proxy ready)\n'
  else
    printf 'ok\n'
  fi
}

warp_zero_trust_require_ssh_compatible() {
  local guard=""
  guard="$(warp_zero_trust_ssh_guard_state_get)"
  case "${guard}" in
    ok*|unknown) return 0 ;;
  esac
  warn "Zero Trust membutuhkan runtime routing tambahan yang sudah applied sehat di backend Local Proxy."
  warn "Set backend routing tambahan ke Local Proxy lalu apply, atau kosongkan effective WARP users dulu."
  warn "Status guard: ${guard}"
  return 1
}

warp_zero_trust_render_mdm_file() {
  local cfg team client_id client_secret proxy_port tmp
  cfg="$(warp_zero_trust_config_get)"
  team="$(printf '%s\n' "${cfg}" | awk -F'=' '/^team=/{print $2; exit}')"
  client_id="$(printf '%s\n' "${cfg}" | awk -F'=' '/^client_id=/{print substr($0,11); exit}')"
  client_secret="$(printf '%s\n' "${cfg}" | awk -F'=' '/^client_secret=/{print substr($0,15); exit}')"
  proxy_port="$(warp_zero_trust_proxy_port_get)"
  [[ -n "${team}" && -n "${client_id}" && -n "${client_secret}" ]] || return 1

  mkdir -p "$(dirname "${WARP_ZEROTRUST_MDM_FILE}")" "${WARP_ZEROTRUST_ROOT}" 2>/dev/null || true
  tmp="$(mktemp "${WORK_DIR}/.warp-zerotrust-mdm.XXXXXX" 2>/dev/null || true)"
  [[ -n "${tmp}" ]] || tmp="${WORK_DIR}/.warp-zerotrust-mdm.$$"
  printf '%s\0%s\0%s' "${team}" "${client_id}" "${client_secret}" | python3 -c '
import sys
from xml.sax.saxutils import escape

dst = sys.argv[1]
proxy_port = sys.argv[2]
parts = sys.stdin.buffer.read().split(b"\0")
if len(parts) < 3:
    raise SystemExit(1)
team, client_id, client_secret = [item.decode("utf-8") for item in parts[:3]]
xml = f"""<?xml version="1.0" encoding="UTF-8"?>
<dict>
  <key>organization</key>
  <string>{escape(team)}</string>
  <key>display_name</key>
  <string>Autoscript Zero Trust</string>
  <key>auth_client_id</key>
  <string>{escape(client_id)}</string>
  <key>auth_client_secret</key>
  <string>{escape(client_secret)}</string>
  <key>onboarding</key>
  <false/>
  <key>auto_connect</key>
  <integer>1</integer>
  <key>service_mode</key>
  <string>proxy</string>
  <key>proxy_port</key>
  <integer>{proxy_port}</integer>
</dict>
"""
with open(dst, "w", encoding="utf-8") as fh:
  fh.write(xml)
' "${tmp}" "${proxy_port}" || return 1
  mv -f "${tmp}" "${WARP_ZEROTRUST_MDM_FILE}" || {
    rm -f "${tmp}" >/dev/null 2>&1 || true
    return 1
  }
  chmod 600 "${WARP_ZEROTRUST_MDM_FILE}" >/dev/null 2>&1 || true
  return 0
}

warp_tier_show_status() {
  local mode mode_display target live live_display svc_state license_raw license_masked socks_state="unknown"
  local last_verified="" last_verified_at="" last_verified_age=""
  mode="$(warp_mode_cli_get)"
  mode_display="$(warp_mode_display_get 2>/dev/null || true)"
  if [[ "${mode}" == "zerotrust" ]]; then
    warp_tier_zero_trust_show_status
    return 0
  fi

  target="$(warp_tier_target_effective_get)"
  live="$(warp_live_tier_get)"
  live_display="$(warp_live_tier_display_get)"
  license_raw="$(warp_plus_license_state_get)"
  license_masked="$(warp_plus_license_mask "${license_raw}")"
  last_verified="$(network_state_get "warp_tier_last_verified" 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]' || true)"
  last_verified_at="$(network_state_get "warp_tier_last_verified_at" 2>/dev/null | tr -d '\r' || true)"
  if [[ -n "${last_verified_at}" ]] && have_cmd date; then
    local now_ts="" verified_ts="" age_sec=""
    now_ts="$(date +%s 2>/dev/null || true)"
    verified_ts="$(date -d "${last_verified_at}" +%s 2>/dev/null || true)"
    if [[ "${now_ts}" =~ ^[0-9]+$ && "${verified_ts}" =~ ^[0-9]+$ && "${now_ts}" -ge "${verified_ts}" ]]; then
      age_sec="$((now_ts - verified_ts))"
      if (( age_sec < 60 )); then
        last_verified_age="${age_sec}s lalu"
      elif (( age_sec < 3600 )); then
        last_verified_age="$((age_sec / 60))m lalu"
      elif (( age_sec < 86400 )); then
        last_verified_age="$((age_sec / 3600))j lalu"
      else
        last_verified_age="$((age_sec / 86400))h lalu"
      fi
    fi
  fi
  warp_tier_state_seed_from_live
  if svc_exists wireproxy; then
    svc_state="$(svc_state wireproxy)"
  else
    svc_state="not-installed"
  fi
  if warp_proxy_port_is_listening; then
    socks_state="listening"
  elif [[ "${svc_state}" == "active" ]]; then
    socks_state="not-listening"
  fi

  printf "Mode          : %s\n" "${mode_display:-Free/Plus}"
  printf "Backend       : Free/Plus (wgcf + wireproxy)\n"
  printf "Free/Plus Tier: %s\n" "${target}"
  printf "Free/Plus Live: %s\n" "${live_display}"
  printf "wireproxy     : %s\n" "${svc_state}"
  printf "SOCKS5        : %s\n" "${socks_state}"
  printf "Zero Trust    : available via cloudflare-warp backend\n"
  if [[ "${live}" == "unknown" ]]; then
    printf "Probe Status  : trace Cloudflare via SOCKS belum konklusif; gunakan target + status wireproxy sebagai petunjuk sementara.\n"
    if [[ "${target}" == "free" || "${target}" == "plus" ]]; then
      printf "Operational   : estimasi %s (wireproxy=%s, socks=%s)\n" "${target}" "${svc_state}" "${socks_state}"
    fi
    case "${last_verified}" in
      free|plus) printf "Last Verified : %s\n" "${last_verified}" ;;
    esac
    if [[ -n "${last_verified_at}" ]]; then
      printf "Verified At   : %s\n" "${last_verified_at}"
      [[ -n "${last_verified_age}" ]] && printf "Verified Age  : %s\n" "${last_verified_age}"
    fi
  fi
  if [[ -n "${license_raw}" ]]; then
    printf "WARP+ License : %s\n" "${license_masked}"
  else
    printf "WARP+ License : (kosong)\n"
  fi
}

warp_tier_free_plus_show_status() {
  local active_mode="" target="" svc_state="not-installed" socks_state="unknown"
  local zt_service_state="missing" zt_proxy_state="not-listening" zt_runtime_note=""
  local last_verified="" last_verified_at="" last_verified_age="" license_raw="" license_masked=""
  active_mode="$(warp_mode_state_get 2>/dev/null || true)"
  if [[ "${active_mode}" != "zerotrust" ]]; then
    warp_tier_show_status
    return 0
  fi

  target="$(warp_tier_target_cached_get)"
  last_verified="$(warp_tier_last_verified_get)"
  last_verified_at="$(warp_tier_last_verified_at_get)"
  last_verified_age="$(warp_tier_last_verified_age_get "${last_verified_at}")"
  license_raw="$(warp_plus_license_state_get)"
  license_masked="$(warp_plus_license_mask "${license_raw}")"
  if svc_exists wireproxy; then
    svc_state="$(svc_state wireproxy)"
  fi
  if svc_exists "${WARP_ZEROTRUST_SERVICE}"; then
    zt_service_state="$(svc_state "${WARP_ZEROTRUST_SERVICE}")"
  fi
  zt_proxy_state="$(warp_zero_trust_proxy_state_get 2>/dev/null || printf 'not-listening\n')"
  socks_state="standby (host in Zero Trust)"
  case "${zt_service_state}:${zt_proxy_state}" in
    active:listening)
      zt_runtime_note="active on host; Free/Plus saat ini standby"
      ;;
    active:*)
      zt_runtime_note="service active, tetapi proxy ${zt_proxy_state}; Free/Plus saat ini standby"
      ;;
    inactive:*)
      zt_runtime_note="inactive on host; Free/Plus saat ini standby"
      ;;
    missing:*)
      zt_runtime_note="service missing on host; Free/Plus saat ini standby"
      ;;
    *)
      zt_runtime_note="${zt_service_state} on host; proxy ${zt_proxy_state}; Free/Plus saat ini standby"
      ;;
  esac

  printf "Mode          : Free/Plus\n"
  printf "Backend       : Free/Plus (wgcf + wireproxy)\n"
  printf "Free/Plus Tier: %s\n" "${target}"
  printf "Free/Plus Live: standby (host in Zero Trust)\n"
  printf "wireproxy     : %s\n" "${svc_state}"
  printf "SOCKS5        : %s\n" "${socks_state}"
  printf "Zero Trust    : %s\n" "${zt_runtime_note}"
  if [[ "${target}" == "unknown" ]]; then
    printf "Probe Status  : target Free/Plus belum tersimpan; status live tidak diprobe saat host aktif di Zero Trust.\n"
  fi
  case "${last_verified}" in
    free|plus) printf "Last Verified : %s\n" "${last_verified}" ;;
  esac
  if [[ -n "${last_verified_at}" ]]; then
    printf "Verified At   : %s\n" "${last_verified_at}"
    [[ -n "${last_verified_age}" ]] && printf "Verified Age  : %s\n" "${last_verified_age}"
  fi
  if [[ -n "${license_raw}" ]]; then
    printf "WARP+ License : %s\n" "${license_masked}"
  else
    printf "WARP+ License : (kosong)\n"
  fi
}

warp_tier_zero_trust_show_status() {
  local cfg team client_id client_secret proxy_port config_state="" active_mode="" active_mode_display=""
  local svc_state="missing" mdm_state="missing" proxy_state="not-listening"
  local cli_status="unknown" reg_status="unknown" ssh_guard="unknown"
  cfg="$(warp_zero_trust_config_get)"
  active_mode="$(warp_mode_state_get)"
  active_mode_display="$(warp_mode_display_get 2>/dev/null || true)"
  team="$(printf '%s\n' "${cfg}" | awk -F'=' '/^team=/{print $2; exit}')"
  client_id="$(printf '%s\n' "${cfg}" | awk -F'=' '/^client_id=/{print substr($0,11); exit}')"
  client_secret="$(printf '%s\n' "${cfg}" | awk -F'=' '/^client_secret=/{print substr($0,15); exit}')"
  proxy_port="$(printf '%s\n' "${cfg}" | awk -F'=' '/^proxy_port=/{print $2; exit}')"
  config_state="$(printf '%s\n' "${cfg}" | awk -F'=' '/^config_state=/{print $2; exit}')"

  if svc_exists "${WARP_ZEROTRUST_SERVICE}"; then
    svc_state="$(svc_state "${WARP_ZEROTRUST_SERVICE}")"
  fi
  [[ -f "${WARP_ZEROTRUST_MDM_FILE}" ]] && mdm_state="present"
  proxy_state="$(warp_zero_trust_proxy_state_get)"
  if have_cmd warp-cli; then
    cli_status="$(warp_zero_trust_cli_status_line_get)"
    reg_status="$(warp_zero_trust_cli_registration_line_get)"
  fi
  ssh_guard="$(warp_zero_trust_ssh_guard_state_get)"

  printf "Mode          : %s\n" "${active_mode_display:-Zero Trust}"
  printf "Backend       : cloudflare-warp (Zero Trust proxy)\n"
  printf "Team Name     : %s\n" "${team:-"(kosong)"}"
  printf "Client ID     : %s\n" "$(warp_zero_trust_secret_mask "${client_id}")"
  printf "Client Secret : %s\n" "$(warp_zero_trust_secret_mask "${client_secret}")"
  printf "Config State  : %s\n" "${config_state:-incomplete}"
  printf "%-14s: %s\n" "${WARP_ZEROTRUST_SERVICE}" "${svc_state}"
  printf "MDM Policy    : %s\n" "${mdm_state}"
  printf "Proxy Bind    : 127.0.0.1:%s\n" "${proxy_port:-${WARP_ZEROTRUST_PROXY_PORT}}"
  printf "Proxy State   : %s\n" "${proxy_state}"
  printf "CLI Status    : %s\n" "${cli_status}"
  printf "Registration  : %s\n" "${reg_status}"
  printf "Routing Guard : %s\n" "${ssh_guard}"
}

warp_tier_zero_trust_show_requirements() {
  local proxy_port=""
  proxy_port="$(warp_zero_trust_proxy_port_get)"
  printf "Requirement   : cloudflare-warp client dan warp-cli harus tersedia di host\n"
  printf "Requirement   : team name + service token client id/client secret harus terisi\n"
  printf "Requirement   : backend ini memakai proxy lokal port %s untuk outbound Xray\n" "${proxy_port}"
  printf "Requirement   : bila ada effective WARP users di routing tambahan, runtime local proxy wajib applied sehat sebelum Zero Trust diaktifkan\n"
}

warp_tier_zero_trust_show_rollout_notes() {
  printf "Rollout Note  : Zero Trust di codebase ini diperlakukan sebagai mode backend baru\n"
  printf "Rollout Note  : Free/Plus tetap memakai wgcf + wireproxy\n"
  printf "Rollout Note  : Zero Trust memakai proxy lokal host yang bisa dipakai Xray dan routing tambahan via Local Proxy\n"
  printf "Rollout Note  : Routing tambahan kompatibel bila backend WARP memakai local proxy bersama port lokal WARP\n"
  printf "Rollout Note  : Backend dedicated lama dipertahankan sebagai fallback Free/Plus, tetapi tidak kompatibel dengan Zero Trust\n"
}

warp_free_plus_backend_prepare_activate_unlocked() {
  if svc_exists "${WARP_ZEROTRUST_SERVICE}" && svc_is_active "${WARP_ZEROTRUST_SERVICE}"; then
    warp_zero_trust_cli_run disconnect >/dev/null 2>&1 || true
    svc_stop_checked "${WARP_ZEROTRUST_SERVICE}" 30 || return 1
  fi
  return 0
}

warp_zero_trust_disconnect_backend_unlocked() {
  if have_cmd warp-cli; then
    warp_zero_trust_cli_run disconnect >/dev/null 2>&1 || true
  fi
  if svc_exists "${WARP_ZEROTRUST_SERVICE}" && svc_is_active "${WARP_ZEROTRUST_SERVICE}"; then
    svc_stop_checked "${WARP_ZEROTRUST_SERVICE}" 30 || return 1
  fi
  return 0
}

warp_zero_trust_team_set() {
  local team="${1:-}"
  team="$(printf '%s' "${team}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  [[ -n "${team}" ]] || return 1
  [[ "${team}" =~ ^[a-z0-9][a-z0-9-]*$ ]] || return 1
  warp_zero_trust_config_set_values WARP_ZEROTRUST_TEAM "${team}"
}

warp_zero_trust_client_id_set() {
  local value="${1:-}"
  value="$(printf '%s' "${value}" | tr -d '[:space:]')"
  [[ -n "${value}" ]] || return 1
  warp_zero_trust_config_set_values WARP_ZEROTRUST_CLIENT_ID "${value}"
}

warp_zero_trust_client_secret_set() {
  local value="${1:-}"
  value="$(printf '%s' "${value}" | tr -d '[:space:]')"
  [[ -n "${value}" ]] || return 1
  warp_zero_trust_config_set_values WARP_ZEROTRUST_CLIENT_SECRET "${value}"
}

warp_zero_trust_configure_credentials() {
  local cfg="" current_team="" current_client_id="" current_client_secret=""
  local team_input="" client_id_input="" client_secret_input=""
  local final_team="" final_client_id="" final_client_secret=""
  local masked_client_id="" masked_client_secret=""

  cfg="$(warp_zero_trust_config_get)"
  current_team="$(printf '%s\n' "${cfg}" | awk -F'=' '/^team=/{print $2; exit}')"
  current_client_id="$(printf '%s\n' "${cfg}" | awk -F'=' '/^client_id=/{print substr($0,11); exit}')"
  current_client_secret="$(printf '%s\n' "${cfg}" | awk -F'=' '/^client_secret=/{print substr($0,15); exit}')"
  masked_client_id="$(warp_zero_trust_secret_mask "${current_client_id}")"
  masked_client_secret="$(warp_zero_trust_secret_mask "${current_client_secret}")"

  title
  echo "$(warp_tier_zero_trust_menu_title "Setup Credentials")"
  hr
  printf "Isi tiga field sekaligus. Tekan ENTER untuk mempertahankan nilai lama.\n"
  printf "Ketik 'kembali' pada field mana pun untuk batal tanpa mengubah config.\n"
  hr
  printf "Current Team Name     : %s\n" "${current_team:-"(kosong)"}"
  printf "Current Client ID     : %s\n" "${masked_client_id}"
  printf "Current Client Secret : %s\n" "${masked_client_secret}"
  hr

  read -r -p "Team name Zero Trust [${current_team:-kosong}]: " team_input
  if is_back_choice "${team_input}"; then
    return 0
  fi
  read -r -s -p "Service token client id [ENTER=pakai nilai lama]: " client_id_input
  echo
  if is_back_choice "${client_id_input}"; then
    return 0
  fi
  read -r -s -p "Service token client secret [ENTER=pakai nilai lama]: " client_secret_input
  echo
  if is_back_choice "${client_secret_input}"; then
    return 0
  fi

  if [[ -n "${team_input}" ]]; then
    final_team="$(printf '%s' "${team_input}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  else
    final_team="${current_team}"
  fi
  if [[ -n "${client_id_input}" ]]; then
    final_client_id="$(printf '%s' "${client_id_input}" | tr -d '[:space:]')"
  else
    final_client_id="${current_client_id}"
  fi
  if [[ -n "${client_secret_input}" ]]; then
    final_client_secret="$(printf '%s' "${client_secret_input}" | tr -d '[:space:]')"
  else
    final_client_secret="${current_client_secret}"
  fi

  [[ -n "${final_team}" && "${final_team}" =~ ^[a-z0-9][a-z0-9-]*$ ]] || {
    warn "Team name Zero Trust tidak valid."
    hr
    pause
    return 1
  }
  [[ -n "${final_client_id}" ]] || {
    warn "Client ID Zero Trust tidak boleh kosong."
    hr
    pause
    return 1
  }
  [[ -n "${final_client_secret}" ]] || {
    warn "Client secret Zero Trust tidak boleh kosong."
    hr
    pause
    return 1
  }

  if ! warp_zero_trust_config_set_values \
    WARP_ZEROTRUST_TEAM "${final_team}" \
    WARP_ZEROTRUST_CLIENT_ID "${final_client_id}" \
    WARP_ZEROTRUST_CLIENT_SECRET "${final_client_secret}"; then
    warn "Gagal menyimpan kredensial Zero Trust."
    hr
    pause
    return 1
  fi

  log "Kredensial Zero Trust disimpan."
  hr
  pause
  return 0
}

warp_action_confirm_or_cancel() {
  local prompt="${1:-}"
  local cancel_msg="${2:-Aksi dibatalkan.}"
  local confirm_rc=0

  confirm_yn_or_back "${prompt}"
  confirm_rc=$?
  case "${confirm_rc}" in
    0)
      return 0
      ;;
    1|2)
      warn "${cancel_msg}"
      hr
      pause
      return 1
      ;;
    *)
      warn "${cancel_msg}"
      hr
      pause
      return 1
      ;;
  esac
}

warp_zero_trust_apply_connect() {
  local rc
  title
  echo "$(warp_tier_zero_trust_menu_title "Apply / Connect")"
  hr

  if ! warp_action_confirm_or_cancel "Aktifkan backend Zero Trust sekarang?" "Aktivasi Zero Trust dibatalkan."; then
    return 0
  fi

  (
    local cfg config_state snap_dir warp_txn_success="false"
    flock -x 200

    if ! have_cmd warp-cli; then
      warn "warp-cli tidak ditemukan. Install Cloudflare WARP client dulu di host ini."
      hr
      pause
      exit 1
    fi
    if ! svc_exists "${WARP_ZEROTRUST_SERVICE}"; then
      warn "Service ${WARP_ZEROTRUST_SERVICE} tidak ditemukan."
      hr
      pause
      exit 1
    fi
    if ! warp_zero_trust_require_ssh_compatible; then
      hr
      pause
      exit 1
    fi

    cfg="$(warp_zero_trust_config_get)"
    config_state="$(printf '%s\n' "${cfg}" | awk -F'=' '/^config_state=/{print $2; exit}')"
    if [[ "${config_state}" != "complete" ]]; then
      warn "Config Zero Trust belum lengkap. Isi team name, client id, dan client secret dulu."
      hr
      pause
      exit 1
    fi

    snap_dir="$(mktemp -d "${WORK_DIR}/.warp-zerotrust.XXXXXX" 2>/dev/null || true)"
    [[ -n "${snap_dir}" ]] || snap_dir="${WORK_DIR}/.warp-zerotrust.$$"
    mkdir -p "${snap_dir}" 2>/dev/null || true
    if ! warp_runtime_snapshot_capture "${snap_dir}"; then
      warn "Gagal membuat snapshot sebelum aktivasi Zero Trust."
      rm -rf "${snap_dir}" >/dev/null 2>&1 || true
      hr
      pause
      exit 1
    fi
    trap 'if [[ "${warp_txn_success}" != "true" ]]; then warp_runtime_snapshot_restore_on_abort "${snap_dir}"; fi' EXIT

    if svc_exists wireproxy && svc_is_active wireproxy; then
      svc_stop_checked wireproxy 30 || warp_runtime_snapshot_restore_or_fail "${snap_dir}" "Gagal menghentikan wireproxy sebelum aktivasi Zero Trust."
    fi
    if ! warp_zero_trust_render_mdm_file; then
      warp_runtime_snapshot_restore_or_fail "${snap_dir}" "Gagal merender mdm.xml Zero Trust."
    fi
    if ! warp_zero_trust_post_restart_health_check; then
      warp_runtime_snapshot_restore_or_fail "${snap_dir}" "Backend Zero Trust tidak sehat sesudah start."
    fi
    if ! warp_mode_state_set zerotrust; then
      warp_runtime_snapshot_restore_or_fail "${snap_dir}" "Gagal menyimpan state mode Zero Trust."
    fi

    warp_txn_success="true"
    trap - EXIT
    rm -rf "${snap_dir}" >/dev/null 2>&1 || true
    hr
    warp_tier_show_status
    hr
    pause
  ) 200>"${WARP_LOCK_FILE}"
  rc=$?
  return "${rc}"
}

warp_zero_trust_disconnect() {
  local rc
  title
  echo "$(warp_tier_zero_trust_menu_title "Disconnect")"
  hr

  if ! warp_action_confirm_or_cancel "Putuskan backend Zero Trust sekarang?" "Disconnect Zero Trust dibatalkan."; then
    return 0
  fi

  (
    flock -x 200
    if ! warp_zero_trust_disconnect_backend_unlocked; then
      warn "Gagal menghentikan backend Zero Trust."
      hr
      pause
      exit 1
    fi
    if ! warp_mode_state_set zerotrust; then
      warn "Gagal mempertahankan state mode Zero Trust."
      hr
      pause
      exit 1
    fi
    hr
    warp_tier_show_status
    hr
    pause
  ) 200>"${WARP_LOCK_FILE}"
  rc=$?
  return "${rc}"
}

warp_zero_trust_return_to_free_plus() {
  local rc
  title
  echo "$(warp_tier_zero_trust_menu_title "Return to Free/Plus")"
  hr

  if ! warp_action_confirm_or_cancel "Kembalikan backend WARP ke Free/Plus sekarang?" "Kembali ke Free/Plus dibatalkan."; then
    return 0
  fi

  (
    local snap_dir warp_txn_success="false"
    flock -x 200

    if ! have_cmd wireproxy; then
      warn "wireproxy tidak ditemukan. Jalankan setup.sh atau pasang wireproxy dulu."
      hr
      pause
      exit 1
    fi

    snap_dir="$(mktemp -d "${WORK_DIR}/.warp-back-freeplus.XXXXXX" 2>/dev/null || true)"
    [[ -n "${snap_dir}" ]] || snap_dir="${WORK_DIR}/.warp-back-freeplus.$$"
    mkdir -p "${snap_dir}" 2>/dev/null || true
    if ! warp_runtime_snapshot_capture "${snap_dir}"; then
      warn "Gagal membuat snapshot sebelum kembali ke Free/Plus."
      rm -rf "${snap_dir}" >/dev/null 2>&1 || true
      hr
      pause
      exit 1
    fi
    trap 'if [[ "${warp_txn_success}" != "true" ]]; then warp_runtime_snapshot_restore_on_abort "${snap_dir}"; fi' EXIT

    if ! warp_zero_trust_disconnect_backend_unlocked; then
      warp_runtime_snapshot_restore_or_fail "${snap_dir}" "Gagal menghentikan backend Zero Trust sebelum kembali ke Free/Plus."
    fi
    if ! warp_wireproxy_post_restart_health_check; then
      warp_runtime_snapshot_restore_or_fail "${snap_dir}" "wireproxy tidak sehat sesudah kembali ke Free/Plus."
    fi
    if ! warp_mode_state_set consumer; then
      warp_runtime_snapshot_restore_or_fail "${snap_dir}" "Gagal menyimpan state mode Free/Plus."
    fi

    warp_txn_success="true"
    trap - EXIT
    rm -rf "${snap_dir}" >/dev/null 2>&1 || true
    hr
    warp_tier_show_status
    hr
    pause
  ) 200>"${WARP_LOCK_FILE}"
  rc=$?
  return "${rc}"
}

warp_tier_switch_free() {
  title
  echo "$(warp_tier_free_plus_menu_title "Switch ke WARP Free")"
  hr

  if ! warp_action_confirm_or_cancel "Switch ke WARP Free sekarang?" "Switch ke WARP Free dibatalkan."; then
    return 0
  fi

  local rc
  (
    local snap_dir stage_dir warp_txn_success="false"
    flock -x 200

    if ! have_cmd wgcf; then
      warn "wgcf tidak ditemukan. Jalankan setup.sh terlebih dulu."
      hr
      pause
      exit 1
    fi
    if ! have_cmd wireproxy; then
      warn "wireproxy tidak ditemukan. Jalankan setup.sh terlebih dulu."
      hr
      pause
      exit 1
    fi

    mkdir -p "${WGCF_DIR}"
    snap_dir="$(mktemp -d "${WORK_DIR}/.warp-free.XXXXXX" 2>/dev/null || true)"
    [[ -n "${snap_dir}" ]] || snap_dir="${WORK_DIR}/.warp-free.$$"
    mkdir -p "${snap_dir}" 2>/dev/null || true
    if ! warp_runtime_snapshot_capture "${snap_dir}"; then
      warn "Gagal membuat snapshot WARP sebelum switch free."
      rm -rf "${snap_dir}" >/dev/null 2>&1 || true
      hr
      pause
      exit 1
    fi
    trap 'if [[ "${warp_txn_success}" != "true" ]]; then warp_runtime_snapshot_restore_on_abort "${snap_dir}"; fi' EXIT
    if ! warp_free_plus_backend_prepare_activate_unlocked; then
      warp_runtime_snapshot_restore_or_fail "${snap_dir}" "Gagal menonaktifkan backend Zero Trust sebelum switch ke WARP free."
    fi
    stage_dir="$(mktemp -d "${WORK_DIR}/.warp-free-stage.XXXXXX" 2>/dev/null || true)"
    [[ -n "${stage_dir}" ]] || stage_dir="${WORK_DIR}/.warp-free-stage.$$"
    mkdir -p "${stage_dir}" 2>/dev/null || true
    if ! warp_wgcf_seed_stage_from_live_account "${stage_dir}"; then
      rm -rf "${stage_dir}" >/dev/null 2>&1 || true
      warp_runtime_snapshot_restore_or_fail "${snap_dir}" "Gagal menyalin akun WGCF lama ke staging WARP free."
    fi
    if ! warp_wgcf_build_profile_in_dir "${stage_dir}" free; then
      rm -rf "${stage_dir}" >/dev/null 2>&1 || true
      warp_runtime_snapshot_restore_or_fail "${snap_dir}" "Gagal build profile WARP free."
    fi
    if ! warp_wgcf_install_live_files_from_dir "${stage_dir}"; then
      rm -rf "${stage_dir}" >/dev/null 2>&1 || true
      warp_runtime_snapshot_restore_or_fail "${snap_dir}" "Gagal menyiapkan file WARP free baru."
    fi
    rm -rf "${stage_dir}" >/dev/null 2>&1 || true
    if ! warp_wireproxy_apply_profile "${WGCF_DIR}/wgcf-profile.conf"; then
      warp_runtime_snapshot_restore_or_fail "${snap_dir}" "Gagal apply profile WARP free ke wireproxy."
    fi

    if ! warp_wireproxy_restart_checked; then
      warp_runtime_snapshot_restore_or_fail "${snap_dir}" "wireproxy tidak aktif setelah switch WARP free."
    fi
    local tier_wait_rc=0
    if ! warp_live_tier_wait_for free 20; then
      tier_wait_rc=$?
    fi
    if (( tier_wait_rc == 1 )); then
      warp_runtime_snapshot_restore_or_fail "${snap_dir}" "Live WARP tier tidak sesuai target free setelah switch."
    elif (( tier_wait_rc == 2 )); then
      warn "Probe tier WARP free belum memberi jawaban pasti; mempertahankan hasil switch tanpa rollback keras."
    fi
    if ! network_state_set_many "${WARP_MODE_STATE_KEY}" "consumer" "${WARP_TIER_STATE_KEY}" "free" "warp_tier_last_verified" "free" "warp_tier_last_verified_at" "$(date '+%Y-%m-%d %H:%M:%S')"; then
      warp_runtime_snapshot_restore_or_fail "${snap_dir}" "Gagal menyimpan target tier WARP free."
    fi
    if ! warp_runtime_refresh_ssh_network_after_profile_change; then
      warp_runtime_snapshot_restore_or_fail "${snap_dir}" "Runtime routing tambahan gagal disegarkan sesudah switch WARP free."
    fi
    log "WARP tier target di-set: free"
    warp_txn_success="true"
    trap - EXIT
    rm -rf "${snap_dir}" >/dev/null 2>&1 || true
    hr
    warp_tier_show_status
    hr
    pause
  ) 200>"${WARP_LOCK_FILE}"
  rc=$?
  return "${rc}"
}

warp_tier_switch_plus() {
  local rc
  title
  echo "$(warp_tier_free_plus_menu_title "Switch ke WARP Plus")"
  hr

  if ! warp_action_confirm_or_cancel "Switch ke WARP Plus sekarang?" "Switch ke WARP Plus dibatalkan."; then
    return 0
  fi

  (
    local saved_key key masked snap_dir stage_dir warp_txn_success="false"
    flock -x 200

    if ! have_cmd wgcf; then
      warn "wgcf tidak ditemukan. Jalankan setup.sh terlebih dulu."
      hr
      pause
      exit 1
    fi
    if ! have_cmd wireproxy; then
      warn "wireproxy tidak ditemukan. Jalankan setup.sh terlebih dulu."
      hr
      pause
      exit 1
    fi

    saved_key="$(warp_plus_license_state_get)"
    masked="$(warp_plus_license_mask "${saved_key}")"
    if [[ -n "${saved_key}" ]]; then
      echo "License tersimpan: ${masked}"
      read -r -p "Input WARP+ License Key (Enter=pakai tersimpan, atau kembali): " key
      if is_back_choice "${key}"; then
        exit 0
      fi
      key="$(echo "${key}" | tr -d '[:space:]')"
      [[ -n "${key}" ]] || key="${saved_key}"
    else
      read -r -p "Input WARP+ License Key (atau kembali): " key
      if is_back_choice "${key}"; then
        exit 0
      fi
      key="$(echo "${key}" | tr -d '[:space:]')"
    fi

    if [[ -z "${key}" ]]; then
      warn "License key WARP+ kosong"
      hr
      pause
      exit 1
    fi

    snap_dir="$(mktemp -d "${WORK_DIR}/.warp-plus.XXXXXX" 2>/dev/null || true)"
    [[ -n "${snap_dir}" ]] || snap_dir="${WORK_DIR}/.warp-plus.$$"
    mkdir -p "${snap_dir}" 2>/dev/null || true
    if ! warp_runtime_snapshot_capture "${snap_dir}"; then
      warn "Gagal membuat snapshot WARP sebelum switch plus."
      rm -rf "${snap_dir}" >/dev/null 2>&1 || true
      hr
      pause
      exit 1
    fi
    trap 'if [[ "${warp_txn_success}" != "true" ]]; then warp_runtime_snapshot_restore_on_abort "${snap_dir}"; fi' EXIT
    if ! warp_free_plus_backend_prepare_activate_unlocked; then
      warp_runtime_snapshot_restore_or_fail "${snap_dir}" "Gagal menonaktifkan backend Zero Trust sebelum switch ke WARP plus."
    fi

    stage_dir="$(mktemp -d "${WORK_DIR}/.warp-plus-stage.XXXXXX" 2>/dev/null || true)"
    [[ -n "${stage_dir}" ]] || stage_dir="${WORK_DIR}/.warp-plus-stage.$$"
    mkdir -p "${stage_dir}" 2>/dev/null || true
    if ! warp_wgcf_seed_stage_from_live_account "${stage_dir}"; then
      rm -rf "${stage_dir}" >/dev/null 2>&1 || true
      warp_runtime_snapshot_restore_or_fail "${snap_dir}" "Gagal menyalin akun WGCF lama ke staging WARP plus."
    fi
    if ! warp_wgcf_build_profile_in_dir "${stage_dir}" plus "${key}"; then
      rm -rf "${stage_dir}" >/dev/null 2>&1 || true
      warp_runtime_snapshot_restore_or_fail "${snap_dir}" "Gagal build profile WARP plus."
    fi
    if ! warp_wgcf_install_live_files_from_dir "${stage_dir}"; then
      rm -rf "${stage_dir}" >/dev/null 2>&1 || true
      warp_runtime_snapshot_restore_or_fail "${snap_dir}" "Gagal menyiapkan file WARP plus baru."
    fi
    rm -rf "${stage_dir}" >/dev/null 2>&1 || true
    if ! warp_wireproxy_apply_profile "${WGCF_DIR}/wgcf-profile.conf"; then
      warp_runtime_snapshot_restore_or_fail "${snap_dir}" "Gagal apply profile WARP plus ke wireproxy."
    fi

    if ! warp_wireproxy_restart_checked; then
      warp_runtime_snapshot_restore_or_fail "${snap_dir}" "wireproxy tidak aktif setelah switch WARP plus."
    fi
    local tier_wait_rc=0
    if ! warp_live_tier_wait_for plus 20; then
      tier_wait_rc=$?
    fi
    if (( tier_wait_rc == 1 )); then
      warp_runtime_snapshot_restore_or_fail "${snap_dir}" "Live WARP tier tidak sesuai target plus setelah switch."
    elif (( tier_wait_rc == 2 )); then
      warn "Probe tier WARP plus belum memberi jawaban pasti; mempertahankan hasil switch tanpa rollback keras."
    fi
    if ! network_state_set_many \
      "${WARP_MODE_STATE_KEY}" "consumer" \
      "${WARP_TIER_STATE_KEY}" "plus" \
      "${WARP_PLUS_LICENSE_STATE_KEY}" "${key}" \
      "warp_tier_last_verified" "plus" \
      "warp_tier_last_verified_at" "$(date '+%Y-%m-%d %H:%M:%S')"; then
      warp_runtime_snapshot_restore_or_fail "${snap_dir}" "Gagal menyimpan target tier WARP plus."
    fi
    if ! warp_runtime_refresh_ssh_network_after_profile_change; then
      warp_runtime_snapshot_restore_or_fail "${snap_dir}" "Runtime routing tambahan gagal disegarkan sesudah switch WARP plus."
    fi
    log "WARP tier target di-set: plus"
    warp_txn_success="true"
    trap - EXIT
    rm -rf "${snap_dir}" >/dev/null 2>&1 || true
    hr
    warp_tier_show_status
    hr
    pause
  ) 200>"${WARP_LOCK_FILE}"
  rc=$?
  return "${rc}"
}

warp_tier_reconnect_regenerate() {
  local rc
  title
  echo "$(warp_tier_free_plus_menu_title "Reconnect/Regenerate")"
  hr

  if ! warp_action_confirm_or_cancel "Reconnect/Regenerate WARP sesuai target sekarang?" "Reconnect/Regenerate WARP dibatalkan."; then
    return 0
  fi

  (
    local target key snap_dir stage_dir warp_txn_success="false"
    flock -x 200

    if ! have_cmd wgcf; then
      warn "wgcf tidak ditemukan. Jalankan setup.sh terlebih dulu."
      hr
      pause
      exit 1
    fi
    if ! have_cmd wireproxy; then
      warn "wireproxy tidak ditemukan. Jalankan setup.sh terlebih dulu."
      hr
      pause
      exit 1
    fi

    target="$(warp_tier_reconnect_target_get)"
    if [[ "${target}" != "free" && "${target}" != "plus" ]]; then
      warn "Target reconnect Free/Plus belum diketahui."
      warn "Gunakan menu Switch ke WARP Free atau Switch ke WARP Plus dulu agar target tersimpan jelas."
      hr
      pause
      exit 1
    fi

    snap_dir="$(mktemp -d "${WORK_DIR}/.warp-reconnect.XXXXXX" 2>/dev/null || true)"
    [[ -n "${snap_dir}" ]] || snap_dir="${WORK_DIR}/.warp-reconnect.$$"
    mkdir -p "${snap_dir}" 2>/dev/null || true
    if ! warp_runtime_snapshot_capture "${snap_dir}"; then
      warn "Gagal membuat snapshot WARP sebelum reconnect."
      rm -rf "${snap_dir}" >/dev/null 2>&1 || true
      hr
      pause
      exit 1
    fi
    trap 'if [[ "${warp_txn_success}" != "true" ]]; then warp_runtime_snapshot_restore_on_abort "${snap_dir}"; fi' EXIT
    if ! warp_free_plus_backend_prepare_activate_unlocked; then
      warp_runtime_snapshot_restore_or_fail "${snap_dir}" "Gagal menonaktifkan backend Zero Trust sebelum reconnect/regenerate Free/Plus."
    fi
    stage_dir="$(mktemp -d "${WORK_DIR}/.warp-reconnect-stage.XXXXXX" 2>/dev/null || true)"
    [[ -n "${stage_dir}" ]] || stage_dir="${WORK_DIR}/.warp-reconnect-stage.$$"
    mkdir -p "${stage_dir}" 2>/dev/null || true
    if ! warp_wgcf_seed_stage_from_live_account "${stage_dir}"; then
      rm -rf "${stage_dir}" >/dev/null 2>&1 || true
      warp_runtime_snapshot_restore_or_fail "${snap_dir}" "Gagal menyalin akun WGCF lama ke staging reconnect."
    fi
    if [[ "${target}" == "plus" ]]; then
      key="$(warp_plus_license_state_get)"
      key="$(echo "${key}" | tr -d '[:space:]')"
      if [[ -z "${key}" ]]; then
        rm -rf "${stage_dir}" >/dev/null 2>&1 || true
        rm -rf "${snap_dir}" >/dev/null 2>&1 || true
        warn "Target plus aktif, tapi license key kosong. Gunakan menu Switch ke WARP Plus dulu."
        hr
        pause
        exit 1
      fi
      if ! warp_wgcf_build_profile_in_dir "${stage_dir}" plus "${key}"; then
        rm -rf "${stage_dir}" >/dev/null 2>&1 || true
        warp_runtime_snapshot_restore_or_fail "${snap_dir}" "Gagal build profile WARP plus saat reconnect."
      fi
    else
      if ! warp_wgcf_build_profile_in_dir "${stage_dir}" free; then
        rm -rf "${stage_dir}" >/dev/null 2>&1 || true
        warp_runtime_snapshot_restore_or_fail "${snap_dir}" "Gagal build profile WARP free saat reconnect."
      fi
    fi

    if ! warp_wgcf_install_live_files_from_dir "${stage_dir}"; then
      rm -rf "${stage_dir}" >/dev/null 2>&1 || true
      warp_runtime_snapshot_restore_or_fail "${snap_dir}" "Gagal menyiapkan file WARP reconnect baru."
    fi
    rm -rf "${stage_dir}" >/dev/null 2>&1 || true
    if ! warp_wireproxy_apply_profile "${WGCF_DIR}/wgcf-profile.conf"; then
      warp_runtime_snapshot_restore_or_fail "${snap_dir}" "Gagal apply profile WARP saat reconnect."
    fi

    if ! warp_wireproxy_restart_checked; then
      warp_runtime_snapshot_restore_or_fail "${snap_dir}" "wireproxy tidak aktif setelah reconnect/regenerate."
    fi
    local tier_wait_rc=0
    if ! warp_live_tier_wait_for "${target}" 20; then
      tier_wait_rc=$?
    fi
    if (( tier_wait_rc == 1 )); then
      warp_runtime_snapshot_restore_or_fail "${snap_dir}" "Live WARP tier tidak sesuai target setelah reconnect/regenerate."
    elif (( tier_wait_rc == 2 )); then
      warn "Probe tier WARP belum memberi jawaban pasti setelah reconnect/regenerate; mempertahankan hasil reconnect tanpa rollback keras."
    fi

    if ! network_state_set_many "${WARP_MODE_STATE_KEY}" "consumer" "${WARP_TIER_STATE_KEY}" "${target}" "warp_tier_last_verified" "${target}" "warp_tier_last_verified_at" "$(date '+%Y-%m-%d %H:%M:%S')" >/dev/null 2>&1; then
      warp_runtime_snapshot_restore_or_fail "${snap_dir}" "Gagal menyimpan target tier WARP setelah reconnect."
    fi
    if ! warp_runtime_refresh_ssh_network_after_profile_change; then
      warp_runtime_snapshot_restore_or_fail "${snap_dir}" "Runtime routing tambahan gagal disegarkan sesudah reconnect/regenerate WARP."
    fi
    warp_txn_success="true"
    trap - EXIT
    rm -rf "${snap_dir}" >/dev/null 2>&1 || true
    log "Reconnect/regenerate selesai untuk target tier: ${target}"
    hr
    warp_tier_show_status
    hr
    pause
  ) 200>"${WARP_LOCK_FILE}"
  rc=$?
  return "${rc}"
}

warp_tier_menu() {
  while true; do
    title
    echo "$(warp_tier_menu_title)"
    hr
    warp_tier_show_status
    hr
    echo "  1) Show overall status"
    echo "  2) Free/Plus"
    echo "  3) Zero Trust"
    echo "  0) Back"
    hr
    read -r -p "Pilih: " c
    case "${c}" in
      1)
        title
        echo "$(warp_tier_menu_title "Status")"
        hr
        warp_tier_show_status
        hr
        pause
        ;;
      2) warp_tier_free_plus_menu ;;
      3) warp_tier_zero_trust_menu ;;
      0|kembali|k|back|b) break ;;
      *) warn "Pilihan tidak valid" ; sleep 1 ;;
    esac
  done
}

warp_tier_free_plus_menu() {
  while true; do
    local active_mode
    active_mode="$(warp_mode_state_get)"
    title
    echo "$(warp_tier_free_plus_menu_title)"
    hr
    if [[ "${active_mode}" == "zerotrust" ]]; then
      printf "Current Mode  : Zero Trust (aksi di menu ini akan mengembalikan backend ke Free/Plus)\n"
      hr
    fi
    warp_tier_free_plus_show_status
    hr
    echo "  1) Show status"
    echo "  2) Switch ke WARP Free"
    echo "  3) Switch ke WARP Plus"
    echo "  4) Reconnect/Regenerate sesuai target"
    echo "  0) Back"
    hr
    read -r -p "Pilih: " c
    case "${c}" in
      1)
        title
        echo "$(warp_tier_free_plus_menu_title "Status")"
        hr
        warp_tier_free_plus_show_status
        hr
        pause
        ;;
      2)
        if ! warp_tier_switch_free; then
          :
        fi
        ;;
      3)
        if ! warp_tier_switch_plus; then
          :
        fi
        ;;
      4)
        if ! warp_tier_reconnect_regenerate; then
          :
        fi
        ;;
      0|kembali|k|back|b) break ;;
      *) warn "Pilihan tidak valid" ; sleep 1 ;;
    esac
  done
}

warp_tier_zero_trust_menu() {
  while true; do
    title
    echo "$(warp_tier_zero_trust_menu_title)"
    hr
    warp_tier_zero_trust_show_status
    hr
    echo "  1) Show status"
    echo "  2) Setup Credentials"
    echo "  3) Apply / Connect Zero Trust"
    echo "  4) Disconnect Zero Trust"
    echo "  5) Return to Free/Plus"
    echo "  6) Requirements"
    echo "  7) Rollout notes"
    echo "  0) Back"
    hr
    read -r -p "Pilih: " c
    case "${c}" in
      1)
        title
        echo "$(warp_tier_zero_trust_menu_title "Status")"
        hr
        warp_tier_zero_trust_show_status
        hr
        pause
        ;;
      2)
        if ! warp_zero_trust_configure_credentials; then
          :
        fi
        ;;
      3)
        if ! warp_zero_trust_apply_connect; then
          :
        fi
        ;;
      4)
        if ! warp_zero_trust_disconnect; then
          :
        fi
        ;;
      5)
        if ! warp_zero_trust_return_to_free_plus; then
          :
        fi
        ;;
      6)
        title
        echo "$(warp_tier_zero_trust_menu_title "Requirements")"
        hr
        warp_tier_zero_trust_show_requirements
        hr
        pause
        ;;
      7)
        title
        echo "$(warp_tier_zero_trust_menu_title "Rollout Notes")"
        hr
        warp_tier_zero_trust_show_rollout_notes
        hr
        pause
        ;;
      0|kembali|k|back|b) break ;;
      *) warn "Pilihan tidak valid" ; sleep 1 ;;
    esac
  done
}

warp_controls_menu() {
  # shellcheck disable=SC2034 # used by ui_menu_render_options via nameref
  local -a items=(
    "1|WARP Status"
    "2|Restart WARP"
    "3|WARP Global"
    "4|Per User"
    "5|Per Inbound"
    "6|Per Domain"
    "0|Back"
  )
  while true; do
    ui_menu_screen_begin "$(xray_network_menu_title "WARP")"
    ui_menu_render_options items 76
    hr
    read -r -p "Pilih: " c
    case "${c}" in
      1) warp_status ;;
      2)
        local backend_svc backend_name
        backend_svc="$(warp_backend_service_name_get)"
        backend_name="$(warp_backend_display_name_get)"
        title
        echo "Restart ${backend_name}"
        hr
        if ! confirm_yn_or_back "Restart ${backend_name} sekarang?"; then
          warn "Restart ${backend_name} dibatalkan."
          hr
          pause
          continue
        fi
        if svc_exists "${backend_svc}"; then
          if ! warp_backend_post_restart_health_check; then
            warn "Restart ${backend_name} gagal."
            hr
            pause
            continue
          fi
        else
          warn "${backend_svc} tidak terdeteksi"
        fi
        hr
        pause
        ;;
      3) menu_run_isolated_report "WARP Global" warp_global_menu ;;
      4) menu_run_isolated_report "WARP Per User" warp_per_user_menu ;;
      5) menu_run_isolated_report "WARP Per Inbounds" warp_per_inbounds_menu ;;
      6) menu_run_isolated_report "WARP Domain Geosite" warp_domain_geosite_menu ;;
      0|kembali|k|back|b) break ;;
      *) warn "Pilihan tidak valid" ; sleep 1 ;;
    esac
  done
}

domain_geosite_menu() {
  need_python3
  local routing_candidate=""
  local pending_changes="false"
  local source_file="" c="" ent="" no="" remove_entry=""
  while true; do
    source_file="${routing_candidate:-${XRAY_ROUTING_CONF}}"
    title
    echo "$(xray_network_menu_title "Domain/Geosite Routing (Direct List)")"
    hr
    if [[ "${pending_changes}" == "true" ]]; then
      echo "Mode edit : STAGED"
      echo "Catatan   : perubahan belum diterapkan ke runtime."
      hr
    fi
    echo "Template (readonly):"
    python3 - <<'PY' "${XRAY_ROUTING_CONF}" 2>/dev/null || true
import json, sys
src=sys.argv[1]
try:
  with open(src,'r',encoding='utf-8') as f:
    cfg=json.load(f)
except Exception:
  raise SystemExit(0)
rules=((cfg.get('routing') or {}).get('rules') or [])
tpl=None
for r in rules:
  if not isinstance(r, dict):
    continue
  if r.get('type') != 'field':
    continue
  if r.get('outboundTag') != 'direct':
    continue
  dom=r.get('domain') or []
  if isinstance(dom, list) and ('geosite:apple' in dom or 'geosite:google' in dom):
    tpl=dom
    break
if not isinstance(tpl, list):
  tpl=[]
for i,d in enumerate([x for x in tpl if isinstance(x,str)] , start=1):
  print(f"  {i:>2}. {d}")
PY
    hr

    echo "Editable (custom direct list):"
    local -a direct_entries=()
    mapfile -t direct_entries < <(xray_routing_custom_domain_list_get "regexp:^$" "direct" "${source_file}" 2>/dev/null || true)
    if (( ${#direct_entries[@]} == 0 )); then
      echo "  (kosong)"
    else
      local i
      for (( i=0; i<${#direct_entries[@]}; i++ )); do
        printf "  %2d. %s\n" "$((i + 1))" "${direct_entries[$i]}"
      done
    fi
    hr

    echo "  1) Add domain/geosite ke custom list"
    echo "  2) Remove domain/geosite dari custom list"
    if [[ "${pending_changes}" == "true" ]]; then
      echo "  3) Apply staged changes"
      echo "  4) Discard staged changes"
    fi
    echo "  0) Back"
    hr
    read -r -p "Pilih: " c
    case "${c}" in
      1)
        read -r -p "Masukkan entry (contoh: geosite:twitter / example.com) (atau kembali): " ent
        if is_back_choice "${ent}"; then
          continue
        fi
        ent="$(echo "${ent}" | tr -d '[:space:]')"
        if [[ -z "${ent}" ]]; then
          warn "Entry kosong"
          pause
          continue
        fi
        if [[ "${ent}" == "regexp:^$" ]]; then
          warn "Entry reserved"
          pause
          continue
        fi
        if ! routing_custom_domain_entry_valid "${ent}"; then
          warn "Entry harus berupa geosite:nama atau domain yang valid."
          pause
          continue
        fi
        if ! confirm_menu_apply_now "Stage entry ${ent} ke custom direct list sekarang?"; then
          pause
          continue
        fi
        if ! xray_routing_candidate_prepare routing_candidate; then
          warn "Gagal menyiapkan staging routing."
          pause
          continue
        fi
        if ! xray_routing_custom_domain_entry_set_mode_in_file "${routing_candidate}" "${routing_candidate}" direct "${ent}"; then
          warn "Gagal men-stage custom direct list."
          pause
          continue
        fi
        pending_changes="true"
        log "Entry di-stage: ${ent}"
        pause
        ;;
      2)
        read -r -p "Hapus nomor entry (lihat daftar) (atau kembali): " no
        if is_back_word_choice "${no}"; then
          continue
        fi
        if [[ -z "${no}" || ! "${no}" =~ ^[0-9]+$ || "${no}" -le 0 ]]; then
          warn "Nomor tidak valid"
          pause
          continue
        fi
        if (( no > ${#direct_entries[@]} )); then
          warn "Nomor di luar range"
          pause
          continue
        fi
        remove_entry="${direct_entries[$((no - 1))]}"
        if [[ -z "${remove_entry}" ]]; then
          warn "Nomor di luar range"
          pause
          continue
        fi
        if ! confirm_menu_apply_now "Stage penghapusan entry ${remove_entry} dari custom direct list sekarang?"; then
          pause
          continue
        fi
        if ! xray_routing_candidate_prepare routing_candidate; then
          warn "Gagal menyiapkan staging routing."
          pause
          continue
        fi
        if ! xray_routing_custom_domain_entry_set_mode_in_file "${routing_candidate}" "${routing_candidate}" off "${remove_entry}"; then
          warn "Gagal men-stage penghapusan custom direct list."
          pause
          continue
        fi
        pending_changes="true"
        log "Entry di-stage untuk dihapus: ${remove_entry}"
        pause
        ;;
      3)
        if [[ "${pending_changes}" != "true" ]]; then
          warn "Pilihan tidak valid"
          sleep 1
          continue
        fi
        if ! confirm_menu_apply_now "Apply staged direct routing changes sekarang?"; then
          pause
          continue
        fi
        if ! xray_routing_apply_candidate_file "${routing_candidate}"; then
          pause
          continue
        fi
        xray_stage_candidate_cleanup "${routing_candidate}"
        routing_candidate=""
        pending_changes="false"
        log "Staged direct routing changes diterapkan."
        pause
        ;;
      4)
        if [[ "${pending_changes}" != "true" ]]; then
          warn "Pilihan tidak valid"
          sleep 1
          continue
        fi
        if confirm_menu_apply_now "Buang staged direct routing changes?"; then
          xray_stage_candidate_cleanup "${routing_candidate}"
          routing_candidate=""
          pending_changes="false"
          log "Staged direct routing changes dibuang."
        fi
        pause
        ;;
      0|kembali|k|back|b)
        if [[ "${pending_changes}" == "true" ]]; then
          local back_rc=0
          if confirm_yn_or_back "Apply staged direct routing changes sebelum keluar? Pilih no untuk membuang staging."; then
            if ! xray_routing_apply_candidate_file "${routing_candidate}"; then
              pause
              continue
            fi
          else
            back_rc=$?
            if (( back_rc == 2 )); then
              continue
            fi
          fi
        fi
        xray_stage_candidate_cleanup "${routing_candidate}"
        break
        ;;
      *) warn "Pilihan tidak valid" ; sleep 1 ;;
    esac
  done
}
