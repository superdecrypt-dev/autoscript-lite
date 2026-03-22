#!/usr/bin/env bash
set -u
set -o pipefail

CONFIG_ENV="/etc/autoscript/openvpn/config.env"
SERVER_CONF=""
SERVICE="openvpn-server@autoscript-tcp"
SINCE="7 days ago"

findings=()
notes=()

usage() {
  cat <<'EOF'
Usage: openvpn-audit.sh [options]

Read-only audit helper for OpenVPN runtime.

Options:
  --config-env PATH   Path to autoscript OpenVPN env file.
  --server-conf PATH  Path to OpenVPN server config.
  --service NAME      systemd unit name to inspect.
  --since VALUE       journalctl/log lookback window. Default: 7 days ago
  -h, --help          Show this help.

Examples:
  sudo ./autoscript/tools/openvpn-audit.sh
  sudo ./autoscript/tools/openvpn-audit.sh --server-conf /etc/openvpn/server/server.conf
EOF
}

add_finding() {
  findings+=("$1|$2")
}

add_note() {
  notes+=("$1")
}

print_section() {
  printf '\n== %s ==\n' "$1"
}

trim() {
  local value="${1:-}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

read_env_value() {
  local key="$1"
  local path="$2"
  [[ -f "$path" ]] || return 1
  awk -F= -v wanted="$key" '
    $0 ~ /^[[:space:]]*#/ { next }
    index($0, "=") == 0 { next }
    {
      key = $1
      sub(/^[[:space:]]+/, "", key)
      sub(/[[:space:]]+$/, "", key)
      if (key != wanted) {
        next
      }
      value = substr($0, index($0, "=") + 1)
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      print value
      exit
    }
  ' "$path"
}

read_conf_value() {
  local key="$1"
  local path="$2"
  [[ -f "$path" ]] || return 1
  awk -v wanted="$key" '
    /^[[:space:]]*#/ { next }
    NF == 0 { next }
    {
      if ($1 != wanted) {
        next
      }
      out = $0
      sub(/^[^[:space:]]+[[:space:]]+/, "", out)
      sub(/[[:space:]]+;.*$/, "", out)
      print out
      exit
    }
  ' "$path"
}

has_conf_directive() {
  local key="$1"
  local path="$2"
  [[ -f "$path" ]] || return 1
  awk -v wanted="$key" '
    /^[[:space:]]*#/ { next }
    NF == 0 { next }
    $1 == wanted { found = 1; exit }
    END { exit(found ? 0 : 1) }
  ' "$path"
}

first_existing() {
  local path=""
  for path in "$@"; do
    [[ -n "$path" && -f "$path" ]] && printf '%s\n' "$path" && return 0
  done
  return 1
}

perm_octal() {
  local path="$1"
  stat -c '%a' "$path" 2>/dev/null || true
}

cert_not_after() {
  local path="$1"
  openssl x509 -in "$path" -noout -enddate 2>/dev/null | sed 's/^notAfter=//'
}

days_until_date() {
  local raw="$1"
  local target_epoch=""
  local now_epoch=""
  target_epoch="$(date -d "$raw" +%s 2>/dev/null || true)"
  now_epoch="$(date +%s)"
  [[ -n "$target_epoch" ]] || return 1
  printf '%s\n' "$(( (target_epoch - now_epoch) / 86400 ))"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config-env)
      CONFIG_ENV="$2"
      shift 2
      ;;
    --server-conf)
      SERVER_CONF="$2"
      shift 2
      ;;
    --service)
      SERVICE="$2"
      shift 2
      ;;
    --since)
      SINCE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n' "$1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

OPENVPN_ROOT="$(read_env_value OPENVPN_ROOT "$CONFIG_ENV" 2>/dev/null || true)"
OPENVPN_ROOT="${OPENVPN_ROOT:-/etc/autoscript/openvpn}"
SERVER_CONF="$(trim "${SERVER_CONF:-}")"
if [[ -z "$SERVER_CONF" ]]; then
  SERVER_CONF="$(first_existing \
    "${OPENVPN_ROOT}/server-tcp.conf" \
    "/etc/openvpn/server/autoscript-tcp.conf" \
    "/etc/openvpn/server/server.conf" \
    "/etc/openvpn/server.conf" \
    2>/dev/null || true)"
fi

PORT_TCP="$(read_env_value OPENVPN_PORT_TCP "$CONFIG_ENV" 2>/dev/null || true)"
PUBLIC_PORT_TCP="$(read_env_value OPENVPN_PUBLIC_PORT_TCP "$CONFIG_ENV" 2>/dev/null || true)"
PUBLIC_HOST="$(read_env_value OPENVPN_PUBLIC_HOST "$CONFIG_ENV" 2>/dev/null || true)"

PROTO="$(read_conf_value proto "$SERVER_CONF" 2>/dev/null || true)"
PORT_CONF="$(read_conf_value port "$SERVER_CONF" 2>/dev/null || true)"
STATUS_FILE="$(read_conf_value status "$SERVER_CONF" 2>/dev/null || true)"
LOG_FILE="$(read_conf_value log-append "$SERVER_CONF" 2>/dev/null || true)"
SERVER_NET="$(read_conf_value server "$SERVER_CONF" 2>/dev/null || true)"
USER_DIRECTIVE="$(read_conf_value user "$SERVER_CONF" 2>/dev/null || true)"
GROUP_DIRECTIVE="$(read_conf_value group "$SERVER_CONF" 2>/dev/null || true)"
TLS_MIN="$(read_conf_value tls-version-min "$SERVER_CONF" 2>/dev/null || true)"
AUTH_DIGEST="$(read_conf_value auth "$SERVER_CONF" 2>/dev/null || true)"
DATA_CIPHERS="$(read_conf_value data-ciphers "$SERVER_CONF" 2>/dev/null || true)"
DATA_CIPHERS_FALLBACK="$(read_conf_value data-ciphers-fallback "$SERVER_CONF" 2>/dev/null || true)"
CIPHER_LEGACY="$(read_conf_value cipher "$SERVER_CONF" 2>/dev/null || true)"
CA_FILE="$(read_conf_value ca "$SERVER_CONF" 2>/dev/null || true)"
CERT_FILE="$(read_conf_value cert "$SERVER_CONF" 2>/dev/null || true)"
KEY_FILE="$(read_conf_value key "$SERVER_CONF" 2>/dev/null || true)"
CRL_FILE="$(read_conf_value crl-verify "$SERVER_CONF" 2>/dev/null || true)"
VERIFY_CLIENT_CERT="$(read_conf_value verify-client-cert "$SERVER_CONF" 2>/dev/null || true)"

LISTEN_PORT="${PORT_CONF:-${PORT_TCP:-}}"

HOSTNAME_FQDN="$(hostname -f 2>/dev/null || hostname 2>/dev/null || printf 'unknown')"
OPENVPN_VERSION="$(openvpn --version 2>/dev/null | awk 'NR==1 {print $2" "$3}' || true)"
SERVICE_STATE="$(systemctl is-active "$SERVICE" 2>/dev/null || true)"
SERVICE_ENABLED="$(systemctl is-enabled "$SERVICE" 2>/dev/null || true)"
IP_FORWARD="$(sysctl -n net.ipv4.ip_forward 2>/dev/null || true)"

if [[ -z "$SERVER_CONF" || ! -f "$SERVER_CONF" ]]; then
  add_finding "High" "Server config tidak ditemukan. Gunakan --server-conf atau pastikan file config ada di /etc/openvpn/server/."
fi

if [[ -n "$SERVICE_STATE" && "$SERVICE_STATE" != "active" ]]; then
  add_finding "High" "Service ${SERVICE} tidak active (state: ${SERVICE_STATE})."
elif [[ -z "$SERVICE_STATE" ]]; then
  add_finding "Medium" "Service ${SERVICE} tidak dapat dipastikan via systemctl."
fi

if [[ -n "$TLS_MIN" ]]; then
  case "$TLS_MIN" in
    1.0|1.1)
      add_finding "High" "tls-version-min masih ${TLS_MIN}; minimal 1.2."
      ;;
  esac
else
  add_finding "Medium" "tls-version-min tidak ditemukan di config."
fi

if has_conf_directive "compress" "$SERVER_CONF" || has_conf_directive "comp-lzo" "$SERVER_CONF"; then
  add_finding "High" "Compression aktif; ini sebaiknya dimatikan kecuali ada kebutuhan kompatibilitas yang jelas."
fi

if has_conf_directive "duplicate-cn" "$SERVER_CONF"; then
  add_finding "Medium" "duplicate-cn aktif; satu identitas client bisa dipakai paralel."
fi

if has_conf_directive "client-to-client" "$SERVER_CONF"; then
  add_finding "Medium" "client-to-client aktif; lateral movement antar client lebih mudah."
fi

if [[ -z "$CRL_FILE" ]]; then
  add_finding "Medium" "crl-verify tidak dikonfigurasi."
elif [[ ! -f "$CRL_FILE" ]]; then
  add_finding "Medium" "File CRL tidak ditemukan: ${CRL_FILE}."
fi

if [[ -z "$USER_DIRECTIVE" ]]; then
  add_finding "Medium" "Directive user tidak ada; proses bisa tetap berjalan lebih privileged dari yang perlu."
fi

if [[ -z "$GROUP_DIRECTIVE" ]]; then
  add_finding "Low" "Directive group tidak ada."
fi

if [[ "$AUTH_DIGEST" == "SHA1" ]]; then
  add_finding "Medium" "auth masih SHA1; pertimbangkan digest yang lebih kuat jika kompatibilitas client memungkinkan."
fi

if [[ "$DATA_CIPHERS" == *CBC* || "$DATA_CIPHERS_FALLBACK" == *CBC* || "$CIPHER_LEGACY" == *CBC* ]]; then
  add_finding "Medium" "Cipher CBC masih diizinkan untuk kompatibilitas; audit apakah semua client masih membutuhkannya."
fi

if ! has_conf_directive "tls-auth" "$SERVER_CONF" && ! has_conf_directive "tls-crypt" "$SERVER_CONF"; then
  add_note "Tidak ada tls-auth/tls-crypt. Pada repo autoscript ini memang by design, tapi tetap menambah noise dari internet scan."
fi

if [[ -n "$VERIFY_CLIENT_CERT" && "$VERIFY_CLIENT_CERT" == "none" ]]; then
  add_note "verify-client-cert none aktif. Ini konsisten dengan mode auth username/password linked ke akun SSH."
fi

if [[ -n "$KEY_FILE" && -f "$KEY_FILE" ]]; then
  KEY_PERM="$(perm_octal "$KEY_FILE")"
  if [[ -n "$KEY_PERM" && "$KEY_PERM" -gt 600 ]]; then
    add_finding "High" "Permission server key terlalu longgar (${KEY_PERM}) di ${KEY_FILE}."
  fi
elif [[ -n "$KEY_FILE" ]]; then
  add_finding "High" "File server key tidak ditemukan: ${KEY_FILE}."
fi

if [[ -n "$CERT_FILE" && ! -f "$CERT_FILE" ]]; then
  add_finding "High" "File server cert tidak ditemukan: ${CERT_FILE}."
fi

if [[ -n "$CA_FILE" && ! -f "$CA_FILE" ]]; then
  add_finding "High" "File CA tidak ditemukan: ${CA_FILE}."
fi

if [[ "$IP_FORWARD" != "1" ]]; then
  add_finding "High" "net.ipv4.ip_forward = ${IP_FORWARD:-unknown}; routing client bisa gagal."
fi

SUBNET_ADDR="$(awk '{print $1}' <<<"${SERVER_NET:-}")"
NFT_HAS_AUTOSCRIPT_OPENVPN=""
if command -v nft >/dev/null 2>&1; then
  if nft list table ip autoscript_openvpn >/dev/null 2>&1; then
    NFT_HAS_AUTOSCRIPT_OPENVPN="yes"
  fi
fi

IPTABLES_HAS_MASQ=""
if [[ -n "$SUBNET_ADDR" ]] && command -v iptables >/dev/null 2>&1; then
  if iptables -t nat -S 2>/dev/null | grep -Fq "$SUBNET_ADDR"; then
    IPTABLES_HAS_MASQ="yes"
  fi
fi

if [[ "$NFT_HAS_AUTOSCRIPT_OPENVPN" != "yes" && "$IPTABLES_HAS_MASQ" != "yes" ]]; then
  add_finding "Medium" "Rule NAT OpenVPN tidak terdeteksi via nftables maupun iptables."
fi

LISTENER_LINE=""
if [[ -n "$LISTEN_PORT" ]]; then
  LISTENER_LINE="$(ss -ltnp 2>/dev/null | grep -E ":${LISTEN_PORT}\\b" | head -n1 || true)"
  if [[ -z "$LISTENER_LINE" ]]; then
    add_finding "High" "Tidak ada listener TCP pada port ${LISTEN_PORT}."
  fi
fi

CERT_NOT_AFTER=""
CERT_DAYS_LEFT=""
if [[ -n "$CERT_FILE" && -f "$CERT_FILE" ]]; then
  CERT_NOT_AFTER="$(cert_not_after "$CERT_FILE")"
  CERT_DAYS_LEFT="$(days_until_date "$CERT_NOT_AFTER" 2>/dev/null || true)"
  if [[ -n "$CERT_DAYS_LEFT" ]]; then
    if (( CERT_DAYS_LEFT < 0 )); then
      add_finding "High" "Server certificate sudah expired (${CERT_NOT_AFTER})."
    elif (( CERT_DAYS_LEFT <= 30 )); then
      add_finding "Medium" "Server certificate akan expired dalam ${CERT_DAYS_LEFT} hari (${CERT_NOT_AFTER})."
    fi
  fi
fi

BAD_PACKET_COUNT="0"
AUTH_FAIL_COUNT="0"
RECENT_ERRORS=""
if command -v journalctl >/dev/null 2>&1; then
  BAD_PACKET_COUNT="$(journalctl -u "$SERVICE" --since "$SINCE" --no-pager 2>/dev/null | grep -c 'Bad encapsulated packet length from peer' || true)"
  AUTH_FAIL_COUNT="$(journalctl -u "$SERVICE" --since "$SINCE" --no-pager 2>/dev/null | grep -Eic 'auth.*fail|authentication failed|AUTH_FAILED|bad username|bad password' || true)"
  RECENT_ERRORS="$(journalctl -u "$SERVICE" --since "$SINCE" --no-pager 2>/dev/null | grep -Ei 'error|warn|fail|bad encapsulated' | tail -n 10 || true)"
elif [[ -n "$LOG_FILE" && -f "$LOG_FILE" ]]; then
  BAD_PACKET_COUNT="$(grep -c 'Bad encapsulated packet length from peer' "$LOG_FILE" 2>/dev/null || true)"
  AUTH_FAIL_COUNT="$(grep -Eic 'auth.*fail|authentication failed|AUTH_FAILED|bad username|bad password' "$LOG_FILE" 2>/dev/null || true)"
  RECENT_ERRORS="$(grep -Ei 'error|warn|fail|bad encapsulated' "$LOG_FILE" 2>/dev/null | tail -n 10 || true)"
fi

print_section "Summary"
printf 'Host           : %s\n' "$HOSTNAME_FQDN"
printf 'Time           : %s\n' "$(date '+%F %T %Z')"
printf 'OpenVPN        : %s\n' "${OPENVPN_VERSION:-unknown}"
printf 'Service        : %s\n' "$SERVICE"
printf 'Service state  : %s\n' "${SERVICE_STATE:-unknown}"
printf 'Service enabled: %s\n' "${SERVICE_ENABLED:-unknown}"
printf 'Config env     : %s\n' "$CONFIG_ENV"
printf 'Server conf    : %s\n' "${SERVER_CONF:-not found}"

print_section "Runtime"
printf 'Public host    : %s\n' "${PUBLIC_HOST:-unknown}"
printf 'Port (public)  : %s\n' "${PUBLIC_PORT_TCP:-unknown}"
printf 'Port (server)  : %s\n' "${LISTEN_PORT:-unknown}"
printf 'Proto          : %s\n' "${PROTO:-unknown}"
printf 'Listener       : %s\n' "${LISTENER_LINE:-not found}"
printf 'IPv4 forward   : %s\n' "${IP_FORWARD:-unknown}"
printf 'Status file    : %s\n' "${STATUS_FILE:-unset}"
printf 'Log file       : %s\n' "${LOG_FILE:-unset}"

print_section "Config Snapshot"
printf 'server         : %s\n' "${SERVER_NET:-unset}"
printf 'user/group     : %s / %s\n' "${USER_DIRECTIVE:-unset}" "${GROUP_DIRECTIVE:-unset}"
printf 'tls-version-min: %s\n' "${TLS_MIN:-unset}"
printf 'auth           : %s\n' "${AUTH_DIGEST:-unset}"
printf 'data-ciphers   : %s\n' "${DATA_CIPHERS:-unset}"
printf 'fallback cipher: %s\n' "${DATA_CIPHERS_FALLBACK:-unset}"
printf 'legacy cipher  : %s\n' "${CIPHER_LEGACY:-unset}"
printf 'crl-verify     : %s\n' "${CRL_FILE:-unset}"
printf 'verify-client  : %s\n' "${VERIFY_CLIENT_CERT:-unset}"

if [[ -n "$CERT_NOT_AFTER" ]]; then
  printf 'server cert exp: %s' "$CERT_NOT_AFTER"
  [[ -n "$CERT_DAYS_LEFT" ]] && printf ' (%s days left)' "$CERT_DAYS_LEFT"
  printf '\n'
fi

if [[ -n "$KEY_FILE" ]]; then
  printf 'server key perm: %s (%s)\n' "$(perm_octal "$KEY_FILE")" "$KEY_FILE"
fi

print_section "Findings"
if [[ ${#findings[@]} -eq 0 ]]; then
  printf 'No material findings detected by this script.\n'
else
  i=1
  for entry in "${findings[@]}"; do
    printf '%d. [%s] %s\n' "$i" "${entry%%|*}" "${entry#*|}"
    i=$((i + 1))
  done
fi

print_section "Notes"
if [[ ${#notes[@]} -eq 0 ]]; then
  printf 'No extra notes.\n'
else
  i=1
  for note in "${notes[@]}"; do
    printf '%d. %s\n' "$i" "$note"
    i=$((i + 1))
  done
fi

print_section "Recent Log Signals"
printf 'Bad encapsulated packet length: %s\n' "${BAD_PACKET_COUNT:-0}"
printf 'Authentication failures      : %s\n' "${AUTH_FAIL_COUNT:-0}"
if [[ -n "$RECENT_ERRORS" ]]; then
  printf '%s\n' "$RECENT_ERRORS"
else
  printf 'No recent warning/error lines captured.\n'
fi

print_section "Next Steps"
printf '1. Jalankan script ini dengan sudo di host live.\n'
printf '2. Review temuan High/Medium dulu, lalu cek 20-50 baris log di sekitar error.\n'
printf '3. Untuk audit manual lanjutan, cocokkan hasil ini dengan firewall, route push, dan account lifecycle SSH-linked.\n'
