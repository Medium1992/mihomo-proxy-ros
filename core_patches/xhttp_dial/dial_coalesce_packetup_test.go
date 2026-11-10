package xhttp

import (
	"bytes"
	"io"
	"net"
	"testing"
	"time"

	"github.com/metacubex/http"
	"github.com/metacubex/http/httptest"
)

// Тело packet-up перематывается: GetBody отдаёт те же байты сколько угодно
// раз. Без тела (данные в заголовках) перематывать нечего.
func TestCoalesceDialsPacketUpGetBody(t *testing.T) {
	data := []byte("packet-up payload")
	req, err := http.NewRequest("POST", "https://example.com/xhttp", nil)
	if err != nil {
		t.Fatal(err)
	}
	cfg := &Config{Host: "example.com", Path: "/xhttp", Mode: "packet-up"}
	if err := cfg.FillPacketRequest(req, "session", "0", data); err != nil {
		t.Fatal(err)
	}
	if req.GetBody == nil {
		t.Fatal("packet-up request has no GetBody")
	}
	for i := 0; i < 2; i++ {
		body, err := req.GetBody()
		if err != nil {
			t.Fatal(err)
		}
		got, err := io.ReadAll(body)
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(got, data) {
			t.Fatalf("GetBody #%d returned %q, want %q", i+1, got, data)
		}
	}

	req, err = http.NewRequest("POST", "https://example.com/xhttp", nil)
	if err != nil {
		t.Fatal(err)
	}
	cfg = &Config{Host: "example.com", Path: "/xhttp", Mode: "packet-up", UplinkDataPlacement: PlacementHeader}
	if err := cfg.FillPacketRequest(req, "session", "0", data); err != nil {
		t.Fatal(err)
	}
	if req.Body != nil || req.GetBody != nil {
		t.Fatal("packet-up request with data in headers has a body")
	}
}

// Сервер с лимитом потоков меньше, чем клиент шлёт до его SETTINGS: холодный
// залп packet-up на одном соединении отбивается, и отбитые POST'ы net/http
// повторяет. Сессии проходят все, а не висят до тайм-аута.
func TestCoalesceDialsPacketUpLowStreamLimit(t *testing.T) {
	leakCheck(t)
	handler, err := NewServerHandler(ServerOption{
		Config: Config{Path: "/xhttp", Mode: "packet-up"},
		ConnHandler: func(conn net.Conn) {
			defer conn.Close()
			io.Copy(conn, conn)
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewUnstartedServer(handler)
	srv.EnableHTTP2 = true
	srv.Config.HTTP2 = &http.HTTP2Config{MaxConcurrentStreams: 8}
	srv.StartTLS()
	t.Cleanup(srv.Close)

	for round := 0; round < 3; round++ {
		client := standClient(t, srv.Listener.Addr().String(), "packet-up", &ReuseConfig{MaxConnections: "1"}, nil)
		if failed, err := sessions(client, 80, 10*time.Second, 4<<10); failed != 0 {
			t.Fatalf("round %d: %d of 80 sessions failed: %v", round, failed, err)
		}
		client.Close()
	}
}
