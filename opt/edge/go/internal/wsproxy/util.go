package wsproxy

import (
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const (
	RuntimeSessionHeartbeat    = 15 * time.Second
	RuntimeSessionStaleDefault = 90 * time.Second
)

var tokenRe = regexp.MustCompile(`^[a-f0-9]{10}$`)

func NormalizeToken(v string) string {
	s := strings.ToLower(strings.TrimSpace(v))
	if tokenRe.MatchString(s) {
		return s
	}
	return ""
}

func NormUser(v string) string {
	s := strings.TrimSpace(v)
	if idx := strings.IndexByte(s, '@'); idx >= 0 {
		s = s[:idx]
	}
	return s
}

func NormalizeIP(v string) string {
	s := strings.TrimSpace(v)
	s = strings.TrimPrefix(s, "[")
	s = strings.TrimSuffix(s, "]")
	if ip := net.ParseIP(s); ip != nil {
		return ip.String()
	}
	return ""
}

func FirstNonEmpty(values ...string) string {
	for _, v := range values {
		if strings.TrimSpace(v) != "" {
			return strings.TrimSpace(v)
		}
	}
	return ""
}

func FilterEmpty(parts []string) []string {
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		if p != "" {
			out = append(out, p)
		}
	}
	return out
}

func ToBool(v interface{}) bool {
	switch x := v.(type) {
	case bool:
		return x
	case float64:
		return x != 0
	case int:
		return x != 0
	case int64:
		return x != 0
	case string:
		switch strings.ToLower(strings.TrimSpace(x)) {
		case "1", "true", "yes", "on", "y":
			return true
		}
	}
	return false
}

func ToString(v interface{}) string {
	switch x := v.(type) {
	case string:
		return x
	case json.Number:
		return x.String()
	case float64:
		return strconv.FormatFloat(x, 'f', -1, 64)
	case int:
		return strconv.Itoa(x)
	case int64:
		return strconv.FormatInt(x, 10)
	default:
		return fmt.Sprintf("%v", v)
	}
}

func ToInt(v interface{}) int {
	switch x := v.(type) {
	case int:
		return x
	case int64:
		return int(x)
	case float64:
		return int(x)
	case json.Number:
		i, _ := x.Int64()
		return int(i)
	case string:
		i, _ := strconv.Atoi(strings.TrimSpace(x))
		return i
	default:
		return 0
	}
}

func ToFloat(v interface{}) float64 {
	switch x := v.(type) {
	case float64:
		return x
	case int:
		return float64(x)
	case int64:
		return float64(x)
	case json.Number:
		f, _ := x.Float64()
		return f
	case string:
		f, _ := strconv.ParseFloat(strings.TrimSpace(x), 64)
		return f
	default:
		return 0
	}
}

func FileExists(path string) bool {
	info, err := os.Stat(path)
	return err == nil && !info.IsDir()
}

func FileExecutable(path string) bool {
	info, err := os.Stat(path)
	return err == nil && !info.IsDir() && info.Mode()&0111 != 0
}

func MaxInt(a, b int) int {
	if a > b {
		return a
	}
	return b
}

func Max64(a, b int64) int64 {
	if a > b {
		return a
	}
	return b
}

func PidAlive(pid int) bool {
	err := syscall.Kill(pid, 0)
	return err == nil || errors.Is(err, syscall.EPERM)
}

func RuntimeSessionStale() time.Duration {
	if raw := strings.TrimSpace(os.Getenv("XRAY_WS_RUNTIME_SESSION_STALE_SEC")); raw != "" {
		if v, err := strconv.Atoi(raw); err == nil && v >= 15 {
			return time.Duration(v) * time.Second
		}
	}
	return RuntimeSessionStaleDefault
}

func WriteJSONAtomic(path string, payload interface{}, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	data, err := json.MarshalIndent(payload, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')
	tmp, err := os.CreateTemp(filepath.Dir(path), ".tmp.*.json")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	defer func() { _ = os.Remove(tmpPath) }()
	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Chmod(tmpPath, mode); err != nil {
		return err
	}
	return os.Rename(tmpPath, path)
}
