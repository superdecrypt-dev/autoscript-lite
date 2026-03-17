# shellcheck shell=bash
# Network Controls
# - WARP global: direct / warp
# - WARP: global / per-user / per-protocol (inbound)
# - Domain/Geosite: direct exceptions (editable list, template tetap readonly)
# - Adblock: custom geosite ext:custom.dat:adblock (enable/disable)
# -------------------------
warp_status() {
  title
  echo "WARP (wireproxy) status"
  hr
  if svc_exists wireproxy; then
    systemctl status wireproxy --no-pager || true
  else
    warn "wireproxy.service tidak terdeteksi"
  fi
  hr
  pause
}

network_state_file() {
  echo "${WORK_DIR}/network_state.json"
}

network_state_get() {
  # args: key
  local key="$1"
  local f
  f="$(network_state_file)"
  if [[ ! -f "${f}" ]]; then
    return 0
  fi
  python3 - <<'PY' "${f}" "${key}" 2>/dev/null || true
import json, sys
path, key = sys.argv[1:3]
try:
  with open(path,'r',encoding='utf-8') as f:
    d=json.load(f)
except Exception:
  d={}
v=d.get(key)
if v is None:
  raise SystemExit(0)
print(v)
PY
}

network_state_set() {
  # args: key value
  network_state_set_many "$1" "$2"
}

network_state_set_many() {
  # args: key value [key value ...]
  local f tmp rc
  if (( $# < 2 || $# % 2 != 0 )); then
    return 1
  fi
  f="$(network_state_file)"
  tmp="$(mktemp "${WORK_DIR}/.network_state.json.tmp.XXXXXX" 2>/dev/null || true)"
  if [[ -z "${tmp}" ]]; then
    tmp="${WORK_DIR}/network_state.json.tmp.$$"
  fi
  need_python3
  python3 - <<'PY' "${f}" "${tmp}" "$@"
import json, os, sys
path, tmp, *items = sys.argv[1:]
if len(items) % 2 != 0:
  raise SystemExit(2)
d={}
try:
  if os.path.exists(path):
    with open(path,'r',encoding='utf-8') as f:
      d=json.load(f) or {}
except Exception:
  d={}
for i in range(0, len(items), 2):
  d[items[i]] = items[i + 1]
with open(tmp,'w',encoding='utf-8') as f:
  json.dump(d,f,ensure_ascii=False,indent=2)
  f.write("\n")
os.replace(tmp, path)
PY
  rc=$?
  rm -f "${tmp}" 2>/dev/null || true
  if (( rc != 0 )); then
    return "${rc}"
  fi
  chmod 600 "${f}" 2>/dev/null || true
}

snapshot_file_capture() {
  local path="$1" snap_dir="$2" label="$3"
  mkdir -p "${snap_dir}" 2>/dev/null || true
  if [[ -e "${path}" ]]; then
    cp -a "${path}" "${snap_dir}/${label}.data" 2>/dev/null || return 1
    printf '1\n' > "${snap_dir}/${label}.exists"
  else
    printf '0\n' > "${snap_dir}/${label}.exists"
  fi
  return 0
}

snapshot_file_restore() {
  local path="$1" snap_dir="$2" label="$3"
  local exists="0"
  exists="$(cat "${snap_dir}/${label}.exists" 2>/dev/null || printf '0')"
  if [[ "${exists}" == "1" ]]; then
    mkdir -p "$(dirname "${path}")" 2>/dev/null || true
    cp -a "${snap_dir}/${label}.data" "${path}" 2>/dev/null || return 1
  else
    rm -f "${path}" 2>/dev/null || return 1
  fi
  return 0
}

adblock_lock_file_path() {
  printf '%s\n' "${ADBLOCK_LOCK_FILE:-/run/autoscript/locks/adblock.lock}"
}

adblock_run_locked() {
  local lock_file rc
  if [[ "${ADBLOCK_LOCK_HELD:-0}" == "1" ]]; then
    "$@"
    return $?
  fi
  lock_file="$(adblock_lock_file_path)"
  mkdir -p "$(dirname "${lock_file}")" 2>/dev/null || true
  if (
    flock -x 200 || exit 1
    export ADBLOCK_LOCK_HELD=1
    "$@"
  ) 200>"${lock_file}"; then
    return 0
  else
    rc=$?
  fi
  return "${rc}"
}

xray_dns_lock_prepare() {
  mkdir -p "$(dirname "${DNS_LOCK_FILE}")" 2>/dev/null || true
}

xray_dns_run_locked() {
  local rc
  xray_dns_lock_prepare
  if [[ "${DNS_LOCK_HELD:-0}" == "1" ]]; then
    "$@"
    return $?
  fi
  if (
    flock -x 200 || exit 1
    export DNS_LOCK_HELD=1
    "$@"
  ) 200>"${DNS_LOCK_FILE}"; then
    return 0
  else
    rc=$?
  fi
  return "${rc}"
}

xray_dns_conf_bootstrap_locked() {
  local dir base tmp
  [[ -f "${XRAY_DNS_CONF}" ]] && return 0
  dir="$(dirname "${XRAY_DNS_CONF}")"
  base="$(basename "${XRAY_DNS_CONF}")"
  mkdir -p "${dir}" 2>/dev/null || return 1
  tmp="$(mktemp "${dir}/.${base}.init.XXXXXX" 2>/dev/null || true)"
  [[ -n "${tmp}" ]] || return 1
  if ! printf '%s\n' '{"dns":{}}' > "${tmp}"; then
    rm -f "${tmp}" >/dev/null 2>&1 || true
    return 1
  fi
  chmod 600 "${tmp}" >/dev/null 2>&1 || true
  chown 0:0 "${tmp}" >/dev/null 2>&1 || true
  if ! mv -f "${tmp}" "${XRAY_DNS_CONF}"; then
    rm -f "${tmp}" >/dev/null 2>&1 || true
    return 1
  fi
  return 0
}

warp_wireproxy_restart_checked() {
  if ! svc_exists wireproxy; then
    warn "wireproxy.service tidak terdeteksi"
    return 1
  fi
  if ! svc_restart_checked wireproxy 30 >/dev/null 2>&1; then
    warn "Restart wireproxy gagal."
    return 1
  fi
  if have_cmd ss; then
    local wait_i=0
    for (( wait_i=0; wait_i<20; wait_i++ )); do
      if ss -lnt 2>/dev/null | grep -Eq '(^|[[:space:]])[^[:space:]]*:40000([[:space:]]|$)'; then
        return 0
      fi
      sleep 1
    done
    warn "wireproxy aktif, tetapi port SOCKS5 40000 belum listening setelah restart."
    return 1
  fi
  return 0
}

warp_wireproxy_post_restart_health_check() {
  local target live tier_rc=0
  if ! warp_wireproxy_restart_checked; then
    return 1
  fi
  target="$(warp_tier_target_effective_get)"
  case "${target}" in
    free|plus)
      if ! warp_live_tier_wait_for "${target}" 20; then
        tier_rc=$?
      fi
      if (( tier_rc == 1 )); then
        warn "wireproxy hidup, tetapi egress WARP belum sehat untuk target ${target}."
        return 1
      elif (( tier_rc == 2 )); then
        warn "wireproxy hidup, tetapi probe tier WARP belum memberi jawaban pasti; lanjutkan tanpa rollback keras."
      fi
      ;;
    *)
      live="$(warp_live_tier_get)"
      case "${live}" in
        free|plus) ;;
        *)
          warn "wireproxy hidup, tetapi tier WARP live belum terdeteksi sehat."
          return 1
          ;;
      esac
      ;;
  esac
  return 0
}

warp_runtime_snapshot_capture() {
  local snap_dir="$1"
  mkdir -p "${snap_dir}" 2>/dev/null || true
  snapshot_file_capture "${WGCF_DIR}/wgcf-account.toml" "${snap_dir}" "wgcf_account" || return 1
  snapshot_file_capture "${WGCF_DIR}/wgcf-profile.conf" "${snap_dir}" "wgcf_profile" || return 1
  snapshot_file_capture "${WIREPROXY_CONF}" "${snap_dir}" "wireproxy_conf" || return 1
  snapshot_file_capture "$(network_state_file)" "${snap_dir}" "network_state" || return 1
  if svc_exists wireproxy; then
    printf '1\n' > "${snap_dir}/wireproxy.exists"
    if svc_is_active wireproxy; then
      printf '1\n' > "${snap_dir}/wireproxy.active"
    else
      printf '0\n' > "${snap_dir}/wireproxy.active"
    fi
  else
    printf '0\n' > "${snap_dir}/wireproxy.exists"
    printf '0\n' > "${snap_dir}/wireproxy.active"
  fi
  return 0
}

warp_runtime_snapshot_restore() {
  local snap_dir="$1"
  local had_service was_active
  had_service="$(cat "${snap_dir}/wireproxy.exists" 2>/dev/null || printf '0')"
  was_active="$(cat "${snap_dir}/wireproxy.active" 2>/dev/null || printf '0')"

  snapshot_file_restore "${WGCF_DIR}/wgcf-account.toml" "${snap_dir}" "wgcf_account" || return 1
  snapshot_file_restore "${WGCF_DIR}/wgcf-profile.conf" "${snap_dir}" "wgcf_profile" || return 1
  snapshot_file_restore "${WIREPROXY_CONF}" "${snap_dir}" "wireproxy_conf" || return 1
  snapshot_file_restore "$(network_state_file)" "${snap_dir}" "network_state" || return 1

  if [[ "${had_service}" == "1" ]]; then
    if [[ "${was_active}" == "1" ]]; then
      warp_wireproxy_restart_checked || return 1
    elif svc_exists wireproxy && svc_is_active wireproxy; then
      svc_stop_checked wireproxy 30 || return 1
    fi
  fi
  return 0
}

warp_runtime_snapshot_restore_or_fail() {
  # args: snap_dir primary_message
  local snap_dir="$1"
  local primary_message="$2"
  if warp_runtime_snapshot_restore "${snap_dir}" >/dev/null 2>&1; then
    warn "${primary_message}"
  else
    warn "${primary_message}"
    warn "Rollback WARP gagal. Runtime mungkin masih berada pada state transisi."
  fi
  rm -rf "${snap_dir}" >/dev/null 2>&1 || true
  hr
  pause
  exit 1
}

warp_runtime_snapshot_restore_on_abort() {
  local snap_dir="${1:-}"
  [[ -n "${snap_dir}" && -d "${snap_dir}" ]] || return 0
  if warp_runtime_snapshot_restore "${snap_dir}" >/dev/null 2>&1; then
    warn "Transaksi WARP terputus sebelum selesai. Snapshot runtime dipulihkan."
  else
    warn "Transaksi WARP terputus sebelum selesai dan rollback snapshot gagal."
  fi
  rm -rf "${snap_dir}" >/dev/null 2>&1 || true
}

validate_email_user() {
  # args: email (username@protocol)
  local email="${1:-}"
  [[ "${email}" =~ ^[A-Za-z0-9._-]+@(vless|vmess|trojan)$ ]]
}

is_default_xray_email_or_tag() {
  # Default/bawaan Xray (disembunyikan dari menu WARP per-user):
  # default@(vless|vmess|trojan)-(tcp|ws|hup|grpc)
  local s="${1:-}"
  [[ "${s}" =~ ^default@(vless|vmess|trojan)-(tcp|ws|hup|grpc)$ ]]
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

xray_routing_readonly_geosite_rule_print() {
  # Menampilkan rule geosite template (readonly) dari 30-routing.json
  # Rule ini dibuat oleh setup_modular.sh dan TIDAK boleh diedit dari menu.
  need_python3
  [[ -f "${XRAY_ROUTING_CONF}" ]] || return 0
  python3 - <<'PY' "${XRAY_ROUTING_CONF}" 2>/dev/null || true
import json, sys

src=sys.argv[1]
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

try:
  with open(src,'r',encoding='utf-8') as f:
    cfg=json.load(f)
except Exception:
  raise SystemExit(0)

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
  if [[ ! -f "${XRAY_ROUTING_CONF}" ]]; then
    printf 'mode=unknown\ntag=\n'
    return 0
  fi
  need_python3
  python3 - <<'PY' "${XRAY_ROUTING_CONF}"
import json, sys
src=sys.argv[1]
with open(src,'r',encoding='utf-8') as f:
  cfg=json.load(f)
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
  idx = find_rule_idx(marker, outbound)
  if idx < 0 and not enable:
    return
  if idx < 0 and enable:
    rules.insert(default_idx, {"type": "field", "user": [marker], "outboundTag": outbound})
    idx = default_idx
    default_idx += 1
  rule = rules[idx]
  if not isinstance(rule, dict):
    rule = {"type": "field", "user": [marker], "outboundTag": outbound}
  users = rule.get('user')
  if not isinstance(users, list):
    users = []
  users = [u for u in users if u != marker and u != email]
  users.insert(0, marker)
  if enable and email not in users:
    users.append(email)
  rule['type'] = 'field'
  rule['outboundTag'] = outbound
  rule['user'] = users
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
  idx = find_rule_idx(marker, outbound)
  if idx < 0 and not enable:
    return
  if idx < 0 and enable:
    rules.insert(default_idx, {"type": "field", "inboundTag": [marker], "outboundTag": outbound})
    idx = default_idx
    default_idx += 1
  rule = rules[idx]
  if not isinstance(rule, dict):
    rule = {"type": "field", "inboundTag": [marker], "outboundTag": outbound}
  tags = rule.get('inboundTag')
  if not isinstance(tags, list):
    tags = []
  tags = [t for t in tags if t != marker and t != inbound_tag]
  tags.insert(0, marker)
  if enable and inbound_tag not in tags:
    tags.append(inbound_tag)
  rule['type'] = 'field'
  rule['outboundTag'] = outbound
  rule['inboundTag'] = tags
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
import json, sys
src=sys.argv[1]
try:
  with open(src,'r',encoding='utf-8') as f:
    cfg=json.load(f)
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
    xray_routing_default_rule_get
    hr
  else
    warn "Routing conf tidak ditemukan: ${XRAY_ROUTING_CONF}"
  fi

  if svc_exists wireproxy; then
    svc_status_line wireproxy
  else
    echo "wireproxy: (tidak terpasang)"
  fi
  hr
  pause
}

warp_global_mode_get() {
  xray_routing_default_rule_get | awk -F'=' '/^mode=/{print $2; exit}' 2>/dev/null || true
}

warp_global_mode_pretty_get() {
  local mode
  mode="$(warp_global_mode_get)"
  case "${mode}" in
    warp) echo "warp" ;;
    direct) echo "direct" ;;
    *) echo "unknown" ;;
  esac
}

xray_routing_rule_user_list_get() {
  # args: marker outboundTag
  local marker="$1"
  local outbound="$2"
  need_python3
  [[ -f "${XRAY_ROUTING_CONF}" ]] || return 0
  python3 - <<'PY' "${XRAY_ROUTING_CONF}" "${marker}" "${outbound}" 2>/dev/null || true
import json, sys
src, marker, outbound = sys.argv[1:4]
try:
  with open(src,'r',encoding='utf-8') as f:
    cfg=json.load(f)
except Exception:
  raise SystemExit(0)
rules=((cfg.get('routing') or {}).get('rules') or [])
out=[]
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
      if isinstance(x, str) and x and x != marker:
        out.append(x)
    break
for x in out:
  print(x)
PY
}

xray_routing_rule_inbound_list_get() {
  # args: marker outboundTag
  local marker="$1"
  local outbound="$2"
  need_python3
  [[ -f "${XRAY_ROUTING_CONF}" ]] || return 0
  python3 - <<'PY' "${XRAY_ROUTING_CONF}" "${marker}" "${outbound}" 2>/dev/null || true
import json, sys
src, marker, outbound = sys.argv[1:4]
try:
  with open(src,'r',encoding='utf-8') as f:
    cfg=json.load(f)
except Exception:
  raise SystemExit(0)
rules=((cfg.get('routing') or {}).get('rules') or [])
out=[]
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
      if isinstance(x, str) and x and x != marker:
        out.append(x)
    break
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
custom=None
for r in rules:
  if not isinstance(r, dict):
    continue
  if r.get('type') != 'field':
    continue
  if r.get('outboundTag') != outbound:
    continue
  dom=r.get('domain') or []
  if isinstance(dom, list) and marker in dom:
    custom=[x for x in dom if isinstance(x, str) and x and x != marker]
    break
if not isinstance(custom, list):
  custom=[]
for x in custom:
  print(x)
PY
}

xray_routing_candidate_prepare() {
  local -n _out_ref="$1"
  if [[ -n "${_out_ref}" && -f "${_out_ref}" ]]; then
    return 0
  fi
  _out_ref="$(mktemp "${WORK_DIR}/routing-stage.XXXXXX.json" 2>/dev/null || true)"
  [[ -n "${_out_ref}" ]] || return 1
  cp -a "${XRAY_ROUTING_CONF}" "${_out_ref}" || {
    rm -f -- "${_out_ref}" >/dev/null 2>&1 || true
    _out_ref=""
    return 1
  }
  chmod 600 "${_out_ref}" >/dev/null 2>&1 || true
  return 0
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
import json, sys
src=sys.argv[1]
try:
  with open(src,'r',encoding='utf-8') as f:
    cfg=json.load(f)
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
  local global wire_state
  global="$(warp_global_mode_pretty_get)"
  if svc_exists wireproxy; then
    if svc_is_active wireproxy; then
      wire_state="active"
    else
      wire_state="inactive"
    fi
  else
    wire_state="not-installed"
  fi

  local wu du wi di dd wd
  wu="$(xray_routing_rule_user_list_get "dummy-warp-user" "warp" | wc -l | tr -d ' ')"
  du="$(xray_routing_rule_user_list_get "dummy-direct-user" "direct" | wc -l | tr -d ' ')"
  wi="$(xray_routing_rule_inbound_list_get "dummy-warp-inbounds" "warp" | wc -l | tr -d ' ')"
  di="$(xray_routing_rule_inbound_list_get "dummy-direct-inbounds" "direct" | wc -l | tr -d ' ')"
  dd="$(xray_routing_custom_domain_list_get "regexp:^$" "direct" | wc -l | tr -d ' ')"
  wd="$(xray_routing_custom_domain_list_get "regexp:^\$WARP" "warp" | wc -l | tr -d ' ')"

  echo "WARP Global : ${global}"
  echo "wireproxy   : ${wire_state}"
  echo "Override    : user warp=${wu}, user direct=${du} | inbound warp=${wi}, inbound direct=${di}"
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

xray_routing_adblock_rule_get() {
  # prints: enabled=<0|1> outbound=<tag|-> duplicates=<n> domains=<n>
  need_python3
  if [[ ! -f "${XRAY_ROUTING_CONF}" ]]; then
    echo "enabled=0"
    echo "outbound=-"
    echo "duplicates=0"
    echo "domains=0"
    return 0
  fi
  python3 - <<'PY' "${XRAY_ROUTING_CONF}" "${ADBLOCK_GEOSITE_ENTRY}" 2>/dev/null || true
import json
import sys

src, entry = sys.argv[1:3]

try:
  with open(src, "r", encoding="utf-8") as f:
    cfg = json.load(f)
except Exception:
  print("enabled=0")
  print("outbound=-")
  print("duplicates=0")
  print("domains=0")
  raise SystemExit(0)

rules = ((cfg.get("routing") or {}).get("rules") or [])
targets = []
for i, r in enumerate(rules):
  if not isinstance(r, dict):
    continue
  if r.get("type") != "field":
    continue
  dom = r.get("domain") or []
  if not isinstance(dom, list):
    continue
  if any(isinstance(x, str) and x.strip() == entry for x in dom):
    targets.append((i, r))

if not targets:
  print("enabled=0")
  print("outbound=-")
  print("duplicates=0")
  print("domains=0")
  raise SystemExit(0)

r = targets[0][1]
out = "-"
ot = r.get("outboundTag")
if isinstance(ot, str) and ot.strip():
  out = ot.strip()
dom = r.get("domain") or []
dom_count = 0
if isinstance(dom, list):
  dom_count = sum(1 for x in dom if isinstance(x, str) and x.strip())

print("enabled=1")
print(f"outbound={out}")
print(f"duplicates={max(0, len(targets) - 1)}")
print(f"domains={dom_count}")
PY
}

adblock_custom_dat_status_get() {
  if [[ -s "${CUSTOM_GEOSITE_DAT}" ]]; then
    echo "ready"
  else
    echo "missing"
  fi
}

xray_routing_adblock_rule_set() {
  # args: blocked|off
  local mode="${1:-}"
  local backup tmp out changed rc
  need_python3
  [[ -f "${XRAY_ROUTING_CONF}" ]] || die "Xray routing conf tidak ditemukan: ${XRAY_ROUTING_CONF}"
  ensure_path_writable "${XRAY_ROUTING_CONF}"
  backup="$(xray_backup_path_prepare "${XRAY_ROUTING_CONF}")"
  tmp="${WORK_DIR}/30-routing-adblock.json.tmp"

  set +e
  out="$(
    (
      flock -x 200
      cp -a "${XRAY_ROUTING_CONF}" "${backup}" || exit 1
      py_out="$(
        python3 - <<'PY' "${XRAY_ROUTING_CONF}" "${tmp}" "${mode}" "${ADBLOCK_GEOSITE_ENTRY}"
import json
import sys

src, dst, mode, entry = sys.argv[1:5]
mode = mode.strip().lower()
if mode not in ("blocked", "off"):
  raise SystemExit("Mode harus blocked|off")

with open(src, "r", encoding="utf-8") as f:
  cfg = json.load(f)

routing = cfg.get("routing") or {}
rules = routing.get("rules")
if not isinstance(rules, list):
  raise SystemExit("Invalid routing.rules")
before = json.dumps(cfg, ensure_ascii=False, sort_keys=True, separators=(",", ":"))

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
    if r.get("type") != "field":
      continue
    if r.get("outboundTag") != "direct":
      continue
    dom = r.get("domain") or []
    if isinstance(dom, list) and ("geosite:apple" in dom or "geosite:google" in dom):
      return i
  return None

def has_entry(r):
  if not isinstance(r, dict):
    return False
  if r.get("type") != "field":
    return False
  dom = r.get("domain") or []
  if not isinstance(dom, list):
    return False
  for x in dom:
    if isinstance(x, str) and x.strip() == entry:
      return True
  return False

idxs = [i for i, r in enumerate(rules) if has_entry(r)]

if mode == "off":
  if idxs:
    rm = set(idxs)
    rules = [r for i, r in enumerate(rules) if i not in rm]
else:
  if len(idxs) > 1:
    rm = set(idxs[1:])
    rules = [r for i, r in enumerate(rules) if i not in rm]

  primary_idx = None
  for i, r in enumerate(rules):
    if has_entry(r):
      primary_idx = i
      break

  if primary_idx is None:
    default_idx = find_default_idx()
    tpl_idx = find_template_direct_idx()
    insert_at = default_idx if default_idx is not None else len(rules)
    if tpl_idx is not None and tpl_idx < insert_at:
      insert_at = tpl_idx + 1
    rules.insert(insert_at, {
      "type": "field",
      "domain": [entry],
      "outboundTag": "blocked"
    })
    primary_idx = insert_at

  rule = rules[primary_idx]
  if not isinstance(rule, dict):
    rule = {}
  dom = rule.get("domain")
  if not isinstance(dom, list):
    dom = []

  cleaned = [entry]
  seen = {entry}
  for x in dom:
    if not isinstance(x, str):
      continue
    x = x.strip()
    if not x or x in seen:
      continue
    cleaned.append(x)
    seen.add(x)

  rule["type"] = "field"
  rule["domain"] = cleaned
  rule["outboundTag"] = mode
  rules[primary_idx] = rule

  default_idx = find_default_idx()
  if default_idx is not None and primary_idx > default_idx:
    moved = rules.pop(primary_idx)
    rules.insert(default_idx, moved)

routing["rules"] = rules
cfg["routing"] = routing
after = json.dumps(cfg, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
changed = 1 if after != before else 0
print(f"changed={changed}")

with open(dst, "w", encoding="utf-8") as f:
  json.dump(cfg, f, ensure_ascii=False, indent=2)
  f.write("\n")
PY
      )" || exit 1
      printf '%s\n' "${py_out}"
      changed_local="$(xray_txn_changed_flag "${py_out}")"

      xray_write_file_atomic "${XRAY_ROUTING_CONF}" "${tmp}" || {
        restore_file_if_exists "${backup}" "${XRAY_ROUTING_CONF}"
        exit 1
      }

      if [[ "${changed_local}" == "1" ]]; then
        if ! xray_routing_restart_checked; then
          if ! restore_file_if_exists "${backup}" "${XRAY_ROUTING_CONF}"; then
            exit 1
          fi
          xray_routing_restart_checked || exit 1
          exit 86
        fi
      fi
    ) 200>"${ROUTING_LOCK_FILE}"
  )"
  rc=$?
  set -e

  xray_txn_rc_or_die "${rc}" \
    "Gagal update adblock routing (rollback ke backup: ${backup})" \
    "xray tidak aktif setelah update adblock routing. Config di-rollback ke backup: ${backup}"

  changed="$(xray_txn_changed_flag "${out}")"
  if [[ "${changed}" != "1" ]]; then
    return 0
  fi
  return 0
}

ssh_dns_adblock_config_get() {
  need_python3
  [[ -f "${SSH_DNS_ADBLOCK_CONFIG_FILE}" ]] || {
    printf 'enabled=0\ndns_port=-\nauto_update_enabled=0\n'
    return 0
  }
  python3 - <<'PY' "${SSH_DNS_ADBLOCK_CONFIG_FILE}" 2>/dev/null || true
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
data = {}
try:
  text = path.read_text(encoding="utf-8")
except Exception:
  text = ""
for line in text.splitlines():
  line = line.strip()
  if not line or line.startswith("#") or "=" not in line:
    continue
  k, v = line.split("=", 1)
  data[k.strip()] = v.strip()

print(f"enabled={data.get('SSH_DNS_ADBLOCK_ENABLED', '0')}")
print(f"dns_port={data.get('SSH_DNS_ADBLOCK_PORT', '-')}")
print(f"auto_update_enabled={data.get('AUTOSCRIPT_ADBLOCK_AUTO_UPDATE_ENABLED', '0')}")
print(f"auto_update_days={data.get('AUTOSCRIPT_ADBLOCK_AUTO_UPDATE_DAYS', '1')}")
PY
}

ssh_dns_adblock_config_set_enabled() {
  if [[ "${ADBLOCK_LOCK_HELD:-0}" != "1" ]]; then
    adblock_run_locked ssh_dns_adblock_config_set_enabled "$@"
    return $?
  fi
  local value="${1:-0}"
  need_python3
  [[ "${value}" == "0" || "${value}" == "1" ]] || return 1
  local tmp
  mkdir -p "$(dirname "${SSH_DNS_ADBLOCK_CONFIG_FILE}")" 2>/dev/null || true
  tmp="$(mktemp "${WORK_DIR}/.ssh-adblock-config.XXXXXX" 2>/dev/null || true)"
  [[ -n "${tmp}" ]] || tmp="${WORK_DIR}/.ssh-adblock-config.$$"
  python3 - <<'PY' "${SSH_DNS_ADBLOCK_CONFIG_FILE}" "${tmp}" "${value}"
import pathlib
import sys

src = pathlib.Path(sys.argv[1])
dst = pathlib.Path(sys.argv[2])
value = sys.argv[3]
lines = []
found = False
if src.exists():
  try:
    lines = src.read_text(encoding="utf-8").splitlines()
  except Exception:
    lines = []
out = []
for line in lines:
  if line.strip().startswith("SSH_DNS_ADBLOCK_ENABLED="):
    out.append(f"SSH_DNS_ADBLOCK_ENABLED={value}")
    found = True
  else:
    out.append(line)
if not found:
  out.append(f"SSH_DNS_ADBLOCK_ENABLED={value}")
dst.write_text("\n".join(out).rstrip("\n") + "\n", encoding="utf-8")
PY
  local rc=$?
  if (( rc == 0 )); then
    mv -f "${tmp}" "${SSH_DNS_ADBLOCK_CONFIG_FILE}" || {
      rm -f "${tmp}" >/dev/null 2>&1 || true
      return 1
    }
    chmod 644 "${SSH_DNS_ADBLOCK_CONFIG_FILE}" >/dev/null 2>&1 || true
  else
    rm -f "${tmp}" >/dev/null 2>&1 || true
  fi
  return "${rc}"
}

adblock_config_set_values() {
  if [[ "${ADBLOCK_LOCK_HELD:-0}" != "1" ]]; then
    adblock_run_locked adblock_config_set_values "$@"
    return $?
  fi
  need_python3
  if (( $# < 2 || $# % 2 != 0 )); then
    return 1
  fi

  local tmp
  mkdir -p "$(dirname "${SSH_DNS_ADBLOCK_CONFIG_FILE}")" 2>/dev/null || true
  touch "${SSH_DNS_ADBLOCK_CONFIG_FILE}"
  tmp="$(mktemp "${WORK_DIR}/.ssh-adblock-config.XXXXXX" 2>/dev/null || true)"
  [[ -n "${tmp}" ]] || tmp="${WORK_DIR}/.ssh-adblock-config.$$"

  python3 - <<'PY' "${SSH_DNS_ADBLOCK_CONFIG_FILE}" "${tmp}" "$@"
import pathlib
import sys

src = pathlib.Path(sys.argv[1])
dst = pathlib.Path(sys.argv[2])
items = sys.argv[3:]
if len(items) % 2 != 0:
  raise SystemExit(2)

updates = {}
for i in range(0, len(items), 2):
  updates[str(items[i])] = str(items[i + 1])

lines = []
if src.exists():
  try:
    lines = src.read_text(encoding="utf-8").splitlines()
  except Exception:
    lines = []

out = []
seen = set()
for line in lines:
  stripped = line.strip()
  if not stripped or stripped.startswith("#") or "=" not in line:
    out.append(line)
    continue
  key, _ = line.split("=", 1)
  key = key.strip()
  if key in updates:
    out.append(f"{key}={updates[key]}")
    seen.add(key)
  else:
    out.append(line)

for key, value in updates.items():
  if key in seen:
    continue
  out.append(f"{key}={value}")

dst.write_text("\n".join(out).rstrip("\n") + "\n", encoding="utf-8")
PY
  local rc=$?
  if (( rc == 0 )); then
    mv -f "${tmp}" "${SSH_DNS_ADBLOCK_CONFIG_FILE}" || {
      rm -f "${tmp}" >/dev/null 2>&1 || true
      return 1
    }
    chmod 644 "${SSH_DNS_ADBLOCK_CONFIG_FILE}" >/dev/null 2>&1 || true
  else
    rm -f "${tmp}" >/dev/null 2>&1 || true
  fi
  return "${rc}"
}

ssh_dns_adblock_status_get() {
  if [[ ! -x "${SSH_DNS_ADBLOCK_SYNC_BIN}" ]]; then
    local cfg auto_update_enabled auto_update_days
    cfg="$(ssh_dns_adblock_config_get)"
    auto_update_enabled="$(printf '%s\n' "${cfg}" | awk -F'=' '/^auto_update_enabled=/{print $2; exit}')"
    auto_update_days="$(printf '%s\n' "${cfg}" | awk -F'=' '/^auto_update_days=/{print $2; exit}')"
    [[ -n "${auto_update_days}" ]] || auto_update_days="1"
    printf '%s\n' "${cfg}"
    printf 'dns_service=missing\n'
    printf 'sync_service=missing\n'
    printf 'nft_table=absent\n'
    printf 'bound_users=0\n'
    printf 'users_count=0\n'
    printf 'manual_domains=0\n'
    printf 'merged_domains=0\n'
    printf 'blocklist_entries=0\n'
    printf 'source_urls=0\n'
    printf 'rendered_file=missing\n'
    printf 'custom_dat=%s\n' "$(adblock_custom_dat_status_get)"
    printf 'auto_update_service=missing\n'
    printf 'auto_update_timer=%s\n' "$([[ "${auto_update_enabled}" == "1" ]] && echo "inactive" || echo "inactive")"
    printf 'auto_update_days=%s\n' "${auto_update_days}"
    printf 'auto_update_schedule=every %s day(s)\n' "${auto_update_days}"
    printf 'last_update=-\n'
    return 0
  fi
  "${SSH_DNS_ADBLOCK_SYNC_BIN}" --status 2>/dev/null || true
}

ssh_dns_adblock_apply_now() {
  if [[ "${ADBLOCK_LOCK_HELD:-0}" != "1" ]]; then
    adblock_run_locked ssh_dns_adblock_apply_now "$@"
    return $?
  fi
  [[ -x "${SSH_DNS_ADBLOCK_SYNC_BIN}" ]] || {
    warn "adblock-sync tidak ditemukan. Jalankan setup.sh ulang."
    return 1
  }
  if ! systemctl is-active --quiet "${SSH_DNS_ADBLOCK_SERVICE}"; then
    svc_start_checked "${SSH_DNS_ADBLOCK_SERVICE}" 20 >/dev/null 2>&1 || {
      warn "Service ${SSH_DNS_ADBLOCK_SERVICE} gagal diaktifkan."
      return 1
    }
  fi
  "${SSH_DNS_ADBLOCK_SYNC_BIN}" --apply >/dev/null 2>&1
}

ssh_dns_adblock_set_enabled_now() {
  if [[ "${ADBLOCK_LOCK_HELD:-0}" != "1" ]]; then
    adblock_run_locked ssh_dns_adblock_set_enabled_now "$@"
    return $?
  fi
  local value="${1:-0}"
  [[ "${value}" == "0" || "${value}" == "1" ]] || return 1
  ssh_dns_adblock_config_set_enabled "${value}" || return 1
  ssh_dns_adblock_apply_now
}

adblock_update_now() {
  if [[ "${ADBLOCK_LOCK_HELD:-0}" != "1" ]]; then
    adblock_run_locked adblock_update_now "$@"
    return $?
  fi
  [[ -x "${SSH_DNS_ADBLOCK_SYNC_BIN}" ]] || {
    warn "adblock-sync tidak ditemukan. Jalankan setup.sh ulang."
    return 1
  }
  local mode="${1:-}"
  local -a args=(--update)
  if [[ "${mode}" == "reload-xray" ]]; then
    args+=(--reload-xray)
  fi
  if ! systemctl is-active --quiet "${SSH_DNS_ADBLOCK_SERVICE}"; then
    svc_start_checked "${SSH_DNS_ADBLOCK_SERVICE}" 20 >/dev/null 2>&1 || {
      warn "Service ${SSH_DNS_ADBLOCK_SERVICE} gagal diaktifkan."
      return 1
    }
  fi
  "${SSH_DNS_ADBLOCK_SYNC_BIN}" "${args[@]}" >/dev/null 2>&1
}

adblock_mark_dirty() {
  adblock_config_set_values AUTOSCRIPT_ADBLOCK_DIRTY 1
}

adblock_auto_update_timer_state_matches() {
  local expect_enabled="${1:-}"
  [[ "${expect_enabled}" == "0" || "${expect_enabled}" == "1" ]] || return 1

  if [[ "${expect_enabled}" == "1" ]]; then
    systemctl is-enabled --quiet "${ADBLOCK_AUTO_UPDATE_TIMER}" 2>/dev/null || return 1
    systemctl is-active --quiet "${ADBLOCK_AUTO_UPDATE_TIMER}" 2>/dev/null || return 1
    return 0
  fi

  if systemctl is-enabled --quiet "${ADBLOCK_AUTO_UPDATE_TIMER}" 2>/dev/null; then
    return 1
  fi
  if systemctl is-active --quiet "${ADBLOCK_AUTO_UPDATE_TIMER}" 2>/dev/null; then
    return 1
  fi
  return 0
}

adblock_auto_update_timer_days_matches() {
  local expected_days="${1:-}"
  local timer_path="/etc/systemd/system/${ADBLOCK_AUTO_UPDATE_TIMER}"
  local current_days=""

  [[ "${expected_days}" =~ ^[1-9][0-9]*$ ]] || return 1
  [[ -f "${timer_path}" ]] || return 1

  current_days="$(awk -F'=' '/^[[:space:]]*OnUnitActiveSec=/{print $2; exit}' "${timer_path}" 2>/dev/null | tr -d '[:space:]')"
  [[ "${current_days}" == "${expected_days}d" ]]
}

adblock_auto_update_verify_rollback_state() {
  local expected_enabled="${1:-}"
  local expected_days="${2:-}"
  if ! adblock_auto_update_timer_state_matches "${expected_enabled}"; then
    echo "state timer rollback tidak sesuai target (${expected_enabled})"
    return 1
  fi
  if [[ -n "${expected_days}" ]] && ! adblock_auto_update_timer_days_matches "${expected_days}"; then
    echo "interval timer rollback tidak sesuai target (${expected_days} hari)"
    return 1
  fi
  return 0
}

adblock_auto_update_set_enabled() {
  if [[ "${ADBLOCK_LOCK_HELD:-0}" != "1" ]]; then
    adblock_run_locked adblock_auto_update_set_enabled "$@"
    return $?
  fi
  local value="${1:-}"
  local rollback_notes=()
  [[ "${value}" == "0" || "${value}" == "1" ]] || return 1

  if [[ ! -f "/etc/systemd/system/${ADBLOCK_AUTO_UPDATE_TIMER}" ]]; then
    warn "Timer auto update belum tersedia. Jalankan setup.sh ulang."
    return 1
  fi

  if ! adblock_config_set_values AUTOSCRIPT_ADBLOCK_AUTO_UPDATE_ENABLED "${value}"; then
    warn "Gagal menyimpan status Auto Update."
    return 1
  fi

  if [[ "${value}" == "1" ]]; then
    if ! systemctl enable --now "${ADBLOCK_AUTO_UPDATE_TIMER}" >/dev/null 2>&1; then
      adblock_config_set_values AUTOSCRIPT_ADBLOCK_AUTO_UPDATE_ENABLED 0 >/dev/null 2>&1 || rollback_notes+=("restore env gagal")
      systemctl disable --now "${ADBLOCK_AUTO_UPDATE_TIMER}" >/dev/null 2>&1 || rollback_notes+=("disable timer rollback gagal")
      adblock_auto_update_verify_rollback_state 0 >/dev/null 2>&1 || rollback_notes+=("state timer rollback tidak sesuai")
      if ((${#rollback_notes[@]} > 0)); then
        warn "Gagal mengaktifkan timer ${ADBLOCK_AUTO_UPDATE_TIMER}. Rollback juga gagal: ${rollback_notes[*]}"
      else
        warn "Gagal mengaktifkan timer ${ADBLOCK_AUTO_UPDATE_TIMER}."
      fi
      return 1
    fi
    if ! adblock_auto_update_timer_state_matches 1; then
      adblock_config_set_values AUTOSCRIPT_ADBLOCK_AUTO_UPDATE_ENABLED 0 >/dev/null 2>&1 || rollback_notes+=("restore env gagal")
      systemctl disable --now "${ADBLOCK_AUTO_UPDATE_TIMER}" >/dev/null 2>&1 || rollback_notes+=("disable timer rollback gagal")
      adblock_auto_update_verify_rollback_state 0 >/dev/null 2>&1 || rollback_notes+=("state timer rollback tidak sesuai")
      if ((${#rollback_notes[@]} > 0)); then
        warn "Timer ${ADBLOCK_AUTO_UPDATE_TIMER} belum benar-benar aktif setelah enable. Rollback juga gagal: ${rollback_notes[*]}"
      else
        warn "Timer ${ADBLOCK_AUTO_UPDATE_TIMER} belum benar-benar aktif setelah enable."
      fi
      return 1
    fi
    log "Auto Update Adblock diaktifkan."
    return 0
  fi

  if ! systemctl disable --now "${ADBLOCK_AUTO_UPDATE_TIMER}" >/dev/null 2>&1; then
    adblock_config_set_values AUTOSCRIPT_ADBLOCK_AUTO_UPDATE_ENABLED 1 >/dev/null 2>&1 || rollback_notes+=("restore env gagal")
    systemctl enable --now "${ADBLOCK_AUTO_UPDATE_TIMER}" >/dev/null 2>&1 || rollback_notes+=("enable timer rollback gagal")
    adblock_auto_update_verify_rollback_state 1 >/dev/null 2>&1 || rollback_notes+=("state timer rollback tidak sesuai")
    if ((${#rollback_notes[@]} > 0)); then
      warn "Gagal menonaktifkan timer ${ADBLOCK_AUTO_UPDATE_TIMER}. Rollback juga gagal: ${rollback_notes[*]}"
    else
      warn "Gagal menonaktifkan timer ${ADBLOCK_AUTO_UPDATE_TIMER}."
    fi
    return 1
  fi
  if ! adblock_auto_update_timer_state_matches 0; then
    adblock_config_set_values AUTOSCRIPT_ADBLOCK_AUTO_UPDATE_ENABLED 1 >/dev/null 2>&1 || rollback_notes+=("restore env gagal")
    systemctl enable --now "${ADBLOCK_AUTO_UPDATE_TIMER}" >/dev/null 2>&1 || rollback_notes+=("enable timer rollback gagal")
    adblock_auto_update_verify_rollback_state 1 >/dev/null 2>&1 || rollback_notes+=("state timer rollback tidak sesuai")
    if ((${#rollback_notes[@]} > 0)); then
      warn "Timer ${ADBLOCK_AUTO_UPDATE_TIMER} belum benar-benar nonaktif setelah disable. Rollback juga gagal: ${rollback_notes[*]}"
    else
      warn "Timer ${ADBLOCK_AUTO_UPDATE_TIMER} belum benar-benar nonaktif setelah disable."
    fi
    return 1
  fi
  log "Auto Update Adblock dinonaktifkan."
  return 0
}

adblock_auto_update_timer_write() {
  local days="${1:-}"
  local timer_path="/etc/systemd/system/${ADBLOCK_AUTO_UPDATE_TIMER}"
  local dir base tmp mode uid gid
  [[ "${days}" =~ ^[1-9][0-9]*$ ]] || return 1
  [[ -f "${timer_path}" ]] || return 1
  dir="$(dirname "${timer_path}")"
  base="$(basename "${timer_path}")"
  tmp="$(mktemp "${dir}/.${base}.new.XXXXXX" 2>/dev/null || true)"
  [[ -n "${tmp}" ]] || return 1
  mode="$(stat -c '%a' "${timer_path}" 2>/dev/null || echo '644')"
  uid="$(stat -c '%u' "${timer_path}" 2>/dev/null || echo '0')"
  gid="$(stat -c '%g' "${timer_path}" 2>/dev/null || echo '0')"
  if ! cat > "${tmp}" <<EOF
[Unit]
Description=Run Adblock update every ${days} day(s)

[Timer]
OnBootSec=10min
OnUnitActiveSec=${days}d
AccuracySec=5min
Unit=${ADBLOCK_AUTO_UPDATE_SERVICE}
Persistent=true

[Install]
WantedBy=timers.target
EOF
  then
    rm -f "${tmp}" >/dev/null 2>&1 || true
    return 1
  fi
  chmod "${mode}" "${tmp}" >/dev/null 2>&1 || chmod 644 "${tmp}" >/dev/null 2>&1 || true
  chown "${uid}:${gid}" "${tmp}" >/dev/null 2>&1 || chown 0:0 "${tmp}" >/dev/null 2>&1 || true
  if ! mv -f "${tmp}" "${timer_path}"; then
    rm -f "${tmp}" >/dev/null 2>&1 || true
    return 1
  fi
  systemctl daemon-reload >/dev/null 2>&1 || return 1
  return 0
}

adblock_auto_update_set_days() {
  if [[ "${ADBLOCK_LOCK_HELD:-0}" != "1" ]]; then
    adblock_run_locked adblock_auto_update_set_days "$@"
    return $?
  fi
  local days="${1:-}"
  local previous_days=""
  local rollback_notes=()
  local timer_was_enabled="0"
  [[ "${days}" =~ ^[1-9][0-9]*$ ]] || {
    warn "Interval harus berupa angka hari, minimal 1."
    return 1
  }

  previous_days="$(ssh_dns_adblock_config_get | awk -F'=' '/^auto_update_days=/{print $2; exit}')"
  [[ "${previous_days}" =~ ^[1-9][0-9]*$ ]] || previous_days="1"
  if systemctl is-enabled --quiet "${ADBLOCK_AUTO_UPDATE_TIMER}" 2>/dev/null; then
    timer_was_enabled="1"
  fi

  if ! adblock_config_set_values AUTOSCRIPT_ADBLOCK_AUTO_UPDATE_DAYS "${days}"; then
    warn "Gagal menyimpan interval Auto Update."
    return 1
  fi

  if ! adblock_auto_update_timer_write "${days}"; then
    adblock_config_set_values AUTOSCRIPT_ADBLOCK_AUTO_UPDATE_DAYS "${previous_days}" >/dev/null 2>&1 || rollback_notes+=("restore env hari gagal")
    adblock_auto_update_timer_write "${previous_days}" >/dev/null 2>&1 || rollback_notes+=("restore timer file gagal")
    adblock_auto_update_verify_rollback_state "${timer_was_enabled}" "${previous_days}" >/dev/null 2>&1 || rollback_notes+=("state timer rollback tidak sesuai")
    if ((${#rollback_notes[@]} > 0)); then
      warn "Gagal memperbarui timer ${ADBLOCK_AUTO_UPDATE_TIMER}. Rollback juga gagal: ${rollback_notes[*]}"
    else
      warn "Gagal memperbarui timer ${ADBLOCK_AUTO_UPDATE_TIMER}."
    fi
    return 1
  fi

  if systemctl is-enabled --quiet "${ADBLOCK_AUTO_UPDATE_TIMER}" 2>/dev/null; then
    if ! systemctl restart "${ADBLOCK_AUTO_UPDATE_TIMER}" >/dev/null 2>&1; then
      adblock_config_set_values AUTOSCRIPT_ADBLOCK_AUTO_UPDATE_DAYS "${previous_days}" >/dev/null 2>&1 || rollback_notes+=("restore env hari gagal")
      adblock_auto_update_timer_write "${previous_days}" >/dev/null 2>&1 || rollback_notes+=("restore timer file gagal")
      systemctl restart "${ADBLOCK_AUTO_UPDATE_TIMER}" >/dev/null 2>&1 || rollback_notes+=("restart timer rollback gagal")
      adblock_auto_update_verify_rollback_state "${timer_was_enabled}" "${previous_days}" >/dev/null 2>&1 || rollback_notes+=("state timer rollback tidak sesuai")
      if ((${#rollback_notes[@]} > 0)); then
        warn "Gagal restart timer ${ADBLOCK_AUTO_UPDATE_TIMER}. Rollback juga gagal: ${rollback_notes[*]}"
      else
        warn "Gagal restart timer ${ADBLOCK_AUTO_UPDATE_TIMER}. Interval lama dipulihkan."
      fi
      return 1
    fi
    if ! adblock_auto_update_timer_state_matches 1; then
      adblock_config_set_values AUTOSCRIPT_ADBLOCK_AUTO_UPDATE_DAYS "${previous_days}" >/dev/null 2>&1 || rollback_notes+=("restore env hari gagal")
      adblock_auto_update_timer_write "${previous_days}" >/dev/null 2>&1 || rollback_notes+=("restore timer file gagal")
      systemctl restart "${ADBLOCK_AUTO_UPDATE_TIMER}" >/dev/null 2>&1 || rollback_notes+=("restart timer rollback gagal")
      adblock_auto_update_verify_rollback_state "${timer_was_enabled}" "${previous_days}" >/dev/null 2>&1 || rollback_notes+=("state timer rollback tidak sesuai")
      if ((${#rollback_notes[@]} > 0)); then
        warn "Timer ${ADBLOCK_AUTO_UPDATE_TIMER} tidak sehat setelah restart. Rollback juga gagal: ${rollback_notes[*]}"
      else
        warn "Timer ${ADBLOCK_AUTO_UPDATE_TIMER} tidak sehat setelah restart. Interval lama dipulihkan."
      fi
      return 1
    fi
    if ! adblock_auto_update_timer_days_matches "${days}"; then
      rollback_notes=()
      adblock_config_set_values AUTOSCRIPT_ADBLOCK_AUTO_UPDATE_DAYS "${previous_days}" >/dev/null 2>&1 || rollback_notes+=("restore env hari gagal")
      adblock_auto_update_timer_write "${previous_days}" >/dev/null 2>&1 || rollback_notes+=("restore timer file gagal")
      systemctl restart "${ADBLOCK_AUTO_UPDATE_TIMER}" >/dev/null 2>&1 || rollback_notes+=("restart timer rollback gagal")
      adblock_auto_update_verify_rollback_state "${timer_was_enabled}" "${previous_days}" >/dev/null 2>&1 || rollback_notes+=("state timer rollback tidak sesuai")
      if ((${#rollback_notes[@]} > 0)); then
        warn "Interval timer ${ADBLOCK_AUTO_UPDATE_TIMER} tidak sesuai setelah restart. Rollback juga gagal: ${rollback_notes[*]}"
      else
        warn "Interval timer ${ADBLOCK_AUTO_UPDATE_TIMER} tidak sesuai setelah restart. Interval lama dipulihkan."
      fi
      return 1
    fi
  fi

  log "Interval Auto Update di-set setiap ${days} hari."
  return 0
}

adblock_auto_update_days_menu() {
  local input
  local confirm_rc=0
  while true; do
    title
    echo "5) Network > Adblock > Set Auto Update Interval"
    hr
    echo "Masukkan jumlah hari. Contoh: 1, 3, 7"
    hr
    if ! read -r -p "Interval hari (atau kembali): " input; then
      echo
      return 0
    fi
    if is_back_choice "${input}"; then
      return 0
    fi
    if ! confirm_yn_or_back "Set interval Auto Update ke ${input} hari sekarang?"; then
      confirm_rc=$?
      if (( confirm_rc == 1 || confirm_rc == 2 )); then
        warn "Set interval Auto Update dibatalkan."
        pause
        continue
      fi
    fi
    if adblock_auto_update_set_days "${input}"; then
      pause
      return 0
    fi
    pause
  done
}

adblock_manual_domains_list() {
  need_python3
  [[ -f "${SSH_DNS_ADBLOCK_BLOCKLIST_FILE}" ]] || return 0
  python3 - <<'PY' "${SSH_DNS_ADBLOCK_BLOCKLIST_FILE}" 2>/dev/null || true
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
try:
  lines = path.read_text(encoding="utf-8").splitlines()
except Exception:
  raise SystemExit(0)

seen = set()
for raw in lines:
  line = str(raw or "").strip().lower().rstrip(".")
  if not line or line.startswith("#"):
    continue
  if line.startswith("*."):
    line = line[2:]
  if " " in line or "/" in line or ".." in line or "." not in line:
    continue
  if line in seen:
    continue
  seen.add(line)
  print(line)
PY
}

adblock_manual_domain_normalize() {
  local domain="${1:-}"
  domain="$(printf '%s' "${domain}" | tr '[:upper:]' '[:lower:]')"
  domain="$(printf '%s' "${domain}" | tr -d '[:space:]')"
  if [[ "${domain}" == \*.* ]]; then
    domain="${domain#*.}"
  fi
  domain="${domain#.}"
  domain="${domain%.}"
  [[ -n "${domain}" ]] || return 1
  [[ "${domain}" =~ ^[a-z0-9][a-z0-9._-]*\.[a-z0-9._-]+$ ]] || return 1
  [[ "${domain}" != *..* ]] || return 1
  printf '%s\n' "${domain}"
}

adblock_manual_domain_add_commit() {
  local normalized="${1:-}"
  local snap_dir tmp
  [[ -n "${normalized}" ]] || return 1
  mkdir -p "$(dirname "${SSH_DNS_ADBLOCK_BLOCKLIST_FILE}")" 2>/dev/null || true
  touch "${SSH_DNS_ADBLOCK_BLOCKLIST_FILE}"
  if adblock_manual_domains_list | grep -Fxq "${normalized}"; then
    warn "Domain sudah ada."
    return 1
  fi
  snap_dir="$(mktemp -d "${WORK_DIR}/.adblock-domain-add.XXXXXX" 2>/dev/null || true)"
  [[ -n "${snap_dir}" ]] || snap_dir="${WORK_DIR}/.adblock-domain-add.$$"
  mkdir -p "${snap_dir}" 2>/dev/null || true
  snapshot_file_capture "${SSH_DNS_ADBLOCK_BLOCKLIST_FILE}" "${snap_dir}" "blocklist" || {
    warn "Gagal membuat snapshot blocklist sebelum update."
    rm -rf "${snap_dir}" >/dev/null 2>&1 || true
    return 1
  }
  tmp="$(mktemp "${WORK_DIR}/.ssh-adblock-blocklist.XXXXXX" 2>/dev/null || true)"
  [[ -n "${tmp}" ]] || tmp="${WORK_DIR}/.ssh-adblock-blocklist.$$"
  if [[ -f "${SSH_DNS_ADBLOCK_BLOCKLIST_FILE}" ]]; then
    cat "${SSH_DNS_ADBLOCK_BLOCKLIST_FILE}" > "${tmp}" || {
      rm -f "${tmp}" >/dev/null 2>&1 || true
      rm -rf "${snap_dir}" >/dev/null 2>&1 || true
      warn "Gagal menyalin blocklist lama."
      return 1
    }
  else
    : > "${tmp}"
  fi
  printf '%s\n' "${normalized}" >> "${tmp}" || {
    rm -f "${tmp}" >/dev/null 2>&1 || true
    rm -rf "${snap_dir}" >/dev/null 2>&1 || true
    warn "Gagal menulis blocklist baru."
    return 1
  }
  if ! mv -f "${tmp}" "${SSH_DNS_ADBLOCK_BLOCKLIST_FILE}"; then
    rm -f "${tmp}" >/dev/null 2>&1 || true
    rm -rf "${snap_dir}" >/dev/null 2>&1 || true
    warn "Gagal mengganti blocklist live."
    return 1
  fi
  chmod 644 "${SSH_DNS_ADBLOCK_BLOCKLIST_FILE}" >/dev/null 2>&1 || true
  if adblock_mark_dirty; then
    log "Domain Adblock ditambahkan. Jalankan Update Adblock untuk build artifact baru."
    rm -rf "${snap_dir}" >/dev/null 2>&1 || true
    return 0
  fi
  if snapshot_file_restore "${SSH_DNS_ADBLOCK_BLOCKLIST_FILE}" "${snap_dir}" "blocklist" >/dev/null 2>&1; then
    warn "Domain ditambahkan, tetapi status dirty gagal ditandai. Perubahan dibatalkan."
  else
    warn "Domain ditambahkan, status dirty gagal ditandai, dan rollback snapshot blocklist juga gagal."
  fi
  rm -rf "${snap_dir}" >/dev/null 2>&1 || true
  return 1
}

adblock_manual_domain_add_menu() {
  local input normalized confirm_rc=0
  while true; do
    title
    echo "5) Network > Adblock > Add Domain"
    hr
    echo "Masukkan domain plain. Contoh: ads.example.com"
    hr
    if ! read -r -p "Domain (atau kembali): " input; then
      echo
      return 0
    fi
    if is_back_choice "${input}"; then
      return 0
    fi
    normalized="$(adblock_manual_domain_normalize "${input}")" || {
      warn "Domain tidak valid."
      pause
      continue
    }
    if ! confirm_yn_or_back "Tambahkan domain ${normalized} ke daftar manual Adblock sekarang?"; then
      confirm_rc=$?
      if (( confirm_rc == 1 || confirm_rc == 2 )); then
        warn "Tambah domain Adblock dibatalkan."
        pause
        continue
      fi
    fi
    if adblock_run_locked adblock_manual_domain_add_commit "${normalized}"; then
      pause
      return 0
    fi
    pause
    continue
  done
}

adblock_manual_domain_delete_commit() {
  local normalized="${1:-}"
  local -a domains=()
  local line tmp i snap_dir found="0"
  [[ -n "${normalized}" ]] || return 1
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    domains+=("${line}")
    if [[ "${line}" == "${normalized}" ]]; then
      found="1"
    fi
  done < <(adblock_manual_domains_list)
  if [[ "${found}" != "1" ]]; then
    warn "Domain tidak ditemukan."
    return 1
  fi
  tmp="$(mktemp "${WORK_DIR}/.ssh-adblock-domains.XXXXXX" 2>/dev/null || true)"
  [[ -n "${tmp}" ]] || tmp="${WORK_DIR}/.ssh-adblock-domains.$$"
  : > "${tmp}"
  for i in "${!domains[@]}"; do
    if [[ "${domains[$i]}" == "${normalized}" ]]; then
      continue
    fi
    printf '%s\n' "${domains[$i]}" >> "${tmp}"
  done
  mkdir -p "$(dirname "${SSH_DNS_ADBLOCK_BLOCKLIST_FILE}")" 2>/dev/null || true
  snap_dir="$(mktemp -d "${WORK_DIR}/.adblock-domain-del.XXXXXX" 2>/dev/null || true)"
  [[ -n "${snap_dir}" ]] || snap_dir="${WORK_DIR}/.adblock-domain-del.$$"
  mkdir -p "${snap_dir}" 2>/dev/null || true
  snapshot_file_capture "${SSH_DNS_ADBLOCK_BLOCKLIST_FILE}" "${snap_dir}" "blocklist" || {
    rm -f "${tmp}" >/dev/null 2>&1 || true
    warn "Gagal membuat snapshot blocklist sebelum delete."
    rm -rf "${snap_dir}" >/dev/null 2>&1 || true
    return 1
  }
  mv -f "${tmp}" "${SSH_DNS_ADBLOCK_BLOCKLIST_FILE}" || {
    rm -f "${tmp}" >/dev/null 2>&1 || true
    rm -rf "${snap_dir}" >/dev/null 2>&1 || true
    warn "Gagal menulis blocklist baru."
    return 1
  }
  chmod 644 "${SSH_DNS_ADBLOCK_BLOCKLIST_FILE}" >/dev/null 2>&1 || true
  if adblock_mark_dirty; then
    log "Domain Adblock dihapus. Jalankan Update Adblock untuk build artifact baru."
    rm -rf "${snap_dir}" >/dev/null 2>&1 || true
    return 0
  fi
  if snapshot_file_restore "${SSH_DNS_ADBLOCK_BLOCKLIST_FILE}" "${snap_dir}" "blocklist" >/dev/null 2>&1; then
    warn "Domain dihapus, tetapi status dirty gagal ditandai. Perubahan dibatalkan."
  else
    warn "Domain dihapus, status dirty gagal ditandai, dan rollback snapshot blocklist juga gagal."
  fi
  rm -rf "${snap_dir}" >/dev/null 2>&1 || true
  return 1
}

adblock_manual_domain_delete_menu() {
  local -a domains=()
  local line choice idx i selected_domain confirm_rc=0
  while true; do
    title
    echo "5) Network > Adblock > Delete Domain"
    hr
    domains=()
    while IFS= read -r line; do
      [[ -n "${line}" ]] || continue
      domains+=("${line}")
    done < <(adblock_manual_domains_list)
    if ((${#domains[@]} == 0)); then
      echo "Belum ada domain manual Adblock."
      hr
      pause
      return 0
    fi
    for i in "${!domains[@]}"; do
      printf "  %d) %s\n" "$((i + 1))" "${domains[$i]}"
    done
    hr
    if ! read -r -p "Hapus nomor berapa (atau kembali): " choice; then
      echo
      return 0
    fi
    if is_back_choice "${choice}"; then
      return 0
    fi
    [[ "${choice}" =~ ^[0-9]+$ ]] || {
      warn "Pilihan tidak valid."
      pause
      continue
    }
    idx=$((choice - 1))
    if (( idx < 0 || idx >= ${#domains[@]} )); then
      warn "Nomor di luar range."
      pause
      continue
    fi
    selected_domain="${domains[$idx]}"
    if ! confirm_yn_or_back "Hapus domain ${selected_domain} dari daftar manual Adblock sekarang?"; then
      confirm_rc=$?
      if (( confirm_rc == 1 || confirm_rc == 2 )); then
        warn "Delete domain Adblock dibatalkan."
        pause
        continue
      fi
    fi
    if adblock_run_locked adblock_manual_domain_delete_commit "${selected_domain}"; then
      pause
      return 0
    fi
    pause
    continue
  done
}

adblock_restore_runtime_state_checked() {
  # args: want_xray_enabled(0/1) want_ssh_enabled(0/1)
  local want_xray="${1:-0}" want_ssh="${2:-0}"
  local target_mode="off"
  local notes=()
  [[ "${want_xray}" == "1" ]] && target_mode="blocked"

  if ! xray_routing_adblock_rule_set "${target_mode}" >/dev/null 2>&1; then
    notes+=("rollback Xray gagal")
  fi

  if ! ssh_dns_adblock_config_set_enabled "${want_ssh}" >/dev/null 2>&1; then
    notes+=("rollback config SSH gagal")
  elif ! ssh_dns_adblock_apply_now >/dev/null 2>&1; then
    notes+=("rollback apply SSH gagal")
  fi

  if ((${#notes[@]} > 0)); then
    printf '%s\n' "$(IFS=' | '; echo "${notes[*]}")"
    return 1
  fi
  return 0
}

adblock_enable_all() {
  if [[ "${ADBLOCK_LOCK_HELD:-0}" != "1" ]]; then
    adblock_run_locked adblock_enable_all "$@"
    return $?
  fi
  local status dirty rendered_status xray_was_enabled update_mode rollback_msg=""
  status="$(ssh_dns_adblock_status_get)"
  dirty="$(printf '%s\n' "${status}" | awk -F'=' '/^dirty=/{print $2; exit}')"
  rendered_status="$(printf '%s\n' "${status}" | awk -F'=' '/^rendered_file=/{print $2; exit}')"
  xray_was_enabled="$(xray_routing_adblock_rule_get 2>/dev/null | awk -F'=' '/^enabled=/{print $2; exit}')"

  if [[ "${dirty}" == "1" || "$(adblock_custom_dat_status_get)" != "ready" || "${rendered_status}" != "ready" ]]; then
    update_mode=""
    if [[ "${xray_was_enabled}" == "1" ]]; then
      update_mode="reload-xray"
    fi
    if ! adblock_update_now "${update_mode}"; then
      warn "Update Adblock gagal. Enable dibatalkan."
      return 1
    fi
  fi

  if [[ "$(adblock_custom_dat_status_get)" != "ready" ]]; then
    warn "custom.dat belum siap. Enable dibatalkan."
    return 1
  fi

  if ! xray_routing_adblock_rule_set blocked; then
    warn "Xray Adblock gagal diaktifkan."
    return 1
  fi

  if ! ssh_dns_adblock_config_set_enabled 1; then
    if ! rollback_msg="$(adblock_restore_runtime_state_checked "${xray_was_enabled}" "0")"; then
      die "Rollback enable Adblock gagal: ${rollback_msg}"
    fi
    warn "Gagal mengaktifkan DNS Adblock SSH."
    return 1
  fi

  if ! ssh_dns_adblock_apply_now; then
    if ! rollback_msg="$(adblock_restore_runtime_state_checked "${xray_was_enabled}" "0")"; then
      die "Rollback enable Adblock gagal: ${rollback_msg}"
    fi
    warn "DNS Adblock SSH gagal diterapkan."
    return 1
  fi

  log "Adblock diaktifkan (shared source -> Xray + SSH)."
  return 0
}

adblock_disable_all() {
  if [[ "${ADBLOCK_LOCK_HELD:-0}" != "1" ]]; then
    adblock_run_locked adblock_disable_all "$@"
    return $?
  fi
  local xray_status="ON"
  local ssh_status="ON"
  local previous_xray previous_ssh rollback_msg=""
  previous_xray="$(xray_routing_adblock_rule_get 2>/dev/null | awk -F'=' '/^enabled=/{print $2; exit}')"
  previous_ssh="$(ssh_dns_adblock_status_get | awk -F'=' '/^enabled=/{print $2; exit}')"

  if xray_routing_adblock_rule_set off; then
    xray_status="OFF"
  else
    warn "Xray Adblock gagal dinonaktifkan."
  fi

  if ! ssh_dns_adblock_config_set_enabled 0; then
    warn "Gagal menonaktifkan DNS Adblock SSH."
  elif ssh_dns_adblock_apply_now; then
    ssh_status="OFF"
  else
    warn "DNS Adblock SSH gagal disinkronkan saat disable."
  fi

  if [[ "${xray_status}" == "OFF" && "${ssh_status}" == "OFF" ]]; then
    log "Adblock dinonaktifkan (Xray + SSH)."
    return 0
  fi

  if ! rollback_msg="$(adblock_restore_runtime_state_checked "${previous_xray}" "${previous_ssh}")"; then
    die "Rollback disable Adblock gagal: ${rollback_msg}"
  fi
  warn "Adblock nonaktif sebagian. Xray=${xray_status}, SSH=${ssh_status}."
  return 1
}

ssh_dns_adblock_show_bound_users() {
  title
  echo "5) Network > Adblock > Bound Users"
  hr
  if [[ ! -x "${SSH_DNS_ADBLOCK_SYNC_BIN}" ]]; then
    warn "adblock-sync tidak ditemukan. Jalankan setup.sh ulang."
    hr
    pause
    return 0
  fi
  local rows
  rows="$("${SSH_DNS_ADBLOCK_SYNC_BIN}" --show-users 2>/dev/null || true)"
  if [[ -z "${rows//[[:space:]]/}" ]]; then
    echo "Belum ada user SSH terkelola yang terikat ke SSH Adblock."
    hr
    pause
    return 0
  fi
  printf "%-20s %-8s\n" "Username" "UID"
  hr
  while IFS='|' read -r username uid; do
    [[ -n "${username}" ]] || continue
    printf "%-20s %-8s\n" "${username}" "${uid}"
  done <<<"${rows}"
  hr
  pause
}

xray_adblock_menu() {
  need_python3
  while true; do
    local st enabled outbound duplicates asset_status
    st="$(xray_routing_adblock_rule_get 2>/dev/null || true)"
    enabled="$(printf '%s\n' "${st}" | awk -F'=' '/^enabled=/{print $2; exit}')"
    outbound="$(printf '%s\n' "${st}" | awk -F'=' '/^outbound=/{sub(/^outbound=/,""); print; exit}')"
    duplicates="$(printf '%s\n' "${st}" | awk -F'=' '/^duplicates=/{print $2; exit}')"
    asset_status="$(adblock_custom_dat_status_get)"

    title
    echo "5) Network > Adblock (Custom Geosite)"
    hr
    printf "Geosite File : %s\n" "${CUSTOM_GEOSITE_DAT}"
    printf "Asset Status : %s\n" "${asset_status}"
    printf "Rule Entry   : %s\n" "${ADBLOCK_GEOSITE_ENTRY}"
    if [[ "${enabled}" == "1" ]]; then
      printf "Rule Status  : ON\n"
    else
      printf "Rule Status  : OFF\n"
    fi
    printf "OutboundTag  : %s\n" "${outbound:--}"
    if [[ -n "${duplicates}" && "${duplicates}" != "0" ]]; then
      printf "Duplicates   : %s (akan dibersihkan saat update)\n" "${duplicates}"
    fi
    hr
    echo "  1) Enable -> blocked"
    echo "  2) Disable (hapus rule)"
    echo "  0) Back"
    hr
    read -r -p "Pilih: " c
    case "${c}" in
      1)
        if [[ ! -s "${CUSTOM_GEOSITE_DAT}" ]]; then
          warn "custom.dat belum tersedia. Jalankan setup.sh dulu untuk download custom geosite."
          pause
          continue
        fi
        xray_routing_adblock_rule_set blocked
        log "Adblock diaktifkan ke blocked (${ADBLOCK_GEOSITE_ENTRY})"
        pause
        ;;
      2)
        xray_routing_adblock_rule_set off
        log "Adblock dinonaktifkan (rule dihapus: ${ADBLOCK_GEOSITE_ENTRY})"
        pause
        ;;
      0|kembali|k|back|b) break ;;
      *) warn "Pilihan tidak valid" ; sleep 1 ;;
    esac
  done
}

ssh_dns_adblock_menu() {
  while true; do
    local st enabled dns_port dns_service sync_service nft_table users_count entries
    st="$(ssh_dns_adblock_status_get)"
    enabled="$(printf '%s\n' "${st}" | awk -F'=' '/^enabled=/{print $2; exit}')"
    dns_port="$(printf '%s\n' "${st}" | awk -F'=' '/^dns_port=/{print $2; exit}')"
    dns_service="$(printf '%s\n' "${st}" | awk -F'=' '/^dns_service=/{print $2; exit}')"
    sync_service="$(printf '%s\n' "${st}" | awk -F'=' '/^sync_service=/{print $2; exit}')"
    nft_table="$(printf '%s\n' "${st}" | awk -F'=' '/^nft_table=/{print $2; exit}')"
    users_count="$(printf '%s\n' "${st}" | awk -F'=' '/^users_count=/{print $2; exit}')"
  entries="$(printf '%s\n' "${st}" | awk -F'=' '/^blocklist_entries=/{print $2; exit}')"
  local source_urls
  source_urls="$(printf '%s\n' "${st}" | awk -F'=' '/^source_urls=/{print $2; exit}')"

    title
    echo "5) Network > Adblock > SSH Adblock"
    hr
    printf "Rule Status   : %s\n" "$([[ "${enabled}" == "1" ]] && echo "ON" || echo "OFF")"
    printf "DNS Service   : %s\n" "${dns_service:--}"
    printf "Sync Service  : %s\n" "${sync_service:--}"
    printf "NFT Table     : %s\n" "${nft_table:--}"
    printf "Managed Users : %s\n" "${users_count:-0}"
    printf "Blocklist     : %s entries\n" "${entries:-0}"
    printf "URL Sources   : %s\n" "${source_urls:-0}"
    printf "DNS Port      : %s\n" "${dns_port:--}"
    hr
    echo "  1) Enable"
    echo "  2) Disable"
    echo "  3) Add URL"
    echo "  4) Delete URL"
    echo "  5) Update URL"
    echo "  6) Show bound users"
    echo "  0) Back"
    hr
    read -r -p "Pilih: " c
	    case "${c}" in
	      1)
	        if ssh_dns_adblock_set_enabled_now 1; then
	          log "SSH Adblock diaktifkan."
	        else
	          warn "SSH Adblock gagal diaktifkan."
	        fi
	        pause
	        ;;
	      2)
	        if ssh_dns_adblock_set_enabled_now 0; then
	          log "SSH Adblock dinonaktifkan."
	        else
	          warn "SSH Adblock gagal dinonaktifkan."
	        fi
	        pause
	        ;;
      3)
        ssh_dns_adblock_url_add_menu
        ;;
      4)
        ssh_dns_adblock_url_delete_menu
        ;;
      5)
        if ssh_dns_adblock_apply_now; then
          log "SSH Adblock URL sources diperbarui."
        else
          warn "SSH Adblock URL sources gagal diperbarui."
        fi
        pause
        ;;
      6)
        ssh_dns_adblock_show_bound_users
        ;;
      0|kembali|k|back|b) break ;;
      *) invalid_choice ;;
    esac
  done
}

ssh_dns_adblock_urls_list() {
  [[ -f "${SSH_DNS_ADBLOCK_URLS_FILE}" ]] || return 0
  grep -E '^[[:space:]]*https?://' "${SSH_DNS_ADBLOCK_URLS_FILE}" 2>/dev/null | sed 's/^[[:space:]]*//'
}

ssh_dns_adblock_url_normalize() {
  local url="${1:-}"
  url="$(printf '%s' "${url}" | tr -d '[:space:]')"
  [[ "${url}" =~ ^https?://.+$ ]] || return 1
  printf '%s\n' "${url}"
}

ssh_dns_adblock_url_add_commit() {
  local normalized="${1:-}"
  local snap_dir tmp
  [[ -n "${normalized}" ]] || return 1
  mkdir -p "$(dirname "${SSH_DNS_ADBLOCK_URLS_FILE}")" 2>/dev/null || true
  touch "${SSH_DNS_ADBLOCK_URLS_FILE}"
  if ssh_dns_adblock_urls_list | grep -Fxq "${normalized}"; then
    warn "URL sudah ada."
    return 1
  fi
  snap_dir="$(mktemp -d "${WORK_DIR}/.adblock-url-add.XXXXXX" 2>/dev/null || true)"
  [[ -n "${snap_dir}" ]] || snap_dir="${WORK_DIR}/.adblock-url-add.$$"
  mkdir -p "${snap_dir}" 2>/dev/null || true
  snapshot_file_capture "${SSH_DNS_ADBLOCK_URLS_FILE}" "${snap_dir}" "urls" || {
    warn "Gagal membuat snapshot URL source sebelum update."
    rm -rf "${snap_dir}" >/dev/null 2>&1 || true
    return 1
  }
  tmp="$(mktemp "${WORK_DIR}/.ssh-adblock-urls.XXXXXX" 2>/dev/null || true)"
  [[ -n "${tmp}" ]] || tmp="${WORK_DIR}/.ssh-adblock-urls.$$"
  if [[ -f "${SSH_DNS_ADBLOCK_URLS_FILE}" ]]; then
    cat "${SSH_DNS_ADBLOCK_URLS_FILE}" > "${tmp}" || {
      rm -f "${tmp}" >/dev/null 2>&1 || true
      rm -rf "${snap_dir}" >/dev/null 2>&1 || true
      warn "Gagal menyalin file URL source lama."
      return 1
    }
  else
    : > "${tmp}"
  fi
  printf '%s\n' "${normalized}" >> "${tmp}" || {
    rm -f "${tmp}" >/dev/null 2>&1 || true
    rm -rf "${snap_dir}" >/dev/null 2>&1 || true
    warn "Gagal menulis file URL source baru."
    return 1
  }
  if ! mv -f "${tmp}" "${SSH_DNS_ADBLOCK_URLS_FILE}"; then
    rm -f "${tmp}" >/dev/null 2>&1 || true
    rm -rf "${snap_dir}" >/dev/null 2>&1 || true
    warn "Gagal mengganti file URL source live."
    return 1
  fi
  chmod 644 "${SSH_DNS_ADBLOCK_URLS_FILE}" >/dev/null 2>&1 || true
  if adblock_mark_dirty; then
    log "URL source Adblock ditambahkan. Jalankan Update Adblock untuk build artifact baru."
    rm -rf "${snap_dir}" >/dev/null 2>&1 || true
    return 0
  fi
  if snapshot_file_restore "${SSH_DNS_ADBLOCK_URLS_FILE}" "${snap_dir}" "urls" >/dev/null 2>&1; then
    warn "URL ditambahkan, tetapi status dirty gagal ditandai. Perubahan dibatalkan."
  else
    warn "URL ditambahkan, status dirty gagal ditandai, dan rollback snapshot URL juga gagal."
  fi
  rm -rf "${snap_dir}" >/dev/null 2>&1 || true
  return 1
}

ssh_dns_adblock_url_add_menu() {
  local input normalized confirm_rc=0
  while true; do
    title
    echo "5) Network > Adblock > Add URL Source"
    hr
    echo "Sumber URL harus berbentuk http:// atau https://"
    hr
    if ! read -r -p "URL (atau kembali): " input; then
      echo
      return 0
    fi
    if is_back_choice "${input}"; then
      return 0
    fi
    normalized="$(ssh_dns_adblock_url_normalize "${input}")" || {
      warn "URL tidak valid."
      pause
      continue
    }
    if ! confirm_yn_or_back "Tambahkan URL source ${normalized} ke Adblock sekarang?"; then
      confirm_rc=$?
      if (( confirm_rc == 1 || confirm_rc == 2 )); then
        warn "Tambah URL source Adblock dibatalkan."
        pause
        continue
      fi
    fi
    if adblock_run_locked ssh_dns_adblock_url_add_commit "${normalized}"; then
      pause
      return 0
    fi
    pause
    continue
  done
}

ssh_dns_adblock_url_delete_commit() {
  local normalized="${1:-}"
  local -a urls=()
  local line tmp i snap_dir found="0"
  [[ -n "${normalized}" ]] || return 1
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    urls+=("${line}")
    if [[ "${line}" == "${normalized}" ]]; then
      found="1"
    fi
  done < <(ssh_dns_adblock_urls_list)
  if [[ "${found}" != "1" ]]; then
    warn "URL tidak ditemukan."
    return 1
  fi
  tmp="$(mktemp "${WORK_DIR}/.ssh-adblock-urls.XXXXXX" 2>/dev/null || true)"
  [[ -n "${tmp}" ]] || tmp="${WORK_DIR}/.ssh-adblock-urls.$$"
  : > "${tmp}"
  for i in "${!urls[@]}"; do
    if [[ "${urls[$i]}" == "${normalized}" ]]; then
      continue
    fi
    printf '%s\n' "${urls[$i]}" >> "${tmp}"
  done
  mkdir -p "$(dirname "${SSH_DNS_ADBLOCK_URLS_FILE}")" 2>/dev/null || true
  snap_dir="$(mktemp -d "${WORK_DIR}/.adblock-url-del.XXXXXX" 2>/dev/null || true)"
  [[ -n "${snap_dir}" ]] || snap_dir="${WORK_DIR}/.adblock-url-del.$$"
  mkdir -p "${snap_dir}" 2>/dev/null || true
  snapshot_file_capture "${SSH_DNS_ADBLOCK_URLS_FILE}" "${snap_dir}" "urls" || {
    rm -f "${tmp}" >/dev/null 2>&1 || true
    warn "Gagal membuat snapshot URL source sebelum delete."
    rm -rf "${snap_dir}" >/dev/null 2>&1 || true
    return 1
  }
  mv -f "${tmp}" "${SSH_DNS_ADBLOCK_URLS_FILE}" || {
    rm -f "${tmp}" >/dev/null 2>&1 || true
    rm -rf "${snap_dir}" >/dev/null 2>&1 || true
    warn "Gagal menulis URL source baru."
    return 1
  }
  chmod 644 "${SSH_DNS_ADBLOCK_URLS_FILE}" >/dev/null 2>&1 || true
  if adblock_mark_dirty; then
    log "URL source Adblock dihapus. Jalankan Update Adblock untuk build artifact baru."
    rm -rf "${snap_dir}" >/dev/null 2>&1 || true
    return 0
  fi
  if snapshot_file_restore "${SSH_DNS_ADBLOCK_URLS_FILE}" "${snap_dir}" "urls" >/dev/null 2>&1; then
    warn "URL dihapus, tetapi status dirty gagal ditandai. Perubahan dibatalkan."
  else
    warn "URL dihapus, status dirty gagal ditandai, dan rollback snapshot URL juga gagal."
  fi
  rm -rf "${snap_dir}" >/dev/null 2>&1 || true
  return 1
}

ssh_dns_adblock_url_delete_menu() {
  local -a urls=()
  local line choice idx i selected_url confirm_rc=0
  while true; do
    title
    echo "5) Network > Adblock > Delete URL Source"
    hr
    urls=()
    while IFS= read -r line; do
      [[ -n "${line}" ]] || continue
      urls+=("${line}")
    done < <(ssh_dns_adblock_urls_list)
    if ((${#urls[@]} == 0)); then
      echo "Belum ada URL source Adblock."
      hr
      pause
      return 0
    fi
    i=1
    for line in "${urls[@]}"; do
      printf "  %d) %s\n" "${i}" "${line}"
      i=$((i + 1))
    done
    hr
    if ! read -r -p "Hapus nomor berapa (atau kembali): " choice; then
      echo
      return 0
    fi
    if is_back_choice "${choice}"; then
      return 0
    fi
    [[ "${choice}" =~ ^[0-9]+$ ]] || {
      warn "Pilihan tidak valid."
      pause
      continue
    }
    idx=$((choice - 1))
    if (( idx < 0 || idx >= ${#urls[@]} )); then
      warn "Nomor di luar range."
      pause
      continue
    fi
    selected_url="${urls[$idx]}"
    if ! confirm_yn_or_back "Hapus URL source ${selected_url} dari Adblock sekarang?"; then
      confirm_rc=$?
      if (( confirm_rc == 1 || confirm_rc == 2 )); then
        warn "Delete URL source Adblock dibatalkan."
        pause
        continue
      fi
    fi
    if adblock_run_locked ssh_dns_adblock_url_delete_commit "${selected_url}"; then
      pause
      return 0
    fi
    pause
    continue
  done
}

adblock_menu() {
  need_python3
  while true; do
    local xray_st xray_enabled xray_outbound xray_duplicates
    local ssh_st ssh_enabled dns_port dns_service sync_service nft_table users_count entries source_urls
    local dirty manual_domains merged_domains rendered_status xray_asset last_update overall_status
    local auto_update_enabled auto_update_timer auto_update_schedule auto_update_days
    xray_st="$(xray_routing_adblock_rule_get 2>/dev/null || true)"
    xray_enabled="$(printf '%s\n' "${xray_st}" | awk -F'=' '/^enabled=/{print $2; exit}')"
    xray_outbound="$(printf '%s\n' "${xray_st}" | awk -F'=' '/^outbound=/{sub(/^outbound=/,""); print; exit}')"
    xray_duplicates="$(printf '%s\n' "${xray_st}" | awk -F'=' '/^duplicates=/{print $2; exit}')"

    ssh_st="$(ssh_dns_adblock_status_get)"
    ssh_enabled="$(printf '%s\n' "${ssh_st}" | awk -F'=' '/^enabled=/{print $2; exit}')"
    dns_port="$(printf '%s\n' "${ssh_st}" | awk -F'=' '/^dns_port=/{print $2; exit}')"
    dns_service="$(printf '%s\n' "${ssh_st}" | awk -F'=' '/^dns_service=/{print $2; exit}')"
    sync_service="$(printf '%s\n' "${ssh_st}" | awk -F'=' '/^sync_service=/{print $2; exit}')"
    nft_table="$(printf '%s\n' "${ssh_st}" | awk -F'=' '/^nft_table=/{print $2; exit}')"
    users_count="$(printf '%s\n' "${ssh_st}" | awk -F'=' '/^users_count=/{print $2; exit}')"
    entries="$(printf '%s\n' "${ssh_st}" | awk -F'=' '/^blocklist_entries=/{print $2; exit}')"
    source_urls="$(printf '%s\n' "${ssh_st}" | awk -F'=' '/^source_urls=/{print $2; exit}')"
    dirty="$(printf '%s\n' "${ssh_st}" | awk -F'=' '/^dirty=/{print $2; exit}')"
    manual_domains="$(printf '%s\n' "${ssh_st}" | awk -F'=' '/^manual_domains=/{print $2; exit}')"
    merged_domains="$(printf '%s\n' "${ssh_st}" | awk -F'=' '/^merged_domains=/{print $2; exit}')"
    rendered_status="$(printf '%s\n' "${ssh_st}" | awk -F'=' '/^rendered_file=/{print $2; exit}')"
    xray_asset="$(printf '%s\n' "${ssh_st}" | awk -F'=' '/^custom_dat=/{print $2; exit}')"
    auto_update_enabled="$(printf '%s\n' "${ssh_st}" | awk -F'=' '/^auto_update_enabled=/{print $2; exit}')"
    auto_update_timer="$(printf '%s\n' "${ssh_st}" | awk -F'=' '/^auto_update_timer=/{print $2; exit}')"
    auto_update_days="$(printf '%s\n' "${ssh_st}" | awk -F'=' '/^auto_update_days=/{print $2; exit}')"
    auto_update_schedule="$(printf '%s\n' "${ssh_st}" | awk -F'=' '/^auto_update_schedule=/{print $2; exit}')"
    last_update="$(printf '%s\n' "${ssh_st}" | awk -F'=' '/^last_update=/{sub(/^last_update=/,""); print; exit}')"

    if [[ "${xray_enabled}" == "1" && "${ssh_enabled}" == "1" ]]; then
      overall_status="ON"
    elif [[ "${xray_enabled}" == "1" || "${ssh_enabled}" == "1" ]]; then
      overall_status="PARTIAL"
    else
      overall_status="OFF"
    fi

    title
    echo "5) Network > Adblock"
    hr
    echo "Satu source: manual domains + URL sources. Output runtime: Xray custom.dat + SSH dnsmasq."
    hr
    printf "Status       : %s\n" "${overall_status}"
    printf "Dirty        : %s\n" "$([[ "${dirty}" == "1" ]] && echo "YES" || echo "NO")"
    printf "Manual List  : %s domain\n" "${manual_domains:-0}"
    printf "URL Sources  : %s\n" "${source_urls:-0}"
    printf "Merged List  : %s domain\n" "${merged_domains:-0}"
    printf "Auto Update  : %s\n" "$([[ "${auto_update_enabled}" == "1" ]] && echo "ON" || echo "OFF")"
    printf "Update Timer : %s\n" "${auto_update_timer:--}"
    printf "Interval     : %s day(s)\n" "${auto_update_days:-1}"
    printf "Schedule     : %s\n" "${auto_update_schedule:--}"
    printf "Last Update  : %s\n" "${last_update:--}"
    hr
    printf "Xray Rule    : %s\n" "$([[ "${xray_enabled}" == "1" ]] && echo "ON" || echo "OFF")"
    printf "Xray Asset   : %s\n" "${xray_asset:--}"
    printf "Rule Entry   : %s\n" "${ADBLOCK_GEOSITE_ENTRY}"
    printf "OutboundTag  : %s\n" "${xray_outbound:--}"
    if [[ -n "${xray_duplicates}" && "${xray_duplicates}" != "0" ]]; then
      printf "Duplicates   : %s (akan dibersihkan saat update)\n" "${xray_duplicates}"
    fi
    hr
    printf "SSH Rule     : %s\n" "$([[ "${ssh_enabled}" == "1" ]] && echo "ON" || echo "OFF")"
    printf "DNS Service  : %s\n" "${dns_service:--}"
    printf "Sync Service : %s\n" "${sync_service:--}"
    printf "NFT Table    : %s\n" "${nft_table:--}"
    printf "Managed Users: %s\n" "${users_count:-0}"
    printf "Blocklist    : %s entries\n" "${entries:-0}"
    printf "DNS Asset    : %s\n" "${rendered_status:--}"
    printf "DNS Port     : %s\n" "${dns_port:--}"
    hr
    echo "  1) Enable Adblock"
    echo "  2) Disable Adblock"
    echo "  3) Add Domain"
    echo "  4) Delete Domain"
    echo "  5) Add URL Source"
    echo "  6) Delete URL Source"
    echo "  7) Update Adblock"
    echo "  8) Show bound users"
    echo "  9) Toggle Auto Update"
    echo " 10) Set Auto Update Interval"
    echo "  0) Back"
    hr
    if ! read -r -p "Pilih: " c; then
      echo
      break
    fi
    case "${c}" in
      1)
        if confirm_yn_or_back "Enable Adblock sekarang?"; then
          menu_run_isolated_report "Enable Adblock" adblock_enable_all
        else
          warn "Enable Adblock dibatalkan."
        fi
        pause
        ;;
      2)
        if confirm_yn_or_back "Disable Adblock sekarang?"; then
          menu_run_isolated_report "Disable Adblock" adblock_disable_all
        else
          warn "Disable Adblock dibatalkan."
        fi
        pause
        ;;
      3) menu_run_isolated_report "Add Adblock Domain" adblock_manual_domain_add_menu ;;
      4) menu_run_isolated_report "Delete Adblock Domain" adblock_manual_domain_delete_menu ;;
      5) menu_run_isolated_report "Add Adblock Source URL" ssh_dns_adblock_url_add_menu ;;
      6) menu_run_isolated_report "Delete Adblock Source URL" ssh_dns_adblock_url_delete_menu ;;
      7)
        if confirm_yn_or_back "Update artifact Adblock sekarang?"; then
          if [[ "${xray_enabled}" == "1" ]]; then
            if adblock_update_now reload-xray; then
              log "Adblock sources diperbarui dan artifact runtime dibangun ulang."
            else
              warn "Update Adblock gagal."
            fi
          elif adblock_update_now; then
            log "Adblock sources diperbarui dan artifact runtime dibangun ulang."
          else
            warn "Update Adblock gagal."
          fi
        else
          warn "Update Adblock dibatalkan."
        fi
        pause
        ;;
      8) ssh_dns_adblock_show_bound_users ;;
      9)
        if [[ "${auto_update_enabled}" == "1" ]]; then
          if confirm_yn_or_back "Disable Auto Update Adblock sekarang?"; then
            menu_run_isolated_report "Disable Adblock Auto Update" adblock_auto_update_set_enabled 0
          else
            warn "Disable Auto Update Adblock dibatalkan."
          fi
        else
          if confirm_yn_or_back "Enable Auto Update Adblock sekarang?"; then
            menu_run_isolated_report "Enable Adblock Auto Update" adblock_auto_update_set_enabled 1
          else
            warn "Enable Auto Update Adblock dibatalkan."
          fi
        fi
        pause
        ;;
      10) menu_run_isolated_report "Set Adblock Auto Update Interval" adblock_auto_update_days_menu ;;
      0|kembali|k|back|b) break ;;
      *) invalid_choice ;;
    esac
  done
}

warp_global_menu() {
  while true; do
    title
    echo "WARP Controls > WARP Global"
    hr
    printf "Status WARP Global: %s\n" "$(warp_global_mode_pretty_get)"
    hr
    echo "  1) direct"
    echo "  2) warp"
    echo "  0) kembali"
    hr
    read -r -p "Pilih: " c
    case "${c}" in
      1)
        if ! confirm_yn_or_back "Set WARP Global ke DIRECT sekarang?"; then
          warn "Perubahan WARP Global dibatalkan."
          pause
          continue
        fi
        if ! menu_run_isolated xray_routing_default_rule_set direct; then
          warn "Gagal mengubah WARP Global ke DIRECT."
          pause
          continue
        fi
        log "WARP Global di-set ke DIRECT"
        pause
        return 0
        ;;
      2)
        if ! confirm_yn_or_back "Set WARP Global ke WARP sekarang?"; then
          warn "Perubahan WARP Global dibatalkan."
          pause
          continue
        fi
        if ! menu_run_isolated xray_routing_default_rule_set warp; then
          warn "Gagal mengubah WARP Global ke WARP."
          pause
          continue
        fi
        log "WARP Global di-set ke WARP"
        pause
        return 0
        ;;
      0|kembali|k|back|b) return 0 ;;
      *) warn "Pilihan tidak valid" ; sleep 1 ;;
    esac
  done
}

warp_user_set_effective_mode() {
  local email="$1"
  local desired="$2" # direct|warp

  if is_default_xray_email_or_tag "${email}"; then
    warn "User default Xray bersifat readonly: ${email}"
    return 0
  fi

  case "${desired}" in
    direct|warp)
      if ! menu_run_isolated xray_routing_rule_set_user_outbound_mode "${email}" "${desired}"; then
        warn "Gagal mengubah mode WARP per-user untuk ${email}."
        return 1
      fi
      ;;
    *) warn "Mode user harus direct|warp" ;;
  esac
}


warp_per_user_menu() {
  need_python3

  local page=0
  local page_size=10

  while true; do
    mapfile -t all_users_raw < <(xray_inbounds_all_client_emails_get 2>/dev/null || true)

    local all_users=()
    local u
    for u in "${all_users_raw[@]}"; do
      if is_default_xray_email_or_tag "${u}"; then
        continue
      fi
      all_users+=("${u}")
    done

    if (( ${#all_users[@]} == 0 )); then
      title
      echo "WARP Controls > WARP per-user"
      hr
      warn "Tidak menemukan user non-default dari config inbounds."
      hr
      pause
      return 0
    fi

    mapfile -t warp_override < <(xray_routing_rule_user_list_get "dummy-warp-user" "warp" 2>/dev/null || true)
    mapfile -t direct_override < <(xray_routing_rule_user_list_get "dummy-direct-user" "direct" 2>/dev/null || true)

    declare -A warp_set=()
    declare -A direct_set=()

    for u in "${warp_override[@]}"; do
      [[ -n "${u}" ]] && warp_set["${u}"]=1
    done
    for u in "${direct_override[@]}"; do
      [[ -n "${u}" ]] && direct_set["${u}"]=1
    done

    local global_mode default_mode
    global_mode="$(warp_global_mode_get || true)"
    case "${global_mode}" in
      warp) default_mode="warp" ;;
      direct) default_mode="direct" ;;
      *) default_mode="unknown" ;;
    esac

    local total pages start end i row email status
    total="${#all_users[@]}"
    pages=$(( (total + page_size - 1) / page_size ))
    if (( page < 0 )); then page=0; fi
    if (( page >= pages )); then page=$((pages - 1)); fi
    start=$((page * page_size))
    end=$((start + page_size))
    if (( end > total )); then end=total; fi

    title
    echo "WARP Controls > WARP per-user"
    hr
    printf "WARP Global: %s
" "$(warp_global_mode_pretty_get)"
    hr
    printf "%-4s %-32s %-7s
" "No" "User" "Status"
    printf "%-4s %-32s %-7s
" "----" "--------------------------------" "-------"

    for (( i=start; i<end; i++ )); do
      row=$((i - start + 1))
      email="${all_users[$i]}"

      if [[ -n "${direct_set[${email}]:-}" ]]; then
        status="direct"
      elif [[ -n "${warp_set[${email}]:-}" ]]; then
        status="warp"
      else
        status="${default_mode}"
      fi

      printf "%-4s %-32s %-7s
" "${row}" "${email}" "${status}"
    done

    echo
    echo "Halaman: $((page + 1))/${pages} | Total user: ${total}"
    if (( pages > 1 )); then
      echo "Toggle: next / previous / 0 kembali"
    else
      echo "Toggle: 0 kembali"
    fi
    hr
    read -r -p "Pilih No untuk ubah (atau next/previous/kembali): " c

    if is_back_choice "${c}"; then
      return 0
    fi

    case "${c}" in
      next|n)
        if (( page < pages - 1 )); then
          page=$((page + 1))
        fi
        continue
        ;;
      previous|prev|p)
        if (( page > 0 )); then
          page=$((page - 1))
        fi
        continue
        ;;
    esac

    if [[ ! "${c}" =~ ^[0-9]+$ ]]; then
      warn "Input tidak valid"
      sleep 1
      continue
    fi

    if (( c < 1 || c > (end - start) )); then
      warn "No di luar range"
      sleep 1
      continue
    fi

    email="${all_users[$((start + c - 1))]}"

    local cur_status
    if [[ -n "${direct_set[${email}]:-}" ]]; then
      cur_status="direct"
    elif [[ -n "${warp_set[${email}]:-}" ]]; then
      cur_status="warp"
    else
      cur_status="${default_mode}"
    fi

    while true; do
      title
      echo "WARP Controls > WARP per-user"
      hr
      echo "User   : ${email}"
      echo "Status : ${cur_status}"
      hr
      echo "  1) direct"
      echo "  2) warp"
      echo "  0) kembali"
      hr
      read -r -p "Pilih: " s

      if is_back_choice "${s}"; then
        break
      fi

      case "${s}" in
        1)
          if ! confirm_yn_or_back "Set user ${email} ke DIRECT sekarang?"; then
            warn "Perubahan WARP per-user dibatalkan."
            pause
            continue
          fi
          if warp_user_set_effective_mode "${email}" direct; then
            log "Per-user di-set DIRECT: ${email}"
            pause
            break
          fi
          pause
          ;;
        2)
          if ! confirm_yn_or_back "Set user ${email} ke WARP sekarang?"; then
            warn "Perubahan WARP per-user dibatalkan."
            pause
            continue
          fi
          if warp_user_set_effective_mode "${email}" warp; then
            log "Per-user di-set WARP: ${email}"
            pause
            break
          fi
          pause
          ;;
        *) warn "Pilihan tidak valid" ; sleep 1 ;;
      esac
    done
  done
}


warp_inbound_set_effective_mode() {
  local tag="$1"
  local desired="$2" # direct|warp

  if [[ "${tag}" == "api" ]]; then
    warn "Inbound internal (api) bersifat readonly: ${tag}"
    return 0
  fi

  case "${desired}" in
    direct|warp)
      if ! menu_run_isolated xray_routing_rule_set_inbound_outbound_mode "${tag}" "${desired}"; then
        warn "Gagal mengubah mode WARP per-inbound untuk ${tag}."
        return 1
      fi
      ;;
    *) warn "Mode inbound harus direct|warp" ;;
  esac
}


warp_per_inbounds_menu() {
  need_python3

  while true; do
    mapfile -t all_tags_raw < <(xray_inbounds_all_tags_get 2>/dev/null || true)

    local tags=()
    local t
    for t in "${all_tags_raw[@]}"; do
      if [[ "${t}" == "api" ]]; then
        continue
      fi
      tags+=("${t}")
    done

    if (( ${#tags[@]} == 0 )); then
      title
      echo "WARP Controls > WARP per-protocol inbounds"
      hr
      warn "Tidak ada inbound yang bisa diatur."
      hr
      pause
      return 0
    fi

    mapfile -t warp_override < <(xray_routing_rule_inbound_list_get "dummy-warp-inbounds" "warp" 2>/dev/null || true)
    mapfile -t direct_override < <(xray_routing_rule_inbound_list_get "dummy-direct-inbounds" "direct" 2>/dev/null || true)

    declare -A warp_set=()
    declare -A direct_set=()

    for t in "${warp_override[@]}"; do
      [[ -n "${t}" ]] && warp_set["${t}"]=1
    done
    for t in "${direct_override[@]}"; do
      [[ -n "${t}" ]] && direct_set["${t}"]=1
    done

    local global_mode default_mode
    global_mode="$(warp_global_mode_get || true)"
    case "${global_mode}" in
      warp) default_mode="warp" ;;
      direct) default_mode="direct" ;;
      *) default_mode="unknown" ;;
    esac

    title
    echo "WARP Controls > WARP per-protocol inbounds"
    hr
    printf "WARP Global: %s
" "$(warp_global_mode_pretty_get)"
    hr
    printf "%-4s %-28s %-7s
" "No" "Protocol (Inbound Tag)" "Status"
    printf "%-4s %-28s %-7s
" "----" "----------------------------" "-------"

    local i status
    for (( i=0; i<${#tags[@]}; i++ )); do
      t="${tags[$i]}"

      if [[ -n "${direct_set[${t}]:-}" ]]; then
        status="direct"
      elif [[ -n "${warp_set[${t}]:-}" ]]; then
        status="warp"
      else
        status="${default_mode}"
      fi

      printf "%-4s %-28s %-7s
" "$((i + 1))" "${t}" "${status}"
    done

    hr
    echo "Pilih No untuk ubah (direct/warp), atau 0 kembali"
    read -r -p "Pilih: " c

    if is_back_choice "${c}"; then
      return 0
    fi

    if [[ ! "${c}" =~ ^[0-9]+$ ]]; then
      warn "Input tidak valid"
      sleep 1
      continue
    fi
    if (( c < 1 || c > ${#tags[@]} )); then
      warn "No di luar range"
      sleep 1
      continue
    fi

    t="${tags[$((c - 1))]}"

    local cur_status
    if [[ -n "${direct_set[${t}]:-}" ]]; then
      cur_status="direct"
    elif [[ -n "${warp_set[${t}]:-}" ]]; then
      cur_status="warp"
    else
      cur_status="${default_mode}"
    fi

    while true; do
      title
      echo "WARP Controls > WARP per-protocol inbounds"
      hr
      echo "Inbound : ${t}"
      echo "Status  : ${cur_status}"
      hr
      echo "  1) direct"
      echo "  2) warp"
      echo "  0) kembali"
      hr
      read -r -p "Pilih: " s

      if is_back_choice "${s}"; then
        break
      fi

	      case "${s}" in
	        1)
	          if ! confirm_yn_or_back "Set inbound ${t} ke DIRECT sekarang?"; then
	            warn "Perubahan WARP per-inbound dibatalkan."
	            pause
	            continue
	          fi
	          if warp_inbound_set_effective_mode "${t}" direct; then
	            log "Per-inbounds di-set DIRECT: ${t}"
	            pause
	            break
	          fi
	          pause
	          ;;
	        2)
	          if ! confirm_yn_or_back "Set inbound ${t} ke WARP sekarang?"; then
	            warn "Perubahan WARP per-inbound dibatalkan."
	            pause
	            continue
	          fi
	          if warp_inbound_set_effective_mode "${t}" warp; then
	            log "Per-inbounds di-set WARP: ${t}"
	            pause
	            break
	          fi
	          pause
	          ;;
	        *) warn "Pilihan tidak valid" ; sleep 1 ;;
	      esac
    done
  done
}


warp_domain_geosite_menu() {
  need_python3

  local mode="direct"
  local routing_candidate=""
  local pending_changes="false"
  local source_file="" c="" ent=""

  while true; do
    source_file="${routing_candidate:-${XRAY_ROUTING_CONF}}"
    title
    echo "WARP Controls > WARP per-Geosite/Domain"
    hr
    echo "Status: ${mode}"
    if [[ "${pending_changes}" == "true" ]]; then
      echo "Staging: pending apply"
    fi
    hr

    echo "Readonly (template) geosite:"
    xray_routing_readonly_geosite_rule_print || true
    hr

    local header ent
    local -a lst_raw=()
    local -a lst=()

    if [[ "${mode}" == "warp" ]]; then
      header="Custom WARP list:"
      mapfile -t lst_raw < <(xray_routing_custom_domain_list_get "regexp:^\$WARP" "warp" "${source_file}" 2>/dev/null || true)
    else
      header="Custom DIRECT list:"
      mapfile -t lst_raw < <(xray_routing_custom_domain_list_get "regexp:^$" "direct" "${source_file}" 2>/dev/null || true)
    fi

    for ent in "${lst_raw[@]}"; do
      lst+=("${ent}")
    done

    echo "${header}"
    if (( ${#lst[@]} == 0 )); then
      echo "  (kosong)"
    else
      local i
      for (( i=0; i<${#lst[@]}; i++ )); do
        ent="${lst[$i]}"
        if is_readonly_geosite_domain "${ent}"; then
          printf "  %2d. %s (readonly)\n" "$((i + 1))" "${ent}"
        else
          printf "  %2d. %s\n" "$((i + 1))" "${ent}"
        fi
      done
    fi
    hr

    echo "  1) direct"
    echo "  2) warp"
    echo "  3) tambah domain"
    echo "  4) hapus domain"
    if [[ "${pending_changes}" == "true" ]]; then
      echo "  5) apply staged changes"
      echo "  6) discard staged changes"
    fi
    echo "  0) kembali"
    hr
    read -r -p "Pilih: " c

    if is_back_choice "${c}"; then
      if [[ "${pending_changes}" == "true" ]]; then
        local back_rc=0
        if confirm_yn_or_back "Apply staged WARP per-domain/geosite changes sebelum keluar? Pilih no untuk membuang staging."; then
          if ! xray_routing_apply_candidate_file "${routing_candidate}"; then
            pause
            continue
          fi
        else
          back_rc=$?
          if (( back_rc == 2 )); then
            continue
          fi
        fi
      fi
      rm -f "${routing_candidate}" >/dev/null 2>&1 || true
      break
    fi

    case "${c}" in
      1) mode="direct" ;;
      2) mode="warp" ;;
      3)
        read -r -p "Entry (contoh: geosite:twitter / example.com) (atau kembali): " ent
        if is_back_choice "${ent}"; then
          continue
        fi
        ent="$(echo "${ent}" | tr -d '[:space:]')"
        if [[ -z "${ent}" || "${ent}" == "regexp:^$" || "${ent}" == "regexp:^\$WARP" ]]; then
          warn "Entry tidak valid / reserved"
          pause
          continue
        fi
        if ! routing_custom_domain_entry_valid "${ent}"; then
          warn "Entry harus berupa geosite:nama atau domain yang valid."
          pause
          continue
        fi
	        if is_readonly_geosite_domain "${ent}"; then
	          warn "Readonly geosite tidak boleh diubah dari menu ini: ${ent}"
	          pause
	          continue
	        fi
	        if ! confirm_yn_or_back "Stage entry ${ent} ke mode ${mode^^} sekarang?"; then
	          warn "Perubahan WARP per-domain/geosite dibatalkan."
	          pause
	          continue
	        fi
	        if ! xray_routing_candidate_prepare routing_candidate; then
	          warn "Gagal menyiapkan staging routing."
	          pause
	          continue
	        fi
	        if ! xray_routing_custom_domain_entry_set_mode_in_file "${routing_candidate}" "${routing_candidate}" "${mode}" "${ent}"; then
	          warn "Gagal men-stage entry WARP per-domain/geosite."
	          pause
	          continue
	        fi
	        pending_changes="true"
	        log "Entry di-stage ${mode^^}: ${ent}"
	        pause
        ;;
      4)
        if (( ${#lst[@]} == 0 )); then
          warn "List kosong"
          pause
          continue
        fi
        read -r -p "Entry yang dihapus (No atau teks) (atau kembali): " ent
        if is_back_choice "${ent}"; then
          continue
        fi
        ent="$(echo "${ent}" | tr -d '[:space:]')"

        if [[ "${ent}" =~ ^[0-9]+$ ]]; then
          if (( ent < 1 || ent > ${#lst[@]} )); then
            warn "No tidak ditemukan"
            pause
            continue
          fi
          ent="${lst[$((ent - 1))]}"
        fi

        if [[ -z "${ent}" || "${ent}" == "regexp:^$" || "${ent}" == "regexp:^\$WARP" ]]; then
          warn "Entry tidak valid / reserved"
          pause
          continue
        fi
	        if is_readonly_geosite_domain "${ent}"; then
	          warn "Readonly geosite tidak bisa dihapus dari menu ini: ${ent}"
	          pause
	          continue
	        fi
	        if ! confirm_yn_or_back "Stage penghapusan entry ${ent} dari mode ${mode^^} sekarang?"; then
	          warn "Penghapusan entry WARP per-domain/geosite dibatalkan."
	          pause
	          continue
	        fi

	        if ! xray_routing_candidate_prepare routing_candidate; then
	          warn "Gagal menyiapkan staging routing."
	          pause
	          continue
	        fi
	        if ! xray_routing_custom_domain_entry_set_mode_in_file "${routing_candidate}" "${routing_candidate}" off "${ent}"; then
	          warn "Gagal men-stage penghapusan entry WARP per-domain/geosite."
	          pause
	          continue
	        fi
	        pending_changes="true"
	        log "Entry di-stage untuk dihapus: ${ent}"
        pause
        ;;
      5)
        if [[ "${pending_changes}" != "true" ]]; then
          warn "Pilihan tidak valid"
          sleep 1
          continue
        fi
        if ! confirm_menu_apply_now "Apply staged WARP per-domain/geosite changes sekarang?"; then
          pause
          continue
        fi
        if ! xray_routing_apply_candidate_file "${routing_candidate}"; then
          pause
          continue
        fi
        rm -f "${routing_candidate}" >/dev/null 2>&1 || true
        routing_candidate=""
        pending_changes="false"
        log "Staged WARP per-domain/geosite changes diterapkan."
        pause
        ;;
      6)
        if [[ "${pending_changes}" != "true" ]]; then
          warn "Pilihan tidak valid"
          sleep 1
          continue
        fi
        if confirm_menu_apply_now "Buang staged WARP per-domain/geosite changes?"; then
          rm -f "${routing_candidate}" >/dev/null 2>&1 || true
          routing_candidate=""
          pending_changes="false"
          log "Staged WARP per-domain/geosite changes dibuang."
        fi
        pause
        ;;
      *) warn "Pilihan tidak valid" ; sleep 1 ;;
    esac
  done
}



warp_tier_state_target_get() {
  local raw
  raw="$(network_state_get "${WARP_TIER_STATE_KEY}" 2>/dev/null || true)"
  raw="$(echo "${raw}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  case "${raw}" in
    free|plus) echo "${raw}" ;;
    *) echo "unknown" ;;
  esac
}

warp_plus_license_state_get() {
  network_state_get "${WARP_PLUS_LICENSE_STATE_KEY}" 2>/dev/null | tr -d '\r' || true
}

warp_plus_license_mask() {
  local key="${1:-}"
  local len
  key="$(echo "${key}" | tr -d '[:space:]')"
  len="${#key}"
  if (( len <= 8 )); then
    echo "${key}"
    return 0
  fi
  echo "${key:0:4}****${key:len-4:4}"
}

warp_trace_field_get() {
  # args: field_name
  local field="${1:-}"
  local bind_addr trace
  [[ -n "${field}" ]] || return 0
  [[ -f "${WIREPROXY_CONF}" ]] || return 0
  if ! have_cmd curl; then
    return 0
  fi
  bind_addr="$(awk -F'=' '
    /^[[:space:]]*BindAddress[[:space:]]*=/ {
      v=$2
      gsub(/[[:space:]]/, "", v)
      print v
      exit
    }
  ' "${WIREPROXY_CONF}" 2>/dev/null || true)"
  [[ -n "${bind_addr}" ]] || bind_addr="127.0.0.1:40000"

  trace="$(curl -fsS --max-time 8 --socks5 "${bind_addr}" "https://www.cloudflare.com/cdn-cgi/trace" 2>/dev/null || true)"
  [[ -n "${trace}" ]] || return 0
  echo "${trace}" | awk -F= -v k="${field}" '$1==k {print $2; exit}'
}

warp_live_tier_get() {
  local warpv
  warpv="$(warp_trace_field_get warp | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  case "${warpv}" in
    plus) echo "plus" ;;
    on) echo "free" ;;
    off) echo "off" ;;
    *) echo "unknown" ;;
  esac
}

warp_live_tier_wait_for() {
  local expected="${1:-}"
  local timeout="${2:-20}"
  local checks i live saw_probe="false"
  [[ "${expected}" == "free" || "${expected}" == "plus" ]] || return 1
  if [[ ! "${timeout}" =~ ^[0-9]+$ ]] || (( timeout <= 0 )); then
    timeout=20
  fi
  checks=$(( timeout < 1 ? 1 : timeout ))
  for (( i=0; i<checks; i++ )); do
    live="$(warp_live_tier_get)"
    case "${live}" in
      free|plus|off) saw_probe="true" ;;
    esac
    [[ "${live}" == "${expected}" ]] && return 0
    sleep 1
  done
  if [[ "${saw_probe}" != "true" ]]; then
    return 2
  fi
  return 1
}

warp_tier_target_effective_get() {
  local target live
  target="$(warp_tier_state_target_get)"
  if [[ "${target}" == "free" || "${target}" == "plus" ]]; then
    echo "${target}"
    return 0
  fi

  live="$(warp_live_tier_get)"
  case "${live}" in
    free|plus)
      echo "${live}"
      ;;
    *)
      echo "unknown"
      ;;
  esac
}

warp_tier_reconnect_target_get() {
  local live target
  live="$(warp_live_tier_get)"
  case "${live}" in
    free|plus)
      echo "${live}"
      return 0
      ;;
  esac
  target="$(warp_tier_target_effective_get)"
  case "${target}" in
    free|plus) echo "${target}" ;;
    *) echo "free" ;;
  esac
}

warp_tier_state_seed_from_live() {
  # Status view tidak boleh mengubah persistent state.
  return 0
}

xray_routing_restart_checked() {
  local state=""

  if systemctl restart xray >/dev/null 2>&1; then
    if svc_wait_active xray 60; then
      return 0
    fi
  else
    state="$(svc_state xray)"
    if [[ "${state}" == "active" ]]; then
      return 1
    fi
  fi

  state="$(svc_state xray)"
  if [[ "${state}" == "failed" || "${state}" == "inactive" || "${state}" == "activating" || "${state}" == "deactivating" ]]; then
    systemctl reset-failed xray >/dev/null 2>&1 || true
    sleep 1
    if systemctl start xray >/dev/null 2>&1 && svc_wait_active xray 60; then
      return 0
    fi
  fi

  return 1
}

xray_routing_post_speed_sync_or_die() {
  # args: backup_routing backup_outbounds context
  local backup_rt="$1"
  local backup_out="$2"
  local context="$3"
  local rollback_notes=()
  local need_sync="false"

  if speed_policy_has_entries; then
    need_sync="true"
  elif speed_policy_artifacts_present_in_xray; then
    need_sync="true"
  fi
  if [[ "${need_sync}" != "true" ]]; then
    return 0
  fi

  if speed_policy_sync_xray && speed_policy_apply_now >/dev/null 2>&1; then
    return 0
  fi

  warn "Sinkronisasi speed policy gagal setelah ${context}. Melakukan rollback..."
  if [[ -n "${backup_rt}" ]]; then
    restore_file_if_exists "${backup_rt}" "${XRAY_ROUTING_CONF}" || rollback_notes+=("restore routing gagal")
  fi
  if [[ -n "${backup_out}" ]]; then
    restore_file_if_exists "${backup_out}" "${XRAY_OUTBOUNDS_CONF}" || rollback_notes+=("restore outbounds gagal")
  fi
  if ! xray_routing_restart_checked; then
    rollback_notes+=("restart xray rollback gagal")
  fi

  if (( ${#rollback_notes[@]} > 0 )); then
    die "Sinkronisasi speed policy gagal setelah ${context}; rollback juga bermasalah: $(IFS=' | '; echo "${rollback_notes[*]}")."
  fi
  die "Sinkronisasi speed policy gagal setelah ${context}; perubahan di-rollback ke state sebelumnya."
}

warp_wireproxy_socks_block_get() {
  if [[ ! -f "${WIREPROXY_CONF}" ]]; then
    cat <<'EOF'
[Socks5]
BindAddress = 127.0.0.1:40000
EOF
    return 0
  fi

  awk '
    BEGIN { inblk=0; found=0 }
    /^[[:space:]]*\[(Socks|Socks5)\][[:space:]]*$/ {
      inblk=1
      if (found==0) {
        print "[Socks5]"
        found=1
      }
      next
    }
    /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
      inblk=0
      next
    }
    inblk { print; next }
    END {
      if (found==0) {
        print "[Socks5]"
        print "BindAddress = 127.0.0.1:40000"
      }
    }
  ' "${WIREPROXY_CONF}" 2>/dev/null
}

warp_wireproxy_apply_profile() {
  # args: wgcf_profile_path
  local profile="${1:-}"
  local tmp backup socks_block ts
  [[ -n "${profile}" && -f "${profile}" ]] || {
    warn "Profile wgcf tidak ditemukan: ${profile}"
    return 1
  }

  mkdir -p "$(dirname "${WIREPROXY_CONF}")"
  tmp="$(mktemp)"
  socks_block="$(warp_wireproxy_socks_block_get)"

  awk '
    BEGIN { drop=0 }
    /^[[:space:]]*\[(Socks|Socks5)\][[:space:]]*$/ { drop=1; next }
    /^[[:space:]]*\[[^]]+\][[:space:]]*$/ { drop=0 }
    drop { next }
    { print }
  ' "${profile}" > "${tmp}"
  printf "\n%s\n" "${socks_block}" >> "${tmp}"

  if [[ -f "${WIREPROXY_CONF}" ]]; then
    ts="$(date +%Y%m%d-%H%M%S)"
    backup="${WIREPROXY_CONF}.bak.${ts}"
    cp -f "${WIREPROXY_CONF}" "${backup}" 2>/dev/null || true
  fi

  if ! install -m 600 "${tmp}" "${WIREPROXY_CONF}"; then
    rm -f "${tmp}" 2>/dev/null || true
    warn "Gagal menulis wireproxy config: ${WIREPROXY_CONF}"
    return 1
  fi
  rm -f "${tmp}" 2>/dev/null || true
  return 0
}

warp_wgcf_register_noninteractive_in_dir() {
  local target_dir="${1:-${WGCF_DIR}}"
  local reg_log
  reg_log="$(mktemp "/tmp/wgcf-register-manage.XXXXXX.log")"

  mkdir -p "${target_dir}"
  pushd "${target_dir}" >/dev/null || {
    warn "Gagal masuk ke ${target_dir}"
    return 1
  }

  if [[ -f "wgcf-account.toml" ]]; then
    popd >/dev/null || true
    return 0
  fi

  if have_cmd expect; then
    expect <<'EOF' >"${reg_log}" 2>&1 || true
set timeout 180
log_user 1
spawn wgcf register
expect {
  -re {Use the arrow keys.*} { send "\r"; exp_continue }
  -re {Do you agree.*} { send "\r"; exp_continue }
  -re {\(y/n\)} { send "y\r"; exp_continue }
  -re {Yes/No} { send "\r"; exp_continue }
  -re {accept} { send "\r"; exp_continue }
  eof
}
EOF
  else
    set +o pipefail
    yes | wgcf register >"${reg_log}" 2>&1 || true
    set -o pipefail
  fi

  popd >/dev/null || true
  if [[ ! -f "${target_dir}/wgcf-account.toml" ]]; then
    warn "wgcf register gagal. Log: ${reg_log}"
    tail -n 60 "${reg_log}" >&2 || true
    return 1
  fi
  rm -f "${reg_log}" >/dev/null 2>&1 || true
  return 0
}

warp_wgcf_register_noninteractive() {
  warp_wgcf_register_noninteractive_in_dir "${WGCF_DIR}"
}

warp_wgcf_seed_stage_from_live_account() {
  local target_dir="${1:-}"
  [[ -n "${target_dir}" ]] || return 1
  mkdir -p "${target_dir}" 2>/dev/null || return 1
  if [[ -s "${WGCF_DIR}/wgcf-account.toml" ]]; then
    install -m 600 "${WGCF_DIR}/wgcf-account.toml" "${target_dir}/wgcf-account.toml" || return 1
  fi
  return 0
}

warp_wgcf_build_profile_in_dir() {
  # args: target_dir tier [license_key]
  local target_dir="${1:-${WGCF_DIR}}"
  local tier="${2:-free}"
  local license_key="${3:-}"
  local gen_log upd_log
  gen_log="$(mktemp "/tmp/wgcf-generate-manage.XXXXXX.log")"
  upd_log="$(mktemp "/tmp/wgcf-update-manage.XXXXXX.log")"

  mkdir -p "${target_dir}"
  if [[ ! -f "${target_dir}/wgcf-account.toml" ]]; then
    if ! warp_wgcf_register_noninteractive_in_dir "${target_dir}"; then
      return 1
    fi
  fi

  pushd "${target_dir}" >/dev/null || {
    warn "Gagal masuk ke ${target_dir}"
    return 1
  }

  if [[ "${tier}" == "plus" ]]; then
    license_key="$(echo "${license_key}" | tr -d '[:space:]')"
    if [[ -z "${license_key}" ]]; then
      popd >/dev/null || true
      warn "License key WARP+ kosong"
      return 1
    fi
    if ! wgcf update --license-key "${license_key}" >"${upd_log}" 2>&1; then
      popd >/dev/null || true
      warn "wgcf update --license-key gagal. Log: ${upd_log}"
      tail -n 60 "${upd_log}" >&2 || true
      return 1
    fi
  fi

  if ! wgcf generate -p "${target_dir}/wgcf-profile.conf" >"${gen_log}" 2>&1; then
    popd >/dev/null || true
    warn "wgcf generate gagal. Log: ${gen_log}"
    tail -n 60 "${gen_log}" >&2 || true
    return 1
  fi
  popd >/dev/null || true

  if [[ ! -s "${target_dir}/wgcf-profile.conf" ]]; then
    warn "wgcf-profile.conf tidak ditemukan setelah generate"
    return 1
  fi
  rm -f "${gen_log}" "${upd_log}" >/dev/null 2>&1 || true
  return 0
}

warp_wgcf_build_profile() {
  # args: tier [license_key]
  local tier="${1:-free}"
  local license_key="${2:-}"
  warp_wgcf_build_profile_in_dir "${WGCF_DIR}" "${tier}" "${license_key}"
}

warp_wgcf_install_live_files_from_dir() {
  local source_dir="${1:-}"
  local tmp_account="" tmp_profile=""
  [[ -n "${source_dir}" ]] || return 1
  mkdir -p "${WGCF_DIR}" || return 1
  [[ -s "${source_dir}/wgcf-account.toml" ]] || return 1
  [[ -s "${source_dir}/wgcf-profile.conf" ]] || return 1
  tmp_account="$(mktemp "${WGCF_DIR}/.wgcf-account.XXXXXX" 2>/dev/null || true)"
  tmp_profile="$(mktemp "${WGCF_DIR}/.wgcf-profile.XXXXXX" 2>/dev/null || true)"
  [[ -n "${tmp_account}" && -n "${tmp_profile}" ]] || {
    rm -f "${tmp_account}" "${tmp_profile}" >/dev/null 2>&1 || true
    return 1
  }
  if ! install -m 600 "${source_dir}/wgcf-account.toml" "${tmp_account}"; then
    rm -f "${tmp_account}" "${tmp_profile}" >/dev/null 2>&1 || true
    return 1
  fi
  if ! install -m 600 "${source_dir}/wgcf-profile.conf" "${tmp_profile}"; then
    rm -f "${tmp_account}" "${tmp_profile}" >/dev/null 2>&1 || true
    return 1
  fi
  if ! mv -f "${tmp_account}" "${WGCF_DIR}/wgcf-account.toml"; then
    rm -f "${tmp_account}" "${tmp_profile}" >/dev/null 2>&1 || true
    return 1
  fi
  if ! mv -f "${tmp_profile}" "${WGCF_DIR}/wgcf-profile.conf"; then
    rm -f "${tmp_profile}" >/dev/null 2>&1 || true
    return 1
  fi
  return 0
}

warp_tier_show_status() {
  local target live svc_state license_raw license_masked
  target="$(warp_tier_target_effective_get)"
  live="$(warp_live_tier_get)"
  license_raw="$(warp_plus_license_state_get)"
  license_masked="$(warp_plus_license_mask "${license_raw}")"
  warp_tier_state_seed_from_live
  if svc_exists wireproxy; then
    svc_state="$(svc_state wireproxy)"
  else
    svc_state="not-installed"
  fi

  printf "Target Tier   : %s\n" "${target}"
  printf "Live Tier     : %s\n" "${live}"
  printf "wireproxy     : %s\n" "${svc_state}"
  if [[ -n "${license_raw}" ]]; then
    printf "WARP+ License : %s\n" "${license_masked}"
  else
    printf "WARP+ License : (kosong)\n"
  fi
}

warp_tier_switch_free() {
  title
  echo "5) Network > WARP Controls > Switch ke WARP Free"
  hr

  local confirm_rc=0
  if ! confirm_yn_or_back "Switch ke WARP Free sekarang?"; then
    confirm_rc=$?
    if (( confirm_rc == 1 || confirm_rc == 2 )); then
      warn "Switch ke WARP Free dibatalkan."
      hr
      pause
      return 0
    fi
  fi

  local rc
  (
    local snap_dir stage_dir warp_txn_success="false"
    flock -x 200

    if ! have_cmd wgcf; then
      warn "wgcf tidak ditemukan. Jalankan setup.sh terlebih dulu."
      hr
      pause
      exit 1
    fi
    if ! have_cmd wireproxy; then
      warn "wireproxy tidak ditemukan. Jalankan setup.sh terlebih dulu."
      hr
      pause
      exit 1
    fi

    mkdir -p "${WGCF_DIR}"
    snap_dir="$(mktemp -d "${WORK_DIR}/.warp-free.XXXXXX" 2>/dev/null || true)"
    [[ -n "${snap_dir}" ]] || snap_dir="${WORK_DIR}/.warp-free.$$"
    mkdir -p "${snap_dir}" 2>/dev/null || true
    if ! warp_runtime_snapshot_capture "${snap_dir}"; then
      warn "Gagal membuat snapshot WARP sebelum switch free."
      rm -rf "${snap_dir}" >/dev/null 2>&1 || true
      hr
      pause
      exit 1
    fi
    trap 'if [[ "${warp_txn_success}" != "true" ]]; then warp_runtime_snapshot_restore_on_abort "${snap_dir}"; fi' EXIT
    stage_dir="$(mktemp -d "${WORK_DIR}/.warp-free-stage.XXXXXX" 2>/dev/null || true)"
    [[ -n "${stage_dir}" ]] || stage_dir="${WORK_DIR}/.warp-free-stage.$$"
    mkdir -p "${stage_dir}" 2>/dev/null || true
    if ! warp_wgcf_seed_stage_from_live_account "${stage_dir}"; then
      rm -rf "${stage_dir}" >/dev/null 2>&1 || true
      warp_runtime_snapshot_restore_or_fail "${snap_dir}" "Gagal menyalin akun WGCF lama ke staging WARP free."
    fi
    if ! warp_wgcf_build_profile_in_dir "${stage_dir}" free; then
      rm -rf "${stage_dir}" >/dev/null 2>&1 || true
      warp_runtime_snapshot_restore_or_fail "${snap_dir}" "Gagal build profile WARP free."
    fi
    if ! warp_wgcf_install_live_files_from_dir "${stage_dir}"; then
      rm -rf "${stage_dir}" >/dev/null 2>&1 || true
      warp_runtime_snapshot_restore_or_fail "${snap_dir}" "Gagal menyiapkan file WARP free baru."
    fi
    rm -rf "${stage_dir}" >/dev/null 2>&1 || true
    if ! warp_wireproxy_apply_profile "${WGCF_DIR}/wgcf-profile.conf"; then
      warp_runtime_snapshot_restore_or_fail "${snap_dir}" "Gagal apply profile WARP free ke wireproxy."
    fi

    if ! warp_wireproxy_restart_checked; then
      warp_runtime_snapshot_restore_or_fail "${snap_dir}" "wireproxy tidak aktif setelah switch WARP free."
    fi
    local tier_wait_rc=0
    if ! warp_live_tier_wait_for free 20; then
      tier_wait_rc=$?
    fi
    if (( tier_wait_rc == 1 )); then
      warp_runtime_snapshot_restore_or_fail "${snap_dir}" "Live WARP tier tidak sesuai target free setelah switch."
    elif (( tier_wait_rc == 2 )); then
      warn "Probe tier WARP free belum memberi jawaban pasti; menyimpan state target tanpa rollback keras."
    fi
    if ! network_state_set_many "${WARP_TIER_STATE_KEY}" "free"; then
      warp_runtime_snapshot_restore_or_fail "${snap_dir}" "Gagal menyimpan target tier WARP free."
    fi
    log "WARP tier target di-set: free"
    warp_txn_success="true"
    trap - EXIT
    rm -rf "${snap_dir}" >/dev/null 2>&1 || true
    hr
    warp_tier_show_status
    hr
    pause
  ) 200>"${WARP_LOCK_FILE}"
  rc=$?
  return "${rc}"
}

warp_tier_switch_plus() {
  local rc
  title
  echo "5) Network > WARP Controls > Switch ke WARP Plus"
  hr

  local confirm_rc=0
  if ! confirm_yn_or_back "Switch ke WARP Plus sekarang?"; then
    confirm_rc=$?
    if (( confirm_rc == 1 || confirm_rc == 2 )); then
      warn "Switch ke WARP Plus dibatalkan."
      hr
      pause
      return 0
    fi
  fi

  (
    local saved_key key masked snap_dir stage_dir warp_txn_success="false"
    flock -x 200

    if ! have_cmd wgcf; then
      warn "wgcf tidak ditemukan. Jalankan setup.sh terlebih dulu."
      hr
      pause
      exit 1
    fi
    if ! have_cmd wireproxy; then
      warn "wireproxy tidak ditemukan. Jalankan setup.sh terlebih dulu."
      hr
      pause
      exit 1
    fi

    saved_key="$(warp_plus_license_state_get)"
    masked="$(warp_plus_license_mask "${saved_key}")"
    if [[ -n "${saved_key}" ]]; then
      echo "License tersimpan: ${masked}"
      read -r -p "Input WARP+ License Key (Enter=pakai tersimpan, atau kembali): " key
      if is_back_choice "${key}"; then
        exit 0
      fi
      key="$(echo "${key}" | tr -d '[:space:]')"
      [[ -n "${key}" ]] || key="${saved_key}"
    else
      read -r -p "Input WARP+ License Key (atau kembali): " key
      if is_back_choice "${key}"; then
        exit 0
      fi
      key="$(echo "${key}" | tr -d '[:space:]')"
    fi

    if [[ -z "${key}" ]]; then
      warn "License key WARP+ kosong"
      hr
      pause
      exit 1
    fi

    snap_dir="$(mktemp -d "${WORK_DIR}/.warp-plus.XXXXXX" 2>/dev/null || true)"
    [[ -n "${snap_dir}" ]] || snap_dir="${WORK_DIR}/.warp-plus.$$"
    mkdir -p "${snap_dir}" 2>/dev/null || true
    if ! warp_runtime_snapshot_capture "${snap_dir}"; then
      warn "Gagal membuat snapshot WARP sebelum switch plus."
      rm -rf "${snap_dir}" >/dev/null 2>&1 || true
      hr
      pause
      exit 1
    fi
    trap 'if [[ "${warp_txn_success}" != "true" ]]; then warp_runtime_snapshot_restore_on_abort "${snap_dir}"; fi' EXIT

    stage_dir="$(mktemp -d "${WORK_DIR}/.warp-plus-stage.XXXXXX" 2>/dev/null || true)"
    [[ -n "${stage_dir}" ]] || stage_dir="${WORK_DIR}/.warp-plus-stage.$$"
    mkdir -p "${stage_dir}" 2>/dev/null || true
    if ! warp_wgcf_seed_stage_from_live_account "${stage_dir}"; then
      rm -rf "${stage_dir}" >/dev/null 2>&1 || true
      warp_runtime_snapshot_restore_or_fail "${snap_dir}" "Gagal menyalin akun WGCF lama ke staging WARP plus."
    fi
    if ! warp_wgcf_build_profile_in_dir "${stage_dir}" plus "${key}"; then
      rm -rf "${stage_dir}" >/dev/null 2>&1 || true
      warp_runtime_snapshot_restore_or_fail "${snap_dir}" "Gagal build profile WARP plus."
    fi
    if ! warp_wgcf_install_live_files_from_dir "${stage_dir}"; then
      rm -rf "${stage_dir}" >/dev/null 2>&1 || true
      warp_runtime_snapshot_restore_or_fail "${snap_dir}" "Gagal menyiapkan file WARP plus baru."
    fi
    rm -rf "${stage_dir}" >/dev/null 2>&1 || true
    if ! warp_wireproxy_apply_profile "${WGCF_DIR}/wgcf-profile.conf"; then
      warp_runtime_snapshot_restore_or_fail "${snap_dir}" "Gagal apply profile WARP plus ke wireproxy."
    fi

    if ! warp_wireproxy_restart_checked; then
      warp_runtime_snapshot_restore_or_fail "${snap_dir}" "wireproxy tidak aktif setelah switch WARP plus."
    fi
    local tier_wait_rc=0
    if ! warp_live_tier_wait_for plus 20; then
      tier_wait_rc=$?
    fi
    if (( tier_wait_rc == 1 )); then
      warp_runtime_snapshot_restore_or_fail "${snap_dir}" "Live WARP tier tidak sesuai target plus setelah switch."
    elif (( tier_wait_rc == 2 )); then
      warn "Probe tier WARP plus belum memberi jawaban pasti; menyimpan state target tanpa rollback keras."
    fi
    if ! network_state_set_many \
      "${WARP_TIER_STATE_KEY}" "plus" \
      "${WARP_PLUS_LICENSE_STATE_KEY}" "${key}"; then
      warp_runtime_snapshot_restore_or_fail "${snap_dir}" "Gagal menyimpan target tier WARP plus."
    fi
    log "WARP tier target di-set: plus"
    warp_txn_success="true"
    trap - EXIT
    rm -rf "${snap_dir}" >/dev/null 2>&1 || true
    hr
    warp_tier_show_status
    hr
    pause
  ) 200>"${WARP_LOCK_FILE}"
  rc=$?
  return "${rc}"
}

warp_tier_reconnect_regenerate() {
  local rc
  title
  echo "5) Network > WARP Controls > Reconnect/Regenerate"
  hr

  local confirm_rc=0
  if ! confirm_yn_or_back "Reconnect/Regenerate WARP sesuai target sekarang?"; then
    confirm_rc=$?
    if (( confirm_rc == 1 || confirm_rc == 2 )); then
      warn "Reconnect/Regenerate WARP dibatalkan."
      hr
      pause
      return 0
    fi
  fi

  (
    local target key snap_dir stage_dir warp_txn_success="false"
    flock -x 200

    if ! have_cmd wgcf; then
      warn "wgcf tidak ditemukan. Jalankan setup.sh terlebih dulu."
      hr
      pause
      exit 1
    fi
    if ! have_cmd wireproxy; then
      warn "wireproxy tidak ditemukan. Jalankan setup.sh terlebih dulu."
      hr
      pause
      exit 1
    fi

    target="$(warp_tier_reconnect_target_get)"
    if [[ "${target}" != "free" && "${target}" != "plus" ]]; then
      target="free"
    fi

    snap_dir="$(mktemp -d "${WORK_DIR}/.warp-reconnect.XXXXXX" 2>/dev/null || true)"
    [[ -n "${snap_dir}" ]] || snap_dir="${WORK_DIR}/.warp-reconnect.$$"
    mkdir -p "${snap_dir}" 2>/dev/null || true
    if ! warp_runtime_snapshot_capture "${snap_dir}"; then
      warn "Gagal membuat snapshot WARP sebelum reconnect."
      rm -rf "${snap_dir}" >/dev/null 2>&1 || true
      hr
      pause
      exit 1
    fi
    trap 'if [[ "${warp_txn_success}" != "true" ]]; then warp_runtime_snapshot_restore_on_abort "${snap_dir}"; fi' EXIT
    stage_dir="$(mktemp -d "${WORK_DIR}/.warp-reconnect-stage.XXXXXX" 2>/dev/null || true)"
    [[ -n "${stage_dir}" ]] || stage_dir="${WORK_DIR}/.warp-reconnect-stage.$$"
    mkdir -p "${stage_dir}" 2>/dev/null || true
    if ! warp_wgcf_seed_stage_from_live_account "${stage_dir}"; then
      rm -rf "${stage_dir}" >/dev/null 2>&1 || true
      warp_runtime_snapshot_restore_or_fail "${snap_dir}" "Gagal menyalin akun WGCF lama ke staging reconnect."
    fi
    if [[ "${target}" == "plus" ]]; then
      key="$(warp_plus_license_state_get)"
      key="$(echo "${key}" | tr -d '[:space:]')"
      if [[ -z "${key}" ]]; then
        rm -rf "${stage_dir}" >/dev/null 2>&1 || true
        rm -rf "${snap_dir}" >/dev/null 2>&1 || true
        warn "Target plus aktif, tapi license key kosong. Gunakan menu Switch ke WARP Plus dulu."
        hr
        pause
        exit 1
      fi
      if ! warp_wgcf_build_profile_in_dir "${stage_dir}" plus "${key}"; then
        rm -rf "${stage_dir}" >/dev/null 2>&1 || true
        warp_runtime_snapshot_restore_or_fail "${snap_dir}" "Gagal build profile WARP plus saat reconnect."
      fi
    else
      if ! warp_wgcf_build_profile_in_dir "${stage_dir}" free; then
        rm -rf "${stage_dir}" >/dev/null 2>&1 || true
        warp_runtime_snapshot_restore_or_fail "${snap_dir}" "Gagal build profile WARP free saat reconnect."
      fi
    fi

    if ! warp_wgcf_install_live_files_from_dir "${stage_dir}"; then
      rm -rf "${stage_dir}" >/dev/null 2>&1 || true
      warp_runtime_snapshot_restore_or_fail "${snap_dir}" "Gagal menyiapkan file WARP reconnect baru."
    fi
    rm -rf "${stage_dir}" >/dev/null 2>&1 || true
    if ! warp_wireproxy_apply_profile "${WGCF_DIR}/wgcf-profile.conf"; then
      warp_runtime_snapshot_restore_or_fail "${snap_dir}" "Gagal apply profile WARP saat reconnect."
    fi

    if ! warp_wireproxy_restart_checked; then
      warp_runtime_snapshot_restore_or_fail "${snap_dir}" "wireproxy tidak aktif setelah reconnect/regenerate."
    fi
    local tier_wait_rc=0
    if ! warp_live_tier_wait_for "${target}" 20; then
      tier_wait_rc=$?
    fi
    if (( tier_wait_rc == 1 )); then
      warp_runtime_snapshot_restore_or_fail "${snap_dir}" "Live WARP tier tidak sesuai target setelah reconnect/regenerate."
    elif (( tier_wait_rc == 2 )); then
      warn "Probe tier WARP belum memberi jawaban pasti setelah reconnect/regenerate; menyimpan state target tanpa rollback keras."
    fi

    if ! network_state_set_many "${WARP_TIER_STATE_KEY}" "${target}" >/dev/null 2>&1; then
      warp_runtime_snapshot_restore_or_fail "${snap_dir}" "Gagal menyimpan target tier WARP setelah reconnect."
    fi
    warp_txn_success="true"
    trap - EXIT
    rm -rf "${snap_dir}" >/dev/null 2>&1 || true
    log "Reconnect/regenerate selesai untuk target tier: ${target}"
    hr
    warp_tier_show_status
    hr
    pause
  ) 200>"${WARP_LOCK_FILE}"
  rc=$?
  return "${rc}"
}

warp_tier_menu() {
  while true; do
    title
    echo "5) Network > WARP Controls > WARP Tier (Free/Plus)"
    hr
    warp_tier_show_status
    hr
    echo "  1) Show status"
    echo "  2) Switch ke WARP Free"
    echo "  3) Switch ke WARP Plus"
    echo "  4) Reconnect/Regenerate sesuai target"
    echo "  0) Back"
    hr
    read -r -p "Pilih: " c
    case "${c}" in
      1)
        title
        echo "5) Network > WARP Controls > WARP Tier Status"
        hr
        warp_tier_show_status
        hr
        pause
        ;;
      2)
        if ! warp_tier_switch_free; then
          :
        fi
        ;;
      3)
        if ! warp_tier_switch_plus; then
          :
        fi
        ;;
      4)
        if ! warp_tier_reconnect_regenerate; then
          :
        fi
        ;;
      0|kembali|k|back|b) break ;;
      *) warn "Pilihan tidak valid" ; sleep 1 ;;
    esac
  done
}

warp_controls_menu() {
  local -a items=(
    "1|WARP Status"
    "2|Restart WARP"
    "3|WARP Global"
    "4|Per User"
    "5|Per Inbound"
    "6|Per Domain"
    "7|WARP Tier"
    "0|Back"
  )
  while true; do
    ui_menu_screen_begin "5) Network > WARP"
    ui_menu_render_options items 76
    hr
    read -r -p "Pilih: " c
    case "${c}" in
      1) warp_status ;;
      2)
        title
        echo "Restart wireproxy"
        hr
        if ! confirm_yn_or_back "Restart wireproxy sekarang?"; then
          warn "Restart wireproxy dibatalkan."
          hr
          pause
          continue
        fi
        if svc_exists wireproxy; then
          if ! warp_wireproxy_post_restart_health_check; then
            warn "Restart wireproxy gagal."
            hr
            pause
            continue
          fi
        else
          warn "wireproxy.service tidak terdeteksi"
        fi
        hr
        pause
        ;;
      3) menu_run_isolated_report "WARP Global" warp_global_menu ;;
      4) menu_run_isolated_report "WARP Per User" warp_per_user_menu ;;
      5) menu_run_isolated_report "WARP Per Inbounds" warp_per_inbounds_menu ;;
      6) menu_run_isolated_report "WARP Domain Geosite" warp_domain_geosite_menu ;;
      7) menu_run_isolated_report "WARP Tier" warp_tier_menu ;;
      0|kembali|k|back|b) break ;;
      *) warn "Pilihan tidak valid" ; sleep 1 ;;
    esac
  done
}

domain_geosite_menu() {
  need_python3
  local routing_candidate=""
  local pending_changes="false"
  local source_file="" c="" ent="" no="" remove_entry=""
  while true; do
    source_file="${routing_candidate:-${XRAY_ROUTING_CONF}}"
    title
    echo "5) Network > Domain/Geosite Routing (Direct List)"
    hr
    if [[ "${pending_changes}" == "true" ]]; then
      echo "Mode edit : STAGED"
      echo "Catatan   : perubahan belum diterapkan ke runtime."
      hr
    fi
    echo "Template (readonly):"
    python3 - <<'PY' "${XRAY_ROUTING_CONF}" 2>/dev/null || true
import json, sys
src=sys.argv[1]
try:
  with open(src,'r',encoding='utf-8') as f:
    cfg=json.load(f)
except Exception:
  raise SystemExit(0)
rules=((cfg.get('routing') or {}).get('rules') or [])
tpl=None
for r in rules:
  if not isinstance(r, dict):
    continue
  if r.get('type') != 'field':
    continue
  if r.get('outboundTag') != 'direct':
    continue
  dom=r.get('domain') or []
  if isinstance(dom, list) and ('geosite:apple' in dom or 'geosite:google' in dom):
    tpl=dom
    break
if not isinstance(tpl, list):
  tpl=[]
for i,d in enumerate([x for x in tpl if isinstance(x,str)] , start=1):
  print(f"  {i:>2}. {d}")
PY
    hr

    echo "Editable (custom direct list):"
    local -a direct_entries=()
    mapfile -t direct_entries < <(xray_routing_custom_domain_list_get "regexp:^$" "direct" "${source_file}" 2>/dev/null || true)
    if (( ${#direct_entries[@]} == 0 )); then
      echo "  (kosong)"
    else
      local i
      for (( i=0; i<${#direct_entries[@]}; i++ )); do
        printf "  %2d. %s\n" "$((i + 1))" "${direct_entries[$i]}"
      done
    fi
    hr

    echo "  1) Add domain/geosite ke custom list"
    echo "  2) Remove domain/geosite dari custom list"
    if [[ "${pending_changes}" == "true" ]]; then
      echo "  3) Apply staged changes"
      echo "  4) Discard staged changes"
    fi
    echo "  0) Back"
    hr
    read -r -p "Pilih: " c
    case "${c}" in
      1)
        read -r -p "Masukkan entry (contoh: geosite:twitter / example.com) (atau kembali): " ent
        if is_back_choice "${ent}"; then
          continue
        fi
        ent="$(echo "${ent}" | tr -d '[:space:]')"
        if [[ -z "${ent}" ]]; then
          warn "Entry kosong"
          pause
          continue
        fi
        if [[ "${ent}" == "regexp:^$" ]]; then
          warn "Entry reserved"
          pause
          continue
        fi
        if ! routing_custom_domain_entry_valid "${ent}"; then
          warn "Entry harus berupa geosite:nama atau domain yang valid."
          pause
          continue
        fi
        if ! confirm_menu_apply_now "Stage entry ${ent} ke custom direct list sekarang?"; then
          pause
          continue
        fi
        if ! xray_routing_candidate_prepare routing_candidate; then
          warn "Gagal menyiapkan staging routing."
          pause
          continue
        fi
        if ! xray_routing_custom_domain_entry_set_mode_in_file "${routing_candidate}" "${routing_candidate}" direct "${ent}"; then
          warn "Gagal men-stage custom direct list."
          pause
          continue
        fi
        pending_changes="true"
        log "Entry di-stage: ${ent}"
        pause
        ;;
      2)
        read -r -p "Hapus nomor entry (lihat daftar) (atau kembali): " no
        if is_back_word_choice "${no}"; then
          continue
        fi
        if [[ -z "${no}" || ! "${no}" =~ ^[0-9]+$ || "${no}" -le 0 ]]; then
          warn "Nomor tidak valid"
          pause
          continue
        fi
        if (( no > ${#direct_entries[@]} )); then
          warn "Nomor di luar range"
          pause
          continue
        fi
        remove_entry="${direct_entries[$((no - 1))]}"
        if [[ -z "${remove_entry}" ]]; then
          warn "Nomor di luar range"
          pause
          continue
        fi
        if ! confirm_menu_apply_now "Stage penghapusan entry ${remove_entry} dari custom direct list sekarang?"; then
          pause
          continue
        fi
        if ! xray_routing_candidate_prepare routing_candidate; then
          warn "Gagal menyiapkan staging routing."
          pause
          continue
        fi
        if ! xray_routing_custom_domain_entry_set_mode_in_file "${routing_candidate}" "${routing_candidate}" off "${remove_entry}"; then
          warn "Gagal men-stage penghapusan custom direct list."
          pause
          continue
        fi
        pending_changes="true"
        log "Entry di-stage untuk dihapus: ${remove_entry}"
        pause
        ;;
      3)
        if [[ "${pending_changes}" != "true" ]]; then
          warn "Pilihan tidak valid"
          sleep 1
          continue
        fi
        if ! confirm_menu_apply_now "Apply staged direct routing changes sekarang?"; then
          pause
          continue
        fi
        if ! xray_routing_apply_candidate_file "${routing_candidate}"; then
          pause
          continue
        fi
        rm -f "${routing_candidate}" >/dev/null 2>&1 || true
        routing_candidate=""
        pending_changes="false"
        log "Staged direct routing changes diterapkan."
        pause
        ;;
      4)
        if [[ "${pending_changes}" != "true" ]]; then
          warn "Pilihan tidak valid"
          sleep 1
          continue
        fi
        if confirm_menu_apply_now "Buang staged direct routing changes?"; then
          rm -f "${routing_candidate}" >/dev/null 2>&1 || true
          routing_candidate=""
          pending_changes="false"
          log "Staged direct routing changes dibuang."
        fi
        pause
        ;;
      0|kembali|k|back|b)
        if [[ "${pending_changes}" == "true" ]]; then
          local back_rc=0
          if confirm_yn_or_back "Apply staged direct routing changes sebelum keluar? Pilih no untuk membuang staging."; then
            if ! xray_routing_apply_candidate_file "${routing_candidate}"; then
              pause
              continue
            fi
          else
            back_rc=$?
            if (( back_rc == 2 )); then
              continue
            fi
          fi
        fi
        rm -f "${routing_candidate}" >/dev/null 2>&1 || true
        break
        ;;
      *) warn "Pilihan tidak valid" ; sleep 1 ;;
    esac
  done
}


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
  # primary=<...>
  # secondary=<...>
  # strategy=<...>
  # cache=on|off
  local src_file="${1:-${XRAY_DNS_CONF}}"
  need_python3

  if [[ ! -f "${src_file}" ]]; then
    echo "primary="
    echo "secondary="
    echo "strategy="
    echo "cache=on"
    return 0
  fi

  python3 - <<'PY' "${src_file}" 2>/dev/null || true
import json, sys

src=sys.argv[1]
try:
  with open(src,'r',encoding='utf-8') as f:
    cfg=json.load(f)
except Exception:
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
    cp -a "${XRAY_DNS_CONF}" "${_out_ref}" || {
      rm -f -- "${_out_ref}" >/dev/null 2>&1 || true
      _out_ref=""
      return 1
    }
  else
    printf '{\n  "dns": {}\n}\n' > "${_out_ref}" || {
      rm -f -- "${_out_ref}" >/dev/null 2>&1 || true
      _out_ref=""
      return 1
    }
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

path, action, value = sys.argv[1:4]
action = str(action or "").strip()
value = str(value or "").strip()

if os.path.isfile(path):
  try:
    with open(path, "r", encoding="utf-8") as f:
      cfg = json.load(f)
  except Exception:
    cfg = {}
else:
  cfg = {}
if not isinstance(cfg, dict):
  cfg = {}

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

src, dst, val = sys.argv[1:4]
val=str(val).strip()

with open(src,'r',encoding='utf-8') as f:
  try:
    cfg=json.load(f)
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

src, dst, val = sys.argv[1:4]
val=str(val).strip()

with open(src,'r',encoding='utf-8') as f:
  try:
    cfg=json.load(f)
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

src, dst, val = sys.argv[1:4]
val=str(val).strip()

with open(src,'r',encoding='utf-8') as f:
  try:
    cfg=json.load(f)
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

src, dst = sys.argv[1:3]
with open(src,'r',encoding='utf-8') as f:
  try:
    cfg=json.load(f)
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
  local primary secondary strategy cache
  primary="$(xray_dns_status_get "${src_file}" | awk -F'=' '/^primary=/{print $2; exit}' 2>/dev/null || true)"
  secondary="$(xray_dns_status_get "${src_file}" | awk -F'=' '/^secondary=/{print $2; exit}' 2>/dev/null || true)"
  strategy="$(xray_dns_status_get "${src_file}" | awk -F'=' '/^strategy=/{print $2; exit}' 2>/dev/null || true)"
  cache="$(xray_dns_status_get "${src_file}" | awk -F'=' '/^cache=/{print $2; exit}' 2>/dev/null || true)"

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
  local status_source="" status_label="" primary="" secondary="" strategy="" cache=""
  while true; do
    status_source="${dns_candidate:-${XRAY_DNS_CONF}}"
    status_label="LIVE"
    if [[ "${pending_changes}" == "true" && -n "${dns_candidate}" ]]; then
      status_label="STAGED"
    fi
    primary="$(xray_dns_status_get "${status_source}" | awk -F'=' '/^primary=/{print $2; exit}' 2>/dev/null || true)"
    secondary="$(xray_dns_status_get "${status_source}" | awk -F'=' '/^secondary=/{print $2; exit}' 2>/dev/null || true)"
    strategy="$(xray_dns_status_get "${status_source}" | awk -F'=' '/^strategy=/{print $2; exit}' 2>/dev/null || true)"
    cache="$(xray_dns_status_get "${status_source}" | awk -F'=' '/^cache=/{print $2; exit}' 2>/dev/null || true)"
    [[ -n "${primary}" ]] || primary="-"
    [[ -n "${secondary}" ]] || secondary="-"
    [[ -n "${strategy}" ]] || strategy="-"
    [[ -n "${cache}" ]] || cache="on"

    title
    echo "5) Network > DNS Settings"
    hr
    echo "Source status : ${status_label}"
    echo "Primary DNS   : ${primary}"
    echo "Secondary DNS : ${secondary}"
    echo "QueryStrategy : ${strategy}"
    echo "DNS Cache     : $( [[ "${cache}" == "on" ]] && echo ON || echo OFF )"
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
        current_primary="$(xray_dns_status_get "${status_source}" | awk -F'=' '/^primary=/{print $2; exit}' 2>/dev/null || true)"
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
          if ! confirm_menu_apply_now "Apply semua staged DNS changes sekarang?"; then
            pause
            continue
          fi
          if ! dns_settings_run_mutation "Staged DNS settings applied" xray_dns_apply_candidate_file "${dns_candidate}"; then
            pause
            continue
          fi
          rm -f "${dns_candidate}" >/dev/null 2>&1 || true
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
          rm -f "${dns_candidate}" >/dev/null 2>&1 || true
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
          if confirm_yn_or_back "Apply staged DNS changes sebelum keluar? Pilih no untuk membuang staging."; then
            if ! dns_settings_run_mutation "Staged DNS settings applied" xray_dns_apply_candidate_file "${dns_candidate}"; then
              pause
              continue
            fi
          else
            back_rc=$?
            if (( back_rc == 2 )); then
              continue
            fi
            rm -f "${dns_candidate}" >/dev/null 2>&1 || true
            log "Staged DNS changes dibuang."
          fi
        fi
        rm -f "${dns_candidate}" >/dev/null 2>&1 || true
        break
        ;;
      *) warn "Pilihan tidak valid" ; sleep 1 ;;
    esac
  done
}

dns_addons_menu() {
  while true; do
    title
    echo "5) Network > DNS Add-ons"
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
    echo "  1) Open DNS config with nano"
    echo "  0) Back"
    hr
    read -r -p "Pilih: " c
    case "${c}" in
      1)
        if have_cmd nano; then
          if ! xray_dns_run_locked dns_addons_edit_with_nano; then
            pause
            return 1
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
      echo "Preview diff DNS:"
      echo "  ${diff_report}"
      preview_report_show_file "${diff_report}" || warn "Gagal membuka preview diff DNS."
      hr
    else
      rm -f "${diff_report}" >/dev/null 2>&1 || true
      diff_report=""
    fi
    if ! confirm_yn_or_back "Terapkan hasil edit DNS ke file live sekarang?"; then
      apply_rc=$?
      if (( apply_rc == 1 || apply_rc == 2 )); then
        warn "Perubahan editor DNS dibatalkan sebelum diterapkan ke file live."
        rm -f "${diff_report}" >/dev/null 2>&1 || true
        rm -rf "${snap_dir}" >/dev/null 2>&1 || true
        return 0
      fi
    elif ! xray_write_file_atomic "${XRAY_DNS_CONF}" "${edit_target}"; then
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
    fi
  fi
  rm -f "${diff_report}" >/dev/null 2>&1 || true
  rm -rf "${snap_dir}" >/dev/null 2>&1 || true
  if [[ "${fatal_dns_error}" == "true" || "${dns_edit_failed}" == "true" ]]; then
    return 1
  fi
  return 0
}

network_diagnostics_menu() {
  while true; do
    title
    echo "5) Network > Diagnostics"
    hr
    echo "  1) Show summary (routing)"
    echo "  2) Validate conf.d JSON (jq)"
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
        if svc_exists "${SSHWS_DROPBEAR_SERVICE}"; then
          systemctl status "${SSHWS_DROPBEAR_SERVICE}" --no-pager || true
        else
          warn "${SSHWS_DROPBEAR_SERVICE} tidak terdeteksi"
        fi
        hr
        if svc_exists "${SSHWS_STUNNEL_SERVICE}"; then
          systemctl status "${SSHWS_STUNNEL_SERVICE}" --no-pager || true
        else
          warn "${SSHWS_STUNNEL_SERVICE} tidak terdeteksi"
        fi
        hr
        if svc_exists "${SSHWS_PROXY_SERVICE}"; then
          systemctl status "${SSHWS_PROXY_SERVICE}" --no-pager || true
        else
          warn "${SSHWS_PROXY_SERVICE} tidak terdeteksi"
        fi
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
    "5|Adblock"
    "0|Back"
  )
  while true; do
    ui_menu_screen_begin "5) Network"
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
      5) menu_run_isolated_report "Adblock" adblock_menu ;;
      0|kembali|k|back|b) break ;;
      *) invalid_choice ;;
    esac
  done
}

# -------------------------
# Speedtest
# -------------------------
speedtest_bin_get() {
  if have_cmd speedtest; then
    echo "speedtest"
    return 0
  fi
  if [[ -x /snap/bin/speedtest ]]; then
    echo "/snap/bin/speedtest"
    return 0
  fi
  echo ""
}

speedtest_run_now() {
  title
  echo "7) Speedtest > Run"
  hr

  local speedtest_bin
  speedtest_bin="$(speedtest_bin_get)"
  if [[ -z "${speedtest_bin}" ]]; then
    warn "speedtest belum tersedia. Jalankan setup.sh untuk install speedtest via snap."
    hr
    pause
    return 0
  fi

  local spin_log=""
  if ! ui_run_logged_command_with_spinner spin_log "Menjalankan speedtest" "${speedtest_bin}" --accept-license --accept-gdpr; then
    warn "Speedtest gagal dijalankan."
    hr
    tail -n 60 "${spin_log}" 2>/dev/null || true
    hr
    rm -f "${spin_log}" >/dev/null 2>&1 || true
    pause
    return 0
  fi
  if [[ -n "${spin_log}" && -s "${spin_log}" ]]; then
    cat "${spin_log}" 2>/dev/null || true
  fi
  rm -f "${spin_log}" >/dev/null 2>&1 || true
  hr
  pause
}

speedtest_show_version() {
  title
  echo "7) Speedtest > Version"
  hr

  local speedtest_bin
  speedtest_bin="$(speedtest_bin_get)"
  if [[ -z "${speedtest_bin}" ]]; then
    warn "speedtest belum tersedia."
    hr
    pause
    return 0
  fi

  if ! "${speedtest_bin}" --version 2>/dev/null; then
    warn "Tidak bisa membaca versi speedtest."
  fi
  hr
  pause
}

speedtest_menu() {
  local -a items=(
    "1|Run Speedtest"
    "2|Version"
    "0|Back"
  )
  while true; do
    ui_menu_screen_begin "7) Speedtest"
    ui_menu_render_options items 76
    hr
    if ! read -r -p "Pilih: " c; then
      echo
      break
    fi
    case "${c}" in
      1) speedtest_run_now ;;
      2) speedtest_show_version ;;
      0|kembali|k|back|b) break ;;
      *) warn "Pilihan tidak valid" ; sleep 1 ;;
    esac
  done
}

# -------------------------
