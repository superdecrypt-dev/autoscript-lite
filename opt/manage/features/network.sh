#!/usr/bin/env bash
# shellcheck shell=bash

for _rel in \
  "features/network/warp.sh" \
  "features/network/routing.sh" \
  "features/network/dns.sh" \
  "features/network/diagnostics.sh" \
  "features/network/speedtest.sh"; do
  manage_source_relative "${_rel}"
done
unset _rel
