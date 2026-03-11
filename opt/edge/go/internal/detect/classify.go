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
	ClassSSH
	ClassVLESSRaw
	ClassTrojanRaw
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

func IsSSHBanner(b []byte) bool {
	trimmed := bytes.TrimLeft(b, "\r\n\t ")
	return bytes.HasPrefix(trimmed, []byte("SSH-"))
}

func IsVLESSRequest(b []byte) bool {
	if len(b) < 24 {
		return false
	}
	version := b[0]
	if version != 0x00 && version != 0x01 {
		return false
	}
	uuid := b[1:17]
	allZero := true
	for _, v := range uuid {
		if v != 0x00 {
			allZero = false
			break
		}
	}
	if allZero {
		return false
	}
	addonsLen := int(b[17])
	pos := 18 + addonsLen
	if len(b) < pos+4 {
		return false
	}
	command := b[pos]
	if command != 0x01 && command != 0x02 && command != 0x03 {
		return false
	}
	pos++
	if len(b) < pos+2+1 {
		return false
	}
	pos += 2 // port
	addrType := b[pos]
	pos++
	switch addrType {
	case 0x01:
		return len(b) >= pos+4
	case 0x02:
		if len(b) < pos+1 {
			return false
		}
		addrLen := int(b[pos])
		pos++
		return addrLen > 0 && len(b) >= pos+addrLen
	case 0x03:
		return len(b) >= pos+16
	default:
		return false
	}
}

func IsTrojanRequest(b []byte) bool {
	if len(b) < 58 {
		return false
	}
	for i := 0; i < 56; i++ {
		ch := b[i]
		switch {
		case ch >= '0' && ch <= '9':
		case ch >= 'a' && ch <= 'f':
		case ch >= 'A' && ch <= 'F':
		default:
			return false
		}
	}
	if b[56] != '\r' || b[57] != '\n' {
		return false
	}
	return true
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
			case IsSSHBanner(current):
				return current, ClassSSH, nil
			case IsTrojanRequest(current):
				return current, ClassTrojanRaw, nil
			case IsVLESSRequest(current):
				return current, ClassVLESSRaw, nil
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
				case IsSSHBanner(current):
					return current, ClassSSH, nil
				case IsTrojanRequest(current):
					return current, ClassTrojanRaw, nil
				case IsVLESSRequest(current):
					return current, ClassVLESSRaw, nil
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
	case IsSSHBanner(current):
		return current, ClassSSH, nil
	case IsTrojanRequest(current):
		return current, ClassTrojanRaw, nil
	case IsVLESSRequest(current):
		return current, ClassVLESSRaw, nil
	case IsPossibleHTTPPrefix(current):
		return current, ClassPossibleHTTP, nil
	default:
		return current, ClassUnknown, nil
	}
}
