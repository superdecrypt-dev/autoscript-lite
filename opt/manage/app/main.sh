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
      warn "Hidden bulk refresh ACCOUNT INFO dinonaktifkan."
      warn "Gunakan menu Domain Control > Refresh Account Info."
      return 1
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
