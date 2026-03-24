#!/usr/bin/env python3
import argparse
import csv
import hashlib
import json
import os
import shutil
import subprocess
import time
import sys
from datetime import datetime, timezone
from pathlib import Path

# Add shared library path
sys.path.append("/opt/setup/lib")
try:
    import utils
except ImportError:
    # Fallback for development environment
    sys.path.append(str(Path(__file__).resolve().parents[1] / "lib"))
    import utils

EVENT_MAX_AGE_SEC = 15


def now_iso():
  return datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M")


def run(cmd, check=True):
  return subprocess.run(
    cmd,
    check=check,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
  )


def parse_mbit(v):
  try:
    n = float(v)
  except Exception:
    return 0.0
  if n <= 0:
    return 0.0
  return round(n, 3)


def load_config(path):
  cfg = utils.load_json_file(path)
  if cfg is None:
    raise RuntimeError(f"Config openvpn-speed tidak ditemukan atau invalid JSON: {path}")

  if not isinstance(cfg, dict):
    raise RuntimeError(f"Config openvpn-speed harus object JSON: {path}")

  raw_default_rate = cfg.get("default_rate_mbit", 10000)
  try:
    default_rate = int(raw_default_rate)
  except Exception:
    raise RuntimeError("default_rate_mbit pada config openvpn-speed harus integer > 0")
  if default_rate < 1:
    raise RuntimeError("default_rate_mbit pada config openvpn-speed harus > 0")

  return {
    "tun_iface": str(cfg.get("tun_iface") or "").strip(),
    "ifb_iface": str(cfg.get("ifb_iface") or "ifb2").strip() or "ifb2",
    "state_root": str(cfg.get("state_root") or "/opt/quota/ssh").strip() or "/opt/quota/ssh",
    "status_file": str(cfg.get("status_file") or "/etc/autoscript/openvpn/status-tcp.log").strip() or "/etc/autoscript/openvpn/status-tcp.log",
    "event_dir": str(cfg.get("event_dir") or "/run/openvpn-speed-events").strip() or "/run/openvpn-speed-events",
    "state_file": str(cfg.get("state_file") or "/var/lib/openvpn-speed/state.json").strip() or "/var/lib/openvpn-speed/state.json",
    "default_rate_mbit": default_rate,
  }
  if ":" in raw:
    head, _, _ = raw.partition(":")
    return utils.normalize_ip(head)
  return utils.normalize_ip(raw)


def session_key(username, real_addr, virtual_ip):
  return "|".join((str(utils.norm_user(username) or "").strip(), str(real_addr or "").strip(), str(virtual_ip or "").strip()))


def resolve_cmd(*candidates):
  for c in candidates:
    p = shutil.which(c)
    if p:
      return p
    if c.startswith("/") and os.path.isfile(c) and os.access(c, os.X_OK):
      return c
  return ""


def ensure_deps():
  missing = []
  if not resolve_cmd("ip"):
    missing.append("ip")
  if not resolve_cmd("tc"):
    missing.append("tc")
  if not resolve_cmd("modprobe", "/usr/sbin/modprobe", "/sbin/modprobe"):
    missing.append("modprobe")
  if missing:
    raise RuntimeError(f"Missing command(s): {', '.join(missing)}")


def ensure_ifb(ifb_iface):
  modprobe_cmd = resolve_cmd("modprobe", "/usr/sbin/modprobe", "/sbin/modprobe")
  if not modprobe_cmd:
    raise RuntimeError("Missing command: modprobe")
  run([modprobe_cmd, "ifb"], check=False)
  run(["ip", "link", "add", ifb_iface, "type", "ifb"], check=False)
  run(["ip", "link", "set", ifb_iface, "up"], check=True)


def detect_tun_iface():
  p = subprocess.run(
    ["ip", "-br", "link", "show", "type", "tun"],
    check=False,
    capture_output=True,
    text=True,
  )
  if p.returncode == 0:
    fallback = ""
    for line in (p.stdout or "").splitlines():
      cols = line.split()
      if not cols:
        continue
      name = cols[0]
      if not fallback:
        fallback = name
      flags = cols[-1] if cols else ""
      if "UP" in flags:
        return name
    if fallback:
      return fallback
  return "tun0"


def iter_state_files(state_root):
  root = Path(state_root)
  if not root.exists():
    return
  for fp in sorted(root.glob("*.json")):
    if fp.name.startswith("."):
      continue
    yield fp


def load_openvpn_sessions(status_file):
  sessions = {}
  status_path = Path(status_file)
  if not status_path.is_file():
    return sessions
  client_header = []
  try:
    lines = status_path.read_text(encoding="utf-8", errors="ignore").splitlines()
  except Exception:
    return sessions
  for raw_line in lines:
    try:
      row = next(csv.reader([str(raw_line or "")]))
    except Exception:
      continue
    row = [str(item or "").strip() for item in row]
    if not row:
      continue
    if row[0] == "HEADER" and len(row) >= 3 and row[1] == "CLIENT_LIST":
      client_header = row[2:]
      continue
    if row[0] != "CLIENT_LIST" or not client_header:
      continue
    values = row[1:]
    if not values:
      continue
    payload = {}
    for idx, key in enumerate(client_header):
      payload[str(key)] = values[idx] if idx < len(values) else ""
    username = utils.norm_user(payload.get("Username") or payload.get("Common Name"))
    virtual_ip = utils.normalize_ip(payload.get("Virtual Address"))
    if not username or not virtual_ip:
      continue
    real_ip = utils.normalize_real_address_ip(payload.get("Real Address"))
    item = sessions.setdefault(username, {
      "virtual_ips": [],
      "real_ips": [],
      "session_count": 0,
      "session_keys": [],
    })
    key = session_key(username, payload.get("Real Address") or real_ip, virtual_ip)
    if key and key not in item["session_keys"]:
      item["session_keys"].append(key)
    if virtual_ip not in item["virtual_ips"]:
      item["virtual_ips"].append(virtual_ip)
    if real_ip and real_ip not in item["real_ips"]:
      item["real_ips"].append(real_ip)
    item["session_count"] = int(item.get("session_count") or 0) + 1
  for item in sessions.values():
    item["session_keys"].sort()
    item["virtual_ips"].sort()
    item["real_ips"].sort()
  return sessions


def load_speed_events(event_dir):
  root = Path(event_dir)
  if not root.is_dir():
    return []
  now = int(time.time())
  latest = {}
  stale_paths = []
  for fp in sorted(root.glob("*.json")):
    try:
      payload = utils.load_json_file(str(fp), default={}) or {}
    except Exception:
      payload = {}
    if not isinstance(payload, dict):
      stale_paths.append(fp)
      continue
    event = str(payload.get("event") or "").strip().lower()
    username = utils.norm_user(payload.get("username"))
    virtual_ip = utils.normalize_ip(payload.get("virtual_ip"))
    real_addr = str(payload.get("real_addr") or "").strip()
    key = str(payload.get("session_key") or session_key(username, real_addr, virtual_ip)).strip()
    written_at = utils.to_int(payload.get("written_at"), 0)
    if event not in ("connect", "disconnect") or not username or not virtual_ip or not key:
      stale_paths.append(fp)
      continue
    if written_at <= 0 or (now - written_at) > EVENT_MAX_AGE_SEC:
      stale_paths.append(fp)
      continue
    existing = latest.get(key)
    if existing is None or written_at >= int(existing.get("written_at") or 0):
      latest[key] = {
        "event": event,
        "username": username,
        "virtual_ip": virtual_ip,
        "real_addr": real_addr,
        "real_ip": utils.normalize_real_address_ip(real_addr),
        "session_key": key,
        "written_at": written_at,
        "path": fp,
      }
  for fp in stale_paths:
    try:
      fp.unlink()
    except Exception:
      pass
  return list(latest.values())


def merge_speed_events(sessions, events):
  merged = {}
  for username, item in (sessions or {}).items():
    payload = {
      "virtual_ips": list(item.get("virtual_ips") or []),
      "real_ips": list(item.get("real_ips") or []),
      "session_count": int(item.get("session_count") or 0),
      "session_keys": list(item.get("session_keys") or []),
    }
    merged[username] = payload

  for event in events or ():
    username = utils.norm_user(event.get("username"))
    if not username:
      continue
    item = merged.setdefault(username, {
      "virtual_ips": [],
      "real_ips": [],
      "session_count": 0,
      "session_keys": [],
    })
    key = str(event.get("session_key") or "").strip()
    virtual_ip = utils.normalize_ip(event.get("virtual_ip"))
    real_ip = utils.normalize_ip(event.get("real_ip"))
    keys = set(str(v).strip() for v in item.get("session_keys") or [] if str(v).strip())
    if str(event.get("event")) == "connect":
      if key and key not in keys:
        keys.add(key)
      if virtual_ip and virtual_ip not in item["virtual_ips"]:
        item["virtual_ips"].append(virtual_ip)
      if real_ip and real_ip not in item["real_ips"]:
        item["real_ips"].append(real_ip)
    elif str(event.get("event")) == "disconnect":
      if key and key in keys:
        keys.discard(key)
      rebuilt_virtual = []
      rebuilt_real = []
      for raw_key in sorted(keys):
        parts = raw_key.split("|", 2)
        if len(parts) != 3:
          continue
        _, key_real_addr, key_virtual_ip = parts
        key_real_ip = utils.normalize_real_address_ip(key_real_addr)
        key_virtual_ip = utils.normalize_ip(key_virtual_ip)
        if key_virtual_ip and key_virtual_ip not in rebuilt_virtual:
          rebuilt_virtual.append(key_virtual_ip)
        if key_real_ip and key_real_ip not in rebuilt_real:
          rebuilt_real.append(key_real_ip)
      item["virtual_ips"] = rebuilt_virtual
      item["real_ips"] = rebuilt_real
    item["session_keys"] = sorted(keys)
    item["session_count"] = len(item["session_keys"])

  for item in merged.values():
    item["virtual_ips"] = sorted({utils.normalize_ip(v) for v in item.get("virtual_ips") or [] if utils.normalize_ip(v)})
    item["real_ips"] = sorted({utils.normalize_ip(v) for v in item.get("real_ips") or [] if utils.normalize_ip(v)})
    item["session_keys"] = sorted({str(v).strip() for v in item.get("session_keys") or [] if str(v).strip()})
    item["session_count"] = len(item["session_keys"])
  return merged


def load_policies(state_root, sessions):
  policies = []
  for fp in iter_state_files(state_root) or ():
    data = utils.load_json_file(str(fp), default={})
    if not isinstance(data, dict):
      continue
    status = data.get("status")
    if not isinstance(status, dict):
      continue
    if not utils.to_bool(status.get("speed_limit_enabled")):
      continue
    username = utils.norm_user(data.get("username") or fp.stem)
    if not username:
      continue
    session = sessions.get(username) or {}
    virtual_ips = session.get("virtual_ips")
    if not isinstance(virtual_ips, list) or not virtual_ips:
      continue
    down = parse_mbit(status.get("speed_down_mbit", 0))
    up = parse_mbit(status.get("speed_up_mbit", 0))
    if down <= 0 and up <= 0:
      continue
    policies.append({
      "username": username,
      "virtual_ips": sorted({str(ip).strip() for ip in virtual_ips if str(ip).strip()}),
      "real_ips": list(session.get("real_ips") or []),
      "session_count": int(session.get("session_count") or 0),
      "down_mbit": down,
      "up_mbit": up,
    })
  policies.sort(key=lambda item: item["username"])
  return policies


def mbit_text(v):
  n = float(v)
  if abs(n - int(n)) < 1e-9:
    return f"{int(n)}mbit"
  return f"{n:.3f}mbit"


def qdisc_show(dev):
  p = subprocess.run(
    ["tc", "qdisc", "show", "dev", dev],
    check=False,
    capture_output=True,
    text=True,
  )
  if p.returncode != 0:
    return ""
  return p.stdout or ""


def tc_is_speed_managed(iface, ifb_iface):
  out_iface = qdisc_show(iface)
  out_ifb = qdisc_show(ifb_iface)
  return (
    "qdisc htb 1:" in out_iface and
    "qdisc ingress ffff:" in out_iface and
    (
      "qdisc htb 2:" in out_ifb or
      "qdisc fq_codel 1999:" in out_iface
    )
  )


def flush_tc(iface, ifb_iface):
  run(["tc", "qdisc", "del", "dev", iface, "root"], check=False)
  run(["tc", "qdisc", "del", "dev", iface, "ingress"], check=False)
  run(["tc", "qdisc", "del", "dev", ifb_iface, "root"], check=False)


def apply_tc(iface, ifb_iface, default_rate_mbit, policies):
  if not policies:
    flush_tc(iface, ifb_iface)
    return []

  ensure_ifb(ifb_iface)
  flush_tc(iface, ifb_iface)

  default_rate = mbit_text(max(1000.0, float(default_rate_mbit)))

  run(["tc", "qdisc", "replace", "dev", iface, "root", "handle", "1:", "htb", "default", "999"], check=True)
  run(["tc", "class", "replace", "dev", iface, "parent", "1:", "classid", "1:999", "htb", "rate", default_rate, "ceil", default_rate], check=True)
  run(["tc", "qdisc", "replace", "dev", iface, "parent", "1:999", "handle", "1999:", "fq_codel"], check=False)

  run(["tc", "qdisc", "replace", "dev", iface, "handle", "ffff:", "ingress"], check=True)
  run([
    "tc", "filter", "replace", "dev", iface, "parent", "ffff:", "protocol", "ip",
    "u32", "match", "u32", "0", "0",
    "action", "mirred", "egress", "redirect", "dev", ifb_iface,
  ], check=True)

  run(["tc", "qdisc", "replace", "dev", ifb_iface, "root", "handle", "2:", "htb", "default", "999"], check=True)
  run(["tc", "class", "replace", "dev", ifb_iface, "parent", "2:", "classid", "2:999", "htb", "rate", default_rate, "ceil", default_rate], check=True)
  run(["tc", "qdisc", "replace", "dev", ifb_iface, "parent", "2:999", "handle", "2999:", "fq_codel"], check=False)

  applied = []
  minor = 100
  prio = 100
  for p in policies:
    if minor > 4094:
      break
    down = mbit_text(p["down_mbit"] if p["down_mbit"] > 0 else float(default_rate_mbit))
    up = mbit_text(p["up_mbit"] if p["up_mbit"] > 0 else float(default_rate_mbit))
    class_down = f"1:{minor}"
    class_up = f"2:{minor}"
    qh_down = f"{minor + 1000}:"
    qh_up = f"{minor + 2000}:"

    run(["tc", "class", "replace", "dev", iface, "parent", "1:", "classid", class_down, "htb", "rate", down, "ceil", down], check=True)
    run(["tc", "qdisc", "replace", "dev", iface, "parent", class_down, "handle", qh_down, "fq_codel"], check=False)
    run(["tc", "class", "replace", "dev", ifb_iface, "parent", "2:", "classid", class_up, "htb", "rate", up, "ceil", up], check=True)
    run(["tc", "qdisc", "replace", "dev", ifb_iface, "parent", class_up, "handle", qh_up, "fq_codel"], check=False)

    for ip in p["virtual_ips"]:
      run([
        "tc", "filter", "add", "dev", iface, "parent", "1:", "protocol", "ip",
        "prio", str(prio), "u32", "match", "ip", "dst", f"{ip}/32", "flowid", class_down,
      ], check=True)
      prio += 1
      run([
        "tc", "filter", "add", "dev", ifb_iface, "parent", "2:", "protocol", "ip",
        "prio", str(prio), "u32", "match", "ip", "src", f"{ip}/32", "flowid", class_up,
      ], check=True)
      prio += 1

    applied.append({
      "username": p["username"],
      "virtual_ips": p["virtual_ips"],
      "real_ips": p["real_ips"],
      "session_count": p["session_count"],
      "down_mbit": p["down_mbit"],
      "up_mbit": p["up_mbit"],
      "class_minor": minor,
    })
    minor += 1

  return applied


def write_state(state_file, data):
  payload = {
    "updated_at": now_iso(),
    **data,
  }
  utils.write_json_atomic(state_file, payload)


def build_snapshot(cfg):
  iface = cfg["tun_iface"] or detect_tun_iface()
  sessions = load_openvpn_sessions(cfg["status_file"])
  sessions = merge_speed_events(sessions, load_speed_events(cfg["event_dir"]))
  policies = load_policies(cfg["state_root"], sessions)
  snapshot = {
    "tun_iface": iface,
    "ifb_iface": cfg["ifb_iface"],
    "status_file": cfg["status_file"],
    "event_dir": cfg["event_dir"],
    "state_root": cfg["state_root"],
    "default_rate_mbit": int(cfg["default_rate_mbit"]),
    "sessions": sessions,
    "policies": policies,
  }
  signature = json.dumps(snapshot, sort_keys=True, ensure_ascii=False)
  return snapshot, signature


def apply_snapshot(cfg, snapshot, dry_run=False):
  iface = snapshot["tun_iface"]
  ifb_iface = snapshot["ifb_iface"]
  policies = snapshot["policies"]
  default_rate_mbit = snapshot["default_rate_mbit"]

  if dry_run:
    write_state(cfg["state_file"], {
      "ok": True,
      "dry_run": True,
      "tun_iface": iface,
      "ifb_iface": ifb_iface,
      "policy_count": len(policies),
      "applied": [],
    })
    return 0

  ensure_deps()
  tc_cleanup = "none"
  if policies:
    applied = apply_tc(iface, ifb_iface, default_rate_mbit, policies)
    tc_cleanup = "managed_active"
  else:
    if tc_is_speed_managed(iface, ifb_iface):
      flush_tc(iface, ifb_iface)
      tc_cleanup = "flushed_managed"
    else:
      tc_cleanup = "skipped_foreign_tc"
    applied = []

  write_state(cfg["state_file"], {
    "ok": True,
    "dry_run": False,
    "tun_iface": iface,
    "ifb_iface": ifb_iface,
    "status_file": cfg["status_file"],
    "state_root": cfg["state_root"],
    "policy_count": len(applied),
    "session_users": len(snapshot["sessions"]),
    "applied": applied,
    "tc_cleanup": tc_cleanup,
  })
  return 0


def run_once(cfg_path, dry_run=False):
  cfg = load_config(cfg_path)
  snapshot, _ = build_snapshot(cfg)
  return apply_snapshot(cfg, snapshot, dry_run=dry_run)


def run_watch(cfg_path, interval):
  sleep_s = max(2, int(interval))
  last_signature = ""
  state_file_fallback = "/var/lib/openvpn-speed/state.json"
  while True:
    cfg = None
    try:
      cfg = load_config(cfg_path)
      snapshot, signature = build_snapshot(cfg)
      if signature != last_signature:
        apply_snapshot(cfg, snapshot, dry_run=False)
        last_signature = signature
    except Exception as e:
      st_file = state_file_fallback
      if isinstance(cfg, dict):
        st_file = str(cfg.get("state_file") or state_file_fallback)
      try:
        write_state(st_file, {
          "ok": False,
          "error": str(e),
        })
      except Exception:
        pass
    time.sleep(sleep_s)


def show_status(cfg_path):
  cfg = load_config(cfg_path)
  st = utils.load_json_file(cfg["state_file"], default={}) or {}
  print(json.dumps(st, ensure_ascii=False, indent=2))
  return 0


def do_flush(cfg_path):
  cfg = load_config(cfg_path)
  iface = cfg["tun_iface"] or detect_tun_iface()
  ensure_deps()
  flush_tc(iface, cfg["ifb_iface"])
  write_state(cfg["state_file"], {
    "ok": True,
    "flushed": True,
    "tun_iface": iface,
    "ifb_iface": cfg["ifb_iface"],
  })
  return 0


def main():
  ap = argparse.ArgumentParser(prog="openvpn-speed")
  sub = ap.add_subparsers(dest="cmd", required=True)

  p_once = sub.add_parser("once")
  p_once.add_argument("--config", default="/etc/autoscript/openvpn/speed.json")
  p_once.add_argument("--dry-run", action="store_true")

  p_watch = sub.add_parser("watch")
  p_watch.add_argument("--config", default="/etc/autoscript/openvpn/speed.json")
  p_watch.add_argument("--interval", type=int, default=5)

  p_status = sub.add_parser("status")
  p_status.add_argument("--config", default="/etc/autoscript/openvpn/speed.json")

  p_flush = sub.add_parser("flush")
  p_flush.add_argument("--config", default="/etc/autoscript/openvpn/speed.json")

  args = ap.parse_args()
  if args.cmd == "once":
    return run_once(args.config, dry_run=args.dry_run)
  if args.cmd == "watch":
    return run_watch(args.config, args.interval)
  if args.cmd == "status":
    return show_status(args.config)
  if args.cmd == "flush":
    return do_flush(args.config)
  return 1


if __name__ == "__main__":
  try:
    raise SystemExit(main())
  except KeyboardInterrupt:
    raise SystemExit(0)
  except Exception as exc:
    print(f"[openvpn-speed] {exc}", file=os.sys.stderr)
    raise SystemExit(1)
