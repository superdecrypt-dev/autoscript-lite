#!/usr/bin/env bash
set -euo pipefail

# Harden PATH untuk mencegah PATH hijacking saat script dijalankan sebagai root.
SAFE_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
PATH="${SAFE_PATH}"
export PATH

# ============================================================
# run.sh — Installer otomatis Xray VPN Server
# Repo: https://github.com/superdecrypt-dev/autoscript
# ============================================================

# -------------------------
# Konstanta
# -------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
RUN_USE_LOCAL_SOURCE="${RUN_USE_LOCAL_SOURCE:-0}"
EDGE_PROVIDER="${EDGE_PROVIDER:-go}"
EDGE_ACTIVATE_RUNTIME="${EDGE_ACTIVATE_RUNTIME:-true}"
export EDGE_PROVIDER EDGE_ACTIVATE_RUNTIME
REPO_URL="${REPO_URL:-https://github.com/superdecrypt-dev/autoscript.git}"
REPO_DIR="${REPO_DIR:-/opt/autoscript}"
if [[ "${RUN_USE_LOCAL_SOURCE}" == "1" ]]; then
  REPO_DIR="${SCRIPT_DIR}"
fi
MANAGE_BIN="/usr/local/bin/manage"
MANAGE_MODULES_SRC_DIR="${REPO_DIR}/opt/manage"
MANAGE_MODULES_DST_DIR="/opt/manage"
MANAGE_FALLBACK_MODULES_DST_DIR="/usr/local/lib/autoscript-manage/opt/manage"
BOT_INSTALLER_BIN="/usr/local/bin/install-discord-bot"
TELEGRAM_INSTALLER_BIN="/usr/local/bin/install-telegram-bot"
DISCORD_BOT_HOME="/opt/bot-discord"
DISCORD_BOT_SRC_DIR="${REPO_DIR}/bot-discord"
TELEGRAM_BOT_HOME="/opt/bot-telegram"
TELEGRAM_BOT_SRC_DIR="${REPO_DIR}/bot-telegram"
RUN_FALLBACK_REQUIRED_FILES=(
  "setup.sh"
  "manage.sh"
  "install-discord-bot.sh"
  "install-telegram-bot.sh"
  "opt/setup/core/logging.sh"
  "opt/setup/core/helpers.sh"
  "opt/setup/install/bootstrap.sh"
  "opt/setup/install/domain.sh"
  "opt/setup/install/nginx.sh"
  "opt/setup/install/network.sh"
  "opt/setup/install/xray.sh"
  "opt/setup/install/management.sh"
  "opt/setup/install/sshws.sh"
  "opt/setup/install/edge.sh"
  "opt/setup/install/badvpn.sh"
  "opt/setup/install/observability.sh"
  "opt/setup/templates/config/edge-runtime.env"
  "opt/setup/templates/config/badvpn-runtime.env"
  "opt/setup/templates/systemd/edge-mux.service"
  "opt/setup/templates/systemd/badvpn-udpgw.service"
  "opt/edge/dist/SHA256SUMS"
  "opt/badvpn/dist/SHA256SUMS"
  "opt/manage/features/network.sh"
  "opt/manage/features/analytics.sh"
  "opt/manage/menus/maintenance_menu.sh"
  "opt/manage/menus/main_menu.sh"
  "opt/manage/app/main.sh"
)

# -------------------------
# Warna output
# -------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# -------------------------
# Helpers
# -------------------------
log()  { echo -e "${CYAN}[run]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

hr() { echo "------------------------------------------------------------"; }

repo_has_local_changes() {
  local dir="$1"
  git -C "${dir}" diff --quiet --ignore-submodules -- || return 0
  git -C "${dir}" diff --cached --quiet --ignore-submodules -- || return 0
  if [[ -n "$(git -C "${dir}" ls-files --others --exclude-standard 2>/dev/null || true)" ]]; then
    return 0
  fi
  return 1
}

repo_layout_missing_files() {
  local root="$1"
  shift || true
  local -a patterns=("$@")
  local -a missing=()
  local rel=""

  if [[ -d "${root}/.git" ]]; then
    while IFS= read -r rel; do
      [[ -n "${rel}" ]] || continue
      [[ -e "${root}/${rel}" ]] || missing+=("${rel}")
    done < <(git -C "${root}" ls-files -- "${patterns[@]}" 2>/dev/null || true)
  fi

  if (( ${#missing[@]} == 0 )); then
    local fallback
    for fallback in "${RUN_FALLBACK_REQUIRED_FILES[@]}"; do
      [[ -e "${root}/${fallback}" ]] || missing+=("${fallback}")
    done
  fi

  printf '%s\n' "${missing[@]}"
}

run_prebuilt_arch_suffix() {
  case "$(uname -m)" in
    x86_64|amd64) printf '%s\n' "amd64" ;;
    aarch64|arm64) printf '%s\n' "arm64" ;;
    *) return 1 ;;
  esac
}

preflight_repo_layout() {
  local root="$1"
  local -a missing=()
  local rel=""
  local arch_suffix=""

  [[ -d "${root}" ]] || die "Direktori source repo tidak ditemukan: ${root}"
  [[ -d "${root}/opt/setup" ]] || die "Source modular setup tidak ditemukan: ${root}/opt/setup"
  [[ -d "${root}/opt/manage" ]] || die "Source modular manage tidak ditemukan: ${root}/opt/manage"

  while IFS= read -r rel; do
    [[ -n "${rel}" ]] || continue
    missing+=("${rel}")
  done < <(repo_layout_missing_files "${root}" setup.sh manage.sh install-discord-bot.sh install-telegram-bot.sh opt/setup opt/manage)

  arch_suffix="$(run_prebuilt_arch_suffix 2>/dev/null || true)"
  if [[ -n "${arch_suffix}" ]]; then
    [[ -f "${root}/opt/edge/dist/edge-mux-linux-${arch_suffix}" ]] || missing+=("opt/edge/dist/edge-mux-linux-${arch_suffix}")
    [[ -f "${root}/opt/badvpn/dist/badvpn-udpgw-linux-${arch_suffix}" ]] || missing+=("opt/badvpn/dist/badvpn-udpgw-linux-${arch_suffix}")
  fi

  if (( ${#missing[@]} > 0 )); then
    warn "Layout repo tidak lengkap di: ${root}"
    printf '  - %s\n' "${missing[@]}" >&2
    die "Preflight repo gagal. Lengkapi source lokal/repo sebelum menjalankan run.sh."
  fi
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

reclone_repo_with_backup() {
  local target="$1"
  local backup=""
  backup="${target}.backup.$(date +%Y%m%d%H%M%S)"

  warn "Repo kotor. Backup: ${backup}"
  mv "${target}" "${backup}" || die "Gagal backup repositori lama: ${target}"

  log "Clone ulang repo ke ${target} ..."
  if ! git clone --depth=1 "${REPO_URL}" "${target}" 2>&1; then
    die "Gagal re-clone repositori setelah backup. Backup tersedia di: ${backup}"
  fi
  ok "Repo bersih siap."
  ok "Backup lama: ${backup}"
}

# -------------------------
# Validasi
# -------------------------
check_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "Script ini harus dijalankan sebagai root.\n  Coba: sudo bash run.sh"
  fi
}

check_os() {
  [[ -f /etc/os-release ]] || die "Tidak menemukan /etc/os-release"
  # shellcheck disable=SC1091
  . /etc/os-release

  local id="${ID:-}"
  local ver="${VERSION_ID:-}"
  local codename="${VERSION_CODENAME:-}"

  if [[ "${id}" == "ubuntu" ]]; then
    local ok_ver
    ok_ver="$(awk "BEGIN { print (\"${ver}\" + 0 >= 20.04) ? 1 : 0 }")"
    [[ "${ok_ver}" == "1" ]] || die "Ubuntu minimal 20.04. Versi terdeteksi: ${ver}"
    ok "OS: Ubuntu ${ver} (${codename})"
  elif [[ "${id}" == "debian" ]]; then
    local major="${ver%%.*}"
    [[ "${major:-0}" -ge 11 ]] 2>/dev/null || die "Debian minimal 11. Versi terdeteksi: ${ver}"
    ok "OS: Debian ${ver} (${codename})"
  else
    die "OS tidak didukung: ${id}. Hanya Ubuntu >=20.04 atau Debian >=11."
  fi
}

check_deps() {
  local missing=()
  for cmd in git bash; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      missing+=("${cmd}")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    warn "Dependency belum ada: ${missing[*]}"
    log "Pasang dependency yang kurang..."
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y "${missing[@]}" || die "Gagal menginstal: ${missing[*]}"
    ok "Dependency siap."
  fi
}

# -------------------------
# Langkah instalasi
# -------------------------
clone_repo() {
  if [[ "${RUN_USE_LOCAL_SOURCE}" == "1" ]]; then
    preflight_repo_layout "${REPO_DIR}"
    log "Source lokal: ${REPO_DIR}"
    return 0
  fi

  mkdir -p "$(dirname "${REPO_DIR}")"

  if [[ -d "${REPO_DIR}" && ! -d "${REPO_DIR}/.git" ]]; then
    if [[ -z "$(find "${REPO_DIR}" -mindepth 1 -maxdepth 1 2>/dev/null)" ]]; then
      rmdir "${REPO_DIR}" || true
    else
      die "Direktori ${REPO_DIR} sudah ada tetapi bukan git repo. Bersihkan/rename dulu lalu jalankan ulang."
    fi
  fi

  if [[ -d "${REPO_DIR}/.git" ]]; then
    log "Update repo di ${REPO_DIR} ..."
    if ! git -C "${REPO_DIR}" pull --ff-only origin main 2>&1; then
      if repo_has_local_changes "${REPO_DIR}"; then
        warn "Update repo gagal: working tree kotor."
        reclone_repo_with_backup "${REPO_DIR}"
        return 0
      fi
      die "Gagal update repositori di ${REPO_DIR}. Penyebab bukan perubahan lokal; cek koneksi/remote lalu coba lagi."
    fi
    preflight_repo_layout "${REPO_DIR}"
    ok "Repo updated."
    return 0
  fi

  log "Clone repo ke ${REPO_DIR} ..."
  local clone_err=""
  if ! clone_err="$(git clone --depth=1 "${REPO_URL}" "${REPO_DIR}" 2>&1)"; then
    if grep -Eqi 'could not create work tree dir|permission denied|operation not permitted|read-only file system' <<<"${clone_err}"; then
      die "Gagal mengkloning repositori: ${REPO_URL}\n  Penyebab: path tujuan tidak bisa ditulis (${REPO_DIR}). Cek permission/ownership direktori.\n  Detail git: ${clone_err}"
    fi
    die "Gagal mengkloning repositori: ${REPO_URL}\n  Pastikan server memiliki koneksi internet dan URL repo benar.\n  Detail git: ${clone_err}"
  fi
  preflight_repo_layout "${REPO_DIR}"
  ok "Repo siap."
}

install_manage() {
  local src="${REPO_DIR}/manage.sh"
  local bot_installer_src="${REPO_DIR}/install-discord-bot.sh"
  local telegram_installer_src="${REPO_DIR}/install-telegram-bot.sh"

  [[ -f "${src}" ]] || die "File manage.sh tidak ditemukan di repositori."
  [[ -f "${bot_installer_src}" ]] || die "File install-discord-bot.sh tidak ditemukan di repositori."
  [[ -f "${telegram_installer_src}" ]] || die "File install-telegram-bot.sh tidak ditemukan di repositori."
  preflight_repo_layout "${REPO_DIR}"

  log "Sync manage -> ${MANAGE_MODULES_DST_DIR} ..."
  sync_tree_atomic "${MANAGE_MODULES_SRC_DIR}" "${MANAGE_MODULES_DST_DIR}" "modul manage"
  find "${MANAGE_MODULES_DST_DIR}" -type d -exec chmod 755 {} + 2>/dev/null || true
  find "${MANAGE_MODULES_DST_DIR}" -type f -name '*.sh' -exec chmod 644 {} + 2>/dev/null || true
  chown -R root:root "${MANAGE_MODULES_DST_DIR}" 2>/dev/null || true
  ok "Manage modules: ${MANAGE_MODULES_DST_DIR}"

  log "Sync fallback manage -> ${MANAGE_FALLBACK_MODULES_DST_DIR} ..."
  sync_tree_atomic "${MANAGE_MODULES_SRC_DIR}" "${MANAGE_FALLBACK_MODULES_DST_DIR}" "fallback modul manage"
  find "${MANAGE_FALLBACK_MODULES_DST_DIR}" -type d -exec chmod 755 {} + 2>/dev/null || true
  find "${MANAGE_FALLBACK_MODULES_DST_DIR}" -type f -name '*.sh' -exec chmod 644 {} + 2>/dev/null || true
  chown -R root:root "${MANAGE_FALLBACK_MODULES_DST_DIR}" 2>/dev/null || true
  ok "Fallback manage: ${MANAGE_FALLBACK_MODULES_DST_DIR}"

  log "Pasang manage -> ${MANAGE_BIN} ..."
  install -m 0755 "${src}" "${MANAGE_BIN}"
  ok "manage siap."

  log "Pasang installer Discord -> ${BOT_INSTALLER_BIN} ..."
  install -m 0755 "${bot_installer_src}" "${BOT_INSTALLER_BIN}"
  ok "Installer Discord siap."

  log "Pasang installer Telegram -> ${TELEGRAM_INSTALLER_BIN} ..."
  install -m 0755 "${telegram_installer_src}" "${TELEGRAM_INSTALLER_BIN}"
  ok "Installer Telegram siap."
}

seed_discord_bot_home() {
  if [[ ! -d "${DISCORD_BOT_SRC_DIR}" ]]; then
    warn "Source bot Discord tidak ditemukan di repo (${DISCORD_BOT_SRC_DIR}); lewati bootstrap /opt/bot-discord."
    return 0
  fi

  if [[ -d "${DISCORD_BOT_HOME}" ]] && [[ -n "$(find "${DISCORD_BOT_HOME}" -mindepth 1 -maxdepth 1 2>/dev/null || true)" ]]; then
    ok "Discord home sudah ada."
    return 0
  fi

  log "Siapkan source Discord -> ${DISCORD_BOT_HOME} ..."
  mkdir -p "${DISCORD_BOT_HOME}"
  cp -a "${DISCORD_BOT_SRC_DIR}/." "${DISCORD_BOT_HOME}/"
  chown -R root:root "${DISCORD_BOT_HOME}" 2>/dev/null || true
  ok "Discord source siap."
}

seed_telegram_bot_home() {
  if [[ ! -d "${TELEGRAM_BOT_SRC_DIR}" ]]; then
    warn "Source bot Telegram tidak ditemukan di repo (${TELEGRAM_BOT_SRC_DIR}); lewati bootstrap /opt/bot-telegram."
    return 0
  fi

  if [[ -d "${TELEGRAM_BOT_HOME}" ]] && [[ -n "$(find "${TELEGRAM_BOT_HOME}" -mindepth 1 -maxdepth 1 2>/dev/null || true)" ]]; then
    ok "Telegram home sudah ada."
    return 0
  fi

  log "Siapkan source Telegram -> ${TELEGRAM_BOT_HOME} ..."
  mkdir -p "${TELEGRAM_BOT_HOME}"
  cp -a "${TELEGRAM_BOT_SRC_DIR}/." "${TELEGRAM_BOT_HOME}/"
  chown -R root:root "${TELEGRAM_BOT_HOME}" 2>/dev/null || true
  ok "Telegram source siap."
}

cleanup_repo_after_success() {
  if [[ "${RUN_USE_LOCAL_SOURCE}" == "1" ]]; then
    warn "Source lokal dipertahankan: ${REPO_DIR}"
    return 0
  fi

  if [[ "${KEEP_REPO_AFTER_INSTALL:-0}" == "1" ]]; then
    warn "Repo dipertahankan: ${REPO_DIR}"
    return 0
  fi

  if [[ ! -d "${REPO_DIR}" ]]; then
    return 0
  fi

  local resolved=""
  if command -v readlink >/dev/null 2>&1; then
    resolved="$(readlink -f -- "${REPO_DIR}" 2>/dev/null || true)"
  fi
  [[ -n "${resolved}" ]] || resolved="${REPO_DIR}"

  case "${resolved}" in
    "/"|"/."|"/.."|"/bin"|"/boot"|"/dev"|"/etc"|"/home"|"/lib"|"/lib64"|"/media"|"/mnt"|"/opt"|"/proc"|"/root"|"/run"|"/sbin"|"/srv"|"/sys"|"/tmp"|"/usr"|"/var")
      die "Menolak hapus path berbahaya: ${resolved}"
      ;;
  esac

  if [[ "${PWD}/" == "${resolved}/"* ]]; then
    cd /
  fi

  rm -rf -- "${resolved}"
  ok "Source repo dibersihkan."
}

run_setup() {
  local setup="${REPO_DIR}/setup.sh"

  [[ -f "${setup}" ]] || die "File setup.sh tidak ditemukan di repositori."

  log "Jalankan setup.sh dalam 3 detik ..."
  sleep 3
  hr
  bash "${setup}"
  hr
  ok "setup.sh selesai."
}

# -------------------------
# Main
# -------------------------
main() {
  echo
  echo -e "${BOLD}============================================================${NC}"
  echo -e "${BOLD}   Autoscript Installer${NC}"
  echo -e "${BOLD}============================================================${NC}"
  echo

  check_root
  check_os
  check_deps
  clone_repo
  install_manage
  seed_discord_bot_home
  seed_telegram_bot_home
  run_setup
  cleanup_repo_after_success

  echo
  echo -e "${BOLD}============================================================${NC}"
  ok "Install selesai."
  echo -e "  Buka panel: ${BOLD}manage${NC}"
  echo -e "${BOLD}============================================================${NC}"
  echo
}

main "$@"
