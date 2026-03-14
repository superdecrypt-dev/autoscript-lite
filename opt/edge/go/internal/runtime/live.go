package runtime

import (
	"sync"
	"sync/atomic"
)

type Live struct {
	mu      sync.Mutex
	current atomic.Value
}

func NewLive(cfg Config) *Live {
	live := &Live{}
	live.current.Store(cfg.Clone())
	return live
}

func (l *Live) Config() Config {
	if l == nil {
		return Config{}
	}
	if cfg, ok := l.current.Load().(Config); ok {
		return cfg.Clone()
	}
	return Config{}
}

func (l *Live) Set(cfg Config) {
	if l == nil {
		return
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	l.current.Store(cfg.Clone())
}

func (l *Live) Reload(load func() (Config, error)) (Config, Config, error) {
	if l == nil {
		cfg, err := load()
		return Config{}, cfg, err
	}
	l.mu.Lock()
	defer l.mu.Unlock()

	oldCfg := l.Config()
	newCfg, err := load()
	if err != nil {
		return oldCfg, Config{}, err
	}
	stored := newCfg.Clone()
	l.current.Store(stored)
	return oldCfg, stored.Clone(), nil
}
