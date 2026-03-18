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

XRAY_CONFIG="/usr/local/etc/xray/config.json"
XRAY_CONFDIR="/usr/local/etc/xray/conf.d"
XRAY_DOMAIN_FILE="/etc/xray/domain"
NGINX_CONF="/etc/nginx/conf.d/xray.conf"
CERT_DIR="/opt/cert"
CERT_FULLCHAIN="${CERT_DIR}/fullchain.pem"
CERT_PRIVKEY="${CERT_DIR}/privkey.pem"
WIREPROXY_CONF="/etc/wireproxy/config.conf"
WIREGUARD_DIR="${WIREGUARD_DIR:-/etc/wireguard}"
SSH_WARP_SYNC_BIN="${SSH_WARP_SYNC_BIN:-/usr/local/bin/ssh-warp-sync}"
SSH_NETWORK_WARP_INTERFACE="${SSH_NETWORK_WARP_INTERFACE:-warp-ssh0}"
SSHWS_DROPBEAR_PORT="${SSHWS_DROPBEAR_PORT:-22022}"
SSHWS_STUNNEL_PORT="${SSHWS_STUNNEL_PORT:-22443}"
SSHWS_PROXY_PORT="${SSHWS_PROXY_PORT:-10015}"
NGINX_SIGNING_KEY_FPRS="${NGINX_SIGNING_KEY_FPRS:-8540A6F18833A80E9C1653A42FD21310B49F6B46 573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62 9E9BE90EACBCDE69FE9B204CBCDCD8A38D88A2B3}"
# Backward compatibility: jika user hanya set 1 fingerprint via env sebelumnya.
NGINX_SIGNING_KEY_FPR="${NGINX_SIGNING_KEY_FPR:-}"
SPEED_POLICY_ROOT="/opt/speed"
SPEED_STATE_DIR="/var/lib/xray-speed"
SPEED_CONFIG_DIR="/etc/xray-speed"
SPEED_PROTO_DIRS=("vless" "vmess" "trojan")
DOMAIN_GUARD_CONFIG_DIR="/etc/xray-domain-guard"
DOMAIN_GUARD_CONFIG_FILE="${DOMAIN_GUARD_CONFIG_DIR}/config.env"
DOMAIN_GUARD_LOG_DIR="/var/log/xray-domain-guard"
AUTOSCRIPT_ENV_DIR="${AUTOSCRIPT_ENV_DIR:-/etc/autoscript}"
CLOUDFLARE_API_TOKEN_FILE="${CLOUDFLARE_API_TOKEN_FILE:-${AUTOSCRIPT_ENV_DIR}/cloudflare.env}"
CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-}"
# Daftar domain induk yang disediakan (private)
PROVIDED_ROOT_DOMAINS=(
"vyxara1.web.id"
"vyxara2.web.id"
)

# NOTE: Token Cloudflare dibaca dari env runtime, /etc/autoscript/cloudflare.env,
# atau file cloudflare.env di dalam direktori autoscript.
# ACME_CERT_MODE:
# - standalone: issue cert for DOMAIN via standalone (port 80)
# - dns_cf_wildcard: issue wildcard cert for ACME_ROOT_DOMAIN via dns_cf
ACME_CERT_MODE="standalone"
ACME_ROOT_DOMAIN=""
CF_ZONE_ID=""
CF_ACCOUNT_ID=""
VPS_IPV4=""
CF_PROXIED="false"
XRAY_INSTALL_REF="${XRAY_INSTALL_REF:-e741a4f56d368afbb9e5be3361b40c4552d3710d}"
ACME_SH_INSTALL_REF="${ACME_SH_INSTALL_REF:-f39d066ced0271d87790dc426556c1e02a88c91b}"
ACME_DEFAULT_CA="${ACME_DEFAULT_CA:-letsencrypt}"
XRAY_INSTALL_SCRIPT_URL="https://raw.githubusercontent.com/XTLS/Xray-install/${XRAY_INSTALL_REF}/install-release.sh"
ACME_SH_TARBALL_URL="https://codeload.github.com/acmesh-official/acme.sh/tar.gz/${ACME_SH_INSTALL_REF}"
ACME_SH_DNS_CF_HOOK_URL="https://raw.githubusercontent.com/acmesh-official/acme.sh/${ACME_SH_INSTALL_REF}/dnsapi/dns_cf.sh"
XRAY_ASSET_DIR="/usr/local/share/xray"
CUSTOM_GEOSITE_DEST="${XRAY_ASSET_DIR}/custom.dat"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SETUP_BIN_SRC_DIR="${SCRIPT_DIR}/opt/setup/bin"
SETUP_TEMPLATE_SRC_DIR="${SCRIPT_DIR}/opt/setup/templates"
MANAGE_MODULES_SRC_DIR="${SCRIPT_DIR}/opt/manage"
MANAGE_MODULES_DST_DIR="/opt/manage"
MANAGE_BUNDLE_URL="${MANAGE_BUNDLE_URL:-https://raw.githubusercontent.com/superdecrypt-dev/autoscript/main/manage_bundle.zip}"
MANAGE_BIN="${MANAGE_BIN:-/usr/local/bin/manage}"
MANAGE_FALLBACK_MODULES_DST_DIR="${MANAGE_FALLBACK_MODULES_DST_DIR:-/usr/local/lib/autoscript-manage/opt/manage}"
SETUP_MODULES_ROOT="${SCRIPT_DIR}/opt/setup"
SETUP_FALLBACK_ROOT="${SETUP_FALLBACK_ROOT:-/usr/local/lib/autoscript-setup}"
SETUP_FALLBACK_SCRIPT="${SETUP_FALLBACK_SCRIPT:-${SETUP_FALLBACK_ROOT}/setup.sh}"
SETUP_FALLBACK_MODULES_ROOT="${SETUP_FALLBACK_MODULES_ROOT:-${SETUP_FALLBACK_ROOT}/opt/setup}"

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
# shellcheck source=opt/setup/install/zivpn.sh
source_setup_module "opt/setup/install/zivpn.sh"
# shellcheck source=opt/setup/install/adblock.sh
source_setup_module "opt/setup/install/adblock.sh"
# shellcheck source=opt/setup/install/domain_guard.sh
source_setup_module "opt/setup/install/domain_guard.sh"

cloudflare_token_read_from_path() {
  local path="$1"
  [[ -r "${path}" ]] || return 1
  awk -F= '
    $1 == "CLOUDFLARE_API_TOKEN" {
      print substr($0, index($0, "=") + 1)
      exit
    }
  ' "${path}" 2>/dev/null || true
}

cloudflare_token_internal_file() {
  printf '%s\n' "${SCRIPT_DIR}/cloudflare.env"
}

cloudflare_token_write_file() {
  local path="$1"
  local token="$2"
  local dir="" tmp=""
  [[ -n "${path}" && -n "${token}" ]] || return 1
  dir="$(dirname "${path}")"
  install -d -m 700 "${dir}" || return 1
  tmp="$(mktemp "${dir}/.cloudflare.env.XXXXXX")" || return 1
  if ! printf 'CLOUDFLARE_API_TOKEN=%s\n' "${token}" > "${tmp}"; then
    rm -f -- "${tmp}" >/dev/null 2>&1 || true
    return 1
  fi
  chmod 600 "${tmp}" >/dev/null 2>&1 || true
  if ! install -m 600 "${tmp}" "${path}"; then
    rm -f -- "${tmp}" >/dev/null 2>&1 || true
    return 1
  fi
  rm -f -- "${tmp}" >/dev/null 2>&1 || true
}

cloudflare_token_load_from_file() {
  local candidate="" token=""
  [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]] && return 0
  for candidate in "${CLOUDFLARE_API_TOKEN_FILE}" "$(cloudflare_token_internal_file)"; do
    token="$(cloudflare_token_read_from_path "${candidate}")"
    [[ -n "${token}" ]] || continue
    CLOUDFLARE_API_TOKEN="${token}"
    return 0
  done
  return 0
}

cloudflare_token_persist_if_available() {
  local token="${CLOUDFLARE_API_TOKEN:-}"
  local existing=""
  local internal_file=""
  [[ -n "${token}" ]] || return 0
  existing="$(cloudflare_token_read_from_path "${CLOUDFLARE_API_TOKEN_FILE}")"
  if [[ "${existing}" != "${token}" ]]; then
    cloudflare_token_write_file "${CLOUDFLARE_API_TOKEN_FILE}" "${token}" \
      || die "Gagal menyimpan secret Cloudflare ke ${CLOUDFLARE_API_TOKEN_FILE}."
  fi

  internal_file="$(cloudflare_token_internal_file)"
  existing="$(cloudflare_token_read_from_path "${internal_file}")"
  if [[ "${existing}" != "${token}" ]]; then
    cloudflare_token_write_file "${internal_file}" "${token}" \
      || die "Gagal menyimpan secret Cloudflare ke ${internal_file}."
  fi
}

trap run_exit_cleanups EXIT
sanity_check() {
  local failed=0
  local edge_provider edge_active edge_runtime_service
  edge_provider="${EDGE_PROVIDER:-none}"
  edge_active="${EDGE_ACTIVATE_RUNTIME:-false}"

  listener_present_tcp() {
    local pattern="$1"
    ss -lntp 2>/dev/null | grep -Eq "${pattern}"
  }

  listener_present_badvpn() {
    local port="$1"
    local pattern="(^|[[:space:]])127\\.0\\.0\\.1:${port}([[:space:]]|$)"
    ss -lntp 2>/dev/null | grep -Eq "${pattern}" || ss -lunp 2>/dev/null | grep -Eq "${pattern}"
  }

  wait_for_listener() {
    local checker="$1"
    local target="$2"
    local tries="${3:-5}"
    local delay="${4:-1}"
    local i
    for ((i = 0; i < tries; i++)); do
      if "${checker}" "${target}"; then
        return 0
      fi
      sleep "${delay}"
    done
    return 1
  }

  # Core services (must be active)
  if systemctl is-active --quiet xray; then
    ok "check: xray active"
  else
    warn "check: xray inactive"
    systemctl status xray --no-pager >&2 || true
    journalctl -u xray -n 200 --no-pager >&2 || true
    failed=1
  fi

  if systemctl is-active --quiet nginx; then
    ok "check: nginx active"
  else
    warn "check: nginx inactive"
    systemctl status nginx --no-pager >&2 || true
    journalctl -u nginx -n 200 --no-pager >&2 || true
    failed=1
  fi

  if systemctl is-active --quiet wireproxy; then
    ok "check: wireproxy active"
  else
    warn "check: wireproxy inactive"
    systemctl status wireproxy --no-pager >&2 || true
    journalctl -u wireproxy -n 120 --no-pager >&2 || true
    failed=1
  fi

  if systemctl is-active --quiet sshws-dropbear; then
    ok "check: sshws-dropbear active"
  else
    warn "check: sshws-dropbear inactive"
    systemctl status sshws-dropbear --no-pager >&2 || true
    journalctl -u sshws-dropbear -n 120 --no-pager >&2 || true
    failed=1
  fi

  if systemctl is-active --quiet sshws-stunnel; then
    ok "check: sshws-stunnel active"
  else
    warn "check: sshws-stunnel inactive"
    systemctl status sshws-stunnel --no-pager >&2 || true
    journalctl -u sshws-stunnel -n 120 --no-pager >&2 || true
    warn "check: sshws-stunnel opsional"
  fi

  if systemctl is-active --quiet sshws-proxy; then
    ok "check: sshws-proxy active"
  else
    warn "check: sshws-proxy inactive"
    systemctl status sshws-proxy --no-pager >&2 || true
    journalctl -u sshws-proxy -n 120 --no-pager >&2 || true
    failed=1
  fi

  if systemctl is-active --quiet sshws-qac-enforcer.timer; then
    ok "check: ssh qac timer active"
  else
    warn "check: ssh qac timer inactive"
    systemctl status sshws-qac-enforcer.timer --no-pager >&2 || true
    failed=1
  fi

  if systemctl is-active --quiet zivpn.service; then
    ok "check: zivpn active"
  else
    warn "check: zivpn inactive"
    systemctl status zivpn.service --no-pager >&2 || true
    journalctl -u zivpn.service -n 120 --no-pager >&2 || true
    failed=1
  fi

  if systemctl is-active --quiet "${SSH_DNS_ADBLOCK_SERVICE}"; then
    ok "check: ssh adblock active"
  else
    warn "check: ssh adblock inactive"
    systemctl status "${SSH_DNS_ADBLOCK_SERVICE}" --no-pager >&2 || true
    journalctl -u "${SSH_DNS_ADBLOCK_SERVICE}" -n 120 --no-pager >&2 || true
    failed=1
  fi

  if systemctl is-active --quiet xray-domain-guard.timer; then
    ok "check: domain guard timer active"
  else
    warn "check: domain guard timer inactive"
    systemctl status xray-domain-guard.timer --no-pager >&2 || true
    journalctl -u xray-domain-guard.timer -n 120 --no-pager >&2 || true
    failed=1
  fi

  if badvpn_runtime_expected 2>/dev/null; then
    if systemctl is-active --quiet badvpn-udpgw.service; then
      ok "check: badvpn-udpgw active"
    else
      warn "check: badvpn-udpgw inactive"
      systemctl status badvpn-udpgw.service --no-pager >&2 || true
      journalctl -u badvpn-udpgw.service -n 120 --no-pager >&2 || true
      failed=1
    fi
  else
    warn "check: badvpn-udpgw optional (prebuilt tidak tersedia)"
  fi

  if [[ "${edge_provider}" != "none" ]]; then
    case "${edge_provider}" in
      nginx-stream) edge_runtime_service="nginx" ;;
      *) edge_runtime_service="edge-mux.service" ;;
    esac
    case "${edge_active}" in
      1|true|TRUE|yes|YES|on|ON)
        if systemctl is-active --quiet "${edge_runtime_service}"; then
          ok "check: ${edge_runtime_service} active"
        else
          warn "check: ${edge_runtime_service} inactive"
          systemctl status "${edge_runtime_service}" --no-pager >&2 || true
          journalctl -u "${edge_runtime_service}" -n 120 --no-pager >&2 || true
          failed=1
        fi
        ;;
    esac
  fi

  # Config sanity (non-fatal if tools missing)
  if command -v nginx >/dev/null 2>&1; then
    if nginx -t >/dev/null 2>&1; then
      ok "check: nginx -t OK"
    else
      warn "check: nginx -t failed"
      nginx -t >&2 || true
      failed=1
    fi
  fi

  if command -v jq >/dev/null 2>&1 && [[ -f "${XRAY_CONFDIR}/10-inbounds.json" ]]; then
    if jq -e . "${XRAY_CONFDIR}/10-inbounds.json" >/dev/null 2>&1; then
      ok "check: xray config OK"
    else
      warn "check: xray config invalid"
      jq -e . "${XRAY_CONFDIR}/10-inbounds.json" >&2 || true
      failed=1
    fi
  fi

  # Cert presence (TLS termination depends on these)
  if [[ -s "/opt/cert/fullchain.pem" && -s "/opt/cert/privkey.pem" ]]; then
    ok "check: cert files present"
  else
    warn "check: cert files missing"
    failed=1
  fi

  # Listener hints (informational only)
  # Match exact port agar tidak false-positive ke :4430 dst.
  if wait_for_listener listener_present_tcp '(^|[[:space:]])[^[:space:]]*:80([[:space:]]|$)' 5 1; then
    ok "check: port 80 listening"
  else
    warn "check: port 80 not listening"
  fi

  if wait_for_listener listener_present_tcp '(^|[[:space:]])[^[:space:]]*:443([[:space:]]|$)' 5 1; then
    ok "check: port 443 listening"
  else
    warn "check: port 443 not listening"
  fi

  if badvpn_runtime_expected 2>/dev/null; then
    local badvpn_ports badvpn_ports_label badvpn_missing="" port
    badvpn_ports="$(awk -F= '
      $1 == "BADVPN_UDPGW_PORTS" {
        gsub(/"/, "", $2)
        gsub(/,/, " ", $2)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
        print $2
        exit
      }
    ' /etc/default/badvpn-udpgw 2>/dev/null)"
    [[ -n "${badvpn_ports}" ]] || badvpn_ports="7300 7400 7500 7600 7700 7800 7900"
    badvpn_ports_label="$(printf '%s\n' "${badvpn_ports}" | sed 's/ /, /g')"
    for port in ${badvpn_ports}; do
      if ! wait_for_listener listener_present_badvpn "${port}" 5 1; then
        badvpn_missing="${badvpn_missing}${badvpn_missing:+, }${port}"
      fi
    done
    if [[ -z "${badvpn_missing}" ]]; then
      ok "check: badvpn ${badvpn_ports_label} listening"
    else
      warn "check: badvpn ${badvpn_ports_label} missing ${badvpn_missing}"
      failed=1
    fi
  else
    warn "check: badvpn 7300, 7400, 7500, 7600, 7700, 7800, 7900 optional (prebuilt tidak tersedia)"
  fi

  if [[ "$failed" -ne 0 ]]; then
    die "Sanity check gagal. Lihat log di atas."
  fi
}

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
  setup_run_step "Siapkan wgcf" setup_wgcf
  setup_run_step "Siapkan wireproxy" setup_wireproxy
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
  cloudflare_token_load_from_file
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
