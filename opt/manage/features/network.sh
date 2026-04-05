#!/usr/bin/env bash
# shellcheck shell=bash

for _rel in \
  "features/network/warp.sh" \
  "features/network/routing.sh" \
  "features/network/adblock.sh" \
  "features/network/dns.sh" \
  "features/network/diagnostics.sh" \
  "features/network/speedtest.sh" \
  manage_source_relative "${_rel}"
done
unset _rel
