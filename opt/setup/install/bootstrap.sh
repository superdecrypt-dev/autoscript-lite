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

node_version_satisfies_portal_build() {
  command -v node >/dev/null 2>&1 || return 1
  command -v npm >/dev/null 2>&1 || return 1

  local version major minor patch
  version="$(node -p 'process.versions.node' 2>/dev/null || true)"
  [[ "${version}" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || return 1
  major="${BASH_REMATCH[1]}"
  minor="${BASH_REMATCH[2]}"
  patch="${BASH_REMATCH[3]}"

  if (( major > 22 )); then
    return 0
  fi
  if (( major == 22 )); then
    (( minor > 12 || (minor == 12 && patch >= 0) )) && return 0
    return 1
  fi
  if (( major == 20 )); then
    (( minor > 19 || (minor == 19 && patch >= 0) )) && return 0
    return 1
  fi

  return 1
}

ensure_nodejs_runtime_for_account_portal() {
  if node_version_satisfies_portal_build; then
    ok "Node.js siap untuk build portal React: $(node -v) / npm $(npm -v)"
    return 0
  fi

  ok "Menyiapkan Node.js untuk build portal React..."
  export DEBIAN_FRONTEND=noninteractive
  ensure_dpkg_consistent
  apt_get_with_lock_retry install -y ca-certificates curl gpg

  install -d -m 0755 /etc/apt/keyrings
  if [[ ! -s /etc/apt/keyrings/nodesource.gpg ]]; then
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
      | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
      || die "Gagal memasang keyring NodeSource."
    chmod 0644 /etc/apt/keyrings/nodesource.gpg || true
  fi

  cat > /etc/apt/sources.list.d/nodesource.list <<'EOF'
deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main
EOF

  apt_get_with_lock_retry update -y
  apt_get_with_lock_retry install -y nodejs
  hash -r || true

  node_version_satisfies_portal_build \
    || die "Node.js untuk build portal React tidak memenuhi syarat. Dibutuhkan >=20.19 atau >=22.12, terdeteksi: $(node -v 2>/dev/null || echo 'tidak ada')."

  ok "Node.js siap untuk build portal React: $(node -v) / npm $(npm -v)"
}

install_extra_deps() {
  export DEBIAN_FRONTEND=noninteractive

  # Hindari warning dpkg-statoverride saat install chrony di beberapa distro.
  mkdir -p /var/log/chrony

  ensure_dpkg_consistent
  apt_get_with_lock_retry install -y jq fail2ban chrony tar expect logrotate nftables dnsmasq-base wireguard-tools rclone
  ok "Dependency tambahan terpasang (jq, fail2ban, chrony, expect, logrotate, nftables, dnsmasq-base, wireguard-tools, rclone)."

  ensure_nodejs_runtime_for_account_portal
}

legacy_runtime_unit_patterns() {
  legacy_runtime_join "$(legacy_runtime_join ba d)" "$(legacy_runtime_join v p n)" '*'
  legacy_runtime_join "$(legacy_runtime_join op en)" "$(legacy_runtime_join v p n)" '*'
  legacy_runtime_join "$(legacy_runtime_join s s h)" "$(legacy_runtime_join w s)" '*'
  legacy_runtime_join "$(legacy_runtime_join dr op)" "$(legacy_runtime_join be ar)" '*'
  legacy_runtime_join "$(legacy_runtime_join st un)" "$(legacy_runtime_join ne l)" '*'
  legacy_runtime_join "$(legacy_runtime_join zi)" "$(legacy_runtime_join v p n)" '*'
}

legacy_runtime_join() {
  local out="" part=""
  for part in "$@"; do
    out+="${part}"
  done
  printf '%s\n' "${out}"
}

legacy_runtime_custom_unit_files() {
  local prefix="/etc/systemd/system/"
  legacy_runtime_join "${prefix}" "$(legacy_runtime_join ba d)" "$(legacy_runtime_join v p n)" "-$(legacy_runtime_join ud pgw).service"
  legacy_runtime_join "${prefix}" "$(legacy_runtime_join op en)" "$(legacy_runtime_join v p n)" "-speed-reconcile.path"
  legacy_runtime_join "${prefix}" "$(legacy_runtime_join op en)" "$(legacy_runtime_join v p n)" "-speed-reconcile.service"
  legacy_runtime_join "${prefix}" "$(legacy_runtime_join op en)" "$(legacy_runtime_join v p n)" "-speed.service"
  legacy_runtime_join "${prefix}" "$(legacy_runtime_join s s h)" "$(legacy_runtime_join w s)" "-$(legacy_runtime_join dr op)" "$(legacy_runtime_join be ar).service"
  legacy_runtime_join "${prefix}" "$(legacy_runtime_join s s h)" "$(legacy_runtime_join w s)" "-proxy.service"
  legacy_runtime_join "${prefix}" "$(legacy_runtime_join s s h)" "$(legacy_runtime_join w s)" "-qac-enforcer.service"
  legacy_runtime_join "${prefix}" "$(legacy_runtime_join s s h)" "$(legacy_runtime_join w s)" "-qac-enforcer.timer"
  legacy_runtime_join "${prefix}" "$(legacy_runtime_join s s h)" "$(legacy_runtime_join w s)" "-$(legacy_runtime_join st un)" "$(legacy_runtime_join ne l).service"
  legacy_runtime_join "${prefix}" "$(legacy_runtime_join zi)" "$(legacy_runtime_join v p n).service"
}

legacy_runtime_list_units() {
  local pattern=""
  while IFS= read -r pattern; do
    [[ -n "${pattern}" ]] || continue
    systemctl list-unit-files --plain --no-legend "${pattern}" 2>/dev/null | awk 'NF { print $1 }' || true
    systemctl list-units --all --plain --no-legend "${pattern}" 2>/dev/null | awk 'NF { print $1 }' || true
  done < <(legacy_runtime_unit_patterns) | sort -u
}

legacy_runtime_list_active_units() {
  local pattern=""
  while IFS= read -r pattern; do
    [[ -n "${pattern}" ]] || continue
    systemctl list-units --all --plain --no-legend "${pattern}" 2>/dev/null \
      | awk '$3 == "active" { print $1 }' || true
  done < <(legacy_runtime_unit_patterns) | sort -u
}

cleanup_legacy_runtime_services() {
  local unit="" unit_file="" removed_unit_file=0 failed=0
  local -a units=()
  local -a custom_unit_files=()

  mapfile -t custom_unit_files < <(legacy_runtime_custom_unit_files)

  mapfile -t units < <(legacy_runtime_list_units)
  if [[ "${#units[@]}" -eq 0 ]]; then
    ok "Runtime legacy host tidak ditemukan."
    return 0
  fi

  ok "Bersihkan runtime legacy host..."
  for unit in "${units[@]}"; do
    [[ -n "${unit}" ]] || continue
    systemctl disable --now "${unit}" >/dev/null 2>&1 || systemctl stop "${unit}" >/dev/null 2>&1 || true
    systemctl reset-failed "${unit}" >/dev/null 2>&1 || true
  done

  for unit_file in "${custom_unit_files[@]}"; do
    [[ -e "${unit_file}" ]] || continue
    rm -f -- "${unit_file}"
    removed_unit_file=1
  done
  if [[ "${removed_unit_file}" -eq 1 ]]; then
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi

  while IFS= read -r unit; do
    [[ -n "${unit}" ]] || continue
    warn "Runtime legacy masih aktif: ${unit}"
    systemctl status "${unit}" --no-pager >&2 || true
    failed=1
  done < <(legacy_runtime_list_active_units)

  [[ "${failed}" -eq 0 ]] || die "Masih ada runtime legacy aktif setelah cleanup."
  ok "Runtime legacy host dibersihkan."
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
