#!/usr/bin/env bash
set -euo pipefail

SAFE_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
PATH="${SAFE_PATH}"
export PATH

BACKEND_SERVICE="${BACKEND_SERVICE:-xray-discord-backend}"
GATEWAY_SERVICE="${GATEWAY_SERVICE:-xray-discord-gateway}"
BACKEND_HOST="${BACKEND_HOST:-}"
BACKEND_PORT="${BACKEND_PORT:-}"
INTERNAL_SHARED_SECRET="${INTERNAL_SHARED_SECRET:-}"
BOT_STATE_DIR="${BOT_STATE_DIR:-/var/lib/xray-discord-bot}"
BOT_LOG_DIR="${BOT_LOG_DIR:-/var/log/xray-discord-bot}"
BOT_MONITOR_LOG_FILE="${BOT_MONITOR_LOG_FILE:-${BOT_LOG_DIR}/monitor-lite.log}"
BOT_MONITOR_MAX_LINES="${BOT_MONITOR_MAX_LINES:-1000}"
BOT_MONITOR_LOCK_FILE="${BOT_MONITOR_LOCK_FILE:-${BOT_LOG_DIR}/monitor-lite.lock}"

format_host_for_url() {
  local host="$1"
  if [[ "${host}" == *:* && "${host}" != \[*\] ]]; then
    printf '[%s]\n' "${host}"
    return
  fi
  printf '%s\n' "${host}"
}

resolve_backend_base_url() {
  local default_port="$1"
  local raw_base="${BACKEND_BASE_URL:-}"
  local raw_host="${BACKEND_HOST:-}"
  local raw_port="${BACKEND_PORT:-}"

  if [[ -n "${raw_host}" || -n "${raw_port}" ]]; then
    local host="${raw_host:-127.0.0.1}"
    local port="${raw_port:-${default_port}}"
    local derived
    if [[ ! "${port}" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
      echo "[monitor] BACKEND_PORT tidak valid: ${port}" >&2
      exit 1
    fi
    derived="http://$(format_host_for_url "${host}"):${port}"
    if [[ -n "${raw_base}" && "${raw_base%/}" != "${derived}" ]]; then
      echo "[monitor] BACKEND_BASE_URL tidak sinkron dengan BACKEND_HOST/BACKEND_PORT." >&2
      exit 1
    fi
    printf '%s\n' "${derived}"
    return
  fi

  printf '%s\n' "${raw_base:-http://127.0.0.1:${default_port}}"
}

BACKEND_BASE_URL="$(resolve_backend_base_url 8080)"
BACKEND_HEALTH_URL="${BACKEND_HEALTH_URL:-${BACKEND_BASE_URL%/}/health}"

QUIET=0
if [[ "${1:-}" == "-q" || "${1:-}" == "--quiet" ]]; then
  QUIET=1
fi

if command -v flock >/dev/null 2>&1; then
  mkdir -p "${BOT_LOG_DIR}"
  exec 9>"${BOT_MONITOR_LOCK_FILE}"
  flock -n 9 || exit 0
fi

log_line() {
  local line="$1"
  mkdir -p "${BOT_LOG_DIR}"
  printf '%s\n' "${line}" >> "${BOT_MONITOR_LOG_FILE}"

  if [[ "${BOT_MONITOR_MAX_LINES}" =~ ^[0-9]+$ ]] && (( BOT_MONITOR_MAX_LINES > 0 )); then
    local current_lines
    current_lines="$(wc -l < "${BOT_MONITOR_LOG_FILE}" 2>/dev/null || echo 0)"
    if (( current_lines > BOT_MONITOR_MAX_LINES )); then
      tail -n "${BOT_MONITOR_MAX_LINES}" "${BOT_MONITOR_LOG_FILE}" > "${BOT_MONITOR_LOG_FILE}.tmp"
      mv "${BOT_MONITOR_LOG_FILE}.tmp" "${BOT_MONITOR_LOG_FILE}"
    fi
  fi
}

check_service() {
  local unit="$1"
  local state
  state="$(systemctl is-active "${unit}" 2>/dev/null || true)"
  [[ -n "${state}" ]] || state="unknown"
  if [[ "${state}" == "active" ]]; then
    printf '%s\n' "active"
    return 0
  fi
  printf '%s\n' "${state}"
  return 1
}

check_health() {
  local body
  local -a curl_args=(-fsS --max-time 8)
  if [[ -n "${INTERNAL_SHARED_SECRET}" ]]; then
    curl_args+=(-H "X-Internal-Shared-Secret: ${INTERNAL_SHARED_SECRET}")
  fi
  curl_args+=("${BACKEND_HEALTH_URL}")
  body="$(curl "${curl_args[@]}" 2>/dev/null || true)"
  if [[ -n "${body}" ]] && printf '%s' "${body}" | grep -Eq '"status"[[:space:]]*:[[:space:]]*"ok"'; then
    printf '%s\n' "ok"
    return 0
  fi
  printf '%s\n' "fail"
  return 1
}

backend_state="unknown"
gateway_state="unknown"
health_state="unknown"
fail_count=0

if backend_state="$(check_service "${BACKEND_SERVICE}")"; then
  :
else
  fail_count=$((fail_count + 1))
fi

if gateway_state="$(check_service "${GATEWAY_SERVICE}")"; then
  :
else
  fail_count=$((fail_count + 1))
fi

if health_state="$(check_health)"; then
  :
else
  fail_count=$((fail_count + 1))
fi

level="OK"
if (( fail_count > 0 )); then
  level="FAIL"
fi

ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
message="${ts} ${level} backend=${backend_state} gateway=${gateway_state} health=${health_state}"

if (( QUIET == 0 )); then
  echo "${message}"
fi

log_line "${message}"
if command -v logger >/dev/null 2>&1; then
  logger -t xray-discord-monitor "${message}"
fi

if (( fail_count > 0 )); then
  exit 1
fi
exit 0
