package accounting

import (
	"io"
	"log"
	"os"
	"path/filepath"
	"testing"
)

func TestRecordXrayQuotaRequiresResolvedUsername(t *testing.T) {
	stateRoot := t.TempDir()
	target := filepath.Join(stateRoot, "demo.json")
	if err := os.WriteFile(target, []byte("{\"quota_used\": 5}\n"), 0o644); err != nil {
		t.Fatalf("write state: %v", err)
	}

	RecordXrayQuota(log.New(io.Discard, "", 0), XrayQuotaConfig{StateRoot: stateRoot}, "", 18080, 99)

	raw, err := os.ReadFile(target)
	if err != nil {
		t.Fatalf("read state: %v", err)
	}
	if string(raw) != "{\"quota_used\": 5}\n" {
		t.Fatalf("quota state changed unexpectedly: %s", raw)
	}
}

func TestRecordXrayQuotaUpdatesResolvedUsername(t *testing.T) {
	stateRoot := t.TempDir()
	target := filepath.Join(stateRoot, "demo.json")
	if err := os.WriteFile(target, []byte("{\"quota_used\": 5}\n"), 0o644); err != nil {
		t.Fatalf("write state: %v", err)
	}

	RecordXrayQuota(log.New(io.Discard, "", 0), XrayQuotaConfig{StateRoot: stateRoot}, "demo@vless", 18080, 99)

	_, payload, err := loadXrayState(stateRoot, "demo")
	if err != nil {
		t.Fatalf("load state: %v", err)
	}
	if got := toUint64(payload["quota_used"]); got != 104 {
		t.Fatalf("quota_used = %d, want 104", got)
	}
}
