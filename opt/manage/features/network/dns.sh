#!/usr/bin/env bash
# shellcheck shell=bash

# -------------------------
# DNS Settings
# -------------------------
dns_server_literal_normalize() {
  local raw="${1:-}"
  raw="$(printf '%s' "${raw}" | tr -d '[:space:]')"
  [[ -n "${raw}" ]] || return 1
  need_python3
  python3 - <<'PY' "${raw}"
import ipaddress
import sys

value = str(sys.argv[1]).strip()
try:
    addr = ipaddress.ip_address(value)
except Exception:
    raise SystemExit(1)
print(addr.compressed)
PY
}

xray_dns_status_get() {
  # output:
  # parse_state=ok|missing|invalid
  # error=<...>
  # primary=<...>
  # secondary=<...>
  # strategy=<...>
  # cache=on|off
  local src_file="${1:-${XRAY_DNS_CONF}}"
  need_python3

  if [[ ! -f "${src_file}" ]]; then
    echo "parse_state=missing"
    echo "error="
    echo "primary="
    echo "secondary="
    echo "strategy="
    echo "cache=on"
    return 0
  fi

  python3 - <<'PY' "${src_file}" 2>/dev/null || true
import json, sys

def strip_json_comments(text):
  out = []
  i = 0
  n = len(text)
  in_str = False
  quote = ""
  escape = False
  while i < n:
    ch = text[i]
    nxt = text[i + 1] if i + 1 < n else ""
    if in_str:
      out.append(ch)
      if escape:
        escape = False
      elif ch == "\\":
        escape = True
      elif ch == quote:
        in_str = False
      i += 1
      continue
    if ch in ('"', "'"):
      in_str = True
      quote = ch
      out.append(ch)
      i += 1
      continue
    if ch == "/" and nxt == "/":
      i += 2
      while i < n and text[i] not in "\r\n":
        i += 1
      continue
    if ch == "/" and nxt == "*":
      i += 2
      while i + 1 < n and not (text[i] == "*" and text[i + 1] == "/"):
        i += 1
      i += 2
      continue
    out.append(ch)
    i += 1
  return "".join(out)

def load_jsonc(path):
  with open(path, "r", encoding="utf-8") as f:
    return json.loads(strip_json_comments(f.read()))

src=sys.argv[1]
try:
  cfg=load_jsonc(src)
except Exception:
  print('parse_state=invalid')
  print('error=JSON DNS invalid atau tidak bisa dibaca')
  print('primary=')
  print('secondary=')
  print('strategy=')
  print('cache=on')
  raise SystemExit(0)

dns=cfg.get('dns') or {}
if not isinstance(dns, dict):
  dns={}

servers=dns.get('servers') or []
if not isinstance(servers, list):
  servers=[]

def server_addr(s):
  if isinstance(s, str):
    return s
  if isinstance(s, dict):
    a=s.get('address')
    if isinstance(a, str):
      return a
  return ''

primary=server_addr(servers[0]) if len(servers) > 0 else ''
secondary=server_addr(servers[1]) if len(servers) > 1 else ''

qs=dns.get('queryStrategy')
strategy=qs if isinstance(qs, str) else ''

disable_cache=dns.get('disableCache')
cache='off' if bool(disable_cache) else 'on'

print('parse_state=ok')
print('error=')
print('primary=' + primary)
print('secondary=' + secondary)
print('strategy=' + strategy)
print('cache=' + cache)
PY
}

xray_dns_candidate_prepare() {
  local -n _out_ref="$1"
  if [[ -n "${_out_ref}" && -f "${_out_ref}" ]]; then
    return 0
  fi
  _out_ref="$(mktemp "${WORK_DIR}/dns-stage.XXXXXX.json" 2>/dev/null || true)"
  [[ -n "${_out_ref}" ]] || return 1
  if [[ -f "${XRAY_DNS_CONF}" ]]; then
    need_python3
    if ! python3 - <<'PY' "${XRAY_DNS_CONF}" "${_out_ref}"
import json, sys

def strip_json_comments(text):
  out = []
  i = 0
  n = len(text)
  in_str = False
  quote = ""
  escape = False
  while i < n:
    ch = text[i]
    nxt = text[i + 1] if i + 1 < n else ""
    if in_str:
      out.append(ch)
      if escape:
        escape = False
      elif ch == "\\":
        escape = True
      elif ch == quote:
        in_str = False
      i += 1
      continue
    if ch in ('"', "'"):
      in_str = True
      quote = ch
      out.append(ch)
      i += 1
      continue
    if ch == "/" and nxt == "/":
      i += 2
      while i < n and text[i] not in "\r\n":
        i += 1
      continue
    if ch == "/" and nxt == "*":
      i += 2
      while i + 1 < n and not (text[i] == "*" and text[i + 1] == "/"):
        i += 1
      i += 2
      continue
    out.append(ch)
    i += 1
  return "".join(out)

src, dst = sys.argv[1:3]
with open(src, "r", encoding="utf-8") as f:
  cfg = json.loads(strip_json_comments(f.read()))
with open(dst, "w", encoding="utf-8") as f:
  json.dump(cfg, f, ensure_ascii=False, indent=2)
  f.write("\n")
PY
    then
      rm -f -- "${_out_ref}" >/dev/null 2>&1 || true
      _out_ref=""
      return 1
    fi
  else
    printf '{\n  "dns": {}\n}\n' > "${_out_ref}" || {
      rm -f -- "${_out_ref}" >/dev/null 2>&1 || true
      _out_ref=""
      return 1
    }
  fi
  if ! xray_stage_origin_capture "${_out_ref}" "${XRAY_DNS_CONF}"; then
    xray_stage_candidate_cleanup "${_out_ref}"
    _out_ref=""
    return 1
  fi
  chmod 600 "${_out_ref}" >/dev/null 2>&1 || true
  return 0
}

xray_dns_mutate_candidate_file() {
  # args: candidate_file action [value]
  local candidate="$1"
  local action="$2"
  local value="${3:-}"
  need_python3
  [[ -n "${candidate}" ]] || return 1
  python3 - <<'PY' "${candidate}" "${action}" "${value}" || return 1
import json
import os
import sys
import tempfile

def strip_json_comments(text):
  out = []
  i = 0
  n = len(text)
  in_str = False
  quote = ""
  escape = False
  while i < n:
    ch = text[i]
    nxt = text[i + 1] if i + 1 < n else ""
    if in_str:
      out.append(ch)
      if escape:
        escape = False
      elif ch == "\\":
        escape = True
      elif ch == quote:
        in_str = False
      i += 1
      continue
    if ch in ('"', "'"):
      in_str = True
      quote = ch
      out.append(ch)
      i += 1
      continue
    if ch == "/" and nxt == "/":
      i += 2
      while i < n and text[i] not in "\r\n":
        i += 1
      continue
    if ch == "/" and nxt == "*":
      i += 2
      while i + 1 < n and not (text[i] == "*" and text[i + 1] == "/"):
        i += 1
      i += 2
      continue
    out.append(ch)
    i += 1
  return "".join(out)

path, action, value = sys.argv[1:4]
action = str(action or "").strip()
value = str(value or "").strip()

if os.path.isfile(path):
  try:
    with open(path, "r", encoding="utf-8") as f:
      cfg = json.loads(strip_json_comments(f.read()))
  except Exception as exc:
    raise SystemExit(f"Config DNS tidak valid: {exc}")
else:
  cfg = {}
if not isinstance(cfg, dict):
  raise SystemExit("Config DNS tidak valid: root JSON bukan object")

dns = cfg.get("dns")
if not isinstance(dns, dict):
  dns = {}
servers = dns.get("servers")
if not isinstance(servers, list):
  servers = []

def set_server(idx, server_value):
  while len(servers) <= idx:
    servers.append("")
  if isinstance(servers[idx], dict):
    servers[idx]["address"] = server_value
  else:
    servers[idx] = server_value

def server_addr(entry):
  if isinstance(entry, str):
    return entry.strip()
  if isinstance(entry, dict):
    addr = entry.get("address")
    if isinstance(addr, str):
      return addr.strip()
  return ""

if action == "set_primary":
  if value:
    set_server(0, value)
elif action == "set_secondary":
  primary = server_addr(servers[0]) if len(servers) > 0 else ""
  if not primary:
    raise SystemExit("Primary DNS belum diset. Set Primary DNS dulu sebelum Secondary DNS.")
  if value:
    set_server(1, value)
elif action == "set_query_strategy":
  if value.lower() in {"off", "clear", "none", "-", "default"}:
    dns.pop("queryStrategy", None)
  elif value:
    dns["queryStrategy"] = value
elif action == "toggle_cache":
  dns["disableCache"] = not bool(dns.get("disableCache"))
else:
  raise SystemExit(f"aksi DNS tidak dikenali: {action}")

dns["servers"] = servers
cfg["dns"] = dns

dirn = os.path.dirname(path) or "."
fd, tmp = tempfile.mkstemp(prefix=".tmp.", suffix=".json", dir=dirn)
try:
  with os.fdopen(fd, "w", encoding="utf-8") as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
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
PY
}

xray_dns_apply_candidate_file() {
  local candidate="$1"
  local tmp backup rc
  [[ -f "${candidate}" ]] || return 1
  need_python3
  backup="$(xray_backup_path_prepare "${XRAY_DNS_CONF}")"
  tmp="${WORK_DIR}/02-dns.json.tmp"

  xray_dns_lock_prepare
  set +e
  (
    flock -x 200
    xray_stage_origin_verify_live "${candidate}" "${XRAY_DNS_CONF}" "DNS Xray" || exit 89
    xray_dns_conf_bootstrap_locked || exit 1
    ensure_path_writable "${XRAY_DNS_CONF}"
    cp -a "${XRAY_DNS_CONF}" "${backup}" || exit 1
    cp -a "${candidate}" "${tmp}" || exit 1
    xray_write_file_atomic "${XRAY_DNS_CONF}" "${tmp}" || {
      restore_file_if_exists "${backup}" "${XRAY_DNS_CONF}"
      exit 1
    }
    if ! xray_routing_restart_checked; then
      if ! restore_file_if_exists "${backup}" "${XRAY_DNS_CONF}"; then
        exit 1
      fi
      xray_routing_restart_checked || exit 1
      exit 86
    fi
  ) 200>"${DNS_LOCK_FILE}"
  rc=$?
  set -e

  if (( rc == 89 )); then
    warn "Apply staged DNS dibatalkan karena file live berubah sejak staging dibuat."
    return 1
  fi
  xray_txn_rc_or_die "${rc}" \
    "Gagal apply staged DNS settings (rollback ke backup: ${backup})" \
    "xray tidak aktif setelah apply staged DNS settings. Config di-rollback ke backup: ${backup}"
  return 0
}

xray_dns_set_primary() {
  local val="$1"
  local tmp backup rc

  need_python3
  backup="$(xray_backup_path_prepare "${XRAY_DNS_CONF}")"
  tmp="${WORK_DIR}/02-dns.json.tmp"

  xray_dns_lock_prepare
  set +e
  (
    flock -x 200
    xray_dns_conf_bootstrap_locked || exit 1
    ensure_path_writable "${XRAY_DNS_CONF}"
    cp -a "${XRAY_DNS_CONF}" "${backup}" || exit 1
    python3 - <<'PY' "${XRAY_DNS_CONF}" "${tmp}" "${val}"
import json, sys

def strip_json_comments(text):
  out = []
  i = 0
  n = len(text)
  in_str = False
  quote = ""
  escape = False
  while i < n:
    ch = text[i]
    nxt = text[i + 1] if i + 1 < n else ""
    if in_str:
      out.append(ch)
      if escape:
        escape = False
      elif ch == "\\":
        escape = True
      elif ch == quote:
        in_str = False
      i += 1
      continue
    if ch in ('"', "'"):
      in_str = True
      quote = ch
      out.append(ch)
      i += 1
      continue
    if ch == "/" and nxt == "/":
      i += 2
      while i < n and text[i] not in "\r\n":
        i += 1
      continue
    if ch == "/" and nxt == "*":
      i += 2
      while i + 1 < n and not (text[i] == "*" and text[i + 1] == "/"):
        i += 1
      i += 2
      continue
    out.append(ch)
    i += 1
  return "".join(out)

src, dst, val = sys.argv[1:4]
val=str(val).strip()

try:
  with open(src,'r',encoding='utf-8') as f:
    cfg=json.loads(strip_json_comments(f.read()))
except Exception as exc:
  raise SystemExit(f"Config DNS tidak valid: {exc}")

if not isinstance(cfg, dict):
  raise SystemExit("Config DNS tidak valid: root JSON bukan object")

dns=cfg.get('dns')
if not isinstance(dns, dict):
  dns={}

servers=dns.get('servers')
if not isinstance(servers, list):
  servers=[]

def set_server(idx, v):
  while len(servers) <= idx:
    servers.append("")
  if isinstance(servers[idx], dict):
    servers[idx]['address']=v
  else:
    servers[idx]=v

if val:
  set_server(0, val)

dns['servers']=servers
cfg['dns']=dns

with open(dst,'w',encoding='utf-8') as f:
  json.dump(cfg,f,ensure_ascii=False,indent=2)
  f.write("\n")
PY
    xray_write_file_atomic "${XRAY_DNS_CONF}" "${tmp}" || {
      restore_file_if_exists "${backup}" "${XRAY_DNS_CONF}"
      exit 1
    }
    if ! xray_routing_restart_checked; then
      if ! restore_file_if_exists "${backup}" "${XRAY_DNS_CONF}"; then
        exit 1
      fi
      xray_routing_restart_checked || exit 1
      exit 86
    fi
  ) 200>"${DNS_LOCK_FILE}"
  rc=$?
  set -e

  xray_txn_rc_or_die "${rc}" \
    "Gagal update Primary DNS (rollback ke backup: ${backup})" \
    "xray tidak aktif setelah update dns primary. Config di-rollback ke backup: ${backup}"
  return 0
}

xray_dns_set_secondary() {
  local val="$1"
  local tmp backup rc

  need_python3
  backup="$(xray_backup_path_prepare "${XRAY_DNS_CONF}")"
  tmp="${WORK_DIR}/02-dns.json.tmp"

  xray_dns_lock_prepare
  set +e
  (
    flock -x 200
    xray_dns_conf_bootstrap_locked || exit 1
    ensure_path_writable "${XRAY_DNS_CONF}"
    cp -a "${XRAY_DNS_CONF}" "${backup}" || exit 1
    python3 - <<'PY' "${XRAY_DNS_CONF}" "${tmp}" "${val}"
import json, sys

def strip_json_comments(text):
  out = []
  i = 0
  n = len(text)
  in_str = False
  quote = ""
  escape = False
  while i < n:
    ch = text[i]
    nxt = text[i + 1] if i + 1 < n else ""
    if in_str:
      out.append(ch)
      if escape:
        escape = False
      elif ch == "\\":
        escape = True
      elif ch == quote:
        in_str = False
      i += 1
      continue
    if ch in ('"', "'"):
      in_str = True
      quote = ch
      out.append(ch)
      i += 1
      continue
    if ch == "/" and nxt == "/":
      i += 2
      while i < n and text[i] not in "\r\n":
        i += 1
      continue
    if ch == "/" and nxt == "*":
      i += 2
      while i + 1 < n and not (text[i] == "*" and text[i + 1] == "/"):
        i += 1
      i += 2
      continue
    out.append(ch)
    i += 1
  return "".join(out)

src, dst, val = sys.argv[1:4]
val=str(val).strip()

try:
  with open(src,'r',encoding='utf-8') as f:
    cfg=json.loads(strip_json_comments(f.read()))
except Exception as exc:
  raise SystemExit(f"Config DNS tidak valid: {exc}")

if not isinstance(cfg, dict):
  raise SystemExit("Config DNS tidak valid: root JSON bukan object")

dns=cfg.get('dns')
if not isinstance(dns, dict):
  dns={}

servers=dns.get('servers')
if not isinstance(servers, list):
  servers=[]

def server_addr(value):
  if isinstance(value, str):
    return value.strip()
  if isinstance(value, dict):
    addr = value.get('address')
    if isinstance(addr, str):
      return addr.strip()
  return ""

def set_server(idx, v):
  while len(servers) <= idx:
    servers.append("")
  if isinstance(servers[idx], dict):
    servers[idx]['address']=v
  else:
    servers[idx]=v

if val:
  primary = server_addr(servers[0]) if len(servers) > 0 else ""
  if not primary:
    raise SystemExit("Primary DNS belum diset. Set Primary DNS dulu sebelum Secondary DNS.")
  set_server(1, val)

dns['servers']=servers
cfg['dns']=dns

with open(dst,'w',encoding='utf-8') as f:
  json.dump(cfg,f,ensure_ascii=False,indent=2)
  f.write("\n")
PY
    xray_write_file_atomic "${XRAY_DNS_CONF}" "${tmp}" || {
      restore_file_if_exists "${backup}" "${XRAY_DNS_CONF}"
      exit 1
    }
    if ! xray_routing_restart_checked; then
      if ! restore_file_if_exists "${backup}" "${XRAY_DNS_CONF}"; then
        exit 1
      fi
      xray_routing_restart_checked || exit 1
      exit 86
    fi
  ) 200>"${DNS_LOCK_FILE}"
  rc=$?
  set -e

  xray_txn_rc_or_die "${rc}" \
    "Gagal update Secondary DNS (rollback ke backup: ${backup})" \
    "xray tidak aktif setelah update dns secondary. Config di-rollback ke backup: ${backup}"
  return 0
}

xray_dns_set_query_strategy() {
  local val="$1"
  local tmp backup rc

  need_python3
  backup="$(xray_backup_path_prepare "${XRAY_DNS_CONF}")"
  tmp="${WORK_DIR}/02-dns.json.tmp"

  xray_dns_lock_prepare
  set +e
  (
    flock -x 200
    xray_dns_conf_bootstrap_locked || exit 1
    ensure_path_writable "${XRAY_DNS_CONF}"
    cp -a "${XRAY_DNS_CONF}" "${backup}" || exit 1
    python3 - <<'PY' "${XRAY_DNS_CONF}" "${tmp}" "${val}"
import json, sys

def strip_json_comments(text):
  out = []
  i = 0
  n = len(text)
  in_str = False
  quote = ""
  escape = False
  while i < n:
    ch = text[i]
    nxt = text[i + 1] if i + 1 < n else ""
    if in_str:
      out.append(ch)
      if escape:
        escape = False
      elif ch == "\\":
        escape = True
      elif ch == quote:
        in_str = False
      i += 1
      continue
    if ch in ('"', "'"):
      in_str = True
      quote = ch
      out.append(ch)
      i += 1
      continue
    if ch == "/" and nxt == "/":
      i += 2
      while i < n and text[i] not in "\r\n":
        i += 1
      continue
    if ch == "/" and nxt == "*":
      i += 2
      while i + 1 < n and not (text[i] == "*" and text[i + 1] == "/"):
        i += 1
      i += 2
      continue
    out.append(ch)
    i += 1
  return "".join(out)

src, dst, val = sys.argv[1:4]
val=str(val).strip()

try:
  with open(src,'r',encoding='utf-8') as f:
    cfg=json.loads(strip_json_comments(f.read()))
except Exception as exc:
  raise SystemExit(f"Config DNS tidak valid: {exc}")

if not isinstance(cfg, dict):
  raise SystemExit("Config DNS tidak valid: root JSON bukan object")

dns=cfg.get('dns')
if not isinstance(dns, dict):
  dns={}

if val.lower() in {"off", "clear", "none", "-", "default"}:
  dns.pop('queryStrategy', None)
elif val:
  dns['queryStrategy']=val

cfg['dns']=dns
with open(dst,'w',encoding='utf-8') as f:
  json.dump(cfg,f,ensure_ascii=False,indent=2)
  f.write("\n")
PY
    xray_write_file_atomic "${XRAY_DNS_CONF}" "${tmp}" || {
      restore_file_if_exists "${backup}" "${XRAY_DNS_CONF}"
      exit 1
    }
    if ! xray_routing_restart_checked; then
      if ! restore_file_if_exists "${backup}" "${XRAY_DNS_CONF}"; then
        exit 1
      fi
      xray_routing_restart_checked || exit 1
      exit 86
    fi
  ) 200>"${DNS_LOCK_FILE}"
  rc=$?
  set -e

  xray_txn_rc_or_die "${rc}" \
    "Gagal update Query Strategy (rollback ke backup: ${backup})" \
    "xray tidak aktif setelah update dns queryStrategy. Config di-rollback ke backup: ${backup}"
  return 0
}

xray_dns_toggle_cache() {
  local tmp backup rc
  need_python3
  backup="$(xray_backup_path_prepare "${XRAY_DNS_CONF}")"
  tmp="${WORK_DIR}/02-dns.json.tmp"

  xray_dns_lock_prepare
  set +e
  (
    flock -x 200
    xray_dns_conf_bootstrap_locked || exit 1
    ensure_path_writable "${XRAY_DNS_CONF}"
    cp -a "${XRAY_DNS_CONF}" "${backup}" || exit 1
    python3 - <<'PY' "${XRAY_DNS_CONF}" "${tmp}"
import json, sys

def strip_json_comments(text):
  out = []
  i = 0
  n = len(text)
  in_str = False
  quote = ""
  escape = False
  while i < n:
    ch = text[i]
    nxt = text[i + 1] if i + 1 < n else ""
    if in_str:
      out.append(ch)
      if escape:
        escape = False
      elif ch == "\\":
        escape = True
      elif ch == quote:
        in_str = False
      i += 1
      continue
    if ch in ('"', "'"):
      in_str = True
      quote = ch
      out.append(ch)
      i += 1
      continue
    if ch == "/" and nxt == "/":
      i += 2
      while i < n and text[i] not in "\r\n":
        i += 1
      continue
    if ch == "/" and nxt == "*":
      i += 2
      while i + 1 < n and not (text[i] == "*" and text[i + 1] == "/"):
        i += 1
      i += 2
      continue
    out.append(ch)
    i += 1
  return "".join(out)

src, dst = sys.argv[1:3]
try:
  with open(src,'r',encoding='utf-8') as f:
    cfg=json.loads(strip_json_comments(f.read()))
except Exception as exc:
  raise SystemExit(f"Config DNS tidak valid: {exc}")

if not isinstance(cfg, dict):
  raise SystemExit("Config DNS tidak valid: root JSON bukan object")

dns=cfg.get('dns')
if not isinstance(dns, dict):
  dns={}

cur=bool(dns.get('disableCache'))
dns['disableCache']=not cur

cfg['dns']=dns
with open(dst,'w',encoding='utf-8') as f:
  json.dump(cfg,f,ensure_ascii=False,indent=2)
  f.write("\n")
PY
    xray_write_file_atomic "${XRAY_DNS_CONF}" "${tmp}" || {
      restore_file_if_exists "${backup}" "${XRAY_DNS_CONF}"
      exit 1
    }
    if ! xray_routing_restart_checked; then
      if ! restore_file_if_exists "${backup}" "${XRAY_DNS_CONF}"; then
        exit 1
      fi
      xray_routing_restart_checked || exit 1
      exit 86
    fi
  ) 200>"${DNS_LOCK_FILE}"
  rc=$?
  set -e

  xray_txn_rc_or_die "${rc}" \
    "Gagal toggle DNS cache (rollback ke backup: ${backup})" \
    "xray tidak aktif setelah update dns cache. Config di-rollback ke backup: ${backup}"
  return 0
}

dns_show_status() {
  local src_file="${1:-${XRAY_DNS_CONF}}"
  local title_label="${2:-DNS Status}"
  local primary secondary strategy cache parse_state status_blob
  status_blob="$(xray_dns_status_get "${src_file}")"
  parse_state="$(printf '%s\n' "${status_blob}" | awk -F'=' '/^parse_state=/{print $2; exit}' 2>/dev/null || true)"
  primary="$(printf '%s\n' "${status_blob}" | awk -F'=' '/^primary=/{print $2; exit}' 2>/dev/null || true)"
  secondary="$(printf '%s\n' "${status_blob}" | awk -F'=' '/^secondary=/{print $2; exit}' 2>/dev/null || true)"
  strategy="$(printf '%s\n' "${status_blob}" | awk -F'=' '/^strategy=/{print $2; exit}' 2>/dev/null || true)"
  cache="$(printf '%s\n' "${status_blob}" | awk -F'=' '/^cache=/{print $2; exit}' 2>/dev/null || true)"

  if [[ "${cache}" == "on" ]]; then
    cache="ON"
  else
    cache="OFF"
  fi

  [[ -n "${primary}" ]] || primary="-"
  [[ -n "${secondary}" ]] || secondary="-"
  [[ -n "${strategy}" ]] || strategy="-"

  title
  echo "${title_label}"
  hr
  echo
  case "${parse_state}" in
    invalid) printf "Parser State    : %s\n" "INVALID JSON" ;;
    missing) printf "Parser State    : %s\n" "MISSING" ;;
    *) printf "Parser State    : %s\n" "OK" ;;
  esac
  printf "Primary DNS     : %s\n" "${primary}"
  printf "Secondary DNS   : %s\n" "${secondary}"
  printf "Query Strategy  : %s\n" "${strategy}"
  printf "Cache           : %s\n" "${cache}"
  echo
  hr
  pause
}

dns_settings_run_mutation() {
  local success_msg="$1"
  shift || true
  local cmd_output=""
  if cmd_output="$( ( "$@" ) 2>&1 )"; then
    log "${success_msg}"
    return 0
  fi
  warn "Operasi DNS gagal."
  if [[ -n "${cmd_output}" ]]; then
    printf '%s\n' "${cmd_output}" >&2
  fi
  return 1
}

dns_addons_diff_report_write() {
  local live_path="${1:-}"
  local candidate_path="${2:-}"
  local outfile="${3:-}"
  [[ -n "${candidate_path}" && -n "${outfile}" ]] || return 1
  need_python3
  python3 - <<'PY' "${live_path}" "${candidate_path}" "${outfile}"
import difflib
import pathlib
import sys

live_raw, cand_raw, out_raw = sys.argv[1:4]
live = pathlib.Path(live_raw) if live_raw else None
cand = pathlib.Path(cand_raw)
out = pathlib.Path(out_raw)

live_text = ""
live_label = live_raw or "(empty)"
if live is not None and live.exists():
  live_text = live.read_text(encoding="utf-8", errors="replace")
else:
  live_label = f"{live_label} (empty)"

cand_text = cand.read_text(encoding="utf-8", errors="replace")
diff = list(difflib.unified_diff(
  live_text.splitlines(True),
  cand_text.splitlines(True),
  fromfile=live_label,
  tofile=str(cand),
))
payload = "".join(diff) if diff else "(tidak ada perubahan)\n"
out.write_text(payload, encoding="utf-8")
PY
}

dns_settings_menu() {
  local dns_candidate=""
  local pending_changes="false"
  local status_source="" status_label="" status_blob="" primary="" secondary="" strategy="" cache="" parse_state=""
  while true; do
    status_source="${dns_candidate:-${XRAY_DNS_CONF}}"
    status_label="LIVE"
    if [[ "${pending_changes}" == "true" && -n "${dns_candidate}" ]]; then
      status_label="STAGED"
    fi
    status_blob="$(xray_dns_status_get "${status_source}")"
    parse_state="$(printf '%s\n' "${status_blob}" | awk -F'=' '/^parse_state=/{print $2; exit}' 2>/dev/null || true)"
    primary="$(printf '%s\n' "${status_blob}" | awk -F'=' '/^primary=/{print $2; exit}' 2>/dev/null || true)"
    secondary="$(printf '%s\n' "${status_blob}" | awk -F'=' '/^secondary=/{print $2; exit}' 2>/dev/null || true)"
    strategy="$(printf '%s\n' "${status_blob}" | awk -F'=' '/^strategy=/{print $2; exit}' 2>/dev/null || true)"
    cache="$(printf '%s\n' "${status_blob}" | awk -F'=' '/^cache=/{print $2; exit}' 2>/dev/null || true)"
    [[ -n "${primary}" ]] || primary="-"
    [[ -n "${secondary}" ]] || secondary="-"
    [[ -n "${strategy}" ]] || strategy="-"
    [[ -n "${cache}" ]] || cache="on"

    title
    echo "$(xray_network_menu_title "DNS Settings")"
    hr
    echo "Source status : ${status_label}"
    case "${parse_state}" in
      invalid) echo "Parser state  : INVALID JSON" ;;
      missing) echo "Parser state  : MISSING (akan bootstrap saat apply)" ;;
      *) echo "Parser state  : OK" ;;
    esac
    echo "Primary DNS   : ${primary}"
    echo "Secondary DNS : ${secondary}"
    echo "QueryStrategy : ${strategy}"
    echo "DNS Cache     : $( [[ "${cache}" == "on" ]] && echo ON || echo OFF )"
    if [[ "${parse_state}" == "invalid" ]]; then
      warn "DNS Settings diblok sampai JSON DNS valid kembali. Gunakan DNS Editor atau Checks untuk memperbaiki file."
    fi
    hr
    echo "  1) Set Primary DNS"
    echo "  2) Set Secondary DNS"
    echo "  3) Set Query Strategy"
    echo "  4) Toggle DNS Cache"
    if [[ "${pending_changes}" == "true" ]]; then
      echo "  5) Apply staged DNS changes"
      echo "  6) Discard staged DNS changes"
      echo "  7) Show staged DNS status"
    else
      echo "  5) Show DNS Status"
    fi
    echo "  0) Back"
    hr
    read -r -p "Pilih: " c
    case "${c}" in
      1)
        if [[ "${parse_state}" == "invalid" ]]; then
          pause
          continue
        fi
        read -r -p "Primary DNS (contoh 1.1.1.1) (atau kembali): " d
        if is_back_choice "${d}"; then
          continue
        fi
        d="$(dns_server_literal_normalize "${d}")" || {
          warn "Primary DNS harus IPv4/IPv6 literal. Untuk upstream advanced gunakan DNS Add-ons > nano."
          pause
          continue
        }
        if ! confirm_yn_or_back "Stage Primary DNS ke ${d} sekarang?"; then
          warn "Stage Primary DNS dibatalkan."
          pause
          continue
        fi
        if ! xray_dns_candidate_prepare dns_candidate; then
          warn "Gagal menyiapkan staging DNS."
          pause
          continue
        fi
        if ! xray_dns_mutate_candidate_file "${dns_candidate}" set_primary "${d}"; then
          warn "Gagal men-stage Primary DNS."
          pause
          continue
        fi
        pending_changes="true"
        log "Primary DNS di-stage: ${d}"
        pause
        ;;
      2)
        if [[ "${parse_state}" == "invalid" ]]; then
          pause
          continue
        fi
        local current_primary=""
        read -r -p "Secondary DNS (contoh 8.8.8.8) (atau kembali): " d
        if is_back_choice "${d}"; then
          continue
        fi
        d="$(dns_server_literal_normalize "${d}")" || {
          warn "Secondary DNS harus IPv4/IPv6 literal. Untuk upstream advanced gunakan DNS Add-ons > nano."
          pause
          continue
        }
        current_primary="$(printf '%s\n' "${status_blob}" | awk -F'=' '/^primary=/{print $2; exit}' 2>/dev/null || true)"
        if [[ -z "${current_primary}" ]]; then
          warn "Primary DNS belum diset. Set Primary DNS dulu sebelum mengisi Secondary DNS."
          pause
          continue
        fi
        if ! confirm_yn_or_back "Stage Secondary DNS ke ${d} sekarang?"; then
          warn "Stage Secondary DNS dibatalkan."
          pause
          continue
        fi
        if ! xray_dns_candidate_prepare dns_candidate; then
          warn "Gagal menyiapkan staging DNS."
          pause
          continue
        fi
        if ! xray_dns_mutate_candidate_file "${dns_candidate}" set_secondary "${d}"; then
          warn "Gagal men-stage Secondary DNS."
          pause
          continue
        fi
        pending_changes="true"
        log "Secondary DNS di-stage: ${d}"
        pause
        ;;
      3)
        if [[ "${parse_state}" == "invalid" ]]; then
          pause
          continue
        fi
        read -r -p "Query Strategy (UseIP/UseIPv4/UseIPv6/PreferIPv4/PreferIPv6, clear=hapus) (atau kembali): " qs
        if is_back_choice "${qs}"; then
          continue
        fi
        qs="$(echo "${qs}" | tr -d '[:space:]')"
        case "${qs}" in
          UseIP|UseIPv4|UseIPv6|PreferIPv4|PreferIPv6)
            if ! confirm_menu_apply_now "Stage Query Strategy ke ${qs} sekarang?"; then
              pause
              continue
            fi
            if ! xray_dns_candidate_prepare dns_candidate; then
              warn "Gagal menyiapkan staging DNS."
              pause
              continue
            fi
            if ! xray_dns_mutate_candidate_file "${dns_candidate}" set_query_strategy "${qs}"; then
              warn "Gagal men-stage Query Strategy."
              pause
              continue
            fi
            pending_changes="true"
            log "Query Strategy di-stage: ${qs}"
            pause
            ;;
          off|OFF|clear|CLEAR|none|NONE|-|default|DEFAULT)
            if ! confirm_menu_apply_now "Stage penghapusan Query Strategy custom sekarang?"; then
              pause
              continue
            fi
            if ! xray_dns_candidate_prepare dns_candidate; then
              warn "Gagal menyiapkan staging DNS."
              pause
              continue
            fi
            if ! xray_dns_mutate_candidate_file "${dns_candidate}" set_query_strategy "clear"; then
              warn "Gagal men-stage penghapusan Query Strategy."
              pause
              continue
            fi
            pending_changes="true"
            log "Query Strategy custom di-stage untuk dihapus."
            pause
            ;;
          *)
            warn "Query Strategy tidak valid"
            pause
            ;;
        esac
        ;;
      4)
        if [[ "${parse_state}" == "invalid" ]]; then
          pause
          continue
        fi
        if ! confirm_menu_apply_now "Stage toggle DNS Cache sekarang?"; then
          pause
          continue
        fi
        if ! xray_dns_candidate_prepare dns_candidate; then
          warn "Gagal menyiapkan staging DNS."
          pause
          continue
        fi
        if ! xray_dns_mutate_candidate_file "${dns_candidate}" toggle_cache; then
          warn "Gagal men-stage toggle DNS Cache."
          pause
          continue
        fi
        pending_changes="true"
        log "Toggle DNS Cache di-stage."
        pause
        ;;
      5)
        if [[ "${pending_changes}" == "true" ]]; then
          if [[ "${parse_state}" == "invalid" ]]; then
            warn "Staged DNS invalid. Buang staging lalu ulangi dari state live terbaru."
            pause
            continue
          fi
          if ! confirm_menu_apply_now "Apply semua staged DNS changes sekarang?"; then
            pause
            continue
          fi
          if ! dns_settings_run_mutation "Staged DNS settings applied" xray_dns_apply_candidate_file "${dns_candidate}"; then
            pause
            continue
          fi
          xray_stage_candidate_cleanup "${dns_candidate}"
          dns_candidate=""
          pending_changes="false"
          pause
          continue
        fi
        dns_show_status
        ;;
      6)
        if [[ "${pending_changes}" != "true" ]]; then
          warn "Pilihan tidak valid"
          sleep 1
          continue
        fi
        if confirm_menu_apply_now "Buang semua staged DNS changes?"; then
          xray_stage_candidate_cleanup "${dns_candidate}"
          dns_candidate=""
          pending_changes="false"
          log "Staged DNS changes dibuang."
        fi
        pause
        ;;
      7)
        if [[ "${pending_changes}" != "true" ]]; then
          warn "Pilihan tidak valid"
          sleep 1
          continue
        fi
        dns_show_status "${dns_candidate}" "DNS Status (Staged)"
        ;;
      0|kembali|k|back|b)
        if [[ "${pending_changes}" == "true" ]]; then
          local back_rc=0
          if [[ "${parse_state}" == "invalid" ]]; then
            warn "Staged DNS invalid. Staging dibuang."
            xray_stage_candidate_cleanup "${dns_candidate}"
            dns_candidate=""
            pending_changes="false"
          elif confirm_yn_or_back "Apply staged DNS changes sebelum keluar? Pilih no untuk membuang staging."; then
            if ! dns_settings_run_mutation "Staged DNS settings applied" xray_dns_apply_candidate_file "${dns_candidate}"; then
              pause
              continue
            fi
          else
            back_rc=$?
            if (( back_rc == 2 )); then
              continue
            fi
            xray_stage_candidate_cleanup "${dns_candidate}"
            log "Staged DNS changes dibuang."
          fi
        fi
        xray_stage_candidate_cleanup "${dns_candidate}"
        break
        ;;
      *) warn "Pilihan tidak valid" ; sleep 1 ;;
    esac
  done
}

dns_addons_menu() {
  while true; do
    title
    echo "$(xray_network_menu_title "DNS Add-ons")"
    hr
    if [[ -f "${XRAY_DNS_CONF}" ]]; then
      echo "DNS conf: ${XRAY_DNS_CONF}"
      echo "Tip: gunakan editor untuk perubahan advanced (nano)."
      hr
      sed -n '1,200p' "${XRAY_DNS_CONF}" || true
      hr
    else
      warn "DNS conf tidak ditemukan: ${XRAY_DNS_CONF}"
      hr
    fi
    echo "  1) Open DNS config with nano (full replace)"
    echo "  0) Back"
    hr
    read -r -p "Pilih: " c
    case "${c}" in
      1)
        if have_cmd nano; then
          if ! xray_dns_run_locked dns_addons_edit_with_nano; then
            pause
            continue
          fi
          pause
        else
          warn "nano tidak tersedia"
          pause
        fi
        ;;
      0|kembali|k|back|b) break ;;
      *) warn "Pilihan tidak valid" ; sleep 1 ;;
    esac
  done
}

dns_addons_edit_with_nano() {
  local fatal_dns_error="false"
  local dns_edit_failed="false"
  local snap_dir edit_target apply_rc=0 diff_report=""
  local added_lines=0 removed_lines=0 live_backup=""
  snap_dir="$(mktemp -d "${WORK_DIR}/.dns-editor.XXXXXX" 2>/dev/null || true)"
  [[ -n "${snap_dir}" ]] || snap_dir="${WORK_DIR}/.dns-editor.$$"
  mkdir -p "${snap_dir}" "$(dirname "${XRAY_DNS_CONF}")" 2>/dev/null || true
  if ! snapshot_file_capture "${XRAY_DNS_CONF}" "${snap_dir}" "dns_conf"; then
    warn "Gagal membuat snapshot DNS config sebelum edit."
    rm -rf "${snap_dir}" >/dev/null 2>&1 || true
    return 1
  fi

  edit_target="${snap_dir}/dns_conf.edit.json"
  if [[ -f "${XRAY_DNS_CONF}" ]]; then
    if ! cp -a "${XRAY_DNS_CONF}" "${edit_target}" 2>/dev/null; then
      warn "Gagal menyiapkan salinan DNS config untuk editor."
      rm -rf "${snap_dir}" >/dev/null 2>&1 || true
      return 1
    fi
  else
    : > "${edit_target}" || {
      warn "Gagal menyiapkan file DNS config untuk editor."
      rm -rf "${snap_dir}" >/dev/null 2>&1 || true
      return 1
    }
  fi

  if ! nano "${edit_target}"; then
    warn "Editor manual DNS gagal dibuka atau dibatalkan."
    rm -rf "${snap_dir}" >/dev/null 2>&1 || true
    return 1
  fi

  if { [[ -f "${XRAY_DNS_CONF}" ]] && cmp -s -- "${XRAY_DNS_CONF}" "${edit_target}"; } \
    || { [[ ! -f "${XRAY_DNS_CONF}" ]] && [[ ! -s "${edit_target}" ]]; }; then
    log "Tidak ada perubahan pada DNS config."
    rm -rf "${snap_dir}" >/dev/null 2>&1 || true
    return 0
  fi

  if ! xray_confdir_syntax_test_with_override "${XRAY_DNS_CONF}" "${edit_target}"; then
    dns_edit_failed="true"
    warn "Konfigurasi DNS invalid setelah edit manual. Perubahan belum diterapkan ke file live."
  else
    diff_report="$(preview_report_path_prepare "dns-edit-diff" 2>/dev/null || true)"
    if [[ -n "${diff_report}" ]] && dns_addons_diff_report_write "${XRAY_DNS_CONF}" "${edit_target}" "${diff_report}"; then
      added_lines="$(grep -Ec '^[+][^+]' "${diff_report}" 2>/dev/null || true)"
      removed_lines="$(grep -Ec '^[-][^-]' "${diff_report}" 2>/dev/null || true)"
      [[ "${added_lines}" =~ ^[0-9]+$ ]] || added_lines=0
      [[ "${removed_lines}" =~ ^[0-9]+$ ]] || removed_lines=0
      echo "Preview diff DNS:"
      echo "  ${diff_report}"
      echo "Ringkasan    : +${added_lines} / -${removed_lines} baris"
      preview_report_show_file "${diff_report}" || warn "Gagal membuka preview diff DNS."
      hr
    else
      rm -f "${diff_report}" >/dev/null 2>&1 || true
      diff_report=""
    fi
    if [[ -f "${XRAY_DNS_CONF}" ]]; then
      live_backup="$(mktemp "${WORK_DIR}/dns-live.backup.XXXXXX.json" 2>/dev/null || true)"
      if [[ -n "${live_backup}" ]]; then
        if ! cp -a "${XRAY_DNS_CONF}" "${live_backup}" 2>/dev/null; then
          rm -f "${live_backup}" >/dev/null 2>&1 || true
          live_backup=""
        else
          echo "Backup live   : ${live_backup}"
        fi
      fi
    fi
	    warn "Editor ini akan mengganti keseluruhan DNS config live, bukan patch per-field."
	    warn "Gunakan menu DNS Settings bila Anda hanya ingin mengubah server/query-strategy/cache secara per-field."
	    if ! confirm_yn_or_back "Terapkan hasil edit DNS ke file live sekarang?"; then
	      apply_rc=$?
	      if (( apply_rc == 1 || apply_rc == 2 )); then
	        warn "Perubahan editor DNS dibatalkan sebelum diterapkan ke file live."
	        rm -f "${diff_report}" >/dev/null 2>&1 || true
	        [[ -n "${live_backup}" ]] && rm -f "${live_backup}" >/dev/null 2>&1 || true
	        rm -rf "${snap_dir}" >/dev/null 2>&1 || true
	        return 0
	      fi
	    elif ! confirm_menu_apply_now "Konfirmasi final: ganti seluruh DNS config live dengan hasil editor ini?"; then
	      warn "Perubahan editor DNS dibatalkan pada checkpoint full-replace."
	      rm -f "${diff_report}" >/dev/null 2>&1 || true
	      [[ -n "${live_backup}" ]] && rm -f "${live_backup}" >/dev/null 2>&1 || true
	      rm -rf "${snap_dir}" >/dev/null 2>&1 || true
	      return 0
	    else
	      local replace_ack=""
	      read -r -p "Ketik persis 'REPLACE DNS FULL' untuk lanjut full-replace DNS config (atau kembali): " replace_ack
	      if is_back_choice "${replace_ack}"; then
	        warn "Perubahan editor DNS dibatalkan pada checkpoint full-replace."
	        rm -f "${diff_report}" >/dev/null 2>&1 || true
	        [[ -n "${live_backup}" ]] && rm -f "${live_backup}" >/dev/null 2>&1 || true
	        rm -rf "${snap_dir}" >/dev/null 2>&1 || true
	        return 0
	      fi
	      if [[ "${replace_ack}" != "REPLACE DNS FULL" ]]; then
	        warn "Konfirmasi full-replace DNS tidak cocok. Dibatalkan."
	        rm -f "${diff_report}" >/dev/null 2>&1 || true
	        [[ -n "${live_backup}" ]] && rm -f "${live_backup}" >/dev/null 2>&1 || true
	        rm -rf "${snap_dir}" >/dev/null 2>&1 || true
	        return 0
	      fi
	      if (( added_lines + removed_lines >= 40 )); then
	        local replace_full_ack=""
	        read -r -p "Diff DNS cukup besar (+${added_lines}/-${removed_lines}). Ketik persis 'CONFIRM DNS LARGE' untuk lanjut (atau kembali): " replace_full_ack
	        if is_back_choice "${replace_full_ack}"; then
	          warn "Perubahan editor DNS dibatalkan pada checkpoint diff besar."
	          rm -f "${diff_report}" >/dev/null 2>&1 || true
	          [[ -n "${live_backup}" ]] && rm -f "${live_backup}" >/dev/null 2>&1 || true
	          rm -rf "${snap_dir}" >/dev/null 2>&1 || true
	          return 0
	        fi
	        if [[ "${replace_full_ack}" != "CONFIRM DNS LARGE" ]]; then
	          warn "Konfirmasi tambahan full-replace DNS tidak cocok. Dibatalkan."
	          rm -f "${diff_report}" >/dev/null 2>&1 || true
	          [[ -n "${live_backup}" ]] && rm -f "${live_backup}" >/dev/null 2>&1 || true
	          rm -rf "${snap_dir}" >/dev/null 2>&1 || true
	          return 0
	        fi
	      fi
	    fi
	    if ! xray_write_file_atomic "${XRAY_DNS_CONF}" "${edit_target}"; then
	      dns_edit_failed="true"
	      warn "Gagal mengganti DNS config secara atomic."
	    elif ! xray_routing_restart_checked; then
      dns_edit_failed="true"
      if ! snapshot_file_restore "${XRAY_DNS_CONF}" "${snap_dir}" "dns_conf" >/dev/null 2>&1; then
        warn "Rollback file DNS dari snapshot gagal setelah restart xray gagal."
        fatal_dns_error="true"
      elif ! xray_routing_restart_checked; then
        warn "Rollback runtime xray gagal setelah restart xray gagal."
        fatal_dns_error="true"
      fi
      warn "xray tidak aktif setelah edit manual DNS config. File dikembalikan ke snapshot sebelumnya."
      systemctl status xray --no-pager 2>/dev/null || true
    else
      log "DNS config berhasil diperbarui lewat editor manual."
      if [[ -n "${live_backup}" && -f "${live_backup}" ]]; then
        echo "Backup pre-apply: ${live_backup}"
        echo "Restore hint   : cp -f '${live_backup}' '${XRAY_DNS_CONF}' && systemctl restart xray"
      fi
    fi
  fi
  rm -f "${diff_report}" >/dev/null 2>&1 || true
  rm -rf "${snap_dir}" >/dev/null 2>&1 || true
  if [[ "${fatal_dns_error}" == "true" || "${dns_edit_failed}" == "true" ]]; then
    return 1
  fi
  return 0
}

