#!/usr/bin/env bash
# Bootstrap/install groundwork module for setup runtime.

check_os() {
  [[ -f /etc/os-release ]] || die "Tidak menemukan /etc/os-release"
  # shellcheck disable=SC1091
  . /etc/os-release

  local id="${ID:-}"
  local ver="${VERSION_ID:-}"
  local codename="${VERSION_CODENAME:-}"

  # Gunakan awk agar check_os tetap bisa dipanggil sebelum python3 dipasang.
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

wait_for_dpkg_lock() {
  local timeout=300
  local waited=0
  local step=3
  local lock_files=(
    /var/lib/dpkg/lock-frontend
    /var/lib/dpkg/lock
    /var/lib/apt/lists/lock
    /var/cache/apt/archives/lock
  )

  command -v fuser >/dev/null 2>&1 || return 0

  while true; do
    local busy=0
    local lf
    for lf in "${lock_files[@]}"; do
      if [[ -e "${lf}" ]] && fuser "${lf}" >/dev/null 2>&1; then
        busy=1
        break
      fi
    done

    if [[ "${busy}" -eq 0 ]]; then
      return 0
    fi
    if (( waited >= timeout )); then
      return 1
    fi

    sleep "${step}"
    waited=$((waited + step))
  done
}

apt_get_with_lock_retry() {
  local max_attempts=8
  local attempt=1
  local tmp rc

  while (( attempt <= max_attempts )); do
    wait_for_dpkg_lock || true
    tmp="$(mktemp)"
    set +e
    apt-get "$@" >"${tmp}" 2>&1
    rc=$?
    set -e
    cat "${tmp}"
    if (( rc == 0 )); then
      rm -f "${tmp}" >/dev/null 2>&1 || true
      return 0
    fi

    if grep -qiE "Could not get lock|Unable to acquire the dpkg frontend lock|Unable to lock the administration directory" "${tmp}"; then
      warn "APT lock masih dipakai proses lain. Retry ${attempt}/${max_attempts} ..."
      rm -f "${tmp}" >/dev/null 2>&1 || true
      sleep 3
      attempt=$((attempt + 1))
      continue
    fi

    rm -f "${tmp}" >/dev/null 2>&1 || true
    return "${rc}"
  done

  return 1
}

ensure_dpkg_consistent() {
  wait_for_dpkg_lock || die "Timeout menunggu lock dpkg/apt."

  local audit
  audit="$(dpkg --audit 2>/dev/null || true)"
  if [[ -n "${audit//[[:space:]]/}" ]]; then
    warn "Status dpkg tidak konsisten. Menjalankan pemulihan: dpkg --configure -a"
    dpkg --configure -a || die "Gagal memulihkan status dpkg."
  fi

  apt_get_with_lock_retry -f install -y >/dev/null 2>&1 || true
}

install_base_deps() {
  export DEBIAN_FRONTEND=noninteractive
  ensure_dpkg_consistent
  apt_get_with_lock_retry update -y
  apt_get_with_lock_retry install -y curl ca-certificates unzip openssl socat cron gpg lsb-release python3 iproute2 jq dnsutils
  ok "Dependency dasar terpasang."
}

install_extra_deps() {
  export DEBIAN_FRONTEND=noninteractive

  # Hindari warning dpkg-statoverride saat install chrony di beberapa distro.
  mkdir -p /var/log/chrony

  ensure_dpkg_consistent
  apt_get_with_lock_retry install -y jq fail2ban chrony tar expect logrotate nftables dropbear dnsmasq-base wireguard-tools openvpn easy-rsa

  if command -v stunnel4 >/dev/null 2>&1 || command -v stunnel >/dev/null 2>&1; then
    ok "Dependency tambahan terpasang (jq, fail2ban, chrony, expect, logrotate, nftables, dropbear, dnsmasq-base, openvpn, easy-rsa; stunnel sudah tersedia)."
    return 0
  fi
  if apt_get_with_lock_retry install -y stunnel4 >/dev/null 2>&1 || apt_get_with_lock_retry install -y stunnel >/dev/null 2>&1; then
    ok "Dependency tambahan terpasang (jq, fail2ban, chrony, expect, logrotate, nftables, dropbear, dnsmasq-base, openvpn, easy-rsa; stunnel opsional tersedia)."
  else
    warn "Paket stunnel tidak tersedia di repo distro. Layanan sshws-stunnel akan dilewati (opsional)."
    ok "Dependency tambahan terpasang (jq, fail2ban, chrony, expect, logrotate, nftables, dropbear, dnsmasq-base, openvpn, easy-rsa)."
  fi
}

install_speedtest_snap() {
  ok "Install speedtest via snap..."

  if command -v speedtest >/dev/null 2>&1; then
    ok "speedtest sudah tersedia: $(command -v speedtest)"
    return 0
  fi

  export DEBIAN_FRONTEND=noninteractive
  if ! command -v snap >/dev/null 2>&1; then
    apt-get install -y snapd || die "Gagal install snapd."
  fi

  systemctl enable --now snapd.socket >/dev/null 2>&1 || true
  systemctl enable --now snapd.service >/dev/null 2>&1 || true

  if [[ ! -e /snap ]]; then
    ln -s /var/lib/snapd/snap /snap >/dev/null 2>&1 || true
  fi

  export PATH="${PATH}:/snap/bin"

  for _ in {1..15}; do
    if snap version >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
  snap version >/dev/null 2>&1 || die "snapd belum siap. Cek: systemctl status snapd --no-pager"

  if ! snap list speedtest >/dev/null 2>&1; then
    snap install speedtest || die "Gagal install speedtest via snap."
  fi

  hash -r || true
  if command -v speedtest >/dev/null 2>&1 || [[ -x /snap/bin/speedtest ]]; then
    ok "speedtest terpasang via snap."
  else
    warn "speedtest terpasang, namun binary belum ada di PATH shell saat ini. Gunakan /snap/bin/speedtest."
  fi
}
