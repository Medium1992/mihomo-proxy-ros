//go:build go1.22

package xhttp

import (
	"net"
	"testing"
	"time"

	"golang.org/x/net/http2"
)

// queuedPath makes c take the kernel's word for an empty path of minRTT and
// a round trip of rtt now, until the test changes it, on a path of its own
// unless it has one.
func queuedPath(c *flowConn, minRTT, rtt time.Duration) {
	c.tcp, c.kAt, c.kOK = fakeRawConn{}, time.Now().Add(time.Hour), true
	c.kstat = tcpStats{rtt: rtt, minRTT: minRTT}
	c.rttBase = minRTT
	if c.path == nil {
		c.path, c.pathSet = &flowPath{conns: map[*flowConn]flowPathConn{}}, true
	}
}

// inFlight sets what c's open downloads have in flight and what c has in
// the network, as its kernel reports it, to n each.
func inFlight(c *flowConn, n int64) {
	c.downOpenSent, c.downOpenReturned = 1<<30+n, 1<<30
	c.kstat.unacked = n
}

// judged reads c's path at at and flowSuspectRounds round trips later, as
// a verdict asks, and gives the second answer.
func judged(c *flowConn, at time.Time) bool {
	c.foreignQueue(at)
	return c.foreignQueue(at.Add(flowSuspectRounds * c.kstat.rtt))
}

// queuedDownload is a server with one download whose reader takes all it is
// sent, on a path whose round trip stands at 500 ms over an empty 50 ms: a
// queue the server cuts against while it counts as its own. The cap is 1 MiB.
func queuedDownload(t *testing.T) (h *flowHarness, s *flowStream) {
	t.Helper()
	const id = 1
	h = newFlowHarness(t)
	t.Cleanup(func() { h.c.Close() })
	h.track()
	h.openStream(4 << 20)
	h.fromServer(func(fr *http2.Framer) { writeDataSplit(fr, id, 200<<10) })
	h.c.mu.Lock()
	defer h.c.mu.Unlock()
	queuedPath(h.c, 50*time.Millisecond, 500*time.Millisecond)
	s = h.c.streams[id]
	s.down.cap = 1 << 20
	s.down.mark, s.down.markBase = time.Now(), s.down.returned
	return h, s
}

// credit returns 4 KiB of the download's credit and gives the cap after it.
func credit(h *flowHarness, s *flowStream) int32 {
	h.fromClient(func(fr *http2.Framer) { fr.WriteWindowUpdate(1, 4<<10) })
	h.c.mu.Lock()
	defer h.c.mu.Unlock()
	return s.down.cap
}

// TestFlowQueueThatStaysIsForeign is a queue of 450 ms over an empty 50 ms
// that stays where it was while what the server has in flight comes down
// from 4 to 2 MiB: no queue of the server's own does, so it counts as
// foreign. At 2.1 MiB it does not yet.
func TestFlowQueueThatStaysIsForeign(t *testing.T) {
	c := &flowConn{streams: map[uint32]*flowStream{}}
	queuedPath(c, 50*time.Millisecond, 500*time.Millisecond)
	now := time.Now()
	inFlight(c, 4<<20)
	c.foreignQueue(now)
	inFlight(c, 2100<<10)
	if judged(c, now.Add(time.Second)) {
		t.Fatal("foreign before what was in flight came down to half")
	}
	inFlight(c, 2<<20)
	for _, d := range []time.Duration{0, time.Millisecond, flowSuspectRounds*c.kstat.rtt - time.Millisecond} {
		if c.foreignQueue(now.Add(3*time.Second + d)) {
			t.Fatalf("foreign %v after the halving, before the smoothed round trip could follow the queue", d)
		}
	}
	if !c.foreignQueue(now.Add(3*time.Second + flowSuspectRounds*c.kstat.rtt)) {
		t.Fatal("a queue that stayed while the server's own data halved is not foreign")
	}
}

// TestFlowQueueThatShortensIsOwn is the server's own queue: when what it has
// in flight halves, the queue comes down from 450 to 300 ms, by a third, and
// it never counts as foreign.
func TestFlowQueueThatShortensIsOwn(t *testing.T) {
	c := &flowConn{streams: map[uint32]*flowStream{}}
	queuedPath(c, 50*time.Millisecond, 500*time.Millisecond)
	now := time.Now()
	inFlight(c, 4<<20)
	c.foreignQueue(now)
	inFlight(c, 2<<20)
	c.kstat.rtt = 350 * time.Millisecond
	if judged(c, now.Add(time.Second)) {
		t.Fatal("a queue that came down by a third with the server's data counts as foreign")
	}
}

// TestFlowForeignQueueEnds is a foreign queue that drains, and one that does
// not: the first counts as the server's own at once, the second after
// flowForeignRounds round trips, when the server cuts against it again.
func TestFlowForeignQueueEnds(t *testing.T) {
	for _, drains := range []bool{true, false} {
		c := &flowConn{streams: map[uint32]*flowStream{}}
		queuedPath(c, 50*time.Millisecond, 500*time.Millisecond)
		now := time.Now()
		inFlight(c, 4<<20)
		c.foreignQueue(now)
		inFlight(c, 1<<20)
		if !judged(c, now.Add(time.Second)) {
			t.Fatalf("drains %v: not foreign", drains)
		}
		now = now.Add(flowSuspectRounds * c.kstat.rtt)
		later := now.Add(2 * time.Second)
		if drains {
			c.kstat.rtt = 60 * time.Millisecond
			if c.foreignQueue(later) {
				later = later.Add(flowSuspectRounds * c.kstat.rtt)
			} else {
				t.Fatal("a queue that dipped under the bar for a moment ended the verdict")
			}
		} else {
			later = now.Add(time.Second + flowForeignRounds*500*time.Millisecond)
			if !c.foreignQueue(later.Add(-time.Millisecond)) {
				t.Fatal("no longer foreign before flowForeignRounds round trips")
			}
		}
		if c.foreignQueue(later) {
			t.Fatalf("drains %v: still foreign", drains)
		}
	}
}

// TestFlowInFlightSpansConnections is a client with two connections, 2 MiB
// in flight on each, behind a standing queue. When one of them is down to
// 1 MiB the path holds 3 MiB, three quarters, and that says nothing; when
// the other is down to 0.9 MiB as well, the path holds under half, and the
// queue is foreign. A connection alone would have taken its own halving for
// the verdict, with the other's data the queue.
func TestFlowInFlightSpansConnections(t *testing.T) {
	path := &flowPath{conns: map[*flowConn]flowPathConn{}}
	a := &flowConn{streams: map[uint32]*flowStream{}, path: path, pathSet: true}
	b := &flowConn{streams: map[uint32]*flowStream{}, path: path, pathSet: true}
	queuedPath(a, 50*time.Millisecond, 500*time.Millisecond)
	queuedPath(b, 50*time.Millisecond, 500*time.Millisecond)
	now := time.Now()
	inFlight(a, 2<<20)
	inFlight(b, 2<<20)
	a.foreignQueue(now)
	b.foreignQueue(now)
	inFlight(a, 1<<20)
	if judged(a, now.Add(time.Second)) {
		t.Fatal("one connection's halving counted for the path's")
	}
	inFlight(b, 900<<10)
	if !judged(b, now.Add(3*time.Second)) {
		t.Fatal("the path's data halved with the queue where it was, and it is not foreign")
	}
	path.release(a)
	if _, ok := path.conns[a]; ok {
		t.Fatal("a released connection still counts for the path")
	}
}

// TestFlowPathFloor is a connection opened into a standing queue: its kernel
// takes 450 ms for the empty path, and to it the queue looks small. The
// path keeps the least empty-path round trip of all its connections, 50 ms,
// and the queue counts as foreign all the same.
func TestFlowPathFloor(t *testing.T) {
	path := &flowPath{conns: map[*flowConn]flowPathConn{}}
	early := &flowConn{streams: map[uint32]*flowStream{}, path: path, pathSet: true}
	queuedPath(early, 50*time.Millisecond, 60*time.Millisecond)
	now := time.Now()
	early.foreignQueue(now)
	path.release(early)
	late := &flowConn{streams: map[uint32]*flowStream{}, path: path, pathSet: true}
	queuedPath(late, 450*time.Millisecond, 500*time.Millisecond)
	inFlight(late, 4<<20)
	late.foreignQueue(now.Add(time.Second))
	inFlight(late, 1<<20)
	if !judged(late, now.Add(2*time.Second)) {
		t.Fatal("a queue over the path's floor did not count as foreign for a connection with a higher one")
	}
}

// tcpPeer is a connection whose peer is a TCP address.
type tcpPeer struct {
	net.Conn
	addr *net.TCPAddr
}

func (c tcpPeer) RemoteAddr() net.Addr { return c.addr }

// TestFlowPathOutlivesConnections is a client that closes its connection and
// opens another: the new one gets the same path, with what it learnt, and a
// client from another address does not.
func TestFlowPathOutlivesConnections(t *testing.T) {
	c := &flowConn{}
	a := tcpPeer{addr: &net.TCPAddr{IP: net.IPv4(192, 0, 2, 7), Port: 40000}}
	p := flowPathOf(a)
	p.release(c)
	a.addr = &net.TCPAddr{IP: net.IPv4(192, 0, 2, 7), Port: 40001}
	q := flowPathOf(a)
	defer q.release(c)
	if q != p {
		t.Fatal("a new connection from the same address got a new path")
	}
	b := flowPathOf(tcpPeer{addr: &net.TCPAddr{IP: net.IPv4(192, 0, 2, 8), Port: 40000}})
	defer b.release(c)
	if b == p {
		t.Fatal("a connection from another address got the same path")
	}
}

// TestFlowForeignQueueStopsCuts is a download against a standing queue: the
// cap is cut while the queue counts as the server's own, and not while it
// counts as foreign.
func TestFlowForeignQueueStopsCuts(t *testing.T) {
	for _, foreign := range []bool{false, true} {
		h, s := queuedDownload(t)
		if foreign {
			h.c.mu.Lock()
			h.c.path.foreignAt = time.Now()
			h.c.mu.Unlock()
		}
		got := credit(h, s)
		if cut := got < 1<<20; cut == foreign {
			t.Fatalf("foreign %v: the cap went from 1 MiB to %d", foreign, got)
		}
	}
}

// TestFlowBothMustHalve is a queue that stands while only one of the two
// halves: what the downloads have in flight, as a client drains its buffers
// with the server's own data still filling the network, or what the
// network holds, with the downloads' credit where it was. Neither says the
// queue is foreign; both together do.
func TestFlowBothMustHalve(t *testing.T) {
	for _, half := range []string{"downloads", "network", "both"} {
		c := &flowConn{streams: map[uint32]*flowStream{}}
		queuedPath(c, 50*time.Millisecond, 500*time.Millisecond)
		now := time.Now()
		inFlight(c, 4<<20)
		c.foreignQueue(now)
		if half != "network" {
			c.downOpenSent = c.downOpenReturned + 1<<20
		}
		if half != "downloads" {
			c.kstat.unacked = 1 << 20
		}
		if got := judged(c, now.Add(time.Second)); got != (half == "both") {
			t.Fatalf("%s halved: foreign %v", half, got)
		}
	}
}

// TestFlowBarLeavesJitterOut is a foreign queue of 600 ms on a path whose
// round trip swings by 300 ms with it: pi's setpoint, four times that swing,
// would take the queue for none and end the verdict at once.
func TestFlowBarLeavesJitterOut(t *testing.T) {
	c := &flowConn{streams: map[uint32]*flowStream{}}
	queuedPath(c, 150*time.Millisecond, 750*time.Millisecond)
	c.kstat.rttVar = 300 * time.Millisecond
	now := time.Now()
	inFlight(c, 4<<20)
	c.foreignQueue(now)
	inFlight(c, 1<<20)
	if !judged(c, now.Add(time.Second)) {
		t.Fatal("a queue of 600 ms that swings by 300 ms is not foreign")
	}
}

// TestFlowPathTakesLongestQueue is two clients behind one address: A's
// path holds a queue other traffic keeps at 450 ms, B's is empty. B's
// reports must not end A's episode: the path takes the longest queue a
// connection has seen lately, and A's queue is foreign all the same. Once
// A has not reported for flowPathFresh round trips, its queue no longer
// counts.
func TestFlowPathTakesLongestQueue(t *testing.T) {
	path := &flowPath{conns: map[*flowConn]flowPathConn{}}
	a := &flowConn{streams: map[uint32]*flowStream{}, path: path, pathSet: true}
	b := &flowConn{streams: map[uint32]*flowStream{}, path: path, pathSet: true}
	queuedPath(a, 50*time.Millisecond, 500*time.Millisecond)
	queuedPath(b, 50*time.Millisecond, 55*time.Millisecond)
	now := time.Now()
	inFlight(a, 4<<20)
	a.foreignQueue(now)
	b.foreignQueue(now.Add(time.Millisecond))
	inFlight(a, 1<<20)
	a.foreignQueue(now.Add(time.Second))
	b.foreignQueue(now.Add(time.Second + time.Millisecond))
	verdict := now.Add(time.Second + flowSuspectRounds*500*time.Millisecond)
	if !a.foreignQueue(verdict) {
		t.Fatal("a client with an empty path behind the same address ended another's verdict")
	}
	// Well inside flowForeignRounds of B's round trip, so that only A's
	// queue going stale can end the verdict.
	late := verdict.Add(flowPathFresh*55*time.Millisecond + time.Millisecond)
	b.foreignQueue(late)
	if b.foreignQueue(late.Add(flowSuspectRounds * 55 * time.Millisecond)) {
		t.Fatal("a queue no connection has reported for long still holds the verdict")
	}
}

// TestFlowNoQueueCuts is a download against a standing queue on a server
// that leaves the queue to TCP: neither pi nor the cut at a long queue takes
// its cap down, where the same server without the setting cuts it.
func TestFlowNoQueueCuts(t *testing.T) {
	for _, noCuts := range []bool{false, true} {
		h, s := queuedDownload(t)
		h.c.mu.Lock()
		h.c.noQueueCuts = noCuts
		h.c.mu.Unlock()
		got := credit(h, s)
		if cut := got < 1<<20; cut == noCuts {
			t.Fatalf("noQueueCuts %v: the cap went from 1 MiB to %d", noCuts, got)
		}
	}
}

// TestFlowNoQueueCutsStopsPI is a queue of 60 ms over an empty 50 ms, short
// of the cut at a long queue but well over pi's setpoint, on a download pi
// governs: a client that returns credit in small steps, a reader that has
// settled, a round trip measured. pi cuts it, unless the server leaves the
// queue to TCP.
func TestFlowNoQueueCutsStopsPI(t *testing.T) {
	for _, noCuts := range []bool{false, true} {
		h, s := queuedDownload(t)
		h.c.mu.Lock()
		h.c.noQueueCuts, h.c.incremental = noCuts, true
		h.c.kstat.rtt = 110 * time.Millisecond
		s.down.flat = flowFullRounds
		s.down.mark = time.Now().Add(-200 * time.Millisecond)
		h.c.mu.Unlock()
		got := credit(h, s)
		if cut := got < 1<<20; cut == noCuts {
			t.Fatalf("noQueueCuts %v: pi took the cap from 1 MiB to %d", noCuts, got)
		}
	}
}
