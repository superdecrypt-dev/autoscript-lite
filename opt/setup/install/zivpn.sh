#!/usr/bin/env bash
# ZIVPN UDP install/runtime module for setup runtime.

ZIVPN_UPSTREAM_AMD64_INSTALLER_URL="${ZIVPN_UPSTREAM_AMD64_INSTALLER_URL:-https://raw.githubusercontent.com/zahidbd2/udp-zivpn/main/zi.sh}"
ZIVPN_UPSTREAM_ARM64_INSTALLER_URL="${ZIVPN_UPSTREAM_ARM64_INSTALLER_URL:-https://raw.githubusercontent.com/zahidbd2/udp-zivpn/main/zi2.sh}"
ZIVPN_SYNC_HELPER_DST="${ZIVPN_SYNC_HELPER_DST:-/usr/local/bin/zivpn-password-sync}"

zivpn_arch_label() {
  case "$(uname -m)" in
    x86_64|amd64) printf '%s\n' "amd64" ;;
    aarch64|arm64) printf '%s\n' "arm64" ;;
    *) return 1 ;;
  esac
}

zivpn_installer_url() {
  local arch
  arch="$(zivpn_arch_label)" || return 1
  case "${arch}" in
    amd64) printf '%s\n' "${ZIVPN_UPSTREAM_AMD64_INSTALLER_URL}" ;;
    arm64) printf '%s\n' "${ZIVPN_UPSTREAM_ARM64_INSTALLER_URL}" ;;
    *) return 1 ;;
  esac
}

zivpn_run_upstream_installer() {
  local url="${1:-}"
  local tmp_script tmp_log

  [[ -n "${url}" ]] || die "URL installer upstream ZIVPN kosong."

  tmp_script="$(mktemp "${TMPDIR:-/tmp}/zi.XXXXXX.sh")" || die "Gagal membuat file installer sementara ZIVPN."
  tmp_log="$(mktemp "${TMPDIR:-/tmp}/zi.XXXXXX.log")" || {
    rm -f "${tmp_script}" >/dev/null 2>&1 || true
    die "Gagal membuat log sementara ZIVPN."
  }

  if ! wget -qO "${tmp_script}" "${url}"; then
    rm -f "${tmp_script}" "${tmp_log}" >/dev/null 2>&1 || true
    die "Gagal mengunduh installer upstream ZIVPN: ${url}"
  fi
  chmod 755 "${tmp_script}" >/dev/null 2>&1 || true

  # Jalankan installer upstream apa adanya. Input kosong menjaga default password upstream.
  if ! printf '\n' | bash "${tmp_script}" >"${tmp_log}" 2>&1; then
    cat "${tmp_log}" >&2 || true
    rm -f "${tmp_script}" "${tmp_log}" >/dev/null 2>&1 || true
    die "Installer upstream ZIVPN gagal dijalankan."
  fi

  rm -f "${tmp_script}" "${tmp_log}" >/dev/null 2>&1 || true
}

zivpn_install_sync_helper() {
  local helper_src="${SETUP_BIN_SRC_DIR}/zivpn-password-sync.py"
  [[ -f "${helper_src}" ]] || die "Helper sync password ZIVPN tidak ditemukan: ${helper_src}"
  install -D -m 755 "${helper_src}" "${ZIVPN_SYNC_HELPER_DST}"
}

install_zivpn_stack() {
  local installer_url
  ok "Pasang ZIVPN UDP via installer upstream..."
  installer_url="$(zivpn_installer_url)" || die "Arsitektur host belum didukung oleh installer upstream ZIVPN."
  zivpn_run_upstream_installer "${installer_url}"
  zivpn_install_sync_helper

  if systemctl is-active --quiet zivpn.service; then
    ok "ZIVPN UDP upstream aktif."
  else
    warn "Installer upstream ZIVPN selesai, tetapi service belum aktif. Cek: journalctl -u zivpn.service -n 120 --no-pager"
  fi
}
