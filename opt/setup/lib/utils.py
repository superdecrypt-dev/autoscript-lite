#!/usr/bin/env python3
import json
import os
import re
import tempfile
import pathlib
import subprocess
from typing import Any, Dict, List, Optional, Tuple, Union

# Common Regex
SSH_USERNAME_RE = re.compile(r"^[a-z_][a-z0-9_-]{1,31}$")
SSHWS_TOKEN_RE = re.compile(r"^[a-f0-9]{10}$")
SSHWS_DIAGNOSTIC_TOKEN = "diagnostic-probe"

def norm_user(v: Any) -> str:
    """Normalize username by removing protocol suffixes."""
    s = str(v or "").strip()
    if s.endswith("@ssh"):
        s = s[:-4]
    if "@" in s:
        s = s.split("@", 1)[0]
    return s

def normalize_token(v: Any) -> str:
    """Normalize and validate SSHWS token."""
    s = str(v or "").strip().lower()
    if s == SSHWS_DIAGNOSTIC_TOKEN or SSHWS_TOKEN_RE.fullmatch(s):
        return s
    return ""

def to_bool(v: Any) -> bool:
    """Convert various types to boolean."""
    if isinstance(v, bool):
        return v
    if isinstance(v, (int, float)):
        return bool(v)
    return str(v or "").strip().lower() in ("1", "true", "yes", "on", "y")

def to_int(v: Any, default: int = 0) -> int:
    """Safely convert value to integer."""
    try:
        if v is None: return default
        if isinstance(v, (int, float, bool)): return int(v)
        s = str(v).strip()
        return int(float(s)) if s else default
    except Exception:
        return default

def to_float(v: Any, default: float = 0.0) -> float:
    """Safely convert value to float."""
    try:
        if v is None: return default
        if isinstance(v, (int, float, bool)): return float(v)
        s = str(v).strip()
        return float(s) if s else default
    except Exception:
        return default

def normalize_ip(v: Any) -> str:
    """Normalize IP address (handling brackets for IPv6)."""
    s = str(v or "").strip()
    if not s: return ""
    if s.startswith("[") and s.endswith("]"):
        s = s[1:-1].strip()
    try:
        import ipaddress
        return str(ipaddress.ip_address(s))
    except Exception:
        return ""

def normalize_real_address_ip(value: Any) -> str:
    """Extract and normalize IP from 'IP:PORT' format."""
    raw = str(value or "").strip()
    if not raw: return ""
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

def is_loopback_ip(v: Any) -> bool:
    """Check if an IP is a loopback address."""
    s = normalize_ip(v)
    if not s: return False
    try:
        import ipaddress
        return ipaddress.ip_address(s).is_loopback
    except Exception:
        return False

def write_json_atomic(path: Union[str, pathlib.Path], payload: Any, mode: int = 0o600) -> bool:
    """Write JSON file atomically using a temporary file."""
    path = pathlib.Path(path)
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        text = json.dumps(payload, ensure_ascii=False, indent=2) + "\n"
        fd, tmp = tempfile.mkstemp(prefix=".tmp.", suffix=".json", dir=str(path.parent))
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                f.write(text)
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp, str(path))
            try:
                os.chmod(str(path), mode)
            except Exception:
                pass
            return True
        finally:
            if os.path.exists(tmp):
                try:
                    if os.path.exists(tmp):
                        os.remove(tmp)
                except Exception:
                    pass
    except Exception:
        return False

def load_json_file(path: Union[str, pathlib.Path]) -> Optional[Dict]:
    """Load and parse a JSON file."""
    try:
        p = pathlib.Path(path)
        if not p.is_file(): return None
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception:
        return None

def read_env_map(path: Union[str, pathlib.Path]) -> Dict[str, str]:
    """Read a simple KEY=VALUE environment file."""
    data = {}
    p = pathlib.Path(path)
    if not p.is_file(): return data
    try:
        for line in p.read_text(encoding="utf-8", errors="ignore").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            data[key.strip()] = value.strip().strip("'\"")
    except Exception:
        pass
    return data

def run_cmd(argv: List[str], timeout: int = 30, check: bool = False) -> Tuple[bool, str]:
    """Run a system command and return success status and output."""
    try:
        cp = subprocess.run(
            argv,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=check
        )
        out = (cp.stdout or "").strip() or (cp.stderr or "").strip()
        return (cp.returncode == 0), out
    except Exception as exc:
        return False, str(exc)
