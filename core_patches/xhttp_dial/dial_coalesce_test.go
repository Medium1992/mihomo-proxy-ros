package xhttp

import (
	"context"
	"crypto/tls"
	"errors"
	"net"
	"os"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/metacubex/http"
	"github.com/metacubex/http/httptest"
	"github.com/metacubex/http/httptrace"
)

// dialCounter считает dial'ы и открытые ими TCP-соединения.
type dialCounter struct {
	dials   atomic.Int64
	open    atomic.Int64
	maxOpen atomic.Int64
}

func (d *dialCounter) track(c net.Conn) net.Conn {
	n := d.open.Add(1)
	for m := d.maxOpen.Load(); n > m && !d.maxOpen.CompareAndSwap(m, n); m = d.maxOpen.Load() {
	}
	return &countedConn{Conn: c, d: d}
}

type countedConn struct {
	net.Conn
	d    *dialCounter
	once sync.Once
}

func (c *countedConn) Close() error {
	c.once.Do(func() { c.d.open.Add(-1) })
	return c.Conn.Close()
}

// coalescedTestTransport собирает h2-транспорт XHTTP так же, как это делает
// vless.go, и оборачивает его склейкой. delay имитирует RTT до сервера.
func coalescedTestTransport(t *testing.T, addr string, d *dialCounter, delay time.Duration) http.RoundTripper {
	t.Helper()
	mk := CoalesceDials(func() http.RoundTripper {
		return NewTransport(func(ctx context.Context) (net.Conn, error) {
			d.dials.Add(1)
			if delay > 0 {
				select {
				case <-time.After(delay):
				case <-ctx.Done():
					return nil, ctx.Err()
				}
			}
			c, err := (&net.Dialer{}).DialContext(ctx, "tcp", addr)
			if err != nil {
				return nil, err
			}
			return d.track(c), nil
		}, func(ctx context.Context, c net.Conn, _ bool) (net.Conn, error) {
			tc := tls.Client(c, &tls.Config{NextProtos: []string{"h2"}, InsecureSkipVerify: true})
			if err := tc.HandshakeContext(ctx); err != nil {
				return nil, err
			}
			return tc, nil
		}, nil, nil, 0)
	})
	rt := mk()
	if _, ok := rt.(*coalescingTransport); !ok {
		t.Fatalf("h2 transport was not wrapped: %T", rt)
	}
	t.Cleanup(func() { rt.(*coalescingTransport).CloseIdleConnections() })
	return rt
}

func h2TestServer(t *testing.T, maxStreams uint32, handler http.HandlerFunc) string {
	t.Helper()
	srv := httptest.NewUnstartedServer(handler)
	srv.EnableHTTP2 = true
	if maxStreams > 0 {
		srv.Config.HTTP2 = &http.HTTP2Config{MaxConcurrentStreams: int(maxStreams)}
	}
	srv.StartTLS()
	t.Cleanup(srv.Close)
	return srv.Listener.Addr().String()
}

// blackholeServer принимает TCP, читает ClientHello и не отвечает: так
// выглядит рукопожатие, заблокированное после ClientHello.
func blackholeServer(t *testing.T) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	var mu sync.Mutex
	var conns []net.Conn
	t.Cleanup(func() {
		ln.Close()
		mu.Lock()
		for _, c := range conns {
			c.Close()
		}
		mu.Unlock()
	})
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			mu.Lock()
			conns = append(conns, c)
			mu.Unlock()
			go func() {
				b := make([]byte, 4096)
				for {
					if _, err := c.Read(b); err != nil {
						return
					}
				}
			}()
		}
	}()
	return ln.Addr().String()
}

func setDialTimeout(t *testing.T, d time.Duration) {
	old := coalescedDialTimeout
	coalescedDialTimeout = d
	t.Cleanup(func() { coalescedDialTimeout = old })
}

func setDialStale(t *testing.T, d time.Duration) {
	old := coalescedDialStale
	coalescedDialStale = d
	t.Cleanup(func() { coalescedDialStale = old })
}

// roundTripTimeout — потолок для запроса без своего срока: тест с
// поломанной склейкой должен упасть, а не повиснуть.
const roundTripTimeout = 10 * time.Second

func roundTrip(rt http.RoundTripper, ctx context.Context) error {
	if _, ok := ctx.Deadline(); !ok {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, roundTripTimeout)
		defer cancel()
	}
	req, err := http.NewRequestWithContext(ctx, "GET", "https://example.com/", nil)
	if err != nil {
		return err
	}
	resp, err := rt.RoundTrip(req)
	if err != nil {
		return err
	}
	return resp.Body.Close()
}

// Параллельные запросы, каждый со своим сроком. Возвращает число ошибок и
// время, за которое закончился последний.
func burst(rt http.RoundTripper, n int, timeout time.Duration) (failed int64, took time.Duration) {
	var wg sync.WaitGroup
	var fails atomic.Int64
	start := time.Now()
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			ctx, cancel := context.WithTimeout(context.Background(), timeout)
			defer cancel()
			if roundTrip(rt, ctx) != nil {
				fails.Add(1)
			}
		}()
	}
	wg.Wait()
	return fails.Load(), time.Since(start)
}

func TestCoalesceDialsColdBurst(t *testing.T) {
	addr := h2TestServer(t, 0, func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("ok")) })
	var d dialCounter
	rt := coalescedTestTransport(t, addr, &d, 30*time.Millisecond)

	failed, _ := burst(rt, 100, 10*time.Second)
	if failed != 0 {
		t.Fatalf("%d of 100 requests failed", failed)
	}
	if got := d.dials.Load(); got != 1 {
		t.Fatalf("cold burst of 100 requests made %d dials, want 1", got)
	}
	// Тёплый пул: новых соединений нет.
	if failed, _ := burst(rt, 100, 10*time.Second); failed != 0 {
		t.Fatalf("%d of 100 warm requests failed", failed)
	}
	if got := d.dials.Load(); got != 1 {
		t.Fatalf("warm burst dialed again: %d dials total", got)
	}
}

// Рукопожатие висит: в полёте ровно один сокет, и ждущие получают ошибку
// ведущего, а не тянут каждый свой срок.
func TestCoalesceDialsBlackhole(t *testing.T) {
	setDialTimeout(t, 300*time.Millisecond)
	addr := blackholeServer(t)
	var d dialCounter
	rt := coalescedTestTransport(t, addr, &d, 0)

	failed, took := burst(rt, 20, 3*time.Second)
	if failed != 20 {
		t.Fatalf("%d of 20 requests failed, want all", failed)
	}
	if got := d.maxOpen.Load(); got != 1 {
		t.Fatalf("%d TCP connections open at once, want 1", got)
	}
	if got := d.dials.Load(); got != 1 {
		t.Fatalf("%d dials, want 1", got)
	}
	if took > 2*time.Second {
		t.Fatalf("requests ended after %v: waiters did not get the leader's error", took)
	}
	if got := d.open.Load(); got != 0 {
		t.Fatalf("%d TCP connections left open after the dial timed out", got)
	}
}

// Соединение упёрлось в MAX_CONCURRENT_STREAMS: запросы не зависают, а
// дополнительные соединения открываются по одному, а не на каждый запрос.
func TestCoalesceDialsStreamLimit(t *testing.T) {
	addr := h2TestServer(t, 5, func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(300 * time.Millisecond)
		w.Write([]byte("ok"))
	})
	var d dialCounter
	rt := coalescedTestTransport(t, addr, &d, 20*time.Millisecond)

	failed, took := burst(rt, 30, 10*time.Second)
	if failed != 0 {
		t.Fatalf("%d of 30 requests failed", failed)
	}
	if got := d.dials.Load(); got > 10 {
		t.Fatalf("30 requests over a 5-stream limit made %d dials", got)
	}
	if took > 3*time.Second {
		t.Fatalf("30 requests took %v", took)
	}
}

// В reuse-settings каждый транспорт держит одно соединение: max-connections
// снова ограничивает сокеты.
func TestCoalesceDialsReuseManager(t *testing.T) {
	addr := h2TestServer(t, 0, func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("ok")) })
	var d dialCounter
	m, err := NewReuseManager(&ReuseConfig{MaxConnections: "2"}, func() http.RoundTripper {
		return coalescedTestTransport(t, addr, &d, 30*time.Millisecond)
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { m.Close() })

	var wg sync.WaitGroup
	var fails atomic.Int64
	for i := 0; i < 50; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			rt := m.GetTransport()
			defer rt.(*ReuseTransport).Close()
			if roundTrip(rt, context.Background()) != nil {
				fails.Add(1)
			}
		}()
	}
	wg.Wait()
	if got := fails.Load(); got != 0 {
		t.Fatalf("%d of 50 sessions failed", got)
	}
	if got := d.dials.Load(); got != 2 {
		t.Fatalf("max-connections=2 with 50 sessions made %d dials, want 2", got)
	}
}

// Запрос ведущего ушёл, пока dial шёл: dial не бросается, его соединение
// достаётся остальным.
func TestCoalesceDialsLeaderGivesUp(t *testing.T) {
	addr := h2TestServer(t, 0, func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("ok")) })
	var d dialCounter
	rt := coalescedTestTransport(t, addr, &d, 300*time.Millisecond)

	ctx, cancel := context.WithCancel(context.Background())
	leaderDone := make(chan error, 1)
	go func() { leaderDone <- roundTrip(rt, ctx) }()
	time.Sleep(50 * time.Millisecond)

	var wg sync.WaitGroup
	var fails atomic.Int64
	for i := 0; i < 10; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if roundTrip(rt, context.Background()) != nil {
				fails.Add(1)
			}
		}()
	}
	time.Sleep(50 * time.Millisecond)
	cancel()
	if err := <-leaderDone; err == nil {
		t.Fatal("leader request succeeded despite being canceled")
	}
	wg.Wait()
	if got := fails.Load(); got != 0 {
		t.Fatalf("%d of 10 followers failed", got)
	}
	if got := d.dials.Load(); got != 1 {
		t.Fatalf("%d dials, want 1", got)
	}
}

// Ждущий, чей запрос отменили, выходит сразу, не дожидаясь повисшего ведущего.
func TestCoalesceDialsFollowerGivesUp(t *testing.T) {
	setDialTimeout(t, 5*time.Second)
	addr := blackholeServer(t)
	var d dialCounter
	rt := coalescedTestTransport(t, addr, &d, 0)

	leaderCtx, cancelLeader := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancelLeader()
	leaderDone := make(chan struct{})
	go func() {
		roundTrip(rt, leaderCtx)
		close(leaderDone)
	}()
	// Ведущий не должен пережить тест и попасть в проверку утечек следующего.
	defer func() {
		cancelLeader()
		select {
		case <-leaderDone:
		case <-time.After(5 * time.Second):
			t.Error("leader round trip did not return after cancel")
		}
	}()
	time.Sleep(50 * time.Millisecond)

	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	start := time.Now()
	if err := roundTrip(rt, ctx); err == nil {
		t.Fatal("follower succeeded against a blackhole")
	}
	if took := time.Since(start); took > time.Second {
		t.Fatalf("canceled follower returned after %v", took)
	}
}

// Ошибка не залипает: следующий запрос дозванивается заново.
func TestCoalesceDialsRedialAfterFailure(t *testing.T) {
	addr := h2TestServer(t, 0, func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("ok")) })
	var calls atomic.Int64
	rt := CoalesceDials(func() http.RoundTripper {
		return NewTransport(func(ctx context.Context) (net.Conn, error) {
			if calls.Add(1) == 1 {
				return nil, errors.New("first dial fails")
			}
			return (&net.Dialer{}).DialContext(ctx, "tcp", addr)
		}, func(ctx context.Context, c net.Conn, _ bool) (net.Conn, error) {
			tc := tls.Client(c, &tls.Config{NextProtos: []string{"h2"}, InsecureSkipVerify: true})
			return tc, tc.HandshakeContext(ctx)
		}, nil, nil, 0)
	})()
	defer rt.(*coalescingTransport).CloseIdleConnections()

	if err := roundTrip(rt, context.Background()); err == nil {
		t.Fatal("first request succeeded, want the dial error")
	}
	if err := roundTrip(rt, context.Background()); err != nil {
		t.Fatalf("second request: %v", err)
	}
}

// Свой GotConn клиента XHTTP продолжает вызываться.
func TestCoalesceDialsKeepsClientTrace(t *testing.T) {
	addr := h2TestServer(t, 0, func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("ok")) })
	var d dialCounter
	rt := coalescedTestTransport(t, addr, &d, 0)

	var got atomic.Bool
	ctx := httptrace.WithClientTrace(context.Background(), &httptrace.ClientTrace{
		GotConn: func(httptrace.GotConnInfo) { got.Store(true) },
	})
	if err := roundTrip(rt, ctx); err != nil {
		t.Fatal(err)
	}
	if !got.Load() {
		t.Fatal("caller's GotConn hook was not called")
	}
}

func TestCoalesceDialsPassThrough(t *testing.T) {
	if CoalesceDials(nil) != nil {
		t.Fatal("nil maker must stay nil")
	}
	dialRaw := func(context.Context) (net.Conn, error) { return nil, errors.New("unused") }
	wrapTLS := func(_ context.Context, c net.Conn, _ bool) (net.Conn, error) { return c, nil }
	for _, alpn := range [][]string{{"http/1.1"}, {"h3"}} {
		rt := CoalesceDials(func() http.RoundTripper { return NewTransport(dialRaw, wrapTLS, nil, alpn, 0) })()
		if _, ok := rt.(*coalescingTransport); ok {
			t.Fatalf("alpn %v transport was wrapped", alpn)
		}
	}
}

// returnsWithin проваливает тест, если fn не вернулась за d, вместо того чтобы
// повиснуть вместе с ней.
func returnsWithin(t *testing.T, d time.Duration, what string, fn func()) {
	t.Helper()
	done := make(chan struct{})
	go func() {
		defer close(done)
		fn()
	}()
	select {
	case <-done:
	case <-time.After(d):
		t.Fatalf("%s did not return within %v", what, d)
	}
}

func TestBoundedDialTimeout(t *testing.T) {
	setDialTimeout(t, 100*time.Millisecond)
	start := time.Now()
	var err error
	returnsWithin(t, 2*time.Second, "bounded dial", func() {
		_, err = boundedDial(context.Background(), func(ctx context.Context, _, _ string) (net.Conn, error) {
			select {
			case <-ctx.Done():
				return nil, ctx.Err()
			case <-time.After(3 * time.Second):
				return nil, errors.New("dial context was never canceled")
			}
		}, "tcp", "x")
	})
	if !errors.Is(err, os.ErrDeadlineExceeded) {
		t.Fatalf("err = %v, want deadline exceeded", err)
	}
	if took := time.Since(start); took > time.Second {
		t.Fatalf("bounded dial returned after %v", took)
	}

	// Удачный dial: контекст после него не отменяется.
	var dialCtx context.Context
	c1, c2 := net.Pipe()
	defer c2.Close()
	conn, err := boundedDial(context.Background(), func(ctx context.Context, _, _ string) (net.Conn, error) {
		dialCtx = ctx
		return c1, nil
	}, "tcp", "x")
	if err != nil || conn != c1 {
		t.Fatalf("conn, err = %v, %v", conn, err)
	}
	time.Sleep(200 * time.Millisecond)
	if dialCtx.Err() != nil {
		t.Fatalf("dial context canceled after a successful dial: %v", dialCtx.Err())
	}
	conn.Close()
}

// Обрыв после того, как dial вернулся, ничего не делает: контекст удачного
// соединения не отменяется.
func TestGuardedDialAbortAfterDone(t *testing.T) {
	g, ctx := newGuardedDial(context.Background())
	c1, c2 := net.Pipe()
	defer c2.Close()
	conn, err := g.run(ctx, func(context.Context, string, string) (net.Conn, error) { return c1, nil }, "tcp", "x")
	if err != nil || conn != c1 {
		t.Fatalf("conn, err = %v, %v", conn, err)
	}
	g.abort(errCoalescedDialAbandoned)
	if ctx.Err() != nil {
		t.Fatalf("context canceled after the dial returned: %v", ctx.Err())
	}
	conn.Close()
}

// Ведущий дозвонился, но соединение негодное: рукопожатие прошло, а до h2
// дело не дошло. Ждущие не висят: либо получают ту же ошибку, либо
// дозваниваются сами, и следующий запрос идёт по рабочему соединению.
func TestCoalesceDialsUnusableLeaderConn(t *testing.T) {
	addr := h2TestServer(t, 0, func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("ok")) })
	var calls atomic.Int64
	rt := CoalesceDials(func() http.RoundTripper {
		return NewTransport(func(ctx context.Context) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, "tcp", addr)
		}, func(ctx context.Context, c net.Conn, _ bool) (net.Conn, error) {
			tc := tls.Client(c, &tls.Config{NextProtos: []string{"h2"}, InsecureSkipVerify: true})
			if err := tc.HandshakeContext(ctx); err != nil {
				return nil, err
			}
			if calls.Add(1) == 1 {
				tc.Close()
			}
			return tc, nil
		}, nil, nil, 0)
	})()
	defer rt.(*coalescingTransport).CloseIdleConnections()

	start := time.Now()
	burst(rt, 5, 5*time.Second)
	if took := time.Since(start); took > 2*time.Second {
		t.Fatalf("requests behind an unusable leader connection took %v", took)
	}
	if calls.Load() < 1 {
		t.Fatal("no dial happened")
	}
	if err := roundTrip(rt, context.Background()); err != nil {
		t.Fatalf("request after the unusable connection: %v", err)
	}
}

// slowFirstWrite задерживает первую запись: net/http пишет h2 preface, пока
// настраивает соединение, то есть до того, как положить его в пул.
type slowFirstWrite struct {
	net.Conn
	once  sync.Once
	delay time.Duration
}

func (c *slowFirstWrite) Write(b []byte) (int, error) {
	c.once.Do(func() { time.Sleep(c.delay) })
	return c.Conn.Write(b)
}

// Запрос пришёл, когда dial ведущего уже вернулся, а соединение ещё не в пуле
// (net/http настраивает h2): он ждёт соединение ведущего, а не дозванивается.
func TestCoalesceDialsPublicationWindow(t *testing.T) {
	addr := h2TestServer(t, 0, func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("ok")) })
	var dials atomic.Int64
	dialed := make(chan struct{})
	rt := CoalesceDials(func() http.RoundTripper {
		return NewTransport(func(ctx context.Context) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, "tcp", addr)
		}, func(ctx context.Context, c net.Conn, _ bool) (net.Conn, error) {
			tc := tls.Client(c, &tls.Config{NextProtos: []string{"h2"}, InsecureSkipVerify: true})
			if err := tc.HandshakeContext(ctx); err != nil {
				return nil, err
			}
			if dials.Add(1) == 1 {
				defer close(dialed)
			}
			return &slowFirstWrite{Conn: tc, delay: 150 * time.Millisecond}, nil
		}, nil, nil, 0)
	})()
	defer rt.(*coalescingTransport).CloseIdleConnections()

	first := make(chan error, 1)
	go func() { first <- roundTrip(rt, context.Background()) }()
	select {
	case <-dialed:
	case <-time.After(5 * time.Second):
		t.Fatal("first dial did not finish")
	}
	// Dial вернулся, соединение настраивается ещё 150 мс.
	time.Sleep(20 * time.Millisecond)
	if err := roundTrip(rt, context.Background()); err != nil {
		t.Fatalf("second request: %v", err)
	}
	if err := <-first; err != nil {
		t.Fatalf("first request: %v", err)
	}
	if got := dials.Load(); got != 1 {
		t.Fatalf("request in the publication window made its own dial: %d dials, want 1", got)
	}
}

// Ведущий повис: пока он моложе coalescedDialStale, за ним ждут. Потом один
// из ждущих дозванивается сам, остальные встают за ним; так раз в срок, пока
// ждущие не кончатся. Ни один dial не обрывается, пока его ждут, и все сокеты
// закрываются, когда ждать некому.
func TestCoalesceDialsStaleLeader(t *testing.T) {
	setDialTimeout(t, 3*time.Second)
	setDialStale(t, 300*time.Millisecond)
	addr := blackholeServer(t)
	var d dialCounter
	rt := coalescedTestTransport(t, addr, &d, 0)

	var wg sync.WaitGroup
	start := func() {
		wg.Add(1)
		go func() {
			defer wg.Done()
			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			defer cancel()
			roundTrip(rt, ctx)
		}()
	}
	start()
	waitFor(t, "the leader to dial", time.Second, func() bool { return d.dials.Load() == 1 })
	begin := time.Now()
	start()
	start()
	time.Sleep(150 * time.Millisecond)
	if got := d.dials.Load(); got != 1 && time.Since(begin) < 250*time.Millisecond {
		t.Fatalf("waiters behind a fresh leader dialed: %d dials", got)
	}
	waitFor(t, "a waiter to replace the stale leader", time.Second, func() bool { return d.dials.Load() == 2 })
	waitFor(t, "the last waiter to replace the next one", time.Second, func() bool { return d.dials.Load() == 3 })
	wg.Wait()
	if got := d.dials.Load(); got != 3 {
		t.Fatalf("%d dials for three requests, want 3", got)
	}
	waitFor(t, "abandoned dials to close", time.Second, func() bool { return d.open.Load() == 0 })
}

// Запрос получил соединение, оно его не приняло, и net/http ищет заново.
// Dial прошлого поиска net/http запускает в своей горутине, и он может
// начаться уже после dial'а нового: ожидание нового он не трогает. Dial,
// опоздавший к уже нашедшему соединение поиску, не нужен никому.
func TestCoalesceDialsLateDialOfEarlierGetConn(t *testing.T) {
	rt := &dialRoundTrip{donec: make(chan struct{})}
	rt.getConn()
	rt.gotConn()
	rt.getConn()
	c2, retried, done := rt.startDial()
	if done || !retried {
		t.Fatalf("dial of the second getConn: done=%v retried=%v, want a retried dial", done, retried)
	}
	if _, _, done := rt.startDial(); done {
		t.Fatal("a late dial of the first getConn was refused while the second still waits")
	}
	select {
	case <-c2:
		t.Fatal("a late dial of the first getConn released the second getConn's dial")
	default:
	}
	rt.gotConn()
	select {
	case <-c2:
	default:
		t.Fatal("GotConn did not release the dial")
	}
	if _, _, done := rt.startDial(); !done {
		t.Fatal("a dial after the last getConn got a connection was not refused")
	}
	rt.finish()
	if _, _, done := rt.startDial(); !done {
		t.Fatal("a dial after RoundTrip returned was not refused")
	}
}
