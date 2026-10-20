# Free space check, prompts, RAM disk for temp files, pull slot, links.
:global MPRminor
:global MPRstop
:global MPRpathPull
:global MPRlink
:global MPRsublink
:local freespace [/system/resource/get free-hdd-space]
:if ($freespace<80914560 and ([:len [/container/find comment="MihomoProxyRoS"]] = 0) and ([:len [[/disk/find where fs=ext4 free>80914560]]] = 0)) do={
:put "Low free space on storage(s), script exit"
:set MPRstop true
} else={
# defconf turns on auto-smb-sharing: without this the ContainerTemp disk below
# would show up on the network as an SMB share.
:do {/disk/settings/set auto-smb-sharing=no auto-media-sharing=no auto-media-interface=none} on-error={}

:local TempContainer
:local flagTempContainer false
:while ($flagTempContainer=false) do={
:put "Would you like to create a RAM disk for container temporary files?"
:put "- yes"
:put "- no"
:set TempContainer [/terminal ask]
:if ($TempContainer="yes") do={
/disk/add type=tmpfs slot=ContainerTemp
/container/config/set tmpdir=ContainerTemp/
:set flagTempContainer true
}
:if ($TempContainer="no") do={
:set flagTempContainer true
}
}

:set MPRpathPull ""
:if (([:len [/container/find comment="MihomoProxyRoS"]] = 0) or (([:len [/container/find comment="DNSProxy"]] = 0) and $dnsproxy=true)) do={
:local slotArray 
:if ($freespace>=80914560) do={:set slotArray ($slotArray, "system")}
:local flagDisks false
:local slotDisk 
:local selectSlot 
foreach i in=[/disk/find where fs=ext4 free>80914560] do={
:set slotArray ($slotArray, [/disk/get $i value-name=slot]);
}
foreach i in=[/disk/find where fs=btrfs free>80914560] do={
:set slotArray ($slotArray, [/disk/get $i value-name=slot]);
}
foreach i in=[/disk/find where fs=tmpfs free>80914560] do={
:set slotArray ($slotArray, [/disk/get $i value-name=slot]);
}
:while ($flagDisks=false) do={
:put "Enter the name of the disk slot to which you want to pull the containers. Possible options slot:"
foreach i in=$slotArray do={:put "- $i"}
:set slotDisk [/terminal ask]
foreach i in=$slotArray do={
:if ($i=$slotDisk) do={
:set selectSlot $i
:if ($selectSlot!="system") do={:set MPRpathPull "$selectSlot/"}
:put "The slot $selectSlot selected for pulling Containers, path pulling $MPRpathPull"
:if ($MPRminor >= 21) do={
:if ([:len [/disk/find where slot=$selectSlot fs=tmpfs]] > 0) do={
:local repullSource (":delay 30s\r\n:local c [/container/find where comment=\"MihomoProxyRoS\"]\r\n:if ([:len \$c] > 0) do={\r\n/container/repull \$c\r\n:delay 5s\r\n:local i 0\r\n:while (([:len [/container/find where comment=\"MihomoProxyRoS\" and running]] = 0) and (\$i < 200)) do={\r\n:if ([:len [/container/find where comment=\"MihomoProxyRoS\" and (stopped or running)]] > 0) do={\r\n/container/start [/container/find where comment=\"MihomoProxyRoS\" and stopped]\r\n}\r\n:delay 3s\r\n:set i (\$i + 1)\r\n}\r\n:if ([:len [/container/find where comment=\"MihomoProxyRoS\" and running]] > 0) do={:log info \"MihomoProxyRoS started after repull\"} else={:log warning \"MihomoProxyRoS did not start after repull\"}\r\n}")
:if ([:len [/system/script/find where name="MihomoProxyRoS_repull"]] = 0) do={/system/script/add name=MihomoProxyRoS_repull source=$repullSource} else={/system/script/set [find where name="MihomoProxyRoS_repull"] source=$repullSource}
:if ([:len [/system/scheduler/find where name="MihomoProxyRoS_repull"]] = 0) do={/system/scheduler/add name=MihomoProxyRoS_repull start-time=startup on-event="/system/script/run MihomoProxyRoS_repull"} else={/system/scheduler/set [find where name="MihomoProxyRoS_repull"] start-time=startup on-event="/system/script/run MihomoProxyRoS_repull"}
} else={
/system/script/remove [find where name="MihomoProxyRoS_repull"]
/system/scheduler/remove [find where name="MihomoProxyRoS_repull"]
}
}
:set flagDisks true
}}}}

:local defaultLINK
:do {
:set defaultLINK [/container/envs/get [find key=LINK1 list=MihomoProxyRoS] value]
} on-error {
:set defaultLINK " "
}
:put "Please enter a valid link vless://... or vmess://... or ss://... or trojan://... Press Enter to skip and hold current value: $defaultLINK"
:set MPRlink [/terminal ask]
:if ([:len $MPRlink] = 0) do={
:set MPRlink $defaultLINK
}

:local defaultSUBLINK
:do {
:set defaultSUBLINK [/container/envs/get [find key=SUB_LINK1 list=MihomoProxyRoS] value]
} on-error {
:set defaultSUBLINK " "
}
:put "Enter sublink http(s)://... URL. Press Enter to skip and hold current value: $defaultSUBLINK"
:set MPRsublink [/terminal ask]
:if ([:len $MPRsublink] = 0) do={
:set MPRsublink $defaultSUBLINK
}
}
