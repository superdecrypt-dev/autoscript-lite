#!/usr/bin/env bash
# Post-install sanity check module for setup runtime.
# This module verifies that all services are active and listeners are up.

sanity_check() {
  local failed=0
  local edge_provider edge_active edge_runtime_service warp_runtime_mode
  edge_provider="${EDGE_PROVIDER:-none}"
  edge_active="${EDGE_ACTIVATE_RUNTIME:-false}"
  warp_runtime_mode="$(cloudflare_warp_mode_state_get 2>/dev/null || true)"

  listener_present_tcp() {
    local pattern="$1"
    ss -lntp 2>/dev/null | grep -Eq "${pattern}"
  }

  wait_for_listener() {
    local checker="$1"
    local target="$2"
    local tries="${3:-5}"
    local delay="${4:-1}"
    local i
    for ((i = 0; i < tries; i++)); do
      if "${checker}" "${target}"; then
        return 0
      fi
      sleep "${delay}"
    done
    return 1
  }

  # Core services (must be active)
  if systemctl is-active --quiet xray; then
    ok "check: xray active"
  else
    warn "check: xray inactive"
    systemctl status xray --no-pager >&2 || true
    journalctl -u xray -n 200 --no-pager >&2 || true
    failed=1
  fi

  if systemctl is-active --quiet nginx; then
    ok "check: nginx active"
  else
    warn "check: nginx inactive"
    systemctl status nginx --no-pager >&2 || true
    journalctl -u nginx -n 200 --no-pager >&2 || true
    failed=1
  fi

  if [[ "${warp_runtime_mode}" == "zerotrust" ]]; then
    if systemctl is-active --quiet wireproxy; then
      warn "check: wireproxy active saat mode Zero Trust"
      warn "check: wireproxy seharusnya idle ketika backend Zero Trust menjadi runtime aktif."
    else
      ok "check: wireproxy idle (Zero Trust runtime)"
    fi
  elif systemctl is-active --quiet wireproxy; then
    ok "check: wireproxy active"
  else
    warn "check: wireproxy inactive"
    systemctl status wireproxy --no-pager >&2 || true
    journalctl -u wireproxy -n 120 --no-pager >&2 || true
    failed=1
  fi

  if command -v warp-cli >/dev/null 2>&1 || systemctl list-unit-files "${WARP_ZEROTRUST_SERVICE}" >/dev/null 2>&1; then
    ok "check: Zero Trust backend tersedia (cloudflare-warp)"
    if [[ "${warp_runtime_mode}" == "zerotrust" ]]; then
      if systemctl is-active --quiet "${WARP_ZEROTRUST_SERVICE}"; then
        ok "check: ${WARP_ZEROTRUST_SERVICE} active (Zero Trust runtime)"
      else
        warn "check: ${WARP_ZEROTRUST_SERVICE} inactive pada mode Zero Trust"
        systemctl status "${WARP_ZEROTRUST_SERVICE}" --no-pager >&2 || true
        journalctl -u "${WARP_ZEROTRUST_SERVICE}" -n 120 --no-pager >&2 || true
        failed=1
      fi
    elif systemctl is-active --quiet "${WARP_ZEROTRUST_SERVICE}"; then
      warn "check: ${WARP_ZEROTRUST_SERVICE} active"
      warn "check: backend Zero Trust aktif; pastikan ini memang state runtime yang diinginkan."
    else
      ok "check: ${WARP_ZEROTRUST_SERVICE} idle"
    fi
  else
    warn "check: Zero Trust backend belum terpasang (opsional)"
  fi

  local adblock_dns_service="${ADBLOCK_DNS_SERVICE:-adblock-dns.service}"
  if systemctl is-active --quiet "${adblock_dns_service}"; then
    ok "check: dns adblock active"
  else
    warn "check: dns adblock inactive"
    systemctl status "${adblock_dns_service}" --no-pager >&2 || true
    journalctl -u "${adblock_dns_service}" -n 120 --no-pager >&2 || true
    failed=1
  fi

  if systemctl is-active --quiet xray-domain-guard.timer; then
    ok "check: domain guard timer active"
  else
    warn "check: domain guard timer inactive"
    systemctl status xray-domain-guard.timer --no-pager >&2 || true
    journalctl -u xray-domain-guard.timer -n 120 --no-pager >&2 || true
    failed=1
  fi

  if systemctl is-active --quiet "${ACCOUNT_PORTAL_SERVICE}.service"; then
    ok "check: account portal active"
  else
    warn "check: account portal inactive"
    systemctl status "${ACCOUNT_PORTAL_SERVICE}.service" --no-pager >&2 || true
    journalctl -u "${ACCOUNT_PORTAL_SERVICE}.service" -n 120 --no-pager >&2 || true
    failed=1
  fi

  if [[ "${edge_provider}" != "none" ]]; then
    case "${edge_provider}" in
      nginx-stream) edge_runtime_service="nginx" ;;
      *) edge_runtime_service="edge-mux.service" ;;
    esac
    case "${edge_active}" in
      1|true|TRUE|yes|YES|on|ON)
        if systemctl is-active --quiet "${edge_runtime_service}"; then
          ok "check: ${edge_runtime_service} active"
        else
          warn "check: ${edge_runtime_service} inactive"
          systemctl status "${edge_runtime_service}" --no-pager >&2 || true
          journalctl -u "${edge_runtime_service}" -n 120 --no-pager >&2 || true
          failed=1
        fi
        ;;
    esac
  fi

  # Config sanity (non-fatal if tools missing)
  if command -v nginx >/dev/null 2>&1; then
    if nginx -t >/dev/null 2>&1; then
      ok "check: nginx -t OK"
    else
      warn "check: nginx -t failed"
      nginx -t >&2 || true
      failed=1
    fi
  fi

  if command -v jq >/dev/null 2>&1 && [[ -f "${XRAY_CONFDIR}/10-inbounds.json" ]]; then
    if jq -e . "${XRAY_CONFDIR}/10-inbounds.json" >/dev/null 2>&1; then
      ok "check: xray config OK"
    else
      warn "check: xray config invalid"
      jq -e . "${XRAY_CONFDIR}/10-inbounds.json" >&2 || true
      failed=1
    fi
  fi

  # Cert presence (TLS termination depends on these)
  if [[ -s "/opt/cert/fullchain.pem" && -s "/opt/cert/privkey.pem" ]]; then
    ok "check: cert files present"
  else
    warn "check: cert files missing"
    failed=1
  fi

  # Listener hints (informational only)
  # Match exact port agar tidak false-positive ke :4430 dst.
  if wait_for_listener listener_present_tcp '(^|[[:space:]])[^[:space:]]*:80([[:space:]]|$)' 5 1; then
    ok "check: port 80 listening"
  else
    warn "check: port 80 not listening"
  fi

  if wait_for_listener listener_present_tcp '(^|[[:space:]])[^[:space:]]*:443([[:space:]]|$)' 5 1; then
    ok "check: port 443 listening"
  else
    warn "check: port 443 not listening"
  fi

  if [[ "$failed" -ne 0 ]]; then
    die "Sanity check gagal. Lihat log di atas."
  fi
}
