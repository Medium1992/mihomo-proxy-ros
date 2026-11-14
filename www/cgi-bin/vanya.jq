# Конфиг ключа ssconf в список ссылок для провайдера mihomo, по одной в
# строке, основной узел первым. Понимает:
#   - старый JSON Outline: method, password, server, server_port;
#   - transport с $type: shadowsocks или tcpudp (tcp/udp) — cipher, secret,
#     endpoint строкой host:port, $type dial или websocket;
#   - transport с $type: singbox — в config лежит JSON sing-box, из него
#     берутся outbounds shadowsocks, vless, trojan и hysteria2, а основной —
#     тот, к которому в итоге ведёт route.final.

def hp: if (.server | tostring | test(":")) then "[\(.server)]:\(.server_port)" else "\(.server):\(.server_port)" end;

def qs: to_entries | map(select(.value != null and .value != "")) | map("\(.key)=\(.value | tostring | @uri)") | join("&");

def ssuser($method; $password): "\($method):\($password)" | @base64 | sub("=+$"; "");

def nodename($loc; $name): (if $loc != "" then $loc + " " else "" end) + $name;

# --- sing-box ---

def tlsq:
  (.tls // {}) as $t
  | if ($t.enabled // false) then
      ($t.reality.enabled // false) as $r
      | {security: (if $r then "reality" else "tls" end),
         sni: $t.server_name,
         fp: (if ($t.utls.enabled // false) then ($t.utls.fingerprint // "chrome") else null end),
         pbk: (if $r then $t.reality.public_key else null end),
         sid: (if $r then $t.reality.short_id else null end),
         allowInsecure: (if ($t.insecure // false) then "1" else null end),
         alpn: (($t.alpn // []) | if length > 0 then join(",") else null end)}
    else {} end;

def trq:
  (.transport // {}) as $tr
  | ($tr.type // "tcp") as $ty
  | {type: (if $ty == "http" then "h2" else $ty end)}
    + (if $ty == "ws" then {path: ($tr.path // "/"), host: ($tr.headers.Host // null)}
       elif $ty == "grpc" then {serviceName: ($tr.service_name // "")}
       else {} end);

def sburi($loc):
  nodename($loc; .tag // .type) as $name
  | if .type == "shadowsocks" then
      "ss://\(ssuser(.method; .password))@\(hp)#\($name | @uri)"
    elif .type == "vless" then
      "vless://\(.uuid | @uri)@\(hp)?\(({encryption: "none", flow: .flow} + tlsq + trq) | qs)#\($name | @uri)"
    elif .type == "trojan" then
      "trojan://\(.password | @uri)@\(hp)?\((tlsq + trq) | qs)#\($name | @uri)"
    elif .type == "hysteria2" then
      "hysteria2://\((.password // "") | @uri)@\(hp)?\(((tlsq | del(.security)) + (if (.obfs.type // null) then {obfs: .obfs.type, "obfs-password": .obfs.password} else {} end)) | qs)#\($name | @uri)"
    else empty end;

def resolve($obs; $tag; $depth):
  if $depth > 8 or $tag == null then null
  else
    ([$obs[] | select(.tag == $tag)] | .[0]) as $o
    | if $o == null then null
      elif ($o.outbounds | type) == "array" then
        ([($o.default // empty), $o.outbounds[]] | map(resolve($obs; .; $depth + 1)) | map(select(. != null)) | .[0])
      else $o end
  end;

def singbox($loc):
  (if (.config | type) == "string" then (.config | fromjson) else .config end) as $sb
  | ($sb.outbounds // []) as $obs
  | resolve($obs; $sb.route.final; 0) as $main
  | [$obs[] | select(.type == "shadowsocks" or .type == "vless" or .type == "trojan" or .type == "hysteria2")]
  | (map(select(. == $main)) + map(select(. != $main)))
  | .[] | sburi($loc);

# --- Outline ---

def endpoint:
  (if type == "string" then {"$type": "dial", address: .} else . end) as $e
  | if ($e["$type"] // "dial") == "dial" then
      ($e.address | capture("^\\[?(?<server>[^\\]]+?)\\]?:(?<port>[0-9]+)$")) | {server, server_port: .port}
    elif $e["$type"] == "websocket" then
      ($e.url | capture("^(?<scheme>wss?)://(?<host>[^/:]+)(:(?<port>[0-9]+))?(?<path>/.*)?$")) as $u
      | {server: $u.host,
         server_port: ($u.port // (if $u.scheme == "wss" then "443" else "80" end)),
         ws: {tls: ($u.scheme == "wss"), host: $u.host, path: ($u.path // "/")}}
    else error("endpoint $type \($e["$type"]) is not supported") end;

def outline($loc):
  (if .["$type"] == "tcpudp" then .tcp else . end) as $tcp
  | if ($tcp["$type"] // "") != "shadowsocks" then error("transport is not shadowsocks") else . end
  | ($tcp.endpoint | endpoint) as $ep
  | nodename($loc; $ep.server) as $name
  | if $ep.ws then
      (["v2ray-plugin", "mode=websocket"] + (if $ep.ws.tls then ["tls"] else [] end) + ["host=\($ep.ws.host)", "path=\($ep.ws.path)"] | join(";")) as $plugin
      | "ss://\(ssuser($tcp.cipher; $tcp.secret))@\($ep | hp)?plugin=\($plugin | @uri)#\($name | @uri)"
    else
      "ss://\(ssuser($tcp.cipher; $tcp.secret))@\($ep | hp)#\($name | @uri)"
    end;

if .transport then
  (.transport.location // .location // "") as $loc
  | if .transport["$type"] == "singbox" then .transport | singbox($loc) else .transport | outline($loc) end
elif .method and .password and .server and .server_port then
  "ss://\(ssuser(.method; .password))@\(hp)#\(nodename(""; .tag // "\(.server):\(.server_port)") | @uri)"
else
  error("unknown ssconf config: no transport and no method/password/server/server_port")
end
