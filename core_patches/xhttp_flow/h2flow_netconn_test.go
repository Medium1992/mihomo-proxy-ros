//go:build go1.22

package xhttp

import (
	"net"
	"testing"
)

// Code that looks through connection wrappers must reach the accepted
// connection behind the governor.
func TestFlowConnNetConn(t *testing.T) {
	a, b := net.Pipe()
	defer a.Close()
	defer b.Close()
	fc := newFlowConn(a, flowDefault, flowDefault)
	if got := fc.NetConn(); got != a {
		t.Fatalf("NetConn returned %v, want the accepted connection", got)
	}
}
