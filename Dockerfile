# syntax=docker/dockerfile:1
ARG TRANSMISSION_VERSION=4.0.5-r3-ls240
# Build stage: copy Transmission binaries from LSIO's pre-built image
FROM lscr.io/linuxserver/transmission:${TRANSMISSION_VERSION} AS transmission-source

# Intermediate stage: stage only the Transmission runtime assets
FROM scratch AS transmission-files
COPY --from=transmission-source /usr/bin/transmission-daemon /usr/bin/transmission-daemon
COPY --from=transmission-source /usr/bin/transmission-remote /usr/bin/transmission-remote
COPY --from=transmission-source /usr/bin/transmission-create /usr/bin/transmission-create
COPY --from=transmission-source /usr/bin/transmission-edit /usr/bin/transmission-edit
COPY --from=transmission-source /usr/bin/transmission-show /usr/bin/transmission-show
# Copy the required shared libraries from the Transmission source image
COPY --from=transmission-source /usr/lib/libdeflate.so.0 /usr/lib/libdeflate.so.0
COPY --from=transmission-source /usr/lib/libcurl.so.4 /usr/lib/libcurl.so.4
COPY --from=transmission-source /usr/lib/libpsl.so.5 /usr/lib/libpsl.so.5
COPY --from=transmission-source /usr/lib/libminiupnpc.so.18 /usr/lib/libminiupnpc.so.18
COPY --from=transmission-source /usr/lib/libintl.so.8 /usr/lib/libintl.so.8
COPY --from=transmission-source /usr/lib/libcares.so.2 /usr/lib/libcares.so.2
COPY --from=transmission-source /usr/lib/libnghttp2.so.14 /usr/lib/libnghttp2.so.14
COPY --from=transmission-source /usr/lib/libidn2.so.0 /usr/lib/libidn2.so.0
COPY --from=transmission-source /usr/lib/libzstd.so.1 /usr/lib/libzstd.so.1
COPY --from=transmission-source /usr/lib/libbrotlidec.so.1 /usr/lib/libbrotlidec.so.1
COPY --from=transmission-source /usr/lib/libunistring.so.5 /usr/lib/libunistring.so.5
COPY --from=transmission-source /usr/lib/libbrotlicommon.so.1 /usr/lib/libbrotlicommon.so.1
COPY --from=transmission-source /usr/lib/libstdc++.so.6 /usr/lib/libstdc++.so.6
COPY --from=transmission-source /usr/lib/libgcc_s.so.1 /usr/lib/libgcc_s.so.1

# Final stage: runtime image
FROM ghcr.io/linuxserver/baseimage-alpine:3.24

ARG BUILD_DATE
ARG VERSION

LABEL build_version="toondocker version:- ${VERSION} Build-date:- ${BUILD_DATE}" \
      maintainer="toondocker"

RUN echo "**** install runtime dependencies ****" && \
    apk add --no-cache \
      curl \
      libevent \
      openssl \
      zlib && \
    printf "toondocker version: ${VERSION}\nBuild-date: ${BUILD_DATE}\nTransmission: ${TRANSMISSION_VERSION}" > /build_version && \
    echo "**** cleanup ****" && \
    rm -rf /tmp/* $HOME/.cache

# Copy Transmission runtime assets from the intermediate stage
COPY --from=transmission-files /usr/ /usr/

RUN test -f /usr/bin/transmission-daemon || (echo "ERROR: Transmission binaries not copied successfully" && exit 1)

# Copy local files (minimal content from root/)
COPY root/ /

# ensure S6 files have correct permissions
RUN find /etc/s6-overlay/s6-rc.d -type f -name run -exec chmod 0755 {} \; \
 && find /etc/s6-overlay/s6-rc.d -type d -exec chmod 0755 {} \; \
 && chown -R root:root /etc/s6-overlay/s6-rc.d

# Expose ports and define volume
EXPOSE 9091 51413/tcp 51413/udp

# Health check: verify the s6-managed Transmission service is running
HEALTHCHECK --interval=30s --timeout=10s --start-period=20s --retries=3 \
    CMD s6-svstat /run/service/svc-transmission >/dev/null 2>&1 || exit 1
