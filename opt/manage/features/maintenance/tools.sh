#!/usr/bin/env bash
# shellcheck shell=bash

tools_external_installer_require_cmd() {
  local installer_cmd="$1"
  local label="$2"

  if [[ ! -x "${installer_cmd}" ]]; then
    warn "Installer ${label} tidak ditemukan / tidak executable:"
    echo "  ${installer_cmd}"
    echo
    echo "Hint: jalankan ulang run.sh agar installer ikut dipasang."
    hr
    pause
    return 1
  fi
  if declare -F manage_bootstrap_path_trusted >/dev/null 2>&1 && ! manage_bootstrap_path_trusted "${installer_cmd}"; then
    warn "Installer ${label} tidak trusted:"
    echo "  ${installer_cmd}"
    echo
    echo "Hint: pastikan owner root, bukan symlink, dan tidak writable oleh group/other."
    hr
    pause
    return 1
  fi
  return 0
}

tools_external_installer_exec() {
  local menu_title="$1"
  local label="$2"
  local installer_cmd="$3"
  local confirm_prompt="${4:-}"
  shift 4 || true
  local -a cmd=( "${installer_cmd}" "$@" )

  ui_menu_screen_begin "${menu_title}"
  tools_external_installer_require_cmd "${installer_cmd}" "${label}" || return 0

  echo "Menjalankan command:"
  printf '  %q' "${cmd[@]}"
  printf '\n'
  echo "Boundary:"
  echo "  - kontrol akan diserahkan ke installer eksternal"
  echo "  - installer dapat mengubah file/env/service di luar menu manage ini"
  hr

  if [[ -n "${confirm_prompt}" ]]; then
    if ! confirm_menu_apply_now "${confirm_prompt}"; then
      pause
      return 0
    fi
  fi

  if ! "${cmd[@]}"; then
    warn "Installer ${label} keluar dengan status error."
  fi
  hr
  pause
  return 0
}

install_telegram_bot_menu() {
  local installer_cmd="/usr/local/bin/install-telegram-bot"
  tools_external_installer_exec \
    "9) Tools > Telegram Bot" \
    "bot Telegram" \
    "${installer_cmd}" \
    "Serahkan kontrol ke installer bot Telegram eksternal sekarang?" \
    "menu"
  return 0
}

autoscript_license_status_menu() {
  local license_bin="/usr/local/bin/autoscript-license-check"
  local trusted_default_api_url="https://autoscript-license.minidecrypt.workers.dev/api/v1/license/check"
  local config_file="/etc/autoscript/license/config.env"

  ui_menu_screen_begin "9) Tools > License Guard"
  if [[ ! -x "${license_bin}" ]]; then
    warn "Binary license guard tidak ditemukan / tidak executable:"
    echo "  ${license_bin}"
    echo
    echo "Hint: jalankan ulang run.sh atau setup.sh agar license guard ikut dipasang."
    hr
    pause
    return 0
  fi
  if declare -F manage_bootstrap_path_trusted >/dev/null 2>&1 && ! manage_bootstrap_path_trusted "${license_bin}"; then
    warn "Binary license guard tidak trusted:"
    echo "  ${license_bin}"
    echo
    echo "Hint: pastikan owner root, bukan symlink, dan tidak writable oleh group/other."
    hr
    pause
    return 0
  fi

  if ! AUTOSCRIPT_LICENSE_DEFAULT_API_URL="${trusted_default_api_url}" \
    AUTOSCRIPT_LICENSE_API_URL="${trusted_default_api_url}" \
    AUTOSCRIPT_LICENSE_CONFIG_FILE="${config_file}" \
    "${license_bin}" status; then
    warn "Gagal membaca status license guard."
  fi
  hr
  pause
  return 0
}
