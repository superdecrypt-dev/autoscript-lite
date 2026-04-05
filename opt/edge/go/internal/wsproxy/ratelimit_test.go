package wsproxy

import (
	"testing"
	"time"
)

func TestRateLimiterReserveFirstChunkIsPaced(t *testing.T) {
	rl := NewRateLimiter()
	now := time.Unix(100, 0)
	want := 100 * time.Millisecond

	sleep := rl.reserve(rateKey{user: "alice", direction: "up"}, now, want)
	if sleep != want {
		t.Fatalf("sleep = %v, want %v", sleep, want)
	}
}

func TestRateLimiterReserveRespectsElapsedTime(t *testing.T) {
	rl := NewRateLimiter()
	key := rateKey{user: "alice", direction: "down"}
	base := time.Unix(100, 0)
	want := 100 * time.Millisecond

	if sleep := rl.reserve(key, base, want); sleep != want {
		t.Fatalf("first sleep = %v, want %v", sleep, want)
	}
	if sleep := rl.reserve(key, base.Add(50*time.Millisecond), want); sleep != 150*time.Millisecond {
		t.Fatalf("second sleep = %v, want %v", sleep, 150*time.Millisecond)
	}
	if sleep := rl.reserve(key, base.Add(500*time.Millisecond), want); sleep != want {
		t.Fatalf("idle recovery sleep = %v, want %v", sleep, want)
	}
}
