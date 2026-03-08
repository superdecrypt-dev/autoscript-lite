#!/usr/bin/env bash

EDGE_DIST_DIR="${SCRIPT_DIR}/opt/edge/dist"
EDGE_DIST_MANIFEST="${EDGE_DIST_DIR}/SHA256SUMS"
EDGE_BIN="${EDGE_BIN:-/usr/local/bin/edge-mux}"
EDGE_SERVICE_NAME="${EDGE_SERVICE_NAME:-edge-mux.service}"

edge_runtime_activate_requested() {
  case "${EDGE_ACTIVATE_RUNTIME:-false}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

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

edge_go_arch_suffix() {
  local arch
  arch="$(uname -m 2>/dev/null || echo unknown)"
  case "${arch}" in
    x86_64|amd64) printf '%s\n' "amd64" ;;
    aarch64|arm64) printf '%s\n' "arm64" ;;
    *) return 1 ;;
  esac
}

edge_go_dist_binary_path() {
  local suffix
  suffix="$(edge_go_arch_suffix)" || return 1
  printf '%s\n' "${EDGE_DIST_DIR}/edge-mux-linux-${suffix}"
}

edge_go_binary_available() {
  local path
  path="$(edge_go_dist_binary_path)" || return 1
  [[ -f "${path}" && -s "${path}" ]]
}

edge_go_verify_dist_binary() {
  local path name expected actual
  path="$(edge_go_dist_binary_path)" || return 1
  [[ -f "${path}" && -s "${path}" ]] || return 1
  [[ -f "${EDGE_DIST_MANIFEST}" && -s "${EDGE_DIST_MANIFEST}" ]] || return 1
  command -v sha256sum >/dev/null 2>&1 || return 1

  name="$(basename "${path}")"
  expected="$(awk -v target="${name}" '$2 == target {print tolower($1)}' "${EDGE_DIST_MANIFEST}" | head -n1)"
  [[ -n "${expected}" ]] || return 1
  actual="$(sha256sum "${path}" | awk '{print tolower($1)}')"
  [[ -n "${actual}" && "${actual}" == "${expected}" ]]
}

write_edge_runtime_env() {
  if ! edge_provider_supported; then
    die "EDGE_PROVIDER tidak dikenal: $(edge_provider_selected)"
  fi

  render_setup_template_or_die \
    "config/edge-runtime.env" \
    "/etc/default/edge-runtime" \
    "EDGE_PROVIDER=$(edge_provider_selected)" \
    "EDGE_ACTIVATE_RUNTIME=${EDGE_ACTIVATE_RUNTIME:-false}" \
    "EDGE_PUBLIC_HTTP_PORT=${EDGE_PUBLIC_HTTP_PORT:-80}" \
    "EDGE_PUBLIC_TLS_PORT=${EDGE_PUBLIC_TLS_PORT:-443}" \
    "EDGE_NGINX_HTTP_BACKEND=${EDGE_NGINX_HTTP_BACKEND:-127.0.0.1:18080}" \
    "EDGE_SSH_CLASSIC_BACKEND=${EDGE_SSH_CLASSIC_BACKEND:-127.0.0.1:22022}" \
    "EDGE_HTTP_DETECT_TIMEOUT_MS=${EDGE_HTTP_DETECT_TIMEOUT_MS:-250}" \
    "EDGE_CLASSIC_TLS_ON_80=${EDGE_CLASSIC_TLS_ON_80:-true}" \
    "EDGE_TLS_CERT_FILE=${EDGE_TLS_CERT_FILE:-/opt/cert/fullchain.pem}" \
    "EDGE_TLS_KEY_FILE=${EDGE_TLS_KEY_FILE:-/opt/cert/privkey.pem}"
}

stage_edge_go_provider() {
  local src
  src="$(edge_go_dist_binary_path)" || die "Arsitektur host belum didukung untuk provider go."
  [[ -f "${src}" && -s "${src}" ]] || die "Binary prebuilt edge-mux belum tersedia: ${src}"
  edge_go_verify_dist_binary || die "Checksum binary prebuilt edge-mux gagal atau manifest SHA256SUMS belum siap: ${src}"

  install -d -m 755 "$(dirname "${EDGE_BIN}")"
  install -m 0755 "${src}" "${EDGE_BIN}"
  chown root:root "${EDGE_BIN}" 2>/dev/null || true

  render_setup_template_or_die \
    "systemd/edge-mux.service" \
    "/etc/systemd/system/${EDGE_SERVICE_NAME}" \
    0644

  systemctl daemon-reload >/dev/null 2>&1 || true
  warn "Provider go sudah di-stage ke ${EDGE_BIN}, tetapi service ${EDGE_SERVICE_NAME} belum diaktifkan."
}

edge_runtime_port_busy() {
  local port="$1"
  ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "(^|[:.])${port}$"
}

edge_runtime_activation_preflight() {
  local http_port tls_port
  http_port="${EDGE_PUBLIC_HTTP_PORT:-80}"
  tls_port="${EDGE_PUBLIC_TLS_PORT:-443}"

  [[ -x "${EDGE_BIN}" ]] || die "Binary edge belum tersedia: ${EDGE_BIN}"
  [[ -s "${EDGE_TLS_CERT_FILE:-/opt/cert/fullchain.pem}" ]] || die "TLS cert edge tidak ditemukan: ${EDGE_TLS_CERT_FILE:-/opt/cert/fullchain.pem}"
  [[ -s "${EDGE_TLS_KEY_FILE:-/opt/cert/privkey.pem}" ]] || die "TLS key edge tidak ditemukan: ${EDGE_TLS_KEY_FILE:-/opt/cert/privkey.pem}"

  if edge_runtime_port_busy "${http_port}"; then
    die "Port edge HTTP ${http_port} sedang dipakai. Aktivasi runtime edge belum aman sampai listener publik lama dipindah atau port diganti."
  fi
  if edge_runtime_port_busy "${tls_port}"; then
    die "Port edge TLS ${tls_port} sedang dipakai. Aktivasi runtime edge belum aman sampai listener publik lama dipindah atau port diganti."
  fi
}

activate_edge_provider_runtime() {
  edge_runtime_activation_preflight
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable "${EDGE_SERVICE_NAME}" --now >/dev/null 2>&1 || die "Gagal enable ${EDGE_SERVICE_NAME}"
  systemctl restart "${EDGE_SERVICE_NAME}" >/dev/null 2>&1 || die "Gagal restart ${EDGE_SERVICE_NAME}"
  systemctl is-active --quiet "${EDGE_SERVICE_NAME}" || die "${EDGE_SERVICE_NAME} tidak aktif setelah start"
  ok "Edge runtime aktif: ${EDGE_SERVICE_NAME}"
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
  case "$(edge_provider_selected)" in
    go)
      stage_edge_go_provider
      if edge_runtime_activate_requested; then
        activate_edge_provider_runtime
      fi
      ;;
    haproxy|nginx-stream)
      warn "Provider $(edge_provider_selected) masih berupa template desain/scaffold dan belum bisa diaktifkan."
      ;;
  esac
  if ! edge_runtime_activate_requested; then
    warn "Runtime edge belum diaktifkan oleh installer. Set EDGE_ACTIVATE_RUNTIME=true jika ingin mencoba aktivasi pada port yang aman."
  fi
  warn "Dokumen desain: /root/project/autoscript/EDGE_PROVIDER_DESIGN.md"
  return 0
}
