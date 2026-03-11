# shellcheck shell=bash
# Maintenance
# -------------------------
maintenance_menu() {
  local -a items=(
    "1|Core Check"
    "2|Restart Xray"
    "3|Restart Nginx"
    "4|Restart Core"
    "5|Xray Logs"
    "6|Nginx Logs"
    "7|WARP Status"
    "8|Restart WARP"
    "9|Xray Daemons"
    "10|SSH WS Status"
    "11|Restart SSH WS"
    "12|SSH WS Diagnose"
    "13|Edge Status"
    "14|Restart Edge"
    "15|Edge Info"
    "16|BadVPN Status"
    "17|Restart BadVPN"
    "0|Back"
  )
  while true; do
    ui_menu_screen_begin "9) Maintenance"
    ui_menu_render_two_columns_fixed items
    hr
    if ! read -r -p "Pilih: " c; then
      echo
      break
    fi
    case "${c}" in
      1) sanity_check_now ;;
      2) svc_restart xray ; pause ;;
      3) svc_restart nginx ; pause ;;
      4) svc_restart xray ; svc_restart nginx ; pause ;;
      5) title ; tail_logs xray 160 ; hr ; pause ;;
      6) title ; tail_logs nginx 160 ; hr ; pause ;;
      7) wireproxy_status_menu ;;
      8) wireproxy_restart_menu ;;
      9) daemon_status_menu ;;
      10) sshws_status_menu ;;
      11) sshws_restart_menu ;;
      12) sshws_diagnostics_menu ;;
      13) edge_runtime_status_menu ;;
      14) edge_runtime_restart_menu ;;
      15) edge_runtime_info_menu ;;
      16) badvpn_status_menu ;;
      17) badvpn_restart_menu ;;
      0|kembali|k|back|b) break ;;
      *) warn "Pilihan tidak valid" ; sleep 1 ;;
    esac
  done
}

# -------------------------
