package wsproxy

import (
	"sync"
	"time"
)

type rateKey struct {
	user      string
	direction string
}

type rateState struct {
	last time.Time
}

type RateLimiter struct {
	mu     sync.Mutex
	states map[rateKey]rateState
}

func NewRateLimiter() *RateLimiter {
	return &RateLimiter{states: map[rateKey]rateState{}}
}

func (r *RateLimiter) reserve(key rateKey, now time.Time, want time.Duration) time.Duration {
	r.mu.Lock()
	defer r.mu.Unlock()
	state := r.states[key]
	if state.last.Before(now) {
		state.last = now
	}
	target := state.last.Add(want)
	sleep := target.Sub(now)
	state.last = target
	r.states[key] = state
	return sleep
}

func (r *RateLimiter) Throttle(user, direction string, size int, bytesPerSecond int64) {
	if r == nil || bytesPerSecond <= 0 || size <= 0 {
		return
	}
	key := rateKey{user: NormUser(user), direction: direction}
	if key.user == "" {
		return
	}
	now := time.Now()
	want := time.Duration(int64(size) * int64(time.Second) / bytesPerSecond)
	if want <= 0 {
		return
	}

	sleep := r.reserve(key, now, want)
	if sleep > 0 {
		time.Sleep(sleep)
	}
}
