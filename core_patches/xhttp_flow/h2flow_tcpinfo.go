//go:build go1.22

package xhttp

// The Linux TCP_INFO reader in Xray-core-fork feeds the server-only queue
// control and needs Xray's stat package; mihomo only runs the client role.

import (
	"net"
	"syscall"
)

func rawTCP(net.Conn) syscall.RawConn { return nil }

func readTCPStats(syscall.RawConn) (tcpStats, bool) { return tcpStats{}, false }
