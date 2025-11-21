FROM --platform=$BUILDPLATFORM golang:alpine AS builder
ARG TARGETOS
ARG TARGETARCH
ARG TAG
ARG WITH_GVISOR
ARG BUILDTIME
ARG AMD64VERSION

RUN apk add --no-cache curl jq gzip tar git make
   
RUN mkdir -p /final
    
RUN curl -s https://api.github.com/repos/heiher/hev-socks5-tunnel/releases/latest | \
    jq -r '.assets[].browser_download_url' | grep -E 'arm32v7|arm64|x86_64' | \
    while read url; do curl -L "$url" -o "$(basename "$url")"; done

RUN curl -s https://api.github.com/repos/hufrea/byedpi/releases/latest | \
    jq -r '.assets[].browser_download_url' | grep -E 'armv7l|aarch64|x86_64' | \
    while read url; do curl -L "$url" -o "$(basename "$url")"; done

RUN for f in *.tar.gz; do tar -xzf "$f"; done

RUN if [ "$TARGETARCH" = "amd64" ]; then mv hev-socks5-tunnel-linux-x86_64 /final/hs5t; \
    elif [ "$TARGETARCH" = "arm64" ]; then mv hev-socks5-tunnel-linux-arm64 /final/hs5t; \
    else mv hev-socks5-tunnel-linux-arm32v7 /final/hs5t; fi
    
RUN if [ "$TARGETARCH" = "amd64" ]; then mv ciadpi-x86_64 /final/byedpi; \
    elif [ "$TARGETARCH" = "arm64" ]; then mv ciadpi-aarch64 /final/byedpi; \
    else mv ciadpi-armv7l /final/byedpi; fi

RUN git clone https://github.com/MetaCubeX/mihomo.git /src
WORKDIR /src

RUN git fetch --all --tags --prune && git switch --detach "$TAG" 2>/dev/null || git switch "$TAG"
RUN echo "Updating version.go with TAG=${TAG}-fakeip-ros and BUILDTIME=${BUILDTIME}" && \
    sed -i "s|Version\s*=.*|Version = \"${TAG}-fakeip-ros\"|" constant/version.go && \
    sed -i "s|BuildTime\s*=.*|BuildTime = \"${BUILDTIME}\"|" constant/version.go

RUN cat > dns/envttl.go <<'EOF'
package dns

import (
  "os"
  "strconv"
)

func fakeipTTL() int {
  if v := os.Getenv("TTL_FAKEIP"); v != "" {
    if i, err := strconv.Atoi(v); err == nil && i > 0 {
      return i
    }
  }
  return 1
}
EOF

RUN awk 'BEGIN{done=0} { \
  if(!done && $0 ~ /setMsgTTL\([[:space:]]*msg,[[:space:]]*1[[:space:]]*\)/){ \
    sub(/setMsgTTL\([[:space:]]*msg,[[:space:]]*1[[:space:]]*\)/, "setMsgTTL(msg, uint32(fakeipTTL()))"); done=1 \
  } \
  print \
} END { if(done==0){ exit 1 } }' dns/middleware.go > /tmp/mw.go && \
    mv /tmp/mw.go dns/middleware.go && \
    grep -q 'setMsgTTL(msg, uint32(fakeipTTL()))' dns/middleware.go

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

COPY entrypoint.sh /final/entrypoint.sh
RUN chmod +x /final/entrypoint.sh /final/mihomo /final/byedpi /final/hs5t


FROM alpine:latest
ARG TARGETARCH
COPY --from=builder /final /
RUN if [ "$TARGETARCH" = "arm64" ] || [ "$TARGETARCH" = "amd64" ]; then \
        apk add --no-cache ca-certificates tzdata iproute2 iptables iptables-legacy nftables; \
    elif [ "$TARGETARCH" = "arm" ]; then \
        apk add --no-cache ca-certificates tzdata iproute2 iptables iptables-legacy; \
    else \
        echo "Unsupported architecture: $TARGETARCH" && exit 1; \
    fi && \
    rm -f /usr/sbin/iptables /usr/sbin/iptables-save /usr/sbin/iptables-restore && \
    ln -s /usr/sbin/iptables-legacy /usr/sbin/iptables && \
    ln -s /usr/sbin/iptables-legacy-save /usr/sbin/iptables-save && \
    ln -s /usr/sbin/iptables-legacy-restore /usr/sbin/iptables-restore;
ENTRYPOINT ["/entrypoint.sh"]
