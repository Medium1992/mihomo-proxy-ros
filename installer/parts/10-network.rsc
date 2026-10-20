# Interface lists, veth, DNS forwarders and statics, NTP, routes.
:global MPRminor
:local start
:if ([:len [/interface/list/find name=WAN]] = 0) do={
/interface/list/add name=WAN
:put "interface list WAN added, pls add interface to interface list WAN and press Enter to continue"
:set start [/terminal ask]
}
:if ([:len [/interface/list/find name=LAN]] = 0) do={
/interface/list/add name=LAN
:put "interface list LAN added, pls add interface to interface list LAN and press Enter to continue"
:set start [/terminal ask]
}

:do {/interface/veth/add name=MihomoProxyRoS address=192.168.255.2/30 gateway=192.168.255.1
:put "Create VETH MihomoProxyRoS"} on-error {}
:do {/interface/list/add name=InAccept include=WAN
:put "Create interfacelist InAccept"} on-error {}
:do {/interface/list/member/add interface=MihomoProxyRoS list=InAccept
:put "Add in interfacelist InAccept interface MihomoProxyRoS"} on-error {}
:do {/ip/address/add address=192.168.255.1/30 interface=MihomoProxyRoS
:put "Add address Mikrotik for interface MihomoProxyRoS"} on-error {}
:do {/ip/dns/forwarders/add name=MihomoProxyRoS dns-servers=192.168.255.2 verify-doh-cert=no
:put "Add DNS Forwarders MihomoProxyRoS"} on-error {}

:do {/interface/list/add name=Containers
:put "Create interfacelist Containers"} on-error {}
:do {/interface/list/member/add interface=MihomoProxyRoS list=Containers
:put "Add in interfacelist Containers interface MihomoProxyRoS"} on-error {}

:do {
/ip dns forwarders
add doh-servers=https://8.8.8.8/dns-query name=Google
add doh-servers=https://1.1.1.1/dns-query name=CloudFlare
add doh-servers=https://9.9.9.9/dns-query name=Quad9
add dns-servers=111.88.96.54,111.88.96.55 name=XBOX
add doh-servers=https://xbox-dns.ru/dns-query name=XBOX-DOH
add dns-servers=77.88.8.8,77.88.8.1 name=Yandex verify-doh-cert=no
add dns-servers=8.8.8.8 name=Google8 verify-doh-cert=no
:local cmd
:if ($MPRminor >= 21) do={:set cmd [:parse "/certificate/settings/set builtin-trust-store=dns,container"]} else={:set cmd [:parse "/certificate/settings/set builtin-trust-anchors=not-trusted; /certificate/settings/set builtin-trust-anchors=trusted"]}
$cmd
/ip/dns/set allow-remote-requests=yes cache-max-ttl=1d cache-size=15000KiB doh-max-concurrent-queries=500 doh-max-server-connections=10 servers=8.8.8.8 use-doh-server=https://8.8.8.8/dns-query verify-doh-cert=yes
/ip dns static
add forward-to=Google8 match-subdomain=yes name=pool.ntp.org type=FWD
add address=8.8.8.8 comment="DNS Google" name=dns.google type=A
add address=8.8.4.4 comment="DNS Google" name=dns.google type=A
add address=104.16.248.249 comment="DNS CloudFlare" name=cloudflare-dns.com type=A
add address=104.16.249.249 comment="DNS CloudFlare" name=cloudflare-dns.com type=A
add address=9.9.9.9 comment="DNS Quad9" name=dns.quad9.net type=A
add address=149.112.112.112 comment="DNS Quad9" name=dns.quad9.net type=A
add address=111.88.96.55 comment="XBOX DNS" name=xbox-dns.ru type=A
/system ntp client
set enabled=yes
/system ntp client servers
add address=0.ru.pool.ntp.org
add address=1.ru.pool.ntp.org
add address=2.ru.pool.ntp.org
add address=3.ru.pool.ntp.org
:put "DNS and NTP client configuration complete"
/ipv6 nd set [ find default=yes ] advertise-dns=yes disabled=yes
:if ($MPRminor >= 21) do={:set cmd [:parse "/ipv6 settings set accept-router-advertisements-on=none"]; $cmd}
/ipv6 settings set accept-redirects=no accept-router-advertisements=no allow-fast-path=no disable-ipv6=yes disable-link-local-address=yes forward=no
:put "Disable ipv6"
/ip route
add blackhole comment=BlackHole distance=254 dst-address=10.0.0.0/8 gateway="" routing-table=main
add blackhole comment=BlackHole distance=254 dst-address=172.16.0.0/12 gateway="" routing-table=main
add blackhole comment=BlackHole distance=254 dst-address=192.168.0.0/16 gateway="" routing-table=main
:put "Add BlackHole route into routing table main"
:put "delay 10s for NTP sync"
:delay 10
/ip firewall filter set [find where action=fasttrack-connection] connection-mark=no-mark
} on-error {}

:if ([:len [/routing/table/find comment="MihomoProxyRoS"]] = 0) do={
/routing/table/add name=MihomoProxyRoS fib comment="MihomoProxyRoS"
:put "Add routing table MihomoProxyRoS"
}
:if ([:len [/ip/route/find comment="MihomoProxyRoS0"]] = 0) do={
/ip route 
add dst-address=0.0.0.0/0 gateway=192.168.255.2 routing-table=MihomoProxyRoS comment="MihomoProxyRoS0"
add blackhole comment=BlackHole distance=254 dst-address=10.0.0.0/8 gateway="" routing-table=MihomoProxyRoS
add blackhole comment=BlackHole distance=254 dst-address=172.16.0.0/12 gateway="" routing-table=MihomoProxyRoS
add blackhole comment=BlackHole distance=254 dst-address=192.168.0.0/16 gateway="" routing-table=MihomoProxyRoS
:put "Add default route 0.0.0.0/0 into routing table MihomoProxyRoS & BlackHole route"}
