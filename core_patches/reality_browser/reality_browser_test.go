package tls

import (
	"bytes"
	"testing"
	"time"

	utls "github.com/metacubex/utls"
)

func TestRealityBrowserOption(t *testing.T) {
	for value, want := range map[string]bool{"": false, "off": false, "auto": true, "AUTO": true, " auto ": true} {
		got, err := ParseRealityBrowser(value)
		if err != nil || got != want {
			t.Errorf("ParseRealityBrowser(%q) = %v, %v; want %v", value, got, err, want)
		}
	}
	if _, err := ParseRealityBrowser("chrome"); err == nil {
		t.Error("an unknown browser value is refused")
	}
}

func TestRealityBrowserFingerprintsThatResume(t *testing.T) {
	for name, want := range map[string]bool{
		"chrome": true, "firefox": true, "edge": true,
		"safari": false, "ios": false, "randomized": false, "chrome120": true,
	} {
		fingerprint, ok := GetFingerprint(name)
		if !ok {
			t.Fatalf("no fingerprint %q", name)
		}
		if got := resumesSessions(fingerprint); got != want {
			t.Errorf("%s (%s %s) resumes: %v, want %v", name, fingerprint.Client, fingerprint.Version, got, want)
		}
		config := &RealityConfig{Browser: true}
		if got := config.UsesBrowser(name); got != want {
			t.Errorf("%s with browser: auto behaves as the browser: %v, want %v", name, got, want)
		}
		config.Browser = false
		if config.UsesBrowser(name) {
			t.Errorf("%s without browser mode behaves as the browser", name)
		}
	}
	var none *RealityConfig
	if none.UsesBrowser("chrome") {
		t.Error("no REALITY is no browser mode")
	}
}

// The gap before the first data and the verification delay are those of the
// fork: Chrome and Edge have both, Firefox only the delay, Safari neither.
func TestRealityBrowserTimings(t *testing.T) {
	chrome, _ := GetFingerprint("chrome")
	firefox, _ := GetFingerprint("firefox")
	safari, _ := GetFingerprint("safari")
	gap := applicationDataGap(chrome)
	if gap == nil {
		t.Fatal("Chrome sends its first data after a gap")
	}
	for i := 0; i < 100; i++ {
		if d := gap(); d < 250*time.Microsecond || d >= 1200*time.Microsecond {
			t.Fatalf("Chrome's gap %v", d)
		}
	}
	if applicationDataGap(firefox) != nil || applicationDataGap(safari) != nil {
		t.Error("Firefox and Safari send their first data with their Finished")
	}
	key := "TestRealityBrowserTimings " + t.Name()
	delay := verifyDelay(chrome, key)
	if d := delay(); d < 15*time.Millisecond || d >= 48*time.Millisecond {
		t.Fatalf("Chrome's first verification %v", d)
	}
	if d := delay(); d != time.Millisecond {
		t.Fatalf("Chrome's verification of a certificate it verified lately %v", d)
	}
	if verifyDelay(safari, key) != nil {
		t.Error("no delay is imitated for Safari")
	}
}

func TestRealityBrowserTicketStore(t *testing.T) {
	saved := usableTicket
	usableTicket = func(*utls.ClientSessionState) bool { return true }
	t.Cleanup(func() { usableTicket = saved })
	store := &ticketStore{sessions: make(map[string][]*utls.ClientSessionState)}
	saveTickets := tickets
	tickets = store
	t.Cleanup(func() { tickets = saveTickets })

	a, b, c := &utls.ClientSessionState{}, &utls.ClientSessionState{}, &utls.ClientSessionState{}
	store.push("s", a)
	store.push("s", b)
	store.push("s", c)
	if got := store.offer("s"); got != c {
		t.Fatal("the newest ticket is offered first")
	}
	if got := store.offer("s"); got != b {
		t.Fatal("two tickets are kept per server")
	}
	if got := store.offer("s"); got != nil {
		t.Fatal("each ticket is offered once")
	}

	store.push("s", a)
	store.fail("s")
	store.push("s", b)
	if got := store.offer("s"); got != nil {
		t.Fatal("no ticket is offered to a server where one failed lately")
	}
	store.failed["s"] = time.Now().Add(-ticketBackoff - time.Second)
	if got := store.offer("s"); got != b {
		t.Fatal("tickets collected meanwhile are offered after the backoff")
	}

	// Only a verified connection keeps the tickets its server sends.
	verifier := &browserVerifier{}
	cache := &connTickets{key: "v", verifier: verifier}
	cache.Put("", a)
	if store.offer("v") != nil {
		t.Fatal("a ticket of an unverified connection is kept")
	}
	verifier.verified.Store(true)
	cache.Put("", a)
	if store.offer("v") != a {
		t.Fatal("a ticket of a verified connection is not kept")
	}
	cache.session = b
	if got, ok := cache.Get(""); got != b || !ok {
		t.Fatal("the connection offers its ticket")
	}
	if got, ok := cache.Get(""); got != nil || ok {
		t.Fatal("the connection offers its ticket once")
	}
}

func TestRealityBrowserSessionIDAuthenticatesTheHelloWithoutBinders(t *testing.T) {
	hello := []byte("hello-body-0123456789")
	binders := [][]byte{{1, 2, 3}, {4, 5}}
	// binders: length 2, then each with its length byte
	n := 2 + 1 + 3 + 1 + 2
	aad := pskAAD(hello, binders)
	if !bytes.Equal(aad[:len(hello)-n], hello[:len(hello)-n]) {
		t.Fatal("the hello before the binders is kept")
	}
	if !bytes.Equal(aad[len(hello)-n:], make([]byte, n)) {
		t.Fatal("the binders are zeroed")
	}
	if bytes.Equal(hello[len(hello)-n:], make([]byte, n)) {
		t.Fatal("the hello itself is left as it was")
	}
}

// Firefox's resumption hello drops session_ticket and sizes its GREASE ECH
// for the pre_shared_key; Chrome's is its own hello plus pre_shared_key.
func TestRealityBrowserFirefoxResumptionHello(t *testing.T) {
	firefox, _ := GetFingerprint("firefox")
	chrome, _ := GetFingerprint("chrome")
	if resumptionSpec(chrome, &utls.ClientSessionState{}) != nil {
		t.Error("Chrome resumes with its own hello")
	}
	if resumptionSpec(firefox, nil) != nil {
		t.Error("without a ticket Firefox sends its own hello")
	}
}
