# shellcheck shell=bash
# Main menu
# -------------------------
# Catatan maintainability:
# Beberapa target action di bawah ini masih diimplementasikan di manage.sh selama
# fase modularisasi transisi. Jangan menghapus handler lama sebelum logic benar-benar
# dipindah dan smoke test menu terkait lulus.
tools_warp_tier_menu() {
  local prev="${WARP_TIER_MENU_CONTEXT:-}"
  WARP_TIER_MENU_CONTEXT="tools"
  menu_run_isolated_report "WARP Tier" warp_tier_menu
  local rc=$?
  WARP_TIER_MENU_CONTEXT="${prev}"
  return "${rc}"
}

tools_menu() {
  local -a items=(
    "1|Telegram Bot"
    "2|WARP Tier"
    "3|License Guard"
    "4|Backup/Restore"
    "5|Uninstall"
    "0|Back"
  )
  while true; do
    ui_menu_screen_begin "10) Tools"
    ui_menu_render_options items 76
    hr
    if ! read -r -p "Pilih: " c; then
      echo
      break
    fi
    case "${c}" in
      1) run_action "Telegram Bot" install_telegram_bot_menu ;;
      2) tools_warp_tier_menu ;;
      3|license|license-guard) run_action "License Guard" autoscript_license_status_menu ;;
      4|backup|restore|backup-restore) run_action "Backup/Restore" backup_restore_menu ;;
      5|uninstall) run_action "Uninstall" autoscript_uninstall_menu ;;
      0|kembali|k|back|b) break ;;
      *) warn "Pilihan tidak valid" ; sleep 1 ;;
    esac
  done
}

main_menu_render_options() {
  # shellcheck disable=SC2034
  local -a items=(
    "1|Xray Users"
    "2|Xray QAC"
    "3|Xray Network"
    "4|Domain Control"
    "5|Speedtest"
    "6|Security"
    "7|Maintenance"
    "8|Traffic"
    "9|Tools"
    "0|Keluar"
  )
  ui_menu_render_two_columns_fixed items
}

main_menu_render_license_block_notice() {
  local reason="${MANAGE_LICENSE_BLOCK_REASON:-Akses manage ditolak oleh license guard.}"
  main_menu_center_line "License Info"
  hr
  echo "Lisensi VPS tidak aktif untuk membuka menu utama."
  echo
  echo -e "${reason}"
  echo
  echo "Perpanjang lisensi di: https://autoscript.license.dpdns.org"
}

main_menu() {
  while true; do
    title
    main_menu_info_header_print
    if [[ "${MANAGE_LICENSE_BLOCKED:-0}" == "1" ]]; then
      main_menu_render_license_block_notice
      hr
      if ! read -r -p "Tekan Enter untuk keluar... " c; then
        echo
      fi
      exit 1
    fi
    main_menu_center_line "$(ui_decorated_section_title "Main Menu")"
    hr
    main_menu_render_options
    hr
    if ! read -r -p "Pilih: " c; then
      echo
      exit 0
    fi
    case "${c}" in
      1) run_action "Xray Users" user_menu ;;
      2|quota) run_action "Xray QAC" quota_menu ;;
      3|network) run_action "Xray Network" network_menu ;;
      4|domain) run_action "Domain Control" domain_control_menu ;;
      5|speedtest|speed) run_action "Speedtest" speedtest_menu ;;
      6|security) run_action "Security" fail2ban_menu ;;
      7|maintenance|maint) run_action "Maintenance" maintenance_menu ;;
      8|analytics|traffic) run_action "Traffic" traffic_analytics_menu ;;
      9|tools) run_action "Tools" tools_menu ;;
      0|kembali|k|back|b) exit 0 ;;
      *) invalid_choice ;;
    esac
  done
}
