#!/usr/bin/env bash
# shellcheck shell=bash

validate_email_user() {
  # args: email (username@protocol)
  local email="${1:-}"
  [[ "${email}" =~ ^[A-Za-z0-9._-]+@(vless|vmess|trojan)$ ]]
}

is_default_xray_email_or_tag() {
  # Default/bawaan Xray (disembunyikan dari menu WARP per-user):
  # default@(vless|vmess|trojan)-(tcp|ws|hup|xhttp|xhttp3|grpc)
  local s="${1:-}"
  [[ "${s}" =~ ^default@(vless|vmess|trojan)-(tcp|ws|hup|grpc|xhttp|xhttp3)$ ]]
}

is_readonly_geosite_domain() {
  # Geosite ini readonly (jangan disentuh), tampilkan di menu tapi jangan diubah:
  # apple, meta, google, openai, spotify, netflix, reddit
  local ent="${1:-}"
  case "${ent}" in
    geosite:apple|geosite:meta|geosite:google|geosite:openai|geosite:spotify|geosite:netflix|geosite:reddit)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

routing_custom_domain_entry_valid() {
  local ent="${1:-}"
  ent="$(echo "${ent}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  [[ -n "${ent}" ]] || return 1

  if [[ "${ent}" =~ ^geosite:[a-z0-9._:-]+$ ]]; then
    return 0
  fi

  # Accept plain domains / wildcard domains and reject obvious garbage such as "5".
  if [[ "${ent}" =~ ^(\*\.)?[a-z0-9][a-z0-9._-]*\.[a-z0-9._-]+$ ]] && [[ "${ent}" != *..* ]]; then
    return 0
  fi

  return 1
}

routing_load_jsonc() {
  local path="${1:-}"
  python3 - <<'PY' "${path}" 2>/dev/null
import json
import sys

path = sys.argv[1]

def strip_json_comments(text):
  result = []
  i = 0
  in_string = False
  escape = False
  length = len(text)
  while i < length:
    ch = text[i]
    nxt = text[i + 1] if i + 1 < length else ""
    if in_string:
      result.append(ch)
      if escape:
        escape = False
      elif ch == "\\":
        escape = True
      elif ch == '"':
        in_string = False
      i += 1
      continue
    if ch == '"':
      in_string = True
      result.append(ch)
      i += 1
      continue
    if ch == "/" and nxt == "/":
      i += 2
      while i < length and text[i] not in "\r\n":
        i += 1
      continue
    if ch == "/" and nxt == "*":
      i += 2
      while i + 1 < length and not (text[i] == "*" and text[i + 1] == "/"):
        i += 1
      i = min(i + 2, length)
      continue
    result.append(ch)
    i += 1
  return "".join(result)

with open(path, "r", encoding="utf-8") as handle:
  data = json.loads(strip_json_comments(handle.read()))
print(json.dumps(data, ensure_ascii=False))
PY
}

xray_routing_readonly_geosite_rule_print() {
  # Menampilkan rule geosite template (readonly) dari 30-routing.json
  # Rule ini dibuat oleh setup_modular.sh dan TIDAK boleh diedit dari menu.
  need_python3
  [[ -f "${XRAY_ROUTING_CONF}" ]] || return 0
  python3 - <<'PY' "$(routing_load_jsonc "${XRAY_ROUTING_CONF}")" 2>/dev/null || true
import json, sys

src=json.loads(sys.argv[1])
targets=[
  "geosite:apple",
  "geosite:meta",
  "geosite:google",
  "geosite:openai",
  "geosite:spotify",
  "geosite:netflix",
  "geosite:reddit",
]
tset=set(targets)

cfg=src

rules=((cfg.get("routing") or {}).get("rules") or [])
found=None
for r in rules:
  if not isinstance(r, dict):
    continue
  if r.get("type") != "field":
    continue
  dom=r.get("domain") or []
  if not isinstance(dom, list):
    continue
  if any(isinstance(x,str) and x in tset for x in dom):
    found=r
    break

if not found:
  print("  (rule readonly geosite tidak ditemukan)")
  raise SystemExit(0)

out="-"
if isinstance(found.get("outboundTag"), str) and found.get("outboundTag"):
  out=found.get("outboundTag")

print(f"OutboundTag : {out} (readonly)")
dom=found.get("domain") or []
for i, x in enumerate(targets, start=1):
  if x in dom:
    print(f"  {i:>2}. {x}")
PY
}


xray_routing_default_rule_get() {
  # prints: mode=<direct|warp|unknown> tag=<tag-or-empty>
  local src_file="${1:-${XRAY_ROUTING_CONF}}"
  if [[ ! -f "${src_file}" ]]; then
    printf 'mode=unknown\ntag=\n'
    return 0
  fi
  need_python3
  python3 - <<'PY' "$(routing_load_jsonc "${src_file}")"
import json, sys
cfg=json.loads(sys.argv[1])
routing=(cfg.get('routing') or {})
rules=routing.get('rules') or []
mode='unknown'
tag=''
def is_default_rule(r):
  if not isinstance(r, dict):
    return False
  if r.get('type') != 'field':
    return False
  port=str(r.get('port','')).strip()
  if port not in ('1-65535','0-65535'):
    return False
  # Keep this in sync with the writer-side heuristic below.
  if r.get('user') or r.get('domain') or r.get('ip') or r.get('protocol'):
    return False
  return True

target=None
for r in rules:
  if is_default_rule(r):
    target=r
# pick last matching
if isinstance(target, dict):
  ot=target.get('outboundTag')
  if isinstance(ot, str) and ot:
    tag=ot
    if ot == 'warp':
      mode='warp'
    elif ot == 'direct':
      mode='direct'
    else:
      mode='unknown'
print(f"mode={mode}")
print(f"tag={tag}")
PY
}

xray_routing_default_rule_set() {
  # args: mode direct|warp
  local mode="$1"
  local tmp backup backup_out rc
  need_python3

  [[ -f "${XRAY_ROUTING_CONF}" ]] || die "Xray routing conf tidak ditemukan: ${XRAY_ROUTING_CONF}"
  ensure_path_writable "${XRAY_ROUTING_CONF}"

  backup="$(xray_backup_path_prepare "${XRAY_ROUTING_CONF}")"
  backup_out="$(xray_backup_path_prepare "${XRAY_OUTBOUNDS_CONF}")"
  tmp="${WORK_DIR}/30-routing.json.tmp"

  set +e
  (
    flock -x 200
    cp -a "${XRAY_ROUTING_CONF}" "${backup}" || exit 1
    cp -a "${XRAY_OUTBOUNDS_CONF}" "${backup_out}" || exit 1
    python3 - <<'PY' "${XRAY_ROUTING_CONF}" "${XRAY_OUTBOUNDS_CONF}" "${tmp}" "${mode}" "${SPEED_OUTBOUND_TAG_PREFIX}" || exit 1
import json, sys
src, ob_src, dst, mode, speed_out_prefix = sys.argv[1:6]
with open(src,'r',encoding='utf-8') as f:
  cfg=json.load(f)

routing=(cfg.get('routing') or {})
rules=routing.get('rules')
if not isinstance(rules, list):
  raise SystemExit("Invalid routing config: routing.rules bukan list")

def is_default_rule(r):
  # BUG-14 fix: added additional checks to reduce false positives.
  # A rule with port='1-65535' alone is ambiguous; we also require that
  # it has no 'user', 'domain', 'ip', or 'protocol' filters (which would
  # indicate a more specific rule rather than the catch-all default).
  if not isinstance(r, dict): return False
  if r.get('type') != 'field': return False
  port=str(r.get('port','')).strip()
  if port not in ('1-65535','0-65535'): return False
  # A genuine catch-all default rule should not have specific user/domain/ip/protocol filters
  if r.get('user') or r.get('domain') or r.get('ip') or r.get('protocol'):
    return False
  return True

idx=None
for i,r in enumerate(rules):
  if is_default_rule(r):
    idx=i

if idx is None:
  raise SystemExit("Default rule (port 1-65535) tidak ditemukan")

try:
  with open(ob_src,'r',encoding='utf-8') as f:
    ob_cfg=json.load(f)
except Exception:
  ob_cfg={}

def list_outbound_tags():
  out=[]
  seen=set()
  for o in (ob_cfg.get('outbounds') or []):
    if not isinstance(o, dict):
      continue
    t=o.get('tag')
    if not isinstance(t, str):
      continue
    t=t.strip()
    if not t or t in seen:
      continue
    seen.add(t)
    out.append(t)
  return out

def pick_default_selector(tags):
  deny={"api","blocked"}
  sel=[]
  for t in ("direct","warp"):
    if t in tags and t not in sel:
      sel.append(t)
  if not sel:
    for t in tags:
      if t in deny:
        continue
      if speed_out_prefix and isinstance(t, str) and t.startswith(speed_out_prefix):
        continue
      if t in sel:
        continue
      sel.append(t)
      if len(sel) >= 2:
        break
  return sel

r=rules[idx]
if mode == 'direct':
  r['outboundTag']='direct'
elif mode == 'warp':
  r['outboundTag']='warp'
else:
  raise SystemExit("Mode tidak dikenal: " + mode)

rules[idx]=r
routing['rules']=rules
cfg['routing']=routing

with open(dst,'w',encoding='utf-8') as f:
  json.dump(cfg,f,ensure_ascii=False,indent=2)
  f.write("\n")
PY
    xray_write_file_atomic "${XRAY_ROUTING_CONF}" "${tmp}" || {
      restore_file_if_exists "${backup}" "${XRAY_ROUTING_CONF}"
      exit 1
    }

    if ! xray_confdir_syntax_test; then
      restore_file_if_exists "${backup}" "${XRAY_ROUTING_CONF}"
      exit 87
    fi

    if ! xray_routing_restart_checked; then
      if ! restore_file_if_exists "${backup}" "${XRAY_ROUTING_CONF}"; then
        exit 1
      fi
      xray_routing_restart_checked || exit 1
      exit 86
    fi
  ) 200>"${ROUTING_LOCK_FILE}"
  rc=$?
  set -e

  xray_txn_rc_or_die "${rc}" \
    "Gagal update routing (rollback ke backup: ${backup})" \
    "xray tidak aktif setelah update routing default. Config di-rollback ke backup: ${backup}" \
    "Konfigurasi xray invalid setelah update routing default. Config di-rollback ke backup: ${backup}"

  xray_routing_post_speed_sync_or_die "${backup}" "${backup_out}" "update routing default WARP"
}

xray_routing_rule_toggle_user_outbound() {
  # args: marker outboundTag email on|off
  local marker="$1"
  local outbound="$2"
  local email="$3"
  local onoff="$4"
  local tmp backup rc

  need_python3
  [[ -f "${XRAY_ROUTING_CONF}" ]] || die "Xray routing conf tidak ditemukan: ${XRAY_ROUTING_CONF}"
  ensure_path_writable "${XRAY_ROUTING_CONF}"
  backup="$(xray_backup_path_prepare "${XRAY_ROUTING_CONF}")"
  tmp="${WORK_DIR}/30-routing.json.tmp"

  set +e
  (
    flock -x 200
    cp -a "${XRAY_ROUTING_CONF}" "${backup}" || exit 1
    python3 - <<'PY' "${XRAY_ROUTING_CONF}" "${tmp}" "${marker}" "${outbound}" "${email}" "${onoff}" || exit 1
import json, sys
src, dst, marker, outbound, email, onoff = sys.argv[1:7]
enable = (onoff.lower() == 'on')

with open(src,'r',encoding='utf-8') as f:
  cfg=json.load(f)
routing=(cfg.get('routing') or {})
rules=routing.get('rules')
if not isinstance(rules, list):
  raise SystemExit("Invalid routing config: routing.rules bukan list")

def is_default_rule(r):
  # BUG-14 fix: added additional checks to reduce false positives.
  # A rule with port='1-65535' alone is ambiguous; we also require that
  # it has no 'user', 'domain', 'ip', or 'protocol' filters (which would
  # indicate a more specific rule rather than the catch-all default).
  if not isinstance(r, dict): return False
  if r.get('type') != 'field': return False
  port=str(r.get('port','')).strip()
  if port not in ('1-65535','0-65535'): return False
  # A genuine catch-all default rule should not have specific user/domain/ip/protocol filters
  if r.get('user') or r.get('domain') or r.get('ip') or r.get('protocol'):
    return False
  return True

default_idx=None
for i,r in enumerate(rules):
  if is_default_rule(r):
    default_idx=i

if default_idx is None:
  raise SystemExit("Default rule tidak ditemukan, tidak bisa insert rule baru")

rule_idx=None
for i,r in enumerate(rules):
  if not isinstance(r, dict): continue
  if r.get('type') != 'field': continue
  if r.get('outboundTag') != outbound: continue
  u=r.get('user') or []
  # BUG-13 fix: explicitly require rule has a 'user' field (not 'inboundTag').
  # Without this check, a per-inbound rule with the same outboundTag could be
  # mistakenly matched and modified when looking for a per-user rule.
  if not isinstance(u, list) or 'inboundTag' in r:
    continue
  if marker in u:
    rule_idx=i
    break

if rule_idx is None:
  # Insert before default rule
  newr={"type":"field","user":[marker],"outboundTag":outbound}
  rules.insert(default_idx, newr)
  rule_idx=default_idx

r=rules[rule_idx]
u=r.get('user') or []
if not isinstance(u, list):
  u=[]
# Ensure marker is first
u=[x for x in u if x != marker]
u.insert(0, marker)

if enable:
  if email not in u:
    u.append(email)
else:
  u=[x for x in u if x != email]
  # Keep marker only

r['user']=u
rules[rule_idx]=r
routing['rules']=rules
cfg['routing']=routing

with open(dst,'w',encoding='utf-8') as f:
  json.dump(cfg,f,ensure_ascii=False,indent=2)
  f.write("\n")
PY
    xray_write_file_atomic "${XRAY_ROUTING_CONF}" "${tmp}" || {
      restore_file_if_exists "${backup}" "${XRAY_ROUTING_CONF}"
      exit 1
    }
    if ! xray_routing_restart_checked; then
      if ! restore_file_if_exists "${backup}" "${XRAY_ROUTING_CONF}"; then
        exit 1
      fi
      xray_routing_restart_checked || exit 1
      exit 86
    fi
  ) 200>"${ROUTING_LOCK_FILE}"
  rc=$?
  set -e

  xray_txn_rc_or_die "${rc}" \
    "Gagal update routing (rollback ke backup: ${backup})" \
    "xray tidak aktif setelah update routing per-user warp/direct. Config di-rollback ke backup: ${backup}"
  return 0
}

xray_routing_rule_set_user_outbound_mode() {
  # args: email mode(direct|warp|off)
  local email="$1"
  local mode="$2"
  local tmp backup backup_out rc

  need_python3
  [[ -f "${XRAY_ROUTING_CONF}" ]] || die "Xray routing conf tidak ditemukan: ${XRAY_ROUTING_CONF}"
  ensure_path_writable "${XRAY_ROUTING_CONF}"
  backup="$(xray_backup_path_prepare "${XRAY_ROUTING_CONF}")"
  backup_out="$(xray_backup_path_prepare "${XRAY_OUTBOUNDS_CONF}")"
  tmp="${WORK_DIR}/30-routing.user-mode.tmp"

  set +e
  (
    flock -x 200
    cp -a "${XRAY_ROUTING_CONF}" "${backup}" || exit 1
    cp -a "${XRAY_OUTBOUNDS_CONF}" "${backup_out}" || exit 1
    python3 - <<'PY' "${XRAY_ROUTING_CONF}" "${tmp}" "${email}" "${mode}" || exit 1
import json, sys

src, dst, email, mode = sys.argv[1:5]
mode = (mode or "").strip().lower()
if mode not in {"direct", "warp", "off"}:
  raise SystemExit("Mode user harus direct|warp|off.")

with open(src, 'r', encoding='utf-8') as f:
  cfg = json.load(f)
routing = cfg.get('routing') or {}
rules = routing.get('rules')
if not isinstance(rules, list):
  raise SystemExit("Invalid routing config: routing.rules bukan list")

def is_default_rule(r):
  if not isinstance(r, dict): return False
  if r.get('type') != 'field': return False
  port = str(r.get('port', '')).strip()
  if port not in ('1-65535', '0-65535'): return False
  if r.get('user') or r.get('domain') or r.get('ip') or r.get('protocol'):
    return False
  return True

def find_rule_idx(marker, outbound):
  for i, r in enumerate(rules):
    if not isinstance(r, dict): continue
    if r.get('type') != 'field': continue
    if r.get('outboundTag') != outbound: continue
    users = r.get('user') or []
    if not isinstance(users, list) or 'inboundTag' in r:
      continue
    if marker in users:
      return i
  return -1

default_idx = -1
for i, r in enumerate(rules):
  if is_default_rule(r):
    default_idx = i
if default_idx < 0:
  raise SystemExit("Default rule tidak ditemukan, tidak bisa insert rule baru")

def toggle_user_marker(marker, outbound, enable):
  global default_idx
  idxs = []
  merged = []
  seen = set()
  for i, r in enumerate(rules):
    if not isinstance(r, dict): continue
    if r.get('type') != 'field': continue
    if r.get('outboundTag') != outbound: continue
    users = r.get('user') or []
    if not isinstance(users, list) or 'inboundTag' in r:
      continue
    if marker not in users:
      continue
    idxs.append(i)
    for u in users:
      if not isinstance(u, str):
        continue
      u = u.strip()
      if not u or u == marker or u in seen:
        continue
      seen.add(u)
      merged.append(u)
  idx = idxs[0] if idxs else -1
  for dup_idx in reversed(idxs[1:]):
    rules.pop(dup_idx)
    if dup_idx < default_idx:
      default_idx -= 1
  if idx < 0 and not enable:
    return
  if idx < 0 and enable:
    rules.insert(default_idx, {"type": "field", "user": [marker], "outboundTag": outbound})
    idx = default_idx
    default_idx += 1
    merged = []
  rule = rules[idx]
  if not isinstance(rule, dict):
    rule = {"type": "field", "user": [marker], "outboundTag": outbound}
  users = [u for u in merged if u != email]
  if enable and email not in users:
    users.append(email)
  rule['type'] = 'field'
  rule['outboundTag'] = outbound
  rule['user'] = [marker] + users
  rules[idx] = rule

if mode == 'direct':
  toggle_user_marker("dummy-warp-user", "warp", False)
  toggle_user_marker("dummy-direct-user", "direct", True)
elif mode == 'warp':
  toggle_user_marker("dummy-direct-user", "direct", False)
  toggle_user_marker("dummy-warp-user", "warp", True)
else:
  toggle_user_marker("dummy-direct-user", "direct", False)
  toggle_user_marker("dummy-warp-user", "warp", False)

routing['rules'] = rules
cfg['routing'] = routing
with open(dst, 'w', encoding='utf-8') as f:
  json.dump(cfg, f, ensure_ascii=False, indent=2)
  f.write("\n")
PY
    xray_write_file_atomic "${XRAY_ROUTING_CONF}" "${tmp}" || {
      restore_file_if_exists "${backup}" "${XRAY_ROUTING_CONF}"
      exit 1
    }
    if ! xray_routing_restart_checked; then
      if ! restore_file_if_exists "${backup}" "${XRAY_ROUTING_CONF}"; then
        exit 1
      fi
      xray_routing_restart_checked || exit 1
      exit 86
    fi
  ) 200>"${ROUTING_LOCK_FILE}"
  rc=$?
  set -e

  xray_txn_rc_or_die "${rc}" \
    "Gagal update routing (rollback ke backup: ${backup})" \
    "xray tidak aktif setelah update routing per-user warp/direct. Config di-rollback ke backup: ${backup}"

  xray_routing_post_speed_sync_or_die "${backup}" "${backup_out}" "update routing WARP per-user"
  return 0
}

xray_routing_rule_toggle_inbounds_outbound() {
  # args: marker outboundTag comma_inboundTags on|off
  local marker="$1"
  local outbound="$2"
  local tags_csv="$3"
  local onoff="$4"
  local tmp backup rc

  need_python3
  [[ -f "${XRAY_ROUTING_CONF}" ]] || die "Xray routing conf tidak ditemukan: ${XRAY_ROUTING_CONF}"
  ensure_path_writable "${XRAY_ROUTING_CONF}"
  backup="$(xray_backup_path_prepare "${XRAY_ROUTING_CONF}")"
  tmp="${WORK_DIR}/30-routing.json.tmp"

  set +e
  (
    flock -x 200
    cp -a "${XRAY_ROUTING_CONF}" "${backup}" || exit 1
    python3 - <<'PY' "${XRAY_ROUTING_CONF}" "${tmp}" "${marker}" "${outbound}" "${tags_csv}" "${onoff}" || exit 1
import json, sys
src, dst, marker, outbound, tags_csv, onoff = sys.argv[1:7]
enable = (onoff.lower() == 'on')
tags=[t.strip() for t in tags_csv.split(",") if t.strip()]

with open(src,'r',encoding='utf-8') as f:
  cfg=json.load(f)
routing=(cfg.get('routing') or {})
rules=routing.get('rules')
if not isinstance(rules, list):
  raise SystemExit("Invalid routing config: routing.rules bukan list")

def is_default_rule(r):
  # BUG-14 fix: added additional checks to reduce false positives.
  # A rule with port='1-65535' alone is ambiguous; we also require that
  # it has no 'user', 'domain', 'ip', or 'protocol' filters (which would
  # indicate a more specific rule rather than the catch-all default).
  if not isinstance(r, dict): return False
  if r.get('type') != 'field': return False
  port=str(r.get('port','')).strip()
  if port not in ('1-65535','0-65535'): return False
  # A genuine catch-all default rule should not have specific user/domain/ip/protocol filters
  if r.get('user') or r.get('domain') or r.get('ip') or r.get('protocol'):
    return False
  return True

default_idx=None
for i,r in enumerate(rules):
  if is_default_rule(r):
    default_idx=i
if default_idx is None:
  raise SystemExit("Default rule tidak ditemukan, tidak bisa insert rule baru")

rule_idx=None
for i,r in enumerate(rules):
  if not isinstance(r, dict): continue
  if r.get('type') != 'field': continue
  if r.get('outboundTag') != outbound: continue
  ib=r.get('inboundTag') or []
  if isinstance(ib, list) and marker in ib:
    rule_idx=i
    break

if rule_idx is None:
  newr={"type":"field","inboundTag":[marker],"outboundTag":outbound}
  rules.insert(default_idx, newr)
  rule_idx=default_idx

r=rules[rule_idx]
ib=r.get('inboundTag') or []
if not isinstance(ib, list):
  ib=[]
# Ensure marker first
ib=[x for x in ib if x != marker]
ib.insert(0, marker)

if enable:
  for t in tags:
    if t not in ib:
      ib.append(t)
else:
  ib=[x for x in ib if x not in tags]
  # Keep marker only

r['inboundTag']=ib
rules[rule_idx]=r
routing['rules']=rules
cfg['routing']=routing

with open(dst,'w',encoding='utf-8') as f:
  json.dump(cfg,f,ensure_ascii=False,indent=2)
  f.write("\n")
PY
    xray_write_file_atomic "${XRAY_ROUTING_CONF}" "${tmp}" || {
      restore_file_if_exists "${backup}" "${XRAY_ROUTING_CONF}"
      exit 1
    }
    if ! xray_routing_restart_checked; then
      if ! restore_file_if_exists "${backup}" "${XRAY_ROUTING_CONF}"; then
        exit 1
      fi
      xray_routing_restart_checked || exit 1
      exit 86
    fi
  ) 200>"${ROUTING_LOCK_FILE}"
  rc=$?
  set -e

  xray_txn_rc_or_die "${rc}" \
    "Gagal update routing (rollback ke backup: ${backup})" \
    "xray tidak aktif setelah update routing per-inbound warp/direct. Config di-rollback ke backup: ${backup}"
  return 0
}

xray_routing_rule_set_inbound_outbound_mode() {
  # args: inbound_tag mode(direct|warp|off)
  local tag="$1"
  local mode="$2"
  local tmp backup backup_out rc

  need_python3
  [[ -f "${XRAY_ROUTING_CONF}" ]] || die "Xray routing conf tidak ditemukan: ${XRAY_ROUTING_CONF}"
  ensure_path_writable "${XRAY_ROUTING_CONF}"
  backup="$(xray_backup_path_prepare "${XRAY_ROUTING_CONF}")"
  backup_out="$(xray_backup_path_prepare "${XRAY_OUTBOUNDS_CONF}")"
  tmp="${WORK_DIR}/30-routing.inbound-mode.tmp"

  set +e
  (
    flock -x 200
    cp -a "${XRAY_ROUTING_CONF}" "${backup}" || exit 1
    cp -a "${XRAY_OUTBOUNDS_CONF}" "${backup_out}" || exit 1
    python3 - <<'PY' "${XRAY_ROUTING_CONF}" "${tmp}" "${tag}" "${mode}" || exit 1
import json, sys

src, dst, inbound_tag, mode = sys.argv[1:5]
mode = (mode or "").strip().lower()
if mode not in {"direct", "warp", "off"}:
  raise SystemExit("Mode inbound harus direct|warp|off.")

with open(src, 'r', encoding='utf-8') as f:
  cfg = json.load(f)
routing = cfg.get('routing') or {}
rules = routing.get('rules')
if not isinstance(rules, list):
  raise SystemExit("Invalid routing config: routing.rules bukan list")

def is_default_rule(r):
  if not isinstance(r, dict): return False
  if r.get('type') != 'field': return False
  port = str(r.get('port', '')).strip()
  if port not in ('1-65535', '0-65535'): return False
  if r.get('user') or r.get('domain') or r.get('ip') or r.get('protocol'):
    return False
  return True

def find_rule_idx(marker, outbound):
  for i, r in enumerate(rules):
    if not isinstance(r, dict): continue
    if r.get('type') != 'field': continue
    if r.get('outboundTag') != outbound: continue
    tags = r.get('inboundTag') or []
    if isinstance(tags, list) and marker in tags:
      return i
  return -1

default_idx = -1
for i, r in enumerate(rules):
  if is_default_rule(r):
    default_idx = i
if default_idx < 0:
  raise SystemExit("Default rule tidak ditemukan, tidak bisa insert rule baru")

def toggle_inbound_marker(marker, outbound, enable):
  global default_idx
  idxs = []
  merged = []
  seen = set()
  for i, r in enumerate(rules):
    if not isinstance(r, dict): continue
    if r.get('type') != 'field': continue
    if r.get('outboundTag') != outbound: continue
    tags = r.get('inboundTag') or []
    if not isinstance(tags, list) or marker not in tags:
      continue
    idxs.append(i)
    for tag in tags:
      if not isinstance(tag, str):
        continue
      tag = tag.strip()
      if not tag or tag == marker or tag in seen:
        continue
      seen.add(tag)
      merged.append(tag)
  idx = idxs[0] if idxs else -1
  for dup_idx in reversed(idxs[1:]):
    rules.pop(dup_idx)
    if dup_idx < default_idx:
      default_idx -= 1
  if idx < 0 and not enable:
    return
  if idx < 0 and enable:
    rules.insert(default_idx, {"type": "field", "inboundTag": [marker], "outboundTag": outbound})
    idx = default_idx
    default_idx += 1
    merged = []
  rule = rules[idx]
  if not isinstance(rule, dict):
    rule = {"type": "field", "inboundTag": [marker], "outboundTag": outbound}
  tags = [t for t in merged if t != inbound_tag]
  if enable and inbound_tag not in tags:
    tags.append(inbound_tag)
  rule['type'] = 'field'
  rule['outboundTag'] = outbound
  rule['inboundTag'] = [marker] + tags
  rules[idx] = rule

if mode == 'direct':
  toggle_inbound_marker("dummy-warp-inbounds", "warp", False)
  toggle_inbound_marker("dummy-direct-inbounds", "direct", True)
elif mode == 'warp':
  toggle_inbound_marker("dummy-direct-inbounds", "direct", False)
  toggle_inbound_marker("dummy-warp-inbounds", "warp", True)
else:
  toggle_inbound_marker("dummy-direct-inbounds", "direct", False)
  toggle_inbound_marker("dummy-warp-inbounds", "warp", False)

routing['rules'] = rules
cfg['routing'] = routing
with open(dst, 'w', encoding='utf-8') as f:
  json.dump(cfg, f, ensure_ascii=False, indent=2)
  f.write("\n")
PY
    xray_write_file_atomic "${XRAY_ROUTING_CONF}" "${tmp}" || {
      restore_file_if_exists "${backup}" "${XRAY_ROUTING_CONF}"
      exit 1
    }
    if ! xray_routing_restart_checked; then
      if ! restore_file_if_exists "${backup}" "${XRAY_ROUTING_CONF}"; then
        exit 1
      fi
      xray_routing_restart_checked || exit 1
      exit 86
    fi
  ) 200>"${ROUTING_LOCK_FILE}"
  rc=$?
  set -e

  xray_txn_rc_or_die "${rc}" \
    "Gagal update routing (rollback ke backup: ${backup})" \
    "xray tidak aktif setelah update routing per-inbound warp/direct. Config di-rollback ke backup: ${backup}"

  xray_routing_post_speed_sync_or_die "${backup}" "${backup_out}" "update routing WARP per-inbound"
  return 0
}

xray_list_inbounds_tags_by_protocol() {
  # args: proto
  local proto="$1"
  need_python3
  [[ -f "${XRAY_INBOUNDS_CONF}" ]] || return 0
  python3 - <<'PY' "${XRAY_INBOUNDS_CONF}" "${proto}"
import json, sys
src, proto = sys.argv[1:3]
with open(src,'r',encoding='utf-8') as f:
  cfg=json.load(f)
tags=[]
for ib in cfg.get('inbounds', []) or []:
  if not isinstance(ib, dict):
    continue
  if ib.get('protocol') != proto:
    continue
  tag=ib.get('tag')
  if isinstance(tag, str) and tag.strip():
    tags.append(tag.strip())
print(",".join(tags))
PY
}

xray_inbounds_all_tags_get() {
  need_python3
  [[ -f "${XRAY_INBOUNDS_CONF}" ]] || return 0
  python3 - <<'PY' "${XRAY_INBOUNDS_CONF}" 2>/dev/null || true
import json, re, sys
src=sys.argv[1]
def strip_json_comments(text):
  text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
  lines = []
  for line in text.splitlines():
    out = []
    i = 0
    in_str = False
    esc = False
    while i < len(line):
      ch = line[i]
      if in_str:
        out.append(ch)
        if esc:
          esc = False
        elif ch == '\\':
          esc = True
        elif ch == '"':
          in_str = False
        i += 1
        continue
      if ch == '"':
        in_str = True
        out.append(ch)
        i += 1
        continue
      if ch == '/' and i + 1 < len(line) and line[i + 1] == '/':
        break
      out.append(ch)
      i += 1
    lines.append(''.join(out))
  return '\n'.join(lines)
try:
  with open(src,'r',encoding='utf-8') as f:
    cfg=json.loads(strip_json_comments(f.read()))
except Exception:
  raise SystemExit(0)
tags=set()
for ib in (cfg.get('inbounds') or []):
  if not isinstance(ib, dict):
    continue
  tag=ib.get('tag')
  if isinstance(tag, str) and tag.strip():
    tags.add(tag.strip())
for t in sorted(tags):
  print(t)
PY
}


network_show_summary() {
  title
  echo "Network / Proxy Summary"
  hr

  if [[ -f "${XRAY_ROUTING_CONF}" ]]; then
    if xray_json_file_require_valid "${XRAY_ROUTING_CONF}" "Xray routing config"; then
      xray_routing_default_rule_get
    else
      warn "Ringkasan routing dilewati karena JSON routing invalid."
    fi
    hr
  else
    warn "Routing conf tidak ditemukan: ${XRAY_ROUTING_CONF}"
  fi

  echo "WARP mode: $(warp_mode_state_get)"
  if svc_exists "$(warp_backend_service_name_get)"; then
    svc_status_line "$(warp_backend_service_name_get)"
  else
    echo "$(warp_backend_display_name_get): (tidak terpasang)"
  fi
  hr
  pause
}

xray_outbound_tags_list_get() {
  # args: [outbounds_conf]
  local src_file="${1:-${XRAY_OUTBOUNDS_CONF}}"
  need_python3
  [[ -f "${src_file}" ]] || return 0
  python3 - <<'PY' "$(routing_load_jsonc "${src_file}")" 2>/dev/null || true
import json, sys

try:
  cfg = json.loads(sys.argv[1])
except Exception:
  raise SystemExit(0)

outbounds = cfg.get('outbounds') or []
seen = set()
for ob in outbounds:
  if not isinstance(ob, dict):
    continue
  tag = ob.get('tag')
  if not isinstance(tag, str):
    continue
  tag = tag.strip()
  if not tag or tag in seen:
    continue
  seen.add(tag)
  print(tag)
PY
}

routing_outbound_summary_render() {
  local default_line mode tag
  local -a outbounds=()
  local -a direct_users=() warp_users=() direct_inbounds=() warp_inbounds=()
  local direct_user_count warp_user_count direct_inbound_count warp_inbound_count

  title
  echo "Routing & Outbound Summary"
  hr

  if [[ -f "${XRAY_ROUTING_CONF}" ]]; then
    if xray_json_file_require_valid "${XRAY_ROUTING_CONF}" "Xray routing config"; then
      default_line="$(xray_routing_default_rule_get)"
      mode="$(printf '%s\n' "${default_line}" | awk -F'=' '/^mode=/{print $2; exit}' 2>/dev/null || true)"
      tag="$(printf '%s\n' "${default_line}" | awk -F'=' '/^tag=/{print $2; exit}' 2>/dev/null || true)"
      echo "Default route : mode=${mode:--} tag=${tag:--}"
    else
      warn "Routing conf tidak valid."
    fi
  else
    warn "Routing conf tidak ditemukan: ${XRAY_ROUTING_CONF}"
  fi

  echo "WARP mode     : $(warp_mode_state_get)"
  echo "WARP global   : $(warp_global_mode_pretty_get)"
  if svc_exists "$(warp_backend_service_name_get)"; then
    svc_status_line "$(warp_backend_service_name_get)"
  else
    echo "$(warp_backend_display_name_get): (tidak terpasang)"
  fi
  hr

  if [[ -f "${XRAY_OUTBOUNDS_CONF}" ]]; then
    if xray_json_file_require_valid "${XRAY_OUTBOUNDS_CONF}" "Xray outbounds config"; then
      mapfile -t outbounds < <(xray_outbound_tags_list_get)
      echo "Outbound tags (${#outbounds[@]}):"
      local tag_item
      for tag_item in "${outbounds[@]}"; do
        [[ -n "${tag_item}" ]] || continue
        echo "  - ${tag_item}"
      done
    else
      warn "Outbound conf tidak valid."
    fi
  else
    warn "Outbound conf tidak ditemukan: ${XRAY_OUTBOUNDS_CONF}"
  fi
  hr

  mapfile -t direct_users < <(xray_routing_rule_user_list_get "dummy-direct-user" "direct" 2>/dev/null || true)
  mapfile -t warp_users < <(xray_routing_rule_user_list_get "dummy-warp-user" "warp" 2>/dev/null || true)
  mapfile -t direct_inbounds < <(xray_routing_rule_inbound_list_get "dummy-direct-inbounds" "direct" 2>/dev/null || true)
  mapfile -t warp_inbounds < <(xray_routing_rule_inbound_list_get "dummy-warp-inbounds" "warp" 2>/dev/null || true)
  direct_user_count="${#direct_users[@]}"
  warp_user_count="${#warp_users[@]}"
  direct_inbound_count="${#direct_inbounds[@]}"
  warp_inbound_count="${#warp_inbounds[@]}"

  echo "Route buckets:"
  echo "  direct-google : geosite:google, geosite:apple"
  echo "  direct-app    : geosite:openai, geosite:meta"
  echo "  warp-social   : geosite:spotify, geosite:netflix, geosite:reddit"
  echo "  blocked       : geosite:private, geoip:private, bittorrent"
  echo "  dns-out       : dns-in"
  hr

  echo "User / inbound overrides:"
  echo "  direct users  : ${direct_user_count}"
  if (( direct_user_count > 0 )); then
    printf '    - %s\n' "${direct_users[@]}"
  fi
  echo "  warp users    : ${warp_user_count}"
  if (( warp_user_count > 0 )); then
    printf '    - %s\n' "${warp_users[@]}"
  fi
  echo "  direct inb    : ${direct_inbound_count}"
  if (( direct_inbound_count > 0 )); then
    printf '    - %s\n' "${direct_inbounds[@]}"
  fi
  echo "  warp inb      : ${warp_inbound_count}"
  if (( warp_inbound_count > 0 )); then
    printf '    - %s\n' "${warp_inbounds[@]}"
  fi
  hr
  pause
}

xray_routing_outbound_default_route_render() {
  local default_line mode tag
  title
  echo "Default Route"
  hr
  if [[ -f "${XRAY_ROUTING_CONF}" ]]; then
    if xray_json_file_require_valid "${XRAY_ROUTING_CONF}" "Xray routing config"; then
      default_line="$(xray_routing_default_rule_get)"
      mode="$(printf '%s\n' "${default_line}" | awk -F'=' '/^mode=/{print $2; exit}' 2>/dev/null || true)"
      tag="$(printf '%s\n' "${default_line}" | awk -F'=' '/^tag=/{print $2; exit}' 2>/dev/null || true)"
      echo "Current mode : ${mode:--}"
      echo "Current tag  : ${tag:--}"
    else
      warn "Routing conf tidak valid."
      pause
      return 0
    fi
  else
    warn "Routing conf tidak ditemukan: ${XRAY_ROUTING_CONF}"
    pause
    return 0
  fi
  hr
  echo "Mode yang tersedia:"
  echo "  1) direct"
  echo "  2) warp"
  echo "  0) Back"
  hr
  local c=""
  read -r -p "Pilih: " c || { echo; return 0; }
  case "${c}" in
    1|direct)
      if confirm_yn_or_back "Terapkan default route direct sekarang?"; then
        xray_routing_default_rule_set direct
        log "Default route disetel ke direct."
      fi
      ;;
    2|warp)
      if confirm_yn_or_back "Terapkan default route warp sekarang?"; then
        xray_routing_default_rule_set warp
        log "Default route disetel ke warp."
      fi
      ;;
    0|kembali|k|back|b)
      ;;
    *)
      invalid_choice
      ;;
  esac
  pause
}

xray_routing_outbound_user_overrides_render() {
  local -a direct_users=() warp_users=()
  local direct_user_count warp_user_count
  title
  echo "User Overrides"
  hr
  mapfile -t direct_users < <(xray_routing_rule_user_list_get "dummy-direct-user" "direct" 2>/dev/null || true)
  mapfile -t warp_users < <(xray_routing_rule_user_list_get "dummy-warp-user" "warp" 2>/dev/null || true)
  direct_user_count="${#direct_users[@]}"
  warp_user_count="${#warp_users[@]}"
  echo "direct users : ${direct_user_count}"
  if (( direct_user_count > 0 )); then
    printf '  - %s\n' "${direct_users[@]}"
  fi
  echo "warp users   : ${warp_user_count}"
  if (( warp_user_count > 0 )); then
    printf '  - %s\n' "${warp_users[@]}"
  fi
  hr
  pause
}

xray_routing_outbound_inbound_overrides_render() {
  local -a direct_inbounds=() warp_inbounds=()
  local direct_inbound_count warp_inbound_count
  title
  echo "Inbound Overrides"
  hr
  mapfile -t direct_inbounds < <(xray_routing_rule_inbound_list_get "dummy-direct-inbounds" "direct" 2>/dev/null || true)
  mapfile -t warp_inbounds < <(xray_routing_rule_inbound_list_get "dummy-warp-inbounds" "warp" 2>/dev/null || true)
  direct_inbound_count="${#direct_inbounds[@]}"
  warp_inbound_count="${#warp_inbounds[@]}"
  echo "direct inb : ${direct_inbound_count}"
  if (( direct_inbound_count > 0 )); then
    printf '  - %s\n' "${direct_inbounds[@]}"
  fi
  echo "warp inb   : ${warp_inbound_count}"
  if (( warp_inbound_count > 0 )); then
    printf '  - %s\n' "${warp_inbounds[@]}"
  fi
  hr
  pause
}

xray_routing_outbound_domain_buckets_render() {
  title
  echo "Domain Buckets"
  hr
  echo "direct-google : geosite:google, geosite:apple"
  echo "direct-app    : geosite:openai, geosite:meta"
  echo "warp-social   : geosite:spotify, geosite:netflix, geosite:reddit"
  echo "blocked       : geosite:private, geoip:private, bittorrent"
  echo "dns-out       : dns-in"
  hr
  if [[ -f "${XRAY_ROUTING_CONF}" ]] && xray_json_file_require_valid "${XRAY_ROUTING_CONF}" "Xray routing config"; then
    xray_routing_readonly_geosite_rule_print || true
  fi
  hr
  pause
}

xray_routing_outbound_conflict_check_render() {
  local -a direct_users=() warp_users=() direct_inbounds=() warp_inbounds=()
  local user_conflicts=0 inbound_conflicts=0 entry
  declare -A direct_user_set=()
  declare -A warp_user_set=()
  declare -A direct_inbound_set=()
  declare -A warp_inbound_set=()

  title
  echo "Conflict Check"
  hr
  mapfile -t direct_users < <(xray_routing_rule_user_list_get "dummy-direct-user" "direct" 2>/dev/null || true)
  mapfile -t warp_users < <(xray_routing_rule_user_list_get "dummy-warp-user" "warp" 2>/dev/null || true)
  mapfile -t direct_inbounds < <(xray_routing_rule_inbound_list_get "dummy-direct-inbounds" "direct" 2>/dev/null || true)
  mapfile -t warp_inbounds < <(xray_routing_rule_inbound_list_get "dummy-warp-inbounds" "warp" 2>/dev/null || true)

  for entry in "${direct_users[@]}"; do
    [[ -n "${entry}" ]] && direct_user_set["${entry}"]=1
  done
  for entry in "${warp_users[@]}"; do
    [[ -n "${entry}" ]] && warp_user_set["${entry}"]=1
  done
  for entry in "${direct_inbounds[@]}"; do
    [[ -n "${entry}" ]] && direct_inbound_set["${entry}"]=1
  done
  for entry in "${warp_inbounds[@]}"; do
    [[ -n "${entry}" ]] && warp_inbound_set["${entry}"]=1
  done

  for entry in "${!direct_user_set[@]}"; do
    [[ -n "${warp_user_set[${entry}]:-}" ]] && ((user_conflicts+=1))
  done
  for entry in "${!direct_inbound_set[@]}"; do
    [[ -n "${warp_inbound_set[${entry}]:-}" ]] && ((inbound_conflicts+=1))
  done

  echo "user conflicts    : ${user_conflicts}"
  echo "inbound conflicts : ${inbound_conflicts}"
  hr
  echo "Catatan: jika nilai > 0, ada entri yang terikat ke direct dan warp sekaligus."
  hr
  pause
}

routing_outbound_summary_menu() {
  while true; do
    title
    xray_network_menu_title "Routing & Outbound"
    hr
    echo "  1) Summary"
    echo "  2) Default Route"
    echo "  3) User Overrides"
    echo "  4) Inbound Overrides"
    echo "  5) Domain Buckets"
    echo "  6) Conflict Check"
    echo "  0) Back"
    hr
    read -r -p "Pilih: " c
    case "${c}" in
      1) routing_outbound_summary_render ;;
      2) xray_routing_outbound_default_route_render ;;
      3) xray_routing_outbound_user_overrides_render ;;
      4) xray_routing_outbound_inbound_overrides_render ;;
      5) xray_routing_outbound_domain_buckets_render ;;
      6) xray_routing_outbound_conflict_check_render ;;
      0|kembali|k|back|b) break ;;
      *) invalid_choice ;;
    esac
  done
}

warp_global_mode_get() {
  local src_file="${1:-${XRAY_ROUTING_CONF}}"
  xray_routing_default_rule_get "${src_file}" | awk -F'=' '/^mode=/{print $2; exit}' 2>/dev/null || true
}

# shellcheck disable=SC2120
warp_global_mode_pretty_get() {
  local mode
  mode="$(warp_global_mode_get "${1:-${XRAY_ROUTING_CONF}}")"
  case "${mode}" in
    warp) echo "warp" ;;
    direct) echo "direct" ;;
    *) echo "unknown" ;;
  esac
}

xray_routing_rule_user_list_get() {
  # args: marker outboundTag [routing_conf]
  local marker="$1"
  local outbound="$2"
  local src_file="${3:-${XRAY_ROUTING_CONF}}"
  need_python3
  [[ -f "${src_file}" ]] || return 0
  python3 - <<'PY' "${src_file}" "${marker}" "${outbound}" 2>/dev/null || true
import json, sys
src, marker, outbound = sys.argv[1:4]
try:
  with open(src,'r',encoding='utf-8') as f:
    cfg=json.load(f)
except Exception:
  raise SystemExit(0)
rules=((cfg.get('routing') or {}).get('rules') or [])
out=[]
seen=set()
for r in rules:
  if not isinstance(r, dict): 
    continue
  if r.get('type') != 'field':
    continue
  if r.get('outboundTag') != outbound:
    continue
  u=r.get('user') or []
  if not isinstance(u, list):
    continue
  if marker in u:
    for x in u:
      if isinstance(x, str) and x and x != marker and x not in seen:
        out.append(x)
        seen.add(x)
for x in out:
  print(x)
PY
}

xray_routing_rule_inbound_list_get() {
  # args: marker outboundTag [routing_conf]
  local marker="$1"
  local outbound="$2"
  local src_file="${3:-${XRAY_ROUTING_CONF}}"
  need_python3
  [[ -f "${src_file}" ]] || return 0
  python3 - <<'PY' "${src_file}" "${marker}" "${outbound}" 2>/dev/null || true
import json, sys
src, marker, outbound = sys.argv[1:4]
try:
  with open(src,'r',encoding='utf-8') as f:
    cfg=json.load(f)
except Exception:
  raise SystemExit(0)
rules=((cfg.get('routing') or {}).get('rules') or [])
out=[]
seen=set()
for r in rules:
  if not isinstance(r, dict): 
    continue
  if r.get('type') != 'field':
    continue
  if r.get('outboundTag') != outbound:
    continue
  ib=r.get('inboundTag') or []
  if not isinstance(ib, list):
    continue
  if marker in ib:
    for x in ib:
      if isinstance(x, str) and x and x != marker and x not in seen:
        out.append(x)
        seen.add(x)
for x in out:
  print(x)
PY
}

xray_routing_custom_domain_list_get() {
  # args: marker outboundTag [routing_conf]
  local marker="$1"
  local outbound="$2"
  local src_file="${3:-${XRAY_ROUTING_CONF}}"
  need_python3
  [[ -f "${src_file}" ]] || return 0
  python3 - <<'PY' "${src_file}" "${marker}" "${outbound}" 2>/dev/null || true
import json, sys
src, marker, outbound = sys.argv[1:4]
try:
  with open(src,'r',encoding='utf-8') as f:
    cfg=json.load(f)
except Exception:
  raise SystemExit(0)
rules=((cfg.get('routing') or {}).get('rules') or [])
custom=[]
seen=set()
for r in rules:
  if not isinstance(r, dict):
    continue
  if r.get('type') != 'field':
    continue
  if r.get('outboundTag') != outbound:
    continue
  dom=r.get('domain') or []
  if isinstance(dom, list) and marker in dom:
    for x in dom:
      if isinstance(x, str) and x and x != marker and x not in seen:
        custom.append(x)
        seen.add(x)
for x in custom:
  print(x)
PY
}

xray_routing_candidate_prepare() {
  local -n _out_ref="$1"
  if [[ -n "${_out_ref}" && -f "${_out_ref}" ]]; then
    return 0
  fi
  if ! xray_json_file_require_valid "${XRAY_ROUTING_CONF}" "Xray routing config"; then
    return 1
  fi
  _out_ref="$(mktemp "${WORK_DIR}/routing-stage.XXXXXX.json" 2>/dev/null || true)"
  [[ -n "${_out_ref}" ]] || return 1
  cp -a "${XRAY_ROUTING_CONF}" "${_out_ref}" || {
    rm -f -- "${_out_ref}" >/dev/null 2>&1 || true
    _out_ref=""
    return 1
  }
  if ! xray_stage_origin_capture "${_out_ref}" "${XRAY_ROUTING_CONF}"; then
    xray_stage_candidate_cleanup "${_out_ref}"
    _out_ref=""
    return 1
  fi
  chmod 600 "${_out_ref}" >/dev/null 2>&1 || true
  return 0
}

xray_routing_default_rule_set_in_file() {
  # args: src_conf dst_conf mode direct|warp
  local src_conf="$1"
  local dst_conf="$2"
  local mode="$3"
  need_python3
  [[ -f "${src_conf}" ]] || return 1
  python3 - <<'PY' "${src_conf}" "${dst_conf}" "${mode}" || return 1
import json, os, sys, tempfile
src, dst, mode = sys.argv[1:4]
with open(src,'r',encoding='utf-8') as f:
  cfg=json.load(f)
routing=(cfg.get('routing') or {})
rules=routing.get('rules') or []
if not isinstance(rules, list):
  raise SystemExit("Invalid routing config: routing.rules bukan list")
def is_default_rule(r):
  if not isinstance(r, dict): return False
  if r.get('type') != 'field': return False
  port=str(r.get('port','')).strip()
  if port not in ('1-65535','0-65535'): return False
  if r.get('user') or r.get('domain') or r.get('ip') or r.get('protocol'):
    return False
  return True
idx=None
for i,r in enumerate(rules):
  if is_default_rule(r):
    idx=i
if idx is None:
  raise SystemExit("Default rule (port 1-65535) tidak ditemukan")
r=rules[idx]
if mode == 'direct':
  r['outboundTag']='direct'
elif mode == 'warp':
  r['outboundTag']='warp'
else:
  raise SystemExit("Mode tidak dikenal: " + mode)
rules[idx]=r
routing['rules']=rules
cfg['routing']=routing
dirn=os.path.dirname(dst) or "."
fd,tmp=tempfile.mkstemp(prefix=".tmp.",suffix=".json",dir=dirn)
try:
  with os.fdopen(fd,'w',encoding='utf-8') as f:
    json.dump(cfg,f,ensure_ascii=False,indent=2)
    f.write("\n")
    f.flush()
    os.fsync(f.fileno())
  os.replace(tmp,dst)
finally:
  try:
    if os.path.exists(tmp):
      os.remove(tmp)
  except Exception:
    pass
PY
}

xray_routing_rule_set_user_outbound_mode_in_file() {
  # args: src_conf dst_conf email mode(direct|warp|off)
  local src_conf="$1"
  local dst_conf="$2"
  local email="$3"
  local mode="$4"
  need_python3
  [[ -f "${src_conf}" ]] || return 1
  python3 - <<'PY' "${src_conf}" "${dst_conf}" "${email}" "${mode}" || return 1
import json, os, sys, tempfile
src, dst, email, mode = sys.argv[1:5]
mode = (mode or "").strip().lower()
if mode not in {"direct", "warp", "off"}:
  raise SystemExit("Mode user harus direct|warp|off.")
with open(src,'r',encoding='utf-8') as f:
  cfg=json.load(f)
routing = cfg.get('routing') or {}
rules = routing.get('rules')
if not isinstance(rules, list):
  raise SystemExit("Invalid routing config: routing.rules bukan list")
def is_default_rule(r):
  if not isinstance(r, dict): return False
  if r.get('type') != 'field': return False
  port = str(r.get('port', '')).strip()
  if port not in ('1-65535', '0-65535'): return False
  if r.get('user') or r.get('domain') or r.get('ip') or r.get('protocol'):
    return False
  return True
def find_rule_idx(marker, outbound):
  for i, r in enumerate(rules):
    if not isinstance(r, dict): continue
    if r.get('type') != 'field': continue
    if r.get('outboundTag') != outbound: continue
    users = r.get('user') or []
    if not isinstance(users, list) or 'inboundTag' in r:
      continue
    if marker in users:
      return i
  return -1
default_idx = -1
for i, r in enumerate(rules):
  if is_default_rule(r):
    default_idx = i
if default_idx < 0:
  raise SystemExit("Default rule tidak ditemukan, tidak bisa insert rule baru")
def toggle_user_marker(marker, outbound, enable):
  global default_idx
  idxs = []
  merged = []
  seen = set()
  for i, r in enumerate(rules):
    if not isinstance(r, dict): continue
    if r.get('type') != 'field': continue
    if r.get('outboundTag') != outbound: continue
    users = r.get('user') or []
    if not isinstance(users, list) or 'inboundTag' in r:
      continue
    if marker not in users:
      continue
    idxs.append(i)
    for u in users:
      if not isinstance(u, str):
        continue
      u = u.strip()
      if not u or u == marker or u in seen:
        continue
      seen.add(u)
      merged.append(u)
  idx = idxs[0] if idxs else -1
  for dup_idx in reversed(idxs[1:]):
    rules.pop(dup_idx)
    if dup_idx < default_idx:
      default_idx -= 1
  if idx < 0 and not enable:
    return
  if idx < 0 and enable:
    rules.insert(default_idx, {"type": "field", "user": [marker], "outboundTag": outbound})
    idx = default_idx
    default_idx += 1
    merged = []
  rule = rules[idx]
  if not isinstance(rule, dict):
    rule = {"type": "field", "user": [marker], "outboundTag": outbound}
  users = [u for u in merged if u != email]
  if enable and email not in users:
    users.append(email)
  rule['type'] = 'field'
  rule['outboundTag'] = outbound
  rule['user'] = [marker] + users
  rules[idx] = rule
if mode == 'direct':
  toggle_user_marker("dummy-warp-user", "warp", False)
  toggle_user_marker("dummy-direct-user", "direct", True)
elif mode == 'warp':
  toggle_user_marker("dummy-direct-user", "direct", False)
  toggle_user_marker("dummy-warp-user", "warp", True)
else:
  toggle_user_marker("dummy-direct-user", "direct", False)
  toggle_user_marker("dummy-warp-user", "warp", False)
routing['rules'] = rules
cfg['routing'] = routing
dirn=os.path.dirname(dst) or "."
fd,tmp=tempfile.mkstemp(prefix=".tmp.",suffix=".json",dir=dirn)
try:
  with os.fdopen(fd,'w',encoding='utf-8') as f:
    json.dump(cfg,f,ensure_ascii=False,indent=2)
    f.write("\n")
    f.flush()
    os.fsync(f.fileno())
  os.replace(tmp,dst)
finally:
  try:
    if os.path.exists(tmp):
      os.remove(tmp)
  except Exception:
    pass
PY
}

xray_routing_rule_set_inbound_outbound_mode_in_file() {
  # args: src_conf dst_conf inbound_tag mode(direct|warp|off)
  local src_conf="$1"
  local dst_conf="$2"
  local tag="$3"
  local mode="$4"
  need_python3
  [[ -f "${src_conf}" ]] || return 1
  python3 - <<'PY' "${src_conf}" "${dst_conf}" "${tag}" "${mode}" || return 1
import json, os, sys, tempfile
src, dst, inbound_tag, mode = sys.argv[1:5]
mode = (mode or "").strip().lower()
if mode not in {"direct", "warp", "off"}:
  raise SystemExit("Mode inbound harus direct|warp|off.")
with open(src, 'r', encoding='utf-8') as f:
  cfg = json.load(f)
routing = cfg.get('routing') or {}
rules = routing.get('rules')
if not isinstance(rules, list):
  raise SystemExit("Invalid routing config: routing.rules bukan list")
def is_default_rule(r):
  if not isinstance(r, dict): return False
  if r.get('type') != 'field': return False
  port = str(r.get('port', '')).strip()
  if port not in ('1-65535', '0-65535'): return False
  if r.get('user') or r.get('domain') or r.get('ip') or r.get('protocol'):
    return False
  return True
def find_rule_idx(marker, outbound):
  for i, r in enumerate(rules):
    if not isinstance(r, dict): continue
    if r.get('type') != 'field': continue
    if r.get('outboundTag') != outbound: continue
    tags = r.get('inboundTag') or []
    if isinstance(tags, list) and marker in tags:
      return i
  return -1
default_idx = -1
for i, r in enumerate(rules):
  if is_default_rule(r):
    default_idx = i
if default_idx < 0:
  raise SystemExit("Default rule tidak ditemukan, tidak bisa insert rule baru")
def toggle_inbound_marker(marker, outbound, enable):
  global default_idx
  idxs = []
  merged = []
  seen = set()
  for i, r in enumerate(rules):
    if not isinstance(r, dict): continue
    if r.get('type') != 'field': continue
    if r.get('outboundTag') != outbound: continue
    tags = r.get('inboundTag') or []
    if not isinstance(tags, list) or marker not in tags:
      continue
    idxs.append(i)
    for tag in tags:
      if not isinstance(tag, str):
        continue
      tag = tag.strip()
      if not tag or tag == marker or tag in seen:
        continue
      seen.add(tag)
      merged.append(tag)
  idx = idxs[0] if idxs else -1
  for dup_idx in reversed(idxs[1:]):
    rules.pop(dup_idx)
    if dup_idx < default_idx:
      default_idx -= 1
  if idx < 0 and not enable:
    return
  if idx < 0 and enable:
    rules.insert(default_idx, {"type": "field", "inboundTag": [marker], "outboundTag": outbound})
    idx = default_idx
    default_idx += 1
    merged = []
  rule = rules[idx]
  if not isinstance(rule, dict):
    rule = {"type": "field", "inboundTag": [marker], "outboundTag": outbound}
  tags = [t for t in merged if t != inbound_tag]
  if enable and inbound_tag not in tags:
    tags.append(inbound_tag)
  rule['type'] = 'field'
  rule['outboundTag'] = outbound
  rule['inboundTag'] = [marker] + tags
  rules[idx] = rule
if mode == 'direct':
  toggle_inbound_marker("dummy-warp-inbounds", "warp", False)
  toggle_inbound_marker("dummy-direct-inbounds", "direct", True)
elif mode == 'warp':
  toggle_inbound_marker("dummy-direct-inbounds", "direct", False)
  toggle_inbound_marker("dummy-warp-inbounds", "warp", True)
else:
  toggle_inbound_marker("dummy-direct-inbounds", "direct", False)
  toggle_inbound_marker("dummy-warp-inbounds", "warp", False)
routing['rules'] = rules
cfg['routing'] = routing
dirn=os.path.dirname(dst) or "."
fd,tmp=tempfile.mkstemp(prefix=".tmp.",suffix=".json",dir=dirn)
try:
  with os.fdopen(fd,'w',encoding='utf-8') as f:
    json.dump(cfg,f,ensure_ascii=False,indent=2)
    f.write("\n")
    f.flush()
    os.fsync(f.fileno())
  os.replace(tmp,dst)
finally:
  try:
    if os.path.exists(tmp):
      os.remove(tmp)
  except Exception:
    pass
PY
}

xray_routing_custom_domain_entry_set_mode_in_file() {
  # args: src_conf dst_conf mode direct|warp|off entry
  local src_conf="$1"
  local dst_conf="$2"
  local mode="$3"
  local ent="$4"
  need_python3
  [[ -f "${src_conf}" ]] || die "Xray routing conf tidak ditemukan: ${src_conf}"
  python3 - <<'PY' "${src_conf}" "${dst_conf}" "${mode}" "${ent}" || return 1
import json
import os
import sys
import tempfile

src, dst, mode, ent = sys.argv[1:5]
mode = mode.lower().strip()
ent = ent.strip()

with open(src, 'r', encoding='utf-8') as f:
  cfg = json.load(f)

routing = (cfg.get('routing') or {})
rules = routing.get('rules')
if not isinstance(rules, list):
  raise SystemExit("Invalid routing.rules")

def is_default_rule(r):
  if not isinstance(r, dict):
    return False
  if r.get('type') != 'field':
    return False
  port = str(r.get('port', '')).strip()
  if port not in ('1-65535', '0-65535'):
    return False
  if r.get('user') or r.get('domain') or r.get('ip') or r.get('protocol'):
    return False
  return True

def find_default_idx():
  idx = None
  for i, r in enumerate(rules):
    if is_default_rule(r):
      idx = i
  return idx

def find_template_direct_idx():
  for i, r in enumerate(rules):
    if not isinstance(r, dict):
      continue
    if r.get('type') != 'field':
      continue
    if r.get('outboundTag') != 'direct':
      continue
    dom = r.get('domain') or []
    if isinstance(dom, list) and ('geosite:apple' in dom or 'geosite:google' in dom):
      return i
  return None

def find_domain_rule_idx(outbound, marker):
  for i, r in enumerate(rules):
    if not isinstance(r, dict):
      continue
    if r.get('type') != 'field':
      continue
    if r.get('outboundTag') != outbound:
      continue
    dom = r.get('domain') or []
    if isinstance(dom, list) and marker in dom:
      return i
  return None

def ensure_domain_rule(outbound, marker, insert_at):
  idx = find_domain_rule_idx(outbound, marker)
  if idx is not None:
    return idx
  newr = {"type": "field", "domain": [marker], "outboundTag": outbound}
  rules.insert(insert_at, newr)
  return insert_at

def normalize_rule(idx, marker, desired_present):
  r = rules[idx]
  dom = r.get('domain') or []
  if not isinstance(dom, list):
    dom = []
  dom = [x for x in dom if x != marker]
  dom.insert(0, marker)
  dom = [x for x in dom if x != ent]
  if desired_present:
    dom.append(ent)
  r['domain'] = dom
  rules[idx] = r

default_idx = find_default_idx()
if default_idx is None:
  raise SystemExit("Default rule tidak ditemukan")

tpl_idx = find_template_direct_idx()
base = (tpl_idx + 1) if tpl_idx is not None else default_idx

direct_marker = 'regexp:^$'
warp_marker = 'regexp:^$WARP'

direct_idx = find_domain_rule_idx('direct', direct_marker)
warp_idx = find_domain_rule_idx('warp', warp_marker)

if mode == 'direct':
  if direct_idx is None:
    direct_idx = ensure_domain_rule('direct', direct_marker, base)
  if warp_idx is not None:
    normalize_rule(warp_idx, warp_marker, False)
  normalize_rule(direct_idx, direct_marker, True)
elif mode == 'warp':
  base_warp = (direct_idx + 1) if direct_idx is not None else base
  if warp_idx is None:
    warp_idx = ensure_domain_rule('warp', warp_marker, base_warp)
  if direct_idx is not None:
    normalize_rule(direct_idx, direct_marker, False)
  normalize_rule(warp_idx, warp_marker, True)
elif mode == 'off':
  if direct_idx is not None:
    normalize_rule(direct_idx, direct_marker, False)
  if warp_idx is not None:
    normalize_rule(warp_idx, warp_marker, False)
else:
  raise SystemExit("Mode harus direct|warp|off")

for idx in range(len(rules) - 1, -1, -1):
  r = rules[idx]
  if not isinstance(r, dict):
    continue
  if r.get('type') != 'field':
    continue
  if str(r.get('outboundTag') or '') not in {'direct', 'warp'}:
    continue
  dom = r.get('domain')
  if not isinstance(dom, list):
    continue
  normalized = [str(x).strip() for x in dom if str(x).strip()]
  if not normalized:
    continue
  real_domains = [x for x in normalized if x not in {direct_marker, warp_marker}]
  if real_domains:
    continue
  if direct_marker in normalized or warp_marker in normalized:
    rules.pop(idx)

routing['rules'] = rules
cfg['routing'] = routing

dirn = os.path.dirname(dst) or "."
fd, tmp = tempfile.mkstemp(prefix=".tmp.", suffix=".json", dir=dirn)
try:
  with os.fdopen(fd, "w", encoding="utf-8") as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
    f.write("\n")
    f.flush()
    os.fsync(f.fileno())
  os.replace(tmp, dst)
finally:
  try:
    if os.path.exists(tmp):
      os.remove(tmp)
  except Exception:
    pass
PY
}

xray_routing_apply_candidate_file() {
  local candidate="$1"
  local backup backup_out rc
  [[ -f "${candidate}" ]] || return 1
  ensure_path_writable "${XRAY_ROUTING_CONF}"
  backup="$(xray_backup_path_prepare "${XRAY_ROUTING_CONF}")"
  backup_out="$(xray_backup_path_prepare "${XRAY_OUTBOUNDS_CONF}")"

  set +e
  (
    flock -x 200
    xray_stage_origin_verify_live "${candidate}" "${XRAY_ROUTING_CONF}" "Routing Xray" || exit 89
    cp -a "${XRAY_ROUTING_CONF}" "${backup}" || exit 1
    cp -a "${XRAY_OUTBOUNDS_CONF}" "${backup_out}" || exit 1
    xray_write_file_atomic "${XRAY_ROUTING_CONF}" "${candidate}" || {
      restore_file_if_exists "${backup}" "${XRAY_ROUTING_CONF}"
      exit 1
    }
    if ! xray_routing_restart_checked; then
      if ! restore_file_if_exists "${backup}" "${XRAY_ROUTING_CONF}"; then
        exit 1
      fi
      xray_routing_restart_checked || exit 1
      exit 86
    fi
  ) 200>"${ROUTING_LOCK_FILE}"
  rc=$?
  set -e

  if (( rc == 89 )); then
    warn "Apply staged routing dibatalkan karena file live berubah sejak staging dibuat."
    return 1
  fi
  xray_txn_rc_or_die "${rc}" \
    "Gagal apply staged routing (rollback ke backup: ${backup})" \
    "xray tidak aktif setelah apply staged routing. Config di-rollback ke backup: ${backup}"
  xray_routing_post_speed_sync_or_die "${backup}" "${backup_out}" "apply staged routing custom domain"
  return 0
}

xray_inbounds_all_client_emails_get() {
  need_python3
  [[ -f "${XRAY_INBOUNDS_CONF}" ]] || return 0
  python3 - <<'PY' "${XRAY_INBOUNDS_CONF}" 2>/dev/null || true
import json, re, sys
src=sys.argv[1]
def strip_json_comments(text):
  text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
  lines = []
  for line in text.splitlines():
    out = []
    i = 0
    in_str = False
    esc = False
    while i < len(line):
      ch = line[i]
      if in_str:
        out.append(ch)
        if esc:
          esc = False
        elif ch == '\\':
          esc = True
        elif ch == '"':
          in_str = False
        i += 1
        continue
      if ch == '"':
        in_str = True
        out.append(ch)
        i += 1
        continue
      if ch == '/' and i + 1 < len(line) and line[i + 1] == '/':
        break
      out.append(ch)
      i += 1
    lines.append(''.join(out))
  return '\n'.join(lines)
try:
  with open(src,'r',encoding='utf-8') as f:
    cfg=json.loads(strip_json_comments(f.read()))
except Exception:
  raise SystemExit(0)
emails=set()
for ib in (cfg.get('inbounds') or []):
  if not isinstance(ib, dict):
    continue
  st=(ib.get('settings') or {})
  clients=st.get('clients') or []
  if not isinstance(clients, list):
    continue
  for c in clients:
    if not isinstance(c, dict):
      continue
    em=c.get('email')
    if isinstance(em, str) and em.strip():
      emails.add(em.strip())
for em in sorted(emails):
  print(em)
PY
}

warp_controls_summary() {
  local global wire_state backend_svc backend_name mode
  global="$(warp_global_mode_pretty_get)"
  mode="$(warp_mode_state_get)"
  backend_svc="$(warp_backend_service_name_get)"
  backend_name="$(warp_backend_display_name_get)"
  if svc_exists "${backend_svc}"; then
    if svc_is_active "${backend_svc}"; then
      wire_state="active"
    else
      wire_state="inactive"
    fi
  else
    wire_state="not-installed"
  fi

  local wu du wi di dd wd user_conflicts=0 inbound_conflicts=0 entry
  local -a warp_users=() direct_users=() warp_inbounds=() direct_inbounds=()
  declare -A warp_user_set=()
  declare -A direct_user_set=()
  declare -A warp_inbound_set=()
  declare -A direct_inbound_set=()
  mapfile -t warp_users < <(xray_routing_rule_user_list_get "dummy-warp-user" "warp" 2>/dev/null || true)
  mapfile -t direct_users < <(xray_routing_rule_user_list_get "dummy-direct-user" "direct" 2>/dev/null || true)
  mapfile -t warp_inbounds < <(xray_routing_rule_inbound_list_get "dummy-warp-inbounds" "warp" 2>/dev/null || true)
  mapfile -t direct_inbounds < <(xray_routing_rule_inbound_list_get "dummy-direct-inbounds" "direct" 2>/dev/null || true)
  wu="${#warp_users[@]}"
  du="${#direct_users[@]}"
  wi="${#warp_inbounds[@]}"
  di="${#direct_inbounds[@]}"
  dd="$(xray_routing_custom_domain_list_get "regexp:^$" "direct" | wc -l | tr -d ' ')"
  wd="$(xray_routing_custom_domain_list_get "regexp:^\$WARP" "warp" | wc -l | tr -d ' ')"
  for entry in "${warp_users[@]}"; do
    [[ -n "${entry}" ]] && warp_user_set["${entry}"]=1
  done
  for entry in "${direct_users[@]}"; do
    [[ -n "${entry}" ]] && direct_user_set["${entry}"]=1
  done
  for entry in "${warp_inbounds[@]}"; do
    [[ -n "${entry}" ]] && warp_inbound_set["${entry}"]=1
  done
  for entry in "${direct_inbounds[@]}"; do
    [[ -n "${entry}" ]] && direct_inbound_set["${entry}"]=1
  done
  for entry in "${!warp_user_set[@]}"; do
    [[ -n "${direct_user_set[${entry}]:-}" ]] && ((user_conflicts+=1))
  done
  for entry in "${!warp_inbound_set[@]}"; do
    [[ -n "${direct_inbound_set[${entry}]:-}" ]] && ((inbound_conflicts+=1))
  done

  echo "WARP Mode   : ${mode}"
  echo "WARP Global : ${global}"
  echo "${backend_name} : ${wire_state}"
  echo "Override    : user warp=${wu}, user direct=${du} | inbound warp=${wi}, inbound direct=${di}"
  echo "Conflict    : user=${user_conflicts}, inbound=${inbound_conflicts}"
  echo "Domain list : direct=${dd}, warp=${wd}"
}

warp_controls_report() {
  title
  echo "WARP status report (detail)"
  hr
  warp_controls_summary || true
  hr

  need_python3
  python3 - <<'PY' "${XRAY_INBOUNDS_CONF}" "${XRAY_ROUTING_CONF}" 2>/dev/null || true
import json, sys
inb_path, routing_path = sys.argv[1:3]

def load_json(path):
  try:
    with open(path,'r',encoding='utf-8') as f:
      return json.load(f)
  except Exception:
    return {}

inb=load_json(inb_path)
rt=load_json(routing_path)

rules=((rt.get('routing') or {}).get('rules') or [])

def is_default_rule(r):
  # BUG-14 fix: added additional checks to reduce false positives.
  # A rule with port='1-65535' alone is ambiguous; we also require that
  # it has no 'user', 'domain', 'ip', or 'protocol' filters (which would
  # indicate a more specific rule rather than the catch-all default).
  if not isinstance(r, dict): return False
  if r.get('type') != 'field': return False
  port=str(r.get('port','')).strip()
  if port not in ('1-65535','0-65535'): return False
  # A genuine catch-all default rule should not have specific user/domain/ip/protocol filters
  if r.get('user') or r.get('domain') or r.get('ip') or r.get('protocol'):
    return False
  return True

def get_default_mode():
  target=None
  for r in rules:
    if is_default_rule(r):
      target=r
  mode='unknown'
  bal=''
  if isinstance(target, dict):
    ot=target.get('outboundTag')
    if ot == 'warp':
      mode='warp'
    elif ot == 'direct':
      mode='direct'
    elif isinstance(ot, str) and ot:
      mode='unknown'
    else:
      mode='unknown'
  return mode, bal

def rule_list_user(marker, outbound):
  for r in rules:
    if not isinstance(r, dict): 
      continue
    if r.get('type') != 'field':
      continue
    if r.get('outboundTag') != outbound:
      continue
    u=r.get('user') or []
    if isinstance(u, list) and marker in u:
      return [x for x in u if isinstance(x,str) and x and x != marker]
  return []

def rule_list_inbound(marker, outbound):
  for r in rules:
    if not isinstance(r, dict): 
      continue
    if r.get('type') != 'field':
      continue
    if r.get('outboundTag') != outbound:
      continue
    ib=r.get('inboundTag') or []
    if isinstance(ib, list) and marker in ib:
      return [x for x in ib if isinstance(x,str) and x and x != marker]
  return []

def rule_list_domain(marker, outbound):
  for r in rules:
    if not isinstance(r, dict): 
      continue
    if r.get('type') != 'field':
      continue
    if r.get('outboundTag') != outbound:
      continue
    dom=r.get('domain') or []
    if isinstance(dom, list) and marker in dom:
      return [x for x in dom if isinstance(x,str) and x and x != marker]
  return []

mode, bal = get_default_mode()
default_label = mode

warp_users=set(rule_list_user('dummy-warp-user','warp'))
direct_users=set(rule_list_user('dummy-direct-user','direct'))
warp_inb=set(rule_list_inbound('dummy-warp-inbounds','warp'))
direct_inb=set(rule_list_inbound('dummy-direct-inbounds','direct'))
direct_dom=rule_list_domain('regexp:^$','direct')
warp_dom=rule_list_domain('regexp:^$WARP','warp')

# Collect client emails (and protocol)
clients=[]
for ib in (inb.get('inbounds') or []):
  if not isinstance(ib, dict):
    continue
  proto=ib.get('protocol')
  st=(ib.get('settings') or {})
  cls=st.get('clients') or []
  if not isinstance(cls, list):
    continue
  for c in cls:
    if not isinstance(c, dict):
      continue
    em=c.get('email')
    if isinstance(em, str) and em.strip():
      clients.append((em.strip(), proto if isinstance(proto,str) else ''))

# unique keep stable sorted
clients_sorted=sorted(set(clients), key=lambda x: (x[0], x[1]))

def eff_mode_for_email(email):
  if email in direct_users:
    return 'direct'
  if email in warp_users:
    return 'warp'
  if mode in ('warp','direct'):
    return mode
  return default_label

print("Per-user effective mode:")
print(f"{'Email':<28} {'Proto':<8} {'Effective':<12} {'Override':<10}")
print("-"*62)
for em, proto in clients_sorted:
  override=''
  if em in direct_users:
    override='direct'
  elif em in warp_users:
    override='warp'
  eff=eff_mode_for_email(em)
  print(f"{em:<28} {proto:<8} {eff:<12} {override:<10}")
if not clients_sorted:
  print("(tidak ada client ditemukan dari 10-inbounds.json)")

print()
print("Per-inboundTag effective mode:")
print(f"{'InboundTag':<28} {'Proto':<8} {'Effective':<12} {'Override':<10}")
print("-"*62)

def inbounds_tags_by_proto():
  out=[]
  for ib in (inb.get('inbounds') or []):
    if not isinstance(ib, dict):
      continue
    tag=ib.get('tag')
    proto=ib.get('protocol')
    if isinstance(tag,str) and tag.strip():
      out.append((tag.strip(), proto if isinstance(proto,str) else ''))
  return sorted(set(out), key=lambda x: (x[1], x[0]))

def eff_mode_for_inbound(tag):
  if tag in direct_inb:
    return 'direct'
  if tag in warp_inb:
    return 'warp'
  if mode in ('warp','direct'):
    return mode
  return default_label

tags=inbounds_tags_by_proto()
for tag, proto in tags:
  override=''
  if tag in direct_inb:
    override='direct'
  elif tag in warp_inb:
    override='warp'
  eff=eff_mode_for_inbound(tag)
  print(f"{tag:<28} {proto:<8} {eff:<12} {override:<10}")
if not tags:
  print("(tidak ada inbound tag ditemukan dari 10-inbounds.json)")

print()
print("Custom Domain/Geosite Lists:")
print("  Direct (custom):")
if direct_dom:
  for x in direct_dom:
    print(f"    - {x}")
else:
  print("    (kosong)")
print("  WARP (custom):")
if warp_dom:
  for x in warp_dom:
    print(f"    - {x}")
else:
  print("    (kosong)")
PY
  hr
  pause
}

xray_routing_custom_domain_entry_set_mode() {
  # args: mode direct|warp|off entry
  local mode="$1"
  local ent="$2"
  local tmp backup backup_out rc
  need_python3
  [[ -f "${XRAY_ROUTING_CONF}" ]] || die "Xray routing conf tidak ditemukan: ${XRAY_ROUTING_CONF}"
  ensure_path_writable "${XRAY_ROUTING_CONF}"
  backup="$(xray_backup_path_prepare "${XRAY_ROUTING_CONF}")"
  backup_out="$(xray_backup_path_prepare "${XRAY_OUTBOUNDS_CONF}")"
  tmp="${WORK_DIR}/30-routing.json.tmp"

  set +e
  (
    flock -x 200
    cp -a "${XRAY_ROUTING_CONF}" "${backup}" || exit 1
    cp -a "${XRAY_OUTBOUNDS_CONF}" "${backup_out}" || exit 1
    xray_routing_custom_domain_entry_set_mode_in_file "${XRAY_ROUTING_CONF}" "${tmp}" "${mode}" "${ent}" || exit 1
    xray_write_file_atomic "${XRAY_ROUTING_CONF}" "${tmp}" || {
      restore_file_if_exists "${backup}" "${XRAY_ROUTING_CONF}"
      exit 1
    }
    if ! xray_routing_restart_checked; then
      if ! restore_file_if_exists "${backup}" "${XRAY_ROUTING_CONF}"; then
        exit 1
      fi
      xray_routing_restart_checked || exit 1
      exit 86
    fi
  ) 200>"${ROUTING_LOCK_FILE}"
  rc=$?
  set -e

  xray_txn_rc_or_die "${rc}" \
    "Gagal update routing (rollback ke backup: ${backup})" \
    "xray tidak aktif setelah update custom domain mode. Config di-rollback ke backup: ${backup}"

  xray_routing_post_speed_sync_or_die "${backup}" "${backup_out}" "update routing WARP per-domain"
  return 0
}
