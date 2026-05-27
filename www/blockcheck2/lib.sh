#!/bin/sh
# blockcheck2 helpers: DoH, probes, nft, worker UIDs. POSIX sh, IPv4.

BC_LIB_DIR="${BC_LIB_DIR:-/www/blockcheck2}"
BC_STATE_DIR="${BC_STATE_DIR:-/dev/shm/mihomo-blockcheck2}"
BC_NFT_TABLE="${BC_NFT_TABLE:-mihomo_blockcheck2}"
BC_NFT_TARGETS_SET="${BC_NFT_TARGETS_SET:-bc_targets}"
BC_QUEUE_BASE="${BC_QUEUE_BASE:-700}"
BC_MARK_BASE="${BC_MARK_BASE:-0x70000}"
BC_WORKER_MAX="${BC_WORKER_MAX:-32}"
# Per-worker source-port sub-range. Busybox nc has no SO_REUSEADDR; the
# range must be wide enough to avoid wrapping into TIME_WAIT'd ports.
BC_SPORT_BASE="${BC_SPORT_BASE:-16000}"
BC_SPORT_TOTAL="${BC_SPORT_TOTAL:-2000}"
BC_PROBE_TIMEOUT="${BC_PROBE_TIMEOUT:-8}"
BC_HARD_BODY="${BC_HARD_BODY:-0}"
BC_HARD_PATH="${BC_HARD_PATH:-/}"
BC_HARD_MIN_BYTES="${BC_HARD_MIN_BYTES:-16384}"
BC_TLS_MIN_BYTES="${BC_TLS_MIN_BYTES:-1024}"
BC_THROUGHPUT_BYTES="${BC_THROUGHPUT_BYTES:-262144}"
BC_THROUGHPUT_MAX_SEC="${BC_THROUGHPUT_MAX_SEC:-5}"
BC_DOH_TIMEOUT="${BC_DOH_TIMEOUT:-4}"
BC_DOH_SERVERS="${BC_DOH_SERVERS:-1.1.1.1|cloudflare-dns.com|/dns-query?name=%s&type=A 8.8.8.8|dns.google|/resolve?name=%s&type=A 9.9.9.9|dns.quad9.net|/dns-query?name=%s&type=A}"
BC_NFQWS="${BC_NFQWS:-nfqws2}"

bc_log() { printf '[bc] %s\n' "$*" >&2; }

# bc_repeat_probe N FUNC ARGS… — runs FUNC up to N times, fails on first non-zero.
bc_repeat_probe() {
  local reps="$1"; shift
  local fn="$1"; shift
  case "$reps" in ''|*[!0-9]*) reps=1 ;; esac
  [ "$reps" -lt 1 ] && reps=1
  local i=0
  while [ "$i" -lt "$reps" ]; do
    "$fn" "$@" || return 1
    i=$((i + 1))
  done
  return 0
}

bc_preflight() {
  local missing=""
  for b in nft openssl nc "$BC_NFQWS"; do
    command -v "$b" >/dev/null 2>&1 || missing="$missing $b"
  done
  if [ -n "$missing" ]; then
    bc_log "missing binaries:$missing"
    return 2
  fi
  if ! nft list tables >/dev/null 2>&1; then
    bc_log "nft недоступен — требуется ядро с nftables (RouterOS arm64/amd64 7.21+)"
    return 3
  fi
  return 0
}

# DoH resolve cache: $BC_DOH_CACHE_DIR/<host>, line 1 = expiry_unix_ts, остальное = IPv4.
BC_DOH_CACHE_DIR="${BC_DOH_CACHE_DIR:-${BC_STATE_DIR}/.dohcache}"
BC_DOH_TTL_MIN="${BC_DOH_TTL_MIN:-30}"
BC_DOH_TTL_MAX="${BC_DOH_TTL_MAX:-3600}"

# bc_doh_resolve HOST → один IPv4 на строку.
bc_doh_resolve() {
  local host="$1" spec ip sni path tmp out seen="" ttl=0 ips=""
  [ -z "$host" ] && return 0
  command -v openssl >/dev/null 2>&1 || return 0
  # Already a literal IPv4 — pass through.
  case "$host" in
    *[!0-9.]*) ;;
    *)
      printf '%s\n' "$host"
      return 0
      ;;
  esac

  # Cache lookup.
  mkdir -p "$BC_DOH_CACHE_DIR" 2>/dev/null
  local cache_file="$BC_DOH_CACHE_DIR/$host"
  if [ -s "$cache_file" ]; then
    local now exp
    now=$(date +%s)
    exp=$(head -n1 "$cache_file" 2>/dev/null)
    case "$exp" in
      ''|*[!0-9]*) ;;
      *)
        if [ "$now" -lt "$exp" ]; then
          tail -n +2 "$cache_file"
          return 0
        fi
        ;;
    esac
  fi

  local diag_file="${BC_DOH_DIAG:-/dev/null}"
  for spec in $BC_DOH_SERVERS; do
    ip="${spec%%|*}"; spec="${spec#*|}"
    sni="${spec%%|*}"; path="${spec#*|}"
    tmp=$(printf '%s' "$path" | sed "s/%s/$host/g")
    local stderr_buf="/dev/shm/.bc_doh_err.$$"
    # NOTE: dropped -verify_return_error / -verify_hostname. They depend on
    # OpenSSL finding a CA bundle (path varies between Alpine releases) and
    # silently make handshakes fail. For DoH resolution we only need TLS to
    # transport the query; SNI=cloudflare-dns.com against 1.1.1.1 is itself
    # the trust anchor we care about.
    out=$(
      {
        printf 'GET %s HTTP/1.1\r\n' "$tmp"
        printf 'Host: %s\r\n' "$sni"
        printf 'Accept: application/dns-json\r\n'
        printf 'Connection: close\r\n\r\n'
      } | timeout -k 2 "$BC_DOH_TIMEOUT" \
        openssl s_client -quiet -connect "$ip:443" -servername "$sni" 2>"$stderr_buf"
    )
    local rc=$?
    local errsnip=""
    [ -s "$stderr_buf" ] && errsnip=$(head -c 200 "$stderr_buf" 2>/dev/null | tr '\n\r\t' '   ')
    rm -f "$stderr_buf"
    printf 'doh %s@%s rc=%s outlen=%s err=%s\n' "$sni" "$ip" "$rc" "${#out}" "$errsnip" >> "$diag_file" 2>/dev/null
    # Strip HTTP headers — keep only the JSON body.
    local body
    body=$(printf '%s\n' "$out" | awk 'BEGIN{b=0} /^\r?$/ {b=1; next} b {print}')

    # Extract IPv4 addresses from `"data":"x.x.x.x"` and the smallest TTL
    # from `"TTL":N`. Simple grep+sed — far more robust across busybox awk
    # versions than a multi-pattern awk parser. For DoH JSON the only `data`
    # fields containing a literal IPv4 are A records, so this is correct.
    local ip_list ttl_min
    ip_list=$(printf '%s' "$body" | grep -oE '"data"[[:space:]]*:[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"' \
              | sed -E 's/.*"([0-9.]+)"$/\1/')
    ttl_min=$(printf '%s' "$body" | grep -oE '"TTL"[[:space:]]*:[[:space:]]*[0-9]+' \
              | sed -E 's/.*:[[:space:]]*//' | sort -n | head -n1)
    printf 'doh %s@%s parsed_ips=%s ttl_min=%s\n' "$sni" "$ip" "$(printf '%s' "$ip_list" | tr '\n' ',')" "$ttl_min" >> "$diag_file" 2>/dev/null

    [ -z "$ip_list" ] && continue

    # Collect unique IPs.
    for d in $ip_list; do
      [ "$d" = "$ip" ] && continue
      case " $seen " in *" $d "*) continue ;; esac
      seen="$seen $d"
      ips="${ips:+$ips }$d"
    done
    if [ -n "$ttl_min" ] && [ "$ttl_min" -gt 0 ] 2>/dev/null; then
      ttl="$ttl_min"
    fi
    [ -n "$ips" ] && break
  done

  if [ -z "$ips" ]; then
    printf 'no_ips host=%s\n' "$host" >> "$diag_file" 2>/dev/null
    return 0
  fi

  # Clamp TTL.
  [ "$ttl" -lt "$BC_DOH_TTL_MIN" ] && ttl="$BC_DOH_TTL_MIN"
  [ "$ttl" -gt "$BC_DOH_TTL_MAX" ] && ttl="$BC_DOH_TTL_MAX"
  local exp=$(( $(date +%s) + ttl ))
  # Atomic cache write (tmp + mv).
  local cache_tmp="$cache_file.tmp.$$"
  {
    printf '%s\n' "$exp"
    for d in $ips; do printf '%s\n' "$d"; done
  } > "$cache_tmp" 2>/dev/null && mv "$cache_tmp" "$cache_file" 2>/dev/null
  for d in $ips; do printf '%s\n' "$d"; done
}

# Drop the cache (used by runner cleanup if desired; not called by default —
# cache survives across jobs to speed repeat runs within TTL).
bc_doh_cache_clear() {
  rm -rf "$BC_DOH_CACHE_DIR" 2>/dev/null
}

# Marking: dst-IP set @bc_targets + per-worker src-port sub-range → ct mark K → queue K.
# Worker UID-based маркировка (`meta skuid`, cgroupv2) на ядре 5.6.3 RouterOS не
# работает — отсюда sport-схема. От ранних проб остались bc_ensure_users / per-UID
# probes; всё это удалено, probes идут от root (CGI uid), маркируется sport-range.
# Probe должен делать `-bind 0.0.0.0:<port>` через bc_probe_port. NO `bypass` на queue:
# если nfqws упал — пакеты дропаются, и probe явно фейлится вместо тихого pass.
bc_nft_setup() {
  local n="$1" i mark queue step sport_min sport_max
  bc_nft_teardown
  [ "$n" -lt 1 ] && n=1
  step=$((BC_SPORT_TOTAL / n))
  [ "$step" -lt 1 ] && step=1

  nft add table inet "$BC_NFT_TABLE" || return 1
  nft add set inet "$BC_NFT_TABLE" "$BC_NFT_TARGETS_SET" \
    '{ type ipv4_addr; flags interval; }' || return 1
  nft add chain inet "$BC_NFT_TABLE" out  '{ type filter hook output      priority mangle; policy accept; }'
  nft add chain inet "$BC_NFT_TABLE" post '{ type filter hook postrouting priority mangle; policy accept; }'
  nft add chain inet "$BC_NFT_TABLE" pre  '{ type filter hook prerouting  priority mangle; policy accept; }'

  i=0
  while [ "$i" -lt "$n" ]; do
    mark=$((BC_MARK_BASE + i))
    queue=$((BC_QUEUE_BASE + i))
    sport_min=$((BC_SPORT_BASE + i * step))
    sport_max=$((BC_SPORT_BASE + (i + 1) * step - 1))

    nft add rule inet "$BC_NFT_TABLE" out \
      ip daddr "@${BC_NFT_TARGETS_SET}" tcp sport "$sport_min-$sport_max" \
      ct state new counter ct mark set "$mark"
    nft add rule inet "$BC_NFT_TABLE" out \
      ip daddr "@${BC_NFT_TARGETS_SET}" udp sport "$sport_min-$sport_max" \
      ct state new counter ct mark set "$mark"

    # Без `ct {original,reply} packets N-M` фильтра: для QUIC Initial,
    # уложившегося в один датаграмм, packet counter на mangle-priority
    # ещё 0 (confirm после нас) — пакет проскакивал мимо очереди.
    # Стратегии короткоживущие, лимит не нужен.
    nft add rule inet "$BC_NFT_TABLE" post \
      meta l4proto { tcp, udp } ct mark "$mark" \
      counter queue num "$queue"

    nft add rule inet "$BC_NFT_TABLE" pre \
      meta l4proto { tcp, udp } ct mark "$mark" \
      counter queue num "$queue"

    i=$((i + 1))
  done

  nft add rule inet "$BC_NFT_TABLE" out  ip daddr "@${BC_NFT_TARGETS_SET}" counter comment '"out_targets_total"'
  nft add rule inet "$BC_NFT_TABLE" post meta l4proto { tcp, udp } counter comment '"post_total"'
  nft add rule inet "$BC_NFT_TABLE" pre  meta l4proto { tcp, udp } counter comment '"pre_total"'
}

bc_nft_add_target() {
  local ip="$1"
  [ -z "$ip" ] && return 1
  nft add element inet "$BC_NFT_TABLE" "$BC_NFT_TARGETS_SET" "{ $ip }" 2>/dev/null
  return 0
}

# bc_probe_port K N → порт в sub-range воркера K. Файловый счётчик чтобы
# не словить EADDRINUSE на TIME_WAIT при back-to-back probes (busybox nc
# без SO_REUSEADDR).
bc_probe_port() {
  local k="$1" n="$2" step sport_min ctr_file ctr
  [ "$n" -lt 1 ] && n=1
  step=$((BC_SPORT_TOTAL / n))
  [ "$step" -lt 1 ] && step=1
  sport_min=$((BC_SPORT_BASE + k * step))
  ctr_file="${BC_STATE_DIR}/.portctr_w${k}"
  if [ -r "$ctr_file" ]; then
    ctr=$(cat "$ctr_file" 2>/dev/null)
    case "$ctr" in ''|*[!0-9]*) ctr=0 ;; esac
  else
    ctr=0
  fi
  ctr=$((ctr + 1))
  printf '%s' "$ctr" > "$ctr_file" 2>/dev/null
  printf '%s\n' $((sport_min + ctr % step))
}

bc_nft_teardown() {
  nft list table inet "$BC_NFT_TABLE" >/dev/null 2>&1 && \
    nft delete table inet "$BC_NFT_TABLE" 2>/dev/null
  nft list table ip "$BC_NFT_TABLE" >/dev/null 2>&1 && \
    nft delete table ip "$BC_NFT_TABLE" 2>/dev/null
  return 0
}

bc_kill_stale_nfqws() {
  local q
  for q in $(seq "$BC_QUEUE_BASE" $((BC_QUEUE_BASE + BC_WORKER_MAX - 1))); do
    ps -o pid,args 2>/dev/null | awk -v q="$q" '
      $0 ~ ("--qnum[= ]" q "([^0-9]|$)") { print $1 }
    ' | while IFS= read -r pid; do
      [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null
    done
  done
}

# bc_nfqws_start K PROTO ARGS PIDFILE LOG
bc_nfqws_start() {
  local k="$1" proto="$2" args="$3" pidfile="$4" logfile="$5"
  local queue=$((BC_QUEUE_BASE + k))
  local filter
  # Если в args уже есть свой --filter-*, не добавляем дефолтный (multi-profile через --new).
  case " $args " in
    *' --filter-tcp='*|*' --filter-udp='*) filter="" ;;
    *)
      case "$proto" in
        quic)             filter="--filter-udp=443" ;;
        http)             filter="--filter-tcp=80"  ;;
        tls|tls12|tls13)  filter="--filter-tcp=443" ;;
        *)                filter="--filter-tcp=80,443" ;;
      esac
      ;;
  esac
  local lua_args=""
  if [ "$BC_NFQWS" = "nfqws2" ] || [ "${BC_NFQWS##*/}" = "nfqws2" ]; then
    local f
    for f in /lua/*.lua; do
      [ -f "$f" ] && lua_args="$lua_args --lua-init=@$f"
    done
  fi
  # Лог точной команды — для диффа между main-scan и custom-test когда
  # стратегия проходит в одном и фейлится в другом.
  printf '=== [k=%s queue=%s] %s --qnum %s --user=root %s %s %s\n' \
    "$k" "$queue" "$BC_NFQWS" "$queue" "$lua_args" "$args" "$filter" \
    >>"$logfile" 2>/dev/null
  # shellcheck disable=SC2086
  "$BC_NFQWS" --qnum "$queue" --user=root $lua_args $args $filter >>"$logfile" 2>&1 &
  local pid=$!
  printf '%s\n' "$pid" > "$pidfile"
  sleep 0.1 2>/dev/null || sleep 1
  if ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$pidfile"
    return 1
  fi
  return 0
}

bc_nfqws_stop() {
  local pidfile="$1" pid
  [ -f "$pidfile" ] || return 0
  pid=$(cat "$pidfile" 2>/dev/null)
  [ -n "$pid" ] && kill "$pid" 2>/dev/null
  rm -f "$pidfile"
  local i=0
  while [ "$i" -lt 10 ] && [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; do
    i=$((i + 1)); sleep 0.05 2>/dev/null || sleep 1
  done
}

# Probes: возвращают 0=ok / 1=fail. Каждый bind'ит source port в sub-range
# воркера K — nft `*sport` ловит соединение и направляет в queue.
# Caller должен экспортировать BC_TOTAL_WORKERS.

bc_probe_http() {
  local k="$1" host="$2" ip="$3"
  local n="${BC_TOTAL_WORKERS:-8}"
  local method path size port attempt=0 out=""
  if [ "$BC_HARD_BODY" = "1" ]; then
    method="GET"; path="$BC_HARD_PATH"
  else
    method="HEAD"; path="/"
  fi
  while [ "$attempt" -lt 3 ]; do
    port=$(bc_probe_port "$k" "$n")
    if [ "$BC_HARD_BODY" = "1" ]; then
      local body_file="${BC_STATE_DIR:-/tmp}/.http_body_w${k}.$$"
      local err_file="${BC_STATE_DIR:-/tmp}/.http_err_w${k}.$$"
      printf '%s %s HTTP/1.0\r\nHost: %s\r\nUser-Agent: Mozilla/5.0\r\nAccept: */*\r\nConnection: close\r\n\r\n' "$method" "$path" "$host" \
        | timeout -k 2 "$BC_PROBE_TIMEOUT" nc -p "$port" -w "$BC_PROBE_TIMEOUT" "$ip" 80 2>"$err_file" > "$body_file"
      size=$(wc -c < "$body_file" 2>/dev/null)
      case "$size" in ''|*[!0-9]*) size=0 ;; esac
      out=$(head -c 256 "$body_file" 2>/dev/null)
      err=$(cat "$err_file" 2>/dev/null)
      rm -f "$body_file" "$err_file"
      case "$err" in
        *"Address in use"*|*"address in use"*|*"already in use"*)
          attempt=$((attempt+1)); continue ;;
      esac
      # HTTP/80 на большинстве сайтов отдаёт 301/302 на HTTPS — тело редиректа
      # маленькое (~300 байт), size-гейт его режет. Для HTTP DPI обходится если
      # вообще пришёл ответ 2xx/3xx; size-гейт держим только для 200 (полное тело).
      status_line=$(printf '%s' "$out" | awk 'NR==1{print; exit}')
      case "$status_line" in
        "HTTP/1."[01]" 2"*)
          [ "$size" -ge "$BC_HARD_MIN_BYTES" ] && return 0
          ;;
        "HTTP/1."[01]" 3"*)
          return 0
          ;;
      esac
      break
    else
      out=$(printf 'HEAD / HTTP/1.0\r\nHost: %s\r\nUser-Agent: Mozilla/5.0\r\nAccept: */*\r\nConnection: close\r\n\r\n' "$host" \
        | timeout -k 2 "$BC_PROBE_TIMEOUT" nc -p "$port" -w "$BC_PROBE_TIMEOUT" "$ip" 80 2>&1)
      case "$out" in
        HTTP/*|*"HTTP/1."*) return 0 ;;
        *"Address in use"*|*"address in use"*|*"already in use"*)
          attempt=$((attempt+1)); continue ;;
      esac
      break
    fi
  done
  if [ -n "$BC_STATE_DIR" ]; then
    printf 'mode=%s size=%s port=%s\n---\n%s\n' \
      "${BC_HARD_BODY:-0}" "${size:-0}" "$port" "$out" \
      > "${BC_STATE_DIR}/.http_diag_w${k}" 2>/dev/null
  fi
  return 1
}

# bc_probe_tls K HOST IP TLSVER  → tls1_2 | tls1_3.
# Pass-marker: "Cipher is " / "New, TLSv" — печатается ТОЛЬКО после Finished.
# `BEGIN CERTIFICATE` не годится: появляется ещё в середине handshake.
bc_probe_tls() {
  local k="$1" host="$2" ip="$3" ver="$4"
  local n="${BC_TOTAL_WORKERS:-8}"
  local port
  port=$(bc_probe_port "$k" "$n")
  local flag=""
  case "$ver" in
    tls1_2) flag="-tls1_2" ;;
    tls1_3) flag="-tls1_3" ;;
  esac
  local out size=0
  if [ "$BC_HARD_BODY" = "1" ]; then
    local body_file="${BC_STATE_DIR:-/tmp}/.tls_body_w${k}_${ver}.$$"
    # shellcheck disable=SC2086
    printf 'GET %s HTTP/1.0\r\nHost: %s\r\nUser-Agent: Mozilla/5.0\r\nAccept: */*\r\nConnection: close\r\n\r\n' "$BC_HARD_PATH" "$host" \
      | timeout -k 2 "$BC_PROBE_TIMEOUT" openssl s_client $flag -quiet -ign_eof \
          -bind "0.0.0.0:$port" -connect "$ip:443" -servername "$host" \
          2>/dev/null > "$body_file"
    size=$(wc -c < "$body_file" 2>/dev/null)
    case "$size" in ''|*[!0-9]*) size=0 ;; esac
    out=$(head -c 256 "$body_file" 2>/dev/null)
    rm -f "$body_file"
    case "$out" in
      HTTP/*|*"HTTP/1."*)
        [ "$size" -ge "$BC_HARD_MIN_BYTES" ] && return 0
        ;;
    esac
  else
    # shellcheck disable=SC2086
    out=$(timeout -k 2 "$BC_PROBE_TIMEOUT" openssl s_client $flag \
      -bind "0.0.0.0:$port" -connect "$ip:443" -servername "$host" \
      </dev/null 2>&1)
    size=${#out}
    if [ "$size" -ge "$BC_TLS_MIN_BYTES" ]; then
      case "$out" in
        *"Cipher is "*|*"Cipher    : "*|*"New, TLSv"*|*"Verification: OK"*|*"Verify return code: 0"*) return 0 ;;
      esac
    fi
  fi
  if [ -n "$BC_STATE_DIR" ]; then
    printf 'mode=%s size=%s min=%s port=%s ver=%s\n---\n%s\n' \
      "${BC_HARD_BODY:-0}" "$size" "$BC_TLS_MIN_BYTES" "$port" "$ver" "$out" \
      > "${BC_STATE_DIR}/.tls_diag_w${k}_${ver}" 2>/dev/null
  fi
  return 1
}

# QUIC через `openssl s_client -quic` (OpenSSL ≥3.5). `-quic` не выходит
# сам после handshake — exit code всегда 143 от timeout, проверяем по выводу.
bc_probe_quic() {
  local k="$1" host="$2" ip="$3"
  local n="${BC_TOTAL_WORKERS:-8}"
  local port
  port=$(bc_probe_port "$k" "$n")

  local out
  out=$(timeout -k 2 "$BC_PROBE_TIMEOUT" openssl s_client -quic \
        -bind "0.0.0.0:$port" -connect "$ip:443" \
        -servername "$host" -alpn h3 \
        </dev/null 2>&1)

  if [ -n "$BC_STATE_DIR" ]; then
    printf 'port=%s\n---\n%s\n' "$port" "$out" \
      > "${BC_STATE_DIR}/.quic_diag_w${k}" 2>/dev/null
  fi

  case "$out" in
    *"Server certificate"*|*"Certificate chain"*|*"BEGIN CERTIFICATE"*|*"Verify return code: 0"*|*"verify return:1"*) return 0 ;;
  esac
  return 1
}

# Throughput-probe для @full и googlevideo /videoplayback. Тянем
# BC_THROUGHPUT_BYTES за ≤BC_THROUGHPUT_MAX_SEC; имплицитный порог kbps.
bc_probe_throughput() {
  local k="$1" host="$2" ip="$3" path="$4"
  local n="${BC_TOTAL_WORKERS:-8}"
  local port
  port=$(bc_probe_port "$k" "$n")
  local bytes="${BC_THROUGHPUT_BYTES:-262144}"
  local max="${BC_THROUGHPUT_MAX_SEC:-5}"
  [ -z "$path" ] && path="/"

  local out_file="${BC_STATE_DIR:-/dev/shm/mihomo-blockcheck2}/.thr_w${k}.$$"
  printf 'GET %s HTTP/1.1\r\nHost: %s\r\nRange: bytes=0-%s\r\nUser-Agent: Mozilla/5.0\r\nAccept: */*\r\nAccept-Encoding: identity\r\nConnection: close\r\n\r\n' \
    "$path" "$host" "$((bytes - 1))" \
  | timeout -k 2 "$max" openssl s_client -tls1_3 -quiet -ign_eof -alpn http/1.1 \
      -bind "0.0.0.0:$port" -connect "$ip:443" -servername "$host" \
      2>/dev/null > "$out_file"

  local size status
  size=$(wc -c < "$out_file" 2>/dev/null)
  case "$size" in ''|*[!0-9]*) size=0 ;; esac
  status=$(head -c 32 "$out_file" 2>/dev/null | awk 'NR==1 {print $2; exit}')

  if [ -n "$BC_STATE_DIR" ]; then
    printf 'size=%s need=%s max_sec=%s status=%s port=%s host=%s path=%.200s\n' \
      "$size" "$bytes" "$max" "$status" "$port" "$host" "$path" \
      > "${BC_STATE_DIR}/.thr_diag_w${k}" 2>/dev/null
  fi
  rm -f "$out_file"

  case "$status" in 2*) ;; *) return 1 ;; esac
  [ "$size" -ge "$bytes" ] && return 0
  return 1
}
