#!/bin/sh
set -eu

FAKE_IP_RANGE="${FAKE_IP_RANGE:-198.18.0.0/15}"
EXTERNAL_UI_URL="${EXTERNAL_UI_URL:-https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip}"
CONFIG_DIR="/root/.config/mihomo"
AWG_DIR="$CONFIG_DIR/awg"
LINKS_YAML="$CONFIG_DIR/links.yaml"
CONFIG_YAML="$CONFIG_DIR/config.yaml"
DIRECT_YAML="$CONFIG_DIR/direct.yaml"
BYEDPI="${BYEDPI:-false}"                 
BYEDPI_ADDRESS="${BYEDPI_ADDRESS:-192.168.255.6}"
BYEDPI_SOCKS_PORT="${BYEDPI_SOCKS_PORT:-1080}"
BYEDPI_YAML="$CONFIG_DIR/byedpi.yaml"
UI_URL_CHECK="$CONFIG_DIR/.ui_url"
FAKE_IP_FILTER="${FAKE_IP_FILTER:-}"

log() { echo "[$(date +'%H:%M:%S')] $*"; }

health_check_block() {
  cat <<EOF
    health-check:
      enable: true
      url: https://www.gstatic.com/generate_204
      interval: ${INTERVAL:-120}
      timeout: 5000
      lazy: false
      expected-status: 204
EOF
}

first_iface() {
  ip -o link show | awk -F': ' '/link\/ether/ {print $2}' | cut -d'@' -f1 | head -n1
}

# ------------------- DIRECT -------------------
generate_direct_yaml() {
  local iface=$(first_iface)
  log "Generating $DIRECT_YAML with interface: $iface"
  cat > "$DIRECT_YAML" <<EOF
proxies:
  - name: "direct"
    type: direct
    udp: true
    ip-version: ipv4
    interface-name: "$iface"
EOF
}

# ------------------- BYEDPI -------------------
generate_byedpi_yaml() {
  [ "$BYEDPI" = "true" ] || return 0

  log "Generating $BYEDPI_YAML (address=$BYEDPI_ADDRESS, port=$BYEDPI_SOCKS_PORT)"
  cat > "$BYEDPI_YAML" <<EOF
proxies:
  - name: "BYEDPI"
    type: socks5
    server: $BYEDPI_ADDRESS
    port: $BYEDPI_SOCKS_PORT
    udp: true
EOF
}

# ------------------- AWG -------------------
parse_awg_config() {
  local config_file="$1"
  local awg_name=$(basename "$config_file" .conf)
  local private_key=$(grep -E "^PrivateKey" "$config_file" | sed 's/^PrivateKey[[:space:]]*=[[:space:]]*//')
  local address=$(grep -E "^Address" "$config_file" | sed 's/^Address[[:space:]]*=[[:space:]]*//')
  address=$(echo "$address" | tr ',' '\n' | grep -v ':' | head -n1)
  local dns=$(grep -E "^DNS" "$config_file" | sed 's/^DNS[[:space:]]*=[[:space:]]*//')
  dns=$(echo "$dns" | tr ',' '\n' | grep -v ':' | sed 's/^ *//;s/ *$//' | paste -sd, -)
  local mtu=$(grep -E "^MTU" "$config_file" | sed 's/^MTU[[:space:]]*=[[:space:]]*//')
  local jc=$(grep -E "^Jc" "$config_file" | sed 's/^Jc[[:space:]]*=[[:space:]]*//')
  local jmin=$(grep -E "^Jmin" "$config_file" | sed 's/^Jmin[[:space:]]*=[[:space:]]*//')
  local jmax=$(grep -E "^Jmax" "$config_file" | sed 's/^Jmax[[:space:]]*=[[:space:]]*//')
  local s1=$(grep -E "^S1" "$config_file" | sed 's/^S1[[:space:]]*=[[:space:]]*//')
  local s2=$(grep -E "^S2" "$config_file" | sed 's/^S2[[:space:]]*=[[:space:]]*//')
  local h1=$(grep -E "^H1" "$config_file" | sed 's/^H1[[:space:]]*=[[:space:]]*//')
  local h2=$(grep -E "^H2" "$config_file" | sed 's/^H2[[:space:]]*=[[:space:]]*//')
  local h3=$(grep -E "^H3" "$config_file" | sed 's/^H3[[:space:]]*=[[:space:]]*//')
  local h4=$(grep -E "^H4" "$config_file" | sed 's/^H4[[:space:]]*=[[:space:]]*//')
  local i1=$(grep -E "^I1" "$config_file" | sed 's/^I1[[:space:]]*=[[:space:]]*//')
  local i2=$(grep -E "^I2" "$config_file" | sed 's/^I2[[:space:]]*=[[:space:]]*//')
  local i3=$(grep -E "^I3" "$config_file" | sed 's/^I3[[:space:]]*=[[:space:]]*//')
  local i4=$(grep -E "^I4" "$config_file" | sed 's/^I4[[:space:]]*=[[:space:]]*//')
  local i5=$(grep -E "^I5" "$config_file" | sed 's/^I5[[:space:]]*=[[:space:]]*//')
  local j1=$(grep -E "^J1" "$config_file" | sed 's/^J1[[:space:]]*=[[:space:]]*//')
  local j2=$(grep -E "^J2" "$config_file" | sed 's/^J2[[:space:]]*=[[:space:]]*//')
  local j3=$(grep -E "^J3" "$config_file" | sed 's/^J3[[:space:]]*=[[:space:]]*//')
  local itime=$(grep -E "^itime" "$config_file" | sed 's/^itime[[:space:]]*=[[:space:]]*//')
  local public_key=$(grep -E "^PublicKey" "$config_file" | sed 's/^PublicKey[[:space:]]*=[[:space:]]*//')
  local psk=$(grep -E "^PresharedKey" "$config_file" | sed 's/^PresharedKey[[:space:]]*=[[:space:]]*//')
  local endpoint=$(grep -E "^Endpoint" "$config_file" | sed 's/^Endpoint[[:space:]]*=[[:space:]]*//')
  local server=$(echo "$endpoint" | cut -d':' -f1)
  local port=$(echo "$endpoint" | cut -d':' -f2)

  cat <<EOF
  - name: "$awg_name"
    type: wireguard
    private-key: $private_key
    server: $server
    port: $port
    ip: $address
    mtu: ${mtu:-1420}
    public-key: $public_key
    allowed-ips: ['0.0.0.0/0']
$(if [ -n "$psk" ]; then echo "    pre-shared-key: $psk"; fi)
    udp: true
    dns: [ $dns ]
    remote-dns-resolve: true
    amnezia-wg-option:
      jc: ${jc:-4}
      jmin: ${jmin:-40}
      jmax: ${jmax:-70}
      s1: ${s1:-0}
      s2: ${s2:-0}
      h1: ${h1:-1}
      h2: ${h2:-2}
      h3: ${h3:-3}
      h4: ${h4:-4}
      i1: "${i1:-""}"
      i2: "${i2:-""}"
      i3: "${i3:-""}"
      i4: "${i4:-""}"
      i5: "${i5:-""}"
      j1: "${j1:-""}"
      j2: "${j2:-""}"
      j3: "${j3:-""}"
      itime: ${itime:-"0"}
EOF
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

# ------------------- LINKS -------------------
link_file_mihomo() {
  log "Generating $LINKS_YAML"
  : > "$LINKS_YAML"
  for i in $(env | grep -E '^LINK[0-9]*=' | sort -t '=' -k1 | cut -d '=' -f1); do
    eval "echo \"\$$i\"" >> "$LINKS_YAML"
  done
}

# ------------------- CONFIG -------------------
config_file_mihomo() {
  log "Generating $CONFIG_YAML"
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
  enhanced-mode: fake-ip
  fake-ip-range: ${FAKE_IP_RANGE}${FAKE_IP_FILTER:+
  fake-ip-filter:}${FAKE_IP_FILTER:+$(printf '\n    - %s' $(echo "$FAKE_IP_FILTER" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$'))}
  nameserver:
    - https://dns.google/dns-query
    - https://1.1.1.1/dns-query
    - https://dns.quad9.net/dns-query
hosts:
  dns.google: [8.8.8.8, 8.8.4.4]
  dns.quad9.net: [9.9.9.9, 149.112.112.112]
  cloudflare-dns.com: [104.16.248.249, 104.16.249.249]
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
  - name: tun-in
    type: tun
    stack: system
    auto-detect-interface: false
    include-interface:
      - $(first_iface)
    auto-route: true
    auto-redirect: true
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

  # LINKS
  if env | grep -qE '^LINK[0-9]*='; then
    cat >> "$CONFIG_YAML" <<EOF
  LINKS:
    type: file
    path: $(basename "$LINKS_YAML")
$(health_check_block)
EOF
    providers="$providers LINKS"
  fi

  # SUB_LINK
  for var in $(env | grep -E '^SUB_LINK[0-9]*=' | sort -t '=' -k1); do
    name=$(echo "$var" | cut -d '=' -f1)
    value=$(echo "$var" | cut -d '=' -f2- | tr '+' ' ')
    url=$(echo "$value" | cut -d '#' -f1)
    headers_raw=$(echo "$value" | cut -d '#' -f2-)
    headers_clean=$(echo "$headers_raw" | sed 's/^[[:space:]]*#*[[:space:]]*//; s/[[:space:]]*$//' | tr -d ' \t\n\r')

    def_hwid="${HWID:-}"; def_device_os="${DEVICE_OS:-}"; def_ver_os="${VER_OS:-}"; def_device_model="${DEVICE_MODEL:-}"; def_user_agent="${USER_AGENT:-}"
    x_hwid=""; x_device_os=""; x_ver_os=""; x_device_model=""; x_user_agent=""

    if [ -n "$headers_clean" ]; then
      OLDIFS=$IFS; IFS='#'
      for pair in $headers_clean; do
        [ -z "$pair" ] && continue
        key=$(echo "$pair" | cut -d'=' -f1)
        val=$(echo "$pair" | cut -d'=' -f2- | tr '+' ' ')
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

    cat >> "$CONFIG_YAML" <<EOF
  $name:
    type: http
    url: "$url"
    interval: 86400
    proxy: DIRECT
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
  done

  # AWG
  awg_provs=$(generate_awg_providers)
  providers="${providers}${awg_provs}"

  # BYEDPI
  if [ "$BYEDPI" = "true" ]; then
    cat >> "$CONFIG_YAML" <<EOF
  BYEDPI:
    type: file
    path: $(basename "$BYEDPI_YAML")
$(health_check_block)
EOF
    providers="$providers BYEDPI"
  fi

# DIRECT
  cat >> "$CONFIG_YAML" <<EOF
  DIRECT:
    type: file
    path: $(basename "$DIRECT_YAML")
$(health_check_block)
EOF
  providers="$providers DIRECT"


# === ГРУППЫ + ПРАВИЛА ===
  {
    echo
    echo "proxy-groups:"
    echo " - name: GLOBAL"
    echo "   type: ${GLOBAL_TYPE:-select}"
    echo "   use:"
    if [ -n "${GLOBAL_USE:-}" ]; then
      echo "$GLOBAL_USE" | tr ',' '\n' | sed 's/^/     - /'
    else
      for p in $providers; do echo "     - $p"; done
    fi
    [ -n "${GLOBAL_FILTER:-}" ] && echo "   filter: $GLOBAL_FILTER"
    [ -n "${GLOBAL_EXCLUDE:-}" ] && echo "   exclude-filter: $GLOBAL_EXCLUDE"

    # === Сбор групп с приоритетами (ЛОГИ ВНЕ БЛОКА) ===
    group_prio_list=""
    idx=0
    if [ -n "${GROUP:-}" ]; then
      for g in $(echo "$GROUP" | tr ',' ' '); do
        g=$(echo "$g" | xargs)
        [ -z "$g" ] && continue

        env_name=$(echo "$g" | tr '-' '_' | tr '[:lower:]' '[:upper:]')
        has_resource=false
        for suffix in GEOSITE GEOIP AS; do
          if [ -n "$(printenv "${env_name}_${suffix}" 2>/dev/null || echo "")" ]; then
            has_resource=true
            break
          fi
        done

        if ! $has_resource; then
          # ЛОГ ТОЛЬКО В КОНСОЛЬ
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
      use=$(printenv "${env_name}_USE" || true)

      echo
      echo " - name: $g"
      echo "   type: $type"
      [ -n "$filter" ] && echo "   filter: $filter"
      [ -n "$exclude" ] && echo "   exclude-filter: $exclude"
      echo "   use:"
      if [ -n "$use" ]; then
        echo "$use" | tr ',' '\n' | sed 's/^/     - /'
      else
        for p in $providers; do echo "     - $p"; done
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
    done

    # === rules ===
    echo
    echo "rules:"
    if ! lsmod | grep -q '^nft_tproxy'; then
      echo " - AND,((NETWORK,udp),(DST-PORT,443)),REJECT"
    fi

    if [ -n "$rule_accum" ]; then
      echo "$rule_accum" | sed '1d' | sed 's/^/ /'
    fi

    if lsmod | grep -q '^nft_tproxy'; then
      echo " - IN-NAME,tproxy-in,GLOBAL"
      echo " - IN-NAME,mixed-in,GLOBAL"
    else
      echo " - IN-NAME,tun-in,GLOBAL"
      echo " - IN-NAME,mixed-in,GLOBAL"
    fi
    echo " - MATCH,DIRECT"
  } >> "$CONFIG_YAML"
}

# ------------------- NFT -------------------
nft_rules() {
  log "Applying nftables..."
  iface=$(first_iface)
  iface_ip=$(ip -4 addr show "$iface" | grep inet | awk '{ print $2 }' | cut -d/ -f1)
  nft flush ruleset || true
  nft -f - <<EOF
table inet mihomo_tproxy {
    chain prerouting {
        type filter hook prerouting priority filter; policy accept;
        ip daddr ${FAKE_IP_RANGE} meta l4proto { tcp, udp } meta mark set 0x00000001 tproxy ip to 127.0.0.1:12345 accept
        ip daddr { $iface_ip, 0.0.0.0/8, 127.0.0.0/8, 224.0.0.0/4, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 169.254.0.0/16, 192.0.0.0/24, 192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24, 192.88.99.0/24, 198.18.0.0/15, 224.0.0.0/3 } return
        meta l4proto { tcp, udp } meta mark set 0x00000001 tproxy ip to 127.0.0.1:12345 accept
    }
    chain divert {
        type filter hook prerouting priority mangle; policy accept;
        meta l4proto tcp socket transparent 1 meta mark set 0x00000001 accept
    }
}
EOF
  ip rule show | grep -q 'fwmark 0x00000001 lookup 100' || ip rule add fwmark 1 table 100
  ip route replace local 0.0.0.0/0 dev lo table 100
}

# ------------------- RUN -------------------
run() {
  mkdir -p "$CONFIG_DIR" "$AWG_DIR"
  generate_direct_yaml
  generate_byedpi_yaml
  
  link_file_mihomo

  if lsmod | grep -q '^nft_tproxy'; then
    nft_rules
  fi

  config_file_mihomo
  log "Starting mihomo..."
  exec ./mihomo
}

# ------------------- ENTRY -------------------
if ! env | grep -qE '^LINK[0-9]*=' \
   && ! env | grep -qE '^SUB_LINK[0-9]*=' \
   && ! find "$AWG_DIR" -name "*.conf" | grep -q . 2>/dev/null; then
  log "Warning: no sources → minimal config"
fi

run || exit 1
