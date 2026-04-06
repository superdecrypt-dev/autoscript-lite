#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd -P)"

log() {
  printf '[test-adblock-upgrade] %s\n' "$*"
}

fail() {
  printf '[test-adblock-upgrade] FAIL: %s\n' "$*" >&2
  exit 1
}

assert_file_contains() {
  local file="$1"
  local pattern="$2"
  grep -Fqx -- "${pattern}" "${file}" || fail "expected ${file} to contain: ${pattern}"
}

setup_management_under_test() {
  local mgmt_src="$1"
  local mgmt_dst="$2"
  local legacy_root="$3"
  local systemd_dir="$4"

  python3 - "${mgmt_src}" "${mgmt_dst}" "${legacy_root}" "${systemd_dir}" <<'PY'
from pathlib import Path
import sys

src = Path(sys.argv[1]).read_text(encoding="utf-8")
legacy_root = sys.argv[3]
systemd_dir = sys.argv[4].rstrip("/")
src = src.replace("/etc/autoscript/ssh-adblock", legacy_root)
src = src.replace('"/etc/systemd/system/', f'"{systemd_dir}/')
Path(sys.argv[2]).write_text(src, encoding="utf-8")
PY
}

run_migration_success_case() {
  local tmp legacy_root new_root systemd_dir mgmt_under_test
  tmp="$(mktemp -d)"
  legacy_root="${tmp}/legacy-adblock"
  new_root="${tmp}/adblock"
  systemd_dir="${tmp}/systemd"
  mgmt_under_test="${tmp}/management-under-test.sh"

  mkdir -p "${legacy_root}" "${systemd_dir}"
  printf 'legacy-blocked\n' > "${legacy_root}/blocked.domains"
  printf 'https://example.invalid/list.txt\n' > "${legacy_root}/source.urls"
  printf 'legacy-merged\n' > "${legacy_root}/merged.domains"
  printf 'address=/legacy.example/0.0.0.0\n' > "${legacy_root}/blocklist.generated.conf"
  cat > "${legacy_root}/config.env" <<'EOF'
AUTOSCRIPT_ADBLOCK_ENABLED=1
AUTOSCRIPT_ADBLOCK_DIRTY=1
AUTOSCRIPT_ADBLOCK_LAST_UPDATE=2026-04-06 11:22:33 UTC
EOF
  : > "${systemd_dir}/ssh-adblock-dns.service"
  : > "${systemd_dir}/ssh-adblock-sync.service"
  : > "${systemd_dir}/ssh-adblock-update.service"
  : > "${systemd_dir}/ssh-adblock-update.timer"

  setup_management_under_test \
    "${ROOT_DIR}/opt/setup/install/management.sh" \
    "${mgmt_under_test}" \
    "${legacy_root}" \
    "${systemd_dir}"

  export TEST_STATE_DIR="${tmp}/state"
  export TEST_SYSTEMD_DIR="${systemd_dir}"
  export TEST_SYNC_EXIT_CODE=0
  export TEST_SYNC_ACTIVATES_DNS=1
  mkdir -p "${TEST_STATE_DIR}"

  # shellcheck disable=SC1090
  source "${mgmt_under_test}"

  TEST_DIE_CALLED=0
  ok() { :; }
  warn() { :; }
  die() { TEST_DIE_CALLED=1; printf '%s\n' "$*" >&2; return 1; }
  systemctl() {
    local action="${1:-}"
    local service="${*: -1}"
    case "${action}" in
      disable|reset-failed|daemon-reload|enable|status)
        return 0
        ;;
      is-active)
        [[ -f "${TEST_STATE_DIR}/${service}.active" ]]
        ;;
      start|restart)
        touch "${TEST_STATE_DIR}/${service}.active"
        return 0
        ;;
      *)
        return 0
        ;;
    esac
  }
  pgrep() { return 1; }
  pkill() { return 0; }
  journalctl() { return 0; }
  install_repo_asset_or_die() {
    local _src_rel="$1"
    local dst="$2"
    local mode="${3:-0755}"
    mkdir -p "$(dirname "${dst}")"
    cat > "${dst}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--apply" ]]; then
  if [[ "${TEST_SYNC_ACTIVATES_DNS:-1}" == "1" ]]; then
    : > "${TEST_STATE_DIR}/${ADBLOCK_DNS_SERVICE}.active"
  fi
  exit "${TEST_SYNC_EXIT_CODE:-0}"
fi
exit 0
EOF
    chmod "${mode}" "${dst}"
  }
  render_setup_template_or_die() {
    local rel="$1"
    local dst="$2"
    local mode="${3:-0644}"
    shift 3
    mkdir -p "$(dirname "${dst}")"
    python3 - "${ROOT_DIR}/opt/setup/templates/${rel}" "${dst}" "${mode}" "$@" <<'PY'
import os
import re
import sys
from pathlib import Path

src, dst, mode, *items = sys.argv[1:]
text = Path(src).read_text(encoding="utf-8")
for item in items:
    key, value = item.split("=", 1)
    text = text.replace(f"__{key}__", value)
missing = sorted(set(re.findall(r"__([A-Z0-9_]+)__", text)))
if missing:
    raise SystemExit(f"unresolved placeholders: {', '.join(missing)}")
Path(dst).write_text(text, encoding="utf-8")
os.chmod(dst, int(mode, 8))
PY
  }

  export \
    ADBLOCK_ROOT="${new_root}" \
    ADBLOCK_CONFIG_FILE="${new_root}/config.env" \
    ADBLOCK_BLOCKLIST_FILE="${new_root}/blocked.domains" \
    ADBLOCK_URLS_FILE="${new_root}/source.urls" \
    ADBLOCK_MERGED_FILE="${new_root}/merged.domains" \
    ADBLOCK_RENDERED_FILE="${new_root}/blocklist.generated.conf" \
    ADBLOCK_DNSMASQ_CONF="${new_root}/dnsmasq.conf" \
    ADBLOCK_DNS_SERVICE="adblock-dns.service" \
    ADBLOCK_SYNC_SERVICE="adblock-sync.service" \
    ADBLOCK_SYNC_BIN="${tmp}/bin/adblock-sync" \
    ADBLOCK_AUTO_UPDATE_SERVICE="adblock-update.service" \
    ADBLOCK_AUTO_UPDATE_TIMER="adblock-update.timer" \
    ADBLOCK_AUTO_UPDATE_DAYS="1" \
    ADBLOCK_RUNTIME_USER="xray" \
    ADBLOCK_NFT_TABLE="autoscript_adblock" \
    ADBLOCK_PORT="5353" \
    CUSTOM_GEOSITE_DEST="${tmp}/custom.dat" \
    TEST_STATE_DIR

  install_adblock_runtime
  [[ "${TEST_DIE_CALLED}" -eq 0 ]] || fail "unexpected die during successful migration case"

  [[ ! -d "${legacy_root}" ]] || fail "legacy adblock root should be removed"
  [[ -f "${new_root}/blocked.domains" ]] || fail "blocked.domains was not migrated"
  [[ -f "${new_root}/source.urls" ]] || fail "source.urls was not migrated"
  [[ -f "${new_root}/merged.domains" ]] || fail "merged.domains was not migrated"
  [[ -f "${new_root}/blocklist.generated.conf" ]] || fail "rendered file was not migrated"
  assert_file_contains "${new_root}/blocked.domains" "legacy-blocked"
  assert_file_contains "${new_root}/source.urls" "https://example.invalid/list.txt"
  assert_file_contains "${new_root}/merged.domains" "legacy-merged"
  assert_file_contains "${new_root}/config.env" "AUTOSCRIPT_ADBLOCK_ENABLED=1"
  assert_file_contains "${new_root}/config.env" "AUTOSCRIPT_ADBLOCK_DIRTY=1"
  assert_file_contains "${new_root}/config.env" "AUTOSCRIPT_ADBLOCK_LAST_UPDATE=2026-04-06 11:22:33 UTC"
  [[ -f "${TEST_STATE_DIR}/adblock-dns.service.active" ]] || fail "dns service was not marked active"
  [[ ! -f "${systemd_dir}/ssh-adblock-dns.service" ]] || fail "legacy dns unit should be removed"
  [[ -f "${systemd_dir}/adblock-dns.service" ]] || fail "new dns unit should be rendered"
}

run_fail_fast_case() {
  local tmp legacy_root new_root systemd_dir mgmt_under_test rc
  tmp="$(mktemp -d)"
  legacy_root="${tmp}/legacy-adblock"
  new_root="${tmp}/adblock"
  systemd_dir="${tmp}/systemd"
  mgmt_under_test="${tmp}/management-under-test.sh"

  mkdir -p "${legacy_root}" "${systemd_dir}"
  setup_management_under_test \
    "${ROOT_DIR}/opt/setup/install/management.sh" \
    "${mgmt_under_test}" \
    "${legacy_root}" \
    "${systemd_dir}"

  export TEST_STATE_DIR="${tmp}/state"
  export TEST_SYSTEMD_DIR="${systemd_dir}"
  export TEST_SYNC_EXIT_CODE=1
  export TEST_SYNC_ACTIVATES_DNS=0
  mkdir -p "${TEST_STATE_DIR}"

  # shellcheck disable=SC1090
  source "${mgmt_under_test}"

  TEST_DIE_CALLED=0
  ok() { :; }
  warn() { :; }
  die() { TEST_DIE_CALLED=1; printf '%s\n' "$*" >&2; return 1; }
  systemctl() {
    local action="${1:-}"
    local service="${*: -1}"
    case "${action}" in
      disable|reset-failed|daemon-reload|enable|status)
        return 0
        ;;
      is-active)
        [[ -f "${TEST_STATE_DIR}/${service}.active" ]]
        ;;
      start|restart)
        if [[ "${TEST_SYNC_ACTIVATES_DNS:-0}" == "1" ]]; then
          touch "${TEST_STATE_DIR}/${service}.active"
        fi
        return 0
        ;;
      *)
        return 0
        ;;
    esac
  }
  pgrep() { return 1; }
  pkill() { return 0; }
  journalctl() { return 0; }
  install_repo_asset_or_die() {
    local _src_rel="$1"
    local dst="$2"
    local mode="${3:-0755}"
    mkdir -p "$(dirname "${dst}")"
    cat > "${dst}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--apply" ]]; then
  exit "${TEST_SYNC_EXIT_CODE:-1}"
fi
exit 0
EOF
    chmod "${mode}" "${dst}"
  }
  render_setup_template_or_die() {
    local rel="$1"
    local dst="$2"
    local mode="${3:-0644}"
    shift 3
    mkdir -p "$(dirname "${dst}")"
    python3 - "${ROOT_DIR}/opt/setup/templates/${rel}" "${dst}" "${mode}" "$@" <<'PY'
import os
import re
import sys
from pathlib import Path

src, dst, mode, *items = sys.argv[1:]
text = Path(src).read_text(encoding="utf-8")
for item in items:
    key, value = item.split("=", 1)
    text = text.replace(f"__{key}__", value)
missing = sorted(set(re.findall(r"__([A-Z0-9_]+)__", text)))
if missing:
    raise SystemExit(f"unresolved placeholders: {', '.join(missing)}")
Path(dst).write_text(text, encoding="utf-8")
os.chmod(dst, int(mode, 8))
PY
  }

  export \
    ADBLOCK_ROOT="${new_root}" \
    ADBLOCK_CONFIG_FILE="${new_root}/config.env" \
    ADBLOCK_BLOCKLIST_FILE="${new_root}/blocked.domains" \
    ADBLOCK_URLS_FILE="${new_root}/source.urls" \
    ADBLOCK_MERGED_FILE="${new_root}/merged.domains" \
    ADBLOCK_RENDERED_FILE="${new_root}/blocklist.generated.conf" \
    ADBLOCK_DNSMASQ_CONF="${new_root}/dnsmasq.conf" \
    ADBLOCK_DNS_SERVICE="adblock-dns.service" \
    ADBLOCK_SYNC_SERVICE="adblock-sync.service" \
    ADBLOCK_SYNC_BIN="${tmp}/bin/adblock-sync" \
    ADBLOCK_AUTO_UPDATE_SERVICE="adblock-update.service" \
    ADBLOCK_AUTO_UPDATE_TIMER="adblock-update.timer" \
    ADBLOCK_AUTO_UPDATE_DAYS="1" \
    ADBLOCK_RUNTIME_USER="xray" \
    ADBLOCK_NFT_TABLE="autoscript_adblock" \
    ADBLOCK_PORT="5353" \
    CUSTOM_GEOSITE_DEST="${tmp}/custom.dat" \
    TEST_STATE_DIR

  set +e
  install_adblock_runtime >/dev/null 2>&1
  rc=$?
  set -e
  [[ "${TEST_DIE_CALLED}" -eq 1 ]] || fail "install_adblock_runtime should trigger die when adblock apply fails"
  [[ "${rc}" -ne 0 || "${TEST_DIE_CALLED}" -eq 1 ]]
}

cd "${ROOT_DIR}"
log "Legacy adblock migration"
run_migration_success_case
log "Fail-fast when adblock runtime is unhealthy"
run_fail_fast_case
log "Semua test upgrade adblock selesai"
