#!/usr/bin/env python3
import logging
import os
import select
import socket
import ssl
import struct
import threading


LISTEN_HOST = os.getenv("WARP_ZT_BRIDGE_LISTEN_HOST", "127.0.0.1")
LISTEN_PORT = int(os.getenv("WARP_ZT_BRIDGE_LISTEN_PORT", "40001"))
UPSTREAM_HOST = os.getenv("WARP_ZT_BRIDGE_UPSTREAM_HOST", "127.0.0.1")
UPSTREAM_PORT = int(os.getenv("WARP_ZT_BRIDGE_UPSTREAM_PORT", "40000"))
DOH_HOST = os.getenv("WARP_ZT_BRIDGE_DOH_HOST", "dns.google")
DOH_PORT = int(os.getenv("WARP_ZT_BRIDGE_DOH_PORT", "443"))
DOH_PATH = os.getenv("WARP_ZT_BRIDGE_DOH_PATH", "/dns-query")
BUFFER = 65535


def recv_exact(sock, size):
    data = bytearray()
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise ConnectionError("unexpected EOF")
        data.extend(chunk)
    return bytes(data)


def parse_socks_addr(data, offset=0):
    atyp = data[offset]
    offset += 1
    if atyp == 1:
        host = socket.inet_ntoa(data[offset:offset + 4])
        offset += 4
    elif atyp == 3:
        size = data[offset]
        offset += 1
        host = data[offset:offset + size].decode()
        offset += size
    elif atyp == 4:
        host = socket.inet_ntop(socket.AF_INET6, data[offset:offset + 16])
        offset += 16
    else:
        raise ValueError(f"unsupported atyp {atyp}")
    port = struct.unpack("!H", data[offset:offset + 2])[0]
    offset += 2
    return host, port, offset


def build_socks_addr(host, port):
    try:
        return b"\x01" + socket.inet_aton(host) + struct.pack("!H", port)
    except OSError:
        pass
    try:
        return b"\x04" + socket.inet_pton(socket.AF_INET6, host) + struct.pack("!H", port)
    except OSError:
        pass
    encoded = host.encode()
    if len(encoded) > 255:
        raise ValueError("domain too long")
    return b"\x03" + bytes([len(encoded)]) + encoded + struct.pack("!H", port)


def drain_socks_reply(sock, atyp):
    if atyp == 1:
        recv_exact(sock, 6)
    elif atyp == 3:
        size = recv_exact(sock, 1)[0]
        recv_exact(sock, size + 2)
    elif atyp == 4:
        recv_exact(sock, 18)
    else:
        raise ConnectionError(f"upstream invalid atyp={atyp}")


def upstream_negotiate(dest_host, dest_port, cmd=1):
    upstream = socket.create_connection((UPSTREAM_HOST, UPSTREAM_PORT), timeout=10)
    upstream.sendall(b"\x05\x01\x00")
    if recv_exact(upstream, 2) != b"\x05\x00":
        raise ConnectionError("upstream auth failed")
    upstream.sendall(b"\x05" + bytes([cmd]) + b"\x00" + build_socks_addr(dest_host, dest_port))
    head = recv_exact(upstream, 4)
    if head[:2] != b"\x05\x00":
        raise ConnectionError(f"upstream rejected cmd={cmd} code={head[1]}")
    drain_socks_reply(upstream, head[3])
    upstream.settimeout(None)
    return upstream


def relay_stream(src, dst):
    try:
        while True:
            data = src.recv(BUFFER)
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


def doh_query_via_upstream(payload):
    upstream = upstream_negotiate(DOH_HOST, DOH_PORT, cmd=1)
    try:
        tls = ssl.create_default_context().wrap_socket(upstream, server_hostname=DOH_HOST)
        req = (
            f"POST {DOH_PATH} HTTP/1.1\r\n"
            f"Host: {DOH_HOST}\r\n"
            "Content-Type: application/dns-message\r\n"
            "Accept: application/dns-message\r\n"
            f"Content-Length: {len(payload)}\r\n"
            "Connection: close\r\n\r\n"
        ).encode() + payload
        tls.sendall(req)
        response = bytearray()
        while True:
            chunk = tls.recv(BUFFER)
            if not chunk:
                break
            response.extend(chunk)
        _, _, body = bytes(response).partition(b"\r\n\r\n")
        if not body:
            raise ConnectionError("empty DoH response")
        return body
    finally:
        try:
            upstream.close()
        except Exception:
            pass


def handle_udp_associate(client, bind_host):
    udp_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp_sock.bind((bind_host, 0))
    bind_port = udp_sock.getsockname()[1]
    client.sendall(b"\x05\x00\x00" + build_socks_addr(bind_host, bind_port))
    logging.info("udp associate ready on %s:%s", bind_host, bind_port)
    try:
        while True:
            readable, _, _ = select.select([client, udp_sock], [], [], 1.0)
            if not readable:
                continue
            if client in readable and not client.recv(1):
                return
            if udp_sock not in readable:
                continue
            packet, client_addr = udp_sock.recvfrom(BUFFER)
            if len(packet) < 10 or packet[2] != 0:
                continue
            dst_host, dst_port, offset = parse_socks_addr(packet, 3)
            if dst_port != 53:
                logging.info("drop unsupported UDP target %s:%s", dst_host, dst_port)
                continue
            payload = packet[offset:]
            try:
                response = doh_query_via_upstream(payload)
            except Exception as exc:
                logging.warning("DoH query failed for %s:%s: %s", dst_host, dst_port, exc)
                continue
            udp_sock.sendto(b"\x00\x00\x00" + build_socks_addr(dst_host, dst_port) + response, client_addr)
    finally:
        udp_sock.close()


def handle_client(client, addr):
    try:
        client.settimeout(10)
        ver, nmethods = recv_exact(client, 2)
        if ver != 5:
            raise ConnectionError("invalid version")
        recv_exact(client, nmethods)
        client.sendall(b"\x05\x00")

        ver, cmd, _, atyp = recv_exact(client, 4)
        if ver != 5:
            raise ConnectionError("invalid request version")
        if atyp == 1:
            host = socket.inet_ntoa(recv_exact(client, 4))
        elif atyp == 3:
            host = recv_exact(client, recv_exact(client, 1)[0]).decode()
        elif atyp == 4:
            host = socket.inet_ntop(socket.AF_INET6, recv_exact(client, 16))
        else:
            client.sendall(b"\x05\x08\x00\x01\x00\x00\x00\x00\x00\x00")
            return
        port = struct.unpack("!H", recv_exact(client, 2))[0]
        client.settimeout(None)

        if cmd == 1:
            upstream = upstream_negotiate(host, port, cmd=1)
            client.sendall(b"\x05\x00\x00" + build_socks_addr("0.0.0.0", 0))
            t1 = threading.Thread(target=relay_stream, args=(client, upstream), daemon=True)
            t2 = threading.Thread(target=relay_stream, args=(upstream, client), daemon=True)
            t1.start()
            t2.start()
            t1.join()
            t2.join()
            upstream.close()
            return

        if cmd == 3:
            handle_udp_associate(client, LISTEN_HOST)
            return

        client.sendall(b"\x05\x07\x00\x01\x00\x00\x00\x00\x00\x00")
    except Exception as exc:
        logging.debug("client %s failed: %s", addr, exc)
        try:
            client.sendall(b"\x05\x01\x00\x01\x00\x00\x00\x00\x00\x00")
        except Exception:
            pass
    finally:
        try:
            client.close()
        except Exception:
            pass


def main():
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((LISTEN_HOST, LISTEN_PORT))
    server.listen(256)
    logging.info(
        "listening on %s:%s upstream=%s:%s doh=%s:%s%s",
        LISTEN_HOST, LISTEN_PORT, UPSTREAM_HOST, UPSTREAM_PORT, DOH_HOST, DOH_PORT, DOH_PATH,
    )
    while True:
        client, addr = server.accept()
        threading.Thread(target=handle_client, args=(client, addr), daemon=True).start()


if __name__ == "__main__":
    main()
