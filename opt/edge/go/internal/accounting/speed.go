package accounting

import (
	"log"
	"sync/atomic"
	"time"
)

const (
	defaultRefreshInterval = 2 * time.Second
	initialResolveWait     = 1500 * time.Millisecond
	warmupFreeBytes        = 64 * 1024
	// Allow enough time for an upstream username resolver to populate the
	// controller before short-lived xray-direct sessions finish completely
	// unshaped.
	warmupMaxWait = 8 * time.Second
)

type XraySpeedPolicy struct {
	Enabled         bool
	DownloadBytesPS uint64
	UploadBytesPS   uint64
}

type XraySpeedController struct {
	logger    *log.Logger
	cfg       XrayQuotaConfig
	localPort int
	done      chan struct{}
	started   atomic.Bool
	ready     atomic.Bool
	user      atomic.Value
	downBPS   atomic.Uint64
	upBPS     atomic.Uint64
	startedAt atomic.Int64
}

func NewXraySpeedController(logger *log.Logger, cfg XrayQuotaConfig, localPort int) *XraySpeedController {
	return &XraySpeedController{
		logger:    logger,
		cfg:       cfg,
		localPort: localPort,
		done:      make(chan struct{}),
	}
}

func (c *XraySpeedController) Start() {
	if c == nil {
		return
	}
	if !c.started.CompareAndSwap(false, true) {
		return
	}
	c.startedAt.Store(time.Now().UnixNano())
	go c.run()
}

func (c *XraySpeedController) Stop() {
	if c == nil {
		return
	}
	if c.started.CompareAndSwap(true, false) {
		close(c.done)
	}
}

func (c *XraySpeedController) DownloadLimiter() *speedRate {
	return &speedRate{value: &c.downBPS, controller: c}
}

func (c *XraySpeedController) UploadLimiter() *speedRate {
	return &speedRate{value: &c.upBPS, controller: c}
}

func (c *XraySpeedController) Username() string {
	if c == nil {
		return ""
	}
	if v, ok := c.user.Load().(string); ok {
		return v
	}
	return ""
}

func (c *XraySpeedController) SetUsername(username string) {
	if c == nil {
		return
	}
	if user := normalizeUser(username); user != "" {
		c.user.Store(user)
	}
}

func (c *XraySpeedController) WaitForReady(transferred uint64) {
	if c == nil || c.ready.Load() {
		return
	}
	if transferred <= warmupFreeBytes {
		return
	}
	startedAt := time.Unix(0, c.startedAt.Load())
	for {
		if c.ready.Load() {
			return
		}
		if !startedAt.IsZero() && time.Since(startedAt) >= warmupMaxWait {
			return
		}
		select {
		case <-c.done:
			return
		case <-time.After(25 * time.Millisecond):
		}
	}
}

func (c *XraySpeedController) WaitForInitialPolicy(timeout time.Duration) {
	if c == nil || c.ready.Load() {
		return
	}
	if timeout <= 0 {
		timeout = initialResolveWait
	}
	deadline := time.Now().Add(timeout)
	for {
		if c.ready.Load() || c.Username() != "" {
			return
		}
		if time.Now().After(deadline) {
			return
		}
		select {
		case <-c.done:
			return
		case <-time.After(25 * time.Millisecond):
		}
	}
}

func (c *XraySpeedController) run() {
	ticker := time.NewTicker(defaultRefreshInterval)
	defer ticker.Stop()
	for {
		select {
		case <-c.done:
			return
		default:
		}

		username := c.Username()
		if username == "" {
			select {
			case <-c.done:
				return
			case <-ticker.C:
			}
			continue
		}

		policy, err := LoadXraySpeedPolicy(c.cfg.StateRoot, username)
		if err != nil {
			if c.logger != nil {
				c.logger.Printf("edge-mux speed policy load failed user=%s: %v", username, err)
			}
		} else if policy.Enabled {
			c.downBPS.Store(policy.DownloadBytesPS)
			c.upBPS.Store(policy.UploadBytesPS)
			c.ready.Store(true)
		} else {
			c.downBPS.Store(0)
			c.upBPS.Store(0)
			c.ready.Store(true)
		}

		select {
		case <-c.done:
			return
		case <-ticker.C:
		}
	}
}

type speedRate struct {
	value      *atomic.Uint64
	controller *XraySpeedController
}

func (r *speedRate) RateBytesPerSecond() uint64 {
	if r == nil || r.value == nil {
		return 0
	}
	return r.value.Load()
}

func (r *speedRate) WaitForReady(transferred uint64) {
	if r == nil || r.controller == nil {
		return
	}
	r.controller.WaitForReady(transferred)
}
