#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2005,SC2034

network_diagnostics_menu() {
  while true; do
    title
    xray_network_menu_title "Diagnostics"
    hr
    echo "  1) Show summary (routing)"
    echo "  2) Validate conf.d JSON"
    echo "  3) xray run -test -confdir (syntax check)"
    echo "  4) Show core service status"
    echo "  0) Back"
    hr
    read -r -p "Pilih: " c
    case "${c}" in
      1) network_show_summary ;;
      2)
        title
        echo "Validate JSON"
        hr
        check_xray_config_json || true
        hr
        pause
        ;;
      3)
        title
        echo "xray config test (confdir)"
        hr
        if xray_confdir_syntax_test_pretty; then
          log "Syntax conf.d: OK"
        else
          warn "Syntax conf.d: GAGAL"
        fi
        hr
        pause
        ;;
      4)
        title
        echo "Service status (core)"
        hr
        if svc_exists "$(main_menu_edge_service_name)"; then
          systemctl status "$(main_menu_edge_service_name)" --no-pager || true
        else
          warn "$(main_menu_edge_service_name) tidak terdeteksi"
        fi
        hr
        systemctl status xray --no-pager || true
        hr
        systemctl status nginx --no-pager || true
        hr
        if svc_exists wireproxy; then
          systemctl status wireproxy --no-pager || true
        else
          warn "wireproxy.service tidak terdeteksi"
        fi
        hr
        pause
        ;;
      0|kembali|k|back|b) break ;;
      *) invalid_choice ;;
    esac
  done
}

network_menu() {
  local -a items=(
    "1|WARP"
    "2|DNS"
    "3|DNS Editor"
    "4|Checks"
    "0|Back"
  )
  while true; do
    ui_menu_screen_begin "$(xray_network_menu_title)"
    ui_menu_render_options items 76
    hr
    if ! read -r -p "Pilih: " c; then
      echo
      break
    fi
    case "${c}" in
      1) menu_run_isolated_report "WARP Controls" warp_controls_menu ;;
      2) menu_run_isolated_report "DNS Settings" dns_settings_menu ;;
      3) menu_run_isolated_report "DNS Add-ons" dns_addons_menu ;;
      4) menu_run_isolated_report "Network Diagnostics" network_diagnostics_menu ;;
      0|kembali|k|back|b) break ;;
      *) invalid_choice ;;
    esac
  done
}
