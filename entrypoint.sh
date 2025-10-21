#!/bin/sh
set -eu
FAKE_IP_RANGE="${FAKE_IP_RANGE:-198.18.0.0/15}"
CONFIG_DIR="/root/.config/mihomo"
AWG_DIR="$CONFIG_DIR/awg"
AWG_YAML="$CONFIG_DIR/awg.yaml"
LINKS_YAML="$CONFIG_DIR/links.yaml"
CONFIG_YAML="$CONFIG_DIR/config.yaml"
DIRECT_YAML="$CONFIG_DIR/direct.yaml"

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
  local iface
  iface=$(first_iface)
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

# ------------------- AWG -------------------

parse_awg_config() {
  local config_file="$1"
  local awg_name
  awg_name=$(basename "$config_file" .conf)

  # базовые поля
  local private_key=$(grep -E "^PrivateKey" "$config_file" | sed 's/^PrivateKey[[:space:]]*=[[:space:]]*//')
  local address=$(grep -E "^Address" "$config_file" | sed 's/^Address[[:space:]]*=[[:space:]]*//')
  # первый IPv4 адрес
  address=$(echo "$address" | tr ',' '\n' | grep -v ':' | head -n1)
  local dns=$(grep -E "^DNS" "$config_file" | sed 's/^DNS[[:space:]]*=[[:space:]]*//')
  dns=$(echo "$dns" | tr ',' '\n' | grep -v ':' | sed 's/^ *//;s/ *$//' | paste -sd, -)
  local mtu=$(grep -E "^MTU" "$config_file" | sed 's/^MTU[[:space:]]*=[[:space:]]*//')

  # старые awg-опции
  local jc=$(grep -E "^Jc" "$config_file" | sed 's/^Jc[[:space:]]*=[[:space:]]*//')
  local jmin=$(grep -E "^Jmin" "$config_file" | sed 's/^Jmin[[:space:]]*=[[:space:]]*//')
  local jmax=$(grep -E "^Jmax" "$config_file" | sed 's/^Jmax[[:space:]]*=[[:space:]]*//')
  local s1=$(grep -E "^S1" "$config_file" | sed 's/^S1[[:space:]]*=[[:space:]]*//')
  local s2=$(grep -E "^S2" "$config_file" | sed 's/^S2[[:space:]]*=[[:space:]]*//')
  local h1=$(grep -E "^H1" "$config_file" | sed 's/^H1[[:space:]]*=[[:space:]]*//')
  local h2=$(grep -E "^H2" "$config_file" | sed 's/^H2[[:space:]]*=[[:space:]]*//')
  local h3=$(grep -E "^H3" "$config_file" | sed 's/^H3[[:space:]]*=[[:space:]]*//')
  local h4=$(grep -E "^H4" "$config_file" | sed 's/^H4[[:space:]]*=[[:space:]]*//')

  # новые awg 1.5
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

generate_awg_yaml() {
  log "Generating $AWG_YAML"
  echo "proxies:" > "$AWG_YAML"
  if find "$AWG_DIR" -name "*.conf" | grep -q . 2>/dev/null; then
    find "$AWG_DIR" -name "*.conf" | while read -r conf; do
      parse_awg_config "$conf"
    done >> "$AWG_YAML"
  fi
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

  cat > "$CONFIG_YAML" <<EOF
log-level: ${LOG_LEVEL:-warning}
external-controller: 0.0.0.0:9090
external-ui: ui
external-ui-url: "${EXTERNAL_UI_URL:-https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip}"
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
  fake-ip-range: ${FAKE_IP_RANGE}
  nameserver:
    - https://dns.google/dns-query
    - https://cloudflare-dns.com/dns-query
    - https://dns.quad9.net/dns-query
hosts:
  dns.google: [8.8.8.8, 8.8.4.4]
  dns.quad9.net: [9.9.9.9, 149.112.112.112]
  cloudflare-dns.com: [104.16.248.249, 104.16.249.249]

listeners:
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
  - name: mixed-in
    type: mixed
    port: 1080
    listen: 0.0.0.0
    udp: true

proxy-providers:
EOF

  providers=""

  # провайдер links, если есть LINKi
  if env | grep -qE '^LINK[0-9]*='; then
    cat >> "$CONFIG_YAML" <<EOF
  LINKS:
    type: file
    path: $(basename "$LINKS_YAML")
$(health_check_block)
EOF
    providers="$providers LINKS"
  fi

  # провайдеры SUB_LINKi
  for var in $(env | grep -E '^SUB_LINK[0-9]*=' | sort -t '=' -k1); do
    name=$(echo "$var" | cut -d '=' -f1)
    value=$(echo "$var" | cut -d '=' -f2-)
    cat >> "$CONFIG_YAML" <<EOF
  $name:
    url: "$value"
    type: http
    interval: 86400
    proxy: DIRECT
$(health_check_block)
EOF
    providers="$providers $name"
  done

  # провайдер AWG
  if find "$AWG_DIR" -name "*.conf" | grep -q . 2>/dev/null; then
    cat >> "$CONFIG_YAML" <<EOF
  AWG:
    type: file
    path: $(basename "$AWG_YAML")
$(health_check_block)
EOF
    providers="$providers AWG"
  fi

  # Всегда добавляем DIRECT
  cat >> "$CONFIG_YAML" <<EOF
  DIRECT:
    type: file
    path: $(basename "$DIRECT_YAML")
$(health_check_block)
EOF
  providers="$providers DIRECT"

  # Группы
  {
    echo
    echo "proxy-groups:"
    echo "  - name: GLOBAL"
    echo "    type: ${GLOBAL_TYPE:-select}"
    echo "    use:"
    if [ -n "${GLOBAL_USE:-}" ]; then
      echo "$GLOBAL_USE" | tr ',' '\n' | sed 's/^/      - /'
    else
      for p in $providers; do
        echo "      - $p"
      done
    fi
    [ -n "${GLOBAL_FILTER:-}" ] && echo "    filter: $GLOBAL_FILTER"
    [ -n "${GLOBAL_EXCLUDE:-}" ] && echo "    exclude-filter: $GLOBAL_EXCLUDE"

    echo
    echo "  - name: quic"
    echo "    type: select"
    echo "    proxies:"
    echo "      - PASS"
    echo "      - REJECT-DROP"
    
    echo
    echo "rules:"
    echo "  - AND,((NETWORK,udp),(DST-PORT,443)),quic"
    echo "  - MATCH,GLOBAL"
  } >> "$CONFIG_YAML"
}

# ------------------- Orchestrator -------------------

run() {
  mkdir -p "$CONFIG_DIR" "$AWG_DIR"

  generate_direct_yaml
  generate_awg_yaml
  link_file_mihomo
  config_file_mihomo

  log "Starting mihomo..."
  exec ./mihomo
}

# ------------------- Entry -------------------

# Проверка на наличие источников
if ! env | grep -qE '^LINK[0-9]*=' \
   && ! env | grep -qE '^SUB_LINK[0-9]*=' \
   && ! find "$AWG_DIR" -name "*.conf" | grep -q . 2>/dev/null; then
  log "Warning: no LINK*, SUB_LINK*, or AWG .conf found. Config will be minimal (but DIRECT is always included)."
fi

run || exit 1
