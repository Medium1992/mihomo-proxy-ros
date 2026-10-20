# Mount lists, container, start. privileged= only exists on 7.24+, so the
# add command is built at run time.
:global MPRminor
:global MPRpathPull
:local totalspace [/system/resource/get total-hdd-space]
:local priv ""
:if ($MPRminor >= 24) do={:set priv " privileged=yes"}
:local add [:parse ("/container/add remote-image=\"ghcr.io/medium1992/mihomo-proxy-ros\"" . $priv . " envlists=MihomoProxyRoS mountlists=MihomoProxyRoS interface=MihomoProxyRoS root-dir=\"" . $MPRpathPull . "Containers/MihomoProxyRoS\" start-on-boot=yes comment=\"MihomoProxyRoS\"")]
:local flagContainer false
:while ($flagContainer = false) do={
:if ($totalspace>=120000000) do={
:if ([:len [/container/mounts/find comment="MihomoProxyRoS"]] = 0) do={
:do { /file/add name=mihomo type=directory} on-error {}
/container/mounts/add src=/mihomo/ dst=/root/.config/mihomo/ list=MihomoProxyRoS comment="MihomoProxyRoS"
}
} else={
:if ([:len [/container/mounts/find comment="MihomoProxyRoSAWG"]] = 0) do={
:do { /file/add name=awg_conf type=directory} on-error {}
/container/mounts/add src=/awg_conf/ dst=/root/.config/mihomo/awg/ list=MihomoProxyRoS comment="MihomoProxyRoSAWG"
}
:if ([:len [/container/mounts/find comment="MihomoProxyRoSProxies"]] = 0) do={
:do { /file/add name=proxies_yaml type=directory} on-error {}
/container/mounts/add src=/proxies_yaml/ dst=/root/.config/mihomo/proxies_mount/ list=MihomoProxyRoS comment="MihomoProxyRoSProxies"
}
:if ([:len [/container/mounts/find comment="MihomoProxyRoSRuleSet"]] = 0) do={
:do { /file/add name=ruleset_txt type=directory} on-error {}
/container/mounts/add src=/ruleset_txt/ dst=/root/.config/mihomo/rule_set_list list=MihomoProxyRoS comment="MihomoProxyRoSRuleSet"
}
}
:if ([:len [/container/find comment="MihomoProxyRoS"]] = 0) do={
$add
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
