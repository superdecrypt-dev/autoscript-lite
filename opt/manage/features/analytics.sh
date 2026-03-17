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

  echo "Domain terdeteksi: ${domain}"
  hr
  if ! confirm_menu_apply_now "Jalankan renew certificate untuk domain ${domain} sekarang?"; then
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

      warn "Terdeteksi konflik port 80. Menghentikan web service sementara untuk retry renew..."
      if (( ${#conflict_services[@]} > 0 )); then
        printf 'Service yang akan dihentikan sementara: %s\n' "$(IFS=', '; echo "${conflict_services[*]}")"
        hr
        if ! confirm_menu_apply_now "Hentikan sementara service di atas lalu retry renew certificate?"; then
          rm -rf "${cert_backup_dir}" >/dev/null 2>&1 || true
          domain_control_clear_stopped_services
          domain_control_clear_runtime_snapshot
          hr
          pause
          return 0
        fi
      fi

      if ! stop_conflicting_services; then
        warn "Renew dibatalkan karena tidak semua service konflik berhasil dihentikan."
        if ! domain_control_restore_stopped_services_strict 3; then
          warn "Sebagian service yang sempat dihentikan juga gagal dipulihkan."
        fi
        domain_control_clear_stopped_services
        rm -rf "${cert_backup_dir}" >/dev/null 2>&1 || true
        domain_control_clear_runtime_snapshot
        hr
        pause
        return 1
      fi

      if "${acme}" --renew -d "${domain}" --force 2>&1; then
        renew_ok="true"
      fi

      if ! domain_control_restore_stopped_services_strict 3; then
        warn "Renew berhasil, tetapi sebagian service yang dihentikan sementara tidak kembali aktif. Mencoba rollback cert/runtime..."
        if ! cert_snapshot_restore "${cert_backup_dir}" >/dev/null 2>&1; then
          rollback_notes+=("restore sertifikat gagal")
        fi
        domain_control_restore_cert_runtime_after_rollback rollback_notes || true
        if ! domain_control_restore_stopped_services_strict 3; then
          rollback_notes+=("restore service runtime TLS gagal")
        else
          domain_control_clear_stopped_services
        fi
        rm -rf "${cert_backup_dir}" >/dev/null 2>&1 || true
        domain_control_clear_runtime_snapshot
        if (( ${#rollback_notes[@]} > 0 )); then
          warn "Rollback renew cert juga bermasalah: ${rollback_notes[*]}"
        fi
        hr
        pause
        return 1
      fi
      domain_control_clear_stopped_services
    else
      warn "acme.sh renew domain aktif gagal, mencoba ulang..."
      if "${acme}" --renew -d "${domain}" --force 2>&1; then
        renew_ok="true"
      fi
    fi
  fi

  if [[ "${renew_ok}" != "true" ]]; then
    warn "Renew gagal. Cek output di atas."
    rm -rf "${cert_backup_dir}" >/dev/null 2>&1 || true
    domain_control_clear_stopped_services
    domain_control_clear_runtime_snapshot
    hr
    pause
    return 1
  fi

  echo
  if ! cert_runtime_restart_active_tls_consumers; then
    warn "Cert berhasil diperbarui, tetapi restart consumer TLS tambahan gagal. Mencoba rollback cert sebelumnya..."
    cert_snapshot_restore "${cert_backup_dir}" >/dev/null 2>&1 || rollback_notes+=("restore sertifikat gagal")
    domain_control_restore_cert_runtime_after_rollback rollback_notes || true
    if (( ${#rollback_notes[@]} > 0 )); then
      warn "Rollback cert juga bermasalah: ${rollback_notes[*]}"
    fi
    rm -rf "${cert_backup_dir}" >/dev/null 2>&1 || true
    domain_control_clear_stopped_services
    domain_control_clear_runtime_snapshot
    hr
    pause
    return 1
  fi
  if ! cert_runtime_hostname_tls_handshake_check "${domain}"; then
    warn "Cert berhasil diperbarui, tetapi probe TLS hostname gagal. Mencoba rollback cert sebelumnya..."
    cert_snapshot_restore "${cert_backup_dir}" >/dev/null 2>&1 || rollback_notes+=("restore sertifikat gagal")
    domain_control_restore_cert_runtime_after_rollback rollback_notes || true
    if (( ${#rollback_notes[@]} > 0 )); then
      warn "Rollback cert juga bermasalah: ${rollback_notes[*]}"
    fi
    rm -rf "${cert_backup_dir}" >/dev/null 2>&1 || true
    domain_control_clear_stopped_services
    domain_control_clear_runtime_snapshot
    hr
    pause
    return 1
  fi
  rm -rf "${cert_backup_dir}" >/dev/null 2>&1 || true
  domain_control_clear_stopped_services
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
  while true; do
    title
    echo "TLS & Cert"
    hr
    echo "  1) Cert Info"
    echo "  2) Check Expiry"
    echo "  3) Renew Cert"
    echo "  4) Reload Nginx"
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

sshws_status_menu() {
  title
  echo "9) Maintenance > SSH WS Status"
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
  echo "9) Maintenance > Restart SSH WS"
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
  echo "9) Maintenance > SSH WS Combined Logs"
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
    echo "9) Maintenance > SSH WS Diagnostics"
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
  # args: username password quota_bytes expired_at created_at ip_enabled ip_limit speed_enabled speed_down speed_up sshws_token [output_file_override]
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
  domain="$(detect_domain)"
  ip="$(main_info_ip_quiet_get)"
  [[ -n "${ip}" ]] || ip="$(detect_public_ip)"
  geo="$(main_info_geo_lookup "${ip}")"
  IFS='|' read -r geo_ip isp country <<<"${geo}"
  [[ -n "${geo_ip}" && "${geo_ip}" != "-" ]] && ip="${geo_ip}"
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
  # args: username [password_override] [output_file_override]
  local username="${1:-}"
  local password_override="${2:-}"
  local output_file_override="${3:-}"
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

  ssh_account_info_write "${username}" "${password}" "${quota_bytes}" "${expired_at}" "${created_at}" "${ip_enabled}" "${ip_limit}" "${speed_enabled}" "${speed_down}" "${speed_up}" "${sshws_token}" "${output_file_override}"
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
  local created_at expired_at password
  [[ -n "${username}" && -n "${qf}" ]] || return 1
  [[ -f "${qf}" ]] && return 0

  created_at="$(date '+%Y-%m-%d')"
  expired_at="$(ssh_linux_account_expiry_get "${username}" 2>/dev/null || true)"
  [[ -n "${expired_at}" ]] || expired_at="-"

  if ! ssh_user_state_write "${username}" "${created_at}" "${expired_at}"; then
    return 1
  fi

  password="$(ssh_previous_password_get "${username}" 2>/dev/null || true)"
  if [[ -n "${password}" && "${password}" != "-" ]]; then
    ssh_account_info_refresh_from_state "${username}" "${password}" >/dev/null 2>&1 || true
  else
    ssh_account_info_refresh_from_state "${username}" >/dev/null 2>&1 || true
  fi
  return 0
}

ssh_pick_managed_user() {
  local -n _out_ref="$1"
  _out_ref=""

  ssh_state_dirs_prepare

  local -a users=()
  local -A seen_users=()
  local u="" name=""
  while IFS= read -r u; do
    [[ -n "${u}" ]] || continue
    if [[ -n "${seen_users["${u}"]+x}" ]]; then
      continue
    fi
    seen_users["${u}"]=1
    users+=("${u}")
  done < <(find "${SSH_USERS_STATE_DIR}" -maxdepth 1 -type f -name '*.json' -printf '%f\n' 2>/dev/null | sed -E 's/@ssh\.json$//' | sed -E 's/\.json$//' | sort -u)
  while IFS= read -r name; do
    [[ -n "${name}" ]] || continue
    name="${name%@ssh}"
    if [[ -n "${seen_users["${name}"]+x}" ]]; then
      continue
    fi
    seen_users["${name}"]=1
    users+=("${name}")
  done < <(find "${SSH_ACCOUNT_DIR}" -maxdepth 1 -type f -name '*.txt' -printf '%f\n' 2>/dev/null | sed -E 's/@ssh\.txt$//' | sed -E 's/\.txt$//' | sort -u)
  while IFS= read -r name; do
    [[ -n "${name}" ]] || continue
    name="${name%.pass}"
    if [[ -n "${seen_users["${name}"]+x}" ]]; then
      continue
    fi
    seen_users["${name}"]=1
    users+=("${name}")
  done < <(find "${ZIVPN_PASSWORDS_DIR}" -maxdepth 1 -type f -name '*.pass' -printf '%f\n' 2>/dev/null | sort -u)
  while IFS= read -r name; do
    [[ -n "${name}" ]] || continue
    if [[ -n "${seen_users["${name}"]+x}" ]]; then
      continue
    fi
    seen_users["${name}"]=1
    users+=("${name}")
  done < <(ssh_linux_candidate_users_get 2>/dev/null || true)

  if (( ${#users[@]} > 1 )); then
    IFS=$'\n' users=($(printf '%s\n' "${users[@]}" | sort -u))
    unset IFS
  fi

  if (( ${#users[@]} == 0 )); then
    warn "Belum ada akun SSH terkelola."
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
      if userdel "${username}" >/dev/null 2>&1; then
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

ssh_managed_users_lines() {
  ssh_state_dirs_prepare
  need_python3
  python3 - <<'PY' "${SSH_USERS_STATE_DIR}" 2>/dev/null || true
import json
import os
import pwd
import re
import sys
from datetime import datetime

root = sys.argv[1]

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

  if ! useradd -m -s /bin/bash "${username}" >/dev/null 2>&1; then
    ssh_add_user_rollback "${username}" "${qf}" "${acc_file}" "Gagal membuat user Linux '${username}'." "${password}" "false" "false"
    pause
    return 1
  fi

  if ! printf '%s:%s\n' "${username}" "${password}" | chpasswd >/dev/null 2>&1; then
    ssh_add_user_rollback "${username}" "${qf}" "${acc_file}" "Gagal set password user '${username}'." "${password}" "false" "true"
    pause
    return 1
  fi

  if ! chage -E "${expired_at}" "${username}" >/dev/null 2>&1; then
    ssh_add_user_rollback "${username}" "${qf}" "${acc_file}" "Gagal set expiry user '${username}'." "${password}" "false" "true"
    pause
    return 1
  fi

  if ! ssh_user_state_write "${username}" "${created_at}" "${expired_at}"; then
    ssh_add_user_rollback "${username}" "${qf}" "${acc_file}" "Gagal menulis metadata akun SSH." "${password}" "false" "true"
    pause
    return 1
  fi

  if ! ssh_qac_atomic_update_file "${qf}" set_quota_limit "${quota_bytes}"; then
    ssh_add_user_rollback "${username}" "${qf}" "${acc_file}" "Gagal set quota metadata SSH." "${password}" "false" "true"
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
    ssh_add_user_rollback "${username}" "${qf}" "${acc_file}" "${add_fail_msg}" "${password}" "false" "true"
    pause
    return 1
  fi

  if ! ssh_account_info_refresh_from_state "${username}" "${password}"; then
    ssh_add_user_rollback "${username}" "${qf}" "${acc_file}" "Gagal menyiapkan SSH account info." "${password}" "false" "true"
    pause
    return 1
  fi

  if ! ssh_qac_enforce_now_warn "${username}"; then
    if [[ "${ip_enabled}" == "true" ]]; then
      ssh_add_user_rollback "${username}" "${qf}" "${acc_file}" "Gagal enforcement awal SSH (IP/Login limit)." "${password}" "false" "true"
    else
      ssh_add_user_rollback "${username}" "${qf}" "${acc_file}" "Gagal enforcement awal SSH." "${password}" "false" "true"
    fi
    pause
    return 1
  fi
  if ! ssh_dns_adblock_runtime_refresh_if_available; then
    ssh_add_user_rollback "${username}" "${qf}" "${acc_file}" "Gagal refresh runtime DNS Adblock SSH." "${password}" "false" "true"
    pause
    return 1
  fi
  if ! ssh_account_info_refresh_from_state "${username}" "${password}"; then
    ssh_add_user_rollback "${username}" "${qf}" "${acc_file}" "Gagal menulis SSH account info." "${password}" "false" "true"
    pause
    return 1
  fi
  if ! zivpn_sync_user_password_warn "${username}" "${password}"; then
    ssh_add_user_rollback "${username}" "${qf}" "${acc_file}" "Gagal sinkronisasi password ZIVPN." "${password}" "true" "true"
    pause
    return 1
  fi
  if ! ssh_account_info_refresh_from_state "${username}" "${password}"; then
    ssh_add_user_rollback "${username}" "${qf}" "${acc_file}" "Gagal refresh final SSH account info." "${password}" "true" "true"
    pause
    return 1
  fi

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

  if (( ${#notes[@]} > 0 )); then
    printf '%s\n' "$(IFS=' | '; echo "${notes[*]}")"
    return 1
  fi
  return 0
}

ssh_delete_user_apply_locked() {
  local username="$1"
  local previous_password="$2"
  local linux_exists="$3"
  local zivpn_file=""
  local cleanup_failed="" dns_failed="false" zivpn_failed="false"
  local snapshot_dir="" state_mode="absent" state_backup="" state_file=""
  local state_compat_mode="absent" state_compat_backup="" state_compat_file=""
  local account_mode="absent" account_backup="" account_file=""
  local account_compat_mode="absent" account_compat_backup="" account_compat_file=""
  local zivpn_mode="absent" zivpn_backup=""
  local -a notes=()

  if zivpn_runtime_available; then
    zivpn_file="$(zivpn_password_file "${username}")"
  fi
  state_file="$(ssh_user_state_file "${username}")"
  state_compat_file="$(ssh_user_state_compat_file "${username}")"
  account_file="$(ssh_account_info_file "${username}")"
  account_compat_file="${SSH_ACCOUNT_DIR}/${username}.txt"
  snapshot_dir="$(mktemp -d "${TMPDIR:-/tmp}/ssh-delete.${username}.XXXXXX" 2>/dev/null || true)"
  if [[ -z "${snapshot_dir}" || ! -d "${snapshot_dir}" ]]; then
    warn "Gagal menyiapkan snapshot rollback hapus user SSH."
    pause
    return 1
  fi
  if ! ssh_optional_file_snapshot_create "${state_file}" "${snapshot_dir}" state_mode state_backup \
    || ! ssh_optional_file_snapshot_create "${state_compat_file}" "${snapshot_dir}" state_compat_mode state_compat_backup \
    || ! ssh_optional_file_snapshot_create "${account_file}" "${snapshot_dir}" account_mode account_backup \
    || ! ssh_optional_file_snapshot_create "${account_compat_file}" "${snapshot_dir}" account_compat_mode account_compat_backup; then
    rm -rf "${snapshot_dir}" >/dev/null 2>&1 || true
    warn "Gagal membuat snapshot artefak SSH sebelum delete."
    pause
    return 1
  fi
  if [[ -n "${zivpn_file}" ]] && ! ssh_optional_file_snapshot_create "${zivpn_file}" "${snapshot_dir}" zivpn_mode zivpn_backup; then
    rm -rf "${snapshot_dir}" >/dev/null 2>&1 || true
    warn "Gagal membuat snapshot password ZIVPN sebelum delete."
    pause
    return 1
  fi

  if [[ "${linux_exists}" == "true" ]] && ! userdel "${username}" >/dev/null 2>&1; then
    local restore_msg=""
    restore_msg="$(ssh_delete_user_snapshot_restore \
      "${username}" \
      "${state_mode}" "${state_backup}" "${state_file}" \
      "${state_compat_mode}" "${state_compat_backup}" "${state_compat_file}" \
      "${account_mode}" "${account_backup}" "${account_file}" \
      "${account_compat_mode}" "${account_compat_backup}" "${account_compat_file}" \
      "${zivpn_mode}" "${zivpn_backup}" "${zivpn_file}" 2>/dev/null || true)"
    warn "Gagal menghapus user Linux '${username}'."
    [[ -n "${restore_msg}" ]] && warn "Rollback snapshot belum sepenuhnya bersih: ${restore_msg}"
    rm -rf "${snapshot_dir}" >/dev/null 2>&1 || true
    pause
    return 1
  fi

  if [[ -n "${zivpn_file}" ]] && ! zivpn_remove_user_password_warn "${username}"; then
    zivpn_failed="true"
    notes+=("cleanup ZIVPN gagal")
  fi

  if [[ "${zivpn_failed}" != "true" ]]; then
    cleanup_failed="$(ssh_user_artifacts_cleanup_locked "${username}" 2>/dev/null || true)"
    if [[ -n "${cleanup_failed}" ]]; then
      notes+=("cleanup artefak lokal gagal: ${cleanup_failed}")
    fi
  fi

  if [[ "${zivpn_failed}" != "true" && -z "${cleanup_failed}" ]] && ! ssh_dns_adblock_runtime_refresh_if_available; then
    dns_failed="true"
    notes+=("refresh runtime DNS adblock gagal")
  fi

  rm -rf "${snapshot_dir}" >/dev/null 2>&1 || true

  title
  if [[ -n "${cleanup_failed}" || "${dns_failed}" == "true" || "${zivpn_failed}" == "true" ]]; then
    echo "Delete SSH user selesai parsial ⚠"
    echo "Akun Linux sudah terhapus, tetapi cleanup lanjutan belum sepenuhnya bersih."
    if (( ${#notes[@]} > 0 )); then
      printf '%s\n' "$(IFS=' | '; echo "${notes[*]}")"
    fi
    hr
    pause
    return 1
  fi

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
    echo "2) SSH Users > Active Sessions"
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

ssh_menu() {
  local -a items=(
    "1|Add User"
    "2|Delete User"
    "3|Set Expiry"
    "4|Reset Password"
    "5|List Users"
    "6|SSH WS Status"
    "7|Restart SSH WS"
    "8|Active Sessions"
    "0|Back"
  )
  while true; do
    ui_menu_screen_begin "2) SSH Users"
    ui_menu_render_options items 76
    hr
    if ! read -r -p "Pilih: " c; then
      echo
      break
    fi
    case "${c}" in
      1) menu_run_isolated_report "Add SSH User" ssh_add_user_menu ;;
      2) menu_run_isolated_report "Delete SSH User" ssh_delete_user_menu ;;
      3) menu_run_isolated_report "Set SSH Expiry" ssh_extend_expiry_menu ;;
      4) menu_run_isolated_report "Reset SSH Password" ssh_reset_password_menu ;;
      5) ssh_list_users_menu ;;
      6) sshws_status_menu ;;
      7) sshws_restart_menu ;;
      8) sshws_active_sessions_menu ;;
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
  local -A seen=()
  local f base username qf

  while IFS= read -r -d '' f; do
    base="$(basename "${f}")"
    base="${base%.json}"
    username="$(ssh_username_from_key "${base}")"
    [[ -n "${username}" ]] || continue
    if [[ -n "${seen["${username}"]+x}" ]]; then
      continue
    fi
    seen["${username}"]=1
    qf="$(ssh_user_state_resolve_file "${username}")"
    SSH_QAC_FILES+=("${qf}")
  done < <(find "${SSH_USERS_STATE_DIR}" -maxdepth 1 -type f -name '*.json' -print0 2>/dev/null | sort -z)

  while IFS= read -r -d '' f; do
    base="$(basename "${f}")"
    base="${base%.txt}"
    username="$(ssh_username_from_key "${base}")"
    [[ -n "${username}" ]] || continue
    if [[ -n "${seen["${username}"]+x}" ]]; then
      continue
    fi
    seen["${username}"]=1
    qf="$(ssh_user_state_resolve_file "${username}")"
    SSH_QAC_FILES+=("${qf}")
  done < <(find "${SSH_ACCOUNT_DIR}" -maxdepth 1 -type f -name '*.txt' -print0 2>/dev/null | sort -z)

  while IFS= read -r -d '' f; do
    base="$(basename "${f}")"
    username="${base%.pass}"
    [[ -n "${username}" ]] || continue
    if [[ -n "${seen["${username}"]+x}" ]]; then
      continue
    fi
    seen["${username}"]=1
    qf="$(ssh_user_state_resolve_file "${username}")"
    SSH_QAC_FILES+=("${qf}")
  done < <(find "${ZIVPN_PASSWORDS_DIR}" -maxdepth 1 -type f -name '*.pass' -print0 2>/dev/null | sort -z)

  while IFS= read -r username; do
    [[ -n "${username}" ]] || continue
    if [[ -n "${seen["${username}"]+x}" ]]; then
      continue
    fi
    seen["${username}"]=1
    qf="$(ssh_user_state_resolve_file "${username}")"
    SSH_QAC_FILES+=("${qf}")
  done < <(ssh_linux_candidate_users_get 2>/dev/null || true)
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

st = payload["status"]

if action == "set_quota_limit":
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
else:
  raise SystemExit(f"aksi ssh_qac_atomic_update_file tidak dikenali: {action}")

payload["status"] = st
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
  [[ -n "${src}" && -n "${dst}" ]] || return 1
  mkdir -p "$(dirname "${dst}")" 2>/dev/null || true
  cp -f -- "${src}" "${dst}" || return 1
  chmod 600 "${dst}" 2>/dev/null || true
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
    echo "Bootstrap akan membuat state awal dengan nilai konservatif:"
    echo "  - quota used = 0"
    echo "  - created_at = hari ini"
    echo "  - expired_at = hasil baca akun Linux bila tersedia, selain itu '-'"
    hr
    if ! confirm_menu_apply_now "Buat metadata SSH QAC awal untuk '${username_hint}' sekarang?"; then
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
