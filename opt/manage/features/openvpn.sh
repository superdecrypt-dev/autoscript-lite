# shellcheck shell=bash

openvpn_account_dir_value() {
  printf '%s\n' "${ACCOUNT_ROOT}/openvpn"
}

openvpn_account_info_file() {
  local name="${1:-}"
  printf '%s/%s@openvpn.txt\n' "$(openvpn_account_dir_value)" "${name}"
}

openvpn_pki_dir_value() {
  openvpn_runtime_get_env OVPN_PKI_DIR 2>/dev/null || echo "/etc/openvpn/server/pki"
}

openvpn_ca_file_value() {
  openvpn_runtime_get_env OVPN_CA_FILE 2>/dev/null || echo "$(openvpn_pki_dir_value)/ca.crt"
}

openvpn_tls_crypt_file_value() {
  openvpn_runtime_get_env OVPN_TLS_CRYPT_FILE 2>/dev/null || echo "$(openvpn_pki_dir_value)/tls-crypt.key"
}

openvpn_ccd_dir_value() {
  openvpn_runtime_get_env OVPN_CCD_DIR 2>/dev/null || echo "/etc/openvpn/server/ccd"
}

openvpn_downloads_dir_value() {
  openvpn_runtime_get_env OVPN_DOWNLOADS_DIR 2>/dev/null || echo "/var/lib/openvpn/downloads"
}

openvpn_client_key_path_value() {
  local name="${1:-}"
  printf '%s/%s.key\n' "$(openvpn_clients_dir_value)" "${name}"
}

openvpn_client_csr_path_value() {
  local name="${1:-}"
  printf '%s/%s.csr\n' "$(openvpn_clients_dir_value)" "${name}"
}

openvpn_client_cert_path_value() {
  local name="${1:-}"
  printf '%s/%s.crt\n' "$(openvpn_clients_dir_value)" "${name}"
}

openvpn_client_ext_path_value() {
  local name="${1:-}"
  printf '%s/%s.ext\n' "$(openvpn_clients_dir_value)" "${name}"
}

openvpn_client_profile_path_value() {
  local name="${1:-}"
  printf '%s/%s-tcp.ovpn\n' "$(openvpn_clients_dir_value)" "${name}"
}

openvpn_client_ssl_profile_path_value() {
  local name="${1:-}"
  printf '%s/%s-ssl.ovpn\n' "$(openvpn_clients_dir_value)" "${name}"
}

openvpn_client_ws_profile_path_value() {
  local name="${1:-}"
  printf '%s/%s-ws.ovpn\n' "$(openvpn_clients_dir_value)" "${name}"
}

openvpn_client_ssl_helper_path_value() {
  local name="${1:-}"
  printf '%s/%s-ssl-helper.py\n' "$(openvpn_clients_dir_value)" "${name}"
}

openvpn_client_ws_helper_path_value() {
  local name="${1:-}"
  printf '%s/%s-ws-helper.py\n' "$(openvpn_clients_dir_value)" "${name}"
}

openvpn_client_tcp_run_path_value() {
  local name="${1:-}"
  printf '%s/%s-tcp-run.sh\n' "$(openvpn_clients_dir_value)" "${name}"
}

openvpn_client_ssl_run_path_value() {
  local name="${1:-}"
  printf '%s/%s-ssl-run.sh\n' "$(openvpn_clients_dir_value)" "${name}"
}

openvpn_client_ws_run_path_value() {
  local name="${1:-}"
  printf '%s/%s-ws-run.sh\n' "$(openvpn_clients_dir_value)" "${name}"
}

openvpn_download_token_valid() {
  local token="${1:-}"
  [[ "${token}" =~ ^[A-Fa-f0-9]{16}$ ]]
}

openvpn_download_path_from_token() {
  local token="${1:-}"
  openvpn_download_token_valid "${token}" || return 1
  printf '/ovpn/%s.zip\n' "${token,,}"
}

openvpn_client_tcp_tun_device_value() {
  local name="${1:-client}"
  name="${name,,}"
  name="${name//[^a-z0-9]/}"
  [[ -n "${name}" ]] || name="client"
  printf 'ovpntcp%s\n' "${name:0:8}"
}

openvpn_client_ssl_local_port_value() {
  printf '%s\n' "21197"
}

openvpn_client_ws_local_port_value() {
  printf '%s\n' "21196"
}

openvpn_client_bundle_path_value() {
  local name="${1:-}"
  openvpn_client_name_valid "${name}" || return 1
  printf '%s/%s.zip\n' "$(openvpn_downloads_dir_value)" "${name}"
}

openvpn_client_bundle_url_value() {
  local name="${1:-}"
  local host
  openvpn_client_name_valid "${name}" || return 1
  host="$(detect_domain)"
  [[ -n "${host}" ]] || host="$(detect_public_ip_ipapi)"
  [[ -n "${host}" ]] || return 1
  printf 'https://%s/ovpn/%s.zip\n' "${host}" "${name}"
}

openvpn_client_public_port_manage() {
  local tcp_port
  tcp_port="$(openvpn_runtime_get_env OVPN_TCP_PORT 2>/dev/null || echo "21194")"
  if edge_runtime_enabled_for_public_ports; then
    echo "443"
  else
    echo "${tcp_port}"
  fi
}

openvpn_client_name_valid() {
  local name="${1:-}"
  [[ "${name}" =~ ^[a-z0-9][a-z0-9._-]{0,31}$ ]]
}

openvpn_client_state_exists() {
  local name="${1:-}"
  openvpn_client_name_valid "${name}" || return 1
  [[ -s "$(openvpn_client_state_path_value "${name}")" ]]
}

openvpn_client_state_read_field() {
  local name="${1:-}"
  local field="${2:-}"
  local state_file
  state_file="$(openvpn_client_state_path_value "${name}")"
  [[ -s "${state_file}" ]] || return 1
  need_python3
  python3 - <<'PY' "${state_file}" "${field}" 2>/dev/null || true
import json
import sys

path, field = sys.argv[1:3]
try:
  with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
  if isinstance(data, dict):
    value = data.get(field)
    if value is not None:
      print(str(value))
except Exception:
  pass
PY
}

openvpn_client_cn_get() {
  local name="${1:-}"
  local cn
  cn="$(openvpn_client_state_read_field "${name}" "client_cn" 2>/dev/null || true)"
  if [[ -n "${cn}" ]]; then
    printf '%s\n' "${cn}"
  else
    printf '%s\n' "${name}"
  fi
}

openvpn_client_created_at_get() {
  local name="${1:-}"
  local created
  created="$(openvpn_client_state_read_field "${name}" "created_at" 2>/dev/null || true)"
  if [[ -n "${created}" ]]; then
    printf '%s\n' "${created}"
  else
    date -u '+%Y-%m-%d'
  fi
}

openvpn_client_expired_at_get() {
  local name="${1:-}"
  local expired
  expired="$(openvpn_client_state_read_field "${name}" "expired_at" 2>/dev/null || true)"
  if [[ -n "${expired}" ]]; then
    printf '%s\n' "${expired}"
  else
    printf '%s\n' "-"
  fi
}

openvpn_core_service_name_manage() {
  printf '%s\n' "ovpn-tcp.service"
}

openvpn_server_conf_manage() {
  openvpn_runtime_get_env OVPN_SERVER_CONF 2>/dev/null || echo "/etc/openvpn/server/ovpn-tcp.conf"
}

openvpn_manage_ready_reason() {
  local pki_dir ca_file ca_key tls_crypt_file core_svc server_conf
  if ! have_cmd python3; then
    printf '%s\n' "python3 belum terpasang."
    return 0
  fi
  if ! have_cmd openssl; then
    printf '%s\n' "openssl belum terpasang."
    return 0
  fi
  if ! have_cmd openvpn; then
    printf '%s\n' "binary openvpn belum terpasang."
    return 0
  fi
  core_svc="$(openvpn_core_service_name_manage)"
  if ! svc_exists "${core_svc}"; then
    printf '%s\n' "${core_svc} belum terpasang."
    return 0
  fi
  server_conf="$(openvpn_server_conf_manage)"
  [[ -f "${server_conf}" ]] || {
    printf '%s\n' "config server OpenVPN belum ada di ${server_conf}."
    return 0
  }
  pki_dir="$(openvpn_pki_dir_value)"
  ca_file="$(openvpn_ca_file_value)"
  ca_key="${pki_dir}/ca.key"
  tls_crypt_file="$(openvpn_tls_crypt_file_value)"
  [[ -f "${ca_file}" ]] || {
    printf '%s\n' "CA OpenVPN belum ada di ${ca_file}."
    return 0
  }
  [[ -f "${ca_key}" ]] || {
    printf '%s\n' "CA key OpenVPN belum ada di ${ca_key}."
    return 0
  }
  [[ -f "${tls_crypt_file}" ]] || {
    printf '%s\n' "tls-crypt key OpenVPN belum ada di ${tls_crypt_file}."
    return 0
  }
  return 1
}

openvpn_manage_is_ready() {
  local reason=""
  reason="$(openvpn_manage_ready_reason 2>/dev/null || true)"
  [[ -z "${reason}" ]]
}

openvpn_client_download_token_get() {
  local name="${1:-}"
  local token
  token="$(openvpn_client_state_read_field "${name}" "download_token" 2>/dev/null || true)"
  if openvpn_download_token_valid "${token}"; then
    printf '%s\n' "${token,,}"
  else
    printf '\n'
  fi
}

openvpn_expiry_is_active_manage() {
  local expired_at="${1:-}"
  [[ -z "${expired_at}" || "${expired_at}" == "-" ]] && return 0
  need_python3
  python3 - <<'PY' "${expired_at}" 2>/dev/null
from datetime import date, datetime
import re
import sys

raw = str(sys.argv[1] or "").strip()
if not raw or raw == "-":
  raise SystemExit(0)

candidate = raw[:10]
if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", candidate):
  raise SystemExit(0)

expiry = datetime.strptime(candidate, "%Y-%m-%d").date()
today = date.today()
# Samakan perilaku dengan intuisi operator SSH: tanggal expiry masih aktif
# sepanjang hari itu, dan baru dianggap expired mulai hari berikutnya.
raise SystemExit(0 if expiry >= today else 1)
PY
}

openvpn_client_generate_cn() {
  local name="${1:-}"
  local clients_dir ccd_dir
  clients_dir="$(openvpn_clients_dir_value)"
  ccd_dir="$(openvpn_ccd_dir_value)"
  install -d -m 700 "${clients_dir}" "${ccd_dir}" 2>/dev/null || true
  need_python3
  python3 - <<'PY' "${clients_dir}" "${ccd_dir}" "${name}"
import json
import os
import re
import secrets
import sys

clients_dir, ccd_dir, raw_name = sys.argv[1:4]
base = re.sub(r"[^a-z0-9]+", "", str(raw_name or "").strip().lower())
base = base[:16] or "client"
seen = set()
for entry in os.listdir(clients_dir):
  if not entry.endswith(".json") or entry.startswith("."):
    continue
  path = os.path.join(clients_dir, entry)
  try:
    with open(path, "r", encoding="utf-8") as f:
      data = json.load(f)
    if isinstance(data, dict):
      cn = str(data.get("client_cn") or "").strip().lower()
      if cn:
        seen.add(cn)
  except Exception:
    continue
for entry in os.listdir(ccd_dir):
  if entry and not entry.startswith("."):
    seen.add(entry.strip().lower())

for _ in range(256):
  cn = f"ovpn-{base}-{secrets.token_hex(3)}"
  if cn not in seen:
    print(cn)
    raise SystemExit(0)
raise SystemExit(1)
PY
}

openvpn_client_state_upsert() {
  local name="${1:-}"
  local client_cn="${2:-}"
  local state_file clients_dir
  state_file="$(openvpn_client_state_path_value "${name}")"
  clients_dir="$(openvpn_clients_dir_value)"
  install -d -m 700 "${clients_dir}" 2>/dev/null || true
  need_python3
  python3 - <<'PY' "${clients_dir}" "${state_file}" "${name}" "${client_cn}"
import datetime
import json
import os
import re
import secrets
import sys
import tempfile

clients_dir, state_file, client_name, client_cn = sys.argv[1:5]

def load_json(path):
  try:
    with open(path, "r", encoding="utf-8") as f:
      data = json.load(f)
    if isinstance(data, dict):
      return data
  except Exception:
    pass
  return {}

def save_json(path, payload):
  dirn = os.path.dirname(path) or "."
  fd, tmp = tempfile.mkstemp(prefix=".tmp.", suffix=".json", dir=dirn)
  try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
      json.dump(payload, f, ensure_ascii=False, indent=2)
      f.write("\n")
      f.flush()
      os.fsync(f.fileno())
    os.replace(tmp, path)
    try:
      os.chmod(path, 0o600)
    except Exception:
      pass
  finally:
    try:
      if os.path.exists(tmp):
        os.remove(tmp)
    except Exception:
      pass

payload = load_json(state_file)
current_real = os.path.realpath(state_file)
seen_tokens = set()
seen_download_tokens = set()
for entry in os.listdir(clients_dir):
  if not entry.endswith(".json") or entry.startswith("."):
    continue
  path = os.path.join(clients_dir, entry)
  if os.path.realpath(path) == current_real:
    continue
  data = load_json(path)
  tok = str(data.get("ovpnws_token") or "").strip().lower()
  if re.fullmatch(r"[a-f0-9]{10}", tok):
    seen_tokens.add(tok)
  dlt = str(data.get("download_token") or "").strip().lower()
  if re.fullmatch(r"[a-f0-9]{16}", dlt):
    seen_download_tokens.add(dlt)

token = str(payload.get("ovpnws_token") or "").strip().lower()
if not re.fullmatch(r"[a-f0-9]{10}", token) or token in seen_tokens:
  for _ in range(256):
    token = secrets.token_hex(5)
    if token not in seen_tokens:
      break
  else:
    raise SystemExit(1)

download_token = str(payload.get("download_token") or "").strip().lower()
if not re.fullmatch(r"[a-f0-9]{16}", download_token) or download_token in seen_download_tokens:
  for _ in range(256):
    download_token = secrets.token_hex(8)
    if download_token not in seen_download_tokens:
      break
  else:
    raise SystemExit(1)

cn = str(client_cn or payload.get("client_cn") or client_name).strip()
created = str(payload.get("created_at") or "").strip() or datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%d")
payload.update({
  "managed_by": "autoscript-manage",
  "protocol": "openvpn",
  "client_name": client_name,
  "client_cn": cn,
  "created_at": created,
  "expired_at": str(payload.get("expired_at") or "-").strip()[:10] or "-",
  "ovpnws_token": token,
  "download_token": download_token,
})
save_json(state_file, payload)
print(token)
PY
}

openvpn_client_state_set_dates() {
  local name="${1:-}"
  local created_at="${2:-}"
  local expired_at="${3:-}"
  local state_file clients_dir
  openvpn_client_name_valid "${name}" || return 1
  state_file="$(openvpn_client_state_path_value "${name}")"
  clients_dir="$(openvpn_clients_dir_value)"
  install -d -m 700 "${clients_dir}" 2>/dev/null || true
  need_python3
  python3 - <<'PY' "${clients_dir}" "${state_file}" "${name}" "${created_at}" "${expired_at}"
import datetime
import json
import os
import re
import sys
import tempfile

clients_dir, state_file, client_name, created_at, expired_at = sys.argv[1:6]

def load_json(path):
  try:
    with open(path, "r", encoding="utf-8") as f:
      data = json.load(f)
    if isinstance(data, dict):
      return data
  except Exception:
    pass
  return {}

def save_json(path, payload):
  dirn = os.path.dirname(path) or "."
  fd, tmp = tempfile.mkstemp(prefix=".tmp.", suffix=".json", dir=dirn)
  try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
      json.dump(payload, f, ensure_ascii=False, indent=2)
      f.write("\n")
      f.flush()
      os.fsync(f.fileno())
    os.replace(tmp, path)
    try:
      os.chmod(path, 0o600)
    except Exception:
      pass
  finally:
    try:
      if os.path.exists(tmp):
        os.remove(tmp)
    except Exception:
      pass

def norm_date(value, fallback="-"):
  text = str(value or "").strip()
  if not text or text == "-":
    return fallback
  match = re.search(r"\d{4}-\d{2}-\d{2}", text)
  if match:
    return match.group(0)
  return fallback

payload = load_json(state_file)
client_cn = str(payload.get("client_cn") or client_name).strip() or client_name
created = norm_date(created_at, fallback=norm_date(payload.get("created_at"), fallback=datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%d")))
expired = norm_date(expired_at, fallback=norm_date(payload.get("expired_at"), fallback="-"))

payload.update({
  "managed_by": str(payload.get("managed_by") or "autoscript-manage"),
  "protocol": "openvpn",
  "client_name": client_name,
  "client_cn": client_cn,
  "created_at": created,
  "expired_at": expired,
})
save_json(state_file, payload)
PY
}

openvpn_client_ccd_path_for_cn() {
  local client_cn="${1:-}"
  printf '%s/%s\n' "$(openvpn_ccd_dir_value)" "${client_cn}"
}

openvpn_client_allow_cn() {
  local client_cn="${1:-}"
  local ccd_dir file
  ccd_dir="$(openvpn_ccd_dir_value)"
  file="$(openvpn_client_ccd_path_for_cn "${client_cn}")"
  install -d -m 755 "${ccd_dir}" 2>/dev/null || true
  {
    printf '# autoscript openvpn client\n'
    printf 'push-reset\n'
  } > "${file}"
  chmod 644 "${file}" 2>/dev/null || true
}

openvpn_client_access_sync_manage() {
  local name="${1:-}"
  local client_cn expired_at file
  openvpn_client_name_valid "${name}" || return 1
  openvpn_client_state_exists "${name}" || return 1
  client_cn="$(openvpn_client_cn_get "${name}")"
  expired_at="$(openvpn_client_expired_at_get "${name}")"
  file="$(openvpn_client_ccd_path_for_cn "${client_cn}")"
  if openvpn_expiry_is_active_manage "${expired_at}"; then
    openvpn_client_allow_cn "${client_cn}" || return 1
  else
    rm -f "${file}" >/dev/null 2>&1 || true
  fi
}

openvpn_client_access_sync_all_manage() {
  local row name
  while IFS= read -r row; do
    [[ -n "${row}" ]] || continue
    IFS='|' read -r name _ <<<"${row}"
    [[ -n "${name}" ]] || continue
    openvpn_client_access_sync_manage "${name}" >/dev/null 2>&1 || true
  done < <(openvpn_client_rows)
}

openvpn_expiry_sync_now_warn() {
  local name="${1:-}"
  if [[ -n "${name}" ]]; then
    if ! openvpn_client_access_sync_manage "${name}"; then
      warn "Sinkronisasi akses OpenVPN belum sepenuhnya berhasil untuk '${name}'."
      return 1
    fi
    return 0
  fi
  if ! openvpn_client_access_sync_all_manage; then
    warn "Sinkronisasi akses OpenVPN belum sepenuhnya berhasil."
    return 1
  fi
  return 0
}

openvpn_client_artifacts_remove() {
  local name="${1:-}"
  local bundle_file=""
  bundle_file="$(openvpn_client_bundle_path_value "${name}" 2>/dev/null || true)"
  rm -f \
    "$(openvpn_client_key_path_value "${name}")" \
    "$(openvpn_client_csr_path_value "${name}")" \
    "$(openvpn_client_cert_path_value "${name}")" \
    "$(openvpn_client_ext_path_value "${name}")" \
    "$(openvpn_client_profile_path_value "${name}")" \
    "$(openvpn_client_ssl_profile_path_value "${name}")" \
    "$(openvpn_client_ws_profile_path_value "${name}")" \
    "$(openvpn_client_ssl_helper_path_value "${name}")" \
    "$(openvpn_client_ws_helper_path_value "${name}")" \
    "$(openvpn_client_tcp_run_path_value "${name}")" \
    "$(openvpn_client_ssl_run_path_value "${name}")" \
    "$(openvpn_client_ws_run_path_value "${name}")" \
    "$(openvpn_account_info_file "${name}")" \
    "$(openvpn_client_state_path_value "${name}")" \
    "${bundle_file}" >/dev/null 2>&1 || true
}

openvpn_client_delete_manage() {
  local name="${1:-}"
  local client_cn=""
  openvpn_client_name_valid "${name}" || return 1
  client_cn="$(openvpn_client_cn_get "${name}")"
  [[ -n "${client_cn}" ]] && rm -f "$(openvpn_client_ccd_path_for_cn "${client_cn}")" >/dev/null 2>&1 || true
  openvpn_client_artifacts_remove "${name}"
}

openvpn_client_issue_certificate_manage() {
  local name="${1:-}"
  local client_cn="${2:-}"
  local pki_dir ca_file ca_key ca_srl tls_crypt_file
  local key csr crt ext
  pki_dir="$(openvpn_pki_dir_value)"
  ca_file="$(openvpn_ca_file_value)"
  ca_key="${pki_dir}/ca.key"
  ca_srl="${pki_dir}/ca.srl"
  tls_crypt_file="$(openvpn_tls_crypt_file_value)"
  key="$(openvpn_client_key_path_value "${name}")"
  csr="$(openvpn_client_csr_path_value "${name}")"
  crt="$(openvpn_client_cert_path_value "${name}")"
  ext="$(openvpn_client_ext_path_value "${name}")"

  [[ -n "${client_cn}" ]] || return 1
  [[ -f "${ca_file}" && -f "${ca_key}" && -f "${tls_crypt_file}" ]] || {
    warn "PKI OpenVPN belum siap. Jalankan setup OpenVPN terlebih dulu."
    return 1
  }

  install -d -m 700 "$(openvpn_clients_dir_value)" 2>/dev/null || true
  printf '%s\n' "basicConstraints=CA:FALSE" > "${ext}"
  printf '%s\n' "keyUsage = digitalSignature" >> "${ext}"
  printf '%s\n' "extendedKeyUsage = clientAuth" >> "${ext}"

  openssl genrsa -out "${key}" 4096 >/dev/null 2>&1 || return 1
  openssl req -new -key "${key}" -subj "/CN=${client_cn}" -out "${csr}" >/dev/null 2>&1 || return 1
  openssl x509 -req -in "${csr}" -CA "${ca_file}" -CAkey "${ca_key}" \
    -CAserial "${ca_srl}" -out "${crt}" -days 3650 -sha256 -extfile "${ext}" >/dev/null 2>&1 || return 1
  rm -f "${csr}" "${ext}" >/dev/null 2>&1 || true
  chmod 600 "${key}" "${crt}" >/dev/null 2>&1 || true
}

openvpn_client_render_embedded_profile_manage() {
  local profile="$1"
  local remote_host="$2"
  local remote_port="$3"
  local mode_label="$4"
  local note_block="${5:-}"
  local key_file="$6"
  local crt_file="$7"
  local ca_file tls_crypt_file
  ca_file="$(openvpn_ca_file_value)"
  tls_crypt_file="$(openvpn_tls_crypt_file_value)"
  need_python3
  python3 - <<'PY' "${profile}" "${remote_host}" "${remote_port}" "${ca_file}" "${crt_file}" "${key_file}" "${tls_crypt_file}" "${mode_label}" "${note_block}"
import sys
from pathlib import Path

out, remote_host, remote_port, ca_path, crt_path, key_path, tls_crypt_path, mode_label, note_block = sys.argv[1:]

def slurp(path):
  return Path(path).read_text(encoding="utf-8").strip() + "\n"

notes = []
for line in str(note_block or "").splitlines():
  text = line.strip()
  if text:
    notes.append(f"# {text}")
notes_text = ""
if notes:
  notes_text = "\n" + "\n".join(notes) + "\n"

payload = f"""client
dev tun
proto tcp-client
remote {remote_host} {remote_port}
nobind
persist-key
persist-tun
remote-cert-tls server
auth SHA256
cipher AES-256-GCM
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
verb 3
# Profile mode : {mode_label}{notes_text}

<ca>
{slurp(ca_path)}</ca>
<cert>
{slurp(crt_path)}</cert>
<key>
{slurp(key_path)}</key>
<tls-crypt>
{slurp(tls_crypt_path)}</tls-crypt>
"""
Path(out).write_text(payload, encoding="utf-8")
PY
  chmod 600 "${profile}" >/dev/null 2>&1 || true
}

openvpn_client_render_tcp_wrapper_manage() {
  local name="${1:-}"
  local profile_file runtime_profile tun_device out
  out="$(openvpn_client_tcp_run_path_value "${name}")"
  profile_file="$(basename "$(openvpn_client_profile_path_value "${name}")")"
  runtime_profile=".${name}-tcp-runtime.ovpn"
  tun_device="$(openvpn_client_tcp_tun_device_value "${name}")"
  cat > "${out}" <<EOF
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="\$(cd -- "\$(dirname -- "\${BASH_SOURCE[0]}")" && pwd)"
PROFILE_FILE="\${SCRIPT_DIR}/${profile_file}"
RUNTIME_PROFILE="\${SCRIPT_DIR}/${runtime_profile}"
TUN_DEVICE="${tun_device}"

cleanup_tun_state() {
  if command -v ip >/dev/null 2>&1; then
    ip route flush dev "\${TUN_DEVICE}" >/dev/null 2>&1 || true
    ip addr flush dev "\${TUN_DEVICE}" >/dev/null 2>&1 || true
    ip link set "\${TUN_DEVICE}" down >/dev/null 2>&1 || true
    ip link delete "\${TUN_DEVICE}" >/dev/null 2>&1 || true
  fi
}

cleanup() {
  cleanup_tun_state
  rm -f "\${RUNTIME_PROFILE}" >/dev/null 2>&1 || true
}

trap cleanup EXIT INT TERM

for arg in "\$@"; do
  if [[ "\${arg}" == "--daemon" ]]; then
    echo "Launcher TCP ini harus dijalankan foreground tanpa --daemon." >&2
    echo "Gunakan nohup/systemd luar jika ingin background, tetapi wrapper harus tetap hidup untuk cleanup." >&2
    exit 1
  fi
done

[[ -f "\${PROFILE_FILE}" ]] || {
  echo "Profile TCP tidak ditemukan: \${PROFILE_FILE}" >&2
  exit 1
}

cleanup_tun_state

python3 - "\${PROFILE_FILE}" "\${RUNTIME_PROFILE}" "\${TUN_DEVICE}" <<'PY'
import sys
from pathlib import Path

src, dst, tun_device = sys.argv[1:4]
lines = Path(src).read_text(encoding="utf-8").splitlines()
out = []
dev_rewritten = False
for line in lines:
  stripped = line.strip()
  if stripped == "dev tun" and not dev_rewritten:
    out.append("dev-type tun")
    out.append(f"dev {tun_device}")
    dev_rewritten = True
    continue
  if stripped in {"persist-key", "persist-tun"}:
    continue
  out.append(line)
if not dev_rewritten:
  out.insert(0, f"dev {tun_device}")
  out.insert(0, "dev-type tun")
Path(dst).write_text("\\n".join(out) + "\\n", encoding="utf-8")
PY

openvpn --config "\${RUNTIME_PROFILE}" "\$@" &
child_pid=\$!
wait "\${child_pid}"
EOF
  chmod 700 "${out}" >/dev/null 2>&1 || true
}

openvpn_client_render_ssl_helper_manage() {
  local name="${1:-}" connect_host="${2:-}" server_name="${3:-}" remote_port="${4:-}"
  local out
  out="$(openvpn_client_ssl_helper_path_value "${name}")"
  cat > "${out}" <<EOF
#!/usr/bin/env python3
import socket
import ssl
import threading

LISTEN_HOST = "127.0.0.1"
LISTEN_PORT = $(openvpn_client_ssl_local_port_value)
REMOTE_HOST = "${connect_host}"
REMOTE_PORT = ${remote_port}
SERVER_NAME = "${server_name}"


def pipe(src, dst):
  try:
    while True:
      data = src.recv(65536)
      if not data:
        break
      dst.sendall(data)
  except Exception:
    pass
  finally:
    try:
      dst.shutdown(socket.SHUT_WR)
    except Exception:
      pass
    try:
      dst.close()
    except Exception:
      pass
    try:
      src.close()
    except Exception:
      pass


def handle_client(client_sock):
  upstream = None
  tls_sock = None
  try:
    upstream = socket.create_connection((REMOTE_HOST, REMOTE_PORT), timeout=10)
    ctx = ssl.create_default_context()
    tls_sock = ctx.wrap_socket(upstream, server_hostname=SERVER_NAME)
    t1 = threading.Thread(target=pipe, args=(client_sock, tls_sock), daemon=True)
    t2 = threading.Thread(target=pipe, args=(tls_sock, client_sock), daemon=True)
    t1.start()
    t2.start()
    t1.join()
    t2.join()
  except Exception:
    try:
      client_sock.close()
    except Exception:
      pass
    try:
      if tls_sock is not None:
        tls_sock.close()
    except Exception:
      pass
    try:
      if upstream is not None:
        upstream.close()
    except Exception:
      pass


def main():
  server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
  server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
  server.bind((LISTEN_HOST, LISTEN_PORT))
  server.listen(16)
  try:
    while True:
      client_sock, _ = server.accept()
      threading.Thread(target=handle_client, args=(client_sock,), daemon=True).start()
  finally:
    server.close()


if __name__ == "__main__":
  main()
EOF
  chmod 700 "${out}" >/dev/null 2>&1 || true
}

openvpn_client_render_ws_helper_manage() {
  local name="${1:-}" connect_host="${2:-}" server_name="${3:-}" remote_port="${4:-}" ws_path="${5:-}"
  local out
  out="$(openvpn_client_ws_helper_path_value "${name}")"
  cat > "${out}" <<EOF
#!/usr/bin/env python3
import socket
import ssl
import threading

LISTEN_HOST = "127.0.0.1"
LISTEN_PORT = $(openvpn_client_ws_local_port_value)
REMOTE_HOST = "${connect_host}"
REMOTE_PORT = ${remote_port}
SERVER_NAME = "${server_name}"
WS_PATH = "${ws_path}"


def pipe(src, dst):
  try:
    while True:
      data = src.recv(65536)
      if not data:
        break
      dst.sendall(data)
  except Exception:
    pass
  finally:
    try:
      dst.shutdown(socket.SHUT_WR)
    except Exception:
      pass
    try:
      dst.close()
    except Exception:
      pass
    try:
      src.close()
    except Exception:
      pass


def handle_client(client_sock):
  upstream = None
  tls_sock = None
  try:
    upstream = socket.create_connection((REMOTE_HOST, REMOTE_PORT), timeout=10)
    ctx = ssl.create_default_context()
    tls_sock = ctx.wrap_socket(upstream, server_hostname=SERVER_NAME)
    request = (
      f"GET {WS_PATH} HTTP/1.1\\r\\n"
      f"Host: {SERVER_NAME}\\r\\n"
      "Upgrade: websocket\\r\\n"
      "Connection: Upgrade\\r\\n"
      "X-OVPN-WS: 1\\r\\n"
      "\\r\\n"
    ).encode("ascii")
    tls_sock.sendall(request)

    response = b""
    while b"\\r\\n\\r\\n" not in response:
      chunk = tls_sock.recv(4096)
      if not chunk:
        raise RuntimeError("empty websocket response")
      response += chunk
      if len(response) > 16384:
        raise RuntimeError("oversized websocket response")
    status_line = response.split(b"\\r\\n", 1)[0].decode("latin1", "replace")
    if "101" not in status_line:
      raise RuntimeError(status_line)

    _, tail = response.split(b"\\r\\n\\r\\n", 1)
    if tail:
      client_sock.sendall(tail)

    t1 = threading.Thread(target=pipe, args=(client_sock, tls_sock), daemon=True)
    t2 = threading.Thread(target=pipe, args=(tls_sock, client_sock), daemon=True)
    t1.start()
    t2.start()
    t1.join()
    t2.join()
  except Exception:
    try:
      client_sock.close()
    except Exception:
      pass
    try:
      if tls_sock is not None:
        tls_sock.close()
    except Exception:
      pass
    try:
      if upstream is not None:
        upstream.close()
    except Exception:
      pass


def main():
  server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
  server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
  server.bind((LISTEN_HOST, LISTEN_PORT))
  server.listen(16)
  try:
    while True:
      client_sock, _ = server.accept()
      threading.Thread(target=handle_client, args=(client_sock,), daemon=True).start()
  finally:
    server.close()


if __name__ == "__main__":
  main()
EOF
  chmod 700 "${out}" >/dev/null 2>&1 || true
}

openvpn_client_render_tunnel_launcher_manage() {
  local name="${1:-}" mode="${2:-ssl}"
  local helper_file profile_file helper_log helper_pid out
  case "${mode}" in
    ssl)
      helper_file="$(basename "$(openvpn_client_ssl_helper_path_value "${name}")")"
      profile_file="$(basename "$(openvpn_client_ssl_profile_path_value "${name}")")"
      helper_log="${name}-ssl-helper.log"
      helper_pid="${name}-ssl-helper.pid"
      out="$(openvpn_client_ssl_run_path_value "${name}")"
      ;;
    ws)
      helper_file="$(basename "$(openvpn_client_ws_helper_path_value "${name}")")"
      profile_file="$(basename "$(openvpn_client_ws_profile_path_value "${name}")")"
      helper_log="${name}-ws-helper.log"
      helper_pid="${name}-ws-helper.pid"
      out="$(openvpn_client_ws_run_path_value "${name}")"
      ;;
    *)
      return 1
      ;;
  esac
  cat > "${out}" <<EOF
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="\$(cd -- "\$(dirname -- "\${BASH_SOURCE[0]}")" && pwd)"
HELPER_FILE="\${SCRIPT_DIR}/${helper_file}"
PROFILE_FILE="\${SCRIPT_DIR}/${profile_file}"
HELPER_LOG="\${SCRIPT_DIR}/${helper_log}"
HELPER_PID="\${SCRIPT_DIR}/${helper_pid}"

cleanup() {
  if [[ -f "\${HELPER_PID}" ]]; then
    kill "\$(cat "\${HELPER_PID}")" >/dev/null 2>&1 || true
    rm -f "\${HELPER_PID}" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT INT TERM

for arg in "\$@"; do
  if [[ "\${arg}" == "--daemon" ]]; then
    echo "Launcher ini harus dijalankan foreground tanpa --daemon." >&2
    echo "Gunakan nohup/systemd luar jika ingin background, tetapi helper harus tetap hidup." >&2
    exit 1
  fi
done

python3 "\${HELPER_FILE}" >"\${HELPER_LOG}" 2>&1 &
echo \$! > "\${HELPER_PID}"
sleep 1
exec openvpn --config "\${PROFILE_FILE}" "\$@"
EOF
  chmod 700 "${out}" >/dev/null 2>&1 || true
}

openvpn_client_render_bundle_manage() {
  local name="${1:-}"
  local out tcp_profile ssl_profile ws_profile legacy_token legacy_path
  out="$(openvpn_client_bundle_path_value "${name}")" || return 1
  legacy_token="$(openvpn_client_download_token_get "${name}")"
  if openvpn_download_token_valid "${legacy_token}"; then
    legacy_path="$(openvpn_downloads_dir_value)/${legacy_token}.zip"
    [[ "${legacy_path}" == "${out}" ]] || rm -f "${legacy_path}" >/dev/null 2>&1 || true
  fi
  tcp_profile="$(openvpn_client_profile_path_value "${name}")"
  ssl_profile="$(openvpn_client_ssl_profile_path_value "${name}")"
  ws_profile="$(openvpn_client_ws_profile_path_value "${name}")"
  install -d -m 755 "$(openvpn_downloads_dir_value)" 2>/dev/null || true
  need_python3
  python3 - <<'PY' "${out}" "${tcp_profile}" "${ssl_profile}" "${ws_profile}"
import os
import sys
import tempfile
import zipfile

out, tcp_profile, ssl_profile, ws_profile = sys.argv[1:5]
files = [p for p in (tcp_profile, ssl_profile, ws_profile) if os.path.isfile(p)]
if not files:
  raise SystemExit(1)
dirn = os.path.dirname(out) or "."
fd, tmp = tempfile.mkstemp(prefix=".tmp.", suffix=".zip", dir=dirn)
os.close(fd)
try:
  with zipfile.ZipFile(tmp, "w", compression=zipfile.ZIP_DEFLATED) as zf:
    for path in files:
      zf.write(path, arcname=os.path.basename(path))
  os.replace(tmp, out)
  os.chmod(out, 0o644)
finally:
  try:
    if os.path.exists(tmp):
      os.remove(tmp)
  except Exception:
    pass
PY
}

openvpn_client_render_artifacts_manage() {
  local name="${1:-}"
  local remote_host="${2:-}"
  local remote_port="${3:-}"
  local key crt remote_ip connect_host server_name ws_token ws_path ws_alt_path
  local tcp_profile ssl_profile ws_profile
  key="$(openvpn_client_key_path_value "${name}")"
  crt="$(openvpn_client_cert_path_value "${name}")"
  tcp_profile="$(openvpn_client_profile_path_value "${name}")"
  ssl_profile="$(openvpn_client_ssl_profile_path_value "${name}")"
  ws_profile="$(openvpn_client_ws_profile_path_value "${name}")"
  [[ -n "${remote_host}" ]] || remote_host="$(detect_domain)"
  [[ -n "${remote_host}" ]] || remote_host="$(detect_public_ip_ipapi)"
  [[ -n "${remote_host}" ]] || remote_host="127.0.0.1"
  [[ -n "${remote_port}" ]] || remote_port="$(openvpn_client_public_port_manage)"
  remote_ip="$(detect_public_ip_ipapi)"
  connect_host="${remote_ip:-${remote_host}}"
  server_name="${remote_host}"
  ws_token="$(openvpn_client_state_upsert "${name}" "$(openvpn_client_cn_get "${name}")")"
  ws_path="$(openvpnws_path_from_token "${ws_token}" 2>/dev/null || true)"
  ws_alt_path="$(openvpnws_alt_path_from_token "${ws_token}" 2>/dev/null || true)"

  openvpn_client_render_embedded_profile_manage \
    "${tcp_profile}" \
    "${remote_host}" \
    "${remote_port}" \
    "TCP" \
    $'Gunakan profile ini langsung untuk mode OpenVPN TCP.\nLauncher cepat: '"$(basename "$(openvpn_client_tcp_run_path_value "${name}")")"$'\nCatatan      : launcher TCP membersihkan state tun lokal saat rerun cepat di host Linux.' \
    "${key}" \
    "${crt}"

  openvpn_client_render_embedded_profile_manage \
    "${ssl_profile}" \
    "127.0.0.1" \
    "$(openvpn_client_ssl_local_port_value)" \
    "SSL/TLS" \
    $'Jalankan helper TLS lokal sebelum memakai profile ini.\nLauncher cepat: '"$(basename "$(openvpn_client_ssl_run_path_value "${name}")")" \
    "${key}" \
    "${crt}"

  openvpn_client_render_embedded_profile_manage \
    "${ws_profile}" \
    "127.0.0.1" \
    "$(openvpn_client_ws_local_port_value)" \
    "WS" \
    $'Token        : '"${ws_token}"$'\nWS Path      : '"${ws_path}"$'\nWS Path Alt  : '"${ws_alt_path}"$'\nHeader       : X-OVPN-WS: 1\nLauncher cepat: '"$(basename "$(openvpn_client_ws_run_path_value "${name}")")" \
    "${key}" \
    "${crt}"

  openvpn_client_render_tcp_wrapper_manage "${name}"
  openvpn_client_render_ssl_helper_manage "${name}" "${connect_host}" "${server_name}" "${remote_port}"
  openvpn_client_render_ws_helper_manage "${name}" "${connect_host}" "${server_name}" "${remote_port}" "${ws_path}"
  openvpn_client_render_tunnel_launcher_manage "${name}" ssl
  openvpn_client_render_tunnel_launcher_manage "${name}" ws
  openvpn_client_render_bundle_manage "${name}"
}

openvpn_account_info_refresh() {
  local name="${1:-}"
  local info_file account_dir token download_url download_file ws_path ws_alt_path cn created expired access domain ip remote_port
  info_file="$(openvpn_account_info_file "${name}")"
  account_dir="$(openvpn_account_dir_value)"
  token="$(openvpn_client_state_token_get "${name}")"
  download_url="$(openvpn_client_bundle_url_value "${name}" 2>/dev/null || true)"
  download_file="$(openvpn_client_bundle_path_value "${name}" 2>/dev/null || true)"
  ws_path="-"
  ws_alt_path="-"
  if openvpnws_token_valid "${token}"; then
    ws_path="$(openvpnws_path_from_token "${token}" 2>/dev/null || true)"
    ws_alt_path="$(openvpnws_alt_path_from_token "${token}" 2>/dev/null || true)"
    if [[ "${ws_alt_path}" == /bebas/* ]]; then
      ws_alt_path="/<bebas>/${token}"
    fi
  fi
  cn="$(openvpn_client_cn_get "${name}")"
  created="$(openvpn_client_created_at_get "${name}")"
  expired="$(openvpn_client_expired_at_get "${name}")"
  if [[ -f "$(openvpn_client_ccd_path_for_cn "${cn}")" ]]; then
    access="yes"
  else
    access="no"
  fi
  domain="$(detect_domain)"
  ip="$(detect_public_ip_ipapi)"
  remote_port="$(openvpn_client_public_port_manage)"

  install -d -m 700 "${account_dir}" 2>/dev/null || true
  {
    printf '%s\n' "=== OPENVPN ACCOUNT INFO ==="
    printf '%-12s : %s\n' "Domain" "${domain:-"-"}"
    printf '%-12s : %s\n' "IP" "${ip:-"-"}"
    printf '%-12s : %s\n' "Client Name" "${name}"
    printf '%-12s : %s\n' "Client CN" "${cn}"
    printf '%-12s : %s\n' "Created" "${created}"
    printf '%-12s : %s\n' "Expired" "${expired:-"-"}"
    printf '%-12s : %s\n' "Access" "${access}"
    printf '%-12s : %s\n' "TCP Remote" "${domain:-$ip}:${remote_port}"
    printf '%-12s : %s\n' "SSL Remote" "${domain:-$ip}:443"
    printf '%-12s : %s\n' "WS Remote" "${domain:-$ip}:443"
    printf '%-12s : %s\n' "WS Token" "${token:-"-"}"
    printf '%-12s : %s\n' "WS Path" "${ws_path}"
    printf '%-12s : %s\n' "WS Path Alt" "${ws_alt_path}"
    printf '%-12s : %s\n' "TCP Profile" "$(openvpn_client_profile_path_value "${name}")"
    printf '%-12s : %s\n' "SSL Profile" "$(openvpn_client_ssl_profile_path_value "${name}")"
    printf '%-12s : %s\n' "WS Profile" "$(openvpn_client_ws_profile_path_value "${name}")"
    printf '%-12s : %s\n' "ZIP URL" "${download_url:-"-"}"
    printf '%-12s : %s\n' "ZIP File" "${download_file:-"-"}"
  } > "${info_file}"
  chmod 600 "${info_file}" 2>/dev/null || true
}

openvpn_client_add_rollback() {
  local name="${1:-}" cn="${2:-}" msg="${3:-}"
  [[ -n "${cn}" ]] && rm -f "$(openvpn_client_ccd_path_for_cn "${cn}")" >/dev/null 2>&1 || true
  openvpn_client_artifacts_remove "${name}"
  if [[ -n "${msg}" ]]; then
    warn "${msg}"
  fi
}

openvpn_client_rows() {
  local clients_dir ccd_dir
  clients_dir="$(openvpn_clients_dir_value)"
  ccd_dir="$(openvpn_ccd_dir_value)"
  [[ -d "${clients_dir}" ]] || return 0
  need_python3
  python3 - <<'PY' "${clients_dir}" "${ccd_dir}" 2>/dev/null || true
import json
import os
import sys

clients_dir, ccd_dir = sys.argv[1:3]
rows = []
for entry in os.listdir(clients_dir):
  if not entry.endswith(".json") or entry.startswith("."):
    continue
  path = os.path.join(clients_dir, entry)
  name = entry[:-5]
  created = "-"
  expired = "-"
  token = ""
  cn = name
  try:
    with open(path, "r", encoding="utf-8") as f:
      data = json.load(f)
    if isinstance(data, dict):
      created = str(data.get("created_at") or "-").strip() or "-"
      expired = str(data.get("expired_at") or "-").strip()[:10] or "-"
      token = str(data.get("ovpnws_token") or "").strip().lower()
      cn = str(data.get("client_cn") or name).strip() or name
  except Exception:
    pass
  allowed = "yes" if os.path.exists(os.path.join(ccd_dir, cn)) else "no"
  rows.append((name.lower(), name, cn, created, expired, token, allowed))
for _, name, cn, created, expired, token, allowed in sorted(rows):
  print("|".join([name, cn, created, expired, token, allowed]))
PY
}

openvpn_client_count_value() {
  local count=0 row=""
  while IFS= read -r row; do
    [[ -n "${row}" ]] || continue
    count=$((count + 1))
  done < <(openvpn_client_rows)
  printf '%s\n' "${count}"
}
