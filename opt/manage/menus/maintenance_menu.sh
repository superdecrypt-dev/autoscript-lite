# shellcheck shell=bash
# Maintenance
# -------------------------
maintenance_menu() {
  local -a items=(
    "1|Restart Xray"
    "2|Restart Nginx"
    "3|Restart Core"
    "4|Xray Logs"
    "5|Nginx Logs"
    "6|WARP Status"
    "7|Restart WARP"
    "8|Xray Daemons"
    "9|SSH WS Status"
    "10|Restart SSH WS"
    "11|SSH WS Diagnose"
    "12|Edge Status"
    "13|Restart Edge"
    "14|Edge Info"
    "15|BadVPN Status"
    "16|Restart BadVPN"
    "0|Back"
  )
  while true; do
    ui_menu_screen_begin "10) Maintenance"
    ui_menu_render_options items 84
    hr
    if ! read -r -p "Pilih: " c; then
      echo
      break
    fi
    case "${c}" in
      1) svc_restart xray ; pause ;;
      2) svc_restart nginx ; pause ;;
      3) svc_restart xray ; svc_restart nginx ; pause ;;
      4) title ; tail_logs xray 160 ; hr ; pause ;;
      5) title ; tail_logs nginx 160 ; hr ; pause ;;
      6) wireproxy_status_menu ;;
      7) wireproxy_restart_menu ;;
      8) daemon_status_menu ;;
      9) sshws_status_menu ;;
      10) sshws_restart_menu ;;
      11) sshws_diagnostics_menu ;;
      12) edge_runtime_status_menu ;;
      13) edge_runtime_restart_menu ;;
      14) edge_runtime_info_menu ;;
      15) badvpn_status_menu ;;
      16) badvpn_restart_menu ;;
      0|kembali|k|back|b) break ;;
      *) warn "Pilihan tidak valid" ; sleep 1 ;;
    esac
  done
}

# -------------------------
