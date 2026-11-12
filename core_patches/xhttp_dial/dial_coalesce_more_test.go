package xhttp

import (
	"bytes"
	"context"
	"crypto/tls"
	"fmt"
	"io"
	"math/rand"
	"net"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/metacubex/mihomo/common/httputils"

	"github.com/metacubex/http"
	"github.com/metacubex/http/httptest"
)

// transportGoroutines — горутины, в стеке которых есть HTTP-транспорт или
// XHTTP. Остальное (тестовый раннер, рантайм) счёту не мешает.
func transportGoroutines() (int, string) {
	buf := make([]byte, 1<<22)
	buf = buf[:runtime.Stack(buf, true)]
	n := 0
	var leaked strings.Builder
	for _, g := range strings.Split(string(buf), "\n\n") {
		if strings.Contains(g, "leakCheck") || strings.Contains(g, "transportGoroutines") {
			continue
		}
		if strings.Contains(g, "github.com/metacubex/http.") || strings.Contains(g, "mihomo/transport/xhttp.") {
			n++
			leaked.WriteString(g)
			leaked.WriteString("\n\n")
		}
	}
	return n, leaked.String()
}

// leakCheck ставится первым в тесте: t.Cleanup выполняется в обратном порядке,
// так что проверка идёт после закрытия серверов и транспортов теста.
func leakCheck(t *testing.T) {
	t.Helper()
	base, _ := transportGoroutines()
	t.Cleanup(func() {
		deadline := time.Now().Add(5 * time.Second)
		for {
			n, stacks := transportGoroutines()
			if n <= base {
				return
			}
			if time.Now().After(deadline) {
				t.Fatalf("%d transport goroutines left (baseline %d):\n%s", n, base, stacks)
			}
			time.Sleep(20 * time.Millisecond)
		}
	})
}

// closeTransport закрывает транспорт так же, как это делает клиент XHTTP.
func closeTransport(t *testing.T, rt http.RoundTripper) {
	t.Cleanup(func() { httputils.CloseTransport(rt) })
}

func waitFor(t *testing.T, what string, timeout time.Duration, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// Лишний dial не становится лишним h2-соединением: на холодном пуле после
// всплеска живо ровно одно TCP-соединение.
func TestCoalesceDialsLiveConnsColdBurst(t *testing.T) {
	leakCheck(t)
	addr := h2TestServer(t, 0, func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("ok")) })
	var d dialCounter
	rt := coalescedTestTransport(t, addr, &d, 30*time.Millisecond)
	closeTransport(t, rt)

	if failed, _ := burst(rt, 200, 10*time.Second); failed != 0 {
		t.Fatalf("%d of 200 requests failed", failed)
	}
	time.Sleep(100 * time.Millisecond)
	if got := d.open.Load(); got != 1 {
		t.Fatalf("%d live TCP connections after a cold burst, want 1", got)
	}
}

// При лимите потоков запросы несут ровно столько соединений, сколько нужно
// под пик (30 запросов / 5 потоков = 6), а не по соединению на запрос.
// Открытых одновременно может быть чуть больше: соединение, которое
// дозвонилось, когда место уже освободилось, h2 закрывает сам («Turns out we
// don't need this c» в addConnIfNeeded), и до закрытия оно успевает
// посчитаться.
func TestCoalesceDialsLiveConnsStreamLimit(t *testing.T) {
	leakCheck(t)
	var mu sync.Mutex
	used := map[string]bool{}
	addr := h2TestServer(t, 5, func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		used[r.RemoteAddr] = true
		mu.Unlock()
		time.Sleep(300 * time.Millisecond)
		w.Write([]byte("ok"))
	})
	var d dialCounter
	rt := coalescedTestTransport(t, addr, &d, 20*time.Millisecond)
	closeTransport(t, rt)

	if failed, _ := burst(rt, 30, 10*time.Second); failed != 0 {
		t.Fatalf("%d of 30 requests failed", failed)
	}
	mu.Lock()
	n := len(used)
	mu.Unlock()
	if n > 6 {
		t.Fatalf("30 requests over 5 streams used %d connections, want at most 6", n)
	}
	if got := d.maxOpen.Load(); got > 8 {
		t.Fatalf("%d TCP connections open at once, want at most 8", got)
	}
	t.Logf("connections used %d, dials %d, peak open %d", n, d.dials.Load(), d.maxOpen.Load())
}

// После полной блокировки не остаётся ни сокетов, ни горутин dial'а.
func TestCoalesceDialsNoLeakBlackhole(t *testing.T) {
	leakCheck(t)
	setDialTimeout(t, 300*time.Millisecond)
	addr := blackholeServer(t)
	var d dialCounter
	rt := coalescedTestTransport(t, addr, &d, 0)
	closeTransport(t, rt)

	for round := 0; round < 3; round++ {
		if failed, _ := burst(rt, 30, 2*time.Second); failed != 30 {
			t.Fatalf("round %d: %d of 30 requests failed, want all", round, failed)
		}
	}
	// Попытки идут одна за другой, по одной в срок 300 мс, пока сессии ждут
	// (2 с на раунд): не больше семи-восьми на раунд, а не по одной на запрос.
	if got := d.dials.Load(); got > 3*8 {
		t.Fatalf("3 rounds of 30 requests made %d dials, want at most one per attempt bound", got)
	}
	if got := d.maxOpen.Load(); got != 1 {
		t.Fatalf("%d sockets open at once, want 1", got)
	}
	waitFor(t, "sockets to close", 2*time.Second, func() bool { return d.open.Load() == 0 })
}

// Все запросы ушли, а ведущий висит: его dial обрывается сам, без закрытия
// транспорта и задолго до срока.
func TestCoalesceDialsAbandonedDialEnds(t *testing.T) {
	leakCheck(t)
	// Срок заметно больше ожидания ниже, но конечный: если обрыв сломан,
	// dial не переживёт тест надолго.
	setDialTimeout(t, 3*time.Second)
	addr := blackholeServer(t)
	var d dialCounter
	rt := coalescedTestTransport(t, addr, &d, 0)
	closeTransport(t, rt)

	if failed, _ := burst(rt, 10, 200*time.Millisecond); failed != 10 {
		t.Fatalf("%d of 10 requests failed, want all", failed)
	}
	waitFor(t, "the abandoned dial to end", time.Second, func() bool { return d.open.Load() == 0 })
	if got := d.dials.Load(); got != 1 {
		t.Fatalf("%d dials, want 1", got)
	}
}

// Блокировку сняли, пока брошенный dial ещё висел бы: новая сессия
// дозванивается сразу, а не ждёт его.
func TestCoalesceDialsRecoversAfterAbandonedDial(t *testing.T) {
	leakCheck(t)
	setDialTimeout(t, 3*time.Second)
	addr := h2TestServer(t, 0, func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("ok")) })
	var calls atomic.Int64
	hungDone := make(chan struct{})
	rt := CoalesceDials(func() http.RoundTripper {
		return NewTransport(func(ctx context.Context) (net.Conn, error) {
			if calls.Add(1) == 1 {
				// Первый dial висит, как рукопожатие под блокировкой.
				<-ctx.Done()
				close(hungDone)
				return nil, ctx.Err()
			}
			return (&net.Dialer{}).DialContext(ctx, "tcp", addr)
		}, func(ctx context.Context, c net.Conn, _ bool) (net.Conn, error) {
			tc := tls.Client(c, &tls.Config{NextProtos: []string{"h2"}, InsecureSkipVerify: true})
			return tc, tc.HandshakeContext(ctx)
		}, nil, nil, 0)
	})()
	closeTransport(t, rt)

	if failed, _ := burst(rt, 5, 200*time.Millisecond); failed != 5 {
		t.Fatalf("%d of 5 blocked requests failed, want all", failed)
	}
	select {
	case <-hungDone:
	case <-time.After(time.Second):
		t.Fatal("abandoned dial was not canceled")
	}
	start := time.Now()
	if failed, _ := burst(rt, 20, 3*time.Second); failed != 0 {
		t.Fatalf("%d of 20 requests failed after the block was lifted", failed)
	}
	if took := time.Since(start); took > time.Second {
		t.Fatalf("recovery took %v", took)
	}
	if got := calls.Load(); got != 2 {
		t.Fatalf("%d dials, want 2 (the abandoned one and one fresh)", got)
	}
}

// CloseHttp2Connections доступен через обёртку и рвёт живые соединения.
func TestCoalesceDialsCloseTransportClosesConns(t *testing.T) {
	leakCheck(t)
	addr := h2TestServer(t, 0, func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("ok")) })
	var d dialCounter
	rt := coalescedTestTransport(t, addr, &d, 0)

	if failed, _ := burst(rt, 20, 5*time.Second); failed != 0 {
		t.Fatalf("%d of 20 requests failed", failed)
	}
	if _, ok := rt.(interface{ CloseHttp2Connections() }); !ok {
		t.Fatal("wrapper hides CloseHttp2Connections")
	}
	httputils.CloseTransport(rt)
	waitFor(t, "connections to close", 2*time.Second, func() bool { return d.open.Load() == 0 })
}

// Сервер оборвал все соединения: следующий всплеск снова склеивается в один dial.
func TestCoalesceDialsServerDropsConns(t *testing.T) {
	leakCheck(t)
	srv := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("ok")) }))
	srv.EnableHTTP2 = true
	srv.StartTLS()
	t.Cleanup(srv.Close)
	var d dialCounter
	rt := coalescedTestTransport(t, srv.Listener.Addr().String(), &d, 20*time.Millisecond)
	closeTransport(t, rt)

	for round := 1; round <= 3; round++ {
		if failed, _ := burst(rt, 50, 5*time.Second); failed != 0 {
			t.Fatalf("round %d: %d of 50 requests failed", round, failed)
		}
		if got := d.dials.Load(); got != int64(round) {
			t.Fatalf("round %d: %d dials total, want %d", round, got, round)
		}
		srv.CloseClientConnections()
		waitFor(t, "client to notice the drop", 2*time.Second, func() bool { return d.open.Load() == 0 })
	}
}

// Ведущие хранятся по адресу: запросы к разным хостам одного транспорта не
// ждут друг друга, каждый хост дозванивается один раз.
func TestCoalesceDialsPerAddress(t *testing.T) {
	leakCheck(t)
	addr := h2TestServer(t, 0, func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("ok")) })
	var d dialCounter
	rt := coalescedTestTransport(t, addr, &d, 30*time.Millisecond)
	closeTransport(t, rt)

	var wg sync.WaitGroup
	var fails atomic.Int64
	for i := 0; i < 40; i++ {
		host := "a.example"
		if i%2 == 1 {
			host = "b.example"
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			ctx, cancel := context.WithTimeout(context.Background(), roundTripTimeout)
			defer cancel()
			req, _ := http.NewRequestWithContext(ctx, "GET", "https://"+host+"/", nil)
			resp, err := rt.RoundTrip(req)
			if err != nil {
				fails.Add(1)
				return
			}
			resp.Body.Close()
		}()
	}
	wg.Wait()
	if got := fails.Load(); got != 0 {
		t.Fatalf("%d of 40 requests failed", got)
	}
	if got := d.dials.Load(); got != 2 {
		t.Fatalf("two hosts made %d dials, want 2", got)
	}
}

// Хаос: запросы с разными сроками и отменами, сервер то рвёт соединения, то
// отвечает медленно. Ни один RoundTrip не должен пережить свой срок дольше,
// чем на запас, и после всего не должно остаться горутин.
func TestCoalesceDialsChurn(t *testing.T) {
	leakCheck(t)
	setDialTimeout(t, time.Second)
	srv := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(time.Duration(rand.Intn(50)) * time.Millisecond)
		w.Write([]byte("ok"))
	}))
	srv.EnableHTTP2 = true
	srv.Config.HTTP2 = &http.HTTP2Config{MaxConcurrentStreams: 8}
	srv.StartTLS()
	t.Cleanup(srv.Close)
	var d dialCounter
	rt := coalescedTestTransport(t, srv.Listener.Addr().String(), &d, 10*time.Millisecond)
	closeTransport(t, rt)

	stop := time.Now().Add(3 * time.Second)
	var wg sync.WaitGroup
	var calls, stuck atomic.Int64
	for w := 0; w < 40; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for time.Now().Before(stop) {
				timeout := time.Duration(1+rand.Intn(300)) * time.Millisecond
				ctx, cancel := context.WithTimeout(context.Background(), timeout)
				start := time.Now()
				_ = roundTrip(rt, ctx)
				cancel()
				calls.Add(1)
				if time.Since(start) > timeout+time.Second {
					stuck.Add(1)
				}
			}
		}()
	}
	dropper := make(chan struct{})
	go func() {
		defer close(dropper)
		for time.Now().Before(stop) {
			time.Sleep(time.Duration(100+rand.Intn(300)) * time.Millisecond)
			srv.CloseClientConnections()
		}
	}()
	wg.Wait()
	<-dropper
	if got := stuck.Load(); got != 0 {
		t.Fatalf("%d of %d round trips outlived their deadline by more than 1s", got, calls.Load())
	}
	t.Logf("%d round trips, %d dials", calls.Load(), d.dials.Load())
}

// Полный путь клиента XHTTP: NewClient (он и ставит склейку) против
// серверной части XHTTP по TLS h2. С max-connections=1 все сессии всех
// режимов идут через одно TCP-соединение, данные доходят без искажений.
func TestCoalesceDialsXHTTPClientModes(t *testing.T) {
	for _, mode := range []string{"stream-one", "stream-up", "packet-up"} {
		t.Run(mode, func(t *testing.T) {
			leakCheck(t)
			handler, err := NewServerHandler(ServerOption{
				// Паддинг stream-up спит между записями по 20-80 с и замечает
				// закрытый поток только после сна: в проверку утечек клиента
				// эта серверная горутина не входит.
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
			addr := srv.Listener.Addr().String()

			var d dialCounter
			makeTransport := func() http.RoundTripper {
				return NewTransport(func(ctx context.Context) (net.Conn, error) {
					d.dials.Add(1)
					time.Sleep(20 * time.Millisecond)
					c, err := (&net.Dialer{}).DialContext(ctx, "tcp", addr)
					if err != nil {
						return nil, err
					}
					return d.track(c), nil
				}, func(ctx context.Context, c net.Conn, _ bool) (net.Conn, error) {
					tc := tls.Client(c, &tls.Config{NextProtos: []string{"h2"}, InsecureSkipVerify: true})
					return tc, tc.HandshakeContext(ctx)
				}, nil, nil, 0)
			}
			client, err := NewClient(&Config{
				Host:        "example.com",
				Path:        "/xhttp",
				Mode:        mode,
				ReuseConfig: &ReuseConfig{MaxConnections: "1"},
			}, makeTransport, nil, false)
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { client.Close() })

			const sessions = 30
			var wg sync.WaitGroup
			errs := make(chan error, sessions)
			for i := 0; i < sessions; i++ {
				wg.Add(1)
				go func(i int) {
					defer wg.Done()
					ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
					defer cancel()
					conn, err := client.Dial(ctx)
					if err != nil {
						errs <- fmt.Errorf("session %d dial: %w", i, err)
						return
					}
					defer conn.Close()
					conn.SetDeadline(time.Now().Add(10 * time.Second))
					msg := bytes.Repeat([]byte(fmt.Sprintf("session-%02d;", i)), 200)
					if _, err := conn.Write(msg); err != nil {
						errs <- fmt.Errorf("session %d write: %w", i, err)
						return
					}
					got := make([]byte, len(msg))
					if _, err := io.ReadFull(conn, got); err != nil {
						errs <- fmt.Errorf("session %d read: %w", i, err)
						return
					}
					if !bytes.Equal(got, msg) {
						errs <- fmt.Errorf("session %d: echo mismatch", i)
					}
				}(i)
			}
			wg.Wait()
			close(errs)
			for err := range errs {
				t.Error(err)
			}
			if got := d.dials.Load(); got != 1 {
				t.Fatalf("%d sessions in %s with max-connections=1 made %d dials, want 1", sessions, mode, got)
			}
		})
	}
}
