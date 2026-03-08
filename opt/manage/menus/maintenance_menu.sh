# shellcheck shell=bash
# Maintenance
# -------------------------
maintenance_menu() {
  while true; do
    title
    echo "10) Maintenance"
    hr
    echo "  1. Restart xray"
    echo "  2. Restart nginx"
    echo "  3. Restart all (xray+nginx)"
    echo "  4. View xray logs (tail)"
    echo "  5. View nginx logs (tail)"
    echo "  6. Wireproxy (WARP) Status (ringkas)"
    echo "  7. Restart wireproxy (WARP)"
    echo "  8. Daemon Status & Restart (xray-expired / xray-quota / xray-limit-ip / xray-speed)"
    echo "  9. SSH WS Status (dropbear/stunnel/proxy)"
    echo "  10. Restart SSH WS Stack"
    echo "  11. SSH WS Diagnostics"
    echo "  12. Edge Gateway Status"
    echo "  13. Restart Edge Gateway"
    echo "  14. Edge Gateway Info"
    echo "  0. Kembali"
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
      0|kembali|k|back|b) break ;;
      *) warn "Pilihan tidak valid" ; sleep 1 ;;
    esac
  done
}

# -------------------------
