#!/usr/bin/env bash
# Shared Autoscript license guard helpers for setup runtime.

autoscript_license_enabled() {
  [[ -n "${AUTOSCRIPT_LICENSE_API_URL:-}" ]]
}

autoscript_license_runtime_enforce_enabled() {
  local raw="${AUTOSCRIPT_LICENSE_RUNTIME_ENFORCE:-true}"
  raw="$(printf '%s' "${raw}" | tr '[:upper:]' '[:lower:]')"
  [[ "${raw}" == "1" || "${raw}" == "true" || "${raw}" == "yes" || "${raw}" == "on" ]]
}

autoscript_license_repo_bin_path() {
  printf '%s\n' "${SETUP_BIN_SRC_DIR}/autoscript-license-check"
}

autoscript_license_exec_repo_bin() {
  local license_bin=""
  license_bin="$(autoscript_license_repo_bin_path)"
  [[ -x "${license_bin}" ]] || die "Binary source autoscript-license-check tidak ditemukan: ${license_bin}"
  AUTOSCRIPT_LICENSE_API_URL="${AUTOSCRIPT_LICENSE_API_URL:-}" \
  AUTOSCRIPT_LICENSE_API_TOKEN="${AUTOSCRIPT_LICENSE_API_TOKEN:-}" \
  AUTOSCRIPT_LICENSE_CACHE_TTL_SEC="${AUTOSCRIPT_LICENSE_CACHE_TTL_SEC:-86400}" \
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
    ui_subtle "License guard: nonaktif (AUTOSCRIPT_LICENSE_API_URL belum di-set)"
    return 0
  fi

  ok "Validasi lisensi IP VPS..."
  autoscript_license_exec_repo_bin check --stage setup --allow-disabled=false
}
