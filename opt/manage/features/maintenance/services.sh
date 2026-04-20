#!/usr/bin/env bash
# shellcheck shell=bash

# -------------------------
# Wireproxy helpers
# -------------------------
wireproxy_status_menu() {
  title
  echo "7) Maintenance > WARP Status"
  hr

  if ! svc_exists wireproxy; then
    warn "wireproxy.service tidak ditemukan. Pastikan setup.sh sudah dijalankan."
    hr
    pause
    return 0
  fi

  # Status service
  if svc_is_active wireproxy; then
    log "wireproxy : active ✅"
  else
    warn "wireproxy : INACTIVE ❌"
  fi

  # PID & uptime (best-effort)
  local pid uptime_str
  pid="$(systemctl show -p MainPID --value wireproxy 2>/dev/null || true)"
  if [[ -n "${pid}" && "${pid}" != "0" ]]; then
    log "PID       : ${pid}"
    uptime_str="$(process_uptime_pretty "${pid}" || true)"
    [[ -n "${uptime_str}" ]] && log "Uptime    : ${uptime_str}"
  fi

  # Cek SOCKS5 port 40000 (wireproxy bind address)
  hr
  if have_cmd ss; then
    if ss -lntp 2>/dev/null | grep -q ':40000'; then
      log "Port 40000 (SOCKS5) : LISTENING ✅"
    else
      warn "Port 40000 (SOCKS5) : NOT listening ❌"
    fi
  else
    warn "ss tidak tersedia, tidak bisa cek port 40000"
  fi

  # Cek konektivitas WARP via wireproxy (opsional, timeout singkat)
  hr
  log "Test koneksi via WARP proxy (curl --socks5 127.0.0.1:40000, timeout 5s)..."
  if have_cmd curl; then
    local warp_ip
    warp_ip="$(curl -fsSL --socks5 127.0.0.1:40000 --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    if [[ -n "${warp_ip}" ]]; then
      log "WARP outbound IP : ${warp_ip} ✅"
    else
      warn "WARP outbound IP : gagal (wireproxy mungkin tidak terhubung ke WARP)"
    fi
  else
    warn "curl tidak tersedia, skip test koneksi WARP"
  fi

  hr
  echo "Konfigurasi : /etc/wireproxy/config.conf"
  echo "Info log    : disembunyikan agar tampilan ringkas"
  echo
  echo "  1) Lihat log wireproxy (20 baris)"
  echo "  0) Back"
  hr
  if ! read -r -p "Pilih: " c; then
    echo
    return 0
  fi
  case "${c}" in
    1) daemon_log_tail_show wireproxy 20 ;;
    0|kembali|k|back|b) : ;;
    *) warn "Pilihan tidak valid" ; sleep 1 ;;
  esac
}

wireproxy_restart_menu() {
  title
  echo "7) Maintenance > Restart WARP"
  hr

  local confirm_rc=0
  confirm_yn_or_back "Restart wireproxy sekarang?"
  confirm_rc=$?
  if (( confirm_rc != 0 )); then
    if (( confirm_rc == 2 )); then
      warn "Restart wireproxy dibatalkan (kembali)."
    else
      warn "Restart wireproxy dibatalkan."
    fi
    hr
    pause
    return 0
  fi

  local restart_failed="false"
  if ! svc_exists wireproxy; then
    warn "wireproxy.service tidak ditemukan."
    hr
    pause
    return 0
  fi

  if ! warp_wireproxy_post_restart_health_check; then
    warn "Restart wireproxy gagal."
    restart_failed="true"
  fi
  hr
  pause
  [[ "${restart_failed}" != "true" ]]
}

xray_runtime_stats_summary_print() {
  if ! have_cmd xray; then
    warn "xray binary tidak tersedia, skip stats summary"
    return 0
  fi
  if ! have_cmd python3; then
    warn "python3 tidak tersedia, skip stats summary"
    return 0
  fi

  local stats_tmp
  stats_tmp="$(mktemp)"
  if ! xray api statsquery --server=127.0.0.1:10080 >"${stats_tmp}" 2>/dev/null; then
    rm -f "${stats_tmp}"
    warn "Stats query via API gagal"
    return 0
  fi

  python3 - <<'PY' "${stats_tmp}"
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
try:
  data = json.loads(path.read_text(encoding="utf-8"))
except Exception:
  print("[manage][WARN] Stats query mengembalikan JSON tidak valid")
  raise SystemExit(0)

stats = data.get("stat")
if not isinstance(stats, list):
  print("[manage][WARN] Stats query tidak memuat field stat")
  raise SystemExit(0)

user_totals = {}
inbound_totals = {}

for row in stats:
  if not isinstance(row, dict):
    continue
  name = str(row.get("name") or "").strip()
  value = int(row.get("value") or 0)
  if not name:
    continue
  parts = name.split(">>>")
  if len(parts) != 4:
    continue
  scope, ident, traffic_tag, direction = parts
  if traffic_tag != "traffic" or direction not in ("uplink", "downlink"):
    continue
  target = None
  if scope == "user":
    target = user_totals.setdefault(ident, {"uplink": 0, "downlink": 0})
  elif scope == "inbound":
    target = inbound_totals.setdefault(ident, {"uplink": 0, "downlink": 0})
  if target is not None:
    target[direction] += value

def human(n):
  units = ["B", "KB", "MB", "GB", "TB"]
  v = float(max(0, int(n)))
  idx = 0
  while v >= 1024 and idx < len(units) - 1:
    v /= 1024.0
    idx += 1
  if idx == 0:
    return f"{int(v)} {units[idx]}"
  return f"{v:.2f} {units[idx]}"

def top_rows(mapping, limit=3):
  rows = []
  for ident, vals in mapping.items():
    up = int(vals.get("uplink") or 0)
    down = int(vals.get("downlink") or 0)
    total = up + down
    if total <= 0:
      continue
    rows.append((total, ident, up, down))
  rows.sort(reverse=True)
  return rows[:limit]

user_rows = top_rows(user_totals, 3)
inbound_rows = top_rows(inbound_totals, 4)

if user_rows:
  print("Top Users:")
  for total, ident, up, down in user_rows:
    print(f"  {ident:<24} up={human(up):>10} down={human(down):>10} total={human(total):>10}")
else:
  print("Top Users: -")

if inbound_rows:
  print("Inbound Traffic:")
  for total, ident, up, down in inbound_rows:
    print(f"  {ident:<24} up={human(up):>10} down={human(down):>10} total={human(total):>10}")
else:
  print("Inbound Traffic: -")
PY
  rm -f "${stats_tmp}"
}

xray_runtime_log_summary_print() {
  if ! have_cmd python3; then
    warn "python3 tidak tersedia, skip ringkasan log Xray"
    return 0
  fi

  python3 - <<'PY' "/var/log/xray/error.log" "/var/log/xray/access.log"
import pathlib
import sys

error_log = pathlib.Path(sys.argv[1])
access_log = pathlib.Path(sys.argv[2])

def read_tail(path, max_lines=200):
    if not path.exists():
        return []
    try:
        return path.read_text(encoding="utf-8", errors="replace").splitlines()[-max_lines:]
    except Exception:
        return []

def compact(line, limit=140):
    line = " ".join(str(line or "").split())
    if len(line) <= limit:
        return line
    return line[: limit - 3] + "..."

err_lines = read_tail(error_log, 200)
acc_lines = read_tail(access_log, 200)

warn_count = sum(1 for line in err_lines if "[Warning]" in line)
error_count = sum(1 for line in err_lines if "[Error]" in line)
depr_count = sum(1 for line in err_lines if "deprecated" in line.lower())

last_warn = next((line for line in reversed(err_lines) if "[Warning]" in line), "")
last_err = next((line for line in reversed(err_lines) if "[Error]" in line), "")
last_access = acc_lines[-1] if acc_lines else ""

print(f"Error Log    : warn={warn_count} error={error_count} deprecated={depr_count}")
print(f"Access Tail  : {len(acc_lines)} line sample")
if last_warn:
    print(f"Last Warning : {compact(last_warn)}")
if last_err:
    print(f"Last Error   : {compact(last_err)}")
if last_access:
    print(f"Last Access  : {compact(last_access)}")
PY
}

xray_runtime_snapshot_export() {
  if ! have_cmd python3; then
    warn "python3 tidak tersedia, tidak bisa export snapshot"
    return 1
  fi

  local report_dir out stats_tmp dns_blob metrics_vars metrics_pprof fake_a fake_aaaa
  report_dir="${REPORT_DIR:-/root/report}"
  mkdir -p "${report_dir}" >/dev/null 2>&1 || {
    warn "Gagal membuat report dir: ${report_dir}"
    return 1
  }
  out="${report_dir}/xray-runtime-$(date +%Y%m%d-%H%M%S).json"
  stats_tmp="$(mktemp)"
  xray api statsquery --server=127.0.0.1:10080 >"${stats_tmp}" 2>/dev/null || printf '{"stat":[]}\n' >"${stats_tmp}"

  dns_blob=""
  if declare -F xray_dns_status_get >/dev/null 2>&1; then
    dns_blob="$(xray_dns_status_get "${XRAY_DNS_CONF:-/usr/local/etc/xray/conf.d/02-dns.json}")"
  fi

  metrics_vars="false"
  metrics_pprof="false"
  if have_cmd curl; then
    curl -fsS --max-time 2 "http://127.0.0.1:11111/debug/vars" >/dev/null 2>&1 && metrics_vars="true"
    curl -fsS --max-time 2 "http://127.0.0.1:11111/debug/pprof/" >/dev/null 2>&1 && metrics_pprof="true"
  fi

  fake_a=""
  fake_aaaa=""
  if have_cmd dig; then
    fake_a="$(dig +short @127.0.0.1 -p 1053 www.google.com A 2>/dev/null | head -n1 || true)"
    fake_aaaa="$(dig +short @127.0.0.1 -p 1053 www.google.com AAAA 2>/dev/null | head -n1 || true)"
  fi

  python3 - <<'PY' "${out}" "${stats_tmp}" "${dns_blob}" "${metrics_vars}" "${metrics_pprof}" "${fake_a}" "${fake_aaaa}"
import json
import os
import pathlib
import re
import subprocess
import sys
import time

out_path = pathlib.Path(sys.argv[1])
stats_path = pathlib.Path(sys.argv[2])
dns_blob = sys.argv[3]
metrics_vars = sys.argv[4].lower() == "true"
metrics_pprof = sys.argv[5].lower() == "true"
fake_a = sys.argv[6]
fake_aaaa = sys.argv[7]

def run(cmd):
    try:
        return subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL).strip()
    except Exception:
        return ""

def service_active(name):
    return run(["systemctl", "is-active", name]) == "active"

def listen_tcp(port):
    out = run(["ss", "-ltn"])
    return bool(re.search(rf'(^|\\s)127\\.0\\.0\\.1:{port}(\\s|$)', out, re.M))

def listen_tcp_any(port):
    out = run(["ss", "-ltn"])
    return bool(re.search(rf'(^|\\s)[^\\s]*:{port}(\\s|$)', out, re.M))

def listen_udp_local(port):
    out = run(["ss", "-lun"])
    return bool(re.search(rf'(^|\\s)127\\.0\\.0\\.1:{port}(\\s|$)', out, re.M))

def listen_udp_any(port):
    out = run(["ss", "-lun"])
    return bool(re.search(rf'(^|\\s)[^\\s]*:{port}(\\s|$)', out, re.M))

pid = run(["systemctl", "show", "-p", "MainPID", "--value", "xray"])
started = run(["ps", "-o", "etimes=", "-p", pid]) if pid and pid != "0" else ""
uptime_seconds = int(started) if started.isdigit() else 0

dns_summary = {}
for line in dns_blob.splitlines():
    if "=" not in line:
        continue
    k, v = line.split("=", 1)
    dns_summary[k.strip()] = v.strip()

try:
    stats_payload = json.loads(stats_path.read_text(encoding="utf-8"))
except Exception:
    stats_payload = {"stat": []}

snapshot = {
    "generated_at_unix": int(time.time()),
    "service": {
        "xray_active": service_active("xray"),
        "pid": pid,
        "uptime_seconds": uptime_seconds,
    },
    "listeners": {
        "api_10080_tcp": listen_tcp(10080),
        "dns_1053_tcp": listen_tcp(1053),
        "dns_1053_udp": listen_udp_local(1053),
        "xhttp3_443_udp": listen_udp_any(443),
        "metrics_11111_tcp": listen_tcp(11111),
    },
    "metrics": {
        "debug_vars_ok": metrics_vars,
        "debug_pprof_ok": metrics_pprof,
    },
    "dns": dns_summary,
    "fakedns": {
        "a": fake_a,
        "aaaa": fake_aaaa,
    },
    "statsquery": stats_payload,
    "logs": {
        "access_log": "/var/log/xray/access.log",
        "error_log": "/var/log/xray/error.log",
    },
}

out_path.write_text(json.dumps(snapshot, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY
  rm -f "${stats_tmp}" >/dev/null 2>&1 || true

  if [[ -f "${out}" ]]; then
    chmod 600 "${out}" >/dev/null 2>&1 || true
    log "Snapshot tersimpan: ${out}"
    return 0
  fi
  warn "Gagal menulis snapshot runtime Xray."
  return 1
}

xray_runtime_status_menu() {
  title
  echo "7) Maintenance > Xray Runtime Status"
  hr

  local xray_dns_conf metrics_url access_log error_log
  xray_dns_conf="${XRAY_DNS_CONF:-/usr/local/etc/xray/conf.d/02-dns.json}"
  metrics_url="http://127.0.0.1:11111"
  access_log="/var/log/xray/access.log"
  error_log="/var/log/xray/error.log"

  if svc_exists xray; then
    svc_status_line xray
  else
    warn "xray tidak terpasang"
    hr
    pause
    return 0
  fi

  local pid uptime_str
  pid="$(systemctl show -p MainPID --value xray 2>/dev/null || true)"
  if [[ -n "${pid}" && "${pid}" != "0" ]]; then
    echo "PID         : ${pid}"
    uptime_str="$(process_uptime_pretty "${pid}" || true)"
    [[ -n "${uptime_str}" ]] && echo "Uptime      : ${uptime_str}"
  fi

  hr
  if have_cmd ss; then
    if ss -ltn 2>/dev/null | grep -Eq '(^|[[:space:]])127\.0\.0\.1:10080([[:space:]]|$)'; then
      log "API 127.0.0.1:10080      : LISTENING ✅"
    else
      warn "API 127.0.0.1:10080      : NOT listening ❌"
    fi
    if ss -ltn 2>/dev/null | grep -Eq '(^|[[:space:]])127\.0\.0\.1:1053([[:space:]]|$)'; then
      log "DNS TCP 127.0.0.1:1053   : LISTENING ✅"
    else
      warn "DNS TCP 127.0.0.1:1053   : NOT listening ❌"
    fi
    if ss -lun 2>/dev/null | grep -Eq '(^|[[:space:]])127\.0\.0\.1:1053([[:space:]]|$)'; then
      log "DNS UDP 127.0.0.1:1053   : LISTENING ✅"
    else
      warn "DNS UDP 127.0.0.1:1053   : NOT listening ❌"
    fi
    if ss -lun 2>/dev/null | grep -Eq '(^|[[:space:]])[^[:space:]]*:443([[:space:]]|$)'; then
      log "XHTTP/3 UDP *:443        : LISTENING ✅"
    else
      warn "XHTTP/3 UDP *:443        : NOT listening ❌"
    fi
    if ss -ltn 2>/dev/null | grep -Eq '(^|[[:space:]])127\.0\.0\.1:11111([[:space:]]|$)'; then
      log "Metrics 127.0.0.1:11111  : LISTENING ✅"
    else
      warn "Metrics 127.0.0.1:11111  : NOT listening ❌"
    fi
  else
    warn "ss tidak tersedia, skip cek listener Xray"
  fi

  hr
  if have_cmd curl; then
    if curl -fsS --max-time 2 "${metrics_url}/debug/vars" >/dev/null 2>&1; then
      log "Metrics /debug/vars      : OK ✅"
    else
      warn "Metrics /debug/vars      : FAIL ❌"
    fi
    if curl -fsS --max-time 2 "${metrics_url}/debug/pprof/" >/dev/null 2>&1; then
      log "Metrics /debug/pprof     : OK ✅"
    else
      warn "Metrics /debug/pprof     : FAIL ❌"
    fi
  else
    warn "curl tidak tersedia, skip cek metrics Xray"
  fi

  hr
  if declare -F xray_dns_status_get >/dev/null 2>&1; then
    local status_blob parse_state primary secondary strategy cache
    status_blob="$(xray_dns_status_get "${xray_dns_conf}")"
    parse_state="$(printf '%s\n' "${status_blob}" | awk -F'=' '/^parse_state=/{print $2; exit}' 2>/dev/null || true)"
    primary="$(printf '%s\n' "${status_blob}" | awk -F'=' '/^primary=/{print $2; exit}' 2>/dev/null || true)"
    secondary="$(printf '%s\n' "${status_blob}" | awk -F'=' '/^secondary=/{print $2; exit}' 2>/dev/null || true)"
    strategy="$(printf '%s\n' "${status_blob}" | awk -F'=' '/^strategy=/{print $2; exit}' 2>/dev/null || true)"
    cache="$(printf '%s\n' "${status_blob}" | awk -F'=' '/^cache=/{print $2; exit}' 2>/dev/null || true)"
    [[ -n "${primary}" ]] || primary="-"
    [[ -n "${secondary}" ]] || secondary="-"
    [[ -n "${strategy}" ]] || strategy="-"
    [[ -n "${cache}" ]] || cache="on"
    echo "DNS Parser  : ${parse_state:-unknown}"
    echo "DNS Primary : ${primary}"
    echo "DNS Second  : ${secondary}"
    echo "DNS Strategy: ${strategy}"
    echo "DNS Cache   : $( [[ "${cache}" == "on" ]] && echo ON || echo OFF )"
  else
    warn "xray_dns_status_get tidak tersedia, skip ringkasan DNS"
  fi

  if have_cmd dig; then
    local fake_a fake_aaaa
    fake_a="$(dig +short @127.0.0.1 -p 1053 www.google.com A 2>/dev/null | head -n1 || true)"
    fake_aaaa="$(dig +short @127.0.0.1 -p 1053 www.google.com AAAA 2>/dev/null | head -n1 || true)"
    [[ -n "${fake_a}" ]] && echo "FakeDNS A   : ${fake_a}" || warn "FakeDNS A   : gagal"
    [[ -n "${fake_aaaa}" ]] && echo "FakeDNS AAAA: ${fake_aaaa}" || warn "FakeDNS AAAA: gagal"
  else
    warn "dig tidak tersedia, skip cek FakeDNS"
  fi

  hr
  xray_runtime_stats_summary_print

  hr
  xray_runtime_log_summary_print

  hr
  if [[ -f "${access_log}" ]]; then
    echo "Access log  : ${access_log} ($(stat -c '%s bytes' "${access_log}" 2>/dev/null || echo '?'))"
  else
    warn "Access log  : ${access_log} tidak ada"
  fi
  if [[ -f "${error_log}" ]]; then
    echo "Error log   : ${error_log} ($(stat -c '%s bytes' "${error_log}" 2>/dev/null || echo '?'))"
  else
    warn "Error log   : ${error_log} tidak ada"
  fi

  echo
  echo "  1) Xray Logs (80 baris)"
  echo "  2) Error Log (40 baris)"
  echo "  3) Export Runtime Snapshot"
  echo "  0) Back"
  hr
  if ! read -r -p "Pilih: " c; then
    echo
    return 0
  fi
  case "${c}" in
    1) title ; tail_logs xray 80 ; hr ; pause ;;
    2)
      title
      echo "7) Maintenance > Xray Error Log"
      hr
      if [[ -f "${error_log}" ]]; then
        tail -n 40 "${error_log}" 2>/dev/null || true
      else
        warn "File error log tidak ditemukan."
      fi
      hr
      pause
      ;;
    3)
      xray_runtime_snapshot_export || true
      hr
      pause
      ;;
    0|kembali|k|back|b) : ;;
    *) warn "Pilihan tidak valid" ; sleep 1 ;;
  esac
}

edge_runtime_env_file() {
  printf '%s\n' "/etc/default/edge-runtime"
}

edge_runtime_get_env() {
  local key="$1"
  local env_file
  env_file="$(edge_runtime_env_file)"
  [[ -r "${env_file}" ]] || return 1
  awk -F= -v key="${key}" '
    $1 == key {
      sub(/^[[:space:]]+/, "", $2)
      sub(/[[:space:]]+$/, "", $2)
      print $2
      exit
    }
  ' "${env_file}"
}

edge_runtime_port_list() {
  local list_key="$1" single_key="$2" fallback_list="$3" fallback_single="$4"
  local raw
  raw="$(edge_runtime_get_env "${list_key}" 2>/dev/null || true)"
  if [[ -z "${raw}" ]]; then
    raw="$(edge_runtime_get_env "${single_key}" 2>/dev/null || true)"
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

edge_runtime_public_http_ports() {
  edge_runtime_port_list EDGE_PUBLIC_HTTP_PORTS EDGE_PUBLIC_HTTP_PORT "80 8080 8880 2052 2082 2086 2095" "80"
}

edge_runtime_public_tls_ports() {
  edge_runtime_port_list EDGE_PUBLIC_TLS_PORTS EDGE_PUBLIC_TLS_PORT "443 2053 2083 2087 2096 8443" "443"
}

edge_runtime_ports_label() {
  local ports="${1:-}"
  [[ -n "${ports}" ]] || {
    printf '%s\n' "-"
    return 0
  }
  printf '%s\n' "${ports}" | sed 's/ /, /g'
}

edge_runtime_service_name() {
  local provider
  provider="$(edge_runtime_get_env EDGE_PROVIDER 2>/dev/null || echo "none")"
  case "${provider}" in
    nginx-stream) printf '%s\n' "nginx" ;;
    go) printf '%s\n' "edge-mux.service" ;;
    *) printf '%s\n' "edge-mux.service" ;;
  esac
}

edge_runtime_effective_xray_backend() {
  local key="${1:-}"
  local provider="${2:-none}"
  local http_backend="${3:-127.0.0.1:18080}"
  local nginx_tls_backend="${4:-127.0.0.1:18443}"
  local value

  case "${key}" in
    EDGE_XRAY_DIRECT_BACKEND)
      value="$(edge_runtime_get_env "${key}" 2>/dev/null || true)"
      printf '%s\n' "${value:-${http_backend}}"
      return 0
      ;;
    EDGE_XRAY_WS_BACKEND)
      value="$(edge_runtime_get_env "${key}" 2>/dev/null || true)"
      printf '%s\n' "${value:-${http_backend}}"
      return 0
      ;;
    EDGE_XRAY_TLS_BACKEND)
      value="$(edge_runtime_get_env "${key}" 2>/dev/null || true)"
      if [[ -z "${value}" ]]; then
        if [[ "${provider}" == "go" ]]; then
          printf '%s\n' "${http_backend}"
        else
          printf '%s\n' "${nginx_tls_backend}"
        fi
        return 0
      fi
      if [[ "${provider}" == "go" && "${value}" == "${nginx_tls_backend}" ]]; then
        local direct_backend ws_backend
        direct_backend="$(edge_runtime_get_env EDGE_XRAY_DIRECT_BACKEND 2>/dev/null || true)"
        ws_backend="$(edge_runtime_get_env EDGE_XRAY_WS_BACKEND 2>/dev/null || true)"
        direct_backend="${direct_backend:-${http_backend}}"
        ws_backend="${ws_backend:-${http_backend}}"
        if [[ "${direct_backend}" == "${http_backend}" && "${ws_backend}" == "${http_backend}" ]]; then
          printf '%s\n' "${http_backend}"
          return 0
        fi
      fi
      printf '%s\n' "${value}"
      return 0
      ;;
  esac

  return 1
}

edge_runtime_log_unique_backend_listener() {
  local label="${1:-}"
  local addr="${2:-}"
  local seen_name="${3:-}"
  local fail_on_missing="${4:-false}"
  [[ -n "${label}" && -n "${addr}" && -n "${seen_name}" ]] || return 0

  local -n seen_ref="${seen_name}"
  if [[ -n "${seen_ref[${addr}]:-}" ]]; then
    return 0
  fi
  seen_ref["${addr}"]=1

  local port
  port="${addr##*:}"
  if edge_runtime_socket_listening "${port}"; then
    log "${label} ${addr} : LISTENING ✅"
    return 0
  fi
  warn "${label} ${addr} : NOT listening ❌"
  [[ "${fail_on_missing}" != "true" ]]
}

format_elapsed_seconds_pretty() {
  local total="${1:-0}"
  local days hours mins secs rem
  [[ "${total}" =~ ^[0-9]+$ ]] || return 1

  days=$(( total / 86400 ))
  rem=$(( total % 86400 ))
  hours=$(( rem / 3600 ))
  rem=$(( rem % 3600 ))
  mins=$(( rem / 60 ))
  secs=$(( rem % 60 ))

  if (( days > 0 )); then
    printf '%d-%02d:%02d:%02d\n' "${days}" "${hours}" "${mins}" "${secs}"
  else
    printf '%02d:%02d:%02d\n' "${hours}" "${mins}" "${secs}"
  fi
}

process_uptime_pretty() {
  local pid="${1:-}"
  local started_at now_ts start_ts elapsed
  [[ "${pid}" =~ ^[0-9]+$ ]] || return 1
  (( pid > 0 )) || return 1

  started_at="$(ps -o lstart= -p "${pid}" 2>/dev/null | sed -e 's/^[[:space:]]*//' || true)"
  [[ -n "${started_at}" ]] || return 1

  now_ts="$(date +%s 2>/dev/null || true)"
  start_ts="$(date -d "${started_at}" +%s 2>/dev/null || true)"
  [[ "${now_ts}" =~ ^[0-9]+$ && "${start_ts}" =~ ^[0-9]+$ ]] || return 1
  (( now_ts >= start_ts )) || return 1

  elapsed=$(( now_ts - start_ts ))
  format_elapsed_seconds_pretty "${elapsed}"
}

edge_runtime_tls_backend_required() {
  local provider="${1:-}"
  local active="${2:-false}"
  [[ "${active}" == "true" && "${provider}" == "nginx-stream" ]]
}

edge_runtime_metrics_addr() {
  edge_runtime_get_env EDGE_METRICS_LISTEN 2>/dev/null || echo "127.0.0.1:9910"
}

edge_runtime_print_observability_summary() {
  local addr="${1:-}"
  [[ -n "${addr}" ]] || addr="$(edge_runtime_metrics_addr)"

  if ! have_cmd curl; then
    warn "curl tidak tersedia, skip observability edge"
    return 0
  fi
  if ! have_cmd python3; then
    warn "python3 tidak tersedia, skip observability edge"
    return 0
  fi

  local status_tmp
  status_tmp="$(mktemp)"
  if ! curl -fsS --max-time 2 "http://${addr}/status" >"${status_tmp}" 2>/dev/null; then
    rm -f "${status_tmp}"
    warn "Status ${addr} : unavailable"
    return 0
  fi

  python3 - <<'PY' "${addr}" "${status_tmp}"
import json
import pathlib
import re
import sys

addr = sys.argv[1]
path = pathlib.Path(sys.argv[2])
try:
  data = json.loads(path.read_text(encoding="utf-8"))
except Exception:
  print(f"[manage][WARN] Status {addr} : invalid JSON")
  raise SystemExit(0)

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

def yesno(v):
  return "up" if bool(v) else "down"

def join_map(mapping):
  if not isinstance(mapping, dict) or not mapping:
    return "-"
  parts = []
  for key in sorted(mapping):
    parts.append(f"{key}={mapping[key]}")
  return ", ".join(parts)

def join_abuse_blocks(until_map, reason_map, surface_map):
  if not isinstance(until_map, dict) or not until_map:
    return "-"
  parts = []
  for ip in sorted(until_map):
    reason = "-"
    surface = "-"
    if isinstance(reason_map, dict):
      reason = str(reason_map.get(ip) or "-").strip() or "-"
    if isinstance(surface_map, dict):
      surface = str(surface_map.get(ip) or "-").strip() or "-"
    parts.append(f"{ip}({reason}/{surface})")
  return ", ".join(parts) if parts else "-"

def backend_status_text(row):
  if not isinstance(row, dict):
    return "-"
  status = str(row.get("status") or "").strip().lower()
  healthy = bool(row.get("healthy"))
  if not status:
    status = "up" if healthy else "down"
  latency = to_int(row.get("latency_ms"), -1)
  reason = str(row.get("reason") or "").strip()
  address = str(row.get("address") or "-").strip() or "-"
  parts = [status]
  if latency >= 0 and status in ("up", "degraded"):
    parts.append(f"{latency}ms")
  if status in ("down", "disabled") and reason:
    parts.append(reason)
  parts.append(address)
  return " | ".join(parts)

surface = data.get("surface")
listeners = data.get("listener_up") if isinstance(data.get("listener_up"), dict) else {}
last_route = data.get("last_route") if isinstance(data.get("last_route"), dict) else {}
backend_health = data.get("backend_health") if isinstance(data.get("backend_health"), dict) else {}
abuse = data.get("abuse") if isinstance(data.get("abuse"), dict) else {}

print(f"[manage] Status {addr} : ok ✅")
print(f"Runtime OK  : {'true' if bool(data.get('ok')) else 'false'}")
print(f"Active conn : {to_int(data.get('active_connections_total'), 0)}")
print(
  "Listeners   : "
  f"http={yesno(listeners.get('http'))} "
  f"tls={yesno(listeners.get('tls'))} "
  f"metrics={yesno(listeners.get('metrics'))}"
)
if last_route:
  print(
    "Last route  : "
    f"{last_route.get('surface') or '-'} | "
    f"{last_route.get('route') or '-'} | "
    f"{last_route.get('backend') or '-'}"
  )

if backend_health:
  print("Backends:")
  for name in sorted(backend_health):
    print(f"  {name:<18} {backend_status_text(backend_health.get(name))}")

if abuse:
  print(
    "Abuse: "
    f"active_ip={to_int(abuse.get('active_ips'), 0)} "
    f"active_conn={to_int(abuse.get('active_connections'), 0)} "
    f"rate_tracked={to_int(abuse.get('rate_tracked_ips'), 0)} "
    f"reject_tracked={to_int(abuse.get('reject_tracked_ips'), 0)} "
    f"cooldown={to_int(abuse.get('cooldown_blocked_ips'), 0)}"
  )
  reject_reasons = join_map(abuse.get("reject_reasons"))
  reject_surfaces = join_map(abuse.get("reject_surfaces"))
  blocked = join_abuse_blocks(
    abuse.get("blocked_until_unix"),
    abuse.get("blocked_reason"),
    abuse.get("blocked_surface"),
  )
  print(f"  reasons            {reject_reasons}")
  print(f"  surfaces           {reject_surfaces}")
  print(f"  blocked            {blocked}")

if isinstance(surface, dict) and surface:
  print("Surface:")
  for name in sorted(surface):
    row = surface.get(name)
    if not isinstance(row, dict):
      continue
    active = to_int(row.get("active_connections"), 0)
    accepted = to_int(row.get("accepted_total"), 0)
    rejected = to_int(row.get("rejected_total"), 0)
    detect = join_map(row.get("detect_totals"))
    routes = join_map(row.get("route_totals"))
    print(
      f"  {name:<18} "
      f"act={active} acc={accepted} rej={rejected} "
      f"detect={detect} route={routes}"
    )
PY
  rm -f "${status_tmp}"
}

edge_runtime_status_menu() {
  title
  echo "7) Maintenance > Edge Gateway Status"
  hr

  local svc env_file provider active http_ports tls_ports http_backend http_tls_backend detect_timeout tls80 tls_backend_required
  local xray_direct_backend xray_tls_backend xray_ws_backend
  svc="$(edge_runtime_service_name)"
  env_file="$(edge_runtime_env_file)"
  provider="$(edge_runtime_get_env EDGE_PROVIDER 2>/dev/null || echo "none")"
  active="$(edge_runtime_get_env EDGE_ACTIVATE_RUNTIME 2>/dev/null || echo "false")"
  http_ports="$(edge_runtime_public_http_ports)"
  tls_ports="$(edge_runtime_public_tls_ports)"
  http_backend="$(edge_runtime_get_env EDGE_NGINX_HTTP_BACKEND 2>/dev/null || echo "127.0.0.1:18080")"
  http_tls_backend="$(edge_runtime_get_env EDGE_NGINX_TLS_BACKEND 2>/dev/null || echo "127.0.0.1:18443")"
  xray_direct_backend="$(edge_runtime_effective_xray_backend EDGE_XRAY_DIRECT_BACKEND "${provider}" "${http_backend}" "${http_tls_backend}" 2>/dev/null || echo "${http_backend}")"
  xray_tls_backend="$(edge_runtime_effective_xray_backend EDGE_XRAY_TLS_BACKEND "${provider}" "${http_backend}" "${http_tls_backend}" 2>/dev/null || echo "${http_backend}")"
  xray_ws_backend="$(edge_runtime_effective_xray_backend EDGE_XRAY_WS_BACKEND "${provider}" "${http_backend}" "${http_tls_backend}" 2>/dev/null || echo "${http_backend}")"
  detect_timeout="$(edge_runtime_get_env EDGE_HTTP_DETECT_TIMEOUT_MS 2>/dev/null || echo "250")"
  tls80="$(edge_runtime_get_env EDGE_CLASSIC_TLS_ON_80 2>/dev/null || echo "true")"
  if edge_runtime_tls_backend_required "${provider}" "${active}"; then
    tls_backend_required="true"
  else
    tls_backend_required="false"
  fi

  echo "Runtime env : ${env_file}"
  echo "Provider    : ${provider}"
  echo "Activate    : ${active}"
  echo "HTTP ports  : $(edge_runtime_ports_label "${http_ports}")"
  echo "TLS ports   : $(edge_runtime_ports_label "${tls_ports}")"
  echo "Nginx HTTP  : ${http_backend}"
  if [[ "${tls_backend_required}" == "true" ]]; then
    echo "Nginx HTTPS : ${http_tls_backend}"
  else
    echo "Nginx HTTPS : ${http_tls_backend} (unused)"
  fi
  echo "Xray Direct : ${xray_direct_backend}"
  echo "Xray TLS    : ${xray_tls_backend}"
  echo "Xray WS     : ${xray_ws_backend}"
  echo "Detect (ms) : ${detect_timeout}"
  echo "TLS on 80   : ${tls80}"
  hr

  if svc_exists "${svc}"; then
    svc_status_line "${svc}"
  else
    warn "${svc} tidak terpasang"
  fi

  if svc_exists nginx; then
    svc_status_line nginx
  fi

  hr
  if have_cmd ss; then
    declare -A seen_backends=()
    local port missing_http=() missing_tls=()
    for port in ${http_ports}; do
      if ! ss -lnt 2>/dev/null | grep -Eq "(^|[[:space:]])[^[:space:]]*:${port}([[:space:]]|$)"; then
        missing_http+=("${port}")
      fi
    done
    if (( ${#missing_http[@]} == 0 )); then
      log "Public HTTP $(edge_runtime_ports_label "${http_ports}") : LISTENING ✅"
    else
      warn "Public HTTP $(edge_runtime_ports_label "${http_ports}") : missing ${missing_http[*]} ❌"
    fi
    for port in ${tls_ports}; do
      if ! ss -lnt 2>/dev/null | grep -Eq "(^|[[:space:]])[^[:space:]]*:${port}([[:space:]]|$)"; then
        missing_tls+=("${port}")
      fi
    done
    if (( ${#missing_tls[@]} == 0 )); then
      log "Public TLS  $(edge_runtime_ports_label "${tls_ports}") : LISTENING ✅"
    else
      warn "Public TLS  $(edge_runtime_ports_label "${tls_ports}") : missing ${missing_tls[*]} ❌"
    fi

    local backend_http_port backend_http_tls_port
    backend_http_port="${http_backend##*:}"
    if ss -lnt 2>/dev/null | grep -Eq "(^|[[:space:]])[^[:space:]]*:${backend_http_port}([[:space:]]|$)"; then
      log "Backend HTTP ${http_backend} : LISTENING ✅"
    else
      warn "Backend HTTP ${http_backend} : NOT listening ❌"
    fi
    if [[ "${tls_backend_required}" == "true" ]]; then
      backend_http_tls_port="${http_tls_backend##*:}"
      if ss -lnt 2>/dev/null | grep -Eq "(^|[[:space:]])[^[:space:]]*:${backend_http_tls_port}([[:space:]]|$)"; then
        log "Backend HTTPS ${http_tls_backend} : LISTENING ✅"
      else
        warn "Backend HTTPS ${http_tls_backend} : NOT listening ❌"
      fi
      # shellcheck disable=SC2034
      seen_backends["${http_tls_backend}"]=1
    else
      log "Backend HTTPS ${http_tls_backend} : unused for provider ${provider} ✅"
    fi
    # shellcheck disable=SC2034
    seen_backends["${http_backend}"]=1
    edge_runtime_log_unique_backend_listener "Xray Direct" "${xray_direct_backend}" seen_backends || true
    edge_runtime_log_unique_backend_listener "Xray TLS" "${xray_tls_backend}" seen_backends || true
    edge_runtime_log_unique_backend_listener "Xray WS" "${xray_ws_backend}" seen_backends || true
  else
    warn "ss tidak tersedia, skip cek listener edge"
  fi

  hr
  edge_runtime_print_observability_summary "$(edge_runtime_metrics_addr)"
  hr
  pause
}

edge_runtime_socket_listening() {
  local port="${1:-0}"
  [[ "${port}" =~ ^[0-9]+$ ]] || return 1
  have_cmd ss || return 0
  ss -lnt 2>/dev/null | grep -Eq "(^|[[:space:]])[^[:space:]]*:${port}([[:space:]]|$)"
}

edge_runtime_post_restart_health_check() {
  local svc provider active http_ports tls_ports http_backend http_tls_backend tls_backend_required
  local xray_direct_backend xray_tls_backend xray_ws_backend
  local backend_http_port backend_http_tls_port
  svc="$(edge_runtime_service_name)"
  provider="$(edge_runtime_get_env EDGE_PROVIDER 2>/dev/null || echo "none")"
  active="$(edge_runtime_get_env EDGE_ACTIVATE_RUNTIME 2>/dev/null || echo "false")"
  http_ports="$(edge_runtime_public_http_ports)"
  tls_ports="$(edge_runtime_public_tls_ports)"
  http_backend="$(edge_runtime_get_env EDGE_NGINX_HTTP_BACKEND 2>/dev/null || echo "127.0.0.1:18080")"
  http_tls_backend="$(edge_runtime_get_env EDGE_NGINX_TLS_BACKEND 2>/dev/null || echo "127.0.0.1:18443")"
  xray_direct_backend="$(edge_runtime_effective_xray_backend EDGE_XRAY_DIRECT_BACKEND "${provider}" "${http_backend}" "${http_tls_backend}" 2>/dev/null || echo "${http_backend}")"
  xray_tls_backend="$(edge_runtime_effective_xray_backend EDGE_XRAY_TLS_BACKEND "${provider}" "${http_backend}" "${http_tls_backend}" 2>/dev/null || echo "${http_backend}")"
  xray_ws_backend="$(edge_runtime_effective_xray_backend EDGE_XRAY_WS_BACKEND "${provider}" "${http_backend}" "${http_tls_backend}" 2>/dev/null || echo "${http_backend}")"
  if edge_runtime_tls_backend_required "${provider}" "${active}"; then
    tls_backend_required="true"
  else
    tls_backend_required="false"
  fi

  if ! svc_restart_checked "${svc}" 60; then
    warn "Restart ${svc} gagal."
    return 1
  fi

  backend_http_port="${http_backend##*:}"
  backend_http_tls_port="${http_tls_backend##*:}"

  local port
  for port in ${http_ports}; do
    if ! edge_runtime_socket_listening "${port}"; then
      warn "Port HTTP publik ${port} belum listening setelah restart edge."
      return 1
    fi
  done
  for port in ${tls_ports}; do
    if ! edge_runtime_socket_listening "${port}"; then
      warn "Port TLS publik ${port} belum listening setelah restart edge."
      return 1
    fi
  done
  if ! edge_runtime_socket_listening "${backend_http_port}"; then
    warn "Backend HTTP ${http_backend} belum listening setelah restart edge."
    return 1
  fi
  if [[ "${tls_backend_required}" == "true" ]] && ! edge_runtime_socket_listening "${backend_http_tls_port}"; then
    warn "Backend HTTPS ${http_tls_backend} belum listening setelah restart edge."
    return 1
  fi
  declare -A seen_backends=()
  # shellcheck disable=SC2034
  seen_backends["${http_backend}"]=1
  if [[ "${tls_backend_required}" == "true" ]]; then
    # shellcheck disable=SC2034
    seen_backends["${http_tls_backend}"]=1
  fi
  edge_runtime_log_unique_backend_listener "Xray Direct" "${xray_direct_backend}" seen_backends true || return 1
  edge_runtime_log_unique_backend_listener "Xray TLS" "${xray_tls_backend}" seen_backends true || return 1
  edge_runtime_log_unique_backend_listener "Xray WS" "${xray_ws_backend}" seen_backends true || return 1
  return 0
}

edge_runtime_restart_menu() {
  title
  echo "7) Maintenance > Restart Edge Gateway"
  hr

  local confirm_rc=0
  confirm_yn_or_back "Restart Edge Gateway sekarang?"
  confirm_rc=$?
  if (( confirm_rc != 0 )); then
    if (( confirm_rc == 2 )); then
      warn "Restart Edge Gateway dibatalkan (kembali)."
    else
      warn "Restart Edge Gateway dibatalkan."
    fi
    hr
    pause
    return 0
  fi

  local restart_failed="false"
  local svc
  svc="$(edge_runtime_service_name)"
  if ! svc_exists "${svc}"; then
    warn "${svc} tidak terpasang."
    hr
    pause
    return 0
  fi

  if ! edge_runtime_post_restart_health_check; then
    warn "Restart ${svc} gagal."
    restart_failed="true"
  fi
  hr
  pause
  [[ "${restart_failed}" != "true" ]]
}

edge_runtime_info_menu() {
  title
  echo "7) Maintenance > Edge Gateway Info"
  hr

  local provider active http_ports tls_ports http_backend http_tls_backend detect_timeout tls80 cert_file key_file
  local xray_direct_backend xray_tls_backend xray_ws_backend
  provider="$(edge_runtime_get_env EDGE_PROVIDER 2>/dev/null || echo "none")"
  active="$(edge_runtime_get_env EDGE_ACTIVATE_RUNTIME 2>/dev/null || echo "false")"
  http_ports="$(edge_runtime_public_http_ports)"
  tls_ports="$(edge_runtime_public_tls_ports)"
  http_backend="$(edge_runtime_get_env EDGE_NGINX_HTTP_BACKEND 2>/dev/null || echo "127.0.0.1:18080")"
  http_tls_backend="$(edge_runtime_get_env EDGE_NGINX_TLS_BACKEND 2>/dev/null || echo "127.0.0.1:18443")"
  xray_direct_backend="$(edge_runtime_effective_xray_backend EDGE_XRAY_DIRECT_BACKEND "${provider}" "${http_backend}" "${http_tls_backend}" 2>/dev/null || echo "${http_backend}")"
  xray_tls_backend="$(edge_runtime_effective_xray_backend EDGE_XRAY_TLS_BACKEND "${provider}" "${http_backend}" "${http_tls_backend}" 2>/dev/null || echo "${http_backend}")"
  xray_ws_backend="$(edge_runtime_effective_xray_backend EDGE_XRAY_WS_BACKEND "${provider}" "${http_backend}" "${http_tls_backend}" 2>/dev/null || echo "${http_backend}")"
  detect_timeout="$(edge_runtime_get_env EDGE_HTTP_DETECT_TIMEOUT_MS 2>/dev/null || echo "250")"
  tls80="$(edge_runtime_get_env EDGE_CLASSIC_TLS_ON_80 2>/dev/null || echo "true")"
  cert_file="$(edge_runtime_get_env EDGE_TLS_CERT_FILE 2>/dev/null || echo "/opt/cert/fullchain.pem")"
  key_file="$(edge_runtime_get_env EDGE_TLS_KEY_FILE 2>/dev/null || echo "/opt/cert/privkey.pem")"
  echo "Provider        : ${provider}"
  echo "Runtime Active  : ${active}"
  echo "Public HTTP     : $(edge_runtime_ports_label "${http_ports}")"
  echo "Public TLS      : $(edge_runtime_ports_label "${tls_ports}")"
  echo "Nginx HTTP      : ${http_backend}"
  if [[ "${provider}" == "nginx-stream" && "${active}" == "true" ]]; then
    echo "Nginx HTTPS     : ${http_tls_backend}"
  else
    echo "Nginx HTTPS     : ${http_tls_backend} (nginx-stream only)"
  fi
  echo "Xray Direct     : ${xray_direct_backend}"
  echo "Xray TLS        : ${xray_tls_backend}"
  echo "Xray WS         : ${xray_ws_backend}"
  echo "Detect Timeout  : ${detect_timeout} ms"
  echo "Classic TLS :80 : ${tls80}"
  echo "TLS Cert        : ${cert_file}"
  echo "TLS Key         : ${key_file}"
  hr
  echo "Mode ringkas:"
  if [[ "${provider}" == "nginx-stream" && "${active}" == "true" ]]; then
    echo "  - HTTP ingress -> backend HTTP (${http_backend})"
    echo "  - TLS ingress -> backend HTTPS (${http_tls_backend})"
  else
    echo "  - edge-go pegang port publik 80/443"
    echo "  - nginx route path Xray di backend HTTP (${http_backend})"
  fi
  echo "  - edge gateway aktif pada seluruh port Cloudflare HTTP/HTTPS yang didukung"
  hr
  pause
}

daemon_restart_confirm_one() {
  local svc="${1:-}"
  local label="${2:-${svc}}"
  [[ -n "${svc}" ]] || return 1
  if ! svc_exists "${svc}"; then
    warn "${label} tidak terpasang"
    return 1
  fi
  if ! confirm_menu_apply_now "Restart ${label} sekarang?"; then
    return 2
  fi
  if ! svc_restart "${svc}"; then
    warn "Restart ${label} gagal."
    return 1
  fi
  return 0
}

daemon_restart_confirm_many() {
  local prompt="${1:-}"
  local warn_msg="${2:-Sebagian service gagal direstart.}"
  shift 2 || true
  local svc restart_failed="false"

  if ! confirm_menu_apply_now "${prompt}"; then
    return 2
  fi

  for svc in "$@"; do
    if svc_exists "${svc}"; then
      if ! svc_restart "${svc}"; then
        restart_failed="true"
      fi
    else
      warn "${svc} tidak terpasang, skip"
    fi
  done
  if [[ "${restart_failed}" == "true" ]]; then
    warn "${warn_msg}"
    return 1
  fi
  return 0
}

xray_daemon_post_restart_health_check() {
  local svc
  if ! svc_exists xray || ! svc_is_active xray; then
    warn "xray belum active setelah restart daemon terkait."
    return 1
  fi
  for svc in "$@"; do
    [[ -n "${svc}" ]] || continue
    if svc_exists "${svc}" && ! svc_is_active "${svc}"; then
      warn "Daemon ${svc} belum active setelah restart."
      return 1
    fi
  done
  return 0
}

xray_daemon_restart_checked() {
  local svc restarted="false"
  local -a failed=()
  for svc in "$@"; do
    [[ -n "${svc}" ]] || continue
    if svc_exists "${svc}"; then
      if svc_restart_checked "${svc}" 60; then
        restarted="true"
      else
        failed+=("${svc}")
      fi
    else
      warn "${svc} tidak terpasang, skip"
    fi
  done
  if [[ "${restarted}" != "true" ]]; then
    warn "Tidak ada daemon Xray yang bisa direstart."
    return 1
  fi
  if (( ${#failed[@]} > 0 )); then
    warn "Gagal restart daemon Xray: ${failed[*]}"
    return 1
  fi
  xray_daemon_post_restart_health_check "$@" || return 1
  return 0
}

daemon_status_menu() {
  title
  echo "7) Maintenance > Xray Daemons"
  hr

  local daemons=(
    "xray" "nginx" "xray-expired" "xray-quota" "xray-limit-ip" "xray-speed" "wireproxy"
  )
  local d
  for d in "${daemons[@]}"; do
    if svc_exists "${d}"; then
      svc_status_line "${d}"
    else
      echo "N/A  - ${d} (not installed)"
    fi
  done
  hr

  echo "Info: daemon logs disembunyikan agar ringkas."
  hr

  echo "  1) Restart xray-expired"
  echo "  2) Restart xray-quota"
  echo "  3) Restart xray-limit-ip"
  echo "  4) Restart xray-speed"
  echo "  5) Restart All Xray Daemons"
  echo "  6) xray-expired Logs"
  echo "  7) xray-quota Logs"
  echo "  8) xray-limit-ip Logs"
  echo "  9) xray-speed Logs"
  echo "  0) Back"
  hr
  if ! read -r -p "Pilih: " c; then
    echo
    return 0
  fi
  case "${c}" in
    1)
      if confirm_menu_apply_now "Restart xray-expired sekarang?"; then
        xray_daemon_restart_checked xray-expired || true
      fi
      pause
      ;;
    2)
      if confirm_menu_apply_now "Restart xray-quota sekarang?"; then
        xray_daemon_restart_checked xray-quota || true
      fi
      pause
      ;;
    3)
      if confirm_menu_apply_now "Restart xray-limit-ip sekarang?"; then
        xray_daemon_restart_checked xray-limit-ip || true
      fi
      pause
      ;;
    4)
      if confirm_menu_apply_now "Restart xray-speed sekarang?"; then
        xray_daemon_restart_checked xray-speed || true
      fi
      pause
      ;;
    5)
      if confirm_menu_apply_now "Restart semua daemon Xray sekarang?"; then
        if ! xray_daemon_restart_checked xray-expired xray-quota xray-limit-ip xray-speed; then
          pause
          return 1
        fi
      fi
      pause
      ;;
    6) daemon_log_tail_show xray-expired 20 ;;
    7) daemon_log_tail_show xray-quota 20 ;;
    8) daemon_log_tail_show xray-limit-ip 20 ;;
    9) daemon_log_tail_show xray-speed 20 ;;
    0|kembali|k|back|b) return 0 ;;
    *) warn "Pilihan tidak valid" ; sleep 1 ;;
  esac
}

# -------------------------
