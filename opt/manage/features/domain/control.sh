#!/usr/bin/env bash
# shellcheck shell=bash

domain_menu_v2() {
  ui_menu_screen_begin "8) Domain Control > Set Domain" "Konfigurasi Domain TLS"
  echo -e "${UI_MUTED}Pilih metode domain untuk proses set domain.${UI_RESET}"
  echo -e "  ${UI_ACCENT}1)${UI_RESET} Input domain manual"
  echo -e "  ${UI_ACCENT}2)${UI_RESET} Gunakan domain yang disediakan"
  echo -e "  ${UI_ACCENT}0)${UI_RESET} Kembali"
  hr

  local choice=""
  while true; do
    if ! read -r -p "Pilih opsi (1-2/0/kembali): " choice; then
      echo
      return 2
    fi
    case "$choice" in
      1|2) break ;;
      0|kembali|k|back|b) return 2 ;;
      *) echo "Pilihan tidak valid." ;;
    esac
  done

  if [[ "$choice" == "1" ]]; then
    local re='^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$'
    while true; do
      if ! read -r -p "Masukkan domain (atau kembali): " DOMAIN; then
        echo
        return 2
      fi
      if is_back_choice "${DOMAIN}"; then
        return 2
      fi
      DOMAIN="${DOMAIN,,}"

      [[ -n "${DOMAIN:-}" ]] || {
        echo "Domain tidak boleh kosong."
        continue
      }

      if [[ "$DOMAIN" =~ $re ]]; then
        log "Domain valid: $DOMAIN"
        ACME_CERT_MODE="standalone"
        ACME_ROOT_DOMAIN=""
        CF_ZONE_ID=""
        break
      else
        echo "Domain tidak valid. Coba lagi."
      fi
    done
    return 0
  fi

  VPS_IPV4="$(get_public_ipv4)"
  log "Public IPv4 VPS: $VPS_IPV4"

  [[ ${#PROVIDED_ROOT_DOMAINS[@]} -gt 0 ]] || die "Daftar domain induk (PROVIDED_ROOT_DOMAINS) kosong."

  echo
  echo -e "${UI_BOLD}Pilih domain induk${UI_RESET}"
  local i=1
  local root=""
  for root in "${PROVIDED_ROOT_DOMAINS[@]}"; do
    echo -e "  ${UI_ACCENT}${i})${UI_RESET} ${root}"
    i=$((i + 1))
  done

  local pick=""
  while true; do
    if ! read -r -p "Pilih nomor domain induk (1-${#PROVIDED_ROOT_DOMAINS[@]}/kembali): " pick; then
      echo
      return 2
    fi
    if is_back_choice "${pick}"; then
      return 2
    fi
    [[ "$pick" =~ ^[0-9]+$ ]] || { echo "Input harus angka."; continue; }
    [[ "$pick" -ge 1 && "$pick" -le ${#PROVIDED_ROOT_DOMAINS[@]} ]] || { echo "Di luar range."; continue; }
    break
  done

  ACME_ROOT_DOMAIN="${PROVIDED_ROOT_DOMAINS[$((pick - 1))]}"
  log "Domain induk terpilih: $ACME_ROOT_DOMAIN"

  CF_ZONE_ID="$(cf_get_zone_id_by_name "$ACME_ROOT_DOMAIN" || true)"
  [[ -n "${CF_ZONE_ID:-}" ]] || die "Zone Cloudflare untuk $ACME_ROOT_DOMAIN tidak ditemukan / token tidak punya akses (butuh Zone:Read + DNS:Edit)."
  CF_ACCOUNT_ID="$(cf_get_account_id_by_zone "$CF_ZONE_ID" || true)"
  [[ -n "${CF_ACCOUNT_ID:-}" ]] || warn "Tidak bisa ambil CF_ACCOUNT_ID dari zone (acme.sh dns_cf mungkin tetap bisa jalan tanpa ini)."

  echo
  echo -e "${UI_BOLD}Pilih metode pembuatan subdomain${UI_RESET}"
  echo -e "  ${UI_ACCENT}1)${UI_RESET} Generate acak"
  echo -e "  ${UI_ACCENT}2)${UI_RESET} Input manual"

  local mth=""
  while true; do
    if ! read -r -p "Pilih opsi (1-2/kembali): " mth; then
      echo
      return 2
    fi
    case "$mth" in
      1|2) break ;;
      0|kembali|k|back|b) return 2 ;;
      *) echo "Pilihan tidak valid." ;;
    esac
  done

  local sub=""
  if [[ "$mth" == "1" ]]; then
    sub="$(gen_subdomain_random)"
    log "Subdomain generated: $sub"
  else
    while true; do
      if ! read -r -p "Masukkan nama subdomain (atau kembali): " sub; then
        echo
        return 2
      fi
      if is_back_choice "${sub}"; then
        return 2
      fi
      sub="${sub,,}"
      if validate_subdomain "$sub"; then
        log "Subdomain valid: $sub"
        break
      fi
      echo "Subdomain tidak valid. Hanya huruf kecil, angka, titik, dan strip (-). Tanpa spasi/kapital/karakter aneh."
    done
  fi

  echo
  local proxy_rc=0
  if confirm_yn_or_back "Aktifkan Cloudflare proxy (orange cloud) untuk DNS A record?"; then
    CF_PROXIED="true"
    log "Cloudflare proxy: ON (proxied=true)"
  else
    proxy_rc=$?
    if (( proxy_rc == 2 )); then
      warn "Input domain dibatalkan, kembali ke menu Domain Control."
      return 2
    fi
    CF_PROXIED="false"
    log "Cloudflare proxy: OFF (proxied=false)"
  fi

  DOMAIN="${sub}.${ACME_ROOT_DOMAIN}"
  log "Domain final: $DOMAIN"

  local cf_rc=0
  cf_validate_subdomain_a_record_choice "$CF_ZONE_ID" "$DOMAIN" "$VPS_IPV4" "$CF_PROXIED" || cf_rc=$?
  if (( cf_rc != 0 )); then
    if (( cf_rc == 1 || cf_rc == 2 )); then
      warn "Input domain dibatalkan, kembali ke menu Domain Control."
      return 2
    fi
    return "${cf_rc}"
  fi

  ACME_CERT_MODE="dns_cf_wildcard"
  log "Mode sertifikat: wildcard dns_cf untuk ${DOMAIN} (meliputi *.$DOMAIN)"
}

stop_conflicting_services() {
  DOMAIN_CTRL_STOPPED_SERVICES=()
  DOMAIN_CTRL_STOP_FAILURES=()

  local svc
  for svc in nginx apache2 caddy lighttpd; do
    if svc_exists "${svc}" && svc_is_active "${svc}"; then
      if systemctl stop "${svc}" >/dev/null 2>&1; then
        if svc_is_active "${svc}"; then
          DOMAIN_CTRL_STOP_FAILURES+=("${svc}: masih aktif setelah stop")
        else
          domain_control_append_stopped_service "${svc}"
        fi
      else
        DOMAIN_CTRL_STOP_FAILURES+=("${svc}: gagal dihentikan")
      fi
    fi
  done
  domain_control_stop_edge_runtime_if_needed
  if (( ${#DOMAIN_CTRL_STOP_FAILURES[@]} > 0 )); then
    return 1
  fi
  return 0
}

domain_control_port80_conflict_services_list() {
  local svc edge_svc=""
  for svc in nginx apache2 caddy lighttpd; do
    if svc_exists "${svc}" && svc_is_active "${svc}"; then
      printf '%s\n' "${svc}"
    fi
  done
  if edge_runtime_enabled_for_public_ports; then
    edge_svc="$(edge_runtime_service_name 2>/dev/null || true)"
    if [[ -n "${edge_svc}" && "${edge_svc}" != "nginx" ]] && svc_exists "${edge_svc}" && svc_is_active "${edge_svc}"; then
      printf '%s\n' "${edge_svc}"
    fi
  fi
}

domain_control_append_stopped_service() {
  local candidate="$1"
  local existing
  [[ -n "${candidate}" ]] || return 0
  for existing in "${DOMAIN_CTRL_STOPPED_SERVICES[@]}"; do
    [[ "${existing}" == "${candidate}" ]] && return 0
  done
  DOMAIN_CTRL_STOPPED_SERVICES+=("${candidate}")
}

domain_control_edge_runtime_service_name() {
  local provider env_file
  env_file="/etc/default/edge-runtime"
  provider="$(awk -F= '$1=="EDGE_PROVIDER"{print $2; exit}' "${env_file}" 2>/dev/null || echo "none")"
  case "${provider}" in
    nginx-stream) printf '%s\n' "nginx" ;;
    go) printf '%s\n' "edge-mux.service" ;;
    *) return 1 ;;
  esac
}

domain_control_edge_runtime_http_on_80() {
  local env_file provider active http_port
  env_file="/etc/default/edge-runtime"
  provider="$(awk -F= '$1=="EDGE_PROVIDER"{print $2; exit}' "${env_file}" 2>/dev/null || echo "none")"
  active="$(awk -F= '$1=="EDGE_ACTIVATE_RUNTIME"{print $2; exit}' "${env_file}" 2>/dev/null || echo "false")"
  http_port="$(awk -F= '$1=="EDGE_PUBLIC_HTTP_PORT"{print $2; exit}' "${env_file}" 2>/dev/null || echo "80")"
  [[ "${provider}" != "none" ]] || return 1
  case "${active}" in
    1|true|TRUE|yes|YES|on|ON) ;;
    *) return 1 ;;
  esac
  [[ "${http_port}" == "80" ]]
}

domain_control_stop_edge_runtime_if_needed() {
  local svc=""
  if domain_control_edge_runtime_http_on_80; then
    svc="$(domain_control_edge_runtime_service_name 2>/dev/null || true)"
    if [[ -n "${svc}" && "${svc}" != "nginx" ]] && svc_exists "${svc}" && svc_is_active "${svc}"; then
      if systemctl stop "${svc}" >/dev/null 2>&1; then
        if svc_is_active "${svc}"; then
          DOMAIN_CTRL_STOP_FAILURES+=("${svc}: masih aktif setelah stop")
        else
          domain_control_append_stopped_service "${svc}"
        fi
      else
        DOMAIN_CTRL_STOP_FAILURES+=("${svc}: gagal dihentikan")
      fi
    fi
  fi
}

domain_control_restart_active_tls_runtime_consumers() {
  if [[ "${DOMAIN_CTRL_RUNTIME_SNAPSHOT_VALID:-0}" == "1" ]]; then
    domain_control_restore_tls_runtime_consumers_from_snapshot "${DOMAIN_CTRL_STOPPED_SERVICES[@]}"
    return $?
  fi

  local edge_svc
  if svc_exists sshws-stunnel && svc_is_active sshws-stunnel; then
    systemctl restart sshws-stunnel >/dev/null 2>&1 || {
      warn "Gagal restart sshws-stunnel setelah update cert."
      return 1
    }
    svc_is_active sshws-stunnel || {
      warn "sshws-stunnel tidak active setelah update cert."
      return 1
    }
  fi
  edge_svc="$(domain_control_edge_runtime_service_name 2>/dev/null || true)"
  if [[ -n "${edge_svc}" && "${edge_svc}" != "nginx" ]] && svc_exists "${edge_svc}" && svc_is_active "${edge_svc}"; then
    systemctl restart "${edge_svc}" >/dev/null 2>&1 || {
      warn "Gagal restart ${edge_svc} setelah update cert."
      return 1
    }
    svc_is_active "${edge_svc}" || {
      warn "${edge_svc} tidak active setelah update cert."
      return 1
    }
  fi
  return 0
}

domain_control_clear_runtime_snapshot() {
  DOMAIN_CTRL_RUNTIME_SNAPSHOT_VALID="0"
  DOMAIN_CTRL_NGINX_WAS_ACTIVE="0"
  DOMAIN_CTRL_TLS_RUNTIME_ACTIVE_SERVICES=()
}

domain_control_capture_runtime_snapshot() {
  local edge_svc
  domain_control_clear_runtime_snapshot

  if svc_exists nginx && svc_is_active nginx; then
    DOMAIN_CTRL_NGINX_WAS_ACTIVE="1"
  fi
  if svc_exists sshws-stunnel && svc_is_active sshws-stunnel; then
    DOMAIN_CTRL_TLS_RUNTIME_ACTIVE_SERVICES+=("sshws-stunnel")
  fi
  edge_svc="$(domain_control_edge_runtime_service_name 2>/dev/null || true)"
  if [[ -n "${edge_svc}" && "${edge_svc}" != "nginx" && "${edge_svc}" != "sshws-stunnel" ]] && svc_exists "${edge_svc}" && svc_is_active "${edge_svc}"; then
    DOMAIN_CTRL_TLS_RUNTIME_ACTIVE_SERVICES+=("${edge_svc}")
  fi
  DOMAIN_CTRL_RUNTIME_SNAPSHOT_VALID="1"
}

domain_control_tls_service_was_active() {
  local svc="${1:-}"
  local item
  for item in "${DOMAIN_CTRL_TLS_RUNTIME_ACTIVE_SERVICES[@]}"; do
    [[ "${item}" == "${svc}" ]] && return 0
  done
  return 1
}

domain_control_restore_tls_runtime_consumers_from_snapshot() {
  local -a skipped_services=("$@")
  local edge_svc svc
  local rc=0
  local -a targets=("sshws-stunnel")
  local skipped

  edge_svc="$(domain_control_edge_runtime_service_name 2>/dev/null || true)"
  if [[ -n "${edge_svc}" && "${edge_svc}" != "nginx" && "${edge_svc}" != "sshws-stunnel" ]]; then
    targets+=("${edge_svc}")
  fi

  for svc in "${targets[@]}"; do
    for skipped in "${skipped_services[@]}"; do
      [[ "${skipped}" == "${svc}" ]] && continue 2
    done
    if domain_control_tls_service_was_active "${svc}"; then
      if ! svc_exists "${svc}"; then
        warn "Service TLS ${svc} tidak ditemukan saat rollback."
        rc=1
        continue
      fi
      if ! svc_restart_checked "${svc}" 60; then
        warn "Gagal memulihkan service TLS ${svc} saat rollback."
        rc=1
      fi
    elif svc_exists "${svc}" && svc_is_active "${svc}"; then
      if ! svc_stop_checked "${svc}" 60; then
        warn "Gagal mengembalikan ${svc} ke state inactive saat rollback."
        rc=1
      fi
    fi
  done

  return "${rc}"
}

domain_control_restore_cert_runtime_after_rollback() {
  local notes_name="$1"
  local rc=0
  [[ -n "${notes_name}" ]] || return 1
  declare -n notes_out="${notes_name}"

  if [[ "${DOMAIN_CTRL_NGINX_WAS_ACTIVE:-0}" == "1" ]]; then
    if ! svc_restart_checked nginx 60; then
      notes_out+=("restore nginx rollback gagal")
      rc=1
    fi
  elif svc_exists nginx && svc_is_active nginx; then
    if ! svc_stop_checked nginx 60; then
      notes_out+=("nginx rollback gagal dikembalikan ke inactive")
      rc=1
    fi
  fi
  if ! domain_control_restore_tls_runtime_consumers_from_snapshot; then
    notes_out+=("reload consumer TLS rollback gagal")
    rc=1
  fi
  return "${rc}"
}

domain_control_restore_after_cert_success() {
  local svc
  for svc in "${DOMAIN_CTRL_STOPPED_SERVICES[@]}"; do
    [[ "${svc}" == "nginx" ]] && continue
    if svc_exists "${svc}"; then
      svc_start_checked "${svc}" 60 || {
        warn "Gagal restore service ${svc} setelah update cert."
        return 1
      }
    fi
  done
  domain_control_clear_stopped_services
  return 0
}

domain_control_restore_non_nginx_conflicts_after_issue() {
  local svc
  local rc=0
  local -a keep_services=()

  if (( ${#DOMAIN_CTRL_STOPPED_SERVICES[@]} == 0 )); then
    return 0
  fi

  for svc in "${DOMAIN_CTRL_STOPPED_SERVICES[@]}"; do
    if [[ "${svc}" == "nginx" ]]; then
      keep_services+=("${svc}")
      continue
    fi
    if svc_exists "${svc}"; then
      if ! svc_start_checked "${svc}" 60; then
        warn "Gagal memulihkan service konflik ${svc} segera setelah issue cert."
        keep_services+=("${svc}")
        rc=1
      fi
    fi
  done

  DOMAIN_CTRL_STOPPED_SERVICES=("${keep_services[@]}")
  return "${rc}"
}

domain_control_restore_stopped_services() {
  if (( ${#DOMAIN_CTRL_STOPPED_SERVICES[@]} == 0 )); then
    return 0
  fi

  local svc
  local rc=0
  for svc in "${DOMAIN_CTRL_STOPPED_SERVICES[@]}"; do
    if svc_exists "${svc}"; then
      if ! svc_start_checked "${svc}" 60; then
        warn "Gagal restore service: ${svc}"
        rc=1
      fi
    fi
  done
  return "${rc}"
}

domain_control_clear_stopped_services() {
  DOMAIN_CTRL_STOPPED_SERVICES=()
  DOMAIN_CTRL_STOP_FAILURES=()
}

cert_renew_service_journal_write() {
  local svc=""
  mkdir -p "${WORK_DIR}" 2>/dev/null || return 1
  : > "${CERT_RENEW_SERVICE_JOURNAL_FILE}" || return 1
  for svc in "${DOMAIN_CTRL_STOPPED_SERVICES[@]}"; do
    [[ -n "${svc}" ]] || continue
    printf '%s\n' "${svc}" >> "${CERT_RENEW_SERVICE_JOURNAL_FILE}" || return 1
  done
  chmod 600 "${CERT_RENEW_SERVICE_JOURNAL_FILE}" 2>/dev/null || true
  return 0
}

cert_renew_service_journal_clear() {
  rm -f "${CERT_RENEW_SERVICE_JOURNAL_FILE}" >/dev/null 2>&1 || true
}

cert_renew_cert_journal_write() {
  local domain="${1:-}"
  local backup_dir="${2:-}"
  local tmp=""
  [[ -n "${domain}" && -n "${backup_dir}" ]] || return 1
  mkdir -p "${WORK_DIR}" 2>/dev/null || return 1
  tmp="$(mktemp "${WORK_DIR}/.cert-renew-cert.XXXXXX" 2>/dev/null || true)"
  [[ -n "${tmp}" ]] || return 1
  {
    printf 'domain=%s\n' "${domain}"
    printf 'backup_dir=%s\n' "${backup_dir}"
    printf 'created_at=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  } > "${tmp}" || {
    rm -f "${tmp}" >/dev/null 2>&1 || true
    return 1
  }
  chmod 600 "${tmp}" 2>/dev/null || true
  mv -f "${tmp}" "${CERT_RENEW_CERT_JOURNAL_FILE}" || {
    rm -f "${tmp}" >/dev/null 2>&1 || true
    return 1
  }
  chmod 600 "${CERT_RENEW_CERT_JOURNAL_FILE}" 2>/dev/null || true
  return 0
}

cert_renew_cert_journal_clear() {
  rm -f "${CERT_RENEW_CERT_JOURNAL_FILE}" >/dev/null 2>&1 || true
}

cert_renew_cert_journal_field_get() {
  local key="${1:-}"
  [[ -n "${key}" && -f "${CERT_RENEW_CERT_JOURNAL_FILE}" ]] || return 1
  awk -F= -v want="${key}" '$1==want {print substr($0, index($0, "=")+1); exit}' "${CERT_RENEW_CERT_JOURNAL_FILE}" 2>/dev/null
}

domain_control_current_nginx_domain_get() {
  grep -E '^[[:space:]]*server_name[[:space:]]+' "${NGINX_CONF}" 2>/dev/null \
    | head -n1 \
    | sed -E 's/^[[:space:]]*server_name[[:space:]]+//; s/;.*$//' \
    | awk '{print $1}' \
    | tr -d ';' || true
}

domain_control_cf_sync_pending_dir_prepare() {
  mkdir -p "${DOMAIN_CONTROL_CF_SYNC_PENDING_DIR}" 2>/dev/null || return 1
  chmod 700 "${DOMAIN_CONTROL_CF_SYNC_PENDING_DIR}" 2>/dev/null || true
}

domain_control_cf_sync_pending_key_for_domain() {
  local domain="${1:-}"
  domain="$(normalize_domain_token "${domain}")"
  [[ -n "${domain}" ]] || return 1
  printf '%s\n' "${domain//\//_}"
}

domain_control_cf_sync_pending_file_for_domain() {
  local domain="${1:-}"
  local key=""
  key="$(domain_control_cf_sync_pending_key_for_domain "${domain}")" || return 1
  domain_control_cf_sync_pending_dir_prepare || return 1
  printf '%s/%s.pending\n' "${DOMAIN_CONTROL_CF_SYNC_PENDING_DIR}" "${key}"
}

domain_control_cf_sync_pending_legacy_migrate() {
  local legacy_domain="" target_file=""
  [[ -f "${DOMAIN_CONTROL_CF_SYNC_PENDING_FILE}" ]] || return 0
  legacy_domain="$(awk -F= '$1=="domain" {print substr($0, index($0, "=")+1); exit}' "${DOMAIN_CONTROL_CF_SYNC_PENDING_FILE}" 2>/dev/null || true)"
  legacy_domain="$(normalize_domain_token "${legacy_domain}")"
  [[ -n "${legacy_domain}" ]] || return 0
  target_file="$(domain_control_cf_sync_pending_file_for_domain "${legacy_domain}" 2>/dev/null || true)"
  [[ -n "${target_file}" ]] || return 0
  if [[ ! -f "${target_file}" ]]; then
    mv -f "${DOMAIN_CONTROL_CF_SYNC_PENDING_FILE}" "${target_file}" >/dev/null 2>&1 || true
  else
    rm -f "${DOMAIN_CONTROL_CF_SYNC_PENDING_FILE}" >/dev/null 2>&1 || true
  fi
}

domain_control_cf_sync_pending_list_files() {
  local file=""
  domain_control_cf_sync_pending_legacy_migrate
  domain_control_cf_sync_pending_dir_prepare || return 0
  while IFS= read -r -d '' file; do
    [[ -s "${file}" ]] || continue
    printf '%s\n' "${file}"
  done < <(find "${DOMAIN_CONTROL_CF_SYNC_PENDING_DIR}" -maxdepth 1 -type f -name '*.pending' -print0 2>/dev/null | sort -z)
}

domain_control_cf_sync_pending_find_file() {
  local domain="${1:-}"
  local file=""
  domain_control_cf_sync_pending_legacy_migrate
  if [[ -n "${domain}" ]]; then
    file="$(domain_control_cf_sync_pending_file_for_domain "${domain}" 2>/dev/null || true)"
    [[ -n "${file}" && -f "${file}" ]] || return 1
    printf '%s\n' "${file}"
    return 0
  fi
  file="$(domain_control_cf_sync_pending_list_files | head -n1 || true)"
  [[ -n "${file}" ]] || return 1
  printf '%s\n' "${file}"
}

domain_control_cf_sync_pending_exists() {
  local domain="${1:-}"
  if [[ -n "${domain}" ]]; then
    domain_control_cf_sync_pending_find_file "${domain}" >/dev/null 2>&1
    return $?
  fi
  [[ -n "$(domain_control_cf_sync_pending_list_files | head -n1 || true)" ]]
}

domain_control_cf_sync_pending_count() {
  local domain="${1:-}"
  local file="" count=0
  if [[ -n "${domain}" ]]; then
    file="$(domain_control_cf_sync_pending_find_file "${domain}" 2>/dev/null || true)"
    [[ -n "${file}" ]] && count=1
    printf '%s\n' "${count}"
    return 0
  fi
  while IFS= read -r file; do
    [[ -n "${file}" ]] || continue
    count=$((count + 1))
  done < <(domain_control_cf_sync_pending_list_files)
  printf '%s\n' "${count}"
}

domain_control_cf_sync_pending_field_get_from_file() {
  local file="${1:-}"
  local key="${2:-}"
  [[ -n "${file}" && -f "${file}" && -n "${key}" ]] || return 1
  awk -F= -v want="${key}" '$1==want {print substr($0, index($0, "=")+1); exit}' "${file}" 2>/dev/null
}

domain_control_cf_sync_pending_field_get() {
  local key="${1:-}"
  local domain="${2:-}"
  local file=""
  [[ -n "${key}" ]] || return 1
  file="$(domain_control_cf_sync_pending_find_file "${domain}" 2>/dev/null || true)"
  [[ -n "${file}" ]] || return 1
  domain_control_cf_sync_pending_field_get_from_file "${file}" "${key}"
}

domain_control_cf_sync_pending_write() {
  local domain="${1:-}"
  local zone_id="${2:-}"
  local ipv4="${3:-}"
  local proxied="${4:-false}"
  local runtime_domain="${5:-}"
  local nginx_domain="${6:-}"
  local tmp="" target_file=""
  [[ -n "${domain}" && -n "${zone_id}" && -n "${ipv4}" ]] || return 1
  DOMAIN_CONTROL_CF_SYNC_PENDING_LAST_ERROR=""
  runtime_domain="$(normalize_domain_token "${runtime_domain:-$(detect_domain)}")"
  nginx_domain="$(normalize_domain_token "${nginx_domain:-$(domain_control_current_nginx_domain_get)}")"
  target_file="$(domain_control_cf_sync_pending_file_for_domain "${domain}" 2>/dev/null || true)"
  [[ -n "${target_file}" ]] || return 1
  mkdir -p "${WORK_DIR}" 2>/dev/null || return 1
  tmp="$(mktemp "${WORK_DIR}/.cf-sync-pending.XXXXXX" 2>/dev/null || true)"
  [[ -n "${tmp}" ]] || return 1
  {
    printf 'domain=%s\n' "${domain}"
    printf 'zone_id=%s\n' "${zone_id}"
    printf 'ipv4=%s\n' "${ipv4}"
    printf 'proxied=%s\n' "${proxied}"
    printf 'runtime_domain=%s\n' "${runtime_domain}"
    printf 'nginx_domain=%s\n' "${nginx_domain}"
    printf 'created_at=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  } > "${tmp}" || {
    rm -f "${tmp}" >/dev/null 2>&1 || true
    return 1
  }
  chmod 600 "${tmp}" 2>/dev/null || true
  mv -f "${tmp}" "${target_file}" || {
    rm -f "${tmp}" >/dev/null 2>&1 || true
    return 1
  }
}

domain_control_cf_sync_pending_clear() {
  local domain="${1:-}"
  local file=""
  domain_control_cf_sync_pending_legacy_migrate
  if [[ -n "${domain}" ]]; then
    file="$(domain_control_cf_sync_pending_file_for_domain "${domain}" 2>/dev/null || true)"
    [[ -n "${file}" ]] && rm -f "${file}" >/dev/null 2>&1 || true
    return 0
  fi
  rm -f "${DOMAIN_CONTROL_CF_SYNC_PENDING_FILE}" >/dev/null 2>&1 || true
  rm -f "${DOMAIN_CONTROL_CF_SYNC_PENDING_DIR}"/*.pending >/dev/null 2>&1 || true
}

domain_control_cf_sync_pending_clear_if_domain_matches() {
  local domain="${1:-}"
  [[ -n "${domain}" ]] || return 0
  domain_control_cf_sync_pending_clear "${domain}"
}

cert_renew_service_recover_if_needed() {
  local svc=""
  local -a journal_services=()

  [[ -s "${CERT_RENEW_SERVICE_JOURNAL_FILE}" ]] || return 0

  while IFS= read -r svc; do
    [[ -n "${svc}" ]] || continue
    journal_services+=("${svc}")
  done < "${CERT_RENEW_SERVICE_JOURNAL_FILE}"

  if (( ${#journal_services[@]} == 0 )); then
    cert_renew_service_journal_clear
    return 0
  fi

  warn "Terdeteksi renew certificate yang belum selesai. Mencoba memulihkan service publik yang sebelumnya dihentikan..."
  DOMAIN_CTRL_STOPPED_SERVICES=("${journal_services[@]}")
  if domain_control_restore_stopped_services_strict 3; then
    domain_control_clear_stopped_services
    cert_renew_service_journal_clear
    log "Service publik dari renew sebelumnya berhasil dipulihkan."
    return 0
  fi

  warn "Sebagian service publik dari renew sebelumnya masih gagal dipulihkan. Journal pemulihan dipertahankan."
  return 1
}

cert_renew_cert_recover_if_needed() {
  local domain="" backup_dir="" created_at=""
  local -a notes=()

  [[ -s "${CERT_RENEW_CERT_JOURNAL_FILE}" ]] || return 0

  domain="$(cert_renew_cert_journal_field_get domain 2>/dev/null || true)"
  backup_dir="$(cert_renew_cert_journal_field_get backup_dir 2>/dev/null || true)"
  created_at="$(cert_renew_cert_journal_field_get created_at 2>/dev/null || true)"
  if [[ -z "${backup_dir}" || ! -d "${backup_dir}" ]]; then
    warn "Journal recovery cert renew ditemukan, tetapi snapshot cert tidak lagi tersedia."
    cert_renew_cert_journal_clear
    return 1
  fi

  warn "Terdeteksi rollback cert renew yang belum selesai sejak ${created_at:-waktu tidak diketahui}. Mencoba memulihkan snapshot cert..."
  if ! cert_snapshot_restore "${backup_dir}" >/dev/null 2>&1; then
    warn "Restore snapshot cert dari ${backup_dir} gagal. Journal recovery dipertahankan."
    return 1
  fi
  if svc_exists nginx && svc_is_active nginx; then
    if ! nginx_restart_checked_with_listener >/dev/null 2>&1; then
      sleep 2
      if ! nginx_restart_checked_with_listener >/dev/null 2>&1; then
        notes+=("restart nginx gagal")
      fi
    fi
  fi
  if ! cert_runtime_restart_active_tls_consumers >/dev/null 2>&1; then
    sleep 2
    if ! cert_runtime_restart_active_tls_consumers >/dev/null 2>&1; then
      notes+=("restart consumer TLS gagal")
    fi
  fi
  if [[ -n "${domain}" ]] && ! cert_runtime_hostname_tls_handshake_check "${domain}" >/dev/null 2>&1; then
    sleep 2
    if ! cert_runtime_hostname_tls_handshake_check "${domain}" >/dev/null 2>&1; then
      notes+=("probe TLS hostname gagal")
    fi
  fi
  if (( ${#notes[@]} > 0 )); then
    warn "Recovery cert renew belum bersih: $(IFS=' | '; echo "${notes[*]}"). Snapshot tetap dipertahankan di ${backup_dir}."
    return 1
  fi

  rm -rf "${backup_dir}" >/dev/null 2>&1 || true
  cert_renew_cert_journal_clear
  log "Recovery cert renew selesai untuk domain ${domain:-"(tidak diketahui)"}."
  return 0
}

domain_control_restore_on_exit() {
  # Safety net: jika proses domain control gagal di tengah (die/exit),
  # service yang sebelumnya aktif dipulihkan otomatis.
  if [[ "${DOMAIN_CTRL_TXN_ACTIVE:-0}" == "1" ]]; then
    local -a txn_notes=()
    warn "Domain Control berhenti sebelum transaksi domain selesai. Mencoba rollback snapshot..."
    if ! domain_control_txn_restore txn_notes; then
      if (( ${#txn_notes[@]} > 0 )); then
        warn "Rollback transaksi domain belum bersih: $(IFS=' | '; echo "${txn_notes[*]}")"
      fi
    fi
    domain_control_clear_runtime_snapshot
  fi
  if (( ${#DOMAIN_CTRL_STOPPED_SERVICES[@]} > 0 )); then
    warn "Domain Control berhenti sebelum selesai. Mencoba restore service yang tadi dihentikan..."
    if domain_control_restore_stopped_services; then
      domain_control_clear_stopped_services
    else
      warn "Sebagian service gagal dipulihkan pada EXIT safety-net."
    fi
  fi
}

install_acme_and_issue_cert() {
  local install_fullchain="${1:-${CERT_FULLCHAIN}}"
  local install_privkey="${2:-${CERT_PRIVKEY}}"
  local email
  email="$(rand_email)"
  log "Email acme.sh (acak): $email"

	  if [[ "${ACME_CERT_MODE:-standalone}" == "dns_cf_wildcard" ]]; then
    domain_control_clear_stopped_services
  fi

  local acme_tmpdir acme_src_dir acme_tgz acme_install_log
  acme_tmpdir="$(mktemp -d)"
  acme_tgz="${acme_tmpdir}/acme.tar.gz"
  acme_install_log="${acme_tmpdir}/acme-install.log"
  acme_src_dir=""

  if download_file_checked "${ACME_SH_TARBALL_URL}" "${acme_tgz}" "acme.sh tarball"; then
    if tar -xzf "${acme_tgz}" -C "${acme_tmpdir}" >/dev/null 2>&1; then
      acme_src_dir="$(find "${acme_tmpdir}" -maxdepth 1 -type d -name 'acme.sh-*' -print -quit)"
    fi
  fi

  if [[ -z "${acme_src_dir:-}" || ! -f "${acme_src_dir}/acme.sh" ]]; then
    warn "Source bundle acme.sh tidak tersedia, fallback ke single-file installer."
    acme_src_dir="${acme_tmpdir}/acme-single"
    mkdir -p "${acme_src_dir}"
    download_file_or_die "${ACME_SH_SCRIPT_URL}" "${acme_src_dir}/acme.sh" "" "acme.sh script"
  fi

  chmod 700 "${acme_src_dir}/acme.sh"
  if ! (cd "${acme_src_dir}" && bash ./acme.sh --install --home /root/.acme.sh --accountemail "$email") >"${acme_install_log}" 2>&1; then
    warn "Install acme.sh gagal. Ringkasan log:"
    sed -n '1,120p' "${acme_install_log}" >&2 || true
    rm -rf "${acme_tmpdir}" >/dev/null 2>&1 || true
    die "Gagal install acme.sh dari ref ${ACME_SH_INSTALL_REF}."
  fi
  rm -rf "${acme_tmpdir}" >/dev/null 2>&1 || true

  export PATH="/root/.acme.sh:${PATH}"
  [[ -x /root/.acme.sh/acme.sh ]] || die "acme.sh tidak ditemukan setelah proses install."
  /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null || true

  mkdir -p "${CERT_DIR}" "$(dirname "${install_fullchain}")" "$(dirname "${install_privkey}")"
  chmod 700 "${CERT_DIR}" >/dev/null 2>&1 || true

  if [[ "${ACME_CERT_MODE:-standalone}" == "dns_cf_wildcard" ]]; then
    [[ -n "${ACME_ROOT_DOMAIN:-}" ]] || die "ACME_ROOT_DOMAIN kosong (mode dns_cf_wildcard)."
    [[ -n "${DOMAIN:-}" ]] || die "DOMAIN kosong (mode dns_cf_wildcard)."
    [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]] || die "CLOUDFLARE_API_TOKEN kosong untuk mode wildcard dns_cf."
    log "Issue sertifikat wildcard untuk ${DOMAIN} via acme.sh (dns_cf)..."

    if [[ ! -s /root/.acme.sh/dnsapi/dns_cf.sh ]]; then
      warn "dns_cf hook tidak ditemukan, mencoba bootstrap dari ref ${ACME_SH_INSTALL_REF} ..."
      mkdir -p /root/.acme.sh/dnsapi
      download_file_or_die "${ACME_SH_DNS_CF_HOOK_URL}" /root/.acme.sh/dnsapi/dns_cf.sh "" "acme dns_cf hook"
      chmod 700 /root/.acme.sh/dnsapi/dns_cf.sh >/dev/null 2>&1 || true
    fi
    [[ -s /root/.acme.sh/dnsapi/dns_cf.sh ]] || die "Hook dns_cf tetap tidak ditemukan setelah bootstrap."

    if ! cf_api GET "/user/tokens/verify" >/dev/null 2>&1; then
      die "Token Cloudflare tidak valid/kurang scope. Butuh minimal: Zone:DNS Edit + Zone:Read untuk zone domain."
    fi

    export CF_Token="$CLOUDFLARE_API_TOKEN"
    [[ -n "${CF_ACCOUNT_ID:-}" ]] && export CF_Account_ID="$CF_ACCOUNT_ID"
    [[ -n "${CF_ZONE_ID:-}" ]] && export CF_Zone_ID="$CF_ZONE_ID"

    /root/.acme.sh/acme.sh --issue --force --dns dns_cf \
      -d "$DOMAIN" -d "*.$DOMAIN" \
      || die "Gagal issue sertifikat wildcard via dns_cf (pastikan token Cloudflare valid)."

    /root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
      --key-file "${install_privkey}" \
      --fullchain-file "${install_fullchain}" \
      --reloadcmd "/bin/true" >/dev/null || {
        warn "Gagal install-cert wildcard ke ${CERT_DIR}."
        return 1
      }
	  else
	    local -a conflict_services=()
	    while IFS= read -r svc; do
	      [[ -n "${svc}" ]] || continue
	      conflict_services+=("${svc}")
	    done < <(domain_control_port80_conflict_services_list)
	    if (( ${#conflict_services[@]} > 0 )); then
	      warn "Terdeteksi konflik port 80. Set Domain standalone sekarang fail-closed dan tidak lagi menghentikan service publik otomatis."
	      warn "Service aktif di port 80: $(IFS=', '; echo "${conflict_services[*]}")"
	      warn "Bebaskan port 80 secara manual lalu jalankan Set Domain lagi."
	      return 1
	    fi
	    log "Issue sertifikat untuk $DOMAIN via acme.sh (standalone port 80)..."
	    /root/.acme.sh/acme.sh --issue --force --standalone -d "$DOMAIN" --httpport 80 \
	      || die "Gagal issue sertifikat (pastikan port 80 terbuka & DNS domain mengarah ke VPS)."

    /root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
      --key-file "${install_privkey}" \
      --fullchain-file "${install_fullchain}" \
	      --reloadcmd "/bin/true" >/dev/null || {
	        warn "Gagal install-cert standalone ke ${CERT_DIR}."
	        return 1
	      }
	  fi

  chmod 600 "${install_privkey}" "${install_fullchain}" >/dev/null 2>&1 || true

  log "Sertifikat tersimpan:"
  log "  - ${install_fullchain}"
  log "  - ${install_privkey}"
}

acme_install_targets_pin_live() {
  local domain="${1:-${DOMAIN:-}}"
  local install_fullchain="${2:-${CERT_FULLCHAIN}}"
  local install_privkey="${3:-${CERT_PRIVKEY}}"
  local acme="/root/.acme.sh/acme.sh"

  [[ -n "${domain}" ]] || return 1
  [[ -x "${acme}" ]] || return 1

  mkdir -p "${CERT_DIR}" "$(dirname "${install_fullchain}")" "$(dirname "${install_privkey}")" >/dev/null 2>&1 || return 1
  chmod 700 "${CERT_DIR}" >/dev/null 2>&1 || true

  "${acme}" --install-cert -d "${domain}" \
    --key-file "${install_privkey}" \
    --fullchain-file "${install_fullchain}" \
    --reloadcmd "/bin/true" >/dev/null 2>&1
}

domain_control_activate_cert_runtime_after_install() {
  local staged_fullchain="${1:-}"
  local staged_privkey="${2:-}"
  if [[ -n "${staged_fullchain}" || -n "${staged_privkey}" ]]; then
    if ! cert_stage_install_to_live "${staged_fullchain}" "${staged_privkey}"; then
      warn "Gagal memasang file sertifikat staged ke path live."
      return 1
    fi
  fi
  if ! domain_control_restart_active_tls_runtime_consumers; then
    warn "Gagal restart consumer TLS tambahan setelah update cert."
    return 1
  fi
  if ! domain_control_restore_after_cert_success; then
    warn "Gagal memulihkan service konflik setelah update cert."
    return 1
  fi
  if ! acme_install_targets_pin_live "${DOMAIN}" "${CERT_FULLCHAIN}" "${CERT_PRIVKEY}"; then
    warn "Gagal menyelaraskan target install acme.sh ke path cert live."
    return 1
  fi
  return 0
}

domain_control_apply_nginx_domain() {
  local domain="$1"
  local applied_domain
  local backup candidate preflight_rc=0
  domain="$(printf '%s' "${domain}" | tr -d '\r\n' | awk '{print $1}' | tr -d ';')"
  [[ -n "${domain}" ]] || die "Domain kosong."
  [[ -f "${NGINX_CONF}" ]] || die "Nginx conf tidak ditemukan: ${NGINX_CONF}"
  ensure_path_writable "${NGINX_CONF}"

  backup="${WORK_DIR}/xray.conf.domain-backup.$(date +%s)"
  cp -a "${NGINX_CONF}" "${backup}" || die "Gagal membuat backup nginx conf."
  candidate="$(mktemp "${WORK_DIR}/xray.conf.domain-candidate.XXXXXX" 2>/dev/null || true)"
  [[ -n "${candidate}" ]] || die "Gagal membuat candidate nginx conf."

  if ! sed -E "s|^([[:space:]]*server_name[[:space:]]+)[^;]+;|\\1${domain};|g" "${NGINX_CONF}" > "${candidate}"; then
    rm -f "${candidate}" >/dev/null 2>&1 || true
    die "Gagal update server_name di nginx conf."
  fi

  applied_domain="$(grep -E '^[[:space:]]*server_name[[:space:]]+' "${candidate}" 2>/dev/null | head -n1 | sed -E 's/^[[:space:]]*server_name[[:space:]]+//; s/;.*$//' | awk '{print $1}' | tr -d ';' || true)"
  if [[ -z "${applied_domain}" || "${applied_domain}" != "${domain}" ]]; then
    rm -f "${candidate}" >/dev/null 2>&1 || true
    die "server_name nginx tidak sesuai setelah update (expect=${domain}, got=${applied_domain:-<kosong>})."
  fi

  if nginx_conf_test_with_override "${NGINX_CONF}" "${candidate}"; then
    :
  else
    preflight_rc=$?
    rm -f "${candidate}" >/dev/null 2>&1 || true
    if (( preflight_rc == 1 )); then
      die "Konfigurasi nginx candidate invalid sebelum diterapkan ke file live."
    fi
    die "Preflight nginx candidate tidak tersedia. Batalkan apply domain agar nginx conf tidak diuji hanya setelah file live diganti."
  fi

  local nginx_mode nginx_uid nginx_gid nginx_tmp_target=""
  nginx_mode="$(stat -c '%a' "${NGINX_CONF}" 2>/dev/null || echo '644')"
  nginx_uid="$(stat -c '%u' "${NGINX_CONF}" 2>/dev/null || echo '0')"
  nginx_gid="$(stat -c '%g' "${NGINX_CONF}" 2>/dev/null || echo '0')"
  nginx_tmp_target="$(mktemp "$(dirname "${NGINX_CONF}")/.xray.conf.new.XXXXXX" 2>/dev/null || true)"
  if [[ -z "${nginx_tmp_target}" ]] || ! cp -f -- "${candidate}" "${nginx_tmp_target}" >/dev/null 2>&1; then
    rm -f "${candidate}" >/dev/null 2>&1 || true
    cp -a "${backup}" "${NGINX_CONF}" >/dev/null 2>&1 || die "Gagal memasang candidate nginx conf; restore backup nginx juga gagal."
    die "Gagal mengganti nginx conf secara atomic."
  fi
  chmod "${nginx_mode}" "${nginx_tmp_target}" 2>/dev/null || chmod 644 "${nginx_tmp_target}" 2>/dev/null || true
  chown "${nginx_uid}:${nginx_gid}" "${nginx_tmp_target}" 2>/dev/null || true
  if ! mv -f "${nginx_tmp_target}" "${NGINX_CONF}" >/dev/null 2>&1; then
    rm -f "${nginx_tmp_target}" >/dev/null 2>&1 || true
    rm -f "${candidate}" >/dev/null 2>&1 || true
    cp -a "${backup}" "${NGINX_CONF}" >/dev/null 2>&1 || die "Gagal memasang candidate nginx conf; restore backup nginx juga gagal."
    die "Gagal mengganti nginx conf secara atomic."
  fi
  rm -f "${candidate}" >/dev/null 2>&1 || true

  if ! nginx -t >/dev/null 2>&1; then
    warn "nginx -t gagal setelah update domain, rollback ke backup."
    cp -a "${backup}" "${NGINX_CONF}" >/dev/null 2>&1 || die "Konfigurasi nginx invalid setelah ubah domain; restore backup nginx gagal."
    nginx -t >/dev/null 2>&1 || die "Konfigurasi nginx invalid setelah ubah domain; backup nginx juga tidak valid saat rollback."
    die "Konfigurasi nginx invalid setelah ubah domain."
  fi

  if ! svc_restart_checked nginx 60; then
    warn "Restart nginx gagal setelah update domain, rollback ke backup."
    cp -a "${backup}" "${NGINX_CONF}" >/dev/null 2>&1 || die "Gagal restart nginx setelah ubah domain; restore backup nginx juga gagal."
    nginx -t >/dev/null 2>&1 || die "Gagal restart nginx setelah ubah domain; backup nginx tidak valid saat rollback."
    if ! svc_restart_checked nginx 60; then
      die "Gagal restart nginx setelah ubah domain; rollback nginx juga gagal."
    fi
    die "Gagal restart nginx setelah ubah domain. Perubahan nginx sudah di-rollback."
  fi

  if ! sync_xray_domain_file "${applied_domain}"; then
    warn "Compat domain file gagal disinkronkan ke ${XRAY_DOMAIN_FILE}. Mengembalikan candidate nginx agar domain tidak aktif setengah jadi."
    cp -a "${backup}" "${NGINX_CONF}" >/dev/null 2>&1 || die "Compat domain file gagal disinkronkan; restore backup nginx juga gagal."
    nginx -t >/dev/null 2>&1 || die "Compat domain file gagal disinkronkan; backup nginx tidak valid saat rollback."
    if ! svc_restart_checked nginx 60; then
      die "Compat domain file gagal disinkronkan; rollback nginx juga gagal."
    fi
    die "Compat domain file gagal disinkronkan setelah apply domain."
  fi

  log "server_name nginx diperbarui ke: ${domain}"
}

domain_control_set_domain_now() {
  if [[ "${DOMAIN_CONTROL_LOCK_HELD:-0}" != "1" ]]; then
    domain_control_run_locked domain_control_set_domain_now "$@"
    return $?
  fi
  have_cmd curl || die "curl tidak ditemukan."
  have_cmd jq || die "jq tidak ditemukan."

  if domain_menu_v2; then
    :
  else
    local domain_input_rc=$?
    if (( domain_input_rc == 2 )); then
      warn "Set Domain dibatalkan. Kembali ke menu Domain Control."
      return 0
    fi
    return "${domain_input_rc}"
  fi
  local spin_log=""
  local spinner_warn_lines=""
  local pending_dns_incomplete="false"
  if ! ui_run_logged_command_with_spinner spin_log "Menerapkan domain & sertifikat" domain_control_set_domain_after_prompt; then
    warn "Set Domain gagal."
    hr
    tail -n 60 "${spin_log}" 2>/dev/null || true
    hr
    rm -f "${spin_log}" >/dev/null 2>&1 || true
    pause
    return 1
  fi
  spinner_warn_lines="$(grep '\[manage\]\[WARN\]' "${spin_log}" 2>/dev/null | tail -n 12 || true)"
  hr
  if [[ -n "${spinner_warn_lines}" ]]; then
    printf '%s\n' "${spinner_warn_lines}"
    hr
  fi
  rm -f "${spin_log}" >/dev/null 2>&1 || true
  log "Domain aktif sekarang: ${DOMAIN}"
  if domain_control_cf_sync_pending_exists "${DOMAIN}"; then
    warn "Target DNS Cloudflare untuk ${DOMAIN} masih pending repair."
    if confirm_yn_or_back "Coba sinkronkan target DNS Cloudflare sekarang juga?"; then
      if ! domain_control_sync_target_dns_now "${DOMAIN}"; then
        pending_dns_incomplete="true"
      fi
    else
      warn "Repair target DNS Cloudflare ditunda. Gunakan menu 'Repair Target DNS Record' bila ingin menyelesaikannya."
      pending_dns_incomplete="true"
    fi
    if [[ "${pending_dns_incomplete}" == "true" ]] && domain_control_cf_sync_pending_exists "${DOMAIN}"; then
      warn "Set Domain belum dianggap selesai penuh: target DNS Cloudflare untuk ${DOMAIN} masih pending repair."
      pause
      return 1
    fi
  fi
  local refresh_log="" refresh_warn_lines="" refresh_ip=""
  refresh_ip="$(normalize_ip_token "$(detect_public_ip_ipapi 2>/dev/null || detect_public_ip 2>/dev/null || true)")"
  if ! ui_run_logged_command_with_spinner refresh_log "Refresh ACCOUNT INFO ke domain baru" domain_control_refresh_account_info_batches_run "${DOMAIN}" "${refresh_ip}" "all" "10"; then
    warn "Refresh otomatis ACCOUNT INFO gagal pada percobaan pertama. Mencoba sekali lagi sebelum menandai sync pending..."
    hr
    tail -n 60 "${refresh_log}" 2>/dev/null || true
    hr
    rm -f "${refresh_log}" >/dev/null 2>&1 || true
    if ! ui_run_logged_command_with_spinner refresh_log "Retry refresh ACCOUNT INFO ke domain baru" domain_control_refresh_account_info_batches_run "${DOMAIN}" "${refresh_ip}" "all" "10"; then
      account_info_domain_sync_state_mark_pending >/dev/null 2>&1 || true
      warn "Set Domain sudah mengaktifkan runtime utama, tetapi refresh otomatis ACCOUNT INFO tetap gagal."
      warn "Status dikembalikan gagal agar sinkronisasi file akun tidak terlihat selesai penuh."
      warn "Domain aktif tetap: ${DOMAIN}. Jalankan 'Refresh Account Info' untuk menyelesaikan sinkronisasi file akun."
      hr
      tail -n 60 "${refresh_log}" 2>/dev/null || true
      hr
      rm -f "${refresh_log}" >/dev/null 2>&1 || true
      pause
      return 1
    fi
  fi
  refresh_warn_lines="$(grep '\[manage\]\[WARN\]' "${refresh_log}" 2>/dev/null | tail -n 12 || true)"
  if [[ -n "${refresh_warn_lines}" ]]; then
    hr
    printf '%s\n' "${refresh_warn_lines}"
  fi
  rm -f "${refresh_log}" >/dev/null 2>&1 || true
  if account_info_domain_sync_state_write "${DOMAIN}" >/dev/null 2>&1; then
    log "ACCOUNT INFO berhasil diselaraskan otomatis ke domain baru."
  else
    warn "ACCOUNT INFO berhasil direfresh ke domain baru, tetapi state sinkronisasi domain gagal disimpan."
  fi
  if domain_control_openvpn_sync_after_domain_change "${DOMAIN}"; then
    log "Profile OpenVPN berhasil diselaraskan ke domain baru."
  else
    warn "Sebagian profil OpenVPN gagal diselaraskan ke domain baru."
  fi
  pause
}

domain_control_openvpn_sync_after_domain_change() {
  local domain="${1:-}"
  [[ -n "${domain}" ]] || return 0
  if ! declare -F openvpn_runtime_available >/dev/null 2>&1; then
    return 0
  fi
  openvpn_runtime_available || return 0

  local env_file="${OPENVPN_CONFIG_ENV_FILE:-/etc/autoscript/openvpn/config.env}"
  python3 - <<'PY' "${env_file}" "${domain}" || return 1
from pathlib import Path
import sys
path = Path(sys.argv[1])
domain = sys.argv[2].strip()
lines = path.read_text(encoding="utf-8", errors="ignore").splitlines() if path.exists() else []
out = []
seen = False
for raw in lines:
    line = str(raw)
    stripped = line.strip()
    if not stripped or stripped.startswith("#") or "=" not in line:
        out.append(line)
        continue
    key, _ = line.split("=", 1)
    if key.strip() == "OPENVPN_PUBLIC_HOST":
        out.append(f"OPENVPN_PUBLIC_HOST={domain}")
        seen = True
    else:
        out.append(line)
if not seen:
    out.append(f"OPENVPN_PUBLIC_HOST={domain}")
path.parent.mkdir(parents=True, exist_ok=True)
tmp = path.with_name(f".{path.name}.tmp")
tmp.write_text("\n".join(out).rstrip("\n") + "\n", encoding="utf-8")
tmp.chmod(0o600)
tmp.replace(path)
PY

  local usernames=()
  local username
  while IFS= read -r username; do
    [[ -n "${username}" ]] || continue
    usernames+=("${username}")
  done < <(
    {
      find "${SSH_USERS_STATE_DIR}" -maxdepth 1 -type f -name '*.json' -printf '%f\n' 2>/dev/null \
        | sed -E 's/@ssh\.json$//' | sed -E 's/\.json$//'
      find "${SSH_ACCOUNT_DIR}" -maxdepth 1 -type f -name '*.txt' -printf '%f\n' 2>/dev/null \
        | sed -E 's/@ssh\.txt$//' | sed -E 's/\.txt$//'
    } | sort -u
  )

  local updated=0 failed=0
  for username in "${usernames[@]}"; do
    id "${username}" >/dev/null 2>&1 || continue
    if openvpn_manage_json ensure-user --username "${username}" >/dev/null 2>&1; then
      updated=$((updated + 1))
    else
      failed=$((failed + 1))
    fi
  done

  log "OpenVPN sync domain=${domain}: updated=${updated}, failed=${failed}"
  (( failed == 0 ))
}

domain_control_set_domain_after_prompt() {
  local cert_backup_dir
  local nginx_conf_backup
  local compat_snapshot_dir=""
  local rollback_notes=()
  local cf_dns_snapshot=""
  local cert_stage_dir="" staged_fullchain="" staged_privkey=""
  cert_backup_dir="${WORK_DIR}/cert-snapshot.$(date +%s).$$"
  nginx_conf_backup="${WORK_DIR}/xray.conf.pre-domain-change.$(date +%s).$$"
  compat_snapshot_dir="${WORK_DIR}/compat-domain-snapshot.$(date +%s).$$"
  cert_stage_dir="$(mktemp -d "${WORK_DIR}/cert-stage.$(date +%s).XXXXXX" 2>/dev/null || true)"
  [[ -n "${cert_stage_dir}" ]] || cert_stage_dir="${WORK_DIR}/cert-stage.$(date +%s).$$"
  mkdir -p "${cert_stage_dir}" >/dev/null 2>&1 || die "Gagal menyiapkan staging sertifikat sebelum set domain."
  staged_fullchain="${cert_stage_dir}/fullchain.pem"
  staged_privkey="${cert_stage_dir}/privkey.pem"
  domain_control_capture_runtime_snapshot
  if ! cert_snapshot_create "${cert_backup_dir}"; then
    die "Gagal membuat snapshot sertifikat sebelum set domain."
  fi
  cp -a "${NGINX_CONF}" "${nginx_conf_backup}" || die "Gagal membuat backup nginx sebelum set domain."
  if ! domain_control_optional_file_snapshot_create "${XRAY_DOMAIN_FILE}" "${compat_snapshot_dir}" compat_domain; then
    rm -rf "${compat_snapshot_dir}" >/dev/null 2>&1 || true
    die "Gagal membuat snapshot compat domain sebelum set domain."
  fi
  domain_control_txn_begin "${cert_backup_dir}" "${nginx_conf_backup}" "${compat_snapshot_dir}" "${DOMAIN}"

  if ! install_acme_and_issue_cert "${staged_fullchain}" "${staged_privkey}"; then
    warn "Issue/install sertifikat gagal. Mengembalikan snapshot transaksi domain..."
    domain_control_txn_restore rollback_notes || true
    if (( ${#rollback_notes[@]} > 0 )); then
      die "Set domain dibatalkan karena issue/install sertifikat gagal; rollback juga bermasalah: $(IFS=' | '; echo "${rollback_notes[*]}")."
    fi
    die "Set domain dibatalkan karena issue/install sertifikat gagal; sertifikat sebelumnya berhasil dipulihkan."
  fi

  if ! ( domain_control_apply_nginx_domain "${DOMAIN}" ); then
    warn "Apply domain ke nginx gagal. Mengembalikan snapshot transaksi domain..."
    domain_control_txn_restore rollback_notes || true
    if (( ${#rollback_notes[@]} > 0 )); then
      die "Set domain dibatalkan karena update nginx gagal; rollback juga bermasalah: $(IFS=' | '; echo "${rollback_notes[*]}")."
    fi
    die "Set domain dibatalkan karena update nginx gagal; snapshot transaksi berhasil dipulihkan."
  fi

  if ! domain_control_activate_cert_runtime_after_install "${staged_fullchain}" "${staged_privkey}"; then
    warn "Aktivasi runtime cert/domain gagal. Mengembalikan snapshot transaksi domain..."
    domain_control_txn_restore rollback_notes || true
    if (( ${#rollback_notes[@]} > 0 )); then
      die "Set domain dibatalkan karena aktivasi runtime cert/domain gagal; rollback juga bermasalah: $(IFS=' | '; echo "${rollback_notes[*]}")."
    fi
    die "Set domain dibatalkan karena aktivasi runtime cert/domain gagal; snapshot transaksi berhasil dipulihkan."
  fi

  if [[ "${ACME_CERT_MODE:-standalone}" == "dns_cf_wildcard" ]]; then
    [[ -n "${CF_ZONE_ID:-}" ]] || die "CF_ZONE_ID kosong untuk flow wildcard dns_cf."
    [[ -n "${VPS_IPV4:-}" ]] || VPS_IPV4="$(get_public_ipv4)"
    cf_dns_snapshot="$(mktemp "${WORK_DIR}/cf-domain-snapshot.XXXXXX" 2>/dev/null || true)"
    [[ -n "${cf_dns_snapshot}" ]] || die "Gagal menyiapkan snapshot DNS Cloudflare sebelum apply domain."
    if ! cf_snapshot_relevant_a_records "${CF_ZONE_ID}" "${DOMAIN}" "${VPS_IPV4}" "${cf_dns_snapshot}"; then
      rm -f "${cf_dns_snapshot}" >/dev/null 2>&1 || true
      warn "Snapshot DNS Cloudflare sebelum aktivasi target gagal dibuat. Mengembalikan snapshot transaksi domain..."
      domain_control_txn_restore rollback_notes || true
      if (( ${#rollback_notes[@]} > 0 )); then
        die "Set domain dibatalkan karena snapshot DNS Cloudflare gagal dibuat; rollback juga bermasalah: $(IFS=' | '; echo "${rollback_notes[*]}")."
      fi
      die "Set domain dibatalkan karena snapshot DNS Cloudflare gagal dibuat; snapshot transaksi berhasil dipulihkan."
    fi
    domain_control_txn_register_cf_snapshot "${CF_ZONE_ID}" "${DOMAIN}" "${VPS_IPV4}" "${cf_dns_snapshot}"
    domain_control_txn_mark_cf_prepared

    local cf_sync_ok="false" cf_sync_try=0
    for cf_sync_try in 1 2 3; do
      if cf_prepare_subdomain_a_record "${CF_ZONE_ID}" "${DOMAIN}" "${VPS_IPV4}" "${CF_PROXIED:-false}"; then
        cf_sync_ok="true"
        break
      fi
      sleep 2
    done
    if [[ "${cf_sync_ok}" != "true" ]]; then
      warn "Sinkronisasi target DNS Cloudflare gagal. Mengembalikan snapshot transaksi domain..."
      domain_control_txn_restore rollback_notes || true
      if (( ${#rollback_notes[@]} > 0 )); then
        die "Set domain dibatalkan karena sinkronisasi target DNS Cloudflare gagal; rollback juga bermasalah: $(IFS=' | '; echo "${rollback_notes[*]}")."
      fi
      die "Set domain dibatalkan karena sinkronisasi target DNS Cloudflare gagal; snapshot transaksi berhasil dipulihkan."
    fi
    domain_control_cf_sync_pending_clear_if_domain_matches "${DOMAIN}"
  fi

  main_info_cache_invalidate
  domain_control_txn_clear
  rm -f "${nginx_conf_backup}" >/dev/null 2>&1 || true
  rm -rf "${compat_snapshot_dir}" >/dev/null 2>&1 || true
  rm -rf "${cert_backup_dir}" >/dev/null 2>&1 || true
  rm -rf "${cert_stage_dir}" >/dev/null 2>&1 || true
  rm -f "${cf_dns_snapshot}" >/dev/null 2>&1 || true
  domain_control_clear_runtime_snapshot
}

domain_control_refresh_account_info_now() {
  local domain ip summary xray_count ssh_count total_count xray_preview ssh_preview preview_report="" dry_run_report=""
  local geo="" geo_ip="" target_isp="-" target_country="-"
  local scope_choice="" scope="all" scope_label="Semua (Xray + SSH)"
  local spin_log=""
  local ask_rc=0
  local max_targets_per_run="10"
  local run_all_batches="false"

  title
  echo "8) Domain Control > Refresh Account Info"
  hr

  domain="$(normalize_domain_token "$(detect_domain)")"
  if [[ -z "${domain}" ]]; then
    warn "Domain aktif tidak terdeteksi."
    pause
    return 1
  fi
  ip="$(normalize_ip_token "$(detect_public_ip_ipapi 2>/dev/null || detect_public_ip 2>/dev/null || true)")"
  if [[ -n "${ip}" ]]; then
    geo="$(main_info_geo_lookup "${ip}" 2>/dev/null || true)"
    IFS='|' read -r geo_ip target_isp target_country <<<"${geo}"
    [[ -n "${geo_ip}" && "${geo_ip}" != "-" ]] && ip="${geo_ip}"
    [[ -n "${target_isp}" ]] || target_isp="-"
    [[ -n "${target_country}" ]] || target_country="-"
  fi
  echo "Pilih scope refresh:"
  echo "  1) Semua (Xray + SSH)"
  echo "  2) Xray only"
  echo "  3) SSH only"
  echo "  0) Back"
  hr
  while true; do
    if ! read -r -p "Pilih scope (1-3/0): " scope_choice; then
      echo
      return 0
    fi
    case "${scope_choice}" in
      1) scope="all" ; scope_label="Semua (Xray + SSH)" ; break ;;
      2) scope="xray" ; scope_label="Xray only" ; break ;;
      3) scope="ssh" ; scope_label="SSH only" ; break ;;
      0|kembali|k|back|b) return 0 ;;
      *) echo "Pilihan tidak valid." ;;
    esac
  done

  summary="$(account_info_refresh_targets_summary "${scope}" 5)"
  IFS='|' read -r xray_count ssh_count total_count xray_preview ssh_preview <<<"${summary}"

  echo "Domain aktif : ${domain}"
  echo "IP aktif     : ${ip:-tidak terdeteksi}"
  echo "ISP target   : ${target_isp:-"-"}"
  echo "Country tgt  : ${target_country:-"-"}"
  echo "Scope        : ${scope_label}"
  echo "Mode apply   : chunked (maks 10 target per batch atomic, maks 10 target per eksekusi)"
  if [[ "${scope}" == "all" || "${scope}" == "xray" ]]; then
    echo "Target Xray  : ${xray_count:-0}"
    echo "Preview Xray : ${xray_preview:--}"
  fi
  if [[ "${scope}" == "all" || "${scope}" == "ssh" ]]; then
    echo "Target SSH   : ${ssh_count:-0}"
    echo "Preview SSH  : ${ssh_preview:--}"
  fi
  echo "Total target : ${total_count:-0}"
  echo "Default run  : 10 target pertama per eksekusi."
  preview_report="$(preview_report_path_prepare "account-info-refresh-targets" 2>/dev/null || true)"
  if [[ -n "${preview_report}" ]] && account_info_refresh_targets_report_write "${scope}" "${preview_report}"; then
    echo "Daftar target lengkap:"
    echo "  ${preview_report}"
  else
    rm -f "${preview_report}" >/dev/null 2>&1 || true
    preview_report=""
  fi
  dry_run_report="$(preview_report_path_prepare "account-info-refresh-dryrun" 2>/dev/null || true)"
  if [[ -n "${dry_run_report}" ]] && account_info_refresh_dry_run_report_write "${scope}" "${dry_run_report}" "${domain}" "${ip}" "${target_isp}" "${target_country}"; then
    echo "Dry-run report : ${dry_run_report}"
  else
    rm -f "${dry_run_report}" >/dev/null 2>&1 || true
    dry_run_report=""
  fi
  hr

  if [[ -z "${total_count}" || "${total_count}" == "0" ]]; then
    warn "Tidak ada ACCOUNT INFO yang perlu direfresh."
    pause
    return 0
  fi

  echo "Aksi:"
  echo "  1) Preview only"
  echo "  2) Dry-run rendered diff"
  echo "  3) Refresh sekarang"
  echo "  0) Back"
  hr
  local refresh_action=""
  while true; do
    if ! read -r -p "Pilih aksi (1-3/0): " refresh_action; then
      echo
      return 0
    fi
    case "${refresh_action}" in
      1)
        if [[ -n "${preview_report}" && -f "${preview_report}" ]]; then
          preview_report_show_file "${preview_report}" || warn "Gagal membuka preview target refresh."
        else
          warn "Preview target tidak tersedia."
        fi
        hr
        pause
        return 0
        ;;
      2)
        if [[ -n "${dry_run_report}" && -f "${dry_run_report}" ]]; then
          preview_report_show_file "${dry_run_report}" || warn "Gagal membuka dry-run refresh."
        else
          warn "Dry-run refresh tidak tersedia."
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

  confirm_yn_or_back "Refresh ACCOUNT INFO untuk scope ${scope_label} ini sekarang?"
  ask_rc=$?
  if (( ask_rc != 0 )); then
    if (( ask_rc == 2 )); then
      warn "Refresh ACCOUNT INFO dibatalkan (kembali)."
    else
      warn "Refresh ACCOUNT INFO dibatalkan."
    fi
    pause
    return 0
  fi
  if ! confirm_menu_apply_now "Konfirmasi final: jalankan bulk rewrite ACCOUNT INFO untuk scope ${scope_label}?"; then
    warn "Refresh ACCOUNT INFO dibatalkan pada checkpoint final."
    pause
    return 0
  fi
  read -r -p "Batas target per run (Enter=10, 1-10, atau kembali): " max_targets_per_run
  if is_back_choice "${max_targets_per_run}"; then
    warn "Refresh ACCOUNT INFO dibatalkan pada pemilihan limit target."
    pause
    return 0
  fi
  [[ -n "${max_targets_per_run}" ]] || max_targets_per_run="10"
  if [[ ! "${max_targets_per_run}" =~ ^[0-9]+$ ]]; then
    warn "Limit target per run tidak valid. Dibatalkan."
    pause
    return 0
  fi
  if (( max_targets_per_run < 1 || max_targets_per_run > 10 )); then
    warn "Limit target per run harus berada di rentang 1-10."
    pause
    return 0
  fi
  local bulk_ack=""
  read -r -p "Ketik persis 'REFRESH ${scope}' untuk lanjut bulk rewrite ACCOUNT INFO (atau kembali): " bulk_ack
  if is_back_choice "${bulk_ack}"; then
    warn "Refresh ACCOUNT INFO dibatalkan pada checkpoint bulk-write."
    pause
    return 0
  fi
  if [[ "${bulk_ack}" != "REFRESH ${scope}" ]]; then
    warn "Konfirmasi bulk rewrite ACCOUNT INFO tidak cocok. Dibatalkan."
    pause
    return 0
  fi
  if [[ "${total_count:-0}" =~ ^[0-9]+$ ]] && (( total_count > max_targets_per_run )); then
    if confirm_menu_apply_now "Target melebihi satu batch. Jalankan seluruh batch refresh ACCOUNT INFO sekarang sampai selesai?"; then
      run_all_batches="true"
    fi
  fi
  if [[ "${total_count:-0}" =~ ^[0-9]+$ ]] && (( total_count >= 20 )); then
    if ! confirm_menu_apply_now "Target refresh mencapai ${total_count} file/account info. Tetap lanjut bulk rewrite sekarang?"; then
      warn "Refresh ACCOUNT INFO dibatalkan pada checkpoint bulk-write."
      pause
      return 0
    fi
  fi

  if [[ "${run_all_batches}" == "true" ]]; then
    if ui_run_logged_command_with_spinner spin_log "Refresh ACCOUNT INFO (${scope_label}, semua batch)" domain_control_refresh_account_info_batches_run "${domain}" "${ip}" "${scope}" "${max_targets_per_run}"; then
      if account_info_domain_sync_state_write "${domain}"; then
        log "ACCOUNT INFO berhasil disinkronkan untuk seluruh batch."
      else
        warn "ACCOUNT INFO berhasil direfresh untuk seluruh batch, tetapi state sinkronisasi domain gagal disimpan."
      fi
      rm -f "${spin_log}" >/dev/null 2>&1 || true
      pause
      return 0
    fi
  elif ui_run_logged_command_with_spinner spin_log "Refresh ACCOUNT INFO (${scope_label})" account_refresh_all_info_files "${domain}" "${ip}" "${scope}" "${max_targets_per_run}"; then
    if [[ "${total_count:-0}" =~ ^[0-9]+$ ]] && (( total_count > max_targets_per_run )); then
      log "Batch ACCOUNT INFO berhasil diproses."
      warn "State sinkronisasi domain belum diupdate karena target masih tersisa di batch berikutnya."
    else
      if account_info_domain_sync_state_write "${domain}"; then
        log "ACCOUNT INFO berhasil disinkronkan."
      else
        warn "ACCOUNT INFO berhasil disinkronkan, tetapi state sinkronisasi domain gagal disimpan."
      fi
    fi
    if [[ "${total_count:-0}" =~ ^[0-9]+$ ]] && (( total_count > max_targets_per_run )); then
      account_info_domain_sync_state_mark_pending >/dev/null 2>&1 || true
      warn "Eksekusi ini hanya memproses ${max_targets_per_run} target pertama. Jalankan ulang menu ini untuk batch berikutnya."
    fi
    rm -f "${spin_log}" >/dev/null 2>&1 || true
    pause
    return 0
  fi

  account_info_domain_sync_state_mark_pending >/dev/null 2>&1 || true
  warn "Refresh ACCOUNT INFO gagal."
  warn "Batch yang sudah berhasil sebelum titik gagal dipertahankan. State sinkronisasi domain ditandai pending sampai refresh selesai penuh."
  hr
  tail -n 60 "${spin_log}" 2>/dev/null || true
  hr
  rm -f "${spin_log}" >/dev/null 2>&1 || true
  rm -f "${preview_report}" "${dry_run_report}" >/dev/null 2>&1 || true
  pause
  return 1
}

domain_control_sync_compat_domain_now() {
  local domain ask_rc=0 current_compat=""
  local snapshot_dir="" preview_report="" nginx_domain="" sync_state_domain=""
  if [[ "${DOMAIN_CONTROL_LOCK_HELD:-0}" != "1" ]]; then
    domain_control_run_locked domain_control_sync_compat_domain_now "$@"
    return $?
  fi

  title
  echo "8) Domain Control > Repair Compat Domain Drift (Repair-Only)"
  hr

  domain="$(normalize_domain_token "$(detect_domain)")"
  if [[ -z "${domain}" ]]; then
    warn "Domain aktif tidak terdeteksi."
    pause
    return 1
  fi

  echo "Domain aktif    : ${domain}"
  echo "Compat file     : ${XRAY_DOMAIN_FILE}"
  current_compat="$(head -n1 "${XRAY_DOMAIN_FILE}" 2>/dev/null | tr -d '\r' | awk '{print $1}' | tr -d ';' || true)"
  nginx_domain="$(grep -E '^[[:space:]]*server_name[[:space:]]+' "${NGINX_CONF}" 2>/dev/null | head -n1 | sed -E 's/^[[:space:]]*server_name[[:space:]]+//; s/;.*$//' | awk '{print $1}' | tr -d ';' || true)"
  echo "Compat saat ini : ${current_compat:-"(kosong)"}"
  echo "Nginx server_name : ${nginx_domain:-"(tidak terdeteksi)"}"
  echo "Catatan         : ini adalah repair artefak kompatibilitas ke domain aktif, bukan set domain baru."
  sync_state_domain="$(normalize_domain_token "$(account_info_domain_sync_state_read)")"
  echo "Sync state dom : ${sync_state_domain:-"(tidak tercatat)"}"
  preview_report="$(preview_report_path_prepare "compat-domain-sync" 2>/dev/null || true)"
  if [[ -n "${preview_report}" ]]; then
    {
      printf 'Current compat : %s\n' "${current_compat:-"(kosong)"}"
      printf 'Target domain  : %s\n' "${domain}"
      printf '\n'
      printf -- '--- current\n'
      printf -- '+++ target\n'
      printf -- '@@ compat-domain @@\n'
      printf -- '-%s\n' "${current_compat:-"(kosong)"}"
      printf -- '+%s\n' "${domain}"
    } > "${preview_report}" 2>/dev/null || true
    [[ -f "${preview_report}" ]] && echo "Preview repair : ${preview_report}"
  fi
  hr

  if [[ -n "${current_compat}" && "${current_compat}" == "${domain}" ]]; then
    log "Compat domain file sudah sinkron dengan domain aktif."
    pause
    return 0
  fi
  if [[ -n "${sync_state_domain}" && "${sync_state_domain}" != "-" && "${sync_state_domain}" != "${domain}" ]]; then
    warn "Repair compat domain dibatalkan: state sinkronisasi domain terakhir (${sync_state_domain}) tidak cocok dengan domain aktif (${domain})."
    warn "Selesaikan refresh batch domain saat ini atau jalankan set domain/guard renew hingga state benar-benar final."
    pause
    return 1
  fi
  if domain_control_cf_sync_pending_exists; then
    warn "Repair compat domain dibatalkan: masih ada pending repair target DNS Cloudflare."
    warn "Selesaikan 'Repair Target DNS Record' dulu agar compat repair tetap mengikuti runtime utama yang benar-benar final."
    pause
    return 1
  fi
  if [[ -n "${nginx_domain}" && "${nginx_domain}" != "${domain}" ]]; then
    warn "Repair compat domain dibatalkan: domain aktif (${domain}) tidak cocok dengan server_name nginx (${nginx_domain})."
    warn "Gunakan Set Domain agar compat repair tetap terikat ke runtime utama."
    pause
    return 1
  fi
  if [[ ! -s "${CERT_FULLCHAIN}" || ! -s "${CERT_PRIVKEY}" ]]; then
    warn "Repair compat domain dibatalkan: file cert live belum siap."
    pause
    return 1
  fi
  if declare -F cert_runtime_hostname_tls_handshake_check >/dev/null 2>&1; then
    if ! cert_runtime_hostname_tls_handshake_check "${domain}" >/dev/null 2>&1; then
      warn "Repair compat domain dibatalkan: probe TLS hostname untuk domain aktif belum sehat."
      warn "Gunakan Set Domain atau perbaiki runtime TLS dulu sebelum mensinkronkan compat domain."
      pause
      return 1
    fi
  fi

  confirm_yn_or_back "Sinkronkan compat domain file ke domain aktif sekarang?"
  ask_rc=$?
  if (( ask_rc != 0 )); then
    if (( ask_rc == 2 )); then
      warn "Sinkronisasi compat domain dibatalkan (kembali)."
    else
      warn "Sinkronisasi compat domain dibatalkan."
    fi
    pause
    return 0
  fi
  if ! confirm_menu_apply_now "Konfirmasi final: repair compat domain file ke domain aktif ${domain}?"; then
    warn "Sinkronisasi compat domain dibatalkan pada checkpoint final."
    pause
    return 0
  fi
  local compat_ack=""
  read -r -p "Ketik persis 'SYNC COMPAT ${domain}' untuk lanjut repair compat domain (atau kembali): " compat_ack
  if is_back_choice "${compat_ack}"; then
    warn "Sinkronisasi compat domain dibatalkan pada checkpoint final."
    pause
    return 0
  fi
  if [[ "${compat_ack}" != "SYNC COMPAT ${domain}" ]]; then
    warn "Konfirmasi repair compat domain tidak cocok. Dibatalkan."
    pause
    return 0
  fi

  snapshot_dir="$(mktemp -d "${WORK_DIR}/.compat-domain-sync.XXXXXX" 2>/dev/null || true)"
  if [[ -n "${snapshot_dir}" ]]; then
    domain_control_optional_file_snapshot_create "${XRAY_DOMAIN_FILE}" "${snapshot_dir}" compat_domain >/dev/null 2>&1 || true
  fi

  if sync_xray_domain_file "${domain}"; then
    log "Compat domain file berhasil disinkronkan ke ${domain}."
    [[ -n "${snapshot_dir}" ]] && rm -rf "${snapshot_dir}" >/dev/null 2>&1 || true
    pause
    return 0
  fi

  if [[ -n "${snapshot_dir}" && -d "${snapshot_dir}" ]]; then
    domain_control_optional_file_snapshot_restore "${XRAY_DOMAIN_FILE}" "${snapshot_dir}" compat_domain >/dev/null 2>&1 || true
    rm -rf "${snapshot_dir}" >/dev/null 2>&1 || true
  fi
  warn "Sinkronisasi compat domain file gagal."
  pause
  return 1
}

domain_control_sync_target_dns_now() {
  local pending_domain_hint="${1:-}"
  local pending_file=""
  local -a pending_files=()
  local pending_choice="" i=0
  local domain="" zone_id="" ipv4="" proxied="false" created_at=""
  local pending_runtime_domain="" pending_nginx_domain=""
  local active_domain="" active_nginx_domain=""
  local cf_dns_snapshot="" ask_rc=0
  if [[ "${DOMAIN_CONTROL_LOCK_HELD:-0}" != "1" ]]; then
    domain_control_run_locked domain_control_sync_target_dns_now "$@"
    return $?
  fi

  title
  echo "8) Domain Control > Repair Target DNS Record (Manual Repair)"
  hr

  while IFS= read -r pending_file; do
    [[ -n "${pending_file}" ]] || continue
    pending_files+=("${pending_file}")
  done < <(domain_control_cf_sync_pending_list_files)

  if (( ${#pending_files[@]} == 0 )); then
    log "Tidak ada pending repair target DNS Cloudflare."
    pause
    return 0
  fi

  if [[ -n "${pending_domain_hint}" ]]; then
    pending_file="$(domain_control_cf_sync_pending_find_file "${pending_domain_hint}" 2>/dev/null || true)"
    if [[ -z "${pending_file}" ]]; then
      warn "Pending repair target DNS untuk ${pending_domain_hint} tidak ditemukan lagi."
      pause
      return 0
    fi
  elif (( ${#pending_files[@]} > 1 )); then
    echo "Pending repair DNS tersedia:"
    for i in "${!pending_files[@]}"; do
      domain="$(domain_control_cf_sync_pending_field_get_from_file "${pending_files[$i]}" domain 2>/dev/null || true)"
      created_at="$(domain_control_cf_sync_pending_field_get_from_file "${pending_files[$i]}" created_at 2>/dev/null || true)"
      printf "  %d) %s (%s)\n" "$((i + 1))" "${domain:-unknown}" "${created_at:-waktu tidak diketahui}"
    done
    hr
    while true; do
      if ! read -r -p "Repair pending domain nomor berapa (atau kembali): " pending_choice; then
        echo
        return 0
      fi
      if is_back_choice "${pending_choice}"; then
        return 0
      fi
      [[ "${pending_choice}" =~ ^[0-9]+$ ]] || { warn "Pilihan tidak valid."; continue; }
      if (( pending_choice < 1 || pending_choice > ${#pending_files[@]} )); then
        warn "Nomor di luar range."
        continue
      fi
      pending_file="${pending_files[$((pending_choice - 1))]}"
      break
    done
  else
    pending_file="${pending_files[0]}"
  fi

  domain="$(domain_control_cf_sync_pending_field_get_from_file "${pending_file}" domain 2>/dev/null || true)"
  zone_id="$(domain_control_cf_sync_pending_field_get_from_file "${pending_file}" zone_id 2>/dev/null || true)"
  ipv4="$(domain_control_cf_sync_pending_field_get_from_file "${pending_file}" ipv4 2>/dev/null || true)"
  proxied="$(domain_control_cf_sync_pending_field_get_from_file "${pending_file}" proxied 2>/dev/null || true)"
  pending_runtime_domain="$(domain_control_cf_sync_pending_field_get_from_file "${pending_file}" runtime_domain 2>/dev/null || true)"
  pending_nginx_domain="$(domain_control_cf_sync_pending_field_get_from_file "${pending_file}" nginx_domain 2>/dev/null || true)"
  created_at="$(domain_control_cf_sync_pending_field_get_from_file "${pending_file}" created_at 2>/dev/null || true)"
  [[ -n "${proxied}" ]] || proxied="false"

  if [[ -z "${domain}" || -z "${zone_id}" || -z "${ipv4}" ]]; then
    warn "State pending repair target DNS Cloudflare tidak lengkap."
    warn "File pending : ${pending_file}"
    warn "File pending dipertahankan agar operator masih bisa meninjau atau membersihkannya secara sadar."
    pause
    return 1
  fi

  active_domain="$(normalize_domain_token "$(detect_domain)")"
  active_nginx_domain="$(normalize_domain_token "$(domain_control_current_nginx_domain_get)")"
  echo "Pending sejak : ${created_at:-tidak diketahui}"
  echo "Target domain : ${domain}"
  echo "Runtime saat dibuat : ${pending_runtime_domain:-"(tidak terekam)"}"
  echo "Nginx saat dibuat   : ${pending_nginx_domain:-"(tidak terekam)"}"
  echo "Runtime aktif kini  : ${active_domain:-"(tidak terdeteksi)"}"
  echo "Nginx aktif kini    : ${active_nginx_domain:-"(tidak terdeteksi)"}"
  echo "Zone ID       : ${zone_id}"
  echo "Target IPv4   : ${ipv4}"
  echo "Cloudflare proxy : ${proxied}"
  echo "Catatan       : aksi ini hanya memperbaiki A record target Cloudflare pasca-commit runtime domain."
  hr
  if [[ -n "${active_domain}" && "${active_domain}" != "${domain}" ]]; then
    warn "Repair target DNS dibatalkan: pending domain (${domain}) tidak cocok dengan domain aktif saat ini (${active_domain})."
    warn "Gunakan menu ini hanya setelah memastikan pending task memang masih relevan."
    pause
    return 1
  fi
  if [[ -n "${active_nginx_domain}" && "${active_nginx_domain}" != "${domain}" ]]; then
    warn "Repair target DNS dibatalkan: server_name nginx aktif (${active_nginx_domain}) tidak cocok dengan pending domain (${domain})."
    pause
    return 1
  fi
  confirm_yn_or_back "Lanjutkan repair target DNS Cloudflare sekarang?"
  ask_rc=$?
  if (( ask_rc != 0 )); then
    if (( ask_rc == 2 )); then
      warn "Repair target DNS dibatalkan (kembali)."
    else
      warn "Repair target DNS dibatalkan."
    fi
    pause
    return 0
  fi
  if ! confirm_menu_apply_now "Konfirmasi final: sync target DNS Cloudflare untuk ${domain} sekarang?"; then
    warn "Repair target DNS dibatalkan pada checkpoint final."
    pause
    return 0
  fi
  local dns_ack=""
  read -r -p "Ketik persis 'SYNC DNS ${domain}' untuk lanjut repair target DNS (atau kembali): " dns_ack
  if is_back_choice "${dns_ack}"; then
    warn "Repair target DNS dibatalkan pada checkpoint final."
    pause
    return 0
  fi
  if [[ "${dns_ack}" != "SYNC DNS ${domain}" ]]; then
    warn "Konfirmasi repair target DNS tidak cocok. Dibatalkan."
    pause
    return 0
  fi

  cf_dns_snapshot="$(mktemp "${WORK_DIR}/cf-domain-repair.XXXXXX" 2>/dev/null || true)"
  if [[ -z "${cf_dns_snapshot}" ]]; then
    warn "Gagal menyiapkan snapshot DNS Cloudflare untuk repair."
    pause
    return 1
  fi
  if ! cf_snapshot_relevant_a_records "${zone_id}" "${domain}" "${ipv4}" "${cf_dns_snapshot}"; then
    rm -f "${cf_dns_snapshot}" >/dev/null 2>&1 || true
    warn "Gagal membuat snapshot DNS Cloudflare sebelum repair target."
    pause
    return 1
  fi
  if ! cf_prepare_subdomain_a_record "${zone_id}" "${domain}" "${ipv4}" "${proxied}"; then
    warn "Repair target DNS Cloudflare gagal. Mencoba restore snapshot DNS sebelumnya..."
    if ! cf_restore_relevant_a_records_snapshot "${zone_id}" "${domain}" "${ipv4}" "${cf_dns_snapshot}"; then
      warn "Restore snapshot DNS Cloudflare juga gagal. Pending repair dipertahankan."
    else
      warn "Snapshot DNS Cloudflare berhasil dipulihkan. Pending repair dipertahankan."
    fi
    rm -f "${cf_dns_snapshot}" >/dev/null 2>&1 || true
    pause
    return 1
  fi
  rm -f "${cf_dns_snapshot}" >/dev/null 2>&1 || true
  rm -f "${pending_file}" >/dev/null 2>&1 || true
  log "Target DNS Cloudflare berhasil disinkronkan ke ${domain}."
  local remaining_pending=0
  remaining_pending="$(domain_control_cf_sync_pending_list_files | wc -l | tr -d '[:space:]' || true)"
  [[ "${remaining_pending}" =~ ^[0-9]+$ ]] || remaining_pending=0
  if (( remaining_pending > 0 )); then
    warn "Masih ada ${remaining_pending} pending repair DNS lain yang belum dibereskan."
    if confirm_yn_or_back "Lanjutkan repair pending DNS berikutnya sekarang juga?"; then
      if ! domain_control_sync_target_dns_now; then
        return 1
      fi
      return 0
    fi
  fi
  pause
  return 0
}

domain_control_show_info() {
  title
  echo "8) Domain Control > Current Domain"
  hr
  echo "Domain aktif : $(detect_domain)"
  echo "Cert file    : ${CERT_FULLCHAIN}"
  echo "Key file     : ${CERT_PRIVKEY}"
  if [[ -s "${CERT_FULLCHAIN}" && -s "${CERT_PRIVKEY}" ]]; then
    echo "Status cert  : tersedia"
  else
    echo "Status cert  : belum tersedia / kosong"
  fi
  hr
  pause
}

domain_control_guard_check() {
  title
  echo "8) Domain Control > Guard Check"
  hr

  if [[ ! -x "${XRAY_DOMAIN_GUARD_BIN}" ]]; then
    warn "xray-domain-guard belum terpasang."
    warn "Jalankan setup.sh terbaru untuk mengaktifkan Domain & Cert Guard."
    hr
    pause
    return 0
  fi

  local rc=0 spin_log=""
  if ui_run_logged_command_with_spinner spin_log "Menjalankan guard check" "${XRAY_DOMAIN_GUARD_BIN}" check; then
    rc=0
  else
    rc=$?
  fi

  hr
  if [[ -n "${spin_log}" && -s "${spin_log}" ]]; then
    cat "${spin_log}" 2>/dev/null || true
    hr
  fi
  case "${rc}" in
    0) log "Domain & Cert Guard: sehat." ;;
    1) warn "Domain & Cert Guard: warning terdeteksi." ;;
    2) warn "Domain & Cert Guard: masalah critical terdeteksi." ;;
    *) warn "Domain & Cert Guard selesai dengan status ${rc}." ;;
  esac
  echo "Config path: ${XRAY_DOMAIN_GUARD_CONFIG_FILE}"
  if [[ -f "${XRAY_DOMAIN_GUARD_LOG_FILE}" ]]; then
    echo "Log path   : ${XRAY_DOMAIN_GUARD_LOG_FILE}"
  fi
  rm -f "${spin_log}" >/dev/null 2>&1 || true
  pause
  return "${rc}"
}

domain_control_guard_renew_if_needed() {
  if [[ "${DOMAIN_CONTROL_LOCK_HELD:-0}" != "1" ]]; then
    domain_control_run_locked domain_control_guard_renew_if_needed "$@"
    return $?
  fi
  title
  echo "8) Domain Control > Guard Renew (External Binary)"
  hr

  if [[ ! -x "${XRAY_DOMAIN_GUARD_BIN}" ]]; then
    warn "xray-domain-guard belum terpasang."
    hr
    pause
    return 0
  fi

  local ask_rc=0 rc=0 spin_log="" check_rc=0 check_log="" status_log="" post_check_log="" post_check_rc=0
  local domain="" nginx_domain="" compat_domain=""
  local -a post_notes=()
  local compat_prompt_rc=0
  local dns_prompt_rc=0
  if ui_run_logged_command_with_spinner check_log "Menjalankan guard preflight" "${XRAY_DOMAIN_GUARD_BIN}" check; then
    check_rc=0
  else
    check_rc=$?
  fi
  ui_run_logged_command_with_spinner status_log "Mengambil status guard terakhir" "${XRAY_DOMAIN_GUARD_BIN}" status >/dev/null 2>&1 || true

  hr
  if [[ -n "${check_log}" && -s "${check_log}" ]]; then
    cat "${check_log}" 2>/dev/null || true
    hr
  fi
  case "${check_rc}" in
    0) log "Preflight guard: sehat." ;;
    1) warn "Preflight guard: warning terdeteksi." ;;
    2) warn "Preflight guard: masalah critical terdeteksi." ;;
    *) warn "Preflight guard selesai dengan status ${check_rc}." ;;
  esac
  echo "Config path: ${XRAY_DOMAIN_GUARD_CONFIG_FILE}"
  if [[ -f "${XRAY_DOMAIN_GUARD_LOG_FILE}" ]]; then
    echo "Log path   : ${XRAY_DOMAIN_GUARD_LOG_FILE}"
  fi
  if [[ -n "${status_log}" && -s "${status_log}" ]]; then
    echo "Status/log terakhir:"
    cat "${status_log}" 2>/dev/null || true
    hr
  fi
  echo "Perkiraan artefak/runtime yang bisa disentuh:"
  echo "  - Cert files : ${CERT_FULLCHAIN}, ${CERT_PRIVKEY}"
  echo "  - Nginx conf : ${NGINX_CONF}"
  echo "  - Compat file: ${XRAY_DOMAIN_FILE}"
  echo "  - Service    : nginx, xray, sshws-stunnel, edge runtime (jika aktif)"
  echo "Command    : ${XRAY_DOMAIN_GUARD_BIN} renew-if-needed"
  echo "Catatan    : renew-if-needed dijalankan oleh binary eksternal dan dapat memperbarui cert/domain artefak terkait."
  hr
  rm -f "${check_log}" >/dev/null 2>&1 || true
  rm -f "${status_log}" >/dev/null 2>&1 || true

  if (( check_rc >= 1 )); then
    warn "Guard renew dibatalkan: preflight guard belum bersih."
    warn "Perbaiki dulu warning/critical pada guard check sebelum menjalankan renew-if-needed."
    pause
    return 0
  fi

  confirm_yn_or_back "Lanjutkan guard renew-if-needed sekarang setelah melihat preflight di atas?"
  ask_rc=$?
  if (( ask_rc != 0 )); then
    if (( ask_rc == 2 )); then
      warn "Dibatalkan dan kembali ke Domain Control."
      pause
      return 0
    fi
    warn "Dibatalkan oleh pengguna."
    pause
    return 0
  fi
  if ! confirm_menu_apply_now "Konfirmasi final: jalankan binary eksternal xray-domain-guard renew-if-needed sekarang?"; then
    warn "Guard renew dibatalkan pada checkpoint final."
    pause
    return 0
  fi
  local guard_ack=""
  read -r -p "Ketik persis 'GUARD RENEW' untuk lanjut menjalankan renew-if-needed (atau kembali): " guard_ack
  if is_back_choice "${guard_ack}"; then
    warn "Guard renew dibatalkan pada checkpoint final."
    pause
    return 0
  fi
  if [[ "${guard_ack}" != "GUARD RENEW" ]]; then
    warn "Konfirmasi guard renew tidak cocok. Dibatalkan."
    pause
    return 0
  fi

  if ui_run_logged_command_with_spinner spin_log "Menjalankan guard renew" "${XRAY_DOMAIN_GUARD_BIN}" renew-if-needed; then
    rc=0
  else
    rc=$?
  fi
  if ui_run_logged_command_with_spinner post_check_log "Verifikasi postflight guard" "${XRAY_DOMAIN_GUARD_BIN}" check; then
    post_check_rc=0
  else
    post_check_rc=$?
  fi
  domain="$(normalize_domain_token "$(detect_domain)")"
  nginx_domain="$(normalize_domain_token "$(domain_control_current_nginx_domain_get)")"
  compat_domain="$(head -n1 "${XRAY_DOMAIN_FILE}" 2>/dev/null | tr -d '\r' | awk '{print $1}' | tr -d ';' || true)"
  compat_domain="$(normalize_domain_token "${compat_domain}")"
  if [[ -z "${domain}" ]]; then
    post_notes+=("domain aktif tidak terdeteksi")
  fi
  if [[ -n "${domain}" && -n "${nginx_domain}" && "${nginx_domain}" != "${domain}" ]]; then
    post_notes+=("server_name nginx tidak sinkron (${nginx_domain})")
  fi
  if [[ -n "${domain}" && -n "${compat_domain}" && "${compat_domain}" != "${domain}" ]]; then
    post_notes+=("compat domain tidak sinkron (${compat_domain})")
  fi
  if [[ -n "${domain}" ]] && declare -F cert_runtime_hostname_tls_handshake_check >/dev/null 2>&1; then
    if ! cert_runtime_hostname_tls_handshake_check "${domain}" >/dev/null 2>&1; then
      post_notes+=("probe TLS hostname gagal")
    fi
  fi

  hr
  if [[ -n "${spin_log}" && -s "${spin_log}" ]]; then
    cat "${spin_log}" 2>/dev/null || true
    hr
  fi
  if [[ -n "${post_check_log}" && -s "${post_check_log}" ]]; then
    echo "Postflight guard check:"
    cat "${post_check_log}" 2>/dev/null || true
    hr
  fi
  case "${rc}" in
    0) log "Renew-if-needed selesai." ;;
    1) warn "Renew-if-needed selesai dengan warning." ;;
    2) warn "Renew-if-needed selesai, namun masih ada kondisi critical." ;;
    *) warn "Renew-if-needed selesai dengan status ${rc}." ;;
  esac
  if (( post_check_rc != 0 )); then
    warn "Postflight guard check belum bersih (status ${post_check_rc})."
  fi
  if (( ${#post_notes[@]} > 0 )); then
    warn "Verifikasi shell-side setelah guard renew mendeteksi: $(IFS=' | '; echo "${post_notes[*]}")."
  fi
  if (( rc == 0 )); then
    if (( post_check_rc == 0 && ${#post_notes[@]} == 0 )); then
      local guard_followup_pending="false"
      log "Postflight guard sehat: domain/nginx/compat/cert tetap sinkron."
      if [[ -n "${domain}" ]] && domain_control_cf_sync_pending_exists; then
        if confirm_yn_or_back "Terdapat pending repair target DNS Cloudflare setelah guard renew. Repair sekarang?"; then
          domain_control_sync_target_dns_now "${domain}" || rc=1
        else
          dns_prompt_rc=$?
          if (( dns_prompt_rc == 1 || dns_prompt_rc == 2 )); then
            warn "Repair target DNS Cloudflare ditunda. Pending task tetap dipertahankan."
            guard_followup_pending="true"
          fi
        fi
      fi
      if [[ "${rc}" == "0" && -n "${domain}" ]] && domain_control_cf_sync_pending_exists; then
        guard_followup_pending="true"
      fi
      compat_domain="$(head -n1 "${XRAY_DOMAIN_FILE}" 2>/dev/null | tr -d '\r' | awk '{print $1}' | tr -d ';' || true)"
      compat_domain="$(normalize_domain_token "${compat_domain}")"
      if [[ "${rc}" == "0" && -n "${domain}" && "${compat_domain}" != "${domain}" && ! domain_control_cf_sync_pending_exists ]]; then
        if confirm_yn_or_back "Compat domain file belum sinkron setelah guard renew. Sinkronkan sekarang?"; then
          domain_control_sync_compat_domain_now || rc=1
        else
          compat_prompt_rc=$?
          if (( compat_prompt_rc == 1 || compat_prompt_rc == 2 )); then
            warn "Repair compat domain ditunda. Anda masih bisa menjalankannya manual dari Domain Control."
            guard_followup_pending="true"
          fi
        fi
      fi
      compat_domain="$(head -n1 "${XRAY_DOMAIN_FILE}" 2>/dev/null | tr -d '\r' | awk '{print $1}' | tr -d ';' || true)"
      compat_domain="$(normalize_domain_token "${compat_domain}")"
      if [[ "${rc}" == "0" && -n "${domain}" && "${compat_domain}" != "${domain}" ]]; then
        guard_followup_pending="true"
      fi
      if [[ "${rc}" == "0" && -n "${domain}" ]]; then
        local refresh_ip="" guard_refresh_log=""
        refresh_ip="$(normalize_ip_token "$(detect_public_ip_ipapi 2>/dev/null || detect_public_ip 2>/dev/null || true)")"
        if ui_run_logged_command_with_spinner guard_refresh_log "Refresh ACCOUNT INFO pasca-guard renew" domain_control_refresh_account_info_batches_run "${domain}" "${refresh_ip}" "all" "10"; then
          if [[ "${guard_followup_pending}" == "true" ]]; then
            account_info_domain_sync_state_mark_pending >/dev/null 2>&1 || true
            warn "Refresh ACCOUNT INFO pasca-guard renew berhasil, tetapi follow-up domain masih pending."
          else
            account_info_domain_sync_state_write "${domain}" >/dev/null 2>&1 || true
          fi
          rm -f "${guard_refresh_log}" >/dev/null 2>&1 || true
        else
          account_info_domain_sync_state_mark_pending >/dev/null 2>&1 || true
          warn "Postflight guard sehat, tetapi refresh otomatis ACCOUNT INFO pasca-guard renew gagal."
          hr
          tail -n 60 "${guard_refresh_log}" 2>/dev/null || true
          hr
          rm -f "${guard_refresh_log}" >/dev/null 2>&1 || true
        fi
      elif [[ -n "${domain}" && ( "${guard_followup_pending}" == "true" || "${rc}" != "0" ) ]]; then
        account_info_domain_sync_state_mark_pending >/dev/null 2>&1 || true
      fi
    else
      rc=1
    fi
  fi
  rm -f "${spin_log}" >/dev/null 2>&1 || true
  rm -f "${post_check_log}" >/dev/null 2>&1 || true
  pause
  return "${rc}"
}

domain_control_menu() {
  local pending_prompted="false"
  local compat_prompted="false"
  while true; do
    local -a items=()
    local cf_pending_total="false"
    local cf_pending_active="false"
    local cf_pending_count=0
    local cf_pending_active_count=0
    local cf_pending_other_count=0
    local pending_prompt_rc=0
    local compat_prompt_rc=0
    local active_domain="" sync_state_domain="" compat_domain=""
    active_domain="$(normalize_domain_token "$(detect_domain 2>/dev/null || true)")"
    sync_state_domain="$(normalize_domain_token "$(account_info_domain_sync_state_read)")"
    compat_domain="$(head -n1 "${XRAY_DOMAIN_FILE}" 2>/dev/null | tr -d '\r' | awk '{print $1}' | tr -d ';' || true)"
    compat_domain="$(normalize_domain_token "${compat_domain}")"
    cf_pending_count="$(domain_control_cf_sync_pending_count)"
    [[ "${cf_pending_count}" =~ ^[0-9]+$ ]] || cf_pending_count=0
    if (( cf_pending_count > 0 )); then
      cf_pending_total="true"
    else
      pending_prompted="false"
    fi
    if [[ -n "${active_domain}" ]]; then
      cf_pending_active_count="$(domain_control_cf_sync_pending_count "${active_domain}")"
      [[ "${cf_pending_active_count}" =~ ^[0-9]+$ ]] || cf_pending_active_count=0
      if (( cf_pending_active_count > 0 )); then
        cf_pending_active="true"
      fi
    fi
    cf_pending_other_count=$((cf_pending_count - cf_pending_active_count))
    if (( cf_pending_other_count < 0 )); then
      cf_pending_other_count=0
    fi
    items=(
      "1|Set Domain"
      "2|Current Domain"
      "3|Guard Check"
      "4|Guard Renew (external binary)"
      "5|Refresh Account Info"
      "6|Repair Compat Domain Drift (repair-only)"
      "7|Repair Target DNS Record (manual repair)$([[ "${cf_pending_total}" == "true" ]] && printf ' (%s pending)' "${cf_pending_count}")"
      "0|Back"
    )
    ui_menu_screen_begin "8) Domain Control"
    if [[ "${cf_pending_active}" == "true" ]]; then
      warn "Ada ${cf_pending_active_count} pending repair target DNS Cloudflare untuk domain aktif ${active_domain}. Gunakan 'Repair Target DNS Record' bila ingin menyelesaikannya."
      hr
      if [[ "${pending_prompted}" != "true" ]]; then
        pending_prompted="true"
        if confirm_yn_or_back "Buka repair 'Repair Target DNS Record' sekarang?"; then
          menu_run_isolated_report "Repair Target DNS" domain_control_sync_target_dns_now
          continue
        fi
        pending_prompt_rc=$?
        if (( pending_prompt_rc == 1 || pending_prompt_rc == 2 )); then
          warn "Repair target DNS tidak dibuka otomatis. Anda masih bisa memilih menu 7 kapan saja."
          hr
        fi
      fi
    else
      pending_prompted="false"
      if (( cf_pending_other_count > 0 )); then
        warn "Ada ${cf_pending_other_count} pending repair target DNS Cloudflare untuk domain lain. Ini tidak memblokir operasi domain aktif saat ini."
        hr
      fi
    fi
    if [[ "${sync_state_domain}" == "-" ]]; then
      warn "Sync state ACCOUNT INFO masih pending. Jalankan 'Refresh Account Info' sampai semua batch selesai."
      hr
    elif [[ -n "${active_domain}" && -n "${sync_state_domain}" && "${sync_state_domain}" != "${active_domain}" ]]; then
      warn "Sync state ACCOUNT INFO terakhir (${sync_state_domain}) belum cocok dengan domain aktif (${active_domain})."
      hr
    fi
    if [[ "${cf_pending_active}" != "true" && -n "${active_domain}" && -n "${compat_domain}" && "${compat_domain}" != "${active_domain}" ]]; then
      warn "Compat domain drift terdeteksi: ${compat_domain} != ${active_domain}"
      hr
      if [[ "${compat_prompted}" != "true" ]]; then
        compat_prompted="true"
        if confirm_yn_or_back "Buka repair 'Repair Compat Domain Drift' sekarang?"; then
          menu_run_isolated_report "Repair Compat Domain" domain_control_sync_compat_domain_now
          continue
        fi
        compat_prompt_rc=$?
        if (( compat_prompt_rc == 1 || compat_prompt_rc == 2 )); then
          warn "Repair compat domain tidak dibuka otomatis. Anda masih bisa memilih menu 6 kapan saja."
          hr
        fi
      fi
    else
      compat_prompted="false"
    fi
    ui_menu_render_options items 76
    hr
    if ! read -r -p "Pilih: " c; then
      echo
      break
    fi
    case "${c}" in
      1)
        if [[ "${cf_pending_active}" == "true" ]]; then
          warn "Set Domain ditahan: masih ada pending repair target DNS Cloudflare untuk domain aktif."
          warn "Selesaikan 'Repair Target DNS Record' dulu agar perubahan domain baru tidak menumpuk di atas pending repair lama."
          pause
          continue
        fi
        menu_run_isolated_report "Set Domain" domain_control_set_domain_now
        ;;
      2) domain_control_show_info ;;
      3) menu_run_isolated_report "Domain Guard Check" domain_control_guard_check ;;
      4)
        if [[ "${cf_pending_active}" == "true" ]]; then
          warn "Guard Renew ditahan: masih ada pending repair target DNS Cloudflare."
          warn "Selesaikan repair target DNS dulu agar postflight guard tidak berjalan di atas state Cloudflare yang belum sinkron."
          pause
          continue
        fi
        menu_run_isolated_report "Domain Guard Renew (External)" domain_control_guard_renew_if_needed
        ;;
      5)
        if [[ "${cf_pending_active}" == "true" ]]; then
          warn "Refresh Account Info ditahan: masih ada pending repair target DNS Cloudflare."
          warn "Selesaikan repair target DNS dulu agar refresh berjalan di atas state domain yang benar-benar final."
          pause
          continue
        fi
        menu_run_isolated_report "Refresh Account Info" domain_control_refresh_account_info_now
        ;;
      6)
        if [[ "${cf_pending_active}" == "true" ]]; then
          warn "Repair Compat Domain ditahan: masih ada pending repair target DNS Cloudflare."
          warn "Selesaikan repair target DNS dulu agar artefak compat tidak disinkronkan ke state yang belum final."
          pause
          continue
        fi
        menu_run_isolated_report "Repair Compat Domain" domain_control_sync_compat_domain_now
        ;;
      7) menu_run_isolated_report "Repair Target DNS" domain_control_sync_target_dns_now ;;
      0|kembali|k|back|b) break ;;
      *) invalid_choice ;;
    esac
  done
}
