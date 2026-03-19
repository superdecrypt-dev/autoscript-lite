#!/usr/bin/env bash
# shellcheck shell=bash

install_discord_bot_menu() {
  local installer_cmd="/usr/local/bin/install-discord-bot"
  ui_menu_screen_begin "13) Tools > Discord Bot"

  if [[ ! -x "${installer_cmd}" ]]; then
    warn "Installer bot Discord tidak ditemukan / tidak executable:"
    echo "  ${installer_cmd}"
    echo
    echo "Hint: jalankan ulang run.sh agar installer ikut dipasang."
    hr
    pause
    return 0
  fi

  echo "Menjalankan installer:"
  echo "  ${installer_cmd} menu"
  echo "Boundary:"
  echo "  - kontrol akan diserahkan ke installer eksternal"
  echo "  - installer dapat mengubah file/env/service bot di luar menu manage ini"
  hr
  if ! confirm_menu_apply_now "Serahkan kontrol ke installer bot Discord eksternal sekarang?"; then
    pause
    return 0
  fi
  if ! "${installer_cmd}" menu; then
    warn "Installer bot Discord keluar dengan status error."
    hr
    pause
  fi
  return 0
}

install_telegram_bot_menu() {
  local installer_cmd="/usr/local/bin/install-telegram-bot"
  ui_menu_screen_begin "13) Tools > Telegram Bot"

  if [[ ! -x "${installer_cmd}" ]]; then
    warn "Installer bot Telegram tidak ditemukan / tidak executable:"
    echo "  ${installer_cmd}"
    echo
    echo "Hint: jalankan ulang run.sh agar installer ikut dipasang."
    hr
    pause
    return 0
  fi

  echo "Menjalankan installer:"
  echo "  ${installer_cmd} menu"
  echo "Boundary:"
  echo "  - kontrol akan diserahkan ke installer eksternal"
  echo "  - installer dapat mengubah file/env/service bot di luar menu manage ini"
  hr
  if ! confirm_menu_apply_now "Serahkan kontrol ke installer bot Telegram eksternal sekarang?"; then
    pause
    return 0
  fi
  if ! "${installer_cmd}" menu; then
    warn "Installer bot Telegram keluar dengan status error."
    hr
    pause
  fi
  return 0
}


