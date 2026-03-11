#!/usr/bin/env python3
import argparse
import fcntl
import ipaddress
import json
import os
import pathlib
import pwd
import re
import secrets
import subprocess
import tempfile
import time

STATE_ROOT = pathlib.Path("/opt/quota/ssh-ovpn")
LOCK_FILE = pathlib.Path("/run/autoscript/locks/sshws-qac.lock")
SESSION_ROOT = pathlib.Path("/run/autoscript/sshws-sessions")
UNIFIED_QAC_ROOT = pathlib.Path("/opt/quota/ssh-ovpn")
UNIFIED_QAC_RUNTIME_BIN = pathlib.Path("/usr/local/bin/ssh-ovpn-qac-runtime")
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

def normalize_token(v):
  s = str(v or "").strip().lower()
  if re.fullmatch(r"[a-f0-9]{10}", s):
    return s
  return ""

def norm_date(v):
  s = str(v or "").strip()
  if not s or s == "-":
    return ""
  match = re.search(r"\d{4}-\d{2}-\d{2}", s)
  return match.group(0) if match else ""

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

def normalize_ip_list(values):
  out = []
  seen = set()
  if not isinstance(values, list):
    return out
  for raw in values:
    ip = normalize_ip(raw)
    if not ip or ip in seen:
      continue
    seen.add(ip)
    out.append(ip)
  return sorted(out)

def normalize_session_rows(values, protocol):
  rows = []
  seen = set()
  if not isinstance(values, list):
    return rows
  for raw in values:
    if not isinstance(raw, dict):
      continue
    client_ip = normalize_ip(raw.get("client_ip"))
    if not client_ip:
      continue
    row = {
      "protocol": str(protocol or raw.get("protocol") or "-").strip() or "-",
      "surface": str(raw.get("surface") or raw.get("transport") or "-").strip() or "-",
      "client_ip": client_ip,
      "detail": str(raw.get("detail") or raw.get("virtual_ip") or raw.get("client_cn") or "-").strip() or "-",
      "updated_at_unix": max(0, to_int(raw.get("updated_at_unix"), to_int(raw.get("updated_at"), 0))),
    }
    row_key = (row["protocol"], row["surface"], row["client_ip"], row["detail"])
    if row_key in seen:
      continue
    seen.add(row_key)
    rows.append(row)
  rows.sort(key=lambda item: (item["protocol"], item["surface"], item["client_ip"], item["detail"]))
  return rows

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
    return None, None, [], []
  total = 0
  ips = set()
  sessions = []
  port_map = dropbear_port_auth_map()
  try:
    for path, payload in iter_runtime_sessions(SESSION_ROOT, prune_stale=True):
      session_user = norm_user(payload.get("username") or "")
      if not session_user:
        session_user = norm_user(port_map.get(to_int(payload.get("local_port"), 0)) or "")
      if session_user == user:
        total += 1
        ip = normalize_ip(payload.get("client_ip"))
        if ip:
          ips.add(ip)
        sessions.append({
          "protocol": "ssh",
          "surface": str(payload.get("transport") or "-").strip() or "-",
          "client_ip": ip,
          "detail": f"local:{to_int(payload.get('local_port'), 0)}",
          "updated_at_unix": max(0, to_int(payload.get("updated_at"), 0)),
        })
  except Exception:
    return None, None, [], []
  sessions.sort(key=lambda item: (item["surface"], item["client_ip"], item["detail"]))
  return total, len(ips), sorted(ips), sessions

def active_sessions_from_runtime(username):
  total, _, _, _ = runtime_session_stats(username)
  return total

_DROPBEAR_ROWS_CACHE = None
_DROPBEAR_AUTH_CACHE = None
_DROPBEAR_AUTH_PORT_CACHE = None


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

def _parse_dropbear_auth_port_lines(lines):
  mapping = {}
  pat = re.compile(r"auth succeeded for '([^']+)' from 127\.0\.0\.1:(\d+)", re.IGNORECASE)
  for line in lines:
    m = pat.search(str(line or ""))
    if not m:
      continue
    try:
      port = int(m.group(2))
    except Exception:
      continue
    user = norm_user(m.group(1))
    if user:
      mapping[port] = user
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

def dropbear_port_auth_map():
  global _DROPBEAR_AUTH_PORT_CACHE
  if _DROPBEAR_AUTH_PORT_CACHE is not None:
    return _DROPBEAR_AUTH_PORT_CACHE
  mapping = {}
  try:
    res = subprocess.run(
      ["journalctl", "-u", "sshws-dropbear", "--no-pager", "-n", "2000"],
      stdout=subprocess.PIPE,
      stderr=subprocess.DEVNULL,
      text=True,
      check=False,
    )
    mapping.update(_parse_dropbear_auth_port_lines((res.stdout or "").splitlines()))
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
      mapping.update(_parse_dropbear_auth_port_lines((res.stdout or "").splitlines()))
    except FileNotFoundError:
      pass
  _DROPBEAR_AUTH_PORT_CACHE = mapping
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
  dropbear_count = active_sessions_from_dropbear(username)
  if runtime_count is not None:
    return max(int(runtime_count), int(dropbear_count))
  return int(dropbear_count)

def active_login_metric(username):
  if not username or not user_exists(username):
    return 0
  runtime_count, runtime_ip_count, _, _ = runtime_session_stats(username)
  dropbear_count = active_sessions_from_dropbear(username)
  if runtime_count is not None:
    return max(int(runtime_count), int(runtime_ip_count or 0), int(dropbear_count))
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


def sync_unified_ssh_runtime(username, quota_used=None, active_sessions_count=None, distinct_ips=None, session_rows=None, quota_exhausted=None, ip_limit_locked=None, last_reason=None):
  user = norm_user(username)
  if not user or not UNIFIED_QAC_RUNTIME_BIN.is_file():
    return
  cmd = [str(UNIFIED_QAC_RUNTIME_BIN), "ssh-sync", "--user", user]
  if quota_used is not None:
    cmd.extend(["--quota-used-ssh", str(max(0, int(quota_used)))])
  if active_sessions_count is not None:
    active_count = max(0, int(active_sessions_count))
    cmd.extend(["--active-session-ssh", str(active_count)])
    if active_count > 0:
      cmd.extend(["--last-seen-ssh", str(max(0, int(time.time())))])
  if distinct_ips is not None:
    cmd.extend(["--distinct-ips-ssh-json", json.dumps(list(distinct_ips), ensure_ascii=False)])
  if session_rows is not None:
    cmd.extend(["--sessions-ssh-json", json.dumps(list(session_rows), ensure_ascii=False)])
  if quota_exhausted is not None:
    cmd.extend(["--quota-exhausted", "true" if quota_exhausted else "false"])
  if ip_limit_locked is not None:
    cmd.extend(["--ip-limit-locked", "true" if ip_limit_locked else "false"])
  if last_reason is not None:
    cmd.extend(["--last-reason", str(last_reason or "-")])
  try:
    subprocess.run(
      cmd,
      check=False,
      stdout=subprocess.DEVNULL,
      stderr=subprocess.DEVNULL,
    )
  except Exception:
    pass


def sync_unified_ovpn_access():
  if not UNIFIED_QAC_RUNTIME_BIN.is_file():
    return
  cmd = [
    str(UNIFIED_QAC_RUNTIME_BIN),
    "ovpn-sync-access",
    "--clients-dir",
    "/etc/openvpn/clients",
    "--ccd-dir",
    "/etc/openvpn/server/ccd",
  ]
  try:
    subprocess.run(
      cmd,
      check=False,
      stdout=subprocess.DEVNULL,
      stderr=subprocess.DEVNULL,
    )
  except Exception:
    pass


def load_unified_state(username):
  user = norm_user(username)
  if not user:
    return {}
  path = UNIFIED_QAC_ROOT / f"{user}.json"
  if not path.is_file():
    return {}
  try:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if isinstance(payload, dict):
      return payload
  except Exception:
    pass
  return {}

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
  policy = payload.get("policy") if isinstance(payload.get("policy"), dict) else {}
  runtime = payload.get("runtime") if isinstance(payload.get("runtime"), dict) else {}
  derived = payload.get("derived") if isinstance(payload.get("derived"), dict) else {}
  meta = payload.get("meta") if isinstance(payload.get("meta"), dict) else {}
  status_raw = payload.get("status")
  status = status_raw if isinstance(status_raw, dict) else {}

  unit = str(policy.get("quota_unit") or payload.get("quota_unit") or "binary").strip().lower()
  if unit not in ("binary", "decimal"):
    unit = "binary"
  token = pick_unique_sshws_token(path.parent, path, payload.get("sshws_token") or meta.get("sshws_token"))

  quota_limit_ssh = max(
    0,
    to_int(
      policy.get("quota_limit_ssh_bytes"),
      to_int(policy.get("quota_limit_bytes"), to_int(payload.get("quota_limit"), 0)),
    ),
  )
  quota_limit_ovpn = max(
    0,
    to_int(
      policy.get("quota_limit_ovpn_bytes"),
      to_int(policy.get("quota_limit_bytes"), quota_limit_ssh),
    ),
  )
  quota_used_ssh = max(
    0,
    max(
      to_int(runtime.get("quota_used_ssh_bytes"), 0),
      to_int(payload.get("quota_used"), 0),
    ),
  )
  quota_used_ovpn = max(0, to_int(runtime.get("quota_used_ovpn_bytes"), 0))
  active_session_ssh = max(0, to_int(runtime.get("active_session_ssh"), 0))
  active_session_ovpn = max(0, to_int(runtime.get("active_session_ovpn"), 0))
  last_seen_ssh = max(0, to_int(runtime.get("last_seen_ssh_unix"), 0))
  last_seen_ovpn = max(0, to_int(runtime.get("last_seen_ovpn_unix"), 0))
  distinct_ips_ssh = normalize_ip_list(runtime.get("distinct_ips_ssh"))
  distinct_ips_ovpn = normalize_ip_list(runtime.get("distinct_ips_ovpn"))
  sessions_ssh = normalize_session_rows(runtime.get("sessions_ssh"), "ssh")
  sessions_ovpn = normalize_session_rows(runtime.get("sessions_ovpn"), "ovpn")
  distinct_ips_total = sorted(set(distinct_ips_ssh) | set(distinct_ips_ovpn))

  created_at = str(payload.get("created_at") or meta.get("created_at") or "-").strip() or "-"
  expired_at = norm_date(policy.get("expired_at") or payload.get("expired_at") or "-") or "-"

  ip_limit_enabled = to_bool(policy.get("ip_limit_enabled"), status.get("ip_limit_enabled"))
  ip_limit = max(0, to_int(policy.get("ip_limit"), to_int(status.get("ip_limit"), 0)))
  speed_limit_enabled = to_bool(policy.get("speed_limit_enabled"), status.get("speed_limit_enabled"))
  speed_down = max(0.0, to_float(policy.get("speed_down_mbit"), to_float(status.get("speed_down_mbit"), 0.0)))
  speed_up = max(0.0, to_float(policy.get("speed_up_mbit"), to_float(status.get("speed_up_mbit"), 0.0)))
  manual_block = to_bool(status.get("manual_block"))
  access_enabled = to_bool(policy.get("access_enabled"), True)
  ip_limit_locked = to_bool(derived.get("ip_limit_locked"))
  quota_exhausted_ssh = to_bool(derived.get("quota_exhausted_ssh"), to_bool(derived.get("quota_exhausted")))
  quota_exhausted_ovpn = to_bool(derived.get("quota_exhausted_ovpn"))
  access_effective_ssh = to_bool(derived.get("access_effective_ssh"), to_bool(derived.get("access_effective"), True))
  access_effective_ovpn = to_bool(derived.get("access_effective_ovpn"), True)
  last_reason_ssh = str(derived.get("last_reason_ssh") or derived.get("last_reason") or "-").strip() or "-"
  last_reason_ovpn = str(derived.get("last_reason_ovpn") or derived.get("last_reason") or "-").strip() or "-"
  quota_used_total = max(0, to_int(derived.get("quota_used_total_bytes"), quota_used_ssh + quota_used_ovpn))
  active_session_total = max(0, to_int(derived.get("active_session_total"), active_session_ssh + active_session_ovpn))
  distinct_ip_total = max(0, to_int(derived.get("distinct_ip_total"), len(distinct_ips_total)))
  ip_limit_metric = max(0, to_int(derived.get("ip_limit_metric"), len(distinct_ips_total) if distinct_ips_total else active_session_total))
  speed_limit_active_ssh = max(0, to_int(derived.get("speed_limit_active_ssh"), active_session_ssh if speed_limit_enabled and speed_down > 0 else 0))
  speed_limit_active_ovpn = max(0, to_int(derived.get("speed_limit_active_ovpn"), active_session_ovpn if speed_limit_enabled and speed_down > 0 else 0))
  speed_limit_active_total = max(0, to_int(derived.get("speed_limit_active_total"), speed_limit_active_ssh + speed_limit_active_ovpn))

  meta = {
    "created_at": created_at,
    "updated_at_unix": max(0, to_int(meta.get("updated_at_unix"), 0)),
    "migrated_from_legacy": bool(to_bool(meta.get("migrated_from_legacy"))),
    "ssh_present": True,
    "ovpn_present": bool(to_bool(meta.get("ovpn_present"))),
    "sshws_token": token,
  }

  return {
    "version": 1,
    "managed_by": "autoscript-manage",
    "protocol": "ssh-ovpn",
    "username": username,
    "created_at": created_at,
    "expired_at": expired_at,
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
      "lock_reason": str(last_reason_ssh or "-").strip() or "-",
      "account_locked": bool(to_bool(status.get("account_locked"))),
      "lock_owner": str(status.get("lock_owner") or "").strip(),
      "lock_shell_restore": str(status.get("lock_shell_restore") or "").strip(),
    },
    "policy": {
      "quota_limit_bytes": quota_limit_ssh,
      "quota_limit_ssh_bytes": quota_limit_ssh,
      "quota_limit_ovpn_bytes": quota_limit_ovpn,
      "quota_unit": unit,
      "expired_at": expired_at,
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
      "distinct_ips_ssh": distinct_ips_ssh,
      "distinct_ips_ovpn": distinct_ips_ovpn,
      "sessions_ssh": sessions_ssh,
      "sessions_ovpn": sessions_ovpn,
      "last_seen_ssh_unix": last_seen_ssh,
      "last_seen_ovpn_unix": last_seen_ovpn,
    },
    "derived": {
      "quota_used_total_bytes": quota_used_total,
      "active_session_total": active_session_total,
      "distinct_ip_total": distinct_ip_total,
      "distinct_ips_total": distinct_ips_total,
      "quota_exhausted": bool(quota_exhausted_ssh),
      "quota_exhausted_ssh": bool(quota_exhausted_ssh),
      "quota_exhausted_ovpn": bool(quota_exhausted_ovpn),
      "ip_limit_locked": bool(ip_limit_locked),
      "ip_limit_metric": ip_limit_metric,
      "access_effective": bool(access_effective_ssh),
      "access_effective_ssh": bool(access_effective_ssh),
      "access_effective_ovpn": bool(access_effective_ovpn),
      "speed_limit_active_ssh": speed_limit_active_ssh,
      "speed_limit_active_ovpn": speed_limit_active_ovpn,
      "speed_limit_active_total": speed_limit_active_total,
      "last_reason": str(last_reason_ssh if last_reason_ssh not in ("", "-") else last_reason_ovpn).strip() or "-",
      "last_reason_ssh": str(last_reason_ssh or "-").strip() or "-",
      "last_reason_ovpn": str(last_reason_ovpn or "-").strip() or "-",
    },
    "meta": meta,
  }

def enforce_user(path):
  payload = normalize_payload(path)
  status = payload["status"]
  before = json.dumps(payload, ensure_ascii=False, sort_keys=True)

  username = norm_user(payload.get("username") or path.stem) or norm_user(path.stem) or path.stem
  active_sessions_count = active_sessions(username)
  runtime_count, _runtime_ip_count, runtime_ips, runtime_sessions = runtime_session_stats(username)
  if runtime_count is None:
    runtime_ips = []
    runtime_sessions = []
  quota_used = to_int(payload.get("quota_used"), 0)

  sync_unified_ssh_runtime(
    username,
    quota_used=quota_used,
    active_sessions_count=active_sessions_count,
    distinct_ips=runtime_ips,
    session_rows=runtime_sessions,
  )
  sync_unified_ovpn_access()

  unified = load_unified_state(username)
  unified_policy = unified.get("policy") if isinstance(unified.get("policy"), dict) else {}
  unified_derived = unified.get("derived") if isinstance(unified.get("derived"), dict) else {}
  unified_runtime = unified.get("runtime") if isinstance(unified.get("runtime"), dict) else {}
  unified_meta = unified.get("meta") if isinstance(unified.get("meta"), dict) else {}

  ip_enabled = bool(status.get("ip_limit_enabled"))
  ip_limit = to_int(status.get("ip_limit"), 0)
  if ip_limit < 0:
    ip_limit = 0
  speed_enabled = to_bool(status.get("speed_limit_enabled"))
  speed_down = max(0.0, to_float(status.get("speed_down_mbit"), 0.0))
  speed_up = max(0.0, to_float(status.get("speed_up_mbit"), 0.0))
  if isinstance(unified_policy, dict) and unified_policy:
    ip_enabled = to_bool(unified_policy.get("ip_limit_enabled"))
    ip_limit = to_int(unified_policy.get("ip_limit"), ip_limit)
    speed_enabled = to_bool(unified_policy.get("speed_limit_enabled"))
    speed_down = max(0.0, to_float(unified_policy.get("speed_down_mbit"), speed_down))
    speed_up = max(0.0, to_float(unified_policy.get("speed_up_mbit"), speed_up))
  status["ip_limit_enabled"] = bool(ip_enabled)
  status["ip_limit"] = max(0, ip_limit)
  status["ip_limit_locked"] = bool(unified_derived.get("ip_limit_locked")) if unified_derived else False
  if not speed_enabled:
    speed_down = 0.0
    speed_up = 0.0
  status["speed_limit_enabled"] = bool(speed_enabled and (speed_down > 0 or speed_up > 0))
  status["speed_down_mbit"] = speed_down if status["speed_limit_enabled"] else 0.0
  status["speed_up_mbit"] = speed_up if status["speed_limit_enabled"] else 0.0

  quota_limit = to_int(payload.get("quota_limit"), 0)
  if isinstance(unified_policy, dict) and unified_policy:
    quota_limit = to_int(unified_policy.get("quota_limit_ssh_bytes"), to_int(unified_policy.get("quota_limit_bytes"), quota_limit))
  payload["quota_limit"] = max(0, quota_limit)
  payload["policy"]["quota_limit_bytes"] = max(0, quota_limit)
  payload["policy"]["quota_limit_ssh_bytes"] = max(0, quota_limit)
  payload["policy"]["quota_limit_ovpn_bytes"] = to_int(
    unified_policy.get("quota_limit_ovpn_bytes"),
    to_int(payload["policy"].get("quota_limit_ovpn_bytes"), max(0, quota_limit)),
  )
  payload["policy"]["quota_unit"] = str(unified_policy.get("quota_unit") or payload["policy"].get("quota_unit") or "binary").strip().lower() or "binary"
  status["quota_exhausted"] = bool(unified_derived.get("quota_exhausted_ssh")) if unified_derived else bool(quota_limit > 0 and quota_used >= quota_limit)
  payload["runtime"]["quota_used_ssh_bytes"] = max(0, quota_used)
  payload["runtime"]["quota_used_ovpn_bytes"] = max(0, to_int(unified_runtime.get("quota_used_ovpn_bytes"), to_int(payload["runtime"].get("quota_used_ovpn_bytes"), 0)))
  payload["runtime"]["active_session_ssh"] = max(0, active_sessions_count)
  payload["runtime"]["active_session_ovpn"] = max(0, to_int(unified_runtime.get("active_session_ovpn"), to_int(payload["runtime"].get("active_session_ovpn"), 0)))
  payload["runtime"]["last_seen_ssh_unix"] = max(0, to_int(unified_runtime.get("last_seen_ssh_unix"), to_int(payload["runtime"].get("last_seen_ssh_unix"), 0)))
  payload["runtime"]["last_seen_ovpn_unix"] = max(0, to_int(unified_runtime.get("last_seen_ovpn_unix"), to_int(payload["runtime"].get("last_seen_ovpn_unix"), 0)))
  payload["runtime"]["distinct_ips_ssh"] = normalize_ip_list(unified_runtime.get("distinct_ips_ssh"))
  payload["runtime"]["distinct_ips_ovpn"] = normalize_ip_list(unified_runtime.get("distinct_ips_ovpn"))
  payload["runtime"]["sessions_ssh"] = normalize_session_rows(unified_runtime.get("sessions_ssh"), "ssh")
  payload["runtime"]["sessions_ovpn"] = normalize_session_rows(unified_runtime.get("sessions_ovpn"), "ovpn")
  payload["derived"]["quota_used_total_bytes"] = max(0, to_int(unified_derived.get("quota_used_total_bytes"), quota_used + to_int(payload["runtime"].get("quota_used_ovpn_bytes"), 0)))
  payload["derived"]["active_session_total"] = max(0, to_int(unified_derived.get("active_session_total"), active_sessions_count + to_int(payload["runtime"].get("active_session_ovpn"), 0)))
  payload["derived"]["distinct_ip_total"] = max(0, to_int(unified_derived.get("distinct_ip_total"), payload["derived"].get("distinct_ip_total")))
  payload["derived"]["distinct_ips_total"] = normalize_ip_list(unified_derived.get("distinct_ips_total"))
  payload["derived"]["quota_exhausted"] = bool(unified_derived.get("quota_exhausted_ssh")) if unified_derived else bool(status["quota_exhausted"])
  payload["derived"]["quota_exhausted_ssh"] = bool(unified_derived.get("quota_exhausted_ssh")) if unified_derived else bool(status["quota_exhausted"])
  payload["derived"]["quota_exhausted_ovpn"] = bool(unified_derived.get("quota_exhausted_ovpn")) if unified_derived else bool(payload["derived"].get("quota_exhausted_ovpn"))
  payload["derived"]["ip_limit_locked"] = bool(unified_derived.get("ip_limit_locked")) if unified_derived else bool(status.get("ip_limit_locked"))
  payload["derived"]["ip_limit_metric"] = max(0, to_int(unified_derived.get("ip_limit_metric"), payload["derived"].get("ip_limit_metric")))
  payload["derived"]["speed_limit_active_ssh"] = max(0, to_int(unified_derived.get("speed_limit_active_ssh"), payload["derived"].get("speed_limit_active_ssh")))
  payload["derived"]["speed_limit_active_ovpn"] = max(0, to_int(unified_derived.get("speed_limit_active_ovpn"), payload["derived"].get("speed_limit_active_ovpn")))
  payload["derived"]["speed_limit_active_total"] = max(0, to_int(unified_derived.get("speed_limit_active_total"), payload["derived"].get("speed_limit_active_total")))

  reason = ""
  if bool(status.get("manual_block")):
    reason = "manual"
  else:
    unified_reason = str(unified_derived.get("last_reason_ssh") or unified_derived.get("last_reason") or "").strip().lower() if unified_derived else ""
    if bool(status.get("quota_exhausted")):
      reason = "quota" if unified_reason in ("", "-") else unified_reason
    elif bool(status.get("ip_limit_locked")):
      reason = "ip_limit" if unified_reason in ("", "-") else unified_reason

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
    if exists and account_locked and lock_owner == "ssh_qac":
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
  payload["derived"]["last_reason"] = reason or str(unified_derived.get("last_reason") or "-").strip() or "-"
  payload["derived"]["last_reason_ssh"] = str(unified_derived.get("last_reason_ssh") or payload["derived"].get("last_reason") or "-").strip() or "-"
  payload["derived"]["last_reason_ovpn"] = str(unified_derived.get("last_reason_ovpn") or "-").strip() or "-"
  payload["derived"]["access_effective"] = bool(unified_derived.get("access_effective_ssh")) if unified_derived else bool(payload["derived"].get("access_effective"))
  payload["derived"]["access_effective_ssh"] = bool(unified_derived.get("access_effective_ssh")) if unified_derived else bool(payload["derived"].get("access_effective_ssh"))
  payload["derived"]["access_effective_ovpn"] = bool(unified_derived.get("access_effective_ovpn")) if unified_derived else bool(payload["derived"].get("access_effective_ovpn"))
  payload["meta"]["updated_at_unix"] = max(0, to_int(unified_meta.get("updated_at_unix"), to_int(payload["meta"].get("updated_at_unix"), 0)))
  payload["meta"]["ovpn_present"] = bool(to_bool(unified_meta.get("ovpn_present"), payload["meta"].get("ovpn_present")))

  after = json.dumps(payload, ensure_ascii=False, sort_keys=True)
  if after != before:
    write_json_atomic(path, payload)
    try:
      os.chmod(path, 0o600)
    except Exception:
      pass

def run_once(target_user):
  if not STATE_ROOT.exists():
    return 0
  try:
    LOCK_FILE.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(str(LOCK_FILE.parent), 0o700)
  except Exception:
    pass
  with open(LOCK_FILE, "a+", encoding="utf-8") as lf:
    fcntl.flock(lf.fileno(), fcntl.LOCK_EX)
    try:
      paths = sorted(STATE_ROOT.glob("*.json"), key=lambda p: p.name.lower())
      target_norm = norm_user(target_user)
      for path in paths:
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
        enforce_user(path)
    finally:
      fcntl.flock(lf.fileno(), fcntl.LOCK_UN)
  return 0

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
