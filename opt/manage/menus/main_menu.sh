# shellcheck shell=bash
# Main menu
# -------------------------
# Catatan maintainability:
# Beberapa target action di bawah ini masih diimplementasikan di manage.sh selama
# fase modularisasi transisi. Jangan menghapus handler lama sebelum logic benar-benar
# dipindah dan smoke test menu terkait lulus.
main_menu_terminal_width() {
  local width="${COLUMNS:-}"
  if [[ ! "${width}" =~ ^[0-9]+$ ]] || (( width < 40 )); then
    if command -v tput >/dev/null 2>&1; then
      width="$(tput cols 2>/dev/null || true)"
    fi
  fi
  if [[ ! "${width}" =~ ^[0-9]+$ ]] || (( width < 40 )); then
    width=80
  fi
  printf '%s\n' "${width}"
}

main_menu_render_single_column() {
  echo -e "  ${UI_ACCENT}1)${UI_RESET} Status"
  echo -e "  ${UI_ACCENT}2)${UI_RESET} Xray Users"
  echo -e "  ${UI_ACCENT}3)${UI_RESET} SSH Users"
  echo -e "  ${UI_ACCENT}4)${UI_RESET} Xray QAC"
  echo -e "  ${UI_ACCENT}5)${UI_RESET} SSH QAC"
  echo -e "  ${UI_ACCENT}6)${UI_RESET} Network"
  echo -e "  ${UI_ACCENT}7)${UI_RESET} Domain Control"
  echo -e "  ${UI_ACCENT}8)${UI_RESET} Speedtest"
  echo -e "  ${UI_ACCENT}9)${UI_RESET} Security"
  echo -e "  ${UI_ACCENT}10)${UI_RESET} Maintenance"
  echo -e "  ${UI_ACCENT}11)${UI_RESET} Traffic"
  echo -e "  ${UI_ACCENT}12)${UI_RESET} Discord Bot"
  echo -e "  ${UI_ACCENT}13)${UI_RESET} Telegram Bot"
  echo -e "  ${UI_ACCENT}0)${UI_RESET} Keluar"
}

main_menu_render_two_columns() {
  local width
  width="$(main_menu_terminal_width)"

  local -a left_nums=("1)" "2)" "3)" "4)" "5)" "6)" "7)")
  local -a left_labels=("Status" "Xray Users" "SSH Users" "Xray QAC" "SSH QAC" "Network" "Domain Control")
  local -a right_nums=("8)" "9)" "10)" "11)" "12)" "13)" "0)")
  local -a right_labels=("Speedtest" "Security" "Maintenance" "Traffic" "Discord Bot" "Telegram Bot" "Keluar")
  local i left_label_width=0 right_label_width=0
  for i in "${!left_labels[@]}"; do
    (( ${#left_labels[$i]} > left_label_width )) && left_label_width=${#left_labels[$i]}
  done
  for i in "${!right_labels[@]}"; do
    (( ${#right_labels[$i]} > right_label_width )) && right_label_width=${#right_labels[$i]}
  done

  local min_width=$(( 2 + 3 + 1 + left_label_width + 2 + 3 + 1 + right_label_width ))
  if (( width < min_width )); then
    main_menu_render_single_column
    return 0
  fi

  for i in "${!left_nums[@]}"; do
    printf "  %b%s%b %-*s  %b%s%b %s\n" \
      "${UI_ACCENT}" "${left_nums[$i]}" "${UI_RESET}" "${left_label_width}" "${left_labels[$i]}" \
      "${UI_ACCENT}" "${right_nums[$i]}" "${UI_RESET}" "${right_labels[$i]}"
  done
}

main_menu_render_options() {
  local width
  width="$(main_menu_terminal_width)"
  if (( width >= 72 )); then
    main_menu_render_two_columns
  else
    main_menu_render_single_column
  fi
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
