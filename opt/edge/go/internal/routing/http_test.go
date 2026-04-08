package routing

import "testing"

func TestRouteLabelTreatsDiagnosticProbeAsXrayWS(t *testing.T) {
	req := HTTPRequest{
		Method:     "GET",
		Path:       "/diagnostic-probe",
		Upgrade:    "websocket",
		Connection: "upgrade",
	}
	if got := RouteLabel(req, ""); got != "xray-ws-like" {
		t.Fatalf("RouteLabel() = %q, want xray-ws-like", got)
	}
}

func TestRouteLabelTreatsHexTokenWSPathAsXrayWSLike(t *testing.T) {
	tests := []string{"/a1b2c3d4e5", "/bebas/a1b2c3d4e5"}
	for _, path := range tests {
		req := HTTPRequest{
			Method:     "GET",
			Path:       path,
			Upgrade:    "websocket",
			Connection: "upgrade",
		}
		if got := RouteLabel(req, ""); got != "xray-ws-like" {
			t.Fatalf("RouteLabel(%q) = %q, want xray-ws-like", path, got)
		}
	}
}

func TestRouteLabelRecognizesKnownRouteWithMultiSegmentPrefixSuffix(t *testing.T) {
	req := HTTPRequest{
		Method:     "GET",
		Path:       "/bebas/bebas2/vless-ws/bebas/bebas2",
		Upgrade:    "websocket",
		Connection: "upgrade",
	}
	if got := RouteLabel(req, ""); got != "vless-ws" {
		t.Fatalf("RouteLabel() = %q, want vless-ws", got)
	}
}
