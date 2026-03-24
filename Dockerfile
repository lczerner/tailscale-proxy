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
ENV LISTEN_PORT="80"
# Tailscale userspace SOCKS5 proxy (default)
ENV TS_SOCKS5_ADDR="localhost:1055"

RUN mkdir -p /var/lib/tailscale
VOLUME ["/var/lib/tailscale"]

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE ${LISTEN_PORT}

ENTRYPOINT ["/entrypoint.sh"]
