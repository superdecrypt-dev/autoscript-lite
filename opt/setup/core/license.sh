#!/usr/bin/env bash
# Shared Autoscript license guard helpers for setup runtime.

autoscript_license_enabled() {
  local api_url="${AUTOSCRIPT_LICENSE_API_URL:-${AUTOSCRIPT_LICENSE_DEFAULT_API_URL:-}}"
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

autoscript_license_resolve_bin_path() {
  local repo_bin=""
  local installed_bin="${AUTOSCRIPT_LICENSE_BIN:-/usr/local/bin/autoscript-license-check}"

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
  license_bin="$(autoscript_license_resolve_bin_path)"
  AUTOSCRIPT_LICENSE_DEFAULT_API_URL="${AUTOSCRIPT_LICENSE_DEFAULT_API_URL:-}" \
  AUTOSCRIPT_LICENSE_API_URL="${AUTOSCRIPT_LICENSE_API_URL:-}" \
  AUTOSCRIPT_LICENSE_CACHE_TTL_SEC="${AUTOSCRIPT_LICENSE_CACHE_TTL_SEC:-3600}" \
  AUTOSCRIPT_LICENSE_RUNTIME_ENFORCE="${AUTOSCRIPT_LICENSE_RUNTIME_ENFORCE:-true}" \
  AUTOSCRIPT_LICENSE_RUNTIME_INTERVAL_MIN="${AUTOSCRIPT_LICENSE_RUNTIME_INTERVAL_MIN:-15}" \
  AUTOSCRIPT_LICENSE_CONFIG_FILE="${AUTOSCRIPT_LICENSE_CONFIG_FILE}" \
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
