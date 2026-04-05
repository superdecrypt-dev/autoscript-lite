#!/usr/bin/env bash
# shellcheck shell=bash

for _rel in \
  "features/users/xray_users.sh" \
  "features/users/xray_qac.sh"; do
  manage_source_relative "${_rel}"
done
unset _rel
