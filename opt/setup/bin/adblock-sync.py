#!/usr/bin/env python3
import argparse
import datetime
import json
import os
import pathlib
import pwd
import re
import subprocess
import sys
import tempfile

DEFAULT_ENV_FILE = pathlib.Path("/etc/autoscript/ssh-adblock/config.env")
DEFAULT_STATE_ROOT = pathlib.Path("/opt/quota/ssh")
DEFAULT_BLOCKLIST_FILE = pathlib.Path("/etc/autoscript/ssh-adblock/blocked.domains")
DEFAULT_URLS_FILE = pathlib.Path("/etc/autoscript/ssh-adblock/source.urls")
DEFAULT_MERGED_FILE = pathlib.Path("/etc/autoscript/ssh-adblock/merged.domains")
DEFAULT_RENDERED_FILE = pathlib.Path("/etc/autoscript/ssh-adblock/blocklist.generated.conf")
DEFAULT_CUSTOM_DAT = pathlib.Path("/usr/local/share/xray/custom.dat")
DEFAULT_XRAY_ROUTING_FILE = pathlib.Path("/usr/local/etc/xray/conf.d/30-routing.json")
DEFAULT_XRAY_ADBLOCK_ENTRY = "ext:custom.dat:adblock"
DEFAULT_NFT_TABLE = "autoscript_ssh_adblock"
DEFAULT_DNS_PORT = 5353
DEFAULT_DNS_SERVICE = "ssh-adblock-dns.service"
DEFAULT_SYNC_SERVICE = "adblock-sync.service"
DEFAULT_XRAY_SERVICE = "xray"
ADBLOCK_DIRTY_KEY = "AUTOSCRIPT_ADBLOCK_DIRTY"
ADBLOCK_LAST_UPDATE_KEY = "AUTOSCRIPT_ADBLOCK_LAST_UPDATE"
ADBLOCK_MERGED_FILE_KEY = "AUTOSCRIPT_ADBLOCK_MERGED_FILE"
ADBLOCK_CUSTOM_DAT_KEY = "AUTOSCRIPT_ADBLOCK_CUSTOM_DAT"
ADBLOCK_XRAY_SERVICE_KEY = "AUTOSCRIPT_ADBLOCK_XRAY_SERVICE"
ADBLOCK_AUTO_UPDATE_ENABLED_KEY = "AUTOSCRIPT_ADBLOCK_AUTO_UPDATE_ENABLED"
ADBLOCK_AUTO_UPDATE_SERVICE_KEY = "AUTOSCRIPT_ADBLOCK_AUTO_UPDATE_SERVICE"
ADBLOCK_AUTO_UPDATE_TIMER_KEY = "AUTOSCRIPT_ADBLOCK_AUTO_UPDATE_TIMER"
ADBLOCK_AUTO_UPDATE_DAYS_KEY = "AUTOSCRIPT_ADBLOCK_AUTO_UPDATE_DAYS"
SSH_USER_RE = re.compile(r"^([a-z_][a-z0-9_-]{0,31})@ssh\.json$")


def parse_args():
  parser = argparse.ArgumentParser(description="Sync shared Adblock runtime for SSH + Xray")
  parser.add_argument("--apply", action="store_true", help="Apply current runtime state")
  parser.add_argument("--update", action="store_true", help="Refresh sources, rebuild artifacts, and apply runtime state")
  parser.add_argument("--reload-xray", action="store_true", help="Reload xray service when custom.dat changes")
  parser.add_argument(
    "--reload-xray-if-enabled",
    action="store_true",
    help="Reload xray only when the Xray adblock rule is currently enabled",
  )
  parser.add_argument("--status", action="store_true", help="Print runtime status")
  parser.add_argument("--show-users", action="store_true", help="Print bound SSH users")
  parser.add_argument("--env-file", default=str(DEFAULT_ENV_FILE))
  return parser.parse_args()


def parse_env_file(path):
  data = {}
  try:
    text = pathlib.Path(path).read_text(encoding="utf-8")
  except Exception:
    return data
  for line in text.splitlines():
    line = line.strip()
    if not line or line.startswith("#") or "=" not in line:
      continue
    key, value = line.split("=", 1)
    data[key.strip()] = value.strip()
  return data


def to_bool(value):
  return str(value or "").strip().lower() in ("1", "true", "yes", "on", "y")


def to_int(value, default):
  try:
    return int(str(value).strip())
  except Exception:
    return int(default)


def service_state(name):
  if not name:
    return "missing"
  try:
    rc = subprocess.run(
      ["systemctl", "is-active", name],
      stdout=subprocess.DEVNULL,
      stderr=subprocess.DEVNULL,
      check=False,
    ).returncode
  except Exception:
    return "missing"
  if rc == 0:
    return "active"
  return "inactive"


def service_start(name):
  if not name:
    return False
  try:
    rc = subprocess.run(
      ["systemctl", "start", name],
      stdout=subprocess.DEVNULL,
      stderr=subprocess.DEVNULL,
      check=False,
    ).returncode
  except Exception:
    return False
  return rc == 0


def service_restart(name):
  if not name:
    return False
  try:
    rc = subprocess.run(
      ["systemctl", "restart", name],
      stdout=subprocess.DEVNULL,
      stderr=subprocess.DEVNULL,
      check=False,
    ).returncode
  except Exception:
    return False
  return rc == 0


def table_exists(table_name):
  try:
    rc = subprocess.run(
      ["nft", "list", "table", "inet", table_name],
      stdout=subprocess.DEVNULL,
      stderr=subprocess.DEVNULL,
      check=False,
    ).returncode
  except Exception:
    return False
  return rc == 0


def list_managed_users(state_root):
  root = pathlib.Path(state_root)
  users = []
  seen_uids = set()
  if not root.is_dir():
    return users
  for path in sorted(root.glob("*@ssh.json")):
    match = SSH_USER_RE.match(path.name)
    if not match:
      continue
    username = match.group(1)
    try:
      pw = pwd.getpwnam(username)
    except KeyError:
      continue
    if pw.pw_uid <= 0 or pw.pw_uid in seen_uids:
      continue
    seen_uids.add(pw.pw_uid)
    users.append((username, pw.pw_uid))
  return users


def normalize_domain(value):
  domain = str(value or "").strip().lower().rstrip(".")
  if not domain or domain.startswith("#") or " " in domain or "/" in domain:
    return ""
  if "." not in domain or ".." in domain:
    return ""
  return domain


def normalize_blocklist_line(value):
  raw = str(value or "").strip()
  if not raw:
    return ""
  if raw.startswith(("!", "[", "@@")):
    return ""

  line = raw.split("#", 1)[0].strip()
  if not line:
    return ""

  hosts_parts = line.split()
  if len(hosts_parts) >= 2 and hosts_parts[0] in ("0.0.0.0", "127.0.0.1", "::", "::1"):
    return normalize_domain(hosts_parts[1])

  if line.startswith("||"):
    line = line[2:]
  elif line.startswith("|"):
    line = line[1:]

  if line.startswith(("http://", "https://")):
    try:
      line = line.split("://", 1)[1]
    except Exception:
      return ""

  if "/" in line:
    line = line.split("/", 1)[0]

  if "^" in line:
    line = line.split("^", 1)[0]

  if ":" in line and not line.startswith("["):
    line = line.split(":", 1)[0]

  return normalize_domain(line)


def read_domains_from_text(text):
  domains = []
  seen = set()
  lines = str(text or "").splitlines()
  for line in lines:
    domain = normalize_blocklist_line(line)
    if not domain or domain in seen:
      continue
    seen.add(domain)
    domains.append(domain)
  return domains


def read_blocklist(path):
  try:
    text = pathlib.Path(path).read_text(encoding="utf-8")
  except Exception:
    return []
  return read_domains_from_text(text)


def read_merged_domains(path):
  domains = []
  seen = set()
  try:
    lines = pathlib.Path(path).read_text(encoding="utf-8").splitlines()
  except Exception:
    return domains
  for line in lines:
    domain = normalize_domain(line)
    if not domain or domain in seen:
      continue
    seen.add(domain)
    domains.append(domain)
  return domains


def read_rendered_blocklist(path):
  domains = []
  seen = set()
  try:
    lines = pathlib.Path(path).read_text(encoding="utf-8").splitlines()
  except Exception:
    return domains
  for line in lines:
    raw = str(line or "").strip()
    if not raw or raw.startswith("#"):
      continue
    if not raw.startswith("address=/"):
      continue
    try:
      domain = raw.split("/", 3)[1]
    except Exception:
      continue
    domain = normalize_domain(domain)
    if not domain or domain in seen:
      continue
    seen.add(domain)
    domains.append(domain)
  return domains


def read_urls_file(path):
  urls = []
  seen = set()
  try:
    lines = pathlib.Path(path).read_text(encoding="utf-8").splitlines()
  except Exception:
    return urls
  for line in lines:
    line = str(line or "").strip()
    if not line or line.startswith("#"):
      continue
    if not line.startswith(("http://", "https://")):
      continue
    if line in seen:
      continue
    seen.add(line)
    urls.append(line)
  return urls


def fetch_url_text(url):
  try:
    res = subprocess.run(
      ["curl", "-fsSL", "--connect-timeout", "10", "--max-time", "45", url],
      capture_output=True,
      text=True,
      check=False,
    )
  except Exception:
    return False, ""
  if res.returncode != 0:
    return False, ""
  return True, res.stdout or ""


def build_blocklist(cfg):
  merged = []
  seen = set()
  failed_urls = []

  def add_many(items):
    for item in items:
      if not item or item in seen:
        continue
      seen.add(item)
      merged.append(item)

  add_many(read_blocklist(cfg["blocklist_file"]))
  for url in cfg["source_urls"]:
    ok, text = fetch_url_text(url)
    if not ok:
      failed_urls.append(url)
      continue
    add_many(read_domains_from_text(text))
  return merged, failed_urls


def write_atomic(path, text, mode=0o644):
  target = pathlib.Path(path)
  new_bytes = text.encode("utf-8")
  try:
    if target.read_bytes() == new_bytes:
      return False
  except Exception:
    pass
  target.parent.mkdir(parents=True, exist_ok=True)
  fd, tmp = tempfile.mkstemp(prefix=".tmp.", suffix=".conf", dir=str(target.parent))
  try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
      handle.write(text)
      handle.flush()
      os.fsync(handle.fileno())
    os.chmod(tmp, mode)
    os.replace(tmp, target)
  finally:
    try:
      if os.path.exists(tmp):
        os.remove(tmp)
    except Exception:
      pass
  return True


def write_atomic_bytes(path, data, mode=0o644):
  target = pathlib.Path(path)
  try:
    if target.read_bytes() == data:
      return False
  except Exception:
    pass
  target.parent.mkdir(parents=True, exist_ok=True)
  fd, tmp = tempfile.mkstemp(prefix=".tmp.", suffix=".dat", dir=str(target.parent))
  try:
    with os.fdopen(fd, "wb") as handle:
      handle.write(data)
      handle.flush()
      os.fsync(handle.fileno())
    os.chmod(tmp, mode)
    os.replace(tmp, target)
  finally:
    try:
      if os.path.exists(tmp):
        os.remove(tmp)
    except Exception:
      pass
  return True


def render_blocklist(domains, rendered_file):
  lines = [
    "# generated by adblock-sync.py",
    "# do not edit directly",
  ]
  for domain in domains:
    lines.append(f"address=/{domain}/0.0.0.0")
    lines.append(f"address=/{domain}/::")
  return write_atomic(rendered_file, "\n".join(lines) + "\n")


def render_merged_domains(domains, merged_file):
  payload = "\n".join(domains)
  if payload:
    payload += "\n"
  return write_atomic(merged_file, payload, mode=0o644)


def protobuf_varint(value):
  number = int(value)
  out = bytearray()
  while True:
    byte = number & 0x7F
    number >>= 7
    if number:
      out.append(byte | 0x80)
    else:
      out.append(byte)
      return bytes(out)


def protobuf_key(field_number, wire_type):
  return protobuf_varint((field_number << 3) | wire_type)


def protobuf_bytes(field_number, payload):
  return protobuf_key(field_number, 2) + protobuf_varint(len(payload)) + payload


def protobuf_string(field_number, value):
  return protobuf_bytes(field_number, str(value).encode("utf-8"))


def protobuf_varint_field(field_number, value):
  return protobuf_key(field_number, 0) + protobuf_varint(value)


def build_custom_dat(domains, code="ADBLOCK"):
  geosite_payload = bytearray()
  geosite_payload.extend(protobuf_string(1, str(code or "ADBLOCK").strip().upper() or "ADBLOCK"))
  for domain in domains:
    domain_payload = bytearray()
    # type=2 => RootDomain. Ini paling cocok untuk daftar host adblock plain.
    domain_payload.extend(protobuf_varint_field(1, 2))
    domain_payload.extend(protobuf_string(2, domain))
    geosite_payload.extend(protobuf_bytes(2, bytes(domain_payload)))
  return protobuf_bytes(1, bytes(geosite_payload))


def render_custom_dat(domains, custom_dat_path):
  return write_atomic_bytes(custom_dat_path, build_custom_dat(domains), mode=0o644)


def update_env_file(path, updates):
  src = pathlib.Path(path)
  lines = []
  if src.exists():
    try:
      lines = src.read_text(encoding="utf-8").splitlines()
    except Exception:
      lines = []

  out = []
  seen = set()
  for line in lines:
    stripped = line.strip()
    if not stripped or stripped.startswith("#") or "=" not in line:
      out.append(line)
      continue
    key, _ = line.split("=", 1)
    key = key.strip()
    if key in updates:
      out.append(f"{key}={updates[key]}")
      seen.add(key)
    else:
      out.append(line)

  for key, value in updates.items():
    if key in seen:
      continue
    out.append(f"{key}={value}")

  write_atomic(src, "\n".join(out).rstrip("\n") + "\n", mode=0o644)


def flush_table(table_name):
  subprocess.run(
    ["nft", "delete", "table", "inet", table_name],
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
    check=False,
  )


def apply_table(table_name, dns_port, users):
  rules = [
    f"table inet {table_name} {{",
    "  chain output {",
    "    type nat hook output priority dstnat; policy accept;",
  ]
  for _, uid in users:
    rules.append(f"    meta skuid {uid} udp dport 53 redirect to :{dns_port}")
    rules.append(f"    meta skuid {uid} tcp dport 53 redirect to :{dns_port}")
  rules.extend(["  }", "}"])
  flush_table(table_name)
  subprocess.run(
    ["nft", "-f", "-"],
    input="\n".join(rules) + "\n",
    text=True,
    check=True,
  )


def ensure_dns_service_loaded(cfg, rendered_changed):
  if str(cfg["dns_service"] or "").strip() in ("", "-", "none"):
    return
  current_state = service_state(cfg["dns_service"])
  if rendered_changed:
    if not service_restart(cfg["dns_service"]):
      raise SystemExit(f"Gagal restart DNS Adblock service: {cfg['dns_service']}")
    return
  if current_state != "active":
    service_start(cfg["dns_service"])


def reload_xray_if_needed(cfg, custom_changed, should_reload):
  if str(cfg["xray_service"] or "").strip() in ("", "-", "none"):
    return
  if not should_reload or not custom_changed:
    return
  if not service_restart(cfg["xray_service"]):
    raise SystemExit(f"Gagal reload service xray: {cfg['xray_service']}")
  if service_state(cfg["xray_service"]) != "active":
    raise SystemExit(f"Service xray tidak aktif setelah reload: {cfg['xray_service']}")


def xray_adblock_enabled():
  try:
    cfg = json.loads(DEFAULT_XRAY_ROUTING_FILE.read_text(encoding="utf-8"))
  except Exception:
    return False
  rules = ((cfg.get("routing") or {}).get("rules") or [])
  for rule in rules:
    if not isinstance(rule, dict) or rule.get("type") != "field":
      continue
    domains = rule.get("domain") or []
    if not isinstance(domains, list):
      continue
    if any(isinstance(item, str) and item.strip() == DEFAULT_XRAY_ADBLOCK_ENTRY for item in domains):
      return True
  return False


def materialize_artifacts(cfg, domains):
  merged_changed = render_merged_domains(domains, cfg["merged_file"])
  rendered_changed = render_blocklist(domains, cfg["rendered_file"])
  custom_changed = render_custom_dat(domains, cfg["custom_dat"])
  return merged_changed, rendered_changed, custom_changed


def apply_runtime(cfg, refresh_sources=False, reload_xray=False):
  if subprocess.run(["which", "nft"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False).returncode != 0:
    raise SystemExit("nft tidak tersedia")

  rendered_changed = False
  custom_changed = False
  if refresh_sources:
    blocklist, failed_urls = build_blocklist(cfg)
    if failed_urls:
      raise SystemExit(
        "Gagal mengambil source URL adblock: " + ", ".join(sorted(dict.fromkeys(failed_urls)))
      )
    _, rendered_changed, custom_changed = materialize_artifacts(cfg, blocklist)
  else:
    merged_blocklist = read_merged_domains(cfg["merged_file"])
    if merged_blocklist:
      blocklist = merged_blocklist
      rendered_changed = render_blocklist(blocklist, cfg["rendered_file"])
      custom_path = pathlib.Path(cfg["custom_dat"])
      if not custom_path.is_file() or custom_path.stat().st_size == 0:
        custom_changed = render_custom_dat(blocklist, cfg["custom_dat"])
    else:
      rendered_blocklist = read_rendered_blocklist(cfg["rendered_file"])
      if rendered_blocklist:
        blocklist = rendered_blocklist
        render_merged_domains(blocklist, cfg["merged_file"])
      else:
        blocklist = read_blocklist(cfg["blocklist_file"])
      rendered_changed = render_blocklist(blocklist, cfg["rendered_file"])
      custom_path = pathlib.Path(cfg["custom_dat"])
      if blocklist and (rendered_blocklist or not custom_path.is_file() or custom_path.stat().st_size == 0):
        custom_changed = render_custom_dat(blocklist, cfg["custom_dat"])

  ensure_dns_service_loaded(cfg, rendered_changed)

  users = list_managed_users(cfg["state_root"])
  if not cfg["enabled"] or not users:
    flush_table(cfg["nft_table"])
  else:
    apply_table(cfg["nft_table"], cfg["dns_port"], users)

  if refresh_sources:
    update_env_file(
      cfg["env_file"],
      {
        ADBLOCK_DIRTY_KEY: "0",
        ADBLOCK_LAST_UPDATE_KEY: datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC"),
      },
    )
    cfg["dirty"] = False

  reload_xray_if_needed(cfg, custom_changed, reload_xray)
  return users, blocklist


def print_status(cfg):
  users = list_managed_users(cfg["state_root"])
  manual_domains = read_blocklist(cfg["blocklist_file"])
  merged_domains = read_merged_domains(cfg["merged_file"])
  if not merged_domains:
    merged_domains = read_rendered_blocklist(cfg["rendered_file"])
  print(f"enabled={1 if cfg['enabled'] else 0}")
  print(f"dirty={1 if cfg['dirty'] else 0}")
  print(f"dns_service={service_state(cfg['dns_service'])}")
  print(f"sync_service={service_state(cfg['sync_service'])}")
  print(f"nft_table={'present' if table_exists(cfg['nft_table']) else 'absent'}")
  print(f"bound_users={len(users)}")
  print(f"users_count={len(users)}")
  print(f"manual_domains={len(manual_domains)}")
  print(f"merged_domains={len(merged_domains)}")
  print(f"blocklist_entries={len(merged_domains)}")
  print(f"source_urls={len(cfg['source_urls'])}")
  print(f"dns_port={cfg['dns_port']}")
  print(f"blocklist_file={cfg['blocklist_file']}")
  print(f"urls_file={cfg['urls_file']}")
  print(f"merged_file={cfg['merged_file']}")
  print(f"rendered_file={'ready' if pathlib.Path(cfg['rendered_file']).is_file() else 'missing'}")
  print(f"custom_dat={'ready' if pathlib.Path(cfg['custom_dat']).is_file() else 'missing'}")
  print(f"custom_dat_path={cfg['custom_dat']}")
  print(f"auto_update_enabled={1 if cfg['auto_update_enabled'] else 0}")
  print(f"auto_update_service={service_state(cfg['auto_update_service'])}")
  print(f"auto_update_timer={service_state(cfg['auto_update_timer'])}")
  print(f"auto_update_days={cfg['auto_update_days']}")
  print(f"auto_update_schedule=every {cfg['auto_update_days']} day(s)")
  print(f"last_update={cfg['last_update'] or '-'}")


def print_users(cfg):
  for username, uid in list_managed_users(cfg["state_root"]):
    print(f"{username}|{uid}")


def main():
  args = parse_args()
  env = parse_env_file(args.env_file)
  cfg = {
    "enabled": to_bool(env.get("SSH_DNS_ADBLOCK_ENABLED", "0")),
    "dirty": to_bool(env.get(ADBLOCK_DIRTY_KEY, "0")),
    "last_update": env.get(ADBLOCK_LAST_UPDATE_KEY, ""),
    "state_root": env.get("SSH_DNS_ADBLOCK_STATE_ROOT", str(DEFAULT_STATE_ROOT)),
    "blocklist_file": env.get("SSH_DNS_ADBLOCK_BLOCKLIST_FILE", str(DEFAULT_BLOCKLIST_FILE)),
    "urls_file": env.get("SSH_DNS_ADBLOCK_URLS_FILE", str(DEFAULT_URLS_FILE)),
    "merged_file": env.get(ADBLOCK_MERGED_FILE_KEY, str(DEFAULT_MERGED_FILE)),
    "rendered_file": env.get("SSH_DNS_ADBLOCK_RENDERED_FILE", str(DEFAULT_RENDERED_FILE)),
    "custom_dat": env.get(ADBLOCK_CUSTOM_DAT_KEY, str(DEFAULT_CUSTOM_DAT)),
    "nft_table": env.get("SSH_DNS_ADBLOCK_NFT_TABLE", DEFAULT_NFT_TABLE),
    "dns_port": to_int(env.get("SSH_DNS_ADBLOCK_PORT", str(DEFAULT_DNS_PORT)), DEFAULT_DNS_PORT),
    "dns_service": env.get("SSH_DNS_ADBLOCK_SERVICE", DEFAULT_DNS_SERVICE),
    "sync_service": env.get("SSH_DNS_ADBLOCK_SYNC_SERVICE", DEFAULT_SYNC_SERVICE),
    "xray_service": env.get(ADBLOCK_XRAY_SERVICE_KEY, DEFAULT_XRAY_SERVICE),
    "auto_update_enabled": to_bool(env.get(ADBLOCK_AUTO_UPDATE_ENABLED_KEY, "0")),
    "auto_update_service": env.get(ADBLOCK_AUTO_UPDATE_SERVICE_KEY, "adblock-update.service"),
    "auto_update_timer": env.get(ADBLOCK_AUTO_UPDATE_TIMER_KEY, "adblock-update.timer"),
    "auto_update_days": max(1, to_int(env.get(ADBLOCK_AUTO_UPDATE_DAYS_KEY, "1"), 1)),
    "env_file": args.env_file,
  }
  cfg["source_urls"] = read_urls_file(cfg["urls_file"])

  if args.show_users:
    print_users(cfg)
    return 0
  if args.status:
    print_status(cfg)
    return 0

  reload_xray = bool(args.reload_xray)
  if args.reload_xray_if_enabled and xray_adblock_enabled():
    reload_xray = True

  users, blocklist = apply_runtime(cfg, refresh_sources=args.update, reload_xray=reload_xray)
  if args.apply or args.update or (not args.status and not args.show_users):
    sys.stderr.write(
      f"adblock-sync: enabled={1 if cfg['enabled'] else 0} users={len(users)} blocklist={len(blocklist)} urls={len(cfg['source_urls'])}\n"
    )
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
