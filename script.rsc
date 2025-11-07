:local freespace [/system/resource/get free-hdd-space]
:if ($freespace<80914560 and ([:len [/container/find comment="MihomoProxyRoS"]] = 0) and ([:len [[/disk/find where fs=ext4 free>80914560]]] = 0)) do={
:put "Low free space on storage(s), script exit"
} else={
:local start
:put "Script loaded, press Enter to start"
:set start [/terminal ask]
:put "Starting script"

:local pathPull ""
:if (([:len [/container/find comment="MihomoProxyRoS"]] = 0) or ([:len [/container/find comment="DNSProxy"]] = 0) or ([:len [/container/find comment="ByeDPI"]] = 0)) do={
:local slotArray 
:if ($freespace>=80914560) do={:set slotArray ($slotArray, "system")}
:local flagDisks false
:local slotDisk 
:local selectSlot 
foreach i in=[/disk/find where fs=ext4 free>80914560] do={
:set slotArray ($slotArray, [/disk/get [find where fs=ext4 free>80914560] value-name=slot]);
}
:while ($flagDisks=false) do={
:put "Enter the name of the disk slot to which you want to pull the containers. Possible options slot:"
foreach i in=$slotArray do={:put "- $i"}
:set slotDisk [/terminal ask]
foreach i in=$slotArray do={
:if ($i=$slotDisk) do={
:set selectSlot $i
:if ($selectSlot!="system") do={:set pathPull "$selectSlot/"}
:put "The slot $selectSlot selected for pulling Containers, path pulling $pathPull"
:set flagDisks true
}}}}

:local inputLINK
:local defaultLINK
:do {
:set defaultLINK [/container/envs/get [find key=LINK1 list=MihomoProxyRoS] value]
} on-error {
:set defaultLINK " "
}
:put "Please enter a valid link vless://... or vmess://... or ss://... or trojan://... Press Enter to skip and hold current value: $defaultLINK"
:set inputLINK [/terminal ask]
:if ([:len $inputLINK] = 0) do={
:set inputLINK $defaultLINK
}

:local inputSUBLINK
:local defaultSUBLINK
:do {
:set defaultSUBLINK [/container/envs/get [find key=SUB_LINK1 list=MihomoProxyRoS] value]
} on-error {
:set defaultSUBLINK " "
}
:put "Enter sublink http(s)://... URL. Press Enter to skip and hold current value: $defaultSUBLINK"
:set inputSUBLINK [/terminal ask]
:if ([:len $inputSUBLINK] = 0) do={
:set inputSUBLINK $defaultSUBLINK
}

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

:do {/interface/veth/add name=ByeDPI address=192.168.255.6/30 gateway=192.168.255.5
:put "Create VETH ByeDPI"} on-error {}
:do {/interface/list/member/add interface=ByeDPI list=InAccept
:put "Add in interfacelist InAccept interface ByeDPI"} on-error {}
:do {/ip/address/add address=192.168.255.5/30 interface=ByeDPI
:put "Add address Mikrotik for interface ByeDPI"} on-error {}

:do {/interface/veth/add name=DNSProxy address=192.168.255.10/30 gateway=192.168.255.9
:put "Create VETH DNSProxy"} on-error {}
:do {/interface/list/member/add interface=DNSProxy list=InAccept
:put "Add in interfacelist InAccept interface DNSProxy"} on-error {}
:do {/ip/address/add address=192.168.255.9/30 interface=DNSProxy
:put "Add address Mikrotik for interface DNSProxy"} on-error {}
:do {/ip/dns/forwarders/add name=DNSProxy dns-servers=192.168.255.10 verify-doh-cert=no
:put "Add DNS Forwarders DNSProxy"} on-error {}

:do {/interface/list/add name=Containers
:put "Create interfacelist Containers"} on-error {}
:do {/interface/list/member/add interface=MihomoProxyRoS list=Containers
:put "Add in interfacelist Containers interface MihomoProxyRoS"} on-error {}
:do {/interface/list/member/add interface=ByeDPI list=Containers
:put "Add in interfacelist Containers interface ByeDPI"} on-error {}
:do {/interface/list/member/add interface=DNSProxy list=Containers
:put "Add in interfacelist Containers interface DNSProxy"} on-error {}

:do {
/ip dns forwarders
add doh-servers=https://dns.google/dns-query name=Google
add doh-servers=https://cloudflare-dns.com/dns-query name=CloudFlare
add doh-servers=https://dns.quad9.net/dns-query name=Quad9
add dns-servers=176.99.11.77,80.78.247.254 name=XBOX
add dns-servers=77.88.8.8,77.88.8.1 name=Yandex verify-doh-cert=no
add dns-servers=8.8.8.8 name=Google8 verify-doh-cert=no
/certificate/settings/set builtin-trust-anchors=not-trusted
/certificate/settings/set builtin-trust-anchors=trusted
/ip/dns/set allow-remote-requests=yes cache-max-ttl=1d cache-size=15000KiB doh-max-concurrent-queries=500 doh-max-server-connections=10 servers=8.8.8.8 use-doh-server=https://dns.google/dns-query verify-doh-cert=yes
/ip dns static
add forward-to=Google8 match-subdomain=yes name=pool.ntp.org type=FWD
add address=8.8.8.8 comment="DNS Google" name=dns.google type=A
add address=8.8.4.4 comment="DNS Google" name=dns.google type=A
add address=104.16.248.249 comment="DNS CloudFlare" name=cloudflare-dns.com type=A
add address=104.16.249.249 comment="DNS CloudFlare" name=cloudflare-dns.com type=A
add address=9.9.9.9 comment="DNS Quad9" name=dns.quad9.net type=A
add address=149.112.112.112 comment="DNS Quad9" name=dns.quad9.net type=A
add address=176.99.11.77 comment="XBOX DNS" name=xbox-dns.ru type=A
add address=185.46.11.181 comment="XBOX DNS" name=xbox-dns.ru type=A
/system ntp client
set enabled=yes
/system ntp client servers
add address=0.ru.pool.ntp.org
add address=1.ru.pool.ntp.org
add address=2.ru.pool.ntp.org
add address=3.ru.pool.ntp.org
:put "DNS and NTP client configuration complete"
/ipv6 nd set [ find default=yes ] advertise-dns=yes disabled=yes
/ipv6 settings set accept-redirects=no accept-router-advertisements=no allow-fast-path=no disable-ipv6=yes disable-link-local-address=yes forward=no
:put "Disable ipv6"
#/ip service
#set ftp disabled=yes
#set ssh disabled=yes
#set telnet disabled=yes
#set www disabled=yes
#set api disabled=yes
#set api-ssl disabled=yes
#:put "Disable services ftp, ssh, telnet, www, api, api-ssl"
/ip route
add blackhole comment=BlackHole disabled=no distance=254 dst-address=10.0.0.0/8 gateway="" routing-table=main scope=30 suppress-hw-offload=no
add blackhole comment=BlackHole disabled=no distance=254 dst-address=172.16.0.0/12 gateway="" routing-table=main scope=30 suppress-hw-offload=no
add blackhole comment=BlackHole disabled=no distance=254 dst-address=192.168.0.0/16 gateway="" routing-table=main scope=30 suppress-hw-offload=no
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
add blackhole comment=BlackHole disabled=no distance=254 dst-address=10.0.0.0/8 gateway="" routing-table=MihomoProxyRoS scope=30 suppress-hw-offload=no
add blackhole comment=BlackHole disabled=no distance=254 dst-address=172.16.0.0/12 gateway="" routing-table=MihomoProxyRoS scope=30 suppress-hw-offload=no
add blackhole comment=BlackHole disabled=no distance=254 dst-address=192.168.0.0/16 gateway="" routing-table=MihomoProxyRoS scope=30 suppress-hw-offload=no
:put "Add default route 0.0.0.0/0 into routing table MihomoProxyRoS & BlackHole route"}

:local softid [/system/license/get software-id]
:local model [/system/resource/get board-name]
:local version [/system/resource/get version]

/container/envs
:do {add key=FAKE_IP_RANGE list=MihomoProxyRoS value=198.18.0.0/15
:put "Add env FAKE_IP_RANGE value: 198.18.0.0/15"} on-error {}
:do {add key=FAKE_IP_FILTER list=MihomoProxyRoS value=www.youtube.com
:put "Add env FAKE_IP_FILTER value: www.youtube.com"} on-error {}
:do {add key=LOG_LEVEL list=MihomoProxyRoS value=error
:put "Add env LOG_LEVEL value: error"} on-error {}
:do {add key=TTL_FAKEIP list=MihomoProxyRoS value=10
:put "Add env TTL_FAKEIP value: 10"} on-error {}
:do {add key=BYEDPI list=MihomoProxyRoS value=true
:put "Add env BYEDPI value: true"} on-error {}
:do {add key=BYEDPI_ADDRESS list=MihomoProxyRoS value=192.168.255.6
:put "Add env BYEDPI_ADDRESS value: 192.168.255.6"} on-error {}
:do {add key=BYEDPI_SOCKS_PORT list=MihomoProxyRoS value=1080
:put "Add env BYEDPI_SOCKS_PORT: 1080"} on-error {}
:do { add key=GROUP list=MihomoProxyRoS value=youtube,telegram,discord,amazon
:put "Add env GROUP value: youtube,telegram,discord,amazon"} on-error {}
:do { add key=YOUTUBE_GEOSITE list=MihomoProxyRoS value=youtube
:put "Add env YOUTUBE_GEOSITE value: youtube"} on-error {}
:do { add key=YOUTUBE_PRIORITY list=MihomoProxyRoS value=1
:put "Add env YOUTUBE_PRIORITY value: 1"} on-error {}
:do { add key=TELEGRAM_GEOSITE list=MihomoProxyRoS value=telegram
:put "Add env TELEGRAM_GEOSITE value: telegram"} on-error {}
:do { add key=TELEGRAM_GEOIP list=MihomoProxyRoS value=telegram
:put "Add env TELEGRAM_GEOIP value: telegram"} on-error {}
:do { add key=TELEGRAM_AS list=MihomoProxyRoS value=AS62041,AS59930,AS62014,AS211157,AS44907
:put "Add env TELEGRAM_AS value: AS62041,AS59930,AS62014,AS211157,AS44907"} on-error {}
:do { add key=TELEGRAM_PRIORITY list=MihomoProxyRoS value=2
:put "Add env TELEGRAM_PRIORITY value: 2"} on-error {}
:do { add key=DISCORD_GEOSITE list=MihomoProxyRoS value=discord
:put "Add env DISCORD_GEOSITE value: telegram"} on-error {}
:do { add key=DISCORD_GEOIP list=MihomoProxyRoS value=discord
:put "Add env DISCORD_GEOIP value: telegram"} on-error {}
:do { add key=AMAZON_AS list=MihomoProxyRoS value=AS16509
:put "Add env AMAZON_AS value: AS16509"} on-error {}
:do { add key=SW_ID_FOR_HWID list=MihomoProxyRoS value=$softid
:put "Add env SW_ID_FOR_HWID value: $softid"} on-error {}
:do { add key=DEVICE_OS list=MihomoProxyRoS value=RouterOS
:put "Add env DEVICE_OS value:RouterOS"} on-error {}
:do { add key=VER_OS list=MihomoProxyRoS value=$version
:put "Add env VER_OS value: $version"} on-error {}
:do { add key=DEVICE_MODEL list=MihomoProxyRoS value=$model
:put "Add env DEVICE_MODEL value: $model"} on-error {}
:do { add key=USER_AGENT list=MihomoProxyRoS value=medium1992/mihomo-proxy-ros
:put "Add env USER_AGENT value: medium1992/mihomo-proxy-ros"} on-error {}
:do {
add key=LINK1 list=MihomoProxyRoS value=$inputLINK
:put "Add env LINK1 value: $inputLINK"
} on-error {
:if ($inputLINK != [/container/envs/get [find key=LINK1 list=MihomoProxyRoS] value]) do={
set [find where key=LINK1 list=MihomoProxyRoS] value=$inputLINK
:put "Set env LINK1 new value: $inputLINK"
}
}
:do {
add key=SUB_LINK1 list=MihomoProxyRoS value=$inputSUBLINK
:put "Add env SUBLINK1 value: $inputSUBLINK"
} on-error {
:if ($inputSUBLINK != [/container/envs/get [find key=SUB_LINK1 list=MihomoProxyRoS] value]) do={
set [find where key=SUB_LINK1 list=MihomoProxyRoS] value=$inputSUBLINK
:put "Set env SUBLINK1 new value: $inputLINK"
}
}

:if ([:len [/ip/route/find comment="MihomoProxyRoS1"]] = 0) do={
/ip/route/add dst-address=198.18.0.0/15 gateway=192.168.255.2 comment="MihomoProxyRoS1"
:put "Add ip route FakeIP"}

/ip/firewall/address-list
:do {
add address=1.1.1.1 list=DNS
add address=9.9.9.9 list=DNS
add address=149.112.112.112 list=DNS
add address=104.16.248.249 list=DNS
add address=104.16.249.249 list=DNS
add address=8.8.8.8 list=DNS
add address=8.8.4.4 list=DNS
:put "Add address list DNS"
} on-error {}

/ip firewall mangle
:if ([:len [find comment="MSSClamp"]] = 0) do={add action=change-mss chain=postrouting new-mss=clamp-to-pmtu protocol=tcp tcp-flags=syn connection-state=new comment="MSSClamp"; :put "Add mangle rules 1"}
:if ([:len [find comment="YT_MSS"]] = 0) do={add action=change-mss chain=postrouting dst-address-list=YT in-interface=ByeDPI new-mss=88 protocol=tcp tcp-flags=syn connection-state=new comment="YT_MSS"; :put "Add mangle rules YT_MSS"}
:if ([:len [find comment="Accept_no_mark"]] = 0) do={add action=accept chain=prerouting connection-mark=no-mark connection-state=established,related,untracked comment="Accept_no_mark"; :put "Add mangle rules 2"}
:if ([:len [find comment="AcceptInWAN&Containers"]] = 0) do={add action=accept chain=prerouting in-interface-list=InAccept comment="AcceptInWAN&Containers"; :put "Add mangle rules 3"}
:if ([:len [find comment="RoutingToMihomo2"]] = 0) do={add action=mark-routing chain=prerouting in-interface-list=LAN connection-mark=MihomoProxyRoS new-routing-mark=MihomoProxyRoS passthrough=no comment="RoutingToMihomo2"; :put "Add mangle rules 4"}
:if ([:len [find comment="MarkConnAddressList"]] = 0) do={add action=mark-connection chain=prerouting connection-state=new dst-address-list=MihomoProxyRoS new-connection-mark=MihomoProxyRoS comment="MarkConnAddressList"; :put "Add mangle rules 5"}
:if ([:len [find comment="Telegram_RTC"]] = 0) do={add action=mark-connection chain=prerouting connection-state=new content="\12\A4\42" dst-address-list=Telegram in-interface-list=LAN new-connection-mark=MihomoProxyRoS protocol=udp comment="Telegram_RTC"; :put "Add mangle rules 6"}
:if ([:len [find comment="Discord_RTC"]] = 0) do={add action=mark-connection chain=prerouting connection-bytes=102 connection-state=new content="\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00" dst-address-type=!local in-interface-list=LAN new-connection-mark=MihomoProxyRoS dst-port=19294-19344,50000-50100 protocol=udp comment="Discord_RTC"; :put "Add mangle rules 7"}
:if ([:len [find comment="Discord_WebRTC"]] = 0) do={add action=mark-connection chain=prerouting connection-bytes=128 connection-state=new content="\12\A4\42" dst-address-type=!local in-interface-list=LAN new-connection-mark=MihomoProxyRoS dst-port=19294-19344,50000-50100 protocol=udp comment="Discord_WebRTC"; :put "Add mangle rules 8"}
:if ([:len [find comment="RoutingToMihomo1"]] = 0) do={add action=mark-routing chain=prerouting in-interface-list=LAN connection-mark=MihomoProxyRoS new-routing-mark=MihomoProxyRoS passthrough=no comment="RoutingToMihomo1"; :put "Add mangle rules 9"}

/ip firewall address-list
:do {add list=YT comment=YT_MSS address=www.youtube.com} on-error {}
:do {add list=MihomoProxyRoS comment=YT address=www.youtube.com} on-error {}
:do {add list=MihomoProxyRoS comment=TelegramFromAS31500 address=109.239.140.0/24} on-error {}

/ip dns static
:if ([:len [find name="themoviedb.org"]] = 0) do={ add address-list=MihomoProxyRoS forward-to=Quad9 comment="tmdb" match-subdomain=yes type=FWD name="themoviedb.org" }
:if ([:len [find name="tmdb.org"]] = 0) do={ add address-list=MihomoProxyRoS forward-to=Quad9 comment="tmdb" match-subdomain=yes type=FWD name="tmdb.org" }
:if ([:len [find name="tmdb-image-prod.b-cdn.net"]] = 0) do={ add address-list=MihomoProxyRoS forward-to=Quad9 comment="tmdb" type=FWD name="tmdb-image-prod.b-cdn.net" }

:if ([:len [/system/script/find name="IP_MihomoProxyRoS"]] = 0) do={
/system script
add name=IP_MihomoProxyRoS source="# Define global variables\r\
\n:global AddressList \"MihomoProxyRoS\"\r\
\n\r\
\n# List of resources corresponding to RSC files\r\
\n:global resources {\r\
\n\"geoipv4/twitter\";\r\
\n\"asnv4/AS13414\";\r\
\n\"asnv4/AS63179\";\r\
\n\"asnv4/AS35995\";\r\
\n\"geoipv4/facebook\";\r\
\n\"asnv4/AS32934\";\r\
\n\"asnv4/AS54115\";\r\
\n\"geoipv4/netflix\";\r\
\n\"asnv4/AS2906\"\r\
\n}\r\
\n\r\
\n# Base URL for RSC files\r\
\n:local baseUrl \"https://raw.githubusercontent.com/Medium1992/MikroTik_IPlist/refs/heads/main/for_scripts\
\"\r\
\n\r\
\n:foreach resource in=\$resources do={\r\
\n:local url \"\$baseUrl/\$resource.rsc\"\r\
\n:do {\r\
\n:local r [/tool fetch url=\$url mode=https output=user as-value]\r\
\n:if ((\$r->\"status\")=\"finished\") do={\r\
\n:local content (\$r->\"data\")\r\
\n:local s [:parse \$content]\r\
\n\$s\r\
\n:log warning \"\$resource.rsc loading completed\"\r\
\n:put \"\$resource.rsc loading completed\"\r\
\n}\r\
\n} on-error {}\r\
\n:local part 1\r\
\n:local continue true\r\
\n:while (\$continue) do={\r\
\n:local url \"\$baseUrl/\$resource_part\$part.rsc\"\r\
\n:do {\r\
\n:local r [/tool fetch url=\$url mode=https output=user as-value]\r\
\n:if ((\$r->\"status\")=\"finished\") do={\r\
\n:local content (\$r->\"data\")\r\
\n:local s [:parse \$content]\r\
\n\$s\r\
\n:log warning \"\$resource.rsc part\$part loading completed\"\r\
\n:put \"\$resource.rsc part\$part loading completed\"\r\
\n}\r\
\n:set part (\$part + 1)\r\
\n} on-error {\r\
\n:set continue false\r\
\n}\r\
\n}\r\
\n}"
:put "Add script IP_AddressList for pull IPs to ip firewall address-list"}

:if ([:len [/system/script/find name="IP_Telegram"]] = 0) do={
/system script
add name=IP_Telegram source="# Define global variables\r\
\n:global AddressList \"Telegram\"\r\
\n\r\
\n# List of resources corresponding to RSC files\r\
\n:global resources {\r\
\n\"geoipv4/telegram\";\r\
\n\"asnv4/AS62041\";\r\
\n\"asnv4/AS59930\";\r\
\n\"asnv4/AS62014\";\r\
\n\"asnv4/AS211157\";\r\
\n\"asnv4/AS44907\"\r\
\n}\r\
\n\r\
\n# Base URL for RSC files\r\
\n:local baseUrl \"https://raw.githubusercontent.com/Medium1992/MikroTik_IPlist/refs/heads/main/for_scripts\
\"\r\
\n\r\
\n:foreach resource in=\$resources do={\r\
\n:local url \"\$baseUrl/\$resource.rsc\"\r\
\n:do {\r\
\n:local r [/tool fetch url=\$url mode=https output=user as-value]\r\
\n:if ((\$r->\"status\")=\"finished\") do={\r\
\n:local content (\$r->\"data\")\r\
\n:local s [:parse \$content]\r\
\n\$s\r\
\n:log warning \"\$resource.rsc loading completed\"\r\
\n:put \"\$resource.rsc loading completed\"\r\
\n}\r\
\n} on-error {}\r\
\n:local part 1\r\
\n:local continue true\r\
\n:while (\$continue) do={\r\
\n:local url \"\$baseUrl/\$resource_part\$part.rsc\"\r\
\n:do {\r\
\n:local r [/tool fetch url=\$url mode=https output=user as-value]\r\
\n:if ((\$r->\"status\")=\"finished\") do={\r\
\n:local content (\$r->\"data\")\r\
\n:local s [:parse \$content]\r\
\n\$s\r\
\n:log warning \"\$resource.rsc part\$part loading completed\"\r\
\n:put \"\$resource.rsc part\$part loading completed\"\r\
\n}\r\
\n:set part (\$part + 1)\r\
\n} on-error {\r\
\n:set continue false\r\
\n}\r\
\n}\r\
\n}"
:put "Add script IP_AddressList for pull IPs to ip firewall address-list"}

:if ([:len [/system/script/find name="FWD_update"]] = 0) do={
/system script
add name=FWD_update source="# Define global variables\r\
\n:global AddressList \"\"\r\
\n:global ForwardTo \"MihomoProxyRoS\"\r\
\n\r\
\n# List of resources corresponding to RSC files\r\
\n:global resources {\r\
\n\"youtube\";\r\
\n\"meta\";\r\
\n\"netflix\";\r\
\n\"discord\";\r\
\n\"torrent\";\r\
\n\"rutracker\";\r\
\n\"adguard\";\r\
\n\"anime\";\r\
\n\"deepl\";\r\
\n\"openai\";\r\
\n\"google-gemini\";\r\
\n\"canva\";\r\
\n\"art\";\r\
\n\"tidal\";\r\
\n\"spotify\";\r\
\n\"tiktok\";\r\
\n\"music\";\r\
\n\"x\";\r\
\n\"xhamster\";\r\
\n\"porn\";\r\
\n\"video\";\r\
\n\"telegram\"\r\
\n\"claude\";\r\
\n\"xai\";\r\
\n\"notion\";\r\
\n\"twitch\";\r\
\n\"supercell\";\r\
\n\"xbox\";\r\
\n\"playstation\";\r\
\n\"pornhub\"\r\
\n}\r\
\n\r\
\n# Base URL for RSC files\r\
\n:local baseUrl \"https://raw.githubusercontent.com/Medium1992/MikroTik_DNS_FWD/refs/heads/main/for_scripts\"\r\
\n\r\
\n:foreach resource in=\$resources do={\r\
\n:local url \"\$baseUrl/\$resource.rsc\"\r\
\n:do {\r\
\n:local r [/tool fetch url=\$url mode=https output=user as-value]\r\
\n:if ((\$r->\"status\")=\"finished\") do={\r\
\n:local content (\$r->\"data\")\r\
\n:local s [:parse \$content]\r\
\n\$s\r\
\n:log warning \"\$resource.rsc loading completed\"\r\
\n:put \"\$resource.rsc loading completed\"\r\
\n}\r\
\n} on-error {}\r\
\n:local part 1\r\
\n:local continue true\r\
\n:while (\$continue) do={\r\
\n:local url \"\$baseUrl/\$resource_part\$part.rsc\"\r\
\n:do {\r\
\n:local r [/tool fetch url=\$url mode=https output=user as-value]\r\
\n:if ((\$r->\"status\")=\"finished\") do={\r\
\n:local content (\$r->\"data\")\r\
\n:local s [:parse \$content]\r\
\n\$s\r\
\n:log warning \"\$resource.rsc part\$part loading completed\"\r\
\n:put \"\$resource.rsc part\$part loading completed\"\r\
\n}\r\
\n:set part (\$part + 1)\r\
\n} on-error {\r\
\n:set continue false\r\
\n}\r\
\n}\r\
\n}"
:put "Add script FWD_update for pull resources to DNS static FWD"}

:if ([:len [/system/scheduler/find comment="MihomoProxyRoS"]] = 0) do={
:do {
:put "Run script FWD_update, pls wait for DNS static entries pulled"
/system/script/run FWD_update
:put "Run script IP_MihomoProxyRoS, pls wait for IPs static entries pulled"
/system/script/run IP_MihomoProxyRoS
:put "Run script IP_Telegram, pls wait for IPs static entries pulled"
/system/script/run IP_Telegram
} on-error {}
}
:do {
/system scheduler
add interval=1d name=update_FWD start-time=06:30:00 comment="MihomoProxyRoS" on-event="/system/script/run FWD_update\r\
\n/system/script/run IP_MihomoProxyRoS\r\
\n/system/script/run IP_Telegram"
:put "Add shedule update resources on 06:30 AM every day"
} on-error {} 

:local flagContainer false
:while ($flagContainer = false) do={
:if ([:len [/container/mounts/find comment="MihomoProxyRoSAWG"]] = 0) do={
:do { /file/add name=awg_conf type=directory} on-error {}
/container/mounts/add src=/awg_conf/ dst=/root/.config/mihomo/awg/ name=awg_conf comment="MihomoProxyRoSAWG"
}
:if ([:len [/container/find comment="MihomoProxyRoS"]] = 0) do={
/container/add remote-image="ghcr.io/medium1992/mihomo-proxy-ros" envlists=MihomoProxyRoS mount=awg_conf interface=MihomoProxyRoS root-dir=($pathPull . "Containers/MihomoProxyRoS") start-on-boot=yes comment="MihomoProxyRoS"
:put "Start pull MihomoProxyRoS container, pls wait when container starting, pls wait"
:delay 1
}
:if ([:len [/container/find comment="MihomoProxyRoS" and stopped]] > 0) do={
/container/start [find where comment="MihomoProxyRoS" and stopped]
:put "Container MihomoProxyRoS started"
:set $flagContainer true
}
:if ([:len [/container/find comment="MihomoProxyRoS" and download/extract failed]] > 0) do={
/container/repull [find where comment="MihomoProxyRoS"]
:put "Container MihomoProxyRoS extract failed, repull, pls wait"
:delay 1
}
:if ([:len [/container/find comment="MihomoProxyRoS" and (stopped or running)]] > 0) do={
/container/start [find where comment="MihomoProxyRoS" and stopped]
:delay 3
:if ([:len [/container/find comment="MihomoProxyRoS" and running]] > 0) do={
:put "Container MihomoProxyRoS started"
:set $flagContainer true
}
:if ([:len [/container/find comment="MihomoProxyRoS" and stopped]] > 0) do={
/container/repull [find where comment="MihomoProxyRoS"]
:put "Container MihomoProxyRoS extract failed, repull, pls wait"
:delay 1
}
}
:if ([:len [/container/find comment="MihomoProxyRoS" and download/extract failed]] > 0) do={
/container/repull [find where comment="MihomoProxyRoS"]
:put "Container MihomoProxyRoS extract failed, repull, pls wait"
:delay 1
}
:delay 1
}

:set flagContainer false
:while ($flagContainer = false) do={
:if ([:len [/container/find comment="DNSProxy"]] = 0) do={
/container/add remote-image="ghcr.io/medium1992/dns-proxy-ros" interface=DNSProxy cmd="--cache --hosts-files=/hosts --upstream \"[/www.youtube.com/]192.168.255.2:53\" --ipv6-disabled --upstream https://dns.google/dns-query --upstream https://cloudflare-dns.com/dns-query --upstream https://dns.quad9.net/dns-query --upstream-mode=parallel" root-dir=($pathPull . "Containers/DNSProxy") start-on-boot=yes comment="DNSProxy"
:put "Start pull DNSProxy container, pls wait when container starting, pls wait"
:delay 1
}
:if ([:len [/container/find comment="DNSProxy" and stopped]] > 0) do={
/container/start [find where comment="DNSProxy" and stopped]
:put "Container DNSProxy started"
:set $flagContainer true
}
:if ([:len [/container/find comment="DNSProxy" and download/extract failed]] > 0) do={
/container/repull [find where comment="DNSProxy"]
:put "Container DNSProxy extract failed, repull, pls wait"
:delay 1
}
:if ([:len [/container/find comment="DNSProxy" and (stopped or running)]] > 0) do={
/container/start [find where comment="DNSProxy" and stopped]
:delay 3
:if ([:len [/container/find comment="DNSProxy" and running]] > 0) do={
:put "Container DNSProxy started"
:set $flagContainer true
}
:if ([:len [/container/find comment="DNSProxy" and stopped]] > 0) do={
/container/repull [find where comment="DNSProxy"]
:put "Container DNSProxy extract failed, repull, pls wait"
:delay 1
}
}
:if ([:len [/container/find comment="DNSProxy" and download/extract failed]] > 0) do={
/container/repull [find where comment="DNSProxy"]
:put "Container DNSProxy extract failed, repull, pls wait"
:delay 1
}
:delay 1
}

:set flagContainer false
:while ($flagContainer = false) do={
:if ([:len [/container/find comment="ByeDPI"]] = 0) do={
/container/add remote-image="registry-1.docker.io/wiktorbgu/byedpi-mikrotik" interface=ByeDPI cmd="--split 4+se --udp-fake 1 --oob 86 --mod-http rmspace --disorder 15+s --tlsrec 5+s --split -1+se --split 46+se --split 88:7:10 --proto ipv4 --auto=torst,redirect,ssl_err --def-ttl 128 --auto=torst,redirect,ssl_err --split 1+s --disoob 1 --udp-fake 1 --auto=torst,redirect,ssl_err --oob 10+h --disorder 1 --tlsrec 4:7+s --split 1+s --disorder 3+s --udp-fake 1 --auto=torst,redirect,ssl_err --oob 10+h --disorder 1 --tlsrec 4:7+s --split 1+s --disorder 3+s --udp-fake 1 --auto=torst,redirect,ssl_err --fake -1 --fake-offset 5 --tlsrec 4:7+s --udp-fake 1 --auto=torst,redirect,ssl_err --split 1 --oob 1+s --split -1 --udp-fake 1 --auto=torst,redirect,ssl_err --oob 10+h --disorder 1 --tlsrec 4:7+s --split 1+s --disorder 3+s --udp-fake 1 --auto=torst,redirect,ssl_err --split 1+s --disoob 1 --udp-fake 1 --auto=torst,redirect,ssl_err --proto udp --udp-fake 1 --fake-sni --disorder 1 --split 0+s --disorder 3+s --split 6+s --disorder 9+s --split 12+s --disorder 15+s --split 20+s --disorder 25+s --split 30+s --disorder 35+s --auto=torst,redirect,ssl_err --split 1 --disoob 1 --auto=torst,redirect,ssl_err --split 5 --oob 25000+s --auto=torst,redirect,ssl_err --oob 1 --disorder 1 --tlsrec 1+s --ttl 10 --fake-tls-mod msize=1500 --split 0+s --disorder 3+s --auto=torst,redirect,ssl_err --fake -1 --tlsrec 1+s --auto=torst,redirect,ssl_err --split 1 --oob 1+s --split -1" root-dir=($pathPull . "Containers/ByeDPI") dns=192.168.255.10 start-on-boot=yes comment="ByeDPI"
:put "Start pull ByeDPI container, pls wait when container starting, pls wait"
:delay 1
}
:if ([:len [/container/find comment="ByeDPI" and stopped]] > 0) do={
/container/start [find where comment="ByeDPI" and stopped]
:put "Container ByeDPI started"
:set $flagContainer true
}
:if ([:len [/container/find comment="ByeDPI" and download/extract failed]] > 0) do={
/container/repull [find where comment="ByeDPI"]
:put "Container ByeDPI extract failed, repull, pls wait"
:delay 1
}
:if ([:len [/container/find comment="ByeDPI" and (stopped or running)]] > 0) do={
/container/start [find where comment="ByeDPI" and stopped]
:delay 3
:if ([:len [/container/find comment="ByeDPI" and running]] > 0) do={
:put "Container ByeDPI started"
:set $flagContainer true
}
:if ([:len [/container/find comment="ByeDPI" and stopped]] > 0) do={
/container/repull [find where comment="ByeDPI"]
:put "Container ByeDPI extract failed, repull, pls wait"
:delay 1
}
}
:if ([:len [/container/find comment="ByeDPI" and download/extract failed]] > 0) do={
/container/repull [find where comment="ByeDPI"]
:put "Container ByeDPI extract failed, repull, pls wait"
:delay 1
}
:delay 1
}

:if ([:len [/system/script/find name="changeDNS"]] = 0) do={
/system script
add name=changeDNS source=":if ([:len [/container/find comment=\"DNSProxy\" and running]] > 0 and [/ip/dns/get servers]!=192.168.255.10) d\
o={\r\
\n/ip dns set use-doh-server=\"\" verify-doh-cert=no\r\
\n/ip dns set servers=\"\"\r\
\n/ip dns set servers=192.168.255.10\r\
\n/ip dns cache flush\r\
\n:log warning \"change DNS server to DNSProxy\"\r\
\n} \r\
\n:if ([:len [/container/find comment=\"DNSProxy\" and stopped]] > 0 and [/ip/dns/get servers]=192.168.255.10) do={\r\
\n/ip dns set servers=\"\"\r\
\n/ip dns set servers=8.8.8.8\r\
\n/ip dns set use-doh-server=https://dns.google/dns-query verify-doh-cert=yes\r\
\n/ip dns cache flush\r\
\n:log warning \"change DNS server to DoH Google\"\r\
\n}"
:put "Add script changeDNS"}
:do {
/system scheduler
add interval=10s name=DNSchange on-event=changeDNS
:put "Add shedule DNSchange check every 10s"
} on-error {} 

/system/script/environment/remove [find where ]
:put "Script complete, enjoy, for use WG,AWG pls push conf files on Mikrotik to path /awg_conf/"
:put "For donate USDT(TRC20):TWDDYD1nk5JnG6FxvEu2fyFqMCY9PcdEsJ"
:log warning "script complete, enjoy!"
:log warning "For donate USDT(TRC20):TWDDYD1nk5JnG6FxvEu2fyFqMCY9PcdEsJ"
}
