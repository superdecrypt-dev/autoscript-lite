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
    {"tag": "default@vmess-tcp", "listen": "127.0.0.1", "port": 38990},
    {"tag": "default@trojan-tcp", "listen": "127.0.0.1", "port": 48778}
  ]
}`)

	cfg := Config{
		VLESSRawBackend:  "127.0.0.1:28080",
		VMessRawBackend:  "127.0.0.1:28082",
		TrojanRawBackend: "127.0.0.1:28081",
		VLESSRawSource:   "env:EDGE_XRAY_VLESS_RAW_BACKEND",
		VMessRawSource:   "env:EDGE_XRAY_VMESS_RAW_BACKEND",
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
	if refreshed.VMessRawBackend != "127.0.0.1:38990" {
		t.Fatalf("VMessRawBackend = %q, want 127.0.0.1:38990", refreshed.VMessRawBackend)
	}
	if refreshed.TrojanRawBackend != "127.0.0.1:48778" {
		t.Fatalf("TrojanRawBackend = %q, want 127.0.0.1:48778", refreshed.TrojanRawBackend)
	}
	if refreshed.VLESSRawSource != discoveredBackendSource(file, "default@vless-tcp") {
		t.Fatalf("VLESSRawSource = %q", refreshed.VLESSRawSource)
	}
	if refreshed.VMessRawSource != discoveredBackendSource(file, "default@vmess-tcp") {
		t.Fatalf("VMessRawSource = %q", refreshed.VMessRawSource)
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
    {"tag": "default@vmess-tcp", "listen": "127.0.0.1", "port": 38990},
    {"tag": "default@trojan-tcp", "listen": "127.0.0.1", "port": 48778}
  ]
}`)

	cfg := Config{
		VLESSRawBackend:  "10.10.10.5:443",
		VMessRawBackend:  "10.10.10.7:443",
		TrojanRawBackend: "10.10.10.6:443",
		VLESSRawSource:   "env:EDGE_XRAY_VLESS_RAW_BACKEND",
		VMessRawSource:   "env:EDGE_XRAY_VMESS_RAW_BACKEND",
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
	if refreshed.VMessRawBackend != cfg.VMessRawBackend {
		t.Fatalf("VMessRawBackend = %q, want %q", refreshed.VMessRawBackend, cfg.VMessRawBackend)
	}
	if refreshed.TrojanRawBackend != cfg.TrojanRawBackend {
		t.Fatalf("TrojanRawBackend = %q, want %q", refreshed.TrojanRawBackend, cfg.TrojanRawBackend)
	}
}

func TestRefreshDiscoveredRawBackendsSkipsFileWhenTargetsAreExplicit(t *testing.T) {
	cfg := Config{
		VLESSRawBackend:  "10.10.10.5:443",
		VMessRawBackend:  "10.10.10.7:443",
		TrojanRawBackend: "10.10.10.6:443",
		VLESSRawSource:   "env:EDGE_XRAY_VLESS_RAW_BACKEND",
		VMessRawSource:   "env:EDGE_XRAY_VMESS_RAW_BACKEND",
		TrojanRawSource:  "env:EDGE_XRAY_TROJAN_RAW_BACKEND",
		XrayInboundsFile: filepath.Join(t.TempDir(), "missing-10-inbounds.json"),
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
	if refreshed.VMessRawBackend != cfg.VMessRawBackend {
		t.Fatalf("VMessRawBackend = %q, want %q", refreshed.VMessRawBackend, cfg.VMessRawBackend)
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
