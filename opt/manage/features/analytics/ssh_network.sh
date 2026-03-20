#!/usr/bin/env bash
# shellcheck shell=bash

ssh_network_lock_prepare() {
  local lock_file="${SSH_NETWORK_LOCK_FILE:-/run/autoscript/locks/ssh-network.lock}"
  mkdir -p "$(dirname "${lock_file}")" 2>/dev/null || true
  chmod 700 "$(dirname "${lock_file}")" 2>/dev/null || true
}

ssh_network_interface_name_is_valid() {
  [[ "${1:-}" =~ ^[A-Za-z0-9._-]{1,15}$ ]]
}

ssh_network_run_locked() {
  local lock_file rc=0
  if [[ "${SSH_NETWORK_LOCK_HELD:-0}" == "1" ]]; then
    "$@"
    return $?
  fi
  ssh_network_lock_prepare
  lock_file="${SSH_NETWORK_LOCK_FILE:-/run/autoscript/locks/ssh-network.lock}"
  if have_cmd flock; then
    if (
      flock -x 200 || exit 1
      SSH_NETWORK_LOCK_HELD=1 "$@"
    ) 200>"${lock_file}"; then
      return 0
    fi
    return $?
  fi
  SSH_NETWORK_LOCK_HELD=1 "$@"
  rc=$?
  return "${rc}"
}

ssh_network_config_get() {
  need_python3
  python3 - <<'PY' "${SSH_NETWORK_CONFIG_FILE}" \
    "${SSH_NETWORK_NFT_TABLE}" \
    "${SSH_NETWORK_FWMARK}" \
    "${SSH_NETWORK_ROUTE_TABLE}" \
    "${SSH_NETWORK_RULE_PREF}" \
    "${SSH_NETWORK_WARP_INTERFACE}" \
    "${SSH_NETWORK_WARP_BACKEND}" \
    "${SSH_NETWORK_XRAY_REDIR_PORT}" \
    "${SSH_NETWORK_XRAY_REDIR_PORT_V6}"
import pathlib
import re
import sys

cfg_path = pathlib.Path(sys.argv[1])
defaults = {
  "global_mode": "direct",
  "nft_table": str(sys.argv[2] or "autoscript_ssh_network").strip() or "autoscript_ssh_network",
  "fwmark": str(sys.argv[3] or "42042").strip() or "42042",
  "route_table": str(sys.argv[4] or "42042").strip() or "42042",
  "rule_pref": str(sys.argv[5] or "14200").strip() or "14200",
  "warp_interface": str(sys.argv[6] or "warp-ssh0").strip() or "warp-ssh0",
  "warp_backend": str(sys.argv[7] or "auto").strip().lower() or "auto",
  "xray_redir_port": str(sys.argv[8] or "12345").strip() or "12345",
  "xray_redir_port_v6": str(sys.argv[9] or "12346").strip() or "12346",
}
data = {}
if cfg_path.exists():
  try:
    for line in cfg_path.read_text(encoding="utf-8").splitlines():
      line = line.strip()
      if not line or line.startswith("#") or "=" not in line:
        continue
      key, value = line.split("=", 1)
      data[key.strip()] = value.strip()
  except Exception:
    data = {}

global_mode = str(data.get("SSH_NETWORK_ROUTE_GLOBAL", defaults["global_mode"])).strip().lower()
if global_mode not in ("direct", "warp"):
  global_mode = defaults["global_mode"]

warp_backend = str(data.get("SSH_NETWORK_WARP_BACKEND", defaults["warp_backend"])).strip().lower()
if warp_backend not in ("auto", "local-proxy", "interface"):
  warp_backend = defaults["warp_backend"]

def read_num(key, fallback):
  raw = str(data.get(key, fallback)).strip()
  try:
    return str(int(float(raw)))
  except Exception:
    return str(fallback)

warp_interface = str(data.get("SSH_NETWORK_WARP_INTERFACE", defaults["warp_interface"])).strip() or defaults["warp_interface"]
if not re.fullmatch(r"[A-Za-z0-9._-]{1,15}", warp_interface):
  warp_interface = defaults["warp_interface"]

print(f"global_mode={global_mode}")
print(f"nft_table={str(data.get('SSH_NETWORK_NFT_TABLE', defaults['nft_table'])).strip() or defaults['nft_table']}")
print(f"fwmark={read_num('SSH_NETWORK_FWMARK', defaults['fwmark'])}")
print(f"route_table={read_num('SSH_NETWORK_ROUTE_TABLE', defaults['route_table'])}")
print(f"rule_pref={read_num('SSH_NETWORK_RULE_PREF', defaults['rule_pref'])}")
print(f"warp_backend={warp_backend}")
print(f"warp_interface={warp_interface}")
print(f"xray_redir_port={read_num('SSH_NETWORK_XRAY_REDIR_PORT', defaults['xray_redir_port'])}")
print(f"xray_redir_port_v6={read_num('SSH_NETWORK_XRAY_REDIR_PORT_V6', defaults['xray_redir_port_v6'])}")
PY
}

ssh_network_config_set_values() {
  local tmp
  need_python3
  mkdir -p "${SSH_NETWORK_ROOT}" 2>/dev/null || true
  touch "${SSH_NETWORK_CONFIG_FILE}"
  tmp="$(mktemp "${WORK_DIR}/.ssh-network-config.XXXXXX" 2>/dev/null || true)"
  [[ -n "${tmp}" ]] || tmp="${WORK_DIR}/.ssh-network-config.$$"
  python3 - <<'PY' "${SSH_NETWORK_CONFIG_FILE}" "${tmp}" "$@"
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
    mv -f "${tmp}" "${SSH_NETWORK_CONFIG_FILE}" || {
      rm -f "${tmp}" >/dev/null 2>&1 || true
      return 1
    }
    chmod 600 "${SSH_NETWORK_CONFIG_FILE}" >/dev/null 2>&1 || true
  else
    rm -f "${tmp}" >/dev/null 2>&1 || true
  fi
  return "${rc}"
}

ssh_network_global_mode_set() {
  local mode="${1:-}"
  case "${mode}" in
    direct|warp) ;;
    *) return 1 ;;
  esac
  ssh_network_config_set_values SSH_NETWORK_ROUTE_GLOBAL "${mode}"
}

ssh_network_warp_backend_set() {
  local backend="${1:-}"
  case "${backend}" in
    auto|local-proxy|interface) ;;
    *) return 1 ;;
  esac
  ssh_network_config_set_values SSH_NETWORK_WARP_BACKEND "${backend}"
}

ssh_network_warp_backend_effective_get_from_value() {
  local backend="${1:-auto}"
  case "${backend}" in
    local-proxy|interface)
      printf '%s\n' "${backend}"
      ;;
    *)
      if have_cmd xray && have_cmd iptables; then
        printf 'local-proxy\n'
      else
        printf 'interface\n'
      fi
      ;;
  esac
}

ssh_network_warp_backend_effective_get() {
  local cfg backend=""
  cfg="$(ssh_network_config_get)"
  backend="$(printf '%s\n' "${cfg}" | awk -F'=' '/^warp_backend=/{print $2; exit}')"
  ssh_network_warp_backend_effective_get_from_value "${backend:-auto}"
}

ssh_network_warp_backend_pretty_get() {
  local backend="${1:-auto}"
  case "${backend}" in
    local-proxy) printf 'Local Proxy\n' ;;
    local-proxy-drift) printf 'Local Proxy (Drift)\n' ;;
    interface) printf 'Dedicated Interface\n' ;;
    interface-drift) printf 'Dedicated Interface (Drift)\n' ;;
    idle) printf 'Idle / Not Applied\n' ;;
    *) printf 'Auto\n' ;;
  esac
}

ssh_network_warp_apply_path_pretty_get() {
  local backend="${1:-auto}"
  case "${backend}" in
    idle) printf 'not applied\n' ;;
    local-proxy) printf 'xray redirect + local WARP SOCKS\n' ;;
    local-proxy-drift) printf 'xray redirect + local WARP SOCKS (drift)\n' ;;
    interface) printf 'wg-quick interface + nft/ip rule\n' ;;
    interface-drift) printf 'wg-quick interface + nft/ip rule (drift)\n' ;;
    *)
      backend="$(ssh_network_warp_backend_effective_get_from_value "${backend}")"
      case "${backend}" in
        local-proxy) printf 'xray redirect + local WARP SOCKS\n' ;;
        *) printf 'wg-quick interface + nft/ip rule\n' ;;
      esac
      ;;
  esac
}

ssh_network_runtime_backend_applied_get() {
  local iptables_state="${1:-absent}" ip6tables_state="${2:-absent}" nft_state="${3:-absent}"
  local ip_rule_state="${4:-absent}" ip_rule_v6_state="${5:-absent}" route_table_v4_state="${6:-absent}"
  local route_table_v6_state="${7:-absent}" iface_state="${8:-missing}" warp_service_state="${9:-inactive}"
  local xray_redir_v4_state="${10:-not-listening}" xray_redir_v6_state="${11:-not-listening}" host_warp_proxy_state="${12:-not-listening}"

  if [[ "${iptables_state}" == "present" || "${ip6tables_state}" == "present" ]]; then
    if [[ "${host_warp_proxy_state}" != "listening" ]]; then
      printf 'local-proxy-drift\n'
      return 0
    fi
    if [[ "${iptables_state}" == "present" && "${xray_redir_v4_state}" != "active" ]]; then
      printf 'local-proxy-drift\n'
      return 0
    fi
    if [[ "${ip6tables_state}" == "present" && "${xray_redir_v6_state}" != "active" ]]; then
      printf 'local-proxy-drift\n'
      return 0
    fi
    printf 'local-proxy\n'
    return 0
  fi
  if [[ "${nft_state}" == "present" || "${ip_rule_state}" == "present" || "${ip_rule_v6_state}" == "present" ]]; then
    if [[ "${iface_state}" == "present" && "${warp_service_state}" == "active" ]]; then
      printf 'interface\n'
    else
      printf 'interface-drift\n'
    fi
    return 0
  fi
  if [[ "${route_table_v4_state}" == "present" || "${route_table_v6_state}" == "present" ]]; then
    if [[ "${iface_state}" == "present" && "${warp_service_state}" == "active" ]]; then
      printf 'interface\n'
    else
      printf 'interface-drift\n'
    fi
    return 0
  fi
  if [[ "${iface_state}" == "present" && "${warp_service_state}" == "active" ]]; then
    printf 'interface\n'
    return 0
  fi
  printf 'idle\n'
}

ssh_network_xray_redir_runtime_state_get() {
  local listener_state="${1:-not-listening}" apply_state="${2:-absent}"
  case "${listener_state}:${apply_state}" in
    listening:present) printf 'active\n' ;;
    listening:absent) printf 'standby\n' ;;
    missing:*) printf 'missing\n' ;;
    not-listening:present) printf 'drift-no-listener\n' ;;
    *) printf 'not-listening\n' ;;
  esac
}

ssh_network_xray_redir_port_get() {
  local cfg=""
  cfg="$(ssh_network_config_get)"
  printf '%s\n' "${cfg}" | awk -F'=' '/^xray_redir_port=/{print $2; exit}'
}

ssh_network_xray_redir_port_v6_get() {
  local cfg=""
  cfg="$(ssh_network_config_get)"
  printf '%s\n' "${cfg}" | awk -F'=' '/^xray_redir_port_v6=/{print $2; exit}'
}

ssh_network_xray_redir_inbound_tag_v4_get() {
  printf 'ssh-network-warp-redir-v4\n'
}

ssh_network_xray_redir_inbound_tag_v6_get() {
  printf 'ssh-network-warp-redir-v6\n'
}

ssh_network_xray_redir_chain_v4_get() {
  printf 'AUTOSCRIPT_SSH_WARP_V4\n'
}

ssh_network_xray_redir_chain_v6_get() {
  printf 'AUTOSCRIPT_SSH_WARP_V6\n'
}

ssh_network_xray_redir_mark_chain_v4_get() {
  printf 'AUTOSCRIPT_SSH_WARP_MARK_V4\n'
}

ssh_network_xray_redir_mark_chain_v6_get() {
  printf 'AUTOSCRIPT_SSH_WARP_MARK_V6\n'
}

ssh_network_host_warp_mode_get() {
  if declare -F warp_mode_display_cached_get >/dev/null 2>&1; then
    warp_mode_display_cached_get 2>/dev/null || printf 'Free/Plus\n'
  elif declare -F warp_mode_display_get >/dev/null 2>&1; then
    warp_mode_display_get 2>/dev/null || printf 'Free/Plus\n'
  else
    printf 'Free/Plus\n'
  fi
}

ssh_network_host_warp_backend_display_get() {
  if declare -F warp_backend_display_name_get >/dev/null 2>&1; then
    warp_backend_display_name_get 2>/dev/null || printf 'WARP Backend\n'
  else
    printf 'wireproxy\n'
  fi
}

ssh_network_host_warp_service_name_get() {
  if declare -F warp_backend_service_name_get >/dev/null 2>&1; then
    warp_backend_service_name_get 2>/dev/null || printf 'wireproxy\n'
  else
    printf 'wireproxy\n'
  fi
}

ssh_network_host_warp_service_state_get() {
  local svc=""
  svc="$(ssh_network_host_warp_service_name_get)"
  if [[ -n "${svc}" ]] && svc_exists "${svc}"; then
    svc_state "${svc}"
  else
    printf 'missing\n'
  fi
}

ssh_network_host_warp_proxy_port_get() {
  if declare -F warp_proxy_port_get >/dev/null 2>&1; then
    warp_proxy_port_get 2>/dev/null || printf '%s\n' "${WARP_ZEROTRUST_PROXY_PORT:-40000}"
  else
    printf '%s\n' "${WARP_ZEROTRUST_PROXY_PORT:-40000}"
  fi
}

ssh_network_dedicated_interface_guard() {
  local mode=""
  if declare -F warp_mode_state_get >/dev/null 2>&1; then
    mode="$(warp_mode_state_get 2>/dev/null || true)"
  fi
  if [[ "${mode}" == "zerotrust" ]]; then
    warn "Dedicated Interface SSH tidak kompatibel saat host aktif di Zero Trust."
    warn "Gunakan backend Local Proxy, atau kembalikan host ke Free/Plus lebih dulu."
    return 1
  fi
  return 0
}

ssh_network_warp_interface_set() {
  local iface="${1:-}"
  ssh_network_interface_name_is_valid "${iface}" || return 1
  ssh_network_config_set_values SSH_NETWORK_WARP_INTERFACE "${iface}"
}

ssh_network_warp_config_path() {
  local iface="${1:-}"
  ssh_network_interface_name_is_valid "${iface}" || return 1
  printf '%s/%s.conf\n' "${WIREGUARD_DIR:-/etc/wireguard}" "${iface}"
}

ssh_network_warp_unit_name() {
  local iface="${1:-}"
  ssh_network_interface_name_is_valid "${iface}" || return 1
  printf 'wg-quick@%s\n' "${iface}"
}

ssh_network_warp_helper_available() {
  [[ -x "${SSH_WARP_SYNC_BIN:-/usr/local/bin/ssh-warp-sync}" ]]
}

ssh_network_file_fingerprint() {
  local path="${1:-}"
  [[ -n "${path}" && -f "${path}" ]] || return 1
  cksum "${path}" 2>/dev/null | awk '{print $1 ":" $2}'
}

ssh_network_warp_sync_config_unlocked() {
  local iface="${1:-}" source_conf="" dest_dir="" dest_path="" helper=""
  ssh_network_interface_name_is_valid "${iface}" || {
    warn "Nama interface WARP SSH tidak valid."
    return 1
  }
  source_conf="${WIREPROXY_CONF:-/etc/wireproxy/config.conf}"
  dest_dir="${WIREGUARD_DIR:-/etc/wireguard}"
  dest_path="$(ssh_network_warp_config_path "${iface}")" || return 1
  [[ -s "${source_conf}" ]] || {
    warn "Source config WARP host tidak ditemukan: ${source_conf}"
    return 1
  }
  mkdir -p "${dest_dir}" 2>/dev/null || true
  chmod 700 "${dest_dir}" 2>/dev/null || true

  helper="${SSH_WARP_SYNC_BIN:-/usr/local/bin/ssh-warp-sync}"
  if ssh_network_warp_helper_available; then
    "${helper}" --interface "${iface}" --source "${source_conf}" --dest-dir "${dest_dir}" >/dev/null 2>&1 || {
      warn "Gagal merender config SSH WARP dari ${source_conf}."
      return 1
    }
  else
    need_python3
    python3 - <<'PY' "${source_conf}" "${dest_path}" >/dev/null 2>&1 || {
import os
import pathlib
import sys

src = pathlib.Path(sys.argv[1])
dst = pathlib.Path(sys.argv[2])
keep_sections = {"[Interface]", "[Peer]"}
drop_interface_keys = {"dns", "table", "preup", "postup", "predown", "postdown", "saveconfig"}

def compact_blank(lines):
    out = []
    prev_blank = False
    for line in lines:
        blank = not line.strip()
        if blank and prev_blank:
            continue
        out.append("" if blank else line.rstrip())
        prev_blank = blank
    while out and not out[-1].strip():
        out.pop()
    return out

source_text = src.read_text(encoding="utf-8")
out = []
current = None
table_inserted = False
for raw in source_text.splitlines():
    line = raw.rstrip("\n")
    stripped = line.strip()
    if stripped.startswith("[") and stripped.endswith("]"):
        if current == "[Interface]" and not table_inserted:
            out.append("Table = off")
            out.append("")
            table_inserted = True
        current = stripped if stripped in keep_sections else None
        if current is not None:
            out.append(current)
        continue
    if current is None:
        continue
    if not stripped:
        out.append("")
        continue
    if stripped.startswith("#") or stripped.startswith(";"):
        out.append(line)
        continue
    key = stripped.split("=", 1)[0].strip().lower()
    if current == "[Interface]" and key in drop_interface_keys:
        continue
    out.append(line)

if current == "[Interface]" and not table_inserted:
    out.append("Table = off")

rendered = "\n".join(compact_blank(out)).rstrip() + "\n"
if "[Interface]" not in rendered or "[Peer]" not in rendered:
    raise SystemExit("source config tidak memuat [Interface] dan [Peer] yang valid")

dst.parent.mkdir(parents=True, exist_ok=True)
dst.write_text(rendered, encoding="utf-8")
os.chmod(dst, 0o600)
PY
      warn "Gagal merender fallback config SSH WARP dari ${source_conf}."
      return 1
    }
  fi
  chmod 600 "${dest_path}" >/dev/null 2>&1 || true
  return 0
}

ssh_network_warp_sync_config_now() {
  if [[ "${SSH_NETWORK_LOCK_HELD:-0}" != "1" ]]; then
    ssh_network_run_locked ssh_network_warp_sync_config_now "$@"
    return $?
  fi
  ssh_network_warp_sync_config_unlocked "$@"
}

ssh_network_warp_runtime_start_unlocked() {
  local iface="${1:-}" unit=""
  ssh_network_interface_name_is_valid "${iface}" || {
    warn "Nama interface WARP SSH tidak valid."
    return 1
  }
  have_cmd wg-quick || {
    warn "wg-quick tidak tersedia. Install wireguard-tools atau rerun setup.sh."
    return 1
  }
  if ! systemctl cat "wg-quick@.service" >/dev/null 2>&1 && ! systemctl cat "wg-quick@${iface}" >/dev/null 2>&1; then
    warn "Template service wg-quick@.service tidak tersedia."
    return 1
  fi
  ssh_network_warp_sync_config_unlocked "${iface}" || return 1
  unit="$(ssh_network_warp_unit_name "${iface}")" || return 1
  systemctl daemon-reload >/dev/null 2>&1 || true
  if svc_is_active "${unit}"; then
    if ! svc_restart_checked "${unit}" 30; then
      warn "Gagal restart ${unit}."
      return 1
    fi
  else
    if ! systemctl enable --now "${unit}" >/dev/null 2>&1; then
      warn "Gagal mengaktifkan ${unit}."
      return 1
    fi
    if ! svc_wait_active "${unit}" 30; then
      warn "${unit} belum aktif sesudah start."
      return 1
    fi
  fi
  if ! have_cmd ip || ! ip link show "${iface}" >/dev/null 2>&1; then
    warn "Interface SSH WARP '${iface}' belum tersedia sesudah start."
    return 1
  fi
  return 0
}

ssh_network_warp_runtime_start_now() {
  if [[ "${SSH_NETWORK_LOCK_HELD:-0}" != "1" ]]; then
    ssh_network_run_locked ssh_network_warp_runtime_start_now "$@"
    return $?
  fi
  ssh_network_warp_runtime_start_unlocked "$@"
}

ssh_network_warp_runtime_deactivate_unlocked() {
  local iface="${1:-}" unit="" conf_path=""
  ssh_network_interface_name_is_valid "${iface}" || {
    warn "Nama interface WARP SSH tidak valid."
    return 1
  }
  unit="$(ssh_network_warp_unit_name "${iface}")" || return 1
  conf_path="$(ssh_network_warp_config_path "${iface}" 2>/dev/null || true)"
  systemctl disable --now "${unit}" >/dev/null 2>&1 || systemctl stop "${unit}" >/dev/null 2>&1 || true
  if svc_exists "${unit}" && ! svc_wait_inactive "${unit}" 20; then
    warn "${unit} belum berhenti sepenuhnya."
    return 1
  fi
  if [[ -n "${conf_path}" && -f "${conf_path}" ]] && have_cmd wg-quick; then
    wg-quick down "${iface}" >/dev/null 2>&1 || true
  fi
  if have_cmd ip && ip link show "${iface}" >/dev/null 2>&1; then
    ip link delete dev "${iface}" >/dev/null 2>&1 || true
  fi
  if have_cmd ip && ip link show "${iface}" >/dev/null 2>&1; then
    warn "Interface SSH WARP '${iface}' masih aktif sesudah stop."
    return 1
  fi
  return 0
}

ssh_network_warp_interface_decommission_unlocked() {
  local iface="${1:-}" conf_path=""
  ssh_network_interface_name_is_valid "${iface}" || {
    warn "Nama interface WARP SSH tidak valid."
    return 1
  }
  ssh_network_warp_runtime_deactivate_unlocked "${iface}" || return 1
  conf_path="$(ssh_network_warp_config_path "${iface}" 2>/dev/null || true)"
  if [[ -n "${conf_path}" && -f "${conf_path}" ]]; then
    rm -f "${conf_path}" >/dev/null 2>&1 || {
      warn "Config interface WARP SSH lama '${iface}' gagal dibersihkan."
      return 1
    }
  fi
  return 0
}

ssh_network_warp_runtime_stop_unlocked() {
  local iface="${1:-}"
  ssh_network_interface_name_is_valid "${iface}" || {
    warn "Nama interface WARP SSH tidak valid."
    return 1
  }
  ssh_network_runtime_clear_unlocked >/dev/null 2>&1 || true
  ssh_network_warp_runtime_deactivate_unlocked "${iface}"
}

ssh_network_warp_runtime_stop_now() {
  if [[ "${SSH_NETWORK_LOCK_HELD:-0}" != "1" ]]; then
    ssh_network_run_locked ssh_network_warp_runtime_stop_now "$@"
    return $?
  fi
  ssh_network_warp_runtime_stop_unlocked "$@"
}

ssh_network_warp_interface_change_unlocked() {
  local new_iface="${1:-}" cfg current_iface=""
  ssh_network_interface_name_is_valid "${new_iface}" || {
    warn "Nama interface WARP SSH tidak valid."
    return 1
  }
  cfg="$(ssh_network_config_get)"
  current_iface="$(printf '%s\n' "${cfg}" | awk -F'=' '/^warp_interface=/{print $2; exit}')"
  if ! ssh_network_interface_name_is_valid "${current_iface}"; then
    current_iface=""
  fi
  if [[ "${new_iface}" == "${current_iface}" ]]; then
    return 0
  fi
  ssh_network_warp_interface_set "${new_iface}" || return 1
  if ssh_network_runtime_apply_unlocked; then
    if [[ -n "${current_iface}" && "${current_iface}" != "${new_iface}" ]]; then
      if ! ssh_network_warp_interface_decommission_unlocked "${current_iface}"; then
        warn "Cleanup interface lama '${current_iface}' gagal. Rollback ke interface sebelumnya..."
        if ssh_network_warp_interface_set "${current_iface}" >/dev/null 2>&1 && ssh_network_runtime_apply_unlocked >/dev/null 2>&1; then
          ssh_network_warp_interface_decommission_unlocked "${new_iface}" >/dev/null 2>&1 || true
        fi
        return 1
      fi
    fi
    return 0
  fi
  if [[ -n "${current_iface}" && "${current_iface}" != "${new_iface}" ]]; then
    ssh_network_warp_interface_set "${current_iface}" >/dev/null 2>&1 || true
    ssh_network_runtime_apply_unlocked >/dev/null 2>&1 || true
    ssh_network_warp_interface_decommission_unlocked "${new_iface}" >/dev/null 2>&1 || true
  fi
  return 1
}

ssh_network_warp_interface_change_now() {
  if [[ "${SSH_NETWORK_LOCK_HELD:-0}" != "1" ]]; then
    ssh_network_run_locked ssh_network_warp_interface_change_now "$@"
    return $?
  fi
  if [[ "${SSH_QAC_LOCK_HELD:-0}" != "1" ]]; then
    ssh_qac_run_locked ssh_network_warp_interface_change_now "$@"
    return $?
  fi
  ssh_network_warp_interface_change_unlocked "$@"
}

ssh_network_warp_endpoint_ips() {
  local iface="${1:-}" conf_path=""
  ssh_network_interface_name_is_valid "${iface}" || return 1
  conf_path="$(ssh_network_warp_config_path "${iface}")" || return 1
  [[ -f "${conf_path}" ]] || return 1
  need_python3
  python3 - <<'PY' "${conf_path}" 2>/dev/null || true
import ipaddress
import socket
import sys
from pathlib import Path

path = Path(sys.argv[1])
endpoint_host = ""
for raw in path.read_text(encoding="utf-8").splitlines():
    line = raw.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    key, value = line.split("=", 1)
    if key.strip().lower() != "endpoint":
        continue
    endpoint = value.strip()
    if endpoint.startswith("[") and "]" in endpoint:
        endpoint_host = endpoint[1:].split("]", 1)[0].strip()
    else:
        endpoint_host = endpoint.rsplit(":", 1)[0].strip()
    break

if not endpoint_host:
    raise SystemExit(0)

ipv4 = []
ipv6 = []
try:
    ip = ipaddress.ip_address(endpoint_host)
    if ip.version == 4:
        ipv4.append(str(ip))
    else:
        ipv6.append(str(ip))
except ValueError:
    try:
        infos = socket.getaddrinfo(endpoint_host, None, 0, socket.SOCK_DGRAM)
    except Exception:
        infos = []
    seen4 = set()
    seen6 = set()
    for family, _, _, _, sockaddr in infos:
        host = sockaddr[0]
        try:
            ip = ipaddress.ip_address(host)
        except ValueError:
            continue
        if ip.version == 4 and host not in seen4:
            seen4.add(host)
            ipv4.append(host)
        elif ip.version == 6 and host not in seen6:
            seen6.add(host)
            ipv6.append(host)

for item in ipv4:
    print(f"ipv4|{item}")
for item in ipv6:
    print(f"ipv6|{item}")
PY
}

ssh_network_user_route_mode_get() {
  local qf="${1:-}"
  [[ -n "${qf}" && -f "${qf}" ]] || {
    printf '%s\n' "inherit"
    return 0
  }
  need_python3
  python3 - <<'PY' "${qf}" 2>/dev/null || true
import json
import sys

mode = "inherit"
try:
  payload = json.load(open(sys.argv[1], "r", encoding="utf-8"))
  if isinstance(payload, dict):
    network = payload.get("network")
    if isinstance(network, dict):
      candidate = str(network.get("route_mode") or "").strip().lower()
      if candidate in ("inherit", "direct", "warp"):
        mode = candidate
except Exception:
  pass
print(mode)
PY
}

ssh_network_user_route_mode_set() {
  local username="${1:-}"
  local mode="${2:-}"
  local qf=""
  [[ -n "${username}" ]] || return 1
  case "${mode}" in
    inherit|direct|warp) ;;
    *) return 1 ;;
  esac
  ssh_state_dirs_prepare
  qf="$(ssh_user_state_resolve_file "${username}")"
  [[ -n "${qf}" ]] || qf="$(ssh_user_state_file "${username}")"
  [[ -n "${qf}" ]] || return 1
  if [[ ! -f "${qf}" ]]; then
    if ! id "${username}" >/dev/null 2>&1; then
      warn "User Linux '${username}' belum ada untuk SSH Network."
      return 1
    fi
    if ! ssh_qac_metadata_bootstrap_if_missing "${username}" "${qf}"; then
      warn "Gagal menyiapkan metadata SSH untuk '${username}'."
      return 1
    fi
  fi
  ssh_qac_atomic_update_file "${qf}" network_route_mode_set "${mode}"
}

ssh_network_effective_rows() {
  local cfg global_mode username uid qf override effective
  cfg="$(ssh_network_config_get)"
  global_mode="$(printf '%s\n' "${cfg}" | awk -F'=' '/^global_mode=/{print $2; exit}')"
  [[ "${global_mode}" == "warp" ]] || global_mode="direct"
  while IFS= read -r username; do
    [[ -n "${username}" ]] || continue
    uid="$(id -u "${username}" 2>/dev/null || true)"
    [[ "${uid}" =~ ^[0-9]+$ ]] || continue
    qf="$(ssh_user_state_resolve_file "${username}")"
    override="$(ssh_network_user_route_mode_get "${qf}")"
    case "${override}" in
      direct|warp) effective="${override}" ;;
      *) effective="${global_mode}" ; override="inherit" ;;
    esac
    printf '%s|%s|%s|%s\n' "${username}" "${uid:--}" "${override}" "${effective}"
  done < <(ssh_collect_candidate_users false)
}

ssh_network_port_is_listening() {
  local port="${1:-}"
  [[ "${port}" =~ ^[0-9]+$ ]] || return 1
  have_cmd ss || return 1
  ss -lnt "( sport = :${port} )" 2>/dev/null | awk -v want=":${port}" 'index($0, want) {found=1} END{exit found ? 0 : 1}'
}

ssh_network_wait_port_listening() {
  local port="${1:-}" timeout="${2:-20}" i=0
  [[ "${port}" =~ ^[0-9]+$ ]] || return 1
  [[ "${timeout}" =~ ^[0-9]+$ ]] || timeout=20
  while (( i < timeout )); do
    if ssh_network_port_is_listening "${port}"; then
      return 0
    fi
    sleep 1
    ((i++))
  done
  return 1
}

ssh_network_warp_cgroup_root_get() {
  printf '%s\n' "${SSH_NETWORK_WARP_CGROUP_ROOT:-/sys/fs/cgroup/autoscript-ssh-network}"
}

ssh_network_warp_cgroup_path_get() {
  local root
  root="$(ssh_network_warp_cgroup_root_get)"
  printf '%s/%s\n' "${root}" "${SSH_NETWORK_WARP_CGROUP_NAME:-warp}"
}

ssh_network_warp_cgroup_relpath_get() {
  local path root="/sys/fs/cgroup"
  path="$(ssh_network_warp_cgroup_path_get)"
  case "${path}" in
    "${root}")
      return 1
      ;;
    "${root}/"*)
      printf '%s\n' "${path#${root}/}"
      ;;
    *)
      return 1
      ;;
  esac
}

ssh_network_warp_cgroup_supported() {
  local root="/sys/fs/cgroup" fs_type=""
  [[ -d "${root}" && -w "${root}" ]] || return 1
  have_cmd iptables || return 1
  fs_type="$(stat -fc %T "${root}" 2>/dev/null || true)"
  [[ "${fs_type}" == "cgroup2fs" ]] || return 1
  iptables -m cgroup -h >/dev/null 2>&1 || return 1
  return 0
}

ssh_network_warp_cgroup_clear_unlocked() {
  local root="/sys/fs/cgroup" path="" parent="" pid=""
  path="$(ssh_network_warp_cgroup_path_get)"
  [[ -n "${path}" && -d "${path}" ]] || return 0

  if [[ -r "${path}/cgroup.procs" && -w "${root}/cgroup.procs" ]]; then
    while IFS= read -r pid; do
      [[ "${pid}" =~ ^[0-9]+$ ]] || continue
      printf '%s\n' "${pid}" > "${root}/cgroup.procs" 2>/dev/null || true
    done < "${path}/cgroup.procs"
  fi

  rmdir "${path}" >/dev/null 2>&1 || true
  parent="$(dirname "${path}")"
  if [[ -n "${parent}" && "${parent}" != "${root}" ]]; then
    rmdir "${parent}" >/dev/null 2>&1 || true
  fi
  return 0
}

ssh_network_dropbear_session_pids_for_users() {
  (( $# > 0 )) || return 0
  need_python3
  python3 - <<'PY' "${SSHWS_DROPBEAR_PORT}" "$@"
import re
import subprocess
import sys

try:
  DROPBEAR_PORT = int(float(sys.argv[1] or 22022))
except Exception:
  DROPBEAR_PORT = 22022

def norm_user(value):
  text = str(value or "").strip()
  if text.endswith("@ssh"):
    text = text[:-4]
  if "@" in text:
    text = text.split("@", 1)[0]
  return text

targets = {norm_user(item) for item in sys.argv[2:] if norm_user(item)}
if not targets:
  raise SystemExit(0)

rows = []
try:
  res = subprocess.run(
    ["ps", "-eo", "pid=,ppid=,user=,comm=,args="],
    stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL,
    text=True,
    check=False,
    timeout=2.0,
  )
except Exception:
  res = None

if res is None or res.returncode != 0:
  raise SystemExit(0)

for line in (res.stdout or "").splitlines():
  raw = line.strip()
  if not raw:
    continue
  parts = raw.split(None, 4)
  if len(parts) < 5:
    continue
  try:
    pid = int(parts[0])
    ppid = int(parts[1])
  except ValueError:
    continue
  rows.append({
    "pid": pid,
    "ppid": ppid,
    "comm": parts[3],
    "args": parts[4],
  })

master_pids = set()
for row in rows:
  if row.get("comm") == "dropbear" and f"-p 127.0.0.1:{DROPBEAR_PORT}" in str(row.get("args") or ""):
    master_pids.add(int(row.get("pid") or 0))

if not master_pids:
  raise SystemExit(0)

session_pids = []
for row in rows:
  if row.get("comm") != "dropbear":
    continue
  if int(row.get("ppid") or 0) in master_pids:
    session_pids.append(int(row.get("pid") or 0))

if not session_pids:
  raise SystemExit(0)

mapping = {}
pat = re.compile(r"dropbear\[(\d+)\]: .*auth succeeded for '([^']+)'", re.IGNORECASE)

def parse_lines(lines):
  for line in lines:
    match = pat.search(str(line or ""))
    if not match:
      continue
    try:
      pid = int(match.group(1))
    except Exception:
      continue
    username = norm_user(match.group(2))
    if username:
      mapping[pid] = username

try:
  res = subprocess.run(
    ["journalctl", "-u", "sshws-dropbear", "--no-pager", "-n", "2000"],
    stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL,
    text=True,
    check=False,
    timeout=2.0,
  )
  parse_lines((res.stdout or "").splitlines())
except Exception:
  pass

if not mapping:
  try:
    res = subprocess.run(
      ["tail", "-n", "5000", "/var/log/auth.log"],
      stdout=subprocess.PIPE,
      stderr=subprocess.DEVNULL,
      text=True,
      check=False,
      timeout=2.0,
    )
    parse_lines((res.stdout or "").splitlines())
  except Exception:
    pass

for pid in sorted(set(session_pids)):
  username = mapping.get(pid)
  if username in targets:
    print(f"{pid}|{username}")
PY
}

ssh_network_warp_cgroup_sync_dropbear_users_unlocked() {
  local parent="" path="" pid="" username=""
  (( $# > 0 )) || return 0
  ssh_network_warp_cgroup_supported || return 0

  parent="$(ssh_network_warp_cgroup_root_get)"
  path="$(ssh_network_warp_cgroup_path_get)"
  mkdir -p "${parent}" "${path}" >/dev/null 2>&1 || return 1

  while IFS='|' read -r pid username; do
    [[ "${pid}" =~ ^[0-9]+$ ]] || continue
    printf '%s\n' "${pid}" > "${path}/cgroup.procs" 2>/dev/null || true
  done < <(ssh_network_dropbear_session_pids_for_users "$@")
  return 0
}

ssh_network_host_warp_proxy_state_get() {
  local port="" svc_name="" listener_name=""
  port="$(ssh_network_host_warp_proxy_port_get)"
  svc_name="$(ssh_network_host_warp_service_name_get)"
  if declare -F warp_port_listener_name_get >/dev/null 2>&1; then
    listener_name="$(warp_port_listener_name_get "${port}" 2>/dev/null || true)"
    case "${listener_name}" in
      "${svc_name}") printf 'listening\n' ;;
      wireproxy) printf 'occupied-by-wireproxy\n' ;;
      "") printf 'not-listening\n' ;;
      *) printf 'busy-other-process\n' ;;
    esac
    return 0
  fi
  if ssh_network_port_is_listening "${port}"; then
    printf 'listening\n'
  else
    printf 'not-listening\n'
  fi
}

ssh_network_xray_redir_listener_state_get() {
  local family="${1:-ipv4}" port=""
  case "${family}" in
    ipv6) port="$(ssh_network_xray_redir_port_v6_get)" ;;
    *) port="$(ssh_network_xray_redir_port_get)" ;;
  esac
  if ssh_network_port_is_listening "${port}"; then
    printf 'listening\n'
  else
    printf 'not-listening\n'
  fi
}

ssh_network_xray_redir_runtime_clear_unlocked() {
  local chain_v4="" chain_v6="" chain_mark_v4="" chain_mark_v6=""
  chain_v4="$(ssh_network_xray_redir_chain_v4_get)"
  chain_v6="$(ssh_network_xray_redir_chain_v6_get)"
  chain_mark_v4="$(ssh_network_xray_redir_mark_chain_v4_get)"
  chain_mark_v6="$(ssh_network_xray_redir_mark_chain_v6_get)"

  if have_cmd iptables; then
    while iptables -t nat -D OUTPUT -p tcp -j "${chain_v4}" >/dev/null 2>&1; do :; done
    iptables -t nat -F "${chain_v4}" >/dev/null 2>&1 || true
    iptables -t nat -X "${chain_v4}" >/dev/null 2>&1 || true
    while iptables -t mangle -D OUTPUT -p tcp -j "${chain_mark_v4}" >/dev/null 2>&1; do :; done
    iptables -t mangle -F "${chain_mark_v4}" >/dev/null 2>&1 || true
    iptables -t mangle -X "${chain_mark_v4}" >/dev/null 2>&1 || true
  fi
  if have_cmd ip6tables; then
    while ip6tables -t nat -D OUTPUT -p tcp -j "${chain_v6}" >/dev/null 2>&1; do :; done
    ip6tables -t nat -F "${chain_v6}" >/dev/null 2>&1 || true
    ip6tables -t nat -X "${chain_v6}" >/dev/null 2>&1 || true
    while ip6tables -t mangle -D OUTPUT -p tcp -j "${chain_mark_v6}" >/dev/null 2>&1; do :; done
    ip6tables -t mangle -F "${chain_mark_v6}" >/dev/null 2>&1 || true
    ip6tables -t mangle -X "${chain_mark_v6}" >/dev/null 2>&1 || true
  fi
}

ssh_network_host_warp_proxy_prepare_unlocked() {
  local port=""
  port="$(ssh_network_host_warp_proxy_port_get)"
  if declare -F warp_backend_post_restart_health_check >/dev/null 2>&1; then
    warp_backend_post_restart_health_check || return 1
  else
    local svc=""
    svc="$(ssh_network_host_warp_service_name_get)"
    if [[ -n "${svc}" && "${svc}" != "missing" ]] && svc_exists "${svc}" && ! svc_is_active "${svc}"; then
      svc_restart_checked "${svc}" 30 || return 1
    fi
  fi
  if ! ssh_network_port_is_listening "${port}"; then
    warn "Proxy lokal WARP host port ${port} belum listening."
    return 1
  fi
  return 0
}

ssh_network_xray_transparent_prepare_unlocked() {
  local inb_conf="${XRAY_INBOUNDS_CONF}" rt_conf="${XRAY_ROUTING_CONF}"
  local svc_conf="/etc/systemd/system/xray.service.d/10-confdir.conf"
  local tmp_inb="" tmp_rt="" tmp_svc=""
  local backup_inb="" backup_rt="" backup_svc=""
  local port4="" port6="" tag4="" tag6="" rc=0

  [[ -f "${inb_conf}" ]] || {
    warn "Xray inbounds conf tidak ditemukan: ${inb_conf}"
    return 1
  }
  [[ -f "${rt_conf}" ]] || {
    warn "Xray routing conf tidak ditemukan: ${rt_conf}"
    return 1
  }
  [[ -f "${svc_conf}" ]] || {
    warn "Drop-in xray.service tidak ditemukan: ${svc_conf}"
    return 1
  }

  ensure_path_writable "${inb_conf}"
  ensure_path_writable "${rt_conf}"
  ensure_path_writable "${svc_conf}"

  port4="$(ssh_network_xray_redir_port_get)"
  port6="$(ssh_network_xray_redir_port_v6_get)"
  tag4="$(ssh_network_xray_redir_inbound_tag_v4_get)"
  tag6="$(ssh_network_xray_redir_inbound_tag_v6_get)"
  backup_inb="$(xray_backup_path_prepare "${inb_conf}")"
  backup_rt="$(xray_backup_path_prepare "${rt_conf}")"
  backup_svc="$(xray_backup_path_prepare "${svc_conf}")"
  tmp_inb="$(mktemp "${WORK_DIR}/10-inbounds.sshnet.XXXXXX" 2>/dev/null || true)"
  [[ -n "${tmp_inb}" ]] || tmp_inb="${WORK_DIR}/10-inbounds.sshnet.$$"
  tmp_rt="$(mktemp "${WORK_DIR}/30-routing.sshnet.XXXXXX" 2>/dev/null || true)"
  [[ -n "${tmp_rt}" ]] || tmp_rt="${WORK_DIR}/30-routing.sshnet.$$"
  tmp_svc="$(mktemp "${WORK_DIR}/10-confdir.sshnet.XXXXXX" 2>/dev/null || true)"
  [[ -n "${tmp_svc}" ]] || tmp_svc="${WORK_DIR}/10-confdir.sshnet.$$"

  set +e
  (
    flock -x 200
    cp -a "${inb_conf}" "${backup_inb}" || exit 1
    cp -a "${rt_conf}" "${backup_rt}" || exit 1
    cp -a "${svc_conf}" "${backup_svc}" || exit 1

    python3 - <<'PY' "${svc_conf}" "${tmp_svc}" || exit 1
import pathlib
import sys

src = pathlib.Path(sys.argv[1])
dst = pathlib.Path(sys.argv[2])
wanted = {
    "AmbientCapabilities": "CAP_NET_ADMIN",
    "CapabilityBoundingSet": "CAP_NET_ADMIN",
    "NoNewPrivileges": "no",
}

lines = []
if src.exists():
    lines = src.read_text(encoding="utf-8").splitlines()

out = []
seen = set()
for line in lines:
    stripped = line.strip()
    if not stripped or stripped.startswith("#") or "=" not in line:
        out.append(line)
        continue
    key, _ = line.split("=", 1)
    key = key.strip()
    if key in wanted:
        out.append(f"{key}={wanted[key]}")
        seen.add(key)
    else:
        out.append(line)

for key, value in wanted.items():
    if key not in seen:
        out.append(f"{key}={value}")

dst.write_text("\n".join(out).rstrip("\n") + "\n", encoding="utf-8")
PY

    python3 - <<'PY' "${inb_conf}" "${rt_conf}" "${tmp_inb}" "${tmp_rt}" "${port4}" "${port6}" "${tag4}" "${tag6}" || exit 1
import json
import pathlib
import sys

inb_src, rt_src, inb_dst, rt_dst, port4_raw, port6_raw, tag4, tag6 = sys.argv[1:9]
port4 = int(port4_raw)
port6 = int(port6_raw)

def load_json(path):
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)

def dump_json(path, payload):
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False, indent=2)
        fh.write("\n")

inb_cfg = load_json(inb_src)
inbounds = inb_cfg.get("inbounds")
if not isinstance(inbounds, list):
    raise SystemExit("Invalid Xray inbounds config")

canonical_inbounds = [
    {
        "listen": "127.0.0.1",
        "port": port4,
        "protocol": "dokodemo-door",
        "tag": tag4,
        "settings": {
            "network": "tcp",
            "followRedirect": True,
        },
        "streamSettings": {
            "sockopt": {
                "tproxy": "redirect",
            }
        },
    },
    {
        "listen": "::1",
        "port": port6,
        "protocol": "dokodemo-door",
        "tag": tag6,
        "settings": {
            "network": "tcp",
            "followRedirect": True,
        },
        "streamSettings": {
            "sockopt": {
                "tproxy": "redirect",
            }
        },
    },
]

filtered_inbounds = []
inserted = False
for inbound in inbounds:
    if not isinstance(inbound, dict):
        filtered_inbounds.append(inbound)
        continue
    tag = str(inbound.get("tag") or "").strip()
    if tag in (tag4, tag6):
        continue
    filtered_inbounds.append(inbound)
    if not inserted and tag == "api":
        filtered_inbounds.extend(canonical_inbounds)
        inserted = True
if not inserted:
    filtered_inbounds = canonical_inbounds + filtered_inbounds
inb_cfg["inbounds"] = filtered_inbounds
dump_json(inb_dst, inb_cfg)

rt_cfg = load_json(rt_src)
routing = rt_cfg.get("routing") or {}
rules = routing.get("rules")
if not isinstance(rules, list):
    raise SystemExit("Invalid Xray routing config")

canonical_rule = {
    "type": "field",
    "inboundTag": [tag4, tag6],
    "outboundTag": "warp",
}

filtered_rules = []
inserted = False
for rule in rules:
    if not isinstance(rule, dict):
        filtered_rules.append(rule)
        continue
    inbound_tags = rule.get("inboundTag")
    if isinstance(inbound_tags, list) and any(item in (tag4, tag6) for item in inbound_tags if isinstance(item, str)):
        continue
    filtered_rules.append(rule)
    if not inserted and rule.get("type") == "field" and isinstance(inbound_tags, list) and "api" in inbound_tags:
      filtered_rules.append(canonical_rule)
      inserted = True
if not inserted:
    filtered_rules.insert(0, canonical_rule)
routing["rules"] = filtered_rules
rt_cfg["routing"] = routing
dump_json(rt_dst, rt_cfg)
PY

    xray_write_file_atomic "${svc_conf}" "${tmp_svc}" || exit 1
    xray_write_file_atomic "${inb_conf}" "${tmp_inb}" || exit 1
    xray_write_file_atomic "${rt_conf}" "${tmp_rt}" || exit 1

    systemctl daemon-reload >/dev/null 2>&1 || true
    if ! xray_restart_checked; then
      restore_file_if_exists "${backup_svc}" "${svc_conf}"
      restore_file_if_exists "${backup_inb}" "${inb_conf}"
      restore_file_if_exists "${backup_rt}" "${rt_conf}"
      systemctl daemon-reload >/dev/null 2>&1 || true
      xray_restart_checked >/dev/null 2>&1 || true
      exit 86
    fi
    if ! ssh_network_wait_port_listening "${port4}" 20; then
      restore_file_if_exists "${backup_svc}" "${svc_conf}"
      restore_file_if_exists "${backup_inb}" "${inb_conf}"
      restore_file_if_exists "${backup_rt}" "${rt_conf}"
      systemctl daemon-reload >/dev/null 2>&1 || true
      xray_restart_checked >/dev/null 2>&1 || true
      exit 1
    fi
    if have_cmd ip6tables && ! ssh_network_wait_port_listening "${port6}" 20; then
      restore_file_if_exists "${backup_svc}" "${svc_conf}"
      restore_file_if_exists "${backup_inb}" "${inb_conf}"
      restore_file_if_exists "${backup_rt}" "${rt_conf}"
      systemctl daemon-reload >/dev/null 2>&1 || true
      xray_restart_checked >/dev/null 2>&1 || true
      exit 1
    fi
    exit 0
  ) 200>"${ROUTING_LOCK_FILE}"
  rc=$?
  set -e

  rm -f "${tmp_inb}" "${tmp_rt}" "${tmp_svc}" >/dev/null 2>&1 || true
  return "${rc}"
}

ssh_network_runtime_apply_local_proxy_uids_unlocked() {
  local port4="" port6="" chain_v4="" chain_v6="" chain_mark_v4="" chain_mark_v6="" fwmark=""
  local uid="" rc=0 arg="" mode="uids" cgroup_rel=""
  local -a warp_uids=() warp_users=()

  for arg in "$@"; do
    if [[ "${arg}" == "--users" ]]; then
      mode="users"
      continue
    fi
    if [[ "${mode}" == "users" ]]; then
      warp_users+=("${arg}")
    else
      warp_uids+=("${arg}")
    fi
  done

  have_cmd iptables || {
    warn "iptables tidak tersedia. Backend local proxy SSH tidak bisa di-apply."
    return 1
  }
  have_cmd xray || {
    warn "xray tidak tersedia. Backend local proxy SSH tidak bisa di-apply."
    return 1
  }

  if ! ssh_network_host_warp_proxy_prepare_unlocked; then
    warn "Backend WARP host belum sehat untuk SSH local proxy."
    return 1
  fi
  if ! ssh_network_xray_transparent_prepare_unlocked; then
    warn "Runtime Xray redirect untuk SSH belum siap."
    return 1
  fi

  port4="$(ssh_network_xray_redir_port_get)"
  port6="$(ssh_network_xray_redir_port_v6_get)"
  chain_v4="$(ssh_network_xray_redir_chain_v4_get)"
  chain_v6="$(ssh_network_xray_redir_chain_v6_get)"
  chain_mark_v4="$(ssh_network_xray_redir_mark_chain_v4_get)"
  chain_mark_v6="$(ssh_network_xray_redir_mark_chain_v6_get)"
  fwmark="$(ssh_network_config_get | awk -F'=' '/^fwmark=/{print $2; exit}')"

  ssh_network_runtime_clear_unlocked

  if ! ssh_network_warp_cgroup_sync_dropbear_users_unlocked "${warp_users[@]}"; then
    warn "Sinkron cgroup sesi dropbear untuk WARP SSH gagal."
  else
    cgroup_rel="$(ssh_network_warp_cgroup_relpath_get 2>/dev/null || true)"
  fi

  iptables -t nat -N "${chain_v4}" >/dev/null 2>&1 || rc=1
  (( rc == 0 )) || { ssh_network_xray_redir_runtime_clear_unlocked; return 1; }
  iptables -t nat -A "${chain_v4}" -m addrtype --dst-type LOCAL -j RETURN >/dev/null 2>&1 || rc=1
  iptables -t nat -A "${chain_v4}" -d 0.0.0.0/8 -j RETURN >/dev/null 2>&1 || rc=1
  iptables -t nat -A "${chain_v4}" -d 10.0.0.0/8 -j RETURN >/dev/null 2>&1 || rc=1
  iptables -t nat -A "${chain_v4}" -d 100.64.0.0/10 -j RETURN >/dev/null 2>&1 || rc=1
  iptables -t nat -A "${chain_v4}" -d 127.0.0.0/8 -j RETURN >/dev/null 2>&1 || rc=1
  iptables -t nat -A "${chain_v4}" -d 169.254.0.0/16 -j RETURN >/dev/null 2>&1 || rc=1
  iptables -t nat -A "${chain_v4}" -d 172.16.0.0/12 -j RETURN >/dev/null 2>&1 || rc=1
  iptables -t nat -A "${chain_v4}" -d 192.168.0.0/16 -j RETURN >/dev/null 2>&1 || rc=1
  iptables -t nat -A "${chain_v4}" -d 224.0.0.0/4 -j RETURN >/dev/null 2>&1 || rc=1
  iptables -t nat -A "${chain_v4}" -d 240.0.0.0/4 -j RETURN >/dev/null 2>&1 || rc=1
  if [[ -n "${cgroup_rel}" && "${fwmark}" =~ ^[0-9]+$ ]]; then
    iptables -t mangle -N "${chain_mark_v4}" >/dev/null 2>&1 || rc=1
    iptables -t mangle -A "${chain_mark_v4}" -m cgroup --path "${cgroup_rel}" -p tcp -j MARK --set-mark "${fwmark}" >/dev/null 2>&1 || rc=1
    iptables -t mangle -A OUTPUT -p tcp -j "${chain_mark_v4}" >/dev/null 2>&1 || rc=1
    iptables -t nat -A "${chain_v4}" -m mark --mark "${fwmark}" -p tcp -j REDIRECT --to-ports "${port4}" >/dev/null 2>&1 || rc=1
  fi
  for uid in "${warp_uids[@]}"; do
    iptables -t nat -A "${chain_v4}" -m owner --uid-owner "${uid}" -p tcp -j REDIRECT --to-ports "${port4}" >/dev/null 2>&1 || rc=1
  done
  iptables -t nat -A OUTPUT -p tcp -j "${chain_v4}" >/dev/null 2>&1 || rc=1

  if have_cmd ip6tables; then
    ip6tables -t nat -N "${chain_v6}" >/dev/null 2>&1 || rc=1
    ip6tables -t nat -A "${chain_v6}" -m addrtype --dst-type LOCAL -j RETURN >/dev/null 2>&1 || rc=1
    ip6tables -t nat -A "${chain_v6}" -d ::1/128 -j RETURN >/dev/null 2>&1 || rc=1
    ip6tables -t nat -A "${chain_v6}" -d fc00::/7 -j RETURN >/dev/null 2>&1 || rc=1
    ip6tables -t nat -A "${chain_v6}" -d fe80::/10 -j RETURN >/dev/null 2>&1 || rc=1
    ip6tables -t nat -A "${chain_v6}" -d ff00::/8 -j RETURN >/dev/null 2>&1 || rc=1
    if [[ -n "${cgroup_rel}" && "${fwmark}" =~ ^[0-9]+$ ]]; then
      ip6tables -t mangle -N "${chain_mark_v6}" >/dev/null 2>&1 || rc=1
      ip6tables -t mangle -A "${chain_mark_v6}" -m cgroup --path "${cgroup_rel}" -p tcp -j MARK --set-mark "${fwmark}" >/dev/null 2>&1 || rc=1
      ip6tables -t mangle -A OUTPUT -p tcp -j "${chain_mark_v6}" >/dev/null 2>&1 || rc=1
      ip6tables -t nat -A "${chain_v6}" -m mark --mark "${fwmark}" -p tcp -j REDIRECT --to-ports "${port6}" >/dev/null 2>&1 || rc=1
    fi
    for uid in "${warp_uids[@]}"; do
      ip6tables -t nat -A "${chain_v6}" -m owner --uid-owner "${uid}" -p tcp -j REDIRECT --to-ports "${port6}" >/dev/null 2>&1 || rc=1
    done
    ip6tables -t nat -A OUTPUT -p tcp -j "${chain_v6}" >/dev/null 2>&1 || rc=1
  fi

  if (( rc != 0 )); then
    ssh_network_xray_redir_runtime_clear_unlocked
    warn "Gagal menerapkan iptables redirect untuk SSH local proxy."
    return 1
  fi
  return 0
}

ssh_network_runtime_clear_unlocked() {
  local nft_table mark route_table rule_pref mark_hex=""
  local cfg
  cfg="$(ssh_network_config_get)"
  nft_table="$(printf '%s\n' "${cfg}" | awk -F'=' '/^nft_table=/{print $2; exit}')"
  mark="$(printf '%s\n' "${cfg}" | awk -F'=' '/^fwmark=/{print $2; exit}')"
  route_table="$(printf '%s\n' "${cfg}" | awk -F'=' '/^route_table=/{print $2; exit}')"
  rule_pref="$(printf '%s\n' "${cfg}" | awk -F'=' '/^rule_pref=/{print $2; exit}')"
  if [[ "${mark}" =~ ^[0-9]+$ ]]; then
    printf -v mark_hex '0x%x' "${mark}"
  fi
  if have_cmd nft && [[ -n "${nft_table}" ]]; then
    nft delete table inet "${nft_table}" >/dev/null 2>&1 || true
  fi
  ssh_network_warp_cgroup_clear_unlocked
  ssh_network_xray_redir_runtime_clear_unlocked
  if have_cmd ip; then
    while ip rule del pref "${rule_pref}" fwmark "${mark_hex:-${mark}}" table "${route_table}" >/dev/null 2>&1; do :; done
    while ip rule del pref "${rule_pref}" fwmark "${mark}" table "${route_table}" >/dev/null 2>&1; do :; done
    while ip -6 rule del pref "${rule_pref}" fwmark "${mark_hex:-${mark}}" table "${route_table}" >/dev/null 2>&1; do :; done
    while ip -6 rule del pref "${rule_pref}" fwmark "${mark}" table "${route_table}" >/dev/null 2>&1; do :; done
    ip route flush table "${route_table}" >/dev/null 2>&1 || true
    ip -6 route flush table "${route_table}" >/dev/null 2>&1 || true
  fi
}

ssh_network_runtime_apply_unlocked() {
  local cfg nft_table mark route_table rule_pref warp_iface warp_backend backend_effective mark_hex=""
  local -a warp_uids=() warp_users=()
  local -a endpoint_v4=() endpoint_v6=()
  local username uid override effective
  local tmp="" warp_conf_path="" warp_conf_before="" warp_conf_after="" warp_cfg_changed="false"

  cfg="$(ssh_network_config_get)"
  nft_table="$(printf '%s\n' "${cfg}" | awk -F'=' '/^nft_table=/{print $2; exit}')"
  mark="$(printf '%s\n' "${cfg}" | awk -F'=' '/^fwmark=/{print $2; exit}')"
  route_table="$(printf '%s\n' "${cfg}" | awk -F'=' '/^route_table=/{print $2; exit}')"
  rule_pref="$(printf '%s\n' "${cfg}" | awk -F'=' '/^rule_pref=/{print $2; exit}')"
  warp_backend="$(printf '%s\n' "${cfg}" | awk -F'=' '/^warp_backend=/{print $2; exit}')"
  warp_iface="$(printf '%s\n' "${cfg}" | awk -F'=' '/^warp_interface=/{print $2; exit}')"
  backend_effective="$(ssh_network_warp_backend_effective_get_from_value "${warp_backend:-auto}")"
  if [[ "${mark}" =~ ^[0-9]+$ ]]; then
    printf -v mark_hex '0x%x' "${mark}"
  fi

  while IFS='|' read -r username uid override effective; do
    [[ -n "${username}" ]] || continue
    [[ "${uid}" =~ ^[0-9]+$ ]] || continue
    [[ "${effective}" == "warp" ]] || continue
    warp_users+=("${username}")
    warp_uids+=("${uid}")
  done < <(ssh_network_effective_rows)

  if (( ${#warp_uids[@]} == 0 )); then
    ssh_network_runtime_clear_unlocked
    if [[ -n "${warp_iface}" ]] && ssh_network_interface_name_is_valid "${warp_iface}"; then
      if ! ssh_network_warp_runtime_deactivate_unlocked "${warp_iface}"; then
        warn "Runtime routing SSH sudah dibersihkan, tetapi interface WARP '${warp_iface}' gagal dihentikan."
        return 1
      fi
    fi
    return 0
  fi

  if [[ "${backend_effective}" == "local-proxy" ]]; then
    if ! ssh_network_runtime_apply_local_proxy_uids_unlocked "${warp_uids[@]}" --users "${warp_users[@]}"; then
      return 1
    fi
    if [[ -n "${warp_iface}" ]] && ssh_network_interface_name_is_valid "${warp_iface}"; then
      ssh_network_warp_runtime_deactivate_unlocked "${warp_iface}" >/dev/null 2>&1 || true
    fi
    return 0
  fi

  if ! ssh_network_dedicated_interface_guard; then
    return 1
  fi

  have_cmd nft || {
    warn "nft tidak tersedia. Routing SSH tidak bisa di-apply."
    return 1
  }
  have_cmd ip || {
    warn "iproute2 tidak tersedia. Routing SSH tidak bisa di-apply."
    return 1
  }
  if [[ -z "${warp_iface}" ]]; then
    warn "Interface WARP SSH belum diset."
    return 1
  fi
  warp_conf_path="$(ssh_network_warp_config_path "${warp_iface}" 2>/dev/null || true)"
  warp_conf_before="$(ssh_network_file_fingerprint "${warp_conf_path}" 2>/dev/null || true)"
  if ! ssh_network_warp_sync_config_unlocked "${warp_iface}"; then
    warn "Gagal sinkron config SSH WARP dari source WARP host."
    return 1
  fi
  warp_conf_after="$(ssh_network_file_fingerprint "${warp_conf_path}" 2>/dev/null || true)"
  if [[ -n "${warp_conf_after}" && "${warp_conf_after}" != "${warp_conf_before}" ]]; then
    warp_cfg_changed="true"
  fi
  if ! ip link show "${warp_iface}" >/dev/null 2>&1; then
    if ! ssh_network_warp_runtime_start_unlocked "${warp_iface}"; then
      warn "Interface WARP SSH '${warp_iface}' tidak ditemukan dan provisioning otomatis gagal."
      return 1
    fi
    if ! ip link show "${warp_iface}" >/dev/null 2>&1; then
      warn "Interface WARP SSH '${warp_iface}' belum tersedia sesudah provisioning otomatis."
      return 1
    fi
  elif [[ "${warp_cfg_changed}" == "true" ]]; then
    if ! ssh_network_warp_runtime_start_unlocked "${warp_iface}"; then
      warn "Interface WARP SSH '${warp_iface}' gagal direfresh setelah config berubah."
      return 1
    fi
  fi
  while IFS='|' read -r fam ipaddr; do
    [[ -n "${fam}" && -n "${ipaddr}" ]] || continue
    case "${fam}" in
      ipv4) endpoint_v4+=("${ipaddr}") ;;
      ipv6) endpoint_v6+=("${ipaddr}") ;;
    esac
  done < <(ssh_network_warp_endpoint_ips "${warp_iface}")

  tmp="$(mktemp "${WORK_DIR}/.ssh-network-nft.XXXXXX" 2>/dev/null || true)"
  [[ -n "${tmp}" ]] || tmp="${WORK_DIR}/.ssh-network-nft.$$"
  {
    printf 'table inet %s {\n' "${nft_table}"
    printf '  chain output {\n'
    printf '    type route hook output priority mangle; policy accept;\n'
    printf '    oifname "lo" return\n'
    printf '    ip daddr { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4 } return\n'
    printf '    ip6 daddr { ::1/128, fc00::/7, fe80::/10, ff00::/8 } return\n'
    if (( ${#endpoint_v4[@]} > 0 )); then
      printf '    ip daddr { '
      printf '%s' "${endpoint_v4[0]}"
      local idx
      for ((idx=1; idx<${#endpoint_v4[@]}; idx++)); do
        printf ', %s' "${endpoint_v4[$idx]}"
      done
      printf ' } return\n'
    fi
    if (( ${#endpoint_v6[@]} > 0 )); then
      printf '    ip6 daddr { '
      printf '%s' "${endpoint_v6[0]}"
      local idx6
      for ((idx6=1; idx6<${#endpoint_v6[@]}; idx6++)); do
        printf ', %s' "${endpoint_v6[$idx6]}"
      done
      printf ' } return\n'
    fi
    local seen_uid="" uid_entry=""
    while IFS= read -r uid_entry; do
      [[ "${uid_entry}" == "${seen_uid}" ]] && continue
      seen_uid="${uid_entry}"
      printf '    meta skuid %s meta mark set %s\n' "${uid_entry}" "${mark}"
    done < <(printf '%s\n' "${warp_uids[@]}" | sort -n)
    printf '  }\n'
    printf '}\n'
  } > "${tmp}"

  ssh_network_runtime_clear_unlocked
  if ! nft -f "${tmp}" >/dev/null 2>&1; then
    rm -f "${tmp}" >/dev/null 2>&1 || true
    warn "Gagal menerapkan nft routing SSH."
    return 1
  fi
  rm -f "${tmp}" >/dev/null 2>&1 || true

  ip route replace table "${route_table}" default dev "${warp_iface}" >/dev/null 2>&1 || {
    ssh_network_runtime_clear_unlocked
    warn "Gagal menerapkan route table SSH ke interface ${warp_iface}."
    return 1
  }
  ip -6 route replace table "${route_table}" default dev "${warp_iface}" >/dev/null 2>&1 || true
  ip rule add pref "${rule_pref}" fwmark "${mark_hex:-${mark}}" table "${route_table}" >/dev/null 2>&1 || {
    ssh_network_runtime_clear_unlocked
    warn "Gagal menambah ip rule SSH."
    return 1
  }
  ip -6 rule add pref "${rule_pref}" fwmark "${mark_hex:-${mark}}" table "${route_table}" >/dev/null 2>&1 || true
  return 0
}

ssh_network_runtime_sync_session_targets_unlocked() {
  local cfg warp_backend backend_effective="" username="" uid="" override="" effective=""
  local -a warp_users=()

  cfg="$(ssh_network_config_get)"
  warp_backend="$(printf '%s\n' "${cfg}" | awk -F'=' '/^warp_backend=/{print $2; exit}')"
  backend_effective="$(ssh_network_warp_backend_effective_get_from_value "${warp_backend:-auto}")"

  if [[ "${backend_effective}" != "local-proxy" ]]; then
    ssh_network_warp_cgroup_clear_unlocked
    return 0
  fi

  while IFS='|' read -r username uid override effective; do
    [[ -n "${username}" ]] || continue
    [[ "${effective}" == "warp" ]] || continue
    warp_users+=("${username}")
  done < <(ssh_network_effective_rows)

  if (( ${#warp_users[@]} == 0 )); then
    ssh_network_warp_cgroup_clear_unlocked
    return 0
  fi

  if ! ssh_network_warp_cgroup_sync_dropbear_users_unlocked "${warp_users[@]}"; then
    warn "Sinkron target sesi dropbear WARP SSH gagal."
    return 1
  fi
  return 0
}

ssh_network_runtime_sync_session_targets_now() {
  if [[ "${SSH_NETWORK_LOCK_HELD:-0}" != "1" ]]; then
    ssh_network_run_locked ssh_network_runtime_sync_session_targets_now
    return $?
  fi
  if [[ "${SSH_QAC_LOCK_HELD:-0}" != "1" ]]; then
    ssh_qac_run_locked ssh_network_runtime_sync_session_targets_now
    return $?
  fi
  ssh_network_runtime_sync_session_targets_unlocked
}

ssh_network_runtime_apply_now() {
  if [[ "${SSH_NETWORK_LOCK_HELD:-0}" != "1" ]]; then
    ssh_network_run_locked ssh_network_runtime_apply_now
    return $?
  fi
  if [[ "${SSH_QAC_LOCK_HELD:-0}" != "1" ]]; then
    ssh_qac_run_locked ssh_network_runtime_apply_now
    return $?
  fi
  ssh_network_runtime_apply_unlocked
}

ssh_network_runtime_refresh_if_available() {
  declare -F ssh_network_runtime_apply_now >/dev/null 2>&1 || return 0
  ssh_network_runtime_apply_now
}

ssh_network_runtime_status_get() {
  local cfg global_mode nft_table mark route_table rule_pref warp_iface warp_backend xray_redir_port xray_redir_port_v6 mark_hex=""
  local backend_effective="" backend_applied="idle" xray_redir_v4_state="not-listening" xray_redir_v6_state="not-listening"
  local xray_redir_v4_listener_state="not-listening" xray_redir_v6_listener_state="not-listening"
  local iptables_state="absent" ip6tables_state="absent" host_warp_mode="" host_warp_backend="" host_warp_service=""
  local host_warp_service_state="missing" host_warp_proxy_port="" host_warp_proxy_state="not-listening"
  local chain_v4="" chain_v6=""
  local nft_state="absent" ip_rule_state="absent" ip_rule_v6_state="absent" iface_state="missing"
  local route_table_v4_state="absent" route_table_v6_state="absent"
  local effective_warp_users="0" warp_conf_state="missing" warp_service_state="missing"
  local warp_unit="" warp_conf_path="" route_v4_lines="" route_v6_lines=""
  cfg="$(ssh_network_config_get)"
  global_mode="$(printf '%s\n' "${cfg}" | awk -F'=' '/^global_mode=/{print $2; exit}')"
  nft_table="$(printf '%s\n' "${cfg}" | awk -F'=' '/^nft_table=/{print $2; exit}')"
  mark="$(printf '%s\n' "${cfg}" | awk -F'=' '/^fwmark=/{print $2; exit}')"
  route_table="$(printf '%s\n' "${cfg}" | awk -F'=' '/^route_table=/{print $2; exit}')"
  rule_pref="$(printf '%s\n' "${cfg}" | awk -F'=' '/^rule_pref=/{print $2; exit}')"
  warp_backend="$(printf '%s\n' "${cfg}" | awk -F'=' '/^warp_backend=/{print $2; exit}')"
  warp_iface="$(printf '%s\n' "${cfg}" | awk -F'=' '/^warp_interface=/{print $2; exit}')"
  xray_redir_port="$(printf '%s\n' "${cfg}" | awk -F'=' '/^xray_redir_port=/{print $2; exit}')"
  xray_redir_port_v6="$(printf '%s\n' "${cfg}" | awk -F'=' '/^xray_redir_port_v6=/{print $2; exit}')"
  backend_effective="$(ssh_network_warp_backend_effective_get_from_value "${warp_backend:-auto}")"
  chain_v4="$(ssh_network_xray_redir_chain_v4_get)"
  chain_v6="$(ssh_network_xray_redir_chain_v6_get)"
  if [[ "${mark}" =~ ^[0-9]+$ ]]; then
    printf -v mark_hex '0x%x' "${mark}"
  fi
  if have_cmd nft && nft list table inet "${nft_table}" >/dev/null 2>&1; then
    nft_state="present"
  fi
  if have_cmd ip; then
    if ip rule show 2>/dev/null | grep -Eiq "(^| )${rule_pref}:.*fwmark (${mark}|${mark_hex:-${mark}})(/0xffffffff)? .*lookup ${route_table}( |$)"; then
      ip_rule_state="present"
    fi
    if ip -6 rule show 2>/dev/null | grep -Eiq "(^| )${rule_pref}:.*fwmark (${mark}|${mark_hex:-${mark}})(/0xffffffff)? .*lookup ${route_table}( |$)"; then
      ip_rule_v6_state="present"
    fi
    route_v4_lines="$(ip route show table "${route_table}" 2>/dev/null || true)"
    if [[ -n "${route_v4_lines//[$' \t\r\n']/}" ]]; then
      if [[ -n "${warp_iface}" && " ${route_v4_lines//$'\n'/ } " == *" dev ${warp_iface} "* ]]; then
        route_table_v4_state="present"
      else
        route_table_v4_state="mismatch"
      fi
    fi
    route_v6_lines="$(ip -6 route show table "${route_table}" 2>/dev/null || true)"
    if [[ -n "${route_v6_lines//[$' \t\r\n']/}" ]]; then
      if [[ -n "${warp_iface}" && " ${route_v6_lines//$'\n'/ } " == *" dev ${warp_iface} "* ]]; then
        route_table_v6_state="present"
      else
        route_table_v6_state="mismatch"
      fi
    fi
  fi
  if [[ -n "${warp_iface}" ]] && have_cmd ip && ip link show "${warp_iface}" >/dev/null 2>&1; then
    iface_state="present"
  fi
  if [[ -n "${warp_iface}" ]]; then
    warp_conf_path="$(ssh_network_warp_config_path "${warp_iface}" 2>/dev/null || true)"
    [[ -n "${warp_conf_path}" && -f "${warp_conf_path}" ]] && warp_conf_state="present"
    warp_unit="$(ssh_network_warp_unit_name "${warp_iface}" 2>/dev/null || true)"
    if systemctl cat "wg-quick@.service" >/dev/null 2>&1 || { [[ -n "${warp_unit}" ]] && systemctl cat "${warp_unit}" >/dev/null 2>&1; }; then
      warp_service_state="$(svc_state "${warp_unit}")"
      [[ -n "${warp_service_state}" ]] || warp_service_state="inactive"
    fi
  fi
  if have_cmd iptables; then
    if iptables -t nat -S OUTPUT 2>/dev/null | grep -Fq -- "-A OUTPUT -p tcp -j ${chain_v4}"; then
      iptables_state="present"
    fi
  fi
  if have_cmd ip6tables; then
    if ip6tables -t nat -S OUTPUT 2>/dev/null | grep -Fq -- "-A OUTPUT -p tcp -j ${chain_v6}"; then
      ip6tables_state="present"
    fi
  fi
  xray_redir_v4_listener_state="$(ssh_network_xray_redir_listener_state_get ipv4)"
  if have_cmd ip6tables; then
    xray_redir_v6_listener_state="$(ssh_network_xray_redir_listener_state_get ipv6)"
  else
    xray_redir_v6_listener_state="missing"
  fi
  xray_redir_v4_state="$(ssh_network_xray_redir_runtime_state_get "${xray_redir_v4_listener_state}" "${iptables_state}")"
  xray_redir_v6_state="$(ssh_network_xray_redir_runtime_state_get "${xray_redir_v6_listener_state}" "${ip6tables_state}")"
  host_warp_mode="$(ssh_network_host_warp_mode_get)"
  host_warp_backend="$(ssh_network_host_warp_backend_display_get)"
  host_warp_service="$(ssh_network_host_warp_service_name_get)"
  host_warp_service_state="$(ssh_network_host_warp_service_state_get)"
  host_warp_proxy_port="$(ssh_network_host_warp_proxy_port_get)"
  host_warp_proxy_state="$(ssh_network_host_warp_proxy_state_get)"
  effective_warp_users="$(ssh_network_effective_rows | awk -F'|' '$4=="warp"{c++} END{print c+0}')"
  backend_applied="$(ssh_network_runtime_backend_applied_get \
    "${iptables_state}" "${ip6tables_state}" "${nft_state}" "${ip_rule_state}" "${ip_rule_v6_state}" \
    "${route_table_v4_state}" "${route_table_v6_state}" "${iface_state}" "${warp_service_state}" \
    "${xray_redir_v4_state}" "${xray_redir_v6_state}" "${host_warp_proxy_state}")"
  printf 'global_mode=%s\n' "${global_mode}"
  printf 'nft_table=%s\n' "${nft_table}"
  printf 'fwmark=%s\n' "${mark}"
  printf 'route_table=%s\n' "${route_table}"
  printf 'rule_pref=%s\n' "${rule_pref}"
  printf 'warp_backend=%s\n' "${warp_backend:-auto}"
  printf 'warp_backend_effective=%s\n' "${backend_effective}"
  printf 'warp_backend_applied=%s\n' "${backend_applied}"
  printf 'warp_interface=%s\n' "${warp_iface}"
  printf 'warp_interface_state=%s\n' "${iface_state}"
  printf 'warp_config_state=%s\n' "${warp_conf_state}"
  printf 'warp_service_state=%s\n' "${warp_service_state}"
  printf 'xray_redir_port=%s\n' "${xray_redir_port}"
  printf 'xray_redir_port_v6=%s\n' "${xray_redir_port_v6}"
  printf 'xray_redir_v4_state=%s\n' "${xray_redir_v4_state}"
  printf 'xray_redir_v6_state=%s\n' "${xray_redir_v6_state}"
  printf 'iptables_state=%s\n' "${iptables_state}"
  printf 'ip6tables_state=%s\n' "${ip6tables_state}"
  printf 'host_warp_mode=%s\n' "${host_warp_mode}"
  printf 'host_warp_backend=%s\n' "${host_warp_backend}"
  printf 'host_warp_service=%s\n' "${host_warp_service}"
  printf 'host_warp_service_state=%s\n' "${host_warp_service_state}"
  printf 'host_warp_proxy_port=%s\n' "${host_warp_proxy_port}"
  printf 'host_warp_proxy_state=%s\n' "${host_warp_proxy_state}"
  printf 'nft_state=%s\n' "${nft_state}"
  printf 'ip_rule_state=%s\n' "${ip_rule_state}"
  printf 'ip_rule_v6_state=%s\n' "${ip_rule_v6_state}"
  printf 'route_table_v4_state=%s\n' "${route_table_v4_state}"
  printf 'route_table_v6_state=%s\n' "${route_table_v6_state}"
  printf 'effective_warp_users=%s\n' "${effective_warp_users}"
}

ssh_network_effective_rows_print() {
  local username uid override effective
  printf "%-18s %-8s %-10s %-10s\n" "Username" "UID" "Override" "Effective"
  hr
  while IFS='|' read -r username uid override effective; do
    [[ -n "${username}" ]] || continue
    printf "%-18s %-8s %-10s %-10s\n" "${username}" "${uid:--}" "${override}" "${effective}"
  done < <(ssh_network_effective_rows)
}

ssh_network_pick_routable_user() {
  local -n _out_ref="$1"
  _out_ref=""

  local -a users=()
  local name="" uid="" override="" effective=""
  while IFS='|' read -r name uid override effective; do
    [[ -n "${name}" ]] || continue
    users+=("${name}")
  done < <(ssh_network_effective_rows)

  if (( ${#users[@]} > 1 )); then
    mapfile -t users < <(printf '%s\n' "${users[@]}" | sort -u)
  fi

  if (( ${#users[@]} == 0 )); then
    warn "Belum ada akun SSH routable yang bisa dipilih dari menu ini."
    return 1
  fi

  local i pick
  echo "Pilih akun SSH routable:"
  for i in "${!users[@]}"; do
    printf "  %d) %s\n" "$((i + 1))" "${users[$i]}"
  done

  while true; do
    if ! read -r -p "Nomor akun (1-${#users[@]}/kembali): " pick; then
      echo
      return 1
    fi
    if is_back_choice "${pick}"; then
      return 1
    fi
    [[ "${pick}" =~ ^[0-9]+$ ]] || {
      warn "Input tidak valid."
      continue
    }
    if (( pick < 1 || pick > ${#users[@]} )); then
      warn "Nomor di luar daftar."
      continue
    fi
    _out_ref="${users[$((pick - 1))]}"
    return 0
  done
}

ssh_network_menu_title() {
  local suffix="${1:-}"
  if [[ -n "${suffix}" ]]; then
    printf '6) SSH Network > %s\n' "${suffix}"
  else
    printf '6) SSH Network\n'
  fi
}

ssh_network_dns_menu() {
  while true; do
    local st cfg enabled dns_port primary secondary dns_service sync_service nft_table users_count
    local dns_state dns_state_raw sync_state sync_state_raw
    st="$(ssh_dns_adblock_status_get)"
    cfg="$(ssh_dns_resolver_config_get)"
    enabled="$(printf '%s\n' "${st}" | awk -F'=' '/^enabled=/{print $2; exit}')"
    dns_port="$(printf '%s\n' "${cfg}" | awk -F'=' '/^dns_port=/{print $2; exit}')"
    primary="$(printf '%s\n' "${cfg}" | awk -F'=' '/^upstream_primary=/{print $2; exit}')"
    secondary="$(printf '%s\n' "${cfg}" | awk -F'=' '/^upstream_secondary=/{print $2; exit}')"
    dns_service="$(printf '%s\n' "${st}" | awk -F'=' '/^dns_service=/{print $2; exit}')"
    dns_state_raw="$(printf '%s\n' "${st}" | awk -F'=' '/^dns_service_state=/{print $2; exit}')"
    sync_service="$(printf '%s\n' "${st}" | awk -F'=' '/^sync_service=/{print $2; exit}')"
    sync_state_raw="$(printf '%s\n' "${st}" | awk -F'=' '/^sync_service_state=/{print $2; exit}')"
    nft_table="$(printf '%s\n' "${st}" | awk -F'=' '/^nft_table=/{print $2; exit}')"
    users_count="$(printf '%s\n' "${st}" | awk -F'=' '/^users_count=/{print $2; exit}')"
    if [[ -n "${dns_state_raw}" ]]; then
      dns_state="${dns_state_raw}"
    elif [[ -n "${dns_service}" && "${dns_service}" != "missing" ]] && svc_exists "${dns_service}"; then
      dns_state="$(svc_state "${dns_service}")"
    else
      dns_state="missing"
    fi
    if [[ -n "${sync_state_raw}" ]]; then
      sync_state="${sync_state_raw}"
    elif [[ -n "${sync_service}" && "${sync_service}" != "missing" ]] && svc_exists "${sync_service}"; then
      sync_state="$(svc_state "${sync_service}")"
    else
      sync_state="missing"
    fi
    [[ -n "${dns_port}" ]] || dns_port="${SSH_DNS_ADBLOCK_PORT:-5353}"
    [[ -n "${primary}" ]] || primary="1.1.1.1"
    [[ -n "${secondary}" ]] || secondary="8.8.8.8"

    title
    echo "$(ssh_network_menu_title "DNS for SSH")"
    hr
    printf "%-14s : %s\n" "Backend" "dnsmasq + nft meta skuid"
    printf "%-14s : %s\n" "Steering" "$([[ "${enabled}" == "1" ]] && echo "ON" || echo "OFF")"
    printf "%-14s : %s\n" "DNS Service" "${dns_service:--}"
    printf "%-14s : %s\n" "DNS State" "${dns_state:--}"
    printf "%-14s : %s\n" "Sync Service" "${sync_service:--}"
    printf "%-14s : %s\n" "Sync State" "${sync_state:--}"
    printf "%-14s : %s\n" "NFT Table" "${nft_table:--}"
    printf "%-14s : %s\n" "Managed Users" "${users_count:-0}"
    printf "%-14s : %s\n" "DNS Port" "${dns_port}"
    printf "%-14s : %s\n" "Primary DNS" "${primary}"
    printf "%-14s : %s\n" "Secondary DNS" "${secondary}"
    hr
    echo "  1) Enable DNS Steering"
    echo "  2) Disable DNS Steering"
    echo "  3) Set Primary DNS"
    echo "  4) Set Secondary DNS"
    echo "  5) Apply DNS Runtime"
    echo "  0) Back"
    hr
    if ! read -r -p "Pilih: " c; then
      echo
      return 0
    fi
    case "${c}" in
      1)
        if ! confirm_yn_or_back "Aktifkan DNS steering untuk user SSH managed sekarang?"; then
          warn "Enable DNS steering dibatalkan."
        elif ssh_dns_adblock_set_enabled_now 1; then
          log "DNS steering SSH diaktifkan."
        else
          warn "DNS steering SSH gagal diaktifkan."
        fi
        pause
        ;;
      2)
        if ! confirm_yn_or_back "Nonaktifkan DNS steering untuk user SSH managed sekarang?"; then
          warn "Disable DNS steering dibatalkan."
        elif ssh_dns_adblock_set_enabled_now 0; then
          log "DNS steering SSH dinonaktifkan."
        else
          warn "DNS steering SSH gagal dinonaktifkan."
        fi
        pause
        ;;
      3)
        local new_primary
        if ! read -r -p "Primary DNS SSH (IPv4/IPv6 literal) (atau kembali): " new_primary; then
          echo
          return 0
        fi
        if is_back_choice "${new_primary}"; then
          continue
        fi
        new_primary="$(dns_server_literal_normalize "${new_primary}")" || {
          warn "Primary DNS SSH harus IPv4/IPv6 literal."
          pause
          continue
        }
        if ! confirm_yn_or_back "Set Primary DNS SSH ke ${new_primary} sekarang?"; then
          warn "Set Primary DNS SSH dibatalkan."
          pause
          continue
        fi
        if ssh_dns_resolver_set_upstreams "${new_primary}" "${secondary}"; then
          log "Primary DNS SSH diubah ke ${new_primary}."
        else
          warn "Primary DNS SSH gagal diubah."
        fi
        pause
        ;;
      4)
        local new_secondary
        if ! read -r -p "Secondary DNS SSH (IPv4/IPv6 literal) (atau kembali): " new_secondary; then
          echo
          return 0
        fi
        if is_back_choice "${new_secondary}"; then
          continue
        fi
        new_secondary="$(dns_server_literal_normalize "${new_secondary}")" || {
          warn "Secondary DNS SSH harus IPv4/IPv6 literal."
          pause
          continue
        }
        if ! confirm_yn_or_back "Set Secondary DNS SSH ke ${new_secondary} sekarang?"; then
          warn "Set Secondary DNS SSH dibatalkan."
          pause
          continue
        fi
        if ssh_dns_resolver_set_upstreams "${primary}" "${new_secondary}"; then
          log "Secondary DNS SSH diubah ke ${new_secondary}."
        else
          warn "Secondary DNS SSH gagal diubah."
        fi
        pause
        ;;
      5)
        if ssh_dns_resolver_apply_now; then
          log "Runtime DNS SSH berhasil disinkronkan."
        else
          warn "Runtime DNS SSH gagal disinkronkan."
        fi
        pause
        ;;
      0|kembali|k|back|b) return 0 ;;
      *) invalid_choice ;;
    esac
  done
}

ssh_network_route_global_menu() {
  while true; do
    local st global_mode warp_iface warp_backend warp_backend_effective warp_backend_applied host_warp_mode host_warp_service_state
    local host_warp_proxy_state host_warp_proxy_port effective_warp_users
    st="$(ssh_network_runtime_status_get)"
    global_mode="$(printf '%s\n' "${st}" | awk -F'=' '/^global_mode=/{print $2; exit}')"
    warp_backend="$(printf '%s\n' "${st}" | awk -F'=' '/^warp_backend=/{print $2; exit}')"
    warp_backend_effective="$(printf '%s\n' "${st}" | awk -F'=' '/^warp_backend_effective=/{print $2; exit}')"
    warp_backend_applied="$(printf '%s\n' "${st}" | awk -F'=' '/^warp_backend_applied=/{print $2; exit}')"
    warp_iface="$(printf '%s\n' "${st}" | awk -F'=' '/^warp_interface=/{print $2; exit}')"
    host_warp_mode="$(printf '%s\n' "${st}" | awk -F'=' '/^host_warp_mode=/{print $2; exit}')"
    host_warp_service_state="$(printf '%s\n' "${st}" | awk -F'=' '/^host_warp_service_state=/{print $2; exit}')"
    host_warp_proxy_port="$(printf '%s\n' "${st}" | awk -F'=' '/^host_warp_proxy_port=/{print $2; exit}')"
    host_warp_proxy_state="$(printf '%s\n' "${st}" | awk -F'=' '/^host_warp_proxy_state=/{print $2; exit}')"
    effective_warp_users="$(printf '%s\n' "${st}" | awk -F'=' '/^effective_warp_users=/{print $2; exit}')"

    title
    echo "$(ssh_network_menu_title "Routing SSH Global")"
    hr
    printf "%-18s : %s\n" "Backend Config" "$(ssh_network_warp_backend_pretty_get "${warp_backend:-auto}")"
    printf "%-18s : %s\n" "Backend Target" "$(ssh_network_warp_backend_pretty_get "${warp_backend_effective:-auto}")"
    printf "%-18s : %s\n" "Backend Applied" "$(ssh_network_warp_backend_pretty_get "${warp_backend_applied:-idle}")"
    printf "%-18s : %s\n" "Apply Path" "$(ssh_network_warp_apply_path_pretty_get "${warp_backend_effective:-auto}")"
    printf "%-18s : %s\n" "Global Mode" "${global_mode}"
    printf "%-18s : %s\n" "WARP Iface" "${warp_iface}"
    printf "%-18s : %s\n" "Host WARP Mode" "${host_warp_mode}"
    printf "%-18s : %s\n" "Host WARP Svc" "${host_warp_service_state}"
    printf "%-18s : %s\n" "Host WARP SOCKS" "${host_warp_proxy_state} (127.0.0.1:${host_warp_proxy_port:-40000})"
    printf "%-18s : %s\n" "Effective Warp Users" "${effective_warp_users}"
    hr
    ssh_network_effective_rows_print
    hr
    echo "  1) Set Global Mode: Direct"
    echo "  2) Set Global Mode: WARP"
    echo "  3) Save WARP Backend (config only)"
    echo "  4) Apply Routing Runtime"
    echo "  0) Back"
    hr
    if ! read -r -p "Pilih: " c; then
      echo
      return 0
    fi
    case "${c}" in
      1)
        local prev_mode="${global_mode}"
        if ! confirm_yn_or_back "Set routing SSH global ke DIRECT sekarang?"; then
          warn "Set routing global direct dibatalkan."
        elif ssh_network_global_mode_set direct && ssh_network_runtime_apply_now; then
          log "Routing SSH global diubah ke DIRECT."
        else
          ssh_network_global_mode_set "${prev_mode}" >/dev/null 2>&1 || true
          warn "Routing SSH global gagal diubah ke DIRECT."
        fi
        pause
        ;;
      2)
        local prev_mode="${global_mode}"
        if ! confirm_yn_or_back "Set routing SSH global ke WARP sekarang?"; then
          warn "Set routing global WARP dibatalkan."
        elif ssh_network_global_mode_set warp && ssh_network_runtime_apply_now; then
          log "Routing SSH global diubah ke WARP."
        else
          ssh_network_global_mode_set "${prev_mode}" >/dev/null 2>&1 || true
          warn "Routing SSH global gagal diubah ke WARP."
        fi
        pause
        ;;
      3)
        local backend_pick=""
        if ! read -r -p "Backend WARP SSH (auto/local-proxy/interface) (atau kembali): " backend_pick; then
          echo
          return 0
        fi
        backend_pick="$(printf '%s' "${backend_pick}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
        if is_back_choice "${backend_pick}"; then
          continue
        fi
        if [[ "${backend_pick}" == "interface" ]] && ! ssh_network_dedicated_interface_guard; then
          pause
          continue
        fi
        if ! confirm_yn_or_back "Set backend WARP SSH ke ${backend_pick} sekarang?"; then
          warn "Set backend WARP SSH dibatalkan."
        elif ssh_network_warp_backend_set "${backend_pick}"; then
          log "Backend WARP SSH disimpan: ${backend_pick}. Jalankan Apply Routing Runtime untuk merekonsiliasi runtime."
        else
          warn "Backend WARP SSH gagal diubah."
        fi
        pause
        ;;
      4)
        if ssh_network_runtime_apply_now; then
          log "Runtime routing SSH berhasil disinkronkan."
        else
          warn "Runtime routing SSH gagal disinkronkan."
        fi
        pause
        ;;
      0|kembali|k|back|b) return 0 ;;
      *) invalid_choice ;;
    esac
  done
}

ssh_network_route_user_menu() {
  while true; do
    local st="" backend_effective="" backend_applied="" menu_context=""
    local menu_title="" backend_label="" target_label="" option1="" option2="" option3=""
    local mode1="" mode2="" mode3="" confirm_prompt="" cancel_msg="" success_msg="" fail_msg=""
    st="$(ssh_network_runtime_status_get)"
    backend_effective="$(printf '%s\n' "${st}" | awk -F'=' '/^warp_backend_effective=/{print $2; exit}')"
    backend_applied="$(printf '%s\n' "${st}" | awk -F'=' '/^warp_backend_applied=/{print $2; exit}')"
    menu_context="${SSH_NETWORK_USER_MENU_CONTEXT:-routing}"
    if [[ "${menu_context}" == "warp" ]]; then
      menu_title="WARP SSH Per-User"
      backend_label="Kontrol WARP per-user"
      target_label="enable / disable / inherit"
      option1="Enable WARP for User"
      option2="Disable WARP for User"
      option3="Reset User to Inherit"
      mode1="warp"
      mode2="direct"
      mode3="inherit"
    else
      menu_title="Routing SSH Per-User"
      backend_label="Per-user override di metadata SSH"
      target_label="inherit / direct / warp"
      option1="Set User: Inherit"
      option2="Set User: Direct"
      option3="Set User: WARP"
      mode1="inherit"
      mode2="direct"
      mode3="warp"
    fi
    title
    echo "$(ssh_network_menu_title "${menu_title}")"
    hr
    printf "%-18s : %s\n" "Backend" "${backend_label}"
    if [[ "${menu_context}" == "warp" ]]; then
      printf "%-18s : %s\n" "State" "metadata SSH: network.route_mode"
    fi
    printf "%-18s : %s\n" "Target Path" "$(ssh_network_warp_apply_path_pretty_get "${backend_effective}")"
    printf "%-18s : %s\n" "Applied Path" "$(ssh_network_warp_apply_path_pretty_get "${backend_applied}")"
    printf "%-18s : %s\n" "Target" "${target_label}"
    hr
    ssh_network_effective_rows_print
    hr
    echo "  1) ${option1}"
    echo "  2) ${option2}"
    echo "  3) ${option3}"
    if [[ "${menu_context}" == "warp" ]]; then
      echo "  4) Apply WARP Runtime"
    else
      echo "  4) Apply Routing Runtime"
    fi
    echo "  0) Back"
    hr
    if ! read -r -p "Pilih: " c; then
      echo
      return 0
    fi
    case "${c}" in
      1|2|3)
        local target_user="" target_mode="" target_qf="" prev_mode=""
        case "${c}" in
          1) target_mode="${mode1}" ;;
          2) target_mode="${mode2}" ;;
          3) target_mode="${mode3}" ;;
        esac
        if ! ssh_network_pick_routable_user target_user; then
          pause
          continue
        fi
        target_qf="$(ssh_user_state_resolve_file "${target_user}")"
        prev_mode="$(ssh_network_user_route_mode_get "${target_qf}")"
        if [[ "${menu_context}" == "warp" ]]; then
          confirm_prompt="Set mode WARP SSH '${target_user}' ke ${target_mode} sekarang?"
          cancel_msg="Set mode WARP user dibatalkan."
          success_msg="Mode WARP SSH '${target_user}' diubah ke ${target_mode}."
          fail_msg="Mode WARP SSH '${target_user}' gagal diubah."
        else
          confirm_prompt="Set routing SSH '${target_user}' ke ${target_mode} sekarang?"
          cancel_msg="Set routing user dibatalkan."
          success_msg="Routing SSH '${target_user}' diubah ke ${target_mode}."
          fail_msg="Routing SSH '${target_user}' gagal diubah."
        fi
        if ! confirm_yn_or_back "${confirm_prompt}"; then
          warn "${cancel_msg}"
        elif ssh_network_user_route_mode_set "${target_user}" "${target_mode}" && ssh_network_runtime_apply_now; then
          log "${success_msg}"
        else
          [[ -n "${prev_mode}" ]] && ssh_network_user_route_mode_set "${target_user}" "${prev_mode}" >/dev/null 2>&1 || true
          warn "${fail_msg}"
        fi
        pause
        ;;
      4)
        if ssh_network_runtime_apply_now; then
          if [[ "${menu_context}" == "warp" ]]; then
            log "Runtime WARP SSH berhasil disinkronkan."
          else
            log "Runtime routing SSH berhasil disinkronkan."
          fi
        else
          if [[ "${menu_context}" == "warp" ]]; then
            warn "Runtime WARP SSH gagal disinkronkan."
          else
            warn "Runtime routing SSH gagal disinkronkan."
          fi
        fi
        pause
        ;;
      0|kembali|k|back|b) return 0 ;;
      *) invalid_choice ;;
    esac
  done
}

ssh_network_warp_global_menu() {
  while true; do
    local st global_mode warp_backend warp_backend_effective warp_backend_applied effective_warp_users
    local xray_redir_v4_state xray_redir_v6_state
    local iptables_state ip6tables_state host_warp_mode host_warp_backend host_warp_service_state host_warp_proxy_state host_warp_proxy_port
    st="$(ssh_network_runtime_status_get)"
    global_mode="$(printf '%s\n' "${st}" | awk -F'=' '/^global_mode=/{print $2; exit}')"
    warp_backend="$(printf '%s\n' "${st}" | awk -F'=' '/^warp_backend=/{print $2; exit}')"
    warp_backend_effective="$(printf '%s\n' "${st}" | awk -F'=' '/^warp_backend_effective=/{print $2; exit}')"
    warp_backend_applied="$(printf '%s\n' "${st}" | awk -F'=' '/^warp_backend_applied=/{print $2; exit}')"
    xray_redir_v4_state="$(printf '%s\n' "${st}" | awk -F'=' '/^xray_redir_v4_state=/{print $2; exit}')"
    xray_redir_v6_state="$(printf '%s\n' "${st}" | awk -F'=' '/^xray_redir_v6_state=/{print $2; exit}')"
    iptables_state="$(printf '%s\n' "${st}" | awk -F'=' '/^iptables_state=/{print $2; exit}')"
    ip6tables_state="$(printf '%s\n' "${st}" | awk -F'=' '/^ip6tables_state=/{print $2; exit}')"
    host_warp_mode="$(printf '%s\n' "${st}" | awk -F'=' '/^host_warp_mode=/{print $2; exit}')"
    host_warp_backend="$(printf '%s\n' "${st}" | awk -F'=' '/^host_warp_backend=/{print $2; exit}')"
    host_warp_service_state="$(printf '%s\n' "${st}" | awk -F'=' '/^host_warp_service_state=/{print $2; exit}')"
    host_warp_proxy_state="$(printf '%s\n' "${st}" | awk -F'=' '/^host_warp_proxy_state=/{print $2; exit}')"
    host_warp_proxy_port="$(printf '%s\n' "${st}" | awk -F'=' '/^host_warp_proxy_port=/{print $2; exit}')"
    effective_warp_users="$(printf '%s\n' "${st}" | awk -F'=' '/^effective_warp_users=/{print $2; exit}')"
    title
    echo "$(ssh_network_menu_title "WARP SSH Global")"
    hr
    printf "%-18s : %s\n" "Global WARP" "$([[ "${global_mode}" == "warp" ]] && echo "ON" || echo "OFF")"
    printf "%-18s : %s\n" "Backend Config" "$(ssh_network_warp_backend_pretty_get "${warp_backend:-auto}")"
    printf "%-18s : %s\n" "Backend Target" "$(ssh_network_warp_backend_pretty_get "${warp_backend_effective:-auto}")"
    printf "%-18s : %s\n" "Backend Applied" "$(ssh_network_warp_backend_pretty_get "${warp_backend_applied:-idle}")"
    printf "%-18s : %s\n" "Apply Path" "$(ssh_network_warp_apply_path_pretty_get "${warp_backend_effective:-auto}")"
    printf "%-18s : %s\n" "Host WARP Mode" "${host_warp_mode}"
    printf "%-18s : %s\n" "Host Backend" "${host_warp_backend}"
    printf "%-18s : %s\n" "Host Service" "${host_warp_service_state}"
    printf "%-18s : %s\n" "Host SOCKS" "${host_warp_proxy_state} (127.0.0.1:${host_warp_proxy_port:-40000})"
    printf "%-18s : %s\n" "Xray Redir IPv4" "${xray_redir_v4_state}"
    printf "%-18s : %s\n" "Xray Redir IPv6" "${xray_redir_v6_state}"
    printf "%-18s : %s\n" "iptables IPv4" "${iptables_state}"
    printf "%-18s : %s\n" "ip6tables IPv6" "${ip6tables_state}"
    printf "%-18s : %s\n" "Effective Warp Users" "${effective_warp_users}"
    hr
    echo "  1) Enable WARP Global"
    echo "  2) Disable WARP Global"
    echo "  0) Back"
    hr
    if ! read -r -p "Pilih: " c; then
      echo
      return 0
    fi
    case "${c}" in
      1)
        local prev_mode="${global_mode}"
        if ! confirm_yn_or_back "Aktifkan WARP global untuk trafik SSH sekarang?"; then
          warn "Enable WARP SSH global dibatalkan."
        elif ssh_network_global_mode_set warp && ssh_network_runtime_apply_now; then
          log "WARP SSH global diaktifkan."
        else
          ssh_network_global_mode_set "${prev_mode}" >/dev/null 2>&1 || true
          warn "WARP SSH global gagal diaktifkan."
        fi
        pause
        ;;
      2)
        local prev_mode="${global_mode}"
        if ! confirm_yn_or_back "Matikan WARP global untuk trafik SSH sekarang?"; then
          warn "Disable WARP SSH global dibatalkan."
        elif ssh_network_global_mode_set direct && ssh_network_runtime_apply_now; then
          log "WARP SSH global dimatikan."
        else
          ssh_network_global_mode_set "${prev_mode}" >/dev/null 2>&1 || true
          warn "WARP SSH global gagal dimatikan."
        fi
        pause
        ;;
      0|kembali|k|back|b) return 0 ;;
      *) invalid_choice ;;
    esac
  done
}

ssh_network_warp_user_menu() {
  local SSH_NETWORK_USER_MENU_CONTEXT="warp"
  ssh_network_route_user_menu
}

ssh_network_menu() {
  # shellcheck disable=SC2034 # used by ui_menu_render_options via nameref
  local -a items=(
    "1|DNS for SSH"
    "2|WARP SSH Global"
    "3|WARP SSH Per-User"
    "0|Back"
  )
  while true; do
    ui_menu_screen_begin "6) SSH Network"
    ui_menu_render_options items 76
    hr
    if ! read -r -p "Pilih: " c; then
      echo
      return 0
    fi
    case "${c}" in
      1) menu_run_isolated_report "DNS for SSH" ssh_network_dns_menu ;;
      2) menu_run_isolated_report "WARP SSH Global" ssh_network_warp_global_menu ;;
      3) menu_run_isolated_report "WARP SSH Per-User" ssh_network_warp_user_menu ;;
      0|kembali|k|back|b) return 0 ;;
      *) invalid_choice ;;
    esac
  done
}

ssh_menu() {
  local pending_count=0
  while true; do
    pending_count="$(ssh_pending_recovery_count)"
    [[ "${pending_count}" =~ ^[0-9]+$ ]] || pending_count=0
    ui_menu_screen_begin "2) SSH Users"
    if (( pending_count > 0 )); then
      warn "Ada ${pending_count} journal recovery SSH tertunda. Gunakan 'Recover Pending Txn' bila ingin melanjutkannya."
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
          warn "Mutasi SSH baru ditahan sampai journal recovery tertunda diselesaikan."
          pause
        else
          menu_run_isolated_report "Add SSH User" ssh_add_user_menu
        fi
        ;;
      2)
        if (( pending_count > 0 )); then
          warn "Mutasi SSH baru ditahan sampai journal recovery tertunda diselesaikan."
          pause
        else
          menu_run_isolated_report "Delete SSH User" ssh_delete_user_menu
        fi
        ;;
      3)
        if (( pending_count > 0 )); then
          warn "Mutasi SSH baru ditahan sampai journal recovery tertunda diselesaikan."
          pause
        else
          menu_run_isolated_report "Set SSH Expiry" ssh_extend_expiry_menu
        fi
        ;;
      4)
        if (( pending_count > 0 )); then
          warn "Mutasi SSH baru ditahan sampai journal recovery tertunda diselesaikan."
          pause
        else
          menu_run_isolated_report "Reset SSH Password" ssh_reset_password_menu
        fi
        ;;
      5) ssh_list_users_menu ;;
      6) ssh_runtime_context_run ssh-users sshws_status_menu ;;
      7) ssh_runtime_context_run ssh-users sshws_restart_menu ;;
      8) ssh_runtime_context_run ssh-users sshws_active_sessions_menu ;;
      9) menu_run_isolated_report "Recover Pending SSH Txn" ssh_recover_pending_txn_menu ;;
      0|kembali|k|back|b) break ;;
      *) invalid_choice ;;
    esac
  done
}

# -------------------------
