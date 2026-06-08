# xray2mihomo converter — jq port of worker src/converter.js
# Input: parsed Xray subscription JSON. Arg $fmt = uri|base64|yaml. Output: raw text.

def tv($x): ($x != null) and ($x != false) and ($x != "");
def trim: if . == null then "" else (tostring | sub("^[ \t\r\n]+"; "") | sub("[ \t\r\n]+$"; "")) end;
def lc: ascii_downcase;
def firstNE($a): ($a | map(trim) | map(select(. != "")) | .[0]) // "";

# encodeURIComponent
def encComp:
  (tostring | @uri)
  | gsub("%21"; "!") | gsub("%2A"; "*") | gsub("%27"; "'") | gsub("%28"; "(") | gsub("%29"; ")");
# URLSearchParams value/key serialization (application/x-www-form-urlencoded)
def formEnc:
  (tostring | @uri)
  | gsub("%20"; "+") | gsub("%2A"; "*") | gsub("~"; "%7E");

# ---- ordered query params (array of {k,v}); param() skips null/empty ----
def pset($k; $v):
  if ($v == null or ($v | tostring) == "") then .
  else
    ($v | tostring) as $vs
    | (map(.k) | index($k)) as $i
    | if $i == null then . + [{k: $k, v: $vs}]
      else .[0:$i] + [{k: $k, v: $vs}] + .[$i+1:] end
  end;
def phas($k): (map(.k) | index($k)) != null;
def pstr: map((.k | formEnc) + "=" + (.v | formEnc)) | join("&");
# Mimic JS String() coercion (the worker stringifies query values this way,
# so an object value lands as the literal "[object Object]").
def jsStr($v):
  if $v == null then null
  elif ($v | type) == "object" then "[object Object]"
  elif ($v | type) == "array" then ($v | map(tostring) | join(","))
  else ($v | tostring) end;

def hostPort($host; $port):
  ($host | tostring) as $h
  | (if ($h | test(":")) and (($h | startswith("[")) | not) then "[" + $h + "]" else $h end)
    + ":" + (if $port == null then "" else ($port | tostring) end);

def sameText($a; $b): ($a | trim | lc) == ($b | trim | lc);
def tagOf($fallback):
  . as $ob
  | firstNE([$ob.remarks, $ob.remark, $ob.ps, $ob.name]) as $remark
  | firstNE([$ob.tag]) as $otag
  | if ($remark != "" and $otag != "" and (sameText($remark; $otag) | not)) then ($remark + " " + $otag)
    elif ($remark != "") then $remark
    elif ($otag != "") then $otag
    else $fallback end;

# ---------- protocol inference / normalize ----------
def inferProtocol:
  . as $ob
  | (firstNE([$ob.protocol, $ob.type]) | lc) as $p
  | if $p != "" then $p
    else
      (firstNE([$ob.tag, $ob.ps, $ob.remark, $ob.remarks, $ob.name]) | lc) as $label
      | ($ob.settings // {}) as $s
      | (($ob.streamSettings // {}).security // "" | tostring | lc) as $sec
      | if ($label | test("vless")) then "vless"
        elif ($label | test("vmess")) then "vmess"
        elif ($label | test("trojan")) then "trojan"
        elif ($label | test("hysteria2|hy2")) then "hysteria2"
        elif ($label | test("shadowsocks")) or ($label | test("(^|[^a-z])ss([^a-z]|$)")) then "shadowsocks"
        elif ($s.vnext) then
          (($s.vnext[0].users[0]) // {}) as $u
          | if ($u.encryption == "none" or tv($u.flow) or $sec == "reality") then "vless" else "vmess" end
        elif ($s.servers) then
          (($s.servers[0]) // {}) as $srv
          | if tv($srv.method) then "shadowsocks" elif tv($srv.password) then "trojan" else "" end
        elif (tv($s.id) and ($s.encryption == "none" or tv($s.flow) or $sec == "reality")) then "vless"
        elif tv($s.id) then "vmess"
        elif (tv($s.method) and tv($s.password)) then "shadowsocks"
        elif (tv($s.password) or tv($s.auth)) then "trojan"
        else "" end
    end;

def normOB:
  . as $ob
  | ($ob + {settings: ($ob.settings // {}), streamSettings: ($ob.streamSettings // $ob.stream // {})})
  | .protocol = inferProtocol;

def vnext($settings):
  (($settings.vnext[0]) // $settings // {}) as $v
  | (($v.users[0]) // ($settings.users[0]) // $settings // {}) as $u
  | {v: $v, u: $u};

# ---------- findOutbounds ----------
def looksLikeOutbound:
  (type == "object") and (
    (has("protocol") or has("settings") or has("streamSettings"))
    or (has("vnext") or has("servers") or has("address") or has("server") or has("id") or has("password") or has("method"))
  );
def localRemark: firstNE([.remarks, .remark]);

def findOB($inside; $inh):
  if type == "array" then
    ( . as $arr | range(0; length) as $i | $arr[$i]
      | ( if ($inside and (. | looksLikeOutbound)) then {ob: ., remark: $inh} else empty end ),
        findOB(false; $inh) )
  elif type == "object" then
    (localRemark) as $lr | (if $lr == "" then $inh else $lr end) as $rem
    | ( if ($inside and looksLikeOutbound) then {ob: ., remark: $rem} else empty end ),
      ( to_entries[] |
        if .key == "outbounds" then (.value | findOB(true; $rem))
        elif .key == "outbound" then
          ( (.value | if looksLikeOutbound then {ob: ., remark: $rem} else empty end),
            (.value | findOB(false; $rem)) )
        else (.value | findOB(false; $rem)) end )
  else empty end;

def gatherOutbounds:
  [ (if type == "array" then findOB(true; "") else findOB(false; "") end) ]
  | map(
      .remark as $rem | .ob
      | (if ($rem != "" and (firstNE([.remarks, .remark]) == "")) then (.remarks = $rem) else . end)
      | normOB
    )
  | map(select(looksLikeOutbound))
  # dedupe by full normalized JSON (sorted keys), preserving order
  | reduce .[] as $x ({seen: {}, out: []};
      ($x | walk(if type == "object" then to_entries | sort_by(.key) | from_entries else . end) | tojson) as $k
      | if .seen[$k] then . else {seen: (.seen + {($k): true}), out: (.out + [$x])} end)
  | .out;

# ---------- streamParams (for URIs) ----------
def streamParams($stream):
  ($stream // {}) as $s
  | ($s.network // "tcp") as $net
  | ($s.security // "") as $sec
  | ($s.tlsSettings // {}) as $tls
  | ($s.realitySettings // {}) as $reality
  | ($reality.settings // {}) as $ri
  | ($s.wsSettings // {}) as $ws
  | ($s.httpSettings // {}) as $http
  | ($s.httpupgradeSettings // {}) as $httpup
  | ($s.xhttpSettings // $s.splithttpSettings // {}) as $xhttp
  | ($s.grpcSettings // {}) as $grpc
  | ($s.kcpSettings // {}) as $kcp
  | ($s.tcpSettings // {}) as $tcp
  | pset("type"; $net)
  | (if ($sec != "" and $sec != "none") then pset("security"; $sec) else . end)
  | pset("sni"; ($tls.serverName // $reality.serverName // (if ($reality.serverNames | type) == "array" then $reality.serverNames[0] else $reality.serverNames end)))
  | pset("fp"; ($tls.fingerprint // $reality.fingerprint // $ri.fingerprint))
  | pset("alpn"; (if ($tls.alpn | type) == "array" then ($tls.alpn | join(",")) else $tls.alpn end))
  | pset("pbk"; ($reality.publicKey // $reality.public_key // $reality.password // $ri.publicKey // $ri.public_key // $ri.password))
  | pset("sid"; ($reality.shortId // $reality.short_id // (if ($reality.shortIds | type) == "array" then $reality.shortIds[0] else $reality.shortIds end)))
  | pset("spx"; $reality.spiderX)
  | pset("path"; ($ws.path // $http.path // $httpup.path // $xhttp.path))
  | pset("host"; (($ws.headers.Host // $ws.headers.host) // ($httpup.headers.Host // $httpup.headers.host) // ($xhttp.headers.Host // $xhttp.headers.host) // $xhttp.host))
  | pset("mode"; $xhttp.mode)
  | pset("x_padding_bytes"; jsStr($xhttp.xPaddingBytes // $xhttp.x_padding_bytes))
  # xhttp `extra` is carried in standard Xray share links as a single JSON param.
  # The worker drops it in URIs; we round-trip it (object -> compact JSON, string as-is).
  | ($xhttp.extra) as $ex
  | (if (($ex | type) == "object") and (($ex | length) > 0) then pset("extra"; ($ex | tojson))
     elif (($ex | type) == "string") and ($ex != "") then pset("extra"; $ex)
     else . end)
  | pset("serviceName"; $grpc.serviceName)
  | pset("seed"; $kcp.seed)
  | (if tv($kcp.header.type) then pset("headerType"; $kcp.header.type) else . end)
  | (if tv($tcp.header.request.headers.Host) then pset("host"; (if ($tcp.header.request.headers.Host | type) == "array" then ($tcp.header.request.headers.Host | join(",")) else $tcp.header.request.headers.Host end)) else . end);
  # NOTE: finalmask is a JSON-only Xray streamSettings feature with no share-link/URI
  # representation. Only its salamander mask maps to a standard URI param (hysteria2
  # obfs), handled in buildHy2. The worker emits fm=<json> here, but no client reads
  # it, so we intentionally drop it.

# ---------- URI builders ----------
def buildVless:
  . as $ob | vnext($ob.settings) as $e
  | ($e.u.id // $ob.settings.id) as $id
  | ($e.v.address // $ob.settings.address // $ob.address // $ob.server) as $host
  | ($e.v.port // $ob.settings.port // $ob.port // 443) as $port
  | if (tv($host) and tv($id)) then
      ( []
        | pset("encryption"; ($e.u.encryption // $ob.settings.encryption // "none"))
        | pset("flow"; ($e.u.flow // $ob.settings.flow))
        | streamParams($ob.streamSettings)
        | (if (phas("security") | not) then pset("security"; "none") else . end) ) as $p
      | "vless://" + ($id | encComp) + "@" + hostPort($host; $port) + "?" + ($p | pstr) + "#" + ($ob | tagOf($host) | encComp)
    else null end;

def buildTrojan:
  . as $ob | ($ob.settings.servers[0] // $ob.settings // {}) as $s
  | ($s.address // $s.server // $ob.address // $ob.server) as $host
  | ($s.port // $ob.port // 443) as $port
  | ($s.password // $ob.password) as $pw
  | if (tv($host) and tv($pw)) then
      ( [] | streamParams($ob.streamSettings) | (if (phas("security") | not) then pset("security"; "none") else . end) ) as $p
      | "trojan://" + ($pw | encComp) + "@" + hostPort($host; $port) + "?" + ($p | pstr) + "#" + ($ob | tagOf($host) | encComp)
    else null end;

def buildVmess:
  . as $ob | vnext($ob.settings) as $e
  | ($e.u.id // $ob.settings.id) as $id
  | ($e.v.address // $ob.settings.address // $ob.address // $ob.server) as $host
  | ($e.v.port // $ob.settings.port // $ob.port // 443) as $port
  | if (tv($host) and tv($id)) then
      ($ob.streamSettings // {}) as $stream | ($stream.wsSettings // {}) as $ws | ($stream.tlsSettings // {}) as $tls
      | { v: "2", ps: ($ob | tagOf($host)), add: ($host | tostring), port: ($port | tostring),
          id: $id, aid: (($e.u.alterId // 0) | tostring), scy: ($e.u.security // "auto"),
          net: ($stream.network // "tcp"), type: "none",
          host: (($ws.headers.Host // $ws.headers.host) // $tls.serverName // ""),
          path: ($ws.path // ""), tls: (if $stream.security == "tls" then "tls" else "" end),
          sni: ($tls.serverName // ""),
          alpn: (if ($tls.alpn | type) == "array" then ($tls.alpn | join(",")) else ($tls.alpn // "") end),
          fp: ($tls.fingerprint // "") }
      | "vmess://" + (tojson | @base64)
    else null end;

def buildShadowsocks:
  . as $ob | ($ob.settings.servers[0] // $ob.settings // {}) as $s
  | ($s.address // $s.server // $ob.address // $ob.server) as $host
  | ($s.port // $ob.port // 8388) as $port
  | ($s.method // $ob.method) as $method
  | ($s.password // $ob.password) as $pw
  | if (tv($method) and tv($pw) and tv($host)) then
      (($method + ":" + $pw) | @base64 | gsub("=+$"; "")) as $user
      | ( [] | streamParams($ob.streamSettings) ) as $p
      | ($p | pstr) as $qs
      | "ss://" + $user + "@" + hostPort($host; $port) + (if $qs != "" then "?" + $qs else "" end) + "#" + ($ob | tagOf($host) | encComp)
    else null end;

def buildHy2:
  . as $ob
  | ($ob.streamSettings.hysteriaSettings // $ob.streamSettings.hy2Settings // {}) as $hy
  | ($ob.settings.servers[0] // $ob.settings.server // $ob.settings // {}) as $s
  | ($s.address // $s.server // $ob.address // $ob.server) as $host
  | ($s.port // $ob.port) as $port
  | ($hy.auth // $hy.password // $s.password // $s.auth // $ob.settings.password // $ob.settings.auth) as $pw
  | if (tv($host) and tv($pw)) then
      ($ob.streamSettings.tlsSettings // {}) as $tls
      | ($ob.streamSettings.finalmask) as $fm
      | (($fm.udp // []) | map(select((.type == "salamander") and ((((.settings // {}).password) // "") != ""))) | .[0]) as $sal
      | ( []
          | pset("sni"; ($tls.serverName // $s.serverName))
          | pset("alpn"; (if ($tls.alpn | type) == "array" then ($tls.alpn | join(",")) else $tls.alpn end))
          | pset("insecure"; (if tv($tls.allowInsecure) then "1" else "" end))
          | pset("obfs"; ($hy.obfs // $ob.settings.obfs // $s.obfs))
          | (if $sal != null then (pset("obfs"; "salamander") | pset("obfs-password"; $sal.settings.password)) else . end) ) as $p
      | (if (($hy.version // $ob.settings.version // $ob.version // "2") | tostring) == "1" then "hysteria" else "hysteria2" end) as $scheme
      | $scheme + "://" + ($pw | encComp) + "@" + hostPort($host; $port) + "?" + ($p | pstr) + "#" + ($ob | tagOf($host) | encComp)
    else null end;

def toUri:
  . as $ob | ($ob.protocol // "" | lc) as $proto
  | if $proto == "vless" then buildVless
    elif $proto == "vmess" then buildVmess
    elif $proto == "trojan" then buildTrojan
    elif $proto == "shadowsocks" then buildShadowsocks
    elif ($proto == "hysteria" or $proto == "hysteria2" or $proto == "hy2") then buildHy2
    else null end;

# ---------- transports for YAML proxies ----------
def setIf($k; $v): if ($v == null or $v == "" or (($v | type) == "array" and ($v | length) == 0) or (($v | type) == "object" and ($v | length) == 0)) then . else . + {($k): $v} end;
def asList($v): if ($v == null or $v == "") then [] elif ($v | type) == "array" then ($v | map(select(. != null and . != "")) | map(tostring)) else [($v | tostring)] end;
def headerMap($h): if ($h | type) != "object" then {} else ($h | to_entries | map(select(.value != null and .value != "")) | map({key: .key, value: (if (.value | type) == "array" then (.value | map(select(. != null and . != "")) | join(",")) else (.value | tostring) end)}) | from_entries) end;
def headerListMap($h): if ($h | type) != "object" then {} else ($h | to_entries | map(.key as $k | {key: $k, value: asList(.value)}) | map(select(.value | length > 0)) | from_entries) end;
def firstHost($h): if ($h | type) != "object" then "" else ($h.Host // $h.host // "") end;
def normNet($n): ($n // "tcp" | tostring | lc) as $x | if $x == "raw" then "tcp" elif $x == "splithttp" then "xhttp" elif $x == "websocket" then "ws" else $x end;
def httpOptsFromTcp($tcp):
  ($tcp.header // {}) as $h
  | if (($h.type // "" | tostring | lc) != "http") then null
    else
      ($h.request // {}) as $req
      | ({} | setIf("method"; $req.method)
            | setIf("path"; (if (asList($req.path) | length) > 0 then asList($req.path) else ["/"] end))) as $o
      | (headerListMap($req.headers)) as $hm
      | (if ($hm | length) > 0 then $o + {headers: $hm} else $o end)
    end;

def addTlsDirect($proxy; $stream):
  ($stream.security // "" | tostring | lc) as $sec
  | ($stream.tlsSettings // {}) as $tls
  | ($stream.realitySettings // {}) as $reality
  | ($reality.settings // {}) as $ri
  | $proxy
  | (if ($sec == "tls" or $sec == "reality") then
       (. + {tls: true})
       | setIf("servername"; ($tls.serverName // $reality.serverName // (if ($reality.serverNames | type) == "array" then $reality.serverNames[0] else $reality.serverNames end)))
       | setIf("alpn"; asList($tls.alpn))
       | setIf("client-fingerprint"; ($tls.fingerprint // $reality.fingerprint // $ri.fingerprint))
       | (if tv($tls.allowInsecure) then . + {"skip-cert-verify": true} else . end)
     else . end)
  | (if ($sec == "reality") then
       ({} | setIf("public-key"; ($reality.publicKey // $reality.public_key // $reality.password // $ri.publicKey // $ri.public_key // $ri.password))
           | setIf("short-id"; ($reality.shortId // $reality.short_id // (if ($reality.shortIds | type) == "array" then $reality.shortIds[0] else $reality.shortIds end)))) as $ro
       | (if ($ro | length) > 0 then . + {"reality-opts": $ro} else . end)
     else . end);

def applyWsTransport($proxy; $ws; $upgrade):
  ($ws.path // "/") as $rawpath
  | ($rawpath | split("?")) as $pp
  | ($pp[0]) as $basepath
  | (if ($pp | length) > 1 then ($pp[1] | split("&")) else [] end) as $qs
  | ($qs | map(select(startswith("ed="))) | .[0]) as $edp
  | (if $edp != null then ($edp | ltrimstr("ed=")) else null end) as $ed
  | (if $ed != null then ($qs | map(select(startswith("ed=") | not))) else $qs end) as $qs2
  | (if $ed != null then ($basepath + (if ($qs2 | length) > 0 then "?" + ($qs2 | join("&")) else "" end)) else $rawpath end) as $path
  | ({}
     | (if $ed != null then . + {"max-early-data": ($ed | tonumber), "early-data-header-name": "Sec-WebSocket-Protocol"} else . end)
     | setIf("path"; $path)) as $opts
  | (headerMap($ws.headers)) as $hm
  | ($ws.host // firstHost($ws.headers)) as $host
  | (if tv($host) then ($hm + {Host: ($host | tostring)}) else $hm end) as $hm2
  | (if ($hm2 | length) > 0 then $opts + {headers: $hm2} else $opts end) as $opts2
  | (if $upgrade then $opts2 + {"v2ray-http-upgrade": true} else $opts2 end) as $opts3
  | (if tv($ws.ed) or tv($ws.maxEarlyData) then $opts3 + {"max-early-data": (($ws.ed // $ws.maxEarlyData) | tonumber)} else $opts3 end) as $opts4
  | (if tv($ws.earlyDataHeaderName) then $opts4 + {"early-data-header-name": $ws.earlyDataHeaderName} else $opts4 end) as $opts5
  | $proxy + {network: "ws"}
  | (if ($opts5 | length) > 0 then . + {"ws-opts": $opts5} else . end);

def applyHttpTransport($proxy; $http):
  ({} | setIf("path"; (if ($http.path | type) == "array" then $http.path[0] else ($http.path // "/") end))
      | setIf("host"; asList($http.host))) as $o
  | $proxy + {network: "h2"}
  | (if ($o | length) > 0 then . + {"h2-opts": $o} else . end);

def applyGrpcTransport($proxy; $grpc):
  ({} | setIf("grpc-service-name"; $grpc.serviceName)
      | setIf("grpc-user-agent"; $grpc.userAgent)
      | setIf("ping-interval"; $grpc.pingInterval)
      | setIf("max-connections"; $grpc.maxConnections)
      | setIf("min-streams"; $grpc.minStreams)
      | setIf("max-streams"; $grpc.maxStreams)) as $o
  | $proxy + {network: "grpc"}
  | (if ($o | length) > 0 then . + {"grpc-opts": $o} else . end);

def rangeString($v):
  if ($v == null or $v == "") then ""
  elif ($v | type) == "number" then ($v | tostring)
  elif ($v | type) == "string" then $v
  elif ($v | type) == "object" then
    (($v.from // $v.min)) as $from | (($v.to // $v.max)) as $to
    | if ($from != null and $to != null) then (($from | tostring) + "-" + ($to | tostring)) else "" end
  else "" end;
def parseExtraObj($v): if ($v | type) == "object" then $v else {} end;
def xmuxToReuse($xmux):
  if ($xmux | type) != "object" then {}
  else
    {} | setIf("max-concurrency"; rangeString($xmux.maxConcurrency))
       | setIf("max-connections"; rangeString($xmux.maxConnections))
       | setIf("c-max-reuse-times"; rangeString($xmux.cMaxReuseTimes))
       | setIf("h-max-request-times"; rangeString($xmux.hMaxRequestTimes))
       | setIf("h-max-reusable-secs"; rangeString($xmux.hMaxReusableSecs))
       | setIf("h-keep-alive-period"; $xmux.hKeepAlivePeriod)
  end;
def streamToXhttpDownloadSettings($dsStream):
  ($dsStream.streamSettings // $dsStream.stream // $dsStream) as $stream
  | ($stream.xhttpSettings // $stream.splithttpSettings // {}) as $xhttp
  | ($stream.tlsSettings // {}) as $tls
  | ($stream.realitySettings // {}) as $reality
  | ({} | setIf("path"; $xhttp.path)
        | setIf("host"; ($xhttp.host // firstHost($xhttp.headers)))) as $o0
  | (headerMap($xhttp.headers)) as $hm
  | (if ($hm | length) > 0 then $o0 + {headers: $hm} else $o0 end) as $o1
  | (xmuxToReuse($xhttp.xmux // (parseExtraObj($xhttp.extra).xmux))) as $reuse
  | (if ($reuse | length) > 0 then $o1 + {"reuse-settings": $reuse} else $o1 end) as $o2
  | ($o2 | setIf("server"; ($dsStream.address // $dsStream.server)) | setIf("port"; $dsStream.port)) as $o3
  | ($stream.security // "" | tostring | lc) as $sec
  | (if ($sec == "tls" or $sec == "reality") then
       ($o3 + {tls: true})
       | setIf("alpn"; asList($tls.alpn))
       | setIf("skip-cert-verify"; (if tv($tls.allowInsecure) then true else null end))
       | setIf("servername"; ($tls.serverName // $reality.serverName // (if ($reality.serverNames | type) == "array" then $reality.serverNames[0] else $reality.serverNames end)))
       | setIf("client-fingerprint"; ($tls.fingerprint // $reality.fingerprint))
     else $o3 end) as $o4
  | (if ($sec == "reality") then
       ({} | setIf("public-key"; ($reality.publicKey // $reality.password))
           | setIf("short-id"; ($reality.shortId // (if ($reality.shortIds | type) == "array" then $reality.shortIds[0] else $reality.shortIds end)))) as $ro
       | (if ($ro | length) > 0 then $o4 + {"reality-opts": $ro} else $o4 end)
     else $o4 end);
def xhttpScalars($o; $x):
  $o
  | setIf("no-grpc-header"; $x.noGRPCHeader)
  | setIf("x-padding-bytes"; rangeString($x.xPaddingBytes // $x.x_padding_bytes))
  | setIf("x-padding-obfs-mode"; $x.xPaddingObfsMode)
  | setIf("x-padding-key"; $x.xPaddingKey)
  | setIf("x-padding-header"; $x.xPaddingHeader)
  | setIf("x-padding-placement"; $x.xPaddingPlacement)
  | setIf("x-padding-method"; $x.xPaddingMethod)
  | setIf("uplink-http-method"; ($x.uplinkHTTPMethod // $x.uplinkHttpMethod))
  | setIf("session-placement"; $x.sessionPlacement)
  | setIf("session-key"; $x.sessionKey)
  | setIf("seq-placement"; $x.seqPlacement)
  | setIf("seq-key"; $x.seqKey)
  | setIf("uplink-data-placement"; $x.uplinkDataPlacement)
  | setIf("uplink-data-key"; $x.uplinkDataKey)
  | setIf("uplink-chunk-size"; rangeString($x.uplinkChunkSize))
  | setIf("sc-max-each-post-bytes"; rangeString($x.scMaxEachPostBytes))
  | setIf("sc-min-posts-interval-ms"; rangeString($x.scMinPostsIntervalMs));
def applyXhttpExtra($o; $extraRaw):
  (parseExtraObj($extraRaw)) as $extra
  | if ($extra | length) == 0 then $o
    else
      (xhttpScalars($o; $extra)) as $o1
      | (xmuxToReuse($extra.xmux)) as $reuse
      | (if ($reuse | length) > 0 then $o1 + {"reuse-settings": $reuse} else $o1 end) as $o2
      | (if ($extra.downloadSettings != null) then streamToXhttpDownloadSettings($extra.downloadSettings) else {} end) as $ds
      | (if ($ds | length) > 0 then $o2 + {"download-settings": $ds} else $o2 end)
    end;
def applyXhttpTransport($proxy; $xhttp):
  ({} | setIf("path"; $xhttp.path)
      | setIf("host"; ($xhttp.host // firstHost($xhttp.headers)))
      | setIf("mode"; $xhttp.mode)) as $o0
  | (headerMap($xhttp.headers) | del(.Host) | del(.host)) as $hm
  | (if ($hm | length) > 0 then $o0 + {headers: $hm} else $o0 end) as $o1
  | (xhttpScalars($o1; $xhttp)) as $o2
  | (xmuxToReuse($xhttp.xmux)) as $reuse
  | (if ($reuse | length) > 0 then $o2 + {"reuse-settings": $reuse} else $o2 end) as $o3
  | (if ($xhttp.downloadSettings != null) then streamToXhttpDownloadSettings($xhttp.downloadSettings) else {} end) as $ds
  | (if ($ds | length) > 0 then $o3 + {"download-settings": $ds} else $o3 end) as $o4
  | (applyXhttpExtra($o4; $xhttp.extra)) as $o5
  | $proxy + {network: "xhttp"}
  | (if ($o5 | length) > 0 then . + {"xhttp-opts": $o5} else . end);

def addTransportDirect($proxy; $stream; $protocol):
  ($stream // {}) as $s
  | (normNet($s.network // "tcp")) as $network
  | ($s.tcpSettings // $s.rawSettings // {}) as $tcp
  | ($s.wsSettings // {}) as $ws
  | ($s.httpupgradeSettings // {}) as $httpup
  | ($s.xhttpSettings // $s.splithttpSettings // {}) as $xhttp
  | ($s.grpcSettings // {}) as $grpc
  | ($s.httpSettings // {}) as $http
  | (httpOptsFromTcp($tcp)) as $tcpHttp
  | (if ($protocol == "trojan" and (["ws", "httpupgrade", "grpc"] | index($network)) == null) then ($proxy + {network: "tcp"})
     elif ($network == "xhttp" and $protocol != "vless") then ($proxy + {network: "tcp"})
     elif ($tcpHttp != null) then ($proxy + {network: "http", "http-opts": $tcpHttp})
     elif ($network == "http" or $network == "h2") then applyHttpTransport($proxy; $http)
     elif ($network == "ws") then applyWsTransport($proxy; $ws; false)
     elif ($network == "httpupgrade") then applyWsTransport($proxy; $httpup; true)
     elif ($network == "grpc") then applyGrpcTransport($proxy; $grpc)
     elif ($network == "xhttp" and $protocol == "vless") then applyXhttpTransport($proxy; $xhttp)
     else ($proxy + {network: (if $network == "tcp" then "tcp" else $network end)}) end)
  | addTlsDirect(.; $s);

# ---------- outbound -> proxy dict ----------
def vlessProxy($idx):
  . as $ob | vnext($ob.settings) as $e
  | ($e.v.address // $ob.settings.address // $ob.address // $ob.server) as $host
  | ($e.v.port // $ob.settings.port // $ob.port // 443) as $port
  | ($e.u.id // $ob.settings.id) as $uuid
  | if (tv($host) and tv($uuid)) then
      ({name: ($ob | tagOf("vless-" + (($idx + 1) | tostring))), type: "vless", server: $host, port: ($port | tonumber? // $port), uuid: $uuid, udp: true}
       | setIf("flow"; ($e.u.flow // $ob.settings.flow))
       | (($e.u.encryption // $ob.settings.encryption) as $enc | if (tv($enc) and $enc != "none") then . + {encryption: {"__q": $enc}} else . end)) as $proxy
      | addTransportDirect($proxy; $ob.streamSettings; "vless")
    else null end;

def vmessProxy($idx):
  . as $ob | vnext($ob.settings) as $e
  | ($e.v.address // $ob.settings.address // $ob.address // $ob.server) as $host
  | ($e.v.port // $ob.settings.port // $ob.port // 443) as $port
  | ($e.u.id // $ob.settings.id) as $uuid
  | if (tv($host) and tv($uuid)) then
      ({name: ($ob | tagOf("vmess-" + (($idx + 1) | tostring))), type: "vmess", server: $host, port: ($port | tonumber? // $port), uuid: $uuid, alterId: (($e.u.alterId // 0) | tonumber? // 0), cipher: ($e.u.security // "auto"), udp: true}) as $proxy
      | addTransportDirect($proxy; $ob.streamSettings; "vmess")
    else null end;

def trojanProxy($idx):
  . as $ob | ($ob.settings.servers[0] // $ob.settings // {}) as $s
  | ($s.address // $s.server // $ob.address // $ob.server) as $host
  | ($s.port // $ob.port // 443) as $port
  | ($s.password // $ob.password) as $pw
  | if (tv($host) and tv($pw)) then
      ({name: ($ob | tagOf("trojan-" + (($idx + 1) | tostring))), type: "trojan", server: $host, port: ($port | tonumber? // $port), password: $pw, udp: true}) as $proxy
      | addTransportDirect($proxy; $ob.streamSettings; "trojan")
      | (if has("servername") then (. + {sni: .servername} | del(.servername)) else . end)
    else null end;

def ssProxy($idx):
  . as $ob | ($ob.settings.servers[0] // $ob.settings // {}) as $s
  | ($s.address // $s.server // $ob.address // $ob.server) as $host
  | ($s.port // $ob.port // 8388) as $port
  | ($s.method // $ob.method) as $method
  | ($s.password // $ob.password) as $pw
  | if (tv($method) and tv($pw) and tv($host)) then
      {name: ($ob | tagOf("ss-" + (($idx + 1) | tostring))), type: "ss", server: $host, port: ($port | tonumber? // $port), cipher: $method, password: $pw, udp: true}
    else null end;

def hyProxy($idx):
  . as $ob
  | ($ob.streamSettings.hysteriaSettings // $ob.streamSettings.hy2Settings // {}) as $hy
  | ($ob.settings.servers[0] // $ob.settings.server // $ob.settings // {}) as $s
  | ($s.address // $s.server // $ob.address // $ob.server) as $host
  | ($s.port // $ob.port) as $port
  | ($hy.auth // $hy.password // $s.password // $s.auth // $ob.settings.password // $ob.settings.auth) as $pw
  | if (tv($host) and tv($pw)) then
      ($ob.streamSettings.tlsSettings // {}) as $tls
      | ($ob.streamSettings.finalmask) as $fm
      | (($fm.udp // []) | map(select((.type == "salamander") and ((((.settings // {}).password) // "") != ""))) | .[0]) as $sal
      | (if (($hy.version // $ob.settings.version // $ob.version // "2") | tostring) == "1" then "hysteria" else "hysteria2" end) as $type
      | ({name: ($ob | tagOf($type + "-" + (($idx + 1) | tostring))), type: $type, server: $host, port: (($port // 443) | tonumber? // ($port // 443)), password: $pw, udp: true}
         | setIf("sni"; ($tls.serverName // $s.serverName))
         | setIf("alpn"; asList($tls.alpn))
         | (if tv($tls.allowInsecure) then . + {"skip-cert-verify": true} else . end)
         | setIf("obfs"; ($hy.obfs // $ob.settings.obfs // $s.obfs))
         | (if $sal != null then (. + {obfs: "salamander", "obfs-password": $sal.settings.password}) else . end))
    else null end;

def toProxy($idx):
  . as $ob | ($ob.protocol // "" | lc) as $proto
  | if $proto == "vless" then vlessProxy($idx)
    elif $proto == "vmess" then vmessProxy($idx)
    elif $proto == "trojan" then trojanProxy($idx)
    elif $proto == "shadowsocks" then ssProxy($idx)
    elif ($proto == "hysteria" or $proto == "hysteria2" or $proto == "hy2") then hyProxy($idx)
    else null end;

# ---------- YAML emitter (mirrors proxiesToYaml) ----------
def yamlScalar:
  if type == "number" or type == "boolean" then tostring
  elif . == null then "\"\""
  elif (type == "object" and has("__q")) then (.["__q"] | tostring | @json)
  else
    tostring as $s
    | if ($s | test("^[A-Za-z0-9_.:/@+-]+$")) and (($s | IN("true", "false", "null")) | not) then $s else ($s | @json) end
  end;

def yamlValue($indent):
  (" " * $indent) as $pad
  | if (type == "object" and has("__q")) then yamlScalar
    elif type == "array" then
      (if length == 0 then "[]" else ("\n" + ([.[] | $pad + "- " + yamlScalar] | join("\n"))) end)
    elif type == "object" then
      ("\n" + ([to_entries[] | $pad + .key + ": " + (.value | yamlValue($indent + 2))] | join("\n")))
    else yamlScalar end;

def proxiesToYaml:
  (["proxies:"] + (
    map(to_entries | select(length > 0) |
      (.[0]) as $first | (.[1:]) as $rest
      | (["  - " + $first.key + ": " + ($first.value | yamlValue(4))]
         + ($rest | map("    " + .key + ": " + (.value | yamlValue(6)))))
      | join("\n"))
  )) | join("\n") + "\n";

# ---------- dedupe ----------
def dedupeProxies:
  reduce .[] as $x ({seen: {}, out: []};
    ($x | del(.name) | walk(if type == "object" then to_entries | sort_by(.key) | from_entries else . end) | tojson) as $k
    | if .seen[$k] then . else {seen: (.seen + {($k): true}), out: (.out + [$x])} end) | .out;
def dedupeUris:
  reduce .[] as $x ({seen: {}, out: []};
    ($x | sub("#.*$"; "")) as $k
    | if .seen[$k] then . else {seen: (.seen + {($k): true}), out: (.out + [$x])} end) | .out;

# ---------- main ----------
(gatherOutbounds) as $obs
| if $fmt == "yaml" then
    ([ range(0; ($obs | length)) as $i | ($obs[$i] | toProxy($i)) ] | map(select(. != null)) | dedupeProxies) as $proxies
    | (if ($proxies | length) == 0 then error("no proxies converted to YAML") else ($proxies | proxiesToYaml) end)
  else
    ([ range(0; ($obs | length)) as $i | ($obs[$i] | toUri) ] | map(select(. != null)) | dedupeUris) as $uris
    | if $fmt == "base64" then ($uris | join("\n") | @base64)
      else ($uris | if length > 0 then join("\n") + "\n" else "" end) end
  end
