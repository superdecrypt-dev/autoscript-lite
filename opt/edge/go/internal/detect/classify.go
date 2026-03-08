package detect

import (
	"bytes"
	"errors"
	"io"
	"net"
	"time"
)

const MaxPeekBytes = 4096

var httpMethods = [][]byte{
	[]byte("GET "),
	[]byte("POST "),
	[]byte("HEAD "),
	[]byte("PUT "),
	[]byte("OPTIONS "),
	[]byte("DELETE "),
	[]byte("PATCH "),
	[]byte("CONNECT "),
	[]byte("PRI * HTTP/2.0"),
}

func IsHTTP(b []byte) bool {
	trimmed := bytes.TrimLeft(b, "\r\n\t ")
	for _, method := range httpMethods {
		if bytes.HasPrefix(trimmed, method) {
			return true
		}
	}
	return false
}

func IsTLSClientHello(b []byte) bool {
	if len(b) < 3 {
		return false
	}
	return b[0] == 0x16 && b[1] == 0x03 && b[2] <= 0x04
}

func ReadInitial(conn net.Conn, timeout time.Duration, maxBytes int) ([]byte, bool, error) {
	if maxBytes <= 0 {
		maxBytes = MaxPeekBytes
	}
	if err := conn.SetReadDeadline(time.Now().Add(timeout)); err != nil {
		return nil, false, err
	}
	defer conn.SetReadDeadline(time.Time{})

	buf := make([]byte, maxBytes)
	n, err := conn.Read(buf)
	if err != nil {
		if ne, ok := err.(net.Error); ok && ne.Timeout() {
			return nil, true, nil
		}
		if errors.Is(err, io.EOF) {
			return nil, false, io.EOF
		}
		return nil, false, err
	}
	return buf[:n], false, nil
}
