#!/usr/bin/env bash
# shellcheck shell=bash

manage_router_dispatch() {
  local action="${1:-}"
  shift || true
  case "${action}" in
    "")
      return 0
      ;;
    user|users|xray-users)
      manage_menu_user_render "$@"
      ;;
    quota|qac|xray-qac)
      quota_menu "$@"
      ;;
    network|xray-network)
      manage_menu_network_render "$@"
      ;;
    domain|domain-control)
      manage_menu_domain_render "$@"
      ;;
    speedtest|speed)
      speedtest_menu "$@"
      ;;
    security)
      fail2ban_menu "$@"
      ;;
    maintenance)
      maintenance_menu "$@"
      ;;
    traffic|analytics)
      traffic_analytics_menu "$@"
      ;;
    tools)
      tools_menu "$@"
      ;;
    backup|restore|backup-restore)
      backup_restore_menu "$@"
      ;;
    telegram-bot)
      install_telegram_bot_menu "$@"
      ;;
    license-guard)
      autoscript_license_status_menu "$@"
      ;;
    *)
      warn "Action manage tidak dikenal: ${action}"
      return 1
      ;;
  esac
}
