package accounting

import (
	"io"
	"log"
	"testing"
)

func TestSessionTrackerResolveUsernameUsesResolverOnly(t *testing.T) {
	tracker := NewXrayRuntimeSessionTracker(
		log.New(io.Discard, "", 0),
		XrayQuotaConfig{
			SessionRoot:      t.TempDir(),
			SessionHeartbeat: 1,
		},
		18080,
		"127.0.0.1",
		"xray_direct",
		func() string {
			return "demo@vmess"
		},
	)
	if tracker == nil {
		t.Fatalf("tracker = nil")
	}
	if got := tracker.resolveUsername(); got != "demo" {
		t.Fatalf("resolveUsername = %q, want demo", got)
	}
}

func TestSessionTrackerResolveUsernameReturnsEmptyWithoutResolver(t *testing.T) {
	tracker := NewXrayRuntimeSessionTracker(
		log.New(io.Discard, "", 0),
		XrayQuotaConfig{
			SessionRoot:      t.TempDir(),
			SessionHeartbeat: 1,
		},
		18080,
		"127.0.0.1",
		"xray_direct",
		nil,
	)
	if tracker == nil {
		t.Fatalf("tracker = nil")
	}
	if got := tracker.resolveUsername(); got != "" {
		t.Fatalf("resolveUsername = %q, want empty", got)
	}
}
