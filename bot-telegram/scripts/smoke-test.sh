#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd -P)"
BACKEND_SERVICE="${BACKEND_SERVICE:-bot-telegram-backend}"
GATEWAY_SERVICE="${GATEWAY_SERVICE:-bot-telegram-gateway}"
BACKEND_HOST="${BACKEND_HOST:-}"
BACKEND_PORT="${BACKEND_PORT:-}"
SECRET="${INTERNAL_SHARED_SECRET:-}"

resolve_env_file() {
  local candidate

  for candidate in "${BOT_ENV_FILE:-}" "${TELEGRAM_ENV_FILE:-}"; do
    if [[ -n "${candidate}" && -f "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return
    fi
  done

  if command -v systemctl >/dev/null 2>&1; then
    candidate="$(systemctl cat bot-telegram-gateway 2>/dev/null | awk '
      /^[[:space:]]*EnvironmentFile=/ {
        value = substr($0, index($0, "=") + 1)
        sub(/^-/, "", value)
        if (value != "") print value
      }
    ' | tail -n1)"
    if [[ -n "${candidate}" && -f "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return
    fi
  fi

  for candidate in "/etc/bot-telegram/bot.env" "${BASE_DIR}/.env"; do
    if [[ -f "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return
    fi
  done
}

ENV_FILE="$(resolve_env_file || true)"

if [[ -n "${ENV_FILE}" && -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
fi

SECRET="${INTERNAL_SHARED_SECRET:-}"

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
      echo "[smoke] BACKEND_PORT tidak valid: ${port}" >&2
      exit 1
    fi
    derived="http://$(format_host_for_url "${host}"):${port}"
    if [[ -n "${raw_base}" && "${raw_base%/}" != "${derived}" ]]; then
      echo "[smoke] BACKEND_BASE_URL tidak sinkron dengan BACKEND_HOST/BACKEND_PORT." >&2
      exit 1
    fi
    printf '%s\n' "${derived}"
    return
  fi

  printf '%s\n' "${raw_base:-http://127.0.0.1:${default_port}}"
}

BACKEND_BASE_URL="$(resolve_backend_base_url 8081)"

if [[ -z "${SECRET}" ]]; then
  echo "[smoke] INTERNAL_SHARED_SECRET belum diset" >&2
  exit 1
fi

wait_backend_endpoint() {
  local label="$1"
  local endpoint="$2"
  local attempts="${3:-30}"

  for _ in $(seq 1 "${attempts}"); do
    if curl -fsS --max-time 8 -H "X-Internal-Shared-Secret: ${SECRET}" "${BACKEND_BASE_URL%/}${endpoint}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  echo "[smoke] timeout menunggu ${label}: ${BACKEND_BASE_URL%/}${endpoint}" >&2
  return 1
}

echo "[smoke] service state"
systemctl is-active "${BACKEND_SERVICE}" || true
systemctl is-active "${GATEWAY_SERVICE}" || true

echo "[smoke] backend health"
wait_backend_endpoint "backend health" "/health"
curl -fsS --max-time 8 -H "X-Internal-Shared-Secret: ${SECRET}" "${BACKEND_BASE_URL%/}/health"

echo "[smoke] auth guard + menu endpoint"
wait_backend_endpoint "backend main-menu" "/api/main-menu"
curl -fsS --max-time 8 -H "X-Internal-Shared-Secret: ${SECRET}" "${BACKEND_BASE_URL%/}/api/main-menu" >/dev/null

echo "[smoke] PASS"
