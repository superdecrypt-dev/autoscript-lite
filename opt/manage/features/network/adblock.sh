#!/usr/bin/env bash
# shellcheck shell=bash

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

  need_python3
    printf 'enabled=0\ndns_port=-\nupstream_primary=1.1.1.1\nupstream_secondary=8.8.8.8\nauto_update_enabled=0\n'
    return 0
  }
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

print(f"auto_update_enabled={data.get('AUTOSCRIPT_ADBLOCK_AUTO_UPDATE_ENABLED', '0')}")
print(f"auto_update_days={data.get('AUTOSCRIPT_ADBLOCK_AUTO_UPDATE_DAYS', '1')}")
PY
}

  local cfg dns_port primary secondary
  dns_port="$(printf '%s\n' "${cfg}" | awk -F'=' '/^dns_port=/{print $2; exit}')"
  primary="$(printf '%s\n' "${cfg}" | awk -F'=' '/^upstream_primary=/{print $2; exit}')"
  secondary="$(printf '%s\n' "${cfg}" | awk -F'=' '/^upstream_secondary=/{print $2; exit}')"
  [[ -n "${primary}" ]] || primary="1.1.1.1"
  [[ -n "${secondary}" ]] || secondary="8.8.8.8"
  printf 'dns_port=%s\n' "${dns_port}"
  printf 'upstream_primary=%s\n' "${primary}"
  printf 'upstream_secondary=%s\n' "${secondary}"
}

  if [[ "${ADBLOCK_LOCK_HELD:-0}" != "1" ]]; then
    return $?
  fi
  local cfg dns_port primary secondary tmp
  dns_port="$(printf '%s\n' "${cfg}" | awk -F'=' '/^dns_port=/{print $2; exit}')"
  primary="$(printf '%s\n' "${cfg}" | awk -F'=' '/^upstream_primary=/{print $2; exit}')"
  secondary="$(printf '%s\n' "${cfg}" | awk -F'=' '/^upstream_secondary=/{print $2; exit}')"
  primary="$(dns_server_literal_normalize "${primary}")" || primary="1.1.1.1"
  secondary="$(dns_server_literal_normalize "${secondary}")" || secondary="8.8.8.8"

  cat > "${tmp}" <<EOF
port=${dns_port}
listen-address=127.0.0.1
bind-interfaces
no-resolv
no-hosts
domain-needed
bogus-priv
cache-size=1000
server=${primary}
server=${secondary}
EOF
    rm -f "${tmp}" >/dev/null 2>&1 || true
    return 1
  }
  return 0
}

  if [[ "${ADBLOCK_LOCK_HELD:-0}" != "1" ]]; then
    return $?
  fi
      return 1
    }
  else
      return 1
    }
  fi
}

  if [[ "${ADBLOCK_LOCK_HELD:-0}" != "1" ]]; then
    return $?
  fi
  local primary="${1:-}"
  local secondary="${2:-}"
  primary="$(dns_server_literal_normalize "${primary}")" || return 1
  secondary="$(dns_server_literal_normalize "${secondary}")" || return 1
    adblock_config_set_values \
}

  if [[ "${ADBLOCK_LOCK_HELD:-0}" != "1" ]]; then
    return $?
  fi
  local value="${1:-0}"
  need_python3
  [[ "${value}" == "0" || "${value}" == "1" ]] || return 1
  local tmp
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
    found = True
  else:
    out.append(line)
if not found:
dst.write_text("\n".join(out).rstrip("\n") + "\n", encoding="utf-8")
PY
  local rc=$?
  if (( rc == 0 )); then
      rm -f "${tmp}" >/dev/null 2>&1 || true
      return 1
    }
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
      rm -f "${tmp}" >/dev/null 2>&1 || true
      return 1
    }
  else
    rm -f "${tmp}" >/dev/null 2>&1 || true
  fi
  return "${rc}"
}

  local raw_status=""
    local cfg auto_update_enabled auto_update_days
    auto_update_enabled="$(printf '%s\n' "${cfg}" | awk -F'=' '/^auto_update_enabled=/{print $2; exit}')"
    auto_update_days="$(printf '%s\n' "${cfg}" | awk -F'=' '/^auto_update_days=/{print $2; exit}')"
    [[ -n "${auto_update_days}" ]] || auto_update_days="1"
    printf '%s\n' "${cfg}"
    printf 'dns_service=missing\n'
    printf 'dns_service_state=missing\n'
    printf 'sync_service=missing\n'
    printf 'sync_service_state=missing\n'
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
    printf 'auto_update_service_state=missing\n'
    printf 'auto_update_timer=%s\n' "$([[ "${auto_update_enabled}" == "1" ]] && echo "inactive" || echo "inactive")"
    printf 'auto_update_days=%s\n' "${auto_update_days}"
    printf 'auto_update_schedule=every %s day(s)\n' "${auto_update_days}"
    printf 'last_update=-\n'
    return 0
  fi
  if [[ -z "${raw_status}" ]]; then
    return 0
  fi

  local dns_service dns_state sync_service sync_state auto_service auto_state
  dns_service="$(printf '%s\n' "${raw_status}" | awk -F'=' '/^dns_service=/{print $2; exit}')"
  dns_state="$(printf '%s\n' "${raw_status}" | awk -F'=' '/^dns_service_state=/{print $2; exit}')"
  sync_service="$(printf '%s\n' "${raw_status}" | awk -F'=' '/^sync_service=/{print $2; exit}')"
  sync_state="$(printf '%s\n' "${raw_status}" | awk -F'=' '/^sync_service_state=/{print $2; exit}')"
  auto_service="$(printf '%s\n' "${raw_status}" | awk -F'=' '/^auto_update_service=/{print $2; exit}')"
  auto_state="$(printf '%s\n' "${raw_status}" | awk -F'=' '/^auto_update_service_state=/{print $2; exit}')"

  adblock_status_token_is_service_state() {
    case "${1:-}" in
      active|inactive|failed|activating|deactivating|reloading|unknown|missing|not-found)
        return 0
        ;;
      *)
        return 1
        ;;
    esac
  }

  if [[ -z "${dns_state}" ]] && adblock_status_token_is_service_state "${dns_service}"; then
    dns_state="${dns_service}"
  fi
  if [[ -z "${sync_state}" ]] && adblock_status_token_is_service_state "${sync_service}"; then
    sync_state="${sync_service}"
  fi
  if [[ -z "${auto_state}" ]] && adblock_status_token_is_service_state "${auto_service}"; then
    auto_state="${auto_service}"
    auto_service="${ADBLOCK_AUTO_UPDATE_SERVICE}"
  fi

  printf '%s\n' "${raw_status}" | awk -F= '
    $1!="dns_service" &&
    $1!="dns_service_state" &&
    $1!="sync_service" &&
    $1!="sync_service_state" &&
    $1!="auto_update_service" &&
    $1!="auto_update_service_state" { print $0 }
  '
  printf 'dns_service=%s\n' "${dns_service:-missing}"
  printf 'dns_service_state=%s\n' "${dns_state:-missing}"
  printf 'sync_service=%s\n' "${sync_service:-missing}"
  printf 'sync_service_state=%s\n' "${sync_state:-missing}"
  printf 'auto_update_service=%s\n' "${auto_service:-missing}"
  printf 'auto_update_service_state=%s\n' "${auto_state:-missing}"
}

  if [[ "${ADBLOCK_LOCK_HELD:-0}" != "1" ]]; then
    return $?
  fi
    warn "adblock-sync tidak ditemukan. Jalankan setup.sh ulang."
    return 1
  }
      return 1
    }
  fi
}

  if [[ "${ADBLOCK_LOCK_HELD:-0}" != "1" ]]; then
    return $?
  fi
  local backup="" had_existing="0"
  local -a rollback_notes=()
  shift 3 || true

  declare -F "${apply_fn}" >/dev/null 2>&1 || return 1
  declare -F "${mutate_fn}" >/dev/null 2>&1 || return 1

    had_existing="1"
      rm -f "${backup}" >/dev/null 2>&1 || true
      return 1
    fi
  fi

  if ! "${mutate_fn}" "$@"; then
    rm -f "${backup}" >/dev/null 2>&1 || true
    return 1
  fi

  if "${apply_fn}"; then
    rm -f "${backup}" >/dev/null 2>&1 || true
    return 0
  fi

  if [[ "${had_existing}" == "1" ]]; then
      rollback_notes+=("restore config gagal")
    fi
  else
  fi

  if ! "${apply_fn}" >/dev/null 2>&1; then
    rollback_notes+=("restore runtime gagal")
  fi

  rm -f "${backup}" >/dev/null 2>&1 || true
  if ((${#rollback_notes[@]} > 0)); then
    warn "${context} gagal; rollback config/runtime tidak sepenuhnya bersih: $(IFS=' | '; echo "${rollback_notes[*]}")."
  else
    warn "${context} gagal. Config/runtime dikembalikan ke state sebelumnya."
  fi
  return 1
}

  if [[ "${ADBLOCK_LOCK_HELD:-0}" != "1" ]]; then
    return $?
  fi
  local value="${1:-0}"
  [[ "${value}" == "0" || "${value}" == "1" ]] || return 1
    "${value}"
}

adblock_update_now() {
  if [[ "${ADBLOCK_LOCK_HELD:-0}" != "1" ]]; then
    adblock_run_locked adblock_update_now "$@"
    return $?
  fi
    warn "adblock-sync tidak ditemukan. Jalankan setup.sh ulang."
    return 1
  }
  local mode="${1:-}"
  local -a args=(--update)
  if [[ "${mode}" == "reload-xray" ]]; then
    args+=(--reload-xray)
  fi
      return 1
    }
  fi
}

adblock_mark_dirty() {
  adblock_config_set_values AUTOSCRIPT_ADBLOCK_DIRTY 1
}

adblock_dirty_flag_get() {
  local status dirty
  dirty="$(printf '%s\n' "${status}" | awk -F'=' '/^dirty=/{print $2; exit}')"
  case "${dirty}" in
    1|true|TRUE|yes|on) printf '1\n' ;;
    *) printf '0\n' ;;
  esac
}

adblock_dirty_flag_restore() {
  local previous="${1:-0}"
  if [[ "${ADBLOCK_LOCK_HELD:-0}" != "1" ]]; then
    adblock_run_locked adblock_dirty_flag_restore "${previous}"
    return $?
  fi
  if [[ "${previous}" == "1" ]]; then
    adblock_mark_dirty
  else
    adblock_config_set_values AUTOSCRIPT_ADBLOCK_DIRTY 0
  fi
}

adblock_source_change_commit_and_sync() {
  local source_file="${1:-}"
  local snapshot_label="${2:-source}"
  local success_label="${3:-Perubahan source Adblock tersimpan.}"
  local prev_dirty="0" snap_dir="" restore_ok="true"
  local restore_mode="" xray_enabled=""
  local current_dirty="0"
  shift 3 || true
  if [[ "${ADBLOCK_LOCK_HELD:-0}" != "1" ]]; then
    adblock_run_locked adblock_source_change_commit_and_sync "${source_file}" "${snapshot_label}" "${success_label}" "$@"
    return $?
  fi
  [[ -n "${source_file}" ]] || return 1
  prev_dirty="$(adblock_dirty_flag_get)"
  snap_dir="$(mktemp -d "${WORK_DIR}/.adblock-source-sync.XXXXXX" 2>/dev/null || true)"
  [[ -n "${snap_dir}" ]] || snap_dir="${WORK_DIR}/.adblock-source-sync.$$"
  mkdir -p "${snap_dir}" 2>/dev/null || true
  if ! snapshot_file_capture "${source_file}" "${snap_dir}" "${snapshot_label}"; then
    warn "Gagal membuat snapshot source Adblock sebelum apply."
    rm -rf "${snap_dir}" >/dev/null 2>&1 || true
    return 1
  fi
  if ! "$@"; then
    rm -rf "${snap_dir}" >/dev/null 2>&1 || true
    return 1
  fi
  if adblock_prompt_update_after_source_change "${success_label}"; then
    rm -rf "${snap_dir}" >/dev/null 2>&1 || true
    return 0
  fi
  if ! snapshot_file_restore "${source_file}" "${snap_dir}" "${snapshot_label}" >/dev/null 2>&1; then
    restore_ok="false"
    warn "Rollback source Adblock gagal setelah auto-update gagal."
  fi
  if ! adblock_dirty_flag_restore "${prev_dirty}" >/dev/null 2>&1; then
    restore_ok="false"
    warn "Restore dirty flag Adblock gagal setelah auto-update gagal."
  fi
  if [[ "${restore_ok}" == "true" && "${prev_dirty}" == "0" ]]; then
    xray_enabled="$(xray_routing_adblock_rule_get 2>/dev/null | awk -F'=' '/^enabled=/{print $2; exit}')"
    if [[ "${xray_enabled}" == "1" ]]; then
      restore_mode="reload-xray"
    fi
    if ! adblock_update_now "${restore_mode}"; then
      sleep 1
      if ! adblock_update_now "${restore_mode}"; then
        restore_ok="false"
        adblock_mark_dirty >/dev/null 2>&1 || adblock_dirty_flag_restore "1" >/dev/null 2>&1 || true
        warn "Rollback runtime Adblock ke source sebelumnya gagal setelah auto-update source baru gagal."
      fi
    fi
  fi
  if [[ "${restore_ok}" == "true" ]]; then
    rm -rf "${snap_dir}" >/dev/null 2>&1 || true
    warn "Update Adblock otomatis gagal. Perubahan source dibatalkan agar source dan runtime tetap sinkron."
  else
    adblock_mark_dirty >/dev/null 2>&1 || adblock_dirty_flag_restore "1" >/dev/null 2>&1 || true
    current_dirty="$(adblock_dirty_flag_get)"
    warn "Update Adblock otomatis gagal dan rollback source/runtime tidak sepenuhnya bersih."
    warn "Status akhir : dirty=${current_dirty}, snapshot source dipertahankan di ${snap_dir}"
    warn "Tinjau source/runtime Adblock lalu jalankan 'Update Adblock' lagi setelah state dipastikan benar."
  fi
  return 1
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
    echo "$(adblock_menu_title "Set Auto Update Interval")"
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
    confirm_yn_or_back "Set interval Auto Update ke ${input} hari sekarang?"
    confirm_rc=$?
    if (( confirm_rc != 0 )); then
      if (( confirm_rc == 2 )); then
        warn "Set interval Auto Update dibatalkan (kembali)."
      else
        warn "Set interval Auto Update dibatalkan."
      fi
      pause
      continue
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
  if adblock_manual_domains_list | grep -Fxq "${normalized}"; then
    warn "Domain sudah ada."
    return 1
  fi
  snap_dir="$(mktemp -d "${WORK_DIR}/.adblock-domain-add.XXXXXX" 2>/dev/null || true)"
  [[ -n "${snap_dir}" ]] || snap_dir="${WORK_DIR}/.adblock-domain-add.$$"
  mkdir -p "${snap_dir}" 2>/dev/null || true
    warn "Gagal membuat snapshot blocklist sebelum update."
    rm -rf "${snap_dir}" >/dev/null 2>&1 || true
    return 1
  }
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
    rm -f "${tmp}" >/dev/null 2>&1 || true
    rm -rf "${snap_dir}" >/dev/null 2>&1 || true
    warn "Gagal mengganti blocklist live."
    return 1
  fi
  if adblock_mark_dirty; then
    log "Domain Adblock ditambahkan. Jalankan Update Adblock untuk build artifact baru."
    rm -rf "${snap_dir}" >/dev/null 2>&1 || true
    return 0
  fi
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
    echo "$(adblock_menu_title "Add Domain")"
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
    confirm_yn_or_back "Tambahkan domain ${normalized} ke daftar manual Adblock sekarang?"
    confirm_rc=$?
    if (( confirm_rc != 0 )); then
      if (( confirm_rc == 2 )); then
        warn "Tambah domain Adblock dibatalkan (kembali)."
      else
        warn "Tambah domain Adblock dibatalkan."
      fi
      pause
      continue
    fi
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
  : > "${tmp}"
  for i in "${!domains[@]}"; do
    if [[ "${domains[$i]}" == "${normalized}" ]]; then
      continue
    fi
    printf '%s\n' "${domains[$i]}" >> "${tmp}"
  done
  snap_dir="$(mktemp -d "${WORK_DIR}/.adblock-domain-del.XXXXXX" 2>/dev/null || true)"
  [[ -n "${snap_dir}" ]] || snap_dir="${WORK_DIR}/.adblock-domain-del.$$"
  mkdir -p "${snap_dir}" 2>/dev/null || true
    rm -f "${tmp}" >/dev/null 2>&1 || true
    warn "Gagal membuat snapshot blocklist sebelum delete."
    rm -rf "${snap_dir}" >/dev/null 2>&1 || true
    return 1
  }
    rm -f "${tmp}" >/dev/null 2>&1 || true
    rm -rf "${snap_dir}" >/dev/null 2>&1 || true
    warn "Gagal menulis blocklist baru."
    return 1
  }
  if adblock_mark_dirty; then
    log "Domain Adblock dihapus. Jalankan Update Adblock untuk build artifact baru."
    rm -rf "${snap_dir}" >/dev/null 2>&1 || true
    return 0
  fi
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
    echo "$(adblock_menu_title "Delete Domain")"
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
    confirm_yn_or_back "Hapus domain ${selected_domain} dari daftar manual Adblock sekarang?"
    confirm_rc=$?
    if (( confirm_rc != 0 )); then
      if (( confirm_rc == 2 )); then
        warn "Delete domain Adblock dibatalkan (kembali)."
      else
        warn "Delete domain Adblock dibatalkan."
      fi
      pause
      continue
    fi
      pause
      return 0
    fi
    pause
    continue
  done
}

adblock_restore_runtime_state_checked() {
  local target_mode="off"
  local notes=()
  [[ "${want_xray}" == "1" ]] && target_mode="blocked"

  if ! xray_routing_adblock_rule_set "${target_mode}" >/dev/null 2>&1; then
    notes+=("rollback Xray gagal")
  fi

  fi

  if ((${#notes[@]} > 0)); then
    printf '%s\n' "$(IFS=' | '; echo "${notes[*]}")"
    return 1
  fi
  return 0
}

adblock_prompt_update_after_source_change() {
  local change_label="${1:-Perubahan source Adblock tersimpan.}"
  local update_mode=""
  local xray_enabled=""

  log "${change_label}"
  xray_enabled="$(xray_routing_adblock_rule_get 2>/dev/null | awk -F'=' '/^enabled=/{print $2; exit}')"
  if [[ "${xray_enabled}" == "1" ]]; then
    update_mode="reload-xray"
  fi

  log "Menjalankan Update Adblock otomatis agar artifact dan runtime langsung sinkron..."
  if adblock_update_now "${update_mode}"; then
    log "Update Adblock selesai setelah perubahan source."
    return 0
  fi

  warn "Update Adblock setelah perubahan source gagal. Status dirty dipertahankan untuk retry."
  return 1
}

adblock_action_preview_print() {
  local action="${1:-update}"
  local status dirty manual_domains merged_domains source_urls rendered_status custom_dat

  dirty="$(printf '%s\n' "${status}" | awk -F'=' '/^dirty=/{print $2; exit}')"
  manual_domains="$(printf '%s\n' "${status}" | awk -F'=' '/^manual_domains=/{print $2; exit}')"
  merged_domains="$(printf '%s\n' "${status}" | awk -F'=' '/^merged_domains=/{print $2; exit}')"
  source_urls="$(printf '%s\n' "${status}" | awk -F'=' '/^source_urls=/{print $2; exit}')"
  rendered_status="$(printf '%s\n' "${status}" | awk -F'=' '/^rendered_file=/{print $2; exit}')"
  custom_dat="$(printf '%s\n' "${status}" | awk -F'=' '/^custom_dat=/{print $2; exit}')"
  xray_enabled="$(xray_routing_adblock_rule_get 2>/dev/null | awk -F'=' '/^enabled=/{print $2; exit}')"
  xray_outbound="$(xray_routing_adblock_rule_get 2>/dev/null | awk -F'=' '/^outbound=/{print $2; exit}')"
  [[ -n "${manual_domains}" ]] || manual_domains="0"
  [[ -n "${merged_domains}" ]] || merged_domains="0"
  [[ -n "${source_urls}" ]] || source_urls="0"
  [[ -n "${dirty}" ]] || dirty="0"
  [[ -n "${rendered_status}" ]] || rendered_status="-"
  [[ -n "${custom_dat}" ]] || custom_dat="-"
  [[ -n "${xray_enabled}" ]] || xray_enabled="0"

  if [[ "${xray_enabled}" == "1" ]]; then
    update_mode="reload-xray"
  fi

  echo "Preview aksi : ${action}"
  echo "Manual list  : ${manual_domains} domain"
  echo "URL source   : ${source_urls}"
  echo "Merged list  : ${merged_domains} domain"
  echo "Dirty        : $([[ "${dirty}" == "1" ]] && echo "YES" || echo "NO")"
  echo "custom.dat   : ${custom_dat}"
  echo "Rendered DNS : ${rendered_status}"
  echo "Xray rule    : $([[ "${xray_enabled}" == "1" ]] && echo "ON" || echo "OFF") (${xray_outbound:--})"
  case "${action}" in
    enable)
      echo "Mode update  : ${update_mode}"
      ;;
    disable)
      ;;
    update)
      echo "Efek         : rebuild artifact shared source dan apply ke runtime yang relevan."
      echo "Mode update  : ${update_mode}"
      ;;
  esac
}

adblock_enable_all() {
  if [[ "${ADBLOCK_LOCK_HELD:-0}" != "1" ]]; then
    adblock_run_locked adblock_enable_all "$@"
    return $?
  fi
  local status dirty rendered_status xray_was_enabled update_mode rollback_msg=""
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

    if ! rollback_msg="$(adblock_restore_runtime_state_checked "${xray_was_enabled}" "0")"; then
      die "Rollback enable Adblock gagal: ${rollback_msg}"
    fi
    return 1
  fi

    if ! rollback_msg="$(adblock_restore_runtime_state_checked "${xray_was_enabled}" "0")"; then
      die "Rollback enable Adblock gagal: ${rollback_msg}"
    fi
    return 1
  fi

  return 0
}

adblock_disable_all() {
  if [[ "${ADBLOCK_LOCK_HELD:-0}" != "1" ]]; then
    adblock_run_locked adblock_disable_all "$@"
    return $?
  fi
  local xray_status="ON"
  previous_xray="$(xray_routing_adblock_rule_get 2>/dev/null | awk -F'=' '/^enabled=/{print $2; exit}')"

  if xray_routing_adblock_rule_set off; then
    xray_status="OFF"
  else
    warn "Xray Adblock gagal dinonaktifkan."
  fi

  else
  fi

    return 0
  fi

    die "Rollback disable Adblock gagal: ${rollback_msg}"
  fi
  return 1
}

  title
  echo "$(adblock_menu_title "Bound Users")"
  hr
    warn "adblock-sync tidak ditemukan. Jalankan setup.sh ulang."
    hr
    pause
    return 0
  fi
  local rows
  if [[ -z "${rows//[[:space:]]/}" ]]; then
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
    echo "$(adblock_menu_title "Custom Geosite")"
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

  while true; do
    local st enabled dns_port dns_service dns_state sync_service sync_state nft_table users_count entries source_urls
    enabled="$(printf '%s\n' "${st}" | awk -F'=' '/^enabled=/{print $2; exit}')"
    dns_port="$(printf '%s\n' "${st}" | awk -F'=' '/^dns_port=/{print $2; exit}')"
    dns_service="$(printf '%s\n' "${st}" | awk -F'=' '/^dns_service=/{print $2; exit}')"
    dns_state="$(printf '%s\n' "${st}" | awk -F'=' '/^dns_service_state=/{print $2; exit}')"
    sync_service="$(printf '%s\n' "${st}" | awk -F'=' '/^sync_service=/{print $2; exit}')"
    sync_state="$(printf '%s\n' "${st}" | awk -F'=' '/^sync_service_state=/{print $2; exit}')"
    nft_table="$(printf '%s\n' "${st}" | awk -F'=' '/^nft_table=/{print $2; exit}')"
    users_count="$(printf '%s\n' "${st}" | awk -F'=' '/^users_count=/{print $2; exit}')"
    entries="$(printf '%s\n' "${st}" | awk -F'=' '/^blocklist_entries=/{print $2; exit}')"
    source_urls="$(printf '%s\n' "${st}" | awk -F'=' '/^source_urls=/{print $2; exit}')"
    if [[ -z "${dns_state}" ]]; then
      if [[ -n "${dns_service}" && "${dns_service}" != "missing" ]] && svc_exists "${dns_service}"; then
        dns_state="$(svc_state "${dns_service}")"
      else
        dns_state="missing"
      fi
    fi
    if [[ -z "${sync_state}" ]]; then
      if [[ -n "${sync_service}" && "${sync_service}" != "missing" ]] && svc_exists "${sync_service}"; then
        sync_state="$(svc_state "${sync_service}")"
      else
        sync_state="missing"
      fi
    fi

    title
    hr
    printf "Rule Status   : %s\n" "$([[ "${enabled}" == "1" ]] && echo "ON" || echo "OFF")"
    printf "DNS Service   : %s\n" "${dns_service:--}"
    printf "DNS State     : %s\n" "${dns_state:--}"
    printf "Sync Service  : %s\n" "${sync_service:--}"
    printf "Sync State    : %s\n" "${sync_state:--}"
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
        else
        fi
        pause
        ;;
      2)
        else
        fi
        pause
        ;;
      3)
        ;;
      4)
        ;;
      5)
        else
        fi
        pause
        ;;
      6)
        ;;
      0|kembali|k|back|b) break ;;
      *) invalid_choice ;;
    esac
  done
}

}

  local url="${1:-}"
  url="$(printf '%s' "${url}" | tr -d '[:space:]')"
  [[ "${url}" =~ ^https?://.+$ ]] || return 1
  printf '%s\n' "${url}"
}

  local normalized="${1:-}"
  local snap_dir tmp
  [[ -n "${normalized}" ]] || return 1
    warn "URL sudah ada."
    return 1
  fi
  snap_dir="$(mktemp -d "${WORK_DIR}/.adblock-url-add.XXXXXX" 2>/dev/null || true)"
  [[ -n "${snap_dir}" ]] || snap_dir="${WORK_DIR}/.adblock-url-add.$$"
  mkdir -p "${snap_dir}" 2>/dev/null || true
    warn "Gagal membuat snapshot URL source sebelum update."
    rm -rf "${snap_dir}" >/dev/null 2>&1 || true
    return 1
  }
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
    rm -f "${tmp}" >/dev/null 2>&1 || true
    rm -rf "${snap_dir}" >/dev/null 2>&1 || true
    warn "Gagal mengganti file URL source live."
    return 1
  fi
  if adblock_mark_dirty; then
    log "URL source Adblock ditambahkan. Jalankan Update Adblock untuk build artifact baru."
    rm -rf "${snap_dir}" >/dev/null 2>&1 || true
    return 0
  fi
    warn "URL ditambahkan, tetapi status dirty gagal ditandai. Perubahan dibatalkan."
  else
    warn "URL ditambahkan, status dirty gagal ditandai, dan rollback snapshot URL juga gagal."
  fi
  rm -rf "${snap_dir}" >/dev/null 2>&1 || true
  return 1
}

  local input normalized confirm_rc=0
  while true; do
    title
    echo "$(adblock_menu_title "Add URL Source")"
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
      warn "URL tidak valid."
      pause
      continue
    }
    confirm_yn_or_back "Tambahkan URL source ${normalized} ke Adblock sekarang?"
    confirm_rc=$?
    if (( confirm_rc != 0 )); then
      if (( confirm_rc == 2 )); then
        warn "Tambah URL source Adblock dibatalkan (kembali)."
      else
        warn "Tambah URL source Adblock dibatalkan."
      fi
      pause
      continue
    fi
      pause
      return 0
    fi
    pause
    continue
  done
}

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
  if [[ "${found}" != "1" ]]; then
    warn "URL tidak ditemukan."
    return 1
  fi
  : > "${tmp}"
  for i in "${!urls[@]}"; do
    if [[ "${urls[$i]}" == "${normalized}" ]]; then
      continue
    fi
    printf '%s\n' "${urls[$i]}" >> "${tmp}"
  done
  snap_dir="$(mktemp -d "${WORK_DIR}/.adblock-url-del.XXXXXX" 2>/dev/null || true)"
  [[ -n "${snap_dir}" ]] || snap_dir="${WORK_DIR}/.adblock-url-del.$$"
  mkdir -p "${snap_dir}" 2>/dev/null || true
    rm -f "${tmp}" >/dev/null 2>&1 || true
    warn "Gagal membuat snapshot URL source sebelum delete."
    rm -rf "${snap_dir}" >/dev/null 2>&1 || true
    return 1
  }
    rm -f "${tmp}" >/dev/null 2>&1 || true
    rm -rf "${snap_dir}" >/dev/null 2>&1 || true
    warn "Gagal menulis URL source baru."
    return 1
  }
  if adblock_mark_dirty; then
    log "URL source Adblock dihapus. Jalankan Update Adblock untuk build artifact baru."
    rm -rf "${snap_dir}" >/dev/null 2>&1 || true
    return 0
  fi
    warn "URL dihapus, tetapi status dirty gagal ditandai. Perubahan dibatalkan."
  else
    warn "URL dihapus, status dirty gagal ditandai, dan rollback snapshot URL juga gagal."
  fi
  rm -rf "${snap_dir}" >/dev/null 2>&1 || true
  return 1
}

  local -a urls=()
  local line choice idx i selected_url confirm_rc=0
  while true; do
    title
    echo "$(adblock_menu_title "Delete URL Source")"
    hr
    urls=()
    while IFS= read -r line; do
      [[ -n "${line}" ]] || continue
      urls+=("${line}")
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
    confirm_yn_or_back "Hapus URL source ${selected_url} dari Adblock sekarang?"
    confirm_rc=$?
    if (( confirm_rc != 0 )); then
      if (( confirm_rc == 2 )); then
        warn "Delete URL source Adblock dibatalkan (kembali)."
      else
        warn "Delete URL source Adblock dibatalkan."
      fi
      pause
      continue
    fi
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
    local dirty manual_domains merged_domains rendered_status xray_asset last_update overall_status
    local auto_update_enabled auto_update_timer auto_update_schedule auto_update_days auto_update_service auto_update_service_state
    xray_st="$(xray_routing_adblock_rule_get 2>/dev/null || true)"
    xray_enabled="$(printf '%s\n' "${xray_st}" | awk -F'=' '/^enabled=/{print $2; exit}')"
    xray_outbound="$(printf '%s\n' "${xray_st}" | awk -F'=' '/^outbound=/{sub(/^outbound=/,""); print; exit}')"
    xray_duplicates="$(printf '%s\n' "${xray_st}" | awk -F'=' '/^duplicates=/{print $2; exit}')"

    if [[ -z "${dns_state}" ]]; then
      if [[ -n "${dns_service}" && "${dns_service}" != "missing" ]] && svc_exists "${dns_service}"; then
        dns_state="$(svc_state "${dns_service}")"
      else
        dns_state="missing"
      fi
    fi
    if [[ -z "${sync_state}" ]]; then
      if [[ -n "${sync_service}" && "${sync_service}" != "missing" ]] && svc_exists "${sync_service}"; then
        sync_state="$(svc_state "${sync_service}")"
      else
        sync_state="missing"
      fi
    fi
    if [[ -z "${auto_update_service_state}" ]]; then
      if [[ -n "${auto_update_service}" && "${auto_update_service}" != "missing" ]] && svc_exists "${auto_update_service}"; then
        auto_update_service_state="$(svc_state "${auto_update_service}")"
      else
        auto_update_service_state="missing"
      fi
    fi

      overall_status="ON"
      overall_status="PARTIAL"
    else
      overall_status="OFF"
    fi

    title
    echo "$(adblock_menu_title)"
    hr
    hr
    printf "Status       : %s\n" "${overall_status}"
    printf "Dirty        : %s\n" "$([[ "${dirty}" == "1" ]] && echo "YES" || echo "NO")"
    printf "Manual List  : %s domain\n" "${manual_domains:-0}"
    printf "URL Sources  : %s\n" "${source_urls:-0}"
    printf "Merged List  : %s domain\n" "${merged_domains:-0}"
    printf "Auto Update  : %s\n" "$([[ "${auto_update_enabled}" == "1" ]] && echo "ON" || echo "OFF")"
    printf "Update Svc   : %s\n" "${auto_update_service:--}"
    printf "Update State : %s\n" "${auto_update_service_state:--}"
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
    printf "DNS Service  : %s\n" "${dns_service:--}"
    printf "DNS State    : %s\n" "${dns_state:--}"
    printf "Sync Service : %s\n" "${sync_service:--}"
    printf "Sync State   : %s\n" "${sync_state:--}"
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
        hr
        adblock_action_preview_print enable
        hr
        if confirm_yn_or_back "Enable Adblock sekarang?"; then
          menu_run_isolated_report "Enable Adblock" adblock_enable_all
        else
          warn "Enable Adblock dibatalkan."
        fi
        pause
        ;;
      2)
        hr
        adblock_action_preview_print disable
        hr
        if confirm_yn_or_back "Disable Adblock sekarang?"; then
          menu_run_isolated_report "Disable Adblock" adblock_disable_all
        else
          warn "Disable Adblock dibatalkan."
        fi
        pause
        ;;
      3) menu_run_isolated_report "Add Adblock Domain" adblock_manual_domain_add_menu ;;
      4) menu_run_isolated_report "Delete Adblock Domain" adblock_manual_domain_delete_menu ;;
      7)
        hr
        adblock_action_preview_print update
        hr
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
