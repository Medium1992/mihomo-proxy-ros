package tls

// REALITY browser mode, the client role of "browser": "auto" in
// realitySettings of Medium1992/Xray-core-fork (v26.11.9-h2Flow-7,
// transport/internet/reality/reality.go and resumption.go there).
//
// With reality-opts.browser: auto the client resumes sessions the way the
// browser of its fingerprint does: the second and later connections to a
// server offer a ticket the server issued, in a pre_shared_key extension,
// and resume with a short handshake. Chrome and Edge send their own hello
// plus pre_shared_key; Firefox sends the hello Firefox sends when it resumes
// (no session_ticket, a longer GREASE ECH). A full handshake waits as long as
// the browser takes to verify the certificate chain, and Chrome and Edge send
// their first application data a little after their Finished.
//
// A REALITY server issues tickets only to clients that set
// realityTicketsFlag in the session ID, and only with "browser": "auto" on
// its inbound; older servers ignore the flag and issue none, so the client
// keeps doing full handshakes with them. Tickets are kept only from
// connections verified as REALITY, each is used once, at most two per server,
// as Chrome keeps them. A resumed connection is verified by completing: only
// the server that issued the ticket knows its key.
//
// Safari, iOS and the randomized fingerprints do not resume: with them the
// mode changes nothing.

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/ed25519"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/sha512"
	"crypto/x509"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"math/rand/v2"
	"net"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/ntp"

	utls "github.com/metacubex/utls"
	"golang.org/x/crypto/hkdf"
)

// ParseRealityBrowser reads reality-opts.browser: "auto" turns browser mode
// on, "" and "off" leave it off.
func ParseRealityBrowser(value string) (bool, error) {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "", "off":
		return false, nil
	case "auto":
		return true, nil
	}
	return false, fmt.Errorf("invalid REALITY browser %q, want auto or off", value)
}

// UsesBrowser reports whether connections of this config with the named
// client-fingerprint behave as the browser: browser mode is on and the
// browser of the fingerprint resumes sessions. A nil config is no REALITY.
func (c *RealityConfig) UsesBrowser(clientFingerprint string) bool {
	if c == nil || !c.Browser {
		return false
	}
	fingerprint, ok := GetFingerprint(clientFingerprint)
	return ok && resumesSessions(fingerprint)
}

// GetRealityConn is upstream's GetRealityConn, renamed getRealityConnStock
// by core_patches/reality_browser, with browser mode in front of it.
func GetRealityConn(ctx context.Context, conn net.Conn, fingerprint UClientHelloID, serverName string, realityConfig *RealityConfig) (net.Conn, error) {
	if realityConfig == nil || !realityConfig.Browser || !resumesSessions(fingerprint) {
		return getRealityConnStock(ctx, conn, fingerprint, serverName, realityConfig)
	}
	return getRealityConnBrowser(ctx, conn, fingerprint, serverName, realityConfig)
}

func getRealityConnBrowser(ctx context.Context, conn net.Conn, fingerprint UClientHelloID, serverName string, realityConfig *RealityConfig) (net.Conn, error) {
	key := ticketKey(conn, serverName, realityConfig, fingerprint)
	verifier := &browserVerifier{serverName: serverName}
	if delay := verifyDelay(fingerprint, key); delay != nil {
		verifier.delay = delay
	}
	cache := &connTickets{key: key, verifier: verifier, session: tickets.offer(key)}
	// The browser's hello as it is, X25519MLKEM768 included whatever
	// support-x25519mlkem768 says: a hello without it is no browser's, and
	// a server with browser mode takes it.
	uConfig := &utls.Config{
		Time:                   ntp.Now,
		ServerName:             serverName,
		InsecureSkipVerify:     true,
		InsecureSkipTimeVerify: true, // REALITY's certificate has no validity
		SessionTicketsDisabled: false,
		ClientSessionCache:     cache,
		OmitEmptyPsk:           true,
		AlwaysIncludePSK:       true,
		VerifyConnection:       verifier.VerifyConnection,
	}
	// uTLS takes the ticket from the cache when it builds the hello.
	offered := cache.session != nil
	var spec *utls.ClientHelloSpec
	if offered {
		spec = resumptionSpec(fingerprint, cache.session)
	}
	uConn, err := buildUClient(conn, uConfig, fingerprint, spec)
	if err != nil {
		return nil, fmt.Errorf("REALITY: failed to build the ClientHello: %w", err)
	}
	if spec != nil && offeredPSK(uConn) == nil {
		// uTLS dropped the ticket: the browser's resumption hello without
		// it is a hello the browser never sends.
		if uConn, err = buildUClient(conn, uConfig, fingerprint, nil); err != nil {
			return nil, fmt.Errorf("REALITY: failed to rebuild the full ClientHello: %w", err)
		}
	}
	verifier.UConn = uConn
	if err := sealBrowserHello(uConn, verifier, realityConfig, cache); err != nil {
		return nil, err
	}

	if err := uConn.HandshakeContext(ctx); err != nil {
		if offered {
			tickets.fail(key)
		}
		return nil, err
	}
	resumed := uConn.ConnectionState().DidResume
	log.Debugln("REALITY Authentication: %v, browser mode, resumed: %v", verifier.verified.Load(), resumed)
	if !verifier.verified.Load() {
		if offered {
			tickets.fail(key)
		} else {
			tickets.clear(key)
		}
		go realityClientFallback(uConn, uConfig.ServerName, fingerprint)
		return nil, errors.New("REALITY authentication failed")
	}
	if gap := applicationDataGap(fingerprint); gap != nil {
		// Chrome sends its first application data a little after its
		// Finished, not with it; nothing is written before this returns.
		time.Sleep(gap())
	}
	return uConn, nil
}

// buildUClient returns a uTLS client for c with its ClientHello built: the
// fingerprint's, or spec when one is given. It works on a copy of config,
// which uTLS changes while it builds the hello.
func buildUClient(c net.Conn, config *utls.Config, fingerprint UClientHelloID, spec *utls.ClientHelloSpec) (*utls.UConn, error) {
	config = config.Clone()
	var uConn *utls.UConn
	if spec != nil {
		uConn = utls.UClient(c, config, utls.HelloCustom)
		if err := uConn.ApplyPreset(spec); err != nil {
			return nil, err
		}
	} else {
		uConn = utls.UClient(c, config, fingerprint)
	}
	if err := uConn.BuildHandshakeState(); err != nil {
		return nil, err
	}
	return uConn, nil
}

// sealBrowserHello writes the REALITY session ID into the built hello and
// derives the key the server proves it holds, as upstream does, with two
// differences: the reserved byte asks for tickets, and a hello that offers a
// ticket is authenticated with its binders zeroed, which are written after
// the session ID since they cover it.
func sealBrowserHello(uConn *utls.UConn, verifier *browserVerifier, realityConfig *RealityConfig, cache *connTickets) error {
	hello := uConn.HandshakeState.Hello
	// The legacy session ID is 32 bytes at a fixed offset: after version,
	// random and its length byte.
	if hello == nil || len(hello.Raw) < 39+32 || hello.Raw[38] != 32 {
		return fmt.Errorf("REALITY: the ClientHello of fingerprint %s %s has no session ID to seal", uConn.ClientHelloID.Client, uConn.ClientHelloID.Version)
	}
	hello.SessionId = make([]byte, 32)
	copy(hello.Raw[39:], hello.SessionId)
	binary.BigEndian.PutUint64(hello.SessionId, uint64(ntp.Now().Unix()))
	copy(hello.SessionId[8:], realityConfig.ShortID[:])
	hello.SessionId[0] = 1
	hello.SessionId[1] = 8
	hello.SessionId[2] = 2
	hello.SessionId[3] = realityTicketsFlag

	keyShareKeys := uConn.HandshakeState.State13.KeyShareKeys
	if keyShareKeys == nil {
		return errors.New("REALITY: nil keyShareKeys")
	}
	ecdheKey := keyShareKeys.Ecdhe
	if ecdheKey == nil {
		ecdheKey = keyShareKeys.MlkemEcdhe
	}
	if ecdheKey == nil {
		return fmt.Errorf("REALITY: fingerprint %s %s does not support TLS 1.3", uConn.ClientHelloID.Client, uConn.ClientHelloID.Version)
	}
	authKey, err := ecdheKey.ECDH(realityConfig.PublicKey)
	if err != nil {
		return err
	}
	if authKey == nil {
		return errors.New("nil auth_key")
	}
	if _, err = hkdf.New(sha256.New, authKey, hello.Random[:20], []byte("REALITY")).Read(authKey); err != nil {
		return err
	}
	verifier.authKey = authKey
	aesBlock, _ := aes.NewCipher(authKey)
	aeadCipher, _ := cipher.NewGCM(aesBlock)
	aad := hello.Raw
	psk := offeredPSK(uConn)
	if psk != nil {
		aad = pskAAD(hello.Raw, psk.Binders)
	}
	aeadCipher.Seal(hello.SessionId[:0], hello.Random[20:], hello.SessionId[:16], aad)
	copy(hello.Raw[39:], hello.SessionId)
	if psk != nil {
		// The binders cover the session ID written above.
		if err := psk.PatchBuiltHello(hello); err != nil && err != io.EOF {
			return fmt.Errorf("REALITY: failed to bind the ticket: %w", err)
		}
	}
	return nil
}

// browserVerifier is upstream's realityVerifier plus what browser mode
// needs: a resumed handshake is REALITY's, and a full one waits as long as
// the browser takes to verify the chain.
type browserVerifier struct {
	*utls.UConn
	serverName string
	authKey    []byte
	verified   atomic.Bool
	delay      func() time.Duration
}

func (c *browserVerifier) VerifyConnection(state utls.ConnectionState) error {
	if state.DidResume {
		// Only the server that issued the ticket completes this handshake,
		// and only verified servers' tickets are kept. Resumed handshakes
		// carry no certificate and the browsers take no time on them.
		c.verified.Store(true)
		return nil
	}
	certs := state.PeerCertificates
	if len(certs) == 0 {
		return errors.New("REALITY: no certificate")
	}
	if pub, ok := certs[0].PublicKey.(ed25519.PublicKey); ok {
		h := hmac.New(sha512.New, c.authKey)
		h.Write(pub)
		if bytes.Equal(h.Sum(nil), certs[0].Signature) {
			c.verified.Store(true)
			if c.delay != nil {
				time.Sleep(c.delay())
			}
			return nil
		}
	}
	opts := x509.VerifyOptions{
		DNSName:       c.serverName,
		Intermediates: x509.NewCertPool(),
		CurrentTime:   ntp.Now(),
	}
	for _, cert := range certs[1:] {
		opts.Intermediates.AddCert(cert)
	}
	if _, err := certs[0].Verify(opts); err != nil {
		return err
	}
	return nil
}

// realityTicketsFlag is the bit of the session ID's reserved byte by which
// the client asks for tickets, see the fork's third_party/reality.
const realityTicketsFlag = 1

const (
	ticketsPerServer = 2
	ticketServers    = 256
)

var tickets = &ticketStore{sessions: make(map[string][]*utls.ClientSessionState)}

// ticketBackoff is how long a client offers no ticket to a server after one
// failed there, as with a server of an older version behind the same
// address: it takes the ticket for a stranger's and hands the connection to
// the target. Tickets are still collected meanwhile.
const ticketBackoff = 10 * time.Minute

type ticketStore struct {
	sync.Mutex
	sessions map[string][]*utls.ClientSessionState
	failed   map[string]time.Time
}

// offer takes a ticket to offer to the server, unless one failed there
// lately.
func (s *ticketStore) offer(key string) *utls.ClientSessionState {
	s.Lock()
	if at, ok := s.failed[key]; ok {
		if time.Since(at) < ticketBackoff {
			s.Unlock()
			return nil
		}
		delete(s.failed, key)
	}
	s.Unlock()
	for {
		session := s.pop(key)
		if session == nil || usableTicket(session) {
			return session
		}
	}
}

// usableTicket is usable, but for tests of the store.
var usableTicket = usable

// usable reports whether uTLS will offer session: a TLS 1.3 session whose
// use-by time has not passed. The hello is chosen by the ticket offered
// (Firefox's differs), so one uTLS would drop builds a resumption's hello
// without its pre_shared_key.
func usable(session *utls.ClientSessionState) bool {
	_, state, err := session.ResumptionState()
	if err != nil || state == nil {
		return false
	}
	b, err := state.Bytes()
	// version, then the client's use_by and age_add end the encoding
	if err != nil || len(b) < 2+12 || binary.BigEndian.Uint16(b) != utls.VersionTLS13 {
		return false
	}
	useBy := time.Unix(int64(binary.BigEndian.Uint64(b[len(b)-12:])), 0)
	return time.Now().Before(useBy)
}

// fail drops the server's tickets and offers none to it for a while.
func (s *ticketStore) fail(key string) {
	s.Lock()
	defer s.Unlock()
	delete(s.sessions, key)
	if s.failed == nil {
		s.failed = make(map[string]time.Time)
	}
	now := time.Now()
	if _, exists := s.failed[key]; !exists && len(s.failed) >= ticketServers {
		for name, failedAt := range s.failed {
			if now.Sub(failedAt) >= ticketBackoff {
				delete(s.failed, name)
			}
		}
	}
	if _, exists := s.failed[key]; !exists && len(s.failed) >= ticketServers {
		// Every marker is active: the oldest goes, and its server's tickets
		// with it, so none is offered there before its backoff would end.
		var oldest string
		var earliest time.Time
		for name, failedAt := range s.failed {
			if earliest.IsZero() || failedAt.Before(earliest) {
				oldest, earliest = name, failedAt
			}
		}
		delete(s.failed, oldest)
		delete(s.sessions, oldest)
	}
	s.failed[key] = now
}

func (s *ticketStore) pop(key string) *utls.ClientSessionState {
	s.Lock()
	defer s.Unlock()
	list := s.sessions[key]
	if len(list) == 0 {
		return nil
	}
	session := list[len(list)-1]
	if len(list) == 1 {
		delete(s.sessions, key)
	} else {
		s.sessions[key] = list[:len(list)-1]
	}
	return session
}

func (s *ticketStore) push(key string, session *utls.ClientSessionState) {
	s.Lock()
	defer s.Unlock()
	list := s.sessions[key]
	if list == nil && len(s.sessions) >= ticketServers {
		for k := range s.sessions { // drop one server, whichever
			delete(s.sessions, k)
			break
		}
	}
	list = append(list, session)
	if len(list) > ticketsPerServer {
		list = list[len(list)-ticketsPerServer:]
	}
	s.sessions[key] = list
}

func (s *ticketStore) clear(key string) {
	s.Lock()
	defer s.Unlock()
	delete(s.sessions, key)
}

// connTickets is the ClientSessionCache of one connection. It holds the
// ticket the connection offers, taken from the store before the hello is
// built, since the hello depends on it; uTLS puts the tickets the server
// sends, and only those of a verified connection are kept.
type connTickets struct {
	key      string
	verifier *browserVerifier
	mu       sync.Mutex
	session  *utls.ClientSessionState
}

func (c *connTickets) Get(string) (*utls.ClientSessionState, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	session := c.session
	c.session = nil
	return session, session != nil
}

func (c *connTickets) Put(_ string, session *utls.ClientSessionState) {
	if session == nil {
		tickets.clear(c.key)
		return
	}
	if c.verifier.verified.Load() {
		tickets.push(c.key, session)
	}
}

// resumptionSpec returns the hello of fingerprint as its browser sends it
// when it offers session, or nil when that is the hello of fingerprint plus
// pre_shared_key, as with Chrome. Firefox drops the empty session_ticket
// extension, and sizes its GREASE ECH payload as if the inner hello held the
// pre_shared_key too: it grows by the size of that extension rounded up to
// 32 bytes (Firefox 156 and 160 captures).
func resumptionSpec(fingerprint UClientHelloID, session *utls.ClientSessionState) *utls.ClientHelloSpec {
	if fingerprint.Client != "Firefox" || session == nil {
		return nil
	}
	spec, err := utls.UTLSIdToSpec(fingerprint)
	if err != nil {
		return nil
	}
	pskLen, ok := pskExtensionLen(session)
	if !ok {
		return nil
	}
	extensions := make([]utls.TLSExtension, 0, len(spec.Extensions))
	for _, extension := range spec.Extensions {
		switch e := extension.(type) {
		case utls.ISessionTicketExtension:
			continue
		case *utls.GREASEEncryptedClientHelloExtension:
			if len(e.CandidatePayloadLens) == 1 {
				e.CandidatePayloadLens = []uint16{e.CandidatePayloadLens[0] + uint16((pskLen+31)/32*32)}
			}
		}
		extensions = append(extensions, extension)
	}
	spec.Extensions = extensions
	return &spec
}

// pskExtensionLen is the size of the pre_shared_key extension offering
// session: type and length, the identity with its obfuscated age, and the
// binder, as long as the hash of the session's cipher suite.
func pskExtensionLen(session *utls.ClientSessionState) (int, bool) {
	ticket, state, err := session.ResumptionState()
	if err != nil || state == nil {
		return 0, false
	}
	b, err := state.Bytes()
	if err != nil || len(b) < 5 {
		return 0, false
	}
	binder := 32
	if uint16(b[3])<<8|uint16(b[4]) == utls.TLS_AES_256_GCM_SHA384 {
		binder = 48
	}
	return 4 + 2 + 2 + len(ticket) + 4 + 2 + 1 + binder, true
}

// ticketKey names the tickets of one REALITY server as one proxy sees it:
// the address dialed, the name, the key and short ID, and the fingerprint,
// whose hello the tickets were issued to.
func ticketKey(conn net.Conn, serverName string, config *RealityConfig, fingerprint UClientHelloID) string {
	addr := ""
	if remote := conn.RemoteAddr(); remote != nil {
		addr = remote.String()
	}
	return addr + " " + serverName + " " + hex.EncodeToString(config.PublicKey.Bytes()) + " " +
		hex.EncodeToString(config.ShortID[:]) + " " + fingerprint.Client + "_" + fingerprint.Version
}

// resumesSessions reports whether the browser of fingerprint resumes
// sessions: its hello advertises session_ticket and psk_key_exchange_modes,
// so pre_shared_key belongs in it once a ticket is there. Randomized
// fingerprints have no browser to follow.
func resumesSessions(fingerprint UClientHelloID) bool {
	if strings.HasPrefix(fingerprint.Client, "Randomized") || fingerprint.Client == "" {
		return false
	}
	spec, err := utls.UTLSIdToSpec(fingerprint)
	if err != nil {
		return false
	}
	hasModes, hasTicket, hasTLS13 := false, false, false
	for _, extension := range spec.Extensions {
		switch e := extension.(type) {
		case utls.PreSharedKeyExtension:
			return false
		case *utls.PSKKeyExchangeModesExtension:
			hasModes = true
		case utls.ISessionTicketExtension:
			hasTicket = true
		case *utls.SupportedVersionsExtension:
			hasTLS13 = slices.Contains(e.Versions, utls.VersionTLS13)
		}
	}
	return hasModes && hasTicket && hasTLS13
}

// offeredPSK returns the pre_shared_key extension of the built hello if it
// offers a ticket.
func offeredPSK(uConn *utls.UConn) *utls.UtlsPreSharedKeyExtension {
	for _, extension := range uConn.Extensions {
		if psk, ok := extension.(*utls.UtlsPreSharedKeyExtension); ok && len(psk.Identities) != 0 {
			return psk
		}
	}
	return nil
}

// pskAAD returns the additional data of the session ID of a hello that
// offers a ticket: the hello with its binders zeroed, as the binders cover
// the session ID.
func pskAAD(raw []byte, binders [][]byte) []byte {
	n := 2
	for _, binder := range binders {
		n += 1 + len(binder)
	}
	aad := bytes.Clone(raw)
	if n <= len(aad) {
		for i := len(aad) - n; i < len(aad); i++ {
			aad[i] = 0
		}
	}
	return aad
}

// verifyDelay returns how long the browser of fingerprint takes to verify a
// server's certificate chain, which REALITY's own check of the certificate
// does not take: the time between the server's flight and the client's
// Finished. Measured in the fork through REALITY in front of real sites:
// Chrome 157 15-48 ms, Edge 157 25-50 ms; Firefox 156 and 160 1-5 ms.
// Chromium keeps the result for the certificate for 30 minutes, and verifies
// again in about 1 ms meanwhile.
func verifyDelay(fingerprint UClientHelloID, key string) func() time.Duration {
	var from, to time.Duration
	cached := false
	switch fingerprint.Client {
	case "Chrome":
		from, to, cached = 15*time.Millisecond, 48*time.Millisecond, true
	case "Edge":
		from, to, cached = 25*time.Millisecond, 50*time.Millisecond, true
	case "Firefox":
		from, to = 1*time.Millisecond, 5*time.Millisecond
	default:
		return nil
	}
	return func() time.Duration {
		if cached && !verifications.fresh(key) {
			return time.Millisecond
		}
		return from + time.Duration(rand.Int64N(int64(to-from)))
	}
}

// applicationDataGap returns how long after its handshake a browser sends
// its first application data, or nil when it sends it with its Finished.
// Chrome 157 left 0.25 to 1.2 ms on the fork's stand. The gap decides what a
// target that reads after its handshake finds waiting, which changes how
// nginx groups its HTTP/2 greeting.
func applicationDataGap(fingerprint UClientHelloID) func() time.Duration {
	switch fingerprint.Client {
	case "Chrome", "Edge":
		const from, to = 250 * time.Microsecond, 1200 * time.Microsecond
		return func() time.Duration { return from + time.Duration(rand.Int64N(int64(to-from))) }
	}
	return nil
}

// verifyCacheTTL is how long Chromium keeps a certificate's verification.
const verifyCacheTTL = 30 * time.Minute

var verifications = &verifyCache{at: make(map[string]time.Time)}

// verifyCache remembers when a server's certificate was last verified.
type verifyCache struct {
	sync.Mutex
	at map[string]time.Time
}

// fresh reports whether the certificate of the server named key needs a
// verification, a fresh one, and notes that it has one now.
func (v *verifyCache) fresh(key string) bool {
	v.Lock()
	defer v.Unlock()
	now := time.Now()
	last, ok := v.at[key]
	if !ok || now.Sub(last) > verifyCacheTTL {
		if len(v.at) >= ticketServers {
			v.at = make(map[string]time.Time)
		}
		v.at[key] = now
		return true
	}
	return false
}
