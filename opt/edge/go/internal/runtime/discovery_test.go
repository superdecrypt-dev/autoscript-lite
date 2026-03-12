package runtime

import (
	"os"
	"path/filepath"
	"testing"
)

func TestRefreshDiscoveredRawBackendsOverridesLoopbackTargets(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "10-inbounds.json")
	writeTestFile(t, file, `{
  "inbounds": [
    {"tag": "default@vless-tcp", "listen": "127.0.0.1", "port": 33175},
    {"tag": "default@trojan-tcp", "listen": "127.0.0.1", "port": 48778}
  ]
}`)

	cfg := Config{
		VLESSRawBackend:  "127.0.0.1:28080",
		TrojanRawBackend: "127.0.0.1:28081",
		VLESSRawSource:   "env:EDGE_XRAY_VLESS_RAW_BACKEND",
		TrojanRawSource:  "env:EDGE_XRAY_TROJAN_RAW_BACKEND",
		XrayInboundsFile: file,
	}

	refreshed, changed, err := RefreshDiscoveredRawBackends(cfg)
	if err != nil {
		t.Fatalf("RefreshDiscoveredRawBackends error = %v", err)
	}
	if !changed {
		t.Fatalf("changed = false, want true")
	}
	if refreshed.VLESSRawBackend != "127.0.0.1:33175" {
		t.Fatalf("VLESSRawBackend = %q, want 127.0.0.1:33175", refreshed.VLESSRawBackend)
	}
	if refreshed.TrojanRawBackend != "127.0.0.1:48778" {
		t.Fatalf("TrojanRawBackend = %q, want 127.0.0.1:48778", refreshed.TrojanRawBackend)
	}
	if refreshed.VLESSRawSource != discoveredBackendSource(file, "default@vless-tcp") {
		t.Fatalf("VLESSRawSource = %q", refreshed.VLESSRawSource)
	}
	if refreshed.TrojanRawSource != discoveredBackendSource(file, "default@trojan-tcp") {
		t.Fatalf("TrojanRawSource = %q", refreshed.TrojanRawSource)
	}
}

func TestRefreshDiscoveredRawBackendsPreservesExplicitNonLoopbackTargets(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "10-inbounds.json")
	writeTestFile(t, file, `{
  "inbounds": [
    {"tag": "default@vless-tcp", "listen": "127.0.0.1", "port": 33175},
    {"tag": "default@trojan-tcp", "listen": "127.0.0.1", "port": 48778}
  ]
}`)

	cfg := Config{
		VLESSRawBackend:  "10.10.10.5:443",
		TrojanRawBackend: "10.10.10.6:443",
		VLESSRawSource:   "env:EDGE_XRAY_VLESS_RAW_BACKEND",
		TrojanRawSource:  "env:EDGE_XRAY_TROJAN_RAW_BACKEND",
		XrayInboundsFile: file,
	}

	refreshed, changed, err := RefreshDiscoveredRawBackends(cfg)
	if err != nil {
		t.Fatalf("RefreshDiscoveredRawBackends error = %v", err)
	}
	if changed {
		t.Fatalf("changed = true, want false")
	}
	if refreshed.VLESSRawBackend != cfg.VLESSRawBackend {
		t.Fatalf("VLESSRawBackend = %q, want %q", refreshed.VLESSRawBackend, cfg.VLESSRawBackend)
	}
	if refreshed.TrojanRawBackend != cfg.TrojanRawBackend {
		t.Fatalf("TrojanRawBackend = %q, want %q", refreshed.TrojanRawBackend, cfg.TrojanRawBackend)
	}
}

func writeTestFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatalf("WriteFile(%s): %v", path, err)
	}
}
