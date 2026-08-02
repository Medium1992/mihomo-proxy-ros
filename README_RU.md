[English](/README.md) | [Русский](/README_RU.md) · [Telegram](https://t.me/+96HVPF3Ww6o3YTNi) · [Кодекс поведения](./CODE_OF_CONDUCT.md)

# mihomo-proxy-ros

> Мультиархитектурный Docker-контейнер для **MikroTik RouterOS**: [mihomo](https://github.com/metacubex/mihomo) + [byedpi](https://github.com/hufrea/byedpi) + [zapret](https://github.com/bol-van/zapret) + [zapret2](https://github.com/bol-van/zapret2). Управление через ENV + встроенная веб-панель на sh, которая собирает готовые команды для терминала RouterOS.

[![GitHub release](https://img.shields.io/github/v/release/Medium1992/mihomo-proxy-ros?label=release)](https://github.com/Medium1992/mihomo-proxy-ros/releases)
[![Docker Pulls](https://img.shields.io/docker/pulls/medium1992/mihomo-proxy-ros?logo=docker&label=docker%20pulls)](https://hub.docker.com/r/medium1992/mihomo-proxy-ros)
[![Docker Image Size](https://img.shields.io/docker/image-size/medium1992/mihomo-proxy-ros/latest?logo=docker&label=image%20size)](https://hub.docker.com/r/medium1992/mihomo-proxy-ros)
[![License](https://img.shields.io/github/license/Medium1992/mihomo-proxy-ros)](./LICENSE)
![Platforms](https://img.shields.io/badge/arch-amd64%20%7C%20arm64%20%7C%20armv7%20%7C%20armv5-blue)
[![Telegram](https://img.shields.io/badge/Telegram-группа-blue?logo=telegram)](https://t.me/+96HVPF3Ww6o3YTNi)

## ✨ Возможности

- 🌍 **Мультиархитектура**: ARM, ARM64, AMD64v1/v2/v3 (тег `latest` собирает ARM, ARM64, AMD64v3 — для v1/v2 запулите отдельный тег)
- 🖥 **Встроенная веб-панель** на порту `80` — визуальный редактор ENV, валидатор YAML, менеджеры файлов AWG/прокси/rule-set, генератор команд для MikroTik
- 🔐 **Обход DPI** через [ByeDPI](https://github.com/hufrea/byedpi), [Zapret/nfqws](https://github.com/bol-van/zapret), [Zapret2/nfqws2](https://github.com/bol-van/zapret2) (nfqws/nfqws2 — только amd64/arm64)
- 🧩 **Гибкая маршрутизация** по доменам, IP, GeoSite, GeoIP, ASN — всё через ENV
- 🛡 Несколько прокси-ссылок и **подписок** (включая [RemnaWave](https://docs.rw/docs/features/hwid-device-limit) с HWID)
- 🚀 Интеграция **WireGuard / AmneziaWG** копированием `.conf` в маунт-папку
- 📦 **Автоустановка** в один сниппет в терминал MikroTik
- 🛠 Несколько VETH-интерфейсов становятся прокси-выходами → mangle в RouterOS отправит куда нужно

> Тестировалось на **RouterOS 7.20+**. Нужен пакет `container` и `device-mode container=yes`.

## ⚡ Быстрый старт

1. **Включить поддержку контейнеров** в RouterOS:
   ```
   /system/device-mode/print
   /system/device-mode/update mode=advanced container=yes traffic-gen=yes
   ```
   На подтверждение даётся ~5 минут — выключите/включите питание или нажмите любую физическую кнопку на устройстве.

2. **Вставить установочный сниппет** в терминал RouterOS — см. раздел [§ Установка через RouterOS](#-установка-через-routeros) ниже.

3. **Открыть веб-панель**: `http://<ip-контейнера>:80/`
   Настроить ENV визуально → нажать *Команды MikroTik* → скопировать → вставить в терминал RouterOS.

4. **Или панель mihomo**: `http://<ip-контейнера>:9090/` (UI из `EXTERNAL_UI_URL`).

## 🖥 Веб-панель

**`http://<ip-контейнера>:80/`** — локальная панель управления, которая раздаётся busybox httpd прямо из контейнера.

> [!IMPORTANT]
> Панель закрыта HTTP basic auth. **По умолчанию `admin` / `admin` — смените пароль.**
> *Инструменты → Пароль вебки*: введите новый пароль, получите md5-хеш и готовые команды RouterOS.
> Сам пароль никуда не сохраняется — в env уезжает только хеш (`BASIC_AUTH_HASH`).
> Забыли пароль — удалите env `BASIC_AUTH_HASH` и перезапустите контейнер, вернётся дефолтный `admin`.

Значения секретных ENV (`LINK*`, `SUB_LINK*`, `SUB_LINK*_HEADERS`, `SOCKS*`, `MIXED_IN_USER*`, `UI_SECRET`)
в HTML не печатаются и не сохраняются в localStorage браузера: в поле показывается «•••••••• задано»,
настоящее значение подгружается по кнопке «Показать». Черновик правок живёт на сервере
(`/dev/shm/mihomo-ui/draft.json`, tmpfs) — чистый браузер без кеша и кук по-прежнему открывает
панель в актуальном состоянии.

<p align="center">
  <img src="docs/screenshots/webui-1.png" width="800" alt="Веб-панель — обзор">
</p>

<details>
<summary>📸 Ещё скриншоты</summary>

<p align="center">
  <img src="docs/screenshots/webui-2.png" width="800" alt="Веб-панель — прокси-провайдеры"><br><br>
  <img src="docs/screenshots/webui-3.png" width="800" alt="Веб-панель — прокси-группы"><br><br>
  <img src="docs/screenshots/webui-4.png" width="800" alt="Веб-панель — DPI / файлы zapret"><br><br>
  <img src="docs/screenshots/webui-5.png" width="800" alt="Веб-панель — YAML / rule-set">
</p>

</details>


Она **НЕ меняет** работающий контейнер напрямую. Вместо этого:

- показывает все ENV, которые понимает `entrypoint.sh`, по логическим страницам (Обзор, Провайдеры, DPI, Группы, Правила, Rule-set, YAML, Инструменты)
- держит правки локально в `localStorage` относительно исходных значений
- собирает точные команды `/container/envs/add|set|remove` для копипасты в терминал, плюс финальные `/container/stop`+`start` для применения

Что ещё внутри:

- **Редактор proxy YAML** с 12 шаблонами протоколов (vless-tcp/reality, vless-xhttp, vmess, trojan, ss, anytls, wireguard, amneziawg, hysteria2, tuic, ssh, vless-ws) — кнопка *"Загрузить шаблон"* подставляет в textarea
- **Живая валидация `mihomo -t`** перед сохранением, плюс проверка уникальности `name:` по всем провайдерам
- **Редактор AWG** с полным шаблоном `[Interface]/[Peer]/[Mihomo]` со всеми ключами, которые понимает парсер
- **Менеджер DPI-файлов** — загрузка `.bin` фейков в `/zapret-fakebin/`, редактирование текстовых списков в `/zapret-lists/`, фильтр по имени
- **Конструктор rule-set'ов** — вставляешь список в формате payload, получаешь готовую ENV `RULE_SETxx_BASE64`

Все runtime-артефакты (сгенерированный config, провайдерские YAML, пререндеренный HTML) лежат в `/dev/shm` — **флэш не изнашивается**.

## 📁 Точки монтирования

| Путь в контейнере | Назначение | Формат |
|---|---|---|
| `/root/.config/mihomo/awg/` | Конфиги WireGuard / AmneziaWG → становятся прокси-провайдерами | `*.conf` |
| `/root/.config/mihomo/proxies_mount/` | Свои прокси-провайдеры в нативном YAML mihomo | `*.yaml` / `*.yml` |
| `/root/.config/mihomo/rule_set_list/` | Свои rule-set-списки в формате [payload](https://wiki.metacubex.one/ru/config/rule-providers/#payload) | `*.txt` (имя файла = имя группы) |
| `/zapret-fakebin/` | Бинарные fake-пакеты для `nfqws --dpi-desync-fake-*` | `*.bin` |
| `/zapret-lists/` | Текстовые списки доменов/IP для lua-скриптов nfqws | `*.txt` |

В контейнер можно прикрепить **несколько VETH-интерфейсов** — они появятся как direct-выходы в mihomo, а маршрутизацию между ними делаешь через mangle в RouterOS. Входящий трафик в контейнер должен идти **только через первый VETH**.

## 🧑‍🍳 Несколько примеров

### YouTube через одну VLESS-ссылку
```yaml
LINK1: "vless://uuid@server:443?type=tcp&security=reality&pbk=...#myvless"
GROUP: "youtube"
YOUTUBE_USE: "LINK1"
YOUTUBE_GEOSITE: "youtube"
```

### Telegram через AmneziaWG (`tunnel1.conf` в `/root/.config/mihomo/awg/`)
```yaml
GROUP: "telegram"
TELEGRAM_USE: "tunnel1"
TELEGRAM_GEOSITE: "telegram"
TELEGRAM_GEOIP: "telegram"
TELEGRAM_AS: "AS62041,AS59930,AS62014,AS211157,AS44907"
```

### Discord + Google через стратегию ByeDPI
```yaml
BYEDPI_CMD: "--tlsrec 41+s --udp-fake 1 --oob 1 --auto=torst,redirect,ssl_err --fake -1"
GROUP: "discord,google"
DISCORD_USE: "BYEDPI"
DISCORD_GEOSITE: "discord"
DISCORD_GEOIP: "discord"
GOOGLE_USE: "BYEDPI"
GOOGLE_GEOSITE: "google"
GOOGLE_GEOIP: "google"
```

### Завернуть LAN-подсеть через SOCKS5
```yaml
SOCKS1: "server=192.168.88.10#port=1080#username=user#password=pass"
GROUP: "lan_socks"
LAN_SOCKS_USE: "SOCKS1"
LAN_SOCKS_SRCIPCIDR: "192.168.88.0/24"
```

## ⚙️ Переменные окружения

### Базовое

| ENV | По умолчанию | Описание |
|---|---|---|
| `TPROXY` | `true` | На RoS ≥ 7.21 (`arm64`/`amd64`) контейнер использует **NFTables**. `true` → TProxy inbound (TCP+UDP); `false` → Redirect (TCP) + TUN (UDP). |
| `DNS_MODE` | `fake-ip` | Режим DNS [enhanced-mode](https://wiki.metacubex.one/ru/config/dns/#enhanced-mode). |
| `NAMESERVER_POLICY` | — | Какие домены через какой DNS резолвить. Формат: `domain1#dns1,domain2#dns2`. [Docs](https://wiki.metacubex.one/ru/config/dns/#nameserver-policy). |
| `SNIFFER` | `true` | [Сниффер доменов](https://wiki.metacubex.one/ru/config/sniff) для роутинга по доменам, если домен резолвил не mihomo. |
| `FAKE_IP_RANGE` | `198.18.0.0/15` | [Диапазон fake-ip пула](https://wiki.metacubex.one/ru/config/dns/#fake-ip-range). |
| `FAKE_IP_TTL` | `1` | [TTL записи fake-ip в DNS-кеше](https://wiki.metacubex.one/ru/config/dns/#fake-ip-ttl) (сек). |
| `FAKE_IP_FILTERxx` | — | Список правил для DNS-сервера в режиме `rule`. |

### Логи и UI

| ENV | По умолчанию | Описание |
|---|---|---|
| `LOG_LEVEL` | `error` | Уровень логов mihomo: `silent`/`error`/`warning`/`info`/`debug`. [Docs](https://wiki.metacubex.one/ru/config/general/#_5). |
| `EXTERNAL_UI_URL` | [ссылка](https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip) | ZIP-источник для панели mihomo на `:9090`. [Docs](https://wiki.metacubex.one/ru/config/general/#url). |
| `UI_SECRET` | — | Секрет для external-controller (порт `9090`). Пусто = без авторизации (только LAN). |

### Веб-панель на `:80`

| ENV | По умолчанию | Описание |
|---|---|---|
| `BASIC_AUTH_USER` | `admin` | Логин basic auth веб-панели. Пустое значение вместе с `BASIC_AUTH_HASH` отключает авторизацию. |
| `BASIC_AUTH_HASH` | хеш пароля `admin` | md5-хеш пароля (`$1$соль$хеш`). Генерируется в *Инструменты → Пароль вебки*. Открытый пароль в env не хранится. |
| `WEB_CSRF` | `on` | Проверка `Referer` на изменяющих запросах CGI. `off` — если дёргаете эндпоинты панели из своих скриптов. |
| `ALLOW_PRIVATE_FETCH` | `false` | Разрешить `http-fetch` / `xray2mihomo-sub` ходить на loopback и приватные подсети (например, подписка на своём NAS). |
| `WEB_API_PORT` | `81` | Порт служебного слушателя на `127.0.0.1` с конвертером `xray2mihomo-sub` — его качает сам mihomo из `SUB_LINK*`, поэтому он без пароля. Из LAN недоступен. `0` = выключить. |

#### Конвертер подписок в `SUB_LINK*`

Ссылку из *Инструменты → xray2mihomo* можно класть в `SUB_LINK*` как есть:

```
SUB_LINK1=http://127.0.0.1:81/cgi-bin/xray2mihomo-sub?sub=https://provider.example/sub&format=yaml
```

Порт `81` живёт только на loopback контейнера и не закрыт паролем — иначе mihomo,
который обновляет провайдер по `interval`, получал бы 401 от панели на `:80`.
В этом вебруте лежит **единственный** CGI — конвертер; ничего читающего или пишущего файлы там нет.
Старые конфиги со ссылкой на порт 80 переписываются на `:81` автоматически при старте
(значение env не меняется, правится только сгенерированный `config.yaml`).

### Health-check

| ENV | По умолчанию | Описание |
|---|---|---|
| `HEALTHCHECK_PROVIDER` | `true` | `true` → проверка использует `HEALTHCHECK_*`. `false` → проверка использует `GROUP_URL`/`XXX_URL`/и т.п. (per-group). |
| `HEALTHCHECK_URL` | `https://www.gstatic.com/generate_204` | [Дефолтный URL](https://wiki.metacubex.one/ru/config/proxy-providers/#health-checkurl). |
| `HEALTHCHECK_URL_STATUS` | `204` | [Ожидаемый статус](https://wiki.metacubex.one/ru/config/proxy-groups/#expected-status). |
| `HEALTHCHECK_INTERVAL` | `120` | Интервал (сек). [Docs](https://wiki.metacubex.one/ru/config/proxy-providers/#health-checkinterval). |
| `HEALTHCHECK_URL_BYEDPI` | `https://www.facebook.com` | URL для провайдера `BYEDPI`. |
| `HEALTHCHECK_URL_STATUS_BYEDPI` | `200` | Ожидаемый статус для провайдера `BYEDPI`. |
| `HEALTHCHECK_URL_ZAPRET` | `https://www.facebook.com` | URL для всех провайдеров `ZAPRET`/`ZAPRET2`. |
| `HEALTHCHECK_URL_STATUS_ZAPRET` | `200` | Ожидаемый статус для `ZAPRET`/`ZAPRET2`. |

### DPI-движки

| ENV | По умолчанию | Описание |
|---|---|---|
| `BYEDPI_CMDxx` | — | Стратегия [ByeDPI](https://github.com/hufrea/byedpi). `BYEDPI_CMD` → выход `BYEDPI`; `BYEDPI_CMD1` → `BYEDPI_1` и т.д. Подбор стратегий — [byedpi-orchestrator](https://hub.docker.com/r/vindibona/byedpi-orchestrator). |
| `ZAPRET_CMDxx` | — | Стратегия [Zapret/nfqws](https://github.com/bol-van/zapret). В контейнере есть готовые fake-файлы в `/zapret-fakebin/` (например `quic_initial_www_google_com.bin`) и списки в `/zapret-lists/` (`ipset-all.txt`, `list-general.txt` и т.п.). |
| `ZAPRET2_CMDxx` | — | Стратегия [Zapret2/nfqws2](https://github.com/bol-van/zapret2). |
| `ZAPRET2_WG_CMD` | *(дефолт с blob `quic_initial_vk_com`)* | Отдельная стратегия nfqws2 для заворота WireGuard handshake. |
| `ZAPRET_PACKETSxx` | `12` | Сколько первых пакетов идёт через очередь nfqws. `ZAPRET_PACKETS` — для всех по умолчанию, `ZAPRET_PACKETSxx` — переопределение конкретному провайдеру. Не-натуральное число = неограниченно (всегда в очереди). |
| `ZAPRET2_PACKETSxx` | `12` | То же для nfqws2. |

### Прокси-провайдеры

| ENV | По умолчанию | Описание |
|---|---|---|
| `LINK0`, `LINK1`, … | — | Одна прокси-ссылка: `vless://`, `vmess://`, `ss://`, `trojan://`, `vpn://`. На каждую — отдельный [proxy-provider](https://wiki.metacubex.one/ru/config/proxy-providers). |
| `SUB_LINK0`, `SUB_LINK1`, … | — | Подписка (`http(s)://...`). На каждую — отдельный [proxy-provider](https://wiki.metacubex.one/ru/config/proxy-providers), с поддержкой HWID через заголовки. |
| `SUB_LINKxx_PROXY` | `DIRECT` | Через какой [proxy](https://wiki.metacubex.one/ru/config/proxy-providers/#proxy) тянуть подписку. Пример: `SUB_LINK1_PROXY=proxies1`. |
| `SUB_LINKxx_HEADERS` | — | Кастомные [HTTP-заголовки](https://wiki.metacubex.one/ru/config/proxy-providers/#header) для запроса подписки. Формат: `key1=val1#key2=val2`. Пример с HWID: `x-hwid=...#x-device-os=...#x-ver-os=...#x-device-model=...#user-agent=...`. |
| `SUB_LINK_INTERVAL` | `3600` | Дефолтный [интервал обновления](https://wiki.metacubex.one/ru/config/proxy-providers/#interval) (сек) для всех подписок. |
| `SUB_LINKxx_INTERVAL` | наследует `SUB_LINK_INTERVAL` | Переопределение per-подписка. |
| `SUB_LINKxx_FILTER` | — | Provider-level [filter](https://wiki.metacubex.one/ru/config/proxy-providers/#filter) — regex по именам узлов внутри подписки. Несколько шаблонов через `\|`. |
| `SUB_LINKxx_EXCLUDE_FILTER` | — | Provider-level [exclude-filter](https://wiki.metacubex.one/ru/config/proxy-providers/#exclude-filter) — regex исключения. |
| `SUB_LINKxx_EXCLUDE_TYPE` | — | Provider-level [exclude-type](https://wiki.metacubex.one/ru/config/proxy-providers/#exclude-type) — список [Adapter Type](https://github.com/MetaCubeX/mihomo/blob/fbead56ec97ae93f904f4476df1741af718c9c2a/constant/adapters.go#L18-L45) (регистр не важен) через `\|`. Пример: `vmess\|direct`. |
| `SUB_LINKxx_ADDITIONAL_PREFIX` | — | Идёт в `override.`[`additional-prefix`](https://wiki.metacubex.one/ru/config/proxy-providers/#overrideadditional-prefix) — фиксированный префикс к каждому имени узла. |
| `SUB_LINKxx_ADDITIONAL_SUFFIX` | — | Идёт в `override.`[`additional-suffix`](https://wiki.metacubex.one/ru/config/proxy-providers/#overrideadditional-suffix) — фиксированный суффикс к каждому имени узла. |
| `SOCKS0`, `SOCKS1`, … | — | SOCKS5 прокси. Формат: `server=ip#port=1080#username=#password=#tls=#fingerprint=#skip-cert-verify=#udp=#ip-version=`. [Docs](https://wiki.metacubex.one/ru/config/proxies/socks/). |
| `XXX_DIALER_PROXY` | — | [Override dialer-proxy](https://wiki.metacubex.one/ru/config/proxy-providers/#override) — пускать соединения этого провайдера через другую группу. Пример: `LINK1_DIALER_PROXY=YouTube`. |

### Прокси-группы

`GROUP` объявляет набор групп. Для каждой группы `XXX` (в верхнем регистре) работают префиксные ENV ниже.

> 💡 Кроме пользовательских групп есть три «системные», встроенные в entrypoint: `GROUP_*` (дефолтные значения для всех групп), `GLOBAL_*` (специальная группа GLOBAL) и `DNS_*` (служебная группа для DNS-резолвинга). Все три принимают тот же набор префиксных ENV из таблицы ниже.

| ENV | По умолчанию | Описание |
|---|---|---|
| `GROUP` | — | Список [прокси-групп](https://wiki.metacubex.one/ru/config/proxy-groups) через запятую. `telegram,youtube,google,ai,geoblock` → группы `TELEGRAM, YOUTUBE, GOOGLE, AI, GEOBLOCK`. Группа создаётся только если у неё есть хотя бы один ресурс (`XXX_*`) или `XXX_USE`. |
| `XXX_TYPE` | `select` | [Тип группы](https://wiki.metacubex.one/ru/config/proxy-groups/#type): `select` / `url-test` / `fallback` / `load-balance` / `relay`. |
| `XXX_USE` | *все провайдеры в порядке: LINKs, SUB_LINKs, WG/AWG, BYEDPI, DIRECT* | Какие [провайдеры](https://wiki.metacubex.one/ru/config/proxy-providers) включить в группу. Пример: `YOUTUBE_USE=BYEDPI,LINK1`. |
| `XXX_PROXIES` | — | Явный список [proxies](https://wiki.metacubex.one/ru/config/proxy-groups/#proxies) (конкретных узлов, не провайдеров) через запятую. Альтернатива/дополнение к `XXX_USE`. |
| `XXX_FILTER` | — | [Regex-фильтр имён](https://wiki.metacubex.one/ru/config/proxy-groups/#filter). Пример: `RU\|BYEDPI`. |
| `XXX_EXCLUDE` | — | [Regex-исключение](https://wiki.metacubex.one/ru/config/proxy-groups/#exclude-filter). |
| `XXX_EXCLUDE_TYPE` | — | [Исключение по типу](https://wiki.metacubex.one/ru/config/proxy-groups/#exclude-type). Пример: `vmess\|direct`. |
| `XXX_DNS` | — | DNS-резолвер для доменных правил этой группы. Пример: `https://dns.google/dns-query#disable-qtype-65=true&disable-ipv6=true`. |
| `XXX_ICON` | — | URL [иконки](https://wiki.metacubex.one/ru/config/proxy-groups/#icon) группы. |
| `XXX_HIDDEN` | `false` | Скрыть группу из веб-панели mihomo. |
| `GROUP_URL` / `XXX_URL` | `https://www.gstatic.com/generate_204` | URL health-check'a при `HEALTHCHECK_PROVIDER=false` и `XXX_TYPE` ∈ `url-test`/`fallback`/`load-balance`. |
| `GROUP_URL_STATUS` / `XXX_URL_STATUS` | `204` | Ожидаемый статус для проверки выше. |
| `GROUP_INTERVAL` / `XXX_INTERVAL` | `60` | Интервал проверки (сек). |
| `GROUP_TOLERANCE` / `XXX_TOLERANCE` | `20` | [Tolerance для url-test](https://wiki.metacubex.one/ru/config/proxy-groups/url-test/#tolerance) в мс. |
| `GROUP_STRATEGY` / `XXX_STRATEGY` | `consistent-hashing` | [Стратегия балансировки](https://wiki.metacubex.one/ru/config/proxy-groups/load-balance/#strategy). |

### Правила маршрутизации (на группу)

Каждая ENV ниже создаёт автоматическое [правило](https://wiki.metacubex.one/ru/config/rules) с таргетом на группу `XXX`. `XXX_GEOSITE/GEOIP/AS` дополнительно собирают rule-set формата `.mrs` из репозитория [meta-rules-dat](https://github.com/MetaCubeX/meta-rules-dat).

| ENV | Описание |
|---|---|
| `XXX_GEOSITE` | Список [geosite](https://github.com/MetaCubeX/meta-rules-dat/tree/meta/geo/geosite) через запятую. Пример: `GEOBLOCK_GEOSITE=intel,openai,xai`. |
| `XXX_GEOIP` | Список [geoip](https://github.com/MetaCubeX/meta-rules-dat/tree/meta/geo/geoip). Пример: `GEOBLOCK_GEOIP=netflix`. |
| `XXX_AS` | Номера [AS](https://github.com/MetaCubeX/meta-rules-dat/tree/meta/asn). Пример: `TELEGRAM_AS=AS62041,AS59930,AS62014,AS211157,AS44907`. |
| `XXX_DOMAIN` | Точные [DOMAIN](https://wiki.metacubex.one/ru/config/rules/#domain) совпадения. |
| `XXX_SUFFIX` | [DOMAIN-SUFFIX](https://wiki.metacubex.one/ru/config/rules/#domain-suffix) совпадения. |
| `XXX_KEYWORD` | [DOMAIN-KEYWORD](https://wiki.metacubex.one/ru/config/rules/#domain-keyword) совпадения. |
| `XXX_IPCIDR` | [IP-CIDR](https://wiki.metacubex.one/ru/config/rules/#ip-cidr-ip-cidr6) подсети. |
| `XXX_SRCIPCIDR` | [SRC-IP-CIDR](https://wiki.metacubex.one/ru/config/rules/#src-ip-cidr) — роутинг по источнику. Пример: `SOCKS_SRCIPCIDR=192.168.88.37/32,192.168.88.65/32`. |
| `XXX_DSCP` | Маркировка трафика группы [DSCP-меткой](https://wiki.metacubex.one/ru/config/rules/#dscp). Значение 0–63. Пример: `YOUTUBE_DSCP=10`. |
| `XXX_PRIORITY` | Позиция правил группы в списке `rules`. Меньше = раньше. Приоритеты общие с `RULESxx`. По умолчанию ≥1000. |

### Кастомные rule-set'ы

| ENV | Описание |
|---|---|
| `RULE_SETxx_BASE64` | `<base64>#<name>` — `<base64>` это base64-кодированный список формата [payload](https://wiki.metacubex.one/ru/config/rule-providers/#payload). Создаёт rule-set + группу `<name>` с приоритетом ≥2000. Конструктор в веб-панели *Rule-sets → Новый base64* собирает это за тебя. |
| `RULESxx` | Сырое [правило mihomo](https://wiki.metacubex.one/ru/config/rules/), где `xx` — приоритет. Пример: `RULES1=AND,((NETWORK,udp),(DST-PORT,443)),REJECT` дропает QUIC первым правилом. |

## 🛠 Установка через RouterOS

Сначала включите поддержку контейнеров (если ещё не включена):

```
/system/device-mode/print
/system/device-mode/update mode=advanced container=yes traffic-gen=yes
```

На подтверждение даётся ~5 минут — выключите/включите питание или кратковременно нажмите любую физическую кнопку на устройстве.

Затем вставьте сниппет ниже в терминал RouterOS:

```routeros
:global currentVersion [/system resource get version];
:global currentMinor [:pick $currentVersion ([:find $currentVersion "."] + 1) ([:find $currentVersion "."] + 3)];
:global r
:global statusPackage false
:global statusDeviceMode [/system/device-mode/get container]

:if ([:len [/system/package/find name=container available=no disabled=no]] >0) do={
:set statusPackage true
} else={
:put "Please check the installation of the container package"
}
:if ($statusDeviceMode=false) do={
:put "Please check /system/device-mode/print container enable"
}
:if ($currentMinor >= 21) do={
:put "Current version RouterOS 7.$currentMinor"
:set r [/tool fetch url=https://raw.githubusercontent.com/Medium1992/mihomo-proxy-ros/refs/heads/main/script21.rsc mode=https output=user as-value]
}
:if ($currentMinor = 20) do={
:put "Current version RouterOS 7.$currentMinor"
:set r [/tool fetch url=https://raw.githubusercontent.com/Medium1992/mihomo-proxy-ros/refs/heads/main/script.rsc mode=https output=user as-value]
}
:if ($currentMinor < 20) do={
:put "Current version RouterOS $currentVersion"
:put "Update to at least version RouterOS 7.20"
}

:if (($r->"status")="finished" and $statusPackage=true and $statusDeviceMode=true) do={
:global content ($r->"data")
:if ([:len $content] > 0) do={
:global s [:parse $content]
:log warning "script loading completed and started"
:put "script loading completed and started"
$s
/system/script/environment/remove [find where ]
}
}
```

В процессе скрипт спросит:

- одну прокси-ссылку (`vless://`, `vmess://`, `ss://`, `trojan://`)
- опционально — ссылку на подписку (`http(s)://...`)

…и сам настроит конфиг роутера, mangle + маршрутизацию, установку контейнера и стартовый пул доменов.

После установки тонкая донастройка — либо через **веб-панель на `:80`**, либо через вспомогательные репозитории:

- [DNS_FWD](https://github.com/Medium1992/MikroTik_DNS_FWD) — управление DNS forwarding
- [IPList](https://github.com/Medium1992/MikroTik_IPlist) — IP-листы

## 🐳 Docker Compose

Готовый пример — в [`docker-compose.yml`](./docker-compose.yml).

## 🤝 Контрибьютинг

PR приветствуются — сначала прочитайте [Кодекс поведения](./CODE_OF_CONDUCT.md) и [CONTRIBUTING.md](./CONTRIBUTING.md).

## 🔐 Безопасность

Сообщайте о чувствительных вопросах по [SECURITY.md](./SECURITY.md).

## 💖 Поддержка проекта

Если проект сэкономил вам время с настройкой микротика и скриптами:

- **USDT (TRC20):** `TWDDYD1nk5JnG6FxvEu2fyFqMCY9PcdEsJ`
- [boosty.to/petersolomon/donate](https://boosty.to/petersolomon/donate)

<img width="150" height="150" alt="petersolomon-donate" src="https://github.com/user-attachments/assets/fcf40baa-a09e-4188-a036-7ad3a77f06ea" />
