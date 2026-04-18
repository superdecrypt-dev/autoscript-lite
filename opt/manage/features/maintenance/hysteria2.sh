#!/usr/bin/env bash
# shellcheck shell=bash

hysteria2_menu_title() {
  local suffix="${1:-}"
  local base="9) Hysteria 2"
  if [[ -n "${suffix}" ]]; then
    printf '%s > %s\n' "${base}" "${suffix}"
  else
    printf '%s\n' "${base}"
  fi
}

hysteria2_manage_bin_resolve() {
  local bin="${HYSTERIA2_MANAGE_BIN:-/usr/local/bin/hysteria2-manage}"
  if [[ ! -x "${bin}" ]]; then
    warn "Binary Hysteria 2 manage tidak ditemukan:"
    echo "  ${bin}"
    echo
    echo "Hint: rerun setup agar Hysteria 2 terpasang."
    return 1
  fi
  if declare -F manage_bootstrap_path_trusted >/dev/null 2>&1 && ! manage_bootstrap_path_trusted "${bin}"; then
    warn "Binary Hysteria 2 manage tidak trusted:"
    echo "  ${bin}"
    return 1
  fi
  printf '%s\n' "${bin}"
}

hysteria2_status_field() {
  local blob="${1:-}" key="${2:-}"
  awk -F= -v wanted="${key}" '$1==wanted {sub(/^[^=]*=/, ""); print; exit}' <<<"${blob}"
}

hysteria2_print_kv() {
  local label="${1:-}" value="${2:-}"
  printf '%-18s : %s\n' "${label}" "${value:--}"
}

hysteria2_service_label() {
  local state="${1:-unknown}" substate="${2:-unknown}"
  if [[ -n "${state}" && "${state}" != "unknown" && -n "${substate}" && "${substate}" != "unknown" ]]; then
    printf '%s (%s)\n' "${state}" "${substate}"
  else
    printf '%s\n' "${state:--}"
  fi
}

hysteria2_user_rows_print() {
  local raw="${1:-}" show_uri="${2:-1}"
  local idx=0 username created_at expired_at uri
  while IFS=$'\t' read -r username created_at expired_at uri; do
    [[ -n "${username}" ]] || continue
    idx=$((idx + 1))
    printf '%2d) %-20s %s\n' "${idx}" "${username}" "${created_at:-unknown}"
    printf '    valid until  : %s\n' "${expired_at:-Unlimited}"
    if [[ "${show_uri}" == "1" && -n "${uri}" ]]; then
      printf '    uri          : %s\n' "${uri}"
    fi
    echo
  done <<<"${raw}"
}

hysteria2_user_row_lookup() {
  local raw="${1:-}" choice="${2:-}" idx=0 username created_at expired_at uri
  while IFS=$'\t' read -r username created_at expired_at uri; do
    [[ -n "${username}" ]] || continue
    idx=$((idx + 1))
    if [[ "${choice}" == "${idx}" || "${choice}" == "${username}" ]]; then
      printf '%s\t%s\t%s\t%s\n' "${username}" "${created_at}" "${expired_at}" "${uri}"
      return 0
    fi
  done <<<"${raw}"
  return 1
}

hysteria2_account_file_show() {
  local path="${1:-}"
  if [[ -f "${path}" ]]; then
    cat "${path}"
  else
    echo "(Account file tidak ditemukan: ${path})"
  fi
}

hysteria2_restart_service_if_present() {
  local svc="${1:-xray.service}"
  if ! systemctl list-unit-files "${svc}" >/dev/null 2>&1; then
    warn "Service ${svc} belum terpasang."
    return 1
  fi
  systemctl enable "${svc}" --now >/dev/null 2>&1 || true
  if ! systemctl restart "${svc}" >/dev/null 2>&1; then
    return 1
  fi
  if ! systemctl is-active --quiet "${svc}"; then
    return 1
  fi
  return 0
}

hysteria2_status_menu() {
  local bin="" status_blob="" service_label="" service_enabled="" backend_label="" cleaner_state="" cleaner_enabled="" port="" domain="" masquerade="" user_count="" latest_username="" latest_created_at="" latest_expired_at="" config_file="" users_file="" account_root=""
  ui_menu_screen_begin "$(hysteria2_menu_title "Status")"
  bin="$(hysteria2_manage_bin_resolve)" || { hr; pause; return 0; }
  status_blob="$("${bin}" status 2>/dev/null || true)"
  if [[ -z "${status_blob}" ]]; then
    warn "Gagal membaca status Hysteria 2."
    hr
    pause
    return 0
  fi

  service_label="$(hysteria2_service_label \
    "$(hysteria2_status_field "${status_blob}" "SERVICE_STATE")" \
    "$(hysteria2_status_field "${status_blob}" "SERVICE_SUBSTATE")")"
  service_enabled="$(hysteria2_status_field "${status_blob}" "SERVICE_ENABLED")"
  backend_label="$(hysteria2_status_field "${status_blob}" "BACKEND")"
  backend_label="${backend_label:-Xray native inbound}"
  cleaner_state="$(hysteria2_service_label \
    "$(hysteria2_status_field "${status_blob}" "EXPIRED_CLEANER_STATE")" \
    "$(hysteria2_status_field "${status_blob}" "EXPIRED_CLEANER_SUBSTATE")")"
  cleaner_enabled="$(hysteria2_status_field "${status_blob}" "EXPIRED_CLEANER_ENABLED")"
  port="$(hysteria2_status_field "${status_blob}" "PORT")"
  domain="$(hysteria2_status_field "${status_blob}" "DOMAIN")"
  masquerade="$(hysteria2_status_field "${status_blob}" "MASQUERADE_URL")"
  user_count="$(hysteria2_status_field "${status_blob}" "USER_COUNT")"
  latest_username="$(hysteria2_status_field "${status_blob}" "LATEST_USERNAME")"
  latest_created_at="$(hysteria2_status_field "${status_blob}" "LATEST_CREATED_AT")"
  latest_expired_at="$(hysteria2_status_field "${status_blob}" "LATEST_EXPIRED_AT")"
  config_file="$(hysteria2_status_field "${status_blob}" "CONFIG_FILE")"
  users_file="$(hysteria2_status_field "${status_blob}" "USERS_FILE")"
  account_root="$(hysteria2_status_field "${status_blob}" "ACCOUNT_ROOT")"

  echo "Overview"
  hr
  hysteria2_print_kv "Service" "${service_label}"
  hysteria2_print_kv "Enabled" "${service_enabled}"
  hysteria2_print_kv "Backend" "${backend_label}"
  hysteria2_print_kv "Auto Expired" "${cleaner_state}"
  hysteria2_print_kv "Cleaner Enabled" "${cleaner_enabled}"
  hysteria2_print_kv "Listen" "UDP :${port:-443}"
  hysteria2_print_kv "Domain" "${domain}"
  hysteria2_print_kv "Masquerade" "${masquerade}"
  hysteria2_print_kv "Users" "${user_count:-0}"
  echo
  echo "Latest Account"
  hr
  if [[ -n "${latest_username}" ]]; then
    hysteria2_print_kv "Username" "${latest_username}"
    hysteria2_print_kv "Created At" "${latest_created_at}"
    hysteria2_print_kv "Valid Until" "${latest_expired_at}"
  else
    echo "Belum ada user Hysteria 2."
  fi
  echo
  echo "Config Surface"
  hr
  hysteria2_print_kv "Config File" "${config_file}"
  hysteria2_print_kv "Users DB" "${users_file}"
  hysteria2_print_kv "Account Root" "${account_root}"
  hr
  pause
  return 0
}

hysteria2_list_users_menu() {
  local bin="" out="" count=0
  ui_menu_screen_begin "$(hysteria2_menu_title "List Users")"
  bin="$(hysteria2_manage_bin_resolve)" || { hr; pause; return 0; }
  out="$("${bin}" list-users 2>/dev/null || true)"
  if [[ -z "${out}" ]]; then
    echo "Belum ada user Hysteria 2."
    hr
    pause
    return 0
  fi
  count="$(awk -F'\t' 'NF && $1 != "" {c++} END {print c+0}' <<<"${out}")"
  printf 'Total user : %s\n' "${count}"
  hr
  hysteria2_user_rows_print "${out}" 1
  hr
  pause
  return 0
}

hysteria2_add_user_menu() {
  local bin="" status_blob="" existing_users="" username="" password="" days_input="" cmd_out="" svc="${HYSTERIA2_SERVICE:-xray.service}"
  local domain="" port="" masquerade="" account_root="" account_file="" password_label="" expiry_label="Unlimited" count=0
  ui_menu_screen_begin "$(hysteria2_menu_title "Add User")"
  bin="$(hysteria2_manage_bin_resolve)" || { hr; pause; return 0; }

  status_blob="$("${bin}" status 2>/dev/null || true)"
  if [[ -z "${status_blob}" ]]; then
    warn "Gagal membaca status Hysteria 2."
    hr
    pause
    return 0
  fi

  domain="$(hysteria2_status_field "${status_blob}" "DOMAIN")"
  port="$(hysteria2_status_field "${status_blob}" "PORT")"
  masquerade="$(hysteria2_status_field "${status_blob}" "MASQUERADE_URL")"
  account_root="$(hysteria2_status_field "${status_blob}" "ACCOUNT_ROOT")"
  existing_users="$("${bin}" list-users 2>/dev/null || true)"

  echo "Current Accounts"
  hr
  if [[ -n "${existing_users}" ]]; then
    count="$(awk -F'\t' 'NF && $1 != "" {c++} END {print c+0}' <<<"${existing_users}")"
    printf 'Total user : %s\n' "${count}"
    hr
    hysteria2_user_rows_print "${existing_users}" 1
  else
    echo "Belum ada user Hysteria 2."
  fi
  hr

  read -r -p "Username baru (0 untuk kembali): " username || { echo; return 0; }
  case "${username}" in
    ""|0|kembali|k|back|b) return 0 ;;
  esac
  read -r -p "Password (kosong=auto): " password || { echo; return 0; }
  while true; do
    read -r -p "Masa aktif (hari, kosong=tanpa expiry): " days_input || { echo; return 0; }
    if [[ -z "${days_input}" ]]; then
      expiry_label="Unlimited"
      break
    fi
    if [[ "${days_input}" =~ ^[0-9]+$ ]]; then
      if [[ "${days_input}" == "0" ]]; then
        expiry_label="Unlimited"
      else
        expiry_label="$(date -u -d "+${days_input} days" '+%Y-%m-%d' 2>/dev/null || true)"
        [[ -n "${expiry_label}" ]] || expiry_label="After ${days_input} day(s)"
      fi
      break
    fi
    warn "Masa aktif harus angka bulat >= 0."
  done

  account_file="${account_root:-/opt/account/hysteria2}/${username}@hy2.txt"
  password_label="${password:-auto-generated}"
  ui_menu_screen_begin "$(hysteria2_menu_title "Add User > Review")"
  echo "Username       : ${username}"
  echo "Password       : ${password_label}"
  echo "Domain         : ${domain}"
  echo "Port UDP       : ${port:-443}"
  echo "Masquerade     : ${masquerade}"
  echo "Valid Until    : ${expiry_label}"
  hr
  if ! confirm_menu_apply_now "Buat user Hysteria 2 '${username}' sekarang?"; then
    pause
    return 0
  fi
  if ! cmd_out="$("${bin}" add-user --username "${username}" --password "${password}" --days "${days_input}" 2>&1)"; then
    warn "Gagal membuat user Hysteria 2."
    echo "${cmd_out}"
    hr
    pause
    return 0
  fi
  if ! hysteria2_restart_service_if_present "${svc}"; then
    warn "User dibuat, tetapi restart ${svc} gagal."
    systemctl status "${svc}" --no-pager || true
    hr
    pause
    return 0
  fi
  echo "[manage][OK] User Hysteria 2 berhasil dibuat."
  echo "${cmd_out}"
  if [[ -n "${account_file}" ]]; then
    hr
    echo "Generated account info:"
    hr
    hysteria2_account_file_show "${account_file}"
  fi
  hr
  pause
  return 0
}

hysteria2_delete_user_menu() {
  local bin="" raw="" choice="" selected="" username="" created_at="" expired_at="" uri="" cmd_out="" svc="${HYSTERIA2_SERVICE:-xray.service}"
  bin="$(hysteria2_manage_bin_resolve)" || { hr; pause; return 0; }
  raw="$("${bin}" list-users 2>/dev/null || true)"
  if [[ -z "${raw}" ]]; then
    ui_menu_screen_begin "$(hysteria2_menu_title "Delete User")"
    echo "Belum ada user Hysteria 2."
    hr
    pause
    return 0
  fi

  ui_menu_screen_begin "$(hysteria2_menu_title "Delete User")"
  echo "Pilih user yang akan dihapus:"
  hr
  hysteria2_user_rows_print "${raw}" 1
  hr
  read -r -p "No / username (0 untuk kembali): " choice || { echo; return 0; }
  case "${choice}" in
    ""|0|kembali|k|back|b) return 0 ;;
  esac

  selected="$(hysteria2_user_row_lookup "${raw}" "${choice}")" || {
    warn "User tidak ditemukan."
    pause
    return 0
  }
  IFS=$'\t' read -r username created_at expired_at uri <<<"${selected}"
  ui_menu_screen_begin "$(hysteria2_menu_title "Delete User > Review")"
  echo "Username    : ${username}"
  echo "Created At  : ${created_at}"
  echo "Valid Until : ${expired_at}"
  echo "URI         : ${uri}"
  hr
  if ! confirm_menu_apply_now "Hapus user Hysteria 2 '${username}' sekarang?"; then
    pause
    return 0
  fi
  if ! cmd_out="$("${bin}" delete-user --username "${username}" 2>&1)"; then
    warn "Gagal menghapus user Hysteria 2."
    echo "${cmd_out}"
    hr
    pause
    return 0
  fi
  if ! hysteria2_restart_service_if_present "${svc}"; then
    warn "User dihapus, tetapi restart ${svc} gagal."
    systemctl status "${svc}" --no-pager || true
    hr
    pause
    return 0
  fi
  echo "[manage][OK] User Hysteria 2 berhasil dihapus."
  echo "${cmd_out}"
  hr
  pause
  return 0
}

hysteria2_tools_menu() {
  local c
  while true; do
    # shellcheck disable=SC2034
    local -a items=(
      "1|Status"
      "2|List Users"
      "3|Add User"
      "4|Delete User"
      "0|Back"
    )
    ui_menu_screen_begin "$(hysteria2_menu_title)"
    ui_menu_render_options items 76
    hr
    if ! read -r -p "Pilih: " c; then
      echo
      break
    fi
    case "${c}" in
      1|status) hysteria2_status_menu ;;
      2|list|users) hysteria2_list_users_menu ;;
      3|add|create) hysteria2_add_user_menu ;;
      4|delete|del|remove) hysteria2_delete_user_menu ;;
      0|kembali|k|back|b) break ;;
      *) warn "Pilihan tidak valid" ; sleep 1 ;;
    esac
  done
}
