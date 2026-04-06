#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd -P)"

log() {
  printf '[test-noninteractive] %s\n' "$*"
}

warn() {
  printf '[test-noninteractive] WARN: %s\n' "$*" >&2
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

collect_files() {
  local pattern="$1"
  shift || true
  find "$@" -type f -name "${pattern}" | sort
}

check_bash_syntax() {
  local file
  for file in "$@"; do
    bash -n "${file}"
  done
}

python_compile_files() {
  local -a files=("$@")
  if (( ${#files[@]} == 0 )); then
    return 0
  fi
  python3 -m py_compile "${files[@]}"
}

cd "${ROOT_DIR}"

log "Mulai baseline non-interactive checks"

mapfile -t SHELL_FILES < <(
  {
    printf '%s\n' \
      "run.sh" \
      "setup.sh" \
      "manage.sh" \
      "install-telegram-bot.sh"
    collect_files '*.sh' opt/setup opt/manage bot-telegram/scripts tools
  } | awk 'NF && !seen[$0]++'
)

log "Bash syntax: shell scripts"
check_bash_syntax "${SHELL_FILES[@]}"

if need_cmd shellcheck; then
  log "Shellcheck"
  shellcheck -x -S warning "${SHELL_FILES[@]}"
else
  warn "shellcheck tidak ditemukan; lint shell dilewati."
fi

mapfile -t PYTHON_FILES < <(
  collect_files '*.py' \
    opt/setup/bin \
    opt/setup/lib \
    bot-telegram/backend-py/app \
    bot-telegram/gateway-py/app \
    tools
)

log "Python compile"
python_compile_files "${PYTHON_FILES[@]}"

log "Python gate: Telegram bot"
bash bot-telegram/scripts/gate-all.sh

log "Shell test: adblock upgrade"
bash tools/test-adblock-upgrade.sh

log "Shell test: edge dist"
bash tools/test-edge-dist.sh

if [[ -f "opt/edge/go/go.mod" ]]; then
  if need_cmd go; then
    log "Go test: edge"
    go -C opt/edge/go test ./...
  else
    warn "go tidak ditemukan; test edge dilewati."
  fi
fi

log "Semua baseline non-interactive checks selesai."
