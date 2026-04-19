#!/usr/bin/env python3
import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path


def parse_key_value(blob: str) -> dict[str, str]:
    data: dict[str, str] = {}
    for line in blob.splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        data[key.strip()] = value.strip()
    return data


def parse_systemctl_show(blob: str) -> dict[str, str]:
    data: dict[str, str] = {}
    for line in blob.splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        data[key.strip()] = value.strip()
    return data


def parse_csv(blob: str) -> list[str]:
    result: list[str] = []
    for item in (blob or "").split(","):
        value = item.strip()
        if value:
            result.append(value)
    return result


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


def xray_service_active(service: str) -> bool:
    result = subprocess.run(
        ["systemctl", "show", "-p", "ActiveState", service],
        capture_output=True,
        check=False,
        text=True,
    )
    data = parse_systemctl_show(result.stdout or "")
    return data.get("ActiveState") == "active"


def validate_confdir(confdir: str) -> None:
    result = subprocess.run(
        ["xray", "-test", "-confdir", confdir],
        capture_output=True,
        check=False,
        text=True,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or f"rc={result.returncode}").strip()
        raise RuntimeError(f"validasi confdir gagal: {detail}")


def load_state(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
    except Exception:
        return {}


def save_state(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


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


def remove_users_via_api(api_server: str, inbound_tag: str, emails: list[str]) -> None:
    if not emails:
        return
    result = subprocess.run(
        ["xray", "api", "rmu", f"--server={api_server}", f"-tag={inbound_tag}", *emails],
        capture_output=True,
        check=False,
        text=True,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or f"rc={result.returncode}").strip()
        raise RuntimeError(f"hapus user via xray api gagal: {detail}")


def request_restart(service: str, confdir: str, cooldown: int, state_file: Path) -> bool:
    state = load_state(state_file)
    now = int(time.time())
    last_restart = int(state.get("last_restart") or 0)
    state["pending_restart"] = True
    state["service"] = service
    if cooldown > 0 and last_restart > 0 and now - last_restart < cooldown:
        save_state(state_file, state)
        return False
    validate_confdir(confdir)
    if xray_service_active(service):
        restart_service(service)
    state["last_restart"] = now
    state["pending_restart"] = False
    save_state(state_file, state)
    return True


def run_loop(
    manage_bin: str,
    service: str,
    interval: int,
    confdir: str,
    restart_cooldown: int,
    state_file: Path,
    api_server: str,
    inbound_tag: str,
) -> int:
    while True:
        state = load_state(state_file)
        if state.get("pending_restart"):
            try:
                request_restart(service, confdir, restart_cooldown, state_file)
            except RuntimeError as exc:
                print(f"[hysteria2-expired] {exc}", file=sys.stderr, flush=True)
                return 1

        rc, data, detail = run_manage_prune(manage_bin)
        if rc != 0:
            print(f"[hysteria2-expired] prune gagal: {detail}", file=sys.stderr, flush=True)
            time.sleep(interval)
            continue

        removed_count = int(data.get("REMOVED_COUNT", "0") or "0")
        removed_users = data.get("REMOVED_USERS", "")
        removed_emails = parse_csv(data.get("REMOVED_EMAILS", ""))
        if removed_count > 0:
            print(
                f"[hysteria2-expired] removed={removed_count} users={removed_users or '-'}",
                flush=True,
            )
            try:
                api_synced = False
                if removed_emails:
                    try:
                        remove_users_via_api(api_server, inbound_tag, removed_emails)
                        api_synced = True
                        print(
                            f"[hysteria2-expired] runtime synced via xray api tag={inbound_tag}",
                            flush=True,
                        )
                    except RuntimeError as exc:
                        print(f"[hysteria2-expired] {exc}", file=sys.stderr, flush=True)
                if not api_synced:
                    did_restart = request_restart(service, confdir, restart_cooldown, state_file)
                    if not did_restart:
                        print(
                            f"[hysteria2-expired] restart ditunda cooldown={restart_cooldown}s",
                            flush=True,
                        )
            except RuntimeError as exc:
                print(f"[hysteria2-expired] {exc}", file=sys.stderr, flush=True)
                return 1

        time.sleep(interval)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manage-bin", default="/usr/local/bin/hysteria2-manage")
    parser.add_argument("--service", default="xray.service")
    parser.add_argument("--interval", type=int, default=60)
    parser.add_argument("--confdir", default="/usr/local/etc/xray/conf.d")
    parser.add_argument("--restart-cooldown", type=int, default=300)
    parser.add_argument("--state-file", default="/var/lib/autoscript/hysteria2-expired/state.json")
    parser.add_argument("--api-server", default="127.0.0.1:10080")
    parser.add_argument("--inbound-tag", default="hy2-in")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    if args.interval < 1:
        raise SystemExit("--interval minimal 1 detik")
    if args.restart_cooldown < 0:
        raise SystemExit("--restart-cooldown minimal 0 detik")
    return run_loop(
        args.manage_bin,
        args.service,
        args.interval,
        args.confdir,
        args.restart_cooldown,
        Path(args.state_file),
        args.api_server,
        args.inbound_tag,
    )


if __name__ == "__main__":
    sys.exit(main())
