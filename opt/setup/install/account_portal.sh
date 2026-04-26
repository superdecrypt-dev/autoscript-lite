#!/usr/bin/env bash
# Standalone account portal module for setup runtime.

ensure_account_portal_python_venv_support() {
  command -v python3 >/dev/null 2>&1 || die "python3 dibutuhkan untuk portal info akun."

  if python3 -m ensurepip --version >/dev/null 2>&1; then
    return 0
  fi

  command -v apt-get >/dev/null 2>&1 || die "ensurepip tidak tersedia dan apt-get tidak ditemukan untuk memasang python venv support."
  declare -F apt_get_with_lock_retry >/dev/null 2>&1 || die "Helper apt_get_with_lock_retry tidak tersedia."

  local py_major_minor="" py_venv_pkg=""
  py_major_minor="$(python3 - <<'PY'
import sys
print(f"{sys.version_info.major}.{sys.version_info.minor}")
PY
)"
  [[ -n "${py_major_minor}" ]] || die "Gagal mendeteksi versi python3 aktif."
  py_venv_pkg="python${py_major_minor}-venv"

  warn "ensurepip belum tersedia untuk python3 aktif. Mencoba memasang ${py_venv_pkg} ..."
  apt_get_with_lock_retry update -y
  if ! apt_get_with_lock_retry install -y "${py_venv_pkg}"; then
    warn "Gagal memasang ${py_venv_pkg}. Mencoba fallback ke python3-venv ..."
    apt_get_with_lock_retry install -y python3-venv || die "Gagal memasang dukungan python venv (${py_venv_pkg} / python3-venv)."
  fi

  python3 -m ensurepip --version >/dev/null 2>&1 || die "Dukungan ensurepip tetap belum tersedia setelah memasang paket venv Python."
}

install_account_portal() {
  ok "Pasang portal info akun..."

  ensure_account_portal_python_venv_support
  [[ -d "${ACCOUNT_PORTAL_SRC_DIR}" ]] || die "Source portal info akun tidak ditemukan: ${ACCOUNT_PORTAL_SRC_DIR}"
  [[ -f "${ACCOUNT_PORTAL_SRC_DIR}/requirements.lock.txt" ]] || die "requirements.lock.txt portal tidak ditemukan."

  sync_tree_atomic "${ACCOUNT_PORTAL_SRC_DIR}" "${ACCOUNT_PORTAL_ROOT}" "portal info akun ${ACCOUNT_PORTAL_ROOT}"

  local portal_web_root="${ACCOUNT_PORTAL_ROOT}/web"
  local portal_web_dist="${portal_web_root}/dist"
  if [[ -d "${portal_web_root}" ]]; then
    [[ -f "${portal_web_root}/package.json" ]] || die "package.json portal web tidak ditemukan."
    [[ -f "${portal_web_root}/package-lock.json" ]] || die "package-lock.json portal web tidak ditemukan."

    ensure_nodejs_runtime_for_account_portal
    rm -rf "${portal_web_root}/node_modules" "${portal_web_dist}" >/dev/null 2>&1 || true
    (
      cd "${portal_web_root}"
      npm ci --no-audit --no-fund >/dev/null
      npm run build >/dev/null
    ) || die "Build frontend portal React gagal."
    [[ -f "${portal_web_dist}/index.html" ]] || die "Hasil build frontend portal tidak ditemukan: ${portal_web_dist}/index.html"
    rm -rf "${portal_web_root}/node_modules" >/dev/null 2>&1 || true
  fi

  find "${ACCOUNT_PORTAL_ROOT}" -type d -exec chmod 755 {} + 2>/dev/null || true
  find "${ACCOUNT_PORTAL_ROOT}" -type f -exec chmod 644 {} + 2>/dev/null || true
  chown -R root:root "${ACCOUNT_PORTAL_ROOT}" 2>/dev/null || true

  python3 -m venv "${ACCOUNT_PORTAL_ROOT}/.venv"
  "${ACCOUNT_PORTAL_ROOT}/.venv/bin/pip" install --upgrade pip >/dev/null
  "${ACCOUNT_PORTAL_ROOT}/.venv/bin/pip" install -r "${ACCOUNT_PORTAL_ROOT}/requirements.lock.txt" >/dev/null

  local portal_py_files=()
  mapfile -t portal_py_files < <(find "${ACCOUNT_PORTAL_ROOT}/app" -name '*.py' | sort)
  if (( ${#portal_py_files[@]} > 0 )); then
    python3 -m py_compile "${portal_py_files[@]}"
  fi

  render_setup_template_or_die \
    "systemd/account-portal.service" \
    "/etc/systemd/system/${ACCOUNT_PORTAL_SERVICE}.service" \
    0644 \
    "ACCOUNT_PORTAL_ROOT=${ACCOUNT_PORTAL_ROOT}" \
    "ACCOUNT_PORTAL_HOST=${ACCOUNT_PORTAL_HOST}" \
    "ACCOUNT_PORTAL_PORT=${ACCOUNT_PORTAL_PORT}"

  systemctl daemon-reload
  if ! service_enable_restart_checked "${ACCOUNT_PORTAL_SERVICE}"; then
    systemctl status "${ACCOUNT_PORTAL_SERVICE}" --no-pager >&2 || true
    journalctl -u "${ACCOUNT_PORTAL_SERVICE}" -n 120 --no-pager >&2 || true
    die "Portal info akun gagal diaktifkan."
  fi

  ok "Portal info akun aktif:"
  ok "  - service: ${ACCOUNT_PORTAL_SERVICE}.service"
  ok "  - root   : ${ACCOUNT_PORTAL_ROOT}"
  ok "  - bind   : ${ACCOUNT_PORTAL_HOST}:${ACCOUNT_PORTAL_PORT}"
}
