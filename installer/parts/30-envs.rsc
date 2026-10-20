# Container envs, FakeIP route, DNS address list.
:global MPRminor
:global MPRlink
:global MPRsublink
:global MPRapple
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
:do {add key=SNIFFER_SKIP_DST_ADDRESS list=MihomoProxyRoS value="rule-set:Telegram_geoip_telegram,rule-set:META_geoip_facebook,109.239.140.0/24,194.221.250.50/32"
:put "Add env SNIFFER_SKIP_DST_ADDRESS value: rule-set:Telegram_geoip_telegram,rule-set:META_geoip_facebook,109.239.140.0/24,194.221.250.50/32"} on-error {}
:do {add key=BYEDPI_CMD list=MihomoProxyRoS value="-Ku -a1 -An -d1 -s1+s -d3+s -s6+s -d9+s -s12+s -d15+s -s20+s -d25+s -s30+s -d35+s -At,r,s -s1 -q1 -At,r,s -s5 -o2 -At,r,s -o1 -d1 -r1+s -s1+s -d3+s -At,r,s -f-1 -r1+s -At,r,s -s1 -o1+s -s-1"
:put "Add env BYEDPI_CMD"} on-error {}
:if ($MPRminor >= 21 and (([/system/resource/get architecture-name] = "arm64") or ([/system/resource/get architecture-name] = "x86_64"))) do={
:do {add key=ZAPRET_CMD list=MihomoProxyRoS value=""
:put "Add env ZAPRET_CMD"} on-error {}
:do {add key=ZAPRET2_CMD list=MihomoProxyRoS value=""
:put "Add env ZAPRET2_CMD"} on-error {}
}
:local groups "YouTube,Telegram,Discord,META,SuperCell,AI,Twitch"
:if ($MPRapple) do={:set groups ($groups . ",Apple")}
:do { add key=GROUP list=MihomoProxyRoS value=$groups
:put "Add env GROUP value: $groups"} on-error {
# GROUP is already there: keep it as the operator left it, only add Apple
:if ($MPRapple) do={
:local cur [get [find where key=GROUP and list=MihomoProxyRoS] value]
:if ([:typeof [:find ("," . $cur . ",") ",Apple,"]] = "nil") do={
:if ([:len $cur] > 0) do={:set cur ($cur . ",Apple")} else={:set cur "Apple"}
set [find where key=GROUP and list=MihomoProxyRoS] value=$cur
:put "Add Apple to env GROUP: $cur"
}
}
}
:if ($MPRapple) do={
:do { add key=APPLE_GEOSITE list=MihomoProxyRoS value=apple
:put "Add env APPLE_GEOSITE value: apple"} on-error {}
:do { add key=APPLE_GEOIP list=MihomoProxyRoS value="https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo-lite/geoip/apple.mrs"
:put "Add env APPLE_GEOIP value: geo-lite geoip apple.mrs"} on-error {}
}
:do { add key=YOUTUBE_GEOSITE list=MihomoProxyRoS value=youtube
:put "Add env YOUTUBE_GEOSITE value: youtube"} on-error {}
:do { add key=TELEGRAM_GEOSITE list=MihomoProxyRoS value=telegram
:put "Add env TELEGRAM_GEOSITE value: telegram"} on-error {}
:do { add key=TELEGRAM_GEOIP list=MihomoProxyRoS value=telegram
:put "Add env TELEGRAM_GEOIP value: telegram"} on-error {}
:do { add key=TELEGRAM_AS list=MihomoProxyRoS value=AS62041,AS59930,AS62014,AS211157,AS44907
:put "Add env TELEGRAM_AS value: AS62041,AS59930,AS62014,AS211157,AS44907"} on-error {}
:do { add key=TELEGRAM_IPCIDR list=MihomoProxyRoS value=109.239.140.0/24,194.221.250.50/32
:put "Add env TELEGRAM_IPCIDR value: 109.239.140.0/24,194.221.250.50/32"} on-error {}
:do { add key=DISCORD_GEOSITE list=MihomoProxyRoS value=discord
:put "Add env DISCORD_GEOSITE value: discord"} on-error {}
:do { add key=DISCORD_GEOIP list=MihomoProxyRoS value=discord
:put "Add env DISCORD_GEOIP value: discord"} on-error {}
:do { add key=META_GEOSITE list=MihomoProxyRoS value=meta
:put "Add env META_GEOSITE value: meta"} on-error {}
:do { add key=META_GEOIP list=MihomoProxyRoS value=facebook
:put "Add env META_GEOIP value: facebook"} on-error {}
:do { add key=META_AS list=MihomoProxyRoS value=AS32934,AS54115,AS63293
:put "Add env META_AS value: AS32934,AS54115,AS63293"} on-error {}
:do { add key=META_IPCIDR list=MihomoProxyRoS value=41.189.185.0/24,202.59.209.0/24,223.27.200.0/24,223.27.237.0/24
:put "Add env META_IPCIDR value: 41.189.185.0/24,202.59.209.0/24,223.27.200.0/24,223.27.237.0/24"} on-error {}
:do { add key=SUPERCELL_GEOSITE list=MihomoProxyRoS value=supercell
:put "Add env SUPERCELL_GEOSITE value: supercell"} on-error {}
:do { add key=AI_GEOSITE list=MihomoProxyRoS value=category-ai-!cn,openai,google-gemini,anthropic
:put "Add env AI_GEOSITE value: category-ai-!cn,openai,google-gemini,anthropic"} on-error {}
:do { add key=AI_AS list=MihomoProxyRoS value=AS399358,AS60808
:put "Add env AI_AS value: AS399358,AS60808"} on-error {}
:do { add key=AI_IPCIDR list=MihomoProxyRoS value=216.73.216.0/22
:put "Add env AI_IPCIDR value: 216.73.216.0/22"} on-error {}
:do { add key=TWITCH_GEOSITE list=MihomoProxyRoS value=twitch
:put "Add env TWITCH_GEOSITE value: twitch"} on-error {}
:do { add key=RULES1 list=MihomoProxyRoS value="AND,((NETWORK,udp),(DST-PORT,443)),REJECT"
:put "Add env RULES1 value: AND,((NETWORK,udp),(DST-PORT,443)),REJECT"} on-error {}
:do {
add key=LINK1 list=MihomoProxyRoS value=$MPRlink
:put "Add env LINK1 value: $MPRlink"
} on-error {
:if ($MPRlink != [/container/envs/get [find key=LINK1 list=MihomoProxyRoS] value]) do={
set [find where key=LINK1 list=MihomoProxyRoS] value=$MPRlink
:put "Set env LINK1 new value: $MPRlink"
}
}
:do {
add key=SUB_LINK1 list=MihomoProxyRoS value=$MPRsublink
:put "Add env SUBLINK1 value: $MPRsublink"
} on-error {
:if ($MPRsublink != [/container/envs/get [find key=SUB_LINK1 list=MihomoProxyRoS] value]) do={
set [find where key=SUB_LINK1 list=MihomoProxyRoS] value=$MPRsublink
:put "Set env SUBLINK1 new value: $MPRsublink"
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
