#!/usr/bin/env bash

EDGE_RUNTIME_ENV_FILE="${EDGE_RUNTIME_ENV_FILE:-/etc/default/edge-runtime}"
EDGE_DIST_DIR="${SCRIPT_DIR}/opt/edge/dist"
EDGE_DIST_MANIFEST="${EDGE_DIST_DIR}/SHA256SUMS"
EDGE_BIN="${EDGE_BIN:-/usr/local/bin/edge-mux}"
EDGE_SERVICE_NAME="${EDGE_SERVICE_NAME:-edge-mux.service}"
EDGE_HAPROXY_SERVICE_NAME="${EDGE_HAPROXY_SERVICE_NAME:-haproxy.service}"
EDGE_HAPROXY_CFG="${EDGE_HAPROXY_CFG:-/etc/haproxy/haproxy.cfg}"
EDGE_HAPROXY_PEM_FILE="${EDGE_HAPROXY_PEM_FILE:-/etc/haproxy/autoscript/edge.pem}"
EDGE_HAPROXY_FALLBACK_ENABLED="${EDGE_HAPROXY_FALLBACK_ENABLED:-true}"
EDGE_HAPROXY_STANDBY_HTTP_PORT="${EDGE_HAPROXY_STANDBY_HTTP_PORT:-18082}"
EDGE_HAPROXY_STANDBY_TLS_PORT="${EDGE_HAPROXY_STANDBY_TLS_PORT:-18444}"

edge_runtime_env_file_trusted() {
  local file="${EDGE_RUNTIME_ENV_FILE}"
  [[ -f "${file}" && ! -L "${file}" && -r "${file}" ]] || return 1

  if [[ "$(id -u)" -ne 0 ]]; then
    return 0
  fi

  local owner mode
  owner="$(stat -c '%u' "${file}" 2>/dev/null || echo 1)"
  mode="$(stat -c '%A' "${file}" 2>/dev/null || echo '----------')"
  [[ "${owner}" == "0" ]] || return 1
  [[ "${mode:5:1}" != "w" && "${mode:8:1}" != "w" ]] || return 1
  return 0
}

edge_runtime_set_default_from_persisted() {
  local key="$1"
  local value="$2"
  if [[ -n "${!key+x}" ]]; then
    return 0
  fi
  declare -gx "${key}=${value}"
}

load_persisted_edge_runtime_env() {
  local key value
  edge_runtime_env_file_trusted || return 0

  while IFS='=' read -r key value; do
    case "${key}" in
      EDGE_PROVIDER|EDGE_ACTIVATE_RUNTIME|EDGE_PUBLIC_HTTP_PORT|EDGE_PUBLIC_TLS_PORT|EDGE_NGINX_HTTP_BACKEND|EDGE_SSH_CLASSIC_BACKEND|EDGE_SSH_TLS_BACKEND|EDGE_HTTP_DETECT_TIMEOUT_MS|EDGE_CLASSIC_TLS_ON_80|EDGE_TLS_CERT_FILE|EDGE_TLS_KEY_FILE|EDGE_HAPROXY_PEM_FILE|EDGE_HAPROXY_FALLBACK_ENABLED|EDGE_HAPROXY_STANDBY_HTTP_PORT|EDGE_HAPROXY_STANDBY_TLS_PORT)
        value="${value%$'\r'}"
        edge_runtime_set_default_from_persisted "${key}" "${value}"
        ;;
    esac
  done < "${EDGE_RUNTIME_ENV_FILE}"
}

edge_runtime_activate_requested() {
  case "${EDGE_ACTIVATE_RUNTIME:-false}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

edge_runtime_should_take_public_ports() {
  edge_provider_enabled && edge_runtime_activate_requested
}

edge_haproxy_fallback_enabled() {
  case "${EDGE_HAPROXY_FALLBACK_ENABLED:-false}" in
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
    go) printf '%s\n' "go (active custom provider)" ;;
    haproxy) printf '%s\n' "haproxy (active fallback provider)" ;;
    nginx-stream) printf '%s\n' "nginx-stream (planned experimental provider; scaffold only)" ;;
    *) printf '%s\n' "invalid:${provider}" ;;
  esac
}

edge_provider_service_name() {
  case "$(edge_provider_selected)" in
    go) printf '%s\n' "${EDGE_SERVICE_NAME}" ;;
    haproxy) printf '%s\n' "${EDGE_HAPROXY_SERVICE_NAME}" ;;
    *) return 1 ;;
  esac
}

edge_conflicting_provider_services() {
  local target
  target="$(edge_provider_service_name 2>/dev/null || true)"
  for svc in "${EDGE_SERVICE_NAME}" "${EDGE_HAPROXY_SERVICE_NAME}"; do
    [[ -n "${target}" && "${svc}" == "${target}" ]] && continue
    printf '%s\n' "${svc}"
  done
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

edge_runtime_preflight_or_die() {
  if ! edge_provider_enabled; then
    return 0
  fi

  case "$(edge_provider_selected)" in
    go)
      edge_go_binary_available || die "Binary prebuilt edge-mux belum tersedia untuk provider go."
      edge_go_verify_dist_binary || die "Checksum binary prebuilt edge-mux gagal atau manifest SHA256SUMS belum siap."
      ;;
    haproxy|nginx-stream)
      if edge_runtime_activate_requested; then
        die "Provider $(edge_provider_selected) belum siap untuk aktivasi runtime."
      fi
      ;;
  esac
}

write_edge_runtime_env() {
  if ! edge_provider_supported; then
    die "EDGE_PROVIDER tidak dikenal: $(edge_provider_selected)"
  fi

  render_setup_template_or_die \
    "config/edge-runtime.env" \
    "${EDGE_RUNTIME_ENV_FILE}" \
    0644 \
    "EDGE_PROVIDER=$(edge_provider_selected)" \
    "EDGE_ACTIVATE_RUNTIME=${EDGE_ACTIVATE_RUNTIME:-false}" \
    "EDGE_PUBLIC_HTTP_PORT=${EDGE_PUBLIC_HTTP_PORT:-80}" \
    "EDGE_PUBLIC_TLS_PORT=${EDGE_PUBLIC_TLS_PORT:-443}" \
    "EDGE_NGINX_HTTP_BACKEND=${EDGE_NGINX_HTTP_BACKEND:-127.0.0.1:18080}" \
    "EDGE_SSH_CLASSIC_BACKEND=${EDGE_SSH_CLASSIC_BACKEND:-127.0.0.1:22022}" \
    "EDGE_SSH_TLS_BACKEND=${EDGE_SSH_TLS_BACKEND:-127.0.0.1:22443}" \
    "EDGE_HTTP_DETECT_TIMEOUT_MS=${EDGE_HTTP_DETECT_TIMEOUT_MS:-250}" \
    "EDGE_CLASSIC_TLS_ON_80=${EDGE_CLASSIC_TLS_ON_80:-true}" \
    "EDGE_TLS_CERT_FILE=${EDGE_TLS_CERT_FILE:-/opt/cert/fullchain.pem}" \
    "EDGE_TLS_KEY_FILE=${EDGE_TLS_KEY_FILE:-/opt/cert/privkey.pem}" \
    "EDGE_HAPROXY_PEM_FILE=${EDGE_HAPROXY_PEM_FILE}" \
    "EDGE_HAPROXY_FALLBACK_ENABLED=${EDGE_HAPROXY_FALLBACK_ENABLED:-true}" \
    "EDGE_HAPROXY_STANDBY_HTTP_PORT=${EDGE_HAPROXY_STANDBY_HTTP_PORT:-18082}" \
    "EDGE_HAPROXY_STANDBY_TLS_PORT=${EDGE_HAPROXY_STANDBY_TLS_PORT:-18444}"
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

stage_edge_haproxy_provider() {
  apt_get_with_lock_retry install -y haproxy || die "Gagal install haproxy."
  install -d -m 755 "/etc/haproxy/autoscript"
  umask 077
  cat "${EDGE_TLS_CERT_FILE:-/opt/cert/fullchain.pem}" "${EDGE_TLS_KEY_FILE:-/opt/cert/privkey.pem}" > "${EDGE_HAPROXY_PEM_FILE}" \
    || die "Gagal membuat PEM bundle haproxy: ${EDGE_HAPROXY_PEM_FILE}"
  chmod 600 "${EDGE_HAPROXY_PEM_FILE}"
  chown root:root "${EDGE_HAPROXY_PEM_FILE}" 2>/dev/null || true

  render_setup_template_or_die \
    "haproxy/haproxy.cfg" \
    "${EDGE_HAPROXY_CFG}" \
    0644 \
    "EDGE_PUBLIC_HTTP_PORT=${EDGE_PUBLIC_HTTP_PORT:-80}" \
    "EDGE_PUBLIC_TLS_PORT=${EDGE_PUBLIC_TLS_PORT:-443}" \
    "EDGE_NGINX_HTTP_BACKEND=${EDGE_NGINX_HTTP_BACKEND:-127.0.0.1:18080}" \
    "EDGE_SSH_CLASSIC_BACKEND=${EDGE_SSH_CLASSIC_BACKEND:-127.0.0.1:22022}" \
    "EDGE_SSH_TLS_BACKEND=${EDGE_SSH_TLS_BACKEND:-127.0.0.1:22443}" \
    "EDGE_HTTP_DETECT_TIMEOUT_MS=${EDGE_HTTP_DETECT_TIMEOUT_MS:-250}" \
    "EDGE_HAPROXY_PEM_FILE=${EDGE_HAPROXY_PEM_FILE}"

  haproxy -c -f "${EDGE_HAPROXY_CFG}" >/dev/null 2>&1 || die "Validasi haproxy gagal: ${EDGE_HAPROXY_CFG}"
  systemctl daemon-reload >/dev/null 2>&1 || true
  warn "Provider haproxy sudah di-stage ke ${EDGE_HAPROXY_CFG}, tetapi service ${EDGE_HAPROXY_SERVICE_NAME} belum diaktifkan."
}

stage_edge_haproxy_standby_runtime() {
  local orig_http_port orig_tls_port
  orig_http_port="${EDGE_PUBLIC_HTTP_PORT:-80}"
  orig_tls_port="${EDGE_PUBLIC_TLS_PORT:-443}"

  EDGE_PUBLIC_HTTP_PORT="${EDGE_HAPROXY_STANDBY_HTTP_PORT:-18082}" \
  EDGE_PUBLIC_TLS_PORT="${EDGE_HAPROXY_STANDBY_TLS_PORT:-18444}" \
    stage_edge_haproxy_provider

  systemctl enable "${EDGE_HAPROXY_SERVICE_NAME}" --now >/dev/null 2>&1 || die "Gagal enable ${EDGE_HAPROXY_SERVICE_NAME} standby"
  systemctl restart "${EDGE_HAPROXY_SERVICE_NAME}" >/dev/null 2>&1 || die "Gagal restart ${EDGE_HAPROXY_SERVICE_NAME} standby"
  ok "HAProxy standby aktif di ${EDGE_HAPROXY_STANDBY_HTTP_PORT:-18082}/${EDGE_HAPROXY_STANDBY_TLS_PORT:-18444}"

  EDGE_PUBLIC_HTTP_PORT="${orig_http_port}"
  EDGE_PUBLIC_TLS_PORT="${orig_tls_port}"
}

edge_runtime_port_busy() {
  local port="$1"
  ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "(^|[:.])${port}$"
}

edge_runtime_port_owned_only_by_edge() {
  local port="$1"
  local lines
  lines="$(ss -lntpH "( sport = :${port} )" 2>/dev/null || true)"
  [[ -n "${lines}" ]] || return 1
  printf '%s\n' "${lines}" | grep -qvE 'users:\(\(("edge-mux"|"haproxy")' && return 1
  return 0
}

edge_runtime_activation_preflight() {
  local http_port tls_port
  http_port="${EDGE_PUBLIC_HTTP_PORT:-80}"
  tls_port="${EDGE_PUBLIC_TLS_PORT:-443}"

  [[ -s "${EDGE_TLS_CERT_FILE:-/opt/cert/fullchain.pem}" ]] || die "TLS cert edge tidak ditemukan: ${EDGE_TLS_CERT_FILE:-/opt/cert/fullchain.pem}"
  [[ -s "${EDGE_TLS_KEY_FILE:-/opt/cert/privkey.pem}" ]] || die "TLS key edge tidak ditemukan: ${EDGE_TLS_KEY_FILE:-/opt/cert/privkey.pem}"

  case "$(edge_provider_selected)" in
    go)
      [[ -x "${EDGE_BIN}" ]] || die "Binary edge belum tersedia: ${EDGE_BIN}"
      ;;
    haproxy)
      command -v haproxy >/dev/null 2>&1 || die "Binary haproxy belum tersedia."
      [[ -s "${EDGE_HAPROXY_CFG}" ]] || die "Config haproxy belum tersedia: ${EDGE_HAPROXY_CFG}"
      haproxy -c -f "${EDGE_HAPROXY_CFG}" >/dev/null 2>&1 || die "Validasi haproxy gagal: ${EDGE_HAPROXY_CFG}"
      ;;
  esac

  if edge_runtime_port_busy "${http_port}"; then
    edge_runtime_port_owned_only_by_edge "${http_port}" || die "Port edge HTTP ${http_port} sedang dipakai proses non-edge. Aktivasi runtime edge belum aman."
  fi
  if edge_runtime_port_busy "${tls_port}"; then
    edge_runtime_port_owned_only_by_edge "${tls_port}" || die "Port edge TLS ${tls_port} sedang dipakai proses non-edge. Aktivasi runtime edge belum aman."
  fi
}

activate_edge_provider_runtime() {
  local target_service svc
  local -a restore_services=()
  target_service="$(edge_provider_service_name)" || die "Provider edge tidak punya service runtime."
  edge_runtime_activation_preflight

  while IFS= read -r svc; do
    [[ -n "${svc}" ]] || continue
    if systemctl is-active --quiet "${svc}" 2>/dev/null; then
      restore_services+=("${svc}")
    fi
  done < <(edge_conflicting_provider_services)

  systemctl daemon-reload >/dev/null 2>&1 || true
  for svc in "${restore_services[@]}"; do
    systemctl disable --now "${svc}" >/dev/null 2>&1 || true
    systemctl stop "${svc}" >/dev/null 2>&1 || true
  done

  if ! systemctl enable "${target_service}" --now >/dev/null 2>&1; then
    warn "Gagal mengaktifkan ${target_service}; mencoba menghidupkan kembali provider sebelumnya."
    for svc in "${restore_services[@]}"; do
      systemctl enable "${svc}" --now >/dev/null 2>&1 || true
    done
    die "Gagal enable ${target_service}"
  fi
  if ! systemctl restart "${target_service}" >/dev/null 2>&1; then
    warn "Gagal restart ${target_service}; mencoba menghidupkan kembali provider sebelumnya."
    systemctl stop "${target_service}" >/dev/null 2>&1 || true
    for svc in "${restore_services[@]}"; do
      systemctl enable "${svc}" --now >/dev/null 2>&1 || true
    done
    die "Gagal restart ${target_service}"
  fi
  systemctl is-active --quiet "${target_service}" || die "${target_service} tidak aktif setelah start"
  ok "Edge runtime aktif: ${target_service}"
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
  install_setup_bin_or_die "edge-provider-switch" "/usr/local/bin/edge-provider-switch" 0755
  case "$(edge_provider_selected)" in
    go)
      stage_edge_go_provider
      if edge_runtime_activate_requested; then
        activate_edge_provider_runtime
      fi
      if edge_haproxy_fallback_enabled; then
        stage_edge_haproxy_standby_runtime
      fi
      ;;
    haproxy)
      stage_edge_haproxy_provider
      if edge_runtime_activate_requested; then
        activate_edge_provider_runtime
      fi
      ;;
    nginx-stream)
      warn "Provider $(edge_provider_selected) masih berupa template desain/scaffold dan belum bisa diaktifkan."
      ;;
  esac
  if ! edge_runtime_activate_requested; then
    warn "Runtime edge belum diaktifkan oleh installer. Set EDGE_ACTIVATE_RUNTIME=true jika ingin mencoba aktivasi pada port yang aman."
  fi
  warn "Dokumen desain: /root/project/autoscript/EDGE_PROVIDER_DESIGN.md"
  return 0
}
