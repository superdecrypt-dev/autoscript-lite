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
  # parallel=on|off
  # systemhosts=on|off
  # disablefallback=on|off
  # disablefallbackifmatch=on|off
  # hosts_count=<n>
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

hosts=dns.get('hosts')
if not isinstance(hosts, dict):
  hosts = {}

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

parallel='on' if bool(dns.get('enableParallelQuery')) else 'off'
systemhosts='on' if bool(dns.get('useSystemHosts')) else 'off'
disablefallback='on' if bool(dns.get('disableFallback')) else 'off'
disablefallbackifmatch='on' if bool(dns.get('disableFallbackIfMatch')) else 'off'

print('parse_state=ok')
print('error=')
print('primary=' + primary)
print('secondary=' + secondary)
print('strategy=' + strategy)
print('cache=' + cache)
print('parallel=' + parallel)
print('systemhosts=' + systemhosts)
print('disablefallback=' + disablefallback)
print('disablefallbackifmatch=' + disablefallbackifmatch)
print('hosts_count=' + str(len(hosts)))
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
elif action == "toggle_enable_parallel_query":
  dns["enableParallelQuery"] = not bool(dns.get("enableParallelQuery"))
elif action == "toggle_use_system_hosts":
  dns["useSystemHosts"] = not bool(dns.get("useSystemHosts"))
elif action == "toggle_disable_fallback":
  dns["disableFallback"] = not bool(dns.get("disableFallback"))
elif action == "toggle_disable_fallback_if_match":
  dns["disableFallbackIfMatch"] = not bool(dns.get("disableFallbackIfMatch"))
elif action == "set_host_pin":
  if not value or "|" not in value:
    raise SystemExit("set_host_pin butuh format domain|ip")
  host, ip = value.split("|", 1)
  host = host.strip()
  ip = ip.strip()
  if not host or not ip:
    raise SystemExit("set_host_pin butuh domain dan ip")
  hosts = dns.get("hosts")
  if not isinstance(hosts, dict):
    hosts = {}
  hosts[host] = ip
  dns["hosts"] = hosts
elif action == "clear_host_pin":
  if value:
    hosts = dns.get("hosts")
    if isinstance(hosts, dict):
      hosts.pop(value, None)
      dns["hosts"] = hosts
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

xray_dns_server_objects_get() {
  # output columns:
  # idx	type	tag	address	domains_count	skipfallback	finalquery	querystrategy	domains_csv
  local src_file="${1:-${XRAY_DNS_CONF}}"
  need_python3
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

src = sys.argv[1]
try:
  with open(src, "r", encoding="utf-8") as f:
    cfg = json.loads(strip_json_comments(f.read()))
except Exception:
  raise SystemExit(0)

dns = cfg.get("dns")
if not isinstance(dns, dict):
  dns = {}
servers = dns.get("servers")
if not isinstance(servers, list):
  servers = []

for idx, entry in enumerate(servers):
  if isinstance(entry, str):
    print(f"{idx}\tstring\t-\t{entry}\t0\t-\t-\t-\t-")
    continue
  if not isinstance(entry, dict):
    print(f"{idx}\tunknown\t-\t-\t0\t-\t-\t-\t-")
    continue
  tag = entry.get("tag")
  tag = tag.strip() if isinstance(tag, str) else ""
  addr = entry.get("address")
  addr = addr.strip() if isinstance(addr, str) else ""
  domains = entry.get("domains")
  if not isinstance(domains, list):
    domains = []
  clean_domains = [x.strip() for x in domains if isinstance(x, str) and x.strip()]
  skipfallback = "on" if bool(entry.get("skipFallback")) else "off"
  finalquery = "on" if bool(entry.get("finalQuery")) else "off"
  qstrategy = entry.get("queryStrategy")
  qstrategy = qstrategy.strip() if isinstance(qstrategy, str) else ""
  print(f"{idx}\tdict\t{tag}\t{addr}\t{len(clean_domains)}\t{skipfallback}\t{finalquery}\t{qstrategy}\t{','.join(clean_domains)}")
PY
}

xray_dns_mutate_server_object_candidate_file() {
  # args: candidate_file index action [value]
  local candidate="$1"
  local index="$2"
  local action="$3"
  local value="${4:-}"
  need_python3
  [[ -n "${candidate}" ]] || return 1
  python3 - <<'PY' "${candidate}" "${index}" "${action}" "${value}" || return 1
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

path, index_raw, action, value = sys.argv[1:5]
action = str(action or "").strip()
value = str(value or "").strip()
try:
  idx = int(str(index_raw).strip())
except Exception:
  raise SystemExit("index server DNS tidak valid")

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
  raise SystemExit("Config DNS tidak valid: dns.servers bukan array")

if idx < 0 or idx >= len(servers):
  raise SystemExit("Index server DNS di luar range")

entry = servers[idx]
if not isinstance(entry, dict):
  raise SystemExit("Server DNS ini immutable atau bukan object resolver")

def clean_list(raw):
  out = []
  for item in raw.split(","):
    item = item.strip()
    if item:
      out.append(item)
  return out

if action == "set_address":
  if not value:
    raise SystemExit("address kosong")
  entry["address"] = value
elif action == "set_tag":
  if value:
    entry["tag"] = value
  else:
    entry.pop("tag", None)
elif action == "toggle_skip_fallback":
  entry["skipFallback"] = not bool(entry.get("skipFallback"))
elif action == "toggle_final_query":
  entry["finalQuery"] = not bool(entry.get("finalQuery"))
elif action == "set_query_strategy":
  if value.lower() in {"off", "clear", "none", "-", "default"}:
    entry.pop("queryStrategy", None)
  elif value:
    entry["queryStrategy"] = value
elif action == "set_domains":
  domains = clean_list(value)
  if domains:
    entry["domains"] = domains
  else:
    entry.pop("domains", None)
elif action == "clear_domains":
  entry.pop("domains", None)
else:
  raise SystemExit(f"aksi DNS server tidak dikenali: {action}")

servers[idx] = entry
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

dns_addons_servers_summary_render() {
  local src_file="${1:-${XRAY_DNS_CONF}}"
  local lines=()
  mapfile -t lines < <(xray_dns_server_objects_get "${src_file}")
  local line idx typ tag addr dcount skip final qstr dlist
  echo "Resolver Objects"
  hr
  if [[ "${#lines[@]}" -eq 0 ]]; then
    echo "  (tidak ada resolver object yang bisa diedit)"
    return 0
  fi
  for line in "${lines[@]}"; do
    [[ -n "${line}" ]] || continue
    IFS=$'\t' read -r idx typ tag addr dcount skip final qstr dlist <<<"${line}"
    printf "  [%s] %s\n" "${idx}" "${addr:-${typ}}"
    printf "       Tag            : %s\n" "${tag:--}"
    printf "       Domains        : %s\n" "${dcount:-0}"
    printf "       SkipFallback   : %s\n" "${skip:-off}"
    printf "       FinalQuery     : %s\n" "${final:-off}"
    printf "       QueryStrategy   : %s\n" "${qstr:--}"
    if [[ -n "${dlist}" && "${dlist}" != "-" ]]; then
      printf "       Domain Filters  : %s\n" "${dlist}"
    fi
  done
}

dns_addons_server_object_menu() {
  local dns_candidate=""
  local pending_changes="false"
  while true; do
    local status_source status_blob parse_state
    status_source="${dns_candidate:-${XRAY_DNS_CONF}}"
    status_blob="$(xray_dns_status_get "${status_source}")"
    parse_state="$(printf '%s\n' "${status_blob}" | awk -F'=' '/^parse_state=/{print $2; exit}' 2>/dev/null || true)"
    title
    echo "$(xray_network_menu_title "DNS Resolver Objects")"
    hr
    dns_addons_servers_summary_render "${status_source}"
    hr
    echo "  1) Edit Resolver by Index"
    if [[ "${pending_changes}" == "true" ]]; then
      echo "  2) Apply staged resolver-object changes"
      echo "  3) Discard staged resolver-object changes"
      echo "  4) Show staged resolver summary"
    else
      echo "  2) Refresh live resolver summary"
    fi
    echo "  0) Back"
    hr
    read -r -p "Pilih: " c
    case "${c}" in
      1)
        if [[ "${parse_state}" == "invalid" ]]; then
          warn "DNS invalid. Perbaiki dulu di DNS Settings."
          pause
          continue
        fi
        local idx
        read -r -p "Index resolver object (lihat summary, atau kembali): " idx
        if is_back_choice "${idx}"; then
          continue
        fi
        idx="$(echo "${idx}" | tr -d '[:space:]')"
        if ! [[ "${idx}" =~ ^[0-9]+$ ]]; then
          warn "Index resolver tidak valid"
          pause
          continue
        fi
        if ! dns_addons_server_object_editor_menu "${idx}" dns_candidate; then
          pause
          continue
        fi
        if [[ -n "${dns_candidate}" && -f "${dns_candidate}" && -f "${XRAY_DNS_CONF}" ]] \
          && ! cmp -s -- "${dns_candidate}" "${XRAY_DNS_CONF}"; then
          pending_changes="true"
        else
          xray_stage_candidate_cleanup "${dns_candidate}"
          dns_candidate=""
          pending_changes="false"
        fi
        ;;
      2)
        if [[ "${pending_changes}" == "true" ]]; then
          if [[ "${parse_state}" == "invalid" ]]; then
            warn "Staged DNS invalid. Buang staging lalu ulangi dari state live terbaru."
            pause
            continue
          fi
          if ! confirm_menu_apply_now "Apply staged DNS resolver-object changes sekarang?"; then
            pause
            continue
          fi
          if ! dns_settings_run_mutation "Staged DNS resolver-object changes applied" xray_dns_apply_candidate_file "${dns_candidate}"; then
            pause
            continue
          fi
          xray_stage_candidate_cleanup "${dns_candidate}"
          dns_candidate=""
          pending_changes="false"
          pause
          continue
        fi
        pause
        ;;
      3)
        if [[ "${pending_changes}" != "true" ]]; then
          warn "Pilihan tidak valid"
          sleep 1
          continue
        fi
        if confirm_menu_apply_now "Buang semua staged resolver-object changes?"; then
          xray_stage_candidate_cleanup "${dns_candidate}"
          dns_candidate=""
          pending_changes="false"
          log "Staged resolver-object DNS changes dibuang."
        fi
        pause
        ;;
      4)
        if [[ "${pending_changes}" != "true" ]]; then
          warn "Pilihan tidak valid"
          sleep 1
          continue
        fi
        dns_show_status "${dns_candidate}" "DNS Status (Staged)"
        ;;
      0|kembali|k|back|b)
        if [[ "${pending_changes}" == "true" ]]; then
          if [[ "${parse_state}" == "invalid" ]]; then
            warn "Staged DNS invalid. Staging dibuang."
            xray_stage_candidate_cleanup "${dns_candidate}"
            dns_candidate=""
            pending_changes="false"
          elif confirm_yn_or_back "Apply staged resolver-object DNS changes sebelum keluar? Pilih no untuk membuang staging."; then
            if ! dns_settings_run_mutation "Staged DNS resolver-object changes applied" xray_dns_apply_candidate_file "${dns_candidate}"; then
              pause
              continue
            fi
          else
            xray_stage_candidate_cleanup "${dns_candidate}"
            log "Staged resolver-object DNS changes dibuang."
          fi
        fi
        xray_stage_candidate_cleanup "${dns_candidate}"
        break
        ;;
      *) warn "Pilihan tidak valid" ; sleep 1 ;;
    esac
  done
}

dns_addons_server_object_editor_menu() {
  local idx="$1"
  local candidate_var_name="${2:-}"
  local dns_candidate=""
  local pending_changes="false"
  local candidate_ref=""
  [[ -n "${candidate_var_name}" ]] || return 1
  local -n _candidate_ref="${candidate_var_name}"
  candidate_ref="${_candidate_ref}"
  if ! xray_dns_candidate_prepare _candidate_ref; then
    warn "Gagal menyiapkan staging DNS."
    return 1
  fi
  dns_candidate="${_candidate_ref}"
  while true; do
    local status_blob parse_state line typ tag addr dcount skip final qstr dlist
    status_blob="$(xray_dns_status_get "${dns_candidate:-${XRAY_DNS_CONF}}")"
    parse_state="$(printf '%s\n' "${status_blob}" | awk -F'=' '/^parse_state=/{print $2; exit}' 2>/dev/null || true)"
    line="$(xray_dns_server_objects_get "${dns_candidate:-${XRAY_DNS_CONF}}" | awk -F'\t' -v n="${idx}" '$1==n {print; exit}' 2>/dev/null || true)"
    if [[ -z "${line}" ]]; then
      warn "Resolver index ${idx} tidak ditemukan"
      return 1
    fi
    IFS=$'\t' read -r _ typ tag addr dcount skip final qstr dlist <<<"${line}"
    title
    echo "$(xray_network_menu_title "DNS Resolver Object #${idx}")"
    hr
    printf "Type           : %s\n" "${typ:-unknown}"
    printf "Address        : %s\n" "${addr:--}"
    printf "Tag            : %s\n" "${tag:--}"
    printf "Domains        : %s\n" "${dcount:-0}"
    printf "SkipFallback   : %s\n" "${skip:-off}"
    printf "FinalQuery     : %s\n" "${final:-off}"
    printf "QueryStrategy  : %s\n" "${qstr:--}"
    if [[ -n "${dlist}" && "${dlist}" != "-" ]]; then
      printf "Domain Filters : %s\n" "${dlist}"
    fi
    hr
    if [[ "${typ}" != "dict" ]]; then
      warn "Resolver object ini immutable. Gunakan index object yang bertipe dict."
      echo "  0) Back"
      hr
      read -r -p "Pilih: " c
      case "${c}" in
        0|kembali|k|back|b) break ;;
        *) warn "Pilihan tidak valid" ; sleep 1 ;;
      esac
      continue
    fi
    echo "  1) Set Address"
    echo "  2) Set Tag"
    echo "  3) Toggle Skip Fallback"
    echo "  4) Toggle Final Query"
    echo "  5) Set Query Strategy"
    echo "  6) Set Domains (comma separated)"
    echo "  7) Clear Domains"
    if [[ "${pending_changes}" == "true" ]]; then
      echo "  8) Apply staged changes"
      echo "  9) Discard staged changes"
    fi
    echo "  0) Back"
    hr
    read -r -p "Pilih: " c
    case "${c}" in
      1)
        if [[ "${parse_state}" == "invalid" ]]; then
          warn "DNS invalid. Perbaiki dulu di DNS Settings."
          pause
          continue
        fi
        local new_addr
        read -r -p "Address baru (atau kembali): " new_addr
        if is_back_choice "${new_addr}"; then
          continue
        fi
        new_addr="$(echo "${new_addr}" | tr -d '[:space:]')"
        if [[ -z "${new_addr}" ]]; then
          warn "Address kosong"
          pause
          continue
        fi
        if ! confirm_menu_apply_now "Stage address resolver #${idx} ke ${new_addr} sekarang?"; then
          pause
          continue
        fi
        if ! xray_dns_mutate_server_object_candidate_file "${dns_candidate}" "${idx}" set_address "${new_addr}"; then
          warn "Gagal set address resolver."
          pause
          continue
        fi
        pending_changes="true"
        log "Resolver #${idx} address di-stage: ${new_addr}"
        pause
        ;;
      2)
        local new_tag
        read -r -p "Tag baru (kosong untuk hapus, atau kembali): " new_tag
        if is_back_choice "${new_tag}"; then
          continue
        fi
        new_tag="$(echo "${new_tag}" | tr -d '[:space:]')"
        if ! confirm_menu_apply_now "Stage tag resolver #${idx} sekarang?"; then
          pause
          continue
        fi
        if ! xray_dns_mutate_server_object_candidate_file "${dns_candidate}" "${idx}" set_tag "${new_tag}"; then
          warn "Gagal set tag resolver."
          pause
          continue
        fi
        pending_changes="true"
        log "Resolver #${idx} tag di-stage."
        pause
        ;;
      3)
        if ! confirm_menu_apply_now "Toggle skipFallback resolver #${idx} sekarang?"; then
          pause
          continue
        fi
        if ! xray_dns_mutate_server_object_candidate_file "${dns_candidate}" "${idx}" toggle_skip_fallback ""; then
          warn "Gagal toggle skipFallback resolver."
          pause
          continue
        fi
        pending_changes="true"
        log "Resolver #${idx} skipFallback di-stage."
        pause
        ;;
      4)
        if ! confirm_menu_apply_now "Toggle finalQuery resolver #${idx} sekarang?"; then
          pause
          continue
        fi
        if ! xray_dns_mutate_server_object_candidate_file "${dns_candidate}" "${idx}" toggle_final_query ""; then
          warn "Gagal toggle finalQuery resolver."
          pause
          continue
        fi
        pending_changes="true"
        log "Resolver #${idx} finalQuery di-stage."
        pause
        ;;
      5)
        local new_qs
        read -r -p "Query Strategy (UseIP/UseIPv4/UseIPv6/PreferIPv4/PreferIPv6, clear=hapus) (atau kembali): " new_qs
        if is_back_choice "${new_qs}"; then
          continue
        fi
        new_qs="$(echo "${new_qs}" | tr -d '[:space:]')"
        case "${new_qs}" in
          UseIP|UseIPv4|UseIPv6|PreferIPv4|PreferIPv6|clear|CLEAR|off|OFF|none|NONE|-|default|DEFAULT)
            if ! confirm_menu_apply_now "Stage queryStrategy resolver #${idx} sekarang?"; then
              pause
              continue
            fi
            if ! xray_dns_mutate_server_object_candidate_file "${dns_candidate}" "${idx}" set_query_strategy "${new_qs}"; then
              warn "Gagal set queryStrategy resolver."
              pause
              continue
            fi
            pending_changes="true"
            log "Resolver #${idx} queryStrategy di-stage."
            pause
            ;;
          *)
            warn "Query Strategy tidak valid"
            pause
            ;;
        esac
        ;;
      6)
        local new_domains
        read -r -p "Domains CSV (contoh geosite:google,full:example.com) (atau kembali): " new_domains
        if is_back_choice "${new_domains}"; then
          continue
        fi
        new_domains="$(echo "${new_domains}" | sed 's/[[:space:]]*,[[:space:]]*/,/g; s/^[[:space:]]*//; s/[[:space:]]*$//')"
        if ! confirm_menu_apply_now "Stage domains resolver #${idx} sekarang?"; then
          pause
          continue
        fi
        if ! xray_dns_mutate_server_object_candidate_file "${dns_candidate}" "${idx}" set_domains "${new_domains}"; then
          warn "Gagal set domains resolver."
          pause
          continue
        fi
        pending_changes="true"
        log "Resolver #${idx} domains di-stage."
        pause
        ;;
      7)
        if ! confirm_menu_apply_now "Clear domains resolver #${idx} sekarang?"; then
          pause
          continue
        fi
        if ! xray_dns_mutate_server_object_candidate_file "${dns_candidate}" "${idx}" clear_domains ""; then
          warn "Gagal clear domains resolver."
          pause
          continue
        fi
        pending_changes="true"
        log "Resolver #${idx} domains di-stage untuk dihapus."
        pause
        ;;
      8)
        if [[ "${pending_changes}" != "true" ]]; then
          warn "Pilihan tidak valid"
          sleep 1
          continue
        fi
        if [[ "${parse_state}" == "invalid" ]]; then
          warn "Staged DNS invalid. Perbaiki dulu di DNS Settings."
          pause
          continue
        fi
        if confirm_menu_apply_now "Apply staged resolver-object changes sekarang?"; then
          if ! dns_settings_run_mutation "Staged DNS resolver-object changes applied" xray_dns_apply_candidate_file "${dns_candidate}"; then
            pause
            continue
          fi
          pending_changes="false"
          dns_candidate=""
          pause
          return 0
        fi
        pause
        ;;
      9)
        if [[ "${pending_changes}" != "true" ]]; then
          warn "Pilihan tidak valid"
          sleep 1
          continue
        fi
        if confirm_menu_apply_now "Buang staged resolver-object changes?"; then
          xray_stage_candidate_cleanup "${dns_candidate}"
          dns_candidate=""
          pending_changes="false"
          log "Staged resolver-object DNS changes dibuang."
          return 0
        fi
        pause
        ;;
      0|kembali|k|back|b)
        if [[ "${pending_changes}" == "true" ]]; then
          if confirm_yn_or_back "Apply staged resolver-object DNS changes sebelum keluar? Pilih no untuk membuang staging."; then
            if ! dns_settings_run_mutation "Staged DNS resolver-object changes applied" xray_dns_apply_candidate_file "${dns_candidate}"; then
              pause
              continue
            fi
          else
            xray_stage_candidate_cleanup "${dns_candidate}"
            log "Staged resolver-object DNS changes dibuang."
          fi
        fi
        xray_stage_candidate_cleanup "${dns_candidate}"
        break
        ;;
      *) warn "Pilihan tidak valid" ; sleep 1 ;;
    esac
  done
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
  local parallel systemhosts disablefallback disablefallbackifmatch hosts_count
  parallel="$(printf '%s\n' "${status_blob}" | awk -F'=' '/^parallel=/{print $2; exit}' 2>/dev/null || true)"
  systemhosts="$(printf '%s\n' "${status_blob}" | awk -F'=' '/^systemhosts=/{print $2; exit}' 2>/dev/null || true)"
  disablefallback="$(printf '%s\n' "${status_blob}" | awk -F'=' '/^disablefallback=/{print $2; exit}' 2>/dev/null || true)"
  disablefallbackifmatch="$(printf '%s\n' "${status_blob}" | awk -F'=' '/^disablefallbackifmatch=/{print $2; exit}' 2>/dev/null || true)"
  hosts_count="$(printf '%s\n' "${status_blob}" | awk -F'=' '/^hosts_count=/{print $2; exit}' 2>/dev/null || true)"
  [[ -n "${primary}" ]] || primary="-"
  [[ -n "${secondary}" ]] || secondary="-"
  [[ -n "${strategy}" ]] || strategy="-"
  [[ -n "${cache}" ]] || cache="on"
  [[ -n "${parallel}" ]] || parallel="off"
  [[ -n "${systemhosts}" ]] || systemhosts="off"
  [[ -n "${disablefallback}" ]] || disablefallback="off"
  [[ -n "${disablefallbackifmatch}" ]] || disablefallbackifmatch="off"
  [[ -n "${hosts_count}" ]] || hosts_count="0"

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
    echo "Parallel Query: $( [[ "${parallel}" == "on" ]] && echo ON || echo OFF )"
    echo "System Hosts  : $( [[ "${systemhosts}" == "on" ]] && echo ON || echo OFF )"
    echo "Fallback Lock : $( [[ "${disablefallback}" == "on" ]] && echo ON || echo OFF )"
    echo "Match Lock    : $( [[ "${disablefallbackifmatch}" == "on" ]] && echo ON || echo OFF )"
    echo "Hosts Count   : ${hosts_count}"
    if [[ "${parse_state}" == "invalid" ]]; then
      warn "DNS Settings diblok sampai JSON DNS valid kembali. Gunakan DNS Editor atau Checks untuk memperbaiki file."
    fi
    hr
    echo "  1) Set Primary DNS"
    echo "  2) Set Secondary DNS"
    echo "  3) Set Query Strategy"
    echo "  4) Toggle DNS Cache"
    echo "  5) Advanced Controls"
    if [[ "${pending_changes}" == "true" ]]; then
      echo "  6) Apply staged DNS changes"
      echo "  7) Discard staged DNS changes"
      echo "  8) Show staged DNS status"
    else
      echo "  6) Show DNS Status"
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
        menu_run_isolated_report "DNS Advanced Controls" dns_advanced_controls_menu
        ;;
      6)
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
      7)
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
      8)
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

dns_advanced_controls_menu() {
  local dns_candidate=""
  local pending_changes="false"
  while true; do
    local status_source status_blob parse_state parallel systemhosts disablefallback disablefallbackifmatch hosts_count
    status_source="${dns_candidate:-${XRAY_DNS_CONF}}"
    status_blob="$(xray_dns_status_get "${status_source}")"
    parse_state="$(printf '%s\n' "${status_blob}" | awk -F'=' '/^parse_state=/{print $2; exit}' 2>/dev/null || true)"
    parallel="$(printf '%s\n' "${status_blob}" | awk -F'=' '/^parallel=/{print $2; exit}' 2>/dev/null || true)"
    systemhosts="$(printf '%s\n' "${status_blob}" | awk -F'=' '/^systemhosts=/{print $2; exit}' 2>/dev/null || true)"
    disablefallback="$(printf '%s\n' "${status_blob}" | awk -F'=' '/^disablefallback=/{print $2; exit}' 2>/dev/null || true)"
    disablefallbackifmatch="$(printf '%s\n' "${status_blob}" | awk -F'=' '/^disablefallbackifmatch=/{print $2; exit}' 2>/dev/null || true)"
    hosts_count="$(printf '%s\n' "${status_blob}" | awk -F'=' '/^hosts_count=/{print $2; exit}' 2>/dev/null || true)"
    [[ -n "${parallel}" ]] || parallel="off"
    [[ -n "${systemhosts}" ]] || systemhosts="off"
    [[ -n "${disablefallback}" ]] || disablefallback="off"
    [[ -n "${disablefallbackifmatch}" ]] || disablefallbackifmatch="off"
    [[ -n "${hosts_count}" ]] || hosts_count="0"

    title
    echo "$(xray_network_menu_title "DNS Advanced")"
    hr
    echo "Parallel Query : $( [[ "${parallel}" == "on" ]] && echo ON || echo OFF )"
    echo "System Hosts   : $( [[ "${systemhosts}" == "on" ]] && echo ON || echo OFF )"
    echo "Fallback Lock  : $( [[ "${disablefallback}" == "on" ]] && echo ON || echo OFF )"
    echo "Match Lock     : $( [[ "${disablefallbackifmatch}" == "on" ]] && echo ON || echo OFF )"
    echo "Hosts Count    : ${hosts_count}"
    hr
    echo "  1) Toggle Parallel Query"
    echo "  2) Toggle Use System Hosts"
    echo "  3) Toggle Disable Fallback"
    echo "  4) Toggle Disable Fallback If Match"
    echo "  5) Pin Host Domain"
    echo "  6) Clear Host Pin"
    echo "  0) Back"
    hr
    read -r -p "Pilih: " c
    case "${c}" in
      1)
        if [[ "${parse_state}" == "invalid" ]]; then
          warn "DNS invalid. Perbaiki dulu di DNS Settings."
          pause
          continue
        fi
        if confirm_menu_apply_now "Toggle enableParallelQuery sekarang?"; then
          if ! xray_dns_candidate_prepare dns_candidate; then
            warn "Gagal menyiapkan staging DNS."
            pause
            continue
          fi
          if ! xray_dns_mutate_candidate_file "${dns_candidate}" toggle_enable_parallel_query; then
            warn "Gagal toggle enableParallelQuery."
            pause
            continue
          fi
          pending_changes="true"
          log "enableParallelQuery di-stage."
        fi
        pause
        ;;
      2)
        if [[ "${parse_state}" == "invalid" ]]; then
          warn "DNS invalid. Perbaiki dulu di DNS Settings."
          pause
          continue
        fi
        if confirm_menu_apply_now "Toggle useSystemHosts sekarang?"; then
          if ! xray_dns_candidate_prepare dns_candidate; then
            warn "Gagal menyiapkan staging DNS."
            pause
            continue
          fi
          if ! xray_dns_mutate_candidate_file "${dns_candidate}" toggle_use_system_hosts; then
            warn "Gagal toggle useSystemHosts."
            pause
            continue
          fi
          pending_changes="true"
          log "useSystemHosts di-stage."
        fi
        pause
        ;;
      3)
        if [[ "${parse_state}" == "invalid" ]]; then
          warn "DNS invalid. Perbaiki dulu di DNS Settings."
          pause
          continue
        fi
        if confirm_menu_apply_now "Toggle disableFallback sekarang?"; then
          if ! xray_dns_candidate_prepare dns_candidate; then
            warn "Gagal menyiapkan staging DNS."
            pause
            continue
          fi
          if ! xray_dns_mutate_candidate_file "${dns_candidate}" toggle_disable_fallback; then
            warn "Gagal toggle disableFallback."
            pause
            continue
          fi
          pending_changes="true"
          log "disableFallback di-stage."
        fi
        pause
        ;;
      4)
        if [[ "${parse_state}" == "invalid" ]]; then
          warn "DNS invalid. Perbaiki dulu di DNS Settings."
          pause
          continue
        fi
        if confirm_menu_apply_now "Toggle disableFallbackIfMatch sekarang?"; then
          if ! xray_dns_candidate_prepare dns_candidate; then
            warn "Gagal menyiapkan staging DNS."
            pause
            continue
          fi
          if ! xray_dns_mutate_candidate_file "${dns_candidate}" toggle_disable_fallback_if_match; then
            warn "Gagal toggle disableFallbackIfMatch."
            pause
            continue
          fi
          pending_changes="true"
          log "disableFallbackIfMatch di-stage."
        fi
        pause
        ;;
      5)
        if [[ "${parse_state}" == "invalid" ]]; then
          warn "DNS invalid. Perbaiki dulu di DNS Settings."
          pause
          continue
        fi
        local host ip host_value=""
        read -r -p "Host/domain (atau kembali): " host
        if is_back_choice "${host}"; then
          continue
        fi
        read -r -p "IP literal (IPv4/IPv6) (atau kembali): " ip
        if is_back_choice "${ip}"; then
          continue
        fi
        host="$(echo "${host}" | tr -d '[:space:]')"
        ip="$(echo "${ip}" | tr -d '[:space:]')"
        if [[ -z "${host}" || -z "${ip}" ]]; then
          warn "Host atau IP kosong"
          pause
          continue
        fi
        if ! dns_server_literal_normalize "${ip}" >/dev/null 2>&1; then
          warn "IP literal tidak valid"
          pause
          continue
        fi
        host_value="${host}|${ip}"
        if ! confirm_menu_apply_now "Pin ${host} -> ${ip} sekarang?"; then
          pause
          continue
        fi
        if ! xray_dns_candidate_prepare dns_candidate; then
          warn "Gagal menyiapkan staging DNS."
          pause
          continue
        fi
        if ! xray_dns_mutate_candidate_file "${dns_candidate}" set_host_pin "${host_value}"; then
          warn "Gagal pin host DNS."
          pause
          continue
        fi
        pending_changes="true"
        log "Host DNS di-stage: ${host} -> ${ip}"
        pause
        ;;
      6)
        if [[ "${parse_state}" == "invalid" ]]; then
          warn "DNS invalid. Perbaiki dulu di DNS Settings."
          pause
          continue
        fi
        local host
        read -r -p "Host/domain yang mau dihapus (atau kembali): " host
        if is_back_choice "${host}"; then
          continue
        fi
        host="$(echo "${host}" | tr -d '[:space:]')"
        if [[ -z "${host}" ]]; then
          warn "Host kosong"
          pause
          continue
        fi
        if ! confirm_menu_apply_now "Hapus pin host ${host} sekarang?"; then
          pause
          continue
        fi
        if ! xray_dns_candidate_prepare dns_candidate; then
          warn "Gagal menyiapkan staging DNS."
          pause
          continue
        fi
        if ! xray_dns_mutate_candidate_file "${dns_candidate}" clear_host_pin "${host}"; then
          warn "Gagal hapus host DNS."
          pause
          continue
        fi
        pending_changes="true"
        log "Host DNS di-stage untuk dihapus: ${host}"
        pause
        ;;
      0|kembali|k|back|b)
        if [[ "${pending_changes}" == "true" ]]; then
          if confirm_menu_apply_now "Apply staged DNS advanced changes sekarang?"; then
            if ! dns_settings_run_mutation "Staged DNS advanced settings applied" xray_dns_apply_candidate_file "${dns_candidate}"; then
              pause
              continue
            fi
          else
            xray_stage_candidate_cleanup "${dns_candidate}"
            dns_candidate=""
            pending_changes="false"
          fi
        fi
        xray_stage_candidate_cleanup "${dns_candidate}"
        break
        ;;
      *) invalid_choice ;;
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
      echo "Tip: resolver object editor untuk perubahan granular; nano untuk full replace."
      hr
      dns_addons_servers_summary_render "${XRAY_DNS_CONF}" || true
      hr
    else
      warn "DNS conf tidak ditemukan: ${XRAY_DNS_CONF}"
      hr
    fi
    echo "  1) Resolver Object Editor"
    echo "  2) Open DNS config with nano (full replace)"
    echo "  0) Back"
    hr
    read -r -p "Pilih: " c
    case "${c}" in
      1)
        menu_run_isolated_report "DNS Resolver Objects" dns_addons_server_object_menu
        ;;
      2)
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
