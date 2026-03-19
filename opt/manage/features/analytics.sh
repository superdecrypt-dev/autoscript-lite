#!/usr/bin/env bash
# shellcheck shell=bash

for _rel in \
  "features/analytics/traffic.sh" \
  "features/analytics/security.sh" \
  "features/analytics/runtime_services.sh" \
  "features/analytics/ssh_users.sh" \
  "features/analytics/ssh_network.sh" \
  "features/analytics/ssh_qac.sh" \
  "features/analytics/tools.sh"; do
  manage_source_relative "${_rel}"
done
unset _rel
