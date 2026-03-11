#!/usr/bin/env python3
import argparse
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
DEFAULT_RENDERED_FILE = pathlib.Path("/etc/autoscript/ssh-adblock/blocklist.generated.conf")
DEFAULT_NFT_TABLE = "autoscript_ssh_adblock"
DEFAULT_DNS_PORT = 5353
DEFAULT_DNS_SERVICE = "ssh-adblock-dns.service"
DEFAULT_SYNC_SERVICE = "ssh-adblock-sync.service"
SSH_USER_RE = re.compile(r"^([a-z_][a-z0-9_-]{0,31})@ssh\.json$")


def parse_args():
  parser = argparse.ArgumentParser(description="Sync SSH DNS adblock runtime")
  parser.add_argument("--apply", action="store_true", help="Apply runtime state")
  parser.add_argument("--update", action="store_true", help="Refresh blocklist from URLs and apply runtime state")
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
  if "." not in domain:
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
    return ""
  if res.returncode != 0:
    return ""
  return res.stdout or ""


def build_blocklist(cfg):
  merged = []
  seen = set()

  def add_many(items):
    for item in items:
      if not item or item in seen:
        continue
      seen.add(item)
      merged.append(item)

  add_many(read_blocklist(cfg["blocklist_file"]))
  for url in cfg["source_urls"]:
    add_many(read_domains_from_text(fetch_url_text(url)))
  return merged


def write_atomic(path, text, mode=0o644):
  target = pathlib.Path(path)
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


def render_blocklist(domains, rendered_file):
  lines = [
    "# generated by ssh-adblock-sync.py",
    "# do not edit directly",
  ]
  for domain in domains:
    lines.append(f"address=/{domain}/0.0.0.0")
    lines.append(f"address=/{domain}/::")
  write_atomic(rendered_file, "\n".join(lines) + "\n")


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


def apply_runtime(cfg):
  if subprocess.run(["which", "nft"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False).returncode != 0:
    raise SystemExit("nft tidak tersedia")

  blocklist = build_blocklist(cfg)
  render_blocklist(blocklist, cfg["rendered_file"])

  users = list_managed_users(cfg["state_root"])
  if not cfg["enabled"] or not users:
    flush_table(cfg["nft_table"])
    return users, blocklist

  apply_table(cfg["nft_table"], cfg["dns_port"], users)
  return users, blocklist


def print_status(cfg):
  users = list_managed_users(cfg["state_root"])
  blocklist = build_blocklist(cfg)
  print(f"enabled={1 if cfg['enabled'] else 0}")
  print(f"dns_service={service_state(cfg['dns_service'])}")
  print(f"sync_service={service_state(cfg['sync_service'])}")
  print(f"nft_table={'present' if table_exists(cfg['nft_table']) else 'absent'}")
  print(f"bound_users={len(users)}")
  print(f"blocklist_entries={len(blocklist)}")
  print(f"source_urls={len(cfg['source_urls'])}")
  print(f"dns_port={cfg['dns_port']}")
  print(f"blocklist_file={cfg['blocklist_file']}")
  print(f"urls_file={cfg['urls_file']}")


def print_users(cfg):
  for username, uid in list_managed_users(cfg["state_root"]):
    print(f"{username}|{uid}")


def main():
  args = parse_args()
  env = parse_env_file(args.env_file)
  cfg = {
    "enabled": to_bool(env.get("SSH_DNS_ADBLOCK_ENABLED", "0")),
    "state_root": env.get("SSH_DNS_ADBLOCK_STATE_ROOT", str(DEFAULT_STATE_ROOT)),
    "blocklist_file": env.get("SSH_DNS_ADBLOCK_BLOCKLIST_FILE", str(DEFAULT_BLOCKLIST_FILE)),
    "urls_file": env.get("SSH_DNS_ADBLOCK_URLS_FILE", str(DEFAULT_URLS_FILE)),
    "rendered_file": env.get("SSH_DNS_ADBLOCK_RENDERED_FILE", str(DEFAULT_RENDERED_FILE)),
    "nft_table": env.get("SSH_DNS_ADBLOCK_NFT_TABLE", DEFAULT_NFT_TABLE),
    "dns_port": to_int(env.get("SSH_DNS_ADBLOCK_PORT", str(DEFAULT_DNS_PORT)), DEFAULT_DNS_PORT),
    "dns_service": env.get("SSH_DNS_ADBLOCK_SERVICE", DEFAULT_DNS_SERVICE),
    "sync_service": env.get("SSH_DNS_ADBLOCK_SYNC_SERVICE", DEFAULT_SYNC_SERVICE),
  }
  cfg["source_urls"] = read_urls_file(cfg["urls_file"])

  if args.show_users:
    print_users(cfg)
    return 0
  if args.status:
    print_status(cfg)
    return 0

  users, blocklist = apply_runtime(cfg)
  if args.apply or args.update or True:
    sys.stderr.write(
      f"ssh-adblock-sync: enabled={1 if cfg['enabled'] else 0} users={len(users)} blocklist={len(blocklist)} urls={len(cfg['source_urls'])}\n"
    )
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
