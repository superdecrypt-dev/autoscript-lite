#!/usr/bin/env bash
set -euo pipefail

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[rotate-token] ERROR: command tidak ditemukan: $1" >&2
    exit 1
  }
}

list_env_files() {
  local candidate

  for candidate in "${BOT_ENV_FILE:-}" "${DISCORD_ENV_FILE:-}"; do
    [[ -n "${candidate}" ]] && printf '%s\n' "${candidate}"
  done

  if command -v systemctl >/dev/null 2>&1; then
    systemctl cat xray-discord-gateway 2>/dev/null | awk '
      /^[[:space:]]*EnvironmentFile=/ {
        value = substr($0, index($0, "=") + 1)
        sub(/^-/, "", value)
        if (value != "") print value
      }
    '
  fi

  printf '%s\n' "/etc/xray-discord-bot/bot.env"
}

is_probably_discord_token() {
  local token="$1"
  # Format umum token bot Discord: base64-ish '.' base64-ish '.' base64-ish
  [[ "${token}" =~ ^[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{6,}\.[A-Za-z0-9_\-]{20,}$ ]]
}

upsert_env_key() {
  local file="$1"
  local key="$2"
  local value="$3"

  [[ -f "${file}" ]] || return 0

  if grep -qE "^${key}=" "${file}"; then
    sed -i -E "s|^${key}=.*$|${key}=${value}|g" "${file}"
  else
    printf '%s=%s\n' "${key}" "${value}" >>"${file}"
  fi

  chmod 600 "${file}" || true
}

main() {
  need_cmd sed
  need_cmd systemctl

  local token="${1:-}"
  if [[ -z "${token}" ]]; then
    read -r -s -p "Masukkan DISCORD_BOT_TOKEN baru: " token
    echo
    read -r -s -p "Ulangi DISCORD_BOT_TOKEN baru: " token2
    echo
    [[ "${token}" == "${token2}" ]] || {
      echo "[rotate-token] ERROR: token konfirmasi tidak sama." >&2
      exit 1
    }
  fi

  if ! is_probably_discord_token "${token}"; then
    echo "[rotate-token] ERROR: format token terlihat tidak valid." >&2
    exit 1
  fi

  local found=0
  local f
  while IFS= read -r f; do
    if [[ -f "${f}" ]]; then
      upsert_env_key "${f}" "DISCORD_BOT_TOKEN" "${token}"
      echo "[rotate-token] updated: ${f}"
      found=1
    fi
  done < <(list_env_files)

  (( found == 1 )) || {
    echo "[rotate-token] ERROR: env file tidak ditemukan." >&2
    exit 1
  }

  systemctl restart xray-discord-gateway
  sleep 2
  systemctl show xray-discord-gateway -p ActiveState -p SubState -p NRestarts --no-pager
  echo "[rotate-token] selesai."
}

main "$@"
