#!/usr/bin/env bash
# shellcheck shell=bash

for _rel in \
  "features/analytics/traffic.sh"; do
  manage_source_relative "${_rel}"
done
unset _rel
