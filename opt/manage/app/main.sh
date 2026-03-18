#!/usr/bin/env bash

main() {
  need_root
  init_runtime_dirs
  ensure_account_quota_dirs

  case "${1:-}" in
    __apply-ssh-network)
      if ! declare -F ssh_network_runtime_apply_now >/dev/null 2>&1; then
        warn "Hidden apply SSH Network tidak tersedia."
        return 1
      fi
      if ! ssh_network_runtime_apply_now; then
        warn "Apply runtime SSH Network gagal."
        return 1
      fi
      return 0
      ;;
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
