#!/usr/bin/env bash
# SSH Adblock foundation for setup runtime.

SSH_DNS_ADBLOCK_ROOT="${SSH_DNS_ADBLOCK_ROOT:-/etc/autoscript/ssh-adblock}"
SSH_DNS_ADBLOCK_CONFIG_FILE="${SSH_DNS_ADBLOCK_ROOT}/config.env"
SSH_DNS_ADBLOCK_BLOCKLIST_FILE="${SSH_DNS_ADBLOCK_ROOT}/blocked.domains"
SSH_DNS_ADBLOCK_URLS_FILE="${SSH_DNS_ADBLOCK_ROOT}/source.urls"
SSH_DNS_ADBLOCK_RENDERED_FILE="${SSH_DNS_ADBLOCK_ROOT}/blocklist.generated.conf"
SSH_DNS_ADBLOCK_DNSMASQ_CONF="${SSH_DNS_ADBLOCK_ROOT}/dnsmasq.conf"
SSH_DNS_ADBLOCK_PORT="${SSH_DNS_ADBLOCK_PORT:-5353}"
SSH_DNS_ADBLOCK_SERVICE="${SSH_DNS_ADBLOCK_SERVICE:-ssh-adblock-dns.service}"
SSH_DNS_ADBLOCK_SYNC_SERVICE="${SSH_DNS_ADBLOCK_SYNC_SERVICE:-ssh-adblock-sync.service}"
SSH_DNS_ADBLOCK_SYNC_BIN="${SSH_DNS_ADBLOCK_SYNC_BIN:-/usr/local/bin/ssh-adblock-sync}"
SSH_DNS_ADBLOCK_NFT_TABLE="${SSH_DNS_ADBLOCK_NFT_TABLE:-autoscript_ssh_adblock}"
SSH_DNS_ADBLOCK_STATE_ROOT="${SSH_DNS_ADBLOCK_STATE_ROOT:-${SSH_QUOTA_DIR:-/opt/quota/ssh}}"

install_ssh_dns_adblock_foundation() {
  ok "Pasang fondasi SSH Adblock..."
  command -v python3 >/dev/null 2>&1 || die "python3 dibutuhkan untuk SSH Adblock."
  local dnsmasq_bin=""
  dnsmasq_bin="$(command -v dnsmasq 2>/dev/null || true)"
  [[ -n "${dnsmasq_bin}" ]] || die "dnsmasq tidak ditemukan. Pastikan dnsmasq-base terpasang."
  command -v nft >/dev/null 2>&1 || die "nft tidak ditemukan. Pastikan nftables terpasang."

  install -d -m 755 /etc/systemd/system
  install -d -m 755 "${SSH_DNS_ADBLOCK_ROOT}"

  install_setup_bin_or_die "ssh-adblock-sync.py" "${SSH_DNS_ADBLOCK_SYNC_BIN}" 0755

  render_setup_template_or_die \
    "config/ssh-adblock.env" \
    "${SSH_DNS_ADBLOCK_CONFIG_FILE}" \
    0644 \
    "SSH_DNS_ADBLOCK_PORT=${SSH_DNS_ADBLOCK_PORT}" \
    "SSH_DNS_ADBLOCK_STATE_ROOT=${SSH_DNS_ADBLOCK_STATE_ROOT}" \
    "SSH_DNS_ADBLOCK_BLOCKLIST_FILE=${SSH_DNS_ADBLOCK_BLOCKLIST_FILE}" \
    "SSH_DNS_ADBLOCK_URLS_FILE=${SSH_DNS_ADBLOCK_URLS_FILE}" \
    "SSH_DNS_ADBLOCK_RENDERED_FILE=${SSH_DNS_ADBLOCK_RENDERED_FILE}" \
    "SSH_DNS_ADBLOCK_NFT_TABLE=${SSH_DNS_ADBLOCK_NFT_TABLE}" \
    "SSH_DNS_ADBLOCK_SERVICE=${SSH_DNS_ADBLOCK_SERVICE}" \
    "SSH_DNS_ADBLOCK_SYNC_SERVICE=${SSH_DNS_ADBLOCK_SYNC_SERVICE}"

  render_setup_template_or_die \
    "config/ssh-adblock.blocked.domains" \
    "${SSH_DNS_ADBLOCK_BLOCKLIST_FILE}" \
    0644

  install -m 0644 /dev/null "${SSH_DNS_ADBLOCK_URLS_FILE}"

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
    "systemd/ssh-adblock-sync.service" \
    "/etc/systemd/system/${SSH_DNS_ADBLOCK_SYNC_SERVICE}" \
    0644 \
    "SSH_DNS_ADBLOCK_SYNC_BIN=${SSH_DNS_ADBLOCK_SYNC_BIN}"

  systemctl daemon-reload
  systemctl enable --now "${SSH_DNS_ADBLOCK_SERVICE}" >/dev/null 2>&1 || die "Gagal mengaktifkan ${SSH_DNS_ADBLOCK_SERVICE}."
  systemctl enable "${SSH_DNS_ADBLOCK_SYNC_SERVICE}" >/dev/null 2>&1 || true
  "${SSH_DNS_ADBLOCK_SYNC_BIN}" --apply >/dev/null 2>&1 || die "Gagal sinkronisasi awal SSH Adblock."
  ok "Fondasi SSH Adblock siap."
}
