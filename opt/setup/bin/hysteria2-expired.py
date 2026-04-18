#!/usr/bin/env python3
import argparse
import subprocess
import sys
import time


def parse_key_value(blob: str) -> dict[str, str]:
    data: dict[str, str] = {}
    for line in blob.splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        data[key.strip()] = value.strip()
    return data


def run_manage_prune(manage_bin: str) -> tuple[int, dict[str, str], str]:
    result = subprocess.run(
        [manage_bin, "prune-expired"],
        capture_output=True,
        check=False,
        text=True,
    )
    payload = (result.stdout or "").strip()
    if result.returncode != 0:
        detail = (result.stderr or payload or f"rc={result.returncode}").strip()
        return result.returncode, {}, detail
    return 0, parse_key_value(payload), payload


def restart_service(service: str) -> None:
    result = subprocess.run(
        ["systemctl", "restart", service],
        capture_output=True,
        check=False,
        text=True,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or f"rc={result.returncode}").strip()
        raise RuntimeError(f"restart {service} gagal: {detail}")


def run_loop(manage_bin: str, service: str, interval: int) -> int:
    while True:
        rc, data, detail = run_manage_prune(manage_bin)
        if rc != 0:
            print(f"[hysteria2-expired] prune gagal: {detail}", file=sys.stderr, flush=True)
            time.sleep(interval)
            continue

        removed_count = int(data.get("REMOVED_COUNT", "0") or "0")
        removed_users = data.get("REMOVED_USERS", "")
        if removed_count > 0:
            print(
                f"[hysteria2-expired] removed={removed_count} users={removed_users or '-'}",
                flush=True,
            )
            try:
                restart_service(service)
            except RuntimeError as exc:
                print(f"[hysteria2-expired] {exc}", file=sys.stderr, flush=True)
                return 1

        time.sleep(interval)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manage-bin", default="/usr/local/bin/hysteria2-manage")
    parser.add_argument("--service", default="xray.service")
    parser.add_argument("--interval", type=int, default=60)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    if args.interval < 1:
        raise SystemExit("--interval minimal 1 detik")
    return run_loop(args.manage_bin, args.service, args.interval)


if __name__ == "__main__":
    sys.exit(main())
