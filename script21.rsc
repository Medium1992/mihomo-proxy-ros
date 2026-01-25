:local freespace [/system/resource/get free-hdd-space]
:if ($freespace<80914560 and ([:len [/container/find comment="MihomoProxyRoS"]] = 0) and ([:len [[/disk/find where fs=ext4 free>80914560]]] = 0)) do={
:put "Low free space on storage(s), script exit"
} else={
:local start
:put "Script loaded, press Enter to start"
:set start [/terminal ask]
:put "Starting script"

:local flagDNSproxy false
:local dnsproxy false
:local dnsproxychoice

:while ($flagDNSproxy=false) do={
:put "Specify whether you want to install dnsproxy:"
:put "- yes"
:put "- no"
:set dnsproxychoice [/terminal ask]
:if ($dnsproxychoice="yes") do={
:set dnsproxy true
:set flagDNSproxy true
}
:if ($dnsproxychoice="no") do={
:set flagDNSproxy true
}}

:local pathPull ""
:if (([:len [/container/find comment="MihomoProxyRoS"]] = 0) or (([:len [/container/find comment="DNSProxy"]] = 0) and $dnsproxy=true)) do={
:local slotArray 
:if ($freespace>=80914560) do={:set slotArray ($slotArray, "system")}
:local flagDisks false
:local slotDisk 
:local selectSlot 
foreach i in=[/disk/find where fs=ext4 free>80914560] do={
:set slotArray ($slotArray, [/disk/get [find where fs=ext4 free>80914560] value-name=slot]);
}
foreach i in=[/disk/find where fs=tmpfs free>80914560] do={
:set slotArray ($slotArray, [/disk/get [find where fs=tmpfs free>80914560] value-name=slot]);
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

:do {/interface/list/add name=Containers
:put "Create interfacelist Containers"} on-error {}
:do {/interface/list/member/add interface=MihomoProxyRoS list=Containers
:put "Add in interfacelist Containers interface MihomoProxyRoS"} on-error {}

:do {
/ip dns forwarders
add doh-servers=https://dns.google/dns-query name=Google
add doh-servers=https://cloudflare-dns.com/dns-query name=CloudFlare
add dns-servers=9.9.9.9,149.112.112.112 name=Quad9
add dns-servers=176.99.11.77,80.78.247.254 name=XBOX
add dns-servers=77.88.8.8,77.88.8.1 name=Yandex verify-doh-cert=no
add dns-servers=8.8.8.8 name=Google8 verify-doh-cert=no
/certificate/settings/set builtin-trust-store=dns,container
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
/ipv6 settings set accept-redirects=no accept-router-advertisements=no accept-router-advertisements-on=none allow-fast-path=no disable-ipv6=yes disable-link-local-address=yes forward=no
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

/container/envs
:do {add key=FAKE_IP_RANGE list=MihomoProxyRoS value=198.18.0.0/15
:put "Add env FAKE_IP_RANGE value: 198.18.0.0/15"} on-error {}
:do {add key=FAKE_IP_FILTER1 list=MihomoProxyRoS value="DOMAIN,www.youtube.com,real-ip"
:put "Add env FAKE_IP_FILTER1 value: DOMAIN,www.youtube.com,real-ip"} on-error {}
:do {add key=NAMESERVER_POLICY list=MihomoProxyRoS value="tmdb-image-prod.b-cdn.net#https://dns.quad9.net/dns-query,+.themoviedb.org#https://dns.quad9.net/dns-query,+.tmdb.org#https://dns.quad9.net/dns-query,rule-set:META_geosite_meta#https://dns.quad9.net/dns-query"
:put "Add env NAMESERVER_POLICY value: instagram, facebook, tmdb from Quad9"} on-error {}
:do {add key=LOG_LEVEL list=MihomoProxyRoS value=error
:put "Add env LOG_LEVEL value: error"} on-error {}
:do {add key=FAKE_IP_TTL list=MihomoProxyRoS value=10
:put "Add env FAKE_IP_TTL value: 10"} on-error {}
:do {add key=BYEDPI_CMD list=MihomoProxyRoS value="-Ku -a1 -An -d1 -s1+s -d3+s -s6+s -d9+s -s12+s -d15+s -s20+s -d25+s -s30+s -d35+s -At,r,s -s1 -q1 -At,r,s -s5 -o2 -At,r,s -o1 -d1 -r1+s -s1+s -d3+s -At,r,s -f-1 -r1+s -At,r,s -s1 -o1+s -s-1"
:put "Add env BYEDPI_CMD"} on-error {}
:if (([/system/resource/get architecture-name] = "arm64") or ([/system/resource/get architecture-name] = "x86_64")) do={
:do {add key=ZAPRET_CMD list=MihomoProxyRoS value=""
:put "Add env ZAPRET_CMD"} on-error {}
:do {add key=ZAPRET2_CMD list=MihomoProxyRoS value=""
:put "Add env ZAPRET2_CMD"} on-error {}
}
:do { add key=GROUP list=MihomoProxyRoS value=YouTube,Telegram,Discord,META,Roblox,SuperCell,AI,Twitch
:put "Add env GROUP value: YouTube,Telegram,Discord,META,Roblox,SuperCell,AI,Twitch"} on-error {}
:do { add key=YOUTUBE_GEOSITE list=MihomoProxyRoS value=youtube
:put "Add env YOUTUBE_GEOSITE value: youtube"} on-error {}
:do { add key=TELEGRAM_GEOSITE list=MihomoProxyRoS value=telegram
:put "Add env TELEGRAM_GEOSITE value: telegram"} on-error {}
:do { add key=TELEGRAM_GEOIP list=MihomoProxyRoS value=telegram
:put "Add env TELEGRAM_GEOIP value: telegram"} on-error {}
:do { add key=TELEGRAM_AS list=MihomoProxyRoS value=AS62041,AS59930,AS62014,AS211157,AS44907
:put "Add env TELEGRAM_AS value: AS62041,AS59930,AS62014,AS211157,AS44907"} on-error {}
:do { add key=TELEGRAM_IPCIDR list=MihomoProxyRoS value=109.239.140.0/24
:put "Add env TELEGRAM_IPCIDR value: 109.239.140.0/24"} on-error {}
:do { add key=DISCORD_GEOSITE list=MihomoProxyRoS value=discord
:put "Add env DISCORD_GEOSITE value: telegram"} on-error {}
:do { add key=DISCORD_GEOIP list=MihomoProxyRoS value=discord
:put "Add env DISCORD_GEOIP value: telegram"} on-error {}
:do { add key=META_GEOSITE list=MihomoProxyRoS value=meta
:put "Add env META_GEOSITE value: meta"} on-error {}
:do { add key=META_GEOIP list=MihomoProxyRoS value=facebook
:put "Add env META_GEOIP value: facebook"} on-error {}
:do { add key=META_AS list=MihomoProxyRoS value=AS32934,AS54115
:put "Add env META_AS value: AS32934,AS54115"} on-error {}
:do { add key=ROBLOX_GEOSITE list=MihomoProxyRoS value=roblox
:put "Add env ROBLOX_GEOSITE value: roblox"} on-error {}
:do { add key=ROBLOX_AS list=MihomoProxyRoS value=AS22697,AS11281,AS136766
:put "Add env ROBLOX_AS value: AS22697,AS11281,AS136766"} on-error {}
:do { add key=SUPERCELL_GEOSITE list=MihomoProxyRoS value=supercell
:put "Add env SUPERCELL_GEOSITE value: supercell"} on-error {}
:do { add key=AI_GEOSITE list=MihomoProxyRoS value=category-ai-!cn,openai,google-gemini
:put "Add env AI_GEOSITE value: category-ai-!cn,openai,google-gemini"} on-error {}
:do { add key=TWITCH_GEOSITE list=MihomoProxyRoS value=twitch
:put "Add env TWITCH_GEOSITE value: twitch"} on-error {}
:do { add key=RULES1 list=MihomoProxyRoS value="AND,((NETWORK,udp),(DST-PORT,443)),REJECT"
:put "Add env RULES1 value: AND,((NETWORK,udp),(DST-PORT,443)),REJECT"} on-error {}
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
:if ([:len [find comment="YT_MSS"]] = 0) do={add action=change-mss chain=forward dst-address-list=YT in-interface=MihomoProxyRoS new-mss=88 protocol=tcp tcp-flags=syn connection-state=new comment="YT_MSS"; :put "Add mangle rules YT_MSS"}
:if ([:len [find comment="Accept_no_mark"]] = 0) do={add action=accept chain=prerouting connection-mark=no-mark connection-state=established,related,untracked comment="Accept_no_mark"; :put "Add mangle rules 1"}
:if ([:len [find comment="AcceptInWAN&Containers"]] = 0) do={add action=accept chain=prerouting in-interface-list=InAccept comment="AcceptInWAN&Containers"; :put "Add mangle rules 2"}
:if ([:len [find comment="RoutingToMihomo2"]] = 0) do={add action=mark-routing chain=prerouting in-interface-list=LAN connection-mark=MihomoProxyRoS new-routing-mark=MihomoProxyRoS passthrough=no comment="RoutingToMihomo2"; :put "Add mangle rules 3"}
:if ([:len [find comment="MarkConnAddressList"]] = 0) do={add action=mark-connection chain=prerouting in-interface-list=LAN connection-mark=no-mark connection-state=new dst-address-list=MihomoProxyRoS new-connection-mark=MihomoProxyRoS comment="MarkConnAddressList"; :put "Add mangle rules 4"}
:if ([:len [find comment="Discord_RTC"]] = 0) do={add action=mark-connection chain=prerouting connection-bytes=102 connection-mark=no-mark connection-state=new content="\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00" dst-address-type=!local in-interface-list=LAN new-connection-mark=MihomoProxyRoS dst-port=19294-19344,50000-50100 protocol=udp comment="Discord_RTC"; :put "Add mangle rules 5"}
:if ([:len [find comment="Discord_WebRTC"]] = 0) do={add action=mark-connection chain=prerouting connection-bytes=128 connection-mark=no-mark connection-state=new content="\12\A4\42" dst-address-type=!local in-interface-list=LAN new-connection-mark=MihomoProxyRoS dst-port=19294-19344,50000-50100 protocol=udp comment="Discord_WebRTC"; :put "Add mangle rules 6"}
:if ([:len [find comment="RoutingToMihomo1"]] = 0) do={add action=mark-routing chain=prerouting in-interface-list=LAN connection-mark=MihomoProxyRoS new-routing-mark=MihomoProxyRoS passthrough=no comment="RoutingToMihomo1"; :put "Add mangle rules 7"}

/ip dns static
:if ([:len [find name="mask.icloud.com"]] = 0) do={ add name="mask.icloud.com" type=NXDOMAIN }
:if ([:len [find name="mask-h2.icloud.com"]] = 0) do={ add name="mask-h2.icloud.com" type=NXDOMAIN }
:if ([:len [find name="doh.dns.apple.com"]] = 0) do={ add name="doh.dns.apple.com" type=NXDOMAIN }
:if ([:len [find name="dns.apple.com"]] = 0) do={ add name="dns.apple.com" type=NXDOMAIN }
:if ([:len [find name="ntc.party"]] = 0) do={ add comment=NTCParty name=ntc.party type=CNAME cname=box.ntc.party }
:if ([:len [find name="usher.ttvnw.net"]] = 0) do={ add comment=twitch forward-to=MihomoProxyRoS match-subdomain=yes name=usher.ttvnw.net type=FWD }
:if ([:len [find name="gql.twitch.tv"]] = 0) do={ add comment=twitch forward-to=MihomoProxyRoS match-subdomain=yes name=gql.twitch.tv type=FWD }

/ip firewall address-list
:do {add list=YT comment=YT_MSS address=www.youtube.com} on-error {}
:do {add list=MihomoProxyRoS comment=YT address=www.youtube.com} on-error {}
:do {add list=MihomoProxyRoS comment=NTCParty address=ntc.party} on-error {}
:do {add list=MihomoProxyRoS comment=TelegramFromAS31500 address=109.239.140.0/24} on-error {}

:if ([:len [/system/script/find name="IP_MihomoProxyRoS"]] = 0) do={
/system script
add name=IP_MihomoProxyRoS source="# Define global variables\r\
\n:global AddressList \"MihomoProxyRoS\"\r\
\n\r\
\n# List of resources corresponding to RSC files\r\
\n:global resources {\r\
\n# Telegram\r\
\n\"geoipv4/telegram\";\r\
\n\"asnv4/AS62041\";\r\
\n\"asnv4/AS59930\";\r\
\n\"asnv4/AS62014\";\r\
\n\"asnv4/AS211157\";\r\
\n\"asnv4/AS44907\";\r\
\n# Twitter\r\
\n\"geoipv4/twitter\";\r\
\n\"asnv4/AS13414\";\r\
\n\"asnv4/AS63179\";\r\
\n\"asnv4/AS35995\";\r\
\n# Meta\r\
\n\"geoipv4/facebook\";\r\
\n\"asnv4/AS32934\";\r\
\n\"asnv4/AS54115\";\r\
\n# NetFlix\r\
\n\"geoipv4/netflix\";\r\
\n\"asnv4/AS2906\";\r\
\n# Roblox\r\
\n\"asnv4/AS22697\";\r\
\n\"asnv4/AS11281\";\r\
\n\"asnv4/AS136766\";\r\
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
\n\"telegram\";\r\
\n\"netflix\";\r\
\n\"discord\";\r\
\n\"rutracker\";\r\
\n\"torrent\";\r\
\n\"adguard\";\r\
\n\"anime\";\r\
\n\"deepl\";\r\
\n\"category-ai-!cn\";\r\
\n\"openai\";\r\
\n\"google-gemini\";\r\
\n\"canva\";\r\
\n\"art\";\r\
\n\"tidal\";\r\
\n\"tiktok\";\r\
\n\"music\";\r\
\n\"tmdb\";\r\
\n\"x\";\r\
\n\"kinopub\";\r\
\n\"xhamster\";\r\
\n\"porn\";\r\
\n\"video\";\r\
\n\"claude\";\r\
\n\"xai\";\r\
\n\"notion\";\r\
\n\"supercell\";\r\
\n\"xbox\";\r\
\n\"roblox\";\r\
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
} on-error {}
}
:do {
/system scheduler
add interval=1d name=update_FWD start-time=06:30:00 comment="MihomoProxyRoS" on-event="/system/script/run FWD_update\r\
\n/system/script/run IP_MihomoProxyRoS"
:put "Add schedule update resources on 06:30 AM every day"
} on-error {} 

:local flagContainer false
:while ($flagContainer = false) do={
:if ([:len [/container/mounts/find comment="MihomoProxyRoSAWG"]] = 0) do={
:do { /file/add name=awg_conf type=directory} on-error {}
/container/mounts/add src=/awg_conf/ dst=/root/.config/mihomo/awg/ list=awg_conf comment="MihomoProxyRoSAWG"
}
:if ([:len [/container/mounts/find comment="MihomoProxyRoSProxies"]] = 0) do={
:do { /file/add name=proxies_yaml type=directory} on-error {}
/container/mounts/add src=/proxies_yaml/ dst=/root/.config/mihomo/proxies_mount/ list=proxies_yaml comment="MihomoProxyRoSProxies"
}
:if ([:len [/container/mounts/find comment="MihomoProxyRoSRuleSet"]] = 0) do={
:do { /file/add name=ruleset_txt type=directory} on-error {}
/container/mounts/add src=/ruleset_txt/ dst=/root/.config/mihomo/rule_set_list list=ruleset_txt comment="MihomoProxyRoSRuleSet"
}
:if ([:len [/container/find comment="MihomoProxyRoS"]] = 0) do={
/container/add remote-image="ghcr.io/medium1992/mihomo-proxy-ros" envlists=MihomoProxyRoS mountlists=awg_conf,proxies_yaml,ruleset_txt interface=MihomoProxyRoS root-dir=($pathPull . "Containers/MihomoProxyRoS") start-on-boot=yes comment="MihomoProxyRoS"
:put "Start pull MihomoProxyRoS container, pls wait when container starting, pls wait"
:delay 1
}
:if ([:len [/container/find comment="MihomoProxyRoS" and (stopped or running)]] > 0) do={
/container/start [find where comment="MihomoProxyRoS" and stopped]
:delay 3
:if ([:len [/container/find comment="MihomoProxyRoS" and running]] > 0) do={
:put "Container MihomoProxyRoS started"
:set flagContainer true
}
}
:delay 1
}

:if ($dnsproxy=true) do={
:do {/interface/veth/add name=DNSProxy address=192.168.255.10/30 gateway=192.168.255.9
:put "Create VETH DNSProxy"} on-error {}
:do {/interface/list/member/add interface=DNSProxy list=InAccept
:put "Add in interfacelist InAccept interface DNSProxy"} on-error {}
:do {/ip/address/add address=192.168.255.9/30 interface=DNSProxy
:put "Add address Mikrotik for interface DNSProxy"} on-error {}
:do {/ip/dns/forwarders/add name=DNSProxy dns-servers=192.168.255.10 verify-doh-cert=no
:put "Add DNS Forwarders DNSProxy"} on-error {}
:do {/interface/list/member/add interface=DNSProxy list=Containers
:put "Add in interfacelist Containers interface DNSProxy"} on-error {}

:set flagContainer false
:while ($flagContainer = false) do={
:if ([:len [/container/find comment="DNSProxy"]] = 0) do={
/container/add remote-image="ghcr.io/medium1992/dns-proxy-ros" interface=DNSProxy cmd="--cache --hosts-files=/hosts --ipv6-disabled --upstream https://dns.google/dns-query --upstream https://cloudflare-dns.com/dns-query --upstream https://dns.quad9.net/dns-query --upstream-mode=parallel" root-dir=($pathPull . "Containers/DNSProxy") start-on-boot=yes comment="DNSProxy"
:put "Start pull DNSProxy container, pls wait when container starting, pls wait"
:delay 5
}
:if ([:len [/container/find comment="DNSProxy" and (stopped or running)]] > 0) do={
/container/start [find where comment="DNSProxy" and stopped]
:delay 3
:if ([:len [/container/find comment="DNSProxy" and running]] > 0) do={
:put "Container DNSProxy started"
:set flagContainer true
}
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
}

/system/script/environment/remove [find where ]
:put "Script complete, enjoy!"
:put "For use WG,AWG pls push conf files on Mikrotik to path /awg_conf/"
:put "Webpanel UI http://192.168.255.2:9090/ui/"
:put "For donate:"
:put "- USDT(TRC20):TWDDYD1nk5JnG6FxvEu2fyFqMCY9PcdEsJ"
:put "Invite link Telegram-group https://t.me/+96HVPF3Ww6o3YTNi"
:log warning "script complete, enjoy!"
:log warning "For use WG,AWG pls push conf files on Mikrotik to path /awg_conf/"
:log warning "Webpanel UI http://192.168.255.2:9090/ui/"
:log warning "For donate:"
:log warning "- USDT(TRC20):TWDDYD1nk5JnG6FxvEu2fyFqMCY9PcdEsJ"
:log warning "Invite link Telegram-group https://t.me/+96HVPF3Ww6o3YTNi"
}
