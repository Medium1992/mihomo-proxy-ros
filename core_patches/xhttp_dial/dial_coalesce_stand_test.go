package xhttp

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/tls"
	"fmt"
	"io"
	"net"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/metacubex/http"
	"github.com/metacubex/http/httptest"
)

// Сценарии ручного стенда (mihomo -> реле -> Xray) на полном пути клиента
// XHTTP: NewClient и серверная часть XHTTP по TLS h2, между ними реле,
// которое считает соединения и умеет изображать блокировку после ClientHello.

// standRelay — TCP-реле перед сервером. В режиме block новые соединения
// принимаются и читаются, но наверх ничего не уходит и ответа нет.
type standRelay struct {
	ln       net.Listener
	upstream string
	blocked  atomic.Bool
	accepted atomic.Int64
	open     atomic.Int64
	peak     atomic.Int64
	mu       sync.Mutex
	conns    map[net.Conn]struct{}
}

func newStandRelay(t *testing.T, upstream string) *standRelay {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	r := &standRelay{ln: ln, upstream: upstream, conns: map[net.Conn]struct{}{}}
	t.Cleanup(func() {
		ln.Close()
		r.kill()
	})
	go r.serve()
	return r
}

func (r *standRelay) addr() string { return r.ln.Addr().String() }

func (r *standRelay) track(c net.Conn) {
	r.mu.Lock()
	r.conns[c] = struct{}{}
	r.mu.Unlock()
}

func (r *standRelay) untrack(c net.Conn) {
	r.mu.Lock()
	delete(r.conns, c)
	r.mu.Unlock()
}

// kill рвёт все соединения через реле, как обрыв пути.
func (r *standRelay) kill() {
	r.mu.Lock()
	defer r.mu.Unlock()
	for c := range r.conns {
		c.Close()
	}
}

func (r *standRelay) reset() { r.accepted.Store(0); r.peak.Store(r.open.Load()) }

func (r *standRelay) serve() {
	for {
		c, err := r.ln.Accept()
		if err != nil {
			return
		}
		r.accepted.Add(1)
		n := r.open.Add(1)
		for m := r.peak.Load(); n > m && !r.peak.CompareAndSwap(m, n); m = r.peak.Load() {
		}
		// Регистрация до запуска горутины: kill не должен пропустить
		// только что принятое соединение.
		r.track(c)
		go func() {
			defer r.open.Add(-1)
			defer r.untrack(c)
			defer c.Close()
			if r.blocked.Load() {
				io.Copy(io.Discard, c)
				return
			}
			up, err := net.Dial("tcp", r.upstream)
			if err != nil {
				return
			}
			r.track(up)
			defer r.untrack(up)
			defer up.Close()
			done := make(chan struct{}, 2)
			go func() { io.Copy(up, c); up.Close(); done <- struct{}{} }()
			go func() { io.Copy(c, up); c.Close(); done <- struct{}{} }()
			<-done
			<-done
		}()
	}
}

// standServer — серверная часть XHTTP по TLS h2 с эхом.
func standServer(t *testing.T, mode string) string {
	t.Helper()
	handler, err := NewServerHandler(ServerOption{
		Config: Config{Path: "/xhttp", Mode: mode, ScStreamUpServerSecs: "0"},
		ConnHandler: func(conn net.Conn) {
			defer conn.Close()
			io.Copy(conn, conn)
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewUnstartedServer(handler)
	srv.EnableHTTP2 = true
	srv.StartTLS()
	t.Cleanup(srv.Close)
	return srv.Listener.Addr().String()
}

// standClient собирает клиента XHTTP так же, как vless.go. wrap, если задан,
// оборачивает фабрику транспорта снаружи, как это делает xhttp_flow.
func standClient(t *testing.T, addr, mode string, reuse *ReuseConfig, wrap func(TransportMaker) TransportMaker) *Client {
	t.Helper()
	var mk TransportMaker = func() http.RoundTripper {
		return NewTransport(func(ctx context.Context) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, "tcp", addr)
		}, func(ctx context.Context, c net.Conn, _ bool) (net.Conn, error) {
			tc := tls.Client(c, &tls.Config{NextProtos: []string{"h2"}, InsecureSkipVerify: true})
			if err := tc.HandshakeContext(ctx); err != nil {
				return nil, err
			}
			return tc, nil
		}, nil, nil, 0)
	}
	if wrap != nil {
		mk = wrap(mk)
	}
	client, err := NewClient(&Config{Host: "example.com", Path: "/xhttp", Mode: mode, ReuseConfig: reuse}, mk, nil, false)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { client.Close() })
	return client
}

// echoSession гоняет size байт через сессию и сверяет SHA-256.
func echoSession(client *Client, timeout time.Duration, size int, seed int) error {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	conn, err := client.Dial(ctx)
	if err != nil {
		return fmt.Errorf("dial: %w", err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(timeout))
	msg := make([]byte, size)
	for i := range msg {
		msg[i] = byte((i*7 + seed) % 251)
	}
	errc := make(chan error, 1)
	go func() {
		_, err := conn.Write(msg)
		errc <- err
	}()
	h := sha256.New()
	if _, err := io.CopyN(h, conn, int64(size)); err != nil {
		return fmt.Errorf("read: %w", err)
	}
	if err := <-errc; err != nil {
		return fmt.Errorf("write: %w", err)
	}
	if want := sha256.Sum256(msg); !bytes.Equal(h.Sum(nil), want[:]) {
		return fmt.Errorf("echo mismatch")
	}
	return nil
}

func sessions(client *Client, n int, timeout time.Duration, size int) (failed int64, firstErr error) {
	var wg sync.WaitGroup
	var fails atomic.Int64
	var once sync.Once
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			if err := echoSession(client, timeout, size, i); err != nil {
				fails.Add(1)
				once.Do(func() { firstErr = err })
			}
		}(i)
	}
	wg.Wait()
	return fails.Load(), firstErr
}

// Рабочий сервер, все режимы: холодный всплеск из 50 сессий открывает ровно
// max-connections соединений, тёплый — ни одного, данные доходят целыми. Без
// reuse-settings соединение на сессию задумано и остаётся.
func TestCoalesceDialsStandModes(t *testing.T) {
	for _, mode := range []string{"stream-one", "stream-up", "packet-up"} {
		for _, reuse := range []bool{true, false} {
			name := mode + "/reuse"
			if !reuse {
				name = mode + "/noreuse"
			}
			t.Run(name, func(t *testing.T) {
				leakCheck(t)
				relay := newStandRelay(t, standServer(t, mode))
				var rc *ReuseConfig
				if reuse {
					rc = &ReuseConfig{MaxConnections: "2"}
				}
				client := standClient(t, relay.addr(), mode, rc, nil)

				if failed, err := sessions(client, 50, 10*time.Second, 32<<10); failed != 0 {
					t.Fatalf("cold: %d of 50 sessions failed: %v", failed, err)
				}
				cold := relay.accepted.Load()
				relay.reset()
				if failed, err := sessions(client, 50, 10*time.Second, 32<<10); failed != 0 {
					t.Fatalf("warm: %d of 50 sessions failed: %v", failed, err)
				}
				warm := relay.accepted.Load()
				if failed, err := sessions(client, 3, 30*time.Second, 4<<20); failed != 0 {
					t.Fatalf("4 MiB: %d of 3 sessions failed: %v", failed, err)
				}
				if reuse {
					if cold != 2 || warm != 0 {
						t.Fatalf("max-connections=2: cold burst opened %d connections, warm %d; want 2 and 0", cold, warm)
					}
				} else if cold != 50 {
					t.Fatalf("without reuse-settings: cold burst opened %d connections, want one per session (50)", cold)
				}
			})
		}
	}
}

// Внешняя обёртка подменяет DialTLSContext до склейки, как xhttp_flow:
// склейка работает поверх неё, и каждое соединение проходит через обёртку.
func TestCoalesceDialsStandWrappedDial(t *testing.T) {
	leakCheck(t)
	relay := newStandRelay(t, standServer(t, "stream-up"))
	var wrapped atomic.Int64
	wrap := func(mk TransportMaker) TransportMaker {
		return func() http.RoundTripper {
			rt := mk()
			tr := rt.(*http.Transport)
			dial := tr.DialTLSContext
			tr.DialTLSContext = func(ctx context.Context, network, addr string) (net.Conn, error) {
				c, err := dial(ctx, network, addr)
				if err == nil {
					wrapped.Add(1)
				}
				return c, err
			}
			return rt
		}
	}
	client := standClient(t, relay.addr(), "stream-up", &ReuseConfig{MaxConnections: "2"}, wrap)

	if failed, err := sessions(client, 50, 10*time.Second, 32<<10); failed != 0 {
		t.Fatalf("%d of 50 sessions failed: %v", failed, err)
	}
	if got := relay.accepted.Load(); got != 2 {
		t.Fatalf("%d connections with an outer dial wrapper, want 2", got)
	}
	if got := wrapped.Load(); got != 2 {
		t.Fatalf("outer wrapper saw %d connections, want 2", got)
	}
}

// Блокировка после ClientHello на холодном пуле: живые соединения оборваны,
// новые висят. Две волны сессий не открывают больше max-connections сокетов
// и не оставляют их висеть; после снятия блокировки сессии сразу идут.
func TestCoalesceDialsStandBlackhole(t *testing.T) {
	leakCheck(t)
	setDialTimeout(t, 2*time.Second)
	relay := newStandRelay(t, standServer(t, "stream-one"))
	client := standClient(t, relay.addr(), "stream-one", &ReuseConfig{MaxConnections: "2"}, nil)

	if failed, err := sessions(client, 20, 10*time.Second, 1<<10); failed != 0 {
		t.Fatalf("warm-up: %d of 20 sessions failed: %v", failed, err)
	}
	relay.blocked.Store(true)
	relay.kill()
	waitFor(t, "relayed connections to drop", 2*time.Second, func() bool { return relay.open.Load() == 0 })

	for wave := 1; wave <= 2; wave++ {
		relay.reset()
		if failed, _ := sessions(client, 50, 700*time.Millisecond, 1<<10); failed != 50 {
			t.Fatalf("wave %d: %d of 50 sessions failed, want all", wave, failed)
		}
		if got := relay.peak.Load(); got > 2 {
			t.Fatalf("wave %d: %d sockets open at once, want at most 2", wave, got)
		}
		waitFor(t, "abandoned dials to end", time.Second, func() bool { return relay.open.Load() == 0 })
	}

	relay.blocked.Store(false)
	relay.reset()
	start := time.Now()
	if failed, err := sessions(client, 30, 5*time.Second, 1<<10); failed != 0 {
		t.Fatalf("after unblock: %d of 30 sessions failed: %v", failed, err)
	}
	if took := time.Since(start); took > time.Second {
		t.Fatalf("recovery after unblock took %v", took)
	}
	if got := relay.accepted.Load(); got > 2 {
		t.Fatalf("recovery opened %d connections, want at most 2", got)
	}
}

// Загрузки, оборванные посреди передачи, не ломают пул: новые сессии идут
// по тем же соединениям, горутины не остаются.
func TestCoalesceDialsStandAborts(t *testing.T) {
	leakCheck(t)
	relay := newStandRelay(t, standServer(t, "stream-up"))
	client := standClient(t, relay.addr(), "stream-up", &ReuseConfig{MaxConnections: "2"}, nil)

	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			conn, err := client.Dial(ctx)
			if err != nil {
				return
			}
			conn.SetDeadline(time.Now().Add(5 * time.Second))
			go conn.Write(make([]byte, 8<<20))
			io.CopyN(io.Discard, conn, 256<<10)
			conn.Close()
		}()
	}
	wg.Wait()
	if failed, err := sessions(client, 20, 10*time.Second, 256<<10); failed != 0 {
		t.Fatalf("after aborts: %d of 20 sessions failed: %v", failed, err)
	}
	if got := relay.accepted.Load(); got != 2 {
		t.Fatalf("%d connections, want 2", got)
	}
}

// Страница начала грузиться во время блокировки, сессии идут одна за другой,
// и блокировка снимается посреди залпа. Повисший ведущий не держит залп:
// сессии, пришедшие после снятия, проходят все, а новое соединение получают
// и часть сессий, начатых ещё во время блокировки. Сокетов при этом единицы.
func TestCoalesceDialsStandBlockDuringPage(t *testing.T) {
	leakCheck(t)
	setDialTimeout(t, 3*time.Second)
	relay := newStandRelay(t, standServer(t, "stream-one"))
	client := standClient(t, relay.addr(), "stream-one", &ReuseConfig{MaxConnections: "2"}, nil)
	relay.blocked.Store(true)

	const n = 48
	var unblocked atomic.Int64
	time.AfterFunc(1200*time.Millisecond, func() {
		unblocked.Store(time.Now().UnixNano())
		relay.blocked.Store(false)
	})
	var wg sync.WaitGroup
	var during, after, afterOK atomic.Int64
	var firstErr atomic.Value
	for i := 0; i < n; i++ {
		time.Sleep(40 * time.Millisecond)
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			blocked := unblocked.Load() == 0
			err := echoSession(client, 4*time.Second, 1<<10, i)
			switch {
			case blocked && err == nil:
				during.Add(1)
			case !blocked:
				after.Add(1)
				if err == nil {
					afterOK.Add(1)
				} else {
					firstErr.CompareAndSwap(nil, err)
				}
			}
		}(i)
	}
	wg.Wait()
	if after.Load() == 0 {
		t.Fatal("no session started after unblock")
	}
	if afterOK.Load() != after.Load() {
		t.Fatalf("%d of %d sessions started after unblock failed: %v", after.Load()-afterOK.Load(), after.Load(), firstErr.Load())
	}
	if during.Load() == 0 {
		t.Fatal("no session started during the block got the new connection")
	}
	if got := relay.peak.Load(); got > 6 {
		t.Fatalf("%d sockets open at once, want a few", got)
	}
	t.Logf("started during block and passed: %d; after unblock: %d of %d; connections %d", during.Load(), afterOK.Load(), after.Load(), relay.accepted.Load())
}
