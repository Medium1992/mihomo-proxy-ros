// Часть форк-патча fakeip_src: адрес клиента, задавший DNS-вопрос, кладётся в
// context, чтобы до правил fake-ip-filter он доехал без правки структуры
// DNSContext. Файл целиком наш, апстрим о нём не знает.
// Назначение в дереве ядра: context/dns_srcip.go
package context

import (
	"context"
	"net/netip"
)

type dnsSrcAddrKey struct{}

// WithDNSSrcAddr carries the address of the client that asked the question.
func WithDNSSrcAddr(ctx context.Context, addr netip.Addr) context.Context {
	return context.WithValue(ctx, dnsSrcAddrKey{}, addr)
}

// DNSSrcAddrFrom returns an invalid Addr for queries made inside the core
// (TUN hijack, resolving the proxies themselves): those keep the old behaviour.
func DNSSrcAddrFrom(ctx context.Context) netip.Addr {
	if ctx == nil {
		return netip.Addr{}
	}
	addr, _ := ctx.Value(dnsSrcAddrKey{}).(netip.Addr)
	return addr
}
