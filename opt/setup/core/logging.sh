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

ui_subtle() {
  echo -e "${DIM}$*${NC}"
}

ui_section_title() {
  local text="$1"
  echo -e "${BOLD}${text}${NC}"
}

ui_spinner_wait() {
  local pid="$1"
  local label="${2:-Memproses}"
  local status_file="${3:-}"
  local start_ts now elapsed frame_idx rc
  local -a frames=('|' '/' '-' '\\')
  local current_label

  if [[ ! "${pid}" =~ ^[0-9]+$ ]]; then
    return 1
  fi

  if [[ ! -t 1 ]]; then
    wait "${pid}"
    return $?
  fi

  start_ts="$(date +%s 2>/dev/null || echo 0)"
  frame_idx=0
  while kill -0 "${pid}" 2>/dev/null; do
    now="$(date +%s 2>/dev/null || echo "${start_ts}")"
    elapsed=$(( now - start_ts ))
    current_label="${label}"
    if [[ -n "${status_file}" && -r "${status_file}" ]]; then
      local status_line=""
      status_line="$(head -n1 "${status_file}" 2>/dev/null | tr -d '\r' || true)"
      [[ -n "${status_line}" ]] && current_label="${status_line}"
    fi
    printf '\r%b' "${frames[$frame_idx]} ${current_label} ${DIM}(${elapsed}s)${NC}"
    frame_idx=$(( (frame_idx + 1) % ${#frames[@]} ))
    sleep 0.12
  done

  wait "${pid}"
  rc=$?
  printf '\r\033[2K'
  return "${rc}"
}
