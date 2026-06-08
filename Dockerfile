# syntax=docker/dockerfile:1.7
FROM --platform=$BUILDPLATFORM alpine:latest AS package
ARG TARGETOS
ARG TARGETARCH
ARG TARGETVARIANT
ARG AMD64VERSION
ARG MIHOMO_RELEASE_TAG=latest
RUN apk add --no-cache curl jq gzip tar unzip
RUN mkdir -p /final

RUN if [ "$MIHOMO_RELEASE_TAG" = "latest" ]; then \
      MIHOMO_API_URL="https://api.github.com/repos/medium1992/mihomo-proxy-ros/releases/latest"; \
    else \
      MIHOMO_API_URL="https://api.github.com/repos/medium1992/mihomo-proxy-ros/releases/tags/${MIHOMO_RELEASE_TAG}"; \
    fi && \
    curl -s "$MIHOMO_API_URL" | \
    jq -r '.assets[].browser_download_url' | grep -E 'mihomo-linux-(amd64|arm64|armv7|armv5)' | \
    while read url; do curl -L "$url" -o "$(basename "$url")"; done

RUN curl -s https://api.github.com/repos/heiher/hev-socks5-tunnel/releases/latest | \
    jq -r '.assets[].browser_download_url' | grep -E 'arm32|arm32v7|arm64|x86_64' | \
    while read url; do curl -L "$url" -o "$(basename "$url")"; done

RUN curl -s https://api.github.com/repos/hufrea/byedpi/releases/latest | \
    jq -r '.assets[].browser_download_url' | grep -E 'armv6|armv7l|aarch64|x86_64' | \
    while read url; do curl -L "$url" -o "$(basename "$url")"; done

RUN for f in *.tar.gz; do tar -xzf "$f"; done
RUN for f in *.gz; do gunzip "$f"; done

RUN curl -s https://api.github.com/repos/bol-van/zapret/releases/latest | \
    jq -r '.tag_name as $tag | .assets[].browser_download_url | select(endswith(".tar.gz") and (contains("openwrt-embedded") | not))' | \
    head -1 | \
    xargs -I {} curl -L {} -o zapret.tar.gz && \
    mkdir /zapret && \
    tar -xzf zapret.tar.gz -C /zapret --strip-components=1 && \
    rm zapret.tar.gz

RUN curl -s https://api.github.com/repos/bol-van/zapret2/releases/latest | \
    jq -r '.tag_name as $tag | .assets[].browser_download_url | select(endswith(".tar.gz") and (contains("openwrt-embedded") | not))' | \
    head -1 | \
    xargs -I {} curl -L {} -o zapret2.tar.gz && \
    mkdir /zapret2 && \
    tar -xzf zapret2.tar.gz -C /zapret2 --strip-components=1 && \
    rm zapret2.tar.gz

RUN curl -s https://api.github.com/repos/Flowseal/zapret-discord-youtube/releases/latest | \
    jq -r '.assets[].browser_download_url | select(endswith(".zip"))' | \
    head -1 | \
    xargs -I {} curl -L {} -o zapret-discord-youtube.zip && \
    mkdir -p /zapret-discord-youtube && \
    unzip zapret-discord-youtube.zip -d /zapret-discord-youtube && \
    rm zapret-discord-youtube.zip

RUN curl -L https://github.com/IndeecFOX/zapret4rocket/archive/refs/heads/master.zip \
        -o zapret4rocket.zip && \
    mkdir -p /zapret4rocket && \
    unzip zapret4rocket.zip -d /zapret4rocket && \
    rm zapret4rocket.zip

RUN mkdir -p /final /final/usr/local/bin

RUN if [ "$TARGETARCH" = "amd64" ]; then \
      SRC="$(ls mihomo-linux-amd64-${AMD64VERSION} mihomo-linux-amd64-${AMD64VERSION}-* 2>/dev/null | grep -vE '\.(deb|rpm|pkg\.tar\.zst|gz)$' | head -n1)"; \
    elif [ "$TARGETARCH" = "arm64" ]; then \
      SRC="$(ls mihomo-linux-arm64 mihomo-linux-arm64-* 2>/dev/null | grep -vE '\.(deb|rpm|pkg\.tar\.zst|gz)$' | head -n1)"; \
    elif [ "$TARGETARCH" = "arm" ] && [ "$TARGETVARIANT" = "v7" ]; then \
      SRC="$(ls mihomo-linux-armv7 mihomo-linux-armv7-* 2>/dev/null | grep -vE '\.(deb|rpm|pkg\.tar\.zst|gz)$' | head -n1)"; \
    else \
      SRC="$(ls mihomo-linux-armv5 mihomo-linux-armv5-* 2>/dev/null | grep -vE '\.(deb|rpm|pkg\.tar\.zst|gz)$' | head -n1)"; \
    fi && \
    [ -n "$SRC" ] && mv "$SRC" /final/usr/local/bin/mihomo

RUN if [ "$TARGETARCH" = "amd64" ]; then mv hev-socks5-tunnel-linux-x86_64 /final/usr/local/bin/hs5t; \
    elif [ "$TARGETARCH" = "arm64" ]; then mv hev-socks5-tunnel-linux-arm64 /final/usr/local/bin/hs5t; \
    elif [ "$TARGETARCH" = "arm" ] && [ "$TARGETVARIANT" = "v7" ]; then mv hev-socks5-tunnel-linux-arm32v7 /final/usr/local/bin/hs5t; \
    else mv hev-socks5-tunnel-linux-arm32 /final/usr/local/bin/hs5t; fi

RUN if [ "$TARGETARCH" = "amd64" ]; then mv ciadpi-x86_64 /final/usr/local/bin/byedpi; \
    elif [ "$TARGETARCH" = "arm64" ]; then mv ciadpi-aarch64 /final/usr/local/bin/byedpi; \
    elif [ "$TARGETARCH" = "arm" ] && [ "$TARGETVARIANT" = "v7" ]; then mv ciadpi-armv7l /final/usr/local/bin/byedpi; \
    else mv ciadpi-armv6 /final/usr/local/bin/byedpi; fi

RUN if [ "$TARGETARCH" = "amd64" ]; then mv zapret/binaries/linux-x86_64/nfqws /final/usr/local/bin/nfqws; \
    elif [ "$TARGETARCH" = "arm64" ]; then mv zapret/binaries/linux-arm64/nfqws /final/usr/local/bin/nfqws; fi

RUN if [ "$TARGETARCH" = "amd64" ]; then mv zapret2/binaries/linux-x86_64/nfqws2 /final/usr/local/bin/nfqws2; \
    elif [ "$TARGETARCH" = "arm64" ]; then mv zapret2/binaries/linux-arm64/nfqws2 /final/usr/local/bin/nfqws2; fi

RUN if [ "$TARGETARCH" = "amd64" ] || [ "$TARGETARCH" = "arm64" ]; then \
    mkdir -p /final/lua /final/zapret-fakebin /final/zapret-lists; \
    if [ -d zapret2/lua ] && ls zapret2/lua/*.lua >/dev/null 2>&1; then \
        cp zapret2/lua/*.lua /final/lua/; \
    fi; \
    Z4R=zapret4rocket/zapret4rocket-master; \
    if [ -d "$Z4R/fake" ] && ls "$Z4R"/fake/*.bin >/dev/null 2>&1; then \
        cp "$Z4R"/fake/*.bin /final/zapret-fakebin/; \
    fi; \
    if [ -d zapret-discord-youtube/bin ] && ls zapret-discord-youtube/bin/*.bin >/dev/null 2>&1; then \
        cp zapret-discord-youtube/bin/*.bin /final/zapret-fakebin/; \
    fi; \
    if [ -d zapret2/files/fake ] && ls zapret2/files/fake/*.bin >/dev/null 2>&1; then \
        cp zapret2/files/fake/*.bin /final/zapret-fakebin/; \
    fi; \
    if [ -d "$Z4R/lists" ] && ls "$Z4R"/lists/*.txt >/dev/null 2>&1; then \
        cp "$Z4R"/lists/*.txt /final/zapret-lists/; \
    fi; \
    if [ -d zapret-discord-youtube/lists ] && ls zapret-discord-youtube/lists/*.txt >/dev/null 2>&1; then \
        cp zapret-discord-youtube/lists/*.txt /final/zapret-lists/; \
    fi; \
fi

COPY entrypoint.sh entrypoint_armv5.sh /final/
COPY www/ /final/www/
RUN --mount=type=secret,id=awg,target=/tmp/awg \
    install -m 0444 /tmp/awg /final/usr/local/bin/awg
RUN --mount=type=secret,id=happ1,target=/tmp/happ1 \
    --mount=type=secret,id=happ2,target=/tmp/happ2 \
    --mount=type=secret,id=happ3,target=/tmp/happ3 \
    --mount=type=secret,id=happ4,target=/tmp/happ4 \
    cat /tmp/happ1 /tmp/happ2 /tmp/happ3 /tmp/happ4 | base64 -d > /final/www/assets/happ.js && \
    chmod 0444 /final/www/assets/happ.js

RUN if [ "$TARGETARCH" = "arm" ] && [ "$TARGETVARIANT" = "v5" ]; then \
        mv /final/entrypoint_armv5.sh /final/entrypoint.sh; \
    else \
        rm -f /final/entrypoint_armv5.sh; \
    fi && \
    if [ "$TARGETARCH" = "amd64" ] || [ "$TARGETARCH" = "arm64" ]; then \
    chmod +x /final/entrypoint.sh /final/www/cgi-bin/index.sh /final/www/cgi-bin/show_config.sh /final/usr/local/bin/mihomo /final/usr/local/bin/byedpi /final/usr/local/bin/hs5t /final/usr/local/bin/nfqws /final/usr/local/bin/nfqws2; \
    else \
    chmod +x /final/entrypoint.sh /final/www/cgi-bin/index.sh /final/www/cgi-bin/show_config.sh /final/usr/local/bin/mihomo /final/usr/local/bin/byedpi /final/usr/local/bin/hs5t; \
    fi

FROM --platform=linux/amd64 alpine:latest AS linux-amd64
FROM --platform=linux/arm64 alpine:latest AS linux-arm64
FROM --platform=linux/arm/v7 alpine:latest AS linux-armv7
FROM --platform=linux/arm/v5 scratch AS linux-armv5
ADD rootfs.tar /

FROM ${TARGETOS}-${TARGETARCH}${TARGETVARIANT}
ARG TARGETARCH
ARG TARGETVARIANT

COPY --from=package /final /

RUN if [ "$TARGETARCH" = "arm64" ] || [ "$TARGETARCH" = "amd64" ]; then \
        apk add --no-cache ca-certificates busybox-extras openssl tzdata iproute2 nftables jq; \
    elif [ "$TARGETARCH" = "arm" ] && [ "$TARGETVARIANT" = "v7" ]; then \
        apk add --no-cache ca-certificates busybox-extras openssl tzdata iproute2 iptables iptables-legacy jq; \
    fi && \
    if ! ( [ "$TARGETARCH" = "arm" ] && [ "$TARGETVARIANT" = "v5" ] ); then \
    rm -f /usr/sbin/iptables /usr/sbin/iptables-save /usr/sbin/iptables-restore && \
    ln -s /usr/sbin/iptables-legacy /usr/sbin/iptables && \
    ln -s /usr/sbin/iptables-legacy-save /usr/sbin/iptables-save && \
    ln -s /usr/sbin/iptables-legacy-restore /usr/sbin/iptables-restore; \
    fi

ENTRYPOINT ["/entrypoint.sh"]
