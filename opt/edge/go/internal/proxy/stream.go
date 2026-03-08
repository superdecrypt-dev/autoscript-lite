package proxy

import (
	"io"
	"net"
	"sync"
)

func Bridge(left net.Conn, right net.Conn, leftToRightPrefix []byte, rightToLeftPrefix []byte) error {
	var wg sync.WaitGroup
	errCh := make(chan error, 2)

	copyOne := func(dst net.Conn, src net.Conn, prefix []byte) {
		defer wg.Done()
		if len(prefix) > 0 {
			if _, err := dst.Write(prefix); err != nil {
				errCh <- err
				return
			}
		}
		_, err := io.Copy(dst, src)
		if tcp, ok := dst.(*net.TCPConn); ok {
			_ = tcp.CloseWrite()
		} else {
			_ = dst.Close()
		}
		errCh <- err
	}

	wg.Add(2)
	go copyOne(right, left, leftToRightPrefix)
	go copyOne(left, right, rightToLeftPrefix)
	wg.Wait()
	close(errCh)

	for err := range errCh {
		if err != nil && err != io.EOF {
			return err
		}
	}
	return nil
}
