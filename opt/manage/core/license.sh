#!/usr/bin/env bash
# shellcheck shell=bash

manage_license_config_get() {
  local key="$1"
  local env_file="${AUTOSCRIPT_LICENSE_CONFIG_FILE:-/etc/autoscript/license/config.env}"
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

manage_license_guard_enabled() {
  local api_url="${AUTOSCRIPT_LICENSE_API_URL:-}"
  if [[ -z "${api_url}" ]]; then
    api_url="$(manage_license_config_get AUTOSCRIPT_LICENSE_API_URL 2>/dev/null || true)"
  fi
  [[ -n "${api_url}" ]]
}

manage_license_stage_for_args() {
  local action="${1:-}"
  case "${action}" in
    __apply-ssh-network|__sync-ssh-network-session-targets)
      printf '%s\n' "runtime"
      ;;
    *)
      printf '%s\n' "manage"
      ;;
  esac
}

manage_license_guard_preflight() {
  local action="${1:-}"
  local stage license_bin

  if ! manage_license_guard_enabled; then
    return 0
  fi

  stage="$(manage_license_stage_for_args "${action}")"
  license_bin="${AUTOSCRIPT_LICENSE_BIN:-/usr/local/bin/autoscript-license-check}"

  if [[ ! -x "${license_bin}" ]]; then
    echo "manage: binary license guard tidak ditemukan: ${license_bin}" >&2
    return 1
  fi
  if declare -F manage_bootstrap_path_trusted >/dev/null 2>&1 && ! manage_bootstrap_path_trusted "${license_bin}"; then
    echo "manage: binary license guard tidak trusted: ${license_bin}" >&2
    return 1
  fi

  if ! "${license_bin}" check --stage "${stage}" --allow-disabled=true; then
    echo "manage: akses ${stage} ditolak oleh license guard." >&2
    return 1
  fi
  return 0
}
