//go:build go1.22

package xhttp

import (
	"bytes"
	"encoding/binary"
	"io"
	"net"
	"sync"
)

// ackConn writes the acknowledgement of the server's SETTINGS in a record of
// its own, as Chrome does; Go's client writes it with the WINDOW_UPDATE that
// follows. A frame header split across writes is held until it is complete,
// so a fragmented acknowledgement still goes in one write. After the
// acknowledgement it passes writes through. From ackConn in h2shape.go of
// Medium1992/Xray-core-fork v26.11.9-h2Flow-7, for REALITY browser mode.
type ackConn struct {
	net.Conn
	mu          sync.Mutex
	prefaceLeft int
	held        []byte // the start of a frame header not yet written
	payload     int
	done        bool
	// err ends the wrapper: after a failed write its frame boundaries no
	// longer match what the peer received.
	err error
}

const ackFrameHeaderLen = 9

func (c *ackConn) Write(b []byte) (int, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.err != nil {
		return 0, c.err
	}
	if c.done {
		return c.Conn.Write(b)
	}
	data, held := b, len(c.held)
	if held != 0 {
		data = append(c.held, b...)
		c.held = nil
	}
	p := min(c.prefaceLeft, len(data))
	c.prefaceLeft -= p
	at, end, partial := -1, 0, len(data)
	for p < len(data) {
		if c.payload > 0 {
			n := min(c.payload, len(data)-p)
			c.payload -= n
			p += n
			continue
		}
		if len(data)-p < ackFrameHeaderLen {
			partial = p
			break
		}
		header := data[p : p+ackFrameHeaderLen]
		p += ackFrameHeaderLen
		c.payload = int(header[0])<<16 | int(header[1])<<8 | int(header[2])
		if c.payload == 0 && header[3] == h2Settings && header[4]&h2FlagAck != 0 &&
			binary.BigEndian.Uint32(header[5:])&0x7fffffff == 0 {
			c.done = true
			at, end = p-ackFrameHeaderLen, p
			break
		}
	}
	if partial < len(data) {
		c.held = bytes.Clone(data[partial:])
		data = data[:partial]
	}
	parts := [][]byte{data}
	if at >= 0 {
		parts = [][]byte{data[:at], data[at:end], data[end:]}
	}
	written := 0
	for _, part := range parts {
		if len(part) == 0 {
			continue
		}
		n, err := c.Conn.Write(part)
		written += n
		if err == nil && n != len(part) {
			err = io.ErrShortWrite
		}
		if err != nil {
			c.err = err
			return max(0, written-held), err
		}
	}
	return len(b), nil
}

// NetConn is the connection under the wrapper, for what looks through it.
func (c *ackConn) NetConn() net.Conn {
	return c.Conn
}
