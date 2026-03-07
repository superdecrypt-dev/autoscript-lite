#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

TABLE_NAME = "xray_speed"
MARK_MIN = 1000
MARK_MAX = 59999


def now_iso():
  return datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M")


def run(cmd, check=True):
  return subprocess.run(
    cmd,
    check=check,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
  )


def run_input(cmd, text, check=True):
  return subprocess.run(
    cmd,
    input=text,
    text=True,
    check=check,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
  )


def detect_iface():
  p = subprocess.run(
    ["ip", "route", "show", "default", "0.0.0.0/0"],
    check=False,
    capture_output=True,
    text=True,
  )
  if p.returncode == 0:
    for line in (p.stdout or "").splitlines():
      parts = line.strip().split()
      for i, tok in enumerate(parts):
        if tok == "dev" and i + 1 < len(parts):
          return parts[i + 1]

  p2 = subprocess.run(
    ["ip", "-br", "link"],
    check=False,
    capture_output=True,
    text=True,
  )
  if p2.returncode == 0:
    for line in (p2.stdout or "").splitlines():
      cols = line.split()
      if not cols:
        continue
      if cols[0] != "lo":
        return cols[0]
  return ""


def parse_mbit(v):
  try:
    n = float(v)
  except Exception:
    return 0.0
  if n <= 0:
    return 0.0
  return round(n, 3)


def boolify(v):
  if isinstance(v, bool):
    return v
  if isinstance(v, (int, float)):
    return bool(v)
  s = str(v or "").strip().lower()
  return s in ("1", "true", "yes", "on", "y")


def load_json(path, default=None):
  try:
    with open(path, "r", encoding="utf-8") as f:
      return json.load(f)
  except Exception:
    return default


def save_json_atomic(path, data):
  os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
  tmp = f"{path}.tmp.{os.getpid()}"
  with open(tmp, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
    f.flush()
    os.fsync(f.fileno())
  os.replace(tmp, path)


def load_config(path):
  try:
    with open(path, "r", encoding="utf-8") as f:
      cfg = json.load(f)
  except FileNotFoundError:
    raise RuntimeError(f"Config xray-speed tidak ditemukan: {path}")
  except json.JSONDecodeError as e:
    raise RuntimeError(f"Config xray-speed invalid JSON di {path} (line {e.lineno}, col {e.colno}): {e.msg}")
  except Exception as e:
    raise RuntimeError(f"Gagal membaca config xray-speed {path}: {e}")

  if not isinstance(cfg, dict):
    raise RuntimeError(f"Config xray-speed harus object JSON: {path}")

  raw_default_rate = cfg.get("default_rate_mbit", 10000)
  try:
    default_rate = int(raw_default_rate)
  except Exception:
    raise RuntimeError("default_rate_mbit pada config xray-speed harus integer > 0")
  if default_rate < 1:
    raise RuntimeError("default_rate_mbit pada config xray-speed harus > 0")

  return {
    "iface": str(cfg.get("iface") or "").strip(),
    "ifb_iface": str(cfg.get("ifb_iface") or "ifb1").strip() or "ifb1",
    "policy_root": str(cfg.get("policy_root") or "/opt/speed").strip() or "/opt/speed",
    "state_file": str(cfg.get("state_file") or "/var/lib/xray-speed/state.json").strip() or "/var/lib/xray-speed/state.json",
    "default_rate_mbit": default_rate,
  }


def iter_policy_files(policy_root):
  root = Path(policy_root)
  if not root.exists():
    return
  for proto_dir in sorted(root.iterdir()):
    if not proto_dir.is_dir():
      continue
    proto = proto_dir.name
    for fp in sorted(proto_dir.glob("*.json")):
      yield proto, fp


def load_policies(policy_root):
  policies = []
  seen_mark = set()
  for proto, fp in iter_policy_files(policy_root):
    data = load_json(str(fp), default={})
    if not isinstance(data, dict):
      continue

    enabled = boolify(data.get("enabled", True))
    if not enabled:
      continue

    try:
      mark = int(data.get("mark", 0))
    except Exception:
      mark = 0
    if mark < 1000 or mark > 59999:
      continue
    if mark in seen_mark:
      continue

    up = parse_mbit(data.get("up_mbit", 0))
    down = parse_mbit(data.get("down_mbit", 0))
    if up <= 0 or down <= 0:
      continue

    user = str(data.get("username") or data.get("email") or fp.stem).strip() or fp.stem

    seen_mark.add(mark)
    policies.append({
      "proto": proto,
      "file": str(fp),
      "username": user,
      "mark": mark,
      "up_mbit": up,
      "down_mbit": down,
    })

  policies.sort(key=lambda x: (x["mark"], x["username"]))
  return policies


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
  if not resolve_cmd("nft"):
    missing.append("nft")
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


def flush_tc(iface, ifb_iface):
  run(["tc", "qdisc", "del", "dev", iface, "root"], check=False)
  run(["tc", "qdisc", "del", "dev", iface, "ingress"], check=False)
  run(["tc", "qdisc", "del", "dev", ifb_iface, "root"], check=False)


def flush_nft():
  run(["nft", "delete", "table", "inet", TABLE_NAME], check=False)


def apply_nft():
  rules = f"""table inet {TABLE_NAME} {{
  chain output {{
    type route hook output priority mangle; policy accept;
    meta mark >= {MARK_MIN} meta mark <= {MARK_MAX} ct mark set meta mark
  }}
  chain prerouting {{
    type filter hook prerouting priority mangle; policy accept;
    ct mark >= {MARK_MIN} ct mark <= {MARK_MAX} meta mark set ct mark
  }}
}}
"""
  flush_nft()
  run_input(["nft", "-f", "-"], rules, check=True)


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
  # Hindari menghapus qdisc milik sistem lain saat policy kosong.
  out_iface = qdisc_show(iface)
  out_ifb = qdisc_show(ifb_iface)
  return (
    "qdisc htb 1:" in out_iface and
    "qdisc ingress ffff:" in out_iface and
    "qdisc htb 2:" in out_ifb
  )


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

  # Download path fix:
  # Copy conntrack mark -> skb mark BEFORE mirroring ingress packets to IFB.
  # This allows fw filter on IFB (handle <mark>) to classify per-user download traffic.
  ingress_v4 = [
    "tc", "filter", "replace", "dev", iface, "parent", "ffff:", "protocol", "ip",
    "u32", "match", "u32", "0", "0"
  ]
  try:
    run(ingress_v4 + ["action", "connmark", "action", "mirred", "egress", "redirect", "dev", ifb_iface], check=True)
  except Exception:
    # Fallback for kernels without act_connmark support (keeps previous behavior).
    run(ingress_v4 + ["action", "mirred", "egress", "redirect", "dev", ifb_iface], check=True)

  ingress_v6 = [
    "tc", "filter", "replace", "dev", iface, "parent", "ffff:", "protocol", "ipv6",
    "u32", "match", "u32", "0", "0"
  ]
  try:
    run(ingress_v6 + ["action", "connmark", "action", "mirred", "egress", "redirect", "dev", ifb_iface], check=True)
  except Exception:
    run(ingress_v6 + ["action", "mirred", "egress", "redirect", "dev", ifb_iface], check=False)

  run(["tc", "qdisc", "replace", "dev", ifb_iface, "root", "handle", "2:", "htb", "default", "999"], check=True)
  run(["tc", "class", "replace", "dev", ifb_iface, "parent", "2:", "classid", "2:999", "htb", "rate", default_rate, "ceil", default_rate], check=True)
  run(["tc", "qdisc", "replace", "dev", ifb_iface, "parent", "2:999", "handle", "2999:", "fq_codel"], check=False)

  applied = []
  minor = 100
  for p in policies:
    if minor > 4094:
      break
    up = mbit_text(p["up_mbit"])
    down = mbit_text(p["down_mbit"])
    class_e = f"1:{minor}"
    class_i = f"2:{minor}"
    qh_e = f"{minor + 1000}:"
    qh_i = f"{minor + 2000}:"
    mark = str(int(p["mark"]))

    run(["tc", "class", "replace", "dev", iface, "parent", "1:", "classid", class_e, "htb", "rate", up, "ceil", up], check=True)
    run(["tc", "qdisc", "replace", "dev", iface, "parent", class_e, "handle", qh_e, "fq_codel"], check=False)
    run(["tc", "filter", "replace", "dev", iface, "parent", "1:", "protocol", "ip", "handle", mark, "fw", "flowid", class_e], check=True)
    run(["tc", "filter", "replace", "dev", iface, "parent", "1:", "protocol", "ipv6", "handle", mark, "fw", "flowid", class_e], check=False)

    run(["tc", "class", "replace", "dev", ifb_iface, "parent", "2:", "classid", class_i, "htb", "rate", down, "ceil", down], check=True)
    run(["tc", "qdisc", "replace", "dev", ifb_iface, "parent", class_i, "handle", qh_i, "fq_codel"], check=False)
    run(["tc", "filter", "replace", "dev", ifb_iface, "parent", "2:", "protocol", "ip", "handle", mark, "fw", "flowid", class_i], check=True)
    run(["tc", "filter", "replace", "dev", ifb_iface, "parent", "2:", "protocol", "ipv6", "handle", mark, "fw", "flowid", class_i], check=False)

    applied.append({
      "username": p["username"],
      "proto": p["proto"],
      "mark": p["mark"],
      "class_minor": minor,
      "up_mbit": p["up_mbit"],
      "down_mbit": p["down_mbit"],
    })
    minor += 1

  return applied


def write_state(state_file, data):
  payload = {
    "updated_at": now_iso(),
    **data,
  }
  save_json_atomic(state_file, payload)


def build_snapshot(cfg):
  iface = cfg["iface"] or detect_iface()
  if not iface:
    raise RuntimeError("Tidak bisa mendeteksi interface utama (default route).")
  policies = load_policies(cfg["policy_root"])
  snapshot = {
    "iface": iface,
    "ifb_iface": cfg["ifb_iface"],
    "default_rate_mbit": int(cfg["default_rate_mbit"]),
    "policies": policies,
  }
  raw = json.dumps(snapshot, sort_keys=True, ensure_ascii=False).encode("utf-8")
  digest = hashlib.sha256(raw).hexdigest()
  return snapshot, digest


def apply_snapshot(cfg, snapshot, dry_run=False):
  iface = snapshot["iface"]
  ifb_iface = snapshot["ifb_iface"]
  policies = snapshot["policies"]
  default_rate_mbit = snapshot["default_rate_mbit"]

  if dry_run:
    write_state(cfg["state_file"], {
      "ok": True,
      "dry_run": True,
      "iface": iface,
      "ifb_iface": ifb_iface,
      "policy_count": len(policies),
      "applied": [],
    })
    return 0

  ensure_deps()
  tc_cleanup = "none"
  if policies:
    apply_nft()
    applied = apply_tc(iface, ifb_iface, default_rate_mbit, policies)
    tc_cleanup = "managed_active"
  else:
    if tc_is_speed_managed(iface, ifb_iface):
      flush_tc(iface, ifb_iface)
      tc_cleanup = "flushed_managed"
    else:
      tc_cleanup = "skipped_foreign_tc"
    flush_nft()
    applied = []

  write_state(cfg["state_file"], {
    "ok": True,
    "dry_run": False,
    "iface": iface,
    "ifb_iface": ifb_iface,
    "policy_count": len(applied),
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
  last_digest = ""
  state_file_fallback = "/var/lib/xray-speed/state.json"
  while True:
    cfg = None
    try:
      cfg = load_config(cfg_path)
      snapshot, digest = build_snapshot(cfg)
      if digest != last_digest:
        apply_snapshot(cfg, snapshot, dry_run=False)
        last_digest = digest
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
  st = load_json(cfg["state_file"], default={}) or {}
  print(json.dumps(st, ensure_ascii=False, indent=2))
  return 0


def do_flush(cfg_path):
  cfg = load_config(cfg_path)
  iface = cfg["iface"] or detect_iface()
  if not iface:
    raise RuntimeError("Tidak bisa mendeteksi interface utama.")
  ensure_deps()
  flush_tc(iface, cfg["ifb_iface"])
  flush_nft()
  write_state(cfg["state_file"], {
    "ok": True,
    "flushed": True,
    "iface": iface,
    "ifb_iface": cfg["ifb_iface"],
  })
  return 0


def main():
  ap = argparse.ArgumentParser(prog="xray-speed")
  sub = ap.add_subparsers(dest="cmd", required=True)

  p_once = sub.add_parser("once")
  p_once.add_argument("--config", default="/etc/xray-speed/config.json")
  p_once.add_argument("--dry-run", action="store_true")

  p_watch = sub.add_parser("watch")
  p_watch.add_argument("--config", default="/etc/xray-speed/config.json")
  p_watch.add_argument("--interval", type=int, default=5)

  p_status = sub.add_parser("status")
  p_status.add_argument("--config", default="/etc/xray-speed/config.json")

  p_flush = sub.add_parser("flush")
  p_flush.add_argument("--config", default="/etc/xray-speed/config.json")

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
    print(str(exc), file=sys.stderr)
    raise SystemExit(1)
