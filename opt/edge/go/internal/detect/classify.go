package detect

import (
	"bytes"
	"errors"
	"io"
	"net"
	"time"
)

const MaxPeekBytes = 4096

type InitialClass int

const (
	ClassUnknown InitialClass = iota
	ClassHTTP
	ClassTLSClientHello
	ClassTimeout
	ClassPossibleHTTP
)

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

func IsPossibleHTTPPrefix(b []byte) bool {
	trimmed := bytes.TrimLeft(b, "\r\n\t ")
	if len(trimmed) == 0 {
		return true
	}
	for _, method := range httpMethods {
		if len(trimmed) <= len(method) && bytes.HasPrefix(method, trimmed) {
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

func ReadInitial(conn net.Conn, timeout time.Duration, maxBytes int) ([]byte, InitialClass, error) {
	if maxBytes <= 0 {
		maxBytes = MaxPeekBytes
	}
	if err := conn.SetReadDeadline(time.Now().Add(timeout)); err != nil {
		return nil, ClassUnknown, err
	}
	defer conn.SetReadDeadline(time.Time{})

	buf := make([]byte, maxBytes)
	used := 0
	for used < len(buf) {
		n, err := conn.Read(buf[used:])
		if n > 0 {
			used += n
			current := buf[:used]
			switch {
			case IsHTTP(current):
				return current, ClassHTTP, nil
			case IsTLSClientHello(current):
				return current, ClassTLSClientHello, nil
			case IsPossibleHTTPPrefix(current):
				continue
			default:
				return current, ClassUnknown, nil
			}
		}
		if err != nil {
			if ne, ok := err.(net.Error); ok && ne.Timeout() {
				if used == 0 {
					return nil, ClassTimeout, nil
				}
				current := buf[:used]
				if IsPossibleHTTPPrefix(current) {
					return current, ClassPossibleHTTP, nil
				}
				return current, ClassTimeout, nil
			}
			if errors.Is(err, io.EOF) {
				if used == 0 {
					return nil, ClassUnknown, io.EOF
				}
				current := buf[:used]
				switch {
				case IsHTTP(current):
					return current, ClassHTTP, nil
				case IsTLSClientHello(current):
					return current, ClassTLSClientHello, nil
				case IsPossibleHTTPPrefix(current):
					return current, ClassPossibleHTTP, nil
				default:
					return current, ClassUnknown, nil
				}
			}
			return nil, ClassUnknown, err
		}
	}
	current := buf[:used]
	switch {
	case IsHTTP(current):
		return current, ClassHTTP, nil
	case IsTLSClientHello(current):
		return current, ClassTLSClientHello, nil
	case IsPossibleHTTPPrefix(current):
		return current, ClassPossibleHTTP, nil
	default:
		return current, ClassUnknown, nil
	}
}
