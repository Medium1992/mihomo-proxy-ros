package xhttp

import (
	"context"
	"crypto/tls"
	"net"
	"sync/atomic"
	"testing"
	"time"

	"github.com/metacubex/http"
)

// hedgeFactory — фабрика h2-транспортов XHTTP одного клиента со склейкой.
// target и delay решают за каждый dial по его номеру (с 1), куда он идёт и
// сколько ждёт перед TCP, — так изображаются потерянный SYN и блокировка.
// tlsDelay, если не nil, — сколько рукопожатие с этим номером (с 1) ждёт
// после установленного TCP, — так изображается медленный ClientHello.
func hedgeFactory(t *testing.T, d *dialCounter, target func(n int64) string, delay func(n int64) time.Duration, tlsDelay func(n int64) time.Duration) TransportMaker {
	t.Helper()
	var handshakes atomic.Int64
	mk := CoalesceDials(func() http.RoundTripper {
		return NewTransport(func(ctx context.Context) (net.Conn, error) {
			n := d.dials.Add(1)
			if wait := delay(n); wait > 0 {
				select {
				case <-time.After(wait):
				case <-ctx.Done():
					return nil, ctx.Err()
				}
			}
			c, err := (&net.Dialer{}).DialContext(ctx, "tcp", target(n))
			if err != nil {
				return nil, err
			}
			return d.track(c), nil
		}, func(ctx context.Context, c net.Conn, _ bool) (net.Conn, error) {
			if n := handshakes.Add(1); tlsDelay != nil {
				if wait := tlsDelay(n); wait > 0 {
					select {
					case <-time.After(wait):
					case <-ctx.Done():
						return nil, ctx.Err()
					}
				}
			}
			tc := tls.Client(c, &tls.Config{NextProtos: []string{"h2"}, InsecureSkipVerify: true})
			if err := tc.HandshakeContext(ctx); err != nil {
				return nil, err
			}
			return tc, nil
		}, nil, nil, 0)
	})
	return func() http.RoundTripper {
		rt := mk()
		if _, ok := rt.(*coalescingTransport); !ok {
			t.Fatalf("h2 transport was not wrapped: %T", rt)
		}
		t.Cleanup(func() { rt.(*coalescingTransport).CloseIdleConnections() })
		return rt
	}
}

func okServer(t *testing.T) string {
	return h2TestServer(t, 0, func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("ok")) })
}

func TestCoalesceDialsHedgeHistory(t *testing.T) {
	var h *dialHistory
	if _, ok := h.hedgeAfter("a"); ok {
		t.Fatal("nil history gave a hedge delay")
	}
	h = &dialHistory{}
	if _, ok := h.hedgeAfter("a"); ok {
		t.Fatal("empty history gave a hedge delay")
	}
	h.observe("a", 10*time.Millisecond)
	if d, ok := h.hedgeAfter("a"); !ok || d != coalescedHedgeMin {
		t.Fatalf("fast path: hedge after %v, %v; want the %v floor", d, ok, coalescedHedgeMin)
	}
	if _, ok := h.hedgeAfter("b"); ok {
		t.Fatal("history leaked to another address")
	}
	h = &dialHistory{}
	h.observe("a", 100*time.Millisecond)
	h.observe("a", 900*time.Millisecond)
	if d, ok := h.hedgeAfter("a"); !ok || d != 400*time.Millisecond {
		t.Fatalf("one slow dial after 100ms: hedge after %v, %v; want 400ms (smoothed to 200ms)", d, ok)
	}
	h = &dialHistory{}
	h.observe("a", 600*time.Millisecond)
	if d, ok := h.hedgeAfter("a"); ok {
		t.Fatalf("slow path: hedge after %v; want none at or past coalescedDialStale", d)
	}
}

// Клиент уже дозванивался, теперь холодный залп на свежем транспорте, и dial
// ведущего застрял, как при потерянном SYN. Запасной dial начинается по
// замеру клиента, а не через coalescedDialStale, и залп идёт по нему.
func TestCoalesceDialsHedgeUsesClientHistory(t *testing.T) {
	addr := okServer(t)
	var d dialCounter
	mk := hedgeFactory(t, &d, func(int64) string { return addr }, func(n int64) time.Duration {
		if n == 2 {
			return 3 * time.Second
		}
		return 0
	}, nil)
	if err := roundTrip(mk(), context.Background()); err != nil {
		t.Fatal(err)
	}
	failed, took := burst(mk(), 30, 5*time.Second)
	if failed != 0 {
		t.Fatalf("%d of 30 requests failed", failed)
	}
	if took >= 800*time.Millisecond {
		t.Fatalf("burst behind a stuck dial took %v: no hedge before coalescedDialStale", took)
	}
	if got := d.dials.Load(); got != 3 {
		t.Fatalf("%d dials, want warm-up, the stuck one and one hedge", got)
	}
}

// Первый dial клиента: истории нет, срок не угадываем. Медленный, но живой
// dial запасного не получает.
func TestCoalesceDialsNoHedgeWithoutHistory(t *testing.T) {
	addr := okServer(t)
	var d dialCounter
	mk := hedgeFactory(t, &d, func(int64) string { return addr }, func(int64) time.Duration { return 600 * time.Millisecond }, nil)
	failed, took := burst(mk(), 30, 5*time.Second)
	if failed != 0 {
		t.Fatalf("%d of 30 requests failed", failed)
	}
	if got := d.dials.Load(); got != 1 {
		t.Fatalf("%d dials without history, want 1", got)
	}
	if took < 600*time.Millisecond {
		t.Fatalf("burst took %v, faster than its only dial", took)
	}
}

// Рабочий путь с историей: dial укладывается в срок, запасных нет.
func TestCoalesceDialsHedgeQuietOnHealthyPath(t *testing.T) {
	addr := okServer(t)
	var d dialCounter
	mk := hedgeFactory(t, &d, func(int64) string { return addr }, func(n int64) time.Duration {
		if n == 1 {
			return 0
		}
		return 100 * time.Millisecond
	}, nil)
	if err := roundTrip(mk(), context.Background()); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 3; i++ {
		if failed, _ := burst(mk(), 30, 5*time.Second); failed != 0 {
			t.Fatalf("burst %d: %d of 30 requests failed", i, failed)
		}
	}
	if got := d.dials.Load(); got != 4 {
		t.Fatalf("%d dials for warm-up and three cold bursts, want 4", got)
	}
}

// TCP ведущего поднялся сразу, а рукопожатие идёт 600 мс. Браузер второго
// ClientHello на медленное рукопожатие не шлёт, и мы не шлём: запасного dial'а
// нет, залп ждёт ведущего.
func TestCoalesceDialsNoHedgeOnSlowHandshake(t *testing.T) {
	addr := okServer(t)
	var d dialCounter
	mk := hedgeFactory(t, &d, func(int64) string { return addr }, func(int64) time.Duration { return 0 }, func(n int64) time.Duration {
		if n == 2 {
			return 600 * time.Millisecond
		}
		return 0
	})
	if err := roundTrip(mk(), context.Background()); err != nil {
		t.Fatal(err)
	}
	failed, took := burst(mk(), 30, 5*time.Second)
	if failed != 0 {
		t.Fatalf("%d of 30 requests failed", failed)
	}
	if got := d.dials.Load(); got != 2 {
		t.Fatalf("%d dials, want warm-up and the slow one: no second ClientHello while a handshake runs", got)
	}
	if took < 600*time.Millisecond {
		t.Fatalf("burst took %v, faster than its only handshake", took)
	}
}

// Запасной dial сразу получает отказ (сброс, закрытый порт), а застрявший
// ведущий через 600 мс дозванивается. Вставшие за запасным не падают с его
// ошибкой, а дожидаются ведущего, как без запасного. Ждущие уходят к
// запасному разом, и кто дошёл, когда он уже упал, второго не начинает:
// отказ получил бы и он, и так по dial'у на ждущего.
func TestCoalesceDialsFailedHedgeFallsBackToLeader(t *testing.T) {
	addr := okServer(t)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	refused := ln.Addr().String()
	ln.Close()
	var d dialCounter
	mk := hedgeFactory(t, &d, func(n int64) string {
		if n <= 2 {
			return addr
		}
		return refused
	}, func(n int64) time.Duration {
		if n == 2 {
			return 600 * time.Millisecond
		}
		return 0
	}, nil)
	if err := roundTrip(mk(), context.Background()); err != nil {
		t.Fatal(err)
	}
	failed, took := burst(mk(), 30, 5*time.Second)
	if failed != 0 {
		t.Fatalf("%d of 30 requests failed with the hedge's error", failed)
	}
	if took >= coalescedDialStale {
		t.Fatalf("burst took %v: waited past the leader's dial", took)
	}
	if got := d.dials.Load(); got != 3 {
		t.Fatalf("%d dials, want warm-up, the slow leader and the refused hedge", got)
	}
}

// Блокировка после ClientHello у клиента с историей: TCP поднимается, так что
// запасного dial'а нет, дальше правило coalescedDialStale, и сокетов единицы,
// а не по одному на запрос.
func TestCoalesceDialsHedgeBoundedOnBlackhole(t *testing.T) {
	addr := okServer(t)
	hole := blackholeServer(t)
	var d dialCounter
	mk := hedgeFactory(t, &d, func(n int64) string {
		if n == 1 {
			return addr
		}
		return hole
	}, func(int64) time.Duration { return 0 }, nil)
	warm := mk()
	if err := roundTrip(warm, context.Background()); err != nil {
		t.Fatal(err)
	}
	warm.(*coalescingTransport).CloseIdleConnections()
	waitFor(t, "the warm-up connection to close", time.Second, func() bool { return d.open.Load() == 0 })
	var ends atomic.Int64
	failed, _ := burst(mk(), 50, 2500*time.Millisecond)
	ends.Store(d.dials.Load())
	if failed != 50 {
		t.Fatalf("%d of 50 requests failed, want all", failed)
	}
	// Ведущий, затем новые на ~1 и ~2 с; запасного нет: TCP установлен.
	if got := ends.Load() - 1; got > 3 {
		t.Fatalf("%d dials into the blackhole in 2.5s, want at most 3", got)
	}
	if got := d.maxOpen.Load(); got > 5 {
		t.Fatalf("%d sockets open at once", got)
	}
	waitFor(t, "abandoned dials to close", 2*time.Second, func() bool { return d.open.Load() == 0 })
}

// Соединение ведущего занято его же долгим запросом (лимит в один поток), а
// RoundTrip ведущего не вернётся до конца сессии. Запрос, пришедший, пока
// удачный ведущий держит место, получает от net/http занятое соединение,
// ищет заново и дозванивается сам сразу, а не ждёт ведущего до конца его
// сессии.
func TestCoalesceDialsFollowerOfLongLeader(t *testing.T) {
	release := make(chan struct{})
	addr := h2TestServer(t, 1, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/long" {
			w.WriteHeader(http.StatusOK)
			w.(http.Flusher).Flush()
			select {
			case <-release:
			case <-r.Context().Done():
			}
			return
		}
		w.Write([]byte("ok"))
	})
	var d dialCounter
	rt := coalescedTestTransport(t, addr, &d, 0)

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, "GET", "https://example.com/long", nil)
	if err != nil {
		t.Fatal(err)
	}
	resp, err := rt.RoundTrip(req)
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		close(release)
		resp.Body.Close()
	}()

	start := time.Now()
	ctx2, cancel2 := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel2()
	if err := roundTrip(rt, ctx2); err != nil {
		t.Fatalf("request behind a busy leader connection failed after %v: %v", time.Since(start), err)
	}
	if took := time.Since(start); took > time.Second {
		t.Fatalf("request behind a busy leader connection took %v", took)
	}
	if got := d.dials.Load(); got != 2 {
		t.Fatalf("%d dials, want the leader and one for the second request", got)
	}
}
