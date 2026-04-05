#!/usr/bin/env bash
set -euo pipefail

BADVPN_BIN="${1:-/usr/local/bin/badvpn-udpgw}"
RUNTIME_ENV_FILE="${2:-/etc/default/badvpn-udpgw}"

[[ -x "${BADVPN_BIN}" ]] || {
  echo "badvpn binary not executable: ${BADVPN_BIN}" >&2
  exit 1
}

if [[ -f "${RUNTIME_ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${RUNTIME_ENV_FILE}"
fi

PORTS_RAW="${BADVPN_UDPGW_PORTS:-7300 7400 7500 7600 7700 7800 7900}"
MAX_CLIENTS="${BADVPN_UDPGW_MAX_CLIENTS:-512}"
MAX_CONN_PER_CLIENT="${BADVPN_UDPGW_MAX_CONNECTIONS_FOR_CLIENT:-8}"
BUFFER_SIZE="${BADVPN_UDPGW_BUFFER_SIZE:-1048576}"
PORTS_RAW="${PORTS_RAW//,/ }"
read -r -a PORTS <<< "${PORTS_RAW}"
if (( ${#PORTS[@]} == 0 )); then
  echo "invalid BADVPN_UDPGW_PORTS: empty" >&2
  exit 1
fi

declare -A seen_ports=()
for port in "${PORTS[@]}"; do
  case "${port}" in
    ''|*[!0-9]*) echo "invalid BADVPN_UDPGW_PORTS entry: ${port}" >&2; exit 1 ;;
  esac
  if (( port <= 0 )); then
    echo "invalid badvpn port: ${port}" >&2
    exit 1
  fi
  if [[ -n "${seen_ports[${port}]:-}" ]]; then
    continue
  fi
  seen_ports["${port}"]=1
done

pids=()

cleanup() {
  local pid
  for pid in "${pids[@]:-}"; do
    kill "${pid}" >/dev/null 2>&1 || true
  done
  wait >/dev/null 2>&1 || true
}

trap cleanup EXIT INT TERM

for port in "${PORTS[@]}"; do
  "${BADVPN_BIN}" \
    --listen-addr "127.0.0.1:${port}" \
    --max-clients "${MAX_CLIENTS}" \
    --max-connections-for-client "${MAX_CONN_PER_CLIENT}" \
    --client-socket-sndbuf "${BUFFER_SIZE}" &
  pids+=("$!")
done

wait -n "${pids[@]}"
exit 1
