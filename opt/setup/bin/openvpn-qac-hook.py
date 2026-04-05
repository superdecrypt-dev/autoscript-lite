#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import tempfile
import time
from pathlib import Path


DEFAULT_PENDING_DIR = Path("/run/openvpn-qac-disconnect")
DEFAULT_SPEED_EVENT_DIR = Path("/run/openvpn-speed-events")


def env_str(name: str) -> str:
  return str(os.environ.get(name) or "").strip()


def env_int(name: str, default: int = 0) -> int:
  try:
    return int(float(env_str(name) or str(default)))
  except Exception:
    return int(default)


def normalize_ip(v: str) -> str:
  value = str(v or "").strip()
  if not value:
    return ""
  if value.startswith("[") and value.endswith("]"):
    value = value[1:-1].strip()
  try:
    import ipaddress
    return str(ipaddress.ip_address(value))
  except Exception:
    return ""


def normalize_username() -> str:
  for key in ("username", "common_name"):
    raw = env_str(key)
    if raw:
      return raw
  return ""


def write_json_atomic(path: Path, payload: dict[str, object]) -> None:
  path.parent.mkdir(parents=True, exist_ok=True)
  fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
  try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
      json.dump(payload, handle, ensure_ascii=True, indent=2)
      handle.write("\n")
      handle.flush()
      os.fsync(handle.fileno())
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
  finally:
    try:
      if os.path.exists(tmp):
        os.unlink(tmp)
    except Exception:
      pass


def session_key(username: str, real_addr: str, virtual_ip: str) -> str:
  return "|".join((str(username or "").strip(), str(real_addr or "").strip(), str(virtual_ip or "").strip()))


def write_speed_event(speed_event_dir: Path, username: str, real_addr: str, virtual_ip: str, event: str) -> None:
  key = session_key(username, real_addr, virtual_ip)
  digest = hashlib.sha256(key.encode("utf-8", errors="ignore")).hexdigest()[:16]
  payload = {
    "event": str(event or "").strip().lower(),
    "username": username,
    "real_addr": real_addr,
    "virtual_ip": virtual_ip,
    "session_key": key,
    "written_at": int(time.time()),
  }
  target = speed_event_dir / f"{digest}.json"
  write_json_atomic(target, payload)


def handle_disconnect(pending_dir: Path) -> int:
  username = normalize_username()
  trusted_ip = normalize_ip(env_str("trusted_ip"))
  trusted_port = env_str("trusted_port")
  virtual_ip = normalize_ip(env_str("ifconfig_pool_remote_ip") or env_str("ifconfig_local"))
  bytes_received = max(0, env_int("bytes_received", 0))
  bytes_sent = max(0, env_int("bytes_sent", 0))
  if not username or not trusted_ip or not virtual_ip:
    return 0

  real_addr = trusted_ip
  if trusted_port:
    real_addr = f"{trusted_ip}:{trusted_port}"
  key = session_key(username, real_addr, virtual_ip)
  digest = hashlib.sha256(key.encode("utf-8", errors="ignore")).hexdigest()[:16]
  stamp = int(time.time() * 1000)
  payload = {
    "username": username,
    "real_addr": real_addr,
    "virtual_ip": virtual_ip,
    "session_key": key,
    "bytes_received": bytes_received,
    "bytes_sent": bytes_sent,
    "bytes_total": int(bytes_received + bytes_sent),
    "written_at": int(time.time()),
  }
  target = pending_dir / f"{stamp}-{os.getpid()}-{digest}.json"
  write_json_atomic(target, payload)
  try:
    write_speed_event(DEFAULT_SPEED_EVENT_DIR, username, real_addr, virtual_ip, "disconnect")
  except Exception:
    pass
  return 0


def main() -> int:
  parser = argparse.ArgumentParser(description="OpenVPN QAC disconnect hook")
  parser.add_argument("event", choices=("disconnect",))
  parser.add_argument("--pending-dir", default=str(DEFAULT_PENDING_DIR))
  args = parser.parse_args()
  pending_dir = Path(args.pending_dir)
  if args.event == "disconnect":
    return handle_disconnect(pending_dir)
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
