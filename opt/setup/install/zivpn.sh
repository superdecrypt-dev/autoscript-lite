#!/usr/bin/env bash
# ZIVPN UDP install/runtime module for setup runtime.

ZIVPN_DIST_DIR="${SCRIPT_DIR}/opt/zivpn/dist"
ZIVPN_RUNTIME_ROOT="${ZIVPN_RUNTIME_ROOT:-/etc/zivpn}"
ZIVPN_CONFIG_FILE="${ZIVPN_CONFIG_FILE:-${ZIVPN_RUNTIME_ROOT}/config.json}"
ZIVPN_CERT_FILE="${ZIVPN_CERT_FILE:-${ZIVPN_RUNTIME_ROOT}/zivpn.crt}"
ZIVPN_KEY_FILE="${ZIVPN_KEY_FILE:-${ZIVPN_RUNTIME_ROOT}/zivpn.key}"
ZIVPN_PASSWORDS_DIR="${ZIVPN_PASSWORDS_DIR:-${ZIVPN_RUNTIME_ROOT}/passwords.d}"
ZIVPN_BIN_INSTALL_PATH="${ZIVPN_BIN_INSTALL_PATH:-/usr/local/bin/zivpn}"
ZIVPN_SYNC_BIN="${ZIVPN_SYNC_BIN:-/usr/local/bin/zivpn-password-sync}"
ZIVPN_SYNC_SRC="${SETUP_BIN_SRC_DIR}/zivpn-password-sync.py"
ZIVPN_SERVICE_NAME="${ZIVPN_SERVICE_NAME:-zivpn.service}"
ZIVPN_SERVICE_TEMPLATE="${SETUP_TEMPLATE_SRC_DIR}/systemd/zivpn.service"
ZIVPN_ACCOUNT_DIR="${ZIVPN_ACCOUNT_DIR:-/opt/account/ssh}"
ZIVPN_LISTEN_PORT="${ZIVPN_LISTEN_PORT:-5667}"
ZIVPN_OBFS="${ZIVPN_OBFS:-zivpn}"

zivpn_arch_label() {
  case "$(uname -m)" in
    x86_64|amd64) printf '%s\n' "amd64" ;;
    aarch64|arm64) printf '%s\n' "arm64" ;;
    *) return 1 ;;
  esac
}

zivpn_expected_binary_path() {
  local arch
  arch="$(zivpn_arch_label)" || return 1
  case "${arch}" in
    amd64) printf '%s\n' "${ZIVPN_DIST_DIR}/zivpn-linux-amd64" ;;
    arm64) printf '%s\n' "${ZIVPN_DIST_DIR}/zivpn-linux-arm64" ;;
    *) return 1 ;;
  esac
}

zivpn_prebuilt_ready() {
  local bin
  bin="$(zivpn_expected_binary_path)" || return 1
  [[ -f "${bin}" && -s "${bin}" ]]
}

zivpn_validate_port() {
  [[ "${ZIVPN_LISTEN_PORT}" =~ ^[0-9]+$ ]] || die "ZIVPN_LISTEN_PORT harus angka 1..65535 (got: ${ZIVPN_LISTEN_PORT})."
  if (( ZIVPN_LISTEN_PORT < 1 || ZIVPN_LISTEN_PORT > 65535 )); then
    die "ZIVPN_LISTEN_PORT di luar range 1..65535 (got: ${ZIVPN_LISTEN_PORT})."
  fi
}

zivpn_cert_matches_domain() {
  local target_domain="${1:-}"
  [[ -n "${target_domain}" ]] || return 1
  [[ -s "${ZIVPN_CERT_FILE}" && -s "${ZIVPN_KEY_FILE}" ]] || return 1
  command -v openssl >/dev/null 2>&1 || return 1
  openssl x509 -in "${ZIVPN_CERT_FILE}" -noout -subject 2>/dev/null | grep -qi "CN[[:space:]]*=[[:space:]]*${target_domain}"
}

zivpn_ensure_cert() {
  local target_domain="${DOMAIN:-}"
  [[ -n "${target_domain}" ]] || target_domain="$(detect_domain 2>/dev/null || true)"
  [[ -n "${target_domain}" ]] || target_domain="zivpn.local"

  if zivpn_cert_matches_domain "${target_domain}"; then
    return 0
  fi

  command -v openssl >/dev/null 2>&1 || die "openssl dibutuhkan untuk membuat sertifikat ZIVPN."
  install -d -m 700 "${ZIVPN_RUNTIME_ROOT}" "${ZIVPN_PASSWORDS_DIR}"
  if ! openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout "${ZIVPN_KEY_FILE}" \
    -out "${ZIVPN_CERT_FILE}" \
    -days 3650 \
    -subj "/CN=${target_domain}" >/dev/null 2>&1; then
    die "Gagal membuat sertifikat self-signed ZIVPN."
  fi
  chmod 600 "${ZIVPN_KEY_FILE}" >/dev/null 2>&1 || true
  chmod 644 "${ZIVPN_CERT_FILE}" >/dev/null 2>&1 || true
  chown root:root "${ZIVPN_KEY_FILE}" "${ZIVPN_CERT_FILE}" 2>/dev/null || true
}

zivpn_password_files_present() {
  find "${ZIVPN_PASSWORDS_DIR}" -maxdepth 1 -type f -name '*.pass' | grep -q .
}

install_zivpn_stack() {
  local bin
  ok "Pasang ZIVPN UDP..."
  command -v python3 >/dev/null 2>&1 || die "python3 dibutuhkan untuk ZIVPN password sync."
  [[ -f "${ZIVPN_SERVICE_TEMPLATE}" ]] || die "Template service ZIVPN tidak ditemukan: ${ZIVPN_SERVICE_TEMPLATE}"
  [[ -f "${ZIVPN_SYNC_SRC}" ]] || die "Asset sync ZIVPN tidak ditemukan: ${ZIVPN_SYNC_SRC}"
  zivpn_prebuilt_ready || die "Binary prebuilt ZIVPN belum tersedia untuk arsitektur host."
  zivpn_validate_port

  bin="$(zivpn_expected_binary_path)" || die "Arsitektur host belum didukung untuk ZIVPN."

  install -d -m 755 "$(dirname "${ZIVPN_BIN_INSTALL_PATH}")"
  install -m 0755 "${bin}" "${ZIVPN_BIN_INSTALL_PATH}"
  chown root:root "${ZIVPN_BIN_INSTALL_PATH}" 2>/dev/null || true

  install -d -m 700 "${ZIVPN_RUNTIME_ROOT}" "${ZIVPN_PASSWORDS_DIR}"
  install_setup_bin_or_die "zivpn-password-sync.py" "${ZIVPN_SYNC_BIN}" 0755
  zivpn_ensure_cert

  render_setup_template_or_die \
    "systemd/zivpn.service" \
    "/etc/systemd/system/${ZIVPN_SERVICE_NAME}" \
    0644 \
    "ZIVPN_BIN_INSTALL_PATH=${ZIVPN_BIN_INSTALL_PATH}" \
    "ZIVPN_CONFIG_FILE=${ZIVPN_CONFIG_FILE}"

  systemctl daemon-reload

  if ! "${ZIVPN_SYNC_BIN}" \
    --config "${ZIVPN_CONFIG_FILE}" \
    --passwords-dir "${ZIVPN_PASSWORDS_DIR}" \
    --listen ":${ZIVPN_LISTEN_PORT}" \
    --cert "${ZIVPN_CERT_FILE}" \
    --key "${ZIVPN_KEY_FILE}" \
    --obfs "${ZIVPN_OBFS}" \
    --account-dir "${ZIVPN_ACCOUNT_DIR}" \
    --seed-from-account-info \
    --service "${ZIVPN_SERVICE_NAME}" \
    --sync-service-state >/dev/null 2>&1; then
    journalctl -u "${ZIVPN_SERVICE_NAME}" -n 120 --no-pager >&2 || true
    die "Gagal sinkronisasi awal runtime ZIVPN."
  fi

  if zivpn_password_files_present; then
    if systemctl is-active --quiet "${ZIVPN_SERVICE_NAME}"; then
      ok "ZIVPN UDP aktif di port ${ZIVPN_LISTEN_PORT}."
    else
      warn "ZIVPN password sudah tersinkron, tetapi service belum aktif. Cek: journalctl -u ${ZIVPN_SERVICE_NAME} -n 120 --no-pager"
    fi
  else
    ok "ZIVPN UDP siap. Service akan aktif otomatis setelah ada akun SSH yang disinkronkan."
  fi
}
