# shellcheck shell=bash
# Maintenance
# -------------------------
maintenance_restore_service_state_exact() {
  local svc="$1"
  local should_be_active="$2"
  case "${should_be_active}" in
    true)
      svc_exists "${svc}" || return 0
      if svc_is_active "${svc}"; then
        return 0
      fi
      if [[ "${svc}" == "xray" ]]; then
        xray_restart_checked_with_preflight >/dev/null 2>&1
      elif [[ "${svc}" == "nginx" ]]; then
        nginx_restart_checked_with_listener >/dev/null 2>&1
      else
        svc_start_checked "${svc}" 30 >/dev/null 2>&1
      fi
      ;;
    false)
      if svc_exists "${svc}" && svc_is_active "${svc}"; then
        svc_stop_checked "${svc}" 30 >/dev/null 2>&1
      else
        return 0
      fi
      ;;
    *)
      return 1
      ;;
  esac
}

maintenance_core_runtime_health_check() {
  local domain=""
  if svc_exists xray && ! svc_is_active xray; then
    warn "Post-check restart core: xray belum active."
    return 1
  fi
  if svc_exists nginx && ! svc_is_active nginx; then
    warn "Post-check restart core: nginx belum active."
    return 1
  fi
  domain="$(normalize_domain_token "$(detect_domain 2>/dev/null || true)")"
  if [[ -n "${domain}" ]] && declare -F cert_runtime_hostname_tls_handshake_check >/dev/null 2>&1; then
    if ! cert_runtime_hostname_tls_handshake_check "${domain}" >/dev/null 2>&1; then
      warn "Post-check restart core: probe TLS hostname untuk ${domain} gagal."
      return 1
    fi
  fi
  return 0
}

maintenance_restart_core_now() {
  local xray_was_active="false"
  local nginx_was_active="false"
  local restart_ack=""
  local pre_runtime_healthy="unknown"
  if svc_exists xray && svc_is_active xray; then
    xray_was_active="true"
  fi
  if svc_exists nginx && svc_is_active nginx; then
    nginx_was_active="true"
  fi
  if declare -F maintenance_core_runtime_health_check >/dev/null 2>&1; then
    if maintenance_core_runtime_health_check >/dev/null 2>&1; then
      pre_runtime_healthy="true"
    else
      pre_runtime_healthy="false"
    fi
  fi
  echo "Pre-check     : xray=${xray_was_active}, nginx=${nginx_was_active}, runtime_healthy=${pre_runtime_healthy}"
  if [[ "${pre_runtime_healthy}" == "false" ]]; then
    warn "Runtime sebelum restart core sudah terdeteksi tidak sehat."
    if ! confirm_menu_apply_now "Lanjutkan restart core dalam mode best-effort recovery juga?"; then
      warn "Restart core dibatalkan."
      return 0
    fi
  fi
  if ! confirm_menu_apply_now "Restart Core akan me-restart Xray dan Nginx. Recovery yang tersedia bersifat best-effort, bukan snapshot runtime penuh. Lanjutkan sekarang?"; then
    warn "Restart core dibatalkan."
    return 0
  fi
  read -r -p "Ketik persis 'RESTART CORE' untuk lanjut restart core (atau kembali): " restart_ack
  if is_back_choice "${restart_ack}"; then
    warn "Restart core dibatalkan."
    return 0
  fi
  if [[ "${restart_ack}" != "RESTART CORE" ]]; then
    warn "Konfirmasi restart core tidak cocok. Dibatalkan."
    return 0
  fi
  if have_cmd xray && ! xray_confdir_syntax_test; then
    warn "Syntax confdir Xray gagal. Restart core dibatalkan sebelum service disentuh."
    return 1
  fi
  if have_cmd nginx && ! nginx -t >/dev/null 2>&1; then
    warn "nginx -t gagal. Restart core dibatalkan sebelum service disentuh."
    return 1
  fi
  if ! xray_restart_checked_with_preflight; then
    warn "Restart core dibatalkan: restart xray gagal."
    return 1
  fi
  if ! nginx_restart_checked_with_listener; then
    warn "Restart nginx pertama gagal setelah xray berhasil direstart. Mencoba retry sekali lagi sebelum restore state..."
    sleep 2
  fi
  if ! nginx_restart_checked_with_listener; then
    warn "Restart core gagal setelah xray berhasil direstart: restart nginx gagal. Mencoba restore state service sebelumnya..."
    maintenance_restore_service_state_exact xray "${xray_was_active}" || true
    maintenance_restore_service_state_exact nginx "${nginx_was_active}" || true
    if [[ "${xray_was_active}" == "true" ]] && { ! svc_exists xray || ! svc_is_active xray; }; then
      warn "Restore state xray ke kondisi semula gagal."
      return 1
    fi
    if [[ "${xray_was_active}" != "true" ]] && svc_exists xray && svc_is_active xray; then
      warn "Restore state xray ke kondisi inactive semula gagal."
      return 1
    fi
    if [[ "${nginx_was_active}" == "true" ]] && { ! svc_exists nginx || ! svc_is_active nginx; }; then
      warn "Restore state nginx ke kondisi semula gagal."
      return 1
    fi
    if [[ "${nginx_was_active}" != "true" ]] && svc_exists nginx && svc_is_active nginx; then
      warn "Restore state nginx ke kondisi inactive semula gagal."
      return 1
    fi
    if [[ "${pre_runtime_healthy}" == "true" ]] && ! maintenance_core_runtime_health_check >/dev/null 2>&1; then
      warn "Runtime belum kembali ke kondisi sehat seperti sebelum restart core."
    fi
    return 1
  fi
  if ! maintenance_core_runtime_health_check; then
    sleep 2
  fi
  if ! maintenance_core_runtime_health_check; then
    warn "Restart core selesai, tetapi post-check runtime belum sehat. Mencoba restore state service sebelumnya..."
    maintenance_restore_service_state_exact xray "${xray_was_active}" || true
    maintenance_restore_service_state_exact nginx "${nginx_was_active}" || true
    if [[ "${pre_runtime_healthy}" == "true" ]] && maintenance_core_runtime_health_check >/dev/null 2>&1; then
      warn "Runtime berhasil dipulihkan lagi ke kondisi sehat semula setelah restore state service."
    elif [[ "${pre_runtime_healthy}" == "true" ]]; then
      warn "Runtime belum kembali ke kondisi sehat seperti sebelum restart core."
    fi
    return 1
  fi
  if [[ "${pre_runtime_healthy}" == "true" ]]; then
    log "Restart core selesai dan runtime sehat kembali."
  else
    warn "Restart core selesai. Runtime kini lolos post-check, tetapi aksi ini tetap memakai recovery best-effort."
  fi
  return 0
}

maintenance_restart_xray_now() {
  xray_restart_checked_with_preflight
}

maintenance_restart_nginx_now() {
  nginx_restart_checked_with_listener
}

maintenance_menu() {
  local -a items=(
    "1|Core Check"
    "2|Restart Xray"
    "3|Restart Nginx"
    "4|Restart Core (best-effort restore)"
    "5|Xray Logs"
    "6|Nginx Logs"
    "7|WARP Status"
    "8|Restart WARP"
    "9|Xray Daemons"
    "10|SSH WS Status"
    "11|Restart SSH WS"
    "12|SSH WS Diagnose"
    "13|OpenVPN Status"
    "14|Restart OpenVPN"
    "15|OpenVPN Logs"
    "16|Edge Status"
    "17|Restart Edge"
    "18|Edge Info"
    "19|BadVPN Status"
    "20|Restart BadVPN"
    "0|Back"
  )
  while true; do
    ui_menu_screen_begin "11) Maintenance"
    ui_menu_render_two_columns_fixed items
    hr
    if ! read -r -p "Pilih: " c; then
      echo
      break
    fi
    case "${c}" in
      1) sanity_check_now ;;
      2)
        if confirm_yn_or_back "Restart xray sekarang?"; then
          menu_run_isolated_report "Restart Xray" maintenance_restart_xray_now
        else
          warn "Restart xray dibatalkan."
        fi
        pause
        ;;
      3)
        if confirm_yn_or_back "Restart nginx sekarang?"; then
          menu_run_isolated_report "Restart Nginx" maintenance_restart_nginx_now
        else
          warn "Restart nginx dibatalkan."
        fi
        pause
        ;;
      4)
        if confirm_yn_or_back "Restart core service (xray + nginx) sekarang?"; then
          menu_run_isolated_report "Restart Core" maintenance_restart_core_now
        else
          warn "Restart core dibatalkan."
        fi
        pause
        ;;
      5) title ; tail_logs xray 160 ; hr ; pause ;;
      6) title ; tail_logs nginx 160 ; hr ; pause ;;
      7) menu_run_isolated_report "Wireproxy Status" wireproxy_status_menu ;;
      8) menu_run_isolated_report "Wireproxy Restart" wireproxy_restart_menu ;;
      9) menu_run_isolated_report "Daemon Status" daemon_status_menu ;;
      10) menu_run_isolated_report "SSHWS Status" ssh_runtime_context_run maintenance sshws_status_menu ;;
      11) menu_run_isolated_report "SSHWS Restart" ssh_runtime_context_run maintenance sshws_restart_menu ;;
      12) menu_run_isolated_report "SSHWS Diagnostics" ssh_runtime_context_run maintenance sshws_diagnostics_menu ;;
      13) menu_run_isolated_report "OpenVPN Status" openvpn_status_menu ;;
      14) menu_run_isolated_report "OpenVPN Restart" openvpn_restart_menu ;;
      15) menu_run_isolated_report "OpenVPN Logs" openvpn_logs_menu ;;
      16) menu_run_isolated_report "Edge Runtime Status" edge_runtime_status_menu ;;
      17) menu_run_isolated_report "Edge Runtime Restart" edge_runtime_restart_menu ;;
      18) menu_run_isolated_report "Edge Runtime Info" edge_runtime_info_menu ;;
      19) menu_run_isolated_report "BadVPN Status" badvpn_status_menu ;;
      20) menu_run_isolated_report "BadVPN Restart" badvpn_restart_menu ;;
      0|kembali|k|back|b) break ;;
      *) warn "Pilihan tidak valid" ; sleep 1 ;;
    esac
  done
}

# -------------------------
