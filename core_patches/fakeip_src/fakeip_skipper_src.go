// Часть форк-патча fakeip_src: копия ShouldSkipped, которая кладёт адрес
// клиента в метаданные, поэтому правило SRC-IP-CIDR в fake-ip-filter начинает
// матчиться. Оригинальный ShouldSkipped не трогаем — он остаётся для вызовов,
// где источника нет.
// Назначение в дереве ядра: component/fakeip/skipper_src.go
package fakeip

import (
	"net/netip"

	C "github.com/metacubex/mihomo/constant"
)

// ShouldSkippedSrc is ShouldSkipped with the client address available to rules.
func (p *Skipper) ShouldSkippedSrc(domain string, src netip.Addr) bool {
	if len(p.Rules) > 0 {
		metadata := &C.Metadata{Host: domain, SrcIP: src}
		for _, rule := range p.Rules {
			if matched, action := rule.Match(metadata, C.RuleMatchHelper{}); matched {
				return action == UseRealIP
			}
		}
		return false
	}
	return p.ShouldSkipped(domain)
}
