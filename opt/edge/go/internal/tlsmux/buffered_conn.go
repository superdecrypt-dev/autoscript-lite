package tlsmux

import (
	"bytes"
	"net"
)

type bufferedConn struct {
	net.Conn
	prefix *bytes.Reader
}

func (c *bufferedConn) Read(p []byte) (int, error) {
	if c.prefix != nil && c.prefix.Len() > 0 {
		return c.prefix.Read(p)
	}
	return c.Conn.Read(p)
}

func withPrefix(conn net.Conn, prefix []byte) net.Conn {
	if len(prefix) == 0 {
		return conn
	}
	return &bufferedConn{
		Conn:   conn,
		prefix: bytes.NewReader(prefix),
	}
}
