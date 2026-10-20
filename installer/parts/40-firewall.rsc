# Mangle rules, DNS statics, address lists.
/ip firewall mangle
:if ([:len [find comment="YT_MSS"]] = 0) do={add action=change-mss chain=forward dst-address-list=YT in-interface=MihomoProxyRoS new-mss=88 protocol=tcp tcp-flags=syn connection-state=new comment="YT_MSS"; :put "Add mangle rule YT_MSS"}
:if ([:len [find comment="Accept_no_mark"]] = 0) do={add action=accept chain=prerouting connection-mark=no-mark connection-state=established comment="Accept_no_mark"; :put "Add mangle rule 1"}
:if ([:len [find comment="AcceptInWAN&Containers"]] = 0) do={add action=accept chain=prerouting in-interface-list=InAccept comment="AcceptInWAN&Containers"; :put "Add mangle rule 2"}
:if ([:len [find comment="RoutingToMihomo2"]] = 0) do={add action=mark-routing chain=prerouting in-interface-list=LAN connection-mark=MihomoProxyRoS new-routing-mark=MihomoProxyRoS passthrough=no comment="RoutingToMihomo2"; :put "Add mangle rule 3"}
:if ([:len [find comment="MarkConnAddressList"]] = 0) do={add action=mark-connection chain=prerouting in-interface-list=LAN connection-mark=no-mark connection-state=new dst-address-list=MihomoProxyRoS new-connection-mark=MihomoProxyRoS comment="MarkConnAddressList"; :put "Add mangle rule 4"}
:if ([:len [find comment="Discord_RTC"]] = 0) do={add action=mark-connection chain=prerouting connection-bytes=102 connection-mark=no-mark connection-state=new content="\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00" dst-address-type=!local in-interface-list=LAN new-connection-mark=MihomoProxyRoS dst-port=19294-19344,50000-50100 protocol=udp comment="Discord_RTC"; :put "Add mangle rule 5"}
:if ([:len [find comment="Discord_WebRTC"]] = 0) do={add action=mark-connection chain=prerouting connection-bytes=128 connection-mark=no-mark connection-state=new content="\12\A4\42" dst-address-type=!local in-interface-list=LAN new-connection-mark=MihomoProxyRoS dst-port=19294-19344,50000-50100 protocol=udp comment="Discord_WebRTC"; :put "Add mangle rule 6"}
:if ([:len [find comment="RoutingToMihomo1"]] = 0) do={add action=mark-routing chain=prerouting in-interface-list=LAN connection-mark=MihomoProxyRoS new-routing-mark=MihomoProxyRoS passthrough=no comment="RoutingToMihomo1"; :put "Add mangle rule 7"}

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
