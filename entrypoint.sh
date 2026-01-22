#!/bin/sh

sleep 1

if ! lsmod | grep nf_tables >/dev/null 2>&1; then
  if ! apk info -e iptables iptables-legacy >/dev/null 2>&1; then
    echo "Install iptables"
    apk add --no-cache iptables iptables-legacy >/dev/null 2>&1
    rm -f /usr/sbin/iptables /usr/sbin/iptables-save /usr/sbin/iptables-restore
    ln -s /usr/sbin/iptables-legacy /usr/sbin/iptables
    ln -s /usr/sbin/iptables-legacy-save /usr/sbin/iptables-save
    ln -s /usr/sbin/iptables-legacy-restore /usr/sbin/iptables-restore
  fi
else
  if ! apk info -e nftables >/dev/null 2>&1; then
    echo "Install nftables"
    apk add --no-cache nftables >/dev/null 2>&1
  fi
  if apk info -e iptables iptables-legacy >/dev/null 2>&1; then
    echo "Delete iptables"
    apk del iptables iptables-legacy >/dev/null 2>&1
  fi
fi

echo 180  > /proc/sys/net/netfilter/nf_conntrack_udp_timeout_stream

set -eu

TPROXY="${TPROXY:-true}"
EXTERNAL_UI_URL="${EXTERNAL_UI_URL:-https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip}"
UI_SECRET="${UI_SECRET:-}"
CONFIG_DIR="/root/.config/mihomo"
AWG_DIR="$CONFIG_DIR/awg"
PROXIES_DIR="$CONFIG_DIR/proxies_mount"
RULE_SET_DIR="$CONFIG_DIR/rule_set_list"
CONFIG_YAML="$CONFIG_DIR/config.yaml"
BYEDPI_YAML="$CONFIG_DIR/byedpi.yaml"
ZAPRET_YAML="$CONFIG_DIR/zapret.yaml"
ZAPRET2_YAML="$CONFIG_DIR/zapret2.yaml"
UI_URL_CHECK="$CONFIG_DIR/.ui_url"
FAKE_IP_RANGE="${FAKE_IP_RANGE:-198.18.0.0/15}"
FAKE_IP_TTL="${FAKE_IP_TTL:-1}"
FAKE_IP_FILTER="${FAKE_IP_FILTER:-}"
BYEDPI_CMD="${BYEDPI_CMD:-}"
BYEDPI_CMD_UDP="${BYEDPI_CMD_UDP:-}"
ZAPRET_PACKETS="${ZAPRET_PACKETS:-12}"
ZAPRET2_PACKETS="${ZAPRET2_PACKETS:-12}"
HEALTHCHECK_INTERVAL="${HEALTHCHECK_INTERVAL:-120}"
HEALTHCHECK_URL="${HEALTHCHECK_URL:-https://www.gstatic.com/generate_204}"
HEALTHCHECK_URL_STATUS="${HEALTHCHECK_URL_STATUS:-204}"
HEALTHCHECK_PROVIDER="${HEALTHCHECK_PROVIDER:-true}"
SUB_LINK_INTERVAL="${SUB_LINK_INTERVAL:-3600}"
GROUP_TYPE="${GROUP_TYPE:-select}"
GROUP_USE="${GROUP_USE:-}"
GROUP_FILTER="${GROUP_FILTER:-}"
GROUP_EXCLUDE="${GROUP_EXCLUDE:-}"
GROUP_EXCLUDE_TYPE="${GROUP_EXCLUDE_TYPE:-}"
GROUP_URL="${GROUP_URL:-https://www.gstatic.com/generate_204}"
GROUP_URL_STATUS="${GROUP_URL_STATUS:-204}"
GROUP_INTERVAL="${GROUP_INTERVAL:-60}"
GROUP_TOLERANCE="${GROUP_TOLERANCE:-20}"
GROUP_STRATEGY="${GROUP_STRATEGY:-consistent-hashing}"
[ -n "$BYEDPI_CMD" ] && BYEDPI=true || BYEDPI=false

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

log() { echo "[$(date +'%H:%M:%S')] $*"; }

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
generate_byedpi_yaml() {
  [ "$BYEDPI" = "true" ] || return 0
  echo "Generating $BYEDPI_YAML"
  cat > "$BYEDPI_YAML" <<EOF
proxies:
  - name: "BYEDPI"
    type: direct
    udp: true
    ip-version: ipv4
    routing-mark: 131
EOF
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
    yaml="$CONFIG_DIR/${name}.yaml"

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
    path: ${name}.yaml
EOF
    if [ "${HEALTHCHECK_PROVIDER}" = "true" ]; then
      cat >> "$CONFIG_YAML" <<EOF
    health-check:
      enable: true
      url: ${HEALTHCHECK_URL_ZAPRET:-https://www.facebook.com}
      interval: $HEALTHCHECK_INTERVAL
      timeout: 1500
      lazy: false
      expected-status: ${HEALTHCHECK_URL_STATUS_ZAPRET:-200}
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
    ./$bin --qnum $queue --user=root $LUA_INIT_ARGS $cmd &
  done
}

# ------------------- AWG / WG -------------------
parse_awg_config() {
  local config_file="$1"
  local awg_name=$(basename "$config_file" .conf)

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
    while IFS= read -r addr; do
      addr=$(echo "$addr" | sed 's/[[:space:]]//g')
      if echo "$addr" | grep -q ':'; then
        [ -n "$ip_v6" ] && ip_v6="$ip_v6,"
        ip_v6="${ip_v6}${addr}"
      else
        [ -n "$ip_v4" ] && ip_v4="$ip_v4,"
        ip_v4="${ip_v4}${addr}"
      fi
    done < <(echo "$address" | tr ',' '\n')
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
  if [ -n "$dns_raw" ]; then
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
    [ -n "$i1" ]     && echo "      i1: $i1"
    [ -n "$i2" ]     && echo "      i2: $i2"
    [ -n "$i3" ]     && echo "      i3: $i3"
    [ -n "$i4" ]     && echo "      i4: $i4"
    [ -n "$i5" ]     && echo "      i5: $i5"
    [ -n "$j1" ]     && echo "      j1: $j1"
    [ -n "$j2" ]     && echo "      j2: $j2"
    [ -n "$j3" ]     && echo "      j3: $j3"
    [ -n "$itime" ]  && echo "      itime: $itime"
  fi
  echo ""
}

generate_awg_providers() {
  local awg_providers=""
  if ls "$AWG_DIR"/*.conf >/dev/null 2>&1; then
    for conf in "$AWG_DIR"/*.conf; do
      [ ! -f "$conf" ] && continue
      local awg_name=$(basename "$conf" .conf)
      local awg_yaml="${CONFIG_DIR}/${awg_name}.yaml"

      {
        echo "proxies:"
        parse_awg_config "$conf"
      } > "$awg_yaml"

      cat >> "$CONFIG_YAML" <<EOF
  ${awg_name}:
    type: file
    path: ${awg_name}.yaml
EOF
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
      local target_yaml="${CONFIG_DIR}/${provider_name}.yaml"
      cp "$yaml_file" "$target_yaml"
      cat >> "$CONFIG_YAML" <<EOF
  ${provider_name}:
    type: file
    path: ${provider_name}.yaml
EOF
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
  [ -z "${NAMESERVER_POLICY:-}" ] && return
  echo "  nameserver-policy:"
  OLDIFS=$IFS
  IFS=','
  for raw in $NAMESERVER_POLICY; do
    item=$(printf '%s' "$raw" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -z "$item" ] && continue
    domain=${item%%#*}
    dns=${item#*#}
    printf "    '%s': '%s'\n" "$domain" "$dns"
  done
  IFS=$OLDIFS
}

# ===== Registries =====

DEFINED_GROUPS=""
DEFINED_RULESETS=""
DEFINED_RULES=""

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
log-level: ${LOG_LEVEL:-error}
external-controller: 0.0.0.0:9090
secret: $UI_SECRET
external-ui: ui
external-ui-url: "$EXTERNAL_UI_URL"
unified-delay: true
ipv6: false
geodata-mode: true
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
hosts:
  dns.google: [8.8.8.8, 8.8.4.4]
  dns.quad9.net: [9.9.9.9, 149.112.112.112]
  cloudflare-dns.com: [104.16.248.249, 104.16.249.249]
  
sniffer:
  enable: ${SNIFFER:-true}
  sniff:
    QUIC:
    TLS:
    HTTP:

listeners:
EOF

  if lsmod | grep -q '^nft_tproxy' && [ "$TPROXY" = "true" ]; then
    cat >> "$CONFIG_YAML" <<EOF
  - name: tproxy-in
    type: tproxy
    port: 12345
    listen: 0.0.0.0
    udp: true
EOF
  else
    cat >> "$CONFIG_YAML" <<EOF
  - name: redir-in
    type: redir
    port: 12345
    listen: 0.0.0.0
  - name: tun-in
    type: tun
    stack: system
    disable-icmp-forwarding: true
    auto-detect-interface: false
    include-interface:
      - $(first_iface)
    auto-route: true
    auto-redirect: false
    inet4-address:
      - 198.19.0.1/30
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
    for varname in $(env | grep -E '^LINK[0-9]*=' | sort -t '=' -k1 | cut -d'=' -f1); do
      eval "url=\"\$$varname\""
      provider_name="$varname"
      yaml_file="$CONFIG_DIR/${provider_name}.yaml"
      printf '%s\n' "$url" > "$yaml_file"
      cat >> "$CONFIG_YAML" <<EOF
  $provider_name:
    type: file
    path: ${provider_name}.yaml
EOF
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
  done < <(env | grep -E '^SUB_LINK[0-9]+=' | sort -V)

  # AWG
  awg_provs=$(generate_awg_providers)
  providers="${providers}${awg_provs}"
  dns_other="${dns_other}${awg_provs}"

# SOCKS5
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
    yaml_file="$CONFIG_DIR/${name}.yaml"
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
    path: ${name}.yaml
EOF
    if [ "${HEALTHCHECK_PROVIDER}" = "true" ]; then
      cat >> "$CONFIG_YAML" <<EOF
$(health_check_block)
EOF
    fi
    providers="$providers $name"
    dns_other="$dns_other $name"
  done < <(env | grep -E '^SOCKS[0-9]+=' | sort -V)

  # ZAPRET
  generate_zapret_proxies 300 ZAPRET "$ZAPRET_LIST"
  generate_zapret_proxies 400 ZAPRET2 "$ZAPRET2_LIST"

  # BYEDPI
  if [ "$BYEDPI" = "true" ]; then
    cat >> "$CONFIG_YAML" <<EOF
  BYEDPI:
    type: file
    path: $(basename "$BYEDPI_YAML")
EOF
    if [ "${HEALTHCHECK_PROVIDER}" = "true" ]; then
      cat >> "$CONFIG_YAML" <<EOF
    health-check:
      enable: true
      url: ${HEALTHCHECK_URL_BYEDPI:-https://www.facebook.com}
      interval: $HEALTHCHECK_INTERVAL
      timeout: 1500
      lazy: false
      expected-status: ${HEALTHCHECK_URL_STATUS_BYEDPI:-200}
EOF
    fi
    providers="$providers BYEDPI"
  fi
  
  # all interfaces
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
        ip rule add fwmark $i table $i 2>/dev/null || true
    fi
  if [ $i = 200 ]; then
    ip route del default
    ip route replace default via $gw dev $iface
  else
    ip route replace default via $gw dev $iface table $i
    ip rule del table $i 2>/dev/null
    ip rule add fwmark $i table $i
  fi

  echo "Generating $CONFIG_DIR/$iface.yaml with interface: $iface"
  
  cat > "$CONFIG_DIR/$iface.yaml" <<EOF
proxies:
  - name: "$iface"
    type: direct
    udp: true
    ip-version: ipv4
    interface-name: "$iface"
EOF
  if [ $i -gt 200 ]; then
  cat >> "$CONFIG_DIR/$iface.yaml" <<EOF    
    routing-mark: $i
EOF
  fi

  cat >> "$CONFIG_YAML" <<EOF
  $iface:
    type: file
    path: $iface.yaml
EOF
    if [ "${HEALTHCHECK_PROVIDER}" = "true" ]; then
      cat >> "$CONFIG_YAML" <<EOF
$(health_check_block)
EOF
    fi
 
  providers="$providers $iface"
  i=$((i+1))
done

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
[ "$BYEDPI"  = "true" ] && dns_zapret="$dns_zapret BYEDPI"
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

      ruleset_file="$CONFIG_DIR/${name}_ruleset_payload.txt"
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

        ruleset_file="$CONFIG_DIR/${name}_ruleset_payload.txt"

        cp "$f" "$ruleset_file"

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
    g_tol="${GLOBAL_TOLERANCE:-$GROUP_TOLERANCE}"
    g_url="${GLOBAL_URL:-$GROUP_URL}"
    g_status="${GLOBAL_URL_STATUS:-$GROUP_URL_STATUS}"
    g_interval="${GLOBAL_INTERVAL:-$GROUP_INTERVAL}"
    g_strategy="${GLOBAL_STRATEGY:-$GROUP_STRATEGY}"
    g_icon="${GLOBAL_ICON:-}"
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
      echo "    use:"
      if [ -n "$use" ]; then
        echo "$use" | tr ',' '\n' | sed 's/^/      - /'
      else
      for p in $providers; do echo "      - $p"; done
    fi

    # DNS

    type="${DNS_TYPE:-select}"
    filter="${DNS_FILTER:-}"
    exclude="${DNS_EXCLUDE:-}"
    exclude_type="${DNS_EXCLUDE_TYPE:-}"
    use="${DNS_USE:-}"
    g_tol="${DNS_TOLERANCE:-$GROUP_TOLERANCE}"
    g_url="${DNS_URL:-$GROUP_URL}"
    g_status="${DNS_URL_STATUS:-$GROUP_URL_STATUS}"
    g_interval="${DNS_INTERVAL:-$GROUP_INTERVAL}"
    g_strategy="${DNS_STRATEGY:-$GROUP_STRATEGY}"
    g_icon="${DNS_ICON:-}"
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
      echo "    use:"
      if [ -n "$use" ]; then
        echo "$use" | tr ',' '\n' | sed 's/^/      - /'
      else
      for p in $dns_providers; do echo "      - $p"; done
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
        for suffix in GEOSITE GEOIP AS DOMAIN SUFFIX IPCIDR KEYWORD SRCIPCIDR; do
          if [ -n "$(printenv "${env_name}_${suffix}" 2>/dev/null || echo "")" ]; then
            has_resource=true
            break
          fi
        done

        if ! $has_resource; then
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
      g_tol=$(printenv "${env_name}_TOLERANCE" || echo "$GROUP_TOLERANCE")
      g_url=$(printenv "${env_name}_URL" || echo "$GROUP_URL")
      g_status=$(printenv "${env_name}_URL_STATUS" || echo "$GROUP_URL_STATUS")
      g_interval=$(printenv "${env_name}_INTERVAL" || echo "$GROUP_INTERVAL")
      g_strategy=$(printenv "${env_name}_STRATEGY" || echo "$GROUP_STRATEGY")
      g_icon=$(printenv "${env_name}_ICON" || echo "")
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
        echo "    use:"
        if [ -n "$use" ]; then
          echo "$use" | tr ',' '\n' | sed 's/^/      - /'
        else
          for p in $providers; do echo "      - $p"; done
        fi
        register_group "$g"
      fi
    done

# Сбор приоритетов для custom rule-set групп (по аналогии с GROUP)
    custom_group_prio_list=""
    custom_idx=0

    # Проходим по уже собранным custom name
    if [ -n "$custom_rules_payloads" ]; then
      echo "$custom_rules_payloads" | grep -v '^$' | sort -t'|' -k1 -n | while IFS='|' read -r idx name payload_file; do
        env_name=$(echo "$name" | tr '-' '_' | tr '[:lower:]' '[:upper:]')
        prio=$(printenv "${env_name}_PRIORITY" 2>/dev/null || echo "")
        [ -z "$prio" ] && prio=$((2000 + custom_idx))   # дефолт, если нет ENV
        custom_group_prio_list="$custom_group_prio_list $name|$prio"
        custom_idx=$((custom_idx + 1))
      done
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
        g_tol=$(printenv "${env_name}_TOLERANCE" || echo "$GROUP_TOLERANCE")
        g_url=$(printenv "${env_name}_URL" || echo "$GROUP_URL")
        g_status=$(printenv "${env_name}_URL_STATUS" || echo "$GROUP_URL_STATUS")
        g_interval=$(printenv "${env_name}_INTERVAL" || echo "$GROUP_INTERVAL")
        g_strategy=$(printenv "${env_name}_STRATEGY" || echo "$GROUP_STRATEGY")
        g_icon=$(printenv "${env_name}_ICON" || echo "")
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
          echo "    use:"
          if [ -n "$use" ]; then
            echo "$use" | tr ',' '\n' | sed 's/^/      - /'
          else
            for p in $providers; do echo "      - $p"; done
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
      - IP-CIDR,$ipcidr,no-resolve"
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
fi

add_rule "RULE-SET,$rs_name,$g" "$group_prio"
        all_rules="$all_rules
$group_prio|RULE-SET,${g}_custom_rules,$g"
      fi

      idx=$((idx + 1))
    done

# Добавляем inline rule-providers для custom
if [ -n "$custom_rules_payloads" ]; then
  echo "$custom_rules_payloads" | grep -v '^$' | sort -t'|' -k1 -n | while IFS='|' read -r idx name payload_file; do
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

add_rule "RULE-SET,$rs_name,$name" "$prio"
  done
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

  all_rules="${all_rules}
${prio}|RULE-SET,${name}_ruleset,${name}"
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
    if lsmod | grep -q '^nft_tproxy' && [ "$TPROXY" = "true" ]; then
      echo "  - IN-NAME,tproxy-in,GLOBAL"
    else
      echo "  - IN-NAME,redir-in,GLOBAL"
      echo "  - IN-NAME,tun-in,GLOBAL"
    fi
    echo "  - IN-NAME,mixed-in,GLOBAL"
    echo "  - MATCH,DIRECT"
  } >> "$CONFIG_YAML"
}

# ------------------- NFT -------------------
nft_rules() {
  echo "Applying nftables..."
  iface=$(first_iface)
  iface_cidr=$(ip -4 -o addr show dev "$iface" scope global | awk '{print $4}')
  iface_ip=$(ip -4 addr show "$iface" | grep inet | awk '{ print $2 }' | cut -d/ -f1)
  nft flush ruleset || true
if [ "${TPROXY}" = "true" ]; then
  nft create table inet mihomo
  nft add chain inet mihomo pre "{type filter hook prerouting priority filter; policy accept;}"
  nft add rule inet mihomo pre tcp option mptcp exists drop
  nft add rule inet mihomo pre ip daddr ${FAKE_IP_RANGE} meta l4proto { tcp, udp } iifname "$iface" meta mark set 0x00000001 tproxy ip to 127.0.0.1:12345 accept
  nft add rule inet mihomo pre ip daddr { $iface_cidr, 127.0.0.0/8, 224.0.0.0/4, 255.255.255.255 } return
  nft add rule inet mihomo pre meta l4proto { tcp, udp } iifname "$iface" meta mark set 0x00000001 tproxy ip to 127.0.0.1:12345 accept
  nft add chain inet mihomo divert "{type filter hook prerouting priority mangle; policy accept;}"
  nft add rule inet mihomo divert meta l4proto tcp socket transparent 1 meta mark set 0x00000001 accept
  ip rule show | grep -q 'fwmark 0x00000001 lookup 100' || ip rule add fwmark 1 table 100
  ip route replace local 0.0.0.0/0 dev lo table 100
  echo "Mode inbound TProxy(tcp,udp) interface $iface"
else
  nft create table inet mihomo
  nft add chain inet mihomo pre "{type nat hook prerouting priority -99; policy accept;}"
  nft add rule inet mihomo pre meta iifname != "$iface" return 
  nft add rule inet mihomo pre meta l4proto { tcp, udp } th dport 53 iifname "$iface" dnat ip to 198.19.0.2
  nft add rule inet mihomo pre ip daddr { $iface_cidr, 127.0.0.0/8, 198.19.0.0/30, 224.0.0.0/4, 255.255.255.255 } return
  nft add rule inet mihomo pre tcp option mptcp 1 drop
  nft add rule inet mihomo pre meta nfproto 2 meta l4proto tcp redirect to 12345
  echo "Mode inbound Redirect(tcp)+TUN(udp) interface $iface"
fi
[ -n "$ZAPRET_LIST" ] && apply_zapret_nft 300 300 "$ZAPRET_LIST"  zapret  ZAPRET  "$ZAPRET_PACKETS"
[ -n "$ZAPRET2_LIST" ] && apply_zapret_nft 400 400 "$ZAPRET2_LIST" zapret2 ZAPRET2 "$ZAPRET2_PACKETS"
if [ "${BYEDPI}" = "true" ] || [ "${TPROXY}" = "false" ]; then
  nft add table nat
  nft add chain nat output '{ type nat hook output priority -100; }'
  if [ "${BYEDPI}" = "true" ]; then
    nft add rule nat output meta l4proto tcp mark 0x00000083 redirect to 1100
  fi
  if [ "${TPROXY}" = "false" ]; then  
    nft add rule nat output meta l4proto tcp oifname "Meta" redirect to 12345
  fi
fi
}

iptables_rules() {
  echo "Applying iptables..."
  local iface=$(first_iface)
  iptables -F
  iptables -X
  iptables -t nat -F
  iptables -t nat -X
  iptables -t mangle -F
  iptables -t mangle -X
  iptables -t nat -N mihomo-output
  iptables -t nat -N mihomo-prerouting
  iptables -t nat -A PREROUTING -j mihomo-prerouting
  iptables -t nat -A OUTPUT -j mihomo-output
  if [ "${BYEDPI}" = "true" ]; then
  iptables -t nat -A mihomo-output -p tcp -m mark --mark 131 -j REDIRECT --to-port 1100
  fi
  iptables -t nat -A mihomo-output -o Meta -p tcp -j REDIRECT --to-ports 12345
  iptables -t nat -A mihomo-prerouting -i Meta -j RETURN
  iptables -t nat -A mihomo-prerouting -i $iface -p udp -m udp --dport 53 -j DNAT --to-destination 198.19.0.2
  iptables -t nat -A mihomo-prerouting -i $iface -p tcp -m tcp --dport 53 -j DNAT --to-destination 198.19.0.2
  iptables -t nat -A mihomo-prerouting -m addrtype --dst-type LOCAL -j RETURN
  iptables -t nat -A mihomo-prerouting -m addrtype ! --dst-type UNICAST -j RETURN
  iptables -t nat -A mihomo-prerouting -i $iface -p tcp -j REDIRECT --to-ports 12345
  echo "Mode inbound Redirect(tcp)+TUN(udp) interface $iface"
}

config_file() {
  cat > /hs5t.yml << EOF
misc:
  log-level: 'error'
tunnel:
  name: hs5t
  mtu: 1500
  ipv4: 100.64.0.1
  multi-queue: true
  post-up-script: '/hs5t.sh'
socks5:
  address: '127.0.0.1'
  port: 1090
  udp: 'udp'
EOF
}

hs5t_file() {
  cat > /hs5t.sh << 'EOF'
#!/bin/sh
ip rule show | grep -q 'fwmark 0x83 ipproto udp lookup 131' || ip rule add fwmark 131 ipproto udp table 131
ip route replace default via 100.64.0.1 dev hs5t table 131
EOF
chmod +x /hs5t.sh
}

# ------------------- RUN -------------------
run() {
  mkdir -p "$CONFIG_DIR" "$AWG_DIR" "$PROXIES_DIR" "$RULE_SET_DIR"
  if lsmod | grep -q '^nft_tproxy'; then
    nft_rules
  else
    iptables_rules
  fi
  if [ "${BYEDPI}" = "true" ]; then
    generate_byedpi_yaml
    config_file
    hs5t_file
    echo "Starting ByeDPI v.$(./byedpi --version) "
    echo "Starting hev-socks5-tunnel $(./hs5t --version | head -n 2 | tail -n 1)"
    local cmd_udp=$(printenv "$BYEDPI_CMD_UDP" || echo "$BYEDPI_CMD")
  fi
  config_file_mihomo
  echo "Starting Mihomo $(./mihomo -v)"
  if lsmod | grep -q '^nft_tproxy'; then
  start_zapret_processes 300 nfqws  "$ZAPRET_LIST"
  start_zapret_processes 400 nfqws2 "$ZAPRET2_LIST"
  fi
  if [ "${BYEDPI}" = "true" ]; then
    ./byedpi --port 1100 --transparent $BYEDPI_CMD &
    ./byedpi --port 1090 $cmd_udp &
    ./hs5t ./hs5t.yml &
  fi
  exec ./mihomo
}

run || exit 1
