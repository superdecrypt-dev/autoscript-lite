package proxy

import (
	"io"
	"net"
	"sync"
	"sync/atomic"
	"time"
)

type BridgeStats struct {
	LeftToRight uint64
	RightToLeft uint64
}

type RateProvider interface {
	RateBytesPerSecond() uint64
}

type BridgeOptions struct {
	LeftToRight RateProvider
	RightToLeft RateProvider
}

func Bridge(left net.Conn, right net.Conn, leftToRightPrefix []byte, rightToLeftPrefix []byte) error {
	_, err := BridgeWithStats(left, right, leftToRightPrefix, rightToLeftPrefix)
	return err
}

func BridgeWithStats(left net.Conn, right net.Conn, leftToRightPrefix []byte, rightToLeftPrefix []byte) (BridgeStats, error) {
	return BridgeWithStatsAndOptions(left, right, leftToRightPrefix, rightToLeftPrefix, BridgeOptions{})
}

func BridgeWithStatsAndOptions(left net.Conn, right net.Conn, leftToRightPrefix []byte, rightToLeftPrefix []byte, options BridgeOptions) (BridgeStats, error) {
	var wg sync.WaitGroup
	errCh := make(chan error, 2)
	var stats BridgeStats

	copyOne := func(dst net.Conn, src net.Conn, prefix []byte, counter *uint64, limiter RateProvider) {
		defer wg.Done()
		var throttle paceLimiter
		if len(prefix) > 0 {
			n, err := dst.Write(prefix)
			if n > 0 {
				atomic.AddUint64(counter, uint64(n))
				throttle.Wait(uint64(n), limiter)
			}
			if err != nil {
				errCh <- err
				return
			}
		}
		buf := make([]byte, 32*1024)
		for {
			nr, er := src.Read(buf)
			if nr > 0 {
				nw, ew := dst.Write(buf[:nr])
				if nw > 0 {
					atomic.AddUint64(counter, uint64(nw))
					throttle.Wait(uint64(nw), limiter)
				}
				if ew != nil {
					errCh <- ew
					break
				}
				if nw != nr {
					errCh <- io.ErrShortWrite
					break
				}
			}
			if er != nil {
				errCh <- er
				break
			}
		}
		if tcp, ok := dst.(*net.TCPConn); ok {
			_ = tcp.CloseWrite()
		} else {
			_ = dst.Close()
		}
	}

	wg.Add(2)
	go copyOne(right, left, leftToRightPrefix, &stats.LeftToRight, options.LeftToRight)
	go copyOne(left, right, rightToLeftPrefix, &stats.RightToLeft, options.RightToLeft)
	wg.Wait()
	close(errCh)

	for err := range errCh {
		if err != nil && err != io.EOF {
			return stats, err
		}
	}
	return stats, nil
}

type paceLimiter struct {
	lastRate uint64
	bytes     uint64
	seenBytes uint64
	start     time.Time
}

func (p *paceLimiter) Wait(written uint64, provider RateProvider) {
	if written == 0 || provider == nil {
		return
	}
	if gate, ok := provider.(interface{ WaitForReady(uint64) }); ok {
		gate.WaitForReady(p.seenBytes + written)
	}
	p.seenBytes += written
	rate := provider.RateBytesPerSecond()
	if rate == 0 {
		p.lastRate = 0
		p.bytes = 0
		p.start = time.Time{}
		return
	}
	now := time.Now()
	if p.lastRate != rate || p.start.IsZero() {
		p.lastRate = rate
		p.bytes = 0
		p.start = now
	}
	p.bytes += written
	targetElapsed := time.Duration(float64(p.bytes)/float64(rate)*float64(time.Second))
	actualElapsed := now.Sub(p.start)
	if targetElapsed > actualElapsed {
		time.Sleep(targetElapsed - actualElapsed)
	}
}
