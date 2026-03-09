#!/usr/bin/env bash
# Network/runtime tuning module for setup runtime.

WGCF_RELEASE_TAG="${WGCF_RELEASE_TAG:-v2.2.30}"
WGCF_RELEASE_VERSION="${WGCF_RELEASE_VERSION:-2.2.30}"
WIREPROXY_RELEASE_TAG="${WIREPROXY_RELEASE_TAG:-v1.1.2}"

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

[sshd]
enabled  = true
port     = ssh
mode     = aggressive
# sshd log ke systemd journal di distro modern, override backend khusus untuk jail ini.
backend  = systemd
logpath  = %(sshd_log)s
maxretry = 3
findtime = 10m
bantime  = 1d

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
  ok "Siapkan wireproxy..."

  mkdir -p /etc/wireproxy
  cp -f /etc/wgcf/wgcf-profile.conf /etc/wireproxy/config.conf

  # wireproxy v1.0.9 memakai section [Socks5], bukan [Socks].
  # Rebuild section SOCKS agar idempotent dan menghindari salah format kompatibilitas.
  local wp_conf="/etc/wireproxy/config.conf"
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
  service_enable_restart_checked wireproxy || die "wireproxy gagal diaktifkan. Cek: journalctl -u wireproxy -n 100 --no-pager"
  ok "wireproxy aktif."
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
