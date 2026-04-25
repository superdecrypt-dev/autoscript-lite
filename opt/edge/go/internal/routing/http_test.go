package routing

import "testing"

func TestRouteLabelTreatsUnknownWebSocketPathAsOther(t *testing.T) {
	req := HTTPRequest{
		Method:     "GET",
		Path:       "/a1b2c3d4e5",
		Upgrade:    "websocket",
		Connection: "upgrade",
	}
	if got := RouteLabel(req, ""); got != "websocket-other" {
		t.Fatalf("RouteLabel() = %q, want websocket-other", got)
	}
}
