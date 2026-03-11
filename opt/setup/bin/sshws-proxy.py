#!/usr/bin/env python3
import argparse
import asyncio
import fcntl
import glob
import ipaddress
import json
import os
import pwd
import re
import signal
import subprocess
import tempfile
import time
from collections import defaultdict, deque
from pathlib import Path
from urllib.parse import urlsplit

HANDSHAKE_TIMEOUT_DEFAULT = 10.0
QAC_STATE_ROOT = Path("/opt/quota/ssh")
QAC_LOCK_FILE = Path("/run/autoscript/locks/sshws-qac.lock")
QAC_ENFORCER_BIN = Path("/usr/local/bin/sshws-qac-enforcer")
QAC_SESSION_ROOT = Path("/run/autoscript/sshws-sessions")
POLICY_REFRESH_SEC = 2.0
RUNTIME_SESSION_HEARTBEAT_SEC = 15.0
UNASSIGNED_RESOLVE_BURST_BYTES = 4096
UNASSIGNED_RESOLVE_MIN_INTERVAL_SEC = 0.05
ATTRIBUTION_WARMUP_ATTEMPTS = 6
ATTRIBUTION_WARMUP_DELAY_SEC = 0.05
ATTRIBUTION_WARMUP_SCAN_TIMEOUT_SEC = 0.1
SSHWS_TOKEN_RE = re.compile(r"^[a-f0-9]{10}$")


class HandshakeError(Exception):
  def __init__(self, code, reason):
    super().__init__(reason)
    self.code = code
    self.reason = reason


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
  if SSHWS_TOKEN_RE.fullmatch(s):
    return s
  return ""


def extract_token_from_path(path, expected_prefix):
  raw_path = str(path or "/").split("?", 1)[0].split("#", 1)[0] or "/"
  prefix = str(expected_prefix or "/").split("?", 1)[0].split("#", 1)[0] or "/"
  prefix = prefix.rstrip("/") or "/"
  if prefix == "/":
    parts = [part for part in raw_path.split("/") if part]
    if not parts or len(parts) > 2:
      return ""
    if len(parts) == 2 and parts[0] in {
      "vless-ws",
      "vmess-ws",
      "trojan-ws",
      "vless-hup",
      "vmess-hup",
      "trojan-hup",
      "vless-grpc",
      "vmess-grpc",
      "trojan-grpc",
    }:
      return ""
    return normalize_token(parts[-1])
  wanted = prefix + "/"
  if not raw_path.startswith(wanted):
    return ""
  suffix = raw_path[len(wanted):].strip("/")
  if not suffix or "/" in suffix:
    return ""
  return normalize_token(suffix)


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


def extract_client_ip(headers, peername=None):
  hdrs = headers if isinstance(headers, dict) else {}
  candidates = []
  value = normalize_ip(hdrs.get("cf-connecting-ip"))
  if value:
    candidates.append(value)
  if isinstance(peername, tuple) and peername:
    value = normalize_ip(peername[0])
    if value:
      candidates.append(value)
  for value in candidates:
    if value and value not in ("127.0.0.1", "::1"):
      return value
  for value in candidates:
    if value:
      return value
  return ""


def write_json_atomic_file(path, payload, mode=0o600):
  path = Path(path)
  try:
    path.parent.mkdir(parents=True, exist_ok=True)
  except Exception:
    pass
  text = json.dumps(payload, ensure_ascii=False, indent=2) + "\n"
  fd, tmp = tempfile.mkstemp(prefix=".tmp.", suffix=".json", dir=str(path.parent))
  try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
      f.write(text)
      f.flush()
      os.fsync(f.fileno())
    os.replace(tmp, str(path))
    try:
      os.chmod(str(path), int(mode))
    except Exception:
      pass
  finally:
    try:
      if os.path.exists(tmp):
        os.remove(tmp)
    except Exception:
      pass


def cleanup_runtime_session_root(root):
  root_path = Path(root)
  try:
    root_path.mkdir(parents=True, exist_ok=True)
    os.chmod(str(root_path), 0o700)
  except Exception:
    pass
  try:
    for path in root_path.glob("*.json"):
      try:
        path.unlink()
      except FileNotFoundError:
        pass
      except Exception:
        pass
  except Exception:
    pass

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

def runtime_session_payload_valid(payload):
  if not isinstance(payload, dict):
    return False
  if not pid_alive(payload.get("proxy_pid")):
    return False
  updated_at = to_int(payload.get("updated_at"), 0)
  now = int(time.time())
  if updated_at <= 0 or now <= 0:
    return False
  return (now - updated_at) <= int(RUNTIME_SESSION_STALE_SEC)

def iter_runtime_sessions(root, prune_stale=False):
  root_path = Path(root)
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

def runtime_session_stats(root, username, extra_client_ips=None):
  root_path = Path(root)
  user = norm_user(username)
  if not user or not root_path.is_dir():
    return 0, 0
  total = 0
  ips = set()
  try:
    for path, payload in iter_runtime_sessions(root_path, prune_stale=True):
      session_user = norm_user(payload.get("username") or path.stem)
      if session_user != user:
        continue
      total += 1
      ip = normalize_ip(payload.get("client_ip"))
      if ip:
        ips.add(ip)
  except Exception:
    return 0, 0
  extra_values = extra_client_ips if isinstance(extra_client_ips, (list, tuple, set)) else (extra_client_ips,)
  for value in extra_values:
    extra_ip = normalize_ip(value)
    if extra_ip:
      ips.add(extra_ip)
  return total, len(ips)


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
    for c in children.get(cur, ()):
      q.append(c)
  return ""


def scan_dropbear_sessions(dropbear_port, timeout_sec=1.0):
  try:
    timeout = float(timeout_sec)
  except Exception:
    timeout = 1.0
  if timeout < 0.05:
    timeout = 0.05
  try:
    p = subprocess.run(
      ["ss", "-tnpH"],
      check=False,
      capture_output=True,
      text=True,
      timeout=timeout,
    )
  except Exception:
    return {}

  if p.returncode != 0:
    return {}

  proc_info, children = _build_proc_tables()
  out = {}
  for raw in (p.stdout or "").splitlines():
    line = raw.strip()
    if not line or "dropbear" not in line:
      continue
    cols = line.split()
    if len(cols) < 6:
      continue
    lport = _parse_port(cols[3])
    rport = _parse_port(cols[4])
    if lport != int(dropbear_port) or rport <= 0:
      continue
    m = re.search(r"pid=(\d+)", line)
    if not m:
      continue
    user = _username_from_pid(int(m.group(1)), proc_info, children)
    if user:
      out[rport] = user
  return out


class SharedRateLimiter:
  def __init__(self):
    self._lock = asyncio.Lock()
    self._next_ts = {}

  async def throttle(self, user, direction, amount_bytes, rate_bps):
    if not user or amount_bytes <= 0 or rate_bps <= 0:
      return
    key = "{}|{}".format(user, direction)
    now = time.monotonic()
    async with self._lock:
      nxt = float(self._next_ts.get(key, now))
      start = nxt if nxt > now else now
      wait_s = max(0.0, start - now)
      dur_s = float(amount_bytes) / float(rate_bps)
      self._next_ts[key] = start + dur_s
    if wait_s > 0:
      await asyncio.sleep(wait_s)


class QuotaManager:
  def __init__(self, state_root, lock_file, enforcer_bin, session_root):
    self.state_root = Path(state_root)
    self.lock_file = Path(lock_file)
    self.enforcer_bin = Path(enforcer_bin)
    self.session_root = Path(session_root)
    self._pending = defaultdict(int)
    self._cache = {}
    self._cache_lock = asyncio.Lock()

  def _qf(self, username):
    u = norm_user(username)
    return self.state_root / "{}@ssh.json".format(u)

  def _legacy_qf(self, username):
    u = norm_user(username)
    return self.state_root / "{}.json".format(u)

  def _resolve_qf(self, username):
    primary = self._qf(username)
    if primary.is_file():
      return primary
    legacy = self._legacy_qf(username)
    if legacy.is_file():
      return legacy
    return primary

  def _state_entries(self):
    try:
      entries = sorted(self.state_root.iterdir(), key=lambda p: p.name.lower())
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

  def _load_json(self, path):
    try:
      with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
      if isinstance(data, dict):
        return data
    except Exception:
      pass
    return {}

  def _write_json_atomic(self, path, payload):
    write_json_atomic_file(path, payload, 0o600)

  def _invalidate_cache(self, users):
    if not users:
      return
    for user in users:
      self._cache.pop(norm_user(user), None)

  def _trigger_enforcer_sync(self, target_user=""):
    if not self.enforcer_bin.is_file() or not os.access(str(self.enforcer_bin), os.X_OK):
      return False
    cmd = [str(self.enforcer_bin), "--once"]
    user = norm_user(target_user)
    if user:
      cmd.extend(["--user", user])
    try:
      subprocess.run(
        cmd,
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=10,
      )
      return True
    except Exception:
      return False

  def _parse_policy(self, username, payload):
    st_raw = payload.get("status")
    st = st_raw if isinstance(st_raw, dict) else {}
    speed_enabled = to_bool(st.get("speed_limit_enabled"))
    speed_down = max(0.0, to_float(st.get("speed_down_mbit"), 0.0))
    speed_up = max(0.0, to_float(st.get("speed_up_mbit"), 0.0))
    if not speed_enabled:
      speed_down = 0.0
      speed_up = 0.0
    else:
      if speed_down <= 0:
        speed_down = 0.0
      if speed_up <= 0:
        speed_up = 0.0
      speed_enabled = bool(speed_down > 0 or speed_up > 0)

    lock_reason = str(st.get("lock_reason") or "").strip().lower()
    blocked = (
      to_bool(st.get("manual_block")) or
      to_bool(st.get("quota_exhausted")) or
      to_bool(st.get("ip_limit_locked")) or
      to_bool(st.get("account_locked")) or
      lock_reason in ("manual", "quota", "ip_limit")
    )

    return {
      "username": username,
      "blocked": blocked,
      "speed_enabled": speed_enabled,
      "speed_down_bps": int(speed_down * 125000.0) if speed_enabled else 0,
      "speed_up_bps": int(speed_up * 125000.0) if speed_enabled else 0,
    }

  async def resolve_token(self, token):
    tok = normalize_token(token)
    if not tok or not self.state_root.is_dir():
      return ""
    for qf in self._state_entries():
      payload = self._load_json(qf)
      if normalize_token(payload.get("sshws_token")) != tok:
        continue
      user = norm_user(payload.get("username") or qf.stem)
      if user:
        return user
    return ""

  async def get_policy(self, username):
    user = norm_user(username)
    if not user:
      return None
    qf = self._resolve_qf(user)
    try:
      st = os.stat(str(qf))
      mtime_ns = int(getattr(st, "st_mtime_ns", int(st.st_mtime * 1_000_000_000)))
    except Exception:
      return None

    async with self._cache_lock:
      cached = self._cache.get(user)
      if cached and cached.get("mtime_ns") == mtime_ns:
        return cached.get("policy")

    payload = self._load_json(qf)
    policy = self._parse_policy(user, payload)
    async with self._cache_lock:
      self._cache[user] = {"mtime_ns": mtime_ns, "policy": policy}
    return policy

  async def get_admission(self, username, client_ip="", extra_total=0, extra_client_ips=None):
    user = norm_user(username)
    if not user:
      return {"allowed": False, "reason": "Forbidden", "policy": None}
    qf = self._resolve_qf(user)
    if not qf.is_file():
      return {"allowed": False, "reason": "Forbidden", "policy": None}
    payload = self._load_json(qf)
    if not isinstance(payload, dict):
      return {"allowed": False, "reason": "Forbidden", "policy": None}

    policy = self._parse_policy(user, payload)
    st_raw = payload.get("status")
    st = st_raw if isinstance(st_raw, dict) else {}
    lock_reason = str(st.get("lock_reason") or "").strip().lower()

    if to_bool(st.get("manual_block")) or lock_reason == "manual":
      return {"allowed": False, "reason": "Account Locked", "policy": policy}

    quota_limit = max(0, to_int(payload.get("quota_limit"), 0))
    quota_used = max(0, to_int(payload.get("quota_used"), 0))
    if to_bool(st.get("quota_exhausted")) or lock_reason == "quota" or (quota_limit > 0 and quota_used >= quota_limit):
      return {"allowed": False, "reason": "Account Locked", "policy": policy}

    if to_bool(st.get("account_locked")) and lock_reason not in ("", "ip_limit"):
      return {"allowed": False, "reason": "Account Locked", "policy": policy}

    ip_enabled = to_bool(st.get("ip_limit_enabled"))
    ip_limit = max(0, to_int(st.get("ip_limit"), 0))
    if ip_enabled and ip_limit > 0:
      extra_ips = tuple(extra_client_ips or ())
      if client_ip:
        extra_ips = extra_ips + (client_ip,)
      active_total, active_ip_count = runtime_session_stats(
        self.session_root,
        user,
        extra_client_ips=extra_ips,
      )
      prospective_total = int(active_total) + 1 + max(0, int(extra_total))
      prospective_metric = max(prospective_total, int(active_ip_count or 0))
      if prospective_metric > ip_limit:
        return {"allowed": False, "reason": "IP/Login Limit Reached", "policy": policy}

    return {"allowed": True, "reason": "", "policy": policy}

  async def enforce_now(self, target_user=""):
    user = norm_user(target_user)
    await asyncio.to_thread(self._trigger_enforcer_sync, user)

  async def record(self, username, up_bytes=0, down_bytes=0):
    user = norm_user(username)
    if not user:
      return
    total = max(0, int(up_bytes)) + max(0, int(down_bytes))
    if total <= 0:
      return
    self._pending[user] += total

  async def flush_once(self):
    if not self._pending:
      return False
    deltas = dict(self._pending)
    self._pending.clear()

    changed = []
    try:
      self.lock_file.parent.mkdir(parents=True, exist_ok=True)
    except Exception:
      pass

    lockh = open(str(self.lock_file), "a+", encoding="utf-8")
    try:
      fcntl.flock(lockh.fileno(), fcntl.LOCK_EX)
      for user, delta in deltas.items():
        if int(delta) <= 0:
          continue
        qf = self._resolve_qf(user)
        if not qf.is_file():
          continue
        payload = self._load_json(qf)
        old_used = max(0, to_int(payload.get("quota_used"), 0))
        new_used = old_used + int(delta)
        if new_used == old_used:
          continue
        payload["quota_used"] = new_used
        self._write_json_atomic(qf, payload)
        changed.append(user)
    finally:
      try:
        fcntl.flock(lockh.fileno(), fcntl.LOCK_UN)
      except Exception:
        pass
      lockh.close()

    if changed:
      async with self._cache_lock:
        self._invalidate_cache(changed)
      await asyncio.to_thread(self._trigger_enforcer_sync, "")
    return bool(changed)


class ConnectionContext:
  def __init__(self, backend_local_port, quota_manager, session_root, client_ip=""):
    self.backend_local_port = int(backend_local_port)
    self._quota = quota_manager
    self._session_root = Path(session_root)
    self._session_path = self._session_root / "{}.json".format(self.backend_local_port) if self.backend_local_port > 0 else None
    self._client_ip = normalize_ip(client_ip)
    self._lock = asyncio.Lock()
    self._username = ""
    self._pending_up = 0
    self._pending_down = 0
    self._policy_cached = None
    self._policy_cached_at = 0.0
    self._session_written_at = 0.0
    self._created_at = int(time.time())

  def write_runtime_session(self, username=""):
    if self._session_path is None:
      return
    payload = {
      "backend_local_port": int(self.backend_local_port),
      "backend": "dropbear",
      "backend_target": "{}:{}".format(BACKEND_HOST, BACKEND_PORT),
      "transport": "ssh-ws",
      "source": "sshws-proxy",
      "proxy_pid": int(os.getpid()),
      "created_at": int(self._created_at),
      "updated_at": int(time.time()),
    }
    user = norm_user(username or self._username)
    if user:
      payload["username"] = user
    if self._client_ip:
      payload["client_ip"] = self._client_ip
    write_json_atomic_file(self._session_path, payload, 0o600)
    self._session_written_at = time.monotonic()

  def clear_runtime_session(self):
    if self._session_path is None:
      return
    try:
      self._session_path.unlink()
    except FileNotFoundError:
      pass
    except Exception:
      pass
    self._session_written_at = 0.0

  async def touch_runtime_session(self, force=False):
    if self._session_path is None:
      return
    async with self._lock:
      user = self._username
      last_written = float(self._session_written_at or 0.0)
    if not user:
      return
    now = time.monotonic()
    if not force and last_written > 0 and (now - last_written) < float(RUNTIME_SESSION_HEARTBEAT_SEC):
      return
    try:
      self.write_runtime_session(user)
    except Exception:
      pass

  async def assign_username(self, username):
    user = norm_user(username)
    if not user:
      return
    flush_up = 0
    flush_down = 0
    async with self._lock:
      if self._username:
        return
      self._username = user
      flush_up = self._pending_up
      flush_down = self._pending_down
      self._pending_up = 0
      self._pending_down = 0
      self._policy_cached = None
      self._policy_cached_at = 0.0
    try:
      self.write_runtime_session(user)
    except Exception:
      pass
    if flush_up or flush_down:
      await self._quota.record(user, flush_up, flush_down)

  async def username(self):
    async with self._lock:
      return self._username

  async def record_up(self, size):
    n = max(0, int(size))
    if n <= 0:
      return
    async with self._lock:
      user = self._username
      if not user:
        self._pending_up += n
        return
    await self._quota.record(user, up_bytes=n, down_bytes=0)

  async def record_down(self, size):
    n = max(0, int(size))
    if n <= 0:
      return
    async with self._lock:
      user = self._username
      if not user:
        self._pending_down += n
        return
    await self._quota.record(user, up_bytes=0, down_bytes=n)

  async def policy(self):
    user = await self.username()
    if not user:
      return None
    now = time.monotonic()
    async with self._lock:
      if self._policy_cached and (now - self._policy_cached_at) < POLICY_REFRESH_SEC:
        return self._policy_cached
    p = await self._quota.get_policy(user)
    async with self._lock:
      self._policy_cached = p
      self._policy_cached_at = now
    return p


class ConnectionRegistry:
  def __init__(self):
    self._lock = asyncio.Lock()
    self._by_port = {}
    self._pending_totals = defaultdict(int)
    self._pending_ips = defaultdict(lambda: defaultdict(int))

  def _pending_snapshot_unlocked(self, username):
    user = norm_user(username)
    if not user:
      return 0, ()
    ip_map = self._pending_ips.get(user, {})
    return int(self._pending_totals.get(user, 0)), tuple(sorted(ip_map.keys()))

  def _reserve_pending_unlocked(self, username, client_ip):
    user = norm_user(username)
    ip = normalize_ip(client_ip)
    if not user:
      return None
    self._pending_totals[user] += 1
    if ip:
      self._pending_ips[user][ip] += 1
    return (user, ip)

  def _release_pending_unlocked(self, reservation):
    if not reservation:
      return
    user = norm_user(reservation[0] if len(reservation) > 0 else "")
    ip = normalize_ip(reservation[1] if len(reservation) > 1 else "")
    if not user:
      return
    current_total = int(self._pending_totals.get(user, 0))
    if current_total > 1:
      self._pending_totals[user] = current_total - 1
    else:
      self._pending_totals.pop(user, None)
    if ip:
      current_ip = int(self._pending_ips.get(user, {}).get(ip, 0))
      if current_ip > 1:
        self._pending_ips[user][ip] = current_ip - 1
      else:
        self._pending_ips.get(user, {}).pop(ip, None)
      if not self._pending_ips.get(user):
        self._pending_ips.pop(user, None)

  async def reserve_admission(self, username, client_ip, quota_mgr):
    admission = {"allowed": False, "reason": "Forbidden", "policy": None}
    user = norm_user(username)
    async with self._lock:
      pending_total, pending_ips = self._pending_snapshot_unlocked(user)
      admission = await quota_mgr.get_admission(user, client_ip, extra_total=pending_total, extra_client_ips=pending_ips)
      if not admission.get("policy") or not admission.get("allowed"):
        return admission, None
      reservation = self._reserve_pending_unlocked(user, client_ip)
      return admission, reservation

  async def finalize_admission(self, reservation, ctx):
    user = norm_user(reservation[0] if reservation else "")
    async with self._lock:
      self._release_pending_unlocked(reservation)
      await ctx.assign_username(user)
      if ctx.backend_local_port > 0:
        self._by_port[ctx.backend_local_port] = ctx
    return True

  async def cancel_reservation(self, reservation):
    async with self._lock:
      self._release_pending_unlocked(reservation)

  async def register(self, ctx):
    if ctx.backend_local_port <= 0:
      return
    async with self._lock:
      self._by_port[ctx.backend_local_port] = ctx

  async def unregister(self, ctx):
    if ctx.backend_local_port <= 0:
      return
    async with self._lock:
      cur = self._by_port.get(ctx.backend_local_port)
      if cur is ctx:
        self._by_port.pop(ctx.backend_local_port, None)

  async def assign_by_port_map(self, port_user_map):
    targets = []
    async with self._lock:
      for port, user in port_user_map.items():
        ctx = self._by_port.get(int(port))
        if ctx and user:
          targets.append((ctx, user))
    for ctx, user in targets:
      await ctx.assign_username(user)


async def _resolve_ctx_username_with_retry(args, registry, ctx, attempts=1, delay_sec=0.05, scan_timeout_sec=1.0):
  tries = max(1, int(attempts))
  delay = max(0.0, float(delay_sec))
  scan_timeout = max(0.05, float(scan_timeout_sec))
  for idx in range(tries):
    if await ctx.username():
      return True
    try:
      pmap = await asyncio.to_thread(scan_dropbear_sessions, int(args.backend_port), scan_timeout)
      await registry.assign_by_port_map(pmap)
    except Exception:
      pass
    if await ctx.username():
      return True
    if delay > 0 and (idx + 1) < tries:
      await asyncio.sleep(delay)
  return bool(await ctx.username())


async def _send_http_error(writer, code, reason):
  body = "{} {}\n".format(code, reason).encode("utf-8")
  resp = (
    "HTTP/1.1 {} {}\r\n".format(code, reason) +
    "Content-Type: text/plain\r\n" +
    "Content-Length: {}\r\n".format(len(body)) +
    "Connection: close\r\n" +
    "\r\n"
  ).encode("ascii")
  writer.write(resp + body)
  await writer.drain()


async def _read_handshake(reader, expected_path, timeout_sec):
  try:
    raw = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), timeout=timeout_sec)
  except asyncio.TimeoutError as exc:
    raise HandshakeError(408, "Request Timeout") from exc
  except (asyncio.IncompleteReadError, asyncio.LimitOverrunError) as exc:
    raise HandshakeError(400, "Bad Request") from exc

  try:
    text = raw.decode("latin1")
  except UnicodeDecodeError as exc:
    raise HandshakeError(400, "Bad Request") from exc

  lines = text.split("\r\n")
  if not lines or not lines[0]:
    raise HandshakeError(400, "Bad Request")

  req = lines[0].split()
  if len(req) < 3:
    raise HandshakeError(400, "Bad Request")
  method = req[0]
  target = req[1]

  if "://" in target:
    try:
      parsed = urlsplit(target)
      path = parsed.path or "/"
      if parsed.query:
        path = "{}?{}".format(path, parsed.query)
    except Exception:
      path = target
  else:
    path = target

  path_only = (path.split("?", 1)[0].split("#", 1)[0] or "/")
  expected_only = ((expected_path or "/").split("?", 1)[0].split("#", 1)[0] or "/")

  if method.upper() != "GET":
    raise HandshakeError(405, "Method Not Allowed")
  if expected_only == "/":
    if not path_only.startswith("/"):
      raise HandshakeError(404, "Not Found")
  else:
    if path_only != expected_only and not path_only.startswith(expected_only + "/"):
      raise HandshakeError(404, "Not Found")

  headers = {}
  for line in lines[1:]:
    if not line:
      continue
    if ":" not in line:
      continue
    key, value = line.split(":", 1)
    headers[key.strip().lower()] = value.strip()

  if headers.get("upgrade", "").lower() != "websocket":
    raise HandshakeError(400, "Bad Request")
  return headers, path_only


async def _send_handshake_ok(writer):
  resp = (
    "HTTP/1.1 101 Switching Protocols\r\n"
    "Content-Length: 104857600000\r\n"
    "\r\n"
  ).encode("ascii")
  writer.write(resp)
  await writer.drain()


async def _client_to_backend(client_reader, backend_writer, ctx, limiter, args, registry):
  unresolved_up_bytes = 0
  last_resolve_ts = 0.0
  while True:
    data = await client_reader.read(16384)
    if not data:
      break
    if not await ctx.username():
      unresolved_up_bytes += len(data)
      now = time.monotonic()
      if unresolved_up_bytes > UNASSIGNED_RESOLVE_BURST_BYTES and (now - last_resolve_ts) >= UNASSIGNED_RESOLVE_MIN_INTERVAL_SEC:
        last_resolve_ts = now
        try:
          await _resolve_ctx_username_with_retry(args, registry, ctx, attempts=2, delay_sec=0.02, scan_timeout_sec=0.2)
        except Exception:
          pass
    policy = await ctx.policy()
    if policy and policy.get("blocked"):
      break
    if policy and policy.get("speed_enabled"):
      await limiter.throttle(policy.get("username"), "up", len(data), int(policy.get("speed_up_bps") or 0))
      unresolved_up_bytes = 0
    await ctx.record_up(len(data))
    backend_writer.write(data)
    await backend_writer.drain()

  try:
    backend_writer.close()
    await backend_writer.wait_closed()
  except Exception:
    pass


async def _backend_to_client(backend_reader, client_writer, ctx, limiter, args, registry):
  unresolved_down_bytes = 0
  last_resolve_ts = 0.0
  while True:
    data = await backend_reader.read(16384)
    if not data:
      break
    if not await ctx.username():
      unresolved_down_bytes += len(data)
      now = time.monotonic()
      if unresolved_down_bytes > UNASSIGNED_RESOLVE_BURST_BYTES and (now - last_resolve_ts) >= UNASSIGNED_RESOLVE_MIN_INTERVAL_SEC:
        last_resolve_ts = now
        try:
          await _resolve_ctx_username_with_retry(args, registry, ctx, attempts=2, delay_sec=0.02, scan_timeout_sec=0.2)
        except Exception:
          pass
    policy = await ctx.policy()
    if policy and policy.get("blocked"):
      break
    if policy and policy.get("speed_enabled"):
      await limiter.throttle(policy.get("username"), "down", len(data), int(policy.get("speed_down_bps") or 0))
      unresolved_down_bytes = 0
    await ctx.record_down(len(data))
    client_writer.write(data)
    await client_writer.drain()


async def _runtime_session_heartbeat(stop_evt, ctx):
  interval = max(5.0, float(RUNTIME_SESSION_HEARTBEAT_SEC))
  while not stop_evt.is_set():
    try:
      await asyncio.wait_for(stop_evt.wait(), timeout=interval)
      break
    except asyncio.TimeoutError:
      pass
    try:
      await ctx.touch_runtime_session(force=True)
    except Exception:
      pass


async def _handle_client(ws_reader, ws_writer, args, registry, quota_mgr, limiter):
  try:
    headers, path_only = await _read_handshake(ws_reader, args.path, args.handshake_timeout)
  except HandshakeError as exc:
    await _send_http_error(ws_writer, exc.code, exc.reason)
    ws_writer.close()
    await ws_writer.wait_closed()
    return
  except Exception:
    await _send_http_error(ws_writer, 400, "Bad Request")
    ws_writer.close()
    await ws_writer.wait_closed()
    return

  token = extract_token_from_path(path_only, args.path)
  if not token:
    try:
      await _send_http_error(ws_writer, 401, "Unauthorized")
    except Exception:
      pass
    try:
      ws_writer.close()
      await ws_writer.wait_closed()
    except Exception:
      pass
    return

  username = await quota_mgr.resolve_token(token)
  if not username:
    try:
      await _send_http_error(ws_writer, 403, "Forbidden")
    except Exception:
      pass
    try:
      ws_writer.close()
      await ws_writer.wait_closed()
    except Exception:
      pass
    return

  client_ip = extract_client_ip(headers, ws_writer.get_extra_info("peername"))
  admission, reservation = await registry.reserve_admission(username, client_ip, quota_mgr)
  reservation_active = bool(reservation)
  if not admission.get("policy"):
    try:
      await _send_http_error(ws_writer, 403, "Forbidden")
    except Exception:
      pass
    try:
      ws_writer.close()
      await ws_writer.wait_closed()
    except Exception:
      pass
    return
  if not admission.get("allowed"):
    try:
      await _send_http_error(ws_writer, 403, admission.get("reason") or "Account Locked")
    except Exception:
      pass
    try:
      ws_writer.close()
      await ws_writer.wait_closed()
    except Exception:
      pass
    return

  backend_writer = None
  ctx = None
  resolver_task = None
  heartbeat_stop = None
  heartbeat_task = None
  try:
    backend_reader, backend_writer = await asyncio.open_connection(
      args.backend_host,
      args.backend_port,
    )
    sockname = backend_writer.get_extra_info("sockname")
    backend_local_port = int(sockname[1]) if isinstance(sockname, tuple) and len(sockname) > 1 else 0
    ctx = ConnectionContext(backend_local_port, quota_mgr, args.qac_session_root, client_ip)
    await registry.finalize_admission(reservation, ctx)
    reservation_active = False
    try:
      await quota_mgr.enforce_now(username)
    except Exception:
      pass
    heartbeat_stop = asyncio.Event()
    heartbeat_task = asyncio.create_task(_runtime_session_heartbeat(heartbeat_stop, ctx))
  except Exception:
    if reservation_active:
      try:
        await registry.cancel_reservation(reservation)
      except Exception:
        pass
    if backend_writer is not None:
      try:
        backend_writer.close()
        await backend_writer.wait_closed()
      except Exception:
        pass
    try:
      await _send_http_error(ws_writer, 502, "Bad Gateway")
    except Exception:
      pass
    try:
      ws_writer.close()
      await ws_writer.wait_closed()
    except Exception:
      pass
    return

  try:
    await _send_handshake_ok(ws_writer)
    if not await ctx.username():
      # Fallback ini hanya untuk kompatibilitas jika ada sesi tanpa token teratribusi,
      # tetapi jalur normal SSHWS sekarang sudah menetapkan username dari token sejak awal.
      try:
        await _resolve_ctx_username_with_retry(
          args,
          registry,
          ctx,
          attempts=ATTRIBUTION_WARMUP_ATTEMPTS,
          delay_sec=ATTRIBUTION_WARMUP_DELAY_SEC,
          scan_timeout_sec=ATTRIBUTION_WARMUP_SCAN_TIMEOUT_SEC,
        )
      except Exception:
        pass
      resolver_task = asyncio.create_task(
        _resolve_ctx_username_with_retry(args, registry, ctx, attempts=4, delay_sec=0.05, scan_timeout_sec=0.2)
      )
    pump1 = asyncio.create_task(_client_to_backend(ws_reader, backend_writer, ctx, limiter, args, registry))
    pump2 = asyncio.create_task(_backend_to_client(backend_reader, ws_writer, ctx, limiter, args, registry))
    done, pending = await asyncio.wait({pump1, pump2}, return_when=asyncio.FIRST_COMPLETED)
    for t in pending:
      t.cancel()
    if pending:
      await asyncio.gather(*pending, return_exceptions=True)
    for t in done:
      t.exception()
  except Exception:
    pass
  finally:
    if heartbeat_stop is not None:
      heartbeat_stop.set()
    if heartbeat_task is not None and not heartbeat_task.done():
      heartbeat_task.cancel()
      try:
        await heartbeat_task
      except BaseException:
        pass
    if resolver_task is not None and not resolver_task.done():
      resolver_task.cancel()
      try:
        await resolver_task
      except BaseException:
        pass
    if ctx is not None:
      # Best-effort resolve terakhir sebelum context dilepas:
      # mengurangi kemungkinan quota/speed tidak teratribusi pada koneksi pendek.
      current_user = ""
      try:
        if not await ctx.username():
          await _resolve_ctx_username_with_retry(args, registry, ctx, attempts=2, delay_sec=0.02, scan_timeout_sec=0.2)
      except Exception:
        pass
      try:
        current_user = await ctx.username()
      except Exception:
        current_user = ""
      try:
        await quota_mgr.flush_once()
      except Exception:
        pass
      try:
        ctx.clear_runtime_session()
      except Exception:
        pass
      await registry.unregister(ctx)
      if current_user:
        try:
          await quota_mgr.enforce_now(current_user)
        except Exception:
          pass
    if backend_writer is not None:
      try:
        backend_writer.close()
        await backend_writer.wait_closed()
      except Exception:
        pass
    try:
      ws_writer.close()
      await ws_writer.wait_closed()
    except Exception:
      pass


async def _session_map_loop(args, stop_evt, registry):
  interval = max(0.2, float(args.session_scan_interval))
  while not stop_evt.is_set():
    try:
      pmap = await asyncio.to_thread(scan_dropbear_sessions, int(args.backend_port))
      await registry.assign_by_port_map(pmap)
    except Exception:
      pass
    try:
      await asyncio.wait_for(stop_evt.wait(), timeout=interval)
    except asyncio.TimeoutError:
      pass


async def _quota_flush_loop(args, stop_evt, quota_mgr):
  interval = max(1.0, float(args.quota_flush_interval))
  while not stop_evt.is_set():
    try:
      await asyncio.wait_for(stop_evt.wait(), timeout=interval)
      if stop_evt.is_set():
        break
    except asyncio.TimeoutError:
      pass
    try:
      await quota_mgr.flush_once()
    except Exception:
      pass


async def _run(args):
  cleanup_runtime_session_root(args.qac_session_root)
  quota_mgr = QuotaManager(args.qac_state_root, args.qac_lock_file, args.qac_enforcer_bin, args.qac_session_root)
  limiter = SharedRateLimiter()
  registry = ConnectionRegistry()

  server = await asyncio.start_server(
    lambda reader, writer: _handle_client(reader, writer, args, registry, quota_mgr, limiter),
    host=args.listen_host,
    port=args.listen_port,
    backlog=512,
  )

  loop = asyncio.get_running_loop()
  stop_evt = asyncio.Event()
  for sig in (signal.SIGINT, signal.SIGTERM):
    try:
      loop.add_signal_handler(sig, stop_evt.set)
    except NotImplementedError:
      pass

  bg_tasks = [
    asyncio.create_task(_session_map_loop(args, stop_evt, registry)),
    asyncio.create_task(_quota_flush_loop(args, stop_evt, quota_mgr)),
  ]

  await stop_evt.wait()
  server.close()
  await server.wait_closed()

  for t in bg_tasks:
    t.cancel()
  if bg_tasks:
    await asyncio.gather(*bg_tasks, return_exceptions=True)
  try:
    await quota_mgr.flush_once()
  except Exception:
    pass


def _parse_args():
  parser = argparse.ArgumentParser(description="SSH websocket proxy")
  parser.add_argument("--listen-host", default="127.0.0.1")
  parser.add_argument("--listen-port", type=int, default=10015)
  parser.add_argument("--backend-host", default="127.0.0.1")
  parser.add_argument("--backend-port", type=int, default=22022)
  parser.add_argument("--path", default="/")
  parser.add_argument("--handshake-timeout", type=float, default=HANDSHAKE_TIMEOUT_DEFAULT)
  parser.add_argument("--qac-state-root", default=str(QAC_STATE_ROOT))
  parser.add_argument("--qac-lock-file", default=str(QAC_LOCK_FILE))
  parser.add_argument("--qac-enforcer-bin", default=str(QAC_ENFORCER_BIN))
  parser.add_argument("--qac-session-root", default=str(QAC_SESSION_ROOT))
  parser.add_argument("--session-scan-interval", type=float, default=0.1)
  parser.add_argument("--quota-flush-interval", type=float, default=1.0)
  return parser.parse_args()


def main():
  args = _parse_args()
  if args.handshake_timeout <= 0:
    args.handshake_timeout = HANDSHAKE_TIMEOUT_DEFAULT
  asyncio.run(_run(args))


if __name__ == "__main__":
  main()
