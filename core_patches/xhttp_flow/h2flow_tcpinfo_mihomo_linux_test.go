//go:build linux && go1.22

package xhttp

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	gotls "crypto/tls"
	"crypto/x509"
	"math/big"
	"net"
	"testing"
	"time"

	"github.com/metacubex/sing/common/bufio"
	mtls "github.com/metacubex/tls"
	utls "github.com/metacubex/utls"
)

// TestFlowTCPStatsMihomo checks that the client role reaches the kernel TCP
// stats through the wrappers mihomo puts on an XHTTP connection: its TLS, the
// uTLS client REALITY is built on, and sing's extended conn under either.
func TestFlowTCPStatsMihomo(t *testing.T) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tpl := &x509.Certificate{SerialNumber: big.NewInt(1), NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour)}
	der, err := x509.CreateCertificate(rand.Reader, tpl, tpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	cert := gotls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}

	for _, tc := range []struct {
		name string
		wrap func(net.Conn) (net.Conn, error)
	}{
		{"tls", func(c net.Conn) (net.Conn, error) {
			cl := mtls.Client(c, &mtls.Config{InsecureSkipVerify: true})
			return cl, cl.Handshake()
		}},
		{"utls", func(c net.Conn) (net.Conn, error) {
			cl := utls.UClient(c, &utls.Config{InsecureSkipVerify: true, ServerName: "x"}, utls.HelloChrome_Auto)
			return cl, cl.Handshake()
		}},
		{"extended+tls", func(c net.Conn) (net.Conn, error) {
			cl := mtls.Client(bufio.NewExtendedConn(c), &mtls.Config{InsecureSkipVerify: true})
			return cl, cl.Handshake()
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ln, err := net.Listen("tcp", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			defer ln.Close()
			go func() {
				c, err := ln.Accept()
				if err != nil {
					return
				}
				s := gotls.Server(c, &gotls.Config{Certificates: []gotls.Certificate{cert}})
				if s.Handshake() == nil {
					buf := make([]byte, 1)
					s.Read(buf)
				}
				s.Close()
			}()
			c, err := net.Dial("tcp", ln.Addr().String())
			if err != nil {
				t.Fatal(err)
			}
			defer c.Close()
			cl, err := tc.wrap(c)
			if err != nil {
				t.Fatal(err)
			}
			rc := rawTCP(cl)
			if rc == nil {
				t.Fatal("no raw TCP socket under the connection")
			}
			st, ok := readTCPStats(rc)
			if !ok || st.rtt <= 0 || st.minRTT <= 0 {
				t.Fatalf("no TCP stats: %+v %v", st, ok)
			}
		})
	}
}
