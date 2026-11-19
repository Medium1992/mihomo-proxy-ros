//go:build go1.22

package xhttp

import (
	"bytes"
	"net"
	"testing"
)

type writesConn struct {
	net.Conn
	writes [][]byte
}

func (c *writesConn) Write(b []byte) (int, error) {
	c.writes = append(c.writes, bytes.Clone(b))
	return len(b), nil
}

func flowAckFrame(typ, flags byte, payload []byte) []byte {
	n := len(payload)
	return append([]byte{byte(n >> 16), byte(n >> 8), byte(n), typ, flags, 0, 0, 0, 0}, payload...)
}

// Chrome writes its acknowledgement of the server's SETTINGS in a record of
// its own; Go writes it with the WINDOW_UPDATE that follows.
func TestFlowBrowserAckGoesInAWriteOfItsOwn(t *testing.T) {
	preface := []byte(h2Preface)
	settings := flowAckFrame(h2Settings, 0, []byte{0, 4, 0, 0x60, 0, 0})
	window := flowAckFrame(h2WindowUpdate, 0, []byte{0, 0x0f, 0, 1})
	ack := flowAckFrame(h2Settings, h2FlagAck, nil)
	after := flowAckFrame(h2WindowUpdate, 0, []byte{0, 0, 0x10, 0})

	inner := &writesConn{}
	c := &ackConn{Conn: inner, prefaceLeft: len(h2Preface)}
	first := append(append(bytes.Clone(preface), settings...), window...)
	if n, err := c.Write(first); n != len(first) || err != nil {
		t.Fatal(n, err)
	}
	second := append(bytes.Clone(ack), after...)
	if n, err := c.Write(second); n != len(second) || err != nil {
		t.Fatal(n, err)
	}
	if n, err := c.Write(after); n != len(after) || err != nil {
		t.Fatal(n, err)
	}
	want := [][]byte{first, ack, after, after}
	if len(inner.writes) != len(want) {
		t.Fatalf("writes %d, want %d", len(inner.writes), len(want))
	}
	for i := range want {
		if !bytes.Equal(inner.writes[i], want[i]) {
			t.Fatalf("write %d: % x, want % x", i, inner.writes[i], want[i])
		}
	}
}

// A frame header split across writes is held until whole, so a fragmented
// acknowledgement still goes in one write, and nothing is lost or reordered.
func TestFlowBrowserAckSplitAcrossWrites(t *testing.T) {
	preface := []byte(h2Preface)
	ack := flowAckFrame(h2Settings, h2FlagAck, nil)
	data := flowAckFrame(h2Data, 0, []byte("payload"))
	stream := append(append(bytes.Clone(preface), ack...), data...)

	for cut := 1; cut < len(stream); cut++ {
		inner := &writesConn{}
		c := &ackConn{Conn: inner, prefaceLeft: len(h2Preface)}
		if _, err := c.Write(stream[:cut]); err != nil {
			t.Fatal(err)
		}
		if _, err := c.Write(stream[cut:]); err != nil {
			t.Fatal(err)
		}
		if got := bytes.Join(inner.writes, nil); !bytes.Equal(got, stream) {
			t.Fatalf("cut %d: the bytes changed", cut)
		}
		found := false
		for _, w := range inner.writes {
			if bytes.Equal(w, ack) {
				found = true
			}
		}
		if !found {
			t.Fatalf("cut %d: the acknowledgement did not go alone: %d writes", cut, len(inner.writes))
		}
	}
}
