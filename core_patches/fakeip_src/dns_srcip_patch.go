// Часть форк-патча fakeip_src: сюда вынесено всё, что вызывается из двух
// пропатченных строк ядра (dns/server.go и dns/middleware.go). Чем больше кода
// живёт здесь, тем меньше строк апстрима надо чинить после его рефакторингов.
// Назначение в дереве ядра: dns/srcip_patch.go
package dns

import (
	"context"
	"net/netip"

	"github.com/metacubex/mihomo/component/fakeip"
	icontext "github.com/metacubex/mihomo/context"

	D "github.com/miekg/dns"
)

// ctxWithSrc pulls the client address out of the DNS ResponseWriter.
func ctxWithSrc(w D.ResponseWriter) context.Context {
	ctx := context.Background()
	if w == nil {
		return ctx
	}
	addr := w.RemoteAddr()
	if addr == nil {
		return ctx
	}
	if ap, err := netip.ParseAddrPort(addr.String()); err == nil {
		return icontext.WithDNSSrcAddr(ctx, ap.Addr().Unmap())
	}
	return ctx
}

func shouldSkippedCtx(ctx context.Context, skipper *fakeip.Skipper, host string) bool {
	return skipper.ShouldSkippedSrc(host, icontext.DNSSrcAddrFrom(ctx))
}
