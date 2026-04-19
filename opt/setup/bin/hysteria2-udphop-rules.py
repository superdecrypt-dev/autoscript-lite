#!/usr/bin/env python3
import shlex
import subprocess
import sys
from pathlib import Path


ENV_FILE = Path("/etc/autoscript/hysteria2/config.env")
COMMENT = "autoscript-hy2-udphop"


def load_env() -> dict[str, str]:
    env: dict[str, str] = {}
    if not ENV_FILE.exists():
        return env
    for line in ENV_FILE.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        key, value = stripped.split("=", 1)
        env[key.strip()] = value.strip()
    return env


def run(args: list[str], check: bool = True) -> subprocess.CompletedProcess:
    result = subprocess.run(args, capture_output=True, check=False, text=True)
    if check and result.returncode != 0:
        detail = (result.stderr or result.stdout or f"rc={result.returncode}").strip()
        raise SystemExit(detail)
    return result


def rule_args(port: str, hop_ports: str) -> list[str]:
    if "," in hop_ports:
        port_args = ["-m", "multiport", "--dports", hop_ports]
    elif "-" in hop_ports:
        port_args = ["-m", "udp", "--dport", hop_ports.replace("-", ":")]
    else:
        port_args = ["-m", "udp", "--dport", hop_ports]
    return [
        "-p",
        "udp",
        *port_args,
        "-m",
        "comment",
        "--comment",
        COMMENT,
        "-j",
        "REDIRECT",
        "--to-ports",
        port,
    ]


def existing_prerouting_rules() -> list[list[str]]:
    result = run(["iptables", "-t", "nat", "-S", "PREROUTING"])
    items: list[list[str]] = []
    for line in result.stdout.splitlines():
        if COMMENT not in line:
            continue
        args = shlex.split(line)
        if not args or args[0] != "-A":
            continue
        args[0] = "-D"
        items.append(args)
    return items


def remove_rules() -> None:
    for item in existing_prerouting_rules():
        run(["iptables", "-t", "nat", *item], check=False)


def apply_rules() -> None:
    env = load_env()
    port = str(env.get("HYSTERIA2_PORT", "443")).strip() or "443"
    hop_ports = str(env.get("HYSTERIA2_UDPHOP_PORTS", "20000-40000")).strip() or "20000-40000"
    public_iface = str(env.get("HYSTERIA2_PUBLIC_IFACE", "")).strip()
    remove_rules()
    args = rule_args(port, hop_ports)
    if public_iface:
        args = ["-i", public_iface, *args]
    check_args = ["iptables", "-t", "nat", "-C", "PREROUTING", *args]
    if run(check_args, check=False).returncode == 0:
        return
    run(["iptables", "-t", "nat", "-A", "PREROUTING", *args])


def status() -> None:
    env = load_env()
    port = str(env.get("HYSTERIA2_PORT", "443")).strip() or "443"
    hop_ports = str(env.get("HYSTERIA2_UDPHOP_PORTS", "20000-40000")).strip() or "20000-40000"
    public_iface = str(env.get("HYSTERIA2_PUBLIC_IFACE", "")).strip()
    args = rule_args(port, hop_ports)
    if public_iface:
        args = ["-i", public_iface, *args]
    active = run(["iptables", "-t", "nat", "-C", "PREROUTING", *args], check=False).returncode == 0
    print(f"ACTIVE={'yes' if active else 'no'}")
    print(f"PORT={port}")
    print(f"UDPHOP_PORTS={hop_ports}")
    print(f"PUBLIC_IFACE={public_iface or '-'}")


def main() -> int:
    action = (sys.argv[1] if len(sys.argv) > 1 else "status").strip().lower()
    if action == "apply":
        apply_rules()
        return 0
    if action == "remove":
        remove_rules()
        return 0
    if action == "status":
        status()
        return 0
    raise SystemExit("usage: hysteria2-udphop-rules.py [apply|remove|status]")


if __name__ == "__main__":
    sys.exit(main())
