#!/usr/bin/env bash
# Network/runtime tuning module for setup runtime.

WGCF_RELEASE_TAG="${WGCF_RELEASE_TAG:-v2.2.30}"
WGCF_RELEASE_VERSION="${WGCF_RELEASE_VERSION:-2.2.30}"
WIREPROXY_RELEASE_TAG="${WIREPROXY_RELEASE_TAG:-v1.1.2}"
HYSTERIA2_RELEASE_URL_BASE="${HYSTERIA2_RELEASE_URL_BASE:-https://github.com/apernet/hysteria/releases/latest/download}"
CLOUDFLARE_WARP_KEY_URL="${CLOUDFLARE_WARP_KEY_URL:-https://pkg.cloudflareclient.com/pubkey.gpg}"
CLOUDFLARE_WARP_REPO_URL="${CLOUDFLARE_WARP_REPO_URL:-https://pkg.cloudflareclient.com/}"
CLOUDFLARE_WARP_KEYRING="${CLOUDFLARE_WARP_KEYRING:-/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg}"
CLOUDFLARE_WARP_LIST_FILE="${CLOUDFLARE_WARP_LIST_FILE:-/etc/apt/sources.list.d/cloudflare-client.list}"
WARP_STATE_FILE="${WARP_STATE_FILE:-/var/lib/xray-manage/network_state.json}"

install_fail2ban_aggressive() {
  ok "Aktifkan fail2ban..."

  if service_enable_restart_checked fail2ban; then
    ok "fail2ban aktif."
  else
    warn "fail2ban belum aktif (akan dicoba lagi setelah jail.local diterapkan)."
  fi
}

ensure_fail2ban_nginx_filters() {
  # Buat filter minimal jika distro tidak menyediakannya
  mkdir -p /etc/fail2ban/filter.d

  if [[ ! -f /etc/fail2ban/filter.d/nginx-http-auth.conf ]]; then
    cat > /etc/fail2ban/filter.d/nginx-http-auth.conf <<'EOF'
[Definition]
failregex = ^\s*\[error\] .*? user ".*?": password mismatch, client: <HOST>.*$
            ^\s*\[error\] .*? user ".*?": was not found in ".*?", client: <HOST>.*$
ignoreregex =
EOF
  fi

  if [[ ! -f /etc/fail2ban/filter.d/nginx-botsearch.conf ]]; then
    cat > /etc/fail2ban/filter.d/nginx-botsearch.conf <<'EOF'
[Definition]
failregex = ^<HOST> - .* \"(GET|POST|HEAD).*(wp-login\.php|xmlrpc\.php|\.env|phpmyadmin|admin\.php|setup\.php|HNAP1|boaform) .*\"
            ^<HOST> - .* \"(GET|POST|HEAD).*(\.git/|\.svn/|\.hg/|\.DS_Store) .*\"
ignoreregex =
EOF
  fi

  if [[ ! -f /etc/fail2ban/filter.d/nginx-bad-request.conf ]]; then
    cat > /etc/fail2ban/filter.d/nginx-bad-request.conf <<'EOF'
[Definition]

failregex = ^<HOST> - .* "(GET|POST|HEAD|PUT|DELETE|OPTIONS|PATCH).*" (400|401|403|404|405|444) .*
            ^<HOST> - .* "(GET|POST|HEAD|PUT|DELETE).* (wp-login\.php|xmlrpc\.php|\.env|phpmyadmin|HNAP1|admin|manager)" .*
            ^\s*\d{4}/\d{2}/\d{2}\s+\d{2}:\d{2}:\d{2}\s+\[error\]\s+\d+#\d+:\s+\*\d+\s+client sent invalid request.*client:\s+<HOST>.*$
            ^\s*\d{4}/\d{2}/\d{2}\s+\d{2}:\d{2}:\d{2}\s+\[error\]\s+\d+#\d+:\s+\*\d+\s+client sent invalid method.*client:\s+<HOST>.*$
            ^\s*\d{4}/\d{2}/\d{2}\s+\d{2}:\d{2}:\d{2}\s+\[error\]\s+\d+#\d+:\s+\*\d+\s+invalid host in request.*client:\s+<HOST>.*$
            ^\s*\d{4}/\d{2}/\d{2}\s+\d{2}:\d{2}:\d{2}\s+\[error\]\s+\d+#\d+:\s+\*\d+\s+request.*invalid.*client:\s+<HOST>.*$

ignoreregex =
EOF
  fi

}

configure_fail2ban_aggressive_jails() {
  ok "Terapkan fail2ban mode aggressive..."

  ensure_fail2ban_nginx_filters

  mkdir -p /etc/fail2ban
  cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime  = 1d
findtime = 10m
maxretry = 3
# backend = auto: deteksi otomatis terbaik untuk file-based logs (nginx, fail2ban.log).
# Jangan pakai backend=systemd di [DEFAULT] karena nginx (dari nginx.org repo) log ke
# /var/log/nginx/*.log (file), BUKAN ke systemd journal. Dengan backend=systemd,
# fail2ban mengabaikan logpath dan baca dari journal sehingga nginx jails dan
# recidive tidak berfungsi sama sekali.
backend  = auto
ignoreip = 127.0.0.1/8 ::1

[nginx-bad-request-access]
enabled  = true
port     = http,https
filter   = nginx-bad-request
logpath  = /var/log/nginx/access.log
maxretry = 20
findtime = 60
bantime  = 1h

[nginx-bad-request-error]
enabled  = true
port     = http,https
filter   = nginx-bad-request
logpath  = /var/log/nginx/error.log
maxretry = 10
findtime = 60
bantime  = 2h

[recidive]
enabled  = true
# recidive membaca fail2ban.log (file), backend=auto sudah tepat dari [DEFAULT].
logpath  = /var/log/fail2ban.log
bantime  = 7d
findtime = 1d
maxretry = 5
EOF

  service_enable_restart_checked fail2ban || die "Gagal mengaktifkan fail2ban setelah menerapkan jail.local."
  ok "fail2ban jails aggressive diterapkan."
}

enable_bbr() {
  ok "Aktifkan TCP BBR..."

  cat > /etc/sysctl.d/99-custom-net.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

  sysctl --system >/dev/null 2>&1 || true
  ok "TCP BBR diset (fq + bbr)."
}

setup_swap_2gb() {
  ok "Siapkan swap 2GB..."

  if is_container_env; then
    warn "Lingkungan kontainer terdeteksi. Swap dilewati."
    return 0
  fi

  if swapon --show 2>/dev/null | awk '{print $1}' | grep -qx "/swapfile"; then
    ok "Swap sudah aktif."
    return 0
  fi

  if [[ ! -f /swapfile ]]; then
    fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
  fi

  if ! swapon /swapfile >/dev/null 2>&1; then
    warn "Gagal mengaktifkan /swapfile (kernel/permission/fs constraint)."
  fi
  touch /etc/fstab
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab

  cat > /etc/sysctl.d/99-custom-vm.conf <<'EOF'
vm.swappiness = 10
vm.vfs_cache_pressure = 50
EOF

  sysctl --system >/dev/null 2>&1 || true
  if swapon --show 2>/dev/null | awk '{print $1}' | grep -qx "/swapfile"; then
    ok "Swap 2GB aktif."
  else
    warn "Swap belum aktif. Lanjut tanpa swap."
  fi
}

tune_ulimit() {
  ok "Atur ulimit..."

  mkdir -p /etc/security/limits.d
  cat > /etc/security/limits.d/99-custom-limits.conf <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
* soft nproc  1048576
* hard nproc  1048576
root soft nofile 1048576
root hard nofile 1048576
EOF

  mkdir -p /etc/systemd/system.conf.d
  cat > /etc/systemd/system.conf.d/99-custom-limits.conf <<'EOF'
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=1048576
EOF

  systemctl daemon-reexec >/dev/null 2>&1 || true
  ok "ulimit limits ditambahkan (perlu relogin/reboot untuk full effect)."
}

setup_time_sync_chrony() {
  ok "Aktifkan chrony..."

  systemctl disable --now systemd-timesyncd >/dev/null 2>&1 || true
  systemctl enable chrony --now >/dev/null 2>&1 || true
  systemctl restart chrony >/dev/null 2>&1 || true
  ok "chrony aktif."
}

get_arch() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armhf) echo "armv7" ;;
    *) die "Arsitektur tidak didukung: $arch" ;;
  esac
}

wgcf_asset_name() {
  case "$(get_arch)" in
    amd64) printf '%s\n' "wgcf_${WGCF_RELEASE_VERSION}_linux_amd64" ;;
    arm64) printf '%s\n' "wgcf_${WGCF_RELEASE_VERSION}_linux_arm64" ;;
    armv7) printf '%s\n' "wgcf_${WGCF_RELEASE_VERSION}_linux_armv7" ;;
    *) return 1 ;;
  esac
}

wgcf_asset_url() {
  local asset
  asset="$(wgcf_asset_name)" || return 1
  printf 'https://github.com/ViRb3/wgcf/releases/download/%s/%s\n' "${WGCF_RELEASE_TAG}" "${asset}"
}

wireproxy_asset_name() {
  case "$(get_arch)" in
    amd64) printf '%s\n' "wireproxy_linux_amd64.tar.gz" ;;
    arm64) printf '%s\n' "wireproxy_linux_arm64.tar.gz" ;;
    armv7) printf '%s\n' "wireproxy_linux_arm.tar.gz" ;;
    *) return 1 ;;
  esac
}

wireproxy_asset_url() {
  local asset
  asset="$(wireproxy_asset_name)" || return 1
  printf 'https://github.com/windtf/wireproxy/releases/download/%s/%s\n' "${WIREPROXY_RELEASE_TAG}" "${asset}"
}

hysteria2_asset_name() {
  case "$(get_arch)" in
    amd64) printf '%s\n' "hysteria-linux-amd64" ;;
    arm64) printf '%s\n' "hysteria-linux-arm64" ;;
    armv7) printf '%s\n' "hysteria-linux-arm" ;;
    *) return 1 ;;
  esac
}

hysteria2_asset_url() {
  local asset
  asset="$(hysteria2_asset_name)" || return 1
  printf '%s/%s\n' "${HYSTERIA2_RELEASE_URL_BASE}" "${asset}"
}

hysteria2_udp_port_free() {
  local p="${1:-}"
  [[ -n "${p}" ]] || return 1
  ! ss -lun 2>/dev/null | awk '{print $5}' | grep -qE "[:.]${p}$"
}

hysteria2_pick_udp_port() {
  local requested="${HYSTERIA2_PORT:-443}" candidate tries=0
  if [[ "${requested}" =~ ^[0-9]+$ ]] && hysteria2_udp_port_free "${requested}"; then
    printf '%s\n' "${requested}"
    return 0
  fi
  while (( tries < 2000 )); do
    candidate="$(pick_port)"
    if [[ "${candidate}" =~ ^[0-9]+$ ]] && hysteria2_udp_port_free "${candidate}"; then
      printf '%s\n' "${candidate}"
      return 0
    fi
    tries=$((tries + 1))
  done
  die "Gagal mendapatkan port UDP kosong untuk Hysteria 2."
}

cloudflare_warp_repo_codename_get() {
  local codename=""
  if command -v lsb_release >/dev/null 2>&1; then
    codename="$(lsb_release -cs 2>/dev/null || true)"
  fi
  if [[ -z "${codename}" && -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    codename="${VERSION_CODENAME:-}"
  fi
  printf '%s\n' "${codename}"
}

cloudflare_warp_repo_arch_get() {
  local arch=""
  arch="$(dpkg --print-architecture 2>/dev/null || true)"
  case "${arch}" in
    amd64|arm64)
      printf '%s\n' "${arch}"
      return 0
      ;;
  esac
  return 1
}

cloudflare_warp_repo_supported() {
  local distro_id="" codename="" arch=""
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    distro_id="${ID:-}"
  fi
  codename="$(cloudflare_warp_repo_codename_get)"
  arch="$(cloudflare_warp_repo_arch_get 2>/dev/null || true)"

  case "${distro_id}:${codename}" in
    ubuntu:focal|ubuntu:jammy|ubuntu:noble|debian:bullseye|debian:bookworm|debian:trixie) ;;
    *) return 1 ;;
  esac
  [[ "${arch}" == "amd64" || "${arch}" == "arm64" ]]
}

cloudflare_warp_zero_trust_proxy_port_get() {
  local proxy_port=""
  proxy_port="$(python3 - <<'PY' "${WARP_ZEROTRUST_CONFIG_FILE}" "${WARP_ZEROTRUST_PROXY_PORT}" 2>/dev/null || true
import pathlib
import sys

cfg = pathlib.Path(sys.argv[1])
default_port = str(sys.argv[2] or "40000").strip() or "40000"
proxy_port = ""

if cfg.exists():
  try:
    for line in cfg.read_text(encoding="utf-8").splitlines():
      stripped = line.strip()
      if not stripped or stripped.startswith("#") or "=" not in line:
        continue
      key, value = line.split("=", 1)
      if key.strip() == "WARP_ZEROTRUST_PROXY_PORT":
        proxy_port = value.strip()
        break
  except Exception:
    proxy_port = ""

print(proxy_port if proxy_port.isdigit() else default_port)
PY
)"
  if [[ ! "${proxy_port}" =~ ^[0-9]+$ ]]; then
    proxy_port="${WARP_ZEROTRUST_PROXY_PORT}"
  fi
  printf '%s\n' "${proxy_port}"
}

cloudflare_warp_port_listener_names_get() {
  local port="${1:-}"
  [[ "${port}" =~ ^[0-9]+$ ]] || return 1
  command -v ss >/dev/null 2>&1 || return 1
  ss -lntp "sport = :${port}" 2>/dev/null | awk '
    NR <= 1 { next }
    {
      line = $0
      while (match(line, /\("[^"]+"/)) {
        name = substr(line, RSTART + 2, RLENGTH - 3)
        if (!(name in seen)) {
          print name
          seen[name] = 1
        }
        line = substr(line, RSTART + RLENGTH)
      }
    }
  '
}

cloudflare_warp_zero_trust_proxy_owned_by_service() {
  local port=""
  port="$(cloudflare_warp_zero_trust_proxy_port_get 2>/dev/null || true)"
  [[ "${port}" =~ ^[0-9]+$ ]] || return 1
  cloudflare_warp_port_listener_names_get "${port}" 2>/dev/null | grep -Fxq "${WARP_ZEROTRUST_SERVICE}"
}

cloudflare_warp_mode_state_get() {
  local mode="" state_mode="" runtime_zero_trust_active=1
  if [[ -f "${WARP_STATE_FILE}" ]]; then
    state_mode="$(python3 - <<'PY' "${WARP_STATE_FILE}" 2>/dev/null || true
import json
import sys

path = sys.argv[1]
try:
  with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh) or {}
except Exception:
  data = {}
value = str(data.get("warp_mode") or "").strip().lower()
if value in {"consumer", "zerotrust"}:
  print(value)
PY
    )"
  fi

  if ! systemctl list-unit-files "${WARP_ZEROTRUST_SERVICE}" >/dev/null 2>&1 \
    || ! systemctl is-active --quiet "${WARP_ZEROTRUST_SERVICE}" \
    || ! cloudflare_warp_zero_trust_proxy_owned_by_service; then
    runtime_zero_trust_active=0
  fi

  if (( runtime_zero_trust_active == 1 )); then
    printf 'zerotrust\n'
    return 0
  fi

  if [[ "${state_mode}" == "consumer" || "${state_mode}" == "zerotrust" ]]; then
    printf '%s\n' "${state_mode}"
    return 0
  fi

  if [[ -f "${WARP_ZEROTRUST_MDM_FILE}" ]] && systemctl list-unit-files "${WARP_ZEROTRUST_SERVICE}" >/dev/null 2>&1 && systemctl is-active --quiet "${WARP_ZEROTRUST_SERVICE}"; then
    printf 'zerotrust\n'
  else
    printf 'consumer\n'
  fi
}

cloudflare_warp_tier_state_get() {
  local tier=""
  if [[ ! -f "${WARP_STATE_FILE}" ]]; then
    printf 'unknown\n'
    return 0
  fi
  tier="$(python3 - <<'PY' "${WARP_STATE_FILE}" 2>/dev/null || true
import json
import sys

path = sys.argv[1]
try:
  with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh) or {}
except Exception:
  data = {}
value = str(data.get("warp_tier_target") or "").strip().lower()
if value in {"free", "plus"}:
  print(value)
PY
)"
  if [[ "${tier}" == "free" || "${tier}" == "plus" ]]; then
    printf '%s\n' "${tier}"
  else
    printf 'unknown\n'
  fi
}

cloudflare_warp_seed_free_plus_state_if_missing() {
  local mode="" tier="" tmp="" now="" state_dir=""
  mode="$(cloudflare_warp_mode_state_get 2>/dev/null || true)"
  [[ "${mode}" == "zerotrust" ]] && return 0

  tier="$(cloudflare_warp_tier_state_get 2>/dev/null || true)"
  if [[ "${tier}" == "free" || "${tier}" == "plus" ]]; then
    return 0
  fi

  state_dir="$(dirname -- "${WARP_STATE_FILE}")"
  install -d -m 700 "${state_dir}" >/dev/null 2>&1 || return 1
  tmp="$(mktemp "${state_dir}/.network_state.json.tmp.XXXXXX" 2>/dev/null || true)"
  if [[ -z "${tmp}" ]]; then
    tmp="${state_dir}/.network_state.json.tmp.$$"
  fi
  now="$(date '+%Y-%m-%d %H:%M:%S')"
  python3 - <<'PY' "${WARP_STATE_FILE}" "${tmp}" "${now}" || {
import json
import os
import sys

path = sys.argv[1]
tmp = sys.argv[2]
now = sys.argv[3]
try:
  if os.path.exists(path):
    with open(path, "r", encoding="utf-8") as fh:
      data = json.load(fh) or {}
  else:
    data = {}
except Exception:
  data = {}

os.makedirs(os.path.dirname(path) or ".", exist_ok=True)

tier = str(data.get("warp_tier_target") or "").strip().lower()
if tier not in {"free", "plus"}:
  data["warp_tier_target"] = "free"
if str(data.get("warp_mode") or "").strip().lower() != "zerotrust":
  data["warp_mode"] = "consumer"
if str(data.get("warp_tier_last_verified") or "").strip().lower() not in {"free", "plus"}:
  data["warp_tier_last_verified"] = data["warp_tier_target"]
if not str(data.get("warp_tier_last_verified_at") or "").strip():
  data["warp_tier_last_verified_at"] = now

with open(tmp, "w", encoding="utf-8") as fh:
  json.dump(data, fh, ensure_ascii=False, indent=2)
  fh.write("\n")
os.replace(tmp, path)
PY
    rm -f "${tmp}" >/dev/null 2>&1 || true
    return 1
  }
  chmod 600 "${WARP_STATE_FILE}" >/dev/null 2>&1 || true
  rm -f "${tmp}" >/dev/null 2>&1 || true
  return 0
}

cloudflare_warp_repo_configure() {
  local codename="" arch="" key_tmp="" key_gpg_tmp=""
  codename="$(cloudflare_warp_repo_codename_get)"
  arch="$(cloudflare_warp_repo_arch_get)" || return 1
  [[ -n "${codename}" ]] || return 1

  install -d -m 755 /usr/share/keyrings /etc/apt/sources.list.d
  key_tmp="$(mktemp)" || return 1
  key_gpg_tmp="$(mktemp)" || {
    rm -f "${key_tmp}" >/dev/null 2>&1 || true
    return 1
  }

  if ! download_file_checked "${CLOUDFLARE_WARP_KEY_URL}" "${key_tmp}" "Cloudflare WARP signing key"; then
    rm -f "${key_tmp}" "${key_gpg_tmp}" >/dev/null 2>&1 || true
    return 1
  fi
  if ! gpg --yes --dearmor <"${key_tmp}" >"${key_gpg_tmp}"; then
    rm -f "${key_tmp}" "${key_gpg_tmp}" >/dev/null 2>&1 || true
    return 1
  fi

  install -m 0644 "${key_gpg_tmp}" "${CLOUDFLARE_WARP_KEYRING}"
  cat > "${CLOUDFLARE_WARP_LIST_FILE}" <<EOF
deb [arch=${arch} signed-by=${CLOUDFLARE_WARP_KEYRING}] ${CLOUDFLARE_WARP_REPO_URL} ${codename} main
EOF

  rm -f "${key_tmp}" "${key_gpg_tmp}" >/dev/null 2>&1 || true
  return 0
}

install_cloudflare_warp() {
  local active_mode=""
  ok "Pasang Cloudflare WARP client..."

  if ! cloudflare_warp_repo_supported; then
    warn "Repo Cloudflare WARP tidak didukung pada host ini. Backend Zero Trust dilewati tanpa menggagalkan setup."
    return 0
  fi

  export DEBIAN_FRONTEND=noninteractive
  ensure_dpkg_consistent
  apt_get_with_lock_retry install -y ca-certificates curl gpg lsb-release >/dev/null 2>&1 || true

  if ! cloudflare_warp_repo_configure; then
    warn "Gagal menyiapkan repo Cloudflare WARP. Backend Zero Trust dilewati untuk sesi setup ini."
    return 0
  fi
  if ! apt_get_with_lock_retry update -y; then
    warn "APT update untuk repo Cloudflare WARP gagal. Backend Zero Trust dilewati untuk sesi setup ini."
    return 0
  fi
  if ! apt_get_with_lock_retry install -y cloudflare-warp; then
    warn "Paket cloudflare-warp gagal dipasang. Backend Zero Trust tetap opsional dan setup dilanjutkan."
    return 0
  fi

  active_mode="$(cloudflare_warp_mode_state_get)"
  if [[ "${active_mode}" != "zerotrust" ]]; then
    warp-cli --accept-tos disconnect >/dev/null 2>&1 || true
    systemctl disable --now "${WARP_ZEROTRUST_SERVICE}" >/dev/null 2>&1 || true
    ok "cloudflare-warp terpasang. ${WARP_ZEROTRUST_SERVICE} disiapkan dalam keadaan idle sampai mode Zero Trust diaktifkan."
  else
    ok "cloudflare-warp terpasang. Mode Zero Trust sudah tercatat aktif; ${WARP_ZEROTRUST_SERVICE} dibiarkan mengikuti state runtime."
  fi
}

install_wgcf() {
  if command -v wgcf >/dev/null 2>&1; then
    ok "wgcf sudah ada."
    return 0
  fi

  ok "Pasang wgcf..."
  local url tmp
  url="$(wgcf_asset_url)" || die "Asset wgcf belum tersedia untuk arsitektur host ini."
  tmp="$(mktemp)"
  download_file_or_die "${url}" "${tmp}" "" "wgcf ${WGCF_RELEASE_TAG}"
  install -m 0755 "${tmp}" /usr/local/bin/wgcf
  rm -f "${tmp}" >/dev/null 2>&1 || true
  ok "wgcf siap."
}

install_wireproxy() {
  if command -v wireproxy >/dev/null 2>&1; then
    ok "wireproxy sudah ada."
    return 0
  fi

  ok "Pasang wireproxy..."
  local url tmpdir tgz bin
  url="$(wireproxy_asset_url)" || die "Asset wireproxy belum tersedia untuk arsitektur host ini."
  tmpdir="$(mktemp -d)"
  tgz="${tmpdir}/wireproxy.tar.gz"

  download_file_or_die "${url}" "${tgz}" "" "wireproxy ${WIREPROXY_RELEASE_TAG}"
  tar -xzf "$tgz" -C "$tmpdir" >/dev/null 2>&1 || die "Gagal extract wireproxy."
  bin="$(find "$tmpdir" -type f -name wireproxy -print -quit)"
  [[ -n "${bin:-}" && -f "$bin" ]] || die "Binary wireproxy tidak ditemukan setelah extract."
  install -m 755 "$bin" /usr/local/bin/wireproxy

  rm -rf "$tmpdir"
  ok "wireproxy terpasang."
}

install_hysteria2() {
  if [[ -x "${HYSTERIA2_BIN}" ]]; then
    ok "Hysteria 2 sudah ada."
    return 0
  fi

  ok "Pasang Hysteria 2 (spike)..."
  local url tmp
  url="$(hysteria2_asset_url)" || die "Asset Hysteria 2 belum tersedia untuk arsitektur host ini."
  tmp="$(mktemp)"
  download_file_or_die "${url}" "${tmp}" "" "Hysteria 2 latest"
  install -m 0755 "${tmp}" "${HYSTERIA2_BIN}"
  rm -f "${tmp}" >/dev/null 2>&1 || true
  ok "Hysteria 2 terpasang."
}

setup_hysteria2() {
  local port="" existing_port=""

  ok "Siapkan Hysteria 2 (spike)..."
  [[ -x "${HYSTERIA2_BIN}" ]] || die "Binary Hysteria 2 tidak ditemukan: ${HYSTERIA2_BIN}"
  [[ -s "${CERT_FULLCHAIN}" && -s "${CERT_PRIVKEY}" ]] || die "Sertifikat TLS belum siap untuk Hysteria 2."

  if [[ -f "${HYSTERIA2_ENV_FILE}" ]]; then
    existing_port="$(awk -F= '$1=="HYSTERIA2_PORT"{print $2; exit}' "${HYSTERIA2_ENV_FILE}" 2>/dev/null | tr -d '[:space:]' || true)"
  fi
  if [[ "${existing_port}" =~ ^[0-9]+$ ]]; then
    port="${existing_port}"
  else
    port="$(hysteria2_pick_udp_port)"
  fi

  install -d -m 0700 "${HYSTERIA2_ROOT}" "${HYSTERIA2_ACCOUNT_ROOT}"
  cat > "${HYSTERIA2_ENV_FILE}" <<EOF
HYSTERIA2_PORT=${port}
HYSTERIA2_MASQUERADE_URL=${HYSTERIA2_MASQUERADE_URL}
EOF
  chmod 600 "${HYSTERIA2_ENV_FILE}" >/dev/null 2>&1 || true

  install_setup_bin_or_die "hysteria2-manage.py" "${HYSTERIA2_MANAGE_BIN}" 0755
  install_setup_bin_or_die "hysteria2-expired.py" "${HYSTERIA2_EXPIRED_BIN}" 0755
  "${HYSTERIA2_MANAGE_BIN}" ensure-runtime || die "Gagal menyiapkan runtime Hysteria 2."

  render_setup_template_or_die \
    "systemd/hysteria2.service" \
    "/etc/systemd/system/${HYSTERIA2_SERVICE}" \
    0644 \
    "HYSTERIA2_BIN=${HYSTERIA2_BIN}" \
    "HYSTERIA2_CONFIG_FILE=${HYSTERIA2_CONFIG_FILE}"
  render_setup_template_or_die \
    "systemd/hysteria2-expired.service" \
    "/etc/systemd/system/${HYSTERIA2_EXPIRED_SERVICE}" \
    0644 \
    "HYSTERIA2_EXPIRED_BIN=${HYSTERIA2_EXPIRED_BIN}" \
    "HYSTERIA2_MANAGE_BIN=${HYSTERIA2_MANAGE_BIN}" \
    "HYSTERIA2_SERVICE_NAME=${HYSTERIA2_SERVICE}" \
    "HYSTERIA2_EXPIRED_INTERVAL=${HYSTERIA2_EXPIRED_INTERVAL}"

  systemctl daemon-reload
  service_enable_restart_checked "${HYSTERIA2_SERVICE}" || die "Hysteria 2 gagal diaktifkan. Cek: journalctl -u ${HYSTERIA2_SERVICE} -n 100 --no-pager"
  service_enable_restart_checked "${HYSTERIA2_EXPIRED_SERVICE}" || die "Auto expired Hysteria 2 gagal diaktifkan. Cek: journalctl -u ${HYSTERIA2_EXPIRED_SERVICE} -n 100 --no-pager"
  ok "Hysteria 2 aktif di UDP port ${port}."
}

setup_wgcf() {
  ok "Siapkan wgcf..."

  mkdir -p /etc/wgcf

  # Jika /etc/wgcf pernah menjadi file, pindahkan agar tidak bikin exit diam-diam saat pushd.
  if [[ -e /etc/wgcf && ! -d /etc/wgcf ]]; then
    mv -f /etc/wgcf "/etc/wgcf.bak.$(date +%s)" || true
    mkdir -p /etc/wgcf
  fi

  pushd /etc/wgcf >/dev/null || die "Gagal masuk ke /etc/wgcf."

  if [[ ! -f wgcf-account.toml ]]; then
    local reg_log
    reg_log="$(mktemp "/tmp/wgcf-register.XXXXXX.log")"

    # wgcf versi baru kadang pakai prompt berbasis TTY (arrow-keys). `yes |` sering tidak efektif.
    if command -v expect >/dev/null 2>&1; then
      expect <<'EOF' >"$reg_log" 2>&1 || true
set timeout 180
log_user 1
spawn wgcf register
# Coba accept prompt dengan Enter / y
expect {
  -re {Use the arrow keys.*} { send "\r"; exp_continue }
  -re {Do you agree.*} { send "\r"; exp_continue }
  -re {\(y/n\)} { send "y\r"; exp_continue }
  -re {Yes/No} { send "\r"; exp_continue }
  -re {accept} { send "\r"; exp_continue }
  eof
}
EOF
    else
      # Fallback kompatibilitas (lebih rentan), tapi tetap kita log.
      set +o pipefail
      yes | wgcf register >"$reg_log" 2>&1 || true
      set -o pipefail
    fi

    [[ -f wgcf-account.toml ]] || {
      tail -n 120 "$reg_log" >&2 || true
      die "wgcf register gagal. Lihat log: $reg_log"
    }
    rm -f "$reg_log" >/dev/null 2>&1 || true
  fi

  local gen_log
  gen_log="$(mktemp "/tmp/wgcf-generate.XXXXXX.log")"
  wgcf generate >"$gen_log" 2>&1 || {
    tail -n 120 "$gen_log" >&2 || true
    die "wgcf generate gagal. Lihat log: $gen_log"
  }
  [[ -f wgcf-profile.conf ]] || {
    tail -n 120 "$gen_log" >&2 || true
    die "wgcf-profile.conf tidak ditemukan setelah generate."
  }
  rm -f "$gen_log" >/dev/null 2>&1 || true

  popd >/dev/null || die "Gagal kembali dari /etc/wgcf."
  ok "wgcf siap."
}

setup_wireproxy() {
  local active_mode=""
  ok "Siapkan wireproxy..."

  mkdir -p /etc/wireproxy
  cp -f /etc/wgcf/wgcf-profile.conf "${WIREPROXY_CONF}"

  # wireproxy v1.0.9 memakai section [Socks5], bukan [Socks].
  # Rebuild section SOCKS agar idempotent dan menghindari salah format kompatibilitas.
  local wp_conf="${WIREPROXY_CONF}"
  local wp_tmp
  wp_tmp="$(mktemp)"
  awk '
    BEGIN { drop=0 }
    /^\[(Socks|Socks5)\]$/ { drop=1; next }
    /^\[.*\]$/ { drop=0 }
    drop { next }
    { print }
  ' "$wp_conf" > "$wp_tmp"
  cat >> "$wp_tmp" <<'EOF'

[Socks5]
BindAddress = 127.0.0.1:40000
EOF
  install -m 600 "$wp_tmp" "$wp_conf"
  rm -f "$wp_tmp"

  render_setup_template_or_die \
    "systemd/wireproxy.service" \
    "/etc/systemd/system/wireproxy.service" \
    0644

  systemctl daemon-reload
  active_mode="$(cloudflare_warp_mode_state_get 2>/dev/null || true)"
  if [[ "${active_mode}" == "zerotrust" ]]; then
    if command -v warp-cli >/dev/null 2>&1; then
      warp-cli --accept-tos connect >/dev/null 2>&1 || true
    fi
    systemctl disable --now wireproxy >/dev/null 2>&1 || systemctl stop wireproxy >/dev/null 2>&1 || true
    systemctl reset-failed wireproxy >/dev/null 2>&1 || true
    ok "wireproxy siap dalam keadaan idle karena mode runtime WARP saat ini adalah Zero Trust."
    return 0
  fi

  if systemctl list-unit-files "${WARP_ZEROTRUST_SERVICE}" >/dev/null 2>&1 && systemctl is-active --quiet "${WARP_ZEROTRUST_SERVICE}"; then
    if command -v warp-cli >/dev/null 2>&1; then
      warp-cli --accept-tos disconnect >/dev/null 2>&1 || true
    fi
    systemctl disable --now "${WARP_ZEROTRUST_SERVICE}" >/dev/null 2>&1 || systemctl stop "${WARP_ZEROTRUST_SERVICE}" >/dev/null 2>&1 || true
  fi

  service_enable_restart_checked wireproxy || die "wireproxy gagal diaktifkan. Cek: journalctl -u wireproxy -n 100 --no-pager"
  if cloudflare_warp_seed_free_plus_state_if_missing; then
    ok "state WARP Free/Plus disiapkan: Free."
  else
    warn "Gagal inisialisasi state WARP Free/Plus; main menu mungkin sementara hanya menampilkan Active."
  fi
  ok "wireproxy aktif."
}

warp_zero_trust_config_upsert_key() {
  local file="$1"
  local key="$2"
  local value="$3"
  local tmp=""
  tmp="$(mktemp)" || return 1
  python3 - <<'PY' "${file}" "${tmp}" "${key}" "${value}" || {
import pathlib
import sys

src = pathlib.Path(sys.argv[1])
dst = pathlib.Path(sys.argv[2])
target_key = sys.argv[3]
target_value = sys.argv[4]

lines = []
if src.exists():
  try:
    lines = src.read_text(encoding="utf-8").splitlines()
  except Exception:
    lines = []

out = []
seen = False
for line in lines:
  stripped = line.strip()
  if not stripped or stripped.startswith("#") or "=" not in line:
    out.append(line)
    continue
  key, _ = line.split("=", 1)
  key = key.strip()
  if key == target_key:
    out.append(f"{target_key}={target_value}")
    seen = True
  else:
    out.append(line)

if not seen:
  out.append(f"{target_key}={target_value}")

dst.write_text("\n".join(out).rstrip("\n") + "\n", encoding="utf-8")
PY
    rm -f "${tmp}" >/dev/null 2>&1 || true
    return 1
  }
  install -m 0600 "${tmp}" "${file}"
  rm -f "${tmp}" >/dev/null 2>&1 || true
  return 0
}

setup_warp_zero_trust_backend() {
  ok "Siapkan backend Zero Trust..."

  install -d -m 700 "${WARP_ZEROTRUST_ROOT}" "$(dirname "${WARP_ZEROTRUST_MDM_FILE}")"
  if [[ ! -f "${WARP_ZEROTRUST_CONFIG_FILE}" ]]; then
    render_setup_template_or_die \
      "config/warp-zerotrust.env" \
      "${WARP_ZEROTRUST_CONFIG_FILE}" \
      0600 \
      "WARP_ZEROTRUST_PROXY_PORT=${WARP_ZEROTRUST_PROXY_PORT}"
  fi

  chmod 600 "${WARP_ZEROTRUST_CONFIG_FILE}" >/dev/null 2>&1 || true
  warp_zero_trust_config_upsert_key "${WARP_ZEROTRUST_CONFIG_FILE}" "WARP_ZEROTRUST_PROXY_PORT" "${WARP_ZEROTRUST_PROXY_PORT}" \
    || die "Gagal menormalkan config Zero Trust: ${WARP_ZEROTRUST_CONFIG_FILE}"

  if ! grep -q '^WARP_ZEROTRUST_TEAM=' "${WARP_ZEROTRUST_CONFIG_FILE}" 2>/dev/null; then
    printf 'WARP_ZEROTRUST_TEAM=\n' >> "${WARP_ZEROTRUST_CONFIG_FILE}"
  fi
  if ! grep -q '^WARP_ZEROTRUST_CLIENT_ID=' "${WARP_ZEROTRUST_CONFIG_FILE}" 2>/dev/null; then
    printf 'WARP_ZEROTRUST_CLIENT_ID=\n' >> "${WARP_ZEROTRUST_CONFIG_FILE}"
  fi
  if ! grep -q '^WARP_ZEROTRUST_CLIENT_SECRET=' "${WARP_ZEROTRUST_CONFIG_FILE}" 2>/dev/null; then
    printf 'WARP_ZEROTRUST_CLIENT_SECRET=\n' >> "${WARP_ZEROTRUST_CONFIG_FILE}"
  fi
  chmod 600 "${WARP_ZEROTRUST_CONFIG_FILE}" >/dev/null 2>&1 || true
  [[ -f "${WARP_ZEROTRUST_MDM_FILE}" ]] && chmod 600 "${WARP_ZEROTRUST_MDM_FILE}" >/dev/null 2>&1 || true

  if command -v warp-cli >/dev/null 2>&1; then
    ok "Backend Zero Trust siap. Isi credential di ${WARP_ZEROTRUST_CONFIG_FILE} lalu aktifkan lewat menu manage bila diperlukan."
  else
    warn "warp-cli belum tersedia. Skeleton backend Zero Trust sudah dibuat, tetapi paket cloudflare-warp belum terpasang."
  fi
}

xray_warp_interface_name_default() {
  local iface="${XRAY_WARP_INTERFACE:-warp-xray0}"
  if [[ ! "${iface}" =~ ^[a-zA-Z0-9._-]{1,15}$ ]]; then
    iface="warp-xray0"
  fi
  printf '%s\n' "${iface}"
}

xray_warp_config_path() {
  local iface="${1:-}"
  [[ -n "${iface}" ]] || return 1
  printf '%s/%s.conf\n' "${WIREGUARD_DIR:-/etc/wireguard}" "${iface}"
}

setup_xray_warp_interface() {
  local iface="" conf_path="" unit=""

  ok "Siapkan Xray WARP interface..."
  [[ -s "${WIREPROXY_CONF}" ]] || die "Source config WARP host tidak ditemukan: ${WIREPROXY_CONF}"
  command -v python3 >/dev/null 2>&1 || die "python3 tidak ditemukan untuk Xray WARP."
  command -v wg-quick >/dev/null 2>&1 || die "wg-quick tidak ditemukan. Pastikan wireguard-tools terpasang."

  iface="$(xray_warp_interface_name_default)"
  conf_path="$(xray_warp_config_path "${iface}")" || die "Nama interface Xray WARP tidak valid."

  install_setup_bin_or_die "xray-warp-sync.py" "${XRAY_WARP_SYNC_BIN}" 0755
  install -d -m 700 "${WIREGUARD_DIR:-/etc/wireguard}"
  "${XRAY_WARP_SYNC_BIN}" --interface "${iface}" --source "${WIREPROXY_CONF}" --dest-dir "${WIREGUARD_DIR:-/etc/wireguard}" \
    || die "Gagal menyiapkan config Xray WARP untuk ${iface}."

  unit="wg-quick@${iface}"
  if systemctl is-active --quiet "${unit}" >/dev/null 2>&1; then
    if service_enable_restart_checked "${unit}"; then
      ok "Xray WARP interface aktif dan disegarkan: ${iface}"
    else
      warn "Xray WARP config diperbarui, tetapi restart ${unit} gagal."
    fi
  else
    systemctl disable --now "${unit}" >/dev/null 2>&1 || true
    ok "Xray WARP config siap: ${conf_path}"
  fi
}

cleanup_wgcf_files() {
  ok "Bersihkan file wgcf..."

  rm -f /etc/wgcf/wgcf-profile.conf /etc/wgcf/wgcf-account.toml || true
  ok "Cleanup wgcf siap."
}

enable_cron_service() {
  ok "Aktifkan cron..."

  if service_enable_restart_checked cron; then
    :
  elif service_enable_restart_checked crond; then
    :
  else
    die "Gagal mengaktifkan cron maupun crond."
  fi

  ok "cron aktif."
}
