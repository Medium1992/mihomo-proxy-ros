:local freespace [/system/resource/get free-hdd-space]
:if ($freespace<80914560 and ([:len [/container/find comment="MihomoProxyRoS"]] = 0)) do={
:put "Low free space on storage, script exit"
} else={

:local start
:put "Script loaded, press Enter to start"
:set start [/terminal ask]
:put "Starting script"

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
/interface/list/find add name=WAN
:put "interface list WAN added, pls add interface to interface list WAN and press Enter to continue"
:set start [/terminal ask]
}
:if ([:len [/interface/list/find name=LAN]] = 0) do={
/interface/list/find add name=LAN
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
/ip service
set ftp disabled=yes
set ssh disabled=yes
set telnet disabled=yes
set www disabled=yes
set api disabled=yes
set api-ssl disabled=yes
:put "Disable services ftp, ssh, telnet, www, api, api-ssl"
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

/container/envs
:do {add key=FAKE_IP_RANGE list=MihomoProxyRoS value=198.18.0.0/15
:put "Add env FAKE_IP_RANGE value: 198.18.0.0/15"} on-error {}
:do {add key=LOG_LEVEL list=MihomoProxyRoS value=error
:put "Add env LOG_LEVEL value: error"} on-error {}
:do {add key=TTL_FAKEIP list=MihomoProxyRoS value=10
:put "Add env TTL_FAKEIP value: 10"} on-error {}
:do { add key=GROUP list=MihomoProxyRoS value=youtube,telegram
:put "Add env GROUP value: youtube,telegram"} on-error {}
:do { add key=TELEGRAM_GEOIP list=MihomoProxyRoS value=telegram
:put "Add env TELEGRAM_GEOIP value: telegram"} on-error {}
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
:if ([:len [find comment="MihomoProxyRoS1"]] = 0) do={add action=change-mss chain=postrouting new-mss=clamp-to-pmtu protocol=tcp tcp-flags=syn connection-state=new comment="MihomoProxyRoS1"; :put "Add mangle rules 1"}
#:if ([:len [find comment="YT_MSS"]] = 0) do={add action=change-mss chain=postrouting in-interface=ByeDPI content=www.youtube.com new-mss=88 protocol=tcp tcp-flags=syn connection-state=new comment="YT_MSS"; :put "Add mangle rules YT_MSS"}
:if ([:len [find comment="MihomoProxyRoS2"]] = 0) do={add action=accept chain=prerouting connection-mark=no-mark connection-state=established,related,untracked comment="MihomoProxyRoS2"; :put "Add mangle rules 2"}
:if ([:len [find comment="MihomoProxyRoS3"]] = 0) do={add action=accept chain=prerouting in-interface-list=InAccept comment="MihomoProxyRoS3"; :put "Add mangle rules 3"}
:if ([:len [find comment="MihomoProxyRoS4"]] = 0) do={add action=mark-routing chain=prerouting in-interface-list=LAN connection-mark=MihomoProxyRoS new-routing-mark=MihomoProxyRoS passthrough=no comment="MihomoProxyRoS4"; :put "Add mangle rules 4"}
:if ([:len [find comment="MihomoProxyRoS5"]] = 0) do={add action=mark-connection chain=prerouting connection-state=new dst-address-list=MihomoProxyRoS new-connection-mark=MihomoProxyRoS comment="MihomoProxyRoS5"; :put "Add mangle rules 5"}
:if ([:len [find comment="MihomoProxyRoS6"]] = 0) do={add action=mark-connection chain=prerouting connection-state=new content="\12\A4\42" dst-address-list=VoiceTelegram in-interface-list=LAN new-connection-mark=MihomoProxyRoS protocol=udp comment="MihomoProxyRoS6"; :put "Add mangle rules 6"}
:if ([:len [find comment="MihomoProxyRoS7"]] = 0) do={add action=mark-connection chain=prerouting connection-bytes=102 connection-state=new content="\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00" dst-address-type=!local in-interface-list=LAN new-connection-mark=MihomoProxyRoS dst-port=19000-20000,50000-50100 protocol=udp comment="MihomoProxyRoS7"; :put "Add mangle rules 7"}
:if ([:len [find comment="MihomoProxyRoS8"]] = 0) do={add action=mark-connection chain=prerouting connection-bytes=128 connection-state=new content="\12\A4\42" dst-address-type=!local in-interface-list=LAN new-connection-mark=MihomoProxyRoS dst-port=19000-20000,50000-50100 protocol=udp comment="MihomoProxyRoS8"; :put "Add mangle rules 8"}
:if ([:len [find comment="MihomoProxyRoS9"]] = 0) do={add action=mark-routing chain=prerouting in-interface-list=LAN connection-mark=MihomoProxyRoS new-routing-mark=MihomoProxyRoS passthrough=no comment="MihomoProxyRoS9"; :put "Add mangle rules 9"}

/ip firewall filter
:if ([:len [find comment="MihomoProxyRoSDNS"]] = 0) do={
add chain=input protocol=udp dst-port=53 in-interface-list=Containers comment="MihomoProxyRoSDNS" place-before=3
}

/ip firewall address-list
:do {add list=VoiceTelegram comment=Telegram address=91.105.192.0/23} on-error {}
:do {add list=VoiceTelegram comment=Telegram address=91.108.4.0/22} on-error {}
:do {add list=VoiceTelegram comment=Telegram address=91.108.8.0/21} on-error {}
:do {add list=VoiceTelegram comment=Telegram address=91.108.16.0/21} on-error {}
:do {add list=VoiceTelegram comment=Telegram address=91.108.56.0/22} on-error {}
:do {add list=VoiceTelegram comment=Telegram address=95.161.64.0/20} on-error {}
:do {add list=VoiceTelegram comment=Telegram address=109.239.140.0/24} on-error {}
:do {add list=VoiceTelegram comment=Telegram address=149.154.160.0/20} on-error {}
:do {add list=VoiceTelegram comment=Telegram address=185.76.151.0/24} on-error {}
:do {add list=MihomoProxyRoS comment=KinoPUB address=95.216.223.137} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=31.13.24.0/21} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=31.13.64.0/18} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=45.64.40.0/22} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=57.141.0.0/24} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=57.141.2.0/24} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=57.141.4.0/24} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=57.141.6.0/24} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=57.141.8.0/24} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=57.141.10.0/24} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=57.141.12.0/24} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=57.144.0.0/14} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=66.220.144.0/20} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=69.63.176.0/20} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=69.171.224.0/19} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=74.119.76.0/22} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=102.132.96.0/20} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=102.132.112.0/24} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=102.132.114.0/23} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=102.132.116.0/23} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=102.132.119.0/24} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=102.132.120.0/23} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=102.132.123.0/24} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=102.132.125.0/24} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=102.132.126.0/23} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=102.221.188.0/22} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=103.4.96.0/22} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=129.134.0.0/17} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=129.134.130.0/23} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=129.134.132.0/24} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=129.134.135.0/24} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=129.134.136.0/22} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=129.134.140.0/24} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=129.134.143.0/24} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=129.134.144.0/24} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=129.134.147.0/24} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=129.134.148.0/23} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=129.134.150.0/24} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=129.134.154.0/23} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=129.134.156.0/22} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=129.134.160.0/22} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=129.134.164.0/23} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=129.134.168.0/24} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=129.134.170.0/23} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=129.134.172.0/22} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=129.134.176.0/20} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=157.240.0.0/17} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=157.240.128.0/23} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=157.240.131.0/24} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=157.240.156.0/22} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=157.240.169.0/24} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=157.240.170.0/24} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=157.240.175.0/24} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=157.240.177.0/24} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=157.240.179.0/24} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=157.240.181.0/24} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=157.240.182.0/23} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=157.240.184.0/21} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=157.240.192.0/18} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=163.70.128.0/17} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=163.114.128.0/20} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=173.252.64.0/18} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=179.60.192.0/22} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=185.60.216.0/22} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=185.89.216.0/22} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=199.201.64.0/22} on-error {}
:do {add list=MihomoProxyRoS comment=FaceBook address=204.15.20.0/22} on-error {}
:do {add list=MihomoProxyRoS comment=Twitter address=8.25.194.0/23} on-error {}
:do {add list=MihomoProxyRoS comment=Twitter address=8.25.196.0/23} on-error {}
:do {add list=MihomoProxyRoS comment=Twitter address=64.63.0.0/18} on-error {}
:do {add list=MihomoProxyRoS comment=Twitter address=69.12.56.0/21} on-error {}
:do {add list=MihomoProxyRoS comment=Twitter address=69.195.160.0/19} on-error {}
:do {add list=MihomoProxyRoS comment=Twitter address=103.252.112.0/22} on-error {}
:do {add list=MihomoProxyRoS comment=Twitter address=104.244.40.0/23} on-error {}
:do {add list=MihomoProxyRoS comment=Twitter address=104.244.42.0/24} on-error {}
:do {add list=MihomoProxyRoS comment=Twitter address=104.244.44.0/22} on-error {}
:do {add list=MihomoProxyRoS comment=Twitter address=185.45.4.0/22} on-error {}
:do {add list=MihomoProxyRoS comment=Twitter address=188.64.224.0/21} on-error {}
:do {add list=MihomoProxyRoS comment=Twitter address=192.48.236.0/23} on-error {}
:do {add list=MihomoProxyRoS comment=Twitter address=192.133.76.0/22} on-error {}
:do {add list=MihomoProxyRoS comment=Twitter address=199.16.156.0/22} on-error {}
:do {add list=MihomoProxyRoS comment=Twitter address=199.59.148.0/22} on-error {}
:do {add list=MihomoProxyRoS comment=Twitter address=199.96.56.0/23} on-error {}
:do {add list=MihomoProxyRoS comment=Twitter address=202.160.128.0/22} on-error {}
:do {add list=MihomoProxyRoS comment=Twitter address=209.237.192.0/19} on-error {}
:do {add list=MihomoProxyRoS comment=Netflix address=23.246.0.0/18} on-error {}
:do {add list=MihomoProxyRoS comment=Netflix address=37.77.184.0/21} on-error {}
:do {add list=MihomoProxyRoS comment=Netflix address=45.57.0.0/17} on-error {}
:do {add list=MihomoProxyRoS comment=Netflix address=64.120.128.0/17} on-error {}
:do {add list=MihomoProxyRoS comment=Netflix address=66.197.128.0/19} on-error {}
:do {add list=MihomoProxyRoS comment=Netflix address=66.197.160.0/20} on-error {}
:do {add list=MihomoProxyRoS comment=Netflix address=66.197.182.0/23} on-error {}
:do {add list=MihomoProxyRoS comment=Netflix address=66.197.186.0/23} on-error {}
:do {add list=MihomoProxyRoS comment=Netflix address=66.197.188.0/22} on-error {}
:do {add list=MihomoProxyRoS comment=Netflix address=66.197.192.0/18} on-error {}
:do {add list=MihomoProxyRoS comment=Netflix address=69.53.224.0/20} on-error {}
:do {add list=MihomoProxyRoS comment=Netflix address=69.53.240.0/21} on-error {}
:do {add list=MihomoProxyRoS comment=Netflix address=69.53.248.0/23} on-error {}
:do {add list=MihomoProxyRoS comment=Netflix address=69.53.250.0/24} on-error {}
:do {add list=MihomoProxyRoS comment=Netflix address=69.53.252.0/22} on-error {}
:do {add list=MihomoProxyRoS comment=Netflix address=108.175.32.0/20} on-error {}
:do {add list=MihomoProxyRoS comment=Netflix address=185.2.220.0/22} on-error {}
:do {add list=MihomoProxyRoS comment=Netflix address=185.9.188.0/22} on-error {}
:do {add list=MihomoProxyRoS comment=Netflix address=192.173.64.0/18} on-error {}
:do {add list=MihomoProxyRoS comment=Netflix address=198.38.96.0/19} on-error {}
:do {add list=MihomoProxyRoS comment=Netflix address=198.45.48.0/20} on-error {}
:do {add list=MihomoProxyRoS comment=Netflix address=207.45.72.0/22} on-error {}
:do {add list=MihomoProxyRoS comment=Netflix address=208.75.76.0/22} on-error {}

/ip dns static
:if ([:len [find name="themoviedb.org"]] = 0) do={ add address-list=MihomoProxyRoS forward-to=Quad9 comment="tmdb" match-subdomain=yes type=FWD name="themoviedb.org" }
:if ([:len [find name="tmdb.org"]] = 0) do={ add address-list=MihomoProxyRoS forward-to=Quad9 comment="tmdb" match-subdomain=yes type=FWD name="tmdb.org" }
:if ([:len [find name="tmdb-image-prod.b-cdn.net"]] = 0) do={ add address-list=MihomoProxyRoS forward-to=Quad9 comment="tmdb" type=FWD name="tmdb-image-prod.b-cdn.net" }

:if ([:len [/system/script/find name="FWD_update"]] = 0) do={
/system script
add name=FWD_update source="# Define global variables\r\
    \n:global AddressList \"\"\r\
    \n:global ForwardTo \"MihomoProxyRoS\"\r\
    \n\r\
    \n# List of resources corresponding to RSC files\r\
    \n:local resources {\r\
    \n    \"youtube\";\r\
    \n    \"meta\";\r\
    \n    \"netflix\";\r\
    \n    \"discord\";\r\
    \n    \"torrent\";\r\
    \n    \"rutracker\";\r\
    \n    \"adguard\";\r\
    \n    \"anime\";\r\
    \n    \"deepl\";\r\
    \n    \"openai\";\r\
    \n    \"google-gemini\";\r\
    \n    \"canva\";\r\
    \n    \"art\";\r\
    \n    \"tidal\";\r\
    \n    \"spotify\";\r\
    \n    \"tiktok\";\r\
    \n    \"music\";\r\
    \n    \"x\";\r\
    \n    \"pornhub\";\r\
    \n    \"xhamster\";\r\
    \n    \"porn\";\r\
    \n    \"video\";\r\
    \n    \"telegram\"\r\
    \n}\r\
    \n\r\
    \n# Base URL for RSC files\r\
    \n:local baseUrl \"https://raw.githubusercontent.com/Medium1992/MikroTik_DNS_FWD/refs/heads/main/for_scripts\"\r\
    \n\r\
    \n# Fetch and execute each script\r\
    \n:foreach resource in=\$resources do={\r\
    \n    # First try the single file without _part\r\
    \n    :local url \"\$baseUrl/\$resource.rsc\"\r\
    \n    :do {\r\
    \n        :local r [/tool fetch url=\$url mode=https output=user as-value]\r\
    \n        :if ((\$r->\"status\")=\"finished\") do={\r\
    \n            :local content (\$r->\"data\")\r\
    \n            :if ([:len \$content] > 0 && [:find \$content \"/ip dns static\"] >= 0) do={\r\
    \n                :local s [:parse \$content]\r\
    \n                \$s\r\
    \n           \
    \n     :log warning \"\$resource.rsc loading completed\"\
    \n\r\
    \n            } else={\r\
    \n                :log warning \"Invalid or empty content: \$url\"\r\
    \n            }\r\
    \n        }\r\
    \n    } on-error={\r\
    \n        :log warning \"Error fetching single file \$resource.rsc, trying fetch parts file\"\r\
    \n        # If single file fails, try fetching parts\r\
    \n        :local part 1\r\
    \n        :local continue true\r\
    \n        :while (\$continue) do={\r\
    \n            :local url \"\$baseUrl/\$resource_part\$part.rsc\"\r\
    \n            :do {\r\
    \n                :local r [/tool fetch url=\$url mode=https output=user as-value]\r\
    \n                :if ((\$r->\"status\")=\"finished\") do={\r\
    \n                    :local content (\$r->\"data\")\r\
    \n                    :if ([:len \$content] > 0 && [:find \$content \"/ip dns static\"] >= 0) do={\r\
    \n                        :local s [:parse \$content]\r\
    \n                        \$s\r\
    \n                    } else={\r\
    \n                        :log warning \"Invalid or empty content \$resource.rsc\"\r\
    \n                        :set continue false\r\
    \n                    }\r\
    \n                } else={\r\
    \n                    :set continue false\r\
    \n                }\r\
    \n            } on-error={\r\
    \n                :if (\$part = 1) do={\r\
    \n\
    \n                   :log warning \"https://raw.githubusercontent.com is not available, check availability\"\
    \n\r\
    \n                } else={\r\
    \n                   :set part (\$part - 1)\r\
    \n           \
    \n        :log warning \"\$resource.rsc loading completed, number last part \$part\"\
    \n\r\
    \n                }\r\
    \n                :set continue false\r\
    \n            }\r\
    \n            :set part (\$part + 1)\r\
    \n        }\r\
    \n    }\r\
    \n}"
:put "Add script FWD_update for pull resources to DNS static FWD"}
:if ([:len [/system/scheduler/find comment="MihomoProxyRoS"]] = 0) do={
:do {
:put "Run script FWD_update, pls wait for DNS static entries pulled"
/system/script/run FWD_update
} on-error {}
}
:do {
/system scheduler
add interval=1d name=update_FWD on-event=FWD_update start-time=06:30:00 comment="MihomoProxyRoS"
:put "Add shedule FWD_update on 06:30 am every day"
} on-error {} 

:local flagContainer false
:while ($flagContainer = false) do={
:do {
:if ([:len [/container/mounts/find comment="MihomoProxyRoSAWG"]] = 0) do={
/container/mounts/add src=/awg_conf/ dst=/root/.config/mihomo/awg/ name=awg_conf comment="MihomoProxyRoSAWG"
}
/container/add remote-image="ghcr.io/medium1992/mihomo-proxy-ros" envlists=MihomoProxyRoS mount=awg_conf interface=MihomoProxyRoS root-dir=Containers/MihomoProxyRoS dns=192.168.255.1 start-on-boot=yes comment="MihomoProxyRoS"
:put "Start pull MihomoProxyRoS container, pls wait when container starting, pls wait"
:delay 1
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
} on-error {
:if ([:len [/container/find comment="MihomoProxyRoS" and (stopped or running)]] > 0) do={
/container/start [find where comment="MihomoProxyRoS" and stopped]
:delay 3
:if ([:len [/container/find comment="MihomoProxyRoS" and running)]] > 0) do={
:put "Container MihomoProxyRoS started"
:set $flagContainer true
}
:if ([:len [/container/find comment="MihomoProxyRoS" and stopped)]] > 0) do={
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
}

:set flagContainer false
:while ($flagContainer = false) do={
:do {
/container/add remote-image="ghcr.io/medium1992/dns-proxy-ros" interface=DNSProxy cmd="--cache --ipv6-disabled --upstream https://dns.google/dns-query --upstream https://cloudflare-dns.com/dns-query --upstream https://dns.quad9.net/dns-query --upstream-mode=parallel" root-dir=Containers/DNSProxy dns=192.168.255.9 start-on-boot=yes comment="DNSProxy"
:put "Start pull DNSProxy container, pls wait when container starting, pls wait"
:delay 1
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
} on-error {
:if ([:len [/container/find comment="DNSProxy" and (stopped or running)]] > 0) do={
/container/start [find where comment="DNSProxy" and stopped]
:delay 3
:if ([:len [/container/find comment="DNSProxy" and running)]] > 0) do={
:put "Container DNSProxy started"
:set $flagContainer true
}
:if ([:len [/container/find comment="DNSProxy" and stopped)]] > 0) do={
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
}

:set flagContainer false
:while ($flagContainer = false) do={
:do {
/container/add remote-image="registry-1.docker.io/wiktorbgu/byedpi-mikrotik" interface=ByeDPI cmd="--tlsrec 41+s --udp-fake 1 --oob 1 --udp-fake 1 --auto=torst,redirect,ssl_err --fake -1 --udp-fake 1 --auto=torst,redirect,ssl_err --disorder 1:11+sm --md5sig --udp-fake 1 --auto=torst,redirect,ssl_err --fake-sni google.com --fake-tls-mod rand --fake 1 --disorder 1:11+sm --split 1:11+sm --md5sig --udp-fake 1 --auto=torst,redirect,ssl_err --oob 1 --disorder 1 --tlsrec 1+s --split 1+s --disorder 3+s --udp-fake 1 --auto=torst,redirect,ssl_err --split 5 --oob 2 --udp-fake 1 --auto=torst,redirect,ssl_err --split 1+s --disoob 1 --udp-fake 1 --auto=torst,redirect,ssl_err --oob 1 --disorder 1 --tlsrec 1+s --split 1+s --disorder 3+s --udp-fake 1" root-dir=Containers/ByeDPI dns=192.168.255.10 start-on-boot=yes comment="ByeDPI"
:put "Start pull ByeDPI container, pls wait when container starting, pls wait"
:delay 1
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
} on-error {
:if ([:len [/container/find comment="ByeDPI" and (stopped or running)]] > 0) do={
/container/start [find where comment="ByeDPI" and stopped]
:delay 3
:if ([:len [/container/find comment="ByeDPI" and running)]] > 0) do={
:put "Container ByeDPI started"
:set $flagContainer true
}
:if ([:len [/container/find comment="ByeDPI" and stopped)]] > 0) do={
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
}

:if ([:len [/system/script/find name="changeDNS"]] = 0) do={
/system script
add name=changeDNS source=":if ([:len [/container/find comment=\"DNSProxy\" and running]] > 0 and [/ip/dns/get servers]!=192.168.255.10) d\
    o={\r\
    \n/ip dns set use-doh-server=\"\" verify-doh-cert=no\r\
    \n/ip dns set servers=\"\"\r\
    \n/ip dns set servers=192.168.255.10\r\
    \n/ip dns set cache-max-ttl=10s\r\
    \n/ip dns cache flush\r\
    \n:log warning \"change DNS server to DNSProxy\"\r\
    \n} \r\
    \n:if ([:len [/container/find comment=\"DNSProxy\" and stopped]] > 0 and [/ip/dns/get servers]=192.168.255.10) do={\r\
    \n/ip dns set servers=\"\"\r\
    \n/ip dns set servers=8.8.8.8\r\
    \n/ip dns set use-doh-server=https://dns.google/dns-query verify-doh-cert=yes\r\
    \n/ip dns set cache-max-ttl=1d\r\
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
:put "Script complete, enjoy, for use AWG pls push AWG_conf file on Mikrotik to path /awg_conf/"
:put "For donate USDT(TRC20):TWDDYD1nk5JnG6FxvEu2fyFqMCY9PcdEsJ"
:log warning "script complete, enjoy"
:log warning "For donate USDT(TRC20):TWDDYD1nk5JnG6FxvEu2fyFqMCY9PcdEsJ"
}