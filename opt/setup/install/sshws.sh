#!/usr/bin/env bash
# SSHWS install/runtime module for setup runtime.

validate_port_number() {
  local name="$1"
  local value="$2"
  [[ "${value}" =~ ^[0-9]+$ ]] || die "${name} harus angka 1..65535 (got: ${value})."
  if (( value < 1 || value > 65535 )); then
    die "${name} di luar range 1..65535 (got: ${value})."
  fi
}

validate_sshws_ports_config() {
  local stunnel_enabled="false"
  if command -v stunnel4 >/dev/null 2>&1 || command -v stunnel >/dev/null 2>&1; then
    stunnel_enabled="true"
  fi

  validate_port_number "SSHWS_DROPBEAR_PORT" "${SSHWS_DROPBEAR_PORT}"
  validate_port_number "SSHWS_PROXY_PORT" "${SSHWS_PROXY_PORT}"
  if [[ "${stunnel_enabled}" == "true" ]]; then
    validate_port_number "SSHWS_STUNNEL_PORT" "${SSHWS_STUNNEL_PORT}"
  fi

  if [[ "${SSHWS_DROPBEAR_PORT}" == "${SSHWS_PROXY_PORT}" ]]; then
    die "Port SSHWS tidak boleh duplikat (dropbear=${SSHWS_DROPBEAR_PORT}, proxy=${SSHWS_PROXY_PORT})."
  fi
  if [[ "${stunnel_enabled}" == "true" ]] && [[ "${SSHWS_DROPBEAR_PORT}" == "${SSHWS_STUNNEL_PORT}" \
     || "${SSHWS_STUNNEL_PORT}" == "${SSHWS_PROXY_PORT}" ]]; then
    die "Port SSHWS tidak boleh duplikat saat stunnel aktif (dropbear=${SSHWS_DROPBEAR_PORT}, stunnel=${SSHWS_STUNNEL_PORT}, proxy=${SSHWS_PROXY_PORT})."
  fi

  local -a ports=("${SSHWS_DROPBEAR_PORT}" "${SSHWS_PROXY_PORT}")
  local p
  if [[ "${stunnel_enabled}" == "true" ]]; then
    ports+=("${SSHWS_STUNNEL_PORT}")
  fi
  for p in "${ports[@]}"; do
    case "${p}" in
      80|443)
        die "Port SSHWS ${p} bentrok dengan port publik Nginx (80/443)."
        ;;
      10085)
        die "Port SSHWS ${p} bentrok dengan Xray API port (10085)."
        ;;
    esac
  done
  if [[ "${stunnel_enabled}" != "true" ]]; then
    warn "Validasi port stunnel dilewati (stunnel belum tersedia, mode opsional)."
  fi
}

install_sshws_stack() {
  ok "Setup SSH WebSocket stack (dropbear + stunnel4 + proxy, backend direct ke dropbear)..."
  command -v python3 >/dev/null 2>&1 || die "python3 tidak ditemukan untuk SSH WS proxy."
  [[ -x /usr/sbin/dropbear ]] || die "dropbear tidak ditemukan di /usr/sbin/dropbear."

  local stunnel_bin=""
  if command -v stunnel4 >/dev/null 2>&1; then
    stunnel_bin="$(command -v stunnel4)"
  elif command -v stunnel >/dev/null 2>&1; then
    stunnel_bin="$(command -v stunnel)"
  else
    warn "stunnel4/stunnel tidak ditemukan. Service sshws-stunnel akan dilewati (opsional)."
  fi

  install -d -m 755 /etc/systemd/system
  if [[ -n "${stunnel_bin}" ]]; then
    install -d -m 755 /etc/stunnel
    install -d -m 755 /run/stunnel
  fi

  systemctl disable --now xray-sshws-dropbear xray-sshws-stunnel xray-sshws-proxy >/dev/null 2>&1 || true
  systemctl disable --now sshws-dropbear sshws-stunnel sshws-proxy >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/xray-sshws-dropbear.service \
        /etc/systemd/system/xray-sshws-stunnel.service \
        /etc/systemd/system/xray-sshws-proxy.service >/dev/null 2>&1 || true
  rm -f /usr/local/bin/xray-sshws-proxy /etc/stunnel/xray-sshws.conf >/dev/null 2>&1 || true

  local -a required_ports=("${SSHWS_DROPBEAR_PORT}" "${SSHWS_PROXY_PORT}")
  local p
  if [[ -n "${stunnel_bin}" ]]; then
    required_ports+=("${SSHWS_STUNNEL_PORT}")
  fi
  for p in "${required_ports[@]}"; do
    if ! is_port_free "${p}"; then
      die "Port SSHWS ${p} sedang dipakai proses lain. Bebaskan port ini atau ubah SSHWS_*_PORT."
    fi
  done

  render_setup_template_or_die \
    "systemd/sshws-dropbear.service" \
    "/etc/systemd/system/sshws-dropbear.service" \
    0644 \
    "SSHWS_DROPBEAR_PORT=${SSHWS_DROPBEAR_PORT}"

  if [[ -n "${stunnel_bin}" ]]; then
    render_setup_template_or_die \
      "config/sshws-stunnel.conf" \
      "/etc/stunnel/sshws.conf" \
      0600 \
      "SSHWS_STUNNEL_PORT=${SSHWS_STUNNEL_PORT}" \
      "SSHWS_DROPBEAR_PORT=${SSHWS_DROPBEAR_PORT}" \
      "CERT_FULLCHAIN=${CERT_FULLCHAIN}" \
      "CERT_PRIVKEY=${CERT_PRIVKEY}"

    render_setup_template_or_die \
      "systemd/sshws-stunnel.service" \
      "/etc/systemd/system/sshws-stunnel.service" \
      0644 \
      "STUNNEL_BIN=${stunnel_bin}"
  else
    rm -f /etc/stunnel/sshws.conf /etc/systemd/system/sshws-stunnel.service >/dev/null 2>&1 || true
  fi

  install_setup_bin_or_die "sshws-proxy.py" "/usr/local/bin/sshws-proxy" 0755

  render_setup_template_or_die \
    "systemd/sshws-proxy.service" \
    "/etc/systemd/system/sshws-proxy.service" \
    0644 \
    "SSHWS_PROXY_PORT=${SSHWS_PROXY_PORT}" \
    "SSHWS_DROPBEAR_PORT=${SSHWS_DROPBEAR_PORT}"

  systemctl daemon-reload
  service_enable_restart_checked sshws-dropbear || die "Gagal mengaktifkan sshws-dropbear."
  if [[ -n "${stunnel_bin}" ]]; then
    if service_enable_restart_checked sshws-stunnel; then
      ok "sshws-stunnel aktif (standby TLS local bridge)."
    else
      warn "sshws-stunnel gagal aktif. Layanan utama SSHWS tetap berjalan via jalur proxy -> dropbear direct."
      systemctl disable --now sshws-stunnel >/dev/null 2>&1 || true
    fi
  else
    ok "sshws-stunnel dilewati (binary stunnel tidak tersedia)."
    systemctl disable --now sshws-stunnel >/dev/null 2>&1 || true
  fi
  service_enable_restart_checked sshws-proxy || die "Gagal mengaktifkan sshws-proxy."

  systemctl disable --now stunnel4 >/dev/null 2>&1 || true

  if systemctl is-active --quiet ssh >/dev/null 2>&1 || systemctl is-active --quiet sshd >/dev/null 2>&1; then
    systemctl disable dropbear >/dev/null 2>&1 || true
    ok "Dropbear distro diset disabled (fallback OpenSSH aktif)."
  else
    warn "Dropbear distro dipertahankan untuk mencegah lockout SSH (OpenSSH tidak aktif)."
  fi
  ok "SSH WebSocket stack aktif (proxy -> dropbear direct, stunnel standby)."
}

install_sshws_qac_enforcer() {
  ok "Setup SSH QAC enforcer (timer 1 menit)..."
  command -v python3 >/dev/null 2>&1 || die "python3 tidak ditemukan untuk SSH QAC enforcer."
  install -d -m 755 /etc/systemd/system

  install_setup_bin_or_die "sshws-qac-enforcer.py" "/usr/local/bin/sshws-qac-enforcer" 0755

  render_setup_template_or_die \
    "systemd/sshws-qac-enforcer.service" \
    "/etc/systemd/system/sshws-qac-enforcer.service" \
    0644

  render_setup_template_or_die \
    "systemd/sshws-qac-enforcer.timer" \
    "/etc/systemd/system/sshws-qac-enforcer.timer" \
    0644

  systemctl daemon-reload
  if systemctl enable --now sshws-qac-enforcer.timer >/dev/null 2>&1; then
    systemctl start sshws-qac-enforcer.service >/dev/null 2>&1 || true
    ok "SSH QAC enforcer aktif:"
    ok "  - binary: /usr/local/bin/sshws-qac-enforcer"
    ok "  - timer : sshws-qac-enforcer.timer (1 menit)"
  else
    warn "Gagal mengaktifkan sshws-qac-enforcer.timer. Cek: systemctl status sshws-qac-enforcer.timer --no-pager"
  fi
}
