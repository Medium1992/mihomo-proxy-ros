#!/bin/sh

set -u

WWW_DIR="${WWW_DIR:-/www}"
CGI="$WWW_DIR/cgi-bin/index.sh"
PAGES="overview:index core:core providers:providers listeners:listeners dpi:dpi groups:groups rules:rules rulesets:rulesets yaml:yaml tools:tools"
CURRENT_PID=""

graceful_shutdown() {
  trap - TERM INT
  [ -n "$CURRENT_PID" ] && kill "$CURRENT_PID" 2>/dev/null || true
  exit 0
}
trap graceful_shutdown TERM INT

[ -f "$CGI" ] || exit 0

render_page() {
  page="$1"
  out="$2"
  raw="${out}.raw"
  tmp="${out}.tmp"
  rm -f "$raw" "$tmp"
  # Write the CGI output to a file FIRST — no pipe → no SIGPIPE / Broken pipe noise.
  QUERY_STRING="page=$page" STATIC_MODE=true /bin/sh "$CGI" >"$raw" 2>/dev/null &
  CURRENT_PID="$!"
  wait "$CURRENT_PID" 2>/dev/null || {
    rc=$?
    CURRENT_PID=""
    rm -f "$raw" "$tmp"
    return "$rc"
  }
  CURRENT_PID=""
  if [ ! -s "$raw" ]; then
    rm -f "$raw"
    return 1
  fi
  # Strip HTTP headers (up to first empty line) and write body to tmp.
  awk '
    BEGIN { body = 0 }
    body { print; next }
    /^$/ { body = 1 }
  ' "$raw" > "$tmp" 2>/dev/null
  rm -f "$raw"
  if [ -s "$tmp" ]; then
    mv "$tmp" "$out"
  else
    rm -f "$tmp"
    return 1
  fi
}

for item in $PAGES; do
  page="${item%%:*}"
  name="${item#*:}"
  render_page "$page" "$WWW_DIR/${name}.html" || echo "render_static: failed $page" >&2
done
