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
// начинается запасной, как backup connect job у Chrome, и залп идёт по нему.
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
	if took >= coalescedBackupAfter+500*time.Millisecond {
		t.Fatalf("burst behind a lost SYN took %v: no backup dial", took)
	}
	if got := d.dials.Load(); got != 3 {
		t.Fatalf("%d dials, want warm-up, the stuck one and one backup", got)
	}
}

// Первый dial клиента и единственный запрос: запасной не ждёт ни истории, ни
// второго запроса. У Chrome backup job тоже от них не зависит.
func TestCoalesceDialsBackupForLoneFirstRequest(t *testing.T) {
	addr := okServer(t)
	var d dialCounter
	mk := dialFactory(t, &d, func(int64) string { return addr }, func(n int64) time.Duration {
		if n == 1 {
			return 3 * time.Second
		}
		return 0
	}, nil)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	start := time.Now()
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

// Рабочий путь: dial укладывается в coalescedBackupAfter, запасных нет.
func TestCoalesceDialsBackupQuietOnHealthyPath(t *testing.T) {
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

// TCP ведущего поднялся сразу, а рукопожатие идёт 600 мс. Браузер второго
// ClientHello на медленное рукопожатие не шлёт, и мы не шлём: ни запасного,
// ни своих dial'ов у ждущих, залп ждёт ведущего и идёт по одному соединению.
func TestCoalesceDialsOneConnOnSlowHandshake(t *testing.T) {
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
	if got := d.dials.Load(); got != 2 {
		t.Fatalf("%d dials, want warm-up and the slow one: no second ClientHello while a handshake runs", got)
	}
	if took < 600*time.Millisecond {
		t.Fatalf("burst took %v, faster than its only handshake", took)
	}
}

// Запасной dial сразу получает отказ (сброс, закрытый порт), а застрявший
// ведущий через 600 мс дозванивается. Отказ запасного залп не роняет: ведущий
// дозванивается, и все идут по нему.
func TestCoalesceDialsFailedBackupKeepsLeader(t *testing.T) {
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
		t.Fatalf("%d of 30 requests failed with the backup's error", failed)
	}
	if took >= time.Second {
		t.Fatalf("burst took %v: waited past the leader's dial", took)
	}
	if got := d.dials.Load(); got != 3 {
		t.Fatalf("%d dials, want warm-up, the slow leader and the refused backup", got)
	}
}

// Блокировка после ClientHello: TCP поднимается, запасного нет, и пока попытка
// висит, второй не начинается: попытки сменяют друг друга по
// coalescedAttemptTimeout, и сокет в полёте один.
func TestCoalesceDialsOneAttemptOnBlackhole(t *testing.T) {
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
	want := int64(2500*time.Millisecond/coalescedAttemptTimeout) + 1
	if got := d.dials.Load() - 1; got != want {
		t.Fatalf("%d dials into the blackhole in 2.5s, want %d: one per attempt bound", got, want)
	}
	if got := d.maxOpen.Load(); got > 1 {
		t.Fatalf("%d sockets open at once, want 1", got)
	}
	waitFor(t, "abandoned dials to close", 2*time.Second, func() bool { return d.open.Load() == 0 })
}

// lagConn — соединение канала с задержкой rtt: всё, что присылает сервер,
// приходит через rtt после отправки. Запись уходит сразу, так что круг
// «запрос — ответ» стоит одну rtt, как на настоящем канале.
type lagConn struct {
	net.Conn
	rtt    time.Duration
	chunks chan lagChunk
	buf    []byte
	err    error
}

type lagChunk struct {
	data []byte
	at   time.Time
	err  error
}

func newLagConn(c net.Conn, rtt time.Duration) *lagConn {
	l := &lagConn{Conn: c, rtt: rtt, chunks: make(chan lagChunk, 64)}
	go func() {
		for {
			b := make([]byte, 32<<10)
			n, err := c.Read(b)
			l.chunks <- lagChunk{b[:n], time.Now().Add(rtt), err}
			if err != nil {
				return
			}
		}
	}()
	return l
}

func (l *lagConn) Read(b []byte) (int, error) {
	for len(l.buf) == 0 {
		if l.err != nil {
			return 0, l.err
		}
		ch := <-l.chunks
		time.Sleep(time.Until(ch.at))
		l.buf, l.err = ch.data, ch.err
	}
	n := copy(b, l.buf)
	l.buf = l.buf[n:]
	return n, nil
}

// Медленный, но живой канал: TCP устанавливается за rtt, рукопожатие идёт
// ещё rtt, всего 2,5 и 4 с, больше coalescedAttemptTimeout. Попытка
// заменяется, а не идёт параллельно, но такую не обрывают: срок растёт со
// временем установки TCP и продлевается, пока сервер присылает байты.
func TestCoalesceDialsSlowAliveHandshake(t *testing.T) {
	addr := okServer(t)
	for _, rtt := range []time.Duration{1250 * time.Millisecond, 2 * time.Second} {
		var d dialCounter
		mk := CoalesceDials(func() http.RoundTripper {
			return NewTransport(func(ctx context.Context) (net.Conn, error) {
				d.dials.Add(1)
				select {
				case <-time.After(rtt):
				case <-ctx.Done():
					return nil, ctx.Err()
				}
				c, err := (&net.Dialer{}).DialContext(ctx, "tcp", addr)
				if err != nil {
					return nil, err
				}
				return newLagConn(d.track(c), rtt), nil
			}, func(ctx context.Context, c net.Conn, _ bool) (net.Conn, error) {
				tc := tls.Client(c, &tls.Config{NextProtos: []string{"h2"}, InsecureSkipVerify: true})
				if err := tc.HandshakeContext(ctx); err != nil {
					return nil, err
				}
				return tc, nil
			}, nil, nil, 0)
		})
		rt := mk()
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		start := time.Now()
		err := roundTrip(rt, ctx)
		cancel()
		rt.(*coalescingTransport).CloseIdleConnections()
		if err != nil {
			t.Fatalf("rtt %v: request over a slow live path failed after %v: %v", rtt, time.Since(start), err)
		}
		// Ведущий и, может быть, запасной: TCP идёт дольше coalescedBackupAfter.
		if got := d.dials.Load(); got > 2 {
			t.Fatalf("rtt %v: %d dials, want no attempt cut on a live path", rtt, got)
		}
	}
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
