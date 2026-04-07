package runtime

import (
	"encoding/json"
	"fmt"
	"net"
	"os"
	"strings"
)

type xrayInboundFile struct {
	Inbounds []xrayInbound `json:"inbounds"`
}

type xrayInbound struct {
	Tag    string `json:"tag"`
	Listen string `json:"listen"`
	Port   int    `json:"port"`
}

func RefreshDiscoveredRawBackends(cfg Config) (Config, bool, error) {
	file := strings.TrimSpace(cfg.XrayInboundsFile)
	if file == "" {
		file = defaultXrayInboundsFile
	}
	cfg.XrayInboundsFile = file
	if !shouldOverrideDiscoveredBackend(cfg.VLESSRawBackend) && !shouldOverrideDiscoveredBackend(cfg.VMessRawBackend) && !shouldOverrideDiscoveredBackend(cfg.TrojanRawBackend) {
		return cfg, false, nil
	}

	discovered, err := discoverRawBackendsFromXrayFile(file)
	if err != nil {
		return cfg, false, err
	}

	changed := false
	if addr, ok := discovered["default@vless-tcp"]; ok && shouldOverrideDiscoveredBackend(cfg.VLESSRawBackend) {
		if cfg.VLESSRawBackend != addr || cfg.VLESSRawSource != discoveredBackendSource(file, "default@vless-tcp") {
			changed = true
		}
		cfg.VLESSRawBackend = addr
		cfg.VLESSRawSource = discoveredBackendSource(file, "default@vless-tcp")
	}
	if addr, ok := discovered["default@vmess-tcp"]; ok && shouldOverrideDiscoveredBackend(cfg.VMessRawBackend) {
		if cfg.VMessRawBackend != addr || cfg.VMessRawSource != discoveredBackendSource(file, "default@vmess-tcp") {
			changed = true
		}
		cfg.VMessRawBackend = addr
		cfg.VMessRawSource = discoveredBackendSource(file, "default@vmess-tcp")
	}
	if addr, ok := discovered["default@trojan-tcp"]; ok && shouldOverrideDiscoveredBackend(cfg.TrojanRawBackend) {
		if cfg.TrojanRawBackend != addr || cfg.TrojanRawSource != discoveredBackendSource(file, "default@trojan-tcp") {
			changed = true
		}
		cfg.TrojanRawBackend = addr
		cfg.TrojanRawSource = discoveredBackendSource(file, "default@trojan-tcp")
	}
	return cfg, changed, nil
}

func discoverRawBackendsFromXrayFile(path string) (map[string]string, error) {
	content, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}

	var payload xrayInboundFile
	if err := json.Unmarshal(content, &payload); err != nil {
		return nil, fmt.Errorf("parse xray inbounds %s: %w", path, err)
	}

	out := make(map[string]string, 3)
	for _, inbound := range payload.Inbounds {
		tag := strings.TrimSpace(inbound.Tag)
		switch tag {
		case "default@vless-tcp", "default@vmess-tcp", "default@trojan-tcp":
		default:
			continue
		}
		if inbound.Port <= 0 {
			continue
		}
		host := strings.TrimSpace(inbound.Listen)
		if host == "" {
			host = "127.0.0.1"
		}
		out[tag] = normalizeAddr(fmt.Sprintf("%s:%d", host, inbound.Port), "127.0.0.1")
	}
	return out, nil
}

func discoveredBackendSource(path, tag string) string {
	return fmt.Sprintf("xray-inbounds:%s#%s", path, tag)
}

func shouldOverrideDiscoveredBackend(addr string) bool {
	host := "127.0.0.1"
	if parsedHost, _, err := net.SplitHostPort(strings.TrimSpace(addr)); err == nil && strings.TrimSpace(parsedHost) != "" {
		host = parsedHost
	}
	host = strings.TrimSpace(host)
	switch strings.ToLower(host) {
	case "", "127.0.0.1", "::1", "localhost":
		return true
	default:
		return false
	}
}
