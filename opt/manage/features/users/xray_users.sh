#!/usr/bin/env bash
# shellcheck shell=bash

XRAY_EDGE_RUNTIME_ENV_FILE="${XRAY_EDGE_RUNTIME_ENV_FILE:-/etc/default/edge-runtime}"

xray_edge_runtime_env_value() {
  local key="$1"
  [[ -r "${XRAY_EDGE_RUNTIME_ENV_FILE}" ]] || return 1
  awk -F= -v key="${key}" '
    $1 == key {
      sub(/^[[:space:]]+/, "", $2)
      sub(/[[:space:]]+$/, "", $2)
      print $2
      exit
    }
  ' "${XRAY_EDGE_RUNTIME_ENV_FILE}"
}

xray_edge_runtime_port_list() {
  local list_key="$1" single_key="$2" fallback_list="$3" fallback_single="$4"
  local raw
  raw="$(xray_edge_runtime_env_value "${list_key}" 2>/dev/null || true)"
  if [[ -z "${raw}" ]]; then
    raw="$(xray_edge_runtime_env_value "${single_key}" 2>/dev/null || true)"
  fi
  if [[ -z "${raw}" ]]; then
    raw="${fallback_list:-${fallback_single}}"
  fi
  awk '
    {
      gsub(/,/, " ")
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^[0-9]+$/ && !seen[$i]++) {
          out = out (out ? " " : "") $i
        }
      }
    }
    END { print out }
  ' <<< "${raw}"
}

xray_edge_runtime_ports_label() {
  local ports="${1:-}"
  [[ -n "${ports}" ]] || {
    printf '%s\n' "-"
    return 0
  }
  printf '%s\n' "${ports}" | sed 's/ /, /g'
}

xray_edge_runtime_public_http_ports_label() {
  xray_edge_runtime_ports_label "$(xray_edge_runtime_port_list EDGE_PUBLIC_HTTP_PORTS EDGE_PUBLIC_HTTP_PORT "80 8080 8880 2052 2082 2086 2095" "80")"
}

xray_edge_runtime_public_tls_ports_label() {
  xray_edge_runtime_ports_label "$(xray_edge_runtime_port_list EDGE_PUBLIC_TLS_PORTS EDGE_PUBLIC_TLS_PORT "443 2053 2083 2087 2096 8443" "443")"
}

xray_edge_runtime_all_public_ports_label() {
  local tls_ports http_ports merged
  tls_ports="$(xray_edge_runtime_port_list EDGE_PUBLIC_TLS_PORTS EDGE_PUBLIC_TLS_PORT "443 2053 2083 2087 2096 8443" "443")"
  http_ports="$(xray_edge_runtime_port_list EDGE_PUBLIC_HTTP_PORTS EDGE_PUBLIC_HTTP_PORT "80 8080 8880 2052 2082 2086 2095" "80")"
  merged="$(printf '%s %s\n' "${tls_ports}" "${http_ports}" | awk '
    {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^[0-9]+$/ && !seen[$i]++) {
          out = out (out ? " " : "") $i
        }
      }
    }
    END { print out }
  ')"
  xray_edge_runtime_ports_label "${merged}"
}

xray_edge_runtime_primary_ports_label() {
  local tls_ports http_ports primary=""
  tls_ports="$(xray_edge_runtime_port_list EDGE_PUBLIC_TLS_PORTS EDGE_PUBLIC_TLS_PORT "443 2053 2083 2087 2096 8443" "443")"
  http_ports="$(xray_edge_runtime_port_list EDGE_PUBLIC_HTTP_PORTS EDGE_PUBLIC_HTTP_PORT "80 8080 8880 2052 2082 2086 2095" "80")"
  for port in ${tls_ports}; do
    primary="${port}"
    break
  done
  for port in ${http_ports}; do
    if [[ -n "${primary}" && "${port}" != "${primary}" ]]; then
      primary+=" ${port}"
    elif [[ -z "${primary}" ]]; then
      primary="${port}"
    fi
    break
  done
  xray_edge_runtime_ports_label "${primary}"
}

xray_edge_runtime_ws_ports_label() {
  xray_edge_runtime_all_public_ports_label
}

xray_edge_runtime_alt_tls_ports_label() {
  local ports out=() port
  ports="$(xray_edge_runtime_port_list EDGE_PUBLIC_TLS_PORTS EDGE_PUBLIC_TLS_PORT "443 2053 2083 2087 2096 8443" "443")"
  for port in ${ports}; do
    [[ "${port}" == "443" ]] && continue
    out+=("${port}")
  done
  if (( ${#out[@]} > 0 )); then
    printf '%s\n' "${out[*]}" | sed 's/ /, /g'
  else
    printf '%s\n' "-"
  fi
}

xray_edge_runtime_alt_http_ports_label() {
  local ports out=() port
  ports="$(xray_edge_runtime_port_list EDGE_PUBLIC_HTTP_PORTS EDGE_PUBLIC_HTTP_PORT "80 8080 8880 2052 2082 2086 2095" "80")"
  for port in ${ports}; do
    [[ "${port}" == "80" ]] && continue
    out+=("${port}")
  done
  if (( ${#out[@]} > 0 )); then
    printf '%s\n' "${out[*]}" | sed 's/ /, /g'
  else
    printf '%s\n' "-"
  fi
}


xray_backup_config() {
  # Create operation-local backup file to avoid cross-operation overwrite.
  # args: file_path (optional)
  local src b base
  src="${1:-${XRAY_INBOUNDS_CONF}}"
  base="$(basename "${src}")"

  [[ -f "${src}" ]] || die "File backup source tidak ditemukan: ${src}"
  mkdir -p "${WORK_DIR}" 2>/dev/null || true

  b="$(mktemp "${WORK_DIR}/${base}.prev.XXXXXX")" || die "Gagal membuat file backup untuk: ${src}"
  if ! cp -a "${src}" "${b}"; then
    rm -f "${b}" 2>/dev/null || true
    die "Gagal membuat backup untuk: ${src}"
  fi

  # Best-effort housekeeping: hapus backup historis (>7 hari) untuk file yang sama.
  find "${WORK_DIR}" -maxdepth 1 -type f -name "${base}.prev.*" -mtime +7 -delete 2>/dev/null || true

  echo "${b}"
}

xray_backup_path_prepare() {
  # Reserve a unique backup path without copying file content yet.
  # Use this when snapshot must be taken inside an existing lock section.
  local src="$1"
  local base path
  base="$(basename "${src}")"
  mkdir -p "${WORK_DIR}" 2>/dev/null || true
  path="$(mktemp "${WORK_DIR}/${base}.prev.XXXXXX")" || die "Gagal menyiapkan path backup untuk: ${src}"
  rm -f "${path}" 2>/dev/null || true
  echo "${path}"
}




xray_write_file_atomic() {
  # args: dest_path tmp_json_path
  local dest="$1"
  local src_tmp="$2"
  local dir base tmp_target mode uid gid

  dir="$(dirname "${dest}")"
  base="$(basename "${dest}")"

  ensure_path_writable "${dest}"

  tmp_target="$(mktemp "${dir}/.${base}.new.XXXXXX" 2>/dev/null || true)"
  [[ -n "${tmp_target}" ]] || die "Gagal membuat temp file untuk replace: ${dest}"

  mode="$(stat -c '%a' "${dest}" 2>/dev/null || echo '600')"
  uid="$(stat -c '%u' "${dest}" 2>/dev/null || echo '0')"
  gid="$(stat -c '%g' "${dest}" 2>/dev/null || echo '0')"

  if ! cp -f "${src_tmp}" "${tmp_target}"; then
    rm -f "${tmp_target}" 2>/dev/null || true
    die "Gagal menyiapkan temp file untuk replace: ${dest}"
  fi
  chmod "${mode}" "${tmp_target}" 2>/dev/null || chmod 600 "${tmp_target}" || true
  chown "${uid}:${gid}" "${tmp_target}" 2>/dev/null || chown 0:0 "${tmp_target}" || true

  mv -f "${tmp_target}" "${dest}" || {
    rm -f "${tmp_target}" 2>/dev/null || true
    die "Gagal replace ${dest} (permission denied / filesystem read-only / immutable)."
  }
}

xray_write_config_atomic() {
  # Backward-compat wrapper (writes inbounds conf).
  # args: tmp_json_path
  xray_write_file_atomic "${XRAY_INBOUNDS_CONF}" "$1"
}

xray_restart_or_rollback_file() {
  # args: target_file backup_file context_label
  local target="$1"
  local backup="$2"
  local ctx="${3:-config}"
  if ! xray_restart_checked; then
    cp -a "${backup}" "${target}" 2>/dev/null || die "xray tidak aktif setelah update ${ctx}; restore backup juga gagal: ${backup}"
    if ! xray_restart_checked; then
      die "xray tidak aktif setelah update ${ctx}; rollback runtime juga gagal setelah restore backup: ${backup}"
    fi
    die "xray tidak aktif setelah update ${ctx}. Config di-rollback ke backup: ${backup}"
  fi
}

xray_write_routing_locked() {
  # Wrapper xray_write_file_atomic untuk ROUTING_CONF dengan flock.
  # Gunakan ini untuk semua write ke 30-routing.json agar sinkron dengan
  # daemon Python (xray-quota, limit-ip, user-block) yang pakai lock yang sama.
  # args: tmp_json_path
  local tmp="$1"
  (
    flock -x 200
    xray_write_file_atomic "${XRAY_ROUTING_CONF}" "${tmp}"
  ) 200>"${ROUTING_LOCK_FILE}"
}

xray_txn_changed_flag() {
  # args: output_blob -> prints 1 or 0
  local out="${1:-}"
  local changed
  changed="$(printf '%s\n' "${out}" | awk -F'=' '/^changed=/{print $2; exit}')"
  if [[ "${changed}" == "1" ]]; then
    echo "1"
  else
    echo "0"
  fi
}

xray_txn_rc_or_die() {
  # args: rc fail_msg [restart_fail_msg] [syntax_fail_msg] [rollback_fail_msg]
  local rc="$1"
  local fail_msg="$2"
  local restart_fail_msg="${3:-}"
  local syntax_fail_msg="${4:-}"
  local rollback_fail_msg="${5:-}"

  if (( rc == 0 )); then
    return 0
  fi
  if (( rc == 87 )) && [[ -n "${syntax_fail_msg}" ]]; then
    die "${syntax_fail_msg}"
  fi
  if (( rc == 86 )) && [[ -n "${restart_fail_msg}" ]]; then
    die "${restart_fail_msg}"
  fi
  if (( rc == 88 )) && [[ -n "${rollback_fail_msg}" ]]; then
    die "${rollback_fail_msg}"
  fi
  die "${fail_msg}"
}

xray_txn_rc_or_warn() {
  # args: rc fail_msg [restart_fail_msg] [syntax_fail_msg] [rollback_fail_msg]
  local rc="$1"
  local fail_msg="$2"
  local restart_fail_msg="${3:-}"
  local syntax_fail_msg="${4:-}"
  local rollback_fail_msg="${5:-}"

  if (( rc == 0 )); then
    return 0
  fi
  if (( rc == 87 )) && [[ -n "${syntax_fail_msg}" ]]; then
    warn "${syntax_fail_msg}"
    return 1
  fi
  if (( rc == 86 )) && [[ -n "${restart_fail_msg}" ]]; then
    warn "${restart_fail_msg}"
    return 1
  fi
  if (( rc == 88 )) && [[ -n "${rollback_fail_msg}" ]]; then
    warn "${rollback_fail_msg}"
    return 1
  fi
  warn "${fail_msg}"
  return 1
}



xray_add_client() {
  # args: protocol username uuid_or_pass
  local proto="$1"
  local username="$2"
  local cred="$3"

  local email="${username}@${proto}"
  need_python3

  [[ -f "${XRAY_INBOUNDS_CONF}" ]] || die "Xray inbounds conf tidak ditemukan: ${XRAY_INBOUNDS_CONF}"
  ensure_path_writable "${XRAY_INBOUNDS_CONF}"

  local backup tmp out changed rc
  backup="$(xray_backup_path_prepare "${XRAY_INBOUNDS_CONF}")"
  tmp="${WORK_DIR}/10-inbounds.add.tmp"

  set +e
  out="$(
    (
      flock -x 200
      cp -a "${XRAY_INBOUNDS_CONF}" "${backup}" || exit 1

      py_out="$(
        python3 - <<'PY' "${XRAY_INBOUNDS_CONF}" "${tmp}" "${proto}" "${email}" "${cred}"
import json
import sys

src, dst, proto, email, cred = sys.argv[1:6]

with open(src, "r", encoding="utf-8") as f:
  cfg = json.load(f)

inbounds = cfg.get("inbounds", [])
if not isinstance(inbounds, list):
  raise SystemExit("Invalid config: inbounds is not a list")

def inbound_matches_proto(ib, p):
  if not isinstance(ib, dict):
    return False
  ib_proto = str(ib.get("protocol") or "").strip().lower()
  if p in ("vless", "vmess", "trojan"):
    return ib_proto == p
  return False

def iter_clients_for_protocol(p):
  for ib in inbounds:
    if not inbound_matches_proto(ib, p):
      continue
    st = ib.get("settings") or {}
    clients = st.get("clients")
    if isinstance(clients, list):
      for c in clients:
        yield c

for c in iter_clients_for_protocol(proto):
  if c.get("email") == email:
    raise SystemExit(f"user sudah ada di config untuk {proto}: {email}")

if proto == "vless":
  client = {"id": cred, "email": email}
elif proto == "vmess":
  client = {"id": cred, "alterId": 0, "email": email}
elif proto == "trojan":
  client = {"password": cred, "email": email}
else:
  raise SystemExit("Unsupported protocol: " + proto)

updated = False
for ib in inbounds:
  if not inbound_matches_proto(ib, proto):
    continue
  st = ib.setdefault("settings", {})
  clients = st.get("clients")
  if clients is None:
    st["clients"] = []
    clients = st["clients"]
  if not isinstance(clients, list):
    continue
  clients.append(client)
  updated = True

if not updated:
  raise SystemExit(f"Tidak menemukan inbound protocol {proto} dengan settings.clients")

with open(dst, "w", encoding="utf-8") as f:
  json.dump(cfg, f, ensure_ascii=False, indent=2)
  f.write("\n")

print("changed=1")
PY
      )" || exit 1

      printf '%s\n' "${py_out}"
      changed_local="$(xray_txn_changed_flag "${py_out}")"

      if [[ "${changed_local}" == "1" ]]; then
        xray_write_file_atomic "${XRAY_INBOUNDS_CONF}" "${tmp}" || {
          restore_file_if_exists "${backup}" "${XRAY_INBOUNDS_CONF}"
          exit 1
        }

        if ! xray_restart_checked; then
          if ! restore_file_if_exists "${backup}" "${XRAY_INBOUNDS_CONF}"; then
            exit 1
          fi
          if ! xray_restart_checked; then
            exit 88
          fi
          exit 86
        fi
      fi
    ) 200>"${ROUTING_LOCK_FILE}"
  )"
  rc=$?
  set -e

  xray_txn_rc_or_die "${rc}" \
    "Gagal memproses inbounds untuk add user: ${email}" \
    "xray tidak aktif setelah add user. Config di-rollback ke backup: ${backup}" \
    "" \
    "xray tidak aktif setelah add user, dan rollback runtime juga gagal setelah restore backup: ${backup}"

  changed="$(xray_txn_changed_flag "${out}")"
  if [[ "${changed}" != "1" ]]; then
    return 0
  fi
  return 0
}

xray_delete_client() {
  # args: protocol username
  local proto="$1"
  local username="$2"

  local email="${username}@${proto}"
  need_python3

  [[ -f "${XRAY_INBOUNDS_CONF}" ]] || die "Xray inbounds conf tidak ditemukan: ${XRAY_INBOUNDS_CONF}"
  [[ -f "${XRAY_ROUTING_CONF}" ]] || die "Xray routing conf tidak ditemukan: ${XRAY_ROUTING_CONF}"
  ensure_path_writable "${XRAY_INBOUNDS_CONF}"
  ensure_path_writable "${XRAY_ROUTING_CONF}"

  local backup_inb backup_rt tmp_inb tmp_rt out changed rc
  backup_inb="$(xray_backup_path_prepare "${XRAY_INBOUNDS_CONF}")"
  backup_rt="$(xray_backup_path_prepare "${XRAY_ROUTING_CONF}")"
  tmp_inb="${WORK_DIR}/10-inbounds.delete.tmp"
  tmp_rt="${WORK_DIR}/30-routing.delete.tmp"

  set +e
  out="$(
    (
      flock -x 200
      cp -a "${XRAY_INBOUNDS_CONF}" "${backup_inb}" || exit 1
      cp -a "${XRAY_ROUTING_CONF}" "${backup_rt}" || exit 1

      py_out="$(
        python3 - <<'PY' "${XRAY_INBOUNDS_CONF}" "${XRAY_ROUTING_CONF}" "${tmp_inb}" "${tmp_rt}" "${proto}" "${email}"
import json
import sys

inb_src, rt_src, inb_dst, rt_dst, proto, email = sys.argv[1:7]

with open(inb_src, "r", encoding="utf-8") as f:
  inb_cfg = json.load(f)
with open(rt_src, "r", encoding="utf-8") as f:
  rt_cfg = json.load(f)

inbounds = inb_cfg.get("inbounds", [])
if not isinstance(inbounds, list):
  raise SystemExit("Invalid inbounds config: inbounds is not a list")

def inbound_matches_proto(ib, p):
  if not isinstance(ib, dict):
    return False
  ib_proto = str(ib.get("protocol") or "").strip().lower()
  if p in ("vless", "vmess", "trojan"):
    return ib_proto == p
  return False

removed = 0
for ib in inbounds:
  if not inbound_matches_proto(ib, proto):
    continue
  st = ib.get("settings") or {}
  clients = st.get("clients")
  if not isinstance(clients, list):
    continue
  before = len(clients)
  clients[:] = [c for c in clients if c.get("email") != email]
  removed += (before - len(clients))
  st["clients"] = clients
  ib["settings"] = st

routing = (rt_cfg.get("routing") or {})
rules = routing.get("rules")
routing_changed = False
if isinstance(rules, list):
  markers = {"dummy-block-user","dummy-quota-user","dummy-limit-user","dummy-warp-user","dummy-direct-user"}
  speed_marker_prefix = "dummy-speed-user-"
  for r in rules:
    if not isinstance(r, dict):
      continue
    u = r.get("user")
    if not isinstance(u, list):
      continue
    managed = any(m in u for m in markers)
    if not managed:
      managed = any(isinstance(x, str) and x.startswith(speed_marker_prefix) for x in u)
    if not managed:
      continue
    new_users = [x for x in u if x != email]
    if new_users != u:
      routing_changed = True
    r["user"] = new_users
  routing["rules"] = rules
  rt_cfg["routing"] = routing

changed = removed > 0 or routing_changed
if not changed:
  print("changed=0")
  raise SystemExit(0)

with open(inb_dst, "w", encoding="utf-8") as f:
  json.dump(inb_cfg, f, ensure_ascii=False, indent=2)
  f.write("\n")
with open(rt_dst, "w", encoding="utf-8") as f:
  json.dump(rt_cfg, f, ensure_ascii=False, indent=2)
  f.write("\n")

print("changed=1")
PY
      )" || exit 1

      printf '%s\n' "${py_out}"
      changed_local="$(xray_txn_changed_flag "${py_out}")"

      if [[ "${changed_local}" == "1" ]]; then
        xray_write_file_atomic "${XRAY_INBOUNDS_CONF}" "${tmp_inb}" || {
          restore_file_if_exists "${backup_inb}" "${XRAY_INBOUNDS_CONF}"
          restore_file_if_exists "${backup_rt}" "${XRAY_ROUTING_CONF}"
          exit 1
        }
        xray_write_file_atomic "${XRAY_ROUTING_CONF}" "${tmp_rt}" || {
          restore_file_if_exists "${backup_inb}" "${XRAY_INBOUNDS_CONF}"
          restore_file_if_exists "${backup_rt}" "${XRAY_ROUTING_CONF}"
          exit 1
        }

        if ! xray_restart_checked; then
          if ! restore_file_if_exists "${backup_inb}" "${XRAY_INBOUNDS_CONF}"; then
            exit 1
          fi
          if ! restore_file_if_exists "${backup_rt}" "${XRAY_ROUTING_CONF}"; then
            exit 1
          fi
          if ! xray_restart_checked; then
            exit 88
          fi
          exit 86
        fi
      fi
    ) 200>"${ROUTING_LOCK_FILE}"
  )"
  rc=$?
  set -e

  xray_txn_rc_or_die "${rc}" \
    "Gagal memproses delete user (rollback ke backup): ${email}" \
    "xray tidak aktif setelah delete user. Config di-rollback ke backup." \
    "" \
    "xray tidak aktif setelah delete user, dan rollback runtime juga gagal setelah restore backup."

  changed="$(xray_txn_changed_flag "${out}")"
  if [[ "${changed}" != "1" ]]; then
    return 0
  fi
  return 0
}

xray_reset_client_credential() {
  # args: protocol username uuid_or_pass
  local proto="$1"
  local username="$2"
  local cred="$3"

  local email="${username}@${proto}"
  need_python3

  [[ -f "${XRAY_INBOUNDS_CONF}" ]] || die "Xray inbounds conf tidak ditemukan: ${XRAY_INBOUNDS_CONF}"
  ensure_path_writable "${XRAY_INBOUNDS_CONF}"

  local backup tmp out changed rc
  backup="$(xray_backup_path_prepare "${XRAY_INBOUNDS_CONF}")"
  tmp="${WORK_DIR}/10-inbounds.reset-cred.tmp"

  set +e
  out="$(
    (
      flock -x 200
      cp -a "${XRAY_INBOUNDS_CONF}" "${backup}" || exit 1

      py_out="$(
        python3 - <<'PY' "${XRAY_INBOUNDS_CONF}" "${tmp}" "${proto}" "${email}" "${cred}"
import json
import sys

src, dst, proto, email, cred = sys.argv[1:6]

with open(src, "r", encoding="utf-8") as f:
  cfg = json.load(f)

inbounds = cfg.get("inbounds", [])
if not isinstance(inbounds, list):
  raise SystemExit("Invalid config: inbounds is not a list")

def inbound_matches_proto(ib, p):
  if not isinstance(ib, dict):
    return False
  ib_proto = str(ib.get("protocol") or "").strip().lower()
  if p in ("vless", "vmess", "trojan"):
    return ib_proto == p
  return False

updated = 0
for ib in inbounds:
  if not inbound_matches_proto(ib, proto):
    continue
  st = ib.get("settings") or {}
  clients = st.get("clients")
  if not isinstance(clients, list):
    continue
  for c in clients:
    if not isinstance(c, dict):
      continue
    if c.get("email") != email:
      continue
    if proto == "trojan":
      c["password"] = cred
      c.pop("id", None)
    else:
      c["id"] = cred
      c.pop("password", None)
      if proto == "vmess":
        try:
          c["alterId"] = int(c.get("alterId") or 0)
        except Exception:
          c["alterId"] = 0
    updated += 1

if updated == 0:
  raise SystemExit(f"user tidak ditemukan di config untuk {proto}: {email}")

with open(dst, "w", encoding="utf-8") as f:
  json.dump(cfg, f, ensure_ascii=False, indent=2)
  f.write("\n")

print("changed=1")
PY
      )" || exit 1

      printf '%s\n' "${py_out}"
      changed_local="$(xray_txn_changed_flag "${py_out}")"

      if [[ "${changed_local}" == "1" ]]; then
        xray_write_file_atomic "${XRAY_INBOUNDS_CONF}" "${tmp}" || {
          restore_file_if_exists "${backup}" "${XRAY_INBOUNDS_CONF}"
          exit 1
        }

        if ! xray_restart_checked; then
          if ! restore_file_if_exists "${backup}" "${XRAY_INBOUNDS_CONF}"; then
            exit 1
          fi
          if ! xray_restart_checked; then
            exit 88
          fi
          exit 86
        fi
      fi
    ) 200>"${ROUTING_LOCK_FILE}"
  )"
  rc=$?
  set -e

  xray_txn_rc_or_die "${rc}" \
    "Gagal reset UUID/password user: ${email}" \
    "xray tidak aktif setelah reset UUID/password. Config di-rollback ke backup: ${backup}" \
    "" \
    "xray tidak aktif setelah reset UUID/password, dan rollback runtime juga gagal setelah restore backup: ${backup}"

  changed="$(xray_txn_changed_flag "${out}")"
  if [[ "${changed}" != "1" ]]; then
    return 0
  fi
  return 0
}

xray_routing_set_user_in_marker() {
  # args: marker email on|off [outbound_tag]
  # outbound_tag defaults to 'blocked' for backward compatibility
  local marker="$1"
  local email="$2"
  local state="$3"
  # BUG-08 fix: outboundTag is now a parameter instead of hardcoded 'blocked'.
  # Previously this function silently failed for any marker whose rule used a
  # different outboundTag (e.g. dummy-warp-user → 'warp', dummy-direct-user → 'direct').
  local outbound_tag="${4:-blocked}"

  need_python3
  [[ -f "${XRAY_ROUTING_CONF}" ]] || die "Xray routing conf tidak ditemukan: ${XRAY_ROUTING_CONF}"
  ensure_path_writable "${XRAY_ROUTING_CONF}"

  local backup tmp out changed rc
  backup="$(xray_backup_path_prepare "${XRAY_ROUTING_CONF}")"
  tmp="${WORK_DIR}/30-routing.marker.tmp"

  # Load + modify + save + restart + rollback di lock yang sama agar tidak menimpa perubahan concurrent.
  set +e
  out="$(
    (
      flock -x 200
      cp -a "${XRAY_ROUTING_CONF}" "${backup}" || exit 1

      py_out="$(
        python3 - <<'PY' "${XRAY_ROUTING_CONF}" "${tmp}" "${marker}" "${email}" "${state}" "${outbound_tag}"
import json, sys
src, dst, marker, email, state, outbound_tag = sys.argv[1:7]

with open(src, "r", encoding="utf-8") as f:
  cfg = json.load(f)

routing = cfg.get("routing") or {}
rules = routing.get("rules")
if not isinstance(rules, list):
  raise SystemExit("Invalid routing config: routing.rules is not a list")

target = None
for r in rules:
  if not isinstance(r, dict):
    continue
  if r.get("type") != "field":
    continue
  if r.get("outboundTag") != outbound_tag:
    continue
  u = r.get("user")
  if not isinstance(u, list):
    continue
  if marker in u:
    target = r
    break

if target is None:
  raise SystemExit(f"Tidak menemukan routing rule outboundTag={outbound_tag} dengan marker: {marker}")

users = target.get("user") or []
if not isinstance(users, list):
  users = []

if marker not in users:
  users.insert(0, marker)
else:
  users = [marker] + [x for x in users if x != marker]

changed = False
if state == "on":
  if email not in users:
    users.append(email)
    changed = True
elif state == "off":
  new_users = [x for x in users if x != email]
  if new_users != users:
    users = new_users
    changed = True
else:
  raise SystemExit("state harus 'on' atau 'off'")

target["user"] = users
hard_block_markers = {"dummy-block-user", "dummy-quota-user", "dummy-limit-user"}

def is_api_rule(rule):
  return isinstance(rule, dict) and rule.get("type") == "field" and rule.get("outboundTag") == "api"

def is_static_block_rule(rule):
  if not isinstance(rule, dict) or rule.get("type") != "field":
    return False
  if rule.get("outboundTag") != "blocked":
    return False
  users_local = rule.get("user")
  return not isinstance(users_local, list)

def is_hard_block_user_rule(rule):
  if not isinstance(rule, dict) or rule.get("type") != "field":
    return False
  if rule.get("outboundTag") != "blocked":
    return False
  users_local = rule.get("user")
  if not isinstance(users_local, list):
    return False
  return any(item in hard_block_markers for item in users_local if isinstance(item, str))

prefix_rules = []
hard_block_rules = []
other_rules = []
for rule in rules:
  if is_api_rule(rule) or is_static_block_rule(rule):
    prefix_rules.append(rule)
  elif is_hard_block_user_rule(rule):
    hard_block_rules.append(rule)
  else:
    other_rules.append(rule)

rules = prefix_rules + hard_block_rules + other_rules
routing["rules"] = rules
cfg["routing"] = routing

if changed:
  with open(dst, "w", encoding="utf-8") as wf:
    json.dump(cfg, wf, ensure_ascii=False, indent=2)
    wf.write("\n")

print("changed=1" if changed else "changed=0")
PY
      )" || exit 1

      printf '%s\n' "${py_out}"
      changed_local="$(xray_txn_changed_flag "${py_out}")"

      if [[ "${changed_local}" == "1" ]]; then
        xray_write_file_atomic "${XRAY_ROUTING_CONF}" "${tmp}" || {
          restore_file_if_exists "${backup}" "${XRAY_ROUTING_CONF}"
          exit 1
        }

        if ! xray_restart_checked; then
          if ! restore_file_if_exists "${backup}" "${XRAY_ROUTING_CONF}"; then
            exit 1
          fi
          if ! xray_restart_checked; then
            exit 88
          fi
          exit 86
        fi
      fi
    ) 200>"${ROUTING_LOCK_FILE}"
  )"
  rc=$?
  set -e

  xray_txn_rc_or_die "${rc}" \
    "Gagal memproses routing: ${XRAY_ROUTING_CONF}" \
    "xray tidak aktif setelah update routing. Routing di-rollback ke backup: ${backup}" \
    "" \
    "xray tidak aktif setelah update routing, dan rollback runtime juga gagal setelah restore backup: ${backup}"

  changed="$(xray_txn_changed_flag "${out}")"
  if [[ "${changed}" != "1" ]]; then
    return 0
  fi
  return 0
}


xray_extract_endpoints() {
  # args: protocol -> prints lines: network|path_or_service
  local proto="$1"
  need_python3
  python3 - <<'PY' "${XRAY_INBOUNDS_CONF}" "${proto}"
import json, sys
src, proto = sys.argv[1:3]
with open(src,'r',encoding='utf-8') as f:
  cfg=json.load(f)

seen=set()
for ib in cfg.get('inbounds', []) or []:
  if ib.get('protocol') != proto:
    continue
  ss = ib.get('streamSettings') or {}
  net = ss.get('network') or ''
  if not net:
    continue
  val=''
  if net == 'ws':
    ws = ss.get('wsSettings') or {}
    val = ws.get('path') or ''
  elif net in ('httpupgrade','httpUpgrade'):
    hu = ss.get('httpUpgradeSettings') or ss.get('httpupgradeSettings') or {}
    val = hu.get('path') or ''
  elif net == 'grpc':
    gs = ss.get('grpcSettings') or {}
    val = gs.get('serviceName') or ''
  key=(net,val)
  if key in seen:
    continue
  seen.add(key)
  print(net + "|" + val)
PY
}

speed_policy_file_path() {
  # args: proto username
  local proto="$1"
  local username="$2"
  echo "${SPEED_POLICY_ROOT}/${proto}/${username}@${proto}.json"
}

speed_policy_exists() {
  # args: proto username
  local proto="$1"
  local username="$2"
  local f
  f="$(speed_policy_file_path "${proto}" "${username}")"
  [[ -f "${f}" ]]
}

speed_policy_remove() {
  # args: proto username
  local proto="$1"
  local username="$2"
  local f
  f="$(speed_policy_file_path "${proto}" "${username}")"
  speed_policy_lock_prepare
  (
    flock -x 200
    if [[ -f "${f}" ]]; then
      rm -f "${f}" 2>/dev/null || true
    fi
  ) 200>"${SPEED_POLICY_LOCK_FILE}"
}

speed_policy_remove_checked() {
  # args: proto username
  local proto="$1"
  local username="$2"
  local f
  f="$(speed_policy_file_path "${proto}" "${username}")"
  speed_policy_lock_prepare
  (
    flock -x 200
    if [[ ! -f "${f}" ]]; then
      exit 0
    fi
    rm -f "${f}" || exit 1
    [[ ! -e "${f}" ]]
  ) 200>"${SPEED_POLICY_LOCK_FILE}"
}

speed_policy_upsert() {
  # args: proto username down_mbit up_mbit
  local proto="$1"
  local username="$2"
  local down_mbit="$3"
  local up_mbit="$4"

  ensure_speed_policy_dirs
  speed_policy_lock_prepare
  need_python3

  local email out_file mark
  email="${username}@${proto}"
  out_file="$(speed_policy_file_path "${proto}" "${username}")"

  mark="$(
    (
      flock -x 200
      python3 - <<'PY' "${SPEED_POLICY_ROOT}" "${proto}" "${email}" "${down_mbit}" "${up_mbit}" "${out_file}"
import zlib
import json
import os
import sys
import tempfile
from datetime import datetime, timezone

root, proto, email, down_raw, up_raw, out_file = sys.argv[1:7]

def to_float(v):
  try:
    n = float(v)
  except Exception:
    return 0.0
  if n <= 0:
    return 0.0
  return round(n, 3)

down = to_float(down_raw)
up = to_float(up_raw)
if down <= 0 or up <= 0:
  raise SystemExit("speed mbit harus > 0")

MARK_MIN = 1000
MARK_MAX = 59999
RANGE = MARK_MAX - MARK_MIN + 1

def valid_mark(v):
  try:
    m = int(v)
  except Exception:
    return False
  return MARK_MIN <= m <= MARK_MAX

def load_json(path):
  try:
    with open(path, "r", encoding="utf-8") as f:
      return json.load(f)
  except Exception:
    return {}

used = set()
for p1 in ("vless", "vmess", "trojan"):
  d = os.path.join(root, p1)
  if not os.path.isdir(d):
    continue
  for name in os.listdir(d):
    if not name.endswith(".json"):
      continue
    fp = os.path.join(d, name)
    if os.path.abspath(fp) == os.path.abspath(out_file):
      continue
    data = load_json(fp)
    m = data.get("mark")
    if valid_mark(m):
      used.add(int(m))

existing = load_json(out_file)
existing_mark = existing.get("mark")

if valid_mark(existing_mark) and int(existing_mark) not in used:
  mark = int(existing_mark)
else:
  seed = zlib.crc32(email.encode("utf-8")) & 0xFFFFFFFF
  start = MARK_MIN + (seed % RANGE)
  mark = None
  for i in range(RANGE):
    cand = MARK_MIN + ((start - MARK_MIN + i) % RANGE)
    if cand not in used:
      mark = cand
      break
  if mark is None:
    raise SystemExit("mark speed policy habis")

payload = {
  "enabled": True,
  "username": email,
  "protocol": proto,
  "mark": mark,
  "down_mbit": down,
  "up_mbit": up,
  "updated_at": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M"),
}

os.makedirs(os.path.dirname(out_file) or ".", exist_ok=True)
fd, tmp = tempfile.mkstemp(prefix=".tmp.", suffix=".json", dir=os.path.dirname(out_file) or ".")
try:
  with os.fdopen(fd, "w", encoding="utf-8") as f:
    json.dump(payload, f, ensure_ascii=False, indent=2)
    f.write("\n")
    f.flush()
    os.fsync(f.fileno())
  os.replace(tmp, out_file)
finally:
  try:
    if os.path.exists(tmp):
      os.remove(tmp)
  except Exception:
    pass

print(mark)
PY
    ) 200>"${SPEED_POLICY_LOCK_FILE}"
  )" || return 1

  [[ -n "${mark:-}" ]] || return 1
  chmod 600 "${out_file}" 2>/dev/null || true
  echo "${mark}"
}

speed_policy_apply_now() {
  if [[ -x /usr/local/bin/xray-speed && -f "${SPEED_CONFIG_FILE}" ]]; then
    /usr/local/bin/xray-speed once --config "${SPEED_CONFIG_FILE}" >/dev/null 2>&1 && return 0
  fi
  if svc_exists xray-speed; then
    svc_restart_checked xray-speed 20 >/dev/null 2>&1 || return 1
    svc_is_active xray-speed && return 0
  fi
  return 1
}

speed_policy_sync_xray() {
  need_python3
  [[ -f "${XRAY_OUTBOUNDS_CONF}" ]] || return 1
  [[ -f "${XRAY_ROUTING_CONF}" ]] || return 1
  ensure_path_writable "${XRAY_OUTBOUNDS_CONF}"
  ensure_path_writable "${XRAY_ROUTING_CONF}"

  local backup_out backup_rt tmp_out tmp_rt rc
  backup_out="$(xray_backup_path_prepare "${XRAY_OUTBOUNDS_CONF}")"
  backup_rt="$(xray_backup_path_prepare "${XRAY_ROUTING_CONF}")"
  tmp_out="${WORK_DIR}/20-outbounds.json.tmp"
  tmp_rt="${WORK_DIR}/30-routing-speed.json.tmp"

  set +e
  (
    flock -x 200
    cp -a "${XRAY_OUTBOUNDS_CONF}" "${backup_out}" || exit 1
    cp -a "${XRAY_ROUTING_CONF}" "${backup_rt}" || exit 1
    python3 - <<'PY' \
      "${SPEED_POLICY_ROOT}" \
      "${XRAY_OUTBOUNDS_CONF}" \
      "${XRAY_ROUTING_CONF}" \
      "${tmp_out}" \
      "${tmp_rt}" \
      "${SPEED_OUTBOUND_TAG_PREFIX}" \
      "${SPEED_RULE_MARKER_PREFIX}" \
      "${SPEED_MARK_MIN}" \
      "${SPEED_MARK_MAX}"
import copy
import json
import os
import re
import sys

policy_root, out_src, rt_src, out_dst, rt_dst, out_prefix, marker_prefix, mark_min_raw, mark_max_raw = sys.argv[1:10]
mark_min = int(mark_min_raw)
mark_max = int(mark_max_raw)

def load_json(path):
  with open(path, "r", encoding="utf-8") as f:
    return json.load(f)

def dump_json(path, obj):
  with open(path, "w", encoding="utf-8") as f:
    json.dump(obj, f, ensure_ascii=False, indent=2)
    f.write("\n")

def boolify(v):
  if isinstance(v, bool):
    return v
  if isinstance(v, (int, float)):
    return bool(v)
  s = str(v or "").strip().lower()
  return s in ("1", "true", "yes", "on", "y")

def to_float(v):
  try:
    n = float(v)
  except Exception:
    return 0.0
  if n <= 0:
    return 0.0
  return n

def to_mark(v):
  try:
    m = int(v)
  except Exception:
    return None
  if m < mark_min or m > mark_max:
    return None
  return m

def list_mark_users(root):
  mark_users = {}
  for proto in ("vless", "vmess", "trojan"):
    d = os.path.join(root, proto)
    if not os.path.isdir(d):
      continue
    for name in sorted(os.listdir(d)):
      if not name.endswith(".json"):
        continue
      fp = os.path.join(d, name)
      try:
        data = load_json(fp)
      except Exception:
        continue
      if not isinstance(data, dict):
        continue
      if not boolify(data.get("enabled", True)):
        continue
      mark = to_mark(data.get("mark"))
      if mark is None:
        continue
      down = to_float(data.get("down_mbit"))
      up = to_float(data.get("up_mbit"))
      if down <= 0 or up <= 0:
        continue
      email = str(data.get("username") or data.get("email") or os.path.splitext(name)[0]).strip()
      if not email:
        continue
      mark_users.setdefault(mark, set()).add(email)
  return {k: sorted(v) for k, v in sorted(mark_users.items())}

def is_default_rule(r):
  if not isinstance(r, dict):
    return False
  if r.get("type") != "field":
    return False
  port = str(r.get("port", "")).strip()
  if port not in ("1-65535", "0-65535"):
    return False
  if r.get("user") or r.get("domain") or r.get("ip") or r.get("protocol"):
    return False
  return True

def is_protected_rule(r):
  if not isinstance(r, dict):
    return False
  if r.get("type") != "field":
    return False
  ot = r.get("outboundTag")
  return isinstance(ot, str) and ot in ("api", "blocked")

def is_hard_block_user_rule(r):
  if not isinstance(r, dict):
    return False
  if r.get("type") != "field":
    return False
  if norm_tag(r.get("outboundTag")) != "blocked":
    return False
  users = r.get("user")
  if not isinstance(users, list):
    return False
  hard_markers = {"dummy-block-user", "dummy-quota-user", "dummy-limit-user"}
  return any(isinstance(x, str) and x in hard_markers for x in users)

def norm_tag(v):
  if not isinstance(v, str):
    return ""
  return v.strip()

def sanitize_tag(v):
  s = norm_tag(v)
  if not s:
    return "x"
  return re.sub(r"[^A-Za-z0-9_.-]", "-", s)

mark_users = list_mark_users(policy_root)

out_cfg = load_json(out_src)
outbounds = out_cfg.get("outbounds")
if not isinstance(outbounds, list):
  raise SystemExit("Invalid outbounds config: outbounds bukan list")
outbounds_by_tag = {}
for o in outbounds:
  if not isinstance(o, dict):
    continue
  t = norm_tag(o.get("tag"))
  if not t:
    continue
  outbounds_by_tag[t] = o

rt_cfg = load_json(rt_src)
routing = rt_cfg.get("routing") or {}
rules = routing.get("rules")
if not isinstance(rules, list):
  raise SystemExit("Invalid routing config: routing.rules bukan list")

default_rule = None
for r in rules:
  if is_default_rule(r):
    default_rule = r

base_selector = []
if isinstance(default_rule, dict):
  ot = norm_tag(default_rule.get("outboundTag"))
  if ot:
    base_selector = [ot]

if not base_selector:
  if "direct" in outbounds_by_tag:
    base_selector = ["direct"]
  else:
    for t in outbounds_by_tag.keys():
      if not t.startswith(out_prefix):
        base_selector = [t]
        break
if not base_selector:
  raise SystemExit("Outbound dasar untuk speed policy tidak ditemukan")

effective_selector = []
seen = set()
for t in base_selector:
  t2 = norm_tag(t)
  if not t2:
    continue
  if t2 in ("api", "blocked"):
    continue
  if t2.startswith(out_prefix):
    continue
  if t2 not in outbounds_by_tag:
    continue
  if t2 in seen:
    continue
  seen.add(t2)
  effective_selector.append(t2)
if not effective_selector:
  # Recovery path untuk konfigurasi non-kanonik/tidak valid:
  # jika selector dasar berisi tag speed/internal saja, fallback ke outbound non-speed.
  if "direct" in outbounds_by_tag:
    effective_selector = ["direct"]
  else:
    for t in outbounds_by_tag.keys():
      t2 = norm_tag(t)
      if not t2:
        continue
      if t2 in ("api", "blocked"):
        continue
      if t2.startswith(out_prefix):
        continue
      effective_selector = [t2]
      break
if not effective_selector:
  raise SystemExit("Selector outbound dasar untuk speed policy kosong")

clean_outbounds = []
for o in outbounds:
  if isinstance(o, dict):
    tag = norm_tag(o.get("tag"))
    if tag and tag.startswith(out_prefix):
      continue
  clean_outbounds.append(o)

mark_out_tags = {}
for mark in sorted(mark_users.keys()):
  per_mark = {}
  for base_tag in effective_selector:
    src = outbounds_by_tag.get(base_tag)
    if not isinstance(src, dict):
      continue
    clone_tag = f"{out_prefix}{mark}-{sanitize_tag(base_tag)}"
    so = copy.deepcopy(src)
    so["tag"] = clone_tag
    ss = so.get("streamSettings")
    if not isinstance(ss, dict):
      ss = {}
    sock = ss.get("sockopt")
    if not isinstance(sock, dict):
      sock = {}
    sock["mark"] = int(mark)
    ss["sockopt"] = sock
    so["streamSettings"] = ss
    clean_outbounds.append(so)
    per_mark[base_tag] = clone_tag
  mark_out_tags[mark] = per_mark

out_cfg["outbounds"] = clean_outbounds
dump_json(out_dst, out_cfg)

kept_rules = []
for r in rules:
  if not isinstance(r, dict):
    kept_rules.append(r)
    continue
  if r.get("type") != "field":
    kept_rules.append(r)
    continue
  users = r.get("user")
  ot = norm_tag(r.get("outboundTag"))
  has_speed_marker = isinstance(users, list) and any(
    isinstance(x, str) and x.startswith(marker_prefix) for x in users
  )
  if has_speed_marker and ot.startswith(out_prefix):
    continue
  kept_rules.append(r)

speed_rules = []
for mark, users in sorted(mark_users.items()):
  marker = f"{marker_prefix}{mark}"
  rule = {
    "type": "field",
    "user": [marker] + users,
  }
  first_base = effective_selector[0]
  ot = mark_out_tags.get(mark, {}).get(first_base, "")
  if not ot:
    continue
  rule["outboundTag"] = ot
  speed_rules.append(rule)

prefix_rules = []
hard_block_rules = []
other_rules = []
for rule in kept_rules:
  if is_protected_rule(rule) and not is_hard_block_user_rule(rule):
    prefix_rules.append(rule)
  elif is_hard_block_user_rule(rule):
    hard_block_rules.append(rule)
  else:
    other_rules.append(rule)

merged_rules = prefix_rules + hard_block_rules + speed_rules + other_rules
routing["rules"] = merged_rules
rt_cfg["routing"] = routing
dump_json(rt_dst, rt_cfg)
PY
    xray_write_file_atomic "${XRAY_OUTBOUNDS_CONF}" "${tmp_out}" || {
      restore_file_if_exists "${backup_out}" "${XRAY_OUTBOUNDS_CONF}"
      restore_file_if_exists "${backup_rt}" "${XRAY_ROUTING_CONF}"
      exit 1
    }
    xray_write_file_atomic "${XRAY_ROUTING_CONF}" "${tmp_rt}" || {
      restore_file_if_exists "${backup_out}" "${XRAY_OUTBOUNDS_CONF}"
      restore_file_if_exists "${backup_rt}" "${XRAY_ROUTING_CONF}"
      exit 1
    }

	    if ! xray_restart_checked; then
	      if ! restore_file_if_exists "${backup_out}" "${XRAY_OUTBOUNDS_CONF}"; then
	        echo "rollback speed policy gagal: restore outbounds backup gagal" >&2
	        exit 1
	      fi
	      if ! restore_file_if_exists "${backup_rt}" "${XRAY_ROUTING_CONF}"; then
	        echo "rollback speed policy gagal: restore routing backup gagal" >&2
	        exit 1
	      fi
	      if ! xray_restart_checked; then
	        echo "rollback speed policy gagal: xray tidak aktif setelah restore backup" >&2
	        exit 1
	      fi
	      exit 86
	    fi
  ) 200>"${ROUTING_LOCK_FILE}"
  rc=$?
  set -e

  if (( rc == 0 )); then
    return 0
  fi
  return 1
}

rollback_new_user_after_create_failure() {
  # args: proto username [reason] [inbounds_created=true|false]
  local proto="$1"
  local username="$2"
  local reason="${3:-operasi create gagal}"
  local inbounds_created="${4:-true}"
  local email="${username}@${proto}" failed=0

  warn "Rollback akun ${email}: ${reason}."
  if [[ "${inbounds_created}" == "true" ]]; then
    if ! xray_delete_client_try "${proto}" "${username}"; then
      warn "Rollback inbounds gagal untuk ${email}"
      failed=1
    fi
  fi
  if ! delete_account_artifacts_checked "${proto}" "${username}"; then
    warn "Rollback artefak lokal gagal untuk ${email}"
    failed=1
  fi
  if ! speed_policy_remove_checked "${proto}" "${username}"; then
    warn "Rollback cleanup speed policy file gagal untuk ${email}"
    failed=1
  fi
  if ! speed_policy_sync_xray_try; then
    warn "Rollback sinkronisasi speed policy gagal untuk ${email}"
    failed=1
  elif ! speed_policy_apply_now >/dev/null 2>&1; then
    warn "Rollback apply runtime speed policy gagal untuk ${email}"
    failed=1
  fi
  return "${failed}"
}

rollback_new_user_after_speed_failure() {
  # args: proto username
  rollback_new_user_after_create_failure "$1" "$2" "setup speed-limit gagal"
}

user_add_prepare_speed_policy_before_runtime() {
  # args: proto username speed_enabled speed_down_mbit speed_up_mbit
  local proto="$1"
  local username="$2"
  local speed_enabled="$3"
  local speed_down_mbit="$4"
  local speed_up_mbit="$5"
  local speed_mark=""

  if [[ "${speed_enabled}" == "true" ]]; then
    speed_mark="$(speed_policy_upsert "${proto}" "${username}" "${speed_down_mbit}" "${speed_up_mbit}")" || {
      echo "gagal menyimpan speed policy"
      return 1
    }
    if ! speed_policy_sync_xray; then
      echo "gagal sinkronisasi speed policy ke routing/outbound xray"
      return 1
    fi
    if ! speed_policy_apply_now >/dev/null 2>&1; then
      echo "policy speed tersimpan, tetapi apply runtime gagal (cek service xray-speed)"
      return 1
    fi
    printf '%s\n' "${speed_mark}"
    return 0
  fi

  if speed_policy_exists "${proto}" "${username}"; then
    if ! speed_policy_remove_checked "${proto}" "${username}"; then
      echo "gagal membersihkan speed policy lama"
      return 1
    fi
    if ! speed_policy_sync_xray; then
      echo "sinkronisasi speed policy lama gagal"
      return 1
    fi
    if ! speed_policy_apply_now >/dev/null 2>&1; then
      echo "apply runtime speed policy gagal"
      return 1
    fi
  fi
  return 0
}

write_account_artifacts() {
  # args: protocol username cred quota_bytes days ip_limit_enabled ip_limit_value speed_enabled speed_down_mbit speed_up_mbit [account_output_override] [quota_output_override]
  local proto="$1"
  local username="$2"
  local cred="$3"
  local quota_bytes="$4"
  local days="$5"
  local ip_enabled="$6"
  local ip_limit="$7"
  local speed_enabled="$8"
  local speed_down="$9"
  local speed_up="${10}"
  local account_output_override="${11:-}"
  local quota_output_override="${12:-}"

  ensure_account_quota_dirs
  need_python3

  local domain ip created expired geo geo_ip isp country
  domain="$(detect_domain)"
  ip="$(detect_public_ip_ipapi)"
  created="$(date '+%Y-%m-%d %H:%M')"
  expired="$(date -d "+${days} days" '+%Y-%m-%d' 2>/dev/null || date '+%Y-%m-%d')"
  geo="$(main_info_geo_lookup "${ip}")"
  IFS='|' read -r geo_ip isp country <<<"${geo}"
  [[ -n "${geo_ip}" && "${geo_ip}" != "-" ]] && ip="${geo_ip}"
  [[ -n "${isp}" ]] || isp="-"
  [[ -n "${country}" ]] || country="-"

  local acc_file quota_file
  acc_file="${ACCOUNT_ROOT}/${proto}/${username}@${proto}.txt"
  quota_file="${QUOTA_ROOT}/${proto}/${username}@${proto}.json"
  [[ -n "${account_output_override}" ]] && acc_file="${account_output_override}"
  [[ -n "${quota_output_override}" ]] && quota_file="${quota_output_override}"

  python3 - <<'PY' "${acc_file}" "${quota_file}" "${XRAY_INBOUNDS_CONF}" "${domain}" "${ip}" "${isp}" "${country}" "${username}" "${proto}" "${cred}" "${quota_bytes}" "${created}" "${expired}" "${days}" "${ip_enabled}" "${ip_limit}" "${speed_enabled}" "${speed_down}" "${speed_up}" "$(xray_edge_runtime_primary_ports_label)" "$(xray_edge_runtime_public_tls_ports_label)" "$(xray_edge_runtime_alt_tls_ports_label)" "$(xray_edge_runtime_alt_http_ports_label)"
import sys, json, base64, urllib.parse, datetime, os, tempfile, ipaddress
acc_file, quota_file, inbounds_file, domain, ip, isp, country, username, proto, cred, quota_bytes, created_at, expired_at, days, ip_enabled, ip_limit, speed_enabled, speed_down, speed_up, primary_ports_disp, tls_ports_disp, alt_tls_ports_disp, alt_http_ports_disp = sys.argv[1:24]
quota_bytes=int(quota_bytes)
days=int(float(days)) if str(days).strip() else 0
ip_enabled = str(ip_enabled).lower() in ("1","true","yes","y","on")
speed_enabled = str(speed_enabled).lower() in ("1","true","yes","y","on")
try:
  ip_limit_int=int(ip_limit)
except Exception:
  ip_limit_int=0
try:
  speed_down_mbit=float(speed_down)
except Exception:
  speed_down_mbit=0.0
try:
  speed_up_mbit=float(speed_up)
except Exception:
  speed_up_mbit=0.0
if not speed_enabled or speed_down_mbit <= 0 or speed_up_mbit <= 0:
  speed_enabled=False
  speed_down_mbit=0.0
  speed_up_mbit=0.0

def fmt_gb(v):
  try:
    v=float(v)
  except Exception:
    return "0"
  if v <= 0:
    return "0"
  if abs(v - round(v)) < 1e-9:
    return str(int(round(v)))
  s=f"{v:.2f}"
  s=s.rstrip("0").rstrip(".")
  return s

def fmt_mbit(v):
  try:
    n=float(v)
  except Exception:
    return "0"
  if n <= 0:
    return "0"
  if abs(n-round(n)) < 1e-9:
    return str(int(round(n)))
  s=f"{n:.2f}"
  return s.rstrip("0").rstrip(".")

PROTO_LABELS = {
  "vless": "Vless",
  "vmess": "Vmess",
  "trojan": "Trojan",
}

def proto_label(p):
  return PROTO_LABELS.get(str(p or "").strip().lower(), str(p or "").strip().title() or "Xray")

def path_alt_placeholder(path):
  raw = str(path or "").strip()
  if not raw:
    return "-"
  if not raw.startswith("/"):
    raw = "/" + raw
  return f"/<bebas>{raw}"


def service_alt_placeholder(service):
  raw = str(service or "").strip()
  if not raw or raw == "-":
    return "-"
  return f"<bebas>/{raw.lstrip('/')}"

def section_line(label, value, width):
  return f"  {label:<{width}} : {value}"

def append_link_block(lines, label, value):
  lines.append(f"    {label:<12} :")
  lines.append(str(value or "-"))

def is_public_ipv4(raw):
  try:
    addr = ipaddress.ip_address(str(raw).strip())
  except Exception:
    return False
  return (
    addr.version == 4
    and not addr.is_private
    and not addr.is_loopback
    and not addr.is_link_local
    and not addr.is_multicast
    and not addr.is_unspecified
    and not addr.is_reserved
  )

def write_text_atomic(path, content):
  dirn = os.path.dirname(path) or "."
  os.makedirs(dirn, exist_ok=True)
  fd, tmp = tempfile.mkstemp(prefix=".tmp.", suffix=".txt", dir=dirn)
  try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
      f.write(content)
      f.flush()
      os.fsync(f.fileno())
    os.replace(tmp, path)
  finally:
    try:
      if os.path.exists(tmp):
        os.remove(tmp)
    except Exception:
      pass

def write_json_atomic(path, obj):
  dirn = os.path.dirname(path) or "."
  os.makedirs(dirn, exist_ok=True)
  fd, tmp = tempfile.mkstemp(prefix=".tmp.", suffix=".json", dir=dirn)
  try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
      json.dump(obj, f, ensure_ascii=False, indent=2)
      f.write("\n")
      f.flush()
      os.fsync(f.fileno())
    os.replace(tmp, path)
  finally:
    try:
      if os.path.exists(tmp):
        os.remove(tmp)
    except Exception:
      pass

def pick_portal_token(quota_file_path, current_token=""):
  import secrets
  import re
  root_dir = os.path.dirname(os.path.dirname(quota_file_path)) or "."
  used = set()
  try:
    for proto_name in sorted(os.listdir(root_dir), key=str.lower):
      proto_dir = os.path.join(root_dir, proto_name)
      if not os.path.isdir(proto_dir):
        continue
      for name in sorted(os.listdir(proto_dir), key=str.lower):
        if name.startswith(".") or not name.endswith(".json"):
          continue
        entry = os.path.join(proto_dir, name)
        try:
          if os.path.realpath(entry) == os.path.realpath(quota_file_path):
            continue
        except Exception:
          pass
        try:
          loaded = json.load(open(entry, "r", encoding="utf-8"))
        except Exception:
          continue
        if not isinstance(loaded, dict):
          continue
        tok = str(loaded.get("portal_token") or "").strip()
        if re.fullmatch(r"[A-Za-z0-9_-]{10,64}", tok):
          used.add(tok)
  except Exception:
    pass
  token = str(current_token or "").strip()
  if re.fullmatch(r"[A-Za-z0-9_-]{10,64}", token) and token not in used:
    return token
  for _ in range(256):
    token = secrets.token_urlsafe(12).rstrip("=")
    if token and re.fullmatch(r"[A-Za-z0-9_-]{10,64}", token) and token not in used:
      return token
  raise RuntimeError("failed to allocate portal token")

# Public endpoint harus selaras dengan nginx public path (setup.sh).
PUBLIC_PATHS = {
  "vless": {"ws": "/vless-ws", "httpupgrade": "/vless-hup", "xhttp": "/vless-xhttp", "grpc": "vless-grpc"},
  "vmess": {"ws": "/vmess-ws", "httpupgrade": "/vmess-hup", "xhttp": "/vmess-xhttp", "grpc": "vmess-grpc"},
  "trojan": {"ws": "/trojan-ws", "httpupgrade": "/trojan-hup", "xhttp": "/trojan-xhttp", "grpc": "trojan-grpc"},
}
TCP_TLS_PROTOCOLS = {"vless", "trojan"}
tcp_tls_host = domain


def vless_link(net, val):
  q={"encryption":"none","security":"tls","type":net,"sni":domain}
  if net in ("ws","httpupgrade","xhttp"):
    q["path"]=val or "/"
  elif net=="grpc":
    if val:
      q["serviceName"]=val
  host = tcp_tls_host if net == "tcp" else domain
  return f"vless://{cred}@{host}:443?{urllib.parse.urlencode(q)}#{urllib.parse.quote(username + "@" + proto)}"

def trojan_link(net, val):
  q={"security":"tls","type":net,"sni":domain}
  if net in ("ws","httpupgrade","xhttp"):
    q["path"]=val or "/"
  elif net=="grpc":
    if val:
      q["serviceName"]=val
  host = tcp_tls_host if net == "tcp" else domain
  return f"trojan://{cred}@{host}:443?{urllib.parse.urlencode(q)}#{urllib.parse.quote(username + "@" + proto)}"

def vmess_link(net, val):
  obj={
    "v":"2",
    "ps":username + "@" + proto,
    "add":domain,
    "port":"443",
    "id":cred,
    "aid":"0",
    "net":net,
    "type":"none",
    "host":domain,
    "tls":"tls",
    "sni":domain
  }
  if net in ("ws","httpupgrade","xhttp"):
    obj["path"]=val or "/"
  elif net=="grpc":
    obj["path"]=val or ""  # many clients use path as serviceName
    obj["type"]="gun"
  raw=json.dumps(obj, separators=(",",":"))
  return "vmess://" + base64.b64encode(raw.encode()).decode()

links={}
public_proto = PUBLIC_PATHS.get(proto, {})
nets = ["ws", "httpupgrade", "grpc"]
if proto in TCP_TLS_PROTOCOLS:
  nets = ["tcp"] + nets
nets = [net for net in nets if net != "grpc"] + ["xhttp", "grpc"]
for net in nets:
  val = public_proto.get(net, "")
  if proto=="vless":
    links[net]=vless_link(net,val)
  elif proto=="vmess":
    links[net]=vmess_link(net,val)
  elif proto=="trojan":
    links[net]=trojan_link(net,val)

quota_gb = quota_bytes/(1024**3) if quota_bytes else 0
quota_gb_disp = fmt_gb(quota_gb)
proto_disp = proto_label(proto)
portal_token = pick_portal_token(quota_file, "")
portal_url = f"https://{domain}/account/{portal_token}" if domain and domain != "-" else "-"
ws_path = public_proto.get("ws", "") or "/"
ws_path_alt = path_alt_placeholder(ws_path)
hup_path = public_proto.get("httpupgrade", "") or "/"
hup_path_alt = path_alt_placeholder(hup_path)
xhttp_path = public_proto.get("xhttp", "") or "/"
xhttp_path_alt = path_alt_placeholder(xhttp_path)
grpc_service = public_proto.get("grpc", "") or "-"
grpc_service_alt = service_alt_placeholder(grpc_service)
created_disp = created_at[:10] if len(created_at) >= 10 and created_at[4:5] == "-" and created_at[7:8] == "-" else created_at
running_labels = [
  f"{proto_disp} WS",
  f"{proto_disp} HUP",
  f"{proto_disp} XHTTP",
  f"{proto_disp} gRPC",
  f"{proto_disp} Path WS",
  f"{proto_disp} Path WS Alt",
  f"{proto_disp} Path HUP",
  f"{proto_disp} Path HUP Alt",
  f"{proto_disp} Path XHTTP",
  f"{proto_disp} Path XHTTP Alt",
  f"{proto_disp} Path Service",
  f"{proto_disp} Path Service Alt",
]
if proto in TCP_TLS_PROTOCOLS:
  running_labels.append(f"{proto_disp} TCP+TLS Port")
running_label_width = max(len(label) for label in running_labels)

# Write account txt
lines=[]
lines.append("=== XRAY ACCOUNT INFO ===")
lines.append(f"  Domain      : {domain}")
lines.append(f"  IP          : {ip}")
lines.append(f"  ISP         : {isp or '-'}")
lines.append(f"  Country     : {country or '-'}")
lines.append(f"  Username    : {username}")
lines.append(f"  Protocol    : {proto}")
if proto in ("vless","vmess"):
  lines.append(f"  UUID        : {cred}")
else:
  lines.append(f"  Password    : {cred}")
lines.append(f"  Quota Limit : {quota_gb_disp} GB")
lines.append(f"  Expired     : {days} days")
lines.append(f"  Valid Until : {expired_at}")
lines.append(f"  Created     : {created_disp}")
lines.append(f"  IP Limit    : {'ON' if ip_enabled else 'OFF'}" + (f" ({ip_limit_int})" if ip_enabled and ip_limit_int > 0 else ""))
if speed_enabled:
  lines.append(f"  Speed Limit : ON (DOWN {fmt_mbit(speed_down_mbit)} Mbps | UP {fmt_mbit(speed_up_mbit)} Mbps)")
else:
  lines.append("  Speed Limit : OFF")
lines.append(f"  Portal Info : {portal_url}")
lines.append("")
lines.append("=== RUNNING ON PORT & PATH ===")
lines.append(section_line(f"{proto_disp} WS", primary_ports_disp, running_label_width))
lines.append(section_line(f"{proto_disp} HUP", primary_ports_disp, running_label_width))
lines.append(section_line(f"{proto_disp} XHTTP", primary_ports_disp, running_label_width))
lines.append(section_line(f"{proto_disp} gRPC", primary_ports_disp, running_label_width))
if proto in TCP_TLS_PROTOCOLS:
  lines.append(section_line(f"{proto_disp} TCP+TLS Port", primary_ports_disp, running_label_width))
lines.append(section_line("Alt Port SSL/TLS", alt_tls_ports_disp, running_label_width))
lines.append(section_line("Alt Port HTTP", alt_http_ports_disp, running_label_width))
lines.append(section_line(f"{proto_disp} Path WS", ws_path, running_label_width))
lines.append(section_line(f"{proto_disp} Path WS Alt", ws_path_alt, running_label_width))
lines.append(section_line(f"{proto_disp} Path HUP", hup_path, running_label_width))
lines.append(section_line(f"{proto_disp} Path HUP Alt", hup_path_alt, running_label_width))
lines.append(section_line(f"{proto_disp} Path XHTTP", xhttp_path, running_label_width))
lines.append(section_line(f"{proto_disp} Path XHTTP Alt", xhttp_path_alt, running_label_width))
lines.append(section_line(f"{proto_disp} Path Service", grpc_service, running_label_width))
lines.append(section_line(f"{proto_disp} Path Service Alt", grpc_service_alt, running_label_width))
lines.append("")
lines.append("=== LINKS IMPORT ===")
if "tcp" in links:
  append_link_block(lines, "TCP+TLS", links.get('tcp','-'))
  lines.append("")
append_link_block(lines, "WebSocket", links.get('ws','-'))
lines.append("")
append_link_block(lines, "HTTPUpgrade", links.get('httpupgrade','-'))
lines.append("")
if "xhttp" in links:
  append_link_block(lines, "XHTTP", links.get('xhttp','-'))
  lines.append("")
append_link_block(lines, "gRPC", links.get('grpc','-'))
lines.append("")

write_text_atomic(acc_file, "\n".join(lines))

# Write quota json metadata
meta={
  "username": username + "@" + proto,
  "protocol": proto,
  "portal_token": portal_token,
  "quota_limit": quota_bytes,
  "quota_unit": "binary",
  "quota_used": 0,
  "xray_usage_bytes": 0,
  "xray_api_baseline_bytes": 0,
  "xray_usage_carry_bytes": 0,
  "xray_api_last_total_bytes": 0,
  "xray_usage_reset_pending": False,
  "created_at": created_at,
  "expired_at": expired_at,
  "status": {
    "manual_block": False,
    "quota_exhausted": False,
    "ip_limit_enabled": ip_enabled,
    "ip_limit": ip_limit_int if ip_enabled else 0,
    "speed_limit_enabled": speed_enabled,
    "speed_down_mbit": speed_down_mbit if speed_enabled else 0,
    "speed_up_mbit": speed_up_mbit if speed_enabled else 0,
    "ip_limit_locked": False,
    "lock_reason": "",
    "locked_at": ""
  }
}
write_json_atomic(quota_file, meta)
PY
  local py_rc=$?
  if (( py_rc != 0 )); then
    return "${py_rc}"
  fi

  chmod 600 "${acc_file}" "${quota_file}" || true
  return 0
}

account_info_refresh_for_user() {
  # args: protocol username [domain] [ip] [credential_override] [output_file_override]
  local proto="$1"
  local username="$2"
  local domain="${3:-}"
  local ip="${4:-}"
  local cred_override="${5:-}"
  local output_file_override="${6:-}"

  ensure_account_quota_dirs
  need_python3

  local acc_file quota_file acc_compatfmt quota_compatfmt
  acc_file="${ACCOUNT_ROOT}/${proto}/${username}@${proto}.txt"
  quota_file="${QUOTA_ROOT}/${proto}/${username}@${proto}.json"
  acc_compatfmt="${ACCOUNT_ROOT}/${proto}/${username}.txt"
  quota_compatfmt="${QUOTA_ROOT}/${proto}/${username}.json"

  if [[ ! -f "${acc_file}" && -f "${acc_compatfmt}" ]]; then
    acc_file="${acc_compatfmt}"
  fi
  if [[ ! -f "${quota_file}" && -f "${quota_compatfmt}" ]]; then
    quota_file="${quota_compatfmt}"
  fi

  [[ -n "${domain}" ]] || domain="$(detect_domain)"
  if [[ -z "${ip}" ]]; then
    if [[ -f "${acc_file}" ]]; then
      ip="$(grep -E '^[[:space:]]*IP[[:space:]]*:' "${acc_file}" | head -n1 | sed -E 's/^[[:space:]]*IP[[:space:]]*:[[:space:]]*//' || true)"
    fi
    [[ -n "${ip}" ]] || ip="$(detect_public_ip)"
  fi

  local rc=0 geo geo_ip isp country
  geo="$(main_info_geo_lookup "${ip}")"
  IFS='|' read -r geo_ip isp country <<<"${geo}"
  [[ -n "${geo_ip}" && "${geo_ip}" != "-" ]] && ip="${geo_ip}"
  [[ -n "${isp}" ]] || isp="-"
  [[ -n "${country}" ]] || country="-"
  set +e
  python3 - <<'PY' "${acc_file}" "${quota_file}" "${XRAY_INBOUNDS_CONF}" "${domain}" "${ip}" "${isp}" "${country}" "${username}" "${proto}" "${cred_override}" "${output_file_override}" "$(xray_edge_runtime_primary_ports_label)" "$(xray_edge_runtime_public_tls_ports_label)" "$(xray_edge_runtime_alt_tls_ports_label)" "$(xray_edge_runtime_alt_http_ports_label)"
import base64
import ipaddress
import json
import os
import re
import sys
import tempfile
import urllib.parse
from datetime import date, datetime

acc_file, quota_file, inbounds_file, domain_arg, ip_arg, isp_arg, country_arg, username, proto, cred_override, output_override, primary_ports_disp, tls_ports_disp, alt_tls_ports_disp, alt_http_ports_disp = sys.argv[1:16]
email = f"{username}@{proto}"
forced_cred = str(cred_override or "").strip()
out_file = str(output_override or "").strip() or acc_file


def to_int(v, default=0):
  try:
    if v is None:
      return default
    if isinstance(v, bool):
      return int(v)
    if isinstance(v, (int, float)):
      return int(v)
    s = str(v).strip()
    if not s:
      return default
    return int(float(s))
  except Exception:
    return default


def to_float(v, default=0.0):
  try:
    if v is None:
      return default
    if isinstance(v, bool):
      return float(int(v))
    if isinstance(v, (int, float)):
      return float(v)
    s = str(v).strip()
    if not s:
      return default
    return float(s)
  except Exception:
    return default


def fmt_gb(v):
  try:
    n = float(v)
  except Exception:
    return "0"
  if n <= 0:
    return "0"
  if abs(n - round(n)) < 1e-9:
    return str(int(round(n)))
  return f"{n:.2f}".rstrip("0").rstrip(".")


def fmt_mbit(v):
  try:
    n = float(v)
  except Exception:
    return "0"
  if n <= 0:
    return "0"
  if abs(n - round(n)) < 1e-9:
    return str(int(round(n)))
  return f"{n:.2f}".rstrip("0").rstrip(".")


PROTO_LABELS = {
  "vless": "Vless",
  "vmess": "Vmess",
  "trojan": "Trojan",
}


def path_alt_placeholder(path):
  raw = str(path or "").strip()
  if not raw:
    return "-"
  if not raw.startswith("/"):
    raw = "/" + raw
  return f"/<bebas>{raw}"


def service_alt_placeholder(service):
  raw = str(service or "").strip()
  if not raw or raw == "-":
    return "-"
  return f"<bebas>/{raw.lstrip('/')}"


def section_line(label, value, width):
  return f"  {label:<{width}} : {value}"


def append_link_block(lines, label, value):
  lines.append(f"    {label:<12} :")
  lines.append(str(value or "-"))


def is_public_ipv4(raw):
  try:
    addr = ipaddress.ip_address(str(raw).strip())
  except Exception:
    return False
  return (
    addr.version == 4
    and not addr.is_private
    and not addr.is_loopback
    and not addr.is_link_local
    and not addr.is_multicast
    and not addr.is_unspecified
    and not addr.is_reserved
  )


def parse_date_only(raw):
  s = str(raw or "").strip()
  if not s:
    return None
  s = s[:10]
  try:
    return datetime.strptime(s, "%Y-%m-%d").date()
  except Exception:
    return None


def read_account_fields(path):
  fields = {}
  if not os.path.isfile(path):
    return fields
  try:
    with open(path, "r", encoding="utf-8", errors="replace") as f:
      for raw in f:
        line = raw.strip()
        if ":" not in line:
          continue
        k, v = line.split(":", 1)
        fields[k.strip()] = v.strip()
  except Exception:
    return {}
  return fields


def write_json_atomic(path, obj):
  dirn = os.path.dirname(path) or "."
  os.makedirs(dirn, exist_ok=True)
  fd, tmp = tempfile.mkstemp(prefix=".tmp.", suffix=".json", dir=dirn)
  try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
      json.dump(obj, f, ensure_ascii=False, indent=2)
      f.write("\n")
      f.flush()
      os.fsync(f.fileno())
    os.replace(tmp, path)
  finally:
    try:
      if os.path.exists(tmp):
        os.remove(tmp)
    except Exception:
      pass


def pick_portal_token(quota_file_path, current_token=""):
  import secrets
  import re
  root_dir = os.path.dirname(os.path.dirname(quota_file_path)) or "."
  used = set()
  try:
    for proto_name in sorted(os.listdir(root_dir), key=str.lower):
      proto_dir = os.path.join(root_dir, proto_name)
      if not os.path.isdir(proto_dir):
        continue
      for name in sorted(os.listdir(proto_dir), key=str.lower):
        if name.startswith(".") or not name.endswith(".json"):
          continue
        entry = os.path.join(proto_dir, name)
        try:
          if os.path.realpath(entry) == os.path.realpath(quota_file_path):
            continue
        except Exception:
          pass
        try:
          loaded = json.load(open(entry, "r", encoding="utf-8"))
        except Exception:
          continue
        if not isinstance(loaded, dict):
          continue
        tok = str(loaded.get("portal_token") or "").strip()
        if re.fullmatch(r"[A-Za-z0-9_-]{10,64}", tok):
          used.add(tok)
  except Exception:
    pass
  token = str(current_token or "").strip()
  if re.fullmatch(r"[A-Za-z0-9_-]{10,64}", token) and token not in used:
    return token
  for _ in range(256):
    token = secrets.token_urlsafe(12).rstrip("=")
    if token and re.fullmatch(r"[A-Za-z0-9_-]{10,64}", token) and token not in used:
      return token
  raise RuntimeError("failed to allocate portal token")


def parse_quota_bytes_from_text(s):
  m = re.search(r"([0-9]+(?:\.[0-9]+)?)", str(s or ""))
  if not m:
    return 0
  try:
    gb = float(m.group(1))
  except Exception:
    return 0
  if gb <= 0:
    return 0
  return int(round(gb * (1024 ** 3)))


def parse_days_from_text(s):
  m = re.search(r"([0-9]+)", str(s or ""))
  if not m:
    return None
  try:
    n = int(m.group(1))
  except Exception:
    return None
  if n < 0:
    return 0
  return n


def parse_ip_line(s):
  text = str(s or "").strip().upper()
  if not text.startswith("ON"):
    return False, 0
  m = re.search(r"\(([0-9]+)\)", text)
  if not m:
    return True, 0
  return True, to_int(m.group(1), 0)


def parse_speed_line(s):
  text = str(s or "").strip()
  if not text.upper().startswith("ON"):
    return False, 0.0, 0.0
  m = re.search(
    r"DOWN\s*([0-9]+(?:\.[0-9]+)?)\s*Mbps\s*\|\s*UP\s*([0-9]+(?:\.[0-9]+)?)\s*Mbps",
    text,
    flags=re.IGNORECASE,
  )
  if not m:
    return False, 0.0, 0.0
  return True, to_float(m.group(1), 0.0), to_float(m.group(2), 0.0)


existing = read_account_fields(acc_file)

domain = str(domain_arg or "").strip() or str(existing.get("Domain") or "").strip() or "-"
ip = str(ip_arg or "").strip() or str(existing.get("IP") or "").strip() or "0.0.0.0"
isp = str(isp_arg or "").strip() or str(existing.get("ISP") or "").strip() or "-"
country = str(country_arg or "").strip() or str(existing.get("Country") or "").strip() or "-"

meta = {}
meta_dirty = False
if os.path.isfile(quota_file):
  try:
    loaded = json.load(open(quota_file, "r", encoding="utf-8"))
    if isinstance(loaded, dict):
      meta = loaded
  except Exception:
    meta = {}

status = meta.get("status")
if not isinstance(status, dict):
  status = {}

quota_bytes = to_int(meta.get("quota_limit"), -1)
if quota_bytes < 0:
  quota_bytes = parse_quota_bytes_from_text(existing.get("Quota Limit", ""))
if quota_bytes < 0:
  quota_bytes = 0
quota_gb_disp = fmt_gb(quota_bytes / (1024 ** 3)) if quota_bytes else "0"

created_at = str(meta.get("created_at") or existing.get("Created") or "").strip()
if created_at:
  s = created_at.replace("T", " ").strip()
  if s.endswith("Z"):
    s = s[:-1]
  try:
    dt = datetime.fromisoformat(s)
    if dt.hour == 0 and dt.minute == 0 and dt.second == 0 and len(s) <= 10:
      created_at = dt.strftime("%Y-%m-%d")
    else:
      created_at = dt.strftime("%Y-%m-%d %H:%M")
  except Exception:
    if len(s) >= 16 and s[4:5] == "-" and s[7:8] == "-" and s[13:14] == ":":
      created_at = s[:16]
    elif len(s) >= 10 and s[4:5] == "-" and s[7:8] == "-":
      created_at = s[:10]
    else:
      created_at = datetime.now().strftime("%Y-%m-%d %H:%M")
else:
  created_at = datetime.now().strftime("%Y-%m-%d %H:%M")
expired_at = str(meta.get("expired_at") or existing.get("Valid Until") or "").strip()
expired_at = expired_at[:10] if expired_at else "-"

d_expired = parse_date_only(expired_at)
if d_expired:
  days = max(0, (d_expired - date.today()).days)
else:
  days = parse_days_from_text(existing.get("Expired", ""))
  if days is None:
    d_created = parse_date_only(created_at)
    if d_created and d_expired:
      days = max(0, (d_expired - d_created).days)
    else:
      days = 0

if "ip_limit_enabled" in status:
  ip_enabled = bool(status.get("ip_limit_enabled"))
  ip_limit_int = to_int(status.get("ip_limit"), 0)
else:
  ip_enabled, ip_limit_int = parse_ip_line(existing.get("IP Limit", ""))
if ip_limit_int < 0:
  ip_limit_int = 0

if "speed_limit_enabled" in status or "speed_down_mbit" in status or "speed_up_mbit" in status:
  speed_enabled = bool(status.get("speed_limit_enabled"))
  speed_down_mbit = to_float(status.get("speed_down_mbit"), 0.0)
  speed_up_mbit = to_float(status.get("speed_up_mbit"), 0.0)
else:
  speed_enabled, speed_down_mbit, speed_up_mbit = parse_speed_line(existing.get("Speed Limit", ""))

if not speed_enabled or speed_down_mbit <= 0 or speed_up_mbit <= 0:
  speed_enabled = False
  speed_down_mbit = 0.0
  speed_up_mbit = 0.0

cred = forced_cred
if not cred and os.path.isfile(inbounds_file):
  try:
    cfg = json.load(open(inbounds_file, "r", encoding="utf-8"))
    def inbound_matches_proto(ib, p):
      if not isinstance(ib, dict):
        return False
      ib_proto = str(ib.get("protocol") or "").strip().lower()
      if p in ("vless", "vmess", "trojan"):
        return ib_proto == p
      return False

    for ib in cfg.get("inbounds") or []:
      if not isinstance(ib, dict):
        continue
      if not inbound_matches_proto(ib, proto):
        continue
      clients = (ib.get("settings") or {}).get("clients") or []
      if not isinstance(clients, list):
        continue
      for c in clients:
        if not isinstance(c, dict):
          continue
        if str(c.get("email") or "") != email:
          continue
        if proto == "trojan":
          v = c.get("password")
        else:
          v = c.get("id")
        cred = str(v or "").strip()
        if cred:
          break
      if cred:
        break
  except Exception:
    cred = ""

if not cred:
  if proto == "trojan":
    cred = str(existing.get("Password") or "").strip()
  else:
    cred = str(existing.get("UUID") or "").strip()
if not cred:
  raise SystemExit(20)

PUBLIC_PATHS = {
  "vless": {"ws": "/vless-ws", "httpupgrade": "/vless-hup", "xhttp": "/vless-xhttp", "grpc": "vless-grpc"},
  "vmess": {"ws": "/vmess-ws", "httpupgrade": "/vmess-hup", "xhttp": "/vmess-xhttp", "grpc": "vmess-grpc"},
  "trojan": {"ws": "/trojan-ws", "httpupgrade": "/trojan-hup", "xhttp": "/trojan-xhttp", "grpc": "trojan-grpc"},
}
TCP_TLS_PROTOCOLS = {"vless", "trojan"}
tcp_tls_host = domain


def vless_link(net, val):
  q = {"encryption": "none", "security": "tls", "type": net, "sni": domain}
  if net in ("ws", "httpupgrade", "xhttp"):
    q["path"] = val or "/"
  elif net == "grpc" and val:
    q["serviceName"] = val
  host = tcp_tls_host if net == "tcp" else domain
  return f"vless://{cred}@{host}:443?{urllib.parse.urlencode(q)}#{urllib.parse.quote(username + '@' + proto)}"


def trojan_link(net, val):
  q = {"security": "tls", "type": net, "sni": domain}
  if net in ("ws", "httpupgrade", "xhttp"):
    q["path"] = val or "/"
  elif net == "grpc" and val:
    q["serviceName"] = val
  host = tcp_tls_host if net == "tcp" else domain
  return f"trojan://{cred}@{host}:443?{urllib.parse.urlencode(q)}#{urllib.parse.quote(username + '@' + proto)}"


def vmess_link(net, val):
  obj = {
    "v": "2",
    "ps": username + "@" + proto,
    "add": domain,
    "port": "443",
    "id": cred,
    "aid": "0",
    "net": net,
    "type": "none",
    "host": domain,
    "tls": "tls",
    "sni": domain,
  }
  if net in ("ws", "httpupgrade", "xhttp"):
    obj["path"] = val or "/"
  elif net == "grpc":
    obj["path"] = val or ""
    obj["type"] = "gun"
  raw = json.dumps(obj, separators=(",", ":"))
  return "vmess://" + base64.b64encode(raw.encode()).decode()

links = {}
public_proto = PUBLIC_PATHS.get(proto, {})
proto_disp = PROTO_LABELS.get(proto, proto.title() or "Xray")
portal_token = pick_portal_token(quota_file, meta.get("portal_token") or "")
if str(meta.get("portal_token") or "").strip() != portal_token:
  meta["portal_token"] = portal_token
  meta_dirty = True
portal_url = f"https://{domain}/account/{portal_token}" if domain and domain != "-" else "-"
ws_path = public_proto.get("ws", "") or "/"
ws_path_alt = path_alt_placeholder(ws_path)
hup_path = public_proto.get("httpupgrade", "") or "/"
hup_path_alt = path_alt_placeholder(hup_path)
xhttp_path = public_proto.get("xhttp", "") or "/"
xhttp_path_alt = path_alt_placeholder(xhttp_path)
grpc_service = public_proto.get("grpc", "") or "-"
grpc_service_alt = service_alt_placeholder(grpc_service)
created_disp = created_at[:10] if len(created_at) >= 10 and created_at[4:5] == "-" and created_at[7:8] == "-" else created_at
running_labels = [
  f"{proto_disp} WS",
  f"{proto_disp} HUP",
  f"{proto_disp} XHTTP",
  f"{proto_disp} gRPC",
  f"{proto_disp} Path WS",
  f"{proto_disp} Path WS Alt",
  f"{proto_disp} Path HUP",
  f"{proto_disp} Path HUP Alt",
  f"{proto_disp} Path XHTTP",
  f"{proto_disp} Path XHTTP Alt",
  f"{proto_disp} Path Service",
  f"{proto_disp} Path Service Alt",
]
if proto in TCP_TLS_PROTOCOLS:
  running_labels.append(f"{proto_disp} TCP+TLS Port")
running_label_width = max(len(label) for label in running_labels)
nets = ["ws", "httpupgrade", "grpc"]
if proto in TCP_TLS_PROTOCOLS:
  nets = ["tcp"] + nets
nets = [net for net in nets if net != "grpc"] + ["xhttp", "grpc"]
for net in nets:
  val = public_proto.get(net, "")
  if proto == "vless":
    links[net] = vless_link(net, val)
  elif proto == "vmess":
    links[net] = vmess_link(net, val)
  elif proto == "trojan":
    links[net] = trojan_link(net, val)

lines = []
lines.append("=== XRAY ACCOUNT INFO ===")
lines.append(f"  Domain      : {domain}")
lines.append(f"  IP          : {ip}")
lines.append(f"  ISP         : {isp}")
lines.append(f"  Country     : {country}")
lines.append(f"  Username    : {username}")
lines.append(f"  Protocol    : {proto}")
if proto in ("vless", "vmess"):
  lines.append(f"  UUID        : {cred}")
else:
  lines.append(f"  Password    : {cred}")
lines.append(f"  Quota Limit : {quota_gb_disp} GB")
lines.append(f"  Expired     : {days} days")
lines.append(f"  Valid Until : {expired_at}")
lines.append(f"  Created     : {created_disp}")
lines.append(f"  IP Limit    : {'ON' if ip_enabled else 'OFF'}" + (f" ({ip_limit_int})" if ip_enabled and ip_limit_int > 0 else ""))
if speed_enabled:
  lines.append(f"  Speed Limit : ON (DOWN {fmt_mbit(speed_down_mbit)} Mbps | UP {fmt_mbit(speed_up_mbit)} Mbps)")
else:
  lines.append("  Speed Limit : OFF")
lines.append(f"  Portal Info : {portal_url}")
lines.append("")
lines.append("=== RUNNING ON PORT & PATH ===")
lines.append(section_line(f"{proto_disp} WS", primary_ports_disp, running_label_width))
lines.append(section_line(f"{proto_disp} HUP", primary_ports_disp, running_label_width))
lines.append(section_line(f"{proto_disp} XHTTP", primary_ports_disp, running_label_width))
lines.append(section_line(f"{proto_disp} gRPC", primary_ports_disp, running_label_width))
if proto in TCP_TLS_PROTOCOLS:
  lines.append(section_line(f"{proto_disp} TCP+TLS Port", primary_ports_disp, running_label_width))
lines.append(section_line("Alt Port SSL/TLS", alt_tls_ports_disp, running_label_width))
lines.append(section_line("Alt Port HTTP", alt_http_ports_disp, running_label_width))
lines.append(section_line(f"{proto_disp} Path WS", ws_path, running_label_width))
lines.append(section_line(f"{proto_disp} Path WS Alt", ws_path_alt, running_label_width))
lines.append(section_line(f"{proto_disp} Path HUP", hup_path, running_label_width))
lines.append(section_line(f"{proto_disp} Path HUP Alt", hup_path_alt, running_label_width))
lines.append(section_line(f"{proto_disp} Path XHTTP", xhttp_path, running_label_width))
lines.append(section_line(f"{proto_disp} Path XHTTP Alt", xhttp_path_alt, running_label_width))
lines.append(section_line(f"{proto_disp} Path Service", grpc_service, running_label_width))
lines.append(section_line(f"{proto_disp} Path Service Alt", grpc_service_alt, running_label_width))
lines.append("")
lines.append("=== LINKS IMPORT ===")
if "tcp" in links:
  append_link_block(lines, "TCP+TLS", links.get('tcp', '-'))
  lines.append("")
append_link_block(lines, "WebSocket", links.get('ws', '-'))
lines.append("")
append_link_block(lines, "HTTPUpgrade", links.get('httpupgrade', '-'))
lines.append("")
if "xhttp" in links:
  append_link_block(lines, "XHTTP", links.get('xhttp', '-'))
  lines.append("")
append_link_block(lines, "gRPC", links.get('grpc', '-'))
lines.append("")

os.makedirs(os.path.dirname(out_file) or ".", exist_ok=True)
fd, tmp = tempfile.mkstemp(prefix=".tmp.", suffix=".txt", dir=os.path.dirname(out_file) or ".")
try:
  with os.fdopen(fd, "w", encoding="utf-8") as f:
    f.write("\n".join(lines))
    f.flush()
    os.fsync(f.fileno())
  os.replace(tmp, out_file)
finally:
  try:
    if os.path.exists(tmp):
      os.remove(tmp)
  except Exception:
    pass
if meta_dirty and quota_file:
  write_json_atomic(quota_file, meta)
PY
  rc=$?
  set -e

  if (( rc == 20 )); then
    warn "Credential ${username}@${proto} tidak ditemukan, skip refresh account info."
    return 1
  fi
  if (( rc != 0 )); then
    warn "Gagal refresh XRAY ACCOUNT INFO untuk ${username}@${proto}"
    return 1
  fi

  chmod 600 "${output_file_override:-${acc_file}}" 2>/dev/null || true
  return 0
}

account_info_refresh_warn() {
  # args: protocol username
  local proto="$1"
  local username="$2"
  if ! account_info_refresh_for_user "${proto}" "${username}"; then
    warn "XRAY ACCOUNT INFO belum sinkron untuk ${username}@${proto}"
    return 1
  fi
  return 0
}

account_info_refresh_target_file_for_user() {
  local proto="$1"
  local username="$2"
  local acc_file acc_compatfmt
  acc_file="${ACCOUNT_ROOT}/${proto}/${username}@${proto}.txt"
  acc_compatfmt="${ACCOUNT_ROOT}/${proto}/${username}.txt"
  if [[ ! -f "${acc_file}" && -f "${acc_compatfmt}" ]]; then
    acc_file="${acc_compatfmt}"
  fi
  printf '%s\n' "${acc_file}"
}

account_info_refresh_snapshot_file() {
  local path="$1"
  local snap_dir="$2"
  local manifest_file="$3"
  local backup_file=""
  if [[ -e "${path}" || -L "${path}" ]]; then
    backup_file="$(mktemp "${snap_dir}/snapshot.XXXXXX" 2>/dev/null || true)"
    [[ -n "${backup_file}" ]] || return 1
    if ! cp -a "${path}" "${backup_file}" 2>/dev/null; then
      rm -f "${backup_file}" >/dev/null 2>&1 || true
      return 1
    fi
    printf 'file\t%s\t%s\n' "${path}" "${backup_file}" >> "${manifest_file}"
  else
    printf 'absent\t%s\t-\n' "${path}" >> "${manifest_file}"
  fi
}

account_info_refresh_restore_snapshot() {
  local manifest_file="$1"
  local failed=0 kind path backup_file
  while IFS=$'\t' read -r kind path backup_file; do
    case "${kind}" in
      file)
        mkdir -p "$(dirname "${path}")" 2>/dev/null || true
        if ! cp -a "${backup_file}" "${path}" 2>/dev/null; then
          warn "Rollback ACCOUNT INFO gagal restore: ${path}"
          failed=1
          continue
        fi
        chmod 600 "${path}" 2>/dev/null || true
        ;;
      absent)
        if [[ -e "${path}" || -L "${path}" ]]; then
          if ! rm -f "${path}" 2>/dev/null; then
            warn "Rollback ACCOUNT INFO gagal hapus file baru: ${path}"
            failed=1
          fi
        fi
        ;;
    esac
  done < "${manifest_file}"
  return "${failed}"
}

account_refresh_xray_batch_apply() {
  # args: domain ip start_idx end_idx protos_ref users_ref targets_ref updated_ref failed_ref skipped_ref
  local domain="${1:-}"
  local ip="${2:-}"
  local start_idx="${3:-0}"
  local end_idx="${4:-0}"
  local -n _protos_ref="${5}"
  local -n _users_ref="${6}"
  local -n _targets_ref="${7}"
  local -n _updated_ref="${8}"
  local -n _failed_ref="${9}"
  local -n _skipped_ref="${10}"
  local snap_dir="" manifest_file="" i proto username target_file candidate_file=""

  snap_dir="$(mktemp -d "${WORK_DIR}/.account-info-refresh-xray.XXXXXX" 2>/dev/null || true)"
  [[ -n "${snap_dir}" ]] || snap_dir="${WORK_DIR}/.account-info-refresh-xray.$$"
  mkdir -p "${snap_dir}" 2>/dev/null || return 1
  manifest_file="${snap_dir}/manifest.tsv"
  : > "${manifest_file}" || {
    rm -rf "${snap_dir}" >/dev/null 2>&1 || true
    return 1
  }

  for (( i=start_idx; i<end_idx; i++ )); do
    target_file="${_targets_ref[$i]}"
    [[ -n "${target_file}" ]] || continue
    if ! account_info_refresh_snapshot_file "${target_file}" "${snap_dir}" "${manifest_file}"; then
      warn "Gagal membuat snapshot batch ACCOUNT INFO Xray: ${target_file}"
      account_info_refresh_restore_snapshot "${manifest_file}" >/dev/null 2>&1 || warn "Rollback batch ACCOUNT INFO Xray juga gagal."
      rm -rf "${snap_dir}" >/dev/null 2>&1 || true
      return 1
    fi
  done

  for (( i=start_idx; i<end_idx; i++ )); do
    proto="${_protos_ref[$i]}"
    username="${_users_ref[$i]}"
    target_file="${_targets_ref[$i]}"
    candidate_file="${snap_dir}/xray.${i}.candidate.txt"
    rm -f -- "${candidate_file}" >/dev/null 2>&1 || true
    if ! account_info_refresh_for_user "${proto}" "${username}" "${domain}" "${ip}" "" "${candidate_file}"; then
      _failed_ref=$((_failed_ref + 1))
      warn "Refresh ACCOUNT INFO Xray gagal untuk ${username}@${proto}. Batch saat ini akan di-rollback."
      account_info_refresh_restore_snapshot "${manifest_file}" >/dev/null 2>&1 || warn "Rollback batch ACCOUNT INFO Xray juga gagal."
      rm -rf "${snap_dir}" >/dev/null 2>&1 || true
      return 1
    fi
    if [[ -f "${target_file}" ]] && cmp -s -- "${target_file}" "${candidate_file}"; then
      _skipped_ref=$((_skipped_ref + 1))
      rm -f -- "${candidate_file}" >/dev/null 2>&1 || true
      continue
    fi
    if account_info_restore_file_locked "${candidate_file}" "${target_file}" >/dev/null 2>&1; then
      _updated_ref=$((_updated_ref + 1))
    else
      _failed_ref=$((_failed_ref + 1))
      warn "Commit ACCOUNT INFO Xray gagal untuk ${username}@${proto}. Batch saat ini akan di-rollback."
      account_info_refresh_restore_snapshot "${manifest_file}" >/dev/null 2>&1 || warn "Rollback batch ACCOUNT INFO Xray juga gagal."
      rm -f -- "${candidate_file}" >/dev/null 2>&1 || true
      rm -rf "${snap_dir}" >/dev/null 2>&1 || true
      return 1
    fi
    rm -f -- "${candidate_file}" >/dev/null 2>&1 || true
  done

  rm -rf "${snap_dir}" >/dev/null 2>&1 || true
  return 0
}

  # args: start_idx end_idx domain ip users_ref targets_ref updated_ref failed_ref skipped_ref
  local start_idx="${1:-0}"
  local end_idx="${2:-0}"
  local domain="${3:-}"
  local ip="${4:-}"
  local -n _users_ref="${5}"
  local -n _targets_ref="${6}"
  local -n _updated_ref="${7}"
  local -n _failed_ref="${8}"
  local -n _skipped_ref="${9}"
  local snap_dir="" manifest_file="" i username target_file state_file candidate_file=""

  mkdir -p "${snap_dir}" 2>/dev/null || return 1
  manifest_file="${snap_dir}/manifest.tsv"
  : > "${manifest_file}" || {
    rm -rf "${snap_dir}" >/dev/null 2>&1 || true
    return 1
  }

  for (( i=start_idx; i<end_idx; i++ )); do
    username="${_users_ref[$i]}"
    target_file="${_targets_ref[$i]}"
    if [[ -n "${target_file}" ]]; then
      if ! account_info_refresh_snapshot_file "${target_file}" "${snap_dir}" "${manifest_file}"; then
        rm -rf "${snap_dir}" >/dev/null 2>&1 || true
        return 1
      fi
    fi
    if [[ -n "${state_file}" ]]; then
      if ! account_info_refresh_snapshot_file "${state_file}" "${snap_dir}" "${manifest_file}"; then
        rm -rf "${snap_dir}" >/dev/null 2>&1 || true
        return 1
      fi
    fi
  done

  for (( i=start_idx; i<end_idx; i++ )); do
    username="${_users_ref[$i]}"
    target_file="${_targets_ref[$i]}"
    if ! account_info_target_write_preflight "${target_file}"; then
      rm -rf "${snap_dir}" >/dev/null 2>&1 || true
      return 1
    fi
    if [[ ! -f "${state_file}" ]]; then
      _skipped_ref=$((_skipped_ref + 1))
      continue
    fi
    rm -f -- "${candidate_file}" >/dev/null 2>&1 || true
      _failed_ref=$((_failed_ref + 1))
      rm -rf "${snap_dir}" >/dev/null 2>&1 || true
      return 1
    fi
    if [[ -f "${target_file}" ]] && cmp -s -- "${target_file}" "${candidate_file}"; then
      _skipped_ref=$((_skipped_ref + 1))
      rm -f -- "${candidate_file}" >/dev/null 2>&1 || true
      continue
    fi
    if account_info_restore_file_locked "${candidate_file}" "${target_file}" >/dev/null 2>&1; then
      _updated_ref=$((_updated_ref + 1))
    else
      _failed_ref=$((_failed_ref + 1))
      rm -f -- "${candidate_file}" >/dev/null 2>&1 || true
      rm -rf "${snap_dir}" >/dev/null 2>&1 || true
      return 1
    fi
    rm -f -- "${candidate_file}" >/dev/null 2>&1 || true
  done

  rm -rf "${snap_dir}" >/dev/null 2>&1 || true
  return 0
}

account_refresh_all_info_files() {
  # args: [domain] [ip] [scope]
  local domain="${1:-}"
  local ip="${2:-}"
  local scope="${3:-all}"
  local max_targets="${4:-0}"
  local start_offset="${5:-0}"
  local i proto username
  local -a xray_refresh_protos=() xray_refresh_users=() xray_refresh_targets=()
  local batch_size=10 batch_start=0 batch_end=0 total_batches=0 current_batch=0
  local total_selected=0 selected_offset=0

  if [[ "${USER_DATA_MUTATION_LOCK_HELD:-0}" != "1" ]]; then
    user_data_mutation_run_locked account_refresh_all_info_files "$@"
    return $?
  fi

  if [[ "${ACCOUNT_INFO_LOCK_HELD:-0}" != "1" ]]; then
    account_info_run_locked account_refresh_all_info_files "$@"
    return $?
  fi

  ensure_account_quota_dirs
  case "${scope}" in
    *) scope="all" ;;
  esac
  [[ "${max_targets}" =~ ^[0-9]+$ ]] || max_targets=0
  [[ "${start_offset}" =~ ^[0-9]+$ ]] || start_offset=0
  [[ -n "${domain}" ]] || domain="$(detect_domain)"
  [[ -n "${ip}" ]] || ip="$(detect_public_ip_ipapi)"

  if [[ "${scope}" == "all" || "${scope}" == "xray" ]]; then
    account_collect_files
    if (( ${#ACCOUNT_FILES[@]} > 0 )); then
      for i in "${!ACCOUNT_FILES[@]}"; do
        proto="${ACCOUNT_FILE_PROTOS[$i]}"
        username="$(account_parse_username_from_file "${ACCOUNT_FILES[$i]}" "${proto}")"
        [[ -n "${username}" ]] || continue
        if [[ -n "${seen_xray_users["${proto}|${username}"]+x}" ]]; then
          continue
        fi
        if (( start_offset > 0 && selected_offset < start_offset )); then
          seen_xray_users["${proto}|${username}"]=1
          selected_offset=$((selected_offset + 1))
          continue
        fi
        if (( max_targets > 0 && total_selected >= max_targets )); then
          break
        fi
        seen_xray_users["${proto}|${username}"]=1
        target_file="$(account_info_refresh_target_file_for_user "${proto}" "${username}")"
        xray_refresh_protos+=("${proto}")
        xray_refresh_users+=("${username}")
        xray_refresh_targets+=("${target_file}")
        total_selected=$((total_selected + 1))
      done
    fi
  fi
      [[ -n "${username}" ]] || continue
        continue
      fi
      if (( start_offset > 0 && selected_offset < start_offset )); then
        selected_offset=$((selected_offset + 1))
        continue
      fi
      if (( max_targets > 0 && total_selected >= max_targets )); then
        break
      fi
      total_selected=$((total_selected + 1))
    done
  fi

  if (( ${#xray_refresh_users[@]} > 0 )); then
    total_batches=$(( (${#xray_refresh_users[@]} + batch_size - 1) / batch_size ))
    for (( batch_start=0; batch_start<${#xray_refresh_users[@]}; batch_start+=batch_size )); do
      batch_end=$((batch_start + batch_size))
      (( batch_end > ${#xray_refresh_users[@]} )) && batch_end="${#xray_refresh_users[@]}"
      current_batch=$((batch_start / batch_size + 1))
      log "Refresh ACCOUNT INFO Xray batch ${current_batch}/${total_batches}."
      if ! account_refresh_xray_batch_apply "${domain}" "${ip}" "${batch_start}" "${batch_end}" xray_refresh_protos xray_refresh_users xray_refresh_targets updated failed xray_skipped; then
        return 1
      fi
    done
  fi

      batch_end=$((batch_start + batch_size))
      current_batch=$((batch_start / batch_size + 1))
        return 1
      fi
    done
  fi

    return 1
  fi
  return 0
}

domain_control_refresh_account_info_batches_run() {
  # args: domain ip scope [batch_limit]
  local domain="${1:-}"
  local ip="${2:-}"
  local scope="${3:-all}"
  local batch_limit="${4:-10}"
  local offset=0

  [[ "${batch_limit}" =~ ^[0-9]+$ ]] || batch_limit=10
  if (( batch_limit < 1 )); then
    batch_limit=10
  fi

  summary="$(account_info_refresh_targets_summary "${scope}" 1)"
  [[ "${total_count}" =~ ^[0-9]+$ ]] || total_count=0
  if (( total_count == 0 )); then
    return 0
  fi

  while (( offset < total_count )); do
    if ! account_refresh_all_info_files "${domain}" "${ip}" "${scope}" "${batch_limit}" "${offset}"; then
      warn "Batch refresh ACCOUNT INFO pada offset ${offset} gagal. Mencoba ulang sekali lagi..."
      sleep 1
      if ! account_refresh_all_info_files "${domain}" "${ip}" "${scope}" "${batch_limit}" "${offset}"; then
        return 1
      fi
    fi
    offset=$((offset + batch_limit))
  done
  return 0
}


delete_one_file() {
  local f="$1"
  [[ -n "${f}" ]] || return 0
  if [[ -f "${f}" ]]; then
    if have_cmd lsattr && lsattr -d "${f}" 2>/dev/null | awk '{print $1}' | grep -q 'i'; then
      warn "File immutable, lepas dulu: chattr -i '${f}'"
    fi
    chmod u+w "${f}" 2>/dev/null || true
    if rm -f "${f}" 2>/dev/null; then
      log "Hapus: ${f}"
    else
      warn "Gagal hapus: ${f} (permission denied/immutable)"
    fi
  fi
}

delete_account_artifacts() {
  # args: protocol username
  local proto="$1"
  local username="$2"

  local acc_file acc_file_compatfmt quota_file quota_file_compatfmt
  acc_file="${ACCOUNT_ROOT}/${proto}/${username}@${proto}.txt"
  acc_file_compatfmt="${ACCOUNT_ROOT}/${proto}/${username}.txt"
  quota_file="${QUOTA_ROOT}/${proto}/${username}@${proto}.json"
  quota_file_compatfmt="${QUOTA_ROOT}/${proto}/${username}.json"

  delete_one_file "${acc_file}"
  delete_one_file "${acc_file_compatfmt}"
  delete_one_file "${quota_file}"
  delete_one_file "${quota_file}.lock"
  delete_one_file "${quota_file_compatfmt}"
  delete_one_file "${quota_file_compatfmt}.lock"
  speed_policy_remove_checked "${proto}" "${username}" >/dev/null 2>&1 || true
}

delete_account_artifacts_checked() {
  # args: protocol username
  local proto="$1"
  local username="$2"
  local failed=0
  local p=""
  for p in \
    "${ACCOUNT_ROOT}/${proto}/${username}@${proto}.txt" \
    "${ACCOUNT_ROOT}/${proto}/${username}.txt" \
    "${QUOTA_ROOT}/${proto}/${username}@${proto}.json" \
    "${QUOTA_ROOT}/${proto}/${username}@${proto}.json.lock" \
    "${QUOTA_ROOT}/${proto}/${username}.json" \
    "${QUOTA_ROOT}/${proto}/${username}.json.lock"; do
    if [[ ! -e "${p}" && ! -L "${p}" ]]; then
      continue
    fi
    chmod u+w "${p}" 2>/dev/null || true
    if ! rm -f "${p}" 2>/dev/null; then
      warn "Gagal hapus artefak: ${p}"
      failed=1
      continue
    fi
    if [[ -e "${p}" || -L "${p}" ]]; then
      warn "Artefak masih ada setelah unlink: ${p}"
      failed=1
    fi
  done
  if ! speed_policy_remove_checked "${proto}" "${username}"; then
    warn "Gagal hapus speed policy: ${username}@${proto}"
    failed=1
  fi
  return "${failed}"
}

xray_delete_user_restore_from_snapshots() {
  # args:
  # proto username previous_cred deleted_from_inbounds
  # canonical_account backup_account compat_account backup_account_compat
  # canonical_quota backup_quota compat_quota backup_quota_compat
  # speed_policy_file backup_speed
  local proto="$1"
  local username="$2"
  local previous_cred="$3"
  local deleted_from_inbounds="${4:-false}"
  local canonical_account_file="$5"
  local rollback_account_backup="$6"
  local compat_account_file="$7"
  local rollback_account_compat_backup="$8"
  local canonical_quota_file="$9"
  local rollback_quota_backup="${10}"
  local compat_quota_file="${11}"
  local rollback_quota_compat_backup="${12}"
  local speed_policy_file="${13}"
  local rollback_speed_backup="${14}"
  local -a notes=()

  if [[ "${deleted_from_inbounds}" == "true" ]]; then
    if ! xray_add_client "${proto}" "${username}" "${previous_cred}" >/dev/null 2>&1; then
      notes+=("restore inbounds gagal")
    fi
  fi

  if [[ -n "${rollback_quota_backup}" && -f "${rollback_quota_backup}" ]]; then
    if ! quota_restore_file_locked "${rollback_quota_backup}" "${canonical_quota_file}" 2>/dev/null; then
      notes+=("restore quota gagal")
    fi
  fi
  if [[ -n "${rollback_quota_compat_backup}" && -f "${rollback_quota_compat_backup}" ]]; then
    if ! quota_restore_file_locked "${rollback_quota_compat_backup}" "${compat_quota_file}" 2>/dev/null; then
      notes+=("restore quota compat gagal")
    fi
  fi
  if [[ -n "${rollback_account_backup}" && -f "${rollback_account_backup}" ]]; then
    if ! account_info_restore_file_locked "${rollback_account_backup}" "${canonical_account_file}" 2>/dev/null; then
      notes+=("restore account info gagal")
    fi
  fi
  if [[ -n "${rollback_account_compat_backup}" && -f "${rollback_account_compat_backup}" ]]; then
    if ! account_info_restore_file_locked "${rollback_account_compat_backup}" "${compat_account_file}" 2>/dev/null; then
      notes+=("restore account info compat gagal")
    fi
  fi
  if [[ -n "${rollback_speed_backup}" && -f "${rollback_speed_backup}" ]]; then
    if ! speed_policy_restore_file_locked "${rollback_speed_backup}" "${speed_policy_file}" 2>/dev/null; then
      notes+=("restore speed policy gagal")
    fi
  fi

  local effective_quota_file=""
  if [[ -f "${canonical_quota_file}" ]]; then
    effective_quota_file="${canonical_quota_file}"
  elif [[ -f "${compat_quota_file}" ]]; then
    effective_quota_file="${compat_quota_file}"
  fi

  if [[ -n "${effective_quota_file}" ]]; then
    local st_quota st_manual st_iplocked
    st_quota="$(quota_get_status_bool "${effective_quota_file}" "quota_exhausted" 2>/dev/null || echo "false")"
    st_manual="$(quota_get_status_bool "${effective_quota_file}" "manual_block" 2>/dev/null || echo "false")"
    st_iplocked="$(quota_get_status_bool "${effective_quota_file}" "ip_limit_locked" 2>/dev/null || echo "false")"
    xray_routing_set_user_in_marker "dummy-quota-user" "${username}@${proto}" "$( [[ "${st_quota}" == "true" ]] && echo on || echo off )" >/dev/null 2>&1 || notes+=("restore routing quota gagal")
    xray_routing_set_user_in_marker "dummy-block-user" "${username}@${proto}" "$( [[ "${st_manual}" == "true" ]] && echo on || echo off )" >/dev/null 2>&1 || notes+=("restore routing manual gagal")
    xray_routing_set_user_in_marker "dummy-limit-user" "${username}@${proto}" "$( [[ "${st_iplocked}" == "true" ]] && echo on || echo off )" >/dev/null 2>&1 || notes+=("restore routing ip-limit gagal")
    if ! quota_sync_speed_policy_for_user "${proto}" "${username}" "${effective_quota_file}" >/dev/null 2>&1; then
      notes+=("restore speed policy runtime gagal")
    fi
    if ! account_info_refresh_warn "${proto}" "${username}" >/dev/null 2>&1; then
      notes+=("refresh account info rollback gagal")
    fi
  fi

  if (( ${#notes[@]} > 0 )); then
    printf '%s\n' "$(IFS=' | '; echo "${notes[*]}")"
    return 1
  fi
  return 0
}

speed_policy_sync_xray_try() {
  ( speed_policy_sync_xray ) >/dev/null 2>&1
}

xray_add_client_try() {
  ( xray_add_client "$@" ) >/dev/null 2>&1
}

xray_delete_client_try() {
  ( xray_delete_client "$@" ) >/dev/null 2>&1
}

xray_reset_client_credential_try() {
  ( xray_reset_client_credential "$@" ) >/dev/null 2>&1
}

xray_user_current_credential_get() {
  local proto="$1"
  local username="$2"
  need_python3
  python3 - <<'PY' "${XRAY_INBOUNDS_CONF}" "${proto}" "${username}"
import json
import sys

src, proto, username = sys.argv[1:4]
email = f"{username}@{proto}"
try:
    cfg = json.load(open(src, "r", encoding="utf-8"))
except Exception:
    raise SystemExit(0)

for ib in cfg.get("inbounds") or []:
    if not isinstance(ib, dict):
        continue
    if str(ib.get("protocol") or "").strip().lower() != proto:
        continue
    clients = ((ib.get("settings") or {}).get("clients") or [])
    if not isinstance(clients, list):
        continue
    for client in clients:
        if not isinstance(client, dict):
            continue
        if str(client.get("email") or "").strip() != email:
            continue
        value = client.get("password") if proto == "trojan" else client.get("id")
        value = str(value or "").strip()
        if value:
            print(value)
            raise SystemExit(0)
raise SystemExit(0)
PY
}

quota_sync_speed_policy_for_user_try() {
  ( quota_sync_speed_policy_for_user "$@" )
}

xray_user_expiry_rollback() {
  # args: quota_file quota_backup proto username email_for_routing current_expiry was_present_in_inbounds readded_now
  local qf="$1"
  local backup="$2"
  local proto="$3"
  local username="$4"
  local email_for_routing="$5"
  local current_expiry="$6"
  local was_present_in_inbounds="${7:-false}"
  local readded_now="${8:-false}"
  local -a notes=()

  if ! quota_restore_file_locked "${backup}" "${qf}" >/dev/null 2>&1; then
    echo "Expiry rollback ke ${current_expiry} gagal: restore quota gagal"
    return 1
  fi

  if [[ "${was_present_in_inbounds}" == "true" ]]; then
    local rollback_apply_msg=""
    if ! rollback_apply_msg="$(xray_qac_apply_runtime_from_quota "${qf}" "${proto}" "${username}" "${email_for_routing}" true true)"; then
      notes+=("${rollback_apply_msg}")
    fi
  else
    if [[ "${readded_now}" == "true" ]]; then
      if ! xray_delete_client_try "${proto}" "${username}"; then
        notes+=("hapus restore sementara gagal")
      fi
    fi
    xray_routing_set_user_in_marker "dummy-quota-user" "${email_for_routing}" off >/dev/null 2>&1 || notes+=("restore routing quota expired gagal")
    xray_routing_set_user_in_marker "dummy-block-user" "${email_for_routing}" off >/dev/null 2>&1 || notes+=("restore routing manual block expired gagal")
    xray_routing_set_user_in_marker "dummy-limit-user" "${email_for_routing}" off >/dev/null 2>&1 || notes+=("restore routing ip-limit expired gagal")
    if ! account_info_refresh_warn "${proto}" "${username}" >/dev/null 2>&1; then
      notes+=("refresh XRAY ACCOUNT INFO rollback gagal")
    fi
  fi

  if (( ${#notes[@]} > 0 )); then
    echo "Expiry dirollback ke ${current_expiry}, tetapi rollback belum bersih: $(IFS=' | '; echo "${notes[*]}")"
    return 1
  fi
  echo "Expiry dirollback ke ${current_expiry}."
  return 0
}

xray_qac_apply_runtime_from_quota() {
  # args: quota_file proto username email_for_routing restart_limit_ip sync_speed
  local qf="$1"
  local proto="$2"
  local username="$3"
  local email_for_routing="$4"
  local restart_limit_ip="${5:-false}"
  local sync_speed="${6:-false}"
  local st_quota st_manual st_iplocked

  st_quota="$(quota_get_status_bool "${qf}" "quota_exhausted" 2>/dev/null || echo "false")"
  st_manual="$(quota_get_status_bool "${qf}" "manual_block" 2>/dev/null || echo "false")"
  st_iplocked="$(quota_get_status_bool "${qf}" "ip_limit_locked" 2>/dev/null || echo "false")"

  if ! xray_routing_set_user_in_marker "dummy-quota-user" "${email_for_routing}" "$( [[ "${st_quota}" == "true" ]] && echo on || echo off )" >/dev/null 2>&1; then
    echo "routing quota marker gagal"
    return 1
  fi
  if ! xray_routing_set_user_in_marker "dummy-block-user" "${email_for_routing}" "$( [[ "${st_manual}" == "true" ]] && echo on || echo off )" >/dev/null 2>&1; then
    echo "routing manual-block marker gagal"
    return 1
  fi
  if ! xray_routing_set_user_in_marker "dummy-limit-user" "${email_for_routing}" "$( [[ "${st_iplocked}" == "true" ]] && echo on || echo off )" >/dev/null 2>&1; then
    echo "routing ip-limit marker gagal"
    return 1
  fi

  if [[ "${restart_limit_ip}" == "true" ]]; then
    if ! svc_restart_any xray-limit-ip xray-limit >/dev/null 2>&1; then
      echo "restart service limit-ip gagal"
      return 1
    fi
  fi

  if [[ "${sync_speed}" == "true" ]]; then
    if ! quota_sync_speed_policy_for_user_try "${proto}" "${username}" "${qf}"; then
      echo "sinkronisasi speed policy gagal"
      return 1
    fi
  fi

  if ! account_info_refresh_warn "${proto}" "${username}"; then
    echo "XRAY ACCOUNT INFO belum sinkron"
    return 1
  fi

  return 0
}

xray_qac_atomic_apply() {
  # args: quota_file proto username email_for_routing restart_limit_ip sync_speed action [action_args...]
  local qf="$1"
  local proto="$2"
  local username="$3"
  local email_for_routing="$4"
  local restart_limit_ip="${5:-false}"
  local sync_speed="${6:-false}"
  local action="$7"
  shift 7 || true

  if [[ "${USER_DATA_MUTATION_LOCK_HELD:-0}" != "1" ]]; then
    user_data_mutation_run_locked xray_qac_atomic_apply "${qf}" "${proto}" "${username}" "${email_for_routing}" "${restart_limit_ip}" "${sync_speed}" "${action}" "$@"
    return $?
  fi

  local backup_file
  backup_file="$(mktemp "${WORK_DIR}/.quota-qac.${username}.${proto}.XXXXXX" 2>/dev/null || true)"
  if [[ -z "${backup_file}" ]]; then
    echo "gagal membuat backup quota"
    return 1
  fi
  if ! QUOTA_ATOMIC_BACKUP_FILE="${backup_file}" quota_atomic_update_file "${qf}" "${action}" "$@"; then
    rm -f -- "${backup_file}" >/dev/null 2>&1 || true
    echo "gagal update metadata quota"
    return 1
  fi

  local apply_msg=""
  if ! apply_msg="$(xray_qac_apply_runtime_from_quota "${qf}" "${proto}" "${username}" "${email_for_routing}" "${restart_limit_ip}" "${sync_speed}")"; then
    local -a rollback_notes=()
    if ! quota_restore_file_locked "${backup_file}" "${qf}" >/dev/null 2>&1; then
      rollback_notes+=("rollback quota gagal")
    else
      local rollback_apply_msg=""
      if ! rollback_apply_msg="$(xray_qac_apply_runtime_from_quota "${qf}" "${proto}" "${username}" "${email_for_routing}" "${restart_limit_ip}" "${sync_speed}")"; then
        rollback_notes+=("rollback runtime gagal: ${rollback_apply_msg}")
      fi
    fi
    rm -f -- "${backup_file}" >/dev/null 2>&1 || true
    if (( ${#rollback_notes[@]} > 0 )); then
      echo "${apply_msg}. Rollback: ${rollback_notes[*]}"
    else
      echo "${apply_msg}. State di-rollback."
    fi
    return 1
  fi

  rm -f -- "${backup_file}" >/dev/null 2>&1 || true
  return 0
}

xray_qac_unlock_ip_atomic_apply() {
  # args: quota_file proto username email_for_routing
  local qf="$1"
  local proto="$2"
  local username="$3"
  local email_for_routing="$4"
  local backup_file=""

  if [[ "${USER_DATA_MUTATION_LOCK_HELD:-0}" != "1" ]]; then
    user_data_mutation_run_locked xray_qac_unlock_ip_atomic_apply "${qf}" "${proto}" "${username}" "${email_for_routing}"
    return $?
  fi

  backup_file="$(mktemp "${WORK_DIR}/.quota-unlock-ip.${username}.${proto}.XXXXXX" 2>/dev/null || true)"
  if [[ -z "${backup_file}" ]]; then
    echo "gagal membuat backup quota"
    return 1
  fi
  if ! QUOTA_ATOMIC_BACKUP_FILE="${backup_file}" quota_atomic_update_file "${qf}" clear_ip_limit_locked_recompute; then
    rm -f -- "${backup_file}" >/dev/null 2>&1 || true
    echo "gagal update metadata quota"
    return 1
  fi

  local apply_msg=""
  if ! apply_msg="$(xray_qac_apply_runtime_from_quota "${qf}" "${proto}" "${username}" "${email_for_routing}" true false)"; then
    local -a rollback_notes=()
    if ! quota_restore_file_locked "${backup_file}" "${qf}" >/dev/null 2>&1; then
      rollback_notes+=("rollback quota gagal")
    else
      local rollback_apply_msg=""
      if ! rollback_apply_msg="$(xray_qac_apply_runtime_from_quota "${qf}" "${proto}" "${username}" "${email_for_routing}" true false)"; then
        rollback_notes+=("rollback runtime gagal: ${rollback_apply_msg}")
      fi
    fi
    rm -f -- "${backup_file}" >/dev/null 2>&1 || true
    if (( ${#rollback_notes[@]} > 0 )); then
      echo "${apply_msg}. Rollback: ${rollback_notes[*]}"
    else
      echo "${apply_msg}. State di-rollback."
    fi
    return 1
  fi

  if [[ -x /usr/local/bin/limit-ip ]]; then
    if ! /usr/local/bin/limit-ip unlock "${email_for_routing}" >/dev/null 2>&1; then
      local -a rollback_notes=()
      if ! quota_restore_file_locked "${backup_file}" "${qf}" >/dev/null 2>&1; then
        rollback_notes+=("rollback quota gagal")
      else
        local rollback_apply_msg=""
        if ! rollback_apply_msg="$(xray_qac_apply_runtime_from_quota "${qf}" "${proto}" "${username}" "${email_for_routing}" true false)"; then
          rollback_notes+=("rollback runtime gagal: ${rollback_apply_msg}")
        fi
      fi
      rm -f -- "${backup_file}" >/dev/null 2>&1 || true
      if (( ${#rollback_notes[@]} > 0 )); then
        echo "service limit-ip unlock gagal. Rollback: ${rollback_notes[*]}"
      else
        echo "service limit-ip unlock gagal. State di-rollback."
      fi
      return 1
    fi
  fi

  rm -f -- "${backup_file}" >/dev/null 2>&1 || true
  return 0
}

user_add_apply_locked() {
  local rc=0
  (
    USER_ADD_ABORT_PROTO="$1"
    USER_ADD_ABORT_USERNAME="$2"
    USER_ADD_ABORT_ROLLBACK="1"
    USER_ADD_ABORT_INBOUNDS_CREATED="0"
    USER_ADD_ABORT_TXN_DIR=""
    trap '
      if [[ "${USER_ADD_ABORT_ROLLBACK:-0}" == "1" ]]; then
        if rollback_new_user_after_create_failure "${USER_ADD_ABORT_PROTO}" "${USER_ADD_ABORT_USERNAME}" "transaksi add user terputus sebelum commit final" "$( [[ "${USER_ADD_ABORT_INBOUNDS_CREATED:-0}" == "1" ]] && echo true || echo false )" >/dev/null 2>&1; then
          mutation_txn_dir_remove "${USER_ADD_ABORT_TXN_DIR:-}" >/dev/null 2>&1 || true
        fi
      fi
    ' EXIT INT TERM HUP QUIT
    user_add_apply_locked_inner "$@"
    rc=$?
    USER_ADD_ABORT_ROLLBACK="0"
    trap - EXIT INT TERM HUP QUIT
    exit "${rc}"
  )
  rc=$?
  return "${rc}"
}

user_add_apply_locked_inner() {
  local proto="$1"
  local username="$2"
  local quota_bytes="$3"
  local days="$4"
  local ip_enabled="$5"
  local ip_limit="$6"
  local speed_enabled="$7"
  local speed_down_mbit="$8"
  local speed_up_mbit="$9"
  local cred
  local stage_dir="" staged_account_file="" staged_quota_file=""
  local live_account_file="" live_quota_file=""
  local speed_prepare_result="" speed_mark=""
  local add_txn_dir=""

  if proto_uses_password "${proto}"; then
    cred="$(python3 - <<'PY'
import secrets
print(secrets.token_hex(16))
PY
)"
  else
    cred="$(gen_uuid)"
  fi

  live_account_file="${ACCOUNT_ROOT}/${proto}/${username}@${proto}.txt"
  live_quota_file="${QUOTA_ROOT}/${proto}/${username}@${proto}.json"
  stage_dir="$(mktemp -d "${WORK_DIR}/.xray-add.${username}.${proto}.XXXXXX" 2>/dev/null || true)"
  if [[ -z "${stage_dir}" || ! -d "${stage_dir}" ]]; then
    warn "Akun ${username}@${proto} dibatalkan: gagal menyiapkan staging artefak akun."
    pause
    return 1
  fi
  staged_account_file="${stage_dir}/account.txt"
  staged_quota_file="${stage_dir}/quota.json"

  if ! write_account_artifacts "${proto}" "${username}" "${cred}" "${quota_bytes}" "${days}" "${ip_enabled}" "${ip_limit}" "${speed_enabled}" "${speed_down_mbit}" "${speed_up_mbit}" "${staged_account_file}" "${staged_quota_file}"; then
    warn "Akun ${username}@${proto} dibatalkan: gagal menulis metadata akun/quota."
    rm -rf "${stage_dir}" >/dev/null 2>&1 || true
    pause
    return 1
  fi

  add_txn_dir="$(mutation_txn_dir_new "xray-add.${proto}.${username}" 2>/dev/null || true)"
  if [[ -z "${add_txn_dir}" || ! -d "${add_txn_dir}" ]]; then
    warn "Akun ${username}@${proto} dibatalkan: gagal menyiapkan journal recovery add Xray."
    rm -rf "${stage_dir}" >/dev/null 2>&1 || true
    pause
    return 1
  fi
  USER_ADD_ABORT_TXN_DIR="${add_txn_dir}"
  mutation_txn_field_write "${add_txn_dir}" proto "${proto}" >/dev/null 2>&1 || true
  mutation_txn_field_write "${add_txn_dir}" username "${username}" >/dev/null 2>&1 || true
  mutation_txn_field_write "${add_txn_dir}" cred "${cred}" >/dev/null 2>&1 || true
  mutation_txn_field_write "${add_txn_dir}" live_account_file "${live_account_file}" >/dev/null 2>&1 || true
  mutation_txn_field_write "${add_txn_dir}" live_quota_file "${live_quota_file}" >/dev/null 2>&1 || true
  mutation_txn_field_write "${add_txn_dir}" runtime_created "0" >/dev/null 2>&1 || true
  cp -f -- "${staged_account_file}" "${add_txn_dir}/account.new.txt" >/dev/null 2>&1 || true
  cp -f -- "${staged_quota_file}" "${add_txn_dir}/quota.new.json" >/dev/null 2>&1 || true

  if ! speed_prepare_result="$(user_add_prepare_speed_policy_before_runtime "${proto}" "${username}" "${speed_enabled}" "${speed_down_mbit}" "${speed_up_mbit}" 2>&1)"; then
    warn "Akun ${username}@${proto} dibatalkan: ${speed_prepare_result:-setup speed policy gagal}."
    if ! rollback_new_user_after_create_failure "${proto}" "${username}" "${speed_prepare_result:-setup speed policy gagal}" "false"; then
      warn "Rollback add user tidak bersih sepenuhnya. Cek artefak account/quota/speed policy."
    else
      mutation_txn_dir_remove "${add_txn_dir}" >/dev/null 2>&1 || true
    fi
    rm -rf "${stage_dir}" >/dev/null 2>&1 || true
    pause
    return 1
  fi
  speed_mark="${speed_prepare_result}"

  if ! account_info_restore_file_locked "${staged_account_file}" "${live_account_file}" >/dev/null 2>&1 \
    || ! quota_restore_file_locked "${staged_quota_file}" "${live_quota_file}" >/dev/null 2>&1; then
    warn "Akun ${username}@${proto} dibatalkan: gagal commit artefak account/quota sebelum client live dibuat."
    if ! rollback_new_user_after_create_failure "${proto}" "${username}" "commit artefak account/quota gagal sebelum create runtime" "false"; then
      warn "Rollback add user tidak bersih sepenuhnya. Cek artefak account/quota/speed policy."
    else
      mutation_txn_dir_remove "${add_txn_dir}" >/dev/null 2>&1 || true
    fi
    rm -rf "${stage_dir}" >/dev/null 2>&1 || true
    pause
    return 1
  fi

  if ! xray_add_client "${proto}" "${username}" "${cred}"; then
    warn "Akun ${username}@${proto} dibatalkan: gagal menambah client ke inbounds Xray."
    if ! rollback_new_user_after_create_failure "${proto}" "${username}" "gagal menambah client ke inbounds Xray" "false"; then
      warn "Rollback add user tidak bersih sepenuhnya. Cek inbounds/account/quota/speed policy."
    else
      mutation_txn_dir_remove "${add_txn_dir}" >/dev/null 2>&1 || true
    fi
    rm -rf "${stage_dir}" >/dev/null 2>&1 || true
    pause
    return 1
  fi
  USER_ADD_ABORT_INBOUNDS_CREATED="1"
  mutation_txn_field_write "${add_txn_dir}" runtime_created "1" >/dev/null 2>&1 || true
  rm -rf "${stage_dir}" >/dev/null 2>&1 || true

  if [[ "${speed_enabled}" == "true" ]]; then
    log "Speed policy aktif untuk ${username}@${proto} (mark=${speed_mark}, down=${speed_down_mbit}Mbps, up=${speed_up_mbit}Mbps)"
  fi

  USER_ADD_ABORT_ROLLBACK="0"
  mutation_txn_dir_remove "${add_txn_dir}" >/dev/null 2>&1 || true
  rm -rf "${stage_dir}" >/dev/null 2>&1 || true

  title
  echo "Add user sukses ✅"
  local created_account_file created_quota_file
  created_account_file="${live_account_file}"
  created_quota_file="${live_quota_file}"
  hr
  echo "Account file:"
  echo "  ${created_account_file}"
  echo "Quota metadata:"
  echo "  ${created_quota_file}"
  hr
  echo "XRAY ACCOUNT INFO:"
  if [[ -f "${created_account_file}" ]]; then
    cat "${created_account_file}"
  else
    echo "(XRAY ACCOUNT INFO tidak ditemukan: ${created_account_file})"
  fi
  hr
  pause
}

xray_add_txn_recover_dir() {
  local txn_dir="${1:-}"
  local proto="" username="" cred="" runtime_created="" live_account_file="" live_quota_file=""
  local current_cred="" notes=""
  [[ -n "${txn_dir}" && -d "${txn_dir}" ]] || return 0

  proto="$(mutation_txn_field_read "${txn_dir}" proto 2>/dev/null || true)"
  username="$(mutation_txn_field_read "${txn_dir}" username 2>/dev/null || true)"
  cred="$(mutation_txn_field_read "${txn_dir}" cred 2>/dev/null || true)"
  runtime_created="$(mutation_txn_field_read "${txn_dir}" runtime_created 2>/dev/null || true)"
  live_account_file="$(mutation_txn_field_read "${txn_dir}" live_account_file 2>/dev/null || true)"
  live_quota_file="$(mutation_txn_field_read "${txn_dir}" live_quota_file 2>/dev/null || true)"
  [[ -n "${proto}" && -n "${username}" ]] || {
    mutation_txn_dir_remove "${txn_dir}"
    return 0
  }

  if [[ "${runtime_created}" != "1" ]]; then
    if rollback_new_user_after_create_failure "${proto}" "${username}" "membersihkan journal add Xray lama" "false" >/dev/null 2>&1; then
      mutation_txn_dir_remove "${txn_dir}"
      log "Recovery transaksi add Xray membersihkan staging lama untuk ${username}@${proto}."
      return 0
    fi
    warn "Recovery transaksi add Xray untuk ${username}@${proto} belum bersih: cleanup staging gagal."
    return 1
  fi

  current_cred="$(xray_user_current_credential_get "${proto}" "${username}" 2>/dev/null || true)"
  if [[ -z "${current_cred}" ]]; then
    if rollback_new_user_after_create_failure "${proto}" "${username}" "runtime client add Xray tidak lagi ada" "false" >/dev/null 2>&1; then
      mutation_txn_dir_remove "${txn_dir}"
      log "Recovery transaksi add Xray membersihkan artefak yatim untuk ${username}@${proto}."
      return 0
    fi
    warn "Recovery transaksi add Xray untuk ${username}@${proto} belum bersih: runtime hilang tetapi cleanup gagal."
    return 1
  fi
  if [[ -n "${cred}" && "${current_cred}" != "${cred}" ]]; then
    warn "Recovery transaksi add Xray untuk ${username}@${proto} ditahan: credential live sudah berubah sejak journal dibuat."
    return 1
  fi
  if [[ -f "${txn_dir}/account.new.txt" && -n "${live_account_file}" ]]; then
    account_info_restore_file_locked "${txn_dir}/account.new.txt" "${live_account_file}" >/dev/null 2>&1 || notes="commit account info gagal"
  fi
  if [[ -z "${notes}" && -f "${txn_dir}/quota.new.json" && -n "${live_quota_file}" ]]; then
    quota_restore_file_locked "${txn_dir}/quota.new.json" "${live_quota_file}" >/dev/null 2>&1 || notes="commit quota gagal"
  fi
  if [[ -z "${notes}" ]]; then
    mutation_txn_dir_remove "${txn_dir}"
    log "Recovery transaksi add Xray selesai untuk ${username}@${proto}."
    return 0
  fi
  warn "Recovery transaksi add Xray untuk ${username}@${proto} belum bersih: ${notes}"
  return 1
}

xray_add_txn_recover_pending_all() {
  local txn_dir=""
  local failed=0
  mutation_txn_prepare || return 0
  while IFS= read -r -d '' txn_dir; do
    [[ -n "${txn_dir}" ]] || continue
    if ! xray_add_txn_recover_dir "${txn_dir}"; then
      failed=1
    fi
  done < <(find "${MUTATION_TXN_DIR}" -maxdepth 1 -type d -name 'xray-add.*' -print0 2>/dev/null | sort -z)
  return "${failed}"
}

xray_delete_txn_recover_dir() {
  local txn_dir="${1:-}"
  local proto username deleted_flag previous_cred current_cred notes=""
  [[ -n "${txn_dir}" && -d "${txn_dir}" ]] || return 0

  proto="$(mutation_txn_field_read "${txn_dir}" proto 2>/dev/null || true)"
  username="$(mutation_txn_field_read "${txn_dir}" username 2>/dev/null || true)"
  deleted_flag="$(mutation_txn_field_read "${txn_dir}" runtime_deleted 2>/dev/null || true)"
  previous_cred="$(mutation_txn_field_read "${txn_dir}" previous_cred 2>/dev/null || true)"
  if [[ -z "${proto}" || -z "${username}" ]]; then
    mutation_txn_dir_remove "${txn_dir}"
    return 0
  fi
  if [[ "${deleted_flag}" != "1" ]]; then
    local canonical_account_file compat_account_file canonical_quota_file compat_quota_file speed_policy_file restore_msg=""
    canonical_account_file="${ACCOUNT_ROOT}/${proto}/${username}@${proto}.txt"
    compat_account_file="${ACCOUNT_ROOT}/${proto}/${username}.txt"
    canonical_quota_file="${QUOTA_ROOT}/${proto}/${username}@${proto}.json"
    compat_quota_file="${QUOTA_ROOT}/${proto}/${username}.json"
    speed_policy_file="$(speed_policy_file_path "${proto}" "${username}")"
    restore_msg="$(xray_delete_user_restore_from_snapshots \
      "${proto}" "${username}" "${previous_cred}" "false" \
      "${canonical_account_file}" "${txn_dir}/account.txt" \
      "${compat_account_file}" "${txn_dir}/account.compat.txt" \
      "${canonical_quota_file}" "${txn_dir}/quota.json" \
      "${compat_quota_file}" "${txn_dir}/quota.compat.json" \
      "${speed_policy_file}" "${txn_dir}/speed.json" 2>/dev/null || true)"
    if [[ -n "${restore_msg}" ]]; then
      warn "Recovery transaksi delete Xray untuk ${username}@${proto} belum bersih: ${restore_msg}"
      return 1
    fi
    mutation_txn_dir_remove "${txn_dir}"
    log "Recovery transaksi delete Xray memulihkan state pra-delete untuk ${username}@${proto}."
    return 0
  fi

  current_cred="$(xray_user_current_credential_get "${proto}" "${username}" 2>/dev/null || true)"
  if [[ -n "${current_cred}" ]]; then
    if [[ -n "${previous_cred}" && "${current_cred}" != "${previous_cred}" ]]; then
      warn "Recovery transaksi delete Xray untuk ${username}@${proto} ditahan: credential live sudah berubah sejak jurnal dibuat."
      return 1
    fi
    xray_delete_client_try "${proto}" "${username}" || notes="hapus client runtime ulang gagal"
  fi
  if [[ -z "${notes}" ]] && ! delete_account_artifacts_checked "${proto}" "${username}"; then
    notes="cleanup artefak lokal gagal"
  fi
  if [[ -z "${notes}" ]] && ! speed_policy_sync_xray_try; then
    notes="sinkronisasi speed policy gagal"
  elif [[ -z "${notes}" ]] && ! speed_policy_apply_now >/dev/null 2>&1; then
    notes="apply runtime speed policy gagal"
  fi

  if [[ -z "${notes}" ]]; then
    log "Recovery transaksi delete Xray selesai untuk ${username}@${proto}."
    mutation_txn_dir_remove "${txn_dir}"
    return 0
  fi

  warn "Recovery transaksi delete Xray untuk ${username}@${proto} belum bersih: ${notes}"
  return 1
}

xray_delete_txn_recover_pending_all() {
  local txn_dir=""
  local failed=0
  mutation_txn_prepare || return 0
  while IFS= read -r -d '' txn_dir; do
    [[ -n "${txn_dir}" ]] || continue
    if ! xray_delete_txn_recover_dir "${txn_dir}"; then
      failed=1
    fi
  done < <(find "${MUTATION_TXN_DIR}" -maxdepth 1 -type d -name 'xray-delete.*' -print0 2>/dev/null | sort -z)
  return "${failed}"
}

xray_reset_txn_recover_dir() {
  local txn_dir="${1:-}"
  local proto username target_file previous_cred new_cred runtime_changed file_committed live_cred=""
  local selected_snapshot staged_account_file
  local status_msg=""
  [[ -n "${txn_dir}" && -d "${txn_dir}" ]] || return 0

  proto="$(mutation_txn_field_read "${txn_dir}" proto 2>/dev/null || true)"
  username="$(mutation_txn_field_read "${txn_dir}" username 2>/dev/null || true)"
  target_file="$(mutation_txn_field_read "${txn_dir}" target_file 2>/dev/null || true)"
  previous_cred="$(mutation_txn_field_read "${txn_dir}" previous_cred 2>/dev/null || true)"
  new_cred="$(mutation_txn_field_read "${txn_dir}" new_cred 2>/dev/null || true)"
  runtime_changed="$(mutation_txn_field_read "${txn_dir}" runtime_changed 2>/dev/null || true)"
  file_committed="$(mutation_txn_field_read "${txn_dir}" file_committed 2>/dev/null || true)"
  selected_snapshot="${txn_dir}/account.txt"
  staged_account_file="${txn_dir}/account.new.txt"

  if [[ -z "${proto}" || -z "${username}" || -z "${target_file}" ]]; then
    mutation_txn_dir_remove "${txn_dir}"
    return 0
  fi
  if [[ "${runtime_changed}" != "1" ]]; then
    if [[ "${file_committed}" == "1" ]]; then
      if [[ -f "${selected_snapshot}" ]]; then
        if account_info_restore_file_locked "${selected_snapshot}" "${target_file}" >/dev/null 2>&1; then
          log "Recovery reset credential Xray selesai untuk ${username}@${proto}: rollback file account info lama diselesaikan dari journal."
          mutation_txn_dir_remove "${txn_dir}"
          return 0
        fi
      elif [[ -n "${previous_cred}" ]] && account_info_refresh_for_user "${proto}" "${username}" "" "" "${previous_cred}" >/dev/null 2>&1; then
        log "Recovery reset credential Xray selesai untuk ${username}@${proto}: account info lama dipulihkan dari journal."
        mutation_txn_dir_remove "${txn_dir}"
        return 0
      fi
      warn "Recovery reset credential Xray untuk ${username}@${proto} belum bersih: rollback file account info lama gagal."
      return 1
    fi
    mutation_txn_dir_remove "${txn_dir}"
    return 0
  fi

  live_cred="$(xray_user_current_credential_get "${proto}" "${username}" 2>/dev/null || true)"
  if [[ -z "${live_cred}" ]]; then
    warn "Recovery reset credential Xray untuk ${username}@${proto} belum bisa diselesaikan: credential live tidak terdeteksi."
    return 1
  fi

  if [[ -n "${new_cred}" && "${live_cred}" == "${new_cred}" && -f "${staged_account_file}" ]]; then
    if account_info_restore_file_locked "${staged_account_file}" "${target_file}" >/dev/null 2>&1; then
      status_msg="commit file account info baru diselesaikan dari journal"
    fi
  elif [[ -n "${previous_cred}" && "${live_cred}" == "${previous_cred}" ]]; then
    if [[ -f "${selected_snapshot}" ]]; then
      if account_info_restore_file_locked "${selected_snapshot}" "${target_file}" >/dev/null 2>&1; then
        status_msg="rollback file account info lama diselesaikan dari journal"
      fi
    elif account_info_refresh_for_user "${proto}" "${username}" "" "" "${previous_cred}" >/dev/null 2>&1; then
      status_msg="refresh account info lama diselesaikan dari journal"
    fi
  fi

  if [[ -z "${status_msg}" ]] && account_info_refresh_for_user "${proto}" "${username}" "" "" "${live_cred}" >/dev/null 2>&1; then
    status_msg="account info diselaraskan ke credential live dari journal"
  fi

  if [[ -n "${status_msg}" ]]; then
    log "Recovery reset credential Xray selesai untuk ${username}@${proto}: ${status_msg}."
    mutation_txn_dir_remove "${txn_dir}"
    return 0
  fi

  warn "Recovery reset credential Xray untuk ${username}@${proto} belum bersih."
  return 1
}

xray_reset_txn_recover_pending_all() {
  local txn_dir=""
  local failed=0
  mutation_txn_prepare || return 0
  while IFS= read -r -d '' txn_dir; do
    [[ -n "${txn_dir}" ]] || continue
    if ! xray_reset_txn_recover_dir "${txn_dir}"; then
      failed=1
    fi
  done < <(find "${MUTATION_TXN_DIR}" -maxdepth 1 -type d -name 'xray-reset.*' -print0 2>/dev/null | sort -z)
  return "${failed}"
}

xray_pending_txn_dirs_by_kind() {
  local kind="${1:-all}"
  case "${kind}" in
    add) mutation_txn_list_dirs 'xray-add.*' ;;
    delete) mutation_txn_list_dirs 'xray-delete.*' ;;
    reset) mutation_txn_list_dirs 'xray-reset.*' ;;
    all)
      mutation_txn_list_dirs 'xray-add.*'
      mutation_txn_list_dirs 'xray-delete.*'
      mutation_txn_list_dirs 'xray-reset.*'
      ;;
    *) return 0 ;;
  esac
}

xray_pending_txn_label() {
  local txn_dir="${1:-}"
  local base="" proto="" username="" created=""
  [[ -n "${txn_dir}" && -d "${txn_dir}" ]] || return 1
  base="$(basename "${txn_dir}")"
  proto="$(mutation_txn_field_read "${txn_dir}" proto 2>/dev/null || true)"
  username="$(mutation_txn_field_read "${txn_dir}" username 2>/dev/null || true)"
  created="$(date -r "${txn_dir}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || true)"
  case "${base}" in
    xray-add.*) printf 'ADD    | %s@%s | %s\n' "${username:-?}" "${proto:-?}" "${created:-unknown}" ;;
    xray-delete.*) printf 'DELETE | %s@%s | %s\n' "${username:-?}" "${proto:-?}" "${created:-unknown}" ;;
    xray-reset.*) printf 'RESET  | %s@%s | %s\n' "${username:-?}" "${proto:-?}" "${created:-unknown}" ;;
    *) printf '%s | %s\n' "${base}" "${created:-unknown}" ;;
  esac
}

xray_pending_recovery_count() {
  local count=0
  mutation_txn_prepare || {
    printf '0\n'
    return 0
  }
  count="$(find "${MUTATION_TXN_DIR}" -maxdepth 1 -type d \( -name 'xray-add.*' -o -name 'xray-delete.*' -o -name 'xray-reset.*' \) 2>/dev/null | wc -l | tr -d '[:space:]' || true)"
  [[ "${count}" =~ ^[0-9]+$ ]] || count=0
  printf '%s\n' "${count}"
}

xray_pending_recovery_count_by_kind() {
  local kind="${1:-all}"
  local pattern=""
  local count=0
  mutation_txn_prepare || {
    printf '0\n'
    return 0
  }
  case "${kind}" in
    add) pattern='xray-add.*' ;;
    delete) pattern='xray-delete.*' ;;
    reset) pattern='xray-reset.*' ;;
    all) ;;
    *) printf '0\n'; return 0 ;;
  esac
  if [[ -n "${pattern}" ]]; then
    count="$(find "${MUTATION_TXN_DIR}" -maxdepth 1 -type d -name "${pattern}" 2>/dev/null | wc -l | tr -d '[:space:]' || true)"
  else
    count="$(find "${MUTATION_TXN_DIR}" -maxdepth 1 -type d \( -name 'xray-add.*' -o -name 'xray-delete.*' -o -name 'xray-reset.*' \) 2>/dev/null | wc -l | tr -d '[:space:]' || true)"
  fi
  [[ "${count}" =~ ^[0-9]+$ ]] || count=0
  printf '%s\n' "${count}"
}

xray_recover_pending_txn_now() {
  local kind="${1:-all}"
  local txn_dir="${2:-}"
  if [[ -n "${txn_dir}" ]]; then
    case "${kind}" in
      add) xray_add_txn_recover_dir "${txn_dir}" ;;
      delete) xray_delete_txn_recover_dir "${txn_dir}" ;;
      reset) xray_reset_txn_recover_dir "${txn_dir}" ;;
      *) return 1 ;;
    esac
    return $?
  fi
  case "${kind}" in
    add) xray_add_txn_recover_pending_all ;;
    delete) xray_delete_txn_recover_pending_all ;;
    reset) xray_reset_txn_recover_pending_all ;;
    all|*)
      local failed=0
      xray_add_txn_recover_pending_all || failed=1
      xray_delete_txn_recover_pending_all || failed=1
      xray_reset_txn_recover_pending_all || failed=1
      return "${failed}"
      ;;
  esac
}

xray_recover_pending_txn_pick_dir() {
  local kind="${1:-}"
  local -n _out_ref="${2}"
  local -a dirs=()
  local txn_dir="" choice="" i
  _out_ref=""
  [[ "${kind}" == "add" || "${kind}" == "delete" || "${kind}" == "reset" ]] || return 1
  while IFS= read -r txn_dir; do
    [[ -n "${txn_dir}" ]] || continue
    dirs+=("${txn_dir}")
  done < <(xray_pending_txn_dirs_by_kind "${kind}")
  if (( ${#dirs[@]} == 0 )); then
    return 1
  fi
  if (( ${#dirs[@]} == 1 )); then
    _out_ref="${dirs[0]}"
    return 0
  fi
  echo "Pilih journal recovery ${kind} Xray:"
  for i in "${!dirs[@]}"; do
    printf '  %d) %s\n' "$((i + 1))" "$(xray_pending_txn_label "${dirs[$i]}")"
  done
  while true; do
    if ! read -r -p "Pilih journal (1-${#dirs[@]}/kembali): " choice; then
      echo
      return 1
    fi
    if is_back_choice "${choice}"; then
      return 1
    fi
    [[ "${choice}" =~ ^[0-9]+$ ]] || { warn "Pilihan tidak valid."; continue; }
    if (( choice < 1 || choice > ${#dirs[@]} )); then
      warn "Nomor di luar range."
      continue
    fi
    _out_ref="${dirs[$((choice - 1))]}"
    return 0
  done
}

xray_recover_pending_txn_menu() {
  local pending_count=0 add_count=0 delete_count=0 reset_count=0 choice=""
  local selected_dir=""
  local selected_label=""
  pending_count="$(xray_pending_recovery_count)"
  add_count="$(xray_pending_recovery_count_by_kind add)"
  delete_count="$(xray_pending_recovery_count_by_kind delete)"
  reset_count="$(xray_pending_recovery_count_by_kind reset)"
  [[ "${pending_count}" =~ ^[0-9]+$ ]] || pending_count=0
  [[ "${add_count}" =~ ^[0-9]+$ ]] || add_count=0
  [[ "${delete_count}" =~ ^[0-9]+$ ]] || delete_count=0
  [[ "${reset_count}" =~ ^[0-9]+$ ]] || reset_count=0

  title
  echo "Xray Users > Recover Pending Txn"
  hr
  echo "Pending journal : ${pending_count}"
  echo "  Add    : ${add_count}"
  echo "  Delete : ${delete_count}"
  echo "  Reset  : ${reset_count}"
  if (( pending_count == 0 )); then
    log "Tidak ada journal recovery Xray yang tertunda."
    pause
    return 0
  fi
  echo "Catatan        : aksi ini bisa memodifikasi runtime/account info untuk menyelesaikan transaksi lama yang terputus."
  hr
  echo "  1) Recover journal Add"
  echo "  2) Recover journal Delete"
  echo "  3) Recover journal Reset"
  echo "  0) Back"
  hr
  read -r -p "Pilih aksi: " choice
  case "${choice}" in
    1)
      (( add_count > 0 )) || { warn "Tidak ada journal add Xray."; pause; return 0; }
      xray_recover_pending_txn_pick_dir add selected_dir || { pause; return 0; }
      selected_label="$(xray_pending_txn_label "${selected_dir}")"
      echo "Journal terpilih : ${selected_label}"
      confirm_menu_apply_now "Lanjutkan recovery journal add Xray ini sekarang? (${selected_label})" || { pause; return 0; }
      user_data_mutation_run_locked xray_recover_pending_txn_now add "${selected_dir}"
      ;;
    2)
      (( delete_count > 0 )) || { warn "Tidak ada journal delete Xray."; pause; return 0; }
      xray_recover_pending_txn_pick_dir delete selected_dir || { pause; return 0; }
      selected_label="$(xray_pending_txn_label "${selected_dir}")"
      echo "Journal terpilih : ${selected_label}"
      confirm_menu_apply_now "Lanjutkan recovery journal delete Xray ini sekarang? (${selected_label})" || { pause; return 0; }
      user_data_mutation_run_locked xray_recover_pending_txn_now delete "${selected_dir}"
      ;;
    3)
      (( reset_count > 0 )) || { warn "Tidak ada journal reset Xray."; pause; return 0; }
      xray_recover_pending_txn_pick_dir reset selected_dir || { pause; return 0; }
      selected_label="$(xray_pending_txn_label "${selected_dir}")"
      echo "Journal terpilih : ${selected_label}"
      confirm_menu_apply_now "Lanjutkan recovery journal reset Xray ini sekarang? (${selected_label})" || { pause; return 0; }
      user_data_mutation_run_locked xray_recover_pending_txn_now reset "${selected_dir}"
      ;;
    0|kembali|k|back|b)
      return 0
      ;;
    *)
      warn "Pilihan tidak valid."
      ;;
  esac
  pause
}

user_del_apply_locked() {
  local proto="$1"
  local username="$2"
  local selected_file="$3"
  local partial_failure="false"
  local rollback_restored="false"
  local deleted_from_inbounds="false"
  local abort_restore_active="false"
  local rollback_notes=()
  local previous_cred="" speed_policy_file="" rollback_tmpdir="" rollback_account_backup="" rollback_quota_backup="" rollback_speed_backup="" rollback_account_compat_backup="" rollback_quota_compat_backup=""
  local canonical_account_file compat_account_file canonical_quota_file compat_quota_file

  if [[ -f "${selected_file}" ]]; then
    if proto_uses_password "${proto}"; then
      previous_cred="$(grep -E '^Password\s*:' "${selected_file}" | head -n1 | sed 's/^Password\s*:\s*//' | tr -d '[:space:]' || true)"
    else
      previous_cred="$(grep -E '^UUID\s*:' "${selected_file}" | head -n1 | sed 's/^UUID\s*:\s*//' | tr -d '[:space:]' || true)"
    fi
  fi
  if [[ -z "${previous_cred}" ]]; then
    previous_cred="$(xray_user_current_credential_get "${proto}" "${username}")"
  fi
  if [[ -z "${previous_cred}" ]]; then
    warn "Delete user dibatalkan: credential lama untuk rollback tidak tersedia di file managed maupun runtime Xray."
    pause
    return 1
  fi

  speed_policy_file="$(speed_policy_file_path "${proto}" "${username}")"
  canonical_account_file="${ACCOUNT_ROOT}/${proto}/${username}@${proto}.txt"
  compat_account_file="${ACCOUNT_ROOT}/${proto}/${username}.txt"
  canonical_quota_file="${QUOTA_ROOT}/${proto}/${username}@${proto}.json"
  compat_quota_file="${QUOTA_ROOT}/${proto}/${username}.json"
  rollback_tmpdir="$(mutation_txn_dir_new "xray-delete.${proto}.${username}" 2>/dev/null || true)"
  if [[ -n "${rollback_tmpdir}" && -d "${rollback_tmpdir}" ]]; then
    mutation_txn_field_write "${rollback_tmpdir}" proto "${proto}" >/dev/null 2>&1 || true
    mutation_txn_field_write "${rollback_tmpdir}" username "${username}" >/dev/null 2>&1 || true
    mutation_txn_field_write "${rollback_tmpdir}" previous_cred "${previous_cred}" >/dev/null 2>&1 || true
    mutation_txn_field_write "${rollback_tmpdir}" runtime_deleted "0" >/dev/null 2>&1 || true
    rollback_account_backup="${rollback_tmpdir}/account.txt"
    rollback_quota_backup="${rollback_tmpdir}/quota.json"
    rollback_speed_backup="${rollback_tmpdir}/speed.json"
    rollback_account_compat_backup="${rollback_tmpdir}/account.compat.txt"
    rollback_quota_compat_backup="${rollback_tmpdir}/quota.compat.json"
    [[ -f "${canonical_account_file}" ]] && cp -f "${canonical_account_file}" "${rollback_account_backup}" 2>/dev/null || true
    [[ -f "${compat_account_file}" ]] && cp -f "${compat_account_file}" "${rollback_account_compat_backup}" 2>/dev/null || true
    [[ -f "${canonical_quota_file}" ]] && cp -f "${canonical_quota_file}" "${rollback_quota_backup}" 2>/dev/null || true
    [[ -f "${compat_quota_file}" ]] && cp -f "${compat_quota_file}" "${rollback_quota_compat_backup}" 2>/dev/null || true
    [[ -f "${speed_policy_file}" ]] && cp -f "${speed_policy_file}" "${rollback_speed_backup}" 2>/dev/null || true
  fi
  abort_restore_active="true"
  trap '
    if [[ "${abort_restore_active:-false}" == "true" ]]; then
      xray_delete_user_restore_from_snapshots "'"${proto}"'" "'"${username}"'" "'"${previous_cred}"'" "${deleted_from_inbounds:-false}" "'"${canonical_account_file}"'" "'"${rollback_account_backup}"'" "'"${compat_account_file}"'" "'"${rollback_account_compat_backup}"'" "'"${canonical_quota_file}"'" "'"${rollback_quota_backup}"'" "'"${compat_quota_file}"'" "'"${rollback_quota_compat_backup}"'" "'"${speed_policy_file}"'" "'"${rollback_speed_backup}"'" >/dev/null 2>&1 || true
    fi
  ' EXIT INT TERM HUP QUIT

  if ! delete_account_artifacts_checked "${proto}" "${username}"; then
    partial_failure="true"
    warn "Delete user dibatalkan: cleanup artefak lokal gagal sebelum inbounds Xray dihapus."
  elif [[ "${partial_failure}" != "true" ]] && ! speed_policy_sync_xray_try; then
    partial_failure="true"
    warn "Delete user dibatalkan: sinkronisasi speed policy gagal sebelum inbounds Xray dihapus."
  elif [[ "${partial_failure}" != "true" ]] && ! speed_policy_apply_now >/dev/null 2>&1; then
    partial_failure="true"
    warn "Delete user dibatalkan: apply runtime speed policy gagal sebelum inbounds Xray dihapus."
  elif [[ "${partial_failure}" != "true" ]] && ! xray_delete_client "${proto}" "${username}"; then
    partial_failure="true"
    warn "Delete user dibatalkan: gagal menghapus client dari inbounds Xray setelah cleanup artefak disiapkan."
  else
    deleted_from_inbounds="true"
    [[ -n "${rollback_tmpdir}" ]] && mutation_txn_field_write "${rollback_tmpdir}" runtime_deleted "1" >/dev/null 2>&1 || true
  fi

  if [[ "${partial_failure}" == "true" ]]; then
    local restore_msg=""
    if restore_msg="$(xray_delete_user_restore_from_snapshots \
      "${proto}" "${username}" "${previous_cred}" "${deleted_from_inbounds}" \
      "${canonical_account_file}" "${rollback_account_backup}" \
      "${compat_account_file}" "${rollback_account_compat_backup}" \
      "${canonical_quota_file}" "${rollback_quota_backup}" \
      "${compat_quota_file}" "${rollback_quota_compat_backup}" \
      "${speed_policy_file}" "${rollback_speed_backup}" 2>/dev/null)"; then
      rollback_restored="true"
      partial_failure="false"
    elif [[ -n "${restore_msg}" ]]; then
      rollback_notes+=("${restore_msg}")
    fi
  fi

  abort_restore_active="false"
  trap - EXIT INT TERM HUP QUIT
  if [[ "${rollback_restored}" == "true" || "${partial_failure}" != "true" ]]; then
    mutation_txn_dir_remove "${rollback_tmpdir}"
  fi

  title
  if [[ "${rollback_restored}" == "true" ]]; then
    echo "Delete user dibatalkan ⚠"
    echo "Cleanup akhir gagal, tetapi rollback berhasil memulihkan akun."
  elif [[ "${partial_failure}" == "true" ]]; then
    if [[ "${deleted_from_inbounds}" == "true" ]]; then
      echo "Delete user selesai parsial ⚠"
      echo "Perubahan utama sudah diterapkan, tetapi cleanup/sinkronisasi lanjutan belum bersih."
    else
      echo "Delete user dibatalkan parsial ⚠"
      echo "Inbounds Xray belum dihapus, tetapi rollback artefak lokal belum pulih sepenuhnya."
    fi
    if (( ${#rollback_notes[@]} > 0 )); then
      printf 'Rollback gagal: %s\n' "$(IFS=' | '; echo "${rollback_notes[*]}")"
    fi
  else
    echo "Delete user selesai ✅"
  fi
  hr
  pause
  if [[ "${rollback_restored}" == "true" || "${partial_failure}" == "true" ]]; then
    if [[ "${partial_failure}" == "true" && -n "${rollback_tmpdir}" ]]; then
      warn "Journal recovery delete Xray dipertahankan di ${rollback_tmpdir} sampai cleanup selesai."
    fi
    return 1
  fi
  return 0
}

user_extend_expiry_apply_locked() {
  local proto="$1"
  local username="$2"
  local quota_file="$3"
  local acc_file="$4"
  local current_expiry="$5"
  local new_expiry="$6"
  local email_for_routing existing_protos was_present_in_inbounds="false" readded_inbounds="false"
  local quota_backup_file=""
  local expired_daemon_paused="false"

  quota_backup_file="$(mktemp "${WORK_DIR}/.quota-expiry.${username}.${proto}.XXXXXX" 2>/dev/null || true)"
  if [[ -z "${quota_backup_file}" ]]; then
    warn "Gagal membuat backup metadata expiry."
    pause
    return 1
  fi

  if ! xray_expired_pause_if_active expired_daemon_paused; then
    rm -f -- "${quota_backup_file}" >/dev/null 2>&1 || true
    warn "Gagal menghentikan xray-expired sementara waktu. Extend expiry dibatalkan agar state tidak race."
    pause
    return 1
  fi

  email_for_routing="${username}@${proto}"
  existing_protos="$(xray_username_find_protos "${username}" 2>/dev/null || true)"
  if echo " ${existing_protos} " | grep -q " ${proto} "; then
    was_present_in_inbounds="true"
  fi

  if ! QUOTA_ATOMIC_BACKUP_FILE="${quota_backup_file}" quota_atomic_update_file "${quota_file}" set_expired_at "${new_expiry}"; then
    if ! xray_expired_resume_if_needed "${expired_daemon_paused}"; then
      warn "xray-expired gagal diaktifkan kembali setelah extend expiry dibatalkan."
    fi
    rm -f -- "${quota_backup_file}" >/dev/null 2>&1 || true
    warn "Gagal update metadata expiry quota."
    pause
    return 1
  fi

  if [[ "${was_present_in_inbounds}" != "true" ]]; then
    local restore_failed="false"
    local restore_reason=""
    if [[ -f "${acc_file}" ]]; then
      local cred=""
      if proto_uses_password "${proto}"; then
        cred="$(grep -E '^Password\s*:' "${acc_file}" | head -n1 | sed 's/^Password\s*:\s*//' | tr -d '[:space:]' || true)"
      else
        cred="$(grep -E '^UUID\s*:' "${acc_file}" | head -n1 | sed 's/^UUID\s*:\s*//' | tr -d '[:space:]' || true)"
      fi
      if [[ -n "${cred}" ]]; then
        if xray_add_client_try "${proto}" "${username}" "${cred}"; then
          readded_inbounds="true"
          log "User ${username}@${proto} di-restore ke inbounds (expired lalu di-extend)."
        else
          restore_failed="true"
          restore_reason="Gagal me-restore ${username}@${proto} ke inbounds. Cek credential di: ${acc_file}"
        fi
      else
        restore_failed="true"
        restore_reason="Credential tidak ditemukan di ${acc_file}. Re-add user manual jika diperlukan."
      fi
    else
      restore_failed="true"
      restore_reason="Account file tidak ada: ${acc_file}. User mungkin perlu di-add ulang secara manual."
    fi

    if [[ "${restore_failed}" == "true" ]]; then
      local rollback_msg=""
      rollback_msg="$(xray_user_expiry_rollback "${quota_file}" "${quota_backup_file}" "${proto}" "${username}" "${email_for_routing}" "${current_expiry}" "${was_present_in_inbounds}" "${readded_inbounds}" 2>&1 || true)"
      if ! xray_expired_resume_if_needed "${expired_daemon_paused}"; then
        warn "xray-expired gagal diaktifkan kembali setelah rollback extend expiry."
      fi
      warn "${restore_reason}"
      [[ -n "${rollback_msg}" ]] && warn "${rollback_msg}"
      rm -f -- "${quota_backup_file}" >/dev/null 2>&1 || true
      pause
      return 1
    fi
  fi

  if [[ "$(quota_get_status_bool "${quota_file}" "quota_exhausted" 2>/dev/null || echo "false")" == "true" ]]; then
    if ! quota_atomic_update_file "${quota_file}" clear_quota_exhausted_recompute; then
      local rollback_msg=""
      rollback_msg="$(xray_user_expiry_rollback "${quota_file}" "${quota_backup_file}" "${proto}" "${username}" "${email_for_routing}" "${current_expiry}" "${was_present_in_inbounds}" "${readded_inbounds}" 2>&1 || true)"
      if ! xray_expired_resume_if_needed "${expired_daemon_paused}"; then
        warn "xray-expired gagal diaktifkan kembali setelah rollback extend expiry."
      fi
      warn "Gagal reset status quota exhausted setelah extend expiry."
      [[ -n "${rollback_msg}" ]] && warn "${rollback_msg}"
      rm -f -- "${quota_backup_file}" >/dev/null 2>&1 || true
      pause
      return 1
    fi
    log "Quota exhausted flag di-reset setelah extend expiry."
  fi

  local apply_msg=""
  if ! apply_msg="$(xray_qac_apply_runtime_from_quota "${quota_file}" "${proto}" "${username}" "${email_for_routing}" true true)"; then
    local rollback_msg=""
    rollback_msg="$(xray_user_expiry_rollback "${quota_file}" "${quota_backup_file}" "${proto}" "${username}" "${email_for_routing}" "${current_expiry}" "${was_present_in_inbounds}" "${readded_inbounds}" 2>&1 || true)"
    if ! xray_expired_resume_if_needed "${expired_daemon_paused}"; then
      warn "xray-expired gagal diaktifkan kembali setelah rollback extend expiry."
    fi
    warn "Extend expiry gagal: ${apply_msg}"
    [[ -n "${rollback_msg}" ]] && warn "${rollback_msg}"
    rm -f -- "${quota_backup_file}" >/dev/null 2>&1 || true
    pause
    return 1
  fi

  if ! xray_expired_resume_if_needed "${expired_daemon_paused}"; then
    rm -f -- "${quota_backup_file}" >/dev/null 2>&1 || true
    warn "Expiry berhasil diperbarui, tetapi xray-expired gagal diaktifkan kembali."
    pause
    return 1
  fi

  rm -f -- "${quota_backup_file}" >/dev/null 2>&1 || true

  title
  echo "Extend/Set Expiry selesai ✅"
  hr
  echo "  ${username}@${proto}"
  echo "  Expiry baru : ${new_expiry}"
  hr
  pause
}

user_reset_credential_apply_locked() {
  local rc=0
  (
    XRAY_RESET_ABORT_PROTO="$1"
    XRAY_RESET_ABORT_USERNAME="$2"
    XRAY_RESET_ABORT_PREVIOUS_CRED=""
    XRAY_RESET_ABORT_TARGET_FILE=""
    XRAY_RESET_ABORT_SELECTED_SNAPSHOT=""
    XRAY_RESET_ABORT_FILE_COMMITTED="0"
    XRAY_RESET_ABORT_RUNTIME_CHANGED="0"
    XRAY_RESET_ABORT_ACTIVE="1"
    trap '
      if [[ "${XRAY_RESET_ABORT_ACTIVE:-0}" == "1" ]]; then
        if [[ "${XRAY_RESET_ABORT_RUNTIME_CHANGED:-0}" == "1" ]]; then
          xray_reset_client_credential_try "${XRAY_RESET_ABORT_PROTO}" "${XRAY_RESET_ABORT_USERNAME}" "${XRAY_RESET_ABORT_PREVIOUS_CRED}" >/dev/null 2>&1 || true
        fi
        if [[ "${XRAY_RESET_ABORT_FILE_COMMITTED:-0}" == "1" ]]; then
          if [[ -n "${XRAY_RESET_ABORT_SELECTED_SNAPSHOT:-}" && -f "${XRAY_RESET_ABORT_SELECTED_SNAPSHOT}" && -n "${XRAY_RESET_ABORT_TARGET_FILE:-}" ]]; then
            account_info_restore_file_locked "${XRAY_RESET_ABORT_SELECTED_SNAPSHOT}" "${XRAY_RESET_ABORT_TARGET_FILE}" >/dev/null 2>&1 || account_info_refresh_for_user "${XRAY_RESET_ABORT_PROTO}" "${XRAY_RESET_ABORT_USERNAME}" "" "" "${XRAY_RESET_ABORT_PREVIOUS_CRED}" >/dev/null 2>&1 || true
          else
            account_info_refresh_for_user "${XRAY_RESET_ABORT_PROTO}" "${XRAY_RESET_ABORT_USERNAME}" "" "" "${XRAY_RESET_ABORT_PREVIOUS_CRED}" >/dev/null 2>&1 || true
          fi
        fi
      fi
    ' EXIT INT TERM HUP QUIT
    user_reset_credential_apply_locked_inner "$@"
    rc=$?
    XRAY_RESET_ABORT_ACTIVE="0"
    trap - EXIT INT TERM HUP QUIT
    exit "${rc}"
  )
  rc=$?
  return "${rc}"
}

user_reset_credential_apply_locked_inner() {
  local proto="$1"
  local username="$2"
  local selected_file="$3"
  local previous_cred="" new_cred label
  local snapshot_dir="" selected_snapshot="" target_file="" snapshot_source="" staged_account_file=""

  target_file="$(account_info_refresh_target_file_for_user "${proto}" "${username}")"
  snapshot_source="${target_file}"
  if [[ -f "${selected_file}" ]]; then
    snapshot_source="${selected_file}"
    if proto_uses_password "${proto}"; then
      previous_cred="$(grep -E '^Password\s*:' "${selected_file}" | head -n1 | sed 's/^Password\s*:\s*//' | tr -d '[:space:]' || true)"
    else
      previous_cred="$(grep -E '^UUID\s*:' "${selected_file}" | head -n1 | sed 's/^UUID\s*:\s*//' | tr -d '[:space:]' || true)"
    fi
  fi
  if [[ -z "${previous_cred}" ]]; then
    previous_cred="$(xray_user_current_credential_get "${proto}" "${username}")"
  fi
  if [[ -z "${previous_cred}" ]]; then
    warn "Credential lama tidak ditemukan di file managed maupun runtime Xray."
    pause
    return 1
  fi
  XRAY_RESET_ABORT_PREVIOUS_CRED="${previous_cred}"

  if proto_uses_password "${proto}"; then
    new_cred="$(python3 - <<'PY'
import secrets
print(secrets.token_hex(16))
PY
)"
    label="Password baru"
  else
    new_cred="$(gen_uuid)"
    label="UUID baru"
  fi

  snapshot_dir="$(mutation_txn_dir_new "xray-reset.${proto}.${username}" 2>/dev/null || true)"
  if [[ -z "${snapshot_dir}" || ! -d "${snapshot_dir}" ]]; then
    warn "Gagal menyiapkan staging reset ${label,,} untuk ${username}@${proto}."
    pause
    return 1
  fi
  mutation_txn_field_write "${snapshot_dir}" proto "${proto}" >/dev/null 2>&1 || true
  mutation_txn_field_write "${snapshot_dir}" username "${username}" >/dev/null 2>&1 || true
  mutation_txn_field_write "${snapshot_dir}" target_file "${target_file}" >/dev/null 2>&1 || true
  mutation_txn_field_write "${snapshot_dir}" previous_cred "${previous_cred}" >/dev/null 2>&1 || true
  mutation_txn_field_write "${snapshot_dir}" new_cred "${new_cred}" >/dev/null 2>&1 || true
  mutation_txn_field_write "${snapshot_dir}" file_committed "0" >/dev/null 2>&1 || true
  mutation_txn_field_write "${snapshot_dir}" runtime_changed "0" >/dev/null 2>&1 || true
  if [[ -n "${snapshot_dir}" && -f "${snapshot_source}" ]]; then
    selected_snapshot="${snapshot_dir}/account.txt"
    cp -f -- "${snapshot_source}" "${selected_snapshot}" >/dev/null 2>&1 || selected_snapshot=""
  fi
  staged_account_file="${snapshot_dir}/account.new.txt"
  XRAY_RESET_ABORT_TARGET_FILE="${target_file}"
  XRAY_RESET_ABORT_SELECTED_SNAPSHOT="${selected_snapshot}"

  if ! account_info_target_write_preflight "${target_file}"; then
    mutation_txn_dir_remove "${snapshot_dir}"
    warn "Reset ${label,,} dibatalkan: target XRAY ACCOUNT INFO tidak siap ditulis."
    pause
    return 1
  fi

  if ! account_info_refresh_for_user "${proto}" "${username}" "" "" "${new_cred}" "${staged_account_file}"; then
    mutation_txn_dir_remove "${snapshot_dir}"
    warn "Reset ${label,,} dibatalkan: XRAY ACCOUNT INFO baru gagal disiapkan sebelum credential live diubah."
    pause
    return 1
  fi

  if ! account_info_restore_file_locked "${staged_account_file}" "${target_file}" >/dev/null 2>&1; then
    mutation_txn_dir_remove "${snapshot_dir}"
    warn "Reset ${label,,} dibatalkan: commit XRAY ACCOUNT INFO baru gagal sebelum credential live diubah."
    pause
    return 1
  fi
  XRAY_RESET_ABORT_FILE_COMMITTED="1"
  mutation_txn_field_write "${snapshot_dir}" file_committed "1" >/dev/null 2>&1 || true

  if ! xray_reset_client_credential_try "${proto}" "${username}" "${new_cred}"; then
    local rollback_file_failed="false"
    if [[ -n "${selected_snapshot}" && -f "${selected_snapshot}" ]]; then
      if ! account_info_restore_file_locked "${selected_snapshot}" "${target_file}" >/dev/null 2>&1; then
        if ! account_info_refresh_for_user "${proto}" "${username}" "" "" "${previous_cred}" >/dev/null 2>&1; then
          rollback_file_failed="true"
        fi
      fi
    elif ! account_info_refresh_for_user "${proto}" "${username}" "" "" "${previous_cred}" >/dev/null 2>&1; then
      rollback_file_failed="true"
    fi
    if [[ "${rollback_file_failed}" == "true" ]]; then
      warn "Reset ${label,,} dibatalkan: credential live baru gagal diterapkan dan rollback file account info lama juga gagal."
      warn "Journal recovery reset Xray dipertahankan di ${snapshot_dir}."
    else
      XRAY_RESET_ABORT_FILE_COMMITTED="0"
      mutation_txn_field_write "${snapshot_dir}" file_committed "0" >/dev/null 2>&1 || true
      mutation_txn_dir_remove "${snapshot_dir}"
      warn "Reset ${label,,} dibatalkan: credential live baru gagal diterapkan, file account info lama dipulihkan."
    fi
    pause
    return 1
  fi
  XRAY_RESET_ABORT_RUNTIME_CHANGED="1"
  mutation_txn_field_write "${snapshot_dir}" runtime_changed "1" >/dev/null 2>&1 || true

  XRAY_RESET_ABORT_FILE_COMMITTED="0"
  XRAY_RESET_ABORT_RUNTIME_CHANGED="0"
  XRAY_RESET_ABORT_ACTIVE="0"
  mutation_txn_dir_remove "${snapshot_dir}"

  title
  echo "Reset UUID/Password selesai ✅"
  hr
  echo "User         : ${username}@${proto}"
  echo "${label} : ${new_cred}"
  local account_file
  account_file="${ACCOUNT_ROOT}/${proto}/${username}@${proto}.txt"
  hr
  echo "Account file:"
  echo "  ${account_file}"
  hr
  echo "XRAY ACCOUNT INFO:"
  if [[ -f "${account_file}" ]]; then
    cat "${account_file}"
  else
    echo "(XRAY ACCOUNT INFO tidak ditemukan: ${account_file})"
  fi
  hr
  pause
}

user_add_menu() {
  local proto
  title
  echo "Xray Users > Add User"
  hr

  ensure_account_quota_dirs
  need_python3

  echo "Pilih protocol:"
  proto_list_menu_print
  hr
  if ! read -r -p "Protocol (1-3/kembali): " p; then
    echo
    return 0
  fi
  if is_back_choice "${p}"; then
    return 0
  fi
  proto="$(proto_menu_pick_to_value "${p}")"
  if [[ -z "${proto}" ]]; then
    warn "Protocol tidak valid"
    pause
    return 0
  fi

  local page=0
  while true; do
    title
    echo "Xray Users > Add User"
    hr
    echo "Protocol terpilih: ${proto}"
    echo "Daftar akun ${proto} (10 per halaman):"
    hr
    account_collect_files "${proto}"
    ACCOUNT_PAGE="${page}"
    if (( ${#ACCOUNT_FILES[@]} > 0 )); then
      account_print_table_page "${ACCOUNT_PAGE}" "${proto}"
    else
      echo "  (Belum ada akun ${proto} terkelola)"
      echo "  Ketik lanjut untuk membuat akun baru."
      echo
      echo "Halaman: 0/0  | Total akun: 0"
    fi
    hr
    echo "Ketik: lanjut / next / previous / kembali"
    if ! read -r -p "Pilihan: " nav; then
      echo
      return 0
    fi
    if is_back_choice "${nav}"; then
      return 0
    fi
    case "${nav}" in
      lanjut|lanjutkan|l) break ;;
      next|n)
        local pages
        pages="$(account_total_pages)"
        if (( pages > 0 && page < pages - 1 )); then page=$((page + 1)); fi
        ;;
      previous|p|prev)
        if (( page > 0 )); then page=$((page - 1)); fi
        ;;
      *) invalid_choice ;;
    esac
  done

  title
  echo "Xray Users > Add User"
  hr
  echo "Protocol : ${proto}"
  hr

  if ! read -r -p "Username (atau kembali): " username; then
    echo
    return 0
  fi
  if is_back_choice "${username}"; then
    return 0
  fi
  if [[ -z "${username}" ]]; then
    warn "Username kosong"
    pause
    return 0
  fi

  if ! validate_username "${username}"; then
    warn "Username tidak valid. Gunakan: A-Z a-z 0-9 . _ - (tanpa spasi, tanpa '/', tanpa '..', tanpa '@')."
    pause
    return 0
  fi


  local found_xray found_account found_quota
  found_xray="$(xray_username_find_protos "${username}" || true)"
  found_account="$(account_username_find_protos "${username}" || true)"
  found_quota="$(quota_username_find_protos "${username}" || true)"
  if [[ -n "${found_xray}" || -n "${found_account}" || -n "${found_quota}" ]]; then
    warn "Username sudah ada, batal membuat akun: ${username}"
    [[ -n "${found_xray}" ]] && echo "  - Xray inbounds: ${found_xray}"
    [[ -n "${found_account}" ]] && echo "  - Account file : ${found_account}"
    [[ -n "${found_quota}" ]] && echo "  - Quota meta   : ${found_quota}"
    pause
    return 0
  fi

  if ! read -r -p "Masa aktif (hari) (atau kembali): " days; then
    echo
    return 0
  fi
  if is_back_word_choice "${days}"; then
    return 0
  fi
  if [[ -z "${days}" || ! "${days}" =~ ^[0-9]+$ || "${days}" -le 0 ]]; then
    warn "Masa aktif harus angka hari > 0"
    pause
    return 0
  fi

  if ! read -r -p "Quota (GB) (atau kembali): " quota_gb; then
    echo
    return 0
  fi
  if is_back_choice "${quota_gb}"; then
    return 0
  fi
  if [[ -z "${quota_gb}" ]]; then
    warn "Quota kosong"
    pause
    return 0
  fi
  local quota_gb_num quota_bytes
  quota_gb_num="$(normalize_gb_input "${quota_gb}")"
  if [[ -z "${quota_gb_num}" ]]; then
    warn "Format quota tidak valid. Contoh: 10 atau 10GB"
    pause
    return 0
  fi
  quota_gb="${quota_gb_num}"
  quota_bytes="$(bytes_from_gb "${quota_gb_num}")"

  local ip_toggle=""
  echo "Limit IP? (on/off)"
  if ! read_required_on_off ip_toggle "IP Limit (on/off) (atau kembali): "; then
    return 0
  fi
  local ip_enabled="false"
  local ip_limit="0"
  if [[ "${ip_toggle}" == "on" ]]; then
    ip_enabled="true"
    if ! read -r -p "Limit IP (angka) (atau kembali): " ip_limit; then
      echo
      return 0
    fi
    if is_back_word_choice "${ip_limit}"; then
      return 0
    fi
    if [[ -z "${ip_limit}" || ! "${ip_limit}" =~ ^[0-9]+$ || "${ip_limit}" -le 0 ]]; then
      warn "Limit IP harus angka > 0"
      pause
      return 0
    fi
  fi

  local speed_toggle=""
  echo "Limit speed per user? (on/off)"
  if ! read_required_on_off speed_toggle "Speed Limit (on/off) (atau kembali): "; then
    return 0
  fi
  local speed_enabled="false"
  local speed_down_mbit="0"
  local speed_up_mbit="0"
  if [[ "${speed_toggle}" == "on" ]]; then
    speed_enabled="true"

    if ! read -r -p "Speed Download Mbps (contoh: 20 atau 20mbit) (atau kembali): " speed_down; then
      echo
      return 0
    fi
    if is_back_word_choice "${speed_down}"; then
      return 0
    fi
    speed_down_mbit="$(normalize_speed_mbit_input "${speed_down}")"
    if [[ -z "${speed_down_mbit}" ]] || ! speed_mbit_is_positive "${speed_down_mbit}"; then
      warn "Speed download tidak valid. Gunakan angka > 0, contoh: 20 atau 20mbit"
      pause
      return 0
    fi

    if ! read -r -p "Speed Upload Mbps (contoh: 10 atau 10mbit) (atau kembali): " speed_up; then
      echo
      return 0
    fi
    if is_back_word_choice "${speed_up}"; then
      return 0
    fi
    speed_up_mbit="$(normalize_speed_mbit_input "${speed_up}")"
    if [[ -z "${speed_up_mbit}" ]] || ! speed_mbit_is_positive "${speed_up_mbit}"; then
      warn "Speed upload tidak valid. Gunakan angka > 0, contoh: 10 atau 10mbit"
      pause
      return 0
    fi
  fi

  hr
  echo "Ringkasan:"
  echo "  Username : ${username}"
  echo "  Protocol : ${proto}"
  echo "  Email    : ${username}@${proto}"
  echo "  Expired  : ${days} hari"
  echo "  Quota    : ${quota_gb} GB"
  echo "  IP Limit : ${ip_enabled} $( [[ "${ip_enabled}" == "true" ]] && echo "(${ip_limit})" )"
  if [[ "${speed_enabled}" == "true" ]]; then
    echo "  Speed    : true (DOWN ${speed_down_mbit} Mbps | UP ${speed_up_mbit} Mbps)"
  else
    echo "  Speed    : false"
  fi
  hr
  local create_confirm_rc=0
  if confirm_yn_or_back "Buat user ini sekarang?"; then
    :
  else
    create_confirm_rc=$?
    if (( create_confirm_rc == 2 )); then
      warn "Pembuatan user dibatalkan (kembali)."
      pause
      return 0
    fi
    warn "Pembuatan user dibatalkan."
    pause
    return 0
  fi

  user_data_mutation_run_locked user_add_apply_locked "${proto}" "${username}" "${quota_bytes}" "${days}" "${ip_enabled}" "${ip_limit}" "${speed_enabled}" "${speed_down_mbit}" "${speed_up_mbit}"
}





user_del_menu() {
  ensure_account_quota_dirs
  need_python3

  title
  echo "Xray Users > Delete User"
  hr
  echo "Pilih protocol:"
  proto_list_menu_print
  hr
  if ! read -r -p "Protocol (1-3/kembali): " p; then
    echo
    return 0
  fi
  if is_back_choice "${p}"; then
    return 0
  fi
  local proto
  proto="$(proto_menu_pick_to_value "${p}")"
  if [[ -z "${proto}" ]]; then
    warn "Protocol tidak valid"
    pause
    return 0
  fi

  local page=0
  local username="" selected_file="" selected_quota_file=""
  while true; do
    title
    echo "Xray Users > Delete User"
    hr
    echo "Protocol terpilih: ${proto}"
    echo "Daftar akun ${proto} (10 per halaman):"
    hr
    account_collect_files "${proto}"
    ACCOUNT_PAGE="${page}"
    if (( ${#ACCOUNT_FILES[@]} > 0 )); then
      account_print_table_page "${ACCOUNT_PAGE}" "${proto}"
    else
      echo "  (Belum ada akun ${proto} terkelola)"
      echo
      echo "Halaman: 0/0  | Total akun: 0"
      hr
      echo "Ketik: kembali"
      if ! read -r -p "Pilihan: " nav; then
        echo
        return 0
      fi
      return 0
    fi
    hr
    echo "Ketik NO akun, atau: next / previous / kembali"
    local nav=""
    if ! read -r -p "Pilihan: " nav; then
      echo
      return 0
    fi
    if is_back_choice "${nav}"; then
      return 0
    fi
    case "${nav}" in
      next|n)
        local pages
        pages="$(account_total_pages)"
        if (( pages > 0 && page < pages - 1 )); then page=$((page + 1)); fi
        continue
        ;;
      previous|p|prev)
        if (( page > 0 )); then page=$((page - 1)); fi
        continue
        ;;
    esac

    if [[ ! "${nav}" =~ ^[0-9]+$ ]]; then
      invalid_choice
      continue
    fi

    local total pages start end rows idx
    total="${#ACCOUNT_FILES[@]}"
    pages=$(( (total + ACCOUNT_PAGE_SIZE - 1) / ACCOUNT_PAGE_SIZE ))
    if (( page < 0 )); then page=0; fi
    if (( pages > 0 && page >= pages )); then page=$((pages - 1)); fi
    start=$((page * ACCOUNT_PAGE_SIZE))
    end=$((start + ACCOUNT_PAGE_SIZE))
    if (( end > total )); then end="${total}"; fi
    rows=$((end - start))

    if (( nav < 1 || nav > rows )); then
      warn "NO di luar range"
      pause
      continue
    fi

    idx=$((start + nav - 1))
    selected_file="${ACCOUNT_FILES[$idx]}"
    username="$(account_parse_username_from_file "${selected_file}" "${proto}")"
    selected_quota_file="${QUOTA_ROOT}/${proto}/${username}@${proto}.json"

    title
    echo "Xray Users > Delete User"
    hr
    echo "Protocol : ${proto}"
    echo "Username : ${username}"
    echo "Account  : ${selected_file}"
    echo "Quota    : ${selected_quota_file}"
    hr

    local confirm_rc=0
    if confirm_yn_or_back "Hapus user ini?"; then
      break
    else
      confirm_rc=$?
      if (( confirm_rc == 2 )); then
        return 0
      fi
      continue
    fi
  done

  hr
  user_data_mutation_run_locked user_del_apply_locked "${proto}" "${username}" "${selected_file}"
}





user_extend_expiry_menu() {
  local page=0
  local selected_file="" selected_proto="" username="" proto=""
  while true; do
    title
    echo "Xray Users > Set Expiry"
    hr
    echo "Daftar akun (10 per halaman):"
    hr
    account_collect_files
    ACCOUNT_PAGE="${page}"
    account_print_table_page "${ACCOUNT_PAGE}"
    hr
    echo "Ketik NO akun untuk pilih langsung, atau: lanjut / next / previous / kembali"
    if ! read -r -p "Pilihan: " nav; then
      echo
      return 0
    fi
    if is_back_choice "${nav}"; then
      return 0
    fi
    case "${nav}" in
      lanjut|lanjutkan|l) break ;;
      next|n)
        local pages
        pages="$(account_total_pages)"
        if (( pages > 0 && page < pages - 1 )); then page=$((page + 1)); fi
        ;;
      previous|p|prev)
        if (( page > 0 )); then page=$((page - 1)); fi
        ;;
      *)
        if [[ ! "${nav}" =~ ^[0-9]+$ ]]; then
          invalid_choice
          continue
        fi

        local total pages start end rows idx
        total="${#ACCOUNT_FILES[@]}"
        pages=$(( (total + ACCOUNT_PAGE_SIZE - 1) / ACCOUNT_PAGE_SIZE ))
        if (( page < 0 )); then page=0; fi
        if (( pages > 0 && page >= pages )); then page=$((pages - 1)); fi
        start=$((page * ACCOUNT_PAGE_SIZE))
        end=$((start + ACCOUNT_PAGE_SIZE))
        if (( end > total )); then end="${total}"; fi
        rows=$((end - start))

        if (( nav < 1 || nav > rows )); then
          warn "NO di luar range"
          pause
          continue
        fi

        idx=$((start + nav - 1))
        selected_file="${ACCOUNT_FILES[$idx]}"
        selected_proto="${ACCOUNT_FILE_PROTOS[$idx]}"
        username="$(account_parse_username_from_file "${selected_file}" "${selected_proto}")"
        proto="${selected_proto}"
        break
        ;;
    esac
  done

  title
  echo "Xray Users > Set Expiry"
  hr

  ensure_account_quota_dirs
  need_python3

  local quota_file acc_file
  if [[ -n "${selected_file}" ]]; then
    acc_file="${selected_file}"
    quota_file="${QUOTA_ROOT}/${proto}/${username}@${proto}.json"
    echo "Akun terpilih langsung dari tabel:"
    echo "  Protocol : ${proto}"
    echo "  Username : ${username}"
    hr
  else
    echo "Pilih protocol:"
    proto_list_menu_print
    hr
    if ! read -r -p "Protocol (1-3/kembali): " p; then
      echo
      return 0
    fi
    if is_back_choice "${p}"; then
      return 0
    fi
    proto="$(proto_menu_pick_to_value "${p}")"
    if [[ -z "${proto}" ]]; then
      warn "Protocol tidak valid"
      pause
      return 0
    fi

    if ! read -r -p "Username (atau kembali): " username; then
      echo
      return 0
    fi
    if is_back_choice "${username}"; then
      return 0
    fi
    if [[ -z "${username}" ]]; then
      warn "Username kosong"
      pause
      return 0
    fi

    if ! validate_username "${username}"; then
      warn "Username tidak valid. Gunakan: A-Z a-z 0-9 . _ - (tanpa spasi, tanpa '/', tanpa '..', tanpa '@')."
      pause
      return 0
    fi

    quota_file="${QUOTA_ROOT}/${proto}/${username}@${proto}.json"
    acc_file="${ACCOUNT_ROOT}/${proto}/${username}@${proto}.txt"
  fi

  if [[ ! -f "${quota_file}" ]]; then
    warn "Quota file tidak ditemukan: ${quota_file}"
    pause
    return 0
  fi

  # Tampilkan expiry saat ini
  local current_expiry
  current_expiry="$(python3 - <<'PY' "${quota_file}"
import json, sys
p = sys.argv[1]
try:
  d = json.load(open(p, 'r', encoding='utf-8'))
  print(str(d.get("expired_at") or "-"))
except Exception:
  print("-")
PY
)"

  hr
  echo "Username    : ${username}"
  echo "Protocol    : ${proto}"
  echo "Expiry saat ini : ${current_expiry}"
  hr
  echo "  1) Tambah hari (extend)"
  echo "  2) Set tanggal langsung (YYYY-MM-DD)"
  echo "  0) Back"
  hr
  if ! read -r -p "Pilih mode: " mode; then
    echo
    return 0
  fi
  if is_back_choice "${mode}"; then
    return 0
  fi

  local new_expiry=""

  case "${mode}" in
    1)
      if ! read -r -p "Tambah berapa hari? (atau kembali): " add_days; then
        echo
        return 0
      fi
      if is_back_word_choice "${add_days}"; then
        return 0
      fi
      if [[ -z "${add_days}" || ! "${add_days}" =~ ^[0-9]+$ || "${add_days}" -le 0 ]]; then
        warn "Jumlah hari harus angka > 0"
        pause
        return 0
      fi
      # Hitung dari expiry saat ini, jika sudah lewat hitung dari hari ini
      new_expiry="$(python3 - <<'PY' "${current_expiry}" "${add_days}"
import sys
from datetime import datetime, timedelta
exp_str = sys.argv[1].strip()
add = int(sys.argv[2])
today = datetime.now().date()
try:
  base = datetime.fromisoformat(exp_str[:10]).date()
  # Jika sudah expired, mulai dari hari ini
  if base < today:
    base = today
except Exception:
  base = today
result = base + timedelta(days=add)
print(result.strftime('%Y-%m-%d'))
PY
)"
      ;;
    2)
      if ! read -r -p "Tanggal expiry baru (YYYY-MM-DD) (atau kembali): " input_date; then
        echo
        return 0
      fi
      if is_back_choice "${input_date}"; then
        return 0
      fi
      # Validasi format tanggal
      if ! python3 - <<'PY' "${input_date}" 2>/dev/null; then
import sys
from datetime import datetime
s = sys.argv[1].strip()
try:
  datetime.strptime(s, '%Y-%m-%d')
  print(s)
except Exception:
  raise SystemExit(1)
PY
        warn "Format tanggal tidak valid. Gunakan: YYYY-MM-DD"
        pause
        return 0
      fi
      new_expiry="$(python3 - <<'PY' "${input_date}"
import sys
from datetime import datetime
s = sys.argv[1].strip()
datetime.strptime(s, '%Y-%m-%d')
print(s)
PY
)"
      ;;
    0|kembali|k|back|b)
      return 0
      ;;
    *)
      warn "Pilihan tidak valid"
      pause
      return 0
      ;;
  esac

  if [[ -z "${new_expiry}" ]]; then
    warn "Gagal menghitung tanggal baru"
    pause
    return 0
  fi

  if date_ymd_is_past "${new_expiry}"; then
    warn "Tanggal expiry ${new_expiry} sudah lewat dan akan membuat akun segera expired."
    if ! confirm_menu_apply_now "Tetap terapkan expiry lampau ${new_expiry} untuk ${username}@${proto}?"; then
      pause
      return 0
    fi
  fi

  hr
  echo "Ringkasan perubahan:"
  echo "  Username  : ${username}@${proto}"
  echo "  Expiry sebelumnya : ${current_expiry}"
  echo "  Expiry baru : ${new_expiry}"
  hr
  local confirm_rc=0
  if confirm_yn_or_back "Konfirmasi simpan?"; then
    :
  else
    confirm_rc=$?
    if (( confirm_rc == 2 )); then
      warn "Dibatalkan (kembali)."
      pause
      return 0
    fi
    warn "Dibatalkan."
    pause
    return 0
  fi

  user_data_mutation_run_locked user_extend_expiry_apply_locked "${proto}" "${username}" "${quota_file}" "${acc_file}" "${current_expiry}" "${new_expiry}"
}

user_reset_credential_menu() {
  ensure_account_quota_dirs
  need_python3

  title
  echo "Xray Users > Reset UUID/Password"
  hr
  echo "Pilih protocol:"
  proto_list_menu_print
  hr
  if ! read -r -p "Protocol (1-3/kembali): " p; then
    echo
    return 0
  fi
  if is_back_choice "${p}"; then
    return 0
  fi
  local proto
  proto="$(proto_menu_pick_to_value "${p}")"
  if [[ -z "${proto}" ]]; then
    warn "Protocol tidak valid"
    pause
    return 0
  fi

  local page=0
  local username="" selected_file="" selected_quota_file=""
  while true; do
    title
    echo "Xray Users > Reset UUID/Password"
    hr
    echo "Protocol terpilih: ${proto}"
    echo "Daftar akun ${proto} (10 per halaman):"
    hr
    account_collect_files "${proto}"
    ACCOUNT_PAGE="${page}"
    if (( ${#ACCOUNT_FILES[@]} > 0 )); then
      account_print_table_page "${ACCOUNT_PAGE}" "${proto}"
    else
      echo "  (Belum ada akun ${proto} terkelola)"
      echo
      echo "Halaman: 0/0  | Total akun: 0"
      hr
      echo "Ketik: kembali"
      if ! read -r -p "Pilihan: " nav; then
        echo
        return 0
      fi
      return 0
    fi
    hr
    echo "Ketik NO akun, atau: next / previous / kembali"
    local nav=""
    if ! read -r -p "Pilihan: " nav; then
      echo
      return 0
    fi
    if is_back_choice "${nav}"; then
      return 0
    fi
    case "${nav}" in
      next|n)
        local pages
        pages="$(account_total_pages)"
        if (( pages > 0 && page < pages - 1 )); then page=$((page + 1)); fi
        continue
        ;;
      previous|p|prev)
        if (( page > 0 )); then page=$((page - 1)); fi
        continue
        ;;
    esac

    if [[ ! "${nav}" =~ ^[0-9]+$ ]]; then
      invalid_choice
      continue
    fi

    local total pages start end rows idx
    total="${#ACCOUNT_FILES[@]}"
    pages=$(( (total + ACCOUNT_PAGE_SIZE - 1) / ACCOUNT_PAGE_SIZE ))
    if (( page < 0 )); then page=0; fi
    if (( pages > 0 && page >= pages )); then page=$((pages - 1)); fi
    start=$((page * ACCOUNT_PAGE_SIZE))
    end=$((start + ACCOUNT_PAGE_SIZE))
    if (( end > total )); then end="${total}"; fi
    rows=$((end - start))

    if (( nav < 1 || nav > rows )); then
      warn "NO di luar range"
      pause
      continue
    fi

    idx=$((start + nav - 1))
    selected_file="${ACCOUNT_FILES[$idx]}"
    username="$(account_parse_username_from_file "${selected_file}" "${proto}")"
    selected_quota_file="${QUOTA_ROOT}/${proto}/${username}@${proto}.json"

    title
    echo "Xray Users > Reset UUID/Password"
    hr
    echo "Protocol : ${proto}"
    echo "Username : ${username}"
    echo "Account  : ${selected_file}"
    echo "Quota    : ${selected_quota_file}"
    hr

    local confirm_rc=0
    if confirm_yn_or_back "Reset UUID/password user ini?"; then
      break
    else
      confirm_rc=$?
      if (( confirm_rc == 2 )); then
        return 0
      fi
      continue
    fi
  done

  user_data_mutation_run_locked user_reset_credential_apply_locked "${proto}" "${username}" "${selected_file}"
}

user_list_menu() {
  ACCOUNT_PAGE=0
  while true; do
    title
    echo "Xray Users > List Users"
    hr

    account_collect_files
    account_print_table_page "${ACCOUNT_PAGE}"
    hr

    echo "  view) View file detail"
    echo "  search) Search"
    echo "  next) Next page"
    echo "  previous) Previous page"
    echo "  refresh) Refresh"
    hr
    if ! read -r -p "Pilih (view/search/next/previous/refresh/kembali): " c; then
      echo
      break
    fi

    if is_back_choice "${c}"; then
      break
    fi

    case "${c}" in
      view|1) account_view_flow ;;
      search|2) account_search_flow ;;
      next|n)
        local pages
        pages="$(account_total_pages)"
        if (( pages > 0 && ACCOUNT_PAGE < pages - 1 )); then
          ACCOUNT_PAGE=$((ACCOUNT_PAGE + 1))
        fi
        ;;
      previous|p|prev)
        if (( ACCOUNT_PAGE > 0 )); then
          ACCOUNT_PAGE=$((ACCOUNT_PAGE - 1))
        fi
        ;;
      refresh|3) : ;;
      *) invalid_choice ;;
    esac
  done
}

user_menu() {
  local pending_count=0
  local -a items=(
    "1|Add User"
    "2|Delete User"
    "3|Set Expiry"
    "4|Reset UUID/Password"
    "5|List Users"
    "6|Recover Pending Txn"
    "0|Back"
  )
  while true; do
    pending_count="$(xray_pending_recovery_count)"
    [[ "${pending_count}" =~ ^[0-9]+$ ]] || pending_count=0
    ui_menu_screen_begin "1) Xray Users"
    if (( pending_count > 0 )); then
      warn "Ada ${pending_count} journal recovery Xray tertunda. Gunakan 'Recover Pending Txn' bila ingin melanjutkannya."
      hr
    fi
    ui_menu_render_options items 76
    hr
    if ! read -r -p "Pilih: " c; then
      echo
      break
    fi
    case "${c}" in
      1)
        if (( pending_count > 0 )); then
          warn "Mutasi Xray baru ditahan sampai journal recovery tertunda diselesaikan."
          pause
        else
          menu_run_isolated_report "Add Xray User" user_add_menu
        fi
        ;;
      2)
        if (( pending_count > 0 )); then
          warn "Mutasi Xray baru ditahan sampai journal recovery tertunda diselesaikan."
          pause
        else
          menu_run_isolated_report "Delete Xray User" user_del_menu
        fi
        ;;
      3)
        if (( pending_count > 0 )); then
          warn "Mutasi Xray baru ditahan sampai journal recovery tertunda diselesaikan."
          pause
        else
          menu_run_isolated_report "Set Xray Expiry" user_extend_expiry_menu
        fi
        ;;
      4)
        if (( pending_count > 0 )); then
          warn "Mutasi Xray baru ditahan sampai journal recovery tertunda diselesaikan."
          pause
        else
          menu_run_isolated_report "Reset Xray Credential" user_reset_credential_menu
        fi
        ;;
      5) user_list_menu ;;
      6) menu_run_isolated_report "Recover Pending Xray Txn" xray_recover_pending_txn_menu ;;
      0|kembali|k|back|b) break ;;
      *) invalid_choice ;;
    esac
  done
}

# -------------------------
# Quota & Access Control
# - Sumber metadata: /opt/quota/(vless|vmess|trojan)/*.json
# - Perubahan JSON menggunakan atomic write (tmp + replace) untuk menghindari file korup
# -------------------------
QUOTA_FILES=()
QUOTA_FILE_PROTOS=()
QUOTA_PAGE_SIZE=10
QUOTA_PAGE=0
QUOTA_QUERY=""
QUOTA_VIEW_INDEXES=()
