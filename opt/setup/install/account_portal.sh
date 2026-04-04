#!/usr/bin/env bash
# Standalone account portal module for setup runtime.

install_account_portal() {
  ok "Pasang portal info akun..."

  command -v python3 >/dev/null 2>&1 || die "python3 dibutuhkan untuk portal info akun."
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
