# Собирает rootfs.tar для образа linux/arm/v5.
# docker build -f buildroot/Dockerfile --output type=local,dest=. buildroot
FROM debian:trixie AS build
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential file wget cpio unzip rsync bc git ca-certificates \
      python3 perl patch bzip2 xz-utils \
 && rm -rf /var/lib/apt/lists/* \
 && useradd -m br
USER br
WORKDIR /home/br
ARG BR_VERSION=2026.05.3
RUN git clone --depth 1 -b "${BR_VERSION}" https://gitlab.com/buildroot.org/buildroot.git
COPY --chown=br busybox-httpd.fragment ./
COPY --chown=br mihomo_armv5_defconfig buildroot/configs/
RUN make -C buildroot mihomo_armv5_defconfig \
 && make -C buildroot \
 && for opt in CONFIG_FEATURE_HTTPD_CGI CONFIG_FEATURE_HTTPD_BASIC_AUTH CONFIG_FEATURE_HTTPD_AUTH_MD5 CONFIG_TIMEOUT CONFIG_STAT CONFIG_FEATURE_STAT_FORMAT; do \
      grep -qx "$opt=y" buildroot/output/build/busybox-*/.config \
        || { echo "busybox: $opt did not make it into the build" >&2; exit 1; }; \
    done

FROM scratch
COPY --from=build /home/br/buildroot/output/images/rootfs.tar /
