#!/usr/bin/env bash
# Shared helper functions for modular setup runtime.

download_file_or_die() {
  local url="$1"
  local out="$2"
  local _unused_hint="${3:-}"
  local label="${4:-${_unused_hint:-$url}}"

  if ! download_file_checked "${url}" "${out}" "${label}"; then
    die "Gagal download: ${label}"
  fi
}

download_file_checked() {
  local url="$1"
  local out="$2"
  local label="${3:-$url}"

  if ! curl -fsSL --connect-timeout 15 --max-time 120 "${url}" -o "${out}"; then
    rm -f "${out}" >/dev/null 2>&1 || true
    return 1
  fi
  if [[ ! -s "${out}" ]]; then
    warn "File hasil download kosong: ${label}"
    rm -f "${out}" >/dev/null 2>&1 || true
    return 1
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

sync_tree_atomic() {
  local src="$1"
  local dst="$2"
  local label="${3:-data}"
  local parent base stage backup=""

  [[ -d "${src}" ]] || die "Source ${label} tidak ditemukan: ${src}"
  parent="$(dirname "${dst}")"
  base="$(basename "${dst}")"
  mkdir -p "${parent}"
  stage="$(mktemp -d "${parent}/.${base}.stage.XXXXXX")" || die "Gagal menyiapkan staging ${label}: ${dst}"
  cp -a "${src}/." "${stage}/" || {
    rm -rf "${stage}" >/dev/null 2>&1 || true
    die "Gagal menyalin ${label} ke staging: ${src}"
  }

  if [[ -e "${dst}" ]]; then
    backup="${parent}/.${base}.backup.$(date +%Y%m%d%H%M%S)"
    mv "${dst}" "${backup}" || {
      rm -rf "${stage}" >/dev/null 2>&1 || true
      die "Gagal memindahkan ${label} lama ke backup: ${dst}"
    }
  fi

  if ! mv "${stage}" "${dst}"; then
    rm -rf "${stage}" >/dev/null 2>&1 || true
    if [[ -n "${backup}" && -e "${backup}" ]]; then
      mv "${backup}" "${dst}" >/dev/null 2>&1 || true
    fi
    die "Gagal mengaktifkan ${label} baru: ${dst}"
  fi

  if [[ -n "${backup}" && -e "${backup}" ]]; then
    rm -rf "${backup}" >/dev/null 2>&1 || true
  fi
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

is_container_env() {
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    systemd-detect-virt --quiet --container && return 0
  fi
  [[ -f /.dockerenv ]] && return 0
  grep -qaE '(lxc|docker|containerd|podman)' /proc/1/cgroup 2>/dev/null && return 0
  return 1
}

ensure_runtime_lock_dirs() {
  install -d -m 700 /run/autoscript /run/autoscript/locks
}

ensure_stdin_available() {
  if [[ ! -t 0 ]]; then
    local tty_name=""
    local tty_path=""
    tty_name="$(ps -o tty= -p "$$" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ -n "${tty_name}" && "${tty_name}" != "?" ]]; then
      tty_path="/dev/${tty_name}"
      if [[ -r "${tty_path}" ]]; then
        exec <"${tty_path}" || true
      fi
    fi
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
