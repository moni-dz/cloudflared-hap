FROM --platform=$BUILDPLATFORM golang:alpine AS cloudflared-build

ARG CLOUDFLARED_VERSION
ARG TARGETARCH
ARG TARGETVARIANT

RUN apk add --no-cache git
RUN git clone --depth 1 ${CLOUDFLARED_VERSION:+--branch "$CLOUDFLARED_VERSION"} \
      https://github.com/cloudflare/cloudflared.git /src
WORKDIR /src
RUN set -e; \
    case "${TARGETARCH}/${TARGETVARIANT}" in \
      arm/v7) export GOARCH=arm GOARM=7,softfloat ;; \
      arm/*)  export GOARCH=arm GOARM=6 ;; \
      *)      export GOARCH="${TARGETARCH}" ;; \
    esac; \
    CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" \
      -o /out/cloudflared ./cmd/cloudflared

FROM alpine:3.22 AS final

RUN apk add --no-cache ca-certificates iptables iptables-legacy iproute2 bash openssh curl jq

RUN ln -s /usr/sbin/iptables-legacy /usr/local/bin/iptables
RUN ln -s /usr/sbin/ip6tables-legacy /usr/local/bin/ip6tables

RUN ssh-keygen -f /etc/ssh/ssh_host_rsa_key -N '' -t rsa
RUN ssh-keygen -f /etc/ssh/ssh_host_ed25519_key -N '' -t ed25519

COPY sshd_config /etc/ssh/
COPY run.sh /usr/local/bin
COPY --from=cloudflared-build /out/cloudflared /usr/local/bin/cloudflared
RUN chmod +x /usr/local/bin/run.sh /usr/local/bin/cloudflared

EXPOSE 22
CMD ["/usr/local/bin/run.sh"]

FROM --platform=$BUILDPLATFORM muslcc/x86_64:arm-linux-musleabi AS musl-cross

FROM --platform=$BUILDPLATFORM debian:bookworm-slim AS musl-rootfs

RUN apt-get update && apt-get install -y --no-install-recommends \
      curl ca-certificates build-essential bc bison flex qemu-user-static && \
    rm -rf /var/lib/apt/lists/*

COPY --from=musl-cross / /opt/arm-linux-musleabi-cross/

RUN mkdir -p /opt/arm-linux-musleabi-cross/prefixed-bin && \
    for t in gcc g++ c++ cpp ar as ld ld.bfd ld.gold nm ranlib strip \
             objcopy objdump readelf addr2line size elfedit dwp \
             gcc-ar gcc-nm gcc-ranlib gcov gcov-dump gcov-tool gprof strings; do \
      ln -s "../bin/$t" "/opt/arm-linux-musleabi-cross/prefixed-bin/arm-linux-musleabi-$t"; \
    done
ENV PATH="/opt/arm-linux-musleabi-cross/prefixed-bin:${PATH}"
ENV CROSS="arm-linux-musleabi-"

ARG BUSYBOX_VERSION="1.36.1"
RUN mkdir -p /usr/src && \
    curl --fail --retry 5 --retry-all-errors -sL "https://busybox.net/downloads/busybox-${BUSYBOX_VERSION}.tar.bz2" -o /tmp/busybox.tar.bz2 && \
    tar -xj -C /usr/src -f /tmp/busybox.tar.bz2 && rm /tmp/busybox.tar.bz2

WORKDIR /usr/src/busybox-1.36.1
RUN make ARCH=arm CROSS_COMPILE=${CROSS} defconfig && \
    sed -i 's/# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config && \
    yes '' | make ARCH=arm CROSS_COMPILE=${CROSS} oldconfig && \
    make ARCH=arm CROSS_COMPILE=${CROSS} -j"$(nproc)" busybox

ARG DROPBEAR_VERSION="2025.88"
RUN curl --fail --retry 5 --retry-all-errors -sL "https://matt.ucc.asn.au/dropbear/releases/dropbear-${DROPBEAR_VERSION}.tar.bz2" -o /tmp/dropbear.tar.bz2 && \
    tar -xj -C /usr/src -f /tmp/dropbear.tar.bz2 && rm /tmp/dropbear.tar.bz2

WORKDIR /usr/src/dropbear-2025.88
RUN CC=${CROSS}gcc ./configure --host=arm-linux-musleabi --enable-static \
      --disable-zlib --disable-utmp --disable-utmpx --disable-wtmp --disable-wtmpx \
      --disable-lastlog --disable-loginfunc --disable-pututline --disable-pututxline \
      LDFLAGS=-static && \
    make PROGRAMS="dropbear dropbearkey" STATIC=1 -j"$(nproc)"

# --- iptables: legacy backend only (no nftables/libmnl).
ARG IPTABLES_VERSION="1.8.9"
RUN curl --fail --retry 5 --retry-all-errors -sL "https://www.netfilter.org/pub/iptables/iptables-${IPTABLES_VERSION}.tar.xz" -o /tmp/iptables.tar.xz && \
    tar -xJ -C /usr/src -f /tmp/iptables.tar.xz && rm /tmp/iptables.tar.xz
WORKDIR /usr/src/iptables-1.8.9
RUN CC=${CROSS}gcc ./configure --host=arm-linux-musleabi \
      --disable-nftables --disable-connlabel --disable-shared --enable-static \
      LDFLAGS=-static && \
    make -j"$(nproc)"

# --- Assemble the rootfs.
WORKDIR /
RUN set -e; \
    mkdir -p /rootfs/bin /rootfs/lib /rootfs/usr/sbin /rootfs/usr/local/bin \
             /rootfs/etc/dropbear /rootfs/etc/ssl/certs /rootfs/root/.ssh /rootfs/var/run; \
    cp /usr/src/busybox-1.36.1/busybox /rootfs/bin/busybox; \
    chroot /rootfs /bin/busybox --install -s /bin; \
    cp /usr/src/dropbear-2025.88/dropbear /rootfs/usr/sbin/dropbear; \
    cp /opt/arm-linux-musleabi-cross/arm-linux-musleabi/lib/libc.so /rootfs/lib/ld-musl-arm.so.1; \
    ln -s ld-musl-arm.so.1 /rootfs/lib/libc.so; \
    cp /usr/src/iptables-1.8.9/iptables/xtables-legacy-multi /rootfs/usr/sbin/xtables-legacy-multi; \
    for t in iptables iptables-save iptables-restore ip6tables ip6tables-save ip6tables-restore; do \
      ln -s xtables-legacy-multi /rootfs/usr/sbin/$t; \
      ln -s /usr/sbin/$t /rootfs/usr/local/bin/$t; \
    done

# Host keys, generated at build time like the other stages.
RUN cp /usr/src/dropbear-2025.88/dropbearkey /rootfs/usr/sbin/dropbearkey && \
    chroot /rootfs /usr/sbin/dropbearkey -t rsa -f /etc/dropbear/dropbear_rsa_host_key && \
    chroot /rootfs /usr/sbin/dropbearkey -t ecdsa -f /etc/dropbear/dropbear_ecdsa_host_key && \
    chroot /rootfs /usr/sbin/dropbearkey -t ed25519 -f /etc/dropbear/dropbear_ed25519_host_key && \
    rm /rootfs/usr/sbin/dropbearkey

# Minimal user/host db - musl reads /etc/passwd,/etc/shadow,/etc/group
# directly (no nsswitch). Root's shadow entry starts locked; run.sh
# sets the real password via chpasswd from $PASSWORD at container start.
RUN printf 'root:x:0:0:root:/root:/bin/ash\n' > /rootfs/etc/passwd && \
    printf 'root:!:19000:0:99999:7:::\n' > /rootfs/etc/shadow && \
    printf 'root:x:0:\n' > /rootfs/etc/group && \
    printf '127.0.0.1 localhost\n' > /rootfs/etc/hosts && \
    printf 'export PATH=/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n' > /rootfs/etc/profile && \
    chmod 600 /rootfs/etc/shadow

RUN curl -sL https://curl.se/ca/cacert.pem -o /rootfs/etc/ssl/certs/ca-certificates.crt

COPY run.sh /rootfs/usr/local/bin/
COPY --from=cloudflared-build /out/cloudflared /rootfs/usr/local/bin/cloudflared
RUN chmod +x /rootfs/usr/local/bin/run.sh /rootfs/usr/local/bin/cloudflared

FROM scratch AS final-v7
COPY --from=musl-rootfs /rootfs/ /

EXPOSE 22
CMD ["/usr/local/bin/run.sh"]

# ---------------------------------------------------------------------------
ARG TARGETVARIANT
FROM final${TARGETVARIANT:+-v7}

