#!/usr/bin/env bash
# shellcheck shell=bash

hysteria2_menu_title() {
  local suffix="${1:-}"
  local base="9) Tools > Hysteria 2"
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
    echo "Hint: rerun setup agar spike Hysteria 2 terpasang."
    return 1
  fi
  if declare -F manage_bootstrap_path_trusted >/dev/null 2>&1 && ! manage_bootstrap_path_trusted "${bin}"; then
    warn "Binary Hysteria 2 manage tidak trusted:"
    echo "  ${bin}"
    return 1
  fi
  printf '%s\n' "${bin}"
}

hysteria2_restart_service_if_present() {
  local svc="${1:-hysteria2.service}"
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
  local bin=""
  ui_menu_screen_begin "$(hysteria2_menu_title "Status")"
  bin="$(hysteria2_manage_bin_resolve)" || { hr; pause; return 0; }

  if ! "${bin}" status; then
    warn "Gagal membaca status Hysteria 2."
  fi
  hr
  if systemctl list-unit-files "${HYSTERIA2_SERVICE:-hysteria2.service}" >/dev/null 2>&1; then
    systemctl status "${HYSTERIA2_SERVICE:-hysteria2.service}" --no-pager || true
  else
    warn "Service Hysteria 2 belum terpasang."
  fi
  hr
  pause
  return 0
}

hysteria2_list_users_menu() {
  local bin="" out=""
  ui_menu_screen_begin "$(hysteria2_menu_title "List Users")"
  bin="$(hysteria2_manage_bin_resolve)" || { hr; pause; return 0; }
  out="$("${bin}" list-users 2>/dev/null || true)"
  if [[ -z "${out}" ]]; then
    echo "Belum ada user Hysteria 2."
    hr
    pause
    return 0
  fi
  printf '%-24s %-24s\n' "USERNAME" "CREATED_AT"
  hr
  awk -F'\t' '{printf "%-24s %-24s\n", $1, $2}' <<<"${out}"
  hr
  pause
  return 0
}

hysteria2_add_user_menu() {
  local bin="" username="" password="" cmd_out="" svc="${HYSTERIA2_SERVICE:-hysteria2.service}"
  ui_menu_screen_begin "$(hysteria2_menu_title "Add User")"
  bin="$(hysteria2_manage_bin_resolve)" || { hr; pause; return 0; }

  read -r -p "Username baru (0 untuk kembali): " username || { echo; return 0; }
  case "${username}" in
    ""|0|kembali|k|back|b) return 0 ;;
  esac
  read -r -p "Password (kosong=auto): " password || { echo; return 0; }

  if ! confirm_menu_apply_now "Buat user Hysteria 2 '${username}' sekarang?"; then
    pause
    return 0
  fi
  if ! cmd_out="$("${bin}" add-user --username "${username}" --password "${password}" 2>&1)"; then
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
  ok "User Hysteria 2 berhasil dibuat."
  echo "${cmd_out}"
  hr
  pause
  return 0
}

hysteria2_delete_user_menu() {
  local bin="" username="" cmd_out="" svc="${HYSTERIA2_SERVICE:-hysteria2.service}"
  ui_menu_screen_begin "$(hysteria2_menu_title "Delete User")"
  bin="$(hysteria2_manage_bin_resolve)" || { hr; pause; return 0; }

  read -r -p "Username yang dihapus (0 untuk kembali): " username || { echo; return 0; }
  case "${username}" in
    ""|0|kembali|k|back|b) return 0 ;;
  esac

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
  ok "User Hysteria 2 berhasil dihapus."
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
