#!/usr/bin/env bash
# Nginx install/config module for setup runtime.

stop_conflicting_services() {
  systemctl stop nginx 2>/dev/null || true
  systemctl stop apache2 2>/dev/null || true
  systemctl stop caddy 2>/dev/null || true
  systemctl stop lighttpd 2>/dev/null || true
}

nginx_installed_from_nginx_org() {
  if ! dpkg-query -W -f='${Status}' nginx 2>/dev/null | grep -q "install ok installed"; then
    return 1
  fi

  local repo_line=""
  repo_line="$(apt-cache policy nginx 2>/dev/null | awk '
    /^[[:space:]]*\*\*\*/ { capture=1; next }
    capture && /^[[:space:]]+[0-9]+[[:space:]]/ { print; exit }
  ')"
  echo "${repo_line}" | grep -qi 'nginx\.org/packages/mainline'
}

install_nginx_official_repo() {
  # shellcheck disable=SC1091
  . /etc/os-release

  local codename
  codename="${VERSION_CODENAME:-}"
  [[ -n "${codename}" ]] || codename="$(lsb_release -sc 2>/dev/null || true)"
  [[ -n "${codename}" ]] || die "Gagal mendeteksi codename OS."

  ensure_dpkg_consistent
  if nginx_installed_from_nginx_org; then
    ok "Nginx mainline dari nginx.org sudah terpasang; skip uninstall paket nginx distro."
  elif dpkg-query -W -f='${Status}' nginx 2>/dev/null | grep -q "install ok installed" \
    || dpkg-query -W -f='${Status}' nginx-common 2>/dev/null | grep -q "install ok installed" \
    || dpkg-query -W -f='${Status}' nginx-full 2>/dev/null | grep -q "install ok installed" \
    || dpkg-query -W -f='${Status}' nginx-core 2>/dev/null | grep -q "install ok installed"; then
    ok "Migrasi paket Nginx distro ke nginx.org mainline..."
    apt_get_with_lock_retry remove -y nginx nginx-common nginx-full nginx-core 2>/dev/null || true
  fi

  mkdir -p /usr/share/keyrings
  local key_tmp key_gpg_tmp
  local key_fprs_raw allowed_fprs got_fpr expected_fpr matched="false"
  key_tmp="$(mktemp)"
  key_gpg_tmp="$(mktemp)"

  curl -fsSL https://nginx.org/keys/nginx_signing.key -o "${key_tmp}" || die "Gagal download nginx signing key."
  key_fprs_raw="$(gpg --show-keys --with-colons "${key_tmp}" 2>/dev/null | awk -F: '/^fpr:/{print toupper($10)}' | tr '\n' ' ' || true)"
  key_fprs_raw="$(echo "${key_fprs_raw}" | awk '{$1=$1;print}')"
  [[ -n "${key_fprs_raw}" ]] || die "Gagal membaca fingerprint nginx signing key."

  if [[ -n "${NGINX_SIGNING_KEY_FPR:-}" ]]; then
    allowed_fprs="${NGINX_SIGNING_KEY_FPR^^}"
  else
    allowed_fprs="${NGINX_SIGNING_KEY_FPRS^^}"
  fi

  for got_fpr in ${key_fprs_raw}; do
    for expected_fpr in ${allowed_fprs}; do
      if [[ "${got_fpr}" == "${expected_fpr}" ]]; then
        matched="true"
        break 2
      fi
    done
  done
  if [[ "${matched}" != "true" ]]; then
    die "Fingerprint nginx signing key mismatch (allowed=${allowed_fprs}, got=${key_fprs_raw})."
  fi
  gpg --dearmor <"${key_tmp}" >"${key_gpg_tmp}"
  install -m 644 "${key_gpg_tmp}" /usr/share/keyrings/nginx-archive-keyring.gpg

  rm -f "${key_tmp}" "${key_gpg_tmp}"

  local distro
  if [[ "${ID}" == "ubuntu" ]]; then
    distro="ubuntu"
  elif [[ "${ID}" == "debian" ]]; then
    distro="debian"
  else
    die "OS tidak didukung untuk repo nginx.org"
  fi

  cat > /etc/apt/sources.list.d/nginx.list <<EOF
deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] https://nginx.org/packages/mainline/${distro}/ ${codename} nginx
EOF

  cat > /etc/apt/preferences.d/99nginx <<'EOF'
Package: *
Pin: origin nginx.org
Pin-Priority: 900
EOF

  apt_get_with_lock_retry update -y
  apt_get_with_lock_retry install -y nginx jq
  ok "Nginx terpasang dari repo resmi nginx.org (mainline)."
}

detect_nginx_user() {
  if id -u nginx >/dev/null 2>&1; then
    echo "nginx"
    return 0
  fi
  if id -u www-data >/dev/null 2>&1; then
    echo "www-data"
    return 0
  fi
  echo "root"
}

write_nginx_main_conf() {
  local nginx_user
  nginx_user="$(detect_nginx_user)"

  rm -f /etc/nginx/conf.d/default.conf 2>/dev/null || true
  rm -f "${NGINX_CONF}" 2>/dev/null || true

  render_setup_template_or_die \
    "nginx/nginx.conf" \
    "/etc/nginx/nginx.conf" \
    0644 \
    "NGINX_USER=${nginx_user}"

  render_setup_template_or_die \
    "nginx/cloudflare-realip.conf" \
    "/etc/nginx/conf.d/00-cloudflare-realip.conf" \
    0644

  nginx -t || die "Konfigurasi /etc/nginx/nginx.conf invalid."
  ok "Nginx main config ditulis: /etc/nginx/nginx.conf (optimized 1 vCPU / 1GB RAM)."
}

write_nginx_config() {
  [[ -f "${CERT_FULLCHAIN}" && -f "${CERT_PRIVKEY}" ]] || die "Sertifikat tidak ditemukan di ${CERT_DIR}."

  local -a nginx_tpl_vars=(
    "P_VLESS_WS=${P_VLESS_WS}"
    "P_VMESS_WS=${P_VMESS_WS}"
    "P_TROJAN_WS=${P_TROJAN_WS}"
    "P_SS_WS=${P_SS_WS}"
    "P_SS2022_WS=${P_SS2022_WS}"
    "P_VLESS_HUP=${P_VLESS_HUP}"
    "P_VMESS_HUP=${P_VMESS_HUP}"
    "P_TROJAN_HUP=${P_TROJAN_HUP}"
    "P_SS_HUP=${P_SS_HUP}"
    "P_SS2022_HUP=${P_SS2022_HUP}"
    "P_VLESS_GRPC=${P_VLESS_GRPC}"
    "P_VMESS_GRPC=${P_VMESS_GRPC}"
    "P_TROJAN_GRPC=${P_TROJAN_GRPC}"
    "P_SS_GRPC=${P_SS_GRPC}"
    "P_SS2022_GRPC=${P_SS2022_GRPC}"
    "I_VLESS_WS=${I_VLESS_WS}"
    "I_VMESS_WS=${I_VMESS_WS}"
    "I_TROJAN_WS=${I_TROJAN_WS}"
    "I_SS_WS=${I_SS_WS}"
    "I_SS2022_WS=${I_SS2022_WS}"
    "I_VLESS_HUP=${I_VLESS_HUP}"
    "I_VMESS_HUP=${I_VMESS_HUP}"
    "I_TROJAN_HUP=${I_TROJAN_HUP}"
    "I_SS_HUP=${I_SS_HUP}"
    "I_SS2022_HUP=${I_SS2022_HUP}"
    "I_VLESS_GRPC=${I_VLESS_GRPC}"
    "I_VMESS_GRPC=${I_VMESS_GRPC}"
    "I_TROJAN_GRPC=${I_TROJAN_GRPC}"
    "I_SS_GRPC=${I_SS_GRPC}"
    "I_SS2022_GRPC=${I_SS2022_GRPC}"
    "DOMAIN=${DOMAIN}"
    "CERT_DIR=${CERT_DIR}"
    "SSHWS_PROXY_PORT=${SSHWS_PROXY_PORT}"
  )

  render_setup_template_or_die \
    "nginx/xray.conf" \
    "${NGINX_CONF}" \
    0644 \
    "${nginx_tpl_vars[@]}"

  nginx -t || die "Konfigurasi Nginx invalid."
  systemctl enable nginx --now
  systemctl restart nginx
  ok "Nginx reverse proxy aktif (public paths -> internal port/path via map \$uri)."
}
