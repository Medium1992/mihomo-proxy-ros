#!/bin/sh
# ByeDPI Check helpers. Reuses BlockCheck2 DoH/probe code, but routes probes
# through temporary byedpi transparent/SOCKS + hs5t workers instead of nfqueue.

BC_STATE_DIR="${BC_STATE_DIR:-/dev/shm/mihomo-byedpi-check}"
BC_NFT_TABLE="${BC_NFT_TABLE:-mihomo_byedpi_check}"
BC_NFT_TARGETS_SET="${BC_NFT_TARGETS_SET:-bdpi_targets}"
BC_MARK_BASE="${BC_MARK_BASE:-57344}"
BC_WORKER_MAX="${BC_WORKER_MAX:-16}"
BC_SPORT_BASE="${BC_SPORT_BASE:-22000}"
BC_SPORT_TOTAL="${BC_SPORT_TOTAL:-2000}"
BC_TCP_PORT_BASE="${BC_TCP_PORT_BASE:-18000}"
BC_UDP_PORT_BASE="${BC_UDP_PORT_BASE:-19000}"
BC_TUN_NET_OCTET="${BC_TUN_NET_OCTET:-65}"
BC_HS5T_DIR="${BC_HS5T_DIR:-${BC_STATE_DIR}/hs5t}"
BC_BYEDPI_BIN="${BC_BYEDPI_BIN:-byedpi}"
BC_HS5T_BIN="${BC_HS5T_BIN:-hs5t}"
BC_IPT_MANGLE_CHAIN="${BC_IPT_MANGLE_CHAIN:-BDPI_CHECK_MARK}"
BC_IPT_NAT_CHAIN="${BC_IPT_NAT_CHAIN:-BDPI_CHECK_NAT}"
BC_RULE_BACKEND=""

# Pull in DoH and probe implementations. Variables above are already set, so
# the sourced defaults do not point at blockcheck2 state.
. /www/blockcheck2/lib.sh

# ByeDPI Check overrides: write probe stdout to a temp file instead of
# command substitution ($()).  When timeout(1) kills openssl with SIGKILL,
# buffered pipe data inside $() is lost; the kernel has already written the
# file, so we still see the certificate / response.
bc_probe_http() {
  local k="$1" host="$2" ip="$3"
  local n="${BC_TOTAL_WORKERS:-8}"
  local port attempt=0 out="" size=0 err="" status_line=""
  local min_bytes="${BC_HTTP_MIN_BYTES:-1024}"
  while [ "$attempt" -lt 3 ]; do
    port=$(bc_probe_port "$k" "$n")
    local body_file="${BC_STATE_DIR:-/tmp}/.http_body_w${k}.$$"
    local err_file="${BC_STATE_DIR:-/tmp}/.http_err_w${k}.$$"
    if [ "$BC_HARD_BODY" = "1" ]; then
      printf 'GET %s HTTP/1.0\r\nHost: %s\r\nUser-Agent: Mozilla/5.0\r\nAccept: */*\r\nConnection: close\r\n\r\n' "$BC_HARD_PATH" "$host" \
        | timeout -k 2 "$BC_PROBE_TIMEOUT" nc -p "$port" -w "$BC_PROBE_TIMEOUT" "$ip" 80 2>"$err_file" > "$body_file"
    else
      printf 'GET / HTTP/1.0\r\nHost: %s\r\nUser-Agent: Mozilla/5.0\r\nAccept: */*\r\nConnection: close\r\n\r\n' "$host" \
        | timeout -k 2 "$BC_PROBE_TIMEOUT" nc -p "$port" -w "$BC_PROBE_TIMEOUT" "$ip" 80 2>"$err_file" > "$body_file"
    fi
    size=$(wc -c < "$body_file" 2>/dev/null)
    case "$size" in ''|*[!0-9]*) size=0 ;; esac
    out=$(head -c 256 "$body_file" 2>/dev/null)
    err=$(cat "$err_file" 2>/dev/null)
    rm -f "$body_file" "$err_file"
    case "$err" in
      *"Address in use"*|*"address in use"*|*"already in use"*)
        attempt=$((attempt+1)); continue ;;
    esac
    status_line=$(printf '%s' "$out" | awk 'NR==1{print; exit}')
    case "$status_line" in
      "HTTP/1."[01]" 2"*)
        if [ "$BC_HARD_BODY" = "1" ]; then
          [ "$size" -ge "$BC_HARD_MIN_BYTES" ] && return 0
        else
          [ "$size" -ge "$min_bytes" ] && return 0
        fi
        ;;
      "HTTP/1."[01]" 3"*)
        if [ "$BC_HARD_BODY" = "1" ]; then
          return 0
        else
          [ "$size" -ge "$min_bytes" ] && return 0
        fi
        ;;
    esac
    break
  done
  if [ -n "$BC_STATE_DIR" ]; then
    printf 'mode=%s size=%s min=%s port=%s\n---\n%s\n' \
      "${BC_HARD_BODY:-0}" "$size" "$min_bytes" "$port" "$out" \
      > "${BC_STATE_DIR}/.http_diag_w${k}" 2>/dev/null
  fi
  return 1
}

bc_probe_tls() {
  local k="$1" host="$2" ip="$3" ver="$4"
  local n="${BC_TOTAL_WORKERS:-8}"
  local port flag=""
  case "$ver" in
    tls1_2) flag="-tls1_2" ;;
    tls1_3) flag="-tls1_3" ;;
  esac
  port=$(bc_probe_port "$k" "$n")
  local tmpfile="${BC_STATE_DIR:-/tmp}/.tls_out_w${k}_${ver}_$$"
  if [ "$BC_HARD_BODY" = "1" ]; then
    printf 'GET %s HTTP/1.0\r\nHost: %s\r\nUser-Agent: Mozilla/5.0\r\nAccept: */*\r\nConnection: close\r\n\r\n' "$BC_HARD_PATH" "$host" \
      | timeout -k 2 "$BC_PROBE_TIMEOUT" openssl s_client $flag -quiet -ign_eof \
          -bind "0.0.0.0:$port" -connect "$ip:443" -servername "$host" \
          2>/dev/null > "$tmpfile"
    local size=$(wc -c < "$tmpfile" 2>/dev/null)
    case "$size" in ''|*[!0-9]*) size=0 ;; esac
    local out=$(head -c 256 "$tmpfile" 2>/dev/null)
    rm -f "$tmpfile"
    case "$out" in
      HTTP/*|*"HTTP/1."*)
        [ "$size" -ge "$BC_HARD_MIN_BYTES" ] && return 0
        ;;
    esac
  else
    timeout -k 2 "$BC_PROBE_TIMEOUT" openssl s_client $flag \
      -bind "0.0.0.0:$port" -connect "$ip:443" -servername "$host" \
      </dev/null > "$tmpfile" 2>&1
    local size=$(wc -c < "$tmpfile" 2>/dev/null)
    case "$size" in ''|*[!0-9]*) size=0 ;; esac
    local min_bytes="${BC_TLS_MIN_BYTES:-1024}"
    local out=$(cat "$tmpfile" 2>/dev/null)
    rm -f "$tmpfile"
    if [ "$size" -ge "$min_bytes" ]; then
      case "$out" in
        *"Cipher is "*|*"Cipher    : "*|*"New, TLSv"*|*"Verification: OK"*|*"Verify return code: 0"*) return 0 ;;
      esac
    fi
    if [ -n "$BC_STATE_DIR" ]; then
      printf 'mode=%s size=%s min=%s port=%s ver=%s\n---\n%s\n' \
        "${BC_HARD_BODY:-0}" "$size" "$min_bytes" "$port" "$ver" "$out" \
        > "${BC_STATE_DIR}/.tls_diag_w${k}_${ver}" 2>/dev/null
    fi
  fi
  return 1
}

bc_probe_quic() {
  local k="$1" host="$2" ip="$3"
  local n="${BC_TOTAL_WORKERS:-8}"
  local port
  port=$(bc_probe_port "$k" "$n")
  local tmpfile="${BC_STATE_DIR:-/tmp}/.quic_out_w${k}_$$"
  timeout -k 2 "$BC_PROBE_TIMEOUT" openssl s_client -quic \
    -bind "0.0.0.0:$port" -connect "$ip:443" \
    -servername "$host" -alpn h3 \
    </dev/null > "$tmpfile" 2>&1
  local out=$(cat "$tmpfile" 2>/dev/null)
  rm -f "$tmpfile"
  if [ -n "$BC_STATE_DIR" ]; then
    printf 'port=%s\n---\n%s\n' "$port" "$out" \
      > "${BC_STATE_DIR}/.quic_diag_w${k}" 2>/dev/null
  fi
  case "$out" in
    *"Server certificate"*|*"Certificate chain"*|*"BEGIN CERTIFICATE"*|*"Verify return code: 0"*|*"verify return:1"*) return 0 ;;
  esac
  return 1
}

bc_preflight() {
  local missing=""
  for b in openssl nc "$BC_BYEDPI_BIN" "$BC_HS5T_BIN"; do
    command -v "$b" >/dev/null 2>&1 || missing="$missing $b"
  done
  if [ -n "$missing" ]; then
    bc_log "missing binaries:$missing"
    return 2
  fi
  if command -v nft >/dev/null 2>&1 && nft list tables >/dev/null 2>&1; then
    return 0
  fi
  if command -v iptables >/dev/null 2>&1 && iptables -t nat -L OUTPUT >/dev/null 2>&1; then
    return 0
  fi
  bc_log "neither nft nor iptables is available"
  return 3
}

bc_have_nft() {
  command -v nft >/dev/null 2>&1 && nft list tables >/dev/null 2>&1
}

bc_have_iptables() {
  command -v iptables >/dev/null 2>&1 && \
    iptables -t nat -L OUTPUT >/dev/null 2>&1 && \
    iptables -t mangle -L OUTPUT >/dev/null 2>&1
}

bc_mark_for_worker() {
  printf '%s\n' $((BC_MARK_BASE + $1))
}

bc_tcp_port_for_worker() {
  printf '%s\n' $((BC_TCP_PORT_BASE + $1))
}

bc_udp_port_for_worker() {
  printf '%s\n' $((BC_UDP_PORT_BASE + $1))
}

bc_hs5t_conf() {
  printf '%s/hs5t_%s.yml\n' "$BC_HS5T_DIR" "$1"
}

bc_hs5t_pidfile() {
  printf '%s/hs5t_%s.pid\n' "$BC_HS5T_DIR" "$1"
}

bc_hs5t_stop_one() {
  local k="$1" pid pidf mark
  pidf=$(bc_hs5t_pidfile "$k")
  if [ -f "$pidf" ]; then
    pid=$(cat "$pidf" 2>/dev/null)
    [ -n "$pid" ] && kill -KILL "$pid" 2>/dev/null
    rm -f "$pidf"
  fi
  mark=$(bc_mark_for_worker "$k")
  while ip rule del fwmark "$mark" ipproto udp table "$mark" pref 160 2>/dev/null; do :; done
  while ip rule del fwmark "$mark" ipproto udp table "$mark" 2>/dev/null; do :; done
  while ip rule del fwmark "$mark" table "$mark" 2>/dev/null; do :; done
  ip route flush table "$mark" 2>/dev/null || true
  ip link del "bdpi_$k" 2>/dev/null || true
}

bc_hs5t_start_one() {
  local k="$1" mark udp_port conf script pidf
  mkdir -p "$BC_HS5T_DIR" || return 1
  mark=$(bc_mark_for_worker "$k")
  udp_port=$(bc_udp_port_for_worker "$k")
  conf=$(bc_hs5t_conf "$k")
  script="$BC_HS5T_DIR/hs5t_$k.sh"
  pidf=$(bc_hs5t_pidfile "$k")

  bc_hs5t_stop_one "$k"

  cat > "$conf" <<EOF
misc:
  log-level: 'error'
tunnel:
  name: bdpi_$k
  mtu: 1500
  ipv4: 100.$BC_TUN_NET_OCTET.$k.1
  multi-queue: true
  post-up-script: '$script'
socks5:
  address: '127.0.0.1'
  port: $udp_port
  udp: 'udp'
EOF

  cat > "$script" <<EOF
#!/bin/sh
ip rule show | grep -q "fwmark $mark.*ipproto udp" || \
  ip rule add fwmark $mark ipproto udp table $mark pref 160
ip route replace default via 100.$BC_TUN_NET_OCTET.$k.1 dev bdpi_$k table $mark
EOF
  chmod +x "$script"

  "$BC_HS5T_BIN" "$conf" >>"$BC_HS5T_DIR/hs5t_$k.log" 2>&1 &
  printf '%s\n' "$!" > "$pidf"
  sleep 0.2 2>/dev/null || sleep 1
  return 0
}

bc_hs5t_setup() {
  local n="$1" i=0
  mkdir -p "$BC_HS5T_DIR" || return 1
  while [ "$i" -lt "$n" ]; do
    bc_hs5t_start_one "$i" || return 1
    i=$((i + 1))
  done
}

bc_hs5t_teardown() {
  local i=0
  while [ "$i" -lt "$BC_WORKER_MAX" ]; do
    bc_hs5t_stop_one "$i"
    i=$((i + 1))
  done
  # Fallback: scan /proc directly (busybox ps without TTY may hide background jobs)
  for _pdir in /proc/[0-9]*; do
    [ -f "$_pdir/cmdline" ] || continue
    _cmd=$(tr '\0' ' ' < "$_pdir/cmdline" 2>/dev/null)
    case "$_cmd" in
      *hs5t*mihomo-byedpi-check*) kill -KILL "$(basename "$_pdir")" 2>/dev/null ;;
    esac
  done
  for i in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    ip link del "bdpi_$i" 2>/dev/null || true
  done
}

bc_nft_setup() {
  local n="$1" i mark step sport_min sport_max tcp_port
  bc_nft_teardown
  [ "$n" -lt 1 ] && n=1
  step=$((BC_SPORT_TOTAL / n))
  [ "$step" -lt 1 ] && step=1

  if ! bc_have_nft; then
    bc_iptables_setup "$n"
    return $?
  fi
  BC_RULE_BACKEND="nft"

  nft add table inet "$BC_NFT_TABLE" || return 1
  nft add set inet "$BC_NFT_TABLE" "$BC_NFT_TARGETS_SET" \
    '{ type ipv4_addr; flags interval; }' || return 1
  nft add chain inet "$BC_NFT_TABLE" out_mark '{ type filter hook output priority mangle; policy accept; }' || return 1
  nft add chain inet "$BC_NFT_TABLE" out_nat  '{ type nat hook output priority dstnat; policy accept; }' || return 1

  i=0
  while [ "$i" -lt "$n" ]; do
    mark=$(bc_mark_for_worker "$i")
    tcp_port=$(bc_tcp_port_for_worker "$i")
    sport_min=$((BC_SPORT_BASE + i * step))
    sport_max=$((BC_SPORT_BASE + (i + 1) * step - 1))

    nft add rule inet "$BC_NFT_TABLE" out_mark \
      ip daddr "@${BC_NFT_TARGETS_SET}" tcp sport "$sport_min-$sport_max" \
      counter meta mark set "$mark"
    nft add rule inet "$BC_NFT_TABLE" out_mark \
      ip daddr "@${BC_NFT_TARGETS_SET}" udp sport "$sport_min-$sport_max" \
      counter meta mark set "$mark"
    nft add rule inet "$BC_NFT_TABLE" out_nat \
      meta l4proto tcp meta mark "$mark" counter redirect to "$tcp_port"
    i=$((i + 1))
  done
}

bc_nft_add_target() {
  local ip="$1" n i mark step sport_min sport_max
  [ -z "$ip" ] && return 1
  if [ "$BC_RULE_BACKEND" = "iptables" ]; then
    n="${BC_TOTAL_WORKERS:-1}"
    case "$n" in ''|*[!0-9]*) n=1 ;; esac
    [ "$n" -lt 1 ] && n=1
    step=$((BC_SPORT_TOTAL / n))
    [ "$step" -lt 1 ] && step=1
    i=0
    while [ "$i" -lt "$n" ]; do
      mark=$(bc_mark_for_worker "$i")
      sport_min=$((BC_SPORT_BASE + i * step))
      sport_max=$((BC_SPORT_BASE + (i + 1) * step - 1))
      iptables -t mangle -C "$BC_IPT_MANGLE_CHAIN" -d "$ip" -p tcp -m tcp --sport "$sport_min:$sport_max" -j MARK --set-mark "$mark" 2>/dev/null || \
        iptables -t mangle -A "$BC_IPT_MANGLE_CHAIN" -d "$ip" -p tcp -m tcp --sport "$sport_min:$sport_max" -j MARK --set-mark "$mark" 2>/dev/null
      iptables -t mangle -C "$BC_IPT_MANGLE_CHAIN" -d "$ip" -p udp -m udp --sport "$sport_min:$sport_max" -j MARK --set-mark "$mark" 2>/dev/null || \
        iptables -t mangle -A "$BC_IPT_MANGLE_CHAIN" -d "$ip" -p udp -m udp --sport "$sport_min:$sport_max" -j MARK --set-mark "$mark" 2>/dev/null
      i=$((i + 1))
    done
    return 0
  fi
  nft add element inet "$BC_NFT_TABLE" "$BC_NFT_TARGETS_SET" "{ $ip }" 2>/dev/null
  return 0
}

bc_nft_teardown() {
  nft list table inet "$BC_NFT_TABLE" >/dev/null 2>&1 && \
    nft delete table inet "$BC_NFT_TABLE" 2>/dev/null
  bc_iptables_teardown
  return 0
}

bc_iptables_setup() {
  local n="$1" i mark tcp_port
  bc_have_iptables || return 1
  BC_RULE_BACKEND="iptables"

  bc_iptables_teardown

  iptables -t mangle -N "$BC_IPT_MANGLE_CHAIN" 2>/dev/null || true
  iptables -t mangle -F "$BC_IPT_MANGLE_CHAIN" 2>/dev/null || return 1
  iptables -t nat -N "$BC_IPT_NAT_CHAIN" 2>/dev/null || true
  iptables -t nat -F "$BC_IPT_NAT_CHAIN" 2>/dev/null || return 1

  iptables -t mangle -C OUTPUT -p tcp -j "$BC_IPT_MANGLE_CHAIN" 2>/dev/null || \
    iptables -t mangle -A OUTPUT -p tcp -j "$BC_IPT_MANGLE_CHAIN" || return 1
  iptables -t mangle -C OUTPUT -p udp -j "$BC_IPT_MANGLE_CHAIN" 2>/dev/null || \
    iptables -t mangle -A OUTPUT -p udp -j "$BC_IPT_MANGLE_CHAIN" || return 1
  iptables -t nat -C OUTPUT -p tcp -j "$BC_IPT_NAT_CHAIN" 2>/dev/null || \
    iptables -t nat -A OUTPUT -p tcp -j "$BC_IPT_NAT_CHAIN" || return 1

  i=0
  while [ "$i" -lt "$n" ]; do
    mark=$(bc_mark_for_worker "$i")
    tcp_port=$(bc_tcp_port_for_worker "$i")
    iptables -t nat -C "$BC_IPT_NAT_CHAIN" -p tcp -m mark --mark "$mark" -j REDIRECT --to-ports "$tcp_port" 2>/dev/null || \
      iptables -t nat -A "$BC_IPT_NAT_CHAIN" -p tcp -m mark --mark "$mark" -j REDIRECT --to-ports "$tcp_port" || return 1
    i=$((i + 1))
  done
}

bc_iptables_teardown() {
  if command -v iptables >/dev/null 2>&1; then
    while iptables -t mangle -D OUTPUT -p tcp -j "$BC_IPT_MANGLE_CHAIN" 2>/dev/null; do :; done
    while iptables -t mangle -D OUTPUT -p udp -j "$BC_IPT_MANGLE_CHAIN" 2>/dev/null; do :; done
    while iptables -t nat -D OUTPUT -p tcp -j "$BC_IPT_NAT_CHAIN" 2>/dev/null; do :; done
    iptables -t mangle -F "$BC_IPT_MANGLE_CHAIN" 2>/dev/null || true
    iptables -t mangle -X "$BC_IPT_MANGLE_CHAIN" 2>/dev/null || true
    iptables -t nat -F "$BC_IPT_NAT_CHAIN" 2>/dev/null || true
    iptables -t nat -X "$BC_IPT_NAT_CHAIN" 2>/dev/null || true
  fi
}

bc_kill_stale_byedpi() {
  for _pdir in /proc/[0-9]*; do
    [ -f "$_pdir/cmdline" ] || continue
    _cmd=$(tr '\0' ' ' < "$_pdir/cmdline" 2>/dev/null)
    case "$_cmd" in
      *byedpi*--port*18[0-9][0-9][0-9]*) kill -KILL "$(basename "$_pdir")" 2>/dev/null ;;
      *byedpi*--port*19[0-9][0-9][0-9]*) kill -KILL "$(basename "$_pdir")" 2>/dev/null ;;
    esac
  done
}

bc_byedpi_args_safe() {
  printf '%s\n' "$1" | grep -Eq '(^|[[:space:]])(--port(=|[[:space:]])|-p([[:space:]]|$)|--transparent([[:space:]]|$)|-E([[:space:]]|$)|--daemon([[:space:]]|$)|-D([[:space:]]|$)|--pidfile(=|[[:space:]])|-w([[:space:]]|$))' && return 1
  return 0
}

bc_byedpi_start() {
  local k="$1" args="$2" pid_tcp="$3" pid_udp="$4" logfile="$5"
  local tcp_port udp_port
  tcp_port=$(bc_tcp_port_for_worker "$k")
  udp_port=$(bc_udp_port_for_worker "$k")
  bc_byedpi_args_safe "$args" || return 2

  printf '=== [k=%s] byedpi tcp:%s udp:%s args: %s\n' "$k" "$tcp_port" "$udp_port" "$args" >>"$logfile" 2>/dev/null
  # shellcheck disable=SC2086
  "$BC_BYEDPI_BIN" --port "$tcp_port" --transparent $args >>"$logfile" 2>&1 &
  printf '%s\n' "$!" > "$pid_tcp"
  # shellcheck disable=SC2086
  "$BC_BYEDPI_BIN" --port "$udp_port" $args >>"$logfile" 2>&1 &
  printf '%s\n' "$!" > "$pid_udp"
  sleep 0.15 2>/dev/null || sleep 1
  kill -0 "$(cat "$pid_tcp" 2>/dev/null)" 2>/dev/null || return 1
  kill -0 "$(cat "$pid_udp" 2>/dev/null)" 2>/dev/null || return 1
  return 0
}

bc_byedpi_stop() {
  local pidfile pid
  for pidfile in "$@"; do
    [ -f "$pidfile" ] || continue
    pid=$(cat "$pidfile" 2>/dev/null)
    [ -n "$pid" ] && kill -KILL "$pid" 2>/dev/null
    rm -f "$pidfile"
  done
}
