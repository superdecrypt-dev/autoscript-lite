package routing

import (
	"bytes"
	"net/url"
	"strings"
)

type HTTPRequest struct {
	Method         string
	Path           string
	Host           string
	Version        string
	Upgrade        string
	Connection     string
	IsHTTP2Preface bool
}

var knownRouteNames = map[string]struct{}{
	"vless-ws":     {},
	"vmess-ws":     {},
	"trojan-ws":    {},
	"vless-hup":    {},
	"vless-xhttp":  {},
	"vmess-hup":    {},
	"vmess-xhttp":  {},
	"trojan-hup":   {},
	"trojan-xhttp": {},
	"vless-grpc":   {},
	"vmess-grpc":   {},
	"trojan-grpc":  {},
}

const diagnosticProbeToken = "diagnostic-probe"

func ParseHTTPRequest(initial []byte) (HTTPRequest, bool) {
	lines := bytes.Split(initial, []byte{'\n'})
	if len(lines) == 0 {
		return HTTPRequest{}, false
	}
	requestLine := strings.TrimSpace(strings.TrimRight(string(lines[0]), "\r"))
	fields := strings.Fields(requestLine)
	if len(fields) < 3 {
		return HTTPRequest{}, false
	}
	req := HTTPRequest{
		Method:  fields[0],
		Path:    normalizeTargetPath(fields[1]),
		Version: fields[2],
	}
	if req.Method == "PRI" && fields[1] == "*" && fields[2] == "HTTP/2.0" {
		req.IsHTTP2Preface = true
		req.Path = "/"
		return req, true
	}
	for _, raw := range lines[1:] {
		line := strings.TrimSpace(strings.TrimRight(string(raw), "\r"))
		if line == "" {
			break
		}
		key, value, ok := strings.Cut(line, ":")
		if !ok {
			continue
		}
		key = strings.ToLower(strings.TrimSpace(key))
		value = strings.TrimSpace(value)
		switch key {
		case "host":
			req.Host = value
		case "upgrade":
			req.Upgrade = strings.ToLower(value)
		case "connection":
			req.Connection = strings.ToLower(value)
		}
	}
	return req, true
}

func RouteLabel(req HTTPRequest, alpn string) string {
	if req.IsHTTP2Preface {
		if strings.EqualFold(alpn, "h2") {
			return "http2"
		}
		return "http2-preface"
	}
	if strings.EqualFold(req.Method, "CONNECT") {
		return "connect"
	}
	if name := knownRouteFromPath(req.Path); name != "" {
		return name
	}
	if isWebSocketRequest(req) {
		if looksLikeSSHWSPath(req.Path) {
			return "ssh-ws-like"
		}
		return "websocket-other"
	}
	if strings.EqualFold(alpn, "h2") {
		return "http2"
	}
	if req.Path == "" || req.Path == "/" {
		return "root"
	}
	return "http-other"
}

func normalizeTargetPath(target string) string {
	target = strings.TrimSpace(target)
	if target == "" {
		return "/"
	}
	if strings.HasPrefix(target, "http://") || strings.HasPrefix(target, "https://") {
		if u, err := url.Parse(target); err == nil {
			if u.Path != "" {
				return u.EscapedPath()
			}
			return "/"
		}
	}
	if strings.HasPrefix(target, "/") {
		if u, err := url.ParseRequestURI(target); err == nil {
			if u.Path != "" {
				return u.EscapedPath()
			}
		}
	}
	return target
}

func knownRouteFromPath(path string) string {
	segments := pathSegments(path)
	if len(segments) == 0 {
		return ""
	}
	if _, ok := knownRouteNames[segments[0]]; ok {
		return segments[0]
	}
	if len(segments) >= 2 {
		if _, ok := knownRouteNames[segments[1]]; ok {
			return segments[1]
		}
	}
	return ""
}

func pathSegments(path string) []string {
	raw := strings.TrimSpace(path)
	if raw == "" || raw == "/" {
		return nil
	}
	parts := strings.Split(strings.Trim(raw, "/"), "/")
	out := make([]string, 0, len(parts))
	for _, part := range parts {
		text := strings.TrimSpace(part)
		if text != "" {
			out = append(out, text)
		}
	}
	return out
}

func isWebSocketRequest(req HTTPRequest) bool {
	if req.Upgrade == "websocket" {
		return true
	}
	return strings.Contains(req.Connection, "upgrade") && strings.Contains(req.Upgrade, "websocket")
}

func looksLikeSSHWSPath(path string) bool {
	segments := pathSegments(path)
	if len(segments) == 0 || len(segments) > 2 {
		return false
	}
	last := segments[len(segments)-1]
	if last == diagnosticProbeToken {
		return true
	}
	if len(last) < 8 {
		return false
	}
	for _, ch := range last {
		switch {
		case ch >= 'a' && ch <= 'f':
		case ch >= 'A' && ch <= 'F':
		case ch >= '0' && ch <= '9':
		default:
			return false
		}
	}
	return true
}
