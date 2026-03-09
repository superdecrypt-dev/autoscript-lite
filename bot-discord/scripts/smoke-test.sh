#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd -P)"

resolve_env_file() {
  local candidate

  for candidate in "${BOT_ENV_FILE:-}" "${DISCORD_ENV_FILE:-}"; do
    if [[ -n "${candidate}" && -f "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return
    fi
  done

  if command -v systemctl >/dev/null 2>&1; then
    candidate="$(systemctl cat xray-discord-gateway 2>/dev/null | awk '
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

  for candidate in "/etc/xray-discord-bot/bot.env" "${BASE_DIR}/.env"; do
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
      echo "BACKEND_PORT tidak valid: ${port}" >&2
      exit 1
    fi
    derived="http://$(format_host_for_url "${host}"):${port}"
    if [[ -n "${raw_base}" && "${raw_base%/}" != "${derived}" ]]; then
      echo "BACKEND_BASE_URL tidak sinkron dengan BACKEND_HOST/BACKEND_PORT." >&2
      exit 1
    fi
    printf '%s\n' "${derived}"
    return
  fi

  printf '%s\n' "${raw_base:-http://127.0.0.1:${default_port}}"
}

BACKEND_BASE_URL="$(resolve_backend_base_url 8080)"
INTERNAL_SHARED_SECRET="${INTERNAL_SHARED_SECRET:-}"

if [[ -z "${INTERNAL_SHARED_SECRET}" ]]; then
  echo "INTERNAL_SHARED_SECRET kosong. isi dulu di env runtime bot."
  exit 1
fi

echo "== health =="
curl -fsS "${BACKEND_BASE_URL}/health" \
  -H "X-Internal-Shared-Secret: ${INTERNAL_SHARED_SECRET}" | sed 's/.*/&/'

echo
echo "== menu 1 overview =="
curl -fsS -X POST "${BACKEND_BASE_URL}/api/menu/1/action" \
  -H "Content-Type: application/json" \
  -H "X-Internal-Shared-Secret: ${INTERNAL_SHARED_SECRET}" \
  -d '{"action":"overview","params":{}}' | sed 's/.*/&/'
