#!/usr/bin/env python3
import argparse
import asyncio
import json
import re
from pathlib import Path
from urllib.parse import urlsplit

OVPNWS_TOKEN_RE = re.compile(r"^[a-f0-9]{10}$")
RESERVED_PATH_PARTS = {
  "vless-ws",
  "vmess-ws",
  "trojan-ws",
  "shadowsocks-ws",
  "shadowsocks2022-ws",
  "ss-ws",
  "ss2022-ws",
  "vless-hup",
  "vmess-hup",
  "trojan-hup",
  "shadowsocks-hup",
  "shadowsocks2022-hup",
  "ss-hup",
  "ss2022-hup",
  "vless-grpc",
  "vmess-grpc",
  "trojan-grpc",
  "shadowsocks-grpc",
  "shadowsocks2022-grpc",
  "ss-grpc",
  "ss2022-grpc",
  "openvpn-ws",
}


class HandshakeError(Exception):
  def __init__(self, code, reason):
    super().__init__(reason)
    self.code = code
    self.reason = reason


async def _send_http_error(writer, code, reason):
  body = f"{code} {reason}\n".encode("utf-8")
  resp = (
    f"HTTP/1.1 {code} {reason}\r\n"
    "Content-Type: text/plain\r\n"
    f"Content-Length: {len(body)}\r\n"
    "Connection: close\r\n"
    "\r\n"
  ).encode("ascii")
  writer.write(resp + body)
  await writer.drain()


def _normalize_path_prefix(value):
  text = str(value or "/").split("?", 1)[0].split("#", 1)[0] or "/"
  text = "/" + text.lstrip("/")
  if len(text) > 1:
    text = text.rstrip("/")
  if not text or text == "/openvpn-ws":
    return "/"
  return text


def _normalize_token(value):
  token = str(value or "").strip().lower()
  if OVPNWS_TOKEN_RE.fullmatch(token):
    return token
  return ""


def _extract_token_from_path(path, expected_prefix):
  raw_path = str(path or "/").split("?", 1)[0].split("#", 1)[0] or "/"
  prefix = _normalize_path_prefix(expected_prefix)
  if prefix == "/":
    parts = [part for part in raw_path.split("/") if part]
    if not parts or len(parts) > 2:
      return ""
    if len(parts) == 2 and parts[0].lower() in RESERVED_PATH_PARTS:
      return ""
    return _normalize_token(parts[-1])
  wanted = prefix + "/"
  if not raw_path.startswith(wanted):
    return ""
  suffix = raw_path[len(wanted):].strip("/")
  if not suffix:
    return ""
  parts = [part for part in suffix.split("/") if part]
  if not parts or len(parts) > 2:
    return ""
  return _normalize_token(parts[-1])


def _resolve_token_path(target):
  if "://" in target:
    try:
      parsed = urlsplit(target)
      path = parsed.path or "/"
      if parsed.query:
        path = f"{path}?{parsed.query}"
      return path
    except Exception:
      return target
  return target


def _token_exists(token_root, token):
  tok = _normalize_token(token)
  if not tok:
    return False
  root = Path(token_root)
  if not root.is_dir():
    return False
  for path in sorted(root.glob("*.json"), key=lambda entry: entry.name.lower()):
    try:
      payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
      continue
    if not isinstance(payload, dict):
      continue
    if _normalize_token(payload.get("ovpnws_token")) == tok:
      return True
  return False


async def _read_handshake(reader, expected_path, token_root, timeout_sec):
  try:
    raw = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), timeout=timeout_sec)
  except asyncio.TimeoutError as exc:
    raise HandshakeError(408, "Request Timeout") from exc
  except (asyncio.IncompleteReadError, asyncio.LimitOverrunError) as exc:
    raise HandshakeError(400, "Bad Request") from exc

  try:
    text = raw.decode("latin1")
  except UnicodeDecodeError as exc:
    raise HandshakeError(400, "Bad Request") from exc

  lines = text.split("\r\n")
  if not lines or not lines[0]:
    raise HandshakeError(400, "Bad Request")

  req = lines[0].split()
  if len(req) < 3:
    raise HandshakeError(400, "Bad Request")
  method = req[0].upper()
  target = _resolve_token_path(req[1])
  path_only = _normalize_path_prefix(target)

  if method != "GET":
    raise HandshakeError(405, "Method Not Allowed")

  headers = {}
  for line in lines[1:]:
    if not line or ":" not in line:
      continue
    key, value = line.split(":", 1)
    headers[key.strip().lower()] = value.strip()

  if headers.get("upgrade", "").lower() != "websocket":
    raise HandshakeError(400, "Bad Request")

  token = _extract_token_from_path(path_only, expected_path)
  if not token:
    raise HandshakeError(404, "Not Found")
  if not _token_exists(token_root, token):
    raise HandshakeError(404, "Not Found")
  return path_only, token


async def _send_handshake_ok(writer):
  resp = (
    "HTTP/1.1 101 Switching Protocols\r\n"
    "Content-Length: 104857600000\r\n"
    "\r\n"
  ).encode("ascii")
  writer.write(resp)
  await writer.drain()


async def _pipe(reader, writer):
  while True:
    data = await reader.read(16384)
    if not data:
      break
    writer.write(data)
    await writer.drain()
  try:
    writer.close()
    await writer.wait_closed()
  except Exception:
    pass


async def _handle_client(client_reader, client_writer, args):
  try:
    await _read_handshake(client_reader, args.path, args.token_root, args.handshake_timeout)
  except HandshakeError as exc:
    try:
      await _send_http_error(client_writer, exc.code, exc.reason)
    finally:
      client_writer.close()
      await client_writer.wait_closed()
    return
  except Exception:
    try:
      await _send_http_error(client_writer, 400, "Bad Request")
    finally:
      client_writer.close()
      await client_writer.wait_closed()
    return

  try:
    backend_reader, backend_writer = await asyncio.open_connection(args.backend_host, args.backend_port)
  except Exception:
    try:
      await _send_http_error(client_writer, 502, "Bad Gateway")
    finally:
      client_writer.close()
      await client_writer.wait_closed()
    return

  try:
    await _send_handshake_ok(client_writer)
  except Exception:
    backend_writer.close()
    await backend_writer.wait_closed()
    client_writer.close()
    await client_writer.wait_closed()
    return

  try:
    await asyncio.gather(
      _pipe(client_reader, backend_writer),
      _pipe(backend_reader, client_writer),
    )
  finally:
    try:
      backend_writer.close()
      await backend_writer.wait_closed()
    except Exception:
      pass
    try:
      client_writer.close()
      await client_writer.wait_closed()
    except Exception:
      pass


def build_parser():
  parser = argparse.ArgumentParser(description="OpenVPN websocket proxy")
  parser.add_argument("--listen-host", default="127.0.0.1")
  parser.add_argument("--listen-port", type=int, required=True)
  parser.add_argument("--backend-host", default="127.0.0.1")
  parser.add_argument("--backend-port", type=int, required=True)
  parser.add_argument("--path", default="/")
  parser.add_argument("--token-root", default="/etc/openvpn/clients")
  parser.add_argument("--handshake-timeout", type=float, default=10.0)
  return parser


async def _run(args):
  server = await asyncio.start_server(
    lambda reader, writer: _handle_client(reader, writer, args),
    args.listen_host,
    args.listen_port,
    reuse_address=True,
  )
  async with server:
    await server.serve_forever()


def main():
  args = build_parser().parse_args()
  if args.listen_port <= 0 or args.backend_port <= 0:
    raise SystemExit("listen-port dan backend-port harus > 0")
  if args.handshake_timeout <= 0:
    raise SystemExit("handshake-timeout harus > 0")
  args.path = _normalize_path_prefix(args.path)
  asyncio.run(_run(args))


if __name__ == "__main__":
  main()
