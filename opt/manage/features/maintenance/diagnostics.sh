#!/usr/bin/env bash
# shellcheck shell=bash

status_diagnostics_menu() {
  title
  echo "11) Maintenance > Core Check"
  hr
  svc_status_line xray
  svc_status_line nginx
  svc_status_line "$(main_menu_edge_service_name)"
  hr
  echo "Listeners (ringkas):"
  show_listeners_compact
  hr
  pause
}

