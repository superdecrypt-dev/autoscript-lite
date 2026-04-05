#!/usr/bin/env bash
# OpenVPN classic 2.6 install/runtime module for setup runtime.
# Design note:
# - OpenVPN tetap direct via routing host normal.
# - Jangan kaitkan egress OpenVPN ke WARP/Zero Trust tanpa redesign policy routing yang disengaja.

OPENVPN_ROOT="${OPENVPN_ROOT:-/etc/autoscript/openvpn}"
OPENVPN_CONFIG_ENV_FILE="${OPENVPN_CONFIG_ENV_FILE:-${OPENVPN_ROOT}/config.env}"
OPENVPN_DOMAIN_FILE="${OPENVPN_DOMAIN_FILE:-${XRAY_DOMAIN_FILE}}"
OPENVPN_EASYRSA_SHARE_DIR="${OPENVPN_EASYRSA_SHARE_DIR:-/usr/share/easy-rsa}"
OPENVPN_EASYRSA_DIR="${OPENVPN_EASYRSA_DIR:-/etc/openvpn/easy-rsa}"
OPENVPN_PKI_DIR="${OPENVPN_PKI_DIR:-${OPENVPN_EASYRSA_DIR}/pki}"
OPENVPN_SERVER_DIR="${OPENVPN_SERVER_DIR:-/etc/openvpn/server}"
OPENVPN_PROFILE_DIR="${OPENVPN_PROFILE_DIR:-/opt/account/openvpn}"
OPENVPN_METADATA_DIR="${OPENVPN_METADATA_DIR:-/var/lib/openvpn-manage/users}"
OPENVPN_SERVER_NAME="${OPENVPN_SERVER_NAME:-autoscript-server}"
OPENVPN_AUTH_PAM_SERVICE="${OPENVPN_AUTH_PAM_SERVICE:-openvpn}"
OPENVPN_PORT_TCP="${OPENVPN_PORT_TCP:-1194}"
OPENVPN_PUBLIC_PORT_TCP="${OPENVPN_PUBLIC_PORT_TCP:-443}"
OPENVPN_MANAGEMENT_HOST="${OPENVPN_MANAGEMENT_HOST:-127.0.0.1}"
OPENVPN_MANAGEMENT_PORT="${OPENVPN_MANAGEMENT_PORT:-21194}"
OPENVPN_WS_PROXY_PORT="${OPENVPN_WS_PROXY_PORT:-10016}"
OPENVPN_WS_PUBLIC_PATH="${OPENVPN_WS_PUBLIC_PATH:-}"
OPENVPN_WS_HANDSHAKE_TIMEOUT_SEC="${OPENVPN_WS_HANDSHAKE_TIMEOUT_SEC:-10}"
OPENVPN_SUBNET_TCP="${OPENVPN_SUBNET_TCP:-10.9.0.0}"
OPENVPN_NETMASK_TCP="${OPENVPN_NETMASK_TCP:-255.255.255.0}"
OPENVPN_DNS_PRIMARY="${OPENVPN_DNS_PRIMARY:-1.1.1.1}"
OPENVPN_DNS_SECONDARY="${OPENVPN_DNS_SECONDARY:-1.0.0.1}"
OPENVPN_NFT_RULE_FILE="${OPENVPN_NFT_RULE_FILE:-/etc/nftables.d/autoscript-openvpn.nft}"
OPENVPN_SYSCTL_FILE="${OPENVPN_SYSCTL_FILE:-/etc/sysctl.d/99-autoscript-openvpn.conf}"
OPENVPN_TCP_SERVICE="${OPENVPN_TCP_SERVICE:-openvpn-server@autoscript-tcp}"
OPENVPN_WS_SERVICE="${OPENVPN_WS_SERVICE:-ovpn-ws-proxy}"
OPENVPN_TUN_IFACE="${OPENVPN_TUN_IFACE:-tun0}"
OPENVPN_SPEED_SERVICE="${OPENVPN_SPEED_SERVICE:-openvpn-speed}"
OPENVPN_SPEED_RECONCILE_SERVICE="${OPENVPN_SPEED_RECONCILE_SERVICE:-openvpn-speed-reconcile}"
OPENVPN_SPEED_CONFIG_FILE="${OPENVPN_SPEED_CONFIG_FILE:-${OPENVPN_ROOT}/speed.json}"
OPENVPN_SPEED_STATE_DIR="${OPENVPN_SPEED_STATE_DIR:-/var/lib/openvpn-speed}"
OPENVPN_SPEED_IFB_IFACE="${OPENVPN_SPEED_IFB_IFACE:-ifb2}"
OPENVPN_SPEED_INTERVAL="${OPENVPN_SPEED_INTERVAL:-2}"
OPENVPN_SPEED_DEFAULT_RATE_MBIT="${OPENVPN_SPEED_DEFAULT_RATE_MBIT:-10000}"
OPENVPN_SPEED_EVENT_DIR="${OPENVPN_SPEED_EVENT_DIR:-/run/openvpn-speed-events}"
OPENVPN_STATUS_INTERVAL="${OPENVPN_STATUS_INTERVAL:-2}"
OPENVPN_QAC_PENDING_DIR="${OPENVPN_QAC_PENDING_DIR:-/run/openvpn-qac-disconnect}"
OPENVPN_QAC_TMPFILES_CONF="${OPENVPN_QAC_TMPFILES_CONF:-/etc/tmpfiles.d/openvpn-qac.conf}"
OPENVPN_TCP_SERVICE_DROPIN_DIR="${OPENVPN_TCP_SERVICE_DROPIN_DIR:-/etc/systemd/system/${OPENVPN_TCP_SERVICE}.service.d}"

openvpn_validate_port() {
  local name="$1"
  local value="$2"
  [[ "${value}" =~ ^[0-9]+$ ]] || die "${name} harus angka 1..65535 (got: ${value})."
  if (( value < 1 || value > 65535 )); then
    die "${name} di luar range 1..65535 (got: ${value})."
  fi
}

openvpn_validate_ws_path() {
  local path="${1:-}"
  [[ -n "${path}" ]] || die "OPENVPN_WS_PUBLIC_PATH tidak boleh kosong."
  [[ "${path}" == /* ]] || die "OPENVPN_WS_PUBLIC_PATH harus diawali '/' (got: ${path})."
  [[ "${path}" != *" "* ]] || die "OPENVPN_WS_PUBLIC_PATH tidak boleh mengandung spasi (got: ${path})."
  [[ "${path}" =~ ^/[A-Fa-f0-9]{10}$ ]] || die "OPENVPN_WS_PUBLIC_PATH harus token 10 karakter heksadesimal seperti SSH WS (got: ${path})."
}

openvpn_ws_generate_token() {
  python3 - <<'PY'
import secrets
print("/" + secrets.token_hex(5))
PY
}

openvpn_ws_public_path_value() {
  local path="${OPENVPN_WS_PUBLIC_PATH:-}"
  path="$(printf '%s' "${path}" | tr -d '\r' | xargs 2>/dev/null || true)"
  if [[ -n "${path}" && "${path}" =~ ^/[A-Fa-f0-9]{10}$ ]]; then
    printf '%s\n' "${path,,}"
    return 0
  fi

  if [[ -f "${OPENVPN_CONFIG_ENV_FILE}" ]]; then
    path="$(awk -F= '$1=="OPENVPN_WS_PUBLIC_PATH"{print substr($0, index($0, "=")+1); exit}' "${OPENVPN_CONFIG_ENV_FILE}" 2>/dev/null | tr -d '\r' | xargs 2>/dev/null || true)"
    if [[ -n "${path}" && "${path}" =~ ^/[A-Fa-f0-9]{10}$ ]]; then
      printf '%s\n' "${path,,}"
      return 0
    fi
  fi

  openvpn_ws_generate_token
}

openvpn_ws_handshake_timeout_sec_value() {
  local value="${OPENVPN_WS_HANDSHAKE_TIMEOUT_SEC:-10}"
  [[ "${value}" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "OPENVPN_WS_HANDSHAKE_TIMEOUT_SEC harus angka positif (got: ${value})."
  python3 - <<'PY' "${value}"
import sys
try:
    value = float(sys.argv[1])
except Exception:
    raise SystemExit(1)
if value <= 0:
    raise SystemExit(1)
print(f"{value:g}")
PY
  [[ $? -eq 0 ]] || die "OPENVPN_WS_HANDSHAKE_TIMEOUT_SEC harus > 0 (got: ${value})."
}

openvpn_public_host_value() {
  local host="${OPENVPN_PUBLIC_HOST:-}"
  host="$(printf '%s' "${host}" | tr -d '\r' | xargs 2>/dev/null || true)"
  if [[ -n "${host}" ]]; then
    printf '%s\n' "${host}"
    return 0
  fi
  host="$(printf '%s' "${DOMAIN:-}" | tr -d '\r' | xargs 2>/dev/null || true)"
  if [[ -n "${host}" ]]; then
    printf '%s\n' "${host}"
    return 0
  fi
  host="$(printf '%s' "$(detect_domain 2>/dev/null || true)" | tr -d '\r' | xargs 2>/dev/null || true)"
  if [[ -n "${host}" ]]; then
    printf '%s\n' "${host}"
    return 0
  fi
  host="$(main_info_ip_quiet_get 2>/dev/null || true)"
  [[ -n "${host}" ]] || host="$(detect_public_ip 2>/dev/null || true)"
  printf '%s\n' "${host:-127.0.0.1}"
}

openvpn_auth_pam_plugin_detect() {
  local candidate=""
  local -a candidates=(
    "/usr/lib/openvpn/openvpn-plugin-auth-pam.so"
    "/usr/lib/openvpn/plugins/openvpn-plugin-auth-pam.so"
    "/usr/lib/x86_64-linux-gnu/openvpn/plugins/openvpn-plugin-auth-pam.so"
    "/usr/lib/aarch64-linux-gnu/openvpn/plugins/openvpn-plugin-auth-pam.so"
  )
  for candidate in "${candidates[@]}"; do
    [[ -f "${candidate}" ]] || continue
    printf '%s\n' "${candidate}"
    return 0
  done
  candidate="$(find /usr/lib -type f -name 'openvpn-plugin-auth-pam.so' 2>/dev/null | head -n1 || true)"
  [[ -n "${candidate}" ]] || die "Plugin openvpn-plugin-auth-pam.so tidak ditemukan setelah install OpenVPN."
  printf '%s\n' "${candidate}"
}

openvpn_copy_easyrsa_tree_or_die() {
  local src="${OPENVPN_EASYRSA_SHARE_DIR}"
  [[ -d "${src}" ]] || die "Direktori easy-rsa share tidak ditemukan: ${src}"
  install -d -m 755 "${OPENVPN_EASYRSA_DIR}"
  if [[ ! -x "${OPENVPN_EASYRSA_DIR}/easyrsa" ]]; then
    cp -a "${src}/." "${OPENVPN_EASYRSA_DIR}/" || die "Gagal menyalin easy-rsa ke ${OPENVPN_EASYRSA_DIR}."
  fi
  if [[ ! -f "${OPENVPN_EASYRSA_DIR}/vars" && -f "${OPENVPN_EASYRSA_DIR}/vars.example" ]]; then
    cp -f "${OPENVPN_EASYRSA_DIR}/vars.example" "${OPENVPN_EASYRSA_DIR}/vars" || die "Gagal menyiapkan vars easy-rsa."
  fi
  chmod 755 "${OPENVPN_EASYRSA_DIR}/easyrsa" 2>/dev/null || true
}

openvpn_easyrsa_run_or_die() {
  local cn="${1:-}"
  shift || true
  if [[ -n "${cn}" ]]; then
    (
      cd "${OPENVPN_EASYRSA_DIR}" || exit 1
      EASYRSA_BATCH=1 EASYRSA_REQ_CN="${cn}" ./easyrsa "$@"
    ) >/dev/null 2>&1 || die "easy-rsa gagal: $*"
    return 0
  fi
  (
    cd "${OPENVPN_EASYRSA_DIR}" || exit 1
    EASYRSA_BATCH=1 ./easyrsa "$@"
  ) >/dev/null 2>&1 || die "easy-rsa gagal: $*"
}

openvpn_init_pki_or_die() {
  openvpn_copy_easyrsa_tree_or_die
  install -d -m 700 "${OPENVPN_ROOT}" "${OPENVPN_PROFILE_DIR}" "${OPENVPN_METADATA_DIR}"
  # OpenVPN drops to nobody:nogroup, so the server dir must remain traversable
  # for CRL re-stat/reload while keeping the private key itself mode 600.
  install -d -m 755 "${OPENVPN_SERVER_DIR}"
  if [[ ! -d "${OPENVPN_PKI_DIR}" ]]; then
    openvpn_easyrsa_run_or_die "autoscript-ca" init-pki
  fi
  if [[ ! -f "${OPENVPN_PKI_DIR}/ca.crt" ]]; then
    openvpn_easyrsa_run_or_die "autoscript-ca" build-ca nopass
  fi
  if [[ ! -f "${OPENVPN_PKI_DIR}/issued/${OPENVPN_SERVER_NAME}.crt" || ! -f "${OPENVPN_PKI_DIR}/private/${OPENVPN_SERVER_NAME}.key" ]]; then
    openvpn_easyrsa_run_or_die "" build-server-full "${OPENVPN_SERVER_NAME}" nopass
  fi
  openvpn_easyrsa_run_or_die "" gen-crl
  install -m 644 "${OPENVPN_PKI_DIR}/ca.crt" "${OPENVPN_SERVER_DIR}/ca.crt"
  install -m 644 "${OPENVPN_PKI_DIR}/issued/${OPENVPN_SERVER_NAME}.crt" "${OPENVPN_SERVER_DIR}/server.crt"
  install -m 600 "${OPENVPN_PKI_DIR}/private/${OPENVPN_SERVER_NAME}.key" "${OPENVPN_SERVER_DIR}/server.key"
  install -m 644 "${OPENVPN_PKI_DIR}/crl.pem" "${OPENVPN_SERVER_DIR}/crl.pem"
  chmod 755 "${OPENVPN_SERVER_DIR}" 2>/dev/null || true
  chmod 600 "${OPENVPN_SERVER_DIR}/server.key" 2>/dev/null || true
}

openvpn_write_pam_or_die() {
  cat > "/etc/pam.d/${OPENVPN_AUTH_PAM_SERVICE}" <<'EOF'
auth requisite pam_exec.so quiet /usr/local/bin/openvpn-auth-guard
@include common-auth
@include common-account
@include common-session-noninteractive
EOF
  chmod 644 "/etc/pam.d/${OPENVPN_AUTH_PAM_SERVICE}" 2>/dev/null || true
}

openvpn_write_sysctl_or_die() {
  cat > "${OPENVPN_SYSCTL_FILE}" <<'EOF'
net.ipv4.ip_forward=1
EOF
  chmod 644 "${OPENVPN_SYSCTL_FILE}" 2>/dev/null || true
  sysctl --system >/dev/null 2>&1 || die "Gagal menerapkan sysctl OpenVPN."
}

openvpn_ensure_nftables_include_or_die() {
  local conf="/etc/nftables.conf"
  if [[ ! -f "${conf}" ]]; then
    cat > "${conf}" <<'EOF'
#!/usr/sbin/nft -f
flush ruleset
include "/etc/nftables.d/*.nft"
EOF
  elif ! grep -Fq 'include "/etc/nftables.d/*.nft"' "${conf}" 2>/dev/null; then
    printf '\ninclude "/etc/nftables.d/*.nft"\n' >> "${conf}"
  fi
}

openvpn_write_nftables_or_die() {
  install -d -m 755 /etc/nftables.d
  render_setup_template_or_die \
    "config/openvpn-nftables.nft" \
    "${OPENVPN_NFT_RULE_FILE}" \
    0644 \
    "OPENVPN_SUBNET_TCP=${OPENVPN_SUBNET_TCP}" \
    "OPENVPN_NETMASK_TCP=${OPENVPN_NETMASK_TCP}"
  openvpn_ensure_nftables_include_or_die
  systemctl enable nftables >/dev/null 2>&1 || true
  nft delete table ip autoscript_openvpn >/dev/null 2>&1 || true
  nft -f "${OPENVPN_NFT_RULE_FILE}" >/dev/null 2>&1 || die "Gagal menerapkan NAT OpenVPN via nft."
  ok "nftables NAT OpenVPN aktif."
}

openvpn_render_runtime_or_die() {
  local public_host auth_pam_plugin
  public_host="$(openvpn_public_host_value)"
  auth_pam_plugin="$(openvpn_auth_pam_plugin_detect)"
  OPENVPN_WS_PUBLIC_PATH="$(openvpn_ws_public_path_value)"
  openvpn_validate_ws_path "${OPENVPN_WS_PUBLIC_PATH}"

  render_setup_template_or_die \
    "config/openvpn.env" \
    "${OPENVPN_CONFIG_ENV_FILE}" \
    0644 \
    "OPENVPN_ROOT=${OPENVPN_ROOT}" \
    "OPENVPN_DOMAIN_FILE=${OPENVPN_DOMAIN_FILE}" \
    "OPENVPN_EASYRSA_DIR=${OPENVPN_EASYRSA_DIR}" \
    "OPENVPN_PKI_DIR=${OPENVPN_PKI_DIR}" \
    "OPENVPN_SERVER_DIR=${OPENVPN_SERVER_DIR}" \
    "OPENVPN_PROFILE_DIR=${OPENVPN_PROFILE_DIR}" \
    "OPENVPN_METADATA_DIR=${OPENVPN_METADATA_DIR}" \
    "OPENVPN_SERVER_NAME=${OPENVPN_SERVER_NAME}" \
    "OPENVPN_PORT_TCP=${OPENVPN_PORT_TCP}" \
    "OPENVPN_PUBLIC_PORT_TCP=${OPENVPN_PUBLIC_PORT_TCP}" \
    "OPENVPN_PUBLIC_HOST=${public_host}" \
    "OPENVPN_MANAGEMENT_HOST=${OPENVPN_MANAGEMENT_HOST}" \
    "OPENVPN_MANAGEMENT_PORT=${OPENVPN_MANAGEMENT_PORT}" \
    "OPENVPN_WS_PROXY_PORT=${OPENVPN_WS_PROXY_PORT}" \
    "OPENVPN_WS_PUBLIC_PATH=${OPENVPN_WS_PUBLIC_PATH}" \
    "OPENVPN_WS_HANDSHAKE_TIMEOUT_SEC=$(openvpn_ws_handshake_timeout_sec_value)"

  render_setup_template_or_die \
    "config/openvpn-server-tcp.conf" \
    "${OPENVPN_SERVER_DIR}/autoscript-tcp.conf" \
    0600 \
    "OPENVPN_PORT_TCP=${OPENVPN_PORT_TCP}" \
    "OPENVPN_SUBNET_TCP=${OPENVPN_SUBNET_TCP}" \
    "OPENVPN_NETMASK_TCP=${OPENVPN_NETMASK_TCP}" \
    "OPENVPN_SERVER_DIR=${OPENVPN_SERVER_DIR}" \
    "OPENVPN_SERVER_NAME=${OPENVPN_SERVER_NAME}" \
    "OPENVPN_ROOT=${OPENVPN_ROOT}" \
    "OPENVPN_MANAGEMENT_HOST=${OPENVPN_MANAGEMENT_HOST}" \
    "OPENVPN_MANAGEMENT_PORT=${OPENVPN_MANAGEMENT_PORT}" \
    "OPENVPN_DNS_PRIMARY=${OPENVPN_DNS_PRIMARY}" \
    "OPENVPN_DNS_SECONDARY=${OPENVPN_DNS_SECONDARY}" \
    "OPENVPN_STATUS_INTERVAL=${OPENVPN_STATUS_INTERVAL}" \
    "OPENVPN_AUTH_PAM_PLUGIN=${auth_pam_plugin}" \
    "OPENVPN_AUTH_PAM_SERVICE=${OPENVPN_AUTH_PAM_SERVICE}"
}

openvpn_disable_legacy_udp_or_warn() {
  systemctl disable --now openvpn-server@autoscript-udp >/dev/null 2>&1 || true
  rm -f \
    "${OPENVPN_SERVER_DIR}/autoscript-udp.conf" \
    "${OPENVPN_ROOT}/status-udp.log" \
    "${OPENVPN_ROOT}/server-udp.log" \
    "${OPENVPN_ROOT}/ipp-udp.txt"
}

openvpn_install_ws_proxy_coupling_or_die() {
  install -d -m 755 "${OPENVPN_TCP_SERVICE_DROPIN_DIR}"
  render_setup_template_or_die \
    "systemd/openvpn-server-ovpn-ws-proxy.conf" \
    "${OPENVPN_TCP_SERVICE_DROPIN_DIR}/ovpn-ws-proxy.conf" \
    0644 \
    "OPENVPN_WS_SERVICE=${OPENVPN_WS_SERVICE}"
}

install_openvpn_stack() {
  ok "Pasang OpenVPN classic 2.6..."
  OPENVPN_WS_PUBLIC_PATH="$(openvpn_ws_public_path_value)"
  openvpn_validate_port "OPENVPN_PORT_TCP" "${OPENVPN_PORT_TCP}"
  openvpn_validate_port "OPENVPN_PUBLIC_PORT_TCP" "${OPENVPN_PUBLIC_PORT_TCP}"
  openvpn_validate_port "OPENVPN_WS_PROXY_PORT" "${OPENVPN_WS_PROXY_PORT}"
  openvpn_validate_ws_path "${OPENVPN_WS_PUBLIC_PATH}"
  export DEBIAN_FRONTEND=noninteractive
  ensure_dpkg_consistent
  apt_get_with_lock_retry install -y openvpn easy-rsa || die "Gagal menginstal openvpn/easy-rsa."
  openvpn_init_pki_or_die
  openvpn_write_pam_or_die
  openvpn_write_sysctl_or_die
  openvpn_write_nftables_or_die
  if declare -F install_sshws_proxy_binary_or_die >/dev/null 2>&1; then
    install_sshws_proxy_binary_or_die
  fi
  install -d -m 700 /run/autoscript
  install -d -m 770 "${OPENVPN_QAC_PENDING_DIR}"
  chown nobody:nogroup "${OPENVPN_QAC_PENDING_DIR}" 2>/dev/null || true
  install -d -m 770 "${OPENVPN_SPEED_EVENT_DIR}"
  chown nobody:nogroup "${OPENVPN_SPEED_EVENT_DIR}" 2>/dev/null || true
  install_repo_asset_or_die "opt/setup/templates/tmpfiles/openvpn-qac.conf" "${OPENVPN_QAC_TMPFILES_CONF}" 0644
  systemd-tmpfiles --create "${OPENVPN_QAC_TMPFILES_CONF}" >/dev/null 2>&1 || die "Gagal menyiapkan tmpfiles OpenVPN QAC."
  install_setup_bin_or_die "openvpn-manage.py" "/usr/local/bin/openvpn-manage" 0755
  install_setup_bin_or_die "openvpn-auth-guard.py" "/usr/local/bin/openvpn-auth-guard" 0755
  install_setup_bin_or_die "openvpn-connect-guard.py" "/usr/local/bin/openvpn-connect-guard" 0755
  install_setup_bin_or_die "openvpn-qac-hook.py" "/usr/local/bin/openvpn-qac-hook" 0755
  install_setup_bin_or_die "openvpn-session-kill.py" "/usr/local/bin/openvpn-session-kill" 0755
  openvpn_render_runtime_or_die
  openvpn_install_ws_proxy_coupling_or_die
  openvpn_disable_legacy_udp_or_warn
  render_setup_template_or_die \
    "systemd/ovpn-ws-proxy.service" \
    "/etc/systemd/system/${OPENVPN_WS_SERVICE}.service" \
    0644 \
    "OPENVPN_TCP_SERVICE=${OPENVPN_TCP_SERVICE}" \
    "OPENVPN_CONFIG_ENV_FILE=${OPENVPN_CONFIG_ENV_FILE}"
  systemctl daemon-reload
  service_enable_restart_checked "${OPENVPN_TCP_SERVICE}" || die "Gagal mengaktifkan ${OPENVPN_TCP_SERVICE}."
  service_enable_restart_checked "${OPENVPN_WS_SERVICE}" || die "Gagal mengaktifkan ${OPENVPN_WS_SERVICE}."
  # Nginx may have been rendered before OpenVPN finalized its WS public path.
  # Re-render here so the public path never stays empty and hijacks Xray routes.
  if declare -F write_nginx_config >/dev/null 2>&1; then
    write_nginx_config
  fi
  install_openvpn_speed_limiter_foundation
  ok "OpenVPN aktif: ${OPENVPN_TCP_SERVICE} (backend tcp/${OPENVPN_PORT_TCP}, public tcp/${OPENVPN_PUBLIC_PORT_TCP})"
  ok "OpenVPN WS aktif: ${OPENVPN_WS_SERVICE} (${OPENVPN_WS_PUBLIC_PATH} -> 127.0.0.1:${OPENVPN_WS_PROXY_PORT})"
}

install_openvpn_speed_limiter_foundation() {
  ok "Pasang openvpn-speed..."
  command -v python3 >/dev/null 2>&1 || die "python3 tidak ditemukan untuk openvpn-speed."
  install -d -m 700 "${OPENVPN_SPEED_STATE_DIR}"
  render_setup_template_or_die \
    "config/openvpn-speed-config.json" \
    "${OPENVPN_SPEED_CONFIG_FILE}" \
    0600 \
    "OPENVPN_TUN_IFACE=${OPENVPN_TUN_IFACE}" \
    "OPENVPN_SPEED_IFB_IFACE=${OPENVPN_SPEED_IFB_IFACE}" \
    "OPENVPN_ROOT=${OPENVPN_ROOT}" \
    "OPENVPN_SPEED_EVENT_DIR=${OPENVPN_SPEED_EVENT_DIR}" \
    "OPENVPN_SPEED_STATE_FILE=${OPENVPN_SPEED_STATE_DIR}/state.json" \
    "OPENVPN_SPEED_DEFAULT_RATE_MBIT=${OPENVPN_SPEED_DEFAULT_RATE_MBIT}"
  install_setup_bin_or_die "openvpn-speed.py" "/usr/local/bin/openvpn-speed" 0755
  render_setup_template_or_die \
    "systemd/openvpn-speed.service" \
    "/etc/systemd/system/${OPENVPN_SPEED_SERVICE}.service" \
    0644 \
    "OPENVPN_TCP_SERVICE=${OPENVPN_TCP_SERVICE}" \
    "OPENVPN_SPEED_CONFIG_FILE=${OPENVPN_SPEED_CONFIG_FILE}" \
    "OPENVPN_SPEED_INTERVAL=${OPENVPN_SPEED_INTERVAL}"
  render_setup_template_or_die \
    "systemd/openvpn-speed-reconcile.service" \
    "/etc/systemd/system/${OPENVPN_SPEED_RECONCILE_SERVICE}.service" \
    0644 \
    "OPENVPN_TCP_SERVICE=${OPENVPN_TCP_SERVICE}" \
    "OPENVPN_SPEED_CONFIG_FILE=${OPENVPN_SPEED_CONFIG_FILE}"
  render_setup_template_or_die \
    "systemd/openvpn-speed-reconcile.path" \
    "/etc/systemd/system/${OPENVPN_SPEED_RECONCILE_SERVICE}.path" \
    0644 \
    "OPENVPN_SPEED_RECONCILE_SERVICE=${OPENVPN_SPEED_RECONCILE_SERVICE}" \
    "OPENVPN_SPEED_EVENT_DIR=${OPENVPN_SPEED_EVENT_DIR}" \
    "OPENVPN_SPEED_STATE_ROOT=/opt/quota/openvpn"
  systemctl daemon-reload
  if service_enable_restart_checked "${OPENVPN_SPEED_SERVICE}"; then
    ok "openvpn-speed aktif:"
    ok "  - config : ${OPENVPN_SPEED_CONFIG_FILE}"
    ok "  - binary : /usr/local/bin/openvpn-speed"
    ok "  - service: ${OPENVPN_SPEED_SERVICE}"
  else
    warn "openvpn-speed gagal aktif otomatis. Cek: systemctl status ${OPENVPN_SPEED_SERVICE} --no-pager"
    systemctl disable --now "${OPENVPN_SPEED_SERVICE}" >/dev/null 2>&1 || true
  fi
  if systemctl enable --now "${OPENVPN_SPEED_RECONCILE_SERVICE}.path" >/dev/null 2>&1; then
    ok "openvpn-speed reconcile path aktif: ${OPENVPN_SPEED_RECONCILE_SERVICE}.path"
  else
    warn "openvpn-speed reconcile path gagal aktif. Cek: systemctl status ${OPENVPN_SPEED_RECONCILE_SERVICE}.path --no-pager"
    systemctl disable --now "${OPENVPN_SPEED_RECONCILE_SERVICE}.path" >/dev/null 2>&1 || true
  fi
}
