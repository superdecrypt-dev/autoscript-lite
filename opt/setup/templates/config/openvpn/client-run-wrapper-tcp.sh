#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROFILE_FILE="${SCRIPT_DIR}/__PROFILE_FILE__"
RUNTIME_PROFILE="${SCRIPT_DIR}/__RUNTIME_PROFILE_FILE__"
TUN_DEVICE="__TUN_DEVICE__"

cleanup_tun_state() {
  if command -v ip >/dev/null 2>&1; then
    ip route flush dev "${TUN_DEVICE}" >/dev/null 2>&1 || true
    ip addr flush dev "${TUN_DEVICE}" >/dev/null 2>&1 || true
    ip link set "${TUN_DEVICE}" down >/dev/null 2>&1 || true
    ip link delete "${TUN_DEVICE}" >/dev/null 2>&1 || true
  fi
}

cleanup() {
  cleanup_tun_state
  rm -f "${RUNTIME_PROFILE}" >/dev/null 2>&1 || true
}

trap cleanup EXIT INT TERM

for arg in "$@"; do
  if [[ "${arg}" == "--daemon" ]]; then
    echo "Launcher TCP ini harus dijalankan foreground tanpa --daemon." >&2
    echo "Gunakan nohup/systemd luar jika ingin background, tetapi wrapper harus tetap hidup untuk cleanup." >&2
    exit 1
  fi
done

[[ -f "${PROFILE_FILE}" ]] || {
  echo "Profile TCP tidak ditemukan: ${PROFILE_FILE}" >&2
  exit 1
}

cleanup_tun_state

python3 - "${PROFILE_FILE}" "${RUNTIME_PROFILE}" "${TUN_DEVICE}" <<'PY'
import sys
from pathlib import Path

src, dst, tun_device = sys.argv[1:4]
lines = Path(src).read_text(encoding="utf-8").splitlines()
out = []
dev_rewritten = False
for line in lines:
  stripped = line.strip()
  if stripped == "dev tun" and not dev_rewritten:
    out.append("dev-type tun")
    out.append(f"dev {tun_device}")
    dev_rewritten = True
    continue
  if stripped in {"persist-key", "persist-tun"}:
    continue
  out.append(line)
if not dev_rewritten:
  out.insert(0, f"dev {tun_device}")
  out.insert(0, "dev-type tun")
Path(dst).write_text("\n".join(out) + "\n", encoding="utf-8")
PY

openvpn --config "${RUNTIME_PROFILE}" "$@" &
child_pid=$!
wait "${child_pid}"
