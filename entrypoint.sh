#!/bin/sh

if ! lsmod | grep nf_tables >/dev/null 2>&1; then
  if ! apk info -e iptables iptables-legacy >/dev/null 2>&1; then
    echo "Install iptables"
    apk add iptables iptables-legacy >/dev/null 2>&1
    rm -f /usr/sbin/iptables /usr/sbin/iptables-save /usr/sbin/iptables-restore
    ln -s /usr/sbin/iptables-legacy /usr/sbin/iptables
    ln -s /usr/sbin/iptables-legacy-save /usr/sbin/iptables-save
    ln -s /usr/sbin/iptables-legacy-restore /usr/sbin/iptables-restore
  fi
else
  if ! apk info -e nftables >/dev/null 2>&1; then
    echo "Install nftables"
    apk add nftables >/dev/null 2>&1
  fi
  if apk info -e iptables iptables-legacy >/dev/null 2>&1; then
    echo "Delete iptables"
    apk del iptables iptables-legacy >/dev/null 2>&1
  fi
fi

set -eu

EXTERNAL_UI_URL="${EXTERNAL_UI_URL:-https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip}"
CONFIG_DIR="/root/.config/mihomo"
AWG_DIR="$CONFIG_DIR/awg"
LINKS_YAML="$CONFIG_DIR/links.yaml"
CONFIG_YAML="$CONFIG_DIR/config.yaml"
DIRECT_YAML="$CONFIG_DIR/direct.yaml"
BYEDPI_YAML="$CONFIG_DIR/byedpi.yaml"
UI_URL_CHECK="$CONFIG_DIR/.ui_url"
FAKE_IP_RANGE="${FAKE_IP_RANGE:-198.18.0.0/15}"
FAKEIP_TTL="${FAKEIP_TTL:-1}"
FAKE_IP_FILTER="${FAKE_IP_FILTER:-}"
BYEDPI="${BYEDPI:-false}"
BYEDPI_CMD="${BYEDPI_CMD:-}"
BYEDPI_CMD_UDP="${BYEDPI_CMD_UDP:-}"
HEALTHCHECK_INTERVAL="${HEALTHCHECK_INTERVAL:-120}"
HEALTHCHECK_URL="${HEALTHCHECK_URL:-https://www.gstatic.com/generate_204}"
HEALTHCHECK_URL_STATUS="${HEALTHCHECK_URL_STATUS:-204}"
GROUP_URL="${GROUP_URL:-https://www.gstatic.com/generate_204}"
GROUP_URL_STATUS="${GROUP_URL_STATUS:-204}"
GROUP_INTERVAL="${GROUP_INTERVAL:-60}"
GROUP_TOLERANCE="${GROUP_TOLERANCE:-20}"
GROUP_STRATEGY="${GROUP_STRATEGY:-consistent-hashing}"

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
    routing-mark: 8888
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
$(health_check_block)
EOF

      awg_providers="${awg_providers} ${awg_name}"
    done
  fi
  echo "$awg_providers"
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
  fake-ip-ttl: ${FAKEIP_TTL}${FAKE_IP_FILTER:+
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
$(health_check_block)
EOF
      providers="$providers $provider_name"
    done
  fi

  # SUB_LINK
  while IFS= read -r var; do
    name=$(echo "$var" | cut -d '=' -f1)
    value=$(echo "$var" | cut -d '=' -f2-)
    url=$(echo "$value" | cut -d '#' -f1)
    headers_raw=$(echo "$value" | cut -d '#' -f2-)
    headers_clean=$(echo "$headers_raw" | sed 's/^[[:space:]]*#*[[:space:]]*//; s/[[:space:]]*$//' | tr -d '\r')

    if [ -n "${SW_ID_FOR_HWID:-}" ]; then
        def_hwid=$(printf '%s' "$SW_ID_FOR_HWID" | busybox sha256sum | busybox cut -c1-16)
    else
        def_hwid=""
    fi
    def_device_os="${DEVICE_OS:-}"
    def_ver_os="${VER_OS:-}"
    def_device_model="${DEVICE_MODEL:-}"
    def_user_agent="${USER_AGENT:-}"
    
    x_hwid=""; x_device_os=""; x_ver_os=""; x_device_model=""; x_user_agent=""

    if [ -n "$headers_clean" ]; then
      OLDIFS=$IFS; IFS='#'
      for pair in $headers_clean; do
        [ -z "$pair" ] && continue
        key=$(echo "$pair" | cut -d'=' -f1)
        val=$(echo "$pair" | cut -d'=' -f2-)
        case "$key" in
          x-hwid) x_hwid="$val" ;;
          x-device-os) x_device_os="$val" ;;
          x-ver-os) x_ver_os="$val" ;;
          x-device-model) x_device_model="$val" ;;
          user-agent) x_user_agent="$val" ;;
        esac
      done
      IFS=$OLDIFS
    fi

    [ -z "$x_hwid" ] && [ -n "$def_hwid" ] && x_hwid="$def_hwid"
    [ -z "$x_device_os" ] && [ -n "$def_device_os" ] && x_device_os="$def_device_os"
    [ -z "$x_ver_os" ] && [ -n "$def_ver_os" ] && x_ver_os="$def_ver_os"
    [ -z "$x_device_model" ] && [ -n "$def_device_model" ] && x_device_model="$def_device_model"
    [ -z "$x_user_agent" ] && [ -n "$def_user_agent" ] && x_user_agent="$def_user_agent"

    proxy="DIRECT"
    eval "proxy=\"\${${name}_PROXY:-DIRECT}\"" 2>/dev/null

    cat >> "$CONFIG_YAML" <<EOF
  $name:
    type: http
    url: "$url"
    interval: 86400
    proxy: $proxy
EOF
    if [ -n "$x_hwid" ] || [ -n "$x_device_os" ] || [ -n "$x_ver_os" ] || [ -n "$x_device_model" ] || [ -n "$x_user_agent" ]; then
      cat >> "$CONFIG_YAML" <<EOF
    header:
EOF
      [ -n "$x_hwid" ] &&         echo "      x-hwid:" >> "$CONFIG_YAML" &&         echo "      - \"$x_hwid\"" >> "$CONFIG_YAML"
      [ -n "$x_device_os" ] &&    echo "      x-device-os:" >> "$CONFIG_YAML" &&    echo "      - \"$x_device_os\"" >> "$CONFIG_YAML"
      [ -n "$x_ver_os" ] &&       echo "      x-ver-os:" >> "$CONFIG_YAML" &&       echo "      - \"$x_ver_os\"" >> "$CONFIG_YAML"
      [ -n "$x_device_model" ] && echo "      x-device-model:" >> "$CONFIG_YAML" && echo "      - \"$x_device_model\"" >> "$CONFIG_YAML"
      [ -n "$x_user_agent" ] &&   echo "      User-Agent:" >> "$CONFIG_YAML" &&     echo "      - \"$x_user_agent\"" >> "$CONFIG_YAML"
    fi
    cat >> "$CONFIG_YAML" <<EOF
$(health_check_block)
EOF
    providers="$providers $name"
  done < <(env | grep -E '^SUB_LINK[0-9]*=' | sort -t '=' -k1)

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
$(health_check_block)
EOF
    providers="$providers $name"
  done < <(env | grep -E '^SOCKS[0-9]+=' | sort -V)

  # BYEDPI
  if [ "$BYEDPI" = "true" ]; then
    cat >> "$CONFIG_YAML" <<EOF
  BYEDPI:
    type: file
    path: $(basename "$BYEDPI_YAML")
    health-check:
      enable: true
      url: ${HEALTHCHECK_URL_BYEDPI:-https://www.facebook.com}
      interval: $HEALTHCHECK_INTERVAL
      timeout: 1500
      lazy: false
      expected-status: ${HEALTHCHECK_URL_STATUS_BYEDPI:-200}
EOF
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
    routing-mark: $i
EOF

  cat >> "$CONFIG_YAML" <<EOF
  $iface:
    type: file
    path: $iface.yaml
$(health_check_block)
EOF
 
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
    g_type="${GLOBAL_TYPE:-select}"
    g_tol="${GLOBAL_TOLERANCE:-$GROUP_TOLERANCE}"
    g_url="${GLOBAL_URL:-$GROUP_URL}"
    g_status="${GLOBAL_URL_STATUS:-$GROUP_URL_STATUS}"
    g_interval="${GLOBAL_INTERVAL:-$GROUP_INTERVAL}"
    g_strategy="${GLOBAL_STRATEGY:-$GROUP_STRATEGY}"
    echo
    echo "proxy-groups:"
    echo "  - name: GLOBAL"
    echo "    type: ${GLOBAL_TYPE:-select}"
    echo "    url: \"$g_url\""
    echo "    expected-status: $g_status"
    echo "    interval: $g_interval"
    echo "    timeout: 1500"
    case "$g_type" in
      url-test)
        [ -n "$g_tol" ] && echo "    tolerance: $g_tol"
        ;;
      load-balance)
        [ -n "$g_strategy" ] && echo "    strategy: $g_strategy"
        ;;
    esac
    echo "    lazy: false"
    [ -n "${GLOBAL_FILTER:-}" ] && echo "    filter: $GLOBAL_FILTER"
    [ -n "${GLOBAL_EXCLUDE:-}" ] && echo "    exclude-filter: $GLOBAL_EXCLUDE"
    [ -n "${GLOBAL_EXCLUDE_TYPE:-}" ] && echo "    exclude-type: $GLOBAL_EXCLUDE_TYPE"
    echo "    use:"
    if [ -n "${GLOBAL_USE:-}" ]; then
      echo "$GLOBAL_USE" | tr ',' '\n' | sed 's/^/      - /'
    else
      for p in $providers; do echo "      - $p"; done
    fi

    # === Сбор групп с приоритетами (ЛОГИ ВНЕ БЛОКА) ===
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

    # === Сортировка по приоритету ===
    sorted_groups=""
    if [ -n "$group_prio_list" ]; then
      sorted_groups=$(echo "$group_prio_list" | tr ' ' '\n' | sort -t'|' -k2 -n | cut -d'|' -f1)
    fi

    # === proxy-groups ===
    for g in $sorted_groups; do
      env_name=$(echo "$g" | tr '-' '_' | tr '[:lower:]' '[:upper:]')
      type=$(printenv "${env_name}_TYPE" || echo "select")
      filter=$(printenv "${env_name}_FILTER" || true)
      exclude=$(printenv "${env_name}_EXCLUDE" || true)
      exclude_type=$(printenv "${env_name}_EXCLUDE_TYPE" || true)
      use=$(printenv "${env_name}_USE" || true)
      g_tol=$(printenv "${env_name}_TOLERANCE" || echo "$GROUP_TOLERANCE")
      g_url=$(printenv "${env_name}_URL" || echo "$GROUP_URL")
      g_status=$(printenv "${env_name}_URL_STATUS" || echo "$GROUP_URL_STATUS")
      g_interval=$(printenv "${env_name}_INTERVAL" || echo "$GROUP_INTERVAL")
      g_strategy=$(printenv "${env_name}_STRATEGY" || echo "$GROUP_STRATEGY")

      echo
      echo "  - name: $g"
      echo "    type: $type"
      echo "    url: \"$g_url\""
      echo "    expected-status: $g_status"
      echo "    interval: $g_interval"
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

    # === rule-providers + rules ===
    echo
    echo "rule-providers:"

    rule_accum=""

    for g in $sorted_groups; do
      env_name=$(echo "$g" | tr '-' '_' | tr '[:lower:]' '[:upper:]')

      # GEOSITE
      geosite_list=$(printenv "${env_name}_GEOSITE" || echo "")
      for gs in $(echo "$geosite_list" | tr ',' ' '); do
        gs=$(echo "$gs" | xargs)
        [ -z "$gs" ] && continue
        cat <<EOF
  ${g}_geosite_$gs:
    type: http
    behavior: domain
    format: mrs
    url: "https://github.com/MetaCubeX/meta-rules-dat/raw/refs/heads/meta/geo/geosite/$gs.mrs"
    interval: 86400
EOF
        rule_accum="$rule_accum
- RULE-SET,${g}_geosite_$gs,$g"
      done

# GEOIP
      geoip_list=$(printenv "${env_name}_GEOIP" || echo "")
      for gi in $(echo "$geoip_list" | tr ',' ' '); do
        gi=$(echo "$gi" | xargs)
        [ -z "$gi" ] && continue

        if [ "$gi" = "discord" ]; then
          # Специальный случай для DISCORD_GEOIP
          cat <<EOF
  ${g}_geoip_$gi:
    type: http
    behavior: ipcidr
    format: text
    url: "https://raw.githubusercontent.com/Medium1992/mihomo-proxy-ros/refs/heads/main/custom_list/discord.list"
    interval: 86400
EOF
          rule_accum="$rule_accum
- AND,((RULE-SET,${g}_geoip_$gi),(NETWORK,UDP),(DST-PORT,19294-19344/50000-50100)),$g"
        else
          # Обычный случай для всех остальных GEOIP
          cat <<EOF
  ${g}_geoip_$gi:
    type: http
    behavior: ipcidr
    format: mrs
    url: "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/refs/heads/meta/geo/geoip/$gi.mrs"
    interval: 86400
EOF
          rule_accum="$rule_accum
- RULE-SET,${g}_geoip_$gi,$g"
        fi
      done

      # AS
      as_list=$(printenv "${env_name}_AS" || echo "")
      for asn in $(echo "$as_list" | tr ',' ' '); do
        asn=$(echo "$asn" | xargs)
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
        rule_accum="$rule_accum
- RULE-SET,${g}_as_$asn,$g"
      done
      
      custom_payload=""
      
      # DOMAIN
      domain_list=$(printenv "${env_name}_DOMAIN" || echo "")
      for dm in $(echo "$domain_list" | tr ',' ' '); do
        dm=$(echo "$dm" | xargs)
        [ -z "$dm" ] && continue
        custom_payload="$custom_payload
      - DOMAIN,$dm"
      done

      # DOMAIN-SUFFIX
      suffix_list=$(printenv "${env_name}_SUFFIX" || echo "")
      for sf in $(echo "$suffix_list" | tr ',' ' '); do
        sf=$(echo "$sf" | xargs)
        [ -z "$sf" ] && continue
        custom_payload="$custom_payload
      - DOMAIN-SUFFIX,$sf"
      done

      # DOMAIN-KEYWORD
      keyword_list=$(printenv "${env_name}_KEYWORD" || echo "")
      for kw in $(echo "$keyword_list" | tr ',' ' '); do
        kw=$(echo "$kw" | xargs)
        [ -z "$kw" ] && continue
        custom_payload="$custom_payload
      - DOMAIN-KEYWORD,$kw"
      done

      # IP-CIDR
      ipcidr_list=$(printenv "${env_name}_IPCIDR" || echo "")
      for ipcidr in $(echo "$ipcidr_list" | tr ',' ' '); do
        ipcidr=$(echo "$ipcidr" | xargs)
        [ -z "$ipcidr" ] && continue
        custom_payload="$custom_payload
      - IP-CIDR,$ipcidr,no-resolve"
      done

      # SRC-IP-CIDR
      srcipcidr_list=$(printenv "${env_name}_SRCIPCIDR" || echo "")
      for srcipcidr in $(echo "$srcipcidr_list" | tr ',' ' '); do
        srcipcidr=$(echo "$srcipcidr" | xargs)
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
        rule_accum="$rule_accum
- RULE-SET,${g}_custom_rules,$g"
      fi
    done

    # === rules ===
    echo
    echo "rules:"
    if ! lsmod | grep -q '^nft_tproxy'; then
      echo "  - AND,((NETWORK,udp),(DST-PORT,443),(DOMAIN-SUFFIX,googlevideo.com)),REJECT"
    fi

    if [ -n "$rule_accum" ]; then
      echo "$rule_accum" | sed '1d' | sed 's/^/  /'
    fi

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
if [ "${BYEDPI}" = "true" ]; then
  nft add table nat
  nft add chain nat output '{ type nat hook output priority -100; }'
  nft add rule nat output meta l4proto tcp mark 0x000022b8 redirect to 1100
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
  iptables -t nat -A mihomo-output -p tcp -m mark --mark 8888 -j REDIRECT --to-port 1100
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
#!/bin/sh
ip rule show | grep -q 'fwmark 0x22b8 ipproto udp lookup 8888' || ip rule add fwmark 8888 ipproto udp table 8888
ip route replace default via 100.64.0.1 dev hs5t table 8888
EOF
chmod +x /hs5t.sh
}

# ------------------- RUN -------------------
run() {
  mkdir -p "$CONFIG_DIR" "$AWG_DIR"
  generate_byedpi_yaml
  if lsmod | grep -q '^nft_tproxy'; then
    nft_rules
  else
    iptables_rules
  fi
  config_file_mihomo
  if [ "${BYEDPI}" = "true" ]; then
    config_file
    hs5t_file
    echo "Starting ByeDPI v.$(./byedpi --version) "
    echo "Starting hev-socks5-tunnel $(./hs5t --version | head -n 2 | tail -n 1)"
    echo "Starting Mihomo $(./mihomo -v)"
    local cmd_udp=$(printenv "$BYEDPI_CMD_UDP" || echo "$BYEDPI_CMD")
    ./byedpi --port 1100 --transparent $BYEDPI_CMD &
    ./byedpi --port 1090 $cmd_udp &
    ./hs5t ./hs5t.yml &
    exec ./mihomo
  fi
  echo "Starting Mihomo $(./mihomo -v)"
  exec ./mihomo
}

# ------------------- ENTRY -------------------
if ! env | grep -qE '^LINK[0-9]*=' \
   && ! env | grep -qE '^SUB_LINK[0-9]*=' \
   && ! find "$AWG_DIR" -name "*.conf" | grep -q . 2>/dev/null; then
  log "Warning: no sources → minimal config"
fi

run || exit 1
