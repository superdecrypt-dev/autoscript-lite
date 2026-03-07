#!/usr/bin/env bash
# Shared helper functions for modular setup runtime.

download_file_or_die() {
  local url="$1"
  local out="$2"
  local expected_sha="${3:-}"
  local label="${4:-$url}"

  if ! download_file_with_sha_check "${url}" "${out}" "${expected_sha}" "${label}"; then
    die "Gagal download/verify: ${label}"
  fi
}

download_file_with_sha_check() {
  local url="$1"
  local out="$2"
  local expected_sha="${3:-}"
  local label="${4:-$url}"
  local actual_sha=""

  if ! curl -fsSL --connect-timeout 15 --max-time 120 "${url}" -o "${out}"; then
    rm -f "${out}" >/dev/null 2>&1 || true
    return 1
  fi
  if [[ ! -s "${out}" ]]; then
    warn "File hasil download kosong: ${label}"
    rm -f "${out}" >/dev/null 2>&1 || true
    return 1
  fi

  if [[ -n "${expected_sha}" ]]; then
    if ! command -v sha256sum >/dev/null 2>&1; then
      warn "sha256sum tidak tersedia untuk verifikasi checksum: ${label}"
      rm -f "${out}" >/dev/null 2>&1 || true
      return 1
    fi
    actual_sha="$(sha256sum "${out}" | awk '{print tolower($1)}')"
    if [[ -z "${actual_sha}" || "${actual_sha}" != "${expected_sha,,}" ]]; then
      warn "Checksum mismatch: ${label}"
      warn "  expected: ${expected_sha,,}"
      warn "  actual  : ${actual_sha:-<empty>}"
      rm -f "${out}" >/dev/null 2>&1 || true
      return 1
    fi
  fi
  return 0
}

rand_str() {
  local n="${1:-16}"
  ( set +o pipefail; tr -dc 'a-z0-9' </dev/urandom | head -c "${n}" )
}

is_port_free() {
  local p="$1"
  ! ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}$"
}

# Registry port yang sudah dipesan dalam sesi ini, disimpan di temp file.
# Wajib pakai temp file karena pick_port dipanggil via $(pick_port) yang
# berjalan di subshell.
_PICK_PORT_REGISTRY="$(mktemp)"

cleanup_pick_port_registry() {
  [[ -n "${_PICK_PORT_REGISTRY:-}" ]] || return 0
  rm -f -- "${_PICK_PORT_REGISTRY}" 2>/dev/null || true
}
register_exit_cleanup cleanup_pick_port_registry

pick_port() {
  local p tries=0
  local reserved
  local max_tries=10000

  while (( tries < max_tries )); do
    p=$(( 20000 + RANDOM % 40000 ))
    for reserved in "${SSHWS_DROPBEAR_PORT}" "${SSHWS_STUNNEL_PORT}" "${SSHWS_PROXY_PORT}"; do
      if [[ "${p}" == "${reserved}" ]]; then
        p=""
        break
      fi
    done
    [[ -n "${p}" ]] || { tries=$((tries + 1)); continue; }
    if is_port_free "${p}" && ! grep -qxF "${p}" "${_PICK_PORT_REGISTRY}" 2>/dev/null; then
      echo "${p}" >> "${_PICK_PORT_REGISTRY}"
      echo "${p}"
      return 0
    fi
    tries=$((tries + 1))
  done

  die "Gagal mendapatkan port kosong setelah ${max_tries} percobaan."
}

install_repo_asset_or_die() {
  local src_rel="$1"
  local dst="$2"
  local mode="${3:-0644}"
  local src="${SCRIPT_DIR}/${src_rel}"
  [[ -f "${src}" ]] || die "Asset repo tidak ditemukan: ${src_rel}"
  mkdir -p "$(dirname "${dst}")"
  install -m "${mode}" "${src}" "${dst}"
  chown root:root "${dst}" 2>/dev/null || true
}

install_setup_bin_or_die() {
  local name="$1"
  local dst="$2"
  local mode="${3:-0755}"
  local src="${SETUP_BIN_SRC_DIR}/${name}"
  [[ -f "${src}" ]] || die "Asset setup bin tidak ditemukan: ${name}"
  mkdir -p "$(dirname "${dst}")"
  install -m "${mode}" "${src}" "${dst}"
  chown root:root "${dst}" 2>/dev/null || true
}

render_setup_template_or_die() {
  local rel="$1"
  local dst="$2"
  local mode="${3:-0644}"
  shift 3
  local src="${SETUP_TEMPLATE_SRC_DIR}/${rel}"
  [[ -f "${src}" ]] || die "Template setup tidak ditemukan: ${rel}"
  command -v python3 >/dev/null 2>&1 || die "python3 dibutuhkan untuk render template setup: ${rel}"
  mkdir -p "$(dirname "${dst}")"
  python3 - "${src}" "${dst}" "${mode}" "$@" <<'PY'
import os
import re
import sys
from pathlib import Path

src, dst, mode, *items = sys.argv[1:]
text = Path(src).read_text(encoding="utf-8")
for item in items:
  key, value = item.split("=", 1)
  text = text.replace(f"__{key}__", value)
missing = sorted(set(re.findall(r"__([A-Z0-9_]+)__", text)))
if missing:
  raise SystemExit(f"template unresolved placeholders in {src}: {', '.join(missing)}")
Path(dst).write_text(text, encoding="utf-8")
os.chmod(dst, int(mode, 8))
PY
  chown root:root "${dst}" 2>/dev/null || true
}

service_enable_restart_checked() {
  local svc="$1"
  systemctl enable "$svc" --now >/dev/null 2>&1 || return 1
  systemctl restart "$svc" >/dev/null 2>&1 || return 1
  systemctl is-active --quiet "$svc" || return 1
  return 0
}

need_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Jalankan sebagai root."
}

ensure_runtime_lock_dirs() {
  install -d -m 700 /run/autoscript /run/autoscript/locks
}

ensure_stdin_available() {
  if [[ ! -t 0 ]]; then
    exec </dev/tty || true
  fi
}

need_python3() {
  if command -v python3 >/dev/null 2>&1; then
    return 0
  fi

  warn "python3 belum terpasang. Memasang python3..."
  export DEBIAN_FRONTEND=noninteractive
  ensure_dpkg_consistent
  apt_get_with_lock_retry update -y
  apt_get_with_lock_retry install -y python3 || die "Gagal memasang python3."
}

confirm_yn() {
  local prompt="${1:-Lanjutkan?}"
  local answer=""
  read -r -p "${prompt} [y/N]: " answer || return 1
  answer="$(echo "${answer}" | tr '[:upper:]' '[:lower:]')"
  [[ "${answer}" == "y" || "${answer}" == "yes" ]]
}
