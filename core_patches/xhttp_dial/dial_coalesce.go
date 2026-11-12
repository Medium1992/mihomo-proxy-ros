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

// Склейка dial'ов HTTP/2-транспорта XHTTP по образцу Chrome.
//
// С переходом клиента на net/http.Transport (MetaCubeX/mihomo bb2f57b0) каждый
// запрос, не нашедший готового соединения, начинает свой dial: для HTTP/1 так
// net/http и задуман («late binding»). Для h2 это значит, что холодный пул или
// рукопожатие, повисшее после ClientHello, дают по TCP-соединению на сессию, а
// max-connections в reuse-settings ограничивает число транспортов, но не
// сокеты под ними. Прежний http2.Transport склеивал dial'ы сам, x/net после
// golang/go#81646 (CL 845005) тоже: первый dial ведущий, остальные ждут его.
// Здесь склейка устроена так, как Chrome ведёт себя с хостом, о котором знает,
// что он говорит h2 (net/http/http_stream_factory_job.cc,
// net/socket/transport_client_socket_pool.cc, ветка main):
//   - первый dial к адресу ведущий; остальные запросы ждут его до
//     coalescedThrottle, а дождавшись, получают его соединение из пула;
//   - не дождавшийся за coalescedThrottle запрос дозванивается сам, но к
//     адресу идёт не больше coalescedMaxDials dial'ов сразу; когда все места
//     заняты, запрос ждёт, пока dial закончится, или соединение из пула;
//   - пока TCP ведущего не установлен за coalescedBackupAfter, а других
//     dial'ов к адресу нет, начинается один запасной (coalescedBackupAfter);
//   - повторных dial'ов по таймеру, пока попытки идут, нет: каждая живёт до
//     своего coalescedDialTimeout.
// В отличие от Chrome и x/net:
//   - dial, который больше никто не ждёт, обрывается: net/http держал бы
//     повисшее рукопожатие ради будущих запросов, а оно им только мешает;
//   - удачный ведущий остаётся на месте ещё coalescedDialRetry: запрос,
//     пришедший, пока net/http настраивает h2 и ещё не положил соединение в
//     пул, иначе дозвонился бы сам;
//   - повторный поиск соединения тем же запросом (соединение его не
//     приняло) за удачным ведущим не встаёт, а дозванивается сразу; Chrome в
//     этом случае ставит поток в очередь сессии, но потоки XHTTP живут часами,
//     и очередь держала бы новые сессии до чужого закрытия;
//   - упавший dial ошибку не раздаёт, пока к адресу идут другие: ждущие
//     переходят к ним, а запрос, чей dial упал, больше не дозванивается сам,
//     иначе на отказывающем пути выходило бы по dial'у на круг.

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

// coalescedThrottle — сколько запрос ждёт чужой dial, прежде чем дозваниваться
// самому. У Chrome это kHTTP2ThrottleMs = 300 (crbug.com/718576) для хостов,
// про которые он знает, что они говорят h2; транспорт здесь h2 всегда.
var coalescedThrottle = 300 * time.Millisecond

// coalescedMaxDials — сколько dial'ов к одному адресу идёт сразу. У Chrome это
// предел сокетов на хост, g_max_sockets_per_group = 6, считая и те, что ещё
// подключаются. Здесь — на транспорт: у каждого клиента xmux своё соединение.
var coalescedMaxDials = 6

// coalescedBackupAfter — когда начинать запасной dial, если TCP ведущего ещё
// не установлен: потерянный SYN ядро повторит только через секунду. Как у
// Chrome (backup connect job, kMaxConnectRetryIntervalMs = 250; только пока
// у хоста нет других сокетов и TCP не установлен) и у Firefox
// (network.http.connection-retry-timeout = 250, отменяется по установленному
// TCP). Когда TCP поднялся и идёт рукопожатие, второй ClientHello к тому же
// серверу браузер не шлёт, и запасной здесь тоже не начинается.
var coalescedBackupAfter = 250 * time.Millisecond

// coalescedDialTimeout ограничивает каждый dial: net/http дозванивается в
// контексте, отвязанном от отмены запроса, а у рукопожатия на этом пути срока
// нет, и повисшее после ClientHello держало бы место до таймаута TCP. У
// браузеров рукопожатие ограничено 30 с (Chrome kSSLHandshakeTimeout, Firefox
// network.http.tls-handshake-timeout), здесь 10 с, как TLSHandshakeTimeout в
// net/http и ограничение рукопожатия XHTTP в Xray: под блокировкой каждое
// место держится до срока, и после снятия блокировки сессии ждали бы
// повисшие попытки полминуты.
var coalescedDialTimeout = 10 * time.Second

var errCoalescedDialAbandoned = errors.New("xhttp: coalesced dial abandoned")

type dialTCPUpKey struct{}

// DialTCPUp отмечает, что TCP dial'а с контекстом ctx установлен и дальше
// идёт рукопожатие. Его зовёт DialTLSContext h2-транспорта (NewTransport)
// между dialRaw и wrapTLS: с этого момента запасной dial не начинается.
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
	dialc chan struct{} // закрыт, когда dial вернулся; err к этому моменту записан
	err   error
	guard *guardedDial
	// Под coalescingTransport.mu.
	refs int // RoundTrip'ы, которые этот dial ждут
}

type coalescingTransport struct {
	*http.Transport
	mu      sync.Mutex
	leaders map[string]*leaderDial // по адресу, как ключ пула net/http: за кем вставать
	dials   map[string]int         // сколько dial'ов к адресу идёт, с запасными
	waiting map[string]int         // сколько запросов ждёт места под dial
	active  map[string]map[*leaderDial]struct{}
	// slotc закрывается и заменяется, когда dial к адресу закончился: его
	// ждут запросы, которым не хватило места или чей dial упал.
	slotc map[string]chan struct{}
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
	throttleAt := time.Now().Add(coalescedThrottle)
	var lastErr error // dial, за которым мы шли или который вели, упал
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
		switch {
		case l != nil && (l.succeeded() || lastErr == nil && time.Now().Before(throttleAt)):
			// Ждём ведущего, пока не вышел срок, или удачного: его соединение
			// вот-вот будет в пуле, и свой dial был бы лишним.
			l.refs++
			c.mu.Unlock()
			conn, err, again := c.follow(ctx, l, rt, gotConnc, addr, throttleAt)
			if !again {
				if err == nil || errors.Is(err, errCoalescedDialAbandoned) || ctx.Err() != nil {
					return conn, err
				}
				lastErr = err
			}
			continue
		case lastErr == nil && c.dials[addr] < coalescedMaxDials:
			l = &leaderDial{dialc: make(chan struct{}), refs: 1}
			var gctx context.Context
			l.guard, gctx = newGuardedDial(ctx)
			if c.leaders == nil {
				c.leaders = make(map[string]*leaderDial)
				c.dials = make(map[string]int)
				c.active = make(map[string]map[*leaderDial]struct{})
			}
			c.leaders[addr] = l
			c.dials[addr]++
			if c.active[addr] == nil {
				c.active[addr] = make(map[*leaderDial]struct{})
			}
			c.active[addr][l] = struct{}{}
			c.mu.Unlock()
			conn, err := c.lead(gctx, l, rt, gotConnc, dial, network, addr)
			if err == nil || errors.Is(err, errCoalescedDialAbandoned) || ctx.Err() != nil {
				return conn, err
			}
			lastErr = err
			continue
		}
		// Места нет, или наш dial упал: ждём, пока закончится какой-нибудь
		// dial к адресу. Удачный кладёт соединение в пул, и его получаем и
		// мы. Упал наш, а других не осталось — его ошибка наша.
		if lastErr != nil && c.dials[addr] == 0 {
			c.mu.Unlock()
			return nil, lastErr
		}
		slotc := c.slot(addr)
		if c.waiting == nil {
			c.waiting = make(map[string]int)
		}
		c.waiting[addr]++
		c.mu.Unlock()
		var err error
		select {
		case <-slotc:
		case <-gotConnc:
			err = errCoalescedDialAbandoned
		case <-rt.donec:
			err = errCoalescedDialAbandoned
		case <-ctx.Done():
			err = ctx.Err()
		}
		c.mu.Lock()
		if c.waiting[addr]--; c.waiting[addr] <= 0 {
			delete(c.waiting, addr)
			// Ушёл последний ждущий места: dial'ы, оставленные ради
			// ждущих, теперь не нужны никому.
			for l := range c.active[addr] {
				if l.refs <= 0 {
					l.guard.abort(errCoalescedDialAbandoned)
				}
			}
		}
		c.mu.Unlock()
		if err != nil {
			return nil, err
		}
	}
}

// slot — канал, который закроется, когда закончится очередной dial к addr.
// Вызывается под coalescingTransport.mu.
func (c *coalescingTransport) slot(addr string) chan struct{} {
	if c.slotc == nil {
		c.slotc = make(map[string]chan struct{})
	}
	ch := c.slotc[addr]
	if ch == nil {
		ch = make(chan struct{})
		c.slotc[addr] = ch
	}
	return ch
}

// dialEnded освобождает место dial'а к addr (l — ведущий, nil — запасной) и
// будит тех, кто его ждал.
func (c *coalescingTransport) dialEnded(l *leaderDial, addr string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if l != nil {
		delete(c.active[addr], l)
		if len(c.active[addr]) == 0 {
			delete(c.active, addr)
		}
	}
	if c.dials[addr]--; c.dials[addr] <= 0 {
		delete(c.dials, addr)
	}
	if ch := c.slotc[addr]; ch != nil {
		close(ch)
		delete(c.slotc, addr)
	}
}

// takeDial занимает место под запасной dial к addr: только если других
// dial'ов к адресу нет, как backup job у Chrome только при пустой группе.
func (c *coalescingTransport) takeDial(addr string) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.dials[addr] != 1 {
		return false
	}
	c.dials[addr]++
	return true
}

// follow ждёт ведущего l до throttleAt. again — ведущий дозвонился, а
// соединение нашему запросу так и не досталось, или срок вышел: пора
// дозваниваться самим.
func (c *coalescingTransport) follow(ctx context.Context, l *leaderDial, rt *dialRoundTrip, gotConnc chan struct{}, addr string, throttleAt time.Time) (conn net.Conn, err error, again bool) {
	defer c.release(l, addr)
	dialc := l.dialc
	var retry <-chan time.Time
	throttle := time.NewTimer(time.Until(throttleAt))
	defer throttle.Stop()
	// Канал, а не throttle.C в select: при go 1.20 в go.mod остановленный
	// таймер может оставить в канале значение.
	throttleC := throttle.C
	for {
		select {
		case <-dialc:
			if l.err != nil {
				return nil, l.err, false
			}
			// Ведущий дозвонился, а нашему соединение пока не досталось.
			// Либо оно сейчас придёт из пула, либо с соединением ведущего
			// что-то не так; ждём немного и дозваниваемся сами.
			dialc, throttleC = nil, nil
			retry = time.After(coalescedDialRetry)
		case <-throttleC:
			select {
			case <-l.dialc:
				// Dial закончился на самом сроке: разбираем его как обычно.
				throttleC = nil
				continue
			default:
			}
			return nil, nil, true
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

func (c *coalescingTransport) lead(ctx context.Context, l *leaderDial, rt *dialRoundTrip, gotConnc chan struct{}, dial func(context.Context, string, string) (net.Conn, error), network, addr string) (net.Conn, error) {
	// Ведущий перестаёт ждать свой dial, когда его запрос получил соединение
	// из другого dial'а или RoundTrip вернулся.
	stop := make(chan struct{})
	go func() {
		select {
		case <-rt.donec:
			c.release(l, addr)
		case <-gotConnc:
			c.release(l, addr)
		case <-stop:
		}
	}()
	conn, err := l.guard.run(ctx, func(ctx context.Context, network, addr string) (net.Conn, error) {
		return c.dialWithBackup(ctx, dial, network, addr)
	}, network, addr)
	close(stop)

	// Место освобождается после того, как исход dial'а записан: проснувшиеся
	// ждущие места должны увидеть удачного ведущего и встать за ним.
	if err != nil {
		// Сначала снимаем ведущего, потом будим ждущих: следующий запрос
		// должен увидеть пустое место и дозвониться заново.
		c.unlead(l, addr)
		l.err = err
		close(l.dialc)
		c.dialEnded(l, addr)
		return conn, err
	}
	close(l.dialc)
	// Удачный встаёт на место ведущего, даже если его уже занял dial,
	// начатый позже: запросам, которые сейчас придут или проснутся, нужно
	// его соединение, а не ещё один dial.
	c.mu.Lock()
	c.leaders[addr] = l
	c.mu.Unlock()
	c.dialEnded(l, addr)
	// Удачный ведущий остаётся на месте ещё coalescedDialRetry: net/http
	// кладёт соединение в пул уже после возврата из dial'а, после настройки
	// h2, и сигнала об этом не даёт (GotConn ведущего бывает и раньше).
	// Запрос, пришедший в это окно, пула ещё не находит; снятый ведущий
	// означал бы для него свой dial, а так он ждёт соединение ведущего и
	// получает его из пула.
	time.AfterFunc(coalescedDialRetry, func() { c.unlead(l, addr) })
	return conn, nil
}

// dialWithBackup дозванивается, а если за coalescedBackupAfter TCP не
// установлен и других dial'ов к адресу нет, начинает один запасной. Побеждает
// первый удачный; второй обрывается, а его соединение, если успело,
// закрывается. Контекст победителя не отменяется: обёртки соединения могут
// привязывать к нему время жизни.
func (c *coalescingTransport) dialWithBackup(ctx context.Context, dial func(context.Context, string, string) (net.Conn, error), network, addr string) (net.Conn, error) {
	type result struct {
		conn net.Conn
		err  error
		idx  int
	}
	results := make(chan result, 2)
	var cancels [2]context.CancelFunc
	tcpUp := make(chan struct{})
	var tcpUpOnce sync.Once
	start := func(idx int, up func()) {
		actx, cancel := context.WithCancel(ctx)
		cancels[idx] = cancel
		if up != nil {
			actx = context.WithValue(actx, dialTCPUpKey{}, up)
		}
		go func() {
			conn, err := dial(actx, network, addr)
			results <- result{conn, err, idx}
		}()
	}
	start(0, func() { tcpUpOnce.Do(func() { close(tcpUp) }) })
	backup := time.NewTimer(coalescedBackupAfter)
	defer backup.Stop()
	backupC := backup.C
	running, backupTaken := 1, false
	defer func() {
		if backupTaken {
			c.dialEnded(nil, addr)
		}
	}()
	var firstErr error
	for running > 0 {
		select {
		case <-backupC:
			backupC = nil
			select {
			case <-tcpUp:
				continue
			default:
			}
			if c.takeDial(addr) {
				backupTaken = true
				running++
				start(1, nil)
			}
		case r := <-results:
			running--
			if r.err == nil {
				if running > 0 {
					// Проигравший обрывается; его соединение, если он всё
					// же дозвонится, никому не нужно.
					cancels[1-r.idx]()
					go func() {
						if l := <-results; l.conn != nil {
							_ = l.conn.Close()
						}
					}()
				}
				return r.conn, nil
			}
			cancels[r.idx]()
			if firstErr == nil {
				firstErr = r.err
			}
		}
	}
	return nil, firstErr
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
// освобождается сразу, и следующий запрос встаёт за другим dial'ом или
// дозванивается заново, а не ждёт обречённый dial. Если же к адресу ждут
// места другие запросы, dial остаётся: его соединение достанется им из пула,
// а оборванный уступил бы место новому dial'у к тому же адресу. Так и Chrome
// снимает connect job, только если попыток больше, чем ждущих запросов.
func (c *coalescingTransport) release(l *leaderDial, addr string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if l.refs--; l.refs > 0 {
		return
	}
	if c.leaders[addr] == l {
		delete(c.leaders, addr)
	}
	if c.waiting[addr] > 0 {
		return
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
