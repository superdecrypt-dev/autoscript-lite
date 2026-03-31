#!/usr/bin/env bash
# Shared Autoscript license guard helpers for setup runtime.

autoscript_license_enabled() {
  local api_url=""
  api_url="$(autoscript_license_resolve_api_url)"
  [[ -n "${api_url}" ]]
}

autoscript_license_runtime_enforce_enabled() {
  local raw="${AUTOSCRIPT_LICENSE_RUNTIME_ENFORCE:-true}"
  raw="$(printf '%s' "${raw}" | tr '[:upper:]' '[:lower:]')"
  [[ "${raw}" == "1" || "${raw}" == "true" || "${raw}" == "yes" || "${raw}" == "on" ]]
}

autoscript_license_repo_bin_path() {
  printf '%s\n' "${SETUP_BIN_SRC_DIR}/autoscript-license-check"
}

autoscript_license_installed_bin_path() {
  printf '%s\n' "/usr/local/bin/autoscript-license-check"
}

autoscript_license_trusted_default_api_url() {
  printf '%s\n' "https://autoscript-license.minidecrypt.workers.dev/api/v1/license/check"
}

autoscript_license_config_file_path() {
  printf '%s\n' "/etc/autoscript/license/config.env"
}

autoscript_license_config_get() {
  local key="$1"
  local env_file=""
  env_file="$(autoscript_license_config_file_path)"
  [[ -r "${env_file}" ]] || return 1
  awk -F= -v key="${key}" '
    $1 == key {
      sub(/^[[:space:]]+/, "", $2)
      sub(/[[:space:]]+$/, "", $2)
      print $2
      exit
    }
  ' "${env_file}"
}

autoscript_license_resolve_api_url() {
  local api_url=""
  local default_api_url=""
  local trusted_default=""
  trusted_default="$(autoscript_license_trusted_default_api_url)"
  api_url="$(autoscript_license_config_get AUTOSCRIPT_LICENSE_API_URL 2>/dev/null || true)"
  default_api_url="$(autoscript_license_config_get AUTOSCRIPT_LICENSE_DEFAULT_API_URL 2>/dev/null || true)"
  if [[ -n "${api_url}" ]]; then
    printf '%s\n' "${api_url}"
    return 0
  fi
  if [[ -n "${default_api_url}" ]]; then
    printf '%s\n' "${default_api_url}"
    return 0
  fi
  printf '%s\n' "${trusted_default}"
}

autoscript_license_resolve_bin_path() {
  local repo_bin=""
  local installed_bin=""

  installed_bin="$(autoscript_license_installed_bin_path)"

  if [[ -f "${installed_bin}" ]]; then
    printf '%s\n' "${installed_bin}"
    return 0
  fi

  repo_bin="$(autoscript_license_repo_bin_path)"
  if [[ -f "${repo_bin}" ]]; then
    printf '%s\n' "${repo_bin}"
    return 0
  fi

  die "Binary autoscript-license-check tidak ditemukan: installed=${installed_bin} repo=${repo_bin}"
}

autoscript_license_exec_repo_bin() {
  local license_bin=""
  local api_url=""
  local config_file=""
  local trusted_default_api_url=""
  license_bin="$(autoscript_license_resolve_bin_path)"
  api_url="$(autoscript_license_resolve_api_url)"
  config_file="$(autoscript_license_config_file_path)"
  trusted_default_api_url="$(autoscript_license_trusted_default_api_url)"
  AUTOSCRIPT_LICENSE_DEFAULT_API_URL="${trusted_default_api_url}" \
  AUTOSCRIPT_LICENSE_API_URL="${api_url}" \
  AUTOSCRIPT_LICENSE_CACHE_TTL_SEC="${AUTOSCRIPT_LICENSE_CACHE_TTL_SEC:-3600}" \
  AUTOSCRIPT_LICENSE_RUNTIME_ENFORCE="${AUTOSCRIPT_LICENSE_RUNTIME_ENFORCE:-true}" \
  AUTOSCRIPT_LICENSE_RUNTIME_INTERVAL_MIN="${AUTOSCRIPT_LICENSE_RUNTIME_INTERVAL_MIN:-15}" \
  AUTOSCRIPT_LICENSE_CONFIG_FILE="${config_file}" \
  AUTOSCRIPT_LICENSE_STATE_FILE="${AUTOSCRIPT_LICENSE_STATE_FILE}" \
  AUTOSCRIPT_LICENSE_CACHE_FILE="${AUTOSCRIPT_LICENSE_CACHE_FILE}" \
  AUTOSCRIPT_LICENSE_STOPPED_SERVICES_FILE="${AUTOSCRIPT_LICENSE_STOPPED_SERVICES_FILE}" \
  python3 "${license_bin}" "$@"
}

autoscript_license_setup_preflight() {
  if ! autoscript_license_enabled; then
    ui_subtle "License guard: nonaktif (URL lisensi tidak tersedia)"
    return 0
  fi

  ok "Validasi lisensi IP VPS..."
  autoscript_license_exec_repo_bin check --stage setup --allow-disabled=false
}
