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

STATE_ROOT = pathlib.Path("/opt/quota/ssh")
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
    return None, None
  total = 0
  ips = set()
  try:
    for path, payload in iter_runtime_sessions(SESSION_ROOT, prune_stale=True):
      session_user = norm_user(payload.get("username") or path.stem)
      if session_user == user:
        total += 1
        ip = normalize_ip(payload.get("client_ip"))
        if ip:
          ips.add(ip)
  except Exception:
    return None, None
  return total, len(ips)

def active_sessions_from_runtime(username):
  total, _ = runtime_session_stats(username)
  return total

_DROPBEAR_ROWS_CACHE = None
_DROPBEAR_AUTH_CACHE = None


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
  dropbear_count = active_sessions_from_dropbear(username)
  if runtime_count is not None:
    return max(int(runtime_count), int(dropbear_count))
  return int(dropbear_count)

def active_login_metric(username):
  if not username or not user_exists(username):
    return 0
  runtime_count, runtime_ip_count = runtime_session_stats(username)
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


def sync_unified_ssh_runtime(username, quota_used=None, active_sessions_count=None, quota_exhausted=None, ip_limit_locked=None, last_reason=None):
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
    "speed_limit_enabled": to_bool(status.get("speed_limit_enabled")),
    "speed_down_mbit": speed_down,
    "speed_up_mbit": speed_up,
    "lock_reason": str(status.get("lock_reason") or "").strip().lower(),
    "account_locked": to_bool(status.get("account_locked")),
    "lock_owner": str(status.get("lock_owner") or "").strip(),
    "lock_shell_restore": str(status.get("lock_shell_restore") or "").strip(),
  }
  return payload

def enforce_user(path):
  payload = normalize_payload(path)
  status = payload["status"]
  before = json.dumps(payload, ensure_ascii=False, sort_keys=True)

  username = norm_user(payload.get("username") or path.stem) or norm_user(path.stem) or path.stem
  active_sessions_count = active_sessions(username)
  quota_used = to_int(payload.get("quota_used"), 0)

  sync_unified_ssh_runtime(
    username,
    quota_used=quota_used,
    active_sessions_count=active_sessions_count,
  )
  sync_unified_ovpn_access()

  unified = load_unified_state(username)
  unified_policy = unified.get("policy") if isinstance(unified.get("policy"), dict) else {}
  unified_derived = unified.get("derived") if isinstance(unified.get("derived"), dict) else {}

  ip_enabled = bool(status.get("ip_limit_enabled"))
  ip_limit = to_int(status.get("ip_limit"), 0)
  if ip_limit < 0:
    ip_limit = 0
  if isinstance(unified_policy, dict) and unified_policy:
    ip_enabled = to_bool(unified_policy.get("ip_limit_enabled"))
    ip_limit = to_int(unified_policy.get("ip_limit"), ip_limit)
  status["ip_limit_enabled"] = bool(ip_enabled)
  status["ip_limit"] = max(0, ip_limit)
  status["ip_limit_locked"] = bool(unified_derived.get("ip_limit_locked")) if unified_derived else False

  quota_limit = to_int(payload.get("quota_limit"), 0)
  if isinstance(unified_policy, dict) and unified_policy:
    quota_limit = to_int(unified_policy.get("quota_limit_bytes"), quota_limit)
  payload["quota_limit"] = max(0, quota_limit)
  status["quota_exhausted"] = bool(unified_derived.get("quota_exhausted")) if unified_derived else bool(quota_limit > 0 and quota_used >= quota_limit)

  reason = ""
  if bool(status.get("manual_block")):
    reason = "manual"
  else:
    unified_reason = str(unified_derived.get("last_reason") or "").strip().lower() if unified_derived else ""
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

  after = json.dumps(payload, ensure_ascii=False, sort_keys=True)
  if after != before:
    write_json_atomic(path, payload)
    try:
      os.chmod(path, 0o600)
    except Exception:
      pass

  sync_unified_ssh_runtime(
    username,
    quota_used=quota_used,
    active_sessions_count=active_sessions_count,
  )

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
