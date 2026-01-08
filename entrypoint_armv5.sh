#!/usr/bin/sh

set -eu

EXTERNAL_UI_URL="${EXTERNAL_UI_URL:-https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip}"
UI_SECRET="${UI_SECRET:-}"
CONFIG_DIR="/root/.config/mihomo"
AWG_DIR="$CONFIG_DIR/awg"
PROXIES_DIR="$CONFIG_DIR/proxies_mount"
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
ZAPRET_CMD="${ZAPRET_CMD:-}"
ZAPRET2_CMD="${ZAPRET2_CMD:-}"
HEALTHCHECK_INTERVAL="${HEALTHCHECK_INTERVAL:-120}"
HEALTHCHECK_URL="${HEALTHCHECK_URL:-https://www.gstatic.com/generate_204}"
HEALTHCHECK_URL_STATUS="${HEALTHCHECK_URL_STATUS:-204}"
HEALTHCHECK_PROVIDER="${HEALTHCHECK_PROVIDER:-true}"
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
if [ -n "$ZAPRET_CMD" ] && lsmod | grep -q '^nft_tproxy'; then
  ZAPRET=true
else
  ZAPRET=false
fi
if [ -n "$ZAPRET2_CMD" ] && lsmod | grep -q '^nft_tproxy'; then
  ZAPRET2=true
else
  ZAPRET2=false
fi

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
generate_zapret_yaml() {
  [ "$ZAPRET" = "true" ] || return 0
  echo "Generating $ZAPRET_YAML"
  cat > "$ZAPRET_YAML" <<EOF
proxies:
  - name: "ZAPRET"
    type: direct
    udp: true
    ip-version: ipv4
    routing-mark: 132
EOF
}

# ------------------- ZAPRET2 -------------------
generate_zapret2_yaml() {
  [ "$ZAPRET2" = "true" ] || return 0
  echo "Generating $ZAPRET2_YAML"
  cat > "$ZAPRET2_YAML" <<EOF
proxies:
  - name: "ZAPRET2"
    type: direct
    udp: true
    ip-version: ipv4
    routing-mark: 133
EOF
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
  respect-rules: false
  listen: 0.0.0.0:53
  ipv6: false
  default-nameserver:
    - 8.8.8.8
    - 9.9.9.9
    - 1.1.1.1
  enhanced-mode: ${DNS_MODE:-fake-ip}
  fake-ip-filter-mode: ${FAKE_IP_FILTER_MODE:-blacklist}
  fake-ip-range: ${FAKE_IP_RANGE}
  fake-ip-ttl: ${FAKE_IP_TTL}${FAKE_IP_FILTER:+
  fake-ip-filter:}${FAKE_IP_FILTER:+$(printf '\n    - %s' $(echo "$FAKE_IP_FILTER" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$'))}
EOF
generate_nameserver_policy >>  $CONFIG_YAML
    cat >> "$CONFIG_YAML" <<EOF
  nameserver:
    - https://dns.google/dns-query
    - https://cloudflare-dns.com/dns-query
    - https://dns.quad9.net/dns-query
hosts:
  dns.google: [8.8.8.8, 8.8.4.4]
  dns.quad9.net: [9.9.9.9, 149.112.112.112]
  cloudflare-dns.com: [104.16.248.249, 104.16.249.249]
  ntc.party: [130.255.77.28]

sniffer:
  enable: ${SNIFFER:-true}
  sniff:
    QUIC:
    TLS:
    HTTP:

listeners:
EOF

  if lsmod | grep -q '^nft_tproxy'; then
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
    done
  fi
  
  # MOUNTED PROXIES from $PROXIES_DIR
  mounted_provs=$(generate_mounted_providers)
  providers="${providers}${mounted_provs}"

  # SUB_LINK
  while IFS= read -r var; do
    name=$(echo "$var" | cut -d '=' -f1)
    url=$(echo "$var" | cut -d '=' -f2- | tr -d '\r')
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
    interval: 86400
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
  done < <(env | grep -E '^SUB_LINK[0-9]+=' | sort -V)

  # AWG
  awg_provs=$(generate_awg_providers)
  providers="${providers}${awg_provs}"

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
  done < <(env | grep -E '^SOCKS[0-9]+=' | sort -V)

  # ZAPRET
  if [ "$ZAPRET" = "true" ]; then
    cat >> "$CONFIG_YAML" <<EOF
  ZAPRET:
    type: file
    path: $(basename "$ZAPRET_YAML")
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
    providers="$providers ZAPRET"
  fi

  # ZAPRET2
  if [ "$ZAPRET2" = "true" ]; then
    cat >> "$CONFIG_YAML" <<EOF
  ZAPRET2:
    type: file
    path: $(basename "$ZAPRET2_YAML")
EOF
    if [ "${HEALTHCHECK_PROVIDER}" = "true" ]; then
      cat >> "$CONFIG_YAML" <<EOF
    health-check:
      enable: true
      url: ${HEALTHCHECK_URL_ZAPRET2:-https://www.facebook.com}
      interval: $HEALTHCHECK_INTERVAL
      timeout: 1500
      lazy: false
      expected-status: ${HEALTHCHECK_URL_STATUS_ZAPRET2:-200}
EOF
    fi
    providers="$providers ZAPRET2"
  fi

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
      [ -n "$filter" ] && echo "    filter: $filter"
      [ -n "$exclude" ] && echo "    exclude-filter: $exclude"
      [ -n "$exclude_type" ] && echo "    exclude-type: $exclude_type"
      echo "    use:"
      if [ -n "$use" ]; then
        echo "$use" | tr ',' '\n' | sed 's/^/      - /'
      else
      for p in $providers; do echo "      - $p"; done
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
      [ -n "$filter" ] && echo "    filter: $filter"
      [ -n "$exclude" ] && echo "    exclude-filter: $exclude"
      [ -n "$exclude_type" ] && echo "    exclude-type: $exclude_type"
      echo "    use:"
      if [ -n "$use" ]; then
        echo "$use" | tr ',' '\n' | sed 's/^/      - /'
      else
        for p in $providers; do echo "      - $p"; done
      fi
    done

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
        cat <<EOF
  ${g}_geosite_$gs:
    type: http
    behavior: domain
    format: mrs
    url: "https://github.com/MetaCubeX/meta-rules-dat/raw/refs/heads/meta/geo/geosite/$gs.mrs"
    interval: 86400
EOF
        all_rules="$all_rules
$group_prio|RULE-SET,${g}_geosite_$gs,$g"
      done

      # GEOIP
      geoip_list=$(printenv "${env_name}_GEOIP" || echo "")
      for gi in $(echo "$geoip_list" | tr ',' ' ' | xargs -n1); do
        [ -z "$gi" ] && continue

        if [ "$gi" = "discord" ]; then
          cat <<EOF
  ${g}_geoip_$gi:
    type: http
    behavior: ipcidr
    format: text
    url: "https://raw.githubusercontent.com/Medium1992/mihomo-proxy-ros/refs/heads/main/custom_list/discord.list"
    interval: 86400
EOF
          all_rules="$all_rules
$group_prio|AND,((RULE-SET,${g}_geoip_$gi),(NETWORK,UDP),(DST-PORT,19294-19344/50000-50100)),$g"
        else
          cat <<EOF
  ${g}_geoip_$gi:
    type: http
    behavior: ipcidr
    format: mrs
    url: "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/refs/heads/meta/geo/geoip/$gi.mrs"
    interval: 86400
EOF
          all_rules="$all_rules
$group_prio|RULE-SET,${g}_geoip_$gi,$g"
        fi
      done

      # AS
      as_list=$(printenv "${env_name}_AS" || echo "")
      for asn in $(echo "$as_list" | tr ',' ' ' | xargs -n1); do
        [ -z "$asn" ] && continue
        as_num=$(echo "$asn" | sed 's/^AS//')
        [ "$as_num" = "$asn" ] && continue
        cat <<EOF
  ${g}_as_$asn:
    type: http
    behavior: ipcidr
    format: mrs
    url: "https://github.com/MetaCubeX/meta-rules-dat/raw/refs/heads/meta/asn/AS$as_num.mrs"
    interval: 86400
EOF
        all_rules="$all_rules
$group_prio|RULE-SET,${g}_as_$asn,$g"
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
        cat <<EOF
  ${g}_custom_rules:
    type: inline
    behavior: classical
    format: text
    payload:$custom_payload
EOF
        all_rules="$all_rules
$group_prio|RULE-SET,${g}_custom_rules,$g"
      fi

      idx=$((idx + 1))
    done

    # Сортируем все правила по приоритету
    sorted_all_rules=$(echo "$all_rules" | grep -v '^$' | sort -t'|' -k1 -n | cut -d'|' -f2- | sed 's/^/  - /')

    # === rules ===
    echo
    echo "rules:"
    echo "$sorted_all_rules"
    if lsmod | grep -q '^nft_tproxy'; then
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
  iface_ip=$(ip -4 addr show "$iface" | grep inet | awk '{ print $2 }' | cut -d/ -f1)
  nft flush ruleset || true
  nft -f - <<EOF
table inet mihomo {
    chain prerouting {
        type filter hook prerouting priority filter; policy accept;
        ip daddr ${FAKE_IP_RANGE} meta l4proto { tcp, udp } iifname "$iface" meta mark set 0x00000001 tproxy ip to 127.0.0.1:12345 accept
        ip daddr { $iface_ip, 0.0.0.0/8, 127.0.0.0/8, 224.0.0.0/4, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 169.254.0.0/16, 192.0.0.0/24, 192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24, 192.88.99.0/24, 198.18.0.0/15, 224.0.0.0/3 } return
        meta l4proto { tcp, udp } iifname "$iface" meta mark set 0x00000001 tproxy ip to 127.0.0.1:12345 accept
    }
    chain divert {
        type filter hook prerouting priority mangle; policy accept;
        meta l4proto tcp socket transparent 1 meta mark set 0x00000001 accept
    }
}
EOF
if [ "${ZAPRET}" = "true" ]; then
  nft create table inet zapret
  nft add chain inet zapret post "{type filter hook postrouting priority mangle;}"
  nft add rule inet zapret post meta l4proto { tcp, udp } mark 0x00000084 ct state new ct mark set 0x00000084
  nft add rule inet zapret post meta l4proto { tcp, udp } ct mark 0x00000084 ct original packets 1-6 queue num 132
  nft add chain inet zapret pre "{type filter hook prerouting priority mangle;}"
  nft add rule inet zapret pre meta l4proto { tcp, udp } ct reply packets 1-6 ct mark 0x00000084 queue num 132
fi
if [ "${ZAPRET2}" = "true" ]; then
  nft create table inet zapret2
  nft add chain inet zapret2 post "{type filter hook postrouting priority mangle;}"
  nft add rule inet zapret2 post meta l4proto { tcp, udp } mark 0x00000085 ct state new ct mark set 0x00000085
  nft add rule inet zapret2 post meta l4proto { tcp, udp } ct mark 0x00000085 ct original packets 1-12 queue num 133
  nft add chain inet zapret2 pre "{type filter hook prerouting priority mangle;}"
  nft add rule inet zapret2 pre meta l4proto { tcp, udp } ct reply packets 1-12 ct mark 0x00000085 queue num 133
fi
if [ "${BYEDPI}" = "true" ]; then
  nft add table nat
  nft add chain nat output '{ type nat hook output priority -100; }'
  nft add rule nat output meta l4proto tcp mark 0x00000083 redirect to 1100
fi
  ip rule show | grep -q 'fwmark 0x00000001 lookup 100' || ip rule add fwmark 1 table 100
  ip route replace local 0.0.0.0/0 dev lo table 100
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
  iptables -t nat -A mihomo-prerouting -i $iface -p tcp -j REDIRECT --to-ports 12345
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
#!/usr/bin/sh
ip rule show | grep -q 'fwmark 0x83 ipproto udp lookup 131' || ip rule add fwmark 131 ipproto udp table 131
ip route replace default via 100.64.0.1 dev hs5t table 131
EOF
chmod +x /hs5t.sh
}

# ------------------- RUN -------------------
run() {
  mkdir -p "$CONFIG_DIR" "$AWG_DIR" "$PROXIES_DIR"
  if lsmod | grep -q '^nft_tproxy'; then
    nft_rules
  else
    iptables_rules
  fi
  if [ "${ZAPRET}" = "true" ]; then
    generate_zapret_yaml
    echo "Starting zapret nfqws $(./nfqws --version) "
  fi
  if [ "${ZAPRET2}" = "true" ]; then
    generate_zapret2_yaml
    LUA_INIT_ARGS=""
    for f in /lua/*.lua; do
      LUA_INIT_ARGS="$LUA_INIT_ARGS --lua-init=@$f"
    done    
    echo "Starting zapret nfqws2 $(./nfqws2 --version) "
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
  if [ "${ZAPRET}" = "true" ]; then
    ./nfqws --qnum 132 --user=root $ZAPRET_CMD &
  fi
  if [ "${ZAPRET2}" = "true" ]; then
    ./nfqws2 --qnum 133 --user=root $LUA_INIT_ARGS $ZAPRET2_CMD &
  fi
  if [ "${BYEDPI}" = "true" ]; then
    ./byedpi --port 1100 --transparent $BYEDPI_CMD &
    ./byedpi --port 1090 $cmd_udp &
    ./hs5t ./hs5t.yml &
  fi
  exec ./mihomo
}

run || exit 1
