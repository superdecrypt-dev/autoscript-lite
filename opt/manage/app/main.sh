#!/usr/bin/env bash

main() {
  need_root
  init_runtime_dirs
  sync_xray_domain_file "$(detect_domain)" >/dev/null 2>&1 || true
  ensure_account_quota_dirs
  quota_migrate_dates_to_dateonly

  case "${1:-}" in
    __refresh-account-info)
      shift
      local refresh_domain="${1:-}"
      local refresh_ip="${2:-}"
      [[ -n "${refresh_domain}" ]] || refresh_domain="$(detect_domain)"
      if account_refresh_all_info_files "${refresh_domain}" "${refresh_ip}"; then
        account_info_domain_sync_state_write "${refresh_domain}"
        return 0
      fi
      return 1
      ;;
  esac

  account_info_sync_after_domain_change_if_needed || true
  account_info_compat_refresh_if_needed || true
  main_menu
}
