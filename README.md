[English](/README.md) | [Русский](/README_RU.md)

# 🇬🇧 Description in English

👉 Please read the [Code of Conduct](./CODE_OF_CONDUCT.md) before participating in the project.

**mihomo-proxy-ros** is a multi-architecture Docker container based on **Mihomo**,  
supporting platforms **ARM**, **ARM64**, **AMD64v1**, **AMD64v2**, and **AMD64v3**.  
The `latest` tag includes **ARM**, **ARM64**, and **AMD64v3**.  
If you have **AMD64v1** or **AMD64v2**, you need to pull the corresponding tag.

## 💖 Project Support

If you find this project useful, you can support it via donation:  
**USDT(TRC20): TWDDYD1nk5JnG6FxvEu2fyFqMCY9PcdEsJ**

## 🌟 Features of the Automated Installation Script for MikroTik Routers

The repository contains an **interactive automated installation script** for **RouterOS MikroTik**,  
which also installs **ByeDPI** and **dnsproxy** from **AdGuardHome**.

- 🌍 Multi-architecture: ARM, ARM64, AMD64v1-v3  
- ⚙️ Automated installation via MikroTik terminal using the script at the end of this description  
- 🔐 DPI bypass via ByeDPI (thanks to [wiktorbgu](https://hub.docker.com/r/wiktorbgu/byedpi-mikrotik), you can modify the strategy in the container CMD)  
- 🌐 DNSProxy: multi-resolve from multiple DNS servers, supports all DNS protocols  
- 🧩 Flexible routing and management of domain, IP, and AS pools via ENVs  
- 🛡️ Ability to add multiple proxy links and subscriptions (including RemnaWave subscriptions with HWID) via ENVs  
- 🚀 Integration of multiple WG, AWG VPNs by copying config files into the mount folder  

During execution, the user is prompted to:  
- Enter a single proxy link: `vless://`, `vmess://`, `ss://`, `trojan://`  
- If available — a subscription link: `Enter sublink http(s)://... URL`  

The script automatically performs:  
- Router configuration  
- Mangle and routing setup  
- Container installation  
- Domain pool formation for resources routed through proxies  

This makes the project significantly **simplify the setup process**,  
making it convenient even for **inexperienced users**,  
and provides a **flexible, ready-to-use proxy solution**.

---

After installation, you can **flexibly configure resource routing** on the router itself by modifying the resources in the existing script or creating new ones ([DNS_FWD](https://github.com/Medium1992/MikroTik_DNS_FWD), [IPList](https://github.com/Medium1992/MikroTik_IPlist)),  
as well as **adding new links** and other parameters via environment variables (`ENV`) for flexible routing and container logic configuration of `mihomo-proxy-ros`.

## 🌟 ENVs Description

| Variable               | Default                                | Description |
|------------------------|----------------------------------------|------------|
| `FAKE_IP_RANGE`        | `198.18.0.0/15`                        | Fake-IP pool range [DOCs](https://wiki.metacubex.one/ru/config/dns/#fake-ip-range) |
| `TTL_FAKEIP`           | `1`                                    | TTL for FakeIP entries in DNS cache (seconds) |
| `FAKE_IP_FILTER`       | —                                      | Comma-separated list of domains excluded from Fake-IP [DOCs](https://wiki.metacubex.one/ru/config/dns/#fake-ip-filter). By default, `www.youtube.com` is excluded due to YouTube behavior on TVs via BYEDPI and the need to adjust MSS |
| `EXTERNAL_UI_URL`      | `https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip` | Web interface link (zip archive) [DOCs](https://wiki.metacubex.one/ru/config/general/#url) |
| `LOG_LEVEL`            | `error`                                | Mihomo log level (`silent`, `error`, `warning`, `info`, `debug`) [DOCs](https://wiki.metacubex.one/ru/config/general/#_5) |
| `INTERVAL`             | `120`                                  | Health-check interval in seconds [DOCs](https://wiki.metacubex.one/ru/config/proxy-providers/#health-checkinterval) |
| `BYEDPI`               | `false`                                | Enable proxy via ByeDPI (`true`/`false`). Adds a [proxy provider](https://wiki.metacubex.one/ru/config/proxy-providers) of type [SOCKS5](https://wiki.metacubex.one/ru/config/proxies/socks) named `BYEDPI` |
| `BYEDPI_ADDRESS`       | `192.168.255.6`                        | Server IP address for [proxy provider](https://wiki.metacubex.one/ru/config/proxy-providers) `BYEDPI` |
| `BYEDPI_SOCKS_PORT`    | `1080`                                 | SOCKS5 port for [proxy provider](https://wiki.metacubex.one/ru/config/proxy-providers) `BYEDPI` |
| `LINK0`, `LINK1`...    | —                                      | Proxy links `vless://`, `vmess://`, `ss://`, `trojan://`... Each link creates a separate [proxy provider](https://wiki.metacubex.one/ru/config/proxy-providers) |
| `SUB_LINK0`, `SUB_LINK1`... | —                                 | Subscription links `http(s)://`... Each subscription creates a separate [proxy provider](https://wiki.metacubex.one/ru/config/proxy-providers). Supports setting [HWID](https://docs.rw/docs/features/hwid-device-limit) per subscription |
| `SW_ID_FOR_HWID`       | —                                      | Any value which will be automatically encrypted for header [x-hwid](https://docs.rw/docs/features/hwid-device-limit) (sha256[:16]). By default, `x-hwid` header is automatically added for any `SUB_LINK` request if individual values were not set in ENV. Stores Mikrotik Router Software ID |
| `DEVICE_OS`            | —                                      | Any value. By default, `x-device-os` header is automatically added for `SUB_LINK` requests if ENV `SUB_LINK` values were not set. Stores RouterOS version |
| `VER_OS`               | —                                      | Any value. By default, `x-ver-os` header is automatically added for `SUB_LINK` requests if ENV `SUB_LINK` values were not set. Stores current RouterOS version |
| `DEVICE_MODEL`         | —                                      | Any value. By default, `x-device-model` header is automatically added for `SUB_LINK` requests if ENV `SUB_LINK` values were not set. Stores current Mikrotik Board Name |
| `USER_AGENT`           | —                                      | Any value. By default, `User-Agent` header is automatically added for `SUB_LINK` requests if ENV `SUB_LINK` values were not set. Stores `medium1992/mihomo-proxy-ros` |
| `GROUP`                | —                                      | Comma-separated list of [proxy groups](https://wiki.metacubex.one/ru/config/proxy-groups). For example: `telegram,youtube,google,ai,geoblock` will create `TELEGRAM`, `YOUTUBE`, `GOOGLE`, `AI`, `GEOBLOCK`. A group is created only if at least one ENV `_GEOSITE`, `_GEOIP`, or `_AS` exists |
| `XXX_TYPE`             | `select`                               | [Proxy group type](https://wiki.metacubex.one/ru/config/proxy-groups/#type) (`select`, `url-test`, `fallback`, `load-balance`). `XXX` is the proxy group name in ENV `GROUP`. Example: `GROUP=...,youtube,...` → `YOUTUBE_TYPE` |
| `XXX_USE`              | *(all providers)* order: `LINKs`, `SUB_LINKs`, `WG,AWG`, `BYEDPI`, `DIRECT` | List of [proxy providers](https://wiki.metacubex.one/ru/config/proxy-providers) in order for the proxy group `XXX`. Example: `GROUP=...,youtube,...` and `YOUTUBE_USE=BYEDPI,LINK1` uses two providers for YOUTUBE: BYEDPI first, then LINK1 |
| `XXX_FILTER`           | —                                      | [Proxy group filter](https://wiki.metacubex.one/ru/config/proxy-groups/#filter). Example: `YOUTUBE_FILTER=RU\|BYEDPI` will only use proxies with Russian flag emoji and name BYEDPI |
| `XXX_EXCLUDE`          | —                                      | [Proxy group exclusion filter](https://wiki.metacubex.one/ru/config/proxy-groups/#exclude-filter). Example: `YOUTUBE_EXCLUDE=RU\|BYEDPI` excludes proxies with Russian flag emoji and name BYEDPI |
| `XXX_GEOSITE`          | —                                      | Comma-separated list of [geosite](https://github.com/MetaCubeX/meta-rules-dat/tree/meta/geo/geosite) for proxy group `XXX`. Creates a [rule-set](https://wiki.metacubex.one/ru/config/rules/#rule-set) and routing [rules](https://wiki.metacubex.one/ru/config/rules) for the group. Example: `GEOBLOCK_GEOSITE=intel,openai,xai` |
| `XXX_GEOIP`            | —                                      | Comma-separated list of [geoip](https://github.com/MetaCubeX/meta-rules-dat/tree/meta/geo/geoip) for proxy group `XXX`. Creates rule-set and routing rules. Example: `GEOBLOCK_GEOIP=netflix` |
| `XXX_AS`               | —                                      | Comma-separated list of [AS](https://github.com/MetaCubeX/meta-rules-dat/tree/meta/asn) for proxy group `XXX`. Example: `TELEGRAM_AS=AS62041,AS59930,AS62014,AS211157,AS44907` |
| `XXX_PRIORITY`         | —                                      | Priority of proxy group `XXX` in [rules](https://wiki.metacubex.one/ru/config/rules). Example: `YOUTUBE_PRIORITY=1`, `TELEGRAM_PRIORITY=2` |

> **SUB_LINK** with individual parameters [x-hwid](https://docs.rw/docs/features/hwid-device-limit), [x-device-os](https://docs.rw/docs/features/hwid-device-limit), [x-ver-os](https://docs.rw/docs/features/hwid-device-limit), [x-device-model](https://docs.rw/docs/features/hwid-device-limit), [User-Agent](https://docs.rw/docs/features/hwid-device-limit) are set via `#`  
> ```https://...#x-hwid=...#x-device-os=...#x-ver-os=...#x-device-model=...#user-agent=...```

> **WG, AWG** configs must be mounted to the container folder `/root/.config/mihomo/awg/`. Proxy providers will be created for each config file.

---

### MikroTik Terminal Installation Example

🧩 Installation is done **directly via MikroTik terminal** —  
just **copy and paste** the snippet below into the **RouterOS terminal**,  
then the script **automatically downloads** from the repository and **starts installation**.

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

## 💖 Project Support

If you find this project useful, you can support it via donation:  
**USDT(TRC20): TWDDYD1nk5JnG6FxvEu2fyFqMCY9PcdEsJ**
