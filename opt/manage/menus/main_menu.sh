# shellcheck shell=bash
# Main menu
# -------------------------
# Catatan maintainability:
# Beberapa target action di bawah ini masih diimplementasikan di manage.sh selama
# fase modularisasi transisi. Jangan menghapus handler lama sebelum logic benar-benar
# dipindah dan smoke test menu terkait lulus.
main_menu_render_options() {
  local -a items=(
    "1|Status"
    "2|Xray Users"
    "3|SSH Users"
    "4|Xray QAC"
    "5|SSH QAC"
    "6|Network"
    "7|Domain Control"
    "8|Speedtest"
    "9|Security"
    "10|Maintenance"
    "11|Traffic"
    "12|Discord Bot"
    "13|Telegram Bot"
    "0|Keluar"
  )
  ui_menu_render_two_columns_fixed items
}

main_menu() {
  while true; do
    title
    account_info_sync_after_domain_change_if_needed
    main_menu_info_header_print
    main_menu_center_line "Main Menu"
    hr
    main_menu_render_options
    hr
    if ! read -r -p "Pilih: " c; then
      echo
      exit 0
    fi
    case "${c}" in
      1) run_action "Status" status_diagnostics_menu ;;
      2) run_action "Xray Users" user_menu ;;
      3|ssh) run_action "SSH Users" ssh_menu ;;
      4|quota) run_action "Xray QAC" quota_menu ;;
      5|sshquota|ssh-qac) run_action "SSH QAC" ssh_quota_menu ;;
      6|network) run_action "Network" network_menu ;;
      7|domain) run_action "Domain Control" domain_control_menu ;;
      8|speedtest|speed) run_action "Speedtest" speedtest_menu ;;
      9|security) run_action "Security" fail2ban_menu ;;
      10|maintenance|maint) run_action "Maintenance" maintenance_menu ;;
      11|analytics|traffic) run_action "Traffic" traffic_analytics_menu ;;
      12) run_action "Discord Bot" install_discord_bot_menu ;;
      13) run_action "Telegram Bot" install_telegram_bot_menu ;;
      0|kembali|k|back|b) exit 0 ;;
      *) invalid_choice ;;
    esac
  done
}
