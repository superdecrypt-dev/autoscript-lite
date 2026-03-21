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
