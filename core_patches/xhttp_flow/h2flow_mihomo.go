//go:build go1.22

package xhttp

import (
	"context"
	"net"

	"github.com/metacubex/http"
	"github.com/metacubex/mihomo/log"
)

// H2FlowOptions is the "h2-flow" block of a proxy's xhttp-opts, the
// counterpart of "h2Flow" in xhttpSettings.extra of Xray-core-fork:
//
//	xhttp-opts:
//	  h2-flow:
//	    enabled: true
//	    max-stream-receive-window: 16777216
//	    max-connection-receive-window: 33554432
//
// enabled turns the flow governor on or off for this proxy and wins over
// MIHOMO_XHTTP_FLOW; unset, the variable decides and the governor is off
// without it. The windows are what this client grants for downloads, from
// 65535 bytes to 1 GiB; unset, Go's 4 MiB per stream. With the governor they
// are a ceiling and the real window follows what is read; without it they
// are fixed windows.
type H2FlowOptions struct {
	Enabled                    *bool `proxy:"enabled,omitempty"`
	MaxStreamReceiveWindow     int   `proxy:"max-stream-receive-window,omitempty"`
	MaxConnectionReceiveWindow int   `proxy:"max-connection-receive-window,omitempty"`
}

func (o *H2FlowOptions) governed() bool {
	if o != nil && o.Enabled != nil {
		return *o.Enabled
	}
	return flowEnabled
}

func h2FlowReceiveWindow(v int, name string) int {
	if v == 0 {
		return 0
	}
	if v < h2InitWindow || v > 1<<30 {
		log.Warnln("[XHTTP] h2-flow.%s=%d is outside 65535..1073741824, ignored", name, v)
		return 0
	}
	return v
}

// Wrap applies the options to every transport mk builds. Only the HTTP/2
// mode is touched: HTTP/1.1 and HTTP/3 transports pass through unchanged.
// A nil receiver means no "h2-flow" block.
func (o *H2FlowOptions) Wrap(mk func() http.RoundTripper) func() http.RoundTripper {
	if mk == nil {
		return nil
	}
	return func() http.RoundTripper {
		rt := mk()
		t, ok := rt.(*http.Transport)
		if !ok || t.DialTLSContext == nil || t.Protocols == nil || !t.Protocols.UnencryptedHTTP2() {
			return rt
		}
		if o != nil {
			stream := h2FlowReceiveWindow(o.MaxStreamReceiveWindow, "max-stream-receive-window")
			conn := h2FlowReceiveWindow(o.MaxConnectionReceiveWindow, "max-connection-receive-window")
			if stream != 0 || conn != 0 {
				if t.HTTP2 == nil {
					t.HTTP2 = &http.HTTP2Config{}
				}
				if stream != 0 {
					t.HTTP2.MaxReceiveBufferPerStream = stream
				}
				if conn != 0 {
					t.HTTP2.MaxReceiveBufferPerConnection = conn
				}
			}
		}
		if o.governed() {
			dial := t.DialTLSContext
			t.DialTLSContext = func(ctx context.Context, network, addr string) (net.Conn, error) {
				c, err := dial(ctx, network, addr)
				if err != nil {
					return c, err
				}
				return newFlowClientConn(c), nil
			}
		}
		return rt
	}
}
