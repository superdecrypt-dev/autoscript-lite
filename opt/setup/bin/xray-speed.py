#!/usr/bin/env python3
import argparse
import copy
import json
import os
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

_SETUP_LIB_CANDIDATES = (
    Path(os.environ.get("AUTOSCRIPT_SETUP_LIB", "")).resolve() if os.environ.get("AUTOSCRIPT_SETUP_LIB") else None,
    Path("/usr/local/lib/autoscript-setup/opt/setup/lib"),
    Path("/opt/setup/lib"),
    Path(__file__).resolve().parents[1] / "lib",
)
for _candidate in _SETUP_LIB_CANDIDATES:
    if not isinstance(_candidate, Path):
        continue
    if not _candidate.is_dir():
        continue
    _candidate_text = str(_candidate)
    if _candidate_text not in sys.path:
        sys.path.insert(0, _candidate_text)
try:
    import utils
except ImportError as exc:
    raise SystemExit(f"Gagal import setup utils: {exc}")

TABLE_NAME = "xray_speed"
MARK_MIN = 1000
MARK_MAX = 59999
SPEED_OUTBOUND_TAG_PREFIX = "speed-mark-"
SPEED_RULE_MARKER_PREFIX = "dummy-speed-user-"
HARD_BLOCK_MARKERS = {"dummy-block-user", "dummy-quota-user", "dummy-limit-user"}
DEFAULT_XRAY_OUTBOUNDS_CONF = "/usr/local/etc/xray/conf.d/20-outbounds.json"
DEFAULT_XRAY_ROUTING_CONF = "/usr/local/etc/xray/conf.d/30-routing.json"
WARP_LOOP_IFACE = "lo"
WARP_IFB_IFACE = "ifb2"
WARP_PROXY_DEFAULT_HOST = "127.0.0.1"
WARP_PROXY_DEFAULT_PORT = 40000
COMMENT_RE = re.compile(r"//.*?$|/\*.*?\*/", re.M | re.S)
XRAY_TEMPLATE_RELATIVE_DIR = ("opt", "setup", "templates", "xray-conf.d")


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
  return str(v or "").strip().lower() in ("1", "true", "yes", "on", "y")


def norm_tag(v):
  if not isinstance(v, str):
    return ""
  return v.strip()


def sanitize_tag(v):
  s = norm_tag(v)
  if not s:
    return "x"
  return re.sub(r"[^A-Za-z0-9_.-]", "-", s)


def load_json_strict(path):
  with open(path, "r", encoding="utf-8") as f:
    raw = f.read()
  return json.loads(COMMENT_RE.sub("", raw))


def load_leading_comment_lines(path):
  try:
    with open(path, "r", encoding="utf-8") as f:
      lines = f.read().splitlines()
  except Exception:
    return []
  comments = []
  for line in lines:
    stripped = line.lstrip()
    if not stripped:
      if comments:
        break
      continue
    if not stripped.startswith("//"):
      break
    comments.append(line)
  return comments


def template_comment_fallback(path):
  name = Path(path).name
  candidates = []
  env_root = os.environ.get("AUTOSCRIPT_SETUP_LIB", "").strip()
  if env_root:
    candidates.append(Path(env_root).resolve().parent / "templates" / "xray-conf.d" / name)
  candidates.append(Path("/usr/local/lib/autoscript-setup").joinpath(*XRAY_TEMPLATE_RELATIVE_DIR, name))
  candidates.append(Path("/opt/setup").joinpath("templates", "xray-conf.d", name))
  candidates.append(Path(__file__).resolve().parents[1].joinpath("templates", "xray-conf.d", name))
  for candidate in candidates:
    if candidate.is_file():
      comments = load_leading_comment_lines(str(candidate))
      if comments:
        return comments
  return []


def dump_json_atomic_with_comments(path, obj):
  comments = load_leading_comment_lines(path)
  if not comments:
    comments = template_comment_fallback(path)
  tmp = f"{path}.tmp"
  with open(tmp, "w", encoding="utf-8") as f:
    for line in comments:
      f.write(f"{line}\n")
    json.dump(obj, f, ensure_ascii=False, indent=2)
    f.write("\n")
    f.flush()
    os.fsync(f.fileno())
  os.replace(tmp, path)


def dump_json_atomic(path, obj):
  tmp = f"{path}.tmp"
  with open(tmp, "w", encoding="utf-8") as f:
    json.dump(obj, f, ensure_ascii=False, indent=2)
    f.write("\n")
    f.flush()
    os.fsync(f.fileno())
  os.replace(tmp, path)


def canonical_json(obj):
  return json.dumps(obj, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def load_config(path):
  cfg = utils.load_json_file(path)
  if cfg is None:
    raise RuntimeError(f"Config xray-speed tidak ditemukan atau invalid JSON: {path}")

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
    "xray_outbounds_conf": str(cfg.get("xray_outbounds_conf") or DEFAULT_XRAY_OUTBOUNDS_CONF).strip() or DEFAULT_XRAY_OUTBOUNDS_CONF,
    "xray_routing_conf": str(cfg.get("xray_routing_conf") or DEFAULT_XRAY_ROUTING_CONF).strip() or DEFAULT_XRAY_ROUTING_CONF,
  }


def load_json_or_default(path, default):
  data = utils.load_json_file(path)
  if data is None:
    return default
  return data


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
    data = load_json_or_default(str(fp), {})
    if not isinstance(data, dict):
      continue

    enabled = utils.to_bool(data.get("enabled", True))
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


def mark_users_from_policies(policies):
  mark_users = {}
  for policy in policies:
    try:
      mark = int(policy.get("mark", 0))
    except Exception:
      continue
    if mark < MARK_MIN or mark > MARK_MAX:
      continue
    user = str(policy.get("username") or "").strip()
    if not user:
      continue
    mark_users.setdefault(mark, set()).add(user)
  return {mark: sorted(users) for mark, users in sorted(mark_users.items())}


def is_default_rule(rule):
  if not isinstance(rule, dict):
    return False
  if rule.get("type") != "field":
    return False
  port = str(rule.get("port", "")).strip()
  if port not in ("1-65535", "0-65535"):
    return False
  if rule.get("user") or rule.get("domain") or rule.get("ip") or rule.get("protocol"):
    return False
  return True


def is_protected_rule(rule):
  if not isinstance(rule, dict):
    return False
  if rule.get("type") != "field":
    return False
  return norm_tag(rule.get("outboundTag")) in ("api", "blocked")


def is_hard_block_user_rule(rule):
  if not isinstance(rule, dict):
    return False
  if rule.get("type") != "field":
    return False
  if norm_tag(rule.get("outboundTag")) != "blocked":
    return False
  users = rule.get("user")
  if not isinstance(users, list):
    return False
  return any(isinstance(user, str) and user in HARD_BLOCK_MARKERS for user in users)


def load_speed_warp_marks(cfg):
  rt_path = str(cfg.get("xray_routing_conf") or "").strip()
  if not rt_path or not os.path.isfile(rt_path):
    return set()
  try:
    rt_cfg = load_json_strict(rt_path)
  except Exception:
    return set()

  routing = rt_cfg.get("routing") or {}
  rules = routing.get("rules")
  if not isinstance(rules, list):
    return set()

  marks = set()
  for rule in rules:
    if not isinstance(rule, dict):
      continue
    if rule.get("type") != "field":
      continue
    users = rule.get("user")
    if not isinstance(users, list):
      continue
    for user in users:
      if not isinstance(user, str):
        continue
      matched = re.fullmatch(rf"{re.escape(SPEED_RULE_MARKER_PREFIX)}(\d+)-warp", user.strip())
      if not matched:
        continue
      try:
        mark = int(matched.group(1))
      except Exception:
        continue
      if MARK_MIN <= mark <= MARK_MAX:
        marks.add(mark)
  return marks


def detect_warp_proxy_bind(cfg):
  out_path = str(cfg.get("xray_outbounds_conf") or "").strip()
  if not out_path or not os.path.isfile(out_path):
    return WARP_PROXY_DEFAULT_HOST, WARP_PROXY_DEFAULT_PORT
  try:
    out_cfg = load_json_strict(out_path)
  except Exception:
    return WARP_PROXY_DEFAULT_HOST, WARP_PROXY_DEFAULT_PORT

  outbounds = out_cfg.get("outbounds")
  if not isinstance(outbounds, list):
    return WARP_PROXY_DEFAULT_HOST, WARP_PROXY_DEFAULT_PORT

  for outbound in outbounds:
    if not isinstance(outbound, dict):
      continue
    if norm_tag(outbound.get("tag")) != "warp":
      continue
    if norm_tag(outbound.get("protocol")) != "socks":
      continue
    settings = outbound.get("settings") or {}
    servers = settings.get("servers")
    if not isinstance(servers, list) or not servers:
      break
    server = servers[0] or {}
    host = str(server.get("address") or WARP_PROXY_DEFAULT_HOST).strip() or WARP_PROXY_DEFAULT_HOST
    try:
      port = int(server.get("port") or WARP_PROXY_DEFAULT_PORT)
    except Exception:
      port = WARP_PROXY_DEFAULT_PORT
    if port < 1 or port > 65535:
      port = WARP_PROXY_DEFAULT_PORT
    return host, port

  return WARP_PROXY_DEFAULT_HOST, WARP_PROXY_DEFAULT_PORT


def is_loopback_host(host):
  host_n = str(host or "").strip().lower()
  return host_n in {"127.0.0.1", "localhost", "::1"}


def build_synced_xray_configs(out_cfg, rt_cfg, policies):
  outbounds = out_cfg.get("outbounds")
  if not isinstance(outbounds, list):
    raise RuntimeError("Invalid outbounds config: outbounds bukan list")

  routing = rt_cfg.get("routing") or {}
  rules = routing.get("rules")
  if not isinstance(rules, list):
    raise RuntimeError("Invalid routing config: routing.rules bukan list")

  mark_users = mark_users_from_policies(policies)
  outbounds_by_tag = {}
  for outbound in outbounds:
    if not isinstance(outbound, dict):
      continue
    tag = norm_tag(outbound.get("tag"))
    if tag:
      outbounds_by_tag[tag] = outbound

  default_rule = None
  for rule in rules:
    if is_default_rule(rule):
      default_rule = rule
      break

  base_selector = []
  if isinstance(default_rule, dict):
    outbound_tag = norm_tag(default_rule.get("outboundTag"))
    if outbound_tag:
      base_selector = [outbound_tag]

  if not base_selector:
    if "direct" in outbounds_by_tag:
      base_selector = ["direct"]
    else:
      for tag in outbounds_by_tag.keys():
        if not tag.startswith(SPEED_OUTBOUND_TAG_PREFIX):
          base_selector = [tag]
          break

  if not base_selector:
    raise RuntimeError("Outbound dasar untuk speed policy tidak ditemukan")

  effective_selector = []
  seen = set()
  for tag in base_selector:
    normed = norm_tag(tag)
    if not normed:
      continue
    if normed in ("api", "blocked"):
      continue
    if normed.startswith(SPEED_OUTBOUND_TAG_PREFIX):
      continue
    if normed not in outbounds_by_tag:
      continue
    if normed in seen:
      continue
    seen.add(normed)
    effective_selector.append(normed)

  if not effective_selector:
    if "direct" in outbounds_by_tag:
      effective_selector = ["direct"]
    else:
      for tag in outbounds_by_tag.keys():
        normed = norm_tag(tag)
        if not normed:
          continue
        if normed in ("api", "blocked"):
          continue
        if normed.startswith(SPEED_OUTBOUND_TAG_PREFIX):
          continue
        effective_selector = [normed]
        break

  if not effective_selector:
    raise RuntimeError("Selector outbound dasar untuk speed policy kosong")

  def managed_user_override_set(marker, outbound):
    result = set()
    for rule in rules:
      if not isinstance(rule, dict):
        continue
      if rule.get("type") != "field":
        continue
      if norm_tag(rule.get("outboundTag")) != outbound:
        continue
      users = rule.get("user")
      if not isinstance(users, list) or "inboundTag" in rule:
        continue
      if marker not in users:
        continue
      for user in users:
        if not isinstance(user, str):
          continue
        user = user.strip()
        if not user or user == marker:
          continue
        result.add(user)
    return result

  selector_candidates = []
  seen = set()
  for tag in list(effective_selector) + ["direct", "warp"]:
    normed = norm_tag(tag)
    if not normed:
      continue
    if normed in ("api", "blocked"):
      continue
    if normed.startswith(SPEED_OUTBOUND_TAG_PREFIX):
      continue
    if normed not in outbounds_by_tag:
      continue
    if normed in seen:
      continue
    seen.add(normed)
    selector_candidates.append(normed)

  if not selector_candidates:
    raise RuntimeError("Selector outbound kandidat speed policy kosong")

  direct_users = managed_user_override_set("dummy-direct-user", "direct")
  warp_users = managed_user_override_set("dummy-warp-user", "warp")

  def resolve_speed_base_tag(user):
    if user in direct_users:
      return "direct"
    if user in warp_users:
      return "warp"
    first_base = effective_selector[0] if effective_selector else ""
    return first_base or (selector_candidates[0] if selector_candidates else "")

  clean_outbounds = []
  for outbound in outbounds:
    if isinstance(outbound, dict):
      tag = norm_tag(outbound.get("tag"))
      if tag.startswith(SPEED_OUTBOUND_TAG_PREFIX):
        continue
    clean_outbounds.append(outbound)

  mark_out_tags = {}
  for mark in sorted(mark_users.keys()):
    per_mark = {}
    for base_tag in selector_candidates:
      src = outbounds_by_tag.get(base_tag)
      if not isinstance(src, dict):
        continue
      clone = copy.deepcopy(src)
      clone_tag = f"{SPEED_OUTBOUND_TAG_PREFIX}{mark}-{sanitize_tag(base_tag)}"
      clone["tag"] = clone_tag
      stream_settings = clone.get("streamSettings")
      if not isinstance(stream_settings, dict):
        stream_settings = {}
      sockopt = stream_settings.get("sockopt")
      if not isinstance(sockopt, dict):
        sockopt = {}
      sockopt["mark"] = int(mark)
      stream_settings["sockopt"] = sockopt
      clone["streamSettings"] = stream_settings
      clean_outbounds.append(clone)
      per_mark[base_tag] = clone_tag
    mark_out_tags[mark] = per_mark

  kept_rules = []
  for rule in rules:
    if not isinstance(rule, dict):
      kept_rules.append(rule)
      continue
    if rule.get("type") != "field":
      kept_rules.append(rule)
      continue
    users = rule.get("user")
    outbound_tag = norm_tag(rule.get("outboundTag"))
    has_speed_marker = isinstance(users, list) and any(
      isinstance(user, str) and user.startswith(SPEED_RULE_MARKER_PREFIX) for user in users
    )
    if has_speed_marker and outbound_tag.startswith(SPEED_OUTBOUND_TAG_PREFIX):
      continue
    kept_rules.append(rule)

  speed_rules = []
  for mark, users in sorted(mark_users.items()):
    grouped = {}
    for user in users:
      base_tag = resolve_speed_base_tag(user)
      if not base_tag:
        continue
      outbound_tag = mark_out_tags.get(mark, {}).get(base_tag, "")
      if not outbound_tag:
        continue
      grouped.setdefault(base_tag, []).append(user)
    for base_tag, grouped_users in sorted(grouped.items()):
      outbound_tag = mark_out_tags.get(mark, {}).get(base_tag, "")
      if not outbound_tag:
        continue
      speed_rules.append({
        "type": "field",
        "user": [f"{SPEED_RULE_MARKER_PREFIX}{mark}-{sanitize_tag(base_tag)}"] + grouped_users,
        "outboundTag": outbound_tag,
      })

  prefix_rules = []
  hard_block_rules = []
  other_rules = []
  for rule in kept_rules:
    if is_protected_rule(rule) and not is_hard_block_user_rule(rule):
      prefix_rules.append(rule)
    elif is_hard_block_user_rule(rule):
      hard_block_rules.append(rule)
    else:
      other_rules.append(rule)

  next_out_cfg = copy.deepcopy(out_cfg)
  next_out_cfg["outbounds"] = clean_outbounds

  next_rt_cfg = copy.deepcopy(rt_cfg)
  routing_copy = next_rt_cfg.get("routing") or {}
  routing_copy["rules"] = prefix_rules + hard_block_rules + speed_rules + other_rules
  next_rt_cfg["routing"] = routing_copy
  return next_out_cfg, next_rt_cfg


def sync_xray_speed_config(cfg, policies):
  out_path = str(cfg.get("xray_outbounds_conf") or "").strip()
  rt_path = str(cfg.get("xray_routing_conf") or "").strip()
  if not out_path or not rt_path:
    return False
  if not os.path.isfile(out_path) or not os.path.isfile(rt_path):
    return False

  out_cfg = load_json_strict(out_path)
  rt_cfg = load_json_strict(rt_path)
  next_out_cfg, next_rt_cfg = build_synced_xray_configs(out_cfg, rt_cfg, policies)

  current_sig = canonical_json(out_cfg) + "\n" + canonical_json(rt_cfg)
  next_sig = canonical_json(next_out_cfg) + "\n" + canonical_json(next_rt_cfg)
  if current_sig == next_sig:
    return False

  dump_json_atomic_with_comments(out_path, next_out_cfg)
  dump_json_atomic_with_comments(rt_path, next_rt_cfg)
  run(["systemctl", "restart", "xray"], check=True)
  return True


def xray_sync_state_signature(cfg, policies):
  out_path = str(cfg.get("xray_outbounds_conf") or "").strip()
  rt_path = str(cfg.get("xray_routing_conf") or "").strip()
  if not out_path or not rt_path:
    return "disabled"
  if not os.path.isfile(out_path) or not os.path.isfile(rt_path):
    return "missing"
  try:
    out_cfg = load_json_strict(out_path)
    rt_cfg = load_json_strict(rt_path)
    next_out_cfg, next_rt_cfg = build_synced_xray_configs(out_cfg, rt_cfg, policies)
  except Exception as exc:
    return f"error:{exc}"
  current_sig = canonical_json(out_cfg) + "\n" + canonical_json(rt_cfg)
  next_sig = canonical_json(next_out_cfg) + "\n" + canonical_json(next_rt_cfg)
  return "in-sync" if current_sig == next_sig else "drifted"


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


def tc_is_warp_loop_managed(loop_iface, ifb_iface):
  out_loop = qdisc_show(loop_iface)
  out_ifb = qdisc_show(ifb_iface)
  return (
    "qdisc htb 3:" in out_loop and
    "qdisc ingress ffff:" in out_loop and
    "qdisc htb 4:" in out_ifb
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


def flush_tc_warp_loop(loop_iface, ifb_iface):
  run(["tc", "qdisc", "del", "dev", loop_iface, "root"], check=False)
  run(["tc", "qdisc", "del", "dev", loop_iface, "ingress"], check=False)
  run(["tc", "qdisc", "del", "dev", ifb_iface, "root"], check=False)


def apply_tc_warp_loop(loop_iface, ifb_iface, proxy_host, proxy_port, default_rate_mbit, policies):
  if not policies or not is_loopback_host(proxy_host) or int(proxy_port) < 1:
    flush_tc_warp_loop(loop_iface, ifb_iface)
    return []

  ensure_ifb(ifb_iface)
  flush_tc_warp_loop(loop_iface, ifb_iface)

  default_rate = mbit_text(max(1000.0, float(default_rate_mbit)))
  proxy_host = "127.0.0.1"
  proxy_port = str(int(proxy_port))

  run(["tc", "qdisc", "replace", "dev", loop_iface, "root", "handle", "3:", "htb", "default", "999"], check=True)
  run(["tc", "class", "replace", "dev", loop_iface, "parent", "3:", "classid", "3:999", "htb", "rate", default_rate, "ceil", default_rate], check=True)
  run(["tc", "qdisc", "replace", "dev", loop_iface, "parent", "3:999", "handle", "3999:", "fq_codel"], check=False)
  run(["tc", "qdisc", "replace", "dev", loop_iface, "handle", "ffff:", "ingress"], check=True)

  ingress = [
    "tc", "filter", "replace", "dev", loop_iface, "parent", "ffff:", "protocol", "ip", "prio", "10",
    "u32", "match", "ip", "src", f"{proxy_host}/32",
    "match", "ip", "protocol", "6", "0xff",
    "match", "ip", "sport", proxy_port, "0xffff",
  ]
  try:
    run(ingress + ["action", "connmark", "action", "mirred", "egress", "redirect", "dev", ifb_iface], check=True)
  except Exception:
    run(ingress + ["action", "mirred", "egress", "redirect", "dev", ifb_iface], check=True)

  run(["tc", "qdisc", "replace", "dev", ifb_iface, "root", "handle", "4:", "htb", "default", "999"], check=True)
  run(["tc", "class", "replace", "dev", ifb_iface, "parent", "4:", "classid", "4:999", "htb", "rate", default_rate, "ceil", default_rate], check=True)
  run(["tc", "qdisc", "replace", "dev", ifb_iface, "parent", "4:999", "handle", "4999:", "fq_codel"], check=False)

  applied = []
  minor = 100
  for p in policies:
    if minor > 4094:
      break
    up = mbit_text(p["up_mbit"])
    down = mbit_text(p["down_mbit"])
    class_up = f"3:{minor}"
    class_down = f"4:{minor}"
    qh_up = f"{minor + 3000}:"
    qh_down = f"{minor + 4000}:"
    mark_hex = hex(int(p["mark"]))

    run(["tc", "class", "replace", "dev", loop_iface, "parent", "3:", "classid", class_up, "htb", "rate", up, "ceil", up], check=True)
    run(["tc", "qdisc", "replace", "dev", loop_iface, "parent", class_up, "handle", qh_up, "fq_codel"], check=False)
    run([
      "tc", "filter", "replace", "dev", loop_iface, "parent", "3:", "protocol", "ip", "prio", "20",
      "u32", "match", "ip", "dst", f"{proxy_host}/32",
      "match", "ip", "protocol", "6", "0xff",
      "match", "ip", "dport", proxy_port, "0xffff",
      "match", "mark", mark_hex, "0xffffffff",
      "flowid", class_up,
    ], check=True)

    run(["tc", "class", "replace", "dev", ifb_iface, "parent", "4:", "classid", class_down, "htb", "rate", down, "ceil", down], check=True)
    run(["tc", "qdisc", "replace", "dev", ifb_iface, "parent", class_down, "handle", qh_down, "fq_codel"], check=False)
    run(["tc", "filter", "replace", "dev", ifb_iface, "parent", "4:", "protocol", "ip", "handle", str(int(p["mark"])), "fw", "flowid", class_down], check=True)

    applied.append({
      "username": p["username"],
      "proto": p["proto"],
      "mark": p["mark"],
      "class_minor": minor,
      "up_mbit": p["up_mbit"],
      "down_mbit": p["down_mbit"],
      "path": "warp-loop",
      "proxy": f"{proxy_host}:{proxy_port}",
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
  signature = raw.decode("utf-8")
  return snapshot, signature


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
  xray_config_synced = False
  if policies:
    xray_config_synced = sync_xray_speed_config(cfg, policies)
  else:
    xray_config_synced = sync_xray_speed_config(cfg, [])
  warp_marks = load_speed_warp_marks(cfg) if policies else set()
  direct_policies = [policy for policy in policies if int(policy.get("mark", 0)) not in warp_marks]
  warp_policies = [policy for policy in policies if int(policy.get("mark", 0)) in warp_marks]
  warp_proxy_host, warp_proxy_port = detect_warp_proxy_bind(cfg)
  tc_cleanup = "none"
  warp_tc_cleanup = "none"
  if policies:
    apply_nft()
    if direct_policies:
      applied = apply_tc(iface, ifb_iface, default_rate_mbit, direct_policies)
      tc_cleanup = "managed_active"
    else:
      if tc_is_speed_managed(iface, ifb_iface):
        flush_tc(iface, ifb_iface)
        tc_cleanup = "flushed_managed"
      else:
        tc_cleanup = "skipped_foreign_tc"
      applied = []

    if warp_policies and is_loopback_host(warp_proxy_host):
      warp_applied = apply_tc_warp_loop(WARP_LOOP_IFACE, WARP_IFB_IFACE, warp_proxy_host, warp_proxy_port, default_rate_mbit, warp_policies)
      warp_tc_cleanup = "managed_active"
    else:
      if tc_is_warp_loop_managed(WARP_LOOP_IFACE, WARP_IFB_IFACE):
        flush_tc_warp_loop(WARP_LOOP_IFACE, WARP_IFB_IFACE)
        warp_tc_cleanup = "flushed_managed"
      else:
        warp_tc_cleanup = "none"
      warp_applied = []
  else:
    if tc_is_speed_managed(iface, ifb_iface):
      flush_tc(iface, ifb_iface)
      tc_cleanup = "flushed_managed"
    else:
      tc_cleanup = "skipped_foreign_tc"
    if tc_is_warp_loop_managed(WARP_LOOP_IFACE, WARP_IFB_IFACE):
      flush_tc_warp_loop(WARP_LOOP_IFACE, WARP_IFB_IFACE)
      warp_tc_cleanup = "flushed_managed"
    else:
      warp_tc_cleanup = "skipped_foreign_tc"
    flush_nft()
    applied = []
    warp_applied = []

  write_state(cfg["state_file"], {
    "ok": True,
    "dry_run": False,
    "iface": iface,
    "ifb_iface": ifb_iface,
    "policy_count": len(applied) + len(warp_applied),
    "applied": applied,
    "warp_applied": warp_applied,
    "warp_policy_count": len(warp_applied),
    "warp_marks": sorted(warp_marks),
    "warp_proxy": f"{warp_proxy_host}:{warp_proxy_port}" if warp_policies else "",
    "tc_cleanup": tc_cleanup,
    "warp_tc_cleanup": warp_tc_cleanup,
    "xray_config_sync": "updated" if xray_config_synced else "unchanged",
  })
  return 0


def run_once(cfg_path, dry_run=False):
  cfg = load_config(cfg_path)
  snapshot, _ = build_snapshot(cfg)
  return apply_snapshot(cfg, snapshot, dry_run=dry_run)


def run_watch(cfg_path, interval):
  sleep_s = max(2, int(interval))
  last_signature = ""
  state_file_fallback = "/var/lib/xray-speed/state.json"
  while True:
    cfg = None
    try:
      cfg = load_config(cfg_path)
      snapshot, signature = build_snapshot(cfg)
      runtime_signature = signature + "|" + xray_sync_state_signature(cfg, snapshot["policies"])
      if runtime_signature != last_signature:
        apply_snapshot(cfg, snapshot, dry_run=False)
        last_signature = runtime_signature
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
  st = load_json_or_default(cfg["state_file"], {}) or {}
  print(json.dumps(st, ensure_ascii=False, indent=2))
  return 0


def do_flush(cfg_path):
  cfg = load_config(cfg_path)
  iface = cfg["iface"] or detect_iface()
  if not iface:
    raise RuntimeError("Tidak bisa mendeteksi interface utama.")
  ensure_deps()
  flush_tc(iface, cfg["ifb_iface"])
  flush_tc_warp_loop(WARP_LOOP_IFACE, WARP_IFB_IFACE)
  flush_nft()
  write_state(cfg["state_file"], {
    "ok": True,
    "flushed": True,
    "iface": iface,
    "ifb_iface": cfg["ifb_iface"],
    "warp_loop_iface": WARP_LOOP_IFACE,
    "warp_ifb_iface": WARP_IFB_IFACE,
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
