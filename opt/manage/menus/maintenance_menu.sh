# shellcheck shell=bash
# Maintenance
# -------------------------
maintenance_restore_service_state_exact() {
  local svc="$1"
  local should_be_active="$2"
  case "${should_be_active}" in
    true)
      svc_exists "${svc}" || return 0
      if svc_is_active "${svc}"; then
        return 0
      fi
      if [[ "${svc}" == "xray" ]]; then
        xray_restart_checked_with_preflight >/dev/null 2>&1
      elif [[ "${svc}" == "nginx" ]]; then
        nginx_restart_checked_with_listener >/dev/null 2>&1
      else
        svc_start_checked "${svc}" 30 >/dev/null 2>&1
      fi
      ;;
    false)
      if svc_exists "${svc}" && svc_is_active "${svc}"; then
        svc_stop_checked "${svc}" 30 >/dev/null 2>&1
      else
        return 0
      fi
      ;;
    *)
      return 1
      ;;
  esac
}

maintenance_restart_core_now() {
  local xray_was_active="false"
  local nginx_was_active="false"
  if svc_exists xray && svc_is_active xray; then
    xray_was_active="true"
  fi
  if svc_exists nginx && svc_is_active nginx; then
    nginx_was_active="true"
  fi
  if have_cmd xray && ! xray_confdir_syntax_test; then
    warn "Syntax confdir Xray gagal. Restart core dibatalkan sebelum service disentuh."
    return 1
  fi
  if have_cmd nginx && ! nginx -t >/dev/null 2>&1; then
    warn "nginx -t gagal. Restart core dibatalkan sebelum service disentuh."
    return 1
  fi
  if ! xray_restart_checked_with_preflight; then
    warn "Restart core dibatalkan: restart xray gagal."
    return 1
  fi
  if ! nginx_restart_checked_with_listener; then
    warn "Restart core gagal setelah xray berhasil direstart: restart nginx gagal. Mencoba restore state service sebelumnya..."
    maintenance_restore_service_state_exact xray "${xray_was_active}" || true
    maintenance_restore_service_state_exact nginx "${nginx_was_active}" || true
    if [[ "${xray_was_active}" == "true" ]] && { ! svc_exists xray || ! svc_is_active xray; }; then
      warn "Restore state xray ke kondisi semula gagal."
      return 1
    fi
    if [[ "${xray_was_active}" != "true" ]] && svc_exists xray && svc_is_active xray; then
      warn "Restore state xray ke kondisi inactive semula gagal."
      return 1
    fi
    if [[ "${nginx_was_active}" == "true" ]] && { ! svc_exists nginx || ! svc_is_active nginx; }; then
      warn "Restore state nginx ke kondisi semula gagal."
      return 1
    fi
    if [[ "${nginx_was_active}" != "true" ]] && svc_exists nginx && svc_is_active nginx; then
      warn "Restore state nginx ke kondisi inactive semula gagal."
      return 1
    fi
    return 1
  fi
  return 0
}

maintenance_restart_xray_now() {
  xray_restart_checked_with_preflight
}

maintenance_restart_nginx_now() {
  nginx_restart_checked_with_listener
}

maintenance_quota_file_count() {
  local -a quota_targets=("$@")
  local dir count=0
  if (( ${#quota_targets[@]} == 0 )); then
    quota_targets=("${QUOTA_PROTO_DIRS[@]}")
  fi
  for dir in "${quota_targets[@]}"; do
    [[ -d "${QUOTA_ROOT}/${dir}" ]] || continue
    while IFS= read -r -d '' _quota_file; do
      count=$((count + 1))
    done < <(find "${QUOTA_ROOT}/${dir}" -maxdepth 1 -type f -name '*.json' -print0 2>/dev/null | sort -z)
  done
  printf '%s\n' "${count}"
}

maintenance_quota_targets_preview_write() {
  local outfile="$1"
  shift || true
  local -a quota_targets=("$@")
  local dir quota_file
  [[ -n "${outfile}" ]] || return 1
  if (( ${#quota_targets[@]} == 0 )); then
    quota_targets=("${QUOTA_PROTO_DIRS[@]}")
  fi
  mkdir -p "$(dirname "${outfile}")" 2>/dev/null || true
  : > "${outfile}" || return 1
  {
    printf 'Generated: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf '\n'
    for dir in "${quota_targets[@]}"; do
      printf '[%s]\n' "${dir}"
      if [[ ! -d "${QUOTA_ROOT}/${dir}" ]]; then
        printf '(tidak ada target)\n\n'
        continue
      fi
      local found="false"
      while IFS= read -r -d '' quota_file; do
        found="true"
        printf '%s\n' "${quota_file}"
      done < <(find "${QUOTA_ROOT}/${dir}" -maxdepth 1 -type f -name '*.json' -print0 2>/dev/null | sort -z)
      if [[ "${found}" != "true" ]]; then
        printf '(tidak ada target)\n'
      fi
      printf '\n'
    done
  } > "${outfile}" || return 1
  chmod 600 "${outfile}" 2>/dev/null || true
  return 0
}

maintenance_normalize_quota_dates_menu() {
  local -a quota_targets=()
  local file_count ask_rc=0 spin_log="" rc=0 preview_report="" dry_run_report=""
  local scope_choice="" scope_label="Semua proto Xray"
  title
  echo "9) Maintenance > Normalize Quota Dates"
  hr
  echo "Pilih scope normalisasi:"
  echo "  1) Semua proto Xray"
  echo "  2) VLESS only"
  echo "  3) VMESS only"
  echo "  4) TROJAN only"
  echo "  0) Back"
  hr
  while true; do
    if ! read -r -p "Pilih scope (1-4/0): " scope_choice; then
      echo
      return 0
    fi
    case "${scope_choice}" in
      1) quota_targets=("${QUOTA_PROTO_DIRS[@]}") ; scope_label="Semua proto Xray" ; break ;;
      2) quota_targets=("vless") ; scope_label="VLESS only" ; break ;;
      3) quota_targets=("vmess") ; scope_label="VMESS only" ; break ;;
      4) quota_targets=("trojan") ; scope_label="TROJAN only" ; break ;;
      0|kembali|k|back|b) return 0 ;;
      *) echo "Pilihan tidak valid." ;;
    esac
  done
  file_count="$(maintenance_quota_file_count "${quota_targets[@]}")"
  echo "Operasi ini menormalisasi field quota created_at/expired_at ke format YYYY-MM-DD."
  echo "Scope       : ${scope_label}"
  echo "Target file : ${file_count:-0}"
  echo "Catatan     : jika ada warning, perubahan yang sempat ditulis akan di-rollback."
  preview_report="$(preview_report_path_prepare "quota-normalize-targets" 2>/dev/null || true)"
  if [[ -n "${preview_report}" ]] && maintenance_quota_targets_preview_write "${preview_report}" "${quota_targets[@]}"; then
    echo "Daftar target lengkap:"
    echo "  ${preview_report}"
  else
    rm -f "${preview_report}" >/dev/null 2>&1 || true
    preview_report=""
  fi
  dry_run_report="$(preview_report_path_prepare "quota-normalize-dryrun" 2>/dev/null || true)"
  if [[ -n "${dry_run_report}" ]] && quota_migrate_dates_report_write "${dry_run_report}" "${quota_targets[@]}"; then
    echo "Dry-run report : ${dry_run_report}"
  else
    rm -f "${dry_run_report}" >/dev/null 2>&1 || true
    dry_run_report=""
  fi
  hr
  echo "Aksi:"
  echo "  1) Preview only"
  echo "  2) Dry-run normalize"
  echo "  3) Jalankan normalisasi sekarang"
  echo "  0) Back"
  hr
  local action_choice=""
  while true; do
    if ! read -r -p "Pilih aksi (1-3/0): " action_choice; then
      echo
      return 0
    fi
    case "${action_choice}" in
      1)
        if [[ -n "${preview_report}" && -f "${preview_report}" ]]; then
          preview_report_show_file "${preview_report}" || warn "Gagal membuka preview target quota."
        else
          warn "Preview target quota tidak tersedia."
        fi
        hr
        pause
        return 0
        ;;
      2)
        if [[ -n "${dry_run_report}" && -f "${dry_run_report}" ]]; then
          preview_report_show_file "${dry_run_report}" || warn "Gagal membuka dry-run quota."
        else
          warn "Dry-run quota tidak tersedia."
        fi
        hr
        pause
        return 0
        ;;
      3) break ;;
      0|kembali|k|back|b) return 0 ;;
      *) echo "Pilihan tidak valid." ;;
    esac
  done

  if ! confirm_yn_or_back "Jalankan normalisasi quota dates untuk ${scope_label} sekarang?"; then
    ask_rc=$?
    if (( ask_rc == 2 )); then
      warn "Normalisasi quota dates dibatalkan (kembali)."
    else
      warn "Normalisasi quota dates dibatalkan."
    fi
    pause
    return 0
  fi

  if ui_run_logged_command_with_spinner spin_log "Menormalisasi quota dates (${scope_label})" quota_migrate_dates_to_dateonly "${quota_targets[@]}"; then
    rc=0
  else
    rc=$?
  fi

  hr
  if [[ -n "${spin_log}" && -s "${spin_log}" ]]; then
    cat "${spin_log}" 2>/dev/null || true
    hr
  fi
  rm -f "${spin_log}" >/dev/null 2>&1 || true

  case "${rc}" in
    0)
      log "Normalisasi quota dates selesai."
      pause
      return 0
      ;;
    2)
      warn "Normalisasi quota dates menghasilkan warning; perubahan yang sudah ditulis telah di-rollback."
      pause
      return 1
      ;;
    *)
      warn "Normalisasi quota dates gagal dengan status ${rc}."
      pause
      return 1
      ;;
  esac
}

maintenance_menu() {
  local -a items=(
    "1|Core Check"
    "2|Restart Xray"
    "3|Restart Nginx"
    "4|Restart Core"
    "5|Xray Logs"
    "6|Nginx Logs"
    "7|WARP Status"
    "8|Restart WARP"
    "9|Xray Daemons"
    "10|SSH WS Status"
    "11|Restart SSH WS"
    "12|SSH WS Diagnose"
    "13|Edge Status"
    "14|Restart Edge"
    "15|Edge Info"
    "16|BadVPN Status"
    "17|Restart BadVPN"
    "18|Normalize Quota Dates"
    "0|Back"
  )
  while true; do
    ui_menu_screen_begin "9) Maintenance"
    ui_menu_render_two_columns_fixed items
    hr
    if ! read -r -p "Pilih: " c; then
      echo
      break
    fi
    case "${c}" in
      1) sanity_check_now ;;
      2)
        if confirm_yn_or_back "Restart xray sekarang?"; then
          menu_run_isolated_report "Restart Xray" maintenance_restart_xray_now
        else
          warn "Restart xray dibatalkan."
        fi
        pause
        ;;
      3)
        if confirm_yn_or_back "Restart nginx sekarang?"; then
          menu_run_isolated_report "Restart Nginx" maintenance_restart_nginx_now
        else
          warn "Restart nginx dibatalkan."
        fi
        pause
        ;;
      4)
        if confirm_yn_or_back "Restart core service (xray + nginx) sekarang?"; then
          menu_run_isolated_report "Restart Core" maintenance_restart_core_now
        else
          warn "Restart core dibatalkan."
        fi
        pause
        ;;
      5) title ; tail_logs xray 160 ; hr ; pause ;;
      6) title ; tail_logs nginx 160 ; hr ; pause ;;
      7) menu_run_isolated_report "Wireproxy Status" wireproxy_status_menu ;;
      8) menu_run_isolated_report "Wireproxy Restart" wireproxy_restart_menu ;;
      9) menu_run_isolated_report "Daemon Status" daemon_status_menu ;;
      10) menu_run_isolated_report "SSHWS Status" sshws_status_menu ;;
      11) menu_run_isolated_report "SSHWS Restart" sshws_restart_menu ;;
      12) menu_run_isolated_report "SSHWS Diagnostics" sshws_diagnostics_menu ;;
      13) menu_run_isolated_report "Edge Runtime Status" edge_runtime_status_menu ;;
      14) menu_run_isolated_report "Edge Runtime Restart" edge_runtime_restart_menu ;;
      15) menu_run_isolated_report "Edge Runtime Info" edge_runtime_info_menu ;;
      16) menu_run_isolated_report "BadVPN Status" badvpn_status_menu ;;
      17) menu_run_isolated_report "BadVPN Restart" badvpn_restart_menu ;;
      18) menu_run_isolated_report "Normalize Quota Dates" maintenance_normalize_quota_dates_menu ;;
      0|kembali|k|back|b) break ;;
      *) warn "Pilihan tidak valid" ; sleep 1 ;;
    esac
  done
}

# -------------------------
