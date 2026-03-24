#!/usr/bin/env bash
# shellcheck shell=bash

for _rel in \
  "features/maintenance/logs.sh" \
  "features/maintenance/services.sh" \
  "features/maintenance/diagnostics.sh" \
  "features/maintenance/security.sh" \
  "features/maintenance/tools.sh" \
  "features/maintenance/runtime_services.sh"; do
  manage_source_relative "${_rel}"
done
unset _rel
