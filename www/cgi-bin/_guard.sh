#!/bin/sh
# Общий CSRF-guard для CGI, которые что-то меняют или ходят наружу.
# Подключение: . /www/cgi-bin/_guard.sh   (после вывода заголовков)
#
# Заголовок Origin busybox httpd в CGI НЕ пробрасывает — список экспортируемых
# заголовков в нём фиксированный (Host, Referer, Cookie, User-Agent, Auth...).
# Поэтому опираемся на Referer: наши страницы отдаются с
# `Referrer-Policy: same-origin`, значит свои же запросы Referer несут всегда,
# а сторонний сайт при cross-site POST его либо не пришлёт, либо пришлёт чужой
# хост. Оба случая режутся.
#
# Отключить проверку (например, чтобы дёргать API из скриптов):
#   /container/envs/add ... key="WEB_CSRF" value="off"

csrf_ok() {
  [ "${WEB_CSRF:-on}" = "off" ] && return 0
  _ref="${HTTP_REFERER:-}"
  _host="${HTTP_HOST:-}"
  [ -n "$_ref" ] || return 1
  [ -n "$_host" ] || return 1
  _rest="${_ref#*://}"
  _refhost="${_rest%%/*}"
  [ "$_refhost" = "$_host" ]
}

# Печатает готовый JSON-отказ и выходит. Заголовки должны быть уже выведены.
csrf_guard_json() {
  csrf_ok && return 0
  printf '{"ok":false,"error":"cross-origin request blocked"}\n'
  exit 0
}

# То же самое для text/plain-эндпоинтов.
csrf_guard_text() {
  csrf_ok && return 0
  echo "Error: cross-origin request blocked"
  exit 1
}

# --- SSRF ---
# http-fetch / xray2mihomo-sub ходят по URL, который пришёл из браузера.
# Без фильтра через них достаётся всё, что видно изнутри контейнера:
# mihomo API на 127.0.0.1:9090, соседи по LAN, metadata-сервисы облаков.
# Разрешить приватные адреса (например, подписка на своём же NAS):
#   /container/envs/add ... key="ALLOW_PRIVATE_FETCH" value="true"
host_is_private() {
  [ "${ALLOW_PRIVATE_FETCH:-false}" = "true" ] && return 1
  _h="$1"
  case "$_h" in
    localhost|localhost.*|*.localhost|'[::1]'|::1|0.0.0.0) return 0 ;;
  esac
  # Только литеральные IP: имена не резолвим (лишний DNS-запрос на каждый
  # вызов и всё равно гонка TOCTOU). Публичные имена, ведущие в приватную
  # сеть, отсекает уже сам факт basic auth на панели.
  case "$_h" in
    *[!0-9.]*) return 1 ;;
  esac
  IFS='.' read -r _a _b _ _ <<EOF
$_h
EOF
  case "$_a" in ''|*[!0-9]*) return 1 ;; esac
  [ "$_a" = 127 ] && return 0
  [ "$_a" = 10 ] && return 0
  [ "$_a" = 0 ] && return 0
  if [ "$_a" = 192 ]; then
    [ "$_b" = 168 ] && return 0
  fi
  if [ "$_a" = 169 ]; then
    [ "$_b" = 254 ] && return 0
  fi
  if [ "$_a" = 172 ]; then
    case "$_b" in
      ''|*[!0-9]*) ;;
      *) [ "$_b" -ge 16 ] && [ "$_b" -le 31 ] && return 0 ;;
    esac
  fi
  return 1
}

# Достаёт host (без порта) из http(s)-URL.
url_host() {
  _rest="${1#*://}"
  _rest="${_rest%%/*}"
  _rest="${_rest#*@}"
  case "$_rest" in
    \[*\]*) printf '%s' "${_rest%%]*}]" ;;
    *) printf '%s' "${_rest%%:*}" ;;
  esac
}
