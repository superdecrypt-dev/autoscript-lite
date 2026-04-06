#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd -P)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

ACCESS_LOG="${TMP_DIR}/access.log"
QUOTA_ROOT="${TMP_DIR}/quota"
SESSION_ROOT="${TMP_DIR}/sessions"

mkdir -p "${QUOTA_ROOT}/vless" "${QUOTA_ROOT}/trojan" "${SESSION_ROOT}"

cat > "${QUOTA_ROOT}/vless/alice@vless.json" <<'EOF'
{
  "username": "alice@vless",
  "status": {
    "active_sessions_total": 99
  }
}
EOF

cat > "${QUOTA_ROOT}/trojan/bob@trojan.json" <<'EOF'
{
  "username": "bob@trojan",
  "status": {
    "active_sessions_total": 0
  }
}
EOF

mkdir -p "${SESSION_ROOT}/vless"
cat > "${SESSION_ROOT}/vless/alice@vless.json" <<'EOF'
{
  "username": "alice@vless",
  "protocol": "vless",
  "sessions": [
    {
      "peer_identity": "198.51.100.9",
      "public_ip": "198.51.100.9",
      "route": "vless-ws",
      "first_seen_unix": 1,
      "last_seen_unix": 2
    }
  ]
}
EOF

python3 - <<'PY' "${ACCESS_LOG}"
import sys
from datetime import datetime, timedelta

path = sys.argv[1]
now = datetime.now()
recent = now.strftime("%Y/%m/%d %H:%M:%S") + ".000000"
older = (now - timedelta(minutes=20)).strftime("%Y/%m/%d %H:%M:%S") + ".000000"
with open(path, "w", encoding="utf-8") as handle:
    handle.write(f"{recent} from 203.0.113.10:0 accepted tcp:www.gstatic.com:443 [default@vless-ws -> direct] email: alice@vless\n")
    handle.write(f"{recent} from 203.0.113.10:0 accepted tcp:www.gstatic.com:443 [default@vless-ws -> direct] email: alice@vless\n")
    handle.write(f"{recent} from 203.0.113.11:0 accepted tcp:www.gstatic.com:443 [default@trojan-ws -> direct] email: bob@trojan\n")
    handle.write(f"{older} from 203.0.113.12:0 accepted tcp:www.gstatic.com:443 [default@trojan-ws -> direct] email: bob@trojan\n")
PY

python3 "${ROOT_DIR}/opt/setup/bin/xray-session.py" watch \
  --once \
  --access-log "${ACCESS_LOG}" \
  --quota-root "${QUOTA_ROOT}" \
  --session-root "${SESSION_ROOT}" \
  --edge-mux-service "" \
  --window-seconds 300

python3 - <<'PY' "${SESSION_ROOT}" "${QUOTA_ROOT}"
import json
import pathlib
import sys

session_root = pathlib.Path(sys.argv[1])
quota_root = pathlib.Path(sys.argv[2])

alice_session = json.loads((session_root / "vless" / "alice@vless.json").read_text(encoding="utf-8"))
bob_session = json.loads((session_root / "trojan" / "bob@trojan.json").read_text(encoding="utf-8"))
summary = json.loads((session_root / "summary.json").read_text(encoding="utf-8"))
alice_quota = json.loads((quota_root / "vless" / "alice@vless.json").read_text(encoding="utf-8"))
bob_quota = json.loads((quota_root / "trojan" / "bob@trojan.json").read_text(encoding="utf-8"))

assert alice_session["active_sessions_total"] == 1, alice_session
assert bob_session["active_sessions_total"] == 1, bob_session
assert summary["active_users_total"] == 2, summary
assert summary["active_sessions_total"] == 2, summary
assert alice_quota["status"]["active_sessions_total"] == 1, alice_quota
assert bob_quota["status"]["active_sessions_total"] == 1, bob_quota
assert "198.51.100.9" not in alice_quota["status"].get("active_session_peers", []), alice_quota
assert "203.0.113.10" in alice_quota["status"].get("active_session_peers", []), alice_quota
PY
