#!/usr/bin/env bash
# shellcheck shell=bash

for _rel in \
  "features/domain/cloudflare.sh" \
  "features/domain/control.sh"; do
  manage_source_relative "${_rel}"
done
unset _rel
