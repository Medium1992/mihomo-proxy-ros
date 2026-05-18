#!/bin/sh

CONFIG_DIR="${CONFIG_DIR:-/root/.config/mihomo}"
RUNTIME_DIR="${RUNTIME_DIR:-/dev/shm/mihomo}"
AWG_DIR="$CONFIG_DIR/awg"
PROXIES_DIR="$CONFIG_DIR/proxies_mount"
RULE_SET_DIR="$CONFIG_DIR/rule_set_list"
CONTAINER_NAME="${CONTAINER_NAME:-mihomo-proxy-ros}"

qs_get() {
  key="$1"
  printf '%s' "${QUERY_STRING:-}" | tr '&' '\n' | awk -F= -v k="$key" '$1==k {print $2; exit}'
}

page="$(qs_get page)"
[ -z "$page" ] && page="overview"
STATIC_MODE="${STATIC_MODE:-false}"

page_url() {
  id="$1"
  if [ "$STATIC_MODE" = "true" ]; then
    [ "$id" = "overview" ] && printf 'index.html' || printf '%s.html' "$id"
  else
    printf '/cgi-bin/index.sh?page=%s' "$id"
  fi
}

asset_url() {
  path="$1"
  if [ "$STATIC_MODE" = "true" ]; then
    printf '%s' "${path#/}"
  else
    printf '/%s' "${path#/}"
  fi
}

h() {
  sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'
}

env_raw() {
  printenv "$1" 2>/dev/null || true
}

env_default() {
  val="$(env_raw "$1")"
  [ -n "$val" ] && printf '%s' "$val" || printf '%s' "$2"
}

env_attr() {
  env_default "$1" "$2" | h
}

yaml_link_name() {
  base="$(basename "$1")"
  case "$base" in
    *.conf) printf '%s.yaml' "${base%.*}" ;;
    *) printf '%s' "$base" ;;
  esac
}

mounted_file_links() {
  dir="$1"
  ls "$dir" 2>/dev/null | while IFS= read -r file; do
    [ -n "$file" ] || continue
    yaml="$(yaml_link_name "$file")"
    printf '<a class="mount-link" href="%s#%s"><span>%s</span><small>%s</small></a>\n' "$(page_url yaml)" "$(printf '%s' "$yaml" | h)" "$(printf '%s' "$file" | h)" "$(printf '%s' "$yaml" | h)"
  done
}

is_set() {
  [ -n "$(env_raw "$1")" ] && printf 'set' || printf 'default'
}

checked() {
  val="$(env_default "$1" "$2")"
  [ "$val" = "true" ] && printf ' checked'
}

selected() {
  [ "$(env_default "$1" "$3")" = "$2" ] && printf ' selected'
}

count_env() {
  printenv | grep -E "$1" | wc -l | tr -d ' '
}

env_names() {
  printenv | grep -E "$1" | cut -d= -f1 | sort -V
}

sanitize_rule_group_name() {
  printf '%s' "$1" | xargs | sed 's/[^a-zA-Z0-9_-]//g'
}

group_env_prefix() {
  printf '%s' "$1" | tr '-' '_' | tr '[:lower:]' '[:upper:]' | sed 's/[^A-Z0-9_]/_/g'
}

custom_rule_group_names() {
  {
    for var in $(env_names '^RULE_SET[0-9]+_BASE64='); do
      value="$(env_raw "$var")"
      case "$value" in
        *"#"*) sanitize_rule_group_name "${value#*#}" ;;
      esac
    done
    if [ -d "$RULE_SET_DIR" ]; then
      for f in "$RULE_SET_DIR"/*; do
        [ -f "$f" ] || continue
        raw="$(basename "$f")"
        sanitize_rule_group_name "${raw%.*}"
      done
    fi
  } | sed '/^$/d' | sort -u
}

custom_rule_group_records() {
  {
    for var in $(env_names '^RULE_SET[0-9]+_BASE64='); do
      value="$(env_raw "$var")"
      case "$value" in
        *"#"*)
          name="$(sanitize_rule_group_name "${value#*#}")"
          [ -n "$name" ] && printf '%s|base64|%s\n' "$name" "$var"
          ;;
      esac
    done
    if [ -d "$RULE_SET_DIR" ]; then
      for f in "$RULE_SET_DIR"/*; do
        [ -f "$f" ] || continue
        raw="$(basename "$f")"
        name="$(sanitize_rule_group_name "${raw%.*}")"
        [ -n "$name" ] && printf '%s|mount|%s\n' "$name" "$raw"
      done
    fi
  } | awk -F'|' '!seen[$1]++'
}

config_rule_lines() {
  config="$CONFIG_DIR/config.yaml"
  [ -f "$config" ] || return 0
  awk '
    $0 == "rules:" {inside=1; next}
    inside && /^[^[:space:]]/ {inside=0}
    inside && /^[[:space:]]*-[[:space:]]*/ {
      sub(/^[[:space:]]*-[[:space:]]*/, "")
      print
    }
  ' "$config"
}

active_yaml_files() {
  config="$RUNTIME_DIR/config.yaml"
  [ -f "$config" ] && printf '%s\n' "$config"

  if [ -f "$config" ]; then
    awk '
      /^[[:space:]]*path:[[:space:]]*/ {
        sub(/^[[:space:]]*path:[[:space:]]*/, "", $0)
        gsub(/^["'\'']|["'\'']$/, "", $0)
        print
      }
    ' "$config" | while IFS= read -r path; do
      [ -n "$path" ] || continue
      case "$path" in
        /*) file="$path" ;;
        *) file="$RUNTIME_DIR/$path" ;;
      esac
      [ -f "$file" ] && printf '%s\n' "$file"
    done

    for payload in "$RUNTIME_DIR"/*_ruleset_payload.txt; do
      [ -f "$payload" ] || continue
      base="$(basename "$payload" _ruleset_payload.txt)"
      if grep -q "${base}_ruleset" "$config" 2>/dev/null; then
        printf '%s\n' "$payload"
      fi
    done
  fi

  for name in $(env_names '^BYEDPI_CMD[0-9]*='); do
    idx="${name#BYEDPI_CMD}"
    [ "$idx" = "$name" ] && idx=0
    [ -f "/hs5t_${idx}.yml" ] && printf '%s\n' "/hs5t_${idx}.yml"
  done
}

field() {
  name="$1"; label="$2"; hint="$3"; placeholder="$4"; type="${5:-text}"; default="${6:-}"
  value="$(env_attr "$name" "$default")"
  state="$(is_set "$name")"
  cat <<EOF
<label class="field" data-env="$name">
  <span><b>$label</b><em>$name</em></span>
  <input type="$type" name="$name" value="$value" placeholder="$(printf '%s' "$placeholder" | h)" data-default="$(printf '%s' "$default" | h)">
  <small>$hint</small>
  <i>$state</i>
</label>
EOF
}

textarea_field() {
  name="$1"; label="$2"; hint="$3"; placeholder="$4"; default="${5:-}"
  value="$(env_default "$name" "$default" | h)"
  state="$(is_set "$name")"
  cat <<EOF
<label class="field field-wide" data-env="$name">
  <span><b>$label</b><em>$name</em></span>
  <textarea name="$name" placeholder="$(printf '%s' "$placeholder" | h)" data-default="$(printf '%s' "$default" | h)">$value</textarea>
  <small>$hint</small>
  <i>$state</i>
</label>
EOF
}

select_field() {
  name="$1"; label="$2"; hint="$3"; default="$4"; options="$5"
  state="$(is_set "$name")"
  cat <<EOF
<label class="field" data-env="$name">
  <span><b>$label</b><em>$name</em></span>
  <select name="$name" data-default="$default">
EOF
  for opt in $options; do
    printf '<option value="%s"%s>%s</option>\n' "$opt" "$(selected "$name" "$opt" "$default")" "$opt"
  done
  cat <<EOF
  </select>
  <small>$hint</small>
  <i>$state</i>
</label>
EOF
}

toggle_field() {
  name="$1"; label="$2"; hint="$3"; default="$4"
  state="$(is_set "$name")"
  cat <<EOF
<label class="toggle" data-env="$name">
  <input type="checkbox" name="$name" value="true" data-default="$default"$(checked "$name" "$default")>
  <span></span>
  <b>$label</b>
  <small>$hint</small>
  <i>$name · $state</i>
</label>
EOF
}

dns_policy_editor() {
  current="$(env_default NAMESERVER_POLICY "")"
  cat <<EOF
  <input type="hidden" name="NAMESERVER_POLICY" id="nameserverPolicyValue" value="$(printf '%s' "$current" | h)">
  <div class="dns-policy-editor">
    <div class="dns-policy-head">
      <b>Nameserver policy</b>
      <span>NAMESERVER_POLICY</span>
      <button type="button" onclick="addDnsPolicyRow('', '', '')">Добавить policy</button>
    </div>
    <div class="dns-policy-grid dns-policy-labels">
      <span><a href="https://wiki.metacubex.one/ru/config/dns/#nameserver-policy" target="_blank" rel="noopener">Ресурс *</a></span>
      <span><a href="https://wiki.metacubex.one/ru/config/dns/#nameserver-policy" target="_blank" rel="noopener">DNS сервер *</a></span>
      <span><a href="https://wiki.metacubex.one/ru/config/dns/#_2" target="_blank" rel="noopener">Параметры DNS</a></span>
      <span></span>
    </div>
    <div id="dnsPolicyRows" class="dns-policy-rows">
EOF
  if [ -n "$current" ]; then
    OLDIFS=$IFS
    IFS=','
    for raw in $current; do
      item="$(printf '%s' "$raw" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      [ -z "$item" ] && continue
      case "$item" in *#*) ;; *) continue ;; esac
      matcher="${item%%#*}"
      rest="${item#*#}"
      dns="${rest%%#*}"
      params=""
      [ "$dns" != "$rest" ] && params="${rest#*#}"
      cat <<EOF
      <div class="dns-policy-grid dns-policy-row">
        <input class="dns-policy-match" value="$(printf '%s' "$matcher" | h)" placeholder="+.example.com или rule-set:name">
        <input class="dns-policy-server" value="$(printf '%s' "$dns" | h)" placeholder="https://dns.quad9.net/dns-query">
        <input class="dns-policy-params" value="$(printf '%s' "$params" | h)" placeholder="disable-ipv6=true&disable-qtype-65=true">
        <button type="button" onclick="removeDnsPolicyRow(this)">Удалить</button>
      </div>
EOF
    done
    IFS=$OLDIFS
  fi
  cat <<'EOF'
    </div>
    <small>Для каждой строки обязательно заполнить ресурс и DNS сервер. Третью колонку, параметры DNS, можно оставлять пустой. На выходе собирается NAMESERVER_POLICY в формате matcher#dns#params, строки разделяются запятыми.</small>
  </div>
EOF
}

section_start() {
  title="$1"; text="$2"
  cat <<EOF
<section class="panel">
  <div class="section-head">
    <div>
      <h2>$title</h2>
      <p>$text</p>
    </div>
  </div>
EOF
}

section_end() {
  printf '</section>\n'
}

nav_item() {
  id="$1"; title="$2"; icon="$3"
  class=""
  [ "$page" = "$id" ] && class="active"
  printf '<a class="%s" href="%s"><span>%s</span>%s</a>\n' "$class" "$(page_url "$id")" "$icon" "$title"
}

header() {
  echo "Content-Type: text/html; charset=utf-8"
  echo
  cat <<EOF
<!DOCTYPE html>
<html lang="ru">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <link rel="icon" href="$(asset_url favicon.png)">
  <link rel="stylesheet" href="$(asset_url style.css)">
  <title>Mihomo Proxy ROS</title>
</head>
<body>
<div class="app">
  <aside class="side">
    <a class="brand" href="$(page_url overview)">
      <img src="$(asset_url favicon.png)" alt="">
      <strong>MihomoProxyRoS</strong>
      <small>ENV control panel</small>
    </a>
    <nav>
EOF
  nav_item overview "Обзор" "⌁"
  nav_item core "Ядро и DNS" "⚙"
  nav_item providers "Прокси-провайдеры" "+"
  nav_item dpi "DPI" "◇"
  nav_item groups "Прокси-группы" "☷"
  nav_item rules "Правила маршрутизации" "≡"
  nav_item rulesets "Наборы правил" "▣"
  nav_item yaml "YAML" "{}"
  nav_item tools "Инструменты" "↯"
  cat <<EOF
    </nav>
    <div class="side-note">
      <b>sh-only</b>
      <span>Страницы генерируются shell-скриптом из env. Команды собираются локально в браузере.</span>
    </div>
  </aside>
  <main class="main">
    <header class="top">
      <div>
        <p class="eyebrow">контейнер · $CONTAINER_NAME</p>
        <h1>MihomoProxyRoS</h1>
      </div>
      <div class="top-actions">
        <button class="theme-btn" type="button" onclick="toggleTheme()" aria-label="Toggle theme">
          <span class="theme-dot"></span>
          <b id="themeLabel">Темная</b>
        </button>
        <a class="ghost" href="$(page_url yaml)">Смотреть YAML</a>
        <button class="ghost" type="button" onclick="resetCurrentPageDraft()">Сбросить страницу</button>
        <button class="ghost" type="button" onclick="resetUiDraft()">Сбросить черновик</button>
        <button class="primary" type="button" onclick="generateCommands()">Команды MikroTik</button>
      </div>
    </header>
    <form id="envForm">
EOF
}

footer() {
  cat <<'EOF'
    <div class="bottom-submit">
      <button class="primary" type="button" onclick="generateCommands()">Сгенерировать команды MikroTik</button>
    </div>
    </form>
    <section id="commands" class="command-panel" hidden>
      <div>
        <h2>Команды для MikroTik</h2>
        <p>Генератор сравнивает исходное значение env с тем, что сейчас в форме: новое добавляет, измененное правит, очищенное или удаленное удаляет.</p>
      </div>
      <label class="command-list-field">
        <span>ENV list</span>
        <input id="commandEnvList" value="MihomoProxyRoS" spellcheck="false">
      </label>
      <div class="command-grid">
        <label>
          <span>Текущая страница</span>
          <textarea id="commandsText" readonly spellcheck="false"></textarea>
        </label>
        <label>
          <span>Суммарно по всем измененным env</span>
          <textarea id="commandsAllText" readonly spellcheck="false"></textarea>
        </label>
      </div>
      <div class="command-actions">
        <button class="ghost" type="button" onclick="copyCommands()">Скопировать суммарные</button>
      </div>
    </section>
  </main>
</div>
EOF
  printf '<script src="%s"></script>\n' "$(asset_url ui.js)"
  cat <<'EOF'
<div class="modal" id="ruleSetModal" hidden>
  <div class="modal-backdrop" onclick="closeRuleSetModal()"></div>
  <div class="modal-content">
    <header><b>&#1056;&#1077;&#1076;&#1072;&#1082;&#1090;&#1086;&#1088; rule-set</b><button type="button" onclick="closeRuleSetModal()">&#10005;</button></header>
    <div class="modal-body">
      <label><span>&#1048;&#1084;&#1103; rule-set</span><input id="ruleSetModalName" placeholder="custom"></label>
      <label><span>&#1055;&#1088;&#1072;&#1074;&#1080;&#1083;&#1072; (plain-text)</span><textarea id="ruleSetModalPlain" rows="10" placeholder="DOMAIN,example.com&#10;DOMAIN-SUFFIX,example.org"></textarea></label>
      <div class="rule-set-preview"><b>Preview base64</b><code id="ruleSetModalPreview"></code></div>
    </div>
    <footer class="modal-footer">
      <button type="button" class="primary" onclick="saveRuleSetModal()">&#1055;&#1088;&#1080;&#1084;&#1077;&#1085;&#1080;&#1090;&#1100;</button>
      <button type="button" class="ghost" onclick="closeRuleSetModal()">&#1054;&#1090;&#1084;&#1077;&#1085;&#1072;</button>
    </footer>
  </div>
</div>
</body>
</html>
EOF
}

overview_page() {
  link_count="$(count_env '^LINK[0-9]*=')"
  sub_count="$(count_env '^SUB_LINK[0-9]+=')"
  socks_count="$(count_env '^SOCKS[0-9]+=')"
  group_count="$(env_default GROUP '' | tr ',' '\n' | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
  dpi_count="$(printenv | grep -E '^(BYEDPI_CMD|ZAPRET_CMD|ZAPRET2_CMD)' | wc -l | tr -d ' ')"
  yaml_count="$(active_yaml_files | sort -u | wc -l | tr -d ' ')"
  cat <<EOF
<section class="overview-head">
  <div>
    <p class="eyebrow">состояние контейнера</p>
    <h2>Обзор конфигурации</h2>
    <p>Текущие env сгруппированы так же, как entrypoint собирает mihomo: ядро, источники прокси, DPI-обходы, группы, правила и YAML-файлы.</p>
  </div>
  <div class="config-card">
    <span>основной файл</span>
    <b>config.yaml</b>
    <code>$CONFIG_DIR/config.yaml</code>
    <a href="$(page_url yaml)">Открыть YAML</a>
  </div>
</section>
<section class="stats">
  <a href="$(page_url providers)"><b>$link_count</b><span>LINK</span></a>
  <a href="$(page_url providers)"><b>$sub_count</b><span>SUB_LINK</span></a>
  <a href="$(page_url providers)"><b>$socks_count</b><span>SOCKS</span></a>
  <a href="$(page_url dpi)"><b>$dpi_count</b><span>DPI env</span></a>
  <a href="$(page_url groups)"><b>$group_count</b><span>групп</span></a>
  <a href="$(page_url yaml)"><b>$yaml_count</b><span>YAML</span></a>
</section>
EOF
  section_start "Карта env" "Как entrypoint превращает переменные в mihomo-конфиг."
  cat <<'EOF'
<div class="map">
  <article><b>Ядро</b><span>LOG_LEVEL, UI_SECRET, TPROXY, SNIFFER, DNS_MODE, FAKE_IP_*</span></article>
  <article><b>Прокси-провайдеры</b><span>LINK*, SUB_LINK*, SOCKS*, mounted AWG и proxies_mount</span></article>
  <article><b>DPI</b><span>BYEDPI_CMD*, ZAPRET_CMD*, ZAPRET2_CMD*, packets и WireGuard dst</span></article>
  <article><b>Прокси-группы</b><span>GLOBAL_*, DNS_*, GROUP и переменные вида NAME_GEOSITE/USE/TYPE</span></article>
  <article><b>Правила</b><span>RULES*, RULE_SET*_BASE64 и файлы rule_set_list</span></article>
  <article><b>YAML</b><span>config.yaml плюс все file providers и payload-файлы в CONFIG_DIR</span></article>
</div>
EOF
  section_end
}

core_page() {
  section_start "Ядро mihomo" "Базовые настройки контроллера, UI, inbound-режима и sniffing."
  echo '<div class="grid">'
  select_field LOG_LEVEL "Логи" "Уровень <a class=\"doc-link\" href=\"https://wiki.metacubex.one/ru/config/general/#log-level\" target=\"_blank\" rel=\"noopener\">log-level</a> mihomo." error "silent error warning info debug"
  field EXTERNAL_UI_URL "External UI" "Zip-архив панели для <a class=\"doc-link\" href=\"https://wiki.metacubex.one/ru/config/general/#external-ui-url\" target=\"_blank\" rel=\"noopener\">external-ui-url</a>." "https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip" text "https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip"
  field UI_SECRET "UI secret" "Пароль <a class=\"doc-link\" href=\"https://wiki.metacubex.one/ru/config/general/#secret\" target=\"_blank\" rel=\"noopener\">secret</a> external-controller. Оставьте пустым только в закрытой сети." "" password ""
  field AMNEZIA_PREMIUM_PUBLIC_KEY_FILE "Amnezia public key file" "Файл публичного ключа gateway для vpn:// Amnezia Premium." "/awg" text "/awg"
  toggle_field TPROXY "TPROXY" "true: tproxy TCP/UDP, false: redirect TCP + tun UDP." true
  toggle_field SNIFFER "Sniffer" "В entrypoint хардкод: <a class=\"doc-link\" href=\"https://wiki.metacubex.one/ru/config/sniff/\" target=\"_blank\" rel=\"noopener\">sniffer</a> включается только для роутинга по доменам, без override-destination." true
  echo '</div>'
  section_end

  section_start "DNS и fake-ip" "Параметры, которые попадают в блок dns и fake-ip-filter."
  echo '<div class="grid">'
  select_field DNS_MODE "DNS mode" "mihomo <a class=\"doc-link\" href=\"https://wiki.metacubex.one/ru/config/dns/#enhanced-mode\" target=\"_blank\" rel=\"noopener\">enhanced-mode</a>: fake-ip или redir-host." fake-ip "fake-ip redir-host"
  field FAKE_IP_RANGE "Fake-IP range" "Диапазон <a class=\"doc-link\" href=\"https://wiki.metacubex.one/ru/config/dns/#fake-ip-range\" target=\"_blank\" rel=\"noopener\">fake-ip-range</a>." "198.18.0.0/15" text "198.18.0.0/15"
  field FAKE_IP_TTL "Fake-IP TTL" "TTL записей <a class=\"doc-link\" href=\"https://wiki.metacubex.one/ru/config/dns/#fake-ip-ttl\" target=\"_blank\" rel=\"noopener\">fake-ip</a>." "1" number "1"
  dns_policy_editor
  cat <<'EOF'
</div>
<div class="subhead"><b>FAKE_IP_FILTER*</b><button type="button" onclick="addFakeIpFilterRow()">Добавить</button></div>
<div id="fakeFilters" class="rows">
EOF
  for name in $(env_names '^FAKE_IP_FILTER[0-9]+='); do
    val="$(env_attr "$name" "")"
    idx="$(printf '%s' "$name" | sed 's/FAKE_IP_FILTER//')"
    cat <<EOF
<div class="env-row env-row-stack fake-filter-row" data-index="$idx">
  <label class="env-index"><span>#</span><input type="number" min="1" step="1" value="$idx" aria-label="FAKE_IP_FILTER number"></label>
  <label><span>$name</span><input name="$name" value="$val" placeholder="DOMAIN,www.youtube.com,real-ip"></label>
  <button type="button" onclick="removeEnvRow(this)">Удалить</button>
</div>
EOF
  done
  cat <<'EOF'
</div>
<div class="notice">
  <b>fake-ip-filter-mode: rule</b>
  <span>В контейнере этот режим сейчас задан хардкодом, а последним правилом entrypoint всегда добавляет <code>MATCH,fake-ip</code>. Строки выше идут по номеру env: <code>FAKE_IP_FILTER1</code>, <code>FAKE_IP_FILTER2</code> и так далее.</span>
  <a class="doc-link" href="https://wiki.metacubex.one/ru/config/dns/#fake-ip-filter-mode" target="_blank" rel="noopener">Документация fake-ip-filter-mode</a>
  <a class="doc-link" href="https://wiki.metacubex.one/ru/config/rules/" target="_blank" rel="noopener">Документация rules</a>
</div>
EOF
  section_end
}

providers_page() {
  section_start "Health-check" "Общие настройки проверки доступности для file/http proxy-providers или proxy-groups."
  echo '<div class="grid">'
  toggle_field HEALTHCHECK_PROVIDER "Healthcheck в providers" "true: health-check внутри proxy-providers, false: параметры в proxy-groups." true
  field HEALTHCHECK_INTERVAL "Интервал" "Секунды между проверками, параметр <a class=\"doc-link\" href=\"https://wiki.metacubex.one/ru/config/proxy-providers/#interval\" target=\"_blank\" rel=\"noopener\">interval</a>." "120" number "120"
  field HEALTHCHECK_URL "URL" "URL проверки, параметр <a class=\"doc-link\" href=\"https://wiki.metacubex.one/ru/config/proxy-providers/#health-checkurl\" target=\"_blank\" rel=\"noopener\">url</a>." "https://www.gstatic.com/generate_204" text "https://www.gstatic.com/generate_204"
  field HEALTHCHECK_URL_STATUS "Status" "Ожидаемый HTTP-код ответа, параметр <a class=\"doc-link\" href=\"https://wiki.metacubex.one/ru/config/proxy-providers/#health-checkexpected-status\" target=\"_blank\" rel=\"noopener\">expected-status</a>." "204" number "204"
  field HEALTHCHECK_URL_BYEDPI "BYEDPI URL" "URL проверки через BYEDPI, параметр <a class=\"doc-link\" href=\"https://wiki.metacubex.one/ru/config/proxy-providers/#health-checkurl\" target=\"_blank\" rel=\"noopener\">url</a>." "https://www.facebook.com" text "https://www.facebook.com"
  field HEALTHCHECK_URL_STATUS_BYEDPI "BYEDPI status" "Ожидаемый HTTP-код ответа health-check через BYEDPI, параметр <a class=\"doc-link\" href=\"https://wiki.metacubex.one/ru/config/proxy-providers/#health-checkexpected-status\" target=\"_blank\" rel=\"noopener\">expected-status</a>." "200" number "200"
  field HEALTHCHECK_URL_ZAPRET "ZAPRET URL" "URL проверки через ZAPRET, параметр <a class=\"doc-link\" href=\"https://wiki.metacubex.one/ru/config/proxy-providers/#health-checkurl\" target=\"_blank\" rel=\"noopener\">url</a>." "https://www.facebook.com" text "https://www.facebook.com"
  field HEALTHCHECK_URL_STATUS_ZAPRET "ZAPRET status" "Ожидаемый HTTP-код ответа health-check через ZAPRET, параметр <a class=\"doc-link\" href=\"https://wiki.metacubex.one/ru/config/proxy-providers/#health-checkexpected-status\" target=\"_blank\" rel=\"noopener\">expected-status</a>." "200" number "200"
  echo '</div>'
  section_end

  section_start "LINK*" "Одиночные ссылки: vless/vmess/ss/trojan/base64/vpn://. Для каждого можно задать DIALER_PROXY."
  echo '<div class="subhead"><b>LINK</b><button type="button" onclick="addRow('\''links'\'', '\''LINK'\'', false)">Добавить LINK</button></div><div id="links" class="rows">'
  for name in $(env_names '^LINK[0-9]*='); do
    val="$(env_attr "$name" "")"; idx="$(printf '%s' "$name" | sed 's/LINK//')"; [ -z "$idx" ] && idx=0
    cat <<EOF
<div class="env-row env-row-stack link-row" data-index="$idx">
  <label><span>$name</span><input name="$name" value="$val" placeholder="vless://..."></label>
  <label><span>${name}_DIALER_PROXY</span><input name="${name}_DIALER_PROXY" value="$(env_attr "${name}_DIALER_PROXY" "")" placeholder="GLOBAL"></label>
  <label><span>${name}_AMNEZIA_COUNTRY</span><input name="${name}_AMNEZIA_COUNTRY" value="$(env_attr "${name}_AMNEZIA_COUNTRY" "")" placeholder="nl"></label>
  <button type="button" onclick="removeEnvRow(this)">Удалить</button>
</div>
EOF
  done
  cat <<'EOF'
</div>
<div class="note-list">
  <div><b>SOCKSxx</b><span>ENV остается в контейнере, но в этой панели не редактируется: SOCKS удобнее задавать ссылкой вида <code>socks5://</code> прямо в LINKxx.</span></div>
  <div><b>LINKxx_DIALER_PROXY</b><span>Задает <a class="doc-link" href="https://wiki.metacubex.one/ru/config/proxies/#dialer-proxy" target="_blank" rel="noopener">dialer-proxy</a> для конкретного proxy.</span></div>
  <div><b>LINKxx_AMNEZIA_COUNTRY</b><span>Используется для ссылок <code>vpn://</code> Amnezia Premium: укажите страну, например <code>nl</code>.</span></div>
</div>
EOF
  section_end

  section_start "SUB_LINK*" "HTTP subscriptions: URL, interval, proxy, headers и dialer-proxy."
  field SUB_LINK_INTERVAL "Default interval" "Дефолт для SUB_LINK*_INTERVAL." "3600" number "3600"
  echo '<div class="subhead"><b>SUB_LINK</b><button type="button" onclick="addRow('\''subs'\'', '\''SUB_LINK'\'', true)">Добавить SUB_LINK</button></div><div id="subs" class="rows">'
  for name in $(env_names '^SUB_LINK[0-9]+='); do
    val="$(env_attr "$name" "")"; idx="$(printf '%s' "$name" | sed 's/SUB_LINK//')"
    cat <<EOF
<div class="env-row env-row-stack sub-link-row" data-index="$idx">
  <label><span>$name</span><input name="$name" value="$val" placeholder="https://subscription"></label>
  <label><span>${name}_INTERVAL</span><input name="${name}_INTERVAL" value="$(env_attr "${name}_INTERVAL" "")" placeholder="3600"></label>
  <label><span>${name}_PROXY</span><input name="${name}_PROXY" value="$(env_attr "${name}_PROXY" "")" placeholder="DIRECT"></label>
  <label><span>${name}_DIALER_PROXY</span><input name="${name}_DIALER_PROXY" value="$(env_attr "${name}_DIALER_PROXY" "")" placeholder="GLOBAL"></label>
  <div class="headers-editor">
    <span>${name}_HEADERS</span>
    <input type="hidden" class="sub-link-headers-value" name="${name}_HEADERS" value="$(env_attr "${name}_HEADERS" "")">
    <div class="headers-rows"></div>
    <button type="button" class="headers-add">Добавить header</button>
  </div>
  <button type="button" onclick="removeEnvRow(this)">Удалить</button>
</div>
EOF
  done
  cat <<'EOF'
</div>
<div class="note-list">
  <div><b>SUB_LINKxx_PROXY</b><span>Используется как <a class="doc-link" href="https://wiki.metacubex.one/ru/config/proxy-providers/#proxy" target="_blank" rel="noopener">proxy</a> для загрузки подписки.</span></div>
  <div><b>SUB_LINKxx_DIALER_PROXY</b><span>Прокидывается в <a class="doc-link" href="https://wiki.metacubex.one/ru/config/proxies/#dialer-proxy" target="_blank" rel="noopener">dialer-proxy</a> созданных proxy.</span></div>
  <div><b>SUB_LINKxx_INTERVAL</b><span>Интервал обновления подписки, соответствует provider <a class="doc-link" href="https://wiki.metacubex.one/ru/config/proxy-providers/#interval" target="_blank" rel="noopener">interval</a>.</span></div>
  <div><b>SUB_LINKxx_HEADERS</b><span>HTTP <a class="doc-link" href="https://wiki.metacubex.one/ru/config/proxy-providers/#header" target="_blank" rel="noopener">headers</a>. Редактор собирает env в формат <code>key=value#key2=value2</code>.</span></div>
</div>
EOF
  section_end

  section_start "Mounted providers" "Файлы, которые entrypoint читает из каталогов."
  yaml_url="$(page_url yaml)"
  echo '<div class="mounts">'
  printf '<article><b>AWG configs</b><div class="mount-links" id="awg-mount-links">'
  if [ -d "$AWG_DIR" ]; then
    for f in "$AWG_DIR"/*; do
      [ -f "$f" ] || continue
      base="$(basename "$f")"
      size="$(wc -c < "$f" 2>/dev/null | tr -d ' ')"
      display="${base%.conf}"
      anchor="$(yaml_link_name "$base")"
      printf '<div class="mount-link awg-file" data-file="%s" data-anchor="%s"><a class="mount-link-title" href="%s#%s"><span>%s</span><small>%s bytes</small></a><div class="file-actions"><button type="button" onclick="editAwgFile(this)" title="Редактировать">&#10002;</button><button type="button" onclick="deleteAwgFile(this)" title="Удалить">&#10005;</button></div></div>\n' "$(printf '%s' "$base" | h)" "$(printf '%s' "$anchor" | h)" "$yaml_url" "$(printf '%s' "$anchor" | h)" "$(printf '%s' "$display" | h)" "$size"
    done
  else
    echo '<div class="empty">Каталог AWG не смонтирован.</div>'
  fi
  printf '</div>'
  if [ -d "$AWG_DIR" ]; then
    cat <<'EOF'
<div class="mount-actions">
  <button type="button" class="ghost" onclick="createAwgFile()">Новый файл</button>
  <label class="ghost upload-label" tabindex="0">
    <input type="file" id="awgUpload" accept=".conf" hidden onchange="uploadAwgConf()">
    <span>Загрузить .conf</span>
  </label>
</div>
EOF
  fi
  printf '</article><article><b>proxies_mount</b><div class="mount-links" id="proxy-mount-links">'
  if [ -d "$PROXIES_DIR" ]; then
    for f in "$PROXIES_DIR"/*; do
      [ -f "$f" ] || continue
      base="$(basename "$f")"
      size="$(wc -c < "$f" 2>/dev/null | tr -d ' ')"
      display="${base%.yaml}"
      display="${display%.yml}"
      display="${display%.conf}"
      anchor="$(yaml_link_name "$base")"
      printf '<div class="mount-link proxy-file" data-file="%s" data-anchor="%s"><a class="mount-link-title" href="%s#%s"><span>%s</span><small>%s bytes</small></a><div class="file-actions"><button type="button" onclick="editProxyFile(this)" title="Редактировать">&#10002;</button><button type="button" onclick="deleteProxyFile(this)" title="Удалить">&#10005;</button></div></div>\n' "$(printf '%s' "$base" | h)" "$(printf '%s' "$anchor" | h)" "$yaml_url" "$(printf '%s' "$anchor" | h)" "$(printf '%s' "$display" | h)" "$size"
    done
  else
    echo '<div class="empty">Каталог proxies_mount не смонтирован.</div>'
  fi
  printf '</div>'
  if [ -d "$PROXIES_DIR" ]; then
    cat <<'EOF'
<div class="mount-actions">
  <button type="button" class="ghost" onclick="createProxyFile()">Новый файл</button>
  <label class="ghost upload-label" tabindex="0">
    <input type="file" id="proxyUpload" accept=".yaml,.yml" hidden onchange="uploadProxyYaml()">
    <span>Загрузить .yaml</span>
  </label>
</div>
EOF
  fi
  printf '</article></div>'
  section_end
  cat <<'EOF'
<div class="modal" id="proxyEditModal" hidden>
  <div class="modal-backdrop" onclick="closeProxyFileModal()"></div>
  <div class="modal-content">
    <header><b id="proxyEditTitle">Файл</b><button type="button" onclick="closeProxyFileModal()">&#10005;</button></header>
    <div class="modal-body">
      <label><span>Имя файла</span><input id="proxyEditName" placeholder="new-proxy"></label>
      <div class="template-row" id="proxyTemplateRow">
        <label><span>Шаблон протокола</span>
          <select id="proxyTemplateSelect">
            <option value="">— выберите шаблон —</option>
            <option value="vless-tcp">VLESS + TCP (Reality / Vision)</option>
            <option value="vless-xhttp">VLESS + XHTTP</option>
            <option value="vless-ws">VLESS + WebSocket</option>
            <option value="vmess">VMess + WebSocket</option>
            <option value="trojan">Trojan</option>
            <option value="shadowsocks">Shadowsocks</option>
            <option value="anytls">AnyTLS</option>
            <option value="wireguard">WireGuard</option>
            <option value="amneziawg">AmneziaWG</option>
            <option value="hysteria2">Hysteria2</option>
            <option value="tuic">TUIC</option>
            <option value="ssh">SSH</option>
          </select>
        </label>
        <button type="button" class="ghost" onclick="loadProxyTemplate()">Загрузить шаблон</button>
      </div>
      <label><span>Содержимое (YAML)</span><textarea id="proxyEditPlain" rows="14" placeholder="proxies:"></textarea></label>
      <div id="proxyValidateResult" class="validate-result" hidden></div>
    </div>
    <footer class="modal-footer">
      <button type="button" class="ghost" onclick="closeProxyFileModal()">Отмена</button>
      <button type="button" class="ghost" onclick="validateProxyYaml()">Проверить mihomo&nbsp;-t</button>
      <button type="button" class="primary" onclick="saveProxyFileModal()">Сохранить</button>
    </footer>
  </div>
</div>
<div class="modal" id="awgEditModal" hidden>
  <div class="modal-backdrop" onclick="closeAwgFileModal()"></div>
  <div class="modal-content">
    <header><b id="awgEditTitle">AWG config</b><button type="button" onclick="closeAwgFileModal()">&#10005;</button></header>
    <div class="modal-body">
      <label><span>Имя файла (.conf будет добавлено)</span><input id="awgEditName" placeholder="my-awg"></label>
      <div class="template-row" id="awgTemplateRow">
        <button type="button" class="ghost" onclick="loadAwgTemplate()">Загрузить шаблон [Interface]/[Peer]</button>
      </div>
      <label><span>Содержимое (.conf)</span><textarea id="awgEditPlain" rows="18" placeholder="[Interface]"></textarea></label>
    </div>
    <footer class="modal-footer">
      <button type="button" class="ghost" onclick="closeAwgFileModal()">Отмена</button>
      <button type="button" class="primary" onclick="saveAwgFileModal()">Сохранить</button>
    </footer>
  </div>
</div>
EOF
}

dpi_page() {
  section_start "BYEDPI" "Команды BYEDPI_CMD* создают file provider и отдельные маршруты."
  echo '<div class="subhead"><b>BYEDPI_CMD*</b><button type="button" onclick="addRow('\''byedpi'\'', '\''BYEDPI_CMD'\'', false)">Добавить</button></div><div id="byedpi" class="rows">'
  for name in $(env_names '^BYEDPI_CMD[0-9]*='); do
    idx="$(printf '%s' "$name" | sed 's/BYEDPI_CMD//')"; [ -z "$idx" ] && idx=0
    cat <<EOF
<div class="env-row dpi-single-row" data-index="$idx" data-max-index="99"><label><span>$name</span><input name="$name" value="$(env_attr "$name" "")" placeholder="--transparent ..."></label><button type="button" onclick="removeEnvRow(this)">Удалить</button></div>
EOF
  done
  echo '</div>'
  section_end

  section_start "ZAPRET / ZAPRET2" "nfqws/nfqws2 стратегии и packet-window для обычного DPI обхода."
  echo '<div class="grid">'
  field ZAPRET_PACKETS "ZAPRET packets" "Глобальная переменная: сколько первых пакетов соединения будут проходить очередь ZAPRET. <code>0</code> — все пакеты всегда идут через ZAPRET." "12" number "12"
  field ZAPRET2_PACKETS "ZAPRET2 packets" "Глобальная переменная: сколько первых пакетов соединения будут проходить очередь ZAPRET2. <code>0</code> — все пакеты всегда идут через ZAPRET2." "12" number "12"
  echo '</div>'
  echo '<div class="notice"><b>Packets per strategy</b><span>У каждой стратегии можно отдельно изменить это окно через <code>ZAPRET_PACKETSn</code> или <code>ZAPRET2_PACKETSn</code>. Если поле у строки пустое, используется глобальное значение выше.</span></div>'
  echo '<div class="subhead"><b>ZAPRET_CMD*</b><button type="button" onclick="addRow('\''zapret'\'', '\''ZAPRET_CMD'\'', false)">Добавить</button></div><div id="zapret" class="rows">'
  for name in $(env_names '^ZAPRET_CMD[0-9]*='); do
    idx="$(printf '%s' "$name" | sed 's/ZAPRET_CMD//')"; [ -z "$idx" ] && idx=0
    cat <<EOF
<div class="env-row dpi-packet-row" data-index="$idx" data-max-index="99"><label><span>$name</span><input name="$name" value="$(env_attr "$name" "")" placeholder="--dpi-desync=..."></label><label><span>ZAPRET_PACKETS$idx</span><input name="ZAPRET_PACKETS$idx" value="$(env_attr "ZAPRET_PACKETS$idx" "")" placeholder="12"></label><button type="button" onclick="removeEnvRow(this)">Удалить</button></div>
EOF
  done
  echo '</div><div class="subhead"><b>ZAPRET2_CMD*</b><button type="button" onclick="addRow('\''zapret2'\'', '\''ZAPRET2_CMD'\'', false)">Добавить</button></div><div id="zapret2" class="rows">'
  for name in $(env_names '^ZAPRET2_CMD[0-9]*='); do
    idx="$(printf '%s' "$name" | sed 's/ZAPRET2_CMD//')"; [ -z "$idx" ] && idx=0
    cat <<EOF
<div class="env-row dpi-packet-row" data-index="$idx" data-max-index="99"><label><span>$name</span><input name="$name" value="$(env_attr "$name" "")" placeholder="--dpi-desync=..."></label><label><span>ZAPRET2_PACKETS$idx</span><input name="ZAPRET2_PACKETS$idx" value="$(env_attr "ZAPRET2_PACKETS$idx" "")" placeholder="12"></label><button type="button" onclick="removeEnvRow(this)">Удалить</button></div>
EOF
  done
  echo '</div>'
  section_end

  section_start "ZAPRET2 WG" "Отдельная стратегия для пробития WireGuard handshake через nfqws2."
  cat <<EOF
<div class="wg-editor">
  <label class="field field-wide" data-env="ZAPRET2_WG_CMD">
    <span><b>ZAPRET2 WG cmd</b><em>ZAPRET2_WG_CMD</em></span>
    <textarea name="ZAPRET2_WG_CMD" placeholder="--blob=..." data-default="--blob=quic_vk:@/zapret-fakebin/quic_initial_vk_com.bin --payload wireguard_initiation --lua-desync=fake:blob=quic_vk:repeats=6">$(env_default ZAPRET2_WG_CMD "--blob=quic_vk:@/zapret-fakebin/quic_initial_vk_com.bin --payload wireguard_initiation --lua-desync=fake:blob=quic_vk:repeats=6" | h)</textarea>
    <small>Команда nfqws2 для WireGuard handshake.</small>
    <i>$(is_set ZAPRET2_WG_CMD)</i>
  </label>
  <div class="field field-wide wg-endpoint-editor" data-env="ZAPRET2_WG_DST">
    <span><b>ZAPRET2 WG dst</b><em>ZAPRET2_WG_DST</em></span>
    <input type="hidden" name="ZAPRET2_WG_DST" value="$(env_attr ZAPRET2_WG_DST "")" data-default="">
    <div class="wg-endpoint-rows"></div>
    <button type="button" class="wg-endpoint-add">Добавить endpoint</button>
    <small>Endpoint-ы WireGuard собираются в env через запятую: <code>host:port,host2:port2</code>.</small>
    <i>$(is_set ZAPRET2_WG_DST)</i>
  </div>
  <div class="notice">
    <b>Примечание по MikroTik</b>
    <span>Здесь будет краткая схема заворота только WireGuard handshake в контейнер через отдельный ZAPRET2 provider. Точный пример команд добавим после уточнения правил.</span>
  </div>
</div>
EOF
  section_end

  section_start "Файлы /zapret-fakebin" "Бинарные fake-пакеты для nfqws (--dpi-desync-fake-*). Изменения вступят в силу после перезагрузки контейнера."
  cat <<'EOF'
<div class="dpi-toolbar">
  <input type="search" class="dpi-filter" data-list="fakebin-list" placeholder="Фильтр по имени…" oninput="filterDpiList(this)">
  <label class="ghost upload-label" tabindex="0"><input type="file" id="fakebinUpload" hidden onchange="uploadFakebin()"><span>Загрузить файл</span></label>
</div>
EOF
  echo '<div class="mount-links dpi-grid" id="fakebin-list">'
  if [ -d /zapret-fakebin ]; then
    for f in /zapret-fakebin/*; do
      [ -f "$f" ] || continue
      base="$(basename "$f")"
      size="$(wc -c < "$f" 2>/dev/null | tr -d ' ')"
      printf '<div class="mount-link mount-link-compact fakebin-file" data-file="%s" data-name="%s"><div class="mount-link-title"><span>%s</span><small>%s bytes</small></div><div class="file-actions"><a href="/cgi-bin/read-file?type=fakebin&amp;file=%s" download="%s" title="Скачать">&#8681;</a><button type="button" onclick="deleteFakebin(this)" title="Удалить">&#10005;</button></div></div>\n' "$(printf '%s' "$base" | h)" "$(printf '%s' "$base" | h | tr 'A-Z' 'a-z')" "$(printf '%s' "$base" | h)" "$size" "$(printf '%s' "$base" | h)" "$(printf '%s' "$base" | h)"
    done
  else
    echo '<div class="empty">Каталог /zapret-fakebin не смонтирован.</div>'
  fi
  echo '</div>'
  section_end

  section_start "Файлы /zapret-lists" "Текстовые списки доменов/IP для nfqws и lua-скриптов. Редактируются прямо в браузере."
  echo '<div class="dpi-toolbar">'
  echo '  <input type="search" class="dpi-filter" data-list="zlist-list" placeholder="Фильтр по имени…" oninput="filterDpiList(this)">'
  if [ -d /zapret-lists ]; then
    echo '  <button type="button" class="ghost" onclick="createZlistFile()">Новый список</button>'
  fi
  echo '</div>'
  echo '<div class="mount-links dpi-grid" id="zlist-list">'
  if [ -d /zapret-lists ]; then
    for f in /zapret-lists/*; do
      [ -f "$f" ] || continue
      base="$(basename "$f")"
      size="$(wc -c < "$f" 2>/dev/null | tr -d ' ')"
      printf '<div class="mount-link mount-link-compact zlist-file" data-file="%s" data-name="%s"><div class="mount-link-title"><span>%s</span><small>%s bytes</small></div><div class="file-actions"><button type="button" onclick="editZlistFile(this)" title="Редактировать">&#10002;</button><button type="button" onclick="deleteZlistFile(this)" title="Удалить">&#10005;</button></div></div>\n' "$(printf '%s' "$base" | h)" "$(printf '%s' "$base" | h | tr 'A-Z' 'a-z')" "$(printf '%s' "$base" | h)" "$size"
    done
  else
    echo '<div class="empty">Каталог /zapret-lists не смонтирован.</div>'
  fi
  echo '</div>'
  section_end

  cat <<'EOF'
<div class="modal" id="zlistEditModal" hidden>
  <div class="modal-backdrop" onclick="closeZlistFileModal()"></div>
  <div class="modal-content">
    <header><b id="zlistEditTitle">Список</b><button type="button" onclick="closeZlistFileModal()">&#10005;</button></header>
    <div class="modal-body">
      <label><span>Имя файла</span><input id="zlistEditName" placeholder="my-list.txt"></label>
      <label><span>Содержимое (по строке на запись)</span><textarea id="zlistEditPlain" rows="18" placeholder="example.com&#10;example.org"></textarea></label>
    </div>
    <footer class="modal-footer">
      <button type="button" class="ghost" onclick="closeZlistFileModal()">Отмена</button>
      <button type="button" class="primary" onclick="saveZlistFileModal()">Сохранить</button>
    </footer>
  </div>
</div>
EOF
}

default_group_block() {
  cat <<'EOF'
<article class="group-pane" data-group="DEFAULT" data-prefix="GROUP" hidden>
  <div class="group-pane-head">
    <div class="notice">
      <b>DEFAULT</b>
      <span>Эти значения используются для GLOBAL и пользовательских групп, если у них нет собственного env. ENV <code>GROUP</code> скрыт и собирается автоматически из списка групп слева, кроме DEFAULT, GLOBAL и DNS.</span>
    </div>
  </div>
  <div class="grid">
EOF
  printf '<input type="hidden" name="GROUP" value="%s" data-default="">\n' "$(env_attr GROUP "")"
  select_field GROUP_TYPE "GROUP_TYPE" "Тип <a class=\"doc-link\" href=\"https://wiki.metacubex.one/ru/config/proxy-groups/#type\" target=\"_blank\" rel=\"noopener\">proxy-groups type</a> по умолчанию." select "select url-test load-balance fallback relay"
  field GROUP_USE "GROUP_USE" "providers по умолчанию, параметр <a class=\"doc-link\" href=\"https://wiki.metacubex.one/ru/config/proxy-groups/#use\" target=\"_blank\" rel=\"noopener\">use</a>, или none." "" text ""
  field GROUP_PROXIES "GROUP_PROXIES" "Явные <a class=\"doc-link\" href=\"https://wiki.metacubex.one/ru/config/proxy-groups/#proxies\" target=\"_blank\" rel=\"noopener\">proxies</a> по умолчанию." "" text ""
  field GROUP_FILTER "GROUP_FILTER" "Regex <a class=\"doc-link\" href=\"https://wiki.metacubex.one/ru/config/proxy-groups/#filter\" target=\"_blank\" rel=\"noopener\">filter</a> по умолчанию." "" text ""
  field GROUP_EXCLUDE "GROUP_EXCLUDE" "Regex <a class=\"doc-link\" href=\"https://wiki.metacubex.one/ru/config/proxy-groups/#exclude-filter\" target=\"_blank\" rel=\"noopener\">exclude-filter</a> по умолчанию." "" text ""
  field GROUP_URL "GROUP_URL" "URL <a class=\"doc-link\" href=\"https://wiki.metacubex.one/ru/config/proxy-groups/#url\" target=\"_blank\" rel=\"noopener\">health-check</a>, если HEALTHCHECK_PROVIDER=false." "https://www.gstatic.com/generate_204" text "https://www.gstatic.com/generate_204"
  field GROUP_URL_STATUS "GROUP_URL_STATUS" "Ожидаемый <a class=\"doc-link\" href=\"https://wiki.metacubex.one/ru/config/proxy-groups/#expected-status\" target=\"_blank\" rel=\"noopener\">expected-status</a>." "204" number "204"
  field GROUP_INTERVAL "GROUP_INTERVAL" "Интервал <a class=\"doc-link\" href=\"https://wiki.metacubex.one/ru/config/proxy-groups/#interval\" target=\"_blank\" rel=\"noopener\">health-check</a>." "60" number "60"
  field GROUP_TOLERANCE "GROUP_TOLERANCE" "<a class=\"doc-link\" href=\"https://wiki.metacubex.one/ru/config/proxy-groups/#tolerance\" target=\"_blank\" rel=\"noopener\">Tolerance</a> для url-test." "20" number "20"
  select_field GROUP_STRATEGY "GROUP_STRATEGY" "Стратегия <a class=\"doc-link\" href=\"https://wiki.metacubex.one/ru/config/proxy-groups/#strategy\" target=\"_blank\" rel=\"noopener\">load-balance</a>: round-robin, consistent-hashing или sticky-sessions." "consistent-hashing" "round-robin consistent-hashing sticky-sessions"
  echo '</div></article>'
}

group_block() {
  prefix="$1"; title="$2"; source="${3:-group}"; source_kind="${4:-}"; source_ref="${5:-}"
  readonly=""
  delete_button='<button class="group-delete" type="button" onclick="removeGroupPane(this.parentElement.parentElement.dataset.group)">Удалить группу</button>'
  source_note="Имя группы и prefix env. GLOBAL и DNS фиксированы entrypoint."
  source_attrs='data-source="group"'
  case "$title" in GLOBAL|DNS) readonly=" readonly"; delete_button="" ;; esac
  if [ "$source" = "ruleset" ]; then
    readonly=" readonly"
    delete_button=""
    source_note="Группа создана из RULE_SET*_BASE64 или файла rule_set_list. Переименование и удаление связаны с исходным rule-set."
    source_attrs="data-source=\"ruleset\" data-source-kind=\"$(printf '%s' "$source_kind" | h)\" data-source-ref=\"$(printf '%s' "$source_ref" | h)\""
    [ "$source_kind" = "base64" ] && source_attrs="$source_attrs data-source-env=\"$(printf '%s' "$source_ref" | h)\""
  fi
  cat <<EOF
<article class="group-pane" data-group="$(printf '%s' "$title" | h)" data-prefix="$prefix" $source_attrs hidden>
  <div class="group-pane-head">
    $delete_button
    <label class="field">
      <span><b>Group name</b><em>GROUP</em></span>
      <input class="group-name-input" value="$(printf '%s' "$title" | h)" data-original="$(printf '%s' "$title" | h)"$readonly>
      <small>$source_note</small>
      <i>$prefix</i>
    </label>
  </div>
  <div class="grid">
EOF
  select_field "${prefix}_TYPE" "Type" "Тип <a class=\"doc-link\" href=\"https://wiki.metacubex.one/ru/config/proxy-groups/#type\" target=\"_blank\" rel=\"noopener\">proxy-groups type</a>." "$( [ "$prefix" = DNS ] && echo select || echo "$(env_default GROUP_TYPE select)" )" "select url-test load-balance fallback relay"
  field "${prefix}_USE" "Use" "Список <a class=\"doc-link\" href=\"https://wiki.metacubex.one/ru/config/proxy-groups/#use\" target=\"_blank\" rel=\"noopener\">providers</a> через запятую или none." "" text ""
  field "${prefix}_PROXIES" "Proxies" "Явные <a class=\"doc-link\" href=\"https://wiki.metacubex.one/ru/config/proxy-groups/#proxies\" target=\"_blank\" rel=\"noopener\">proxies</a> через запятую." "" text ""
  field "${prefix}_FILTER" "Filter" "Regex <a class=\"doc-link\" href=\"https://wiki.metacubex.one/ru/config/proxy-groups/#filter\" target=\"_blank\" rel=\"noopener\">filter</a> по именам прокси." "" text ""
  field "${prefix}_EXCLUDE" "Exclude" "Regex <a class=\"doc-link\" href=\"https://wiki.metacubex.one/ru/config/proxy-groups/#exclude-filter\" target=\"_blank\" rel=\"noopener\">exclude-filter</a>." "" text ""
  field "${prefix}_PRIORITY" "Priority" "Чем меньше, тем выше в rules." "" number ""
  field "${prefix}_GEOSITE" "Geosite" "Правила <a class=\"doc-link\" href=\"https://wiki.metacubex.one/ru/config/rules/\" target=\"_blank\" rel=\"noopener\">GEOSITE</a> списком через запятую." "youtube,category-ru" text ""
  field "${prefix}_GEOIP" "Geoip" "Правила <a class=\"doc-link\" href=\"https://wiki.metacubex.one/ru/config/rules/\" target=\"_blank\" rel=\"noopener\">GEOIP</a> списком через запятую." "telegram,discord" text ""
  field "${prefix}_AS" "ASN" "Правила <a class=\"doc-link\" href=\"https://wiki.metacubex.one/ru/config/rules/\" target=\"_blank\" rel=\"noopener\">IP-ASN</a>: AS123,AS456." "AS15169" text ""
  field "${prefix}_DOMAIN" "Domain" "Правила <a class=\"doc-link\" href=\"https://wiki.metacubex.one/ru/config/rules/\" target=\"_blank\" rel=\"noopener\">DOMAIN</a> через запятую." "example.com" text ""
  field "${prefix}_SUFFIX" "Suffix" "Правила <a class=\"doc-link\" href=\"https://wiki.metacubex.one/ru/config/rules/\" target=\"_blank\" rel=\"noopener\">DOMAIN-SUFFIX</a> через запятую." "example.com" text ""
  field "${prefix}_KEYWORD" "Keyword" "Правила <a class=\"doc-link\" href=\"https://wiki.metacubex.one/ru/config/rules/\" target=\"_blank\" rel=\"noopener\">DOMAIN-KEYWORD</a> через запятую." "google" text ""
  field "${prefix}_IPCIDR" "IP CIDR" "Правила <a class=\"doc-link\" href=\"https://wiki.metacubex.one/ru/config/rules/\" target=\"_blank\" rel=\"noopener\">IP-CIDR</a> через запятую." "1.1.1.0/24" text ""
  field "${prefix}_SRCIPCIDR" "Source CIDR" "Правила <a class=\"doc-link\" href=\"https://wiki.metacubex.one/ru/config/rules/\" target=\"_blank\" rel=\"noopener\">SRC-IP-CIDR</a> через запятую." "192.168.88.0/24" text ""
  field "${prefix}_DSCP" "DSCP" "Правило <a class=\"doc-link\" href=\"https://wiki.metacubex.one/ru/config/rules/\" target=\"_blank\" rel=\"noopener\">DSCP</a> для отдельного входа." "" number ""
  field "${prefix}_DNS" "DNS policy" "DNS resolver для rule-set этой группы." "https://dns.google/dns-query" text ""
  echo '</div></article>'
}

groups_page() {
  section_start "Прокси-группы" "Выберите группу слева, чтобы редактировать только ее параметры."
  echo '<div class="groups-browser"><aside id="groupList" class="group-list">'
  echo '<button type="button" data-group="DEFAULT" onclick="switchGroupPane(this.dataset.group)"><b>DEFAULT</b><small>GROUP_*</small></button>'
  echo '<button type="button" data-group="GLOBAL" onclick="switchGroupPane(this.dataset.group)"><b>GLOBAL</b><small>GLOBAL_*</small></button>'
  echo '<button type="button" data-group="DNS" onclick="switchGroupPane(this.dataset.group)"><b>DNS</b><small>DNS_*</small></button>'
  group_seen=" DEFAULT GLOBAL DNS "
  for g in $(env_default GROUP "" | tr ',' ' '); do
    clean="$(printf '%s' "$g" | xargs)"
    [ -z "$clean" ] && continue
    case " $group_seen " in *" $clean "*) continue ;; esac
    group_seen="$group_seen $clean "
    envp="$(group_env_prefix "$clean")"
    printf '<button type="button" data-group="%s" onclick="switchGroupPane(this.dataset.group)"><b>%s</b><small>%s_*</small></button>\n' "$(printf '%s' "$clean" | h)" "$(printf '%s' "$clean" | h)" "$envp"
  done
  custom_rule_group_records | while IFS='|' read -r clean kind ref; do
    [ -z "$clean" ] && continue
    case " $group_seen " in *" $clean "*) continue ;; esac
    group_seen="$group_seen $clean "
    envp="$(group_env_prefix "$clean")"
    printf '<button type="button" data-group="%s" data-source="ruleset" onclick="switchGroupPane(this.dataset.group)"><b>%s</b><small>rule-set · %s_*</small></button>\n' "$(printf '%s' "$clean" | h)" "$(printf '%s' "$clean" | h)" "$envp"
  done
  echo '<button class="add-group-btn" type="button" onclick="addGroupPane()">Добавить группу</button>'
  echo '</aside><div id="groupPanes" class="group-panes">'
  default_group_block
  group_block GLOBAL "GLOBAL"
  group_block DNS "DNS"
  group_seen=" DEFAULT GLOBAL DNS "
  for g in $(env_default GROUP "" | tr ',' ' '); do
    clean="$(printf '%s' "$g" | xargs)"
    [ -z "$clean" ] && continue
    case " $group_seen " in *" $clean "*) continue ;; esac
    group_seen="$group_seen $clean "
    envp="$(group_env_prefix "$clean")"
    group_block "$envp" "$clean"
  done
  custom_rule_group_records | while IFS='|' read -r clean kind ref; do
    [ -z "$clean" ] && continue
    case " $group_seen " in *" $clean "*) continue ;; esac
    group_seen="$group_seen $clean "
    envp="$(group_env_prefix "$clean")"
    group_block "$envp" "$clean" ruleset "$kind" "$ref"
  done
  echo '</div></div>'
  section_end
}

rules_page() {
  section_start "Правила маршрутизации" "Общий динамический список по логике entrypoint: generated-правила read-only, RULESxx редактируются прямо внутри списка."
  echo '<textarea id="rulesPreviewEnv" hidden>'
  for name in $(env_names '^(GROUP|RULES[0-9]+|RULE_SET[0-9]+_BASE64|[A-Z0-9_]+_(PRIORITY|GEOSITE|GEOIP|AS|DOMAIN|SUFFIX|IPCIDR|KEYWORD|SRCIPCIDR|DSCP|USE))='); do
    printf '%s=%s\n' "$name" "$(env_raw "$name" | h)"
  done
  echo '</textarea><textarea id="rulesPreviewMounts" hidden>'
  if [ -d "$RULE_SET_DIR" ]; then
    for f in "$RULE_SET_DIR"/*; do
      [ -f "$f" ] || continue
      raw="$(basename "$f")"
      sanitize_rule_group_name "${raw%.*}" | h
      printf '\n'
    done
  fi
  echo '</textarea>'
  echo '<div class="subhead"><b>RULESxx</b><button type="button" onclick="addPreviewRule()">Добавить RULES</button></div><div id="rules" class="rows">'
  for name in $(env_names '^RULES[0-9]+='); do
    idx="$(printf '%s' "$name" | sed 's/RULES//')"
    val="$(env_attr "$name" "")"
    cat <<EOF
<div class="env-row rule-row" data-index="$idx"><label><span>$name</span><input name="$name" value="$val" placeholder="DOMAIN,example.com,GLOBAL"></label><button type="button" onclick="removeEnvRow(this)">Удалить</button></div>
EOF
  done
  echo '</div>'
  echo '<div class="subhead"><b>Итоговый rules из YAML</b></div>'
  echo '<div id="finalRulesPreview" class="final-rules"><div class="empty">Предпросмотр собирается в браузере из env и черновика.</div></div>'
  echo '<div class="note-list"><div><b>RULESxx</b><span>Редактируются отдельно сверху. Generated-строки показывают итог от GROUP/RULE_SET/маунтов и не редактируются здесь.</span></div></div>'
  section_end
}

rulesets_page() {
  section_start "Наборы правил" "RULE_SET*: глобальные rule-set env и файлы из каталога rule_set_list."
  echo '<div class="subhead"><b>RULE_SET*_BASE64</b><button type="button" onclick="addRow('\''rulesets'\'', '\''RULE_SET'\'', true)">Добавить RULE_SET</button></div><div id="rulesets" class="rows">'
  for name in $(env_names '^RULE_SET[0-9]+_BASE64='); do
    idx="$(printf '%s' "$name" | sed 's/RULE_SET//; s/_BASE64//')"
    cat <<EOF
<div class="env-row rule-row" data-index="$idx"><label><span>$name</span><input name="$name" value="$(env_attr "$name" "")" placeholder="BASE64#name"></label><button type="button" onclick="openRuleSetModal(this)" title="Редактировать">&#10002;</button><button type="button" onclick="removeEnvRow(this)">Удалить</button></div>
EOF
  done
  echo '</div><div class="note-list"><div><b>RULE_SETxx_BASE64</b><span>Base64 rule-provider: значение декодируется entrypoint в rule-set файл. Используется вместе с <a class="doc-link" href="https://wiki.metacubex.one/ru/config/rule-providers/" target="_blank" rel="noopener">rule-providers</a> и <a class="doc-link" href="https://wiki.metacubex.one/ru/config/rules/" target="_blank" rel="noopener">RULE-SET</a> правилами.</span></div></div><div class="mounts" style="margin-top:24px; grid-template-columns:1fr"><article><b>RULE-SET Mounts</b><div class="mount-links rule-set-grid">'
  if [ -d "$RULE_SET_DIR" ]; then
    for f in "$RULE_SET_DIR"/*; do
      [ -f "$f" ] || continue
      base="$(basename "$f")"
      size="$(wc -c < "$f" 2>/dev/null | tr -d ' ')"
      display="${base%.txt}"
      printf '<div class="mount-link rule-set-file" data-file="%s"><span>%s</span><small>%s bytes</small><div class="file-actions"><button type="button" onclick="editRuleSetFile(this)" title="Редактировать">&#10002;</button><button type="button" onclick="deleteRuleSetFile(this)" title="Удалить">&#10005;</button></div></div>\n' "$(printf '%s' "$base" | h)" "$(printf '%s' "$display" | h)" "$size"
    done
  else
    echo '<div class="empty">Каталог rule_set_list не смонтирован.</div>'
  fi
  echo '</div>'
  if [ -d "$RULE_SET_DIR" ]; then
    echo '<button type="button" class="ghost" style="margin-top:8px; width:100%" onclick="createRuleSetFile()">Новый файл</button>'
  fi
  echo '</article></div>'
  cat <<'EOF'
<div class="modal" id="fileEditModal" hidden>
  <div class="modal-backdrop" onclick="closeFileEditModal()"></div>
  <div class="modal-content">
    <header><b id="fileEditTitle">Файл</b><button type="button" onclick="closeFileEditModal()">&#10005;</button></header>
    <div class="modal-body">
      <label><span>Имя файла</span><input id="fileEditName" placeholder="new-rules"></label>
      <label><span>Содержимое</span><textarea id="fileEditPlain" rows="12" placeholder="DOMAIN,example.com&#10;DOMAIN-SUFFIX,example.org"></textarea></label>
    </div>
    <footer class="modal-footer">
      <button type="button" class="ghost" onclick="closeFileEditModal()">Отмена</button>
      <button type="button" class="primary" onclick="saveFileEditModal()">Сохранить</button>
    </footer>
  </div>
</div>
EOF
  section_end
}

yaml_page() {
  section_start "Просмотр YAML и подключенных файлов" "Показывает основной config.yaml и только файлы, которые участвуют в текущей сборке."
  echo '<div class="yaml-browser"><div class="file-list">'
  yaml_list="/tmp/mihomo-yaml-files.$$"
  active_yaml_files | awk '!seen[$0]++' > "$yaml_list"
  seen_files=""
  if [ ! -s "$yaml_list" ]; then
    echo '<div class="empty">Файлы еще не созданы. После старта entrypoint они появятся в /root/.config/mihomo.</div>'
  fi
  while IFS= read -r file; do
    [ -f "$file" ] || continue
    base="$(basename "$file")"
    case "$base" in *.txt) continue ;; esac
    case " $seen_files " in *" $base "*) continue ;; esac
    seen_files="$seen_files $base"
    size="$(wc -c < "$file" 2>/dev/null | tr -d ' ')"
    printf '<button type="button" data-name="%s" onclick="switchYaml(this.dataset.name)"><b>%s</b><small>%s bytes</small></button>\n' "$(printf '%s' "$base" | h)" "$(printf '%s' "$base" | h)" "$size"
  done < "$yaml_list"
  echo '</div><div class="yaml-view">'
  seen_files=""
  while IFS= read -r file; do
    [ -f "$file" ] || continue
    base="$(basename "$file")"
    case "$base" in *.txt) continue ;; esac
    case " $seen_files " in *" $base "*) continue ;; esac
    seen_files="$seen_files $base"
    cat <<EOF
<article class="yaml-file" data-name="$(printf '%s' "$base" | h)" hidden>
  <header><b>$(printf '%s' "$base" | h)</b><span>$(printf '%s' "$file" | h)</span><button class="copy-yaml" type="button" onclick="copyActiveYaml(this)">Скопировать</button></header>
  <pre tabindex="0" onclick="activeYamlPre=this; this.focus()">$(sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' "$file" 2>/dev/null)</pre>
</article>
EOF
  done < "$yaml_list"
  rm -f "$yaml_list"
  echo '</div></div>'
  section_end
}

tools_page() {
  section_start "Черновик инструментов" "Страница оставлена как расширяемая зона для конверторов и быстрых генераторов."
  cat <<'EOF'
<div class="tools">
  <article>
    <h3>Base64 rule-set</h3>
    <textarea id="plainRules" placeholder="DOMAIN,example.com&#10;DOMAIN-SUFFIX,example.org"></textarea>
    <input id="rulesName" placeholder="name">
    <button type="button" onclick="document.getElementById('b64Rules').value=btoa(unescape(encodeURIComponent(document.getElementById('plainRules').value)))+'#'+(document.getElementById('rulesName').value||'custom')">Собрать RULE_SET*_BASE64</button>
    <textarea id="b64Rules" readonly></textarea>
  </article>
  <article>
    <h3>RouterOS value escape</h3>
    <textarea id="rawValue" placeholder="Любое значение env"></textarea>
    <button type="button" onclick="document.getElementById('escapedValue').value='&quot;'+mtEscape(document.getElementById('rawValue').value)+'&quot;'">Экранировать</button>
    <textarea id="escapedValue" readonly></textarea>
  </article>
</div>
EOF
  section_end
}

header
case "$page" in
  overview) overview_page ;;
  core) core_page ;;
  providers) providers_page ;;
  dpi) dpi_page ;;
  groups) groups_page ;;
  rules) rules_page ;;
  rulesets) rulesets_page ;;
  yaml) yaml_page ;;
  tools) tools_page ;;
  *) overview_page ;;
esac
footer
