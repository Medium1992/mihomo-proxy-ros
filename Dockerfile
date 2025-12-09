FROM --platform=$BUILDPLATFORM golang:alpine AS builder
ARG TARGETOS
ARG TARGETARCH
ARG AMD64VERSION
RUN apk add --no-cache --no-scripts curl jq gzip tar
    
RUN curl -s https://api.github.com/repos/MetaCubeX/mihomo/releases/latest | \
    jq -r '.assets[].browser_download_url' | grep -E 'mihomo-linux-(amd64|arm64|armv7)' | \
    while read url; do curl -L "$url" -o "$(basename "$url")"; done
    
RUN curl -s https://api.github.com/repos/heiher/hev-socks5-tunnel/releases/latest | \
    jq -r '.assets[].browser_download_url' | grep -E 'arm32v7|arm64|x86_64' | \
    while read url; do curl -L "$url" -o "$(basename "$url")"; done

RUN curl -s https://api.github.com/repos/hufrea/byedpi/releases/latest | \
    jq -r '.assets[].browser_download_url' | grep -E 'armv7l|aarch64|x86_64' | \
    while read url; do curl -L "$url" -o "$(basename "$url")"; done

RUN for f in *.tar.gz; do tar -xzf "$f"; done
RUN for f in *.gz; do gunzip "$f"; done

RUN mkdir -p /final

RUN if [ "$TARGETARCH" = "amd64" ]; then mv $(ls mihomo-linux-amd64-${AMD64VERSION}-* 2>/dev/null | grep -vE '\.(deb|rpm|pkg\.tar\.zst|gz)$' | head -n1) /final/mihomo; \
    elif [ "$TARGETARCH" = "arm64" ]; then mv $(ls mihomo-linux-arm64-* 2>/dev/null | grep -vE '\.(deb|rpm|pkg\.tar\.zst|gz)$' | head -n1) /final/mihomo; \
    else mv $(ls mihomo-linux-armv7-* 2>/dev/null | grep -vE '\.(deb|rpm|pkg\.tar\.zst|gz)$' | head -n1) /final/mihomo; fi

RUN if [ "$TARGETARCH" = "amd64" ]; then mv hev-socks5-tunnel-linux-x86_64 /final/hs5t; \
    elif [ "$TARGETARCH" = "arm64" ]; then mv hev-socks5-tunnel-linux-arm64 /final/hs5t; \
    else mv hev-socks5-tunnel-linux-arm32v7 /final/hs5t; fi
    
RUN if [ "$TARGETARCH" = "amd64" ]; then mv ciadpi-x86_64 /final/byedpi; \
    elif [ "$TARGETARCH" = "arm64" ]; then mv ciadpi-aarch64 /final/byedpi; \
    else mv ciadpi-armv7l /final/byedpi; fi

COPY entrypoint.sh /final/entrypoint.sh
RUN chmod +x /final/entrypoint.sh /final/mihomo /final/byedpi /final/hs5t


FROM alpine:latest
ARG TARGETARCH
COPY --from=builder /final /
RUN if [ "$TARGETARCH" = "arm64" ] || [ "$TARGETARCH" = "amd64" ]; then \
        apk add --no-cache --no-scripts ca-certificates tzdata iproute2-minimal iptables iptables-legacy nftables; \
    elif [ "$TARGETARCH" = "arm" ]; then \
        apk add --no-cache --no-scripts ca-certificates tzdata iproute2-minimal iptables iptables-legacy; \
    else \
        echo "Unsupported architecture: $TARGETARCH" && exit 1; \
    fi && \
    rm -f /usr/sbin/iptables /usr/sbin/iptables-save /usr/sbin/iptables-restore && \
    ln -s /usr/sbin/iptables-legacy /usr/sbin/iptables && \
    ln -s /usr/sbin/iptables-legacy-save /usr/sbin/iptables-save && \
    ln -s /usr/sbin/iptables-legacy-restore /usr/sbin/iptables-restore;
ENTRYPOINT ["/entrypoint.sh"]
