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

sshws_restart_after_dropbear() {
  local dropbear_svc="$1"
  local dropbear_port="" dropbear_probe=""
  if ! svc_exists "${dropbear_svc}"; then
    warn "${dropbear_svc}.service tidak terpasang"
    return 1
  fi
  if ! svc_restart_checked "${dropbear_svc}" 60; then
    warn "Restart ${dropbear_svc} gagal."
    return 1
  fi
  dropbear_port="$(sshws_detect_dropbear_port)"
  dropbear_probe="$(sshws_probe_tcp_endpoint "127.0.0.1" "${dropbear_port}" "tcp")"
  if ! sshws_probe_result_is_healthy "${dropbear_probe}"; then
    warn "Probe ${dropbear_svc} gagal setelah restart: $(sshws_probe_result_disp "${dropbear_probe}")"
    return 1
  fi
  return 0
}


