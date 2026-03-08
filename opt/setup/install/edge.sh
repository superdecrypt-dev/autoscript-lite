#!/usr/bin/env bash

# Scaffold installer edge provider.
# File ini belum dihubungkan ke setup.sh agar tidak mengubah runtime aktif.

edge_provider_selected() {
  printf '%s\n' "${EDGE_PROVIDER:-none}"
}

edge_provider_supported() {
  case "$(edge_provider_selected)" in
    none|go|haproxy|nginx-stream) return 0 ;;
    *) return 1 ;;
  esac
}

edge_provider_enabled() {
  [[ "$(edge_provider_selected)" != "none" ]]
}

edge_provider_summary() {
  local provider
  provider="$(edge_provider_selected)"
  case "${provider}" in
    none) printf '%s\n' "disabled" ;;
    go) printf '%s\n' "go (planned primary provider; scaffold only)" ;;
    haproxy) printf '%s\n' "haproxy (planned fallback provider; scaffold only)" ;;
    nginx-stream) printf '%s\n' "nginx-stream (planned experimental provider; scaffold only)" ;;
    *) printf '%s\n' "invalid:${provider}" ;;
  esac
}

write_edge_runtime_env() {
  if ! edge_provider_supported; then
    die "EDGE_PROVIDER tidak dikenal: $(edge_provider_selected)"
  fi

  render_setup_template_or_die \
    "config/edge-runtime.env" \
    "/etc/default/edge-runtime" \
    "EDGE_PROVIDER=$(edge_provider_selected)" \
    "EDGE_PUBLIC_HTTP_PORT=${EDGE_PUBLIC_HTTP_PORT:-80}" \
    "EDGE_PUBLIC_TLS_PORT=${EDGE_PUBLIC_TLS_PORT:-443}" \
    "EDGE_NGINX_HTTP_BACKEND=${EDGE_NGINX_HTTP_BACKEND:-127.0.0.1:18080}" \
    "EDGE_SSH_CLASSIC_BACKEND=${EDGE_SSH_CLASSIC_BACKEND:-127.0.0.1:22022}" \
    "EDGE_HTTP_DETECT_TIMEOUT_MS=${EDGE_HTTP_DETECT_TIMEOUT_MS:-250}" \
    "EDGE_CLASSIC_TLS_ON_80=${EDGE_CLASSIC_TLS_ON_80:-true}"
}

install_edge_provider_stack() {
  if ! edge_provider_supported; then
    die "EDGE_PROVIDER tidak dikenal: $(edge_provider_selected)"
  fi

  write_edge_runtime_env

  if ! edge_provider_enabled; then
    ok "Edge provider tidak diaktifkan (EDGE_PROVIDER=none)."
    return 0
  fi

  warn "Edge provider dipilih: $(edge_provider_summary)"
  warn "Stage ini baru scaffold. Runtime edge belum diaktifkan oleh installer."
  warn "Dokumen desain: /root/project/autoscript/EDGE_PROVIDER_DESIGN.md"
  return 0
}
