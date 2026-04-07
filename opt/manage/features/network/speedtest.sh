#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034

# -------------------------
# Speedtest
# -------------------------
speedtest_bin_get() {
  if have_cmd speedtest; then
    echo "speedtest"
    return 0
  fi
  if [[ -x /snap/bin/speedtest ]]; then
    echo "/snap/bin/speedtest"
    return 0
  fi
  echo ""
}

speedtest_run_now() {
  title
  echo "9) Speedtest > Run"
  hr

  local speedtest_bin
  speedtest_bin="$(speedtest_bin_get)"
  if [[ -z "${speedtest_bin}" ]]; then
    warn "speedtest belum tersedia. Jalankan setup.sh untuk install speedtest via snap."
    hr
    pause
    return 0
  fi

  local spin_log=""
  if ! ui_run_logged_command_with_spinner spin_log "Menjalankan speedtest" "${speedtest_bin}" --accept-license --accept-gdpr; then
    warn "Speedtest gagal dijalankan."
    hr
    tail -n 60 "${spin_log}" 2>/dev/null || true
    hr
    rm -f "${spin_log}" >/dev/null 2>&1 || true
    pause
    return 0
  fi
  if [[ -n "${spin_log}" && -s "${spin_log}" ]]; then
    cat "${spin_log}" 2>/dev/null || true
  fi
  rm -f "${spin_log}" >/dev/null 2>&1 || true
  hr
  pause
}

speedtest_show_version() {
  title
  echo "9) Speedtest > Version"
  hr

  local speedtest_bin
  speedtest_bin="$(speedtest_bin_get)"
  if [[ -z "${speedtest_bin}" ]]; then
    warn "speedtest belum tersedia."
    hr
    pause
    return 0
  fi

  if ! "${speedtest_bin}" --version 2>/dev/null; then
    warn "Tidak bisa membaca versi speedtest."
  fi
  hr
  pause
}

speedtest_menu() {
  local -a items=(
    "1|Run Speedtest"
    "2|Version"
    "0|Back"
  )
  while true; do
    ui_menu_screen_begin "5) Speedtest"
    ui_menu_render_options items 76
    hr
    if ! read -r -p "Pilih: " c; then
      echo
      break
    fi
    case "${c}" in
      1) speedtest_run_now ;;
      2) speedtest_show_version ;;
      0|kembali|k|back|b) break ;;
      *) warn "Pilihan tidak valid" ; sleep 1 ;;
    esac
  done
}

# -------------------------
