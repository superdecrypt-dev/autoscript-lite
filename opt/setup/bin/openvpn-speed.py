#!/usr/bin/env python3
import argparse
import ipaddress
import json
import os
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M")


def load_env(path: str) -> dict[str, str]:
    payload: dict[str, str] = {}
    try:
        for raw in Path(path).read_text(encoding="utf-8").splitlines():
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            payload[key.strip()] = value.strip()
    except Exception:
        return payload
    return payload


def load_json(path: str | Path, default=None):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except Exception:
        return default


def save_json_atomic(path: str | Path, data: dict) -> None:
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp = target.with_name(f".tmp.{target.name}.{os.getpid()}")
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(data, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(tmp, target)


def to_bool(value, default=False) -> bool:
    if value is None:
        return bool(default)
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return bool(value)
    text = str(value or "").strip().lower()
    if not text:
        return bool(default)
    return text in ("1", "true", "yes", "on", "y")


def to_float(value, default=0.0) -> float:
    try:
        if value is None:
            return default
        if isinstance(value, bool):
            return float(int(value))
        if isinstance(value, (int, float)):
            return float(value)
        text = str(value).strip()
        if not text:
            return default
        return float(text)
    except Exception:
        return default


def norm_user(value: object) -> str:
    text = str(value or "").strip()
    if text.endswith("@ssh"):
        text = text[:-4]
    if "@" in text:
        text = text.split("@", 1)[0]
    return text


def resolve_cmd(*candidates: str) -> str:
    for cand in candidates:
        resolved = shutil.which(cand)
        if resolved:
            return resolved
        if cand.startswith("/") and os.path.isfile(cand) and os.access(cand, os.X_OK):
            return cand
    return ""


def run(cmd: list[str], check=True):
    return subprocess.run(
        cmd,
        check=check,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def qdisc_show(dev: str) -> str:
    proc = subprocess.run(
        ["tc", "qdisc", "show", "dev", dev],
        check=False,
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        return ""
    return proc.stdout or ""


def tc_is_speed_managed(iface: str, ifb_iface: str) -> bool:
    out_iface = qdisc_show(iface)
    out_ifb = qdisc_show(ifb_iface)
    return (
        "qdisc htb 30:" in out_iface and
        "qdisc ingress ffff:" in out_iface and
        "qdisc htb 31:" in out_ifb
    )


def ensure_deps() -> None:
    missing = []
    if not resolve_cmd("ip"):
        missing.append("ip")
    if not resolve_cmd("tc"):
        missing.append("tc")
    if not resolve_cmd("modprobe", "/usr/sbin/modprobe", "/sbin/modprobe"):
        missing.append("modprobe")
    if missing:
        raise RuntimeError(f"Missing command(s): {', '.join(missing)}")


def ensure_ifb(ifb_iface: str) -> None:
    modprobe_cmd = resolve_cmd("modprobe", "/usr/sbin/modprobe", "/sbin/modprobe")
    if not modprobe_cmd:
        raise RuntimeError("Missing command: modprobe")
    run([modprobe_cmd, "ifb"], check=False)
    run(["ip", "link", "add", ifb_iface, "type", "ifb"], check=False)
    run(["ip", "link", "set", ifb_iface, "up"], check=True)


def flush_tc(iface: str, ifb_iface: str) -> None:
    run(["tc", "qdisc", "del", "dev", iface, "root"], check=False)
    run(["tc", "qdisc", "del", "dev", iface, "ingress"], check=False)
    run(["tc", "qdisc", "del", "dev", ifb_iface, "root"], check=False)


def mbit_text(value: float) -> str:
    num = float(value)
    if abs(num - int(num)) < 1e-9:
        return f"{int(num)}mbit"
    return f"{num:.3f}mbit"


def iface_exists(name: str) -> bool:
    proc = subprocess.run(
        ["ip", "link", "show", "dev", name],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return proc.returncode == 0


def parse_status(status_file: Path) -> list[dict]:
    entries: list[dict] = []
    try:
        lines = status_file.read_text(encoding="utf-8", errors="replace").splitlines()
    except Exception:
        return entries
    section = ""
    for raw in lines:
        line = raw.strip()
        if not line:
            continue
        if line == "ROUTING TABLE":
            section = "routing"
            continue
        if line.startswith("HEADER,ROUTING_TABLE,"):
            section = "routing_v2"
            continue
        if line == "GLOBAL STATS":
            break
        if line.startswith("GLOBAL_STATS,"):
            break
        if section != "routing":
            if section != "routing_v2":
                continue
        if section == "routing":
            if line.startswith("Virtual Address,"):
                continue
            parts = [part.strip() for part in line.split(",")]
            if len(parts) < 2:
                continue
            virt = parts[0]
            common_name = parts[1]
        else:
            if line.startswith("ROUTING_TABLE,"):
                parts = [part.strip() for part in line.split(",")]
                if len(parts) < 3:
                    continue
                virt = parts[1]
                common_name = parts[2]
            else:
                continue
        try:
            ip = ipaddress.ip_address(virt)
        except Exception:
            continue
        entries.append({
            "virtual_ip": str(ip),
            "common_name": common_name,
        })
    return entries


def load_client_cn_map(clients_dir: Path) -> dict[str, str]:
    mapping: dict[str, str] = {}
    if not clients_dir.is_dir():
        return mapping
    for fp in sorted(clients_dir.glob("*.json"), key=lambda item: item.name.lower()):
        if fp.name.startswith("."):
            continue
        data = load_json(fp, default={}) or {}
        if not isinstance(data, dict):
            continue
        username = norm_user(data.get("client_name") or fp.stem)
        client_cn = str(data.get("client_cn") or "").strip()
        if username and client_cn:
            mapping[client_cn] = username
    return mapping


def load_unified_speed_policy(state_root: Path, username: str) -> dict | None:
    path = state_root / f"{username}.json"
    data = load_json(path, default={}) or {}
    if not isinstance(data, dict):
        return None
    policy = data.get("policy") if isinstance(data.get("policy"), dict) else {}
    if not policy:
        return None
    speed_enabled = to_bool(policy.get("speed_limit_enabled"))
    speed_down = max(0.0, to_float(policy.get("speed_down_mbit"), 0.0))
    speed_up = max(0.0, to_float(policy.get("speed_up_mbit"), 0.0))
    if not speed_enabled or (speed_down <= 0 and speed_up <= 0):
        return None
    return {
        "username": username,
        "speed_enabled": True,
        "speed_down_mbit": speed_down,
        "speed_up_mbit": speed_up,
    }


def build_snapshot(env: dict[str, str]) -> dict:
    tun_iface = str(env.get("OVPN_SPEED_TUN_IFACE") or "tun0").strip() or "tun0"
    ifb_iface = str(env.get("OVPN_SPEED_IFB_IFACE") or "ifb2").strip() or "ifb2"
    state_file = str(env.get("OVPN_SPEED_STATE_FILE") or "/var/lib/openvpn/speed-state.json").strip() or "/var/lib/openvpn/speed-state.json"
    status_file = Path(str(env.get("OVPN_STATUS_FILE") or "/var/log/openvpn/ovpn-tcp-status.log").strip() or "/var/log/openvpn/ovpn-tcp-status.log")
    clients_dir = Path(str(env.get("OVPN_CLIENTS_DIR") or "/etc/openvpn/clients").strip() or "/etc/openvpn/clients")
    unified_root = Path(str(env.get("UNIFIED_QAC_ROOT") or "/opt/quota/ssh-ovpn").strip() or "/opt/quota/ssh-ovpn")
    default_rate = max(1000.0, to_float(env.get("OVPN_SPEED_DEFAULT_RATE_MBIT"), 10000.0))

    cn_map = load_client_cn_map(clients_dir)
    active = parse_status(status_file)
    policies = []
    for entry in active:
        common_name = str(entry.get("common_name") or "").strip()
        virtual_ip = str(entry.get("virtual_ip") or "").strip()
        if not common_name or not virtual_ip:
            continue
        username = cn_map.get(common_name) or norm_user(common_name)
        if not username:
            continue
        policy = load_unified_speed_policy(unified_root, username)
        if not policy:
            continue
        policies.append({
            "username": username,
            "client_cn": common_name,
            "virtual_ip": virtual_ip,
            "speed_down_mbit": max(0.0, to_float(policy.get("speed_down_mbit"), 0.0)),
            "speed_up_mbit": max(0.0, to_float(policy.get("speed_up_mbit"), 0.0)),
        })
    policies.sort(key=lambda item: (item["username"].lower(), item["virtual_ip"]))
    return {
        "tun_iface": tun_iface,
        "ifb_iface": ifb_iface,
        "state_file": state_file,
        "default_rate_mbit": default_rate,
        "policies": policies,
    }


def apply_tc(snapshot: dict) -> list[dict]:
    tun_iface = snapshot["tun_iface"]
    ifb_iface = snapshot["ifb_iface"]
    policies = snapshot["policies"]
    default_rate = snapshot["default_rate_mbit"]

    if not iface_exists(tun_iface):
        raise RuntimeError(f"Interface {tun_iface} tidak ditemukan.")

    if not policies:
        if tc_is_speed_managed(tun_iface, ifb_iface):
            flush_tc(tun_iface, ifb_iface)
        return []

    ensure_ifb(ifb_iface)
    flush_tc(tun_iface, ifb_iface)

    default_rate_text = mbit_text(default_rate)
    run(["tc", "qdisc", "replace", "dev", tun_iface, "root", "handle", "30:", "htb", "default", "999"], check=True)
    run(["tc", "class", "replace", "dev", tun_iface, "parent", "30:", "classid", "30:999", "htb", "rate", default_rate_text, "ceil", default_rate_text], check=True)
    run(["tc", "qdisc", "replace", "dev", tun_iface, "parent", "30:999", "handle", "3099:", "fq_codel"], check=False)

    run(["tc", "qdisc", "replace", "dev", tun_iface, "handle", "ffff:", "ingress"], check=True)
    run(
        ["tc", "filter", "replace", "dev", tun_iface, "parent", "ffff:", "protocol", "ip", "u32", "match", "u32", "0", "0", "action", "mirred", "egress", "redirect", "dev", ifb_iface],
        check=True,
    )

    run(["tc", "qdisc", "replace", "dev", ifb_iface, "root", "handle", "31:", "htb", "default", "999"], check=True)
    run(["tc", "class", "replace", "dev", ifb_iface, "parent", "31:", "classid", "31:999", "htb", "rate", default_rate_text, "ceil", default_rate_text], check=True)
    run(["tc", "qdisc", "replace", "dev", ifb_iface, "parent", "31:999", "handle", "3199:", "fq_codel"], check=False)

    applied: list[dict] = []
    minor = 100
    for policy in policies:
        if minor > 4094:
            break
        vip = policy["virtual_ip"]
        down = max(0.0, to_float(policy.get("speed_down_mbit"), 0.0))
        up = max(0.0, to_float(policy.get("speed_up_mbit"), 0.0))
        class_out = f"30:{minor}"
        class_in = f"31:{minor}"
        qh_out = f"{minor + 3000}:"
        qh_in = f"{minor + 4000}:"
        if down > 0:
            down_text = mbit_text(down)
            run(["tc", "class", "replace", "dev", tun_iface, "parent", "30:", "classid", class_out, "htb", "rate", down_text, "ceil", down_text], check=True)
            run(["tc", "qdisc", "replace", "dev", tun_iface, "parent", class_out, "handle", qh_out, "fq_codel"], check=False)
            run(["tc", "filter", "replace", "dev", tun_iface, "parent", "30:", "protocol", "ip", "prio", "10", "u32", "match", "ip", "dst", f"{vip}/32", "flowid", class_out], check=True)
        if up > 0:
            up_text = mbit_text(up)
            run(["tc", "class", "replace", "dev", ifb_iface, "parent", "31:", "classid", class_in, "htb", "rate", up_text, "ceil", up_text], check=True)
            run(["tc", "qdisc", "replace", "dev", ifb_iface, "parent", class_in, "handle", qh_in, "fq_codel"], check=False)
            run(["tc", "filter", "replace", "dev", ifb_iface, "parent", "31:", "protocol", "ip", "prio", "10", "u32", "match", "ip", "src", f"{vip}/32", "flowid", class_in], check=True)
        applied.append({
            "username": policy["username"],
            "client_cn": policy["client_cn"],
            "virtual_ip": vip,
            "speed_down_mbit": down,
            "speed_up_mbit": up,
        })
        minor += 1

    return applied


def write_state(state_file: str, payload: dict) -> None:
    save_json_atomic(
        state_file,
        {
            "updated_at": now_iso(),
            **payload,
        },
    )


def apply_snapshot(snapshot: dict, dry_run=False) -> int:
    state_file = snapshot["state_file"]
    if dry_run:
        write_state(state_file, {
            "ok": True,
            "dry_run": True,
            "tun_iface": snapshot["tun_iface"],
            "ifb_iface": snapshot["ifb_iface"],
            "policy_count": len(snapshot["policies"]),
            "applied": snapshot["policies"],
        })
        return 0

    ensure_deps()
    applied = apply_tc(snapshot)
    write_state(state_file, {
        "ok": True,
        "dry_run": False,
        "tun_iface": snapshot["tun_iface"],
        "ifb_iface": snapshot["ifb_iface"],
        "default_rate_mbit": snapshot["default_rate_mbit"],
        "policy_count": len(applied),
        "applied": applied,
    })
    return 0


def run_once(env_file: str, dry_run=False) -> int:
    env = load_env(env_file)
    snapshot = build_snapshot(env)
    return apply_snapshot(snapshot, dry_run=dry_run)


def run_watch(env_file: str, interval: int) -> int:
    sleep_s = max(2, int(interval))
    last_signature = ""
    while True:
        env = load_env(env_file)
        state_file = str(env.get("OVPN_SPEED_STATE_FILE") or "/var/lib/openvpn/speed-state.json")
        try:
            snapshot = build_snapshot(env)
            signature = json.dumps(snapshot, sort_keys=True, ensure_ascii=False)
            if signature != last_signature:
                apply_snapshot(snapshot, dry_run=False)
                last_signature = signature
        except Exception as exc:
            try:
                write_state(state_file, {
                    "ok": False,
                    "error": str(exc),
                })
            except Exception:
                pass
        time.sleep(sleep_s)


def show_status(env_file: str) -> int:
    env = load_env(env_file)
    state_file = str(env.get("OVPN_SPEED_STATE_FILE") or "/var/lib/openvpn/speed-state.json")
    payload = load_json(state_file, default={}) or {}
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0


def do_flush(env_file: str) -> int:
    env = load_env(env_file)
    snapshot = build_snapshot(env)
    tun_iface = snapshot["tun_iface"]
    ifb_iface = snapshot["ifb_iface"]
    ensure_deps()
    if iface_exists(tun_iface) and tc_is_speed_managed(tun_iface, ifb_iface):
        flush_tc(tun_iface, ifb_iface)
    write_state(snapshot["state_file"], {
        "ok": True,
        "flushed": True,
        "tun_iface": tun_iface,
        "ifb_iface": ifb_iface,
    })
    return 0


def parse_args():
    ap = argparse.ArgumentParser(prog="openvpn-speed")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_once = sub.add_parser("once")
    p_once.add_argument("--env-file", default="/etc/default/openvpn-runtime")
    p_once.add_argument("--dry-run", action="store_true")

    p_watch = sub.add_parser("watch")
    p_watch.add_argument("--env-file", default="/etc/default/openvpn-runtime")
    p_watch.add_argument("--interval", type=int, default=5)

    p_status = sub.add_parser("status")
    p_status.add_argument("--env-file", default="/etc/default/openvpn-runtime")

    p_flush = sub.add_parser("flush")
    p_flush.add_argument("--env-file", default="/etc/default/openvpn-runtime")
    return ap.parse_args()


def main() -> int:
    args = parse_args()
    if args.cmd == "once":
        return run_once(args.env_file, dry_run=args.dry_run)
    if args.cmd == "watch":
        return run_watch(args.env_file, args.interval)
    if args.cmd == "status":
        return show_status(args.env_file)
    if args.cmd == "flush":
        return do_flush(args.env_file)
    return 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(0)
    except Exception as exc:
        sys.stderr.write(f"openvpn-speed: {exc}\n")
        raise SystemExit(1)
