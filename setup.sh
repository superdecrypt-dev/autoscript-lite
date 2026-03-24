#!/usr/bin/env bash
# shellcheck disable=SC2034
set -euo pipefail

# Harden PATH untuk mencegah PATH hijacking saat script dijalankan sebagai root.
SAFE_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
PATH="${SAFE_PATH}"
export PATH

# shellcheck disable=SC2154
trap 'rc=$?; echo "[ERROR] line ${LINENO}: command failed (exit ${rc})" >&2; exit ${rc}' ERR

# =========================
# Setup-only autoscript:
# Xray + Nginx (nginx.org repo) + acme.sh
# Default transport layout uses Edge Gateway on shared 80/443
# Public paths fixed, internal ports & paths randomized
# Cert saved to /opt/cert/fullchain.pem & /opt/cert/privkey.pem
# Supports: Ubuntu >= 20.04, Debian >= 11
# =========================

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[0;37m'
NC='\033[0m'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SETUP_MODULES_ROOT="${SCRIPT_DIR}/opt/setup"

setup_bootstrap_die() {
  echo -e "${RED}[ERROR]${NC} $*" >&2
  exit 1
}

setup_module_dir_trusted() {
  local dir="$1"
  [[ -d "${dir}" ]] || return 1

  local root_real dir_real
  root_real="$(readlink -f -- "${SETUP_MODULES_ROOT}" 2>/dev/null || true)"
  dir_real="$(readlink -f -- "${dir}" 2>/dev/null || true)"
  [[ -n "${root_real}" && -n "${dir_real}" ]] || return 1
  [[ "${dir_real}" == "${root_real}" || "${dir_real}" == "${root_real}/"* ]] || return 1

  if [[ "$(id -u)" -ne 0 ]]; then
    return 0
  fi

  [[ -L "${dir}" ]] && return 1

  local owner mode
  owner="$(stat -c '%u' "${dir_real}" 2>/dev/null || echo 1)"
  mode="$(stat -c '%A' "${dir_real}" 2>/dev/null || echo '----------')"
  [[ "${owner}" == "0" ]] || return 1
  [[ "${mode:5:1}" != "w" && "${mode:8:1}" != "w" ]] || return 1
  return 0
}

setup_module_file_trusted() {
  local file="$1"
  [[ -f "${file}" && -r "${file}" ]] || return 1

  setup_module_dir_trusted "$(dirname "${file}")" || return 1

  local root_real file_real
  root_real="$(readlink -f -- "${SETUP_MODULES_ROOT}" 2>/dev/null || true)"
  file_real="$(readlink -f -- "${file}" 2>/dev/null || true)"
  [[ -n "${root_real}" && -n "${file_real}" ]] || return 1
  [[ "${file_real}" == "${root_real}/"* ]] || return 1

  if [[ "$(id -u)" -ne 0 ]]; then
    return 0
  fi

  [[ -L "${file}" ]] && return 1

  local owner mode
  owner="$(stat -c '%u' "${file_real}" 2>/dev/null || echo 1)"
  mode="$(stat -c '%A' "${file_real}" 2>/dev/null || echo '----------')"
  [[ "${owner}" == "0" ]] || return 1
  [[ "${mode:5:1}" != "w" && "${mode:8:1}" != "w" ]] || return 1
  return 0
}

source_setup_module() {
  local rel="$1"
  local file="${SCRIPT_DIR}/${rel}"
  setup_module_file_trusted "${file}" \
    || setup_bootstrap_die "Module setup tidak trusted/tidak valid: ${file}. Pastikan owner root dan tidak writable oleh group/other."
  # shellcheck disable=SC1090
  . "${file}"
}

# shellcheck source=opt/setup/core/env.sh
source_setup_module "opt/setup/core/env.sh"

CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-ZEbavEuJawHqX4-Jwj-L5Vj0nHOD-uPXtdxsMiAZ}"
# Daftar domain induk yang disediakan (private)
PROVIDED_ROOT_DOMAINS=(
"vyxara1.web.id"
"vyxara2.web.id"
)

# Overrides for specific script logic that needs SCRIPT_DIR
SETUP_BIN_SRC_DIR="${SCRIPT_DIR}/opt/setup/bin"
SETUP_TEMPLATE_SRC_DIR="${SCRIPT_DIR}/opt/setup/templates"
MANAGE_MODULES_SRC_DIR="${SCRIPT_DIR}/opt/manage"

# shellcheck source=opt/setup/core/logging.sh
source_setup_module "opt/setup/core/logging.sh"
# shellcheck source=opt/setup/core/helpers.sh
source_setup_module "opt/setup/core/helpers.sh"
# shellcheck source=opt/setup/install/bootstrap.sh
source_setup_module "opt/setup/install/bootstrap.sh"
# shellcheck source=opt/setup/install/domain.sh
source_setup_module "opt/setup/install/domain.sh"
# shellcheck source=opt/setup/install/nginx.sh
source_setup_module "opt/setup/install/nginx.sh"
# shellcheck source=opt/setup/install/edge.sh
source_setup_module "opt/setup/install/edge.sh"
load_persisted_edge_runtime_env
# Precedence: env eksplisit > env runtime tersimpan > default first install.
EDGE_PROVIDER="${EDGE_PROVIDER:-go}"
EDGE_ACTIVATE_RUNTIME="${EDGE_ACTIVATE_RUNTIME:-true}"
# shellcheck source=opt/setup/install/badvpn.sh
source_setup_module "opt/setup/install/badvpn.sh"
# shellcheck source=opt/setup/install/network.sh
source_setup_module "opt/setup/install/network.sh"
# shellcheck source=opt/setup/install/xray.sh
source_setup_module "opt/setup/install/xray.sh"
# shellcheck source=opt/setup/install/management.sh
source_setup_module "opt/setup/install/management.sh"
# shellcheck source=opt/setup/install/sshws.sh
source_setup_module "opt/setup/install/sshws.sh"
# shellcheck source=opt/setup/install/openvpn.sh
source_setup_module "opt/setup/install/openvpn.sh"
# shellcheck source=opt/setup/install/zivpn.sh
source_setup_module "opt/setup/install/zivpn.sh"
# shellcheck source=opt/setup/install/adblock.sh
source_setup_module "opt/setup/install/adblock.sh"
# shellcheck source=opt/setup/install/domain_guard.sh
source_setup_module "opt/setup/install/domain_guard.sh"
# shellcheck source=opt/setup/install/sanity.sh
source_setup_module "opt/setup/install/sanity.sh"

trap run_exit_cleanups EXIT

SETUP_PROGRESS_FILE=""

setup_set_progress() {
  local label="$1"
  [[ -n "${SETUP_PROGRESS_FILE:-}" ]] || return 0
  printf '%s\n' "${label}" > "${SETUP_PROGRESS_FILE}"
}

setup_run_step() {
  local label="$1"
  shift || true
  setup_set_progress "${label}"
  "$@"
}

setup_post_domain_main() {
  setup_run_step "Validasi Python" need_python3
  setup_run_step "Install dependency tambahan" install_extra_deps
  # Re-validasi setelah dependency terpasang: jika stunnel tersedia, conflict port stunnel juga wajib lolos.
  setup_run_step "Validasi port SSH WS" validate_sshws_ports_config
  setup_run_step "Install speedtest" install_speedtest_snap
  setup_run_step "Aktifkan cron" enable_cron_service
  setup_run_step "Aktifkan chrony" setup_time_sync_chrony
  setup_run_step "Install fail2ban" install_fail2ban_aggressive
  setup_run_step "Aktifkan BBR" enable_bbr
  setup_run_step "Siapkan swap" setup_swap_2gb
  setup_run_step "Atur ulimit" tune_ulimit
  setup_run_step "Install wgcf" install_wgcf
  setup_run_step "Install wireproxy" install_wireproxy
  setup_run_step "Install Cloudflare WARP" install_cloudflare_warp
  setup_run_step "Siapkan wgcf" setup_wgcf
  setup_run_step "Siapkan wireproxy" setup_wireproxy
  setup_run_step "Siapkan backend Zero Trust" setup_warp_zero_trust_backend
  setup_run_step "Siapkan SSH WARP" setup_ssh_warp_interface
  setup_run_step "Bersihkan file wgcf" cleanup_wgcf_files
  setup_run_step "Install repo nginx" install_nginx_official_repo
  setup_run_step "Tulis config utama nginx" write_nginx_main_conf
  setup_run_step "Issue sertifikat" install_acme_and_issue_cert
  setup_run_step "Install Xray" install_xray
  setup_run_step "Siapkan updater geodata" setup_xray_geodata_updater
  setup_run_step "Preflight Edge Gateway" edge_runtime_preflight_or_die
  setup_run_step "Tulis config Xray" write_xray_config
  setup_run_step "Tulis config modular Xray" write_xray_modular_configs
  setup_run_step "Konfigurasi service Xray" configure_xray_service_confdir
  setup_run_step "Tulis config nginx" write_nginx_config
  setup_run_step "Install Edge Gateway" install_edge_provider_stack
  setup_set_progress "Sinkron domain Xray"
  if sync_xray_domain_file "${DOMAIN}"; then
    ok "Compat domain file tersimpan: ${XRAY_DOMAIN_FILE}"
  else
    warn "Gagal menulis compat domain file: ${XRAY_DOMAIN_FILE}"
  fi
  setup_run_step "Install SSH WS" install_sshws_stack
  setup_run_step "Install SSH QAC enforcer" install_sshws_qac_enforcer
  setup_run_step "Install SSH expired cleaner" install_ssh_expired_cleaner
  setup_run_step "Install OpenVPN" install_openvpn_stack
  setup_run_step "Install ZIVPN UDP" install_zivpn_stack
  setup_run_step "Install SSH Adblock" install_ssh_dns_adblock_foundation
  setup_run_step "Install BadVPN UDPGW" install_badvpn_udpgw_stack
  setup_run_step "Install management scripts" install_management_scripts
  setup_run_step "Refresh ACCOUNT INFO" refresh_account_info_runtime
  setup_run_step "Sinkron runtime setup" sync_setup_runtime_layout
  setup_run_step "Install Xray speed limiter" install_xray_speed_limiter_foundation
  setup_run_step "Install domain guard" install_domain_cert_guard
  setup_run_step "Konfigurasi logrotate" setup_logrotate
  setup_run_step "Konfigurasi jail fail2ban" configure_fail2ban_aggressive_jails
  setup_run_step "Sanity check" sanity_check
  if [[ "${SETUP_SKIP_MANAGE_SYNC:-0}" != "1" ]]; then
    setup_run_step "Sinkron modul manage" sync_manage_modules_layout
  fi
}

setup_run_post_domain_with_spinner() {
  local setup_log_dir setup_log_file setup_status_file setup_pid rc
  setup_log_dir="/var/log/autoscript"
  mkdir -p "${setup_log_dir}"
  chmod 755 "${setup_log_dir}" 2>/dev/null || true
  setup_log_file="${setup_log_dir}/setup-$(date +%Y%m%d-%H%M%S).log"
  setup_status_file="${setup_log_dir}/setup-status-$(date +%Y%m%d-%H%M%S).txt"

  echo
  ui_hr
  ui_section_title "Menyiapkan Server"
  ui_hr
  ui_subtle "Domain     : ${DOMAIN}"
  ui_subtle "Transport  : Edge Gateway + Xray + SSH"
  ui_subtle "Output log : ${setup_log_file}"
  ui_hr
  ui_section_title "Proses setup berjalan di latar belakang."
  ui_subtle "Tunggu sampai spinner selesai. Jika gagal, potongan log terakhir akan ditampilkan."
  echo

  (
    SETUP_PROGRESS_FILE="${setup_status_file}"
    setup_post_domain_main
  ) >"${setup_log_file}" 2>&1 &
  setup_pid=$!

  set +e
  ui_spinner_wait "${setup_pid}" "Menyiapkan layanan inti" "${setup_status_file}"
  rc=$?
  set -e
  if (( rc == 0 )); then
    rm -f "${setup_status_file}" >/dev/null 2>&1 || true
    ok "Setup selesai."
    ui_subtle "Log setup tersimpan di ${setup_log_file}"
    return 0
  fi

  rm -f "${setup_status_file}" >/dev/null 2>&1 || true
  warn "Setup gagal. Potongan log terakhir:"
  ui_hr
  tail -n 60 "${setup_log_file}" 2>/dev/null || true
  ui_hr
  die "Setup berhenti. Periksa log lengkap: ${setup_log_file} (exit ${rc})"
}

main() {
  safe_clear
  need_root
  ensure_runtime_lock_dirs
  ensure_stdin_available
  validate_sshws_ports_config
  check_os
  install_base_deps
  domain_menu_v2
  setup_run_post_domain_with_spinner
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
