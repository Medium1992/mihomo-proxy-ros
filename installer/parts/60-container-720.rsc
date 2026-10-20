# RouterOS 7.20: named mounts, container, start.
:global MPRpathPull
:local flagContainer false
:while ($flagContainer = false) do={
:if ([:len [/container/mounts/find comment="MihomoProxyRoSAWG"]] = 0) do={
:do { /file/add name=awg_conf type=directory} on-error {}
/container/mounts/add src=/awg_conf/ dst=/root/.config/mihomo/awg/ name=awg_conf comment="MihomoProxyRoSAWG"
}
:if ([:len [/container/mounts/find comment="MihomoProxyRoSProxies"]] = 0) do={
:do { /file/add name=proxies_yaml type=directory} on-error {}
/container/mounts/add src=/proxies_yaml/ dst=/root/.config/mihomo/proxies_mount/ name=proxies_yaml comment="MihomoProxyRoSProxies"
}
:if ([:len [/container/mounts/find comment="MihomoProxyRoSRuleSet"]] = 0) do={
:do { /file/add name=ruleset_txt type=directory} on-error {}
/container/mounts/add src=/ruleset_txt/ dst=/root/.config/mihomo/rule_set_list/ name=ruleset_txt comment="MihomoProxyRoSRuleSet"
}
:if ([:len [/container/find comment="MihomoProxyRoS"]] = 0) do={
/container/add remote-image="ghcr.io/medium1992/mihomo-proxy-ros" envlists=MihomoProxyRoS mounts=awg_conf,proxies_yaml,ruleset_txt interface=MihomoProxyRoS root-dir=($MPRpathPull . "Containers/MihomoProxyRoS") start-on-boot=yes comment="MihomoProxyRoS"
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
