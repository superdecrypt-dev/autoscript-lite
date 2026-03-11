#!/usr/bin/env bash
# Domain guard and log maintenance module for setup runtime.

ensure_env_assignment_present() {
  local file="$1"
  local key="$2"
  local assignment="$3"
  [[ -n "${file}" && -n "${key}" && -n "${assignment}" ]] || return 1
  touch "${file}" >/dev/null 2>&1 || return 1
  if ! grep -Eq "^${key}=" "${file}" 2>/dev/null; then
    printf '%s\n' "${assignment}" >> "${file}" || return 1
  fi
}

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

install_domain_cert_guard() {
  ok "Pasang domain guard..."

  mkdir -p "${DOMAIN_GUARD_CONFIG_DIR}" "${DOMAIN_GUARD_LOG_DIR}"
  chmod 700 "${DOMAIN_GUARD_CONFIG_DIR}" "${DOMAIN_GUARD_LOG_DIR}" || true

  if [[ ! -f "${DOMAIN_GUARD_CONFIG_FILE}" ]]; then
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
  else
    ensure_env_assignment_present "${DOMAIN_GUARD_CONFIG_FILE}" "CERT_WARN_DAYS" 'CERT_WARN_DAYS=14'
    ensure_env_assignment_present "${DOMAIN_GUARD_CONFIG_FILE}" "RENEW_BELOW_DAYS" 'RENEW_BELOW_DAYS=7'
    ensure_env_assignment_present "${DOMAIN_GUARD_CONFIG_FILE}" "AUTO_RENEW" 'AUTO_RENEW=0'
    ensure_env_assignment_present "${DOMAIN_GUARD_CONFIG_FILE}" "ALLOW_CLOUDFLARE_PROXY_MISMATCH" 'ALLOW_CLOUDFLARE_PROXY_MISMATCH=1'
  fi
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
