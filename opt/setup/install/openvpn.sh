#!/usr/bin/env bash

OPENVPN_RUNTIME_ENV_FILE="${OPENVPN_RUNTIME_ENV_FILE:-/etc/default/openvpn-runtime}"
OVPN_TCP_SERVICE_NAME="${OVPN_TCP_SERVICE_NAME:-ovpn-tcp.service}"
OVPNWS_PROXY_SERVICE_NAME="${OVPNWS_PROXY_SERVICE_NAME:-ovpnws-proxy.service}"
OPENVPN_EXPIRED_SERVICE_NAME="${OPENVPN_EXPIRED_SERVICE_NAME:-openvpn-expired.service}"
OPENVPN_EXPIRED_TIMER_NAME="${OPENVPN_EXPIRED_TIMER_NAME:-openvpn-expired.timer}"
OPENVPN_SPEED_SERVICE_NAME="${OPENVPN_SPEED_SERVICE_NAME:-openvpn-speed.service}"
OVPN_TCP_BIND_WAS_SET="${OVPN_TCP_BIND+x}"
OVPN_TCP_PORT_WAS_SET="${OVPN_TCP_PORT+x}"
OVPNWS_PROXY_BIND_WAS_SET="${OVPNWS_PROXY_BIND+x}"
OVPNWS_PROXY_PORT_WAS_SET="${OVPNWS_PROXY_PORT+x}"
OVPNWS_PATH_WAS_SET="${OVPNWS_PATH+x}"
OVPNWS_HANDSHAKE_TIMEOUT_WAS_SET="${OVPNWS_HANDSHAKE_TIMEOUT+x}"
OVPN_DEFAULT_CLIENT_NAME_WAS_SET="${OVPN_DEFAULT_CLIENT_NAME+x}"
OVPN_SERVER_SUBNET_WAS_SET="${OVPN_SERVER_SUBNET+x}"
OVPN_SERVER_NETMASK_WAS_SET="${OVPN_SERVER_NETMASK+x}"
OVPN_CCD_DIR_WAS_SET="${OVPN_CCD_DIR+x}"
OVPN_DOWNLOADS_DIR_WAS_SET="${OVPN_DOWNLOADS_DIR+x}"
OVPN_SPEED_TUN_IFACE_WAS_SET="${OVPN_SPEED_TUN_IFACE+x}"
OVPN_SPEED_IFB_IFACE_WAS_SET="${OVPN_SPEED_IFB_IFACE+x}"
OVPN_SPEED_STATE_FILE_WAS_SET="${OVPN_SPEED_STATE_FILE+x}"
OVPN_SPEED_INTERVAL_WAS_SET="${OVPN_SPEED_INTERVAL+x}"
OVPN_SPEED_DEFAULT_RATE_MBIT_WAS_SET="${OVPN_SPEED_DEFAULT_RATE_MBIT+x}"
OVPN_TCP_PORT="${OVPN_TCP_PORT:-21194}"
OVPNWS_PROXY_PORT="${OVPNWS_PROXY_PORT:-21195}"
OVPNWS_PATH="${OVPNWS_PATH:-/}"
OVPNWS_HANDSHAKE_TIMEOUT="${OVPNWS_HANDSHAKE_TIMEOUT:-10}"
OVPN_ENABLE_TCP="${OVPN_ENABLE_TCP:-true}"
OVPN_ENABLE_SSL="${OVPN_ENABLE_SSL:-true}"
OVPN_ENABLE_WS="${OVPN_ENABLE_WS:-true}"
OVPN_TCP_BIND="${OVPN_TCP_BIND:-127.0.0.1}"
OVPNWS_PROXY_BIND="${OVPNWS_PROXY_BIND:-127.0.0.1}"
OVPN_SERVER_CONF="${OVPN_SERVER_CONF:-/etc/openvpn/server/ovpn-tcp.conf}"
OVPN_PKI_DIR="${OVPN_PKI_DIR:-/etc/openvpn/server/pki}"
OVPN_CA_FILE="${OVPN_CA_FILE:-${OVPN_PKI_DIR}/ca.crt}"
OVPN_CERT_FILE="${OVPN_CERT_FILE:-${OVPN_PKI_DIR}/server.crt}"
OVPN_KEY_FILE="${OVPN_KEY_FILE:-${OVPN_PKI_DIR}/server.key}"
OVPN_DH_FILE="${OVPN_DH_FILE:-none}"
OVPN_TLS_CRYPT_FILE="${OVPN_TLS_CRYPT_FILE:-${OVPN_PKI_DIR}/tls-crypt.key}"
OVPN_CLIENTS_DIR="${OVPN_CLIENTS_DIR:-/etc/openvpn/clients}"
OVPN_CCD_DIR="${OVPN_CCD_DIR:-/etc/openvpn/server/ccd}"
OVPN_DOWNLOADS_DIR="${OVPN_DOWNLOADS_DIR:-/var/lib/openvpn/downloads}"
OVPN_DEFAULT_CLIENT_NAME="${OVPN_DEFAULT_CLIENT_NAME:-autoscript}"
OVPN_SERVER_SUBNET="${OVPN_SERVER_SUBNET:-10.199.0.0}"
OVPN_SERVER_NETMASK="${OVPN_SERVER_NETMASK:-255.255.255.0}"
OVPN_SPEED_TUN_IFACE="${OVPN_SPEED_TUN_IFACE:-tun0}"
OVPN_SPEED_IFB_IFACE="${OVPN_SPEED_IFB_IFACE:-ifb2}"
OVPN_SPEED_STATE_FILE="${OVPN_SPEED_STATE_FILE:-/var/lib/openvpn/speed-state.json}"
OVPN_SPEED_INTERVAL="${OVPN_SPEED_INTERVAL:-5}"
OVPN_SPEED_DEFAULT_RATE_MBIT="${OVPN_SPEED_DEFAULT_RATE_MBIT:-10000}"

openvpn_runtime_read_env_value() {
  local key="$1"
  local env_file="${2:-${OPENVPN_RUNTIME_ENV_FILE}}"
  [[ -r "${env_file}" ]] || return 1
  awk -F= -v key="${key}" '
    $1 == key {
      sub(/^[[:space:]]+/, "", $2)
      sub(/[[:space:]]+$/, "", $2)
      print $2
      exit
    }
  ' "${env_file}"
}

openvpn_runtime_load_persisted_env() {
  local env_file="${OPENVPN_RUNTIME_ENV_FILE}"
  local value=""
  [[ -r "${env_file}" ]] || return 0

  if [[ -z "${OVPN_TCP_BIND_WAS_SET}" ]]; then
    value="$(openvpn_runtime_read_env_value OVPN_TCP_BIND "${env_file}" 2>/dev/null || true)"
    [[ -n "${value}" ]] && OVPN_TCP_BIND="${value}"
  fi
  if [[ -z "${OVPN_TCP_PORT_WAS_SET}" ]]; then
    value="$(openvpn_runtime_read_env_value OVPN_TCP_PORT "${env_file}" 2>/dev/null || true)"
    [[ -n "${value}" ]] && OVPN_TCP_PORT="${value}"
  fi
  if [[ -z "${OVPNWS_PROXY_BIND_WAS_SET}" ]]; then
    value="$(openvpn_runtime_read_env_value OVPNWS_PROXY_BIND "${env_file}" 2>/dev/null || true)"
    [[ -n "${value}" ]] && OVPNWS_PROXY_BIND="${value}"
  fi
  if [[ -z "${OVPNWS_PROXY_PORT_WAS_SET}" ]]; then
    value="$(openvpn_runtime_read_env_value OVPNWS_PROXY_PORT "${env_file}" 2>/dev/null || true)"
    [[ -n "${value}" ]] && OVPNWS_PROXY_PORT="${value}"
  fi
  if [[ -z "${OVPNWS_PATH_WAS_SET}" ]]; then
    value="$(openvpn_runtime_read_env_value OVPNWS_PATH "${env_file}" 2>/dev/null || true)"
    [[ -n "${value}" ]] && OVPNWS_PATH="${value}"
  fi
  if [[ -z "${OVPNWS_HANDSHAKE_TIMEOUT_WAS_SET}" ]]; then
    value="$(openvpn_runtime_read_env_value OVPNWS_HANDSHAKE_TIMEOUT "${env_file}" 2>/dev/null || true)"
    [[ -n "${value}" ]] && OVPNWS_HANDSHAKE_TIMEOUT="${value}"
  fi
  if [[ -z "${OVPN_DEFAULT_CLIENT_NAME_WAS_SET}" ]]; then
    value="$(openvpn_runtime_read_env_value OVPN_DEFAULT_CLIENT_NAME "${env_file}" 2>/dev/null || true)"
    [[ -n "${value}" ]] && OVPN_DEFAULT_CLIENT_NAME="${value}"
  fi
  if [[ -z "${OVPN_SERVER_SUBNET_WAS_SET}" ]]; then
    value="$(openvpn_runtime_read_env_value OVPN_SERVER_SUBNET "${env_file}" 2>/dev/null || true)"
    [[ -n "${value}" ]] && OVPN_SERVER_SUBNET="${value}"
  fi
  if [[ -z "${OVPN_SERVER_NETMASK_WAS_SET}" ]]; then
    value="$(openvpn_runtime_read_env_value OVPN_SERVER_NETMASK "${env_file}" 2>/dev/null || true)"
    [[ -n "${value}" ]] && OVPN_SERVER_NETMASK="${value}"
  fi
  if [[ -z "${OVPN_CCD_DIR_WAS_SET}" ]]; then
    value="$(openvpn_runtime_read_env_value OVPN_CCD_DIR "${env_file}" 2>/dev/null || true)"
    [[ -n "${value}" ]] && OVPN_CCD_DIR="${value}"
  fi
  if [[ -z "${OVPN_DOWNLOADS_DIR_WAS_SET}" ]]; then
    value="$(openvpn_runtime_read_env_value OVPN_DOWNLOADS_DIR "${env_file}" 2>/dev/null || true)"
    [[ -n "${value}" ]] && OVPN_DOWNLOADS_DIR="${value}"
  fi
  if [[ -z "${OVPN_SPEED_TUN_IFACE_WAS_SET}" ]]; then
    value="$(openvpn_runtime_read_env_value OVPN_SPEED_TUN_IFACE "${env_file}" 2>/dev/null || true)"
    [[ -n "${value}" ]] && OVPN_SPEED_TUN_IFACE="${value}"
  fi
  if [[ -z "${OVPN_SPEED_IFB_IFACE_WAS_SET}" ]]; then
    value="$(openvpn_runtime_read_env_value OVPN_SPEED_IFB_IFACE "${env_file}" 2>/dev/null || true)"
    [[ -n "${value}" ]] && OVPN_SPEED_IFB_IFACE="${value}"
  fi
  if [[ -z "${OVPN_SPEED_STATE_FILE_WAS_SET}" ]]; then
    value="$(openvpn_runtime_read_env_value OVPN_SPEED_STATE_FILE "${env_file}" 2>/dev/null || true)"
    [[ -n "${value}" ]] && OVPN_SPEED_STATE_FILE="${value}"
  fi
  if [[ -z "${OVPN_SPEED_INTERVAL_WAS_SET}" ]]; then
    value="$(openvpn_runtime_read_env_value OVPN_SPEED_INTERVAL "${env_file}" 2>/dev/null || true)"
    [[ -n "${value}" ]] && OVPN_SPEED_INTERVAL="${value}"
  fi
  if [[ -z "${OVPN_SPEED_DEFAULT_RATE_MBIT_WAS_SET}" ]]; then
    value="$(openvpn_runtime_read_env_value OVPN_SPEED_DEFAULT_RATE_MBIT "${env_file}" 2>/dev/null || true)"
    [[ -n "${value}" ]] && OVPN_SPEED_DEFAULT_RATE_MBIT="${value}"
  fi
}

openvpn_runtime_requested() {
  case "${OVPN_ENABLE_TCP:-false}:${OVPN_ENABLE_SSL:-false}:${OVPN_ENABLE_WS:-false}" in
    *true*|*TRUE*|*yes*|*YES*|*on*|*ON*|*1*)
      return 0
      ;;
  esac
  return 1
}

openvpn_ws_requested() {
  case "${OVPN_ENABLE_WS:-false}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

openvpn_tcp_or_ssl_requested() {
  case "${OVPN_ENABLE_TCP:-false}:${OVPN_ENABLE_SSL:-false}" in
    *true*|*TRUE*|*yes*|*YES*|*on*|*ON*|*1*)
      return 0
      ;;
  esac
  return 1
}

validate_openvpn_port_number() {
  local name="$1"
  local value="$2"
  [[ "${value}" =~ ^[0-9]+$ ]] || die "${name} harus angka 1..65535 (got: ${value})."
  if (( value < 1 || value > 65535 )); then
    die "${name} di luar range 1..65535 (got: ${value})."
  fi
}

normalize_ovpnws_path() {
  local path="${OVPNWS_PATH:-/}"
  path="${path%%\?*}"
  path="${path%%\#*}"
  path="/${path#/}"
  path="${path%/}"
  [[ -n "${path}" ]] || path="/"
  if [[ "${path}" == "/openvpn-ws" ]]; then
    path="/"
  fi
  printf '%s\n' "${path}"
}

openvpnws_token_valid() {
  local token="${1:-}"
  [[ "${token}" =~ ^[A-Fa-f0-9]{10}$ ]]
}

openvpn_download_token_valid() {
  local token="${1:-}"
  [[ "${token}" =~ ^[A-Fa-f0-9]{16}$ ]]
}

openvpn_download_path_from_token() {
  local token="${1:-}"
  openvpn_download_token_valid "${token}" || return 1
  printf '/ovpn/%s.zip\n' "${token,,}"
}

openvpnws_path_from_token() {
  local token="${1:-}"
  local prefix
  openvpnws_token_valid "${token}" || return 1
  prefix="$(normalize_ovpnws_path)"
  if [[ "${prefix}" == "/" ]]; then
    printf '/%s\n' "${token,,}"
  else
    printf '%s/%s\n' "${prefix}" "${token,,}"
  fi
}

openvpnws_alt_path_from_token() {
  local token="${1:-}"
  local prefix
  openvpnws_token_valid "${token}" || return 1
  prefix="$(normalize_ovpnws_path)"
  if [[ "${prefix}" == "/" ]]; then
    printf '/bebas/%s\n' "${token,,}"
  else
    printf '%s/bebas/%s\n' "${prefix}" "${token,,}"
  fi
}

openvpn_client_state_path() {
  local name="${1:-}"
  printf '%s\n' "${OVPN_CLIENTS_DIR}/${name}.json"
}

openvpn_client_state_token_get() {
  local name="${1:-}"
  local state_file
  state_file="$(openvpn_client_state_path "${name}")"
  [[ -s "${state_file}" ]] || {
    echo ""
    return 0
  }
  need_python3
  python3 - <<'PY' "${state_file}" 2>/dev/null || true
import json
import re
import sys

path = sys.argv[1]
token = ""
try:
  with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
  if isinstance(data, dict):
    token = str(data.get("ovpnws_token") or "").strip()
except Exception:
  token = ""

if re.fullmatch(r"[A-Fa-f0-9]{10}", token):
  print(token.lower())
else:
  print("")
PY
}

openvpn_client_state_download_token_get() {
  local name="${1:-}"
  local state_file
  state_file="$(openvpn_client_state_path "${name}")"
  [[ -s "${state_file}" ]] || {
    echo ""
    return 0
  }
  need_python3
  python3 - <<'PY' "${state_file}" 2>/dev/null || true
import json
import re
import sys

path = sys.argv[1]
token = ""
try:
  with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
  if isinstance(data, dict):
    token = str(data.get("download_token") or "").strip()
except Exception:
  token = ""

if re.fullmatch(r"[A-Fa-f0-9]{16}", token):
  print(token.lower())
else:
  print("")
PY
}

openvpn_client_state_ensure_token() {
  local name="${1:-}"
  local state_file="${2:-}"
  [[ -n "${name}" ]] || return 1
  [[ -n "${state_file}" ]] || state_file="$(openvpn_client_state_path "${name}")"
  install -d -m 700 "${OVPN_CLIENTS_DIR}"
  need_python3
  python3 - <<'PY' "${OVPN_CLIENTS_DIR}" "${state_file}" "${name}"
import datetime
import json
import os
import re
import secrets
import sys
import tempfile

root_dir, state_file, client_name = sys.argv[1:4]

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
      with open(entry, "r", encoding="utf-8") as f:
        loaded = json.load(f)
      if not isinstance(loaded, dict):
        continue
    except Exception:
      continue
    tok = str(loaded.get("ovpnws_token") or "").strip().lower()
    if re.fullmatch(r"[a-f0-9]{10}", tok):
      seen.add(tok)
  tok = str(current_token or "").strip().lower()
  if re.fullmatch(r"[a-f0-9]{10}", tok) and tok not in seen:
    return tok
  for _ in range(256):
    tok = secrets.token_hex(5)
    if tok not in seen:
      return tok
  raise RuntimeError("failed to allocate unique ovpnws token")

payload = {}
if os.path.isfile(state_file):
  try:
    with open(state_file, "r", encoding="utf-8") as f:
      loaded = json.load(f)
    if isinstance(loaded, dict):
      payload = loaded
  except Exception:
    payload = {}

token = pick_unique_token(root_dir, state_file, payload.get("ovpnws_token"))
download_seen = set()
current_real = os.path.realpath(state_file)
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
    with open(entry, "r", encoding="utf-8") as f:
      loaded = json.load(f)
    if not isinstance(loaded, dict):
      continue
  except Exception:
    continue
  tok = str(loaded.get("download_token") or "").strip().lower()
  if re.fullmatch(r"[a-f0-9]{16}", tok):
    download_seen.add(tok)
download_token = str(payload.get("download_token") or "").strip().lower()
if not re.fullmatch(r"[a-f0-9]{16}", download_token) or download_token in download_seen:
  for _ in range(256):
    download_token = secrets.token_hex(8)
    if download_token not in download_seen:
      break
  else:
    raise RuntimeError("failed to allocate unique openvpn download token")
payload["managed_by"] = "autoscript-setup"
payload["client_name"] = client_name
payload["protocol"] = "openvpn"
payload["created_at"] = str(payload.get("created_at") or "").strip() or datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%d")
payload["ovpnws_token"] = token
payload["download_token"] = download_token

dirn = os.path.dirname(state_file) or "."
fd, tmp = tempfile.mkstemp(prefix=".tmp.", suffix=".json", dir=dirn)
try:
  with os.fdopen(fd, "w", encoding="utf-8") as f:
    json.dump(payload, f, ensure_ascii=False, indent=2)
    f.write("\n")
    f.flush()
    os.fsync(f.fileno())
  os.replace(tmp, state_file)
  try:
    os.chmod(state_file, 0o600)
  except Exception:
    pass
finally:
  try:
    if os.path.exists(tmp):
      os.remove(tmp)
  except Exception:
    pass

print(token)
PY
}

validate_openvpn_ports_config() {
  validate_openvpn_port_number "OVPN_TCP_PORT" "${OVPN_TCP_PORT}"
  validate_openvpn_port_number "OVPNWS_PROXY_PORT" "${OVPNWS_PROXY_PORT}"

  if [[ "${OVPN_TCP_PORT}" == "${OVPNWS_PROXY_PORT}" ]]; then
    die "Port OpenVPN tidak boleh duplikat (ovpn-tcp=${OVPN_TCP_PORT}, ovpnws-proxy=${OVPNWS_PROXY_PORT})."
  fi

  local p
  for p in "${OVPN_TCP_PORT}" "${OVPNWS_PROXY_PORT}"; do
    case "${p}" in
      80|443)
        die "Port OpenVPN ${p} bentrok dengan port publik edge (80/443)."
        ;;
      10085)
        die "Port OpenVPN ${p} bentrok dengan Xray API port (10085)."
        ;;
      "${SSHWS_DROPBEAR_PORT}"|"${SSHWS_STUNNEL_PORT}"|"${SSHWS_PROXY_PORT}")
        die "Port OpenVPN ${p} bentrok dengan runtime SSH WS."
        ;;
    esac
  done

  local normalized_path
  normalized_path="$(normalize_ovpnws_path)"
  if [[ "${normalized_path}" != "/" ]]; then
    die "OVPNWS_PATH saat ini harus '/' agar path OpenVPN WS mengikuti pola /<token> dan /<bebas>/<token>."
  fi
}

openvpn_server_domain_value() {
  if [[ -n "${DOMAIN:-}" ]]; then
    printf '%s\n' "${DOMAIN}"
    return 0
  fi
  detect_domain 2>/dev/null || true
}

openvpn_server_ip_value() {
  if [[ -n "${VPS_IPV4:-}" ]]; then
    printf '%s\n' "${VPS_IPV4}"
    return 0
  fi
  detect_public_ipv4 2>/dev/null || true
}

write_openvpn_runtime_env() {
  render_setup_template_or_die \
    "config/openvpn-runtime.env" \
    "${OPENVPN_RUNTIME_ENV_FILE}" \
    0644 \
    "OVPN_ENABLE_TCP=${OVPN_ENABLE_TCP}" \
    "OVPN_ENABLE_SSL=${OVPN_ENABLE_SSL}" \
    "OVPN_ENABLE_WS=${OVPN_ENABLE_WS}" \
    "OVPN_TCP_BIND=${OVPN_TCP_BIND}" \
    "OVPN_TCP_PORT=${OVPN_TCP_PORT}" \
    "OVPNWS_PROXY_BIND=${OVPNWS_PROXY_BIND}" \
    "OVPNWS_PROXY_PORT=${OVPNWS_PROXY_PORT}" \
    "OVPNWS_PATH=$(normalize_ovpnws_path)" \
    "OVPNWS_HANDSHAKE_TIMEOUT=${OVPNWS_HANDSHAKE_TIMEOUT}" \
    "OVPN_SERVER_CONF=${OVPN_SERVER_CONF}" \
    "OVPN_PKI_DIR=${OVPN_PKI_DIR}" \
    "OVPN_CA_FILE=${OVPN_CA_FILE}" \
    "OVPN_CERT_FILE=${OVPN_CERT_FILE}" \
    "OVPN_KEY_FILE=${OVPN_KEY_FILE}" \
    "OVPN_DH_FILE=${OVPN_DH_FILE}" \
    "OVPN_TLS_CRYPT_FILE=${OVPN_TLS_CRYPT_FILE}" \
    "OVPN_CLIENTS_DIR=${OVPN_CLIENTS_DIR}" \
    "OVPN_CCD_DIR=${OVPN_CCD_DIR}" \
    "OVPN_DOWNLOADS_DIR=${OVPN_DOWNLOADS_DIR}" \
    "OVPN_DEFAULT_CLIENT_NAME=${OVPN_DEFAULT_CLIENT_NAME}" \
    "OVPN_SERVER_SUBNET=${OVPN_SERVER_SUBNET}" \
    "OVPN_SERVER_NETMASK=${OVPN_SERVER_NETMASK}" \
    "OVPN_SPEED_TUN_IFACE=${OVPN_SPEED_TUN_IFACE}" \
    "OVPN_SPEED_IFB_IFACE=${OVPN_SPEED_IFB_IFACE}" \
    "OVPN_SPEED_STATE_FILE=${OVPN_SPEED_STATE_FILE}" \
    "OVPN_SPEED_INTERVAL=${OVPN_SPEED_INTERVAL}" \
    "OVPN_SPEED_DEFAULT_RATE_MBIT=${OVPN_SPEED_DEFAULT_RATE_MBIT}"
}

render_openvpn_server_config() {
  render_setup_template_or_die \
    "config/openvpn/server-tcp.conf" \
    "${OVPN_SERVER_CONF}" \
    0600 \
    "OVPN_TCP_BIND=${OVPN_TCP_BIND}" \
    "OVPN_TCP_PORT=${OVPN_TCP_PORT}" \
    "OVPN_SERVER_SUBNET=${OVPN_SERVER_SUBNET}" \
    "OVPN_SERVER_NETMASK=${OVPN_SERVER_NETMASK}" \
    "OVPN_CA_FILE=${OVPN_CA_FILE}" \
    "OVPN_CERT_FILE=${OVPN_CERT_FILE}" \
    "OVPN_KEY_FILE=${OVPN_KEY_FILE}" \
    "OVPN_DH_FILE=${OVPN_DH_FILE}" \
    "OVPN_TLS_CRYPT_FILE=${OVPN_TLS_CRYPT_FILE}" \
    "OVPN_CCD_DIR=${OVPN_CCD_DIR}"
}

openvpn_prepare_dirs() {
  install -d -m 755 /etc/openvpn
  install -d -m 755 /etc/openvpn/server
  install -d -m 700 "${OVPN_PKI_DIR}"
  install -d -m 700 "${OVPN_CLIENTS_DIR}"
  install -d -m 755 "${OVPN_CCD_DIR}"
  install -d -m 755 "${OVPN_DOWNLOADS_DIR}"
  install -d -m 755 /var/log/openvpn
  install -d -m 755 /var/lib/openvpn
}

openvpn_client_bundle_path() {
  local name="${1:-}"
  [[ "${name}" =~ ^[a-z0-9][a-z0-9._-]{0,31}$ ]] || return 1
  printf '%s/%s.zip\n' "${OVPN_DOWNLOADS_DIR}" "${name}"
}

render_openvpn_client_bundle() {
  local name="${1:-}"
  local out tcp_profile ssl_profile ws_profile legacy_token legacy_path
  out="$(openvpn_client_bundle_path "${name}")" || die "Nama client OpenVPN tidak valid untuk bundle ZIP (${name})."
  legacy_token="$(openvpn_client_state_download_token_get "${name}")"
  if openvpn_download_token_valid "${legacy_token}"; then
    legacy_path="${OVPN_DOWNLOADS_DIR}/${legacy_token}.zip"
    [[ "${legacy_path}" == "${out}" ]] || rm -f "${legacy_path}" >/dev/null 2>&1 || true
  fi
  tcp_profile="$(openvpn_client_config_path "${name}")"
  ssl_profile="$(openvpn_client_ssl_profile_path "${name}")"
  ws_profile="$(openvpn_client_ws_profile_path "${name}")"
  install -d -m 755 "${OVPN_DOWNLOADS_DIR}"
  python3 - <<'PY' "${out}" "${tcp_profile}" "${ssl_profile}" "${ws_profile}"
import os
import sys
import tempfile
import zipfile

out, tcp_profile, ssl_profile, ws_profile = sys.argv[1:5]
files = [p for p in (tcp_profile, ssl_profile, ws_profile) if os.path.isfile(p)]
if not files:
  raise SystemExit("no ovpn profiles to bundle")
dirn = os.path.dirname(out) or "."
fd, tmp = tempfile.mkstemp(prefix=".tmp.", suffix=".zip", dir=dirn)
os.close(fd)
try:
  with zipfile.ZipFile(tmp, "w", compression=zipfile.ZIP_DEFLATED) as zf:
    for path in files:
      zf.write(path, arcname=os.path.basename(path))
  os.replace(tmp, out)
  os.chmod(out, 0o644)
finally:
  try:
    if os.path.exists(tmp):
      os.remove(tmp)
  except Exception:
    pass
PY
}

openvpn_client_ccd_path_by_cn() {
  local client_cn="${1:-}"
  printf '%s/%s\n' "${OVPN_CCD_DIR}" "${client_cn}"
}

openvpn_client_allow_cn() {
  local client_cn="${1:-}"
  local file
  file="$(openvpn_client_ccd_path_by_cn "${client_cn}")"
  install -d -m 755 "${OVPN_CCD_DIR}"
  {
    printf '%s\n' "# autoscript openvpn client"
    printf '%s\n' "push-reset"
  } > "${file}"
  chmod 644 "${file}" >/dev/null 2>&1 || true
}

openvpn_install_package() {
  local missing=()
  if ! command -v openvpn >/dev/null 2>&1; then
    missing+=("openvpn")
  fi
  if ! command -v openssl >/dev/null 2>&1; then
    missing+=("openssl")
  fi
  if (( ${#missing[@]} == 0 )); then
    ok "OpenVPN runtime prerequisites sudah tersedia."
    return 0
  fi
  export DEBIAN_FRONTEND=noninteractive
  ensure_dpkg_consistent
  apt_get_with_lock_retry install -y "${missing[@]}" || die "Gagal memasang runtime OpenVPN (${missing[*]})."
  command -v openvpn >/dev/null 2>&1 || die "Binary openvpn tidak ditemukan setelah install."
  command -v openssl >/dev/null 2>&1 || die "Binary openssl tidak ditemukan setelah install."
  ok "OpenVPN terpasang."
}

openvpn_require_tun_or_die() {
  [[ -c /dev/net/tun ]] || die "/dev/net/tun tidak tersedia untuk OpenVPN."
}

openvpn_service_enable_start_checked() {
  local svc="$1"
  systemctl enable "${svc}" >/dev/null 2>&1 || return 1
  systemctl start "${svc}" >/dev/null 2>&1 || return 1
  systemctl is-active --quiet "${svc}" || return 1
  return 0
}

openvpn_pki_subject_file() {
  printf '%s\n' "${OVPN_PKI_DIR}/subject-ext.cnf"
}

openvpn_generate_server_pki_if_missing() {
  openvpn_prepare_dirs
  local ca_key="${OVPN_PKI_DIR}/ca.key"
  local ca_srl="${OVPN_PKI_DIR}/ca.srl"
  local server_csr="${OVPN_PKI_DIR}/server.csr"
  local ext_file server_domain server_ip

  if [[ ! -f "${ca_key}" || ! -f "${OVPN_CA_FILE}" ]]; then
    openssl genrsa -out "${ca_key}" 4096 >/dev/null 2>&1 || die "Gagal membuat CA key OpenVPN."
    openssl req -x509 -new -nodes -key "${ca_key}" -sha256 -days 3650 \
      -subj "/CN=autoscript-openvpn-ca" \
      -out "${OVPN_CA_FILE}" >/dev/null 2>&1 || die "Gagal membuat CA cert OpenVPN."
  fi

  if [[ ! -f "${OVPN_KEY_FILE}" || ! -f "${OVPN_CERT_FILE}" ]]; then
    server_domain="$(openvpn_server_domain_value)"
    server_ip="$(openvpn_server_ip_value)"
    ext_file="$(openvpn_pki_subject_file)"
    {
      printf '%s\n' "basicConstraints=CA:FALSE"
      printf '%s\n' "keyUsage = digitalSignature,keyEncipherment"
      printf '%s\n' "extendedKeyUsage = serverAuth"
      if [[ -n "${server_domain}" || -n "${server_ip}" ]]; then
        printf '%s' "subjectAltName="
        if [[ -n "${server_domain}" ]]; then
          printf 'DNS:%s' "${server_domain}"
          if [[ -n "${server_ip}" ]]; then
            printf ','
          fi
        fi
        if [[ -n "${server_ip}" ]]; then
          printf 'IP:%s' "${server_ip}"
        fi
        printf '\n'
      fi
    } > "${ext_file}"
    chmod 600 "${ext_file}" >/dev/null 2>&1 || true

    openssl genrsa -out "${OVPN_KEY_FILE}" 4096 >/dev/null 2>&1 || die "Gagal membuat server key OpenVPN."
    openssl req -new -key "${OVPN_KEY_FILE}" -subj "/CN=${server_domain:-autoscript-openvpn-server}" \
      -out "${server_csr}" >/dev/null 2>&1 || die "Gagal membuat server CSR OpenVPN."
    openssl x509 -req -in "${server_csr}" -CA "${OVPN_CA_FILE}" -CAkey "${ca_key}" \
      -CAcreateserial -CAserial "${ca_srl}" -out "${OVPN_CERT_FILE}" -days 3650 -sha256 \
      -extfile "${ext_file}" >/dev/null 2>&1 || die "Gagal menandatangani server cert OpenVPN."
    rm -f "${server_csr}" "${ext_file}" >/dev/null 2>&1 || true
  fi

  if [[ ! -f "${OVPN_TLS_CRYPT_FILE}" ]]; then
    openvpn --genkey secret "${OVPN_TLS_CRYPT_FILE}" >/dev/null 2>&1 || die "Gagal membuat tls-crypt key OpenVPN."
  fi

  chmod 600 "${OVPN_CA_FILE}" "${OVPN_CERT_FILE}" "${OVPN_KEY_FILE}" "${OVPN_TLS_CRYPT_FILE}" >/dev/null 2>&1 || true
}

openvpn_client_paths() {
  local name="$1"
  printf '%s\n' "${OVPN_CLIENTS_DIR}/${name}.key" "${OVPN_CLIENTS_DIR}/${name}.csr" "${OVPN_CLIENTS_DIR}/${name}.crt"
}

openvpn_issue_client_certificate() {
  local name="$1"
  local ca_key="${OVPN_PKI_DIR}/ca.key"
  local ca_srl="${OVPN_PKI_DIR}/ca.srl"
  local key csr crt ext
  readarray -t _paths < <(openvpn_client_paths "${name}")
  key="${_paths[0]}"
  csr="${_paths[1]}"
  crt="${_paths[2]}"
  ext="${OVPN_CLIENTS_DIR}/${name}.ext"

  [[ -f "${key}" && -f "${crt}" ]] && return 0
  [[ -f "${OVPN_CA_FILE}" && -f "${ca_key}" ]] || die "PKI OpenVPN belum siap untuk client certificate."

  printf '%s\n' "basicConstraints=CA:FALSE" > "${ext}"
  printf '%s\n' "keyUsage = digitalSignature" >> "${ext}"
  printf '%s\n' "extendedKeyUsage = clientAuth" >> "${ext}"

  openssl genrsa -out "${key}" 4096 >/dev/null 2>&1 || die "Gagal membuat client key OpenVPN (${name})."
  openssl req -new -key "${key}" -subj "/CN=${name}" -out "${csr}" >/dev/null 2>&1 || die "Gagal membuat client CSR OpenVPN (${name})."
  openssl x509 -req -in "${csr}" -CA "${OVPN_CA_FILE}" -CAkey "${ca_key}" \
    -CAserial "${ca_srl}" -out "${crt}" -days 3650 -sha256 -extfile "${ext}" >/dev/null 2>&1 \
    || die "Gagal menandatangani client cert OpenVPN (${name})."
  rm -f "${csr}" "${ext}" >/dev/null 2>&1 || true
  chmod 600 "${key}" "${crt}" >/dev/null 2>&1 || true
}

openvpn_client_config_path() {
  local name="$1"
  printf '%s\n' "${OVPN_CLIENTS_DIR}/${name}-tcp.ovpn"
}

openvpn_client_ssl_profile_path() {
  local name="$1"
  printf '%s\n' "${OVPN_CLIENTS_DIR}/${name}-ssl.ovpn"
}

openvpn_client_ws_profile_path() {
  local name="$1"
  printf '%s\n' "${OVPN_CLIENTS_DIR}/${name}-ws.ovpn"
}

openvpn_client_ssl_helper_path() {
  local name="$1"
  printf '%s\n' "${OVPN_CLIENTS_DIR}/${name}-ssl-helper.py"
}

openvpn_client_ws_helper_path() {
  local name="$1"
  printf '%s\n' "${OVPN_CLIENTS_DIR}/${name}-ws-helper.py"
}

openvpn_client_ssl_run_path() {
  local name="$1"
  printf '%s\n' "${OVPN_CLIENTS_DIR}/${name}-ssl-run.sh"
}

openvpn_client_tcp_run_path() {
  local name="$1"
  printf '%s\n' "${OVPN_CLIENTS_DIR}/${name}-tcp-run.sh"
}

openvpn_client_ws_run_path() {
  local name="$1"
  printf '%s\n' "${OVPN_CLIENTS_DIR}/${name}-ws-run.sh"
}

openvpn_client_tcp_tun_device() {
  local name="${1:-client}"
  name="${name,,}"
  name="${name//[^a-z0-9]/}"
  [[ -n "${name}" ]] || name="client"
  printf 'ovpntcp%s\n' "${name:0:8}"
}

openvpn_client_ssl_local_port() {
  printf '%s\n' "21197"
}

openvpn_client_ws_local_port() {
  printf '%s\n' "21196"
}

openvpn_client_public_port() {
  case "${EDGE_ACTIVATE_RUNTIME:-true}" in
    0|false|FALSE|no|NO|off|OFF)
      printf '%s\n' "${OVPN_TCP_PORT}"
      return 0
      ;;
  esac
  case "${EDGE_PROVIDER:-go}" in
    none|NONE)
      printf '%s\n' "${OVPN_TCP_PORT}"
      return 0
      ;;
  esac
  printf '%s\n' "443"
}

render_openvpn_embedded_profile() {
  local profile="$1"
  local remote_host="$2"
  local remote_port="$3"
  local mode_label="$4"
  local note_block="${5:-}"
  local key="$6"
  local crt="$7"
  [[ -f "${OVPN_CA_FILE}" && -f "${key}" && -f "${crt}" && -f "${OVPN_TLS_CRYPT_FILE}" ]] || die "Asset client OpenVPN belum lengkap untuk render ${profile}."
  python3 - "${profile}" "${remote_host}" "${remote_port}" "${OVPN_CA_FILE}" "${crt}" "${key}" "${OVPN_TLS_CRYPT_FILE}" "${mode_label}" "${note_block}" <<'PY'
import sys
from pathlib import Path

out, remote_host, remote_port, ca_path, crt_path, key_path, tls_crypt_path, mode_label, note_block = sys.argv[1:]

def slurp(path):
  return Path(path).read_text(encoding="utf-8").strip() + "\n"

notes = []
for line in str(note_block or "").splitlines():
  text = line.strip()
  if text:
    notes.append(f"# {text}")
notes_text = ""
if notes:
  notes_text = "\n" + "\n".join(notes) + "\n"

payload = f"""client
dev tun
proto tcp-client
remote {remote_host} {remote_port}
nobind
persist-key
persist-tun
remote-cert-tls server
auth SHA256
cipher AES-256-GCM
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
verb 3
# Profile mode : {mode_label}{notes_text}

<ca>
{slurp(ca_path)}</ca>
<cert>
{slurp(crt_path)}</cert>
<key>
{slurp(key_path)}</key>
<tls-crypt>
{slurp(tls_crypt_path)}</tls-crypt>
"""
Path(out).write_text(payload, encoding="utf-8")
PY
  chmod 600 "${profile}" >/dev/null 2>&1 || true
}

render_openvpn_client_helpers() {
  local name="$1"
  local connect_host="$2"
  local server_name="$3"
  local remote_port="$4"
  local ws_path="$5"
  local tcp_run ssl_helper ssl_run ws_helper ws_run
  tcp_run="$(openvpn_client_tcp_run_path "${name}")"
  ssl_helper="$(openvpn_client_ssl_helper_path "${name}")"
  ssl_run="$(openvpn_client_ssl_run_path "${name}")"
  ws_helper="$(openvpn_client_ws_helper_path "${name}")"
  ws_run="$(openvpn_client_ws_run_path "${name}")"

  render_setup_template_or_die \
    "config/openvpn/client-run-wrapper-tcp.sh" \
    "${tcp_run}" \
    0700 \
    "PROFILE_FILE=$(basename "$(openvpn_client_config_path "${name}")")" \
    "RUNTIME_PROFILE_FILE=.${name}-tcp-runtime.ovpn" \
    "TUN_DEVICE=$(openvpn_client_tcp_tun_device "${name}")"

  render_setup_template_or_die \
    "config/openvpn/client-tunnel-helper-tls.py" \
    "${ssl_helper}" \
    0700 \
    "LISTEN_HOST=127.0.0.1" \
    "LISTEN_PORT=$(openvpn_client_ssl_local_port)" \
    "REMOTE_HOST=${connect_host}" \
    "REMOTE_PORT=${remote_port}" \
    "SERVER_NAME=${server_name}"

  render_setup_template_or_die \
    "config/openvpn/client-tunnel-helper-ws.py" \
    "${ws_helper}" \
    0700 \
    "LISTEN_HOST=127.0.0.1" \
    "LISTEN_PORT=$(openvpn_client_ws_local_port)" \
    "REMOTE_HOST=${connect_host}" \
    "REMOTE_PORT=${remote_port}" \
    "SERVER_NAME=${server_name}" \
    "WS_PATH=${ws_path}"

  render_setup_template_or_die \
    "config/openvpn/client-run-wrapper.sh" \
    "${ssl_run}" \
    0700 \
    "HELPER_FILE=$(basename "${ssl_helper}")" \
    "PROFILE_FILE=$(basename "$(openvpn_client_ssl_profile_path "${name}")")" \
    "HELPER_LOG=${name}-ssl-helper.log" \
    "HELPER_PID=${name}-ssl-helper.pid"

  render_setup_template_or_die \
    "config/openvpn/client-run-wrapper.sh" \
    "${ws_run}" \
    0700 \
    "HELPER_FILE=$(basename "${ws_helper}")" \
    "PROFILE_FILE=$(basename "$(openvpn_client_ws_profile_path "${name}")")" \
    "HELPER_LOG=${name}-ws-helper.log" \
    "HELPER_PID=${name}-ws-helper.pid"
}

render_openvpn_client_artifacts() {
  local name="$1"
  local remote_host="${2:-}"
  local remote_port="${3:-$(openvpn_client_public_port)}"
  local connect_host remote_ip server_name
  local key crt ws_token ws_path ws_alt_path
  local tcp_profile ssl_profile ws_profile
  readarray -t _paths < <(openvpn_client_paths "${name}")
  key="${_paths[0]}"
  crt="${_paths[2]}"
  tcp_profile="$(openvpn_client_config_path "${name}")"
  ssl_profile="$(openvpn_client_ssl_profile_path "${name}")"
  ws_profile="$(openvpn_client_ws_profile_path "${name}")"

  [[ -n "${remote_host}" ]] || remote_host="$(openvpn_server_domain_value)"
  [[ -n "${remote_host}" ]] || remote_host="$(openvpn_server_ip_value)"
  [[ -n "${remote_host}" ]] || remote_host="127.0.0.1"
  remote_ip="$(openvpn_server_ip_value)"
  connect_host="${remote_ip:-${remote_host}}"
  server_name="${remote_host}"
  ws_token="$(openvpn_client_state_ensure_token "${name}")"
  ws_path="$(openvpnws_path_from_token "${ws_token}" 2>/dev/null || true)"
  ws_alt_path="$(openvpnws_alt_path_from_token "${ws_token}" 2>/dev/null || true)"

  render_openvpn_embedded_profile \
    "${tcp_profile}" \
    "${remote_host}" \
    "${remote_port}" \
    "TCP" \
    $'Gunakan profile ini langsung untuk mode OpenVPN TCP.\nLauncher cepat: '"$(basename "$(openvpn_client_tcp_run_path "${name}")")"$'\nCatatan      : launcher TCP membersihkan state tun lokal saat rerun cepat di host Linux.' \
    "${key}" \
    "${crt}"

  render_openvpn_embedded_profile \
    "${ssl_profile}" \
    "127.0.0.1" \
    "$(openvpn_client_ssl_local_port)" \
    "SSL/TLS" \
    $'Jalankan helper TLS lokal sebelum memakai profile ini.\nLauncher cepat: '"$(basename "$(openvpn_client_ssl_run_path "${name}")")" \
    "${key}" \
    "${crt}"

  render_openvpn_embedded_profile \
    "${ws_profile}" \
    "127.0.0.1" \
    "$(openvpn_client_ws_local_port)" \
    "WS" \
    $'Token        : '"${ws_token}"$'\nWS Path      : '"${ws_path}"$'\nWS Path Alt  : '"${ws_alt_path}"$'\nHeader       : X-OVPN-WS: 1\nLauncher cepat: '"$(basename "$(openvpn_client_ws_run_path "${name}")")" \
    "${key}" \
    "${crt}"

  render_openvpn_client_helpers "${name}" "${connect_host}" "${server_name}" "${remote_port}" "${ws_path}"
  render_openvpn_client_bundle "${name}"
}

stage_openvpn_scaffold_assets() {
  validate_openvpn_ports_config
  command -v python3 >/dev/null 2>&1 || die "python3 tidak ditemukan untuk ovpnws-proxy."
  install_setup_bin_or_die "ssh-ovpn-qac-runtime.py" "/usr/local/bin/ssh-ovpn-qac-runtime" 0755
  install_setup_bin_or_die "ovpnws-proxy.py" "/usr/local/bin/ovpnws-proxy" 0755
  install_setup_bin_or_die "openvpn-expired" "/usr/local/bin/openvpn-expired" 0755
  install_setup_bin_or_die "openvpn-speed.py" "/usr/local/bin/openvpn-speed" 0755
  write_openvpn_runtime_env
  render_openvpn_server_config

  render_setup_template_or_die \
    "systemd/ovpn-tcp.service" \
    "/etc/systemd/system/${OVPN_TCP_SERVICE_NAME}" \
    0644 \
    "OPENVPN_RUNTIME_ENV_FILE=${OPENVPN_RUNTIME_ENV_FILE}" \
    "OVPN_SERVER_CONF=${OVPN_SERVER_CONF}"

  render_setup_template_or_die \
    "systemd/ovpnws-proxy.service" \
    "/etc/systemd/system/${OVPNWS_PROXY_SERVICE_NAME}" \
    0644 \
    "OPENVPN_RUNTIME_ENV_FILE=${OPENVPN_RUNTIME_ENV_FILE}" \
    "OVPNWS_PROXY_BIND=${OVPNWS_PROXY_BIND}" \
    "OVPNWS_PROXY_PORT=${OVPNWS_PROXY_PORT}" \
    "OVPN_CLIENTS_DIR=${OVPN_CLIENTS_DIR}" \
    "OVPN_TCP_PORT=${OVPN_TCP_PORT}" \
    "OVPNWS_PATH=$(normalize_ovpnws_path)" \
    "OVPNWS_HANDSHAKE_TIMEOUT=${OVPNWS_HANDSHAKE_TIMEOUT}" \
    "OVPN_TCP_SERVICE_NAME=${OVPN_TCP_SERVICE_NAME}"

  render_setup_template_or_die \
    "systemd/openvpn-expired.service" \
    "/etc/systemd/system/${OPENVPN_EXPIRED_SERVICE_NAME}" \
    0644 \
    "OPENVPN_RUNTIME_ENV_FILE=${OPENVPN_RUNTIME_ENV_FILE}" \
    "OVPN_TCP_SERVICE_NAME=${OVPN_TCP_SERVICE_NAME}"

  render_setup_template_or_die \
    "systemd/openvpn-expired.timer" \
    "/etc/systemd/system/${OPENVPN_EXPIRED_TIMER_NAME}" \
    0644 \
    "OPENVPN_EXPIRED_SERVICE_NAME=${OPENVPN_EXPIRED_SERVICE_NAME}"

  render_setup_template_or_die \
    "systemd/openvpn-speed.service" \
    "/etc/systemd/system/${OPENVPN_SPEED_SERVICE_NAME}" \
    0644 \
    "OPENVPN_RUNTIME_ENV_FILE=${OPENVPN_RUNTIME_ENV_FILE}" \
    "OVPN_TCP_SERVICE_NAME=${OVPN_TCP_SERVICE_NAME}" \
    "OVPN_SPEED_INTERVAL=${OVPN_SPEED_INTERVAL}"

  systemctl daemon-reload >/dev/null 2>&1 || true
  ok "OpenVPN scaffold siap:"
  ok "  - env    : ${OPENVPN_RUNTIME_ENV_FILE}"
  ok "  - config : ${OVPN_SERVER_CONF}"
  ok "  - unit   : ${OVPN_TCP_SERVICE_NAME}, ${OVPNWS_PROXY_SERVICE_NAME}, ${OPENVPN_EXPIRED_SERVICE_NAME}, ${OPENVPN_EXPIRED_TIMER_NAME}, ${OPENVPN_SPEED_SERVICE_NAME}"
  ok "  - binary : /usr/local/bin/ovpnws-proxy, /usr/local/bin/openvpn-expired, /usr/local/bin/openvpn-speed, /usr/local/bin/ssh-ovpn-qac-runtime"
}

install_openvpn_stack() {
  openvpn_runtime_load_persisted_env

  if ! openvpn_runtime_requested; then
    return 0
  fi

  validate_openvpn_ports_config
  openvpn_require_tun_or_die
  openvpn_install_package
  stage_openvpn_scaffold_assets
  openvpn_generate_server_pki_if_missing
  openvpn_issue_client_certificate "${OVPN_DEFAULT_CLIENT_NAME}"
  openvpn_client_allow_cn "${OVPN_DEFAULT_CLIENT_NAME}"
  render_openvpn_client_artifacts "${OVPN_DEFAULT_CLIENT_NAME}" "$(openvpn_server_domain_value || true)" "$(openvpn_client_public_port)"

  if openvpn_tcp_or_ssl_requested; then
    openvpn_service_enable_start_checked "${OVPN_TCP_SERVICE_NAME}" || die "Gagal mengaktifkan ${OVPN_TCP_SERVICE_NAME}"
  else
    systemctl disable --now "${OVPN_TCP_SERVICE_NAME}" >/dev/null 2>&1 || true
  fi

  if openvpn_ws_requested; then
    openvpn_service_enable_start_checked "${OVPNWS_PROXY_SERVICE_NAME}" || die "Gagal mengaktifkan ${OVPNWS_PROXY_SERVICE_NAME}"
  else
    systemctl disable --now "${OVPNWS_PROXY_SERVICE_NAME}" >/dev/null 2>&1 || true
  fi

  if systemctl enable --now "${OPENVPN_EXPIRED_TIMER_NAME}" >/dev/null 2>&1; then
    systemctl start "${OPENVPN_EXPIRED_SERVICE_NAME}" >/dev/null 2>&1 || true
  else
    warn "Gagal mengaktifkan ${OPENVPN_EXPIRED_TIMER_NAME}. Sinkronisasi expiry OpenVPN mungkin tidak otomatis."
  fi

  if ! systemctl enable --now "${OPENVPN_SPEED_SERVICE_NAME}" >/dev/null 2>&1; then
    warn "Gagal mengaktifkan ${OPENVPN_SPEED_SERVICE_NAME}. Speed limit OpenVPN mungkin tidak otomatis."
    systemctl disable --now "${OPENVPN_SPEED_SERVICE_NAME}" >/dev/null 2>&1 || true
  fi

  ok "OpenVPN stack aktif."
  ok "  - core backend : ${OVPN_TCP_BIND}:${OVPN_TCP_PORT}"
  ok "  - ws proxy     : ${OVPNWS_PROXY_BIND}:${OVPNWS_PROXY_PORT}"
  ok "  - speed tun    : ${OVPN_SPEED_TUN_IFACE} (ifb ${OVPN_SPEED_IFB_IFACE})"
  ok "  - client demo  : $(openvpn_client_config_path "${OVPN_DEFAULT_CLIENT_NAME}")"
  ok "  - client ssl   : $(openvpn_client_ssl_profile_path "${OVPN_DEFAULT_CLIENT_NAME}")"
  ok "  - client ws    : $(openvpn_client_ws_profile_path "${OVPN_DEFAULT_CLIENT_NAME}")"
  local demo_bundle
  demo_bundle="$(openvpn_client_bundle_path "${OVPN_DEFAULT_CLIENT_NAME}" 2>/dev/null || true)"
  if [[ -n "${demo_bundle}" ]]; then
    ok "  - client zip   : ${demo_bundle}"
    ok "  - zip url path : /ovpn/${OVPN_DEFAULT_CLIENT_NAME}.zip"
  fi
  local demo_token demo_path demo_alt_path
  demo_token="$(openvpn_client_state_token_get "${OVPN_DEFAULT_CLIENT_NAME}")"
  if openvpnws_token_valid "${demo_token}"; then
    demo_path="$(openvpnws_path_from_token "${demo_token}" 2>/dev/null || true)"
    demo_alt_path="$(openvpnws_alt_path_from_token "${demo_token}" 2>/dev/null || true)"
    ok "  - ovpn ws path : ${demo_path}"
    ok "  - ovpn ws alt  : ${demo_alt_path}"
  fi
}
