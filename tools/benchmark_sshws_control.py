#!/usr/bin/env python3
import argparse
import importlib.util
import json
import shutil
import statistics
import subprocess
import tempfile
import time
from pathlib import Path


def load_helper(helper_path: Path):
    spec = importlib.util.spec_from_file_location("sshws_control_bench", str(helper_path))
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def percentile(values, p):
    if not values:
        return 0.0
    ordered = sorted(values)
    if len(ordered) == 1:
        return float(ordered[0])
    idx = (len(ordered) - 1) * p
    lo = int(idx)
    hi = min(lo + 1, len(ordered) - 1)
    frac = idx - lo
    return float(ordered[lo] * (1.0 - frac) + ordered[hi] * frac)


def time_calls(fn, iterations):
    samples = []
    for _ in range(iterations):
        start = time.perf_counter()
        fn()
        samples.append((time.perf_counter() - start) * 1000.0)
    return {
        "iterations": iterations,
        "mean_ms": round(statistics.fmean(samples), 3),
        "median_ms": round(statistics.median(samples), 3),
        "p95_ms": round(percentile(samples, 0.95), 3),
        "min_ms": round(min(samples), 3),
        "max_ms": round(max(samples), 3),
    }


def build_fixture(mod, state_root: Path, session_root: Path, users: int, sessions_per_user: int):
    state_root.mkdir(parents=True, exist_ok=True)
    session_root.mkdir(parents=True, exist_ok=True)
    port = 20000
    tokens = []
    for idx in range(users):
        username = f"user{idx:05d}"
        token = f"{idx:010x}"[-10:]
        tokens.append((username, token))
        payload = {
            "username": username,
            "sshws_token": token,
            "quota_limit": 200 * 1024 * 1024 * 1024,
            "quota_used": 64 * 1024 * 1024,
            "status": {
                "manual_block": False,
                "quota_exhausted": False,
                "ip_limit_enabled": True,
                "ip_limit": max(2, sessions_per_user + 2),
                "ip_limit_locked": False,
                "account_locked": False,
                "speed_limit_enabled": True,
                "speed_down_mbit": 50,
                "speed_up_mbit": 25,
                "lock_reason": "",
            },
        }
        mod.write_json_atomic(state_root / f"{username}@ssh.json", payload, 0o600)
        for sess in range(sessions_per_user):
            session_payload = {
                "backend_local_port": port,
                "backend": "dropbear",
                "backend_target": "127.0.0.1:22022",
                "transport": "ssh-ws",
                "source": "sshws-proxy",
                "proxy_pid": 1,
                "created_at": int(time.time()),
                "updated_at": int(time.time()),
                "username": username,
                "client_ip": f"10.{idx // 250}.{idx % 250}.{sess + 1}",
            }
            mod.write_json_atomic(session_root / f"{port}.json", session_payload, 0o600)
            port += 1
    return tokens


def main():
    parser = argparse.ArgumentParser(description="Benchmark sshws-control helper")
    parser.add_argument("--users", type=int, default=500)
    parser.add_argument("--sessions-per-user", type=int, default=4)
    parser.add_argument("--iterations", type=int, default=100)
    parser.add_argument("--keep-fixture", action="store_true")
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parent.parent
    helper_path = repo_root / "opt" / "setup" / "bin" / "sshws-control.py"
    mod = load_helper(helper_path)

    tmpdir = Path(tempfile.mkdtemp(prefix="sshws-control-bench."))
    state_root = tmpdir / "state"
    session_root = tmpdir / "sessions"
    tokens = build_fixture(mod, state_root, session_root, args.users, args.sessions_per_user)
    target_user, target_token = tokens[len(tokens) // 2]
    target_path = f"/bench/{target_token}"

    admission_args = argparse.Namespace(
        path=target_path,
        expected_prefix="/bench",
        state_root=str(state_root),
        session_root=str(session_root),
        client_ip="203.0.113.10",
        extra_total=0,
        extra_client_ips="",
    )
    subprocess_cmd = [
        "python3",
        str(helper_path),
        "admission",
        "--path",
        target_path,
        "--expected-prefix",
        "/bench",
        "--state-root",
        str(state_root),
        "--session-root",
        str(session_root),
        "--client-ip",
        "203.0.113.10",
        "--extra-total",
        "0",
        "--extra-client-ips",
        "",
    ]

    # Warmup
    mod.resolve_token(str(state_root), target_token)
    mod.runtime_session_stats(str(session_root), target_user)
    mod.cmd_admission(admission_args)
    subprocess.run(subprocess_cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    results = {
        "fixture": {
            "users": args.users,
            "sessions_per_user": args.sessions_per_user,
            "target_user": target_user,
            "target_token": target_token,
        },
        "benchmarks": {
            "resolve_token_direct": time_calls(lambda: mod.resolve_token(str(state_root), target_token), args.iterations),
            "runtime_session_stats_direct": time_calls(
                lambda: mod.runtime_session_stats(str(session_root), target_user, []), args.iterations
            ),
            "cmd_admission_direct": time_calls(lambda: mod.cmd_admission(admission_args), args.iterations),
            "cmd_admission_subprocess": time_calls(
                lambda: subprocess.run(
                    subprocess_cmd,
                    check=True,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                ),
                args.iterations,
            ),
        },
    }

    print(json.dumps(results, ensure_ascii=False, indent=2))

    if args.keep_fixture:
        print(json.dumps({"fixture_root": str(tmpdir)}, ensure_ascii=False))
    else:
        shutil.rmtree(tmpdir, ignore_errors=True)


if __name__ == "__main__":
    main()
