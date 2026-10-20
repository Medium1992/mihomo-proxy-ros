# Update scripts for DNS FWD and IP lists, their first run, schedulers.
:if ([:len [/system/script/find name="IP_MihomoProxyRoS"]] = 0) do={
/system script
add name=IP_MihomoProxyRoS source="# Define global variables\r\
\n:global AddressList \"MihomoProxyRoS\"\r\
\n\r\
\n:global LoadRscResources do={\r\
\n:foreach resource in=\$resources do={\r\
\n:local url (\$baseUrl . \"/\" . \$resource . \".rsc\")\r\
\n:do {\r\
\n:local r [/tool fetch url=\$url mode=https output=user as-value]\r\
\n:if ((\$r->\"status\") = \"finished\") do={\r\
\n:local content (\$r->\"data\")\r\
\n:local s [:parse \$content]\r\
\n\$s\r\
\n:log warning (\$resource . \".rsc loading completed\")\r\
\n:put (\$resource . \".rsc loading completed\")\r\
\n}\r\
\n} on-error={}\r\
\n:local part 1\r\
\n:local continue true\r\
\n:while (\$continue) do={\r\
\n:local partUrl (\$baseUrl . \"/\" . \$resource . \"_part\" . \$part . \".rsc\")\r\
\n:do {\r\
\n:local r [/tool fetch url=\$partUrl mode=https output=user as-value]\r\
\n:if ((\$r->\"status\") = \"finished\") do={\r\
\n:local content (\$r->\"data\")\r\
\n:local s [:parse \$content]\r\
\n\$s\r\
\n:log warning (\$resource . \".rsc part\" . \$part . \" loading completed\")\r\
\n:put (\$resource . \".rsc part\" . \$part . \" loading completed\")\r\
\n:set part (\$part + 1)\r\
\n} else={\r\
\n:set continue false\r\
\n}\r\
\n} on-error={\r\
\n:set continue false\r\
\n}\r\
\n}\r\
\n}\r\
\n}\r\
\n\r\
\n# First resources\r\
\n:local baseUrl \"https://raw.githubusercontent.com/Medium1992/MikroTik_IPlist/refs/heads/main/for_scripts\"\r\
\n:local resources {\r\
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
\n\"asnv4/AS63293\";\r\
\n\"asnv4/AS45796\";\r\
\n# NetFlix\r\
\n\"geoipv4/netflix\";\r\
\n\"asnv4/AS2906\";\r\
\n# Anthropic\r\
\n\"asnv4/AS399358\";\r\
\n\"asnv4/AS60808\";\r\
\n}\r\
\n\r\
\n\$LoadRscResources resources=\$resources baseUrl=\$baseUrl\r\
\n\r\
\n\r\
\n# Second resources\r\
\n:local baseUrl \"https://raw.githubusercontent.com/Medium1992/mihomo-proxy-ros/refs/heads/main/custom_list\"\r\
\n:local resources {\r\
\n\"ipcidr_address_list_custom\";\r\
\n}\r\
\n\r\
\n\$LoadRscResources resources=\$resources baseUrl=\$baseUrl\r\
\n"
:put "Add script IP_AddressList for pull IPs to ip firewall address-list"}

:if ([:len [/system/script/find name="FWD_update"]] = 0) do={
/system script
add name=FWD_update source="# Define global variables\r\
\n:global AddressList \"\"\r\
\n:global ForwardTo \"MihomoProxyRoS\"\r\
\n\r\
\n:global LoadRscResources do={\r\
\n:foreach resource in=\$resources do={\r\
\n:local url (\$baseUrl . \"/\" . \$resource . \".rsc\")\r\
\n:do {\r\
\n:local r [/tool fetch url=\$url mode=https output=user as-value]\r\
\n:if ((\$r->\"status\") = \"finished\") do={\r\
\n:local content (\$r->\"data\")\r\
\n:local s [:parse \$content]\r\
\n\$s\r\
\n:log warning (\$resource . \".rsc loading completed\")\r\
\n:put (\$resource . \".rsc loading completed\")\r\
\n}\r\
\n} on-error={}\r\
\n:local part 1\r\
\n:local continue true\r\
\n:while (\$continue) do={\r\
\n:local partUrl (\$baseUrl . \"/\" . \$resource . \"_part\" . \$part . \".rsc\")\r\
\n:do {\r\
\n:local r [/tool fetch url=\$partUrl mode=https output=user as-value]\r\
\n:if ((\$r->\"status\") = \"finished\") do={\r\
\n:local content (\$r->\"data\")\r\
\n:local s [:parse \$content]\r\
\n\$s\r\
\n:log warning (\$resource . \".rsc part\" . \$part . \" loading completed\")\r\
\n:put (\$resource . \".rsc part\" . \$part . \" loading completed\")\r\
\n:set part (\$part + 1)\r\
\n} else={\r\
\n:set continue false\r\
\n}\r\
\n} on-error={\r\
\n:set continue false\r\
\n}\r\
\n}\r\
\n}\r\
\n}\r\
\n\r\
\n# First resources set\r\
\n:local baseUrl \"https://raw.githubusercontent.com/Medium1992/MikroTik_DNS_FWD/refs/heads/main/for_scripts\"\r\
\n\r\
\n:local resources {\r\
\n\"youtube\";\r\
\n\"meta\";\r\
\n\"netflix\";\r\
\n\"discord\";\r\
\n\"rutracker\";\r\
\n\"torrent\";\r\
\n\"adguard\";\r\
\n\"anime\";\r\
\n\"deepl\";\r\
\n\"category-ai-!cn\";\r\
\n\"category-anticensorship\";\r\
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
\n\"anthropic\";\r\
\n\"xai\";\r\
\n\"notion\";\r\
\n\"twitch\";\r\
\n\"supercell\";\r\
\n\"xbox\";\r\
\n\"pornhub\";\r\
\n}\r\
\n\r\
\n\$LoadRscResources resources=\$resources baseUrl=\$baseUrl\r\
\n\r\
\n# Second resources\r\
\n:local baseUrl \"https://raw.githubusercontent.com/Medium1992/mihomo-proxy-ros/refs/heads/main/custom_list\"\r\
\n\r\
\n:local resources {\r\
\n\"domain_custom\";\r\
\n}\r\
\n\r\
\n\$LoadRscResources resources=\$resources baseUrl=\$baseUrl\r\
\n"
:put "Add script FWD_update for pull resources to DNS static FWD"}

:if ([:len [/system/script/find name="FWD_update_RU"]] = 0) do={
/system script
add name=FWD_update_RU source="# Define global variables\r\
\n:global AddressList \"\"\r\
\n:global ForwardTo \"Yandex\"\r\
\n\r\
\n# List of resources corresponding to RSC files\r\
\n:global resources {\r\
\n\"category-gov-ru\";\r\
\n\"category-bank-ru\";\r\
\n\"category-retail-ru\";\r\
\n\"category-travel-ru\";\r\
\n\"category-ecommerce-ru\";\r\
\n\"category-entertainment-ru\";\r\
\n\"mailru-group\";\r\
\n\"vk\";\r\
\n\"ok\";\r\
\n\"yandex\";\r\
\n\"ozon\";\r\
\n\"wildberries\";\r\
\n\"x5\";\r\
\n\"okko\";\r\
\n\"kinopoisk\";\r\
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
:put "Add script FWD_update_RU for pull resources to DNS static FWD"}

:if ([:len [/system/script/find name="route_UP"]] = 0) do={
/system script
add name=route_UP source=\
    ":global comments {\
    \n\"MihomoProxyRoS0\";\
    \n\"MihomoProxyRoS1\";\
    \n}\
    \n:foreach i in=\$comments do={\
    \n/ip/route/set [find where comment=\$i disabled=yes] disabled=no\
    \n}"
:put "Add script route_UP"}

:if ([:len [/system/scheduler/find comment="MihomoProxyRoS"]] = 0) do={
:do {
:put "Run script FWD_update_RU, pls wait for DNS static entries pulled"
/system/script/run FWD_update_RU
:put "Run script FWD_update, pls wait for DNS static entries pulled"
/system/script/run FWD_update
:put "Run script IP_MihomoProxyRoS, pls wait for IPs static entries pulled"
/system/script/run IP_MihomoProxyRoS
} on-error {}
}
:do {
/system scheduler
add interval=1d name=update_FWD start-time=06:30:00 comment="MihomoProxyRoS" on-event="/system/script/run FWD_update_RU\r\
\n/system/script/run FWD_update\r\
\n/system/script/run IP_MihomoProxyRoS"
:put "Add schedule update resources on 06:30 AM every day"
/system scheduler
add interval=10s name=route_UP comment="route_UP" on-event="/system/script/run route_UP"
} on-error {} 
