#!/usr/bin/env python3
import hashlib
import ipaddress
import json
import os
import pathlib
import time
STATE_ROOT = pathlib.Path("/run/openvpn-connect-policy")
EVENT_DIR = pathlib.Path("/run/openvpn-speed-events")


def norm_user(value):
  text = str(value or "").strip()
  if text.endswith("@ssh"):
    text = text[:-4]
  if "@" in text:
    text = text.split("@", 1)[0]
  return text


def env_str(name):
  return str(os.environ.get(name) or "").strip()


def normalize_ip(value):
  text = str(value or "").strip()
  if not text:
    return ""
  if text.startswith("[") and text.endswith("]"):
    text = text[1:-1].strip()
  try:
    return str(ipaddress.ip_address(text))
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


def write_json_atomic(path, payload):
  path.parent.mkdir(parents=True, exist_ok=True)
  tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
  try:
    tmp.write_text(json.dumps(payload, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
  finally:
    try:
      if tmp.exists():
        tmp.unlink()
    except Exception:
      pass


def session_key(username, real_addr, virtual_ip):
  return "|".join((str(norm_user(username) or "").strip(), str(real_addr or "").strip(), str(virtual_ip or "").strip()))


def write_speed_connect_event(username):
  user = norm_user(username)
  trusted_ip = normalize_ip(env_str("trusted_ip"))
  trusted_port = env_str("trusted_port")
  virtual_ip = normalize_ip(env_str("ifconfig_pool_remote_ip") or env_str("ifconfig_local"))
  if not user or not trusted_ip or not virtual_ip:
    return
  real_addr = trusted_ip if not trusted_port else f"{trusted_ip}:{trusted_port}"
  key = session_key(user, real_addr, virtual_ip)
  digest = hashlib.sha256(key.encode("utf-8", errors="ignore")).hexdigest()[:16]
  payload = {
    "event": "connect",
    "username": user,
    "real_addr": real_addr,
    "virtual_ip": virtual_ip,
    "session_key": key,
    "written_at": int(time.time()),
  }
  try:
    write_json_atomic(EVENT_DIR / f"{digest}.json", payload)
  except Exception:
    pass


def state_candidates(username):
  user = norm_user(username)
  if not user:
    return []
  return [
    STATE_ROOT / f"{user}@ssh.json",
    STATE_ROOT / f"{user}.json",
  ]


def load_state(username):
  for path in state_candidates(username):
    if not path.is_file():
      continue
    try:
      payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
      continue
    if isinstance(payload, dict):
      return payload
  return {}


def should_deny_existing(payload):
  if not isinstance(payload, dict):
    return False
  status = payload.get("status")
  if not isinstance(status, dict):
    return False
  if bool(status.get("manual_block")):
    return True
  if bool(status.get("quota_exhausted")):
    return True
  if bool(status.get("ip_limit_locked")):
    return True
  if bool(status.get("account_locked")) and str(status.get("lock_owner") or "").strip() == "ssh_qac":
    return True
  return False


def should_deny_connect(payload, connect_ip):
  if not isinstance(payload, dict):
    return False
  status = payload.get("status")
  if not isinstance(status, dict):
    return False
  if not bool(status.get("ip_limit_enabled")):
    return False
  try:
    ip_limit = int(float(status.get("ip_limit") or 0))
  except Exception:
    ip_limit = 0
  if ip_limit <= 0:
    return False
  current_all = {normalize_ip(item) for item in status.get("distinct_ips") or []}
  current_ovpn = {normalize_ip(item) for item in status.get("distinct_ips_openvpn") or []}
  current_all.discard("")
  current_ovpn.discard("")
  ssh_only_ips = current_all - current_ovpn
  combined_ips = set(ssh_only_ips) | set(current_ovpn)
  if connect_ip:
    combined_ips.add(connect_ip)
  if combined_ips:
    return len(combined_ips) > ip_limit
  try:
    active_total = int(float(status.get("active_sessions_total") or 0))
  except Exception:
    active_total = 0
  return (active_total + 1) > ip_limit


def main():
  username = norm_user(env_str("username") or env_str("common_name") or (os.sys.argv[1] if len(os.sys.argv) > 1 else ""))
  if not username:
    raise SystemExit(0)
  payload = load_state(username)
  if should_deny_existing(payload):
    raise SystemExit(1)
  connect_ip = normalize_ip(env_str("trusted_ip"))
  if should_deny_connect(payload, connect_ip):
    raise SystemExit(1)
  write_speed_connect_event(username)
  raise SystemExit(0)


if __name__ == "__main__":
  main()
