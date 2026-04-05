#!/usr/bin/env bash
# shellcheck shell=bash

# -------------------------
# Security
# - TLS & Cert
# - Fail2ban
# - Hardening
# - Overview
# -------------------------
cert_openssl_info() {
  if ! have_cmd openssl; then
    warn "openssl tidak tersedia"
    return 1
  fi
  if [[ ! -f "${CERT_FULLCHAIN}" ]]; then
    warn "Cert tidak ditemukan: ${CERT_FULLCHAIN}"
    return 1
  fi
  openssl x509 -in "${CERT_FULLCHAIN}" -noout     -subject -issuer -serial -startdate -enddate -fingerprint 2>/dev/null || return 1
  return 0
}

cert_expiry_days_left() {
  # prints integer days left, or empty on error
  if ! have_cmd openssl; then
    echo ""
    return 0
  fi
  if [[ ! -f "${CERT_FULLCHAIN}" ]]; then
    echo ""
    return 0
  fi

  local end end_ts cur_ts diff
  end="$(openssl x509 -in "${CERT_FULLCHAIN}" -noout -enddate 2>/dev/null | sed -e 's/^notAfter=//' || true)"
  if [[ -z "${end}" ]]; then
    echo ""
    return 0
  fi

  end_ts="$(date -d "${end}" +%s 2>/dev/null || true)"
  cur_ts="$(date +%s 2>/dev/null || true)"
  if [[ -z "${end_ts}" || -z "${cur_ts}" ]]; then
    echo ""
    return 0
  fi
  diff=$(( (end_ts - cur_ts) / 86400 ))
  echo "${diff}"
}

cert_menu_show_info() {
  title
  echo "TLS & Cert > Cert Info"
  hr
  if ! cert_openssl_info; then
    warn "Gagal membaca info sertifikat"
  fi
  hr
  pause
}

cert_menu_check_expiry() {
  title
  echo "TLS & Cert > Check Expiry"
  hr
  local days
  days="$(cert_expiry_days_left)"
  if [[ -z "${days}" ]]; then
    warn "Tidak dapat menghitung masa berlaku TLS"
  else
    if (( days < 0 )); then
      echo "TLS Expiry : Expired"
    else
      echo "TLS Expiry : ${days} days"
    fi
  fi
  hr
  pause
}

acme_sh_path_get() {
  if [[ -x "/root/.acme.sh/acme.sh" ]]; then
    echo "/root/.acme.sh/acme.sh"
    return 0
  fi
  if have_cmd acme.sh; then
    command -v acme.sh
    return 0
  fi
  echo ""
}

cert_runtime_restart_active_tls_consumers() {
  if [[ "${DOMAIN_CTRL_RUNTIME_SNAPSHOT_VALID:-0}" == "1" ]]; then
    domain_control_restore_tls_runtime_consumers_from_snapshot || return $?
    cert_runtime_tls_consumers_health_check || return 1
    return 0
  fi
  local edge_svc=""
  if svc_exists sshws-stunnel && svc_is_active sshws-stunnel; then
    systemctl restart sshws-stunnel >/dev/null 2>&1 || return 1
    svc_is_active sshws-stunnel || return 1
  fi
  if edge_runtime_enabled_for_public_ports; then
    edge_svc="$(edge_runtime_service_name 2>/dev/null || true)"
    if [[ -n "${edge_svc}" && "${edge_svc}" != "nginx" ]] && svc_exists "${edge_svc}" && svc_is_active "${edge_svc}"; then
      edge_runtime_post_restart_health_check || return 1
    fi
  fi
  cert_runtime_tls_consumers_health_check || return 1
  return 0
}

cert_runtime_tls_consumers_health_check() {
  local -a failed=()
  local stunnel_port="" stunnel_probe="" edge_svc="" http_port="" tls_port=""

  if svc_exists sshws-stunnel && svc_is_active sshws-stunnel; then
    stunnel_port="$(sshws_detect_stunnel_port 2>/dev/null || true)"
    if [[ "${stunnel_port}" =~ ^[0-9]+$ ]]; then
      stunnel_probe="$(sshws_probe_tcp_endpoint "127.0.0.1" "${stunnel_port}" "tls")"
      if ! sshws_probe_result_is_healthy "${stunnel_probe}"; then
        warn "Probe TLS consumer sshws-stunnel gagal: $(sshws_probe_result_disp "${stunnel_probe}")"
        failed+=("sshws-stunnel")
      fi
    fi
  fi

  if edge_runtime_enabled_for_public_ports; then
    edge_svc="$(edge_runtime_service_name 2>/dev/null || true)"
    if [[ -n "${edge_svc}" && "${edge_svc}" != "nginx" ]] && svc_exists "${edge_svc}" && svc_is_active "${edge_svc}"; then
      http_port="$(edge_runtime_get_env EDGE_PUBLIC_HTTP_PORT 2>/dev/null || echo "80")"
      tls_port="$(edge_runtime_get_env EDGE_PUBLIC_TLS_PORT 2>/dev/null || echo "443")"
      if ! edge_runtime_socket_listening "${http_port}"; then
        warn "Port HTTP publik ${http_port} belum listening setelah refresh consumer TLS."
        failed+=("edge-http")
      fi
      if ! edge_runtime_socket_listening "${tls_port}"; then
        warn "Port TLS publik ${tls_port} belum listening setelah refresh consumer TLS."
        failed+=("edge-tls")
      fi
    fi
  fi

  (( ${#failed[@]} == 0 ))
}

cert_runtime_hostname_tls_handshake_check() {
  local domain="${1:-}"
  local probe_output="" rc=0 endpoint="" label=""

  [[ -n "${domain}" ]] || domain="$(detect_domain)"
  [[ -n "${domain}" ]] || {
    warn "Domain aktif tidak terdeteksi untuk probe TLS hostname."
    return 1
  }
  if ! have_cmd openssl; then
    warn "openssl tidak tersedia, skip probe TLS hostname ${domain}."
    return 0
  fi

  for endpoint in "${domain}:443" "127.0.0.1:443"; do
    if [[ "${endpoint}" == "${domain}:443" ]]; then
      label="public"
    else
      label="local"
    fi
    if have_cmd timeout; then
      probe_output="$(timeout 15 openssl s_client -servername "${domain}" -connect "${endpoint}" -verify_hostname "${domain}" -verify_return_error < /dev/null 2>&1)"
      rc=$?
    else
      probe_output="$(openssl s_client -servername "${domain}" -connect "${endpoint}" -verify_hostname "${domain}" -verify_return_error < /dev/null 2>&1)"
      rc=$?
    fi
    if (( rc != 0 )) || ! printf '%s\n' "${probe_output}" | grep -Eq 'Verification: OK|Verify return code: 0 \(ok\)'; then
      warn "Probe TLS hostname ${label} gagal untuk ${domain} via ${endpoint}."
      printf '%s\n' "${probe_output}" >&2
      return 1
    fi
  done
  return 0
}

cert_menu_renew() {
  title
  echo "TLS & Cert > Renew Certificate"
  hr

  local acme
  acme="$(acme_sh_path_get)"
  if [[ -z "${acme}" ]]; then
    warn "acme.sh tidak ditemukan. Pastikan setup.sh sudah memasang acme.sh."
    hr
    pause
    return 0
  fi

  export PATH="/root/.acme.sh:${PATH}"
  local domain
  domain="$(detect_domain)"
  if [[ -z "${domain}" ]]; then
    warn "Domain aktif tidak terdeteksi."
    hr
    pause
    return 0
  fi
  if ! cert_renew_service_recover_if_needed; then
    hr
    pause
    return 1
  fi
  if [[ -s "${CERT_RENEW_CERT_JOURNAL_FILE}" ]]; then
    warn "Terdapat recovery rollback cert renew yang tertunda. Gunakan menu 'Recover Pending Renew' sebelum renew ulang."
    hr
    pause
    return 1
  fi

  echo "Domain terdeteksi: ${domain}"
  echo "Catatan       : bila port 80 bentrok, renew sekarang fail-closed dan tidak menghentikan service publik otomatis."
  hr
  if ! cert_runtime_hostname_tls_handshake_check "${domain}" >/dev/null 2>&1; then
    warn "Runtime TLS hostname untuk ${domain} belum sehat sebelum renew."
    warn "Renew dibatalkan agar perubahan cert baru tidak diterapkan di atas baseline runtime yang sudah bermasalah."
    warn "Perbaiki dulu runtime TLS atau jalankan 'Recover Pending Renew' bila memang ada recovery tertunda."
    hr
    pause
    return 1
  fi
  if ! confirm_menu_apply_now "Jalankan renew certificate untuk domain ${domain} sekarang?"; then
    hr
    pause
    return 0
  fi
  local renew_ack=""
  read -r -p "Ketik persis 'RENEW CERT ${domain}' untuk lanjut renew certificate (atau kembali): " renew_ack
  if is_back_choice "${renew_ack}"; then
    warn "Renew certificate dibatalkan pada checkpoint final."
    hr
    pause
    return 0
  fi
  if [[ "${renew_ack}" != "RENEW CERT ${domain}" ]]; then
    warn "Konfirmasi renew certificate tidak cocok. Dibatalkan."
    hr
    pause
    return 0
  fi
  echo "Menjalankan acme.sh renew untuk domain aktif..."
  echo

  local renew_ok="false"
  local port80_conflict="false"
  local renew_log
  local cert_backup_dir=""
  local -a rollback_notes=()
  local -a conflict_services=()
  renew_log="$(mktemp)"

  domain_control_clear_stopped_services
  domain_control_capture_runtime_snapshot
  cert_backup_dir="${WORK_DIR}/cert-renew-snapshot.$(date +%s).$$"
  if ! acme_install_targets_pin_live "${domain}" "${CERT_FULLCHAIN}" "${CERT_PRIVKEY}"; then
    warn "Gagal menyelaraskan target install acme.sh ke path cert live sebelum renew."
    rm -f "${renew_log}" >/dev/null 2>&1 || true
    rm -rf "${cert_backup_dir}" >/dev/null 2>&1 || true
    domain_control_clear_runtime_snapshot
    hr
    pause
    return 1
  fi
  if ! cert_snapshot_create "${cert_backup_dir}"; then
    warn "Gagal membuat snapshot sertifikat sebelum renew."
    rm -f "${renew_log}" >/dev/null 2>&1 || true
    domain_control_clear_runtime_snapshot
    hr
    pause
    return 1
  fi

  if "${acme}" --renew -d "${domain}" --force 2>&1 | tee "${renew_log}"; then
    renew_ok="true"
  else
    if grep -Eqi "port 80 is already used|Please stop it first" "${renew_log}"; then
      port80_conflict="true"
    fi
  fi
  rm -f "${renew_log}" >/dev/null 2>&1 || true

  if [[ "${renew_ok}" != "true" ]]; then
    if [[ "${port80_conflict}" == "true" ]]; then
      local svc edge_svc=""
      for svc in nginx apache2 caddy lighttpd; do
        if svc_exists "${svc}" && svc_is_active "${svc}"; then
          conflict_services+=("${svc}")
        fi
      done
      if edge_runtime_enabled_for_public_ports; then
        edge_svc="$(edge_runtime_service_name 2>/dev/null || true)"
        if [[ -n "${edge_svc}" && "${edge_svc}" != "nginx" ]] && svc_exists "${edge_svc}" && svc_is_active "${edge_svc}"; then
          conflict_services+=("${edge_svc}")
        fi
      fi
      warn "Terdeteksi konflik port 80. Renew certificate sekarang fail-closed dan tidak lagi menghentikan service publik otomatis."
      if (( ${#conflict_services[@]} > 0 )); then
        printf 'Service aktif yang memakai port 80: %s\n' "$(IFS=', '; echo "${conflict_services[*]}")"
      fi
      warn "Bebaskan port 80 secara manual lalu jalankan renew lagi."
      rm -rf "${cert_backup_dir}" >/dev/null 2>&1 || true
      domain_control_clear_stopped_services
      cert_renew_service_journal_clear
      domain_control_clear_runtime_snapshot
      hr
      pause
      return 1
    else
      warn "acme.sh renew domain aktif gagal."
    fi
  fi

  if [[ "${renew_ok}" != "true" ]]; then
    warn "Renew gagal. Cek output di atas."
    rm -rf "${cert_backup_dir}" >/dev/null 2>&1 || true
    domain_control_clear_stopped_services
    cert_renew_service_journal_clear
    domain_control_clear_runtime_snapshot
    hr
    pause
    return 1
  fi

  echo
  if ! cert_runtime_restart_active_tls_consumers; then
    warn "Restart consumer TLS tambahan gagal. Mencoba retry sekali lagi sebelum rollback cert..."
    sleep 2
  fi
  if ! cert_runtime_restart_active_tls_consumers; then
    warn "Cert berhasil diperbarui, tetapi restart consumer TLS tambahan gagal. Mencoba rollback cert sebelumnya..."
    cert_snapshot_restore "${cert_backup_dir}" >/dev/null 2>&1 || rollback_notes+=("restore sertifikat gagal")
    domain_control_restore_cert_runtime_after_rollback rollback_notes || true
    if (( ${#rollback_notes[@]} > 0 )); then
      warn "Rollback cert juga bermasalah: ${rollback_notes[*]}"
      if cert_renew_cert_journal_write "${domain}" "${cert_backup_dir}"; then
        warn "Journal recovery rollback cert disimpan. Gunakan menu 'Recover Pending Renew' untuk melanjutkan."
        cert_backup_dir=""
      else
        warn "Gagal menyimpan journal recovery rollback cert. Snapshot cert dipertahankan di ${cert_backup_dir}."
      fi
      if cert_renew_cert_recover_if_needed >/dev/null 2>&1; then
        log "Rollback cert berhasil diselesaikan langsung pada flow renew ini."
        warn "Renew cert dibatalkan, tetapi runtime TLS sudah dipulihkan kembali."
      fi
    else
      cert_renew_cert_journal_clear
      log "Runtime TLS berhasil dipulihkan ke snapshot cert sebelumnya."
    fi
    [[ -n "${cert_backup_dir}" ]] && rm -rf "${cert_backup_dir}" >/dev/null 2>&1 || true
    domain_control_clear_stopped_services
    domain_control_clear_runtime_snapshot
    hr
    pause
    return 1
  fi
  if ! cert_runtime_hostname_tls_handshake_check "${domain}"; then
    warn "Probe TLS hostname gagal. Mencoba retry sekali lagi sebelum rollback cert..."
    sleep 2
  fi
  if ! cert_runtime_hostname_tls_handshake_check "${domain}"; then
    warn "Cert berhasil diperbarui, tetapi probe TLS hostname gagal. Mencoba rollback cert sebelumnya..."
    cert_snapshot_restore "${cert_backup_dir}" >/dev/null 2>&1 || rollback_notes+=("restore sertifikat gagal")
    domain_control_restore_cert_runtime_after_rollback rollback_notes || true
    if (( ${#rollback_notes[@]} > 0 )); then
      warn "Rollback cert juga bermasalah: ${rollback_notes[*]}"
      if cert_renew_cert_journal_write "${domain}" "${cert_backup_dir}"; then
        warn "Journal recovery rollback cert disimpan. Gunakan menu 'Recover Pending Renew' untuk melanjutkan."
        cert_backup_dir=""
      else
        warn "Gagal menyimpan journal recovery rollback cert. Snapshot cert dipertahankan di ${cert_backup_dir}."
      fi
      if cert_renew_cert_recover_if_needed >/dev/null 2>&1; then
        log "Rollback cert berhasil diselesaikan langsung pada flow renew ini."
        warn "Renew cert dibatalkan, tetapi runtime TLS sudah dipulihkan kembali."
      fi
    else
      cert_renew_cert_journal_clear
      log "Runtime TLS berhasil dipulihkan ke snapshot cert sebelumnya."
    fi
    [[ -n "${cert_backup_dir}" ]] && rm -rf "${cert_backup_dir}" >/dev/null 2>&1 || true
    domain_control_clear_stopped_services
    domain_control_clear_runtime_snapshot
    hr
    pause
    return 1
  fi
  rm -rf "${cert_backup_dir}" >/dev/null 2>&1 || true
  domain_control_clear_stopped_services
  cert_renew_service_journal_clear
  cert_renew_cert_journal_clear
  domain_control_clear_runtime_snapshot
  log "Renew certificate selesai (cek expiry untuk memastikan)."
  hr
  pause
}

cert_menu_reload_nginx() {
  title
  echo "TLS & Cert > Reload Nginx"
  hr
  if ! svc_exists nginx; then
    warn "nginx.service tidak terdeteksi"
    hr
    pause
    return 0
  fi

  if ! confirm_menu_apply_now "Reload nginx sekarang?"; then
    hr
    pause
    return 0
  fi

  if have_cmd nginx && ! nginx -t >/dev/null 2>&1; then
    warn "nginx -t gagal. Reload/restart dibatalkan."
    hr
    pause
    return 1
  fi

  if systemctl reload nginx 2>/dev/null && svc_is_active nginx && nginx_service_listener_health_check; then
    local domain=""
    domain="$(detect_domain 2>/dev/null || true)"
    if [[ -n "${domain}" ]] && ! cert_runtime_hostname_tls_handshake_check "${domain}"; then
      warn "nginx reload lolos, tetapi probe TLS hostname gagal."
      hr
      pause
      return 1
    fi
    log "nginx reload: OK"
  else
    warn "nginx reload gagal."
    if ! confirm_menu_apply_now "Reload gagal. Lanjutkan dengan restart penuh nginx sekarang?"; then
      hr
      pause
      return 1
    fi
    if have_cmd nginx && ! nginx -t >/dev/null 2>&1; then
      warn "nginx -t gagal sebelum restart fallback."
      hr
      pause
      return 1
    fi
    if nginx_restart_checked_with_listener; then
      local domain=""
      domain="$(detect_domain 2>/dev/null || true)"
      if [[ -n "${domain}" ]] && ! cert_runtime_hostname_tls_handshake_check "${domain}"; then
        warn "nginx restart lolos, tetapi probe TLS hostname gagal."
        hr
        pause
        return 1
      fi
      log "nginx restart: OK"
    else
      warn "nginx masih tidak aktif"
      hr
      pause
      return 1
    fi
  fi
  hr
  pause
}

security_tls_menu() {
  local pending_recovery="false"
  while true; do
    pending_recovery="false"
    [[ -s "${CERT_RENEW_SERVICE_JOURNAL_FILE}" ]] && pending_recovery="true"
    [[ -s "${CERT_RENEW_CERT_JOURNAL_FILE}" ]] && pending_recovery="true"
    title
    echo "TLS & Cert"
    if [[ "${pending_recovery}" == "true" ]]; then
      hr
      warn "Terdapat recovery renew yang tertunda. Gunakan menu 'Recover Pending Renew'."
    fi
    hr
    echo "  1) Cert Info"
    echo "  2) Check Expiry"
    echo "  3) Renew Cert"
    echo "  4) Reload Nginx"
    echo "  5) Recover Pending Renew"
    echo "  0) Back"
    hr
    if ! read -r -p "Pilih: " c; then
      echo
      break
    fi
    case "${c}" in
      1) cert_menu_show_info ;;
      2) cert_menu_check_expiry ;;
      3) cert_menu_renew ;;
      4) cert_menu_reload_nginx ;;
      5)
        local recover_failed="false"
        if ! cert_renew_service_recover_if_needed; then
          recover_failed="true"
        fi
        if ! cert_renew_cert_recover_if_needed; then
          recover_failed="true"
        fi
        if [[ "${recover_failed}" != "true" ]]; then
          log "Recovery renew selesai atau tidak ada journal tertunda."
        else
          warn "Recovery renew belum bersih."
        fi
        pending_recovery="false"
        [[ -s "${CERT_RENEW_SERVICE_JOURNAL_FILE}" ]] && pending_recovery="true"
        [[ -s "${CERT_RENEW_CERT_JOURNAL_FILE}" ]] && pending_recovery="true"
        pause
        ;;
      0|kembali|k|back|b) break ;;
      *) warn "Pilihan tidak valid" ; sleep 1 ;;
    esac
  done
}

fail2ban_client_ready() {
  if ! have_cmd fail2ban-client; then
    return 1
  fi
  return 0
}

fail2ban_jails_list_get() {
  # prints jail names one per line
  if ! fail2ban_client_ready; then
    return 0
  fi
  local out line
  out="$(fail2ban-client status 2>/dev/null || true)"
  [[ -n "${out}" ]] || return 0

  # Format output fail2ban bisa memakai prefix "|-" atau "`-" dan separator
  # setelah ":" bisa berupa spasi/tab, jadi parsing harus longgar.
  line="$(printf '%s\n' "${out}" | sed -nE 's/.*[Jj]ail list[[:space:]]*:[[:space:]]*//p' | head -n1)"
  line="${line//$'\r'/}"
  [[ -n "${line}" ]] || return 0

  printf '%s\n' "${line}" \
    | tr ',' '\n' \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
    | grep -E '.+' || true
}

fail2ban_jail_banned_counts_get() {
  # args: jail -> prints: current|total
  local jail="$1"
  if ! fail2ban_client_ready; then
    echo "0|0"
    return 0
  fi
  local out cur tot
  out="$(fail2ban-client status "${jail}" 2>/dev/null || true)"
  # Output fail2ban bisa memakai tab/spasi campuran setelah ":".
  # Parsing dibuat longgar agar "Currently banned" dan "Total banned" selalu terbaca.
  cur="$(printf '%s\n' "${out}" | sed -nE 's/.*Currently banned:[[:space:]]*([0-9]+).*/\1/p' | head -n1)"
  tot="$(printf '%s\n' "${out}" | sed -nE 's/.*Total banned:[[:space:]]*([0-9]+).*/\1/p' | head -n1)"
  [[ -n "${cur}" ]] || cur="0"
  [[ -n "${tot}" ]] || tot="0"
  echo "${cur}|${tot}"
}

fail2ban_total_banned_get() {
  if ! fail2ban_client_ready; then
    echo "0"
    return 0
  fi
  local total=0 jail counts cur
  while IFS= read -r jail; do
    counts="$(fail2ban_jail_banned_counts_get "${jail}")"
    cur="${counts%%|*}"
    [[ "${cur}" =~ ^[0-9]+$ ]] || cur=0
    total=$((total + cur))
  done < <(fail2ban_jails_list_get)
  echo "${total}"
}

fail2ban_menu_show_jail_status() {
  title
  echo "Fail2ban > Jail Status"
  hr

  if ! svc_exists fail2ban; then
    warn "fail2ban.service tidak terdeteksi"
  fi

  if ! fail2ban_client_ready; then
    warn "fail2ban-client tidak tersedia"
    hr
    pause
    return 0
  fi

  fail2ban-client status 2>/dev/null || true
  hr

  local jails=()
  while IFS= read -r j; do
    [[ -n "${j}" ]] && jails+=("${j}")
  done < <(fail2ban_jails_list_get)

  if (( ${#jails[@]} == 0 )); then
    warn "Tidak ada jail yang terdeteksi."
    hr
    pause
    return 0
  fi

  printf "%-30s %-12s %-12s\n" "JAIL" "BANNED" "TOTAL"
  printf "%-30s %-12s %-12s\n" "------------------------------" "------------" "------------"
  local jail counts cur tot
  for jail in "${jails[@]}"; do
    counts="$(fail2ban_jail_banned_counts_get "${jail}")"
    cur="${counts%%|*}"
    tot="${counts##*|}"
    printf "%-30s %-12s %-12s\n" "${jail}" "${cur}" "${tot}"
  done
  hr
  pause
}

fail2ban_menu_show_banned_ip() {
  title
  echo "Fail2ban > Banned IP"
  hr
  if ! fail2ban_client_ready; then
    warn "fail2ban-client tidak tersedia"
    hr
    pause
    return 0
  fi

  local jails=()
  while IFS= read -r j; do
    [[ -n "${j}" ]] && jails+=("${j}")
  done < <(fail2ban_jails_list_get)

  if (( ${#jails[@]} == 0 )); then
    warn "Tidak ada jail yang terdeteksi."
    hr
    pause
    return 0
  fi

  local jail ips
  for jail in "${jails[@]}"; do
    echo "[${jail}]"
    ips="$(fail2ban-client get "${jail}" banip 2>/dev/null || true)"
    if [[ -z "${ips}" ]]; then
      echo "  (kosong)"
    else
      echo "${ips}" | tr ' ' '\n' | sed -E 's/^/  - /'
    fi
    echo
  done
  hr
  pause
}

fail2ban_menu_unban_ip() {
  title
  echo "Fail2ban > Unban IP"
  hr
  if ! fail2ban_client_ready; then
    warn "fail2ban-client tidak tersedia"
    hr
    pause
    return 0
  fi

  local jails=()
  while IFS= read -r j; do
    [[ -n "${j}" ]] && jails+=("${j}")
  done < <(fail2ban_jails_list_get)

  if (( ${#jails[@]} == 0 )); then
    warn "Tidak ada jail yang terdeteksi."
    hr
    pause
    return 0
  fi

  echo "Daftar jail:"
  local i
  for i in "${!jails[@]}"; do
    printf "  %d) %s\n" "$((i + 1))" "${jails[$i]}"
  done
  echo "  0) Back"
  hr

  if ! read -r -p "Pilih jail (1-${#jails[@]}/0): " c; then
    echo
    return 0
  fi
  if is_back_choice "${c}"; then
    return 0
  fi
  [[ "${c}" =~ ^[0-9]+$ ]] || { warn "Input bukan angka"; pause; return 0; }
  if (( c < 1 || c > ${#jails[@]} )); then
    warn "Pilihan jail di luar range"
    pause
    return 0
  fi
  local jail
  jail="${jails[$((c - 1))]}"

  if ! read -r -p "IP yang ingin di-unban (atau kembali): " ip; then
    echo
    return 0
  fi
  if is_back_choice "${ip}"; then
    return 0
  fi
  ip="$(ip_literal_normalize "${ip}")" || {
    warn "IP tidak valid. Gunakan IPv4/IPv6 literal."
    pause
    return 0
  }

  if ! confirm_menu_apply_now "Unban IP ${ip} dari jail ${jail} sekarang?"; then
    pause
    return 0
  fi

  if fail2ban-client set "${jail}" unbanip "${ip}" 2>/dev/null; then
    log "Unban sukses: ${ip} (${jail})"
  else
    warn "Unban gagal. Pastikan jail & IP valid."
  fi
  hr
  pause
}

fail2ban_post_restart_health_check() {
  local jail
  local -a expected_jails=("$@")
  local status_out=""

  if ! svc_restart_checked fail2ban 20; then
    warn "fail2ban gagal direstart (state=$(svc_state fail2ban || echo unknown))"
    return 1
  fi
  if ! fail2ban_client_ready; then
    warn "fail2ban-client tidak tersedia setelah restart."
    return 1
  fi
  status_out="$(fail2ban-client status 2>/dev/null || true)"
  if [[ -z "${status_out}" ]]; then
    warn "fail2ban-client status kosong setelah restart."
    return 1
  fi
  for jail in "${expected_jails[@]}"; do
    [[ -n "${jail}" ]] || continue
    if ! fail2ban_jail_active_bool "${jail}"; then
      warn "Jail fail2ban belum aktif setelah restart: ${jail}"
      return 1
    fi
  done
  return 0
}

fail2ban_menu_restart() {
  title
  echo "Fail2ban > Restart"
  hr
  local jail=""
  if ! svc_exists fail2ban; then
    warn "fail2ban.service tidak terdeteksi"
    hr
    pause
    return 0
  fi

  local jails=()
  while IFS= read -r jail; do
    [[ -n "${jail}" ]] && jails+=("${jail}")
  done < <(fail2ban_jails_list_get)

  if ! confirm_menu_apply_now "Restart fail2ban sekarang?"; then
    pause
    return 0
  fi

  if fail2ban_post_restart_health_check "${jails[@]}"; then
    log "fail2ban: active"
  else
    warn "fail2ban restart health-check gagal."
  fi
  hr
  pause
}

security_fail2ban_menu() {
  while true; do
    title
    echo "Fail2ban"
    hr
    echo "  1) Jail Status"
    echo "  2) Banned IP"
    echo "  3) Unban IP"
    echo "  4) Restart Fail2ban"
    echo "  0) Back"
    hr
    if ! read -r -p "Pilih: " c; then
      echo
      break
    fi
    case "${c}" in
      1) fail2ban_menu_show_jail_status ;;
      2) fail2ban_menu_show_banned_ip ;;
      3) fail2ban_menu_unban_ip ;;
      4) fail2ban_menu_restart ;;
      0|kembali|k|back|b) break ;;
      *) warn "Pilihan tidak valid" ; sleep 1 ;;
    esac
  done
}

hardening_check_bbr() {
  title
  echo "Hardening > BBR"
  hr
  if ! have_cmd sysctl; then
    warn "sysctl tidak tersedia"
    hr
    pause
    return 0
  fi

  local cc qdisc
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
  qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"

  echo "tcp_congestion_control : ${cc:-"-"}"
  echo "default_qdisc          : ${qdisc:-"-"}"
  echo
  if [[ "${cc}" == "bbr" ]]; then
    echo "BBR : Enabled"
  else
    echo "BBR : Disabled"
  fi
  hr
  pause
}

swap_status_pretty_get() {
  # prints: "<n>GB Active" or "Disabled"
  if ! have_cmd free; then
    echo "Unknown"
    return 0
  fi
  local bytes
  bytes="$(free -b 2>/dev/null | awk '/^Swap:/ {print $2; exit}' || true)"
  [[ -n "${bytes}" ]] || bytes="0"
  if [[ ! "${bytes}" =~ ^[0-9]+$ ]]; then
    bytes="0"
  fi
  if (( bytes <= 0 )); then
    echo "Disabled"
    return 0
  fi
  local gb
  gb=$(( (bytes + 1024**3 - 1) / (1024**3) ))
  echo "${gb}GB Active"
}

hardening_check_swap() {
  title
  echo "Hardening > Swap"
  hr
  if ! have_cmd free; then
    warn "free tidak tersedia"
    hr
    pause
    return 0
  fi

  free -h || true
  hr
  echo "Swap : $(swap_status_pretty_get)"
  hr
  pause
}

hardening_check_ulimit() {
  title
  echo "Hardening > Ulimit"
  hr
  local cur
  cur="$(ulimit -n 2>/dev/null || echo "-")"
  echo "Shell ulimit -n : ${cur}"
  echo
  if svc_exists xray; then
    local lim
    lim="$(systemctl show -p LimitNOFILE --value xray 2>/dev/null || true)"
    echo "xray LimitNOFILE: ${lim:-"-"}"
  fi
  hr
  pause
}

hardening_check_chrony() {
  title
  echo "Hardening > Chrony"
  hr
  if svc_exists chrony; then
    svc_status_line chrony
    hr
    systemctl status chrony --no-pager || true
  elif svc_exists chronyd; then
    svc_status_line chronyd
    hr
    systemctl status chronyd --no-pager || true
  else
    warn "chrony/chronyd service tidak terdeteksi"
  fi
  hr
  pause
}

security_hardening_menu() {
  while true; do
    title
    echo "Hardening"
    hr
    echo "  1) BBR"
    echo "  2) Swap"
    echo "  3) Ulimit"
    echo "  4) Chrony"
    echo "  0) Back"
    hr
    if ! read -r -p "Pilih: " c; then
      echo
      break
    fi
    case "${c}" in
      1) hardening_check_bbr ;;
      2) hardening_check_swap ;;
      3) hardening_check_ulimit ;;
      4) hardening_check_chrony ;;
      0|kembali|k|back|b) break ;;
      *) warn "Pilihan tidak valid" ; sleep 1 ;;
    esac
  done
}

bbr_enabled_bool() {
  if ! have_cmd sysctl; then
    return 1
  fi
  local cc
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
  [[ "${cc}" == "bbr" ]]
}

fail2ban_jail_active_bool() {
  # args: jail name
  local jail="$1"
  if ! fail2ban_client_ready; then
    return 1
  fi
  fail2ban-client status "${jail}" >/dev/null 2>&1
}

security_overview_menu() {
  title
  echo "Overview"
  hr

  local tls_days tls_line
  tls_days="$(cert_expiry_days_left)"
  if [[ -z "${tls_days}" ]]; then
    tls_line="-"
  else
    if (( tls_days < 0 )); then
      tls_line="Expired"
    else
      tls_line="${tls_days} days"
    fi
  fi

  local f2b_line banned ssh_line nginx_line rec_line
  if svc_is_active fail2ban 2>/dev/null; then
    f2b_line="Active"
  else
    f2b_line="Inactive"
  fi

  banned="$(fail2ban_total_banned_get)"
  [[ -n "${banned}" ]] || banned="0"

  if fail2ban_jail_active_bool sshd; then
    ssh_line="Active"
  else
    ssh_line="Inactive"
  fi

  if fail2ban_jail_active_bool nginx-bad-request-access || fail2ban_jail_active_bool nginx-bad-request-error; then
    nginx_line="Active"
  else
    nginx_line="Inactive"
  fi

  if fail2ban_jail_active_bool recidive; then
    rec_line="Active"
  else
    rec_line="Inactive"
  fi

  local bbr_line
  if bbr_enabled_bool; then
    bbr_line="Enabled"
  else
    bbr_line="Disabled"
  fi

  local swap_line
  swap_line="$(swap_status_pretty_get)"

  local edge_svc edge_line xray_svc_line nginx_svc_line ssh_svc_line
  edge_svc="$(main_menu_edge_service_name)"
  if svc_exists "${edge_svc}" && svc_is_active "${edge_svc}"; then
    edge_line="Active"
  else
    edge_line="Inactive"
  fi
  if svc_exists xray && svc_is_active xray; then
    xray_svc_line="Active"
  else
    xray_svc_line="Inactive"
  fi
  if svc_exists nginx && svc_is_active nginx; then
    nginx_svc_line="Active"
  else
    nginx_svc_line="Inactive"
  fi
  if svc_exists "${SSHWS_DROPBEAR_SERVICE}" && svc_is_active "${SSHWS_DROPBEAR_SERVICE}" \
    && svc_exists "${SSHWS_STUNNEL_SERVICE}" && svc_is_active "${SSHWS_STUNNEL_SERVICE}" \
    && svc_exists "${SSHWS_PROXY_SERVICE}" && svc_is_active "${SSHWS_PROXY_SERVICE}"; then
    ssh_svc_line="Active"
  else
    ssh_svc_line="Inactive"
  fi

  echo
  echo "TLS Expiry        : ${tls_line}"
  echo "Fail2ban          : ${f2b_line}"
  echo "Banned IP         : ${banned}"
  echo "SSH Protection    : ${ssh_line}"
  echo "Nginx Protection  : ${nginx_line}"
  echo "Recidive          : ${rec_line}"
  echo "BBR               : ${bbr_line}"
  echo "Swap              : ${swap_line}"
  hr
  echo "Core Services"
  echo "Edge Mux          : ${edge_line}"
  echo "Nginx             : ${nginx_svc_line}"
  echo "Xray              : ${xray_svc_line}"
  echo "SSH               : ${ssh_svc_line}"
  hr
  pause
}

fail2ban_menu() {
  local -a items=(
    "1|TLS & Cert"
    "2|Fail2ban"
    "3|Hardening"
    "4|Overview"
    "0|Back"
  )
  while true; do
    ui_menu_screen_begin "10) Security"
    ui_menu_render_options items 76
    hr
    if ! read -r -p "Pilih: " c; then
      echo
      break
    fi
    case "${c}" in
      1) security_tls_menu ;;
      2) security_fail2ban_menu ;;
      3) security_hardening_menu ;;
      4) security_overview_menu ;;
      0|kembali|k|back|b) break ;;
      *) warn "Pilihan tidak valid" ; sleep 1 ;;
    esac
  done
}

