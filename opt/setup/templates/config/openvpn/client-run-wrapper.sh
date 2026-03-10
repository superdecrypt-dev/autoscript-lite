#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
HELPER_FILE="${SCRIPT_DIR}/__HELPER_FILE__"
PROFILE_FILE="${SCRIPT_DIR}/__PROFILE_FILE__"
HELPER_LOG="${SCRIPT_DIR}/__HELPER_LOG__"
HELPER_PID="${SCRIPT_DIR}/__HELPER_PID__"

cleanup() {
  if [[ -f "${HELPER_PID}" ]]; then
    kill "$(cat "${HELPER_PID}")" >/dev/null 2>&1 || true
    rm -f "${HELPER_PID}" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT INT TERM

for arg in "$@"; do
  if [[ "${arg}" == "--daemon" ]]; then
    echo "Launcher ini harus dijalankan foreground tanpa --daemon." >&2
    echo "Gunakan nohup/systemd luar jika ingin background, tetapi helper harus tetap hidup." >&2
    exit 1
  fi
done

python3 "${HELPER_FILE}" >"${HELPER_LOG}" 2>&1 &
echo $! > "${HELPER_PID}"
sleep 1
exec openvpn --config "${PROFILE_FILE}" "$@"
