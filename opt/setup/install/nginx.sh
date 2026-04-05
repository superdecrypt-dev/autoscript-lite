#!/usr/bin/env bash
# Nginx install/config module for setup runtime.

nginx_use_internal_edge_backend() {
  case "${EDGE_PROVIDER:-none}" in
    go|nginx-stream)
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

route_candidates = {}

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

route_candidates = {}

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

nginx_export_prefer_runtime() {
  local var_name="$1" runtime_value="$2" fallback_value="$3"
  if [[ -n "${runtime_value}" ]]; then
    declare -gx "${var_name}=${runtime_value}"
    return 0
  fi
  if [[ -n "${fallback_value}" ]]; then
    declare -gx "${var_name}=${fallback_value}"
  fi
}

nginx_read_live_xray_inbound_value() {
  local tag_name="$1" field_name="$2"
  local xray_inbounds="${XRAY_CONFDIR}/10-inbounds.json"
  [[ -f "${xray_inbounds}" ]] || return 1
  python3 - "${xray_inbounds}" "${tag_name}" "${field_name}" <<'PY'
import json
import sys
from pathlib import Path

path, tag_name, field_name = sys.argv[1:]
cfg = json.loads(Path(path).read_text())
for inbound in cfg.get("inbounds", []):
    if inbound.get("tag") != tag_name:
        continue
    if field_name == "port":
        value = inbound.get("port")
    else:
        stream = inbound.get("streamSettings") or {}
        network = stream.get("network") or ""
        if field_name == "path":
            if network == "ws":
                value = (stream.get("wsSettings") or {}).get("path")
            elif network == "httpupgrade":
                value = (stream.get("httpupgradeSettings") or {}).get("path")
            elif network == "xhttp":
                value = (stream.get("xhttpSettings") or {}).get("path")
            else:
                value = None
        elif field_name == "serviceName":
            value = (stream.get("grpcSettings") or {}).get("serviceName") if network == "grpc" else None
        else:
            value = None
    if value not in (None, ""):
        print(value)
        raise SystemExit(0)
raise SystemExit(1)
PY
}

nginx_ensure_domain_context_or_die() {
  local detected_domain
  if [[ -z "${DOMAIN:-}" ]]; then
    detected_domain="$(detect_domain 2>/dev/null || true)"
    if [[ -z "${detected_domain}" && -f "${XRAY_DOMAIN_FILE}" ]]; then
      detected_domain="$(awk 'NF{print; exit}' "${XRAY_DOMAIN_FILE}" 2>/dev/null || true)"
    fi
    [[ -n "${detected_domain}" ]] || die "DOMAIN belum tersedia untuk render nginx."
    export DOMAIN="${detected_domain}"
  fi
}

nginx_capture_live_route_context() {
  local has_nginx_conf="false"
  [[ -f "${NGINX_CONF}" ]] && has_nginx_conf="true"

  nginx_export_prefer_runtime P_VLESS_WS "$(nginx_read_live_xray_inbound_value 'default@vless-ws' 'port' || true)" "$([[ "${has_nginx_conf}" == "true" ]] && nginx_read_live_map_value internal_port 'vless-ws' || true)"
  nginx_export_prefer_runtime P_VMESS_WS "$(nginx_read_live_xray_inbound_value 'default@vmess-ws' 'port' || true)" "$([[ "${has_nginx_conf}" == "true" ]] && nginx_read_live_map_value internal_port 'vmess-ws' || true)"
  nginx_export_prefer_runtime P_TROJAN_WS "$(nginx_read_live_xray_inbound_value 'default@trojan-ws' 'port' || true)" "$([[ "${has_nginx_conf}" == "true" ]] && nginx_read_live_map_value internal_port 'trojan-ws' || true)"
  nginx_export_prefer_runtime P_VLESS_HUP "$(nginx_read_live_xray_inbound_value 'default@vless-hup' 'port' || true)" "$([[ "${has_nginx_conf}" == "true" ]] && nginx_read_live_map_value internal_port 'vless-hup' || true)"
  nginx_export_prefer_runtime P_VMESS_HUP "$(nginx_read_live_xray_inbound_value 'default@vmess-hup' 'port' || true)" "$([[ "${has_nginx_conf}" == "true" ]] && nginx_read_live_map_value internal_port 'vmess-hup' || true)"
  nginx_export_prefer_runtime P_TROJAN_HUP "$(nginx_read_live_xray_inbound_value 'default@trojan-hup' 'port' || true)" "$([[ "${has_nginx_conf}" == "true" ]] && nginx_read_live_map_value internal_port 'trojan-hup' || true)"
  nginx_export_prefer_runtime P_VLESS_XHTTP "$(nginx_read_live_xray_inbound_value 'default@vless-xhttp' 'port' || true)" "$([[ "${has_nginx_conf}" == "true" ]] && nginx_read_live_map_value internal_port 'vless-xhttp' || true)"
  nginx_export_prefer_runtime P_VMESS_XHTTP "$(nginx_read_live_xray_inbound_value 'default@vmess-xhttp' 'port' || true)" "$([[ "${has_nginx_conf}" == "true" ]] && nginx_read_live_map_value internal_port 'vmess-xhttp' || true)"
  nginx_export_prefer_runtime P_TROJAN_XHTTP "$(nginx_read_live_xray_inbound_value 'default@trojan-xhttp' 'port' || true)" "$([[ "${has_nginx_conf}" == "true" ]] && nginx_read_live_map_value internal_port 'trojan-xhttp' || true)"

  nginx_export_prefer_runtime P_VLESS_GRPC "$(nginx_read_live_xray_inbound_value 'default@vless-grpc' 'port' || true)" "$([[ "${has_nginx_conf}" == "true" ]] && nginx_read_live_map_value internal_port 'vless-grpc' || true)"
  nginx_export_prefer_runtime P_VMESS_GRPC "$(nginx_read_live_xray_inbound_value 'default@vmess-grpc' 'port' || true)" "$([[ "${has_nginx_conf}" == "true" ]] && nginx_read_live_map_value internal_port 'vmess-grpc' || true)"
  nginx_export_prefer_runtime P_TROJAN_GRPC "$(nginx_read_live_xray_inbound_value 'default@trojan-grpc' 'port' || true)" "$([[ "${has_nginx_conf}" == "true" ]] && nginx_read_live_map_value internal_port 'trojan-grpc' || true)"

  nginx_export_prefer_runtime I_VLESS_WS "$(nginx_read_live_xray_inbound_value 'default@vless-ws' 'path' || true)" "$([[ "${has_nginx_conf}" == "true" ]] && nginx_read_live_map_value internal_path 'vless-ws' || true)"
  nginx_export_prefer_runtime I_VMESS_WS "$(nginx_read_live_xray_inbound_value 'default@vmess-ws' 'path' || true)" "$([[ "${has_nginx_conf}" == "true" ]] && nginx_read_live_map_value internal_path 'vmess-ws' || true)"
  nginx_export_prefer_runtime I_TROJAN_WS "$(nginx_read_live_xray_inbound_value 'default@trojan-ws' 'path' || true)" "$([[ "${has_nginx_conf}" == "true" ]] && nginx_read_live_map_value internal_path 'trojan-ws' || true)"

  nginx_export_prefer_runtime I_VLESS_HUP "$(nginx_read_live_xray_inbound_value 'default@vless-hup' 'path' || true)" "$([[ "${has_nginx_conf}" == "true" ]] && nginx_read_live_map_value internal_path 'vless-hup' || true)"
  nginx_export_prefer_runtime I_VMESS_HUP "$(nginx_read_live_xray_inbound_value 'default@vmess-hup' 'path' || true)" "$([[ "${has_nginx_conf}" == "true" ]] && nginx_read_live_map_value internal_path 'vmess-hup' || true)"
  nginx_export_prefer_runtime I_TROJAN_HUP "$(nginx_read_live_xray_inbound_value 'default@trojan-hup' 'path' || true)" "$([[ "${has_nginx_conf}" == "true" ]] && nginx_read_live_map_value internal_path 'trojan-hup' || true)"
  nginx_export_prefer_runtime I_VLESS_XHTTP "$(nginx_read_live_xray_inbound_value 'default@vless-xhttp' 'path' || true)" "$([[ "${has_nginx_conf}" == "true" ]] && nginx_read_live_map_value internal_path 'vless-xhttp' || true)"
  nginx_export_prefer_runtime I_VMESS_XHTTP "$(nginx_read_live_xray_inbound_value 'default@vmess-xhttp' 'path' || true)" "$([[ "${has_nginx_conf}" == "true" ]] && nginx_read_live_map_value internal_path 'vmess-xhttp' || true)"
  nginx_export_prefer_runtime I_TROJAN_XHTTP "$(nginx_read_live_xray_inbound_value 'default@trojan-xhttp' 'path' || true)" "$([[ "${has_nginx_conf}" == "true" ]] && nginx_read_live_map_value internal_path 'trojan-xhttp' || true)"

  nginx_export_prefer_runtime I_VLESS_GRPC "$(nginx_read_live_xray_inbound_value 'default@vless-grpc' 'serviceName' || true)" "$([[ "${has_nginx_conf}" == "true" ]] && nginx_read_live_grpc_value 'vless-grpc' || true)"
  nginx_export_prefer_runtime I_VMESS_GRPC "$(nginx_read_live_xray_inbound_value 'default@vmess-grpc' 'serviceName' || true)" "$([[ "${has_nginx_conf}" == "true" ]] && nginx_read_live_grpc_value 'vmess-grpc' || true)"
  nginx_export_prefer_runtime I_TROJAN_GRPC "$(nginx_read_live_xray_inbound_value 'default@trojan-grpc' 'serviceName' || true)" "$([[ "${has_nginx_conf}" == "true" ]] && nginx_read_live_grpc_value 'trojan-grpc' || true)"
}

nginx_ensure_render_context_or_die() {
  nginx_ensure_domain_context_or_die
  nginx_capture_live_route_context

  local required_vars=(
    P_VLESS_WS P_VMESS_WS P_TROJAN_WS
    P_VLESS_HUP P_VMESS_HUP P_TROJAN_HUP
    P_VLESS_XHTTP P_VMESS_XHTTP P_TROJAN_XHTTP
    P_VLESS_GRPC P_VMESS_GRPC P_TROJAN_GRPC
    I_VLESS_WS I_VMESS_WS I_TROJAN_WS
    I_VLESS_HUP I_VMESS_HUP I_TROJAN_HUP
    I_VLESS_XHTTP I_VMESS_XHTTP I_TROJAN_XHTTP
    I_VLESS_GRPC I_VMESS_GRPC I_TROJAN_GRPC
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
    ok "Nginx mainline sudah ada."
  elif dpkg-query -W -f='${Status}' nginx 2>/dev/null | grep -q "install ok installed" \
    || dpkg-query -W -f='${Status}' nginx-common 2>/dev/null | grep -q "install ok installed" \
    || dpkg-query -W -f='${Status}' nginx-full 2>/dev/null | grep -q "install ok installed" \
    || dpkg-query -W -f='${Status}' nginx-core 2>/dev/null | grep -q "install ok installed"; then
    ok "Migrasi Nginx ke mainline..."
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
  ok "Nginx mainline siap."
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
  nginx_ensure_domain_context_or_die
  nginx_capture_live_route_context

  rm -f /etc/nginx/conf.d/default.conf 2>/dev/null || true
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
  ok "nginx.conf ditulis."
}

write_nginx_config() {
  [[ -f "${CERT_FULLCHAIN}" && -f "${CERT_PRIVKEY}" ]] || die "Sertifikat tidak ditemukan di ${CERT_DIR}."
  nginx_ensure_render_context_or_die
  nginx_prepare_stream_conf_state

  local nginx_listen_block nginx_tls_block nginx_mode_desc nginx_realip_block
  if nginx_use_internal_edge_backend; then
    if [[ "${EDGE_PROVIDER:-none}" == "nginx-stream" ]] && edge_runtime_activate_requested; then
      nginx_listen_block=$'  listen '"$(nginx_internal_backend_host)"':'"$(nginx_internal_backend_port)"$';\n  listen '"$(nginx_internal_tls_backend_host)"':'"$(nginx_internal_tls_backend_port)"$' ssl;\n\thttp2 on;'
      nginx_tls_block=$'  ssl_certificate '"${CERT_DIR}"$'/fullchain.pem;\n  ssl_certificate_key '"${CERT_DIR}"$'/privkey.pem;\n  ssl_protocols TLSv1.2 TLSv1.3;\n  ssl_ciphers ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES256-GCM-SHA384;'
      nginx_realip_block=""
      nginx_mode_desc="internal backend $(nginx_internal_backend_addr) + tls $(nginx_internal_tls_backend_addr)"
    else
      nginx_listen_block=$'  listen '"$(nginx_internal_backend_host)"':'"$(nginx_internal_backend_port)"$' proxy_protocol;\n\thttp2 on;'
      nginx_tls_block=""
      nginx_realip_block=$'  set_real_ip_from 127.0.0.1;\n  set_real_ip_from ::1;\n  real_ip_header proxy_protocol;\n  real_ip_recursive on;'
      nginx_mode_desc="internal backend $(nginx_internal_backend_addr)"
    fi
  else
    nginx_listen_block=$'  listen 80;\n  listen [::]:80;\n  listen 443 ssl;\n  listen [::]:443 ssl;\n\thttp2 on;'
    nginx_tls_block=$'  ssl_certificate '"${CERT_DIR}"$'/fullchain.pem;\n  ssl_certificate_key '"${CERT_DIR}"$'/privkey.pem;\n  ssl_protocols TLSv1.2 TLSv1.3;\n  ssl_ciphers ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES256-GCM-SHA384;'
    nginx_realip_block=""
    nginx_mode_desc="public 80/443"
  fi

  local -a nginx_tpl_vars=(
    "P_VLESS_WS=${P_VLESS_WS}"
    "P_VMESS_WS=${P_VMESS_WS}"
    "P_TROJAN_WS=${P_TROJAN_WS}"
    "P_VLESS_HUP=${P_VLESS_HUP}"
    "P_VMESS_HUP=${P_VMESS_HUP}"
    "P_TROJAN_HUP=${P_TROJAN_HUP}"
    "P_VLESS_XHTTP=${P_VLESS_XHTTP}"
    "P_VMESS_XHTTP=${P_VMESS_XHTTP}"
    "P_TROJAN_XHTTP=${P_TROJAN_XHTTP}"
    "P_VLESS_GRPC=${P_VLESS_GRPC}"
    "P_VMESS_GRPC=${P_VMESS_GRPC}"
    "P_TROJAN_GRPC=${P_TROJAN_GRPC}"
    "I_VLESS_WS=${I_VLESS_WS}"
    "I_VMESS_WS=${I_VMESS_WS}"
    "I_TROJAN_WS=${I_TROJAN_WS}"
    "I_VLESS_HUP=${I_VLESS_HUP}"
    "I_VMESS_HUP=${I_VMESS_HUP}"
    "I_TROJAN_HUP=${I_TROJAN_HUP}"
    "I_VLESS_XHTTP=${I_VLESS_XHTTP}"
    "I_VMESS_XHTTP=${I_VMESS_XHTTP}"
    "I_TROJAN_XHTTP=${I_TROJAN_XHTTP}"
    "I_VLESS_GRPC=${I_VLESS_GRPC}"
    "I_VMESS_GRPC=${I_VMESS_GRPC}"
    "I_TROJAN_GRPC=${I_TROJAN_GRPC}"
    "DOMAIN=${DOMAIN}"
    "CERT_DIR=${CERT_DIR}"
    "ACCOUNT_PORTAL_PORT=${ACCOUNT_PORTAL_PORT:-7082}"
    "NGINX_LISTEN_BLOCK=${nginx_listen_block}"
    "NGINX_REALIP_BLOCK=${nginx_realip_block}"
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
  ok "Nginx backend aktif (${nginx_mode_desc})."
}
