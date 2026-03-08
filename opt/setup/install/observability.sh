#!/usr/bin/env bash
# Observability, guard, and log maintenance module for setup runtime.

setup_logrotate() {
  ok "Pasang logrotate..."

  cat > /etc/logrotate.d/xray-nginx <<'EOF'
/var/log/nginx/*.log /var/log/xray/*.log {
  daily
  rotate 7
  missingok
  notifempty
  compress
  delaycompress
  copytruncate
}
EOF

  rm -f /etc/cron.d/cleanup-xray-nginx-logs /usr/local/bin/cleanup-xray-nginx-logs 2>/dev/null || true
  ok "Logrotate aktif."
}

install_observability_alerting() {
  ok "Pasang observability..."

  mkdir -p "${OBS_CONFIG_DIR}" "${OBS_STATE_DIR}" "${OBS_LOG_DIR}"
  chmod 700 "${OBS_CONFIG_DIR}" "${OBS_STATE_DIR}" "${OBS_LOG_DIR}" || true

  cat > "${OBS_CONFIG_FILE}" <<'EOF'
# URL webhook opsional. Jika kosong, alert hanya ditulis ke log lokal.
ALERT_WEBHOOK_URL=""
# Batas warning masa berlaku cert (hari).
CERT_WARN_DAYS=14
# Kirim alert hanya saat payload berubah (anti-spam).
ALERT_ONLY_ON_CHANGE=1
# Jika 1, mismatch DNS->IP asal diabaikan bila resolve ke IP Cloudflare (proxied).
ALLOW_CLOUDFLARE_PROXY_MISMATCH=1
EOF
  chmod 600 "${OBS_CONFIG_FILE}" || true

  install_setup_bin_or_die "xray-observe" "/usr/local/bin/xray-observe" 0755

  render_setup_template_or_die \
    "systemd/xray-observe.service" \
    "/etc/systemd/system/xray-observe.service" \
    0644

  render_setup_template_or_die \
    "systemd/xray-observe.timer" \
    "/etc/systemd/system/xray-observe.timer" \
    0644

  systemctl daemon-reload
  if systemctl enable --now xray-observe.timer >/dev/null 2>&1; then
    systemctl start xray-observe.service >/dev/null 2>&1 || true
    ok "Observability aktif:"
    ok "  - binary: /usr/local/bin/xray-observe"
    ok "  - config: ${OBS_CONFIG_FILE}"
    ok "  - timer : xray-observe.timer (5 menit)"
  else
    warn "Gagal mengaktifkan xray-observe.timer. Cek: systemctl status xray-observe.timer --no-pager"
  fi
}

install_domain_cert_guard() {
  ok "Pasang domain guard..."

  mkdir -p "${DOMAIN_GUARD_CONFIG_DIR}" "${OBS_LOG_DIR}"
  chmod 700 "${DOMAIN_GUARD_CONFIG_DIR}" "${OBS_LOG_DIR}" || true

  cat > "${DOMAIN_GUARD_CONFIG_FILE}" <<'EOF'
# Warning jika cert <= nilai ini (hari)
CERT_WARN_DAYS=14
# Jika renew-if-needed dipanggil, renewal dipicu jika cert <= nilai ini (hari)
RENEW_BELOW_DAYS=7
# 1=izinkan auto renew by timer, 0=check-only (disarankan default)
AUTO_RENEW=0
# Jika 1, mismatch DNS->IP asal diabaikan bila resolve ke IP Cloudflare (proxied).
ALLOW_CLOUDFLARE_PROXY_MISMATCH=1
EOF
  chmod 600 "${DOMAIN_GUARD_CONFIG_FILE}" || true

  install_setup_bin_or_die "xray-domain-guard" "/usr/local/bin/xray-domain-guard" 0755

  render_setup_template_or_die \
    "systemd/xray-domain-guard.service" \
    "/etc/systemd/system/xray-domain-guard.service" \
    0644

  render_setup_template_or_die \
    "systemd/xray-domain-guard.timer" \
    "/etc/systemd/system/xray-domain-guard.timer" \
    0644

  systemctl daemon-reload
  if systemctl enable --now xray-domain-guard.timer >/dev/null 2>&1; then
    systemctl start xray-domain-guard.service >/dev/null 2>&1 || true
    ok "Domain guard aktif:"
    ok "  - binary: /usr/local/bin/xray-domain-guard"
    ok "  - config: ${DOMAIN_GUARD_CONFIG_FILE}"
    ok "  - timer : xray-domain-guard.timer (12 jam)"
  else
    warn "Gagal mengaktifkan xray-domain-guard.timer. Cek: systemctl status xray-domain-guard.timer --no-pager"
  fi
}
