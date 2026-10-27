//go:build go1.22

package xhttp

import (
	"encoding/binary"
	"testing"

	"golang.org/x/net/http2"
)


// TestFlowClientRestockedLaterSettings has a governed client restock to a
// governed server and its stack then send another SETTINGS with its initial
// window: the window goes on as it is. Before, a later SETTINGS was shown
// the protocol default again, as before restock.
func TestFlowClientRestockedLaterSettings(t *testing.T) {
	sc := &scriptConn{}
	c := newFlowClientConn(sc)
	t.Cleanup(func() { c.Close() })
	c.mode.Store(flowH2)

	// 1. Client sends initial SETTINGS(INITIAL_WINDOW_SIZE = 4 MiB).
	if _, err := c.writeToServer(frames(func(fr *http2.Framer) {
		fr.WriteSettings(http2.Setting{ID: http2.SettingInitialWindowSize, Val: 4 << 20})
	})); err != nil {
		t.Fatal(err)
	}
	// 2. Governed server replies with SETTINGS + tagged PING.
	c.fromServer(frames(func(fr *http2.Framer) {
		fr.WriteSettings(http2.Setting{ID: http2.SettingInitialWindowSize, Val: 1 << 20})
		fr.WritePing(false, [8]byte{0x6b, 0x7a, 0x3f, 0x91, 1, 2, 3, 4})
	}), nil)
	// 3. Client sends PING ACK; appendRestock restores clientShown = 4 MiB.
	if _, err := c.writeToServer(frames(func(fr *http2.Framer) {
		fr.WritePing(true, [8]byte{0x6b, 0x7a, 0x3f, 0x91, 1, 2, 3, 4})
	})); err != nil {
		t.Fatal(err)
	}
	c.mu.Lock()
	if !c.peerGoverned || c.clientShown != 4<<20 {
		c.mu.Unlock()
		t.Fatalf("after restock: peerGoverned=%v clientShown=%d, want true and %d", c.peerGoverned, c.clientShown, 4<<20)
	}
	c.mu.Unlock()

	// 4. Client stack later sends another SETTINGS with INITIAL_WINDOW_SIZE = 4 MiB.
	sc.take()
	if _, err := c.writeToServer(frames(func(fr *http2.Framer) {
		fr.WriteSettings(http2.Setting{ID: http2.SettingInitialWindowSize, Val: 4 << 20})
	})); err != nil {
		t.Fatal(err)
	}
	sent := sc.take()
	var wireWin uint32
	for _, f := range rawFrames(t, sent) {
		if f.typ == h2Settings && f.flags == 0 && len(f.payload) == 6 {
			wireWin = binary.BigEndian.Uint32(f.payload[2:])
		}
	}
	c.mu.Lock()
	shown := c.clientShown
	c.mu.Unlock()
	t.Logf("after later client SETTINGS(4 MiB) on peerGoverned conn: wire INITIAL_WINDOW_SIZE=%d, clientShown=%d", wireWin, shown)
	if wireWin != 4<<20 || shown != 4<<20 {
		t.Fatalf("peerGoverned client rewrote later SETTINGS(4 MiB) down to wire=%d, clientShown=%d", wireWin, shown)
	}
}
