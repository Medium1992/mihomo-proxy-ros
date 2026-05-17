#!/bin/sh
CONFIG_DIR="${CONFIG_DIR:-/root/.config/mihomo}"
CONFIG="$CONFIG_DIR/config.yaml"

echo "Content-Type: text/plain; charset=utf-8"
echo

active_files() {
  [ -f "$CONFIG" ] && printf '%s\n' "$CONFIG"

  if [ -f "$CONFIG" ]; then
    awk '
      /^[[:space:]]*path:[[:space:]]*/ {
        sub(/^[[:space:]]*path:[[:space:]]*/, "", $0)
        gsub(/^["'\'']|["'\'']$/, "", $0)
        print
      }
    ' "$CONFIG" | while IFS= read -r path; do
      [ -n "$path" ] || continue
      case "$path" in
        /*) file="$path" ;;
        *) file="$CONFIG_DIR/$path" ;;
      esac
      [ -f "$file" ] && printf '%s\n' "$file"
    done

    for payload in "$CONFIG_DIR"/*_ruleset_payload.txt; do
      [ -f "$payload" ] || continue
      base="$(basename "$payload" _ruleset_payload.txt)"
      grep -q "${base}_ruleset" "$CONFIG" 2>/dev/null && printf '%s\n' "$payload"
    done
  fi

  printenv | grep -E '^BYEDPI_CMD[0-9]*=' | cut -d= -f1 | sort -V | while IFS= read -r name; do
    idx="${name#BYEDPI_CMD}"
    [ "$idx" = "$name" ] && idx=0
    [ -f "/hs5t_${idx}.yml" ] && printf '%s\n' "/hs5t_${idx}.yml"
  done
}

seen=""
active_files | awk '!seen[$0]++' | while IFS= read -r file; do
  [ -f "$file" ] || continue
  case " $seen " in *" $file "*) continue ;; esac
  seen="$seen $file"
  printf '\n===== %s =====\n' "$file"
  cat "$file" 2>/dev/null
  printf '\n'
done

if [ ! -f "$CONFIG" ]; then
  echo "No generated mihomo config found at $CONFIG"
fi
