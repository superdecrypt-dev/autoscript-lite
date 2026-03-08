#!/usr/bin/env bash
# Nginx install/config module for setup runtime.

nginx_use_internal_edge_backend() {
  case "${EDGE_PROVIDER:-none}" in
    go|haproxy|nginx-stream)
      case "${EDGE_ACTIVATE_RUNTIME:-false}" in
        1|true|TRUE|yes|YES|on|ON) return 0 ;;
      esac
      ;;
  esac
  return 1
}

nginx_internal_backend_addr() {
  printf '%s\n' "${EDGE_NGINX_HTTP_BACKEND:-127.0.0.1:18080}"
}

nginx_internal_tls_backend_addr() {
  printf '%s\n' "${EDGE_NGINX_TLS_BACKEND:-127.0.0.1:18443}"
}

nginx_internal_backend_host() {
  local addr
  addr="$(nginx_internal_backend_addr)"
  printf '%s\n' "${addr%:*}"
}

nginx_internal_backend_port() {
  local addr
  addr="$(nginx_internal_backend_addr)"
  printf '%s\n' "${addr##*:}"
}

nginx_internal_tls_backend_host() {
  local addr
  addr="$(nginx_internal_tls_backend_addr)"
  printf '%s\n' "${addr%:*}"
}

nginx_internal_tls_backend_port() {
  local addr
  addr="$(nginx_internal_tls_backend_addr)"
  printf '%s\n' "${addr##*:}"
}

nginx_stream_conf_path() {
  printf '%s\n' "${EDGE_NGINX_STREAM_CONF:-/etc/nginx/stream-conf.d/edge-stream.conf}"
}

nginx_prepare_stream_conf_state() {
  local stream_conf
  stream_conf="$(nginx_stream_conf_path)"
  install -d -m 755 "$(dirname "${stream_conf}")"

  if [[ "${EDGE_PROVIDER:-none}" == "nginx-stream" ]] && edge_runtime_activate_requested; then
    return 0
  fi

  rm -f "${stream_conf}" >/dev/null 2>&1 || true
}

nginx_read_live_map_value() {
  local map_name="$1" route_name="$2"
  [[ -f "${NGINX_CONF}" ]] || return 1
  python3 - "${NGINX_CONF}" "${map_name}" "${route_name}" <<'PY'
import re
import sys
from pathlib import Path

conf_path, map_name, route_regex = sys.argv[1:]
text = Path(conf_path).read_text()

route_candidates = {
    "(shadowsocks|ss)-ws": [r"\(\?:shadowsocks\|ss\)-ws", r"ss-ws"],
    "(shadowsocks2022|ss2022)-ws": [r"\(\?:shadowsocks2022\|ss2022\)-ws", r"ss2022-ws"],
    "(shadowsocks|ss)-hup": [r"\(\?:shadowsocks\|ss\)-hup", r"ss-hup"],
    "(shadowsocks2022|ss2022)-hup": [r"\(\?:shadowsocks2022\|ss2022\)-hup", r"ss2022-hup"],
    "(shadowsocks|ss)-grpc": [r"\(\?:shadowsocks\|ss\)-grpc", r"ss-grpc"],
    "(shadowsocks2022|ss2022)-grpc": [r"\(\?:shadowsocks2022\|ss2022\)-grpc", r"ss2022-grpc"],
}

block_match = re.search(
    rf'map \$uri \${re.escape(map_name)} \{{(.*?)^\}}',
    text,
    re.MULTILINE | re.DOTALL,
)
if not block_match:
    raise SystemExit(1)

for candidate in route_candidates.get(route_regex, [route_regex]):
    pattern = re.compile(
        rf'^\s*~\^/\(\?:\[\^/\]\+/\)\?{candidate}\(\?:/\|\$\)\s+([^;]+);\s*$',
        re.MULTILINE,
    )
    match = pattern.search(block_match.group(1))
    if match:
        print(match.group(1))
        raise SystemExit(0)
raise SystemExit(1)
PY
}

nginx_read_live_map_value_first() {
  local map_name="$1"
  shift
  local route_name value
  for route_name in "$@"; do
    value="$(nginx_read_live_map_value "${map_name}" "${route_name}" || true)"
    if [[ -n "${value}" ]]; then
      printf '%s\n' "${value}"
      return 0
    fi
  done
  return 1
}

nginx_read_live_grpc_value() {
  local route_name="$1"
  [[ -f "${NGINX_CONF}" ]] || return 1
  python3 - "${NGINX_CONF}" "${route_name}" <<'PY'
import re
import sys
from pathlib import Path

conf_path, route_regex = sys.argv[1:]
text = Path(conf_path).read_text()

route_candidates = {
    "(shadowsocks|ss)-grpc": [r"\(\?:shadowsocks\|ss\)-grpc", r"ss-grpc"],
    "(shadowsocks2022|ss2022)-grpc": [r"\(\?:shadowsocks2022\|ss2022\)-grpc", r"ss2022-grpc"],
}

block_match = re.search(
    r'map \$uri \$grpc_service_name \{(.*?)^\}',
    text,
    re.MULTILINE | re.DOTALL,
)
if not block_match:
    raise SystemExit(1)

for candidate in route_candidates.get(route_regex, [route_regex]):
    pattern = re.compile(
        rf'^\s*~\^/\(\?:\[\^/\]\+/\)\?{candidate}\(\?:/\|\$\)\s+([^;]+);\s*$',
        re.MULTILINE,
    )
    match = pattern.search(block_match.group(1))
    if match:
        print(match.group(1))
        raise SystemExit(0)
raise SystemExit(1)
PY
}

nginx_read_live_grpc_value_first() {
  local route_name value
  for route_name in "$@"; do
    value="$(nginx_read_live_grpc_value "${route_name}" || true)"
    if [[ -n "${value}" ]]; then
      printf '%s\n' "${value}"
      return 0
    fi
  done
  return 1
}

nginx_export_if_missing_from_live() {
  local var_name="$1" value="$2"
  if [[ -z "${!var_name:-}" && -n "${value}" ]]; then
    declare -gx "${var_name}=${value}"
  fi
}

nginx_ensure_render_context_or_die() {
  local detected_domain
  if [[ -z "${DOMAIN:-}" ]]; then
    detected_domain="$(detect_domain 2>/dev/null || true)"
    if [[ -z "${detected_domain}" && -f "${XRAY_DOMAIN_FILE}" ]]; then
      detected_domain="$(awk 'NF{print; exit}' "${XRAY_DOMAIN_FILE}" 2>/dev/null || true)"
    fi
    [[ -n "${detected_domain}" ]] || die "DOMAIN belum tersedia untuk render nginx."
    export DOMAIN="${detected_domain}"
  fi

  nginx_export_if_missing_from_live P_VLESS_WS "$(nginx_read_live_map_value internal_port 'vless-ws' || true)"
  nginx_export_if_missing_from_live P_VMESS_WS "$(nginx_read_live_map_value internal_port 'vmess-ws' || true)"
  nginx_export_if_missing_from_live P_TROJAN_WS "$(nginx_read_live_map_value internal_port 'trojan-ws' || true)"
  nginx_export_if_missing_from_live P_SS_WS "$(nginx_read_live_map_value_first internal_port 'ss-ws' '\(\?:shadowsocks\|ss\)-ws' || true)"
  nginx_export_if_missing_from_live P_SS2022_WS "$(nginx_read_live_map_value_first internal_port 'ss2022-ws' '\(\?:shadowsocks2022\|ss2022\)-ws' || true)"

  nginx_export_if_missing_from_live P_VLESS_HUP "$(nginx_read_live_map_value internal_port 'vless-hup' || true)"
  nginx_export_if_missing_from_live P_VMESS_HUP "$(nginx_read_live_map_value internal_port 'vmess-hup' || true)"
  nginx_export_if_missing_from_live P_TROJAN_HUP "$(nginx_read_live_map_value internal_port 'trojan-hup' || true)"
  nginx_export_if_missing_from_live P_SS_HUP "$(nginx_read_live_map_value_first internal_port 'ss-hup' '\(\?:shadowsocks\|ss\)-hup' || true)"
  nginx_export_if_missing_from_live P_SS2022_HUP "$(nginx_read_live_map_value_first internal_port 'ss2022-hup' '\(\?:shadowsocks2022\|ss2022\)-hup' || true)"

  nginx_export_if_missing_from_live P_VLESS_GRPC "$(nginx_read_live_map_value internal_port 'vless-grpc' || true)"
  nginx_export_if_missing_from_live P_VMESS_GRPC "$(nginx_read_live_map_value internal_port 'vmess-grpc' || true)"
  nginx_export_if_missing_from_live P_TROJAN_GRPC "$(nginx_read_live_map_value internal_port 'trojan-grpc' || true)"
  nginx_export_if_missing_from_live P_SS_GRPC "$(nginx_read_live_map_value_first internal_port 'ss-grpc' '\(\?:shadowsocks\|ss\)-grpc' || true)"
  nginx_export_if_missing_from_live P_SS2022_GRPC "$(nginx_read_live_map_value_first internal_port 'ss2022-grpc' '\(\?:shadowsocks2022\|ss2022\)-grpc' || true)"

  nginx_export_if_missing_from_live I_VLESS_WS "$(nginx_read_live_map_value internal_path 'vless-ws' || true)"
  nginx_export_if_missing_from_live I_VMESS_WS "$(nginx_read_live_map_value internal_path 'vmess-ws' || true)"
  nginx_export_if_missing_from_live I_TROJAN_WS "$(nginx_read_live_map_value internal_path 'trojan-ws' || true)"
  nginx_export_if_missing_from_live I_SS_WS "$(nginx_read_live_map_value_first internal_path 'ss-ws' '\(\?:shadowsocks\|ss\)-ws' || true)"
  nginx_export_if_missing_from_live I_SS2022_WS "$(nginx_read_live_map_value_first internal_path 'ss2022-ws' '\(\?:shadowsocks2022\|ss2022\)-ws' || true)"

  nginx_export_if_missing_from_live I_VLESS_HUP "$(nginx_read_live_map_value internal_path 'vless-hup' || true)"
  nginx_export_if_missing_from_live I_VMESS_HUP "$(nginx_read_live_map_value internal_path 'vmess-hup' || true)"
  nginx_export_if_missing_from_live I_TROJAN_HUP "$(nginx_read_live_map_value internal_path 'trojan-hup' || true)"
  nginx_export_if_missing_from_live I_SS_HUP "$(nginx_read_live_map_value_first internal_path 'ss-hup' '\(\?:shadowsocks\|ss\)-hup' || true)"
  nginx_export_if_missing_from_live I_SS2022_HUP "$(nginx_read_live_map_value_first internal_path 'ss2022-hup' '\(\?:shadowsocks2022\|ss2022\)-hup' || true)"

  nginx_export_if_missing_from_live I_VLESS_GRPC "$(nginx_read_live_grpc_value 'vless-grpc' || true)"
  nginx_export_if_missing_from_live I_VMESS_GRPC "$(nginx_read_live_grpc_value 'vmess-grpc' || true)"
  nginx_export_if_missing_from_live I_TROJAN_GRPC "$(nginx_read_live_grpc_value 'trojan-grpc' || true)"
  nginx_export_if_missing_from_live I_SS_GRPC "$(nginx_read_live_grpc_value_first 'ss-grpc' '\(\?:shadowsocks\|ss\)-grpc' || true)"
  nginx_export_if_missing_from_live I_SS2022_GRPC "$(nginx_read_live_grpc_value_first 'ss2022-grpc' '\(\?:shadowsocks2022\|ss2022\)-grpc' || true)"

  local required_vars=(
    P_VLESS_WS P_VMESS_WS P_TROJAN_WS P_SS_WS P_SS2022_WS
    P_VLESS_HUP P_VMESS_HUP P_TROJAN_HUP P_SS_HUP P_SS2022_HUP
    P_VLESS_GRPC P_VMESS_GRPC P_TROJAN_GRPC P_SS_GRPC P_SS2022_GRPC
    I_VLESS_WS I_VMESS_WS I_TROJAN_WS I_SS_WS I_SS2022_WS
    I_VLESS_HUP I_VMESS_HUP I_TROJAN_HUP I_SS_HUP I_SS2022_HUP
    I_VLESS_GRPC I_VMESS_GRPC I_TROJAN_GRPC I_SS_GRPC I_SS2022_GRPC
  )
  local missing=()
  local var_name
  for var_name in "${required_vars[@]}"; do
    [[ -n "${!var_name:-}" ]] || missing+=("${var_name}")
  done
  ((${#missing[@]} == 0)) || die "Context route nginx belum lengkap: ${missing[*]}"
}

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

  # Saat rerun di host yang sudah hidup, pertahankan context route/path dari
  # config nginx live sebelum file utama dibersihkan dan ditulis ulang.
  nginx_ensure_render_context_or_die

  rm -f /etc/nginx/conf.d/default.conf 2>/dev/null || true
  rm -f "${NGINX_CONF}" 2>/dev/null || true
  nginx_prepare_stream_conf_state

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
  nginx_ensure_render_context_or_die
  nginx_prepare_stream_conf_state

  local nginx_listen_block nginx_tls_block nginx_mode_desc
  if nginx_use_internal_edge_backend; then
    if [[ "${EDGE_PROVIDER:-none}" == "nginx-stream" ]] && edge_runtime_activate_requested; then
      nginx_listen_block=$'  listen '"$(nginx_internal_backend_host)"':'"$(nginx_internal_backend_port)"$';\n  listen '"$(nginx_internal_tls_backend_host)"':'"$(nginx_internal_tls_backend_port)"$' ssl;\n\thttp2 on;'
      nginx_tls_block=$'  ssl_certificate '"${CERT_DIR}"$'/fullchain.pem;\n  ssl_certificate_key '"${CERT_DIR}"$'/privkey.pem;\n  ssl_protocols TLSv1.2 TLSv1.3;\n  ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;'
      nginx_mode_desc="internal backend $(nginx_internal_backend_addr) + tls $(nginx_internal_tls_backend_addr)"
    else
      nginx_listen_block=$'  listen '"$(nginx_internal_backend_host)"':'"$(nginx_internal_backend_port)"$';'
      nginx_tls_block=""
      nginx_mode_desc="internal backend $(nginx_internal_backend_addr)"
    fi
  else
    nginx_listen_block=$'  listen 80;\n  listen [::]:80;\n  listen 443 ssl;\n  listen [::]:443 ssl;\n\thttp2 on;'
    nginx_tls_block=$'  ssl_certificate '"${CERT_DIR}"$'/fullchain.pem;\n  ssl_certificate_key '"${CERT_DIR}"$'/privkey.pem;\n  ssl_protocols TLSv1.2 TLSv1.3;\n  ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;'
    nginx_mode_desc="public 80/443"
  fi

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
    "NGINX_LISTEN_BLOCK=${nginx_listen_block}"
    "NGINX_TLS_BLOCK=${nginx_tls_block}"
  )

  render_setup_template_or_die \
    "nginx/xray.conf" \
    "${NGINX_CONF}" \
    0644 \
    "${nginx_tpl_vars[@]}"

  nginx -t || die "Konfigurasi Nginx invalid."
  systemctl enable nginx --now
  systemctl restart nginx
  ok "Nginx reverse proxy aktif (${nginx_mode_desc} -> internal port/path via map \$uri)."
}
