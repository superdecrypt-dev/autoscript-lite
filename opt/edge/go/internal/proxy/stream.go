package proxy

import (
	"io"
	"net"
	"sync"
	"sync/atomic"
)

type BridgeStats struct {
	LeftToRight uint64
	RightToLeft uint64
}

func Bridge(left net.Conn, right net.Conn, leftToRightPrefix []byte, rightToLeftPrefix []byte) error {
	_, err := BridgeWithStats(left, right, leftToRightPrefix, rightToLeftPrefix)
	return err
}

func BridgeWithStats(left net.Conn, right net.Conn, leftToRightPrefix []byte, rightToLeftPrefix []byte) (BridgeStats, error) {
	var wg sync.WaitGroup
	errCh := make(chan error, 2)
	var stats BridgeStats

	copyOne := func(dst net.Conn, src net.Conn, prefix []byte, counter *uint64) {
		defer wg.Done()
		if len(prefix) > 0 {
			n, err := dst.Write(prefix)
			if n > 0 {
				atomic.AddUint64(counter, uint64(n))
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
	go copyOne(right, left, leftToRightPrefix, &stats.LeftToRight)
	go copyOne(left, right, rightToLeftPrefix, &stats.RightToLeft)
	wg.Wait()
	close(errCh)

	for err := range errCh {
		if err != nil && err != io.EOF {
			return stats, err
		}
	}
	return stats, nil
}
