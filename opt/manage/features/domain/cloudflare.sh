#!/usr/bin/env bash
# shellcheck shell=bash

get_public_ipv4() {
  local ip=""
  ip="$(curl -4fsSL https://api.ipify.org 2>/dev/null || true)"
  [[ -n "$ip" ]] || ip="$(curl -4fsSL https://ipv4.icanhazip.com 2>/dev/null | tr -d '[:space:]' || true)"
  [[ -n "$ip" ]] || ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
  [[ -n "$ip" ]] || die "Gagal mendapatkan public IPv4 VPS."
  echo "$ip"
}

cf_api() {
  local method="$1"
  local endpoint="$2"
  local data="${3:-}"

  [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]] || die "CLOUDFLARE_API_TOKEN belum di-set."

  local url="https://api.cloudflare.com/client/v4${endpoint}"
  local resp code body trimmed header_file=""
  header_file="$(mktemp)" || die "Gagal membuat temporary header file Cloudflare."
  printf 'Authorization: Bearer %s\n' "${CLOUDFLARE_API_TOKEN}" > "${header_file}"
  printf 'Content-Type: application/json\n' >> "${header_file}"
  chmod 600 "${header_file}" >/dev/null 2>&1 || true

  if [[ -n "$data" ]]; then
    resp="$(curl -sS -L -X "$method" "$url" \
      -H "@${header_file}" \
      --connect-timeout 10 \
      --max-time 30 \
      --data "$data" \
      -w $'\n%{http_code}' || true)"
  else
    resp="$(curl -sS -L -X "$method" "$url" \
      -H "@${header_file}" \
      --connect-timeout 10 \
      --max-time 30 \
      -w $'\n%{http_code}' || true)"
  fi
  rm -f "${header_file}" >/dev/null 2>&1 || true

  code="${resp##*$'\n'}"
  body="${resp%$'\n'*}"

  if [[ -z "${body:-}" ]]; then
    echo "[Cloudflare] Empty response (HTTP ${code:-?}) for ${endpoint}" >&2
    return 1
  fi

  trimmed="${body#"${body%%[![:space:]]*}"}"
  if [[ ! "$trimmed" =~ ^[\{\[] ]]; then
    echo "[Cloudflare] Non-JSON response (HTTP ${code:-?}) for ${endpoint}:" >&2
    echo "$body" >&2
    return 1
  fi

  if [[ ! "${code:-}" =~ ^2 ]]; then
    echo "[Cloudflare] HTTP ${code:-?} for ${endpoint}:" >&2
    echo "$body" >&2
    return 1
  fi

  printf '%s' "$body"
}

cf_get_zone_id_by_name() {
  local zone_name="$1"
  local json zid err

  json="$(cf_api GET "/zones?name=${zone_name}&per_page=1" || true)"
  if [[ -z "${json:-}" ]]; then
    return 1
  fi

  if ! echo "$json" | jq -e '.success == true' >/dev/null 2>&1; then
    err="$(echo "$json" | jq -r '.errors[0].message // empty' 2>/dev/null || true)"
    [[ -n "$err" ]] && echo "[Cloudflare] $err" >&2
    return 1
  fi

  zid="$(echo "$json" | jq -r '.result[0].id // empty' 2>/dev/null || true)"
  [[ -n "$zid" ]] || return 1
  echo "$zid"
}

cf_get_account_id_by_zone() {
  local zone_id="$1"
  local json aid

  json="$(cf_api GET "/zones/${zone_id}" || true)"
  if [[ -z "${json:-}" ]]; then
    return 1
  fi

  aid="$(echo "$json" | jq -r '.result.account.id // empty' 2>/dev/null || true)"
  [[ -n "$aid" ]] || return 1
  echo "$aid"
}

cf_list_a_records_by_ip() {
  local zone_id="$1"
  local ip="$2"
  local json

  json="$(cf_api GET "/zones/${zone_id}/dns_records?type=A&content=${ip}&per_page=100" || true)"
  if [[ -z "${json:-}" ]]; then
    return 0
  fi

  if ! echo "$json" | jq -e '.success == true' >/dev/null 2>&1; then
    return 1
  fi

  echo "$json" | jq -r '.result[] | "\(.id)\t\(.name)"'
}

cf_delete_record() {
  local zone_id="$1"
  local record_id="$2"
  cf_api DELETE "/zones/${zone_id}/dns_records/${record_id}" >/dev/null \
    || {
      warn "Gagal delete DNS record Cloudflare: ${record_id}"
      return 1
    }
}

cf_create_a_record_with_ttl() {
  local zone_id="$1"
  local name="$2"
  local ip="$3"
  local proxied="${4:-false}"
  local ttl="${5:-1}"

  if [[ "$proxied" != "true" && "$proxied" != "false" ]]; then
    proxied="false"
  fi
  if [[ ! "${ttl}" =~ ^[0-9]+$ ]] || (( ttl < 1 )); then
    ttl=1
  fi

  local payload
  payload="$(cat <<EOF
{"type":"A","name":"$name","content":"$ip","ttl":$ttl,"proxied":$proxied}
EOF
  )"
  cf_api POST "/zones/${zone_id}/dns_records" "$payload" >/dev/null \
    || {
      warn "Gagal membuat A record Cloudflare untuk ${name}"
      return 1
    }
}

cf_create_a_record() {
  local zone_id="$1"
  local name="$2"
  local ip="$3"
  local proxied="${4:-false}"
  cf_create_a_record_with_ttl "${zone_id}" "${name}" "${ip}" "${proxied}" 1
}

cf_sync_a_record_proxy_mode() {
  # args: zone_id fqdn ip desired_proxied
  local zone_id="$1"
  local fqdn="$2"
  local ip="$3"
  local desired_proxied="${4:-false}"
  local json
  local lines=()
  local line rid rip rprox payload
  local failed=0

  if [[ "${desired_proxied}" != "true" && "${desired_proxied}" != "false" ]]; then
    desired_proxied="false"
  fi

  json="$(cf_api GET "/zones/${zone_id}/dns_records?type=A&name=${fqdn}&per_page=100" || true)"
  if [[ -z "${json:-}" ]] || ! echo "$json" | jq -e '.success == true' >/dev/null 2>&1; then
    warn "Gagal membaca status DNS A target ${fqdn} dari Cloudflare."
    return 1
  fi

  mapfile -t lines < <(echo "$json" | jq -r '.result[] | "\(.id)\t\(.content)\t\(.proxied)"' 2>/dev/null || true)
  if [[ ${#lines[@]} -eq 0 ]]; then
    warn "Record DNS A target ${fqdn} tidak ditemukan saat sinkron proxy mode."
    return 1
  fi

  local matched=0
  for line in "${lines[@]}"; do
    rid="${line%%$'\t'*}"
    line="${line#*$'\t'}"
    rip="${line%%$'\t'*}"
    rprox="${line#*$'\t'}"
    if [[ "${rip}" == "${ip}" ]]; then
      matched=1
    fi
    if [[ "${rip}" == "${ip}" && "${rprox}" != "${desired_proxied}" ]]; then
      payload="$(cat <<EOF
{"type":"A","name":"$fqdn","content":"$ip","ttl":1,"proxied":$desired_proxied}
EOF
)"
      cf_api PUT "/zones/${zone_id}/dns_records/${rid}" "$payload" >/dev/null \
        || {
          warn "Gagal menyelaraskan mode proxy Cloudflare untuk record ${fqdn} (${rid})"
          failed=1
        }
    fi
  done
  if (( matched == 0 )); then
    warn "Record DNS A target ${fqdn} tidak lagi mengarah ke ${ip} saat sinkron proxy mode."
    return 1
  fi
  return "${failed}"
}

cf_validate_subdomain_a_record_choice() {
  local zone_id="$1"
  local fqdn="$2"
  local ip="$3"
  local proxied="${4:-false}"
  local json rec_ips any_same any_diff
  local cip ask_rc=0

  if [[ "${proxied}" != "true" && "${proxied}" != "false" ]]; then
    proxied="false"
  fi

  log "Preflight DNS A record Cloudflare untuk: $fqdn"
  json="$(cf_api GET "/zones/${zone_id}/dns_records?type=A&name=${fqdn}&per_page=100" || true)"
  if [[ -z "${json:-}" ]] || ! echo "$json" | jq -e '.success == true' >/dev/null 2>&1; then
    return 0
  fi

  mapfile -t rec_ips < <(echo "$json" | jq -r '.result[].content' 2>/dev/null || true)
  if [[ ${#rec_ips[@]} -eq 0 ]]; then
    return 0
  fi

  any_same="0"
  any_diff="0"
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
    warn "A record target sudah ada: ${fqdn} -> ${ip}"
    echo "Mode proxy target akan diselaraskan ke pilihan saat apply domain."
    if ! confirm_yn_or_back "Lanjut menggunakan domain ini?"; then
      ask_rc=$?
      if (( ask_rc == 2 )); then
        warn "Dibatalkan oleh pengguna (kembali)."
        return 2
      fi
      warn "Dibatalkan oleh pengguna."
      return 1
    fi
  fi

  return 0
}

gen_subdomain_random() {
  rand_str 5
}

validate_subdomain() {
  local s="$1"
  [[ -n "$s" ]] || return 1
  [[ "$s" == "${s,,}" ]] || return 1
  [[ "$s" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$ ]] || return 1
  [[ "$s" != *" "* ]] || return 1
  return 0
}

cf_prepare_subdomain_a_record() {
  local zone_id="$1"
  local fqdn="$2"
  local ip="$3"
  local proxied="${4:-false}"

  log "Menyiapkan DNS A record Cloudflare untuk: $fqdn"

  local json rec_ips any_same any_diff target_ready
  target_ready="0"
  json="$(cf_api GET "/zones/${zone_id}/dns_records?type=A&name=${fqdn}&per_page=100" || true)"
  if [[ -n "${json:-}" ]] && echo "$json" | jq -e '.success == true' >/dev/null 2>&1; then
    mapfile -t rec_ips < <(echo "$json" | jq -r '.result[].content' 2>/dev/null || true)
    if [[ ${#rec_ips[@]} -gt 0 ]]; then
      any_same="0"
      any_diff="0"
      local cip
      for cip in "${rec_ips[@]}"; do
        if [[ "$cip" == "$ip" ]]; then
          any_same="1"
        else
          any_diff="1"
        fi
      done

      if [[ "$any_diff" == "1" ]]; then
        die "Subdomain $fqdn sudah ada di Cloudflare tetapi IP berbeda (${rec_ips[*]}). Gunakan nama subdomain lain."
      fi

      if [[ "$any_same" == "1" ]]; then
        warn "A record sudah ada: $fqdn -> $ip (sama dengan IP VPS)"
        if ! cf_sync_a_record_proxy_mode "$zone_id" "$fqdn" "$ip" "$proxied"; then
          return 1
        fi
        log "Melanjutkan proses dengan record target yang sudah ada."
        target_ready="1"
      fi
    fi
  fi

  if [[ "${target_ready}" != "1" ]]; then
    log "Membuat DNS A record: $fqdn -> $ip"
    if ! cf_create_a_record "$zone_id" "$fqdn" "$ip" "$proxied"; then
      return 1
    fi
    target_ready="1"
  fi

  local same_ip=()
  mapfile -t same_ip < <(cf_list_a_records_by_ip "$zone_id" "$ip" || true)
  if [[ ${#same_ip[@]} -gt 0 ]]; then
    local line
    for line in "${same_ip[@]}"; do
      local rid="${line%%$'\t'*}"
      local rname="${line#*$'\t'}"
      if [[ -n "${rid}" && "$rname" != "$fqdn" ]]; then
        warn "Ditemukan A record lain dengan IP sama ($ip): $rname -> $ip"
        warn "Menghapus A record: $rname"
        if ! cf_delete_record "$zone_id" "$rid"; then
          return 1
        fi
      fi
    done
  fi
  return 0
}

cf_snapshot_relevant_a_records() {
  local zone_id="$1"
  local fqdn="$2"
  local ip="$3"
  local outfile="${4:-}"
  local target_file="" same_file="" target_json="" same_json=""
  local empty_json='{"result":[]}'

  [[ -n "${outfile}" ]] || return 1
  target_file="$(mktemp "${WORK_DIR}/.cf-target.XXXXXX" 2>/dev/null || true)"
  same_file="$(mktemp "${WORK_DIR}/.cf-same-ip.XXXXXX" 2>/dev/null || true)"
  [[ -n "${target_file}" && -n "${same_file}" ]] || {
    rm -f -- "${target_file}" "${same_file}" >/dev/null 2>&1 || true
    return 1
  }

  target_json="$(cf_api GET "/zones/${zone_id}/dns_records?type=A&name=${fqdn}&per_page=100" 2>/dev/null || true)"
  same_json="$(cf_api GET "/zones/${zone_id}/dns_records?type=A&content=${ip}&per_page=100" 2>/dev/null || true)"
  printf '%s\n' "${target_json:-${empty_json}}" > "${target_file}" || return 1
  printf '%s\n' "${same_json:-${empty_json}}" > "${same_file}" || return 1

  if ! jq -s '
    [.[0].result // [], .[1].result // []]
    | add
    | map(select((.type // "A") == "A"))
    | unique_by(.id)
    | map({
        id: (.id // ""),
        name: (.name // ""),
        content: (.content // ""),
        proxied: (.proxied // false),
        ttl: (.ttl // 1)
      })
  ' "${target_file}" "${same_file}" > "${outfile}" 2>/dev/null; then
    rm -f -- "${outfile}" "${target_file}" "${same_file}" >/dev/null 2>&1 || true
    return 1
  fi

  chmod 600 "${outfile}" >/dev/null 2>&1 || true
  rm -f -- "${target_file}" "${same_file}" >/dev/null 2>&1 || true
  return 0
}

cf_restore_relevant_a_records_snapshot() {
  local zone_id="$1"
  local fqdn="$2"
  local ip="$3"
  local snapshot_file="${4:-}"
  local target_file="" same_file="" current_target="" current_same=""
  local empty_json='{"result":[]}'
  local -a current_ids=()

  [[ -f "${snapshot_file}" ]] || return 1
  target_file="$(mktemp "${WORK_DIR}/.cf-restore-target.XXXXXX" 2>/dev/null || true)"
  same_file="$(mktemp "${WORK_DIR}/.cf-restore-same.XXXXXX" 2>/dev/null || true)"
  [[ -n "${target_file}" && -n "${same_file}" ]] || {
    rm -f -- "${target_file}" "${same_file}" >/dev/null 2>&1 || true
    return 1
  }

  current_target="$(cf_api GET "/zones/${zone_id}/dns_records?type=A&name=${fqdn}&per_page=100" 2>/dev/null || true)"
  current_same="$(cf_api GET "/zones/${zone_id}/dns_records?type=A&content=${ip}&per_page=100" 2>/dev/null || true)"
  printf '%s\n' "${current_target:-${empty_json}}" > "${target_file}" || return 1
  printf '%s\n' "${current_same:-${empty_json}}" > "${same_file}" || return 1

  mapfile -t current_ids < <(
    jq -s -r '
      [.[0].result // [], .[1].result // []]
      | add
      | map(select((.type // "A") == "A"))
      | unique_by(.id)
      | .[] | (.id // empty)
    ' "${target_file}" "${same_file}" 2>/dev/null || true
  )

  local rid name content proxied ttl
  for rid in "${current_ids[@]}"; do
    [[ -n "${rid}" ]] || continue
    if ! cf_delete_record "${zone_id}" "${rid}"; then
      rm -f -- "${target_file}" "${same_file}" >/dev/null 2>&1 || true
      return 1
    fi
  done

  while IFS=$'\t' read -r name content proxied ttl; do
    [[ -n "${name}" && -n "${content}" ]] || continue
    if ! cf_create_a_record_with_ttl "${zone_id}" "${name}" "${content}" "${proxied}" "${ttl}"; then
      rm -f -- "${target_file}" "${same_file}" >/dev/null 2>&1 || true
      return 1
    fi
  done < <(
    jq -r '
      .[]
      | [
          (.name // ""),
          (.content // ""),
          (if (.proxied // false) then "true" else "false" end),
          ((.ttl // 1) | tostring)
        ]
      | @tsv
    ' "${snapshot_file}" 2>/dev/null || true
  )

  rm -f -- "${target_file}" "${same_file}" >/dev/null 2>&1 || true
  return 0
}


