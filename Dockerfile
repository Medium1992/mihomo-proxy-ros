FROM --platform=$BUILDPLATFORM alpine:latest AS package
ARG TARGETOS
ARG TARGETARCH
ARG TARGETVARIANT
ARG AMD64VERSION
ARG TAG
ARG WITH_GVISOR=1
ARG BUILDTIME
RUN apk add --no-cache curl jq gzip tar unzip git make python3 go
RUN mkdir -p /final
    
RUN curl -s https://api.github.com/repos/heiher/hev-socks5-tunnel/releases/latest | \
    jq -r '.assets[].browser_download_url' | grep -E 'arm32|arm32v7|arm64|x86_64' | \
    while read url; do curl -L "$url" -o "$(basename "$url")"; done

RUN curl -s https://api.github.com/repos/hufrea/byedpi/releases/latest | \
    jq -r '.assets[].browser_download_url' | grep -E 'armv6|armv7l|aarch64|x86_64' | \
    while read url; do curl -L "$url" -o "$(basename "$url")"; done

RUN for f in *.tar.gz; do tar -xzf "$f"; done

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

RUN mkdir -p /final

RUN if [ "$TARGETARCH" = "amd64" ]; then mv hev-socks5-tunnel-linux-x86_64 /final/hs5t; \
    elif [ "$TARGETARCH" = "arm64" ]; then mv hev-socks5-tunnel-linux-arm64 /final/hs5t; \
    elif [ "$TARGETARCH" = "arm" ] && [ "$TARGETVARIANT" = "v7" ]; then mv hev-socks5-tunnel-linux-arm32v7 /final/hs5t; \
    else mv hev-socks5-tunnel-linux-arm32 /final/hs5t; fi
    
RUN if [ "$TARGETARCH" = "amd64" ]; then mv ciadpi-x86_64 /final/byedpi; \
    elif [ "$TARGETARCH" = "arm64" ]; then mv ciadpi-aarch64 /final/byedpi; \
    elif [ "$TARGETARCH" = "arm" ] && [ "$TARGETVARIANT" = "v7" ]; then mv ciadpi-armv7l /final/byedpi; \
    else mv ciadpi-armv6 /final/byedpi; fi

RUN if [ "$TARGETARCH" = "amd64" ]; then mv zapret/binaries/linux-x86_64/nfqws /final/nfqws; \
    elif [ "$TARGETARCH" = "arm64" ]; then mv zapret/binaries/linux-arm64/nfqws /final/nfqws; fi

RUN if [ "$TARGETARCH" = "amd64" ]; then mv zapret2/binaries/linux-x86_64/nfqws2 /final/nfqws2; \
    elif [ "$TARGETARCH" = "arm64" ]; then mv zapret2/binaries/linux-arm64/nfqws2 /final/nfqws2; fi

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

# Клонируем репозиторий
RUN git clone https://github.com/MetaCubeX/mihomo.git /src
WORKDIR /src

# Переключаемся на нужный тэг
RUN git fetch --all --tags --prune && git switch --detach "$TAG" 2>/dev/null || git switch "$TAG"
RUN echo "Updating version.go with TAG=${TAG}-fakeip-ros and BUILDTIME=${BUILDTIME}" && \
    sed -i "s|Version\s*=.*|Version = \"${TAG}-fakeip-ros\"|" constant/version.go && \
    sed -i "s|BuildTime\s*=.*|BuildTime = \"${BUILDTIME}\"|" constant/version.go

RUN sed -i '/^import (/a\    "github.com/metacubex/mihomo/log"' \
    adapter/provider/provider.go

RUN sed -i 's@return nil, fmt.Errorf("proxy %d error: %w", idx, err)@name, _ := mapping["name"].(string)\n                log.Warnln("[Provider %s] skip invalid proxy (idx=%d, name=%q): %v", pdName, idx, name, err)\n                continue@g' \
    adapter/provider/provider.go
  
# Формируем список build tags и собираем
RUN BUILD_TAGS="" && \
    if [ "$WITH_GVISOR" = "1" ]; then BUILD_TAGS="with_gvisor"; fi && \
    echo "Building with tags: $BUILD_TAGS" && \
    if [ "$TARGETARCH" = "amd64" ]; then \
        echo "Setting GOAMD64=$AMD64VERSION for amd64"; \
        CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH GOAMD64=$AMD64VERSION \
        go build -tags "$BUILD_TAGS" -trimpath -ldflags "-w -s -buildid=" -o /final/mihomo .; \
    else \
        CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
        go build -tags "$BUILD_TAGS" -trimpath -ldflags "-w -s -buildid=" -o /final/mihomo .; \
    fi
    
WORKDIR /

RUN if [ "$TARGETARCH" = "arm" ] && [ "$TARGETVARIANT" = "v5" ]; then \
        mv /final/entrypoint_armv5.sh /final/entrypoint.sh; \
    else \
        rm -f /final/entrypoint_armv5.sh; \
    fi && \
    if [ "$TARGETARCH" = "amd64" ] || [ "$TARGETARCH" = "arm64" ]; then \
    chmod +x /final/entrypoint.sh /final/mihomo /final/byedpi /final/hs5t /final/nfqws /final/nfqws2; \
    else \
    chmod +x /final/entrypoint.sh /final/mihomo /final/byedpi /final/hs5t; \
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
        apk add --no-cache ca-certificates tzdata iproute2-minimal iptables iptables-legacy nftables; \
    elif [ "$TARGETARCH" = "arm" ] && [ "$TARGETVARIANT" = "v7" ]; then \
        apk add --no-cache ca-certificates tzdata iproute2-minimal iptables iptables-legacy; \
    fi && \
    if ! ( [ "$TARGETARCH" = "arm" ] && [ "$TARGETVARIANT" = "v5" ] ); then \
    rm -f /usr/sbin/iptables /usr/sbin/iptables-save /usr/sbin/iptables-restore && \
    ln -s /usr/sbin/iptables-legacy /usr/sbin/iptables && \
    ln -s /usr/sbin/iptables-legacy-save /usr/sbin/iptables-save && \
    ln -s /usr/sbin/iptables-legacy-restore /usr/sbin/iptables-restore; \
    fi

ENTRYPOINT ["/entrypoint.sh"]
