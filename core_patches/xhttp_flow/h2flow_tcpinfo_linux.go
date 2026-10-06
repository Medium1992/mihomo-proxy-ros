//go:build linux && go1.22

package xhttp

import (
	"net"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

func rawTCP(c net.Conn) syscall.RawConn {
	for range 8 {
		switch v := c.(type) {
		case *net.TCPConn:
			rc, err := v.SyscallConn()
			if err != nil {
				return nil
			}
			return rc
		case interface{ Upstream() any }:
			// sing and mihomo wrappers (bufio, tfo, extended conns)
			u, ok := v.Upstream().(net.Conn)
			if !ok {
				return nil
			}
			c = u
		case interface{ NetConn() net.Conn }:
			c = v.NetConn()
		case interface{ Raw() net.Conn }:
			c = v.Raw()
		default:
			return nil
		}
	}
	return nil
}

func readTCPStats(rc syscall.RawConn) (s tcpStats, ok bool) {
	if rc == nil {
		return
	}
	rc.Control(func(fd uintptr) {
		info, err := unix.GetsockoptTCPInfo(int(fd), unix.IPPROTO_TCP, unix.TCP_INFO)
		if err != nil {
			return
		}
		s.rtt = time.Duration(info.Rtt) * time.Microsecond
		s.minRTT = time.Duration(info.Min_rtt) * time.Microsecond
		s.rttVar = time.Duration(info.Rttvar) * time.Microsecond
		ok = s.rtt > 0
	})
	return
}
