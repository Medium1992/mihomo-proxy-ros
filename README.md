# 🌐 mihomo-proxy-ros

## 🇬🇧 English Description

**mihomo-proxy-ros** is a multi-architecture Docker container based on **Mihomo**, supporting **ARM**, **ARM64**, **AMD64v1**, **AMD64v2**, and **AMD64v3** platforms.  

## 💖 Support 

If you find this project useful, you can support it with a donation:
**USDT(TRC20): TWDDYD1nk5JnG6FxvEu2fyFqMCY9PcdEsJ**

## 🌟 Features

- 🌍 Multi-architecture: ARM, ARM64, AMD64v1-v3
- ⚙️ Automated setup through MikroTik terminal
- 🔐 DPI bypass via ByeDPI
- 🌐 DNSProxy: multi-resolve from multiple DNS servers, supports all DNS protocols
- 🧩 Flexible routing and domain pool configuration
- 🛡️ Support for adding multiple proxy links via ENV
- 🚀 AWG (AmneziaWireGuard) integration for secure VPN tunnels

An **interactive automated deployment script** is available in the repository for **MikroTik RouterOS**,  
which also installs **ByeDPI** and **AdGuardHome’s dnsproxy** components.

The installation process is **interactive** — you simply paste the executable snippet into the MikroTik terminal, and the script will automatically download and run.

During setup, the user is prompted to:
- Enter a proxy configuration link such as `vless://`, `vmess://`, `ss://`, or `trojan://`
- Optionally provide a subscription link: `Enter sublink http(s)://... URL`

After installation, users can **flexibly configure routing rules**, manage **resource domains**,  
and **add additional proxy links** via environment variables (`ENV`) —  
refer to the documentation for details:  
👉 [\[Documentation ENVs\]](https://github.com/vanes32/mihomo/wiki#-%D0%BA%D0%BE%D0%BD%D1%82%D0%B5%D0%B9%D0%BD%D0%B5%D1%80-mihomo_env-%D0%BD%D0%B0%D1%81%D1%82%D1%80%D0%B0%D0%B8%D0%B2%D0%B0%D0%B5%D1%82%D1%81%D1%8F-%D0%BF%D0%B5%D1%80%D0%B5%D0%BC%D0%B5%D0%BD%D0%BD%D1%8B%D0%BC%D0%B8-env)
View available environment variables in the mihomo_env section

The script then automatically performs:
- Router configuration  
- Mangle and routing rules setup  
- Container deployment  
- Domain pool creation for proxied resources  

Ultimately, this automation simplifies the setup process for less experienced users,  
providing a **ready-to-run and highly customizable network proxy solution**.

---

### Example installation snippet

🧩 The installation is **entirely handled through the MikroTik terminal** —  
you simply **copy and paste** the provided snippet into the **RouterOS terminal**,  
after which the script will automatically download itself from the repository and begin execution.

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

## 💖 Support 

If you find this project useful, you can support it with a donation:
**USDT(TRC20): TWDDYD1nk5JnG6FxvEu2fyFqMCY9PcdEsJ**