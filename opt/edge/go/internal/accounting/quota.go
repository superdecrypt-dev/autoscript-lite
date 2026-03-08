package accounting

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"
)

type SSHQuotaConfig struct {
	StateRoot    string
	DropbearUnit string
	EnforcerPath string
}

var authLineRe = regexp.MustCompile(`(?:Password )?auth succeeded for '([^']+)' from 127\.0\.0\.1:(\d+)`)

func RecordSSHQuotaByLocalPort(logger *log.Logger, cfg SSHQuotaConfig, localPort int, totalBytes uint64) {
	if localPort <= 0 || totalBytes == 0 {
		return
	}
	username, err := ResolveSSHUsernameByLocalPort(cfg.DropbearUnit, localPort)
	if err != nil {
		logger.Printf("edge-mux quota resolve failed port=%d: %v", localPort, err)
		return
	}
	if username == "" {
		logger.Printf("edge-mux quota resolve empty port=%d", localPort)
		return
	}
	if err := addQuotaUsed(cfg.StateRoot, username, totalBytes); err != nil {
		logger.Printf("edge-mux quota update failed user=%s bytes=%d: %v", username, totalBytes, err)
		return
	}
	logger.Printf("edge-mux quota updated user=%s bytes=%d port=%d", username, totalBytes, localPort)
	triggerEnforcer(logger, cfg.EnforcerPath)
}

func ResolveSSHUsernameByLocalPort(unit string, localPort int) (string, error) {
	portText := strconv.Itoa(localPort)
	if username := scanAuthOutput(runCmd("journalctl", "-u", unit, "--no-pager", "-n", "2000"), portText); username != "" {
		return username, nil
	}
	if username := scanAuthOutput(runCmd("tail", "-n", "5000", "/var/log/auth.log"), portText); username != "" {
		return username, nil
	}
	return "", nil
}

func runCmd(name string, args ...string) []byte {
	out, err := exec.Command(name, args...).Output()
	if err != nil {
		return nil
	}
	return out
}

func scanAuthOutput(out []byte, portText string) string {
	if len(out) == 0 || portText == "" {
		return ""
	}
	var username string
	s := bufio.NewScanner(strings.NewReader(string(out)))
	for s.Scan() {
		line := s.Text()
		m := authLineRe.FindStringSubmatch(line)
		if len(m) != 3 {
			continue
		}
		if m[2] != portText {
			continue
		}
		username = normalizeUser(m[1])
	}
	return username
}

func normalizeUser(v string) string {
	s := strings.TrimSpace(v)
	if strings.HasSuffix(s, "@ssh") {
		s = strings.TrimSuffix(s, "@ssh")
	}
	if idx := strings.IndexByte(s, '@'); idx >= 0 {
		s = s[:idx]
	}
	return strings.TrimSpace(s)
}

func candidateStateFiles(stateRoot, username string) []string {
	root := strings.TrimSpace(stateRoot)
	user := normalizeUser(username)
	if root == "" || user == "" {
		return nil
	}
	return []string{
		filepath.Join(root, user+"@ssh.json"),
		filepath.Join(root, user+".json"),
	}
}

func loadSSHState(stateRoot, username string) (string, map[string]any, error) {
	var target string
	for _, path := range candidateStateFiles(stateRoot, username) {
		if st, err := os.Stat(path); err == nil && !st.IsDir() {
			target = path
			break
		}
	}
	if target == "" {
		return "", nil, fmt.Errorf("state file not found for %s", username)
	}
	raw, err := os.ReadFile(target)
	if err != nil {
		return "", nil, err
	}
	var payload map[string]any
	if err := json.Unmarshal(raw, &payload); err != nil {
		return "", nil, err
	}
	return target, payload, nil
}

func LoadSSHSpeedPolicy(stateRoot, username string) (SSHSpeedPolicy, error) {
	_, payload, err := loadSSHState(stateRoot, username)
	if err != nil {
		return SSHSpeedPolicy{}, err
	}
	status, _ := payload["status"].(map[string]any)
	if !toBool(status["speed_limit_enabled"]) {
		return SSHSpeedPolicy{}, nil
	}
	down := mbitToBytesPerSecond(toFloat(status["speed_down_mbit"]))
	up := mbitToBytesPerSecond(toFloat(status["speed_up_mbit"]))
	return SSHSpeedPolicy{
		Enabled:         down > 0 || up > 0,
		DownloadBytesPS: down,
		UploadBytesPS:   up,
	}, nil
}

func addQuotaUsed(stateRoot, username string, totalBytes uint64) error {
	if totalBytes == 0 {
		return nil
	}
	target, payload, err := loadSSHState(stateRoot, username)
	if err != nil {
		return err
	}
	lockPath := target + ".lock"
	lockFile, err := os.OpenFile(lockPath, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return err
	}
	defer lockFile.Close()
	if err := syscall.Flock(int(lockFile.Fd()), syscall.LOCK_EX); err != nil {
		return err
	}
	defer syscall.Flock(int(lockFile.Fd()), syscall.LOCK_UN)

	current := toUint64(payload["quota_used"])
	payload["quota_used"] = current + totalBytes
	return writeJSONAtomic(target, payload)
}

func toUint64(v any) uint64 {
	switch x := v.(type) {
	case nil:
		return 0
	case float64:
		if x < 0 {
			return 0
		}
		return uint64(x)
	case float32:
		if x < 0 {
			return 0
		}
		return uint64(x)
	case int:
		if x < 0 {
			return 0
		}
		return uint64(x)
	case int64:
		if x < 0 {
			return 0
		}
		return uint64(x)
	case uint64:
		return x
	case string:
		n, _ := strconv.ParseUint(strings.TrimSpace(x), 10, 64)
		return n
	default:
		return 0
	}
}

func toFloat(v any) float64 {
	switch x := v.(type) {
	case nil:
		return 0
	case float64:
		return x
	case float32:
		return float64(x)
	case int:
		return float64(x)
	case int64:
		return float64(x)
	case uint64:
		return float64(x)
	case string:
		n, _ := strconv.ParseFloat(strings.TrimSpace(x), 64)
		return n
	default:
		return 0
	}
}

func toBool(v any) bool {
	switch x := v.(type) {
	case bool:
		return x
	case int:
		return x != 0
	case int64:
		return x != 0
	case float64:
		return x != 0
	case string:
		switch strings.ToLower(strings.TrimSpace(x)) {
		case "1", "true", "yes", "on":
			return true
		}
	}
	return false
}

func mbitToBytesPerSecond(v float64) uint64 {
	if v <= 0 {
		return 0
	}
	return uint64(v * 125000.0)
}

func writeJSONAtomic(path string, payload map[string]any) error {
	tmp := path + fmt.Sprintf(".tmp.%d", time.Now().UnixNano())
	data, err := json.MarshalIndent(payload, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')
	if err := os.WriteFile(tmp, data, 0644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func triggerEnforcer(logger *log.Logger, enforcerPath string) {
	path := strings.TrimSpace(enforcerPath)
	if path == "" {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, path, "--once")
	if err := cmd.Run(); err != nil {
		logger.Printf("edge-mux quota enforcer failed: %v", err)
	}
}
