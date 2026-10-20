# WhatsApp rules for the container envs.
:global whatsappRules
:set whatsappRules [/tool fetch url=https://raw.githubusercontent.com/Medium1992/mihomo-proxy-ros/refs/heads/main/custom_list/add_env_WA.rsc mode=https output=user as-value]
:if (($whatsappRules->"status")="finished") do={
:global contentWhatsappRules ($whatsappRules->"data")
:if ([:len $contentWhatsappRules] > 0) do={
:global WARules [:parse $contentWhatsappRules]
:log warning "script loading WARules completed and added"
:put "script loading WARules completed and added"
$WARules
}
}
