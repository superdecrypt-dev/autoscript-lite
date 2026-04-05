#!/usr/bin/env bash
# shellcheck shell=bash

  local ctx="${1:-}"
  shift || true
  "$@"
  local rc=$?
  return "${rc}"
}

  local suffix="${1:-}"
  local base="11) Maintenance"
    maintenance|"") base="11) Maintenance" ;;
  esac
  if [[ -n "${suffix}" ]]; then
    printf '%s > %s\n' "${base}" "${suffix}"
  else
    printf '%s\n' "${base}"
  fi
}

}

  local key="${1:-}"
  local default_value="${2:-}"
  local env_file
  [[ -n "${key}" ]] || {
    printf '%s\n' "${default_value}"
    return 0
  }
  if [[ -r "${env_file}" ]]; then
    local value
    value="$(awk -F= -v k="${key}" '$1==k {print substr($0, index($0, "=")+1); exit}' "${env_file}" | tr -d '\r' || true)"
    if [[ -n "${value}" ]]; then
      printf '%s\n' "${value}"
      return 0
    fi
  fi
  printf '%s\n' "${default_value}"
}

  title
  else
  fi
  hr

  local svc
  for svc in "${services[@]}"; do
    if svc_exists "${svc}"; then
      svc_status_line "${svc}"
    else
      warn "${svc}.service tidak terpasang"
    fi
  done

  hr
  if have_cmd ss; then
    if ss -lntp 2>/dev/null | grep -Eq '(^|[[:space:]])[^[:space:]]*:80([[:space:]]|$)'; then
      log "Port 80   : LISTENING ✅"
    else
      warn "Port 80   : NOT listening ❌"
    fi
    if ss -lntp 2>/dev/null | grep -Eq '(^|[[:space:]])[^[:space:]]*:443([[:space:]]|$)'; then
      log "Port 443  : LISTENING ✅"
    else
      warn "Port 443  : NOT listening ❌"
    fi
  else
    warn "ss tidak tersedia, skip cek port 80/443"
  fi

  hr
  local runtime_env runtime_stale_sec runtime_handshake_timeout
  echo "Internal ports (detected):"
  echo "  - ws proxy local : 127.0.0.1:${proxy_port}"
  echo "Runtime env:"
  echo "  - env file       : ${runtime_env}"
  echo "  - stale sec      : ${runtime_stale_sec}"
  echo "  - handshake sec  : ${runtime_handshake_timeout}"
  hr
  pause
}

  local -a failed=()

  if have_cmd ss; then
      failed+=("port-80")
    fi
      failed+=("port-443")
    fi
  fi
    fi
  fi
  if svc_exists "${proxy_svc}"; then
      failed+=("ws-proxy")
    fi
  fi
    fi
  fi
  if (( ${#failed[@]} > 0 )); then
    return 1
  fi
  return 0
}

  local services=("$@")
  local svc restarted="false"
  local -a failed=()

  for svc in "${services[@]}"; do
    [[ -n "${svc}" ]] || continue
    if svc_exists "${svc}"; then
      if svc_restart_checked "${svc}" 60; then
        restarted="true"
      else
        failed+=("${svc}")
      fi
    else
      warn "${svc}.service tidak terpasang"
    fi
  done

  if [[ "${restarted}" != "true" ]]; then
    return 1
  fi
  if (( ${#failed[@]} > 0 )); then
    return 1
  fi
  return 0
}

  title
  else
  fi
  hr

  local confirm_rc=0
  confirm_rc=$?
  if (( confirm_rc != 0 )); then
    if (( confirm_rc == 2 )); then
    else
    fi
    hr
    pause
    return 0
  fi

  fi
  hr
  pause
}

  # args: host port mode(tcp|tls)
  local host="${1:-127.0.0.1}"
  local port="${2:-0}"
  local mode="${3:-tcp}"
  need_python3
  python3 - <<'PY' "${host}" "${port}" "${mode}" 2>/dev/null || true
import socket
import ssl
import sys
import base64
import os

host, port_s, mode = sys.argv[1:4]
try:
  port = int(port_s)
except Exception:
  print("fail|invalid-port")
  raise SystemExit(0)

timeout = 2.0
sock = None
try:
  raw = socket.create_connection((host, port), timeout=timeout)
  if mode == "tls":
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    sock = ctx.wrap_socket(raw, server_hostname=host or "localhost")
  else:
    sock = raw
  print("ok|connected")
except Exception as exc:
  msg = str(exc).strip().replace("\n", " ")
  print("fail|" + (msg or exc.__class__.__name__.lower()))
finally:
  try:
    if sock is not None:
      sock.close()
  except Exception:
    pass
PY
}

  # args: host port path host_header tls_mode sni
  local host="${1:-127.0.0.1}"
  local port="${2:-0}"
  local path="${3:-/}"
  local host_header="${4:-127.0.0.1}"
  local tls_mode="${5:-off}"
  local sni="${6:-}"
  need_python3
  python3 - <<'PY' "${host}" "${port}" "${path}" "${host_header}" "${tls_mode}" "${sni}" 2>/dev/null || true
import base64
import os
import socket
import ssl
import sys

host, port_s, path, host_header, tls_mode, sni = sys.argv[1:7]
try:
  port = int(port_s)
except Exception:
  print("fail|invalid-port")
  raise SystemExit(0)

raw = None
sock = None
try:
  raw = socket.create_connection((host, port), timeout=3.0)
  raw.settimeout(3.0)
  if tls_mode == "on":
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    sock = ctx.wrap_socket(raw, server_hostname=sni or host or "localhost")
  else:
    sock = raw
  req = (
    f"GET {path or '/'} HTTP/1.1\r\n"
    f"Host: {host_header or host}\r\n"
    "Upgrade: websocket\r\n"
    "Connection: Upgrade\r\n"
    "Sec-WebSocket-Version: 13\r\n"
    f"Sec-WebSocket-Key: {base64.b64encode(os.urandom(16)).decode()}\r\n"
    "\r\n"
  ).encode("ascii", "ignore")
  sock.sendall(req)
  buf = b""
  while b"\r\n\r\n" not in buf and len(buf) < 16384:
    chunk = sock.recv(4096)
    if not chunk:
      break
    buf += chunk
  if not buf:
    print("fail|empty-response")
    raise SystemExit(0)
  line = buf.split(b"\r\n", 1)[0].decode("latin1", "replace").strip()
  parts = line.split(None, 2)
  if len(parts) >= 2 and parts[1].isdigit():
    code = int(parts[1])
    reason = parts[2] if len(parts) >= 3 else ""
    print(f"http|{code}|{reason}")
  else:
    print("fail|" + (line or "bad-response"))
except Exception as exc:
  msg = str(exc).strip().replace("\n", " ")
  print("fail|" + (msg or exc.__class__.__name__.lower()))
finally:
  try:
    if sock is not None:
      sock.close()
  except Exception:
    pass
  try:
    if raw is not None and raw is not sock:
      raw.close()
  except Exception:
    pass
PY
}

  local raw="${1:-}"
  local kind part1 part2
  IFS='|' read -r kind part1 part2 <<<"${raw}"
  case "${kind}" in
    ok)
      echo "OK (${part1:-connected})"
      ;;
    http)
      case "${part1:-0}" in
        101) echo "OK (HTTP 101 ${part2:-})" ;;
        301|302|307|308) echo "WARN (HTTP ${part1} ${part2:-redirect})" ;;
        401|403) echo "FAIL (HTTP ${part1} ${part2:-probe-rejected})" ;;
        *) echo "FAIL (HTTP ${part1:-0} ${part2:-})" ;;
      esac
      ;;
    fail)
      echo "FAIL (${part1:-unknown})"
      ;;
    *)
      echo "FAIL (unknown)"
      ;;
  esac
}

  local raw="${1:-}"
  local kind part1
  IFS='|' read -r kind part1 _ <<<"${raw}"
  case "${kind}" in
    ok) return 0 ;;
    http)
      case "${part1:-0}" in
        101|301|302|307|308) return 0 ;;
      esac
      ;;
  esac
  return 1
}

  title
  else
  fi
  hr

  local -a svc_args=()
  local svc
    if svc_exists "${svc}"; then
      svc_args+=(-u "${svc}")
    fi
  done

  if (( ${#svc_args[@]} == 0 )); then
    hr
    pause
    return 0
  fi

  journalctl "${svc_args[@]}" --no-pager -n 120 2>/dev/null || true
  hr
  pause
}

  local choice=""
  while true; do
    title
    else
    fi
    hr

    domain="$(detect_domain)"

    echo "Services:"
    else
    fi
    else
    fi
    else
    fi

    hr
    echo "Internal Ports:"
    printf "  %-16s : 127.0.0.1:%s\n" "ws proxy" "${proxy_port}"
    printf "  %-16s : %s\n" "domain" "${domain:-"-"}"
    printf "  %-16s : %s\n" "probe path" "${probe_path}"

    hr
    echo "Local Probes:"


    else
    fi

    hr
    echo "Public Path Probes:"
    if have_cmd ss && ss -lntp 2>/dev/null | grep -Eq '(^|[[:space:]])[^[:space:]]*:80([[:space:]]|$)'; then
    else
      printf "  %-16s : %s\n" "nginx :80" "SKIP (not listening)"
    fi
    if [[ -n "${domain}" ]] && have_cmd ss && ss -lntp 2>/dev/null | grep -Eq '(^|[[:space:]])[^[:space:]]*:443([[:space:]]|$)'; then
    else
      printf "  %-16s : %s\n" "nginx :443" "SKIP (domain/443 unavailable)"
    fi

    hr
    echo "Notes:"
    echo "  - HTTP 502 biasanya berarti backend internal belum siap."
    echo "  - HTTP 301/308 pada port 80 normal jika force-HTTPS aktif."
    echo "  - HTTP 401/403 berarti probe sintetis ditolak; cek ws-proxy path/auth flow."
    hr
    echo "  1) Refresh"
    echo "  0) Back"
    hr
    if ! read -r -p "Pilih: " choice; then
      echo
      return 0
    fi
    case "${choice}" in
      1|refresh|r) ;;
      0|kembali|k|back|b) return 0 ;;
      *) warn "Pilihan tidak valid" ; sleep 1 ;;
    esac
  done
}

  title
  hr

  local svc
  for svc in "${services[@]}"; do
    if svc_exists "${svc}"; then
      svc_status_line "${svc}"
    else
      warn "${svc}.service tidak terpasang"
    fi
  done

  hr
  local tcp_port public_tcp_port ws_proxy_port ws_public_path ws_alt_path tls_ports http_ports merged_ports=() seen_ports=() port
  [[ -n "${tcp_port}" ]] || tcp_port="1194"
  tls_ports="$(edge_runtime_public_tls_ports 2>/dev/null || echo "443 2053 2083 2087 2096 8443")"
  http_ports="$(edge_runtime_public_http_ports 2>/dev/null || echo "80 8080 8880 2052 2082 2086 2095")"
  for port in ${tls_ports} ${http_ports}; do
    [[ "${port}" =~ ^[0-9]+$ ]] || continue
    if [[ " ${seen_ports[*]:-} " == *" ${port} "* ]]; then
      continue
    fi
    seen_ports+=("${port}")
    merged_ports+=("${port}")
  done
  if (( ${#merged_ports[@]} > 0 )); then
    public_tcp_port="$(printf '%s\n' "${merged_ports[*]}" | sed 's/ /, /g')"
  else
    [[ -n "${public_tcp_port}" ]] || public_tcp_port="${tcp_port}"
  fi
  [[ -n "${ws_proxy_port}" ]] || ws_proxy_port="10016"
  [[ -n "${ws_public_path}" ]] || ws_public_path="-"
  if [[ "${ws_public_path}" != "-" ]]; then
    [[ "${ws_public_path}" == /* ]] || ws_public_path="/${ws_public_path}"
    ws_alt_path="/<bebas>/${ws_public_path#/}"
  else
    ws_alt_path="-"
  fi
  if have_cmd ss; then
    if ss -lntp 2>/dev/null | grep -Eq "(^|[[:space:]])[^[:space:]]*:${tcp_port}([[:space:]]|$)"; then
      log "Backend TCP ${tcp_port} : LISTENING ✅"
    else
      warn "Backend TCP ${tcp_port} : NOT listening ❌"
    fi
    if ss -lntp 2>/dev/null | grep -Eq "(^|[[:space:]])127\\.0\\.0\\.1:${ws_proxy_port}([[:space:]]|$)"; then
      log "WS proxy ${ws_proxy_port} : LISTENING ✅"
    else
      warn "WS proxy ${ws_proxy_port} : NOT listening ❌"
    fi
  fi

  hr
  echo "Runtime:"
  echo "  - public tcp  : ${public_tcp_port} (via edge-mux)"
  echo "  - ws path     : ${ws_public_path}"
  echo "  - ws path alt : ${ws_alt_path}"
  hr
  pause
}

  local svc="${1:-}"
  local should_be_active="${2:-false}"
  [[ -n "${svc}" ]] || return 1
  case "${should_be_active}" in
    true)
      svc_exists "${svc}" || return 0
      if svc_is_active "${svc}"; then
        return 0
      fi
      svc_start_checked "${svc}" 60 >/dev/null 2>&1
      ;;
    false)
      if svc_exists "${svc}" && svc_is_active "${svc}"; then
        svc_stop_checked "${svc}" 60 >/dev/null 2>&1
      else
        return 0
      fi
      ;;
    *)
      return 1
      ;;
  esac
}

  local tcp_port="" ws_proxy_port=""

  if svc_exists "${tcp_svc}" && ! svc_is_active "${tcp_svc}"; then
    warn "${tcp_svc} belum active setelah restart."
    return 1
  fi
  if svc_exists "${ws_svc}" && ! svc_is_active "${ws_svc}"; then
    warn "${ws_svc} belum active setelah restart."
    return 1
  fi

  [[ "${tcp_port}" =~ ^[0-9]+$ ]] || tcp_port="1194"
  [[ "${ws_proxy_port}" =~ ^[0-9]+$ ]] || ws_proxy_port="10016"

  if have_cmd ss; then
    if ! ss -lntp 2>/dev/null | grep -Eq "(^|[[:space:]])[^[:space:]]*:${tcp_port}([[:space:]]|$)"; then
      return 1
    fi
    if ! ss -lntp 2>/dev/null | grep -Eq "(^|[[:space:]])127\\.0\\.0\\.1:${ws_proxy_port}([[:space:]]|$)"; then
      return 1
    fi
  fi
  return 0
}

  title
  hr
  local tcp_was_active="false"
  local ws_was_active="false"
  local -a rollback_notes=()
  local confirm_rc=0
  confirm_rc=$?
  if (( confirm_rc != 0 )); then
    hr
    pause
    return 0
  fi

  if ! svc_exists "${tcp_svc}"; then
    warn "${tcp_svc} tidak ditemukan."
    hr
    pause
    return 0
  fi
  if ! svc_exists "${ws_svc}"; then
    warn "${ws_svc} tidak ditemukan."
    hr
    pause
    return 0
  fi

  if svc_is_active "${tcp_svc}"; then
    tcp_was_active="true"
  fi
  if svc_is_active "${ws_svc}"; then
    ws_was_active="true"
  fi

  if ! svc_restart_checked "${tcp_svc}" 60; then
    warn "Restart ${tcp_svc} gagal."
    hr
    pause
    return 1
  fi
  if ! svc_restart_checked "${ws_svc}" 60; then
    warn "Restart ${ws_svc} gagal."
    if ((${#rollback_notes[@]} > 0)); then
    fi
    hr
    pause
    return 1
  fi
    if ((${#rollback_notes[@]} > 0)); then
    else
    fi
    hr
    pause
    return 1
  fi
  hr
  pause
}

  title
  hr
  echo
  hr
  pause
}
