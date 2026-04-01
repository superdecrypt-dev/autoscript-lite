#!/usr/bin/env bash
# Autoscript license runtime installer.

install_autoscript_license_runtime() {
  ok "Siapkan runtime license guard..."

  install -d -m 0755 "${AUTOSCRIPT_LICENSE_ROOT}" "${AUTOSCRIPT_LICENSE_STATE_DIR}"
  install_setup_bin_or_die "autoscript-license-check" "${AUTOSCRIPT_LICENSE_BIN}" 0755
  render_setup_template_or_die \
    "config/autoscript-license.env" \
    "${AUTOSCRIPT_LICENSE_CONFIG_FILE}" \
    0600 \
    "AUTOSCRIPT_LICENSE_DEFAULT_API_URL=${AUTOSCRIPT_LICENSE_DEFAULT_API_URL}" \
    "AUTOSCRIPT_LICENSE_API_URL=${AUTOSCRIPT_LICENSE_DEFAULT_API_URL}" \
    "AUTOSCRIPT_LICENSE_CACHE_TTL_SEC=${AUTOSCRIPT_LICENSE_CACHE_TTL_SEC}" \
    "AUTOSCRIPT_LICENSE_RUNTIME_ENFORCE=${AUTOSCRIPT_LICENSE_RUNTIME_ENFORCE}" \
    "AUTOSCRIPT_LICENSE_RUNTIME_INTERVAL_MIN=${AUTOSCRIPT_LICENSE_RUNTIME_INTERVAL_MIN}" \
    "AUTOSCRIPT_LICENSE_STATE_FILE=${AUTOSCRIPT_LICENSE_STATE_FILE}" \
    "AUTOSCRIPT_LICENSE_CACHE_FILE=${AUTOSCRIPT_LICENSE_CACHE_FILE}" \
    "AUTOSCRIPT_LICENSE_STOPPED_SERVICES_FILE=${AUTOSCRIPT_LICENSE_STOPPED_SERVICES_FILE}"
  render_setup_template_or_die \
    "systemd/autoscript-license-enforcer.service" \
    "/etc/systemd/system/${AUTOSCRIPT_LICENSE_SERVICE}" \
    0644 \
    "AUTOSCRIPT_LICENSE_CONFIG_FILE=${AUTOSCRIPT_LICENSE_CONFIG_FILE}" \
    "AUTOSCRIPT_LICENSE_BIN=${AUTOSCRIPT_LICENSE_BIN}"
  render_setup_template_or_die \
    "systemd/autoscript-license-enforcer.timer" \
    "/etc/systemd/system/${AUTOSCRIPT_LICENSE_TIMER}" \
    0644 \
    "AUTOSCRIPT_LICENSE_RUNTIME_INTERVAL_MIN=${AUTOSCRIPT_LICENSE_RUNTIME_INTERVAL_MIN}" \
    "AUTOSCRIPT_LICENSE_SERVICE=${AUTOSCRIPT_LICENSE_SERVICE}"
  systemctl daemon-reload

  if autoscript_license_enabled && autoscript_license_runtime_enforce_enabled; then
    if ! systemctl enable --now "${AUTOSCRIPT_LICENSE_TIMER}" >/dev/null 2>&1; then
      systemctl status "${AUTOSCRIPT_LICENSE_TIMER}" --no-pager >&2 || true
      journalctl -u "${AUTOSCRIPT_LICENSE_TIMER}" -n 80 --no-pager >&2 || true
      die "Gagal mengaktifkan ${AUTOSCRIPT_LICENSE_TIMER}."
    fi
    if ! systemctl start "${AUTOSCRIPT_LICENSE_SERVICE}" >/dev/null 2>&1; then
      systemctl status "${AUTOSCRIPT_LICENSE_SERVICE}" --no-pager >&2 || true
      journalctl -u "${AUTOSCRIPT_LICENSE_SERVICE}" -n 80 --no-pager >&2 || true
      die "Gagal menjalankan ${AUTOSCRIPT_LICENSE_SERVICE}."
    fi
    ok "License guard runtime aktif: ${AUTOSCRIPT_LICENSE_TIMER}"
    return 0
  fi

  systemctl disable --now "${AUTOSCRIPT_LICENSE_TIMER}" >/dev/null 2>&1 || true
  systemctl stop "${AUTOSCRIPT_LICENSE_SERVICE}" >/dev/null 2>&1 || true
  if ! autoscript_license_enabled; then
    warn "License guard runtime dipasang tetapi nonaktif karena URL lisensi tidak tersedia."
  else
    warn "License guard runtime dipasang tetapi timer dinonaktifkan karena AUTOSCRIPT_LICENSE_RUNTIME_ENFORCE=false."
  fi
}
