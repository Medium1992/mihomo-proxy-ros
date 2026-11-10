package xhttp

import (
	"context"
	"errors"
	"net"
	"os"
	"sync"
	"time"

	"github.com/metacubex/http"
	"github.com/metacubex/http/httptrace"
)

// Склейка dial'ов HTTP/2-транспорта XHTTP.
//
// С переходом клиента на net/http.Transport (MetaCubeX/mihomo bb2f57b0) каждый
// запрос, не нашедший готового соединения, начинает свой dial: для HTTP/1 так
// net/http и задуман («late binding»). Для h2 это значит, что холодный пул или
// рукопожатие, повисшее после ClientHello, дают по TCP-соединению на сессию, а
// max-connections в reuse-settings ограничивает число транспортов, но не
// сокеты под ними. Прежний http2.Transport склеивал dial'ы сам. Так же их
// склеивает x/net после golang/go#81646 (CL 845005), отсюда и устройство:
// первый dial ведущий, остальные ждут его и выходят, как только их запрос
// получил соединение из пула. Ошибку ведущего получают все, кто его ждал.
// В отличие от x/net:
//   - dial, который больше никто не ждёт, обрывается: на этом пути net/http
//     держал бы повисшее рукопожатие, и новые сессии после снятия блокировки
//     ждали бы его вместо того, чтобы дозвониться заново;
//   - удачный ведущий остаётся на месте ещё coalescedDialRetry: запрос,
//     пришедший, пока net/http настраивает h2 и ещё не положил соединение в
//     пул, иначе дозвонился бы сам;
//   - повторный getConn того же запроса (соединение его не приняло) за
//     удачным ведущим не встаёт, а дозванивается сразу.

// coalescedDialRetry — сколько ждущий ждёт соединения после того, как ведущий
// дозвонился и его RoundTrip вернулся, и сколько удачный ведущий держит место.
// Обычно ждущий выходит раньше, по GotConn своего запроса; срок нужен, только
// если соединение ведущего оказалось негодным уже после dial'а, и тогда
// ждущий дозванивается сам. Соединение, упёршееся в MAX_CONCURRENT_STREAMS,
// сюда не относится: на него net/http повторяет getConn, и это новый dial. В
// x/net 50 мс; на слабом роутере путь от выдачи соединения до GotConn бывает
// дольше, и ждущий дозванивался бы зря, а в редком плохом случае лишние
// 200 мс ничего не стоят.
const coalescedDialRetry = 250 * time.Millisecond

// coalescedDialTimeout ограничивает dial ведущего. net/http дозванивается в
// контексте, отвязанном от отмены запроса, а рукопожатие на этом пути срока не
// имеет: повисшее после ClientHello держало бы всех ждущих до таймаута TCP.
// Срок тот же, что у dial'а сессии в tunnel (C.DefaultTCPTimeout): ведущий,
// висящий дольше, уже никому из ждавших не поможет, а новые сессии после
// снятия блокировки ждали бы его, вместо того чтобы дозвониться заново.
var coalescedDialTimeout = 5 * time.Second

var errCoalescedDialAbandoned = errors.New("xhttp: coalesced dial abandoned")

type dialRoundTripKey struct{}

// dialRoundTrip — состояние одного RoundTrip, видимое из DialTLSContext:
// контекст dial'а net/http отвязывает от отмены запроса, но значения хранит.
type dialRoundTrip struct {
	mu       sync.Mutex
	done     bool
	attempts int           // сколько раз net/http звал dial ради этого RoundTrip
	donec    chan struct{} // закрыт, когда RoundTrip вернулся
	gotConnc chan struct{} // закрыт, когда запрос получил соединение
}

// startDial вызывается в начале каждого dial'а этого RoundTrip (net/http
// повторяет getConn, если h2-соединение не приняло запрос). done — RoundTrip
// уже вернулся, дозваниваться не для кого.
//
// Новый getConn значит, что прошлый уже получил соединение, и его dial,
// если он ещё ждёт ведущего, больше не нужен: закрываем ему канал, иначе он
// не дождался бы GotConn и дозвонился бы впустую.
func (s *dialRoundTrip) startDial() (gotConnc chan struct{}, retried bool, done bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.done {
		return nil, false, true
	}
	if s.gotConnc != nil {
		close(s.gotConnc)
	}
	s.gotConnc = make(chan struct{})
	s.attempts++
	return s.gotConnc, s.attempts > 1, false
}

func (s *dialRoundTrip) gotConn() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.gotConnc != nil {
		close(s.gotConnc)
		s.gotConnc = nil
	}
}

func (s *dialRoundTrip) finish() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.done = true
	close(s.donec)
}

// leaderDial — dial, который идёт на самом деле.
type leaderDial struct {
	dialc   chan struct{} // закрыт, когда dial вернулся; err к этому моменту записан
	err     error
	rtDonec chan struct{} // donec RoundTrip, ради которого dial начат
	guard   *guardedDial
	refs    int // под coalescingTransport.mu: RoundTrip'ы, которые этот dial ждут
}

type coalescingTransport struct {
	*http.Transport
	mu      sync.Mutex
	leaders map[string]*leaderDial // по адресу, как ключ пула net/http
}

// CoalesceDials оборачивает фабрику так, что у её HTTP/2-транспортов dial'ы
// склеены. Остальные проходят как есть: в HTTP/1.1 соединение на запрос
// задумано, а http3.Transport склеивает dial'ы сам.
func CoalesceDials(mk TransportMaker) TransportMaker {
	if mk == nil {
		return nil
	}
	return func() http.RoundTripper {
		rt := mk()
		t, ok := rt.(*http.Transport)
		if !ok || t.DialTLSContext == nil || t.Protocols == nil || !t.Protocols.UnencryptedHTTP2() {
			return rt
		}
		c := &coalescingTransport{Transport: t}
		dial := t.DialTLSContext
		t.DialTLSContext = func(ctx context.Context, network, addr string) (net.Conn, error) {
			return c.dial(ctx, dial, network, addr)
		}
		return c
	}
}

func (c *coalescingTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	rt := &dialRoundTrip{donec: make(chan struct{})}
	defer rt.finish()
	ctx := context.WithValue(req.Context(), dialRoundTripKey{}, rt)
	// WithClientTrace добавляет хук к уже стоящему трейсу, а не заменяет его:
	// GotConn клиента XHTTP по-прежнему вызывается.
	ctx = httptrace.WithClientTrace(ctx, &httptrace.ClientTrace{
		GotConn: func(httptrace.GotConnInfo) { rt.gotConn() },
	})
	return c.Transport.RoundTrip(req.WithContext(ctx))
}

func (c *coalescingTransport) dial(ctx context.Context, dial func(context.Context, string, string) (net.Conn, error), network, addr string) (net.Conn, error) {
	rt, _ := ctx.Value(dialRoundTripKey{}).(*dialRoundTrip)
	if rt == nil {
		// Запрос пришёл в обход RoundTrip обёртки: склеивать не с чем.
		return boundedDial(ctx, dial, network, addr)
	}
	gotConnc, retried, done := rt.startDial()
	if done {
		return nil, errCoalescedDialAbandoned
	}
	for {
		c.mu.Lock()
		l := c.leaders[addr]
		if l != nil && retried && l.succeeded() {
			// Соединение ведущего этот запрос уже получал, и оно его не
			// приняло (упёрлось в MAX_CONCURRENT_STREAMS): ждать его снова
			// незачем, нужно новое.
			delete(c.leaders, addr)
			l = nil
		}
		if l == nil {
			g, gctx := newGuardedDial(ctx)
			l = &leaderDial{dialc: make(chan struct{}), rtDonec: rt.donec, guard: g, refs: 1}
			if c.leaders == nil {
				c.leaders = make(map[string]*leaderDial)
			}
			c.leaders[addr] = l
			c.mu.Unlock()
			return c.lead(gctx, l, rt, dial, network, addr)
		}
		l.refs++
		c.mu.Unlock()

		conn, err, again := c.follow(ctx, l, rt, gotConnc, addr)
		if !again {
			return conn, err
		}
		// Соединение ведущего нам не досталось: снимаем его, чтобы на
		// следующем круге стать ведущим самим, а не ждать его снова.
		c.unlead(l, addr)
	}
}

// follow ждёт ведущего l. again — ведущий дозвонился, а соединение нашему
// запросу так и не досталось: пора дозваниваться самим.
func (c *coalescingTransport) follow(ctx context.Context, l *leaderDial, rt *dialRoundTrip, gotConnc chan struct{}, addr string) (conn net.Conn, err error, again bool) {
	defer c.release(l, addr)
	dialc, rtDonec := l.dialc, l.rtDonec
	var retry <-chan time.Time
	for {
		if dialc == nil && rtDonec == nil && retry == nil {
			// Ведущий дозвонился и его RoundTrip вернулся, а нашему
			// соединение не досталось. Либо оно сейчас придёт, либо с
			// соединением ведущего что-то не так; ждём немного и
			// дозваниваемся сами.
			retry = time.After(coalescedDialRetry)
		}
		select {
		case <-dialc:
			if l.err != nil {
				return nil, l.err, false
			}
			dialc = nil
		case <-rtDonec:
			rtDonec = nil
		case <-retry:
			return nil, nil, true
		case <-rt.donec:
			return nil, errCoalescedDialAbandoned, false
		case <-gotConnc:
			// Запрос получил соединение, этот dial ему больше не нужен.
			return nil, errCoalescedDialAbandoned, false
		case <-ctx.Done():
			return nil, ctx.Err(), false
		}
	}
}

func (c *coalescingTransport) lead(ctx context.Context, l *leaderDial, rt *dialRoundTrip, dial func(context.Context, string, string) (net.Conn, error), network, addr string) (net.Conn, error) {
	// Ведущий перестаёт ждать свой dial, когда вернулся его RoundTrip.
	stop := make(chan struct{})
	go func() {
		select {
		case <-rt.donec:
			c.release(l, addr)
		case <-stop:
		}
	}()
	conn, err := l.guard.run(ctx, dial, network, addr)
	close(stop)

	if err != nil {
		// Сначала снимаем ведущего, потом будим ждущих: следующий запрос
		// должен увидеть пустое место и дозвониться заново.
		c.unlead(l, addr)
		l.err = err
		close(l.dialc)
		return conn, err
	}
	close(l.dialc)
	// Удачный ведущий остаётся на месте ещё coalescedDialRetry: net/http
	// кладёт соединение в пул уже после возврата из dial'а, после настройки
	// h2, и сигнала об этом не даёт (GotConn ведущего бывает и раньше).
	// Запрос, пришедший в это окно, пула ещё не находит; снятый ведущий
	// означал бы для него свой dial, а так он ждёт соединение ведущего и
	// получает его из пула.
	time.AfterFunc(coalescedDialRetry, func() { c.unlead(l, addr) })
	return conn, nil
}

// succeeded — dial ведущего закончился удачно.
func (l *leaderDial) succeeded() bool {
	select {
	case <-l.dialc:
		return l.err == nil
	default:
		return false
	}
}

// unlead освобождает место ведущего, если его ещё занимает l.
func (c *coalescingTransport) unlead(l *leaderDial, addr string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.leaders[addr] == l {
		delete(c.leaders, addr)
	}
}

// release снимает с l один ждущий его RoundTrip. Ушёл последний, а dial ещё
// идёт — он обрывается: net/http держит dial ради будущих запросов, но
// повисшее рукопожатие будущим запросам только мешает. Место ведущего
// освобождается сразу, и следующий запрос дозванивается заново, а не ждёт
// обречённый dial.
func (c *coalescingTransport) release(l *leaderDial, addr string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if l.refs--; l.refs > 0 {
		return
	}
	if c.leaders[addr] == l {
		delete(c.leaders, addr)
	}
	l.guard.abort(errCoalescedDialAbandoned)
}

// guardedDial — dial, который можно оборвать по сроку или потому, что он
// больше никому не нужен. Контекст отменяется, только пока dial идёт: после
// удачного dial'а он остаётся живым, как и контекст, который net/http
// передаёт сюда, на случай если обёртки соединения привязывают к нему время
// жизни.
type guardedDial struct {
	mu     sync.Mutex
	cancel context.CancelFunc
	done   bool
	reason error
}

func newGuardedDial(ctx context.Context) (*guardedDial, context.Context) {
	ctx, cancel := context.WithCancel(ctx)
	return &guardedDial{cancel: cancel}, ctx
}

func (g *guardedDial) abort(reason error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.done || g.reason != nil {
		return
	}
	g.reason = reason
	g.cancel()
}

func (g *guardedDial) run(ctx context.Context, dial func(context.Context, string, string) (net.Conn, error), network, addr string) (net.Conn, error) {
	timer := time.AfterFunc(coalescedDialTimeout, func() { g.abort(os.ErrDeadlineExceeded) })
	conn, err := dial(ctx, network, addr)
	timer.Stop()
	g.mu.Lock()
	g.done = true
	reason := g.reason
	g.mu.Unlock()
	if reason == nil {
		return conn, err
	}
	// Dial оборван. Даже если он успел вернуть соединение, его контекст уже
	// отменён, и полагаться на такое соединение нельзя.
	if conn != nil {
		_ = conn.Close()
	}
	if err == nil || errors.Is(err, context.Canceled) {
		err = reason
	}
	return nil, err
}

// boundedDial ограничивает dial сроком coalescedDialTimeout.
func boundedDial(ctx context.Context, dial func(context.Context, string, string) (net.Conn, error), network, addr string) (net.Conn, error) {
	g, ctx := newGuardedDial(ctx)
	return g.run(ctx, dial, network, addr)
}
