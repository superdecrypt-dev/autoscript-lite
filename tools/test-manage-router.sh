#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd -P)"
cd "${ROOT_DIR}"

required_modules=(
  '  "menus/user_menu.sh"'
  '  "menus/network_menu.sh"'
  '  "menus/domain_menu.sh"'
)

for pattern in "${required_modules[@]}"; do
  if ! grep -Fq "${pattern}" manage.sh; then
    echo "[test-manage-router] missing required module entry: ${pattern}" >&2
    exit 1
  fi
done

wrapper_checks=(
  'opt/manage/menus/user_menu.sh:  user_menu "$@"'
  'opt/manage/menus/network_menu.sh:  network_menu "$@"'
  'opt/manage/menus/domain_menu.sh:  domain_control_menu "$@"'
)

for item in "${wrapper_checks[@]}"; do
  file="${item%%:*}"
  pattern="${item#*:}"
  if ! grep -Fq "${pattern}" "${file}"; then
    echo "[test-manage-router] wrapper mapping missing in ${file}: ${pattern}" >&2
    exit 1
  fi
done

router_patterns=(
  'user|users|xray-users)'
  'quota|qac|xray-qac)'
  'network|xray-network)'
  'domain|domain-control)'
  'speedtest|speed)'
  'security)'
  'maintenance)'
  'traffic|analytics)'
  'tools)'
  'backup|restore|backup-restore)'
  'telegram-bot)'
  'license-guard)'
  'warn "Action manage tidak dikenal: ${action}"'
)

for pattern in "${router_patterns[@]}"; do
  if ! grep -Fq "${pattern}" opt/manage/core/router.sh; then
    echo "[test-manage-router] router pattern missing: ${pattern}" >&2
    exit 1
  fi
done

entrypoint_patterns=(
  'local action="${1:-}"'
  'manage_license_guard_preflight "${action}"'
  'if [[ -n "${action}" ]]; then'
  'manage_router_dispatch "${action}" "${@:2}"'
)

for pattern in "${entrypoint_patterns[@]}"; do
  if ! grep -Fq "${pattern}" opt/manage/app/main.sh; then
    echo "[test-manage-router] entrypoint router hook missing: ${pattern}" >&2
    exit 1
  fi
done

echo "[test-manage-router] manage router/menu wrappers look consistent"
