#!/usr/bin/env bash
# shellcheck shell=bash

# Auto-open manage CLI on SSH login for root only.
# Safe guards:
# - interactive shell only
# - SSH session only
# - root only
# - can be bypassed with AUTOSCRIPT_MANAGE_AUTO_OPEN=0

case $- in
  *i*) ;;
  *) return 0 ;;
esac

[[ -n "${SSH_CONNECTION:-}" || -n "${SSH_TTY:-}" ]] || return 0
[[ -z "${SSH_ORIGINAL_COMMAND:-}" ]] || return 0
[[ "${AUTOSCRIPT_MANAGE_AUTO_OPEN:-1}" == "1" ]] || return 0

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  return 0
fi

[[ -t 0 && -t 1 ]] || return 0

manage_bin="/usr/local/bin/manage"
[[ -x "${manage_bin}" ]] || return 0

exec "${manage_bin}"
