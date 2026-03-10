# shellcheck shell=bash
# Traffic Analytics
# - Sumber data: metadata quota /opt/quota/{vless,vmess,trojan,shadowsocks,shadowsocks2022}/*.json
# - Menggunakan quota_used sebagai dasar traffic usage.
# -------------------------
traffic_analytics_dataset_build_to_file() {
  # args: output_json_file
  local out_file="$1"
  need_python3
  python3 - <<'PY' "${QUOTA_ROOT}" "${out_file}" "${QUOTA_PROTO_DIRS[@]}"
import json
import os
import sys
from datetime import datetime, timezone

quota_root = sys.argv[1]
out_file = sys.argv[2]
protos = [p.strip() for p in sys.argv[3:] if p.strip()]

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
  pdir = os.path.join(quota_root, proto)
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
  echo "11) Traffic > Overview"
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
for proto in ("vless", "vmess", "trojan", "shadowsocks", "shadowsocks2022"):
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
  echo "11) Traffic > Top Users by Usage"
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
  echo "11) Traffic > Search User Traffic"
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
  echo "11) Traffic > Export JSON"
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
  while true; do
    title
    echo "11) Traffic"
    hr
    echo "  1) Overview"
    echo "  2) Top Users"
    echo "  3) Search User"
    echo "  4) Export JSON"
    echo "  0) Back"
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
  local edge_svc=""
  if svc_exists sshws-stunnel && svc_is_active sshws-stunnel; then
    systemctl restart sshws-stunnel >/dev/null 2>&1 || return 1
    svc_is_active sshws-stunnel || return 1
  fi
  if edge_runtime_enabled_for_public_ports; then
    edge_svc="$(edge_runtime_service_name 2>/dev/null || true)"
    if [[ -n "${edge_svc}" && "${edge_svc}" != "nginx" ]] && svc_exists "${edge_svc}" && svc_is_active "${edge_svc}"; then
      systemctl restart "${edge_svc}" >/dev/null 2>&1 || return 1
      svc_is_active "${edge_svc}" || return 1
    fi
  fi
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
  echo "Menjalankan acme.sh renew..."
  echo

  local renew_ok="false"
  local port80_conflict="false"
  local renew_log
  renew_log="$(mktemp)"

  if "${acme}" --cron --force 2>&1 | tee "${renew_log}"; then
    renew_ok="true"
  else
    if grep -Eqi "port 80 is already used|Please stop it first" "${renew_log}"; then
      port80_conflict="true"
    fi
  fi
  rm -f "${renew_log}" >/dev/null 2>&1 || true

  if [[ "${renew_ok}" != "true" ]]; then
    if [[ "${port80_conflict}" == "true" ]]; then
      warn "Terdeteksi konflik port 80. Menghentikan web service sementara untuk retry renew..."
      local -a stopped_services=()
      local svc edge_svc=""
      for svc in nginx apache2 caddy lighttpd; do
        if svc_exists "${svc}" && svc_is_active "${svc}"; then
          stopped_services+=("${svc}")
          systemctl stop "${svc}" >/dev/null 2>&1 || true
        fi
      done
      if edge_runtime_enabled_for_public_ports; then
        edge_svc="$(edge_runtime_service_name 2>/dev/null || true)"
        if [[ -n "${edge_svc}" && "${edge_svc}" != "nginx" ]] && svc_exists "${edge_svc}" && svc_is_active "${edge_svc}"; then
          stopped_services+=("${edge_svc}")
          systemctl stop "${edge_svc}" >/dev/null 2>&1 || true
        fi
      fi

      if "${acme}" --renew -d "${domain}" --force 2>&1; then
        renew_ok="true"
      fi

      for svc in "${stopped_services[@]}"; do
        if svc_exists "${svc}"; then
          systemctl start "${svc}" >/dev/null 2>&1 || warn "Gagal restore service: ${svc}"
        fi
      done
    else
      warn "acme.sh --cron --force gagal, mencoba renew domain spesifik..."
      if "${acme}" --renew -d "${domain}" --force 2>&1; then
        renew_ok="true"
      fi
    fi
  fi

  if [[ "${renew_ok}" != "true" ]]; then
    warn "Renew gagal. Cek output di atas."
    hr
    pause
    return 0
  fi

  echo
  if ! cert_runtime_restart_active_tls_consumers; then
    warn "Cert berhasil diperbarui, tetapi restart consumer TLS tambahan gagal. Cek sshws-stunnel / edge runtime."
  fi
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

  if systemctl reload nginx 2>/dev/null; then
    log "nginx reload: OK"
  else
    warn "nginx reload gagal, mencoba restart..."
    systemctl restart nginx 2>/dev/null || true
    if svc_is_active nginx; then
      log "nginx restart: OK"
    else
      warn "nginx masih tidak aktif"
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
  if [[ -z "${ip}" ]]; then
    warn "IP kosong"
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

fail2ban_menu_restart() {
  title
  echo "Fail2ban > Restart"
  hr
  if ! svc_exists fail2ban; then
    warn "fail2ban.service tidak terdeteksi"
    hr
    pause
    return 0
  fi

  systemctl restart fail2ban 2>/dev/null || true
  if svc_is_active fail2ban; then
    log "fail2ban: active"
  else
    warn "fail2ban: inactive"
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
  pause
}

fail2ban_menu() {
  while true; do
    title
    echo "9) Security"
    hr
    echo "  1) TLS & Cert"
    echo "  2) Fail2ban"
    echo "  3) Hardening"
    echo "  4) Overview"
    echo "  0) Back"
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
  echo "10) Maintenance > WARP Status"
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
  echo "10) Maintenance > Restart WARP"
  hr

  if ! svc_exists wireproxy; then
    warn "wireproxy.service tidak ditemukan."
    hr
    pause
    return 0
  fi

  svc_restart wireproxy
  hr
  pause
}

edge_runtime_env_file() {
  printf '%s\n' "/etc/default/edge-runtime"
}

badvpn_runtime_env_file() {
  printf '%s\n' "/etc/default/badvpn-udpgw"
}

openvpn_runtime_env_file() {
  printf '%s\n' "/etc/default/openvpn-runtime"
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

openvpn_runtime_get_env() {
  local key="$1"
  local env_file
  env_file="$(openvpn_runtime_env_file)"
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

edge_runtime_metrics_enabled() {
  local value
  value="$(edge_runtime_get_env EDGE_METRICS_ENABLED 2>/dev/null || true)"
  value="${value:-true}"
  case "${value,,}" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

edge_runtime_metrics_listen() {
  local value
  value="$(edge_runtime_get_env EDGE_METRICS_LISTEN 2>/dev/null || true)"
  printf '%s\n' "${value:-127.0.0.1:9910}"
}

edge_runtime_metrics_url() {
  local listen path host port
  path="${1:-/metrics}"
  listen="$(edge_runtime_metrics_listen)"
  if [[ "${listen}" == *:* ]]; then
    host="${listen%:*}"
    port="${listen##*:}"
    if [[ "${host}" == *:* && "${host}" != \[*\] ]]; then
      listen="[${host}]:${port}"
    fi
  fi
  printf 'http://%s%s\n' "${listen}" "${path}"
}

edge_runtime_metrics_fetch() {
  local path="${1:-/metrics}"
  have_cmd curl || return 1
  curl -fsS --max-time 2 "$(edge_runtime_metrics_url "${path}")" 2>/dev/null
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

edge_runtime_status_menu() {
  title
  echo "10) Maintenance > Edge Gateway Status"
  hr

  local svc env_file provider active http_port tls_port http_backend http_tls_backend ssh_backend ssh_tls_backend detect_timeout tls80 tls_backend_required
  local metrics_enabled metrics_listen health_text status_json metrics_text runtime_ok runtime_active runtime_reload runtime_last_reload runtime_listener_http runtime_listener_tls runtime_listener_metrics runtime_proxy_proto
  local runtime_tls_subject runtime_tls_not_after runtime_tls_alpn runtime_last_route
  local metric_accept_http metric_accept_tls metric_rejected_total
  svc="$(edge_runtime_service_name)"
  env_file="$(edge_runtime_env_file)"
  provider="$(edge_runtime_get_env EDGE_PROVIDER 2>/dev/null || echo "none")"
  active="$(edge_runtime_get_env EDGE_ACTIVATE_RUNTIME 2>/dev/null || echo "false")"
  http_port="$(edge_runtime_get_env EDGE_PUBLIC_HTTP_PORT 2>/dev/null || echo "80")"
  tls_port="$(edge_runtime_get_env EDGE_PUBLIC_TLS_PORT 2>/dev/null || echo "443")"
  metrics_listen="$(edge_runtime_metrics_listen)"
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
  if edge_runtime_metrics_enabled; then
    metrics_enabled="true"
  else
    metrics_enabled="false"
  fi

  echo "Runtime env : ${env_file}"
  echo "Provider    : ${provider}"
  echo "Activate    : ${active}"
  echo "HTTP port   : ${http_port}"
  echo "TLS port    : ${tls_port}"
  echo "Metrics     : ${metrics_enabled} (${metrics_listen})"
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

  if [[ "${metrics_enabled}" == "true" ]]; then
    hr
    echo "Runtime observability:"
    if health_text="$(edge_runtime_metrics_fetch /health | tr -d '\r' | head -n1)"; then
      log "Health ${metrics_listen} : ${health_text} ✅"
    else
      warn "Health ${metrics_listen} : unavailable ❌"
    fi

    if status_json="$(edge_runtime_metrics_fetch /status)"; then
      if have_cmd python3; then
        local parsed
        parsed="$(
          python3 - "${status_json}" <<'PY' 2>/dev/null || true
import json
import sys
from datetime import datetime

try:
    data = json.loads(sys.argv[1])
except Exception:
    raise SystemExit(0)

def out(key, value):
    print(f"{key}={value}")

listeners = data.get("listener_up") or {}
last_reload = "-"
try:
    ts = int(data.get("last_reload_unix") or 0)
    if ts > 0:
        last_reload = datetime.fromtimestamp(ts).strftime("%Y-%m-%d %H:%M:%S")
except Exception:
    pass

out("ok", "true" if data.get("ok") else "false")
out("active", int(data.get("active_connections_total") or 0))
out("reload_success", int(data.get("reload_success") or 0))
out("last_reload", last_reload)
out("listener_http", "up" if listeners.get("http") else "down")
out("listener_tls", "up" if listeners.get("tls") else "down")
out("listener_metrics", "up" if listeners.get("metrics") else "down")
out("accept_proxy_protocol", "true" if data.get("accept_proxy_protocol") else "false")
out("tls_subject", str(data.get("tls_certificate_subject") or "-"))
out("tls_not_after", str(data.get("tls_certificate_not_after") or "-"))
out("tls_alpn", ",".join(data.get("tls_advertised_alpn") or []) or "-")
last_route = data.get("last_route") or {}
if last_route:
    out(
        "last_route",
        f"{last_route.get('surface') or '-'} | {last_route.get('route') or '-'} | {last_route.get('backend') or '-'} | "
        f"host={last_route.get('host') or '-'} path={last_route.get('path') or '-'} alpn={last_route.get('alpn') or '-'} sni={last_route.get('sni') or '-'}"
    )
else:
    out("last_route", "-")
PY
        )"
        runtime_ok="-"
        runtime_active="-"
        runtime_reload="-"
        runtime_last_reload="-"
        runtime_listener_http="-"
        runtime_listener_tls="-"
        runtime_listener_metrics="-"
        runtime_proxy_proto="-"
        runtime_tls_subject="-"
        runtime_tls_not_after="-"
        runtime_tls_alpn="-"
        runtime_last_route="-"
        while IFS='=' read -r key value; do
          case "${key}" in
            ok) runtime_ok="${value}" ;;
            active) runtime_active="${value}" ;;
            reload_success) runtime_reload="${value}" ;;
            last_reload) runtime_last_reload="${value}" ;;
            listener_http) runtime_listener_http="${value}" ;;
            listener_tls) runtime_listener_tls="${value}" ;;
            listener_metrics) runtime_listener_metrics="${value}" ;;
            accept_proxy_protocol) runtime_proxy_proto="${value}" ;;
            tls_subject) runtime_tls_subject="${value}" ;;
            tls_not_after) runtime_tls_not_after="${value}" ;;
            tls_alpn) runtime_tls_alpn="${value}" ;;
            last_route) runtime_last_route="${value}" ;;
          esac
        done <<< "${parsed}"

        echo "Runtime OK  : ${runtime_ok}"
        echo "Active conn : ${runtime_active}"
        echo "Reload ok   : ${runtime_reload}"
        echo "Last reload : ${runtime_last_reload}"
        echo "Proxy proto : ${runtime_proxy_proto}"
        echo "TLS cert    : ${runtime_tls_subject}"
        echo "TLS expire  : ${runtime_tls_not_after}"
        echo "ALPN        : ${runtime_tls_alpn}"
        echo "Listeners   : http=${runtime_listener_http} tls=${runtime_listener_tls} metrics=${runtime_listener_metrics}"
        echo "Last route  : ${runtime_last_route}"
      else
        warn "python3 tidak tersedia, skip parsing /status edge"
      fi
    else
      warn "Status ${metrics_listen} : unavailable ❌"
    fi

    if metrics_text="$(edge_runtime_metrics_fetch /metrics)"; then
      metric_accept_http="$(printf '%s\n' "${metrics_text}" | awk '$1 ~ /^edge_mux_connections_accepted_total\{surface="http-port"\}$/ {print $2; exit}')"
      metric_accept_tls="$(printf '%s\n' "${metrics_text}" | awk '$1 ~ /^edge_mux_connections_accepted_total\{surface="tls-port"\}$/ {print $2; exit}')"
      metric_rejected_total="$(printf '%s\n' "${metrics_text}" | awk '$1 ~ /^edge_mux_connections_rejected_total\{/ {sum+=$2} END{print sum+0}')"
      echo "Accepted    : http=${metric_accept_http:-0} tls=${metric_accept_tls:-0}"
      echo "Rejected    : ${metric_rejected_total:-0}"
    else
      warn "Metrics ${metrics_listen} : unavailable ❌"
    fi
  else
    hr
    echo "Runtime observability:"
    echo "Metrics     : disabled"
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
  pause
}

edge_runtime_restart_menu() {
  title
  echo "10) Maintenance > Restart Edge Gateway"
  hr

  local svc
  svc="$(edge_runtime_service_name)"
  if ! svc_exists "${svc}"; then
    warn "${svc} tidak terpasang."
    hr
    pause
    return 0
  fi

  svc_restart "${svc}"
  hr
  pause
}

edge_runtime_info_menu() {
  title
  echo "10) Maintenance > Edge Gateway Info"
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
  echo "10) Maintenance > BadVPN UDPGW Status"
  hr

  local env_file port max_clients max_conn sndbuf svc
  svc="badvpn-udpgw.service"
  env_file="$(badvpn_runtime_env_file)"
  port="$(badvpn_runtime_get_env BADVPN_UDPGW_PORT 2>/dev/null || echo "7300")"
  max_clients="$(badvpn_runtime_get_env BADVPN_UDPGW_MAX_CLIENTS 2>/dev/null || echo "512")"
  max_conn="$(badvpn_runtime_get_env BADVPN_UDPGW_MAX_CONNECTIONS_FOR_CLIENT 2>/dev/null || echo "8")"
  sndbuf="$(badvpn_runtime_get_env BADVPN_UDPGW_BUFFER_SIZE 2>/dev/null || echo "1048576")"

  echo "Runtime env : ${env_file}"
  echo "Listen port : 127.0.0.1:${port}"
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
    if ss -lntH 2>/dev/null | grep -Eq "(^|[[:space:]])127\\.0\\.0\\.1:${port}([[:space:]]|$)"; then
      log "UDPGW 127.0.0.1:${port} : LISTENING ✅"
    else
      warn "UDPGW 127.0.0.1:${port} : NOT listening ❌"
    fi
  else
    warn "ss tidak tersedia, skip cek port TCP UDPGW"
  fi

  hr
  pause
}

badvpn_restart_menu() {
  title
  echo "10) Maintenance > Restart BadVPN UDPGW"
  hr

  local svc
  svc="badvpn-udpgw.service"
  if ! svc_exists "${svc}"; then
    warn "${svc} tidak ditemukan."
    hr
    pause
    return 0
  fi

  svc_restart "${svc}"
  hr
  pause
}

openvpn_value_is_true() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

openvpn_clients_dir_value() {
  openvpn_runtime_get_env OVPN_CLIENTS_DIR 2>/dev/null || echo "/etc/openvpn/clients"
}

openvpn_downloads_dir_value() {
  openvpn_runtime_get_env OVPN_DOWNLOADS_DIR 2>/dev/null || echo "/var/lib/openvpn/downloads"
}

openvpn_default_client_name_value() {
  openvpn_runtime_get_env OVPN_DEFAULT_CLIENT_NAME 2>/dev/null || echo "autoscript"
}

openvpnws_token_valid() {
  local token="${1:-}"
  [[ "${token}" =~ ^[A-Fa-f0-9]{10}$ ]]
}

openvpn_download_token_valid() {
  local token="${1:-}"
  [[ "${token}" =~ ^[A-Fa-f0-9]{16}$ ]]
}

openvpn_client_state_path_value() {
  local name="${1:-}"
  printf '%s/%s.json\n' "$(openvpn_clients_dir_value)" "${name}"
}

openvpn_client_state_token_get() {
  local name="${1:-}"
  local state_file
  state_file="$(openvpn_client_state_path_value "${name}")"
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
    token = str(data.get("ovpnws_token") or "").strip()
except Exception:
  token = ""

if re.fullmatch(r"[A-Fa-f0-9]{10}", token):
  print(token.lower())
else:
  print("")
PY
}

openvpn_client_state_download_token_get() {
  local name="${1:-}"
  local state_file
  state_file="$(openvpn_client_state_path_value "${name}")"
  [[ -s "${state_file}" ]] || {
    echo ""
    return 0
  }
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
    token = str(data.get("download_token") or "").strip()
except Exception:
  token = ""

if re.fullmatch(r"[A-Fa-f0-9]{16}", token):
  print(token.lower())
else:
  print("")
PY
}

openvpn_runtime_ws_prefix_value() {
  local path
  path="$(openvpn_runtime_get_env OVPNWS_PATH 2>/dev/null || echo "/")"
  path="${path%%\?*}"
  path="${path%%\#*}"
  path="/${path#/}"
  path="${path%/}"
  [[ -n "${path}" ]] || path="/"
  if [[ "${path}" == "/openvpn-ws" ]]; then
    path="/"
  fi
  printf '%s\n' "${path}"
}

openvpnws_path_from_token() {
  local token="${1:-}"
  local prefix
  openvpnws_token_valid "${token}" || return 1
  prefix="$(openvpn_runtime_ws_prefix_value)"
  if [[ "${prefix}" == "/" ]]; then
    printf '/%s\n' "${token,,}"
  else
    printf '%s/%s\n' "${prefix}" "${token,,}"
  fi
}

openvpnws_alt_path_from_token() {
  local token="${1:-}"
  local prefix
  openvpnws_token_valid "${token}" || return 1
  prefix="$(openvpn_runtime_ws_prefix_value)"
  if [[ "${prefix}" == "/" ]]; then
    printf '/bebas/%s\n' "${token,,}"
  else
    printf '%s/bebas/%s\n' "${prefix}" "${token,,}"
  fi
}

openvpn_download_path_from_token() {
  local token="${1:-}"
  openvpn_download_token_valid "${token}" || return 1
  printf '/ovpn/%s.zip\n' "${token,,}"
}

openvpn_bundle_path_value() {
  local name="${1:-}"
  [[ "${name}" =~ ^[a-z0-9][a-z0-9._-]{0,31}$ ]] || return 1
  printf '%s/%s.zip\n' "$(openvpn_downloads_dir_value)" "${name}"
}

openvpn_bundle_url_value() {
  local name="${1:-}"
  local host
  [[ "${name}" =~ ^[a-z0-9][a-z0-9._-]{0,31}$ ]] || return 1
  host="$(detect_domain)"
  [[ -n "${host}" ]] || host="$(detect_public_ip_ipapi)"
  [[ -n "${host}" ]] || return 1
  printf 'https://%s/ovpn/%s.zip\n' "${host}" "${name}"
}

openvpn_demo_profile_path() {
  local dir name
  dir="$(openvpn_clients_dir_value)"
  name="$(openvpn_default_client_name_value)"
  printf '%s\n' "${dir}/${name}-tcp.ovpn"
}

openvpn_demo_ssl_profile_path() {
  local dir name
  dir="$(openvpn_clients_dir_value)"
  name="$(openvpn_default_client_name_value)"
  printf '%s\n' "${dir}/${name}-ssl.ovpn"
}

openvpn_demo_ws_profile_path() {
  local dir name
  dir="$(openvpn_clients_dir_value)"
  name="$(openvpn_default_client_name_value)"
  printf '%s\n' "${dir}/${name}-ws.ovpn"
}

openvpn_demo_ssl_run_path() {
  local dir name
  dir="$(openvpn_clients_dir_value)"
  name="$(openvpn_default_client_name_value)"
  printf '%s\n' "${dir}/${name}-ssl-run.sh"
}

openvpn_demo_tcp_run_path() {
  local dir name
  dir="$(openvpn_clients_dir_value)"
  name="$(openvpn_default_client_name_value)"
  printf '%s\n' "${dir}/${name}-tcp-run.sh"
}

openvpn_demo_ws_run_path() {
  local dir name
  dir="$(openvpn_clients_dir_value)"
  name="$(openvpn_default_client_name_value)"
  printf '%s\n' "${dir}/${name}-ws-run.sh"
}

openvpn_status_menu() {
  local breadcrumb="${1:-OpenVPN Status}"
  title
  echo "${breadcrumb}"
  hr

  local env_file core_svc ws_svc speed_svc tcp_enabled ssl_enabled ws_enabled
  local tcp_bind tcp_port ws_bind ws_port ws_path clients_dir downloads_dir speed_state_file default_profile default_ssl_profile default_ws_profile default_name default_token default_download_url default_download_file default_ws_path default_ws_alt_path client_count runtime_ready runtime_reason default_visible core_service_ok ws_service_required ws_service_ok
  env_file="$(openvpn_runtime_env_file)"
  core_svc="ovpn-tcp.service"
  ws_svc="ovpnws-proxy.service"
  speed_svc="openvpn-speed.service"
  tcp_enabled="$(openvpn_runtime_get_env OVPN_ENABLE_TCP 2>/dev/null || echo "false")"
  ssl_enabled="$(openvpn_runtime_get_env OVPN_ENABLE_SSL 2>/dev/null || echo "false")"
  ws_enabled="$(openvpn_runtime_get_env OVPN_ENABLE_WS 2>/dev/null || echo "false")"
  tcp_bind="$(openvpn_runtime_get_env OVPN_TCP_BIND 2>/dev/null || echo "127.0.0.1")"
  tcp_port="$(openvpn_runtime_get_env OVPN_TCP_PORT 2>/dev/null || echo "21194")"
  ws_bind="$(openvpn_runtime_get_env OVPNWS_PROXY_BIND 2>/dev/null || echo "127.0.0.1")"
  ws_port="$(openvpn_runtime_get_env OVPNWS_PROXY_PORT 2>/dev/null || echo "21195")"
  ws_path="$(openvpn_runtime_ws_prefix_value)"
  clients_dir="$(openvpn_clients_dir_value)"
  downloads_dir="$(openvpn_downloads_dir_value)"
  speed_state_file="$(openvpn_speed_state_file_manage)"
  default_name="$(openvpn_default_client_name_value)"
  default_profile="$(openvpn_demo_profile_path)"
  default_ssl_profile="$(openvpn_demo_ssl_profile_path)"
  default_ws_profile="$(openvpn_demo_ws_profile_path)"
  default_token="-"
  default_download_url="-"
  default_download_file="-"
  default_ws_path="-"
  default_ws_alt_path="-"
  client_count="$(openvpn_client_count_value 2>/dev/null || echo "0")"
  runtime_ready="false"
  runtime_reason="$(openvpn_manage_ready_reason 2>/dev/null || true)"
  if [[ -z "${runtime_reason}" ]]; then
    runtime_ready="true"
  fi
  core_service_ok="false"
  ws_service_required="false"
  ws_service_ok="false"
  if svc_exists "${core_svc}" && svc_is_active "${core_svc}"; then
    core_service_ok="true"
  fi
  if openvpn_value_is_true "${ws_enabled}"; then
    ws_service_required="true"
  fi
  if svc_exists "${ws_svc}" && svc_is_active "${ws_svc}"; then
    ws_service_ok="true"
  fi
  if [[ "${runtime_ready}" == "true" && "${core_service_ok}" != "true" ]]; then
    runtime_ready="false"
    runtime_reason="${core_svc} inactive."
  fi
  if [[ "${runtime_ready}" == "true" && "${ws_service_required}" == "true" && "${ws_service_ok}" != "true" ]]; then
    runtime_ready="false"
    if svc_exists "${ws_svc}"; then
      runtime_reason="${ws_svc} inactive."
    else
      runtime_reason="${ws_svc} belum terpasang."
    fi
  fi
  default_visible="false"
  if openvpn_client_state_exists "${default_name}" \
    || [[ -f "${default_profile}" || -f "${default_ssl_profile}" || -f "${default_ws_profile}" ]]; then
    default_visible="true"
  fi
  if [[ "${default_visible}" == "true" ]]; then
    default_token="$(openvpn_client_state_token_get "${default_name}")"
    default_download_file="$(openvpn_bundle_path_value "${default_name}" 2>/dev/null || true)"
    if [[ -f "${default_download_file}" ]]; then
      default_download_url="$(openvpn_bundle_url_value "${default_name}" 2>/dev/null || true)"
    else
      default_download_file="-"
      default_download_url="-"
    fi
  else
    default_name="-"
    default_profile="-"
    default_ssl_profile="-"
    default_ws_profile="-"
  fi
  if openvpnws_token_valid "${default_token}"; then
    default_ws_path="$(openvpnws_path_from_token "${default_token}" 2>/dev/null || true)"
    default_ws_alt_path="$(openvpnws_alt_path_from_token "${default_token}" 2>/dev/null || true)"
    if [[ "${default_ws_alt_path}" == /bebas/* ]]; then
      default_ws_alt_path="/<bebas>/${default_token}"
    fi
  fi

  echo "Runtime env : ${env_file}"
  echo "Runtime OK  : ${runtime_ready}"
  if [[ -n "${runtime_reason}" ]]; then
    echo "Runtime Why : ${runtime_reason}"
  fi
  echo "Modes       : TCP=${tcp_enabled} | SSL/TLS=${ssl_enabled} | WS=${ws_enabled}"
  echo "Core b/e    : ${tcp_bind}:${tcp_port}"
  echo "WS proxy    : ${ws_bind}:${ws_port}"
  echo "WS prefix   : ${ws_path}"
  echo "Clients dir : ${clients_dir}"
  echo "ZIP dir     : ${downloads_dir}"
  echo "Speed state : ${speed_state_file}"
  echo "Managed     : ${client_count} client(s)"
  if [[ "${runtime_ready}" == "true" ]]; then
    echo "Default     : ${default_name}"
    echo "WS Token    : ${default_token:-"-"}"
    echo "ZIP URL     : ${default_download_url:-"-"}"
    echo "WS Path     : ${default_ws_path}"
    echo "WS Path Alt : ${default_ws_alt_path}"
    echo "TCP File    : ${default_profile}"
    echo "SSL File    : ${default_ssl_profile}"
    echo "WS File     : ${default_ws_profile}"
    echo "ZIP File    : ${default_download_file:-"-"}"
  else
    echo "Default     : -"
    echo "WS Token    : -"
    echo "ZIP URL     : -"
    echo "WS Path     : -"
    echo "WS Path Alt : -"
    echo "TCP File    : -"
    echo "SSL File    : -"
    echo "WS File     : -"
    echo "ZIP File    : -"
  fi
  hr

  if svc_exists "${core_svc}"; then
    svc_status_line "${core_svc}"
  else
    warn "${core_svc} tidak terpasang"
  fi

  if svc_exists "${ws_svc}"; then
    svc_status_line "${ws_svc}"
  elif openvpn_value_is_true "${ws_enabled}"; then
    warn "${ws_svc} belum terpasang padahal mode WS aktif"
  else
    log "${ws_svc} : disabled"
  fi

  if svc_exists "${speed_svc}"; then
    svc_status_line "${speed_svc}"
  else
    warn "${speed_svc} tidak terpasang"
  fi

  hr
  if have_cmd ss; then
    if ss -lntH 2>/dev/null | grep -Eq "(^|[[:space:]])${tcp_bind//./\\.}:${tcp_port}([[:space:]]|$)"; then
      log "OpenVPN core ${tcp_bind}:${tcp_port} : LISTENING ✅"
    else
      warn "OpenVPN core ${tcp_bind}:${tcp_port} : NOT listening ❌"
    fi
    if openvpn_value_is_true "${ws_enabled}"; then
      if ss -lntH 2>/dev/null | grep -Eq "(^|[[:space:]])${ws_bind//./\\.}:${ws_port}([[:space:]]|$)"; then
        log "OVPN WS proxy ${ws_bind}:${ws_port} : LISTENING ✅"
      else
        warn "OVPN WS proxy ${ws_bind}:${ws_port} : NOT listening ❌"
      fi
    fi
  else
    warn "ss tidak tersedia, skip cek port OpenVPN"
  fi

  hr
  if [[ "${runtime_ready}" != "true" ]]; then
    warn "Default client disembunyikan sampai runtime OpenVPN sehat."
  elif [[ -f "${default_profile}" ]]; then
    log "Default TCP file : ${default_profile}"
    [[ -f "${default_ssl_profile}" ]] && log "Default SSL file : ${default_ssl_profile}"
    [[ -f "${default_ws_profile}" ]] && log "Default WS file  : ${default_ws_profile}"
  else
    if [[ "${default_visible}" == "true" ]]; then
      warn "File default client belum tersedia: ${default_profile}"
    elif [[ -n "${runtime_reason}" ]]; then
      warn "Default client belum tersedia karena runtime OpenVPN belum siap."
    else
      warn "Default client belum tersedia."
    fi
  fi
  echo "Catatan     : file utama untuk injector adalah profile *.ovpn atau paket ZIP."
  echo "              ZIP memuat tiga profile: *-tcp.ovpn, *-ssl.ovpn, dan *-ws.ovpn."
  echo "              OVPN WS tetap memakai token path saat koneksi dijalankan."
  hr
  pause
}

openvpn_restart_core_menu() {
  local breadcrumb="${1:-OpenVPN > Restart Core}"
  title
  echo "${breadcrumb}"
  hr
  local svc="ovpn-tcp.service"
  if ! svc_exists "${svc}"; then
    warn "${svc} tidak ditemukan."
    hr
    pause
    return 0
  fi
  svc_restart "${svc}"
  hr
  pause
}

openvpn_restart_ws_menu() {
  local breadcrumb="${1:-OpenVPN > Restart WS Proxy}"
  title
  echo "${breadcrumb}"
  hr
  local svc="ovpnws-proxy.service"
  if ! svc_exists "${svc}"; then
    warn "${svc} tidak ditemukan."
    hr
    pause
    return 0
  fi
  svc_restart "${svc}"
  hr
  pause
}

openvpn_demo_files_show() {
  local breadcrumb="${1:-OpenVPN > Client Files}"
  title
  echo "${breadcrumb}"
  hr

  local clients_dir default_name
  clients_dir="$(openvpn_clients_dir_value)"
  default_name="$(openvpn_default_client_name_value)"
  echo "Clients dir : ${clients_dir}"
  hr

  if [[ ! -d "${clients_dir}" ]]; then
    warn "Direktori client OpenVPN belum tersedia."
    hr
    pause
    return 0
  fi

  local found="false" row="" name cn created expired token allowed remote tcp_file ssl_file ws_file download_url download_file main_path alt_path marker
  while IFS= read -r row; do
    [[ -n "${row}" ]] || continue
    found="true"
    IFS='|' read -r name cn created expired token allowed <<<"${row}"
    tcp_file="${clients_dir}/${name}-tcp.ovpn"
    ssl_file="${clients_dir}/${name}-ssl.ovpn"
    ws_file="${clients_dir}/${name}-ws.ovpn"
    download_url="$(openvpn_bundle_url_value "${name}" 2>/dev/null || true)"
    download_file="$(openvpn_bundle_path_value "${name}" 2>/dev/null || true)"
    remote="$(grep -E '^remote ' "${tcp_file}" 2>/dev/null | head -n1 || true)"
    main_path="-"
    alt_path="-"
    if openvpnws_token_valid "${token}"; then
      main_path="$(openvpnws_path_from_token "${token}" 2>/dev/null || true)"
      alt_path="$(openvpnws_alt_path_from_token "${token}" 2>/dev/null || true)"
      if [[ "${alt_path}" == /bebas/* ]]; then
        alt_path="/<bebas>/${token}"
      fi
    fi
    marker=""
    if [[ "${name}" == "${default_name}" ]]; then
      marker=" (default)"
    fi
    echo "Client   : ${name}${marker}"
    echo "CN       : ${cn}"
    echo "Created  : ${created}"
    echo "Expired  : ${expired}"
    echo "Access   : ${allowed}"
    [[ -n "${remote}" ]] && echo "Remote   : ${remote}"
    echo "ZIP URL  : ${download_url:-"-"}"
    echo "WS       : ${main_path} | alt ${alt_path}"
    [[ -f "${tcp_file}" ]] && echo "TCP OVPN : ${tcp_file}"
    [[ -f "${ssl_file}" ]] && echo "SSL OVPN : ${ssl_file}"
    [[ -f "${ws_file}" ]] && echo "WS OVPN  : ${ws_file}"
    [[ -f "${download_file}" ]] && echo "ZIP File : ${download_file}"
    echo
  done < <(openvpn_client_rows)

  if [[ "${found}" != "true" ]]; then
    warn "Belum ada client OpenVPN terkelola di ${clients_dir}"
  fi

  echo "Hint:"
  echo "  - Paket ZIP     : gunakan URL ZIP untuk membagikan semua profile sekaligus"
  echo "  - File utama untuk injector adalah profile *.ovpn"
  echo "  - TCP      : gunakan file *-tcp.ovpn"
  echo "  - SSL/TLS  : gunakan file *-ssl.ovpn"
  echo "  - WS       : gunakan file *-ws.ovpn"
  hr
  pause
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
  local breadcrumb="${1:-10) Maintenance > SSH WS Status}"
  title
  echo "${breadcrumb}"
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

sshws_restart_menu() {
  local breadcrumb="${1:-10) Maintenance > Restart SSH WS}"
  title
  echo "${breadcrumb}"
  hr

  local services=("${SSHWS_DROPBEAR_SERVICE}" "${SSHWS_STUNNEL_SERVICE}" "${SSHWS_PROXY_SERVICE}")
  local svc restarted="false"
  for svc in "${services[@]}"; do
    if svc_exists "${svc}"; then
      svc_restart "${svc}" || true
      restarted="true"
    else
      warn "${svc}.service tidak terpasang"
    fi
  done

  if [[ "${restarted}" != "true" ]]; then
    warn "Tidak ada service SSH WS yang bisa direstart."
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

sshws_combined_logs_menu() {
  title
  echo "10) Maintenance > SSH WS Combined Logs"
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
    echo "10) Maintenance > SSH WS Diagnostics"
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

  local qf accf
  qf="$(ssh_user_state_file "${username}")"
  accf="$(ssh_account_info_file "${username}")"

  # Cegah duplikat terhadap metadata managed unified.
  if [[ -f "${qf}" || -f "${accf}" ]]; then
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
  mkdir -p "${SSH_USERS_STATE_DIR}" "${SSH_ACCOUNT_DIR}"
  chmod 700 "${SSH_USERS_STATE_DIR}" "${SSH_ACCOUNT_DIR}" || true

  find "${QUOTA_ROOT}/ssh" -maxdepth 1 -type f \( -name '*.json' -o -name '*.json.lock' \) -delete 2>/dev/null || true
  find "/var/lib/xray-manage/ssh-users" -maxdepth 1 -type f -name '*.json' -delete 2>/dev/null || true
  find "${SSH_ACCOUNT_DIR}" -maxdepth 1 -type f -name '*.txt' ! -name '*@ssh.txt' -delete 2>/dev/null || true
}

ssh_user_state_file() {
  local username="${1:-}"
  ssh_ovpn_qac_state_path "${username}"
}

ssh_user_state_resolve_file() {
  local username="${1:-}"
  local primary
  primary="$(ssh_user_state_file "${username}")"
  printf '%s\n' "${primary}"
}

ssh_account_info_file() {
  local username="${1:-}"
  printf '%s/%s@ssh.txt\n' "${SSH_ACCOUNT_DIR}" "${username}"
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
    meta = data.get("meta") if isinstance(data.get("meta"), dict) else {}
    token = str(data.get("sshws_token") or meta.get("sshws_token") or "").strip()
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
  local state_file lock_file
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
    meta = loaded.get("meta") if isinstance(loaded.get("meta"), dict) else {}
    tok = str(loaded.get("sshws_token") or meta.get("sshws_token") or "").strip().lower()
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

meta = payload.get("meta") if isinstance(payload.get("meta"), dict) else {}
current_token = payload.get("sshws_token") or meta.get("sshws_token")
token = pick_unique_token(os.path.dirname(path) or ".", path, current_token)
if token != str(current_token or "").strip().lower():
  payload["sshws_token"] = token
  meta["sshws_token"] = token
  payload["meta"] = meta
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
    meta = loaded.get("meta") if isinstance(loaded.get("meta"), dict) else {}
    tok = str(loaded.get("sshws_token") or meta.get("sshws_token") or "").strip().lower()
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

meta = payload.get("meta") if isinstance(payload.get("meta"), dict) else {}
current_token = payload.get("sshws_token") or meta.get("sshws_token")
token = pick_unique_token(os.path.dirname(path) or ".", path, current_token)
if token != str(current_token or "").strip().lower():
  payload["sshws_token"] = token
  meta["sshws_token"] = token
  payload["meta"] = meta
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
    meta = payload.get("meta") if isinstance(payload.get("meta"), dict) else {}
    candidate = str(payload.get("sshws_token") or meta.get("sshws_token") or "").strip().lower()
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
  meta = d.get("meta") if isinstance(d.get("meta"), dict) else {}
  print(str(d.get("created_at") or meta.get("created_at") or "").strip())
except Exception:
  print("")
PY
}

ssh_user_state_expired_at_get() {
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
  policy = d.get("policy") if isinstance(d.get("policy"), dict) else {}
  print(str(d.get("expired_at") or policy.get("expired_at") or "").strip()[:10])
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
import time

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

def to_bool(v, default=False):
  if isinstance(v, bool):
    return v
  if isinstance(v, (int, float)):
    return bool(v)
  s = str(v or "").strip().lower()
  if not s:
    return bool(default)
  return s in ("1", "true", "yes", "on", "y")

def norm_date(v):
  s = str(v or "").strip()
  if not s:
    return ""
  return s[:10]

def date_is_active(v):
  s = norm_date(v)
  if not s or s == "-":
    return True
  try:
    return datetime.datetime.strptime(s, "%Y-%m-%d").date() >= datetime.date.today()
  except Exception:
    return True

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
    meta = loaded.get("meta") if isinstance(loaded.get("meta"), dict) else {}
    tok = str(loaded.get("sshws_token") or meta.get("sshws_token") or "").strip().lower()
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

policy = payload.get("policy") if isinstance(payload.get("policy"), dict) else {}
runtime = payload.get("runtime") if isinstance(payload.get("runtime"), dict) else {}
derived = payload.get("derived") if isinstance(payload.get("derived"), dict) else {}
meta = payload.get("meta") if isinstance(payload.get("meta"), dict) else {}
status_raw = payload.get("status")
status = status_raw if isinstance(status_raw, dict) else {}

created = str(created_at or "").strip() or str(payload.get("created_at") or meta.get("created_at") or "").strip()
if created:
  created = created[:10]
if not created:
  created = datetime.datetime.utcnow().strftime("%Y-%m-%d")

expired = norm_date(expired_at) or norm_date(policy.get("expired_at")) or norm_date(payload.get("expired_at")) or "-"
current_token = payload.get("sshws_token") or meta.get("sshws_token")
token = pick_unique_token(os.path.dirname(state_file) or ".", state_file, current_token)

legacy_quota_limit = max(0, to_int(policy.get("quota_limit_ssh_bytes"), to_int(policy.get("quota_limit_bytes"), to_int(payload.get("quota_limit"), 0))))
quota_limit_ssh = legacy_quota_limit
quota_limit_ovpn = max(0, to_int(policy.get("quota_limit_ovpn_bytes"), to_int(policy.get("quota_limit_bytes"), legacy_quota_limit)))
quota_unit = str(policy.get("quota_unit") or payload.get("quota_unit") or "binary").strip().lower()
if quota_unit not in ("binary", "decimal"):
  quota_unit = "binary"
quota_used_ssh = max(0, to_int(runtime.get("quota_used_ssh_bytes"), to_int(payload.get("quota_used"), 0)))
quota_used_ovpn = max(0, to_int(runtime.get("quota_used_ovpn_bytes"), 0))
active_session_ssh = max(0, to_int(runtime.get("active_session_ssh"), 0))
active_session_ovpn = max(0, to_int(runtime.get("active_session_ovpn"), 0))
last_seen_ssh = max(0, to_int(runtime.get("last_seen_ssh_unix"), 0))
last_seen_ovpn = max(0, to_int(runtime.get("last_seen_ovpn_unix"), 0))

ip_limit_enabled = to_bool(policy.get("ip_limit_enabled"), status.get("ip_limit_enabled"))
ip_limit = max(0, to_int(policy.get("ip_limit"), to_int(status.get("ip_limit"), 0)))
speed_limit_enabled = to_bool(policy.get("speed_limit_enabled"), status.get("speed_limit_enabled"))
speed_down = max(0.0, to_float(policy.get("speed_down_mbit"), to_float(status.get("speed_down_mbit"), 0.0)))
speed_up = max(0.0, to_float(policy.get("speed_up_mbit"), to_float(status.get("speed_up_mbit"), 0.0)))
manual_block = to_bool(status.get("manual_block"))
access_enabled = to_bool(policy.get("access_enabled"), True)

quota_used_total = quota_used_ssh + quota_used_ovpn
active_session_total = active_session_ssh + active_session_ovpn
quota_exhausted_ssh = bool(quota_limit_ssh > 0 and quota_used_ssh >= quota_limit_ssh)
quota_exhausted_ovpn = bool(quota_limit_ovpn > 0 and quota_used_ovpn >= quota_limit_ovpn)
ip_limit_locked = bool(ip_limit_enabled and ip_limit > 0 and active_session_total > ip_limit)
shared_access = bool(access_enabled and date_is_active(expired) and not ip_limit_locked and not manual_block)

if manual_block:
  last_reason_ssh = "manual"
  last_reason_ovpn = "manual"
elif not access_enabled:
  last_reason_ssh = "access_off"
  last_reason_ovpn = "access_off"
elif not date_is_active(expired):
  last_reason_ssh = "expired"
  last_reason_ovpn = "expired"
elif ip_limit_locked:
  last_reason_ssh = "ip_limit"
  last_reason_ovpn = "ip_limit"
else:
  last_reason_ssh = "quota_ssh" if quota_exhausted_ssh else "-"
  last_reason_ovpn = "quota_ovpn" if quota_exhausted_ovpn else "-"
if last_reason_ssh not in ("", "-"):
  last_reason = last_reason_ssh
elif last_reason_ovpn not in ("", "-"):
  last_reason = last_reason_ovpn
else:
  last_reason = "-"

meta["created_at"] = created
meta["updated_at_unix"] = int(time.time())
meta["ssh_present"] = True
meta["ovpn_present"] = bool(meta.get("ovpn_present"))
meta["sshws_token"] = token

payload = {
  "version": 1,
  "managed_by": "autoscript-manage",
  "protocol": "ssh-ovpn",
  "username": username,
  "created_at": created,
  "expired_at": expired,
  "sshws_token": token,
  "quota_limit": quota_limit_ssh,
  "quota_unit": quota_unit,
  "quota_used": quota_used_ssh,
  "status": {
    "manual_block": bool(manual_block),
    "quota_exhausted": bool(quota_exhausted_ssh),
    "ip_limit_enabled": bool(ip_limit_enabled),
    "ip_limit": ip_limit,
    "ip_limit_locked": bool(ip_limit_locked),
    "speed_limit_enabled": bool(speed_limit_enabled),
    "speed_down_mbit": speed_down,
    "speed_up_mbit": speed_up,
    "lock_reason": last_reason,
    "account_locked": bool(to_bool(status.get("account_locked"))),
    "lock_owner": str(status.get("lock_owner") or "").strip(),
    "lock_shell_restore": str(status.get("lock_shell_restore") or "").strip(),
  },
  "policy": {
    "quota_limit_bytes": quota_limit_ssh,
    "quota_limit_ssh_bytes": quota_limit_ssh,
    "quota_limit_ovpn_bytes": quota_limit_ovpn,
    "quota_unit": quota_unit,
    "expired_at": expired,
    "access_enabled": bool(access_enabled),
    "ip_limit_enabled": bool(ip_limit_enabled),
    "ip_limit": ip_limit,
    "speed_limit_enabled": bool(speed_limit_enabled),
    "speed_down_mbit": speed_down,
    "speed_up_mbit": speed_up,
  },
  "runtime": {
    "quota_used_ssh_bytes": quota_used_ssh,
    "quota_used_ovpn_bytes": quota_used_ovpn,
    "active_session_ssh": active_session_ssh,
    "active_session_ovpn": active_session_ovpn,
    "last_seen_ssh_unix": last_seen_ssh,
    "last_seen_ovpn_unix": last_seen_ovpn,
  },
  "derived": {
    "quota_used_total_bytes": quota_used_total,
    "active_session_total": active_session_total,
    "quota_exhausted": bool(quota_exhausted_ssh),
    "quota_exhausted_ssh": bool(quota_exhausted_ssh),
    "quota_exhausted_ovpn": bool(quota_exhausted_ovpn),
    "ip_limit_locked": bool(ip_limit_locked),
    "access_effective": bool(shared_access and not quota_exhausted_ssh),
    "access_effective_ssh": bool(shared_access and not quota_exhausted_ssh),
    "access_effective_ovpn": bool(shared_access and not quota_exhausted_ovpn),
    "last_reason": last_reason,
    "last_reason_ssh": last_reason_ssh,
    "last_reason_ovpn": last_reason_ovpn,
  },
  "meta": meta,
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
import time

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

def to_bool(v, default=False):
  if isinstance(v, bool):
    return v
  if isinstance(v, (int, float)):
    return bool(v)
  s = str(v or "").strip().lower()
  if not s:
    return bool(default)
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

policy = payload.get("policy") if isinstance(payload.get("policy"), dict) else {}
runtime = payload.get("runtime") if isinstance(payload.get("runtime"), dict) else {}
derived = payload.get("derived") if isinstance(payload.get("derived"), dict) else {}
meta = payload.get("meta") if isinstance(payload.get("meta"), dict) else {}
status_raw = payload.get("status")
status = status_raw if isinstance(status_raw, dict) else {}

created = str(created_at or "").strip() or str(payload.get("created_at") or meta.get("created_at") or "").strip()
if created:
  created = created[:10]
if not created:
  created = datetime.datetime.utcnow().strftime("%Y-%m-%d")

expired = norm_date(expired_at) or norm_date(policy.get("expired_at")) or norm_date(payload.get("expired_at")) or "-"
token = pick_unique_token(os.path.dirname(state_file) or ".", state_file, payload.get("sshws_token") or meta.get("sshws_token"))

legacy_quota_limit = max(0, to_int(policy.get("quota_limit_ssh_bytes"), to_int(policy.get("quota_limit_bytes"), to_int(payload.get("quota_limit"), 0))))
quota_limit_ssh = legacy_quota_limit
quota_limit_ovpn = max(0, to_int(policy.get("quota_limit_ovpn_bytes"), to_int(policy.get("quota_limit_bytes"), legacy_quota_limit)))
unit = str(policy.get("quota_unit") or payload.get("quota_unit") or "binary").strip().lower()
if unit not in ("binary", "decimal"):
  unit = "binary"

quota_used_ssh = max(0, to_int(runtime.get("quota_used_ssh_bytes"), to_int(payload.get("quota_used"), 0)))
quota_used_ovpn = max(0, to_int(runtime.get("quota_used_ovpn_bytes"), 0))
active_session_ssh = max(0, to_int(runtime.get("active_session_ssh"), 0))
active_session_ovpn = max(0, to_int(runtime.get("active_session_ovpn"), 0))
last_seen_ssh = max(0, to_int(runtime.get("last_seen_ssh_unix"), 0))
last_seen_ovpn = max(0, to_int(runtime.get("last_seen_ovpn_unix"), 0))

speed_down = max(0.0, to_float(policy.get("speed_down_mbit"), to_float(status.get("speed_down_mbit"), 0.0)))
speed_up = max(0.0, to_float(policy.get("speed_up_mbit"), to_float(status.get("speed_up_mbit"), 0.0)))
ip_limit_enabled = to_bool(policy.get("ip_limit_enabled"), status.get("ip_limit_enabled"))
ip_limit = max(0, to_int(policy.get("ip_limit"), to_int(status.get("ip_limit"), 0)))
speed_limit_enabled = to_bool(policy.get("speed_limit_enabled"), status.get("speed_limit_enabled"))
manual_block = to_bool(status.get("manual_block"))
access_enabled = to_bool(policy.get("access_enabled"), True)

quota_used_total = quota_used_ssh + quota_used_ovpn
active_session_total = active_session_ssh + active_session_ovpn
quota_exhausted_ssh = bool(quota_limit_ssh > 0 and quota_used_ssh >= quota_limit_ssh)
quota_exhausted_ovpn = bool(quota_limit_ovpn > 0 and quota_used_ovpn >= quota_limit_ovpn)
ip_limit_locked = bool(ip_limit_enabled and ip_limit > 0 and active_session_total > ip_limit)
shared_access = bool(access_enabled and date_is_active(expired) and not ip_limit_locked and not manual_block)

if manual_block:
  last_reason_ssh = "manual"
  last_reason_ovpn = "manual"
elif not access_enabled:
  last_reason_ssh = "access_off"
  last_reason_ovpn = "access_off"
elif not date_is_active(expired):
  last_reason_ssh = "expired"
  last_reason_ovpn = "expired"
elif ip_limit_locked:
  last_reason_ssh = "ip_limit"
  last_reason_ovpn = "ip_limit"
else:
  last_reason_ssh = "quota_ssh" if quota_exhausted_ssh else "-"
  last_reason_ovpn = "quota_ovpn" if quota_exhausted_ovpn else "-"
if last_reason_ssh not in ("", "-"):
  last_reason = last_reason_ssh
elif last_reason_ovpn not in ("", "-"):
  last_reason = last_reason_ovpn
else:
  last_reason = "-"

meta["created_at"] = created
meta["updated_at_unix"] = int(time.time())
meta["ssh_present"] = True
meta["ovpn_present"] = bool(meta.get("ovpn_present"))
meta["sshws_token"] = token

payload = {
  "version": 1,
  "managed_by": "autoscript-manage",
  "protocol": "ssh-ovpn",
  "username": username,
  "created_at": created,
  "expired_at": expired,
  "sshws_token": token,
  "quota_limit": quota_limit_ssh,
  "quota_unit": unit,
  "quota_used": quota_used_ssh,
  "status": {
    "manual_block": bool(manual_block),
    "quota_exhausted": bool(quota_exhausted_ssh),
    "ip_limit_enabled": bool(ip_limit_enabled),
    "ip_limit": ip_limit,
    "ip_limit_locked": bool(ip_limit_locked),
    "speed_limit_enabled": bool(speed_limit_enabled),
    "speed_down_mbit": speed_down,
    "speed_up_mbit": speed_up,
    "lock_reason": last_reason,
    "account_locked": bool(to_bool(status.get("account_locked"))),
    "lock_owner": str(status.get("lock_owner") or "").strip(),
    "lock_shell_restore": str(status.get("lock_shell_restore") or "").strip(),
  },
  "policy": {
    "quota_limit_bytes": quota_limit_ssh,
    "quota_limit_ssh_bytes": quota_limit_ssh,
    "quota_limit_ovpn_bytes": quota_limit_ovpn,
    "quota_unit": unit,
    "expired_at": expired,
    "access_enabled": bool(access_enabled),
    "ip_limit_enabled": bool(ip_limit_enabled),
    "ip_limit": ip_limit,
    "speed_limit_enabled": bool(speed_limit_enabled),
    "speed_down_mbit": speed_down,
    "speed_up_mbit": speed_up,
  },
  "runtime": {
    "quota_used_ssh_bytes": quota_used_ssh,
    "quota_used_ovpn_bytes": quota_used_ovpn,
    "active_session_ssh": active_session_ssh,
    "active_session_ovpn": active_session_ovpn,
    "last_seen_ssh_unix": last_seen_ssh,
    "last_seen_ovpn_unix": last_seen_ovpn,
  },
  "derived": {
    "quota_used_total_bytes": quota_used_total,
    "active_session_total": active_session_total,
    "quota_exhausted": bool(quota_exhausted_ssh),
    "quota_exhausted_ssh": bool(quota_exhausted_ssh),
    "quota_exhausted_ovpn": bool(quota_exhausted_ovpn),
    "ip_limit_locked": bool(ip_limit_locked),
    "access_effective": bool(shared_access and not quota_exhausted_ssh),
    "access_effective_ssh": bool(shared_access and not quota_exhausted_ssh),
    "access_effective_ovpn": bool(shared_access and not quota_exhausted_ovpn),
    "last_reason": last_reason,
    "last_reason_ssh": last_reason_ssh,
    "last_reason_ovpn": last_reason_ovpn,
  },
  "meta": meta,
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

ssh_qac_traffic_enforcement_ready() {
  local proxy_svc="${SSHWS_PROXY_SERVICE:-sshws-proxy}"
  [[ -x /usr/local/bin/sshws-proxy ]] && return 0
  [[ -f "/etc/systemd/system/${proxy_svc}.service" ]] && return 0
  [[ -f "/lib/systemd/system/${proxy_svc}.service" ]] && return 0
  return 1
}

ssh_qac_traffic_scope_label() {
  if ssh_qac_traffic_enforcement_ready; then
    echo "Unified SSH & OVPN QAC"
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

badvpn_public_port_label() {
  local port
  port="$(badvpn_runtime_get_env BADVPN_UDPGW_PORT 2>/dev/null || echo "7300")"
  if svc_exists badvpn-udpgw || [[ -r "$(badvpn_runtime_env_file)" ]]; then
    printf '%s\n' "${port}"
  else
    printf '%s\n' "-"
  fi
}

ssh_account_info_write() {
  # args: username password quota_bytes expired_at created_at ip_enabled ip_limit speed_enabled speed_down speed_up sshws_token
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

  ssh_state_dirs_prepare
  password_mode="$(ssh_account_info_password_mode)"
  if [[ "${password_mode}" == "store" ]]; then
    password_out="${password_raw:-"-"}"
  else
    # Pada mode mask, selalu tampil hidden agar konsisten di setiap refresh.
    password_out="(hidden)"
  fi

  local acc_file domain ip isp country quota_limit_disp expired_disp valid_until created_disp ip_disp speed_disp sshws_path sshws_alt_path sshws_main_disp sshws_ports_disp ssh_direct_ports_disp ssh_ssl_tls_ports_disp badvpn_port_disp geo
  acc_file="$(ssh_account_info_file "${username}")"
  domain="$(detect_domain)"
  ip="$(detect_public_ip_ipapi)"
  [[ -n "${ip}" ]] || ip="$(detect_public_ip)"
  geo="$(main_info_geo_lookup "${ip}")"
  isp="${geo%%|*}"
  country="${geo##*|}"
  [[ -n "${domain}" ]] || domain="-"
  [[ -n "${ip}" ]] || ip="-"
  [[ -n "${isp}" ]] || isp="-"
  [[ -n "${country}" ]] || country="-"
  [[ -n "${created_at}" ]] || created_at="$(date -u '+%Y-%m-%d')"
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
  print(datetime.utcnow().strftime("%Y-%m-%d"))
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
from datetime import datetime, timezone
v = (sys.argv[1] or "").strip()
if not v or v == "-":
  print("unlimited")
  raise SystemExit(0)
try:
  dt = datetime.strptime(v[:10], "%Y-%m-%d").date()
  today = datetime.now(timezone.utc).date()
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

  if ! cat > "${acc_file}" <<EOF
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
SSH WS Path : ${sshws_main_disp}
SSH WS Path Alt : ${sshws_alt_path}
SSH WS Port : ${sshws_ports_disp}
SSH Direct Port : ${ssh_direct_ports_disp}
SSH SSL/TLS Port : ${ssh_ssl_tls_ports_disp}
BadVPN UDPGW: ${badvpn_port_disp}

Standard Payload:
Payload WSS:
    GET ${sshws_path} HTTP/1.1[crlf]Host: [host_port][crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]

Payload WS:
    GET ${sshws_path} HTTP/1.1[crlf]Host: [host_port][crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]

Payload WS (Prefixed):
    GET ${sshws_alt_path} HTTP/1.1[crlf]Host: [host_port][crlf]Upgrade: websocket[crlf]Connection: Keep-Alive[crlf][crlf]

Payload SNI+WS+Proxy:
    GET wss://[host]${sshws_path} HTTP/1.1[crlf]Host: [host_port][crlf]Upgrade: websocket[crlf]Connection: Keep-Alive[crlf][crlf]

Payload SNI+WS+Proxy (Prefixed):
    GET wss://[host]${sshws_alt_path} HTTP/1.1[crlf]Host: [host_port][crlf]Upgrade: websocket[crlf]Connection: Keep-Alive[crlf][crlf]

Catatan:
    Path SSH WS wajib memakai token per-user. Format yang didukung: /<token> atau /<bebas>/<token>. Payload lama ke path / tanpa token tidak dipakai lagi.
EOF
  then
    return 1
  fi
  chmod 600 "${acc_file}" >/dev/null 2>&1 || true
  return 0
}

ssh_account_info_refresh_from_state() {
  # args: username [password_override]
  local username="${1:-}"
  local password_override="${2:-}"
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
policy = d.get("policy") if isinstance(d.get("policy"), dict) else {}
meta = d.get("meta") if isinstance(d.get("meta"), dict) else {}
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
  str(max(0, ti(policy.get("quota_limit_ssh_bytes"), ti(policy.get("quota_limit_bytes"), ti(d.get("quota_limit"), 0))))),
  str(d.get("expired_at") or policy.get("expired_at") or "-")[:10] if str(d.get("expired_at") or policy.get("expired_at") or "-").strip() else "-",
  str(d.get("created_at") or meta.get("created_at") or "-"),
  tb(s.get("ip_limit_enabled", policy.get("ip_limit_enabled"))),
  str(max(0, ti(s.get("ip_limit"), ti(policy.get("ip_limit"), 0)))),
  tb(s.get("speed_limit_enabled", policy.get("speed_limit_enabled"))),
  fm(max(0.0, tf(s.get("speed_down_mbit"), tf(policy.get("speed_down_mbit"), 0.0)))),
  fm(max(0.0, tf(s.get("speed_up_mbit"), tf(policy.get("speed_up_mbit"), 0.0)))),
  str(d.get("sshws_token") or meta.get("sshws_token") or "").strip().lower(),
]))
PY
)"
  IFS='|' read -r quota_bytes expired_at created_at ip_enabled ip_limit speed_enabled speed_down speed_up sshws_token <<<"${fields}"

  local unified_fields _unified_username unified_quota_unit _unified_access_enabled _unified_quota_exhausted _unified_ip_locked _unified_last_reason
  local _unified_quota_used_ssh _unified_quota_used_ovpn _unified_quota_used_total _unified_active_ssh _unified_active_ovpn _unified_active_total
  if unified_fields="$(ssh_ovpn_qac_summary_raw_fields "${username}" 2>/dev/null || true)"; [[ -n "${unified_fields}" ]]; then
    local _unified_quota_ovpn _unified_access_ssh _unified_access_ovpn _unified_quota_exhausted_ovpn _unified_reason_ssh _unified_reason_ovpn
    IFS='|' read -r _unified_username quota_bytes _unified_quota_ovpn unified_quota_unit expired_at _unified_access_enabled ip_enabled ip_limit speed_enabled speed_down speed_up _unified_quota_used_ssh _unified_quota_used_ovpn _unified_quota_used_total _unified_active_ssh _unified_active_ovpn _unified_active_total _unified_access_ssh _unified_access_ovpn _unified_quota_exhausted _unified_quota_exhausted_ovpn _unified_ip_locked _unified_reason_ssh _unified_reason_ovpn <<<"${unified_fields}"
  fi

  password="${password_override}"
  if [[ -z "${password}" ]]; then
    password="$(ssh_account_info_password_get "${username}")"
  fi

  if ! sshws_token_valid "${sshws_token}"; then
    sshws_token="$(ssh_user_state_ensure_token "${username}" 2>/dev/null || true)"
  fi

  ssh_account_info_write "${username}" "${password}" "${quota_bytes}" "${expired_at}" "${created_at}" "${ip_enabled}" "${ip_limit}" "${speed_enabled}" "${speed_down}" "${speed_up}" "${sshws_token}"
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

ssh_pick_managed_user() {
  local -n _out_ref="$1"
  _out_ref=""

  ssh_state_dirs_prepare

  local -a users=()
  while IFS= read -r u; do
    [[ -n "${u}" ]] || continue
    users+=("${u}")
  done < <(find "${SSH_USERS_STATE_DIR}" -maxdepth 1 -type f -name '*.json' -printf '%f\n' 2>/dev/null | sed -E 's/@ssh\.json$//' | sed -E 's/\.json$//' | sort -u)

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

ssh_add_user_rollback() {
  # args: username qf acc_file reason
  local username="${1:-}"
  local qf="${2:-}"
  local acc_file="${3:-}"
  local reason="${4:-Gagal membuat akun SSH.}"
  local deleted="false"

  if id "${username}" >/dev/null 2>&1; then
    if userdel -r "${username}" >/dev/null 2>&1 || userdel "${username}" >/dev/null 2>&1; then
      deleted="true"
    fi
  else
    deleted="true"
  fi

  if [[ "${deleted}" == "true" ]]; then
    if [[ -n "${qf}" ]]; then
      rm -f "${qf}" "${SSH_USERS_STATE_DIR}/${username}.json" >/dev/null 2>&1 || true
    fi
    if [[ -n "${acc_file}" ]]; then
      rm -f "${acc_file}" "${SSH_ACCOUNT_DIR}/${username}.txt" >/dev/null 2>&1 || true
    fi
    warn "${reason}"
    return 0
  fi

  # Hindari orphan-silent: saat userdel gagal, pertahankan metadata agar status masih terlihat.
  warn "${reason}"
  warn "Rollback parsial: gagal menghapus user Linux '${username}'."
  warn "Metadata dipertahankan. Jalankan manual: userdel -r '${username}'"
  return 1
}

ssh_managed_users_lines() {
  ssh_state_dirs_prepare
  need_python3
  python3 - <<'PY' "${SSH_USERS_STATE_DIR}" 2>/dev/null || true
import json
import os
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

rows.sort(key=lambda x: x[0])
for _, username, created, expired in rows:
  print(f"{username}|{created}|{expired}")
PY
}

ssh_ovpn_user_rows() {
  ssh_state_dirs_prepare
  local ovpn_clients_dir ccd_dir
  ovpn_clients_dir="$(openvpn_clients_dir_value 2>/dev/null || echo "/etc/openvpn/clients")"
  ccd_dir="$(openvpn_ccd_dir_value 2>/dev/null || echo "/etc/openvpn/server/ccd")"
  need_python3
  python3 - <<'PY' "${SSH_USERS_STATE_DIR}" "${ovpn_clients_dir}" "${ccd_dir}" 2>/dev/null || true
import json
import os
import pwd
import re
import sys

ssh_root, ovpn_root, ccd_root = sys.argv[1:4]

def norm_username(raw):
  text = str(raw or "").strip()
  if text.endswith("@ssh"):
    text = text[:-4]
  if "@" in text:
    text = text.split("@", 1)[0]
  return text

def norm_date(value):
  text = str(value or "").strip()
  if not text or text == "-":
    return "-"
  match = re.search(r"\d{4}-\d{2}-\d{2}", text)
  return match.group(0) if match else "-"

def user_exists(name):
  try:
    pwd.getpwnam(name)
    return True
  except KeyError:
    return False
  except Exception:
    return False

ssh_map = {}
if os.path.isdir(ssh_root):
  for entry in os.listdir(ssh_root):
    if entry.startswith(".") or not entry.endswith(".json"):
      continue
    name = norm_username(entry[:-5])
    if not name:
      continue
    payload = {}
    try:
      with open(os.path.join(ssh_root, entry), "r", encoding="utf-8") as f:
        loaded = json.load(f)
      if isinstance(loaded, dict):
        payload = loaded
    except Exception:
      payload = {}
    meta_user = norm_username(payload.get("username") or name) or name
    ssh_map[meta_user] = {
      "created": norm_date(payload.get("created_at")),
      "expired": norm_date(payload.get("expired_at")),
      "system": "ok" if user_exists(meta_user) else "missing",
    }

ovpn_map = {}
if os.path.isdir(ovpn_root):
  for entry in os.listdir(ovpn_root):
    if entry.startswith(".") or not entry.endswith(".json"):
      continue
    path = os.path.join(ovpn_root, entry)
    name = norm_username(entry[:-5])
    if not name:
      continue
    payload = {}
    try:
      with open(path, "r", encoding="utf-8") as f:
        loaded = json.load(f)
      if isinstance(loaded, dict):
        payload = loaded
    except Exception:
      payload = {}
    client_name = norm_username(payload.get("client_name") or name) or name
    client_cn = str(payload.get("client_cn") or client_name).strip() or client_name
    token = str(payload.get("ovpnws_token") or "").strip().lower()
    access = "yes" if os.path.exists(os.path.join(ccd_root, client_cn)) else "no"
    ovpn_map[client_name] = {
      "created": norm_date(payload.get("created_at")),
      "expired": norm_date(payload.get("expired_at")),
      "client_cn": client_cn,
      "token": token if re.fullmatch(r"[a-f0-9]{10}", token) else "-",
      "access": access,
    }

names = sorted(set(ssh_map) | set(ovpn_map), key=str.lower)
for name in names:
  ssh = ssh_map.get(name)
  ovpn = ovpn_map.get(name)
  if ssh and ovpn:
    pair = "paired"
  elif ssh:
    pair = "ssh-only"
  else:
    pair = "ovpn-only"
  created = (ssh or {}).get("created") or (ovpn or {}).get("created") or "-"
  if not created:
    created = "-"
  expired = "-"
  for value in ((ssh or {}).get("expired"), (ovpn or {}).get("expired")):
    if value and value != "-":
      expired = value
      break
  ssh_state = (ssh or {}).get("system") if ssh else "-"
  ovpn_state = "yes" if ovpn else "-"
  access = (ovpn or {}).get("access") if ovpn else "-"
  client_cn = (ovpn or {}).get("client_cn") or "-"
  token = (ovpn or {}).get("token") or "-"
  print("|".join([name, pair, ssh_state, ovpn_state, access, created, expired, client_cn, token]))
PY
}

ssh_ovpn_find_user_row() {
  local username="${1:-}"
  local row
  while IFS= read -r row; do
    [[ -n "${row}" ]] || continue
    if [[ "${row%%|*}" == "${username}" ]]; then
      printf '%s\n' "${row}"
      return 0
    fi
  done < <(ssh_ovpn_user_rows)
  return 1
}

ssh_ovpn_user_has_ssh_side() {
  local username="${1:-}"
  [[ -n "${username}" ]] || return 1
  ssh_state_dirs_prepare
  [[ -f "$(ssh_user_state_file "${username}")" ]]
}

ssh_ovpn_user_has_ovpn_side() {
  local username="${1:-}"
  openvpn_client_state_exists "${username}"
}

ssh_ovpn_user_has_linux_account() {
  local username="${1:-}"
  [[ -n "${username}" ]] || return 1
  id "${username}" >/dev/null 2>&1
}

ssh_ovpn_openvpn_side_ensure() {
  local username="${1:-}"
  local created_at="${2:-}"
  local expired_at="${3:-}"
  local existing_state="false"
  local client_cn=""
  if [[ -z "${username}" ]]; then
    return 1
  fi
  if openvpn_client_state_exists "${username}"; then
    existing_state="true"
    client_cn="$(openvpn_client_cn_get "${username}")"
  else
    client_cn="$(openvpn_client_generate_cn "${username}" 2>/dev/null || true)"
    if [[ -z "${client_cn}" ]]; then
      warn "Gagal membuat Client CN OpenVPN unik untuk '${username}'."
      return 1
    fi
    if ! openvpn_client_issue_certificate_manage "${username}" "${client_cn}"; then
      openvpn_client_add_rollback "${username}" "${client_cn}" ""
      return 1
    fi
    if ! openvpn_client_state_upsert "${username}" "${client_cn}" >/dev/null; then
      openvpn_client_add_rollback "${username}" "${client_cn}" ""
      warn "Gagal menulis state OpenVPN untuk '${username}'."
      return 1
    fi
  fi

  if ! openvpn_client_state_set_dates "${username}" "${created_at}" "${expired_at}"; then
    if [[ "${existing_state}" != "true" ]]; then
      openvpn_client_add_rollback "${username}" "${client_cn}" ""
    fi
    warn "Gagal menyimpan expiry OpenVPN untuk '${username}'."
    return 1
  fi

  if ! openvpn_client_access_sync_manage "${username}"; then
    if [[ "${existing_state}" != "true" ]]; then
      openvpn_client_add_rollback "${username}" "${client_cn}" ""
    fi
    warn "Gagal menyinkronkan akses OpenVPN untuk '${username}'."
    return 1
  fi

  if ! openvpn_client_render_artifacts_manage "${username}"; then
    if [[ "${existing_state}" != "true" ]]; then
      openvpn_client_add_rollback "${username}" "${client_cn}" ""
    fi
    warn "Gagal membuat file client OpenVPN untuk '${username}'."
    return 1
  fi

  openvpn_account_info_refresh "${username}" || true
  openvpn_expiry_sync_now_warn "${username}" || true
  return 0
}

ssh_ovpn_username_duplicate_reason() {
  local username="${1:-}"
  local reason=""
  if reason="$(ssh_username_duplicate_reason "${username}")"; then
    printf '%s\n' "${reason}"
    return 0
  fi
  if openvpn_client_state_exists "${username}" \
    || [[ -f "$(openvpn_client_profile_path_value "${username}")" ]] \
    || [[ -f "$(openvpn_account_info_file "${username}")" ]] \
    || [[ -f "$(openvpn_client_bundle_path_value "${username}" 2>/dev/null || true)" ]]; then
    printf "Username '%s' sudah terdaftar pada metadata OpenVPN managed.\n" "${username}"
    return 0
  fi
  return 1
}

ssh_add_user_header_render() {
  local -n _page_ref="$1"
  local page_size=5
  local -a rows=()
  local row
  while IFS= read -r row; do
    [[ -n "${row}" ]] || continue
    rows+=("${row}")
  done < <(ssh_ovpn_user_rows)

  local total="${#rows[@]}"
  echo "Daftar akun SSH & OVPN terdaftar (maks 5 baris):"
  if (( total == 0 )); then
    echo "  (Belum ada akun SSH/OVPN terkelola)"
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

  printf "%-4s %-18s %-10s %-6s %-6s %-10s\n" "No" "Username" "Pair" "SSH" "OVPN" "Expired"
  printf "%-4s %-18s %-10s %-6s %-6s %-10s\n" "----" "------------------" "----------" "------" "------" "----------"

  local i username pair ssh_state ovpn_state access created expired client_cn token
  for ((i=start; i<end; i++)); do
    IFS='|' read -r username pair ssh_state ovpn_state access created expired client_cn token <<<"${rows[$i]}"
    printf "%-4s %-18s %-10s %-6s %-6s %-10s\n" "$((i + 1))" "${username}" "${pair}" "${ssh_state}" "${ovpn_state}" "${expired}"
  done

  echo "Halaman: $((page + 1))/${pages} | Total: ${total}"
  if (( pages > 1 )); then
    echo "Navigasi: ketik next/previous sebelum input username."
  fi
}

ssh_ovpn_pick_user() {
  local -n _out_ref="$1"
  local -a rows=()
  local row
  _out_ref=""
  while IFS= read -r row; do
    [[ -n "${row}" ]] || continue
    rows+=("${row}")
  done < <(ssh_ovpn_user_rows)

  if (( ${#rows[@]} == 0 )); then
    warn "Belum ada akun SSH/OVPN terkelola."
    return 1
  fi

  printf "%-4s %-18s %-10s %-6s %-6s %-7s %-10s\n" "No" "Username" "Pair" "SSH" "OVPN" "Access" "Expired"
  printf "%-4s %-18s %-10s %-6s %-6s %-7s %-10s\n" "----" "------------------" "----------" "------" "------" "-------" "----------"
  local i row_username pair ssh_state ovpn_state access created expired client_cn token
  for i in "${!rows[@]}"; do
    IFS='|' read -r row_username pair ssh_state ovpn_state access created expired client_cn token <<<"${rows[$i]}"
    printf "%-4s %-18s %-10s %-6s %-6s %-7s %-10s\n" "$((i + 1))" "${row_username}" "${pair}" "${ssh_state}" "${ovpn_state}" "${access}" "${expired}"
  done

  local pick
  while true; do
    if ! read -r -p "Pilih akun (NO, atau kembali): " pick; then
      echo
      return 1
    fi
    if is_back_choice "${pick}"; then
      return 1
    fi
    [[ "${pick}" =~ ^[0-9]+$ ]] || { warn "Input harus angka."; continue; }
    if (( pick < 1 || pick > ${#rows[@]} )); then
      warn "Di luar range."
      continue
    fi
    IFS='|' read -r _out_ref _ <<<"${rows[$((pick - 1))]}"
    return 0
  done
}

ssh_ovpn_account_info_show() {
  local username="${1:-}"
  local breadcrumb="${2:-3) SSH & OVPN User > ACCOUNT INFO}"
  local row pair ssh_state ovpn_state access created expired client_cn token
  row="$(ssh_ovpn_find_user_row "${username}" 2>/dev/null || true)"
  if [[ -z "${row}" ]]; then
    warn "Akun '${username}' tidak ditemukan."
    pause
    return 0
  fi
  IFS='|' read -r username pair ssh_state ovpn_state access created expired client_cn token <<<"${row}"

  if ssh_ovpn_user_has_ssh_side "${username}"; then
    ssh_account_info_refresh_warn "${username}" || true
  fi
  if ssh_ovpn_user_has_ovpn_side "${username}"; then
    openvpn_account_info_refresh "${username}" || true
  fi

  title
  echo "${breadcrumb}"
  hr
  printf "%-12s : %s\n" "Username" "${username}"
  printf "%-12s : %s\n" "Pair" "${pair}"
  printf "%-12s : %s\n" "SSH" "${ssh_state}"
  printf "%-12s : %s\n" "OVPN" "${ovpn_state}"
  printf "%-12s : %s\n" "Access" "${access}"
  printf "%-12s : %s\n" "Expired" "${expired}"
  if [[ "${client_cn}" != "-" ]]; then
    printf "%-12s : %s\n" "Client CN" "${client_cn}"
  fi
  if [[ "${token}" != "-" ]]; then
    printf "%-12s : %s\n" "WS Token" "${token}"
  fi
  hr
  local unified_fields _unified_username unified_quota_ssh_bytes unified_quota_ovpn_bytes unified_quota_unit _unified_expired unified_access_enabled
  local unified_ip_enabled unified_ip_limit unified_speed_enabled unified_speed_down unified_speed_up
  local unified_used_ssh unified_used_ovpn unified_used_total unified_active_ssh unified_active_ovpn unified_active_total
  local unified_access_ssh unified_access_ovpn _unified_quota_exhausted_ssh _unified_quota_exhausted_ovpn _unified_ip_locked unified_reason_ssh unified_reason_ovpn
  if unified_fields="$(ssh_ovpn_qac_summary_raw_fields "${username}" 2>/dev/null || true)"; [[ -n "${unified_fields}" ]]; then
    IFS='|' read -r _unified_username unified_quota_ssh_bytes unified_quota_ovpn_bytes unified_quota_unit _unified_expired unified_access_enabled unified_ip_enabled unified_ip_limit unified_speed_enabled unified_speed_down unified_speed_up unified_used_ssh unified_used_ovpn unified_used_total unified_active_ssh unified_active_ovpn unified_active_total unified_access_ssh unified_access_ovpn _unified_quota_exhausted_ssh _unified_quota_exhausted_ovpn _unified_ip_locked unified_reason_ssh unified_reason_ovpn <<<"${unified_fields}"
    echo "UNIFIED QAC:"
    printf "%-12s : %s\n" "Quota SSH" "$(ssh_ovpn_qac_format_quota_limit_display "${unified_quota_ssh_bytes}" "${unified_quota_unit}")"
    printf "%-12s : %s\n" "Quota OVPN" "$(ssh_ovpn_qac_format_quota_limit_display "${unified_quota_ovpn_bytes}" "${unified_quota_unit}")"
    printf "%-12s : %s\n" "Used SSH" "$(ssh_ovpn_qac_human_bytes "${unified_used_ssh}")"
    printf "%-12s : %s\n" "Used OVPN" "$(ssh_ovpn_qac_human_bytes "${unified_used_ovpn}")"
    printf "%-12s : %s\n" "Used Total" "$(ssh_ovpn_qac_human_bytes "${unified_used_total}")"
    printf "%-12s : %s\n" "Sess SSH" "${unified_active_ssh}"
    printf "%-12s : %s\n" "Sess OVPN" "${unified_active_ovpn}"
    printf "%-12s : %s\n" "Sess Total" "${unified_active_total}"
    printf "%-12s : %s\n" "Access" "$( [[ "${unified_access_enabled}" == "true" ]] && echo "ON" || echo "OFF" )"
    printf "%-12s : %s\n" "IP Limit" "$( [[ "${unified_ip_enabled}" == "true" ]] && printf 'ON (%s)' "${unified_ip_limit}" || echo "OFF" )"
    if [[ "${unified_speed_enabled}" == "true" ]]; then
      printf "%-12s : %s\n" "Speed" "ON (DOWN ${unified_speed_down} Mbps | UP ${unified_speed_up} Mbps)"
    else
      printf "%-12s : %s\n" "Speed" "OFF"
    fi
    printf "%-12s : %s\n" "Access SSH" "$( [[ "${unified_access_ssh}" == "true" ]] && echo "ON" || echo "OFF" )"
    printf "%-12s : %s\n" "Access OVPN" "$( [[ "${unified_access_ovpn}" == "true" ]] && echo "ON" || echo "OFF" )"
    printf "%-12s : %s\n" "Reason SSH" "${unified_reason_ssh}"
    printf "%-12s : %s\n" "Reason OVPN" "${unified_reason_ovpn}"
    hr
  fi
  if [[ -f "$(ssh_account_info_file "${username}")" ]]; then
    cat "$(ssh_account_info_file "${username}")"
    hr
  else
    warn "SSH ACCOUNT INFO tidak tersedia untuk '${username}'."
    hr
  fi
  if ssh_ovpn_user_has_ovpn_side "${username}" && [[ -f "$(openvpn_account_info_file "${username}")" ]]; then
    cat "$(openvpn_account_info_file "${username}")"
    hr
    echo "Catatan : password hanya berlaku untuk SSH. OpenVPN memakai profile/ZIP."
  else
    warn "OPENVPN ACCOUNT INFO tidak tersedia untuk '${username}'."
  fi
  hr
  pause
}

ssh_add_user_menu() {
  local username qf acc_file header_page=0
  while true; do
    title
    echo "3) SSH & OVPN User > Add User"
    hr
    ssh_add_user_header_render header_page
    hr

    if ! read -r -p "Username SSH & OVPN (atau next/previous/kembali): " username; then
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
  if dup_reason="$(ssh_ovpn_username_duplicate_reason "${username}")"; then
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

  local quota_ssh_input quota_ssh_gb quota_ssh_bytes quota_ovpn_input quota_ovpn_gb quota_ovpn_bytes
  if ! read -r -p "Quota SSH (GB) (atau kembali): " quota_ssh_input; then
    echo
    return 0
  fi
  if is_back_choice "${quota_ssh_input}"; then
    return 0
  fi
  quota_ssh_gb="$(normalize_gb_input "${quota_ssh_input}")"
  if [[ -z "${quota_ssh_gb}" ]]; then
    warn "Format quota SSH tidak valid. Contoh: 5 atau 5GB."
    pause
    return 0
  fi
  quota_ssh_bytes="$(bytes_from_gb "${quota_ssh_gb}")"

  if ! read -r -p "Quota OVPN (GB) (atau kembali): " quota_ovpn_input; then
    echo
    return 0
  fi
  if is_back_choice "${quota_ovpn_input}"; then
    return 0
  fi
  quota_ovpn_gb="$(normalize_gb_input "${quota_ovpn_input}")"
  if [[ -z "${quota_ovpn_gb}" ]]; then
    warn "Format quota OVPN tidak valid. Contoh: 5 atau 5GB."
    pause
    return 0
  fi
  quota_ovpn_bytes="$(bytes_from_gb "${quota_ovpn_gb}")"

  local ip_toggle ip_enabled="false" ip_limit="0"
  echo "Limit IP? (on/off)"
  if ! read -r -p "IP Limit (on/off) (atau kembali): " ip_toggle; then
    echo
    return 0
  fi
  if is_back_word_choice "${ip_toggle}"; then
    return 0
  fi
  ip_toggle="${ip_toggle,,}"
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
  if ! read -r -p "Speed Limit (on/off) (atau kembali): " speed_toggle; then
    echo
    return 0
  fi
  if is_back_word_choice "${speed_toggle}"; then
    return 0
  fi
  speed_toggle="${speed_toggle,,}"
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
  expired_at="$(date -u -d "+${active_days} days" '+%Y-%m-%d' 2>/dev/null || true)"
  if [[ -z "${expired_at}" ]]; then
    warn "Gagal menghitung tanggal expiry SSH."
    pause
    return 0
  fi
  created_at="$(date -u '+%Y-%m-%d')"

  if ! useradd -m -s /bin/bash "${username}" >/dev/null 2>&1; then
    warn "Gagal membuat user Linux '${username}'."
    pause
    return 0
  fi

  if ! printf '%s:%s\n' "${username}" "${password}" | chpasswd >/dev/null 2>&1; then
    ssh_add_user_rollback "${username}" "" "" "Gagal set password user '${username}'."
    pause
    return 0
  fi

  if ! chage -E "${expired_at}" "${username}" >/dev/null 2>&1; then
    ssh_add_user_rollback "${username}" "" "" "Gagal set expiry user '${username}'."
    pause
    return 0
  fi

  if ! ssh_user_state_write "${username}" "${created_at}" "${expired_at}"; then
    ssh_add_user_rollback "${username}" "${qf}" "" "Gagal menulis metadata akun SSH."
    pause
    return 0
  fi

  if ! ssh_qac_atomic_update_file "${qf}" set_quota_ssh_limit "${quota_ssh_bytes}"; then
    ssh_add_user_rollback "${username}" "${qf}" "${acc_file}" "Gagal set quota SSH metadata."
    pause
    return 0
  fi

  if ! ssh_qac_atomic_update_file "${qf}" set_quota_ovpn_limit "${quota_ovpn_bytes}"; then
    ssh_add_user_rollback "${username}" "${qf}" "${acc_file}" "Gagal set quota OVPN metadata."
    pause
    return 0
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
    ssh_add_user_rollback "${username}" "${qf}" "${acc_file}" "${add_fail_msg}"
    pause
    return 0
  fi

  ssh_qac_enforce_now_warn "${username}" || true
  if ! ssh_account_info_refresh_from_state "${username}" "${password}"; then
    ssh_add_user_rollback "${username}" "${qf}" "${acc_file}" "Gagal menulis SSH account info."
    pause
    return 0
  fi

  local pair_status="paired"
  local ovpn_notice=""
  local ovpn_ready_reason=""
  if openvpn_manage_is_ready; then
    if ! ssh_ovpn_openvpn_side_ensure "${username}" "${created_at}" "${expired_at}"; then
      pair_status="ssh-only"
      ovpn_notice="Sisi OpenVPN belum berhasil dibuat. Akun tetap dibuat sebagai SSH-only."
    fi
  else
    pair_status="ssh-only"
    ovpn_ready_reason="$(openvpn_manage_ready_reason 2>/dev/null || true)"
    ovpn_notice="OpenVPN belum siap: ${ovpn_ready_reason:-runtime belum siap}. Akun dibuat sebagai SSH-only."
  fi

  if [[ "${pair_status}" == "paired" ]]; then
    log "Akun SSH & OVPN berhasil dibuat: ${username}"
  else
    log "Akun SSH dibuat tanpa sisi OpenVPN: ${username}"
  fi
  ssh_ovpn_qac_state_sync_now_warn "${username}" || true
  openvpn_speed_sync_now_warn || true
  title
  if [[ "${pair_status}" == "paired" ]]; then
    echo "Add SSH & OVPN user sukses ✅"
  else
    echo "Add SSH user sukses ✅"
  fi
  hr
  printf "%-16s : %s\n" "Pair Status" "${pair_status}"
  echo "SSH account file:"
  echo "  ${acc_file}"
  echo "SSH metadata file:"
  echo "  ${qf}"
  if [[ "${pair_status}" == "paired" ]]; then
    echo "OVPN account file:"
    echo "  $(openvpn_account_info_file "${username}")"
  fi
  hr
  echo "SSH ACCOUNT INFO:"
  if [[ -f "${acc_file}" ]]; then
    cat "${acc_file}"
  else
    echo "(SSH ACCOUNT INFO tidak ditemukan: ${acc_file})"
  fi
  hr
  echo "OPENVPN ACCOUNT INFO:"
  if [[ -f "$(openvpn_account_info_file "${username}")" ]]; then
    cat "$(openvpn_account_info_file "${username}")"
  elif [[ -n "${ovpn_notice}" ]]; then
    echo "${ovpn_notice}"
    echo "Gunakan 'Refresh OVPN Files' setelah runtime OpenVPN siap untuk melengkapi sisi OpenVPN."
  else
    echo "(OPENVPN ACCOUNT INFO tidak ditemukan: $(openvpn_account_info_file "${username}"))"
  fi
  if [[ "$(ssh_account_info_password_mode)" != "store" && -n "${password}" ]]; then
    hr
    echo "One-time Password : ${password}"
    echo "Note             : password ini hanya untuk SSH; OpenVPN memakai profile/ZIP."
  fi
  hr
  password=""
  pause
}

ssh_delete_user_menu() {
  title
  echo "3) SSH & OVPN User > Delete User"
  hr

  local username
  if ! ssh_ovpn_pick_user username; then
    pause
    return 0
  fi

  local ask_rc=0
  if ! confirm_yn_or_back "Hapus akun SSH & OVPN '${username}' sekarang?"; then
    ask_rc=$?
    if (( ask_rc == 2 )); then
      return 0
    fi
    warn "Dibatalkan."
    pause
    return 0
  fi

  if ssh_ovpn_user_has_ssh_side "${username}" && ssh_ovpn_user_has_linux_account "${username}"; then
    userdel -r "${username}" >/dev/null 2>&1 || userdel "${username}" >/dev/null 2>&1 || {
      warn "Gagal menghapus user Linux '${username}'."
      pause
      return 0
    }
  fi

  if ssh_ovpn_user_has_ssh_side "${username}"; then
    rm -f "$(ssh_user_state_file "${username}")" \
          "${SSH_USERS_STATE_DIR}/${username}.json" \
          "$(ssh_account_info_file "${username}")" \
          "${SSH_ACCOUNT_DIR}/${username}.txt" >/dev/null 2>&1 || true
  fi
  if ssh_ovpn_user_has_ovpn_side "${username}"; then
    openvpn_client_delete_manage "${username}" || true
  fi
  ssh_ovpn_qac_state_remove "${username}" || true
  openvpn_speed_sync_now_warn || true
  log "Akun SSH & OVPN '${username}' dihapus."
  pause
}

ssh_extend_expiry_menu() {
  title
  echo "3) SSH & OVPN User > Set Expiry"
  hr

  local username
  if ! ssh_ovpn_pick_user username; then
    pause
    return 0
  fi

  local current_exp
  current_exp="-"
  if ssh_ovpn_user_has_ssh_side "${username}" && ssh_ovpn_user_has_linux_account "${username}"; then
    current_exp="$(chage -l "${username}" 2>/dev/null | awk -F': ' '/Account expires/{print $2; exit}' || true)"
  elif ssh_ovpn_user_has_ssh_side "${username}"; then
    current_exp="$(ssh_user_state_expired_at_get "${username}" 2>/dev/null || true)"
  elif ssh_ovpn_user_has_ovpn_side "${username}"; then
    current_exp="$(openvpn_client_expired_at_get "${username}" 2>/dev/null || true)"
  fi
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
      new_expiry="$(date -u -d "+${add_days} days" '+%Y-%m-%d' 2>/dev/null || true)"
      ;;
    2)
      if ! read -r -p "Tanggal expiry baru (YYYY-MM-DD): " new_expiry; then
        echo
        return 0
      fi
      if is_back_choice "${new_expiry}"; then
        return 0
      fi
      if ! date -u -d "${new_expiry}" '+%Y-%m-%d' >/dev/null 2>&1; then
        warn "Format tanggal tidak valid."
        pause
        return 0
      fi
      new_expiry="$(date -u -d "${new_expiry}" '+%Y-%m-%d' 2>/dev/null || true)"
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

  local created_at updated_any="false"
  created_at="$(ssh_user_state_created_at_get "${username}")"
  if [[ -z "${created_at}" ]]; then
    created_at="$(openvpn_client_created_at_get "${username}" 2>/dev/null || true)"
  fi
  [[ -n "${created_at}" ]] || created_at="$(date -u '+%Y-%m-%d')"

  if ssh_ovpn_user_has_ssh_side "${username}"; then
    if ssh_ovpn_user_has_linux_account "${username}"; then
      if ! chage -E "${new_expiry}" "${username}" >/dev/null 2>&1; then
        warn "Gagal update expiry SSH untuk '${username}'."
      else
        updated_any="true"
      fi
    else
      warn "User Linux '${username}' tidak ditemukan. Metadata SSH tetap akan disinkronkan."
    fi
    if ! ssh_user_state_write "${username}" "${created_at}" "${new_expiry}"; then
      warn "Metadata SSH gagal diperbarui untuk '${username}'."
    else
      updated_any="true"
    fi
    if ! ssh_account_info_refresh_from_state "${username}"; then
      warn "SSH ACCOUNT INFO gagal disinkronkan untuk '${username}'."
    fi
  fi

  if ssh_ovpn_user_has_ovpn_side "${username}"; then
    if ! openvpn_client_state_set_dates "${username}" "${created_at}" "${new_expiry}"; then
      warn "Metadata OpenVPN gagal diperbarui untuk '${username}'."
    else
      updated_any="true"
    fi
    openvpn_expiry_sync_now_warn "${username}" || true
    openvpn_account_info_refresh "${username}" || true
  fi

  ssh_ovpn_qac_state_sync_now_warn "${username}" || true
  if [[ "${updated_any}" != "true" ]]; then
    warn "Tidak ada sisi SSH/OVPN yang berhasil diperbarui untuk '${username}'."
    pause
    return 0
  fi

  log "Expiry akun SSH & OVPN '${username}' diperbarui ke ${new_expiry}."
  pause
}

ssh_list_users_menu() {
  local -a rows=()
  local row
  while IFS= read -r row; do
    [[ -n "${row}" ]] || continue
    rows+=("${row}")
  done < <(ssh_ovpn_user_rows)

  if (( ${#rows[@]} == 0 )); then
    title
    echo "3) SSH & OVPN User > List Users"
    hr
    warn "Belum ada akun SSH/OVPN terkelola."
    hr
    pause
    return 0
  fi

  while true; do
    title
    echo "3) SSH & OVPN User > List Users"
    hr
    printf "%-4s %-18s %-10s %-6s %-6s %-7s %-10s\n" "No" "Username" "Pair" "SSH" "OVPN" "Access" "Expired"
    printf "%-4s %-18s %-10s %-6s %-6s %-7s %-10s\n" "----" "------------------" "----------" "------" "------" "-------" "----------"
    local i username pair ssh_state ovpn_state access created expired client_cn token
    for i in "${!rows[@]}"; do
      IFS='|' read -r username pair ssh_state ovpn_state access created expired client_cn token <<<"${rows[$i]}"
      printf "%-4s %-18s %-10s %-6s %-6s %-7s %-10s\n" "$((i + 1))" "${username}" "${pair}" "${ssh_state}" "${ovpn_state}" "${access}" "${expired}"
    done
    hr
    echo "Ketik nomor untuk lihat SSH & OVPN ACCOUNT INFO."
    echo "0/back untuk kembali."
    hr

    local pick
    if ! read -r -p "Pilih: " pick; then
      echo
      return 0
    fi
    if is_back_choice "${pick}"; then
      return 0
    fi
    if [[ ! "${pick}" =~ ^[0-9]+$ ]] || (( pick < 1 || pick > ${#rows[@]} )); then
      warn "Pilihan tidak valid."
      sleep 1
      continue
    fi

    IFS='|' read -r username _ <<<"${rows[$((pick - 1))]}"
    ssh_ovpn_account_info_show "${username}" "3) SSH & OVPN User > ACCOUNT INFO"
  done
}

ssh_ovpn_refresh_ovpn_files_menu() {
  title
  echo "3) SSH & OVPN User > Refresh OVPN Files"
  hr

  local username
  if ! ssh_ovpn_pick_user username; then
    pause
    return 0
  fi
  if ! ssh_ovpn_user_has_ovpn_side "${username}"; then
    local created_at expired_at ready_reason
    if ! ssh_ovpn_user_has_ssh_side "${username}"; then
      warn "Akun '${username}' belum punya sisi OpenVPN."
      pause
      return 0
    fi
    if ! openvpn_manage_is_ready; then
      ready_reason="$(openvpn_manage_ready_reason 2>/dev/null || true)"
      warn "OpenVPN belum siap untuk '${username}': ${ready_reason:-runtime belum siap}."
      pause
      return 0
    fi
    created_at="$(ssh_user_state_created_at_get "${username}")"
    expired_at="$(ssh_user_state_expired_at_get "${username}")"
    [[ -n "${created_at}" ]] || created_at="$(date -u '+%Y-%m-%d')"
    [[ -n "${expired_at}" ]] || expired_at="-"
    if ! ssh_ovpn_openvpn_side_ensure "${username}" "${created_at}" "${expired_at}"; then
      warn "Gagal melengkapi sisi OpenVPN untuk '${username}'."
      pause
      return 0
    fi
    ssh_ovpn_qac_state_sync_now_warn "${username}" || true
    openvpn_speed_sync_now_warn || true
    log "Sisi OpenVPN berhasil dilengkapi untuk '${username}'."
    ssh_ovpn_account_info_show "${username}" "3) SSH & OVPN User > ACCOUNT INFO"
    return 0
  fi

  if ! openvpn_client_render_artifacts_manage "${username}"; then
    warn "Gagal refresh file OpenVPN untuk '${username}'."
    pause
    return 0
  fi
  openvpn_account_info_refresh "${username}" || true
  openvpn_expiry_sync_now_warn "${username}" || true
  ssh_ovpn_qac_state_sync_now_warn "${username}" || true
  openvpn_speed_sync_now_warn || true

  log "File OpenVPN direfresh untuk '${username}'."
  ssh_ovpn_account_info_show "${username}" "3) SSH & OVPN User > ACCOUNT INFO"
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

def to_bool(v, default=False):
  if isinstance(v, bool):
    return v
  if isinstance(v, (int, float)):
    return bool(v)
  s = str(v or "").strip().lower()
  if not s:
    return bool(default)
  return s in ("1", "true", "yes", "on", "y")

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
    port = _parse_port(payload.get("backend_local_port") or name[:-5])
    if port <= 0:
      continue
    runtime_by_port[port] = {
      "username": norm_user(payload.get("username")),
      "client_ip": normalize_ip(payload.get("client_ip")) or "-",
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
      rows.append({
        "username": username,
        "peer": peer,
        "pid": str(pid),
        "client_ip": runtime_meta.get("client_ip") or "-",
        "_sort_pid": pid,
      })

for port, runtime_meta in sorted(runtime_by_port.items()):
  if port in runtime_ports_seen:
    continue
  rows.append({
    "username": runtime_meta.get("username") or "unknown",
    "peer": "runtime-port:{}".format(port),
    "pid": "-",
    "client_ip": runtime_meta.get("client_ip") or "-",
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
    row["client_ip"],
    row["peer"],
    str(row["pid"]),
    str(counts.get(row["username"], 1)),
    str(meta.get("reason") or "-"),
    str(meta.get("lock") or "OFF"),
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

  echo "Active SSH sessions: ${total} | page $((page + 1))/${display_pages}"
  if [[ -n "${SSHWS_SESSION_QUERY}" ]]; then
    echo "Filter: '${SSHWS_SESSION_QUERY}'"
  fi
  echo "Peer biasanya loopback mapping proxy -> dropbear. Jika korelasi socket gagal, runtime-port akan ditampilkan."
  echo

  if (( total == 0 )); then
    echo "Tidak ada sesi SSH WS aktif."
    return 0
  fi

  printf "%-4s %-18s %-16s %-21s %-7s %-6s %-10s %-6s\n" "NO" "Username" "Client IP" "Peer" "PID" "Sess" "Reason" "Lock"
  hr

  local start end i list_pos real_idx row username client_ip peer pid sess reason lock
  start=$((page * SSHWS_SESSION_PAGE_SIZE))
  end=$((start + SSHWS_SESSION_PAGE_SIZE))
  if (( end > total )); then
    end="${total}"
  fi
  for (( i=start; i<end; i++ )); do
    list_pos="${i}"
    real_idx="${SSHWS_SESSION_VIEW_INDEXES[$list_pos]}"
    row="${SSHWS_SESSION_ROWS[$real_idx]}"
    IFS='|' read -r username client_ip peer pid sess reason lock <<<"${row}"
    printf "%-4s %-18s %-16s %-21s %-7s %-6s %-10s %-6s\n" "$((i - start + 1))" "${username}" "${client_ip}" "${peer}" "${pid}" "${sess}" "${reason}" "${lock}"
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

  local list_pos real_idx row username client_ip peer pid sess reason lock
  list_pos=$((start + view_no - 1))
  real_idx="${SSHWS_SESSION_VIEW_INDEXES[$list_pos]}"
  row="${SSHWS_SESSION_ROWS[$real_idx]}"
  IFS='|' read -r username client_ip peer pid sess reason lock <<<"${row}"

  title
  echo "3) SSH & OVPN User > SSH Session Detail"
  hr
  printf "%-16s : %s\n" "Username" "${username}"
  printf "%-16s : %s\n" "Client IP" "${client_ip}"
  printf "%-16s : %s\n" "Peer" "${peer}"
  printf "%-16s : %s\n" "Dropbear PID" "${pid}"
  printf "%-16s : %s\n" "Active Sessions" "${sess}"
  printf "%-16s : %s\n" "Block Reason" "${reason}"
  printf "%-16s : %s\n" "Account Lock" "${lock}"

  local qf
  qf="$(ssh_user_state_file "${username}")"
  if [[ -f "${qf}" ]]; then
    local fields qssh_disp qovpn_disp ussh_disp uovpn_disp utotal_disp exp_date ip_state ip_lim _reason_ssh _reason_ovpn speed_state speed_down speed_up lock_state _access_ssh _access_ovpn _active_ssh _active_ovpn _active_total
    fields="$(ssh_qac_read_detail_fields "${qf}")"
    IFS='|' read -r _ qssh_disp qovpn_disp ussh_disp uovpn_disp utotal_disp exp_date ip_state ip_lim _reason_ssh _reason_ovpn speed_state speed_down speed_up lock_state _access_ssh _access_ovpn _active_ssh _active_ovpn _active_total <<<"${fields}"
    hr
    printf "%-16s : %s\n" "Quota SSH" "${qssh_disp}"
    printf "%-16s : %s\n" "Quota OVPN" "${qovpn_disp}"
    printf "%-16s : %s\n" "Used SSH" "${ussh_disp}"
    printf "%-16s : %s\n" "Used OVPN" "${uovpn_disp}"
    printf "%-16s : %s\n" "Used Total" "${utotal_disp}"
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
    echo "3) SSH & OVPN User > SSH Active Sessions"
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
  while true; do
    title
    echo "3) SSH & OVPN User"
    hr
    echo "  1) Add User"
    echo "  2) Delete User"
    echo "  3) Set Expiry"
    echo "  4) List Users"
    echo "  5) Refresh OVPN Files"
    echo "  6) SSH WS Status"
    echo "  7) OpenVPN Status"
    echo "  8) Restart SSH WS"
    echo "  9) Restart OpenVPN Core"
    echo "  10) Restart OpenVPN WS Proxy"
    echo "  11) SSH Active Sessions"
    echo "  12) OpenVPN Core Log"
    echo "  13) OpenVPN WS Proxy Log"
    echo "  0) Back"
    hr
    if ! read -r -p "Pilih: " c; then
      echo
      break
    fi
    case "${c}" in
      1) ssh_add_user_menu ;;
      2) ssh_delete_user_menu ;;
      3) ssh_extend_expiry_menu ;;
      4) ssh_list_users_menu ;;
      5) ssh_ovpn_refresh_ovpn_files_menu ;;
      6) sshws_status_menu "3) SSH & OVPN User > SSH WS Status" ;;
      7) openvpn_status_menu "3) SSH & OVPN User > OpenVPN Status" ;;
      8) sshws_restart_menu "3) SSH & OVPN User > Restart SSH WS" ;;
      9) openvpn_restart_core_menu "3) SSH & OVPN User > Restart OpenVPN Core" ;;
      10) openvpn_restart_ws_menu "3) SSH & OVPN User > Restart OpenVPN WS Proxy" ;;
      11) sshws_active_sessions_menu ;;
      12) daemon_log_tail_show "ovpn-tcp.service" 40 ;;
      13) daemon_log_tail_show "ovpnws-proxy.service" 40 ;;
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
      warn "Enforcer SSH & OVPN QAC gagal untuk '${target_user}'. Pastikan '${SSH_QAC_ENFORCER_BIN}' tersedia (bisa di-restore dari setup.sh)."
    else
      warn "Enforcer SSH & OVPN QAC gagal dijalankan. Pastikan '${SSH_QAC_ENFORCER_BIN}' tersedia (bisa di-restore dari setup.sh)."
    fi
    return 1
  fi
  return 0
}

ssh_qac_collect_files() {
  SSH_QAC_FILES=()
  ssh_state_dirs_prepare

  local f
  while IFS= read -r -d '' f; do
    SSH_QAC_FILES+=("${f}")
  done < <(find "${SSH_USERS_STATE_DIR}" -maxdepth 1 -type f -name '*.json' -print0 2>/dev/null | sort -z)
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
  # prints: username|quota_ssh_disp|quota_ovpn_disp|used_ssh_disp|used_ovpn_disp|expired_at_date|lock_state
  local qf="$1"
  need_python3
  python3 - <<'PY' "${qf}"
import json
import pathlib
import sys

p = pathlib.Path(sys.argv[1])
try:
  unified = json.loads(p.read_text(encoding="utf-8"))
  if not isinstance(unified, dict):
    unified = {}
except Exception:
  unified = {}
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

def to_bool(v, default=False):
  if isinstance(v, bool):
    return v
  if isinstance(v, (int, float)):
    return bool(v)
  s = str(v or "").strip().lower()
  if not s:
    return bool(default)
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

policy = unified.get("policy") if isinstance(unified.get("policy"), dict) else {}
runtime = unified.get("runtime") if isinstance(unified.get("runtime"), dict) else {}
derived = unified.get("derived") if isinstance(unified.get("derived"), dict) else {}
status = unified.get("status") if isinstance(unified.get("status"), dict) else {}

username = norm_user(unified.get("username") or username_fallback) or username_fallback
legacy_quota = to_int(policy.get("quota_limit_bytes"), to_int(unified.get("quota_limit"), 0))
quota_limit_ssh = to_int(policy.get("quota_limit_ssh_bytes"), legacy_quota)
quota_limit_ovpn = to_int(policy.get("quota_limit_ovpn_bytes"), legacy_quota)
quota_used_ssh = to_int(runtime.get("quota_used_ssh_bytes"), to_int(unified.get("quota_used"), 0))
quota_used_ovpn = to_int(runtime.get("quota_used_ovpn_bytes"), 0)
unit = str(policy.get("quota_unit") or unified.get("quota_unit") or "binary").strip().lower()
bpg = 1000**3 if unit in ("decimal", "gb", "1000", "gigabyte") else 1024**3
quota_ssh_disp = f"{fmt_gb(quota_limit_ssh / bpg)} GB"
quota_ovpn_disp = f"{fmt_gb(quota_limit_ovpn / bpg)} GB"
quota_used_ssh_disp = used_disp(quota_used_ssh)
quota_used_ovpn_disp = used_disp(quota_used_ovpn)
expired_at = str(policy.get("expired_at") or unified.get("expired_at") or "-").strip()
expired_date = expired_at[:10] if expired_at and expired_at != "-" else "-"
lock_disp = "ON" if (to_bool(status.get("manual_block")) or not to_bool(derived.get("access_effective_ssh"), True) or not to_bool(derived.get("access_effective_ovpn"), True)) else "OFF"

print(f"{username}|{quota_ssh_disp}|{quota_ovpn_disp}|{quota_used_ssh_disp}|{quota_used_ovpn_disp}|{expired_date}|{lock_disp}")
PY
}

ssh_qac_read_detail_fields() {
  # args: json_file
  # prints: username|quota_ssh_disp|quota_ovpn_disp|used_ssh_disp|used_ovpn_disp|used_total_disp|expired_at_date|ip_limit_onoff|ip_limit_value|reason_ssh|reason_ovpn|speed_onoff|speed_down_mbit|speed_up_mbit|lock_state|access_ssh|access_ovpn|active_ssh|active_ovpn|active_total
  local qf="$1"
  need_python3
  python3 - <<'PY' "${qf}"
import json
import pathlib
import sys

p = pathlib.Path(sys.argv[1])
try:
  unified = json.loads(p.read_text(encoding="utf-8"))
  if not isinstance(unified, dict):
    unified = {}
except Exception:
  unified = {}
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

def to_bool(v, default=False):
  if isinstance(v, bool):
    return v
  if isinstance(v, (int, float)):
    return bool(v)
  s = str(v or "").strip().lower()
  if not s:
    return bool(default)
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

policy = unified.get("policy") if isinstance(unified.get("policy"), dict) else {}
runtime = unified.get("runtime") if isinstance(unified.get("runtime"), dict) else {}
derived = unified.get("derived") if isinstance(unified.get("derived"), dict) else {}
status = unified.get("status") if isinstance(unified.get("status"), dict) else {}

username = norm_user(unified.get("username") or username_fallback) or username_fallback
legacy_quota = to_int(policy.get("quota_limit_bytes"), to_int(unified.get("quota_limit"), 0))
quota_limit_ssh = to_int(policy.get("quota_limit_ssh_bytes"), legacy_quota)
quota_limit_ovpn = to_int(policy.get("quota_limit_ovpn_bytes"), legacy_quota)
quota_used_ssh = to_int(runtime.get("quota_used_ssh_bytes"), to_int(unified.get("quota_used"), 0))
quota_used_ovpn = to_int(runtime.get("quota_used_ovpn_bytes"), 0)
quota_used_total = to_int(derived.get("quota_used_total_bytes"), quota_used_ssh + quota_used_ovpn)
active_ssh = to_int(runtime.get("active_session_ssh"), 0)
active_ovpn = to_int(runtime.get("active_session_ovpn"), 0)
active_total = to_int(derived.get("active_session_total"), active_ssh + active_ovpn)
unit = str(policy.get("quota_unit") or unified.get("quota_unit") or "binary").strip().lower()
bpg = 1000**3 if unit in ("decimal", "gb", "1000", "gigabyte") else 1024**3
quota_ssh_disp = f"{fmt_gb(quota_limit_ssh / bpg)} GB"
quota_ovpn_disp = f"{fmt_gb(quota_limit_ovpn / bpg)} GB"
quota_used_ssh_disp = used_disp(quota_used_ssh)
quota_used_ovpn_disp = used_disp(quota_used_ovpn)
quota_used_total_disp = used_disp(quota_used_total)
expired_at = str(policy.get("expired_at") or unified.get("expired_at") or "-").strip()
expired_date = expired_at[:10] if expired_at and expired_at != "-" else "-"
ip_enabled = to_bool(policy.get("ip_limit_enabled"))
ip_limit = to_int(policy.get("ip_limit"), to_int(status.get("ip_limit"), 0))
if ip_limit < 0:
  ip_limit = 0
reason_ssh = str(derived.get("last_reason_ssh") or derived.get("last_reason") or "-").strip()
reason_ovpn = str(derived.get("last_reason_ovpn") or derived.get("last_reason") or "-").strip()

speed_enabled = to_bool(policy.get("speed_limit_enabled"))
speed_down = to_float(policy.get("speed_down_mbit"), to_float(status.get("speed_down_mbit"), 0.0))
speed_up = to_float(policy.get("speed_up_mbit"), to_float(status.get("speed_up_mbit"), 0.0))
if speed_down < 0:
  speed_down = 0.0
if speed_up < 0:
  speed_up = 0.0

access_ssh = "ON" if to_bool(derived.get("access_effective_ssh"), True) else "OFF"
access_ovpn = "ON" if to_bool(derived.get("access_effective_ovpn"), True) else "OFF"
lock_disp = "ON" if (to_bool(status.get("manual_block")) or access_ssh == "OFF" or access_ovpn == "OFF") else "OFF"
print(
  f"{username}|{quota_ssh_disp}|{quota_ovpn_disp}|{quota_used_ssh_disp}|{quota_used_ovpn_disp}|{quota_used_total_disp}|{expired_date}|"
  f"{'ON' if ip_enabled else 'OFF'}|{ip_limit}|{reason_ssh}|{reason_ovpn}|"
  f"{'ON' if speed_enabled else 'OFF'}|{fmt_mbit(speed_down)}|{fmt_mbit(speed_up)}|{lock_disp}|{access_ssh}|{access_ovpn}|{active_ssh}|{active_ovpn}|{active_total}"
)
PY
}

ssh_qac_get_status_bool() {
  # args: json_file key
  local qf="$1"
  local key="$2"
  local username unified_file
  username="$(ssh_ovpn_qac_username_from_legacy_ssh_path "${qf}" 2>/dev/null || true)"
  unified_file="$(ssh_ovpn_qac_state_path "${username}" 2>/dev/null || true)"
  need_python3
  python3 - <<'PY' "${qf}" "${key}" "${unified_file}"
import json
import pathlib
import sys

qf, key, unified_path = sys.argv[1:4]
def load_json(path):
  if not path:
    return {}
  p = pathlib.Path(path)
  if not p.is_file():
    return {}
  try:
    loaded = json.loads(p.read_text(encoding="utf-8"))
    if isinstance(loaded, dict):
      return loaded
  except Exception:
    pass
  return {}

try:
  data = json.load(open(qf, "r", encoding="utf-8"))
except Exception:
  data = {}

if not isinstance(data, dict):
  data = {}

status = data.get("status")
if not isinstance(status, dict):
  status = {}
unified = load_json(unified_path)
policy = unified.get("policy") if isinstance(unified.get("policy"), dict) else {}
derived = unified.get("derived") if isinstance(unified.get("derived"), dict) else {}

val = None
  if unified:
    if key == "ip_limit_enabled":
      val = policy.get("ip_limit_enabled")
    elif key == "speed_limit_enabled":
      val = policy.get("speed_limit_enabled")
    elif key == "quota_exhausted":
      val = derived.get("quota_exhausted_ssh", derived.get("quota_exhausted"))
    elif key == "ip_limit_locked":
      val = derived.get("ip_limit_locked")
    elif key == "account_locked":
      val = not bool(derived.get("access_effective_ssh", policy.get("access_enabled", True)))
if val is None:
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
  local username unified_file
  username="$(ssh_ovpn_qac_username_from_legacy_ssh_path "${qf}" 2>/dev/null || true)"
  unified_file="$(ssh_ovpn_qac_state_path "${username}" 2>/dev/null || true)"
  need_python3
  python3 - <<'PY' "${qf}" "${key}" "${unified_file}"
import json
import pathlib
import sys

qf, key, unified_path = sys.argv[1:4]
def load_json(path):
  if not path:
    return {}
  p = pathlib.Path(path)
  if not p.is_file():
    return {}
  try:
    loaded = json.loads(p.read_text(encoding="utf-8"))
    if isinstance(loaded, dict):
      return loaded
  except Exception:
    pass
  return {}

try:
  data = json.load(open(qf, "r", encoding="utf-8"))
except Exception:
  data = {}

if not isinstance(data, dict):
  data = {}

status = data.get("status")
if not isinstance(status, dict):
  status = {}
unified = load_json(unified_path)
policy = unified.get("policy") if isinstance(unified.get("policy"), dict) else {}

val = None
if unified:
  if key == "ip_limit":
    val = policy.get("ip_limit")
  elif key == "speed_down_mbit":
    val = policy.get("speed_down_mbit")
  elif key == "speed_up_mbit":
    val = policy.get("speed_up_mbit")
if val is None:
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
import datetime
import fcntl
import json
import os
import pathlib
import sys
import tempfile

qf = sys.argv[1]
action = sys.argv[2]
lock_file = pathlib.Path(sys.argv[3] or "/run/autoscript/locks/sshws-qac.lock")
args = sys.argv[4:]

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

def to_bool(v, default=False):
  if isinstance(v, bool):
    return v
  if isinstance(v, (int, float)):
    return bool(v)
  s = str(v or "").strip().lower()
  if not s:
    return bool(default)
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

def date_is_active(value):
  text = str(value or "").strip()
  if not text or text == "-":
    return True
  try:
    expiry = datetime.datetime.strptime(text[:10], "%Y-%m-%d").date()
  except Exception:
    return True
  return expiry >= datetime.date.today()

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
  try:
    loaded = json.load(open(qf, "r", encoding="utf-8"))
    if isinstance(loaded, dict):
      payload = loaded
  except Exception:
    payload = {}

username_fallback = norm_user(pathlib.Path(qf).stem) or pathlib.Path(qf).stem
payload["version"] = 1
payload["managed_by"] = str(payload.get("managed_by") or "autoscript-manage").strip() or "autoscript-manage"
payload["protocol"] = str(payload.get("protocol") or "ssh-ovpn").strip() or "ssh-ovpn"
payload["username"] = norm_user(payload.get("username") or username_fallback) or username_fallback

meta = payload.get("meta") if isinstance(payload.get("meta"), dict) else {}
policy = payload.get("policy") if isinstance(payload.get("policy"), dict) else {}
runtime = payload.get("runtime") if isinstance(payload.get("runtime"), dict) else {}
derived = payload.get("derived") if isinstance(payload.get("derived"), dict) else {}
status_raw = payload.get("status")
status = status_raw if isinstance(status_raw, dict) else {}

created_at = str(payload.get("created_at") or meta.get("created_at") or "-").strip() or "-"
expired_at = str(payload.get("expired_at") or policy.get("expired_at") or "-").strip()[:10] or "-"
legacy_quota_limit = max(0, to_int(policy.get("quota_limit_bytes"), to_int(payload.get("quota_limit"), 0)))
quota_limit_ssh = max(0, to_int(policy.get("quota_limit_ssh_bytes"), legacy_quota_limit))
quota_limit_ovpn = max(0, to_int(policy.get("quota_limit_ovpn_bytes"), legacy_quota_limit))
quota_unit = str(policy.get("quota_unit") or payload.get("quota_unit") or "binary").strip().lower()
if quota_unit not in ("binary", "decimal"):
  quota_unit = "binary"
quota_used_ssh = max(0, to_int(runtime.get("quota_used_ssh_bytes"), 0))
quota_used_ovpn = max(0, to_int(runtime.get("quota_used_ovpn_bytes"), 0))
active_ssh = max(0, to_int(runtime.get("active_session_ssh"), 0))
active_ovpn = max(0, to_int(runtime.get("active_session_ovpn"), 0))

status["manual_block"] = to_bool(status.get("manual_block"))
status["account_locked"] = to_bool(status.get("account_locked"))
status["lock_owner"] = str(status.get("lock_owner") or "").strip()
status["lock_shell_restore"] = str(status.get("lock_shell_restore") or "").strip()

policy["quota_limit_bytes"] = quota_limit_ssh
policy["quota_limit_ssh_bytes"] = quota_limit_ssh
policy["quota_limit_ovpn_bytes"] = quota_limit_ovpn
policy["quota_unit"] = quota_unit
policy["expired_at"] = expired_at
policy["access_enabled"] = to_bool(policy.get("access_enabled"), True)
policy["ip_limit_enabled"] = to_bool(policy.get("ip_limit_enabled"), status.get("ip_limit_enabled"))
policy["ip_limit"] = max(0, to_int(policy.get("ip_limit"), to_int(status.get("ip_limit"), 0)))
policy["speed_limit_enabled"] = to_bool(policy.get("speed_limit_enabled"), status.get("speed_limit_enabled"))
policy["speed_down_mbit"] = max(0.0, to_float(policy.get("speed_down_mbit"), to_float(status.get("speed_down_mbit"), 0.0)))
policy["speed_up_mbit"] = max(0.0, to_float(policy.get("speed_up_mbit"), to_float(status.get("speed_up_mbit"), 0.0)))

if action in ("set_quota_limit", "set_quota_ssh_limit"):
  if len(args) != 1:
    raise SystemExit("set_quota_ssh_limit butuh 1 argumen (bytes)")
  policy["quota_limit_ssh_bytes"] = parse_int(args[0], "quota_limit_ssh", 0)
  policy["quota_limit_bytes"] = policy["quota_limit_ssh_bytes"]
elif action == "set_quota_ovpn_limit":
  if len(args) != 1:
    raise SystemExit("set_quota_ovpn_limit butuh 1 argumen (bytes)")
  policy["quota_limit_ovpn_bytes"] = parse_int(args[0], "quota_limit_ovpn", 0)
elif action in ("reset_quota_used", "reset_quota_ssh_used"):
  runtime["quota_used_ssh_bytes"] = 0
  derived["quota_exhausted"] = False
  derived["quota_exhausted_ssh"] = False
elif action == "reset_quota_ovpn_used":
  runtime["quota_used_ovpn_bytes"] = 0
  derived["quota_exhausted_ovpn"] = False
elif action == "manual_block_set":
  if len(args) != 1:
    raise SystemExit("manual_block_set butuh 1 argumen (on/off)")
  status["manual_block"] = bool(parse_onoff(args[0]))
elif action == "ip_limit_enabled_set":
  if len(args) != 1:
    raise SystemExit("ip_limit_enabled_set butuh 1 argumen (on/off)")
  enabled = bool(parse_onoff(args[0]))
  policy["ip_limit_enabled"] = enabled
  if not enabled:
    derived["ip_limit_locked"] = False
elif action == "set_ip_limit":
  if len(args) != 1:
    raise SystemExit("set_ip_limit butuh 1 argumen (angka)")
  policy["ip_limit"] = parse_int(args[0], "ip_limit", 1)
elif action == "clear_ip_limit_locked":
  derived["ip_limit_locked"] = False
elif action == "set_speed_down":
  if len(args) != 1:
    raise SystemExit("set_speed_down butuh 1 argumen (Mbps)")
  policy["speed_down_mbit"] = parse_float(args[0], "speed_down_mbit", 0.000001)
elif action == "set_speed_up":
  if len(args) != 1:
    raise SystemExit("set_speed_up butuh 1 argumen (Mbps)")
  policy["speed_up_mbit"] = parse_float(args[0], "speed_up_mbit", 0.000001)
elif action == "speed_limit_set":
  if len(args) != 1:
    raise SystemExit("speed_limit_set butuh 1 argumen (on/off)")
  policy["speed_limit_enabled"] = bool(parse_onoff(args[0]))
elif action == "set_speed_all_enable":
  if len(args) != 2:
    raise SystemExit("set_speed_all_enable butuh 2 argumen (down up)")
  policy["speed_down_mbit"] = parse_float(args[0], "speed_down_mbit", 0.000001)
  policy["speed_up_mbit"] = parse_float(args[1], "speed_up_mbit", 0.000001)
  policy["speed_limit_enabled"] = True
else:
  raise SystemExit(f"aksi ssh_qac_atomic_update_file tidak dikenali: {action}")

quota_used_ssh = max(0, int(runtime.get("quota_used_ssh_bytes", quota_used_ssh)))
quota_used_ovpn = max(0, int(runtime.get("quota_used_ovpn_bytes", quota_used_ovpn)))
quota_used_total = quota_used_ssh + quota_used_ovpn
active_total = max(0, int(runtime.get("active_session_ssh", active_ssh))) + max(0, int(runtime.get("active_session_ovpn", active_ovpn)))
quota_exhausted_ssh = bool(policy["quota_limit_ssh_bytes"] > 0 and quota_used_ssh >= policy["quota_limit_ssh_bytes"])
quota_exhausted_ovpn = bool(policy["quota_limit_ovpn_bytes"] > 0 and quota_used_ovpn >= policy["quota_limit_ovpn_bytes"])
ip_limit_locked = bool(policy["ip_limit_enabled"] and policy["ip_limit"] > 0 and active_total > policy["ip_limit"])
if status.get("manual_block"):
  last_reason_ssh = "manual"
  last_reason_ovpn = "manual"
elif not bool(policy.get("access_enabled", True)):
  last_reason_ssh = "access_off"
  last_reason_ovpn = "access_off"
elif not date_is_active(expired_at):
  last_reason_ssh = "expired"
  last_reason_ovpn = "expired"
elif ip_limit_locked:
  last_reason_ssh = "ip_limit"
  last_reason_ovpn = "ip_limit"
else:
  last_reason_ssh = "quota_ssh" if quota_exhausted_ssh else "-"
  last_reason_ovpn = "quota_ovpn" if quota_exhausted_ovpn else "-"
if last_reason_ssh not in ("", "-"):
  last_reason = last_reason_ssh
elif last_reason_ovpn not in ("", "-"):
  last_reason = last_reason_ovpn
else:
  last_reason = "-"

shared_access = bool(policy.get("access_enabled", True) and date_is_active(expired_at) and not ip_limit_locked and not status.get("manual_block"))

derived["quota_used_total_bytes"] = quota_used_total
derived["active_session_total"] = active_total
derived["quota_exhausted"] = quota_exhausted_ssh
derived["quota_exhausted_ssh"] = quota_exhausted_ssh
derived["quota_exhausted_ovpn"] = quota_exhausted_ovpn
derived["ip_limit_locked"] = ip_limit_locked
derived["last_reason"] = last_reason
derived["last_reason_ssh"] = last_reason_ssh
derived["last_reason_ovpn"] = last_reason_ovpn
derived["access_effective"] = bool(shared_access and not quota_exhausted_ssh)
derived["access_effective_ssh"] = bool(shared_access and not quota_exhausted_ssh)
derived["access_effective_ovpn"] = bool(shared_access and not quota_exhausted_ovpn)

status["quota_exhausted"] = quota_exhausted_ssh
status["ip_limit_enabled"] = bool(policy["ip_limit_enabled"])
status["ip_limit"] = int(policy["ip_limit"])
status["ip_limit_locked"] = ip_limit_locked
status["speed_limit_enabled"] = bool(policy["speed_limit_enabled"])
status["speed_down_mbit"] = float(policy["speed_down_mbit"])
status["speed_up_mbit"] = float(policy["speed_up_mbit"])
status["lock_reason"] = last_reason

meta["created_at"] = created_at
payload["meta"] = meta
payload["policy"] = policy
payload["runtime"] = runtime
payload["derived"] = derived
payload["status"] = status
payload["created_at"] = created_at
payload["expired_at"] = expired_at
payload["quota_limit"] = int(policy["quota_limit_ssh_bytes"])
payload["quota_unit"] = quota_unit
payload["quota_used"] = quota_used_ssh

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
  local username
  shift 2 || true
  ssh_qac_atomic_update_file_unlocked "${qf}" "${action}" "$@" || return $?
  username="$(ssh_ovpn_qac_username_from_legacy_ssh_path "${qf}" 2>/dev/null || true)"
  if [[ -n "${username}" ]]; then
    ssh_ovpn_qac_state_sync_now "${username}" || true
  fi
  return 0
}

ssh_qac_view_json() {
  local qf="$1"
  local username unified_file view_file
  username="$(ssh_ovpn_qac_username_from_legacy_ssh_path "${qf}" 2>/dev/null || true)"
  unified_file="$(ssh_ovpn_qac_state_path "${username}" 2>/dev/null || true)"
  view_file="${qf}"
  if [[ -n "${unified_file}" && -f "${unified_file}" ]]; then
    view_file="${unified_file}"
  fi
  title
  echo "SSH & OVPN QAC metadata: ${view_file}"
  hr
  need_python3
  if have_cmd less; then
    python3 - <<'PY' "${view_file}" | less -R
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
    python3 - <<'PY' "${view_file}"
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

  echo "Managed users: ${total} | page $((page + 1))/${display_pages}"
  if [[ -n "${SSH_QAC_QUERY}" ]]; then
    echo "Filter: '${SSH_QAC_QUERY}'"
  fi
  echo

  if (( total == 0 )); then
    echo "Belum ada data SSH & OVPN QAC."
    return 0
  fi

  printf "%-4s %-18s %-10s %-10s %-11s %-11s %-6s\n" "NO" "Username" "Q SSH" "Q OVPN" "U SSH" "U OVPN" "Lock"
  hr

  local start end i list_pos real_idx qf fields username qssh qovpn ussh uovpn _exp lock
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
    IFS='|' read -r username qssh qovpn ussh uovpn _exp lock <<<"${fields}"
    printf "%-4s %-18s %-10s %-10s %-11s %-11s %-6s\n" "$((i - start + 1))" "${username}" "${qssh}" "${qovpn}" "${ussh}" "${uovpn}" "${lock}"
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

  while true; do
    title
    echo "5) SSH & OVPN QAC > Detail"
    hr
    echo "File  : ${qf}"
    hr

    local fields username qssh_disp qovpn_disp ussh_disp uovpn_disp utotal_disp exp_date ip_state ip_lim reason_ssh reason_ovpn speed_state speed_down speed_up lock_state access_ssh access_ovpn active_ssh active_ovpn active_total
    fields="$(ssh_qac_read_detail_fields "${qf}")"
    IFS='|' read -r username qssh_disp qovpn_disp ussh_disp uovpn_disp utotal_disp exp_date ip_state ip_lim reason_ssh reason_ovpn speed_state speed_down speed_up lock_state access_ssh access_ovpn active_ssh active_ovpn active_total <<<"${fields}"

    local label_w=18
    printf "%-${label_w}s : %s\n" "Username" "${username}"
    printf "%-${label_w}s : %s\n" "Quota SSH" "${qssh_disp}"
    printf "%-${label_w}s : %s\n" "Quota OVPN" "${qovpn_disp}"
    printf "%-${label_w}s : %s\n" "Used SSH" "${ussh_disp}"
    printf "%-${label_w}s : %s\n" "Used OVPN" "${uovpn_disp}"
    printf "%-${label_w}s : %s\n" "Used Total" "${utotal_disp}"
    printf "%-${label_w}s : %s\n" "Expired At" "${exp_date}"
    printf "%-${label_w}s : %s\n" "IP/Login Limit" "${ip_state}"
    printf "%-${label_w}s : %s\n" "IP/Login Limit Max" "${ip_lim}"
    printf "%-${label_w}s : %s\n" "Reason SSH" "${reason_ssh}"
    printf "%-${label_w}s : %s\n" "Reason OVPN" "${reason_ovpn}"
    printf "%-${label_w}s : %s\n" "Account Locked" "${lock_state}"
    printf "%-${label_w}s : %s\n" "Access SSH" "${access_ssh}"
    printf "%-${label_w}s : %s\n" "Access OVPN" "${access_ovpn}"
    printf "%-${label_w}s : %s\n" "Active SSH Sessions" "${active_ssh}"
    printf "%-${label_w}s : %s\n" "Active OVPN Sessions" "${active_ovpn}"
    printf "%-${label_w}s : %s\n" "Active Total" "${active_total}"
    printf "%-${label_w}s : %s Mbps\n" "Speed Download" "${speed_down}"
    printf "%-${label_w}s : %s Mbps\n" "Speed Upload" "${speed_up}"
    printf "%-${label_w}s : %s\n" "Speed Limit" "${speed_state}"
    printf "%-${label_w}s : %s\n" "Traffic Scope" "$(ssh_qac_traffic_scope_label)"
    hr

    echo "  1) View JSON"
    echo "  2) Set Quota SSH (GB)"
    echo "  3) Reset Quota SSH"
    echo "  4) Set Quota OVPN (GB)"
    echo "  5) Reset Quota OVPN"
    echo "  6) Toggle Block"
    echo "  7) Toggle IP/Login Limit"
    echo "  8) Set IP/Login Limit"
    echo "  9) Unlock IP/Login"
    echo " 10) Set Speed Download"
    echo " 11) Set Speed Upload"
    echo " 12) Speed Limit Enable/Disable (toggle)"
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
        if ! read -r -p "Quota SSH (GB) (atau kembali): " gb; then
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
        if ! ssh_qac_atomic_update_file "${qf}" set_quota_ssh_limit "${qb}"; then
          warn "Gagal update quota SSH."
          pause
          continue
        fi
        ssh_qac_enforce_now_warn "${username}" || true
        openvpn_expiry_sync_now_warn "${username}" || true
        ssh_account_info_refresh_warn "${username}" || true
        log "Quota SSH diubah: ${gb_num} GB"
        pause
        ;;
      3)
        if ! ssh_qac_atomic_update_file "${qf}" reset_quota_ssh_used; then
          warn "Gagal reset quota used SSH."
          pause
          continue
        fi
        ssh_qac_enforce_now_warn "${username}" || true
        openvpn_expiry_sync_now_warn "${username}" || true
        ssh_account_info_refresh_warn "${username}" || true
        log "Quota used SSH di-reset: 0"
        pause
        ;;
      4)
        if ! read -r -p "Quota OVPN (GB) (atau kembali): " gb; then
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
        local gb_ovpn_num qb_ovpn
        gb_ovpn_num="$(normalize_gb_input "${gb}")"
        if [[ -z "${gb_ovpn_num}" ]]; then
          warn "Format quota tidak valid. Contoh: 5 atau 5GB"
          pause
          continue
        fi
        qb_ovpn="$(bytes_from_gb "${gb_ovpn_num}")"
        if ! ssh_qac_atomic_update_file "${qf}" set_quota_ovpn_limit "${qb_ovpn}"; then
          warn "Gagal update quota OVPN."
          pause
          continue
        fi
        ssh_qac_enforce_now_warn "${username}" || true
        openvpn_expiry_sync_now_warn "${username}" || true
        ssh_account_info_refresh_warn "${username}" || true
        openvpn_account_info_refresh "${username}" || true
        log "Quota OVPN diubah: ${gb_ovpn_num} GB"
        pause
        ;;
      5)
        if ! ssh_qac_atomic_update_file "${qf}" reset_quota_ovpn_used; then
          warn "Gagal reset quota used OVPN."
          pause
          continue
        fi
        ssh_qac_enforce_now_warn "${username}" || true
        openvpn_expiry_sync_now_warn "${username}" || true
        ssh_account_info_refresh_warn "${username}" || true
        openvpn_account_info_refresh "${username}" || true
        log "Quota used OVPN di-reset: 0"
        pause
        ;;
      6)
        local st_mb
        st_mb="$(ssh_qac_get_status_bool "${qf}" "manual_block")"
        if [[ "${st_mb}" == "true" ]]; then
          if ! ssh_qac_atomic_update_file "${qf}" manual_block_set off; then
          warn "Gagal menonaktifkan manual block SSH & OVPN."
            pause
            continue
          fi
          ssh_qac_enforce_now_warn "${username}" || true
          openvpn_expiry_sync_now_warn "${username}" || true
          ssh_account_info_refresh_warn "${username}" || true
          log "Manual block SSH & OVPN: OFF"
        else
          if ! ssh_qac_atomic_update_file "${qf}" manual_block_set on; then
          warn "Gagal mengaktifkan manual block SSH & OVPN."
            pause
            continue
          fi
          ssh_qac_enforce_now_warn "${username}" || true
          openvpn_expiry_sync_now_warn "${username}" || true
          ssh_account_info_refresh_warn "${username}" || true
          log "Manual block SSH & OVPN: ON"
        fi
        pause
        ;;
      7)
        local ip_on
        ip_on="$(ssh_qac_get_status_bool "${qf}" "ip_limit_enabled")"
        if [[ "${ip_on}" == "true" ]]; then
          if ! ssh_qac_atomic_update_file "${qf}" ip_limit_enabled_set off; then
            warn "Gagal menonaktifkan IP/Login limit SSH & OVPN."
            pause
            continue
          fi
          ssh_qac_enforce_now_warn "${username}" || true
          openvpn_expiry_sync_now_warn "${username}" || true
          ssh_account_info_refresh_warn "${username}" || true
          log "IP/Login limit SSH & OVPN: OFF"
        else
          if ! ssh_qac_atomic_update_file "${qf}" ip_limit_enabled_set on; then
            warn "Gagal mengaktifkan IP/Login limit SSH & OVPN."
            pause
            continue
          fi
          ssh_qac_enforce_now_warn "${username}" || true
          openvpn_expiry_sync_now_warn "${username}" || true
          ssh_account_info_refresh_warn "${username}" || true
          log "IP/Login limit SSH & OVPN: ON"
        fi
        pause
        ;;
      8)
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
        if ! ssh_qac_atomic_update_file "${qf}" set_ip_limit "${lim}"; then
          warn "Gagal set IP/Login limit SSH & OVPN."
          pause
          continue
        fi
        ssh_qac_enforce_now_warn "${username}" || true
        openvpn_expiry_sync_now_warn "${username}" || true
        ssh_account_info_refresh_warn "${username}" || true
        log "IP/Login limit SSH & OVPN diubah: ${lim}"
        pause
        ;;
      9)
        if ! ssh_qac_atomic_update_file "${qf}" clear_ip_limit_locked; then
          warn "Gagal unlock IP/Login lock SSH & OVPN."
          pause
          continue
        fi
        ssh_qac_enforce_now_warn "${username}" || true
        openvpn_expiry_sync_now_warn "${username}" || true
        ssh_account_info_refresh_warn "${username}" || true
        log "IP/Login lock SSH & OVPN di-unlock"
        pause
        ;;
      10)
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
        if ! ssh_qac_atomic_update_file "${qf}" set_speed_down "${speed_down_input}"; then
          warn "Gagal set speed download SSH."
          pause
          continue
        fi
        ssh_ovpn_qac_state_sync_now_warn "${username}" || true
        ssh_qac_enforce_now_warn "${username}" || true
        openvpn_speed_sync_now_warn || true
        ssh_account_info_refresh_warn "${username}" || true
        log "Speed download SSH diubah: ${speed_down_input} Mbps"
        pause
        ;;
      11)
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
        if ! ssh_qac_atomic_update_file "${qf}" set_speed_up "${speed_up_input}"; then
          warn "Gagal set speed upload SSH."
          pause
          continue
        fi
        ssh_ovpn_qac_state_sync_now_warn "${username}" || true
        ssh_qac_enforce_now_warn "${username}" || true
        openvpn_speed_sync_now_warn || true
        ssh_account_info_refresh_warn "${username}" || true
        log "Speed upload SSH diubah: ${speed_up_input} Mbps"
        pause
        ;;
      12)
        local speed_on speed_down_now speed_up_now
        speed_on="$(ssh_qac_get_status_bool "${qf}" "speed_limit_enabled")"
        if [[ "${speed_on}" == "true" ]]; then
          if ! ssh_qac_atomic_update_file "${qf}" speed_limit_set off; then
          warn "Gagal menonaktifkan speed limit SSH & OVPN."
            pause
            continue
          fi
          ssh_ovpn_qac_state_sync_now_warn "${username}" || true
          ssh_qac_enforce_now_warn "${username}" || true
          openvpn_speed_sync_now_warn || true
          ssh_account_info_refresh_warn "${username}" || true
          log "Speed limit SSH & OVPN: OFF"
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

        if ! ssh_qac_atomic_update_file "${qf}" set_speed_all_enable "${speed_down_now}" "${speed_up_now}"; then
          warn "Gagal mengaktifkan speed limit SSH & OVPN."
          pause
          continue
        fi
        ssh_ovpn_qac_state_sync_now_warn "${username}" || true
        ssh_qac_enforce_now_warn "${username}" || true
        openvpn_speed_sync_now_warn || true
        ssh_account_info_refresh_warn "${username}" || true
        log "Speed limit SSH & OVPN: ON"
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
    title
    echo "5) SSH & OVPN QAC"
    hr

    ssh_qac_enforce_now_warn || true
    ssh_qac_collect_files
    ssh_qac_build_view_indexes
    ssh_qac_print_table_page "${SSH_QAC_PAGE}"
    hr

    echo "Masukkan NO untuk view/edit, atau ketik:"
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
  echo "10) Maintenance > Log ${svc}"
  hr
  if svc_exists "${svc}"; then
    journalctl -u "${svc}" --no-pager -n "${lines}" 2>/dev/null || true
  else
    warn "${svc}.service tidak terpasang"
  fi
  hr
  pause
}

install_discord_bot_menu() {
  local installer_cmd="/usr/local/bin/install-discord-bot"
  title
  echo "12) Discord Bot"
  hr

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
  hr
  if ! "${installer_cmd}" menu; then
    warn "Installer bot Discord keluar dengan status error."
    hr
    pause
  fi
  return 0
}

install_telegram_bot_menu() {
  local installer_cmd="/usr/local/bin/install-telegram-bot"
  title
  echo "13) Telegram Bot"
  hr

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
  hr
  if ! "${installer_cmd}" menu; then
    warn "Installer bot Telegram keluar dengan status error."
    hr
    pause
  fi
  return 0
}

daemon_status_menu() {
  title
  echo "10) Maintenance > Xray Daemons"
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
  echo " 10) Restart ${sshws_dropbear_svc}"
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
      if svc_exists xray-expired; then svc_restart xray-expired ; else warn "xray-expired tidak terpasang" ; fi
      pause
      ;;
    2)
      if svc_exists xray-quota; then svc_restart xray-quota ; else warn "xray-quota tidak terpasang" ; fi
      pause
      ;;
    3)
      if svc_exists xray-limit-ip; then svc_restart xray-limit-ip ; else warn "xray-limit-ip tidak terpasang" ; fi
      pause
      ;;
    4)
      if svc_exists xray-speed; then svc_restart xray-speed ; else warn "xray-speed tidak terpasang" ; fi
      pause
      ;;
    5)
      for d in xray-expired xray-quota xray-limit-ip xray-speed; do
        if svc_exists "${d}"; then
          svc_restart "${d}"
        else
          warn "${d} tidak terpasang, skip"
        fi
      done
      pause
      ;;
    6) daemon_log_tail_show xray-expired 20 ;;
    7) daemon_log_tail_show xray-quota 20 ;;
    8) daemon_log_tail_show xray-limit-ip 20 ;;
    9) daemon_log_tail_show xray-speed 20 ;;
    10)
      if svc_exists "${sshws_dropbear_svc}"; then svc_restart "${sshws_dropbear_svc}" ; else warn "${sshws_dropbear_svc} tidak terpasang" ; fi
      pause
      ;;
    11)
      if svc_exists "${sshws_stunnel_svc}"; then svc_restart "${sshws_stunnel_svc}" ; else warn "${sshws_stunnel_svc} tidak terpasang" ; fi
      pause
      ;;
    12)
      if svc_exists "${sshws_proxy_svc}"; then svc_restart "${sshws_proxy_svc}" ; else warn "${sshws_proxy_svc} tidak terpasang" ; fi
      pause
      ;;
    13)
      for d in "${sshws_dropbear_svc}" "${sshws_stunnel_svc}" "${sshws_proxy_svc}"; do
        if svc_exists "${d}"; then
          svc_restart "${d}"
        else
          warn "${d} tidak terpasang, skip"
        fi
      done
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
