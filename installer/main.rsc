# MihomoProxyRoS installer: asks whether to install or remove.
# Fetches every part of the chosen action into RAM, checks all of them and
# only then runs them: a part that fails to download, or that RouterOS
# rejects, stops before anything on the router is touched. Nothing is
# written to the disk.
#
# One line per part: {from RouterOS 7.x; to 7.x; file under installer/}.
# A command that exists only on some versions (unknown commands and values
# reject the whole script) goes to its own part here, or into a string that a
# shared part :parse-s at run time only on the versions that have it.
:local installParts {
{20;99;"parts/00-start.rsc"};
{20;99;"parts/10-network.rsc"};
{21;99;"parts/20-whatsapp.rsc"};
{20;99;"parts/30-envs.rsc"};
{20;99;"parts/40-firewall.rsc"};
{20;99;"parts/50-scripts.rsc"};
{20;20;"parts/60-container-720.rsc"};
{21;99;"parts/60-container.rsc"};
{20;99;"parts/90-finish.rsc"};
}
:local removeParts {
{20;99;"uninstall.rsc"};
}
:local base "https://raw.githubusercontent.com/Medium1992/mihomo-proxy-ros/refs/heads/main/installer/"

# Shared state of the parts lives in MPR* globals, removed at the end.
:global MPRminor
:global MPRstop false
:local ver [/system/resource/get version]
:set MPRminor [:tonum [:pick $ver ([:find $ver "."] + 1) ([:find $ver "."] + 3)]]
:if ([:typeof $MPRminor] != "num" or $MPRminor < 20) do={
:put "RouterOS $ver is not supported, update to at least RouterOS 7.20"
:set MPRstop true
}

:local parts [:toarray ""]
:if (!$MPRstop) do={
:local choice ""
:while ($choice != "1" and $choice != "2" and $choice != "3") do={
:put "MihomoProxyRoS, RouterOS 7.$MPRminor"
:put " 1) install or update"
:put " 2) remove"
:put " 3) quit"
:set choice [/terminal ask]
}
:if ($choice = "1") do={:set parts $installParts}
:if ($choice = "2") do={:set parts $removeParts}
:if ($choice = "3") do={:set MPRstop true}
}

# 1. download
:local names [:toarray ""]
:local codes [:toarray ""]
:if (!$MPRstop) do={
:foreach p in=$parts do={
:if (!$MPRstop and $MPRminor >= ($p->0) and $MPRminor <= ($p->1)) do={
:local file ($p->2)
:local data ""
:local try 0
:while ([:len $data] = 0 and $try < 3) do={
:set try ($try + 1)
:do {
:local r [/tool fetch url=($base . $file) mode=https output=user as-value]
:if (($r->"status") = "finished") do={:set data ($r->"data")}
} on-error={:delay 2s}
}
:if ([:len $data] > 0) do={
:set names ($names, $file)
:set codes ($codes, $data)
:put "Loaded $file"
} else={
:put "Failed to download $file, script exit"
:log error "MihomoProxyRoS installer: failed to download $file"
:set MPRstop true
}
}
}
}

# 2. check every part without running it. :parse does not check anything:
# RouterOS checks a script when it starts, and an unknown command or a bad
# value rejects all of it before its first line runs. So each part is started
# with an :error in front: a good part stops on that line, a broken one fails
# with its own error, and nothing in it runs either way.
:if (!$MPRstop) do={
:foreach i,data in=$codes do={
:if (!$MPRstop) do={
:onerror e in={
:local s [:parse (":error \"MPRcheck\"\n" . $data)]
$s
} do={
:if (!($e ~ "^MPRcheck")) do={
:put ("Part " . ($names->$i) . " is rejected by RouterOS 7.$MPRminor: $e, script exit")
:log error ("MihomoProxyRoS installer: " . ($names->$i) . " rejected: $e")
:set MPRstop true
}
}
}
}
}

# 3. run the parts in order, each as its own script
:if (!$MPRstop) do={
:put "Ready: $[:len $codes] part(s) for RouterOS 7.$MPRminor"
:foreach i,data in=$codes do={
:if (!$MPRstop) do={
:onerror e in={
:local s [:parse $data]
$s
} do={
:put ("Error in " . ($names->$i) . ": $e, script exit")
:log error ("MihomoProxyRoS installer: error in " . ($names->$i) . ": $e")
:set MPRstop true
}
}
}
}

/system/script/environment/remove [find where name~"^MPR"]
