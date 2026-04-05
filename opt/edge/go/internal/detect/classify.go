package detect

import (
	"bytes"
	"errors"
	"io"
	"net"
	"strings"
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

func tlsClientHelloRecordLength(b []byte) (int, bool) {
	if !IsTLSClientHello(b) || len(b) < 5 {
		return 0, false
	}
	recordLen := int(b[3])<<8 | int(b[4])
	if recordLen <= 0 {
		return 0, false
	}
	return 5 + recordLen, true
}

func ExtractTLSServerName(b []byte) (string, bool) {
	if !IsTLSClientHello(b) || len(b) < 5 {
		return "", false
	}
	recordLen := int(b[3])<<8 | int(b[4])
	if recordLen <= 0 || len(b) < 5+recordLen {
		return "", false
	}
	record := b[5 : 5+recordLen]
	if len(record) < 4 || record[0] != 0x01 {
		return "", false
	}
	handshakeLen := int(record[1])<<16 | int(record[2])<<8 | int(record[3])
	if handshakeLen <= 0 || len(record) < 4+handshakeLen {
		return "", false
	}
	body := record[4 : 4+handshakeLen]
	if len(body) < 2+32+1 {
		return "", false
	}
	pos := 2 + 32
	sessionIDLen := int(body[pos])
	pos++
	if len(body) < pos+sessionIDLen+2 {
		return "", false
	}
	pos += sessionIDLen
	cipherSuitesLen := int(body[pos])<<8 | int(body[pos+1])
	pos += 2
	if cipherSuitesLen == 0 || cipherSuitesLen%2 != 0 || len(body) < pos+cipherSuitesLen+1 {
		return "", false
	}
	pos += cipherSuitesLen
	compressionMethodsLen := int(body[pos])
	pos++
	if compressionMethodsLen == 0 || len(body) < pos+compressionMethodsLen+2 {
		return "", false
	}
	pos += compressionMethodsLen
	extensionsLen := int(body[pos])<<8 | int(body[pos+1])
	pos += 2
	if extensionsLen == 0 || len(body) < pos+extensionsLen {
		return "", false
	}
	extensions := body[pos : pos+extensionsLen]
	for len(extensions) >= 4 {
		extType := int(extensions[0])<<8 | int(extensions[1])
		extLen := int(extensions[2])<<8 | int(extensions[3])
		extensions = extensions[4:]
		if len(extensions) < extLen {
			return "", false
		}
		extData := extensions[:extLen]
		extensions = extensions[extLen:]
		if extType != 0x0000 || len(extData) < 2 {
			continue
		}
		serverNameListLen := int(extData[0])<<8 | int(extData[1])
		if serverNameListLen == 0 || len(extData) < 2+serverNameListLen {
			return "", false
		}
		names := extData[2 : 2+serverNameListLen]
		for len(names) >= 3 {
			nameType := names[0]
			nameLen := int(names[1])<<8 | int(names[2])
			names = names[3:]
			if len(names) < nameLen {
				return "", false
			}
			if nameType == 0 {
				serverName := strings.ToLower(strings.TrimSuffix(string(names[:nameLen]), "."))
				if serverName != "" {
					return serverName, true
				}
				return "", false
			}
			names = names[nameLen:]
		}
	}
	return "", false
}

func IsSSHBanner(b []byte) bool {
	trimmed := bytes.TrimLeft(b, "\r\n\t ")
	return bytes.HasPrefix(trimmed, []byte("SSH-"))
}

func allBytesZero(b []byte) bool {
	for _, v := range b {
		if v != 0x00 {
			return false
		}
	}
	return true
}

func isRFC4122UUID(b []byte) bool {
	if len(b) != 16 {
		return false
	}
	if allBytesZero(b) {
		return false
	}
	version := b[6] >> 4
	if version < 1 || version > 8 {
		return false
	}
	return b[8]&0xc0 == 0x80
}

func isValidDomainName(b []byte) bool {
	if len(b) == 0 || len(b) > 253 {
		return false
	}
	labelLen := 0
	last := byte(0)
	for i, ch := range b {
		switch {
		case (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9'):
			labelLen++
		case ch == '-':
			if i == 0 || i == len(b)-1 || last == '.' {
				return false
			}
			labelLen++
		case ch == '.':
			if i == 0 || i == len(b)-1 || last == '.' || last == '-' || labelLen == 0 || labelLen > 63 {
				return false
			}
			labelLen = 0
		default:
			return false
		}
		last = ch
	}
	return labelLen > 0 && labelLen <= 63 && last != '-'
}

func isASCIIHex(b []byte) bool {
	for _, ch := range b {
		switch {
		case ch >= '0' && ch <= '9':
		case ch >= 'a' && ch <= 'f':
		case ch >= 'A' && ch <= 'F':
		default:
			return false
		}
	}
	return true
}

func IsVLESSRequest(b []byte) bool {
	if len(b) < 24 {
		return false
	}
	version := b[0]
	if version != 0x00 {
		return false
	}
	uuid := b[1:17]
	if !isRFC4122UUID(uuid) {
		return false
	}
	addonsLen := int(b[17])
	if addonsLen > 255 {
		return false
	}
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
	port := int(b[pos])<<8 | int(b[pos+1])
	if port <= 0 {
		return false
	}
	pos += 2
	addrType := b[pos]
	pos++
	switch addrType {
	case 0x01:
		if len(b) < pos+4 {
			return false
		}
		return !allBytesZero(b[pos : pos+4])
	case 0x02:
		if len(b) < pos+1 {
			return false
		}
		addrLen := int(b[pos])
		pos++
		if addrLen == 0 || len(b) < pos+addrLen {
			return false
		}
		return isValidDomainName(b[pos : pos+addrLen])
	case 0x03:
		if len(b) < pos+16 {
			return false
		}
		return !allBytesZero(b[pos : pos+16])
	default:
		return false
	}
}

func IsTrojanRequest(b []byte) bool {
	if len(b) < 64 {
		return false
	}
	if !isASCIIHex(b[:56]) {
		return false
	}
	if b[56] != '\r' || b[57] != '\n' {
		return false
	}
	pos := 58
	if len(b) < pos+1+1+2 {
		return false
	}
	command := b[pos]
	if command != 0x01 && command != 0x03 {
		return false
	}
	pos++
	addrType := b[pos]
	pos++
	switch addrType {
	case 0x01:
		if len(b) < pos+4+2+2 {
			return false
		}
		if allBytesZero(b[pos : pos+4]) {
			return false
		}
		pos += 4
	case 0x03:
		if len(b) < pos+1 {
			return false
		}
		addrLen := int(b[pos])
		pos++
		if addrLen == 0 || len(b) < pos+addrLen+2+2 {
			return false
		}
		if !isValidDomainName(b[pos : pos+addrLen]) {
			return false
		}
		pos += addrLen
	case 0x04:
		if len(b) < pos+16+2+2 {
			return false
		}
		if allBytesZero(b[pos : pos+16]) {
			return false
		}
		pos += 16
	default:
		return false
	}
	port := int(b[pos])<<8 | int(b[pos+1])
	if port <= 0 {
		return false
	}
	pos += 2
	return len(b) >= pos+2 && b[pos] == '\r' && b[pos+1] == '\n'
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
				if totalLen, ok := tlsClientHelloRecordLength(current); !ok || len(current) < totalLen {
					continue
				}
				return current, ClassTLSClientHello, nil
			case IsSSHBanner(current):
				return current, ClassSSH, nil
			case IsVLESSRequest(current):
				return current, ClassVLESSRaw, nil
			case IsTrojanRequest(current):
				return current, ClassTrojanRaw, nil
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
					if totalLen, ok := tlsClientHelloRecordLength(current); ok && len(current) >= totalLen {
						return current, ClassTLSClientHello, nil
					}
					return current, ClassTimeout, nil
				case IsSSHBanner(current):
					return current, ClassSSH, nil
				case IsVLESSRequest(current):
					return current, ClassVLESSRaw, nil
				case IsTrojanRequest(current):
					return current, ClassTrojanRaw, nil
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
		if totalLen, ok := tlsClientHelloRecordLength(current); ok && len(current) >= totalLen {
			return current, ClassTLSClientHello, nil
		}
		return current, ClassTimeout, nil
	case IsSSHBanner(current):
		return current, ClassSSH, nil
	case IsVLESSRequest(current):
		return current, ClassVLESSRaw, nil
	case IsTrojanRequest(current):
		return current, ClassTrojanRaw, nil
	case IsPossibleHTTPPrefix(current):
		return current, ClassPossibleHTTP, nil
	default:
		return current, ClassUnknown, nil
	}
}
