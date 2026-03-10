#!/usr/bin/env bash
# Domain and certificate module for setup runtime.

declare -ag _ACME_RESTORE_SERVICES=()
declare -gi _ACME_RESTORE_NEEDED=0

acme_append_restore_service() {
  local candidate="$1"
  local existing
  [[ -n "${candidate}" ]] || return 0
  for existing in "${_ACME_RESTORE_SERVICES[@]}"; do
    [[ "${existing}" == "${candidate}" ]] && return 0
  done
  _ACME_RESTORE_SERVICES+=("${candidate}")
}

acme_restore_conflicting_services_on_failure() {
  local svc
  [[ "${_ACME_RESTORE_NEEDED:-0}" == "1" ]] || return 0
  for svc in "${_ACME_RESTORE_SERVICES[@]}"; do
    if systemctl show -p LoadState --value "${svc}" 2>/dev/null | grep -qv '^not-found$'; then
      systemctl start "${svc}" >/dev/null 2>&1 || true
    fi
  done
}
register_exit_cleanup acme_restore_conflicting_services_on_failure

snapshot_conflicting_services_active() {
  local svc
  _ACME_RESTORE_SERVICES=()
  for svc in nginx apache2 caddy lighttpd; do
    if systemctl is-active --quiet "${svc}" >/dev/null 2>&1; then
      acme_append_restore_service "${svc}"
    fi
  done
  if acme_edge_runtime_enabled_for_http80; then
    svc="$(acme_edge_runtime_service_name)"
    if [[ -n "${svc}" && "${svc}" != "nginx" ]] && systemctl is-active --quiet "${svc}" >/dev/null 2>&1; then
      acme_append_restore_service "${svc}"
    fi
  fi
}

acme_edge_runtime_service_name() {
  local provider="${EDGE_PROVIDER:-none}"
  case "${provider}" in
    nginx-stream) printf '%s\n' "nginx" ;;
    go) printf '%s\n' "${EDGE_SERVICE_NAME:-edge-mux.service}" ;;
    *) return 1 ;;
  esac
}

acme_edge_runtime_enabled_for_http80() {
  local provider active http_port
  provider="${EDGE_PROVIDER:-none}"
  active="${EDGE_ACTIVATE_RUNTIME:-false}"
  http_port="${EDGE_PUBLIC_HTTP_PORT:-80}"
  [[ "${provider}" != "none" ]] || return 1
  case "${active}" in
    1|true|TRUE|yes|YES|on|ON) ;;
    *) return 1 ;;
  esac
  [[ "${http_port}" == "80" ]]
}

acme_stop_additional_conflicting_services() {
  local svc=""
  if acme_edge_runtime_enabled_for_http80; then
    svc="$(acme_edge_runtime_service_name 2>/dev/null || true)"
    if [[ -n "${svc}" && "${svc}" != "nginx" ]] && systemctl is-active --quiet "${svc}" >/dev/null 2>&1; then
      systemctl stop "${svc}" >/dev/null 2>&1 || true
    fi
  fi
}

acme_restart_active_tls_consumers() {
  local edge_svc
  if systemctl is-active --quiet sshws-stunnel >/dev/null 2>&1; then
    systemctl restart sshws-stunnel >/dev/null 2>&1 || die "Gagal restart sshws-stunnel setelah update cert."
    systemctl is-active --quiet sshws-stunnel >/dev/null 2>&1 || die "sshws-stunnel tidak active setelah update cert."
  fi
  edge_svc="$(acme_edge_runtime_service_name 2>/dev/null || true)"
  if [[ -n "${edge_svc}" && "${edge_svc}" != "nginx" ]] && systemctl is-active --quiet "${edge_svc}" >/dev/null 2>&1; then
    if systemctl reload "${edge_svc}" >/dev/null 2>&1; then
      :
    else
      systemctl restart "${edge_svc}" >/dev/null 2>&1 || die "Gagal reload/restart ${edge_svc} setelah update cert."
    fi
    systemctl is-active --quiet "${edge_svc}" >/dev/null 2>&1 || die "${edge_svc} tidak active setelah update cert."
  fi
}

acme_restore_conflicting_services_after_success() {
  local svc
  for svc in "${_ACME_RESTORE_SERVICES[@]}"; do
    [[ "${svc}" == "nginx" ]] && continue
    if systemctl show -p LoadState --value "${svc}" 2>/dev/null | grep -qv '^not-found$'; then
      systemctl start "${svc}" >/dev/null 2>&1 || die "Gagal restore service ${svc} setelah update cert."
    fi
  done
  _ACME_RESTORE_SERVICES=()
  _ACME_RESTORE_NEEDED=0
}

rand_email() {
  local user part
  user="$(rand_str 10)"
  part="$(rand_str 6)"
  local domains=("gmail.com" "outlook.com" "proton.me" "icloud.com" "yahoo.com")
  local idx=$(( RANDOM % ${#domains[@]} ))
  echo "${user}.${part}@${domains[$idx]}"
}

get_public_ipv4() {
  local ip=""
  ip="$(curl -4fsSL https://api.ipify.org 2>/dev/null || true)"
  [[ -n "${ip}" ]] || ip="$(curl -4fsSL https://ipv4.icanhazip.com 2>/dev/null | tr -d '[:space:]' || true)"
  [[ -n "${ip}" ]] || ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i==\"src\"){print $(i+1); exit}}')"
  [[ -n "${ip}" ]] || die "Gagal mendapatkan public IPv4 VPS."
  echo "${ip}"
}

detect_domain() {
  local dom=""
  if [[ -n "${DOMAIN:-}" ]]; then
    dom="${DOMAIN}"
  elif [[ -s "${XRAY_DOMAIN_FILE}" ]]; then
    dom="$(head -n1 "${XRAY_DOMAIN_FILE}" 2>/dev/null | tr -d '\r' | awk '{print $1}' | tr -d ';' || true)"
  elif [[ -f "${NGINX_CONF}" ]]; then
    dom="$(grep -E '^[[:space:]]*server_name[[:space:]]+' "${NGINX_CONF}" 2>/dev/null | head -n1 | sed -E 's/^[[:space:]]*server_name[[:space:]]+//; s/;.*$//' | awk '{print $1}' | tr -d ';' || true)"
  fi
  echo "${dom}"
}

sync_xray_domain_file() {
  local domain="${1:-}"
  local normalized tmp
  if [[ -z "${domain}" ]]; then
    domain="$(detect_domain)"
  fi
  normalized="$(printf '%s' "${domain}" | tr -d '\r\n' | awk '{print $1}' | tr -d ';')"
  [[ -n "${normalized}" ]] || return 1

  install -d -m 755 "$(dirname "${XRAY_DOMAIN_FILE}")" >/dev/null 2>&1 || return 1
  tmp="$(mktemp)" || return 1
  if ! printf '%s\n' "${normalized}" > "${tmp}"; then
    rm -f "${tmp}" >/dev/null 2>&1 || true
    return 1
  fi
  if ! install -m 644 "${tmp}" "${XRAY_DOMAIN_FILE}"; then
    rm -f "${tmp}" >/dev/null 2>&1 || true
    return 1
  fi
  rm -f "${tmp}" >/dev/null 2>&1 || true
  return 0
}

cf_api() {
  local method="$1"
  local endpoint="$2"
  local data="${3:-}"

  [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]] || die "CLOUDFLARE_API_TOKEN belum di-set. Isi token Cloudflare di setup.sh atau export env CLOUDFLARE_API_TOKEN."

  local url="https://api.cloudflare.com/client/v4${endpoint}"
  local resp code body trimmed header_file=""
  header_file="$(mktemp)" || die "Gagal membuat temporary header file Cloudflare."
  printf 'Authorization: Bearer %s\n' "${CLOUDFLARE_API_TOKEN}" > "${header_file}"
  printf 'Content-Type: application/json\n' >> "${header_file}"
  chmod 600 "${header_file}" >/dev/null 2>&1 || true

  if [[ -n "${data}" ]]; then
    resp="$(curl -sS -L -X "${method}" "${url}" -H "@${header_file}" --connect-timeout 10 --max-time 30 --data "${data}" -w $'\n%{http_code}' || true)"
  else
    resp="$(curl -sS -L -X "${method}" "${url}" -H "@${header_file}" --connect-timeout 10 --max-time 30 -w $'\n%{http_code}' || true)"
  fi
  rm -f "${header_file}" >/dev/null 2>&1 || true

  code="${resp##*$'\n'}"
  body="${resp%$'\n'*}"

  if [[ -z "${body:-}" ]]; then
    echo "[Cloudflare] Empty response (HTTP ${code:-?}) for ${endpoint}" >&2
    return 1
  fi

  trimmed="${body#"${body%%[![:space:]]*}"}"
  if [[ ! "${trimmed}" =~ ^[\{\[] ]]; then
    echo "[Cloudflare] Non-JSON response (HTTP ${code:-?}) for ${endpoint}:" >&2
    echo "${body}" >&2
    return 1
  fi

  if [[ ! "${code:-}" =~ ^2 ]]; then
    echo "[Cloudflare] HTTP ${code:-?} for ${endpoint}:" >&2
    echo "${body}" >&2
    return 1
  fi

  printf '%s' "${body}"
}

cf_list_zones() {
  cf_api GET "/zones?per_page=50" | jq -r '
  if .success == true then
    .result[] | "\(.id)\t\(.name)"
  else
    empty
  end
  '
}

cf_get_zone_id_by_name() {
  local zone_name="$1"
  local json zid err

  json="$(cf_api GET "/zones?name=${zone_name}&per_page=1" || true)"
  if [[ -z "${json:-}" ]]; then
    return 1
  fi
  if ! echo "${json}" | jq -e '.success == true' >/dev/null 2>&1; then
    err="$(echo "${json}" | jq -r '.errors[0].message // empty' 2>/dev/null || true)"
    [[ -n "${err}" ]] && echo "[Cloudflare] ${err}" >&2
    return 1
  fi
  zid="$(echo "${json}" | jq -r '.result[0].id // empty' 2>/dev/null || true)"
  [[ -n "${zid}" ]] || return 1
  echo "${zid}"
}

cf_get_account_id_by_zone() {
  local zone_id="$1"
  local json aid

  json="$(cf_api GET "/zones/${zone_id}" || true)"
  if [[ -z "${json:-}" ]]; then
    return 1
  fi

  aid="$(echo "${json}" | jq -r '.result.account.id // empty' 2>/dev/null || true)"
  [[ -n "${aid}" ]] || return 1
  echo "${aid}"
}

cf_get_a_record_by_name() {
  local zone_id="$1"
  local name="$2"
  local json

  json="$(cf_api GET "/zones/${zone_id}/dns_records?type=A&name=${name}&per_page=100" || true)"
  if [[ -z "${json:-}" ]]; then
    return 0
  fi
  if ! echo "${json}" | jq -e '.success == true' >/dev/null 2>&1; then
    return 1
  fi

  echo "${json}" | jq -r '.result[] | "\(.id)\t\(.content)"' | head -n 1
}

cf_list_a_records_by_ip() {
  local zone_id="$1"
  local ip="$2"
  local json

  json="$(cf_api GET "/zones/${zone_id}/dns_records?type=A&content=${ip}&per_page=100" || true)"
  if [[ -z "${json:-}" ]]; then
    return 0
  fi
  if ! echo "${json}" | jq -e '.success == true' >/dev/null 2>&1; then
    return 1
  fi

  echo "${json}" | jq -r '.result[] | "\(.id)\t\(.name)"'
}

cf_delete_record() {
  local zone_id="$1"
  local record_id="$2"
  cf_api DELETE "/zones/${zone_id}/dns_records/${record_id}" >/dev/null || die "Gagal delete DNS record Cloudflare: ${record_id}"
}

cf_create_a_record() {
  local zone_id="$1"
  local name="$2"
  local ip="$3"
  local proxied="${4:-false}"

  if [[ "${proxied}" != "true" && "${proxied}" != "false" ]]; then
    proxied="false"
  fi

  local payload
  payload="$(cat <<EOF
{"type":"A","name":"${name}","content":"${ip}","ttl":1,"proxied":${proxied}}
EOF
)"
  cf_api POST "/zones/${zone_id}/dns_records" "${payload}" >/dev/null || die "Gagal membuat A record Cloudflare untuk ${name}"
}

cf_force_a_record_dns_only() {
  local zone_id="$1"
  local fqdn="$2"
  local ip="$3"
  local json
  local lines=()
  local line rid rip rprox payload

  json="$(cf_api GET "/zones/${zone_id}/dns_records?type=A&name=${fqdn}&per_page=100" || true)"
  if [[ -z "${json:-}" ]] || ! echo "${json}" | jq -e '.success == true' >/dev/null 2>&1; then
    return 0
  fi

  mapfile -t lines < <(echo "${json}" | jq -r '.result[] | "\(.id)\t\(.content)\t\(.proxied)"' 2>/dev/null || true)
  if [[ ${#lines[@]} -eq 0 ]]; then
    return 0
  fi

  for line in "${lines[@]}"; do
    rid="${line%%$'\t'*}"
    line="${line#*$'\t'}"
    rip="${line%%$'\t'*}"
    rprox="${line#*$'\t'}"
    if [[ "${rip}" == "${ip}" && "${rprox}" == "true" ]]; then
      payload="$(cat <<EOF
{"type":"A","name":"${fqdn}","content":"${ip}","ttl":1,"proxied":false}
EOF
)"
      cf_api PUT "/zones/${zone_id}/dns_records/${rid}" "${payload}" >/dev/null \
        || warn "Gagal memaksa DNS only untuk record ${fqdn} (${rid})"
    fi
  done
}

gen_subdomain_random() {
  rand_str 5
}

validate_subdomain() {
  local s="$1"
  [[ -n "${s}" ]] || return 1
  [[ "${s}" == "${s,,}" ]] || return 1
  [[ "${s}" != *" "* ]] || return 1
  [[ "${s}" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$ ]] || return 1
  return 0
}

cf_prepare_subdomain_a_record() {
  local zone_id="$1"
  local fqdn="$2"
  local ip="$3"
  local proxied="${4:-false}"

  ok "Cek DNS A: ${fqdn}"

  local json rec_ips any_same any_diff
  json="$(cf_api GET "/zones/${zone_id}/dns_records?type=A&name=${fqdn}&per_page=100" || true)"
  if [[ -n "${json:-}" ]] && echo "${json}" | jq -e '.success == true' >/dev/null 2>&1; then
    mapfile -t rec_ips < <(echo "${json}" | jq -r '.result[].content' 2>/dev/null || true)
    if [[ ${#rec_ips[@]} -gt 0 ]]; then
      any_same="0"
      any_diff="0"
      local cip
      for cip in "${rec_ips[@]}"; do
        if [[ "${cip}" == "${ip}" ]]; then
          any_same="1"
        else
          any_diff="1"
        fi
      done

      if [[ "${any_diff}" == "1" ]]; then
        die "Subdomain ${fqdn} sudah ada di Cloudflare tetapi IP berbeda (${rec_ips[*]}). Gunakan nama subdomain lain."
      fi

      if [[ "${any_same}" == "1" ]]; then
        warn "A record sudah ada: ${fqdn} -> ${ip} (sama dengan IP VPS)"
        if confirm_yn "Lanjut menggunakan domain ini?"; then
          cf_force_a_record_dns_only "${zone_id}" "${fqdn}" "${ip}"
          ok "Lanjut."
          return 0
        fi
        die "Dibatalkan oleh pengguna."
      fi
    fi
  fi

  local same_ip=()
  mapfile -t same_ip < <(cf_list_a_records_by_ip "${zone_id}" "${ip}" || true)
  if [[ ${#same_ip[@]} -gt 0 ]]; then
    local line
    for line in "${same_ip[@]}"; do
      local rid="${line%%$'\t'*}"
      local rname="${line#*$'\t'}"
      if [[ "${rname}" != "${fqdn}" ]]; then
        warn "Ditemukan A record lain dengan IP sama (${ip}): ${rname} -> ${ip}"
        warn "Menghapus A record: ${rname}"
        cf_delete_record "${zone_id}" "${rid}"
      fi
    done
  fi

  ok "Buat A record: ${fqdn} -> ${ip}"
  cf_create_a_record "${zone_id}" "${fqdn}" "${ip}" "${proxied}"
}

domain_menu_v2() {
  ui_header "Konfigurasi Domain TLS"
  echo -e "${DIM}Pilih metode domain untuk proses setup.${NC}"
  echo -e "  ${CYAN}1)${NC} Input domain manual"
  echo -e "  ${CYAN}2)${NC} Gunakan domain yang disediakan"
  ui_hr

  local choice=""
  while true; do
    if ! read -r -p "Pilih opsi (1-2): " choice; then
      die "Input terhenti (EOF) pada pemilihan opsi domain (1-2). Jalankan setup.sh secara interaktif atau berikan stdin yang lengkap."
    fi
    case "${choice}" in
      1|2) break ;;
      *) echo "Pilihan tidak valid." ;;
    esac
  done

  if [[ "${choice}" == "1" ]]; then
    local re='^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$'
    while true; do
      if ! read -r -p "Masukkan domain: " DOMAIN; then
        die "Input terhenti (EOF) saat memasukkan domain. Jalankan setup.sh secara interaktif atau berikan stdin yang lengkap."
      fi
      DOMAIN="${DOMAIN,,}"

      [[ -n "${DOMAIN:-}" ]] || {
        echo "Domain tidak boleh kosong."
        continue
      }

      if [[ "${DOMAIN}" =~ ${re} ]]; then
        ok "Domain: ${DOMAIN}"
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
  ok "IP publik: ${VPS_IPV4}"

  [[ ${#PROVIDED_ROOT_DOMAINS[@]} -gt 0 ]] || die "Daftar domain induk (PROVIDED_ROOT_DOMAINS) kosong."

  echo
  echo -e "${BOLD}Pilih domain induk${NC}"
  local i=1
  local root=""
  for root in "${PROVIDED_ROOT_DOMAINS[@]}"; do
    echo -e "  ${CYAN}${i})${NC} ${root}"
    i=$((i + 1))
  done

  local pick=""
  while true; do
    if ! read -r -p "Pilih nomor domain induk (1-${#PROVIDED_ROOT_DOMAINS[@]}): " pick; then
      die "Input terhenti (EOF) saat memilih domain induk. Jalankan setup.sh secara interaktif atau berikan stdin yang lengkap."
    fi
    [[ "${pick}" =~ ^[0-9]+$ ]] || { echo "Input harus angka."; continue; }
    [[ "${pick}" -ge 1 && "${pick}" -le ${#PROVIDED_ROOT_DOMAINS[@]} ]] || { echo "Di luar range."; continue; }
    break
  done

  ACME_ROOT_DOMAIN="${PROVIDED_ROOT_DOMAINS[$((pick-1))]}"
  ok "Root domain: ${ACME_ROOT_DOMAIN}"

  CF_ZONE_ID="$(cf_get_zone_id_by_name "${ACME_ROOT_DOMAIN}" || true)"
  [[ -n "${CF_ZONE_ID:-}" ]] || die "Zone Cloudflare untuk ${ACME_ROOT_DOMAIN} tidak ditemukan / token tidak punya akses (butuh Zone:Read + DNS:Edit)."
  CF_ACCOUNT_ID="$(cf_get_account_id_by_zone "${CF_ZONE_ID}" || true)"
  [[ -n "${CF_ACCOUNT_ID:-}" ]] || warn "CF_ACCOUNT_ID tidak terbaca (boleh lanjut)."

  echo
  echo -e "${BOLD}Pilih metode pembuatan subdomain${NC}"
  echo -e "  ${CYAN}1)${NC} Generate acak"
  echo -e "  ${CYAN}2)${NC} Input manual"

  local mth=""
  while true; do
    if ! read -r -p "Pilih opsi (1-2): " mth; then
      die "Input terhenti (EOF) saat memilih metode subdomain. Jalankan setup.sh secara interaktif atau berikan stdin yang lengkap."
    fi
    case "${mth}" in
      1|2) break ;;
      *) echo "Pilihan tidak valid." ;;
    esac
  done

  local sub=""
  if [[ "${mth}" == "1" ]]; then
    sub="$(gen_subdomain_random)"
    ok "Subdomain: ${sub}"
  else
    while true; do
      if ! read -r -p "Masukkan nama subdomain: " sub; then
        die "Input terhenti (EOF) saat memasukkan subdomain. Jalankan setup.sh secara interaktif atau berikan stdin yang lengkap."
      fi
      sub="${sub,,}"
      if validate_subdomain "${sub}"; then
        ok "Subdomain: ${sub}"
        break
      fi
      echo "Subdomain tidak valid. Gunakan huruf kecil, angka, titik, dan strip (-)."
    done
  fi

  echo
  if confirm_yn "Aktifkan Cloudflare proxy (orange cloud) untuk DNS A record?"; then
    warn "Cloudflare proxy dimatikan."
  fi
  CF_PROXIED="false"
  ok "Cloudflare proxy: OFF"
  DOMAIN="${sub}.${ACME_ROOT_DOMAIN}"
  ok "Domain: ${DOMAIN}"

  cf_prepare_subdomain_a_record "${CF_ZONE_ID}" "${DOMAIN}" "${VPS_IPV4}" "${CF_PROXIED}"

  ACME_CERT_MODE="dns_cf_wildcard"
  ok "Mode cert: dns_cf wildcard"
}

install_acme_and_issue_cert() {
  local email=""
  if [[ "${ACME_CERT_MODE}" != "dns_cf_wildcard" ]]; then
    snapshot_conflicting_services_active
    _ACME_RESTORE_NEEDED=1
    stop_conflicting_services
    acme_stop_additional_conflicting_services
  else
    _ACME_RESTORE_SERVICES=()
    _ACME_RESTORE_NEEDED=0
  fi
  mkdir -p "$CERT_DIR"

  if [[ -x /root/.acme.sh/acme.sh ]]; then
    ok "acme.sh sudah ada."
  else
    ok "Pasang acme.sh..."
    email="$(rand_email)"
    ok "Email ACME: ${email}"
    local acme_tarball acme_tmpdir acme_dns_hook
    acme_tarball="$(mktemp)"
    acme_tmpdir="$(mktemp -d)"
    acme_dns_hook="$(mktemp)"
    download_file_or_die "${ACME_SH_TARBALL_URL}" "${acme_tarball}" "" "acme.sh tarball"
    download_file_or_die "${ACME_SH_DNS_CF_HOOK_URL}" "${acme_dns_hook}" "" "acme.sh dns_cf hook"
    tar -xzf "${acme_tarball}" -C "${acme_tmpdir}" --strip-components=1 || die "Gagal ekstrak acme.sh tarball."
    [[ -f "${acme_tmpdir}/acme.sh" ]] || die "Tarball acme.sh tidak berisi entry acme.sh."
    install -m 644 "${acme_dns_hook}" "${acme_tmpdir}/dnsapi/dns_cf.sh"
    chmod +x "${acme_tmpdir}/acme.sh"
    export HOME=/root
    (
      cd "${acme_tmpdir}" || exit 1
      sh ./acme.sh --install --home /root/.acme.sh --accountemail "${email}"
    ) >/dev/null || {
      rm -f "${acme_tarball}" "${acme_dns_hook}" >/dev/null 2>&1 || true
      rm -rf "${acme_tmpdir}" >/dev/null 2>&1 || true
      die "Gagal install acme.sh"
    }
    rm -f "${acme_tarball}" "${acme_dns_hook}" >/dev/null 2>&1 || true
    rm -rf "${acme_tmpdir}" >/dev/null 2>&1 || true
  fi

  export PATH="/root/.acme.sh:$PATH"
  /root/.acme.sh/acme.sh --set-default-ca --server "${ACME_DEFAULT_CA}" >/dev/null 2>&1 || true

  if [[ "${ACME_CERT_MODE}" == "dns_cf_wildcard" ]]; then
    ok "Issue wildcard cert via dns_cf..."
    [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]] || die "CLOUDFLARE_API_TOKEN kosong."
    [[ -n "${CF_ZONE_ID:-}" ]] || die "CF_ZONE_ID kosong untuk mode dns_cf_wildcard."

    export CF_Token="${CLOUDFLARE_API_TOKEN}"
    [[ -n "${CF_ACCOUNT_ID:-}" ]] && export CF_Account_ID="${CF_ACCOUNT_ID}"
    [[ -n "${CF_ZONE_ID:-}" ]] && export CF_Zone_ID="${CF_ZONE_ID}"

    /root/.acme.sh/acme.sh --issue --force --dns dns_cf \
      -d "${DOMAIN}" -d "*.${DOMAIN}" \
      || die "Gagal issue sertifikat wildcard via dns_cf (pastikan token Cloudflare valid)."

    /root/.acme.sh/acme.sh --install-cert -d "${DOMAIN}" \
      --key-file "${CERT_PRIVKEY}" \
      --fullchain-file "${CERT_FULLCHAIN}" \
      --reloadcmd "/bin/true" >/dev/null \
      || die "Gagal install sertifikat wildcard ke ${CERT_DIR}."
  else
    ok "Issue cert via standalone :80..."
    /root/.acme.sh/acme.sh --issue --force --standalone -d "${DOMAIN}" --httpport 80 \
      || die "Gagal issue sertifikat (pastikan port 80 terbuka & DNS domain mengarah ke VPS)."

    /root/.acme.sh/acme.sh --install-cert -d "${DOMAIN}" \
      --key-file "${CERT_PRIVKEY}" \
      --fullchain-file "${CERT_FULLCHAIN}" \
      --reloadcmd "/bin/true" >/dev/null \
      || die "Gagal install sertifikat ke ${CERT_DIR}."
  fi

  nginx -t >/dev/null 2>&1 || die "Konfigurasi nginx tidak valid setelah install-cert."
  systemctl restart nginx >/dev/null 2>&1 || die "Gagal restart nginx setelah install-cert."
  acme_restart_active_tls_consumers
  acme_restore_conflicting_services_after_success

  chmod 600 "${CERT_PRIVKEY}" "${CERT_FULLCHAIN}"

  ok "Cert saved:"
  ok "  - ${CERT_FULLCHAIN}"
  ok "  - ${CERT_PRIVKEY}"
}
