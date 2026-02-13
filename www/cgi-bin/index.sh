#!/bin/sh

echo "Content-Type: text/html; charset=utf-8"
echo

# ===== helpers =====
env_val() {
  v="$(printenv "$1" 2>/dev/null)"
  [ -n "$v" ] && printf '%s' "$v"
}

checked() {
  [ "$1" = "true" ] && echo "checked"
}

selected() {
  [ "$1" = "$2" ] && echo "selected"
}

# ===== read ENV =====
EXTERNAL_UI_URL="$(env_val EXTERNAL_UI_URL)"
UI_SECRET="$(env_val UI_SECRET)"
LOG_LEVEL="$(env_val LOG_LEVEL)"
SNIFFER="$(env_val SNIFFER)"
TPROXY="$(env_val TPROXY)"

[ -z "$LOG_LEVEL" ] && LOG_LEVEL="error"
[ -z "$SNIFFER" ] && SNIFFER="true"
[ -z "$TPROXY" ] && TPROXY="true"

# ===== collect dynamic ENV =====
ALL_ENV="$(printenv)"

env_list() {
  echo "$ALL_ENV" | grep -E "^$1" | sort
}

LINK_ENVS="$(env_list 'LINK[0-9]+=')"
SUB_LINK_ENVS="$(env_list 'SUB_LINK[0-9]+=')"
SOCKS_ENVS="$(env_list 'SOCKS[0-9]+=')"

BYEDPI_ENVS="$(env_list 'BYEDPI_CMD')"
ZAPRET_ENVS="$(env_list 'ZAPRET_CMD')"
ZAPRET2_ENVS="$(env_list 'ZAPRET2_CMD')"

# mounted proxies
AWG_FILES="$(ls /root/.config/mihomo/awg 2>/dev/null)"
MOUNTED_PROXIES="$(ls /root/.config/mihomo/proxies_mount 2>/dev/null)"

# veth interfaces
VETHS="$(ip link 2>/dev/null | awk -F: '/veth/ {print $2}' | tr -d ' ')"

cat <<EOF
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<link rel="icon" href="/favicon.png">
<title>Mihomo Proxy ROS</title>
<link rel="stylesheet" href="/style.css">
<meta name="viewport" content="width=device-width, initial-scale=1">
</head>

<body data-theme="light">

<div class="topbar">
  <div class="logo">
    <img src="/favicon.png" alt="MetaCubeX">
    <div>
      <div class="title">mihomo-proxy-ros</div>
      <div class="subtitle">Веб конфигуратор ENVs</div>
    </div>
  </div>

  <div class="top-links">
    <label class="theme-switch">
      <input type="checkbox" id="themeToggle" onclick="toggleTheme()">
      <span class="slider">
        <span class="icon sun">☀️</span>
        <span class="icon moon">🌙</span>
      </span>
    </label>
    <a href="https://wiki.metacubex.one/ru/config/" target="_blank">Mihomo Docs</a>
    <a href="https://github.com/Medium1992/mihomo-proxy-ros/blob/main/README_RU.md" target="_blank">
      GitHub
    </a>
  </div>
</div>

<div class="toolbar">
  <button type="button" onclick="openConfig()">
    📄 Показать текущий config.yaml
  </button>
</div>

<main class="container">

<form method="GET" action="/cgi-bin/gen.sh">

<!-- ================= GENERAL ================= -->
<section class="card">
  <h2>⚙️ Общие настройки</h2>

  <p class="desc">
    Базовые параметры работы ядра <b>Mihomo</b> и веб-интерфейса управления.
  </p>

  <div class="field">
    <label>EXTERNAL_UI_URL</label>
    <input type="text" name="EXTERNAL_UI_URL"
      value="$EXTERNAL_UI_URL"
      placeholder="https://github.com/MetaCubeX/metacubexd/...">
    <small>
      Ссылка на web-интерфейс Mihomo (zip-архив).
      <a href="https://wiki.metacubex.one/ru/config/general/#url" target="_blank">
        Документация
      </a>
    </small>
  </div>

  <div class="field">
    <label>UI_SECRET</label>
    <input type="text" name="UI_SECRET"
      value="$UI_SECRET"
      placeholder="пароль">
    <small>
      Пароль доступа к web-интерфейсу Mihomo.
      <a href="https://wiki.metacubex.one/ru/config/sniff/" target="_blank">
        Документация
      </a>
    </small>
  </div>

  <div class="field">
    <label>LOG_LEVEL</label>
    <select name="LOG_LEVEL">
      <option value="silent"  $(selected "$LOG_LEVEL" silent)>silent</option>
      <option value="error"   $(selected "$LOG_LEVEL" error)>error</option>
      <option value="warning" $(selected "$LOG_LEVEL" warning)>warning</option>
      <option value="info"    $(selected "$LOG_LEVEL" info)>info</option>
      <option value="debug"   $(selected "$LOG_LEVEL" debug)>debug</option>
    </select>
    <small>
      Уровень логирования ядра Mihomo.
      <a href="https://wiki.metacubex.one/ru/config/general/#_5" target="_blank">
        Документация
      </a>
    </small>
  </div>

  <div class="switches">

    <label class="switch">
      <input type="checkbox" name="SNIFFER" value="true" $(checked "$SNIFFER")>
      <span></span>
      <div>
        <b>SNIFFER</b>
        <small>Обнаружение доменов (TLS / HTTP / QUIC)</small>
      </div>
    </label>

    <label class="switch">
      <input type="checkbox" name="TPROXY" value="true" $(checked "$TPROXY")>
      <span></span>
      <div>
        <b>TPROXY</b>
        <small>
          Вкл — inbound TProxy (TCP+UDP)<br>
          Выкл — inbound Redirect (TCP) + TUN (UDP)
        </small>
      </div>
    </label>

  </div>
</section>

<!-- ================= PROXY PROVIDERS ================= -->
<section class="card">
  <h2>📦 Прокси-провайдеры</h2>

  <p class="desc">
    Источники прокси-провайдеров, обнаруженные по ENV и примонтированным конфигурациям.
  </p>

  <!-- ===== Healthcheck ===== -->
<h3>🔍 Healthcheck параметры</h3>

<label class="switch">
    <input type="checkbox" name="HEALTHCHECK_PROVIDER" value="true"
        $(checked "$(env_val HEALTHCHECK_PROVIDER)")>
    <span></span>
    <div>
      <b>HEALTHCHECK_PROVIDER</b>
      <small>
      Вкл — Использовать health-check в прокси-провайдерах<br>
      Выкл — Использовать health-check в прокси-группах
      </small>
    </div>
</label>

  <div class="field">
    <label>HEALTHCHECK_INTERVAL (seconds)</label>
    <input type="number" name="HEALTHCHECK_INTERVAL"
      value="$(env_val HEALTHCHECK_INTERVAL)"
      placeholder="120">
  </div>

  <div class="field">
    <label>HEALTHCHECK_URL</label>
    <input type="text" name="HEALTHCHECK_URL"
      value="$(env_val HEALTHCHECK_URL)"
      placeholder="https://www.gstatic.com/generate_204">
  </div>

  <div class="field">
    <label>HEALTHCHECK_URL_STATUS</label>
    <input type="number" name="HEALTHCHECK_URL_STATUS"
      value="$(env_val HEALTHCHECK_URL_STATUS)"
      placeholder="204">
  </div>

  <div class="field">
    <label>HEALTHCHECK_URL_BYEDPI</label>
    <input type="text" name="HEALTHCHECK_URL_BYEDPI"
      value="$(env_val HEALTHCHECK_URL_BYEDPI)"
      placeholder="https://www.facebook.com">
  </div>

  <div class="field">
    <label>HEALTHCHECK_URL_STATUS_BYEDPI</label>
    <input type="number" name="HEALTHCHECK_URL_STATUS_BYEDPI"
      value="$(env_val HEALTHCHECK_URL_STATUS_BYEDPI)"
      placeholder="200">
  </div>

  <div class="field">
    <label>HEALTHCHECK_URL_ZAPRET</label>
    <input type="text" name="HEALTHCHECK_URL_ZAPRET"
      value="$(env_val HEALTHCHECK_URL_ZAPRET)"
      placeholder="https://www.facebook.com">
  </div>

  <div class="field">
    <label>HEALTHCHECK_URL_STATUS_ZAPRET</label>
    <input type="number" name="HEALTHCHECK_URL_STATUS_ZAPRET"
      value="$(env_val HEALTHCHECK_URL_STATUS_ZAPRET)"
      placeholder="200">
  </div>

  <hr>
EOF
cat <<EOF
  <!-- ===== Detected providers ===== -->
  <h3>📋 Считанные ENV прокси</h3>
<div class="provider-list">

<div class="provider-group">
    <h4>Ссылки прокси</h4>

    <button type="button" class="btn-primary" onclick="addLink()">
      ➕ Добавить ссылку
    </button>
  <div id="linksContainer">
EOF

echo "$LINK_ENVS" | while IFS='=' read -r k v; do
  idx="${k#LINK}"

  dialer_var="LINK${idx}_DIALER_PROXY"
  dialer_value="$(env_val "$dialer_var")"

  printf '%s\n' "
    <div class=\"link-item\" data-index=\"$idx\">
      <span class=\"link-label\">$k</span>
      <input type=\"text\" name=\"$k\" value=\"$v\" placeholder=\"vless://... or vmess://... or ss://... or trojan://... or BASE64\">
      
      <button type=\"button\" class=\"btn-settings\" title=\"Задать dialer-proxy\" onclick=\"toggleDialer(this)\">⚙</button>
      <button type=\"button\" class=\"btn-remove\" onclick=\"removeItem(this)\">×</button>

      <div class=\"dialer-container\">
        <span class=\"dialer-label\">${k}_DIALER_PROXY</span>
        <input type=\"text\" 
               name=\"${k}_DIALER_PROXY\" 
               placeholder=\"например: GLOBAL, main-chain, proxy-a\"
               value=\"$dialer_value\">
      </div>
    </div>
  "
done

cat <<EOF
  </div>
</div>

<div class="provider-group">
  <h4>Подписки (Subscriptions)</h4>

  <button type="button" class="btn-primary" onclick="addSubLink()">
    ➕ Добавить подписку
  </button>

  <div id="subLinksContainer">
EOF

# Цикл SUB_LINK — отдельно, без вложенности
echo "$SUB_LINK_ENVS" | while IFS='=' read -r k v; do
  idx="${k#SUB_LINK}"

  dialer_var="SUB_LINK${idx}_DIALER_PROXY"
  proxy_var="SUB_LINK${idx}_PROXY"
  headers_var="SUB_LINK${idx}_HEADERS"
  interval_var="SUB_LINK${idx}_INTERVAL"

  dialer_value="$(env_val "$dialer_var")"
  proxy_value="$(env_val "$proxy_var")"
  headers_value="$(env_val "$headers_var")"
  interval_value="$(env_val "$interval_var")"

  printf '%s\n' "
    <div class=\"link-item\" data-index=\"$idx\">
      <span class=\"link-label\">$k</span>
      <input type=\"text\" name=\"$k\" value=\"$v\" placeholder=\"https://... или http://... (подписка)\">

      <button type=\"button\" class=\"btn-settings\" title=\"Дополнительные параметры подписки\" onclick=\"toggleSubDialer(this)\">⚙</button>
      <button type=\"button\" class=\"btn-remove\" onclick=\"removeItem(this)\">×</button>

      <div class=\"dialer-container sub-dialer\">
        <div class=\"dialer-row\">
          <span class=\"dialer-label\">${k}_INTERVAL</span>
          <input type=\"number\" name=\"SUB_LINK${idx}_INTERVAL\" placeholder=\"3600 (сек)\" min=\"60\" value=\"$interval_value\">
        </div>
        <div class=\"dialer-row\">
          <span class=\"dialer-label\">${k}_HEADERS</span>
          <input type=\"text\" name=\"SUB_LINK${idx}_HEADERS\" placeholder=\"x-hwid=xxx#user-agent=xxx#x-ver-os=xxx\" value=\"$headers_value\">
        </div>
        <div class=\"dialer-row\">
          <span class=\"dialer-label\">${k}_PROXY</span>
          <input type=\"text\" name=\"SUB_LINK${idx}_PROXY\" placeholder=\"proxies1, socks5-1\" value=\"$proxy_value\">
        </div>
        <div class=\"dialer-row\">
          <span class=\"dialer-label\">${k}_DIALER_PROXY</span>
          <input type=\"text\" name=\"SUB_LINK${idx}_DIALER_PROXY\" placeholder=\"GLOBAL, main-chain, proxy-a\" value=\"$dialer_value\">
        </div>
      </div>
    </div>
  "
done

cat <<EOF
  </div>
</div>

<div class="provider-group">
  <h4>BYEDPI стратегии</h4>

  <button type="button" class="btn-primary" onclick="addByedpi()">
    ➕ Добавить стратегию
  </button>

  <div id="byedpiContainer">
EOF

if printenv BYEDPI_CMD > /dev/null; then
  k="BYEDPI_CMD"
  v="$(env_val "$k")"

  cat <<EOF
    <div class="link-item" data-index="0">
      <span class="link-label">$k</span>
      <input type="text" name="$k" value="$v" placeholder="--ip=127.0.0.1 --port=8080 ...">

      <button type="button" class="btn-remove" onclick="removeItem(this)">×</button>
    </div>
EOF
fi

echo "$BYEDPI_ENVS" | grep 'BYEDPI_CMD[1-9]' | sort -V | while IFS='=' read -r k v; do
  idx="${k#BYEDPI_CMD}"

  cat <<EOF
    <div class="link-item" data-index="$idx">
      <span class="link-label">$k</span>
      <input type="text" name="$k" value="$v" placeholder="--ip=127.0.0.1 --port=8080 ...">

      <button type="button" class="btn-remove" onclick="removeItem(this)">×</button>
    </div>
EOF
done

cat <<EOF
  </div>
</div>

<div class="provider-group">
  <h4>ZAPRET стратегии</h4>

  <div class="field">
    <label>ZAPRET_PACKETS (global)</label>
    <input type="text" name="ZAPRET_PACKETS"
      value="$(env_val ZAPRET_PACKETS)"
      placeholder="packets list (global)">
    <small>Глобальные packets для всех ZAPRET стратегий</small>
  </div>

  <button type="button" class="btn-primary" onclick="addZapret()">

    ➕ Добавить стратегию ZAPRET
  </button>

  <div id="zapretContainer">
EOF

# Сначала ZAPRET_CMD если есть (индекс 0)
if printenv ZAPRET_CMD > /dev/null; then
  k="ZAPRET_CMD"
  v="$(env_val "$k")"
  packets_var="ZAPRET_PACKETS0"
  packets_value="$(env_val "$packets_var")"

  cat <<EOF
    <div class="link-item" data-index="0">
      <span class="link-label">$k</span>
      <input type="text" name="$k" value="$v" placeholder="--param1=value1 --param2=value2 ...">

      <button type="button" class="btn-settings" title="Zadать PACKETS" onclick="toggleDialer(this)">⚙</button>
      <button type="button" class="btn-remove" onclick="removeItem(this)">×</button>

      <div class="dialer-container">
        <span class="dialer-label">ZAPRET_PACKETS0</span>
        <input type="text" name="ZAPRET_PACKETS" placeholder="packets list" value="$packets_value">
      </div>
    </div>
EOF
fi

# Затем остальные ZAPRET_CMD1... sorted
echo "$ZAPRET_ENVS" | grep 'ZAPRET_CMD[1-9]' | sort -V | while IFS='=' read -r k v; do
  idx="${k#ZAPRET_CMD}"
  packets_var="ZAPRET_PACKETS${idx}"
  packets_value="$(env_val "$packets_var")"

  cat <<EOF
    <div class="link-item" data-index="$idx">
      <span class="link-label">$k</span>
      <input type="text" name="$k" value="$v" placeholder="--param1=value1 --param2=value2 ...">

      <button type="button" class="btn-settings" title="Zadать PACKETS" onclick="toggleDialer(this)">⚙</button>
      <button type="button" class="btn-remove" onclick="removeItem(this)">×</button>

      <div class="dialer-container">
        <span class="dialer-label">ZAPRET_PACKETS${idx}</span>
        <input type="text" name="ZAPRET_PACKETS${idx}" placeholder="packets list" value="$packets_value">
      </div>
    </div>
EOF
done

cat <<EOF
  </div>
</div>
EOF

cat <<EOF
<div class="provider-group">
  <h4>ZAPRET2 стратегии</h4>

  <div class="field">
    <label>ZAPRET2_PACKETS (global)</label>
    <input type="text" name="ZAPRET2_PACKETS"
      value="$(env_val ZAPRET2_PACKETS)"
      placeholder="packets list (global)">
    <small>Глобальные packets для всех ZAPRET2 стратегий</small>
  </div>

  <button type="button" class="btn-primary" onclick="addZapret2()">
    ➕ Добавить стратегию ZAPRET2
  </button>

  <div id="zapret2Container">
EOF

# Сначала ZAPRET2_CMD если есть (индекс 0)
if printenv ZAPRET2_CMD > /dev/null; then
  k="ZAPRET2_CMD"
  v="$(env_val "$k")"
  packets_var="ZAPRET2_PACKETS0"
  packets_value="$(env_val "$packets_var")"

  cat <<EOF
    <div class="link-item" data-index="0">
      <span class="link-label">$k</span>
      <input type="text" name="$k" value="$v" placeholder="--param1=value1 --param2=value2 ...">

      <button type="button" class="btn-settings" title="Zadать PACKETS" onclick="toggleDialer(this)">⚙</button>
      <button type="button" class="btn-remove" onclick="removeItem(this)">×</button>

      <div class="dialer-container">
        <span class="dialer-label">ZAPRET2_PACKETS0</span>
        <input type="text" name="ZAPRET2_PACKETS" placeholder="packets list" value="$packets_value">
      </div>
    </div>
EOF
fi

# Затем остальные ZAPRET2_CMD1... sorted
echo "$ZAPRET2_ENVS" | grep 'ZAPRET2_CMD[1-9]' | sort -V | while IFS='=' read -r k v; do
  idx="${k#ZAPRET2_CMD}"
  packets_var="ZAPRET2_PACKETS${idx}"
  packets_value="$(env_val "$packets_var")"

  cat <<EOF
    <div class="link-item" data-index="$idx">
      <span class="link-label">$k</span>
      <input type="text" name="$k" value="$v" placeholder="--param1=value1 --param2=value2 ...">

      <button type="button" class="btn-settings" title="Задать PACKETS" onclick="toggleDialer(this)">⚙</button>
      <button type="button" class="btn-remove" onclick="removeItem(this)">×</button>

      <div class="dialer-container">
        <span class="dialer-label">ZAPRET2_PACKETS${idx}</span>
        <input type="text" name="ZAPRET2_PACKETS${idx}" placeholder="packets list" value="$packets_value">
      </div>
    </div>
EOF
done

cat <<EOF
  </div>
</div>

<div class="provider-group">
  <h4>Mounted (AWG)</h4>
  <pre>$AWG_FILES</pre>
</div>

<div class="provider-group">
  <h4>Mounted (proxies_mount)</h4>
  <pre>$MOUNTED_PROXIES</pre>
</div>

<div class="provider-group">
  <h4>VETH interfaces</h4>
  <pre>$VETHS</pre>
</div>

</div>
</section>

<div class="toolbar" style="margin-top: 32px; text-align: center;">
  <button type="button" class="cmd-btn" onclick="generateCommands()">
    ⚡ Сгенерировать команды для терминала
  </button>
</div>

<div id="commandsOutput" class="card" style="margin-top: 32px; display: none;">
  <h3>Готовые команды для терминала</h3>
  <p>
    Скопируйте и вставьте эти команды в терминал MikroTik, затем перезапустите контейнер:
  </p>
  <pre id="commandsText"></pre>
  <div style="margin-top: 20px; text-align: right;">
    <button type="button" id="copyBtn" class="btn-primary" onclick="copyCommands()">
      📋 Скопировать команды
    </button>
  </div>
</div>
EOF

cat <<'EOF'
</form>
</main>

<div id="configModal" class="modal hidden">
  <div class="modal-content">
    <div class="modal-header">
      <h3>Текущий config.yaml</h3>
      <button type="button" onclick="closeConfig()">✕</button>
    </div>

    <div class="modal-warning">
      ⚠️ Конфигурация сформирована из <b>текущих ENV контейнера</b>.<br>
      Изменения в форме ниже <b>не применены</b>.
    </div>

    <textarea id="configContent"
          class="config-textarea"
          readonly
          spellcheck="false">Загрузка…</textarea>

  </div>
</div>

<script>
/* ===== Config modal ===== */
function openConfig() {
  const modal = document.getElementById('configModal');
  const ta = document.getElementById('configContent');

  modal.classList.remove('hidden');

  fetch('/cgi-bin/show_config.sh')
    .then(r => r.text())
    .then(t => {
      ta.value = t;
      ta.focus();
    });
}

function closeConfig() {
  document.getElementById('configModal').classList.add('hidden');
}

/* ===== Theme toggle ===== */
function toggleTheme() {
  const body = document.body;
  const checkbox = document.getElementById('themeToggle');

  const theme = checkbox.checked ? 'dark' : 'light';
  body.setAttribute('data-theme', theme);
  localStorage.setItem('theme', theme);
}

let linkIndex = document.querySelectorAll('#linksContainer .link-item').length;

document.addEventListener('DOMContentLoaded', () => {
  const saved = localStorage.getItem('theme') || 'light';
  document.body.setAttribute('data-theme', saved);

  const checkbox = document.getElementById('themeToggle');
  checkbox.checked = saved === 'dark';

  linkIndex = document.querySelectorAll('#linksContainer .link-item').length;
});

function getUsedIndexes() {
  return Array.from(document.querySelectorAll('#linksContainer .link-item'))
    .map(el => parseInt(el.dataset.index, 10))
    .filter(n => !isNaN(n))
    .sort((a, b) => a - b);
}

function getNextFreeIndex() {
  const used = getUsedIndexes();
  let i = 0;
  for (; i < used.length; i++) {
    if (used[i] !== i) break;
  }
  return i;
}

function removeItem(btn) {
  btn.closest('.link-item').remove();
}

function addLink() {
  const container = document.getElementById('linksContainer');
  const index = getNextFreeIndex();

  const div = document.createElement('div');
  div.className = 'link-item';
  div.dataset.index = index;

  div.innerHTML = `
    <span class="link-label">LINK${index}</span>
    <input type="text" name="LINK${index}" placeholder="vless://... или vmess://... или ss://... или trojan://... или BASE64">
    <button type="button" class="btn-settings" title="Задать dialer-proxy" onclick="toggleDialer(this)">⚙</button>
    <button type="button" class="btn-remove" onclick="removeItem(this)">×</button>

    <div class="dialer-container">
      <span class="dialer-label">LINK${index}_DIALER_PROXY</span>
      <input type="text" 
            name="LINK${index}_DIALER_PROXY" 
            placeholder="например: GLOBAL, main-chain, proxy-a"
            value="">
    </div>
  `;

  // вставляем с учётом сортировки по индексу
  const items = Array.from(container.children);
  const insertBefore = items.find(el => parseInt(el.dataset.index || 9999, 10) > index);

  if (insertBefore) {
    container.insertBefore(div, insertBefore);
  } else {
    container.appendChild(div);
  }
  const newBtn = div.querySelector('.btn-settings');
  const newInput = div.querySelector('input[name$="_DIALER_PROXY"]');
  if (newBtn && newInput) {
    updateDialerIndicator(newBtn, newInput.value.trim());
    newInput.addEventListener('input', () => {
      updateDialerIndicator(newBtn, newInput.value.trim());
    });
  }
}

function toggleDialer(btn) {
  const item = btn.closest('.link-item');
  const dialer = item.querySelector('.dialer-container');
  const input = dialer.querySelector('input');

  // Закрываем все остальные выпадашки
  document.querySelectorAll('.dialer-container.visible').forEach(d => {
    if (d !== dialer) d.classList.remove('visible');
  });

  dialer.classList.toggle('visible');

  if (dialer.classList.contains('visible')) {
    input.focus();
    input.select();
  }

  // Обновляем индикатор шестерёнки
  updateDialerIndicator(btn, input.value.trim());
}

// Функция обновления цвета шестерёнки
function updateDialerIndicator(btn, value) {
  if (value.trim()) {
    btn.classList.add('filled');
  } else {
    btn.classList.remove('filled');
  }
}

// При загрузке страницы — добавить dialer-поля ко всем существующим LINK-ам
document.addEventListener('DOMContentLoaded', () => {
  // ... твой существующий код ...

  // Добавляем dialer-поля к уже существующим LINK-ам
  document.querySelectorAll('#linksContainer .link-item').forEach(item => {
    const btn = item.querySelector('.btn-settings');
    const input = item.querySelector('input[name$="_DIALER_PROXY"]');
    if (!btn || !input) return;

    // Начальный цвет шестерёнки
    updateDialerIndicator(btn, input.value.trim());

    // Слушатель на ввод
    input.addEventListener('input', () => {
      updateDialerIndicator(btn, input.value.trim());
    });
  });
});

document.addEventListener('DOMContentLoaded', () => {
  document.querySelectorAll('#zapretContainer .link-item, #zapret2Container .link-item')
    .forEach(item => {
      const btn = item.querySelector('.btn-settings');
      const input = item.querySelector('.dialer-container input');
      if (!btn || !input) return;

      updateDialerIndicator(btn, input.value.trim());

      input.addEventListener('input', () => {
        updateDialerIndicator(btn, input.value.trim());
      });
    });
});

function generateCommands() {
  let cmds = [];

  // Global ZAPRET packets
  const zapretGlobal = document.querySelector('input[name="ZAPRET_PACKETS"]');
  if (zapretGlobal?.value.trim()) {
    const v = zapretGlobal.value.trim().replace(/(["\\])/g, '\\$1');
    cmds.push(`set container envs mihomo-proxy-ros ZAPRET_PACKETS "${v}"`);
  }

  // Global ZAPRET2 packets
  const zapret2Global = document.querySelector('input[name="ZAPRET2_PACKETS"]');
  if (zapret2Global?.value.trim()) {
    const v = zapret2Global.value.trim().replace(/(["\\])/g, '\\$1');
    cmds.push(`set container envs mihomo-proxy-ros ZAPRET2_PACKETS "${v}"`);
  }

  document.querySelectorAll('#linksContainer .link-item').forEach(item => {
    const index = item.dataset.index;
    if (!index) return;

    const linkInput = item.querySelector(`input[name="LINK${index}"]`);
    const dialerInput = item.querySelector(`input[name="LINK${index}_DIALER_PROXY"]`);

    if (linkInput?.value.trim()) {
      const value = linkInput.value.trim().replace(/(["\\])/g, '\\$1');
      cmds.push(`set container envs mihomo-proxy-ros LINK${index} "${value}"`);
    }

    if (dialerInput?.value.trim()) {
      const dialer = dialerInput.value.trim().replace(/(["\\])/g, '\\$1');
      cmds.push(`set container envs mihomo-proxy-ros LINK${index}_DIALER_PROXY "${dialer}"`);
    }
  });

  // BYEDPI стратегии
  document.querySelectorAll('#byedpiContainer .link-item').forEach(item => {
    const index = item.dataset.index;
    const key = (index === 0) ? 'BYEDPI_CMD' : `BYEDPI_CMD${index}`;
    const input = item.querySelector(`input[name="${key}"]`);

    if (input?.value.trim()) {
      const value = input.value.trim().replace(/(["\\])/g, '\\$1');
      cmds.push(`set container envs mihomo-proxy-ros ${key} "${value}"`);
    }
  });

  // ZAPRET стратегии
  document.querySelectorAll('#zapretContainer .link-item').forEach(item => {
    const index = item.dataset.index;
    const cmdKey = (index === 0) ? 'ZAPRET_CMD' : `ZAPRET_CMD${index}`;
    const packetsKey = `ZAPRET_PACKETS${index}`;

    const cmdInput = item.querySelector(`input[name="${cmdKey}"]`);
    const packetsInput = item.querySelector(`input[name="${packetsKey}"]`);

    if (cmdInput?.value.trim()) {
      const value = cmdInput.value.trim().replace(/(["\\])/g, '\\$1');
      cmds.push(`set container envs mihomo-proxy-ros ${cmdKey} "${value}"`);
    }

    if (packetsInput?.value.trim()) {
      const value = packetsInput.value.trim().replace(/(["\\])/g, '\\$1');
      cmds.push(`set container envs mihomo-proxy-ros ${packetsKey} "${value}"`);
    }
  });

  // ZAPRET2 стратегии
  document.querySelectorAll('#zapret2Container .link-item').forEach(item => {
    const index = item.dataset.index;
    const cmdKey = (index === 0) ? 'ZAPRET2_CMD' : `ZAPRET2_CMD${index}`;
    const packetsKey = `ZAPRET2_PACKETS${index}`;

    const cmdInput = item.querySelector(`input[name="${cmdKey}"]`);
    const packetsInput = item.querySelector(`input[name="${packetsKey}"]`);

    if (cmdInput?.value.trim()) {
      const value = cmdInput.value.trim().replace(/(["\\])/g, '\\$1');
      cmds.push(`set container envs mihomo-proxy-ros ${cmdKey} "${value}"`);
    }

    if (packetsInput?.value.trim()) {
      const value = packetsInput.value.trim().replace(/(["\\])/g, '\\$1');
      cmds.push(`set container envs mihomo-proxy-ros ${packetsKey} "${value}"`);
    }
  });

  let output = "# Команды для обновления ENV контейнера mihomo-proxy-ros\n";
  output += "# Вставьте в терминал MikroTik\n\n";

  if (cmds.length === 0) {
    output += "# Нет изменений или пустые поля\n";
  } else {
    output += cmds.join("\n") + "\n\n";
    output += "# После выполнения:\n";
    output += "/container restart [find where name=mihomo-proxy-ros]\n";
  }

  const outputBlock = document.getElementById('commandsOutput');
  const textArea = document.getElementById('commandsText');

  textArea.textContent = output;
  outputBlock.style.display = 'block';
  outputBlock.scrollIntoView({ behavior: 'smooth', block: 'center' });
}

function copyCommands() {
  const btn = document.getElementById('copyBtn');
  if (!btn) return;

  const originalText = btn.textContent.trim();
  const textElement = document.getElementById('commandsText');
  const text = textElement?.textContent || '';

  if (!text.trim()) {
    btn.textContent = '⚠️ Нет текста';
    setTimeout(() => { btn.textContent = originalText; }, 2000);
    return;
  }

  // Пытаемся скопировать (fallback всегда работает на HTTP)
  const textArea = document.createElement('textarea');
  textArea.value = text;
  textArea.style.position = 'fixed';
  textArea.style.top = '0';
  textArea.style.left = '0';
  textArea.style.opacity = '0';
  document.body.appendChild(textArea);
  textArea.focus();
  textArea.select();

  try {
    const successful = document.execCommand('copy');
    if (successful) {
      btn.textContent = '✅ Скопировано!';
      setTimeout(() => {
        btn.textContent = originalText;
      }, 2000);
    } else {
      btn.textContent = '❌ Не скопировалось';
      setTimeout(() => { btn.textContent = originalText; }, 2000);
    }
  } catch (err) {
    btn.textContent = '❌ Ошибка';
    setTimeout(() => { btn.textContent = originalText; }, 2000);
  }

  document.body.removeChild(textArea);
}

// ================= SUB LINKS =================

let subLinkIndex = 0; // будет пересчитан

function addSubLink() {
  const container = document.getElementById('subLinksContainer');
  const index = getNextFreeSubIndex();

  const div = document.createElement('div');
  div.className = 'link-item';
  div.dataset.index = index;

  div.innerHTML = `
    <span class="link-label">SUB_LINK${index}</span>
    <input type="text" name="SUB_LINK${index}" placeholder="https://... или http://... (подписка)">

    <button type="button" class="btn-settings" title="Дополнительные параметры подписки" onclick="toggleSubDialer(this)">⚙</button>
    <button type="button" class="btn-remove" onclick="removeItem(this)">×</button>

    <div class="dialer-container sub-dialer">
      <div class="dialer-row">
        <span class="dialer-label">SUB_LINK${index}_INTERVAL</span>
        <input type="number" name="SUB_LINK${index}_INTERVAL" placeholder="3600 (сек)" min="60">
      </div>
      <div class="dialer-row">
        <span class="dialer-label">SUB_LINK${index}_HEADERS</span>
        <input type="text" name="SUB_LINK${index}_HEADERS" placeholder="x-hwid=xxx#user-agent=xxx#x-ver-os=xxx">
      </div>
      <div class="dialer-row">
        <span class="dialer-label">SUB_LINK${index}_PROXY</span>
        <input type="text" name="SUB_LINK${index}_PROXY" placeholder="proxies1, socks5-1">
      </div>
      <div class="dialer-row">
        <span class="dialer-label">SUB_LINK${index}_DIALER_PROXY</span>
        <input type="text" name="SUB_LINK${index}_DIALER_PROXY" placeholder="GLOBAL, main-chain, proxy-a">
      </div>
    </div>
  `;

  const items = Array.from(container.children);
  const insertBefore = items.find(el => parseInt(el.dataset.index || 9999, 10) > index);
  if (insertBefore) {
    container.insertBefore(div, insertBefore);
  } else {
    container.appendChild(div);
  }

  const btn = div.querySelector('.btn-settings');
  updateSubDialerIndicator(btn);

  const inputs = div.querySelectorAll('input[name^="SUB_LINK"][name$="_DIALER_PROXY"], input[name$="_PROXYDIRECT"], input[name$="_HEADERS"], input[name$="_INTERVAL"]');
  inputs.forEach(inp => inp.addEventListener('input', () => updateSubDialerIndicator(btn)));
}

function updateSubDialerIndicator(btn) {
  const item = btn.closest('.link-item');
  const inputs = item.querySelectorAll('input[name^="SUB_LINK"][name$="_DIALER_PROXY"], input[name$="_PROXYDIRECT"], input[name$="_HEADERS"], input[name$="_INTERVAL"]');

  let hasValue = false;
  inputs.forEach(inp => {
    if (inp.value.trim()) hasValue = true;
  });

  btn.classList.toggle('filled', hasValue);
}

function toggleSubDialer(btn) {
  const item = btn.closest('.link-item');
  const dialer = item.querySelector('.dialer-container');

  document.querySelectorAll('.dialer-container.visible').forEach(d => {
    if (d !== dialer) d.classList.remove('visible');
  });

  dialer.classList.toggle('visible');

  if (dialer.classList.contains('visible')) {
    dialer.querySelector('input').focus();
  }
}

function getNextFreeSubIndex() {
  const used = Array.from(document.querySelectorAll('#subLinksContainer .link-item'))
    .map(el => parseInt(el.dataset.index, 10))
    .filter(n => !isNaN(n))
    .sort((a, b) => a - b);

  let i = 0;
  while (used.includes(i)) i++;
  return i;
}

// Инициализация существующих SUB_LINK
document.addEventListener('DOMContentLoaded', () => {
  // ... твой код для LINK ...

  // Для SUB_LINK — загрузка и инициализация
  document.querySelectorAll('#subLinksContainer .link-item').forEach(item => {
    const btn = item.querySelector('.btn-settings');
    if (!btn) return;

    updateSubDialerIndicator(btn);

    const inputs = item.querySelectorAll('input[name^="SUB_LINK"][name$="_DIALER_PROXY"], input[name$="_PROXYDIRECT"], input[name$="_HEADERS"], input[name$="_INTERVAL"]');
    inputs.forEach(inp => {
      inp.addEventListener('input', () => updateSubDialerIndicator(btn));
    });
  });

  subLinkIndex = document.querySelectorAll('#subLinksContainer .link-item').length;
});

// ================= BYEDPI =================

function addByedpi() {
  const container = document.getElementById('byedpiContainer');
  const index = getNextFreeByedpiIndex();

  const key = (index === 0) ? 'BYEDPI_CMD' : `BYEDPI_CMD${index}`;

  const div = document.createElement('div');
  div.className = 'link-item';
  div.dataset.index = index;

  div.innerHTML = `
    <span class="link-label">${key}</span>
    <input type="text" name="${key}" placeholder="--ip=127.0.0.1 --port=8080 ...">

    <button type="button" class="btn-remove" onclick="removeItem(this)">×</button>
  `;

  // Вставка с сортировкой по индексу (как в LINK)
  const items = Array.from(container.children);
  const insertBefore = items.find(el => parseInt(el.dataset.index || 9999, 10) > index);

  if (insertBefore) {
    container.insertBefore(div, insertBefore);
  } else {
    container.appendChild(div);
  }
}

function getNextFreeByedpiIndex() {
  const used = Array.from(document.querySelectorAll('#byedpiContainer .link-item'))
    .map(el => parseInt(el.dataset.index, 10))
    .filter(n => !isNaN(n))
    .sort((a, b) => a - b);

  let i = 0;
  while (used.includes(i)) i++;
  return i;
}

// ================= ZAPRET =================

function addZapret() {
  const container = document.getElementById('zapretContainer');
  const index = getNextFreeZapretIndex();

  const cmdKey = (index === 0) ? 'ZAPRET_CMD' : `ZAPRET_CMD${index}`;
  const packetsKey = `ZAPRET_PACKETS${index}`;

  const div = document.createElement('div');
  div.className = 'link-item';
  div.dataset.index = index;

  div.innerHTML = `
    <span class="link-label">${cmdKey}</span>
    <input type="text" 
           name="${cmdKey}" 
           placeholder="--param1=value1 --param2=value2 ...">

    <button type="button" class="btn-settings" title="Zadать PACKETS" onclick="toggleDialer(this)">⚙</button>
    <button type="button" class="btn-remove" onclick="removeItem(this)">×</button>

    <div class="dialer-container">
      <span class="dialer-label">${packetsKey}</span>
      <input type="text" name="${packetsKey}" placeholder="packets list">
    </div>
  `;

  const items = Array.from(container.children);
  const insertBefore = items.find(el => parseInt(el.dataset.index || 9999, 10) > index);
  if (insertBefore) {
    container.insertBefore(div, insertBefore);
  } else {
    container.appendChild(div);
  }

  const btn = div.querySelector('.btn-settings');
  const input = div.querySelector('input[name^="' + packetsKey + '"]');
  updateDialerIndicator(btn, input.value.trim());
  input.addEventListener('input', () => updateDialerIndicator(btn, input.value.trim()));
}

function getNextFreeZapretIndex() {
  const used = Array.from(document.querySelectorAll('#zapretContainer .link-item'))
    .map(el => parseInt(el.dataset.index, 10))
    .filter(n => !isNaN(n))
    .sort((a, b) => a - b);

  let i = 0;
  while (used.includes(i)) i++;
  return i;
}

// ================= ZAPRET2 =================

function addZapret2() {
  const container = document.getElementById('zapret2Container');
  const index = getNextFreeZapret2Index();

  const cmdKey = (index === 0) ? 'ZAPRET2_CMD' : `ZAPRET2_CMD${index}`;
  const packetsKey = `ZAPRET2_PACKETS${index}`;

  const div = document.createElement('div');
  div.className = 'link-item';
  div.dataset.index = index;

  div.innerHTML = `
    <span class="link-label">${cmdKey}</span>
    <input type="text" 
           name="${cmdKey}" 
           placeholder="--param1=value1 --param2=value2 ...">

    <button type="button" class="btn-settings" title="Zadать PACKETS" onclick="toggleDialer(this)">⚙</button>
    <button type="button" class="btn-remove" onclick="removeItem(this)">×</button>

    <div class="dialer-container">
      <span class="dialer-label">${packetsKey}</span>
      <input type="text" name="${packetsKey}" placeholder="packets list">
    </div>
  `;

  const items = Array.from(container.children);
  const insertBefore = items.find(el => parseInt(el.dataset.index || 9999, 10) > index);
  if (insertBefore) {
    container.insertBefore(div, insertBefore);
  } else {
    container.appendChild(div);
  }

  const btn = div.querySelector('.btn-settings');
  const input = div.querySelector('input[name^="' + packetsKey + '"]');
  updateDialerIndicator(btn, input.value.trim());
  input.addEventListener('input', () => updateDialerIndicator(btn, input.value.trim()));
}

function getNextFreeZapret2Index() {
  const used = Array.from(document.querySelectorAll('#zapret2Container .link-item'))
    .map(el => parseInt(el.dataset.index, 10))
    .filter(n => !isNaN(n))
    .sort((a, b) => a - b);

  let i = 0;
  while (used.includes(i)) i++;
  return i;
}

</script>

</body>
</html>
EOF
