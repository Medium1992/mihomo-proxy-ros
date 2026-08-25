[English](/README.md) | [Русский](/README_RU.md) · [Telegram](https://t.me/+96HVPF3Ww6o3YTNi) · [Code of Conduct](./CODE_OF_CONDUCT.md)

# mihomo-proxy-ros

> Multi-arch Docker container for **MikroTik RouterOS**: [mihomo](https://github.com/metacubex/mihomo) + [byedpi](https://github.com/hufrea/byedpi) + [zapret](https://github.com/bol-van/zapret) + [zapret2](https://github.com/bol-van/zapret2), fully ENV-driven, with a built-in sh-only WebUI that generates ready-to-paste RouterOS commands.

[![GitHub release](https://img.shields.io/github/v/release/Medium1992/mihomo-proxy-ros?label=release)](https://github.com/Medium1992/mihomo-proxy-ros/releases)
[![Docker Pulls](https://img.shields.io/docker/pulls/medium1992/mihomo-proxy-ros?logo=docker&label=docker%20pulls)](https://hub.docker.com/r/medium1992/mihomo-proxy-ros)
[![Docker Image Size](https://img.shields.io/docker/image-size/medium1992/mihomo-proxy-ros/latest?logo=docker&label=image%20size)](https://hub.docker.com/r/medium1992/mihomo-proxy-ros)
[![License](https://img.shields.io/github/license/Medium1992/mihomo-proxy-ros)](./LICENSE)
![Platforms](https://img.shields.io/badge/arch-amd64%20%7C%20arm64%20%7C%20armv7%20%7C%20armv5-blue)
[![Telegram](https://img.shields.io/badge/Telegram-group-blue?logo=telegram)](https://t.me/+96HVPF3Ww6o3YTNi)

## ✨ Features

- 🌍 **Multi-arch**: ARM, ARM64, AMD64v1/v2/v3 (the `latest` tag bundles ARM, ARM64, AMD64v3 — for v1/v2 pull the dedicated tag)
- 🖥 **Built-in WebUI** on port `80` — visual ENV editor, YAML validator, AWG/proxy/rule-set file managers, generates MikroTik terminal commands
- 🔐 **DPI bypass** via [ByeDPI](https://github.com/hufrea/byedpi), [Zapret/nfqws](https://github.com/bol-van/zapret), [Zapret2/nfqws2](https://github.com/bol-van/zapret2) (nfqws/nfqws2 — amd64/arm64 only)
- 🧩 **Flexible routing** by domain / IP / GeoSite / GeoIP / ASN, all controlled via ENV
- 🛡 Multiple proxy links and **subscriptions** (including [RemnaWave](https://docs.rw/docs/features/hwid-device-limit) with HWID)
- 🚀 **WireGuard / AmneziaWG, OpenVPN and TrustTunnel** integration through mounted configuration folders
- 📦 Single-step **automated install** via MikroTik terminal snippet
- 🛠 Multiple VETH interfaces appear as outbound proxies → mangle in RouterOS to send traffic where you want

> Tested with **RouterOS 7.20+**. Requires the `container` package and `device-mode container=yes`.

## ⚡ Quickstart

1. **Enable container support** on RouterOS:
   ```
   /system/device-mode/print
   /system/device-mode/update mode=advanced container=yes traffic-gen=yes
   ```
   You have ~5 minutes to confirm via power-cycle or physical button.

2. **Paste the install snippet** into RouterOS terminal — see [§ RouterOS install](#-routeros-install) below.

3. **Open the WebUI**: `http://<container-ip>:80/`
   Configure ENVs visually, click *MikroTik commands* → copy → paste back into RouterOS terminal.

4. **Or use mihomo's panel**: `http://<container-ip>:9090/` (UI from `EXTERNAL_UI_URL`).

## 🖥 WebUI

**`http://<container-ip>:80/`** — local management panel served by busybox httpd from the container itself.

> [!IMPORTANT]
> The panel is protected by HTTP basic auth. **The default is `admin` / `admin` — change it.**
> Go to *Tools → Web UI password*, type a new password and get the md5 hash plus ready-made
> RouterOS commands. The plaintext password is never stored — only the hash goes into
> `BASIC_AUTH_HASH`. Locked out? Remove the `BASIC_AUTH_HASH` env and restart the container
> to fall back to `admin`.

ENV values are not stored in browser localStorage — draft edits live on the server
(`/dev/shm/mihomo-ui/draft.json`, tmpfs), so a fresh browser with no cache and no cookies opens the
panel in its current state and no secrets are left on disk.

`WEB_MASK_SECRETS=true` additionally hides `LINK*`, `SUB_LINK*`, `SUB_LINK*_HEADERS`, `SOCKS*`,
`MIXED_IN_USER*` and `UI_SECRET` values in the HTML: the field shows a placeholder and the real
value is fetched on demand via a reveal button. Off by default — the panel exists to edit them.

<p align="center">
  <img src="docs/screenshots/webui-1.png" width="800" alt="WebUI — overview">
</p>

<details>
<summary>📸 More screenshots</summary>

<p align="center">
  <img src="docs/screenshots/webui-2.png" width="800" alt="WebUI — proxy providers"><br><br>
  <img src="docs/screenshots/webui-3.png" width="800" alt="WebUI — proxy groups"><br><br>
  <img src="docs/screenshots/webui-4.png" width="800" alt="WebUI — DPI / zapret files"><br><br>
  <img src="docs/screenshots/webui-5.png" width="800" alt="WebUI — YAML / rule-sets">
</p>

</details>


It **does not modify** the running container directly. Instead it:

- shows every ENV that `entrypoint.sh` understands, grouped into logical pages (Core, Providers, DPI, Groups, Rules, Rule-sets, YAML, Tools)
- tracks edits locally in `localStorage` against the original values
- generates the exact `/container/envs/add|set|remove` commands you need to paste into RouterOS terminal, plus the final `/container/stop`+`start` to apply

What's also in there:

- **Proxy YAML editor** with templates for VLESS, VMess, Trojan, Shadowsocks, SSR, Snell, AnyTLS, Mieru, WireGuard / AmneziaWG, Hysteria, Hysteria2, TUIC, MASQUE, Tailscale, ZeroTier, TrustTunnel, OpenVPN and SSH — *"Load template"* fills the textarea
- **Live `mihomo -t` validation** of proxy YAMLs before save, plus uniqueness check of `name:` field across all providers
- **AWG editor** with full `[Interface]/[Peer]/[Mihomo]` template covering every key the parser understands
- **DPI files manager** — upload `.bin` fakes to `/zapret-fakebin/`, edit text lists in `/zapret-lists/`, with filter
- **Rule-set builder** — paste a payload-format list, get a `RULE_SETxx_BASE64` ENV ready

All runtime artifacts (generated config, provider YAMLs, pre-rendered HTML) live in `/dev/shm` — **zero flash wear**.

## 📁 Mount points

| Path in container | Purpose | Format |
|---|---|---|
| `/root/.config/mihomo/awg/` | WireGuard / AmneziaWG configs → become proxy-providers | `*.conf` |
| `/root/.config/mihomo/openvpn/` | OpenVPN configs → become proxy-providers | `*.ovpn` / `*.conf` |
| `/root/.config/mihomo/trusttunnel/` | TrustTunnel configs → become proxy-providers | `*.toml` |
| `/root/.config/mihomo/proxies_mount/` | Custom proxy-providers in mihomo native YAML | `*.yaml` / `*.yml` |
| `/root/.config/mihomo/rule_set_list/` | Custom rule-set lists in [payload](https://wiki.metacubex.one/en/config/rule-providers/#payload) format | `*.txt` (filename = group name) |
| `/zapret-fakebin/` | Binary fake-packets used by `nfqws --dpi-desync-fake-*` | `*.bin` |
| `/zapret-lists/` | Text domain / IP lists for nfqws lua scripts | `*.txt` |

You can also attach **multiple VETH interfaces** to the container — they show up as direct outbounds in mihomo, route to whichever you want via mangle in RouterOS. Inbound traffic to the container must enter via the **first VETH** only.

## 🧑‍🍳 A few examples

### YouTube via a single VLESS link
```yaml
LINK1: "vless://uuid@server:443?type=tcp&security=reality&pbk=...#myvless"
GROUP: "youtube"
YOUTUBE_USE: "LINK1"
YOUTUBE_GEOSITE: "youtube"
```

### Telegram via AmneziaWG (config dropped into `/root/.config/mihomo/awg/tunnel1.conf`)
```yaml
GROUP: "telegram"
TELEGRAM_USE: "tunnel1"
TELEGRAM_GEOSITE: "telegram"
TELEGRAM_GEOIP: "telegram"
TELEGRAM_AS: "AS62041,AS59930,AS62014,AS211157,AS44907"
```

### Discord + Google via ByeDPI strategy
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

### Route a specific LAN subnet via SOCKS5
```yaml
SOCKS1: "server=192.168.88.10#port=1080#username=user#password=pass"
GROUP: "lan_socks"
LAN_SOCKS_USE: "SOCKS1"
LAN_SOCKS_SRCIPCIDR: "192.168.88.0/24"
```

## ⚙️ Environment variables

### Core

| ENV | Default | Description |
|---|---|---|
| `TPROXY` | `true` | On RoS ≥ 7.21 with `arm64`/`amd64`, the container uses **NFTables**. `true` → TProxy in (TCP+UDP); `false` → Redirect (TCP) + TUN (UDP). |
| `DNS_MODE` | `fake-ip` | DNS [enhanced-mode](https://wiki.metacubex.one/en/config/dns/#enhanced-mode). |
| `NAMESERVER_POLICY` | — | Per-domain DNS resolver routing. Format: `domain1#dns1,domain2#dns2`. [Docs](https://wiki.metacubex.one/en/config/dns/#nameserver-policy). |
| `SNIFFER` | `true` | [Domain sniffer](https://wiki.metacubex.one/en/config/sniff) for domain-based rules when not resolved by mihomo. |
| `FAKE_IP_RANGE` | `198.18.0.0/15` | [fake-ip pool](https://wiki.metacubex.one/en/config/dns/#fake-ip-range). |
| `FAKE_IP_TTL` | `1` | [fake-ip cache TTL](https://wiki.metacubex.one/en/config/dns/#fake-ip-ttl) (seconds). |
| `FAKE_IP_FILTERxx` | — | Rules list for DNS server in `rule` mode. |

### DNS servers

Three server lists inside the `dns` block are configurable, items separated by commas. The defaults reproduce exactly what the container used to hardcode, so an unset — or cleared — variable changes nothing: the container falls back to the built-in list. The rest of the `dns` block stays as it was. The web panel edits the lists under **Core and DNS → DNS**.

| ENV | Default | Description |
|---|---|---|
| `DNS_DEFAULT_NAMESERVER` | `8.8.8.8,9.9.9.9,1.1.1.1` | [default-nameserver](https://wiki.metacubex.one/en/config/dns/#default-nameserver): plain DNS used to resolve the DoH/DoT servers and the proxies themselves. Pure IPs only — mihomo rejects domains here. |
| `DNS_NAMESERVER` | three DoH: Google, Quad9, Cloudflare | [nameserver](https://wiki.metacubex.one/en/config/dns/#nameserver): main servers for queries not matched by `NAMESERVER_POLICY`. |
| `DNS_PROXY_SERVER_NAMESERVER` | the same three DoH + `common.dot.dns.yandex.net` | [proxy-server-nameserver](https://wiki.metacubex.one/en/config/dns/#proxy-server-nameserver): resolves the proxy servers’ own domains. |

`DNS_DEFAULT_NAMESERVER` and `DNS_NAMESERVER` also build `DNS_ruleset` — the rule set that sends traffic aimed at DNS servers into the `DNS` group. Domains land there as `DOMAIN,...`, literal addresses as `IP-CIDR,.../32,no-resolve`; the scheme, port and everything after `#` are stripped, and `system`, `dhcp://` and `rcode://` are skipped. `DNS_PROXY_SERVER_NAMESERVER` is not included: mihomo handles those queries outside the routing rules.

### Logs & UI

| ENV | Default | Description |
|---|---|---|
| `LOG_LEVEL` | `error` | mihomo log level: `silent`/`error`/`warning`/`info`/`debug`. [Docs](https://wiki.metacubex.one/en/config/general/#_5). |
| `EXTERNAL_UI_URL` | [MetaCube zip](https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip) | Source zip for the panel served on `:9090`. [Docs](https://wiki.metacubex.one/en/config/general/#url). |
| `UI_SECRET` | — | Secret for the external controller (port `9090`). Empty = no auth (LAN-only setups). |

The «Mihomo dashboard» button carries the controller address and the secret in the link itself; MetaCubeXD, Zashboard and Yacd-meta all connect from it. On top of that the container writes the address into MetaCubeXD's `ui/config.js` (`defaultBackendURL: location.origin`) once the core is up, which covers opening `:9090/ui/` directly instead of using the button. The secret cannot travel that way -- only the link carries it.

### Web UI on `:80`

| ENV | Default | Description |
|---|---|---|
| `BASIC_AUTH_USER` | `admin` | Basic auth login for the web UI. Leaving both this and `BASIC_AUTH_HASH` empty disables auth. |
| `BASIC_AUTH_HASH` | hash of `admin` | md5 hash of the password (`$1$salt$hash`). Generate it in *Tools → Web UI password*; the plaintext password is never stored in env. |
| `WEB_MASK_SECRETS` | `false` | Hide `LINK*`/`SUB_LINK*`/`SOCKS*`/`MIXED_IN_USER*`/`UI_SECRET` values in the panel HTML behind a reveal button. Off by default. |
| `WEB_CSRF` | `on` | `Referer` check on state-changing CGI requests. Set to `off` if you call the panel endpoints from your own scripts. |
| `ALLOW_PRIVATE_FETCH` | `false` | Let `http-fetch` / `xray2mihomo-sub` reach loopback and private subnets (e.g. a subscription hosted on your own NAS). |
| `WEB_API_PORT` | `81` | Port of the helper listener bound to `127.0.0.1` that serves `xray2mihomo-sub` — mihomo fetches it from `SUB_LINK*`, so it carries no password. Not reachable from the LAN. `0` disables it. |

#### Subscription converter in `SUB_LINK*`

The link from *Tools → xray2mihomo* can go straight into `SUB_LINK*`:

```
SUB_LINK1=http://127.0.0.1:81/cgi-bin/xray2mihomo-sub?sub=https://provider.example/sub&format=uri
```

#### Encrypted Happ links in `SUB_LINK*`

`SUB_LINKxx` accepts `happ://crypt…happ://crypt5` directly:

```
SUB_LINK1=happ://crypt5/fzvdpvKZ85Qn2aSN…
SUB_LINK1_HEADERS=x-hwid=ABC-123#user-agent=Happ/3.22.1
```

The container decrypts the link at startup (`www/lib/happ.sh`, openssl), recovers the real
subscription URL and — since Happ serves Xray JSON — routes it through the local converter
(`format=uri`, the shape mihomo parses most reliably). Headers from `SUB_LINKxx_HEADERS` are forwarded upstream by the converter rather
than sent by mihomo, so HWID and user-agent still reach the provider. Use `SUB_LINKxx_CONVERT`
to override the behaviour.

Decryption keys come from `www/assets/happ.js` — the same file the panel uses
(*Tools → Happ crypto*). When Happ ships a new key you will see
`unknown crypt5 marker: …` in the log, which means the `HAPP1..HAPP4` secrets need refreshing.

Port `81` exists only on the container's loopback and is not password-protected — otherwise mihomo,
which refreshes the provider on `interval`, would get a 401 from the panel on `:80`. That webroot
holds a **single** CGI, the converter; nothing that reads or writes files is exposed there.
Configs still pointing at port 80 are rewritten to `:81` automatically at startup (the env value is
left untouched — only the generated `config.yaml` is adjusted).

### Interfaces (VETH)

| ENV | Default | Description |
|---|---|---|
| `<iface>_GATEWAY` | network + 1 | Overrides the interface gateway. The address must belong to the interface subnet — otherwise it is ignored (with a log line) and the derived one is used, so connectivity is never lost. By default it is guessed as "network address + 1" (`192.168.5.0/24` → `192.168.5.1`); if the real gateway differs, that interface does not work as an outbound. |
| `<iface>_GATEWAY1`, `_GATEWAY2`, … | — | `ip#name`. Each one adds a separate outbound to mihomo under that name: its own fwmark, its own routing table (600+), traffic leaves via the given gateway on the same interface. Without `#name` the outbound is called `<iface>_GATEWAYn`. An address outside the interface subnet is rejected. |

The env name matches the interface name; both the exact case and an uppercased form with special characters replaced are accepted — `eth1_GATEWAY` and `ETH1_GATEWAY` both work for `eth1`, `VETH_LAN_GATEWAY` for `veth-lan`.

This is how a neighbouring container becomes an outbound: run it in the same subnet, point a gateway at its address, and a button with your chosen name shows up in mihomo.

```
ETH1_GATEWAY=192.168.5.254
ETH1_GATEWAY1=192.168.5.10#neighbour-vpn
ETH1_GATEWAY2=192.168.5.11#neighbour-tor
```

Special characters in the name (space, comma, colon, quotes, slashes) are replaced with `_` — the name ends up as a YAML key, a filename, and inside comma-separated `GROUP_USE` lists.

### Health-check

| ENV | Default | Description |
|---|---|---|
| `HEALTHCHECK_PROVIDER` | `true` | `true` → checks use `HEALTHCHECK_*`. `false` → checks use `GROUP_URL`/`XXX_URL`/etc. (per-group). |
| `HEALTHCHECK_URL` | `https://www.gstatic.com/generate_204` | [Default URL](https://wiki.metacubex.one/en/config/proxy-providers/#health-checkurl). |
| `HEALTHCHECK_URL_STATUS` | `204` | [Expected status](https://wiki.metacubex.one/en/config/proxy-groups/#expected-status). |
| `HEALTHCHECK_INTERVAL` | `120` | Interval (seconds). [Docs](https://wiki.metacubex.one/en/config/proxy-providers/#health-checkinterval). |
| `HEALTHCHECK_URL_BYEDPI` | `https://www.facebook.com` | URL for `BYEDPI` provider. |
| `HEALTHCHECK_URL_STATUS_BYEDPI` | `200` | Expected status for `BYEDPI` provider. |
| `HEALTHCHECK_URL_ZAPRET` | `https://www.facebook.com` | URL for all `ZAPRET`/`ZAPRET2` providers. |
| `HEALTHCHECK_URL_STATUS_ZAPRET` | `200` | Expected status for `ZAPRET`/`ZAPRET2` providers. |

### DPI engines

| ENV | Default | Description |
|---|---|---|
| `BYEDPI_CMDxx` | — | [ByeDPI](https://github.com/hufrea/byedpi) strategy. `BYEDPI_CMD` → outbound `BYEDPI`; `BYEDPI_CMD1` → `BYEDPI_1`; etc. Pick strategies with [byedpi-orchestrator](https://hub.docker.com/r/vindibona/byedpi-orchestrator). |
| `ZAPRET_CMDxx` | — | [Zapret/nfqws](https://github.com/bol-van/zapret) strategy. Append `#NAME` at the end of the value to name the proxy in the mihomo dashboard (`ZAPRET_2` becomes `ZAPRET_2_NAME`); the proxy provider keeps its name and the label never reaches the nfqws command line. The same applies to `ZAPRET2_CMDxx` and `BYEDPI_CMDxx`. Bundled fakes in `/zapret-fakebin/` (e.g. `quic_initial_www_google_com.bin`) and lists in `/zapret-lists/` (`ipset-all.txt`, `list-general.txt`, etc.). |
| `ZAPRET2_CMDxx` | — | [Zapret2/nfqws2](https://github.com/bol-van/zapret2) strategy. |
| `ZAPRET2_WG_CMD` | *(default with `quic_initial_vk_com` blob)* | Dedicated nfqws2 strategy for WireGuard handshake routing. |
| `ZAPRET_PACKETSxx` | `12` | Number of first packets routed through the nfqws queue. `xx` overrides per-provider. Non-positive values = unlimited (always queued). |
| `ZAPRET2_PACKETSxx` | `12` | Same for nfqws2. |

### Proxy providers

| ENV | Default | Description |
|---|---|---|
| `LINK0`, `LINK1`, … | — | Single proxy URL: `vless://`, `vmess://`, `ss://`, `trojan://`, `vpn://`. Each creates a [proxy-provider](https://wiki.metacubex.one/en/config/proxy-providers). |
| `SUB_LINK0`, `SUB_LINK1`, … | — | Subscription URL (`http(s)://...`). One [proxy-provider](https://wiki.metacubex.one/en/config/proxy-providers) per sub, supports per-sub HWID via headers. |
| `SUB_LINKxx_PROXY` | `DIRECT` | Which [proxy](https://wiki.metacubex.one/en/config/proxy-providers/#proxy) is used to fetch the subscription. Example: `SUB_LINK1_PROXY=proxies1`. |
| `SUB_LINKxx_HEADERS` | — | Custom [HTTP headers](https://wiki.metacubex.one/en/config/proxy-providers/#header) for the sub request. Format: `key1=val1#key2=val2`. HWID example: `x-hwid=...#x-device-os=...#x-ver-os=...#x-device-model=...#user-agent=...`. |
| `SUB_LINK_INTERVAL` | `3600` | Default [refresh interval](https://wiki.metacubex.one/en/config/proxy-providers/#interval) (s) for all subs. |
| `SUB_LINKxx_INTERVAL` | inherits `SUB_LINK_INTERVAL` | Override interval per sub. |
| `SUB_LINKxx_FILTER` | — | Provider-level [filter](https://wiki.metacubex.one/en/config/proxy-providers/#filter) regex — keep only nodes whose name matches. Multiple patterns separated by `\|`. |
| `SUB_LINKxx_EXCLUDE_FILTER` | — | Provider-level [exclude-filter](https://wiki.metacubex.one/en/config/proxy-providers/#exclude-filter) regex. |
| `SUB_LINKxx_EXCLUDE_TYPE` | — | Provider-level [exclude-type](https://wiki.metacubex.one/en/config/proxy-providers/#exclude-type) — list of [Adapter Type](https://github.com/MetaCubeX/mihomo/blob/fbead56ec97ae93f904f4476df1741af718c9c2a/constant/adapters.go#L18-L45) (case-insensitive) via `\|`. Example: `vmess\|direct`. |
| `SUB_LINKxx_ADDITIONAL_PREFIX` | — | Goes into `override.`[`additional-prefix`](https://wiki.metacubex.one/en/config/proxy-providers/#overrideadditional-prefix) — fixed prefix for every node name. |
| `SUB_LINKxx_CONVERT` | `auto` | What to do with the subscription body: `auto` — happ links go through the local converter (Happ serves Xray JSON), plain links reach mihomo untouched; `xray2mihomo` — always convert; `none` — never. Requires `WEB_API_PORT` to be enabled. |
| `SUB_LINKxx_ADDITIONAL_SUFFIX` | — | Goes into `override.`[`additional-suffix`](https://wiki.metacubex.one/en/config/proxy-providers/#overrideadditional-suffix) — fixed suffix for every node name. |
| `SOCKS0`, `SOCKS1`, … | — | SOCKS5 proxy. Format: `server=ip#port=1080#username=#password=#tls=#fingerprint=#skip-cert-verify=#udp=#ip-version=`. [Docs](https://wiki.metacubex.one/en/config/proxies/socks/). |
| `XXX_DIALER_PROXY` | — | [Override dialer-proxy](https://wiki.metacubex.one/en/config/proxy-providers/#override) — route this provider's connections through another group. Example: `LINK1_DIALER_PROXY=YouTube`. |

### Proxy groups

`GROUP` declares the set of named groups. For each group `XXX` (uppercased), prefix-ENV variants below are honored.

> 💡 In addition to user-defined groups, three "system" groups are hardwired in entrypoint: `GROUP_*` (defaults for every group), `GLOBAL_*` (the special GLOBAL group) and `DNS_*` (a dedicated group for DNS resolution). All three accept the same prefix ENVs as the table below.

| ENV | Default | Description |
|---|---|---|
| `GROUP` | — | Comma-separated list of [proxy groups](https://wiki.metacubex.one/en/config/proxy-groups). `telegram,youtube,google,ai,geoblock` → groups `TELEGRAM, YOUTUBE, GOOGLE, AI, GEOBLOCK`. A group is created only if it has at least one resource (`XXX_*`) or `XXX_USE`. |
| `XXX_TYPE` | `select` | [Group type](https://wiki.metacubex.one/en/config/proxy-groups/#type): `select` / `url-test` / `fallback` / `load-balance`. |
| `XXX_USE` | *all providers in order: LINKs, SUB_LINKs, WG/AWG, BYEDPI, DIRECT* | Subset of [providers](https://wiki.metacubex.one/en/config/proxy-providers) to include. Example: `YOUTUBE_USE=BYEDPI,LINK1`. |
| `XXX_PROXIES` | — | Explicit [proxies](https://wiki.metacubex.one/en/config/proxy-groups/#proxies) (specific nodes, not providers), comma-separated. Alternative/addition to `XXX_USE`. |
| `XXX_FILTER` | — | [Provider name filter regex](https://wiki.metacubex.one/en/config/proxy-groups/#filter). Example: `RU\|BYEDPI`. |
| `XXX_EXCLUDE` | — | [Exclude regex](https://wiki.metacubex.one/en/config/proxy-groups/#exclude-filter). |
| `XXX_EXCLUDE_TYPE` | — | [Exclude by type](https://wiki.metacubex.one/en/config/proxy-groups/#exclude-type). Example: `vmess\|direct`. |
| `XXX_DNS` | — | DNS resolver for this group's domain rules. Example: `https://dns.google/dns-query#disable-qtype-65=true&disable-ipv6=true`. |
| `XXX_ICON` | — | URL for the group's [icon](https://wiki.metacubex.one/en/config/proxy-groups/#icon). |
| `XXX_HIDDEN` | `false` | Hide the group from mihomo's WebUI. |
| `GROUP_URL` / `XXX_URL` | `https://www.gstatic.com/generate_204` | Per-group health-check URL when `HEALTHCHECK_PROVIDER=false` and `XXX_TYPE` is `url-test`/`fallback`/`load-balance`. |
| `GROUP_URL_STATUS` / `XXX_URL_STATUS` | `204` | Expected status for the above. |
| `GROUP_INTERVAL` / `XXX_INTERVAL` | `60` | Check interval (seconds). |
| `GROUP_TOLERANCE` / `XXX_TOLERANCE` | `20` | [URL-test tolerance](https://wiki.metacubex.one/en/config/proxy-groups/url-test/#tolerance) in ms. |
| `GROUP_STRATEGY` / `XXX_STRATEGY` | `consistent-hashing` | [Load-balance strategy](https://wiki.metacubex.one/en/config/proxy-groups/load-balance/#strategy). |

### Routing rules (per group)

Each entry creates an automatic [rule](https://wiki.metacubex.one/en/config/rules) targeting the group `XXX`. Named `XXX_GEOSITE/GEOIP/AS` entries are built from the [meta-rules-dat](https://github.com/MetaCubeX/meta-rules-dat) repo. A remote `.mrs`, `.yaml`, or `.yml` URL in `XXX_GEOSITE` or `XXX_GEOIP` creates a separate HTTP rule-set.

| ENV | Description |
|---|---|
| `XXX_GEOSITE` | Comma-separated [geosite](https://github.com/MetaCubeX/meta-rules-dat/tree/meta/geo/geosite) names or `http(s)` URLs ending in `.mrs`, `.yaml`, or `.yml`. `.mrs` URLs use `behavior: domain`; YAML URLs use `behavior: classical`. Example: `GEOBLOCK_GEOSITE=intel,https://example.com/domains.mrs`. |
| `XXX_GEOIP` | Comma-separated [geoip](https://github.com/MetaCubeX/meta-rules-dat/tree/meta/geo/geoip) names or `http(s)` URLs ending in `.mrs`, `.yaml`, or `.yml`. `.mrs` URLs use `behavior: ipcidr`; YAML URLs use `behavior: classical`. Example: `GEOBLOCK_GEOIP=netflix,https://example.com/mixed.yaml`. |
| `XXX_AS` | [AS](https://github.com/MetaCubeX/meta-rules-dat/tree/meta/asn) numbers. Example: `TELEGRAM_AS=AS62041,AS59930,AS62014,AS211157,AS44907`. |
| `XXX_DOMAIN` | Exact [DOMAIN](https://wiki.metacubex.one/en/config/rules/#domain) matches. |
| `XXX_SUFFIX` | [DOMAIN-SUFFIX](https://wiki.metacubex.one/en/config/rules/#domain-suffix) matches. |
| `XXX_KEYWORD` | [DOMAIN-KEYWORD](https://wiki.metacubex.one/en/config/rules/#domain-keyword) matches. |
| `XXX_IPCIDR` | [IP-CIDR](https://wiki.metacubex.one/en/config/rules/#ip-cidr-ip-cidr6) ranges. |
| `XXX_SRCIPCIDR` | [SRC-IP-CIDR](https://wiki.metacubex.one/en/config/rules/#src-ip-cidr) — route by source. Example: `SOCKS_SRCIPCIDR=192.168.88.37/32,192.168.88.65/32`. |
| `XXX_DSCP` | Marks this group's traffic with a [DSCP](https://wiki.metacubex.one/en/config/rules/#dscp) value (0–63). Example: `YOUTUBE_DSCP=10`. |
| `XXX_PRIORITY` | Position of this group's rules in the `rules` list. Lower = earlier. Shared priority space with `RULESxx`. Default ≥1000. |

### Custom rule-sets

| ENV | Description |
|---|---|
| `RULE_SETxx_BASE64` | `<base64>#<name>` — `<base64>` is base64-encoded [payload](https://wiki.metacubex.one/en/config/rule-providers/#payload) list. Creates a rule-set + group `<name>` with priority ≥2000. The WebUI's *Rule-sets → New base64* builds these for you. |
| `RULESxx` | Raw [mihomo rule](https://wiki.metacubex.one/en/config/rules/) where `xx` is the priority. Example: `RULES1=AND,((NETWORK,udp),(DST-PORT,443)),REJECT` drops QUIC first. |

## 🛠 RouterOS install

First, enable container support (if not enabled already):

```
/system/device-mode/print
/system/device-mode/update mode=advanced container=yes traffic-gen=yes
```

You have ~5 minutes to confirm via power-cycle or briefly pressing any physical button on the device.

Then paste the snippet below into RouterOS terminal:

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

During execution the script asks for:

- one proxy URL (`vless://`, `vmess://`, `ss://`, `trojan://`)
- optional subscription URL (`http(s)://...`)

…then sets up router config, mangle + routing, container install, and the initial domain pool.

After install, fine-tune everything either via the **WebUI on `:80`** or via the existing helper repos:

- [DNS_FWD](https://github.com/Medium1992/MikroTik_DNS_FWD) — DNS forwarding management
- [IPList](https://github.com/Medium1992/MikroTik_IPlist) — IP-list helpers

## 🐳 Docker Compose

See [`docker-compose.yml`](./docker-compose.yml) for a standalone example.

## 🤝 Contributing

PRs welcome — read the [Code of Conduct](./CODE_OF_CONDUCT.md) and [CONTRIBUTING.md](./CONTRIBUTING.md) first.

## 🔐 Security

Report sensitive issues per [SECURITY.md](./SECURITY.md).

## 💖 Support the project

If this saved you time configuring MikroTik and its scripts:

- **USDT (TRC20):** `TWDDYD1nk5JnG6FxvEu2fyFqMCY9PcdEsJ`
- [boosty.to/petersolomon/donate](https://boosty.to/petersolomon/donate)

<img width="150" height="150" alt="petersolomon-donate" src="https://github.com/user-attachments/assets/fcf40baa-a09e-4188-a036-7ad3a77f06ea" />
