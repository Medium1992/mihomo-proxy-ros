# 🇷🇺 Описание на русском

**mihomo-proxy-ros** — это мультиархитектурный Docker-контейнер на базе **Mihomo**,  
поддерживающий платформы **ARM**, **ARM64**, **AMD64v1**, **AMD64v2** и **AMD64v3**.  
Тег latest включает в себя **ARM**, **ARM64**, **AMD64v3**.  
Если у вас **AMD64v1**,**AMD64v2** то необходимо запулить соответствующий тэг.
## 💖 Поддержка проекта

Если вам полезен этот проект, вы можете поддержать его донатом:  
**USDT(TRC20): TWDDYD1nk5JnG6FxvEu2fyFqMCY9PcdEsJ**

## 🌟 Особенности скрипта автоматизированной установки на роутеры MikroTik

В репозитории доступен **интерактивный скрипт автоматизированной установки** для **RouterOS MikroTik**,  
который также устанавливает **ByeDPI** и **dnsproxy** от **AdGuardHome**.

- 🌍 Мультиархитектура: ARM, ARM64, AMD64v1-v3
- ⚙️ Автоматизированная установка через терминал MikroTik с использованием скрипта в конце описания
- 🔐 Обход DPI с помощью ByeDPI (спасибо за контейнер [wiktorbgu](https://hub.docker.com/r/wiktorbgu/byedpi-mikrotik), вы можете изменить стратегию в CMD контейнера)
- 🌐 DNSProxy: мультирезолв с нескольких DNS-серверов, поддержка всех протоколов DNS
- 🧩 Гибкая маршрутизация и управление пулом доменов, ip, AS через ENVs
- 🛡️ Возможность добавления нескольких прокси-ссылок, а также подписок(включая подписки RemnaWave с HWID) через ENVs
- 🚀 Интеграция множества WG, AWG VPN посредством копирования конфиг файлов в mount папку.

Во время выполнения пользователю предлагается:
- Ввести одну ссылку на прокси: `vless://`, `vmess://`, `ss://`, `trojan://`
- При наличии — одну ссылку на подписку:  `Enter sublink http(s)://... URL`

Скрипт автоматически выполняет:
- Настройку роутера  
- Конфигурацию Mangle и маршрутизации  
- Установку контейнеров  
- Формирование пула доменов для ресурсов, проходящих через прокси

Таким образом, проект значительно **упрощает процесс настройки**,  
делая его удобным даже для **неопытных пользователей**,  
и обеспечивает **гибкое, готовое к использованию прокси-решение**.


После завершения установки можно **гибко настроить маршрутизацию ресурсов** на самом роутере изменяя ресурсы в существующем скрипте или формирования новых [DNS_FWD](https://github.com/Medium1992/MikroTik_DNS_FWD), [IPList](https://github.com/Medium1992/MikroTik_IPlist) 
а также **добавлять новые ссылки** через переменные окружения (`ENV`) для гибкой настройки маршрутизации и логики работы контейнера `mihomo-proxy-ros`

## 🌟 Описание ENVs

| Переменная              | По умолчанию                         | Описание |
|------------------------|---------------------------------------|---------|
| `FAKE_IP_RANGE`        | `198.18.0.0/15`                       | Диапазон Fake-IP пула [DOCs](https://wiki.metacubex.one/ru/config/dns/#fake-ip-range) |
| `TTL_FAKEIP`           | `1`                                   | Время жизни записи с FakeIP в кеше DNS в секундах |
| `FAKE_IP_FILTER`       | —                                     | Список доменов через запятую, исключённых из Fake-IP [DOCs](https://wiki.metacubex.one/ru/config/dns/#fake-ip-filter). При выполнении скрипта задается `www.youtube.com` из-за особенностей работы youtube на телевизорах через BYEDPI и необходимости изменять MSS |
| `EXTERNAL_UI_URL`      | `https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip` | Ссылка на веб-интерфейс (zip-архив) [DOCs](https://wiki.metacubex.one/ru/config/general/#url) |
| `LOG_LEVEL`            | `error`                               | Уровень логов mihomo (`silent`, `error`, `warning`, `info`, `debug`) [DOCs](https://wiki.metacubex.one/ru/config/general/#_5) |
| `INTERVAL`             | `120`                                 | Интервал health-check в секундах [DOCs](https://wiki.metacubex.one/ru/config/proxy-providers/#health-checkinterval) |
| `BYEDPI`               | `false`                               | Включить прокси через byeDPI (`true`/`false`). Добавляет [прокси-провайдера](https://wiki.metacubex.one/ru/config/proxy-providers) типа [SOCKS5](https://wiki.metacubex.one/ru/config/proxies/socks) с именем `BYEDPI` |
| `BYEDPI_ADDRESS`       | `192.168.255.6`                       | IP-адрес server для [прокси-провайдера](https://wiki.metacubex.one/ru/config/proxy-providers) `BYEDPI` |
| `BYEDPI_SOCKS_PORT`    | `1080`                                | Порт SOCKS5 сервера [прокси-провайдера](https://wiki.metacubex.one/ru/config/proxy-providers) `BYEDPI` |
| `LINK0`, `LINK1`...    | —                                     | Прокси-ссылки `vless://`, `vmess://`, `ss://`, `trojan://`... Для каждой прокси-ссылке создается отдельный [прокси-провайдер](https://wiki.metacubex.one/ru/config/proxy-providers) |
| `SUB_LINK0`, `SUB_LINK1`... | —                                | Подписки типа `http(s)://`... Для каждой подписки создается отдельный [прокси-провайдер](https://wiki.metacubex.one/ru/config/proxy-providers). Имеется поддержка задания [HWID](https://docs.rw/docs/features/hwid-device-limit) каждой подписке отдельно|
| `SW_ID_FOR_HWID`       | —                                     | Задание любого значения которое зашифруется автоматически для header [x-hwid](https://docs.rw/docs/features/hwid-device-limit) (sha256[:16]). По умолчанию будет автоматически добавляться header [x-hwid](https://docs.rw/docs/features/hwid-device-limit) для любого запроса подписок `SUB_LINK`, если в ENV `SUB_LINK` не были заданы индивидуальные значения. В выполнении скрипта в этот ENV записывается `Software ID` роутера Mikrotik |
| `DEVICE_OS`            | —                                     | Задание любого значения. По умолчанию будет автоматически добавляться header [x-device-os](https://docs.rw/docs/features/hwid-device-limit) для любого запроса подписок `SUB_LINK`, если в ENV `SUB_LINK` не были заданы индивидуальные значения. В выполнении скрипта в этот ENV записывается `RouterOS` |
| `VER_OS`               | —                                     |  Задание любого значения. По умолчанию будет автоматически добавляться header [x-ver-os](https://docs.rw/docs/features/hwid-device-limit) для любого запроса подписок `SUB_LINK`, если в ENV `SUB_LINK` не были заданы индивидуальные значения. В выполнении скрипта в этот ENV записывается текущая версия RouterOS |
| `DEVICE_MODEL`         | —                                     | Задание любого значения. По умолчанию будет автоматически добавляться header [x-device-model](https://docs.rw/docs/features/hwid-device-limit) для любого запроса подписок `SUB_LINK`, если в ENV `SUB_LINK` не были заданы индивидуальные значения. В выполнении скрипта в этот ENV записывается текущий Board Name MikroTik |
| `USER_AGENT`           | —                                     | Задание любого значения. По умолчанию будет автоматически добавляться header [User-Agent](https://docs.rw/docs/features/hwid-device-limit) для любого запроса подписок `SUB_LINK`, если в ENV `SUB_LINK` не были заданы индивидуальные значения. В выполнении скрипта в этот ENV записывается `medium1992/mihomo-proxy-ros` |
| `GROUP`                | —                                     | Список [прокси-групп](https://wiki.metacubex.one/ru/config/proxy-groups) через запятую, например `telegram,youtube,google,ai,geoblock` создаст [прокси-группы](https://wiki.metacubex.one/ru/config/proxy-groups) `TELEGRAM`,`YOUTUBE`,`GOOGLE`,`AI`,`GEOBLOCK`. [Прокси-группа](https://wiki.metacubex.one/ru/config/proxy-groups) создается только при наличии для неё хотя бы одного из ENV `_GEOSITE`, `_GEOIP`, `_AS`|
| `XXX_TYPE`             | `select`                              | [Тип прокси-группы](https://wiki.metacubex.one/ru/config/proxy-groups/#type) ([select](https://wiki.metacubex.one/ru/config/proxy-groups/select), [url-test](https://wiki.metacubex.one/ru/config/proxy-groups/url-test), [fallback](https://wiki.metacubex.one/ru/config/proxy-groups/fallback), [load-balance](https://wiki.metacubex.one/ru/config/proxy-groups/load-balance)). `XXX`-[имя прокси-группы](https://wiki.metacubex.one/ru/config/proxy-groups/#name) которое задаешь в ENV `GROUP`. Например для `GROUP` `...,youtube,...` `YOUTUBE_TYPE` |
| `XXX_USE`              | *(все провайдеры)* в порядке `LINKs`, `SUB_LINKs`, `WG,AWG`, `BYEDPI`, `DIRECT`                    | Список [прокси-провайдеров](https://wiki.metacubex.one/ru/config/proxy-providers) через запятую, которые будут использоваться в указанном порядке для [прокси-группы](https://wiki.metacubex.one/ru/config/proxy-groups), где `XXX`-[имя прокси-группы](https://wiki.metacubex.one/ru/config/proxy-groups/#name) которое задаешь в ENV `GROUP`. Например для `GROUP` `...,youtube,...` `YOUTUBE_USE` со значением `BYEDPI,LINK1` оставит в использовании прокси-группой YOUTUBE два прокси провайдера и первым будет BYEDPI, второй LINK1 |
| `XXX_FILTER`           | —                                     | [Фильтр прокси-группы](https://wiki.metacubex.one/ru/config/proxy-groups/#filter), где `XXX`-[имя прокси-группы](https://wiki.metacubex.one/ru/config/proxy-groups/#name) которое задаешь в ENV `GROUP`. Например для `GROUP` `...,youtube,...` `YOUTUBE_FILTER` со значением `RU\|BYEDPI` оставит в использовании прокси-группой YOUTUBE прокси которые имеют эмоджи флага РФ и имя BYEDPI |
| `XXX_EXCLUDE`          | —                                     | [Фильтр исключений прокси-группы](https://wiki.metacubex.one/ru/config/proxy-groups/#exclude-filter) , где `XXX`-[имя прокси-группы](https://wiki.metacubex.one/ru/config/proxy-groups/#name) которое задаешь в ENV `GROUP`. Например для `GROUP` `...,youtube,...` `YOUTUBE_EXCLUDE` со значением `RU\|BYEDPI` исключит из использования прокси-группой YOUTUBE прокси которые имеют эмоджи флага РФ и имя BYEDPI |
| `XXX_GEOSITE`          | —                                     | Список [geosite](https://github.com/MetaCubeX/meta-rules-dat/tree/meta/geo/geosite) через запятую для [прокси-группы](https://wiki.metacubex.one/ru/config/proxy-groups) `XXX`. Фактически создает [rule-set](https://wiki.metacubex.one/ru/config/rules/#rule-set) формата rms и соответствующие правила маршрутизации [rules](https://wiki.metacubex.one/ru/config/rules) в [прокси-группу](https://wiki.metacubex.one/ru/config/proxy-groups), где `XXX`-[имя прокси-группы](https://wiki.metacubex.one/ru/config/proxy-groups/#name) которое задаешь в ENV `GROUP`. Например для `GROUP` `...,geoblock,...` `GEOBLOCK_GEOSITE` со значением `intel,openai,xai` подгрузит список доменов для ресурсов `intel`,`openai`,`xai` и будет маршрутизировать их в прокси-провайдера `GEOBLOCK`  |
| `XXX_GEOIP`            | —                                     | Список [geoip](https://github.com/MetaCubeX/meta-rules-dat/tree/meta/geo/geoip) через запятую для [прокси-группы](https://wiki.metacubex.one/ru/config/proxy-groups) `XXX`. Фактически создает [rule-set](https://wiki.metacubex.one/ru/config/rules/#rule-set) формата rms и соответствующие правила маршрутизации [rules](https://wiki.metacubex.one/ru/config/rules) в [прокси-группу](https://wiki.metacubex.one/ru/config/proxy-groups), где `XXX`-[имя прокси-группы](https://wiki.metacubex.one/ru/config/proxy-groups/#name) которое задаешь в ENV `GROUP`. Например для `GROUP` `...,geoblock,...` `GEOBLOCK_GEOIP` со значением `netflix` подгрузит список пулов IP `netflix` и будет маршрутизировать их в прокси-провайдера `GEOBLOCK` |
| `XXX_AS`               | —                                     | Список [AS](https://github.com/MetaCubeX/meta-rules-dat/tree/meta/asn) через запятую для [прокси-группы](https://wiki.metacubex.one/ru/config/proxy-groups) `XXX`. Фактически создает [rule-set](https://wiki.metacubex.one/ru/config/rules/#rule-set) формата rms и соответствующие правила маршрутизации [rules](https://wiki.metacubex.one/ru/config/rules) в [прокси-группу](https://wiki.metacubex.one/ru/config/proxy-groups), где `XXX`-[имя прокси-группы](https://wiki.metacubex.one/ru/config/proxy-groups/#name) которое задаешь в ENV `GROUP`. Например для `GROUP` `...,telegram,...` `TELEGRAM_AS` со значением `AS62041,AS59930,AS62014,AS211157,AS44907` подгрузит список пулов IP `AS62041`,`AS59930`,`AS62014`,`AS211157`,`AS44907` и будет маршрутизировать их в прокси-провайдера `TELEGRAM` |
| `XXX_PRIORITY`         | —                                     | Приоритет [прокси-группы](https://wiki.metacubex.one/ru/config/proxy-groups) `XXX`, в части порядка правил в [rules](https://wiki.metacubex.one/ru/config/rules). Например, `YOUTUBE_PRIORITY` со значением `1` `TELEGRAM_PRIORITY` со значением `2` создадут правила в [rules](https://wiki.metacubex.one/ru/config/rules) по очереди сначала `YOUTUBE`, потом `TELEGRAM` |

> **SUB_LINK** с индивидуальными параметрами [x-hwid](https://docs.rw/docs/features/hwid-device-limit), [x-device-os](https://docs.rw/docs/features/hwid-device-limit), [x-ver-os](https://docs.rw/docs/features/hwid-device-limit), [x-device-model](https://docs.rw/docs/features/hwid-device-limit), [User-Agent](https://docs.rw/docs/features/hwid-device-limit) задаются через `#` ```https://...#x-hwid=...#x-device-os=...#x-ver-os=...#x-device-model=...#user-agent=...```

> **WG, AWG** необходимо маунтить конфиги WG, AWG в папку контейнера `/root/.config/mihomo/awg/`, будут созданы прокси-провайдеры в кол-ве файлов конфигов с именами этих файлов.


### Пример вставки в терминал MikroTik

🧩 Установка выполняется **непосредственно через терминал MikroTik** —  
достаточно **скопировать и вставить** этот фрагмент в **терминал RouterOS**,  
после чего скрипт **автоматически загрузится** из репозитория и **начнёт установку**.

```bash
:global r [/tool fetch url=https://raw.githubusercontent.com/Medium1992/mihomo-proxy-ros/refs/heads/main/script.rsc mode=https output=user as-value]
:if (($r->"status")="finished") do={
:global content ($r->"data")
:if ([:len $content] > 0) do={
:global s [:parse $content]
:log warning "script loading completed and started"
:put "script loading completed and started"
$s
/system/script/environment/remove [find where ]
} else={
:log warning "Invalid or empty content, script don't start"
:put "Invalid or empty content, script don't start"
/system/script/environment/remove [find where ]
}
}

```
## 💖 Поддержка проекта

Если вам полезен этот проект, вы можете поддержать его донатом:  
**USDT(TRC20): TWDDYD1nk5JnG6FxvEu2fyFqMCY9PcdEsJ**
