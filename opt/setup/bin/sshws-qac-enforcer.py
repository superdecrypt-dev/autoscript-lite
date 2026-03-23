#!/usr/bin/env python3
import argparse
import csv
import fcntl
import grp
import ipaddress
import json
import os
import pathlib
import pwd
import re
import secrets
import shutil
import subprocess
import tempfile
import time

SSH_STATE_ROOT = pathlib.Path("/opt/quota/ssh")
OPENVPN_STATE_ROOT = pathlib.Path("/opt/quota/openvpn")
LOCK_FILE = pathlib.Path("/run/autoscript/locks/sshws-qac.lock")
SESSION_ROOT = pathlib.Path("/run/autoscript/sshws-sessions")
SESSION_USER_INDEX_ROOT = SESSION_ROOT / ".by-user"
SSH_NETWORK_CONFIG_FILE = pathlib.Path("/etc/autoscript/ssh-network/config.env")
SSH_NETWORK_SYNC_CACHE_FILE = pathlib.Path("/run/autoscript/cache/ssh-network-session-targets.json")
OPENVPN_CONFIG_FILE = pathlib.Path("/etc/autoscript/openvpn/config.env")
OPENVPN_QAC_CACHE_FILE = pathlib.Path("/run/autoscript/cache/openvpn-qac-bytes.json")
OPENVPN_QAC_PENDING_DIR = pathlib.Path("/run/openvpn-qac-disconnect")
OPENVPN_CONNECT_POLICY_DIR = pathlib.Path("/run/openvpn-connect-policy")
OPENVPN_SESSION_KILL_BIN = pathlib.Path("/usr/local/bin/openvpn-session-kill")
LOCK_SHELL_CANDIDATES = (
  "/usr/sbin/nologin",
  "/usr/bin/nologin",
  "/sbin/nologin",
  "/bin/false",
)

def env_int(name, default):
  try:
    raw = os.environ.get(name)
    if raw is None:
      return int(default)
    text = str(raw).strip()
    if not text:
      return int(default)
    return int(float(text))
  except Exception:
    return int(default)

RUNTIME_SESSION_STALE_SEC = max(15, env_int("SSHWS_RUNTIME_SESSION_STALE_SEC", 90))


def read_env_map(path):
  data = {}
  env_path = pathlib.Path(path)
  if not env_path.is_file():
    return data
  try:
    lines = env_path.read_text(encoding="utf-8", errors="ignore").splitlines()
  except Exception:
    return data
  for raw in lines:
    line = str(raw or "").strip()
    if not line or line.startswith("#") or "=" not in line:
      continue
    key, value = line.split("=", 1)
    data[str(key).strip()] = str(value).strip()
  return data

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

def normalize_token(v):
  s = str(v or "").strip().lower()
  if re.fullmatch(r"[a-f0-9]{10}", s):
    return s
  return ""

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


def normalize_real_address_ip(value):
  raw = str(value or "").strip()
  if not raw:
    return ""
  if raw.startswith("["):
    right = raw.find("]")
    if right > 1:
      return normalize_ip(raw[1:right])
  if raw.count(":") > 1:
    head, sep, tail = raw.rpartition(":")
    if sep and str(tail).isdigit():
      return normalize_ip(head)
  if ":" in raw:
    head, _, _ = raw.partition(":")
    return normalize_ip(head)
  return normalize_ip(raw)


def openvpn_session_key(username, real_addr, virtual_ip):
  return "|".join((
    str(username or "").strip(),
    str(real_addr or "").strip(),
    str(virtual_ip or "").strip(),
  ))


def openvpn_status_file():
  cfg = read_env_map(OPENVPN_CONFIG_FILE)
  explicit = str(cfg.get("OPENVPN_STATUS_TCP_FILE") or "").strip()
  if explicit:
    return pathlib.Path(explicit)
  root = str(cfg.get("OPENVPN_ROOT") or "/etc/autoscript/openvpn").strip() or "/etc/autoscript/openvpn"
  return pathlib.Path(root) / "status-tcp.log"


def openvpn_qac_cache_load():
  try:
    payload = json.loads(OPENVPN_QAC_CACHE_FILE.read_text(encoding="utf-8"))
  except Exception:
    return {}
  if not isinstance(payload, dict):
    return {}
  sessions = payload.get("sessions")
  return sessions if isinstance(sessions, dict) else {}


def openvpn_qac_cache_store(sessions):
  try:
    OPENVPN_QAC_CACHE_FILE.parent.mkdir(parents=True, exist_ok=True)
  except Exception:
    pass
  write_json_atomic(OPENVPN_QAC_CACHE_FILE, {"sessions": sessions})
  try:
    os.chmod(str(OPENVPN_QAC_CACHE_FILE), 0o600)
  except Exception:
    pass


def _openvpn_status_row_parse(raw_line):
  try:
    row = next(csv.reader([str(raw_line or "")]))
  except Exception:
    return []
  return [str(item or "").strip() for item in row]


def openvpn_pending_disconnects():
  items = []
  root = pathlib.Path(OPENVPN_QAC_PENDING_DIR)
  if not root.is_dir():
    return items
  for path in sorted(root.glob("*.json"), key=lambda p: p.name.lower()):
    try:
      payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
      try:
        path.unlink()
      except Exception:
        pass
      continue
    if not isinstance(payload, dict):
      try:
        path.unlink()
      except Exception:
        pass
      continue
    username = norm_user(payload.get("username"))
    real_addr = str(payload.get("real_addr") or "").strip()
    virtual_ip = normalize_ip(payload.get("virtual_ip"))
    bytes_total = max(0, to_int(payload.get("bytes_total"), 0))
    if not username or not real_addr or not virtual_ip:
      try:
        path.unlink()
      except Exception:
        pass
      continue
    items.append({
      "path": path,
      "username": username,
      "real_addr": real_addr,
      "virtual_ip": virtual_ip,
      "session_key": openvpn_session_key(username, real_addr, virtual_ip),
      "bytes_total": bytes_total,
    })
  return items


def openvpn_runtime_snapshot():
  status_path = openvpn_status_file()
  stats = {}
  current_sessions = {}
  previous_sessions = openvpn_qac_cache_load()
  pending_disconnects = openvpn_pending_disconnects()
  consumed_disconnects = []
  if not status_path.is_file():
    status_path = None

  client_header = []
  lines = []
  if status_path is not None:
    try:
      lines = status_path.read_text(encoding="utf-8", errors="ignore").splitlines()
    except Exception:
      lines = []

  for raw_line in lines:
    row = _openvpn_status_row_parse(raw_line)
    if not row:
      continue
    tag = row[0]
    if tag == "HEADER" and len(row) >= 3 and row[1] == "CLIENT_LIST":
      client_header = row[2:]
      continue
    if tag != "CLIENT_LIST":
      continue
    if not client_header:
      continue
    values = row[1:]
    if not values:
      continue
    payload = {}
    for idx, key in enumerate(client_header):
      payload[str(key)] = values[idx] if idx < len(values) else ""
    username = norm_user(payload.get("Username") or payload.get("Common Name"))
    if not username:
      continue
    real_addr = str(payload.get("Real Address") or "").strip()
    real_ip = normalize_real_address_ip(real_addr)
    virtual_ip = normalize_ip(payload.get("Virtual Address"))
    bytes_total = max(0, to_int(payload.get("Bytes Received"), 0)) + max(0, to_int(payload.get("Bytes Sent"), 0))
    session_key = openvpn_session_key(username, real_addr, virtual_ip)
    prev_total = to_int(previous_sessions.get(session_key), -1)
    delta = 0
    if prev_total >= 0 and bytes_total >= prev_total:
      delta = bytes_total - prev_total
    elif prev_total < 0:
      delta = 0
    current_sessions[session_key] = bytes_total
    item = stats.setdefault(username, {
      "session_count": 0,
      "ips": set(),
      "bytes_delta": 0,
    })
    item["session_count"] = int(item.get("session_count") or 0) + 1
    if real_ip:
      item["ips"].add(real_ip)
    item["bytes_delta"] = int(item.get("bytes_delta") or 0) + int(max(0, delta))

  for entry in pending_disconnects:
    session_key = str(entry.get("session_key") or "").strip()
    if not session_key:
      continue
    if session_key in current_sessions:
      continue
    username = norm_user(entry.get("username"))
    if not username:
      consumed_disconnects.append(entry)
      continue
    bytes_total = max(0, to_int(entry.get("bytes_total"), 0))
    prev_total = to_int(previous_sessions.get(session_key), -1)
    if prev_total >= 0 and bytes_total >= prev_total:
      delta = bytes_total - prev_total
    else:
      delta = bytes_total
    item = stats.setdefault(username, {
      "session_count": 0,
      "ips": set(),
      "bytes_delta": 0,
    })
    item["bytes_delta"] = int(item.get("bytes_delta") or 0) + int(max(0, delta))
    consumed_disconnects.append(entry)

  openvpn_qac_cache_store(current_sessions)
  for entry in consumed_disconnects:
    path = entry.get("path")
    if path is None:
      continue
    try:
      pathlib.Path(path).unlink()
    except Exception:
      pass
  for item in stats.values():
    ips = item.get("ips")
    item["ips"] = sorted(ips) if isinstance(ips, set) else []
  return stats


def openvpn_management_target():
  cfg = read_env_map(OPENVPN_CONFIG_FILE)
  host = str(cfg.get("OPENVPN_MANAGEMENT_HOST") or "127.0.0.1").strip() or "127.0.0.1"
  port = to_int(cfg.get("OPENVPN_MANAGEMENT_PORT"), 21194)
  if port < 1 or port > 65535:
    port = 21194
  return host, port


def kill_openvpn_sessions(username):
  user = norm_user(username)
  if not user or not OPENVPN_SESSION_KILL_BIN.is_file():
    return False
  host, port = openvpn_management_target()
  try:
    res = subprocess.run(
      [str(OPENVPN_SESSION_KILL_BIN), "--host", host, "--port", str(port), "--user", user],
      stdout=subprocess.DEVNULL,
      stderr=subprocess.DEVNULL,
      check=False,
      timeout=8,
    )
  except Exception:
    return False
  return int(getattr(res, "returncode", 1) or 0) == 0

def pid_alive(pid):
  value = to_int(pid, 0)
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

def runtime_session_payload_valid(payload):
  if not isinstance(payload, dict):
    return False
  if not pid_alive(payload.get("proxy_pid")):
    return False
  updated_at = to_int(payload.get("updated_at"), 0)
  now = to_int(time.time(), 0)
  if updated_at <= 0 or now <= 0:
    return False
  return (now - updated_at) <= int(RUNTIME_SESSION_STALE_SEC)

def iter_runtime_sessions(root, prune_stale=False):
  root_path = pathlib.Path(root)
  if not root_path.is_dir():
    return
  for path in root_path.glob("*.json"):
    try:
      payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
      continue
    if runtime_session_payload_valid(payload):
      yield path, payload
      continue
    if prune_stale:
      try:
        path.unlink()
      except FileNotFoundError:
        pass
      except Exception:
        pass


def session_user_index_path(username):
  user = norm_user(username)
  if not user:
    return None
  return SESSION_USER_INDEX_ROOT / f"{user}.json"


def load_user_session_index(username):
  path = session_user_index_path(username)
  if path is None or not path.is_file():
    return {"username": norm_user(username), "sessions": {}}
  try:
    payload = json.loads(path.read_text(encoding="utf-8"))
  except Exception:
    return {"username": norm_user(username), "sessions": {}}
  if not isinstance(payload, dict):
    return {"username": norm_user(username), "sessions": {}}
  sessions = payload.get("sessions")
  if not isinstance(sessions, dict):
    sessions = {}
  return {"username": norm_user(username), "sessions": sessions}


def write_user_session_index(username, payload):
  path = session_user_index_path(username)
  if path is None:
    return
  path.parent.mkdir(parents=True, exist_ok=True)
  out = payload if isinstance(payload, dict) else {}
  out["username"] = norm_user(username)
  sessions = out.get("sessions")
  if not isinstance(sessions, dict):
    sessions = {}
  out["sessions"] = sessions
  write_json_atomic(path, out)


def drop_user_session_index(username):
  path = session_user_index_path(username)
  if path is None:
    return
  try:
    path.unlink()
  except FileNotFoundError:
    pass

def cmd_ok(cmd):
  try:
    return subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
  except FileNotFoundError:
    return False

def user_exists(username):
  return cmd_ok(["id", username])

def get_user_shell(username):
  try:
    return str(pwd.getpwnam(username).pw_shell or "").strip()
  except KeyError:
    return ""

def detect_lock_shell():
  for path in LOCK_SHELL_CANDIDATES:
    if os.path.exists(path):
      return path
  return LOCK_SHELL_CANDIDATES[0]

def is_lock_shell(shell):
  return str(shell or "").strip() in LOCK_SHELL_CANDIDATES

def set_user_shell(username, shell_path):
  shell = str(shell_path or "").strip()
  if not username or not shell:
    return False
  return cmd_ok(["usermod", "-s", shell, username])

def runtime_session_stats(username):
  user = norm_user(username)
  if not user or not SESSION_ROOT.is_dir():
    return None, None, []
  index = load_user_session_index(user)
  sessions = index.get("sessions") or {}
  if sessions:
    total = 0
    ips = set()
    fresh_sessions = {}
    for port, meta in sessions.items():
      session_path = SESSION_ROOT / f"{to_int(port, 0)}.json"
      try:
        payload = json.loads(session_path.read_text(encoding="utf-8"))
      except Exception:
        continue
      if not runtime_session_payload_valid(payload):
        continue
      if norm_user(payload.get("username") or session_path.stem) != user:
        continue
      total += 1
      ip = normalize_ip(payload.get("client_ip"))
      if ip:
        ips.add(ip)
      fresh_sessions[str(to_int(port, 0))] = {
        "client_ip": ip,
        "updated_at": to_int(payload.get("updated_at"), 0),
      }
    if fresh_sessions != sessions:
      if fresh_sessions:
        write_user_session_index(user, {"username": user, "sessions": fresh_sessions})
      else:
        drop_user_session_index(user)
    ip_list = sorted(ips, key=lambda value: (":" in value, value))
    return total, len(ip_list), ip_list
  total = 0
  ips = set()
  fresh_sessions = {}
  try:
    for path, payload in iter_runtime_sessions(SESSION_ROOT, prune_stale=True):
      session_user = norm_user(payload.get("username") or path.stem)
      if session_user == user:
        total += 1
        ip = normalize_ip(payload.get("client_ip"))
        if ip:
          ips.add(ip)
        fresh_sessions[str(to_int(payload.get("backend_local_port"), 0))] = {
          "client_ip": ip,
          "updated_at": to_int(payload.get("updated_at"), 0),
        }
  except Exception:
    return None, None, []
  if fresh_sessions:
    write_user_session_index(user, {"username": user, "sessions": fresh_sessions})
  ip_list = sorted(ips, key=lambda value: (":" in value, value))
  return total, len(ip_list), ip_list

def active_sessions_from_runtime(username):
  total, _, _ = runtime_session_stats(username)
  return total

_DROPBEAR_ROWS_CACHE = None
_DROPBEAR_AUTH_CACHE = None
SSH_NETWORK_SYNC_RETRY_ATTEMPTS = 6
SSH_NETWORK_SYNC_RETRY_DELAY_SEC = 0.5


def dropbear_backend_process_rows():
  global _DROPBEAR_ROWS_CACHE
  if _DROPBEAR_ROWS_CACHE is not None:
    return _DROPBEAR_ROWS_CACHE
  try:
    res = subprocess.run(
      ["ps", "-eo", "pid=,ppid=,user=,comm=,args="],
      stdout=subprocess.PIPE,
      stderr=subprocess.DEVNULL,
      text=True,
      check=False,
    )
  except FileNotFoundError:
    _DROPBEAR_ROWS_CACHE = []
    return _DROPBEAR_ROWS_CACHE
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
    except ValueError:
      continue
    rows.append({
      "pid": pid,
      "ppid": ppid,
      "user": parts[2],
      "comm": parts[3],
      "args": parts[4],
    })
  _DROPBEAR_ROWS_CACHE = rows
  return rows


def active_dropbear_session_pids():
  rows = dropbear_backend_process_rows()
  master_pids = set()
  for row in rows:
    if row.get("comm") == "dropbear" and "-p 127.0.0.1:22022" in str(row.get("args") or ""):
      master_pids.add(int(row.get("pid") or 0))
  if not master_pids:
    return []
  session_pids = []
  for row in rows:
    if row.get("comm") != "dropbear":
      continue
    if int(row.get("ppid") or 0) in master_pids:
      session_pids.append(int(row.get("pid") or 0))
  return session_pids


def _parse_dropbear_auth_lines(lines):
  mapping = {}
  pat = re.compile(r"dropbear\[(\d+)\]: .*auth succeeded for '([^']+)'", re.IGNORECASE)
  for line in lines:
    m = pat.search(str(line or ""))
    if not m:
      continue
    try:
      pid = int(m.group(1))
    except Exception:
      continue
    user = norm_user(m.group(2))
    if user:
      mapping[pid] = user
  return mapping


def dropbear_pid_auth_map():
  global _DROPBEAR_AUTH_CACHE
  if _DROPBEAR_AUTH_CACHE is not None:
    return _DROPBEAR_AUTH_CACHE
  mapping = {}
  try:
    res = subprocess.run(
      ["journalctl", "-u", "sshws-dropbear", "--no-pager", "-n", "2000"],
      stdout=subprocess.PIPE,
      stderr=subprocess.DEVNULL,
      text=True,
      check=False,
    )
    mapping.update(_parse_dropbear_auth_lines((res.stdout or "").splitlines()))
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
      mapping.update(_parse_dropbear_auth_lines((res.stdout or "").splitlines()))
    except FileNotFoundError:
      pass
  _DROPBEAR_AUTH_CACHE = mapping
  return mapping


def active_sessions_from_dropbear(username):
  if not username or not user_exists(username):
    return 0
  target = norm_user(username)
  if not target:
    return 0
  pid_map = dropbear_pid_auth_map()
  count = 0
  for pid in active_dropbear_session_pids():
    if pid_map.get(int(pid)) == target:
      count += 1
  return count

def active_sessions(username):
  if not username or not user_exists(username):
    return 0
  runtime_count = active_sessions_from_runtime(username)
  if runtime_count is not None:
    return int(runtime_count)
  return int(active_sessions_from_dropbear(username))

def active_login_metric(username):
  if not username or not user_exists(username):
    return 0
  runtime_count, runtime_ip_count, _ = runtime_session_stats(username)
  if runtime_count is not None:
    if int(runtime_ip_count or 0) > 0:
      return int(runtime_ip_count)
    return int(runtime_count)
  return active_sessions(username)

def lock_user(username, status=None):
  if not user_exists(username):
    return False
  st = status if isinstance(status, dict) else {}
  ok = False
  if cmd_ok(["passwd", "-l", username]) or cmd_ok(["usermod", "-L", username]):
    ok = True
  current_shell = get_user_shell(username)
  lock_shell = detect_lock_shell()
  if is_lock_shell(current_shell):
    ok = True
  elif current_shell and lock_shell:
    if not str(st.get("lock_shell_restore") or "").strip():
      st["lock_shell_restore"] = current_shell
    if set_user_shell(username, lock_shell):
      ok = True
  return ok

def unlock_user(username, status=None):
  if not user_exists(username):
    return False
  st = status if isinstance(status, dict) else {}
  ok = False
  if cmd_ok(["passwd", "-u", username]) or cmd_ok(["usermod", "-U", username]):
    ok = True
  restore_shell = str(st.get("lock_shell_restore") or "").strip()
  current_shell = get_user_shell(username)
  if restore_shell and current_shell and is_lock_shell(current_shell) and current_shell != restore_shell:
    if set_user_shell(username, restore_shell):
      ok = True
  return ok

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

def ensure_openvpn_connect_policy_dir():
  try:
    OPENVPN_CONNECT_POLICY_DIR.mkdir(parents=True, exist_ok=True)
  except Exception:
    return
  try:
    gid = grp.getgrnam("nogroup").gr_gid
  except Exception:
    gid = -1
  try:
    if gid >= 0:
      os.chown(str(OPENVPN_CONNECT_POLICY_DIR), 0, gid)
  except Exception:
    pass
  try:
    os.chmod(str(OPENVPN_CONNECT_POLICY_DIR), 0o750)
  except Exception:
    pass


def openvpn_connect_policy_path(username):
  user = norm_user(username)
  if not user:
    return None
  return OPENVPN_CONNECT_POLICY_DIR / f"{user}.json"


def openvpn_connect_policy_store(username, payload):
  path = openvpn_connect_policy_path(username)
  if path is None:
    return
  ensure_openvpn_connect_policy_dir()
  data = payload if isinstance(payload, dict) else {}
  write_json_atomic(path, data)
  try:
    gid = grp.getgrnam("nogroup").gr_gid
  except Exception:
    gid = -1
  try:
    if gid >= 0:
      os.chown(str(path), 0, gid)
  except Exception:
    pass
  try:
    os.chmod(str(path), 0o640)
  except Exception:
    pass


def openvpn_connect_policy_drop(username):
  path = openvpn_connect_policy_path(username)
  if path is None:
    return
  try:
    path.unlink()
  except FileNotFoundError:
    pass
  except Exception:
    pass

def ssh_network_config_map():
  data = {}
  if SSH_NETWORK_CONFIG_FILE.is_file():
    try:
      for raw in SSH_NETWORK_CONFIG_FILE.read_text(encoding="utf-8").splitlines():
        line = str(raw or "").strip()
        if not line or line.startswith("#") or "=" not in line:
          continue
        key, value = line.split("=", 1)
        data[key.strip()] = value.strip()
    except Exception:
      data = {}
  global_mode = str(data.get("SSH_NETWORK_ROUTE_GLOBAL") or "direct").strip().lower()
  if global_mode not in ("direct", "warp"):
    global_mode = "direct"
  warp_backend = str(data.get("SSH_NETWORK_WARP_BACKEND") or "auto").strip().lower()
  if warp_backend not in ("auto", "local-proxy", "interface"):
    warp_backend = "auto"
  return {"global_mode": global_mode, "warp_backend": warp_backend}

def ssh_network_backend_effective(configured):
  backend = str(configured or "auto").strip().lower()
  if backend in ("local-proxy", "interface"):
    return backend
  if shutil.which("xray") and shutil.which("iptables"):
    return "local-proxy"
  return "interface"

def ssh_network_user_route_mode(payload):
  if not isinstance(payload, dict):
    return ""
  network = payload.get("network")
  if not isinstance(network, dict):
    return ""
  value = str(network.get("route_mode") or "").strip().lower()
  if value in ("direct", "warp"):
    return value
  return ""

def ssh_network_sync_snapshot():
  cfg = ssh_network_config_map()
  backend_effective = ssh_network_backend_effective(cfg.get("warp_backend"))
  if backend_effective != "local-proxy":
    return {
      "backend_effective": backend_effective,
      "warp_users": [],
      "active_dropbear_sessions": [],
    }
  global_mode = str(cfg.get("global_mode") or "direct").strip().lower()
  warp_users = []
  for path in iter_ssh_state_files(SSH_STATE_ROOT):
    try:
      payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
      payload = {}
    username = norm_user((payload or {}).get("username") or path.stem)
    if not username or not user_exists(username):
      continue
    override = ssh_network_user_route_mode(payload)
    effective = override if override in ("direct", "warp") else global_mode
    if effective == "warp":
      warp_users.append(username)
  warp_users = sorted(set(warp_users), key=str.lower)
  warp_user_set = {item.lower() for item in warp_users}
  active_sessions = []
  if warp_user_set:
    pid_map = dropbear_pid_auth_map()
    for pid in active_dropbear_session_pids():
      username = norm_user(pid_map.get(int(pid)) or "")
      if username and username in warp_user_set:
        active_sessions.append(f"{username}:{int(pid)}")
  active_sessions = sorted(set(active_sessions), key=str.lower)
  return {
    "backend_effective": backend_effective,
    "warp_users": warp_users,
    "active_dropbear_sessions": active_sessions,
  }

def ssh_network_sync_cache_load():
  try:
    payload = json.loads(SSH_NETWORK_SYNC_CACHE_FILE.read_text(encoding="utf-8"))
  except Exception:
    return None
  return payload if isinstance(payload, dict) else None

def ssh_network_sync_cache_store(snapshot):
  try:
    SSH_NETWORK_SYNC_CACHE_FILE.parent.mkdir(parents=True, exist_ok=True)
  except Exception:
    return
  write_json_atomic(SSH_NETWORK_SYNC_CACHE_FILE, snapshot)

def iter_ssh_state_files(root):
  root_path = pathlib.Path(root)
  try:
    entries = sorted(root_path.iterdir(), key=lambda p: p.name.lower())
  except Exception:
    return []
  out = []
  for entry in entries:
    try:
      if not entry.is_file():
        continue
    except Exception:
      continue
    name = entry.name
    if name.startswith(".") or not name.endswith(".json"):
      continue
    out.append(entry)
  return out

def pick_unique_sshws_token(root, current_path, current_token):
  seen = set()
  try:
    current_real = str(pathlib.Path(current_path).resolve())
  except Exception:
    current_real = str(current_path)
  for entry in iter_ssh_state_files(root):
    try:
      if str(entry.resolve()) == current_real:
        continue
    except Exception:
      if str(entry) == str(current_path):
        continue
    try:
      loaded = json.loads(entry.read_text(encoding="utf-8"))
      if not isinstance(loaded, dict):
        continue
    except Exception:
      continue
    tok = normalize_token(loaded.get("sshws_token"))
    if tok:
      seen.add(tok)
  tok = normalize_token(current_token)
  if tok and tok not in seen:
    return tok
  for _ in range(256):
    tok = secrets.token_hex(5)
    if tok not in seen:
      return tok
  raise RuntimeError("failed to allocate unique sshws token")

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
  token = pick_unique_sshws_token(path.parent, path, payload.get("sshws_token"))

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
    "active_sessions_openvpn": to_int(status.get("active_sessions_openvpn"), 0),
    "distinct_ip_count_openvpn": to_int(status.get("distinct_ip_count_openvpn"), 0),
    "distinct_ips_openvpn": status.get("distinct_ips_openvpn") if isinstance(status.get("distinct_ips_openvpn"), list) else [],
    "speed_limit_enabled": to_bool(status.get("speed_limit_enabled")),
    "speed_down_mbit": speed_down,
    "speed_up_mbit": speed_up,
    "lock_reason": str(status.get("lock_reason") or "").strip().lower(),
    "account_locked": to_bool(status.get("account_locked")),
    "lock_owner": str(status.get("lock_owner") or "").strip(),
    "lock_shell_restore": str(status.get("lock_shell_restore") or "").strip(),
  }
  return payload


def normalize_openvpn_payload(path):
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
  payload["protocol"] = "openvpn"
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
    "ip_limit_metric": to_int(status.get("ip_limit_metric"), 0),
    "distinct_ip_count": to_int(status.get("distinct_ip_count"), 0),
    "distinct_ips": status.get("distinct_ips") if isinstance(status.get("distinct_ips"), list) else [],
    "active_sessions_total": to_int(status.get("active_sessions_total"), 0),
    "active_sessions_openvpn": to_int(status.get("active_sessions_openvpn"), 0),
    "distinct_ip_count_openvpn": to_int(status.get("distinct_ip_count_openvpn"), 0),
    "distinct_ips_openvpn": status.get("distinct_ips_openvpn") if isinstance(status.get("distinct_ips_openvpn"), list) else [],
    "speed_limit_enabled": to_bool(status.get("speed_limit_enabled")),
    "speed_down_mbit": speed_down,
    "speed_up_mbit": speed_up,
    "lock_reason": str(status.get("lock_reason") or "").strip().lower(),
    "account_locked": to_bool(status.get("account_locked")),
    "lock_owner": str(status.get("lock_owner") or "").strip(),
    "lock_shell_restore": "",
  }
  return payload

def enforce_user(path, openvpn_stats=None):
  try:
    raw_before = path.read_text(encoding="utf-8")
  except Exception:
    raw_before = ""
  payload = normalize_payload(path)
  status = payload["status"]
  before = json.dumps(payload, ensure_ascii=False, sort_keys=True)
  prev_reason = str(status.get("lock_reason") or "").strip().lower()

  username = norm_user(payload.get("username") or path.stem) or norm_user(path.stem) or path.stem
  ip_enabled = bool(status.get("ip_limit_enabled"))
  ip_limit = to_int(status.get("ip_limit"), 0)
  if ip_limit < 0:
    ip_limit = 0
  runtime_count, runtime_ip_count, runtime_ips = runtime_session_stats(username)
  runtime_unavailable = (runtime_count is None or runtime_ip_count is None)
  if runtime_count is None:
    runtime_count = 0
  if runtime_ip_count is None:
    runtime_ip_count = 0
  if runtime_unavailable:
    dropbear_count = active_sessions_from_dropbear(username)
  else:
    dropbear_count = 0
  ssh_session_total = max(int(runtime_count), int(dropbear_count))
  ssh_ips = sorted(set(runtime_ips or []))
  ssh_ip_count = len(ssh_ips)
  quota_used = to_int(payload.get("quota_used"), 0)
  if quota_used < 0:
    quota_used = 0
  status["active_sessions_runtime"] = int(runtime_count)
  status["active_sessions_dropbear"] = int(dropbear_count)
  status["active_sessions_openvpn"] = 0
  status["active_sessions_total"] = int(ssh_session_total)
  status["distinct_ip_count_openvpn"] = 0
  status["distinct_ips_openvpn"] = []
  status["distinct_ip_count"] = int(ssh_ip_count)
  status["distinct_ips"] = ssh_ips
  if ssh_ip_count > 0:
    status["ip_limit_metric"] = int(ssh_ip_count)
  else:
    status["ip_limit_metric"] = int(ssh_session_total)
  if not ip_enabled:
    status["ip_limit_locked"] = False
  elif ip_limit > 0:
    status["ip_limit_locked"] = to_int(status.get("ip_limit_metric"), 0) > ip_limit
  else:
    status["ip_limit_locked"] = False

  quota_limit = to_int(payload.get("quota_limit"), 0)
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

  exists = user_exists(username)
  if reason:
    if exists and lock_user(username, status):
      account_locked = True
      lock_owner = "ssh_qac"
    elif not exists:
      account_locked = False
      lock_owner = ""
  else:
    restore_shell = str(status.get("lock_shell_restore") or "").strip()
    current_shell = get_user_shell(username) if exists else ""
    unlock_expected = bool(
      exists and (
        (account_locked and lock_owner == "ssh_qac") or
        (restore_shell and current_shell and is_lock_shell(current_shell))
      )
    )
    if unlock_expected:
      if unlock_user(username, status):
        account_locked = False
        lock_owner = ""
        status["lock_shell_restore"] = ""
    elif not account_locked and lock_owner == "ssh_qac":
      lock_owner = ""
      status["lock_shell_restore"] = ""

  status["account_locked"] = bool(account_locked)
  status["lock_owner"] = lock_owner
  payload["status"] = status

  after = json.dumps(payload, ensure_ascii=False, sort_keys=True)
  if after != before or raw_before.strip() != (json.dumps(payload, ensure_ascii=False, indent=2) + "\n").strip():
    write_json_atomic(path, payload)
    try:
      os.chmod(path, 0o600)
    except Exception:
      pass


def enforce_openvpn_user(path, openvpn_stats=None):
  try:
    raw_before = path.read_text(encoding="utf-8")
  except Exception:
    raw_before = ""
  payload = normalize_openvpn_payload(path)
  status = payload["status"]
  before = json.dumps(payload, ensure_ascii=False, sort_keys=True)
  prev_reason = str(status.get("lock_reason") or "").strip().lower()

  username = norm_user(payload.get("username") or path.stem) or norm_user(path.stem) or path.stem
  ovpn = openvpn_stats.get(username) if isinstance(openvpn_stats, dict) else {}
  ovpn_count = to_int((ovpn or {}).get("session_count"), 0)
  ovpn_ips = (ovpn or {}).get("ips")
  if not isinstance(ovpn_ips, list):
    ovpn_ips = []
  ovpn_ips = [ip for ip in (normalize_ip(value) for value in ovpn_ips) if ip]
  ovpn_bytes_delta = max(0, to_int((ovpn or {}).get("bytes_delta"), 0))
  ip_enabled = bool(status.get("ip_limit_enabled"))
  ip_limit = to_int(status.get("ip_limit"), 0)
  if ip_limit < 0:
    ip_limit = 0

  quota_used = to_int(payload.get("quota_used"), 0)
  if quota_used < 0:
    quota_used = 0
  if ovpn_bytes_delta > 0:
    quota_used += int(ovpn_bytes_delta)
    payload["quota_used"] = quota_used

  status["active_sessions_openvpn"] = int(ovpn_count)
  status["active_sessions_total"] = int(ovpn_count)
  status["distinct_ip_count_openvpn"] = len(ovpn_ips)
  status["distinct_ips_openvpn"] = ovpn_ips
  status["distinct_ip_count"] = len(ovpn_ips)
  status["distinct_ips"] = ovpn_ips
  if ovpn_ips:
    status["ip_limit_metric"] = len(ovpn_ips)
  else:
    status["ip_limit_metric"] = int(ovpn_count)
  if not ip_enabled:
    status["ip_limit_locked"] = False
  elif ip_limit > 0:
    status["ip_limit_locked"] = to_int(status.get("ip_limit_metric"), 0) > ip_limit
  else:
    status["ip_limit_locked"] = False

  quota_limit = to_int(payload.get("quota_limit"), 0)
  status["quota_exhausted"] = bool(quota_limit > 0 and quota_used >= quota_limit)

  reason = ""
  if bool(status.get("manual_block")):
    reason = "manual"
  elif bool(status.get("quota_exhausted")):
    reason = "quota"
  elif bool(status.get("ip_limit_locked")):
    reason = "ip_limit"

  status["lock_reason"] = reason
  status["account_locked"] = bool(reason)
  status["lock_owner"] = "openvpn_qac" if reason else ""
  status["lock_shell_restore"] = ""
  payload["status"] = status

  if bool(reason) and reason != prev_reason:
    kill_openvpn_sessions(username)

  openvpn_connect_policy_store(username, {
    "username": username,
    "status": {
      "manual_block": bool(status.get("manual_block")),
      "quota_exhausted": bool(status.get("quota_exhausted")),
      "ip_limit_enabled": bool(status.get("ip_limit_enabled")),
      "ip_limit": to_int(status.get("ip_limit"), 0),
      "ip_limit_locked": bool(status.get("ip_limit_locked")),
      "account_locked": bool(status.get("account_locked")),
      "lock_owner": str(status.get("lock_owner") or "").strip(),
      "active_sessions_total": to_int(status.get("active_sessions_total"), 0),
      "distinct_ips": status.get("distinct_ips") if isinstance(status.get("distinct_ips"), list) else [],
      "distinct_ips_openvpn": status.get("distinct_ips_openvpn") if isinstance(status.get("distinct_ips_openvpn"), list) else [],
    },
  })

  after = json.dumps(payload, ensure_ascii=False, sort_keys=True)
  if after != before or raw_before.strip() != (json.dumps(payload, ensure_ascii=False, indent=2) + "\n").strip():
    write_json_atomic(path, payload)
    try:
      os.chmod(path, 0o600)
    except Exception:
      pass

def run_once(target_user):
  if not SSH_STATE_ROOT.exists() and not OPENVPN_STATE_ROOT.exists():
    return 0
  try:
    LOCK_FILE.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(str(LOCK_FILE.parent), 0o700)
  except Exception:
    pass
  with open(LOCK_FILE, "a+", encoding="utf-8") as lf:
    fcntl.flock(lf.fileno(), fcntl.LOCK_EX)
    try:
      ssh_paths = sorted(SSH_STATE_ROOT.glob("*.json"), key=lambda p: p.name.lower()) if SSH_STATE_ROOT.exists() else []
      openvpn_paths = sorted(OPENVPN_STATE_ROOT.glob("*.json"), key=lambda p: p.name.lower()) if OPENVPN_STATE_ROOT.exists() else []
      openvpn_stats = openvpn_runtime_snapshot()
      target_norm = norm_user(target_user)
      for path in ssh_paths:
        if target_user:
          stem = path.stem
          stem_norm = norm_user(stem)
          try:
            current = json.loads(path.read_text(encoding="utf-8"))
          except Exception:
            current = {}
          username = norm_user(current.get("username") or stem) or stem_norm or stem
          if target_user not in (stem, username) and target_norm not in (stem_norm, username):
            continue
        enforce_user(path, openvpn_stats=openvpn_stats)
      for path in openvpn_paths:
        if target_user:
          stem = path.stem
          stem_norm = norm_user(stem)
          try:
            current = json.loads(path.read_text(encoding="utf-8"))
          except Exception:
            current = {}
          username = norm_user(current.get("username") or stem) or stem_norm or stem
          if target_user not in (stem, username) and target_norm not in (stem_norm, username):
            continue
        enforce_openvpn_user(path, openvpn_stats=openvpn_stats)
      if target_user:
        target_file = openvpn_connect_policy_path(target_user)
        has_target_state = False
        for path in openvpn_paths:
          stem = path.stem
          stem_norm = norm_user(stem)
          try:
            current = json.loads(path.read_text(encoding="utf-8"))
          except Exception:
            current = {}
          username = norm_user(current.get("username") or stem) or stem_norm or stem
          if target_user in (stem, username) or target_norm in (stem_norm, username):
            has_target_state = True
            break
        if not has_target_state:
          openvpn_connect_policy_drop(target_user)
    finally:
      fcntl.flock(lf.fileno(), fcntl.LOCK_UN)
  refresh_ssh_network_session_targets()
  return 0

def refresh_ssh_network_session_targets():
  manage_bin = shutil.which("manage") or "/usr/local/bin/manage"
  if not manage_bin:
    return
  snapshot = ssh_network_sync_snapshot()
  cached = ssh_network_sync_cache_load()
  if cached == snapshot:
    return
  attempts = int(max(1, SSH_NETWORK_SYNC_RETRY_ATTEMPTS))
  for idx in range(attempts):
    try:
      res = subprocess.run(
        [manage_bin, "__sync-ssh-network-session-targets"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
        timeout=45,
      )
      if getattr(res, "returncode", 1) == 0:
        ssh_network_sync_cache_store(snapshot)
        return
    except Exception:
      pass
    if idx >= attempts - 1:
      break
    time.sleep(float(SSH_NETWORK_SYNC_RETRY_DELAY_SEC))

def parse_args():
  p = argparse.ArgumentParser(description="SSH WS quota/access enforcer")
  p.add_argument("--once", action="store_true", help="run one enforcement cycle")
  p.add_argument("--user", default="", help="enforce only for one username")
  return p.parse_args()

def main():
  args = parse_args()
  if args.once:
    raise SystemExit(run_once((args.user or "").strip()))
  raise SystemExit(run_once((args.user or "").strip()))

if __name__ == "__main__":
  main()
