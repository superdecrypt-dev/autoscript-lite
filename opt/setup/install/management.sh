#!/usr/bin/env bash
# Management/bot sync module for setup runtime.

install_management_scripts() {
  ok "Siapkan tools runtime..."

  mkdir -p /opt/account/vless /opt/account/vmess /opt/account/trojan /opt/account/ssh
  mkdir -p /opt/quota/vless /opt/quota/vmess /opt/quota/trojan /opt/quota/ssh
  chmod 700 /opt/account /opt/quota
  chmod 700 /opt/account/vless /opt/account/vmess /opt/account/trojan /opt/account/ssh
  chmod 700 /opt/quota/vless /opt/quota/vmess /opt/quota/trojan /opt/quota/ssh

  cat > /usr/local/bin/xray-expired <<'EOF'
#!/usr/bin/env python3
import argparse
import json
import os
import subprocess
import time
from datetime import datetime, timezone

XRAY_CONFIG_DEFAULT   = "/usr/local/etc/xray/conf.d/30-routing.json"
XRAY_INBOUNDS_DEFAULT = "/usr/local/etc/xray/conf.d/10-inbounds.json"
XRAY_ROUTING_DEFAULT  = "/usr/local/etc/xray/conf.d/30-routing.json"
ACCOUNT_ROOT = "/opt/account"
QUOTA_ROOT = "/opt/quota"
SPEED_ROOT = "/opt/speed"
PROTO_DIRS = ("vless", "vmess", "trojan")

def now_utc():
  return datetime.now(timezone.utc)

def parse_iso8601(value):
  if not value:
    return None
  s = str(value).strip()
  if s.endswith("Z"):
    s = s[:-1] + "+00:00"
  try:
    dt = datetime.fromisoformat(s)
  except Exception:
    return None
  if dt.tzinfo is None:
    dt = dt.replace(tzinfo=timezone.utc)
  return dt

def load_json(path):
  with open(path, "r", encoding="utf-8") as f:
    return json.load(f)

def save_json_atomic(path, data):
  # BUG-10 fix: use mkstemp (unique name) instead of fixed "{path}.tmp"
  # to prevent concurrent writers from corrupting each other's tmp file.
  import tempfile
  dirn = os.path.dirname(path) or "."
  st_mode = None
  st_uid = None
  st_gid = None
  try:
    st = os.stat(path)
    st_mode = st.st_mode & 0o777
    st_uid = st.st_uid
    st_gid = st.st_gid
  except FileNotFoundError:
    pass
  fd, tmp = tempfile.mkstemp(prefix=".tmp.", suffix=".json", dir=dirn)
  try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
      json.dump(data, f, indent=2)
      f.write("\n")
      f.flush()
      os.fsync(f.fileno())
    if st_mode is not None:
      os.chmod(tmp, st_mode)
    if st_uid is not None and st_gid is not None:
      try:
        os.chown(tmp, st_uid, st_gid)
      except PermissionError:
        pass
    os.replace(tmp, path)
  except Exception:
    try:
      if os.path.exists(tmp):
        os.remove(tmp)
    except Exception:
      pass
    raise

ROUTING_LOCK_PATH = "/run/autoscript/locks/xray-routing.lock"

def save_routing_atomic_locked(inbounds_path, inb_data, routing_path, rt_data):
  """BUG-15 note: xray-expired has a 4-argument signature (inbounds + routing) because
  it writes BOTH files atomically in one lock. The other daemons (user-block, xray-quota,
  limit-ip) use a 2-argument signature (config_path, cfg) because they only write routing.
  These signatures are intentionally different — do NOT unify without careful review.
  Tulis kedua file config secara atomik dengan file lock untuk cegah race condition
  dengan daemon lain (xray-quota, limit-ip) yang juga bisa menulis routing config."""
  import fcntl
  lock_dir = os.path.dirname(ROUTING_LOCK_PATH) or "/run/autoscript/locks"
  os.makedirs(lock_dir, exist_ok=True)
  try:
    os.chmod(lock_dir, 0o700)
  except Exception:
    pass
  with open(ROUTING_LOCK_PATH, "w") as lf:
    try:
      fcntl.flock(lf, fcntl.LOCK_EX)
      save_json_atomic(inbounds_path, inb_data)
      save_json_atomic(routing_path, rt_data)
    finally:
      fcntl.flock(lf, fcntl.LOCK_UN)

def restart_xray():
  subprocess.run(
    ["systemctl", "restart", "xray"],
    check=False,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
  )

def remove_user_from_inbounds(cfg, username):
  changed = False
  inbounds = cfg.get("inbounds") or []
  for inbound in inbounds:
    settings = inbound.get("settings") or {}
    clients = settings.get("clients")
    if not isinstance(clients, list):
      continue
    new_clients = []
    for c in clients:
      if c.get("email") == username:
        changed = True
        continue
      new_clients.append(c)
    settings["clients"] = new_clients
    inbound["settings"] = settings
  return changed

def remove_user_from_rules(cfg, username):
  # Hanya bersihkan dari rule yang mengandung dummy markers (manajemen user).
  # Konsisten dengan manage.sh xray_delete_client — custom rules non-marker
  # tidak disentuh agar tidak kehilangan konfigurasi routing lain.
  changed = False
  markers = {
    "dummy-block-user", "dummy-quota-user", "dummy-limit-user",
    "dummy-warp-user", "dummy-direct-user",
  }
  speed_marker_prefix = "dummy-speed-user-"
  rules = ((cfg.get("routing") or {}).get("rules")) or []
  for rule in rules:
    users = rule.get("user")
    if not isinstance(users, list):
      continue
    # Lewati rule yang bukan milik sistem manajemen user
    is_managed = any(m in users for m in markers)
    if not is_managed:
      for u in users:
        if isinstance(u, str) and u.startswith(speed_marker_prefix):
          is_managed = True
          break
    if not is_managed:
      continue
    if username in users:
      rule["user"] = [u for u in users if u != username]
      changed = True
  return changed

def iter_quota_files():
  for proto in PROTO_DIRS:
    d = os.path.join(QUOTA_ROOT, proto)
    if not os.path.isdir(d):
      continue
    for name in os.listdir(d):
      if name.endswith(".json"):
        yield proto, os.path.join(d, name)

def quota_key_from_path(path):
  return os.path.splitext(os.path.basename(path))[0]

def canonical_email(proto, user_key):
  # Quota file format kompatibilitas bisa bernama "username.json" (tanpa @proto).
  # Untuk operasi config Xray, normalisasikan ke format email "username@proto".
  if not user_key:
    return user_key
  if "@" in user_key:
    return user_key
  return f"{user_key}@{proto}"

def is_expired(meta, ts):
  exp = parse_iso8601(meta.get("expired_at") if isinstance(meta, dict) else None)
  if exp is None:
    return False
  return exp <= ts

def _remove_file(path):
  try:
    if os.path.exists(path):
      os.remove(path)
  except Exception:
    pass

def delete_user_artifacts(proto, user_key, quota_path):
  # 1) quota json: /opt/quota/<proto>/<username@proto>.json
  _remove_file(quota_path)

  # 2) account txt (format baru): /opt/account/<proto>/<username@proto>.txt
  _remove_file(os.path.join(ACCOUNT_ROOT, proto, f"{user_key}.txt"))

  # 3) account txt (format kompatibilitas): /opt/account/<proto>/<username>.txt
  # Konsisten dengan manage.sh delete_account_artifacts yang juga hapus keduanya.
  bare = user_key.split("@")[0] if "@" in user_key else user_key
  if bare != user_key:
    _remove_file(os.path.join(ACCOUNT_ROOT, proto, f"{bare}.txt"))

  # 4) quota json format kompatibilitas: /opt/quota/<proto>/<username>.json
  # Jika ada sisa file kompatibilitas, bersihkan juga.
  if bare != user_key:
    _remove_file(os.path.join(QUOTA_ROOT, proto, f"{bare}.json"))

  # 5) speed policy (format baru + fallback format kompatibilitas)
  speed_candidates = {
    os.path.join(SPEED_ROOT, proto, f"{user_key}.json"),
    os.path.join(SPEED_ROOT, proto, f"{bare}@{proto}.json"),
    os.path.join(SPEED_ROOT, proto, f"{bare}.json"),
  }
  for sp in speed_candidates:
    _remove_file(sp)

def run_once(inbounds_path, routing_path, dry_run=False):
  ts = now_utc()
  expired = []  # list[(proto, user_key, quota_path)]

  for proto, path in iter_quota_files():
    try:
      meta = load_json(path)
    except Exception:
      continue

    user_key = quota_key_from_path(path)
    if isinstance(meta, dict):
      u2 = meta.get("username")
      # Prioritaskan meta["username"] jika ada dan tidak kosong.
      # Field ini selalu ditulis manage.sh sebagai "username@proto".
      if isinstance(u2, str) and u2.strip():
        user_key = u2.strip()
    if not user_key:
      continue

    if is_expired(meta, ts):
      expired.append((proto, user_key, path))

  if not expired:
    return 0

  if dry_run:
    for _, user_key, _ in expired:
      print(user_key)
    return 0

  # PENTING: reload inbounds dan routing dari disk sebelum modifikasi+save
  # untuk menghindari overwrite perubahan concurrent dari manage.sh atau daemon lain.
  try:
    inb_cfg = load_json(inbounds_path)
    rt_cfg = load_json(routing_path)
  except Exception:
    return 0

  # Re-check expiry setelah reload disk: cegah race condition dengan
  # manage.sh extend-expiry yang mungkin sudah update quota file
  # antara scan awal dan reload config ini.
  ts2 = now_utc()
  confirmed = []
  for proto, user_key, qpath in expired:
    try:
      meta_fresh = load_json(qpath)
    except FileNotFoundError:
      # File sudah dihapus pihak lain — tetap lanjut bersihkan dari config.
      confirmed.append((proto, user_key, qpath))
      continue
    except Exception:
      continue
    if is_expired(meta_fresh, ts2):
      confirmed.append((proto, user_key, qpath))
    # Jika tidak lagi expired (sudah di-extend), lewati.

  if not confirmed:
    return 0

  # PENTING: reload inbounds dan routing dari disk sebelum modifikasi+save
  # untuk menghindari overwrite perubahan concurrent dari manage.sh atau daemon lain.
  try:
    inb_cfg = load_json(inbounds_path)
    rt_cfg = load_json(routing_path)
  except Exception:
    return 0

  changed_inb = False
  changed_rt = False
  for proto, user_key, _ in confirmed:
    email_key = canonical_email(proto, user_key)
    changed_inb = remove_user_from_inbounds(inb_cfg, email_key) or changed_inb
    changed_rt = remove_user_from_rules(rt_cfg, email_key) or changed_rt

  # BUG-04 fix: save config FIRST, delete artifacts only on success.
  # Previously artifacts were deleted before save, causing permanent inconsistency
  # if save failed (disk full, xray crash, etc.): files gone but user still in config.
  config_saved = False
  if changed_inb or changed_rt:
    try:
      save_routing_atomic_locked(inbounds_path, inb_cfg, routing_path, rt_cfg)
      config_saved = True
    except Exception:
      # Config save failed — do NOT delete artifacts to avoid orphan state.
      return 0
    restart_xray()

  # Delete artifacts only after config has been saved successfully.
  # If nothing changed in config (user wasn't in inbounds/routing), still clean up.
  for proto, user_key, qpath in confirmed:
    delete_user_artifacts(proto, user_key, qpath)

  return 0

def main():
  ap = argparse.ArgumentParser(prog="xray-expired")
  ap.add_argument("--inbounds", default=XRAY_INBOUNDS_DEFAULT)
  ap.add_argument("--routing", default=XRAY_ROUTING_DEFAULT)
  ap.add_argument("--interval", type=int, default=2)
  ap.add_argument("--once", action="store_true")
  ap.add_argument("--dry-run", action="store_true")
  args = ap.parse_args()

  if args.once:
    return run_once(args.inbounds, args.routing, dry_run=args.dry_run)

  interval = max(1, int(args.interval))
  while True:
    try:
      run_once(args.inbounds, args.routing, dry_run=args.dry_run)
    except Exception:
      pass
    time.sleep(interval)

if __name__ == "__main__":
  raise SystemExit(main())
EOF
  chmod +x /usr/local/bin/xray-expired

  cat > /usr/local/bin/limit-ip <<'EOF'
#!/usr/bin/env python3
import argparse
import fcntl
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone

XRAY_CONFIG_DEFAULT = "/usr/local/etc/xray/conf.d/30-routing.json"
QUOTA_ROOT = "/opt/quota"
PROTO_DIRS = ("vless", "vmess", "trojan")
XRAY_ACCESS_LOG = "/var/log/xray/access.log"
EDGE_MUX_SERVICE = "edge-mux"
LOOPBACK_IPS = {"127.0.0.1", "::1", "0:0:0:0:0:0:0:1"}
EDGE_ROUTE_CACHE_SECONDS = 3
EDGE_ROUTE_MATCH_WINDOW_SECONDS = 5
EDGE_ROUTE_FETCH_LOOKBACK_SECONDS = 900
XRAY_PRELOAD_MAX_BYTES = 16 * 1024 * 1024
XRAY_PRELOAD_MAX_LINES = 50000
EDGE_USER_CACHE_SECONDS = 30
RESET_DIR = "/run/autoscript/limit-ip-reset"

EMAIL_RE = re.compile(r"(?:email|user)\s*[:=]\s*([A-Za-z0-9._%+-]{1,128}@[A-Za-z0-9._-]{1,128})")
# BUG-07 fix: added IPv6 support. Previously only IPv4 was matched, so clients
# connecting via IPv6 were never detected and ip-limit never triggered for them.
# New pattern matches:
#   IPv4:  "from 1.2.3.4:12345"
#   IPv6:  "from [::1]:12345" or "from 2001:db8::1:12345" (bare, without brackets)
IP_RE = re.compile(
  r"\bfrom\s+"
  r"(?:"
    r"\[([0-9a-fA-F:]{2,39})\]:\d{1,5}"       # [IPv6]:port
    r"|(\d{1,3}(?:\.\d{1,3}){3}):\d{1,5}"      # IPv4:port
    r"|([0-9a-fA-F]{1,4}(?::[0-9a-fA-F]{0,4}){2,7}):\d{1,5}"  # bare IPv6:port
  r")"
)
ROUTE_RE = re.compile(r"\[(?:[^\]@]+@)?([A-Za-z0-9-]+)\s*->")
EDGE_ROUTE_RE = re.compile(
  r"(?P<ts>\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}).*?"
  r"\broute=(?P<route>[a-z0-9-]+)\b.*?"
  r"\bremote=(?P<remote>\S+)"
)

EDGE_ROUTE_CACHE = {"expires_at": 0.0, "events": []}
USER_ROUTE_CACHE = {}

def extract_ip_from_match(m):
  """Extract IP string from IP_RE match (handles IPv4 and IPv6 groups)."""
  if m is None:
    return None
  return m.group(1) or m.group(2) or m.group(3)

def extract_peer_identity_from_match(m):
  """Return identity key for ip-limit bucketing.

  Prefer stable remote IP for normal public connections. If the observed source
  is loopback, Xray is sitting behind a local edge proxy and the real client IP
  is already masked. In that case fall back to the full endpoint text so each
  concurrent proxied connection is still counted separately instead of all
  public clients collapsing into 127.0.0.1.
  """
  if m is None:
    return None
  ip = extract_ip_from_match(m)
  if not ip:
    return None
  ip_lower = str(ip).strip().lower()
  if ip_lower in ("127.0.0.1", "::1", "0:0:0:0:0:0:0:1"):
    raw = m.group(0) or ""
    if not raw:
      return ip
    endpoint = raw.split(None, 1)[1].strip() if " " in raw else raw.strip()
    return endpoint or ip
  return ip

def is_loopback_ip(value):
  raw = str(value or "").strip().lower()
  return raw in LOOPBACK_IPS

def parse_access_timestamp(line):
  try:
    prefix = str(line or "").strip()[:19]
    return datetime.strptime(prefix, "%Y/%m/%d %H:%M:%S").timestamp()
  except Exception:
    return None

def extract_route_from_line(line):
  m = ROUTE_RE.search(str(line or ""))
  if not m:
    return ""
  return str(m.group(1) or "").strip().lower()

def parse_remote_ip(raw):
  value = str(raw or "").strip()
  if not value:
    return ""
  if value.startswith("[") and "]:" in value:
    return value[1:].split("]:", 1)[0].strip()
  if ":" in value:
    head, tail = value.rsplit(":", 1)
    if tail.isdigit():
      return head.strip()
  return value

def read_tail_lines(path, max_bytes=XRAY_PRELOAD_MAX_BYTES, max_lines=XRAY_PRELOAD_MAX_LINES):
  if not os.path.isfile(path):
    return []
  try:
    with open(path, "rb") as f:
      f.seek(0, os.SEEK_END)
      size = f.tell()
      start = max(0, size - max_bytes)
      f.seek(start)
      payload = f.read()
  except Exception:
    return []
  try:
    lines = payload.decode("utf-8", errors="ignore").splitlines()
  except Exception:
    return []
  if start > 0 and lines:
    lines = lines[1:]
  if max_lines > 0:
    return lines[-max_lines:]
  return lines

def edge_mux_recent_routes(now_ts=None):
  if now_ts is None:
    now_ts = time.time()
  cached_exp = float(EDGE_ROUTE_CACHE.get("expires_at") or 0.0)
  cached_events = EDGE_ROUTE_CACHE.get("events")
  if cached_exp > now_ts and isinstance(cached_events, list):
    return cached_events
  since_ts = now_ts - EDGE_ROUTE_FETCH_LOOKBACK_SECONDS
  since_text = datetime.fromtimestamp(since_ts).strftime("%Y-%m-%d %H:%M:%S")
  try:
    proc = subprocess.run(
      ["journalctl", "-u", EDGE_MUX_SERVICE, "--since", since_text, "--no-pager", "-o", "cat"],
      capture_output=True,
      text=True,
      timeout=8,
      check=False,
    )
    out = ((proc.stdout or "") + ("\n" + proc.stderr if proc.stderr else "")).strip()
    if proc.returncode != 0:
      out = ""
  except Exception:
    out = ""
  events = []
  if out:
    for line in out.splitlines():
      m = EDGE_ROUTE_RE.search(line)
      if not m:
        continue
      route = str(m.group("route") or "").strip().lower()
      if not route:
        continue
      remote_ip = parse_remote_ip(m.group("remote"))
      if not remote_ip or is_loopback_ip(remote_ip):
        continue
      try:
        event_ts = datetime.strptime(str(m.group("ts")), "%Y/%m/%d %H:%M:%S").timestamp()
      except Exception:
        continue
      events.append({"ts": event_ts, "route": route, "ip": remote_ip})
  EDGE_ROUTE_CACHE["expires_at"] = now_ts + EDGE_ROUTE_CACHE_SECONDS
  EDGE_ROUTE_CACHE["events"] = events
  return events

def resolve_public_ip_from_edge(route_name, line_ts, fallback_identity):
  route_n = str(route_name or "").strip().lower()
  if not route_n or line_ts is None:
    return fallback_identity
  candidates = []
  for item in edge_mux_recent_routes(line_ts):
    if str(item.get("route") or "").strip().lower() != route_n:
      continue
    event_ts = float(item.get("ts") or 0.0)
    delta = abs(event_ts - line_ts)
    if delta > EDGE_ROUTE_MATCH_WINDOW_SECONDS:
      continue
    ip_value = str(item.get("ip") or "").strip()
    if not ip_value:
      continue
    candidates.append((delta, event_ts, ip_value))
  if not candidates:
    return fallback_identity
  unique_ips = {ip for _, _, ip in candidates}
  if len(unique_ips) != 1:
    return fallback_identity
  candidates.sort(key=lambda item: (item[0], -item[1]))
  _, _, ip_value = candidates[0]
  return ip_value or fallback_identity

def cache_user_ip(username, route_name, ip_value, now_ts):
  user = str(username or "").strip()
  route = str(route_name or "").strip().lower()
  ip = str(ip_value or "").strip()
  if not user or not route or not ip or is_loopback_ip(ip):
    return
  USER_ROUTE_CACHE[user] = {
    "ip": ip,
    "route": route,
    "expires_at": float(now_ts) + EDGE_USER_CACHE_SECONDS,
  }

def cached_user_ip(username, route_name, now_ts):
  user = str(username or "").strip()
  route = str(route_name or "").strip().lower()
  entry = USER_ROUTE_CACHE.get(user)
  if not isinstance(entry, dict):
    return "-"
  if float(entry.get("expires_at") or 0.0) <= float(now_ts):
    USER_ROUTE_CACHE.pop(user, None)
    return "-"
  if route and str(entry.get("route") or "").strip().lower() != route:
    return "-"
  ip_value = str(entry.get("ip") or "").strip()
  if not ip_value or is_loopback_ip(ip_value):
    return "-"
  return ip_value

def safe_int(v, default=0):
  try:
    if v is None:
      return default
    if isinstance(v, bool):
      return int(v)
    if isinstance(v, (int, float)):
      return int(v)
    s = str(v).strip()
    if s == "":
      return default
    return int(float(s))
  except Exception:
    return default

def now_iso():
  return datetime.now().strftime("%Y-%m-%d %H:%M")

def load_json(path):
  with open(path, "r", encoding="utf-8") as f:
    return json.load(f)

def with_status_lock(path):
  lock_path = f"{path}.lock"
  lock_file = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
  fcntl.flock(lock_file, fcntl.LOCK_EX)
  return lock_file

def release_status_lock(fd):
  try:
    fcntl.flock(fd, fcntl.LOCK_UN)
  finally:
    os.close(fd)

def save_json_atomic(path, data):
  # BUG-10 fix: use mkstemp (unique name) instead of fixed "{path}.tmp"
  # to prevent concurrent writers from corrupting each other's tmp file.
  import tempfile
  dirn = os.path.dirname(path) or "."
  st_mode = None
  st_uid = None
  st_gid = None
  try:
    st = os.stat(path)
    st_mode = st.st_mode & 0o777
    st_uid = st.st_uid
    st_gid = st.st_gid
  except FileNotFoundError:
    pass
  fd, tmp = tempfile.mkstemp(prefix=".tmp.", suffix=".json", dir=dirn)
  try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
      json.dump(data, f, indent=2)
      f.write("\n")
      f.flush()
      os.fsync(f.fileno())
    if st_mode is not None:
      os.chmod(tmp, st_mode)
    if st_uid is not None and st_gid is not None:
      try:
        os.chown(tmp, st_uid, st_gid)
      except PermissionError:
        pass
    os.replace(tmp, path)
  except Exception:
    try:
      if os.path.exists(tmp):
        os.remove(tmp)
    except Exception:
      pass
    raise

ROUTING_LOCK_PATH = "/run/autoscript/locks/xray-routing.lock"

def save_routing_atomic_locked(config_path, cfg):
  """Tulis routing config secara atomik dengan file lock bersama."""
  import fcntl
  lock_dir = os.path.dirname(ROUTING_LOCK_PATH) or "/run/autoscript/locks"
  os.makedirs(lock_dir, exist_ok=True)
  try:
    os.chmod(lock_dir, 0o700)
  except Exception:
    pass
  with open(ROUTING_LOCK_PATH, "w") as lf:
    try:
      fcntl.flock(lf, fcntl.LOCK_EX)
      save_json_atomic(config_path, cfg)
    finally:
      fcntl.flock(lf, fcntl.LOCK_UN)

def load_and_modify_routing_locked(config_path, modify_fn):
  """BUG-01 fix: acquire lock FIRST, then reload config from disk, apply modify_fn, save.
  Prevents last-write-wins race condition with other daemons."""
  import fcntl
  lock_dir = os.path.dirname(ROUTING_LOCK_PATH) or "/run/autoscript/locks"
  os.makedirs(lock_dir, exist_ok=True)
  try:
    os.chmod(lock_dir, 0o700)
  except Exception:
    pass
  with open(ROUTING_LOCK_PATH, "w") as lf:
    try:
      fcntl.flock(lf, fcntl.LOCK_EX)
      cfg = load_json(config_path)
      changed = modify_fn(cfg)
      if changed:
        save_json_atomic(config_path, cfg)
      return changed, cfg
    finally:
      fcntl.flock(lf, fcntl.LOCK_UN)

def find_marker_rule(cfg, marker, outbound_tag):
  # BUG-FIX: fungsi ini wajib ada di limit-ip — sebelumnya hanya terdefinisi
  # di xray-quota sehingga limit-ip crash NameError saat startup/watch/unlock.
  rules = ((cfg.get("routing") or {}).get("rules")) or []
  for r in rules:
    if r.get("type") != "field":
      continue
    if r.get("outboundTag") != outbound_tag:
      continue
    users = r.get("user") or []
    if isinstance(users, list) and marker in users:
      return r
  return None

def restart_xray():
  subprocess.run(["systemctl", "restart", "xray"], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def ensure_user(rule, username, marker=None):
  users = rule.get("user") or []
  if not isinstance(users, list):
    users = []
  if marker is not None and marker not in users:
    users.insert(0, marker)
  if username not in users:
    users.append(username)
    rule["user"] = users
    return True
  rule["user"] = users
  return False

def remove_user(rule, username):
  users = rule.get("user") or []
  if not isinstance(users, list) or username not in users:
    return False
  rule["user"] = [u for u in users if u != username]
  return True

def quota_paths(username):
  """Kembalikan semua path quota JSON yang cocok untuk username.
  Mendukung format baru (username@proto.json) dan format kompatibilitas (username.json).
  Jika username berisi '@', hanya cari di proto yang sesuai (bukan semua proto).
  Jika bare username, coba username@proto.json dulu di semua proto lalu fallback format kompatibilitas."""
  paths = []
  if "@" in username:
    # Full email (mis. "alice@vless"): ekstrak proto dari email, cari hanya di proto itu.
    # Ini menghindari false-positive lookup ke proto yang salah (mis. alice@vless.json
    # dicari di /opt/quota/vmess/ dan /opt/quota/trojan/ yang pasti tidak ada).
    parts = username.split("@", 1)
    email_proto = parts[1] if len(parts) == 2 else ""
    # Cari di proto yang cocok dengan email terlebih dulu
    if email_proto in PROTO_DIRS:
      p = os.path.join(QUOTA_ROOT, email_proto, f"{username}.json")
      if os.path.isfile(p):
        paths.append(p)
    # Fallback: iterasi semua proto (antisipasi file di tempat yang tidak terduga)
    if not paths:
      for proto in PROTO_DIRS:
        if proto == email_proto:
          continue  # sudah dicek di atas
        p = os.path.join(QUOTA_ROOT, proto, f"{username}.json")
        if os.path.isfile(p) and p not in paths:
          paths.append(p)
  else:
    # Bare username: coba username@proto.json (format baru manage.sh) lalu fallback format kompatibilitas
    for proto in PROTO_DIRS:
      candidates = [
        os.path.join(QUOTA_ROOT, proto, f"{username}@{proto}.json"),
        os.path.join(QUOTA_ROOT, proto, f"{username}.json"),
      ]
      for p in candidates:
        if os.path.isfile(p) and p not in paths:
          paths.append(p)
  return paths

def get_status(username):
  for p in quota_paths(username):
    try:
      meta = load_json(p)
    except Exception:
      continue
    if not isinstance(meta, dict):
      continue
    st_raw = meta.get("status") if isinstance(meta, dict) else {}
    st = st_raw if isinstance(st_raw, dict) else {}
    return st
  return {}

def update_status_files(username, mutator):
  for p in quota_paths(username):
    lock_fd = None
    try:
      lock_fd = with_status_lock(p)
      meta = load_json(p)
      if not isinstance(meta, dict):
        continue
      st_raw = meta.get("status") if isinstance(meta, dict) else {}
      st = st_raw if isinstance(st_raw, dict) else {}
      changed = mutator(st)
      if not changed:
        continue
      meta["status"] = st
      save_json_atomic(p, meta)
    except Exception:
      continue
    finally:
      if lock_fd is not None:
        release_status_lock(lock_fd)

def mark_user_reset(username):
  user = str(username or "").strip()
  if not user:
    return
  os.makedirs(RESET_DIR, exist_ok=True)
  try:
    with open(os.path.join(RESET_DIR, user), "w", encoding="utf-8") as f:
      f.write(str(time.time()))
  except Exception:
    pass
  USER_ROUTE_CACHE.pop(user, None)

def set_status(username, enabled=None, limit=None):
  def mutator(st):
    changed = False
    if enabled is not None:
      value = bool(enabled)
      if bool(st.get("ip_limit_enabled")) != value:
        st["ip_limit_enabled"] = value
        changed = True
    if limit is not None:
      value = int(limit)
      if safe_int(st.get("ip_limit"), 0) != value:
        st["ip_limit"] = value
        changed = True
    if "ip_limit_locked" not in st:
      st["ip_limit_locked"] = False
      changed = True
    return changed
  update_status_files(username, mutator)
  mark_user_reset(username)

def lock_user(username):
  def mutator(st):
    changed = False
    if not bool(st.get("ip_limit_locked", False)):
      st["ip_limit_locked"] = True
      changed = True
    if not bool(st.get("manual_block", False)):
      if str(st.get("lock_reason") or "") != "ip_limit":
        st["lock_reason"] = "ip_limit"
        changed = True
      stamp = now_iso()
      if str(st.get("locked_at") or "").strip() != stamp:
        st["locked_at"] = stamp
        changed = True
    elif not st.get("locked_at"):
      st["locked_at"] = now_iso()
      changed = True
    return changed
  update_status_files(username, mutator)

def unlock_user(username):
  mark_user_reset(username)
  def mutator(st):
    changed = False
    if bool(st.get("ip_limit_locked", False)):
      st["ip_limit_locked"] = False
      changed = True
    if st.get("lock_reason") == "ip_limit":
      if bool(st.get("manual_block", False)):
        next_reason = "manual"
      elif bool(st.get("quota_exhausted", False)):
        next_reason = "quota"
      else:
        next_reason = ""
      if str(st.get("lock_reason") or "") != next_reason:
        st["lock_reason"] = next_reason
        changed = True
      if not next_reason and st.get("locked_at"):
        st["locked_at"] = ""
        changed = True
    return changed
  update_status_files(username, mutator)

def parse_line(line):
  m1 = EMAIL_RE.search(line)
  m2 = IP_RE.search(line)
  if not m1 or not m2:
    return None, None
  peer_identity = extract_peer_identity_from_match(m2)
  if not peer_identity:
    return None, None
  username = m1.group(1)
  if is_loopback_ip(extract_ip_from_match(m2)):
    route_name = extract_route_from_line(line)
    line_ts = parse_access_timestamp(line)
    cached_ip = cached_user_ip(username, route_name, line_ts or time.time())
    if cached_ip and cached_ip != "-":
      peer_identity = cached_ip
    else:
      resolved = resolve_public_ip_from_edge(route_name, line_ts, "-")
      if resolved and resolved != "-":
        cache_user_ip(username, route_name, resolved, line_ts or time.time())
        peer_identity = resolved
      else:
        return username, None
  return username, peer_identity

def tail_follow(path):
  p = subprocess.Popen(["tail", "-n", "0", "-F", path], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
  try:
    for line in p.stdout:
      yield line.rstrip("\n")
  finally:
    try:
      p.terminate()
    except Exception:
      pass

def process_event(config_path, marker, seen, user, ip, now_ts, window_seconds, last_restart, min_restart_interval):
  reset_path = os.path.join(RESET_DIR, str(user or "").strip())
  try:
    reset_ts = os.path.getmtime(reset_path)
  except Exception:
    reset_ts = 0.0
  if reset_ts > 0 and now_ts <= reset_ts:
    seen.pop(user, None)
    return last_restart
  if reset_ts > 0:
    seen.pop(user, None)
    try:
      os.remove(reset_path)
    except Exception:
      pass
  st = get_status(user)
  if not st:
    return last_restart
  if not bool(st.get("ip_limit_enabled", False)):
    return last_restart
  lim = safe_int(st.get("ip_limit", 0), 0)
  if lim <= 0:
    return last_restart
  if bool(st.get("ip_limit_locked", False)):
    return last_restart

  bucket = seen.setdefault(user, {})
  cutoff = now_ts - float(window_seconds)
  for ip2 in [k for k, ts in bucket.items() if ts < cutoff]:
    del bucket[ip2]
  if not bucket:
    seen.pop(user, None)
    bucket = seen.setdefault(user, {})
  bucket[ip] = now_ts

  if len(bucket) > lim:
    lock_user(user)
    seen.pop(user, None)
    def do_lock(cfg):
      rule = find_marker_rule(cfg, marker, "blocked")
      if rule is None:
        return False
      return ensure_user(rule, user, marker)
    changed, _ = load_and_modify_routing_locked(config_path, do_lock)
    if changed and now_ts - last_restart >= min_restart_interval:
      restart_xray()
      last_restart = now_ts
  return last_restart

def watch(config_path, marker, window_seconds):
  # Verifikasi marker tersedia saat startup
  try:
    _cfg_init = load_json(config_path)
  except Exception as e:
    print(f"[limit-ip] Gagal load config: {e}", file=sys.stderr)
    return 1
  if find_marker_rule(_cfg_init, marker, "blocked") is None:
    print(f"[limit-ip] Marker rule tidak ditemukan: {marker}", file=sys.stderr)
    return 1

  seen = {}  # user -> ip -> last_seen_epoch
  last_restart = 0.0
  min_restart_interval = 15.0

  preload_cutoff = time.time() - float(window_seconds)
  for line in read_tail_lines(XRAY_ACCESS_LOG):
    line_ts = parse_access_timestamp(line)
    if line_ts is None or line_ts < preload_cutoff:
      continue
    user, ip = parse_line(line)
    if not user or not ip:
      continue
    last_restart = process_event(
      config_path, marker, seen, user, ip, line_ts, window_seconds, last_restart, min_restart_interval
    )

  for line in tail_follow(XRAY_ACCESS_LOG):
    user, ip = parse_line(line)
    if not user or not ip:
      continue
    last_restart = process_event(
      config_path, marker, seen, user, ip, time.time(), window_seconds, last_restart, min_restart_interval
    )

  return 0

def cli():
  ap = argparse.ArgumentParser(prog="limit-ip")
  sub = ap.add_subparsers(dest="cmd", required=True)

  p_set = sub.add_parser("set")
  p_set.add_argument("username")
  p_set.add_argument("--enable", action="store_true")
  p_set.add_argument("--disable", action="store_true")
  p_set.add_argument("--limit", type=int)

  p_unlock = sub.add_parser("unlock")
  p_unlock.add_argument("username")

  p_watch = sub.add_parser("watch")
  p_watch.add_argument("--config", default=XRAY_CONFIG_DEFAULT)
  p_watch.add_argument("--marker", default="dummy-limit-user")
  p_watch.add_argument("--window-seconds", type=int, default=600)

  args = ap.parse_args()

  if args.cmd == "set":
    if args.enable and args.disable:
      ap.error("Pilih salah satu: --enable atau --disable")
    enabled = None
    if args.enable:
      enabled = True
    if args.disable:
      enabled = False
    set_status(args.username, enabled=enabled, limit=args.limit)
    print("OK")
    return 0

  if args.cmd == "unlock":
    unlock_user(args.username)
    # BUG-01 fix: read routing config INSIDE lock, same pattern as other daemons
    def do_unlock(cfg):
      rule = find_marker_rule(cfg, "dummy-limit-user", "blocked")
      if rule is None:
        return False
      return remove_user(rule, args.username)
    changed, _ = load_and_modify_routing_locked(XRAY_CONFIG_DEFAULT, do_unlock)
    if changed:
      restart_xray()
    print("OK")
    return 0

  if args.cmd == "watch":
    return watch(args.config, args.marker, args.window_seconds)

  return 0

if __name__ == "__main__":
  raise SystemExit(cli())

EOF
  chmod +x /usr/local/bin/limit-ip

  cat > /usr/local/bin/user-block <<'EOF'
#!/usr/bin/env python3
import argparse
import json
import os
import subprocess
from datetime import datetime, timezone

XRAY_CONFIG_DEFAULT = "/usr/local/etc/xray/conf.d/30-routing.json"
QUOTA_ROOT = "/opt/quota"
PROTO_DIRS = ("vless", "vmess", "trojan")

def now_iso():
  return datetime.now().strftime("%Y-%m-%d %H:%M")

def load_json(path):
  with open(path, "r", encoding="utf-8") as f:
    return json.load(f)

def save_json_atomic(path, data):
  # BUG-10 fix: use mkstemp (unique name) instead of fixed "{path}.tmp"
  # to prevent concurrent writers from corrupting each other's tmp file.
  import tempfile
  dirn = os.path.dirname(path) or "."
  st_mode = None
  st_uid = None
  st_gid = None
  try:
    st = os.stat(path)
    st_mode = st.st_mode & 0o777
    st_uid = st.st_uid
    st_gid = st.st_gid
  except FileNotFoundError:
    pass
  fd, tmp = tempfile.mkstemp(prefix=".tmp.", suffix=".json", dir=dirn)
  try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
      json.dump(data, f, indent=2)
      f.write("\n")
      f.flush()
      os.fsync(f.fileno())
    if st_mode is not None:
      os.chmod(tmp, st_mode)
    if st_uid is not None and st_gid is not None:
      try:
        os.chown(tmp, st_uid, st_gid)
      except PermissionError:
        pass
    os.replace(tmp, path)
  except Exception:
    try:
      if os.path.exists(tmp):
        os.remove(tmp)
    except Exception:
      pass
    raise

ROUTING_LOCK_PATH = "/run/autoscript/locks/xray-routing.lock"

def save_routing_atomic_locked(config_path, cfg):
  """Tulis routing config secara atomik dengan file lock bersama."""
  import fcntl
  lock_dir = os.path.dirname(ROUTING_LOCK_PATH) or "/run/autoscript/locks"
  os.makedirs(lock_dir, exist_ok=True)
  try:
    os.chmod(lock_dir, 0o700)
  except Exception:
    pass
  with open(ROUTING_LOCK_PATH, "w") as lf:
    try:
      fcntl.flock(lf, fcntl.LOCK_EX)
      save_json_atomic(config_path, cfg)
    finally:
      fcntl.flock(lf, fcntl.LOCK_UN)

def load_and_modify_routing_locked(config_path, modify_fn):
  """BUG-01 fix: acquire lock, reload config from disk, apply modify_fn, save.
  This prevents last-write-wins race condition when multiple daemons write routing.
  Returns (changed: bool, cfg: dict)."""
  import fcntl
  lock_dir = os.path.dirname(ROUTING_LOCK_PATH) or "/run/autoscript/locks"
  os.makedirs(lock_dir, exist_ok=True)
  try:
    os.chmod(lock_dir, 0o700)
  except Exception:
    pass
  with open(ROUTING_LOCK_PATH, "w") as lf:
    try:
      fcntl.flock(lf, fcntl.LOCK_EX)
      # Reload from disk while holding the lock — picks up any concurrent changes
      cfg = load_json(config_path)
      changed = modify_fn(cfg)
      if changed:
        save_json_atomic(config_path, cfg)
      return changed, cfg
    finally:
      fcntl.flock(lf, fcntl.LOCK_UN)

def restart_xray():
  # BUG-FIX: fungsi ini wajib ada di user-block — sebelumnya tidak terdefinisi
  # sehingga user-block crash NameError saat block/unblock dipanggil.
  subprocess.run(["systemctl", "restart", "xray"], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def find_marker_rule(cfg, marker, outbound_tag):
  # BUG-FIX: fungsi ini wajib ada di user-block — sebelumnya hanya terdefinisi
  # di xray-quota sehingga user-block crash NameError saat modify() dijalankan.
  rules = ((cfg.get("routing") or {}).get("rules")) or []
  for r in rules:
    if r.get("type") != "field":
      continue
    if r.get("outboundTag") != outbound_tag:
      continue
    users = r.get("user") or []
    if isinstance(users, list) and marker in users:
      return r
  return None

def ensure_user(rule, username, marker):
  # BUG-FIX: fungsi ini wajib ada di user-block — sebelumnya tidak terdefinisi.
  users = rule.get("user") or []
  if not isinstance(users, list):
    users = []
  if marker not in users:
    users.insert(0, marker)
  if username not in users:
    users.append(username)
    rule["user"] = users
    return True
  rule["user"] = users
  return False

def remove_user(rule, username):
  # BUG-FIX: fungsi ini wajib ada di user-block — sebelumnya tidak terdefinisi.
  users = rule.get("user") or []
  if not isinstance(users, list) or username not in users:
    return False
  rule["user"] = [u for u in users if u != username]
  return True

def quota_paths_for_user(username):
  """Kembalikan path quota JSON untuk username.
  Mendukung format baru (username@proto.json) dan format kompatibilitas (username.json).
  Jika username berisi '@', prioritaskan proto yang sesuai sebelum fallback ke semua proto."""
  paths = []
  if "@" in username:
    parts = username.split("@", 1)
    email_proto = parts[1] if len(parts) == 2 else ""
    if email_proto in PROTO_DIRS:
      p = os.path.join(QUOTA_ROOT, email_proto, f"{username}.json")
      if os.path.isfile(p):
        paths.append(p)
    if not paths:
      for proto in PROTO_DIRS:
        if proto == email_proto:
          continue
        p = os.path.join(QUOTA_ROOT, proto, f"{username}.json")
        if os.path.isfile(p) and p not in paths:
          paths.append(p)
  else:
    for proto in PROTO_DIRS:
      candidates = [
        os.path.join(QUOTA_ROOT, proto, f"{username}@{proto}.json"),
        os.path.join(QUOTA_ROOT, proto, f"{username}.json"),
      ]
      for p in candidates:
        if os.path.isfile(p) and p not in paths:
          paths.append(p)
  return paths

def update_quota_status(username, manual_block):
  for p in quota_paths_for_user(username):
    try:
      meta = load_json(p)
    except Exception:
      continue
    if not isinstance(meta, dict):
      continue
    st_raw = meta.get("status") if isinstance(meta, dict) else {}
    st = st_raw if isinstance(st_raw, dict) else {}
    st["manual_block"] = bool(manual_block)
    if manual_block:
      st["lock_reason"] = "manual"
      st["locked_at"] = now_iso()
    else:
      if st.get("lock_reason") == "manual":
        # BUG-05 fix: correct priority order is manual > quota > ip_limit.
        # Previously ip_limit was checked before quota (wrong order).
        if bool(st.get("quota_exhausted", False)):
          st["lock_reason"] = "quota"
        elif bool(st.get("ip_limit_locked", False)):
          st["lock_reason"] = "ip_limit"
        else:
          st["lock_reason"] = ""
          st["locked_at"] = ""
    meta["status"] = st
    save_json_atomic(p, meta)

def main():
  ap = argparse.ArgumentParser(prog="user-block")
  ap.add_argument("action", choices=["block", "unblock"])
  ap.add_argument("username")
  ap.add_argument("--config", default=XRAY_CONFIG_DEFAULT)
  ap.add_argument("--marker", default="dummy-block-user")
  args = ap.parse_args()

  # BUG-01 fix: use load_and_modify_routing_locked so config is read INSIDE the
  # exclusive lock. Previously cfg was loaded before acquiring the lock, allowing
  # concurrent daemons (xray-quota, limit-ip) to overwrite changes made here.
  marker = args.marker
  username = args.username
  action = args.action

  def modify(cfg):
    rule = find_marker_rule(cfg, marker, "blocked")
    if rule is None:
      raise SystemExit(f"Marker rule not found: {marker}")
    if action == "block":
      return ensure_user(rule, username, marker)
    else:
      return remove_user(rule, username)

  changed, _ = load_and_modify_routing_locked(args.config, modify)

  # Update quota file status (outside lock — quota files have their own atomicity)
  if action == "block":
    update_quota_status(username, True)
  else:
    update_quota_status(username, False)

  if changed:
    restart_xray()

  print("OK")

if __name__ == "__main__":
  main()
EOF
  chmod +x /usr/local/bin/user-block


  cat > /usr/local/bin/xray-quota <<'EOF'
#!/usr/bin/env python3
import argparse
import json
import os
import subprocess
import time
from datetime import datetime, timezone

XRAY_CONFIG_DEFAULT = "/usr/local/etc/xray/conf.d/30-routing.json"
API_SERVER_DEFAULT = "127.0.0.1:10080,127.0.0.1:10085"
API_SERVER_FALLBACKS = ("127.0.0.1:10080", "127.0.0.1:10085")
QUOTA_ROOT = "/opt/quota"
PROTO_DIRS = ("vless", "vmess", "trojan")

GB_DECIMAL = 1000 ** 3
GB_BINARY = 1024 ** 3

def now_iso():
  return datetime.now().strftime("%Y-%m-%d %H:%M")

def load_json(path):
  with open(path, "r", encoding="utf-8") as f:
    return json.load(f)

def save_json_atomic(path, data):
  # BUG-10 fix: use mkstemp (unique name) instead of fixed "{path}.tmp"
  # to prevent concurrent writers from corrupting each other's tmp file.
  import tempfile
  dirn = os.path.dirname(path) or "."
  st_mode = None
  st_uid = None
  st_gid = None
  try:
    st = os.stat(path)
    st_mode = st.st_mode & 0o777
    st_uid = st.st_uid
    st_gid = st.st_gid
  except FileNotFoundError:
    pass
  fd, tmp = tempfile.mkstemp(prefix=".tmp.", suffix=".json", dir=dirn)
  try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
      json.dump(data, f, indent=2)
      f.write("\n")
      f.flush()
      os.fsync(f.fileno())
    if st_mode is not None:
      os.chmod(tmp, st_mode)
    if st_uid is not None and st_gid is not None:
      try:
        os.chown(tmp, st_uid, st_gid)
      except PermissionError:
        pass
    os.replace(tmp, path)
  except Exception:
    try:
      if os.path.exists(tmp):
        os.remove(tmp)
    except Exception:
      pass
    raise

ROUTING_LOCK_PATH = "/run/autoscript/locks/xray-routing.lock"

def save_routing_atomic_locked(config_path, cfg):
  """Tulis routing config secara atomik dengan file lock bersama."""
  import fcntl
  lock_dir = os.path.dirname(ROUTING_LOCK_PATH) or "/run/autoscript/locks"
  os.makedirs(lock_dir, exist_ok=True)
  try:
    os.chmod(lock_dir, 0o700)
  except Exception:
    pass
  with open(ROUTING_LOCK_PATH, "w") as lf:
    try:
      fcntl.flock(lf, fcntl.LOCK_EX)
      save_json_atomic(config_path, cfg)
    finally:
      fcntl.flock(lf, fcntl.LOCK_UN)

def load_and_modify_routing_locked(config_path, modify_fn):
  """Acquire lock, reload config from disk, apply modify_fn, then save atomically.
  Mencegah race condition last-write-wins antar daemon yang menulis routing."""
  import fcntl
  lock_dir = os.path.dirname(ROUTING_LOCK_PATH) or "/run/autoscript/locks"
  os.makedirs(lock_dir, exist_ok=True)
  try:
    os.chmod(lock_dir, 0o700)
  except Exception:
    pass
  with open(ROUTING_LOCK_PATH, "w") as lf:
    try:
      fcntl.flock(lf, fcntl.LOCK_EX)
      cfg = load_json(config_path)
      changed = modify_fn(cfg)
      if changed:
        save_json_atomic(config_path, cfg)
      return changed, cfg
    finally:
      fcntl.flock(lf, fcntl.LOCK_UN)

def restart_xray():
  subprocess.run(["systemctl", "restart", "xray"], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def parse_int(v):
  try:
    if v is None:
      return 0
    if isinstance(v, bool):
      return int(v)
    if isinstance(v, (int, float)):
      return int(v)
    s = str(v).strip()
    if s == "":
      return 0
    return int(float(s))
  except Exception:
    return 0

def parse_bool(v):
  if isinstance(v, bool):
    return v
  if v is None:
    return False
  s = str(v).strip().lower()
  return s in ("1", "true", "yes", "y", "on")

def normalize_quota_limit(meta, raw_limit):
  unit_raw = (meta.get("quota_unit") if isinstance(meta, dict) else "") or ""
  unit = str(unit_raw).strip().lower()

  # Preserve unit string asli agar tidak overwrite 'binary' -> 'gib' di file JSON.
  # Kembalikan (raw_limit, unit_string_asli, bytes_per_gb).
  # manage.sh menulis "binary"; daemon ini tidak boleh mengubahnya menjadi "gib"
  # karena keduanya berarti hal yang sama (1024**3) tapi label jadi tidak konsisten.

  # Binary unit group (GiB = 1024^3)
  if unit in ("gib", "binary", "1024", "gibibyte"):
    return raw_limit, unit, GB_BINARY

  # Decimal unit group (GB = 1000^3)
  if unit in ("decimal", "gb", "1000", "gigabyte"):
    return raw_limit, unit, GB_DECIMAL

  # Heuristic (backward compat):
  # If limit is an exact multiple of decimal GB but not GiB, keep decimal.
  if raw_limit > 0 and raw_limit % GB_DECIMAL == 0 and raw_limit % GB_BINARY != 0:
    return raw_limit, "decimal", GB_DECIMAL

  # Default: treat as GiB bytes (1 GB = 1073741824 B)
  return raw_limit, "binary", GB_BINARY

def find_marker_rule(cfg, marker, outbound_tag):
  rules = ((cfg.get("routing") or {}).get("rules")) or []
  for r in rules:
    if r.get("type") != "field":
      continue
    if r.get("outboundTag") != outbound_tag:
      continue
    users = r.get("user") or []
    if isinstance(users, list) and marker in users:
      return r
  return None

def ensure_user(rule, username, marker):
  users = rule.get("user") or []
  if not isinstance(users, list):
    users = []
  if marker not in users:
    users.insert(0, marker)
  if username not in users:
    users.append(username)
    rule["user"] = users
    return True
  rule["user"] = users
  return False

def remove_user(rule, username):
  users = rule.get("user") or []
  if not isinstance(users, list) or username not in users:
    return False
  rule["user"] = [u for u in users if u != username]
  return True

def iter_quota_files():
  for proto in PROTO_DIRS:
    d = os.path.join(QUOTA_ROOT, proto)
    if not os.path.isdir(d):
      continue
    for name in os.listdir(d):
      if name.endswith(".json"):
        yield proto, os.path.join(d, name)

def _api_server_candidates(api_server):
  ordered = []
  raw = str(api_server or "").strip()
  if raw:
    for part in raw.split(","):
      cand = part.strip()
      if cand and cand not in ordered:
        ordered.append(cand)
  for cand in API_SERVER_FALLBACKS:
    if cand not in ordered:
      ordered.append(cand)
  return ordered

def fetch_all_user_traffic(api_server):
  # Xray stats name format (bytes):
  # - user>>>[email]>>>traffic>>>uplink
  # - user>>>[email]>>>traffic>>>downlink
  candidates = _api_server_candidates(api_server)
  data = None
  last_error = ""

  for server in candidates:
    try:
      out = subprocess.check_output(
        ["xray", "api", "statsquery", f"--server={server}", "--pattern", "user>>>"],
        text=True,
        stderr=subprocess.DEVNULL,
      )
      data = json.loads(out)
      break
    except subprocess.CalledProcessError as e:
      last_error = f"exit {e.returncode} @ {server}"
      continue
    except FileNotFoundError:
      import sys
      print(f"[xray-quota] WARN: perintah 'xray' tidak ditemukan. Quota tidak diupdate.", file=sys.stderr)
      return {}
    except json.JSONDecodeError as e:
      last_error = f"JSON decode error @ {server}: {e}"
      continue
    except Exception as e:
      last_error = f"error @ {server}: {e}"
      continue

  if data is None:
    import sys
    shown = ", ".join(candidates)
    print(
      f"[xray-quota] WARN: xray api statsquery gagal untuk semua endpoint [{shown}]. "
      f"Detail terakhir: {last_error or 'tidak ada detail'}. Quota tidak diupdate siklus ini.",
      file=sys.stderr,
    )
    return {}

  traffic = {}  # email -> {"uplink": int, "downlink": int}
  for it in data.get("stat") or []:
    name = it.get("name") if isinstance(it, dict) else None
    if not isinstance(name, str):
      continue
    parts = name.split(">>>")
    if len(parts) < 4:
      continue
    if parts[0] != "user" or parts[2] != "traffic":
      continue
    email = parts[1]
    direction = parts[3]
    val = parse_int(it.get("value") if isinstance(it, dict) else None)
    d = traffic.setdefault(email, {"uplink": 0, "downlink": 0})
    if direction == "uplink":
      d["uplink"] = val
    elif direction == "downlink":
      d["downlink"] = val

  totals = {}
  for email, d in traffic.items():
    totals[email] = parse_int(d.get("uplink")) + parse_int(d.get("downlink"))
  return totals

def ensure_quota_status(meta, exhausted, q_limit, xray_used, q_unit, bpg):
  st_raw = meta.get("status") if isinstance(meta, dict) else {}
  st = st_raw if isinstance(st_raw, dict) else {}
  changed = False

  xray_used_eff = max(0, parse_int(xray_used))

  if meta.get("quota_limit") != q_limit:
    meta["quota_limit"] = q_limit
    changed = True

  if parse_int(meta.get("xray_usage_bytes")) != xray_used_eff:
    meta["xray_usage_bytes"] = xray_used_eff
    changed = True

  if meta.get("quota_used") != xray_used_eff:
    meta["quota_used"] = xray_used_eff
    changed = True

  if meta.get("quota_unit") != q_unit:
    meta["quota_unit"] = q_unit
    changed = True
  if parse_int(meta.get("quota_bytes_per_gb")) != parse_int(bpg):
    meta["quota_bytes_per_gb"] = int(bpg)
    changed = True

  if bool(st.get("quota_exhausted", False)) != bool(exhausted):
    st["quota_exhausted"] = bool(exhausted)
    changed = True

  if exhausted:
    # Hanya set lock_reason = "quota" jika tidak ada lock lain yang lebih prioritas.
    # BUG-FIX #5: Seragamkan urutan prioritas dengan manage.sh dan user-block:
    # manual > quota > ip_limit  (bukan: manual > ip_limit > quota seperti sebelumnya)
    # Jangan overwrite lock_reason "manual" yang sedang aktif.
    cur_reason    = st.get("lock_reason") or ""
    manual_active = bool(st.get("manual_block", False))
    iplimit_active = bool(st.get("ip_limit_locked", False))
    if manual_active:
      if cur_reason != "manual":
        st["lock_reason"] = "manual"
        changed = True
    else:
      # quota lebih prioritas dari ip_limit (konsisten dengan manage.sh BUG-05 fix)
      if cur_reason != "quota":
        st["lock_reason"] = "quota"
        changed = True
    if not st.get("locked_at"):
      st["locked_at"] = now_iso()
      changed = True
  else:
    # Quota tidak exhausted: bersihkan flag quota jika sebelumnya dikunci karena quota.
    # Jangan sentuh lock_reason lain (manual, ip_limit) — hanya bersihkan milik quota.
    if st.get("lock_reason") == "quota":
      # BUG-FIX #5: Turunkan ke lock_reason berikutnya dengan urutan yang seragam:
      # manual > quota > ip_limit
      if bool(st.get("manual_block", False)):
        st["lock_reason"] = "manual"
      elif bool(st.get("ip_limit_locked", False)):
        st["lock_reason"] = "ip_limit"
      else:
        st["lock_reason"] = ""
        st["locked_at"] = ""
      changed = True

  meta["status"] = st
  return changed

def run_once(config_path, marker, api_server, dry_run=False):
  try:
    cfg = load_json(config_path)
  except Exception:
    return 0

  rule = find_marker_rule(cfg, marker, "blocked")
  if rule is None:
    return 0

  totals = fetch_all_user_traffic(api_server)

  changed_cfg = False
  exhausted_users = []
  ok_users = []

  import fcntl
  for proto, path in iter_quota_files():
    lock_path = f"{path}.lock"
    lock_dir = os.path.dirname(lock_path) or "."
    os.makedirs(lock_dir, exist_ok=True)
    try:
      os.chmod(lock_dir, 0o700)
    except Exception:
      pass
    with open(lock_path, "a+", encoding="utf-8") as lf:
      fcntl.flock(lf.fileno(), fcntl.LOCK_EX)
      try:
        try:
          meta = load_json(path)
        except Exception:
          continue
        if not isinstance(meta, dict):
          continue

        username = os.path.splitext(os.path.basename(path))[0]
        u2 = meta.get("username")
        if isinstance(u2, str) and u2.strip():
          username = u2.strip()
        if not username:
          continue
        user_email = username if "@" in username else f"{username}@{proto}"

        raw_limit = parse_int(meta.get("quota_limit"))
        q_limit, q_unit, bpg = normalize_quota_limit(meta, raw_limit)
        prev_used = parse_int(meta.get("quota_used"))
        prev_xray_used = parse_int(meta.get("xray_usage_bytes") if "xray_usage_bytes" in meta else prev_used)
        baseline = max(0, parse_int(meta.get("xray_api_baseline_bytes")))
        carry = max(0, parse_int(meta.get("xray_usage_carry_bytes")))
        last_total = max(0, parse_int(meta.get("xray_api_last_total_bytes")))
        reset_pending = parse_bool(meta.get("xray_usage_reset_pending", False))
        has_api_total = (user_email in totals)
        api_total = parse_int(totals.get(user_email, 0))

        meta_changed = False
        if reset_pending:
          # Tahan reset_pending sampai API Xray tersedia, agar baseline bisa
          # diambil dari counter kumulatif real-time dan tidak rebound saat API
          # sempat unavailable.
          carry = 0
          xray_used = 0
          if has_api_total:
            baseline = api_total
            last_total = api_total
            if parse_bool(meta.get("xray_usage_reset_pending", False)):
              meta["xray_usage_reset_pending"] = False
              meta_changed = True
          else:
            # API belum ada: biarkan reset_pending tetap true untuk dicoba lagi
            # di siklus berikutnya.
            pass
        else:
          # Gunakan nilai API Xray kumulatif dan kurangi baseline reset.
          # Jika API tidak memberi nilai, fallback ke nilai metadata sebelumnya.
          if has_api_total:
            # Jika counter API restart/turun (api_total < last_total), lanjutkan
            # akumulasi dari usage sebelumnya agar quota tidak "jatuh" ke 0.
            if api_total < last_total:
              carry = max(0, prev_xray_used)
              baseline = 0
            xray_used = max(0, carry + max(0, api_total - baseline))
            last_total = api_total
          else:
            xray_used = prev_xray_used
          if parse_bool(meta.get("xray_usage_reset_pending", False)):
            meta["xray_usage_reset_pending"] = False
            meta_changed = True

        if parse_int(meta.get("xray_api_baseline_bytes")) != baseline:
          meta["xray_api_baseline_bytes"] = baseline
          meta_changed = True
        if parse_int(meta.get("xray_usage_carry_bytes")) != carry:
          meta["xray_usage_carry_bytes"] = carry
          meta_changed = True
        if parse_int(meta.get("xray_api_last_total_bytes")) != last_total:
          meta["xray_api_last_total_bytes"] = last_total
          meta_changed = True

        exhausted = (q_limit > 0 and xray_used >= q_limit)
        if ensure_quota_status(meta, exhausted, q_limit, xray_used, q_unit, bpg):
          meta_changed = True

        if meta_changed and not dry_run:
          try:
            save_json_atomic(path, meta)
          except Exception:
            pass

        if exhausted:
          exhausted_users.append(user_email)
        else:
          ok_users.append(user_email)
      finally:
        fcntl.flock(lf.fileno(), fcntl.LOCK_UN)

  if not exhausted_users and not ok_users:
    return 0

  if dry_run:
    return 0

  # BUG-FIX #4: Gunakan load_and_modify_routing_locked agar load + modify + save
  # semua terjadi di dalam satu exclusive lock yang sama. Pola sebelumnya
  # (load di luar lock, save di dalam lock) membuka race condition: daemon lain
  # bisa menulis routing config antara load cfg_fresh dan akuisisi lock save,
  # sehingga perubahan mereka ter-overwrite. Dengan load_and_modify_routing_locked,
  # reload dari disk terjadi setelah lock acquired — perubahan concurrent aman.
  captured_exhausted = list(dict.fromkeys(exhausted_users))  # stable unique
  captured_ok = list(dict.fromkeys(ok_users))  # stable unique

  def do_block(cfg_live):
    rule_live = find_marker_rule(cfg_live, marker, "blocked")
    if rule_live is None:
      return False
    changed = False
    for username in captured_exhausted:
      if ensure_user(rule_live, username, marker):
        changed = True
    for username in captured_ok:
      if remove_user(rule_live, username):
        changed = True
    return changed

  try:
    changed_cfg, _ = load_and_modify_routing_locked(config_path, do_block)
  except Exception:
    return 0

  if changed_cfg:
    restart_xray()

  return 0

def main():
  ap = argparse.ArgumentParser(prog="xray-quota")
  sub = ap.add_subparsers(dest="cmd", required=True)

  p_once = sub.add_parser("once")
  p_once.add_argument("--config", default=XRAY_CONFIG_DEFAULT)
  p_once.add_argument("--marker", default="dummy-quota-user")
  p_once.add_argument("--api-server", default=API_SERVER_DEFAULT)
  p_once.add_argument("--dry-run", action="store_true")

  p_watch = sub.add_parser("watch")
  p_watch.add_argument("--config", default=XRAY_CONFIG_DEFAULT)
  p_watch.add_argument("--marker", default="dummy-quota-user")
  p_watch.add_argument("--api-server", default=API_SERVER_DEFAULT)
  p_watch.add_argument("--interval", type=int, default=2)
  p_watch.add_argument("--dry-run", action="store_true")

  args = ap.parse_args()

  if args.cmd == "once":
    return run_once(args.config, args.marker, args.api_server, dry_run=args.dry_run)

  interval = max(2, int(args.interval))
  while True:
    try:
      run_once(args.config, args.marker, args.api_server, dry_run=args.dry_run)
    except Exception:
      pass
    time.sleep(interval)

if __name__ == "__main__":
  raise SystemExit(main())

EOF
  chmod +x /usr/local/bin/xray-quota
  local backup_manage_src="${SETUP_BIN_SRC_DIR:-${SCRIPT_DIR}/opt/setup/bin}/backup-manage.py"
  if [[ -f "${backup_manage_src}" ]]; then
    install -d -m 0755 /usr/local/bin
    install -m 0755 "${backup_manage_src}" /usr/local/bin/backup-manage
    chown root:root /usr/local/bin/backup-manage 2>/dev/null || true
  fi
  render_setup_template_or_die \
    "config/backup-cloud.env" \
    "/etc/autoscript/backup/config.env" \
    0644
  render_setup_template_or_die \
    "systemd/xray-expired.service" \
    "/etc/systemd/system/xray-expired.service" \
    0644

  render_setup_template_or_die \
    "systemd/xray-limit-ip.service" \
    "/etc/systemd/system/xray-limit-ip.service" \
    0644

  render_setup_template_or_die \
    "systemd/xray-quota.service" \
    "/etc/systemd/system/xray-quota.service" \
    0644

  systemctl daemon-reload
  if ! service_enable_restart_checked xray-expired; then
    journalctl -u xray-expired -n 120 --no-pager >&2 || true
    die "xray-expired gagal diaktifkan. Cek log di atas."
  fi
  if ! service_enable_restart_checked xray-limit-ip; then
    journalctl -u xray-limit-ip -n 120 --no-pager >&2 || true
    die "xray-limit-ip gagal diaktifkan. Cek log di atas."
  fi
  if ! service_enable_restart_checked xray-quota; then
    journalctl -u xray-quota -n 120 --no-pager >&2 || true
    die "xray-quota gagal diaktifkan. Cek log di atas."
  fi

  ok "Tools runtime siap:"
  ok "  - /usr/local/bin/xray-expired (service: xray-expired)"
  ok "  - /usr/local/bin/limit-ip     (service: xray-limit-ip)"
  ok "  - /usr/local/bin/user-block   (CLI)"
  ok "  - /usr/local/bin/xray-quota    (service: xray-quota)"
  ok "  - /usr/local/bin/backup-manage (CLI local/cloud backup)"
}

sync_manage_modules_layout() {
  local tmpdir="" bundle_file="" downloaded="0" extracted_modules_dir="" extracted_manage_bin=""
  local fallback_modules_dir="${MANAGE_FALLBACK_MODULES_DST_DIR:-/usr/local/lib/autoscript-manage/opt/manage}"

  install_bot_installer_if_present() {
    # args: src_path dst_path label
    local src_path="$1"
    local dst_path="$2"
    local label="$3"
    if [[ -f "${src_path}" ]]; then
      mkdir -p "$(dirname "${dst_path}")"
      install -m 0755 "${src_path}" "${dst_path}"
      chown root:root "${dst_path}" 2>/dev/null || true
      ok "Installer ${label} diperbarui."
    fi
  }

  sync_manage_target_dir() {
    local src_dir="$1"
    local dst_dir="$2"
    sync_tree_atomic "${src_dir}" "${dst_dir}" "modul manage ${dst_dir}"
    find "${dst_dir}" -type d -exec chmod 755 {} + 2>/dev/null || true
    find "${dst_dir}" -type f -name '*.sh' -exec chmod 644 {} + 2>/dev/null || true
    chown -R root:root "${dst_dir}" 2>/dev/null || true
  }

  install_ssh_network_restore_service() {
    render_setup_template_or_die \
      "systemd/ssh-network-restore.service" \
      "/etc/systemd/system/ssh-network-restore.service" \
      0644
    local restore_result=""
    systemctl daemon-reload
    if ! systemctl enable ssh-network-restore.service >/dev/null 2>&1; then
      die "Gagal mengaktifkan ssh-network-restore.service."
    fi
    systemctl reset-failed ssh-network-restore.service >/dev/null 2>&1 || true
    if ! systemctl restart ssh-network-restore.service >/dev/null 2>&1; then
      systemctl status ssh-network-restore.service --no-pager >&2 || true
      journalctl -u ssh-network-restore.service -n 80 --no-pager >&2 || true
      die "ssh-network-restore.service gagal dijalankan saat setup."
    fi
    restore_result="$(systemctl show -p Result --value ssh-network-restore.service 2>/dev/null || true)"
    if [[ "${restore_result}" != "success" ]] || ! systemctl is-active --quiet ssh-network-restore.service; then
      systemctl status ssh-network-restore.service --no-pager >&2 || true
      journalctl -u ssh-network-restore.service -n 80 --no-pager >&2 || true
      die "ssh-network-restore.service tidak sehat setelah restart (Result=${restore_result:-unknown})."
    fi
  }

  sync_manage_from_local_source() {
    [[ -d "${MANAGE_MODULES_SRC_DIR}" ]] || return 1
    [[ -f "${SCRIPT_DIR}/manage.sh" ]] || {
      warn "Source lokal modular manage ditemukan, tetapi manage.sh tidak ada di ${SCRIPT_DIR}."
      return 1
    }

    sync_manage_target_dir "${MANAGE_MODULES_SRC_DIR}" "${MANAGE_MODULES_DST_DIR}"
    sync_manage_target_dir "${MANAGE_MODULES_SRC_DIR}" "${fallback_modules_dir}"

    mkdir -p "$(dirname "${MANAGE_BIN}")"
    install -m 0755 "${SCRIPT_DIR}/manage.sh" "${MANAGE_BIN}"
    chown root:root "${MANAGE_BIN}" 2>/dev/null || true
    install_ssh_network_restore_service
    ok "Binary manage disegarkan dari source lokal: ${MANAGE_BIN}"
    install_bot_installer_if_present "${SCRIPT_DIR}/install-telegram-bot.sh" "/usr/local/bin/install-telegram-bot" "Telegram"
    ok "Template modular manage siap di: ${MANAGE_MODULES_DST_DIR} (source lokal)"
    ok "Fallback modular manage siap di: ${fallback_modules_dir} (source lokal)"
    return 0
  }

  ok "Sync manage modules..."

  # Pada flow run.sh normal, source lokal dari repo selalu tersedia.
  # Default: prioritaskan source lokal agar rerun idempotent dan tidak tergantung
  # freshness manage_bundle.zip remote.
  if [[ "${PREFER_LOCAL_MANAGE_SOURCE:-1}" == "1" ]]; then
    if sync_manage_from_local_source; then
      return 0
    fi
    warn "Source lokal manage tidak ditemukan, beralih ke bundle remote."
  fi

  tmpdir="$(mktemp -d)"
  bundle_file="${tmpdir}/manage_bundle.zip"

  if download_file_checked "${MANAGE_BUNDLE_URL}" "${bundle_file}" "manage_bundle.zip"; then
    downloaded="1"
    ok "manage_bundle.zip berhasil diunduh dari repo."
  else
    warn "Gagal unduh manage_bundle.zip dari repo: ${MANAGE_BUNDLE_URL}"
  fi

  if [[ "${downloaded}" == "1" ]]; then
    extracted_modules_dir="${tmpdir}/manage-modules"
    extracted_manage_bin="${tmpdir}/manage.sh"
    if python3 - "${bundle_file}" "${extracted_modules_dir}" "${extracted_manage_bin}" "${SCRIPT_DIR}" <<'PY'
import os
import sys
import zipfile
from pathlib import PurePosixPath

zip_path, dst_root, manage_bin, local_root = sys.argv[1:5]
MODULE_PREFIX = "opt/manage/"

os.makedirs(dst_root, exist_ok=True)


def read_file(path):
  with open(path, "rb") as fh:
    return fh.read()


def normalize_member(name: str) -> str:
  if "\x00" in name:
    raise ValueError("zip entry contains NUL byte")
  posix = PurePosixPath(name)
  if posix.is_absolute() or ".." in posix.parts:
    raise ValueError(f"unsafe zip entry path: {name}")
  return posix.as_posix()


def local_manage_members(root: str) -> list[str]:
  base = os.path.join(root, "opt", "manage")
  if not os.path.isdir(base):
    return []
  members: list[str] = []
  for walk_root, dirs, files in os.walk(base):
    dirs.sort()
    files.sort()
    for filename in files:
      full = os.path.join(walk_root, filename)
      rel = os.path.relpath(full, root).replace(os.sep, "/")
      members.append(rel)
  return members


with zipfile.ZipFile(zip_path, "r") as zf:
  members = [normalize_member(name) for name in zf.namelist() if not name.endswith("/")]
  if "manage.sh" not in members:
    print("missing manage.sh in zip bundle", file=sys.stderr)
    raise SystemExit(3)

  module_members = sorted(name for name in members if name.startswith(MODULE_PREFIX))
  if not module_members:
    print("missing opt/manage payload in zip bundle", file=sys.stderr)
    raise SystemExit(3)

  manage_data = zf.read("manage.sh")
  payload = {member: zf.read(member) for member in module_members}

  # Guard anti bundle stale: jika setup dijalankan dari repo yang punya source lokal,
  # pastikan isi bundle identik. Jika tidak, paksa fallback ke source lokal.
  local_manage = os.path.join(local_root, "manage.sh")
  mismatch = []
  if os.path.isfile(local_manage) and read_file(local_manage) != manage_data:
    mismatch.append("manage.sh")

  local_members = local_manage_members(local_root)
  missing_from_bundle = sorted(set(local_members) - set(module_members))
  extra_in_bundle = sorted(set(module_members) - set(local_members))
  if missing_from_bundle:
    mismatch.extend(missing_from_bundle)
  if extra_in_bundle:
    mismatch.extend(extra_in_bundle)

  for member in sorted(set(local_members) & set(module_members)):
    local_path = os.path.join(local_root, member.replace("/", os.sep))
    if os.path.isfile(local_path) and read_file(local_path) != payload[member]:
      mismatch.append(member)

  if mismatch:
    print("bundle differs from local source: " + ", ".join(sorted(set(mismatch))), file=sys.stderr)
    raise SystemExit(4)

  for member, data in payload.items():
    dst_rel = member[len(MODULE_PREFIX):]
    dst_path = os.path.join(dst_root, dst_rel)
    os.makedirs(os.path.dirname(dst_path), exist_ok=True)
    with open(dst_path, "wb") as fh:
      fh.write(data)
    os.chmod(dst_path, 0o644)

  manage_dir = os.path.dirname(manage_bin)
  if manage_dir:
    os.makedirs(manage_dir, exist_ok=True)
  with open(manage_bin, "wb") as fh:
    fh.write(manage_data)
  os.chmod(manage_bin, 0o755)

for walk_root, dirs, _files in os.walk(dst_root):
  os.chmod(walk_root, 0o755)
  for dirname in dirs:
    os.chmod(os.path.join(walk_root, dirname), 0o755)
os.chmod(dst_root, 0o755)
PY
    then
      sync_manage_target_dir "${extracted_modules_dir}" "${MANAGE_MODULES_DST_DIR}"
      sync_manage_target_dir "${extracted_modules_dir}" "${fallback_modules_dir}"
      [[ -s "${extracted_manage_bin}" ]] || die "Binary manage hasil ekstraksi bundle kosong: ${extracted_manage_bin}"
      mkdir -p "$(dirname "${MANAGE_BIN}")"
      install -m 0755 "${extracted_manage_bin}" "${MANAGE_BIN}"
      chown root:root "${MANAGE_BIN}" 2>/dev/null || true
      install_ssh_network_restore_service
      install_bot_installer_if_present "${SCRIPT_DIR}/install-telegram-bot.sh" "/usr/local/bin/install-telegram-bot" "Telegram"
      ok "Template modular manage siap di: ${MANAGE_MODULES_DST_DIR}"
      ok "Fallback modular manage siap di: ${fallback_modules_dir}"
      ok "Binary manage disegarkan dari bundle: ${MANAGE_BIN}"
      [[ -n "${tmpdir}" ]] && rm -rf "${tmpdir}" >/dev/null 2>&1 || true
      return 0
    fi
    warn "Ekstrak manage_bundle.zip gagal; fallback ke source lokal."
  fi

  if sync_manage_from_local_source; then
    [[ -n "${tmpdir}" ]] && rm -rf "${tmpdir}" >/dev/null 2>&1 || true
    return 0
  fi

  [[ -n "${tmpdir}" ]] && rm -rf "${tmpdir}" >/dev/null 2>&1 || true
  die "Sinkronisasi modular manage gagal total: bundle gagal/invalid dan source lokal tidak ditemukan (${MANAGE_MODULES_SRC_DIR})."
}

sync_setup_runtime_layout() {
  local fallback_root="${SETUP_FALLBACK_ROOT:-/usr/local/lib/autoscript-setup}"
  local fallback_modules_root="${SETUP_FALLBACK_MODULES_ROOT:-${fallback_root}/opt/setup}"
  local setup_src="${SETUP_MODULES_ROOT:-${SCRIPT_DIR}/opt/setup}"
  local account_portal_src="${ACCOUNT_PORTAL_SRC_DIR:-${SCRIPT_DIR}/account-portal}"
  local adblock_src="${SCRIPT_DIR}/opt/adblock"
  local edge_src="${SCRIPT_DIR}/opt/edge"
  local badvpn_src="${SCRIPT_DIR}/opt/badvpn"
  local fallback_account_portal_root="${fallback_root}/account-portal"
  local fallback_adblock_root="${fallback_root}/opt/adblock"
  local fallback_edge_root="${fallback_root}/opt/edge"
  local fallback_badvpn_root="${fallback_root}/opt/badvpn"

  [[ -d "${setup_src}" ]] || die "Source modular setup tidak ditemukan: ${setup_src}"
  [[ -f "${SCRIPT_DIR}/setup.sh" ]] || die "Source setup.sh tidak ditemukan: ${SCRIPT_DIR}/setup.sh"

  sync_tree_atomic "${setup_src}" "${fallback_modules_root}" "modul setup ${fallback_modules_root}"
  if [[ -d "${account_portal_src}" ]]; then
    sync_tree_atomic "${account_portal_src}" "${fallback_account_portal_root}" "asset account portal ${fallback_account_portal_root}"
    find "${fallback_account_portal_root}" -type d -exec chmod 755 {} + 2>/dev/null || true
    find "${fallback_account_portal_root}" -type f -exec chmod 644 {} + 2>/dev/null || true
    chown -R root:root "${fallback_account_portal_root}" 2>/dev/null || true
  fi
  if [[ -d "${adblock_src}" ]]; then
    sync_tree_atomic "${adblock_src}" "${fallback_adblock_root}" "asset adblock ${fallback_adblock_root}"
    find "${fallback_adblock_root}" -type d -exec chmod 755 {} + 2>/dev/null || true
    find "${fallback_adblock_root}" -type f -name '*.go' -exec chmod 644 {} + 2>/dev/null || true
    find "${fallback_adblock_root}" -type f -name '*.mod' -exec chmod 644 {} + 2>/dev/null || true
    find "${fallback_adblock_root}" -type f -name '*.sum' -exec chmod 644 {} + 2>/dev/null || true
    find "${fallback_adblock_root}" -type f -name 'adblock-sync-linux-*' -exec chmod 755 {} + 2>/dev/null || true
    chown -R root:root "${fallback_adblock_root}" 2>/dev/null || true
  fi
  if [[ -d "${edge_src}" ]]; then
    sync_tree_atomic "${edge_src}" "${fallback_edge_root}" "asset edge ${fallback_edge_root}"
    find "${fallback_edge_root}" -type d -exec chmod 755 {} + 2>/dev/null || true
    find "${fallback_edge_root}" -type f -name '*.sh' -exec chmod 644 {} + 2>/dev/null || true
    find "${fallback_edge_root}" -type f -name '*.go' -exec chmod 644 {} + 2>/dev/null || true
    find "${fallback_edge_root}" -type f -name 'edge-mux-linux-*' -exec chmod 755 {} + 2>/dev/null || true
    chown -R root:root "${fallback_edge_root}" 2>/dev/null || true
  fi
  if [[ -d "${badvpn_src}" ]]; then
    sync_tree_atomic "${badvpn_src}" "${fallback_badvpn_root}" "asset badvpn ${fallback_badvpn_root}"
    find "${fallback_badvpn_root}" -type d -exec chmod 755 {} + 2>/dev/null || true
    find "${fallback_badvpn_root}" -type f -name '*.sh' -exec chmod 644 {} + 2>/dev/null || true
    find "${fallback_badvpn_root}" -type f -name 'badvpn-udpgw-linux-*' -exec chmod 755 {} + 2>/dev/null || true
    chown -R root:root "${fallback_badvpn_root}" 2>/dev/null || true
  fi
  find "${fallback_modules_root}" -type d -exec chmod 755 {} + 2>/dev/null || true
  find "${fallback_modules_root}" -type f -name '*.sh' -exec chmod 644 {} + 2>/dev/null || true
  find "${fallback_modules_root}" -type f -name '*.py' -exec chmod 644 {} + 2>/dev/null || true
  chown -R root:root "${fallback_modules_root}" 2>/dev/null || true

  mkdir -p "$(dirname "${SETUP_FALLBACK_SCRIPT}")"
  install -m 0755 "${SCRIPT_DIR}/setup.sh" "${SETUP_FALLBACK_SCRIPT}"
  chown root:root "${SETUP_FALLBACK_SCRIPT}" 2>/dev/null || true
  ok "Fallback modular setup siap di: ${fallback_modules_root}"
  ok "Fallback script setup siap di: ${SETUP_FALLBACK_SCRIPT}"
}

refresh_account_info_runtime() {
  ok "Refresh ACCOUNT INFO otomatis dilewati; jalankan manual via Domain Control bila diperlukan."
  return 0
}
