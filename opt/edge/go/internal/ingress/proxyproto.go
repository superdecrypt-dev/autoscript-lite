package ingress

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"strings"
	"time"
)

var (
	errUntrustedProxyProtocol = errors.New("untrusted PROXY protocol source")
	proxyV2Signature          = []byte{'\r', '\n', '\r', '\n', 0x00, '\r', '\n', 'Q', 'U', 'I', 'T', '\n'}
)

type peerConn struct {
	net.Conn
	reader *bufio.Reader
	remote net.Addr
}

func (c *peerConn) Read(p []byte) (int, error) {
	if c.reader == nil {
		return c.Conn.Read(p)
	}
	return c.reader.Read(p)
}

func (c *peerConn) RemoteAddr() net.Addr {
	if c.remote != nil {
		return c.remote
	}
	return c.Conn.RemoteAddr()
}

func Wrap(conn net.Conn, acceptProxy bool, trustedCIDRs []string, timeout time.Duration) (net.Conn, error) {
	if conn == nil {
		return nil, errors.New("nil conn")
	}
	reader := bufio.NewReaderSize(conn, 4096)
	wrapped := &peerConn{Conn: conn, reader: reader}
	if !acceptProxy {
		return wrapped, nil
	}

	if timeout > 0 {
		_ = conn.SetReadDeadline(time.Now().Add(timeout))
		defer conn.SetReadDeadline(time.Time{})
	}

	peek, err := reader.Peek(1)
	if err != nil {
		if ne, ok := err.(net.Error); ok && ne.Timeout() {
			return wrapped, nil
		}
		if errors.Is(err, io.EOF) {
			return wrapped, nil
		}
		return nil, err
	}

	switch peek[0] {
	case 'P':
		return wrapProxyV1(wrapped, trustedCIDRs)
	case '\r':
		return wrapProxyV2(wrapped, trustedCIDRs)
	default:
		return wrapped, nil
	}
}

func wrapProxyV1(conn *peerConn, trustedCIDRs []string) (net.Conn, error) {
	head, err := conn.reader.Peek(6)
	if err != nil {
		if ne, ok := err.(net.Error); ok && ne.Timeout() {
			return conn, nil
		}
		if errors.Is(err, io.EOF) {
			return conn, nil
		}
		return nil, err
	}
	if !bytes.Equal(head, []byte("PROXY ")) {
		return conn, nil
	}
	if !isTrustedProxyPeer(conn.Conn.RemoteAddr(), trustedCIDRs) {
		return nil, errUntrustedProxyProtocol
	}
	line, err := conn.reader.ReadString('\n')
	if err != nil {
		return nil, err
	}
	addr, err := parseProxyV1(line)
	if err != nil {
		return nil, err
	}
	if addr != nil {
		conn.remote = addr
	}
	return conn, nil
}

func wrapProxyV2(conn *peerConn, trustedCIDRs []string) (net.Conn, error) {
	head, err := conn.reader.Peek(len(proxyV2Signature))
	if err != nil {
		if ne, ok := err.(net.Error); ok && ne.Timeout() {
			return conn, nil
		}
		if errors.Is(err, io.EOF) {
			return conn, nil
		}
		return nil, err
	}
	if !bytes.Equal(head, proxyV2Signature) {
		return conn, nil
	}
	if !isTrustedProxyPeer(conn.Conn.RemoteAddr(), trustedCIDRs) {
		return nil, errUntrustedProxyProtocol
	}

	header := make([]byte, 16)
	if _, err := io.ReadFull(conn.reader, header); err != nil {
		return nil, err
	}
	length := int(binary.BigEndian.Uint16(header[14:16]))
	payload := make([]byte, length)
	if _, err := io.ReadFull(conn.reader, payload); err != nil {
		return nil, err
	}
	addr, err := parseProxyV2(header, payload)
	if err != nil {
		return nil, err
	}
	if addr != nil {
		conn.remote = addr
	}
	return conn, nil
}

func parseProxyV1(line string) (net.Addr, error) {
	text := strings.TrimSpace(line)
	parts := strings.Fields(text)
	if len(parts) < 2 || parts[0] != "PROXY" {
		return nil, fmt.Errorf("invalid PROXY v1 header")
	}
	if parts[1] == "UNKNOWN" {
		return nil, nil
	}
	if len(parts) != 6 {
		return nil, fmt.Errorf("invalid PROXY v1 field count")
	}
	switch parts[1] {
	case "TCP4", "TCP6":
	default:
		return nil, fmt.Errorf("unsupported PROXY v1 transport %q", parts[1])
	}
	ip := net.ParseIP(parts[2])
	if ip == nil {
		return nil, fmt.Errorf("invalid PROXY v1 source IP %q", parts[2])
	}
	port, err := parsePort(parts[4])
	if err != nil {
		return nil, err
	}
	return &net.TCPAddr{IP: ip, Port: port}, nil
}

func parseProxyV2(header, payload []byte) (net.Addr, error) {
	if len(header) < 16 {
		return nil, fmt.Errorf("invalid PROXY v2 header")
	}
	version := header[12] >> 4
	command := header[12] & 0x0f
	if version != 0x2 {
		return nil, fmt.Errorf("invalid PROXY v2 version %d", version)
	}
	if command == 0x0 {
		return nil, nil
	}
	if command != 0x1 {
		return nil, fmt.Errorf("unsupported PROXY v2 command %d", command)
	}
	family := header[13] >> 4
	switch family {
	case 0x1:
		if len(payload) < 12 {
			return nil, fmt.Errorf("short PROXY v2 IPv4 payload")
		}
		ip := net.IP(payload[0:4])
		port := int(binary.BigEndian.Uint16(payload[8:10]))
		return &net.TCPAddr{IP: ip, Port: port}, nil
	case 0x2:
		if len(payload) < 36 {
			return nil, fmt.Errorf("short PROXY v2 IPv6 payload")
		}
		ip := net.IP(payload[0:16])
		port := int(binary.BigEndian.Uint16(payload[32:34]))
		return &net.TCPAddr{IP: ip, Port: port}, nil
	default:
		return nil, nil
	}
}

func isTrustedProxyPeer(addr net.Addr, trustedCIDRs []string) bool {
	ip := extractIP(addr)
	if ip == nil {
		return false
	}
	for _, raw := range trustedCIDRs {
		cidr := strings.TrimSpace(raw)
		if cidr == "" {
			continue
		}
		if !strings.Contains(cidr, "/") {
			if peer := net.ParseIP(cidr); peer != nil && peer.Equal(ip) {
				return true
			}
			continue
		}
		if _, network, err := net.ParseCIDR(cidr); err == nil && network.Contains(ip) {
			return true
		}
	}
	return false
}

func extractIP(addr net.Addr) net.IP {
	if addr == nil {
		return nil
	}
	switch v := addr.(type) {
	case *net.TCPAddr:
		return v.IP
	case *net.UDPAddr:
		return v.IP
	}
	host, _, err := net.SplitHostPort(addr.String())
	if err != nil {
		host = addr.String()
	}
	host = strings.Trim(host, "[]")
	return net.ParseIP(host)
}

func parsePort(raw string) (int, error) {
	text := strings.TrimSpace(raw)
	if text == "" {
		return 0, fmt.Errorf("empty port")
	}
	var port int
	_, err := fmt.Sscanf(text, "%d", &port)
	if err != nil || port < 0 || port > 65535 {
		return 0, fmt.Errorf("invalid port %q", raw)
	}
	return port, nil
}
