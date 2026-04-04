package wsproxy

import "testing"

func TestPathAllowed(t *testing.T) {
	if !PathAllowed("/foo/bar", "/foo") {
		t.Fatal("expected prefix path to be allowed")
	}
	if PathAllowed("/bar", "/foo") {
		t.Fatal("expected mismatched path to be rejected")
	}
}

func TestFirstForwardedIP(t *testing.T) {
	if got := firstForwardedIP(" 203.0.113.10, 127.0.0.1 "); got != "203.0.113.10" {
		t.Fatalf("unexpected forwarded ip: %q", got)
	}
	if got := firstForwardedIP("garbage, ::1"); got != "::1" {
		t.Fatalf("unexpected fallback forwarded ip: %q", got)
	}
}
