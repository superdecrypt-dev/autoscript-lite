#!/usr/bin/env python3
import argparse
import os
import socket
import time


DEFAULT_HOST = os.environ.get("OPENVPN_MANAGEMENT_HOST") or "127.0.0.1"
DEFAULT_PORT = int(float(os.environ.get("OPENVPN_MANAGEMENT_PORT") or "21194"))


def norm_user(value: str) -> str:
  text = str(value or "").strip()
  if text.endswith("@ssh"):
    text = text[:-4]
  if "@" in text:
    text = text.split("@", 1)[0]
  return text


def recv_until(sock: socket.socket, marker: bytes, timeout: float = 3.0) -> bytes:
  sock.settimeout(timeout)
  chunks = bytearray()
  while marker not in chunks:
    chunk = sock.recv(4096)
    if not chunk:
      break
    chunks.extend(chunk)
  return bytes(chunks)


def management_command(host: str, port: int, command: str) -> str:
  with socket.create_connection((host, port), timeout=3.0) as sock:
    recv_until(sock, b"\n", timeout=3.0)
    sock.sendall((command.rstrip() + "\n").encode("utf-8"))
    time.sleep(0.1)
    response = recv_until(sock, b"\n", timeout=3.0).decode("utf-8", errors="ignore")
    try:
      sock.sendall(b"quit\n")
    except Exception:
      pass
    return response


def kill_user(host: str, port: int, username: str) -> int:
  user = norm_user(username)
  if not user:
    return 0
  response = management_command(host, port, f"kill {user}")
  text = str(response or "").strip()
  if text.startswith("SUCCESS:"):
    return 0
  if "client not found" in text.lower():
    return 0
  return 1


def main() -> int:
  p = argparse.ArgumentParser(description="Kill active OpenVPN session by username via management interface")
  p.add_argument("--host", default=DEFAULT_HOST)
  p.add_argument("--port", type=int, default=DEFAULT_PORT)
  p.add_argument("--user", required=True)
  args = p.parse_args()
  return kill_user(str(args.host or "").strip() or DEFAULT_HOST, int(args.port), args.user)


if __name__ == "__main__":
  raise SystemExit(main())
