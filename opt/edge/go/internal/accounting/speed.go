package accounting

import (
	"log"
	"sync/atomic"
	"time"
)

const (
	defaultResolveAttempts = 100
	defaultResolveDelay    = 100 * time.Millisecond
	defaultRefreshInterval = 2 * time.Second
	initialResolveWait     = 1500 * time.Millisecond
	warmupFreeBytes        = 64 * 1024
	// Allow enough time for dropbear auth logs to become visible so the first
	// post-auth payload does not escape shaping almost entirely on short-lived
	// ssh-direct sessions.
	warmupMaxWait = 8 * time.Second
)

type SSHSpeedPolicy struct {
	Enabled         bool
	DownloadBytesPS uint64
	UploadBytesPS   uint64
}

type SSHSpeedController struct {
	logger    *log.Logger
	cfg       SSHQuotaConfig
	localPort int
	done      chan struct{}
	started   atomic.Bool
	ready     atomic.Bool
	user      atomic.Value
	downBPS   atomic.Uint64
	upBPS     atomic.Uint64
	startedAt atomic.Int64
}

func NewSSHSpeedController(logger *log.Logger, cfg SSHQuotaConfig, localPort int) *SSHSpeedController {
	return &SSHSpeedController{
		logger:    logger,
		cfg:       cfg,
		localPort: localPort,
		done:      make(chan struct{}),
	}
}

func (c *SSHSpeedController) Start() {
	if c == nil {
		return
	}
	if !c.started.CompareAndSwap(false, true) {
		return
	}
	c.startedAt.Store(time.Now().UnixNano())
	go c.run()
}

func (c *SSHSpeedController) Stop() {
	if c == nil {
		return
	}
	if c.started.CompareAndSwap(true, false) {
		close(c.done)
	}
}

func (c *SSHSpeedController) DownloadLimiter() *speedRate {
	return &speedRate{value: &c.downBPS, controller: c}
}

func (c *SSHSpeedController) UploadLimiter() *speedRate {
	return &speedRate{value: &c.upBPS, controller: c}
}

func (c *SSHSpeedController) Username() string {
	if c == nil {
		return ""
	}
	if v, ok := c.user.Load().(string); ok {
		return v
	}
	return ""
}

func (c *SSHSpeedController) WaitForReady(transferred uint64) {
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

func (c *SSHSpeedController) WaitForInitialPolicy(timeout time.Duration) {
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

func (c *SSHSpeedController) run() {
	ticker := time.NewTicker(defaultRefreshInterval)
	defer ticker.Stop()
	attempts := 0
	for {
		select {
		case <-c.done:
			return
		default:
		}

		username := c.Username()
		if username == "" {
			if attempts < defaultResolveAttempts {
				if resolved, err := ResolveSSHUsernameByLocalPort(c.cfg.DropbearUnit, c.localPort); err == nil && resolved != "" {
					c.user.Store(resolved)
					triggerSessionSync(c.logger, c.cfg.ManagePath)
					username = resolved
				} else if err != nil && c.logger != nil {
					c.logger.Printf("edge-mux speed resolve failed port=%d: %v", c.localPort, err)
				}
				attempts++
				if username == "" {
					select {
					case <-c.done:
						return
					case <-time.After(defaultResolveDelay):
					}
					continue
				}
			}
			if username == "" {
				select {
				case <-c.done:
					return
				case <-ticker.C:
				}
				continue
			}
		}

		policy, err := LoadSSHSpeedPolicy(c.cfg.StateRoot, username)
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
	controller *SSHSpeedController
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
