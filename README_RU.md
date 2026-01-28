[English](/README.md) | [Русский](/README_RU.md)

[Telegram группа](https://t.me/+96HVPF3Ww6o3YTNi)

# 🇷🇺 Описание на русском

👉 Ознакомьтесь с [Кодексом поведения](./CODE_OF_CONDUCT.md) перед участием в проекте.

**mihomo-proxy-ros** — это мультиархитектурный Docker-контейнер на базе **Mihomo**, **byedpi**, **zapret(nfqws; только amd64 и arm64)** и **zapret2(nfqws2; только amd64 и arm64)** в одном контейнере,  
поддерживающий платформы **ARM**, **ARM64**, **AMD64v1**, **AMD64v2** и **AMD64v3**.  
Тег latest включает в себя **ARM**, **ARM64**, **AMD64v3**.  
Если у вас **AMD64v1**,**AMD64v2** то необходимо запулить соответствующий тэг.
## 💖 Поддержка проекта

Если вам полезен этот проект, вы можете поддержать его донатом:  
**USDT(TRC20): TWDDYD1nk5JnG6FxvEu2fyFqMCY9PcdEsJ**



## 🌟 Особенности скрипта автоматизированной установки на роутеры MikroTik

В репозитории доступен **интерактивный скрипт автоматизированной установки** для **RouterOS MikroTik**,  
который также устанавливает по желанию **dnsproxy** от **AdGuardHome**.

- 🌍 Мультиархитектура: ARM, ARM64, AMD64v1-v3
- ⚙️ Автоматизированная установка через терминал MikroTik с использованием скрипта в конце описания
- 🔐 Обход DPI с помощью ByeDPI (вы можете изменить стратегию в ENVs для контейнера, для подбора стратегий есть такой вариант [byedpi-orchestrator](https://hub.docker.com/r/vindibona/byedpi-orchestrator))
- 🔐 Обход DPI с помощью Zapret(nfqws) (только на amd64 и arm64) - стратегии подбирать отдельно от контейнера по инструкциям от создателя [zapret](https://github.com/bol-van/zapret)
- 🔐 Обход DPI с помощью Zapret2(nfqws2) (только на amd64 и arm64) - стратегии подбирать отдельно от контейнера по инструкциям от создателя [zapret2](https://github.com/bol-van/zapret2)
- 🌐 DNSProxy: мультирезолв с нескольких DNS-серверов, поддержка всех протоколов DNS (Установка по желанию)
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
а также **добавлять новые ссылки** и другие параметры через переменные окружения (`ENV`) для гибкой настройки маршрутизации и логики работы контейнера `mihomo-proxy-ros`

## 🌟 Описание ENVs

| Переменная              | По умолчанию                         | Описание |
|------------------------|---------------------------------------|---------|
| `TPROXY`               | `true`                                | В RoS>=7.21 архитектуры `arm64` и `adm64` по умолчанию в контейнере используется `NFTables`, если ENV `TPROXY` задан `true` будет использован inbound TProxy(tcp,udp), если задан `false` будет использован inbound Redirect(tcp)+TUN(udp) |
| `DNS_MODE`             | `fake-ip`                             | Режим работы DNS сервера [DOCs](https://wiki.metacubex.one/ru/config/dns/#enhanced-mode) |
| `NAMESERVER_POLICY`    | —                                     | Указание какие домены откуда резолвить [DOCs](https://wiki.metacubex.one/ru/config/dns/#nameserver-policy). Пример оформления ENV `domain1#dns1,domain2#dns2` |
| `SNIFFER`              | `true`                                | [Сниффер доменов](https://wiki.metacubex.one/ru/config/sniff). Применяется при роутинге по доменам, когда домен резолвил не mihomo |
| `FAKE_IP_RANGE`        | `198.18.0.0/15`                       | Диапазон Fake-IP пула [DOCs](https://wiki.metacubex.one/ru/config/dns/#fake-ip-range) |
| `FAKE_IP_TTL`          | `1`                                   | Время жизни записи с FakeIP в кеше DNS в секундах [DOCs](https://wiki.metacubex.one/ru/config/dns/#fake-ip-ttl)|
| `FAKE_IP_FILTERXXX`    | —                                     | Список правил работы ДНС сервера в режиме rule.|
| `EXTERNAL_UI_URL`      | [ссылка](https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip) | Ссылка на веб-интерфейс (zip-архив) [DOCs](https://wiki.metacubex.one/ru/config/general/#url) |
| `LOG_LEVEL`            | `error`                               | Уровень логов mihomo (`silent`, `error`, `warning`, `info`, `debug`) [DOCs](https://wiki.metacubex.one/ru/config/general/#_5) |
| `HEALTHCHECK_URL`      | `https://www.gstatic.com/generate_204`| [URL health-check](https://wiki.metacubex.one/ru/config/proxy-providers/#health-checkurl) |
| `HEALTHCHECK_URL_STATUS`| `204`                                | Ожидаемый статус health-check [DOCs](https://wiki.metacubex.one/ru/config/proxy-groups/#expected-status) |
| `HEALTHCHECK_INTERVAL` | `120`                                 | Интервал health-check в секундах [DOCs](https://wiki.metacubex.one/ru/config/proxy-providers/#health-checkinterval) |
| `HEALTHCHECK_URL_BYEDPI`| `https://www.facebook.com`           | [URL health-check](https://wiki.metacubex.one/ru/config/proxy-providers/#health-checkurl) для прокси-провайдера `BYEDPI` |
| `HEALTHCHECK_URL_STATUS_BYEDPI`| `200`                         | Ожидаемый статус health-check [DOCs](https://wiki.metacubex.one/ru/config/proxy-groups/#expected-status) для прокси-провайдера `BYEDPI` |
| `HEALTHCHECK_URL_ZAPRET`| `https://www.facebook.com`           | [URL health-check](https://wiki.metacubex.one/ru/config/proxy-providers/#health-checkurl) для всех прокси-провайдеров `ZAPRET` и `ZAPRET2`|
| `HEALTHCHECK_URL_STATUS_ZAPRET`| `200`                         | Ожидаемый статус health-check [DOCs](https://wiki.metacubex.one/ru/config/proxy-groups/#expected-status) для всех прокси-провайдеров `ZAPRET` и `ZAPRET2` |
| `HEALTHCHECK_PROVIDER`| `true`                         | Если `true` для проверки доступности url используются параметры `HEALTHCHECK_URL`,`HEALTHCHECK_INTERVAL`,`HEALTHCHECK_URL_STATUS`, если `false` используются `GROUP_URL`,`XXX_URL`,`GROUP_URL_STATUS`,`XXX_URL_STATUS`,`GROUP_INTERVAL`,`XXX_INTERVAL` |
| `BYEDPI_CMDxx`           | —                                     | Стратегия [BYEDPI](https://github.com/hufrea/byedpi) если задан `BYEDPI_CMD` появляется прокси-выход `BYEDPI`, если задан `BYEDPI_CMD1` появляется прокси-выход `BYEDPI_1` и так далее |
| `ZAPRET_CMDxx`        | —                                     | Стратегия [Zapret(nfqws)](https://github.com/bol-van/zapret), если задан `ZAPRET_CMD` появляется прокси-выход `ZAPRET`, если задан `ZAPRET_CMD1` появляется прокси-выход `ZAPRET_1` и так далее. В контейнере присутствуют bin файлы для фейков из репозитория [zapret-discord-youtube](https://github.com/Flowseal/zapret-discord-youtube), пути для их использования `/zapret-fakebin/quic_initial_www_google_com.bin`, `/zapret-fakebin/tls_clienthello_4pda_to.bin`, `/zapret-fakebin/tls_clienthello_max_ru.bin`, `/zapret-fakebin/tls_clienthello_www_google_com.bin`, а также txt списки файлы `/zapret-lists/ipset-all.txt`, `/zapret-lists/ipset-exclude.txt`, `/zapret-lists/list-exclude.txt`, `/zapret-lists/list-general.txt`, `/zapret-lists/list-google.txt` |
| `ZAPRET2_CMDxx`       | —                                     | Стратегия [Zapret2(nfqws2)](https://github.com/bol-van/zapret2), если задан `ZAPRET2_CMD` появляется прокси-выход `ZAPRET2`, если задан `ZAPRET2_CMD1` появляется прокси-выход `ZAPRET2_1` и так далее |
| `ZAPRET_PACKETSxx`        | 12                                     | Кол-во первых пакетов которые будут проходить через очередь запрета. `ZAPRET_PACKETS` значение всем nfqws по умолчанию. `ZAPRET_PACKETSxx` значение конкретному прокси-провайдеру. Значение отличное от натуральных чисел воспринимается как 0, пакеты всегда будут идти через очередь. |
| `ZAPRET2_PACKETSxx`       | 12                                     | Кол-во первых пакетов которые будут проходить через очередь запрета2. `ZAPRET2_PACKETS` значение всем nfqws2 по умолчанию. `ZAPRET2_PACKETSxx` значение конкретному прокси-провайдеру. Значение отличное от натуральных чисел воспринимается как 0, пакеты всегда будут идти через очередь.  |
| `LINK0`, `LINK1`...    | —                                     | Прокси-ссылки `vless://`, `vmess://`, `ss://`, `trojan://`... Для каждой прокси-ссылке создается отдельный [прокси-провайдер](https://wiki.metacubex.one/ru/config/proxy-providers) |
| `SUB_LINK0`, `SUB_LINK1`... | —                                | Подписки типа `http(s)://`... Для каждой подписки создается отдельный [прокси-провайдер](https://wiki.metacubex.one/ru/config/proxy-providers). Имеется поддержка задания [HWID](https://docs.rw/docs/features/hwid-device-limit) каждой подписке отдельно|
| `SUB_LINKxx_PROXY`     | `DIRECT`                              | Указание через какой [прокси](https://wiki.metacubex.one/ru/config/proxy-providers/#proxy) запрашивать подписку. Пример `SUB_LINK1_PROXY` со значнием `proxies1` будет запрашивать подписку через прокси `proxies1` |
| `SUB_LINKxx_HEADERS`     | —                              | Указание [headers](https://wiki.metacubex.one/ru/config/proxy-providers/#header) для запроса подписки со специальными заголовками. Пример оформления `header1=value1#header2=value2`. Пример с x-hwid `x-hwid=xxx#x-device-os=xxx#x-ver-os=xxx#x-device-model=xxx#user-agent=xxx` |
| `SUB_LINKxx_INTERVAL`     | `3600`                             | Указание [интервала обновления подписки](https://wiki.metacubex.one/ru/config/proxy-providers/#interval) в секундах. ENV `SUB_LINK_INTERVAL` задает всем по умолчанию значение. `SUB_LINKxx_INTERVAL` переназначить интервал конкретной подписке.  |
| `SOCKS0`, `SOCKS1`...    | —                                   | Прокси типа [socks5](https://wiki.metacubex.one/ru/config/proxies/socks/). Для каждого socks5 прокси создается отдельный [прокси-провайдер](https://wiki.metacubex.one/ru/config/proxy-providers). Примеры ENV `server=192.168.88.3#port=1080#username=admin#password=admin#tls=true#fingerprint=chrome#skip-cert-verify=false#udp=false#ip-version=ipv4`, `server=192.168.88.3#port=1080#username=admin#password=admin`; разделение параметров [конфига](https://wiki.metacubex.one/ru/config/proxies/socks/) через # |
| `XXX_DIALER_PROXY`    | —                                   | параметр прокси-провайдера, смотрите [override dialer-proxy](https://wiki.metacubex.one/ru/config/proxy-providers/#override). позволяет задать через какую прокси-группу выполнять соединение. Например можно указать чтобы LINK1 соединялся через группу YouTube - `LINK1_DIALER_PROXY` со значением `YouTube` |
| `GROUP`                | —                                     | Список [прокси-групп](https://wiki.metacubex.one/ru/config/proxy-groups) через запятую, например `telegram,youtube,google,ai,geoblock` создаст [прокси-группы](https://wiki.metacubex.one/ru/config/proxy-groups) `TELEGRAM`,`YOUTUBE`,`GOOGLE`,`AI`,`GEOBLOCK`. [Прокси-группа](https://wiki.metacubex.one/ru/config/proxy-groups) создается только при наличии для неё хотя бы одного из ресурсов `XXX_` или `XXX_USE`|
| `XXX_TYPE`             | `select`                              | [Тип прокси-группы](https://wiki.metacubex.one/ru/config/proxy-groups/#type) ([select](https://wiki.metacubex.one/ru/config/proxy-groups/select), [url-test](https://wiki.metacubex.one/ru/config/proxy-groups/url-test), [fallback](https://wiki.metacubex.one/ru/config/proxy-groups/fallback), [load-balance](https://wiki.metacubex.one/ru/config/proxy-groups/load-balance)). `XXX`-[имя прокси-группы](https://wiki.metacubex.one/ru/config/proxy-groups/#name) которое задаешь в ENV `GROUP`. Например для `GROUP` `...,youtube,...` `YOUTUBE_TYPE` |
| `GROUP_URL`            | `https://www.gstatic.com/generate_204`| [URL проверки прокси](https://wiki.metacubex.one/ru/config/proxy-groups/#url) используется при `HEALTHCHECK_PROVIDER`=`false` и `XXX_TYPE` [url-test](https://wiki.metacubex.one/ru/config/proxy-groups/url-test), [fallback](https://wiki.metacubex.one/ru/config/proxy-groups/fallback), [load-balance](https://wiki.metacubex.one/ru/config/proxy-groups/load-balance)|
| `XXX_URL`              | ENV `GROUP_URL`                       | Задание [URL проверки прокси](https://wiki.metacubex.one/ru/config/proxy-groups/#url) для прокси-группы при `HEALTHCHECK_PROVIDER`=`false` |
| `GROUP_URL_STATUS`     | `204`                                 | [URL статус проверки прокси](https://wiki.metacubex.one/ru/config/proxy-groups/#expected-status) используется при `HEALTHCHECK_PROVIDER`=`false` и `XXX_TYPE` [url-test](https://wiki.metacubex.one/ru/config/proxy-groups/url-test), [fallback](https://wiki.metacubex.one/ru/config/proxy-groups/fallback), [load-balance](https://wiki.metacubex.one/ru/config/proxy-groups/load-balance)|
| `XXX_URL_STATUS`       | ENV `GROUP_URL_STATUS`                | Задание [URL статуса проверки прокси](https://wiki.metacubex.one/ru/config/proxy-groups/#expected-status) для прокси-группы при `HEALTHCHECK_PROVIDER`=`false` |
| `GROUP_INTERVAL`       | `60`                                  | [Интервал проверки прокси](https://wiki.metacubex.one/ru/config/proxy-groups/#interval) в секундах, используется при `HEALTHCHECK_PROVIDER`=`false` и `XXX_TYPE` [url-test](https://wiki.metacubex.one/ru/config/proxy-groups/url-test), [fallback](https://wiki.metacubex.one/ru/config/proxy-groups/fallback), [load-balance](https://wiki.metacubex.one/ru/config/proxy-groups/load-balance)|
| `XXX_INTERVAL`         | ENV `GROUP_INTERVAL`                  | Задание [интервала проверки прокси](https://wiki.metacubex.one/ru/config/proxy-groups/#interval) для прокси-группы при `HEALTHCHECK_PROVIDER`=`false` |
| `GROUP_TOLERANCE`      | `20`                                  | [Разница для выбора лучшего прокси](https://wiki.metacubex.one/ru/config/proxy-groups/url-test/#tolerance) в мс, используется при `XXX_TYPE` [url-test](https://wiki.metacubex.one/ru/config/proxy-groups/url-test)|
| `XXX_TOLERANCE`        | ENV `GROUP_TOLERANCE`                 | Задание [разницы для выбора лучшего прокси](https://wiki.metacubex.one/ru/config/proxy-groups/url-test/#tolerance) для прокси-группы|
| `GROUP_STRATEGY`       | `consistent-hashing`                  | [Стратегия балансировки](https://wiki.metacubex.one/ru/config/proxy-groups/load-balance/#strategy), используется при `XXX_TYPE` [load-balance](https://wiki.metacubex.one/ru/config/proxy-groups/load-balance)|
| `XXX_STRATEGY`         | ENV `GROUP_STRATEGY`                  | Задание [стратегии балансировки](https://wiki.metacubex.one/ru/config/proxy-groups/load-balance/#strategy) для прокси-группы|
| `XXX_USE`              | *(все провайдеры)* в порядке `LINKs`, `SUB_LINKs`, `WG,AWG`, `BYEDPI`, `DIRECT`                    | Список [прокси-провайдеров](https://wiki.metacubex.one/ru/config/proxy-providers) через запятую, которые будут использоваться в указанном порядке для [прокси-группы](https://wiki.metacubex.one/ru/config/proxy-groups), где `XXX`-[имя прокси-группы](https://wiki.metacubex.one/ru/config/proxy-groups/#name) которое задаешь в ENV `GROUP`. Например для `GROUP` `...,youtube,...` `YOUTUBE_USE` со значением `BYEDPI,LINK1` оставит в использовании прокси-группой YOUTUBE два прокси провайдера и первым будет BYEDPI, второй LINK1 |
| `XXX_FILTER`           | —                                     | [Фильтр прокси-группы](https://wiki.metacubex.one/ru/config/proxy-groups/#filter), где `XXX`-[имя прокси-группы](https://wiki.metacubex.one/ru/config/proxy-groups/#name) которое задаешь в ENV `GROUP`. Например для `GROUP` `...,youtube,...` `YOUTUBE_FILTER` со значением `RU\|BYEDPI` оставит в использовании прокси-группой YOUTUBE прокси которые имеют эмоджи флага РФ и имя BYEDPI |
| `XXX_EXCLUDE`          | —                                     | [Фильтр исключений прокси-группы](https://wiki.metacubex.one/ru/config/proxy-groups/#exclude-filter) , где `XXX`-[имя прокси-группы](https://wiki.metacubex.one/ru/config/proxy-groups/#name) которое задаешь в ENV `GROUP`. Например для `GROUP` `...,youtube,...` `YOUTUBE_EXCLUDE` со значением `RU\|BYEDPI` исключит из использования прокси-группой YOUTUBE прокси которые имеют эмоджи флага РФ и имя BYEDPI |
| `XXX_EXCLUDE_TYPE`     | —                                     | [Фильтр прокси-группы по типу](https://wiki.metacubex.one/ru/config/proxy-groups/#exclude-type), где `XXX`-[имя прокси-группы](https://wiki.metacubex.one/ru/config/proxy-groups/#name) которое задаешь в ENV `GROUP`. Например для `GROUP` `...,youtube,...` `YOUTUBE_EXCLUDE_TYPE` со значением `vmess\|direct` исключит прокси типа `vmess` и `direct` в использовании прокси-группой YOUTUBE |
| `XXX_DNS`     | —                                     | Возможность задания через какой DNS резолвить домены прокси-группы `XXX`. Пример значения `https://dns.google/dns-query#disable-qtype-65=true&disable-ipv6=true` [Docs](https://wiki.metacubex.one/ru/config/dns/). Это может быть актуально например тем кто ИИ резолвит через comss или другие подобные прокси-днс, то есть задать группе ИИ нужный ДНС, и в группе выбрать MihomoProxyRoS. |
| `XXX_GEOSITE`          | —                                     | Список [geosite](https://github.com/MetaCubeX/meta-rules-dat/tree/meta/geo/geosite) через запятую для [прокси-группы](https://wiki.metacubex.one/ru/config/proxy-groups) `XXX`. Фактически создает [rule-set](https://wiki.metacubex.one/ru/config/rules/#rule-set) формата rms и соответствующие правила маршрутизации [rules](https://wiki.metacubex.one/ru/config/rules) в [прокси-группу](https://wiki.metacubex.one/ru/config/proxy-groups), где `XXX`-[имя прокси-группы](https://wiki.metacubex.one/ru/config/proxy-groups/#name) которое задаешь в ENV `GROUP`. Например для `GROUP` `...,geoblock,...` `GEOBLOCK_GEOSITE` со значением `intel,openai,xai` подгрузит список доменов для ресурсов `intel`,`openai`,`xai` и будет маршрутизировать их в прокси-группу `GEOBLOCK`  |
| `XXX_GEOIP`            | —                                     | Список [geoip](https://github.com/MetaCubeX/meta-rules-dat/tree/meta/geo/geoip) через запятую для [прокси-группы](https://wiki.metacubex.one/ru/config/proxy-groups) `XXX`. Фактически создает [rule-set](https://wiki.metacubex.one/ru/config/rules/#rule-set) формата rms и соответствующие правила маршрутизации [rules](https://wiki.metacubex.one/ru/config/rules) в [прокси-группу](https://wiki.metacubex.one/ru/config/proxy-groups), где `XXX`-[имя прокси-группы](https://wiki.metacubex.one/ru/config/proxy-groups/#name) которое задаешь в ENV `GROUP`. Например для `GROUP` `...,geoblock,...` `GEOBLOCK_GEOIP` со значением `netflix` подгрузит список пулов IP `netflix` и будет маршрутизировать их в прокси-группу `GEOBLOCK` |
| `XXX_AS`               | —                                     | Список [AS](https://github.com/MetaCubeX/meta-rules-dat/tree/meta/asn) через запятую для [прокси-группы](https://wiki.metacubex.one/ru/config/proxy-groups) `XXX`. Фактически создает [rule-set](https://wiki.metacubex.one/ru/config/rules/#rule-set) формата rms и соответствующие правила маршрутизации [rules](https://wiki.metacubex.one/ru/config/rules) в [прокси-группу](https://wiki.metacubex.one/ru/config/proxy-groups), где `XXX`-[имя прокси-группы](https://wiki.metacubex.one/ru/config/proxy-groups/#name) которое задаешь в ENV `GROUP`. Например для `GROUP` `...,telegram,...` `TELEGRAM_AS` со значением `AS62041,AS59930,AS62014,AS211157,AS44907` подгрузит список пулов IP `AS62041`,`AS59930`,`AS62014`,`AS211157`,`AS44907` и будет маршрутизировать их в прокси-группу `TELEGRAM` |
| `XXX_DOMAIN`           | —                                     | Список [доменов](https://wiki.metacubex.one/ru/config/rules/#domain) через запятую для [прокси-группы](https://wiki.metacubex.one/ru/config/proxy-groups) `XXX`. Фактически создает соответствующие правила маршрутизации [rules](https://wiki.metacubex.one/ru/config/rules) в [прокси-группу](https://wiki.metacubex.one/ru/config/proxy-groups), где `XXX`-[имя прокси-группы](https://wiki.metacubex.one/ru/config/proxy-groups/#name) которое задаешь в ENV `GROUP`. Например для `GROUP` `...,telegram,...` `TELEGRAM_DOMAIN` со значением `telegram.org,telegram.com` будет маршрутизировать заданные домены в прокси-группу `TELEGRAM` |
| `XXX_SUFFIX`           | —                                     | Список [доменов](https://wiki.metacubex.one/ru/config/rules/#domain-suffix) через запятую для [прокси-группы](https://wiki.metacubex.one/ru/config/proxy-groups) `XXX`. Фактически создает соответствующие правила маршрутизации [rules](https://wiki.metacubex.one/ru/config/rules) в [прокси-группу](https://wiki.metacubex.one/ru/config/proxy-groups), где `XXX`-[имя прокси-группы](https://wiki.metacubex.one/ru/config/proxy-groups/#name) которое задаешь в ENV `GROUP`. Например для `GROUP` `...,telegram,...` `TELEGRAM_SUFFIX` со значением `telegram.org,telegram.com` будет маршрутизировать заданные домены и их поддомены в прокси-группу `TELEGRAM` |
| `XXX_KEYWORD`           | —                                     | Список [ключевых слов](https://wiki.metacubex.one/ru/config/rules/#domain-keyword) через запятую для [прокси-группы](https://wiki.metacubex.one/ru/config/proxy-groups) `XXX`. Фактически создает соответствующие правила маршрутизации [rules](https://wiki.metacubex.one/ru/config/rules) в [прокси-группу](https://wiki.metacubex.one/ru/config/proxy-groups), где `XXX`-[имя прокси-группы](https://wiki.metacubex.one/ru/config/proxy-groups/#name) которое задаешь в ENV `GROUP`. Например для `GROUP` `...,telegram,...` `TELEGRAM_KEYWORD` со значением `telegram` будет маршрутизировать домены которые содержат слово `telegram` в прокси-группу `TELEGRAM` |
| `XXX_IPCIDR`           | —                                     | Список [IP-CIDR](https://wiki.metacubex.one/ru/config/rules/#ip-cidr-ip-cidr6) через запятую для [прокси-группы](https://wiki.metacubex.one/ru/config/proxy-groups) `XXX`. Фактически создает соответствующие правила маршрутизации [rules](https://wiki.metacubex.one/ru/config/rules) в [прокси-группу](https://wiki.metacubex.one/ru/config/proxy-groups), где `XXX`-[имя прокси-группы](https://wiki.metacubex.one/ru/config/proxy-groups/#name) которое задаешь в ENV `GROUP`. Например для `GROUP` `...,telegram,...` `TELEGRAM_IPCIDR` со значением `91.108.4.0/22,91.108.56.0/22` будет маршрутизировать заданные подсети в прокси-группу `TELEGRAM` |
| `XXX_SRCIPCIDR`        | —                                     | Список [SRC-IP-CIDR](https://wiki.metacubex.one/ru/config/rules/#src-ip-cidr) через запятую для [прокси-группы](https://wiki.metacubex.one/ru/config/proxy-groups) `XXX`. Фактически создает соответствующие правила маршрутизации [rules](https://wiki.metacubex.one/ru/config/rules) в [прокси-группу](https://wiki.metacubex.one/ru/config/proxy-groups), где `XXX`-[имя прокси-группы](https://wiki.metacubex.one/ru/config/proxy-groups/#name) которое задаешь в ENV `GROUP`. Например для `GROUP` `...,socks,...` `SOCKS_IPCIDR` со значением `192.168.88.37/32,192.168.88.65/32` будет маршрутизировать весь трафик от заданных подсетей в прокси-группу `SOCKS` |
| `XXX_PRIORITY`         | —                                     | Приоритет [прокси-группы](https://wiki.metacubex.one/ru/config/proxy-groups) `XXX`, в части порядка правил в [rules](https://wiki.metacubex.one/ru/config/rules). Например, `YOUTUBE_PRIORITY` со значением `1` `TELEGRAM_PRIORITY` со значением `2` создадут правила в [rules](https://wiki.metacubex.one/ru/config/rules) по очереди сначала `YOUTUBE`, потом `TELEGRAM`. По умолчанию приоритет 1000+. |
| `XXX_ICON`         | —                                     | [Иконка прокси-группы](https://wiki.metacubex.one/ru/config/proxy-groups/#icon) указывать ссылку на иконку `"url"` |
| `XXX_HIDDEN`         | `false`                              | true/false, скрывает/показывает прокси-группу в веб панели. |
| `RULE_SETXXX_BASE64`         | —                               | Строка формата `base64#name`, где `base64`-кодированный список формата [payload](https://wiki.metacubex.one/ru/config/rule-providers/#payload) и `name`-имя прокси-группы которая создастся, так же будут автоматически добавлены правила маршрутизации для этой группы с приоритом 2000+. Кодировать строки например `DOMAIN-SUFFIX,ntc.party`, на следующей строке `DOMAIN,abc.com` создаст рул-сет с двумя правилами.  |
| `RULESXXX`             | —                                     | [Правила маршрутизации](https://wiki.metacubex.one/ru/config/rules/) ядра михомо, где `XXX` является приоритетом(порядком) правила. Например ENV `RULES1` со значением `AND,((NETWORK,udp),(DST-PORT,443)),REJECT`, создаст правило дропа QUIC с приоритетом 1, то есть будет на первом месте. Данные приоритеты общие с приоритетами групп `XXX_PRIORITY`. |

> **WG, AWG** необходимо маунтить конфиги WG, AWG в папку контейнера `/root/.config/mihomo/awg/`, будут созданы прокси-провайдеры в кол-ве файлов конфигов с именами этих файлов.

> Любой [прокси](https://wiki.metacubex.one/ru/config/proxies/) можно оформить в файл `.yaml` по документации и маунтить в папку `/root/.config/mihomo/proxies_mount/`.

> Можно создать группу из своего файла списка формата [payload](https://wiki.metacubex.one/ru/config/rule-providers/#payload), файл `name.txt`, где `name`-имя прокси-группы которая создастся, так же будут автоматически добавлены правила маршрутизации для этой группы с приоритом 2000+. Маунтить в папку `/root/.config/mihomo/rule_set_list/`. Строки например `DOMAIN-SUFFIX,ntc.party`, на следующей строке `DOMAIN,abc.com` создаст рул-сет с двумя правилами.

> В контейнер можно добавлять несколько интерфейсов VETH, они появятся как прокси-выходы в mihomo, можно выбирать через какой интерфейс выпускать трафик, а далее в RouterOS при помощи mangle отправлять по своему усмотрению, но направлять трафик в контейнер mihomo только через первый интерфейс по списку.

### Пример вставки в терминал MikroTik

Предварительно убедитесь что у вас установлен пакет `container`, а также разрешены нужные функции device-mode.
```bash
/system/device-mode/print
```
Разрешите device-mode если необходимо.
Следуйте указаниям после выполнения команды ниже, даётся 5 минут на перезагрузку электропитанием или кратковременно нажать на любую кнопку на устройстве, я рекомендую использовать любую кнопку)
```bash
/system/device-mode/update mode=advanced container=yes
```

🧩 Установка выполняется **непосредственно через терминал MikroTik** —  
достаточно **скопировать и вставить** этот фрагмент в **терминал RouterOS**,  
после чего скрипт **автоматически загрузится** из репозитория и **начнёт установку**.

```bash
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
### Пример docker compose файла

[Docker](https://github.com/Medium1992/mihomo-proxy-ros/blob/main/docker-compose.yml)

## 💖 Поддержка проекта

Если вам полезен этот проект, вы можете поддержать его донатом:  
**USDT(TRC20): TWDDYD1nk5JnG6FxvEu2fyFqMCY9PcdEsJ**


