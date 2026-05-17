#!/bin/sh

set -u

WWW_DIR="${WWW_DIR:-/www}"
CGI="$WWW_DIR/cgi-bin/index.sh"
PAGES="overview:index core:core providers:providers dpi:dpi groups:groups rules:rules rulesets:rulesets yaml:yaml tools:tools"

[ -f "$CGI" ] || exit 0

render_page() {
  page="$1"
  out="$2"
  tmp="${out}.tmp"
  QUERY_STRING="page=$page" STATIC_MODE=true /bin/sh "$CGI" | awk '
    BEGIN { body=0 }
    body { print }
    /^$/ && body == 0 { body=1 }
  ' > "$tmp" && mv "$tmp" "$out"
}

for item in $PAGES; do
  page="${item%%:*}"
  name="${item#*:}"
  render_page "$page" "$WWW_DIR/${name}.html"
done
