//go:build go1.22

package xhttp

import (
	"testing"

	"golang.org/x/net/http2"
)


// TestFlowDroppedOverrunTakesNoConnWindow has a stream that read part of its
// body send a frame past its shown upload window: the dropped frame takes
// nothing from the connection window, and nothing but the reset goes to the
// client, as with a stack that refuses it. The governor counted the frame
// returned and gave back what its release allowed, which for a stream that
// had read was nothing, and a sibling's legal upload then closed the
// connection; where it did give credit back, a stock server sends none.
func TestFlowDroppedOverrunTakesNoConnWindow(t *testing.T) {
	h := newFlowHarness(t)
	t.Cleanup(func() { h.c.Close() })
	h.track()
	h.openStream(4 << 20)
	h.toClient.open(1)

	h.fromServer(func(fr *http2.Framer) {
		fr.WriteWindowUpdate(0, 8<<20)
	})
	// The handler reads the first 64 KiB and returns both credits.
	h.fromClient(func(fr *http2.Framer) { writeDataSplit(fr, 1, 64<<10) })
	h.fromServer(func(fr *http2.Framer) {
		fr.WriteWindowUpdate(0, 64<<10)
		fr.WriteWindowUpdate(1, 64<<10)
	})
	h.fromClient(func(fr *http2.Framer) { writeDataSplit(fr, 1, flowShownUp-(64<<10)) })
	h.conn.take()

	h.c.mu.Lock()
	before := h2InitWindow + h.c.upConnForwarded - h.c.upConnSent
	h.c.mu.Unlock()
	h.fromClient(func(fr *http2.Framer) {
		fr.WriteData(1, false, make([]byte, 16384))
	})
	h.sync()
	toClient := h.conn.take()

	h.c.mu.Lock()
	after := h2InitWindow + h.c.upConnForwarded - h.c.upConnSent
	h.c.mu.Unlock()
	if after != before {
		t.Fatalf("the dropped frame took %d bytes of the connection window (%d before, %d after)", before-after, before, after)
	}
	for _, f := range rawFrames(t, toClient) {
		if f.typ != h2RSTStream {
			t.Fatalf("frame of type %d went to the client with the reset; a stock server sends only RST_STREAM", f.typ)
		}
	}
}





// readServerPreface reads the server's SETTINGS, acknowledges them, and reads
// on to the server's first WINDOW_UPDATE on the connection. It returns the
// connection window that the client then holds. A client that sends past
// 65535 bytes before that WINDOW_UPDATE arrives is past the window.
func readServerPreface(t *testing.T, fr *http2.Framer) int64 {
	t.Helper()
	connWin, settings := int64(h2InitWindow), false
	for !settings || connWin == h2InitWindow {
		f, err := fr.ReadFrame()
		if err != nil {
			t.Fatal(err)
		}
		switch f := f.(type) {
		case *http2.SettingsFrame:
			if !f.IsAck() {
				fr.WriteSettingsAck()
				settings = true
			}
		case *http2.WindowUpdateFrame:
			if f.StreamID == 0 {
				connWin += int64(f.Increment)
			}
		}
	}
	return connWin
}
