# SPDX-License-Identifier: MIT

# Pinned release (not :latest) and manifest-list digest so the base image
# cannot drift and an upstream regression cannot land unannounced; the
# digest is the multi-arch index (amd64 and arm64 both resolve from it).
# This pins the BASE image only - apk packages still float until rebuilt.
# Bump deliberately.
FROM alpine:3.24@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a

RUN apk add --no-cache \
    tailscale \
    socat \
    curl \
    bash

# Tailscale auth key
ENV TS_AUTHKEY=""
# The tailnet service DNS and port
ENV TS_DEST_HOST=""
ENV TS_DEST_PORT="80"
# Port the proxy listens on inside the container; EXPOSE is documentation
# only - the listener actually binds whatever LISTEN_PORT is set to at
# runtime, so override both together.
ENV LISTEN_PORT="80"
# Tailscale userspace SOCKS5 proxy (default)
ENV TS_SOCKS5_ADDR="localhost:1055"
# Tailscale node name; set a unique one when running several instances
ENV TS_HOSTNAME="ts-proxy"
# Opt-in: accept subnet routes advertised in the tailnet ("1"/"true")
ENV TS_ACCEPT_ROUTES=""
# Address the proxy listener binds to
ENV TS_BIND_ADDR="0.0.0.0"

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Documentation for tools and humans; -p/--publish decides actual exposure.
EXPOSE 80

# Health check: exercise the full path (listener -> socat -> SOCKS5 ->
# tailnet) with a HEAD request. Any HTTP response (2xx-5xx) counts as
# healthy -- the point is reachability, not the backend's status code,
# so --fail must not be used here. socat only starts after tailscale
# authentication completes, which the start period covers. The probe
# follows TS_BIND_ADDR: 0.0.0.0 is probed as 127.0.0.1, any other value
# is used as-is so a restricted bind stays health-checkable.
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD HC_ADDR="${TS_BIND_ADDR}"; \
        [ "$HC_ADDR" = "0.0.0.0" ] && HC_ADDR=127.0.0.1; \
        code=$(curl -sS -I -o /dev/null -w '%{http_code}' --max-time 5 "http://${HC_ADDR}:${LISTEN_PORT}/"); \
        case "$code" in 2??|3??|4??|5??) exit 0;; *) exit 1;; esac

# OCI image labels; ghcr.io/lczerner/tailscale-proxy is published by CI.
LABEL org.opencontainers.image.title="tailscale-proxy" \
      org.opencontainers.image.description="Bridges a Tailscale tailnet service to the local container network via userspace tailscaled and socat" \
      org.opencontainers.image.authors="Lukáš Czerner <lukas@czerner.cz>" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.source="https://github.com/lczerner/tailscale-proxy" \
      org.opencontainers.image.url="https://github.com/lczerner/tailscale-proxy" \
      org.opencontainers.image.documentation="https://github.com/lczerner/tailscale-proxy#readme"

ENTRYPOINT ["/entrypoint.sh"]
