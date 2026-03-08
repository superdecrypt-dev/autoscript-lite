#!/usr/bin/env bash

BADVPN_DIST_DIR="${SCRIPT_DIR}/opt/badvpn/dist"
BADVPN_DIST_MANIFEST="${BADVPN_DIST_DIR}/SHA256SUMS"
BADVPN_RUNTIME_ENV_FILE="${BADVPN_RUNTIME_ENV_FILE:-/etc/default/badvpn-udpgw}"
BADVPN_RUNTIME_ENV_TEMPLATE="${SETUP_TEMPLATE_SRC_DIR}/config/badvpn-runtime.env"
BADVPN_SERVICE_TEMPLATE="${SETUP_TEMPLATE_SRC_DIR}/systemd/badvpn-udpgw.service"
BADVPN_BIN_INSTALL_PATH="${BADVPN_BIN_INSTALL_PATH:-/usr/local/bin/badvpn-udpgw}"
BADVPN_SERVICE_NAME="${BADVPN_SERVICE_NAME:-badvpn-udpgw.service}"

badvpn_arch_label() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) return 1 ;;
  esac
}

badvpn_expected_binary_path() {
  local arch
  arch="$(badvpn_arch_label)" || return 1
  printf '%s/badvpn-udpgw-linux-%s\n' "${BADVPN_DIST_DIR}" "${arch}"
}

badvpn_prebuilt_ready() {
  local bin
  [[ -f "${BADVPN_DIST_MANIFEST}" ]] || return 1
  bin="$(badvpn_expected_binary_path)" || return 1
  [[ -f "${bin}" ]] || return 1
  return 0
}

badvpn_verify_prebuilt_binary() {
  local bin name expected actual
  badvpn_prebuilt_ready || return 1
  command -v sha256sum >/dev/null 2>&1 || return 1
  bin="$(badvpn_expected_binary_path)" || return 1
  name="$(basename "${bin}")"
  expected="$(awk -v target="${name}" '$2 == target {print tolower($1)}' "${BADVPN_DIST_MANIFEST}" | head -n1)"
  [[ -n "${expected}" ]] || return 1
  actual="$(sha256sum "${bin}" | awk '{print tolower($1)}')"
  [[ -n "${actual}" && "${actual}" == "${expected}" ]]
}

write_badvpn_runtime_env() {
  if [[ -f "${BADVPN_RUNTIME_ENV_TEMPLATE}" ]]; then
    render_setup_template_or_die "config/badvpn-runtime.env" "${BADVPN_RUNTIME_ENV_FILE}" 0644
  else
    cat > "${BADVPN_RUNTIME_ENV_FILE}" <<'EOF'
BADVPN_UDPGW_PORT=7300
BADVPN_UDPGW_MAX_CLIENTS=512
BADVPN_UDPGW_MAX_CONNECTIONS_FOR_CLIENT=8
BADVPN_UDPGW_BUFFER_SIZE=1048576
EOF
  fi
}

install_badvpn_udpgw_stack() {
  local bin src_name
  if ! badvpn_prebuilt_ready; then
    warn "Binary prebuilt BadVPN UDPGW belum ada. Skip."
    return 0
  fi

  if [[ ! -f "${BADVPN_SERVICE_TEMPLATE}" ]]; then
    die "Template service BadVPN UDPGW tidak ditemukan: ${BADVPN_SERVICE_TEMPLATE}"
  fi

  badvpn_verify_prebuilt_binary || die "Checksum binary prebuilt BadVPN UDPGW gagal: ${BADVPN_DIST_MANIFEST}"

  bin="$(badvpn_expected_binary_path)" || die "Arsitektur host belum didukung untuk BadVPN UDPGW."
  src_name="$(basename "${bin}")"
  install -d -m 755 "$(dirname "${BADVPN_BIN_INSTALL_PATH}")"
  install -m 0755 "${bin}" "${BADVPN_BIN_INSTALL_PATH}"
  chown root:root "${BADVPN_BIN_INSTALL_PATH}" 2>/dev/null || true

  write_badvpn_runtime_env
  render_setup_template_or_die \
    "systemd/badvpn-udpgw.service" \
    "/etc/systemd/system/${BADVPN_SERVICE_NAME}" \
    0644 \
    "BADVPN_BIN_INSTALL_PATH=${BADVPN_BIN_INSTALL_PATH}" \
    "BADVPN_RUNTIME_ENV_FILE=${BADVPN_RUNTIME_ENV_FILE}"

  systemctl daemon-reload >/dev/null 2>&1 || true
  service_enable_restart_checked "${BADVPN_SERVICE_NAME}" || die "Gagal mengaktifkan ${BADVPN_SERVICE_NAME}"
  ok "BadVPN UDPGW aktif (${src_name})"
}
