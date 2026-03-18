# shellcheck shell=bash
# Traffic Analytics
# - Sumber data: metadata quota /opt/quota/{vless,vmess,trojan,ssh}/*.json
# - Menggunakan quota_used sebagai dasar traffic usage.
# -------------------------
traffic_analytics_dataset_build_to_file() {
  # args: output_json_file
  local out_file="$1"
  need_python3
  python3 - <<'PY' "${QUOTA_ROOT}" "${SSH_QUOTA_DIR}" "${out_file}" "${QUOTA_PROTO_DIRS[@]}"
import json
import os
import sys
from datetime import datetime, timezone

quota_root = sys.argv[1]
ssh_quota_dir = sys.argv[2]
out_file = sys.argv[3]
protos = [p.strip() for p in sys.argv[4:] if p.strip()]
if "ssh" not in protos:
  protos.append("ssh")

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

entries = []
proto_summary = {p: {"users": 0, "used_bytes": 0, "quota_bytes": 0} for p in protos}

for proto in protos:
  pdir = ssh_quota_dir if proto == "ssh" else os.path.join(quota_root, proto)
  if not os.path.isdir(pdir):
    continue

  chosen = {}
  for name in os.listdir(pdir):
    if not name.endswith(".json"):
      continue
    stem = name[:-5]
    uname = stem.split("@", 1)[0] if "@" in stem else stem
    key = uname.strip()
    if not key:
      continue
    has_at = "@" in stem
    prev = chosen.get(key)
    if prev is None or (has_at and not prev["has_at"]):
      chosen[key] = {"name": name, "has_at": has_at}

  for uname in sorted(chosen.keys(), key=lambda x: x.lower()):
    name = chosen[uname]["name"]
    path = os.path.join(pdir, name)
    try:
      with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
      if not isinstance(data, dict):
        data = {}
    except Exception:
      data = {}

    username = str(data.get("username") or uname).strip() or uname
    used_bytes = to_int(data.get("quota_used"), 0)
    quota_bytes = to_int(data.get("quota_limit"), 0)
    if used_bytes < 0:
      used_bytes = 0
    if quota_bytes < 0:
      quota_bytes = 0
    expired_at = str(data.get("expired_at") or "-")

    entry = {
      "username": username,
      "proto": proto,
      "used_bytes": used_bytes,
      "quota_bytes": quota_bytes,
      "expired_at": expired_at,
      "source_file": path,
    }
    entries.append(entry)

    proto_summary[proto]["users"] += 1
    proto_summary[proto]["used_bytes"] += used_bytes
    proto_summary[proto]["quota_bytes"] += quota_bytes

entries.sort(key=lambda x: (-int(x["used_bytes"]), str(x["username"]).lower(), str(x["proto"]).lower()))

total_users = len(entries)
total_used_bytes = sum(int(e["used_bytes"]) for e in entries)
total_quota_bytes = sum(int(e["quota_bytes"]) for e in entries)

payload = {
  "generated_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M"),
  "quota_root": quota_root,
  "total_users": total_users,
  "total_used_bytes": total_used_bytes,
  "total_quota_bytes": total_quota_bytes,
  "protocols": proto_summary,
  "top_users": entries,
}

tmp = f"{out_file}.tmp.{os.getpid()}"
with open(tmp, "w", encoding="utf-8") as f:
  json.dump(payload, f, ensure_ascii=False, indent=2)
  f.write("\n")
  f.flush()
  os.fsync(f.fileno())
os.replace(tmp, out_file)
print(out_file)
PY
}

traffic_analytics_dataset_make_tmp() {
  local tmp
  tmp="$(mktemp "${WORK_DIR}/traffic-analytics.XXXXXX.json")" || die "Gagal membuat file dataset analytics."
  if ! traffic_analytics_dataset_build_to_file "${tmp}" >/dev/null; then
    rm -f "${tmp}" >/dev/null 2>&1 || true
    return 1
  fi
  echo "${tmp}"
}

traffic_analytics_overview_show() {
  title
  echo "10) Traffic > Overview"
  hr

  local dataset
  if ! dataset="$(traffic_analytics_dataset_make_tmp)"; then
    warn "Gagal membangun dataset traffic analytics."
    hr
    pause
    return 0
  fi

  need_python3
  python3 - <<'PY' "${dataset}"
import json
import sys

path = sys.argv[1]
try:
  data = json.load(open(path, "r", encoding="utf-8"))
except Exception:
  print("Dataset analytics tidak valid.")
  raise SystemExit(0)

def human_bytes(v):
  try:
    n = int(v)
  except Exception:
    n = 0
  if n >= 1024**4:
    return f"{n/(1024**4):.2f} TiB"
  if n >= 1024**3:
    return f"{n/(1024**3):.2f} GiB"
  if n >= 1024**2:
    return f"{n/(1024**2):.2f} MiB"
  if n >= 1024:
    return f"{n/1024:.2f} KiB"
  return f"{n} B"

generated = data.get("generated_at_utc") or "-"
total_users = int(data.get("total_users") or 0)
total_used = int(data.get("total_used_bytes") or 0)
total_quota = int(data.get("total_quota_bytes") or 0)
avg_used = int(total_used / total_users) if total_users > 0 else 0

print(f"Generated UTC : {generated}")
print(f"Total Users   : {total_users}")
print(f"Total Used    : {human_bytes(total_used)}")
print(f"Total Quota   : {human_bytes(total_quota)}")
print(f"Avg/User Used : {human_bytes(avg_used)}")
print()
print("By Protocol:")

protocols = data.get("protocols") or {}
for proto in ("vless", "vmess", "trojan", "ssh"):
  info = protocols.get(proto) or {}
  users = int(info.get("users") or 0)
  used = int(info.get("used_bytes") or 0)
  quota = int(info.get("quota_bytes") or 0)
  print(f"  {proto.upper():<6} users={users:<4} used={human_bytes(used):<12} quota={human_bytes(quota)}")

print()
print("Top 5 Users:")
top = (data.get("top_users") or [])[:5]
if not top:
  print("  (kosong)")
else:
  for i, row in enumerate(top, start=1):
    user = str(row.get("username") or "-")
    proto = str(row.get("proto") or "-").upper()
    used = human_bytes(row.get("used_bytes") or 0)
    print(f"  {i:>2}. {user:<20} {proto:<6} {used}")
PY

  rm -f "${dataset}" >/dev/null 2>&1 || true
  hr
  pause
}

traffic_analytics_top_users_show() {
  title
  echo "10) Traffic > Top Users by Usage"
  hr

  local n
  if ! read -r -p "Tampilkan top berapa user? (default 15, max 200, atau kembali): " n; then
    echo
    return 0
  fi
  if is_back_choice "${n}"; then
    return 0
  fi
  if [[ -z "${n}" ]]; then
    n=15
  fi
  [[ "${n}" =~ ^[0-9]+$ ]] || { warn "Input harus angka."; hr; pause; return 0; }
  if (( n < 1 )); then n=1; fi
  if (( n > 200 )); then n=200; fi

  local dataset
  if ! dataset="$(traffic_analytics_dataset_make_tmp)"; then
    warn "Gagal membangun dataset traffic analytics."
    hr
    pause
    return 0
  fi

  need_python3
  python3 - <<'PY' "${dataset}" "${n}"
import json
import sys

path, top_n = sys.argv[1], int(sys.argv[2])
try:
  data = json.load(open(path, "r", encoding="utf-8"))
except Exception:
  print("Dataset analytics tidak valid.")
  raise SystemExit(0)

def human_bytes(v):
  try:
    n = int(v)
  except Exception:
    n = 0
  if n >= 1024**4:
    return f"{n/(1024**4):.2f} TiB"
  if n >= 1024**3:
    return f"{n/(1024**3):.2f} GiB"
  if n >= 1024**2:
    return f"{n/(1024**2):.2f} MiB"
  if n >= 1024:
    return f"{n/1024:.2f} KiB"
  return f"{n} B"

rows = (data.get("top_users") or [])[:top_n]
if not rows:
  print("Belum ada data traffic user.")
  raise SystemExit(0)

print(f"{'NO':<4} {'PROTO':<8} {'USERNAME':<20} {'USED':<12} {'QUOTA':<12} {'USE%':>6} {'EXPIRED':<10}")
print(f"{'-'*4:<4} {'-'*8:<8} {'-'*20:<20} {'-'*12:<12} {'-'*12:<12} {'-'*6:>6} {'-'*10:<10}")
for i, row in enumerate(rows, start=1):
  proto = str(row.get("proto") or "-").upper()
  user = str(row.get("username") or "-")
  used = int(row.get("used_bytes") or 0)
  quota = int(row.get("quota_bytes") or 0)
  exp = str(row.get("expired_at") or "-")[:10]
  if quota > 0:
    pct = f"{(used * 100.0 / quota):.1f}"
  else:
    pct = "-"
  print(f"{i:<4} {proto:<8} {user[:20]:<20} {human_bytes(used):<12} {human_bytes(quota):<12} {pct:>6} {exp:<10}")
PY

  rm -f "${dataset}" >/dev/null 2>&1 || true
  hr
  pause
}

traffic_analytics_search_user_show() {
  title
  echo "10) Traffic > Search User Traffic"
  hr

  local q
  if ! read -r -p "Cari username/proto (atau kembali): " q; then
    echo
    return 0
  fi
  if is_back_choice "${q}"; then
    return 0
  fi
  q="$(echo "${q}" | awk '{$1=$1;print}')"
  [[ -n "${q}" ]] || { warn "Keyword kosong."; hr; pause; return 0; }

  local dataset
  if ! dataset="$(traffic_analytics_dataset_make_tmp)"; then
    warn "Gagal membangun dataset traffic analytics."
    hr
    pause
    return 0
  fi

  need_python3
  python3 - <<'PY' "${dataset}" "${q}"
import json
import sys

path, query = sys.argv[1], sys.argv[2].strip().lower()
try:
  data = json.load(open(path, "r", encoding="utf-8"))
except Exception:
  print("Dataset analytics tidak valid.")
  raise SystemExit(0)

def human_bytes(v):
  try:
    n = int(v)
  except Exception:
    n = 0
  if n >= 1024**4:
    return f"{n/(1024**4):.2f} TiB"
  if n >= 1024**3:
    return f"{n/(1024**3):.2f} GiB"
  if n >= 1024**2:
    return f"{n/(1024**2):.2f} MiB"
  if n >= 1024:
    return f"{n/1024:.2f} KiB"
  return f"{n} B"

rows = []
for row in (data.get("top_users") or []):
  username = str(row.get("username") or "")
  proto = str(row.get("proto") or "")
  token = f"{username}@{proto}".lower()
  if query in token:
    rows.append(row)

if not rows:
  print("Tidak ada user yang cocok dengan keyword.")
  raise SystemExit(0)

print(f"Ditemukan {len(rows)} user.")
print(f"{'NO':<4} {'PROTO':<8} {'USERNAME':<20} {'USED':<12} {'QUOTA':<12} {'USE%':>6} {'EXPIRED':<10}")
print(f"{'-'*4:<4} {'-'*8:<8} {'-'*20:<20} {'-'*12:<12} {'-'*12:<12} {'-'*6:>6} {'-'*10:<10}")
for i, row in enumerate(rows[:200], start=1):
  proto = str(row.get("proto") or "-").upper()
  user = str(row.get("username") or "-")
  used = int(row.get("used_bytes") or 0)
  quota = int(row.get("quota_bytes") or 0)
  exp = str(row.get("expired_at") or "-")[:10]
  if quota > 0:
    pct = f"{(used * 100.0 / quota):.1f}"
  else:
    pct = "-"
  print(f"{i:<4} {proto:<8} {user[:20]:<20} {human_bytes(used):<12} {human_bytes(quota):<12} {pct:>6} {exp:<10}")
PY

  rm -f "${dataset}" >/dev/null 2>&1 || true
  hr
  pause
}

traffic_analytics_export_json() {
  title
  echo "10) Traffic > Export JSON"
  hr

  local dataset out
  if ! dataset="$(traffic_analytics_dataset_make_tmp)"; then
    warn "Gagal membangun dataset traffic analytics."
    hr
    pause
    return 0
  fi

  out="${REPORT_DIR}/traffic-analytics-$(date +%Y%m%d-%H%M%S).json"
  if cp -f "${dataset}" "${out}"; then
    chmod 600 "${out}" >/dev/null 2>&1 || true
    log "Report tersimpan: ${out}"
  else
    warn "Gagal menyimpan report ke: ${out}"
  fi

  rm -f "${dataset}" >/dev/null 2>&1 || true
  hr
  pause
}

traffic_analytics_menu() {
  local -a items=(
    "1|Overview"
    "2|Top Users"
    "3|Search User"
    "4|Export JSON"
    "0|Back"
  )
  while true; do
    ui_menu_screen_begin "10) Traffic"
    ui_menu_render_options items 76
    hr
    if ! read -r -p "Pilih: " c; then
      echo
      break
    fi
    case "${c}" in
      1) traffic_analytics_overview_show ;;
      2) traffic_analytics_top_users_show ;;
      3) traffic_analytics_search_user_show ;;
      4) traffic_analytics_export_json ;;
      0|kembali|k|back|b) break ;;
      *) warn "Pilihan tidak valid" ; sleep 1 ;;
    esac
  done
}

# -------------------------
# Security
# - TLS & Cert
# - Fail2ban
# - Hardening
# - Overview
# -------------------------
cert_openssl_info() {
  if ! have_cmd openssl; then
    warn "openssl tidak tersedia"
    return 1
  fi
  if [[ ! -f "${CERT_FULLCHAIN}" ]]; then
    warn "Cert tidak ditemukan: ${CERT_FULLCHAIN}"
    return 1
  fi
  openssl x509 -in "${CERT_FULLCHAIN}" -noout     -subject -issuer -serial -startdate -enddate -fingerprint 2>/dev/null || return 1
  return 0
}

cert_expiry_days_left() {
  # prints integer days left, or empty on error
  if ! have_cmd openssl; then
    echo ""
    return 0
  fi
  if [[ ! -f "${CERT_FULLCHAIN}" ]]; then
    echo ""
    return 0
  fi

  local end end_ts cur_ts diff
  end="$(openssl x509 -in "${CERT_FULLCHAIN}" -noout -enddate 2>/dev/null | sed -e 's/^notAfter=//' || true)"
  if [[ -z "${end}" ]]; then
    echo ""
    return 0
  fi

  end_ts="$(date -d "${end}" +%s 2>/dev/null || true)"
  cur_ts="$(date +%s 2>/dev/null || true)"
  if [[ -z "${end_ts}" || -z "${cur_ts}" ]]; then
    echo ""
    return 0
  fi
  diff=$(( (end_ts - cur_ts) / 86400 ))
  echo "${diff}"
}

cert_menu_show_info() {
  title
  echo "TLS & Cert > Cert Info"
  hr
  if ! cert_openssl_info; then
    warn "Gagal membaca info sertifikat"
  fi
  hr
  pause
}

cert_menu_check_expiry() {
  title
  echo "TLS & Cert > Check Expiry"
  hr
  local days
  days="$(cert_expiry_days_left)"
  if [[ -z "${days}" ]]; then
    warn "Tidak dapat menghitung masa berlaku TLS"
  else
    if (( days < 0 )); then
      echo "TLS Expiry : Expired"
    else
      echo "TLS Expiry : ${days} days"
    fi
  fi
  hr
  pause
}

acme_sh_path_get() {
  if [[ -x "/root/.acme.sh/acme.sh" ]]; then
    echo "/root/.acme.sh/acme.sh"
    return 0
  fi
  if have_cmd acme.sh; then
    command -v acme.sh
    return 0
  fi
  echo ""
}

cert_runtime_restart_active_tls_consumers() {
  if [[ "${DOMAIN_CTRL_RUNTIME_SNAPSHOT_VALID:-0}" == "1" ]]; then
    domain_control_restore_tls_runtime_consumers_from_snapshot || return $?
    cert_runtime_tls_consumers_health_check || return 1
    return 0
  fi
  local edge_svc=""
  if svc_exists sshws-stunnel && svc_is_active sshws-stunnel; then
    systemctl restart sshws-stunnel >/dev/null 2>&1 || return 1
    svc_is_active sshws-stunnel || return 1
  fi
  if edge_runtime_enabled_for_public_ports; then
    edge_svc="$(edge_runtime_service_name 2>/dev/null || true)"
    if [[ -n "${edge_svc}" && "${edge_svc}" != "nginx" ]] && svc_exists "${edge_svc}" && svc_is_active "${edge_svc}"; then
      edge_runtime_post_restart_health_check || return 1
    fi
  fi
  cert_runtime_tls_consumers_health_check || return 1
  return 0
}

cert_runtime_tls_consumers_health_check() {
  local -a failed=()
  local stunnel_port="" stunnel_probe="" edge_svc="" http_port="" tls_port=""

  if svc_exists sshws-stunnel && svc_is_active sshws-stunnel; then
    stunnel_port="$(sshws_detect_stunnel_port 2>/dev/null || true)"
    if [[ "${stunnel_port}" =~ ^[0-9]+$ ]]; then
      stunnel_probe="$(sshws_probe_tcp_endpoint "127.0.0.1" "${stunnel_port}" "tls")"
      if ! sshws_probe_result_is_healthy "${stunnel_probe}"; then
        warn "Probe TLS consumer sshws-stunnel gagal: $(sshws_probe_result_disp "${stunnel_probe}")"
        failed+=("sshws-stunnel")
      fi
    fi
  fi

  if edge_runtime_enabled_for_public_ports; then
    edge_svc="$(edge_runtime_service_name 2>/dev/null || true)"
    if [[ -n "${edge_svc}" && "${edge_svc}" != "nginx" ]] && svc_exists "${edge_svc}" && svc_is_active "${edge_svc}"; then
      http_port="$(edge_runtime_get_env EDGE_PUBLIC_HTTP_PORT 2>/dev/null || echo "80")"
      tls_port="$(edge_runtime_get_env EDGE_PUBLIC_TLS_PORT 2>/dev/null || echo "443")"
      if ! edge_runtime_socket_listening "${http_port}"; then
        warn "Port HTTP publik ${http_port} belum listening setelah refresh consumer TLS."
        failed+=("edge-http")
      fi
      if ! edge_runtime_socket_listening "${tls_port}"; then
        warn "Port TLS publik ${tls_port} belum listening setelah refresh consumer TLS."
        failed+=("edge-tls")
      fi
    fi
  fi

  (( ${#failed[@]} == 0 ))
}

cert_runtime_hostname_tls_handshake_check() {
  local domain="${1:-}"
  local probe_output="" rc=0 endpoint="" label=""

  [[ -n "${domain}" ]] || domain="$(detect_domain)"
  [[ -n "${domain}" ]] || {
    warn "Domain aktif tidak terdeteksi untuk probe TLS hostname."
    return 1
  }
  if ! have_cmd openssl; then
    warn "openssl tidak tersedia, skip probe TLS hostname ${domain}."
    return 0
  fi

  for endpoint in "${domain}:443" "127.0.0.1:443"; do
    if [[ "${endpoint}" == "${domain}:443" ]]; then
      label="public"
    else
      label="local"
    fi
    if have_cmd timeout; then
      probe_output="$(timeout 15 openssl s_client -servername "${domain}" -connect "${endpoint}" -verify_hostname "${domain}" -verify_return_error < /dev/null 2>&1)"
      rc=$?
    else
      probe_output="$(openssl s_client -servername "${domain}" -connect "${endpoint}" -verify_hostname "${domain}" -verify_return_error < /dev/null 2>&1)"
      rc=$?
    fi
    if (( rc != 0 )) || ! printf '%s\n' "${probe_output}" | grep -Eq 'Verification: OK|Verify return code: 0 \(ok\)'; then
      warn "Probe TLS hostname ${label} gagal untuk ${domain} via ${endpoint}."
      printf '%s\n' "${probe_output}" >&2
      return 1
    fi
  done
  return 0
}

cert_menu_renew() {
  title
  echo "TLS & Cert > Renew Certificate"
  hr

  local acme
  acme="$(acme_sh_path_get)"
  if [[ -z "${acme}" ]]; then
    warn "acme.sh tidak ditemukan. Pastikan setup.sh sudah memasang acme.sh."
    hr
    pause
    return 0
  fi

  export PATH="/root/.acme.sh:${PATH}"
  local domain
  domain="$(detect_domain)"
  if [[ -z "${domain}" ]]; then
    warn "Domain aktif tidak terdeteksi."
    hr
    pause
    return 0
  fi
  if ! cert_renew_service_recover_if_needed; then
    hr
    pause
    return 1
  fi
  if [[ -s "${CERT_RENEW_CERT_JOURNAL_FILE}" ]]; then
    warn "Terdapat recovery rollback cert renew yang tertunda. Gunakan menu 'Recover Pending Renew' sebelum renew ulang."
    hr
    pause
    return 1
  fi

  echo "Domain terdeteksi: ${domain}"
  echo "Catatan       : bila port 80 bentrok, renew sekarang fail-closed dan tidak menghentikan service publik otomatis."
  hr
  if ! cert_runtime_hostname_tls_handshake_check "${domain}" >/dev/null 2>&1; then
    warn "Runtime TLS hostname untuk ${domain} belum sehat sebelum renew."
    warn "Renew dibatalkan agar perubahan cert baru tidak diterapkan di atas baseline runtime yang sudah bermasalah."
    warn "Perbaiki dulu runtime TLS atau jalankan 'Recover Pending Renew' bila memang ada recovery tertunda."
    hr
    pause
    return 1
  fi
  if ! confirm_menu_apply_now "Jalankan renew certificate untuk domain ${domain} sekarang?"; then
    hr
    pause
    return 0
  fi
  local renew_ack=""
  read -r -p "Ketik persis 'RENEW CERT ${domain}' untuk lanjut renew certificate (atau kembali): " renew_ack
  if is_back_choice "${renew_ack}"; then
    warn "Renew certificate dibatalkan pada checkpoint final."
    hr
    pause
    return 0
  fi
  if [[ "${renew_ack}" != "RENEW CERT ${domain}" ]]; then
    warn "Konfirmasi renew certificate tidak cocok. Dibatalkan."
    hr
    pause
    return 0
  fi
  echo "Menjalankan acme.sh renew untuk domain aktif..."
  echo

  local renew_ok="false"
  local port80_conflict="false"
  local renew_log
  local cert_backup_dir=""
  local -a rollback_notes=()
  local -a conflict_services=()
  renew_log="$(mktemp)"

  domain_control_clear_stopped_services
  domain_control_capture_runtime_snapshot
  cert_backup_dir="${WORK_DIR}/cert-renew-snapshot.$(date +%s).$$"
  if ! acme_install_targets_pin_live "${domain}" "${CERT_FULLCHAIN}" "${CERT_PRIVKEY}"; then
    warn "Gagal menyelaraskan target install acme.sh ke path cert live sebelum renew."
    rm -f "${renew_log}" >/dev/null 2>&1 || true
    rm -rf "${cert_backup_dir}" >/dev/null 2>&1 || true
    domain_control_clear_runtime_snapshot
    hr
    pause
    return 1
  fi
  if ! cert_snapshot_create "${cert_backup_dir}"; then
    warn "Gagal membuat snapshot sertifikat sebelum renew."
    rm -f "${renew_log}" >/dev/null 2>&1 || true
    domain_control_clear_runtime_snapshot
    hr
    pause
    return 1
  fi

  if "${acme}" --renew -d "${domain}" --force 2>&1 | tee "${renew_log}"; then
    renew_ok="true"
  else
    if grep -Eqi "port 80 is already used|Please stop it first" "${renew_log}"; then
      port80_conflict="true"
    fi
  fi
  rm -f "${renew_log}" >/dev/null 2>&1 || true

  if [[ "${renew_ok}" != "true" ]]; then
    if [[ "${port80_conflict}" == "true" ]]; then
      local svc edge_svc=""
      for svc in nginx apache2 caddy lighttpd; do
        if svc_exists "${svc}" && svc_is_active "${svc}"; then
          conflict_services+=("${svc}")
        fi
      done
      if edge_runtime_enabled_for_public_ports; then
        edge_svc="$(edge_runtime_service_name 2>/dev/null || true)"
        if [[ -n "${edge_svc}" && "${edge_svc}" != "nginx" ]] && svc_exists "${edge_svc}" && svc_is_active "${edge_svc}"; then
          conflict_services+=("${edge_svc}")
        fi
      fi
      warn "Terdeteksi konflik port 80. Renew certificate sekarang fail-closed dan tidak lagi menghentikan service publik otomatis."
      if (( ${#conflict_services[@]} > 0 )); then
        printf 'Service aktif yang memakai port 80: %s\n' "$(IFS=', '; echo "${conflict_services[*]}")"
      fi
      warn "Bebaskan port 80 secara manual lalu jalankan renew lagi."
      rm -rf "${cert_backup_dir}" >/dev/null 2>&1 || true
      domain_control_clear_stopped_services
      cert_renew_service_journal_clear
      domain_control_clear_runtime_snapshot
      hr
      pause
      return 1
    else
      warn "acme.sh renew domain aktif gagal."
    fi
  fi

  if [[ "${renew_ok}" != "true" ]]; then
    warn "Renew gagal. Cek output di atas."
    rm -rf "${cert_backup_dir}" >/dev/null 2>&1 || true
    domain_control_clear_stopped_services
    cert_renew_service_journal_clear
    domain_control_clear_runtime_snapshot
    hr
    pause
    return 1
  fi

  echo
  if ! cert_runtime_restart_active_tls_consumers; then
    warn "Restart consumer TLS tambahan gagal. Mencoba retry sekali lagi sebelum rollback cert..."
    sleep 2
  fi
  if ! cert_runtime_restart_active_tls_consumers; then
    warn "Cert berhasil diperbarui, tetapi restart consumer TLS tambahan gagal. Mencoba rollback cert sebelumnya..."
    cert_snapshot_restore "${cert_backup_dir}" >/dev/null 2>&1 || rollback_notes+=("restore sertifikat gagal")
    domain_control_restore_cert_runtime_after_rollback rollback_notes || true
    if (( ${#rollback_notes[@]} > 0 )); then
      warn "Rollback cert juga bermasalah: ${rollback_notes[*]}"
      if cert_renew_cert_journal_write "${domain}" "${cert_backup_dir}"; then
        warn "Journal recovery rollback cert disimpan. Gunakan menu 'Recover Pending Renew' untuk melanjutkan."
        cert_backup_dir=""
      else
        warn "Gagal menyimpan journal recovery rollback cert. Snapshot cert dipertahankan di ${cert_backup_dir}."
      fi
      if cert_renew_cert_recover_if_needed >/dev/null 2>&1; then
        log "Rollback cert berhasil diselesaikan langsung pada flow renew ini."
        warn "Renew cert dibatalkan, tetapi runtime TLS sudah dipulihkan kembali."
      fi
    else
      cert_renew_cert_journal_clear
      log "Runtime TLS berhasil dipulihkan ke snapshot cert sebelumnya."
    fi
    [[ -n "${cert_backup_dir}" ]] && rm -rf "${cert_backup_dir}" >/dev/null 2>&1 || true
    domain_control_clear_stopped_services
    domain_control_clear_runtime_snapshot
    hr
    pause
    return 1
  fi
  if ! cert_runtime_hostname_tls_handshake_check "${domain}"; then
    warn "Probe TLS hostname gagal. Mencoba retry sekali lagi sebelum rollback cert..."
    sleep 2
  fi
  if ! cert_runtime_hostname_tls_handshake_check "${domain}"; then
    warn "Cert berhasil diperbarui, tetapi probe TLS hostname gagal. Mencoba rollback cert sebelumnya..."
    cert_snapshot_restore "${cert_backup_dir}" >/dev/null 2>&1 || rollback_notes+=("restore sertifikat gagal")
    domain_control_restore_cert_runtime_after_rollback rollback_notes || true
    if (( ${#rollback_notes[@]} > 0 )); then
      warn "Rollback cert juga bermasalah: ${rollback_notes[*]}"
      if cert_renew_cert_journal_write "${domain}" "${cert_backup_dir}"; then
        warn "Journal recovery rollback cert disimpan. Gunakan menu 'Recover Pending Renew' untuk melanjutkan."
        cert_backup_dir=""
      else
        warn "Gagal menyimpan journal recovery rollback cert. Snapshot cert dipertahankan di ${cert_backup_dir}."
      fi
      if cert_renew_cert_recover_if_needed >/dev/null 2>&1; then
        log "Rollback cert berhasil diselesaikan langsung pada flow renew ini."
        warn "Renew cert dibatalkan, tetapi runtime TLS sudah dipulihkan kembali."
      fi
    else
      cert_renew_cert_journal_clear
      log "Runtime TLS berhasil dipulihkan ke snapshot cert sebelumnya."
    fi
    [[ -n "${cert_backup_dir}" ]] && rm -rf "${cert_backup_dir}" >/dev/null 2>&1 || true
    domain_control_clear_stopped_services
    domain_control_clear_runtime_snapshot
    hr
    pause
    return 1
  fi
  rm -rf "${cert_backup_dir}" >/dev/null 2>&1 || true
  domain_control_clear_stopped_services
  cert_renew_service_journal_clear
  cert_renew_cert_journal_clear
  domain_control_clear_runtime_snapshot
  log "Renew certificate selesai (cek expiry untuk memastikan)."
  hr
  pause
}

cert_menu_reload_nginx() {
  title
  echo "TLS & Cert > Reload Nginx"
  hr
  if ! svc_exists nginx; then
    warn "nginx.service tidak terdeteksi"
    hr
    pause
    return 0
  fi

  if ! confirm_menu_apply_now "Reload nginx sekarang?"; then
    hr
    pause
    return 0
  fi

  if have_cmd nginx && ! nginx -t >/dev/null 2>&1; then
    warn "nginx -t gagal. Reload/restart dibatalkan."
    hr
    pause
    return 1
  fi

  if systemctl reload nginx 2>/dev/null && svc_is_active nginx && nginx_service_listener_health_check; then
    local domain=""
    domain="$(detect_domain 2>/dev/null || true)"
    if [[ -n "${domain}" ]] && ! cert_runtime_hostname_tls_handshake_check "${domain}"; then
      warn "nginx reload lolos, tetapi probe TLS hostname gagal."
      hr
      pause
      return 1
    fi
    log "nginx reload: OK"
  else
    warn "nginx reload gagal."
    if ! confirm_menu_apply_now "Reload gagal. Lanjutkan dengan restart penuh nginx sekarang?"; then
      hr
      pause
      return 1
    fi
    if have_cmd nginx && ! nginx -t >/dev/null 2>&1; then
      warn "nginx -t gagal sebelum restart fallback."
      hr
      pause
      return 1
    fi
    if nginx_restart_checked_with_listener; then
      local domain=""
      domain="$(detect_domain 2>/dev/null || true)"
      if [[ -n "${domain}" ]] && ! cert_runtime_hostname_tls_handshake_check "${domain}"; then
        warn "nginx restart lolos, tetapi probe TLS hostname gagal."
        hr
        pause
        return 1
      fi
      log "nginx restart: OK"
    else
      warn "nginx masih tidak aktif"
      hr
      pause
      return 1
    fi
  fi
  hr
  pause
}

security_tls_menu() {
  local pending_recovery="false"
  while true; do
    pending_recovery="false"
    [[ -s "${CERT_RENEW_SERVICE_JOURNAL_FILE}" ]] && pending_recovery="true"
    [[ -s "${CERT_RENEW_CERT_JOURNAL_FILE}" ]] && pending_recovery="true"
    title
    echo "TLS & Cert"
    if [[ "${pending_recovery}" == "true" ]]; then
      hr
      warn "Terdapat recovery renew yang tertunda. Gunakan menu 'Recover Pending Renew'."
    fi
    hr
    echo "  1) Cert Info"
    echo "  2) Check Expiry"
    echo "  3) Renew Cert"
    echo "  4) Reload Nginx"
    echo "  5) Recover Pending Renew"
    echo "  0) Back"
    hr
    if ! read -r -p "Pilih: " c; then
      echo
      break
    fi
    case "${c}" in
      1) cert_menu_show_info ;;
      2) cert_menu_check_expiry ;;
      3) cert_menu_renew ;;
      4) cert_menu_reload_nginx ;;
      5)
        local recover_failed="false"
        if ! cert_renew_service_recover_if_needed; then
          recover_failed="true"
        fi
        if ! cert_renew_cert_recover_if_needed; then
          recover_failed="true"
        fi
        if [[ "${recover_failed}" != "true" ]]; then
          log "Recovery renew selesai atau tidak ada journal tertunda."
        else
          warn "Recovery renew belum bersih."
        fi
        pending_recovery="false"
        [[ -s "${CERT_RENEW_SERVICE_JOURNAL_FILE}" ]] && pending_recovery="true"
        [[ -s "${CERT_RENEW_CERT_JOURNAL_FILE}" ]] && pending_recovery="true"
        pause
        ;;
      0|kembali|k|back|b) break ;;
      *) warn "Pilihan tidak valid" ; sleep 1 ;;
    esac
  done
}

fail2ban_client_ready() {
  if ! have_cmd fail2ban-client; then
    return 1
  fi
  return 0
}

fail2ban_jails_list_get() {
  # prints jail names one per line
  if ! fail2ban_client_ready; then
    return 0
  fi
  local out line
  out="$(fail2ban-client status 2>/dev/null || true)"
  [[ -n "${out}" ]] || return 0

  # Format output fail2ban bisa memakai prefix "|-" atau "`-" dan separator
  # setelah ":" bisa berupa spasi/tab, jadi parsing harus longgar.
  line="$(printf '%s\n' "${out}" | sed -nE 's/.*[Jj]ail list[[:space:]]*:[[:space:]]*//p' | head -n1)"
  line="${line//$'\r'/}"
  [[ -n "${line}" ]] || return 0

  printf '%s\n' "${line}" \
    | tr ',' '\n' \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
    | grep -E '.+' || true
}

fail2ban_jail_banned_counts_get() {
  # args: jail -> prints: current|total
  local jail="$1"
  if ! fail2ban_client_ready; then
    echo "0|0"
    return 0
  fi
  local out cur tot
  out="$(fail2ban-client status "${jail}" 2>/dev/null || true)"
  # Output fail2ban bisa memakai tab/spasi campuran setelah ":".
  # Parsing dibuat longgar agar "Currently banned" dan "Total banned" selalu terbaca.
  cur="$(printf '%s\n' "${out}" | sed -nE 's/.*Currently banned:[[:space:]]*([0-9]+).*/\1/p' | head -n1)"
  tot="$(printf '%s\n' "${out}" | sed -nE 's/.*Total banned:[[:space:]]*([0-9]+).*/\1/p' | head -n1)"
  [[ -n "${cur}" ]] || cur="0"
  [[ -n "${tot}" ]] || tot="0"
  echo "${cur}|${tot}"
}

fail2ban_total_banned_get() {
  if ! fail2ban_client_ready; then
    echo "0"
    return 0
  fi
  local total=0 jail counts cur
  while IFS= read -r jail; do
    counts="$(fail2ban_jail_banned_counts_get "${jail}")"
    cur="${counts%%|*}"
    [[ "${cur}" =~ ^[0-9]+$ ]] || cur=0
    total=$((total + cur))
  done < <(fail2ban_jails_list_get)
  echo "${total}"
}

fail2ban_menu_show_jail_status() {
  title
  echo "Fail2ban > Jail Status"
  hr

  if ! svc_exists fail2ban; then
    warn "fail2ban.service tidak terdeteksi"
  fi

  if ! fail2ban_client_ready; then
    warn "fail2ban-client tidak tersedia"
    hr
    pause
    return 0
  fi

  fail2ban-client status 2>/dev/null || true
  hr

  local jails=()
  while IFS= read -r j; do
    [[ -n "${j}" ]] && jails+=("${j}")
  done < <(fail2ban_jails_list_get)

  if (( ${#jails[@]} == 0 )); then
    warn "Tidak ada jail yang terdeteksi."
    hr
    pause
    return 0
  fi

  printf "%-30s %-12s %-12s\n" "JAIL" "BANNED" "TOTAL"
  printf "%-30s %-12s %-12s\n" "------------------------------" "------------" "------------"
  local jail counts cur tot
  for jail in "${jails[@]}"; do
    counts="$(fail2ban_jail_banned_counts_get "${jail}")"
    cur="${counts%%|*}"
    tot="${counts##*|}"
    printf "%-30s %-12s %-12s\n" "${jail}" "${cur}" "${tot}"
  done
  hr
  pause
}

fail2ban_menu_show_banned_ip() {
  title
  echo "Fail2ban > Banned IP"
  hr
  if ! fail2ban_client_ready; then
    warn "fail2ban-client tidak tersedia"
    hr
    pause
    return 0
  fi

  local jails=()
  while IFS= read -r j; do
    [[ -n "${j}" ]] && jails+=("${j}")
  done < <(fail2ban_jails_list_get)

  if (( ${#jails[@]} == 0 )); then
    warn "Tidak ada jail yang terdeteksi."
    hr
    pause
    return 0
  fi

  local jail ips
  for jail in "${jails[@]}"; do
    echo "[${jail}]"
    ips="$(fail2ban-client get "${jail}" banip 2>/dev/null || true)"
    if [[ -z "${ips}" ]]; then
      echo "  (kosong)"
    else
      echo "${ips}" | tr ' ' '\n' | sed -E 's/^/  - /'
    fi
    echo
  done
  hr
  pause
}

fail2ban_menu_unban_ip() {
  title
  echo "Fail2ban > Unban IP"
  hr
  if ! fail2ban_client_ready; then
    warn "fail2ban-client tidak tersedia"
    hr
    pause
    return 0
  fi

  local jails=()
  while IFS= read -r j; do
    [[ -n "${j}" ]] && jails+=("${j}")
  done < <(fail2ban_jails_list_get)

  if (( ${#jails[@]} == 0 )); then
    warn "Tidak ada jail yang terdeteksi."
    hr
    pause
    return 0
  fi

  echo "Daftar jail:"
  local i
  for i in "${!jails[@]}"; do
    printf "  %d) %s\n" "$((i + 1))" "${jails[$i]}"
  done
  echo "  0) Back"
  hr

  if ! read -r -p "Pilih jail (1-${#jails[@]}/0): " c; then
    echo
    return 0
  fi
  if is_back_choice "${c}"; then
    return 0
  fi
  [[ "${c}" =~ ^[0-9]+$ ]] || { warn "Input bukan angka"; pause; return 0; }
  if (( c < 1 || c > ${#jails[@]} )); then
    warn "Pilihan jail di luar range"
    pause
    return 0
  fi
  local jail
  jail="${jails[$((c - 1))]}"

  if ! read -r -p "IP yang ingin di-unban (atau kembali): " ip; then
    echo
    return 0
  fi
  if is_back_choice "${ip}"; then
    return 0
  fi
  ip="$(ip_literal_normalize "${ip}")" || {
    warn "IP tidak valid. Gunakan IPv4/IPv6 literal."
    pause
    return 0
  }

  if ! confirm_menu_apply_now "Unban IP ${ip} dari jail ${jail} sekarang?"; then
    pause
    return 0
  fi

  if fail2ban-client set "${jail}" unbanip "${ip}" 2>/dev/null; then
    log "Unban sukses: ${ip} (${jail})"
  else
    warn "Unban gagal. Pastikan jail & IP valid."
  fi
  hr
  pause
}

fail2ban_post_restart_health_check() {
  local jail
  local -a expected_jails=("$@")
  local status_out=""

  if ! svc_restart_checked fail2ban 20; then
    warn "fail2ban gagal direstart (state=$(svc_state fail2ban || echo unknown))"
    return 1
  fi
  if ! fail2ban_client_ready; then
    warn "fail2ban-client tidak tersedia setelah restart."
    return 1
  fi
  status_out="$(fail2ban-client status 2>/dev/null || true)"
  if [[ -z "${status_out}" ]]; then
    warn "fail2ban-client status kosong setelah restart."
    return 1
  fi
  for jail in "${expected_jails[@]}"; do
    [[ -n "${jail}" ]] || continue
    if ! fail2ban_jail_active_bool "${jail}"; then
      warn "Jail fail2ban belum aktif setelah restart: ${jail}"
      return 1
    fi
  done
  return 0
}

fail2ban_menu_restart() {
  title
  echo "Fail2ban > Restart"
  hr
  local jail=""
  if ! svc_exists fail2ban; then
    warn "fail2ban.service tidak terdeteksi"
    hr
    pause
    return 0
  fi

  local jails=()
  while IFS= read -r jail; do
    [[ -n "${jail}" ]] && jails+=("${jail}")
  done < <(fail2ban_jails_list_get)

  if ! confirm_menu_apply_now "Restart fail2ban sekarang?"; then
    pause
    return 0
  fi

  if fail2ban_post_restart_health_check "${jails[@]}"; then
    log "fail2ban: active"
  else
    warn "fail2ban restart health-check gagal."
  fi
  hr
  pause
}

security_fail2ban_menu() {
  while true; do
    title
    echo "Fail2ban"
    hr
    echo "  1) Jail Status"
    echo "  2) Banned IP"
    echo "  3) Unban IP"
    echo "  4) Restart Fail2ban"
    echo "  0) Back"
    hr
    if ! read -r -p "Pilih: " c; then
      echo
      break
    fi
    case "${c}" in
      1) fail2ban_menu_show_jail_status ;;
      2) fail2ban_menu_show_banned_ip ;;
      3) fail2ban_menu_unban_ip ;;
      4) fail2ban_menu_restart ;;
      0|kembali|k|back|b) break ;;
      *) warn "Pilihan tidak valid" ; sleep 1 ;;
    esac
  done
}

hardening_check_bbr() {
  title
  echo "Hardening > BBR"
  hr
  if ! have_cmd sysctl; then
    warn "sysctl tidak tersedia"
    hr
    pause
    return 0
  fi

  local cc qdisc
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
  qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"

  echo "tcp_congestion_control : ${cc:-"-"}"
  echo "default_qdisc          : ${qdisc:-"-"}"
  echo
  if [[ "${cc}" == "bbr" ]]; then
    echo "BBR : Enabled"
  else
    echo "BBR : Disabled"
  fi
  hr
  pause
}

swap_status_pretty_get() {
  # prints: "<n>GB Active" or "Disabled"
  if ! have_cmd free; then
    echo "Unknown"
    return 0
  fi
  local bytes
  bytes="$(free -b 2>/dev/null | awk '/^Swap:/ {print $2; exit}' || true)"
  [[ -n "${bytes}" ]] || bytes="0"
  if [[ ! "${bytes}" =~ ^[0-9]+$ ]]; then
    bytes="0"
  fi
  if (( bytes <= 0 )); then
    echo "Disabled"
    return 0
  fi
  local gb
  gb=$(( (bytes + 1024**3 - 1) / (1024**3) ))
  echo "${gb}GB Active"
}

hardening_check_swap() {
  title
  echo "Hardening > Swap"
  hr
  if ! have_cmd free; then
    warn "free tidak tersedia"
    hr
    pause
    return 0
  fi

  free -h || true
  hr
  echo "Swap : $(swap_status_pretty_get)"
  hr
  pause
}

hardening_check_ulimit() {
  title
  echo "Hardening > Ulimit"
  hr
  local cur
  cur="$(ulimit -n 2>/dev/null || echo "-")"
  echo "Shell ulimit -n : ${cur}"
  echo
  if svc_exists xray; then
    local lim
    lim="$(systemctl show -p LimitNOFILE --value xray 2>/dev/null || true)"
    echo "xray LimitNOFILE: ${lim:-"-"}"
  fi
  hr
  pause
}

hardening_check_chrony() {
  title
  echo "Hardening > Chrony"
  hr
  if svc_exists chrony; then
    svc_status_line chrony
    hr
    systemctl status chrony --no-pager || true
  elif svc_exists chronyd; then
    svc_status_line chronyd
    hr
    systemctl status chronyd --no-pager || true
  else
    warn "chrony/chronyd service tidak terdeteksi"
  fi
  hr
  pause
}

security_hardening_menu() {
  while true; do
    title
    echo "Hardening"
    hr
    echo "  1) BBR"
    echo "  2) Swap"
    echo "  3) Ulimit"
    echo "  4) Chrony"
    echo "  0) Back"
    hr
    if ! read -r -p "Pilih: " c; then
      echo
      break
    fi
    case "${c}" in
      1) hardening_check_bbr ;;
      2) hardening_check_swap ;;
      3) hardening_check_ulimit ;;
      4) hardening_check_chrony ;;
      0|kembali|k|back|b) break ;;
      *) warn "Pilihan tidak valid" ; sleep 1 ;;
    esac
  done
}

bbr_enabled_bool() {
  if ! have_cmd sysctl; then
    return 1
  fi
  local cc
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
  [[ "${cc}" == "bbr" ]]
}

fail2ban_jail_active_bool() {
  # args: jail name
  local jail="$1"
  if ! fail2ban_client_ready; then
    return 1
  fi
  fail2ban-client status "${jail}" >/dev/null 2>&1
}

security_overview_menu() {
  title
  echo "Overview"
  hr

  local tls_days tls_line
  tls_days="$(cert_expiry_days_left)"
  if [[ -z "${tls_days}" ]]; then
    tls_line="-"
  else
    if (( tls_days < 0 )); then
      tls_line="Expired"
    else
      tls_line="${tls_days} days"
    fi
  fi

  local f2b_line banned ssh_line nginx_line rec_line
  if svc_is_active fail2ban 2>/dev/null; then
    f2b_line="Active"
  else
    f2b_line="Inactive"
  fi

  banned="$(fail2ban_total_banned_get)"
  [[ -n "${banned}" ]] || banned="0"

  if fail2ban_jail_active_bool sshd; then
    ssh_line="Active"
  else
    ssh_line="Inactive"
  fi

  if fail2ban_jail_active_bool nginx-bad-request-access || fail2ban_jail_active_bool nginx-bad-request-error; then
    nginx_line="Active"
  else
    nginx_line="Inactive"
  fi

  if fail2ban_jail_active_bool recidive; then
    rec_line="Active"
  else
    rec_line="Inactive"
  fi

  local bbr_line
  if bbr_enabled_bool; then
    bbr_line="Enabled"
  else
    bbr_line="Disabled"
  fi

  local swap_line
  swap_line="$(swap_status_pretty_get)"

  local edge_svc edge_line xray_svc_line nginx_svc_line ssh_svc_line
  edge_svc="$(main_menu_edge_service_name)"
  if svc_exists "${edge_svc}" && svc_is_active "${edge_svc}"; then
    edge_line="Active"
  else
    edge_line="Inactive"
  fi
  if svc_exists xray && svc_is_active xray; then
    xray_svc_line="Active"
  else
    xray_svc_line="Inactive"
  fi
  if svc_exists nginx && svc_is_active nginx; then
    nginx_svc_line="Active"
  else
    nginx_svc_line="Inactive"
  fi
  if svc_exists "${SSHWS_DROPBEAR_SERVICE}" && svc_is_active "${SSHWS_DROPBEAR_SERVICE}" \
    && svc_exists "${SSHWS_STUNNEL_SERVICE}" && svc_is_active "${SSHWS_STUNNEL_SERVICE}" \
    && svc_exists "${SSHWS_PROXY_SERVICE}" && svc_is_active "${SSHWS_PROXY_SERVICE}"; then
    ssh_svc_line="Active"
  else
    ssh_svc_line="Inactive"
  fi

  echo
  echo "TLS Expiry        : ${tls_line}"
  echo "Fail2ban          : ${f2b_line}"
  echo "Banned IP         : ${banned}"
  echo "SSH Protection    : ${ssh_line}"
  echo "Nginx Protection  : ${nginx_line}"
  echo "Recidive          : ${rec_line}"
  echo "BBR               : ${bbr_line}"
  echo "Swap              : ${swap_line}"
  hr
  echo "Core Services"
  echo "Edge Mux          : ${edge_line}"
  echo "Nginx             : ${nginx_svc_line}"
  echo "Xray              : ${xray_svc_line}"
  echo "SSH               : ${ssh_svc_line}"
  hr
  pause
}

fail2ban_menu() {
  local -a items=(
    "1|TLS & Cert"
    "2|Fail2ban"
    "3|Hardening"
    "4|Overview"
    "0|Back"
  )
  while true; do
    ui_menu_screen_begin "8) Security"
    ui_menu_render_options items 76
    hr
    if ! read -r -p "Pilih: " c; then
      echo
      break
    fi
    case "${c}" in
      1) security_tls_menu ;;
      2) security_fail2ban_menu ;;
      3) security_hardening_menu ;;
      4) security_overview_menu ;;
      0|kembali|k|back|b) break ;;
      *) warn "Pilihan tidak valid" ; sleep 1 ;;
    esac
  done
}
# -------------------------
# Wireproxy helpers
# -------------------------
wireproxy_status_menu() {
  title
  echo "9) Maintenance > WARP Status"
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
  echo "9) Maintenance > Restart WARP"
  hr

  local confirm_rc=0
  if ! confirm_yn_or_back "Restart wireproxy sekarang?"; then
    confirm_rc=$?
    if (( confirm_rc == 1 || confirm_rc == 2 )); then
      warn "Restart wireproxy dibatalkan."
      hr
      pause
      return 0
    fi
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

edge_runtime_env_file() {
  printf '%s\n' "/etc/default/edge-runtime"
}

badvpn_runtime_env_file() {
  printf '%s\n' "/etc/default/badvpn-udpgw"
}

badvpn_runtime_ports() {
  local ports_raw
  ports_raw="$(badvpn_runtime_get_env BADVPN_UDPGW_PORTS 2>/dev/null || echo "7300 7400 7500 7600 7700 7800 7900")"
  ports_raw="${ports_raw//,/ }"
  ports_raw="${ports_raw%\"}"
  ports_raw="${ports_raw#\"}"
  ports_raw="${ports_raw%\'}"
  ports_raw="${ports_raw#\'}"
  awk '
    {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^[0-9]+$/ && !seen[$i]++) {
          ports[++count] = $i + 0
        }
      }
    }
    END {
      if (count > 0) {
        for (i = 1; i <= count; i++) {
          for (j = i + 1; j <= count; j++) {
            if (ports[j] < ports[i]) {
              tmp = ports[i]
              ports[i] = ports[j]
              ports[j] = tmp
            }
          }
        }
        for (i = 1; i <= count; i++) {
          out = out (out ? " " : "") ports[i]
        }
        print out
      }
    }
  ' <<< "${ports_raw}"
}

badvpn_public_port_label() {
  local ports
  ports="$(badvpn_runtime_ports)"
  if svc_exists badvpn-udpgw || [[ -r "$(badvpn_runtime_env_file)" ]]; then
    printf '%s\n' "${ports}" | sed 's/ /, /g'
  else
    printf '%s\n' "-"
  fi
}

badvpn_runtime_get_env() {
  local key="$1"
  local env_file
  env_file="$(badvpn_runtime_env_file)"
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

edge_runtime_service_name() {
  local provider
  provider="$(edge_runtime_get_env EDGE_PROVIDER 2>/dev/null || echo "none")"
  case "${provider}" in
    nginx-stream) printf '%s\n' "nginx" ;;
    go) printf '%s\n' "edge-mux.service" ;;
    *) printf '%s\n' "edge-mux.service" ;;
  esac
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
  echo "9) Maintenance > Edge Gateway Status"
  hr

  local svc env_file provider active http_port tls_port http_backend http_tls_backend ssh_backend ssh_tls_backend detect_timeout tls80 tls_backend_required
  svc="$(edge_runtime_service_name)"
  env_file="$(edge_runtime_env_file)"
  provider="$(edge_runtime_get_env EDGE_PROVIDER 2>/dev/null || echo "none")"
  active="$(edge_runtime_get_env EDGE_ACTIVATE_RUNTIME 2>/dev/null || echo "false")"
  http_port="$(edge_runtime_get_env EDGE_PUBLIC_HTTP_PORT 2>/dev/null || echo "80")"
  tls_port="$(edge_runtime_get_env EDGE_PUBLIC_TLS_PORT 2>/dev/null || echo "443")"
  http_backend="$(edge_runtime_get_env EDGE_NGINX_HTTP_BACKEND 2>/dev/null || echo "127.0.0.1:18080")"
  http_tls_backend="$(edge_runtime_get_env EDGE_NGINX_TLS_BACKEND 2>/dev/null || echo "127.0.0.1:18443")"
  ssh_backend="$(edge_runtime_get_env EDGE_SSH_CLASSIC_BACKEND 2>/dev/null || echo "127.0.0.1:22022")"
  ssh_tls_backend="$(edge_runtime_get_env EDGE_SSH_TLS_BACKEND 2>/dev/null || echo "127.0.0.1:22443")"
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
  echo "HTTP port   : ${http_port}"
  echo "TLS port    : ${tls_port}"
  echo "HTTP backend: ${http_backend}"
  if [[ "${tls_backend_required}" == "true" ]]; then
    echo "HTTPS b/e   : ${http_tls_backend}"
  else
    echo "HTTPS b/e   : ${http_tls_backend} (unused)"
  fi
  echo "SSH backend : ${ssh_backend}"
  echo "SSH TLS b/e : ${ssh_tls_backend}"
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
    if ss -lnt 2>/dev/null | grep -Eq "(^|[[:space:]])[^[:space:]]*:${http_port}([[:space:]]|$)"; then
      log "Public HTTP ${http_port} : LISTENING ✅"
    else
      warn "Public HTTP ${http_port} : NOT listening ❌"
    fi
    if ss -lnt 2>/dev/null | grep -Eq "(^|[[:space:]])[^[:space:]]*:${tls_port}([[:space:]]|$)"; then
      log "Public TLS  ${tls_port} : LISTENING ✅"
    else
      warn "Public TLS  ${tls_port} : NOT listening ❌"
    fi

    local backend_http_port backend_http_tls_port backend_ssh_port
    backend_http_port="${http_backend##*:}"
    backend_ssh_port="${ssh_backend##*:}"
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
    else
      log "Backend HTTPS ${http_tls_backend} : unused for provider ${provider} ✅"
    fi
    if ss -lnt 2>/dev/null | grep -Eq "(^|[[:space:]])[^[:space:]]*:${backend_ssh_port}([[:space:]]|$)"; then
      log "Backend SSH  ${ssh_backend} : LISTENING ✅"
    else
      warn "Backend SSH  ${ssh_backend} : NOT listening ❌"
    fi
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
  local svc provider active http_port tls_port http_backend http_tls_backend ssh_backend tls_backend_required
  local backend_http_port backend_http_tls_port backend_ssh_port
  svc="$(edge_runtime_service_name)"
  provider="$(edge_runtime_get_env EDGE_PROVIDER 2>/dev/null || echo "none")"
  active="$(edge_runtime_get_env EDGE_ACTIVATE_RUNTIME 2>/dev/null || echo "false")"
  http_port="$(edge_runtime_get_env EDGE_PUBLIC_HTTP_PORT 2>/dev/null || echo "80")"
  tls_port="$(edge_runtime_get_env EDGE_PUBLIC_TLS_PORT 2>/dev/null || echo "443")"
  http_backend="$(edge_runtime_get_env EDGE_NGINX_HTTP_BACKEND 2>/dev/null || echo "127.0.0.1:18080")"
  http_tls_backend="$(edge_runtime_get_env EDGE_NGINX_TLS_BACKEND 2>/dev/null || echo "127.0.0.1:18443")"
  ssh_backend="$(edge_runtime_get_env EDGE_SSH_CLASSIC_BACKEND 2>/dev/null || echo "127.0.0.1:22022")"
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
  backend_ssh_port="${ssh_backend##*:}"

  if ! edge_runtime_socket_listening "${http_port}"; then
    warn "Port HTTP publik ${http_port} belum listening setelah restart edge."
    return 1
  fi
  if ! edge_runtime_socket_listening "${tls_port}"; then
    warn "Port TLS publik ${tls_port} belum listening setelah restart edge."
    return 1
  fi
  if ! edge_runtime_socket_listening "${backend_http_port}"; then
    warn "Backend HTTP ${http_backend} belum listening setelah restart edge."
    return 1
  fi
  if [[ "${tls_backend_required}" == "true" ]] && ! edge_runtime_socket_listening "${backend_http_tls_port}"; then
    warn "Backend HTTPS ${http_tls_backend} belum listening setelah restart edge."
    return 1
  fi
  if ! edge_runtime_socket_listening "${backend_ssh_port}"; then
    warn "Backend SSH ${ssh_backend} belum listening setelah restart edge."
    return 1
  fi
  return 0
}

edge_runtime_restart_menu() {
  title
  echo "9) Maintenance > Restart Edge Gateway"
  hr

  local confirm_rc=0
  if ! confirm_yn_or_back "Restart Edge Gateway sekarang?"; then
    confirm_rc=$?
    if (( confirm_rc == 1 || confirm_rc == 2 )); then
      warn "Restart Edge Gateway dibatalkan."
      hr
      pause
      return 0
    fi
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
  echo "9) Maintenance > Edge Gateway Info"
  hr

  local provider active http_port tls_port http_backend http_tls_backend ssh_backend ssh_tls_backend detect_timeout tls80 cert_file key_file
  provider="$(edge_runtime_get_env EDGE_PROVIDER 2>/dev/null || echo "none")"
  active="$(edge_runtime_get_env EDGE_ACTIVATE_RUNTIME 2>/dev/null || echo "false")"
  http_port="$(edge_runtime_get_env EDGE_PUBLIC_HTTP_PORT 2>/dev/null || echo "80")"
  tls_port="$(edge_runtime_get_env EDGE_PUBLIC_TLS_PORT 2>/dev/null || echo "443")"
  http_backend="$(edge_runtime_get_env EDGE_NGINX_HTTP_BACKEND 2>/dev/null || echo "127.0.0.1:18080")"
  http_tls_backend="$(edge_runtime_get_env EDGE_NGINX_TLS_BACKEND 2>/dev/null || echo "127.0.0.1:18443")"
  ssh_backend="$(edge_runtime_get_env EDGE_SSH_CLASSIC_BACKEND 2>/dev/null || echo "127.0.0.1:22022")"
  ssh_tls_backend="$(edge_runtime_get_env EDGE_SSH_TLS_BACKEND 2>/dev/null || echo "127.0.0.1:22443")"
  detect_timeout="$(edge_runtime_get_env EDGE_HTTP_DETECT_TIMEOUT_MS 2>/dev/null || echo "250")"
  tls80="$(edge_runtime_get_env EDGE_CLASSIC_TLS_ON_80 2>/dev/null || echo "true")"
  cert_file="$(edge_runtime_get_env EDGE_TLS_CERT_FILE 2>/dev/null || echo "/opt/cert/fullchain.pem")"
  key_file="$(edge_runtime_get_env EDGE_TLS_KEY_FILE 2>/dev/null || echo "/opt/cert/privkey.pem")"
  echo "Provider        : ${provider}"
  echo "Runtime Active  : ${active}"
  echo "Public HTTP     : ${http_port}"
  echo "Public TLS      : ${tls_port}"
  echo "HTTP Backend    : ${http_backend}"
  echo "HTTPS Backend   : ${http_tls_backend}"
  echo "SSH Backend     : ${ssh_backend}"
  echo "SSH TLS Backend : ${ssh_tls_backend}"
  echo "Detect Timeout  : ${detect_timeout} ms"
  echo "Classic TLS :80 : ${tls80}"
  echo "TLS Cert        : ${cert_file}"
  echo "TLS Key         : ${key_file}"
  hr
  echo "Mode ringkas:"
  echo "  - HTTP / WebSocket -> backend HTTP (${http_backend})"
  if [[ "${provider}" == "nginx-stream" ]]; then
    echo "  - TLS + ALPN http/1.1,h2 -> backend HTTPS (${http_tls_backend})"
    echo "  - TLS tanpa ALPN HTTP -> backend SSH TLS (${ssh_tls_backend})"
  else
    echo "  - non-HTTP setelah TLS -> backend SSH klasik (${ssh_backend})"
  fi
  echo "  - default gateway aktif hanya satu pada port publik"
  hr
  pause
}

badvpn_status_menu() {
  title
  echo "9) Maintenance > BadVPN UDPGW Status"
  hr

  local env_file ports_raw ports_label max_clients max_conn sndbuf svc
  svc="badvpn-udpgw.service"
  env_file="$(badvpn_runtime_env_file)"
  ports_raw="$(badvpn_runtime_ports)"
  ports_label="$(printf '%s\n' "${ports_raw}" | sed 's/ /, /g')"
  max_clients="$(badvpn_runtime_get_env BADVPN_UDPGW_MAX_CLIENTS 2>/dev/null || echo "512")"
  max_conn="$(badvpn_runtime_get_env BADVPN_UDPGW_MAX_CONNECTIONS_FOR_CLIENT 2>/dev/null || echo "8")"
  sndbuf="$(badvpn_runtime_get_env BADVPN_UDPGW_BUFFER_SIZE 2>/dev/null || echo "1048576")"

  echo "Runtime env : ${env_file}"
  echo "Listen port : 127.0.0.1:${ports_label}"
  echo "Max clients : ${max_clients}"
  echo "Max conn    : ${max_conn}"
  echo "Sock sndbuf : ${sndbuf}"
  hr

  if svc_exists "${svc}"; then
    svc_status_line "${svc}"
  else
    warn "${svc} tidak terpasang"
  fi

  hr
  if have_cmd ss; then
    local badvpn_missing="" port
    for port in ${ports_raw}; do
      if ! ss -lntH 2>/dev/null | grep -Eq "(^|[[:space:]])127\\.0\\.0\\.1:${port}([[:space:]]|$)"; then
        badvpn_missing="${badvpn_missing}${badvpn_missing:+, }${port}"
      fi
    done
    if [[ -z "${badvpn_missing}" ]]; then
      log "UDPGW 127.0.0.1:${ports_label} : LISTENING ✅"
    else
      warn "UDPGW 127.0.0.1:${ports_label} : MISSING ${badvpn_missing} ❌"
    fi
  else
    warn "ss tidak tersedia, skip cek port TCP UDPGW"
  fi

  hr
  pause
}

badvpn_post_restart_health_check() {
  local svc ports_raw port
  svc="badvpn-udpgw.service"
  if ! svc_restart_checked "${svc}" 60; then
    warn "Restart ${svc} gagal."
    return 1
  fi
  if ! have_cmd ss; then
    return 0
  fi
  ports_raw="$(badvpn_runtime_ports)"
  for port in ${ports_raw}; do
    if ! ss -lntH 2>/dev/null | grep -Eq "(^|[[:space:]])127\\.0\\.0\\.1:${port}([[:space:]]|$)"; then
      warn "Port UDPGW 127.0.0.1:${port} belum listening setelah restart."
      return 1
    fi
  done
  return 0
}

badvpn_restart_menu() {
  title
  echo "9) Maintenance > Restart BadVPN UDPGW"
  hr

  local confirm_rc=0
  if ! confirm_yn_or_back "Restart BadVPN UDPGW sekarang?"; then
    confirm_rc=$?
    if (( confirm_rc == 1 || confirm_rc == 2 )); then
      warn "Restart BadVPN UDPGW dibatalkan."
      hr
      pause
      return 0
    fi
  fi

  local restart_failed="false"
  local svc
  svc="badvpn-udpgw.service"
  if ! svc_exists "${svc}"; then
    warn "${svc} tidak ditemukan."
    hr
    pause
    return 0
  fi

  if ! badvpn_post_restart_health_check; then
    warn "Restart ${svc} gagal."
    restart_failed="true"
  fi
  hr
  pause
  [[ "${restart_failed}" != "true" ]]
}

sshws_detect_dropbear_port() {
  local fallback="${SSHWS_DROPBEAR_PORT:-22022}"
  local unit_file="/etc/systemd/system/${SSHWS_DROPBEAR_SERVICE}.service"
  local value=""
  if [[ -r "${unit_file}" ]]; then
    value="$(grep -Eo -- '-p[[:space:]]+127\\.0\\.0\\.1:[0-9]+' "${unit_file}" 2>/dev/null | head -n1 | grep -Eo '[0-9]+$' | head -n1 || true)"
  fi
  if [[ "${value}" =~ ^[0-9]+$ ]] && (( value >= 1 && value <= 65535 )); then
    echo "${value}"
  else
    echo "${fallback}"
  fi
}

sshws_detect_stunnel_port() {
  local fallback="${SSHWS_STUNNEL_PORT:-22443}"
  local conf_file="/etc/stunnel/sshws.conf"
  local value=""
  if [[ -r "${conf_file}" ]]; then
    value="$(sed -nE 's/^[[:space:]]*accept[[:space:]]*=[[:space:]]*127\\.0\\.0\\.1:([0-9]+).*$/\1/p' "${conf_file}" | head -n1)"
  fi
  if [[ "${value}" =~ ^[0-9]+$ ]] && (( value >= 1 && value <= 65535 )); then
    echo "${value}"
  else
    echo "${fallback}"
  fi
}

sshws_detect_proxy_port() {
  local fallback="${SSHWS_PROXY_PORT:-10015}"
  local unit_file="/etc/systemd/system/${SSHWS_PROXY_SERVICE}.service"
  local value=""
  if [[ -r "${unit_file}" ]]; then
    value="$(grep -Eo -- '--listen-port[[:space:]]+[0-9]+' "${unit_file}" 2>/dev/null | head -n1 | grep -Eo '[0-9]+' | head -n1 || true)"
  fi
  if [[ "${value}" =~ ^[0-9]+$ ]] && (( value >= 1 && value <= 65535 )); then
    echo "${value}"
  else
    echo "${fallback}"
  fi
}

ssh_runtime_context_run() {
  local ctx="${1:-}"
  shift || true
  local prev="${SSH_RUNTIME_MENU_CONTEXT:-}"
  SSH_RUNTIME_MENU_CONTEXT="${ctx}"
  "$@"
  local rc=$?
  SSH_RUNTIME_MENU_CONTEXT="${prev}"
  return "${rc}"
}

ssh_runtime_menu_title() {
  local suffix="${1:-}"
  local base="9) Maintenance"
  case "${SSH_RUNTIME_MENU_CONTEXT:-}" in
    ssh-users) base="2) SSH Users" ;;
    ssh-network) base="14) SSH Network" ;;
    maintenance|"") base="9) Maintenance" ;;
  esac
  if [[ -n "${suffix}" ]]; then
    printf '%s > %s\n' "${base}" "${suffix}"
  else
    printf '%s\n' "${base}"
  fi
}

sshws_status_menu() {
  title
  if [[ "${SSH_RUNTIME_MENU_CONTEXT:-}" == "ssh-network" ]]; then
    echo "$(ssh_runtime_menu_title "Status")"
  else
    echo "$(ssh_runtime_menu_title "SSH WS Status")"
  fi
  hr

  local services=("${SSHWS_DROPBEAR_SERVICE}" "${SSHWS_STUNNEL_SERVICE}" "${SSHWS_PROXY_SERVICE}")
  local svc
  for svc in "${services[@]}"; do
    if svc_exists "${svc}"; then
      svc_status_line "${svc}"
    else
      warn "${svc}.service tidak terpasang"
    fi
  done

  hr
  if have_cmd ss; then
    if ss -lntp 2>/dev/null | grep -Eq '(^|[[:space:]])[^[:space:]]*:80([[:space:]]|$)'; then
      log "Port 80   : LISTENING ✅"
    else
      warn "Port 80   : NOT listening ❌"
    fi
    if ss -lntp 2>/dev/null | grep -Eq '(^|[[:space:]])[^[:space:]]*:443([[:space:]]|$)'; then
      log "Port 443  : LISTENING ✅"
    else
      warn "Port 443  : NOT listening ❌"
    fi
  else
    warn "ss tidak tersedia, skip cek port 80/443"
  fi

  hr
  local dropbear_port stunnel_port proxy_port
  dropbear_port="$(sshws_detect_dropbear_port)"
  stunnel_port="$(sshws_detect_stunnel_port)"
  proxy_port="$(sshws_detect_proxy_port)"
  echo "Internal ports (detected):"
  echo "  - dropbear local : 127.0.0.1:${dropbear_port}"
  echo "  - stunnel local  : 127.0.0.1:${stunnel_port}"
  echo "  - ws proxy local : 127.0.0.1:${proxy_port}"
  hr
  pause
}

sshws_post_restart_health_check() {
  local dropbear_svc="${SSHWS_DROPBEAR_SERVICE}"
  local stunnel_svc="${SSHWS_STUNNEL_SERVICE}"
  local proxy_svc="${SSHWS_PROXY_SERVICE}"
  local -a failed=()
  local dropbear_port stunnel_port proxy_port dropbear_probe proxy_probe stunnel_probe

  dropbear_port="$(sshws_detect_dropbear_port)"
  stunnel_port="$(sshws_detect_stunnel_port)"
  proxy_port="$(sshws_detect_proxy_port)"
  if have_cmd ss; then
    if (svc_exists "${proxy_svc}" || svc_exists "${stunnel_svc}") && ! ss -lntp 2>/dev/null | grep -Eq '(^|[[:space:]])[^[:space:]]*:80([[:space:]]|$)'; then
      warn "Port 80 belum listening setelah restart SSH WS."
      failed+=("port-80")
    fi
    if (svc_exists "${proxy_svc}" || svc_exists "${stunnel_svc}") && ! ss -lntp 2>/dev/null | grep -Eq '(^|[[:space:]])[^[:space:]]*:443([[:space:]]|$)'; then
      warn "Port 443 belum listening setelah restart SSH WS."
      failed+=("port-443")
    fi
  fi
  if svc_exists "${dropbear_svc}"; then
    dropbear_probe="$(sshws_probe_tcp_endpoint "127.0.0.1" "${dropbear_port}" "tcp")"
    if ! sshws_probe_result_is_healthy "${dropbear_probe}"; then
      warn "Probe dropbear local gagal setelah restart SSH WS: $(sshws_probe_result_disp "${dropbear_probe}")"
      failed+=("dropbear")
    fi
  fi
  if svc_exists "${proxy_svc}"; then
    proxy_probe="$(sshws_probe_ws_endpoint "127.0.0.1" "${proxy_port}" "$(sshws_probe_path_pick)" "127.0.0.1:${proxy_port}" "off" "")"
    if ! sshws_probe_result_is_healthy "${proxy_probe}"; then
      warn "Probe ws proxy local gagal setelah restart SSH WS: $(sshws_probe_result_disp "${proxy_probe}")"
      failed+=("ws-proxy")
    fi
  fi
  if svc_exists "${stunnel_svc}"; then
    stunnel_probe="$(sshws_probe_tcp_endpoint "127.0.0.1" "${stunnel_port}" "tls")"
    if ! sshws_probe_result_is_healthy "${stunnel_probe}"; then
      warn "Probe stunnel local gagal setelah restart SSH WS: $(sshws_probe_result_disp "${stunnel_probe}")"
      failed+=("stunnel")
    fi
  fi
  if (( ${#failed[@]} > 0 )); then
    warn "Verifikasi pasca-restart SSH WS belum sehat: ${failed[*]}"
    return 1
  fi
  return 0
}

sshws_restart_services_checked() {
  local services=("$@")
  local svc restarted="false"
  local -a failed=()

  for svc in "${services[@]}"; do
    [[ -n "${svc}" ]] || continue
    if svc_exists "${svc}"; then
      if svc_restart_checked "${svc}" 60; then
        restarted="true"
      else
        failed+=("${svc}")
      fi
    else
      warn "${svc}.service tidak terpasang"
    fi
  done

  if [[ "${restarted}" != "true" ]]; then
    warn "Tidak ada service SSH WS yang bisa direstart."
    return 1
  fi
  if (( ${#failed[@]} > 0 )); then
    warn "Gagal restart service SSH WS: ${failed[*]}"
    return 1
  fi
  sshws_post_restart_health_check || return 1
  return 0
}

sshws_restart_menu() {
  title
  if [[ "${SSH_RUNTIME_MENU_CONTEXT:-}" == "ssh-network" ]]; then
    echo "$(ssh_runtime_menu_title "Restart SSH Transport")"
  else
    echo "$(ssh_runtime_menu_title "Restart SSH WS")"
  fi
  hr

  local confirm_rc=0
  if ! confirm_yn_or_back "Restart semua service SSH WS sekarang?"; then
    confirm_rc=$?
    if (( confirm_rc == 1 || confirm_rc == 2 )); then
      warn "Restart SSH WS dibatalkan."
      hr
      pause
      return 0
    fi
  fi

  if ! sshws_restart_services_checked "${SSHWS_DROPBEAR_SERVICE}" "${SSHWS_STUNNEL_SERVICE}" "${SSHWS_PROXY_SERVICE}"; then
    warn "Restart SSH WS gagal."
  fi
  hr
  pause
}

sshws_probe_tcp_endpoint() {
  # args: host port mode(tcp|tls)
  local host="${1:-127.0.0.1}"
  local port="${2:-0}"
  local mode="${3:-tcp}"
  need_python3
  python3 - <<'PY' "${host}" "${port}" "${mode}" 2>/dev/null || true
import socket
import ssl
import sys

host, port_s, mode = sys.argv[1:4]
try:
  port = int(port_s)
except Exception:
  print("fail|invalid-port")
  raise SystemExit(0)

timeout = 2.0
sock = None
try:
  raw = socket.create_connection((host, port), timeout=timeout)
  if mode == "tls":
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    sock = ctx.wrap_socket(raw, server_hostname=host or "localhost")
  else:
    sock = raw
  print("ok|connected")
except Exception as exc:
  msg = str(exc).strip().replace("\n", " ")
  print("fail|" + (msg or exc.__class__.__name__.lower()))
finally:
  try:
    if sock is not None:
      sock.close()
  except Exception:
    pass
PY
}

sshws_probe_ws_endpoint() {
  # args: host port path host_header tls_mode sni
  local host="${1:-127.0.0.1}"
  local port="${2:-0}"
  local path="${3:-/}"
  local host_header="${4:-127.0.0.1}"
  local tls_mode="${5:-off}"
  local sni="${6:-}"
  need_python3
  python3 - <<'PY' "${host}" "${port}" "${path}" "${host_header}" "${tls_mode}" "${sni}" 2>/dev/null || true
import socket
import ssl
import sys

host, port_s, path, host_header, tls_mode, sni = sys.argv[1:7]
try:
  port = int(port_s)
except Exception:
  print("fail|invalid-port")
  raise SystemExit(0)

raw = None
sock = None
try:
  raw = socket.create_connection((host, port), timeout=3.0)
  raw.settimeout(3.0)
  if tls_mode == "on":
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    sock = ctx.wrap_socket(raw, server_hostname=sni or host or "localhost")
  else:
    sock = raw
  req = (
    f"GET {path or '/'} HTTP/1.1\r\n"
    f"Host: {host_header or host}\r\n"
    "Upgrade: websocket\r\n"
    "Connection: Upgrade\r\n"
    "User-Agent: autoscript-manage/sshws-diagnostics\r\n"
    "\r\n"
  ).encode("ascii", "ignore")
  sock.sendall(req)
  buf = b""
  while b"\r\n\r\n" not in buf and len(buf) < 16384:
    chunk = sock.recv(4096)
    if not chunk:
      break
    buf += chunk
  if not buf:
    print("fail|empty-response")
    raise SystemExit(0)
  line = buf.split(b"\r\n", 1)[0].decode("latin1", "replace").strip()
  parts = line.split(None, 2)
  if len(parts) >= 2 and parts[1].isdigit():
    code = int(parts[1])
    reason = parts[2] if len(parts) >= 3 else ""
    print(f"http|{code}|{reason}")
  else:
    print("fail|" + (line or "bad-response"))
except Exception as exc:
  msg = str(exc).strip().replace("\n", " ")
  print("fail|" + (msg or exc.__class__.__name__.lower()))
finally:
  try:
    if sock is not None:
      sock.close()
  except Exception:
    pass
  try:
    if raw is not None and raw is not sock:
      raw.close()
  except Exception:
    pass
PY
}

sshws_probe_result_disp() {
  local raw="${1:-}"
  local kind part1 part2
  IFS='|' read -r kind part1 part2 <<<"${raw}"
  case "${kind}" in
    ok)
      echo "OK (${part1:-connected})"
      ;;
    http)
      case "${part1:-0}" in
        101) echo "OK (HTTP 101 ${part2:-})" ;;
        301|302|307|308) echo "WARN (HTTP ${part1} ${part2:-redirect})" ;;
        401|403) echo "WARN (HTTP ${part1} ${part2:-token-required})" ;;
        *) echo "FAIL (HTTP ${part1:-0} ${part2:-})" ;;
      esac
      ;;
    fail)
      echo "FAIL (${part1:-unknown})"
      ;;
    *)
      echo "FAIL (unknown)"
      ;;
  esac
}

sshws_probe_result_is_healthy() {
  local raw="${1:-}"
  local kind part1
  IFS='|' read -r kind part1 _ <<<"${raw}"
  case "${kind}" in
    ok) return 0 ;;
    http)
      case "${part1:-0}" in
        101|301|302|307|308|401|403) return 0 ;;
      esac
      ;;
  esac
  return 1
}

sshws_combined_logs_menu() {
  title
  if [[ "${SSH_RUNTIME_MENU_CONTEXT:-}" == "ssh-network" ]]; then
    echo "$(ssh_runtime_menu_title "Combined Logs")"
  else
    echo "$(ssh_runtime_menu_title "SSH WS Combined Logs")"
  fi
  hr

  local -a svc_args=()
  local svc
  for svc in "${SSHWS_DROPBEAR_SERVICE}" "${SSHWS_STUNNEL_SERVICE}" "${SSHWS_PROXY_SERVICE}"; do
    if svc_exists "${svc}"; then
      svc_args+=(-u "${svc}")
    fi
  done

  if (( ${#svc_args[@]} == 0 )); then
    warn "Belum ada service SSH WS yang terpasang."
    hr
    pause
    return 0
  fi

  journalctl "${svc_args[@]}" --no-pager -n 120 2>/dev/null || true
  hr
  pause
}

sshws_diagnostics_menu() {
  local choice=""
  while true; do
    title
    if [[ "${SSH_RUNTIME_MENU_CONTEXT:-}" == "ssh-network" ]]; then
      echo "$(ssh_runtime_menu_title "Diagnostics")"
    else
      echo "$(ssh_runtime_menu_title "SSH WS Diagnostics")"
    fi
    hr

    local dropbear_port stunnel_port proxy_port domain probe_path
    local proxy_probe tls443_probe http80_probe dropbear_probe stunnel_probe
    dropbear_port="$(sshws_detect_dropbear_port)"
    stunnel_port="$(sshws_detect_stunnel_port)"
    proxy_port="$(sshws_detect_proxy_port)"
    domain="$(detect_domain)"
    probe_path="$(sshws_probe_path_pick)"

    echo "Services:"
    if svc_exists "${SSHWS_DROPBEAR_SERVICE}"; then
      printf "  %-16s : %s\n" "${SSHWS_DROPBEAR_SERVICE}" "$(svc_status_line "${SSHWS_DROPBEAR_SERVICE}")"
    else
      printf "  %-16s : %s\n" "${SSHWS_DROPBEAR_SERVICE}" "NOT INSTALLED"
    fi
    if svc_exists "${SSHWS_STUNNEL_SERVICE}"; then
      printf "  %-16s : %s\n" "${SSHWS_STUNNEL_SERVICE}" "$(svc_status_line "${SSHWS_STUNNEL_SERVICE}")"
    else
      printf "  %-16s : %s\n" "${SSHWS_STUNNEL_SERVICE}" "OPTIONAL / NOT INSTALLED"
    fi
    if svc_exists "${SSHWS_PROXY_SERVICE}"; then
      printf "  %-16s : %s\n" "${SSHWS_PROXY_SERVICE}" "$(svc_status_line "${SSHWS_PROXY_SERVICE}")"
    else
      printf "  %-16s : %s\n" "${SSHWS_PROXY_SERVICE}" "NOT INSTALLED"
    fi

    hr
    echo "Internal Ports:"
    printf "  %-16s : 127.0.0.1:%s\n" "dropbear" "${dropbear_port}"
    printf "  %-16s : 127.0.0.1:%s\n" "stunnel" "${stunnel_port}"
    printf "  %-16s : 127.0.0.1:%s\n" "ws proxy" "${proxy_port}"
    printf "  %-16s : %s\n" "domain" "${domain:-"-"}"
    printf "  %-16s : %s\n" "probe path" "${probe_path}"

    hr
    echo "Local Probes:"
    dropbear_probe="$(sshws_probe_tcp_endpoint "127.0.0.1" "${dropbear_port}" "tcp")"
    printf "  %-16s : %s\n" "dropbear tcp" "$(sshws_probe_result_disp "${dropbear_probe}")"

    proxy_probe="$(sshws_probe_ws_endpoint "127.0.0.1" "${proxy_port}" "${probe_path}" "127.0.0.1:${proxy_port}" "off" "")"
    printf "  %-16s : %s\n" "proxy ws" "$(sshws_probe_result_disp "${proxy_probe}")"

    if svc_exists "${SSHWS_STUNNEL_SERVICE}"; then
      stunnel_probe="$(sshws_probe_tcp_endpoint "127.0.0.1" "${stunnel_port}" "tls")"
      printf "  %-16s : %s\n" "stunnel tls" "$(sshws_probe_result_disp "${stunnel_probe}")"
    else
      printf "  %-16s : %s\n" "stunnel tls" "SKIP (optional)"
    fi

    hr
    echo "Public Path Probes:"
    if have_cmd ss && ss -lntp 2>/dev/null | grep -Eq '(^|[[:space:]])[^[:space:]]*:80([[:space:]]|$)'; then
      http80_probe="$(sshws_probe_ws_endpoint "127.0.0.1" "80" "${probe_path}" "${domain:-127.0.0.1}" "off" "")"
      printf "  %-16s : %s\n" "nginx :80" "$(sshws_probe_result_disp "${http80_probe}")"
    else
      printf "  %-16s : %s\n" "nginx :80" "SKIP (not listening)"
    fi
    if [[ -n "${domain}" ]] && have_cmd ss && ss -lntp 2>/dev/null | grep -Eq '(^|[[:space:]])[^[:space:]]*:443([[:space:]]|$)'; then
      tls443_probe="$(sshws_probe_ws_endpoint "127.0.0.1" "443" "${probe_path}" "${domain}" "on" "${domain}")"
      printf "  %-16s : %s\n" "nginx :443" "$(sshws_probe_result_disp "${tls443_probe}")"
    else
      printf "  %-16s : %s\n" "nginx :443" "SKIP (domain/443 unavailable)"
    fi

    hr
    echo "Notes:"
    echo "  - HTTP 101 menandakan chain SSH WS sehat."
    echo "  - HTTP 502 biasanya berarti backend internal belum siap."
    echo "  - HTTP 301/308 pada port 80 normal jika force-HTTPS aktif."
    echo "  - HTTP 401/403 biasanya berarti path/token SSH WS belum cocok."
    hr
    echo "  1) Refresh"
    echo "  2) Combined SSH WS Logs"
    echo "  0) Back"
    hr
    if ! read -r -p "Pilih: " choice; then
      echo
      return 0
    fi
    case "${choice}" in
      1|refresh|r) ;;
      2|logs|log) sshws_combined_logs_menu ;;
      0|kembali|k|back|b) return 0 ;;
      *) warn "Pilihan tidak valid" ; sleep 1 ;;
    esac
  done
}

ssh_username_valid() {
  local username="${1:-}"
  [[ "${username}" =~ ^[a-z_][a-z0-9_-]{1,31}$ ]]
}

ssh_username_duplicate_reason() {
  # prints reason if duplicate exists; return 0 if duplicate, 1 otherwise.
  local username="${1:-}"
  [[ -n "${username}" ]] || return 1

  # Cegah duplikat terhadap user Linux yang sudah ada.
  if id "${username}" >/dev/null 2>&1; then
    printf "User '%s' sudah ada di sistem Linux.\n" "${username}"
    return 0
  fi

  local qf accf qf_compat accf_compat
  qf="$(ssh_user_state_file "${username}")"
  accf="$(ssh_account_info_file "${username}")"
  qf_compat="${SSH_USERS_STATE_DIR}/${username}.json"
  accf_compat="${SSH_ACCOUNT_DIR}/${username}.txt"

  # Cegah duplikat terhadap metadata managed (format baru/kompatibilitas lama).
  if [[ -f "${qf}" || -f "${accf}" || -f "${qf_compat}" || -f "${accf_compat}" ]]; then
    printf "Username '%s' sudah terdaftar pada metadata SSH managed.\n" "${username}"
    return 0
  fi

  local listed=""
  listed="$(
    find "${SSH_USERS_STATE_DIR}" -maxdepth 1 -type f -name '*.json' -printf '%f\n' 2>/dev/null \
      | sed -E 's/@ssh\.json$//' \
      | sed -E 's/\.json$//' \
      | tr '[:upper:]' '[:lower:]' \
      | grep -Fx -- "${username}" \
      | head -n1 || true
  )"
  if [[ -n "${listed}" ]]; then
    printf "Username '%s' sudah ada pada daftar akun SSH managed.\n" "${username}"
    return 0
  fi

  return 1
}

ssh_username_from_key() {
  local raw="${1:-}"
  raw="${raw%@ssh}"
  if [[ "${raw}" == *"@"* ]]; then
    raw="${raw%%@*}"
  fi
  printf '%s\n' "${raw}"
}

ssh_qac_lock_file() {
  printf '%s\n' "${SSH_QAC_LOCK_FILE:-/run/autoscript/locks/sshws-qac.lock}"
}

ssh_qac_lock_prepare() {
  local lock_file
  local lock_dir
  lock_file="$(ssh_qac_lock_file)"
  lock_dir="$(dirname "${lock_file}")"
  mkdir -p "${lock_dir}" 2>/dev/null || true
  chmod 700 "${lock_dir}" 2>/dev/null || true
}

ssh_qac_run_locked() {
  local lock_file rc=0
  if [[ "${SSH_QAC_LOCK_HELD:-0}" == "1" ]]; then
    "$@"
    return $?
  fi
  ssh_qac_lock_prepare
  lock_file="$(ssh_qac_lock_file)"
  if have_cmd flock; then
    if (
      flock -x 200 || exit 1
      SSH_QAC_LOCK_HELD=1 "$@"
    ) 200>"${lock_file}"; then
      return 0
    fi
    return $?
  fi

  SSH_QAC_LOCK_HELD=1 "$@"
  rc=$?
  return "${rc}"
}

ssh_account_info_password_mode() {
  case "${SSH_ACCOUNT_INFO_STORE_PASSWORD:-1}" in
    0|false|no|off|n)
      echo "mask"
      ;;
    *)
      echo "store"
      ;;
  esac
}

ssh_state_dirs_prepare() {
  local compat_state_dir="/var/lib/xray-manage/ssh-users"
  mkdir -p "${SSH_USERS_STATE_DIR}" "${SSH_ACCOUNT_DIR}"
  chmod 700 "${SSH_USERS_STATE_DIR}" "${SSH_ACCOUNT_DIR}" || true

  if [[ -d "${compat_state_dir}" && "${compat_state_dir}" != "${SSH_USERS_STATE_DIR}" ]]; then
    local f base username dst
    while IFS= read -r -d '' f; do
      base="$(basename "${f}")"
      base="${base%.json}"
      username="$(ssh_username_from_key "${base}")"
      [[ -n "${username}" ]] || continue
      dst="$(ssh_user_state_file "${username}")"
      if [[ ! -f "${dst}" ]]; then
        cp -a "${f}" "${dst}" >/dev/null 2>&1 || true
        chmod 600 "${dst}" >/dev/null 2>&1 || true
      elif [[ "${f}" -nt "${dst}" ]]; then
        # Jika file kompatibilitas lebih baru, sinkronkan agar metadata terbaru tidak hilang.
        cp -f "${f}" "${dst}" >/dev/null 2>&1 || true
        chmod 600 "${dst}" >/dev/null 2>&1 || true
      fi
    done < <(find "${compat_state_dir}" -maxdepth 1 -type f -name '*.json' -print0 2>/dev/null)
  fi

  local f base username dst
  while IFS= read -r -d '' f; do
    base="$(basename "${f}")"
    base="${base%.json}"
    username="$(ssh_username_from_key "${base}")"
    [[ -n "${username}" ]] || continue
    dst="$(ssh_user_state_file "${username}")"
    if [[ "${f}" != "${dst}" ]]; then
      if [[ ! -f "${dst}" ]]; then
        mv -f "${f}" "${dst}" >/dev/null 2>&1 || true
        chmod 600 "${dst}" >/dev/null 2>&1 || true
      elif [[ "${f}" -nt "${dst}" ]]; then
        # Pilih versi paling baru ketika format kompatibilitas & format canonical sama-sama ada.
        mv -f "${f}" "${dst}" >/dev/null 2>&1 || true
        chmod 600 "${dst}" >/dev/null 2>&1 || true
      else
        # Duplikat format kompatibilitas tidak dibutuhkan lagi setelah format @ssh dipakai.
        rm -f "${f}" >/dev/null 2>&1 || true
      fi
    fi
  done < <(find "${SSH_USERS_STATE_DIR}" -maxdepth 1 -type f -name '*.json' -print0 2>/dev/null)
}

zivpn_runtime_available() {
  [[ -x "${ZIVPN_SYNC_BIN}" ]] || return 1
  [[ -f "/etc/systemd/system/${ZIVPN_SERVICE}" || -f "/lib/systemd/system/${ZIVPN_SERVICE}" || -f "${ZIVPN_CONFIG_FILE}" ]] || return 1
  return 0
}

zivpn_password_file() {
  local username="${1:-}"
  printf '%s/%s.pass\n' "${ZIVPN_PASSWORDS_DIR}" "${username}"
}

zivpn_user_password_synced() {
  local username="${1:-}"
  [[ -n "${username}" ]] || return 1
  zivpn_runtime_available || return 1
  [[ -f "$(zivpn_password_file "${username}")" ]]
}

zivpn_password_read() {
  local username="${1:-}"
  local path
  path="$(zivpn_password_file "${username}")"
  [[ -f "${path}" ]] || {
    echo "-"
    return 0
  }
  tr -d '\r\n' < "${path}" 2>/dev/null || echo "-"
}

zivpn_sync_runtime_now() {
  zivpn_runtime_available || return 1
  "${ZIVPN_SYNC_BIN}" \
    --config "${ZIVPN_CONFIG_FILE}" \
    --passwords-dir "${ZIVPN_PASSWORDS_DIR}" \
    --listen ":${ZIVPN_LISTEN_PORT}" \
    --cert "${ZIVPN_CERT_FILE}" \
    --key "${ZIVPN_KEY_FILE}" \
    --obfs "${ZIVPN_OBFS}" \
    --account-dir "${SSH_ACCOUNT_DIR}" \
    --service "${ZIVPN_SERVICE}" \
    --sync-service-state >/dev/null 2>&1
}

zivpn_store_user_password() {
  local username="${1:-}"
  local password="${2:-}"
  local dst tmp
  [[ -n "${username}" && -n "${password}" ]] || return 1
  install -d -m 700 "${ZIVPN_PASSWORDS_DIR}"
  dst="$(zivpn_password_file "${username}")"
  tmp="$(mktemp "${TMPDIR:-/tmp}/zivpn-pass.XXXXXX")" || return 1
  if ! printf '%s\n' "${password}" > "${tmp}"; then
    rm -f "${tmp}" >/dev/null 2>&1 || true
    return 1
  fi
  if ! install -m 600 "${tmp}" "${dst}"; then
    rm -f "${tmp}" >/dev/null 2>&1 || true
    return 1
  fi
  chown root:root "${dst}" 2>/dev/null || true
  rm -f "${tmp}" >/dev/null 2>&1 || true
  return 0
}

zivpn_sync_user_password_warn() {
  local username="${1:-}"
  local password="${2:-}"
  zivpn_runtime_available || return 0
  if ! zivpn_store_user_password "${username}" "${password}"; then
    warn "ZIVPN password store gagal diperbarui untuk '${username}'."
    return 1
  fi
  if ! zivpn_sync_runtime_now; then
    warn "Runtime ZIVPN gagal disinkronkan untuk '${username}'."
    return 1
  fi
  return 0
}

zivpn_remove_user_password_warn() {
  local username="${1:-}"
  zivpn_runtime_available || return 0
  local path
  path="$(zivpn_password_file "${username}")"
  if [[ -e "${path}" || -L "${path}" ]]; then
    rm -f "${path}" >/dev/null 2>&1 || true
    if [[ -e "${path}" || -L "${path}" ]]; then
      warn "File password ZIVPN gagal dihapus untuk '${username}'."
      return 1
    fi
  fi
  if ! zivpn_sync_runtime_now; then
    warn "Runtime ZIVPN gagal disinkronkan setelah hapus akun '${username}'."
    return 1
  fi
  return 0
}

zivpn_account_info_enabled() {
  zivpn_runtime_available || return 1
  [[ -n "${ZIVPN_LISTEN_PORT:-}" ]] || return 1
  return 0
}

ssh_user_state_file() {
  local username="${1:-}"
  printf '%s/%s@ssh.json\n' "${SSH_USERS_STATE_DIR}" "${username}"
}

ssh_user_state_compat_file() {
  local username="${1:-}"
  printf '%s/%s.json\n' "${SSH_USERS_STATE_DIR}" "${username}"
}

ssh_user_state_resolve_file() {
  local username="${1:-}"
  local primary compat
  primary="$(ssh_user_state_file "${username}")"
  compat="$(ssh_user_state_compat_file "${username}")"
  if [[ -f "${primary}" ]]; then
    printf '%s\n' "${primary}"
  elif [[ -f "${compat}" ]]; then
    printf '%s\n' "${compat}"
  else
    printf '%s\n' "${primary}"
  fi
}

ssh_account_info_file() {
  local username="${1:-}"
  printf '%s/%s@ssh.txt\n' "${SSH_ACCOUNT_DIR}" "${username}"
}

ssh_user_artifacts_cleanup_unlocked() {
  local username="${1:-}"
  local f=""
  local -a failed=()
  for f in \
    "$(ssh_user_state_file "${username}")" \
    "${SSH_USERS_STATE_DIR}/${username}.json" \
    "$(ssh_account_info_file "${username}")" \
    "${SSH_ACCOUNT_DIR}/${username}.txt"; do
    [[ -e "${f}" || -L "${f}" ]] || continue
    rm -f "${f}" >/dev/null 2>&1 || true
    if [[ -e "${f}" || -L "${f}" ]]; then
      failed+=("${f}")
    fi
  done
  if (( ${#failed[@]} > 0 )); then
    printf '%s\n' "${failed[*]}"
    return 1
  fi
  return 0
}

ssh_user_artifacts_cleanup_locked() {
  local username="${1:-}"
  ssh_qac_run_locked ssh_user_artifacts_cleanup_unlocked "${username}"
}

sshws_path_prefix() {
  printf '\n'
}

sshws_token_valid() {
  local token="${1:-}"
  [[ "${token}" =~ ^[A-Fa-f0-9]{10}$ ]]
}

sshws_path_from_token() {
  local token="${1:-}"
  if ! sshws_token_valid "${token}"; then
    return 1
  fi
  local prefix
  prefix="$(sshws_path_prefix)"
  if [[ -n "${prefix}" ]]; then
    printf '%s/%s\n' "${prefix}" "${token}"
  else
    printf '/%s\n' "${token}"
  fi
}

sshws_alt_path_from_token() {
  local token="${1:-}"
  if ! sshws_token_valid "${token}"; then
    return 1
  fi
  printf '/bebas/%s\n' "${token,,}"
}

ssh_user_state_token_get() {
  local username="${1:-}"
  local state_file
  ssh_state_dirs_prepare
  state_file="$(ssh_user_state_resolve_file "${username}")"
  [[ -s "${state_file}" ]] || {
    echo ""
    return 0
  }
  need_python3
  python3 - <<'PY' "${state_file}" 2>/dev/null || true
import json
import re
import sys

path = sys.argv[1]
token = ""
try:
  with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
  if isinstance(data, dict):
    token = str(data.get("sshws_token") or "").strip()
except Exception:
  token = ""

if re.fullmatch(r"[A-Fa-f0-9]{10}", token):
  print(token.lower())
else:
  print("")
PY
}

ssh_user_state_ensure_token() {
  local username="${1:-}"
  local state_file tmp lock_file
  ssh_state_dirs_prepare
  state_file="$(ssh_user_state_resolve_file "${username}")"
  [[ -f "${state_file}" ]] || return 1
  ssh_qac_lock_prepare
  lock_file="$(ssh_qac_lock_file)"
  need_python3

  if have_cmd flock; then
    (
      flock -x 200
      python3 - <<'PY' "${state_file}"
import json
import os
import re
import secrets
import sys
import tempfile

path = sys.argv[1]
try:
  with open(path, "r", encoding="utf-8") as f:
    payload = json.load(f)
  if not isinstance(payload, dict):
    payload = {}
except Exception:
  payload = {}

def pick_unique_token(root_dir, current_path, current_token):
  seen = set()
  current_real = os.path.realpath(current_path)
  try:
    names = sorted(os.listdir(root_dir), key=str.lower)
  except Exception:
    names = []
  for name in names:
    if name.startswith(".") or not name.endswith(".json"):
      continue
    entry = os.path.join(root_dir, name)
    if os.path.realpath(entry) == current_real:
      continue
    try:
      loaded = json.load(open(entry, "r", encoding="utf-8"))
      if not isinstance(loaded, dict):
        continue
    except Exception:
      continue
    tok = str(loaded.get("sshws_token") or "").strip().lower()
    if re.fullmatch(r"[a-f0-9]{10}", tok):
      seen.add(tok)
  tok = str(current_token or "").strip().lower()
  if re.fullmatch(r"[a-f0-9]{10}", tok) and tok not in seen:
    return tok
  for _ in range(256):
    tok = secrets.token_hex(5)
    if tok not in seen:
      return tok
  raise RuntimeError("failed to allocate unique sshws token")

token = pick_unique_token(os.path.dirname(path) or ".", path, payload.get("sshws_token"))
if token != str(payload.get("sshws_token") or "").strip().lower():
  payload["sshws_token"] = token
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

print(token)
PY
    ) 200>"${lock_file}"
    return $?
  fi

  python3 - <<'PY' "${state_file}"
import json
import os
import re
import secrets
import sys
import tempfile

path = sys.argv[1]
try:
  with open(path, "r", encoding="utf-8") as f:
    payload = json.load(f)
  if not isinstance(payload, dict):
    payload = {}
except Exception:
  payload = {}

def pick_unique_token(root_dir, current_path, current_token):
  seen = set()
  current_real = os.path.realpath(current_path)
  try:
    names = sorted(os.listdir(root_dir), key=str.lower)
  except Exception:
    names = []
  for name in names:
    if name.startswith(".") or not name.endswith(".json"):
      continue
    entry = os.path.join(root_dir, name)
    if os.path.realpath(entry) == current_real:
      continue
    try:
      loaded = json.load(open(entry, "r", encoding="utf-8"))
      if not isinstance(loaded, dict):
        continue
    except Exception:
      continue
    tok = str(loaded.get("sshws_token") or "").strip().lower()
    if re.fullmatch(r"[a-f0-9]{10}", tok):
      seen.add(tok)
  tok = str(current_token or "").strip().lower()
  if re.fullmatch(r"[a-f0-9]{10}", tok) and tok not in seen:
    return tok
  for _ in range(256):
    tok = secrets.token_hex(5)
    if tok not in seen:
      return tok
  raise RuntimeError("failed to allocate unique sshws token")

token = pick_unique_token(os.path.dirname(path) or ".", path, payload.get("sshws_token"))
if token != str(payload.get("sshws_token") or "").strip().lower():
  payload["sshws_token"] = token
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

print(token)
PY
}

sshws_probe_path_pick() {
  ssh_state_dirs_prepare
  need_python3
  python3 - <<'PY' "${SSH_USERS_STATE_DIR}" 2>/dev/null || true
import json
import os
import re
import sys

root = sys.argv[1]
prefix = ""
token = ""
if os.path.isdir(root):
  for name in sorted(os.listdir(root), key=str.lower):
    if not name.endswith(".json"):
      continue
    path = os.path.join(root, name)
    try:
      with open(path, "r", encoding="utf-8") as f:
        payload = json.load(f)
      if not isinstance(payload, dict):
        continue
    except Exception:
      continue
    candidate = str(payload.get("sshws_token") or "").strip().lower()
    if re.fullmatch(r"[a-f0-9]{10}", candidate):
      token = candidate
      break
if token:
  if prefix:
    print(f"{prefix}/{token}")
  else:
    print(f"/{token}")
else:
  if prefix:
    print(f"{prefix}/diagnostic-probe")
  else:
    print("/diagnostic-probe")
PY
}

ssh_user_state_created_at_get() {
  local username="${1:-}"
  local state_file
  ssh_state_dirs_prepare
  state_file="$(ssh_user_state_resolve_file "${username}")"
  [[ -s "${state_file}" ]] || {
    echo ""
    return 0
  }
  need_python3
  python3 - <<'PY' "${state_file}" 2>/dev/null || true
import json, sys
path = sys.argv[1]
try:
  with open(path, "r", encoding="utf-8") as f:
    d = json.load(f)
  print(str(d.get("created_at") or "").strip())
except Exception:
  print("")
PY
}

ssh_user_state_write() {
  local username="${1:-}" created_at="${2:-}" expired_at="${3:-}"
  local state_file tmp
  ssh_state_dirs_prepare
  state_file="$(ssh_user_state_resolve_file "${username}")"
  ssh_qac_lock_prepare
  local lock_file
  lock_file="$(ssh_qac_lock_file)"

  if have_cmd flock; then
    (
      flock -x 200
      tmp="$(mktemp "${SSH_USERS_STATE_DIR}/.${username}.XXXXXX")" || exit 1
      need_python3
      if ! python3 - <<'PY' "${state_file}" "${username}" "${created_at}" "${expired_at}" > "${tmp}"; then
import datetime
import json
import os
import re
import secrets
import sys

state_file, username, created_at, expired_at = sys.argv[1:5]

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

def to_bool(v):
  if isinstance(v, bool):
    return v
  if isinstance(v, (int, float)):
    return bool(v)
  s = str(v or "").strip().lower()
  return s in ("1", "true", "yes", "on", "y")

def norm_date(v):
  s = str(v or "").strip()
  if not s:
    return ""
  return s[:10]

def pick_unique_token(root_dir, current_path, current_token):
  seen = set()
  current_real = os.path.realpath(current_path)
  try:
    names = sorted(os.listdir(root_dir), key=str.lower)
  except Exception:
    names = []
  for name in names:
    if name.startswith(".") or not name.endswith(".json"):
      continue
    entry = os.path.join(root_dir, name)
    if os.path.realpath(entry) == current_real:
      continue
    try:
      loaded = json.load(open(entry, "r", encoding="utf-8"))
      if not isinstance(loaded, dict):
        continue
    except Exception:
      continue
    tok = str(loaded.get("sshws_token") or "").strip().lower()
    if re.fullmatch(r"[a-f0-9]{10}", tok):
      seen.add(tok)
  tok = str(current_token or "").strip().lower()
  if re.fullmatch(r"[a-f0-9]{10}", tok) and tok not in seen:
    return tok
  for _ in range(256):
    tok = secrets.token_hex(5)
    if tok not in seen:
      return tok
  raise RuntimeError("failed to allocate unique sshws token")

payload = {}
if os.path.isfile(state_file):
  try:
    loaded = json.load(open(state_file, "r", encoding="utf-8"))
    if isinstance(loaded, dict):
      payload = loaded
  except Exception:
    payload = {}

status_raw = payload.get("status")
status = status_raw if isinstance(status_raw, dict) else {}
network_raw = payload.get("network")
network = network_raw if isinstance(network_raw, dict) else {}
network_raw = payload.get("network")
network = network_raw if isinstance(network_raw, dict) else {}

quota_limit = to_int(payload.get("quota_limit"), 0)
if quota_limit < 0:
  quota_limit = 0

quota_used = to_int(payload.get("quota_used"), 0)
if quota_used < 0:
  quota_used = 0

speed_down = to_float(status.get("speed_down_mbit"), 0.0)
speed_up = to_float(status.get("speed_up_mbit"), 0.0)
if speed_down < 0:
  speed_down = 0.0
if speed_up < 0:
  speed_up = 0.0

ip_limit = to_int(status.get("ip_limit"), 0)
if ip_limit < 0:
  ip_limit = 0

unit = str(payload.get("quota_unit") or "binary").strip().lower()
if unit not in ("binary", "decimal"):
  unit = "binary"

created = str(created_at or "").strip() or str(payload.get("created_at") or "").strip()
if created:
  created = created[:10]
if not created:
  created = datetime.datetime.now().strftime("%Y-%m-%d")

expired = norm_date(expired_at) or norm_date(payload.get("expired_at")) or "-"
token = pick_unique_token(os.path.dirname(state_file) or ".", state_file, payload.get("sshws_token"))

payload["managed_by"] = "autoscript-manage"
payload["username"] = username
payload["protocol"] = "ssh"
payload["created_at"] = created
payload["expired_at"] = expired
payload["sshws_token"] = token
payload["quota_limit"] = quota_limit
payload["quota_unit"] = unit
payload["quota_used"] = quota_used
payload["status"] = {
  "manual_block": to_bool(status.get("manual_block")),
  "quota_exhausted": to_bool(status.get("quota_exhausted")),
  "ip_limit_enabled": to_bool(status.get("ip_limit_enabled")),
  "ip_limit": ip_limit,
  "ip_limit_locked": to_bool(status.get("ip_limit_locked")),
  "ip_limit_metric": to_int(status.get("ip_limit_metric"), 0),
  "distinct_ip_count": to_int(status.get("distinct_ip_count"), 0),
  "distinct_ips": status.get("distinct_ips") if isinstance(status.get("distinct_ips"), list) else [],
  "active_sessions_total": to_int(status.get("active_sessions_total"), 0),
  "active_sessions_runtime": to_int(status.get("active_sessions_runtime"), 0),
  "active_sessions_dropbear": to_int(status.get("active_sessions_dropbear"), 0),
  "speed_limit_enabled": to_bool(status.get("speed_limit_enabled")),
  "speed_down_mbit": speed_down,
  "speed_up_mbit": speed_up,
  "lock_reason": str(status.get("lock_reason") or "").strip().lower(),
  "account_locked": to_bool(status.get("account_locked")),
  "lock_owner": str(status.get("lock_owner") or "").strip(),
  "lock_shell_restore": str(status.get("lock_shell_restore") or "").strip(),
}
payload["bootstrap_review_needed"] = to_bool(payload.get("bootstrap_review_needed"))
payload["bootstrap_source"] = str(payload.get("bootstrap_source") or "").strip()

print(json.dumps(payload, ensure_ascii=False, indent=2))
PY
        rm -f "${tmp}" >/dev/null 2>&1 || true
        exit 1
      fi
      printf '\n' >> "${tmp}"
      install -m 600 "${tmp}" "${state_file}" || {
        rm -f "${tmp}" >/dev/null 2>&1 || true
        exit 1
      }
      rm -f "${tmp}" >/dev/null 2>&1 || true
      exit 0
    ) 200>"${lock_file}"
    return $?
  fi

  tmp="$(mktemp "${SSH_USERS_STATE_DIR}/.${username}.XXXXXX")" || return 1
  need_python3
  if ! python3 - <<'PY' "${state_file}" "${username}" "${created_at}" "${expired_at}" > "${tmp}"; then
import datetime
import json
import os
import re
import secrets
import sys

state_file, username, created_at, expired_at = sys.argv[1:5]

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

def to_bool(v):
  if isinstance(v, bool):
    return v
  if isinstance(v, (int, float)):
    return bool(v)
  s = str(v or "").strip().lower()
  return s in ("1", "true", "yes", "on", "y")

def norm_date(v):
  s = str(v or "").strip()
  if not s:
    return ""
  return s[:10]

def pick_unique_token(root_dir, current_path, current_token):
  seen = set()
  current_real = os.path.realpath(current_path)
  try:
    names = sorted(os.listdir(root_dir), key=str.lower)
  except Exception:
    names = []
  for name in names:
    if name.startswith(".") or not name.endswith(".json"):
      continue
    entry = os.path.join(root_dir, name)
    if os.path.realpath(entry) == current_real:
      continue
    try:
      loaded = json.load(open(entry, "r", encoding="utf-8"))
      if not isinstance(loaded, dict):
        continue
    except Exception:
      continue
    tok = str(loaded.get("sshws_token") or "").strip().lower()
    if re.fullmatch(r"[a-f0-9]{10}", tok):
      seen.add(tok)
  tok = str(current_token or "").strip().lower()
  if re.fullmatch(r"[a-f0-9]{10}", tok) and tok not in seen:
    return tok
  for _ in range(256):
    tok = secrets.token_hex(5)
    if tok not in seen:
      return tok
  raise RuntimeError("failed to allocate unique sshws token")

payload = {}
if os.path.isfile(state_file):
  try:
    loaded = json.load(open(state_file, "r", encoding="utf-8"))
    if isinstance(loaded, dict):
      payload = loaded
  except Exception:
    payload = {}

status_raw = payload.get("status")
status = status_raw if isinstance(status_raw, dict) else {}
network_raw = payload.get("network")
network = network_raw if isinstance(network_raw, dict) else {}

quota_limit = to_int(payload.get("quota_limit"), 0)
if quota_limit < 0:
  quota_limit = 0

quota_used = to_int(payload.get("quota_used"), 0)
if quota_used < 0:
  quota_used = 0

speed_down = to_float(status.get("speed_down_mbit"), 0.0)
speed_up = to_float(status.get("speed_up_mbit"), 0.0)
if speed_down < 0:
  speed_down = 0.0
if speed_up < 0:
  speed_up = 0.0

ip_limit = to_int(status.get("ip_limit"), 0)
if ip_limit < 0:
  ip_limit = 0

unit = str(payload.get("quota_unit") or "binary").strip().lower()
if unit not in ("binary", "decimal"):
  unit = "binary"

created = str(created_at or "").strip() or str(payload.get("created_at") or "").strip()
if created:
  created = created[:10]
if not created:
  created = datetime.datetime.now().strftime("%Y-%m-%d")

expired = norm_date(expired_at) or norm_date(payload.get("expired_at")) or "-"
token = pick_unique_token(os.path.dirname(state_file) or ".", state_file, payload.get("sshws_token"))

payload["managed_by"] = "autoscript-manage"
payload["username"] = username
payload["protocol"] = "ssh"
payload["created_at"] = created
payload["expired_at"] = expired
payload["sshws_token"] = token
payload["quota_limit"] = quota_limit
payload["quota_unit"] = unit
payload["quota_used"] = quota_used
payload["status"] = {
  "manual_block": to_bool(status.get("manual_block")),
  "quota_exhausted": to_bool(status.get("quota_exhausted")),
  "ip_limit_enabled": to_bool(status.get("ip_limit_enabled")),
  "ip_limit": ip_limit,
  "ip_limit_locked": to_bool(status.get("ip_limit_locked")),
  "ip_limit_metric": to_int(status.get("ip_limit_metric"), 0),
  "distinct_ip_count": to_int(status.get("distinct_ip_count"), 0),
  "distinct_ips": status.get("distinct_ips") if isinstance(status.get("distinct_ips"), list) else [],
  "active_sessions_total": to_int(status.get("active_sessions_total"), 0),
  "active_sessions_runtime": to_int(status.get("active_sessions_runtime"), 0),
  "active_sessions_dropbear": to_int(status.get("active_sessions_dropbear"), 0),
  "speed_limit_enabled": to_bool(status.get("speed_limit_enabled")),
  "speed_down_mbit": speed_down,
  "speed_up_mbit": speed_up,
  "lock_reason": str(status.get("lock_reason") or "").strip().lower(),
  "account_locked": to_bool(status.get("account_locked")),
  "lock_owner": str(status.get("lock_owner") or "").strip(),
  "lock_shell_restore": str(status.get("lock_shell_restore") or "").strip(),
}
payload["bootstrap_review_needed"] = to_bool(payload.get("bootstrap_review_needed"))
payload["bootstrap_source"] = str(payload.get("bootstrap_source") or "").strip()

print(json.dumps(payload, ensure_ascii=False, indent=2))
PY
    rm -f "${tmp}" >/dev/null 2>&1 || true
    return 1
  fi
  printf '\n' >> "${tmp}"
  install -m 600 "${tmp}" "${state_file}" || {
    rm -f "${tmp}" >/dev/null 2>&1 || true
    return 1
  }
  rm -f "${tmp}" >/dev/null 2>&1 || true
  return 0
}

ssh_account_info_password_get() {
  local username="${1:-}"
  if [[ "$(ssh_account_info_password_mode)" != "store" ]]; then
    echo "-"
    return 0
  fi
  local acc_file
  acc_file="$(ssh_account_info_file "${username}")"
  [[ -f "${acc_file}" ]] || {
    echo "-"
    return 0
  }
  awk '/^Password[[:space:]]*:/{sub(/^Password[[:space:]]*:[[:space:]]*/, ""); print; found=1; exit} END{if(!found) print "-"}' "${acc_file}" 2>/dev/null
}

ssh_previous_password_get() {
  local username="${1:-}"
  local password
  password="$(zivpn_password_read "${username}")"
  if [[ -n "${password}" && "${password}" != "-" ]]; then
    echo "${password}"
    return 0
  fi
  ssh_account_info_password_get "${username}"
}

ssh_qac_traffic_enforcement_ready() {
  local proxy_svc="${SSHWS_PROXY_SERVICE:-sshws-proxy}"
  [[ -x /usr/local/bin/sshws-proxy ]] && return 0
  [[ -f "/etc/systemd/system/${proxy_svc}.service" ]] && return 0
  [[ -f "/lib/systemd/system/${proxy_svc}.service" ]] && return 0
  return 1
}

ssh_qac_traffic_scope_label() {
  if ssh_qac_traffic_enforcement_ready; then
    echo "Unified SSH QAC"
  else
    echo "Metadata only (SSH runtime not installed)"
  fi
}

ssh_qac_traffic_scope_line() {
  if ssh_qac_traffic_enforcement_ready; then
    local provider active
    provider="$(edge_runtime_get_env EDGE_PROVIDER 2>/dev/null || echo "none")"
    active="$(edge_runtime_get_env EDGE_ACTIVATE_RUNTIME 2>/dev/null || echo "false")"
    if [[ "${provider}" == "go" ]]; then
      echo "Quota, speed limit, dan IP/Login limit berlaku sebagai satu sistem SSH pada SSH WS, SSH SSL/TLS, dan SSH Direct selama transport melewati Edge Gateway aktif. Pada provider go, trafik SSH SSL/TLS publik mengikuti jalur backend SSH klasik setelah terminasi TLS, sedangkan SSH WS memakai limiter token-aware milik sshws-proxy. Native sshd port 22 tetap di luar scope traffic enforcement."
      return 0
    fi
    echo "Quota, speed limit, dan IP/Login limit berlaku sebagai satu sistem SSH pada SSH WS, SSH SSL/TLS, dan SSH Direct selama transport melewati Edge Gateway aktif. Native sshd port 22 tetap di luar scope traffic enforcement."
  else
    echo "SSH runtime belum terpasang; quota/IP-login/speed SSH masih metadata dan native sshd port 22 tidak dihitung atau di-throttle."
  fi
}

edge_runtime_enabled_for_public_ports() {
  local provider active
  provider="$(edge_runtime_get_env EDGE_PROVIDER 2>/dev/null || echo "none")"
  active="$(edge_runtime_get_env EDGE_ACTIVATE_RUNTIME 2>/dev/null || echo "false")"
  [[ "${provider}" != "none" ]] || return 1
  case "${active}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
  esac
  return 1
}

ssh_ws_public_ports_label() {
  local http_port tls_port
  http_port="$(edge_runtime_get_env EDGE_PUBLIC_HTTP_PORT 2>/dev/null || echo "80")"
  tls_port="$(edge_runtime_get_env EDGE_PUBLIC_TLS_PORT 2>/dev/null || echo "443")"
  if [[ -n "${tls_port}" && -n "${http_port}" ]]; then
    printf '%s & %s\n' "${tls_port}" "${http_port}"
  else
    printf '%s\n' "443 & 80"
  fi
}

ssh_ssl_tls_public_ports_label() {
  if edge_runtime_enabled_for_public_ports; then
    ssh_ws_public_ports_label
  else
    printf '%s\n' "-"
  fi
}

ssh_direct_public_ports_label() {
  if edge_runtime_enabled_for_public_ports; then
    ssh_ws_public_ports_label
  else
    printf '%s\n' "-"
  fi
}

ssh_account_info_write() {
  # args: username password quota_bytes expired_at created_at ip_enabled ip_limit speed_enabled speed_down speed_up sshws_token [output_file_override] [domain_override] [ip_override] [isp_override] [country_override]
  local username="${1:-}"
  local password_raw="${2:-}"
  local password_mode password_out
  local quota_bytes="${3:-0}"
  local expired_at="${4:--}"
  local created_at="${5:-}"
  local ip_enabled="${6:-false}"
  local ip_limit="${7:-0}"
  local speed_enabled="${8:-false}"
  local speed_down="${9:-0}"
  local speed_up="${10:-0}"
  local sshws_token="${11:-}"
  local output_file_override="${12:-}"
  local domain_override="${13:-}"
  local ip_override="${14:-}"
  local isp_override="${15:-}"
  local country_override="${16:-}"

  ssh_state_dirs_prepare
  password_mode="$(ssh_account_info_password_mode)"
  if [[ "${password_mode}" == "store" ]]; then
    password_out="${password_raw:-"-"}"
  else
    # Pada mode mask, selalu tampil hidden agar konsisten di setiap refresh.
    password_out="(hidden)"
  fi

  local acc_file domain ip geo_ip isp country quota_limit_disp expired_disp valid_until created_disp ip_disp speed_disp sshws_path sshws_alt_path sshws_main_disp sshws_ports_disp ssh_direct_ports_disp ssh_ssl_tls_ports_disp badvpn_port_disp geo
  local running_label_width running_ssh_ws_path running_ssh_ws_alt running_ssh_ws_port running_ssh_direct running_ssh_ssl_tls running_badvpn
  acc_file="$(ssh_account_info_file "${username}")"
  [[ -n "${output_file_override}" ]] && acc_file="${output_file_override}"
  domain="$(normalize_domain_token "${domain_override}")"
  [[ -n "${domain}" ]] || domain="$(detect_domain)"
  ip="$(normalize_ip_token "${ip_override}")"
  if [[ -z "${ip}" ]]; then
    ip="$(main_info_ip_quiet_get)"
    [[ -n "${ip}" ]] || ip="$(detect_public_ip)"
  fi
  isp="${isp_override}"
  country="${country_override}"
  if [[ -z "${isp}" || -z "${country}" ]]; then
    geo="$(main_info_geo_lookup "${ip}")"
    IFS='|' read -r geo_ip isp_geo country_geo <<<"${geo}"
    [[ -n "${geo_ip}" && "${geo_ip}" != "-" ]] && ip="${geo_ip}"
    [[ -n "${isp}" ]] || isp="${isp_geo:-}"
    [[ -n "${country}" ]] || country="${country_geo:-}"
  fi
  [[ -n "${domain}" ]] || domain="-"
  [[ -n "${ip}" ]] || ip="-"
  [[ -n "${isp}" ]] || isp="-"
  [[ -n "${country}" ]] || country="-"
  [[ -n "${created_at}" ]] || created_at="$(date '+%Y-%m-%d')"
  [[ -n "${expired_at}" ]] || expired_at="-"

  quota_limit_disp="$(python3 - <<'PY' "${quota_bytes}"
import sys
def fmt(v):
  s=f"{v:.3f}".rstrip("0").rstrip(".")
  return s if s else "0"
try:
  b=int(float(sys.argv[1]))
except Exception:
  b=0
if b < 0:
  b = 0
print(f"{fmt(b/(1024**3))} GB")
PY
)"

  created_disp="$(python3 - <<'PY' "${created_at}"
import sys
from datetime import datetime
v = (sys.argv[1] or "").strip()
if not v:
  print(datetime.now().strftime("%Y-%m-%d"))
  raise SystemExit(0)
for fmt in ("%Y-%m-%d %H:%M", "%Y-%m-%d", "%Y-%m-%d %H:%M:%S"):
  try:
    dt = datetime.strptime(v[:len(fmt)], fmt)
    print(dt.strftime("%Y-%m-%d"))
    raise SystemExit(0)
  except Exception:
    pass
if len(v) >= 10 and v[4:5] == "-" and v[7:8] == "-":
  print(v[:10])
else:
  print(v)
PY
)"

  valid_until="${expired_at}"
  expired_disp="$(python3 - <<'PY' "${expired_at}"
import sys
from datetime import datetime
v = (sys.argv[1] or "").strip()
if not v or v == "-":
  print("unlimited")
  raise SystemExit(0)
try:
  dt = datetime.strptime(v[:10], "%Y-%m-%d").date()
  today = datetime.now().date()
  days = (dt - today).days
  if days < 0:
    days = 0
  print(f"{days} days")
except Exception:
  print("unknown")
PY
)"

  if [[ "${ip_enabled}" == "true" ]]; then
    if [[ "${ip_limit}" =~ ^[0-9]+$ ]] && (( ip_limit > 0 )); then
      ip_disp="ON (${ip_limit})"
    else
      ip_disp="ON"
    fi
  else
    ip_disp="OFF"
  fi

  if [[ "${speed_enabled}" == "true" ]]; then
    speed_disp="ON (DOWN ${speed_down} Mbps | UP ${speed_up} Mbps)"
  else
    speed_disp="OFF"
  fi

  if sshws_token_valid "${sshws_token}"; then
    sshws_token="${sshws_token,,}"
    sshws_path="$(sshws_path_from_token "${sshws_token}")"
    sshws_alt_path="$(sshws_alt_path_from_token "${sshws_token}" 2>/dev/null || true)"
    sshws_main_disp="${sshws_path}"
  else
    sshws_path="-"
    sshws_alt_path="-"
    sshws_main_disp="-"
  fi
  if [[ "${sshws_alt_path}" == /bebas/* ]]; then
    sshws_alt_path="/<bebas>/${sshws_token}"
  fi
  sshws_ports_disp="$(ssh_ws_public_ports_label)"
  ssh_direct_ports_disp="$(ssh_direct_public_ports_label)"
  ssh_ssl_tls_ports_disp="$(ssh_ssl_tls_public_ports_label)"
  badvpn_port_disp="$(badvpn_public_port_label)"
  local zivpn_block=""
  running_label_width=16
  printf -v running_ssh_ws_path '%-*s : %s' "${running_label_width}" "SSH WS Path" "${sshws_main_disp}"
  printf -v running_ssh_ws_alt '%-*s : %s' "${running_label_width}" "SSH WS Path Alt" "${sshws_alt_path}"
  printf -v running_ssh_ws_port '%-*s : %s' "${running_label_width}" "SSH WS Port" "${sshws_ports_disp}"
  printf -v running_ssh_direct '%-*s : %s' "${running_label_width}" "SSH Direct Port" "${ssh_direct_ports_disp}"
  printf -v running_ssh_ssl_tls '%-*s : %s' "${running_label_width}" "SSH SSL/TLS Port" "${ssh_ssl_tls_ports_disp}"
  printf -v running_badvpn '%-*s : %s' "${running_label_width}" "BadVPN UDPGW" "${badvpn_port_disp}"
  if zivpn_account_info_enabled; then
    local zivpn_password_line
    if zivpn_user_password_synced "${username}"; then
      printf -v zivpn_password_line '%-*s : %s' "${running_label_width}" "ZIVPN Password" "same as SSH password"
    else
      printf -v zivpn_password_line '%-*s : %s' "${running_label_width}" "ZIVPN Password" "not synced to runtime"
    fi
    zivpn_block=$'\n'"=== ZIVPN UDP ==="$'\n'"${zivpn_password_line}"
  fi
  local tmp_acc_file=""
  mkdir -p "$(dirname "${acc_file}")" 2>/dev/null || return 1
  tmp_acc_file="$(mktemp "${acc_file}.tmp.XXXXXX" 2>/dev/null || true)"
  [[ -n "${tmp_acc_file}" ]] || tmp_acc_file="${acc_file}.tmp.$$"
  if ! cat > "${tmp_acc_file}" <<EOF
=== SSH ACCOUNT INFO ===
Domain      : ${domain}
IP          : ${ip}
ISP         : ${isp}
Country     : ${country}
Username    : ${username}
Password    : ${password_out}
Quota Limit : ${quota_limit_disp}
Expired     : ${expired_disp}
Valid Until : ${valid_until}
Created     : ${created_disp}
IP Limit    : ${ip_disp}
Speed Limit : ${speed_disp}

=== RUNNING ON PORT ===
${running_ssh_ws_path}
${running_ssh_ws_alt}
${running_ssh_ws_port}
${running_ssh_direct}
${running_ssh_ssl_tls}
${running_badvpn}
${zivpn_block}

=== STANDARD PAYLOAD ===
Payload WS:
    GET ${sshws_alt_path} HTTP/1.1[crlf]Host: [host_port][crlf]Upgrade: websocket[crlf]Connection: Keep-Alive[crlf][crlf]

Payload WSS:
    GET wss://[host]${sshws_alt_path} HTTP/1.1[crlf]Host: [host_port][crlf]Upgrade: websocket[crlf]Connection: Keep-Alive[crlf][crlf]
EOF
  then
    rm -f "${tmp_acc_file}" >/dev/null 2>&1 || true
    return 1
  fi
  chmod 600 "${tmp_acc_file}" >/dev/null 2>&1 || true
  if ! mv -f "${tmp_acc_file}" "${acc_file}" >/dev/null 2>&1; then
    rm -f "${tmp_acc_file}" >/dev/null 2>&1 || true
    return 1
  fi
  return 0
}

ssh_account_info_refresh_from_state() {
  # args: username [password_override] [output_file_override] [domain_override] [ip_override] [isp_override] [country_override]
  local username="${1:-}"
  local password_override="${2:-}"
  local output_file_override="${3:-}"
  local domain_override="${4:-}"
  local ip_override="${5:-}"
  local isp_override="${6:-}"
  local country_override="${7:-}"
  local qf
  qf="$(ssh_user_state_resolve_file "${username}")"
  [[ -f "${qf}" ]] || return 1

  local fields quota_bytes expired_at created_at ip_enabled ip_limit speed_enabled speed_down speed_up sshws_token password
  need_python3
  fields="$(python3 - <<'PY' "${qf}"
import json
import sys
p = sys.argv[1]
try:
  d = json.load(open(p, "r", encoding="utf-8"))
except Exception:
  d = {}
if not isinstance(d, dict):
  d = {}
s = d.get("status")
if not isinstance(s, dict):
  s = {}
def tb(v):
  if isinstance(v, bool):
    return "true" if v else "false"
  if isinstance(v, (int, float)):
    return "true" if bool(v) else "false"
  return "true" if str(v or "").strip().lower() in ("1", "true", "yes", "on", "y") else "false"
def ti(v, d=0):
  try:
    if v is None:
      return d
    if isinstance(v, bool):
      return int(v)
    if isinstance(v, (int, float)):
      return int(v)
    t = str(v).strip()
    if not t:
      return d
    return int(float(t))
  except Exception:
    return d
def tf(v, d=0.0):
  try:
    if v is None:
      return d
    if isinstance(v, bool):
      return float(int(v))
    if isinstance(v, (int, float)):
      return float(v)
    t = str(v).strip()
    if not t:
      return d
    return float(t)
  except Exception:
    return d
def fm(v):
  s = f"{float(v):.3f}".rstrip("0").rstrip(".")
  return s if s else "0"
print("|".join([
  str(max(0, ti(d.get("quota_limit"), 0))),
  str(d.get("expired_at") or "-")[:10] if str(d.get("expired_at") or "-").strip() else "-",
  str(d.get("created_at") or "-"),
  tb(s.get("ip_limit_enabled")),
  str(max(0, ti(s.get("ip_limit"), 0))),
  tb(s.get("speed_limit_enabled")),
  fm(max(0.0, tf(s.get("speed_down_mbit"), 0.0))),
  fm(max(0.0, tf(s.get("speed_up_mbit"), 0.0))),
  str(d.get("sshws_token") or "").strip().lower(),
]))
PY
)"
  IFS='|' read -r quota_bytes expired_at created_at ip_enabled ip_limit speed_enabled speed_down speed_up sshws_token <<<"${fields}"

  password="${password_override}"
  if [[ -z "${password}" ]]; then
    password="$(ssh_account_info_password_get "${username}")"
  fi

  if ! sshws_token_valid "${sshws_token}"; then
    sshws_token="$(ssh_user_state_ensure_token "${username}" 2>/dev/null || true)"
  fi

  ssh_account_info_write "${username}" "${password}" "${quota_bytes}" "${expired_at}" "${created_at}" "${ip_enabled}" "${ip_limit}" "${speed_enabled}" "${speed_down}" "${speed_up}" "${sshws_token}" "${output_file_override}" "${domain_override}" "${ip_override}" "${isp_override}" "${country_override}"
}

ssh_account_info_refresh_warn() {
  # args: username [password_override]
  local username="${1:-}"
  local password_override="${2:-}"
  if ! ssh_account_info_refresh_from_state "${username}" "${password_override}"; then
    warn "SSH ACCOUNT INFO belum sinkron untuk '${username}'."
    return 1
  fi
  return 0
}

ssh_linux_candidate_users_get() {
  need_python3
  python3 - <<'PY'
import pwd

SKIP_SHELL_SUFFIXES = ("nologin", "false")
for entry in pwd.getpwall():
  name = str(entry.pw_name or "").strip()
  shell = str(entry.pw_shell or "").strip()
  home = str(entry.pw_dir or "").strip()
  if not name or name == "root":
    continue
  if entry.pw_uid < 1000:
    continue
  if not shell or shell.endswith(SKIP_SHELL_SUFFIXES):
    continue
  if home and not home.startswith("/home/"):
    continue
  print(name)
PY
}

ssh_linux_account_expiry_get() {
  local username="${1:-}"
  local raw normalized
  [[ -n "${username}" ]] || return 1
  raw="$(chage -l "${username}" 2>/dev/null | awk -F': ' '/Account expires/{print $2; exit}' || true)"
  raw="$(printf '%s' "${raw}" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' || true)"
  case "${raw,,}" in
    ""|never|never\ expires)
      printf '%s\n' "-"
      return 0
      ;;
  esac
  normalized="$(date -d "${raw}" '+%Y-%m-%d' 2>/dev/null || true)"
  if [[ -n "${normalized}" ]]; then
    printf '%s\n' "${normalized}"
  else
    printf '%s\n' "-"
  fi
}

ssh_qac_metadata_bootstrap_if_missing() {
  local username="${1:-}"
  local qf="${2:-}"
  local created_at
  [[ -n "${username}" && -n "${qf}" ]] || return 1
  [[ -f "${qf}" ]] && return 0

  created_at="$(date '+%Y-%m-%d')"
  if ! ssh_user_state_write "${username}" "${created_at}" "-"; then
    return 1
  fi
  if ! ssh_qac_atomic_update_file "${qf}" bootstrap_marker_set "minimal-placeholder" >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

ssh_qac_bootstrap_status_get() {
  local qf="${1:-}"
  [[ -n "${qf}" && -f "${qf}" ]] || {
    printf 'false|\n'
    return 0
  }
  need_python3
  python3 - <<'PY' "${qf}"
import json
import sys

try:
  data = json.load(open(sys.argv[1], "r", encoding="utf-8"))
except Exception:
  print("false|")
  raise SystemExit(0)

flag = data.get("bootstrap_review_needed")
source = str(data.get("bootstrap_source") or "").strip()
if isinstance(flag, bool):
  needed = flag
elif isinstance(flag, (int, float)):
  needed = bool(flag)
else:
  needed = str(flag or "").strip().lower() in ("1", "true", "yes", "on", "y")
print(("true" if needed else "false") + "|" + source)
PY
}

ssh_pending_login_shell_get() {
  local shell="/usr/sbin/nologin"
  if have_cmd nologin; then
    shell="$(command -v nologin 2>/dev/null || printf '/usr/sbin/nologin')"
  fi
  printf '%s\n' "${shell}"
}

ssh_add_txn_linux_pending_contains() {
  local username="${1:-}"
  local txn_dir="" linux_created=""
  [[ -n "${username}" ]] || return 1
  mutation_txn_prepare || return 1
  while IFS= read -r -d '' txn_dir; do
    [[ -n "${txn_dir}" ]] || continue
    linux_created="$(mutation_txn_field_read "${txn_dir}" linux_created 2>/dev/null || true)"
    if [[ "${linux_created}" != "true" ]]; then
      return 0
    fi
  done < <(find "${MUTATION_TXN_DIR}" -maxdepth 1 -type d -name "ssh-add.${username}*" -print0 2>/dev/null | sort -z)
  return 1
}

ssh_collect_candidate_users() {
  # args: [include_linux=true|false]
  local include_linux="${1:-true}"
  ssh_state_dirs_prepare

  local -A seen_users=()
  local username="" name=""

  while IFS= read -r username; do
    [[ -n "${username}" ]] || continue
    username="${username%.json}"
    username="${username%@ssh}"
    [[ -n "${username}" ]] || continue
    if ssh_add_txn_linux_pending_contains "${username}"; then
      continue
    fi
    if [[ -n "${seen_users["${username}"]+x}" ]]; then
      continue
    fi
    seen_users["${username}"]=1
    printf '%s\n' "${username}"
  done < <(find "${SSH_USERS_STATE_DIR}" -maxdepth 1 -type f -name '*.json' -printf '%f\n' 2>/dev/null | sort -u)

  while IFS= read -r name; do
    [[ -n "${name}" ]] || continue
    name="${name%.txt}"
    name="${name%@ssh}"
    [[ -n "${name}" ]] || continue
    if ssh_add_txn_linux_pending_contains "${name}"; then
      continue
    fi
    if [[ -n "${seen_users["${name}"]+x}" ]]; then
      continue
    fi
    seen_users["${name}"]=1
    printf '%s\n' "${name}"
  done < <(find "${SSH_ACCOUNT_DIR}" -maxdepth 1 -type f -name '*.txt' -printf '%f\n' 2>/dev/null | sort -u)

  while IFS= read -r name; do
    [[ -n "${name}" ]] || continue
    name="${name%.pass}"
    name="${name%@ssh}"
    [[ -n "${name}" ]] || continue
    if ssh_add_txn_linux_pending_contains "${name}"; then
      continue
    fi
    if [[ -n "${seen_users["${name}"]+x}" ]]; then
      continue
    fi
    seen_users["${name}"]=1
    printf '%s\n' "${name}"
  done < <(find "${ZIVPN_PASSWORDS_DIR}" -maxdepth 1 -type f -name '*.pass' -printf '%f\n' 2>/dev/null | sort -u)

  if [[ "${include_linux}" == "true" ]]; then
    while IFS= read -r name; do
      [[ -n "${name}" ]] || continue
      if ssh_add_txn_linux_pending_contains "${name}"; then
        continue
      fi
      if [[ -n "${seen_users["${name}"]+x}" ]]; then
        continue
      fi
      seen_users["${name}"]=1
      printf '%s\n' "${name}"
    done < <(ssh_linux_candidate_users_get 2>/dev/null || true)
  fi
}

ssh_pick_managed_user() {
  local -n _out_ref="$1"
  _out_ref=""

  ssh_state_dirs_prepare

  local -a users=()
  local name=""
  while IFS= read -r name; do
    [[ -n "${name}" ]] || continue
    users+=("${name}")
  done < <(ssh_collect_candidate_users false)

  if (( ${#users[@]} > 1 )); then
    IFS=$'\n' users=($(printf '%s\n' "${users[@]}" | sort -u))
    unset IFS
  fi

  if (( ${#users[@]} == 0 )); then
    warn "Belum ada akun SSH managed yang bisa dipilih dari menu ini."
    return 1
  fi

  local i
  echo "Pilih akun SSH:"
  for i in "${!users[@]}"; do
    printf "  %d) %s\n" "$((i + 1))" "${users[$i]}"
  done

  local pick
  while true; do
    if ! read -r -p "Nomor akun (1-${#users[@]}/kembali): " pick; then
      echo
      return 1
    fi
    if is_back_choice "${pick}"; then
      return 1
    fi
    [[ "${pick}" =~ ^[0-9]+$ ]] || { warn "Input harus angka."; continue; }
    if (( pick < 1 || pick > ${#users[@]} )); then
      warn "Di luar range."
      continue
    fi
    _out_ref="${users[$((pick - 1))]}"
    return 0
  done
}

ssh_read_password_confirm() {
  local -n _out_ref="$1"
  _out_ref=""
  local p1="" p2=""
  if ! read -r -s -p "Password SSH: " p1; then
    echo
    return 1
  fi
  echo
  if [[ -z "${p1}" || ${#p1} -lt 6 ]]; then
    warn "Password minimal 6 karakter."
    return 1
  fi
  if ! read -r -s -p "Ulangi password: " p2; then
    echo
    return 1
  fi
  echo
  if [[ "${p1}" != "${p2}" ]]; then
    warn "Password tidak sama."
    return 1
  fi
  _out_ref="${p1}"
  return 0
}

ssh_apply_password() {
  local username="${1:-}"
  local password="${2:-}"
  printf '%s:%s\n' "${username}" "${password}" | chpasswd >/dev/null 2>&1
}

ssh_apply_expiry() {
  local username="${1:-}"
  local expiry="${2:-}"
  [[ -n "${username}" ]] || return 1
  case "${expiry}" in
    ""|"-"|never|Never|unlimited|Unlimited)
      chage -E -1 "${username}" >/dev/null 2>&1
      ;;
    *)
      chage -E "${expiry}" "${username}" >/dev/null 2>&1
      ;;
  esac
}

ssh_strict_date_ymd_normalize() {
  local raw="${1:-}"
  need_python3
  python3 - <<'PY' "${raw}"
import sys
from datetime import datetime

value = str(sys.argv[1] or "").strip()
try:
    dt = datetime.strptime(value, "%Y-%m-%d")
except Exception:
    raise SystemExit(1)
print(dt.strftime("%Y-%m-%d"))
PY
}

ssh_user_state_expired_at_get() {
  local username="${1:-}"
  local qf
  qf="$(ssh_user_state_resolve_file "${username}")"
  [[ -f "${qf}" ]] || return 1

  need_python3
  python3 - <<'PY' "${qf}"
import json
import sys

path = sys.argv[1]
try:
  data = json.load(open(path, "r", encoding="utf-8"))
except Exception:
  data = {}

if not isinstance(data, dict):
  data = {}

value = str(data.get("expired_at") or "").strip()
if not value or value == "-":
  print("-")
else:
  print(value[:10])
PY
}

ssh_optional_file_snapshot_create() {
  # args: path snap_dir out_mode_var out_backup_var
  local path="${1:-}"
  local snap_dir="${2:-}"
  local __mode_var="${3:-}"
  local __backup_var="${4:-}"
  local mode="absent"
  local backup=""

  if [[ -e "${path}" || -L "${path}" ]]; then
    backup="$(mktemp "${snap_dir}/snapshot.XXXXXX" 2>/dev/null || true)"
    [[ -n "${backup}" ]] || return 1
    if ! cp -a "${path}" "${backup}" 2>/dev/null; then
      rm -f -- "${backup}" >/dev/null 2>&1 || true
      return 1
    fi
    mode="file"
  fi

  [[ -n "${__mode_var}" ]] && printf -v "${__mode_var}" '%s' "${mode}"
  [[ -n "${__backup_var}" ]] && printf -v "${__backup_var}" '%s' "${backup}"
  return 0
}

ssh_optional_file_snapshot_restore() {
  # args: mode backup_file target_file [chmod_mode]
  local mode="${1:-absent}"
  local backup="${2:-}"
  local target="${3:-}"
  local chmod_mode="${4:-600}"
  [[ -n "${target}" ]] || return 1

  case "${mode}" in
    file)
      [[ -n "${backup}" && -e "${backup}" ]] || return 1
      mkdir -p "$(dirname "${target}")" 2>/dev/null || true
      cp -a "${backup}" "${target}" || return 1
      chmod "${chmod_mode}" "${target}" 2>/dev/null || true
      ;;
    absent)
      if [[ -e "${target}" || -L "${target}" ]]; then
        rm -f "${target}" || return 1
      fi
      ;;
    *)
      return 1
      ;;
  esac
  return 0
}

ssh_password_reset_rollback() {
  local username="${1:-}"
  local previous_password="${2:-}"
  local account_mode="${3:-absent}"
  local account_backup="${4:-}"
  local account_file="${5:-}"
  local zivpn_mode="${6:-absent}"
  local zivpn_backup="${7:-}"
  local zivpn_file="${8:-}"
  [[ -n "${username}" ]] || {
    echo "username rollback kosong"
    return 1
  }
  if [[ -z "${previous_password}" || "${previous_password}" == "-" ]]; then
    echo "password lama tidak tersedia untuk rollback"
    return 1
  fi
  if ! ssh_apply_password "${username}" "${previous_password}"; then
    echo "rollback Linux password gagal"
    return 1
  fi
  local rollback_notes=""
  if [[ -n "${account_file}" ]]; then
    if ! ssh_optional_file_snapshot_restore "${account_mode}" "${account_backup}" "${account_file}" 600; then
      rollback_notes="account info rollback gagal"
    fi
  elif ! ssh_account_info_refresh_from_state "${username}" "${previous_password}"; then
    rollback_notes="account info rollback gagal"
  fi

  if [[ -n "${zivpn_file}" ]]; then
    if ! ssh_optional_file_snapshot_restore "${zivpn_mode}" "${zivpn_backup}" "${zivpn_file}" 600; then
      if [[ -n "${rollback_notes}" ]]; then
        rollback_notes="${rollback_notes} | restore file ZIVPN gagal"
      else
        rollback_notes="restore file ZIVPN gagal"
      fi
    elif zivpn_runtime_available && ! zivpn_sync_runtime_now; then
      if [[ -n "${rollback_notes}" ]]; then
        rollback_notes="${rollback_notes} | rollback ZIVPN gagal"
      else
        rollback_notes="rollback ZIVPN gagal"
      fi
    fi
  elif ! zivpn_sync_user_password_warn "${username}" "${previous_password}"; then
    if [[ -n "${rollback_notes}" ]]; then
      rollback_notes="${rollback_notes} | rollback ZIVPN gagal"
    else
      rollback_notes="rollback ZIVPN gagal"
    fi
  fi
  if [[ -n "${rollback_notes}" ]]; then
    echo "password Linux dipulihkan, tetapi ${rollback_notes}"
    return 1
  fi
  echo "ok"
  return 0
}

ssh_expiry_update_rollback() {
  local username="${1:-}"
  local previous_expiry="${2:--}"
  [[ -n "${username}" ]] || {
    echo "username rollback kosong"
    return 1
  }
  if ! ssh_apply_expiry "${username}" "${previous_expiry}"; then
    echo "rollback expiry Linux gagal"
    return 1
  fi

  local created_at
  created_at="$(ssh_user_state_created_at_get "${username}")"
  if [[ -z "${created_at}" ]]; then
    created_at="$(date '+%Y-%m-%d')"
  fi
  if ! ssh_user_state_write "${username}" "${created_at}" "${previous_expiry}"; then
    echo "expiry Linux dipulihkan, tetapi metadata rollback gagal"
    return 1
  fi
  if ! ssh_account_info_refresh_from_state "${username}"; then
    echo "expiry Linux dipulihkan, tetapi SSH ACCOUNT INFO rollback gagal"
    return 1
  fi
  echo "ok"
  return 0
}

ssh_add_user_rollback() {
  # args: username qf acc_file reason raw_password cleanup_zivpn linux_created
  local username="${1:-}"
  local qf="${2:-}"
  local acc_file="${3:-}"
  local reason="${4:-Gagal membuat akun SSH.}"
  local raw_password="${5:-}"
  local cleanup_zivpn="${6:-false}"
  local linux_created="${7:-false}"
  local deleted="false"
  local -a rollback_notes=()

  if [[ "${cleanup_zivpn}" == "true" ]]; then
    if ! zivpn_remove_user_password_warn "${username}"; then
      rollback_notes+=("cleanup ZIVPN gagal")
    fi
  fi

  if [[ "${linux_created}" == "true" ]]; then
    if id "${username}" >/dev/null 2>&1; then
      if ssh_userdel_purge "${username}" >/dev/null 2>&1; then
        deleted="true"
      fi
    fi
  else
    deleted="true"
  fi

  if [[ "${deleted}" == "true" ]]; then
    local -a cleanup_notes=()
    local cleanup_failed=""
    cleanup_failed="$(ssh_user_artifacts_cleanup_locked "${username}" 2>/dev/null || true)"
    if [[ -n "${cleanup_failed}" ]]; then
      cleanup_notes+=("${cleanup_failed}")
    elif ! ssh_network_runtime_refresh_if_available; then
      cleanup_notes+=("refresh runtime SSH Network gagal")
    fi
    warn "${reason}"
    if (( ${#rollback_notes[@]} > 0 )); then
      warn "Rollback tambahan: $(IFS=' | '; echo "${rollback_notes[*]}")"
    fi
    if (( ${#cleanup_notes[@]} > 0 )); then
      warn "Cleanup artefak lokal gagal: ${cleanup_notes[*]}"
      return 1
    fi
    if (( ${#rollback_notes[@]} > 0 )); then
      return 1
    fi
    return 0
  fi

  # Hindari orphan-silent: saat userdel gagal, pertahankan metadata agar status masih terlihat.
  warn "${reason}"
  warn "Rollback parsial: gagal menghapus user Linux '${username}'."
  if [[ "${cleanup_zivpn}" == "true" && -n "${raw_password}" && "${raw_password}" != "-" ]]; then
    if ! zivpn_sync_user_password_warn "${username}" "${raw_password}"; then
      warn "Rollback parsial tambahan: rollback ZIVPN gagal untuk '${username}'."
    else
      warn "Rollback parsial tambahan: rollback ZIVPN berhasil untuk '${username}'."
    fi
  fi
  if (( ${#rollback_notes[@]} > 0 )); then
    warn "Rollback tambahan: $(IFS=' | '; echo "${rollback_notes[*]}")"
  fi
  warn "Artefak managed yang sudah ada dipertahankan. Jalankan manual: userdel '${username}'"
  return 1
}

ssh_add_user_fail_with_rollback() {
  # args: username qf acc_file reason raw_password cleanup_zivpn linux_created txn_dir
  local username="${1:-}"
  local qf="${2:-}"
  local acc_file="${3:-}"
  local reason="${4:-Gagal membuat akun SSH.}"
  local raw_password="${5:-}"
  local cleanup_zivpn="${6:-false}"
  local linux_created="${7:-false}"
  local txn_dir="${8:-}"
  if ssh_add_user_rollback "${username}" "${qf}" "${acc_file}" "${reason}" "${raw_password}" "${cleanup_zivpn}" "${linux_created}"; then
    ssh_add_txn_marker_clear "${username}" >/dev/null 2>&1 || true
    mutation_txn_dir_remove "${txn_dir}"
  else
    [[ -n "${txn_dir}" ]] && warn "Journal recovery add SSH dipertahankan di ${txn_dir}."
  fi
  return 1
}

ssh_add_txn_marker_file() {
  local username="${1:-}"
  printf '%s/ssh-add-markers/%s.txn\n' "${WORK_DIR}" "${username}"
}

ssh_add_txn_marker_write() {
  local username="${1:-}"
  local txn_id="${2:-}"
  local marker_file=""
  [[ -n "${username}" && -n "${txn_id}" ]] || return 1
  marker_file="$(ssh_add_txn_marker_file "${username}")"
  mkdir -p "$(dirname "${marker_file}")" 2>/dev/null || return 1
  if ! printf '%s' "${txn_id}" > "${marker_file}"; then
    return 1
  fi
  chmod 600 "${marker_file}" 2>/dev/null || true
  return 0
}

ssh_add_txn_marker_read() {
  local username="${1:-}"
  local marker_file=""
  [[ -n "${username}" ]] || return 1
  marker_file="$(ssh_add_txn_marker_file "${username}")"
  [[ -f "${marker_file}" ]] || return 1
  cat "${marker_file}" 2>/dev/null || return 1
}

ssh_add_txn_marker_clear() {
  local username="${1:-}"
  local marker_file=""
  [[ -n "${username}" ]] || return 0
  marker_file="$(ssh_add_txn_marker_file "${username}")"
  rm -f "${marker_file}" >/dev/null 2>&1 || true
}

ssh_user_home_dir_default() {
  local username="${1:-}"
  printf '/home/%s\n' "${username}"
}

ssh_user_home_dir_get() {
  local username="${1:-}"
  local home=""
  [[ -n "${username}" ]] || return 1
  home="$(getent passwd "${username}" 2>/dev/null | awk -F: '{print $6; exit}' || true)"
  [[ -n "${home}" ]] || home="$(ssh_user_home_dir_default "${username}")"
  printf '%s\n' "${home}"
}

ssh_user_home_dir_prepare() {
  local username="${1:-}"
  local home=""
  [[ -n "${username}" ]] || return 1
  home="$(ssh_user_home_dir_get "${username}")"
  [[ -n "${home}" ]] || return 1
  mkdir -p "${home}" 2>/dev/null || return 1
  chown "${username}:${username}" "${home}" 2>/dev/null || return 1
  chmod 700 "${home}" 2>/dev/null || true
}

ssh_password_hash_generate() {
  local password="${1:-}"
  [[ -n "${password}" ]] || return 1
  if have_cmd openssl; then
    openssl passwd -6 -stdin 2>/dev/null <<<"${password}" | tr -d '\r' || return 1
    return 0
  fi
  need_python3
  python3 - <<'PY' "${password}"
import crypt
import secrets
import string
import sys

password = sys.argv[1]
alphabet = string.ascii_letters + string.digits + "./"
salt = "".join(secrets.choice(alphabet) for _ in range(16))
print(crypt.crypt(password, f"$6${salt}$"))
PY
}

ssh_home_snapshot_create() {
  local username="${1:-}"
  local snapshot_dir="${2:-}"
  local mode_var="${3:-}"
  local backup_var="${4:-}"
  local home_dir="" archive="" mode="absent" backup=""
  [[ -n "${mode_var}" && -n "${backup_var}" ]] || return 1
  home_dir="$(ssh_user_home_dir_get "${username}")"
  if [[ -n "${home_dir}" && -d "${home_dir}" ]]; then
    archive="${snapshot_dir}/home.tar"
    if tar -cpf "${archive}" -C "${home_dir}" . >/dev/null 2>&1; then
      mode="file"
      backup="${archive}"
    else
      return 1
    fi
  fi
  printf -v "${mode_var}" '%s' "${mode}"
  printf -v "${backup_var}" '%s' "${backup}"
}

ssh_home_snapshot_restore() {
  local username="${1:-}"
  local mode="${2:-absent}"
  local backup_file="${3:-}"
  local home_dir=""
  [[ -n "${username}" ]] || return 1
  home_dir="$(ssh_user_home_dir_get "${username}")"
  [[ -n "${home_dir}" ]] || return 1
  if [[ "${mode}" != "file" || -z "${backup_file}" || ! -f "${backup_file}" ]]; then
    ssh_user_home_dir_prepare "${username}"
    return $?
  fi
  mkdir -p "${home_dir}" 2>/dev/null || return 1
  if ! tar -xpf "${backup_file}" -C "${home_dir}" >/dev/null 2>&1; then
    return 1
  fi
  chown -R "${username}:${username}" "${home_dir}" 2>/dev/null || true
  chmod 700 "${home_dir}" 2>/dev/null || true
}

ssh_linux_account_snapshot_create() {
  local username="${1:-}"
  local snapshot_dir="${2:-}"
  local meta_var="${3:-}"
  local meta_file="" passwd_line="" uid="" gid="" home="" shell="" primary_group="" groups="" password_hash="" gecos=""
  [[ -n "${username}" && -n "${snapshot_dir}" && -n "${meta_var}" ]] || return 1
  passwd_line="$(getent passwd "${username}" 2>/dev/null || true)"
  [[ -n "${passwd_line}" ]] || {
    printf -v "${meta_var}" '%s' ""
    return 0
  }
  uid="$(printf '%s' "${passwd_line}" | awk -F: '{print $3}')"
  gid="$(printf '%s' "${passwd_line}" | awk -F: '{print $4}')"
  home="$(printf '%s' "${passwd_line}" | awk -F: '{print $6}')"
  shell="$(printf '%s' "${passwd_line}" | awk -F: '{print $7}')"
  gecos="$(printf '%s' "${passwd_line}" | awk -F: '{print $5}')"
  primary_group="$(id -gn "${username}" 2>/dev/null || true)"
  password_hash="$(getent shadow "${username}" 2>/dev/null | awk -F: '{print $2}' || true)"
  groups="$(id -Gn "${username}" 2>/dev/null | awk -v pg="${primary_group}" '
    {
      out=""
      for (i=1; i<=NF; i++) {
        if ($i == pg || $i == "") continue
        out = out (out=="" ? "" : ",") $i
      }
      print out
    }' || true)"
  meta_file="${snapshot_dir}/linux-account.meta"
  {
    printf 'uid=%s\n' "${uid}"
    printf 'gid=%s\n' "${gid}"
    printf 'home=%s\n' "${home}"
    printf 'shell=%s\n' "${shell}"
    printf 'gecos=%s\n' "${gecos}"
    printf 'primary_group=%s\n' "${primary_group}"
    printf 'supp_groups=%s\n' "${groups}"
    printf 'password_hash=%s\n' "${password_hash}"
  } > "${meta_file}" || return 1
  chmod 600 "${meta_file}" 2>/dev/null || true
  printf -v "${meta_var}" '%s' "${meta_file}"
}

ssh_linux_account_snapshot_field_get() {
  local meta_file="${1:-}"
  local key="${2:-}"
  [[ -n "${meta_file}" && -f "${meta_file}" && -n "${key}" ]] || return 1
  awk -F= -v want="${key}" '$1==want {print substr($0, index($0, "=")+1); exit}' "${meta_file}" 2>/dev/null
}

ssh_add_txn_recover_dir() {
  local txn_dir="${1:-}"
  local username qf acc_file password expired_at created_at quota_bytes ip_enabled ip_limit speed_enabled speed_down speed_up linux_created txn_id marker_id
  local password_file="" cleanup_failed=""
  local -a notes=()
  [[ -n "${txn_dir}" && -d "${txn_dir}" ]] || return 0

  username="$(mutation_txn_field_read "${txn_dir}" username 2>/dev/null || true)"
  qf="$(mutation_txn_field_read "${txn_dir}" qf 2>/dev/null || true)"
  acc_file="$(mutation_txn_field_read "${txn_dir}" acc_file 2>/dev/null || true)"
  expired_at="$(mutation_txn_field_read "${txn_dir}" expired_at 2>/dev/null || true)"
  created_at="$(mutation_txn_field_read "${txn_dir}" created_at 2>/dev/null || true)"
  quota_bytes="$(mutation_txn_field_read "${txn_dir}" quota_bytes 2>/dev/null || true)"
  ip_enabled="$(mutation_txn_field_read "${txn_dir}" ip_enabled 2>/dev/null || true)"
  ip_limit="$(mutation_txn_field_read "${txn_dir}" ip_limit 2>/dev/null || true)"
  speed_enabled="$(mutation_txn_field_read "${txn_dir}" speed_enabled 2>/dev/null || true)"
  speed_down="$(mutation_txn_field_read "${txn_dir}" speed_down 2>/dev/null || true)"
  speed_up="$(mutation_txn_field_read "${txn_dir}" speed_up 2>/dev/null || true)"
  linux_created="$(mutation_txn_field_read "${txn_dir}" linux_created 2>/dev/null || true)"
  txn_id="$(mutation_txn_field_read "${txn_dir}" txn_id 2>/dev/null || true)"
  password_file="${txn_dir}/password.secret"
  password="$(cat "${password_file}" 2>/dev/null || true)"

  if [[ -z "${username}" || -z "${qf}" || -z "${acc_file}" ]]; then
    mutation_txn_dir_remove "${txn_dir}"
    return 0
  fi
  if [[ "${linux_created}" != "true" ]]; then
    cleanup_failed="$(ssh_user_artifacts_cleanup_locked "${username}" 2>/dev/null || true)"
    if [[ -n "${cleanup_failed}" ]]; then
      warn "Recovery add SSH untuk '${username}' belum bersih: cleanup artefak pre-Linux gagal (${cleanup_failed})."
      return 1
    fi
    if ! ssh_network_runtime_refresh_if_available; then
      warn "Recovery add SSH untuk '${username}' belum bersih: refresh runtime SSH Network gagal."
      return 1
    fi
    marker_id="$(ssh_add_txn_marker_read "${username}" 2>/dev/null || true)"
    if [[ -n "${txn_id}" && -n "${marker_id}" && "${marker_id}" == "${txn_id}" ]]; then
      ssh_add_txn_marker_clear "${username}" >/dev/null 2>&1 || true
    fi
    mutation_txn_dir_remove "${txn_dir}"
    log "Recovery add SSH membersihkan metadata pre-Linux untuk '${username}'."
    return 0
  fi

  if ! id "${username}" >/dev/null 2>&1; then
    local orphan_zivpn_file=""
    orphan_zivpn_file="$(zivpn_password_file "${username}")"
    if [[ -e "${orphan_zivpn_file}" || -L "${orphan_zivpn_file}" ]]; then
      zivpn_remove_user_password_warn "${username}" >/dev/null 2>&1 || true
    fi
    cleanup_failed="$(ssh_user_artifacts_cleanup_locked "${username}" 2>/dev/null || true)"
    if [[ -n "${cleanup_failed}" ]]; then
      warn "Recovery add SSH untuk '${username}' belum bersih: cleanup artefak gagal (${cleanup_failed})."
      return 1
    fi
    if ! ssh_network_runtime_refresh_if_available; then
      warn "Recovery add SSH untuk '${username}' belum bersih: refresh runtime SSH Network gagal."
      return 1
    fi
    marker_id="$(ssh_add_txn_marker_read "${username}" 2>/dev/null || true)"
    if [[ -n "${txn_id}" && -n "${marker_id}" && "${marker_id}" == "${txn_id}" ]]; then
      ssh_add_txn_marker_clear "${username}" >/dev/null 2>&1 || true
    fi
    mutation_txn_dir_remove "${txn_dir}"
    log "Recovery add SSH membuang journal yatim untuk '${username}' karena user Linux tidak ada."
    return 0
  fi

  marker_id="$(ssh_add_txn_marker_read "${username}" 2>/dev/null || true)"
  if [[ -z "${txn_id}" || -z "${marker_id}" || "${marker_id}" != "${txn_id}" ]]; then
    warn "Recovery add SSH untuk '${username}' ditahan: marker transaksi tidak cocok. Akun Linux mungkin sudah dipakai ulang."
    return 1
  fi

  if [[ -z "${password}" ]]; then
    warn "Recovery add SSH untuk '${username}' belum bisa dilanjutkan: password journal tidak tersedia."
    return 1
  fi

  if (( ${#notes[@]} == 0 )) && ! ssh_user_state_write "${username}" "${created_at}" "${expired_at}"; then
    notes+=("tulis metadata akun SSH gagal")
  fi
  if (( ${#notes[@]} == 0 )) && ! ssh_qac_atomic_update_file "${qf}" set_quota_limit "${quota_bytes}"; then
    notes+=("set quota metadata SSH gagal")
  fi
  if (( ${#notes[@]} == 0 )); then
    if [[ "${ip_enabled}" == "true" ]]; then
      if ! ssh_qac_atomic_update_file "${qf}" set_ip_limit "${ip_limit}"; then
        notes+=("set IP limit metadata SSH gagal")
      elif ! ssh_qac_atomic_update_file "${qf}" ip_limit_enabled_set on; then
        notes+=("aktifkan IP limit metadata SSH gagal")
      fi
    else
      if ! ssh_qac_atomic_update_file "${qf}" ip_limit_enabled_set off; then
        notes+=("nonaktifkan IP limit metadata SSH gagal")
      fi
    fi
  fi
  if (( ${#notes[@]} == 0 )); then
    if [[ "${speed_enabled}" == "true" ]]; then
      if ! ssh_qac_atomic_update_file "${qf}" set_speed_all_enable "${speed_down}" "${speed_up}"; then
        notes+=("set speed limit metadata SSH gagal")
      fi
    else
      if ! ssh_qac_atomic_update_file "${qf}" speed_limit_set off; then
        notes+=("nonaktifkan speed limit metadata SSH gagal")
      fi
    fi
  fi
  if (( ${#notes[@]} == 0 )) && ! ssh_account_info_refresh_from_state "${username}" "${password}" "${acc_file}"; then
    notes+=("refresh SSH account info gagal")
  fi
  if (( ${#notes[@]} == 0 )) && ! zivpn_sync_user_password_warn "${username}" "${password}"; then
    notes+=("sinkronisasi password ZIVPN gagal")
  fi
  if (( ${#notes[@]} == 0 )) && ! ssh_qac_enforce_now_warn "${username}"; then
    notes+=("enforcement awal SSH gagal")
  fi
  if (( ${#notes[@]} == 0 )) && ! ssh_dns_adblock_runtime_refresh_if_available; then
    notes+=("refresh runtime DNS Adblock SSH gagal")
  fi
  if (( ${#notes[@]} == 0 )) && ! ssh_network_runtime_refresh_if_available; then
    notes+=("refresh runtime SSH Network gagal")
  fi
  if (( ${#notes[@]} == 0 )) && ! ssh_user_home_dir_prepare "${username}"; then
    notes+=("menyiapkan home dir Linux gagal")
  fi
  if (( ${#notes[@]} == 0 )) && ! ssh_apply_password "${username}" "${password}"; then
    notes+=("set password Linux gagal")
  fi
  if (( ${#notes[@]} == 0 )) && ! ssh_apply_expiry "${username}" "${expired_at}"; then
    notes+=("set expiry Linux gagal")
  fi
  if (( ${#notes[@]} == 0 )) && ! usermod -U "${username}" >/dev/null 2>&1; then
    notes+=("membuka lock akun Linux gagal")
  fi
  if (( ${#notes[@]} == 0 )) && ! usermod -s /bin/bash "${username}" >/dev/null 2>&1; then
    notes+=("aktifkan shell login gagal")
  fi
  if (( ${#notes[@]} == 0 )) && ! ssh_account_info_refresh_from_state "${username}" "${password}" "${acc_file}"; then
    notes+=("refresh final SSH account info gagal")
  fi

  if (( ${#notes[@]} > 0 )); then
    warn "Recovery add SSH untuk '${username}' belum bersih: $(IFS=' | '; echo "${notes[*]}")."
    return 1
  fi

  ssh_add_txn_marker_clear "${username}" >/dev/null 2>&1 || true
  mutation_txn_dir_remove "${txn_dir}"
  log "Recovery add SSH selesai untuk '${username}'."
  return 0
}

ssh_add_txn_recover_pending_all() {
  local txn_dir=""
  mutation_txn_prepare || return 0
  while IFS= read -r -d '' txn_dir; do
    [[ -n "${txn_dir}" ]] || continue
    ssh_add_txn_recover_dir "${txn_dir}" || true
  done < <(find "${MUTATION_TXN_DIR}" -maxdepth 1 -type d -name 'ssh-add.*' -print0 2>/dev/null | sort -z)
}

ssh_userdel_purge() {
  local username="${1:-}"
  [[ -n "${username}" ]] || return 1
  if ! id "${username}" >/dev/null 2>&1; then
    return 0
  fi
  userdel -r "${username}" >/dev/null 2>&1
}

ssh_delete_user_cleanup_after_linux_delete() {
  local username="${1:-}"
  local zivpn_file="${2:-}"
  local cleanup_failed=""
  local -a notes=()

  [[ -n "${username}" ]] || return 1

  if [[ -n "${zivpn_file}" ]] && ! zivpn_remove_user_password_warn "${username}"; then
    notes+=("cleanup ZIVPN gagal")
  fi

  cleanup_failed="$(ssh_user_artifacts_cleanup_locked "${username}" 2>/dev/null || true)"
  if [[ -n "${cleanup_failed}" ]]; then
    notes+=("cleanup artefak lokal gagal: ${cleanup_failed}")
  elif ! ssh_dns_adblock_runtime_refresh_if_available; then
    notes+=("refresh runtime DNS adblock gagal")
  elif ! ssh_network_runtime_refresh_if_available; then
    notes+=("refresh runtime SSH Network gagal")
  fi

  if (( ${#notes[@]} > 0 )); then
    printf '%s\n' "$(IFS=' | '; echo "${notes[*]}")"
    return 1
  fi
  return 0
}

ssh_delete_txn_recover_dir() {
  local txn_dir="${1:-}"
  local username linux_deleted zivpn_file cleanup_failed=""
  local state_mode="absent" state_backup="" state_file=""
  local state_compat_mode="absent" state_compat_backup="" state_compat_file=""
  local account_mode="absent" account_backup="" account_file=""
  local account_compat_mode="absent" account_compat_backup="" account_compat_file=""
  local zivpn_mode="absent" zivpn_backup="" linux_meta_file=""
  local restore_msg=""
  [[ -n "${txn_dir}" && -d "${txn_dir}" ]] || return 0

  username="$(mutation_txn_field_read "${txn_dir}" username 2>/dev/null || true)"
  linux_deleted="$(mutation_txn_field_read "${txn_dir}" linux_deleted 2>/dev/null || true)"
  zivpn_file="$(mutation_txn_field_read "${txn_dir}" zivpn_file 2>/dev/null || true)"
  if [[ -z "${username}" ]]; then
    mutation_txn_dir_remove "${txn_dir}"
    return 0
  fi
  state_file="$(ssh_user_state_file "${username}")"
  state_compat_file="$(ssh_user_state_compat_file "${username}")"
  account_file="$(ssh_account_info_file "${username}")"
  account_compat_file="${SSH_ACCOUNT_DIR}/${username}.txt"
  [[ -f "${txn_dir}/state.path" ]] && state_mode="file" && state_backup="${txn_dir}/state.path"
  [[ -f "${txn_dir}/state_compat.path" ]] && state_compat_mode="file" && state_compat_backup="${txn_dir}/state_compat.path"
  [[ -f "${txn_dir}/account.path" ]] && account_mode="file" && account_backup="${txn_dir}/account.path"
  [[ -f "${txn_dir}/account_compat.path" ]] && account_compat_mode="file" && account_compat_backup="${txn_dir}/account_compat.path"
  if [[ -n "${zivpn_file}" && -f "${txn_dir}/zivpn.path" ]]; then
    zivpn_mode="file"
    zivpn_backup="${txn_dir}/zivpn.path"
  fi
  linux_meta_file="${txn_dir}/linux-account.meta"
  if [[ "${linux_deleted}" != "1" ]]; then
    if id "${username}" >/dev/null 2>&1; then
      if ! ssh_delete_user_predelete_restore "${username}" "${linux_meta_file}" "${state_mode}" "${state_backup}"; then
        warn "Recovery delete SSH untuk '${username}' belum bersih: gagal memulihkan status akun Linux pra-delete."
        return 1
      fi
      restore_msg="$(ssh_delete_user_snapshot_restore \
        "${username}" \
        "${state_mode}" "${state_backup}" "${state_file}" \
        "${state_compat_mode}" "${state_compat_backup}" "${state_compat_file}" \
        "${account_mode}" "${account_backup}" "${account_file}" \
        "${account_compat_mode}" "${account_compat_backup}" "${account_compat_file}" \
        "${zivpn_mode}" "${zivpn_backup}" "${zivpn_file}" 2>/dev/null || true)"
      if [[ -n "${restore_msg}" ]]; then
        warn "Recovery delete SSH untuk '${username}' belum bersih: ${restore_msg}"
        return 1
      fi
      mutation_txn_dir_remove "${txn_dir}"
      log "Recovery delete SSH memulihkan state pra-delete untuk '${username}'."
      return 0
    fi
    cleanup_failed="$(ssh_delete_user_cleanup_after_linux_delete "${username}" "${zivpn_file}" 2>/dev/null || true)"
    if [[ -n "${cleanup_failed}" ]]; then
      warn "Recovery delete SSH untuk '${username}' belum bersih: ${cleanup_failed}"
      return 1
    fi
    mutation_txn_dir_remove "${txn_dir}"
    log "Recovery delete SSH menyelesaikan cleanup pasca-delete untuk '${username}'."
    return 0
  fi
  if id "${username}" >/dev/null 2>&1; then
    warn "Recovery delete SSH untuk '${username}' tertahan: akun Linux masih ada."
    return 1
  fi

  mutation_txn_dir_remove "${txn_dir}"
  log "Recovery delete SSH selesai untuk '${username}'."
  return 0
}

ssh_delete_txn_recover_pending_all() {
  local txn_dir=""
  mutation_txn_prepare || return 0
  while IFS= read -r -d '' txn_dir; do
    [[ -n "${txn_dir}" ]] || continue
    ssh_delete_txn_recover_dir "${txn_dir}" || true
  done < <(find "${MUTATION_TXN_DIR}" -maxdepth 1 -type d -name 'ssh-delete.*' -print0 2>/dev/null | sort -z)
}

ssh_pending_recovery_count() {
  local count=0
  mutation_txn_prepare || {
    printf '0\n'
    return 0
  }
  count="$(find "${MUTATION_TXN_DIR}" -maxdepth 1 -type d \( -name 'ssh-add.*' -o -name 'ssh-delete.*' \) 2>/dev/null | wc -l | tr -d '[:space:]' || true)"
  [[ "${count}" =~ ^[0-9]+$ ]] || count=0
  printf '%s\n' "${count}"
}

ssh_pending_txn_dirs_by_kind() {
  local kind="${1:-all}"
  case "${kind}" in
    add) mutation_txn_list_dirs 'ssh-add.*' ;;
    delete) mutation_txn_list_dirs 'ssh-delete.*' ;;
    all)
      mutation_txn_list_dirs 'ssh-add.*'
      mutation_txn_list_dirs 'ssh-delete.*'
      ;;
    *) return 0 ;;
  esac
}

ssh_pending_txn_label() {
  local txn_dir="${1:-}"
  local base="" username="" created=""
  [[ -n "${txn_dir}" && -d "${txn_dir}" ]] || return 1
  base="$(basename "${txn_dir}")"
  username="$(mutation_txn_field_read "${txn_dir}" username 2>/dev/null || true)"
  created="$(date -r "${txn_dir}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || true)"
  case "${base}" in
    ssh-add.*) printf 'ADD    | %s | %s\n' "${username:-?}" "${created:-unknown}" ;;
    ssh-delete.*) printf 'DELETE | %s | %s\n' "${username:-?}" "${created:-unknown}" ;;
    *) printf '%s | %s\n' "${base}" "${created:-unknown}" ;;
  esac
}

ssh_recover_pending_txn_now() {
  local kind="${1:-all}"
  local txn_dir="${2:-}"
  if [[ -n "${txn_dir}" ]]; then
    case "${kind}" in
      add) ssh_add_txn_recover_dir "${txn_dir}" || true ;;
      delete) ssh_delete_txn_recover_dir "${txn_dir}" || true ;;
    esac
    return 0
  fi
  case "${kind}" in
    add) ssh_add_txn_recover_pending_all || true ;;
    delete) ssh_delete_txn_recover_pending_all || true ;;
    all|*)
      ssh_add_txn_recover_pending_all || true
      ssh_delete_txn_recover_pending_all || true
      ;;
  esac
}

ssh_recover_pending_txn_pick_dir() {
  local kind="${1:-}"
  local -n _out_ref="${2}"
  local -a dirs=()
  local txn_dir="" choice="" i
  _out_ref=""
  [[ "${kind}" == "add" || "${kind}" == "delete" ]] || return 1
  while IFS= read -r txn_dir; do
    [[ -n "${txn_dir}" ]] || continue
    dirs+=("${txn_dir}")
  done < <(ssh_pending_txn_dirs_by_kind "${kind}")
  if (( ${#dirs[@]} == 0 )); then
    return 1
  fi
  if (( ${#dirs[@]} == 1 )); then
    _out_ref="${dirs[0]}"
    return 0
  fi
  echo "Pilih journal recovery ${kind} SSH:"
  for i in "${!dirs[@]}"; do
    printf '  %d) %s\n' "$((i + 1))" "$(ssh_pending_txn_label "${dirs[$i]}")"
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

ssh_recover_pending_txn_menu() {
  local pending_count=0
  local add_count=0
  local delete_count=0
  local choice=""
  local selected_dir=""
  local selected_label=""
  pending_count="$(ssh_pending_recovery_count)"
  add_count="$(find "${MUTATION_TXN_DIR}" -maxdepth 1 -type d -name 'ssh-add.*' 2>/dev/null | wc -l | tr -d '[:space:]' || true)"
  delete_count="$(find "${MUTATION_TXN_DIR}" -maxdepth 1 -type d -name 'ssh-delete.*' 2>/dev/null | wc -l | tr -d '[:space:]' || true)"
  [[ "${pending_count}" =~ ^[0-9]+$ ]] || pending_count=0
  [[ "${add_count}" =~ ^[0-9]+$ ]] || add_count=0
  [[ "${delete_count}" =~ ^[0-9]+$ ]] || delete_count=0

  title
  echo "SSH Users > Recover Pending Txn"
  hr
  echo "Pending journal : ${pending_count}"
  echo "  Add    : ${add_count}"
  echo "  Delete : ${delete_count}"
  if (( pending_count == 0 )); then
    log "Tidak ada journal recovery SSH yang tertunda."
    pause
    return 0
  fi
  echo "Catatan        : aksi ini bisa memodifikasi akun Linux, metadata SSH, dan sinkronisasi ZIVPN untuk menyelesaikan transaksi lama."
  hr
  echo "  1) Recover journal Add"
  echo "  2) Recover journal Delete"
  echo "  0) Back"
  hr
  read -r -p "Pilih aksi: " choice
  case "${choice}" in
    1)
      (( add_count > 0 )) || { warn "Tidak ada journal add SSH."; pause; return 0; }
      ssh_recover_pending_txn_pick_dir add selected_dir || { pause; return 0; }
      selected_label="$(ssh_pending_txn_label "${selected_dir}")"
      echo "Journal terpilih : ${selected_label}"
      confirm_menu_apply_now "Lanjutkan recovery journal add SSH ini sekarang? (${selected_label})" || { pause; return 0; }
      user_data_mutation_run_locked ssh_recover_pending_txn_now add "${selected_dir}"
      ;;
    2)
      (( delete_count > 0 )) || { warn "Tidak ada journal delete SSH."; pause; return 0; }
      ssh_recover_pending_txn_pick_dir delete selected_dir || { pause; return 0; }
      selected_label="$(ssh_pending_txn_label "${selected_dir}")"
      echo "Journal terpilih : ${selected_label}"
      confirm_menu_apply_now "Lanjutkan recovery journal delete SSH ini sekarang? (${selected_label})" || { pause; return 0; }
      user_data_mutation_run_locked ssh_recover_pending_txn_now delete "${selected_dir}"
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

ssh_managed_users_lines() {
  ssh_state_dirs_prepare
  need_python3
  python3 - <<'PY' "${SSH_USERS_STATE_DIR}" "${MUTATION_TXN_DIR}" 2>/dev/null || true
import json
import glob
import os
import pwd
import re
import sys
from datetime import datetime

root = sys.argv[1]
txn_root = sys.argv[2] if len(sys.argv) > 2 else ""

def norm_created(v):
  s = str(v or "").strip()
  if not s or s == "-":
    return "-"
  s = s.replace("T", " ")
  if s.endswith("Z"):
    s = s[:-1]
  s = s.strip()
  if re.match(r"^\d{4}-\d{2}-\d{2}$", s):
    return s
  if len(s) >= 16 and re.match(r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}", s):
    return s[:10]
  candidates = [s]
  if re.match(r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$", s):
    candidates.append(s + ":00")
  for c in candidates:
    try:
      dt = datetime.fromisoformat(c)
      return dt.strftime("%Y-%m-%d")
    except Exception:
      pass
  m = re.search(r"\d{4}-\d{2}-\d{2}", s)
  if m:
    return m.group(0)
  return "-"

def norm_expired(v):
  s = str(v or "").strip()
  if not s or s == "-":
    return "-"
  m = re.search(r"\d{4}-\d{2}-\d{2}", s)
  return m.group(0) if m else "-"

rows = []
seen = set()
if os.path.isdir(root):
  for name in os.listdir(root):
    if not name.endswith(".json"):
      continue
    base = name[:-5]
    username = base[:-4] if base.endswith("@ssh") else base
    username = username.strip()
    if not username:
      continue
    path = os.path.join(root, name)
    created = "-"
    expired = "-"
    try:
      with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
      if isinstance(data, dict):
        meta_user = str(data.get("username") or "").strip()
        if meta_user.endswith("@ssh"):
          meta_user = meta_user[:-4]
        if meta_user:
          username = meta_user
        created = norm_created(data.get("created_at"))
        expired = norm_expired(data.get("expired_at"))
    except Exception:
      pass
    rows.append((username.lower(), username, created, expired))
    seen.add(username)

for entry in pwd.getpwall():
  username = str(entry.pw_name or "").strip()
  shell = str(entry.pw_shell or "").strip()
  home = str(entry.pw_dir or "").strip()
  if not username or username == "root":
    continue
  if entry.pw_uid < 1000:
    continue
  if not shell or shell.endswith(("nologin", "false")):
    continue
  if home and not home.startswith("/home/"):
    continue
  if os.path.isdir(txn_root):
    for pending_path in glob.glob(os.path.join(txn_root, f"ssh-add.{username}*")):
      try:
        with open(os.path.join(pending_path, "linux_created"), "r", encoding="utf-8") as f:
          if f.read().strip() != "true":
            username = ""
            break
      except Exception:
        username = ""
        break
  if not username:
    continue
  if username in seen:
    continue
  rows.append((username.lower(), username, "linux-only", "-"))

rows.sort(key=lambda x: x[0])
for _, username, created, expired in rows:
  print(f"{username}|{created}|{expired}")
PY
}

ssh_add_user_header_render() {
  local -n _page_ref="$1"
  local page_size=5
  local -a rows=()
  local row
  while IFS= read -r row; do
    [[ -n "${row}" ]] || continue
    rows+=("${row}")
  done < <(ssh_managed_users_lines)

  local total="${#rows[@]}"
  echo "Daftar akun SSH terdaftar (maks 5 baris):"
  if (( total == 0 )); then
    echo "  (Belum ada akun SSH terkelola)"
    echo "  Input username baru untuk lanjut."
    return 0
  fi

  local pages=$(( (total + page_size - 1) / page_size ))
  local page="${_page_ref:-0}"
  if (( page < 0 )); then
    page=0
  fi
  if (( page >= pages )); then
    page=$((pages - 1))
  fi
  _page_ref="${page}"

  local start=$((page * page_size))
  local end=$((start + page_size))
  if (( end > total )); then
    end="${total}"
  fi

  printf "%-4s %-20s %-16s %-10s\n" "No" "Username" "Created" "Expired"
  printf "%-4s %-20s %-16s %-10s\n" "----" "--------------------" "----------------" "----------"

  local i username created expired
  for ((i=start; i<end; i++)); do
    IFS='|' read -r username created expired <<<"${rows[$i]}"
    printf "%-4s %-20s %-16s %-10s\n" "$((i + 1))" "${username}" "${created}" "${expired}"
  done

  echo "Halaman: $((page + 1))/${pages} | Total: ${total}"
  if (( pages > 1 )); then
    echo "Navigasi: ketik next/previous sebelum input username."
  fi
}

ssh_add_user_apply_locked() {
  local rc=0
  (
    SSH_ADD_ABORT_ACTIVE="1"
    SSH_ADD_ABORT_USERNAME="$1"
    SSH_ADD_ABORT_QF="$2"
    SSH_ADD_ABORT_ACC="$3"
    SSH_ADD_ABORT_PASSWORD="$4"
    SSH_ADD_ABORT_LINUX_CREATED="false"
    SSH_ADD_ABORT_ZIVPN_SYNCED="false"
    trap '
      if [[ "${SSH_ADD_ABORT_ACTIVE:-0}" == "1" ]]; then
        ssh_add_user_rollback \
          "${SSH_ADD_ABORT_USERNAME}" \
          "${SSH_ADD_ABORT_QF}" \
          "${SSH_ADD_ABORT_ACC}" \
          "transaksi add user SSH terputus sebelum commit final" \
          "${SSH_ADD_ABORT_PASSWORD}" \
          "${SSH_ADD_ABORT_ZIVPN_SYNCED:-false}" \
          "${SSH_ADD_ABORT_LINUX_CREATED:-false}" >/dev/null 2>&1 || true
      fi
    ' EXIT INT TERM HUP QUIT
    ssh_add_user_apply_locked_inner "$@"
    rc=$?
    trap - EXIT INT TERM HUP QUIT
    exit "${rc}"
  )
  rc=$?
  return "${rc}"
}

ssh_add_user_apply_locked_inner() {
  local username="$1"
  local qf="$2"
  local acc_file="$3"
  local password="$4"
  local expired_at="$5"
  local created_at="$6"
  local quota_bytes="$7"
  local ip_enabled="$8"
  local ip_limit="$9"
  local speed_enabled="${10}"
  local speed_down="${11}"
  local speed_up="${12}"
  local add_txn_dir="" add_txn_id="" pending_shell="/usr/sbin/nologin"
  local password_hash="" home_dir="" pending_expired_at="1970-01-02"
  local -a useradd_args=()

  add_txn_dir="$(mutation_txn_dir_new "ssh-add.${username}" 2>/dev/null || true)"
  if [[ -z "${add_txn_dir}" || ! -d "${add_txn_dir}" ]]; then
    warn "Gagal menyiapkan journal recovery add user SSH."
    pause
    return 1
  fi
  add_txn_id="$(basename "${add_txn_dir}")"
  pending_shell="$(ssh_pending_login_shell_get)"
  mutation_txn_field_write "${add_txn_dir}" username "${username}" >/dev/null 2>&1 || true
  mutation_txn_field_write "${add_txn_dir}" qf "${qf}" >/dev/null 2>&1 || true
  mutation_txn_field_write "${add_txn_dir}" acc_file "${acc_file}" >/dev/null 2>&1 || true
  mutation_txn_field_write "${add_txn_dir}" txn_id "${add_txn_id}" >/dev/null 2>&1 || true
  mutation_txn_field_write "${add_txn_dir}" expired_at "${expired_at}" >/dev/null 2>&1 || true
  mutation_txn_field_write "${add_txn_dir}" created_at "${created_at}" >/dev/null 2>&1 || true
  mutation_txn_field_write "${add_txn_dir}" quota_bytes "${quota_bytes}" >/dev/null 2>&1 || true
  mutation_txn_field_write "${add_txn_dir}" ip_enabled "${ip_enabled}" >/dev/null 2>&1 || true
  mutation_txn_field_write "${add_txn_dir}" ip_limit "${ip_limit}" >/dev/null 2>&1 || true
  mutation_txn_field_write "${add_txn_dir}" speed_enabled "${speed_enabled}" >/dev/null 2>&1 || true
  mutation_txn_field_write "${add_txn_dir}" speed_down "${speed_down}" >/dev/null 2>&1 || true
  mutation_txn_field_write "${add_txn_dir}" speed_up "${speed_up}" >/dev/null 2>&1 || true
  mutation_txn_field_write "${add_txn_dir}" linux_created "false" >/dev/null 2>&1 || true
  if ! printf '%s' "${password}" > "${add_txn_dir}/password.secret"; then
    mutation_txn_dir_remove "${add_txn_dir}"
    warn "Gagal menulis journal password recovery add user SSH."
    pause
    return 1
  fi
  chmod 600 "${add_txn_dir}/password.secret" 2>/dev/null || true

  if ! ssh_user_state_write "${username}" "${created_at}" "${expired_at}"; then
    ssh_add_user_fail_with_rollback "${username}" "${qf}" "${acc_file}" "Gagal menulis metadata akun SSH." "${password}" "false" "false" "${add_txn_dir}"
    pause
    return 1
  fi

  if ! ssh_qac_atomic_update_file "${qf}" set_quota_limit "${quota_bytes}"; then
    ssh_add_user_fail_with_rollback "${username}" "${qf}" "${acc_file}" "Gagal set quota metadata SSH." "${password}" "false" "false" "${add_txn_dir}"
    pause
    return 1
  fi

  local add_fail_msg=""
  if [[ "${ip_enabled}" == "true" ]]; then
    if ! ssh_qac_atomic_update_file "${qf}" set_ip_limit "${ip_limit}"; then
      add_fail_msg="Gagal set IP limit metadata SSH."
    elif ! ssh_qac_atomic_update_file "${qf}" ip_limit_enabled_set on; then
      add_fail_msg="Gagal mengaktifkan IP limit metadata SSH."
    fi
  else
    if ! ssh_qac_atomic_update_file "${qf}" ip_limit_enabled_set off; then
      add_fail_msg="Gagal menonaktifkan IP limit metadata SSH."
    fi
  fi

  if [[ -z "${add_fail_msg}" ]]; then
    if [[ "${speed_enabled}" == "true" ]]; then
      if ! ssh_qac_atomic_update_file "${qf}" set_speed_all_enable "${speed_down}" "${speed_up}"; then
        add_fail_msg="Gagal set speed limit metadata SSH."
      fi
    else
      if ! ssh_qac_atomic_update_file "${qf}" speed_limit_set off; then
        add_fail_msg="Gagal menonaktifkan speed limit metadata SSH."
      fi
    fi
  fi

  if [[ -n "${add_fail_msg}" ]]; then
    ssh_add_user_fail_with_rollback "${username}" "${qf}" "${acc_file}" "${add_fail_msg}" "${password}" "false" "false" "${add_txn_dir}"
    pause
    return 1
  fi

  if ! ssh_account_info_refresh_from_state "${username}" "${password}"; then
    ssh_add_user_fail_with_rollback "${username}" "${qf}" "${acc_file}" "Gagal menyiapkan SSH account info." "${password}" "false" "false" "${add_txn_dir}"
    pause
    return 1
  fi
  if ! zivpn_sync_user_password_warn "${username}" "${password}"; then
    ssh_add_user_fail_with_rollback "${username}" "${qf}" "${acc_file}" "Gagal menyiapkan sinkronisasi password ZIVPN sebelum commit user Linux." "${password}" "false" "false" "${add_txn_dir}"
    pause
    return 1
  fi
  SSH_ADD_ABORT_ZIVPN_SYNCED="true"
  if ! ssh_add_txn_marker_write "${username}" "${add_txn_id}"; then
    ssh_add_user_fail_with_rollback "${username}" "${qf}" "${acc_file}" "Gagal menulis marker transaksi add SSH." "${password}" "false" "false" "${add_txn_dir}"
    pause
    return 1
  fi
  if ! ssh_dns_adblock_runtime_refresh_if_available; then
    ssh_add_user_fail_with_rollback "${username}" "${qf}" "${acc_file}" "Gagal refresh runtime DNS Adblock SSH sebelum commit user Linux." "${password}" "true" "false" "${add_txn_dir}"
    pause
    return 1
  fi

  if ! password_hash="$(ssh_password_hash_generate "${password}" 2>/dev/null)"; then
    ssh_add_user_fail_with_rollback "${username}" "${qf}" "${acc_file}" "Gagal menyiapkan hash password Linux sebelum commit user Linux." "${password}" "true" "false" "${add_txn_dir}"
    pause
    return 1
  fi
  home_dir="$(ssh_user_home_dir_default "${username}")"
  useradd_args=(-M -d "${home_dir}" -s "${pending_shell}" -p '!' -e "${pending_expired_at}")
  if ! useradd "${useradd_args[@]}" "${username}" >/dev/null 2>&1; then
    ssh_add_user_fail_with_rollback "${username}" "${qf}" "${acc_file}" "Gagal membuat user Linux '${username}'." "${password}" "true" "false" "${add_txn_dir}"
    pause
    return 1
  fi
  SSH_ADD_ABORT_LINUX_CREATED="true"
  mutation_txn_field_write "${add_txn_dir}" linux_created "true" >/dev/null 2>&1 || true

  if ! ssh_qac_enforce_now_warn "${username}"; then
    if [[ "${ip_enabled}" == "true" ]]; then
      ssh_add_user_fail_with_rollback "${username}" "${qf}" "${acc_file}" "Gagal enforcement awal SSH (IP/Login limit)." "${password}" "true" "true" "${add_txn_dir}"
    else
      ssh_add_user_fail_with_rollback "${username}" "${qf}" "${acc_file}" "Gagal enforcement awal SSH." "${password}" "true" "true" "${add_txn_dir}"
    fi
    pause
    return 1
  fi
  if ! ssh_user_home_dir_prepare "${username}"; then
    ssh_add_user_fail_with_rollback "${username}" "${qf}" "${acc_file}" "Gagal menyiapkan home dir user '${username}'." "${password}" "true" "true" "${add_txn_dir}"
    pause
    return 1
  fi
  if ! usermod -p "${password_hash}" "${username}" >/dev/null 2>&1; then
    ssh_add_user_fail_with_rollback "${username}" "${qf}" "${acc_file}" "Gagal menerapkan hash password final user '${username}'." "${password}" "true" "true" "${add_txn_dir}"
    pause
    return 1
  fi
  if ! ssh_apply_expiry "${username}" "${expired_at}"; then
    ssh_add_user_fail_with_rollback "${username}" "${qf}" "${acc_file}" "Gagal memulihkan expiry final user '${username}' setelah status pending." "${password}" "true" "true" "${add_txn_dir}"
    pause
    return 1
  fi
  if ! usermod -U "${username}" >/dev/null 2>&1; then
    ssh_add_user_fail_with_rollback "${username}" "${qf}" "${acc_file}" "Gagal membuka lock akun Linux '${username}' pada commit final." "${password}" "true" "true" "${add_txn_dir}"
    pause
    return 1
  fi
  if ! usermod -s /bin/bash "${username}" >/dev/null 2>&1; then
    ssh_add_user_fail_with_rollback "${username}" "${qf}" "${acc_file}" "Gagal mengaktifkan shell login user '${username}'." "${password}" "true" "true" "${add_txn_dir}"
    pause
    return 1
  fi
  if ! ssh_account_info_refresh_from_state "${username}" "${password}" "${acc_file}"; then
    ssh_add_user_fail_with_rollback "${username}" "${qf}" "${acc_file}" "Gagal refresh final SSH account info user '${username}' setelah sinkronisasi ZIVPN." "${password}" "true" "true" "${add_txn_dir}"
    pause
    return 1
  fi
  if ! ssh_network_runtime_refresh_if_available; then
    ssh_add_user_fail_with_rollback "${username}" "${qf}" "${acc_file}" "Gagal refresh runtime SSH Network setelah commit user Linux." "${password}" "true" "true" "${add_txn_dir}"
    pause
    return 1
  fi

  SSH_ADD_ABORT_ACTIVE="0"
  ssh_add_txn_marker_clear "${username}" >/dev/null 2>&1 || true
  mutation_txn_dir_remove "${add_txn_dir}"
  log "Akun SSH berhasil dibuat: ${username}"
  title
  echo "Add SSH user sukses ✅"
  hr
  echo "Account file:"
  echo "  ${acc_file}"
  echo "Metadata file:"
  echo "  ${qf}"
  hr
  echo "SSH ACCOUNT INFO:"
  if [[ -f "${acc_file}" ]]; then
    cat "${acc_file}"
  else
    echo "(SSH ACCOUNT INFO tidak ditemukan: ${acc_file})"
  fi
  if [[ "$(ssh_account_info_password_mode)" != "store" && -n "${password}" ]]; then
    hr
    echo "One-time Password : ${password}"
    echo "Note             : password tidak disimpan plaintext di file account info."
  fi
  hr
  pause
}

ssh_delete_user_snapshot_restore() {
  local username="$1"
  local state_mode="$2"
  local state_backup="$3"
  local state_file="$4"
  local state_compat_mode="$5"
  local state_compat_backup="$6"
  local state_compat_file="$7"
  local account_mode="$8"
  local account_backup="$9"
  local account_file="${10}"
  local account_compat_mode="${11}"
  local account_compat_backup="${12}"
  local account_compat_file="${13}"
  local zivpn_mode="${14}"
  local zivpn_backup="${15}"
  local zivpn_file="${16}"
  local -a notes=()

  if ! ssh_optional_file_snapshot_restore "${state_mode}" "${state_backup}" "${state_file}" 600; then
    notes+=("restore state SSH gagal")
  fi
  if ! ssh_optional_file_snapshot_restore "${state_compat_mode}" "${state_compat_backup}" "${state_compat_file}" 600; then
    notes+=("restore state SSH compat gagal")
  fi
  if ! ssh_optional_file_snapshot_restore "${account_mode}" "${account_backup}" "${account_file}" 600; then
    notes+=("restore SSH ACCOUNT INFO gagal")
  fi
  if ! ssh_optional_file_snapshot_restore "${account_compat_mode}" "${account_compat_backup}" "${account_compat_file}" 600; then
    notes+=("restore SSH ACCOUNT INFO compat gagal")
  fi
  if [[ -n "${zivpn_file}" ]]; then
    if ! ssh_optional_file_snapshot_restore "${zivpn_mode}" "${zivpn_backup}" "${zivpn_file}" 600; then
      notes+=("restore password ZIVPN gagal")
    elif zivpn_runtime_available && ! zivpn_sync_runtime_now; then
      notes+=("sync runtime ZIVPN rollback gagal")
    fi
  fi
  if ! ssh_dns_adblock_runtime_refresh_if_available; then
    notes+=("refresh runtime DNS adblock rollback gagal")
  fi
  if ! ssh_network_runtime_refresh_if_available; then
    notes+=("refresh runtime SSH Network rollback gagal")
  fi

  if (( ${#notes[@]} > 0 )); then
    printf '%s\n' "$(IFS=' | '; echo "${notes[*]}")"
    return 1
  fi
  return 0
}

ssh_delete_user_quarantine_for_delete() {
  local username="${1:-}"
  local pending_shell=""
  [[ -n "${username}" ]] || return 1
  pending_shell="$(ssh_pending_login_shell_get)"
  if ! usermod -s "${pending_shell}" "${username}" >/dev/null 2>&1; then
    return 1
  fi
  if ! chage -E 0 "${username}" >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

ssh_delete_user_predelete_restore() {
  local username="${1:-}"
  local linux_meta_file="${2:-}"
  local state_mode="${3:-absent}"
  local state_backup="${4:-}"
  local shell="" expired_at="-"
  [[ -n "${username}" ]] || return 1
  if ! id "${username}" >/dev/null 2>&1; then
    return 1
  fi
  shell="$(ssh_linux_account_snapshot_field_get "${linux_meta_file}" shell 2>/dev/null || true)"
  [[ -n "${shell}" ]] || shell="/bin/bash"
  if ! usermod -s "${shell}" "${username}" >/dev/null 2>&1; then
    return 1
  fi
  expired_at="$(ssh_snapshot_expired_at_read "${state_mode}" "${state_backup}")"
  if ! ssh_apply_expiry "${username}" "${expired_at}"; then
    return 1
  fi
  return 0
}

ssh_snapshot_expired_at_read() {
  local mode="${1:-absent}"
  local backup_file="${2:-}"
  if [[ "${mode}" != "file" || -z "${backup_file}" || ! -f "${backup_file}" ]]; then
    printf '%s\n' "-"
    return 0
  fi
  need_python3
  python3 - <<'PY' "${backup_file}" 2>/dev/null || printf '%s\n' "-"
import json
import re
import sys

try:
  data = json.load(open(sys.argv[1], "r", encoding="utf-8"))
except Exception:
  print("-")
  raise SystemExit(0)

value = str((data or {}).get("expired_at") or "").strip()
match = re.search(r"\d{4}-\d{2}-\d{2}", value)
print(match.group(0) if match else "-")
PY
}

ssh_delete_user_os_rollback() {
  local username="${1:-}"
  local previous_password="${2:-}"
  local state_mode="${3:-absent}"
  local state_backup="${4:-}"
  local state_file="${5:-}"
  local state_compat_mode="${6:-absent}"
  local state_compat_backup="${7:-}"
  local state_compat_file="${8:-}"
  local account_mode="${9:-absent}"
  local account_backup="${10:-}"
  local account_file="${11}"
  local account_compat_mode="${12:-absent}"
  local account_compat_backup="${13:-}"
  local account_compat_file="${14}"
  local zivpn_mode="${15:-absent}"
  local zivpn_backup="${16:-}"
  local zivpn_file="${17:-}"
  local linux_meta_file="${18:-}"
  local home_mode="${19:-absent}"
  local home_backup="${20:-}"
  local expired_at="-"
  local restore_msg=""
  local home_dir="" shell="/bin/bash" primary_group="" supp_groups="" uid="" password_hash="" gecos=""
  local -a useradd_args=()

  [[ -n "${username}" ]] || {
    echo "username rollback kosong"
    return 1
  }
  if [[ -z "${previous_password}" || "${previous_password}" == "-" ]]; then
    echo "password lama tidak tersedia untuk rollback OS"
    return 1
  fi
  if id "${username}" >/dev/null 2>&1; then
    echo "akun Linux '${username}' sudah ada; rollback OS dibatalkan"
    return 1
  fi

  home_dir="$(ssh_linux_account_snapshot_field_get "${linux_meta_file}" home 2>/dev/null || true)"
  shell="$(ssh_linux_account_snapshot_field_get "${linux_meta_file}" shell 2>/dev/null || true)"
  gecos="$(ssh_linux_account_snapshot_field_get "${linux_meta_file}" gecos 2>/dev/null || true)"
  primary_group="$(ssh_linux_account_snapshot_field_get "${linux_meta_file}" primary_group 2>/dev/null || true)"
  supp_groups="$(ssh_linux_account_snapshot_field_get "${linux_meta_file}" supp_groups 2>/dev/null || true)"
  uid="$(ssh_linux_account_snapshot_field_get "${linux_meta_file}" uid 2>/dev/null || true)"
  password_hash="$(ssh_linux_account_snapshot_field_get "${linux_meta_file}" password_hash 2>/dev/null || true)"
  [[ -n "${home_dir}" ]] || home_dir="$(ssh_user_home_dir_default "${username}")"
  [[ -n "${shell}" ]] || shell="/bin/bash"
  useradd_args=(-M -d "${home_dir}" -s "${shell}")
  if [[ -n "${gecos}" ]]; then
    useradd_args+=(-c "${gecos}")
  fi
  if [[ -n "${uid}" && "${uid}" =~ ^[0-9]+$ ]] && ! getent passwd "${uid}" >/dev/null 2>&1; then
    useradd_args+=(-u "${uid}")
  fi
  if [[ -n "${primary_group}" ]] && getent group "${primary_group}" >/dev/null 2>&1; then
    useradd_args+=(-g "${primary_group}")
  fi
  if ! useradd "${useradd_args[@]}" "${username}" >/dev/null 2>&1; then
    echo "gagal membuat ulang user Linux"
    return 1
  fi
  if [[ -n "${password_hash}" && "${password_hash}" != "!" && "${password_hash}" != "*" ]]; then
    if ! usermod -p "${password_hash}" "${username}" >/dev/null 2>&1; then
      userdel -r "${username}" >/dev/null 2>&1 || true
      echo "gagal memulihkan hash password Linux"
      return 1
    fi
  else
    if ! printf '%s:%s\n' "${username}" "${previous_password}" | chpasswd >/dev/null 2>&1; then
      userdel -r "${username}" >/dev/null 2>&1 || true
      echo "gagal memulihkan password Linux"
      return 1
    fi
  fi
  expired_at="$(ssh_snapshot_expired_at_read "${state_mode}" "${state_backup}")"
  if ! ssh_apply_expiry "${username}" "${expired_at}"; then
    userdel -r "${username}" >/dev/null 2>&1 || true
    echo "gagal memulihkan expiry Linux"
    return 1
  fi
  if ! ssh_home_snapshot_restore "${username}" "${home_mode}" "${home_backup}"; then
    userdel -r "${username}" >/dev/null 2>&1 || true
    echo "gagal memulihkan home user Linux"
    return 1
  fi
  if [[ -n "${supp_groups}" ]]; then
    usermod -a -G "${supp_groups}" "${username}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${primary_group}" ]]; then
    chown -R "${username}:${primary_group}" "${home_dir}" >/dev/null 2>&1 || true
  fi

  restore_msg="$(ssh_delete_user_snapshot_restore \
    "${username}" \
    "${state_mode}" "${state_backup}" "${state_file}" \
    "${state_compat_mode}" "${state_compat_backup}" "${state_compat_file}" \
    "${account_mode}" "${account_backup}" "${account_file}" \
    "${account_compat_mode}" "${account_compat_backup}" "${account_compat_file}" \
    "${zivpn_mode}" "${zivpn_backup}" "${zivpn_file}" 2>/dev/null || true)"
  if [[ -n "${restore_msg}" ]]; then
    echo "${restore_msg}"
    return 1
  fi
  echo "ok"
  return 0
}

ssh_delete_user_apply_locked() {
  local username="$1"
  local previous_password="$2"
  local linux_exists="$3"
  local zivpn_file=""
  local cleanup_failed=""
  local delete_txn_dir=""
  local snapshot_dir="" state_mode="absent" state_backup="" state_file=""
  local state_compat_mode="absent" state_compat_backup="" state_compat_file=""
  local account_mode="absent" account_backup="" account_file=""
  local account_compat_mode="absent" account_compat_backup="" account_compat_file=""
  local zivpn_mode="absent" zivpn_backup=""
  local linux_meta_file=""
  local home_mode="absent" home_backup=""
  local rollback_restored="false"
  local -a notes=()

  delete_txn_dir="$(mutation_txn_dir_new "ssh-delete.${username}" 2>/dev/null || true)"
  if [[ -z "${delete_txn_dir}" || ! -d "${delete_txn_dir}" ]]; then
    warn "Gagal menyiapkan journal recovery delete user SSH."
    pause
    return 1
  fi
  if zivpn_runtime_available; then
    zivpn_file="$(zivpn_password_file "${username}")"
  fi
  state_file="$(ssh_user_state_file "${username}")"
  state_compat_file="$(ssh_user_state_compat_file "${username}")"
  account_file="$(ssh_account_info_file "${username}")"
  account_compat_file="${SSH_ACCOUNT_DIR}/${username}.txt"
  snapshot_dir="${delete_txn_dir}"
  if ! ssh_optional_file_snapshot_create "${state_file}" "${snapshot_dir}" state_mode state_backup \
    || ! ssh_optional_file_snapshot_create "${state_compat_file}" "${snapshot_dir}" state_compat_mode state_compat_backup \
    || ! ssh_optional_file_snapshot_create "${account_file}" "${snapshot_dir}" account_mode account_backup \
    || ! ssh_optional_file_snapshot_create "${account_compat_file}" "${snapshot_dir}" account_compat_mode account_compat_backup; then
    mutation_txn_dir_remove "${delete_txn_dir}"
    warn "Gagal membuat snapshot artefak SSH sebelum delete."
    pause
    return 1
  fi
  if [[ -n "${zivpn_file}" ]] && ! ssh_optional_file_snapshot_create "${zivpn_file}" "${snapshot_dir}" zivpn_mode zivpn_backup; then
    mutation_txn_dir_remove "${delete_txn_dir}"
    warn "Gagal membuat snapshot password ZIVPN sebelum delete."
    pause
    return 1
  fi
  if ! ssh_home_snapshot_create "${username}" "${snapshot_dir}" home_mode home_backup; then
    mutation_txn_dir_remove "${delete_txn_dir}"
    warn "Gagal membuat snapshot home user Linux sebelum delete."
    pause
    return 1
  fi
  if [[ "${linux_exists}" == "true" ]] && ! ssh_linux_account_snapshot_create "${username}" "${snapshot_dir}" linux_meta_file; then
    mutation_txn_dir_remove "${delete_txn_dir}"
    warn "Gagal membuat snapshot metadata akun Linux sebelum delete."
    pause
    return 1
  fi
  mutation_txn_field_write "${delete_txn_dir}" username "${username}" >/dev/null 2>&1 || true
  mutation_txn_field_write "${delete_txn_dir}" linux_deleted "0" >/dev/null 2>&1 || true
  [[ -n "${zivpn_file}" ]] && mutation_txn_field_write "${delete_txn_dir}" zivpn_file "${zivpn_file}" >/dev/null 2>&1 || true

  if [[ "${linux_exists}" == "true" ]] && ! ssh_delete_user_quarantine_for_delete "${username}"; then
    local restore_msg=""
    restore_msg="$(ssh_delete_user_snapshot_restore \
      "${username}" \
      "${state_mode}" "${state_backup}" "${state_file}" \
      "${state_compat_mode}" "${state_compat_backup}" "${state_compat_file}" \
      "${account_mode}" "${account_backup}" "${account_file}" \
      "${account_compat_mode}" "${account_compat_backup}" "${account_compat_file}" \
      "${zivpn_mode}" "${zivpn_backup}" "${zivpn_file}" 2>/dev/null || true)"
    mutation_txn_dir_remove "${delete_txn_dir}"
    warn "Gagal mengarantina akun Linux '${username}' sebelum delete."
    [[ -n "${restore_msg}" ]] && warn "Rollback snapshot belum sepenuhnya bersih: ${restore_msg}"
    pause
    return 1
  fi

  cleanup_failed="$(ssh_delete_user_cleanup_after_linux_delete "${username}" "${zivpn_file}" 2>/dev/null || true)"
  if [[ -n "${cleanup_failed}" ]]; then
    local rollback_msg=""
    rollback_msg="$(ssh_delete_user_predelete_restore "${username}" "${linux_meta_file}" "${state_mode}" "${state_backup}" 2>/dev/null || true)"
    if [[ -n "${rollback_msg}" ]]; then
      notes+=("${cleanup_failed}")
      notes+=("rollback status akun Linux gagal: ${rollback_msg}")
    else
      rollback_msg="$(ssh_delete_user_snapshot_restore \
        "${username}" \
        "${state_mode}" "${state_backup}" "${state_file}" \
        "${state_compat_mode}" "${state_compat_backup}" "${state_compat_file}" \
        "${account_mode}" "${account_backup}" "${account_file}" \
        "${account_compat_mode}" "${account_compat_backup}" "${account_compat_file}" \
        "${zivpn_mode}" "${zivpn_backup}" "${zivpn_file}" 2>/dev/null || true)"
      if [[ -z "${rollback_msg}" ]]; then
        rollback_restored="true"
        cleanup_failed=""
        mutation_txn_dir_remove "${delete_txn_dir}"
      else
        notes+=("${cleanup_failed}")
        notes+=("rollback snapshot gagal: ${rollback_msg}")
      fi
    fi
  fi
  if [[ -z "${cleanup_failed}" && "${linux_exists}" == "true" ]] && ! ssh_userdel_purge "${username}" >/dev/null 2>&1; then
    local restore_msg=""
    restore_msg="$(ssh_delete_user_predelete_restore "${username}" "${linux_meta_file}" "${state_mode}" "${state_backup}" 2>/dev/null || true)"
    [[ -n "${restore_msg}" ]] && notes+=("rollback status akun Linux gagal: ${restore_msg}")
    restore_msg="$(ssh_delete_user_snapshot_restore \
      "${username}" \
      "${state_mode}" "${state_backup}" "${state_file}" \
      "${state_compat_mode}" "${state_compat_backup}" "${state_compat_file}" \
      "${account_mode}" "${account_backup}" "${account_file}" \
      "${account_compat_mode}" "${account_compat_backup}" "${account_compat_file}" \
      "${zivpn_mode}" "${zivpn_backup}" "${zivpn_file}" 2>/dev/null || true)"
    [[ -n "${restore_msg}" ]] && notes+=("rollback snapshot gagal: ${restore_msg}")
    cleanup_failed="Gagal menghapus user Linux '${username}' setelah cleanup artefak selesai."
  elif [[ -z "${cleanup_failed}" ]]; then
    mutation_txn_field_write "${delete_txn_dir}" linux_deleted "1" >/dev/null 2>&1 || true
  fi

  title
  if [[ "${rollback_restored}" == "true" ]]; then
    echo "Delete SSH user dibatalkan ⚠"
    echo "Cleanup akhir gagal, tetapi akun Linux dan artefak managed berhasil dipulihkan."
    hr
    pause
    return 1
  fi
  if [[ -n "${cleanup_failed}" ]]; then
    echo "Delete SSH user selesai parsial ⚠"
    echo "Akun Linux sudah terhapus, tetapi cleanup lanjutan belum sepenuhnya bersih."
    if (( ${#notes[@]} > 0 )); then
      printf '%s\n' "$(IFS=' | '; echo "${notes[*]}")"
    fi
    warn "Journal recovery delete SSH dipertahankan di ${delete_txn_dir}."
    hr
    pause
    return 1
  fi

  mutation_txn_dir_remove "${delete_txn_dir}"
  echo "Delete SSH user selesai ✅"
  hr
  echo "Akun Linux dan artefak managed untuk '${username}' berhasil dihapus."
  hr
  pause
  return 0
}

ssh_extend_expiry_apply_locked() {
  local username="$1"
  local new_expiry="$2"
  local previous_expiry="$3"

  if ! ssh_apply_expiry "${username}" "${new_expiry}"; then
    warn "Gagal update expiry untuk '${username}'."
    pause
    return 1
  fi

  local created_at
  created_at="$(ssh_user_state_created_at_get "${username}")"
  if [[ -z "${created_at}" ]]; then
    created_at="$(date '+%Y-%m-%d')"
  fi
  if ! ssh_user_state_write "${username}" "${created_at}" "${new_expiry}"; then
    local rollback_msg=""
    rollback_msg="$(ssh_expiry_update_rollback "${username}" "${previous_expiry}" 2>/dev/null || true)"
    if [[ -n "${rollback_msg}" ]]; then
      warn "Metadata SSH gagal diperbarui untuk '${username}'. Rollback: ${rollback_msg}"
    else
      warn "Metadata SSH gagal diperbarui untuk '${username}'."
    fi
    pause
    return 1
  fi
  if ! ssh_account_info_refresh_from_state "${username}"; then
    local rollback_msg=""
    rollback_msg="$(ssh_expiry_update_rollback "${username}" "${previous_expiry}" 2>/dev/null || true)"
    if [[ -n "${rollback_msg}" ]]; then
      warn "SSH ACCOUNT INFO gagal disinkronkan untuk '${username}'. Rollback: ${rollback_msg}"
    else
      warn "SSH ACCOUNT INFO gagal disinkronkan untuk '${username}'."
    fi
    pause
    return 1
  fi

  log "Expiry akun '${username}' diperbarui ke ${new_expiry}."
  pause
}

ssh_reset_password_apply_locked() {
  local username="$1"
  local previous_password="$2"
  local password="$3"
  local snapshot_dir="" account_snapshot_mode="absent" account_snapshot_backup="" account_file=""
  local zivpn_snapshot_mode="absent" zivpn_snapshot_backup="" zivpn_file=""

  account_file="$(ssh_account_info_file "${username}")"
  if zivpn_runtime_available; then
    zivpn_file="$(zivpn_password_file "${username}")"
  fi
  snapshot_dir="$(mktemp -d "${TMPDIR:-/tmp}/ssh-reset.${username}.XXXXXX" 2>/dev/null || true)"
  if [[ -z "${snapshot_dir}" || ! -d "${snapshot_dir}" ]]; then
    warn "Gagal menyiapkan snapshot rollback password SSH."
    pause
    return 1
  fi
  if ! ssh_optional_file_snapshot_create "${account_file}" "${snapshot_dir}" account_snapshot_mode account_snapshot_backup; then
    rm -rf "${snapshot_dir}" >/dev/null 2>&1 || true
    warn "Gagal membuat snapshot SSH ACCOUNT INFO sebelum reset password."
    pause
    return 1
  fi
  if [[ -n "${zivpn_file}" ]]; then
    if ! ssh_optional_file_snapshot_create "${zivpn_file}" "${snapshot_dir}" zivpn_snapshot_mode zivpn_snapshot_backup; then
      rm -rf "${snapshot_dir}" >/dev/null 2>&1 || true
      warn "Gagal membuat snapshot password ZIVPN sebelum reset password."
      pause
      return 1
    fi
  fi

  if ! ssh_apply_password "${username}" "${password}"; then
    rm -rf "${snapshot_dir}" >/dev/null 2>&1 || true
    warn "Gagal reset password user '${username}'."
    pause
    return 1
  fi

  if ! ssh_account_info_refresh_from_state "${username}" "${password}"; then
    local rollback_msg=""
    rollback_msg="$(ssh_password_reset_rollback "${username}" "${previous_password}" "${account_snapshot_mode}" "${account_snapshot_backup}" "${account_file}" "${zivpn_snapshot_mode}" "${zivpn_snapshot_backup}" "${zivpn_file}" 2>/dev/null || true)"
    rm -rf "${snapshot_dir}" >/dev/null 2>&1 || true
    if [[ -n "${rollback_msg}" ]]; then
      warn "SSH ACCOUNT INFO gagal disinkronkan untuk '${username}'. Rollback: ${rollback_msg}"
    else
      warn "SSH ACCOUNT INFO gagal disinkronkan untuk '${username}'."
    fi
    pause
    return 1
  fi
  if ! zivpn_sync_user_password_warn "${username}" "${password}"; then
    local rollback_msg=""
    rollback_msg="$(ssh_password_reset_rollback "${username}" "${previous_password}" "${account_snapshot_mode}" "${account_snapshot_backup}" "${account_file}" "${zivpn_snapshot_mode}" "${zivpn_snapshot_backup}" "${zivpn_file}" 2>/dev/null || true)"
    rm -rf "${snapshot_dir}" >/dev/null 2>&1 || true
    if [[ -n "${rollback_msg}" ]]; then
      warn "Runtime ZIVPN gagal disinkronkan untuk '${username}'. Rollback: ${rollback_msg}"
    else
      warn "Runtime ZIVPN gagal disinkronkan untuk '${username}'."
    fi
    pause
    return 1
  fi
  if ! ssh_account_info_refresh_from_state "${username}" "${password}"; then
    local rollback_msg=""
    rollback_msg="$(ssh_password_reset_rollback "${username}" "${previous_password}" "${account_snapshot_mode}" "${account_snapshot_backup}" "${account_file}" "${zivpn_snapshot_mode}" "${zivpn_snapshot_backup}" "${zivpn_file}" 2>/dev/null || true)"
    rm -rf "${snapshot_dir}" >/dev/null 2>&1 || true
    if [[ -n "${rollback_msg}" ]]; then
      warn "Refresh final SSH ACCOUNT INFO gagal untuk '${username}'. Rollback: ${rollback_msg}"
    else
      warn "Refresh final SSH ACCOUNT INFO gagal untuk '${username}'."
    fi
    pause
    return 1
  fi
  if [[ "$(ssh_account_info_password_mode)" != "store" && -n "${password}" ]]; then
    hr
    echo "One-time Password : ${password}"
    echo "Note             : password tidak disimpan plaintext di file account info."
    hr
  fi
  rm -rf "${snapshot_dir}" >/dev/null 2>&1 || true

  log "Password akun '${username}' berhasil direset."
  pause
}

ssh_add_user_menu() {
  local username qf acc_file header_page=0
  while true; do
    title
  echo "2) SSH Users > Add User"
    hr
    ssh_add_user_header_render header_page
    hr

    if ! read -r -p "Username SSH (atau next/previous/kembali): " username; then
      echo
      return 0
    fi
    if is_back_choice "${username}"; then
      return 0
    fi
    case "${username,,}" in
      next|n)
        header_page=$((header_page + 1))
        continue
        ;;
      previous|prev|p)
        header_page=$((header_page - 1))
        continue
        ;;
    esac
    username="${username,,}"
    break
  done

  if ! ssh_username_valid "${username}"; then
    warn "Username tidak valid. Gunakan format Linux user (huruf kecil/angka/_/-)."
    pause
    return 0
  fi
  local dup_reason=""
  if dup_reason="$(ssh_username_duplicate_reason "${username}")"; then
    warn "${dup_reason}"
    pause
    return 0
  fi
  qf="$(ssh_user_state_file "${username}")"
  acc_file="$(ssh_account_info_file "${username}")"

  local password=""
  if ! ssh_read_password_confirm password; then
    pause
    return 0
  fi
  if [[ "${username,,}" == "${password,,}" ]]; then
    warn "Password SSH tidak boleh sama dengan username."
    pause
    return 0
  fi

  local active_days
  if ! read -r -p "Masa aktif (hari) (atau kembali): " active_days; then
    echo
    return 0
  fi
  if is_back_choice "${active_days}"; then
    return 0
  fi
  if [[ -z "${active_days}" || ! "${active_days}" =~ ^[0-9]+$ || "${active_days}" -le 0 ]]; then
    warn "Masa aktif harus angka hari > 0."
    pause
    return 0
  fi

  local quota_input quota_gb quota_bytes
  if ! read -r -p "Quota (GB) (atau kembali): " quota_input; then
    echo
    return 0
  fi
  if is_back_choice "${quota_input}"; then
    return 0
  fi
  quota_gb="$(normalize_gb_input "${quota_input}")"
  if [[ -z "${quota_gb}" ]]; then
    warn "Format quota tidak valid. Contoh: 5 atau 5GB."
    pause
    return 0
  fi
  quota_bytes="$(bytes_from_gb "${quota_gb}")"

  local ip_toggle ip_enabled="false" ip_limit="0"
  echo "Limit IP? (on/off)"
  if ! read_required_on_off ip_toggle "IP Limit (on/off) (atau kembali): "; then
    return 0
  fi
  case "${ip_toggle}" in
    on)
      ip_enabled="true"
      if ! read -r -p "Limit IP (angka) (atau kembali): " ip_limit; then
        echo
        return 0
      fi
      if is_back_word_choice "${ip_limit}"; then
        return 0
      fi
      if [[ -z "${ip_limit}" || ! "${ip_limit}" =~ ^[0-9]+$ || "${ip_limit}" -le 0 ]]; then
        warn "Limit IP harus angka > 0."
        pause
        return 0
      fi
      ;;
    off) ip_enabled="false" ; ip_limit="0" ;;
    *)
      warn "Pilihan Limit IP harus on/off."
      pause
      return 0
      ;;
  esac

  local speed_toggle speed_enabled="false" speed_down="0" speed_up="0"
  echo "Limit speed per user? (on/off)"
  if ! read_required_on_off speed_toggle "Speed Limit (on/off) (atau kembali): "; then
    return 0
  fi
  case "${speed_toggle}" in
    on)
      speed_enabled="true"
      if ! read -r -p "Speed Download Mbps (contoh: 20 atau 20mbit) (atau kembali): " speed_down; then
        echo
        return 0
      fi
      if is_back_word_choice "${speed_down}"; then
        return 0
      fi
      speed_down="$(normalize_speed_mbit_input "${speed_down}")"
      if [[ -z "${speed_down}" ]] || ! speed_mbit_is_positive "${speed_down}"; then
        warn "Speed download tidak valid. Gunakan angka > 0."
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
      speed_up="$(normalize_speed_mbit_input "${speed_up}")"
      if [[ -z "${speed_up}" ]] || ! speed_mbit_is_positive "${speed_up}"; then
        warn "Speed upload tidak valid. Gunakan angka > 0."
        pause
        return 0
      fi
      ;;
    off)
      speed_enabled="false"
      speed_down="0"
      speed_up="0"
      ;;
    *)
      warn "Pilihan speed limit harus on/off."
      pause
      return 0
      ;;
  esac

  local expired_at created_at
  expired_at="$(date -d "+${active_days} days" '+%Y-%m-%d' 2>/dev/null || true)"
  if [[ -z "${expired_at}" ]]; then
    warn "Gagal menghitung tanggal expiry SSH."
    pause
    return 1
  fi
  created_at="$(date '+%Y-%m-%d')"

  hr
  echo "Ringkasan:"
  echo "  Username : ${username}"
  echo "  Expired  : ${active_days} hari (sampai ${expired_at})"
  echo "  Quota    : ${quota_gb} GB"
  echo "  IP Limit : ${ip_enabled} $( [[ "${ip_enabled}" == "true" ]] && echo "(${ip_limit})" )"
  if [[ "${speed_enabled}" == "true" ]]; then
    echo "  Speed    : true (DOWN ${speed_down} Mbps | UP ${speed_up} Mbps)"
  else
    echo "  Speed    : false"
  fi
  hr
  local create_confirm_rc=0
  if confirm_yn_or_back "Buat akun SSH ini sekarang?"; then
    :
  else
    create_confirm_rc=$?
    if (( create_confirm_rc == 2 )); then
      warn "Pembuatan akun SSH dibatalkan (kembali)."
      pause
      return 0
    fi
    warn "Pembuatan akun SSH dibatalkan."
    pause
    return 0
  fi

  if user_data_mutation_run_locked ssh_add_user_apply_locked "${username}" "${qf}" "${acc_file}" "${password}" "${expired_at}" "${created_at}" "${quota_bytes}" "${ip_enabled}" "${ip_limit}" "${speed_enabled}" "${speed_down}" "${speed_up}"; then
    password=""
    return 0
  fi
  password=""
  return 1
}

ssh_delete_user_menu() {
  title
  echo "2) SSH Users > Delete User"
  hr

  local username
  if ! ssh_pick_managed_user username; then
    pause
    return 0
  fi

  local ask_rc=0
  if ! confirm_yn_or_back "Hapus akun SSH '${username}' sekarang?"; then
    ask_rc=$?
    if (( ask_rc == 2 )); then
      return 0
    fi
    warn "Dibatalkan."
    pause
    return 0
  fi

  local previous_password
  previous_password="$(ssh_previous_password_get "${username}")"
  local linux_exists="false"
  if id "${username}" >/dev/null 2>&1; then
    linux_exists="true"
  fi
  user_data_mutation_run_locked ssh_delete_user_apply_locked "${username}" "${previous_password}" "${linux_exists}"
}

ssh_extend_expiry_menu() {
  title
  echo "2) SSH Users > Set Expiry"
  hr

  local username
  if ! ssh_pick_managed_user username; then
    pause
    return 0
  fi
  if ! id "${username}" >/dev/null 2>&1; then
    warn "User Linux '${username}' tidak ditemukan."
    pause
    return 0
  fi

  local current_exp
  current_exp="$(chage -l "${username}" 2>/dev/null | awk -F': ' '/Account expires/{print $2; exit}' || true)"
  [[ -n "${current_exp}" ]] || current_exp="-"
  echo "Expiry saat ini: ${current_exp}"
  hr
  echo "  1) Add days from today"
  echo "  2) Set date (YYYY-MM-DD)"
  echo "  0) Back"
  hr

  local mode
  if ! read -r -p "Pilih: " mode; then
    echo
    return 0
  fi
  if is_back_choice "${mode}"; then
    return 0
  fi

  local new_expiry=""
  case "${mode}" in
    1)
      local add_days
      if ! read -r -p "Tambah berapa hari: " add_days; then
        echo
        return 0
      fi
      if is_back_choice "${add_days}"; then
        return 0
      fi
      if [[ ! "${add_days}" =~ ^[0-9]+$ ]] || (( add_days < 1 || add_days > 3650 )); then
        warn "Input hari tidak valid."
        pause
        return 0
      fi
      new_expiry="$(date -d "+${add_days} days" '+%Y-%m-%d' 2>/dev/null || true)"
      ;;
    2)
      if ! read -r -p "Tanggal expiry baru (YYYY-MM-DD): " new_expiry; then
        echo
        return 0
      fi
      if is_back_choice "${new_expiry}"; then
        return 0
      fi
      if ! new_expiry="$(ssh_strict_date_ymd_normalize "${new_expiry}" 2>/dev/null)"; then
        warn "Format tanggal tidak valid."
        pause
        return 0
      fi
      ;;
    *)
      invalid_choice
      return 0
      ;;
  esac

  if [[ -z "${new_expiry}" ]]; then
    warn "Gagal menentukan expiry baru."
    pause
    return 0
  fi

  if date_ymd_is_past "${new_expiry}"; then
    warn "Tanggal expiry ${new_expiry} sudah lewat dan akan membuat akun segera expired."
    if ! confirm_menu_apply_now "Tetap terapkan expiry lampau ${new_expiry} untuk akun SSH ${username}?"; then
      pause
      return 0
    fi
  fi

  hr
  echo "Ringkasan perubahan:"
  echo "  Username : ${username}"
  echo "  Expiry baru : ${new_expiry}"
  hr
  local confirm_rc=0
  if confirm_yn_or_back "Update expiry akun SSH ini sekarang?"; then
    :
  else
    confirm_rc=$?
    if (( confirm_rc == 2 )); then
      warn "Update expiry SSH dibatalkan (kembali)."
      pause
      return 0
    fi
    warn "Update expiry SSH dibatalkan."
    pause
    return 0
  fi

  local previous_expiry
  previous_expiry="$(ssh_user_state_expired_at_get "${username}" 2>/dev/null || true)"
  [[ -n "${previous_expiry}" ]] || previous_expiry="-"
  user_data_mutation_run_locked ssh_extend_expiry_apply_locked "${username}" "${new_expiry}" "${previous_expiry}"
}

ssh_reset_password_menu() {
  title
  echo "2) SSH Users > Reset Password"
  hr

  local username
  if ! ssh_pick_managed_user username; then
    pause
    return 0
  fi
  if ! id "${username}" >/dev/null 2>&1; then
    warn "User Linux '${username}' tidak ditemukan."
    pause
    return 0
  fi

  local previous_password
  previous_password="$(ssh_previous_password_get "${username}")"
  if [[ -z "${previous_password}" || "${previous_password}" == "-" ]]; then
    warn "Password lama untuk '${username}' tidak tersedia, jadi rollback aman tidak bisa dijamin."
    pause
    return 0
  fi

  local password=""
  if ! ssh_read_password_confirm password; then
    pause
    return 0
  fi

  local reset_confirm_rc=0
  if confirm_yn_or_back "Reset password akun SSH ini sekarang?"; then
    :
  else
    reset_confirm_rc=$?
    if (( reset_confirm_rc == 2 )); then
      warn "Reset password SSH dibatalkan (kembali)."
      pause
      return 0
    fi
    warn "Reset password SSH dibatalkan."
    pause
    return 0
  fi

  if user_data_mutation_run_locked ssh_reset_password_apply_locked "${username}" "${previous_password}" "${password}"; then
    password=""
    return 0
  fi
  password=""
  return 1
}

ssh_list_users_menu() {
  local -a users=()
  local u

  ssh_state_dirs_prepare
  need_python3

  while IFS= read -r u; do
    [[ -n "${u}" ]] || continue
    if ssh_add_txn_linux_pending_contains "${u}"; then
      continue
    fi
    users+=("${u}")
  done < <(find "${SSH_USERS_STATE_DIR}" -maxdepth 1 -type f -name '*.json' -printf '%f\n' 2>/dev/null | sed -E 's/@ssh\.json$//' | sed -E 's/\.json$//' | sort -u)

  if (( ${#users[@]} == 0 )); then
    title
    echo "2) SSH Users > List Users"
    hr
    warn "Belum ada akun SSH terkelola."
    hr
    pause
    return 0
  fi

  while true; do
    title
    echo "2) SSH Users > List Users"
    hr
    printf "%-4s %-20s %-12s %-12s %-12s\n" "No" "Username" "Created" "Expired" "SystemUser"
    local i username qf fields meta_user created expired sys_user
    for i in "${!users[@]}"; do
      username="${users[$i]}"
      qf="$(ssh_user_state_file "${username}")"
      fields="$(python3 - <<'PY' "${qf}" 2>/dev/null || true
import json
import re
import sys
from datetime import datetime

path = sys.argv[1]
username = ""
created = "-"
expired = "-"

def norm_created(v):
  s = str(v or "").strip()
  if not s or s == "-":
    return "-"
  s = s.replace("T", " ").strip()
  if s.endswith("Z"):
    s = s[:-1]
  if len(s) >= 10 and re.match(r"^\d{4}-\d{2}-\d{2}$", s[:10]):
    return s[:10]
  try:
    dt = datetime.fromisoformat(s)
    return dt.strftime("%Y-%m-%d")
  except Exception:
    pass
  m = re.search(r"\d{4}-\d{2}-\d{2}", s)
  if m:
    return m.group(0)
  return "-"

def norm_expired(v):
  s = str(v or "").strip()
  if not s or s == "-":
    return "-"
  m = re.search(r"\d{4}-\d{2}-\d{2}", s)
  return m.group(0) if m else "-"

try:
  with open(path, "r", encoding="utf-8") as f:
    d = json.load(f)
  if isinstance(d, dict):
    username = str(d.get("username") or "").strip()
    created = norm_created(d.get("created_at"))
    expired = norm_expired(d.get("expired_at"))
except Exception:
  pass
print("|".join([username, created, expired]))
PY
)"
      IFS='|' read -r meta_user created expired <<<"${fields}"
      if [[ -n "${meta_user}" ]]; then
        meta_user="$(ssh_username_from_key "${meta_user}")"
        [[ -n "${meta_user}" ]] && username="${meta_user}"
      fi
      sys_user="present"
      if ! id "${username}" >/dev/null 2>&1; then
        sys_user="missing"
      fi
      printf "%-4s %-20s %-12s %-12s %-12s\n" "$((i + 1))" "${username}" "${created}" "${expired}" "${sys_user}"
    done
    hr
    echo "Ketik NO untuk lihat detail SSH ACCOUNT INFO."
    echo "0/back untuk kembali ke SSH Users."
    hr

    local pick
    if ! read -r -p "Pilih: " pick; then
      echo
      return 0
    fi
    if is_back_choice "${pick}"; then
      return 0
    fi
    if [[ ! "${pick}" =~ ^[0-9]+$ ]] || (( pick < 1 || pick > ${#users[@]} )); then
      warn "Pilihan tidak valid."
      sleep 1
      continue
    fi

    username="${users[$((pick - 1))]}"
    local acc_file password_info
    ssh_account_info_refresh_warn "${username}" || true
    acc_file="$(ssh_account_info_file "${username}")"

    title
    echo "2) SSH Users > SSH ACCOUNT INFO"
    hr
    echo "Username : ${username}"
    echo "File     : ${acc_file}"
    hr
    if [[ -f "${acc_file}" ]]; then
      cat "${acc_file}"
      password_info="$(grep -E '^Password[[:space:]]*:' "${acc_file}" 2>/dev/null | head -n1 | sed -E 's/^Password[[:space:]]*:[[:space:]]*//' || true)"
      if [[ "$(ssh_account_info_password_mode)" != "store" || -z "${password_info}" || "${password_info}" == "********" ]]; then
        hr
        warn "Password plaintext tidak tersedia di account info (mode mask)."
        echo "Gunakan menu 4) Reset Password untuk mendapatkan one-time password."
      fi
    else
      warn "SSH ACCOUNT INFO tidak ditemukan untuk '${username}'."
    fi
    hr
    pause
  done
}

sshws_active_sessions_collect_rows() {
  SSHWS_SESSION_ROWS=()
  local dropbear_port
  local stale_sec
  dropbear_port="$(sshws_detect_dropbear_port)"
  stale_sec="$(sshws_runtime_session_stale_sec)"
  need_python3

  local row
  while IFS= read -r row; do
    [[ -n "${row}" ]] || continue
    SSHWS_SESSION_ROWS+=("${row}")
  done < <(python3 - <<'PY' "${SSH_USERS_STATE_DIR}" "${dropbear_port}" "${SSHWS_RUNTIME_SESSION_DIR:-/run/autoscript/sshws-sessions}" "${stale_sec}" 2>/dev/null || true
import glob
import ipaddress
import json
import os
import pwd
import re
import subprocess
import sys
import time
from collections import defaultdict, deque

state_root = sys.argv[1]
try:
  dropbear_port = int(sys.argv[2])
except Exception:
  dropbear_port = 0
session_root = sys.argv[3] if len(sys.argv) > 3 else ""
stale_sec = int(float(sys.argv[4] or 90))

def norm_user(v):
  s = str(v or "").strip()
  if s.endswith("@ssh"):
    s = s[:-4]
  if "@" in s:
    s = s.split("@", 1)[0]
  return s

def to_bool(v):
  if isinstance(v, bool):
    return v
  if isinstance(v, (int, float)):
    return bool(v)
  return str(v or "").strip().lower() in ("1", "true", "yes", "on", "y")

def _parse_port(addr):
  s = str(addr or "").strip()
  if not s:
    return -1
  if s.startswith("[") and "]:" in s:
    s = s.rsplit("]:", 1)[-1]
  elif ":" in s:
    s = s.rsplit(":", 1)[-1]
  try:
    return int(s)
  except Exception:
    return -1

def _fmt_age(created_at, updated_at):
  now = int(time.time())
  base = 0
  try:
    base = int(created_at or 0)
  except Exception:
    base = 0
  if base <= 0:
    try:
      base = int(updated_at or 0)
    except Exception:
      base = 0
  if base <= 0 or now <= base:
    return "-"
  secs = now - base
  if secs < 60:
    return f"{secs}s"
  mins, rem = divmod(secs, 60)
  if mins < 60:
    return f"{mins}m"
  hours, rem_m = divmod(mins, 60)
  if hours < 24:
    return f"{hours}h{rem_m:02d}m"
  days, rem_h = divmod(hours, 24)
  return f"{days}d{rem_h:02d}h"

def _fmt_ts(ts):
  try:
    value = int(ts or 0)
  except Exception:
    value = 0
  if value <= 0:
    return "-"
  return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(value))

def _mode_label(transport, source):
  t = str(transport or "").strip().lower()
  s = str(source or "").strip().lower()
  if "ssh-ws" in t or s == "sshws-proxy":
    return "SSH WS"
  if "tls-port" in t:
    return "SSH SSL/TLS"
  if "http-port" in t:
    return "SSH Direct"
  if "ssh" in t:
    return "SSH"
  return "SSH"

def normalize_ip(v):
  s = str(v or "").strip()
  if not s:
    return ""
  if s.startswith("[") and s.endswith("]"):
    s = s[1:-1].strip()
  try:
    return str(ipaddress.ip_address(s))
  except Exception:
    return ""

def _pid_alive(pid):
  try:
    value = int(pid)
  except Exception:
    return False
  if value <= 0:
    return False
  try:
    os.kill(value, 0)
    return True
  except ProcessLookupError:
    return False
  except PermissionError:
    return True
  except Exception:
    return False

def _runtime_payload_valid(payload):
  if not isinstance(payload, dict):
    return False
  if not _pid_alive(payload.get("proxy_pid")):
    return False
  try:
    updated_at = int(float(payload.get("updated_at") or 0))
  except Exception:
    return False
  now = int(time.time())
  if updated_at <= 0 or now <= 0:
    return False
  return (now - updated_at) <= stale_sec

def _build_proc_tables():
  info = {}
  children = defaultdict(list)
  for st in glob.glob("/proc/[0-9]*/status"):
    try:
      pid = int(st.split("/")[2])
      ppid = 0
      uid = 0
      with open(st, "r", encoding="utf-8", errors="ignore") as f:
        for line in f:
          if line.startswith("PPid:"):
            ppid = int(line.split()[1])
          elif line.startswith("Uid:"):
            uid = int(line.split()[1])
      info[pid] = (ppid, uid)
      children[ppid].append(pid)
    except Exception:
      continue
  return info, children

def _username_from_pid(pid, proc_info, children):
  q = deque([int(pid)])
  seen = set()
  while q:
    cur = q.popleft()
    if cur in seen:
      continue
    seen.add(cur)
    meta = proc_info.get(cur)
    if not meta:
      continue
    uid = int(meta[1])
    if uid > 0:
      try:
        return pwd.getpwuid(uid).pw_name
      except KeyError:
        return ""
    for child in children.get(cur, ()):
      q.append(child)
  return ""

meta_map = {}
if os.path.isdir(state_root):
  for name in os.listdir(state_root):
    if not name.endswith(".json"):
      continue
    path = os.path.join(state_root, name)
    username = norm_user(name[:-5])
    reason = "-"
    lock_state = "OFF"
    try:
      with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
      if isinstance(data, dict):
        username = norm_user(data.get("username") or username) or username
        status = data.get("status")
        if not isinstance(status, dict):
          status = {}
        lock_reason = str(status.get("lock_reason") or "").strip().lower()
        reason = lock_reason.upper() if lock_reason else "-"
        lock_state = "ON" if to_bool(status.get("account_locked")) else "OFF"
    except Exception:
      pass
    if username:
      meta_map[username] = {"reason": reason, "lock": lock_state}

runtime_by_port = {}
if session_root and os.path.isdir(session_root):
  for name in os.listdir(session_root):
    if not name.endswith(".json"):
      continue
    path = os.path.join(session_root, name)
    try:
      with open(path, "r", encoding="utf-8") as f:
        payload = json.load(f)
      if not _runtime_payload_valid(payload):
        continue
    except Exception:
      continue
    port = _parse_port(payload.get("backend_local_port") or payload.get("local_port") or name[:-5])
    if port <= 0:
      continue
    runtime_by_port[port] = {
      "username": norm_user(payload.get("username")),
      "client_ip": normalize_ip(payload.get("client_ip")) or "-",
      "source": str(payload.get("source") or "runtime").strip() or "runtime",
      "backend": str(payload.get("backend") or "dropbear").strip() or "dropbear",
      "transport": str(payload.get("transport") or "").strip(),
      "created_at": int(float(payload.get("created_at") or 0)),
      "updated_at": int(float(payload.get("updated_at") or 0)),
    }

rows = []
runtime_ports_seen = set()
proc_info = {}
children = {}
if dropbear_port > 0:
  try:
    res = subprocess.run(
      ["ss", "-tnpH"],
      check=False,
      capture_output=True,
      text=True,
      timeout=1.5,
    )
  except Exception:
    res = None

  if res is not None and res.returncode == 0:
    proc_info, children = _build_proc_tables()
    for raw in (res.stdout or "").splitlines():
      line = raw.strip()
      if not line or "dropbear" not in line:
        continue
      cols = line.split()
      if len(cols) < 6:
        continue
      lport = _parse_port(cols[3])
      if lport != dropbear_port:
        continue
      peer = cols[4]
      m = re.search(r"pid=(\d+)", line)
      if not m:
        continue
      pid = int(m.group(1))
      peer_port = _parse_port(peer)
      runtime_meta = runtime_by_port.get(peer_port, {}) if peer_port > 0 else {}
      username = _username_from_pid(pid, proc_info, children) or runtime_meta.get("username") or "unknown"
      if peer_port > 0:
        runtime_ports_seen.add(peer_port)
      source = runtime_meta.get("source") or "dropbear-scan"
      backend = runtime_meta.get("backend") or "dropbear"
      transport = runtime_meta.get("transport") or ""
      created_at = runtime_meta.get("created_at") or 0
      updated_at = runtime_meta.get("updated_at") or 0
      rows.append({
        "username": username,
        "mode": _mode_label(transport, source),
        "peer": peer,
        "pid": str(pid),
        "client_ip": runtime_meta.get("client_ip") or "-",
        "state": "mapped" if runtime_meta else "socket-only",
        "source": source,
        "backend": backend,
        "created_at": int(created_at or 0),
        "updated_at": int(updated_at or 0),
        "_sort_pid": pid,
      })

for port, runtime_meta in sorted(runtime_by_port.items()):
  if port in runtime_ports_seen:
    continue
  rows.append({
    "username": runtime_meta.get("username") or "unknown",
    "mode": _mode_label(runtime_meta.get("transport"), runtime_meta.get("source")),
    "peer": "runtime-port:{}".format(port),
    "pid": "-",
    "client_ip": runtime_meta.get("client_ip") or "-",
    "state": "runtime-only",
    "source": runtime_meta.get("source") or "runtime",
    "backend": runtime_meta.get("backend") or "dropbear",
    "created_at": int(runtime_meta.get("created_at") or 0),
    "updated_at": int(runtime_meta.get("updated_at") or 0),
    "_sort_pid": 0,
  })

counts = defaultdict(int)
for row in rows:
  counts[row["username"]] += 1

rows.sort(key=lambda item: (item["username"].lower(), int(item.get("_sort_pid") or 0), item["peer"]))
for row in rows:
  meta = meta_map.get(row["username"], {})
  print("|".join([
    row["username"],
    row.get("mode") or "SSH",
    row["client_ip"],
    row["peer"],
    str(row["pid"]),
    str(counts.get(row["username"], 1)),
    str(meta.get("reason") or "-"),
    str(meta.get("lock") or "OFF"),
    _fmt_age(row.get("created_at"), row.get("updated_at")),
    row.get("state") or "-",
    row.get("backend") or "dropbear",
    row.get("source") or "-",
    _fmt_ts(row.get("created_at")),
    _fmt_ts(row.get("updated_at")),
  ]))
PY
)
}

sshws_active_sessions_apply_filter() {
  SSHWS_SESSION_VIEW_INDEXES=()
  local q="${SSHWS_SESSION_QUERY,,}"
  local i row
  for i in "${!SSHWS_SESSION_ROWS[@]}"; do
    row="${SSHWS_SESSION_ROWS[$i]}"
    if [[ -z "${q}" || "${row,,}" == *"${q}"* ]]; then
      SSHWS_SESSION_VIEW_INDEXES+=("${i}")
    fi
  done
  sshws_active_sessions_update_summary
}

sshws_active_sessions_update_summary() {
  SSHWS_SESSION_DISTINCT_IPS=0
  SSHWS_SESSION_MODE_SUMMARY="-"
  local -A ips=()
  local -A modes=()
  local real_idx row mode client_ip
  for real_idx in "${SSHWS_SESSION_VIEW_INDEXES[@]}"; do
    row="${SSHWS_SESSION_ROWS[$real_idx]}"
    IFS='|' read -r _ mode client_ip _ <<<"${row}"
    if [[ -n "${client_ip}" && "${client_ip}" != "-" ]]; then
      ips["${client_ip}"]=1
    fi
    if [[ -n "${mode}" ]]; then
      modes["${mode}"]=$(( ${modes["${mode}"]:-0} + 1 ))
    fi
  done
  SSHWS_SESSION_DISTINCT_IPS="${#ips[@]}"
  local parts=()
  local label
  for label in "SSH WS" "SSH SSL/TLS" "SSH Direct" "SSH"; do
    if [[ -n "${modes["${label}"]:-}" ]]; then
      parts+=("${label}=${modes["${label}"]}")
    fi
  done
  if ((${#parts[@]} > 0)); then
    local joined="${parts[0]}"
    local i
    for (( i=1; i<${#parts[@]}; i++ )); do
      joined+=" | ${parts[$i]}"
    done
    SSHWS_SESSION_MODE_SUMMARY="${joined}"
  fi
}

sshws_active_sessions_print_page() {
  local page="${1:-0}"
  local total="${#SSHWS_SESSION_VIEW_INDEXES[@]}"
  local pages=0
  local display_pages=1
  if (( total > 0 )); then
    pages=$(( (total + SSHWS_SESSION_PAGE_SIZE - 1) / SSHWS_SESSION_PAGE_SIZE ))
    display_pages="${pages}"
  fi
  if (( page < 0 )); then
    page=0
  fi
  if (( pages > 0 && page >= pages )); then
    page=$((pages - 1))
  fi
  SSHWS_SESSION_PAGE="${page}"

  echo "Active SSH sessions: ${total} | Distinct IPs: ${SSHWS_SESSION_DISTINCT_IPS:-0} | page $((page + 1))/${display_pages}"
  if [[ -n "${SSHWS_SESSION_QUERY}" ]]; then
    echo "Filter: '${SSHWS_SESSION_QUERY}'"
  fi
  if [[ "${SSHWS_SESSION_MODE_SUMMARY:-"-"}" != "-" ]]; then
    echo "Modes: ${SSHWS_SESSION_MODE_SUMMARY}"
  fi
  echo "State runtime-only/socket-only akan muncul jika korelasi socket belum lengkap."
  echo

  if (( total == 0 )); then
    echo "Tidak ada sesi SSH aktif."
    return 0
  fi

  printf "%-4s %-18s %-14s %-16s %-8s %-6s %-6s\n" "NO" "Username" "Mode" "Client IP" "Age" "Sess" "Lock"
  hr

  local start end i list_pos real_idx row username mode client_ip peer pid sess reason lock age
  start=$((page * SSHWS_SESSION_PAGE_SIZE))
  end=$((start + SSHWS_SESSION_PAGE_SIZE))
  if (( end > total )); then
    end="${total}"
  fi
  for (( i=start; i<end; i++ )); do
    list_pos="${i}"
    real_idx="${SSHWS_SESSION_VIEW_INDEXES[$list_pos]}"
    row="${SSHWS_SESSION_ROWS[$real_idx]}"
    IFS='|' read -r username mode client_ip peer pid sess reason lock age _ <<<"${row}"
    printf "%-4s %-18s %-14s %-16s %-8s %-6s %-6s\n" "$((i - start + 1))" "${username}" "${mode}" "${client_ip}" "${age}" "${sess}" "${lock}"
  done
}

sshws_active_session_detail() {
  local view_no="${1:-}"
  [[ "${view_no}" =~ ^[0-9]+$ ]] || { warn "Input bukan angka"; pause; return 0; }

  local total page pages start end rows
  total="${#SSHWS_SESSION_VIEW_INDEXES[@]}"
  if (( total <= 0 )); then
    warn "Tidak ada sesi aktif."
    pause
    return 0
  fi

  page="${SSHWS_SESSION_PAGE:-0}"
  pages=$(( (total + SSHWS_SESSION_PAGE_SIZE - 1) / SSHWS_SESSION_PAGE_SIZE ))
  if (( page < 0 )); then page=0; fi
  if (( pages > 0 && page >= pages )); then page=$((pages - 1)); fi
  start=$((page * SSHWS_SESSION_PAGE_SIZE))
  end=$((start + SSHWS_SESSION_PAGE_SIZE))
  if (( end > total )); then end="${total}"; fi
  rows=$((end - start))

  if (( view_no < 1 || view_no > rows )); then
    warn "NO di luar range"
    pause
    return 0
  fi

  local list_pos real_idx row username mode client_ip peer pid sess reason lock age state backend source started updated
  list_pos=$((start + view_no - 1))
  real_idx="${SSHWS_SESSION_VIEW_INDEXES[$list_pos]}"
  row="${SSHWS_SESSION_ROWS[$real_idx]}"
  IFS='|' read -r username mode client_ip peer pid sess reason lock age state backend source started updated <<<"${row}"

  title
  echo "2) SSH Users > Session Detail"
  hr
  printf "%-16s : %s\n" "Username" "${username}"
  printf "%-16s : %s\n" "Mode" "${mode}"
  printf "%-16s : %s\n" "Client IP" "${client_ip}"
  printf "%-16s : %s\n" "State" "${state}"
  printf "%-16s : %s\n" "Source" "${source}"
  printf "%-16s : %s\n" "Backend" "${backend}"
  printf "%-16s : %s\n" "Peer" "${peer}"
  printf "%-16s : %s\n" "Dropbear PID" "${pid}"
  printf "%-16s : %s\n" "Started" "${started}"
  printf "%-16s : %s\n" "Updated" "${updated}"
  printf "%-16s : %s\n" "Age" "${age}"
  printf "%-16s : %s\n" "Active Sessions" "${sess}"
  printf "%-16s : %s\n" "Block Reason" "${reason}"
  printf "%-16s : %s\n" "Account Lock" "${lock}"

  local qf
  qf="$(ssh_user_state_file "${username}")"
  if [[ -f "${qf}" ]]; then
    local fields ql_disp qu_disp exp_date ip_state ip_lim block_reason speed_state speed_down speed_up lock_state
    fields="$(ssh_qac_read_detail_fields "${qf}")"
    IFS='|' read -r _ ql_disp qu_disp exp_date ip_state ip_lim block_reason speed_state speed_down speed_up lock_state <<<"${fields}"
    hr
    printf "%-16s : %s\n" "Quota" "${ql_disp}"
    printf "%-16s : %s\n" "Used" "${qu_disp}"
    printf "%-16s : %s\n" "Expired" "${exp_date}"
    printf "%-16s : %s (%s)\n" "IP/Login Limit" "${ip_state}" "${ip_lim}"
    printf "%-16s : %s DOWN / %s UP (%s)\n" "Speed Limit" "${speed_down}" "${speed_up}" "${speed_state}"
    printf "%-16s : %s\n" "Metadata File" "${qf}"
  fi
  hr
  pause
}

sshws_active_sessions_menu() {
  SSHWS_SESSION_PAGE=0
  SSHWS_SESSION_QUERY=""
  while true; do
    sshws_active_sessions_collect_rows
    sshws_active_sessions_apply_filter

    title
    echo "$(ssh_runtime_menu_title "Active Sessions")"
    hr
    sshws_active_sessions_print_page "${SSHWS_SESSION_PAGE}"
    hr
    echo "Ketik NO untuk detail, atau: search / clear / next / previous / refresh / 0"
    hr

    local c=""
    if ! read -r -p "Pilih: " c; then
      echo
      return 0
    fi
    if is_back_choice "${c}"; then
      return 0
    fi

    case "${c}" in
      next|n)
        local pages
        pages=$(( (${#SSHWS_SESSION_VIEW_INDEXES[@]} + SSHWS_SESSION_PAGE_SIZE - 1) / SSHWS_SESSION_PAGE_SIZE ))
        if (( pages > 0 && SSHWS_SESSION_PAGE < pages - 1 )); then
          SSHWS_SESSION_PAGE=$((SSHWS_SESSION_PAGE + 1))
        fi
        ;;
      previous|p|prev)
        if (( SSHWS_SESSION_PAGE > 0 )); then
          SSHWS_SESSION_PAGE=$((SSHWS_SESSION_PAGE - 1))
        fi
        ;;
      search)
        if ! read -r -p "Filter username/peer (atau kembali): " c; then
          echo
          return 0
        fi
        if is_back_choice "${c}"; then
          continue
        fi
        SSHWS_SESSION_QUERY="${c}"
        SSHWS_SESSION_PAGE=0
        ;;
      clear)
        SSHWS_SESSION_QUERY=""
        SSHWS_SESSION_PAGE=0
        ;;
      refresh|r)
        ;;
      *)
        if [[ "${c}" =~ ^[0-9]+$ ]]; then
          sshws_active_session_detail "${c}"
        else
          warn "Pilihan tidak valid"
          sleep 1
        fi
        ;;
    esac
  done
}

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
    "${SSH_NETWORK_WARP_INTERFACE}"
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
print(f"warp_interface={warp_interface}")
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
  local cfg nft_table mark route_table rule_pref warp_iface mark_hex=""
  local -a warp_uids=()
  local -a endpoint_v4=() endpoint_v6=()
  local username uid override effective
  local tmp=""

  cfg="$(ssh_network_config_get)"
  nft_table="$(printf '%s\n' "${cfg}" | awk -F'=' '/^nft_table=/{print $2; exit}')"
  mark="$(printf '%s\n' "${cfg}" | awk -F'=' '/^fwmark=/{print $2; exit}')"
  route_table="$(printf '%s\n' "${cfg}" | awk -F'=' '/^route_table=/{print $2; exit}')"
  rule_pref="$(printf '%s\n' "${cfg}" | awk -F'=' '/^rule_pref=/{print $2; exit}')"
  warp_iface="$(printf '%s\n' "${cfg}" | awk -F'=' '/^warp_interface=/{print $2; exit}')"
  if [[ "${mark}" =~ ^[0-9]+$ ]]; then
    printf -v mark_hex '0x%x' "${mark}"
  fi

  while IFS='|' read -r username uid override effective; do
    [[ -n "${username}" ]] || continue
    [[ "${uid}" =~ ^[0-9]+$ ]] || continue
    [[ "${effective}" == "warp" ]] || continue
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
  if ! ip link show "${warp_iface}" >/dev/null 2>&1; then
    if ! ssh_network_warp_runtime_start_unlocked "${warp_iface}"; then
      warn "Interface WARP SSH '${warp_iface}' tidak ditemukan dan provisioning otomatis gagal."
      return 1
    fi
    if ! ip link show "${warp_iface}" >/dev/null 2>&1; then
      warn "Interface WARP SSH '${warp_iface}' belum tersedia sesudah provisioning otomatis."
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
  local cfg global_mode nft_table mark route_table rule_pref warp_iface mark_hex=""
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
  warp_iface="$(printf '%s\n' "${cfg}" | awk -F'=' '/^warp_interface=/{print $2; exit}')"
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
  effective_warp_users="$(ssh_network_effective_rows | awk -F'|' '$4=="warp"{c++} END{print c+0}')"
  printf 'global_mode=%s\n' "${global_mode}"
  printf 'nft_table=%s\n' "${nft_table}"
  printf 'fwmark=%s\n' "${mark}"
  printf 'route_table=%s\n' "${route_table}"
  printf 'rule_pref=%s\n' "${rule_pref}"
  printf 'warp_interface=%s\n' "${warp_iface}"
  printf 'warp_interface_state=%s\n' "${iface_state}"
  printf 'warp_config_state=%s\n' "${warp_conf_state}"
  printf 'warp_service_state=%s\n' "${warp_service_state}"
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
    IFS=$'\n' users=($(printf '%s\n' "${users[@]}" | sort -u))
    unset IFS
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
    printf '14) SSH Network > %s\n' "${suffix}"
  else
    printf '14) SSH Network\n'
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
    local st global_mode warp_iface iface_state nft_state ip_rule_state ip_rule_v6_state
    local route_table_v4_state route_table_v6_state effective_warp_users
    st="$(ssh_network_runtime_status_get)"
    global_mode="$(printf '%s\n' "${st}" | awk -F'=' '/^global_mode=/{print $2; exit}')"
    warp_iface="$(printf '%s\n' "${st}" | awk -F'=' '/^warp_interface=/{print $2; exit}')"
    iface_state="$(printf '%s\n' "${st}" | awk -F'=' '/^warp_interface_state=/{print $2; exit}')"
    nft_state="$(printf '%s\n' "${st}" | awk -F'=' '/^nft_state=/{print $2; exit}')"
    ip_rule_state="$(printf '%s\n' "${st}" | awk -F'=' '/^ip_rule_state=/{print $2; exit}')"
    ip_rule_v6_state="$(printf '%s\n' "${st}" | awk -F'=' '/^ip_rule_v6_state=/{print $2; exit}')"
    route_table_v4_state="$(printf '%s\n' "${st}" | awk -F'=' '/^route_table_v4_state=/{print $2; exit}')"
    route_table_v6_state="$(printf '%s\n' "${st}" | awk -F'=' '/^route_table_v6_state=/{print $2; exit}')"
    effective_warp_users="$(printf '%s\n' "${st}" | awk -F'=' '/^effective_warp_users=/{print $2; exit}')"

    title
    echo "$(ssh_network_menu_title "Routing SSH Global")"
    hr
    printf "%-18s : %s\n" "Backend" "nftables mark + ip rule + route table"
    printf "%-18s : %s\n" "Global Mode" "${global_mode}"
    printf "%-18s : %s\n" "WARP Interface" "${warp_iface}"
    printf "%-18s : %s\n" "Interface State" "${iface_state}"
    printf "%-18s : %s\n" "NFT Runtime" "${nft_state}"
    printf "%-18s : %s\n" "IP Rule IPv4" "${ip_rule_state}"
    printf "%-18s : %s\n" "IP Rule IPv6" "${ip_rule_v6_state}"
    printf "%-18s : %s\n" "Route Table IPv4" "${route_table_v4_state}"
    printf "%-18s : %s\n" "Route Table IPv6" "${route_table_v6_state}"
    printf "%-18s : %s\n" "Effective Warp Users" "${effective_warp_users}"
    hr
    ssh_network_effective_rows_print
    hr
    echo "  1) Set Global Mode: Direct"
    echo "  2) Set Global Mode: WARP"
    echo "  3) Set WARP Interface"
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
        local new_iface=""
        if ! read -r -p "Nama interface WARP SSH (contoh warp-ssh0) (atau kembali): " new_iface; then
          echo
          return 0
        fi
        if is_back_choice "${new_iface}"; then
          continue
        fi
        if ! confirm_yn_or_back "Set interface WARP SSH ke ${new_iface} sekarang?"; then
          warn "Set interface WARP SSH dibatalkan."
        elif ssh_network_warp_interface_change_now "${new_iface}"; then
          log "Interface WARP SSH disimpan dan runtime direkonsiliasi: ${new_iface}"
        else
          warn "Interface WARP SSH gagal diganti."
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
    title
    echo "$(ssh_network_menu_title "Routing SSH Per-User")"
    hr
    printf "%-18s : %s\n" "Backend" "Per-user override di metadata SSH"
    printf "%-18s : %s\n" "Enforcement" "meta skuid -> fwmark -> ip rule"
    printf "%-18s : %s\n" "Target" "inherit / direct / warp"
    hr
    ssh_network_effective_rows_print
    hr
    echo "  1) Set User: Inherit"
    echo "  2) Set User: Direct"
    echo "  3) Set User: WARP"
    echo "  4) Apply Routing Runtime"
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
          1) target_mode="inherit" ;;
          2) target_mode="direct" ;;
          3) target_mode="warp" ;;
        esac
        if ! ssh_network_pick_routable_user target_user; then
          pause
          continue
        fi
        target_qf="$(ssh_user_state_resolve_file "${target_user}")"
        prev_mode="$(ssh_network_user_route_mode_get "${target_qf}")"
        if ! confirm_yn_or_back "Set routing SSH '${target_user}' ke ${target_mode} sekarang?"; then
          warn "Set routing user dibatalkan."
        elif ssh_network_user_route_mode_set "${target_user}" "${target_mode}" && ssh_network_runtime_apply_now; then
          log "Routing SSH '${target_user}' diubah ke ${target_mode}."
        else
          [[ -n "${prev_mode}" ]] && ssh_network_user_route_mode_set "${target_user}" "${prev_mode}" >/dev/null 2>&1 || true
          warn "Routing SSH '${target_user}' gagal diubah."
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

ssh_network_warp_global_menu() {
  while true; do
    local st global_mode warp_iface iface_state warp_conf_state warp_service_state
    local nft_state ip_rule_state ip_rule_v6_state route_table_v4_state route_table_v6_state effective_warp_users
    local wire_state="missing"
    st="$(ssh_network_runtime_status_get)"
    global_mode="$(printf '%s\n' "${st}" | awk -F'=' '/^global_mode=/{print $2; exit}')"
    warp_iface="$(printf '%s\n' "${st}" | awk -F'=' '/^warp_interface=/{print $2; exit}')"
    iface_state="$(printf '%s\n' "${st}" | awk -F'=' '/^warp_interface_state=/{print $2; exit}')"
    warp_conf_state="$(printf '%s\n' "${st}" | awk -F'=' '/^warp_config_state=/{print $2; exit}')"
    warp_service_state="$(printf '%s\n' "${st}" | awk -F'=' '/^warp_service_state=/{print $2; exit}')"
    nft_state="$(printf '%s\n' "${st}" | awk -F'=' '/^nft_state=/{print $2; exit}')"
    ip_rule_state="$(printf '%s\n' "${st}" | awk -F'=' '/^ip_rule_state=/{print $2; exit}')"
    ip_rule_v6_state="$(printf '%s\n' "${st}" | awk -F'=' '/^ip_rule_v6_state=/{print $2; exit}')"
    route_table_v4_state="$(printf '%s\n' "${st}" | awk -F'=' '/^route_table_v4_state=/{print $2; exit}')"
    route_table_v6_state="$(printf '%s\n' "${st}" | awk -F'=' '/^route_table_v6_state=/{print $2; exit}')"
    effective_warp_users="$(printf '%s\n' "${st}" | awk -F'=' '/^effective_warp_users=/{print $2; exit}')"
    if svc_exists wireproxy; then
      wire_state="$(svc_state wireproxy)"
    fi
    title
    echo "$(ssh_network_menu_title "WARP SSH Global")"
    hr
    printf "%-18s : %s\n" "Global WARP" "$([[ "${global_mode}" == "warp" ]] && echo "ON" || echo "OFF")"
    printf "%-18s : %s\n" "Backend" "Interface route + fwmark"
    printf "%-18s : %s\n" "Target Interface" "${warp_iface}"
    printf "%-18s : %s\n" "Interface State" "${iface_state}"
    printf "%-18s : %s\n" "Config State" "${warp_conf_state}"
    printf "%-18s : %s\n" "Service State" "${warp_service_state}"
    printf "%-18s : %s\n" "NFT Runtime" "${nft_state}"
    printf "%-18s : %s\n" "IP Rule IPv4" "${ip_rule_state}"
    printf "%-18s : %s\n" "IP Rule IPv6" "${ip_rule_v6_state}"
    printf "%-18s : %s\n" "Route Table IPv4" "${route_table_v4_state}"
    printf "%-18s : %s\n" "Route Table IPv6" "${route_table_v6_state}"
    printf "%-18s : %s\n" "Effective Warp Users" "${effective_warp_users}"
    printf "%-18s : %s\n" "Host WARP" "wireproxy=${wire_state}"
    hr
    echo "  1) Enable WARP Global"
    echo "  2) Disable WARP Global"
    echo "  3) Provision/Refresh Interface"
    echo "  4) Start WARP Interface"
    echo "  5) Stop WARP Interface"
    echo "  6) Set WARP Interface"
    echo "  7) Apply Runtime"
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
      3)
        if ssh_network_warp_sync_config_now "${warp_iface}"; then
          log "Config interface WARP SSH berhasil disegarkan."
        else
          warn "Config interface WARP SSH gagal disegarkan."
        fi
        pause
        ;;
      4)
        if ssh_network_warp_runtime_start_now "${warp_iface}"; then
          log "Interface WARP SSH berhasil diaktifkan."
        else
          warn "Interface WARP SSH gagal diaktifkan."
        fi
        pause
        ;;
      5)
        if ! confirm_yn_or_back "Matikan interface WARP SSH ${warp_iface} sekarang?"; then
          warn "Stop interface WARP SSH dibatalkan."
        elif ssh_network_warp_runtime_stop_now "${warp_iface}"; then
          log "Interface WARP SSH dihentikan."
        else
          warn "Interface WARP SSH gagal dihentikan."
        fi
        pause
        ;;
      6)
        local new_iface=""
        if ! read -r -p "Nama interface WARP SSH (atau kembali): " new_iface; then
          echo
          return 0
        fi
        if is_back_choice "${new_iface}"; then
          continue
        fi
        if ! confirm_yn_or_back "Set interface WARP SSH ke ${new_iface} sekarang?"; then
          warn "Set interface WARP SSH dibatalkan."
        elif ssh_network_warp_interface_change_now "${new_iface}"; then
          log "Interface WARP SSH disimpan dan runtime direkonsiliasi: ${new_iface}"
        else
          warn "Interface WARP SSH gagal diganti."
        fi
        pause
        ;;
      7)
        if ssh_network_runtime_apply_now; then
          log "Runtime WARP SSH berhasil disinkronkan."
        else
          warn "Runtime WARP SSH gagal disinkronkan."
        fi
        pause
        ;;
      0|kembali|k|back|b) return 0 ;;
      *) invalid_choice ;;
    esac
  done
}

ssh_network_warp_user_menu() {
  while true; do
    title
    echo "$(ssh_network_menu_title "WARP SSH Per-User")"
    hr
    printf "%-18s : %s\n" "Backend" "Per-user WARP override"
    printf "%-18s : %s\n" "State" "network.route_mode"
    printf "%-18s : %s\n" "Apply Path" "nft mark + ip rule"
    hr
    ssh_network_effective_rows_print
    hr
    echo "  1) Enable WARP for User"
    echo "  2) Disable WARP for User"
    echo "  3) Reset User to Inherit"
    echo "  4) Apply Runtime"
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
          1) target_mode="warp" ;;
          2) target_mode="direct" ;;
          3) target_mode="inherit" ;;
        esac
        if ! ssh_network_pick_routable_user target_user; then
          pause
          continue
        fi
        target_qf="$(ssh_user_state_resolve_file "${target_user}")"
        prev_mode="$(ssh_network_user_route_mode_get "${target_qf}")"
        if ! confirm_yn_or_back "Set mode WARP SSH '${target_user}' ke ${target_mode} sekarang?"; then
          warn "Set mode WARP user dibatalkan."
        elif ssh_network_user_route_mode_set "${target_user}" "${target_mode}" && ssh_network_runtime_apply_now; then
          log "Mode WARP SSH '${target_user}' diubah ke ${target_mode}."
        else
          [[ -n "${prev_mode}" ]] && ssh_network_user_route_mode_set "${target_user}" "${prev_mode}" >/dev/null 2>&1 || true
          warn "Mode WARP SSH '${target_user}' gagal diubah."
        fi
        pause
        ;;
      4)
        if ssh_network_runtime_apply_now; then
          log "Runtime WARP SSH berhasil disinkronkan."
        else
          warn "Runtime WARP SSH gagal disinkronkan."
        fi
        pause
        ;;
      0|kembali|k|back|b) return 0 ;;
      *) invalid_choice ;;
    esac
  done
}

ssh_network_menu() {
  local -a items=(
    "1|DNS for SSH"
    "2|Routing SSH Global"
    "3|Routing SSH Per-User"
    "4|WARP SSH Global"
    "5|WARP SSH Per-User"
    "0|Back"
  )
  while true; do
    ui_menu_screen_begin "14) SSH Network"
    ui_menu_render_options items 76
    hr
    if ! read -r -p "Pilih: " c; then
      echo
      return 0
    fi
    case "${c}" in
      1) menu_run_isolated_report "DNS for SSH" ssh_network_dns_menu ;;
      2) menu_run_isolated_report "Routing SSH Global" ssh_network_route_global_menu ;;
      3) menu_run_isolated_report "Routing SSH Per-User" ssh_network_route_user_menu ;;
      4) menu_run_isolated_report "WARP SSH Global" ssh_network_warp_global_menu ;;
      5) menu_run_isolated_report "WARP SSH Per-User" ssh_network_warp_user_menu ;;
      0|kembali|k|back|b) return 0 ;;
      *) invalid_choice ;;
    esac
  done
}

ssh_menu() {
  local pending_count=0
  local -a items=(
    "1|Add User"
    "2|Delete User"
    "3|Set Expiry"
    "4|Reset Password"
    "5|List Users"
    "6|SSH WS Status"
    "7|Restart SSH WS"
    "8|Active Sessions"
    "9|Recover Pending Txn"
    "0|Back"
  )
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
# SSH QAC
# -------------------------
SSH_QAC_FILES=()
SSH_QAC_PAGE_SIZE=10
SSH_QAC_PAGE=0
SSH_QAC_QUERY=""
SSH_QAC_VIEW_INDEXES=()
SSH_QAC_ENFORCER_BIN="/usr/local/bin/sshws-qac-enforcer"
SSHWS_SESSION_ROWS=()
SSHWS_SESSION_VIEW_INDEXES=()
SSHWS_SESSION_PAGE_SIZE=10
SSHWS_SESSION_PAGE=0
SSHWS_SESSION_QUERY=""
SSHWS_SESSION_DISTINCT_IPS=0
SSHWS_SESSION_MODE_SUMMARY="-"
SSHWS_RUNTIME_SESSION_DIR="/run/autoscript/sshws-sessions"
SSHWS_RUNTIME_ENV_FILE="/etc/default/sshws-runtime"

sshws_runtime_session_stale_sec() {
  local value="90"
  if [[ -r "${SSHWS_RUNTIME_ENV_FILE}" ]]; then
    value="$(awk -F= '/^[[:space:]]*SSHWS_RUNTIME_SESSION_STALE_SEC=/{print $2; exit}' "${SSHWS_RUNTIME_ENV_FILE}" | tr -d '[:space:]')"
  fi
  [[ "${value}" =~ ^[0-9]+$ ]] || value="90"
  if (( value < 15 )); then
    value="90"
  fi
  printf '%s\n' "${value}"
}

ssh_active_sessions_count() {
  local username="${1:-}"
  local stale_sec
  [[ -n "${username}" ]] || {
    echo "0"
    return 0
  }
  if ! id "${username}" >/dev/null 2>&1; then
    echo "0"
    return 0
  fi

  local runtime_count="0"
  if [[ -d "${SSHWS_RUNTIME_SESSION_DIR}" ]]; then
    stale_sec="$(sshws_runtime_session_stale_sec)"
    runtime_count="$(python3 - "${SSHWS_RUNTIME_SESSION_DIR}" "${username}" "${stale_sec}" <<'PY' 2>/dev/null || true
import json, pathlib, sys, time
import os
root = pathlib.Path(sys.argv[1])
target = str(sys.argv[2] or "").strip()
stale_sec = int(float(sys.argv[3] or 90))
count = 0

def pid_alive(pid):
  try:
    value = int(pid)
  except Exception:
    return False
  if value <= 0:
    return False
  try:
    os.kill(value, 0)
    return True
  except ProcessLookupError:
    return False
  except PermissionError:
    return True
  except Exception:
    return False

if root.is_dir() and target:
  for path in root.glob("*.json"):
    try:
      payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
      continue
    if not isinstance(payload, dict):
      continue
    if not pid_alive(payload.get("proxy_pid")):
      continue
    try:
      updated_at = int(float(payload.get("updated_at") or 0))
    except Exception:
      continue
    now = int(time.time())
    if updated_at <= 0 or now <= 0 or (now - updated_at) > stale_sec:
      continue
    username = str(payload.get("username") or "").strip()
    if username.endswith("@ssh"):
      username = username[:-4]
    if "@" in username:
      username = username.split("@", 1)[0]
    if username == target:
      count += 1
print(count)
PY
)"
  fi
  runtime_count="${runtime_count:-0}"
  [[ "${runtime_count}" =~ ^[0-9]+$ ]] || runtime_count="0"

  local c="0"
  c="$(python3 - "${username}" <<'PY' 2>/dev/null || true
import re
import subprocess
import sys

target = str(sys.argv[1] or "").strip().lower()
if not target:
    print(0)
    raise SystemExit(0)

try:
    res = subprocess.run(
        ["ps", "-eo", "pid=,ppid=,user=,comm=,args="],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        check=False,
    )
except FileNotFoundError:
    print(0)
    raise SystemExit(0)

rows = []
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
    except Exception:
        continue
    rows.append({"pid": pid, "ppid": ppid, "comm": parts[3], "args": parts[4]})

master_pids = set()
for row in rows:
    if row["comm"] == "dropbear" and "-p 127.0.0.1:22022" in row["args"]:
        master_pids.add(row["pid"])

session_pids = []
for row in rows:
    if row["comm"] == "dropbear" and row["ppid"] in master_pids:
        session_pids.append(row["pid"])

pat = re.compile(r"dropbear\[(\d+)\]: .*auth succeeded for '([^']+)'", re.IGNORECASE)
mapping = {}
try:
    res = subprocess.run(
        ["journalctl", "-u", "sshws-dropbear", "--no-pager", "-n", "2000"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        check=False,
    )
    for line in (res.stdout or "").splitlines():
        m = pat.search(line)
        if not m:
            continue
        try:
            pid = int(m.group(1))
        except Exception:
            continue
        mapping[pid] = str(m.group(2) or "").strip().lower()
except FileNotFoundError:
    pass

if not mapping:
    try:
        res = subprocess.run(
            ["tail", "-n", "5000", "/var/log/auth.log"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            check=False,
        )
        for line in (res.stdout or "").splitlines():
            m = pat.search(line)
            if not m:
                continue
            try:
                pid = int(m.group(1))
            except Exception:
                continue
            mapping[pid] = str(m.group(2) or "").strip().lower()
    except FileNotFoundError:
        pass

count = 0
for pid in session_pids:
    if mapping.get(pid) == target:
        count += 1
print(count)
PY
)"
  c="${c:-0}"
  [[ "${c}" =~ ^[0-9]+$ ]] || c="0"
  if (( runtime_count > c )); then
    echo "${runtime_count}"
  else
    echo "${c}"
  fi
}

ssh_qac_setup_file_trusted() {
  local file="${1:-}"
  [[ -n "${file}" && -f "${file}" && -r "${file}" ]] || return 1

  local real owner mode
  real="$(readlink -f -- "${file}" 2>/dev/null || true)"
  [[ -n "${real}" && -f "${real}" && -r "${real}" ]] || return 1

  # Saat root: source restore harus root-owned, non-symlink, dan tidak writable group/other.
  if [[ "$(id -u)" -eq 0 ]]; then
    [[ -L "${file}" || -L "${real}" ]] && return 1
    owner="$(stat -c '%u' "${real}" 2>/dev/null || echo 1)"
    mode="$(stat -c '%A' "${real}" 2>/dev/null || echo '----------')"
    [[ "${owner}" == "0" ]] || return 1
    [[ "${mode:5:1}" != "w" && "${mode:8:1}" != "w" ]] || return 1
  fi

  printf '%s\n' "${real}"
  return 0
}

ssh_qac_detect_setup_script() {
  local candidates=()
  local src_dir="" repo_root=""
  src_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P 2>/dev/null || true)"
  if [[ -n "${src_dir}" ]]; then
    repo_root="$(cd "${src_dir}/../../.." && pwd -P 2>/dev/null || true)"
    [[ -n "${repo_root}" ]] && candidates+=("${repo_root}/setup.sh")
  fi
  [[ -n "${AUTOSCRIPT_SETUP_SH:-}" ]] && candidates+=("${AUTOSCRIPT_SETUP_SH}")
  candidates+=(
    "/root/project/autoscript/setup.sh"
    "/root/autoscript/setup.sh"
    "/opt/autoscript/setup.sh"
  )

  local f trusted_real
  for f in "${candidates[@]}"; do
    trusted_real="$(ssh_qac_setup_file_trusted "${f}" || true)"
    [[ -n "${trusted_real}" ]] || continue
    echo "${trusted_real}"
    return 0
  done
  return 1
}

ssh_qac_install_enforcer_from_setup() {
  [[ -x "${SSH_QAC_ENFORCER_BIN}" ]] && return 0
  local setup_file=""
  local tmp=""
  setup_file="$(ssh_qac_detect_setup_script || true)"
  [[ -n "${setup_file}" ]] || return 1
  command -v awk >/dev/null 2>&1 || return 1

  tmp="$(mktemp)"
  if ! awk '
    index($0, "cat > /usr/local/bin/sshws-qac-enforcer <<'\''PY'\''") { capture=1; next }
    capture && $0 == "PY" { exit }
    capture { print }
  ' "${setup_file}" > "${tmp}"; then
    rm -f "${tmp}" >/dev/null 2>&1 || true
    return 1
  fi
  if [[ ! -s "${tmp}" ]]; then
    rm -f "${tmp}" >/dev/null 2>&1 || true
    return 1
  fi
  if ! head -n1 "${tmp}" | grep -q '^#!/usr/bin/env python3$'; then
    rm -f "${tmp}" >/dev/null 2>&1 || true
    return 1
  fi

  install -d -m 755 "$(dirname "${SSH_QAC_ENFORCER_BIN}")"
  install -m 755 "${tmp}" "${SSH_QAC_ENFORCER_BIN}"
  rm -f "${tmp}" >/dev/null 2>&1 || true
  [[ -x "${SSH_QAC_ENFORCER_BIN}" ]]
}

ssh_qac_enforce_now() {
  local target_user="${1:-}"
  if [[ ! -x "${SSH_QAC_ENFORCER_BIN}" ]]; then
    ssh_qac_install_enforcer_from_setup >/dev/null 2>&1 || true
  fi
  if [[ -x "${SSH_QAC_ENFORCER_BIN}" ]]; then
    if [[ -n "${target_user}" ]]; then
      "${SSH_QAC_ENFORCER_BIN}" --once --user "${target_user}" >/dev/null 2>&1
    else
      "${SSH_QAC_ENFORCER_BIN}" --once >/dev/null 2>&1
    fi
    return $?
  fi
  return 1
}

ssh_qac_enforce_now_warn() {
  local target_user="${1:-}"
  if ! ssh_qac_enforce_now "${target_user}"; then
    if [[ -n "${target_user}" ]]; then
      warn "Enforcer SSH QAC gagal untuk '${target_user}'. Pastikan '${SSH_QAC_ENFORCER_BIN}' tersedia (bisa di-restore dari setup.sh)."
    else
      warn "Enforcer SSH QAC gagal dijalankan. Pastikan '${SSH_QAC_ENFORCER_BIN}' tersedia (bisa di-restore dari setup.sh)."
    fi
    return 1
  fi
  return 0
}

ssh_qac_collect_files() {
  SSH_QAC_FILES=()
  ssh_state_dirs_prepare
  local username qf
  while IFS= read -r username; do
    [[ -n "${username}" ]] || continue
    qf="$(ssh_user_state_resolve_file "${username}")"
    SSH_QAC_FILES+=("${qf}")
  done < <(ssh_collect_candidate_users false)
}

ssh_qac_total_pages_for_indexes() {
  local total="${#SSH_QAC_VIEW_INDEXES[@]}"
  if (( total == 0 )); then
    echo 0
    return 0
  fi
  echo $(( (total + SSH_QAC_PAGE_SIZE - 1) / SSH_QAC_PAGE_SIZE ))
}

ssh_qac_build_view_indexes() {
  SSH_QAC_VIEW_INDEXES=()

  local q
  q="$(echo "${SSH_QAC_QUERY:-}" | tr '[:upper:]' '[:lower:]')"
  if [[ -z "${q}" ]]; then
    local i
    for i in "${!SSH_QAC_FILES[@]}"; do
      SSH_QAC_VIEW_INDEXES+=("${i}")
    done
    return 0
  fi

  local i f base
  for i in "${!SSH_QAC_FILES[@]}"; do
    f="${SSH_QAC_FILES[$i]}"
    base="$(basename "${f}")"
    base="${base%.json}"
    base="$(ssh_username_from_key "${base}")"
    if echo "${base}" | tr '[:upper:]' '[:lower:]' | grep -qF -- "${q}"; then
      SSH_QAC_VIEW_INDEXES+=("${i}")
    fi
  done
}

ssh_qac_read_summary_fields() {
  # args: json_file
  # prints: username|quota_limit_disp|quota_used_disp|expired_at_date|ip_limit_disp|block_reason|lock_state
  local qf="$1"
  need_python3
  python3 - <<'PY' "${qf}"
import json
import pathlib
import sys

p = pathlib.Path(sys.argv[1])
def norm_user(v):
  s = str(v or "").strip()
  if s.endswith("@ssh"):
    s = s[:-4]
  if "@" in s:
    s = s.split("@", 1)[0]
  return s

username_fallback = norm_user(p.stem) or p.stem

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

def to_bool(v):
  if isinstance(v, bool):
    return v
  if isinstance(v, (int, float)):
    return bool(v)
  s = str(v or "").strip().lower()
  return s in ("1", "true", "yes", "on", "y")

def fmt_gb(v):
  try:
    n = float(v)
  except Exception:
    n = 0.0
  if n < 0:
    n = 0.0
  s = f"{n:.3f}".rstrip("0").rstrip(".")
  return s if s else "0"

def used_disp(b):
  try:
    b = int(b)
  except Exception:
    b = 0
  if b >= 1024**3:
    return f"{b/(1024**3):.2f} GB"
  if b >= 1024**2:
    return f"{b/(1024**2):.2f} MB"
  if b >= 1024:
    return f"{b/1024:.2f} KB"
  return f"{b} B"

data = {}
try:
  loaded = json.loads(p.read_text(encoding="utf-8"))
  if isinstance(loaded, dict):
    data = loaded
except Exception:
  data = {}

username = norm_user(data.get("username") or username_fallback) or username_fallback
quota_limit = to_int(data.get("quota_limit"), 0)
quota_used = to_int(data.get("quota_used"), 0)
unit = str(data.get("quota_unit") or "binary").strip().lower()
bpg = 1000**3 if unit in ("decimal", "gb", "1000", "gigabyte") else 1024**3
quota_limit_disp = f"{fmt_gb(quota_limit / bpg)} GB"
quota_used_disp = used_disp(quota_used)
expired_at = str(data.get("expired_at") or "-").strip()
expired_date = expired_at[:10] if expired_at and expired_at != "-" else "-"

status_raw = data.get("status")
status = status_raw if isinstance(status_raw, dict) else {}
ip_enabled = to_bool(status.get("ip_limit_enabled"))
ip_limit = to_int(status.get("ip_limit"), 0)
if ip_limit < 0:
  ip_limit = 0
ip_disp = "ON({})".format(ip_limit) if ip_enabled and ip_limit > 0 else ("ON" if ip_enabled else "OFF")

reason = str(status.get("lock_reason") or "").strip().lower()
if to_bool(status.get("manual_block")):
  reason = "manual"
elif to_bool(status.get("quota_exhausted")):
  reason = "quota"
elif to_bool(status.get("ip_limit_locked")):
  reason = "ip_limit"
reason_disp = reason.upper() if reason else "-"

lock_disp = "ON" if to_bool(status.get("account_locked")) else "OFF"

print(f"{username}|{quota_limit_disp}|{quota_used_disp}|{expired_date}|{ip_disp}|{reason_disp}|{lock_disp}")
PY
}

ssh_qac_read_detail_fields() {
  # args: json_file
  # prints: username|quota_limit_disp|quota_used_disp|expired_at_date|ip_limit_onoff|ip_limit_value|block_reason|speed_onoff|speed_down_mbit|speed_up_mbit|lock_state|distinct_ip_count|ip_limit_metric|distinct_ips|active_sessions_total|active_sessions_runtime|active_sessions_dropbear
  local qf="$1"
  need_python3
  python3 - <<'PY' "${qf}"
import json
import pathlib
import sys

p = pathlib.Path(sys.argv[1])
def norm_user(v):
  s = str(v or "").strip()
  if s.endswith("@ssh"):
    s = s[:-4]
  if "@" in s:
    s = s.split("@", 1)[0]
  return s

username_fallback = norm_user(p.stem) or p.stem

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

def to_bool(v):
  if isinstance(v, bool):
    return v
  if isinstance(v, (int, float)):
    return bool(v)
  s = str(v or "").strip().lower()
  return s in ("1", "true", "yes", "on", "y")

def ips_to_text(v):
  if not isinstance(v, list):
    return "-"
  out = []
  for item in v:
    text = str(item or "").strip()
    if text:
      out.append(text)
  return ", ".join(out) if out else "-"

def fmt_gb(v):
  try:
    n = float(v)
  except Exception:
    n = 0.0
  if n < 0:
    n = 0.0
  s = f"{n:.3f}".rstrip("0").rstrip(".")
  return s if s else "0"

def fmt_mbit(v):
  try:
    n = float(v)
  except Exception:
    n = 0.0
  if n < 0:
    n = 0.0
  s = f"{n:.3f}".rstrip("0").rstrip(".")
  return s if s else "0"

def used_disp(b):
  try:
    b = int(b)
  except Exception:
    b = 0
  if b >= 1024**3:
    return f"{b/(1024**3):.2f} GB"
  if b >= 1024**2:
    return f"{b/(1024**2):.2f} MB"
  if b >= 1024:
    return f"{b/1024:.2f} KB"
  return f"{b} B"

data = {}
try:
  loaded = json.loads(p.read_text(encoding="utf-8"))
  if isinstance(loaded, dict):
    data = loaded
except Exception:
  data = {}

username = norm_user(data.get("username") or username_fallback) or username_fallback
quota_limit = to_int(data.get("quota_limit"), 0)
quota_used = to_int(data.get("quota_used"), 0)
unit = str(data.get("quota_unit") or "binary").strip().lower()
bpg = 1000**3 if unit in ("decimal", "gb", "1000", "gigabyte") else 1024**3
quota_limit_disp = f"{fmt_gb(quota_limit / bpg)} GB"
quota_used_disp = used_disp(quota_used)
expired_at = str(data.get("expired_at") or "-").strip()
expired_date = expired_at[:10] if expired_at and expired_at != "-" else "-"

status_raw = data.get("status")
status = status_raw if isinstance(status_raw, dict) else {}

ip_enabled = to_bool(status.get("ip_limit_enabled"))
ip_limit = to_int(status.get("ip_limit"), 0)
if ip_limit < 0:
  ip_limit = 0
if not ip_enabled:
  ip_limit = 0

reason = str(status.get("lock_reason") or "").strip().lower()
if to_bool(status.get("manual_block")):
  reason = "manual"
elif to_bool(status.get("quota_exhausted")):
  reason = "quota"
elif to_bool(status.get("ip_limit_locked")):
  reason = "ip_limit"
reason_disp = reason.upper() if reason else "-"

speed_enabled = to_bool(status.get("speed_limit_enabled"))
speed_down = to_float(status.get("speed_down_mbit"), 0.0)
speed_up = to_float(status.get("speed_up_mbit"), 0.0)
if speed_down < 0:
  speed_down = 0.0
if speed_up < 0:
  speed_up = 0.0

distinct_ip_count = to_int(status.get("distinct_ip_count"), 0)
if distinct_ip_count < 0:
  distinct_ip_count = 0
ip_limit_metric = to_int(status.get("ip_limit_metric"), 0)
if ip_limit_metric < 0:
  ip_limit_metric = 0
active_sessions_total = to_int(status.get("active_sessions_total"), 0)
if active_sessions_total < 0:
  active_sessions_total = 0
active_sessions_runtime = to_int(status.get("active_sessions_runtime"), 0)
if active_sessions_runtime < 0:
  active_sessions_runtime = 0
active_sessions_dropbear = to_int(status.get("active_sessions_dropbear"), 0)
if active_sessions_dropbear < 0:
  active_sessions_dropbear = 0
distinct_ips = ips_to_text(status.get("distinct_ips"))

lock_disp = "ON" if to_bool(status.get("account_locked")) else "OFF"
print(
  f"{username}|{quota_limit_disp}|{quota_used_disp}|{expired_date}|"
  f"{'ON' if ip_enabled else 'OFF'}|{ip_limit}|{reason_disp}|"
  f"{'ON' if speed_enabled else 'OFF'}|{fmt_mbit(speed_down)}|{fmt_mbit(speed_up)}|{lock_disp}|"
  f"{distinct_ip_count}|{ip_limit_metric}|{distinct_ips}|{active_sessions_total}|{active_sessions_runtime}|{active_sessions_dropbear}"
)
PY
}

ssh_qac_get_status_bool() {
  # args: json_file key
  local qf="$1"
  local key="$2"
  need_python3
  python3 - <<'PY' "${qf}" "${key}"
import json
import sys

qf, key = sys.argv[1:3]
try:
  data = json.load(open(qf, "r", encoding="utf-8"))
except Exception:
  print("false")
  raise SystemExit(0)

if not isinstance(data, dict):
  print("false")
  raise SystemExit(0)

status = data.get("status")
if not isinstance(status, dict):
  status = {}

val = status.get(key)
if isinstance(val, bool):
  print("true" if val else "false")
elif isinstance(val, (int, float)):
  print("true" if bool(val) else "false")
else:
  s = str(val or "").strip().lower()
  print("true" if s in ("1", "true", "yes", "on", "y") else "false")
PY
}

ssh_qac_get_status_number() {
  # args: json_file key
  local qf="$1"
  local key="$2"
  need_python3
  python3 - <<'PY' "${qf}" "${key}"
import json
import sys

qf, key = sys.argv[1:3]
try:
  data = json.load(open(qf, "r", encoding="utf-8"))
except Exception:
  print("0")
  raise SystemExit(0)

if not isinstance(data, dict):
  print("0")
  raise SystemExit(0)

status = data.get("status")
if not isinstance(status, dict):
  status = {}

val = status.get(key)
try:
  if val is None:
    print("0")
  elif isinstance(val, bool):
    print(str(int(val)))
  elif isinstance(val, (int, float)):
    print(str(val))
  else:
    sval = str(val).strip()
    print(sval if sval else "0")
except Exception:
  print("0")
PY
}

ssh_qac_atomic_update_file_unlocked() {
  # args: json_file action [args...]
  local qf="$1"
  local action="$2"
  local lock_file
  shift 2 || true

  ssh_state_dirs_prepare
  ssh_qac_lock_prepare
  lock_file="$(ssh_qac_lock_file)"
  need_python3
  python3 - <<'PY' "${qf}" "${action}" "${lock_file}" "$@"
import atexit
import fcntl
import json
import os
import pathlib
import re
import secrets
import sys
import tempfile
import shutil

qf = sys.argv[1]
action = sys.argv[2]
lock_file = pathlib.Path(sys.argv[3] or "/run/autoscript/locks/sshws-qac.lock")
args = sys.argv[4:]
backup_file = str(os.environ.get("SSH_QAC_ATOMIC_BACKUP_FILE") or "").strip()

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

def to_bool(v):
  if isinstance(v, bool):
    return v
  if isinstance(v, (int, float)):
    return bool(v)
  s = str(v or "").strip().lower()
  return s in ("1", "true", "yes", "on", "y")

def norm_user(v):
  s = str(v or "").strip()
  if s.endswith("@ssh"):
    s = s[:-4]
  if "@" in s:
    s = s.split("@", 1)[0]
  return s

def parse_onoff(v):
  s = str(v or "").strip().lower()
  if s in ("on", "1", "true", "yes", "y"):
    return True
  if s in ("off", "0", "false", "no", "n"):
    return False
  raise SystemExit("nilai on/off tidak valid")

def parse_int(v, key, minv=None):
  try:
    n = int(float(str(v).strip()))
  except Exception:
    raise SystemExit(f"{key} harus angka")
  if minv is not None and n < minv:
    raise SystemExit(f"{key} minimal {minv}")
  return n

def parse_float(v, key, minv=None):
  try:
    n = float(str(v).strip())
  except Exception:
    raise SystemExit(f"{key} harus angka")
  if minv is not None and n < minv:
    raise SystemExit(f"{key} minimal {minv}")
  return n

def pick_unique_token(root_dir, current_path, current_token):
  seen = set()
  current_real = os.path.realpath(current_path)
  try:
    names = sorted(os.listdir(root_dir), key=str.lower)
  except Exception:
    names = []
  for name in names:
    if name.startswith(".") or not name.endswith(".json"):
      continue
    entry = os.path.join(root_dir, name)
    if os.path.realpath(entry) == current_real:
      continue
    try:
      loaded = json.load(open(entry, "r", encoding="utf-8"))
      if not isinstance(loaded, dict):
        continue
    except Exception:
      continue
    tok = str(loaded.get("sshws_token") or "").strip().lower()
    if re.fullmatch(r"[a-f0-9]{10}", tok):
      seen.add(tok)
  tok = str(current_token or "").strip().lower()
  if re.fullmatch(r"[a-f0-9]{10}", tok) and tok not in seen:
    return tok
  for _ in range(256):
    tok = secrets.token_hex(5)
    if tok not in seen:
      return tok
  raise SystemExit("failed to allocate unique sshws token")

lock_handle = None

def release_lock():
  global lock_handle
  if lock_handle is None:
    return
  try:
    fcntl.flock(lock_handle.fileno(), fcntl.LOCK_UN)
  except Exception:
    pass
  try:
    lock_handle.close()
  except Exception:
    pass
  lock_handle = None

try:
  lock_file.parent.mkdir(parents=True, exist_ok=True)
except Exception:
  pass

lock_handle = open(lock_file, "a+", encoding="utf-8")
fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX)
atexit.register(release_lock)

payload = {}
if os.path.isfile(qf):
  if backup_file:
    backup_path = pathlib.Path(backup_file)
    backup_path.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(qf, backup_path)
    try:
      os.chmod(backup_path, 0o600)
    except Exception:
      pass
  try:
    loaded = json.load(open(qf, "r", encoding="utf-8"))
    if isinstance(loaded, dict):
      payload = loaded
  except Exception:
    payload = {}

username_fallback = os.path.basename(qf)
if username_fallback.endswith(".json"):
  username_fallback = username_fallback[:-5]
username_fallback = norm_user(username_fallback) or username_fallback

status_raw = payload.get("status")
status = status_raw if isinstance(status_raw, dict) else {}

quota_limit = to_int(payload.get("quota_limit"), 0)
if quota_limit < 0:
  quota_limit = 0
quota_used = to_int(payload.get("quota_used"), 0)
if quota_used < 0:
  quota_used = 0

speed_down = to_float(status.get("speed_down_mbit"), 0.0)
speed_up = to_float(status.get("speed_up_mbit"), 0.0)
if speed_down < 0:
  speed_down = 0.0
if speed_up < 0:
  speed_up = 0.0

ip_limit = to_int(status.get("ip_limit"), 0)
if ip_limit < 0:
  ip_limit = 0

unit = str(payload.get("quota_unit") or "binary").strip().lower()
if unit not in ("binary", "decimal"):
  unit = "binary"
token = pick_unique_token(os.path.dirname(qf) or ".", qf, payload.get("sshws_token"))

payload["managed_by"] = "autoscript-manage"
payload["protocol"] = "ssh"
payload["username"] = norm_user(payload.get("username") or username_fallback) or username_fallback
payload["created_at"] = str(payload.get("created_at") or "-").strip() or "-"
payload["expired_at"] = str(payload.get("expired_at") or "-").strip()[:10] or "-"
payload["sshws_token"] = token
payload["quota_limit"] = quota_limit
payload["quota_unit"] = unit
payload["quota_used"] = quota_used
payload["bootstrap_review_needed"] = to_bool(payload.get("bootstrap_review_needed"))
payload["bootstrap_source"] = str(payload.get("bootstrap_source") or "").strip()
payload["status"] = {
  "manual_block": to_bool(status.get("manual_block")),
  "quota_exhausted": to_bool(status.get("quota_exhausted")),
  "ip_limit_enabled": to_bool(status.get("ip_limit_enabled")),
  "ip_limit": ip_limit,
  "ip_limit_locked": to_bool(status.get("ip_limit_locked")),
  "speed_limit_enabled": to_bool(status.get("speed_limit_enabled")),
  "speed_down_mbit": speed_down,
  "speed_up_mbit": speed_up,
  "lock_reason": str(status.get("lock_reason") or "").strip().lower(),
  "account_locked": to_bool(status.get("account_locked")),
  "lock_owner": str(status.get("lock_owner") or "").strip(),
  "lock_shell_restore": str(status.get("lock_shell_restore") or "").strip(),
}
network_raw = payload.get("network")
network = network_raw if isinstance(network_raw, dict) else {}
route_mode = str(network.get("route_mode") or "inherit").strip().lower()
if route_mode not in ("inherit", "direct", "warp"):
  route_mode = "inherit"
payload["network"] = {
  "route_mode": route_mode,
}

st = payload["status"]
net = payload["network"]

if action == "bootstrap_marker_set":
  if len(args) != 1:
    raise SystemExit("bootstrap_marker_set butuh 1 argumen (source)")
  payload["bootstrap_review_needed"] = True
  payload["bootstrap_source"] = str(args[0] or "").strip()
elif action == "set_quota_limit":
  if len(args) != 1:
    raise SystemExit("set_quota_limit butuh 1 argumen (bytes)")
  payload["quota_limit"] = parse_int(args[0], "quota_limit", 0)
elif action == "reset_quota_used":
  payload["quota_used"] = 0
  st["quota_exhausted"] = False
elif action == "manual_block_set":
  if len(args) != 1:
    raise SystemExit("manual_block_set butuh 1 argumen (on/off)")
  st["manual_block"] = bool(parse_onoff(args[0]))
elif action == "ip_limit_enabled_set":
  if len(args) != 1:
    raise SystemExit("ip_limit_enabled_set butuh 1 argumen (on/off)")
  enabled = bool(parse_onoff(args[0]))
  st["ip_limit_enabled"] = enabled
  if not enabled:
    st["ip_limit_locked"] = False
elif action == "set_ip_limit":
  if len(args) != 1:
    raise SystemExit("set_ip_limit butuh 1 argumen (angka)")
  st["ip_limit"] = parse_int(args[0], "ip_limit", 1)
elif action == "clear_ip_limit_locked":
  st["ip_limit_locked"] = False
elif action == "set_speed_down":
  if len(args) != 1:
    raise SystemExit("set_speed_down butuh 1 argumen (Mbps)")
  st["speed_down_mbit"] = parse_float(args[0], "speed_down_mbit", 0.000001)
elif action == "set_speed_up":
  if len(args) != 1:
    raise SystemExit("set_speed_up butuh 1 argumen (Mbps)")
  st["speed_up_mbit"] = parse_float(args[0], "speed_up_mbit", 0.000001)
elif action == "speed_limit_set":
  if len(args) != 1:
    raise SystemExit("speed_limit_set butuh 1 argumen (on/off)")
  st["speed_limit_enabled"] = bool(parse_onoff(args[0]))
elif action == "set_speed_all_enable":
  if len(args) != 2:
    raise SystemExit("set_speed_all_enable butuh 2 argumen (down up)")
  st["speed_down_mbit"] = parse_float(args[0], "speed_down_mbit", 0.000001)
  st["speed_up_mbit"] = parse_float(args[1], "speed_up_mbit", 0.000001)
  st["speed_limit_enabled"] = True
elif action == "network_route_mode_set":
  if len(args) != 1:
    raise SystemExit("network_route_mode_set butuh 1 argumen (inherit/direct/warp)")
  mode = str(args[0] or "").strip().lower()
  if mode not in ("inherit", "direct", "warp"):
    raise SystemExit("network route mode harus inherit/direct/warp")
  net["route_mode"] = mode
else:
  raise SystemExit(f"aksi ssh_qac_atomic_update_file tidak dikenali: {action}")

if action != "bootstrap_marker_set":
  payload["bootstrap_review_needed"] = False
  payload["bootstrap_source"] = ""

payload["status"] = st
payload["network"] = net
text = json.dumps(payload, ensure_ascii=False, indent=2) + "\n"
dirn = os.path.dirname(qf) or "."
fd, tmp = tempfile.mkstemp(prefix=".tmp.", suffix=".json", dir=dirn)
try:
  with os.fdopen(fd, "w", encoding="utf-8") as f:
    f.write(text)
    f.flush()
    os.fsync(f.fileno())
  os.replace(tmp, qf)
finally:
  try:
    if os.path.exists(tmp):
      os.remove(tmp)
  except Exception:
    pass
PY
  local py_rc=$?
  if (( py_rc != 0 )); then
    return "${py_rc}"
  fi
  chmod 600 "${qf}" 2>/dev/null || true
  return 0
}

ssh_qac_atomic_update_file() {
  # args: json_file action [args...]
  local qf="$1"
  local action="$2"
  shift 2 || true
  ssh_qac_atomic_update_file_unlocked "${qf}" "${action}" "$@"
}

ssh_qac_restore_file_unlocked() {
  local src="${1:-}"
  local dst="${2:-}"
  local tmp=""
  [[ -n "${src}" && -n "${dst}" ]] || return 1
  mkdir -p "$(dirname "${dst}")" 2>/dev/null || true
  tmp="$(mktemp)" || return 1
  if ! python3 - "${src}" "${dst}" "${tmp}" <<'PY'
import json
import pathlib
import shutil
import sys

src = pathlib.Path(sys.argv[1])
dst = pathlib.Path(sys.argv[2])
tmp = pathlib.Path(sys.argv[3])

def load_json(path):
  try:
    loaded = json.loads(path.read_text(encoding="utf-8"))
    return loaded if isinstance(loaded, dict) else {}
  except Exception:
    return {}

payload = load_json(src)
if not payload:
  shutil.copyfile(src, tmp)
  raise SystemExit(0)

current = load_json(dst)
status = payload.get("status")
if not isinstance(status, dict):
  status = {}
  payload["status"] = status

current_status = current.get("status")
if not isinstance(current_status, dict):
  current_status = {}

preserve_qac_lock_context = (
  bool(current_status.get("account_locked")) and
  str(current_status.get("lock_owner") or "").strip() == "ssh_qac" and
  str(current_status.get("lock_shell_restore") or "").strip() != "" and
  not bool(status.get("account_locked")) and
  str(status.get("lock_owner") or "").strip() == "" and
  str(status.get("lock_shell_restore") or "").strip() == ""
)

if preserve_qac_lock_context:
  status["account_locked"] = True
  status["lock_owner"] = "ssh_qac"
  status["lock_shell_restore"] = str(current_status.get("lock_shell_restore") or "").strip()

tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY
  then
    rm -f -- "${tmp}" >/dev/null 2>&1 || true
    return 1
  fi
  install -m 600 "${tmp}" "${dst}" || {
    rm -f -- "${tmp}" >/dev/null 2>&1 || true
    return 1
  }
  rm -f -- "${tmp}" >/dev/null 2>&1 || true
}

ssh_qac_restore_file_locked() {
  local src="${1:-}"
  local dst="${2:-}"
  ssh_qac_run_locked ssh_qac_restore_file_unlocked "${src}" "${dst}"
}

ssh_qac_apply_with_required_enforcer() {
  # args: username json_file action [args...]
  local username="${1:-}"
  local qf="${2:-}"
  local action="${3:-}"
  shift 3 || true

  if [[ -z "${username}" || -z "${qf}" || -z "${action}" ]]; then
    warn "Helper SSH QAC dipanggil tanpa argumen lengkap."
    return 1
  fi

  if [[ "${USER_DATA_MUTATION_LOCK_HELD:-0}" != "1" ]]; then
    user_data_mutation_run_locked ssh_qac_apply_with_required_enforcer "${username}" "${qf}" "${action}" "$@"
    return $?
  fi

  local backup_file=""
  backup_file="$(mktemp "/tmp/ssh-qac.${username}.XXXXXX")" || {
    warn "Gagal menyiapkan backup state SSH."
    return 1
  }

  if ! SSH_QAC_ATOMIC_BACKUP_FILE="${backup_file}" ssh_qac_atomic_update_file "${qf}" "${action}" "$@"; then
    rm -f -- "${backup_file}"
    return 1
  fi

  if ! ssh_qac_enforce_now "${username}"; then
    warn "Enforcer SSH QAC gagal untuk '${username}'. State di-rollback."
    local -a rollback_notes=()
    if ! ssh_qac_restore_file_locked "${backup_file}" "${qf}" >/dev/null 2>&1; then
      rollback_notes+=("rollback state gagal")
    else
      if ! ssh_qac_enforce_now "${username}"; then
        rollback_notes+=("rollback enforcer gagal")
      fi
    fi
    if ! ssh_account_info_refresh_warn "${username}"; then
      rollback_notes+=("rollback account info gagal")
    fi
    rm -f -- "${backup_file}"
    if (( ${#rollback_notes[@]} > 0 )); then
      warn "Rollback SSH QAC belum sepenuhnya bersih: ${rollback_notes[*]}"
    fi
    return 1
  fi

  if ! ssh_account_info_refresh_warn "${username}"; then
    warn "Refresh SSH ACCOUNT INFO gagal untuk '${username}'. State di-rollback."
    local -a rollback_notes=()
    if ! ssh_qac_restore_file_locked "${backup_file}" "${qf}" >/dev/null 2>&1; then
      rollback_notes+=("rollback state gagal")
    else
      if ! ssh_qac_enforce_now "${username}"; then
        rollback_notes+=("rollback enforcer gagal")
      fi
      if ! ssh_account_info_refresh_warn "${username}"; then
        rollback_notes+=("rollback account info gagal")
      fi
    fi
    rm -f -- "${backup_file}"
    if (( ${#rollback_notes[@]} > 0 )); then
      warn "Rollback SSH QAC belum sepenuhnya bersih: ${rollback_notes[*]}"
    fi
    return 1
  fi
  rm -f -- "${backup_file}"
  return 0
}

ssh_qac_apply_with_required_refresh() {
  # args: username json_file action [args...]
  local username="${1:-}"
  local qf="${2:-}"
  local action="${3:-}"
  shift 3 || true

  if [[ -z "${username}" || -z "${qf}" || -z "${action}" ]]; then
    warn "Helper SSH speed/QAC dipanggil tanpa argumen lengkap."
    return 1
  fi

  if [[ "${USER_DATA_MUTATION_LOCK_HELD:-0}" != "1" ]]; then
    user_data_mutation_run_locked ssh_qac_apply_with_required_refresh "${username}" "${qf}" "${action}" "$@"
    return $?
  fi

  local backup_file=""
  backup_file="$(mktemp "/tmp/ssh-qac.${username}.XXXXXX")" || {
    warn "Gagal menyiapkan backup state SSH."
    return 1
  }

  if ! SSH_QAC_ATOMIC_BACKUP_FILE="${backup_file}" ssh_qac_atomic_update_file "${qf}" "${action}" "$@"; then
    rm -f -- "${backup_file}"
    return 1
  fi

  if ! ssh_account_info_refresh_from_state "${username}"; then
    warn "SSH ACCOUNT INFO gagal disinkronkan untuk '${username}'. State di-rollback."
    local -a rollback_notes=()
    if ! ssh_qac_restore_file_locked "${backup_file}" "${qf}" >/dev/null 2>&1; then
      rollback_notes+=("rollback state gagal")
    else
      if ! ssh_account_info_refresh_from_state "${username}"; then
        rollback_notes+=("rollback account info gagal")
      fi
    fi
    rm -f -- "${backup_file}"
    if (( ${#rollback_notes[@]} > 0 )); then
      warn "Rollback SSH speed/QAC belum sepenuhnya bersih: ${rollback_notes[*]}"
    fi
    return 1
  fi

  rm -f -- "${backup_file}"
  return 0
}

ssh_qac_view_json() {
  local qf="$1"
  title
  echo "SSH QAC metadata: ${qf}"
  hr
  need_python3
  if have_cmd less; then
    python3 - <<'PY' "${qf}" | less -R
import json
import sys

p = sys.argv[1]
try:
  d = json.load(open(p, "r", encoding="utf-8"))
except Exception:
  print(open(p, "r", encoding="utf-8", errors="replace").read())
  raise SystemExit(0)

exp = d.get("expired_at")
if isinstance(exp, str) and exp:
  d["expired_at"] = exp[:10]
print(json.dumps(d, ensure_ascii=False, indent=2))
PY
  else
    python3 - <<'PY' "${qf}"
import json
import sys

p = sys.argv[1]
try:
  d = json.load(open(p, "r", encoding="utf-8"))
except Exception:
  print(open(p, "r", encoding="utf-8", errors="replace").read())
  raise SystemExit(0)

exp = d.get("expired_at")
if isinstance(exp, str) and exp:
  d["expired_at"] = exp[:10]
print(json.dumps(d, ensure_ascii=False, indent=2))
PY
  fi
  hr
  pause
}

ssh_qac_print_table_page() {
  local page="${1:-0}"
  local total="${#SSH_QAC_VIEW_INDEXES[@]}"
  local pages=0
  local display_pages=1
  if (( total > 0 )); then
    pages=$(( (total + SSH_QAC_PAGE_SIZE - 1) / SSH_QAC_PAGE_SIZE ))
    display_pages="${pages}"
  fi
  if (( page < 0 )); then
    page=0
  fi
  if (( pages > 0 && page >= pages )); then
    page=$((pages - 1))
  fi
  SSH_QAC_PAGE="${page}"

  echo "SSH accounts: ${total} | page $((page + 1))/${display_pages}"
  if [[ -n "${SSH_QAC_QUERY}" ]]; then
    echo "Filter: '${SSH_QAC_QUERY}'"
  fi
  echo

  if (( total == 0 )); then
    echo "Belum ada data SSH QAC."
    return 0
  fi

  printf "%-4s %-18s %-11s %-11s %-12s %-10s %-6s\n" "NO" "Username" "Quota" "Used" "Expired" "IPLimit" "Lock"
  hr

  local start end i list_pos real_idx qf fields username ql qu exp ipd lock
  start=$((page * SSH_QAC_PAGE_SIZE))
  end=$((start + SSH_QAC_PAGE_SIZE))
  if (( end > total )); then
    end="${total}"
  fi
  for (( i=start; i<end; i++ )); do
    list_pos="${i}"
    real_idx="${SSH_QAC_VIEW_INDEXES[$list_pos]}"
    qf="${SSH_QAC_FILES[$real_idx]}"
    fields="$(ssh_qac_read_summary_fields "${qf}")"
    IFS='|' read -r username ql qu exp ipd _ lock <<<"${fields}"
    printf "%-4s %-18s %-11s %-11s %-12s %-10s %-6s\n" "$((i - start + 1))" "${username}" "${ql}" "${qu}" "${exp}" "${ipd}" "${lock}"
  done
}

ssh_qac_edit_flow() {
  # args: view_no (1-based pada halaman aktif)
  local view_no="$1"

  [[ "${view_no}" =~ ^[0-9]+$ ]] || { warn "Input bukan angka"; pause; return 0; }
  local total page pages start end rows
  total="${#SSH_QAC_VIEW_INDEXES[@]}"
  if (( total <= 0 )); then
    warn "Tidak ada data"
    pause
    return 0
  fi
  page="${SSH_QAC_PAGE:-0}"
  pages=$(( (total + SSH_QAC_PAGE_SIZE - 1) / SSH_QAC_PAGE_SIZE ))
  if (( page < 0 )); then page=0; fi
  if (( pages > 0 && page >= pages )); then page=$((pages - 1)); fi
  start=$((page * SSH_QAC_PAGE_SIZE))
  end=$((start + SSH_QAC_PAGE_SIZE))
  if (( end > total )); then end="${total}"; fi
  rows=$((end - start))

  if (( view_no < 1 || view_no > rows )); then
    warn "NO di luar range"
    pause
    return 0
  fi

  local list_pos real_idx qf
  list_pos=$((start + view_no - 1))
  real_idx="${SSH_QAC_VIEW_INDEXES[$list_pos]}"
  qf="${SSH_QAC_FILES[$real_idx]}"
  local qf_base username_hint=""
  qf_base="$(basename "${qf}")"
  qf_base="${qf_base%.json}"
  username_hint="$(ssh_username_from_key "${qf_base}")"

  if [[ ! -f "${qf}" ]]; then
    warn "Metadata SSH QAC untuk '${username_hint}' belum ada."
    echo "Bootstrap akan membuat state placeholder minimal:"
	    echo "  - quota used = 0"
	    echo "  - created_at = hari ini"
	    echo "  - expired_at = -"
	    hr
	    if ! confirm_menu_apply_now "Buat metadata SSH QAC awal untuk '${username_hint}' sekarang?"; then
	      pause
	      return 0
	    fi
	    if ! confirm_menu_apply_now "Konfirmasi final: buat placeholder metadata SSH QAC baru untuk '${username_hint}'?"; then
	      pause
	      return 0
	    fi
	    local bootstrap_ack=""
	    read -r -p "Ketik persis 'BOOTSTRAP SSH QAC ${username_hint}' untuk lanjut bootstrap placeholder SSH QAC (atau kembali): " bootstrap_ack
	    if is_back_choice "${bootstrap_ack}"; then
	      pause
	      return 0
	    fi
	    if [[ "${bootstrap_ack}" != "BOOTSTRAP SSH QAC ${username_hint}" ]]; then
	      warn "Konfirmasi bootstrap placeholder SSH QAC tidak cocok. Dibatalkan."
	      pause
	      return 0
	    fi
	    if ! ssh_qac_metadata_bootstrap_if_missing "${username_hint}" "${qf}"; then
	      warn "Gagal membuat metadata SSH QAC awal untuk '${username_hint}'."
	      pause
      return 1
    fi
  fi

  while true; do
    local label_w=18
    title
    echo "4) SSH QAC > Detail"
    hr
    printf "%-${label_w}s : %s\n" "File" "${qf}"
    hr

    local fields username ql_disp qu_disp exp_date ip_state ip_lim block_reason speed_state speed_down speed_up lock_state
    local distinct_ip_count ip_limit_metric distinct_ips active_sessions_total active_sessions_runtime active_sessions_dropbear
    fields="$(ssh_qac_read_detail_fields "${qf}")"
    IFS='|' read -r \
      username \
      ql_disp \
      qu_disp \
      exp_date \
      ip_state \
      ip_lim \
      block_reason \
      speed_state \
      speed_down \
      speed_up \
      lock_state \
      distinct_ip_count \
      ip_limit_metric \
      distinct_ips \
      active_sessions_total \
      active_sessions_runtime \
      active_sessions_dropbear <<<"${fields}"

    [[ "${distinct_ip_count}" =~ ^[0-9]+$ ]] || distinct_ip_count="0"
    [[ "${ip_limit_metric}" =~ ^[0-9]+$ ]] || ip_limit_metric="0"
    [[ "${active_sessions_total}" =~ ^[0-9]+$ ]] || active_sessions_total="0"
    [[ "${active_sessions_runtime}" =~ ^[0-9]+$ ]] || active_sessions_runtime="0"
    [[ "${active_sessions_dropbear}" =~ ^[0-9]+$ ]] || active_sessions_dropbear="0"
    [[ -n "${distinct_ips}" ]] || distinct_ips="-"

    printf "%-${label_w}s : %s\n" "Username" "${username}"
    printf "%-${label_w}s : %s\n" "Quota Limit" "${ql_disp}"
    printf "%-${label_w}s : %s\n" "Quota Used" "${qu_disp}"
    printf "%-${label_w}s : %s\n" "Expired At" "${exp_date}"
    printf "%-${label_w}s : %s\n" "IP/Login Limit" "${ip_state}"
    printf "%-${label_w}s : %s\n" "IP/Login Limit Max" "${ip_lim}"
    printf "%-${label_w}s : %s\n" "IP Unik Aktif" "${distinct_ip_count}"
    printf "%-${label_w}s : %s\n" "Daftar IP Aktif" "${distinct_ips}"
    printf "%-${label_w}s : %s\n" "IP/Login Metric" "${ip_limit_metric}"
    printf "%-${label_w}s : %s\n" "Block Reason" "${block_reason}"
    printf "%-${label_w}s : %s\n" "Account Locked" "${lock_state}"
    printf "%-${label_w}s : %s\n" "Sesi Aktif" "${active_sessions_total}"
    printf "%-${label_w}s : %s Mbps\n" "Speed Download" "${speed_down}"
    printf "%-${label_w}s : %s Mbps\n" "Speed Upload" "${speed_up}"
    printf "%-${label_w}s : %s\n" "Speed Limit" "${speed_state}"
    local ssh_bootstrap_needed ssh_bootstrap_source
    IFS='|' read -r ssh_bootstrap_needed ssh_bootstrap_source <<<"$(ssh_qac_bootstrap_status_get "${qf}")"
    if [[ "${ssh_bootstrap_needed}" == "true" ]]; then
      printf "%-${label_w}s : %s\n" "Bootstrap" "PERLU REVIEW"
      [[ -n "${ssh_bootstrap_source}" ]] && printf "%-${label_w}s : %s\n" "Source" "${ssh_bootstrap_source}"
    fi
    hr

    echo "  1) View JSON"
    echo "  2) Set Quota (GB)"
    echo "  3) Reset Quota"
    echo "  4) Toggle Block"
    echo "  5) Toggle IP/Login Limit"
    echo "  6) Set IP/Login Limit"
    echo "  7) Unlock IP/Login"
    echo "  8) Set Speed Download"
    echo "  9) Set Speed Upload"
    echo " 10) Speed Limit Enable/Disable (toggle)"
    echo "  0) Back"
    hr
    if ! read -r -p "Pilih: " c; then
      echo
      break
    fi
    if is_back_choice "${c}"; then
      return 0
    fi

    case "${c}" in
      1)
        ssh_qac_view_json "${qf}"
        ;;
      2)
        if ! read -r -p "Quota Limit (GB) (atau kembali): " gb; then
          echo
          return 0
        fi
        if is_back_choice "${gb}"; then
          continue
        fi
        if [[ -z "${gb}" ]]; then
          warn "Quota kosong"
          pause
          continue
        fi
        local gb_num qb
        gb_num="$(normalize_gb_input "${gb}")"
        if [[ -z "${gb_num}" ]]; then
          warn "Format quota tidak valid. Contoh: 5 atau 5GB"
          pause
          continue
        fi
        qb="$(bytes_from_gb "${gb_num}")"
        if ! confirm_menu_apply_now "Set quota limit SSH ${username} ke ${gb_num} GB sekarang?"; then
          pause
          continue
        fi
        if ! ssh_qac_apply_with_required_enforcer "${username}" "${qf}" set_quota_limit "${qb}"; then
          warn "Gagal update quota limit SSH."
          pause
          continue
        fi
        log "Quota limit SSH diubah: ${gb_num} GB"
        pause
        ;;
      3)
        if ! confirm_menu_apply_now "Reset quota used SSH ${username} ke 0 sekarang?"; then
          pause
          continue
        fi
        if ! ssh_qac_apply_with_required_enforcer "${username}" "${qf}" reset_quota_used; then
          warn "Gagal reset quota used SSH."
          pause
          continue
        fi
        log "Quota used SSH di-reset: 0"
        pause
        ;;
      4)
        local st_mb
        st_mb="$(ssh_qac_get_status_bool "${qf}" "manual_block")"
        if [[ "${st_mb}" == "true" ]]; then
          if ! confirm_menu_apply_now "Nonaktifkan manual block SSH untuk ${username} sekarang?"; then
            pause
            continue
          fi
          if ! ssh_qac_apply_with_required_enforcer "${username}" "${qf}" manual_block_set off; then
            warn "Gagal menonaktifkan manual block SSH."
            pause
            continue
          fi
          log "Manual block SSH: OFF"
        else
          if ! confirm_menu_apply_now "Aktifkan manual block SSH untuk ${username} sekarang?"; then
            pause
            continue
          fi
          if ! ssh_qac_apply_with_required_enforcer "${username}" "${qf}" manual_block_set on; then
            warn "Gagal mengaktifkan manual block SSH."
            pause
            continue
          fi
          log "Manual block SSH: ON"
        fi
        pause
        ;;
      5)
        local ip_on
        ip_on="$(ssh_qac_get_status_bool "${qf}" "ip_limit_enabled")"
        if [[ "${ip_on}" == "true" ]]; then
          if ! confirm_menu_apply_now "Nonaktifkan IP/Login limit SSH untuk ${username} sekarang?"; then
            pause
            continue
          fi
          if ! ssh_qac_apply_with_required_enforcer "${username}" "${qf}" ip_limit_enabled_set off; then
            warn "Gagal menonaktifkan IP limit SSH."
            pause
            continue
          fi
          log "IP limit SSH: OFF"
        else
          if ! confirm_menu_apply_now "Aktifkan IP/Login limit SSH untuk ${username} sekarang?"; then
            pause
            continue
          fi
          if ! ssh_qac_apply_with_required_enforcer "${username}" "${qf}" ip_limit_enabled_set on; then
            warn "Gagal mengaktifkan IP limit SSH."
            pause
            continue
          fi
          log "IP limit SSH: ON"
        fi
        pause
        ;;
      6)
        if ! read -r -p "IP limit (angka) (atau kembali): " lim; then
          echo
          return 0
        fi
        if is_back_word_choice "${lim}"; then
          continue
        fi
        if [[ -z "${lim}" || ! "${lim}" =~ ^[0-9]+$ || "${lim}" -le 0 ]]; then
          warn "Limit harus angka > 0"
          pause
          continue
        fi
        if ! confirm_menu_apply_now "Set IP/Login limit SSH ${username} ke ${lim} sekarang?"; then
          pause
          continue
        fi
        if ! ssh_qac_apply_with_required_enforcer "${username}" "${qf}" set_ip_limit "${lim}"; then
          warn "Gagal set IP limit SSH."
          pause
          continue
        fi
        log "IP limit SSH diubah: ${lim}"
        pause
        ;;
      7)
        if ! confirm_menu_apply_now "Unlock IP/Login lock SSH untuk ${username} sekarang?"; then
          pause
          continue
        fi
        if ! ssh_qac_apply_with_required_enforcer "${username}" "${qf}" clear_ip_limit_locked; then
          warn "Gagal unlock IP lock SSH."
          pause
          continue
        fi
        log "IP lock SSH di-unlock"
        pause
        ;;
      8)
        if ! read -r -p "Speed Download (Mbps) (contoh: 20 atau 20mbit) (atau kembali): " speed_down_input; then
          echo
          return 0
        fi
        if is_back_word_choice "${speed_down_input}"; then
          continue
        fi
        speed_down_input="$(normalize_speed_mbit_input "${speed_down_input}")"
        if [[ -z "${speed_down_input}" ]] || ! speed_mbit_is_positive "${speed_down_input}"; then
          warn "Speed download tidak valid. Gunakan angka > 0."
          pause
          continue
        fi
        if ! confirm_menu_apply_now "Set speed download SSH ${username} ke ${speed_down_input} Mbps sekarang?"; then
          pause
          continue
        fi
        if ! ssh_qac_apply_with_required_refresh "${username}" "${qf}" set_speed_down "${speed_down_input}"; then
          warn "Gagal set speed download SSH."
          pause
          continue
        fi
        log "Speed download SSH diubah: ${speed_down_input} Mbps"
        pause
        ;;
      9)
        if ! read -r -p "Speed Upload (Mbps) (contoh: 10 atau 10mbit) (atau kembali): " speed_up_input; then
          echo
          return 0
        fi
        if is_back_word_choice "${speed_up_input}"; then
          continue
        fi
        speed_up_input="$(normalize_speed_mbit_input "${speed_up_input}")"
        if [[ -z "${speed_up_input}" ]] || ! speed_mbit_is_positive "${speed_up_input}"; then
          warn "Speed upload tidak valid. Gunakan angka > 0."
          pause
          continue
        fi
        if ! confirm_menu_apply_now "Set speed upload SSH ${username} ke ${speed_up_input} Mbps sekarang?"; then
          pause
          continue
        fi
        if ! ssh_qac_apply_with_required_refresh "${username}" "${qf}" set_speed_up "${speed_up_input}"; then
          warn "Gagal set speed upload SSH."
          pause
          continue
        fi
        log "Speed upload SSH diubah: ${speed_up_input} Mbps"
        pause
        ;;
      10)
        local speed_on speed_down_now speed_up_now
        speed_on="$(ssh_qac_get_status_bool "${qf}" "speed_limit_enabled")"
        if [[ "${speed_on}" == "true" ]]; then
          if ! confirm_menu_apply_now "Nonaktifkan speed limit SSH untuk ${username} sekarang?"; then
            pause
            continue
          fi
          if ! ssh_qac_apply_with_required_refresh "${username}" "${qf}" speed_limit_set off; then
            warn "Gagal menonaktifkan speed limit SSH."
            pause
            continue
          fi
          log "Speed limit SSH: OFF"
          pause
          continue
        fi

        speed_down_now="$(ssh_qac_get_status_number "${qf}" "speed_down_mbit")"
        speed_up_now="$(ssh_qac_get_status_number "${qf}" "speed_up_mbit")"

        if ! speed_mbit_is_positive "${speed_down_now}"; then
          if ! read -r -p "Speed Download (Mbps) (contoh: 20 atau 20mbit) (atau kembali): " speed_down_now; then
            echo
            return 0
          fi
          if is_back_choice "${speed_down_now}"; then
            continue
          fi
          speed_down_now="$(normalize_speed_mbit_input "${speed_down_now}")"
          if [[ -z "${speed_down_now}" ]] || ! speed_mbit_is_positive "${speed_down_now}"; then
            warn "Speed download tidak valid. Speed limit tetap OFF."
            pause
            continue
          fi
        fi
        if ! speed_mbit_is_positive "${speed_up_now}"; then
          if ! read -r -p "Speed Upload (Mbps) (contoh: 10 atau 10mbit) (atau kembali): " speed_up_now; then
            echo
            return 0
          fi
          if is_back_choice "${speed_up_now}"; then
            continue
          fi
          speed_up_now="$(normalize_speed_mbit_input "${speed_up_now}")"
          if [[ -z "${speed_up_now}" ]] || ! speed_mbit_is_positive "${speed_up_now}"; then
            warn "Speed upload tidak valid. Speed limit tetap OFF."
            pause
            continue
          fi
        fi

        if ! confirm_menu_apply_now "Aktifkan speed limit SSH ${username} dengan DOWN ${speed_down_now} Mbps dan UP ${speed_up_now} Mbps sekarang?"; then
          pause
          continue
        fi
        if ! ssh_qac_apply_with_required_refresh "${username}" "${qf}" set_speed_all_enable "${speed_down_now}" "${speed_up_now}"; then
          warn "Gagal mengaktifkan speed limit SSH."
          pause
          continue
        fi
        log "Speed limit SSH: ON"
        pause
        ;;
      *)
        warn "Pilihan tidak valid"
        sleep 1
        ;;
    esac
  done
}

ssh_quota_menu() {
  ssh_state_dirs_prepare
  need_python3

  SSH_QAC_PAGE=0
  SSH_QAC_QUERY=""

  while true; do
    ui_menu_screen_begin "4) SSH QAC"
    ssh_qac_collect_files
    ssh_qac_build_view_indexes
    ssh_qac_print_table_page "${SSH_QAC_PAGE}"
    hr

    echo "Masukkan NO untuk view/edit, atau ketik:"
    echo "  sync) jalankan enforcement SSH QAC sekarang"
    echo "  search) filter username"
    echo "  clear) hapus filter"
    echo "  next / previous"
    hr
    if ! read -r -p "Pilih: " c; then
      echo
      break
    fi

    if is_back_choice "${c}"; then
      break
    fi

    case "${c}" in
      sync)
        if ! ssh_qac_enforce_now_warn; then
          warn "Sinkronisasi enforcement SSH QAC gagal."
        else
          log "Enforcement SSH QAC selesai."
        fi
        pause
        ;;
      next|n)
        local pages
        pages="$(ssh_qac_total_pages_for_indexes)"
        if (( pages > 0 && SSH_QAC_PAGE < pages - 1 )); then
          SSH_QAC_PAGE=$((SSH_QAC_PAGE + 1))
        fi
        ;;
      previous|p|prev)
        if (( SSH_QAC_PAGE > 0 )); then
          SSH_QAC_PAGE=$((SSH_QAC_PAGE - 1))
        fi
        ;;
      search)
        if ! read -r -p "Search username (atau kembali): " q; then
          echo
          break
        fi
        if is_back_choice "${q}"; then
          continue
        fi
        SSH_QAC_QUERY="${q}"
        SSH_QAC_PAGE=0
        ;;
      clear)
        SSH_QAC_QUERY=""
        SSH_QAC_PAGE=0
        ;;
      *)
        if [[ "${c}" =~ ^[0-9]+$ ]]; then
          ssh_qac_edit_flow "${c}"
        else
          warn "Pilihan tidak valid"
          sleep 1
        fi
        ;;
    esac
  done
}

daemon_log_tail_show() {
  # args: service_name [lines]
  local svc="$1"
  local lines="${2:-20}"
  title
  echo "9) Maintenance > Log ${svc}"
  hr
  if svc_exists "${svc}"; then
    journalctl -u "${svc}" --no-pager -n "${lines}" 2>/dev/null || true
  else
    warn "${svc}.service tidak terpasang"
  fi
  hr
  pause
}

sshws_restart_after_dropbear() {
  local dropbear_svc="$1"
  local dropbear_port="" dropbear_probe=""
  if ! svc_exists "${dropbear_svc}"; then
    warn "${dropbear_svc}.service tidak terpasang"
    return 1
  fi
  if ! svc_restart_checked "${dropbear_svc}" 60; then
    warn "Restart ${dropbear_svc} gagal."
    return 1
  fi
  dropbear_port="$(sshws_detect_dropbear_port)"
  dropbear_probe="$(sshws_probe_tcp_endpoint "127.0.0.1" "${dropbear_port}" "tcp")"
  if ! sshws_probe_result_is_healthy "${dropbear_probe}"; then
    warn "Probe ${dropbear_svc} gagal setelah restart: $(sshws_probe_result_disp "${dropbear_probe}")"
    return 1
  fi
  return 0
}

install_discord_bot_menu() {
  local installer_cmd="/usr/local/bin/install-discord-bot"
  ui_menu_screen_begin "11) Discord Bot"

  if [[ ! -x "${installer_cmd}" ]]; then
    warn "Installer bot Discord tidak ditemukan / tidak executable:"
    echo "  ${installer_cmd}"
    echo
    echo "Hint: jalankan ulang run.sh agar installer ikut dipasang."
    hr
    pause
    return 0
  fi

  echo "Menjalankan installer:"
  echo "  ${installer_cmd} menu"
  echo "Boundary:"
  echo "  - kontrol akan diserahkan ke installer eksternal"
  echo "  - installer dapat mengubah file/env/service bot di luar menu manage ini"
  hr
  if ! confirm_menu_apply_now "Serahkan kontrol ke installer bot Discord eksternal sekarang?"; then
    pause
    return 0
  fi
  if ! "${installer_cmd}" menu; then
    warn "Installer bot Discord keluar dengan status error."
    hr
    pause
  fi
  return 0
}

install_telegram_bot_menu() {
  local installer_cmd="/usr/local/bin/install-telegram-bot"
  ui_menu_screen_begin "12) Telegram Bot"

  if [[ ! -x "${installer_cmd}" ]]; then
    warn "Installer bot Telegram tidak ditemukan / tidak executable:"
    echo "  ${installer_cmd}"
    echo
    echo "Hint: jalankan ulang run.sh agar installer ikut dipasang."
    hr
    pause
    return 0
  fi

  echo "Menjalankan installer:"
  echo "  ${installer_cmd} menu"
  echo "Boundary:"
  echo "  - kontrol akan diserahkan ke installer eksternal"
  echo "  - installer dapat mengubah file/env/service bot di luar menu manage ini"
  hr
  if ! confirm_menu_apply_now "Serahkan kontrol ke installer bot Telegram eksternal sekarang?"; then
    pause
    return 0
  fi
  if ! "${installer_cmd}" menu; then
    warn "Installer bot Telegram keluar dengan status error."
    hr
    pause
  fi
  return 0
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
  echo "9) Maintenance > Xray Daemons"
  hr

  local sshws_dropbear_svc="${SSHWS_DROPBEAR_SERVICE:-sshws-dropbear}"
  local sshws_stunnel_svc="${SSHWS_STUNNEL_SERVICE:-sshws-stunnel}"
  local sshws_proxy_svc="${SSHWS_PROXY_SERVICE:-sshws-proxy}"
  local sshws_qac_timer="${SSHWS_QAC_ENFORCER_TIMER:-sshws-qac-enforcer.timer}"

  local daemons=(
    "xray" "nginx" "xray-expired" "xray-quota" "xray-limit-ip" "xray-speed" "wireproxy"
    "${sshws_dropbear_svc}" "${sshws_stunnel_svc}" "${sshws_proxy_svc}" "${sshws_qac_timer}"
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
  echo " 10) Restart ${sshws_dropbear_svc} only"
  echo " 11) Restart ${sshws_stunnel_svc}"
  echo " 12) Restart ${sshws_proxy_svc}"
  echo " 13) Restart All SSH WS"
  echo " 14) ${sshws_dropbear_svc} Logs"
  echo " 15) ${sshws_stunnel_svc} Logs"
  echo " 16) ${sshws_proxy_svc} Logs"
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
    10)
      if confirm_menu_apply_now "Restart ${sshws_dropbear_svc} saja sekarang?"; then
        if ! sshws_restart_after_dropbear "${sshws_dropbear_svc}" "${sshws_stunnel_svc}" "${sshws_proxy_svc}"; then
          warn "Restart SSH WS gagal."
        fi
      fi
      pause
      ;;
    11)
      if confirm_menu_apply_now "Restart ${sshws_stunnel_svc} sekarang?"; then
        if ! sshws_restart_services_checked "${sshws_stunnel_svc}"; then
          warn "Restart ${sshws_stunnel_svc} gagal."
        fi
      fi
      pause
      ;;
    12)
      if confirm_menu_apply_now "Restart ${sshws_proxy_svc} sekarang?"; then
        if ! sshws_restart_services_checked "${sshws_proxy_svc}"; then
          warn "Restart ${sshws_proxy_svc} gagal."
        fi
      fi
      pause
      ;;
    13)
      if confirm_menu_apply_now "Restart semua service SSH WS sekarang?"; then
        if ! sshws_restart_services_checked "${sshws_dropbear_svc}" "${sshws_stunnel_svc}" "${sshws_proxy_svc}"; then
          pause
          return 1
        fi
      fi
      pause
      ;;
    14) daemon_log_tail_show "${sshws_dropbear_svc}" 20 ;;
    15) daemon_log_tail_show "${sshws_stunnel_svc}" 20 ;;
    16) daemon_log_tail_show "${sshws_proxy_svc}" 20 ;;
    0|kembali|k|back|b) return 0 ;;
    *) warn "Pilihan tidak valid" ; sleep 1 ;;
  esac
}

# -------------------------
