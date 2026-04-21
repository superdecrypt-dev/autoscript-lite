#!/usr/bin/env bash

main() {
  local action="${1:-}"
  need_root
  if ! manage_license_guard_preflight "${action}"; then
    return 1
  fi
  init_runtime_dirs
  ensure_account_quota_dirs

  case "${action}" in
    __refresh-account-info)
      local refresh_domain="${2:-}"
      local refresh_ip="${3:-}"
      [[ -n "${refresh_domain}" ]] || refresh_domain="$(normalize_domain_token "$(detect_domain)")"
      [[ -n "${refresh_ip}" ]] || refresh_ip="$(normalize_ip_token "$(detect_public_ip_ipapi 2>/dev/null || detect_public_ip 2>/dev/null || true)")"
      [[ -n "${refresh_domain}" ]] || die "Domain aktif tidak terdeteksi untuk bulk refresh ACCOUNT INFO."
      USER_DATA_MUTATION_LOCK_HELD=1 domain_control_refresh_account_info_batches_run "${refresh_domain}" "${refresh_ip}" "all" "10"
      account_info_domain_sync_state_write "${refresh_domain}" >/dev/null 2>&1 || true
      printf '[manage][OK] ACCOUNT INFO direfresh untuk domain: %s\n' "${refresh_domain}"
      return 0
      ;;
    __sync-domain-file)
      warn "Hidden sync domain state dinonaktifkan."
      warn "Sinkronisasi domain state hanya dikelola internal oleh flow Set Domain."
      return 1
      ;;
  esac

  if [[ -n "${action}" ]]; then
    manage_router_dispatch "${action}" "${@:2}"
    return $?
  fi

  main_menu
}
