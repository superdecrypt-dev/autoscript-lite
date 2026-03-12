#!/usr/bin/env bash
# Shared Adblock foundation for setup runtime.

SSH_DNS_ADBLOCK_ROOT="${SSH_DNS_ADBLOCK_ROOT:-/etc/autoscript/ssh-adblock}"
SSH_DNS_ADBLOCK_CONFIG_FILE="${SSH_DNS_ADBLOCK_ROOT}/config.env"
SSH_DNS_ADBLOCK_BLOCKLIST_FILE="${SSH_DNS_ADBLOCK_ROOT}/blocked.domains"
SSH_DNS_ADBLOCK_URLS_FILE="${SSH_DNS_ADBLOCK_ROOT}/source.urls"
SSH_DNS_ADBLOCK_MERGED_FILE="${SSH_DNS_ADBLOCK_ROOT}/merged.domains"
SSH_DNS_ADBLOCK_RENDERED_FILE="${SSH_DNS_ADBLOCK_ROOT}/blocklist.generated.conf"
SSH_DNS_ADBLOCK_DNSMASQ_CONF="${SSH_DNS_ADBLOCK_ROOT}/dnsmasq.conf"
SSH_DNS_ADBLOCK_PORT="${SSH_DNS_ADBLOCK_PORT:-5353}"
SSH_DNS_ADBLOCK_SERVICE="${SSH_DNS_ADBLOCK_SERVICE:-ssh-adblock-dns.service}"
SSH_DNS_ADBLOCK_SYNC_SERVICE="${SSH_DNS_ADBLOCK_SYNC_SERVICE:-adblock-sync.service}"
SSH_DNS_ADBLOCK_SYNC_BIN="${SSH_DNS_ADBLOCK_SYNC_BIN:-/usr/local/bin/adblock-sync}"
SSH_DNS_ADBLOCK_LEGACY_SYNC_SERVICE="${SSH_DNS_ADBLOCK_LEGACY_SYNC_SERVICE:-ssh-adblock-sync.service}"
SSH_DNS_ADBLOCK_LEGACY_SYNC_BIN="${SSH_DNS_ADBLOCK_LEGACY_SYNC_BIN:-/usr/local/bin/ssh-adblock-sync}"
ADBLOCK_AUTO_UPDATE_SERVICE="${ADBLOCK_AUTO_UPDATE_SERVICE:-adblock-update.service}"
ADBLOCK_AUTO_UPDATE_TIMER="${ADBLOCK_AUTO_UPDATE_TIMER:-adblock-update.timer}"
ADBLOCK_AUTO_UPDATE_DAYS="${ADBLOCK_AUTO_UPDATE_DAYS:-1}"
SSH_DNS_ADBLOCK_NFT_TABLE="${SSH_DNS_ADBLOCK_NFT_TABLE:-autoscript_ssh_adblock}"
SSH_DNS_ADBLOCK_STATE_ROOT="${SSH_DNS_ADBLOCK_STATE_ROOT:-${SSH_QUOTA_DIR:-/opt/quota/ssh}}"

adblock_config_render_preserving_runtime_state() {
  local rendered merged
  rendered="$(mktemp "${TMPDIR:-/tmp}/ssh-adblock-config.rendered.XXXXXX")" || die "Gagal menyiapkan config adblock."
  merged="$(mktemp "${TMPDIR:-/tmp}/ssh-adblock-config.merged.XXXXXX")" || {
    rm -f "${rendered}" >/dev/null 2>&1 || true
    die "Gagal menyiapkan merge config adblock."
  }

  render_setup_template_or_die \
    "config/ssh-adblock.env" \
    "${rendered}" \
    0644 \
    "SSH_DNS_ADBLOCK_PORT=${SSH_DNS_ADBLOCK_PORT}" \
    "SSH_DNS_ADBLOCK_STATE_ROOT=${SSH_DNS_ADBLOCK_STATE_ROOT}" \
    "SSH_DNS_ADBLOCK_BLOCKLIST_FILE=${SSH_DNS_ADBLOCK_BLOCKLIST_FILE}" \
    "SSH_DNS_ADBLOCK_URLS_FILE=${SSH_DNS_ADBLOCK_URLS_FILE}" \
    "SSH_DNS_ADBLOCK_MERGED_FILE=${SSH_DNS_ADBLOCK_MERGED_FILE}" \
    "SSH_DNS_ADBLOCK_RENDERED_FILE=${SSH_DNS_ADBLOCK_RENDERED_FILE}" \
    "SSH_DNS_ADBLOCK_NFT_TABLE=${SSH_DNS_ADBLOCK_NFT_TABLE}" \
    "SSH_DNS_ADBLOCK_SERVICE=${SSH_DNS_ADBLOCK_SERVICE}" \
    "SSH_DNS_ADBLOCK_SYNC_SERVICE=${SSH_DNS_ADBLOCK_SYNC_SERVICE}" \
    "ADBLOCK_AUTO_UPDATE_SERVICE=${ADBLOCK_AUTO_UPDATE_SERVICE}" \
    "ADBLOCK_AUTO_UPDATE_TIMER=${ADBLOCK_AUTO_UPDATE_TIMER}" \
    "ADBLOCK_AUTO_UPDATE_DAYS=${ADBLOCK_AUTO_UPDATE_DAYS}" \
    "CUSTOM_GEOSITE_DEST=${CUSTOM_GEOSITE_DEST}"

  if [[ -f "${SSH_DNS_ADBLOCK_CONFIG_FILE}" ]]; then
    python3 - "${SSH_DNS_ADBLOCK_CONFIG_FILE}" "${rendered}" "${merged}" <<'PY' || {
import pathlib
import sys

existing_path = pathlib.Path(sys.argv[1])
rendered_path = pathlib.Path(sys.argv[2])
merged_path = pathlib.Path(sys.argv[3])
preserve_keys = {
  "SSH_DNS_ADBLOCK_ENABLED",
  "AUTOSCRIPT_ADBLOCK_AUTO_UPDATE_ENABLED",
  "AUTOSCRIPT_ADBLOCK_AUTO_UPDATE_DAYS",
  "AUTOSCRIPT_ADBLOCK_DIRTY",
  "AUTOSCRIPT_ADBLOCK_LAST_UPDATE",
}

existing = {}
try:
  for line in existing_path.read_text(encoding="utf-8").splitlines():
    line = line.strip()
    if not line or line.startswith("#") or "=" not in line:
      continue
    key, value = line.split("=", 1)
    existing[key.strip()] = value.strip()
except Exception:
  existing = {}

lines = rendered_path.read_text(encoding="utf-8").splitlines()
out = []
for line in lines:
  stripped = line.strip()
  if not stripped or stripped.startswith("#") or "=" not in line:
    out.append(line)
    continue
  key, _ = line.split("=", 1)
  key = key.strip()
  if key in preserve_keys and key in existing:
    out.append(f"{key}={existing[key]}")
  else:
    out.append(line)

merged_path.write_text("\n".join(out).rstrip("\n") + "\n", encoding="utf-8")
PY
      rm -f "${rendered}" "${merged}" >/dev/null 2>&1 || true
      die "Gagal merge state adblock lama."
    }
    install -m 0644 "${merged}" "${SSH_DNS_ADBLOCK_CONFIG_FILE}"
  else
    install -m 0644 "${rendered}" "${SSH_DNS_ADBLOCK_CONFIG_FILE}"
  fi
  chown root:root "${SSH_DNS_ADBLOCK_CONFIG_FILE}" 2>/dev/null || true
  rm -f "${rendered}" "${merged}" >/dev/null 2>&1 || true
}

adblock_config_get_value() {
  local key="$1"
  local fallback="${2:-}"
  [[ -f "${SSH_DNS_ADBLOCK_CONFIG_FILE}" ]] || {
    printf '%s\n' "${fallback}"
    return 0
  }
  awk -F'=' -v target="${key}" -v default_value="${fallback}" '
    $1 == target {
      print substr($0, index($0, "=") + 1)
      found = 1
      exit
    }
    END {
      if (!found) {
        print default_value
      }
    }
  ' "${SSH_DNS_ADBLOCK_CONFIG_FILE}" 2>/dev/null
}

adblock_seed_template_if_missing() {
  local template_rel="$1"
  local dst="$2"
  local mode="${3:-0644}"
  if [[ -e "${dst}" ]]; then
    chmod "${mode}" "${dst}" >/dev/null 2>&1 || true
    chown root:root "${dst}" 2>/dev/null || true
    return 0
  fi
  render_setup_template_or_die "${template_rel}" "${dst}" "${mode}"
}

adblock_touch_if_missing() {
  local dst="$1"
  local mode="${2:-0644}"
  if [[ -e "${dst}" ]]; then
    chmod "${mode}" "${dst}" >/dev/null 2>&1 || true
    chown root:root "${dst}" 2>/dev/null || true
    return 0
  fi
  install -m "${mode}" /dev/null "${dst}"
  chown root:root "${dst}" 2>/dev/null || true
}

adblock_runtime_artifacts_ready() {
  [[ -s "${CUSTOM_GEOSITE_DEST}" ]] || return 1
  if [[ -s "${SSH_DNS_ADBLOCK_MERGED_FILE}" ]]; then
    return 0
  fi
  [[ -s "${SSH_DNS_ADBLOCK_RENDERED_FILE}" ]]
}

adblock_bootstrap_update_or_preserve_runtime() {
  if "${SSH_DNS_ADBLOCK_SYNC_BIN}" --update >/dev/null 2>&1; then
    return 0
  fi
  if adblock_runtime_artifacts_ready && "${SSH_DNS_ADBLOCK_SYNC_BIN}" --apply >/dev/null 2>&1; then
    warn "Update Adblock gagal saat setup; artifact lama dipertahankan."
    return 0
  fi
  return 1
}

adblock_cleanup_legacy_sync_runtime() {
  if [[ "${SSH_DNS_ADBLOCK_LEGACY_SYNC_SERVICE}" != "${SSH_DNS_ADBLOCK_SYNC_SERVICE}" ]]; then
    systemctl disable --now "${SSH_DNS_ADBLOCK_LEGACY_SYNC_SERVICE}" >/dev/null 2>&1 || true
    systemctl reset-failed "${SSH_DNS_ADBLOCK_LEGACY_SYNC_SERVICE}" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${SSH_DNS_ADBLOCK_LEGACY_SYNC_SERVICE}" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/multi-user.target.wants/${SSH_DNS_ADBLOCK_LEGACY_SYNC_SERVICE}" >/dev/null 2>&1 || true
  fi
  if [[ "${SSH_DNS_ADBLOCK_LEGACY_SYNC_BIN}" != "${SSH_DNS_ADBLOCK_SYNC_BIN}" ]]; then
    rm -f "${SSH_DNS_ADBLOCK_LEGACY_SYNC_BIN}" >/dev/null 2>&1 || true
  fi
}

install_ssh_dns_adblock_foundation() {
  ok "Pasang fondasi SSH Adblock..."
  command -v python3 >/dev/null 2>&1 || die "python3 dibutuhkan untuk SSH Adblock."
  local dnsmasq_bin=""
  local adblock_auto_update_days_effective=""
  dnsmasq_bin="$(command -v dnsmasq 2>/dev/null || true)"
  [[ -n "${dnsmasq_bin}" ]] || die "dnsmasq tidak ditemukan. Pastikan dnsmasq-base terpasang."
  command -v nft >/dev/null 2>&1 || die "nft tidak ditemukan. Pastikan nftables terpasang."

  install -d -m 755 /etc/systemd/system
  install -d -m 755 "${SSH_DNS_ADBLOCK_ROOT}"

  install_setup_bin_or_die "adblock-sync.py" "${SSH_DNS_ADBLOCK_SYNC_BIN}" 0755

  adblock_config_render_preserving_runtime_state

  adblock_seed_template_if_missing \
    "config/ssh-adblock.blocked.domains" \
    "${SSH_DNS_ADBLOCK_BLOCKLIST_FILE}" \
    0644

  adblock_touch_if_missing "${SSH_DNS_ADBLOCK_URLS_FILE}" 0644
  adblock_touch_if_missing "${SSH_DNS_ADBLOCK_MERGED_FILE}" 0644

  adblock_auto_update_days_effective="$(adblock_config_get_value AUTOSCRIPT_ADBLOCK_AUTO_UPDATE_DAYS "${ADBLOCK_AUTO_UPDATE_DAYS}")"
  [[ "${adblock_auto_update_days_effective}" =~ ^[1-9][0-9]*$ ]] || adblock_auto_update_days_effective="${ADBLOCK_AUTO_UPDATE_DAYS}"

  render_setup_template_or_die \
    "config/ssh-adblock-dnsmasq.conf" \
    "${SSH_DNS_ADBLOCK_DNSMASQ_CONF}" \
    0644 \
    "SSH_DNS_ADBLOCK_PORT=${SSH_DNS_ADBLOCK_PORT}" \
    "SSH_DNS_ADBLOCK_RENDERED_FILE=${SSH_DNS_ADBLOCK_RENDERED_FILE}"

  render_setup_template_or_die \
    "systemd/ssh-adblock-dns.service" \
    "/etc/systemd/system/${SSH_DNS_ADBLOCK_SERVICE}" \
    0644 \
    "DNSMASQ_BIN=${dnsmasq_bin}" \
    "SSH_DNS_ADBLOCK_DNSMASQ_CONF=${SSH_DNS_ADBLOCK_DNSMASQ_CONF}"

  render_setup_template_or_die \
    "systemd/adblock-sync.service" \
    "/etc/systemd/system/${SSH_DNS_ADBLOCK_SYNC_SERVICE}" \
    0644 \
    "SSH_DNS_ADBLOCK_SYNC_BIN=${SSH_DNS_ADBLOCK_SYNC_BIN}"

  render_setup_template_or_die \
    "systemd/adblock-update.service" \
    "/etc/systemd/system/${ADBLOCK_AUTO_UPDATE_SERVICE}" \
    0644 \
    "SSH_DNS_ADBLOCK_SYNC_BIN=${SSH_DNS_ADBLOCK_SYNC_BIN}"

  render_setup_template_or_die \
    "systemd/adblock-update.timer" \
    "/etc/systemd/system/${ADBLOCK_AUTO_UPDATE_TIMER}" \
    0644 \
    "ADBLOCK_AUTO_UPDATE_SERVICE=${ADBLOCK_AUTO_UPDATE_SERVICE}" \
    "ADBLOCK_AUTO_UPDATE_DAYS=${adblock_auto_update_days_effective}"

  adblock_cleanup_legacy_sync_runtime
  systemctl daemon-reload
  systemctl enable --now "${SSH_DNS_ADBLOCK_SERVICE}" >/dev/null 2>&1 || die "Gagal mengaktifkan ${SSH_DNS_ADBLOCK_SERVICE}."
  systemctl enable "${SSH_DNS_ADBLOCK_SYNC_SERVICE}" >/dev/null 2>&1 || true
  adblock_bootstrap_update_or_preserve_runtime || die "Gagal bootstrap awal Adblock."
  if grep -Eq '^AUTOSCRIPT_ADBLOCK_AUTO_UPDATE_ENABLED=1$' "${SSH_DNS_ADBLOCK_CONFIG_FILE}" 2>/dev/null; then
    systemctl enable --now "${ADBLOCK_AUTO_UPDATE_TIMER}" >/dev/null 2>&1 || die "Gagal mengaktifkan ${ADBLOCK_AUTO_UPDATE_TIMER}."
  else
    systemctl disable --now "${ADBLOCK_AUTO_UPDATE_TIMER}" >/dev/null 2>&1 || true
  fi
  ok "Fondasi SSH Adblock siap."
}
