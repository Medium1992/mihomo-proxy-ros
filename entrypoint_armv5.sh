#!/usr/bin/sh

sleep 1

log() { echo "[$(date +'%H:%M:%S')] $*"; }

# sysctl -w net.netfilter.nf_conntrack_tcp_loose=0
sysctl -w net.netfilter.nf_conntrack_tcp_timeout_established=86400
sysctl -w net.netfilter.nf_conntrack_tcp_timeout_syn_sent=5
sysctl -w net.netfilter.nf_conntrack_tcp_timeout_syn_recv=5
sysctl -w net.netfilter.nf_conntrack_tcp_timeout_fin_wait=10
sysctl -w net.netfilter.nf_conntrack_tcp_timeout_close_wait=10
sysctl -w net.netfilter.nf_conntrack_tcp_timeout_last_ack=10
sysctl -w net.netfilter.nf_conntrack_tcp_timeout_time_wait=10
sysctl -w net.netfilter.nf_conntrack_tcp_timeout_close=10
sysctl -w net.netfilter.nf_conntrack_tcp_timeout_unacknowledged=300
sysctl -w net.netfilter.nf_conntrack_udp_timeout_stream=180
# sysctl -w net.ipv4.udp_early_demux=0

for iface in $(ip -o link show up | awk -F': ' '/link\/ether/ {gsub(/@.*$/,"",$2); if($2!="lo") print $2}'); do
tc qdisc add dev $iface root fq_codel >/dev/null 2>&1;
ip link set dev $iface multicast off >/dev/null 2>&1;
done

set -eu

TPROXY="${TPROXY:-true}"
LOG_LEVEL="${LOG_LEVEL:-error}"
EXTERNAL_UI_URL="${EXTERNAL_UI_URL:-https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip}"
UI_SECRET="${UI_SECRET:-}"
CONFIG_DIR="/root/.config/mihomo"
AWG_DIR="$CONFIG_DIR/awg"
PROXIES_DIR="$CONFIG_DIR/proxies_mount"
AMNEZIA_PREMIUM_DIR="$CONFIG_DIR/amnezia_premium"
RULE_SET_DIR="$CONFIG_DIR/rule_set_list"
# Runtime artifacts (regenerated on every container start) live in RAM
# to avoid wearing out the underlying flash storage. Mounted user files
# (AWG_DIR, PROXIES_DIR, RULE_SET_DIR) and mihomo's own downloads
# (geosite, geoip, external-ui) stay in CONFIG_DIR on flash.
RUNTIME_DIR="/dev/shm/mihomo"
HS5T_DIR="/dev/shm/hs5t"
CONFIG_YAML="$RUNTIME_DIR/config.yaml"
UI_URL_CHECK="$CONFIG_DIR/.ui_url"
FAKE_IP_RANGE="${FAKE_IP_RANGE:-198.18.0.0/15}"
FAKE_IP_TTL="${FAKE_IP_TTL:-1}"
ZAPRET_PACKETS="${ZAPRET_PACKETS:-12}"
ZAPRET2_PACKETS="${ZAPRET2_PACKETS:-12}"
HEALTHCHECK_INTERVAL="${HEALTHCHECK_INTERVAL:-120}"
HEALTHCHECK_URL="${HEALTHCHECK_URL:-https://www.gstatic.com/generate_204}"
HEALTHCHECK_URL_STATUS="${HEALTHCHECK_URL_STATUS:-204}"
HEALTHCHECK_URL_BYEDPI="${HEALTHCHECK_URL_BYEDPI:-https://www.facebook.com}"
HEALTHCHECK_URL_STATUS_BYEDPI="${HEALTHCHECK_URL_STATUS_BYEDPI:-200}"
HEALTHCHECK_URL_ZAPRET="${HEALTHCHECK_URL_ZAPRET:-https://www.facebook.com}"
HEALTHCHECK_URL_STATUS_ZAPRET="${HEALTHCHECK_URL_STATUS_ZAPRET:-200}"
HEALTHCHECK_PROVIDER="${HEALTHCHECK_PROVIDER:-true}"
SUB_LINK_INTERVAL="${SUB_LINK_INTERVAL:-3600}"
GROUP_TYPE="${GROUP_TYPE:-select}"
GROUP_USE="${GROUP_USE:-}"
GROUP_PROXIES="${GROUP_PROXIES:-}"
GROUP_FILTER="${GROUP_FILTER:-}"
GROUP_EXCLUDE="${GROUP_EXCLUDE:-}"
GROUP_EXCLUDE_TYPE="${GROUP_EXCLUDE_TYPE:-}"
GROUP_URL="${GROUP_URL:-https://www.gstatic.com/generate_204}"
GROUP_URL_STATUS="${GROUP_URL_STATUS:-204}"
GROUP_INTERVAL="${GROUP_INTERVAL:-60}"
GROUP_TOLERANCE="${GROUP_TOLERANCE:-20}"
GROUP_STRATEGY="${GROUP_STRATEGY:-consistent-hashing}"

# Amnezia Premium vpn:// support.
# Per-provider country override example: LINK1_AMNEZIA_COUNTRY=nl
AMNEZIA_PREMIUM_GATEWAY="http://gw.amnezia.org:80/"
AMNEZIA_PREMIUM_APP_VERSION="4.8.15.4"
AMNEZIA_PREMIUM_APP_LANGUAGE="ru"
AMNEZIA_PREMIUM_OS_VERSION="linux"
AMNEZIA_PREMIUM_PUBLIC_KEY_FILE="${AMNEZIA_PREMIUM_PUBLIC_KEY_FILE:-/usr/local/bin/awg}"
AMNEZIA_PREMIUM_HTTP_TIMEOUT=8
AMNEZIA_PREMIUM_DNS_TIMEOUT=4
AMNEZIA_PREMIUM_DOH_SERVERS="1.1.1.1|cloudflare-dns.com|/dns-query?name=%s&type=A 1.0.0.1|cloudflare-dns.com|/dns-query?name=%s&type=A 8.8.8.8|dns.google|/resolve?name=%s&type=A 8.8.4.4|dns.google|/resolve?name=%s&type=A"
AMNEZIA_PREMIUM_DNS_SERVERS="9.9.9.9 1.1.1.1 77.88.8.8 8.8.8.8"
AMNEZIA_PREMIUM_PROXY_STORAGE_URLS="https://s3.eu-north-1.amazonaws.com/amnezia/ https://storage.googleapis.com/lambda-list/ https://amnzstrg01.blob.core.windows.net/lambda-list/ https://objectstorage.eu-zurich-1.oraclecloud.com/n/zrhfyaq6qxvh/b/lambda-list/o/ https://51.250.16.178/lambda-list/"

ZAPRET2_WG_CMD="${ZAPRET2_WG_CMD:---blob=quic_vk:@/zapret-fakebin/quic_initial_vk_com.bin --payload wireguard_initiation --lua-desync=fake:blob=quic_vk:repeats=6}"
ZAPRET2_WG_DST="${ZAPRET2_WG_DST:-}"

export TPROXY
export LOG_LEVEL
export EXTERNAL_UI_URL
export UI_SECRET
export FAKE_IP_RANGE
export FAKE_IP_TTL
export ZAPRET_PACKETS
export ZAPRET2_PACKETS
export HEALTHCHECK_INTERVAL
export HEALTHCHECK_URL
export HEALTHCHECK_URL_STATUS
export HEALTHCHECK_URL_BYEDPI
export HEALTHCHECK_URL_STATUS_BYEDPI
export HEALTHCHECK_URL_ZAPRET
export HEALTHCHECK_URL_STATUS_ZAPRET
export HEALTHCHECK_PROVIDER
export SUB_LINK_INTERVAL
export GROUP_TYPE
export GROUP_USE
export GROUP_PROXIES
export GROUP_FILTER
export GROUP_EXCLUDE
export GROUP_EXCLUDE_TYPE
export GROUP_URL
export GROUP_URL_STATUS
export GROUP_INTERVAL
export GROUP_TOLERANCE
export GROUP_STRATEGY
export AMNEZIA_PREMIUM_PUBLIC_KEY_FILE

collect_cmds() {
  prefix="$1"
  list=""
  for v in $(env | grep -E "^${prefix}_CMD([0-9]+)?=" | cut -d= -f1 | sort -V); do
    val=$(printenv "$v")
    [ -n "$val" ] && list="$list $v"
  done
  echo "$list"
}

ZAPRET_LIST=$(collect_cmds ZAPRET)
ZAPRET2_LIST=$(collect_cmds ZAPRET2)
BYEDPI_LIST=$(collect_cmds BYEDPI)

[ -n "$BYEDPI_LIST" ] && BYEDPI=true || BYEDPI=false

used_dscps=""
dscp_to_group=""
for var in $(env | grep -E '_DSCP=' | cut -d= -f1 | sort); do
  group=${var%_DSCP}
  dscp=$(printenv $var)
  if ! echo "$dscp" | grep -Eq '^[0-9]+$'; then continue; fi
  if echo "$used_dscps" | grep -qw "$dscp"; then
    log "Warning: DSCP $dscp already assigned to another group, skipping $group"
    continue
  fi
  used_dscps="$used_dscps $dscp"
  dscp_to_group="$dscp_to_group $dscp:$group"
done

health_check_block() {
  cat <<EOF
    health-check:
      enable: true
      url: $HEALTHCHECK_URL
      interval: $HEALTHCHECK_INTERVAL
      timeout: 1500
      lazy: false
      expected-status: $HEALTHCHECK_URL_STATUS
EOF
}

first_iface() {
  ip -o link show | awk -F': ' '/link\/ether/ {print $2}' | cut -d'@' -f1 | head -n1
}

# ------------------- BYEDPI -------------------
generate_byedpi_proxies() {
  base_mark=500

  for var in $BYEDPI_LIST; do
    idx=$(get_cmd_index "$var" BYEDPI)
    mark=$((base_mark + idx))
    name=$(get_instance_name "BYEDPI" "$idx")
    yaml="$RUNTIME_DIR/${name}.yaml"

    cat > "$yaml" <<EOF
proxies:
  - name: "$name"
    type: direct
    udp: true
    ip-version: ipv4
    routing-mark: $mark
EOF

    cat >> "$CONFIG_YAML" <<EOF
  $name:
    type: file
    path: $RUNTIME_DIR/${name}.yaml
EOF

    [ "${HEALTHCHECK_PROVIDER}" = "true" ] && cat >> "$CONFIG_YAML" <<EOF
    health-check:
      enable: true
      url: $HEALTHCHECK_URL_BYEDPI
      interval: $HEALTHCHECK_INTERVAL
      timeout: 1500
      lazy: false
      expected-status: $HEALTHCHECK_URL_STATUS_BYEDPI
EOF

    providers="$providers $name"
  done
}

apply_byedpi_nft() {
  base_mark=500
  base_port=1500

  nft add table inet byedpi
  nft add chain inet byedpi output '{ type nat hook output priority dstnat; policy accept; }'

  for var in $BYEDPI_LIST; do
    idx=$(get_cmd_index "$var" BYEDPI)
    mark=$((base_mark + idx))
    port=$((base_port + idx))

    nft add rule inet byedpi output meta l4proto tcp mark $mark redirect to $port
  done
}

apply_byedpi_iptables() {
  base_mark=500
  base_port=1500

  for var in $BYEDPI_LIST; do
    idx=$(get_cmd_index "$var" BYEDPI)
    mark=$((base_mark + idx))
    port=$((base_port + idx))

    iptables -t nat -A OUTPUT -p tcp -m mark --mark $mark -j REDIRECT --to-port $port
  done
}

generate_hs5t() {
  idx="$1"
  mark=$((500 + idx))
  port=$((2500 + idx))

  cat > "$HS5T_DIR/hs5t_$idx.yml" <<EOF
misc:
  log-level: 'error'
tunnel:
  name: hs5t_$idx
  mtu: 1500
  ipv4: 100.64.$idx.1
  multi-queue: true
  post-up-script: '$HS5T_DIR/hs5t_$idx.sh'
socks5:
  address: '127.0.0.1'
  port: $port
  udp: 'udp'
EOF

  cat > "$HS5T_DIR/hs5t_$idx.sh" <<EOF
#!/usr/bin/sh
ip rule show | grep -q "fwmark $mark.*ipproto udp" || \
  ip rule add fwmark $mark ipproto udp table $mark pref 150
ip route replace default via 100.64.$idx.1 dev hs5t_$idx table $mark
EOF
  chmod +x "$HS5T_DIR/hs5t_$idx.sh"
}

start_byedpi_processes() {
  base_tcp=1500
  base_udp=2500

  for var in $BYEDPI_LIST; do
    idx=$(get_cmd_index "$var" BYEDPI)
    tcp_port=$((base_tcp + idx))
    udp_port=$((base_udp + idx))
    cmd=$(printenv "$var")

    echo "Starting BYEDPI[$idx] tcp:$tcp_port udp:$udp_port"

    byedpi --port $tcp_port --transparent $cmd >/dev/null 2>&1 &
    byedpi --port $udp_port $cmd >/dev/null 2>&1 &
    generate_hs5t "$idx"
    hs5t "$HS5T_DIR/hs5t_$idx.yml" >/dev/null 2>&1 &
  done
}

# ------------------- ZAPRET -------------------
generate_zapret_proxies() {
  base_mark="$1"     # 300 или 400
  prefix="$2"        # ZAPRET / ZAPRET2
  list="$3"

  idx=0
  for var in $list; do
    base="${var%%_CMD*}"      
    idx="${var#${base}_CMD}"   

    if [ -n "$idx" ]; then
      name="${base}_${idx}"
    else
      name="${base}"
    fi
    mark=$((base_mark + idx))
    yaml="$RUNTIME_DIR/${name}.yaml"

    cat > "$yaml" <<EOF
proxies:
  - name: "$name"
    type: direct
    udp: true
    ip-version: ipv4
    routing-mark: $mark
EOF

    cat >> "$CONFIG_YAML" <<EOF
  $name:
    type: file
    path: $RUNTIME_DIR/${name}.yaml
EOF
    if [ "${HEALTHCHECK_PROVIDER}" = "true" ]; then
      cat >> "$CONFIG_YAML" <<EOF
    health-check:
      enable: true
      url: $HEALTHCHECK_URL_ZAPRET
      interval: $HEALTHCHECK_INTERVAL
      timeout: 1500
      lazy: false
      expected-status: $HEALTHCHECK_URL_STATUS_ZAPRET
EOF
    fi
    providers="$providers $name"
    idx=$((idx + 1))
  done
}

get_packets_range() {
  var="$1"        # ZAPRET_CMD1
  base="$2"       # ZAPRET or ZAPRET2
  def="$3"        # дефолт (например 12)

  idx="${var#${base}_CMD}"
  if [ "$idx" = "$var" ] || [ -z "$idx" ]; then
    idx=0
  fi

  packets_var="${base}_PACKETS${idx}"
  packets=$(printenv "$packets_var" 2>/dev/null || true)
  [ -z "$packets" ] && packets="$def"

  if echo "$packets" | grep -Eq '^[0-9]+$' && [ "$packets" -ge 1 ]; then
    echo "1-$packets"
  else
    echo ""
  fi
}

get_cmd_index() {
  var="$1"        # ZAPRET_CMD2
  base="$2"       # ZAPRET / ZAPRET2

  idx="${var#${base}_CMD}"
  [ "$idx" = "$var" ] && idx=""   # защита

  if [ -z "$idx" ]; then
    echo 0
  else
    echo "$idx"
  fi
}

get_instance_name() {
  base="$1"
  idx="$2"

  if [ "$idx" -eq 0 ]; then
    echo "$base"
  else
    echo "${base}_$idx"
  fi
}

apply_zapret_nft() {
  base_mark="$1"
  base_queue="$2"
  list="$3"
  prefix="$4"
  base_env="$5"
  default_packets="$6"

  for var in $list; do
    idx=$(get_cmd_index "$var" "$base_env")

    mark=$((base_mark + idx))
    queue=$((base_queue + idx))
    table="${prefix}_${idx}"

    packets_range=$(get_packets_range "$var" "$base_env" "$default_packets")

    nft add table inet "$table"
    nft add chain inet "$table" pre  "{ type filter hook prerouting priority mangle; }"
    nft add chain inet "$table" post "{ type filter hook postrouting priority mangle; }"

    nft add rule inet "$table" post meta l4proto { tcp, udp } \
      mark $mark ct state new ct mark set $mark

    nft add rule inet "$table" post meta l4proto { tcp, udp } \
      ct mark $mark ${packets_range:+ct original packets $packets_range} \
      queue num $queue

    nft add rule inet "$table" pre meta l4proto { tcp, udp } \
      ct mark $mark ${packets_range:+ct reply packets $packets_range} \
      queue num $queue
  done
}

start_zapret_processes() {
  base_queue="$1"
  bin="$2"
  list="$3"
  LUA_INIT_ARGS=""
  if [ "${bin}" = "nfqws2" ]; then
    for f in /lua/*.lua; do
      LUA_INIT_ARGS="$LUA_INIT_ARGS --lua-init=@$f"
    done   
  fi
  for var in $list; do
    idx=$(get_cmd_index "$var" "$(echo "$var" | sed 's/_CMD.*//')")

    queue=$((base_queue + idx))
    cmd=$(printenv "$var")

    echo "Starting $var on queue $queue"
    "$bin" --qnum $queue --user=root $LUA_INIT_ARGS $cmd &
  done
}

# ------------------- AWG / WG -------------------
parse_awg_config() {
  local config_file="$1"
  local awg_name="${2:-$(basename "$config_file" .conf)}"

read_cfg() {
  local key="$1"
  grep -iE "^[[:space:]]*${key}[[:space:]]*=[[:space:]]*" "$config_file" 2>/dev/null | \
    tail -n1 | \
    sed -E 's/^[[:space:]]*[^=]*=[[:space:]]*//I' | \
    tr -d '\r\n' | \
    sed -E 's/^[[:space:]]+|[[:space:]]+$//g'
}

  local private_key=$(read_cfg "PrivateKey")
  local address=$(read_cfg "Address")
  local dns=$(read_cfg "DNS")
  local mtu=$(read_cfg "MTU")
  local keepalive=$(read_cfg "PersistentKeepalive")
  local workers=$(read_cfg "Workers")

  local jc=$(read_cfg "Jc");         local jmin=$(read_cfg "Jmin");     local jmax=$(read_cfg "Jmax")
  local s1=$(read_cfg "S1");         local s2=$(read_cfg "S2")
  local s3=$(read_cfg "S3");         local s4=$(read_cfg "S4")
  local h1=$(read_cfg "H1");         local h2=$(read_cfg "H2");         local h3=$(read_cfg "H3");         local h4=$(read_cfg "H4")
  local i1=$(read_cfg "I1");         local i2=$(read_cfg "I2");         local i3=$(read_cfg "I3")
  local i4=$(read_cfg "I4");         local i5=$(read_cfg "I5")          
  local j1=$(read_cfg "J1");         local j2=$(read_cfg "J2");         local j3=$(read_cfg "J3")
  local itime=$(read_cfg "ITime")

  local public_key=$(read_cfg "PublicKey")
  local psk=$(read_cfg "PresharedKey")
  local endpoint=$(read_cfg "Endpoint")

  local ip_v4=""
  local ip_v6=""
  if [ -n "$address" ]; then
    OLDIFS=$IFS
    IFS=','
    for addr in $address; do
      addr=$(echo "$addr" | sed 's/[[:space:]]//g')
      if echo "$addr" | grep -q ':'; then
        [ -n "$ip_v6" ] && ip_v6="$ip_v6,"
        ip_v6="${ip_v6}${addr%%/*}"
      else
        [ -n "$ip_v4" ] && ip_v4="$ip_v4,"
        ip_v4="${ip_v4}${addr%%/*}"
      fi
    done
    IFS=$OLDIFS
  fi

  local server=""
  local port=""
  if [ -n "$endpoint" ]; then
    endpoint=$(echo "$endpoint" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if echo "$endpoint" | grep -q '\['; then
      server=$(echo "$endpoint" | sed -E 's@^\[([^]]+)\]:(.*)$@\1@')
      port=$(echo "$endpoint" | sed -E 's@^\[([^]]+)\]:(.*)$@\2@')
    else
      server=$(echo "$endpoint" | cut -d':' -f1)
      port=$(echo "$endpoint" | cut -d':' -f2-)
    fi
  fi

  local allowed_ips_raw=$(read_cfg "AllowedIPs")
  if [ -n "$allowed_ips_raw" ]; then
    allowed_ips_yaml=$(echo "$allowed_ips_raw" | tr ',' '\n' | \
      sed -E 's/^[[:space:]]*([0-9a-fA-F\.:\/-]+)[[:space:]]*$/\1/' | \
      grep -v '^$' | grep -E '^[0-9a-fA-F\.:]+/[0-9]+$' | \
      sed 's/.*/"&"/' | paste -sd, -)
    [ -z "$allowed_ips_yaml" ] && allowed_ips_yaml='"0.0.0.0/0", "::/0"'
  else
    allowed_ips_yaml='"0.0.0.0/0", "::/0"'
  fi

  echo "  - name: \"$awg_name\""
  echo "    type: wireguard"
  [ -n "$private_key" ] && echo "    private-key: $private_key"
  [ -n "$server" ] && echo "    server: $server"
  [ -n "$port" ] && echo "    port: $port"
  [ -n "$ip_v4" ] && echo "    ip: $ip_v4"
  [ -n "$ip_v6" ] && echo "    ipv6: $ip_v6"
  [ -n "$public_key" ] && echo "    public-key: $public_key"
  [ -n "$psk" ] && echo "    pre-shared-key: $psk"
  [ -n "$keepalive" ] && echo "    persistent-keepalive: $keepalive"
  [ -n "$mtu" ] && echo "    mtu: $mtu"
  local dialer_proxy_raw=$(read_cfg "DialerProxy")
  if [ -n "$dialer_proxy_raw" ]; then
    local dialer_proxy_clean=$(echo "$dialer_proxy_raw" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g; s/^["'\'']|["'\'']$//g')
    if [ -n "$dialer_proxy_clean" ]; then
      echo "    dialer-proxy: \"$dialer_proxy_clean\""
    fi
  fi
  [ -n "$workers" ] && echo "    workers: $workers"

  local reserved_raw=$(read_cfg "Reserved")
  if [ -n "$reserved_raw" ]; then
    local reserved_clean=$(echo "$reserved_raw" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g; s/^["'\'']|["'\'']$//g')
    if [ -n "$reserved_clean" ]; then
      if echo "$reserved_clean" | grep -q ','; then
        echo "    reserved: [$reserved_clean]"
      else
        echo "    reserved: \"$reserved_clean\""
      fi
    fi
  fi

  echo "    allowed-ips: [$allowed_ips_yaml]"
  echo "    udp: true"
  local dns_raw=$(read_cfg "DNS")
  if [ -n "$dns_raw" ] && ! echo "$dns_raw" | grep -q '\$'; then
    local dns_list=$(echo "$dns_raw" | tr ',' '\n' | \
      sed -E 's/^[[:space:]]+|[[:space:]]+$//g' | \
      grep -v '^$' | sed 's/.*/"&"/' | paste -sd, -)
    echo "    dns: [$dns_list]"
  fi
  local remote_resolve_raw=$(read_cfg "RemoteDnsResolve")
  if [ -n "$remote_resolve_raw" ]; then
    case "$(echo "$remote_resolve_raw" | tr '[:upper:]' '[:lower:]')" in
      1|true|yes|on)
        echo "    remote-dns-resolve: true"
        ;;
      0|false|no|off)
        echo "    remote-dns-resolve: false"
        ;;
    esac
  fi

  local awg_params="jc jmin jmax s1 s2 s3 s4 h1 h2 h3 h4 i1 i2 i3 i4 i5 j1 j2 j3 itime"
  local has_awg_param=0
  for v in i1 i2 i3 i4 i5; do
    eval val=\$$v
    case "$val" in
      \<*\>) ;;
      *) eval "$v=" ;;
    esac
  done
  for v in $awg_params; do
    eval val=\$$v
    [ -n "$val" ] && has_awg_param=1
  done

  if [ "$has_awg_param" -eq 1 ]; then
    echo "    amnezia-wg-option:"
    [ -n "$jc" ]     && echo "      jc: $jc"
    [ -n "$jmin" ]   && echo "      jmin: $jmin"
    [ -n "$jmax" ]   && echo "      jmax: $jmax"
    [ -n "$s1" ]     && echo "      s1: $s1"
    [ -n "$s2" ]     && echo "      s2: $s2"
    [ -n "$s3" ]     && echo "      s3: $s3"
    [ -n "$s4" ]     && echo "      s4: $s4"
    [ -n "$h1" ]     && echo "      h1: $h1"
    [ -n "$h2" ]     && echo "      h2: $h2"
    [ -n "$h3" ]     && echo "      h3: $h3"
    [ -n "$h4" ]     && echo "      h4: $h4"
    [ -n "$i1" ]     && printf '      i1: %s\n' "$(printf '%s' "$i1" | yaml_quote)"
    [ -n "$i2" ]     && printf '      i2: %s\n' "$(printf '%s' "$i2" | yaml_quote)"
    [ -n "$i3" ]     && printf '      i3: %s\n' "$(printf '%s' "$i3" | yaml_quote)"
    [ -n "$i4" ]     && printf '      i4: %s\n' "$(printf '%s' "$i4" | yaml_quote)"
    [ -n "$i5" ]     && printf '      i5: %s\n' "$(printf '%s' "$i5" | yaml_quote)"
    [ -n "$j1" ]     && echo "      j1: $j1"
    [ -n "$j2" ]     && echo "      j2: $j2"
    [ -n "$j3" ]     && echo "      j3: $j3"
    [ -n "$itime" ]  && echo "      itime: $itime"
  fi
  echo ""
}

json_strings_by_key() {
  local file="$1"
  local key="$2"

  awk -v key="$key" '
    {
      data = data $0 "\n"
    }
    END {
      needle = "\"" key "\""
      pos = 1
      while (pos <= length(data)) {
        rel = index(substr(data, pos), needle)
        if (rel == 0) {
          break
        }
        i = pos + rel - 1 + length(needle)
        while (i <= length(data) && substr(data, i, 1) ~ /[ \t\r\n]/) i++
        if (substr(data, i, 1) != ":") {
          pos = i + 1
          continue
        }
        i++
        while (i <= length(data) && substr(data, i, 1) ~ /[ \t\r\n]/) i++
        if (substr(data, i, 1) != "\"") {
          pos = i + 1
          continue
        }
        i++
        out = ""
        esc = 0
        for (; i <= length(data); i++) {
          c = substr(data, i, 1)
          if (esc) {
            out = out "\\" c
            esc = 0
            continue
          }
          if (c == "\\") {
            esc = 1
            continue
          }
          if (c == "\"") {
            print out
            pos = i + 1
            break
          }
          out = out c
        }
      }
    }
  ' "$file"
}

json_values_by_key() {
  local file="$1"
  local key="$2"

  awk -v key="$key" '
    {
      data = data $0 "\n"
    }
    END {
      needle = "\"" key "\""
      pos = 1
      while (pos <= length(data)) {
        rel = index(substr(data, pos), needle)
        if (rel == 0) {
          break
        }
        i = pos + rel - 1 + length(needle)
        while (i <= length(data) && substr(data, i, 1) ~ /[ \t\r\n]/) i++
        if (substr(data, i, 1) != ":") {
          pos = i + 1
          continue
        }
        i++
        while (i <= length(data) && substr(data, i, 1) ~ /[ \t\r\n]/) i++

        if (substr(data, i, 1) == "\"") {
          i++
          out = ""
          esc = 0
          for (; i <= length(data); i++) {
            c = substr(data, i, 1)
            if (esc) {
              out = out "\\" c
              esc = 0
              continue
            }
            if (c == "\\") {
              esc = 1
              continue
            }
            if (c == "\"") {
              print out
              pos = i + 1
              break
            }
            out = out c
          }
          continue
        }

        out = ""
        for (; i <= length(data); i++) {
          c = substr(data, i, 1)
          if (c == "," || c == "}" || c == "]" || c ~ /[ \t\r\n]/) {
            break
          }
          out = out c
        }
        if (out != "") {
          print out
        }
        pos = i + 1
      }
    }
  ' "$file"
}

json_unescape() {
  awk '
    {
      data = data $0 "\n"
    }
    END {
      esc = 0
      unicode = 0
      hex = ""
      for (i = 1; i <= length(data); i++) {
        c = substr(data, i, 1)
        if (unicode) {
          hex = hex c
          if (length(hex) == 4) {
            unicode = 0
            hex = ""
          }
          continue
        }
        if (esc) {
          if (c == "n") printf "\n"
          else if (c == "r") printf "\r"
          else if (c == "t") printf "\t"
          else if (c == "b") printf "\b"
          else if (c == "f") printf "\f"
          else if (c == "u") {
            unicode = 1
            hex = ""
          } else {
            printf "%s", c
          }
          esc = 0
          continue
        }
        if (c == "\\") {
          esc = 1
          continue
        }
        printf "%s", c
      }
    }
  '
}

json_get() {
  local file="$1"
  local key="$2"

  json_values_by_key "$file" "$key" | head -n1 | json_unescape | tr -d '\r'
}

json_get_line() {
  local file="$1"
  local key="$2"

  awk -v key="$key" '
    function trim(s) {
      gsub(/^[ \t\r\n]+/, "", s)
      gsub(/[ \t\r\n]+$/, "", s)
      return s
    }
    {
      line = $0
      sub(/\r$/, "", line)
      needle = "\"" key "\""
      p = index(line, needle)
      if (p == 0) {
        next
      }
      rest = substr(line, p + length(needle))
      rest = trim(rest)
      if (substr(rest, 1, 1) != ":") {
        next
      }
      rest = trim(substr(rest, 2))
      sub(/,$/, "", rest)
      rest = trim(rest)
      if (substr(rest, 1, 1) == "\"") {
        rest = substr(rest, 2)
        out = ""
        esc = 0
        for (i = 1; i <= length(rest); i++) {
          c = substr(rest, i, 1)
          if (esc) {
            out = out "\\" c
            esc = 0
            continue
          }
          if (c == "\\") {
            esc = 1
            continue
          }
          if (c == "\"") {
            print out
            exit
          }
          out = out c
        }
      } else {
        print rest
        exit
      }
    }
  ' "$file" | json_unescape | tr -d '\r'
}

json_get_line_after() {
  local file="$1"
  local marker="$2"
  local key="$3"

  awk -v marker="$marker" -v key="$key" '
    function trim(s) {
      gsub(/^[ \t\r\n]+/, "", s)
      gsub(/[ \t\r\n]+$/, "", s)
      return s
    }
    function value_from_line(line, key,    needle,p,rest,out,esc,i,c) {
      needle = "\"" key "\""
      p = index(line, needle)
      if (p == 0) {
        return ""
      }
      rest = substr(line, p + length(needle))
      rest = trim(rest)
      if (substr(rest, 1, 1) != ":") {
        return ""
      }
      rest = trim(substr(rest, 2))
      sub(/,$/, "", rest)
      rest = trim(rest)
      if (substr(rest, 1, 1) == "\"") {
        rest = substr(rest, 2)
        out = ""
        esc = 0
        for (i = 1; i <= length(rest); i++) {
          c = substr(rest, i, 1)
          if (esc) {
            out = out "\\" c
            esc = 0
            continue
          }
          if (c == "\\") {
            esc = 1
            continue
          }
          if (c == "\"") {
            return out
          }
          out = out c
        }
        return out
      }
      return rest
    }
    {
      line = $0
      sub(/\r$/, "", line)
      if (!seen && index(line, "\"" marker "\"")) {
        seen = 1
      }
      if (seen) {
        out = value_from_line(line, key)
        if (out != "") {
          print out
          exit
        }
      }
    }
  ' "$file" | json_unescape | tr -d '\r'
}

yaml_quote() {
  sed 's/\\/\\\\/g; s/"/\\"/g; s/.*/"&"/'
}

qcompress_expected_len() {
  local bin_file="$1"
  local bytes

  bytes=$(od -An -t u1 -N 4 "$bin_file" 2>/dev/null) || return 1
  set -- $bytes
  [ "$#" -eq 4 ] || return 1
  echo $((($1 * 16777216) + ($2 * 65536) + ($3 * 256) + $4))
}

decoded_vpn_json_is_complete() {
  local json_file="$1"
  local expected_len="$2"
  local actual_len

  [ -s "$json_file" ] || return 1
  actual_len=$(wc -c < "$json_file" | tr -d ' ')
  if [ "$actual_len" != "$expected_len" ]; then
    if ! grep -q '"service_type"[[:space:]]*:[[:space:]]*"amnezia-premium"' "$json_file" 2>/dev/null; then
      return 1
    fi
  fi
  awk '
    {
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if (c !~ /[ \t\r\n]/) {
          last = c
        }
      }
    }
    END {
      exit(last == "}" ? 0 : 1)
    }
  ' "$json_file" || return 1

  if grep -q '"containers"' "$json_file" 2>/dev/null && grep -q '"defaultContainer"' "$json_file" 2>/dev/null; then
    return 0
  fi

  grep -q '"service_type"[[:space:]]*:[[:space:]]*"amnezia-premium"' "$json_file" 2>/dev/null || return 1
  grep -q '"auth_data"' "$json_file" 2>/dev/null || return 1
  grep -q '"api_key"' "$json_file" 2>/dev/null || return 1
}

try_vpn_json_result() {
  local provider_name="$1"
  local method="$2"
  local json_file="$3"
  local expected_len="$4"
  local actual_len=0

  [ -f "$json_file" ] && actual_len=$(wc -c < "$json_file" | tr -d ' ')
  if decoded_vpn_json_is_complete "$json_file" "$expected_len"; then
    log "vpn:// $provider_name decoded by $method: $actual_len/$expected_len bytes"
    return 0
  fi

  log "vpn:// $provider_name $method produced incomplete JSON: $actual_len/$expected_len bytes"
  return 1
}

decode_vpn_url_to_json() {
  local url="$1"
  local out_json="$2"
  local tmp_prefix="$3"
  local provider_name="${4:-vpn}"
  local payload b64 mod
  local bin_file="${tmp_prefix}.bin"
  local zlib_file="${tmp_prefix}.zlib"
  local raw_file="${tmp_prefix}.raw"
  local gzip_file="${tmp_prefix}.gz"
  local bin_size raw_count expected_len

  payload="${url#vpn://}"
  b64=$(printf '%s' "$payload" | tr '_-' '/+')
  mod=$(( ${#b64} % 4 ))
  case "$mod" in
    2) b64="${b64}==" ;;
    3) b64="${b64}=" ;;
    1) return 1 ;;
  esac

  printf '%s' "$b64" | base64 -d > "$bin_file" 2>/dev/null || return 1
  expected_len=$(qcompress_expected_len "$bin_file") || return 1
  bin_size=$(wc -c < "$bin_file" | tr -d ' ')
  log "vpn:// $provider_name base64 ok: raw=$bin_size bytes, expected-json=$expected_len bytes"
  dd if="$bin_file" of="$zlib_file" bs=1 skip=4 >/dev/null 2>&1 || return 1

  gzip -dc "$zlib_file" > "$out_json" 2>/dev/null || true
  if try_vpn_json_result "$provider_name" "gzip-zlib" "$out_json" "$expected_len"; then
    return 0
  fi

  zcat "$zlib_file" > "$out_json" 2>/dev/null || true
  if try_vpn_json_result "$provider_name" "zcat-zlib" "$out_json" "$expected_len"; then
    return 0
  fi

  # qCompress stores a zlib stream after the 4-byte Qt length header.
  # BusyBox gzip/zcat may reject zlib headers, so wrap the raw deflate
  # payload into a tiny gzip stream. The dummy trailer makes gzip return
  # a checksum error after writing output; we accept the result if JSON
  # content was produced.
  raw_count=$((bin_size - 10))
  if [ "$raw_count" -gt 0 ]; then
    dd if="$bin_file" of="$raw_file" bs=1 skip=6 count="$raw_count" >/dev/null 2>&1 || return 1
    {
      printf '\037\213\010\000\000\000\000\000\000\003'
      cat "$raw_file"
      printf '\000\000\000\000\000\000\000\000'
    } > "$gzip_file"
    gzip -dc "$gzip_file" > "$out_json" 2>/dev/null || true
    if try_vpn_json_result "$provider_name" "gzip-raw-deflate" "$out_json" "$expected_len"; then
      return 0
    fi
  fi

  return 1
}

vpn_awg_value() {
  local last_file="$1"
  local json_file="$2"
  local key="$3"
  local value

  value=$(json_get_line "$last_file" "$key")
  [ -n "$value" ] || value=$(json_get "$last_file" "$key")
  [ -n "$value" ] || value=$(json_get "$json_file" "$key")
  printf '%s' "$value"
}

emit_vpn_wireguard_proxy() {
  local last_file="$1"
  local json_file="$2"
  local name="$3"
  local private_key client_ip server port public_key psk keepalive mtu
  local ip_v4="" ip_v6="" addr
  local jc jmin jmax s1 s2 s3 s4 h1 h2 h3 h4 i1 i2 i3 i4 i5 j1 j2 j3 itime
  local has_awg_param=0

  private_key=$(vpn_awg_value "$last_file" "$json_file" "client_priv_key")
  [ -n "$private_key" ] || private_key=$(vpn_awg_value "$last_file" "$json_file" "private_key")
  client_ip=$(vpn_awg_value "$last_file" "$json_file" "client_ip")
  server=$(vpn_awg_value "$last_file" "$json_file" "hostName")
  port=$(vpn_awg_value "$last_file" "$json_file" "port")
  public_key=$(vpn_awg_value "$last_file" "$json_file" "server_pub_key")
  [ -n "$public_key" ] || public_key=$(vpn_awg_value "$last_file" "$json_file" "public_key")
  psk=$(vpn_awg_value "$last_file" "$json_file" "psk_key")
  keepalive=$(vpn_awg_value "$last_file" "$json_file" "persistent_keep_alive")
  mtu=$(vpn_awg_value "$last_file" "$json_file" "mtu")

  [ -n "$private_key" ] || return 1
  [ -n "$client_ip" ] || return 1
  [ -n "$server" ] || return 1
  [ -n "$port" ] || return 1
  [ -n "$public_key" ] || return 1

  OLDIFS=$IFS
  IFS=','
  for addr in $client_ip; do
    addr=$(echo "$addr" | sed 's/[[:space:]]//g')
    addr=${addr%%/*}
    if echo "$addr" | grep -q ':'; then
      [ -n "$ip_v6" ] && ip_v6="$ip_v6,"
      ip_v6="${ip_v6}${addr}"
    else
      [ -n "$ip_v4" ] && ip_v4="$ip_v4,"
      ip_v4="${ip_v4}${addr}"
    fi
  done
  IFS=$OLDIFS

  [ -n "$ip_v4$ip_v6" ] || return 1

  jc=$(vpn_awg_value "$last_file" "$json_file" "Jc")
  jmin=$(vpn_awg_value "$last_file" "$json_file" "Jmin")
  jmax=$(vpn_awg_value "$last_file" "$json_file" "Jmax")
  s1=$(vpn_awg_value "$last_file" "$json_file" "S1")
  s2=$(vpn_awg_value "$last_file" "$json_file" "S2")
  s3=$(vpn_awg_value "$last_file" "$json_file" "S3")
  s4=$(vpn_awg_value "$last_file" "$json_file" "S4")
  h1=$(vpn_awg_value "$last_file" "$json_file" "H1")
  h2=$(vpn_awg_value "$last_file" "$json_file" "H2")
  h3=$(vpn_awg_value "$last_file" "$json_file" "H3")
  h4=$(vpn_awg_value "$last_file" "$json_file" "H4")
  i1=$(vpn_awg_value "$last_file" "$json_file" "I1")
  i2=$(vpn_awg_value "$last_file" "$json_file" "I2")
  i3=$(vpn_awg_value "$last_file" "$json_file" "I3")
  i4=$(vpn_awg_value "$last_file" "$json_file" "I4")
  i5=$(vpn_awg_value "$last_file" "$json_file" "I5")
  j1=$(vpn_awg_value "$last_file" "$json_file" "J1")
  j2=$(vpn_awg_value "$last_file" "$json_file" "J2")
  j3=$(vpn_awg_value "$last_file" "$json_file" "J3")
  itime=$(vpn_awg_value "$last_file" "$json_file" "ITime")

  for v in i1 i2 i3 i4 i5; do
    eval val=\$$v
    case "$val" in
      \<*\>) ;;
      *) eval "$v=" ;;
    esac
  done

  for v in jc jmin jmax s1 s2 s3 s4 h1 h2 h3 h4 i1 i2 i3 i4 i5 j1 j2 j3 itime; do
    eval val=\$$v
    [ -n "$val" ] && has_awg_param=1
  done

  echo "  - name: \"$name\""
  echo "    type: wireguard"
  echo "    private-key: $private_key"
  echo "    server: $server"
  echo "    port: $port"
  [ -n "$ip_v4" ] && echo "    ip: $ip_v4"
  [ -n "$ip_v6" ] && echo "    ipv6: $ip_v6"
  echo "    public-key: $public_key"
  [ -n "$psk" ] && echo "    pre-shared-key: $psk"
  [ -n "$keepalive" ] && echo "    persistent-keepalive: $keepalive"
  [ -n "$mtu" ] && echo "    mtu: $mtu"
  echo "    allowed-ips: [\"0.0.0.0/0\", \"::/0\"]"
  echo "    udp: true"

  if [ "$has_awg_param" -eq 1 ]; then
    echo "    amnezia-wg-option:"
    [ -n "$jc" ]     && echo "      jc: $jc"
    [ -n "$jmin" ]   && echo "      jmin: $jmin"
    [ -n "$jmax" ]   && echo "      jmax: $jmax"
    [ -n "$s1" ]     && echo "      s1: $s1"
    [ -n "$s2" ]     && echo "      s2: $s2"
    [ -n "$s3" ]     && echo "      s3: $s3"
    [ -n "$s4" ]     && echo "      s4: $s4"
    [ -n "$h1" ]     && echo "      h1: $h1"
    [ -n "$h2" ]     && echo "      h2: $h2"
    [ -n "$h3" ]     && echo "      h3: $h3"
    [ -n "$h4" ]     && echo "      h4: $h4"
    [ -n "$i1" ]     && printf '      i1: %s\n' "$(printf '%s' "$i1" | yaml_quote)"
    [ -n "$i2" ]     && printf '      i2: %s\n' "$(printf '%s' "$i2" | yaml_quote)"
    [ -n "$i3" ]     && printf '      i3: %s\n' "$(printf '%s' "$i3" | yaml_quote)"
    [ -n "$i4" ]     && printf '      i4: %s\n' "$(printf '%s' "$i4" | yaml_quote)"
    [ -n "$i5" ]     && printf '      i5: %s\n' "$(printf '%s' "$i5" | yaml_quote)"
    [ -n "$j1" ]     && echo "      j1: $j1"
    [ -n "$j2" ]     && echo "      j2: $j2"
    [ -n "$j3" ]     && echo "      j3: $j3"
    [ -n "$itime" ]  && echo "      itime: $itime"
  fi
  echo ""
}

emit_vpn_xray_vless_proxy() {
  local last_file="$1"
  local name="$2"
  local server port uuid flow network security fingerprint servername public_key short_id spider_x

  grep -q '"protocol"[[:space:]]*:[[:space:]]*"vless"' "$last_file" 2>/dev/null || return 1

  server=$(json_get_line "$last_file" "address")
  port=$(json_get_line_after "$last_file" "address" "port")
  uuid=$(json_get_line "$last_file" "id")
  flow=$(json_get_line "$last_file" "flow")
  network=$(json_get_line "$last_file" "network")
  security=$(json_get_line "$last_file" "security")
  fingerprint=$(json_get_line "$last_file" "fingerprint")
  servername=$(json_get_line "$last_file" "serverName")
  public_key=$(json_get_line "$last_file" "publicKey")
  short_id=$(json_get_line "$last_file" "shortId")
  spider_x=$(json_get_line "$last_file" "spiderX")

  [ -n "$server" ] || return 1
  [ -n "$port" ] || return 1
  [ -n "$uuid" ] || return 1

  echo "  - name: \"$name\""
  echo "    type: vless"
  echo "    server: $server"
  echo "    port: $port"
  echo "    uuid: $uuid"
  [ -n "$network" ] && echo "    network: $network"
  [ -n "$flow" ] && echo "    flow: $flow"
  echo "    udp: true"

  case "$security" in
    tls|reality)
      echo "    tls: true"
      ;;
  esac

  [ -n "$servername" ] && echo "    servername: $servername"
  [ -n "$fingerprint" ] && echo "    client-fingerprint: $fingerprint"

  if [ "$security" = "reality" ]; then
    [ -n "$public_key" ] || return 1
    echo "    reality-opts:"
    echo "      public-key: $public_key"
    [ -n "$short_id" ] && echo "      short-id: $short_id"
    [ -n "$spider_x" ] && printf '      spider-x: %s\n' "$(printf '%s' "$spider_x" | yaml_quote)"
  fi
  echo ""
}

vpn_json_is_amnezia_premium() {
  local json_file="$1"

  grep -q '"service_type"[[:space:]]*:[[:space:]]*"amnezia-premium"' "$json_file" 2>/dev/null || return 1
  grep -q '"auth_data"' "$json_file" 2>/dev/null || return 1
  grep -q '"api_key"' "$json_file" 2>/dev/null || return 1
}

amnezia_bool_true() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

amnezia_provider_env() {
  local provider_name="$1"
  local suffix="$2"
  local fallback="${3:-}"
  local value

  value=$(printenv "${provider_name}_${suffix}" 2>/dev/null || true)
  [ -n "$value" ] || value="$fallback"
  printf '%s' "$value"
}

amnezia_uuid_file() {
  local file="$1"

  if [ ! -s "$file" ]; then
    mkdir -p "$(dirname "$file")"
    if [ -r /proc/sys/kernel/random/uuid ]; then
      cat /proc/sys/kernel/random/uuid > "$file"
    else
      od -An -N16 -tx1 /dev/urandom | tr -d ' \n' | \
        sed -E 's/^(.{8})(.{4})(.{4})(.{4})(.{12})$/\1-\2-\3-\4-\5/' > "$file"
    fi
  fi

  cat "$file"
}

amnezia_random_uuid() {
  if [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
  else
    od -An -N16 -tx1 /dev/urandom | tr -d ' \n' | \
      sed -E 's/^(.{8})(.{4})(.{4})(.{4})(.{12})$/\1-\2-\3-\4-\5/'
  fi
}

amnezia_premium_gateway_public_key() {
  if [ -n "$AMNEZIA_PREMIUM_PUBLIC_KEY_FILE" ] && [ -s "$AMNEZIA_PREMIUM_PUBLIC_KEY_FILE" ]; then
    cat "$AMNEZIA_PREMIUM_PUBLIC_KEY_FILE"
    return
  fi

  return 1
}

amnezia_base64_file() {
  base64 "$1" | tr -d '\r\n'
}

amnezia_hex_file() {
  od -An -tx1 -v "$1" | tr -d ' \r\n'
}

amnezia_generate_wg_keys() {
  local state_dir="$1"
  local pem_file="$state_dir/x25519.pem"
  local priv_der="$state_dir/private.der"
  local pub_der="$state_dir/public.der"

  if [ -s "$state_dir/privatekey" ] && [ -s "$state_dir/publickey" ]; then
    return 0
  fi

  command -v openssl >/dev/null 2>&1 || return 1
  mkdir -p "$state_dir"
  openssl genpkey -algorithm X25519 -out "$pem_file" >/dev/null 2>&1 || { rm -f "$pem_file" "$priv_der" "$pub_der"; return 1; }
  openssl pkey -in "$pem_file" -outform DER -out "$priv_der" >/dev/null 2>&1 || { rm -f "$pem_file" "$priv_der" "$pub_der"; return 1; }
  openssl pkey -in "$pem_file" -pubout -outform DER -out "$pub_der" >/dev/null 2>&1 || { rm -f "$pem_file" "$priv_der" "$pub_der"; return 1; }
  tail -c 32 "$priv_der" | base64 | tr -d '\r\n' > "$state_dir/privatekey"
  tail -c 32 "$pub_der" | base64 | tr -d '\r\n' > "$state_dir/publickey"
  rm -f "$pem_file" "$priv_der" "$pub_der"
}

amnezia_premium_cleanup_tmp() {
  local state_dir="$1"

  rm -f "$state_dir/.aes.key" "$state_dir/.aes.iv" "$state_dir/.aes.salt" \
    "$state_dir/.payload.json" "$state_dir/.key.json" "$state_dir/.gateway.pem" \
    "$state_dir/.key_payload.bin" "$state_dir/.api_payload.bin" "$state_dir/.request.json" \
    "$state_dir/.response.bin" "$state_dir/.response.json" "$state_dir/.native.conf" \
    "$state_dir/.native.conf.new" "$state_dir/.proxy_endpoints.b64" \
    "$state_dir/.proxy_endpoints.bin" "$state_dir/.proxy_endpoints.json"
}

amnezia_timeout_cmd() {
  local seconds="$1"
  shift

  if command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" "$@"
  else
    "$@"
  fi
}

amnezia_parse_ipv4() {
  awk '
    {
      line = $0
      gsub(/[^0-9.]/, " ", line)
      n = split(line, parts, /[[:space:]]+/)
      for (i = 1; i <= n; i++) {
        if (parts[i] ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) print parts[i]
      }
    }
  '
}

amnezia_resolve_doh() {
  local host="$1"
  local spec ip sni path out tmp_path seen=""

  command -v openssl >/dev/null 2>&1 || return 0
  for spec in $AMNEZIA_PREMIUM_DOH_SERVERS; do
    ip="${spec%%|*}"
    spec="${spec#*|}"
    sni="${spec%%|*}"
    path="${spec#*|}"
    tmp_path=$(printf '%s' "$path" | sed "s/%s/$host/g")
    out=$(
      {
        printf 'GET %s HTTP/1.1\r\n' "$tmp_path"
        printf 'Host: %s\r\n' "$sni"
        printf 'Accept: application/dns-json\r\n'
        printf 'Connection: close\r\n'
        printf '\r\n'
      } | amnezia_timeout_cmd "$AMNEZIA_PREMIUM_HTTP_TIMEOUT" \
        openssl s_client -quiet -connect "$ip:443" -servername "$sni" \
          -verify_return_error -verify_hostname "$sni" 2>/dev/null || true
    )
    for resolved in $(printf '%s\n' "$out" | amnezia_parse_ipv4); do
      [ "$resolved" = "$ip" ] && continue
      case " $seen " in *" $resolved "*) continue ;; esac
      seen="$seen $resolved"
      log "Amnezia Premium resolved $host via DoH $sni@$ip: $resolved" >&2
      printf '%s\n' "$resolved"
    done
  done
}

amnezia_resolve_public_dns() {
  local host="$1"
  local dns out ip seen=""

  for ip in $(amnezia_resolve_doh "$host"); do
    case " $seen " in *" $ip "*) continue ;; esac
    seen="$seen $ip"
    printf '%s\n' "$ip"
  done

  command -v nslookup >/dev/null 2>&1 || return 0
  for dns in $AMNEZIA_PREMIUM_DNS_SERVERS; do
    out=$(amnezia_timeout_cmd "$AMNEZIA_PREMIUM_DNS_TIMEOUT" nslookup "$host" "$dns" 2>/dev/null || true)
    for ip in $(printf '%s\n' "$out" | awk '
      {
        for (i = 1; i <= NF; i++) {
          if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) print $i
        }
      }
    '); do
      [ "$ip" = "$dns" ] && continue
      case " $seen " in *" $ip "*) continue ;; esac
      seen="$seen $ip"
      log "Amnezia Premium resolved $host via DNS $dns: $ip" >&2
      printf '%s\n' "$ip"
    done
  done
}

amnezia_base64url_text() {
  printf '%s' "$1" | base64 | tr -d '=\r\n' | tr '+/' '-_'
}

amnezia_gateway_public_key_text() {
  amnezia_premium_gateway_public_key | sed 's/\r$//' | awk '{ if (NR > 1) printf "\n"; printf "%s", $0 }'
}

amnezia_proxy_storage_paths() {
  local service_type="$1"
  local user_country_code="$2"
  local storage_name

  if [ -n "$service_type" ] && [ -n "$user_country_code" ]; then
    storage_name="endpoints-$service_type-$user_country_code"
    printf '%s.json\n' "$(amnezia_base64url_text "$storage_name")"
  fi
  printf '%s\n' "endpoints.json"
}

amnezia_proxy_urls() {
  local state_dir="$1"
  local service_type="$2"
  local user_country_code="$3"
  local base_url path url enc_file bin_file json_file key_hash key_hex iv_hex endpoint seen=""

  enc_file="$state_dir/.proxy_endpoints.b64"
  bin_file="$state_dir/.proxy_endpoints.bin"
  json_file="$state_dir/.proxy_endpoints.json"
  key_hash=$(amnezia_gateway_public_key_text | openssl dgst -sha512 -hex 2>/dev/null | awk '{print $NF}')
  [ -n "$key_hash" ] || return 0
  key_hex=$(printf '%s' "$key_hash" | cut -c1-64)
  iv_hex=$(printf '%s' "$key_hash" | cut -c65-96)

  for path in $(amnezia_proxy_storage_paths "$service_type" "$user_country_code"); do
    for base_url in $AMNEZIA_PREMIUM_PROXY_STORAGE_URLS; do
      url="${base_url%/}/$path"
      rm -f "$enc_file" "$bin_file" "$json_file"
      amnezia_timeout_cmd "$AMNEZIA_PREMIUM_HTTP_TIMEOUT" wget -q -T "$AMNEZIA_PREMIUM_DNS_TIMEOUT" -O "$enc_file" "$url" 2>/dev/null || true
      [ -s "$enc_file" ] || continue
      base64 -d "$enc_file" > "$bin_file" 2>/dev/null || continue
      openssl enc -d -aes-256-cbc -K "$key_hex" -iv "$iv_hex" \
        -in "$bin_file" -out "$json_file" >/dev/null 2>&1 || continue
      [ -s "$json_file" ] || continue
      log "Amnezia Premium loaded proxy endpoints from $url" >&2
      for endpoint in $(tr '",' '\012' < "$json_file" | grep -E '^https?://' 2>/dev/null); do
        case " $seen " in *" $endpoint "*) continue ;; esac
        seen="$seen $endpoint"
        printf '%s\n' "$endpoint"
      done
      [ -n "$seen" ] && return 0
    done
  done
}

amnezia_http_post() {
  local url="$1"
  local body_file="$2"
  local out_file="$3"
  local request_id="$4"
  local state_dir="${5:-}"
  local service_type="${6:-}"
  local user_country_code="${7:-}"
  local tmp_http="${out_file}.http"
  local proto rest host port path body_len status ip resolved_url resolved_any proxy_url proxy_endpoint
  local active_proxy_file active_proxy_url

  rm -f "$out_file" "$tmp_http"
  case "$url" in
    http://*) proto="http"; rest="${url#http://}" ;;
    https://*) proto="https"; rest="${url#https://}" ;;
    *) return 1 ;;
  esac
  host="${rest%%/*}"
  path="/${rest#*/}"
  [ "$path" = "/$rest" ] && path="/"
  case "$host" in
    *:*) port="${host##*:}"; host="${host%%:*}" ;;
    *) [ "$proto" = "https" ] && port=443 || port=80 ;;
  esac

  status=1
  active_proxy_file="$state_dir/active_proxy_endpoint"
  if [ -n "$state_dir" ] && [ -s "$active_proxy_file" ]; then
    active_proxy_url=$(head -n 1 "$active_proxy_file" | tr -d '\r\n')
    if [ -n "$active_proxy_url" ]; then
      rm -f "$out_file"
      proxy_endpoint="${active_proxy_url%/}$path"
      log "Amnezia Premium trying cached gateway proxy $active_proxy_url"
      amnezia_timeout_cmd "$AMNEZIA_PREMIUM_HTTP_TIMEOUT" wget -q -T "$AMNEZIA_PREMIUM_HTTP_TIMEOUT" -O "$out_file" \
        --header="Content-Type: application/json" \
        --header="X-Client-Request-ID: $request_id" \
        --post-data="$(cat "$body_file")" "$proxy_endpoint" 2>/dev/null
      status=$?
      if [ "$status" -eq 0 ] || [ -s "$out_file" ]; then
        return "$status"
      fi
      rm -f "$active_proxy_file"
      log "Warning: Amnezia Premium cached gateway proxy failed, probing gateway paths"
    fi
  fi

  if [ "$proto" = "http" ]; then
    resolved_any=0
    for ip in $(amnezia_resolve_public_dns "$host"); do
      resolved_any=1
      rm -f "$out_file"
      resolved_url="$proto://$ip:$port$path"
      log "Amnezia Premium trying gateway $host via $ip"
      amnezia_timeout_cmd "$AMNEZIA_PREMIUM_HTTP_TIMEOUT" wget -q -T "$AMNEZIA_PREMIUM_HTTP_TIMEOUT" -O "$out_file" \
        --header="Host: $host" \
        --header="Content-Type: application/json" \
        --header="X-Client-Request-ID: $request_id" \
        --post-data="$(cat "$body_file")" "$resolved_url" 2>/dev/null
      status=$?
      if [ "$status" -eq 0 ] || [ -s "$out_file" ]; then
        [ -n "$state_dir" ] && rm -f "$active_proxy_file"
        return "$status"
      fi
    done
    [ "$resolved_any" -eq 0 ] && log "Warning: Amnezia Premium could not resolve $host via DoH/public DNS fallback"
  fi

  if [ -n "$state_dir" ]; then
    for proxy_url in $(amnezia_proxy_urls "$state_dir" "$service_type" "$user_country_code"); do
      rm -f "$out_file"
      proxy_endpoint="${proxy_url%/}$path"
      log "Amnezia Premium trying gateway proxy $proxy_url"
      amnezia_timeout_cmd "$AMNEZIA_PREMIUM_HTTP_TIMEOUT" wget -q -T "$AMNEZIA_PREMIUM_HTTP_TIMEOUT" -O "$out_file" \
        --header="Content-Type: application/json" \
        --header="X-Client-Request-ID: $request_id" \
        --post-data="$(cat "$body_file")" "$proxy_endpoint" 2>/dev/null
      status=$?
      if [ "$status" -eq 0 ] || [ -s "$out_file" ]; then
        printf '%s\n' "$proxy_url" > "$active_proxy_file"
        return "$status"
      fi
    done
  fi

  rm -f "$out_file"
  log "Amnezia Premium trying gateway $host via system DNS"
  amnezia_timeout_cmd "$AMNEZIA_PREMIUM_HTTP_TIMEOUT" wget -q -T "$AMNEZIA_PREMIUM_HTTP_TIMEOUT" -O "$out_file" \
    --header="Content-Type: application/json" \
    --header="X-Client-Request-ID: $request_id" \
    --post-data="$(cat "$body_file")" "$url" 2>/dev/null
  status=$?
  if [ "$status" -eq 0 ] || [ -s "$out_file" ]; then
    [ -n "$state_dir" ] && rm -f "$active_proxy_file"
    return "$status"
  fi

  body_len=$(wc -c < "$body_file" | tr -d ' ')

  if [ "$proto" = "https" ]; then
    {
      printf 'POST %s HTTP/1.1\r\n' "$path"
      printf 'Host: %s\r\n' "$host"
      printf 'Content-Type: application/json\r\n'
      printf 'X-Client-Request-ID: %s\r\n' "$request_id"
      printf 'Content-Length: %s\r\n' "$body_len"
      printf 'Connection: close\r\n'
      printf '\r\n'
      cat "$body_file"
    } |
    amnezia_timeout_cmd "$AMNEZIA_PREMIUM_HTTP_TIMEOUT" openssl s_client -quiet -connect "$host:$port" -servername "$host" 2>/dev/null
  fi > "$tmp_http" 2>/dev/null || true

  if [ ! -s "$tmp_http" ] && [ "$proto" = "http" ]; then
    # BusyBox nc is not guaranteed, but use it if present because openssl
    # cannot speak plain HTTP without a TLS peer.
    if command -v nc >/dev/null 2>&1; then
      {
        printf 'POST %s HTTP/1.1\r\n' "$path"
        printf 'Host: %s\r\n' "$host"
        printf 'Content-Type: application/json\r\n'
        printf 'X-Client-Request-ID: %s\r\n' "$request_id"
        printf 'Content-Length: %s\r\n' "$body_len"
        printf 'Connection: close\r\n'
        printf '\r\n'
        cat "$body_file"
      } | amnezia_timeout_cmd "$AMNEZIA_PREMIUM_HTTP_TIMEOUT" nc "$host" "$port" > "$tmp_http" 2>/dev/null || true
    fi
  fi

  if [ -s "$tmp_http" ]; then
    awk '{ line=$0; sub(/\r$/, "", line); if (body) print $0; if (line == "") body=1 }' "$tmp_http" > "$out_file"
  fi
  return "$status"
}

amnezia_premium_revoke_native_config() {
  local provider_name="$1"
  local state_dir="$2"
  local api_key="$3"
  local service_protocol="$4"
  local user_country_code="$5"
  local server_country_code="$6"
  local uuid key_bin iv_bin salt_bin key_hex iv_hex key_b64 iv_b64 salt_b64
  local payload_json key_json pub_pem key_payload_bin api_payload_bin
  local key_payload api_payload req_json response_bin response_json gateway endpoint
  local request_id http_status response_size

  [ -n "$server_country_code" ] || return 0
  command -v openssl >/dev/null 2>&1 || return 1
  command -v wget >/dev/null 2>&1 || return 1

  uuid=$(amnezia_uuid_file "$state_dir/installation_uuid")
  key_bin="$state_dir/.aes.key"
  iv_bin="$state_dir/.aes.iv"
  salt_bin="$state_dir/.aes.salt"
  payload_json="$state_dir/.payload.json"
  key_json="$state_dir/.key.json"
  pub_pem="$state_dir/.gateway.pem"
  key_payload_bin="$state_dir/.key_payload.bin"
  api_payload_bin="$state_dir/.api_payload.bin"
  req_json="$state_dir/.request.json"
  response_bin="$state_dir/.response.bin"
  response_json="$state_dir/.response.json"
  amnezia_premium_cleanup_tmp "$state_dir"

  openssl rand 32 > "$key_bin" || { amnezia_premium_cleanup_tmp "$state_dir"; return 1; }
  openssl rand 32 > "$iv_bin" || { amnezia_premium_cleanup_tmp "$state_dir"; return 1; }
  openssl rand 8 > "$salt_bin" || { amnezia_premium_cleanup_tmp "$state_dir"; return 1; }
  key_hex=$(amnezia_hex_file "$key_bin")
  iv_hex=$(od -An -tx1 -N 16 -v "$iv_bin" | tr -d ' \r\n')
  key_b64=$(amnezia_base64_file "$key_bin")
  iv_b64=$(amnezia_base64_file "$iv_bin")
  salt_b64=$(amnezia_base64_file "$salt_bin")

  cat > "$payload_json" <<EOF
{"os_version":"$AMNEZIA_PREMIUM_OS_VERSION","app_version":"$AMNEZIA_PREMIUM_APP_VERSION","app_language":"$AMNEZIA_PREMIUM_APP_LANGUAGE","installation_uuid":"$uuid","user_country_code":"$user_country_code","server_country_code":"$server_country_code","service_type":"amnezia-premium","service_protocol":"$service_protocol","auth_data":{"api_key":"$api_key"}}
EOF
  cat > "$key_json" <<EOF
{"aes_key":"$key_b64","aes_iv":"$iv_b64","aes_salt":"$salt_b64"}
EOF
  amnezia_premium_gateway_public_key > "$pub_pem" || {
    log "ERROR: $provider_name Amnezia Premium gateway public key is missing: $AMNEZIA_PREMIUM_PUBLIC_KEY_FILE"
    amnezia_premium_cleanup_tmp "$state_dir"
    return 1
  }

  openssl pkeyutl -encrypt -pubin -inkey "$pub_pem" -pkeyopt rsa_padding_mode:pkcs1 \
    -in "$key_json" -out "$key_payload_bin" >/dev/null 2>&1 || { amnezia_premium_cleanup_tmp "$state_dir"; return 1; }
  openssl enc -aes-256-cbc -K "$key_hex" -iv "$iv_hex" -nosalt \
    -in "$payload_json" -out "$api_payload_bin" >/dev/null 2>&1 || { amnezia_premium_cleanup_tmp "$state_dir"; return 1; }

  key_payload=$(amnezia_base64_file "$key_payload_bin")
  api_payload=$(amnezia_base64_file "$api_payload_bin")
  printf '{"key_payload":"%s","api_payload":"%s"}' "$key_payload" "$api_payload" > "$req_json"

  gateway="${AMNEZIA_PREMIUM_GATEWAY%/}"
  endpoint="$gateway/v1/revoke_native_config"
  log "Revoking old Amnezia Premium native config for $provider_name: country=$server_country_code"
  request_id="$uuid"
  amnezia_http_post "$endpoint" "$req_json" "$response_bin" "$request_id" "$state_dir" "amnezia-premium" "$user_country_code"
  http_status=$?
  response_size=0
  [ -e "$response_bin" ] && response_size=$(wc -c < "$response_bin" 2>/dev/null | tr -d ' ')
  if [ "$http_status" -ne 0 ]; then
    log "Warning: $provider_name Amnezia Premium revoke request failed: wget_status=$http_status response_bytes=${response_size:-0}"
    if [ ! -s "$response_bin" ]; then
      amnezia_premium_cleanup_tmp "$state_dir"
      return 1
    fi
  fi

  openssl enc -d -aes-256-cbc -K "$key_hex" -iv "$iv_hex" -nosalt \
    -in "$response_bin" -out "$response_json" >/dev/null 2>&1 || true
  if [ -s "$response_json" ] && grep -q '"http_status"' "$response_json" 2>/dev/null; then
    if grep -q '"http_status"[[:space:]]*:[[:space:]]*200' "$response_json" 2>/dev/null; then
      log "Revoked old Amnezia Premium native config for $provider_name: country=$server_country_code"
    fi
    if ! grep -q '"http_status"[[:space:]]*:[[:space:]]*\(200\|404\)' "$response_json" 2>/dev/null; then
      log "Warning: $provider_name Amnezia Premium revoke returned: $(tr -d '\r\n' < "$response_json" | cut -c1-220)"
    fi
  fi

  amnezia_premium_cleanup_tmp "$state_dir"
}

amnezia_premium_post_native_config() {
  local provider_name="$1"
  local state_dir="$2"
  local api_key="$3"
  local service_protocol="$4"
  local user_country_code="$5"
  local server_country_code="$6"
  local out_conf="$7"
  local endpoint gateway uuid private_key public_key key_hash key_hash_file old_country old_key_hash key_work_dir
  local cache_valid refresh_existing
  local key_bin iv_bin salt_bin key_hex iv_hex key_b64 iv_b64 salt_b64
  local payload_json key_json pub_pem key_payload_bin api_payload_bin
  local key_payload api_payload req_json response_bin response_json config_tmp out_tmp
  local request_id http_status response_size

  command -v openssl >/dev/null 2>&1 || { log "ERROR: $provider_name Amnezia Premium requires openssl"; return 1; }
  command -v wget >/dev/null 2>&1 || { log "ERROR: $provider_name Amnezia Premium requires wget"; return 1; }

  mkdir -p "$state_dir"
  amnezia_premium_cleanup_tmp "$state_dir"
  rm -rf "$state_dir/.next_keys"
  key_work_dir=""
  uuid=$(amnezia_uuid_file "$state_dir/installation_uuid")
  amnezia_generate_wg_keys "$state_dir" || { log "ERROR: $provider_name failed to generate X25519 keys"; return 1; }
  private_key=$(cat "$state_dir/privatekey")
  public_key=$(cat "$state_dir/publickey")

  key_hash=$(printf '%s|%s|%s|%s|%s|%s|rotating-key-v1' "$api_key" "$service_protocol" "$user_country_code" "$server_country_code" "$uuid" "$public_key" | openssl dgst -sha256 2>/dev/null | awk '{print $NF}')
  key_hash_file="$state_dir/api_key.sha256"
  old_key_hash=$(cat "$key_hash_file" 2>/dev/null || true)
  cache_valid=false
  if [ -s "$out_conf" ] && [ -n "$old_key_hash" ] && [ "$old_key_hash" = "$key_hash" ]; then
    cache_valid=true
  fi
  if amnezia_bool_true "$cache_valid"; then
    log "Using cached Amnezia Premium native config for $provider_name"
    return 0
  fi

  old_country=$(cat "$state_dir/server_country_code" 2>/dev/null || true)
  refresh_existing=false
  if [ -s "$out_conf" ]; then
    if [ "$old_country" != "$server_country_code" ] || [ "$old_key_hash" != "$key_hash" ]; then
      refresh_existing=true
    fi
  fi

  if amnezia_bool_true "$refresh_existing"; then
    key_work_dir="$state_dir/.next_keys"
    rm -rf "$key_work_dir"
    mkdir -p "$key_work_dir"
    amnezia_generate_wg_keys "$key_work_dir" || { rm -rf "$key_work_dir"; log "ERROR: $provider_name failed to rotate X25519 keys"; return 1; }
    private_key=$(cat "$key_work_dir/privatekey")
    public_key=$(cat "$key_work_dir/publickey")
    key_hash=$(printf '%s|%s|%s|%s|%s|%s|rotating-key-v1' "$api_key" "$service_protocol" "$user_country_code" "$server_country_code" "$uuid" "$public_key" | openssl dgst -sha256 2>/dev/null | awk '{print $NF}')
    log "Prepared new Amnezia Premium keypair for $provider_name"
  fi

  key_bin="$state_dir/.aes.key"
  iv_bin="$state_dir/.aes.iv"
  salt_bin="$state_dir/.aes.salt"
  payload_json="$state_dir/.payload.json"
  key_json="$state_dir/.key.json"
  pub_pem="$state_dir/.gateway.pem"
  key_payload_bin="$state_dir/.key_payload.bin"
  api_payload_bin="$state_dir/.api_payload.bin"
  req_json="$state_dir/.request.json"
  response_bin="$state_dir/.response.bin"
  response_json="$state_dir/.response.json"
  config_tmp="$state_dir/.native.conf"
  out_tmp="$state_dir/.native.conf.new"
  amnezia_premium_cleanup_tmp "$state_dir"
  rm -f "$out_tmp"

  openssl rand 32 > "$key_bin" || { [ -n "$key_work_dir" ] && rm -rf "$key_work_dir"; amnezia_premium_cleanup_tmp "$state_dir"; return 1; }
  openssl rand 32 > "$iv_bin" || { [ -n "$key_work_dir" ] && rm -rf "$key_work_dir"; amnezia_premium_cleanup_tmp "$state_dir"; return 1; }
  openssl rand 8 > "$salt_bin" || { [ -n "$key_work_dir" ] && rm -rf "$key_work_dir"; amnezia_premium_cleanup_tmp "$state_dir"; return 1; }
  key_hex=$(amnezia_hex_file "$key_bin")
  iv_hex=$(od -An -tx1 -N 16 -v "$iv_bin" | tr -d ' \r\n')
  key_b64=$(amnezia_base64_file "$key_bin")
  iv_b64=$(amnezia_base64_file "$iv_bin")
  salt_b64=$(amnezia_base64_file "$salt_bin")

  cat > "$payload_json" <<EOF
{"os_version":"$AMNEZIA_PREMIUM_OS_VERSION","app_version":"$AMNEZIA_PREMIUM_APP_VERSION","app_language":"$AMNEZIA_PREMIUM_APP_LANGUAGE","installation_uuid":"$uuid","user_country_code":"$user_country_code","server_country_code":"$server_country_code","service_type":"amnezia-premium","service_protocol":"$service_protocol","auth_data":{"api_key":"$api_key"},"public_key":"$public_key"}
EOF
  cat > "$key_json" <<EOF
{"aes_key":"$key_b64","aes_iv":"$iv_b64","aes_salt":"$salt_b64"}
EOF
  amnezia_premium_gateway_public_key > "$pub_pem" || {
    log "ERROR: $provider_name Amnezia Premium gateway public key is missing: $AMNEZIA_PREMIUM_PUBLIC_KEY_FILE"
    [ -n "$key_work_dir" ] && rm -rf "$key_work_dir"
    amnezia_premium_cleanup_tmp "$state_dir"
    return 1
  }

  openssl pkeyutl -encrypt -pubin -inkey "$pub_pem" -pkeyopt rsa_padding_mode:pkcs1 \
    -in "$key_json" -out "$key_payload_bin" >/dev/null 2>&1 || { [ -n "$key_work_dir" ] && rm -rf "$key_work_dir"; amnezia_premium_cleanup_tmp "$state_dir"; return 1; }
  openssl enc -aes-256-cbc -K "$key_hex" -iv "$iv_hex" -nosalt \
    -in "$payload_json" -out "$api_payload_bin" >/dev/null 2>&1 || { [ -n "$key_work_dir" ] && rm -rf "$key_work_dir"; amnezia_premium_cleanup_tmp "$state_dir"; return 1; }

  key_payload=$(amnezia_base64_file "$key_payload_bin")
  api_payload=$(amnezia_base64_file "$api_payload_bin")
  printf '{"key_payload":"%s","api_payload":"%s"}' "$key_payload" "$api_payload" > "$req_json"

  gateway="${AMNEZIA_PREMIUM_GATEWAY%/}"
  endpoint="$gateway/v1/native_config"
  log "Requesting Amnezia Premium native config for $provider_name: country=${server_country_code:-auto}"
  request_id="$uuid"
  amnezia_http_post "$endpoint" "$req_json" "$response_bin" "$request_id" "$state_dir" "amnezia-premium" "$user_country_code"
  http_status=$?
  response_size=0
  [ -e "$response_bin" ] && response_size=$(wc -c < "$response_bin" 2>/dev/null | tr -d ' ')
  if [ "$http_status" -ne 0 ]; then
    log "ERROR: $provider_name Amnezia Premium gateway request failed: wget_status=$http_status response_bytes=${response_size:-0}"
    if [ ! -s "$response_bin" ]; then
      if [ -s "$out_conf" ]; then
        log "Warning: $provider_name keeping cached Amnezia Premium native config after gateway request failure"
        rm -f "$out_tmp"
        [ -n "$key_work_dir" ] && rm -rf "$key_work_dir"
        amnezia_premium_cleanup_tmp "$state_dir"
        return 0
      fi
      [ -n "$key_work_dir" ] && rm -rf "$key_work_dir"
      amnezia_premium_cleanup_tmp "$state_dir"
      return 1
    fi
  fi

  openssl enc -d -aes-256-cbc -K "$key_hex" -iv "$iv_hex" -nosalt \
    -in "$response_bin" -out "$response_json" >/dev/null 2>&1 || {
    log "ERROR: $provider_name Amnezia Premium response decrypt failed: response_bytes=${response_size:-0} preview=$(tr -cd '[:print:]\r\n\t' < "$response_bin" | tr -d '\r\n' | cut -c1-220)"
    if [ -s "$out_conf" ]; then
      log "Warning: $provider_name keeping cached Amnezia Premium native config after decrypt failure"
      rm -f "$out_tmp"
      [ -n "$key_work_dir" ] && rm -rf "$key_work_dir"
      amnezia_premium_cleanup_tmp "$state_dir"
      return 0
    fi
    [ -n "$key_work_dir" ] && rm -rf "$key_work_dir"
    amnezia_premium_cleanup_tmp "$state_dir"
    return 1
  }

  if grep -q '"http_status"' "$response_json" 2>/dev/null && \
    ! grep -q '"http_status"[[:space:]]*:[[:space:]]*\(200\|201\)' "$response_json" 2>/dev/null; then
    log "ERROR: $provider_name Amnezia Premium gateway error: $(tr -d '\r\n' < "$response_json" | cut -c1-220)"
    if [ -s "$out_conf" ]; then
      log "Warning: $provider_name keeping cached Amnezia Premium native config after gateway error"
      rm -f "$out_tmp"
      [ -n "$key_work_dir" ] && rm -rf "$key_work_dir"
      amnezia_premium_cleanup_tmp "$state_dir"
      return 0
    fi
    [ -n "$key_work_dir" ] && rm -rf "$key_work_dir"
    amnezia_premium_cleanup_tmp "$state_dir"
    return 1
  fi

  json_get "$response_json" "config" > "$config_tmp"
  if [ ! -s "$config_tmp" ]; then
    log "ERROR: $provider_name Amnezia Premium response has no native config"
    if [ -s "$out_conf" ]; then
      log "Warning: $provider_name keeping cached Amnezia Premium native config after empty response"
      rm -f "$out_tmp"
      [ -n "$key_work_dir" ] && rm -rf "$key_work_dir"
      amnezia_premium_cleanup_tmp "$state_dir"
      return 0
    fi
    rm -f "$out_tmp"
    [ -n "$key_work_dir" ] && rm -rf "$key_work_dir"
    amnezia_premium_cleanup_tmp "$state_dir"
    return 1
  fi

  sed "s|\$WIREGUARD_CLIENT_PRIVATE_KEY|$private_key|g" "$config_tmp" > "$out_tmp"
  if [ ! -s "$out_tmp" ]; then
    log "ERROR: $provider_name Amnezia Premium rendered native config is empty"
    if [ -s "$out_conf" ]; then
      log "Warning: $provider_name keeping cached Amnezia Premium native config after render failure"
      rm -f "$out_tmp"
      [ -n "$key_work_dir" ] && rm -rf "$key_work_dir"
      amnezia_premium_cleanup_tmp "$state_dir"
      return 0
    fi
    rm -f "$out_tmp"
    [ -n "$key_work_dir" ] && rm -rf "$key_work_dir"
    amnezia_premium_cleanup_tmp "$state_dir"
    return 1
  fi
  mv "$out_tmp" "$out_conf"
  if amnezia_bool_true "$refresh_existing" && [ -n "$key_work_dir" ] && [ -s "$key_work_dir/privatekey" ] && [ -s "$key_work_dir/publickey" ]; then
    mv "$key_work_dir/privatekey" "$state_dir/privatekey"
    mv "$key_work_dir/publickey" "$state_dir/publickey"
    rm -rf "$key_work_dir"
    log "Rotated Amnezia Premium keypair for $provider_name"
  fi
  printf '%s' "$key_hash" > "$key_hash_file"
  printf '%s' "$server_country_code" > "$state_dir/server_country_code"

  if amnezia_bool_true "$refresh_existing"; then
    if [ -n "$old_country" ] && [ "$old_country" != "$server_country_code" ]; then
      amnezia_premium_revoke_native_config "$provider_name" "$state_dir" "$api_key" "$service_protocol" "$user_country_code" "$old_country" || true
    fi
  fi

  amnezia_premium_cleanup_tmp "$state_dir"
  log "Saved Amnezia Premium native config for $provider_name"
}

generate_amnezia_premium_provider() {
  local json_file="$1"
  local provider_name="$2"
  local yaml_file="$3"
  local api_key service_protocol user_country_code server_country_code state_dir conf_file

  vpn_json_is_amnezia_premium "$json_file" || return 1

  api_key=$(json_get "$json_file" "api_key")
  service_protocol=$(json_get "$json_file" "service_protocol")
  user_country_code=$(json_get "$json_file" "user_country_code")
  [ -n "$service_protocol" ] || service_protocol="awg"
  [ -n "$user_country_code" ] || user_country_code="ru"
  server_country_code=$(amnezia_provider_env "$provider_name" "AMNEZIA_COUNTRY" "")

  [ -n "$api_key" ] || return 1
  [ "$service_protocol" = "awg" ] || {
    log "ERROR: $provider_name Amnezia Premium protocol '$service_protocol' is not supported yet"
    return 1
  }

  state_dir="$AMNEZIA_PREMIUM_DIR/$provider_name"
  conf_file="$state_dir/native.conf"
  amnezia_premium_post_native_config "$provider_name" "$state_dir" "$api_key" "$service_protocol" \
    "$user_country_code" "$server_country_code" "$conf_file" || return 1

  {
    echo "proxies:"
    parse_awg_config "$conf_file" "$provider_name"
  } > "$yaml_file"
  log "Converted $provider_name Amnezia Premium native config"
}

generate_vpn_provider() {
  local url="$1"
  local provider_name="$2"
  local yaml_file="$3"
  local tmp_prefix="$CONFIG_DIR/.${provider_name}_vpn"
  local json_file="${tmp_prefix}.json"
  local last_file="${tmp_prefix}.last.json"
  local conf_file="${tmp_prefix}.conf"
  local count=0

  rm -f "${tmp_prefix}."*

  if ! decode_vpn_url_to_json "$url" "$json_file" "$tmp_prefix" "$provider_name"; then
    log "ERROR: $provider_name vpn:// decode failed"
    return 1
  fi

  if vpn_json_is_amnezia_premium "$json_file"; then
    if generate_amnezia_premium_provider "$json_file" "$provider_name" "$yaml_file"; then
      rm -f "${tmp_prefix}."*
      return 0
    fi
    rm -f "${tmp_prefix}."*
    return 1
  fi

  echo "proxies:" > "$yaml_file"
  echo "0" > "${tmp_prefix}.count"

  json_strings_by_key "$json_file" "last_config" | while IFS= read -r last_raw; do
    [ -z "$last_raw" ] && continue

    printf '%s' "$last_raw" | json_unescape > "$last_file"

    count_file="${tmp_prefix}.count"
    count=$(cat "$count_file" 2>/dev/null || echo 0)
    count=$((count + 1))
    if [ "$count" -eq 1 ]; then
      proxy_name="$provider_name"
    else
      proxy_name="${provider_name}_${count}"
    fi

    if emit_vpn_wireguard_proxy "$last_file" "$json_file" "$proxy_name" >> "$yaml_file"; then
      echo "$count" > "$count_file"
      continue
    fi

    if emit_vpn_xray_vless_proxy "$last_file" "$proxy_name" >> "$yaml_file"; then
      echo "$count" > "$count_file"
      continue
    fi

    json_strings_by_key "$last_file" "config" | while IFS= read -r cfg_raw; do
      [ -z "$cfg_raw" ] && continue

      printf '%s' "$cfg_raw" | json_unescape > "$conf_file"

      if grep -q '^\[Interface\]' "$conf_file" && grep -q '^\[Peer\]' "$conf_file"; then
        count=$(cat "$count_file" 2>/dev/null || echo 0)
        count=$((count + 1))
        echo "$count" > "$count_file"
        if [ "$count" -eq 1 ]; then
          parse_awg_config "$conf_file" "$provider_name" >> "$yaml_file"
        else
          parse_awg_config "$conf_file" "${provider_name}_${count}" >> "$yaml_file"
        fi
      fi
    done
  done

  count=$(cat "${tmp_prefix}.count" 2>/dev/null || echo 0)
  rm -f "${tmp_prefix}."*

  if [ "$count" -eq 0 ]; then
    log "ERROR: $provider_name vpn:// has no supported WireGuard/AmneziaWG/VLESS config"
    return 1
  fi

  log "Converted $provider_name vpn:// configs: $count"
  return 0
}

generate_awg_providers() {
  local awg_providers=""
  if ls "$AWG_DIR"/*.conf >/dev/null 2>&1; then
    for conf in "$AWG_DIR"/*.conf; do
      [ ! -f "$conf" ] && continue
      local awg_name=$(basename "$conf" .conf)
      local awg_yaml="${RUNTIME_DIR}/${awg_name}.yaml"

      {
        echo "proxies:"
        parse_awg_config "$conf"
      } > "$awg_yaml"

      cat >> "$CONFIG_YAML" <<EOF
  ${awg_name}:
    type: file
    path: $RUNTIME_DIR/${awg_name}.yaml
EOF
emit_provider_override "$awg_name" >> "$CONFIG_YAML"
    if [ "${HEALTHCHECK_PROVIDER}" = "true" ]; then
      cat >> "$CONFIG_YAML" <<EOF
$(health_check_block)
EOF
    fi
      awg_providers="${awg_providers} ${awg_name}"
    done
  fi
  echo "$awg_providers"
}

# ------------------- MOUNTED PROXIES -------------------
generate_mounted_providers() {
  local mounted_providers=""
  if ls "$PROXIES_DIR"/*.yaml >/dev/null 2>&1 || ls "$PROXIES_DIR"/*.yml >/dev/null 2>&1; then
    for yaml_file in "$PROXIES_DIR"/*.yaml "$PROXIES_DIR"/*.yml; do
      [ ! -f "$yaml_file" ] && continue
      local provider_name=$(basename "$yaml_file" .yaml)
      [ "$provider_name" = "$(basename "$yaml_file")" ] && provider_name=$(basename "$yaml_file" .yml)
      # Reference the mounted file directly — no copy to flash needed.
      cat >> "$CONFIG_YAML" <<EOF
  ${provider_name}:
    type: file
    path: $yaml_file
EOF
emit_provider_override "$provider_name" >> "$CONFIG_YAML"
      if [ "${HEALTHCHECK_PROVIDER}" = "true" ]; then
        cat >> "$CONFIG_YAML" <<EOF
$(health_check_block)
EOF
      fi
      mounted_providers="${mounted_providers} ${provider_name}"
    done
  fi
  echo "$mounted_providers"
}

#   NAMESERVER_POLICY="domain1#dns1,domain2#dns2"
generate_nameserver_policy() {
  has_output=false

  if [ -n "${NAMESERVER_POLICY:-}" ]; then
    has_output=true
  fi

  if [ -n "$DNS_POLICY" ]; then
    has_output=true
  fi

  [ "$has_output" = false ] && return

  echo "  nameserver-policy:"

  if [ -n "${NAMESERVER_POLICY:-}" ]; then
    OLDIFS=$IFS
    IFS=','
    for raw in $NAMESERVER_POLICY; do
      item=$(printf '%s' "$raw" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      [ -z "$item" ] && continue
      case "$item" in
        *#*) ;;
        *) log "Skipping invalid NAMESERVER_POLICY item: $item"; continue ;;
      esac
      domain=${item%%#*}
      dns=${item#*#}
      [ -z "$domain" ] || [ -z "$dns" ] && continue
      printf "    '%s': '%s'\n" "$domain" "$dns"
    done
    IFS=$OLDIFS
  fi

  if [ -n "$DNS_POLICY" ]; then
    printf '%s\n' "$DNS_POLICY"
  fi
}

prepare_interface_routes() {
  local i=200
  local iface route_line network mask net_addr gw

  for iface in $(ip -o link show up | awk -F': ' '/link\/ether/ {gsub(/@.*$/,"",$2); if($2!="lo" && $2!~/^hs5t/ && $2!="Meta") print $2}'); do
    route_line=$(ip route list dev "$iface" proto kernel scope link | head -n1)
    [ -z "$route_line" ] && { i=$((i+1)); continue; }
    network=$(echo "$route_line" | awk '{print $1}')
    mask=$(echo "$network" | cut -d/ -f2)
    net_addr=$(echo "$network" | cut -d/ -f1)
    if [ "$mask" -eq 31 ] || [ "$mask" -eq 32 ]; then
      gw="$net_addr"
    else
      gw=$(echo "$net_addr" | awk -F. '{printf "%d.%d.%d.%d", $1, $2, $3, $4+1}')
    fi

    if [ "$i" -eq 200 ]; then
      ip route del default 2>/dev/null || true
      ip route replace default via "$gw" dev "$iface"
    else
      ip route replace default via "$gw" dev "$iface" table $i
      ip rule del table $i 2>/dev/null || true
      ip rule add fwmark $i table $i pref 150
    fi
    i=$((i+1))
  done
}

# ===== Registries =====

DEFINED_GROUPS=""
DEFINED_RULESETS=""
DEFINED_RULES=""
DNS_POLICY=""

add_dns_policy() {
  local rule="$1"
  local dns="$2"
  if [ -z "$DNS_POLICY" ]; then
    DNS_POLICY="    '$rule': '$dns'"
  else
    DNS_POLICY="$DNS_POLICY
    '$rule': '$dns'"
  fi
}


group_defined() {
  case " $DEFINED_GROUPS " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

register_group() {
  DEFINED_GROUPS="$DEFINED_GROUPS $1"
}

ruleset_defined() {
  case " $DEFINED_RULESETS " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

register_ruleset() {
  DEFINED_RULESETS="$DEFINED_RULESETS $1"
}

rule_defined() {
  case "$DEFINED_RULES" in
    *"|$1|"*) return 0 ;;
    *) return 1 ;;
  esac
}

add_rule() {
  local rule="$1"
  local prio="$2"
  if ! rule_defined "$rule"; then
    DEFINED_RULES="${DEFINED_RULES}|$rule|"
    all_rules="$all_rules
$prio|$rule"
  fi
}

emit_provider_override() {
  local name="$1"
  local dialer

  dialer=$(printenv "${name}_DIALER_PROXY" 2>/dev/null || true)

  if [ -n "$dialer" ]; then
    cat <<EOF
    override:
      dialer-proxy: $dialer
EOF
  fi
}

parse_wg_dst() {
  echo "$ZAPRET2_WG_DST" | tr ',' '\n' | sed '/^$/d'
}

apply_zapret2_wg_nft() {

  [ -z "$ZAPRET2_WG_DST" ] && return 0

  echo "Applying ZAPRET2 WG rules..."

  local table="zapret2_wg"
  local mark="0x25"
  local queue="250"

  nft add table inet $table 2>/dev/null || true

  nft add chain inet $table pre '{
    type filter hook prerouting priority mangle;
    policy accept;
  }' 2>/dev/null || true


  echo "$ZAPRET2_WG_DST" | tr ',' '\n' | while read -r ep; do

    [ -z "$ep" ] && continue

    ip="${ep%%:*}"
    port="${ep##*:}"

    echo "WG endpoint: $ip:$port"

    nft add rule inet $table pre \
      ip daddr $ip udp dport $port \
      meta mark set $mark \
      queue num $queue

  done

  ip rule show | grep -q "fwmark $mark lookup main" || \
    ip rule add fwmark $mark table main pref 40

  # === Exclude WG from mihomo tproxy ===
  if [ "${TPROXY}" = "true" ]; then

    echo "Adding mihomo tproxy exclusions for WG..."

    local mtable="mihomo"
    local mchain="pre"

    # Убедимся что таблица есть
    nft list table inet $mtable >/dev/null 2>&1 || return 0

    echo "$ZAPRET2_WG_DST" | tr ',' '\n' | while read -r ep; do

      [ -z "$ep" ] && continue

      ip="${ep%%:*}"
      port="${ep##*:}"

      # Проверим, нет ли уже правила
      nft list chain inet $mtable $mchain | \
        grep -q "ip daddr $ip udp dport $port return" && continue

      echo "Exclude from mihomo: $ip:$port"

      # Добавляем В НАЧАЛО цепочки
      nft insert rule inet $mtable $mchain position 0 \
        ip daddr $ip udp dport $port return

    done
  fi
}

start_zapret2_wg() {

  [ -z "$ZAPRET2_WG_DST" ] && return 0

  local queue="250"

  echo "Starting ZAPRET2 for WireGuard on queue $queue"

  LUA_INIT_ARGS=""
  for f in /lua/*.lua; do
    LUA_INIT_ARGS="$LUA_INIT_ARGS --lua-init=@$f"
  done

  nfqws2 \
    --qnum $queue \
    --user=root \
    $LUA_INIT_ARGS \
    $ZAPRET2_WG_CMD &

}

# ------------------- CONFIG -------------------
config_file_mihomo() {
  echo "Generating $CONFIG_YAML"
  mkdir -p "$CONFIG_DIR"

  LAST_UI_URL=$(cat "$UI_URL_CHECK" 2>/dev/null || true)
  if [ "$EXTERNAL_UI_URL" != "$LAST_UI_URL" ]; then
    log "UI URL changed → removing ui"
    rm -rf "$CONFIG_DIR/ui"
    echo "$EXTERNAL_UI_URL" > "$UI_URL_CHECK"
  fi

  cat > "$CONFIG_YAML" <<EOF
log-level: $LOG_LEVEL
external-controller: 0.0.0.0:9090
secret: $UI_SECRET
external-ui: ui
external-ui-url: "$EXTERNAL_UI_URL"
unified-delay: true
ipv6: false
geodata-mode: true
find-process-mode: off
profile:
  store-selected: true
listeners:
  - name: redir-in
    type: redir
    port: 12345
    listen: 0.0.0.0
EOF
for entry in $dscp_to_group; do
    dscp=${entry%%:*}
    group=${entry#*:}
    port=$((7000 + dscp))
    name="redir-in-dscp-${dscp}"
    cat >> "$CONFIG_YAML" <<EOF
  - name: $name
    type: redir
    port: $port
    listen: 0.0.0.0
EOF
  done
  if lsmod | grep -q '^nft_tproxy' && [ "$TPROXY" = "true" ]; then
    cat >> "$CONFIG_YAML" <<EOF
  - name: tproxy-in
    type: tproxy
    port: 12346
    listen: 0.0.0.0
    udp: true
EOF
  else
    cat >> "$CONFIG_YAML" <<EOF
  - name: tun-in
    type: tun
    inet4-address:
      - 100.64.0.1/32
    udp-timeout: 30
    mtu: 1500
EOF
  fi

  cat >> "$CONFIG_YAML" <<EOF
  - name: mixed-in
    type: mixed
    port: 1080
    listen: 0.0.0.0
    udp: true
proxy-providers:
EOF

  providers=""
  dns_providers=""
  dns_ifaces=""
  dns_zapret=""
  dns_other=""

  # LINK
  if env | grep -qE '^LINK[0-9]*='; then
    for varname in $(env | grep -E '^LINK[0-9]*=' | cut -d'=' -f1 | sort -V); do
      url=$(printenv "$varname")
      provider_name="$varname"
      yaml_file="$RUNTIME_DIR/${provider_name}.yaml"
      case "$url" in
        vpn://*)
          if ! generate_vpn_provider "$url" "$provider_name" "$yaml_file"; then
            echo "proxies: []" > "$yaml_file"
          fi
          ;;
        *)
          printf '%s\n' "$url" > "$yaml_file"
          ;;
      esac
      cat >> "$CONFIG_YAML" <<EOF
  $provider_name:
    type: file
    path: $RUNTIME_DIR/${provider_name}.yaml
EOF
emit_provider_override "$provider_name" >> "$CONFIG_YAML"
    if [ "${HEALTHCHECK_PROVIDER}" = "true" ]; then
      cat >> "$CONFIG_YAML" <<EOF
$(health_check_block)
EOF
    fi
      providers="$providers $provider_name"
      dns_other="$dns_other $provider_name"
    done
  fi
  
  # MOUNTED PROXIES from $PROXIES_DIR
  mounted_provs=$(generate_mounted_providers)
  providers="${providers}${mounted_provs}"

  # SUB_LINK
  sub_link_envs="$RUNTIME_DIR/.sub_link_envs"
  env | grep -E '^SUB_LINK[0-9]+=' | sort -V > "$sub_link_envs" || true
  while IFS= read -r var; do
    name=$(echo "$var" | cut -d '=' -f1)
    url=$(echo "$var" | cut -d '=' -f2- | tr -d '\r')
    interval=$(printenv "${name}_INTERVAL" || echo "$SUB_LINK_INTERVAL")
    proxy="DIRECT"
    eval "proxy=\"\${${name}_PROXY:-DIRECT}\"" 2>/dev/null
    headers_env_name="${name}_HEADERS"
    headers_raw=$(eval "echo \"\${$headers_env_name+x}\"" 2>/dev/null)
    if [ -n "$headers_raw" ]; then
      headers_raw=$(eval "echo \"\${$headers_env_name}\"" | tr -d '\r')
    else
      headers_raw=""
    fi
    cat >> "$CONFIG_YAML" <<EOF
  $name:
    type: http
    url: "$url"
    interval: $interval
    proxy: $proxy
EOF
emit_provider_override "$name" >> "$CONFIG_YAML"
    if [ -n "$headers_raw" ]; then
      cat >> "$CONFIG_YAML" <<EOF
    header:
EOF
      OLDIFS=$IFS
      IFS='#'
      for pair in $headers_raw; do
        [ -z "$pair" ] && continue
        pair=$(echo "$pair" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        key=$(echo "$pair" | cut -d'=' -f1)
        val=$(echo "$pair" | cut -d'=' -f2-)
        [ -z "$key" ] || [ -z "$val" ] && continue
        val_escaped=$(echo "$val" | sed 's/"/\\"/g')
        echo "      $key:" >> "$CONFIG_YAML"
        echo "      - \"$val_escaped\"" >> "$CONFIG_YAML"
      done
      IFS=$OLDIFS
    fi
    cat >> "$CONFIG_YAML" <<EOF
EOF
    if [ "${HEALTHCHECK_PROVIDER}" = "true" ]; then
      cat >> "$CONFIG_YAML" <<EOF
$(health_check_block)
EOF
    fi
    providers="$providers $name"
    dns_other="$dns_other $name"
  done < "$sub_link_envs"
  rm -f "$sub_link_envs"

  # AWG
  awg_provs=$(generate_awg_providers)
  providers="${providers}${awg_provs}"
  dns_other="${dns_other}${awg_provs}"

# SOCKS5
  socks_envs="$CONFIG_DIR/.socks_envs"
  env | grep -E '^SOCKS[0-9]+=' | sort -V > "$socks_envs" || true
  while IFS= read -r var; do
    name=$(echo "$var" | cut -d '=' -f1)
    value=$(echo "$var" | cut -d '=' -f2-)
    server=""
    port=""
    username=""
    password=""
    tls=""
    fingerprint=""
    skip_cert_verify=""
    udp="true"
    ip_version="ipv4"
    OLDIFS=$IFS
    IFS='#'
    for pair in $value; do
      [ -z "$pair" ] && continue
      key=$(echo "$pair" | cut -d'=' -f1 | xargs)
      val=$(echo "$pair" | cut -d'=' -f2- | xargs)
      case "$key" in
        server)           server="$val" ;;
        port)             port="$val" ;;
        username)         username="$val" ;;
        password)         password="$val" ;;
        tls)              tls="$val" ;;
        fingerprint)      fingerprint="$val" ;;
        skip-cert-verify) skip_cert_verify="$val" ;;
        udp)              udp="$val" ;;
        ip-version)       ip_version="$val" ;;
      esac
    done
    IFS=$OLDIFS
    yaml_file="$RUNTIME_DIR/${name}.yaml"
    {
      echo "proxies:"
      echo "  - name: \"$name\""
      echo "    type: socks5"
      echo "    server: $server"
      echo "    port: $port"
      echo "    udp: $udp"
      echo "    ip-version: $ip_version"
      [ -n "$username" ] && echo "    username: $username"
      [ -n "$password" ] && echo "    password: $password"
      [ -n "$tls" ] && echo "    tls: $tls"
      [ -n "$fingerprint" ] && echo "    fingerprint: $fingerprint"
      [ -n "$skip_cert_verify" ] && echo "    skip-cert-verify: $skip_cert_verify"
    } > "$yaml_file"
    cat >> "$CONFIG_YAML" <<EOF
  $name:
    type: file
    path: $RUNTIME_DIR/${name}.yaml
EOF
emit_provider_override "$name" >> "$CONFIG_YAML"
    if [ "${HEALTHCHECK_PROVIDER}" = "true" ]; then
      cat >> "$CONFIG_YAML" <<EOF
$(health_check_block)
EOF
    fi
    providers="$providers $name"
    dns_other="$dns_other $name"
  done < "$socks_envs"
  rm -f "$socks_envs"

  # ZAPRET
  if lsmod | grep nf_tables >/dev/null 2>&1; then
    generate_zapret_proxies 300 ZAPRET "$ZAPRET_LIST"
    generate_zapret_proxies 400 ZAPRET2 "$ZAPRET2_LIST"
  fi

  # BYEDPI
  if [ "${BYEDPI}" = "true" ]; then
    generate_byedpi_proxies
  fi
  
  # all interfaces
reverse_providers=""
i=200
for iface in $(ip -o link show up | awk -F': ' '/link\/ether/ {gsub(/@.*$/,"",$2); if($2!="lo") print $2}'); do
    route_line=$(ip route list dev "$iface" proto kernel scope link | head -n1)
    [ -z "$route_line" ] && { echo "[$i] $iface → no route, skip"; i=$((i+1)); continue; }
    network=$(echo "$route_line" | awk '{print $1}')
    mask=$(echo "$network" | cut -d/ -f2)
    net_addr=$(echo "$network" | cut -d/ -f1)
    if [ "$i" -eq 200 ]; then
      dns_ifaces="$iface $dns_ifaces"
    else
      dns_ifaces="$dns_ifaces $iface"
    fi
    if [ "$mask" -eq 31 ] || [ "$mask" -eq 32 ]; then
        gw="$net_addr"
    else
        gw=$(echo "$net_addr" | awk -F. '{printf "%d.%d.%d.%d", $1, $2, $3, $4+1}')
    fi
  if [ $i = 200 ]; then
    ip route del default 2>/dev/null || true
    ip route replace default via "$gw" dev "$iface"
  else
    ip route replace default via "$gw" dev "$iface" table $i
    ip rule del table $i 2>/dev/null
    ip rule add fwmark $i table $i pref 150
  fi

  echo "Generating $RUNTIME_DIR/$iface.yaml with interface: $iface"

  cat > "$RUNTIME_DIR/$iface.yaml" <<EOF
proxies:
  - name: "$iface"
    type: direct
    udp: true
    ip-version: ipv4
    interface-name: "$iface"
EOF
  if [ $i -gt 200 ]; then
  cat >> "$RUNTIME_DIR/$iface.yaml" <<EOF
    routing-mark: $i
EOF
  fi

  cat >> "$CONFIG_YAML" <<EOF
  $iface:
    type: file
    path: $RUNTIME_DIR/$iface.yaml
EOF
    if [ "${HEALTHCHECK_PROVIDER}" = "true" ]; then
      cat >> "$CONFIG_YAML" <<EOF
$(health_check_block)
EOF
    fi
 
  reverse_providers="$iface $reverse_providers"
  i=$((i+1))
done
  providers="$providers $reverse_providers"

for var in $ZAPRET_LIST; do
  base="${var%%_CMD*}"
  idx="${var#${base}_CMD}"
  if [ -n "$idx" ]; then
    name="${base}_${idx}"
  else
    name="${base}"
  fi
  dns_zapret="$dns_zapret $name"
done
for var in $ZAPRET2_LIST; do
  base="${var%%_CMD*}"
  idx="${var#${base}_CMD}"
  if [ -n "$idx" ]; then
    name="${base}_${idx}"
  else
    name="${base}"
  fi
  dns_zapret="$dns_zapret $name"
done
for var in $BYEDPI_LIST; do
  idx=$(get_cmd_index "$var" BYEDPI)
  name=$(get_instance_name "BYEDPI" "$idx")
  dns_zapret="$dns_zapret $name"
done
dns_providers="$(echo "$dns_ifaces $dns_zapret $dns_other" | xargs)"

# REJECT,REJECT-DROP
  cat >> "$CONFIG_YAML" <<EOF
  REJECT:
    type: inline
    payload:
      - name: "REJECT"
        type: reject
  REJECT-DROP:
    type: inline
    payload:
      - name: "REJECT-DROP"
        type: reject
        drop: true
EOF
  providers="$providers REJECT"
  providers="$providers REJECT-DROP"

# === ГРУППЫ + ПРАВИЛА ===
  {

custom_rules_payloads=""
    custom_rules_idx=0

    for var in $(env | grep -E '^RULE_SET[0-9]+_BASE64=' | sort -V | cut -d= -f1); do

      value=$(printenv "$var" || true)

      case "$value" in
        *"#"*)
          base64_part="${value%%#*}"
          raw_name="${value#*#}"
          ;;
        *)
          echo "ERROR: $var has invalid format. Expected BASE64#name" >&2
          continue
          ;;
      esac

      name=$(echo "$raw_name" | xargs | sed 's/[^a-zA-Z0-9_-]//g')

      if [ -z "$name" ]; then
        echo "ERROR: $var has empty or invalid name after '#'" >&2
        continue
      fi

      if [ -z "$base64_part" ]; then
        echo "ERROR: $var has empty BASE64 payload" >&2
        continue
      fi

      ruleset_file="$RUNTIME_DIR/${name}_ruleset_payload.txt"
      payload=$(printf '%s' "$base64_part" | tr -d '\r\n ' | base64 -d 2>/dev/null || true)

      if [ -z "$payload" ]; then
        log "Skipping $var — BASE64 decode failed"
        continue
      fi
      printf '%s\n' "$payload" > "$ruleset_file"

      custom_rules_payloads="$custom_rules_payloads
      ${custom_rules_idx}|${name}|${ruleset_file}"
      custom_rules_idx=$((custom_rules_idx + 1))
    done

    # ------------------- RULE_SET files (non-base64) -------------------
    if [ -d "$RULE_SET_DIR" ]; then
      for f in "$RULE_SET_DIR"/*; do
        [ -f "$f" ] || continue

        raw_name=$(basename "$f")
        name="${raw_name%.*}"

        name=$(echo "$name" | xargs | sed 's/[^a-zA-Z0-9_-]//g')

        [ -z "$name" ] && {
          log "Skipping rule-set file $f — invalid name"
          continue
        }

        if [ ! -s "$f" ]; then
          log "Skipping rule-set file $f — empty file"
          continue
        fi

        # Reference the mounted file directly — no copy needed.
        ruleset_file="$f"

        custom_rules_payloads="$custom_rules_payloads
    ${custom_rules_idx}|${name}|${ruleset_file}"

        custom_rules_idx=$((custom_rules_idx + 1))
      done
    fi

    # GLOBAL

    type="${GLOBAL_TYPE:-$GROUP_TYPE}"
    filter="${GLOBAL_FILTER:-$GROUP_FILTER}"
    exclude="${GLOBAL_EXCLUDE:-$GROUP_EXCLUDE}"
    exclude_type="${GLOBAL_EXCLUDE_TYPE:-$GROUP_EXCLUDE_TYPE}"
    use="${GLOBAL_USE:-$GROUP_USE}"
    proxies_val="${GLOBAL_PROXIES:-$GROUP_PROXIES}"
    g_tol="${GLOBAL_TOLERANCE:-$GROUP_TOLERANCE}"
    g_url="${GLOBAL_URL:-$GROUP_URL}"
    g_status="${GLOBAL_URL_STATUS:-$GROUP_URL_STATUS}"
    g_interval="${GLOBAL_INTERVAL:-$GROUP_INTERVAL}"
    g_strategy="${GLOBAL_STRATEGY:-$GROUP_STRATEGY}"
    g_icon="${GLOBAL_ICON:-}"
    hidden="${GLOBAL_HIDDEN:-false}"
    echo
    echo "proxy-groups:"
    echo "  - name: GLOBAL"
    echo "    type: $type"
    if [ "${HEALTHCHECK_PROVIDER}" = "false" ]; then
      echo "    url: \"$g_url\""
      echo "    expected-status: $g_status"
      echo "    interval: $g_interval"
    fi
    echo "    timeout: 1500"
    case "$type" in
      url-test)
        [ -n "$g_tol" ] && echo "    tolerance: $g_tol"
        ;;
      load-balance)
        [ -n "$g_strategy" ] && echo "    strategy: $g_strategy"
        ;;
    esac
      echo "    lazy: false"
      [ -n "$g_icon" ] && echo "    icon: $g_icon"
      [ -n "$filter" ] && echo "    filter: $filter"
      [ -n "$exclude" ] && echo "    exclude-filter: $exclude"
      [ -n "$exclude_type" ] && echo "    exclude-type: $exclude_type"
      echo "    hidden: $hidden"
      if [ -n "$proxies_val" ]; then
        echo "    proxies:"
        echo "$proxies_val" | tr ',' '\n' | sed 's/^/      - /'
      fi
      if [ "$use" != "none" ]; then
        echo "    use:"
        if [ -n "$use" ]; then
          echo "$use" | tr ',' '\n' | sed 's/^/      - /'
        else
          for p in $providers; do echo "      - $p"; done
        fi
      fi

    # DNS

    type="${DNS_TYPE:-select}"
    filter="${DNS_FILTER:-}"
    exclude="${DNS_EXCLUDE:-}"
    exclude_type="${DNS_EXCLUDE_TYPE:-}"
    use="${DNS_USE:-}"
    proxies_val="${DNS_PROXIES:-}"
    g_tol="${DNS_TOLERANCE:-$GROUP_TOLERANCE}"
    g_url="${DNS_URL:-$GROUP_URL}"
    g_status="${DNS_URL_STATUS:-$GROUP_URL_STATUS}"
    g_interval="${DNS_INTERVAL:-$GROUP_INTERVAL}"
    g_strategy="${DNS_STRATEGY:-$GROUP_STRATEGY}"
    g_icon="${DNS_ICON:-}"
    hidden="${DNS_HIDDEN:-false}"
    echo
    echo "  - name: DNS"
    echo "    type: $type"
    if [ "${HEALTHCHECK_PROVIDER}" = "false" ]; then
      echo "    url: \"$g_url\""
      echo "    expected-status: $g_status"
      echo "    interval: $g_interval"
    fi
    echo "    timeout: 1500"
    case "$type" in
      url-test)
        [ -n "$g_tol" ] && echo "    tolerance: $g_tol"
        ;;
      load-balance)
        [ -n "$g_strategy" ] && echo "    strategy: $g_strategy"
        ;;
    esac
      echo "    lazy: false"
      [ -n "$g_icon" ] && echo "    icon: $g_icon"
      [ -n "$filter" ] && echo "    filter: $filter"
      [ -n "$exclude" ] && echo "    exclude-filter: $exclude"
      [ -n "$exclude_type" ] && echo "    exclude-type: $exclude_type"
      echo "    hidden: $hidden"
      if [ -n "$proxies_val" ]; then
        echo "    proxies:"
        echo "$proxies_val" | tr ',' '\n' | sed 's/^/      - /'
      fi
      if [ "$use" != "none" ]; then
        echo "    use:"
        if [ -n "$use" ]; then
          echo "$use" | tr ',' '\n' | sed 's/^/      - /'
        else
          for p in $dns_providers; do echo "      - $p"; done
        fi
      fi

    # === Сбор групп с приоритетами ===
    group_prio_list=""
    idx=0
    if [ -n "${GROUP:-}" ]; then
      for g in $(echo "$GROUP" | tr ',' ' '); do
        g=$(echo "$g" | xargs)
        [ -z "$g" ] && continue

        env_name=$(echo "$g" | tr '-' '_' | tr '[:lower:]' '[:upper:]')
        has_resource=false
        has_use=false

        # Проверка rule-ресурсов
        for suffix in GEOSITE GEOIP AS DOMAIN SUFFIX IPCIDR KEYWORD SRCIPCIDR DSCP; do
          if [ -n "$(printenv "${env_name}_${suffix}" 2>/dev/null || echo "")" ]; then
            has_resource=true
            break
          fi
        done

        # Проверка USE
        use_val=$(printenv "${env_name}_USE" 2>/dev/null || echo "")
        [ -n "$use_val" ] && has_use=true

        # Если нет ни ресурсов, ни USE — пропускаем
        if ! $has_resource && ! $has_use; then
          continue
        fi

        prio=$(printenv "${env_name}_PRIORITY" 2>/dev/null || echo "")
        [ -z "$prio" ] && prio=$((1000 + idx))
        group_prio_list="$group_prio_list $g|$prio"
        idx=$((idx + 1))
      done
    fi

    # === Сортировка групп по приоритету ===
    sorted_groups=""
    if [ -n "$group_prio_list" ]; then
      sorted_groups=$(echo "$group_prio_list" | tr ' ' '\n' | sort -t'|' -k2 -n | cut -d'|' -f1)
    fi

    # === Добавляем RULE_SET*_BASE64 группы как обычные группы ===
    if [ -n "$custom_rules_payloads" ]; then
      for name in $(echo "$custom_rules_payloads" | cut -d'|' -f2 | sort -u); do
        case " $sorted_groups " in
          *" $name "*) ;;
          *) sorted_groups="$sorted_groups $name" ;;
        esac
      done
    fi

    # === proxy-groups ===
    for g in $sorted_groups; do
      env_name=$(echo "$g" | tr '-' '_' | tr '[:lower:]' '[:upper:]')
      type=$(printenv "${env_name}_TYPE" || echo "$GROUP_TYPE")
      filter=$(printenv "${env_name}_FILTER" || echo "$GROUP_FILTER")
      exclude=$(printenv "${env_name}_EXCLUDE" || echo "$GROUP_EXCLUDE")
      exclude_type=$(printenv "${env_name}_EXCLUDE_TYPE" || echo "$GROUP_EXCLUDE_TYPE")
      use=$(printenv "${env_name}_USE" || echo "$GROUP_USE")
      proxies_val=$(printenv "${env_name}_PROXIES" 2>/dev/null || echo "$GROUP_PROXIES")
      g_tol=$(printenv "${env_name}_TOLERANCE" || echo "$GROUP_TOLERANCE")
      g_url=$(printenv "${env_name}_URL" || echo "$GROUP_URL")
      g_status=$(printenv "${env_name}_URL_STATUS" || echo "$GROUP_URL_STATUS")
      g_interval=$(printenv "${env_name}_INTERVAL" || echo "$GROUP_INTERVAL")
      g_strategy=$(printenv "${env_name}_STRATEGY" || echo "$GROUP_STRATEGY")
      g_icon=$(printenv "${env_name}_ICON" || echo "")
      hidden=$(printenv "${env_name}_HIDDEN" || echo "false")
      if ! group_defined "$g"; then
        echo
        echo "  - name: $g"
        echo "    type: $type"
        if [ "${HEALTHCHECK_PROVIDER}" = "false" ]; then
          echo "    url: \"$g_url\""
          echo "    expected-status: $g_status"
          echo "    interval: $g_interval"
        fi
        echo "    timeout: 1500"
        case "$type" in
          url-test)
            [ -n "$g_tol" ] && echo "    tolerance: $g_tol"
            ;;
          load-balance)
            [ -n "$g_strategy" ] && echo "    strategy: $g_strategy"
            ;;
        esac
        echo "    lazy: false"
        [ -n "$g_icon" ] && echo "    icon: $g_icon"
        [ -n "$filter" ] && echo "    filter: $filter"
        [ -n "$exclude" ] && echo "    exclude-filter: $exclude"
        [ -n "$exclude_type" ] && echo "    exclude-type: $exclude_type"
        echo "    hidden: $hidden"
        if [ -n "$proxies_val" ]; then
          echo "    proxies:"
          echo "$proxies_val" | tr ',' '\n' | sed 's/^/      - /'
        fi
        if [ "$use" != "none" ]; then
          echo "    use:"
          if [ -n "$use" ]; then
            echo "$use" | tr ',' '\n' | sed 's/^/      - /'
          else
            for p in $providers; do echo "      - $p"; done
          fi
        fi
        register_group "$g"
      fi
    done

# Сбор приоритетов для custom rule-set групп (по аналогии с GROUP)
    custom_group_prio_list=""
    custom_idx=0

    # Проходим по уже собранным custom name
    if [ -n "$custom_rules_payloads" ]; then
      custom_rules_sorted="$CONFIG_DIR/.custom_rules_sorted"
      echo "$custom_rules_payloads" | grep -v '^$' | sort -t'|' -k1 -n > "$custom_rules_sorted" || true
      while IFS='|' read -r idx name payload_file; do
        [ -z "$name" ] && continue
        env_name=$(echo "$name" | tr '-' '_' | tr '[:lower:]' '[:upper:]')
        prio=$(printenv "${env_name}_PRIORITY" 2>/dev/null || echo "")
        [ -z "$prio" ] && prio=$((2000 + custom_idx))   # дефолт, если нет ENV
        custom_group_prio_list="$custom_group_prio_list $name|$prio"
        custom_idx=$((custom_idx + 1))
      done < "$custom_rules_sorted"
      rm -f "$custom_rules_sorted"
    fi

    # Сортировка custom групп по приоритету
    sorted_custom_groups=""
    if [ -n "$custom_group_prio_list" ]; then
      sorted_custom_groups=$(echo "$custom_group_prio_list" | tr ' ' '\n' | sort -t'|' -k2 -n | cut -d'|' -f1)
    fi

    # Добавляем группы для custom rule-set'ов (сортировка по приоритету)
    if [ -n "$sorted_custom_groups" ]; then
      for name in $sorted_custom_groups; do
        env_name=$(echo "$name" | tr '-' '_' | tr '[:lower:]' '[:upper:]')
        type=$(printenv "${env_name}_TYPE" || echo "${GROUP_TYPE:-select}")
        filter=$(printenv "${env_name}_FILTER" || echo "$GROUP_FILTER")
        exclude=$(printenv "${env_name}_EXCLUDE" || echo "$GROUP_EXCLUDE")
        exclude_type=$(printenv "${env_name}_EXCLUDE_TYPE" || echo "$GROUP_EXCLUDE_TYPE")
        use=$(printenv "${env_name}_USE" || echo "$GROUP_USE")
        proxies_val=$(printenv "${env_name}_PROXIES" 2>/dev/null || echo "$GROUP_PROXIES")
        g_tol=$(printenv "${env_name}_TOLERANCE" || echo "$GROUP_TOLERANCE")
        g_url=$(printenv "${env_name}_URL" || echo "$GROUP_URL")
        g_status=$(printenv "${env_name}_URL_STATUS" || echo "$GROUP_URL_STATUS")
        g_interval=$(printenv "${env_name}_INTERVAL" || echo "$GROUP_INTERVAL")
        g_strategy=$(printenv "${env_name}_STRATEGY" || echo "$GROUP_STRATEGY")
        g_icon=$(printenv "${env_name}_ICON" || echo "")
        hidden=$(printenv "${env_name}_HIDDEN" || echo "false")
        if ! group_defined "$name"; then
          echo
          echo "  - name: $name"
          echo "    type: $type"
          if [ "${HEALTHCHECK_PROVIDER}" = "false" ]; then
            echo "    url: \"$g_url\""
            echo "    expected-status: $g_status"
            echo "    interval: $g_interval"
          fi
          echo "    timeout: 1500"
          case "$type" in
            url-test)
              [ -n "$g_tol" ] && echo "    tolerance: $g_tol"
              ;;
            load-balance)
              [ -n "$g_strategy" ] && echo "    strategy: $g_strategy"
              ;;
          esac
          echo "    lazy: false"
          [ -n "$g_icon" ] && echo "    icon: $g_icon"
          [ -n "$filter" ] && echo "    filter: $filter"
          [ -n "$exclude" ] && echo "    exclude-filter: $exclude"
          [ -n "$exclude_type" ] && echo "    exclude-type: $exclude_type"
          echo "    hidden: $hidden"
          if [ -n "$proxies_val" ]; then
            echo "    proxies:"
            echo "$proxies_val" | tr ',' '\n' | sed 's/^/      - /'
          fi
          if [ "$use" != "none" ]; then
            echo "    use:"
            if [ -n "$use" ]; then
              echo "$use" | tr ',' '\n' | sed 's/^/      - /'
            else
              for p in $providers; do echo "      - $p"; done
            fi
          fi
                register_group "$name"
        fi
      done
    fi
    
    #ENV RULES*

    all_rules=""

    for var in $(env | grep -E '^RULES[0-9]+=' | sort -V | cut -d= -f1); do
      prio=${var#RULES}
      content=$(printenv "$var")

      OLDIFS=$IFS
      IFS=';'
      for line in $content; do
        line=$(echo "$line" | xargs)
        [ -z "$line" ] && continue
        all_rules="$all_rules
    $prio|$line"
      done
      IFS=$OLDIFS
    done

    # === rule-providers ===
    echo
    echo "rule-providers:"

    idx=0

    for g in $sorted_groups; do
      env_name=$(echo "$g" | tr '-' '_' | tr '[:lower:]' '[:upper:]')

      group_prio=$(printenv "${env_name}_PRIORITY" 2>/dev/null)
      [ -z "$group_prio" ] && group_prio=$((1000 + idx))

# GEOSITE
geosite_list=$(printenv "${env_name}_GEOSITE" || echo "")
for gs in $(echo "$geosite_list" | tr ',' ' ' | xargs -n1); do
  [ -z "$gs" ] && continue

  rs_name="${g}_geosite_$gs"

  if ! ruleset_defined "$rs_name"; then
    case "$gs" in
      anime|art|casino|education|games|messengers|music|news|porn|socials|tools|torrent|video)
        cat <<EOF
  $rs_name:
    type: http
    behavior: domain
    format: text
    url: "https://iplist.opencck.org/?format=text&data=domains&group=$gs"
    interval: 86400
EOF
        ;;
      *)
        cat <<EOF
  $rs_name:
    type: http
    behavior: domain
    format: mrs
    url: "https://github.com/MetaCubeX/meta-rules-dat/raw/refs/heads/meta/geo/geosite/$gs.mrs"
    interval: 86400
EOF
        ;;
    esac
    register_ruleset "$rs_name"
    
    dns=$(printenv "${env_name}_DNS" 2>/dev/null || true)
    [ -n "$dns" ] && add_dns_policy "rule-set:${rs_name}" "$dns"
  fi

  add_rule "RULE-SET,$rs_name,$g" "$group_prio"
done

# GEOIP
geoip_list=$(printenv "${env_name}_GEOIP" || echo "")
for gi in $(echo "$geoip_list" | tr ',' ' ' | xargs -n1); do
  [ -z "$gi" ] && continue

  rs_name="${g}_geoip_$gi"

  if ! ruleset_defined "$rs_name"; then
    if [ "$gi" = "discord" ]; then
      cat <<EOF
  $rs_name:
    type: http
    behavior: ipcidr
    format: text
    url: "https://raw.githubusercontent.com/Medium1992/mihomo-proxy-ros/refs/heads/main/custom_list/discord.list"
    interval: 86400
EOF
    else
      cat <<EOF
  $rs_name:
    type: http
    behavior: ipcidr
    format: mrs
    url: "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/refs/heads/meta/geo/geoip/$gi.mrs"
    interval: 86400
EOF
    fi
    register_ruleset "$rs_name"
  fi

  if [ "$gi" = "discord" ]; then
    add_rule "AND,((RULE-SET,$rs_name),(NETWORK,UDP),(DST-PORT,19294-19344/50000-50100)),$g" "$group_prio"
  else
    add_rule "RULE-SET,$rs_name,$g" "$group_prio"
  fi
done

# AS
as_list=$(printenv "${env_name}_AS" || echo "")
for asn in $(echo "$as_list" | tr ',' ' ' | xargs -n1); do
  [ -z "$asn" ] && continue
  as_num="${asn#AS}"
  [ "$as_num" = "$asn" ] && continue

  rs_name="${g}_as_$asn"

  if ! ruleset_defined "$rs_name"; then
    cat <<EOF
  $rs_name:
    type: http
    behavior: ipcidr
    format: mrs
    url: "https://github.com/MetaCubeX/meta-rules-dat/raw/refs/heads/meta/asn/AS$as_num.mrs"
    interval: 86400
EOF
    register_ruleset "$rs_name"
  fi

  add_rule "RULE-SET,$rs_name,$g" "$group_prio"
done

      # Custom правила
      custom_payload=""
      domain_list=$(printenv "${env_name}_DOMAIN" || echo "")
      for dm in $(echo "$domain_list" | tr ',' ' ' | xargs -n1); do
        [ -z "$dm" ] && continue
        custom_payload="$custom_payload
      - DOMAIN,$dm"
      done

      suffix_list=$(printenv "${env_name}_SUFFIX" || echo "")
      for sf in $(echo "$suffix_list" | tr ',' ' ' | xargs -n1); do
        [ -z "$sf" ] && continue
        custom_payload="$custom_payload
      - DOMAIN-SUFFIX,$sf"
      done

      keyword_list=$(printenv "${env_name}_KEYWORD" || echo "")
      for kw in $(echo "$keyword_list" | tr ',' ' ' | xargs -n1); do
        [ -z "$kw" ] && continue
        custom_payload="$custom_payload
      - DOMAIN-KEYWORD,$kw"
      done

      ipcidr_list=$(printenv "${env_name}_IPCIDR" || echo "")
      for ipcidr in $(echo "$ipcidr_list" | tr ',' ' ' | xargs -n1); do
        [ -z "$ipcidr" ] && continue
        custom_payload="$custom_payload
      - IP-CIDR,$ipcidr"
      done

      srcipcidr_list=$(printenv "${env_name}_SRCIPCIDR" || echo "")
      for srcipcidr in $(echo "$srcipcidr_list" | tr ',' ' ' | xargs -n1); do
        [ -z "$srcipcidr" ] && continue
        custom_payload="$custom_payload
      - SRC-IP-CIDR,$srcipcidr"
      done

      if [ -n "$custom_payload" ]; then
rs_name="${g}_custom_rules"

if ! ruleset_defined "$rs_name"; then
  cat <<EOF
  $rs_name:
    type: inline
    behavior: classical
    format: text
    payload:$custom_payload
EOF
  register_ruleset "$rs_name"
  dns=$(printenv "${env_name}_DNS" 2>/dev/null || true)
  [ -n "$dns" ] && add_dns_policy "rule-set:${rs_name}" "$dns"
fi

add_rule "RULE-SET,$rs_name,$g" "$group_prio"
      fi
dscp=$(printenv "${env_name}_DSCP" || true)
      if [ -n "$dscp" ]; then
        add_rule "DSCP,$dscp,$g" "$group_prio"
        add_rule "IN-NAME,redir-in-dscp-${dscp},$g" "$group_prio"
      fi
      idx=$((idx + 1))
    done

# Добавляем inline rule-providers для custom
if [ -n "$custom_rules_payloads" ]; then
  custom_rules_sorted="$CONFIG_DIR/.custom_rules_sorted"
  echo "$custom_rules_payloads" | grep -v '^$' | sort -t'|' -k1 -n > "$custom_rules_sorted" || true
  while IFS='|' read -r idx name payload_file; do
    # Защита от пустого имени
    [ -z "$name" ] && continue

rs_name="${name}_ruleset"

if ! ruleset_defined "$rs_name"; then
  cat <<EOF
  $rs_name:
    type: inline
    behavior: classical
    format: text
    payload:
$(sed 's/^/      - /' "$payload_file")
EOF
  register_ruleset "$rs_name"
fi

env_name=$(echo "$name" | tr '-' '_' | tr '[:lower:]' '[:upper:]')
dns=$(printenv "${env_name}_DNS" 2>/dev/null || true)
[ -n "$dns" ] && add_dns_policy "rule-set:${rs_name}" "$dns"
prio=$(printenv "${env_name}_PRIORITY" 2>/dev/null || echo $((2000 + idx)))

add_rule "RULE-SET,$rs_name,$name" "$prio"
  done < "$custom_rules_sorted"
  rm -f "$custom_rules_sorted"
fi

    cat <<EOF
  DNS_ruleset:
    type: inline
    behavior: classical
    format: text
    payload:
      - DOMAIN,dns.google
      - DOMAIN,dns.quad9.net
      - DOMAIN,cloudflare-dns.com
EOF

# Добавляем RULE-SET в all_rules (с приоритетом группы)
if [ -n "$custom_rules_payloads" ]; then
while IFS='|' read -r idx name payload; do
  [ -z "$name" ] && continue
  env_name=$(echo "$name" | tr '-' '_' | tr '[:lower:]' '[:upper:]')
  prio=$(printenv "${env_name}_PRIORITY" 2>/dev/null || echo $((2000 + idx)))

  add_rule "RULE-SET,${name}_ruleset,${name}" "$prio"
done <<EOF
$(echo "$custom_rules_payloads" | grep -v '^$' | sort -t'|' -k1 -n)
EOF
fi

    # Сортируем все правила по приоритету
    sorted_all_rules=$(echo "$all_rules" | grep -v '^$' | sort -t'|' -k1 -n | cut -d'|' -f2- | sed 's/^/  - /')

    # === rules ===
    echo
    echo "rules:"
    echo "  - RULE-SET,DNS_ruleset,DNS"
    echo "$sorted_all_rules"
    echo "  - IN-NAME,redir-in,GLOBAL"
    if lsmod | grep -q '^nft_tproxy' && [ "$TPROXY" = "true" ]; then
      echo "  - IN-NAME,tproxy-in,GLOBAL"
    else
      echo "  - IN-NAME,tun-in,GLOBAL"
    fi
    echo "  - IN-NAME,mixed-in,GLOBAL"
    echo "  - MATCH,DIRECT"
  } >> "$CONFIG_YAML"
cat >> "$CONFIG_YAML" <<EOF

dns:
  enable: true
  cache-algorithm: arc
  prefer-h3: false
  use-system-hosts: false
  respect-rules: true
  listen: 0.0.0.0:53
  ipv6: false
  default-nameserver:
    - 8.8.8.8
    - 9.9.9.9
    - 1.1.1.1
  enhanced-mode: ${DNS_MODE:-fake-ip}
  fake-ip-filter-mode: rule
  fake-ip-range: ${FAKE_IP_RANGE}
  fake-ip-ttl: ${FAKE_IP_TTL}
  fake-ip-filter:
EOF
for var in $(env | grep -E '^FAKE_IP_FILTER[0-9]+=' | sort -V | cut -d= -f1); do
  rule=$(printenv "$var" | xargs)
  [ -z "$rule" ] && continue
  echo "    - $rule" >> "$CONFIG_YAML"
done
    cat >> "$CONFIG_YAML" <<EOF
    - MATCH,fake-ip    
EOF
generate_nameserver_policy >>  $CONFIG_YAML
    cat >> "$CONFIG_YAML" <<EOF
  nameserver:
    - https://dns.google/dns-query#disable-qtype-65=true&disable-ipv6=true
    - https://cloudflare-dns.com/dns-query#disable-qtype-65=true&disable-ipv6=true
    - https://dns.quad9.net/dns-query#disable-qtype-65=true&disable-ipv6=true
  proxy-server-nameserver:
    - https://dns.google/dns-query#disable-qtype-65=true&disable-ipv6=true
    - https://cloudflare-dns.com/dns-query#disable-qtype-65=true&disable-ipv6=true
    - https://dns.quad9.net/dns-query#disable-qtype-65=true&disable-ipv6=true
    - https://common.dot.dns.yandex.net/dns-query#disable-qtype-65=true&disable-ipv6=true
hosts:
  dns.google: [8.8.8.8, 8.8.4.4]
  dns.quad9.net: [9.9.9.9, 149.112.112.112]
  cloudflare-dns.com: [104.16.248.249, 104.16.249.249]
  common.dot.dns.yandex.net: [77.88.8.8]
  
sniffer:
  enable: ${SNIFFER:-true}
  force-dns-mapping: false
  parse-pure-ip: false
  override-destination: false
  sniff:
    QUIC:
      ports: [443, 8443]
    TLS:
      ports: [443, 8443]
    HTTP:
      ports: [80, 8080-8880]
      override-destination: false
EOF
}

# ------------------- NFT -------------------
nft_rules() {
  echo "Applying nftables..."

  nft flush ruleset || true

  nft create table inet rawdrop
  nft add chain inet rawdrop prerouting "{ type filter hook prerouting priority raw; policy accept; }"
  nft add rule inet rawdrop prerouting ip daddr { $FAKE_IP_RANGE } meta l4proto != { tcp, udp } drop

  nft add table inet filter
  nft add chain inet filter input '{ type filter hook input priority filter; policy accept; }'
  nft add rule inet filter input ct state { established, related, untracked } accept
  nft add rule inet filter input ct state invalid drop
  nft add chain inet filter forward '{ type filter hook forward priority filter; policy accept; }'
  nft add rule inet filter forward ct state { established, related, untracked } accept
  nft add rule inet filter forward ct state invalid drop

  nft create table ip nat
  nft add chain ip nat postrouting "{ type nat hook postrouting priority srcnat; policy accept; }"
for iface in $(ip -o link show up | awk -F': ' '/link\/ether/ {gsub(/@.*$/,"",$2); if($2!="lo" && $2!~/^hs5t/ && $2!="Meta") print $2}'); do
  nft add rule ip nat postrouting oifname "$iface" masquerade
done

  iface=$(first_iface)
  iface_cidr=$(ip -4 -o addr show dev "$iface" scope global | awk '{print $4}')
  iface_ip=$(ip -4 addr show "$iface" | grep inet | awk '{ print $2 }' | cut -d/ -f1)

if [ "${TPROXY}" = "true" ]; then
  nft create table inet mihomo
  nft add chain inet mihomo pre "{type filter hook prerouting priority filter; policy accept;}"
  nft add rule inet mihomo pre meta iifname != "$iface" return 
  nft add rule inet mihomo pre tcp option mptcp exists drop
  nft add rule inet mihomo pre ip daddr { $iface_cidr, 127.0.0.0/8, 224.0.0.0/4, 255.255.255.255 } return
  nft add rule inet mihomo pre meta l4proto { tcp, udp } meta mark set 0x00000001 tproxy ip to 127.0.0.1:12346 accept
  nft add chain inet mihomo divert "{type filter hook prerouting priority mangle -1; policy accept;}"
  nft add rule inet mihomo divert meta l4proto { tcp, udp } socket transparent 1 meta mark set 0x00000001 accept
  ip rule show | grep -q 'fwmark 0x00000001 lookup 100' || ip rule add fwmark 1 table 100
  ip route replace local 0.0.0.0/0 dev lo table 100
  echo "Mode inbound TProxy(tcp,udp) interface $iface"
else
  nft create table inet mihomo
  nft add chain inet mihomo nat "{type nat hook prerouting priority dstnat + 1; policy accept;}"
  nft add rule inet mihomo nat meta iifname != "$iface" return
  nft add rule inet mihomo nat tcp option mptcp exists drop
  nft add rule inet mihomo nat ip daddr { $iface_cidr, 127.0.0.0/8, 198.19.0.0/30, 224.0.0.0/4, 255.255.255.255 } return
  nft add rule inet mihomo nat meta l4proto tcp redirect to 12345
  ip rule show | grep -q 'iif $iface ipproto tcp lookup main' || ip rule add iif $iface ipproto tcp lookup main priority 10000
  ip rule show | grep -q 'to $iface_cidr lookup main' || ip rule add to $iface_cidr lookup main priority 10001
  ip rule show | grep -q 'to 127.0.0.0/8 lookup main' || ip rule add to 127.0.0.0/8 lookup main priority 10002
  ip rule show | grep -q 'to 224.0.0.0/4 lookup main' || ip rule add to 224.0.0.0/4 lookup main priority 10003
  ip rule show | grep -q 'to 255.255.255.255 lookup main' || ip rule add to 255.255.255.255 lookup main priority 10004
  ip rule show | grep -q 'iif $iface ipproto udp lookup 110' || ip rule add iif $iface ipproto udp lookup 110 priority 10005
  ip route replace default via 100.64.0.1 dev Meta table 110
  echo "Mode inbound Redirect(tcp)+TUN(udp) interface $iface"
fi
[ -n "$ZAPRET_LIST" ] && apply_zapret_nft 300 300 "$ZAPRET_LIST"  zapret  ZAPRET  "$ZAPRET_PACKETS"
[ -n "$ZAPRET2_LIST" ] && apply_zapret_nft 400 400 "$ZAPRET2_LIST" zapret2 ZAPRET2 "$ZAPRET2_PACKETS"
[ -n "$ZAPRET2_WG_DST" ] && apply_zapret2_wg_nft
[ -n "$BYEDPI_LIST" ] && apply_byedpi_nft
for entry in $dscp_to_group; do
  dscp=${entry%%:*}
  table="dscp_${dscp}"
  chain="pre"
  port=$((7000 + dscp))
  nft create table inet $table
  nft add chain inet $table $chain "{type nat hook prerouting priority dstnat; policy accept;}"
  nft add rule inet $table $chain ip dscp != $dscp return
  nft add rule inet $table $chain meta iifname != "$iface" return
  nft add rule inet $table $chain tcp option mptcp exists drop
if [ "${TPROXY}" = "true" ]; then
  nft add rule inet $table $chain ip daddr { $iface_cidr, 127.0.0.0/8, 224.0.0.0/4, 255.255.255.255 } return
else
  nft add rule inet $table $chain ip daddr { $iface_cidr, 127.0.0.0/8, 198.19.0.0/30, 224.0.0.0/4, 255.255.255.255 } return
fi
  nft add rule inet $table $chain meta l4proto tcp redirect to $port
done
}

iptables_rules() {
  echo "Applying iptables..."

  iptables -F
  iptables -X
  iptables -t nat -F
  iptables -t nat -X
  iptables -t mangle -F
  iptables -t mangle -X
  iptables -t raw -F
  iptables -t raw -X
  iptables -t filter -F
  iptables -t filter -X
  iptables -t raw -A PREROUTING -d $FAKE_IP_RANGE -p tcp -j RETURN
  iptables -t raw -A PREROUTING -d $FAKE_IP_RANGE -p udp -j RETURN
  iptables -t raw -A PREROUTING -d $FAKE_IP_RANGE -j DROP
  iptables -t filter -A INPUT   -m conntrack --ctstate ESTABLISHED,RELATED,UNTRACKED -j ACCEPT
  iptables -t filter -A INPUT -m conntrack --ctstate INVALID -j DROP
  iptables -t filter -A FORWARD   -m conntrack --ctstate ESTABLISHED,RELATED,UNTRACKED -j ACCEPT
  iptables -t filter -A FORWARD -m conntrack --ctstate INVALID -j DROP
  for iface in $(ip -o link show up | awk -F': ' '/link\/ether/ {gsub(/@.*$/,"",$2); if($2!="lo" && $2!~/^hs5t/ && $2!="Meta") print $2}'); do
    iptables -t nat -A POSTROUTING -o "$iface" -j MASQUERADE
  done
  [ -n "$BYEDPI_LIST" ] && apply_byedpi_iptables
  iptables -t nat -A PREROUTING -m addrtype --dst-type LOCAL -j RETURN
  iptables -t nat -A PREROUTING -m addrtype ! --dst-type UNICAST -j RETURN
  iface=$(first_iface)
  iface_cidr=$(ip -4 -o addr show dev "$iface" scope global | awk '{print $4}')
  iface_ip=$(ip -4 addr show "$iface" | grep inet | awk '{ print $2 }' | cut -d/ -f1)
  for entry in $dscp_to_group; do
    dscp=${entry%%:*}
    port=$((7000 + dscp))
    iptables -t nat -A PREROUTING -i $iface -p tcp -m dscp --dscp $dscp -j REDIRECT --to-ports $port
  done
  iptables -t nat -A PREROUTING -i $iface -p tcp -j REDIRECT --to-ports 12345
  ip rule show | grep -q 'iif $iface ipproto tcp lookup main' || ip rule add iif $iface ipproto tcp lookup main priority 10000
  ip rule show | grep -q 'to $iface_cidr lookup main' || ip rule add to $iface_cidr lookup main priority 10001
  ip rule show | grep -q 'to 127.0.0.0/8 lookup main' || ip rule add to 127.0.0.0/8 lookup main priority 10002
  ip rule show | grep -q 'to 224.0.0.0/4 lookup main' || ip rule add to 224.0.0.0/4 lookup main priority 10003
  ip rule show | grep -q 'to 255.255.255.255 lookup main' || ip rule add to 255.255.255.255 lookup main priority 10004
  ip rule show | grep -q 'iif $iface ipproto udp lookup 110' || ip rule add iif $iface ipproto udp lookup 110 priority 10005
  ip route replace default via 100.64.0.1 dev Meta table 110
  echo "Mode inbound Redirect(tcp)+TUN(udp) interface $iface"
}

# ------------------- RUN -------------------
wait_for_meta() {
  for i in $(seq 1 50); do
    if ip link show Meta >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

run() {
  mkdir -p "$CONFIG_DIR" "$AWG_DIR" "$PROXIES_DIR" "$RULE_SET_DIR"
  # Wipe runtime dirs on every start — everything here is regenerated below.
  rm -rf "$RUNTIME_DIR" "$HS5T_DIR"
  mkdir -p "$RUNTIME_DIR" "$HS5T_DIR"
  # Clean up stale hs5t artefacts from previous installs (when they lived in /).
  rm -f /hs5t_*.yml /hs5t_*.sh

  UNSPEC_PREF=$(ip rule show | awk '/lookup unspec/ {print $1}' | tr -d :)
  MASQUERADE_PREF=$(ip rule show | awk '/lookup masquerade/ {print $1}' | tr -d :)
  LOCAL_PREF=$(ip rule show | awk '/lookup local/ {print $1}' | tr -d :)
  MAIN_PREF=$(ip rule show | awk '/lookup main/ {print $1}' | tr -d :)
  DEFAULT_PREF=$(ip rule show | awk '/lookup default/ {print $1}' | tr -d :)

  [ -n "$UNSPEC_PREF" ] && ip rule del pref $UNSPEC_PREF
  [ -n "$MASQUERADE_PREF" ] && ip rule del pref $MASQUERADE_PREF
  ip rule del pref $LOCAL_PREF 2>/dev/null || true
  ip rule del pref $MAIN_PREF 2>/dev/null || true
  ip rule del pref $DEFAULT_PREF 2>/dev/null || true

  ip rule add pref 0 lookup local
  ip rule add pref 32766 lookup main
  ip rule add pref 32767 lookup default

  prepare_interface_routes

  config_file_mihomo

  echo "Starting Mihomo $(mihomo -v)"

  # -d keeps mihomo's own data (UI, geo databases, cache) on flash;
  # -f points to the entrypoint-generated config that lives in RAM.
  # SAFE_PATHS whitelists RUNTIME_DIR so mihomo accepts proxy-providers
  # whose `path:` points to /dev/shm/mihomo/*.yaml (outside its home dir).
  # Colon-separated on Linux per mihomo docs.
  SAFE_PATHS="$RUNTIME_DIR" mihomo -d "$CONFIG_DIR" -f "$CONFIG_YAML" &
  MIHOMO_PID=$!

  wait_for_meta

  if lsmod | grep nf_tables >/dev/null 2>&1; then
    nft_rules
  else
    iptables_rules
  fi

  if lsmod | grep nf_tables >/dev/null 2>&1; then
    start_zapret_processes 300 nfqws  "$ZAPRET_LIST"
    start_zapret_processes 400 nfqws2 "$ZAPRET2_LIST"
    start_zapret2_wg
  fi

  if [ "${BYEDPI}" = "true" ]; then
    start_byedpi_processes
  fi

  # Web UI runs from RAM. /www is the source (mounted, may not allow chmod
  # or be on flash). /dev/shm/web is the runtime docroot:
  #   - cgi-bin: copied so chmod +x works (tmpfs supports unix mode bits)
  #   - HTML:    rendered straight to RAM (no flash wear)
  #   - assets:  symlinks back to /www (picked up live without container restart)
  WEBROOT=/dev/shm/web
  mkdir -p "$WEBROOT"
  rm -rf "$WEBROOT/cgi-bin"
  cp -r /www/cgi-bin "$WEBROOT/cgi-bin"
  chmod +x "$WEBROOT/cgi-bin/"* 2>/dev/null || true
  for item in assets templates favicon.png style.css ui.js; do
    [ -e "/www/$item" ] && ln -sfn "/www/$item" "$WEBROOT/$item"
  done
  WWW_DIR="$WEBROOT" /bin/sh /www/render_static.sh >/dev/null 2>&1 || true
  httpd -f -p 80 -h "$WEBROOT" >/dev/null 2>&1 &

  wait $MIHOMO_PID
}

run || exit 1
