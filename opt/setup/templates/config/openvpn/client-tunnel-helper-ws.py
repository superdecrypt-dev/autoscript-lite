#!/usr/bin/env python3
import socket
import ssl
import threading

LISTEN_HOST = "__LISTEN_HOST__"
LISTEN_PORT = __LISTEN_PORT__
REMOTE_HOST = "__REMOTE_HOST__"
REMOTE_PORT = __REMOTE_PORT__
SERVER_NAME = "__SERVER_NAME__"
WS_PATH = "__WS_PATH__"


def pipe(src, dst):
  try:
    while True:
      data = src.recv(65536)
      if not data:
        break
      dst.sendall(data)
  except Exception:
    pass
  finally:
    try:
      dst.shutdown(socket.SHUT_WR)
    except Exception:
      pass
    try:
      dst.close()
    except Exception:
      pass
    try:
      src.close()
    except Exception:
      pass


def handle_client(client_sock):
  upstream = None
  tls_sock = None
  try:
    upstream = socket.create_connection((REMOTE_HOST, REMOTE_PORT), timeout=10)
    ctx = ssl.create_default_context()
    tls_sock = ctx.wrap_socket(upstream, server_hostname=SERVER_NAME)
    request = (
      f"GET {WS_PATH} HTTP/1.1\r\n"
      f"Host: {SERVER_NAME}\r\n"
      "Upgrade: websocket\r\n"
      "Connection: Upgrade\r\n"
      "X-OVPN-WS: 1\r\n"
      "\r\n"
    ).encode("ascii")
    tls_sock.sendall(request)

    response = b""
    while b"\r\n\r\n" not in response:
      chunk = tls_sock.recv(4096)
      if not chunk:
        raise RuntimeError("empty websocket response")
      response += chunk
      if len(response) > 16384:
        raise RuntimeError("oversized websocket response")
    status_line = response.split(b"\r\n", 1)[0].decode("latin1", "replace")
    if "101" not in status_line:
      raise RuntimeError(status_line)

    _, tail = response.split(b"\r\n\r\n", 1)
    if tail:
      client_sock.sendall(tail)

    t1 = threading.Thread(target=pipe, args=(client_sock, tls_sock), daemon=True)
    t2 = threading.Thread(target=pipe, args=(tls_sock, client_sock), daemon=True)
    t1.start()
    t2.start()
    t1.join()
    t2.join()
  except Exception:
    try:
      client_sock.close()
    except Exception:
      pass
    try:
      if tls_sock is not None:
        tls_sock.close()
    except Exception:
      pass
    try:
      if upstream is not None:
        upstream.close()
    except Exception:
      pass


def main():
  server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
  server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
  server.bind((LISTEN_HOST, LISTEN_PORT))
  server.listen(16)
  try:
    while True:
      client_sock, _ = server.accept()
      threading.Thread(target=handle_client, args=(client_sock,), daemon=True).start()
  finally:
    server.close()


if __name__ == "__main__":
  main()
