#!/usr/bin/env bash
set -euo pipefail

BOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd -P)"
REPO_DIR="$(cd -- "${BOT_DIR}/.." >/dev/null 2>&1 && pwd -P)"
export BOT_DIR REPO_DIR

PROFILE="${1:-local}"
PROD_INSTANCE="${PROD_INSTANCE:-xray-itg-1771777921}"
STAGING_INSTANCE="${STAGING_INSTANCE:-xray-stg-gate3-1771864485}"

log() {
  printf '[gate-all] %s\n' "$*"
}

die() {
  printf '[gate-all] ERROR: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "command tidak ditemukan: $1"
}

run_gate_1() {
  log "Gate 1: Static & Build"

  mapfile -t backend_py_files < <(find "${BOT_DIR}/backend-py/app" -name '*.py')
  if (( ${#backend_py_files[@]} > 0 )); then
    python3 -m py_compile "${backend_py_files[@]}"
  fi

  (
    cd "${BOT_DIR}/gateway-ts"
    npm run build
  )
}

run_gate_2() {
  log "Gate 2: API Smoke (service layer)"

  python3 - <<'PY'
import os
import sys
from pathlib import Path

sys.path.insert(0, str((Path(os.environ["BOT_DIR"]) / "backend-py").resolve()))
from app.services import domain

cases = [
    ("domain_info_success", "domain_info", {}, "ok"),
    ("setup_domain_custom_invalid_domain", "setup_domain_custom", {"domain": "abc"}, "setup_domain_custom_failed"),
    ("setup_domain_cloudflare_invalid_root", "setup_domain_cloudflare", {"root_domain": "999"}, "setup_domain_cloudflare_failed"),
    ("strict_bool_proxied_invalid", "setup_domain_cloudflare", {"root_domain": "999", "proxied": "abc"}, "invalid_param"),
    ("strict_subdomain_mode_invalid", "setup_domain_cloudflare", {"root_domain": "vyxara1.web.id", "subdomain_mode": "oops"}, "invalid_param"),
]

bad = []
for name, action, params, expect_code in cases:
    res = domain.handle(action, params)
    ok = bool(res.get("code") == expect_code or (expect_code == "ok" and res.get("ok") is True))
    print(f"gate2_{name}={'PASS' if ok else 'FAIL'} code={res.get('code')} ok={res.get('ok')}")
    if not ok:
        bad.append(name)

original_cf = domain.system_mutations.op_domain_setup_cloudflare
captured = {}
contract_ok = False
try:
    def fake_cf(*, root_domain_input, subdomain_mode, subdomain, proxied, allow_existing_same_ip):
        captured["root_domain_input"] = root_domain_input
        captured["subdomain_mode"] = subdomain_mode
        captured["subdomain"] = subdomain
        captured["proxied"] = proxied
        captured["allow_existing_same_ip"] = allow_existing_same_ip
        return True, "Domain Control - Set Domain (Cloudflare Wizard)", "mocked"

    domain.system_mutations.op_domain_setup_cloudflare = fake_cf
    res_contract = domain.handle(
        "setup_domain_cloudflare",
        {
            "root_domain": "vyxara1.web.id",
            "subdomain_mode": "manual",
            "subdomain": "gate2-test",
            "proxied": "true",
            "allow_existing_same_ip": "false",
        },
    )
    contract_ok = bool(
        res_contract.get("ok") is True
        and captured.get("proxied") is True
        and captured.get("allow_existing_same_ip") is False
        and captured.get("subdomain_mode") == "manual"
        and captured.get("subdomain") == "gate2-test"
    )
finally:
    domain.system_mutations.op_domain_setup_cloudflare = original_cf

print(f"gate2_bool_explicit_contract={'PASS' if contract_ok else 'FAIL'}")
if not contract_ok:
    bad.append("bool_explicit_contract")

if bad:
    raise SystemExit(f"gate2_failed={','.join(bad)}")
PY
}

run_gate_3() {
  log "Gate 3: Integration non-produksi (local uvicorn HTTP)"

  local log_file="${BOT_DIR}/runtime/logs/backend-gate3-gateall.log"
  (
    cd "${BOT_DIR}/backend-py"
    export INTERNAL_SHARED_SECRET="gate3-gateall-secret"
    export BACKEND_HOST="127.0.0.1"
    export BACKEND_PORT="18082"
    "${BOT_DIR}/.venv/bin/uvicorn" app.main:app --host "${BACKEND_HOST}" --port "${BACKEND_PORT}" >"${log_file}" 2>&1 &
    local uv_pid="$!"
    trap 'kill "${uv_pid}" >/dev/null 2>&1 || true' EXIT

    for _ in $(seq 1 60); do
      if curl -fsS -H "X-Internal-Shared-Secret: gate3-gateall-secret" "http://127.0.0.1:18082/health" >/dev/null 2>&1; then
        break
      fi
      sleep 0.25
    done

    python3 - <<'PY'
import json
import urllib.request
import urllib.error

BASE = "http://127.0.0.1:18082"
SECRET = "gate3-gateall-secret"

def get(path, headers=None):
    req = urllib.request.Request(BASE + path, headers=headers or {}, method="GET")
    with urllib.request.urlopen(req, timeout=10) as r:
        return r.getcode(), json.loads(r.read().decode("utf-8", "ignore"))

def post(path, payload, headers=None):
    req = urllib.request.Request(
        BASE + path,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json", **(headers or {})},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.getcode(), json.loads(r.read().decode("utf-8", "ignore"))

def get_allow_error(path, headers=None):
    try:
        return get(path, headers)
    except urllib.error.HTTPError as exc:
        return exc.code, json.loads(exc.read().decode("utf-8", "ignore"))

checks = []
def rec(name, ok):
    checks.append((name, bool(ok)))
    print(f"gate3_{name}={'PASS' if ok else 'FAIL'}")

s, b = get("/health", headers={"X-Internal-Shared-Secret": SECRET})
rec("health", s == 200 and b.get("status") == "ok")
s, b = get_allow_error("/health")
rec("auth_guard", s == 401)
s, b = post("/api/domain/action", {"action": "info", "params": {}}, headers={"X-Internal-Shared-Secret": SECRET})
rec("domain_info", s == 200 and b.get("code") == "ok")
s, b = post("/api/status/action", {"action": "tls", "params": {}}, headers={"X-Internal-Shared-Secret": SECRET})
rec("status_tls", s == 200 and b.get("code") == "ok")
s, b = post("/api/ops/action", {"action": "traffic_overview", "params": {}}, headers={"X-Internal-Shared-Secret": SECRET})
rec("ops_traffic_overview", s == 200 and b.get("code") == "ok")

if not all(ok for _, ok in checks):
    raise SystemExit("gate3_failed")
PY
  )
}

run_gate_3_1() {
  log "Gate 3.1: Integration produksi (${PROD_INSTANCE})"
  need_cmd lxc

  lxc exec "${PROD_INSTANCE}" -- bash -lc '
set -euo pipefail
env_file="${BOT_ENV_FILE:-${DISCORD_ENV_FILE:-}}"
if [[ -z "${env_file}" || ! -f "${env_file}" ]]; then
env_file="$(systemctl cat bot-discord-gateway 2>/dev/null | awk '"'"'
    /^[[:space:]]*EnvironmentFile=/ {
      value = substr($0, index($0, "=") + 1)
      sub(/^-/, "", value)
      if (value != "") print value
    }
  '"'"' | tail -n1)"
fi
if [[ -z "${env_file}" || ! -f "${env_file}" ]]; then
  env_file="/etc/bot-discord/bot.env"
fi
source "${env_file}"
export INTERNAL_SHARED_SECRET
python3 - <<'"'"'PY'"'"'
import json, os, urllib.request, urllib.error
SECRET=os.environ.get("INTERNAL_SHARED_SECRET","")

def resolve_backend_base_url(default_port: int) -> str:
    raw_base = (os.environ.get("BACKEND_BASE_URL") or "").strip().rstrip("/")
    raw_host = (os.environ.get("BACKEND_HOST") or "").strip()
    raw_port = (os.environ.get("BACKEND_PORT") or "").strip()

    def format_host_for_url(host: str) -> str:
        if ":" in host and not (host.startswith("[") and host.endswith("]")):
            return f"[{host}]"
        return host

    if raw_host or raw_port:
        host = raw_host or "127.0.0.1"
        port = raw_port or str(default_port)
        try:
            port_num = int(port)
        except ValueError as exc:
            raise SystemExit(f"BACKEND_PORT tidak valid: {port}") from exc
        if port_num < 1 or port_num > 65535:
            raise SystemExit(f"BACKEND_PORT tidak valid: {port}")
        derived = f"http://{format_host_for_url(host)}:{port_num}"
        if raw_base and raw_base != derived:
            raise SystemExit("BACKEND_BASE_URL tidak sinkron dengan BACKEND_HOST/BACKEND_PORT.")
        return derived
    return raw_base or f"http://127.0.0.1:{default_port}"

BASE=resolve_backend_base_url(8080)

def get(path, headers=None):
    req=urllib.request.Request(BASE+path, headers=headers or {}, method="GET")
    with urllib.request.urlopen(req, timeout=10) as r:
        return r.getcode(), json.loads(r.read().decode("utf-8","ignore"))

def post(path, payload, headers=None):
    req=urllib.request.Request(
        BASE+path,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type":"application/json", **(headers or {})},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=20) as r:
        return r.getcode(), json.loads(r.read().decode("utf-8","ignore"))

def get_allow_error(path, headers=None):
    try:
        return get(path, headers)
    except urllib.error.HTTPError as exc:
        return exc.code, json.loads(exc.read().decode("utf-8","ignore"))

checks=[]
def rec(name, ok):
    checks.append((name, bool(ok)))
    status_text = "PASS" if ok else "FAIL"
    print(f"gate3_1_{name}={status_text}")

s,b=get("/health", headers={"X-Internal-Shared-Secret":SECRET})
rec("health", s==200 and b.get("status")=="ok")
s,b=get_allow_error("/health")
rec("auth_guard", s==401)
s,b=post("/api/domain/action", {"action":"info","params":{}}, headers={"X-Internal-Shared-Secret":SECRET})
rec("domain_info", s==200 and b.get("code")=="ok")
s,b=post("/api/status/action", {"action":"tls","params":{}}, headers={"X-Internal-Shared-Secret":SECRET})
rec("status_tls", s==200 and b.get("code")=="ok")
s,b=post("/api/ops/action", {"action":"traffic_overview","params":{}}, headers={"X-Internal-Shared-Secret":SECRET})
rec("ops_traffic_overview", s==200 and b.get("code")=="ok")

if not all(ok for _,ok in checks):
    raise SystemExit("gate3_1_failed")
PY
'
}

run_gate_4() {
  log "Gate 4: Negative/Failure (${STAGING_INSTANCE})"
  need_cmd lxc

  lxc exec "${STAGING_INSTANCE}" -- bash -lc '
set -euo pipefail
env_file="${BOT_ENV_FILE:-${DISCORD_ENV_FILE:-}}"
if [[ -z "${env_file}" || ! -f "${env_file}" ]]; then
env_file="$(systemctl cat bot-discord-gateway 2>/dev/null | awk '"'"'
    /^[[:space:]]*EnvironmentFile=/ {
      value = substr($0, index($0, "=") + 1)
      sub(/^-/, "", value)
      if (value != "") print value
    }
  '"'"' | tail -n1)"
fi
if [[ -z "${env_file}" || ! -f "${env_file}" ]]; then
  env_file="/etc/bot-discord/bot.env"
fi
source "${env_file}"
export INTERNAL_SHARED_SECRET
python3 - <<'"'"'PY'"'"'
import json, os, urllib.request, urllib.error
SECRET=os.environ.get("INTERNAL_SHARED_SECRET","")

def resolve_backend_base_url(default_port: int) -> str:
    raw_base = (os.environ.get("BACKEND_BASE_URL") or "").strip().rstrip("/")
    raw_host = (os.environ.get("BACKEND_HOST") or "").strip()
    raw_port = (os.environ.get("BACKEND_PORT") or "").strip()

    def format_host_for_url(host: str) -> str:
        if ":" in host and not (host.startswith("[") and host.endswith("]")):
            return f"[{host}]"
        return host

    if raw_host or raw_port:
        host = raw_host or "127.0.0.1"
        port = raw_port or str(default_port)
        try:
            port_num = int(port)
        except ValueError as exc:
            raise SystemExit(f"BACKEND_PORT tidak valid: {port}") from exc
        if port_num < 1 or port_num > 65535:
            raise SystemExit(f"BACKEND_PORT tidak valid: {port}")
        derived = f"http://{format_host_for_url(host)}:{port_num}"
        if raw_base and raw_base != derived:
            raise SystemExit("BACKEND_BASE_URL tidak sinkron dengan BACKEND_HOST/BACKEND_PORT.")
        return derived
    return raw_base or f"http://127.0.0.1:{default_port}"

BASE=resolve_backend_base_url(8080)

def request(method, path, payload=None, auth=True):
    headers={"Content-Type":"application/json"}
    if auth:
        headers["X-Internal-Shared-Secret"]=SECRET
    data=None
    if payload is not None:
        data=json.dumps(payload).encode("utf-8")
    req=urllib.request.Request(BASE+path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.getcode(), json.loads(r.read().decode("utf-8","ignore"))
    except urllib.error.HTTPError as exc:
        return exc.code, json.loads(exc.read().decode("utf-8","ignore"))

checks=[]
def rec(name, ok):
    checks.append((name, bool(ok)))
    status_text = "PASS" if ok else "FAIL"
    print(f"gate4_{name}={status_text}")

s,b=request("GET","/health", auth=False)
rec("auth_guard", s==401)
s,b=request("POST","/api/domain/action", {"action":"set_auto","params":{"root_domain":"999","proxied":"abc"}}, auth=True)
rec("invalid_bool", s==200 and b.get("code")=="invalid_param")
s,b=request("POST","/api/domain/action", {"action":"set_auto","params":{"root_domain":"999"}}, auth=True)
rec("invalid_root", s==200 and b.get("code")=="setup_domain_cloudflare_failed")

if not all(ok for _,ok in checks):
    raise SystemExit("gate4_failed")
PY
'
}

run_gate_5() {
  log "Gate 5: Discord E2E UX (server-side checks)"
  need_cmd lxc

  lxc exec "${PROD_INSTANCE}" -- bash -lc '
set -euo pipefail
systemctl show bot-discord-gateway -p ActiveState -p SubState -p NRestarts --no-pager
env_file="${BOT_ENV_FILE:-${DISCORD_ENV_FILE:-}}"
if [[ -z "${env_file}" || ! -f "${env_file}" ]]; then
  env_file="$(systemctl cat bot-discord-gateway 2>/dev/null | awk '"'"'
    /^[[:space:]]*EnvironmentFile=/ {
      value = substr($0, index($0, "=") + 1)
      sub(/^-/, "", value)
      if (value != "") print value
    }
  '"'"' | tail -n1)"
fi
if [[ -z "${env_file}" || ! -f "${env_file}" ]]; then
  env_file="/etc/bot-discord/bot.env"
fi
source "${env_file}"
export RESP_JSON="$(curl -fsS --max-time 20 -H "Authorization: Bot ${DISCORD_BOT_TOKEN}" -H "User-Agent: bot-discord-gateway/1.0" "https://discord.com/api/v10/applications/${DISCORD_APPLICATION_ID}/guilds/${DISCORD_GUILD_ID}/commands")"
python3 - <<'"'"'PY'"'"'
import json, os
data = json.loads(os.environ["RESP_JSON"])
names = sorted(str(x.get("name") or "") for x in data if isinstance(x, dict))
print("gate5_commands=" + ",".join(names))
required = {"menu", "status", "notify"}
missing = sorted(required.difference(set(names)))
if missing:
    raise SystemExit("gate5_commands_missing:" + ",".join(missing))
PY
'
}

run_gate_6() {
  log "Gate 6: Regression produksi (read-only menu smoke)"
  need_cmd lxc

  lxc exec "${PROD_INSTANCE}" -- bash -lc '
set -euo pipefail
env_file="${BOT_ENV_FILE:-${DISCORD_ENV_FILE:-}}"
if [[ -z "${env_file}" || ! -f "${env_file}" ]]; then
env_file="$(systemctl cat bot-discord-gateway 2>/dev/null | awk '"'"'
    /^[[:space:]]*EnvironmentFile=/ {
      value = substr($0, index($0, "=") + 1)
      sub(/^-/, "", value)
      if (value != "") print value
    }
  '"'"' | tail -n1)"
fi
if [[ -z "${env_file}" || ! -f "${env_file}" ]]; then
  env_file="/etc/bot-discord/bot.env"
fi
source "${env_file}"
export INTERNAL_SHARED_SECRET
python3 - <<'"'"'PY'"'"'
import json, os, urllib.request, urllib.error
SECRET=os.environ.get("INTERNAL_SHARED_SECRET","")

def resolve_backend_base_url(default_port: int) -> str:
    raw_base = (os.environ.get("BACKEND_BASE_URL") or "").strip().rstrip("/")
    raw_host = (os.environ.get("BACKEND_HOST") or "").strip()
    raw_port = (os.environ.get("BACKEND_PORT") or "").strip()

    def format_host_for_url(host: str) -> str:
        if ":" in host and not (host.startswith("[") and host.endswith("]")):
            return f"[{host}]"
        return host

    if raw_host or raw_port:
        host = raw_host or "127.0.0.1"
        port = raw_port or str(default_port)
        try:
            port_num = int(port)
        except ValueError as exc:
            raise SystemExit(f"BACKEND_PORT tidak valid: {port}") from exc
        if port_num < 1 or port_num > 65535:
            raise SystemExit(f"BACKEND_PORT tidak valid: {port}")
        derived = f"http://{format_host_for_url(host)}:{port_num}"
        if raw_base and raw_base != derived:
            raise SystemExit("BACKEND_BASE_URL tidak sinkron dengan BACKEND_HOST/BACKEND_PORT.")
        return derived
    return raw_base or f"http://127.0.0.1:{default_port}"

BASE=resolve_backend_base_url(8080)
cases=[
  ("status","overview",{}),
  ("status","tls",{}),
  ("qac","summary",{"scope":"xray"}),
  ("network","dns_summary",{}),
  ("domain","info",{}),
  ("network","domain_guard_status",{}),
  ("ops","service_status",{}),
  ("ops","traffic_overview",{}),
]

def post(domain, action, params):
    req=urllib.request.Request(
      BASE+f"/api/{domain}/action",
      data=json.dumps({"action":action,"params":params}).encode("utf-8"),
      headers={"Content-Type":"application/json","X-Internal-Shared-Secret":SECRET},
      method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as r:
      return r.getcode(), json.loads(r.read().decode("utf-8","ignore"))

ok_all=True
for domain, action, params in cases:
    s,b=post(domain, action, params)
    ok=(s==200 and isinstance(b,dict) and "ok" in b and "code" in b and "title" in b)
    status_text = "PASS" if ok else "FAIL"
    print(f"gate6_{domain}_{action}={status_text}")
    ok_all=ok_all and ok
if not ok_all:
    raise SystemExit("gate6_failed")
PY
'
}

run_local_bundle() {
  run_gate_1
  run_gate_2
  run_gate_3
}

run_prod_bundle() {
  run_gate_3_1
  run_gate_5
  run_gate_6
}

run_all_bundle() {
  run_local_bundle
  run_gate_4
  run_prod_bundle
}

case "${PROFILE}" in
  local) run_local_bundle ;;
  prod) run_prod_bundle ;;
  all) run_all_bundle ;;
  *)
    cat <<EOF
Usage: $(basename "$0") [local|prod|all]
  local : Gate 1,2,3 (workspace/staging local uvicorn)
  prod  : Gate 3.1,5,6 (instance produksi via LXC)
  all   : Gate 1-6 (Gate 4 via STAGING_INSTANCE)

Env override:
  PROD_INSTANCE=${PROD_INSTANCE}
  STAGING_INSTANCE=${STAGING_INSTANCE}
EOF
    exit 1
    ;;
esac

log "Selesai profile=${PROFILE}"
