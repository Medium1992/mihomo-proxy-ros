#!/bin/sh
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
  log "Generating $BYEDPI_YAML"
  cat > "$BYEDPI_YAML" <<EOF
proxies:
  - name: "BYEDPI"
    type: direct
    udp: true
    ip-version: ipv4
    routing-mark: 8888
EOF
}

# ------------------- AWG -------------------
parse_awg_config() {
  local config_file="$1"
  local awg_name=$(basename "$config_file" .conf)

  # Чтение параметра WG/AWG без учёта регистра
  read_cfg() {
    local key="$1"
    grep -Ei "^${key}[[:space:]]*=" "$config_file" | sed -E "s/^${key}[[:space:]]*=[[:space:]]*//I"
  }

  local private_key=$(read_cfg "PrivateKey")
  local address=$(read_cfg "Address")
  address=$(echo "$address" | tr ',' '\n' | grep -v ':' | head -n1)
  local dns=$(read_cfg "DNS")
  dns=$(echo "$dns" | tr ',' '\n' | grep -v ':' | sed 's/^ *//;s/ *$//' | paste -sd, -)

  local mtu=$(read_cfg "MTU")
  local jc=$(read_cfg "Jc")
  local jmin=$(read_cfg "Jmin")
  local jmax=$(read_cfg "Jmax")
  local s1=$(read_cfg "S1")
  local s2=$(read_cfg "S2")
  local h1=$(read_cfg "H1")
  local h2=$(read_cfg "H2")
  local h3=$(read_cfg "H3")
  local h4=$(read_cfg "H4")
  local i1=$(read_cfg "I1")
  local i2=$(read_cfg "I2")
  local i3=$(read_cfg "I3")
  local i4=$(read_cfg "I4")
  local i5=$(read_cfg "I5")
  local j1=$(read_cfg "J1")
  local j2=$(read_cfg "J2")
  local j3=$(read_cfg "J3")
  local itime=$(read_cfg "ITime")

  local public_key=$(read_cfg "PublicKey")
  local psk=$(read_cfg "PresharedKey")
  local endpoint=$(read_cfg "Endpoint")

  local server=$(echo "$endpoint" | cut -d':' -f1)
  local port=$(echo "$endpoint" | cut -d':' -f2)

  echo "  - name: \"$awg_name\""
  echo "    type: wireguard"

  [ -n "$private_key" ] && echo "    private-key: $private_key"
  [ -n "$server" ] && echo "    server: $server"
  [ -n "$port" ] && echo "    port: $port"
  [ -n "$address" ] && echo "    ip: $address"
  [ -n "$mtu" ] && echo "    mtu: $mtu"
  [ -n "$public_key" ] && echo "    public-key: $public_key"

  echo "    allowed-ips: ['0.0.0.0/0']"
  [ -n "$psk" ] && echo "    pre-shared-key: $psk"

  echo "    udp: true"

  [ -n "$dns" ] && echo "    dns: [ $dns ]"
  echo "    remote-dns-resolve: true"
  awg_params="jc jmin jmax s1 s2 h1 h2 h3 h4 i1 i2 i3 i4 i5 j1 j2 j3 itime"
  awg_has_value=false
  for v in $awg_params; do
      eval val=\$$v
      if [ -n "$val" ]; then
          awg_has_value=true
          break
      fi
  done
  if $awg_has_value; then
      echo "    amnezia-wg-option:"
      for v in $awg_params; do
          eval val=\$$v
          [ -n "$val" ] && echo "      $v: $val"
      done
  fi
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
  enhanced-mode: ${DNS_MODE:-fake-ip}
  fake-ip-filter-mode: ${FAKE_IP_FILTER_MODE:-blacklist}
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
  log "Applying nftables..."
  iface=$(first_iface)
  iface_ip=$(ip -4 addr show "$iface" | grep inet | awk '{ print $2 }' | cut -d/ -f1)
  nft flush ruleset || true
  nft -f - <<EOF
table inet mihomo {
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
if [ "${BYEDPI}" = "true" ]; then
  nft add table nat
  nft add chain nat output '{ type nat hook output priority -100; }'
  nft add rule nat output meta l4proto tcp mark 0x000022b8 redirect to 1100
fi
  ip rule show | grep -q 'fwmark 0x00000001 lookup 100' || ip rule add fwmark 1 table 100
  ip route replace local 0.0.0.0/0 dev lo table 100
}

iptables_rules() {
  log "Applying iptables..."
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
mkdir -p /etc/iproute2
if [ ! -f /etc/iproute2/rt_tables ]; then
   touch /etc/iproute2/rt_tables
fi
if ! grep -Eq "^500[[:space:]]*byedpi_udp\b" /etc/iproute2/rt_tables; then
   echo "500 byedpi_udp" >> /etc/iproute2/rt_tables
fi
ip rule show | grep -q 'fwmark 0x22b8 lookup 500' || ip rule add fwmark 8888 ipproto udp table 500
ip route replace default via 100.64.0.1 dev hs5t table 500
EOF
chmod +x /hs5t.sh
}

# ------------------- RUN -------------------
run() {
  mkdir -p "$CONFIG_DIR" "$AWG_DIR"
  generate_direct_yaml
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
    log "Starting ByeDPI v.$(./byedpi --version)"
    echo "Starting hev-socks5-tunnel $(./hs5t --version | head -n 2 | tail -n 1)"
    log "Starting hev-socks5-tunnel $(./hs5t --version | head -n 2 | tail -n 1)"
    echo "Starting Mihomo $(./mihomo -v)"
    log "Starting Mihomo $(./mihomo -v)"
    local cmd_udp=$(printenv "$BYEDPI_CMD_UDP" || echo "$BYEDPI_CMD")
    ./byedpi --port 1100 --transparent $BYEDPI_CMD &
    ./byedpi --port 1090 $cmd_udp &
    ./hs5t ./hs5t.yml &
    exec ./mihomo
  fi
  echo "Starting Mihomo $(./mihomo -v)"
  log "Starting Mihomo $(./mihomo -v)"
  exec ./mihomo
}

# ------------------- ENTRY -------------------
if ! env | grep -qE '^LINK[0-9]*=' \
   && ! env | grep -qE '^SUB_LINK[0-9]*=' \
   && ! find "$AWG_DIR" -name "*.conf" | grep -q . 2>/dev/null; then
  log "Warning: no sources → minimal config"
fi

run || exit 1
