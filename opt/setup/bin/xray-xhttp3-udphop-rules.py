#!/usr/bin/env python3
import argparse
import os
import subprocess
import sys

ENV_FILE = os.environ.get("XRAY_XHTTP3_UDPHOP_ENV_FILE", "/etc/default/xray-xhttp3-udphop")
RULE_COMMENT = "autoscript-xray-xhttp3-udphop"


def load_env(path: str) -> dict[str, str]:
    data: dict[str, str] = {}
    if not path or not os.path.isfile(path):
        return data
    with open(path, "r", encoding="utf-8") as handle:
        for raw in handle:
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            data[key.strip()] = value.strip().strip('"').strip("'")
    return data


def normalize_specs(raw: str) -> list[str]:
    specs: list[str] = []
    for chunk in str(raw or "").split(","):
        part = chunk.strip()
        if not part:
            continue
        if "-" in part:
            start, end = part.split("-", 1)
            start = start.strip()
            end = end.strip()
            if start.isdigit() and end.isdigit():
                specs.append(f"{start}:{end}")
        elif part.isdigit():
            specs.append(part)
    return specs


def iptables(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["iptables", *args],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def ensure_rule(spec: str, iface: str, listen_port: str) -> None:
    check = iptables(
        "-t", "nat", "-C", "PREROUTING",
        "-i", iface,
        "-p", "udp",
        "--dport", spec,
        "-m", "comment", "--comment", RULE_COMMENT,
        "-j", "REDIRECT", "--to-ports", listen_port,
    )
    if check.returncode == 0:
        return
    add = iptables(
        "-t", "nat", "-A", "PREROUTING",
        "-i", iface,
        "-p", "udp",
        "--dport", spec,
        "-m", "comment", "--comment", RULE_COMMENT,
        "-j", "REDIRECT", "--to-ports", listen_port,
    )
    if add.returncode != 0:
        raise RuntimeError(add.stderr.strip() or f"failed to add rule for {spec}")


def delete_rule(spec: str, iface: str, listen_port: str) -> None:
    while True:
        delete = iptables(
            "-t", "nat", "-D", "PREROUTING",
            "-i", iface,
            "-p", "udp",
            "--dport", spec,
            "-m", "comment", "--comment", RULE_COMMENT,
            "-j", "REDIRECT", "--to-ports", listen_port,
        )
        if delete.returncode != 0:
            break


def show_status(specs: list[str], iface: str, listen_port: str) -> int:
    active = False
    for spec in specs:
        check = iptables(
            "-t", "nat", "-C", "PREROUTING",
            "-i", iface,
            "-p", "udp",
            "--dport", spec,
            "-m", "comment", "--comment", RULE_COMMENT,
            "-j", "REDIRECT", "--to-ports", listen_port,
        )
        if check.returncode == 0:
            active = True
            break
    print(f"ACTIVE={'yes' if active else 'no'}")
    print(f"IFACE={iface}")
    print(f"PORT={listen_port}")
    print(f"UDPHOP_PORTS={','.join(specs)}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("apply", "delete", "status"))
    parser.add_argument("--iface", default="")
    parser.add_argument("--port", default="")
    parser.add_argument("--ports", default="")
    parser.add_argument("--env-file", default=ENV_FILE)
    args = parser.parse_args()

    env = load_env(args.env_file)
    iface = args.iface or env.get("XRAY_XHTTP3_UDPHOP_IFACE") or ""
    listen_port = args.port or env.get("XRAY_XHTTP3_UDPHOP_LISTEN_PORT") or "443"
    raw_ports = args.ports or env.get("XRAY_XHTTP3_UDPHOP_PORTS") or ""
    specs = normalize_specs(raw_ports)

    if not iface:
        raise SystemExit("missing iface")
    if not specs:
        raise SystemExit("missing udpHop ports")

    if args.action == "status":
        return show_status(specs, iface, listen_port)
    if args.action == "apply":
        for spec in specs:
            ensure_rule(spec, iface, listen_port)
        return 0
    for spec in specs:
        delete_rule(spec, iface, listen_port)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as exc:
        print(str(exc), file=sys.stderr)
        raise SystemExit(1)
