FROM alpine:latest

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
# Port to expose
ARG LISTEN_PORT=80
ENV LISTEN_PORT=${LISTEN_PORT}
# Tailscale userspace SOCKS5 proxy (default)
ENV TS_SOCKS5_ADDR="localhost:1055"
# Tailscale node name; set a unique one when running several instances
ENV TS_HOSTNAME="ts-proxy"
# Opt-in: accept subnet routes advertised in the tailnet ("1"/"true")
ENV TS_ACCEPT_ROUTES=""
# Address the proxy listener binds to
ENV TS_BIND_ADDR="0.0.0.0"

RUN mkdir -p /var/lib/tailscale
VOLUME ["/var/lib/tailscale"]

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE ${LISTEN_PORT}

ENTRYPOINT ["/entrypoint.sh"]
