#!/usr/bin/env bash
# Shared logging/UI helpers for modular setup runtime.

declare -ag _EXIT_CLEANUP_FNS=()

die() {
  echo -e "${RED}[ERROR]${NC} $*" >&2
  exit 1
}

ok() {
  echo -e "${GREEN}[OK]${NC} $*"
}

warn() {
  echo -e "${YELLOW}[WARN]${NC} $*"
}

run_exit_cleanups() {
  local rc=$?
  local fn
  for fn in "${_EXIT_CLEANUP_FNS[@]}"; do
    if declare -F "$fn" >/dev/null 2>&1; then
      "$fn" || true
    fi
  done
  return "$rc"
}

register_exit_cleanup() {
  local fn="$1"
  local existing
  for existing in "${_EXIT_CLEANUP_FNS[@]}"; do
    [[ "$existing" == "$fn" ]] && return 0
  done
  _EXIT_CLEANUP_FNS+=("$fn")
}

safe_clear() {
  if [[ -t 1 ]] && command -v clear >/dev/null 2>&1; then
    clear || true
  fi
}

ui_hr() {
  local w="${COLUMNS:-80}"
  local line
  if [[ ! "${w}" =~ ^[0-9]+$ ]]; then
    w=80
  fi
  if (( w < 60 )); then
    w=60
  fi
  printf -v line '%*s' "${w}" ''
  line="${line// /-}"
  echo -e "${DIM}${line}${NC}"
}

ui_header() {
  local text="$1"
  safe_clear
  ui_hr
  echo -e "${BOLD}${CYAN}${text}${NC}"
  ui_hr
}
