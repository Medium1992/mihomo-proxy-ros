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

**https://boosty.to/petersolomon/donate**

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

| ENVs | Default | Description |
|------------------------|---------------------------------------|---------|
| `DNS_MODE` | `fake-ip` | DNS server operation mode [DOCs](https://wiki.metacubex.one/en/config/dns/#enhanced-mode) |
| `SNIFFER` | `true` | [Domain sniffer](https://wiki.metacubex.one/en/config/sniff). Applied when routing by domains, when the domain is resolved not by mihomo |
| `FAKE_IP_RANGE` | `198.18.0.0/15` | Fake-IP pool range [DOCs](https://wiki.metacubex.one/en/config/dns/#fake-ip-range) |
| `TTL_FAKEIP` | `1` | Lifetime of FakeIP record in DNS cache in seconds |
| `FAKE_IP_FILTER` | — | Comma-separated list of domains excluded from Fake-IP [DOCs](https://wiki.metacubex.one/en/config/dns/#fake-ip-filter). When running the script, `www.youtube.com` is set due to YouTube specifics on TVs via BYEDPI and the need to modify MSS |
| `FAKE_IP_FILTER_MODE` | `blacklist` | Fakeip filter operation mode [DOCs](https://wiki.metacubex.one/en/config/dns/#fake-ip-filter-mode-blacklist) |
| `EXTERNAL_UI_URL` | [link](https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip) | Web interface link (zip archive) [DOCs](https://wiki.metacubex.one/en/config/general/#url) |
| `LOG_LEVEL` | `error` | mihomo log level (`silent`, `error`, `warning`, `info`, `debug`) [DOCs](https://wiki.metacubex.one/en/config/general/#_5) |
| `HEALTHCHECK_URL` | `https://www.gstatic.com/generate_204`| [Health-check URL](https://wiki.metacubex.one/en/config/proxy-providers/#health-checkurl) |
| `HEALTHCHECK_URL_STATUS`| `204` | Expected health-checked status [DOCs](https://wiki.metacubex.one/en/config/proxy-groups/#expected-status) |
| `HEALTHCHECK_INTERVAL` | `120` | Health-check interval in seconds [DOCs](https://wiki.metacubex.one/en/config/proxy-providers/#health-checkinterval) |
| `HEALTHCHECK_URL_BYEDPI` | `https://www.facebook.com`| [Health-check URL](https://wiki.metacubex.one/en/config/proxy-providers/#health-checkurl) for BYEDPI proxy provider |
| `HEALTHCHECK_URL_STATUS_BYEDPI`| `200` | Expected health-check status [DOCs](https://wiki.metacubex.one/en/config/proxy-groups/#expected-status) for BYEDPI proxy provider |
| `BYEDPI` | `false` | Enable proxy via byeDPI (`true`/`false`). Adds a [proxy provider](https://wiki.metacubex.one/en/config/proxy-providers) of type [SOCKS5](https://wiki.metacubex.one/en/config/proxies/socks) named `BYEDPI` |
| `BYEDPI_ADDRESS` | `192.168.255.6` | Server IP address for [proxy provider](https://wiki.metacubex.one/en/config/proxy-providers) `BYEDPI` |
| `BYEDPI_SOCKS_PORT` | `1080` | SOCKS5 server port for [proxy provider](https://wiki.metacubex.one/en/config/proxy-providers) `BYEDPI` |
| `LINK0`, `LINK1`... | — | Proxy links `vless://`, `vmess://`, `ss://`, `trojan://`... For each proxy link, a separate [proxy provider](https://wiki.metacubex.one/en/config/proxy-providers) is created |
| `SUB_LINK0`, `SUB_LINK1`... | — | Subscriptions of type `http(s)://`... For each subscription, a separate [proxy provider](https://wiki.metacubex.one/en/config/proxy-providers) is created. Supports setting [HWID](https://docs.rw/docs/features/hwid-device-limit) individually for each subscription |
| `SW_ID_FOR_HWID` | — | Setting any value that will be automatically encrypted for the [x-hwid](https://docs.rw/docs/features/hwid-device-limit) header (sha256[:16]). By default, the [x-hwid](https://docs.rw/docs/features/hwid-device-limit) header will be automatically added to any `SUB_LINK` subscription request if individual values were not set in the `SUB_LINK` ENV. During script execution, the Mikrotik router's `Software ID` is written to this ENV |
| `DEVICE_OS` | — | Setting any value. By default, the [x-device-os](https://docs.rw/docs/features/hwid-device-limit) header will be automatically added to any `SUB_LINK` subscription request if individual values were not set in the `SUB_LINK` ENV. During script execution, `RouterOS` is written to this ENV |
| `VER_OS` | — | Setting any value. By default, the [x-ver-os](https://docs.rw/docs/features/hwid-device-limit) header will be automatically added to any `SUB_LINK` subscription request if individual values were not set in the `SUB_LINK` ENV. During script execution, the current RouterOS version is written to this ENV |
| `DEVICE_MODEL` | — | Setting any value. By default, the [x-device-model](https://docs.rw/docs/features/hwid-device-limit) header will be automatically added to any `SUB_LINK` subscription request if individual values were not set in the `SUB_LINK` ENV. During script execution, the current MikroTik Board Name is written to this ENV |
| `USER_AGENT` | — | Setting any value. By default, the [User-Agent](https://docs.rw/docs/features/hwid-device-limit) header will be automatically added to any `SUB_LINK` subscription request if individual values were not set in the `SUB_LINK` ENV. During script execution, `medium1992/mihomo-proxy-ros` is written to this ENV |
| `GROUP` | — | Comma-separated list of [proxy groups](https://wiki.metacubex.one/en/config/proxy-groups), e.g., `telegram,youtube,google,ai,geoblock` will create [proxy groups](https://wiki.metacubex.one/en/config/proxy-groups) `TELEGRAM`,`YOUTUBE`,`GOOGLE`,`AI`,`GEOBLOCK`. A [proxy group](https://wiki.metacubex.one/en/config/proxy-groups) is created only if at least one of the `_GEOSITE`, `_GEOIP`, `_AS` ENVs exists for it |
| `XXX_TYPE` | `select` | [Proxy group type](https://wiki.metacubex.one/en/config/proxy-groups/#type) [](https://wiki.metacubex.one/en/config/proxy-groups/load-balance). `XXX` is the [proxy group name](https://wiki.metacubex.one/en/config/proxy-groups/#name) set in the `GROUP` ENV. For example, for `GROUP` `...,youtube,...` → `YOUTUBE_TYPE` |
| `GROUP_URL` | `https://www.gstatic.com/generate_204`| [Proxy check URL](https://wiki.metacubex.one/en/config/proxy-groups/#url) used for `XXX_TYPE` [url-test](https://wiki.metacubex.one/en/config/proxy-groups/url-test), [fallback](https://wiki.metacubex.one/en/config/proxy-groups/fallback), [load-balance](https://wiki.metacubex.one/en/config/proxy-groups/load-balance)|
| `XXX_URL` | ENV `GROUP_URL` | Setting [proxy check URL](https://wiki.metacubex.one/en/config/proxy-groups/#url) for the proxy group|
| `GROUP_URL_STATUS` | `204` | [Proxy check URL status](https://wiki.metacubex.one/en/config/proxy-groups/#expected-status) used for `XXX_TYPE` [url-test](https://wiki.metacubex.one/en/config/proxy-groups/url-test), [fallback](https://wiki.metacubex.one/en/config/proxy-groups/fallback), [load-balance](https://wiki.metacubex.one/en/config/proxy-groups/load-balance)|
| `XXX_URL_STATUS` | ENV `GROUP_URL_STATUS` | Setting [proxy check URL status](https://wiki.metacubex.one/en/config/proxy-groups/#expected-status) for the proxy group|
| `GROUP_INTERVAL` | `60` | [Proxy check interval](https://wiki.metacubex.one/en/config/proxy-groups/#interval) in seconds, used for `XXX_TYPE` [url-test](https://wiki.metacubex.one/en/config/proxy-groups/url-test), [fallback](https://wiki.metacubex.one/en/config/proxy-groups/fallback), [load-balance](https://wiki.metacubex.one/en/config/proxy-groups/load-balance)|
| `XXX_INTERVAL` | ENV `GROUP_INTERVAL` | Setting [proxy check interval](https://wiki.metacubex.one/en/config/proxy-groups/#interval) for the proxy group|
| `GROUP_TOLERANCE` | `20` | [Difference for selecting the best proxy](https://wiki.metacubex.one/en/config/proxy-groups/url-test/#tolerance) in ms, used for `XXX_TYPE` [url-test](https://wiki.metacubex.one/en/config/proxy-groups/url-test)|
| `XXX_TOLERANCE` | ENV `GROUP_TOLERANCE` | Setting [difference for selecting the best proxy](https://wiki.metacubex.one/en/config/proxy-groups/url-test/#tolerance) for the proxy group|
| `GROUP_STRATEGY` | `consistent-hashing` | [Load balancing strategy](https://wiki.metacubex.one/en/config/proxy-groups/load-balance/#strategy), used for `XXX_TYPE` [load-balance](https://wiki.metacubex.one/en/config/proxy-groups/load-balance)|
| `XXX_STRATEGY` | ENV `GROUP_STRATEGY` | Setting [load balancing strategy](https://wiki.metacubex.one/en/config/proxy-groups/load-balance/#strategy) for the proxy group|
| `XXX_USE` | *(all providers)* in order `LINKs`, `SUB_LINKs`, `WG,AWG`, `BYEDPI`, `DIRECT` | Comma-separated list of [proxy providers](https://wiki.metacubex.one/en/config/proxy-providers) to be used in the specified order for the [proxy group](https://wiki.metacubex.one/en/config/proxy-groups), where `XXX` is the [proxy group name](https://wiki.metacubex.one/en/config/proxy-groups/#name) set in the `GROUP` ENV. For example, for `GROUP` `...,youtube,...` → `YOUTUBE_USE` with value `BYEDPI,LINK1` will leave two proxy providers for the YOUTUBE group, with BYEDPI first and LINK1 second |
| `XXX_FILTER` | — | [Proxy group filter](https://wiki.metacubex.one/en/config/proxy-groups/#filter), where `XXX` is the [proxy group name](https://wiki.metacubex.one/en/config/proxy-groups/#name) set in the `GROUP` ENV. For example, for `GROUP` `...,youtube,...` → `YOUTUBE_FILTER` with value `RU\|BYEDPI` will leave proxies with the RF flag emoji and name BYEDPI for the YOUTUBE group |
| `XXX_EXCLUDE` | — | [Proxy group exclude filter](https://wiki.metacubex.one/en/config/proxy-groups/#exclude-filter), where `XXX` is the [proxy group name](https://wiki.metacubex.one/en/config/proxy-groups/#name) set in the `GROUP` ENV. For example, for `GROUP` `...,youtube,...` → `YOUTUBE_EXCLUDE` with value `RU\|BYEDPI` will exclude proxies with the RF flag emoji and name BYEDPI from the YOUTUBE group |
| `XXX_EXCLUDE_TYPE` | — | [Proxy group filter by type](https://wiki.metacubex.one/en/config/proxy-groups/#exclude-type), where `XXX` is the [proxy group name](https://wiki.metacubex.one/en/config/proxy-groups/#name) set in the `GROUP` ENV. For example, for `GROUP` `...,youtube,...` → `YOUTUBE_EXCLUDE_TYPE` with value `vmess\|direct` will exclude `vmess` and `direct` type proxies from the YOUTUBE group |
| `XXX_GEOSITE` | — | Comma-separated list of [geosite](https://github.com/MetaCubeX/meta-rules-dat/tree/meta/geo/geosite) for proxy group `XXX`. Actually creates a [rule-set](https://wiki.metacubex.one/en/config/rules/#rule-set) in rms format and corresponding routing [rules](https://wiki.metacubex.one/en/config/rules) to the [proxy group](https://wiki.metacubex.one/en/config/proxy-groups), where `XXX` is the [proxy group name](https://wiki.metacubex.one/en/config/proxy-groups/#name) set in the `GROUP` ENV. For example, for `GROUP` `...,geoblock,...` → `GEOBLOCK_GEOSITE` with value `intel,openai,xai` will load domain lists for `intel`,`openai`,`xai` resources and route them to the `GEOBLOCK` proxy provider |
| `XXX_GEOIP` | — | Comma-separated list of [geoip](https://github.com/MetaCubeX/meta-rules-dat/tree/meta/geo/geoip) for proxy group `XXX`. Actually creates a [rule-set](https://wiki.metacubex.one/en/config/rules/#rule-set) in rms format and corresponding routing [rules](https://wiki.metacubex.one/en/config/rules) to the [proxy group](https://wiki.metacubex.one/en/config/proxy-groups), where `XXX` is the [proxy group name](https://wiki.metacubex.one/en/config/proxy-groups/#name) set in the `GROUP` ENV. For example, for `GROUP` `...,geoblock,...` → `GEOBLOCK_GEOIP` with value `netflix` will load IP pools for `netflix` and route them to the `GEOBLOCK` proxy provider |
| `XXX_AS` | — | Comma-separated list of [AS](https://github.com/MetaCubeX/meta-rules-dat/tree/meta/asn) for proxy group `XXX`. Actually creates a [rule-set](https://wiki.metacubex.one/en/config/rules/#rule-set) in rms format and corresponding routing [rules](https://wiki.metacubex.one/en/config/rules) to the [proxy group](https://wiki.metacubex.one/en/config/proxy-groups), where `XXX` is the [proxy group name](https://wiki.metacubex.one/en/config/proxy-groups/#name) set in the `GROUP` ENV. For example, for `GROUP` `...,telegram,...` → `TELEGRAM_AS` with value `AS62041,AS59930,AS62014,AS211157,AS44907` will load IP pools for `AS62041`,`AS59930`,`AS62014`,`AS211157`,`AS44907` and route them to the `TELEGRAM` proxy provider |
| `XXX_DOMAIN` | — | Comma-separated list of [domains](https://wiki.metacubex.one/en/config/rules/#domain) for proxy group `XXX`. Actually creates corresponding routing [rules](https://wiki.metacubex.one/en/config/rules) to the [proxy group](https://wiki.metacubex.one/en/config/proxy-groups), where `XXX` is the [proxy group name](https://wiki.metacubex.one/en/config/proxy-groups/#name) set in the `GROUP` ENV. For example, for `GROUP` `...,telegram,...` → `TELEGRAM_DOMAIN` with value `telegram.org,telegram.com` will route the specified domains to the `TELEGRAM` proxy provider |
| `XXX_SUFFIX` | — | Comma-separated list of [domain suffixes](https://wiki.metacubex.one/en/config/rules/#domain-suffix) for proxy group `XXX`. Actually creates corresponding routing [rules](https://wiki.metacubex.one/en/config/rules) to the [proxy group](https://wiki.metacubex.one/en/config/proxy-groups), where `XXX` is the [proxy group name](https://wiki.metacubex.one/en/config/proxy-groups/#name) set in the `GROUP` ENV. For example, for `GROUP` `...,telegram,...` → `TELEGRAM_SUFFIX` with value `telegram.org,telegram.com` will route the specified domains and their subdomains to the `TELEGRAM` proxy provider |
| `XXX_IPCIDR` | — | Comma-separated list of [IP-CIDR](https://wiki.metacubex.one/en/config/rules/#ip-cidr-ip-cidr6) for proxy group `XXX`. Actually creates corresponding routing [rules](https://wiki.metacubex.one/en/config/rules) to the [proxy group](https://wiki.metacubex.one/en/config/proxy-groups), where `XXX` is the [proxy group name](https://wiki.metacubex.one/en/config/proxy-groups/#name) set in the `GROUP` ENV. For example, for `GROUP` `...,telegram,...` → `TELEGRAM_IPCIDR` with value `91.108.4.0/22,91.108.56.0/22` will route the specified subnets to the `TELEGRAM` proxy provider |
| `XXX_PRIORITY` | — | Priority of proxy group `XXX` in terms of rule order in [rules](https://wiki.metacubex.one/en/config/rules). For example, `YOUTUBE_PRIORITY` with value `1` and `TELEGRAM_PRIORITY` with value `2` will create rules in [rules](https://wiki.metacubex.one/en/config/rules) in order: first `YOUTUBE`, then `TELEGRAM` |

> **SUB_LINK** with individual parameters [x-hwid](https://docs.rw/docs/features/hwid-device-limit), [x-device-os](https://docs.rw/docs/features/hwid-device-limit), [x-ver-os](https://docs.rw/docs/features/hwid-device-limit), [x-device-model](https://docs.rw/docs/features/hwid-device-limit), [User-Agent](https://docs.rw/docs/features/hwid-device-limit) are set via `#` ```https://...#x-hwid=...#x-device-os=...#x-ver-os=...#x-device-model=...#user-agent=...```
> 
> **WG, AWG** configs need to be mounted to the container folder `/root/.config/mihomo/awg/`, proxy providers will be created in the number of config files with their filenames.

---

### MikroTik Terminal Installation Example

🧩 Installation is done **directly via MikroTik terminal** —  
just **copy and paste** the snippet below into the **RouterOS terminal**,  
then the script **automatically downloads** from the repository and **starts installation**.

```bash
:global r [/tool fetch url=https://raw.githubusercontent.com/Medium1992/mihomo-proxy-ros/refs/heads/old/script.rsc mode=https output=user as-value]
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
### Docker compose example

[Docker](https://github.com/Medium1992/mihomo-proxy-ros/blob/old/docker-compose.yml)

## 💖 Project Support

If you find this project useful, you can support it via donation:  
**USDT(TRC20): TWDDYD1nk5JnG6FxvEu2fyFqMCY9PcdEsJ**

**https://boosty.to/petersolomon/donate**
