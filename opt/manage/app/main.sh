#!/usr/bin/env bash

main() {
  need_root
  init_runtime_dirs
  ensure_account_quota_dirs

  case "${1:-}" in
    __refresh-account-info)
      warn "Hidden bulk refresh ACCOUNT INFO dinonaktifkan."
      warn "Gunakan menu Domain Control > Refresh Account Info."
      return 1
      ;;
    __migrate-quota-dates)
      warn "Hidden migrasi quota dinonaktifkan."
      warn "Gunakan menu Maintenance > Normalize Quota Dates."
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
