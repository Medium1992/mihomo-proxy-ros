# 🇷🇺 mihomo-proxy-ros

## 🇷🇺 Описание на русском

**mihomo-proxy-ros** — это мультиархитектурный Docker-контейнер на базе **Mihomo**,  
поддерживающий платформы **ARM**, **ARM64**, **AMD64v1**, **AMD64v2** и **AMD64v3**.  

## 💖 Поддержка проекта

Если вам полезен этот проект, вы можете поддержать его донатом:  
**USDT(TRC20): TWDDYD1nk5JnG6FxvEu2fyFqMCY9PcdEsJ**

## 🌟 Особенности

- 🌍 Мультиархитектура: ARM, ARM64, AMD64v1-v3
- ⚙️ Автоматическая установка через терминал MikroTik
- 🔐 Обход DPI с помощью ByeDPI
- 🌐 DNSProxy: мультирезолв с нескольких DNS-серверов, поддержка всех протоколов DNS
- 🧩 Гибкая маршрутизация и управление пулом доменов
- 🛡️ Возможность добавления нескольких прокси-ссылок через переменные окружения (ENV)
- 🚀 Интеграция AWG (AmneziaWireGuard) для безопасных VPN-туннелей

В репозитории доступен **интерактивный скрипт автоматизированной установки** для **RouterOS MikroTik**,  
который также устанавливает **ByeDPI** и **dnsproxy** от **AdGuardHome**.

Во время выполнения пользователю предлагается:
- Ввести ссылку на прокси: `vless://`, `vmess://`, `ss://`, `trojan://`
- При наличии — ссылку на подписку:  
  `Enter sublink http(s)://... URL`

После завершения установки можно **гибко настроить маршрутизацию ресурсов**,  
а также **добавлять новые ссылки** через переменные окружения (`ENV`) —  
см. документацию:  
👉 [Документация по ENVs](https://github.com/vanes32/mihomo/wiki#-%D0%BA%D0%BE%D0%BD%D1%82%D0%B5%D0%B9%D0%BD%D0%B5%D1%80-mihomo_env-%D0%BD%D0%B0%D1%81%D1%82%D1%80%D0%B0%D0%B8%D0%B2%D0%B0%D0%B5%D1%82%D1%81%D1%8F-%D0%BF%D0%B5%D1%80%D0%B5%D0%BC%D0%B5%D0%BD%D0%BD%D1%8B%D0%BC%D0%B8-env) Cмотрите доступные переменные в разделе mihomo_env

Скрипт автоматически выполняет:
- Настройку роутера  
- Конфигурацию Mangle и маршрутизации  
- Установку контейнеров  
- Формирование пула доменов для ресурсов, проходящих через прокси

Таким образом, проект значительно **упрощает процесс настройки**,  
делая его удобным даже для **неопытных пользователей**,  
и обеспечивает **гибкое, готовое к использованию прокси-решение**.

---

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
