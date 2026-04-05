#!/usr/bin/env bash

main() {
  need_root
  if ! manage_license_guard_preflight "${1:-}"; then
    return 1
  fi
  init_runtime_dirs
  ensure_account_quota_dirs

  case "${1:-}" in
    __refresh-account-info)
      warn "Hidden bulk refresh ACCOUNT INFO dinonaktifkan."
      warn "Gunakan menu Domain Control > Refresh Account Info."
      return 1
      ;;
    __sync-domain-file)
      warn "Hidden sync compat domain dinonaktifkan."
      warn "Sinkronisasi compat domain hanya dikelola internal oleh flow Set Domain."
      return 1
      ;;
  esac

  main_menu
}
