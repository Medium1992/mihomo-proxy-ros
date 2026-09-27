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
)

// The tests above drive the governor with x/net's HTTP/2 client. mihomo dials
// XHTTP through its own net/http fork, so these go through NewTransport, the
// exact path the h2 mode takes, with the governor switched on and off.

func newMihomoTestClient(addr string, governed bool) *mhttp.Client {
	var mu sync.Mutex
	on := governed
	rt := NewTransport(
		func(ctx context.Context) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, "tcp", addr)
		},
		func(ctx context.Context, c net.Conn, isH2 bool) (net.Conn, error) { return c, nil },
		nil, nil, 0,
	)
	// flowEnabled is read when a connection is dialed, not when the transport
	// is built, so hold it for this client's dials.
	return &mhttp.Client{Transport: roundTripFunc(func(r *mhttp.Request) (*mhttp.Response, error) {
		mu.Lock()
		prev := flowEnabled
		flowEnabled = on
		resp, err := rt.RoundTrip(r)
		flowEnabled = prev
		mu.Unlock()
		return resp, err
	})}
}

type roundTripFunc func(*mhttp.Request) (*mhttp.Response, error)

func (f roundTripFunc) RoundTrip(r *mhttp.Request) (*mhttp.Response, error) { return f(r) }

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
