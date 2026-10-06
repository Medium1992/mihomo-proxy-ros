//go:build go1.22

package xhttp

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"io"
	mrand "math/rand/v2"
	"net"
	"net/http"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	mhttp "github.com/metacubex/http"
	"github.com/metacubex/mihomo/common/structure"
)

// The tests above drive the governor with x/net's HTTP/2 client. mihomo dials
// XHTTP through its own net/http fork, so these go through NewTransport, the
// exact path the h2 mode takes, wrapped the way vless.go wraps it.

func newMihomoTransport(addr string, opts *H2FlowOptions) mhttp.RoundTripper {
	return opts.Wrap(func() mhttp.RoundTripper {
		return NewTransport(
			func(ctx context.Context) (net.Conn, error) {
				return (&net.Dialer{}).DialContext(ctx, "tcp", addr)
			},
			func(ctx context.Context, c net.Conn, isH2 bool) (net.Conn, error) { return c, nil },
			nil, nil, 0,
		)
	})()
}

func flowOpts(on bool) *H2FlowOptions { return &H2FlowOptions{Enabled: &on} }

func newMihomoTestClient(addr string, governed bool) *mhttp.Client {
	return &mhttp.Client{Transport: newMihomoTransport(addr, flowOpts(governed))}
}

func TestFlowMihomoSlowReaderBounded(t *testing.T) {
	for _, sc := range clientCases {
		for _, governed := range []bool{true, false} {
			var written atomic.Int64
			_, addr := startFlowServer(t, sc.up, sc.down, false, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				buf := make([]byte, 16<<10)
				for {
					n, err := w.Write(buf)
					written.Add(int64(n))
					if err != nil {
						return
					}
				}
			}))
			client := newMihomoTestClient(addr, governed)
			resp, err := client.Get("https://x/down")
			if err != nil {
				t.Fatal(err)
			}
			var consumed atomic.Int64
			stop := make(chan struct{})
			go slowCopy(resp.Body, 256<<10, &consumed, stop)
			time.Sleep(3 * time.Second)
			gap := written.Load() - consumed.Load()
			close(stop)
			resp.Body.Close()
			t.Logf("%s, governed %v: server wrote %d, client read %d, gap %d", sc.name, governed, written.Load(), consumed.Load(), gap)
			if governed && gap > 512<<10 {
				t.Fatalf("%s: gap %d between written and read with the governor", sc.name, gap)
			}
			if !governed && !sc.down.enabled() && gap < 2<<20 {
				t.Fatalf("%s: stock gap %d; the test no longer shows what the governor saves", sc.name, gap)
			}
		}
	}
}

func TestFlowMihomoIntegrityDuplex(t *testing.T) {
	for _, sc := range clientCases {
		_, addr := startFlowServer(t, sc.up, sc.down, true, http.HandlerFunc(echoHandler))
		client := newMihomoTestClient(addr, true)
		var wg sync.WaitGroup
		errs := make(chan error, 16)
		for i := 0; i < 16; i++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				data := make([]byte, 1<<20+mrand.IntN(3<<20))
				rand.Read(data)
				pr, pw := io.Pipe()
				go func() {
					for off := 0; off < len(data); {
						n := min(len(data)-off, 1+mrand.IntN(64<<10))
						if _, err := pw.Write(data[off : off+n]); err != nil {
							return
						}
						off += n
					}
					pw.Close()
				}()
				req, _ := mhttp.NewRequest("POST", "https://x/echo", pr)
				resp, err := client.Do(req)
				if err != nil {
					errs <- err
					return
				}
				defer resp.Body.Close()
				// read in random bursts with pauses so windows grow and shrink
				h := sha256.New()
				buf := make([]byte, 64<<10)
				for {
					n, err := resp.Body.Read(buf[:1+mrand.IntN(len(buf))])
					h.Write(buf[:n])
					if err == io.EOF {
						break
					}
					if err != nil {
						errs <- err
						return
					}
					if mrand.IntN(64) == 0 {
						time.Sleep(time.Duration(mrand.IntN(30)) * time.Millisecond)
					}
				}
				want := sha256.Sum256(data)
				if !bytes.Equal(h.Sum(nil), want[:]) {
					errs <- io.ErrUnexpectedEOF
				}
			}()
		}
		wg.Wait()
		close(errs)
		for err := range errs {
			t.Fatalf("%s: %v", sc.name, err)
		}
	}
}

func TestFlowMihomoKeepsThroughput(t *testing.T) {
	if testing.Short() || raceEnabled {
		t.Skip("timing-sensitive")
	}
	rate := func(governed bool) float64 {
		_, addr := startFlowServer(t, flowLimit{}, flowLimit{}, false, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			buf := make([]byte, 32<<10)
			for {
				if _, err := w.Write(buf); err != nil {
					return
				}
			}
		}))
		client := newMihomoTestClient(lagProxy(t, addr, 20*time.Millisecond), governed)
		resp, err := client.Get("https://x/down")
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		// skip the ramp, measure the steady rate
		io.CopyN(io.Discard, resp.Body, 16<<20)
		start := time.Now()
		n, _ := io.CopyN(io.Discard, resp.Body, 128<<20)
		return float64(n) / (1 << 20) / time.Since(start).Seconds()
	}
	base, gov := rate(false), rate(true)
	t.Logf("rtt 40ms: stock %.1f MiB/s, governed %.1f MiB/s", base, gov)
	if gov < base*0.85 {
		t.Fatalf("governed %.1f is below 85%% of stock %.1f", gov, base)
	}
}

// With the governor off, max-stream-receive-window is the fixed window the
// server may fill ahead of the reader: about 1 MiB here instead of Go's 4 MiB.
func TestFlowMihomoReceiveWindow(t *testing.T) {
	off := false
	opts := &H2FlowOptions{Enabled: &off, MaxStreamReceiveWindow: 1 << 20}
	var written atomic.Int64
	_, addr := startFlowServer(t, flowLimit{}, flowLimit{}, false, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		buf := make([]byte, 16<<10)
		for {
			n, err := w.Write(buf)
			written.Add(int64(n))
			if err != nil {
				return
			}
		}
	}))
	client := &mhttp.Client{Transport: newMihomoTransport(addr, opts)}
	resp, err := client.Get("https://x/down")
	if err != nil {
		t.Fatal(err)
	}
	var consumed atomic.Int64
	stop := make(chan struct{})
	go slowCopy(resp.Body, 256<<10, &consumed, stop)
	time.Sleep(3 * time.Second)
	gap := written.Load() - consumed.Load()
	close(stop)
	resp.Body.Close()
	t.Logf("fixed 1 MiB window: gap %d", gap)
	if gap < 768<<10 || gap > 1536<<10 {
		t.Fatalf("gap %d does not match a 1 MiB stream window", gap)
	}
}

// No h2-flow block and no MIHOMO_XHTTP_FLOW: the governor stays off, as in
// Xray-core-fork, and the transport keeps Go's windows.
func TestFlowMihomoOffByDefault(t *testing.T) {
	prev := flowEnabled
	flowEnabled = false
	defer func() { flowEnabled = prev }()
	var opts *H2FlowOptions
	if opts.governed() {
		t.Fatal("governor on without h2-flow or MIHOMO_XHTTP_FLOW")
	}
	flowEnabled = true
	if !opts.governed() {
		t.Fatal("MIHOMO_XHTTP_FLOW=on did not turn the governor on")
	}
	if flowOpts(false).governed() {
		t.Fatal("h2-flow.enabled=false did not win over MIHOMO_XHTTP_FLOW=on")
	}
}

// The YAML keys decode with the decoder mihomo uses for proxies.
func TestFlowMihomoOptionsDecode(t *testing.T) {
	var dst struct {
		H2Flow *H2FlowOptions `proxy:"h2-flow,omitempty"`
	}
	src := map[string]any{"h2-flow": map[string]any{
		"enabled":                       true,
		"max-stream-receive-window":     16777216,
		"max-connection-receive-window": "33554432",
	}}
	d := structure.NewDecoder(structure.Option{TagName: "proxy", WeaklyTypedInput: true, KeyReplacer: structure.DefaultKeyReplacer})
	if err := d.Decode(src, &dst); err != nil {
		t.Fatal(err)
	}
	f := dst.H2Flow
	if f == nil || f.Enabled == nil || !*f.Enabled || f.MaxStreamReceiveWindow != 16777216 || f.MaxConnectionReceiveWindow != 33554432 {
		t.Fatalf("decoded %+v", f)
	}
	if h2FlowReceiveWindow(1000, "x") != 0 || h2FlowReceiveWindow(2<<30, "x") != 0 || h2FlowReceiveWindow(1<<20, "x") != 1<<20 {
		t.Fatal("window range check")
	}
}
