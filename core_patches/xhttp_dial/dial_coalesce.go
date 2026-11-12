package xhttp

import (
	"context"
	"errors"
	"net"
	"os"
	"sync"
	"sync/atomic"
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
// получил соединение из пула. К адресу идёт одна попытка за раз, и одно
// соединение на транспорт остаётся правдой при любой скорости рукопожатия.
//
// На проводе к адресу никогда не висят два рукопожатия сразу: пока попытка
// висит, второго ClientHello нет; повисшая обрывается (coalescedTCPTimeout,
// coalescedAttemptTimeout), и следующую начинает тот, кому соединение ещё
// нужно, как человек, нажавший «обновить» на повисшей странице. Медленную, но
// живую попытку не обрывают: срок рукопожатия растёт со временем установки
// TCP, и пока сервер что-то присылает, попытка продолжается. Запасной dial
// бывает только до установленного TCP, как у Chrome и Firefox.
//
// В отличие от x/net:
//   - dial, который больше никто не ждёт, обрывается: на этом пути net/http
//     держал бы повисшее рукопожатие, и новые сессии после снятия блокировки
//     ждали бы его вместо того, чтобы дозвониться заново;
//   - удачный ведущий остаётся на месте ещё coalescedDialRetry: запрос,
//     пришедший, пока net/http настраивает h2 и ещё не положил соединение в
//     пул, иначе дозвонился бы сам;
//   - повторный поиск соединения тем же запросом (соединение его не
//     приняло) за удачным ведущим не встаёт, а дозванивается сразу;
//   - ведущий, оборванный по сроку, ошибку ждущим не раздаёт: первый из них
//     дозванивается сам, остальные встают за ним, пока у их сессий есть
//     время. Отказ (сброс, закрытый порт, ошибка TLS) получают все, как в
//     x/net: на отказывающем пути это один dial, а не по dial'у на ждущего;
//   - если TCP ведущего не установлен за coalescedBackupAfter, начинается
//     один запасной dial.

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

// coalescedAttemptTimeout — сколько попытка ведущего ждёт ответа сервера после
// установленного TCP, прежде чем её заменит следующая. net/http дозванивается
// в контексте, отвязанном от отмены запроса, а рукопожатие на этом пути срока
// не имеет: повисшее после ClientHello держало бы всех ждущих до таймаута TCP.
// Срок — это и простой транспорта на одном зависшем рукопожатии (блокировка,
// замёрзший поток, смена WAN посреди рукопожатия), и частота ClientHello под
// блокировкой: один в срок на транспорт. Он вдвое меньше срока сессии в
// tunnel (C.DefaultTCPTimeout, 5 с), чтобы залп, начавший зависшую попытку,
// успел дозвониться следующей. Попытка заменяется, а не идёт параллельно, и
// медленный живой канал срезался бы на одном и том же месте, поэтому срок
// отсчитывается от установленного TCP (DNS, dialer-proxy и сам TCP в него не
// входят), не меньше трёх времён до установленного TCP этой попытки и
// продлевается на столько же, пока от сервера идут байты: блокировка после
// ClientHello — это тишина, а медленный канал присылает ServerHello. Всё
// вместе не дольше coalescedDialTimeout. С TCP Fast Open dialRaw возвращается
// до ответа сервера: время до TCP выходит около нуля, срок — ровно
// coalescedAttemptTimeout от начала, и запасного dial'а нет, а потерянный SYN
// уходит в продление по байтам или в следующую попытку.
var coalescedAttemptTimeout = 2 * time.Second

// coalescedTCPTimeout — сколько попытка ждёт установленного TCP. Сюда входят
// DNS и цепочка dialer-proxy, а потерянный SYN страхует запасной dial, поэтому
// срок длиннее coalescedAttemptTimeout.
var coalescedTCPTimeout = 3 * time.Second

// coalescedDialTimeout — предел попытки целиком, тот же, что у сессии: дольше
// её ждать некому. Им же ограничен dial запроса, пришедшего в обход склейки.
var coalescedDialTimeout = 5 * time.Second

// coalescedBackupAfter — когда начинать запасной dial, если TCP ведущего ещё
// не установлен: потерянный SYN ядро повторит только через секунду. Как у
// Chrome (backup connect job через kMaxConnectRetryIntervalMs = 250, только
// пока TCP не установлен) и у Firefox (network.http.connection-retry-timeout
// = 250, отменяется по установленному TCP). Когда TCP поднялся и идёт
// рукопожатие, второй ClientHello к тому же серверу браузер не шлёт, и
// запасной здесь тоже не начинается.
var coalescedBackupAfter = 250 * time.Millisecond

var errCoalescedDialAbandoned = errors.New("xhttp: coalesced dial abandoned")

type dialAttemptKey struct{}

// dialLeg — один из dial'ов попытки (ведущий или запасной), как его видит
// DialTCPUp через контекст.
type dialLeg struct {
	a    *dialAttempt
	lost atomic.Bool // TCP установлен вторым: этот dial уступил другому
}

// dialAttempt — ход одной попытки ведущего: её запасной dial и сроки.
type dialAttempt struct {
	start  time.Time
	tcpUp  chan struct{} // закрыт, когда TCP попытки (любого из dial'ов) установлен
	upOnce sync.Once
	upAt   atomic.Int64 // когда, UnixNano
	read   atomic.Int64 // сколько байтов прислал сервер
	ended  atomic.Bool  // попытка закончилась: считать больше незачем
}

// markUp отмечает установленный TCP. first — этот dial дошёл до TCP первым
// из двух (ведущий и запасной).
func (a *dialAttempt) markUp() (first bool) {
	a.upOnce.Do(func() {
		a.upAt.Store(time.Now().UnixNano())
		close(a.tcpUp)
		first = true
	})
	return first
}

// errCoalescedSecondTCP — у dial'а попытки TCP установлен вторым: рукопожатие
// уже начал другой, и второго ClientHello к серверу не будет.
var errCoalescedSecondTCP = errors.New("xhttp: the other dial of the attempt reached TCP first")

// secondConn — соединение dial'а, дошедшего до TCP вторым: уже закрыто, и
// wrapTLS падает на первой же записи, ничего не отправив.
type secondConn struct{ net.Conn }

func (secondConn) Read([]byte) (int, error)  { return 0, errCoalescedSecondTCP }
func (secondConn) Write([]byte) (int, error) { return 0, errCoalescedSecondTCP }

// DialTCPUp отмечает, что TCP dial'а с контекстом ctx установлен и дальше
// идёт рукопожатие, и возвращает соединение, которое считает присланные
// сервером байты. Его зовёт DialTLSContext h2-транспорта (NewTransport) между
// dialRaw и wrapTLS: с этого момента запасной dial не начинается, а попытку не
// обрывают, пока сервер что-то присылает. Если TCP попытки уже установил
// другой её dial (ведущий и запасной дошли оба), этот закрывается, не начав
// рукопожатия: к серверу идёт одно рукопожатие. Вне склейки соединение не
// меняется.
func DialTCPUp(ctx context.Context, conn net.Conn) net.Conn {
	leg, ok := ctx.Value(dialAttemptKey{}).(*dialLeg)
	if !ok {
		return conn
	}
	if !leg.a.markUp() {
		// Без TLS wrapTLS ничего не пишет, и dial вернётся без ошибки:
		// отметка, а не ошибка записи, не даёт dialWithBackup его взять.
		leg.lost.Store(true)
		_ = conn.Close()
		return secondConn{conn}
	}
	return &countingConn{Conn: conn, a: leg.a}
}

// countingConn считает байты, прочитанные из соединения, пока идёт попытка.
// Соединение XHTTP живёт часами, поэтому после рукопожатия на чтение остаётся
// одна проверка флага. Настоящий сокет под ней виден через Upstream(): так
// его находят обёртки mihomo и TCP_INFO у xhttp_flow.
type countingConn struct {
	net.Conn
	a *dialAttempt
}

func (c *countingConn) Read(b []byte) (int, error) {
	n, err := c.Conn.Read(b)
	if n > 0 && !c.a.ended.Load() {
		c.a.read.Add(int64(n))
	}
	return n, err
}

func (c *countingConn) Upstream() any { return c.Conn }

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
	guard   *guardedDial
	// Под coalescingTransport.mu.
	refs int // RoundTrip'ы, которые этот dial ждут
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
			conn, err := c.lead(gctx, l, rt, dial, network, addr)
			if !errors.Is(err, os.ErrDeadlineExceeded) || !stillWaiting(ctx, rt, gotConnc) {
				return conn, err
			}
			// Наша попытка повисла и оборвана по сроку, а сессия ещё ждёт:
			// начинаем следующую, если её не начал кто-то из ждущих.
			continue
		}
		l.refs++
		c.mu.Unlock()
		conn, err, again := c.follow(ctx, l, rt, gotConnc, addr)
		if !again {
			return conn, err
		}
		// Соединение удачного ведущего нам не досталось, или ведущий
		// оборван по сроку: на следующем круге ведущими становимся мы, если
		// место ещё не занял другой ждущий, — тогда встаём за ним.
		c.unlead(l, addr)
	}
}

// stillWaiting — соединение этому поиску ещё нужно: RoundTrip не вернулся,
// поиск соединения не получил, контекст dial'а жив.
func stillWaiting(ctx context.Context, rt *dialRoundTrip, gotConnc chan struct{}) bool {
	select {
	case <-rt.donec:
		return false
	case <-gotConnc:
		return false
	case <-ctx.Done():
		return false
	default:
		return true
	}
}

// follow ждёт ведущего l. again — ведущий дозвонился, а соединение нашему
// запросу так и не досталось, или ведущий оборван по сроку: пора
// дозваниваться самим.
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
				if errors.Is(l.err, os.ErrDeadlineExceeded) || errors.Is(l.err, errCoalescedDialAbandoned) {
					// Попытка повисла и оборвана по сроку или оборвана,
					// потому что ждавшие её ушли, а мы пришли, пока она
					// закрывалась. Наша сессия ещё ждёт: следующую
					// начинаем сами, как «обновить» на повисшей странице.
					return nil, nil, true
				}
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
	a := &dialAttempt{start: time.Now(), tcpUp: make(chan struct{})}
	watched := make(chan struct{})
	go watchAttempt(l.guard, a, coalescedTCPTimeout, coalescedAttemptTimeout, watched)
	conn, err := l.guard.run(ctx, coalescedDialTimeout, func(ctx context.Context, network, addr string) (net.Conn, error) {
		return dialWithBackup(ctx, a, dial, network, addr)
	}, network, addr)
	a.ended.Store(true)
	close(watched)
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

// watchAttempt обрывает попытку a, которая повисла: TCP не установлен за
// tcpTimeout (coalescedTCPTimeout) или сервер молчит дольше срока
// рукопожатия (coalescedAttemptTimeout, его даёт attemptTimeout). Предел
// coalescedDialTimeout ставит сам guard. Сроки передаются на старте попытки,
// а не читаются в горутине, как и срок guard'а.
func watchAttempt(g *guardedDial, a *dialAttempt, tcpTimeout, attemptTimeout time.Duration, done <-chan struct{}) {
	wait := func(d time.Duration) bool {
		t := time.NewTimer(d)
		defer t.Stop()
		select {
		case <-t.C:
			return true
		case <-done:
			return false
		}
	}
	tcp := time.NewTimer(tcpTimeout)
	select {
	case <-a.tcpUp:
		tcp.Stop()
	case <-tcp.C:
		g.abort(os.ErrDeadlineExceeded)
		return
	case <-done:
		tcp.Stop()
		return
	}
	bound := attemptTimeout
	if d := 3 * time.Duration(a.upAt.Load()-a.start.UnixNano()); d > bound {
		bound = d
	}
	var read int64
	for wait(bound) {
		n := a.read.Load()
		if n == read {
			// За весь срок от сервера ни байта: рукопожатие повисло.
			g.abort(os.ErrDeadlineExceeded)
			return
		}
		read = n
	}
}

// dialWithBackup дозванивается, а если за coalescedBackupAfter TCP не
// установлен, начинает один запасной dial. Побеждает первый удачный; второй
// обрывается, а его соединение, если успело, закрывается. Контекст
// победителя не отменяется: обёртки соединения могут привязывать к нему время
// жизни.
func dialWithBackup(ctx context.Context, a *dialAttempt, dial func(context.Context, string, string) (net.Conn, error), network, addr string) (net.Conn, error) {
	type result struct {
		conn net.Conn
		err  error
		idx  int
	}
	results := make(chan result, 2)
	var cancels [2]context.CancelFunc
	var legs [2]dialLeg
	start := func(idx int) {
		legs[idx].a = a
		actx, cancel := context.WithCancel(context.WithValue(ctx, dialAttemptKey{}, &legs[idx]))
		cancels[idx] = cancel
		go func() {
			conn, err := dial(actx, network, addr)
			results <- result{conn, err, idx}
		}()
	}
	start(0)
	backup := time.NewTimer(coalescedBackupAfter)
	defer backup.Stop()
	backupC := backup.C
	running := 1
	var firstErr error
	for running > 0 {
		select {
		case <-backupC:
			backupC = nil
			select {
			case <-a.tcpUp:
			default:
				running++
				start(1)
			}
		case r := <-results:
			running--
			if r.err == nil && legs[r.idx].lost.Load() {
				// Уступивший TCP вернулся «удачно» (XHTTP без TLS): его
				// соединение закрыто и никому не годится.
				if r.conn != nil {
					_ = r.conn.Close()
				}
				r.conn, r.err = nil, errCoalescedSecondTCP
			}
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
			// Ошибка dial'а, уступившего TCP другому, ничего не говорит о
			// пути: попытка отвечает ошибкой того, кто шёл дальше.
			if firstErr == nil || errors.Is(firstErr, errCoalescedSecondTCP) {
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
// освобождается, когда обрыв закончился, а не сразу: иначе следующий запрос
// начал бы рукопожатие, пока прежнее ещё закрывается. Пришедший в этот миг
// встаёт за обрываемым и дозванивается следом за ним.
func (c *coalescingTransport) release(l *leaderDial, addr string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if l.refs--; l.refs > 0 {
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

func (g *guardedDial) run(ctx context.Context, timeout time.Duration, dial func(context.Context, string, string) (net.Conn, error), network, addr string) (net.Conn, error) {
	timer := time.AfterFunc(timeout, func() { g.abort(os.ErrDeadlineExceeded) })
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
	// отменён, и полагаться на такое соединение нельзя. Ошибка — причина
	// обрыва, а не то, чем dial ответил на отмену: по ней ждущие отличают
	// повисшую попытку от отказа.
	if conn != nil {
		_ = conn.Close()
	}
	return nil, reason
}

// boundedDial ограничивает dial сроком coalescedDialTimeout.
func boundedDial(ctx context.Context, dial func(context.Context, string, string) (net.Conn, error), network, addr string) (net.Conn, error) {
	g, ctx := newGuardedDial(ctx)
	return g.run(ctx, coalescedDialTimeout, dial, network, addr)
}
