# MihomoProxyRoS uninstaller: removes what the installer and its update scripts
# added (container, envs, mounts, veth, routes, mangle, DNS FWD entries,
# address lists, scripts, schedulers). Router-wide settings the installer
# changed (IPv6, DNS and NTP settings, certificate store, fasttrack, blackhole
# routes in main, the Google/CloudFlare/Quad9/XBOX/Yandex forwarders) and the
# GitHub NAT rules of the install snippet stay.
:local answer
:put "Remove MihomoProxyRoS from this router? Type yes to continue"
:set answer [/terminal ask]
:if ($answer != "yes") do={
:put "Nothing removed"
} else={

# schedulers and scripts first, so nothing re-adds entries while we remove them
/system/scheduler/remove [find where name="update_FWD" or name="route_UP" or name="MihomoProxyRoS_repull"]
/system/script/remove [find where name="IP_MihomoProxyRoS" or name="FWD_update" or name="FWD_update_RU" or name="route_UP" or name="MihomoProxyRoS_repull"]
:put "Removed update scripts and schedulers"

# container
:local c [/container/find where comment="MihomoProxyRoS"]
:if ([:len $c] > 0) do={
:do {/container/stop $c} on-error={}
:local i 0
:while (([:len [/container/find where comment="MihomoProxyRoS" and !stopped]] > 0) and ($i < 60)) do={
:delay 1
:set i ($i + 1)
}
/container/remove [find where comment="MihomoProxyRoS"]
:put "Removed container MihomoProxyRoS"
}
:local i 0
:while (([:len [/container/find where comment="MihomoProxyRoS"]] > 0) and ($i < 60)) do={
:delay 1
:set i ($i + 1)
}
/container/mounts/remove [find where comment~"^MihomoProxyRoS"]
/container/envs/remove [find where list="MihomoProxyRoS"]
:put "Removed container mounts and envs"

:local keep
:put "Delete the folders with your configs (mihomo, awg_conf, proxies_yaml, ruleset_txt)? yes/no"
:set keep [/terminal ask]
:if ($keep = "yes") do={
:foreach d in={"mihomo";"awg_conf";"proxies_yaml";"ruleset_txt"} do={
:do {/file/remove [find where name=$d]} on-error={}
}
:put "Deleted config folders"
}

# RAM disk for temp files, only when no container is left to use it
:if ([:len [/container/find]] = 0) do={
:if ([/container/config/get tmpdir] = "ContainerTemp/") do={
/container/config/set tmpdir=""
}
:do {/disk/remove [find where slot="ContainerTemp" and fs=tmpfs]} on-error={}
}

# DNS: FWD entries of the update scripts, the panel and the installer
/ip/dns/static/remove [find where type=FWD and (forward-to="MihomoProxyRoS" or forward-to="Yandex")]
/ip/dns/static/remove [find where type=NXDOMAIN and (name="mask.icloud.com" or name="mask-h2.icloud.com" or name="doh.dns.apple.com" or name="dns.apple.com")]
/ip/dns/static/remove [find where comment="NTCParty"]
/ip/dns/forwarders/remove [find where name="MihomoProxyRoS"]
:put "Removed DNS FWD entries and the MihomoProxyRoS forwarder"

# address lists
/ip/firewall/address-list/remove [find where list="MihomoProxyRoS" and !dynamic]
/ip/firewall/address-list/remove [find where list="YT" and comment="YT_MSS"]
:foreach a in={"1.1.1.1";"9.9.9.9";"149.112.112.112";"104.16.248.249";"104.16.249.249";"8.8.8.8";"8.8.4.4"} do={
/ip/firewall/address-list/remove [find where list="DNS" and address=$a]
}
:put "Removed address lists"

# mangle
/ip/firewall/mangle/remove [find where comment="YT_MSS" or comment="Accept_no_mark" or comment="AcceptInWAN&Containers" or comment="RoutingToMihomo1" or comment="RoutingToMihomo2" or comment="MarkConnAddressList" or comment="Discord_RTC" or comment="Discord_WebRTC"]
:put "Removed mangle rules"

# routes and routing table
/ip/route/remove [find where comment="MihomoProxyRoS0" or comment="MihomoProxyRoS1"]
/ip/route/remove [find where routing-table="MihomoProxyRoS"]
/routing/table/remove [find where comment="MihomoProxyRoS"]
:put "Removed routes and routing table MihomoProxyRoS"

# veth and interface lists
/ip/address/remove [find where interface="MihomoProxyRoS"]
/interface/list/member/remove [find where interface="MihomoProxyRoS"]
:if ([:len [/interface/list/member/find where list="InAccept"]] = 0) do={
/interface/list/remove [find where name="InAccept"]
}
:if ([:len [/interface/list/member/find where list="Containers"]] = 0) do={
/interface/list/remove [find where name="Containers"]
}
/interface/veth/remove [find where name="MihomoProxyRoS"]
:put "Removed veth MihomoProxyRoS and its interface lists"

:put "MihomoProxyRoS removed"
:log warning "MihomoProxyRoS removed"
}
