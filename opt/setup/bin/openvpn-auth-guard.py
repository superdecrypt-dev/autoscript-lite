#!/usr/bin/env python3
import json
import os
import pathlib
import subprocess
import time

STATE_ROOT = pathlib.Path("/opt/quota/openvpn")
ENFORCER_BIN = "/usr/local/bin/sshws-qac-enforcer"
ENFORCER_TIMEOUT_SEC = 12
SSHWS_PROXY_SERVICE = "sshws-proxy.service"
SSHWS_FLUSH_WAIT_SEC = 0.25


def norm_user(value):
  text = str(value or "").strip()
  if text.endswith("@ssh"):
    text = text[:-4]
  if "@" in text:
    text = text.split("@", 1)[0]
  return text


def state_candidates(username):
  user = norm_user(username)
  if not user:
    return []
  return [
    STATE_ROOT / f"{user}@openvpn.json",
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


def refresh_user_state(username):
  user = norm_user(username)
  if not user or not os.path.exists(ENFORCER_BIN):
    return
  try:
    subprocess.run(
      ["systemctl", "kill", "-s", "SIGUSR1", "--kill-who=main", SSHWS_PROXY_SERVICE],
      stdout=subprocess.DEVNULL,
      stderr=subprocess.DEVNULL,
      check=False,
      timeout=3,
    )
    time.sleep(SSHWS_FLUSH_WAIT_SEC)
  except Exception:
    pass
  try:
    subprocess.run(
      [ENFORCER_BIN, "--once", "--user", user],
      stdout=subprocess.DEVNULL,
      stderr=subprocess.DEVNULL,
      check=False,
      timeout=ENFORCER_TIMEOUT_SEC,
    )
  except Exception:
    return


def should_deny(payload):
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


def main():
  username = norm_user(os.environ.get("PAM_USER") or (os.sys.argv[1] if len(os.sys.argv) > 1 else ""))
  if not username:
    raise SystemExit(0)
  refresh_user_state(username)
  payload = load_state(username)
  raise SystemExit(1 if should_deny(payload) else 0)


if __name__ == "__main__":
  main()
