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
# VLESS/VMess/Trojan/Shadowsocks/Shadowsocks 2022 over WS/HTTPUpgrade/gRPC
# Public paths fixed, internal ports & paths randomized
# Cert saved to /opt/cert/fullchain.pem & /opt/cert/privkey.pem
# Supports: Ubuntu >= 20.04, Debian >= 11, KVM only
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
SSHWS_DROPBEAR_PORT="${SSHWS_DROPBEAR_PORT:-22022}"
SSHWS_STUNNEL_PORT="${SSHWS_STUNNEL_PORT:-22443}"
SSHWS_PROXY_PORT="${SSHWS_PROXY_PORT:-10015}"
NGINX_SIGNING_KEY_FPRS="${NGINX_SIGNING_KEY_FPRS:-8540A6F18833A80E9C1653A42FD21310B49F6B46 573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62 9E9BE90EACBCDE69FE9B204CBCDCD8A38D88A2B3}"
# Backward compatibility: jika user hanya set 1 fingerprint via env sebelumnya.
NGINX_SIGNING_KEY_FPR="${NGINX_SIGNING_KEY_FPR:-}"
SPEED_POLICY_ROOT="/opt/speed"
SPEED_STATE_DIR="/var/lib/xray-speed"
SPEED_CONFIG_DIR="/etc/xray-speed"
SPEED_PROTO_DIRS=("vless" "vmess" "trojan" "shadowsocks" "shadowsocks2022")
OBS_CONFIG_DIR="/etc/xray-observe"
OBS_CONFIG_FILE="${OBS_CONFIG_DIR}/config.env"
OBS_STATE_DIR="/var/lib/xray-observe"
OBS_LOG_DIR="/var/log/xray-observe"
DOMAIN_GUARD_CONFIG_DIR="/etc/xray-domain-guard"
DOMAIN_GUARD_CONFIG_FILE="${DOMAIN_GUARD_CONFIG_DIR}/config.env"
CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-ZEbavEuJawHqX4-Jwj-L5Vj0nHOD-uPXtdxsMiAZ}"
# Daftar domain induk yang disediakan (private)
PROVIDED_ROOT_DOMAINS=(
"vyxara1.web.id"
"vyxara2.web.id"
)

# NOTE: Script ini dipakai pribadi. Isi token di atas jika tidak memakai env var.
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
XRAY_INSTALL_SCRIPT_SHA256="${XRAY_INSTALL_SCRIPT_SHA256:-7f70c95f6b418da8b4f4883343d602964915e28748993870fd554383afdbe555}"
ACME_SH_TARBALL_SHA256="${ACME_SH_TARBALL_SHA256:-3be27ab630d5dd53439a46e56cbe77d998b788c3f0a3eb6b95cdd77e074389a9}"
ACME_SH_DNS_CF_HOOK_SHA256="${ACME_SH_DNS_CF_HOOK_SHA256:-9628ee8238cb3f9cfa1b1a985c0e9593436a3e4f8a9d65a6f775b981be9e76c8}"
CUSTOM_GEOSITE_URL="${CUSTOM_GEOSITE_URL:-https://github.com/superdecrypt-dev/custom-geosite-xray/raw/main/custom.dat}"
CUSTOM_GEOSITE_SHA256="${CUSTOM_GEOSITE_SHA256:-}"
XRAY_ASSET_DIR="/usr/local/share/xray"
CUSTOM_GEOSITE_DEST="${XRAY_ASSET_DIR}/custom.dat"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SETUP_BIN_SRC_DIR="${SCRIPT_DIR}/opt/setup/bin"
SETUP_TEMPLATE_SRC_DIR="${SCRIPT_DIR}/opt/setup/templates"
MANAGE_MODULES_SRC_DIR="${SCRIPT_DIR}/opt/manage"
MANAGE_MODULES_DST_DIR="/opt/manage"
MANAGE_BUNDLE_URL="${MANAGE_BUNDLE_URL:-https://raw.githubusercontent.com/superdecrypt-dev/autoscript/main/manage_bundle.zip}"
MANAGE_BUNDLE_LOCAL_SHA256=""
if [[ -z "${MANAGE_BUNDLE_SHA256:-}" ]] && [[ -f "${SCRIPT_DIR}/manage_bundle.zip" ]] && command -v sha256sum >/dev/null 2>&1; then
  MANAGE_BUNDLE_LOCAL_SHA256="$(sha256sum "${SCRIPT_DIR}/manage_bundle.zip" | awk '{print tolower($1)}')"
fi
MANAGE_BUNDLE_SHA256="${MANAGE_BUNDLE_SHA256:-${MANAGE_BUNDLE_LOCAL_SHA256}}"
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
# shellcheck source=opt/setup/install/network.sh
source_setup_module "opt/setup/install/network.sh"
# shellcheck source=opt/setup/install/xray.sh
source_setup_module "opt/setup/install/xray.sh"
# shellcheck source=opt/setup/install/management.sh
source_setup_module "opt/setup/install/management.sh"
# shellcheck source=opt/setup/install/sshws.sh
source_setup_module "opt/setup/install/sshws.sh"
# shellcheck source=opt/setup/install/observability.sh
source_setup_module "opt/setup/install/observability.sh"

trap run_exit_cleanups EXIT
sanity_check() {
  local failed=0
  local edge_provider edge_active edge_runtime_service
  edge_provider="${EDGE_PROVIDER:-none}"
  edge_active="${EDGE_ACTIVATE_RUNTIME:-false}"

  # Core services (must be active)
  if systemctl is-active --quiet xray; then
    ok "sanity: xray active"
  else
    warn "sanity: xray NOT active"
    systemctl status xray --no-pager >&2 || true
    journalctl -u xray -n 200 --no-pager >&2 || true
    failed=1
  fi

  if systemctl is-active --quiet nginx; then
    ok "sanity: nginx active"
  else
    warn "sanity: nginx NOT active"
    systemctl status nginx --no-pager >&2 || true
    journalctl -u nginx -n 200 --no-pager >&2 || true
    failed=1
  fi

  if systemctl is-active --quiet sshws-dropbear; then
    ok "sanity: sshws-dropbear active"
  else
    warn "sanity: sshws-dropbear NOT active"
    systemctl status sshws-dropbear --no-pager >&2 || true
    journalctl -u sshws-dropbear -n 120 --no-pager >&2 || true
    failed=1
  fi

  if systemctl is-active --quiet sshws-stunnel; then
    ok "sanity: sshws-stunnel active"
  else
    warn "sanity: sshws-stunnel NOT active"
    systemctl status sshws-stunnel --no-pager >&2 || true
    journalctl -u sshws-stunnel -n 120 --no-pager >&2 || true
    warn "sanity: sshws-stunnel bersifat opsional (jalur utama SSHWS tetap via proxy -> dropbear direct)."
  fi

  if systemctl is-active --quiet sshws-proxy; then
    ok "sanity: sshws-proxy active"
  else
    warn "sanity: sshws-proxy NOT active"
    systemctl status sshws-proxy --no-pager >&2 || true
    journalctl -u sshws-proxy -n 120 --no-pager >&2 || true
    failed=1
  fi

  if systemctl is-active --quiet sshws-qac-enforcer.timer; then
    ok "sanity: sshws-qac-enforcer.timer active"
  else
    warn "sanity: sshws-qac-enforcer.timer NOT active"
    systemctl status sshws-qac-enforcer.timer --no-pager >&2 || true
    failed=1
  fi

  if [[ "${edge_provider}" != "none" ]]; then
    case "${edge_provider}" in
      nginx-stream) edge_runtime_service="nginx" ;;
      *) edge_runtime_service="edge-mux.service" ;;
    esac
    case "${edge_active}" in
      1|true|TRUE|yes|YES|on|ON)
        if systemctl is-active --quiet "${edge_runtime_service}"; then
          ok "sanity: ${edge_runtime_service} active"
        else
          warn "sanity: ${edge_runtime_service} NOT active"
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
      ok "sanity: nginx -t OK"
    else
      warn "sanity: nginx -t FAILED"
      nginx -t >&2 || true
      failed=1
    fi
  fi

  if command -v jq >/dev/null 2>&1 && [[ -f "${XRAY_CONFDIR}/10-inbounds.json" ]]; then
    if jq -e . "${XRAY_CONFDIR}/10-inbounds.json" >/dev/null 2>&1; then
      ok "sanity: xray config JSON OK"
    else
      warn "sanity: xray config JSON INVALID"
      jq -e . "${XRAY_CONFDIR}/10-inbounds.json" >&2 || true
      failed=1
    fi
  fi

  # Cert presence (TLS termination depends on these)
  if [[ -s "/opt/cert/fullchain.pem" && -s "/opt/cert/privkey.pem" ]]; then
    ok "sanity: TLS cert files present"
  else
    warn "sanity: TLS cert files missing under /opt/cert"
    failed=1
  fi

  # Listener hints (informational only)
  # Match exact port agar tidak false-positive ke :4430 dst.
  if ss -lntp 2>/dev/null | grep -Eq '(^|[[:space:]])[^[:space:]]*:80([[:space:]]|$)'; then
    ok "sanity: port 80 is listening"
  else
    warn "sanity: port 80 not detected as listening (check nginx)"
  fi

  if ss -lntp 2>/dev/null | grep -Eq '(^|[[:space:]])[^[:space:]]*:443([[:space:]]|$)'; then
    ok "sanity: port 443 is listening"
  else
    warn "sanity: port 443 not detected as listening (check nginx)"
  fi

  if [[ "$failed" -ne 0 ]]; then
    die "Sanity check gagal. Lihat log di atas."
  fi
}

main() {
  safe_clear
  need_root
  ensure_runtime_lock_dirs
  ensure_stdin_available
  validate_sshws_ports_config
  check_os
  install_base_deps
  need_python3
  install_extra_deps
  # Re-validasi setelah dependency terpasang: jika stunnel tersedia, conflict port stunnel juga wajib lolos.
  validate_sshws_ports_config
  install_speedtest_snap
  enable_cron_service
  setup_time_sync_chrony
  install_fail2ban_aggressive
  enable_bbr
  setup_swap_2gb
  tune_ulimit
  install_wgcf
  install_wireproxy
  setup_wgcf
  setup_wireproxy
  cleanup_wgcf_files
  domain_menu_v2
  install_nginx_official_repo
  write_nginx_main_conf
  install_acme_and_issue_cert
  install_xray
  setup_xray_geodata_updater
  install_custom_geosite_adblock
  edge_runtime_preflight_or_die
  write_xray_config
  write_xray_modular_configs
  configure_xray_service_confdir
  write_nginx_config
  install_edge_provider_stack
  if sync_xray_domain_file "${DOMAIN}"; then
    ok "Compat domain file tersimpan: ${XRAY_DOMAIN_FILE}"
  else
    warn "Gagal menulis compat domain file: ${XRAY_DOMAIN_FILE}"
  fi
  install_sshws_stack
  install_sshws_qac_enforcer
  install_management_scripts
  sync_manage_modules_layout
  sync_setup_runtime_layout
  install_xray_speed_limiter_foundation
  install_observability_alerting
  install_domain_cert_guard
  setup_logrotate
  configure_fail2ban_aggressive_jails
  sanity_check
  ok "Setup telah selesai ✅"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
