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

# Begin a section that is also a tab panel.
# Args: $1=tab-id (matches data-tab in the page-tabs nav), $2=title, $3=description.
section_start_tab() {
  tab_id="$1"; title="$2"; text="$3"
  cat <<EOF
<section class="panel tab-panel" data-tab="$tab_id" hidden>
  <div class="section-head">
    <div>
      <h2>$title</h2>
      <p>$text</p>
    </div>
  </div>
EOF
}

# Render the sticky tab navigation at the top of a tabbed page.
# Args: pairs of "tab-id" "Label", repeated. Example:
#   page_tabs_nav health "Health-check" link "LINK" sub-link "SUB_LINK"
page_tabs_nav() {
  printf '<nav class="page-tabs" role="tablist" aria-label="Разделы страницы">'
  while [ "$#" -ge 2 ]; do
    tid="$1"; tlabel="$2"; shift 2
    printf '<button type="button" class="page-tab" data-tab="%s" role="tab" aria-selected="false">'\
'<span class="page-tab-label">%s</span>'\
'<span class="badge badge-changed" data-kind="changed" hidden></span>'\
'<span class="badge badge-error"   data-kind="error"   hidden></span>'\
'</button>' \
      "$(printf '%s' "$tid" | h)" "$(printf '%s' "$tlabel" | h)"
  done
  printf '</nav>\n'
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
  <script>(function(){try{var t=localStorage.getItem("mihomo-theme")||"dark";document.documentElement.setAttribute("data-theme",t);}catch(e){document.documentElement.setAttribute("data-theme","dark");}})();</script>
  <link rel="icon" href="$(asset_url favicon.png)">
  <link rel="stylesheet" href="$(asset_url style.css)">
  <script src="$(asset_url ui.js)" defer></script>
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
  page_tabs_nav \
    core "Ядро" \
    dns  "DNS"
  section_start_tab core "Ядро mihomo" "Базовые настройки контроллера, UI, inbound-режима и sniffing."
  echo '<div class="grid">'
  select_field LOG_LEVEL "Логи" "Уровень <a class=\"doc-link\" href=\"https://wiki.metacubex.one/ru/config/general/#log-level\" target=\"_blank\" rel=\"noopener\">log-level</a> mihomo." error "silent error warning info debug"
  field EXTERNAL_UI_URL "External UI" "Zip-архив панели для <a class=\"doc-link\" href=\"https://wiki.metacubex.one/ru/config/general/#external-ui-url\" target=\"_blank\" rel=\"noopener\">external-ui-url</a>." "https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip" text "https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip"
  field UI_SECRET "UI secret" "Пароль <a class=\"doc-link\" href=\"https://wiki.metacubex.one/ru/config/general/#secret\" target=\"_blank\" rel=\"noopener\">secret</a> external-controller. Оставьте пустым только в закрытой сети." "" password ""
  field AMNEZIA_PREMIUM_PUBLIC_KEY_FILE "Amnezia public key file" "Файл публичного ключа gateway для vpn:// Amnezia Premium." "/awg" text "/awg"
  toggle_field TPROXY "TPROXY" "true: tproxy TCP/UDP, false: redirect TCP + tun UDP." true
  toggle_field SNIFFER "Sniffer" "В entrypoint хардкод: <a class=\"doc-link\" href=\"https://wiki.metacubex.one/ru/config/sniff/\" target=\"_blank\" rel=\"noopener\">sniffer</a> включается только для роутинга по доменам, без override-destination." true
  echo '</div>'
  section_end

  section_start_tab dns "DNS и fake-ip" "Параметры, которые попадают в блок dns и fake-ip-filter."
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
  page_tabs_nav \
    health    "Health-check" \
    link      "LINK*" \
    sub-link  "SUB_LINK*" \
    socks     "SOCKS*" \
    mounted   "Mounted"
  section_start_tab health "Health-check" "Общие настройки проверки доступности для file/http proxy-providers или proxy-groups."
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

  section_start_tab link "LINK*" "Одиночные ссылки: vless/vmess/ss/trojan/base64/vpn://. Для каждого можно задать DIALER_PROXY."
  echo '<div class="subhead"><b>LINK</b><button type="button" onclick="addRow('\''links'\'', '\''LINK'\'', false)">Добавить LINK</button></div><div id="links" class="rows">'
  for name in $(env_names '^LINK[0-9]*='); do
    val="$(env_attr "$name" "")"; idx="$(printf '%s' "$name" | sed 's/LINK//')"; [ -z "$idx" ] && idx=0
    cat <<EOF
<div class="env-row env-row-stack link-row" data-index="$idx">
  <label><span>$name</span><input name="$name" value="$val" placeholder="vless://..."></label>
  <label class="field-validated" data-validate="proxy_name"><span>${name}_DIALER_PROXY</span><input name="${name}_DIALER_PROXY" value="$(env_attr "${name}_DIALER_PROXY" "")" placeholder="GLOBAL"></label>
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

  section_start_tab sub-link "SUB_LINK*" "HTTP subscriptions: URL, interval, proxy, headers и dialer-proxy."
  field SUB_LINK_INTERVAL "Default interval" "Дефолт для SUB_LINK*_INTERVAL." "3600" number "3600"
  echo '<div class="subhead"><b>SUB_LINK</b><button type="button" onclick="addRow('\''subs'\'', '\''SUB_LINK'\'', false)">Добавить SUB_LINK</button></div><div id="subs" class="rows">'
  for name in $(env_names '^SUB_LINK[0-9]+='); do
    val="$(env_attr "$name" "")"; idx="$(printf '%s' "$name" | sed 's/SUB_LINK//')"
    cat <<EOF
<div class="env-row env-row-stack sub-link-row" data-index="$idx">
  <label><span>$name</span><input name="$name" value="$val" placeholder="https://subscription"></label>
  <label><span>${name}_INTERVAL</span><input type="number" name="${name}_INTERVAL" value="$(env_attr "${name}_INTERVAL" "")" placeholder="3600"></label>
  <label><span>${name}_PROXY</span><input name="${name}_PROXY" value="$(env_attr "${name}_PROXY" "")" placeholder="DIRECT"></label>
  <label class="field-validated" data-validate="proxy_name"><span>${name}_DIALER_PROXY</span><input name="${name}_DIALER_PROXY" value="$(env_attr "${name}_DIALER_PROXY" "")" placeholder="GLOBAL"></label>
  <div class="sub-link-extras">
    <label><span>${name}_FILTER</span><input name="${name}_FILTER" value="$(env_attr "${name}_FILTER" "")" placeholder="(?i)hk|hongkong"></label>
    <label><span>${name}_EXCLUDE_FILTER</span><input name="${name}_EXCLUDE_FILTER" value="$(env_attr "${name}_EXCLUDE_FILTER" "")" placeholder="(?i)test"></label>
    <label class="field-validated" data-validate="exclude_type"><span>${name}_EXCLUDE_TYPE</span><input name="${name}_EXCLUDE_TYPE" value="$(env_attr "${name}_EXCLUDE_TYPE" "")" placeholder="vmess|direct"></label>
    <label><span>${name}_ADDITIONAL_PREFIX</span><input name="${name}_ADDITIONAL_PREFIX" value="$(env_attr "${name}_ADDITIONAL_PREFIX" "")" placeholder="${name} | "></label>
    <label><span>${name}_ADDITIONAL_SUFFIX</span><input name="${name}_ADDITIONAL_SUFFIX" value="$(env_attr "${name}_ADDITIONAL_SUFFIX" "")" placeholder=" | ${name}"></label>
  </div>
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
  <div><b>SUB_LINKxx_FILTER</b><span>Provider-level <a class="doc-link" href="https://wiki.metacubex.one/ru/config/proxy-providers/#filter" target="_blank" rel="noopener">filter</a> — regex по именам узлов внутри подписки, несколько через <code>|</code>.</span></div>
  <div><b>SUB_LINKxx_EXCLUDE_FILTER</b><span>Provider-level <a class="doc-link" href="https://wiki.metacubex.one/ru/config/proxy-providers/#exclude-filter" target="_blank" rel="noopener">exclude-filter</a> — regex исключения.</span></div>
  <div><b>SUB_LINKxx_EXCLUDE_TYPE</b><span>Provider-level <a class="doc-link" href="https://wiki.metacubex.one/ru/config/proxy-providers/#exclude-type" target="_blank" rel="noopener">exclude-type</a> — список <a class="doc-link" href="https://github.com/MetaCubeX/mihomo/blob/fbead56ec97ae93f904f4476df1741af718c9c2a/constant/adapters.go#L18-L45" target="_blank" rel="noopener">Adapter Type</a>'ов через <code>|</code>, регистр не важен.</span></div>
  <div><b>SUB_LINKxx_ADDITIONAL_PREFIX</b><span>Идёт в <a class="doc-link" href="https://wiki.metacubex.one/ru/config/proxy-providers/#overrideadditional-prefix" target="_blank" rel="noopener">override.additional-prefix</a> — фиксированный префикс к имени каждого узла.</span></div>
  <div><b>SUB_LINKxx_ADDITIONAL_SUFFIX</b><span>Идёт в <a class="doc-link" href="https://wiki.metacubex.one/ru/config/proxy-providers/#overrideadditional-suffix" target="_blank" rel="noopener">override.additional-suffix</a> — фиксированный суффикс к имени каждого узла.</span></div>
</div>
EOF
  section_end

  section_start_tab socks "SOCKS*" "SOCKS5-провайдеры. Для каждого SOCKS&lt;N&gt; собирается отдельный proxy-provider. Удобнее использовать <code>LINK*</code> с URL вида <code>socks5://user:pass@host:port</code> — формат универсальнее. Этот блок оставлен для совместимости и тонкой настройки полей."
  echo '<div class="subhead"><b>SOCKS*</b><button type="button" onclick="addSocksRow()">Добавить SOCKS</button></div>'
  echo '<div id="socksRows" class="rows">'
  env | grep -E '^SOCKS[0-9]+=' | sort -V | while IFS='=' read -r sname svalue; do
    [ -z "$sname" ] && continue
    idx=$(printf '%s' "$sname" | sed 's/^SOCKS//')
    s_server=""; s_port=""; s_user=""; s_pass=""; s_tls=""; s_fp=""; s_skip=""; s_udp=""; s_ipv=""
    OLDIFS=$IFS
    IFS='#'
    for pair in $svalue; do
      [ -z "$pair" ] && continue
      key="${pair%%=*}"
      val="${pair#*=}"
      case "$key" in
        server)           s_server="$val" ;;
        port)             s_port="$val" ;;
        username)         s_user="$val" ;;
        password)         s_pass="$val" ;;
        tls)              s_tls="$val" ;;
        fingerprint)      s_fp="$val" ;;
        skip-cert-verify) s_skip="$val" ;;
        udp)              s_udp="$val" ;;
        ip-version)       s_ipv="$val" ;;
      esac
    done
    IFS=$OLDIFS
    cat <<EOF
<div class="env-row socks-row" data-index="$idx" data-max-index="99">
  <input type="hidden" name="$sname" value="$(printf '%s' "$svalue" | h)" data-default="" data-base="SOCKS">
  <div class="socks-content">
    <b class="socks-title">$sname</b>
    <div class="socks-grid">
      <label><span>server *</span><input class="socks-server" value="$(printf '%s' "$s_server" | h)" placeholder="1.2.3.4 / host"></label>
      <label><span>port *</span><input class="socks-port" type="number" value="$(printf '%s' "$s_port" | h)" placeholder="1080"></label>
      <label><span>username</span><input class="socks-username" value="$(printf '%s' "$s_user" | h)"></label>
      <label><span>password</span><input class="socks-password" value="$(printf '%s' "$s_pass" | h)"></label>
      <label><span>fingerprint</span><input class="socks-fingerprint" value="$(printf '%s' "$s_fp" | h)" placeholder="chrome / firefox / …"></label>
      <label><span>ip-version</span>
        <select class="socks-ip-version">
          <option value="" $([ -z "$s_ipv" ] && echo selected)>— (default ipv4) —</option>
          <option value="ipv4" $([ "$s_ipv" = "ipv4" ] && echo selected)>ipv4</option>
          <option value="ipv6" $([ "$s_ipv" = "ipv6" ] && echo selected)>ipv6</option>
          <option value="dual" $([ "$s_ipv" = "dual" ] && echo selected)>dual</option>
          <option value="ipv4-prefer" $([ "$s_ipv" = "ipv4-prefer" ] && echo selected)>ipv4-prefer</option>
          <option value="ipv6-prefer" $([ "$s_ipv" = "ipv6-prefer" ] && echo selected)>ipv6-prefer</option>
        </select>
      </label>
    </div>
    <div class="socks-toggles">
      <label class="socks-toggle"><input type="checkbox" class="socks-tls" $([ "$s_tls" = "true" ] && echo checked)><span>tls</span></label>
      <label class="socks-toggle"><input type="checkbox" class="socks-skip-cert-verify" $([ "$s_skip" = "true" ] && echo checked)><span>skip-cert-verify</span></label>
      <label class="socks-toggle"><input type="checkbox" class="socks-udp" $([ "$s_udp" != "false" ] && echo checked)><span>udp</span></label>
    </div>
  </div>
  <button type="button" onclick="removeSocksRow(this)">Удалить</button>
</div>
EOF
  done
  echo '</div>'
  section_end

  section_start_tab mounted "Mounted providers" "Файлы, которые entrypoint читает из каталогов: AWG configs, proxies_mount."
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
            <option value="ssr">ShadowsocksR</option>
            <option value="snell">Snell</option>
            <option value="mieru">Mieru</option>
            <option value="anytls">AnyTLS</option>
            <option value="wireguard">WireGuard</option>
            <option value="amneziawg">AmneziaWG</option>
            <option value="hysteria">Hysteria v1</option>
            <option value="hysteria2">Hysteria2</option>
            <option value="tuic">TUIC</option>
            <option value="masque">MASQUE</option>
            <option value="tailscale">Tailscale</option>
            <option value="trusttunnel">TrustTunnel</option>
            <option value="openvpn">OpenVPN</option>
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
  page_tabs_nav \
    byedpi      "BYEDPI" \
    byedpicheck "ByeDPI Check" \
    zapret      "ZAPRET" \
    blockcheck  "BlockCheck" \
    zapret2     "ZAPRET2" \
    blockcheck2 "BlockCheck2" \
    zapret-wg   "ZAPRET2 WG" \
    fakebin     "fakebin" \
    lists       "lists"
  section_start_tab byedpi "BYEDPI" "Команды BYEDPI_CMD* создают file provider и отдельные маршруты."
  echo '<div class="subhead"><b>BYEDPI_CMD*</b><button type="button" onclick="addRow('\''byedpi'\'', '\''BYEDPI_CMD'\'', false)">Добавить</button></div><div id="byedpi" class="rows">'
  for name in $(env_names '^BYEDPI_CMD[0-9]*='); do
    idx="$(printf '%s' "$name" | sed 's/BYEDPI_CMD//')"; [ -z "$idx" ] && idx=0
    cat <<EOF
<div class="env-row dpi-single-row" data-index="$idx" data-max-index="99"><label><span>$name</span><input name="$name" value="$(env_attr "$name" "")" placeholder="--transparent ..."></label><button type="button" onclick="removeEnvRow(this)">Удалить</button></div>
EOF
  done
  echo '</div>'
  section_end

  section_start_tab byedpicheck "Подбор стратегий ByeDPI Check — для byedpi" "Параллельный перебор стратегий byedpi против заданных доменов. Использует DoH (через openssl) для резолва, изолированные nft/iptables-правила и пул воркеров. TCP проверяется через временный byedpi transparent, UDP/QUIC — через byedpi SOCKS + hs5t; у каждого воркера свой src-порт / mark / route table. Может работать рядом с основными BYEDPI_CMD*, потому что использует отдельные тестовые порты и таблицы."
  cat <<'EOF'
<div class="notice notice-warn"><b>Результаты в RAM</b><span>Логи и отчёты хранятся в <code>/dev/shm/mihomo-byedpi-check/</code> и пропадают после перезагрузки контейнера. Скачайте отчёт или примените стратегию в <code>BYEDPI_CMD</code>, если нужно надолго.</span></div>
<div class="blockcheck-controls">
  <label class="field" title="Форматы строк:&#10; • host                              — handshake-only тест (быстро)&#10; • host/path                          — handshake + скачивание body, должно прийти ≥ N КБ&#10; • @full https://host/path?query     — throughput-тест: тянем 256 КБ за ≤5 с (≈410 kbps min). Для googlevideo /videoplayback URL такой режим включается автоматически."><span><b>Домены</b><em>по одному в строке. <code>host</code> = handshake-only, <code>host/path</code> = + скачать body ≥ N КБ, <code>@full https://...</code> = throughput-тест 256 КБ за ≤5 с (для googlevideo автоматически).</em></span>
    <textarea id="bdcDomains" rows="4" placeholder="rutracker.org
discord.com
google.com/search?q=test"></textarea>
  </label>
  <details class="bc-tier-info">
    <summary>YouTube / googlevideo</summary>
    <div class="bc-tier-info-body">
      <p>Контейнер не извлекает <code>youtube.com/watch</code> в прямые потоки. Можно попробовать получить прямую ссылку на видеопоток внешним инструментом <a class="doc-link" href="https://github.com/yt-dlp/yt-dlp" target="_blank" rel="noopener">yt-dlp/yt-dlp</a>.</p>
      <p>Пример строки для поля <b>Домены</b>: <code>@full https://...googlevideo.com/videoplayback?...</code></p>
      <p><code>@full</code> для <code>googlevideo.com/videoplayback</code> включает YouTube-комплект: <code>www.youtube.com</code>, <code>redirector.googlevideo.com</code>, <code>i.ytimg.com</code> и сам видеопоток. Поток должен отдать 2 МБ за 5 секунд — ориентир для 480p. Та же googlevideo-ссылка без <code>@full</code> проверяет только видеопоток.</p>
    </div>
  </details>
  <div class="grid bc-grid">
    <label class="field"><span><b>Воркеров</b><em>1-16, параллелизм. Каждый воркер поднимает временные byedpi и hs5t</em></span>
      <input id="bdcWorkers" type="number" min="1" max="16" value="4">
    </label>
    <label class="field"><span><b>Уровень</b><em>сколько стратегий перебрать</em></span>
      <select id="bdcLevel">
        <option value="quick">quick (~15)</option>
        <option value="basic" selected>basic (~70, рекомендуется)</option>
        <option value="medium">medium (~120)</option>
        <option value="extended">extended (~220)</option>
        <option value="full">full (~300+)</option>
      </select>
    </label>
  </div>
  <details class="bc-tier-info">
    <summary>Что добавляется в каждом уровне</summary>
    <div class="bc-tier-info-body">
      <p><b>quick</b> — sanity-check инфраструктуры. Базовые <code>fake</code>, <code>split</code>, <code>disorder</code>, <code>tlsrec</code>, UDP fake и короткие ladder-варианты.</p>
      <p><b>basic</b> (+к quick) — стартовый рабочий набор. TTL/def-ttl, SNI fake, <code>fake-tls-mod</code>, HTTP mod, позиции <code>1+s</code> / <code>3+s</code> / <code>host</code>-смещения, а при включённом fakebin — <code>--fake-data &lt;file&gt;</code>.</p>
      <p><b>medium</b> (+к basic) — расширение для типичных кейсов. <code>auto=torst,redirect,ssl_err</code>, <code>oob</code>/<code>disoob</code>, смешанные TCP/UDP цепочки и более длинные ladder-комбинации.</p>
      <p><b>extended</b> (+к medium) — глубокий поиск. Больше SNI, dual-ladder варианты, fake-data по TLS/HTTP категориям.</p>
      <p><b>full</b> (+к extended) — последний километр. QUIC fake-data из fakebin, дополнительные UDP fake counts и самые тяжёлые варианты.</p>
    </div>
  </details>
  <div class="socks-toggles bc-tests" aria-label="Типы тестов">
    <label class="socks-toggle" title="GET / по TCP/80 (handshake = есть HTTP-ответ; hard-body режим — что в теле есть HTTP/ и размер ≥ N КБ)"><input type="checkbox" id="bdcTestHttp" checked><span>HTTP/80</span></label>
    <label class="socks-toggle" title="TLS 1.2 handshake к TCP/443"><input type="checkbox" id="bdcTestTls12" checked><span>TLS 1.2</span></label>
    <label class="socks-toggle" title="TLS 1.3 handshake к TCP/443"><input type="checkbox" id="bdcTestTls13" checked><span>TLS 1.3</span></label>
    <label class="socks-toggle" title="QUIC v1 handshake к UDP/443 через byedpi SOCKS + hs5t"><input type="checkbox" id="bdcTestQuic" checked><span>QUIC/443</span></label>
    <label class="socks-toggle" title="Дополнительно перебрать .bin-файлы из /zapret-fakebin как payload для byedpi --fake-data FILE. Увеличивает количество стратегий."><input type="checkbox" id="bdcUseFakebin"><span>×fakebin</span></label>
  </div>
  <div class="grid bc-grid">
    <label class="field"><span><b>Мин. размер ответа для 16-20KB теста, КБ</b><em>Применяется к доменам с путём.</em></span>
      <input id="bdcHardMinKb" type="number" min="4" max="256" value="16">
    </label>
    <label class="field" title="Стратегии с fake-sni/fake-tls-mod rand могут вести себя нестабильно — probe засчитывается «ok» только если все N попыток прошли подряд. 2 — рекомендовано."><span><b>Повторов на rnd-стратегию</b><em>Probe считается «ok» только если все N попыток подряд прошли. Применяется к <code>rnd</code>-стратегиям. 2 — рекомендовано.</em></span>
      <input id="bdcRndRepeats" type="number" min="1" max="5" value="2">
    </label>
  </div>
  <div class="bc-actions">
    <button type="button" class="primary" onclick="byedpiCheckStart()" id="bdcStartBtn">Запустить</button>
    <button type="button" onclick="byedpiCheckCancel()" id="bdcCancelBtn" disabled>Остановить</button>
    <button type="button" onclick="byedpiCheckDownload()" id="bdcDownloadBtn" disabled>Скачать отчёт</button>
    <span class="bc-status" id="bdcStatus">готов</span>
  </div>
  <details class="bc-custom" id="bdcCustomBox">
    <summary>Тест произвольной стратегии</summary>
    <div class="bc-custom-body">
      <label class="field"><span><b>Аргументы byedpi</b><em>полная строка с флагами byedpi: <code>--fake</code>, <code>--split</code>, <code>--disorder</code>, <code>--tlsrec</code>, <code>--auto=…</code>, <code>--fake-data=…</code>. Без <code>--port</code>, <code>--transparent</code>, <code>--daemon</code> — порты и режимы задаёт runner.</em></span>
        <textarea id="bdcCustomArgs" rows="3" spellcheck="false" placeholder="--timeout 5 --auto=ssl_err --fake -1 --md5sig --fake-sni yandex.ru"></textarea>
      </label>
      <div class="bc-custom-row">
        <div class="socks-toggles" aria-label="Протоколы для custom-теста">
          <label class="socks-toggle"><input type="checkbox" id="bdcCustomHttp" checked><span>HTTP</span></label>
          <label class="socks-toggle"><input type="checkbox" id="bdcCustomTls12" checked><span>TLS 1.2</span></label>
          <label class="socks-toggle"><input type="checkbox" id="bdcCustomTls13" checked><span>TLS 1.3</span></label>
          <label class="socks-toggle"><input type="checkbox" id="bdcCustomQuic" checked><span>QUIC</span></label>
        </div>
        <button type="button" onclick="byedpiCheckCustom()" id="bdcCustomBtn">Запустить только эту</button>
        <span id="bdcCustomResult" class="bc-custom-result" aria-live="polite"></span>
      </div>
    </div>
  </details>
</div>
<div class="bc-results">
  <div class="bc-progress" id="bdcProgress" hidden>
    <progress id="bdcProgressBar" value="0" max="100"></progress>
    <span id="bdcProgressText">0 / 0</span>
    <span class="bc-current" id="bdcCurrent"></span>
  </div>
  <div class="bc-counts" id="bdcCounts" hidden>
    <span class="bc-count-ok" id="bdcCountOk">0 рабочих</span>
    <span class="bc-count-fail" id="bdcCountFail">0 не сработали</span>
    <span class="bc-count-skip" id="bdcCountSkip">0 пропущено</span>
    <label class="socks-toggle bc-filter-toggle"><input type="checkbox" id="bdcFilterOk" checked><span>только рабочие</span></label>
  </div>
  <details class="bc-combined" id="bdcCombinedBox" hidden>
    <summary><b>Рабочие стратегии BYEDPI</b> <span id="bdcCombinedSummary"></span><button type="button" class="bc-copy-all" title="Скопировать все рабочие стратегии" onclick="event.preventDefault(); event.stopPropagation(); bdcCopyAllCombined(event)">⧉</button></summary>
    <div class="bc-combined-body">
      <p class="bc-combined-hint">Все стратегии, у которых есть хотя бы один успешный probe. Каждый вариант можно скопировать или применить в <code>BYEDPI_CMD</code>.</p>
      <div id="bdcCombinedList" class="bc-combined-list"></div>
    </div>
  </details>
  <details class="bc-table-box" id="bdcTableBox" hidden>
    <summary>Подробная таблица найденных стратегий <span id="bdcTableSummary"></span><button type="button" class="bc-copy-all" title="Скопировать таблицу" onclick="event.preventDefault(); event.stopPropagation(); bdcCopyAllTable(event)">⧉</button></summary>
    <div class="bc-table-scroll">
      <table class="bc-table" id="bdcTable">
        <thead><tr><th>Стратегия</th><th>Proto</th><th>Pass</th><th>Fail</th><th>Skip</th><th>Детали</th><th></th></tr></thead>
        <tbody></tbody>
      </table>
    </div>
  </details>
  <details class="bc-log" id="bdcLogBox"><summary>Лог событий runner'a<button type="button" class="bc-copy-all" title="Скопировать лог" onclick="event.preventDefault(); event.stopPropagation(); bdcCopyAllLog(event)">⧉</button></summary>
    <pre id="bdcLog">(пусто — лог появится после запуска)</pre>
  </details>
</div>
EOF
  section_end

  section_start_tab zapret "ZAPRET (nfqws)" "Стратегии nfqws и packet-window для обычного DPI обхода."
  echo '<div class="grid">'
  field ZAPRET_PACKETS "ZAPRET packets" "Глобальная переменная: сколько первых пакетов соединения будут проходить очередь ZAPRET. <code>0</code> — все пакеты всегда идут через ZAPRET." "12" number "12"
  echo '</div>'
  echo '<div class="notice"><b>Packets per strategy</b><span>У каждой стратегии можно отдельно изменить это окно через <code>ZAPRET_PACKETSn</code>. Если поле пустое — используется глобальное значение выше.</span></div>'
  echo '<div class="subhead"><b>ZAPRET_CMD*</b><button type="button" onclick="addRow('\''zapret'\'', '\''ZAPRET_CMD'\'', false)">Добавить</button></div><div id="zapret" class="rows">'
  for name in $(env_names '^ZAPRET_CMD[0-9]*='); do
    idx="$(printf '%s' "$name" | sed 's/ZAPRET_CMD//')"; [ -z "$idx" ] && idx=0
    cat <<EOF
<div class="env-row dpi-packet-row" data-index="$idx" data-max-index="99"><label><span>$name</span><input name="$name" value="$(env_attr "$name" "")" placeholder="--dpi-desync=..."></label><label><span>ZAPRET_PACKETS$idx</span><input name="ZAPRET_PACKETS$idx" value="$(env_attr "ZAPRET_PACKETS$idx" "")" placeholder="12"></label><button type="button" onclick="removeEnvRow(this)">Удалить</button></div>
EOF
  done
  echo '</div>'
  section_end

  section_start_tab blockcheck "Подбор стратегий BlockCheck — для zapret" "Параллельный перебор стратегий nfqws v1 (отдельные --dpi-desync-* флаги) против заданных доменов. Использует DoH (через openssl) для резолва, изолированную nft-таблицу и пул воркеров. Может работать параллельно с BlockCheck2 — у каждого свой пул src-портов / queue / mark. Требует nft-поддержки ядра — на RouterOS это arm64/amd64 версии 7.21 и выше."
  cat <<'EOF'
<div class="notice notice-warn"><b>Результаты в RAM</b><span>Логи и отчёты хранятся в <code>/dev/shm/mihomo-blockcheck1/</code> и пропадают после перезагрузки контейнера. Скачайте отчёт или примените стратегию в <code>ZAPRET_CMD</code>, если нужно надолго.</span></div>
<div class="blockcheck-controls">
  <label class="field" title="Форматы строк:&#10; • host                              — handshake-only тест (быстро)&#10; • host/path                          — handshake + скачивание body, должно прийти ≥ N КБ&#10; • @full https://host/path?query     — throughput-тест: тянем 256 КБ за ≤5 с (≈410 kbps min). Для googlevideo /videoplayback URL такой режим включается автоматически."><span><b>Домены</b><em>по одному в строке. <code>host</code> = handshake-only, <code>host/path</code> = + скачать body ≥ N КБ, <code>@full https://...</code> = throughput-тест 256 КБ за ≤5 с (для googlevideo автоматически).</em></span>
    <textarea id="bc1Domains" rows="4" placeholder="rutracker.org
discord.com
google.com/search?q=test"></textarea>
  </label>
  <details class="bc-tier-info">
    <summary>YouTube / googlevideo</summary>
    <div class="bc-tier-info-body">
      <p>Контейнер не извлекает <code>youtube.com/watch</code> в прямые потоки. Можно попробовать получить прямую ссылку на видеопоток внешним инструментом <a class="doc-link" href="https://github.com/yt-dlp/yt-dlp" target="_blank" rel="noopener">yt-dlp/yt-dlp</a>.</p>
      <p>Пример строки для поля <b>Домены</b>: <code>@full https://...googlevideo.com/videoplayback?...</code></p>
      <p><code>@full</code> для <code>googlevideo.com/videoplayback</code> включает YouTube-комплект: <code>www.youtube.com</code>, <code>redirector.googlevideo.com</code>, <code>i.ytimg.com</code> и сам видеопоток. Поток должен отдать 2 МБ за 5 секунд — ориентир для 480p. Та же googlevideo-ссылка без <code>@full</code> проверяет только видеопоток.</p>
    </div>
  </details>
  <div class="grid bc-grid">
    <label class="field"><span><b>Воркеров</b><em>1-32, параллелизм. Каждый воркер ≈ 5 МБ RAM</em></span>
      <input id="bc1Workers" type="number" min="1" max="32" value="4">
    </label>
    <label class="field"><span><b>Уровень</b><em>сколько стратегий перебрать</em></span>
      <select id="bc1Level">
        <option value="quick">quick (~15)</option>
        <option value="basic" selected>basic (~320, рекомендуется)</option>
        <option value="medium">medium (~920)</option>
        <option value="extended">extended (~1500)</option>
        <option value="full">full (~1900)</option>
      </select>
    </label>
  </div>
  <details class="bc-tier-info">
    <summary>Что добавляется в каждом уровне</summary>
    <div class="bc-tier-info-body">
      <p><b>quick</b> — sanity-check инфраструктуры. 1 splitter (<code>multisplit</code>), 2 fooling (<code>badsum</code>, <code>md5sig</code>), базовые позиции <code>1</code> / <code>host+1</code>. Без композитных модов, seqovl, cutoff.</p>
      <p><b>basic</b> (+к quick) — стартовый рабочий набор. Сплиттеры <code>multidisorder</code>, <code>fakedsplit</code>; <b>композитные modes</b> (<code>fake,multisplit</code>, <code>fake,multidisorder</code>); foolings <code>badseq</code>, <code>datanoack</code>, <code>ts</code> + композит <code>ts,badsum</code>; seqovl <code>1, 681</code>; <code>fake-tls-mod=rnd,dupsid</code>; ещё позиции TLS.</p>
      <p><b>medium</b> (+к basic) — расширение для типичных кейсов. Сплиттеры <code>fakeddisorder</code>, <code>hostfakesplit</code>; композит <code>fake,fakedsplit</code>; <b>cutoff</b> <code>n3/n4</code> (лимит обрабатываемых пакетов); <b>badseq-increment</b> <code>0/2</code>; seqovl <code>652, 726</code>; составной fooling <code>badsum,badseq</code>; длинные позиции (<code>sld+1</code>, <code>1,sld+1,endsld-2</code>).</p>
      <p><b>extended</b> (+к medium) — глубокий поиск. Сплиттер <code>ipfrag2</code>; композит <code>syndata,multisplit</code>; fooling <code>hopbyhop</code>; seqovl <code>654, 1200</code>; супер-цепочка позиций TLS; HTTP позиция <code>endhost-1</code>.</p>
      <p><b>full</b> (+к extended) — последний километр. seqovl <code>1500</code>; cutoff <code>n5</code>; badseq-inc <code>1000</code>; HTTP позиции <code>endhost-1/+1</code>.</p>
    </div>
  </details>
  <div class="socks-toggles bc-tests" aria-label="Типы тестов">
    <label class="socks-toggle" title="GET / по TCP/80 (handshake = есть HTTP-ответ; hard-body режим — что в теле есть HTTP/ и размер ≥ N КБ)"><input type="checkbox" id="bc1TestHttp"  checked><span>HTTP/80</span></label>
    <label class="socks-toggle" title="TLS 1.2 handshake к TCP/443"><input type="checkbox" id="bc1TestTls12" checked><span>TLS 1.2</span></label>
    <label class="socks-toggle" title="TLS 1.3 handshake к TCP/443"><input type="checkbox" id="bc1TestTls13" checked><span>TLS 1.3</span></label>
    <label class="socks-toggle" title="QUIC v1 handshake к UDP/443"><input type="checkbox" id="bc1TestQuic" checked><span>QUIC/443</span></label>
    <label class="socks-toggle" title="Дополнительно перебрать каждый .bin-файл из /zapret-fakebin как payload для --dpi-desync-fake-tls=$FILE / --dpi-desync-fake-http=$FILE / --dpi-desync-fake-quic=$FILE. Сильно увеличивает количество стратегий."><input type="checkbox" id="bc1UseFakebin"><span>×fakebin</span></label>
  </div>
  <div class="grid bc-grid">
    <label class="field"><span><b>Мин. размер ответа для 16-20KB теста, КБ</b><em>Применяется к доменам с путём.</em></span>
      <input id="bc1HardMinKb" type="number" min="4" max="256" value="16">
    </label>
    <label class="field" title="Стратегии с tls_mod=rnd рандомят ClientHello — probe засчитывается «ok» только если все N попыток прошли подряд. 2 — рекомендовано."><span><b>Повторов на rnd-стратегию</b><em>Probe считается «ok» только если все N попыток подряд прошли. Применяется к <code>rnd</code>-стратегиям. 2 — рекомендовано.</em></span>
      <input id="bc1RndRepeats" type="number" min="1" max="5" value="2">
    </label>
  </div>
  <div class="bc-actions">
    <button type="button" class="primary" onclick="blockcheck1Start()" id="bc1StartBtn">Запустить</button>
    <button type="button" onclick="blockcheck1Cancel()" id="bc1CancelBtn" disabled>Остановить</button>
    <button type="button" onclick="blockcheck1Download()" id="bc1DownloadBtn" disabled>Скачать отчёт</button>
    <span class="bc-status" id="bc1Status">готов</span>
  </div>
  <details class="bc-custom" id="bc1CustomBox">
    <summary>Тест произвольной стратегии</summary>
    <div class="bc-custom-body">
      <label class="field"><span><b>Аргументы nfqws (v1)</b><em>полная строка с флагами nfqws: <code>--filter-tcp=…</code> + <code>--dpi-desync=…</code> + <code>--dpi-desync-split-pos=…</code> и т.д. Несколько профилей через <code>--new</code>.</em></span>
        <textarea id="bc1CustomArgs" rows="3" spellcheck="false" placeholder="--filter-tcp=443 --dpi-desync=multisplit --dpi-desync-split-pos=1 --dpi-desync-fooling=badsum"></textarea>
      </label>
      <div class="bc-custom-row">
        <div class="socks-toggles" aria-label="Протоколы для custom-теста">
          <label class="socks-toggle"><input type="checkbox" id="bc1CustomHttp"  checked><span>HTTP</span></label>
          <label class="socks-toggle"><input type="checkbox" id="bc1CustomTls12" checked><span>TLS 1.2</span></label>
          <label class="socks-toggle"><input type="checkbox" id="bc1CustomTls13" checked><span>TLS 1.3</span></label>
          <label class="socks-toggle"><input type="checkbox" id="bc1CustomQuic"  checked><span>QUIC</span></label>
        </div>
        <button type="button" onclick="blockcheck1Custom()" id="bc1CustomBtn">Запустить только эту</button>
        <span id="bc1CustomResult" class="bc-custom-result" aria-live="polite"></span>
      </div>
    </div>
  </details>
</div>
<div class="bc-results">
  <div class="bc-progress" id="bc1Progress" hidden>
    <progress id="bc1ProgressBar" value="0" max="100"></progress>
    <span id="bc1ProgressText">0 / 0</span>
    <span class="bc-current" id="bc1Current"></span>
  </div>
  <div class="bc-counts" id="bc1Counts" hidden>
    <span class="bc-count-ok"   id="bc1CountOk">0 рабочих</span>
    <span class="bc-count-fail" id="bc1CountFail">0 не сработали</span>
    <span class="bc-count-skip" id="bc1CountSkip">0 пропущено</span>
    <label class="socks-toggle bc-filter-toggle"><input type="checkbox" id="bc1FilterOk" checked><span>только рабочие</span></label>
  </div>
  <details class="bc-combined" id="bc1CombinedBox" hidden>
    <summary><b>Сборные стратегии из рабочих</b> <span id="bc1CombinedSummary"></span><button type="button" class="bc-copy-all" title="Скопировать все сборные стратегии (по одной на строку)" onclick="event.preventDefault(); event.stopPropagation(); bc1CopyAllCombined(event)">⧉</button></summary>
    <div class="bc-combined-body">
      <p class="bc-combined-hint">Кросс-произведение всех рабочих <code>http</code> × <code>tls</code> × <code>quic</code> стратегий, склеенных через <code>--new</code>. Каждый вариант можно скопировать или применить в <code>ZAPRET_CMD</code>.</p>
      <div id="bc1CombinedList" class="bc-combined-list"></div>
    </div>
  </details>
  <details class="bc-table-box" id="bc1TableBox" hidden>
    <summary>Подробная таблица найденных стратегий <span id="bc1TableSummary"></span><button type="button" class="bc-copy-all" title="Скопировать всю таблицу: name, proto, pass/fail/skip, args для каждой строки" onclick="event.preventDefault(); event.stopPropagation(); bc1CopyAllTable(event)">⧉</button></summary>
    <div class="bc-table-scroll">
      <table class="bc-table" id="bc1Table">
        <thead><tr>
          <th>Стратегия</th>
          <th>Proto</th>
          <th>Pass</th>
          <th>Fail</th>
          <th>Skip</th>
          <th>Детали</th>
          <th></th>
        </tr></thead>
        <tbody></tbody>
      </table>
    </div>
  </details>
  <details class="bc-log" id="bc1LogBox"><summary>Лог событий runner'a<button type="button" class="bc-copy-all" title="Скопировать весь лог в буфер обмена" onclick="event.preventDefault(); event.stopPropagation(); bc1CopyAllLog(event)">⧉</button></summary>
    <pre id="bc1Log">(пусто — лог появится после запуска)</pre>
  </details>
</div>

EOF
  section_end

  section_start_tab zapret2 "ZAPRET2 (nfqws2)" "Стратегии nfqws2 (lua-движок) и packet-window."
  echo '<div class="grid">'
  field ZAPRET2_PACKETS "ZAPRET2 packets" "Глобальная переменная: сколько первых пакетов соединения будут проходить очередь ZAPRET2. <code>0</code> — все пакеты всегда идут через ZAPRET2." "12" number "12"
  echo '</div>'
  echo '<div class="notice"><b>Packets per strategy</b><span>У каждой стратегии можно отдельно изменить это окно через <code>ZAPRET2_PACKETSn</code>. Если поле пустое — используется глобальное значение выше.</span></div>'
  echo '<div class="subhead"><b>ZAPRET2_CMD*</b><button type="button" onclick="addRow('\''zapret2'\'', '\''ZAPRET2_CMD'\'', false)">Добавить</button></div><div id="zapret2" class="rows">'
  for name in $(env_names '^ZAPRET2_CMD[0-9]*='); do
    idx="$(printf '%s' "$name" | sed 's/ZAPRET2_CMD//')"; [ -z "$idx" ] && idx=0
    cat <<EOF
<div class="env-row dpi-packet-row" data-index="$idx" data-max-index="99"><label><span>$name</span><input name="$name" value="$(env_attr "$name" "")" placeholder="--dpi-desync=..."></label><label><span>ZAPRET2_PACKETS$idx</span><input name="ZAPRET2_PACKETS$idx" value="$(env_attr "ZAPRET2_PACKETS$idx" "")" placeholder="12"></label><button type="button" onclick="removeEnvRow(this)">Удалить</button></div>
EOF
  done
  echo '</div>'
  section_end

  section_start_tab blockcheck2 "Подбор стратегий BlockCheck2 — для zapret2" "Параллельный перебор стратегий nfqws2 (lua-движок) против заданных доменов. Использует DoH (через openssl) для резолва, изолированную nft-таблицу и пул воркеров. Может работать параллельно с BlockCheck — у каждого свой пул src-портов / queue / mark. Требует nft-поддержки ядра — на RouterOS это arm64/amd64 версии 7.21 и выше."
  cat <<'EOF'
<div class="notice notice-warn"><b>Результаты в RAM</b><span>Логи и отчёты хранятся в <code>/dev/shm/mihomo-blockcheck2/</code> и пропадают после перезагрузки контейнера. Скачайте отчёт или примените стратегию в <code>ZAPRET2_CMD</code>, если нужно надолго.</span></div>
<div class="blockcheck-controls">
  <label class="field" title="Форматы строк:&#10; • host                              — handshake-only тест (быстро)&#10; • host/path                          — handshake + скачивание body, должно прийти ≥ N КБ&#10; • @full https://host/path?query     — throughput-тест: тянем 256 КБ за ≤5 с (≈410 kbps min). Для googlevideo /videoplayback URL такой режим включается автоматически."><span><b>Домены</b><em>по одному в строке. <code>host</code> = handshake-only, <code>host/path</code> = + скачать body ≥ N КБ, <code>@full https://...</code> = throughput-тест 256 КБ за ≤5 с (для googlevideo автоматически).</em></span>
    <textarea id="bcDomains" rows="4" placeholder="rutracker.org
discord.com
google.com/search?q=test"></textarea>
  </label>
  <details class="bc-tier-info">
    <summary>YouTube / googlevideo</summary>
    <div class="bc-tier-info-body">
      <p>Контейнер не извлекает <code>youtube.com/watch</code> в прямые потоки. Можно попробовать получить прямую ссылку на видеопоток внешним инструментом <a class="doc-link" href="https://github.com/yt-dlp/yt-dlp" target="_blank" rel="noopener">yt-dlp/yt-dlp</a>.</p>
      <p>Пример строки для поля <b>Домены</b>: <code>@full https://...googlevideo.com/videoplayback?...</code></p>
      <p><code>@full</code> для <code>googlevideo.com/videoplayback</code> включает YouTube-комплект: <code>www.youtube.com</code>, <code>redirector.googlevideo.com</code>, <code>i.ytimg.com</code> и сам видеопоток. Поток должен отдать 2 МБ за 5 секунд — ориентир для 480p. Та же googlevideo-ссылка без <code>@full</code> проверяет только видеопоток.</p>
    </div>
  </details>
  <div class="grid bc-grid">
    <label class="field"><span><b>Воркеров</b><em>1-32, параллелизм. Каждый воркер ≈ 5 МБ RAM</em></span>
      <input id="bcWorkers" type="number" min="1" max="32" value="4">
    </label>
    <label class="field"><span><b>Уровень</b><em>сколько стратегий перебрать</em></span>
      <select id="bcLevel">
        <option value="quick">quick (~20)</option>
        <option value="basic" selected>basic (~400, рекомендуется)</option>
        <option value="medium">medium (~1300)</option>
        <option value="extended">extended (~3500)</option>
        <option value="full">full (~8000)</option>
      </select>
    </label>
  </div>
  <details class="bc-tier-info">
    <summary>Что добавляется в каждом уровне</summary>
    <div class="bc-tier-info-body">
      <p><b>quick</b> — sanity-check инфраструктуры. 2 сплиттера (<code>multidisorder</code>, <code>multisplit</code>), 2 fooling (<code>badsum</code>, <code>tcp_ts=-1000</code>), <code>tls_mod=rnd,dupsid</code>, без pre-fake.</p>
      <p><b>basic</b> (+к quick) — типичный рабочий набор. Сплиттеры <code>fakedsplit</code>, <code>fakeddisorder</code>; <b>pre-fake on</b> (fake-цепочка перед split); foolings <code>tcp_ack=-66000:tcp_ts_up</code>, <code>tcp_md5</code>; tls_mod <code>rnd</code>; seqovl <code>1, -1, 681</code>; позиции <code>1,midsld,1220</code>, <code>host+1</code>, <code>sld+1</code>.</p>
      <p><b>medium</b> (+к basic) — расширение. Сплиттер <code>hostfakesplit</code>; foolings <code>tcp_seq=-3000</code>, <code>tcp_nop_del</code>; tls_mod <code>dupsid</code>; seqovl <code>652, 726</code>; позиции <code>1,sniext+1</code>, <code>sniext+1,midsld</code>, <code>1,sld+1,endsld-2</code>; HTTP <code>method+4</code>, <code>host+5</code>.</p>
      <p><b>extended</b> (+к medium) — глубокий поиск. Сплиттер <code>tcpseg</code>; foolings <code>ip_id=rnd</code>, <code>ip_id=zero</code>, композит <code>badsum:tcp_md5</code>; tls_mod <code>rndsni</code>; seqovl <code>-2, 1200</code>; супер-цепочка позиций TLS; HTTP <code>endhost-1</code>.</p>
      <p><b>full</b> (+к extended) — всё, включая редкие. Сплиттер <code>multidisorder_legacy</code>; foolings <code>tcp_seq=-1000</code>, <code>ip_id=seq</code>, композит <code>tcp_ts=-1000:badsum</code>; seqovl <code>1500</code>; ещё позиции TLS/HTTP; <b>специальные lua-функции</b>: <code>synhide</code> (скрытие SYN), <code>wsize</code>/<code>wssize</code> (window-манипуляция), <code>tls_client_hello_clone</code>, <code>synack_split</code>, QUIC <code>udplen</code>.</p>
    </div>
  </details>
  <div class="socks-toggles bc-tests" aria-label="Типы тестов">
    <label class="socks-toggle" title="GET / по TCP/80 (handshake = есть HTTP-ответ; hard-body режим — что в теле есть HTTP/ и размер ≥ N КБ)"><input type="checkbox" id="bcTestHttp"  checked><span>HTTP/80</span></label>
    <label class="socks-toggle" title="TLS 1.2 handshake к TCP/443 через openssl s_client -tls1_2 -bind … -servername host (handshake = есть Cipher/Verify)"><input type="checkbox" id="bcTestTls12" checked><span>TLS 1.2</span></label>
    <label class="socks-toggle" title="TLS 1.3 handshake к TCP/443 через openssl s_client -tls1_3 -bind … -servername host"><input type="checkbox" id="bcTestTls13" checked><span>TLS 1.3</span></label>
    <label class="socks-toggle" title="QUIC v1 handshake к UDP/443 через openssl s_client -quic -alpn h3 -servername host (handshake = пришёл Server certificate). Нужен OpenSSL ≥3.5 в контейнере."><input type="checkbox" id="bcTestQuic" checked><span>QUIC/443</span></label>
    <label class="socks-toggle" title="Дополнительно перебрать каждый .bin-файл из /zapret-fakebin в качестве fake-payload (заменяет fake_default_tls на --blob=fb:@…). Заметно увеличивает число стратегий (×N_blobs), но именно среди них чаще всего и находятся рабочие комбинации."><input type="checkbox" id="bcUseFakebin"><span>×fakebin</span></label>
  </div>
  <div class="grid bc-grid">
    <label class="field"><span><b>Мин. размер ответа для 16-20KB теста, КБ</b><em>Применяется к доменам с путём.</em></span>
      <input id="bcHardMinKb" type="number" min="4" max="256" value="16">
    </label>
    <label class="field" title="Стратегии с tls_mod=rnd рандомят ClientHello — probe засчитывается «ok» только если все N попыток прошли подряд. 2 — рекомендовано."><span><b>Повторов на rnd-стратегию</b><em>Probe считается «ok» только если все N попыток подряд прошли. Применяется к <code>rnd</code>-стратегиям. 2 — рекомендовано.</em></span>
      <input id="bcRndRepeats" type="number" min="1" max="5" value="2">
    </label>
  </div>
  <div class="bc-actions">
    <button type="button" class="primary" onclick="blockcheck2Start()" id="bcStartBtn">Запустить</button>
    <button type="button" onclick="blockcheck2Cancel()" id="bcCancelBtn" disabled>Остановить</button>
    <button type="button" onclick="blockcheck2Download()" id="bcDownloadBtn" disabled>Скачать отчёт</button>
    <span class="bc-status" id="bcStatus">готов</span>
  </div>
  <details class="bc-custom" id="bcCustomBox">
    <summary>Тест произвольной стратегии</summary>
    <div class="bc-custom-body">
      <label class="field"><span><b>Аргументы nfqws2</b><em>полная строка (включая <code>--filter-tcp=…</code> и <code>--payload=…</code>). Можно несколько профилей через <code>--new</code> — будут тестироваться все выбранные ниже типы.</em></span>
        <textarea id="bcCustomArgs" rows="3" spellcheck="false" placeholder="--filter-tcp=80 --payload=http_req --lua-desync=multidisorder:pos=host+1:badsum --new --filter-tcp=443 --payload=tls_client_hello --lua-desync=multidisorder:pos=1:badsum --new --filter-udp=0-65535 --payload=quic_initial --lua-desync=fake:blob=fake_default_quic:repeats=20"></textarea>
      </label>
      <div class="bc-custom-row">
        <div class="socks-toggles" aria-label="Протоколы для custom-теста" title="По каким протоколам гонять стратегию">
          <label class="socks-toggle" title="GET / по TCP/80"><input type="checkbox" id="bcCustomHttp"  checked><span>HTTP</span></label>
          <label class="socks-toggle" title="TLS 1.2 handshake к TCP/443"><input type="checkbox" id="bcCustomTls12" checked><span>TLS 1.2</span></label>
          <label class="socks-toggle" title="TLS 1.3 handshake к TCP/443"><input type="checkbox" id="bcCustomTls13" checked><span>TLS 1.3</span></label>
          <label class="socks-toggle" title="QUIC v1 handshake к UDP/443 (openssl s_client -quic -alpn h3)"><input type="checkbox" id="bcCustomQuic"  checked><span>QUIC</span></label>
        </div>
        <button type="button" onclick="blockcheck2Custom()" id="bcCustomBtn">Запустить только эту</button>
        <span id="bcCustomResult" class="bc-custom-result" aria-live="polite"></span>
      </div>
    </div>
  </details>
</div>
<div class="bc-results">
  <div class="bc-progress" id="bcProgress" hidden>
    <progress id="bcProgressBar" value="0" max="100"></progress>
    <span id="bcProgressText">0 / 0</span>
    <span class="bc-current" id="bcCurrent"></span>
  </div>
  <div class="bc-counts" id="bcCounts" hidden>
    <span class="bc-count-ok"   id="bcCountOk">0 рабочих</span>
    <span class="bc-count-fail" id="bcCountFail">0 не сработали</span>
    <span class="bc-count-skip" id="bcCountSkip">0 пропущено</span>
    <label class="socks-toggle bc-filter-toggle" title="Скрыть строки которые не пробили DPI"><input type="checkbox" id="bcFilterOk" checked><span>только рабочие</span></label>
  </div>
  <details class="bc-combined" id="bcCombinedBox" hidden>
    <summary><b>Сборные стратегии из рабочих</b> <span id="bcCombinedSummary"></span><button type="button" class="bc-copy-all" title="Скопировать все сборные стратегии (по одной на строку)" onclick="event.preventDefault(); event.stopPropagation(); bcCopyAllCombined(event)">⧉</button></summary>
    <div class="bc-combined-body">
      <p class="bc-combined-hint">Кросс-произведение всех рабочих <code>http</code> × <code>tls</code> × <code>quic</code> стратегий, склеенных через <code>--new</code>. Каждый вариант можно скопировать или применить в <code>ZAPRET2_CMD</code>.</p>
      <div id="bcCombinedList" class="bc-combined-list"></div>
    </div>
  </details>
  <details class="bc-table-box" id="bcTableBox" hidden>
    <summary>Подробная таблица найденных стратегий <span id="bcTableSummary"></span><button type="button" class="bc-copy-all" title="Скопировать всю таблицу: name, proto, pass/fail/skip, args для каждой строки" onclick="event.preventDefault(); event.stopPropagation(); bcCopyAllTable(event)">⧉</button></summary>
    <div class="bc-table-scroll">
      <table class="bc-table" id="bcTable">
        <thead><tr>
          <th title="Имя стратегии. Наведи курсор на код — увидишь полные аргументы nfqws2">Стратегия</th>
          <th title="Тип теста: http (порт 80), tls12 / tls13 (TLS 1.2 / 1.3)">Proto</th>
          <th title="Сколько комбинаций (домен × тип) пробились наружу">Pass</th>
          <th title="Сколько не пробились (timeout, RST, или сервер просто ничего не вернул)">Fail</th>
          <th title="Сколько пар не тестировались, потому что proto стратегии не совпадает с типом теста">Skip ⓘ</th>
          <th>Детали</th>
          <th></th>
        </tr></thead>
        <tbody></tbody>
      </table>
    </div>
  </details>
  <details class="bc-log" id="bcLogBox"><summary>Лог событий runner'a<button type="button" class="bc-copy-all" title="Скопировать весь лог в буфер обмена" onclick="event.preventDefault(); event.stopPropagation(); bcCopyAllLog(event)">⧉</button></summary>
    <pre id="bcLog">(пусто — лог появится после запуска)</pre>
  </details>
</div>

EOF
  section_end

  section_start_tab zapret-wg "ZAPRET2 WG" "Отдельная стратегия для пробития WireGuard handshake через nfqws2."
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
    <b>Заворот только WireGuard handshake в контейнер (MikroTik)</b>
    <span>Чтобы через ZAPRET2 шёл только handshake, а основной WG-трафик — напрямую, в RouterOS на mangle помечаем только пакеты-handshake (фиксированный размер 176 байт для AmneziaWG/WireGuard) и заворачиваем их в роутинг-метку контейнера. Замените <code>162.159.192.1:2408</code> на endpoint вашего сервера, <code>MihomoProxyRoS</code> — на routing-mark, ведущую в контейнер.</span>
    <pre><code>/ip firewall mangle
add action=mark-routing chain=output dst-address=162.159.192.1 dst-port=2408 new-routing-mark=MihomoProxyRoS packet-size=176 passthrough=no protocol=udp</code></pre>
  </div>
</div>
EOF
  section_end

  section_start_tab fakebin "Файлы /zapret-fakebin" "Бинарные fake-пакеты для nfqws (--dpi-desync-fake-*). Изменения вступят в силу после перезагрузки контейнера."
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

  section_start_tab lists "Файлы /zapret-lists" "Текстовые списки доменов/IP для nfqws и lua-скриптов. Редактируются прямо в браузере."
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
  # Same layout as user groups: proxies | use, type | interval, url | url_status,
  # strategy | tolerance, filter | exclude.
  printf '<label class="field field-validated" data-env="GROUP_PROXIES" data-validate="proxies"><span><b>GROUP_PROXIES</b><em>GROUP_PROXIES</em></span><input type="text" name="GROUP_PROXIES" value="%s" placeholder="DIRECT,REJECT" data-default=""><small>Явные <a class="doc-link" href="https://wiki.metacubex.one/ru/config/proxy-groups/#proxies" target="_blank" rel="noopener">proxies</a> по умолчанию: имена прокси-групп (регистрозависимо) либо служебные <code>DIRECT</code>, <code>REJECT</code>, <code>REJECT-DROP</code>, <code>PASS</code>.</small><i>%s</i></label>\n' "$(env_attr GROUP_PROXIES "")" "$(is_set GROUP_PROXIES)"
  printf '<label class="field field-validated" data-env="GROUP_USE" data-validate="use"><span><b>GROUP_USE</b><em>GROUP_USE</em></span><input type="text" name="GROUP_USE" value="%s" placeholder="LINK1,SUB_LINK1,BYEDPI" data-default=""><small>Providers по умолчанию (регистрозависимо), параметр <a class="doc-link" href="https://wiki.metacubex.one/ru/config/proxy-groups/#use" target="_blank" rel="noopener">use</a>, или <code>none</code>.</small><i>%s</i></label>\n' "$(env_attr GROUP_USE "")" "$(is_set GROUP_USE)"
  select_field GROUP_TYPE "GROUP_TYPE" "Тип <a class=\"doc-link\" href=\"https://wiki.metacubex.one/ru/config/proxy-groups/#type\" target=\"_blank\" rel=\"noopener\">proxy-groups type</a> по умолчанию." select "select url-test load-balance fallback relay"
  field GROUP_INTERVAL "GROUP_INTERVAL" "Интервал <a class=\"doc-link\" href=\"https://wiki.metacubex.one/ru/config/proxy-groups/#interval\" target=\"_blank\" rel=\"noopener\">health-check</a>." "60" number "60"
  field GROUP_URL "GROUP_URL" "URL <a class=\"doc-link\" href=\"https://wiki.metacubex.one/ru/config/proxy-groups/#url\" target=\"_blank\" rel=\"noopener\">health-check</a>, если HEALTHCHECK_PROVIDER=false." "https://www.gstatic.com/generate_204" text "https://www.gstatic.com/generate_204"
  field GROUP_URL_STATUS "GROUP_URL_STATUS" "Ожидаемый <a class=\"doc-link\" href=\"https://wiki.metacubex.one/ru/config/proxy-groups/#expected-status\" target=\"_blank\" rel=\"noopener\">expected-status</a>." "204" number "204"
  select_field GROUP_STRATEGY "GROUP_STRATEGY" "Стратегия <a class=\"doc-link\" href=\"https://wiki.metacubex.one/ru/config/proxy-groups/#strategy\" target=\"_blank\" rel=\"noopener\">load-balance</a>: round-robin, consistent-hashing или sticky-sessions." "consistent-hashing" "round-robin consistent-hashing sticky-sessions"
  field GROUP_TOLERANCE "GROUP_TOLERANCE" "<a class=\"doc-link\" href=\"https://wiki.metacubex.one/ru/config/proxy-groups/#tolerance\" target=\"_blank\" rel=\"noopener\">Tolerance</a> для url-test." "20" number "20"
  field GROUP_FILTER "GROUP_FILTER" "Regex <a class=\"doc-link\" href=\"https://wiki.metacubex.one/ru/config/proxy-groups/#filter\" target=\"_blank\" rel=\"noopener\">filter</a> по умолчанию." "" text ""
  field GROUP_EXCLUDE "GROUP_EXCLUDE" "Regex <a class=\"doc-link\" href=\"https://wiki.metacubex.one/ru/config/proxy-groups/#exclude-filter\" target=\"_blank\" rel=\"noopener\">exclude-filter</a> по умолчанию." "" text ""
  printf '<label class="field field-validated" data-env="GROUP_EXCLUDE_TYPE" data-validate="exclude_type"><span><b>GROUP_EXCLUDE_TYPE</b><em>GROUP_EXCLUDE_TYPE</em></span><input type="text" name="GROUP_EXCLUDE_TYPE" value="%s" placeholder="vmess|direct" data-default=""><small><a class="doc-link" href="https://wiki.metacubex.one/ru/config/proxy-groups/#exclude-type" target="_blank" rel="noopener">exclude-type</a> по умолчанию через <code>|</code>. <a class="doc-link" href="https://github.com/MetaCubeX/mihomo/blob/fbead56ec97ae93f904f4476df1741af718c9c2a/constant/adapters.go#L18-L45" target="_blank" rel="noopener">Adapter Type</a>, регистр не важен. Пример: <code>vmess|direct</code>.</small><i>%s</i></label>\n' "$(env_attr GROUP_EXCLUDE_TYPE "")" "$(is_set GROUP_EXCLUDE_TYPE)"
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
  # Field layout (2-column grid):
  #   row 1: PROXIES | USE
  #   row 2: TYPE    | INTERVAL
  #   row 3: URL     | URL_STATUS
  #   row 4: STRATEGY| TOLERANCE
  #   row 5: FILTER  | EXCLUDE
  #   row 6: GEOSITE | GEOIP
  #   row 7: AS      | PRIORITY
  #   rest: DOMAIN, SUFFIX, KEYWORD, IPCIDR, SRCIPCIDR, DSCP, DNS
  printf '<label class="field field-validated" data-env="%s_PROXIES" data-validate="proxies"><span><b>Proxies</b><em>%s_PROXIES</em></span><input type="text" name="%s_PROXIES" value="%s" placeholder="DIRECT,REJECT,YOUTUBE" data-default=""><small>Явные <a class="doc-link" href="https://wiki.metacubex.one/ru/config/proxy-groups/#proxies" target="_blank" rel="noopener">proxies</a> через запятую: имена других прокси-групп (регистрозависимо) либо служебные <code>DIRECT</code>, <code>REJECT</code>, <code>REJECT-DROP</code>, <code>PASS</code>.</small><i>%s</i></label>\n' "$prefix" "$prefix" "$prefix" "$(env_attr "${prefix}_PROXIES" "")" "$(is_set "${prefix}_PROXIES")"
  printf '<label class="field field-validated" data-env="%s_USE" data-validate="use"><span><b>Use</b><em>%s_USE</em></span><input type="text" name="%s_USE" value="%s" placeholder="LINK1,SUB_LINK1,BYEDPI" data-default=""><small>Список <a class="doc-link" href="https://wiki.metacubex.one/ru/config/proxy-groups/#use" target="_blank" rel="noopener">providers</a> через запятую или <code>none</code>. Регистрозависимо. Имена берутся из LINK*/SUB_LINK*/SOCKS*/BYEDPI*/ZAPRET*/AWG-конфигов/proxies_mount.</small><i>%s</i></label>\n' "$prefix" "$prefix" "$prefix" "$(env_attr "${prefix}_USE" "")" "$(is_set "${prefix}_USE")"
  select_field "${prefix}_TYPE" "Type" "Тип <a class=\"doc-link\" href=\"https://wiki.metacubex.one/ru/config/proxy-groups/#type\" target=\"_blank\" rel=\"noopener\">proxy-groups type</a>." "$( [ "$prefix" = DNS ] && echo select || echo "$(env_default GROUP_TYPE select)" )" "select url-test load-balance fallback relay"
  field "${prefix}_INTERVAL" "Interval" "<a class=\"doc-link\" href=\"https://wiki.metacubex.one/ru/config/proxy-groups/#interval\" target=\"_blank\" rel=\"noopener\">Интервал</a> проверки в секундах. Пусто → наследует <code>GROUP_INTERVAL</code>." "" number ""
  field "${prefix}_URL" "URL" "URL <a class=\"doc-link\" href=\"https://wiki.metacubex.one/ru/config/proxy-groups/#url\" target=\"_blank\" rel=\"noopener\">health-check</a> для этой группы. Используется при HEALTHCHECK_PROVIDER=false и TYPE url-test/fallback/load-balance. Пусто → наследует <code>GROUP_URL</code>." "" text ""
  field "${prefix}_URL_STATUS" "URL status" "Ожидаемый <a class=\"doc-link\" href=\"https://wiki.metacubex.one/ru/config/proxy-groups/#expected-status\" target=\"_blank\" rel=\"noopener\">expected-status</a>. Пусто → наследует <code>GROUP_URL_STATUS</code>." "" number ""
  printf '<label class="field" data-env="%s_STRATEGY"><span><b>Strategy</b><em>%s_STRATEGY</em></span><select name="%s_STRATEGY" data-default=""><option value="" %s>— inherit GROUP_STRATEGY —</option><option value="round-robin" %s>round-robin</option><option value="consistent-hashing" %s>consistent-hashing</option><option value="sticky-sessions" %s>sticky-sessions</option></select><small><a class="doc-link" href="https://wiki.metacubex.one/ru/config/proxy-groups/load-balance/#strategy" target="_blank" rel="noopener">Стратегия</a> для load-balance. Пусто → наследует <code>GROUP_STRATEGY</code>.</small><i>%s</i></label>\n' "$prefix" "$prefix" "$prefix" \
    "$( [ -z "$(env_default "${prefix}_STRATEGY" "")" ] && echo selected )" \
    "$( [ "$(env_default "${prefix}_STRATEGY" "")" = "round-robin" ] && echo selected )" \
    "$( [ "$(env_default "${prefix}_STRATEGY" "")" = "consistent-hashing" ] && echo selected )" \
    "$( [ "$(env_default "${prefix}_STRATEGY" "")" = "sticky-sessions" ] && echo selected )" \
    "$(is_set "${prefix}_STRATEGY")"
  field "${prefix}_TOLERANCE" "Tolerance" "<a class=\"doc-link\" href=\"https://wiki.metacubex.one/ru/config/proxy-groups/url-test/#tolerance\" target=\"_blank\" rel=\"noopener\">Tolerance</a> для url-test в мс. Пусто → наследует <code>GROUP_TOLERANCE</code>." "" number ""
  field "${prefix}_FILTER" "Filter" "Regex <a class=\"doc-link\" href=\"https://wiki.metacubex.one/ru/config/proxy-groups/#filter\" target=\"_blank\" rel=\"noopener\">filter</a> по именам прокси." "" text ""
  field "${prefix}_EXCLUDE" "Exclude" "Regex <a class=\"doc-link\" href=\"https://wiki.metacubex.one/ru/config/proxy-groups/#exclude-filter\" target=\"_blank\" rel=\"noopener\">exclude-filter</a>." "" text ""
  printf '<label class="field field-validated" data-env="%s_EXCLUDE_TYPE" data-validate="exclude_type"><span><b>Exclude type</b><em>%s_EXCLUDE_TYPE</em></span><input type="text" name="%s_EXCLUDE_TYPE" value="%s" placeholder="vmess|direct" data-default=""><small><a class="doc-link" href="https://wiki.metacubex.one/ru/config/proxy-groups/#exclude-type" target="_blank" rel="noopener">exclude-type</a> — исключить прокси указанных типов, разделитель <code>|</code>. <a class="doc-link" href="https://github.com/MetaCubeX/mihomo/blob/fbead56ec97ae93f904f4476df1741af718c9c2a/constant/adapters.go#L18-L45" target="_blank" rel="noopener">Adapter Type</a>, регистр не важен. Пример: <code>vmess|direct</code>.</small><i>%s</i></label>\n' "$prefix" "$prefix" "$prefix" "$(env_attr "${prefix}_EXCLUDE_TYPE" "")" "$(is_set "${prefix}_EXCLUDE_TYPE")"
  field "${prefix}_ICON" "Icon" "URL <a class=\"doc-link\" href=\"https://wiki.metacubex.one/ru/config/proxy-groups/#icon\" target=\"_blank\" rel=\"noopener\">иконки</a> группы." "" text ""
  printf '<label class="field" data-env="%s_HIDDEN"><span><b>Hidden</b><em>%s_HIDDEN</em></span><select name="%s_HIDDEN" data-default=""><option value="" %s>— показать (default) —</option><option value="true" %s>true (скрыть из веб-панели)</option><option value="false" %s>false (показать)</option></select><small><a class="doc-link" href="https://wiki.metacubex.one/ru/config/proxy-groups/#hidden" target="_blank" rel="noopener">hidden</a> — скрыть/показать группу в веб-панели mihomo.</small><i>%s</i></label>\n' "$prefix" "$prefix" "$prefix" \
    "$( [ -z "$(env_default "${prefix}_HIDDEN" "")" ] && echo selected )" \
    "$( [ "$(env_default "${prefix}_HIDDEN" "")" = "true" ] && echo selected )" \
    "$( [ "$(env_default "${prefix}_HIDDEN" "")" = "false" ] && echo selected )" \
    "$(is_set "${prefix}_HIDDEN")"
  field "${prefix}_GEOSITE" "Geosite" "Правила <a class=\"doc-link\" href=\"https://wiki.metacubex.one/ru/config/rules/\" target=\"_blank\" rel=\"noopener\">GEOSITE</a> списком через запятую." "youtube,category-ru" text ""
  field "${prefix}_GEOIP" "Geoip" "Правила <a class=\"doc-link\" href=\"https://wiki.metacubex.one/ru/config/rules/\" target=\"_blank\" rel=\"noopener\">GEOIP</a> списком через запятую." "telegram,discord" text ""
  field "${prefix}_AS" "ASN" "Правила <a class=\"doc-link\" href=\"https://wiki.metacubex.one/ru/config/rules/\" target=\"_blank\" rel=\"noopener\">IP-ASN</a>: AS123,AS456." "AS15169" text ""
  field "${prefix}_PRIORITY" "Priority" "Чем меньше, тем выше в rules." "" number ""
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
  # Seed для JS-валидатора _USE / _PROXIES. Раньше сюда попадали только
  # серверные имена (AWG / proxies_mount), а LINK*/SUB_LINK*/SOCKS*/DPI имена
  # JS пытался достать из localStorage — но черновики этих ENV появляются
  # там только после первого визита пользователя на соответствующую страницу.
  # До этого валидатор ругался на «несуществующие» прокси. Теперь сервер
  # отдаёт полный список сразу.
  seed_awg=""
  if [ -d "$AWG_DIR" ]; then
    for f in "$AWG_DIR"/*.conf; do
      [ -f "$f" ] || continue
      name="$(basename "$f" .conf)"
      seed_awg="$seed_awg \"$(printf '%s' "$name" | h)\","
    done
  fi
  seed_mounted=""
  if [ -d "$PROXIES_DIR" ]; then
    for f in "$PROXIES_DIR"/*.yaml "$PROXIES_DIR"/*.yml; do
      [ -f "$f" ] || continue
      name="$(basename "$f")"
      name="${name%.yaml}"; name="${name%.yml}"
      seed_mounted="$seed_mounted \"$(printf '%s' "$name" | h)\","
    done
  fi
  # Interface DIRECT-providers: entrypoint enumerates up'ed ethernet ifaces
  # (см. entrypoint.sh "all interfaces") и пишет $RUNTIME_DIR/$iface.yaml с
  # `type: direct, interface-name: $iface`. Имя провайдера = имя интерфейса.
  # Без этого блока валидатор _USE ругался на ether-провайдеры как на
  # несуществующие.
  for iface in $(ip -o link show up 2>/dev/null | awk -F': ' '/link\/ether/ {gsub(/@.*$/,"",$2); if($2!="lo") print $2}'); do
    [ -n "$iface" ] || continue
    # entrypoint скипает интерфейс без kernel-route — yaml-провайдер не создаётся.
    route_line="$(ip route list dev "$iface" proto kernel scope link 2>/dev/null | head -n1)"
    [ -z "$route_line" ] && continue
    seed_mounted="$seed_mounted \"$(printf '%s' "$iface" | h)\","
  done
  seed_envs=""
  for prov in $(env | grep -E '^(LINK[0-9]*|SUB_LINK[0-9]+|SOCKS[0-9]+)=' | cut -d= -f1 | sort -V); do
    seed_envs="$seed_envs \"$(printf '%s' "$prov" | h)\","
  done
  # DPI имена: BYEDPI[N], ZAPRET[N], ZAPRET2[N] — без _CMD/_PACKETS.
  for dpi_var in $(env | grep -E '^(BYEDPI|ZAPRET|ZAPRET2)_CMD[0-9]*=' | cut -d= -f1 | sort -V); do
    base="$(printf '%s' "$dpi_var" | sed 's/_CMD//')"
    seed_envs="$seed_envs \"$(printf '%s' "$base" | h)\","
  done
  printf '<script id="known-providers-seed" type="application/json">{"awg":[%s],"mounted":[%s],"envs":[%s]}</script>\n' \
    "${seed_awg%,}" "${seed_mounted%,}" "${seed_envs%,}"
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
  section_start "Инструменты" "Конверторы и быстрые проверки для конфигов, подписок и строк прокси."
  cat <<'EOF'
<div class="tools-browser">
  <aside class="group-list tools-list" aria-label="Инструменты">
    <button type="button" class="active" data-tool-tab="b64enc"><b>Base64 encode</b><small>текст → base64</small></button>
    <button type="button" data-tool-tab="b64dec"><b>Base64 decode</b><small>base64 → текст</small></button>
    <button type="button" data-tool-tab="regex"><b>Regex test</b><small>проверка строк</small></button>
    <button type="button" data-tool-tab="xray"><b>Xray outbounds</b><small>JSON → proxy URI</small></button>
  </aside>
  <div class="tool-panes">
    <article class="tool-pane active" data-tool-pane="b64enc">
      <div class="group-pane-head">
        <label class="field"><span><b>Исходный текст</b><em>UTF-8</em></span><textarea id="toolB64Plain" rows="12" spellcheck="false" placeholder="Любой текст"></textarea></label>
      </div>
      <div class="bc-actions">
        <button type="button" onclick="toolCopy('toolB64Encoded', this)">Скопировать</button>
      </div>
      <label class="field field-wide"><span><b>Base64</b><em>результат</em></span><textarea id="toolB64Encoded" rows="8" readonly spellcheck="false"></textarea></label>
    </article>
    <article class="tool-pane" data-tool-pane="b64dec" hidden>
      <div class="group-pane-head">
        <label class="field"><span><b>Base64</b><em>standard / URL-safe</em></span><textarea id="toolB64Input" rows="10" spellcheck="false" placeholder="SGVsbG8="></textarea></label>
      </div>
      <div class="bc-actions">
        <button type="button" onclick="toolCopy('toolB64Decoded', this)">Скопировать</button>
      </div>
      <label class="field field-wide"><span><b>Текст</b><em>UTF-8</em></span><textarea id="toolB64Decoded" rows="10" readonly spellcheck="false"></textarea></label>
      <div class="tool-status" id="toolB64DecodeStatus"></div>
    </article>
    <article class="tool-pane" data-tool-pane="regex" hidden>
      <label class="field field-wide"><span><b>Regex</b><em>/pattern/flags или просто pattern</em></span><input id="toolRegexSource" spellcheck="false" placeholder="/^(https?:\/\/)?([a-z0-9-]+\.)*[a-z0-9-]+\.video(\/.*)?$/i"></label>
      <label class="field field-wide"><span><b>Строки для проверки</b><em>по одной в строке</em></span><textarea id="toolRegexText" rows="12" spellcheck="false" placeholder="Hong Kong 01&#10;Japan test&#10;RU direct"></textarea></label>
      <div class="tool-regex-rows" id="toolRegexRows"></div>
      <div class="tool-status" id="toolRegexStatus"></div>
    </article>
    <article class="tool-pane" data-tool-pane="xray" hidden>
      <details class="bc-tier-info">
        <summary>Пример вставки</summary>
        <div class="bc-tier-info-body">
          <p>Вставьте JSON целиком или объект с секцией <code>outbounds</code>. Конвертер берёт только <code>outbounds</code> и пробует собрать share-ссылки для поддерживаемых протоколов.</p>
          <pre><code>{
  "outbounds": [
    {
      "tag": "vless-reality",
      "protocol": "vless",
      "settings": {
        "vnext": [{
          "address": "example.com",
          "port": 443,
          "users": [{ "id": "UUID", "encryption": "none", "flow": "xtls-rprx-vision" }]
        }]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": { "serverName": "www.microsoft.com", "fingerprint": "chrome", "publicKey": "PUBLIC_KEY", "shortId": "SHORT_ID" }
      }
    }
  ]
}</code></pre>
        </div>
      </details>
      <label class="field field-wide"><span><b>Xray JSON</b><em>outbounds</em></span><textarea id="toolXrayJson" rows="18" spellcheck="false"></textarea></label>
      <div class="bc-actions">
        <button type="button" onclick="toolCopy('toolXrayLinks', this)">Скопировать все</button>
      </div>
      <textarea id="toolXrayLinks" class="tool-hidden-copy" readonly spellcheck="false"></textarea>
      <div class="tool-link-list" id="toolXrayCards"></div>
      <label class="field field-wide"><span><b>Диагностика</b><em>пропущенные outbounds и замечания</em></span><textarea id="toolXrayDiag" rows="8" readonly spellcheck="false"></textarea></label>
    </article>
  </div>
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
