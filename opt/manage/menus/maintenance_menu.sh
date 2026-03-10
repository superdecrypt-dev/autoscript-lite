# shellcheck shell=bash
# Maintenance
# -------------------------
maintenance_menu() {
  while true; do
    title
    echo "10) Maintenance"
    hr
    echo "  1) Restart Xray"
    echo "  2) Restart Nginx"
    echo "  3) Restart Core Services"
    echo "  4) Xray Logs"
    echo "  5) Nginx Logs"
    echo "  6) WARP Status"
    echo "  7) Restart WARP"
    echo "  8) Xray Daemons"
    echo "  9) SSH WS Status"
    echo "  10) Restart SSH WS"
    echo "  11) SSH WS Diagnostics"
    echo "  12) Edge Gateway Status"
    echo "  13) Restart Edge Gateway"
    echo "  14) Edge Gateway Info"
    echo "  15) BadVPN UDPGW Status"
    echo "  16) Restart BadVPN UDPGW"
    echo "  17) OpenVPN Status"
    echo "  18) Restart OpenVPN Core"
    echo "  19) Restart OpenVPN WS Proxy"
    echo "  0) Back"
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
      17) openvpn_status_menu "10) Maintenance > OpenVPN Status" ;;
      18) openvpn_restart_core_menu "10) Maintenance > Restart OpenVPN Core" ;;
      19) openvpn_restart_ws_menu "10) Maintenance > Restart OpenVPN WS Proxy" ;;
      0|kembali|k|back|b) break ;;
      *) warn "Pilihan tidak valid" ; sleep 1 ;;
    esac
  done
}

# -------------------------
