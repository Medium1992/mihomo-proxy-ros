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
//   - повторный поиск соединения тем же запросом (соединение его не
//     приняло) за удачным ведущим не встаёт, а дозванивается сразу;
//   - за ведущим, который дозванивается дольше coalescedDialStale, не ждут:
//     новый запрос или один из ждущих дозванивается сам;
//   - если TCP ведущего не установлен за вдвое большее время, чем обычный
//     dial этого клиента, один из ждущих начинает запасной dial
//     (coalescedHedgeMin); упал запасной — его ждущие возвращаются к
//     ведущему.

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

// coalescedDialStale — дольше этого рукопожатие на рабочем пути не идёт, и
// ведущий, скорее всего, повис: блокировка после ClientHello помнит поток, и
// снятие блокировки его не оживит. За таким ведущим не ждут: первый из ждущих,
// заметивший срок, дозванивается сам, остальные встают за ним, а запрос,
// пришедший позже, замечает срок сразу. Иначе залп страницы, начатый во время
// блокировки, держал бы повисший dial до coalescedDialTimeout, и сессии,
// пришедшие уже после снятия блокировки, ждали бы его. Удачный новый dial
// кладёт соединение в пул, и его получают и те, кто ждал старого ведущего.
// Пока путь заблокирован, на адрес идёт не больше одного нового dial'а в
// coalescedDialStale, и каждый расходует одного ждущего. Срок больше
// рукопожатия REALITY на медленном мобильном канале (0,6–0,9 с): меньший
// давал бы там лишние dial'ы.
var coalescedDialStale = time.Second

// coalescedHedgeMin — нижняя граница срока запасного dial'а. Потерянный SYN
// ядро повторит только через секунду, и весь холодный залп ждал бы этого
// повтора, а сток в это время шёл бы по соседним dial'ам. Поэтому, если TCP
// ведущего не установлен за вдвое большее время, чем сглаженное время dial'а
// (dialHistory), один из ждущих начинает запасной dial, а остальные встают за
// ним; соединение того, кто успеет первым, net/http раздаст всем. Так делают и
// браузеры: запасное TCP-соединение через 250 мс у Chrome (backup connect job)
// и у Firefox (network.http.connection-retry-timeout), и тоже только пока TCP
// не установлен. Когда TCP поднялся и идёт рукопожатие, второй ClientHello к
// тому же серверу браузер не шлёт, и мы не шлём: медленное рукопожатие ждём
// по coalescedDialStale. Нижняя граница — чтобы на быстром канале шум не
// давал лишних dial'ов, верхняя — coalescedDialStale: дальше работает уже то
// правило.
// Запасной dial бывает только у обычного ведущего: у самого запасного и у
// ведущих после coalescedDialStale его нет, так что одновременно идут не
// больше двух dial'ов, а под блокировкой их по-прежнему не больше одного
// нового в coalescedDialStale. Без истории (первый dial клиента) срок не
// угадываем, запасного dial'а нет. Запасной, упавший раньше ведущего
// (скажем, сброс соединения), ждущих не роняет: они возвращаются к ведущему и
// ждут его по coalescedDialStale, как ждали бы без запасного.
var coalescedHedgeMin = 250 * time.Millisecond

var errCoalescedDialAbandoned = errors.New("xhttp: coalesced dial abandoned")

type dialTCPUpKey struct{}

// DialTCPUp отмечает, что TCP dial'а с контекстом ctx установлен и дальше
// идёт рукопожатие. Его зовёт DialTLSContext h2-транспорта (NewTransport)
// между dialRaw и wrapTLS: с этого момента запасной dial ведущему не положен.
func DialTCPUp(ctx context.Context) {
	if up, ok := ctx.Value(dialTCPUpKey{}).(func()); ok {
		up()
	}
}

type dialRoundTripKey struct{}

// dialRoundTrip — состояние одного RoundTrip, видимое из DialTLSContext:
// контекст dial'а net/http отвязывает от отмены запроса, но значения хранит.
type dialRoundTrip struct {
	mu       sync.Mutex
	done     bool
	getConns int           // сколько раз net/http искал соединение ради этого RoundTrip
	donec    chan struct{} // закрыт, когда RoundTrip вернулся
	gotConnc chan struct{} // закрыт, когда последний поиск соединения закончился
}

// getConn вызывается хуком GetConn в начале каждого поиска соединения
// (net/http ищет заново, если h2-соединение не приняло запрос). Поиски одного
// запроса идут друг за другом, и новый значит, что прошлый уже получил
// соединение: его dial, если он ещё ждёт ведущего, больше не нужен.
//
// Отмечать поиск здесь, а не в dial'е: dial net/http запускает в своей
// горутине, и dial прошлого поиска может начаться позже dial'а нового.
func (s *dialRoundTrip) getConn() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.gotConnc != nil {
		close(s.gotConnc)
	}
	s.gotConnc = make(chan struct{})
	s.getConns++
}

// startDial вызывается в начале каждого dial'а этого RoundTrip. done —
// дозваниваться не для кого: RoundTrip вернулся или последний поиск уже
// получил соединение, а dial опоздал. retried — соединение запрос уже
// получал, и оно его не приняло.
func (s *dialRoundTrip) startDial() (gotConnc chan struct{}, retried bool, done bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.done || s.gotConnc == nil {
		return nil, false, true
	}
	return s.gotConnc, s.getConns > 1, false
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
	started time.Time     // когда начат dial
	// hedgeable — обычный ведущий: ему положен запасной dial. Нет у
	// запасного и у ведущих, начатых после ухода от прежнего.
	hedgeable bool
	hedgeOf   *leaderDial // у запасного — ведущий, за которым ждали до него
	guard     *guardedDial
	tcpUp     chan struct{} // закрыт, когда TCP ведущего установлен
	tcpUpOnce sync.Once
	// Под coalescingTransport.mu.
	refs   int  // RoundTrip'ы, которые этот dial ждут
	hedged bool // запасной уже начат: второго не будет
}

type coalescingTransport struct {
	*http.Transport
	hist    *dialHistory
	mu      sync.Mutex
	leaders map[string]*leaderDial // по адресу, как ключ пула net/http
}

// dialHistory — сглаженное время удачного dial'а по адресам, общее для всех
// транспортов одной фабрики, то есть одного клиента XHTTP и одного
// направления. Холодный залп — это как раз свежие транспорты, и замер внутри
// транспорта не набрался бы никогда. Глобальным его делать нельзя: адрес —
// это хост из URL, и прокси за одним CDN-хостом на разных серверах смешали бы
// замеры. Сглаживание как у SRTT в TCP (вес 1/8): один медленный dial, скажем
// после смены сети, не растягивает срок сразу, а новая сеть подтягивается за
// несколько рукопожатий.
type dialHistory struct {
	mu   sync.Mutex
	srtt map[string]time.Duration
}

func (h *dialHistory) observe(addr string, d time.Duration) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.srtt == nil {
		h.srtt = make(map[string]time.Duration)
	}
	if old, ok := h.srtt[addr]; ok {
		d = old + (d-old)/8
	}
	h.srtt[addr] = d
}

// hedgeAfter — через сколько после начала dial'а ведущего начинать запасной.
// ok = false — истории нет или срок не меньше coalescedDialStale.
func (h *dialHistory) hedgeAfter(addr string) (d time.Duration, ok bool) {
	if h == nil {
		return 0, false
	}
	h.mu.Lock()
	srtt, ok := h.srtt[addr]
	h.mu.Unlock()
	if !ok {
		return 0, false
	}
	d = 2 * srtt
	if d < coalescedHedgeMin {
		d = coalescedHedgeMin
	}
	return d, d < coalescedDialStale
}

// CoalesceDials оборачивает фабрику так, что у её HTTP/2-транспортов dial'ы
// склеены. Остальные проходят как есть: в HTTP/1.1 соединение на запрос
// задумано, а http3.Transport склеивает dial'ы сам.
func CoalesceDials(mk TransportMaker) TransportMaker {
	if mk == nil {
		return nil
	}
	hist := &dialHistory{}
	return func() http.RoundTripper {
		rt := mk()
		t, ok := rt.(*http.Transport)
		if !ok || t.DialTLSContext == nil || t.Protocols == nil || !t.Protocols.UnencryptedHTTP2() {
			return rt
		}
		c := &coalescingTransport{Transport: t, hist: hist}
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
	// WithClientTrace добавляет хуки к уже стоящему трейсу, а не заменяет его:
	// GotConn клиента XHTTP по-прежнему вызывается.
	ctx = httptrace.WithClientTrace(ctx, &httptrace.ClientTrace{
		GetConn: func(string) { rt.getConn() },
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
	// Пока этот запрос не уходил от ведущего, его dial обычный; ушёл —
	// запасной или после повисшего, и запасного ему уже не положено.
	hedgeable := true
	var hedgeOf *leaderDial
	for {
		var (
			conn          net.Conn
			err           error
			again, hedged bool
		)
		c.mu.Lock()
		l := c.leaders[addr]
		if l != nil && retried && l.succeeded() {
			// Соединение ведущего этот запрос уже получал, и оно его не
			// приняло (упёрлось в MAX_CONCURRENT_STREAMS): ждать его снова
			// незачем, нужно новое.
			delete(c.leaders, addr)
			l = nil
		}
		hedge := true
		if l == nil && hedgeOf != nil {
			switch {
			case !hedgeOf.hedged:
				hedgeOf.hedged = true
			case alive(hedgeOf):
				// Запасной у ведущего уже был и упал, пока мы шли за ним:
				// ждём ведущего дальше, второго запасного не начинаем.
				l, hedge = hedgeOf, false
			default:
				hedgeOf = nil
			}
		}
		if l == nil {
			g, gctx := newGuardedDial(ctx)
			l = &leaderDial{dialc: make(chan struct{}), rtDonec: rt.donec, started: time.Now(), hedgeable: hedgeable, hedgeOf: hedgeOf, guard: g, tcpUp: make(chan struct{}), refs: 1}
			gctx = context.WithValue(gctx, dialTCPUpKey{}, l.markTCPUp)
			if c.leaders == nil {
				c.leaders = make(map[string]*leaderDial)
			}
			c.leaders[addr] = l
			c.mu.Unlock()
			conn, err = c.lead(gctx, l, rt, dial, network, addr)
		} else {
			l.refs++
			c.mu.Unlock()
			conn, err, again, hedged = c.follow(ctx, l, rt, gotConnc, addr, hedge)
		}
		if err != nil {
			if p := c.rejoin(l); p != nil {
				// Упал запасной, а ведущий, за которым мы ждали до него, ещё
				// жив: ждём его дальше, уже без запасного.
				l = p
				conn, err, again, _ = c.follow(ctx, l, rt, gotConnc, addr, false)
			}
		}
		if !again {
			return conn, err
		}
		// Соединение ведущего нам не досталось, он повис или пора запасному:
		// снимаем его, чтобы на следующем круге стать ведущим самим, а не
		// ждать его снова. Если его уже сменил другой, встаём за новым.
		// Сам ведущий при этом дозванивается дальше.
		c.unlead(l, addr)
		hedgeable = false
		hedgeOf = nil
		if hedged {
			hedgeOf = l
		}
	}
}

// rejoin — к кому вернуться ждущим упавшего dial'а l: к ведущему, запасным
// которого был l, если тот ещё жив. Он остаётся занятым этим RoundTrip'ом,
// как при обычном follow.
func (c *coalescingTransport) rejoin(l *leaderDial) *leaderDial {
	p := l.hedgeOf
	if p == nil {
		return nil
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if !alive(p) {
		return nil
	}
	p.refs++
	return p
}

// alive — dial l ещё идёт или удался, то есть ждать его есть смысл. Вызывается
// под coalescingTransport.mu.
func alive(l *leaderDial) bool {
	select {
	case <-l.dialc:
		return l.err == nil
	default:
		// Без ждущих он оборван и вот-вот вернёт ошибку.
		return l.refs > 0
	}
}

// follow ждёт ведущего l. again — ведущий дозвонился, а соединение нашему
// запросу так и не досталось, ведущий повис или пора запасному dial'у: пора
// дозваниваться самим; hedged — именно запасному. hedge = false — запасного
// не ждать, даже если ведущему он положен.
func (c *coalescingTransport) follow(ctx context.Context, l *leaderDial, rt *dialRoundTrip, gotConnc chan struct{}, addr string, hedge bool) (conn net.Conn, err error, again, hedged bool) {
	defer c.release(l, addr)
	dialc, rtDonec := l.dialc, l.rtDonec
	var retry <-chan time.Time
	wait := coalescedDialStale
	if hedge && l.hedgeable {
		if d, ok := c.hist.hedgeAfter(addr); ok {
			wait, hedged = d, true
		}
	}
	var tcpUp <-chan struct{}
	if hedged {
		tcpUp = l.tcpUp
		select {
		case <-tcpUp:
			// TCP ведущего уже установлен: запасного не будет.
			wait, hedged, tcpUp = coalescedDialStale, false, nil
		default:
		}
	}
	stale := time.NewTimer(time.Until(l.started.Add(wait)))
	defer func() { stale.Stop() }()
	// Канал, а не stale.C в select: при go 1.20 в go.mod остановленный таймер
	// может оставить в канале значение.
	staleC := stale.C
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
				return nil, l.err, false, false
			}
			dialc = nil
			staleC = nil
		case <-staleC:
			staleC = nil
			select {
			case <-l.dialc:
				// Dial закончился на самом сроке: разбираем его как обычно.
			default:
				return nil, nil, true, hedged
			}
		case <-tcpUp:
			// TCP ведущего установлен раньше срока запасного: дальше идёт
			// рукопожатие, и его ждём по coalescedDialStale, как без запасного.
			tcpUp = nil
			if staleC != nil {
				stale.Stop()
				stale = time.NewTimer(time.Until(l.started.Add(coalescedDialStale)))
				staleC = stale.C
			}
			hedged = false
		case <-rtDonec:
			rtDonec = nil
		case <-retry:
			return nil, nil, true, false
		case <-rt.donec:
			return nil, errCoalescedDialAbandoned, false, false
		case <-gotConnc:
			// Запрос получил соединение, этот dial ему больше не нужен.
			return nil, errCoalescedDialAbandoned, false, false
		case <-ctx.Done():
			return nil, ctx.Err(), false, false
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
	c.hist.observe(addr, time.Since(l.started))
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

func (l *leaderDial) markTCPUp() {
	l.tcpUpOnce.Do(func() { close(l.tcpUp) })
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
