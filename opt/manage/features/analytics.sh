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
  "generated_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
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
  echo "11) Traffic Analytics > Overview"
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
  echo "11) Traffic Analytics > Top Users by Usage"
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
  echo "11) Traffic Analytics > Search User Traffic"
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
  echo "11) Traffic Analytics > Export JSON Report"
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
    echo "11) Traffic Analytics"
    hr
    echo "  1) Overview"
    echo "  2) Top Users by Usage"
    echo "  3) Search User Traffic"
    echo "  4) Export JSON Report"
    echo "  0) Kembali"
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
# - TLS & Certificate
# - Fail2ban Protection
# - System Hardening Status
# - Security Overview
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
  openssl x509 -in "${CERT_FULLCHAIN}" -noout     -subject -issuer -serial -startdate -enddate -fingerprint -sha256 2>/dev/null || return 1
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
  echo "TLS & Certificate > Show Certificate Info"
  hr
  if ! cert_openssl_info; then
    warn "Gagal membaca info sertifikat"
  fi
  hr
  pause
}

cert_menu_check_expiry() {
  title
  echo "TLS & Certificate > Check Expiry"
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

cert_menu_renew() {
  title
  echo "TLS & Certificate > Renew Certificate"
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
      local svc
      for svc in nginx apache2 caddy lighttpd; do
        if svc_exists "${svc}" && svc_is_active "${svc}"; then
          stopped_services+=("${svc}")
          systemctl stop "${svc}" >/dev/null 2>&1 || true
        fi
      done

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
  log "Renew certificate selesai (cek expiry untuk memastikan)."
  hr
  pause
}

cert_menu_reload_nginx() {
  title
  echo "TLS & Certificate > Reload Nginx"
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
    echo "TLS & Certificate"
    hr
    echo "  1) Show Certificate Info"
    echo "  2) Check Expiry"
    echo "  3) Renew Certificate"
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
  echo "Fail2ban Protection > Show Jail Status"
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
  echo "Fail2ban Protection > Show Banned IP"
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
  echo "Fail2ban Protection > Unban IP"
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
  echo "Fail2ban Protection > Restart Fail2ban"
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
    echo "Fail2ban Protection"
    hr
    echo "  1) Show Jail Status"
    echo "  2) Show Banned IP"
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
  echo "System Hardening Status > Check BBR"
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
  echo "System Hardening Status > Check Swap"
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
  echo "System Hardening Status > Check Ulimit"
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
  echo "System Hardening Status > Check Chrony"
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
    echo "System Hardening Status"
    hr
    echo "  1) Check BBR"
    echo "  2) Check Swap"
    echo "  3) Check Ulimit"
    echo "  4) Check Chrony"
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
  echo "Security Overview"
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
    echo "  1) TLS & Certificate"
    echo "  2) Fail2ban Protection"
    echo "  3) System Hardening Status"
    echo "  4) Security Overview"
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
  echo "10) Maintenance > Wireproxy (WARP) Status"
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
    uptime_str="$(ps -o etime= -p "${pid}" 2>/dev/null | tr -d ' ' || true)"
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
  echo "10) Maintenance > Restart Wireproxy (WARP)"
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
  echo "10) Maintenance > SSH WS Status"
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
  title
  echo "10) Maintenance > Restart SSH WS Stack"
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

ssh_username_valid() {
  local username="${1:-}"
  [[ "${username}" =~ ^[a-z_][a-z0-9_-]{1,31}$ ]]
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
  case "${SSH_ACCOUNT_INFO_STORE_PASSWORD:-0}" in
    1|true|yes|on|y)
      echo "store"
      ;;
    *)
      echo "mask"
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

ssh_user_state_file() {
  local username="${1:-}"
  printf '%s/%s@ssh.json\n' "${SSH_USERS_STATE_DIR}" "${username}"
}

ssh_account_info_file() {
  local username="${1:-}"
  printf '%s/%s@ssh.txt\n' "${SSH_ACCOUNT_DIR}" "${username}"
}

ssh_user_state_created_at_get() {
  local username="${1:-}"
  local state_file
  ssh_state_dirs_prepare
  state_file="$(ssh_user_state_file "${username}")"
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
  state_file="$(ssh_user_state_file "${username}")"
  ssh_state_dirs_prepare
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
if not created:
  created = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")

expired = norm_date(expired_at) or norm_date(payload.get("expired_at")) or "-"

payload["managed_by"] = "autoscript-manage"
payload["username"] = username
payload["protocol"] = "ssh"
payload["created_at"] = created
payload["expired_at"] = expired
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
if not created:
  created = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")

expired = norm_date(expired_at) or norm_date(payload.get("expired_at")) or "-"

payload["managed_by"] = "autoscript-manage"
payload["username"] = username
payload["protocol"] = "ssh"
payload["created_at"] = created
payload["expired_at"] = expired
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

ssh_account_info_write() {
  # args: username password quota_bytes expired_at created_at ip_enabled ip_limit speed_enabled speed_down speed_up
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

  ssh_state_dirs_prepare
  password_mode="$(ssh_account_info_password_mode)"
  if [[ "${password_mode}" == "store" ]]; then
    password_out="${password_raw:-"-"}"
  else
    # Pada mode mask, selalu tampil hidden agar konsisten di setiap refresh.
    password_out="(hidden)"
  fi

  local acc_file domain ip quota_limit_disp expired_disp valid_until ip_disp speed_disp
  acc_file="$(ssh_account_info_file "${username}")"
  domain="$(detect_domain)"
  ip="$(detect_public_ip_ipapi)"
  [[ -n "${ip}" ]] || ip="$(detect_public_ip)"
  [[ -n "${domain}" ]] || domain="-"
  [[ -n "${ip}" ]] || ip="-"
  [[ -n "${created_at}" ]] || created_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
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

  if ! cat > "${acc_file}" <<EOF
=== SSH ACCOUNT INFO ===
Domain      : ${domain}
IP          : ${ip}
Username    : ${username}
Password    : ${password_out}
Quota Limit : ${quota_limit_disp}
Expired     : ${expired_disp}
Valid Until : ${valid_until}
Created     : ${created_at}
IP Limit    : ${ip_disp}
Speed Limit : ${speed_disp}

Standard Payload:
Payload WSS:
    GET / HTTP/1.1[crlf]Host: [host_port][crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf]Sec-WebSocket-Version: 13[crlf]Sec-WebSocket-Key: [sec_key_base64][crlf][crlf]

Payload WS:
    GET / HTTP/1.1[crlf]Host: [host_port][crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf]Sec-WebSocket-Version: 13[crlf]Sec-WebSocket-Key: [sec_key_base64][crlf][crlf]
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
  qf="$(ssh_user_state_file "${username}")"
  [[ -f "${qf}" ]] || return 1

  local fields quota_bytes expired_at created_at ip_enabled ip_limit speed_enabled speed_down speed_up password
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
]))
PY
)"
  IFS='|' read -r quota_bytes expired_at created_at ip_enabled ip_limit speed_enabled speed_down speed_up <<<"${fields}"

  password="${password_override}"
  if [[ -z "${password}" ]]; then
    password="$(ssh_account_info_password_get "${username}")"
  fi

  ssh_account_info_write "${username}" "${password}" "${quota_bytes}" "${expired_at}" "${created_at}" "${ip_enabled}" "${ip_limit}" "${speed_enabled}" "${speed_down}" "${speed_up}"
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

ssh_add_user_menu() {
  title
  echo "3) SSH Management > Add SSH User"
  hr

  local username qf acc_file
  if ! read -r -p "Username SSH (atau kembali): " username; then
    echo
    return 0
  fi
  if is_back_choice "${username}"; then
    return 0
  fi
  username="${username,,}"
  if ! ssh_username_valid "${username}"; then
    warn "Username tidak valid. Gunakan format Linux user (huruf kecil/angka/_/-)."
    pause
    return 0
  fi
  if id "${username}" >/dev/null 2>&1; then
    warn "User '${username}' sudah ada."
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

  local active_days
  if ! read -r -p "Masa aktif SSH (hari) (atau kembali): " active_days; then
    echo
    return 0
  fi
  if is_back_choice "${active_days}"; then
    return 0
  fi
  if [[ -z "${active_days}" || ! "${active_days}" =~ ^[0-9]+$ || "${active_days}" -le 0 ]]; then
    warn "Masa aktif SSH harus angka hari > 0."
    pause
    return 0
  fi

  local quota_input quota_gb quota_bytes
  if ! read -r -p "Quota (GB) (0=unlimited) (atau kembali): " quota_input; then
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
  if ! read -r -p "Limit IP (on/off) (atau kembali): " ip_toggle; then
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
  if ! read -r -p "Limit speed per user SSH (on/off) (atau kembali): " speed_toggle; then
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
      if ! read -r -p "Speed Download (Mbps) (contoh: 20 atau 20mbit) (atau kembali): " speed_down; then
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

      if ! read -r -p "Speed Upload (Mbps) (contoh: 10 atau 10mbit) (atau kembali): " speed_up; then
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
  created_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

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

  if ! ssh_qac_atomic_update_file "${qf}" set_quota_limit "${quota_bytes}"; then
    ssh_add_user_rollback "${username}" "${qf}" "${acc_file}" "Gagal set quota metadata SSH."
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
  if ! ssh_account_info_write "${username}" "${password}" "${quota_bytes}" "${expired_at}" "${created_at}" "${ip_enabled}" "${ip_limit}" "${speed_enabled}" "${speed_down}" "${speed_up}"; then
    ssh_add_user_rollback "${username}" "${qf}" "${acc_file}" "Gagal menulis SSH account info."
    pause
    return 0
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
  password=""
  pause
}

ssh_delete_user_menu() {
  title
  echo "3) SSH Management > Delete SSH User"
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

  if id "${username}" >/dev/null 2>&1; then
    userdel -r "${username}" >/dev/null 2>&1 || userdel "${username}" >/dev/null 2>&1 || {
      warn "Gagal menghapus user Linux '${username}'."
      pause
      return 0
    }
  fi

  rm -f "$(ssh_user_state_file "${username}")" \
        "${SSH_USERS_STATE_DIR}/${username}.json" \
        "$(ssh_account_info_file "${username}")" \
        "${SSH_ACCOUNT_DIR}/${username}.txt" >/dev/null 2>&1 || true
  log "Akun SSH '${username}' dihapus."
  pause
}

ssh_extend_expiry_menu() {
  title
  echo "3) SSH Management > Extend/Set Expiry"
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
  echo "  1) Tambah hari dari hari ini"
  echo "  2) Set tanggal expiry (YYYY-MM-DD)"
  echo "  0) Kembali"
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

  if ! chage -E "${new_expiry}" "${username}" >/dev/null 2>&1; then
    warn "Gagal update expiry untuk '${username}'."
    pause
    return 0
  fi

  local created_at
  created_at="$(ssh_user_state_created_at_get "${username}")"
  if [[ -z "${created_at}" ]]; then
    created_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  fi
  if ! ssh_user_state_write "${username}" "${created_at}" "${new_expiry}"; then
    warn "Metadata SSH gagal diperbarui untuk '${username}'."
  fi
  if ! ssh_account_info_refresh_from_state "${username}"; then
    warn "SSH ACCOUNT INFO gagal disinkronkan untuk '${username}'."
  fi

  log "Expiry akun '${username}' diperbarui ke ${new_expiry}."
  pause
}

ssh_reset_password_menu() {
  title
  echo "3) SSH Management > Reset Password"
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

  local password=""
  if ! ssh_read_password_confirm password; then
    pause
    return 0
  fi

  if ! printf '%s:%s\n' "${username}" "${password}" | chpasswd >/dev/null 2>&1; then
    warn "Gagal reset password user '${username}'."
    pause
    return 0
  fi

  if ! ssh_account_info_refresh_from_state "${username}" "${password}"; then
    warn "SSH ACCOUNT INFO gagal disinkronkan untuk '${username}'."
  fi
  if [[ "$(ssh_account_info_password_mode)" != "store" && -n "${password}" ]]; then
    hr
    echo "One-time Password : ${password}"
    echo "Note             : password tidak disimpan plaintext di file account info."
    hr
  fi
  password=""

  log "Password akun '${username}' berhasil direset."
  pause
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
    echo "3) SSH Management > List Managed SSH Users"
    hr
    warn "Belum ada akun SSH terkelola."
    hr
    pause
    return 0
  fi

  while true; do
    title
    echo "3) SSH Management > List Managed SSH Users"
    hr
    printf "%-4s %-20s %-22s %-12s %-12s\n" "No" "Username" "Created" "Expired" "SystemUser"
    local i username qf fields meta_user created expired sys_user
    for i in "${!users[@]}"; do
      username="${users[$i]}"
      qf="$(ssh_user_state_file "${username}")"
      fields="$(python3 - <<'PY' "${qf}" 2>/dev/null || true
import json
import sys

path = sys.argv[1]
username = ""
created = "-"
expired = "-"
try:
  with open(path, "r", encoding="utf-8") as f:
    d = json.load(f)
  if isinstance(d, dict):
    username = str(d.get("username") or "").strip()
    created = str(d.get("created_at") or "-")
    expired = str(d.get("expired_at") or "-")
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
      printf "%-4s %-20s %-22s %-12s %-12s\n" "$((i + 1))" "${username}" "${created}" "${expired}" "${sys_user}"
    done
    hr
    echo "Ketik NO untuk lihat detail SSH ACCOUNT INFO."
    echo "0/kembali untuk kembali ke SSH Management."
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
    echo "3) SSH Management > SSH ACCOUNT INFO"
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

ssh_menu() {
  while true; do
    title
    echo "3) SSH Management"
    hr
    echo "  1) Add SSH User"
    echo "  2) Delete SSH User"
    echo "  3) Extend/Set Expiry"
    echo "  4) Reset Password"
    echo "  5) List Managed SSH Users"
    echo "  6) SSH WS Service Status"
    echo "  7) Restart SSH WS Stack"
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
      4) ssh_reset_password_menu ;;
      5) ssh_list_users_menu ;;
      6) sshws_status_menu ;;
      7) sshws_restart_menu ;;
      0|kembali|k|back|b) break ;;
      *) invalid_choice ;;
    esac
  done
}

# -------------------------
# SSH Quota & Access Control
# -------------------------
SSH_QAC_FILES=()
SSH_QAC_PAGE_SIZE=10
SSH_QAC_PAGE=0
SSH_QAC_QUERY=""
SSH_QAC_VIEW_INDEXES=()
SSH_QAC_ENFORCER_BIN="/usr/local/bin/sshws-qac-enforcer"

ssh_active_sessions_count() {
  local username="${1:-}"
  [[ -n "${username}" ]] || {
    echo "0"
    return 0
  }
  if ! id "${username}" >/dev/null 2>&1; then
    echo "0"
    return 0
  fi

  local c="0"
  if have_cmd pgrep; then
    c="$(pgrep -u "${username}" -x dropbear 2>/dev/null | wc -l | awk '{print $1}' || true)"
    c="${c:-0}"
    [[ "${c}" =~ ^[0-9]+$ ]] || c="0"
    if [[ "${c}" == "0" ]]; then
      c="$(pgrep -u "${username}" -f dropbear 2>/dev/null | wc -l | awk '{print $1}' || true)"
      c="${c:-0}"
      [[ "${c}" =~ ^[0-9]+$ ]] || c="0"
    fi
  fi
  echo "${c}"
}

ssh_qac_enforce_once_internal_unlocked() {
  local target_user="${1:-}"
  local lock_file
  ssh_state_dirs_prepare
  ssh_qac_lock_prepare
  lock_file="$(ssh_qac_lock_file)"
  need_python3
  python3 - <<'PY' "${SSH_USERS_STATE_DIR}" "${target_user}" "${lock_file}"
import atexit
import fcntl
import json
import os
import pathlib
import subprocess
import sys
import tempfile

root = pathlib.Path(sys.argv[1])
target = (sys.argv[2] or "").strip()
lock_file = pathlib.Path(sys.argv[3] or "/run/autoscript/locks/sshws-qac.lock")
target_norm = ""

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

target_norm = norm_user(target)

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

def active_sessions(username):
  if not username:
    return 0
  try:
    id_rc = subprocess.run(["id", username], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode
  except FileNotFoundError:
    return 0
  if id_rc != 0:
    return 0
  try:
    cmd = ["pgrep", "-u", username, "-x", "dropbear"]
    res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
  except FileNotFoundError:
    return 0
  lines = [ln for ln in (res.stdout or "").splitlines() if ln.strip()]
  if lines:
    return len(lines)
  try:
    res = subprocess.run(["pgrep", "-u", username, "-f", "dropbear"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
  except FileNotFoundError:
    return 0
  lines = [ln for ln in (res.stdout or "").splitlines() if ln.strip()]
  return len(lines)

def lock_user(username):
  if subprocess.run(["id", username], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0:
    return False
  if subprocess.run(["passwd", "-l", username], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
    return True
  return subprocess.run(["usermod", "-L", username], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0

def unlock_user(username):
  if subprocess.run(["id", username], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0:
    return False
  if subprocess.run(["passwd", "-u", username], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
    return True
  return subprocess.run(["usermod", "-U", username], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0

def write_json_atomic(path, payload):
  text = json.dumps(payload, ensure_ascii=False, indent=2) + "\n"
  dirn = str(path.parent)
  fd, tmp = tempfile.mkstemp(prefix=".tmp.", suffix=".json", dir=dirn)
  try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
      f.write(text)
      f.flush()
      os.fsync(f.fileno())
    os.replace(tmp, path)
  finally:
    try:
      if os.path.exists(tmp):
        os.remove(tmp)
    except Exception:
      pass

def normalize_payload(path):
  payload = {}
  if path.is_file():
    try:
      loaded = json.loads(path.read_text(encoding="utf-8"))
      if isinstance(loaded, dict):
        payload = loaded
    except Exception:
      payload = {}

  username = norm_user(payload.get("username") or path.stem) or norm_user(path.stem) or path.stem
  unit = str(payload.get("quota_unit") or "binary").strip().lower()
  if unit not in ("binary", "decimal"):
    unit = "binary"

  quota_limit = to_int(payload.get("quota_limit"), 0)
  if quota_limit < 0:
    quota_limit = 0
  quota_used = to_int(payload.get("quota_used"), 0)
  if quota_used < 0:
    quota_used = 0

  status_raw = payload.get("status")
  status = status_raw if isinstance(status_raw, dict) else {}

  speed_down = to_float(status.get("speed_down_mbit"), 0.0)
  speed_up = to_float(status.get("speed_up_mbit"), 0.0)
  if speed_down < 0:
    speed_down = 0.0
  if speed_up < 0:
    speed_up = 0.0

  ip_limit = to_int(status.get("ip_limit"), 0)
  if ip_limit < 0:
    ip_limit = 0

  payload["managed_by"] = "autoscript-manage"
  payload["protocol"] = "ssh"
  payload["username"] = username
  payload["created_at"] = str(payload.get("created_at") or "-").strip() or "-"
  payload["expired_at"] = str(payload.get("expired_at") or "-").strip()[:10] or "-"
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
  }
  return payload

if not root.is_dir():
  raise SystemExit(0)

paths = sorted(root.glob("*.json"), key=lambda p: p.name.lower())
for path in paths:
  payload = normalize_payload(path)
  username = norm_user(payload.get("username") or path.stem) or norm_user(path.stem) or path.stem
  stem = path.stem
  stem_user = norm_user(stem)
  if target and target not in (username, stem, stem_user) and target_norm not in (username, stem_user):
    continue

  status = payload["status"]
  before = json.dumps(payload, ensure_ascii=False, sort_keys=True)

  ip_enabled = bool(status.get("ip_limit_enabled"))
  ip_limit = to_int(status.get("ip_limit"), 0)
  if ip_limit < 0:
    ip_limit = 0
  if not ip_enabled:
    status["ip_limit_locked"] = False
  elif ip_limit > 0:
    if active_sessions(username) > ip_limit:
      status["ip_limit_locked"] = True
  else:
    status["ip_limit_locked"] = False

  quota_limit = to_int(payload.get("quota_limit"), 0)
  quota_used = to_int(payload.get("quota_used"), 0)
  status["quota_exhausted"] = bool(quota_limit > 0 and quota_used >= quota_limit)

  reason = ""
  if bool(status.get("manual_block")):
    reason = "manual"
  elif bool(status.get("quota_exhausted")):
    reason = "quota"
  elif bool(status.get("ip_limit_locked")):
    reason = "ip_limit"

  status["lock_reason"] = reason
  account_locked = bool(status.get("account_locked"))
  lock_owner = str(status.get("lock_owner") or "").strip()

  user_exists = subprocess.run(["id", username], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
  if reason:
    if user_exists and lock_user(username):
      account_locked = True
      lock_owner = "ssh_qac"
    elif not user_exists:
      account_locked = False
      lock_owner = ""
  else:
    if user_exists and account_locked and lock_owner == "ssh_qac":
      if unlock_user(username):
        account_locked = False
        lock_owner = ""
    elif not account_locked and lock_owner == "ssh_qac":
      lock_owner = ""

  status["account_locked"] = bool(account_locked)
  status["lock_owner"] = lock_owner
  payload["status"] = status

  after = json.dumps(payload, ensure_ascii=False, sort_keys=True)
  if after != before:
    write_json_atomic(path, payload)
    try:
      os.chmod(path, 0o600)
    except Exception:
      pass
PY
}

ssh_qac_enforce_once_internal() {
  local target_user="${1:-}"
  ssh_qac_enforce_once_internal_unlocked "${target_user}"
}

ssh_qac_enforce_now() {
  local target_user="${1:-}"
  if [[ -x "${SSH_QAC_ENFORCER_BIN}" ]]; then
    if [[ -n "${target_user}" ]]; then
      "${SSH_QAC_ENFORCER_BIN}" --once --user "${target_user}" >/dev/null 2>&1
    else
      "${SSH_QAC_ENFORCER_BIN}" --once >/dev/null 2>&1
    fi
    return $?
  fi
  ssh_qac_enforce_once_internal "${target_user}" >/dev/null 2>&1
}

ssh_qac_enforce_now_warn() {
  local target_user="${1:-}"
  if ! ssh_qac_enforce_now "${target_user}"; then
    if [[ -n "${target_user}" ]]; then
      warn "Enforcer SSH QAC gagal untuk '${target_user}'. Timer akan retry otomatis."
    else
      warn "Enforcer SSH QAC gagal dijalankan. Timer akan retry otomatis."
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
  # prints: username|quota_limit_disp|quota_used_disp|expired_at_date|ip_limit_onoff|ip_limit_value|block_reason|speed_onoff|speed_down_mbit|speed_up_mbit|lock_state
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

lock_disp = "ON" if to_bool(status.get("account_locked")) else "OFF"
print(
  f"{username}|{quota_limit_disp}|{quota_used_disp}|{expired_date}|"
  f"{'ON' if ip_enabled else 'OFF'}|{ip_limit}|{reason_disp}|"
  f"{'ON' if speed_enabled else 'OFF'}|{fmt_mbit(speed_down)}|{fmt_mbit(speed_up)}|{lock_disp}"
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

payload["managed_by"] = "autoscript-manage"
payload["protocol"] = "ssh"
payload["username"] = norm_user(payload.get("username") or username_fallback) or username_fallback
payload["created_at"] = str(payload.get("created_at") or "-").strip() or "-"
payload["expired_at"] = str(payload.get("expired_at") or "-").strip()[:10] or "-"
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

  while true; do
    title
    echo "5) SSH Quota & Access Control > Detail"
    hr
    echo "File  : ${qf}"
    hr

    local fields username ql_disp qu_disp exp_date ip_state ip_lim block_reason speed_state speed_down speed_up lock_state
    fields="$(ssh_qac_read_detail_fields "${qf}")"
    IFS='|' read -r username ql_disp qu_disp exp_date ip_state ip_lim block_reason speed_state speed_down speed_up lock_state <<<"${fields}"

    local active_sessions
    active_sessions="$(ssh_active_sessions_count "${username}")"
    [[ "${active_sessions}" =~ ^[0-9]+$ ]] || active_sessions="0"

    local label_w=18
    printf "%-${label_w}s : %s\n" "Username" "${username}"
    printf "%-${label_w}s : %s\n" "Quota Limit" "${ql_disp}"
    printf "%-${label_w}s : %s\n" "Quota Used" "${qu_disp}"
    printf "%-${label_w}s : %s\n" "Expired At" "${exp_date}"
    printf "%-${label_w}s : %s\n" "IP/Login Limit" "${ip_state}"
    printf "%-${label_w}s : %s\n" "IP/Login Max" "${ip_lim}"
    printf "%-${label_w}s : %s\n" "Block Reason" "${block_reason}"
    printf "%-${label_w}s : %s\n" "Account Locked" "${lock_state}"
    printf "%-${label_w}s : %s\n" "Active Sessions" "${active_sessions}"
    printf "%-${label_w}s : %s Mbps\n" "Speed Download" "${speed_down}"
    printf "%-${label_w}s : %s Mbps\n" "Speed Upload" "${speed_up}"
    printf "%-${label_w}s : %s\n" "Speed Limit" "${speed_state}"
    hr

    echo "  1) View JSON"
    echo "  2) Set Quota Limit (GB)"
    echo "  3) Reset Quota Used (set 0)"
    echo "  4) Manual Block/Unblock (toggle)"
    echo "  5) IP/Login Limit Enable/Disable (toggle)"
    echo "  6) Set IP/Login Limit (angka)"
    echo "  7) Unlock IP/Login Lock"
    echo "  8) Set Speed Download (Mbps)"
    echo "  9) Set Speed Upload (Mbps)"
    echo " 10) Speed Limit Enable/Disable (toggle)"
    echo "  0) Kembali"
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
        if ! ssh_qac_atomic_update_file "${qf}" set_quota_limit "${qb}"; then
          warn "Gagal update quota limit SSH."
          pause
          continue
        fi
        ssh_qac_enforce_now_warn "${username}" || true
        ssh_account_info_refresh_warn "${username}" || true
        log "Quota limit SSH diubah: ${gb_num} GB"
        pause
        ;;
      3)
        if ! ssh_qac_atomic_update_file "${qf}" reset_quota_used; then
          warn "Gagal reset quota used SSH."
          pause
          continue
        fi
        ssh_qac_enforce_now_warn "${username}" || true
        ssh_account_info_refresh_warn "${username}" || true
        log "Quota used SSH di-reset: 0"
        pause
        ;;
      4)
        local st_mb
        st_mb="$(ssh_qac_get_status_bool "${qf}" "manual_block")"
        if [[ "${st_mb}" == "true" ]]; then
          if ! ssh_qac_atomic_update_file "${qf}" manual_block_set off; then
            warn "Gagal menonaktifkan manual block SSH."
            pause
            continue
          fi
          ssh_qac_enforce_now_warn "${username}" || true
          ssh_account_info_refresh_warn "${username}" || true
          log "Manual block SSH: OFF"
        else
          if ! ssh_qac_atomic_update_file "${qf}" manual_block_set on; then
            warn "Gagal mengaktifkan manual block SSH."
            pause
            continue
          fi
          ssh_qac_enforce_now_warn "${username}" || true
          ssh_account_info_refresh_warn "${username}" || true
          log "Manual block SSH: ON"
        fi
        pause
        ;;
      5)
        local ip_on
        ip_on="$(ssh_qac_get_status_bool "${qf}" "ip_limit_enabled")"
        if [[ "${ip_on}" == "true" ]]; then
          if ! ssh_qac_atomic_update_file "${qf}" ip_limit_enabled_set off; then
            warn "Gagal menonaktifkan IP/Login limit SSH."
            pause
            continue
          fi
          ssh_qac_enforce_now_warn "${username}" || true
          ssh_account_info_refresh_warn "${username}" || true
          log "IP/Login limit SSH: OFF"
        else
          if ! ssh_qac_atomic_update_file "${qf}" ip_limit_enabled_set on; then
            warn "Gagal mengaktifkan IP/Login limit SSH."
            pause
            continue
          fi
          ssh_qac_enforce_now_warn "${username}" || true
          ssh_account_info_refresh_warn "${username}" || true
          log "IP/Login limit SSH: ON"
        fi
        pause
        ;;
      6)
        if ! read -r -p "IP/Login limit (angka) (atau kembali): " lim; then
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
          warn "Gagal set IP/Login limit SSH."
          pause
          continue
        fi
        ssh_qac_enforce_now_warn "${username}" || true
        ssh_account_info_refresh_warn "${username}" || true
        log "IP/Login limit SSH diubah: ${lim}"
        pause
        ;;
      7)
        if ! ssh_qac_atomic_update_file "${qf}" clear_ip_limit_locked; then
          warn "Gagal unlock IP/Login lock SSH."
          pause
          continue
        fi
        ssh_qac_enforce_now_warn "${username}" || true
        ssh_account_info_refresh_warn "${username}" || true
        log "IP/Login lock SSH di-unlock"
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
        if ! ssh_qac_atomic_update_file "${qf}" set_speed_down "${speed_down_input}"; then
          warn "Gagal set speed download SSH."
          pause
          continue
        fi
        ssh_account_info_refresh_warn "${username}" || true
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
        if ! ssh_qac_atomic_update_file "${qf}" set_speed_up "${speed_up_input}"; then
          warn "Gagal set speed upload SSH."
          pause
          continue
        fi
        ssh_account_info_refresh_warn "${username}" || true
        log "Speed upload SSH diubah: ${speed_up_input} Mbps"
        pause
        ;;
      10)
        local speed_on speed_down_now speed_up_now
        speed_on="$(ssh_qac_get_status_bool "${qf}" "speed_limit_enabled")"
        if [[ "${speed_on}" == "true" ]]; then
          if ! ssh_qac_atomic_update_file "${qf}" speed_limit_set off; then
            warn "Gagal menonaktifkan speed limit SSH."
            pause
            continue
          fi
          ssh_account_info_refresh_warn "${username}" || true
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

        if ! ssh_qac_atomic_update_file "${qf}" set_speed_all_enable "${speed_down_now}" "${speed_up_now}"; then
          warn "Gagal mengaktifkan speed limit SSH."
          pause
          continue
        fi
        ssh_account_info_refresh_warn "${username}" || true
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
    title
    echo "5) SSH Quota & Access Control"
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
  echo "12) Install BOT Discord"
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
  echo "13) Install BOT Telegram"
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
  echo "10) Maintenance > Daemon Status"
  hr

  local daemons=("xray" "nginx" "xray-expired" "xray-quota" "xray-limit-ip" "xray-speed" "wireproxy" "sshws-qac-enforcer.timer")
  local d
  for d in "${daemons[@]}"; do
    if svc_exists "${d}"; then
      svc_status_line "${d}"
    else
      echo "N/A  - ${d} (not installed)"
    fi
  done
  hr

  echo "Info: log daemon disembunyikan agar tampilan ringkas."
  hr

  echo "  1) Restart xray-expired"
  echo "  2) Restart xray-quota"
  echo "  3) Restart xray-limit-ip"
  echo "  4) Restart xray-speed"
  echo "  5) Restart semua daemon (xray-expired + xray-quota + xray-limit-ip + xray-speed)"
  echo "  6) Lihat log xray-expired (20 baris)"
  echo "  7) Lihat log xray-quota (20 baris)"
  echo "  8) Lihat log xray-limit-ip (20 baris)"
  echo "  9) Lihat log xray-speed (20 baris)"
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
    0|kembali|k|back|b) return 0 ;;
    *) warn "Pilihan tidak valid" ; sleep 1 ;;
  esac
}

# -------------------------
