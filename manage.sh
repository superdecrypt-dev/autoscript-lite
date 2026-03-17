#!/usr/bin/env bash
set -euo pipefail

# Harden PATH untuk mencegah PATH hijacking saat script dijalankan sebagai root.
SAFE_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
PATH="${SAFE_PATH}"
export PATH

# ============================================================
# manage.sh - CLI Menu Manajemen (post-setup)
# - Tidak mengubah setup.sh
# - Fokus: operasi harian (status, user, quota, maintenance)
# ============================================================

# -------------------------
# Konstanta (samakan dengan setup.sh)
# -------------------------
XRAY_CONFDIR="/usr/local/etc/xray/conf.d"
XRAY_LOG_CONF="${XRAY_CONFDIR}/00-log.json"
XRAY_API_CONF="${XRAY_CONFDIR}/01-api.json"
XRAY_DNS_CONF="${XRAY_CONFDIR}/02-dns.json"
XRAY_INBOUNDS_CONF="${XRAY_CONFDIR}/10-inbounds.json"
XRAY_OUTBOUNDS_CONF="${XRAY_CONFDIR}/20-outbounds.json"
XRAY_ROUTING_CONF="${XRAY_CONFDIR}/30-routing.json"
XRAY_POLICY_CONF="${XRAY_CONFDIR}/40-policy.json"
XRAY_STATS_CONF="${XRAY_CONFDIR}/50-stats.json"
XRAY_DOMAIN_FILE="/etc/xray/domain"
NGINX_MAIN_CONF="/etc/nginx/nginx.conf"
NGINX_CONF="/etc/nginx/conf.d/xray.conf"
CERT_DIR="/opt/cert"
CERT_FULLCHAIN="${CERT_DIR}/fullchain.pem"
CERT_PRIVKEY="${CERT_DIR}/privkey.pem"
WIREPROXY_CONF="/etc/wireproxy/config.conf"
WGCF_DIR="/etc/wgcf"
XRAY_ASSET_DIR="/usr/local/share/xray"
CUSTOM_GEOSITE_DAT="${XRAY_ASSET_DIR}/custom.dat"
ADBLOCK_GEOSITE_ENTRY="ext:custom.dat:adblock"

# Domain / ACME / Cloudflare (disamakan dengan setup.sh)
CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-ZEbavEuJawHqX4-Jwj-L5Vj0nHOD-uPXtdxsMiAZ}"
PROVIDED_ROOT_DOMAINS=(
"vyxara1.web.id"
"vyxara2.web.id"
)
ACME_SH_INSTALL_REF="${ACME_SH_INSTALL_REF:-f39d066ced0271d87790dc426556c1e02a88c91b}"
ACME_SH_SCRIPT_URL="https://raw.githubusercontent.com/acmesh-official/acme.sh/${ACME_SH_INSTALL_REF}/acme.sh"
ACME_SH_TARBALL_URL="https://codeload.github.com/acmesh-official/acme.sh/tar.gz/${ACME_SH_INSTALL_REF}"
ACME_SH_DNS_CF_HOOK_URL="https://raw.githubusercontent.com/acmesh-official/acme.sh/${ACME_SH_INSTALL_REF}/dnsapi/dns_cf.sh"

# Runtime state untuk Domain Control
DOMAIN=""
ACME_CERT_MODE="standalone"
ACME_ROOT_DOMAIN=""
CF_ZONE_ID=""
CF_ACCOUNT_ID=""
VPS_IPV4=""
CF_PROXIED="false"
declare -ag DOMAIN_CTRL_STOPPED_SERVICES=()
declare -ag DOMAIN_CTRL_STOP_FAILURES=()
declare -ag DOMAIN_CTRL_TLS_RUNTIME_ACTIVE_SERVICES=()
DOMAIN_CTRL_NGINX_WAS_ACTIVE="0"
DOMAIN_CTRL_TXN_ACTIVE="0"
DOMAIN_CTRL_TXN_CERT_SNAPSHOT=""
DOMAIN_CTRL_TXN_NGINX_BACKUP=""
DOMAIN_CTRL_TXN_COMPAT_SNAPSHOT=""
DOMAIN_CTRL_TXN_CF_SNAPSHOT=""
DOMAIN_CTRL_TXN_CF_PREPARED="0"
DOMAIN_CTRL_TXN_DOMAIN=""
DOMAIN_CTRL_TXN_CF_ZONE_ID=""
DOMAIN_CTRL_TXN_CF_IPV4=""

# Account store (read-only source for Menu 2)
ACCOUNT_ROOT="/opt/account"
ACCOUNT_PROTO_DIRS=("vless" "vmess" "trojan")

# Quota metadata store (Menu 2 add/delete)
QUOTA_ROOT="/opt/quota"
QUOTA_PROTO_DIRS=("vless" "vmess" "trojan")

# Speed policy store (fondasi dari setup.sh)
SPEED_POLICY_ROOT="/opt/speed"
SPEED_POLICY_PROTO_DIRS=("vless" "vmess" "trojan")
SPEED_CONFIG_FILE="/etc/xray-speed/config.json"
SPEED_MARK_MIN=1000
SPEED_MARK_MAX=59999
SPEED_OUTBOUND_TAG_PREFIX="speed-mark-"
SPEED_RULE_MARKER_PREFIX="dummy-speed-user-"
SPEED_POLICY_LOCK_FILE="/var/lock/xray-speed-policy.lock"
ACCOUNT_INFO_LOCK_FILE="/run/autoscript/locks/account-info.lock"
DOMAIN_CONTROL_LOCK_FILE="/run/autoscript/locks/xray-domain-control.lock"
USER_DATA_MUTATION_LOCK_FILE="/run/autoscript/locks/user-data-mutation.lock"
XRAY_DOMAIN_GUARD_BIN="/usr/local/bin/xray-domain-guard"
XRAY_DOMAIN_GUARD_CONFIG_FILE="/etc/xray-domain-guard/config.env"
XRAY_DOMAIN_GUARD_LOG_FILE="/var/log/xray-domain-guard/domain-guard.log"

# Direktori kerja untuk operasi aman (atomic write)
WORK_DIR="/var/lib/xray-manage"

# File lock bersama untuk sinkronisasi write ke routing config dengan daemon Python
# (xray-quota, limit-ip, user-block). Semua pihak harus acquire lock ini sebelum
# memodifikasi 30-routing.json untuk menghindari race condition last-write-wins.
ROUTING_LOCK_FILE="/run/autoscript/locks/xray-routing.lock"
DNS_LOCK_FILE="/run/autoscript/locks/xray-dns.lock"
WARP_LOCK_FILE="/run/autoscript/locks/xray-warp.lock"

# Direktori laporan/export
REPORT_DIR="/var/log/xray-manage"
WARP_TIER_STATE_KEY="warp_tier_target"
WARP_PLUS_LICENSE_STATE_KEY="warp_plus_license_key"
SSH_ACCOUNT_DIR="${ACCOUNT_ROOT}/ssh"
SSH_QUOTA_DIR="${QUOTA_ROOT}/ssh"
SSH_USERS_STATE_DIR="${SSH_QUOTA_DIR}"
SSHWS_DROPBEAR_SERVICE="sshws-dropbear"
SSHWS_STUNNEL_SERVICE="sshws-stunnel"
SSHWS_PROXY_SERVICE="sshws-proxy"
SSHWS_QAC_ENFORCER_SERVICE="sshws-qac-enforcer"
SSHWS_QAC_ENFORCER_TIMER="sshws-qac-enforcer.timer"
SSHWS_DROPBEAR_PORT="${SSHWS_DROPBEAR_PORT:-22022}"
SSHWS_STUNNEL_PORT="${SSHWS_STUNNEL_PORT:-22443}"
SSHWS_PROXY_PORT="${SSHWS_PROXY_PORT:-10015}"
ZIVPN_ROOT="${ZIVPN_ROOT:-/etc/zivpn}"
ZIVPN_CONFIG_FILE="${ZIVPN_CONFIG_FILE:-${ZIVPN_ROOT}/config.json}"
ZIVPN_CERT_FILE="${ZIVPN_CERT_FILE:-${ZIVPN_ROOT}/zivpn.crt}"
ZIVPN_KEY_FILE="${ZIVPN_KEY_FILE:-${ZIVPN_ROOT}/zivpn.key}"
ZIVPN_PASSWORDS_DIR="${ZIVPN_PASSWORDS_DIR:-${ZIVPN_ROOT}/passwords.d}"
ZIVPN_SYNC_BIN="${ZIVPN_SYNC_BIN:-/usr/local/bin/zivpn-password-sync}"
ZIVPN_SERVICE="${ZIVPN_SERVICE:-zivpn.service}"
ZIVPN_LISTEN_PORT="${ZIVPN_LISTEN_PORT:-5667}"
ZIVPN_OBFS="${ZIVPN_OBFS:-zivpn}"
SSH_DNS_ADBLOCK_ROOT="${SSH_DNS_ADBLOCK_ROOT:-/etc/autoscript/ssh-adblock}"
SSH_DNS_ADBLOCK_CONFIG_FILE="${SSH_DNS_ADBLOCK_ROOT}/config.env"
SSH_DNS_ADBLOCK_BLOCKLIST_FILE="${SSH_DNS_ADBLOCK_ROOT}/blocked.domains"
SSH_DNS_ADBLOCK_URLS_FILE="${SSH_DNS_ADBLOCK_ROOT}/source.urls"
SSH_DNS_ADBLOCK_RENDERED_FILE="${SSH_DNS_ADBLOCK_ROOT}/blocklist.generated.conf"
SSH_DNS_ADBLOCK_DNSMASQ_CONF="${SSH_DNS_ADBLOCK_ROOT}/dnsmasq.conf"
SSH_DNS_ADBLOCK_SERVICE="${SSH_DNS_ADBLOCK_SERVICE:-ssh-adblock-dns.service}"
SSH_DNS_ADBLOCK_SYNC_SERVICE="${SSH_DNS_ADBLOCK_SYNC_SERVICE:-adblock-sync.service}"
SSH_DNS_ADBLOCK_SYNC_BIN="${SSH_DNS_ADBLOCK_SYNC_BIN:-/usr/local/bin/adblock-sync}"
ADBLOCK_AUTO_UPDATE_SERVICE="${ADBLOCK_AUTO_UPDATE_SERVICE:-adblock-update.service}"
ADBLOCK_AUTO_UPDATE_TIMER="${ADBLOCK_AUTO_UPDATE_TIMER:-adblock-update.timer}"
# Nilai konstanta di atas dipakai lintas modul yang di-source dinamis dari /opt/manage.
# No-op berikut menandai variabel sebagai "used" agar shellcheck tidak false-positive.
: "${WIREPROXY_CONF}" "${WGCF_DIR}" "${CUSTOM_GEOSITE_DAT}" "${ADBLOCK_GEOSITE_ENTRY}" \
  "${WARP_TIER_STATE_KEY}" "${WARP_PLUS_LICENSE_STATE_KEY}" "${WARP_LOCK_FILE}" \
  "${SSH_USERS_STATE_DIR}" "${SSH_ACCOUNT_DIR}" "${SSH_QUOTA_DIR}" \
  "${SSHWS_DROPBEAR_SERVICE}" "${SSHWS_STUNNEL_SERVICE}" "${SSHWS_PROXY_SERVICE}" \
  "${SSHWS_QAC_ENFORCER_SERVICE}" "${SSHWS_QAC_ENFORCER_TIMER}" \
  "${SSHWS_DROPBEAR_PORT}" "${SSHWS_STUNNEL_PORT}" "${SSHWS_PROXY_PORT}" \
  "${ZIVPN_ROOT}" "${ZIVPN_CONFIG_FILE}" "${ZIVPN_CERT_FILE}" "${ZIVPN_KEY_FILE}" \
  "${ZIVPN_PASSWORDS_DIR}" "${ZIVPN_SYNC_BIN}" "${ZIVPN_SERVICE}" \
  "${ZIVPN_LISTEN_PORT}" "${ZIVPN_OBFS}" \
  "${SSH_DNS_ADBLOCK_ROOT}" "${SSH_DNS_ADBLOCK_CONFIG_FILE}" \
  "${SSH_DNS_ADBLOCK_BLOCKLIST_FILE}" "${SSH_DNS_ADBLOCK_URLS_FILE}" "${SSH_DNS_ADBLOCK_RENDERED_FILE}" \
  "${SSH_DNS_ADBLOCK_DNSMASQ_CONF}" "${SSH_DNS_ADBLOCK_SERVICE}" \
  "${SSH_DNS_ADBLOCK_SYNC_SERVICE}" "${SSH_DNS_ADBLOCK_SYNC_BIN}" \
  "${ADBLOCK_AUTO_UPDATE_SERVICE}" "${ADBLOCK_AUTO_UPDATE_TIMER}"

# Main Menu header cache (best-effort, supaya render menu tetap cepat)
MAIN_INFO_CACHE_TTL=300
MAIN_INFO_CACHE_TS=0
MAIN_INFO_CACHE_OS="-"
MAIN_INFO_CACHE_RAM="-"
MAIN_INFO_CACHE_IP="-"
MAIN_INFO_CACHE_ISP="-"
MAIN_INFO_CACHE_COUNTRY="-"
MAIN_INFO_CACHE_DOMAIN="-"
MAIN_INFO_CACHE_INVALIDATION_FILE="${WORK_DIR}/main-info.cache.invalidate"
ACCOUNT_INFO_DOMAIN_SYNC_STATE_FILE="${WORK_DIR}/account-info-domain.state"
ACCOUNT_INFO_DOMAIN_SYNC_CHECK_TTL=15
ACCOUNT_INFO_DOMAIN_SYNC_LAST_CHECK_TS=0

# Cache metadata quota (proto:username -> "quota_gb|expired|created|ip_enabled|ip_limit")
declare -Ag QUOTA_FIELDS_CACHE=()

# -------------------------
# UI styling (subtle)
# -------------------------
if [[ -t 1 ]]; then
  UI_RESET='\033[0m'
  UI_BOLD='\033[1m'
  UI_ACCENT='\033[0;36m'
  UI_MUTED='\033[0;37m'
  UI_WARN='\033[1;33m'
  UI_ERR='\033[0;31m'
else
  UI_RESET=''
  UI_BOLD=''
  UI_ACCENT=''
  UI_MUTED=''
  UI_WARN=''
UI_ERR=''
fi

MAIN_INFO_REMOTE_LOOKUPS="${MAIN_INFO_REMOTE_LOOKUPS:-1}"

init_runtime_dirs() {
  mkdir -p "${WORK_DIR}"
  chmod 700 "${WORK_DIR}"
  mkdir -p "${SSH_ACCOUNT_DIR}"
  chmod 700 "${SSH_ACCOUNT_DIR}" || true
  mkdir -p "${SSH_USERS_STATE_DIR}"
  chmod 700 "${SSH_USERS_STATE_DIR}" || true

  local lock_dir
  for lock_dir in \
    "$(dirname "${ACCOUNT_INFO_LOCK_FILE}")" \
    "$(dirname "${DOMAIN_CONTROL_LOCK_FILE}")" \
    "$(dirname "${USER_DATA_MUTATION_LOCK_FILE}")" \
    "$(dirname "${ROUTING_LOCK_FILE}")" \
    "$(dirname "${DNS_LOCK_FILE}")" \
    "$(dirname "${WARP_LOCK_FILE}")"; do
    mkdir -p "${lock_dir}" 2>/dev/null || true
    chmod 700 "${lock_dir}" 2>/dev/null || true
  done

  mkdir -p "${REPORT_DIR}"
  chmod 700 "${REPORT_DIR}"
}

# Pastikan directory account/quota ada
ensure_account_quota_dirs() {
  local proto
  mkdir -p "${ACCOUNT_ROOT}"
  mkdir -p "${QUOTA_ROOT}"
  chmod 700 "${ACCOUNT_ROOT}" "${QUOTA_ROOT}" || true

  for proto in "${ACCOUNT_PROTO_DIRS[@]}"; do
    mkdir -p "${ACCOUNT_ROOT}/${proto}"
    chmod 700 "${ACCOUNT_ROOT}/${proto}" || true
  done

  for proto in "${QUOTA_PROTO_DIRS[@]}"; do
    mkdir -p "${QUOTA_ROOT}/${proto}"
    chmod 700 "${QUOTA_ROOT}/${proto}" || true
  done

  mkdir -p "${SSH_ACCOUNT_DIR}" "${SSH_QUOTA_DIR}"
  chmod 700 "${SSH_ACCOUNT_DIR}" "${SSH_QUOTA_DIR}" || true
}

ensure_speed_policy_dirs() {
  local proto
  mkdir -p "${SPEED_POLICY_ROOT}"
  chmod 700 "${SPEED_POLICY_ROOT}" || true
  for proto in "${SPEED_POLICY_PROTO_DIRS[@]}"; do
    mkdir -p "${SPEED_POLICY_ROOT}/${proto}"
    chmod 700 "${SPEED_POLICY_ROOT}/${proto}" || true
  done
}

speed_policy_lock_prepare() {
  mkdir -p "$(dirname "${SPEED_POLICY_LOCK_FILE}")" 2>/dev/null || true
}

speed_policy_run_locked() {
  local rc=0
  if [[ "${SPEED_POLICY_LOCK_HELD:-0}" == "1" ]]; then
    "$@"
    return $?
  fi
  speed_policy_lock_prepare
  if have_cmd flock; then
    if (
      flock -x 200 || exit 1
      SPEED_POLICY_LOCK_HELD=1 "$@"
    ) 200>"${SPEED_POLICY_LOCK_FILE}"; then
      return 0
    fi
    rc=$?
    return "${rc}"
  fi
  SPEED_POLICY_LOCK_HELD=1 "$@"
  rc=$?
  return "${rc}"
}

normalize_domain_token() {
  local domain="${1:-}"
  domain="$(printf '%s' "${domain}" | tr '[:upper:]' '[:lower:]' | tr -d '\r\n' | awk '{print $1}' | tr -d ';')"
  printf '%s\n' "${domain}"
}

normalize_ip_token() {
  local ip="${1:-}"
  ip="$(printf '%s' "${ip}" | tr -d '\r\n' | awk '{print $1}' | tr -d ';')"
  printf '%s\n' "${ip}"
}

ip_literal_normalize() {
  local raw="${1:-}"
  raw="$(normalize_ip_token "${raw}")"
  [[ -n "${raw}" ]] || return 1
  need_python3
  python3 - <<'PY' "${raw}"
import ipaddress
import sys

value = str(sys.argv[1]).strip()
try:
    addr = ipaddress.ip_address(value)
except Exception:
    raise SystemExit(1)
print(addr.compressed)
PY
}

date_ymd_is_past() {
  local value="${1:-}"
  local value_ts="" today_ts=""
  [[ -n "${value}" ]] || return 1
  value_ts="$(date -d "${value}" +%s 2>/dev/null || true)"
  [[ -n "${value_ts}" ]] || return 1
  today_ts="$(date -d "$(date '+%Y-%m-%d')" +%s 2>/dev/null || true)"
  [[ -n "${today_ts}" ]] || return 1
  (( value_ts < today_ts ))
}

preview_report_path_prepare() {
  local prefix="${1:-preview}"
  local base_dir="${REPORT_DIR}"
  local out=""

  mkdir -p "${base_dir}" 2>/dev/null || base_dir="${WORK_DIR}"
  out="$(mktemp "${base_dir}/${prefix}.XXXXXX.txt" 2>/dev/null || true)"
  if [[ -z "${out}" ]]; then
    out="${WORK_DIR}/${prefix}.$(date +%s).$$.txt"
    : > "${out}" 2>/dev/null || return 1
  fi
  printf '%s\n' "${out}"
}

preview_report_show_file() {
  local path="${1:-}"
  local total_lines=0
  [[ -f "${path}" ]] || return 1
  if have_cmd less; then
    less -R "${path}"
    return $?
  fi
  total_lines="$(wc -l < "${path}" 2>/dev/null || echo 0)"
  sed -n '1,400p' "${path}" || return 1
  if [[ "${total_lines}" =~ ^[0-9]+$ ]] && (( total_lines > 400 )); then
    echo
    echo "... output dipotong; buka file report untuk daftar lengkap:"
    echo "  ${path}"
  fi
  return 0
}

account_info_lock_prepare() {
  mkdir -p "$(dirname "${ACCOUNT_INFO_LOCK_FILE}")" 2>/dev/null || true
}

account_info_run_locked() {
  local rc=0
  if [[ "${ACCOUNT_INFO_LOCK_HELD:-0}" == "1" ]]; then
    "$@"
    return $?
  fi
  if ! have_cmd flock; then
    ACCOUNT_INFO_LOCK_HELD=1 "$@"
    return $?
  fi
  account_info_lock_prepare
  if (
    flock -x 200 || exit 1
    ACCOUNT_INFO_LOCK_HELD=1 "$@"
  ) 200>"${ACCOUNT_INFO_LOCK_FILE}"; then
    return 0
  fi
  rc=$?
  return "${rc}"
}

domain_control_lock_prepare() {
  mkdir -p "$(dirname "${DOMAIN_CONTROL_LOCK_FILE}")" 2>/dev/null || true
}

domain_control_run_locked() {
  local rc=0
  if [[ "${DOMAIN_CONTROL_LOCK_HELD:-0}" == "1" ]]; then
    "$@"
    return $?
  fi
  if ! have_cmd flock; then
    DOMAIN_CONTROL_LOCK_HELD=1 "$@"
    return $?
  fi
  domain_control_lock_prepare
  if (
    flock -x 200 || exit 1
    DOMAIN_CONTROL_LOCK_HELD=1 "$@"
  ) 200>"${DOMAIN_CONTROL_LOCK_FILE}"; then
    return 0
  fi
  rc=$?
  return "${rc}"
}

user_data_mutation_lock_prepare() {
  mkdir -p "$(dirname "${USER_DATA_MUTATION_LOCK_FILE}")" 2>/dev/null || true
}

user_data_mutation_run_locked() {
  local rc=0
  if [[ "${USER_DATA_MUTATION_LOCK_HELD:-0}" == "1" ]]; then
    "$@"
    return $?
  fi
  user_data_mutation_lock_prepare
  if have_cmd flock; then
    if (
      flock -x 200 || exit 1
      USER_DATA_MUTATION_LOCK_HELD=1 "$@"
    ) 200>"${USER_DATA_MUTATION_LOCK_FILE}"; then
      return 0
    fi
    rc=$?
    return "${rc}"
  fi
  USER_DATA_MUTATION_LOCK_HELD=1 "$@"
  rc=$?
  return "${rc}"
}

quota_lock_file_path() {
  local qf="${1:-}"
  printf '%s.lock\n' "${qf}"
}

quota_restore_file_locked() {
  # args: backup_file target_file
  local src="${1:-}"
  local dst="${2:-}"
  local lockf
  [[ -n "${src}" && -n "${dst}" ]] || return 1
  lockf="$(quota_lock_file_path "${dst}")"
  mkdir -p "$(dirname "${lockf}")" 2>/dev/null || true

  if have_cmd flock; then
    (
      flock -x 200 || exit 1
      cp -f -- "${src}" "${dst}" || exit 1
      chmod 600 "${dst}" 2>/dev/null || true
    ) 200>"${lockf}"
    return $?
  fi

  cp -f -- "${src}" "${dst}" || return 1
  chmod 600 "${dst}" 2>/dev/null || true
  return 0
}

account_info_restore_file_locked() {
  # args: backup_file target_file
  local src="${1:-}"
  local dst="${2:-}"
  [[ -n "${src}" && -n "${dst}" ]] || return 1
  if [[ "${ACCOUNT_INFO_LOCK_HELD:-0}" != "1" ]]; then
    account_info_run_locked account_info_restore_file_locked "${src}" "${dst}"
    return $?
  fi

  mkdir -p "$(dirname "${dst}")" 2>/dev/null || true
  cp -f -- "${src}" "${dst}" || return 1
  chmod 600 "${dst}" 2>/dev/null || true
  return 0
}

speed_policy_restore_file_locked() {
  # args: backup_file target_file
  local src="${1:-}"
  local dst="${2:-}"
  [[ -n "${src}" && -n "${dst}" ]] || return 1
  if [[ "${SPEED_POLICY_LOCK_HELD:-0}" != "1" ]]; then
    speed_policy_run_locked speed_policy_restore_file_locked "${src}" "${dst}"
    return $?
  fi
  mkdir -p "$(dirname "${dst}")" 2>/dev/null || true
  cp -f -- "${src}" "${dst}" || return 1
  chmod 600 "${dst}" 2>/dev/null || true
  return 0
}

xray_expired_pause_if_active() {
  # args: out_var_name
  local __outvar="${1:-}"
  local was_active="false"
  if svc_exists xray-expired && svc_is_active xray-expired; then
    if ! svc_stop_checked xray-expired 20; then
      return 1
    fi
    was_active="true"
  fi
  [[ -n "${__outvar}" ]] && printf -v "${__outvar}" '%s' "${was_active}"
  return 0
}

xray_expired_resume_if_needed() {
  local was_active="${1:-false}"
  [[ "${was_active}" == "true" ]] || return 0
  svc_start_checked xray-expired 20
}

speed_policy_has_entries() {
  local proto
  for proto in "${SPEED_POLICY_PROTO_DIRS[@]}"; do
    if compgen -G "${SPEED_POLICY_ROOT}/${proto}/*.json" >/dev/null; then
      return 0
    fi
  done
  return 1
}

speed_policy_artifacts_present_in_xray() {
  # Cek apakah masih ada artefak speed policy di config Xray walau policy file kosong.
  # Ini penting untuk skenario "hapus policy terakhir tapi sync gagal".
  need_python3
  [[ -f "${XRAY_OUTBOUNDS_CONF}" && -f "${XRAY_ROUTING_CONF}" ]] || return 1

  python3 - <<'PY' \
    "${XRAY_OUTBOUNDS_CONF}" \
    "${XRAY_ROUTING_CONF}" \
    "${SPEED_OUTBOUND_TAG_PREFIX}" \
    "${SPEED_RULE_MARKER_PREFIX}"
import json
import sys

out_src, rt_src, out_prefix, marker_prefix = sys.argv[1:5]
bal_prefix = f"{out_prefix}bal-"

def load_json(path):
  with open(path, "r", encoding="utf-8") as f:
    return json.load(f)

try:
  out_cfg = load_json(out_src)
  rt_cfg = load_json(rt_src)
except Exception:
  # Konservatif: jika tidak bisa diparse, paksa jalur resync agar kondisi stale tidak terlewat.
  raise SystemExit(0)

for o in (out_cfg.get("outbounds") or []):
  if not isinstance(o, dict):
    continue
  tag = o.get("tag")
  if isinstance(tag, str) and tag.startswith(out_prefix):
    raise SystemExit(0)

routing = rt_cfg.get("routing") or {}

for r in (routing.get("rules") or []):
  if not isinstance(r, dict):
    continue
  if r.get("type") != "field":
    continue
  ot = r.get("outboundTag")
  if isinstance(ot, str) and ot.startswith(out_prefix):
    raise SystemExit(0)
  users = r.get("user")
  if isinstance(users, list):
    for u in users:
      if isinstance(u, str) and u.startswith(marker_prefix):
        raise SystemExit(0)

raise SystemExit(1)
PY
}

ssh_dns_adblock_runtime_refresh_if_available() {
  [[ -x "${SSH_DNS_ADBLOCK_SYNC_BIN}" ]] || return 0
  if declare -F adblock_run_locked >/dev/null 2>&1 && [[ "${ADBLOCK_LOCK_HELD:-0}" != "1" ]]; then
    adblock_run_locked ssh_dns_adblock_runtime_refresh_if_available
    return $?
  fi
  "${SSH_DNS_ADBLOCK_SYNC_BIN}" --apply >/dev/null 2>&1 || return 1
}

speed_policy_resync_after_warp_change() {
  # Perubahan WARP global mempengaruhi jalur dasar speed-mark outbounds.
  # Wajib sinkron ulang supaya speed user tidak memakai topology sebelumnya.
  # Walau policy kosong, tetap perlu sync bila artefak speed historis masih tertinggal.
  local need_sync="false"
  if speed_policy_has_entries; then
    need_sync="true"
  elif speed_policy_artifacts_present_in_xray; then
    need_sync="true"
  fi

  if [[ "${need_sync}" != "true" ]]; then
    return 0
  fi

  if ! speed_policy_sync_xray; then
    warn "Perubahan WARP global tersimpan, tetapi sinkronisasi speed policy gagal."
    return 1
  fi

  if ! speed_policy_apply_now >/dev/null 2>&1; then
    warn "Perubahan WARP global tersimpan, tetapi apply runtime speed policy gagal."
    return 1
  fi
  return 0
}

quota_migrate_dates_to_dateonly() {
  # Normalisasi metadata quota:
  # - created_at -> YYYY-MM-DD
  # - expired_at -> YYYY-MM-DD
  # Idempotent untuk nilai yang sudah sesuai.
  local -a quota_targets=("$@")
  if (( ${#quota_targets[@]} == 0 )); then
    quota_targets=("${QUOTA_PROTO_DIRS[@]}")
  fi
  need_python3
  python3 - <<'PY' "${QUOTA_ROOT}" "${quota_targets[@]}"
import json
import fcntl
import os
import re
import sys
import tempfile
from datetime import datetime

quota_root = sys.argv[1]
protos = tuple(sys.argv[2:])
had_warnings = False
snapshots = {}

DATE_ONLY_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
DATETIME_MIN_RE = re.compile(r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$")

def normalize_date(value):
  if value is None:
    return None
  s = str(value).strip()
  if not s:
    return None
  s = s.replace("T", " ")
  if s.endswith("Z"):
    s = s[:-1]

  if DATE_ONLY_RE.match(s):
    return s

  candidates = [s]
  if s.endswith("+00:00"):
    candidates.append(s[:-6])
  if re.match(r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$", s):
    candidates.append(s + ":00")
  candidates.append(s.replace(" ", "T"))

  for c in candidates:
    try:
      d = datetime.fromisoformat(c)
      return d.strftime("%Y-%m-%d")
    except Exception:
      pass

  for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M"):
    try:
      d = datetime.strptime(s, fmt)
      return d.strftime("%Y-%m-%d")
    except Exception:
      pass

  if len(s) >= 10 and DATE_ONLY_RE.match(s[:10]):
    return s[:10]

  return None

for proto in protos:
  d = os.path.join(quota_root, proto)
  if not os.path.isdir(d):
    continue
  for name in os.listdir(d):
    if not name.endswith(".json"):
      continue
    p = os.path.join(d, name)
    lock_path = p + ".lock"
    try:
      os.makedirs(os.path.dirname(lock_path) or ".", exist_ok=True)
    except Exception:
      pass
    try:
      lock_handle = open(lock_path, "a+", encoding="utf-8")
      fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX)
    except Exception:
      had_warnings = True
      print(f"[manage][WARN] Skip migrasi (lock gagal): {p}", file=sys.stderr)
      try:
        lock_handle.close()
      except Exception:
        pass
      continue
    try:
      try:
        with open(p, "r", encoding="utf-8") as f:
          meta = json.load(f)
        if not isinstance(meta, dict):
          continue
      except Exception:
        had_warnings = True
        print(f"[manage][WARN] Skip migrasi (JSON invalid): {p}", file=sys.stderr)
        continue

      changed = False
      for key in ("created_at", "expired_at"):
        if key not in meta:
          continue
        nd = normalize_date(meta.get(key))
        if nd is None:
          had_warnings = True
          print(f"[manage][WARN] Skip field {key} (format tidak dikenali) di: {p}", file=sys.stderr)
          continue
        if meta.get(key) != nd:
          meta[key] = nd
          changed = True

      if changed:
        try:
          snapshots[p] = (open(p, "rb").read(), int(os.stat(p).st_mode & 0o777))
        except Exception:
          had_warnings = True
          print(f"[manage][WARN] Skip migrasi (snapshot gagal): {p}", file=sys.stderr)
          continue
        dirn = os.path.dirname(p) or "."
        fd, tmp = tempfile.mkstemp(prefix=".tmp.", suffix=".json", dir=dirn)
        try:
          with os.fdopen(fd, "w", encoding="utf-8") as wf:
            json.dump(meta, wf, ensure_ascii=False, indent=2)
            wf.write("\n")
            wf.flush()
            os.fsync(wf.fileno())
          os.replace(tmp, p)
          try:
            os.chmod(p, 0o600)
          except Exception:
            pass
        finally:
          try:
            if os.path.exists(tmp):
              os.remove(tmp)
          except Exception:
            pass
    finally:
      try:
        fcntl.flock(lock_handle.fileno(), fcntl.LOCK_UN)
      except Exception:
        pass
      try:
        lock_handle.close()
      except Exception:
        pass

if had_warnings and snapshots:
  for path, (payload, mode) in snapshots.items():
    dirn = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(prefix=".rollback.", suffix=".json", dir=dirn)
    try:
      with os.fdopen(fd, "wb") as wf:
        wf.write(payload)
        wf.flush()
        os.fsync(wf.fileno())
      os.replace(tmp, path)
      try:
        if isinstance(mode, int):
          os.chmod(path, mode)
      except Exception:
        pass
    finally:
      try:
        if os.path.exists(tmp):
          os.remove(tmp)
      except Exception:
        pass
raise SystemExit(2 if had_warnings else 0)
PY
}

quota_migrate_dates_report_write() {
  local outfile="${1:-}"
  shift || true
  local -a quota_targets=("$@")
  if (( ${#quota_targets[@]} == 0 )); then
    quota_targets=("${QUOTA_PROTO_DIRS[@]}")
  fi
  [[ -n "${outfile}" ]] || return 1
  need_python3
  python3 - <<'PY' "${outfile}" "${QUOTA_ROOT}" "${quota_targets[@]}"
import json
import os
import re
import sys
from datetime import datetime

outfile = sys.argv[1]
quota_root = sys.argv[2]
protos = tuple(sys.argv[3:])

DATE_ONLY_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")

def normalize_date(value):
  if value is None:
    return None
  s = str(value).strip()
  if not s:
    return None
  s = s.replace("T", " ")
  if s.endswith("Z"):
    s = s[:-1]
  if DATE_ONLY_RE.match(s):
    return s
  candidates = [s]
  if s.endswith("+00:00"):
    candidates.append(s[:-6])
  if re.match(r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$", s):
    candidates.append(s + ":00")
  candidates.append(s.replace(" ", "T"))
  for c in candidates:
    try:
      d = datetime.fromisoformat(c)
      return d.strftime("%Y-%m-%d")
    except Exception:
      pass
  for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M"):
    try:
      d = datetime.strptime(s, fmt)
      return d.strftime("%Y-%m-%d")
    except Exception:
      pass
  if len(s) >= 10 and DATE_ONLY_RE.match(s[:10]):
    return s[:10]
  return None

rows = []
summary = {"ok": 0, "would_normalize": 0, "warning": 0}
for proto in protos:
  d = os.path.join(quota_root, proto)
  if not os.path.isdir(d):
    rows.append((proto, "(directory missing)", "skip", "proto directory tidak ditemukan"))
    continue
  for name in sorted(os.listdir(d)):
    if not name.endswith(".json"):
      continue
    path = os.path.join(d, name)
    try:
      with open(path, "r", encoding="utf-8") as fh:
        meta = json.load(fh)
      if not isinstance(meta, dict):
        raise ValueError("root JSON bukan object")
    except Exception as exc:
      rows.append((proto, path, "warning", f"JSON invalid: {exc}"))
      summary["warning"] += 1
      continue
    notes = []
    warning = False
    for key in ("created_at", "expired_at"):
      if key not in meta:
        continue
      nd = normalize_date(meta.get(key))
      if nd is None:
        warning = True
        notes.append(f"{key}=format-tidak-dikenali")
      elif meta.get(key) != nd:
        notes.append(f"{key}:{meta.get(key)} -> {nd}")
    if warning:
      status = "warning"
      summary["warning"] += 1
    elif notes:
      status = "would-normalize"
      summary["would_normalize"] += 1
    else:
      status = "ok"
      summary["ok"] += 1
    rows.append((proto, path, status, ", ".join(notes) if notes else "-"))

os.makedirs(os.path.dirname(outfile) or ".", exist_ok=True)
with open(outfile, "w", encoding="utf-8") as out:
  out.write(f"Generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
  out.write("Mode: dry-run normalize quota dates (tanpa write)\n")
  out.write(f"Summary: ok={summary['ok']} would_normalize={summary['would_normalize']} warning={summary['warning']}\n\n")
  for proto, path, status, note in rows:
    out.write(f"[{proto}] {status}\t{path}\t{note}\n")
PY
}

# -------------------------
# Util
# -------------------------
log() {
  echo -e "${UI_ACCENT}[manage]${UI_RESET} $*"
}

warn() {
  echo -e "${UI_WARN}[manage][WARN]${UI_RESET} $*" >&2
}

die() {
  echo -e "${UI_ERR}[manage][ERROR]${UI_RESET} $*" >&2
  exit 1
}

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Jalankan sebagai root: sudo ./manage.sh"
  fi
}

ensure_path_writable() {
  # args: file_path (existing)
  local path="$1"
  local dir probe tmp

  [[ -e "${path}" ]] || die "Path tidak ditemukan: ${path}"
  dir="$(dirname "${path}")"

  # Best-effort check: directory writable (detect read-only fs, weird perms)
  probe="$(mktemp "${dir}/.writetest.XXXXXX" 2>/dev/null || true)"
  if [[ -z "${probe}" ]]; then
    warn "Directory tidak bisa ditulis: ${dir}"
    die "Tidak dapat menulis ke ${dir} (kemungkinan filesystem read-only / permission khusus)."
  fi
  rm -f "${probe}" 2>/dev/null || true

  # Immutable attribute check (best-effort)
  if have_cmd lsattr; then
    if lsattr -d "${path}" 2>/dev/null | awk '{print $1}' | grep -q 'i'; then
      die "File immutable (chattr +i): ${path}. Jalankan: chattr -i '${path}'"
    fi
  fi

  # Temp file test (same dir) for atomic replace
  tmp="$(mktemp "${dir}/.tmp.$(basename "${path}").XXXXXX" 2>/dev/null || true)"
  if [[ -z "${tmp}" ]]; then
    die "Gagal membuat temp file di ${dir} untuk atomic replace. Cek permission/immutable."
  fi
  if ! cp -a "${path}" "${tmp}" 2>/dev/null; then
    rm -f "${tmp}" 2>/dev/null || true
    die "Gagal membuat temp file di ${dir} untuk atomic replace. Cek permission/immutable."
  fi
  rm -f "${tmp}" 2>/dev/null || true
}

restore_file_if_exists() {
  local src="$1"
  local dst="$2"
  if [[ -f "${src}" ]]; then
    cp -a "${src}" "${dst}" || true
  fi
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

now_ts() {
  date '+%Y-%m-%d %H:%M'
}

bytes_from_gb() {
  # GB (GiB) -> bytes
  local gb="${1:-0}"
  python3 - <<'PY' "${gb}"
import sys
try:
  gb=float(sys.argv[1])
except Exception:
  gb=0.0
b=int(gb*(1024**3))
if b < 0:
  b=0
print(b)
PY
}

quota_disp() {
  # Jika sudah ada unit (mis. "2.50 MB"), jangan tambahkan lagi.
  # Jika hanya angka (mis. "2.50"), tambahkan unit default.
  local v="${1:-}"
  local unit="${2:-GB}"
  if [[ -z "${v}" ]]; then
    echo "0 ${unit}"
    return 0
  fi
  if [[ "${v}" =~ [A-Za-z] ]]; then
    echo "${v}"
  else
    echo "${v} ${unit}"
  fi
}


normalize_gb_input() {
  # Accept "5" or "5GB" (case-insensitive). Returns numeric string or empty on invalid.
  local v="${1:-}"
  v="$(echo "${v}" | tr -d '[:space:]')"
  v="$(echo "${v}" | tr '[:lower:]' '[:upper:]')"
  if [[ "${v}" =~ ^([0-9]+([.][0-9]+)?)GB$ ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "${v}" =~ ^([0-9]+([.][0-9]+)?)$ ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi
  echo ""
}

normalize_speed_mbit_input() {
  # Accept "10", "10mbit", "10mbps", "10m" (case-insensitive), return numeric string.
  local v="${1:-}"
  v="$(echo "${v}" | tr -d '[:space:]')"
  v="$(echo "${v}" | tr '[:upper:]' '[:lower:]')"

  if [[ "${v}" =~ ^([0-9]+([.][0-9]+)?)(mbit|mbps|m)?$ ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi
  echo ""
}

speed_mbit_is_positive() {
  local n="${1:-}"
  [[ "${n}" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
  awk "BEGIN { exit !(${n} > 0) }"
}

validate_username() {
  # Aman untuk dipakai sebagai nama file: mencegah path traversal
  # Aturan:
  # - tidak boleh kosong
  # - tidak boleh mengandung '/', '\\', spasi, '@', atau '..'
  # - hanya karakter: A-Z a-z 0-9 . _ -
  local u="$1"

  if [[ -z "${u}" ]]; then
    return 1
  fi
  if [[ "${u}" == *"/"* || "${u}" == *"\\"* || "${u}" == *" "* || "${u}" == *"@"* || "${u}" == *".."* ]]; then
    return 1
  fi
  if [[ ! "${u}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$ ]]; then
    return 1
  fi
  return 0
}

proto_uses_password() {
  local proto="${1:-}"
  case "${proto}" in
    trojan) return 0 ;;
    *) return 1 ;;
  esac
}

proto_list_menu_print() {
  echo "  1) vless"
  echo "  2) vmess"
  echo "  3) trojan"
}

proto_menu_pick_to_value() {
  # args: pick_number -> prints proto or empty
  local pick="${1:-}"
  case "${pick}" in
    1) echo "vless" ;;
    2) echo "vmess" ;;
    3) echo "trojan" ;;
    *) echo "" ;;
  esac
}

account_username_find_protos() {
  # args: username
  local username="$1"
  local protos=()
  local p
  for p in "${ACCOUNT_PROTO_DIRS[@]}"; do
    if [[ -f "${ACCOUNT_ROOT}/${p}/${username}@${p}.txt" ]]; then
      protos+=("${p}")
    fi
  done
  echo "${protos[*]:-}"
}

quota_username_find_protos() {
  # args: username
  local username="$1"
  local protos=()
  local p
  for p in "${QUOTA_PROTO_DIRS[@]}"; do
    if [[ -f "${QUOTA_ROOT}/${p}/${username}@${p}.json" ]]; then
      protos+=("${p}")
    fi
  done
  echo "${protos[*]:-}"
}

xray_username_find_protos() {
  # args: username
  local username="$1"
  need_python3
  [[ -f "${XRAY_INBOUNDS_CONF}" ]] || return 0
  python3 - <<'PY' "${XRAY_INBOUNDS_CONF}" "${username}" 2>/dev/null || true
import json, sys
src, username = sys.argv[1:3]
try:
  with open(src,'r',encoding='utf-8') as f:
    cfg=json.load(f)
except Exception:
  raise SystemExit(0)

protos=set()
for ib in (cfg.get('inbounds') or []):
  if not isinstance(ib, dict):
    continue
  proto=ib.get('protocol')
  st=(ib.get('settings') or {})
  clients=st.get('clients') or []
  if not isinstance(clients, list):
    continue
  for c in clients:
    if not isinstance(c, dict):
      continue
    em=c.get('email')
    if not isinstance(em, str) or '@' not in em:
      continue
    u,p = em.split('@', 1)
    if u == username and isinstance(p, str) and p:
      protos.add(p.strip())
print(" ".join(sorted([x for x in protos if x])))
PY
}

is_yes() {
  # accept: y/yes/1/on/true
  local v="${1:-}"
  v="$(echo "${v}" | tr '[:upper:]' '[:lower:]')"
  [[ "${v}" == "y" || "${v}" == "yes" || "${v}" == "1" || "${v}" == "on" || "${v}" == "true" ]]
}

read_required_on_off() {
  # args: out_var_name prompt
  local -n _out_ref="$1"
  local prompt="${2:-Input (on/off): }"
  local value
  while true; do
    if ! read -r -p "${prompt}" value; then
      echo
      return 1
    fi
    if is_back_choice "${value}"; then
      return 2
    fi
    value="${value,,}"
    case "${value}" in
      on|off)
        _out_ref="${value}"
        return 0
        ;;
      *)
        warn "Input wajib on/off. Silakan isi 'on' atau 'off'."
        ;;
    esac
  done
}

is_back_choice() {
  local v="${1:-}"
  v="$(echo "${v}" | tr '[:upper:]' '[:lower:]')"
  [[ "${v}" == "0" || "${v}" == "kembali" || "${v}" == "k" || "${v}" == "back" || "${v}" == "b" ]]
}

is_back_word_choice() {
  local v="${1:-}"
  v="$(echo "${v}" | tr '[:upper:]' '[:lower:]')"
  [[ "${v}" == "kembali" || "${v}" == "k" || "${v}" == "back" || "${v}" == "b" ]]
}

detect_domain() {
  # Try nginx conf server_name first, then compatibility file, then hostname -f.
  local dom=""
  if [[ -f "${NGINX_CONF}" ]]; then
    dom="$(grep -E '^[[:space:]]*server_name[[:space:]]+' "${NGINX_CONF}" 2>/dev/null | head -n1 | sed -E 's/^[[:space:]]*server_name[[:space:]]+//; s/;.*$//' || true)"
    dom="$(echo "${dom}" | awk '{print $1}' | tr -d ';')"
  fi
  if [[ -z "${dom}" ]]; then
    dom="$(head -n1 "${XRAY_DOMAIN_FILE}" 2>/dev/null | tr -d '\r' | awk '{print $1}' | tr -d ';' || true)"
  fi
  if [[ -z "${dom}" ]]; then
    dom="$(hostname -f 2>/dev/null || hostname)"
  fi
  echo "${dom}"
}

sync_xray_domain_file() {
  local domain="${1:-}"
  local normalized tmp
  if [[ -z "${domain}" ]]; then
    domain="$(detect_domain)"
  fi
  normalized="$(normalize_domain_token "${domain}")"
  [[ -n "${normalized}" ]] || return 1

  mkdir -p "$(dirname "${XRAY_DOMAIN_FILE}")" 2>/dev/null || return 1
  tmp="$(mktemp "${WORK_DIR}/xray-domain.XXXXXX")" || return 1
  if ! printf '%s\n' "${normalized}" > "${tmp}"; then
    rm -f "${tmp}" >/dev/null 2>&1 || true
    return 1
  fi
  if ! install -m 644 "${tmp}" "${XRAY_DOMAIN_FILE}"; then
    rm -f "${tmp}" >/dev/null 2>&1 || true
    return 1
  fi
  rm -f "${tmp}" >/dev/null 2>&1 || true
  return 0
}

detect_public_ip() {
  # Prefer route src (no internet needed), fallback hostname -I
  local ip=""
  if have_cmd ip; then
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
  fi
  if [[ -z "${ip}" ]]; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  echo "${ip:-0.0.0.0}"
}

detect_public_ip_ipapi() {
  # Ambil public IP dari api.ipify.org (best-effort), fallback ke detect_public_ip
  local ip=""
  if have_cmd curl; then
    ip="$(curl -fsSL --max-time 5 "https://api.ipify.org" 2>/dev/null || true)"
  elif have_cmd wget; then
    ip="$(wget -qO- --timeout=5 "https://api.ipify.org" 2>/dev/null || true)"
  fi

  if [[ -z "${ip}" || ! "${ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    warn "Gagal fetch IP dari api.ipify.org, fallback ke deteksi lokal"
    ip="$(detect_public_ip)"
  fi
  echo "${ip}"
}

account_info_domain_sync_state_read() {
  local state=""
  if [[ -s "${ACCOUNT_INFO_DOMAIN_SYNC_STATE_FILE}" ]]; then
    state="$(head -n1 "${ACCOUNT_INFO_DOMAIN_SYNC_STATE_FILE}" 2>/dev/null | tr -d '\r')"
    state="$(echo "${state}" | awk '{print $1}' | tr -d ';')"
  fi
  echo "${state}"
}

account_info_domain_sync_state_write() {
  local domain="${1:-}"
  local tmp=""
  domain="$(normalize_domain_token "${domain}")"
  [[ -n "${domain}" ]] || domain="-"
  mkdir -p "${WORK_DIR}" 2>/dev/null || return 1
  tmp="$(mktemp "${WORK_DIR}/account-info-domain.XXXXXX" 2>/dev/null || true)"
  [[ -n "${tmp}" ]] || tmp="${WORK_DIR}/account-info-domain.$$"
  if ! printf '%s\n' "${domain}" > "${tmp}"; then
    rm -f "${tmp}" >/dev/null 2>&1 || true
    return 1
  fi
  if ! install -m 600 "${tmp}" "${ACCOUNT_INFO_DOMAIN_SYNC_STATE_FILE}" >/dev/null 2>&1; then
    rm -f "${tmp}" >/dev/null 2>&1 || true
    return 1
  fi
  rm -f "${tmp}" >/dev/null 2>&1 || true
  return 0
}

account_info_probe_domain_from_any_account_file() {
  local proto dir f dom
  for proto in "${ACCOUNT_PROTO_DIRS[@]}"; do
    dir="${ACCOUNT_ROOT}/${proto}"
    [[ -d "${dir}" ]] || continue
    f="$(find "${dir}" -maxdepth 1 -type f -name '*.txt' -print -quit 2>/dev/null || true)"
    [[ -n "${f}" ]] || continue
    dom="$(grep -E '^[[:space:]]*Domain[[:space:]]*:' "${f}" 2>/dev/null | head -n1 | sed -E 's/^[[:space:]]*Domain[[:space:]]*:[[:space:]]*//' || true)"
    dom="$(echo "${dom}" | awk '{print $1}' | tr -d ';')"
    if [[ -n "${dom}" ]]; then
      echo "${dom}"
      return 0
    fi
  done
  dir="${SSH_ACCOUNT_DIR}"
  if [[ -d "${dir}" ]]; then
    f="$(find "${dir}" -maxdepth 1 -type f -name '*.txt' -print -quit 2>/dev/null || true)"
    if [[ -n "${f}" ]]; then
      dom="$(grep -E '^[[:space:]]*Domain[[:space:]]*:' "${f}" 2>/dev/null | head -n1 | sed -E 's/^[[:space:]]*Domain[[:space:]]*:[[:space:]]*//' || true)"
      dom="$(echo "${dom}" | awk '{print $1}' | tr -d ';')"
      if [[ -n "${dom}" ]]; then
        echo "${dom}"
        return 0
      fi
    fi
  fi
  echo ""
}

ssh_account_info_compat_needs_refresh() {
  local state_file username acc_file acc_compat
  if declare -F ssh_state_dirs_prepare >/dev/null 2>&1; then
    ssh_state_dirs_prepare >/dev/null 2>&1 || true
  fi
  [[ -d "${SSH_USERS_STATE_DIR}" ]] || return 1

  while IFS= read -r -d '' state_file; do
    username="$(basename "${state_file}")"
    username="${username%@ssh.json}"
    username="${username%.json}"
    [[ -n "${username}" ]] || continue

    acc_file="${SSH_ACCOUNT_DIR}/${username}@ssh.txt"
    acc_compat="${SSH_ACCOUNT_DIR}/${username}.txt"
    if [[ ! -f "${acc_file}" && -f "${acc_compat}" ]]; then
      acc_file="${acc_compat}"
    fi

    if [[ ! -f "${acc_file}" ]]; then
      return 0
    fi
    if ! grep -Eq '^ISP[[:space:]]*:' "${acc_file}" 2>/dev/null; then
      return 0
    fi
    if ! grep -Eq '^Country[[:space:]]*:' "${acc_file}" 2>/dev/null; then
      return 0
    fi
    if ! grep -Eq '^SSH WS Path[[:space:]]*:[[:space:]]*/[A-Fa-f0-9]{10}[[:space:]]*$' "${acc_file}" 2>/dev/null; then
      return 0
    fi
    if ! grep -Eq '^SSH WS Path Alt[[:space:]]*:[[:space:]]*/<bebas>/[A-Fa-f0-9]{10}[[:space:]]*$' "${acc_file}" 2>/dev/null; then
      return 0
    fi
    if ! grep -Eq '^SSH Direct[[:space:]]+Port[[:space:]]*:' "${acc_file}" 2>/dev/null; then
      return 0
    fi
    if ! grep -Eq '^SSH SSL/TLS[[:space:]]+Port[[:space:]]*:' "${acc_file}" 2>/dev/null; then
      return 0
    fi
    if ! grep -Eq '^BadVPN UDPGW[[:space:]]*:' "${acc_file}" 2>/dev/null; then
      return 0
    fi
  done < <(find "${SSH_USERS_STATE_DIR}" -maxdepth 1 -type f -name '*.json' ! -name '.*' -print0 2>/dev/null | sort -z)

  return 1
}

ssh_account_info_refresh_all_from_state() {
  local state_file username updated=0 failed=0
  if ! declare -F ssh_account_info_refresh_from_state >/dev/null 2>&1; then
    printf '0|0\n'
    return 0
  fi
  if declare -F ssh_state_dirs_prepare >/dev/null 2>&1; then
    ssh_state_dirs_prepare >/dev/null 2>&1 || true
  fi

  [[ -d "${SSH_USERS_STATE_DIR}" ]] || {
    printf '0|0\n'
    return 0
  }

  while IFS= read -r -d '' state_file; do
    username="$(basename "${state_file}")"
    username="${username%@ssh.json}"
    username="${username%.json}"
    [[ -n "${username}" ]] || continue

    if ssh_account_info_refresh_from_state "${username}"; then
      updated=$((updated + 1))
    else
      failed=$((failed + 1))
    fi
  done < <(find "${SSH_USERS_STATE_DIR}" -maxdepth 1 -type f -name '*.json' ! -name '.*' -print0 2>/dev/null | sort -z)

  printf '%s|%s\n' "${updated}" "${failed}"
  (( failed == 0 ))
}

account_info_refresh_collect_ssh_users() {
  local -n _out_ref="$1"
  local username state_file account_file pass_file
  local -A seen=()
  _out_ref=()

  if declare -F ssh_state_dirs_prepare >/dev/null 2>&1; then
    ssh_state_dirs_prepare >/dev/null 2>&1 || true
  fi

  while IFS= read -r -d '' state_file; do
    username="$(basename "${state_file}")"
    username="${username%@ssh.json}"
    username="${username%.json}"
    [[ -n "${username}" ]] || continue
    [[ -n "${seen["${username}"]+x}" ]] && continue
    seen["${username}"]=1
    _out_ref+=("${username}")
  done < <(find "${SSH_USERS_STATE_DIR}" -maxdepth 1 -type f -name '*.json' ! -name '.*' -print0 2>/dev/null | sort -z)

  while IFS= read -r -d '' account_file; do
    username="$(basename "${account_file}")"
    username="${username%@ssh.txt}"
    username="${username%.txt}"
    [[ -n "${username}" ]] || continue
    [[ -n "${seen["${username}"]+x}" ]] && continue
    seen["${username}"]=1
    _out_ref+=("${username}")
  done < <(find "${SSH_ACCOUNT_DIR}" -maxdepth 1 -type f -name '*.txt' ! -name '.*' -print0 2>/dev/null | sort -z)

  while IFS= read -r -d '' pass_file; do
    username="$(basename "${pass_file}")"
    username="${username%.pass}"
    [[ -n "${username}" ]] || continue
    [[ -n "${seen["${username}"]+x}" ]] && continue
    seen["${username}"]=1
    _out_ref+=("${username}")
  done < <(find "${ZIVPN_PASSWORDS_DIR}" -maxdepth 1 -type f -name '*.pass' ! -name '.*' -print0 2>/dev/null | sort -z)

  while IFS= read -r username; do
    [[ -n "${username}" ]] || continue
    [[ -n "${seen["${username}"]+x}" ]] && continue
    seen["${username}"]=1
    _out_ref+=("${username}")
  done < <(ssh_linux_candidate_users_get 2>/dev/null || true)
}

account_info_refresh_targets_summary() {
  local scope="${1:-all}"
  local sample_limit="${2:-5}"
  local i proto username
  local xray_count=0 ssh_count=0
  local -A seen_xray=() seen_ssh=()
  local -a xray_preview_items=() ssh_preview_items=()
  local -a ssh_users=()
  local xray_preview="-" ssh_preview="-"

  [[ "${sample_limit}" =~ ^[0-9]+$ ]] || sample_limit=5

  ensure_account_quota_dirs
  if [[ "${scope}" == "all" || "${scope}" == "xray" ]]; then
    account_collect_files

    if (( ${#ACCOUNT_FILES[@]} > 0 )); then
      for i in "${!ACCOUNT_FILES[@]}"; do
        proto="${ACCOUNT_FILE_PROTOS[$i]}"
        username="$(account_parse_username_from_file "${ACCOUNT_FILES[$i]}" "${proto}")"
        [[ -n "${username}" ]] || continue
        if [[ -n "${seen_xray["${proto}|${username}"]+x}" ]]; then
          continue
        fi
        seen_xray["${proto}|${username}"]=1
        xray_count=$((xray_count + 1))
        if (( sample_limit > 0 && ${#xray_preview_items[@]} < sample_limit )); then
          xray_preview_items+=("${username}@${proto}")
        fi
      done
    fi
  fi

  if [[ "${scope}" == "all" || "${scope}" == "ssh" ]]; then
    account_info_refresh_collect_ssh_users ssh_users
    for username in "${ssh_users[@]}"; do
      [[ -n "${username}" ]] || continue
      if [[ -n "${seen_ssh["${username}"]+x}" ]]; then
        continue
      fi
      seen_ssh["${username}"]=1
      ssh_count=$((ssh_count + 1))
      if (( sample_limit > 0 && ${#ssh_preview_items[@]} < sample_limit )); then
        ssh_preview_items+=("${username}")
      fi
    done
  fi

  if (( ${#xray_preview_items[@]} > 0 )); then
    xray_preview="$(printf '%s, ' "${xray_preview_items[@]}")"
    xray_preview="${xray_preview%, }"
    if (( sample_limit > 0 && xray_count > sample_limit )); then
      xray_preview="${xray_preview}, ..."
    fi
  fi
  if (( ${#ssh_preview_items[@]} > 0 )); then
    ssh_preview="$(printf '%s, ' "${ssh_preview_items[@]}")"
    ssh_preview="${ssh_preview%, }"
    if (( sample_limit > 0 && ssh_count > sample_limit )); then
      ssh_preview="${ssh_preview}, ..."
    fi
  fi

  printf '%s|%s|%s|%s|%s\n' "${xray_count}" "${ssh_count}" "$((xray_count + ssh_count))" "${xray_preview}" "${ssh_preview}"
}

account_info_refresh_targets_report_write() {
  local scope="${1:-all}"
  local outfile="${2:-}"
  local i proto username
  local -A seen_xray=() seen_ssh=()
  local -a ssh_users=()

  [[ -n "${outfile}" ]] || return 1
  ensure_account_quota_dirs
  mkdir -p "$(dirname "${outfile}")" 2>/dev/null || true
  : > "${outfile}" || return 1

  {
    printf 'Scope: %s\n' "${scope}"
    printf 'Generated: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf '\n'

    if [[ "${scope}" == "all" || "${scope}" == "xray" ]]; then
      printf '[XRAY]\n'
      account_collect_files
      if (( ${#ACCOUNT_FILES[@]} == 0 )); then
        printf '(tidak ada target)\n'
      else
        for i in "${!ACCOUNT_FILES[@]}"; do
          proto="${ACCOUNT_FILE_PROTOS[$i]}"
          username="$(account_parse_username_from_file "${ACCOUNT_FILES[$i]}" "${proto}")"
          [[ -n "${username}" ]] || continue
          if [[ -n "${seen_xray["${proto}|${username}"]+x}" ]]; then
            continue
          fi
          seen_xray["${proto}|${username}"]=1
          printf '%s\t%s\t%s\n' "${username}@${proto}" "${proto}" "$(account_info_refresh_target_file_for_user "${proto}" "${username}")"
        done
      fi
      printf '\n'
    fi

    if [[ "${scope}" == "all" || "${scope}" == "ssh" ]]; then
      printf '[SSH]\n'
      account_info_refresh_collect_ssh_users ssh_users
      if (( ${#ssh_users[@]} == 0 )); then
        printf '(tidak ada target)\n'
      else
        for username in "${ssh_users[@]}"; do
          [[ -n "${username}" ]] || continue
          if [[ -n "${seen_ssh["${username}"]+x}" ]]; then
            continue
          fi
          seen_ssh["${username}"]=1
          printf '%s\tssh\t%s\n' "${username}" "$(ssh_account_info_file "${username}")"
        done
        if (( ${#seen_ssh[@]} == 0 )); then
          printf '(tidak ada target)\n'
        fi
      fi
    fi
  } > "${outfile}" || return 1

  chmod 600 "${outfile}" 2>/dev/null || true
  return 0
}

account_info_refresh_dry_run_status_for_file() {
  local target_file="${1:-}"
  local candidate_file="${2:-}"
  local hint="${3:-}"

  if [[ -z "${target_file}" || ! -f "${target_file}" ]]; then
    printf '%s\n' "would-create${hint:+ (${hint})}"
    return 0
  fi
  if [[ -z "${candidate_file}" || ! -f "${candidate_file}" ]]; then
    printf '%s\n' "preview-unavailable${hint:+ (${hint})}"
    return 0
  fi
  if cmp -s -- "${target_file}" "${candidate_file}"; then
    printf '%s\n' "no-rendered-drift"
    return 0
  fi
  printf '%s\n' "would-refresh${hint:+ (${hint})}"
}

account_info_refresh_append_diff_to_report() {
  local report_file="${1:-}"
  local current_file="${2:-}"
  local candidate_file="${3:-}"
  local label="${4:-rendered diff}"
  [[ -n "${report_file}" ]] || return 1
  {
    printf -- '--- %s\n' "${label}"
    if [[ ! -f "${candidate_file}" ]]; then
      printf '(candidate render tidak tersedia)\n'
    elif [[ ! -f "${current_file}" ]]; then
      printf '[current missing]\n'
      cat "${candidate_file}"
      [[ -s "${candidate_file}" ]] || printf '(candidate kosong)\n'
    elif cmp -s -- "${current_file}" "${candidate_file}"; then
      printf '(tidak ada perbedaan konten)\n'
    else
      diff -u --label "current:${current_file}" --label "rendered:${candidate_file}" "${current_file}" "${candidate_file}" || true
    fi
    printf '\n'
  } >> "${report_file}" || return 1
}

account_info_refresh_dry_run_report_write() {
  local scope="${1:-all}"
  local outfile="${2:-}"
  local domain="${3:-}"
  local ip="${4:-}"
  local target_isp="${5:-}"
  local target_country="${6:-}"
  local i proto username status target_file
  local stage_dir="" candidate_file="" state_file="" hint=""
  local -A seen_xray=() seen_ssh=()
  local -a ssh_users=()

  [[ -n "${outfile}" ]] || return 1
  ensure_account_quota_dirs
  mkdir -p "$(dirname "${outfile}")" 2>/dev/null || true
  : > "${outfile}" || return 1

  {
    printf 'Scope: %s\n' "${scope}"
    printf 'Mode: dry-run rendered content diff (tanpa write)\n'
    printf 'Target domain: %s\n' "${domain:-"-"}"
    printf 'Target ip: %s\n' "${ip:-"-"}"
    printf 'Target isp: %s\n' "${target_isp:-"-"}"
    printf 'Target country: %s\n' "${target_country:-"-"}"
    printf 'Generated: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf '\n'

    if [[ "${scope}" == "all" || "${scope}" == "xray" ]]; then
      printf '[XRAY dry-run]\n'
      account_collect_files
      if (( ${#ACCOUNT_FILES[@]} == 0 )); then
        printf '(tidak ada target)\n'
      else
        for i in "${!ACCOUNT_FILES[@]}"; do
          proto="${ACCOUNT_FILE_PROTOS[$i]}"
          username="$(account_parse_username_from_file "${ACCOUNT_FILES[$i]}" "${proto}")"
          [[ -n "${username}" ]] || continue
          if [[ -n "${seen_xray["${proto}|${username}"]+x}" ]]; then
            continue
          fi
          seen_xray["${proto}|${username}"]=1
          target_file="$(account_info_refresh_target_file_for_user "${proto}" "${username}")"
          stage_dir="$(mktemp -d "${WORK_DIR}/.account-dryrun.${username}.${proto}.XXXXXX" 2>/dev/null || true)"
          candidate_file=""
          if [[ -n "${stage_dir}" && -d "${stage_dir}" ]]; then
            candidate_file="${stage_dir}/candidate.txt"
            if ! account_info_refresh_for_user "${proto}" "${username}" "${domain}" "${ip}" "" "${candidate_file}" >/dev/null 2>&1; then
              candidate_file=""
            fi
          fi
          hint=""
          [[ -n "${target_isp}" && "${target_isp}" != "-" ]] && hint="target ISP=${target_isp}, Country=${target_country:-"-"}"
          status="$(account_info_refresh_dry_run_status_for_file "${target_file}" "${candidate_file}" "${hint}")"
          printf '%s\t%s\t%s\n' "${username}@${proto}" "${status}" "${target_file}"
          if [[ -n "${candidate_file}" ]]; then
            account_info_refresh_append_diff_to_report "${outfile}" "${target_file}" "${candidate_file}" "${username}@${proto}" || true
          fi
          [[ -n "${stage_dir}" ]] && rm -rf "${stage_dir}" >/dev/null 2>&1 || true
        done
      fi
      printf '\n'
    fi

    if [[ "${scope}" == "all" || "${scope}" == "ssh" ]]; then
      printf '[SSH dry-run]\n'
      account_info_refresh_collect_ssh_users ssh_users
      if (( ${#ssh_users[@]} == 0 )); then
        printf '(tidak ada target)\n'
      else
        for username in "${ssh_users[@]}"; do
          [[ -n "${username}" ]] || continue
          if [[ -n "${seen_ssh["${username}"]+x}" ]]; then
            continue
          fi
          seen_ssh["${username}"]=1
          target_file="$(ssh_account_info_file "${username}")"
          state_file="$(ssh_user_state_resolve_file "${username}")"
          stage_dir="$(mktemp -d "${WORK_DIR}/.ssh-account-dryrun.${username}.XXXXXX" 2>/dev/null || true)"
          candidate_file=""
          hint=""
          if [[ -n "${stage_dir}" && -d "${stage_dir}" ]]; then
            candidate_file="${stage_dir}/candidate.txt"
            if [[ -f "${state_file}" ]] && ssh_account_info_refresh_from_state "${username}" "" "${candidate_file}" >/dev/null 2>&1; then
              :
            else
              candidate_file=""
              if [[ ! -f "${state_file}" ]]; then
                hint="would-bootstrap-state"
              fi
            fi
          fi
          status="$(account_info_refresh_dry_run_status_for_file "${target_file}" "${candidate_file}" "${hint}")"
          printf '%s\t%s\t%s\n' "${username}" "${status}" "${target_file}"
          if [[ -n "${candidate_file}" ]]; then
            account_info_refresh_append_diff_to_report "${outfile}" "${target_file}" "${candidate_file}" "${username}@ssh" || true
          fi
          [[ -n "${stage_dir}" ]] && rm -rf "${stage_dir}" >/dev/null 2>&1 || true
        done
        if (( ${#seen_ssh[@]} == 0 )); then
          printf '(tidak ada target)\n'
        fi
      fi
    fi
  } > "${outfile}" || return 1

  chmod 600 "${outfile}" 2>/dev/null || true
  return 0
}

account_info_sync_after_domain_change_if_needed() {
  # Deprecated on CLI: render/startup must not trigger bulk rewrites anymore.
  return 0
}

account_info_compat_needs_refresh() {
  # Return 0 jika ditemukan file account info format kompatibilitas yang perlu disegarkan.
  # Kriteria:
  # - nama file format kompatibilitas (username.txt, belum username@proto.txt)
  # - belum memiliki blok "Links Import" modern
  # - belum memiliki baris link gRPC
  # - belum memiliki field ISP/Country
  # - belum memiliki field Path/Path Alt/Port modern
  ensure_account_quota_dirs
  account_collect_files

  if ssh_account_info_compat_needs_refresh; then
    return 0
  fi

  if (( ${#ACCOUNT_FILES[@]} == 0 )); then
    return 1
  fi

  local i f proto base
  for i in "${!ACCOUNT_FILES[@]}"; do
    f="${ACCOUNT_FILES[$i]}"
    proto="${ACCOUNT_FILE_PROTOS[$i]}"
    base="$(basename "${f}")"

    if [[ "${base}" != *@${proto}.txt ]]; then
      return 0
    fi

    if ! grep -Eq '^[[:space:]]*(Links Import:|=== LINKS IMPORT ===)[[:space:]]*$' "${f}" 2>/dev/null; then
      return 0
    fi

    if ! grep -Eq '^[[:space:]]*gRPC[[:space:]]*:' "${f}" 2>/dev/null; then
      return 0
    fi

    if ! grep -Eq '^[[:space:]]*ISP[[:space:]]*:' "${f}" 2>/dev/null; then
      return 0
    fi

    if ! grep -Eq '^[[:space:]]*Country[[:space:]]*:' "${f}" 2>/dev/null; then
      return 0
    fi

    if ! grep -Eq '^[[:space:]]*[A-Za-z0-9]+(?:[[:space:]][A-Za-z0-9]+)?[[:space:]]+Path(?:[[:space:]]+(WS|HUP|Service))?[[:space:]]*:' "${f}" 2>/dev/null; then
      return 0
    fi

    if ! grep -Eq '^[[:space:]]*[A-Za-z0-9]+(?:[[:space:]][A-Za-z0-9]+)?[[:space:]]+Path(?:[[:space:]]+(WS|HUP|Service))?[[:space:]]+Alt[[:space:]]*:' "${f}" 2>/dev/null; then
      return 0
    fi

    if ! grep -Eq '^[[:space:]]*[A-Za-z0-9]+(?:[[:space:]][A-Za-z0-9+]+)?[[:space:]]+(?:WS|HUP|gRPC|TCP\+TLS[[:space:]]+Port|Port)[[:space:]]*:' "${f}" 2>/dev/null; then
      return 0
    fi
  done

  return 1
}

account_info_compat_refresh_if_needed() {
  # Deprecated on CLI: compatibility refresh must be triggered explicitly from menu.
  return 0
}

cert_snapshot_create() {
  # args: backup_dir
  local backup_dir="$1"
  mkdir -p "${backup_dir}" || return 1
  chmod 700 "${backup_dir}" 2>/dev/null || return 1

  if [[ -f "${CERT_FULLCHAIN}" ]]; then
    cp -a "${CERT_FULLCHAIN}" "${backup_dir}/fullchain.pem" 2>/dev/null || return 1
    echo "1" > "${backup_dir}/fullchain.exists"
  else
    echo "0" > "${backup_dir}/fullchain.exists"
  fi

  if [[ -f "${CERT_PRIVKEY}" ]]; then
    cp -a "${CERT_PRIVKEY}" "${backup_dir}/privkey.pem" 2>/dev/null || return 1
    echo "1" > "${backup_dir}/privkey.exists"
  else
    echo "0" > "${backup_dir}/privkey.exists"
  fi

  return 0
}

cert_snapshot_restore() {
  # args: backup_dir
  local backup_dir="$1"
  local fullchain_exists privkey_exists
  local failed=0
  [[ -d "${backup_dir}" ]] || return 0

  fullchain_exists="$(cat "${backup_dir}/fullchain.exists" 2>/dev/null || echo "0")"
  privkey_exists="$(cat "${backup_dir}/privkey.exists" 2>/dev/null || echo "0")"

  if [[ "${fullchain_exists}" == "1" && -f "${backup_dir}/fullchain.pem" ]]; then
    cp -a "${backup_dir}/fullchain.pem" "${CERT_FULLCHAIN}" 2>/dev/null || failed=1
  else
    if [[ -e "${CERT_FULLCHAIN}" ]] && ! rm -f "${CERT_FULLCHAIN}" 2>/dev/null; then
      failed=1
    fi
  fi

  if [[ "${privkey_exists}" == "1" && -f "${backup_dir}/privkey.pem" ]]; then
    cp -a "${backup_dir}/privkey.pem" "${CERT_PRIVKEY}" 2>/dev/null || failed=1
  else
    if [[ -e "${CERT_PRIVKEY}" ]] && ! rm -f "${CERT_PRIVKEY}" 2>/dev/null; then
      failed=1
    fi
  fi

  if [[ -e "${CERT_PRIVKEY}" ]] && ! chmod 600 "${CERT_PRIVKEY}" 2>/dev/null; then
    failed=1
  fi
  if [[ -e "${CERT_FULLCHAIN}" ]] && ! chmod 600 "${CERT_FULLCHAIN}" 2>/dev/null; then
    failed=1
  fi

  return "${failed}"
}

domain_control_optional_file_snapshot_create() {
  local path="$1"
  local backup_dir="$2"
  local key="$3"
  mkdir -p "${backup_dir}" 2>/dev/null || return 1
  if [[ -e "${path}" || -L "${path}" ]]; then
    cp -a "${path}" "${backup_dir}/${key}.snapshot" 2>/dev/null || return 1
    printf '1\n' > "${backup_dir}/${key}.exists"
  else
    printf '0\n' > "${backup_dir}/${key}.exists"
  fi
  return 0
}

domain_control_optional_file_snapshot_restore() {
  local path="$1"
  local backup_dir="$2"
  local key="$3"
  local exists_flag="0"
  exists_flag="$(cat "${backup_dir}/${key}.exists" 2>/dev/null || printf '0')"
  if [[ "${exists_flag}" == "1" && -e "${backup_dir}/${key}.snapshot" ]]; then
    mkdir -p "$(dirname "${path}")" 2>/dev/null || true
    cp -a "${backup_dir}/${key}.snapshot" "${path}" 2>/dev/null || return 1
    return 0
  fi
  if [[ -e "${path}" || -L "${path}" ]]; then
    rm -f -- "${path}" 2>/dev/null || return 1
  fi
  return 0
}

domain_control_txn_clear() {
  DOMAIN_CTRL_TXN_ACTIVE="0"
  DOMAIN_CTRL_TXN_CERT_SNAPSHOT=""
  DOMAIN_CTRL_TXN_NGINX_BACKUP=""
  DOMAIN_CTRL_TXN_COMPAT_SNAPSHOT=""
  DOMAIN_CTRL_TXN_CF_SNAPSHOT=""
  DOMAIN_CTRL_TXN_CF_PREPARED="0"
  DOMAIN_CTRL_TXN_DOMAIN=""
  DOMAIN_CTRL_TXN_CF_ZONE_ID=""
  DOMAIN_CTRL_TXN_CF_IPV4=""
}

domain_control_txn_begin() {
  local cert_snapshot="$1"
  local nginx_backup="$2"
  local compat_snapshot="$3"
  local domain="$4"
  DOMAIN_CTRL_TXN_ACTIVE="1"
  DOMAIN_CTRL_TXN_CERT_SNAPSHOT="${cert_snapshot}"
  DOMAIN_CTRL_TXN_NGINX_BACKUP="${nginx_backup}"
  DOMAIN_CTRL_TXN_COMPAT_SNAPSHOT="${compat_snapshot}"
  DOMAIN_CTRL_TXN_CF_SNAPSHOT=""
  DOMAIN_CTRL_TXN_CF_PREPARED="0"
  DOMAIN_CTRL_TXN_DOMAIN="${domain}"
  DOMAIN_CTRL_TXN_CF_ZONE_ID=""
  DOMAIN_CTRL_TXN_CF_IPV4=""
}

domain_control_txn_register_cf_snapshot() {
  local zone_id="$1"
  local domain="$2"
  local ipv4="$3"
  local snapshot="$4"
  DOMAIN_CTRL_TXN_CF_ZONE_ID="${zone_id}"
  DOMAIN_CTRL_TXN_DOMAIN="${domain}"
  DOMAIN_CTRL_TXN_CF_IPV4="${ipv4}"
  DOMAIN_CTRL_TXN_CF_SNAPSHOT="${snapshot}"
  DOMAIN_CTRL_TXN_CF_PREPARED="0"
}

domain_control_txn_mark_cf_prepared() {
  DOMAIN_CTRL_TXN_CF_PREPARED="1"
}

domain_control_txn_restore() {
  local notes_name="$1"
  local rc=0
  declare -n notes_ref="${notes_name}"

  if [[ -n "${DOMAIN_CTRL_TXN_CF_SNAPSHOT}" && -f "${DOMAIN_CTRL_TXN_CF_SNAPSHOT}" && "${DOMAIN_CTRL_TXN_CF_PREPARED:-0}" == "1" ]]; then
    if ! cf_restore_relevant_a_records_snapshot "${DOMAIN_CTRL_TXN_CF_ZONE_ID}" "${DOMAIN_CTRL_TXN_DOMAIN}" "${DOMAIN_CTRL_TXN_CF_IPV4}" "${DOMAIN_CTRL_TXN_CF_SNAPSHOT}"; then
      notes_ref+=("restore DNS Cloudflare gagal")
      rc=1
    fi
  fi

  if [[ -n "${DOMAIN_CTRL_TXN_COMPAT_SNAPSHOT}" && -d "${DOMAIN_CTRL_TXN_COMPAT_SNAPSHOT}" ]]; then
    if ! domain_control_optional_file_snapshot_restore "${XRAY_DOMAIN_FILE}" "${DOMAIN_CTRL_TXN_COMPAT_SNAPSHOT}" compat_domain; then
      notes_ref+=("restore compat domain gagal")
      rc=1
    fi
  fi

  if [[ -n "${DOMAIN_CTRL_TXN_NGINX_BACKUP}" && -f "${DOMAIN_CTRL_TXN_NGINX_BACKUP}" ]]; then
    if ! cp -a "${DOMAIN_CTRL_TXN_NGINX_BACKUP}" "${NGINX_CONF}" >/dev/null 2>&1; then
      notes_ref+=("restore nginx conf gagal")
      rc=1
    fi
  fi

  if [[ -n "${DOMAIN_CTRL_TXN_CERT_SNAPSHOT}" && -d "${DOMAIN_CTRL_TXN_CERT_SNAPSHOT}" ]]; then
    if ! cert_snapshot_restore "${DOMAIN_CTRL_TXN_CERT_SNAPSHOT}" >/dev/null 2>&1; then
      notes_ref+=("restore sertifikat gagal")
      rc=1
    fi
  fi

  domain_control_restore_cert_runtime_after_rollback notes_ref || rc=1
  if ! domain_control_restore_stopped_services; then
    notes_ref+=("restore service runtime TLS gagal")
    rc=1
  else
    domain_control_clear_stopped_services
  fi

  [[ -n "${DOMAIN_CTRL_TXN_CF_SNAPSHOT}" ]] && rm -f "${DOMAIN_CTRL_TXN_CF_SNAPSHOT}" >/dev/null 2>&1 || true
  [[ -n "${DOMAIN_CTRL_TXN_COMPAT_SNAPSHOT}" ]] && rm -rf "${DOMAIN_CTRL_TXN_COMPAT_SNAPSHOT}" >/dev/null 2>&1 || true
  [[ -n "${DOMAIN_CTRL_TXN_CERT_SNAPSHOT}" ]] && rm -rf "${DOMAIN_CTRL_TXN_CERT_SNAPSHOT}" >/dev/null 2>&1 || true
  [[ -n "${DOMAIN_CTRL_TXN_NGINX_BACKUP}" ]] && rm -f "${DOMAIN_CTRL_TXN_NGINX_BACKUP}" >/dev/null 2>&1 || true
  domain_control_txn_clear
  return "${rc}"
}

main_info_os_get() {
  local pretty=""
  if [[ -r /etc/os-release ]]; then
    pretty="$(awk -F= '/^PRETTY_NAME=/{print $2; exit}' /etc/os-release 2>/dev/null | sed -E 's/^"//; s/"$//')"
  fi
  [[ -n "${pretty}" ]] || pretty="$(uname -sr 2>/dev/null || true)"
  [[ -n "${pretty}" ]] || pretty="-"
  echo "${pretty}"
}

main_info_ram_get() {
  local kb
  kb="$(awk '/^MemTotal:[[:space:]]+[0-9]+/{print $2; exit}' /proc/meminfo 2>/dev/null || true)"
  if [[ -z "${kb}" || ! "${kb}" =~ ^[0-9]+$ ]]; then
    echo "-"
    return 0
  fi
  awk -v kb="${kb}" 'BEGIN{
    gib = kb / 1024 / 1024;
    if (gib >= 1) {
      printf "%.2f GiB", gib;
    } else {
      printf "%.0f MiB", kb / 1024;
    }
  }'
}

main_info_uptime_get() {
  local u
  if have_cmd uptime; then
    u="$(uptime -p 2>/dev/null | sed -E 's/^up[[:space:]]+//')"
    [[ -n "${u}" ]] && { echo "${u}"; return 0; }
  fi
  u="$(awk '{print int($1)}' /proc/uptime 2>/dev/null || true)"
  if [[ -n "${u}" && "${u}" =~ ^[0-9]+$ ]]; then
    local d h m r
    d=$((u / 86400))
    r=$((u % 86400))
    h=$((r / 3600))
    r=$((r % 3600))
    m=$((r / 60))
    if (( d > 0 )); then
      echo "${d}d ${h}h ${m}m"
    elif (( h > 0 )); then
      echo "${h}h ${m}m"
    else
      echo "${m}m"
    fi
    return 0
  fi
  echo "-"
}

main_info_ip_quiet_get() {
  local ip=""
  if [[ "${MAIN_INFO_REMOTE_LOOKUPS}" == "1" ]] && have_cmd curl && have_cmd jq; then
    local json
    json="$(curl -fsSL --max-time 6 "http://ip-api.com/json/?fields=status,query" 2>/dev/null || true)"
    if [[ -n "${json}" ]]; then
      ip="$(echo "${json}" | jq -r 'if .status == "success" then (.query // "-") else "-" end' 2>/dev/null || true)"
    fi
  fi
  if [[ -z "${ip}" || "${ip}" == "-" || "${ip}" == "0.0.0.0" ]]; then
    ip="$(detect_public_ip)"
  fi
  if [[ "${MAIN_INFO_REMOTE_LOOKUPS}" == "1" ]] && [[ -z "${ip}" || "${ip}" == "0.0.0.0" || "${ip}" == "-" ]]; then
    if have_cmd curl; then
      ip="$(curl -4fsSL --max-time 4 "https://api.ipify.org" 2>/dev/null || true)"
    elif have_cmd wget; then
      ip="$(wget -qO- --timeout=4 "https://api.ipify.org" 2>/dev/null || true)"
    fi
  fi
  if [[ "${ip}" == "0.0.0.0" ]]; then
    ip="-"
  fi
  [[ -n "${ip}" ]] || ip="-"
  echo "${ip}"
}

main_info_geo_lookup() {
  # args: ip -> prints: ip|isp|country
  local ip="$1"
  local isp="-" country="-"
  local json

  case "${ip}" in
    ""|"-"|"0.0.0.0"|"127."*|"10."*|"192.168."*|"172.16."*|"172.17."*|"172.18."*|"172.19."*|"172.2"?.*|"172.30."*|"172.31."*)
      echo "${ip}|-|-"
      return 0
      ;;
  esac

  if [[ "${MAIN_INFO_REMOTE_LOOKUPS}" == "1" ]] && [[ "${ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && have_cmd curl && have_cmd jq; then
    json="$(curl -fsSL --max-time 6 "http://ip-api.com/json/${ip}?fields=status,query,country,isp" 2>/dev/null || true)"
    if [[ -n "${json}" ]]; then
      ip="$(echo "${json}" | jq -r 'if .status == "success" then (.query // "-") else "'"${ip}"'" end' 2>/dev/null || true)"
      country="$(echo "${json}" | jq -r 'if .status == "success" then (.country // "-") else "-" end' 2>/dev/null || true)"
      isp="$(echo "${json}" | jq -r 'if .status == "success" then (.isp // "-") else "-" end' 2>/dev/null || true)"
    fi
    if [[ -z "${isp}" || "${isp}" == "-" || -z "${country}" || "${country}" == "-" ]]; then
      json="$(curl -fsSL --max-time 6 "https://ipwho.is/${ip}" 2>/dev/null || true)"
      if [[ -n "${json}" ]]; then
        [[ -z "${country}" || "${country}" == "-" ]] && country="$(echo "${json}" | jq -r 'if .success == true then (.country // "-") else "-" end' 2>/dev/null || true)"
        [[ -z "${isp}" || "${isp}" == "-" ]] && isp="$(echo "${json}" | jq -r 'if .success == true then (.connection.isp // .isp // "-") else "-" end' 2>/dev/null || true)"
      fi
    fi
    if [[ -z "${isp}" || "${isp}" == "-" || -z "${country}" || "${country}" == "-" ]]; then
      json="$(curl -fsSL --max-time 6 "https://ipapi.co/${ip}/json/" 2>/dev/null || true)"
      if [[ -n "${json}" ]]; then
        [[ -z "${country}" || "${country}" == "-" ]] && country="$(echo "${json}" | jq -r '.country_name // "-"' 2>/dev/null || true)"
        [[ -z "${isp}" || "${isp}" == "-" ]] && isp="$(echo "${json}" | jq -r '.org // .asn_org // "-" ' 2>/dev/null || true)"
      fi
    fi
  fi

  [[ -n "${isp}" && "${isp}" != "null" ]] || isp="-"
  [[ -n "${country}" && "${country}" != "null" ]] || country="-"
  [[ -n "${ip}" && "${ip}" != "null" ]] || ip="-"
  echo "${ip}|${isp}|${country}"
}

main_info_tls_expired_get() {
  local days
  days="$(cert_expiry_days_left)"
  if [[ -z "${days}" ]]; then
    echo "-"
    return 0
  fi
  if (( days < 0 )); then
    echo "Expired"
  else
    echo "${days} days"
  fi
}

main_info_warp_status_get() {
  local target
  if ! svc_exists wireproxy; then
    echo "Not Installed"
    return 0
  fi
  if ! svc_is_active wireproxy; then
    echo "Inactive"
    return 0
  fi
  target="$(warp_tier_state_target_get)"
  case "${target}" in
    plus) echo "Active (PLUS)" ;;
    free) echo "Active (FREE)" ;;
    *) echo "Active" ;;
  esac
}

account_count_by_proto() {
  # args: proto -> prints number of unique usernames from /opt/account/<proto>/*.txt
  local proto="$1"
  local dir="${ACCOUNT_ROOT}/${proto}"
  local f base username
  declare -A seen=()

  [[ -d "${dir}" ]] || { echo "0"; return 0; }
  while IFS= read -r -d '' f; do
    base="$(basename "${f}")"
    base="${base%.txt}"
    username="${base%%@*}"
    [[ -n "${username}" ]] || continue
    seen["${username}"]=1
  done < <(find "${dir}" -maxdepth 1 -type f -name '*.txt' -print0 2>/dev/null)

  echo "${#seen[@]}"
}

main_info_cache_invalidated_at_get() {
  local ts="0"
  if [[ -s "${MAIN_INFO_CACHE_INVALIDATION_FILE}" ]]; then
    ts="$(head -n1 "${MAIN_INFO_CACHE_INVALIDATION_FILE}" 2>/dev/null | tr -d '\r' | awk '{print $1}' || true)"
  fi
  [[ "${ts}" =~ ^[0-9]+$ ]] || ts="0"
  printf '%s\n' "${ts}"
}

main_info_cache_invalidate() {
  local ts tmp
  ts="$(date +%s 2>/dev/null || echo 0)"
  MAIN_INFO_CACHE_TS=0
  mkdir -p "${WORK_DIR}" 2>/dev/null || true
  tmp="$(mktemp "${WORK_DIR}/main-info.invalidate.XXXXXX" 2>/dev/null || true)"
  [[ -n "${tmp}" ]] || tmp="${WORK_DIR}/main-info.invalidate.$$"
  if printf '%s\n' "${ts}" > "${tmp}"; then
    install -m 600 "${tmp}" "${MAIN_INFO_CACHE_INVALIDATION_FILE}" >/dev/null 2>&1 || true
  fi
  rm -f "${tmp}" >/dev/null 2>&1 || true
}

main_info_cache_refresh() {
  local now elapsed ip geo isp country invalidated_at
  now="$(date +%s 2>/dev/null || echo 0)"
  invalidated_at="$(main_info_cache_invalidated_at_get)"
  if [[ "${invalidated_at}" =~ ^[0-9]+$ ]] && (( invalidated_at > MAIN_INFO_CACHE_TS )); then
    MAIN_INFO_CACHE_TS=0
  fi
  elapsed=$(( now - MAIN_INFO_CACHE_TS ))
  if (( MAIN_INFO_CACHE_TS > 0 && elapsed >= 0 && elapsed < MAIN_INFO_CACHE_TTL )); then
    return 0
  fi

  MAIN_INFO_CACHE_OS="$(main_info_os_get)"
  MAIN_INFO_CACHE_RAM="$(main_info_ram_get)"
  MAIN_INFO_CACHE_DOMAIN="$(detect_domain)"
  MAIN_INFO_CACHE_IP="$(main_info_ip_quiet_get)"

  ip="${MAIN_INFO_CACHE_IP}"
  geo="$(main_info_geo_lookup "${ip}")"
  IFS='|' read -r ip isp country <<< "${geo}"
  [[ -n "${ip}" ]] || ip="-"
  [[ -n "${isp}" ]] || isp="-"
  [[ -n "${country}" ]] || country="-"
  MAIN_INFO_CACHE_IP="${ip}"
  MAIN_INFO_CACHE_ISP="${isp}"
  MAIN_INFO_CACHE_COUNTRY="${country}"
  MAIN_INFO_CACHE_TS="${now}"
}

main_menu_info_header_print() {
  local os ram up ip isp country domain tls warp
  local vless_count vmess_count trojan_count ssh_count
  local edge_icon nginx_icon xray_icon ssh_icon

  main_info_cache_refresh

  os="${MAIN_INFO_CACHE_OS}"
  ram="${MAIN_INFO_CACHE_RAM}"
  up="$(main_info_uptime_get)"
  ip="${MAIN_INFO_CACHE_IP}"
  isp="${MAIN_INFO_CACHE_ISP}"
  country="${MAIN_INFO_CACHE_COUNTRY}"
  domain="${MAIN_INFO_CACHE_DOMAIN}"
  tls="$(main_info_tls_expired_get)"
  warp="$(main_info_warp_status_get)"
  vless_count="$(account_count_by_proto "vless")"
  vmess_count="$(account_count_by_proto "vmess")"
  trojan_count="$(account_count_by_proto "trojan")"
  ssh_count="$(ssh_account_count)"
  edge_icon="$(service_status_icon "$(main_menu_edge_service_name)")"
  nginx_icon="$(service_status_icon "nginx")"
  xray_icon="$(service_status_icon "xray")"
  ssh_icon="$(service_group_status_icon "${SSHWS_DROPBEAR_SERVICE}" "${SSHWS_STUNNEL_SERVICE}" "${SSHWS_PROXY_SERVICE}")"

  printf "%-12s : %s\n" "System OS" "${os}"
  printf "%-12s : %s\n" "RAM" "${ram}"
  printf "%-12s : %s\n" "Uptime" "${up}"
  printf "%-12s : %s\n" "IP VPS" "${ip}"
  printf "%-12s : %s\n" "ISP" "${isp}"
  printf "%-12s : %s\n" "Country" "${country}"
  printf "%-12s : %s\n" "Domain" "${domain}"
  printf "%-12s : %s\n" "TLS Expired" "${tls}"
  printf "%-12s : %s\n" "WARP Status" "${warp}"
  hr
  main_menu_center_line "ACCOUNTS"
  main_menu_center_segments \
    "VLESS ${vless_count}" \
    "VMESS ${vmess_count}" \
    "TROJAN ${trojan_count}" \
    "SSH ${ssh_count}"
  echo
  main_menu_center_line "SERVICES"
  main_menu_center_segments \
    "Edge Mux ${edge_icon}" \
    "Nginx ${nginx_icon}" \
    "Xray ${xray_icon}" \
    "SSH ${ssh_icon}"
  hr
}

download_file_or_die() {
  local url="$1"
  local out="$2"
  local _unused_hint="${3:-}"
  local label="${4:-${_unused_hint:-$url}}"

  if ! download_file_checked "${url}" "${out}" "${label}"; then
    die "Gagal download: ${label}"
  fi
}

download_file_checked() {
  local url="$1"
  local out="$2"
  local label="${3:-$url}"

  if ! curl -fsSL --connect-timeout 15 --max-time 120 "${url}" -o "${out}"; then
    rm -f "${out}" >/dev/null 2>&1 || true
    return 1
  fi
  if [[ ! -s "${out}" ]]; then
    warn "File hasil download kosong: ${label}"
    rm -f "${out}" >/dev/null 2>&1 || true
    return 1
  fi
  return 0
}

rand_str() {
  local n="${1:-16}"
  ( set +o pipefail; tr -dc 'a-z0-9' </dev/urandom | head -c "$n" )
}

rand_email() {
  local user part
  user="$(rand_str 10)"
  part="$(rand_str 6)"
  local domains=("gmail.com" "outlook.com" "proton.me" "icloud.com" "yahoo.com")
  local idx=$(( RANDOM % ${#domains[@]} ))
  echo "${user}.${part}@${domains[$idx]}"
}

confirm_yn() {
  local prompt="$1"
  local ans
  while true; do
    if ! read -r -p "${prompt} (y/n): " ans; then
      echo
      return 1
    fi
    case "${ans,,}" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      *) echo "Input tidak valid. Jawab y/n." ;;
    esac
  done
}

confirm_yn_or_back() {
  # return: 0=yes, 1=no, 2=back
  local prompt="$1"
  local ans
  while true; do
    if ! read -r -p "${prompt} (y/n/kembali): " ans; then
      echo
      return 2
    fi
    case "${ans,,}" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      0|kembali|k|back|b) return 2 ;;
      *) echo "Input tidak valid. Jawab y/n/kembali." ;;
    esac
  done
}

confirm_menu_apply_now() {
  local prompt="$1"
  local ask_rc=0
  if confirm_yn_or_back "${prompt}"; then
    return 0
  fi
  ask_rc=$?
  if (( ask_rc == 2 )); then
    warn "Aksi dibatalkan (kembali)."
    return 2
  fi
  warn "Aksi dibatalkan."
  return 1
}

get_public_ipv4() {
  local ip=""
  ip="$(curl -4fsSL https://api.ipify.org 2>/dev/null || true)"
  [[ -n "$ip" ]] || ip="$(curl -4fsSL https://ipv4.icanhazip.com 2>/dev/null | tr -d '[:space:]' || true)"
  [[ -n "$ip" ]] || ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
  [[ -n "$ip" ]] || die "Gagal mendapatkan public IPv4 VPS."
  echo "$ip"
}

cf_api() {
  local method="$1"
  local endpoint="$2"
  local data="${3:-}"

  [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]] || die "CLOUDFLARE_API_TOKEN belum di-set."

  local url="https://api.cloudflare.com/client/v4${endpoint}"
  local resp code body trimmed header_file=""
  header_file="$(mktemp)" || die "Gagal membuat temporary header file Cloudflare."
  printf 'Authorization: Bearer %s\n' "${CLOUDFLARE_API_TOKEN}" > "${header_file}"
  printf 'Content-Type: application/json\n' >> "${header_file}"
  chmod 600 "${header_file}" >/dev/null 2>&1 || true

  if [[ -n "$data" ]]; then
    resp="$(curl -sS -L -X "$method" "$url" \
      -H "@${header_file}" \
      --connect-timeout 10 \
      --max-time 30 \
      --data "$data" \
      -w $'\n%{http_code}' || true)"
  else
    resp="$(curl -sS -L -X "$method" "$url" \
      -H "@${header_file}" \
      --connect-timeout 10 \
      --max-time 30 \
      -w $'\n%{http_code}' || true)"
  fi
  rm -f "${header_file}" >/dev/null 2>&1 || true

  code="${resp##*$'\n'}"
  body="${resp%$'\n'*}"

  if [[ -z "${body:-}" ]]; then
    echo "[Cloudflare] Empty response (HTTP ${code:-?}) for ${endpoint}" >&2
    return 1
  fi

  trimmed="${body#"${body%%[![:space:]]*}"}"
  if [[ ! "$trimmed" =~ ^[\{\[] ]]; then
    echo "[Cloudflare] Non-JSON response (HTTP ${code:-?}) for ${endpoint}:" >&2
    echo "$body" >&2
    return 1
  fi

  if [[ ! "${code:-}" =~ ^2 ]]; then
    echo "[Cloudflare] HTTP ${code:-?} for ${endpoint}:" >&2
    echo "$body" >&2
    return 1
  fi

  printf '%s' "$body"
}

cf_get_zone_id_by_name() {
  local zone_name="$1"
  local json zid err

  json="$(cf_api GET "/zones?name=${zone_name}&per_page=1" || true)"
  if [[ -z "${json:-}" ]]; then
    return 1
  fi

  if ! echo "$json" | jq -e '.success == true' >/dev/null 2>&1; then
    err="$(echo "$json" | jq -r '.errors[0].message // empty' 2>/dev/null || true)"
    [[ -n "$err" ]] && echo "[Cloudflare] $err" >&2
    return 1
  fi

  zid="$(echo "$json" | jq -r '.result[0].id // empty' 2>/dev/null || true)"
  [[ -n "$zid" ]] || return 1
  echo "$zid"
}

cf_get_account_id_by_zone() {
  local zone_id="$1"
  local json aid

  json="$(cf_api GET "/zones/${zone_id}" || true)"
  if [[ -z "${json:-}" ]]; then
    return 1
  fi

  aid="$(echo "$json" | jq -r '.result.account.id // empty' 2>/dev/null || true)"
  [[ -n "$aid" ]] || return 1
  echo "$aid"
}

cf_list_a_records_by_ip() {
  local zone_id="$1"
  local ip="$2"
  local json

  json="$(cf_api GET "/zones/${zone_id}/dns_records?type=A&content=${ip}&per_page=100" || true)"
  if [[ -z "${json:-}" ]]; then
    return 0
  fi

  if ! echo "$json" | jq -e '.success == true' >/dev/null 2>&1; then
    return 1
  fi

  echo "$json" | jq -r '.result[] | "\(.id)\t\(.name)"'
}

cf_delete_record() {
  local zone_id="$1"
  local record_id="$2"
  cf_api DELETE "/zones/${zone_id}/dns_records/${record_id}" >/dev/null \
    || {
      warn "Gagal delete DNS record Cloudflare: ${record_id}"
      return 1
    }
}

cf_create_a_record_with_ttl() {
  local zone_id="$1"
  local name="$2"
  local ip="$3"
  local proxied="${4:-false}"
  local ttl="${5:-1}"

  if [[ "$proxied" != "true" && "$proxied" != "false" ]]; then
    proxied="false"
  fi
  if [[ ! "${ttl}" =~ ^[0-9]+$ ]] || (( ttl < 1 )); then
    ttl=1
  fi

  local payload
  payload="$(cat <<EOF
{"type":"A","name":"$name","content":"$ip","ttl":$ttl,"proxied":$proxied}
EOF
  )"
  cf_api POST "/zones/${zone_id}/dns_records" "$payload" >/dev/null \
    || {
      warn "Gagal membuat A record Cloudflare untuk ${name}"
      return 1
    }
}

cf_create_a_record() {
  local zone_id="$1"
  local name="$2"
  local ip="$3"
  local proxied="${4:-false}"
  cf_create_a_record_with_ttl "${zone_id}" "${name}" "${ip}" "${proxied}" 1
}

cf_sync_a_record_proxy_mode() {
  # args: zone_id fqdn ip desired_proxied
  local zone_id="$1"
  local fqdn="$2"
  local ip="$3"
  local desired_proxied="${4:-false}"
  local json
  local lines=()
  local line rid rip rprox payload
  local failed=0

  if [[ "${desired_proxied}" != "true" && "${desired_proxied}" != "false" ]]; then
    desired_proxied="false"
  fi

  json="$(cf_api GET "/zones/${zone_id}/dns_records?type=A&name=${fqdn}&per_page=100" || true)"
  if [[ -z "${json:-}" ]] || ! echo "$json" | jq -e '.success == true' >/dev/null 2>&1; then
    return 0
  fi

  mapfile -t lines < <(echo "$json" | jq -r '.result[] | "\(.id)\t\(.content)\t\(.proxied)"' 2>/dev/null || true)
  if [[ ${#lines[@]} -eq 0 ]]; then
    return 0
  fi

  for line in "${lines[@]}"; do
    rid="${line%%$'\t'*}"
    line="${line#*$'\t'}"
    rip="${line%%$'\t'*}"
    rprox="${line#*$'\t'}"
    if [[ "${rip}" == "${ip}" && "${rprox}" != "${desired_proxied}" ]]; then
      payload="$(cat <<EOF
{"type":"A","name":"$fqdn","content":"$ip","ttl":1,"proxied":$desired_proxied}
EOF
)"
      cf_api PUT "/zones/${zone_id}/dns_records/${rid}" "$payload" >/dev/null \
        || {
          warn "Gagal menyelaraskan mode proxy Cloudflare untuk record ${fqdn} (${rid})"
          failed=1
        }
    fi
  done
  return "${failed}"
}

cf_validate_subdomain_a_record_choice() {
  local zone_id="$1"
  local fqdn="$2"
  local ip="$3"
  local proxied="${4:-false}"
  local json rec_ips any_same any_diff
  local cip ask_rc=0

  if [[ "${proxied}" != "true" && "${proxied}" != "false" ]]; then
    proxied="false"
  fi

  log "Preflight DNS A record Cloudflare untuk: $fqdn"
  json="$(cf_api GET "/zones/${zone_id}/dns_records?type=A&name=${fqdn}&per_page=100" || true)"
  if [[ -z "${json:-}" ]] || ! echo "$json" | jq -e '.success == true' >/dev/null 2>&1; then
    return 0
  fi

  mapfile -t rec_ips < <(echo "$json" | jq -r '.result[].content' 2>/dev/null || true)
  if [[ ${#rec_ips[@]} -eq 0 ]]; then
    return 0
  fi

  any_same="0"
  any_diff="0"
  for cip in "${rec_ips[@]}"; do
    if [[ "${cip}" == "${ip}" ]]; then
      any_same="1"
    else
      any_diff="1"
    fi
  done

  if [[ "${any_diff}" == "1" ]]; then
    die "Subdomain ${fqdn} sudah ada di Cloudflare tetapi IP berbeda (${rec_ips[*]}). Gunakan nama subdomain lain."
  fi

  if [[ "${any_same}" == "1" ]]; then
    warn "A record target sudah ada: ${fqdn} -> ${ip}"
    echo "Mode proxy target akan diselaraskan ke pilihan saat apply domain."
    if ! confirm_yn_or_back "Lanjut menggunakan domain ini?"; then
      ask_rc=$?
      if (( ask_rc == 2 )); then
        warn "Dibatalkan oleh pengguna (kembali)."
        return 2
      fi
      warn "Dibatalkan oleh pengguna."
      return 1
    fi
  fi

  return 0
}

gen_subdomain_random() {
  rand_str 5
}

validate_subdomain() {
  local s="$1"
  [[ -n "$s" ]] || return 1
  [[ "$s" == "${s,,}" ]] || return 1
  [[ "$s" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$ ]] || return 1
  [[ "$s" != *" "* ]] || return 1
  return 0
}

cf_prepare_subdomain_a_record() {
  local zone_id="$1"
  local fqdn="$2"
  local ip="$3"
  local proxied="${4:-false}"

  log "Menyiapkan DNS A record Cloudflare untuk: $fqdn"

  local json rec_ips any_same any_diff target_ready
  target_ready="0"
  json="$(cf_api GET "/zones/${zone_id}/dns_records?type=A&name=${fqdn}&per_page=100" || true)"
  if [[ -n "${json:-}" ]] && echo "$json" | jq -e '.success == true' >/dev/null 2>&1; then
    mapfile -t rec_ips < <(echo "$json" | jq -r '.result[].content' 2>/dev/null || true)
    if [[ ${#rec_ips[@]} -gt 0 ]]; then
      any_same="0"
      any_diff="0"
      local cip
      for cip in "${rec_ips[@]}"; do
        if [[ "$cip" == "$ip" ]]; then
          any_same="1"
        else
          any_diff="1"
        fi
      done

      if [[ "$any_diff" == "1" ]]; then
        die "Subdomain $fqdn sudah ada di Cloudflare tetapi IP berbeda (${rec_ips[*]}). Gunakan nama subdomain lain."
      fi

      if [[ "$any_same" == "1" ]]; then
        warn "A record sudah ada: $fqdn -> $ip (sama dengan IP VPS)"
        if ! cf_sync_a_record_proxy_mode "$zone_id" "$fqdn" "$ip" "$proxied"; then
          return 1
        fi
        log "Melanjutkan proses dengan record target yang sudah ada."
        target_ready="1"
      fi
    fi
  fi

  if [[ "${target_ready}" != "1" ]]; then
    log "Membuat DNS A record: $fqdn -> $ip"
    if ! cf_create_a_record "$zone_id" "$fqdn" "$ip" "$proxied"; then
      return 1
    fi
    target_ready="1"
  fi

  # Cleanup record domain lain dengan IP yang sama dilakukan setelah target fqdn siap,
  # supaya tidak ada jeda putus bila create record target gagal.
  local same_ip=()
  mapfile -t same_ip < <(cf_list_a_records_by_ip "$zone_id" "$ip" || true)
  if [[ ${#same_ip[@]} -gt 0 ]]; then
    local line
    for line in "${same_ip[@]}"; do
      local rid="${line%%$'\t'*}"
      local rname="${line#*$'\t'}"
      if [[ "$rname" != "$fqdn" ]]; then
        warn "Ditemukan A record lain dengan IP sama ($ip): $rname -> $ip"
        warn "Menghapus A record: $rname"
        if ! cf_delete_record "$zone_id" "$rid"; then
          return 1
        fi
      fi
    done
  fi
  return 0
}

cf_snapshot_relevant_a_records() {
  local zone_id="$1"
  local fqdn="$2"
  local ip="$3"
  local outfile="${4:-}"
  local target_file="" same_file="" target_json="" same_json=""

  [[ -n "${outfile}" ]] || return 1
  target_file="$(mktemp "${WORK_DIR}/.cf-target.XXXXXX" 2>/dev/null || true)"
  same_file="$(mktemp "${WORK_DIR}/.cf-same-ip.XXXXXX" 2>/dev/null || true)"
  [[ -n "${target_file}" && -n "${same_file}" ]] || {
    rm -f -- "${target_file}" "${same_file}" >/dev/null 2>&1 || true
    return 1
  }

  target_json="$(cf_api GET "/zones/${zone_id}/dns_records?type=A&name=${fqdn}&per_page=100" 2>/dev/null || true)"
  same_json="$(cf_api GET "/zones/${zone_id}/dns_records?type=A&content=${ip}&per_page=100" 2>/dev/null || true)"
  printf '%s\n' "${target_json:-{\"result\":[]}}" > "${target_file}" || return 1
  printf '%s\n' "${same_json:-{\"result\":[]}}" > "${same_file}" || return 1

  if ! jq -s '
    [.[0].result // [], .[1].result // []]
    | add
    | map(select((.type // "A") == "A"))
    | unique_by(.id)
    | map({
        id: (.id // ""),
        name: (.name // ""),
        content: (.content // ""),
        proxied: (.proxied // false),
        ttl: (.ttl // 1)
      })
  ' "${target_file}" "${same_file}" > "${outfile}" 2>/dev/null; then
    rm -f -- "${outfile}" "${target_file}" "${same_file}" >/dev/null 2>&1 || true
    return 1
  fi

  chmod 600 "${outfile}" >/dev/null 2>&1 || true
  rm -f -- "${target_file}" "${same_file}" >/dev/null 2>&1 || true
  return 0
}

cf_restore_relevant_a_records_snapshot() {
  local zone_id="$1"
  local fqdn="$2"
  local ip="$3"
  local snapshot_file="${4:-}"
  local target_file="" same_file="" current_target="" current_same=""
  local -a current_ids=()

  [[ -f "${snapshot_file}" ]] || return 1
  target_file="$(mktemp "${WORK_DIR}/.cf-restore-target.XXXXXX" 2>/dev/null || true)"
  same_file="$(mktemp "${WORK_DIR}/.cf-restore-same.XXXXXX" 2>/dev/null || true)"
  [[ -n "${target_file}" && -n "${same_file}" ]] || {
    rm -f -- "${target_file}" "${same_file}" >/dev/null 2>&1 || true
    return 1
  }

  current_target="$(cf_api GET "/zones/${zone_id}/dns_records?type=A&name=${fqdn}&per_page=100" 2>/dev/null || true)"
  current_same="$(cf_api GET "/zones/${zone_id}/dns_records?type=A&content=${ip}&per_page=100" 2>/dev/null || true)"
  printf '%s\n' "${current_target:-{\"result\":[]}}" > "${target_file}" || return 1
  printf '%s\n' "${current_same:-{\"result\":[]}}" > "${same_file}" || return 1

  mapfile -t current_ids < <(
    jq -s -r '
      [.[0].result // [], .[1].result // []]
      | add
      | map(select((.type // "A") == "A"))
      | unique_by(.id)
      | .[] | (.id // empty)
    ' "${target_file}" "${same_file}" 2>/dev/null || true
  )

  local rid name content proxied ttl
  for rid in "${current_ids[@]}"; do
    [[ -n "${rid}" ]] || continue
    if ! cf_delete_record "${zone_id}" "${rid}"; then
      rm -f -- "${target_file}" "${same_file}" >/dev/null 2>&1 || true
      return 1
    fi
  done

  while IFS=$'\t' read -r name content proxied ttl; do
    [[ -n "${name}" && -n "${content}" ]] || continue
    if ! cf_create_a_record_with_ttl "${zone_id}" "${name}" "${content}" "${proxied}" "${ttl}"; then
      rm -f -- "${target_file}" "${same_file}" >/dev/null 2>&1 || true
      return 1
    fi
  done < <(
    jq -r '
      .[]
      | [
          (.name // ""),
          (.content // ""),
          (if (.proxied // false) then "true" else "false" end),
          ((.ttl // 1) | tostring)
        ]
      | @tsv
    ' "${snapshot_file}" 2>/dev/null || true
  )

  rm -f -- "${target_file}" "${same_file}" >/dev/null 2>&1 || true
  return 0
}

domain_menu_v2() {
  ui_menu_screen_begin "6) Domain Control > Set Domain" "Konfigurasi Domain TLS"
  echo -e "${UI_MUTED}Pilih metode domain untuk proses set domain.${UI_RESET}"
  echo -e "  ${UI_ACCENT}1)${UI_RESET} Input domain manual"
  echo -e "  ${UI_ACCENT}2)${UI_RESET} Gunakan domain yang disediakan"
  echo -e "  ${UI_ACCENT}0)${UI_RESET} Kembali"
  hr

  local choice=""
  while true; do
    if ! read -r -p "Pilih opsi (1-2/0/kembali): " choice; then
      echo
      return 2
    fi
    case "$choice" in
      1|2) break ;;
      0|kembali|k|back|b) return 2 ;;
      *) echo "Pilihan tidak valid." ;;
    esac
  done

  if [[ "$choice" == "1" ]]; then
    local re='^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$'
    while true; do
      if ! read -r -p "Masukkan domain (atau kembali): " DOMAIN; then
        echo
        return 2
      fi
      if is_back_choice "${DOMAIN}"; then
        return 2
      fi
      DOMAIN="${DOMAIN,,}"

      [[ -n "${DOMAIN:-}" ]] || {
        echo "Domain tidak boleh kosong."
        continue
      }

      if [[ "$DOMAIN" =~ $re ]]; then
        log "Domain valid: $DOMAIN"
        ACME_CERT_MODE="standalone"
        ACME_ROOT_DOMAIN=""
        CF_ZONE_ID=""
        break
      else
        echo "Domain tidak valid. Coba lagi."
      fi
    done
    return 0
  fi

  VPS_IPV4="$(get_public_ipv4)"
  log "Public IPv4 VPS: $VPS_IPV4"

  [[ ${#PROVIDED_ROOT_DOMAINS[@]} -gt 0 ]] || die "Daftar domain induk (PROVIDED_ROOT_DOMAINS) kosong."

  echo
  echo -e "${UI_BOLD}Pilih domain induk${UI_RESET}"
  local i=1
  local root=""
  for root in "${PROVIDED_ROOT_DOMAINS[@]}"; do
    echo -e "  ${UI_ACCENT}${i})${UI_RESET} ${root}"
    i=$((i + 1))
  done

  local pick=""
  while true; do
    if ! read -r -p "Pilih nomor domain induk (1-${#PROVIDED_ROOT_DOMAINS[@]}/kembali): " pick; then
      echo
      return 2
    fi
    if is_back_choice "${pick}"; then
      return 2
    fi
    [[ "$pick" =~ ^[0-9]+$ ]] || { echo "Input harus angka."; continue; }
    [[ "$pick" -ge 1 && "$pick" -le ${#PROVIDED_ROOT_DOMAINS[@]} ]] || { echo "Di luar range."; continue; }
    break
  done

  ACME_ROOT_DOMAIN="${PROVIDED_ROOT_DOMAINS[$((pick - 1))]}"
  log "Domain induk terpilih: $ACME_ROOT_DOMAIN"

  CF_ZONE_ID="$(cf_get_zone_id_by_name "$ACME_ROOT_DOMAIN" || true)"
  [[ -n "${CF_ZONE_ID:-}" ]] || die "Zone Cloudflare untuk $ACME_ROOT_DOMAIN tidak ditemukan / token tidak punya akses (butuh Zone:Read + DNS:Edit)."
  CF_ACCOUNT_ID="$(cf_get_account_id_by_zone "$CF_ZONE_ID" || true)"
  [[ -n "${CF_ACCOUNT_ID:-}" ]] || warn "Tidak bisa ambil CF_ACCOUNT_ID dari zone (acme.sh dns_cf mungkin tetap bisa jalan tanpa ini)."

  echo
  echo -e "${UI_BOLD}Pilih metode pembuatan subdomain${UI_RESET}"
  echo -e "  ${UI_ACCENT}1)${UI_RESET} Generate acak"
  echo -e "  ${UI_ACCENT}2)${UI_RESET} Input manual"

  local mth=""
  while true; do
    if ! read -r -p "Pilih opsi (1-2/kembali): " mth; then
      echo
      return 2
    fi
    case "$mth" in
      1|2) break ;;
      0|kembali|k|back|b) return 2 ;;
      *) echo "Pilihan tidak valid." ;;
    esac
  done

  local sub=""
  if [[ "$mth" == "1" ]]; then
    sub="$(gen_subdomain_random)"
    log "Subdomain generated: $sub"
  else
    while true; do
      if ! read -r -p "Masukkan nama subdomain (atau kembali): " sub; then
        echo
        return 2
      fi
      if is_back_choice "${sub}"; then
        return 2
      fi
      sub="${sub,,}"
      if validate_subdomain "$sub"; then
        log "Subdomain valid: $sub"
        break
      fi
      echo "Subdomain tidak valid. Hanya huruf kecil, angka, titik, dan strip (-). Tanpa spasi/kapital/karakter aneh."
    done
  fi

  echo
  local proxy_rc=0
  if confirm_yn_or_back "Aktifkan Cloudflare proxy (orange cloud) untuk DNS A record?"; then
    CF_PROXIED="true"
    log "Cloudflare proxy: ON (proxied=true)"
  else
    proxy_rc=$?
    if (( proxy_rc == 2 )); then
      warn "Input domain dibatalkan, kembali ke menu Domain Control."
      return 2
    fi
    CF_PROXIED="false"
    log "Cloudflare proxy: OFF (proxied=false)"
  fi

  DOMAIN="${sub}.${ACME_ROOT_DOMAIN}"
  log "Domain final: $DOMAIN"

  local cf_rc=0
  cf_validate_subdomain_a_record_choice "$CF_ZONE_ID" "$DOMAIN" "$VPS_IPV4" "$CF_PROXIED" || cf_rc=$?
  if (( cf_rc != 0 )); then
    if (( cf_rc == 1 || cf_rc == 2 )); then
      warn "Input domain dibatalkan, kembali ke menu Domain Control."
      return 2
    fi
    return "${cf_rc}"
  fi

  ACME_CERT_MODE="dns_cf_wildcard"
  log "Mode sertifikat: wildcard dns_cf untuk ${DOMAIN} (meliputi *.$DOMAIN)"
}

stop_conflicting_services() {
  DOMAIN_CTRL_STOPPED_SERVICES=()
  DOMAIN_CTRL_STOP_FAILURES=()

  local svc
  for svc in nginx apache2 caddy lighttpd; do
    if svc_exists "${svc}" && svc_is_active "${svc}"; then
      if systemctl stop "${svc}" >/dev/null 2>&1; then
        if svc_is_active "${svc}"; then
          DOMAIN_CTRL_STOP_FAILURES+=("${svc}: masih aktif setelah stop")
        else
          domain_control_append_stopped_service "${svc}"
        fi
      else
        DOMAIN_CTRL_STOP_FAILURES+=("${svc}: gagal dihentikan")
      fi
    fi
  done
  domain_control_stop_edge_runtime_if_needed
  if (( ${#DOMAIN_CTRL_STOP_FAILURES[@]} > 0 )); then
    return 1
  fi
  return 0
}

domain_control_append_stopped_service() {
  local candidate="$1"
  local existing
  [[ -n "${candidate}" ]] || return 0
  for existing in "${DOMAIN_CTRL_STOPPED_SERVICES[@]}"; do
    [[ "${existing}" == "${candidate}" ]] && return 0
  done
  DOMAIN_CTRL_STOPPED_SERVICES+=("${candidate}")
}

domain_control_edge_runtime_service_name() {
  local provider env_file
  env_file="/etc/default/edge-runtime"
  provider="$(awk -F= '$1=="EDGE_PROVIDER"{print $2; exit}' "${env_file}" 2>/dev/null || echo "none")"
  case "${provider}" in
    nginx-stream) printf '%s\n' "nginx" ;;
    go) printf '%s\n' "edge-mux.service" ;;
    *) return 1 ;;
  esac
}

domain_control_edge_runtime_http_on_80() {
  local env_file provider active http_port
  env_file="/etc/default/edge-runtime"
  provider="$(awk -F= '$1=="EDGE_PROVIDER"{print $2; exit}' "${env_file}" 2>/dev/null || echo "none")"
  active="$(awk -F= '$1=="EDGE_ACTIVATE_RUNTIME"{print $2; exit}' "${env_file}" 2>/dev/null || echo "false")"
  http_port="$(awk -F= '$1=="EDGE_PUBLIC_HTTP_PORT"{print $2; exit}' "${env_file}" 2>/dev/null || echo "80")"
  [[ "${provider}" != "none" ]] || return 1
  case "${active}" in
    1|true|TRUE|yes|YES|on|ON) ;;
    *) return 1 ;;
  esac
  [[ "${http_port}" == "80" ]]
}

domain_control_stop_edge_runtime_if_needed() {
  local svc=""
  if domain_control_edge_runtime_http_on_80; then
    svc="$(domain_control_edge_runtime_service_name 2>/dev/null || true)"
    if [[ -n "${svc}" && "${svc}" != "nginx" ]] && svc_exists "${svc}" && svc_is_active "${svc}"; then
      if systemctl stop "${svc}" >/dev/null 2>&1; then
        if svc_is_active "${svc}"; then
          DOMAIN_CTRL_STOP_FAILURES+=("${svc}: masih aktif setelah stop")
        else
          domain_control_append_stopped_service "${svc}"
        fi
      else
        DOMAIN_CTRL_STOP_FAILURES+=("${svc}: gagal dihentikan")
      fi
    fi
  fi
}

domain_control_restart_active_tls_runtime_consumers() {
  if [[ "${DOMAIN_CTRL_RUNTIME_SNAPSHOT_VALID:-0}" == "1" ]]; then
    domain_control_restore_tls_runtime_consumers_from_snapshot "${DOMAIN_CTRL_STOPPED_SERVICES[@]}"
    return $?
  fi

  local edge_svc
  if svc_exists sshws-stunnel && svc_is_active sshws-stunnel; then
    systemctl restart sshws-stunnel >/dev/null 2>&1 || {
      warn "Gagal restart sshws-stunnel setelah update cert."
      return 1
    }
    svc_is_active sshws-stunnel || {
      warn "sshws-stunnel tidak active setelah update cert."
      return 1
    }
  fi
  edge_svc="$(domain_control_edge_runtime_service_name 2>/dev/null || true)"
  if [[ -n "${edge_svc}" && "${edge_svc}" != "nginx" ]] && svc_exists "${edge_svc}" && svc_is_active "${edge_svc}"; then
    systemctl restart "${edge_svc}" >/dev/null 2>&1 || {
      warn "Gagal restart ${edge_svc} setelah update cert."
      return 1
    }
    svc_is_active "${edge_svc}" || {
      warn "${edge_svc} tidak active setelah update cert."
      return 1
    }
  fi
  return 0
}

domain_control_clear_runtime_snapshot() {
  DOMAIN_CTRL_RUNTIME_SNAPSHOT_VALID="0"
  DOMAIN_CTRL_NGINX_WAS_ACTIVE="0"
  DOMAIN_CTRL_TLS_RUNTIME_ACTIVE_SERVICES=()
}

domain_control_capture_runtime_snapshot() {
  local edge_svc
  domain_control_clear_runtime_snapshot

  if svc_exists nginx && svc_is_active nginx; then
    DOMAIN_CTRL_NGINX_WAS_ACTIVE="1"
  fi
  if svc_exists sshws-stunnel && svc_is_active sshws-stunnel; then
    DOMAIN_CTRL_TLS_RUNTIME_ACTIVE_SERVICES+=("sshws-stunnel")
  fi
  edge_svc="$(domain_control_edge_runtime_service_name 2>/dev/null || true)"
  if [[ -n "${edge_svc}" && "${edge_svc}" != "nginx" && "${edge_svc}" != "sshws-stunnel" ]] && svc_exists "${edge_svc}" && svc_is_active "${edge_svc}"; then
    DOMAIN_CTRL_TLS_RUNTIME_ACTIVE_SERVICES+=("${edge_svc}")
  fi
  DOMAIN_CTRL_RUNTIME_SNAPSHOT_VALID="1"
}

domain_control_tls_service_was_active() {
  local svc="${1:-}"
  local item
  for item in "${DOMAIN_CTRL_TLS_RUNTIME_ACTIVE_SERVICES[@]}"; do
    [[ "${item}" == "${svc}" ]] && return 0
  done
  return 1
}

domain_control_restore_tls_runtime_consumers_from_snapshot() {
  local -a skipped_services=("$@")
  local edge_svc svc
  local rc=0
  local -a targets=("sshws-stunnel")
  local skipped

  edge_svc="$(domain_control_edge_runtime_service_name 2>/dev/null || true)"
  if [[ -n "${edge_svc}" && "${edge_svc}" != "nginx" && "${edge_svc}" != "sshws-stunnel" ]]; then
    targets+=("${edge_svc}")
  fi

  for svc in "${targets[@]}"; do
    for skipped in "${skipped_services[@]}"; do
      [[ "${skipped}" == "${svc}" ]] && continue 2
    done
    if domain_control_tls_service_was_active "${svc}"; then
      if ! svc_exists "${svc}"; then
        warn "Service TLS ${svc} tidak ditemukan saat rollback."
        rc=1
        continue
      fi
      if ! svc_restart_checked "${svc}" 60; then
        warn "Gagal memulihkan service TLS ${svc} saat rollback."
        rc=1
      fi
    elif svc_exists "${svc}" && svc_is_active "${svc}"; then
      if ! svc_stop_checked "${svc}" 60; then
        warn "Gagal mengembalikan ${svc} ke state inactive saat rollback."
        rc=1
      fi
    fi
  done

  return "${rc}"
}

domain_control_restore_cert_runtime_after_rollback() {
  local notes_name="$1"
  local notes_ref="()"
  local rc=0
  declare -n notes_ref="${notes_name}"

  if [[ "${DOMAIN_CTRL_NGINX_WAS_ACTIVE:-0}" == "1" ]]; then
    if ! svc_restart_checked nginx 60; then
      notes_ref+=("restore nginx rollback gagal")
      rc=1
    fi
  elif svc_exists nginx && svc_is_active nginx; then
    if ! svc_stop_checked nginx 60; then
      notes_ref+=("nginx rollback gagal dikembalikan ke inactive")
      rc=1
    fi
  fi
  if ! domain_control_restore_tls_runtime_consumers_from_snapshot; then
    notes_ref+=("reload consumer TLS rollback gagal")
    rc=1
  fi
  return "${rc}"
}

domain_control_restore_after_cert_success() {
  local svc
  for svc in "${DOMAIN_CTRL_STOPPED_SERVICES[@]}"; do
    [[ "${svc}" == "nginx" ]] && continue
    if svc_exists "${svc}"; then
      svc_start_checked "${svc}" 60 || {
        warn "Gagal restore service ${svc} setelah update cert."
        return 1
      }
    fi
  done
  domain_control_clear_stopped_services
  return 0
}

domain_control_restore_stopped_services() {
  if (( ${#DOMAIN_CTRL_STOPPED_SERVICES[@]} == 0 )); then
    return 0
  fi

  local svc
  local rc=0
  for svc in "${DOMAIN_CTRL_STOPPED_SERVICES[@]}"; do
    if svc_exists "${svc}"; then
      if ! svc_start_checked "${svc}" 60; then
        warn "Gagal restore service: ${svc}"
        rc=1
      fi
    fi
  done
  return "${rc}"
}

domain_control_clear_stopped_services() {
  DOMAIN_CTRL_STOPPED_SERVICES=()
  DOMAIN_CTRL_STOP_FAILURES=()
}

domain_control_restore_on_exit() {
  # Safety net: jika proses domain control gagal di tengah (die/exit),
  # service yang sebelumnya aktif dipulihkan otomatis.
  if [[ "${DOMAIN_CTRL_TXN_ACTIVE:-0}" == "1" ]]; then
    local -a txn_notes=()
    warn "Domain Control berhenti sebelum transaksi domain selesai. Mencoba rollback snapshot..."
    if ! domain_control_txn_restore txn_notes; then
      if (( ${#txn_notes[@]} > 0 )); then
        warn "Rollback transaksi domain belum bersih: $(IFS=' | '; echo "${txn_notes[*]}")"
      fi
    fi
    domain_control_clear_runtime_snapshot
  fi
  if (( ${#DOMAIN_CTRL_STOPPED_SERVICES[@]} > 0 )); then
    warn "Domain Control berhenti sebelum selesai. Mencoba restore service yang tadi dihentikan..."
    if domain_control_restore_stopped_services; then
      domain_control_clear_stopped_services
    else
      warn "Sebagian service gagal dipulihkan pada EXIT safety-net."
    fi
  fi
}

install_acme_and_issue_cert() {
  local email
  email="$(rand_email)"
  log "Email acme.sh (acak): $email"

  if [[ "${ACME_CERT_MODE:-standalone}" != "dns_cf_wildcard" ]]; then
    if ! stop_conflicting_services; then
      die "Gagal menghentikan service konflik: $(IFS=' | '; echo "${DOMAIN_CTRL_STOP_FAILURES[*]}")"
    fi
  else
    domain_control_clear_stopped_services
  fi

  local acme_tmpdir acme_src_dir acme_tgz acme_install_log
  acme_tmpdir="$(mktemp -d)"
  acme_tgz="${acme_tmpdir}/acme.tar.gz"
  acme_install_log="${acme_tmpdir}/acme-install.log"
  acme_src_dir=""

  if download_file_checked "${ACME_SH_TARBALL_URL}" "${acme_tgz}" "acme.sh tarball"; then
    if tar -xzf "${acme_tgz}" -C "${acme_tmpdir}" >/dev/null 2>&1; then
      acme_src_dir="$(find "${acme_tmpdir}" -maxdepth 1 -type d -name 'acme.sh-*' -print -quit)"
    fi
  fi

  if [[ -z "${acme_src_dir:-}" || ! -f "${acme_src_dir}/acme.sh" ]]; then
    warn "Source bundle acme.sh tidak tersedia, fallback ke single-file installer."
    acme_src_dir="${acme_tmpdir}/acme-single"
    mkdir -p "${acme_src_dir}"
    download_file_or_die "${ACME_SH_SCRIPT_URL}" "${acme_src_dir}/acme.sh" "" "acme.sh script"
  fi

  chmod 700 "${acme_src_dir}/acme.sh"
  if ! (cd "${acme_src_dir}" && bash ./acme.sh --install --home /root/.acme.sh --accountemail "$email") >"${acme_install_log}" 2>&1; then
    warn "Install acme.sh gagal. Ringkasan log:"
    sed -n '1,120p' "${acme_install_log}" >&2 || true
    rm -rf "${acme_tmpdir}" >/dev/null 2>&1 || true
    die "Gagal install acme.sh dari ref ${ACME_SH_INSTALL_REF}."
  fi
  rm -rf "${acme_tmpdir}" >/dev/null 2>&1 || true

  export PATH="/root/.acme.sh:${PATH}"
  [[ -x /root/.acme.sh/acme.sh ]] || die "acme.sh tidak ditemukan setelah proses install."
  /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null || true

  mkdir -p "${CERT_DIR}"
  chmod 700 "${CERT_DIR}"

  if [[ "${ACME_CERT_MODE:-standalone}" == "dns_cf_wildcard" ]]; then
    [[ -n "${ACME_ROOT_DOMAIN:-}" ]] || die "ACME_ROOT_DOMAIN kosong (mode dns_cf_wildcard)."
    [[ -n "${DOMAIN:-}" ]] || die "DOMAIN kosong (mode dns_cf_wildcard)."
    [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]] || die "CLOUDFLARE_API_TOKEN kosong untuk mode wildcard dns_cf."
    log "Issue sertifikat wildcard untuk ${DOMAIN} via acme.sh (dns_cf)..."

    if [[ ! -s /root/.acme.sh/dnsapi/dns_cf.sh ]]; then
      warn "dns_cf hook tidak ditemukan, mencoba bootstrap dari ref ${ACME_SH_INSTALL_REF} ..."
      mkdir -p /root/.acme.sh/dnsapi
      download_file_or_die "${ACME_SH_DNS_CF_HOOK_URL}" /root/.acme.sh/dnsapi/dns_cf.sh "" "acme dns_cf hook"
      chmod 700 /root/.acme.sh/dnsapi/dns_cf.sh >/dev/null 2>&1 || true
    fi
    [[ -s /root/.acme.sh/dnsapi/dns_cf.sh ]] || die "Hook dns_cf tetap tidak ditemukan setelah bootstrap."

    if ! cf_api GET "/user/tokens/verify" >/dev/null 2>&1; then
      die "Token Cloudflare tidak valid/kurang scope. Butuh minimal: Zone:DNS Edit + Zone:Read untuk zone domain."
    fi

    export CF_Token="$CLOUDFLARE_API_TOKEN"
    [[ -n "${CF_ACCOUNT_ID:-}" ]] && export CF_Account_ID="$CF_ACCOUNT_ID"
    [[ -n "${CF_ZONE_ID:-}" ]] && export CF_Zone_ID="$CF_ZONE_ID"

    /root/.acme.sh/acme.sh --issue --force --dns dns_cf \
      -d "$DOMAIN" -d "*.$DOMAIN" \
      || die "Gagal issue sertifikat wildcard via dns_cf (pastikan token Cloudflare valid)."

    /root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
      --key-file "$CERT_PRIVKEY" \
      --fullchain-file "$CERT_FULLCHAIN" \
      --reloadcmd "/bin/true" >/dev/null || {
        warn "Gagal install-cert wildcard ke ${CERT_DIR}."
        return 1
      }
  else
    log "Issue sertifikat untuk $DOMAIN via acme.sh (standalone port 80)..."
    /root/.acme.sh/acme.sh --issue --force --standalone -d "$DOMAIN" --httpport 80 \
      || die "Gagal issue sertifikat (pastikan port 80 terbuka & DNS domain mengarah ke VPS)."

    /root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
      --key-file "$CERT_PRIVKEY" \
      --fullchain-file "$CERT_FULLCHAIN" \
      --reloadcmd "/bin/true" >/dev/null || {
        warn "Gagal install-cert standalone ke ${CERT_DIR}."
        return 1
      }
  fi

  chmod 600 "$CERT_PRIVKEY" "$CERT_FULLCHAIN"

  log "Sertifikat tersimpan:"
  log "  - $CERT_FULLCHAIN"
  log "  - $CERT_PRIVKEY"
}

domain_control_activate_cert_runtime_after_install() {
  if ! domain_control_restart_active_tls_runtime_consumers; then
    warn "Gagal restart consumer TLS tambahan setelah update cert."
    return 1
  fi
  if ! domain_control_restore_after_cert_success; then
    warn "Gagal memulihkan service konflik setelah update cert."
    return 1
  fi
  return 0
}

domain_control_apply_nginx_domain() {
  local domain="$1"
  local applied_domain
  local backup candidate preflight_rc=0
  domain="$(printf '%s' "${domain}" | tr -d '\r\n' | awk '{print $1}' | tr -d ';')"
  [[ -n "${domain}" ]] || die "Domain kosong."
  [[ -f "${NGINX_CONF}" ]] || die "Nginx conf tidak ditemukan: ${NGINX_CONF}"
  ensure_path_writable "${NGINX_CONF}"

  backup="${WORK_DIR}/xray.conf.domain-backup.$(date +%s)"
  cp -a "${NGINX_CONF}" "${backup}" || die "Gagal membuat backup nginx conf."
  candidate="$(mktemp "${WORK_DIR}/xray.conf.domain-candidate.XXXXXX" 2>/dev/null || true)"
  [[ -n "${candidate}" ]] || die "Gagal membuat candidate nginx conf."

  if ! sed -E "s|^([[:space:]]*server_name[[:space:]]+)[^;]+;|\\1${domain};|g" "${NGINX_CONF}" > "${candidate}"; then
    rm -f "${candidate}" >/dev/null 2>&1 || true
    die "Gagal update server_name di nginx conf."
  fi

  applied_domain="$(grep -E '^[[:space:]]*server_name[[:space:]]+' "${candidate}" 2>/dev/null | head -n1 | sed -E 's/^[[:space:]]*server_name[[:space:]]+//; s/;.*$//' | awk '{print $1}' | tr -d ';' || true)"
  if [[ -z "${applied_domain}" || "${applied_domain}" != "${domain}" ]]; then
    rm -f "${candidate}" >/dev/null 2>&1 || true
    die "server_name nginx tidak sesuai setelah update (expect=${domain}, got=${applied_domain:-<kosong>})."
  fi

  if nginx_conf_test_with_override "${NGINX_CONF}" "${candidate}"; then
    :
  else
    preflight_rc=$?
    rm -f "${candidate}" >/dev/null 2>&1 || true
    if (( preflight_rc == 1 )); then
      die "Konfigurasi nginx candidate invalid sebelum diterapkan ke file live."
    fi
    die "Preflight nginx candidate tidak tersedia. Batalkan apply domain agar nginx conf tidak diuji hanya setelah file live diganti."
  fi

  local nginx_mode nginx_uid nginx_gid nginx_tmp_target=""
  nginx_mode="$(stat -c '%a' "${NGINX_CONF}" 2>/dev/null || echo '644')"
  nginx_uid="$(stat -c '%u' "${NGINX_CONF}" 2>/dev/null || echo '0')"
  nginx_gid="$(stat -c '%g' "${NGINX_CONF}" 2>/dev/null || echo '0')"
  nginx_tmp_target="$(mktemp "$(dirname "${NGINX_CONF}")/.xray.conf.new.XXXXXX" 2>/dev/null || true)"
  if [[ -z "${nginx_tmp_target}" ]] || ! cp -f -- "${candidate}" "${nginx_tmp_target}" >/dev/null 2>&1; then
    rm -f "${candidate}" >/dev/null 2>&1 || true
    cp -a "${backup}" "${NGINX_CONF}" >/dev/null 2>&1 || die "Gagal memasang candidate nginx conf; restore backup nginx juga gagal."
    die "Gagal mengganti nginx conf secara atomic."
  fi
  chmod "${nginx_mode}" "${nginx_tmp_target}" 2>/dev/null || chmod 644 "${nginx_tmp_target}" 2>/dev/null || true
  chown "${nginx_uid}:${nginx_gid}" "${nginx_tmp_target}" 2>/dev/null || true
  if ! mv -f "${nginx_tmp_target}" "${NGINX_CONF}" >/dev/null 2>&1; then
    rm -f "${nginx_tmp_target}" >/dev/null 2>&1 || true
    rm -f "${candidate}" >/dev/null 2>&1 || true
    cp -a "${backup}" "${NGINX_CONF}" >/dev/null 2>&1 || die "Gagal memasang candidate nginx conf; restore backup nginx juga gagal."
    die "Gagal mengganti nginx conf secara atomic."
  fi
  rm -f "${candidate}" >/dev/null 2>&1 || true

  if ! nginx -t >/dev/null 2>&1; then
    warn "nginx -t gagal setelah update domain, rollback ke backup."
    cp -a "${backup}" "${NGINX_CONF}" >/dev/null 2>&1 || die "Konfigurasi nginx invalid setelah ubah domain; restore backup nginx gagal."
    nginx -t >/dev/null 2>&1 || die "Konfigurasi nginx invalid setelah ubah domain; backup nginx juga tidak valid saat rollback."
    die "Konfigurasi nginx invalid setelah ubah domain."
  fi

  if ! svc_restart_checked nginx 60; then
    warn "Restart nginx gagal setelah update domain, rollback ke backup."
    cp -a "${backup}" "${NGINX_CONF}" >/dev/null 2>&1 || die "Gagal restart nginx setelah ubah domain; restore backup nginx juga gagal."
    nginx -t >/dev/null 2>&1 || die "Gagal restart nginx setelah ubah domain; backup nginx tidak valid saat rollback."
    if ! svc_restart_checked nginx 60; then
      die "Gagal restart nginx setelah ubah domain; rollback nginx juga gagal."
    fi
    die "Gagal restart nginx setelah ubah domain. Perubahan nginx sudah di-rollback."
  fi

  if ! sync_xray_domain_file "${applied_domain}"; then
    warn "Compat domain file gagal disinkronkan ke ${XRAY_DOMAIN_FILE}. Domain nginx tetap aktif; sinkronkan manual bila perlu."
  fi

  log "server_name nginx diperbarui ke: ${domain}"
}

domain_control_set_domain_now() {
  if [[ "${DOMAIN_CONTROL_LOCK_HELD:-0}" != "1" ]]; then
    domain_control_run_locked domain_control_set_domain_now "$@"
    return $?
  fi
  have_cmd curl || die "curl tidak ditemukan."
  have_cmd jq || die "jq tidak ditemukan."

  if domain_menu_v2; then
    :
  else
    local domain_input_rc=$?
    if (( domain_input_rc == 2 )); then
      warn "Set Domain dibatalkan. Kembali ke menu Domain Control."
      return 0
    fi
    return "${domain_input_rc}"
  fi
  local spin_log=""
  if ! ui_run_logged_command_with_spinner spin_log "Menerapkan domain & sertifikat" domain_control_set_domain_after_prompt; then
    warn "Set Domain gagal."
    hr
    tail -n 60 "${spin_log}" 2>/dev/null || true
    hr
    rm -f "${spin_log}" >/dev/null 2>&1 || true
    pause
    return 1
  fi
  rm -f "${spin_log}" >/dev/null 2>&1 || true
  hr
  log "Domain aktif sekarang: ${DOMAIN}"
  log "Refresh ACCOUNT INFO tidak dijalankan otomatis dari flow Set Domain."
  log "Gunakan Domain Control > Refresh Account Info bila artefak akun perlu diselaraskan."
  pause
}

domain_control_set_domain_after_prompt() {
  local cert_backup_dir
  local nginx_conf_backup
  local compat_snapshot_dir=""
  local rollback_notes=()
  local cf_dns_snapshot=""
  cert_backup_dir="${WORK_DIR}/cert-snapshot.$(date +%s).$$"
  nginx_conf_backup="${WORK_DIR}/xray.conf.pre-domain-change.$(date +%s).$$"
  compat_snapshot_dir="${WORK_DIR}/compat-domain-snapshot.$(date +%s).$$"
  domain_control_capture_runtime_snapshot
  if ! cert_snapshot_create "${cert_backup_dir}"; then
    die "Gagal membuat snapshot sertifikat sebelum set domain."
  fi
  cp -a "${NGINX_CONF}" "${nginx_conf_backup}" || die "Gagal membuat backup nginx sebelum set domain."
  if ! domain_control_optional_file_snapshot_create "${XRAY_DOMAIN_FILE}" "${compat_snapshot_dir}" compat_domain; then
    rm -rf "${compat_snapshot_dir}" >/dev/null 2>&1 || true
    die "Gagal membuat snapshot compat domain sebelum set domain."
  fi
  domain_control_txn_begin "${cert_backup_dir}" "${nginx_conf_backup}" "${compat_snapshot_dir}" "${DOMAIN}"

  if ! install_acme_and_issue_cert; then
    warn "Issue/install sertifikat gagal. Mengembalikan snapshot transaksi domain..."
    domain_control_txn_restore rollback_notes || true
    if (( ${#rollback_notes[@]} > 0 )); then
      die "Set domain dibatalkan karena issue/install sertifikat gagal; rollback juga bermasalah: $(IFS=' | '; echo "${rollback_notes[*]}")."
    fi
    die "Set domain dibatalkan karena issue/install sertifikat gagal; sertifikat sebelumnya berhasil dipulihkan."
  fi

  if ! ( domain_control_apply_nginx_domain "${DOMAIN}" ); then
    warn "Apply domain ke nginx gagal. Mengembalikan snapshot transaksi domain..."
    domain_control_txn_restore rollback_notes || true
    if (( ${#rollback_notes[@]} > 0 )); then
      die "Set domain dibatalkan karena update nginx gagal; rollback juga bermasalah: $(IFS=' | '; echo "${rollback_notes[*]}")."
    fi
    die "Set domain dibatalkan karena update nginx gagal; snapshot transaksi berhasil dipulihkan."
  fi

  if [[ "${ACME_CERT_MODE:-standalone}" == "dns_cf_wildcard" ]]; then
    [[ -n "${CF_ZONE_ID:-}" ]] || die "CF_ZONE_ID kosong untuk flow wildcard dns_cf."
    [[ -n "${VPS_IPV4:-}" ]] || VPS_IPV4="$(get_public_ipv4)"
    cf_dns_snapshot="$(mktemp "${WORK_DIR}/cf-domain-snapshot.XXXXXX" 2>/dev/null || true)"
    [[ -n "${cf_dns_snapshot}" ]] || die "Gagal menyiapkan snapshot DNS Cloudflare sebelum apply domain."
    if ! cf_snapshot_relevant_a_records "${CF_ZONE_ID}" "${DOMAIN}" "${VPS_IPV4}" "${cf_dns_snapshot}"; then
      rm -f "${cf_dns_snapshot}" >/dev/null 2>&1 || true
      die "Gagal membuat snapshot DNS Cloudflare sebelum apply domain."
    fi
    domain_control_txn_register_cf_snapshot "${CF_ZONE_ID}" "${DOMAIN}" "${VPS_IPV4}" "${cf_dns_snapshot}"
    if ! cf_prepare_subdomain_a_record "${CF_ZONE_ID}" "${DOMAIN}" "${VPS_IPV4}" "${CF_PROXIED:-false}"; then
      warn "Apply DNS Cloudflare gagal. Mengembalikan snapshot transaksi domain..."
      domain_control_txn_restore rollback_notes || true
      if (( ${#rollback_notes[@]} > 0 )); then
        die "Set domain dibatalkan karena apply DNS Cloudflare gagal; rollback juga bermasalah: $(IFS=' | '; echo "${rollback_notes[*]}")."
      fi
      die "Set domain dibatalkan karena apply DNS Cloudflare gagal; snapshot transaksi berhasil dipulihkan."
    fi
    domain_control_txn_mark_cf_prepared
  fi

  if ! domain_control_activate_cert_runtime_after_install; then
    warn "Aktivasi runtime cert/domain gagal. Mengembalikan snapshot transaksi domain..."
    domain_control_txn_restore rollback_notes || true
    if (( ${#rollback_notes[@]} > 0 )); then
      die "Set domain dibatalkan karena aktivasi runtime cert/domain gagal; rollback juga bermasalah: $(IFS=' | '; echo "${rollback_notes[*]}")."
    fi
    die "Set domain dibatalkan karena aktivasi runtime cert/domain gagal; snapshot transaksi berhasil dipulihkan."
  fi
  main_info_cache_invalidate
  domain_control_txn_clear
  rm -f "${nginx_conf_backup}" >/dev/null 2>&1 || true
  rm -rf "${compat_snapshot_dir}" >/dev/null 2>&1 || true
  rm -rf "${cert_backup_dir}" >/dev/null 2>&1 || true
  rm -f "${cf_dns_snapshot}" >/dev/null 2>&1 || true
  domain_control_clear_runtime_snapshot
}

domain_control_refresh_account_info_now() {
  local domain ip summary xray_count ssh_count total_count xray_preview ssh_preview preview_report="" dry_run_report=""
  local geo="" geo_ip="" target_isp="-" target_country="-"
  local scope_choice="" scope="all" scope_label="Semua (Xray + SSH)"
  local spin_log=""
  local ask_rc=0

  title
  echo "6) Domain Control > Refresh Account Info"
  hr

  domain="$(normalize_domain_token "$(detect_domain)")"
  if [[ -z "${domain}" ]]; then
    warn "Domain aktif tidak terdeteksi."
    pause
    return 1
  fi
  ip="$(normalize_ip_token "$(detect_public_ip_ipapi 2>/dev/null || detect_public_ip 2>/dev/null || true)")"
  if [[ -n "${ip}" ]]; then
    geo="$(main_info_geo_lookup "${ip}" 2>/dev/null || true)"
    IFS='|' read -r geo_ip target_isp target_country <<<"${geo}"
    [[ -n "${geo_ip}" && "${geo_ip}" != "-" ]] && ip="${geo_ip}"
    [[ -n "${target_isp}" ]] || target_isp="-"
    [[ -n "${target_country}" ]] || target_country="-"
  fi
  echo "Pilih scope refresh:"
  echo "  1) Semua (Xray + SSH)"
  echo "  2) Xray only"
  echo "  3) SSH only"
  echo "  0) Back"
  hr
  while true; do
    if ! read -r -p "Pilih scope (1-3/0): " scope_choice; then
      echo
      return 0
    fi
    case "${scope_choice}" in
      1) scope="all" ; scope_label="Semua (Xray + SSH)" ; break ;;
      2) scope="xray" ; scope_label="Xray only" ; break ;;
      3) scope="ssh" ; scope_label="SSH only" ; break ;;
      0|kembali|k|back|b) return 0 ;;
      *) echo "Pilihan tidak valid." ;;
    esac
  done

  summary="$(account_info_refresh_targets_summary "${scope}" 5)"
  IFS='|' read -r xray_count ssh_count total_count xray_preview ssh_preview <<<"${summary}"

  echo "Domain aktif : ${domain}"
  echo "IP aktif     : ${ip:-tidak terdeteksi}"
  echo "ISP target   : ${target_isp:-"-"}"
  echo "Country tgt  : ${target_country:-"-"}"
  echo "Scope        : ${scope_label}"
  if [[ "${scope}" == "all" || "${scope}" == "xray" ]]; then
    echo "Target Xray  : ${xray_count:-0}"
    echo "Preview Xray : ${xray_preview:--}"
  fi
  if [[ "${scope}" == "all" || "${scope}" == "ssh" ]]; then
    echo "Target SSH   : ${ssh_count:-0}"
    echo "Preview SSH  : ${ssh_preview:--}"
  fi
  echo "Total target : ${total_count:-0}"
  preview_report="$(preview_report_path_prepare "account-info-refresh-targets" 2>/dev/null || true)"
  if [[ -n "${preview_report}" ]] && account_info_refresh_targets_report_write "${scope}" "${preview_report}"; then
    echo "Daftar target lengkap:"
    echo "  ${preview_report}"
  else
    rm -f "${preview_report}" >/dev/null 2>&1 || true
    preview_report=""
  fi
  dry_run_report="$(preview_report_path_prepare "account-info-refresh-dryrun" 2>/dev/null || true)"
  if [[ -n "${dry_run_report}" ]] && account_info_refresh_dry_run_report_write "${scope}" "${dry_run_report}" "${domain}" "${ip}" "${target_isp}" "${target_country}"; then
    echo "Dry-run report : ${dry_run_report}"
  else
    rm -f "${dry_run_report}" >/dev/null 2>&1 || true
    dry_run_report=""
  fi
  hr

  if [[ -z "${total_count}" || "${total_count}" == "0" ]]; then
    warn "Tidak ada ACCOUNT INFO yang perlu direfresh."
    pause
    return 0
  fi

  echo "Aksi:"
  echo "  1) Preview only"
  echo "  2) Dry-run rendered diff"
  echo "  3) Refresh sekarang"
  echo "  0) Back"
  hr
  local refresh_action=""
  while true; do
    if ! read -r -p "Pilih aksi (1-3/0): " refresh_action; then
      echo
      return 0
    fi
    case "${refresh_action}" in
      1)
        if [[ -n "${preview_report}" && -f "${preview_report}" ]]; then
          preview_report_show_file "${preview_report}" || warn "Gagal membuka preview target refresh."
        else
          warn "Preview target tidak tersedia."
        fi
        hr
        pause
        return 0
        ;;
      2)
        if [[ -n "${dry_run_report}" && -f "${dry_run_report}" ]]; then
          preview_report_show_file "${dry_run_report}" || warn "Gagal membuka dry-run refresh."
        else
          warn "Dry-run refresh tidak tersedia."
        fi
        hr
        pause
        return 0
        ;;
      3) break ;;
      0|kembali|k|back|b) return 0 ;;
      *) echo "Pilihan tidak valid." ;;
    esac
  done

  if ! confirm_yn_or_back "Refresh ACCOUNT INFO untuk scope ${scope_label} ini sekarang?"; then
    ask_rc=$?
    if (( ask_rc == 2 )); then
      warn "Refresh ACCOUNT INFO dibatalkan (kembali)."
    else
      warn "Refresh ACCOUNT INFO dibatalkan."
    fi
    pause
    return 0
  fi

  if ui_run_logged_command_with_spinner spin_log "Refresh ACCOUNT INFO (${scope_label})" account_refresh_all_info_files "${domain}" "${ip}" "${scope}"; then
    if [[ "${scope}" == "ssh" ]]; then
      log "ACCOUNT INFO SSH berhasil disinkronkan."
    elif account_info_domain_sync_state_write "${domain}"; then
      log "ACCOUNT INFO berhasil disinkronkan."
    else
      warn "ACCOUNT INFO berhasil disinkronkan, tetapi state sinkronisasi domain gagal disimpan."
    fi
    rm -f "${spin_log}" >/dev/null 2>&1 || true
    pause
    return 0
  fi

  warn "Refresh ACCOUNT INFO gagal."
  hr
  tail -n 60 "${spin_log}" 2>/dev/null || true
  hr
  rm -f "${spin_log}" >/dev/null 2>&1 || true
  rm -f "${preview_report}" "${dry_run_report}" >/dev/null 2>&1 || true
  pause
  return 1
}

domain_control_sync_compat_domain_now() {
  local domain ask_rc=0 current_compat=""
  local snapshot_dir="" preview_report=""
  if [[ "${DOMAIN_CONTROL_LOCK_HELD:-0}" != "1" ]]; then
    domain_control_run_locked domain_control_sync_compat_domain_now "$@"
    return $?
  fi

  title
  echo "6) Domain Control > Sync Compat Domain File"
  hr

  domain="$(normalize_domain_token "$(detect_domain)")"
  if [[ -z "${domain}" ]]; then
    warn "Domain aktif tidak terdeteksi."
    pause
    return 1
  fi

  echo "Domain aktif    : ${domain}"
  echo "Compat file     : ${XRAY_DOMAIN_FILE}"
  current_compat="$(head -n1 "${XRAY_DOMAIN_FILE}" 2>/dev/null | tr -d '\r' | awk '{print $1}' | tr -d ';' || true)"
  echo "Compat saat ini : ${current_compat:-"(kosong)"}"
  echo "Catatan         : ini adalah repair artefak kompatibilitas ke domain aktif, bukan set domain baru."
  preview_report="$(preview_report_path_prepare "compat-domain-sync" 2>/dev/null || true)"
  if [[ -n "${preview_report}" ]]; then
    {
      printf 'Current compat : %s\n' "${current_compat:-"(kosong)"}"
      printf 'Target domain  : %s\n' "${domain}"
      printf '\n'
      printf -- '--- current\n'
      printf -- '+++ target\n'
      printf -- '@@ compat-domain @@\n'
      printf -- '-%s\n' "${current_compat:-"(kosong)"}"
      printf -- '+%s\n' "${domain}"
    } > "${preview_report}" 2>/dev/null || true
    [[ -f "${preview_report}" ]] && echo "Preview repair : ${preview_report}"
  fi
  hr

  if [[ -n "${current_compat}" && "${current_compat}" == "${domain}" ]]; then
    log "Compat domain file sudah sinkron dengan domain aktif."
    pause
    return 0
  fi

  if ! confirm_yn_or_back "Sinkronkan compat domain file ke domain aktif sekarang?"; then
    ask_rc=$?
    if (( ask_rc == 2 )); then
      warn "Sinkronisasi compat domain dibatalkan (kembali)."
    else
      warn "Sinkronisasi compat domain dibatalkan."
    fi
    pause
    return 0
  fi

  snapshot_dir="$(mktemp -d "${WORK_DIR}/.compat-domain-sync.XXXXXX" 2>/dev/null || true)"
  if [[ -n "${snapshot_dir}" ]]; then
    domain_control_optional_file_snapshot_create "${XRAY_DOMAIN_FILE}" "${snapshot_dir}" compat_domain >/dev/null 2>&1 || true
  fi

  if sync_xray_domain_file "${domain}"; then
    log "Compat domain file berhasil disinkronkan ke ${domain}."
    [[ -n "${snapshot_dir}" ]] && rm -rf "${snapshot_dir}" >/dev/null 2>&1 || true
    pause
    return 0
  fi

  if [[ -n "${snapshot_dir}" && -d "${snapshot_dir}" ]]; then
    domain_control_optional_file_snapshot_restore "${XRAY_DOMAIN_FILE}" "${snapshot_dir}" compat_domain >/dev/null 2>&1 || true
    rm -rf "${snapshot_dir}" >/dev/null 2>&1 || true
  fi
  warn "Sinkronisasi compat domain file gagal."
  pause
  return 1
}

domain_control_show_info() {
  title
  echo "6) Domain Control > Current Domain"
  hr
  echo "Domain aktif : $(detect_domain)"
  echo "Cert file    : ${CERT_FULLCHAIN}"
  echo "Key file     : ${CERT_PRIVKEY}"
  if [[ -s "${CERT_FULLCHAIN}" && -s "${CERT_PRIVKEY}" ]]; then
    echo "Status cert  : tersedia"
  else
    echo "Status cert  : belum tersedia / kosong"
  fi
  hr
  pause
}

domain_control_guard_check() {
  title
  echo "6) Domain Control > Guard Check"
  hr

  if [[ ! -x "${XRAY_DOMAIN_GUARD_BIN}" ]]; then
    warn "xray-domain-guard belum terpasang."
    warn "Jalankan setup.sh terbaru untuk mengaktifkan Domain & Cert Guard."
    hr
    pause
    return 0
  fi

  local rc=0 spin_log=""
  if ui_run_logged_command_with_spinner spin_log "Menjalankan guard check" "${XRAY_DOMAIN_GUARD_BIN}" check; then
    rc=0
  else
    rc=$?
  fi

  hr
  if [[ -n "${spin_log}" && -s "${spin_log}" ]]; then
    cat "${spin_log}" 2>/dev/null || true
    hr
  fi
  case "${rc}" in
    0) log "Domain & Cert Guard: sehat." ;;
    1) warn "Domain & Cert Guard: warning terdeteksi." ;;
    2) warn "Domain & Cert Guard: masalah critical terdeteksi." ;;
    *) warn "Domain & Cert Guard selesai dengan status ${rc}." ;;
  esac
  echo "Config path: ${XRAY_DOMAIN_GUARD_CONFIG_FILE}"
  if [[ -f "${XRAY_DOMAIN_GUARD_LOG_FILE}" ]]; then
    echo "Log path   : ${XRAY_DOMAIN_GUARD_LOG_FILE}"
  fi
  rm -f "${spin_log}" >/dev/null 2>&1 || true
  pause
  return "${rc}"
}

domain_control_guard_renew_if_needed() {
  if [[ "${DOMAIN_CONTROL_LOCK_HELD:-0}" != "1" ]]; then
    domain_control_run_locked domain_control_guard_renew_if_needed "$@"
    return $?
  fi
  title
  echo "6) Domain Control > Guard Renew"
  hr

  if [[ ! -x "${XRAY_DOMAIN_GUARD_BIN}" ]]; then
    warn "xray-domain-guard belum terpasang."
    hr
    pause
    return 0
  fi

  local ask_rc=0 rc=0 spin_log="" check_rc=0 check_log="" status_log=""
  if ui_run_logged_command_with_spinner check_log "Menjalankan guard preflight" "${XRAY_DOMAIN_GUARD_BIN}" check; then
    check_rc=0
  else
    check_rc=$?
  fi
  ui_run_logged_command_with_spinner status_log "Mengambil status guard terakhir" "${XRAY_DOMAIN_GUARD_BIN}" status >/dev/null 2>&1 || true

  hr
  if [[ -n "${check_log}" && -s "${check_log}" ]]; then
    cat "${check_log}" 2>/dev/null || true
    hr
  fi
  case "${check_rc}" in
    0) log "Preflight guard: sehat." ;;
    1) warn "Preflight guard: warning terdeteksi." ;;
    2) warn "Preflight guard: masalah critical terdeteksi." ;;
    *) warn "Preflight guard selesai dengan status ${check_rc}." ;;
  esac
  echo "Config path: ${XRAY_DOMAIN_GUARD_CONFIG_FILE}"
  if [[ -f "${XRAY_DOMAIN_GUARD_LOG_FILE}" ]]; then
    echo "Log path   : ${XRAY_DOMAIN_GUARD_LOG_FILE}"
  fi
  if [[ -n "${status_log}" && -s "${status_log}" ]]; then
    echo "Status/log terakhir:"
    cat "${status_log}" 2>/dev/null || true
    hr
  fi
  echo "Perkiraan artefak/runtime yang bisa disentuh:"
  echo "  - Cert files : ${CERT_FULLCHAIN}, ${CERT_PRIVKEY}"
  echo "  - Nginx conf : ${NGINX_CONF}"
  echo "  - Compat file: ${XRAY_DOMAIN_FILE}"
  echo "  - Service    : nginx, xray, sshws-stunnel, edge runtime (jika aktif)"
  echo "Command    : ${XRAY_DOMAIN_GUARD_BIN} renew-if-needed"
  echo "Catatan    : renew-if-needed dijalankan oleh binary eksternal dan dapat memperbarui cert/domain artefak terkait."
  hr
  rm -f "${check_log}" >/dev/null 2>&1 || true
  rm -f "${status_log}" >/dev/null 2>&1 || true

  if (( check_rc >= 1 )); then
    if ! confirm_yn_or_back "Preflight guard tidak bersih. Tetap lanjut ke renew-if-needed?"; then
      ask_rc=$?
      if (( ask_rc == 2 )); then
        warn "Guard renew dibatalkan (kembali)."
      else
        warn "Guard renew dibatalkan."
      fi
      pause
      return 0
    fi
  fi

  if ! confirm_yn_or_back "Lanjutkan guard renew-if-needed sekarang setelah melihat preflight di atas?"; then
    ask_rc=$?
    if (( ask_rc == 2 )); then
      warn "Dibatalkan dan kembali ke Domain Control."
      pause
      return 0
    fi
    warn "Dibatalkan oleh pengguna."
    pause
    return 0
  fi

  if ui_run_logged_command_with_spinner spin_log "Menjalankan guard renew" "${XRAY_DOMAIN_GUARD_BIN}" renew-if-needed; then
    rc=0
  else
    rc=$?
  fi

  hr
  if [[ -n "${spin_log}" && -s "${spin_log}" ]]; then
    cat "${spin_log}" 2>/dev/null || true
    hr
  fi
  case "${rc}" in
    0) log "Renew-if-needed selesai, status sehat." ;;
    1) warn "Renew-if-needed selesai dengan warning." ;;
    2) warn "Renew-if-needed selesai, namun masih ada kondisi critical." ;;
    *) warn "Renew-if-needed selesai dengan status ${rc}." ;;
  esac
  rm -f "${spin_log}" >/dev/null 2>&1 || true
  pause
  return "${rc}"
}

domain_control_menu() {
  local -a items=(
    "1|Set Domain"
    "2|Current Domain"
    "3|Guard Check"
    "4|Guard Renew"
    "5|Refresh Account Info"
    "6|Sync Compat Domain File"
    "0|Back"
  )
  while true; do
    ui_menu_screen_begin "6) Domain Control"
    ui_menu_render_options items 76
    hr
    if ! read -r -p "Pilih: " c; then
      echo
      break
    fi
    case "${c}" in
      1) menu_run_isolated_report "Set Domain" domain_control_set_domain_now ;;
      2) domain_control_show_info ;;
      3) menu_run_isolated_report "Domain Guard Check" domain_control_guard_check ;;
      4) menu_run_isolated_report "Domain Guard Renew" domain_control_guard_renew_if_needed ;;
      5) menu_run_isolated_report "Refresh Account Info" domain_control_refresh_account_info_now ;;
      6) menu_run_isolated_report "Sync Compat Domain" domain_control_sync_compat_domain_now ;;
      0|kembali|k|back|b) break ;;
      *) invalid_choice ;;
    esac
  done
}

need_python3() {
  have_cmd python3 || die "python3 tidak ditemukan. Install dulu: apt-get install -y python3"
}

gen_uuid() {
  if have_cmd uuidgen; then
    uuidgen
  else
    python3 - <<'PY'
import uuid
print(uuid.uuid4())
PY
  fi
}

pause() {
  read -r -p "Tekan ENTER untuk kembali..." _ || true
}

invalid_choice() {
  warn "Pilihan tidak valid"
  pause
}

run_action() {
  local label="$1"
  shift || true
  menu_run_isolated_report "${label}" "$@"
}

menu_run_isolated_report() {
  # Jalankan aksi dalam subshell supaya error tidak menutup script,
  # lalu kembalikan status ke caller dengan warning yang konsisten.
  # args: label cmd...
  local label="$1"
  shift || true
  local rc=0
  if _run_in_strict_subshell "$@"; then
    :
  else
    rc=$?
  fi

  if (( rc != 0 )); then
    warn "${label} gagal (rc=${rc}). Kembali ke menu sebelumnya."
  fi
  return "${rc}"
}

domain_control_restore_stopped_services_strict() {
  local attempts="${1:-2}"
  local attempt svc all_restored
  [[ "${attempts}" =~ ^[0-9]+$ ]] || attempts=2
  (( attempts > 0 )) || attempts=1

  for (( attempt=1; attempt<=attempts; attempt++ )); do
    domain_control_restore_stopped_services || true
    all_restored="true"
    for svc in "${DOMAIN_CTRL_STOPPED_SERVICES[@]}"; do
      if svc_exists "${svc}" && ! svc_is_active "${svc}"; then
        all_restored="false"
        break
      fi
    done
    if [[ "${all_restored}" == "true" ]]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

_run_in_strict_subshell() {
  local restore_opts rc=0
  restore_opts="$(set +o)"
  set +e
  ( set -euo pipefail; "$@" )
  rc=$?
  eval "${restore_opts}"
  return "${rc}"
}

menu_run_isolated() {
  _run_in_strict_subshell "$@"
}

hr() {
  local w="${COLUMNS:-80}"
  local line
  if [[ ! "${w}" =~ ^[0-9]+$ ]]; then
    w=80
  fi
  if (( w < 60 )); then
    w=60
  fi
  printf -v line '%*s' "${w}" ''
  line="${line// /-}"
  echo -e "${UI_MUTED}${line}${UI_RESET}"
}

ui_menu_terminal_width() {
  local width="${COLUMNS:-}"
  if [[ ! "${width}" =~ ^[0-9]+$ ]] || (( width < 40 )); then
    if command -v tput >/dev/null 2>&1; then
      width="$(tput cols 2>/dev/null || true)"
    fi
  fi
  if [[ ! "${width}" =~ ^[0-9]+$ ]] || (( width < 40 )); then
    width=80
  fi
  printf '%s\n' "${width}"
}

main_menu_center_line() {
  local text="$1"
  local w
  local pad
  w="$(ui_menu_terminal_width)"
  if (( w < 60 )); then
    w=60
  fi
  if (( ${#text} >= w )); then
    echo "${text}"
    return 0
  fi
  pad=$(( (w - ${#text}) / 2 ))
  printf '%*s%s\n' "${pad}" '' "${text}"
}

main_menu_center_segments() {
  local joined=""
  local sep="   "
  local segment
  for segment in "$@"; do
    [[ -n "${segment}" ]] || continue
    if [[ -n "${joined}" ]]; then
      joined+="${sep}"
    fi
    joined+="${segment}"
  done
  main_menu_center_line "${joined}"
}

ui_menu_screen_begin() {
  local title_text="$1"
  local subtitle="${2:-}"
  title
  main_menu_center_line "${title_text}"
  if [[ -n "${subtitle}" ]]; then
    echo -e "${UI_MUTED}${subtitle}${UI_RESET}"
  fi
  hr
}

ui_menu_render_single_column() {
  local ref_name="$1"
  local -n menu_items="${ref_name}"
  local item key label
  for item in "${menu_items[@]}"; do
    IFS='|' read -r key label <<<"${item}"
    printf "  %b%s)%b %s\n" "${UI_ACCENT}" "${key}" "${UI_RESET}" "${label}"
  done
}

ui_menu_render_two_columns() {
  local ref_name="$1"
  local -n menu_items="${ref_name}"
  local width split total left_count right_count
  local left_num_width=0 right_num_width=0 left_label_width=0 right_label_width=0
  local i left_key left_label right_key right_label
  width="$(ui_menu_terminal_width)"
  total="${#menu_items[@]}"
  split=$(( (total + 1) / 2 ))
  left_count="${split}"
  right_count=$(( total - split ))

  for (( i=0; i<left_count; i++ )); do
    IFS='|' read -r left_key left_label <<<"${menu_items[$i]}"
    (( ${#left_key} > left_num_width )) && left_num_width=${#left_key}
    (( ${#left_label} > left_label_width )) && left_label_width=${#left_label}
  done
  for (( i=0; i<right_count; i++ )); do
    IFS='|' read -r right_key right_label <<<"${menu_items[$((split + i))]}"
    (( ${#right_key} > right_num_width )) && right_num_width=${#right_key}
    (( ${#right_label} > right_label_width )) && right_label_width=${#right_label}
  done

  local min_width=$(( 2 + left_num_width + 2 + left_label_width + 4 ))
  if (( right_count > 0 )); then
    min_width=$(( min_width + right_num_width + 2 + right_label_width ))
  fi
  if (( width < min_width )); then
    ui_menu_render_single_column "${ref_name}"
    return 0
  fi

  for (( i=0; i<left_count; i++ )); do
    IFS='|' read -r left_key left_label <<<"${menu_items[$i]}"
    if (( i < right_count )); then
      IFS='|' read -r right_key right_label <<<"${menu_items[$((split + i))]}"
      printf "  %b%*s)%b %-*s  %b%*s)%b %s\n" \
        "${UI_ACCENT}" "${left_num_width}" "${left_key}" "${UI_RESET}" "${left_label_width}" "${left_label}" \
        "${UI_ACCENT}" "${right_num_width}" "${right_key}" "${UI_RESET}" "${right_label}"
    else
      printf "  %b%*s)%b %s\n" \
        "${UI_ACCENT}" "${left_num_width}" "${left_key}" "${UI_RESET}" "${left_label}"
    fi
  done
}

ui_menu_render_two_columns_fixed() {
  local ref_name="$1"
  local -n menu_items="${ref_name}"
  local split total left_count right_count
  local left_num_width=0 right_num_width=0 left_label_width=0 right_label_width=0
  local shared_label_width=0
  local i left_key left_label right_key right_label
  total="${#menu_items[@]}"
  split=$(( (total + 1) / 2 ))
  left_count="${split}"
  right_count=$(( total - split ))

  for (( i=0; i<left_count; i++ )); do
    IFS='|' read -r left_key left_label <<<"${menu_items[$i]}"
    (( ${#left_key} > left_num_width )) && left_num_width=${#left_key}
    (( ${#left_label} > left_label_width )) && left_label_width=${#left_label}
  done
  for (( i=0; i<right_count; i++ )); do
    IFS='|' read -r right_key right_label <<<"${menu_items[$((split + i))]}"
    (( ${#right_key} > right_num_width )) && right_num_width=${#right_key}
    (( ${#right_label} > right_label_width )) && right_label_width=${#right_label}
  done

  shared_label_width="${left_label_width}"
  (( right_label_width > shared_label_width )) && shared_label_width="${right_label_width}"
  shared_label_width=$(( shared_label_width + 2 ))

  for (( i=0; i<left_count; i++ )); do
    IFS='|' read -r left_key left_label <<<"${menu_items[$i]}"
    if (( i < right_count )); then
      IFS='|' read -r right_key right_label <<<"${menu_items[$((split + i))]}"
      printf "  %b%*s)%b %-*s  %b%*s)%b %s\n" \
        "${UI_ACCENT}" "${left_num_width}" "${left_key}" "${UI_RESET}" "${shared_label_width}" "${left_label}" \
        "${UI_ACCENT}" "${right_num_width}" "${right_key}" "${UI_RESET}" "${right_label}"
    else
      printf "  %b%*s)%b %s\n" \
        "${UI_ACCENT}" "${left_num_width}" "${left_key}" "${UI_RESET}" "${left_label}"
    fi
  done
}

ui_menu_render_options() {
  local ref_name="$1"
  local -n menu_items="${ref_name}"
  local threshold="${2:-72}"
  local width count
  width="$(ui_menu_terminal_width)"
  count="${#menu_items[@]}"
  if (( count >= 4 && width >= threshold )); then
    ui_menu_render_two_columns "${ref_name}"
  else
    ui_menu_render_single_column "${ref_name}"
  fi
}

ui_spinner_wait() {
  local pid="$1"
  local label="${2:-Memproses}"
  local start_ts now elapsed frame_idx rc
  local -a frames=('|' '/' '-' '\\')

  if [[ ! "${pid}" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  if [[ ! -t 1 ]]; then
    wait "${pid}"
    return $?
  fi

  start_ts="$(date +%s 2>/dev/null || echo 0)"
  frame_idx=0
  while kill -0 "${pid}" 2>/dev/null; do
    now="$(date +%s 2>/dev/null || echo "${start_ts}")"
    elapsed=$(( now - start_ts ))
    printf '\r%b' "${frames[$frame_idx]} ${label} ${UI_MUTED}(${elapsed}s)${UI_RESET}"
    frame_idx=$(( (frame_idx + 1) % ${#frames[@]} ))
    sleep 0.12
  done

  wait "${pid}"
  rc=$?
  printf '\r\033[2K'
  return "${rc}"
}

ui_run_logged_command_with_spinner() {
  local __outvar="$1"
  local label="$2"
  shift 2 || true

  local spinner_log_dir spinner_log_file spinner_pid rc
  spinner_log_dir="${WORK_DIR:-/tmp}"
  mkdir -p "${spinner_log_dir}" >/dev/null 2>&1 || spinner_log_dir="/tmp"
  spinner_log_file="$(mktemp "${spinner_log_dir}/manage-spin.XXXXXX.log")" || return 1

  (
    "$@"
  ) >"${spinner_log_file}" 2>&1 &
  spinner_pid=$!

  set +e
  ui_spinner_wait "${spinner_pid}" "${label}"
  rc=$?
  set -e

  printf -v "${__outvar}" '%s' "${spinner_log_file}"
  return "${rc}"
}

title() {
  if [[ -t 1 ]] && command -v clear >/dev/null 2>&1; then
    clear || true
  fi
  echo -e "${UI_BOLD}${UI_ACCENT}Control Panel${UI_RESET}"
  echo -e "${UI_MUTED}Host: $(hostname) | Script: ${0##*/}${UI_RESET}"
  hr
}

# -------------------------
# Service helpers
# -------------------------
svc_state() {
  local svc="$1"
  systemctl is-active "${svc}" 2>/dev/null || true
}

svc_is_active() {
  local svc="$1"
  systemctl is-active --quiet "${svc}" >/dev/null 2>&1
}

svc_wait_active() {
  # args: service [timeout_seconds]
  local svc="$1"
  local timeout="${2:-20}"
  local checks i state

  if [[ ! "${timeout}" =~ ^[0-9]+$ ]] || (( timeout <= 0 )); then
    timeout=20
  fi
  checks=$(( timeout * 4 ))
  if (( checks < 1 )); then
    checks=1
  fi

  for (( i=0; i<checks; i++ )); do
    state="$(svc_state "${svc}")"
    if [[ "${state}" == "active" ]]; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

svc_wait_inactive() {
  # args: service [timeout_seconds]
  local svc="$1"
  local timeout="${2:-20}"
  local checks i state

  if [[ ! "${timeout}" =~ ^[0-9]+$ ]] || (( timeout <= 0 )); then
    timeout=20
  fi
  checks=$(( timeout * 4 ))
  if (( checks < 1 )); then
    checks=1
  fi

  for (( i=0; i<checks; i++ )); do
    state="$(svc_state "${svc}")"
    if [[ "${state}" == "inactive" ]]; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

svc_start_checked() {
  local svc="$1"
  local timeout="${2:-20}"

  if systemctl start "${svc}" >/dev/null 2>&1 && svc_wait_active "${svc}" "${timeout}"; then
    return 0
  fi
  return 1
}

svc_stop_checked() {
  local svc="$1"
  local timeout="${2:-20}"

  if systemctl stop "${svc}" >/dev/null 2>&1 && svc_wait_inactive "${svc}" "${timeout}"; then
    return 0
  fi
  return 1
}

svc_restart_checked() {
  local svc="$1"
  local timeout="${2:-20}"
  local state=""

  if systemctl restart "${svc}" >/dev/null 2>&1; then
    if svc_wait_active "${svc}" "${timeout}"; then
      return 0
    fi
  else
    state="$(svc_state "${svc}")"
    if [[ "${state}" == "active" ]]; then
      return 1
    fi
  fi

  state="$(svc_state "${svc}")"
  if [[ "${state}" == "failed" || "${state}" == "inactive" || "${state}" == "activating" || "${state}" == "deactivating" ]]; then
    systemctl reset-failed "${svc}" >/dev/null 2>&1 || true
    sleep 1
    if systemctl start "${svc}" >/dev/null 2>&1 && svc_wait_active "${svc}" "${timeout}"; then
      return 0
    fi
  fi

  return 1
}

xray_restart_checked() {
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

xray_restart_checked_with_preflight() {
  local ok=1 f

  if have_cmd jq; then
    for f in \
      "${XRAY_LOG_CONF}" \
      "${XRAY_API_CONF}" \
      "${XRAY_DNS_CONF}" \
      "${XRAY_INBOUNDS_CONF}" \
      "${XRAY_OUTBOUNDS_CONF}" \
      "${XRAY_ROUTING_CONF}" \
      "${XRAY_POLICY_CONF}" \
      "${XRAY_STATS_CONF}"; do
      if [[ ! -f "${f}" ]]; then
        warn "Konfigurasi Xray tidak ditemukan: ${f}"
        ok=0
        continue
      fi
      if ! jq -e . "${f}" >/dev/null 2>&1; then
        warn "JSON Xray tidak valid: ${f}"
        ok=0
      fi
    done
  else
    warn "jq tidak tersedia, skip validasi JSON Xray sebelum restart."
  fi

  if (( ok != 1 )); then
    warn "Preflight konfigurasi Xray gagal. Restart dibatalkan."
    return 1
  fi

  if have_cmd xray && ! xray_confdir_syntax_test; then
    warn "Syntax confdir Xray tidak valid. Restart dibatalkan."
    return 1
  fi

  if ! xray_restart_checked; then
    warn "Restart xray gagal."
    return 1
  fi
  return 0
}

nginx_service_listener_health_check() {
  if ! svc_exists nginx || ! svc_is_active nginx; then
    warn "nginx tidak aktif setelah operasi."
    return 1
  fi
  if ! have_cmd ss; then
    return 0
  fi
  if ss -lntp 2>/dev/null | grep -F "nginx" >/dev/null 2>&1; then
    return 0
  fi
  warn "Listener nginx tidak terdeteksi setelah operasi."
  return 1
}

nginx_restart_checked_with_listener() {
  if have_cmd nginx && ! nginx -t >/dev/null 2>&1; then
    warn "nginx -t gagal. Restart nginx dibatalkan."
    return 1
  fi
  if ! svc_restart_checked nginx 60; then
    warn "Restart nginx gagal."
    return 1
  fi
  nginx_service_listener_health_check || return 1
  return 0
}

svc_exists() {
  local svc="$1"
  local load
  load="$(systemctl show -p LoadState --value "${svc}" 2>/dev/null || true)"
  [[ -n "${load}" && "${load}" != "not-found" ]]
}

service_status_icon() {
  local svc="${1:-}"
  if [[ -z "${svc}" ]]; then
    printf '⛔\n'
    return 0
  fi
  if svc_exists "${svc}" && svc_is_active "${svc}"; then
    printf '✅\n'
  else
    printf '⛔\n'
  fi
}

service_group_status_icon() {
  local svc
  if (( $# == 0 )); then
    printf '⛔\n'
    return 0
  fi
  for svc in "$@"; do
    if ! svc_exists "${svc}" || ! svc_is_active "${svc}"; then
      printf '⛔\n'
      return 0
    fi
  done
  printf '✅\n'
}

main_menu_edge_service_name() {
  local provider active
  provider="$(edge_runtime_get_env EDGE_PROVIDER 2>/dev/null || echo "none")"
  active="$(edge_runtime_get_env EDGE_ACTIVATE_RUNTIME 2>/dev/null || echo "false")"
  if [[ "${active}" != "true" ]]; then
    printf '%s\n' "edge-mux.service"
    return 0
  fi
  case "${provider}" in
    nginx-stream) printf '%s\n' "nginx" ;;
    go) printf '%s\n' "edge-mux.service" ;;
    *) printf '%s\n' "edge-mux.service" ;;
  esac
}

ssh_account_count() {
  local count="0"
  if declare -F ssh_state_dirs_prepare >/dev/null 2>&1; then
    ssh_state_dirs_prepare >/dev/null 2>&1 || true
  fi
  [[ -d "${SSH_USERS_STATE_DIR}" ]] || {
    printf '0\n'
    return 0
  }
  count="$(find "${SSH_USERS_STATE_DIR}" -maxdepth 1 -type f -name '*.json' ! -name '.*' 2>/dev/null | wc -l | tr -d '[:space:]')"
  [[ "${count}" =~ ^[0-9]+$ ]] || count="0"
  printf '%s\n' "${count}"
}

svc_status_line() {
  local svc="$1"
  if svc_is_active "${svc}"; then
    echo "OK   - ${svc} (active)"
  else
    echo "FAIL - ${svc} (inactive)"
  fi
}

svc_restart_now() {
  local svc="$1"
  local st
  if svc_restart_checked "${svc}" 20; then
    return 0
  fi

  st="$(svc_state "${svc}")"
  echo "Restart dilakukan, tapi status masih tidak aktif: ${svc} (state=${st:-unknown})" >&2
  return 1
}

svc_restart() {
  local svc="$1"
  local spin_log=""
  if ui_run_logged_command_with_spinner spin_log "Restart ${svc}" svc_restart_now "${svc}"; then
    log "Restart sukses: ${svc}"
    rm -f "${spin_log}" >/dev/null 2>&1 || true
    return 0
  fi

  warn "Restart gagal: ${svc}"
  if [[ -n "${spin_log}" && -s "${spin_log}" ]]; then
    hr
    tail -n 30 "${spin_log}" 2>/dev/null || true
    hr
  fi
  rm -f "${spin_log}" >/dev/null 2>&1 || true
  return 1
}

svc_restart_if_exists() {
  local svc="$1"
  if systemctl cat "${svc}" >/dev/null 2>&1; then
    if svc_restart_now "${svc}" >/dev/null 2>&1; then
      return 0
    fi
    return 1
  fi
  return 1
}

svc_restart_any() {
  # args: list of service names (with or without .service)
  local s
  for s in "$@"; do
    if svc_restart_if_exists "${s}"; then
      return 0
    fi
    if [[ "${s}" != *.service ]]; then
      if svc_restart_if_exists "${s}.service"; then
        return 0
      fi
    fi
  done
  return 1
}

# -------------------------
# Account helpers (read-only)
# -------------------------
ACCOUNT_FILES=()
ACCOUNT_FILE_PROTOS=()

quota_cache_rebuild() {
  QUOTA_FIELDS_CACHE=()
  need_python3

  local line key val
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    key="${line%%|*}"
    val="${line#*|}"
    [[ -n "${key}" ]] || continue
    QUOTA_FIELDS_CACHE["${key}"]="${val}"
  done < <(python3 - <<'PY' "${QUOTA_ROOT}" "${QUOTA_PROTO_DIRS[@]}" 2>/dev/null || true
import json
import os
import sys

quota_root = sys.argv[1]
protos = tuple(sys.argv[2:])

def to_int(v, default=0):
  try:
    if v is None:
      return default
    if isinstance(v, bool):
      return int(v)
    if isinstance(v, (int, float)):
      return int(v)
    s = str(v).strip()
    if s == "":
      return default
    return int(float(s))
  except Exception:
    return default

def fmt_gb(v):
  try:
    v = float(v)
  except Exception:
    return "0"
  if v <= 0:
    return "0"
  if abs(v - round(v)) < 1e-9:
    return str(int(round(v)))
  s = f"{v:.2f}"
  s = s.rstrip("0").rstrip(".")
  return s

for proto in protos:
  d = os.path.join(quota_root, proto)
  if not os.path.isdir(d):
    continue

  chosen = {}
  chosen_has_at = {}
  for name in sorted(os.listdir(d)):
    if not name.endswith(".json"):
      continue
    base = name[:-5]
    username = base.split("@", 1)[0] if "@" in base else base
    if not username:
      continue
    has_at = "@" in base
    prev = chosen.get(username)
    if prev is not None:
      # Prefer username@proto.json over compatibility-format username.json
      if has_at and not chosen_has_at.get(username, False):
        chosen[username] = os.path.join(d, name)
        chosen_has_at[username] = True
      continue
    chosen[username] = os.path.join(d, name)
    chosen_has_at[username] = has_at

  for username in sorted(chosen.keys()):
    qf = chosen[username]
    quota_gb = "0"
    expired = "-"
    created = "-"
    ip_enabled = "false"
    ip_limit = 0

    try:
      with open(qf, "r", encoding="utf-8") as f:
        data = json.load(f)
      if isinstance(data, dict):
        ql = to_int(data.get("quota_limit"), 0)
        unit = str(data.get("quota_unit") or "binary").strip().lower()
        bpg = 1000**3 if unit in ("decimal", "gb", "1000", "gigabyte") else 1024**3
        quota_gb = fmt_gb(ql / bpg) if ql else "0"
        expired = str(data.get("expired_at") or "-")
        created = str(data.get("created_at") or "-")
        st_raw = data.get("status")
        st = st_raw if isinstance(st_raw, dict) else {}
        ip_enabled = str(bool(st.get("ip_limit_enabled"))).lower()
        ip_limit = to_int(st.get("ip_limit"), 0)
    except Exception:
      pass

    print(f"{proto}:{username}|{quota_gb}|{expired}|{created}|{ip_enabled}|{ip_limit}")
PY
)
}

account_collect_files() {
  local proto_filter="${1:-}"
  ACCOUNT_FILES=()
  ACCOUNT_FILE_PROTOS=()

  local proto dir f base u key
  declare -A pos=()
  declare -A has_at=()

  for proto in "${ACCOUNT_PROTO_DIRS[@]}"; do
    if [[ -n "${proto_filter}" && "${proto}" != "${proto_filter}" ]]; then
      continue
    fi
    dir="${ACCOUNT_ROOT}/${proto}"
    [[ -d "${dir}" ]] || continue
    while IFS= read -r -d '' f; do
      base="$(basename "${f}")"
      base="${base%.txt}"
      if [[ "${base}" == *"@"* ]]; then
        u="${base%%@*}"
      else
        u="${base}"
      fi
      key="${proto}:${u}"

      # Prefer file "username@proto.txt" over compatibility-format "username.txt" if both exist.
      if [[ -n "${pos[${key}]:-}" ]]; then
        if [[ "${base}" == *"@"* && "${has_at[${key}]:-0}" != "1" ]]; then
          ACCOUNT_FILES[${pos[${key}]}]="${f}"
          ACCOUNT_FILE_PROTOS[${pos[${key}]}]="${proto}"
          has_at["${key}"]=1
        fi
        continue
      fi

      pos["${key}"]="${#ACCOUNT_FILES[@]}"
      if [[ "${base}" == *"@"* ]]; then
        has_at["${key}"]=1
      else
        has_at["${key}"]=0
      fi

      ACCOUNT_FILES+=("${f}")
      ACCOUNT_FILE_PROTOS+=("${proto}")
    done < <(find "${dir}" -maxdepth 1 -type f -name '*.txt' -print0 2>/dev/null | sort -z)
  done

  # Tambahkan target dari quota metadata bila file account belum ada,
  # agar flow refresh/delete/reset masih bisa menemukan akun yang drift.
  for proto in "${ACCOUNT_PROTO_DIRS[@]}"; do
    if [[ -n "${proto_filter}" && "${proto}" != "${proto_filter}" ]]; then
      continue
    fi
    dir="${QUOTA_ROOT}/${proto}"
    [[ -d "${dir}" ]] || continue
    while IFS= read -r -d '' f; do
      base="$(basename "${f}")"
      base="${base%.json}"
      if [[ "${base}" == *"@"* ]]; then
        u="${base%%@*}"
      else
        u="${base}"
      fi
      [[ -n "${u}" ]] || continue
      key="${proto}:${u}"
      if [[ -n "${pos[${key}]:-}" ]]; then
        continue
      fi
      pos["${key}"]="${#ACCOUNT_FILES[@]}"
      has_at["${key}"]=1
      ACCOUNT_FILES+=("${ACCOUNT_ROOT}/${proto}/${u}@${proto}.txt}")
      ACCOUNT_FILE_PROTOS+=("${proto}")
    done < <(find "${dir}" -maxdepth 1 -type f -name '*.json' -print0 2>/dev/null | sort -z)
  done

  # Tambahkan target dari runtime inbounds agar akun live tanpa file/quota
  # tetap bisa terlihat dan dipulihkan dari menu.
  local email
  while IFS= read -r email; do
    [[ -n "${email}" && "${email}" == *"@"* ]] || continue
    u="${email%%@*}"
    proto="${email##*@}"
    case "${proto}" in
      vless|vmess|trojan) ;;
      *) continue ;;
    esac
    if [[ -n "${proto_filter}" && "${proto}" != "${proto_filter}" ]]; then
      continue
    fi
    key="${proto}:${u}"
    if [[ -n "${pos[${key}]:-}" ]]; then
      continue
    fi
    pos["${key}"]="${#ACCOUNT_FILES[@]}"
    has_at["${key}"]=1
    ACCOUNT_FILES+=("${ACCOUNT_ROOT}/${proto}/${u}@${proto}.txt}")
    ACCOUNT_FILE_PROTOS+=("${proto}")
  done < <(xray_inbounds_all_client_emails_get 2>/dev/null || true)

  # Build metadata cache in one Python process to avoid N subprocesses per row.
  quota_cache_rebuild
}

ACCOUNT_PAGE_SIZE=10
ACCOUNT_PAGE=0

account_total_pages() {
  local total="${#ACCOUNT_FILES[@]}"
  if (( total == 0 )); then
    echo 0
    return 0
  fi
  echo $(( (total + ACCOUNT_PAGE_SIZE - 1) / ACCOUNT_PAGE_SIZE ))
}

account_parse_username_from_file() {
  # args: file_path proto -> prints username (tanpa suffix @proto jika ada)
  local f="$1"
  local proto="$2"
  local base user
  base="$(basename "${f}")"
  base="${base%.txt}"
  if [[ "${base}" == *"@"* ]]; then
    user="${base%%@*}"
  else
    user="${base}"
  fi
  echo "${user}"
}

quota_read_fields() {
  # args: proto username -> prints: quota_gb|expired_at|created_at|ip_enabled|ip_limit
  local proto="$1"
  local username="$2"
  local key="${proto}:${username}"
  local parsed

  if [[ -n "${QUOTA_FIELDS_CACHE["${key}"]+_}" ]]; then
    echo "${QUOTA_FIELDS_CACHE["${key}"]}"
    return 0
  fi

  local qf="${QUOTA_ROOT}/${proto}/${username}@${proto}.json"
  if [[ ! -f "${qf}" ]]; then
    qf="${QUOTA_ROOT}/${proto}/${username}.json"
  fi
  if [[ ! -f "${qf}" ]]; then
    echo "-|-|-|-|-"
    return 0
  fi

  parsed="$(python3 - <<'PY' "${qf}"
import json, sys
p=sys.argv[1]
try:
  d=json.load(open(p,'r',encoding='utf-8'))
except Exception:
  print("-|-|-|-|-")
  raise SystemExit(0)
if not isinstance(d, dict):
  print("-|-|-|-|-")
  raise SystemExit(0)

def to_int(v, default=0):
  try:
    if v is None:
      return default
    if isinstance(v, bool):
      return int(v)
    if isinstance(v, (int, float)):
      return int(v)
    s=str(v).strip()
    if s == "":
      return default
    return int(float(s))
  except Exception:
    return default

def fmt_gb(v):
  try:
    v=float(v)
  except Exception:
    return "0"
  if v <= 0:
    return "0"
  if abs(v - round(v)) < 1e-9:
    return str(int(round(v)))
  s=f"{v:.2f}"
  s=s.rstrip("0").rstrip(".")
  return s

ql=to_int(d.get("quota_limit"), 0)
# Hormati quota_unit yang ditulis saat create user
unit=str(d.get("quota_unit") or "binary").strip().lower()
bpg=1000**3 if unit in ("decimal","gb","1000","gigabyte") else 1024**3
quota_gb=fmt_gb(ql/bpg) if ql else "0"
expired=d.get("expired_at") or "-"
created=d.get("created_at") or "-"
st_raw=d.get("status")
st=st_raw if isinstance(st_raw, dict) else {}
ip_en=bool(st.get("ip_limit_enabled"))
ip_lim=to_int(st.get("ip_limit"), 0)
print(f"{quota_gb}|{expired}|{created}|{str(ip_en).lower()}|{ip_lim}")
PY
)"
  QUOTA_FIELDS_CACHE["${key}"]="${parsed}"
  echo "${parsed}"
}

account_print_table_page() {
  # args: page [proto_filter]
  local page="${1:-0}"
  local proto_filter="${2:-}"
  local total="${#ACCOUNT_FILES[@]}"
  local pages
  pages="$(account_total_pages)"

  if (( total == 0 )); then
    warn "Tidak ada target akun Xray terdeteksi dari account/quota/runtime."
    return 0
  fi

  if (( page < 0 )); then page=0; fi
  if (( pages > 0 && page >= pages )); then page=$((pages - 1)); fi

  local start end i f proto username fields quota_gb expired created ip_en ip_lim
  start=$((page * ACCOUNT_PAGE_SIZE))
  end=$((start + ACCOUNT_PAGE_SIZE))
  if (( end > total )); then end="${total}"; fi

  if [[ -n "${proto_filter}" ]]; then
    printf "%-4s %-18s %-10s %-19s %-7s\n" "NO" "USERNAME" "QUOTA" "VALID UNTIL" "IP"
    printf "%-4s %-18s %-10s %-19s %-7s\n" "----" "------------------" "----------" "-------------------" "-------"
  else
    printf "%-4s %-8s %-18s %-10s %-19s %-7s\n" "NO" "PROTO" "USERNAME" "QUOTA" "VALID UNTIL" "IP"
    printf "%-4s %-8s %-18s %-10s %-19s %-7s\n" "----" "--------" "------------------" "----------" "-------------------" "-------"
  fi

  for (( i=start; i<end; i++ )); do
    f="${ACCOUNT_FILES[$i]}"
    proto="${ACCOUNT_FILE_PROTOS[$i]}"
    username="$(account_parse_username_from_file "${f}" "${proto}")"
    fields="$(quota_read_fields "${proto}" "${username}")"
    quota_gb="${fields%%|*}"
    fields="${fields#*|}"
    expired="${fields%%|*}"
    fields="${fields#*|}"
    created="${fields%%|*}"
    fields="${fields#*|}"
    ip_en="${fields%%|*}"
    ip_lim="${fields##*|}"

    local ip_show="OFF"
    if [[ "${ip_en}" == "true" ]]; then
      ip_show="ON(${ip_lim})"
    fi

    # BUG-17 fix: display page-relative row number (i - start + 1) so that
    # page 2 starts at NO=1, not NO=11. This matches user expectation when
    # entering a row number to select.
    if [[ -n "${proto_filter}" ]]; then
      printf "%-4s %-18s %-10s %-19s %-7s\n" "$((i - start + 1))" "${username}" "${quota_gb} GB" "${expired}" "${ip_show}"
    else
      printf "%-4s %-8s %-18s %-10s %-19s %-7s\n" "$((i - start + 1))" "${proto}" "${username}" "${quota_gb} GB" "${expired}" "${ip_show}"
    fi
  done

  echo
  echo "Halaman: $((page + 1))/${pages}  | Total akun: ${total}"
  if (( pages > 1 )); then
    echo "Ketik: next / previous / kembali"
  fi
}

human_size() {
  # bytes -> human-ish (KiB/MiB/GiB)
  local bytes="${1:-0}"
  local kib mib gib
  kib=$((1024))
  mib=$((1024 * 1024))
  gib=$((1024 * 1024 * 1024))

  if (( bytes >= gib )); then
    printf "%.1fGiB" "$(awk "BEGIN {print ${bytes}/${gib}}")"
  elif (( bytes >= mib )); then
    printf "%.1fMiB" "$(awk "BEGIN {print ${bytes}/${mib}}")"
  elif (( bytes >= kib )); then
    printf "%.1fKiB" "$(awk "BEGIN {print ${bytes}/${kib}}")"
  else
    printf "%dB" "${bytes}"
  fi
}

account_print_table() {
  local i f proto base mtime size
  if (( ${#ACCOUNT_FILES[@]} == 0 )); then
    warn "Tidak ada file account di ${ACCOUNT_ROOT}/{vless,vmess,trojan}"
    echo "Pastikan directory berikut ada:"
    echo "  ${ACCOUNT_ROOT}/vless"
    echo "  ${ACCOUNT_ROOT}/vmess"
    echo "  ${ACCOUNT_ROOT}/trojan"
    return 0
  fi

  printf "%-4s %-8s %-34s %-19s %-8s\n" "NO" "PROTO" "FILE" "UPDATED" "SIZE"
  printf "%-4s %-8s %-34s %-19s %-8s\n" "----" "--------" "----------------------------------" "-------------------" "--------"

  for i in "${!ACCOUNT_FILES[@]}"; do
    f="${ACCOUNT_FILES[$i]}"
    proto="${ACCOUNT_FILE_PROTOS[$i]}"
    base="$(basename "${f}")"
    mtime="$(stat -c '%y' "${f}" 2>/dev/null | cut -d'.' -f1 || echo '-')"
    size="$(stat -c '%s' "${f}" 2>/dev/null || echo '0')"
    printf "%-4s %-8s %-34s %-19s %-8s\n" "$((i + 1))" "${proto}" "${base}" "${mtime}" "$(human_size "${size}")"
  done
}

account_view_flow() {
  if (( ${#ACCOUNT_FILES[@]} == 0 )); then
    warn "Tidak ada file untuk dilihat"
    pause
    return 0
  fi

  local n f total page pages start end rows idx
  if ! read -r -p "Masukkan NO untuk view (atau kembali): " n; then
    echo
    return 0
  fi
  if is_back_choice "${n}"; then
    return 0
  fi
  [[ "${n}" =~ ^[0-9]+$ ]] || { warn "Input bukan angka"; pause; return 0; }

  total="${#ACCOUNT_FILES[@]}"
  page="${ACCOUNT_PAGE:-0}"
  pages=$(( (total + ACCOUNT_PAGE_SIZE - 1) / ACCOUNT_PAGE_SIZE ))
  if (( page < 0 )); then page=0; fi
  if (( pages > 0 && page >= pages )); then page=$((pages - 1)); fi
  start=$((page * ACCOUNT_PAGE_SIZE))
  end=$((start + ACCOUNT_PAGE_SIZE))
  if (( end > total )); then end="${total}"; fi
  rows=$((end - start))

  if (( n < 1 || n > rows )); then
    warn "NO di luar range"
    pause
    return 0
  fi

  idx=$((start + n - 1))
  f="${ACCOUNT_FILES[$idx]}"
  title
  echo "View: ${f}"
  hr
  if have_cmd less; then
    less -R "${f}"
  else
    cat "${f}"
  fi
  hr
  pause
}

account_search_flow() {
  title
  echo "Xray Users > Search"
  hr
  if ! have_cmd grep; then
    warn "grep tidak tersedia"
    pause
    return 0
  fi

  echo "Cari keyword (case-sensitive, gunakan regex bila perlu)."
  if ! read -r -p "Query: " q; then
    echo
    return 0
  fi
  if is_back_choice "${q}"; then
    return 0
  fi
  if [[ -z "${q}" ]]; then
    warn "Query kosong"
    pause
    return 0
  fi

  local matches=() proto dir f
  for proto in "${ACCOUNT_PROTO_DIRS[@]}"; do
    dir="${ACCOUNT_ROOT}/${proto}"
    [[ -d "${dir}" ]] || continue
    while IFS= read -r f; do
      [[ -n "${f}" ]] && matches+=("${f}")
    done < <(grep -RIl -- "${q}" "${dir}" 2>/dev/null || true)
  done

  title
  echo "Hasil search: ${q}"
  hr
  if (( ${#matches[@]} == 0 )); then
    warn "Tidak ada hasil."
    hr
    pause
    return 0
  fi

  local i f proto base
  printf "%-4s %-8s %-34s %s\n" "NO" "PROTO" "FILE" "PATH"
  printf "%-4s %-8s %-34s %s\n" "----" "--------" "----------------------------------" "----"
  for i in "${!matches[@]}"; do
    f="${matches[$i]}"
    proto="$(basename "$(dirname "${f}")")"
    base="$(basename "${f}")"
    printf "%-4s %-8s %-34s %s\n" "$((i + 1))" "${proto}" "${base}" "${f}"
  done
  hr
  echo "  1) View salah satu hasil"
  echo "  0) Back"
  hr
  if ! read -r -p "Pilih: " c; then
    echo
    return 0
  fi
  case "${c}" in
    1)
      if ! read -r -p "Masukkan NO untuk view (atau kembali): " n; then
        echo
        return 0
      fi
      if is_back_choice "${n}"; then
        return 0
      fi
      [[ "${n}" =~ ^[0-9]+$ ]] || { warn "Input bukan angka"; pause; return 0; }
      if (( n < 1 || n > ${#matches[@]} )); then
        warn "NO di luar range"
        pause
        return 0
      fi
      f="${matches[$((n - 1))]}"
      title
      echo "View: ${f}"
      hr
      if have_cmd less; then
        less -R "${f}"
      else
        cat "${f}"
      fi
      hr
      pause
      ;;
    0|kembali|k|back|b) : ;;
    *) : ;;
  esac
}

# -------------------------
# Diagnostics
# -------------------------
check_files() {
  local ok=0
  [[ -d "${XRAY_CONFDIR}" ]] || { warn "Tidak ada: ${XRAY_CONFDIR}"; ok=1; }
  [[ -f "${NGINX_CONF}" ]] || { warn "Tidak ada: ${NGINX_CONF}"; ok=1; }
  [[ -f "${CERT_FULLCHAIN}" ]] || { warn "Tidak ada: ${CERT_FULLCHAIN}"; ok=1; }
  [[ -f "${CERT_PRIVKEY}" ]] || { warn "Tidak ada: ${CERT_PRIVKEY}"; ok=1; }
  return "${ok}"
}

check_nginx_config() {
  if ! have_cmd nginx; then
    warn "nginx tidak tersedia, lewati nginx -t"
    return 0
  fi

  local out rc
  out="$(nginx -t 2>&1 || true)"
  if echo "${out}" | grep -q "test is successful"; then
    log "nginx -t: OK"
    return 0
  fi

  # Beberapa environment (container/sandbox terbatas) memblokir akses pid/log
  # sehingga nginx -t false-negative. Dalam kasus ini jadikan warning agar menu
  # diagnostic tetap bisa lanjut.
  if echo "${out}" | grep -Eqi "Permission denied|/var/run/nginx.pid|could not open error log file"; then
    warn "nginx -t tidak bisa diverifikasi penuh di environment ini (permission restriction)."
    echo "${out}" >&2
    return 0
  fi

  warn "nginx -t: GAGAL"
  if [[ -n "${out}" ]]; then
    echo "${out}" >&2
  else
    warn "Tidak ada output dari nginx -t"
  fi
  return 1
}

check_xray_config_json() {
  if ! have_cmd jq; then
    warn "jq tidak tersedia, lewati validasi JSON"
    return 0
  fi

  local ok=1 f
  for f in \
    "${XRAY_LOG_CONF}" \
    "${XRAY_API_CONF}" \
    "${XRAY_DNS_CONF}" \
    "${XRAY_INBOUNDS_CONF}" \
    "${XRAY_OUTBOUNDS_CONF}" \
    "${XRAY_ROUTING_CONF}" \
    "${XRAY_POLICY_CONF}" \
    "${XRAY_STATS_CONF}"; do
    if [[ ! -f "${f}" ]]; then
      warn "Konfigurasi tidak ditemukan: ${f}"
      ok=0
      continue
    fi
    if ! jq -e . "${f}" >/dev/null; then
      warn "JSON tidak valid: ${f}"
      ok=0
    fi
  done

  (( ok == 1 )) || die "Konfigurasi Xray (conf.d) tidak lengkap / invalid."
  log "Xray conf.d JSON: OK"
}

xray_confdir_syntax_test() {
  # Return 0 jika syntax confdir valid atau binary xray tidak tersedia.
  # Return non-zero jika xray tersedia namun test config gagal.
  if ! have_cmd xray; then
    return 0
  fi
  xray run -test -confdir "${XRAY_CONFDIR}" >/dev/null 2>&1
}

xray_confdir_syntax_test_with_override() {
  # args: live_target candidate_file
  # Validasi seluruh confdir dengan satu file dioverride dari candidate.
  local live_target="${1:-}"
  local candidate_file="${2:-}"
  local temp_confdir="" target_rel="" override_target=""

  [[ -n "${live_target}" && -n "${candidate_file}" ]] || return 1
  if ! have_cmd xray; then
    return 0
  fi
  [[ -d "${XRAY_CONFDIR}" ]] || return 1

  temp_confdir="$(mktemp -d "${WORK_DIR}/.xray-confdir-test.XXXXXX" 2>/dev/null || true)"
  [[ -n "${temp_confdir}" && -d "${temp_confdir}" ]] || return 1
  if ! cp -a "${XRAY_CONFDIR}/." "${temp_confdir}/" >/dev/null 2>&1; then
    rm -rf "${temp_confdir}" >/dev/null 2>&1 || true
    return 1
  fi

  target_rel="${live_target#${XRAY_CONFDIR}/}"
  if [[ "${target_rel}" == "${live_target}" ]]; then
    rm -rf "${temp_confdir}" >/dev/null 2>&1 || true
    return 1
  fi
  override_target="${temp_confdir}/${target_rel}"
  mkdir -p "$(dirname "${override_target}")" 2>/dev/null || true
  if ! cp -f -- "${candidate_file}" "${override_target}" >/dev/null 2>&1; then
    rm -rf "${temp_confdir}" >/dev/null 2>&1 || true
    return 1
  fi

  if xray run -test -confdir "${temp_confdir}" >/dev/null 2>&1; then
    rm -rf "${temp_confdir}" >/dev/null 2>&1 || true
    return 0
  fi
  rm -rf "${temp_confdir}" >/dev/null 2>&1 || true
  return 1
}

nginx_conf_test_with_override() {
  # args: live_target candidate_file
  # Best-effort preflight untuk nginx conf.d dengan satu file dioverride dari candidate.
  # Return 0=valid, 1=invalid, 2=preflight tidak tersedia/tidak bisa disiapkan.
  local live_target="${1:-}"
  local candidate_file="${2:-}"
  local temp_root="" temp_confdir="" temp_main="" rc=2

  [[ -n "${live_target}" && -n "${candidate_file}" ]] || return 2
  [[ -f "${live_target}" && -f "${candidate_file}" && -f "${NGINX_MAIN_CONF}" ]] || return 2
  have_cmd nginx || return 2
  have_cmd python3 || return 2

  temp_root="$(mktemp -d "${WORK_DIR}/.nginx-conf-test.XXXXXX" 2>/dev/null || true)"
  [[ -n "${temp_root}" && -d "${temp_root}" ]] || return 2
  temp_confdir="${temp_root}/conf.d"
  mkdir -p "${temp_confdir}" >/dev/null 2>&1 || {
    rm -rf "${temp_root}" >/dev/null 2>&1 || true
    return 2
  }

  if ! cp -a "$(dirname "${live_target}")/." "${temp_confdir}/" >/dev/null 2>&1; then
    rm -rf "${temp_root}" >/dev/null 2>&1 || true
    return 2
  fi
  if ! cp -f -- "${candidate_file}" "${temp_confdir}/$(basename "${live_target}")" >/dev/null 2>&1; then
    rm -rf "${temp_root}" >/dev/null 2>&1 || true
    return 2
  fi

  temp_main="${temp_root}/nginx.conf"
  if ! python3 - <<'PY' "${NGINX_MAIN_CONF}" "${temp_main}" "$(dirname "${live_target}")" "${temp_confdir}" >/dev/null 2>&1
import pathlib
import re
import sys

main_src = pathlib.Path(sys.argv[1])
main_dst = pathlib.Path(sys.argv[2])
live_dir = sys.argv[3].rstrip("/")
temp_dir = sys.argv[4].rstrip("/")

try:
    text = main_src.read_text(encoding="utf-8")
except Exception:
    raise SystemExit(2)

pattern = re.compile(
    rf'(^\s*include\s+){re.escape(live_dir)}/\*\.conf(\s*;\s*$)',
    re.MULTILINE,
)
updated, count = pattern.subn(
    lambda m: f"{m.group(1)}{temp_dir}/*.conf{m.group(2)}",
    text,
)
if count == 0:
    raise SystemExit(3)

try:
    main_dst.write_text(updated, encoding="utf-8")
except Exception:
    raise SystemExit(2)
PY
  then
    rc=$?
    rm -rf "${temp_root}" >/dev/null 2>&1 || true
    if (( rc == 3 )); then
      return 2
    fi
    return 2
  fi

  if nginx -t -c "${temp_main}" -g "pid ${temp_root}/nginx.pid;" >/dev/null 2>&1; then
    rc=0
  else
    rc=1
  fi
  rm -rf "${temp_root}" >/dev/null 2>&1 || true
  return "${rc}"
}

xray_confdir_syntax_test_pretty() {
  # Untuk menu Diagnostics:
  # - tampilkan error penting jika ada
  # - ringkas warning deprecation transport terdepresiasi agar tidak terlihat seperti fatal error
  if ! have_cmd xray; then
    warn "xray binary tidak ditemukan"
    return 127
  fi

  local out rc filtered deprec_count
  set +e
  out="$(xray run -test -confdir "${XRAY_CONFDIR}" 2>&1)"
  rc=$?
  set -e

  filtered="$(printf '%s\n' "${out}" | grep -Ev 'common/errors: The feature .* is deprecated' || true)"
  deprec_count="$(printf '%s\n' "${out}" | grep -Ec 'common/errors: The feature .* is deprecated' || true)"

  if [[ -n "${filtered//[[:space:]]/}" ]]; then
    printf '%s\n' "${filtered}"
  fi

  if (( deprec_count > 0 )); then
    warn "Ditemukan ${deprec_count} warning deprecation transport terdepresiasi (WS/HUP/gRPC/VMess/Trojan)."
    warn "Ini warning kompatibilitas upstream, bukan syntax error conf.d."
  fi

  return "${rc}"
}


check_tls_expiry() {
  if have_cmd openssl && [[ -f "${CERT_FULLCHAIN}" ]]; then
    local end
    end="$(openssl x509 -in "${CERT_FULLCHAIN}" -noout -enddate 2>/dev/null | sed -e 's/^notAfter=//' || true)"
    if [[ -n "${end}" ]]; then
      log "TLS notAfter: ${end}"
    else
      warn "Gagal baca expiry TLS"
    fi
  else
    warn "openssl/cert tidak tersedia, lewati cek TLS"
  fi
}

show_ports() {
  if have_cmd ss; then
    ss -lntp | sed -n '1,120p'
  else
    warn "ss tidak tersedia"
  fi
}

tail_logs() {
  local target="$1"
  local tail_lines="${2:-120}"
  if [[ "${target}" == "xray" ]]; then
    journalctl -u xray --no-pager -n "${tail_lines}"
  elif [[ "${target}" == "nginx" ]]; then
    journalctl -u nginx --no-pager -n "${tail_lines}"
  else
    die "Target log tidak dikenal: ${target}"
  fi
}


show_listeners_compact() {
  # Ringkas output listeners (80/443) tanpa users:(...)
  if ! have_cmd ss; then
    warn "ss tidak tersedia"
    return 0
  fi

  printf "%-6s %-22s %-8s %s\n" "PROTO" "LOCAL" "PORT" "PROC"
  printf "%-6s %-22s %-8s %s\n" "------" "----------------------" "--------" "----"

  ss -lntpH 2>/dev/null | awk '
    $1 == "LISTEN" {
      local=$4
      port=local
      sub(/.*:/,"",port)

      if (port ~ /^(80|443)$/) {
        proc="-"
        line=$0

        if (line ~ /users:\(\("/) {
          sub(/.*users:\(\("/, "", line)
          sub(/".*/, "", line)
          if (line != "") proc=line
        }

        printf "%-6s %-22s %-8s %s\n", "tcp", local, port, proc
      }
    }
  ' || true
}

sanity_check_now() {
  title
  echo "Sanity Check (core only)"
  hr
  svc_status_line xray
  svc_status_line nginx
  hr

  echo "Daemon Status:"
  svc_status_line xray-expired
  svc_status_line xray-quota
  svc_status_line xray-limit-ip
  hr

  check_files || true
  hr
  check_nginx_config || warn "Validasi nginx gagal (lanjut cek lain)."
  check_xray_config_json
  check_tls_expiry
  hr

  echo "Listeners (ringkas):"
  show_listeners_compact
  hr
  echo "[OK] Sanity check selesai (lihat WARN bila ada)."
  pause
}

status_diagnostics_menu() {
  title
  echo "9) Maintenance > Core Check"
  hr
  svc_status_line xray
  svc_status_line nginx
  svc_status_line "$(main_menu_edge_service_name)"
  svc_status_line "${SSHWS_DROPBEAR_SERVICE}"
  svc_status_line "${SSHWS_STUNNEL_SERVICE}"
  svc_status_line "${SSHWS_PROXY_SERVICE}"
  hr
  echo "Listeners (ringkas):"
  show_listeners_compact
  hr
  pause
}

trap 'domain_control_restore_on_exit' EXIT

# -------------------------
# Xray user management (placeholder)
# -------------------------


xray_backup_config() {
  # Create operation-local backup file to avoid cross-operation overwrite.
  # args: file_path (optional)
  local src b base
  src="${1:-${XRAY_INBOUNDS_CONF}}"
  base="$(basename "${src}")"

  [[ -f "${src}" ]] || die "File backup source tidak ditemukan: ${src}"
  mkdir -p "${WORK_DIR}" 2>/dev/null || true

  b="$(mktemp "${WORK_DIR}/${base}.prev.XXXXXX")" || die "Gagal membuat file backup untuk: ${src}"
  if ! cp -a "${src}" "${b}"; then
    rm -f "${b}" 2>/dev/null || true
    die "Gagal membuat backup untuk: ${src}"
  fi

  # Best-effort housekeeping: hapus backup historis (>7 hari) untuk file yang sama.
  find "${WORK_DIR}" -maxdepth 1 -type f -name "${base}.prev.*" -mtime +7 -delete 2>/dev/null || true

  echo "${b}"
}

xray_backup_path_prepare() {
  # Reserve a unique backup path without copying file content yet.
  # Use this when snapshot must be taken inside an existing lock section.
  local src="$1"
  local base path
  base="$(basename "${src}")"
  mkdir -p "${WORK_DIR}" 2>/dev/null || true
  path="$(mktemp "${WORK_DIR}/${base}.prev.XXXXXX")" || die "Gagal menyiapkan path backup untuk: ${src}"
  rm -f "${path}" 2>/dev/null || true
  echo "${path}"
}




xray_write_file_atomic() {
  # args: dest_path tmp_json_path
  local dest="$1"
  local src_tmp="$2"
  local dir base tmp_target mode uid gid

  dir="$(dirname "${dest}")"
  base="$(basename "${dest}")"

  ensure_path_writable "${dest}"

  tmp_target="$(mktemp "${dir}/.${base}.new.XXXXXX" 2>/dev/null || true)"
  [[ -n "${tmp_target}" ]] || die "Gagal membuat temp file untuk replace: ${dest}"

  mode="$(stat -c '%a' "${dest}" 2>/dev/null || echo '600')"
  uid="$(stat -c '%u' "${dest}" 2>/dev/null || echo '0')"
  gid="$(stat -c '%g' "${dest}" 2>/dev/null || echo '0')"

  if ! cp -f "${src_tmp}" "${tmp_target}"; then
    rm -f "${tmp_target}" 2>/dev/null || true
    die "Gagal menyiapkan temp file untuk replace: ${dest}"
  fi
  chmod "${mode}" "${tmp_target}" 2>/dev/null || chmod 600 "${tmp_target}" || true
  chown "${uid}:${gid}" "${tmp_target}" 2>/dev/null || chown 0:0 "${tmp_target}" || true

  mv -f "${tmp_target}" "${dest}" || {
    rm -f "${tmp_target}" 2>/dev/null || true
    die "Gagal replace ${dest} (permission denied / filesystem read-only / immutable)."
  }
}

xray_write_config_atomic() {
  # Backward-compat wrapper (writes inbounds conf).
  # args: tmp_json_path
  xray_write_file_atomic "${XRAY_INBOUNDS_CONF}" "$1"
}

xray_restart_or_rollback_file() {
  # args: target_file backup_file context_label
  local target="$1"
  local backup="$2"
  local ctx="${3:-config}"
  if ! xray_restart_checked; then
    cp -a "${backup}" "${target}" 2>/dev/null || die "xray tidak aktif setelah update ${ctx}; restore backup juga gagal: ${backup}"
    if ! xray_restart_checked; then
      die "xray tidak aktif setelah update ${ctx}; rollback runtime juga gagal setelah restore backup: ${backup}"
    fi
    die "xray tidak aktif setelah update ${ctx}. Config di-rollback ke backup: ${backup}"
  fi
}

xray_write_routing_locked() {
  # Wrapper xray_write_file_atomic untuk ROUTING_CONF dengan flock.
  # Gunakan ini untuk semua write ke 30-routing.json agar sinkron dengan
  # daemon Python (xray-quota, limit-ip, user-block) yang pakai lock yang sama.
  # args: tmp_json_path
  local tmp="$1"
  (
    flock -x 200
    xray_write_file_atomic "${XRAY_ROUTING_CONF}" "${tmp}"
  ) 200>"${ROUTING_LOCK_FILE}"
}

xray_txn_changed_flag() {
  # args: output_blob -> prints 1 or 0
  local out="${1:-}"
  local changed
  changed="$(printf '%s\n' "${out}" | awk -F'=' '/^changed=/{print $2; exit}')"
  if [[ "${changed}" == "1" ]]; then
    echo "1"
  else
    echo "0"
  fi
}

xray_txn_rc_or_die() {
  # args: rc fail_msg [restart_fail_msg] [syntax_fail_msg] [rollback_fail_msg]
  local rc="$1"
  local fail_msg="$2"
  local restart_fail_msg="${3:-}"
  local syntax_fail_msg="${4:-}"
  local rollback_fail_msg="${5:-}"

  if (( rc == 0 )); then
    return 0
  fi
  if (( rc == 87 )) && [[ -n "${syntax_fail_msg}" ]]; then
    die "${syntax_fail_msg}"
  fi
  if (( rc == 86 )) && [[ -n "${restart_fail_msg}" ]]; then
    die "${restart_fail_msg}"
  fi
  if (( rc == 88 )) && [[ -n "${rollback_fail_msg}" ]]; then
    die "${rollback_fail_msg}"
  fi
  die "${fail_msg}"
}

xray_txn_rc_or_warn() {
  # args: rc fail_msg [restart_fail_msg] [syntax_fail_msg] [rollback_fail_msg]
  local rc="$1"
  local fail_msg="$2"
  local restart_fail_msg="${3:-}"
  local syntax_fail_msg="${4:-}"
  local rollback_fail_msg="${5:-}"

  if (( rc == 0 )); then
    return 0
  fi
  if (( rc == 87 )) && [[ -n "${syntax_fail_msg}" ]]; then
    warn "${syntax_fail_msg}"
    return 1
  fi
  if (( rc == 86 )) && [[ -n "${restart_fail_msg}" ]]; then
    warn "${restart_fail_msg}"
    return 1
  fi
  if (( rc == 88 )) && [[ -n "${rollback_fail_msg}" ]]; then
    warn "${rollback_fail_msg}"
    return 1
  fi
  warn "${fail_msg}"
  return 1
}



xray_add_client() {
  # args: protocol username uuid_or_pass
  local proto="$1"
  local username="$2"
  local cred="$3"

  local email="${username}@${proto}"
  need_python3

  [[ -f "${XRAY_INBOUNDS_CONF}" ]] || die "Xray inbounds conf tidak ditemukan: ${XRAY_INBOUNDS_CONF}"
  ensure_path_writable "${XRAY_INBOUNDS_CONF}"

  local backup tmp out changed rc
  backup="$(xray_backup_path_prepare "${XRAY_INBOUNDS_CONF}")"
  tmp="${WORK_DIR}/10-inbounds.add.tmp"

  set +e
  out="$(
    (
      flock -x 200
      cp -a "${XRAY_INBOUNDS_CONF}" "${backup}" || exit 1

      py_out="$(
        python3 - <<'PY' "${XRAY_INBOUNDS_CONF}" "${tmp}" "${proto}" "${email}" "${cred}"
import json
import sys

src, dst, proto, email, cred = sys.argv[1:6]

with open(src, "r", encoding="utf-8") as f:
  cfg = json.load(f)

inbounds = cfg.get("inbounds", [])
if not isinstance(inbounds, list):
  raise SystemExit("Invalid config: inbounds is not a list")

def inbound_matches_proto(ib, p):
  if not isinstance(ib, dict):
    return False
  ib_proto = str(ib.get("protocol") or "").strip().lower()
  if p in ("vless", "vmess", "trojan"):
    return ib_proto == p
  return False

def iter_clients_for_protocol(p):
  for ib in inbounds:
    if not inbound_matches_proto(ib, p):
      continue
    st = ib.get("settings") or {}
    clients = st.get("clients")
    if isinstance(clients, list):
      for c in clients:
        yield c

for c in iter_clients_for_protocol(proto):
  if c.get("email") == email:
    raise SystemExit(f"user sudah ada di config untuk {proto}: {email}")

if proto == "vless":
  client = {"id": cred, "email": email}
elif proto == "vmess":
  client = {"id": cred, "alterId": 0, "email": email}
elif proto == "trojan":
  client = {"password": cred, "email": email}
else:
  raise SystemExit("Unsupported protocol: " + proto)

updated = False
for ib in inbounds:
  if not inbound_matches_proto(ib, proto):
    continue
  st = ib.setdefault("settings", {})
  clients = st.get("clients")
  if clients is None:
    st["clients"] = []
    clients = st["clients"]
  if not isinstance(clients, list):
    continue
  clients.append(client)
  updated = True

if not updated:
  raise SystemExit(f"Tidak menemukan inbound protocol {proto} dengan settings.clients")

with open(dst, "w", encoding="utf-8") as f:
  json.dump(cfg, f, ensure_ascii=False, indent=2)
  f.write("\n")

print("changed=1")
PY
      )" || exit 1

      printf '%s\n' "${py_out}"
      changed_local="$(xray_txn_changed_flag "${py_out}")"

      if [[ "${changed_local}" == "1" ]]; then
        xray_write_file_atomic "${XRAY_INBOUNDS_CONF}" "${tmp}" || {
          restore_file_if_exists "${backup}" "${XRAY_INBOUNDS_CONF}"
          exit 1
        }

        if ! xray_restart_checked; then
          if ! restore_file_if_exists "${backup}" "${XRAY_INBOUNDS_CONF}"; then
            exit 1
          fi
          if ! xray_restart_checked; then
            exit 88
          fi
          exit 86
        fi
      fi
    ) 200>"${ROUTING_LOCK_FILE}"
  )"
  rc=$?
  set -e

  xray_txn_rc_or_die "${rc}" \
    "Gagal memproses inbounds untuk add user: ${email}" \
    "xray tidak aktif setelah add user. Config di-rollback ke backup: ${backup}" \
    "" \
    "xray tidak aktif setelah add user, dan rollback runtime juga gagal setelah restore backup: ${backup}"

  changed="$(xray_txn_changed_flag "${out}")"
  if [[ "${changed}" != "1" ]]; then
    return 0
  fi
  return 0
}

xray_delete_client() {
  # args: protocol username
  local proto="$1"
  local username="$2"

  local email="${username}@${proto}"
  need_python3

  [[ -f "${XRAY_INBOUNDS_CONF}" ]] || die "Xray inbounds conf tidak ditemukan: ${XRAY_INBOUNDS_CONF}"
  [[ -f "${XRAY_ROUTING_CONF}" ]] || die "Xray routing conf tidak ditemukan: ${XRAY_ROUTING_CONF}"
  ensure_path_writable "${XRAY_INBOUNDS_CONF}"
  ensure_path_writable "${XRAY_ROUTING_CONF}"

  local backup_inb backup_rt tmp_inb tmp_rt out changed rc
  backup_inb="$(xray_backup_path_prepare "${XRAY_INBOUNDS_CONF}")"
  backup_rt="$(xray_backup_path_prepare "${XRAY_ROUTING_CONF}")"
  tmp_inb="${WORK_DIR}/10-inbounds.delete.tmp"
  tmp_rt="${WORK_DIR}/30-routing.delete.tmp"

  set +e
  out="$(
    (
      flock -x 200
      cp -a "${XRAY_INBOUNDS_CONF}" "${backup_inb}" || exit 1
      cp -a "${XRAY_ROUTING_CONF}" "${backup_rt}" || exit 1

      py_out="$(
        python3 - <<'PY' "${XRAY_INBOUNDS_CONF}" "${XRAY_ROUTING_CONF}" "${tmp_inb}" "${tmp_rt}" "${proto}" "${email}"
import json
import sys

inb_src, rt_src, inb_dst, rt_dst, proto, email = sys.argv[1:7]

with open(inb_src, "r", encoding="utf-8") as f:
  inb_cfg = json.load(f)
with open(rt_src, "r", encoding="utf-8") as f:
  rt_cfg = json.load(f)

inbounds = inb_cfg.get("inbounds", [])
if not isinstance(inbounds, list):
  raise SystemExit("Invalid inbounds config: inbounds is not a list")

def inbound_matches_proto(ib, p):
  if not isinstance(ib, dict):
    return False
  ib_proto = str(ib.get("protocol") or "").strip().lower()
  if p in ("vless", "vmess", "trojan"):
    return ib_proto == p
  return False

removed = 0
for ib in inbounds:
  if not inbound_matches_proto(ib, proto):
    continue
  st = ib.get("settings") or {}
  clients = st.get("clients")
  if not isinstance(clients, list):
    continue
  before = len(clients)
  clients[:] = [c for c in clients if c.get("email") != email]
  removed += (before - len(clients))
  st["clients"] = clients
  ib["settings"] = st

routing = (rt_cfg.get("routing") or {})
rules = routing.get("rules")
routing_changed = False
if isinstance(rules, list):
  markers = {"dummy-block-user","dummy-quota-user","dummy-limit-user","dummy-warp-user","dummy-direct-user"}
  speed_marker_prefix = "dummy-speed-user-"
  for r in rules:
    if not isinstance(r, dict):
      continue
    u = r.get("user")
    if not isinstance(u, list):
      continue
    managed = any(m in u for m in markers)
    if not managed:
      managed = any(isinstance(x, str) and x.startswith(speed_marker_prefix) for x in u)
    if not managed:
      continue
    new_users = [x for x in u if x != email]
    if new_users != u:
      routing_changed = True
    r["user"] = new_users
  routing["rules"] = rules
  rt_cfg["routing"] = routing

changed = removed > 0 or routing_changed
if not changed:
  print("changed=0")
  raise SystemExit(0)

with open(inb_dst, "w", encoding="utf-8") as f:
  json.dump(inb_cfg, f, ensure_ascii=False, indent=2)
  f.write("\n")
with open(rt_dst, "w", encoding="utf-8") as f:
  json.dump(rt_cfg, f, ensure_ascii=False, indent=2)
  f.write("\n")

print("changed=1")
PY
      )" || exit 1

      printf '%s\n' "${py_out}"
      changed_local="$(xray_txn_changed_flag "${py_out}")"

      if [[ "${changed_local}" == "1" ]]; then
        xray_write_file_atomic "${XRAY_INBOUNDS_CONF}" "${tmp_inb}" || {
          restore_file_if_exists "${backup_inb}" "${XRAY_INBOUNDS_CONF}"
          restore_file_if_exists "${backup_rt}" "${XRAY_ROUTING_CONF}"
          exit 1
        }
        xray_write_file_atomic "${XRAY_ROUTING_CONF}" "${tmp_rt}" || {
          restore_file_if_exists "${backup_inb}" "${XRAY_INBOUNDS_CONF}"
          restore_file_if_exists "${backup_rt}" "${XRAY_ROUTING_CONF}"
          exit 1
        }

        if ! xray_restart_checked; then
          if ! restore_file_if_exists "${backup_inb}" "${XRAY_INBOUNDS_CONF}"; then
            exit 1
          fi
          if ! restore_file_if_exists "${backup_rt}" "${XRAY_ROUTING_CONF}"; then
            exit 1
          fi
          if ! xray_restart_checked; then
            exit 88
          fi
          exit 86
        fi
      fi
    ) 200>"${ROUTING_LOCK_FILE}"
  )"
  rc=$?
  set -e

  xray_txn_rc_or_die "${rc}" \
    "Gagal memproses delete user (rollback ke backup): ${email}" \
    "xray tidak aktif setelah delete user. Config di-rollback ke backup." \
    "" \
    "xray tidak aktif setelah delete user, dan rollback runtime juga gagal setelah restore backup."

  changed="$(xray_txn_changed_flag "${out}")"
  if [[ "${changed}" != "1" ]]; then
    return 0
  fi
  return 0
}

xray_reset_client_credential() {
  # args: protocol username uuid_or_pass
  local proto="$1"
  local username="$2"
  local cred="$3"

  local email="${username}@${proto}"
  need_python3

  [[ -f "${XRAY_INBOUNDS_CONF}" ]] || die "Xray inbounds conf tidak ditemukan: ${XRAY_INBOUNDS_CONF}"
  ensure_path_writable "${XRAY_INBOUNDS_CONF}"

  local backup tmp out changed rc
  backup="$(xray_backup_path_prepare "${XRAY_INBOUNDS_CONF}")"
  tmp="${WORK_DIR}/10-inbounds.reset-cred.tmp"

  set +e
  out="$(
    (
      flock -x 200
      cp -a "${XRAY_INBOUNDS_CONF}" "${backup}" || exit 1

      py_out="$(
        python3 - <<'PY' "${XRAY_INBOUNDS_CONF}" "${tmp}" "${proto}" "${email}" "${cred}"
import json
import sys

src, dst, proto, email, cred = sys.argv[1:6]

with open(src, "r", encoding="utf-8") as f:
  cfg = json.load(f)

inbounds = cfg.get("inbounds", [])
if not isinstance(inbounds, list):
  raise SystemExit("Invalid config: inbounds is not a list")

def inbound_matches_proto(ib, p):
  if not isinstance(ib, dict):
    return False
  ib_proto = str(ib.get("protocol") or "").strip().lower()
  if p in ("vless", "vmess", "trojan"):
    return ib_proto == p
  return False

updated = 0
for ib in inbounds:
  if not inbound_matches_proto(ib, proto):
    continue
  st = ib.get("settings") or {}
  clients = st.get("clients")
  if not isinstance(clients, list):
    continue
  for c in clients:
    if not isinstance(c, dict):
      continue
    if c.get("email") != email:
      continue
    if proto == "trojan":
      c["password"] = cred
      c.pop("id", None)
    else:
      c["id"] = cred
      c.pop("password", None)
      if proto == "vmess":
        try:
          c["alterId"] = int(c.get("alterId") or 0)
        except Exception:
          c["alterId"] = 0
    updated += 1

if updated == 0:
  raise SystemExit(f"user tidak ditemukan di config untuk {proto}: {email}")

with open(dst, "w", encoding="utf-8") as f:
  json.dump(cfg, f, ensure_ascii=False, indent=2)
  f.write("\n")

print("changed=1")
PY
      )" || exit 1

      printf '%s\n' "${py_out}"
      changed_local="$(xray_txn_changed_flag "${py_out}")"

      if [[ "${changed_local}" == "1" ]]; then
        xray_write_file_atomic "${XRAY_INBOUNDS_CONF}" "${tmp}" || {
          restore_file_if_exists "${backup}" "${XRAY_INBOUNDS_CONF}"
          exit 1
        }

        if ! xray_restart_checked; then
          if ! restore_file_if_exists "${backup}" "${XRAY_INBOUNDS_CONF}"; then
            exit 1
          fi
          if ! xray_restart_checked; then
            exit 88
          fi
          exit 86
        fi
      fi
    ) 200>"${ROUTING_LOCK_FILE}"
  )"
  rc=$?
  set -e

  xray_txn_rc_or_die "${rc}" \
    "Gagal reset UUID/password user: ${email}" \
    "xray tidak aktif setelah reset UUID/password. Config di-rollback ke backup: ${backup}" \
    "" \
    "xray tidak aktif setelah reset UUID/password, dan rollback runtime juga gagal setelah restore backup: ${backup}"

  changed="$(xray_txn_changed_flag "${out}")"
  if [[ "${changed}" != "1" ]]; then
    return 0
  fi
  return 0
}

xray_routing_set_user_in_marker() {
  # args: marker email on|off [outbound_tag]
  # outbound_tag defaults to 'blocked' for backward compatibility
  local marker="$1"
  local email="$2"
  local state="$3"
  # BUG-08 fix: outboundTag is now a parameter instead of hardcoded 'blocked'.
  # Previously this function silently failed for any marker whose rule used a
  # different outboundTag (e.g. dummy-warp-user → 'warp', dummy-direct-user → 'direct').
  local outbound_tag="${4:-blocked}"

  need_python3
  [[ -f "${XRAY_ROUTING_CONF}" ]] || die "Xray routing conf tidak ditemukan: ${XRAY_ROUTING_CONF}"
  ensure_path_writable "${XRAY_ROUTING_CONF}"

  local backup tmp out changed rc
  backup="$(xray_backup_path_prepare "${XRAY_ROUTING_CONF}")"
  tmp="${WORK_DIR}/30-routing.marker.tmp"

  # Load + modify + save + restart + rollback di lock yang sama agar tidak menimpa perubahan concurrent.
  set +e
  out="$(
    (
      flock -x 200
      cp -a "${XRAY_ROUTING_CONF}" "${backup}" || exit 1

      py_out="$(
        python3 - <<'PY' "${XRAY_ROUTING_CONF}" "${tmp}" "${marker}" "${email}" "${state}" "${outbound_tag}"
import json, sys
src, dst, marker, email, state, outbound_tag = sys.argv[1:7]

with open(src, "r", encoding="utf-8") as f:
  cfg = json.load(f)

routing = cfg.get("routing") or {}
rules = routing.get("rules")
if not isinstance(rules, list):
  raise SystemExit("Invalid routing config: routing.rules is not a list")

target = None
for r in rules:
  if not isinstance(r, dict):
    continue
  if r.get("type") != "field":
    continue
  if r.get("outboundTag") != outbound_tag:
    continue
  u = r.get("user")
  if not isinstance(u, list):
    continue
  if marker in u:
    target = r
    break

if target is None:
  raise SystemExit(f"Tidak menemukan routing rule outboundTag={outbound_tag} dengan marker: {marker}")

users = target.get("user") or []
if not isinstance(users, list):
  users = []

if marker not in users:
  users.insert(0, marker)
else:
  users = [marker] + [x for x in users if x != marker]

changed = False
if state == "on":
  if email not in users:
    users.append(email)
    changed = True
elif state == "off":
  new_users = [x for x in users if x != email]
  if new_users != users:
    users = new_users
    changed = True
else:
  raise SystemExit("state harus 'on' atau 'off'")

target["user"] = users
routing["rules"] = rules
cfg["routing"] = routing

if changed:
  with open(dst, "w", encoding="utf-8") as wf:
    json.dump(cfg, wf, ensure_ascii=False, indent=2)
    wf.write("\n")

print("changed=1" if changed else "changed=0")
PY
      )" || exit 1

      printf '%s\n' "${py_out}"
      changed_local="$(xray_txn_changed_flag "${py_out}")"

      if [[ "${changed_local}" == "1" ]]; then
        xray_write_file_atomic "${XRAY_ROUTING_CONF}" "${tmp}" || {
          restore_file_if_exists "${backup}" "${XRAY_ROUTING_CONF}"
          exit 1
        }

        if ! xray_restart_checked; then
          if ! restore_file_if_exists "${backup}" "${XRAY_ROUTING_CONF}"; then
            exit 1
          fi
          if ! xray_restart_checked; then
            exit 88
          fi
          exit 86
        fi
      fi
    ) 200>"${ROUTING_LOCK_FILE}"
  )"
  rc=$?
  set -e

  xray_txn_rc_or_die "${rc}" \
    "Gagal memproses routing: ${XRAY_ROUTING_CONF}" \
    "xray tidak aktif setelah update routing. Routing di-rollback ke backup: ${backup}" \
    "" \
    "xray tidak aktif setelah update routing, dan rollback runtime juga gagal setelah restore backup: ${backup}"

  changed="$(xray_txn_changed_flag "${out}")"
  if [[ "${changed}" != "1" ]]; then
    return 0
  fi
  return 0
}


xray_extract_endpoints() {
  # args: protocol -> prints lines: network|path_or_service
  local proto="$1"
  need_python3
  python3 - <<'PY' "${XRAY_INBOUNDS_CONF}" "${proto}"
import json, sys
src, proto = sys.argv[1:3]
with open(src,'r',encoding='utf-8') as f:
  cfg=json.load(f)

seen=set()
for ib in cfg.get('inbounds', []) or []:
  if ib.get('protocol') != proto:
    continue
  ss = ib.get('streamSettings') or {}
  net = ss.get('network') or ''
  if not net:
    continue
  val=''
  if net == 'ws':
    ws = ss.get('wsSettings') or {}
    val = ws.get('path') or ''
  elif net in ('httpupgrade','httpUpgrade'):
    hu = ss.get('httpUpgradeSettings') or ss.get('httpupgradeSettings') or {}
    val = hu.get('path') or ''
  elif net == 'grpc':
    gs = ss.get('grpcSettings') or {}
    val = gs.get('serviceName') or ''
  key=(net,val)
  if key in seen:
    continue
  seen.add(key)
  print(net + "|" + val)
PY
}

speed_policy_file_path() {
  # args: proto username
  local proto="$1"
  local username="$2"
  echo "${SPEED_POLICY_ROOT}/${proto}/${username}@${proto}.json"
}

speed_policy_exists() {
  # args: proto username
  local proto="$1"
  local username="$2"
  local f
  f="$(speed_policy_file_path "${proto}" "${username}")"
  [[ -f "${f}" ]]
}

speed_policy_remove() {
  # args: proto username
  local proto="$1"
  local username="$2"
  local f
  f="$(speed_policy_file_path "${proto}" "${username}")"
  speed_policy_lock_prepare
  (
    flock -x 200
    if [[ -f "${f}" ]]; then
      rm -f "${f}" 2>/dev/null || true
    fi
  ) 200>"${SPEED_POLICY_LOCK_FILE}"
}

speed_policy_remove_checked() {
  # args: proto username
  local proto="$1"
  local username="$2"
  local f
  f="$(speed_policy_file_path "${proto}" "${username}")"
  speed_policy_lock_prepare
  (
    flock -x 200
    if [[ ! -f "${f}" ]]; then
      exit 0
    fi
    rm -f "${f}" || exit 1
    [[ ! -e "${f}" ]]
  ) 200>"${SPEED_POLICY_LOCK_FILE}"
}

speed_policy_upsert() {
  # args: proto username down_mbit up_mbit
  local proto="$1"
  local username="$2"
  local down_mbit="$3"
  local up_mbit="$4"

  ensure_speed_policy_dirs
  speed_policy_lock_prepare
  need_python3

  local email out_file mark
  email="${username}@${proto}"
  out_file="$(speed_policy_file_path "${proto}" "${username}")"

  mark="$(
    (
      flock -x 200
      python3 - <<'PY' "${SPEED_POLICY_ROOT}" "${proto}" "${email}" "${down_mbit}" "${up_mbit}" "${out_file}"
import zlib
import json
import os
import sys
import tempfile
from datetime import datetime, timezone

root, proto, email, down_raw, up_raw, out_file = sys.argv[1:7]

def to_float(v):
  try:
    n = float(v)
  except Exception:
    return 0.0
  if n <= 0:
    return 0.0
  return round(n, 3)

down = to_float(down_raw)
up = to_float(up_raw)
if down <= 0 or up <= 0:
  raise SystemExit("speed mbit harus > 0")

MARK_MIN = 1000
MARK_MAX = 59999
RANGE = MARK_MAX - MARK_MIN + 1

def valid_mark(v):
  try:
    m = int(v)
  except Exception:
    return False
  return MARK_MIN <= m <= MARK_MAX

def load_json(path):
  try:
    with open(path, "r", encoding="utf-8") as f:
      return json.load(f)
  except Exception:
    return {}

used = set()
for p1 in ("vless", "vmess", "trojan"):
  d = os.path.join(root, p1)
  if not os.path.isdir(d):
    continue
  for name in os.listdir(d):
    if not name.endswith(".json"):
      continue
    fp = os.path.join(d, name)
    if os.path.abspath(fp) == os.path.abspath(out_file):
      continue
    data = load_json(fp)
    m = data.get("mark")
    if valid_mark(m):
      used.add(int(m))

existing = load_json(out_file)
existing_mark = existing.get("mark")

if valid_mark(existing_mark) and int(existing_mark) not in used:
  mark = int(existing_mark)
else:
  seed = zlib.crc32(email.encode("utf-8")) & 0xFFFFFFFF
  start = MARK_MIN + (seed % RANGE)
  mark = None
  for i in range(RANGE):
    cand = MARK_MIN + ((start - MARK_MIN + i) % RANGE)
    if cand not in used:
      mark = cand
      break
  if mark is None:
    raise SystemExit("mark speed policy habis")

payload = {
  "enabled": True,
  "username": email,
  "protocol": proto,
  "mark": mark,
  "down_mbit": down,
  "up_mbit": up,
  "updated_at": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M"),
}

os.makedirs(os.path.dirname(out_file) or ".", exist_ok=True)
fd, tmp = tempfile.mkstemp(prefix=".tmp.", suffix=".json", dir=os.path.dirname(out_file) or ".")
try:
  with os.fdopen(fd, "w", encoding="utf-8") as f:
    json.dump(payload, f, ensure_ascii=False, indent=2)
    f.write("\n")
    f.flush()
    os.fsync(f.fileno())
  os.replace(tmp, out_file)
finally:
  try:
    if os.path.exists(tmp):
      os.remove(tmp)
  except Exception:
    pass

print(mark)
PY
    ) 200>"${SPEED_POLICY_LOCK_FILE}"
  )" || return 1

  [[ -n "${mark:-}" ]] || return 1
  chmod 600 "${out_file}" 2>/dev/null || true
  echo "${mark}"
}

speed_policy_apply_now() {
  if [[ -x /usr/local/bin/xray-speed && -f "${SPEED_CONFIG_FILE}" ]]; then
    /usr/local/bin/xray-speed once --config "${SPEED_CONFIG_FILE}" >/dev/null 2>&1 && return 0
  fi
  if svc_exists xray-speed; then
    svc_restart_checked xray-speed 20 >/dev/null 2>&1 || return 1
    svc_is_active xray-speed && return 0
  fi
  return 1
}

speed_policy_sync_xray() {
  need_python3
  [[ -f "${XRAY_OUTBOUNDS_CONF}" ]] || return 1
  [[ -f "${XRAY_ROUTING_CONF}" ]] || return 1
  ensure_path_writable "${XRAY_OUTBOUNDS_CONF}"
  ensure_path_writable "${XRAY_ROUTING_CONF}"

  local backup_out backup_rt tmp_out tmp_rt rc
  backup_out="$(xray_backup_path_prepare "${XRAY_OUTBOUNDS_CONF}")"
  backup_rt="$(xray_backup_path_prepare "${XRAY_ROUTING_CONF}")"
  tmp_out="${WORK_DIR}/20-outbounds.json.tmp"
  tmp_rt="${WORK_DIR}/30-routing-speed.json.tmp"

  set +e
  (
    flock -x 200
    cp -a "${XRAY_OUTBOUNDS_CONF}" "${backup_out}" || exit 1
    cp -a "${XRAY_ROUTING_CONF}" "${backup_rt}" || exit 1
    python3 - <<'PY' \
      "${SPEED_POLICY_ROOT}" \
      "${XRAY_OUTBOUNDS_CONF}" \
      "${XRAY_ROUTING_CONF}" \
      "${tmp_out}" \
      "${tmp_rt}" \
      "${SPEED_OUTBOUND_TAG_PREFIX}" \
      "${SPEED_RULE_MARKER_PREFIX}" \
      "${SPEED_MARK_MIN}" \
      "${SPEED_MARK_MAX}"
import copy
import json
import os
import re
import sys

policy_root, out_src, rt_src, out_dst, rt_dst, out_prefix, marker_prefix, mark_min_raw, mark_max_raw = sys.argv[1:10]
mark_min = int(mark_min_raw)
mark_max = int(mark_max_raw)

def load_json(path):
  with open(path, "r", encoding="utf-8") as f:
    return json.load(f)

def dump_json(path, obj):
  with open(path, "w", encoding="utf-8") as f:
    json.dump(obj, f, ensure_ascii=False, indent=2)
    f.write("\n")

def boolify(v):
  if isinstance(v, bool):
    return v
  if isinstance(v, (int, float)):
    return bool(v)
  s = str(v or "").strip().lower()
  return s in ("1", "true", "yes", "on", "y")

def to_float(v):
  try:
    n = float(v)
  except Exception:
    return 0.0
  if n <= 0:
    return 0.0
  return n

def to_mark(v):
  try:
    m = int(v)
  except Exception:
    return None
  if m < mark_min or m > mark_max:
    return None
  return m

def list_mark_users(root):
  mark_users = {}
  for proto in ("vless", "vmess", "trojan"):
    d = os.path.join(root, proto)
    if not os.path.isdir(d):
      continue
    for name in sorted(os.listdir(d)):
      if not name.endswith(".json"):
        continue
      fp = os.path.join(d, name)
      try:
        data = load_json(fp)
      except Exception:
        continue
      if not isinstance(data, dict):
        continue
      if not boolify(data.get("enabled", True)):
        continue
      mark = to_mark(data.get("mark"))
      if mark is None:
        continue
      down = to_float(data.get("down_mbit"))
      up = to_float(data.get("up_mbit"))
      if down <= 0 or up <= 0:
        continue
      email = str(data.get("username") or data.get("email") or os.path.splitext(name)[0]).strip()
      if not email:
        continue
      mark_users.setdefault(mark, set()).add(email)
  return {k: sorted(v) for k, v in sorted(mark_users.items())}

def is_default_rule(r):
  if not isinstance(r, dict):
    return False
  if r.get("type") != "field":
    return False
  port = str(r.get("port", "")).strip()
  if port not in ("1-65535", "0-65535"):
    return False
  if r.get("user") or r.get("domain") or r.get("ip") or r.get("protocol"):
    return False
  return True

def is_protected_rule(r):
  if not isinstance(r, dict):
    return False
  if r.get("type") != "field":
    return False
  ot = r.get("outboundTag")
  return isinstance(ot, str) and ot in ("api", "blocked")

def norm_tag(v):
  if not isinstance(v, str):
    return ""
  return v.strip()

def sanitize_tag(v):
  s = norm_tag(v)
  if not s:
    return "x"
  return re.sub(r"[^A-Za-z0-9_.-]", "-", s)

mark_users = list_mark_users(policy_root)

out_cfg = load_json(out_src)
outbounds = out_cfg.get("outbounds")
if not isinstance(outbounds, list):
  raise SystemExit("Invalid outbounds config: outbounds bukan list")
outbounds_by_tag = {}
for o in outbounds:
  if not isinstance(o, dict):
    continue
  t = norm_tag(o.get("tag"))
  if not t:
    continue
  outbounds_by_tag[t] = o

rt_cfg = load_json(rt_src)
routing = rt_cfg.get("routing") or {}
rules = routing.get("rules")
if not isinstance(rules, list):
  raise SystemExit("Invalid routing config: routing.rules bukan list")

default_rule = None
for r in rules:
  if is_default_rule(r):
    default_rule = r

base_selector = []
if isinstance(default_rule, dict):
  ot = norm_tag(default_rule.get("outboundTag"))
  if ot:
    base_selector = [ot]

if not base_selector:
  if "direct" in outbounds_by_tag:
    base_selector = ["direct"]
  else:
    for t in outbounds_by_tag.keys():
      if not t.startswith(out_prefix):
        base_selector = [t]
        break
if not base_selector:
  raise SystemExit("Outbound dasar untuk speed policy tidak ditemukan")

effective_selector = []
seen = set()
for t in base_selector:
  t2 = norm_tag(t)
  if not t2:
    continue
  if t2 in ("api", "blocked"):
    continue
  if t2.startswith(out_prefix):
    continue
  if t2 not in outbounds_by_tag:
    continue
  if t2 in seen:
    continue
  seen.add(t2)
  effective_selector.append(t2)
if not effective_selector:
  # Recovery path untuk konfigurasi non-kanonik/tidak valid:
  # jika selector dasar berisi tag speed/internal saja, fallback ke outbound non-speed.
  if "direct" in outbounds_by_tag:
    effective_selector = ["direct"]
  else:
    for t in outbounds_by_tag.keys():
      t2 = norm_tag(t)
      if not t2:
        continue
      if t2 in ("api", "blocked"):
        continue
      if t2.startswith(out_prefix):
        continue
      effective_selector = [t2]
      break
if not effective_selector:
  raise SystemExit("Selector outbound dasar untuk speed policy kosong")

clean_outbounds = []
for o in outbounds:
  if isinstance(o, dict):
    tag = norm_tag(o.get("tag"))
    if tag and tag.startswith(out_prefix):
      continue
  clean_outbounds.append(o)

mark_out_tags = {}
for mark in sorted(mark_users.keys()):
  per_mark = {}
  for base_tag in effective_selector:
    src = outbounds_by_tag.get(base_tag)
    if not isinstance(src, dict):
      continue
    clone_tag = f"{out_prefix}{mark}-{sanitize_tag(base_tag)}"
    so = copy.deepcopy(src)
    so["tag"] = clone_tag
    ss = so.get("streamSettings")
    if not isinstance(ss, dict):
      ss = {}
    sock = ss.get("sockopt")
    if not isinstance(sock, dict):
      sock = {}
    sock["mark"] = int(mark)
    ss["sockopt"] = sock
    so["streamSettings"] = ss
    clean_outbounds.append(so)
    per_mark[base_tag] = clone_tag
  mark_out_tags[mark] = per_mark

out_cfg["outbounds"] = clean_outbounds
dump_json(out_dst, out_cfg)

kept_rules = []
for r in rules:
  if not isinstance(r, dict):
    kept_rules.append(r)
    continue
  if r.get("type") != "field":
    kept_rules.append(r)
    continue
  users = r.get("user")
  ot = norm_tag(r.get("outboundTag"))
  has_speed_marker = isinstance(users, list) and any(
    isinstance(x, str) and x.startswith(marker_prefix) for x in users
  )
  if has_speed_marker and ot.startswith(out_prefix):
    continue
  kept_rules.append(r)

insert_idx = len(kept_rules)
for i, r in enumerate(kept_rules):
  if is_protected_rule(r):
    continue
  insert_idx = i
  break

speed_rules = []
for mark, users in sorted(mark_users.items()):
  marker = f"{marker_prefix}{mark}"
  rule = {
    "type": "field",
    "user": [marker] + users,
  }
  first_base = effective_selector[0]
  ot = mark_out_tags.get(mark, {}).get(first_base, "")
  if not ot:
    continue
  rule["outboundTag"] = ot
  speed_rules.append(rule)

merged_rules = kept_rules[:insert_idx] + speed_rules + kept_rules[insert_idx:]
routing["rules"] = merged_rules
rt_cfg["routing"] = routing
dump_json(rt_dst, rt_cfg)
PY
    xray_write_file_atomic "${XRAY_OUTBOUNDS_CONF}" "${tmp_out}" || {
      restore_file_if_exists "${backup_out}" "${XRAY_OUTBOUNDS_CONF}"
      restore_file_if_exists "${backup_rt}" "${XRAY_ROUTING_CONF}"
      exit 1
    }
    xray_write_file_atomic "${XRAY_ROUTING_CONF}" "${tmp_rt}" || {
      restore_file_if_exists "${backup_out}" "${XRAY_OUTBOUNDS_CONF}"
      restore_file_if_exists "${backup_rt}" "${XRAY_ROUTING_CONF}"
      exit 1
    }

	    if ! xray_restart_checked; then
	      if ! restore_file_if_exists "${backup_out}" "${XRAY_OUTBOUNDS_CONF}"; then
	        echo "rollback speed policy gagal: restore outbounds backup gagal" >&2
	        exit 1
	      fi
	      if ! restore_file_if_exists "${backup_rt}" "${XRAY_ROUTING_CONF}"; then
	        echo "rollback speed policy gagal: restore routing backup gagal" >&2
	        exit 1
	      fi
	      if ! xray_restart_checked; then
	        echo "rollback speed policy gagal: xray tidak aktif setelah restore backup" >&2
	        exit 1
	      fi
	      exit 86
	    fi
  ) 200>"${ROUTING_LOCK_FILE}"
  rc=$?
  set -e

  if (( rc == 0 )); then
    return 0
  fi
  return 1
}

rollback_new_user_after_create_failure() {
  # args: proto username [reason] [inbounds_created=true|false]
  local proto="$1"
  local username="$2"
  local reason="${3:-operasi create gagal}"
  local inbounds_created="${4:-true}"
  local email="${username}@${proto}" failed=0

  warn "Rollback akun ${email}: ${reason}."
  if [[ "${inbounds_created}" == "true" ]]; then
    if ! xray_delete_client_try "${proto}" "${username}"; then
      warn "Rollback inbounds gagal untuk ${email}"
      failed=1
    fi
  fi
  if ! delete_account_artifacts_checked "${proto}" "${username}"; then
    warn "Rollback artefak lokal gagal untuk ${email}"
    failed=1
  fi
  if ! speed_policy_remove_checked "${proto}" "${username}"; then
    warn "Rollback cleanup speed policy file gagal untuk ${email}"
    failed=1
  fi
  if ! speed_policy_sync_xray_try; then
    warn "Rollback sinkronisasi speed policy gagal untuk ${email}"
    failed=1
  elif ! speed_policy_apply_now >/dev/null 2>&1; then
    warn "Rollback apply runtime speed policy gagal untuk ${email}"
    failed=1
  fi
  return "${failed}"
}

rollback_new_user_after_speed_failure() {
  # args: proto username
  rollback_new_user_after_create_failure "$1" "$2" "setup speed-limit gagal"
}

write_account_artifacts() {
  # args: protocol username cred quota_bytes days ip_limit_enabled ip_limit_value speed_enabled speed_down_mbit speed_up_mbit [account_output_override] [quota_output_override]
  local proto="$1"
  local username="$2"
  local cred="$3"
  local quota_bytes="$4"
  local days="$5"
  local ip_enabled="$6"
  local ip_limit="$7"
  local speed_enabled="$8"
  local speed_down="$9"
  local speed_up="${10}"
  local account_output_override="${11:-}"
  local quota_output_override="${12:-}"

  ensure_account_quota_dirs
  need_python3

  local domain ip created expired geo geo_ip isp country
  domain="$(detect_domain)"
  ip="$(detect_public_ip_ipapi)"
  created="$(date '+%Y-%m-%d %H:%M')"
  expired="$(date -d "+${days} days" '+%Y-%m-%d' 2>/dev/null || date '+%Y-%m-%d')"
  geo="$(main_info_geo_lookup "${ip}")"
  IFS='|' read -r geo_ip isp country <<<"${geo}"
  [[ -n "${geo_ip}" && "${geo_ip}" != "-" ]] && ip="${geo_ip}"
  [[ -n "${isp}" ]] || isp="-"
  [[ -n "${country}" ]] || country="-"

  local acc_file quota_file
  acc_file="${ACCOUNT_ROOT}/${proto}/${username}@${proto}.txt"
  quota_file="${QUOTA_ROOT}/${proto}/${username}@${proto}.json"
  [[ -n "${account_output_override}" ]] && acc_file="${account_output_override}"
  [[ -n "${quota_output_override}" ]] && quota_file="${quota_output_override}"

  python3 - <<'PY' "${acc_file}" "${quota_file}" "${XRAY_INBOUNDS_CONF}" "${domain}" "${ip}" "${isp}" "${country}" "${username}" "${proto}" "${cred}" "${quota_bytes}" "${created}" "${expired}" "${days}" "${ip_enabled}" "${ip_limit}" "${speed_enabled}" "${speed_down}" "${speed_up}"
import sys, json, base64, urllib.parse, datetime, os, tempfile, ipaddress
acc_file, quota_file, inbounds_file, domain, ip, isp, country, username, proto, cred, quota_bytes, created_at, expired_at, days, ip_enabled, ip_limit, speed_enabled, speed_down, speed_up = sys.argv[1:20]
quota_bytes=int(quota_bytes)
days=int(float(days)) if str(days).strip() else 0
ip_enabled = str(ip_enabled).lower() in ("1","true","yes","y","on")
speed_enabled = str(speed_enabled).lower() in ("1","true","yes","y","on")
try:
  ip_limit_int=int(ip_limit)
except Exception:
  ip_limit_int=0
try:
  speed_down_mbit=float(speed_down)
except Exception:
  speed_down_mbit=0.0
try:
  speed_up_mbit=float(speed_up)
except Exception:
  speed_up_mbit=0.0
if not speed_enabled or speed_down_mbit <= 0 or speed_up_mbit <= 0:
  speed_enabled=False
  speed_down_mbit=0.0
  speed_up_mbit=0.0

def fmt_gb(v):
  try:
    v=float(v)
  except Exception:
    return "0"
  if v <= 0:
    return "0"
  if abs(v - round(v)) < 1e-9:
    return str(int(round(v)))
  s=f"{v:.2f}"
  s=s.rstrip("0").rstrip(".")
  return s

def fmt_mbit(v):
  try:
    n=float(v)
  except Exception:
    return "0"
  if n <= 0:
    return "0"
  if abs(n-round(n)) < 1e-9:
    return str(int(round(n)))
  s=f"{n:.2f}"
  return s.rstrip("0").rstrip(".")

PROTO_LABELS = {
  "vless": "Vless",
  "vmess": "Vmess",
  "trojan": "Trojan",
}

def proto_label(p):
  return PROTO_LABELS.get(str(p or "").strip().lower(), str(p or "").strip().title() or "Xray")

def path_alt_placeholder(path):
  raw = str(path or "").strip()
  if not raw:
    return "-"
  if not raw.startswith("/"):
    raw = "/" + raw
  return f"/<bebas>{raw}"


def service_alt_placeholder(service):
  raw = str(service or "").strip()
  if not raw or raw == "-":
    return "-"
  return f"<bebas>/{raw.lstrip('/')}"

def section_line(label, value, width):
  return f"  {label:<{width}} : {value}"

def append_link_block(lines, label, value):
  lines.append(f"    {label:<12} :")
  lines.append(str(value or "-"))

def is_public_ipv4(raw):
  try:
    addr = ipaddress.ip_address(str(raw).strip())
  except Exception:
    return False
  return (
    addr.version == 4
    and not addr.is_private
    and not addr.is_loopback
    and not addr.is_link_local
    and not addr.is_multicast
    and not addr.is_unspecified
    and not addr.is_reserved
  )

def write_text_atomic(path, content):
  dirn = os.path.dirname(path) or "."
  os.makedirs(dirn, exist_ok=True)
  fd, tmp = tempfile.mkstemp(prefix=".tmp.", suffix=".txt", dir=dirn)
  try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
      f.write(content)
      f.flush()
      os.fsync(f.fileno())
    os.replace(tmp, path)
  finally:
    try:
      if os.path.exists(tmp):
        os.remove(tmp)
    except Exception:
      pass

def write_json_atomic(path, obj):
  dirn = os.path.dirname(path) or "."
  os.makedirs(dirn, exist_ok=True)
  fd, tmp = tempfile.mkstemp(prefix=".tmp.", suffix=".json", dir=dirn)
  try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
      json.dump(obj, f, ensure_ascii=False, indent=2)
      f.write("\n")
      f.flush()
      os.fsync(f.fileno())
    os.replace(tmp, path)
  finally:
    try:
      if os.path.exists(tmp):
        os.remove(tmp)
    except Exception:
      pass

# Public endpoint harus selaras dengan nginx public path (setup.sh).
PUBLIC_PATHS = {
  "vless": {"ws": "/vless-ws", "httpupgrade": "/vless-hup", "grpc": "vless-grpc"},
  "vmess": {"ws": "/vmess-ws", "httpupgrade": "/vmess-hup", "grpc": "vmess-grpc"},
  "trojan": {"ws": "/trojan-ws", "httpupgrade": "/trojan-hup", "grpc": "trojan-grpc"},
}
TCP_TLS_PROTOCOLS = {"vless", "trojan"}


def vless_link(net, val):
  q={"encryption":"none","security":"tls","type":net,"sni":domain}
  if net in ("ws","httpupgrade"):
    q["path"]=val or "/"
  elif net=="grpc":
    if val:
      q["serviceName"]=val
  return f"vless://{cred}@{domain}:443?{urllib.parse.urlencode(q)}#{urllib.parse.quote(username + "@" + proto)}"

def trojan_link(net, val):
  q={"security":"tls","type":net,"sni":domain}
  if net in ("ws","httpupgrade"):
    q["path"]=val or "/"
  elif net=="grpc":
    if val:
      q["serviceName"]=val
  return f"trojan://{cred}@{domain}:443?{urllib.parse.urlencode(q)}#{urllib.parse.quote(username + "@" + proto)}"

def vmess_link(net, val):
  obj={
    "v":"2",
    "ps":username + "@" + proto,
    "add":domain,
    "port":"443",
    "id":cred,
    "aid":"0",
    "net":net,
    "type":"none",
    "host":domain,
    "tls":"tls",
    "sni":domain
  }
  if net in ("ws","httpupgrade"):
    obj["path"]=val or "/"
  elif net=="grpc":
    obj["path"]=val or ""  # many clients use path as serviceName
    obj["type"]="gun"
  raw=json.dumps(obj, separators=(",",":"))
  return "vmess://" + base64.b64encode(raw.encode()).decode()

links={}
public_proto = PUBLIC_PATHS.get(proto, {})
nets = ["ws", "httpupgrade", "grpc"]
if proto in TCP_TLS_PROTOCOLS:
  nets = ["tcp"] + nets
for net in nets:
  val = public_proto.get(net, "")
  if proto=="vless":
    links[net]=vless_link(net,val)
  elif proto=="vmess":
    links[net]=vmess_link(net,val)
  elif proto=="trojan":
    links[net]=trojan_link(net,val)

quota_gb = quota_bytes/(1024**3) if quota_bytes else 0
quota_gb_disp = fmt_gb(quota_gb)
proto_disp = proto_label(proto)
ws_path = public_proto.get("ws", "") or "/"
ws_path_alt = path_alt_placeholder(ws_path)
hup_path = public_proto.get("httpupgrade", "") or "/"
hup_path_alt = path_alt_placeholder(hup_path)
grpc_service = public_proto.get("grpc", "") or "-"
grpc_service_alt = service_alt_placeholder(grpc_service)
created_disp = created_at[:10] if len(created_at) >= 10 and created_at[4:5] == "-" and created_at[7:8] == "-" else created_at
running_labels = [
  f"{proto_disp} WS",
  f"{proto_disp} HUP",
  f"{proto_disp} gRPC",
  f"{proto_disp} Path WS",
  f"{proto_disp} Path WS Alt",
  f"{proto_disp} Path HUP",
  f"{proto_disp} Path HUP Alt",
  f"{proto_disp} Path Service",
  f"{proto_disp} Path Service Alt",
]
if proto in TCP_TLS_PROTOCOLS:
  running_labels.append(f"{proto_disp} TCP+TLS Port")
running_label_width = max(len(label) for label in running_labels)

# Write account txt
lines=[]
lines.append("=== XRAY ACCOUNT INFO ===")
lines.append(f"  Domain      : {domain}")
lines.append(f"  IP          : {ip}")
lines.append(f"  ISP         : {isp or '-'}")
lines.append(f"  Country     : {country or '-'}")
lines.append(f"  Username    : {username}")
lines.append(f"  Protocol    : {proto}")
if proto in ("vless","vmess"):
  lines.append(f"  UUID        : {cred}")
else:
  lines.append(f"  Password    : {cred}")
lines.append(f"  Quota Limit : {quota_gb_disp} GB")
lines.append(f"  Expired     : {days} days")
lines.append(f"  Valid Until : {expired_at}")
lines.append(f"  Created     : {created_disp}")
lines.append(f"  IP Limit    : {'ON' if ip_enabled else 'OFF'}" + (f" ({ip_limit_int})" if ip_enabled and ip_limit_int > 0 else ""))
if speed_enabled:
  lines.append(f"  Speed Limit : ON (DOWN {fmt_mbit(speed_down_mbit)} Mbps | UP {fmt_mbit(speed_up_mbit)} Mbps)")
else:
  lines.append("  Speed Limit : OFF")
lines.append("")
lines.append("=== RUNNING ON PORT & PATH ===")
lines.append(section_line(f"{proto_disp} WS", "443 & 80", running_label_width))
lines.append(section_line(f"{proto_disp} HUP", "443 & 80", running_label_width))
lines.append(section_line(f"{proto_disp} gRPC", "443", running_label_width))
if proto in TCP_TLS_PROTOCOLS:
  lines.append(section_line(f"{proto_disp} TCP+TLS Port", "443", running_label_width))
lines.append(section_line(f"{proto_disp} Path WS", ws_path, running_label_width))
lines.append(section_line(f"{proto_disp} Path WS Alt", ws_path_alt, running_label_width))
lines.append(section_line(f"{proto_disp} Path HUP", hup_path, running_label_width))
lines.append(section_line(f"{proto_disp} Path HUP Alt", hup_path_alt, running_label_width))
lines.append(section_line(f"{proto_disp} Path Service", grpc_service, running_label_width))
lines.append(section_line(f"{proto_disp} Path Service Alt", grpc_service_alt, running_label_width))
lines.append("")
lines.append("=== LINKS IMPORT ===")
if "tcp" in links:
  append_link_block(lines, "TCP+TLS", links.get('tcp','-'))
  lines.append("")
append_link_block(lines, "WebSocket", links.get('ws','-'))
lines.append("")
append_link_block(lines, "HTTPUpgrade", links.get('httpupgrade','-'))
lines.append("")
append_link_block(lines, "gRPC", links.get('grpc','-'))
lines.append("")

write_text_atomic(acc_file, "\n".join(lines))

# Write quota json metadata
meta={
  "username": username + "@" + proto,
  "protocol": proto,
  "quota_limit": quota_bytes,
  "quota_unit": "binary",
  "quota_used": 0,
  "xray_usage_bytes": 0,
  "xray_api_baseline_bytes": 0,
  "xray_usage_carry_bytes": 0,
  "xray_api_last_total_bytes": 0,
  "xray_usage_reset_pending": False,
  "created_at": created_at,
  "expired_at": expired_at,
  "status": {
    "manual_block": False,
    "quota_exhausted": False,
    "ip_limit_enabled": ip_enabled,
    "ip_limit": ip_limit_int if ip_enabled else 0,
    "speed_limit_enabled": speed_enabled,
    "speed_down_mbit": speed_down_mbit if speed_enabled else 0,
    "speed_up_mbit": speed_up_mbit if speed_enabled else 0,
    "ip_limit_locked": False,
    "lock_reason": "",
    "locked_at": ""
  }
}
write_json_atomic(quota_file, meta)
PY
  local py_rc=$?
  if (( py_rc != 0 )); then
    return "${py_rc}"
  fi

  chmod 600 "${acc_file}" "${quota_file}" || true
  return 0
}

account_info_refresh_for_user() {
  # args: protocol username [domain] [ip] [credential_override] [output_file_override]
  local proto="$1"
  local username="$2"
  local domain="${3:-}"
  local ip="${4:-}"
  local cred_override="${5:-}"
  local output_file_override="${6:-}"

  ensure_account_quota_dirs
  need_python3

  local acc_file quota_file acc_compatfmt quota_compatfmt
  acc_file="${ACCOUNT_ROOT}/${proto}/${username}@${proto}.txt"
  quota_file="${QUOTA_ROOT}/${proto}/${username}@${proto}.json"
  acc_compatfmt="${ACCOUNT_ROOT}/${proto}/${username}.txt"
  quota_compatfmt="${QUOTA_ROOT}/${proto}/${username}.json"

  if [[ ! -f "${acc_file}" && -f "${acc_compatfmt}" ]]; then
    acc_file="${acc_compatfmt}"
  fi
  if [[ ! -f "${quota_file}" && -f "${quota_compatfmt}" ]]; then
    quota_file="${quota_compatfmt}"
  fi

  [[ -n "${domain}" ]] || domain="$(detect_domain)"
  if [[ -z "${ip}" ]]; then
    if [[ -f "${acc_file}" ]]; then
      ip="$(grep -E '^[[:space:]]*IP[[:space:]]*:' "${acc_file}" | head -n1 | sed -E 's/^[[:space:]]*IP[[:space:]]*:[[:space:]]*//' || true)"
    fi
    [[ -n "${ip}" ]] || ip="$(detect_public_ip)"
  fi

  local rc=0 geo geo_ip isp country
  geo="$(main_info_geo_lookup "${ip}")"
  IFS='|' read -r geo_ip isp country <<<"${geo}"
  [[ -n "${geo_ip}" && "${geo_ip}" != "-" ]] && ip="${geo_ip}"
  [[ -n "${isp}" ]] || isp="-"
  [[ -n "${country}" ]] || country="-"
  set +e
  python3 - <<'PY' "${acc_file}" "${quota_file}" "${XRAY_INBOUNDS_CONF}" "${domain}" "${ip}" "${isp}" "${country}" "${username}" "${proto}" "${cred_override}" "${output_file_override}"
import base64
import ipaddress
import json
import os
import re
import sys
import tempfile
import urllib.parse
from datetime import date, datetime

acc_file, quota_file, inbounds_file, domain_arg, ip_arg, isp_arg, country_arg, username, proto, cred_override, output_override = sys.argv[1:12]
email = f"{username}@{proto}"
forced_cred = str(cred_override or "").strip()
out_file = str(output_override or "").strip() or acc_file


def to_int(v, default=0):
  try:
    if v is None:
      return default
    if isinstance(v, bool):
      return int(v)
    if isinstance(v, (int, float)):
      return int(v)
    s = str(v).strip()
    if not s:
      return default
    return int(float(s))
  except Exception:
    return default


def to_float(v, default=0.0):
  try:
    if v is None:
      return default
    if isinstance(v, bool):
      return float(int(v))
    if isinstance(v, (int, float)):
      return float(v)
    s = str(v).strip()
    if not s:
      return default
    return float(s)
  except Exception:
    return default


def fmt_gb(v):
  try:
    n = float(v)
  except Exception:
    return "0"
  if n <= 0:
    return "0"
  if abs(n - round(n)) < 1e-9:
    return str(int(round(n)))
  return f"{n:.2f}".rstrip("0").rstrip(".")


def fmt_mbit(v):
  try:
    n = float(v)
  except Exception:
    return "0"
  if n <= 0:
    return "0"
  if abs(n - round(n)) < 1e-9:
    return str(int(round(n)))
  return f"{n:.2f}".rstrip("0").rstrip(".")


PROTO_LABELS = {
  "vless": "Vless",
  "vmess": "Vmess",
  "trojan": "Trojan",
}


def path_alt_placeholder(path):
  raw = str(path or "").strip()
  if not raw:
    return "-"
  if not raw.startswith("/"):
    raw = "/" + raw
  return f"/<bebas>{raw}"


def service_alt_placeholder(service):
  raw = str(service or "").strip()
  if not raw or raw == "-":
    return "-"
  return f"<bebas>/{raw.lstrip('/')}"


def section_line(label, value, width):
  return f"  {label:<{width}} : {value}"


def append_link_block(lines, label, value):
  lines.append(f"    {label:<12} :")
  lines.append(str(value or "-"))


def is_public_ipv4(raw):
  try:
    addr = ipaddress.ip_address(str(raw).strip())
  except Exception:
    return False
  return (
    addr.version == 4
    and not addr.is_private
    and not addr.is_loopback
    and not addr.is_link_local
    and not addr.is_multicast
    and not addr.is_unspecified
    and not addr.is_reserved
  )


def parse_date_only(raw):
  s = str(raw or "").strip()
  if not s:
    return None
  s = s[:10]
  try:
    return datetime.strptime(s, "%Y-%m-%d").date()
  except Exception:
    return None


def read_account_fields(path):
  fields = {}
  if not os.path.isfile(path):
    return fields
  try:
    with open(path, "r", encoding="utf-8", errors="replace") as f:
      for raw in f:
        line = raw.strip()
        if ":" not in line:
          continue
        k, v = line.split(":", 1)
        fields[k.strip()] = v.strip()
  except Exception:
    return {}
  return fields


def parse_quota_bytes_from_text(s):
  m = re.search(r"([0-9]+(?:\.[0-9]+)?)", str(s or ""))
  if not m:
    return 0
  try:
    gb = float(m.group(1))
  except Exception:
    return 0
  if gb <= 0:
    return 0
  return int(round(gb * (1024 ** 3)))


def parse_days_from_text(s):
  m = re.search(r"([0-9]+)", str(s or ""))
  if not m:
    return None
  try:
    n = int(m.group(1))
  except Exception:
    return None
  if n < 0:
    return 0
  return n


def parse_ip_line(s):
  text = str(s or "").strip().upper()
  if not text.startswith("ON"):
    return False, 0
  m = re.search(r"\(([0-9]+)\)", text)
  if not m:
    return True, 0
  return True, to_int(m.group(1), 0)


def parse_speed_line(s):
  text = str(s or "").strip()
  if not text.upper().startswith("ON"):
    return False, 0.0, 0.0
  m = re.search(
    r"DOWN\s*([0-9]+(?:\.[0-9]+)?)\s*Mbps\s*\|\s*UP\s*([0-9]+(?:\.[0-9]+)?)\s*Mbps",
    text,
    flags=re.IGNORECASE,
  )
  if not m:
    return False, 0.0, 0.0
  return True, to_float(m.group(1), 0.0), to_float(m.group(2), 0.0)


existing = read_account_fields(acc_file)

domain = str(domain_arg or "").strip() or str(existing.get("Domain") or "").strip() or "-"
ip = str(ip_arg or "").strip() or str(existing.get("IP") or "").strip() or "0.0.0.0"
isp = str(isp_arg or "").strip() or str(existing.get("ISP") or "").strip() or "-"
country = str(country_arg or "").strip() or str(existing.get("Country") or "").strip() or "-"

meta = {}
if os.path.isfile(quota_file):
  try:
    loaded = json.load(open(quota_file, "r", encoding="utf-8"))
    if isinstance(loaded, dict):
      meta = loaded
  except Exception:
    meta = {}

status = meta.get("status")
if not isinstance(status, dict):
  status = {}

quota_bytes = to_int(meta.get("quota_limit"), -1)
if quota_bytes < 0:
  quota_bytes = parse_quota_bytes_from_text(existing.get("Quota Limit", ""))
if quota_bytes < 0:
  quota_bytes = 0
quota_gb_disp = fmt_gb(quota_bytes / (1024 ** 3)) if quota_bytes else "0"

created_at = str(meta.get("created_at") or existing.get("Created") or "").strip()
if created_at:
  s = created_at.replace("T", " ").strip()
  if s.endswith("Z"):
    s = s[:-1]
  try:
    dt = datetime.fromisoformat(s)
    if dt.hour == 0 and dt.minute == 0 and dt.second == 0 and len(s) <= 10:
      created_at = dt.strftime("%Y-%m-%d")
    else:
      created_at = dt.strftime("%Y-%m-%d %H:%M")
  except Exception:
    if len(s) >= 16 and s[4:5] == "-" and s[7:8] == "-" and s[13:14] == ":":
      created_at = s[:16]
    elif len(s) >= 10 and s[4:5] == "-" and s[7:8] == "-":
      created_at = s[:10]
    else:
      created_at = datetime.now().strftime("%Y-%m-%d %H:%M")
else:
  created_at = datetime.now().strftime("%Y-%m-%d %H:%M")
expired_at = str(meta.get("expired_at") or existing.get("Valid Until") or "").strip()
expired_at = expired_at[:10] if expired_at else "-"

d_expired = parse_date_only(expired_at)
if d_expired:
  days = max(0, (d_expired - date.today()).days)
else:
  days = parse_days_from_text(existing.get("Expired", ""))
  if days is None:
    d_created = parse_date_only(created_at)
    if d_created and d_expired:
      days = max(0, (d_expired - d_created).days)
    else:
      days = 0

if "ip_limit_enabled" in status:
  ip_enabled = bool(status.get("ip_limit_enabled"))
  ip_limit_int = to_int(status.get("ip_limit"), 0)
else:
  ip_enabled, ip_limit_int = parse_ip_line(existing.get("IP Limit", ""))
if ip_limit_int < 0:
  ip_limit_int = 0

if "speed_limit_enabled" in status or "speed_down_mbit" in status or "speed_up_mbit" in status:
  speed_enabled = bool(status.get("speed_limit_enabled"))
  speed_down_mbit = to_float(status.get("speed_down_mbit"), 0.0)
  speed_up_mbit = to_float(status.get("speed_up_mbit"), 0.0)
else:
  speed_enabled, speed_down_mbit, speed_up_mbit = parse_speed_line(existing.get("Speed Limit", ""))

if not speed_enabled or speed_down_mbit <= 0 or speed_up_mbit <= 0:
  speed_enabled = False
  speed_down_mbit = 0.0
  speed_up_mbit = 0.0

cred = forced_cred
if not cred and os.path.isfile(inbounds_file):
  try:
    cfg = json.load(open(inbounds_file, "r", encoding="utf-8"))
    def inbound_matches_proto(ib, p):
      if not isinstance(ib, dict):
        return False
      ib_proto = str(ib.get("protocol") or "").strip().lower()
      if p in ("vless", "vmess", "trojan"):
        return ib_proto == p
      return False

    for ib in cfg.get("inbounds") or []:
      if not isinstance(ib, dict):
        continue
      if not inbound_matches_proto(ib, proto):
        continue
      clients = (ib.get("settings") or {}).get("clients") or []
      if not isinstance(clients, list):
        continue
      for c in clients:
        if not isinstance(c, dict):
          continue
        if str(c.get("email") or "") != email:
          continue
        if proto == "trojan":
          v = c.get("password")
        else:
          v = c.get("id")
        cred = str(v or "").strip()
        if cred:
          break
      if cred:
        break
  except Exception:
    cred = ""

if not cred:
  if proto == "trojan":
    cred = str(existing.get("Password") or "").strip()
  else:
    cred = str(existing.get("UUID") or "").strip()
if not cred:
  raise SystemExit(20)

PUBLIC_PATHS = {
  "vless": {"ws": "/vless-ws", "httpupgrade": "/vless-hup", "grpc": "vless-grpc"},
  "vmess": {"ws": "/vmess-ws", "httpupgrade": "/vmess-hup", "grpc": "vmess-grpc"},
  "trojan": {"ws": "/trojan-ws", "httpupgrade": "/trojan-hup", "grpc": "trojan-grpc"},
}
TCP_TLS_PROTOCOLS = {"vless", "trojan"}


def vless_link(net, val):
  q = {"encryption": "none", "security": "tls", "type": net, "sni": domain}
  if net in ("ws", "httpupgrade"):
    q["path"] = val or "/"
  elif net == "grpc" and val:
    q["serviceName"] = val
  return f"vless://{cred}@{domain}:443?{urllib.parse.urlencode(q)}#{urllib.parse.quote(username + '@' + proto)}"


def trojan_link(net, val):
  q = {"security": "tls", "type": net, "sni": domain}
  if net in ("ws", "httpupgrade"):
    q["path"] = val or "/"
  elif net == "grpc" and val:
    q["serviceName"] = val
  return f"trojan://{cred}@{domain}:443?{urllib.parse.urlencode(q)}#{urllib.parse.quote(username + '@' + proto)}"


def vmess_link(net, val):
  obj = {
    "v": "2",
    "ps": username + "@" + proto,
    "add": domain,
    "port": "443",
    "id": cred,
    "aid": "0",
    "net": net,
    "type": "none",
    "host": domain,
    "tls": "tls",
    "sni": domain,
  }
  if net in ("ws", "httpupgrade"):
    obj["path"] = val or "/"
  elif net == "grpc":
    obj["path"] = val or ""
    obj["type"] = "gun"
  raw = json.dumps(obj, separators=(",", ":"))
  return "vmess://" + base64.b64encode(raw.encode()).decode()

links = {}
public_proto = PUBLIC_PATHS.get(proto, {})
proto_disp = PROTO_LABELS.get(proto, proto.title() or "Xray")
ws_path = public_proto.get("ws", "") or "/"
ws_path_alt = path_alt_placeholder(ws_path)
hup_path = public_proto.get("httpupgrade", "") or "/"
hup_path_alt = path_alt_placeholder(hup_path)
grpc_service = public_proto.get("grpc", "") or "-"
grpc_service_alt = service_alt_placeholder(grpc_service)
created_disp = created_at[:10] if len(created_at) >= 10 and created_at[4:5] == "-" and created_at[7:8] == "-" else created_at
running_labels = [
  f"{proto_disp} WS",
  f"{proto_disp} HUP",
  f"{proto_disp} gRPC",
  f"{proto_disp} Path WS",
  f"{proto_disp} Path WS Alt",
  f"{proto_disp} Path HUP",
  f"{proto_disp} Path HUP Alt",
  f"{proto_disp} Path Service",
  f"{proto_disp} Path Service Alt",
]
if proto in TCP_TLS_PROTOCOLS:
  running_labels.append(f"{proto_disp} TCP+TLS Port")
running_label_width = max(len(label) for label in running_labels)
nets = ["ws", "httpupgrade", "grpc"]
if proto in TCP_TLS_PROTOCOLS:
  nets = ["tcp"] + nets
for net in nets:
  val = public_proto.get(net, "")
  if proto == "vless":
    links[net] = vless_link(net, val)
  elif proto == "vmess":
    links[net] = vmess_link(net, val)
  elif proto == "trojan":
    links[net] = trojan_link(net, val)

lines = []
lines.append("=== XRAY ACCOUNT INFO ===")
lines.append(f"  Domain      : {domain}")
lines.append(f"  IP          : {ip}")
lines.append(f"  ISP         : {isp}")
lines.append(f"  Country     : {country}")
lines.append(f"  Username    : {username}")
lines.append(f"  Protocol    : {proto}")
if proto in ("vless", "vmess"):
  lines.append(f"  UUID        : {cred}")
else:
  lines.append(f"  Password    : {cred}")
lines.append(f"  Quota Limit : {quota_gb_disp} GB")
lines.append(f"  Expired     : {days} days")
lines.append(f"  Valid Until : {expired_at}")
lines.append(f"  Created     : {created_disp}")
lines.append(f"  IP Limit    : {'ON' if ip_enabled else 'OFF'}" + (f" ({ip_limit_int})" if ip_enabled and ip_limit_int > 0 else ""))
if speed_enabled:
  lines.append(f"  Speed Limit : ON (DOWN {fmt_mbit(speed_down_mbit)} Mbps | UP {fmt_mbit(speed_up_mbit)} Mbps)")
else:
  lines.append("  Speed Limit : OFF")
lines.append("")
lines.append("=== RUNNING ON PORT & PATH ===")
lines.append(section_line(f"{proto_disp} WS", "443 & 80", running_label_width))
lines.append(section_line(f"{proto_disp} HUP", "443 & 80", running_label_width))
lines.append(section_line(f"{proto_disp} gRPC", "443", running_label_width))
if proto in TCP_TLS_PROTOCOLS:
  lines.append(section_line(f"{proto_disp} TCP+TLS Port", "443", running_label_width))
lines.append(section_line(f"{proto_disp} Path WS", ws_path, running_label_width))
lines.append(section_line(f"{proto_disp} Path WS Alt", ws_path_alt, running_label_width))
lines.append(section_line(f"{proto_disp} Path HUP", hup_path, running_label_width))
lines.append(section_line(f"{proto_disp} Path HUP Alt", hup_path_alt, running_label_width))
lines.append(section_line(f"{proto_disp} Path Service", grpc_service, running_label_width))
lines.append(section_line(f"{proto_disp} Path Service Alt", grpc_service_alt, running_label_width))
lines.append("")
lines.append("=== LINKS IMPORT ===")
if "tcp" in links:
  append_link_block(lines, "TCP+TLS", links.get('tcp', '-'))
  lines.append("")
append_link_block(lines, "WebSocket", links.get('ws', '-'))
lines.append("")
append_link_block(lines, "HTTPUpgrade", links.get('httpupgrade', '-'))
lines.append("")
append_link_block(lines, "gRPC", links.get('grpc', '-'))
lines.append("")

os.makedirs(os.path.dirname(out_file) or ".", exist_ok=True)
fd, tmp = tempfile.mkstemp(prefix=".tmp.", suffix=".txt", dir=os.path.dirname(out_file) or ".")
try:
  with os.fdopen(fd, "w", encoding="utf-8") as f:
    f.write("\n".join(lines))
    f.flush()
    os.fsync(f.fileno())
  os.replace(tmp, out_file)
finally:
  try:
    if os.path.exists(tmp):
      os.remove(tmp)
  except Exception:
    pass
PY
  rc=$?
  set -e

  if (( rc == 20 )); then
    warn "Credential ${username}@${proto} tidak ditemukan, skip refresh account info."
    return 1
  fi
  if (( rc != 0 )); then
    warn "Gagal refresh XRAY ACCOUNT INFO untuk ${username}@${proto}"
    return 1
  fi

  chmod 600 "${output_file_override:-${acc_file}}" 2>/dev/null || true
  return 0
}

account_info_refresh_warn() {
  # args: protocol username
  local proto="$1"
  local username="$2"
  if ! account_info_refresh_for_user "${proto}" "${username}"; then
    warn "XRAY ACCOUNT INFO belum sinkron untuk ${username}@${proto}"
    return 1
  fi
  return 0
}

account_info_refresh_target_file_for_user() {
  local proto="$1"
  local username="$2"
  local acc_file acc_compatfmt
  acc_file="${ACCOUNT_ROOT}/${proto}/${username}@${proto}.txt"
  acc_compatfmt="${ACCOUNT_ROOT}/${proto}/${username}.txt"
  if [[ ! -f "${acc_file}" && -f "${acc_compatfmt}" ]]; then
    acc_file="${acc_compatfmt}"
  fi
  printf '%s\n' "${acc_file}"
}

account_info_refresh_snapshot_file() {
  local path="$1"
  local snap_dir="$2"
  local manifest_file="$3"
  local backup_file=""
  if [[ -e "${path}" || -L "${path}" ]]; then
    backup_file="$(mktemp "${snap_dir}/snapshot.XXXXXX" 2>/dev/null || true)"
    [[ -n "${backup_file}" ]] || return 1
    if ! cp -a "${path}" "${backup_file}" 2>/dev/null; then
      rm -f "${backup_file}" >/dev/null 2>&1 || true
      return 1
    fi
    printf 'file\t%s\t%s\n' "${path}" "${backup_file}" >> "${manifest_file}"
  else
    printf 'absent\t%s\t-\n' "${path}" >> "${manifest_file}"
  fi
}

account_info_refresh_restore_snapshot() {
  local manifest_file="$1"
  local failed=0 kind path backup_file
  while IFS=$'\t' read -r kind path backup_file; do
    case "${kind}" in
      file)
        mkdir -p "$(dirname "${path}")" 2>/dev/null || true
        if ! cp -a "${backup_file}" "${path}" 2>/dev/null; then
          warn "Rollback ACCOUNT INFO gagal restore: ${path}"
          failed=1
          continue
        fi
        chmod 600 "${path}" 2>/dev/null || true
        ;;
      absent)
        if [[ -e "${path}" || -L "${path}" ]]; then
          if ! rm -f "${path}" 2>/dev/null; then
            warn "Rollback ACCOUNT INFO gagal hapus file baru: ${path}"
            failed=1
          fi
        fi
        ;;
    esac
  done < "${manifest_file}"
  return "${failed}"
}

account_refresh_all_info_files() {
  # args: [domain] [ip] [scope]
  local domain="${1:-}"
  local ip="${2:-}"
  local scope="${3:-all}"
  local snap_dir="" manifest_file=""
  local i proto username target_file state_file
  local updated=0 failed=0 ssh_updated=0 ssh_failed=0
  local -a xray_refresh_protos=() xray_refresh_users=() xray_refresh_targets=()
  local -a ssh_refresh_users=() ssh_refresh_targets=()
  local -A seen_targets=() seen_xray_users=() seen_ssh_users=()
  local -a ssh_users=()

  if [[ "${USER_DATA_MUTATION_LOCK_HELD:-0}" != "1" ]]; then
    user_data_mutation_run_locked account_refresh_all_info_files "$@"
    return $?
  fi

  if [[ "${ACCOUNT_INFO_LOCK_HELD:-0}" != "1" ]]; then
    account_info_run_locked account_refresh_all_info_files "$@"
    return $?
  fi

  ensure_account_quota_dirs
  case "${scope}" in
    all|xray|ssh) ;;
    *) scope="all" ;;
  esac
  [[ -n "${domain}" ]] || domain="$(detect_domain)"
  [[ -n "${ip}" ]] || ip="$(detect_public_ip_ipapi)"

  if [[ "${scope}" == "all" || "${scope}" == "xray" ]]; then
    account_collect_files
    if (( ${#ACCOUNT_FILES[@]} > 0 )); then
      for i in "${!ACCOUNT_FILES[@]}"; do
        proto="${ACCOUNT_FILE_PROTOS[$i]}"
        username="$(account_parse_username_from_file "${ACCOUNT_FILES[$i]}" "${proto}")"
        [[ -n "${username}" ]] || continue
        if [[ -n "${seen_xray_users["${proto}|${username}"]+x}" ]]; then
          continue
        fi
        seen_xray_users["${proto}|${username}"]=1
        target_file="$(account_info_refresh_target_file_for_user "${proto}" "${username}")"
        xray_refresh_protos+=("${proto}")
        xray_refresh_users+=("${username}")
        xray_refresh_targets+=("${target_file}")
      done
    fi
  fi
  if [[ "${scope}" == "all" || "${scope}" == "ssh" ]]; then
    account_info_refresh_collect_ssh_users ssh_users
    for username in "${ssh_users[@]}"; do
      [[ -n "${username}" ]] || continue
      if [[ -n "${seen_ssh_users["${username}"]+x}" ]]; then
        continue
      fi
      seen_ssh_users["${username}"]=1
      ssh_refresh_users+=("${username}")
      ssh_refresh_targets+=("$(ssh_account_info_file "${username}")")
    done
  fi

  snap_dir="$(mktemp -d "${WORK_DIR}/.account-info-refresh.XXXXXX" 2>/dev/null || true)"
  [[ -n "${snap_dir}" ]] || snap_dir="${WORK_DIR}/.account-info-refresh.$$"
  mkdir -p "${snap_dir}" 2>/dev/null || return 1
  manifest_file="${snap_dir}/manifest.tsv"
  : > "${manifest_file}" || {
    rm -rf "${snap_dir}" >/dev/null 2>&1 || true
    return 1
  }

  for target_file in "${xray_refresh_targets[@]}" "${ssh_refresh_targets[@]}"; do
    [[ -n "${target_file}" ]] || continue
    if [[ -n "${seen_targets["${target_file}"]+x}" ]]; then
      continue
    fi
    seen_targets["${target_file}"]=1
    if ! account_info_refresh_snapshot_file "${target_file}" "${snap_dir}" "${manifest_file}"; then
      warn "Gagal membuat snapshot sebelum refresh ACCOUNT INFO: ${target_file}"
      if ! account_info_refresh_restore_snapshot "${manifest_file}"; then
        warn "Rollback snapshot ACCOUNT INFO juga gagal."
      fi
      rm -rf "${snap_dir}" >/dev/null 2>&1 || true
      return 1
    fi
  done

  for i in "${!xray_refresh_users[@]}"; do
    if account_info_refresh_for_user "${xray_refresh_protos[$i]}" "${xray_refresh_users[$i]}" "${domain}" "${ip}"; then
      updated=$((updated + 1))
    else
      failed=$((failed + 1))
    fi
  done
  for i in "${!ssh_refresh_users[@]}"; do
    state_file="$(ssh_user_state_resolve_file "${ssh_refresh_users[$i]}")"
    if [[ ! -f "${state_file}" ]] && ! ssh_qac_metadata_bootstrap_if_missing "${ssh_refresh_users[$i]}" "${state_file}"; then
      ssh_failed=$((ssh_failed + 1))
      continue
    fi
    if ssh_account_info_refresh_from_state "${ssh_refresh_users[$i]}"; then
      ssh_updated=$((ssh_updated + 1))
    else
      ssh_failed=$((ssh_failed + 1))
    fi
  done

  log "Refresh ACCOUNT INFO (scope=${scope}): xray_updated=${updated}, xray_failed=${failed}, ssh_updated=${ssh_updated}, ssh_failed=${ssh_failed}"
  if (( failed > 0 || ssh_failed > 0 )); then
    warn "Refresh ACCOUNT INFO gagal parsial. Mengembalikan snapshot sebelumnya..."
    if ! account_info_refresh_restore_snapshot "${manifest_file}"; then
      warn "Rollback ACCOUNT INFO belum pulih sepenuhnya. Cek file di ${ACCOUNT_ROOT} dan ${SSH_ACCOUNT_DIR}."
    fi
    rm -rf "${snap_dir}" >/dev/null 2>&1 || true
    return 1
  fi
  rm -rf "${snap_dir}" >/dev/null 2>&1 || true
  return 0
}


delete_one_file() {
  local f="$1"
  [[ -n "${f}" ]] || return 0
  if [[ -f "${f}" ]]; then
    if have_cmd lsattr && lsattr -d "${f}" 2>/dev/null | awk '{print $1}' | grep -q 'i'; then
      warn "File immutable, lepas dulu: chattr -i '${f}'"
    fi
    chmod u+w "${f}" 2>/dev/null || true
    if rm -f "${f}" 2>/dev/null; then
      log "Hapus: ${f}"
    else
      warn "Gagal hapus: ${f} (permission denied/immutable)"
    fi
  fi
}

delete_account_artifacts() {
  # args: protocol username
  local proto="$1"
  local username="$2"

  local acc_file acc_file_compatfmt quota_file quota_file_compatfmt
  acc_file="${ACCOUNT_ROOT}/${proto}/${username}@${proto}.txt"
  acc_file_compatfmt="${ACCOUNT_ROOT}/${proto}/${username}.txt"
  quota_file="${QUOTA_ROOT}/${proto}/${username}@${proto}.json"
  quota_file_compatfmt="${QUOTA_ROOT}/${proto}/${username}.json"

  delete_one_file "${acc_file}"
  delete_one_file "${acc_file_compatfmt}"
  delete_one_file "${quota_file}"
  delete_one_file "${quota_file}.lock"
  delete_one_file "${quota_file_compatfmt}"
  delete_one_file "${quota_file_compatfmt}.lock"
  speed_policy_remove_checked "${proto}" "${username}" >/dev/null 2>&1 || true
}

delete_account_artifacts_checked() {
  # args: protocol username
  local proto="$1"
  local username="$2"
  local failed=0
  local p=""
  for p in \
    "${ACCOUNT_ROOT}/${proto}/${username}@${proto}.txt" \
    "${ACCOUNT_ROOT}/${proto}/${username}.txt" \
    "${QUOTA_ROOT}/${proto}/${username}@${proto}.json" \
    "${QUOTA_ROOT}/${proto}/${username}@${proto}.json.lock" \
    "${QUOTA_ROOT}/${proto}/${username}.json" \
    "${QUOTA_ROOT}/${proto}/${username}.json.lock"; do
    if [[ ! -e "${p}" && ! -L "${p}" ]]; then
      continue
    fi
    chmod u+w "${p}" 2>/dev/null || true
    if ! rm -f "${p}" 2>/dev/null; then
      warn "Gagal hapus artefak: ${p}"
      failed=1
      continue
    fi
    if [[ -e "${p}" || -L "${p}" ]]; then
      warn "Artefak masih ada setelah unlink: ${p}"
      failed=1
    fi
  done
  if ! speed_policy_remove_checked "${proto}" "${username}"; then
    warn "Gagal hapus speed policy: ${username}@${proto}"
    failed=1
  fi
  return "${failed}"
}

speed_policy_sync_xray_try() {
  ( speed_policy_sync_xray ) >/dev/null 2>&1
}

xray_add_client_try() {
  ( xray_add_client "$@" ) >/dev/null 2>&1
}

xray_delete_client_try() {
  ( xray_delete_client "$@" ) >/dev/null 2>&1
}

xray_reset_client_credential_try() {
  ( xray_reset_client_credential "$@" ) >/dev/null 2>&1
}

xray_user_current_credential_get() {
  local proto="$1"
  local username="$2"
  need_python3
  python3 - <<'PY' "${XRAY_INBOUNDS_CONF}" "${proto}" "${username}"
import json
import sys

src, proto, username = sys.argv[1:4]
email = f"{username}@{proto}"
try:
    cfg = json.load(open(src, "r", encoding="utf-8"))
except Exception:
    raise SystemExit(0)

for ib in cfg.get("inbounds") or []:
    if not isinstance(ib, dict):
        continue
    if str(ib.get("protocol") or "").strip().lower() != proto:
        continue
    clients = ((ib.get("settings") or {}).get("clients") or [])
    if not isinstance(clients, list):
        continue
    for client in clients:
        if not isinstance(client, dict):
            continue
        if str(client.get("email") or "").strip() != email:
            continue
        value = client.get("password") if proto == "trojan" else client.get("id")
        value = str(value or "").strip()
        if value:
            print(value)
            raise SystemExit(0)
raise SystemExit(0)
PY
}

quota_sync_speed_policy_for_user_try() {
  ( quota_sync_speed_policy_for_user "$@" )
}

xray_user_expiry_rollback() {
  # args: quota_file quota_backup proto username email_for_routing current_expiry was_present_in_inbounds readded_now
  local qf="$1"
  local backup="$2"
  local proto="$3"
  local username="$4"
  local email_for_routing="$5"
  local current_expiry="$6"
  local was_present_in_inbounds="${7:-false}"
  local readded_now="${8:-false}"
  local -a notes=()

  if ! quota_restore_file_locked "${backup}" "${qf}" >/dev/null 2>&1; then
    echo "Expiry rollback ke ${current_expiry} gagal: restore quota gagal"
    return 1
  fi

  if [[ "${was_present_in_inbounds}" == "true" ]]; then
    local rollback_apply_msg=""
    if ! rollback_apply_msg="$(xray_qac_apply_runtime_from_quota "${qf}" "${proto}" "${username}" "${email_for_routing}" true true)"; then
      notes+=("${rollback_apply_msg}")
    fi
  else
    if [[ "${readded_now}" == "true" ]]; then
      if ! xray_delete_client_try "${proto}" "${username}"; then
        notes+=("hapus restore sementara gagal")
      fi
    fi
    xray_routing_set_user_in_marker "dummy-quota-user" "${email_for_routing}" off >/dev/null 2>&1 || notes+=("restore routing quota expired gagal")
    xray_routing_set_user_in_marker "dummy-block-user" "${email_for_routing}" off >/dev/null 2>&1 || notes+=("restore routing manual block expired gagal")
    xray_routing_set_user_in_marker "dummy-limit-user" "${email_for_routing}" off >/dev/null 2>&1 || notes+=("restore routing ip-limit expired gagal")
    if ! account_info_refresh_warn "${proto}" "${username}" >/dev/null 2>&1; then
      notes+=("refresh XRAY ACCOUNT INFO rollback gagal")
    fi
  fi

  if (( ${#notes[@]} > 0 )); then
    echo "Expiry dirollback ke ${current_expiry}, tetapi rollback belum bersih: $(IFS=' | '; echo "${notes[*]}")"
    return 1
  fi
  echo "Expiry dirollback ke ${current_expiry}."
  return 0
}

xray_qac_apply_runtime_from_quota() {
  # args: quota_file proto username email_for_routing restart_limit_ip sync_speed
  local qf="$1"
  local proto="$2"
  local username="$3"
  local email_for_routing="$4"
  local restart_limit_ip="${5:-false}"
  local sync_speed="${6:-false}"
  local st_quota st_manual st_iplocked

  st_quota="$(quota_get_status_bool "${qf}" "quota_exhausted" 2>/dev/null || echo "false")"
  st_manual="$(quota_get_status_bool "${qf}" "manual_block" 2>/dev/null || echo "false")"
  st_iplocked="$(quota_get_status_bool "${qf}" "ip_limit_locked" 2>/dev/null || echo "false")"

  if ! xray_routing_set_user_in_marker "dummy-quota-user" "${email_for_routing}" "$( [[ "${st_quota}" == "true" ]] && echo on || echo off )" >/dev/null 2>&1; then
    echo "routing quota marker gagal"
    return 1
  fi
  if ! xray_routing_set_user_in_marker "dummy-block-user" "${email_for_routing}" "$( [[ "${st_manual}" == "true" ]] && echo on || echo off )" >/dev/null 2>&1; then
    echo "routing manual-block marker gagal"
    return 1
  fi
  if ! xray_routing_set_user_in_marker "dummy-limit-user" "${email_for_routing}" "$( [[ "${st_iplocked}" == "true" ]] && echo on || echo off )" >/dev/null 2>&1; then
    echo "routing ip-limit marker gagal"
    return 1
  fi

  if [[ "${restart_limit_ip}" == "true" ]]; then
    if ! svc_restart_any xray-limit-ip xray-limit >/dev/null 2>&1; then
      echo "restart service limit-ip gagal"
      return 1
    fi
  fi

  if [[ "${sync_speed}" == "true" ]]; then
    if ! quota_sync_speed_policy_for_user_try "${proto}" "${username}" "${qf}"; then
      echo "sinkronisasi speed policy gagal"
      return 1
    fi
  fi

  if ! account_info_refresh_warn "${proto}" "${username}"; then
    echo "XRAY ACCOUNT INFO belum sinkron"
    return 1
  fi

  return 0
}

xray_qac_atomic_apply() {
  # args: quota_file proto username email_for_routing restart_limit_ip sync_speed action [action_args...]
  local qf="$1"
  local proto="$2"
  local username="$3"
  local email_for_routing="$4"
  local restart_limit_ip="${5:-false}"
  local sync_speed="${6:-false}"
  local action="$7"
  shift 7 || true

  if [[ "${USER_DATA_MUTATION_LOCK_HELD:-0}" != "1" ]]; then
    user_data_mutation_run_locked xray_qac_atomic_apply "${qf}" "${proto}" "${username}" "${email_for_routing}" "${restart_limit_ip}" "${sync_speed}" "${action}" "$@"
    return $?
  fi

  local backup_file
  backup_file="$(mktemp "${WORK_DIR}/.quota-qac.${username}.${proto}.XXXXXX" 2>/dev/null || true)"
  if [[ -z "${backup_file}" ]]; then
    echo "gagal membuat backup quota"
    return 1
  fi
  if ! QUOTA_ATOMIC_BACKUP_FILE="${backup_file}" quota_atomic_update_file "${qf}" "${action}" "$@"; then
    rm -f -- "${backup_file}" >/dev/null 2>&1 || true
    echo "gagal update metadata quota"
    return 1
  fi

  local apply_msg=""
  if ! apply_msg="$(xray_qac_apply_runtime_from_quota "${qf}" "${proto}" "${username}" "${email_for_routing}" "${restart_limit_ip}" "${sync_speed}")"; then
    local -a rollback_notes=()
    if ! quota_restore_file_locked "${backup_file}" "${qf}" >/dev/null 2>&1; then
      rollback_notes+=("rollback quota gagal")
    else
      local rollback_apply_msg=""
      if ! rollback_apply_msg="$(xray_qac_apply_runtime_from_quota "${qf}" "${proto}" "${username}" "${email_for_routing}" "${restart_limit_ip}" "${sync_speed}")"; then
        rollback_notes+=("rollback runtime gagal: ${rollback_apply_msg}")
      fi
    fi
    rm -f -- "${backup_file}" >/dev/null 2>&1 || true
    if (( ${#rollback_notes[@]} > 0 )); then
      echo "${apply_msg}. Rollback: ${rollback_notes[*]}"
    else
      echo "${apply_msg}. State di-rollback."
    fi
    return 1
  fi

  rm -f -- "${backup_file}" >/dev/null 2>&1 || true
  return 0
}

xray_qac_unlock_ip_atomic_apply() {
  # args: quota_file proto username email_for_routing
  local qf="$1"
  local proto="$2"
  local username="$3"
  local email_for_routing="$4"
  local backup_file=""

  if [[ "${USER_DATA_MUTATION_LOCK_HELD:-0}" != "1" ]]; then
    user_data_mutation_run_locked xray_qac_unlock_ip_atomic_apply "${qf}" "${proto}" "${username}" "${email_for_routing}"
    return $?
  fi

  backup_file="$(mktemp "${WORK_DIR}/.quota-unlock-ip.${username}.${proto}.XXXXXX" 2>/dev/null || true)"
  if [[ -z "${backup_file}" ]]; then
    echo "gagal membuat backup quota"
    return 1
  fi
  if ! QUOTA_ATOMIC_BACKUP_FILE="${backup_file}" quota_atomic_update_file "${qf}" clear_ip_limit_locked_recompute; then
    rm -f -- "${backup_file}" >/dev/null 2>&1 || true
    echo "gagal update metadata quota"
    return 1
  fi

  local apply_msg=""
  if ! apply_msg="$(xray_qac_apply_runtime_from_quota "${qf}" "${proto}" "${username}" "${email_for_routing}" true false)"; then
    local -a rollback_notes=()
    if ! quota_restore_file_locked "${backup_file}" "${qf}" >/dev/null 2>&1; then
      rollback_notes+=("rollback quota gagal")
    else
      local rollback_apply_msg=""
      if ! rollback_apply_msg="$(xray_qac_apply_runtime_from_quota "${qf}" "${proto}" "${username}" "${email_for_routing}" true false)"; then
        rollback_notes+=("rollback runtime gagal: ${rollback_apply_msg}")
      fi
    fi
    rm -f -- "${backup_file}" >/dev/null 2>&1 || true
    if (( ${#rollback_notes[@]} > 0 )); then
      echo "${apply_msg}. Rollback: ${rollback_notes[*]}"
    else
      echo "${apply_msg}. State di-rollback."
    fi
    return 1
  fi

  if [[ -x /usr/local/bin/limit-ip ]]; then
    if ! /usr/local/bin/limit-ip unlock "${email_for_routing}" >/dev/null 2>&1; then
      local -a rollback_notes=()
      if ! quota_restore_file_locked "${backup_file}" "${qf}" >/dev/null 2>&1; then
        rollback_notes+=("rollback quota gagal")
      else
        local rollback_apply_msg=""
        if ! rollback_apply_msg="$(xray_qac_apply_runtime_from_quota "${qf}" "${proto}" "${username}" "${email_for_routing}" true false)"; then
          rollback_notes+=("rollback runtime gagal: ${rollback_apply_msg}")
        fi
      fi
      rm -f -- "${backup_file}" >/dev/null 2>&1 || true
      if (( ${#rollback_notes[@]} > 0 )); then
        echo "service limit-ip unlock gagal. Rollback: ${rollback_notes[*]}"
      else
        echo "service limit-ip unlock gagal. State di-rollback."
      fi
      return 1
    fi
  fi

  rm -f -- "${backup_file}" >/dev/null 2>&1 || true
  return 0
}

user_add_apply_locked() {
  local proto="$1"
  local username="$2"
  local quota_bytes="$3"
  local days="$4"
  local ip_enabled="$5"
  local ip_limit="$6"
  local speed_enabled="$7"
  local speed_down_mbit="$8"
  local speed_up_mbit="$9"
  local cred
  local stage_dir="" staged_account_file="" staged_quota_file=""
  local live_account_file="" live_quota_file=""

  if proto_uses_password "${proto}"; then
    cred="$(python3 - <<'PY'
import secrets
print(secrets.token_hex(16))
PY
)"
  else
    cred="$(gen_uuid)"
  fi

  live_account_file="${ACCOUNT_ROOT}/${proto}/${username}@${proto}.txt"
  live_quota_file="${QUOTA_ROOT}/${proto}/${username}@${proto}.json"
  stage_dir="$(mktemp -d "${WORK_DIR}/.xray-add.${username}.${proto}.XXXXXX" 2>/dev/null || true)"
  if [[ -z "${stage_dir}" || ! -d "${stage_dir}" ]]; then
    warn "Akun ${username}@${proto} dibatalkan: gagal menyiapkan staging artefak akun."
    pause
    return 1
  fi
  staged_account_file="${stage_dir}/account.txt"
  staged_quota_file="${stage_dir}/quota.json"

  if ! write_account_artifacts "${proto}" "${username}" "${cred}" "${quota_bytes}" "${days}" "${ip_enabled}" "${ip_limit}" "${speed_enabled}" "${speed_down_mbit}" "${speed_up_mbit}" "${staged_account_file}" "${staged_quota_file}"; then
    warn "Akun ${username}@${proto} dibatalkan: gagal menulis metadata akun/quota."
    rm -rf "${stage_dir}" >/dev/null 2>&1 || true
    pause
    return 1
  fi

  if ! xray_add_client "${proto}" "${username}" "${cred}"; then
    warn "Akun ${username}@${proto} dibatalkan: gagal menambah client ke inbounds Xray."
    if ! rollback_new_user_after_create_failure "${proto}" "${username}" "gagal menambah client ke inbounds Xray" "false"; then
      warn "Rollback add user tidak bersih sepenuhnya. Cek artefak account/quota/speed policy."
    fi
    rm -rf "${stage_dir}" >/dev/null 2>&1 || true
    pause
    return 1
  fi

  if [[ "${speed_enabled}" == "true" ]]; then
    local speed_mark="" speed_err=""
    if ! speed_mark="$(speed_policy_upsert "${proto}" "${username}" "${speed_down_mbit}" "${speed_up_mbit}")"; then
      speed_err="gagal menyimpan speed policy"
    elif ! speed_policy_sync_xray; then
      speed_err="gagal sinkronisasi speed policy ke routing/outbound xray"
    elif ! speed_policy_apply_now; then
      speed_err="policy speed tersimpan, tetapi apply runtime gagal (cek service xray-speed)"
    fi

    if [[ -n "${speed_err}" ]]; then
      warn "Akun ${username}@${proto} dibatalkan: ${speed_err}."
      if ! rollback_new_user_after_create_failure "${proto}" "${username}" "${speed_err}" "true"; then
        warn "Rollback add user tidak bersih sepenuhnya. Cek inbounds/account/quota/speed policy."
      fi
      rm -rf "${stage_dir}" >/dev/null 2>&1 || true
      pause
      return 1
    fi

    log "Speed policy aktif untuk ${username}@${proto} (mark=${speed_mark}, down=${speed_down_mbit}Mbps, up=${speed_up_mbit}Mbps)"
  else
    if speed_policy_exists "${proto}" "${username}"; then
      if ! speed_policy_remove_checked "${proto}" "${username}"; then
        warn "Akun ${username}@${proto} dibatalkan: gagal membersihkan speed policy lama."
        if ! rollback_new_user_after_create_failure "${proto}" "${username}" "cleanup speed policy lama gagal" "true"; then
          warn "Rollback add user tidak bersih sepenuhnya. Cek inbounds/account/quota/speed policy."
        fi
        rm -rf "${stage_dir}" >/dev/null 2>&1 || true
        pause
        return 1
      fi
      if ! speed_policy_sync_xray; then
        warn "Akun ${username}@${proto} dibatalkan: sinkronisasi speed policy lama gagal."
        if ! rollback_new_user_after_create_failure "${proto}" "${username}" "sinkronisasi speed policy lama gagal" "true"; then
          warn "Rollback add user tidak bersih sepenuhnya. Cek inbounds/account/quota/speed policy."
        fi
        rm -rf "${stage_dir}" >/dev/null 2>&1 || true
        pause
        return 1
      fi
    fi
    if ! speed_policy_apply_now >/dev/null 2>&1; then
      warn "Akun ${username}@${proto} dibatalkan: apply runtime speed policy gagal."
      if ! rollback_new_user_after_create_failure "${proto}" "${username}" "apply runtime speed policy gagal" "true"; then
        warn "Rollback add user tidak bersih sepenuhnya. Cek inbounds/account/quota/speed policy."
      fi
      rm -rf "${stage_dir}" >/dev/null 2>&1 || true
      pause
      return 1
    fi
  fi

  if ! account_info_restore_file_locked "${staged_account_file}" "${live_account_file}" >/dev/null 2>&1 \
    || ! quota_restore_file_locked "${staged_quota_file}" "${live_quota_file}" >/dev/null 2>&1; then
    warn "Akun ${username}@${proto} dibatalkan: gagal commit artefak account/quota dari staging."
    if ! rollback_new_user_after_create_failure "${proto}" "${username}" "commit artefak account/quota gagal" "true"; then
      warn "Rollback add user tidak bersih sepenuhnya. Cek inbounds/account/quota/speed policy."
    fi
    rm -rf "${stage_dir}" >/dev/null 2>&1 || true
    pause
    return 1
  fi

  rm -rf "${stage_dir}" >/dev/null 2>&1 || true

  title
  echo "Add user sukses ✅"
  local created_account_file created_quota_file
  created_account_file="${live_account_file}"
  created_quota_file="${live_quota_file}"
  hr
  echo "Account file:"
  echo "  ${created_account_file}"
  echo "Quota metadata:"
  echo "  ${created_quota_file}"
  hr
  echo "XRAY ACCOUNT INFO:"
  if [[ -f "${created_account_file}" ]]; then
    cat "${created_account_file}"
  else
    echo "(XRAY ACCOUNT INFO tidak ditemukan: ${created_account_file})"
  fi
  hr
  pause
}

user_del_apply_locked() {
  local proto="$1"
  local username="$2"
  local selected_file="$3"
  local partial_failure="false"
  local rollback_restored="false"
  local deleted_from_inbounds="false"
  local rollback_notes=()
  local previous_cred="" speed_policy_file="" rollback_tmpdir="" rollback_account_backup="" rollback_quota_backup="" rollback_speed_backup="" rollback_account_compat_backup="" rollback_quota_compat_backup=""
  local canonical_account_file compat_account_file canonical_quota_file compat_quota_file

  if [[ -f "${selected_file}" ]]; then
    if proto_uses_password "${proto}"; then
      previous_cred="$(grep -E '^Password\s*:' "${selected_file}" | head -n1 | sed 's/^Password\s*:\s*//' | tr -d '[:space:]' || true)"
    else
      previous_cred="$(grep -E '^UUID\s*:' "${selected_file}" | head -n1 | sed 's/^UUID\s*:\s*//' | tr -d '[:space:]' || true)"
    fi
  fi
  if [[ -z "${previous_cred}" ]]; then
    previous_cred="$(xray_user_current_credential_get "${proto}" "${username}")"
  fi
  if [[ -z "${previous_cred}" ]]; then
    warn "Delete user dibatalkan: credential lama untuk rollback tidak tersedia di file managed maupun runtime Xray."
    pause
    return 1
  fi

  speed_policy_file="$(speed_policy_file_path "${proto}" "${username}")"
  canonical_account_file="${ACCOUNT_ROOT}/${proto}/${username}@${proto}.txt"
  compat_account_file="${ACCOUNT_ROOT}/${proto}/${username}.txt"
  canonical_quota_file="${QUOTA_ROOT}/${proto}/${username}@${proto}.json"
  compat_quota_file="${QUOTA_ROOT}/${proto}/${username}.json"
  rollback_tmpdir="$(mktemp -d 2>/dev/null || true)"
  if [[ -n "${rollback_tmpdir}" && -d "${rollback_tmpdir}" ]]; then
    rollback_account_backup="${rollback_tmpdir}/account.txt"
    rollback_quota_backup="${rollback_tmpdir}/quota.json"
    rollback_speed_backup="${rollback_tmpdir}/speed.json"
    rollback_account_compat_backup="${rollback_tmpdir}/account.compat.txt"
    rollback_quota_compat_backup="${rollback_tmpdir}/quota.compat.json"
    [[ -f "${canonical_account_file}" ]] && cp -f "${canonical_account_file}" "${rollback_account_backup}" 2>/dev/null || true
    [[ -f "${compat_account_file}" ]] && cp -f "${compat_account_file}" "${rollback_account_compat_backup}" 2>/dev/null || true
    [[ -f "${canonical_quota_file}" ]] && cp -f "${canonical_quota_file}" "${rollback_quota_backup}" 2>/dev/null || true
    [[ -f "${compat_quota_file}" ]] && cp -f "${compat_quota_file}" "${rollback_quota_compat_backup}" 2>/dev/null || true
    [[ -f "${speed_policy_file}" ]] && cp -f "${speed_policy_file}" "${rollback_speed_backup}" 2>/dev/null || true
  fi

  if ! xray_delete_client "${proto}" "${username}"; then
    partial_failure="true"
    warn "Delete user dibatalkan: gagal menghapus client dari inbounds Xray."
  else
    deleted_from_inbounds="true"
  fi

  if [[ "${partial_failure}" != "true" ]] && ! delete_account_artifacts_checked "${proto}" "${username}"; then
    partial_failure="true"
    warn "Delete user dibatalkan: cleanup artefak lokal gagal setelah inbounds Xray dihapus."
  elif [[ "${partial_failure}" != "true" ]] && ! speed_policy_sync_xray_try; then
    partial_failure="true"
    warn "Delete user dibatalkan: sinkronisasi speed policy gagal setelah inbounds Xray dihapus."
  elif [[ "${partial_failure}" != "true" ]] && ! speed_policy_apply_now >/dev/null 2>&1; then
    partial_failure="true"
    warn "Delete user dibatalkan: apply runtime speed policy gagal setelah inbounds Xray dihapus."
  fi

  if [[ "${partial_failure}" == "true" ]]; then
    if [[ "${deleted_from_inbounds}" == "true" ]] && ! xray_add_client "${proto}" "${username}" "${previous_cred}" >/dev/null 2>&1; then
      rollback_notes+=("restore inbounds gagal")
    fi

    if [[ -n "${rollback_quota_backup}" && -f "${rollback_quota_backup}" ]]; then
      if ! quota_restore_file_locked "${rollback_quota_backup}" "${canonical_quota_file}" 2>/dev/null; then
        rollback_notes+=("restore quota gagal")
      fi
    fi
    if [[ -n "${rollback_quota_compat_backup}" && -f "${rollback_quota_compat_backup}" ]]; then
      if ! quota_restore_file_locked "${rollback_quota_compat_backup}" "${compat_quota_file}" 2>/dev/null; then
        rollback_notes+=("restore quota compat gagal")
      fi
    fi
    if [[ -n "${rollback_account_backup}" && -f "${rollback_account_backup}" ]]; then
      if ! account_info_restore_file_locked "${rollback_account_backup}" "${canonical_account_file}" 2>/dev/null; then
        rollback_notes+=("restore account info gagal")
      fi
    fi
    if [[ -n "${rollback_account_compat_backup}" && -f "${rollback_account_compat_backup}" ]]; then
      if ! account_info_restore_file_locked "${rollback_account_compat_backup}" "${compat_account_file}" 2>/dev/null; then
        rollback_notes+=("restore account info compat gagal")
      fi
    fi
    if [[ -n "${rollback_speed_backup}" && -f "${rollback_speed_backup}" ]]; then
      if ! speed_policy_restore_file_locked "${rollback_speed_backup}" "${speed_policy_file}" 2>/dev/null; then
        rollback_notes+=("restore speed policy gagal")
      fi
    fi

    if [[ -f "${canonical_quota_file}" ]]; then
      local st_quota st_manual st_iplocked
      st_quota="$(quota_get_status_bool "${canonical_quota_file}" "quota_exhausted" 2>/dev/null || echo "false")"
      st_manual="$(quota_get_status_bool "${canonical_quota_file}" "manual_block" 2>/dev/null || echo "false")"
      st_iplocked="$(quota_get_status_bool "${canonical_quota_file}" "ip_limit_locked" 2>/dev/null || echo "false")"
      xray_routing_set_user_in_marker "dummy-quota-user" "${username}@${proto}" "$( [[ "${st_quota}" == "true" ]] && echo on || echo off )" >/dev/null 2>&1 || rollback_notes+=("restore routing quota gagal")
      xray_routing_set_user_in_marker "dummy-block-user" "${username}@${proto}" "$( [[ "${st_manual}" == "true" ]] && echo on || echo off )" >/dev/null 2>&1 || rollback_notes+=("restore routing manual gagal")
      xray_routing_set_user_in_marker "dummy-limit-user" "${username}@${proto}" "$( [[ "${st_iplocked}" == "true" ]] && echo on || echo off )" >/dev/null 2>&1 || rollback_notes+=("restore routing ip-limit gagal")
      if ! quota_sync_speed_policy_for_user "${proto}" "${username}" "${canonical_quota_file}" >/dev/null 2>&1; then
        rollback_notes+=("restore speed policy runtime gagal")
      fi
      if ! account_info_refresh_warn "${proto}" "${username}" >/dev/null 2>&1; then
        rollback_notes+=("refresh account info rollback gagal")
      fi
    fi

    if (( ${#rollback_notes[@]} == 0 )); then
      rollback_restored="true"
      partial_failure="false"
    fi
  fi

  [[ -n "${rollback_tmpdir}" && -d "${rollback_tmpdir}" ]] && rm -rf "${rollback_tmpdir}" 2>/dev/null || true

  title
  if [[ "${rollback_restored}" == "true" ]]; then
    echo "Delete user dibatalkan ⚠"
    echo "Cleanup akhir gagal, tetapi rollback berhasil memulihkan akun."
  elif [[ "${partial_failure}" == "true" ]]; then
    if [[ "${deleted_from_inbounds}" == "true" ]]; then
      echo "Delete user selesai parsial ⚠"
      echo "Perubahan utama sudah diterapkan, tetapi cleanup/sinkronisasi lanjutan belum bersih."
    else
      echo "Delete user dibatalkan parsial ⚠"
      echo "Inbounds Xray belum dihapus, tetapi rollback artefak lokal belum pulih sepenuhnya."
    fi
    if (( ${#rollback_notes[@]} > 0 )); then
      printf 'Rollback gagal: %s\n' "$(IFS=' | '; echo "${rollback_notes[*]}")"
    fi
  else
    echo "Delete user selesai ✅"
  fi
  hr
  pause
  if [[ "${rollback_restored}" == "true" || "${partial_failure}" == "true" ]]; then
    return 1
  fi
  return 0
}

user_extend_expiry_apply_locked() {
  local proto="$1"
  local username="$2"
  local quota_file="$3"
  local acc_file="$4"
  local current_expiry="$5"
  local new_expiry="$6"
  local email_for_routing existing_protos was_present_in_inbounds="false" readded_inbounds="false"
  local quota_backup_file=""
  local expired_daemon_paused="false"

  quota_backup_file="$(mktemp "${WORK_DIR}/.quota-expiry.${username}.${proto}.XXXXXX" 2>/dev/null || true)"
  if [[ -z "${quota_backup_file}" ]]; then
    warn "Gagal membuat backup metadata expiry."
    pause
    return 1
  fi

  if ! xray_expired_pause_if_active expired_daemon_paused; then
    rm -f -- "${quota_backup_file}" >/dev/null 2>&1 || true
    warn "Gagal menghentikan xray-expired sementara waktu. Extend expiry dibatalkan agar state tidak race."
    pause
    return 1
  fi

  email_for_routing="${username}@${proto}"
  existing_protos="$(xray_username_find_protos "${username}" 2>/dev/null || true)"
  if echo " ${existing_protos} " | grep -q " ${proto} "; then
    was_present_in_inbounds="true"
  fi

  if ! QUOTA_ATOMIC_BACKUP_FILE="${quota_backup_file}" quota_atomic_update_file "${quota_file}" set_expired_at "${new_expiry}"; then
    if ! xray_expired_resume_if_needed "${expired_daemon_paused}"; then
      warn "xray-expired gagal diaktifkan kembali setelah extend expiry dibatalkan."
    fi
    rm -f -- "${quota_backup_file}" >/dev/null 2>&1 || true
    warn "Gagal update metadata expiry quota."
    pause
    return 1
  fi

  if [[ "${was_present_in_inbounds}" != "true" ]]; then
    local restore_failed="false"
    local restore_reason=""
    if [[ -f "${acc_file}" ]]; then
      local cred=""
      if proto_uses_password "${proto}"; then
        cred="$(grep -E '^Password\s*:' "${acc_file}" | head -n1 | sed 's/^Password\s*:\s*//' | tr -d '[:space:]' || true)"
      else
        cred="$(grep -E '^UUID\s*:' "${acc_file}" | head -n1 | sed 's/^UUID\s*:\s*//' | tr -d '[:space:]' || true)"
      fi
      if [[ -n "${cred}" ]]; then
        if xray_add_client_try "${proto}" "${username}" "${cred}"; then
          readded_inbounds="true"
          log "User ${username}@${proto} di-restore ke inbounds (expired lalu di-extend)."
        else
          restore_failed="true"
          restore_reason="Gagal me-restore ${username}@${proto} ke inbounds. Cek credential di: ${acc_file}"
        fi
      else
        restore_failed="true"
        restore_reason="Credential tidak ditemukan di ${acc_file}. Re-add user manual jika diperlukan."
      fi
    else
      restore_failed="true"
      restore_reason="Account file tidak ada: ${acc_file}. User mungkin perlu di-add ulang secara manual."
    fi

    if [[ "${restore_failed}" == "true" ]]; then
      local rollback_msg=""
      rollback_msg="$(xray_user_expiry_rollback "${quota_file}" "${quota_backup_file}" "${proto}" "${username}" "${email_for_routing}" "${current_expiry}" "${was_present_in_inbounds}" "${readded_inbounds}" 2>&1 || true)"
      if ! xray_expired_resume_if_needed "${expired_daemon_paused}"; then
        warn "xray-expired gagal diaktifkan kembali setelah rollback extend expiry."
      fi
      warn "${restore_reason}"
      [[ -n "${rollback_msg}" ]] && warn "${rollback_msg}"
      rm -f -- "${quota_backup_file}" >/dev/null 2>&1 || true
      pause
      return 1
    fi
  fi

  if [[ "$(quota_get_status_bool "${quota_file}" "quota_exhausted" 2>/dev/null || echo "false")" == "true" ]]; then
    if ! quota_atomic_update_file "${quota_file}" clear_quota_exhausted_recompute; then
      local rollback_msg=""
      rollback_msg="$(xray_user_expiry_rollback "${quota_file}" "${quota_backup_file}" "${proto}" "${username}" "${email_for_routing}" "${current_expiry}" "${was_present_in_inbounds}" "${readded_inbounds}" 2>&1 || true)"
      if ! xray_expired_resume_if_needed "${expired_daemon_paused}"; then
        warn "xray-expired gagal diaktifkan kembali setelah rollback extend expiry."
      fi
      warn "Gagal reset status quota exhausted setelah extend expiry."
      [[ -n "${rollback_msg}" ]] && warn "${rollback_msg}"
      rm -f -- "${quota_backup_file}" >/dev/null 2>&1 || true
      pause
      return 1
    fi
    log "Quota exhausted flag di-reset setelah extend expiry."
  fi

  local apply_msg=""
  if ! apply_msg="$(xray_qac_apply_runtime_from_quota "${quota_file}" "${proto}" "${username}" "${email_for_routing}" true true)"; then
    local rollback_msg=""
    rollback_msg="$(xray_user_expiry_rollback "${quota_file}" "${quota_backup_file}" "${proto}" "${username}" "${email_for_routing}" "${current_expiry}" "${was_present_in_inbounds}" "${readded_inbounds}" 2>&1 || true)"
    if ! xray_expired_resume_if_needed "${expired_daemon_paused}"; then
      warn "xray-expired gagal diaktifkan kembali setelah rollback extend expiry."
    fi
    warn "Extend expiry gagal: ${apply_msg}"
    [[ -n "${rollback_msg}" ]] && warn "${rollback_msg}"
    rm -f -- "${quota_backup_file}" >/dev/null 2>&1 || true
    pause
    return 1
  fi

  if ! xray_expired_resume_if_needed "${expired_daemon_paused}"; then
    rm -f -- "${quota_backup_file}" >/dev/null 2>&1 || true
    warn "Expiry berhasil diperbarui, tetapi xray-expired gagal diaktifkan kembali."
    pause
    return 1
  fi

  rm -f -- "${quota_backup_file}" >/dev/null 2>&1 || true

  title
  echo "Extend/Set Expiry selesai ✅"
  hr
  echo "  ${username}@${proto}"
  echo "  Expiry baru : ${new_expiry}"
  hr
  pause
}

user_reset_credential_apply_locked() {
  local proto="$1"
  local username="$2"
  local selected_file="$3"
  local previous_cred="" new_cred label
  local snapshot_dir="" selected_snapshot="" target_file="" snapshot_source="" staged_account_file=""

  target_file="$(account_info_refresh_target_file_for_user "${proto}" "${username}")"
  snapshot_source="${target_file}"
  if [[ -f "${selected_file}" ]]; then
    snapshot_source="${selected_file}"
    if proto_uses_password "${proto}"; then
      previous_cred="$(grep -E '^Password\s*:' "${selected_file}" | head -n1 | sed 's/^Password\s*:\s*//' | tr -d '[:space:]' || true)"
    else
      previous_cred="$(grep -E '^UUID\s*:' "${selected_file}" | head -n1 | sed 's/^UUID\s*:\s*//' | tr -d '[:space:]' || true)"
    fi
  fi
  if [[ -z "${previous_cred}" ]]; then
    previous_cred="$(xray_user_current_credential_get "${proto}" "${username}")"
  fi
  if [[ -z "${previous_cred}" ]]; then
    warn "Credential lama tidak ditemukan di file managed maupun runtime Xray."
    pause
    return 1
  fi

  if proto_uses_password "${proto}"; then
    new_cred="$(python3 - <<'PY'
import secrets
print(secrets.token_hex(16))
PY
)"
    label="Password baru"
  else
    new_cred="$(gen_uuid)"
    label="UUID baru"
  fi

  snapshot_dir="$(mktemp -d "${WORK_DIR}/.reset-cred.${username}.${proto}.XXXXXX" 2>/dev/null || true)"
  if [[ -z "${snapshot_dir}" || ! -d "${snapshot_dir}" ]]; then
    warn "Gagal menyiapkan staging reset ${label,,} untuk ${username}@${proto}."
    pause
    return 1
  fi
  if [[ -n "${snapshot_dir}" && -f "${snapshot_source}" ]]; then
    selected_snapshot="${snapshot_dir}/account.txt"
    cp -f -- "${snapshot_source}" "${selected_snapshot}" >/dev/null 2>&1 || selected_snapshot=""
  fi
  staged_account_file="${snapshot_dir}/account.new.txt"

  if ! account_info_refresh_for_user "${proto}" "${username}" "" "" "${new_cred}" "${staged_account_file}"; then
    [[ -n "${snapshot_dir}" ]] && rm -rf "${snapshot_dir}" >/dev/null 2>&1 || true
    warn "Reset ${label,,} dibatalkan: XRAY ACCOUNT INFO baru gagal disiapkan sebelum credential live diubah."
    pause
    return 1
  fi

  if ! xray_reset_client_credential_try "${proto}" "${username}" "${new_cred}"; then
    [[ -n "${snapshot_dir}" ]] && rm -rf "${snapshot_dir}" >/dev/null 2>&1 || true
    warn "Gagal mereset ${label,,} untuk ${username}@${proto}."
    pause
    return 1
  fi

  if ! account_info_restore_file_locked "${staged_account_file}" "${target_file}" >/dev/null 2>&1; then
    if xray_reset_client_credential_try "${proto}" "${username}" "${previous_cred}"; then
      local rollback_file_failed="false"
      if [[ -n "${selected_snapshot}" && -f "${selected_snapshot}" ]]; then
        if ! account_info_restore_file_locked "${selected_snapshot}" "${target_file}" >/dev/null 2>&1; then
          if ! account_info_refresh_for_user "${proto}" "${username}" "" "" "${previous_cred}" >/dev/null 2>&1; then
            rollback_file_failed="true"
          fi
        fi
      elif ! account_info_refresh_for_user "${proto}" "${username}" >/dev/null 2>&1; then
        rollback_file_failed="true"
      fi
      if [[ "${rollback_file_failed}" == "true" ]]; then
        warn "Reset ${label,,} dibatalkan: commit XRAY ACCOUNT INFO baru gagal, credential lama dipulihkan tetapi rollback account info gagal."
      else
        warn "Reset ${label,,} dibatalkan: commit XRAY ACCOUNT INFO baru gagal, credential lama dipulihkan."
      fi
    else
      local live_cred=""
      live_cred="$(xray_user_current_credential_get "${proto}" "${username}" 2>/dev/null || true)"
      if [[ -n "${live_cred}" ]]; then
        account_info_refresh_for_user "${proto}" "${username}" "" "" "${live_cred}" >/dev/null 2>&1 || true
      fi
      warn "Reset ${label,,} gagal: commit XRAY ACCOUNT INFO baru gagal dan rollback credential juga gagal."
    fi
    [[ -n "${snapshot_dir}" ]] && rm -rf "${snapshot_dir}" >/dev/null 2>&1 || true
    pause
    return 1
  fi

  [[ -n "${snapshot_dir}" ]] && rm -rf "${snapshot_dir}" >/dev/null 2>&1 || true

  title
  echo "Reset UUID/Password selesai ✅"
  hr
  echo "User         : ${username}@${proto}"
  echo "${label} : ${new_cred}"
  local account_file
  account_file="${ACCOUNT_ROOT}/${proto}/${username}@${proto}.txt"
  hr
  echo "Account file:"
  echo "  ${account_file}"
  hr
  echo "XRAY ACCOUNT INFO:"
  if [[ -f "${account_file}" ]]; then
    cat "${account_file}"
  else
    echo "(XRAY ACCOUNT INFO tidak ditemukan: ${account_file})"
  fi
  hr
  pause
}

user_add_menu() {
  local proto
  title
  echo "Xray Users > Add User"
  hr

  ensure_account_quota_dirs
  need_python3

  echo "Pilih protocol:"
  proto_list_menu_print
  hr
  if ! read -r -p "Protocol (1-5/kembali): " p; then
    echo
    return 0
  fi
  if is_back_choice "${p}"; then
    return 0
  fi
  proto="$(proto_menu_pick_to_value "${p}")"
  if [[ -z "${proto}" ]]; then
    warn "Protocol tidak valid"
    pause
    return 0
  fi

  local page=0
  while true; do
    title
    echo "Xray Users > Add User"
    hr
    echo "Protocol terpilih: ${proto}"
    echo "Daftar akun ${proto} (10 per halaman):"
    hr
    account_collect_files "${proto}"
    ACCOUNT_PAGE="${page}"
    if (( ${#ACCOUNT_FILES[@]} > 0 )); then
      account_print_table_page "${ACCOUNT_PAGE}" "${proto}"
    else
      echo "  (Belum ada akun ${proto} terkelola)"
      echo "  Ketik lanjut untuk membuat akun baru."
      echo
      echo "Halaman: 0/0  | Total akun: 0"
    fi
    hr
    echo "Ketik: lanjut / next / previous / kembali"
    if ! read -r -p "Pilihan: " nav; then
      echo
      return 0
    fi
    if is_back_choice "${nav}"; then
      return 0
    fi
    case "${nav}" in
      lanjut|lanjutkan|l) break ;;
      next|n)
        local pages
        pages="$(account_total_pages)"
        if (( pages > 0 && page < pages - 1 )); then page=$((page + 1)); fi
        ;;
      previous|p|prev)
        if (( page > 0 )); then page=$((page - 1)); fi
        ;;
      *) invalid_choice ;;
    esac
  done

  title
  echo "Xray Users > Add User"
  hr
  echo "Protocol : ${proto}"
  hr

  if ! read -r -p "Username (atau kembali): " username; then
    echo
    return 0
  fi
  if is_back_choice "${username}"; then
    return 0
  fi
  if [[ -z "${username}" ]]; then
    warn "Username kosong"
    pause
    return 0
  fi

  if ! validate_username "${username}"; then
    warn "Username tidak valid. Gunakan: A-Z a-z 0-9 . _ - (tanpa spasi, tanpa '/', tanpa '..', tanpa '@')."
    pause
    return 0
  fi


  local found_xray found_account found_quota
  found_xray="$(xray_username_find_protos "${username}" || true)"
  found_account="$(account_username_find_protos "${username}" || true)"
  found_quota="$(quota_username_find_protos "${username}" || true)"
  if [[ -n "${found_xray}" || -n "${found_account}" || -n "${found_quota}" ]]; then
    warn "Username sudah ada, batal membuat akun: ${username}"
    [[ -n "${found_xray}" ]] && echo "  - Xray inbounds: ${found_xray}"
    [[ -n "${found_account}" ]] && echo "  - Account file : ${found_account}"
    [[ -n "${found_quota}" ]] && echo "  - Quota meta   : ${found_quota}"
    pause
    return 0
  fi

  if ! read -r -p "Masa aktif (hari) (atau kembali): " days; then
    echo
    return 0
  fi
  if is_back_word_choice "${days}"; then
    return 0
  fi
  if [[ -z "${days}" || ! "${days}" =~ ^[0-9]+$ || "${days}" -le 0 ]]; then
    warn "Masa aktif harus angka hari > 0"
    pause
    return 0
  fi

  if ! read -r -p "Quota (GB) (atau kembali): " quota_gb; then
    echo
    return 0
  fi
  if is_back_choice "${quota_gb}"; then
    return 0
  fi
  if [[ -z "${quota_gb}" ]]; then
    warn "Quota kosong"
    pause
    return 0
  fi
  local quota_gb_num quota_bytes
  quota_gb_num="$(normalize_gb_input "${quota_gb}")"
  if [[ -z "${quota_gb_num}" ]]; then
    warn "Format quota tidak valid. Contoh: 10 atau 10GB"
    pause
    return 0
  fi
  quota_gb="${quota_gb_num}"
  quota_bytes="$(bytes_from_gb "${quota_gb_num}")"

  local ip_toggle=""
  echo "Limit IP? (on/off)"
  if ! read_required_on_off ip_toggle "IP Limit (on/off) (atau kembali): "; then
    return 0
  fi
  local ip_enabled="false"
  local ip_limit="0"
  if [[ "${ip_toggle}" == "on" ]]; then
    ip_enabled="true"
    if ! read -r -p "Limit IP (angka) (atau kembali): " ip_limit; then
      echo
      return 0
    fi
    if is_back_word_choice "${ip_limit}"; then
      return 0
    fi
    if [[ -z "${ip_limit}" || ! "${ip_limit}" =~ ^[0-9]+$ || "${ip_limit}" -le 0 ]]; then
      warn "Limit IP harus angka > 0"
      pause
      return 0
    fi
  fi

  local speed_toggle=""
  echo "Limit speed per user? (on/off)"
  if ! read_required_on_off speed_toggle "Speed Limit (on/off) (atau kembali): "; then
    return 0
  fi
  local speed_enabled="false"
  local speed_down_mbit="0"
  local speed_up_mbit="0"
  if [[ "${speed_toggle}" == "on" ]]; then
    speed_enabled="true"

    if ! read -r -p "Speed Download Mbps (contoh: 20 atau 20mbit) (atau kembali): " speed_down; then
      echo
      return 0
    fi
    if is_back_word_choice "${speed_down}"; then
      return 0
    fi
    speed_down_mbit="$(normalize_speed_mbit_input "${speed_down}")"
    if [[ -z "${speed_down_mbit}" ]] || ! speed_mbit_is_positive "${speed_down_mbit}"; then
      warn "Speed download tidak valid. Gunakan angka > 0, contoh: 20 atau 20mbit"
      pause
      return 0
    fi

    if ! read -r -p "Speed Upload Mbps (contoh: 10 atau 10mbit) (atau kembali): " speed_up; then
      echo
      return 0
    fi
    if is_back_word_choice "${speed_up}"; then
      return 0
    fi
    speed_up_mbit="$(normalize_speed_mbit_input "${speed_up}")"
    if [[ -z "${speed_up_mbit}" ]] || ! speed_mbit_is_positive "${speed_up_mbit}"; then
      warn "Speed upload tidak valid. Gunakan angka > 0, contoh: 10 atau 10mbit"
      pause
      return 0
    fi
  fi

  hr
  echo "Ringkasan:"
  echo "  Username : ${username}"
  echo "  Protocol : ${proto}"
  echo "  Email    : ${username}@${proto}"
  echo "  Expired  : ${days} hari"
  echo "  Quota    : ${quota_gb} GB"
  echo "  IP Limit : ${ip_enabled} $( [[ "${ip_enabled}" == "true" ]] && echo "(${ip_limit})" )"
  if [[ "${speed_enabled}" == "true" ]]; then
    echo "  Speed    : true (DOWN ${speed_down_mbit} Mbps | UP ${speed_up_mbit} Mbps)"
  else
    echo "  Speed    : false"
  fi
  hr
  local create_confirm_rc=0
  if confirm_yn_or_back "Buat user ini sekarang?"; then
    :
  else
    create_confirm_rc=$?
    if (( create_confirm_rc == 2 )); then
      warn "Pembuatan user dibatalkan (kembali)."
      pause
      return 0
    fi
    warn "Pembuatan user dibatalkan."
    pause
    return 0
  fi

  user_data_mutation_run_locked user_add_apply_locked "${proto}" "${username}" "${quota_bytes}" "${days}" "${ip_enabled}" "${ip_limit}" "${speed_enabled}" "${speed_down_mbit}" "${speed_up_mbit}"
}





user_del_menu() {
  ensure_account_quota_dirs
  need_python3

  title
  echo "Xray Users > Delete User"
  hr
  echo "Pilih protocol:"
  proto_list_menu_print
  hr
  if ! read -r -p "Protocol (1-5/kembali): " p; then
    echo
    return 0
  fi
  if is_back_choice "${p}"; then
    return 0
  fi
  local proto
  proto="$(proto_menu_pick_to_value "${p}")"
  if [[ -z "${proto}" ]]; then
    warn "Protocol tidak valid"
    pause
    return 0
  fi

  local page=0
  local username="" selected_file="" selected_quota_file=""
  while true; do
    title
    echo "Xray Users > Delete User"
    hr
    echo "Protocol terpilih: ${proto}"
    echo "Daftar akun ${proto} (10 per halaman):"
    hr
    account_collect_files "${proto}"
    ACCOUNT_PAGE="${page}"
    if (( ${#ACCOUNT_FILES[@]} > 0 )); then
      account_print_table_page "${ACCOUNT_PAGE}" "${proto}"
    else
      echo "  (Belum ada akun ${proto} terkelola)"
      echo
      echo "Halaman: 0/0  | Total akun: 0"
      hr
      echo "Ketik: kembali"
      if ! read -r -p "Pilihan: " nav; then
        echo
        return 0
      fi
      return 0
    fi
    hr
    echo "Ketik NO akun, atau: next / previous / kembali"
    local nav=""
    if ! read -r -p "Pilihan: " nav; then
      echo
      return 0
    fi
    if is_back_choice "${nav}"; then
      return 0
    fi
    case "${nav}" in
      next|n)
        local pages
        pages="$(account_total_pages)"
        if (( pages > 0 && page < pages - 1 )); then page=$((page + 1)); fi
        continue
        ;;
      previous|p|prev)
        if (( page > 0 )); then page=$((page - 1)); fi
        continue
        ;;
    esac

    if [[ ! "${nav}" =~ ^[0-9]+$ ]]; then
      invalid_choice
      continue
    fi

    local total pages start end rows idx
    total="${#ACCOUNT_FILES[@]}"
    pages=$(( (total + ACCOUNT_PAGE_SIZE - 1) / ACCOUNT_PAGE_SIZE ))
    if (( page < 0 )); then page=0; fi
    if (( pages > 0 && page >= pages )); then page=$((pages - 1)); fi
    start=$((page * ACCOUNT_PAGE_SIZE))
    end=$((start + ACCOUNT_PAGE_SIZE))
    if (( end > total )); then end="${total}"; fi
    rows=$((end - start))

    if (( nav < 1 || nav > rows )); then
      warn "NO di luar range"
      pause
      continue
    fi

    idx=$((start + nav - 1))
    selected_file="${ACCOUNT_FILES[$idx]}"
    username="$(account_parse_username_from_file "${selected_file}" "${proto}")"
    selected_quota_file="${QUOTA_ROOT}/${proto}/${username}@${proto}.json"

    title
    echo "Xray Users > Delete User"
    hr
    echo "Protocol : ${proto}"
    echo "Username : ${username}"
    echo "Account  : ${selected_file}"
    echo "Quota    : ${selected_quota_file}"
    hr

    local confirm_rc=0
    if confirm_yn_or_back "Hapus user ini?"; then
      break
    else
      confirm_rc=$?
      if (( confirm_rc == 2 )); then
        return 0
      fi
      continue
    fi
  done

  hr
  user_data_mutation_run_locked user_del_apply_locked "${proto}" "${username}" "${selected_file}"
}





user_extend_expiry_menu() {
  local page=0
  while true; do
    title
    echo "Xray Users > Set Expiry"
    hr
    echo "Daftar akun (10 per halaman):"
    hr
    account_collect_files
    ACCOUNT_PAGE="${page}"
    account_print_table_page "${ACCOUNT_PAGE}"
    hr
    echo "Ketik: lanjut / next / previous / kembali"
    if ! read -r -p "Pilihan: " nav; then
      echo
      return 0
    fi
    if is_back_choice "${nav}"; then
      return 0
    fi
    case "${nav}" in
      lanjut|lanjutkan|l) break ;;
      next|n)
        local pages
        pages="$(account_total_pages)"
        if (( pages > 0 && page < pages - 1 )); then page=$((page + 1)); fi
        ;;
      previous|p|prev)
        if (( page > 0 )); then page=$((page - 1)); fi
        ;;
      *) invalid_choice ;;
    esac
  done

  title
  echo "Xray Users > Set Expiry"
  hr

  ensure_account_quota_dirs
  need_python3

  echo "Pilih protocol:"
  proto_list_menu_print
  hr
  if ! read -r -p "Protocol (1-5/kembali): " p; then
    echo
    return 0
  fi
  if is_back_choice "${p}"; then
    return 0
  fi
  local proto
  proto="$(proto_menu_pick_to_value "${p}")"
  if [[ -z "${proto}" ]]; then
    warn "Protocol tidak valid"
    pause
    return 0
  fi

  if ! read -r -p "Username (atau kembali): " username; then
    echo
    return 0
  fi
  if is_back_choice "${username}"; then
    return 0
  fi
  if [[ -z "${username}" ]]; then
    warn "Username kosong"
    pause
    return 0
  fi

  if ! validate_username "${username}"; then
    warn "Username tidak valid. Gunakan: A-Z a-z 0-9 . _ - (tanpa spasi, tanpa '/', tanpa '..', tanpa '@')."
    pause
    return 0
  fi

  local quota_file acc_file
  quota_file="${QUOTA_ROOT}/${proto}/${username}@${proto}.json"
  acc_file="${ACCOUNT_ROOT}/${proto}/${username}@${proto}.txt"

  if [[ ! -f "${quota_file}" ]]; then
    warn "Quota file tidak ditemukan: ${quota_file}"
    pause
    return 0
  fi

  # Tampilkan expiry saat ini
  local current_expiry
  current_expiry="$(python3 - <<'PY' "${quota_file}"
import json, sys
p = sys.argv[1]
try:
  d = json.load(open(p, 'r', encoding='utf-8'))
  print(str(d.get("expired_at") or "-"))
except Exception:
  print("-")
PY
)"

  hr
  echo "Username    : ${username}"
  echo "Protocol    : ${proto}"
  echo "Expiry saat ini : ${current_expiry}"
  hr
  echo "  1) Tambah hari (extend)"
  echo "  2) Set tanggal langsung (YYYY-MM-DD)"
  echo "  0) Back"
  hr
  if ! read -r -p "Pilih mode: " mode; then
    echo
    return 0
  fi
  if is_back_choice "${mode}"; then
    return 0
  fi

  local new_expiry=""

  case "${mode}" in
    1)
      if ! read -r -p "Tambah berapa hari? (atau kembali): " add_days; then
        echo
        return 0
      fi
      if is_back_word_choice "${add_days}"; then
        return 0
      fi
      if [[ -z "${add_days}" || ! "${add_days}" =~ ^[0-9]+$ || "${add_days}" -le 0 ]]; then
        warn "Jumlah hari harus angka > 0"
        pause
        return 0
      fi
      # Hitung dari expiry saat ini, jika sudah lewat hitung dari hari ini
      new_expiry="$(python3 - <<'PY' "${current_expiry}" "${add_days}"
import sys
from datetime import datetime, timedelta
exp_str = sys.argv[1].strip()
add = int(sys.argv[2])
today = datetime.now().date()
try:
  base = datetime.fromisoformat(exp_str[:10]).date()
  # Jika sudah expired, mulai dari hari ini
  if base < today:
    base = today
except Exception:
  base = today
result = base + timedelta(days=add)
print(result.strftime('%Y-%m-%d'))
PY
)"
      ;;
    2)
      if ! read -r -p "Tanggal expiry baru (YYYY-MM-DD) (atau kembali): " input_date; then
        echo
        return 0
      fi
      if is_back_choice "${input_date}"; then
        return 0
      fi
      # Validasi format tanggal
      if ! python3 - <<'PY' "${input_date}" 2>/dev/null; then
import sys
from datetime import datetime
s = sys.argv[1].strip()
try:
  datetime.strptime(s, '%Y-%m-%d')
  print(s)
except Exception:
  raise SystemExit(1)
PY
        warn "Format tanggal tidak valid. Gunakan: YYYY-MM-DD"
        pause
        return 0
      fi
      new_expiry="$(python3 - <<'PY' "${input_date}"
import sys
from datetime import datetime
s = sys.argv[1].strip()
datetime.strptime(s, '%Y-%m-%d')
print(s)
PY
)"
      ;;
    0|kembali|k|back|b)
      return 0
      ;;
    *)
      warn "Pilihan tidak valid"
      pause
      return 0
      ;;
  esac

  if [[ -z "${new_expiry}" ]]; then
    warn "Gagal menghitung tanggal baru"
    pause
    return 0
  fi

  if date_ymd_is_past "${new_expiry}"; then
    warn "Tanggal expiry ${new_expiry} sudah lewat dan akan membuat akun segera expired."
    if ! confirm_menu_apply_now "Tetap terapkan expiry lampau ${new_expiry} untuk ${username}@${proto}?"; then
      pause
      return 0
    fi
  fi

  hr
  echo "Ringkasan perubahan:"
  echo "  Username  : ${username}@${proto}"
  echo "  Expiry sebelumnya : ${current_expiry}"
  echo "  Expiry baru : ${new_expiry}"
  hr
  local confirm_rc=0
  if confirm_yn_or_back "Konfirmasi simpan?"; then
    :
  else
    confirm_rc=$?
    if (( confirm_rc == 2 )); then
      warn "Dibatalkan (kembali)."
      pause
      return 0
    fi
    warn "Dibatalkan."
    pause
    return 0
  fi

  user_data_mutation_run_locked user_extend_expiry_apply_locked "${proto}" "${username}" "${quota_file}" "${acc_file}" "${current_expiry}" "${new_expiry}"
}

user_reset_credential_menu() {
  ensure_account_quota_dirs
  need_python3

  title
  echo "Xray Users > Reset UUID/Password"
  hr
  echo "Pilih protocol:"
  proto_list_menu_print
  hr
  if ! read -r -p "Protocol (1-3/kembali): " p; then
    echo
    return 0
  fi
  if is_back_choice "${p}"; then
    return 0
  fi
  local proto
  proto="$(proto_menu_pick_to_value "${p}")"
  if [[ -z "${proto}" ]]; then
    warn "Protocol tidak valid"
    pause
    return 0
  fi

  local page=0
  local username="" selected_file="" selected_quota_file=""
  while true; do
    title
    echo "Xray Users > Reset UUID/Password"
    hr
    echo "Protocol terpilih: ${proto}"
    echo "Daftar akun ${proto} (10 per halaman):"
    hr
    account_collect_files "${proto}"
    ACCOUNT_PAGE="${page}"
    if (( ${#ACCOUNT_FILES[@]} > 0 )); then
      account_print_table_page "${ACCOUNT_PAGE}" "${proto}"
    else
      echo "  (Belum ada akun ${proto} terkelola)"
      echo
      echo "Halaman: 0/0  | Total akun: 0"
      hr
      echo "Ketik: kembali"
      if ! read -r -p "Pilihan: " nav; then
        echo
        return 0
      fi
      return 0
    fi
    hr
    echo "Ketik NO akun, atau: next / previous / kembali"
    local nav=""
    if ! read -r -p "Pilihan: " nav; then
      echo
      return 0
    fi
    if is_back_choice "${nav}"; then
      return 0
    fi
    case "${nav}" in
      next|n)
        local pages
        pages="$(account_total_pages)"
        if (( pages > 0 && page < pages - 1 )); then page=$((page + 1)); fi
        continue
        ;;
      previous|p|prev)
        if (( page > 0 )); then page=$((page - 1)); fi
        continue
        ;;
    esac

    if [[ ! "${nav}" =~ ^[0-9]+$ ]]; then
      invalid_choice
      continue
    fi

    local total pages start end rows idx
    total="${#ACCOUNT_FILES[@]}"
    pages=$(( (total + ACCOUNT_PAGE_SIZE - 1) / ACCOUNT_PAGE_SIZE ))
    if (( page < 0 )); then page=0; fi
    if (( pages > 0 && page >= pages )); then page=$((pages - 1)); fi
    start=$((page * ACCOUNT_PAGE_SIZE))
    end=$((start + ACCOUNT_PAGE_SIZE))
    if (( end > total )); then end="${total}"; fi
    rows=$((end - start))

    if (( nav < 1 || nav > rows )); then
      warn "NO di luar range"
      pause
      continue
    fi

    idx=$((start + nav - 1))
    selected_file="${ACCOUNT_FILES[$idx]}"
    username="$(account_parse_username_from_file "${selected_file}" "${proto}")"
    selected_quota_file="${QUOTA_ROOT}/${proto}/${username}@${proto}.json"

    title
    echo "Xray Users > Reset UUID/Password"
    hr
    echo "Protocol : ${proto}"
    echo "Username : ${username}"
    echo "Account  : ${selected_file}"
    echo "Quota    : ${selected_quota_file}"
    hr

    local confirm_rc=0
    if confirm_yn_or_back "Reset UUID/password user ini?"; then
      break
    else
      confirm_rc=$?
      if (( confirm_rc == 2 )); then
        return 0
      fi
      continue
    fi
  done

  user_data_mutation_run_locked user_reset_credential_apply_locked "${proto}" "${username}" "${selected_file}"
}

user_list_menu() {
  ACCOUNT_PAGE=0
  while true; do
    title
    echo "Xray Users > List Users"
    hr

    account_collect_files
    account_print_table_page "${ACCOUNT_PAGE}"
    hr

    echo "  view) View file detail"
    echo "  search) Search"
    echo "  next) Next page"
    echo "  previous) Previous page"
    echo "  refresh) Refresh"
    hr
    if ! read -r -p "Pilih (view/search/next/previous/refresh/kembali): " c; then
      echo
      break
    fi

    if is_back_choice "${c}"; then
      break
    fi

    case "${c}" in
      view|1) account_view_flow ;;
      search|2) account_search_flow ;;
      next|n)
        local pages
        pages="$(account_total_pages)"
        if (( pages > 0 && ACCOUNT_PAGE < pages - 1 )); then
          ACCOUNT_PAGE=$((ACCOUNT_PAGE + 1))
        fi
        ;;
      previous|p|prev)
        if (( ACCOUNT_PAGE > 0 )); then
          ACCOUNT_PAGE=$((ACCOUNT_PAGE - 1))
        fi
        ;;
      refresh|3) : ;;
      *) invalid_choice ;;
    esac
  done
}

user_menu() {
  local -a items=(
    "1|Add User"
    "2|Delete User"
    "3|Set Expiry"
    "4|Reset UUID/Password"
    "5|List Users"
    "0|Back"
  )
  while true; do
    ui_menu_screen_begin "2) Xray Users"
    ui_menu_render_options items 76
    hr
    if ! read -r -p "Pilih: " c; then
      echo
      break
    fi
    case "${c}" in
      1) menu_run_isolated_report "Add Xray User" user_add_menu ;;
      2) menu_run_isolated_report "Delete Xray User" user_del_menu ;;
      3) menu_run_isolated_report "Set Xray Expiry" user_extend_expiry_menu ;;
      4) menu_run_isolated_report "Reset Xray Credential" user_reset_credential_menu ;;
      5) user_list_menu ;;
      0|kembali|k|back|b) break ;;
      *) invalid_choice ;;
    esac
  done
}

# -------------------------
# Quota & Access Control
# - Sumber metadata: /opt/quota/(vless|vmess|trojan)/*.json
# - Perubahan JSON menggunakan atomic write (tmp + replace) untuk menghindari file korup
# -------------------------
QUOTA_FILES=()
QUOTA_FILE_PROTOS=()
QUOTA_PAGE_SIZE=10
QUOTA_PAGE=0
QUOTA_QUERY=""
QUOTA_VIEW_INDEXES=()

quota_collect_files() {
  QUOTA_FILES=()
  QUOTA_FILE_PROTOS=()

  local proto dir f base u key email
  declare -A pos=()
  declare -A has_at=()

  for proto in "${QUOTA_PROTO_DIRS[@]}"; do
    dir="${QUOTA_ROOT}/${proto}"
    [[ -d "${dir}" ]] || continue
    while IFS= read -r -d '' f; do
      base="$(basename "${f}")"
      base="${base%.json}"
      if [[ "${base}" == *"@"* ]]; then
        u="${base%%@*}"
      else
        u="${base}"
      fi

      key="${proto}:${u}"

      # Prefer file "username@proto.json" over compatibility-format "username.json" if both exist.
      if [[ -n "${pos[${key}]:-}" ]]; then
        if [[ "${base}" == *"@"* && "${has_at[${key}]:-0}" != "1" ]]; then
          QUOTA_FILES[${pos[${key}]}]="${f}"
          QUOTA_FILE_PROTOS[${pos[${key}]}]="${proto}"
          has_at["${key}"]=1
        fi
        continue
      fi

      pos["${key}"]="${#QUOTA_FILES[@]}"
      if [[ "${base}" == *"@"* ]]; then
        has_at["${key}"]=1
      else
        has_at["${key}"]=0
      fi

      QUOTA_FILES+=("${f}")
      QUOTA_FILE_PROTOS+=("${proto}")
    done < <(find "${dir}" -maxdepth 1 -type f -name '*.json' -print0 2>/dev/null | sort -z)
  done

  for proto in "${QUOTA_PROTO_DIRS[@]}"; do
    dir="${ACCOUNT_ROOT}/${proto}"
    [[ -d "${dir}" ]] || continue
    while IFS= read -r -d '' f; do
      base="$(basename "${f}")"
      base="${base%.txt}"
      if [[ "${base}" == *"@"* ]]; then
        u="${base%%@*}"
      else
        u="${base}"
      fi
      [[ -n "${u}" ]] || continue

      key="${proto}:${u}"
      if [[ -n "${pos[${key}]:-}" ]]; then
        continue
      fi

      pos["${key}"]="${#QUOTA_FILES[@]}"
      has_at["${key}"]=1
      QUOTA_FILES+=("${QUOTA_ROOT}/${proto}/${u}@${proto}.json}")
      QUOTA_FILE_PROTOS+=("${proto}")
    done < <(find "${dir}" -maxdepth 1 -type f -name '*.txt' -print0 2>/dev/null | sort -z)
  done

  while IFS= read -r email; do
    [[ -n "${email}" && "${email}" == *"@"* ]] || continue
    u="${email%%@*}"
    proto="${email##*@}"
    case "${proto}" in
      vless|vmess|trojan) ;;
      *) continue ;;
    esac

    key="${proto}:${u}"
    if [[ -n "${pos[${key}]:-}" ]]; then
      continue
    fi

    pos["${key}"]="${#QUOTA_FILES[@]}"
    has_at["${key}"]=1
    QUOTA_FILES+=("${QUOTA_ROOT}/${proto}/${u}@${proto}.json}")
    QUOTA_FILE_PROTOS+=("${proto}")
  done < <(xray_inbounds_all_client_emails_get 2>/dev/null || true)
}

quota_metadata_bootstrap_if_missing() {
  # args: proto username quota_file
  local proto="$1"
  local username="$2"
  local qf="$3"
  local acc_file acc_compat

  [[ -n "${proto}" && -n "${username}" && -n "${qf}" ]] || return 1
  [[ -f "${qf}" ]] && return 0

  acc_file="${ACCOUNT_ROOT}/${proto}/${username}@${proto}.txt"
  acc_compat="${ACCOUNT_ROOT}/${proto}/${username}.txt"
  if [[ ! -f "${acc_file}" && -f "${acc_compat}" ]]; then
    acc_file="${acc_compat}"
  fi

  need_python3
  python3 - <<'PY' "${qf}" "${acc_file}" "${proto}" "${username}"
import fcntl
import json
import os
import re
import sys
import tempfile
from datetime import datetime

qf, acc_file, proto, username = sys.argv[1:5]
lock_path = qf + ".lock"

def to_int(value, default=0):
  try:
    if value is None:
      return default
    if isinstance(value, bool):
      return int(value)
    if isinstance(value, (int, float)):
      return int(value)
    raw = str(value).strip()
    if not raw:
      return default
    return int(float(raw))
  except Exception:
    return default

def to_float(value, default=0.0):
  try:
    if value is None:
      return default
    if isinstance(value, bool):
      return float(int(value))
    if isinstance(value, (int, float)):
      return float(value)
    raw = str(value).strip()
    if not raw:
      return default
    return float(raw)
  except Exception:
    return default

def parse_text_fields(path):
  rows = {}
  if not os.path.isfile(path):
    return rows
  try:
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
      for raw in handle:
        line = raw.strip()
        if ":" not in line:
          continue
        key, value = line.split(":", 1)
        rows[key.strip()] = value.strip()
  except Exception:
    return {}
  return rows

def quota_bytes_from_text(raw):
  m = re.search(r"([0-9]+(?:\.[0-9]+)?)", str(raw or ""))
  if not m:
    return 0
  try:
    gb = float(m.group(1))
  except Exception:
    return 0
  if gb <= 0:
    return 0
  return int(round(gb * (1024 ** 3)))

def normalize_date(raw, default="-"):
  s = str(raw or "").strip()
  if not s:
    return default
  m = re.search(r"\d{4}-\d{2}-\d{2}", s)
  if m:
    return m.group(0)
  return default

def parse_ip_limit(raw):
  text = str(raw or "").strip().upper()
  if not text.startswith("ON"):
    return False, 0
  m = re.search(r"\(([0-9]+)\)", text)
  return True, to_int(m.group(1), 0) if m else 0

def parse_speed(raw):
  text = str(raw or "").strip()
  if not text.upper().startswith("ON"):
    return False, 0.0, 0.0
  m = re.search(
    r"DOWN\s*([0-9]+(?:\.[0-9]+)?)\s*Mbps\s*\|\s*UP\s*([0-9]+(?:\.[0-9]+)?)\s*Mbps",
    text,
    flags=re.IGNORECASE,
  )
  if not m:
    return False, 0.0, 0.0
  return True, to_float(m.group(1), 0.0), to_float(m.group(2), 0.0)

fields = parse_text_fields(acc_file)
quota_limit = quota_bytes_from_text(fields.get("Quota Limit"))
expired_at = normalize_date(fields.get("Valid Until"))
created_at = normalize_date(fields.get("Created"), default=datetime.now().strftime("%Y-%m-%d"))
ip_enabled, ip_limit = parse_ip_limit(fields.get("IP Limit"))
speed_enabled, speed_down, speed_up = parse_speed(fields.get("Speed Limit"))
if not speed_enabled or speed_down <= 0 or speed_up <= 0:
  speed_enabled = False
  speed_down = 0.0
  speed_up = 0.0

payload = {
  "username": f"{username}@{proto}",
  "protocol": proto,
  "quota_limit": quota_limit,
  "quota_unit": "binary",
  "quota_used": 0,
  "xray_usage_bytes": 0,
  "xray_api_baseline_bytes": 0,
  "xray_usage_carry_bytes": 0,
  "xray_api_last_total_bytes": 0,
  "xray_usage_reset_pending": False,
  "created_at": created_at,
  "expired_at": expired_at,
  "status": {
    "manual_block": False,
    "quota_exhausted": False,
    "ip_limit_enabled": bool(ip_enabled),
    "ip_limit": ip_limit if ip_enabled else 0,
    "speed_limit_enabled": bool(speed_enabled),
    "speed_down_mbit": speed_down if speed_enabled else 0,
    "speed_up_mbit": speed_up if speed_enabled else 0,
    "ip_limit_locked": False,
    "lock_reason": "",
    "locked_at": "",
  },
}

os.makedirs(os.path.dirname(lock_path) or ".", exist_ok=True)
with open(lock_path, "a+", encoding="utf-8") as lock_handle:
  fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX)
  try:
    if os.path.exists(qf):
      raise SystemExit(0)
    os.makedirs(os.path.dirname(qf) or ".", exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".tmp.", suffix=".json", dir=os.path.dirname(qf) or ".")
    try:
      with os.fdopen(fd, "w", encoding="utf-8") as wf:
        json.dump(payload, wf, ensure_ascii=False, indent=2)
        wf.write("\n")
        wf.flush()
        os.fsync(wf.fileno())
      os.replace(tmp, qf)
      try:
        os.chmod(qf, 0o600)
      except Exception:
        pass
    finally:
      try:
        if os.path.exists(tmp):
          os.remove(tmp)
      except Exception:
        pass
  finally:
    fcntl.flock(lock_handle.fileno(), fcntl.LOCK_UN)
PY
}


quota_total_pages_for_indexes() {
  local total="${#QUOTA_VIEW_INDEXES[@]}"
  if (( total == 0 )); then
    echo 0
    return 0
  fi
  echo $(( (total + QUOTA_PAGE_SIZE - 1) / QUOTA_PAGE_SIZE ))
}

quota_build_view_indexes() {
  # Bangun index view berdasarkan QUOTA_QUERY (case-insensitive, match username/file)
  QUOTA_VIEW_INDEXES=()

  local q
  q="$(echo "${QUOTA_QUERY:-}" | tr '[:upper:]' '[:lower:]')"

  if [[ -z "${q}" ]]; then
    local i
    for i in "${!QUOTA_FILES[@]}"; do
      QUOTA_VIEW_INDEXES+=("${i}")
    done
    return 0
  fi

  local i f proto base u
  for i in "${!QUOTA_FILES[@]}"; do
    f="${QUOTA_FILES[$i]}"
    proto="${QUOTA_FILE_PROTOS[$i]}"
    base="$(basename "${f}")"
    base="${base%.json}"
    if [[ "${base}" == *"@"* ]]; then
      u="${base%%@*}"
    else
      u="${base}"
    fi
    if echo "${u}" | tr '[:upper:]' '[:lower:]' | grep -qF -- "${q}"; then
      QUOTA_VIEW_INDEXES+=("${i}")
      continue
    fi
  done
}

quota_read_summary_fields() {
  # args: json_file
  # prints: username|quota_limit_disp|quota_used_disp|expired_at_date|ip_limit_disp|block_reason|lock_state
  local qf="$1"
  need_python3
  python3 - <<'PY' "${qf}"
import json, pathlib, sys
p=pathlib.Path(sys.argv[1])
username_fallback = p.stem.split("@", 1)[0] if p.stem else "-"
try:
  d=json.load(open(p,'r',encoding='utf-8'))
except Exception:
  print(f"{username_fallback}|0 GB|0 B|-|OFF|-|OFF")
  raise SystemExit(0)
if not isinstance(d, dict):
  print(f"{username_fallback}|0 GB|0 B|-|OFF|-|OFF")
  raise SystemExit(0)

def to_int(v, default=0):
  try:
    if v is None:
      return default
    if isinstance(v, bool):
      return int(v)
    if isinstance(v, (int, float)):
      return int(v)
    s=str(v).strip()
    if s == "":
      return default
    return int(float(s))
  except Exception:
    return default

def fmt_gb(v):
  try:
    n=float(v)
  except Exception:
    n=0.0
  if n < 0:
    n=0.0
  s=f"{n:.3f}".rstrip('0').rstrip('.')
  return s if s else "0"

u=str(d.get("username") or username_fallback or "-")
if u.endswith("@ssh"):
  u=u[:-4]
if "@" in u:
  u=u.split("@", 1)[0]
ql=to_int(d.get("quota_limit"), 0)
qu=to_int(d.get("quota_used"), 0)

# Hormati quota_unit yang tersimpan di file (binary=GiB, decimal=GB)
unit=str(d.get("quota_unit") or "binary").strip().lower()
bpg=1000**3 if unit in ("decimal","gb","1000","gigabyte") else 1024**3
ql_disp=f"{fmt_gb(ql/bpg)} GB"

def used_disp(b):
  try:
    b=int(b)
  except Exception:
    b=0
  if b >= 1024**3:
    return f"{b/(1024**3):.2f} GB"
  if b >= 1024**2:
    return f"{b/(1024**2):.2f} MB"
  if b >= 1024:
    return f"{b/1024:.2f} KB"
  return f"{b} B"

qu_disp=used_disp(qu)

exp=str(d.get("expired_at") or "-")
exp_date=exp[:10] if exp and exp != "-" else "-"

st_raw=d.get("status")
st=st_raw if isinstance(st_raw, dict) else {}
ip_en=bool(st.get("ip_limit_enabled"))
try:
  ip_lim=to_int(st.get("ip_limit"), 0)
except Exception:
  ip_lim=0

ip_str="ON" if ip_en else "OFF"
if ip_en:
  ip_str += f"({ip_lim})" if ip_lim else "(ON)"

lr=str(st.get("lock_reason") or "").strip().lower()
reason="-"
if st.get("manual_block") or lr == "manual":
  reason="MANUAL"
elif st.get("quota_exhausted") or lr == "quota":
  reason="QUOTA"
elif st.get("ip_limit_locked") or lr == "ip_limit":
  reason="IP_LIMIT"

lock_disp="ON" if bool(st.get("account_locked")) else "OFF"
print(f"{u}|{ql_disp}|{qu_disp}|{exp_date}|{ip_str}|{reason}|{lock_disp}")
PY
}

quota_read_detail_fields() {
  # args: json_file
  # prints:
  # username|quota_limit_disp|quota_used_disp|expired_at_date|ip_limit_onoff|ip_limit_value|block_reason|speed_onoff|speed_down_mbit|speed_up_mbit
  local qf="$1"
  need_python3
  python3 - <<'PY' "${qf}"
import json, pathlib, sys
p=pathlib.Path(sys.argv[1])
username_fallback = p.stem.split("@", 1)[0] if p.stem else "-"
try:
  d=json.load(open(p,'r',encoding='utf-8'))
except Exception:
  print(f"{username_fallback}|0 GB|0 B|-|OFF|0|-|OFF|0|0")
  raise SystemExit(0)
if not isinstance(d, dict):
  print(f"{username_fallback}|0 GB|0 B|-|OFF|0|-|OFF|0|0")
  raise SystemExit(0)

def to_int(v, default=0):
  try:
    if v is None:
      return default
    if isinstance(v, bool):
      return int(v)
    if isinstance(v, (int, float)):
      return int(v)
    s=str(v).strip()
    if s == "":
      return default
    return int(float(s))
  except Exception:
    return default

def to_float(v, default=0.0):
  try:
    if v is None:
      return default
    if isinstance(v, bool):
      return float(int(v))
    if isinstance(v, (int, float)):
      return float(v)
    s=str(v).strip()
    if s == "":
      return default
    return float(s)
  except Exception:
    return default

def fmt_gb(v):
  try:
    n=float(v)
  except Exception:
    n=0.0
  if n < 0:
    n=0.0
  s=f"{n:.3f}".rstrip('0').rstrip('.')
  return s if s else "0"

def fmt_mbit(v):
  try:
    n=float(v)
  except Exception:
    n=0.0
  if n < 0:
    n=0.0
  s=f"{n:.3f}".rstrip('0').rstrip('.')
  return s if s else "0"

u=str(d.get("username") or username_fallback or "-")
if u.endswith("@ssh"):
  u=u[:-4]
if "@" in u:
  u=u.split("@", 1)[0]
ql=to_int(d.get("quota_limit"), 0)
qu=to_int(d.get("quota_used"), 0)

# Hormati quota_unit yang tersimpan di file
unit=str(d.get("quota_unit") or "binary").strip().lower()
bpg=1000**3 if unit in ("decimal","gb","1000","gigabyte") else 1024**3
ql_disp=f"{fmt_gb(ql/bpg)} GB"

def used_disp(b):
  try:
    b=int(b)
  except Exception:
    b=0
  if b >= 1024**3:
    return f"{b/(1024**3):.2f} GB"
  if b >= 1024**2:
    return f"{b/(1024**2):.2f} MB"
  if b >= 1024:
    return f"{b/1024:.2f} KB"
  return f"{b} B"

qu_disp=used_disp(qu)

exp=str(d.get("expired_at") or "-")
exp_date=exp[:10] if exp and exp != "-" else "-"

st_raw=d.get("status")
st=st_raw if isinstance(st_raw, dict) else {}
ip_en=bool(st.get("ip_limit_enabled"))
try:
  ip_lim=to_int(st.get("ip_limit"), 0)
except Exception:
  ip_lim=0
if ip_lim < 0:
  ip_lim = 0
lr=str(st.get("lock_reason") or "").strip().lower()
reason="-"
if st.get("manual_block") or lr == "manual":
  reason="MANUAL"
elif st.get("quota_exhausted") or lr == "quota":
  reason="QUOTA"
elif st.get("ip_limit_locked") or lr == "ip_limit":
  reason="IP_LIMIT"

speed_en=bool(st.get("speed_limit_enabled"))
speed_down=to_float(st.get("speed_down_mbit"), 0.0)
speed_up=to_float(st.get("speed_up_mbit"), 0.0)
if speed_down < 0:
  speed_down = 0.0
if speed_up < 0:
  speed_up = 0.0

print(f"{u}|{ql_disp}|{qu_disp}|{exp_date}|{'ON' if ip_en else 'OFF'}|{ip_lim}|{reason}|{'ON' if speed_en else 'OFF'}|{fmt_mbit(speed_down)}|{fmt_mbit(speed_up)}")
PY
}

quota_get_status_bool() {
  # args: json_file key
  local qf="$1"
  local key="$2"
  need_python3
  python3 - <<'PY' "${qf}" "${key}"
import json, sys
p, k = sys.argv[1:3]
try:
  d = json.load(open(p, 'r', encoding='utf-8'))
except Exception:
  print("false")
  raise SystemExit(0)
if not isinstance(d, dict):
  print("false")
  raise SystemExit(0)
st = d.get("status") or {}
if not isinstance(st, dict):
  st = {}
v = st.get(k, False)
print("true" if bool(v) else "false")
PY
}

quota_get_status_int() {
  # args: json_file key
  local qf="$1"
  local key="$2"
  need_python3
  python3 - <<'PY' "${qf}" "${key}"
import json, sys
p, k = sys.argv[1:3]
try:
  d = json.load(open(p, 'r', encoding='utf-8'))
except Exception:
  print("0")
  raise SystemExit(0)
if not isinstance(d, dict):
  print("0")
  raise SystemExit(0)
st = d.get("status") or {}
if not isinstance(st, dict):
  st = {}
v = st.get(k, 0)
try:
  print(int(v))
except Exception:
  print("0")
PY
}

quota_get_status_number() {
  # args: json_file key
  local qf="$1"
  local key="$2"
  need_python3
  python3 - <<'PY' "${qf}" "${key}"
import json, sys
p, k = sys.argv[1:3]
try:
  d = json.load(open(p, 'r', encoding='utf-8'))
except Exception:
  print("0")
  raise SystemExit(0)
if not isinstance(d, dict):
  print("0")
  raise SystemExit(0)
st = d.get("status") or {}
if not isinstance(st, dict):
  st = {}
v = st.get(k, 0)
try:
  n = float(v)
except Exception:
  n = 0.0
if n < 0:
  n = 0.0
s = f"{n:.3f}".rstrip("0").rstrip(".")
print(s if s else "0")
PY
}

quota_get_lock_reason() {
  # args: json_file
  local qf="$1"
  need_python3
  python3 - <<'PY' "${qf}"
import json, sys
p = sys.argv[1]
try:
  d = json.load(open(p, 'r', encoding='utf-8'))
except Exception:
  print("")
  raise SystemExit(0)
if not isinstance(d, dict):
  print("")
  raise SystemExit(0)
st = d.get("status") or {}
if not isinstance(st, dict):
  st = {}
v = st.get("lock_reason") or ""
print(str(v))
PY
}

quota_sync_speed_policy_for_user() {
  # args: proto username quota_file
  local proto="$1"
  local username="$2"
  local qf="$3"

  local speed_on speed_down speed_up mark
  speed_on="$(quota_get_status_bool "${qf}" "speed_limit_enabled")"
  speed_down="$(quota_get_status_number "${qf}" "speed_down_mbit")"
  speed_up="$(quota_get_status_number "${qf}" "speed_up_mbit")"

  if [[ "${speed_on}" == "true" ]]; then
    if ! speed_mbit_is_positive "${speed_down}" || ! speed_mbit_is_positive "${speed_up}"; then
      warn "Speed limit aktif, tapi nilai download/upload belum valid (> 0)."
      return 1
    fi
    if ! mark="$(speed_policy_upsert "${proto}" "${username}" "${speed_down}" "${speed_up}")"; then
      warn "Gagal menyimpan speed policy ${username}@${proto}"
      return 1
    fi
    if ! speed_policy_sync_xray; then
      warn "Gagal sinkronisasi speed policy ke xray"
      return 1
    fi
    if ! speed_policy_apply_now; then
      warn "Speed policy tersimpan, tetapi apply runtime gagal (cek service xray-speed)"
      return 1
    fi
    log "Speed policy aktif untuk ${username}@${proto} (mark=${mark}, down=${speed_down}Mbps, up=${speed_up}Mbps)"
    return 0
  fi

  if speed_policy_exists "${proto}" "${username}"; then
    if ! speed_policy_remove_checked "${proto}" "${username}"; then
      warn "Speed limit dinonaktifkan, tetapi file speed policy gagal dihapus"
      return 1
    fi
    if ! speed_policy_sync_xray; then
      warn "Speed limit dinonaktifkan, tetapi sinkronisasi speed policy ke xray gagal"
      return 1
    fi
    if ! speed_policy_apply_now; then
      warn "Speed limit dinonaktifkan, tetapi apply runtime gagal (cek service xray-speed)"
      return 1
    fi
    return 0
  fi
  if ! speed_policy_apply_now; then
    warn "Speed policy runtime gagal di-refresh (cek service xray-speed)"
    return 1
  fi
  return 0
}



quota_print_table_page() {
  # args: page
  local page="${1:-0}"
  local total="${#QUOTA_VIEW_INDEXES[@]}"
  local pages
  pages="$(quota_total_pages_for_indexes)"

  if (( total == 0 )); then
    echo "Xray accounts: 0 | page 1/1"
    if [[ -n "${QUOTA_QUERY}" ]]; then
      echo "Filter: '${QUOTA_QUERY}'"
    fi
    echo
    echo "Belum ada data Xray QAC."
    return 0
  fi

  if (( page < 0 )); then page=0; fi
  if (( pages > 0 && page >= pages )); then page=$((pages - 1)); fi

  local display_pages=1
  if (( pages > 0 )); then
    display_pages="${pages}"
  fi
  echo "Xray accounts: ${total} | page $((page + 1))/${display_pages}"
  if [[ -n "${QUOTA_QUERY}" ]]; then
    echo "Filter: '${QUOTA_QUERY}'"
  fi
  echo

  local start end i real_idx f proto fields username ql_disp qu_disp exp_date ip_disp block_reason lock_state
  start=$((page * QUOTA_PAGE_SIZE))
  end=$((start + QUOTA_PAGE_SIZE))
  if (( end > total )); then end="${total}"; fi

  printf "%-4s %-8s %-18s %-11s %-11s %-12s %-10s %-6s\n" "NO" "Proto" "Username" "Quota" "Used" "Expired" "IPLimit" "Lock"
  hr

  for (( i=start; i<end; i++ )); do
    real_idx="${QUOTA_VIEW_INDEXES[$i]}"
    f="${QUOTA_FILES[$real_idx]}"
    proto="${QUOTA_FILE_PROTOS[$real_idx]}"

    fields="$(quota_read_summary_fields "${f}")"
    IFS='|' read -r username ql_disp qu_disp exp_date ip_disp block_reason lock_state <<<"${fields}"
    printf "%-4s %-8s %-18s %-11s %-11s %-12s %-10s %-6s\n" \
      "$((i - start + 1))" \
      "${proto}" \
      "${username}" \
      "${ql_disp}" \
      "${qu_disp}" \
      "${exp_date}" \
      "${ip_disp}" \
      "${lock_state}"

  done

  echo
  echo "Halaman: $((page + 1))/${pages}  | Total metadata: ${total}"
  if (( pages > 1 )); then
    echo "Ketik: next / previous / search / clear / kembali"
  fi
}

quota_atomic_update_file() {
  # args: json_file action [action_args...]
  # Security hardening:
  # - Tidak lagi menjalankan python `exec()` dari string dinamis.
  # - Update dibatasi ke action yang sudah di-whitelist.
  local qf="$1"
  local action="${2:-}"
  local lockf="${qf}.lock"
  shift 2 || true
  need_python3

  python3 - "${qf}" "${lockf}" "${action}" "$@" <<'PY'
import fcntl
import json
import os
import re
import shutil
import sys
import tempfile
from datetime import datetime

p = sys.argv[1]
lock_path = sys.argv[2]
action = sys.argv[3]
args = sys.argv[4:]
backup_path = str(os.environ.get("QUOTA_ATOMIC_BACKUP_FILE") or "").strip()

os.makedirs(os.path.dirname(lock_path) or ".", exist_ok=True)

def now_iso():
  return datetime.now().strftime("%Y-%m-%d %H:%M")

def parse_onoff(raw):
  v = str(raw or "").strip().lower()
  if v in ("on", "true", "1", "yes"):
    return True
  if v in ("off", "false", "0", "no"):
    return False
  raise SystemExit(f"aksi {action}: nilai on/off tidak valid: {raw}")

def parse_int(raw, name, min_value=None):
  try:
    val = int(float(str(raw).strip()))
  except Exception:
    raise SystemExit(f"aksi {action}: {name} harus angka")
  if min_value is not None and val < min_value:
    raise SystemExit(f"aksi {action}: {name} minimal {min_value}")
  return val

def parse_float(raw, name, min_value=None):
  try:
    val = float(str(raw).strip())
  except Exception:
    raise SystemExit(f"aksi {action}: {name} harus angka")
  if min_value is not None and val < min_value:
    raise SystemExit(f"aksi {action}: {name} minimal {min_value}")
  return val

def ensure_status(meta):
  st = meta.get("status")
  if not isinstance(st, dict):
    st = {}
    meta["status"] = st
  return st

def recompute_lock_reason(st):
  mb = bool(st.get("manual_block"))
  qe = bool(st.get("quota_exhausted"))
  il = bool(st.get("ip_limit_locked"))

  if mb:
    lr = "manual"
  elif qe:
    lr = "quota"
  elif il:
    lr = "ip_limit"
  else:
    lr = ""

  st["lock_reason"] = lr
  if lr:
    st["locked_at"] = str(st.get("locked_at") or now_iso())
  else:
    st["locked_at"] = ""

with open(lock_path, "a+", encoding="utf-8") as lf:
  fcntl.flock(lf.fileno(), fcntl.LOCK_EX)
  try:
    if backup_path:
      os.makedirs(os.path.dirname(backup_path) or ".", exist_ok=True)
      shutil.copy2(p, backup_path)
      try:
        os.chmod(backup_path, 0o600)
      except Exception:
        pass
    with open(p, "r", encoding="utf-8") as f:
      d = json.load(f)
    if not isinstance(d, dict):
      raise SystemExit("quota metadata invalid: root bukan object")

    st = ensure_status(d)

    if action == "set_expired_at":
      if len(args) != 1:
        raise SystemExit("set_expired_at butuh 1 argumen (YYYY-MM-DD)")
      value = str(args[0]).strip()
      if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", value):
        raise SystemExit("set_expired_at: format tanggal wajib YYYY-MM-DD")
      d["expired_at"] = value

    elif action == "clear_quota_exhausted_recompute":
      st["quota_exhausted"] = False
      recompute_lock_reason(st)

    elif action == "set_quota_limit_recompute":
      if len(args) != 1:
        raise SystemExit("set_quota_limit_recompute butuh 1 argumen (bytes)")
      d["quota_limit"] = parse_int(args[0], "quota_limit", 0)
      recompute_lock_reason(st)

    elif action == "reset_quota_used_recompute":
      d["quota_used"] = 0
      d["xray_usage_bytes"] = 0
      d["xray_api_last_total_bytes"] = 0
      d["xray_usage_carry_bytes"] = 0
      d["xray_usage_reset_pending"] = True
      st["quota_exhausted"] = False
      recompute_lock_reason(st)

    elif action == "manual_block_set":
      if len(args) != 1:
        raise SystemExit("manual_block_set butuh 1 argumen (on/off)")
      enabled = parse_onoff(args[0])
      st["manual_block"] = bool(enabled)
      if enabled:
        st["lock_reason"] = "manual"
        st["locked_at"] = str(st.get("locked_at") or now_iso())
      else:
        recompute_lock_reason(st)

    elif action == "ip_limit_enabled_set":
      if len(args) != 1:
        raise SystemExit("ip_limit_enabled_set butuh 1 argumen (on/off)")
      enabled = parse_onoff(args[0])
      st["ip_limit_enabled"] = bool(enabled)
      if not enabled:
        st["ip_limit_locked"] = False
        recompute_lock_reason(st)

    elif action == "set_ip_limit":
      if len(args) != 1:
        raise SystemExit("set_ip_limit butuh 1 argumen (angka)")
      st["ip_limit"] = parse_int(args[0], "ip_limit", 1)

    elif action == "clear_ip_limit_locked_recompute":
      st["ip_limit_locked"] = False
      recompute_lock_reason(st)

    elif action == "set_speed_down":
      if len(args) != 1:
        raise SystemExit("set_speed_down butuh 1 argumen (Mbps)")
      st["speed_down_mbit"] = parse_float(args[0], "speed_down_mbit", 0.000001)

    elif action == "set_speed_up":
      if len(args) != 1:
        raise SystemExit("set_speed_up butuh 1 argumen (Mbps)")
      st["speed_up_mbit"] = parse_float(args[0], "speed_up_mbit", 0.000001)

    elif action == "speed_limit_set":
      if len(args) != 1:
        raise SystemExit("speed_limit_set butuh 1 argumen (on/off)")
      st["speed_limit_enabled"] = bool(parse_onoff(args[0]))

    elif action == "set_speed_all_enable":
      if len(args) != 2:
        raise SystemExit("set_speed_all_enable butuh 2 argumen (down up)")
      st["speed_down_mbit"] = parse_float(args[0], "speed_down_mbit", 0.000001)
      st["speed_up_mbit"] = parse_float(args[1], "speed_up_mbit", 0.000001)
      st["speed_limit_enabled"] = True

    else:
      raise SystemExit(f"aksi quota_atomic_update_file tidak dikenali: {action}")

    out = json.dumps(d, ensure_ascii=False, indent=2) + "\n"
    dirn = os.path.dirname(p) or "."
    fd, tmp = tempfile.mkstemp(prefix=".tmp.", suffix=".json", dir=dirn)
    try:
      with os.fdopen(fd, "w", encoding="utf-8") as wf:
        wf.write(out)
        wf.flush()
        os.fsync(wf.fileno())
      os.replace(tmp, p)
    finally:
      try:
        if os.path.exists(tmp):
          os.remove(tmp)
      except Exception:
        pass
  finally:
    fcntl.flock(lf.fileno(), fcntl.LOCK_UN)
PY
  local py_rc=$?
  if (( py_rc != 0 )); then
    return "${py_rc}"
  fi

  chmod 600 "${qf}" 2>/dev/null || true
  QUOTA_FIELDS_CACHE=()
  return 0
}

quota_view_json() {
  local qf="$1"
  title
  echo "Quota metadata: ${qf}"
  hr
  if [[ ! -f "${qf}" ]]; then
    warn "Quota metadata belum ada untuk target ini."
    echo "Hint: target ini kemungkinan terdeteksi dari runtime/account file drift dan belum punya JSON quota."
    hr
    pause
    return 0
  fi
  need_python3
  if have_cmd less; then
    python3 - <<'PY' "${qf}" | less -R
import json, sys
p=sys.argv[1]
try:
  d=json.load(open(p,'r',encoding='utf-8'))
except Exception:
  print(open(p,'r',encoding='utf-8',errors='replace').read())
  raise SystemExit(0)
exp=d.get("expired_at")
if isinstance(exp, str) and exp:
  d["expired_at"]=exp[:10]
crt=d.get("created_at")
if isinstance(crt, str) and crt:
  s=crt.replace("T"," ").strip()
  if s.endswith("Z"):
    s=s[:-1]
  if len(s)>=10 and s[4:5]=="-" and s[7:8]=="-":
    d["created_at"]=s[:10]
  else:
    d["created_at"]=s
print(json.dumps(d, ensure_ascii=False, indent=2))
PY
  else
    python3 - <<'PY' "${qf}"
import json, sys
p=sys.argv[1]
try:
  d=json.load(open(p,'r',encoding='utf-8'))
except Exception:
  print(open(p,'r',encoding='utf-8',errors='replace').read())
  raise SystemExit(0)
exp=d.get("expired_at")
if isinstance(exp, str) and exp:
  d["expired_at"]=exp[:10]
crt=d.get("created_at")
if isinstance(crt, str) and crt:
  s=crt.replace("T"," ").strip()
  if s.endswith("Z"):
    s=s[:-1]
  if len(s)>=10 and s[4:5]=="-" and s[7:8]=="-":
    d["created_at"]=s[:10]
  else:
    d["created_at"]=s
print(json.dumps(d, ensure_ascii=False, indent=2))
PY
  fi
  hr
  pause
}

quota_edit_flow() {
  # args: view_no (1-based pada halaman aktif)
  local view_no="$1"

  [[ "${view_no}" =~ ^[0-9]+$ ]] || { warn "Input bukan angka"; pause; return 0; }
  local total page pages start end rows
  total="${#QUOTA_VIEW_INDEXES[@]}"
  if (( total <= 0 )); then
    warn "Tidak ada data"
    pause
    return 0
  fi
  page="${QUOTA_PAGE:-0}"
  pages=$(( (total + QUOTA_PAGE_SIZE - 1) / QUOTA_PAGE_SIZE ))
  if (( page < 0 )); then page=0; fi
  if (( pages > 0 && page >= pages )); then page=$((pages - 1)); fi
  start=$((page * QUOTA_PAGE_SIZE))
  end=$((start + QUOTA_PAGE_SIZE))
  if (( end > total )); then end="${total}"; fi
  rows=$((end - start))

  if (( view_no < 1 || view_no > rows )); then
    warn "NO di luar range"
    pause
    return 0
  fi

  local list_pos real_idx qf proto
  list_pos=$((start + view_no - 1))
  real_idx="${QUOTA_VIEW_INDEXES[$list_pos]}"
  qf="${QUOTA_FILES[$real_idx]}"
  proto="${QUOTA_FILE_PROTOS[$real_idx]}"
  local qf_base username_hint=""
  qf_base="$(basename "${qf}")"
  qf_base="${qf_base%.json}"
  username_hint="${qf_base%%@*}"

  if [[ ! -f "${qf}" ]]; then
    warn "Quota metadata untuk ${username_hint}@${proto} belum ada."
    echo "Bootstrap akan membuat metadata awal dengan asumsi konservatif:"
    echo "  - quota used = 0"
    echo "  - xray usage/baseline = 0"
    echo "  - created/expired/ip-limit/speed dicoba dibaca dari account info bila tersedia"
    hr
    if ! confirm_menu_apply_now "Buat metadata quota awal untuk ${username_hint}@${proto} sekarang?"; then
      pause
      return 0
    fi
    if ! quota_metadata_bootstrap_if_missing "${proto}" "${username_hint}" "${qf}"; then
      warn "Gagal membuat metadata quota awal untuk ${username_hint}@${proto}."
      pause
      return 1
    fi
  fi

  while true; do
    title
    echo "Xray QAC > Detail"
    hr
    echo "Proto : ${proto}"
    echo "File  : ${qf}"
    hr

    local fields username ql_disp qu_disp exp_date ip_state ip_lim block_reason speed_state speed_down speed_up
    fields="$(quota_read_detail_fields "${qf}")"
    IFS='|' read -r username ql_disp qu_disp exp_date ip_state ip_lim block_reason speed_state speed_down speed_up <<<"${fields}"

    # Normalisasi username ke format email (username@proto) untuk routing calls.
    # Metadata historis mungkin hanya menyimpan "alice", bukan "alice@vless".
    local email_for_routing="${username}"
    if [[ "${email_for_routing}" != *"@"* ]]; then
      email_for_routing="${email_for_routing}@${proto}"
    fi
    local speed_username="${username}"
    if [[ "${speed_username}" == *"@"* ]]; then
      speed_username="${speed_username%%@*}"
    fi

    local label_w=14
    printf "%-${label_w}s : %s\n" "Username" "${username}"
    printf "%-${label_w}s : %s\n" "Quota Limit" "${ql_disp}"
    printf "%-${label_w}s : %s\n" "Quota Used" "${qu_disp}"
    printf "%-${label_w}s : %s\n" "Expired At" "${exp_date}"
    printf "%-${label_w}s : %s\n" "IP Limit" "${ip_state}"
    printf "%-${label_w}s : %s\n" "Block Reason" "${block_reason}"
    printf "%-${label_w}s : %s\n" "IP Limit Max" "${ip_lim}"
    printf "%-${label_w}s : %s Mbps\n" "Speed Download" "${speed_down}"
    printf "%-${label_w}s : %s Mbps\n" "Speed Upload" "${speed_up}"
    printf "%-${label_w}s : %s\n" "Speed Limit" "${speed_state}"
    hr

    echo "  1) View JSON"
    echo "  2) Set Quota (GB)"
    echo "  3) Reset Quota"
    echo "  4) Toggle Block"
    echo "  5) Toggle IP Limit"
    echo "  6) Set IP Limit"
    echo "  7) Unlock IP"
    echo "  8) Set Speed Download"
    echo "  9) Set Speed Upload"
    echo " 10) Toggle Speed Limit"
    echo "  0) Back"
    hr
    if ! read -r -p "Pilih: " c; then
      echo
      break
    fi
    if is_back_choice "${c}"; then
      return 0
    fi

    case "${c}" in
      1)
        quota_view_json "${qf}"
        ;;
      2)
        if ! read -r -p "Quota Limit (GB) (atau kembali): " gb; then
          echo
          return 0
        fi
        if is_back_choice "${gb}"; then
          continue
        fi
        if [[ -z "${gb}" ]]; then
          warn "Quota kosong"
          pause
          continue
        fi
        local gb_num qb
        gb_num="$(normalize_gb_input "${gb}")"
        if [[ -z "${gb_num}" ]]; then
          warn "Format quota tidak valid. Contoh: 5 atau 5GB"
          pause
          continue
        fi
        qb="$(bytes_from_gb "${gb_num}")"
        if ! confirm_menu_apply_now "Set quota limit ${username} ke ${gb_num} GB sekarang?"; then
          pause
          continue
        fi
        local apply_msg=""
        if ! apply_msg="$(xray_qac_atomic_apply "${qf}" "${proto}" "${speed_username}" "${email_for_routing}" false false set_quota_limit_recompute "${qb}")"; then
          warn "Quota limit gagal diterapkan: ${apply_msg}"
          pause
          continue
        fi
        log "Quota limit diubah: ${gb_num} GB"
        pause
        ;;
      3)
        # BUG-06 fix: read mb/il BEFORE resetting qe so lock_reason is computed correctly.
        # BUG-05 fix: correct priority quota > ip_limit.
        if ! confirm_menu_apply_now "Reset quota used ${username} ke 0 sekarang?"; then
          pause
          continue
        fi
        local apply_msg=""
        if ! apply_msg="$(xray_qac_atomic_apply "${qf}" "${proto}" "${speed_username}" "${email_for_routing}" false false reset_quota_used_recompute)"; then
          warn "Reset quota gagal diterapkan: ${apply_msg}"
          pause
          continue
        fi
        log "Quota used di-reset: 0 (status quota dibersihkan)"
        pause
        ;;
      4)
        local st_mb
        st_mb="$(quota_get_status_bool "${qf}" "manual_block")"
        if [[ "${st_mb}" == "true" ]]; then
          if ! confirm_menu_apply_now "Nonaktifkan manual block untuk ${username} sekarang?"; then
            pause
            continue
          fi
          # BUG-06 fix: evaluate qe/il BEFORE setting manual_block=False.
          # Previously mb was read AFTER being set to False, so it was always False
          # and lock_reason could never be 'manual' in this branch.
          # BUG-05 fix applied here too: correct priority is quota > ip_limit (not reversed).
          local apply_msg=""
          if ! apply_msg="$(xray_qac_atomic_apply "${qf}" "${proto}" "${speed_username}" "${email_for_routing}" false false manual_block_set off)"; then
            warn "Manual block OFF gagal diterapkan: ${apply_msg}"
            pause
            continue
          fi
          log "Manual block: OFF"
        else
          if ! confirm_menu_apply_now "Aktifkan manual block untuk ${username} sekarang?"; then
            pause
            continue
          fi
          local apply_msg=""
          if ! apply_msg="$(xray_qac_atomic_apply "${qf}" "${proto}" "${speed_username}" "${email_for_routing}" false false manual_block_set on)"; then
            warn "Manual block ON gagal diterapkan: ${apply_msg}"
            pause
            continue
          fi
          log "Manual block: ON"
        fi
        pause
        ;;
      5)
        local ip_on
        ip_on="$(quota_get_status_bool "${qf}" "ip_limit_enabled")"
        if [[ "${ip_on}" == "true" ]]; then
          if ! confirm_menu_apply_now "Nonaktifkan IP limit untuk ${username} sekarang?"; then
            pause
            continue
          fi
          # BUG-06 fix: read il BEFORE resetting ip_limit_locked, then determine lock_reason.
          # BUG-05 fix: correct priority is quota > ip_limit.
          local apply_msg=""
          if ! apply_msg="$(xray_qac_atomic_apply "${qf}" "${proto}" "${speed_username}" "${email_for_routing}" true false ip_limit_enabled_set off)"; then
            warn "IP limit OFF gagal diterapkan: ${apply_msg}"
            pause
            continue
          fi
          log "IP limit: OFF"
        else
          if ! confirm_menu_apply_now "Aktifkan IP limit untuk ${username} sekarang?"; then
            pause
            continue
          fi
          local apply_msg=""
          if ! apply_msg="$(xray_qac_atomic_apply "${qf}" "${proto}" "${speed_username}" "${email_for_routing}" true false ip_limit_enabled_set on)"; then
            warn "IP limit ON gagal diterapkan: ${apply_msg}"
            pause
            continue
          fi
          log "IP limit: ON"
        fi
        pause
        ;;
      6)
        if ! read -r -p "IP Limit (angka) (atau kembali): " lim; then
          echo
          return 0
        fi
        if is_back_word_choice "${lim}"; then
          continue
        fi
        if [[ -z "${lim}" || ! "${lim}" =~ ^[0-9]+$ || "${lim}" -le 0 ]]; then
          warn "IP limit harus angka > 0"
          pause
          continue
        fi
        if ! confirm_menu_apply_now "Set IP limit ${username} ke ${lim} sekarang?"; then
          pause
          continue
        fi
        local apply_msg=""
        if ! apply_msg="$(xray_qac_atomic_apply "${qf}" "${proto}" "${speed_username}" "${email_for_routing}" true false set_ip_limit "${lim}")"; then
          warn "Set IP limit gagal diterapkan: ${apply_msg}"
          pause
          continue
        fi
        log "IP limit diubah: ${lim}"
        pause
        ;;
      7)
        if ! confirm_menu_apply_now "Unlock IP lock untuk ${username} sekarang?"; then
          pause
          continue
        fi
        local apply_msg=""
        if ! apply_msg="$(xray_qac_unlock_ip_atomic_apply "${qf}" "${proto}" "${speed_username}" "${email_for_routing}")"; then
          warn "Unlock IP lock gagal diterapkan: ${apply_msg}"
          pause
          continue
        fi
        log "IP lock di-unlock"
        pause
        ;;
      8)
        if ! read -r -p "Speed Download (Mbps) (contoh: 20 atau 20mbit) (atau kembali): " speed_down_input; then
          echo
          return 0
        fi
        if is_back_word_choice "${speed_down_input}"; then
          continue
        fi
        speed_down_input="$(normalize_speed_mbit_input "${speed_down_input}")"
        if [[ -z "${speed_down_input}" ]] || ! speed_mbit_is_positive "${speed_down_input}"; then
          warn "Speed download tidak valid. Gunakan angka > 0, contoh: 20 atau 20mbit"
          pause
          continue
        fi
        if ! confirm_menu_apply_now "Set speed download ${username} ke ${speed_down_input} Mbps sekarang?"; then
          pause
          continue
        fi
        local apply_msg=""
        if ! apply_msg="$(xray_qac_atomic_apply "${qf}" "${proto}" "${speed_username}" "${email_for_routing}" false true set_speed_down "${speed_down_input}")"; then
          warn "Speed download gagal diterapkan: ${apply_msg}"
          pause
          continue
        fi
        log "Speed download diubah: ${speed_down_input} Mbps"
        pause
        ;;
      9)
        if ! read -r -p "Speed Upload (Mbps) (contoh: 10 atau 10mbit) (atau kembali): " speed_up_input; then
          echo
          return 0
        fi
        if is_back_word_choice "${speed_up_input}"; then
          continue
        fi
        speed_up_input="$(normalize_speed_mbit_input "${speed_up_input}")"
        if [[ -z "${speed_up_input}" ]] || ! speed_mbit_is_positive "${speed_up_input}"; then
          warn "Speed upload tidak valid. Gunakan angka > 0, contoh: 10 atau 10mbit"
          pause
          continue
        fi
        if ! confirm_menu_apply_now "Set speed upload ${username} ke ${speed_up_input} Mbps sekarang?"; then
          pause
          continue
        fi
        local apply_msg=""
        if ! apply_msg="$(xray_qac_atomic_apply "${qf}" "${proto}" "${speed_username}" "${email_for_routing}" false true set_speed_up "${speed_up_input}")"; then
          warn "Speed upload gagal diterapkan: ${apply_msg}"
          pause
          continue
        fi
        log "Speed upload diubah: ${speed_up_input} Mbps"
        pause
        ;;
      10)
        local speed_on speed_down_now speed_up_now
        speed_on="$(quota_get_status_bool "${qf}" "speed_limit_enabled")"
        if [[ "${speed_on}" == "true" ]]; then
          if ! confirm_menu_apply_now "Nonaktifkan speed limit untuk ${username} sekarang?"; then
            pause
            continue
          fi
          local apply_msg=""
          if ! apply_msg="$(xray_qac_atomic_apply "${qf}" "${proto}" "${speed_username}" "${email_for_routing}" false true speed_limit_set off)"; then
            warn "Speed limit OFF gagal diterapkan: ${apply_msg}"
            pause
            continue
          fi
          log "Speed limit: OFF"
          pause
          continue
        fi

        speed_down_now="$(quota_get_status_number "${qf}" "speed_down_mbit")"
        speed_up_now="$(quota_get_status_number "${qf}" "speed_up_mbit")"

        if ! speed_mbit_is_positive "${speed_down_now}"; then
          if ! read -r -p "Speed Download (Mbps) (contoh: 20 atau 20mbit) (atau kembali): " speed_down_now; then
            echo
            return 0
          fi
          if is_back_choice "${speed_down_now}"; then
            continue
          fi
          speed_down_now="$(normalize_speed_mbit_input "${speed_down_now}")"
          if [[ -z "${speed_down_now}" ]] || ! speed_mbit_is_positive "${speed_down_now}"; then
            warn "Speed download tidak valid. Speed limit tetap OFF."
            pause
            continue
          fi
        fi
        if ! speed_mbit_is_positive "${speed_up_now}"; then
          if ! read -r -p "Speed Upload (Mbps) (contoh: 10 atau 10mbit) (atau kembali): " speed_up_now; then
            echo
            return 0
          fi
          if is_back_choice "${speed_up_now}"; then
            continue
          fi
          speed_up_now="$(normalize_speed_mbit_input "${speed_up_now}")"
          if [[ -z "${speed_up_now}" ]] || ! speed_mbit_is_positive "${speed_up_now}"; then
            warn "Speed upload tidak valid. Speed limit tetap OFF."
            pause
            continue
          fi
        fi

        if ! confirm_menu_apply_now "Aktifkan speed limit ${username} dengan DOWN ${speed_down_now} Mbps dan UP ${speed_up_now} Mbps sekarang?"; then
          pause
          continue
        fi
        local apply_msg=""
        if ! apply_msg="$(xray_qac_atomic_apply "${qf}" "${proto}" "${speed_username}" "${email_for_routing}" false true set_speed_all_enable "${speed_down_now}" "${speed_up_now}")"; then
          warn "Speed limit ON gagal diterapkan: ${apply_msg}"
          pause
          continue
        fi
        log "Speed limit: ON"
        pause
        ;;
      *)
        warn "Pilihan tidak valid"
        sleep 1
        ;;
    esac
  done
}

quota_menu() {
  # Minimal: list + search + pagination + view/edit metadata JSON
  ensure_account_quota_dirs
  need_python3

  QUOTA_PAGE=0
  QUOTA_QUERY=""

  while true; do
    ui_menu_screen_begin "4) Xray QAC"

    quota_collect_files
    quota_build_view_indexes
    quota_print_table_page "${QUOTA_PAGE}"
    hr

    echo "Masukkan NO untuk view/edit, atau ketik:"
    echo "  search) filter username"
    echo "  clear) hapus filter"
    echo "  next / previous"
    hr
    if ! read -r -p "Pilih: " c; then
      echo
      break
    fi

    if is_back_choice "${c}"; then
      break
    fi

    case "${c}" in
      next|n)
        local pages
        pages="$(quota_total_pages_for_indexes)"
        if (( pages > 0 && QUOTA_PAGE < pages - 1 )); then
          QUOTA_PAGE=$((QUOTA_PAGE + 1))
        fi
        ;;
      previous|p|prev)
        if (( QUOTA_PAGE > 0 )); then
          QUOTA_PAGE=$((QUOTA_PAGE - 1))
        fi
        ;;
      search)
        if ! read -r -p "Search username (atau kembali): " q; then
          echo
          break
        fi
        if is_back_choice "${q}"; then
          continue
        fi
        QUOTA_QUERY="${q}"
        QUOTA_PAGE=0
        ;;
      clear)
        QUOTA_QUERY=""
        QUOTA_PAGE=0
        ;;
      *)
        if [[ "${c}" =~ ^[0-9]+$ ]]; then
          quota_edit_flow "${c}"
        else
          warn "Pilihan tidak valid"
          sleep 1
        fi
        ;;
    esac
  done
}

# -------------------------

# -------------------------
# Modular load (stage-1 split)
# -------------------------
MANAGE_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
MANAGE_REQUIRED_MODULES=(
  "features/network.sh"
  "features/analytics.sh"
  "menus/maintenance_menu.sh"
  "menus/main_menu.sh"
  "app/main.sh"
)

manage_modules_dir_trusted() {
  local dir="$1"
  [[ -d "${dir}" ]] || return 1

  # Untuk non-root, fallback ke path yang ada.
  if [[ "$(id -u)" -ne 0 ]]; then
    return 0
  fi

  local owner mode
  owner="$(stat -c '%u' "${dir}" 2>/dev/null || echo 1)"
  mode="$(stat -c '%A' "${dir}" 2>/dev/null || echo '----------')"

  # Saat root, hanya izinkan dir modul yang dimiliki root dan tidak writable oleh group/other.
  [[ "${owner}" == "0" ]] || return 1
  [[ "${mode:5:1}" != "w" && "${mode:8:1}" != "w" ]] || return 1
  return 0
}

manage_module_file_trusted() {
  local file="$1"
  local modules_dir="${2:-${MANAGE_MODULES_DIR:-}}"
  [[ -n "${modules_dir}" ]] || return 1
  [[ -f "${file}" && -r "${file}" ]] || return 1

  local modules_real file_real
  modules_real="$(readlink -f -- "${modules_dir}" 2>/dev/null || true)"
  file_real="$(readlink -f -- "${file}" 2>/dev/null || true)"
  [[ -n "${modules_real}" && -n "${file_real}" ]] || return 1
  [[ "${file_real}" == "${modules_real}/"* ]] || return 1

  # Untuk non-root, cukup validasi keberadaan & canonical path.
  if [[ "$(id -u)" -ne 0 ]]; then
    return 0
  fi

  # Saat root, tolak symlink agar source tidak bisa diarahkan ke path lain.
  [[ -L "${file}" ]] && return 1

  local owner mode
  owner="$(stat -c '%u' "${file_real}" 2>/dev/null || echo 1)"
  mode="$(stat -c '%A' "${file_real}" 2>/dev/null || echo '----------')"
  [[ "${owner}" == "0" ]] || return 1
  [[ "${mode:5:1}" != "w" && "${mode:8:1}" != "w" ]] || return 1
  return 0
}

manage_modules_dir_ready() {
  local dir="$1"
  local rel file
  manage_modules_dir_trusted "${dir}" || return 1
  for rel in "${MANAGE_REQUIRED_MODULES[@]}"; do
    file="${dir}/${rel}"
    [[ -r "${file}" ]] || return 1
    manage_module_file_trusted "${file}" "${dir}" || return 1
  done
  return 0
}

resolve_manage_modules_dir() {
  local installed_modules="/usr/local/lib/autoscript-manage/opt/manage"
  local local_modules="${MANAGE_SCRIPT_DIR}/opt/manage"
  if manage_modules_dir_ready "/opt/manage"; then
    printf '%s\n' "/opt/manage"
    return 0
  fi
  if [[ "${MANAGE_SCRIPT_DIR}" != "/usr/local/bin" ]] && manage_modules_dir_ready "${local_modules}"; then
    printf '%s\n' "${local_modules}"
    return 0
  fi
  if manage_modules_dir_ready "${installed_modules}"; then
    printf '%s\n' "${installed_modules}"
    return 0
  fi
  if manage_modules_dir_ready "/opt/autoscript/opt/manage"; then
    printf '%s\n' "/opt/autoscript/opt/manage"
    return 0
  fi
  if manage_modules_dir_ready "${local_modules}"; then
    printf '%s\n' "${local_modules}"
    return 0
  fi
  return 1
}

if [[ -n "${MANAGE_MODULES_DIR:-}" ]]; then
  if ! manage_modules_dir_ready "${MANAGE_MODULES_DIR}"; then
    die "MANAGE_MODULES_DIR tidak valid/tidak lengkap/tidak trusted: ${MANAGE_MODULES_DIR}"
  fi
else
  MANAGE_MODULES_DIR="$(resolve_manage_modules_dir)" \
    || die "Direktori module manage tidak ditemukan atau tidak trusted (cek /opt/manage, /usr/local/lib/autoscript-manage/opt/manage, /opt/autoscript/opt/manage, atau ${MANAGE_SCRIPT_DIR}/opt/manage)."
fi

manage_source_required() {
  local rel="$1"
  local file="${MANAGE_MODULES_DIR}/${rel}"
  [[ -r "${file}" ]] || die "Module wajib tidak ditemukan: ${file}. Jalankan setup.sh/run.sh terbaru untuk sinkronisasi /opt/manage."
  if ! manage_module_file_trusted "${file}"; then
    die "Module wajib tidak trusted/tidak valid: ${file}. Pastikan owner root dan tidak writable oleh group/other."
  fi
  # shellcheck disable=SC1090
  . "${file}"
}

# Stage-1 modules moved out from monolith manage.sh
for _mod in "${MANAGE_REQUIRED_MODULES[@]}"; do
  manage_source_required "${_mod}"
done
unset _mod

main "$@"
