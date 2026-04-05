#!/usr/bin/env bash
# shellcheck shell=bash

daemon_log_tail_show() {
  # args: service_name [lines]
  local svc="$1"
  local lines="${2:-20}"
  title
  echo "11) Maintenance > Log ${svc}"
  hr
  if svc_exists "${svc}"; then
    journalctl -u "${svc}" --no-pager -n "${lines}" 2>/dev/null || true
  else
    warn "${svc}.service tidak terpasang"
  fi
  hr
  pause
}
