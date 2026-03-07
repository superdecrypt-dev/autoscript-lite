#!/usr/bin/env bash
# Shared env/constants for future modular setup refactor.
#
# Intended contents:
# - constant definitions moved from setup.sh
# - shared directory paths
# - config defaults and feature toggles
# - values consumed across install/*.sh modules
#
# Notes:
# - keep `setup.sh` as the single entrypoint
# - source this file from `${SCRIPT_DIR}/opt/setup/core/env.sh`
# - avoid side effects beyond readonly/default variable setup
