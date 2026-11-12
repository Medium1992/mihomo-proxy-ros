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

// dialFactory — фабрика h2-транспортов XHTTP одного клиента со склейкой.
// target и delay решают за каждый dial по его номеру (с 1), куда он идёт и
// сколько ждёт перед TCP, — так изображаются потерянный SYN и блокировка.
// tlsDelay, если не nil, — сколько рукопожатие с этим номером (с 1) ждёт
// после установленного TCP, — так изображается медленный ClientHello.
func dialFactory(t *testing.T, d *dialCounter, target func(n int64) string, delay func(n int64) time.Duration, tlsDelay func(n int64) time.Duration) TransportMaker {
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

// Клиент уже дозванивался, теперь холодный залп на свежем транспорте, и SYN
// ведущего потерян: его dial стоит до TCP. Через coalescedBackupAfter
// начинается запасной, как backup connect job у Chrome, и залп идёт по нему
// раньше, чем истечёт coalescedThrottle ждущих.
func TestCoalesceDialsBackupOnLostSYN(t *testing.T) {
	addr := okServer(t)
	var d dialCounter
	mk := dialFactory(t, &d, func(int64) string { return addr }, func(n int64) time.Duration {
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
	if took >= coalescedThrottle+200*time.Millisecond {
		t.Fatalf("burst behind a lost SYN took %v: no backup dial", took)
	}
	if got := d.dials.Load(); got != 3 {
		t.Fatalf("%d dials, want warm-up, the stuck one and one backup", got)
	}
}

// Одиночный запрос без ждущих тоже получает запасной dial: у Chrome backup job
// не зависит от числа запросов.
func TestCoalesceDialsBackupForLoneRequest(t *testing.T) {
	addr := okServer(t)
	var d dialCounter
	mk := dialFactory(t, &d, func(int64) string { return addr }, func(n int64) time.Duration {
		if n == 1 {
			return 3 * time.Second
		}
		return 0
	}, nil)
	start := time.Now()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if err := roundTrip(mk(), ctx); err != nil {
		t.Fatal(err)
	}
	if took := time.Since(start); took > time.Second {
		t.Fatalf("lone request behind a lost SYN took %v", took)
	}
	if got := d.dials.Load(); got != 2 {
		t.Fatalf("%d dials, want the stuck one and one backup", got)
	}
}

// Рабочий путь: dial укладывается в coalescedBackupAfter и coalescedThrottle,
// ни запасных, ни своих dial'ов у ждущих нет.
func TestCoalesceDialsQuietOnHealthyPath(t *testing.T) {
	addr := okServer(t)
	var d dialCounter
	mk := dialFactory(t, &d, func(int64) string { return addr }, func(n int64) time.Duration {
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

// TCP ведущего поднялся сразу, а рукопожатие идёт 600 мс. Запасного нет: на
// повисшее рукопожатие второй ClientHello не шлют. Но ждущие, не дождавшись за
// coalescedThrottle, дозваниваются сами, как запросы Chrome после
// kHTTP2ThrottleMs, и всего dial'ов не больше coalescedMaxDials.
func TestCoalesceDialsSlowHandshakeThrottled(t *testing.T) {
	addr := okServer(t)
	var d dialCounter
	mk := dialFactory(t, &d, func(int64) string { return addr }, func(int64) time.Duration { return 0 }, func(n int64) time.Duration {
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
	if took >= 600*time.Millisecond {
		t.Fatalf("burst took %v: waited for the slow handshake instead of dialing after the throttle", took)
	}
	if got := d.dials.Load() - 1; got < 2 || got > int64(coalescedMaxDials) {
		t.Fatalf("%d dials for the burst, want the slow one plus waiters' own, at most %d", got, coalescedMaxDials)
	}
}

// Все dial'ы медленные (600 мс до TCP), но живые: запасной и свои dial'ы
// ждущих упираются в coalescedMaxDials, лишних нет.
func TestCoalesceDialsSlowPathCapped(t *testing.T) {
	addr := okServer(t)
	var d dialCounter
	mk := dialFactory(t, &d, func(int64) string { return addr }, func(int64) time.Duration { return 600 * time.Millisecond }, nil)
	failed, _ := burst(mk(), 30, 5*time.Second)
	if failed != 0 {
		t.Fatalf("%d of 30 requests failed", failed)
	}
	if got := d.dials.Load(); got > int64(coalescedMaxDials) {
		t.Fatalf("%d dials, want at most %d", got, coalescedMaxDials)
	}
	if got := d.maxOpen.Load(); got > int64(coalescedMaxDials) {
		t.Fatalf("%d sockets open at once, want at most %d", got, coalescedMaxDials)
	}
}

// Запасной и свои dial'ы ждущих сразу получают отказ (сброс, закрытый порт), а
// застрявший ведущий через 600 мс дозванивается. Ошибка отказавших не роняет
// запросы, пока ведущий жив: они ждут его, и каждый запрос дозванивается сам
// не больше одного раза.
func TestCoalesceDialsFailedDialsFallBackToLeader(t *testing.T) {
	addr := okServer(t)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	refused := ln.Addr().String()
	ln.Close()
	var d dialCounter
	mk := dialFactory(t, &d, func(n int64) string {
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
		t.Fatalf("%d of 30 requests failed with a refused dial's error", failed)
	}
	if took >= time.Second {
		t.Fatalf("burst took %v: waited past the leader's dial", took)
	}
	// Разогрев, ведущий, запасной и не больше одного своего на ждущего.
	if got := d.dials.Load(); got > 3+29 {
		t.Fatalf("%d dials, want at most one per waiter", got)
	}
}

// Блокировка после ClientHello у клиента: TCP поднимается, запасного нет, ждущие
// через coalescedThrottle дозваниваются сами до coalescedMaxDials, и дальше,
// пока попытки висят, новых нет: повторного dial'а по таймеру нет.
func TestCoalesceDialsBlackholeCapped(t *testing.T) {
	addr := okServer(t)
	hole := blackholeServer(t)
	var d dialCounter
	mk := dialFactory(t, &d, func(n int64) string {
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
	failed, _ := burst(mk(), 50, 2500*time.Millisecond)
	if failed != 50 {
		t.Fatalf("%d of 50 requests failed, want all", failed)
	}
	if got := d.dials.Load() - 1; got > int64(coalescedMaxDials) {
		t.Fatalf("%d dials into the blackhole in 2.5s, want at most %d", got, coalescedMaxDials)
	}
	if got := d.maxOpen.Load(); got > int64(coalescedMaxDials) {
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
