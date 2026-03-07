# shellcheck shell=bash
# Main menu
# -------------------------
# Catatan maintainability:
# Beberapa target action di bawah ini masih diimplementasikan di manage.sh selama
# fase modularisasi transisi. Jangan menghapus handler lama sebelum logic benar-benar
# dipindah dan smoke test menu terkait lulus.
main_menu() {
  while true; do
    title
    account_info_sync_after_domain_change_if_needed
    main_menu_info_header_print
    echo -e "${UI_BOLD}${UI_ACCENT}Main Menu${UI_RESET}"
    hr
    echo -e "  ${UI_ACCENT}1)${UI_RESET} Status & Diagnostics"
    echo -e "  ${UI_ACCENT}2)${UI_RESET} Xray Management"
    echo -e "  ${UI_ACCENT}3)${UI_RESET} SSH Management"
    echo -e "  ${UI_ACCENT}4)${UI_RESET} Xray Quota & Access Control"
    echo -e "  ${UI_ACCENT}5)${UI_RESET} SSH Quota & Access Control"
    echo -e "  ${UI_ACCENT}6)${UI_RESET} Network Controls"
    echo -e "  ${UI_ACCENT}7)${UI_RESET} Domain Control"
    echo -e "  ${UI_ACCENT}8)${UI_RESET} Speedtest"
    echo -e "  ${UI_ACCENT}9)${UI_RESET} Security"
    echo -e "  ${UI_ACCENT}10)${UI_RESET} Maintenance"
    echo -e "  ${UI_ACCENT}11)${UI_RESET} Traffic Analytics"
    echo -e "  ${UI_ACCENT}12)${UI_RESET} Install BOT Discord"
    echo -e "  ${UI_ACCENT}13)${UI_RESET} Install BOT Telegram"
    echo -e "  ${UI_ACCENT}0)${UI_RESET} Keluar"
    hr
    if ! read -r -p "Pilih: " c; then
      echo
      exit 0
    fi
    case "${c}" in
      1) run_action "Status & Diagnostics" status_diagnostics_menu ;;
      2) run_action "Xray Management" user_menu ;;
      3|ssh) run_action "SSH Management" ssh_menu ;;
      4|quota) run_action "Xray Quota & Access Control" quota_menu ;;
      5|sshquota|ssh-qac) run_action "SSH Quota & Access Control" ssh_quota_menu ;;
      6|network) run_action "Network Controls" network_menu ;;
      7|domain) run_action "Domain Control" domain_control_menu ;;
      8|speedtest|speed) run_action "Speedtest" speedtest_menu ;;
      9|security) run_action "Security" fail2ban_menu ;;
      10|maintenance|maint) run_action "Maintenance" maintenance_menu ;;
      11|analytics|traffic) run_action "Traffic Analytics" traffic_analytics_menu ;;
      12) run_action "Install BOT Discord" install_discord_bot_menu ;;
      13) run_action "Install BOT Telegram" install_telegram_bot_menu ;;
      0|kembali|k|back|b) exit 0 ;;
      *) invalid_choice ;;
    esac
  done
}
