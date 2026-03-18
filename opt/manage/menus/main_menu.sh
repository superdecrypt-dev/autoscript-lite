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
    "2|Discord Bot"
    "3|WARP Tier"
    "0|Back"
  )
  while true; do
    ui_menu_screen_begin "13) Tools"
    ui_menu_render_options items 76
    hr
    if ! read -r -p "Pilih: " c; then
      echo
      break
    fi
    case "${c}" in
      1) run_action "Telegram Bot" install_telegram_bot_menu ;;
      2) run_action "Discord Bot" install_discord_bot_menu ;;
      3) tools_warp_tier_menu ;;
      0|kembali|k|back|b) break ;;
      *) warn "Pilihan tidak valid" ; sleep 1 ;;
    esac
  done
}

main_menu_render_options() {
  local -a items=(
    "1|Xray Users"
    "2|SSH Users"
    "3|Xray QAC"
    "4|SSH QAC"
    "5|Xray Network"
    "6|SSH Network"
    "7|Adblocker"
    "8|Domain Control"
    "9|Speedtest"
    "10|Security"
    "11|Maintenance"
    "12|Traffic"
    "13|Tools"
    "0|Keluar"
  )
  ui_menu_render_two_columns_fixed items
}

main_menu() {
  while true; do
    title
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
      1) run_action "Xray Users" user_menu ;;
      2|ssh) run_action "SSH Users" ssh_menu ;;
      3|quota) run_action "Xray QAC" quota_menu ;;
      4|sshquota|ssh-qac) run_action "SSH QAC" ssh_quota_menu ;;
      5|network) run_action "Xray Network" network_menu ;;
      6|ssh-network|sshnet) run_action "SSH Network" ssh_network_menu ;;
      7|adblock|adblocker) run_action "Adblocker" adblock_menu ;;
      8|domain) run_action "Domain Control" domain_control_menu ;;
      9|speedtest|speed) run_action "Speedtest" speedtest_menu ;;
      10|security) run_action "Security" fail2ban_menu ;;
      11|maintenance|maint) run_action "Maintenance" maintenance_menu ;;
      12|analytics|traffic) run_action "Traffic" traffic_analytics_menu ;;
      13|tools) run_action "Tools" tools_menu ;;
      0|kembali|k|back|b) exit 0 ;;
      *) invalid_choice ;;
    esac
  done
}
