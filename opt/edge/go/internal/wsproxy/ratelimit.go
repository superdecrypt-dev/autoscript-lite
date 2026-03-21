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

	r.mu.Lock()
	state := r.states[key]
	if state.last.Before(now) {
		state.last = now
	}
	sleep := state.last.Sub(now)
	state.last = state.last.Add(want)
	r.states[key] = state
	r.mu.Unlock()

	if sleep > 0 {
		time.Sleep(sleep)
	}
}
