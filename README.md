# tailscale-proxy

A lightweight container that bridges a [Tailscale](https://tailscale.com/) tailnet service to the local container network. It runs `tailscaled` in userspace networking mode and uses `socat` to forward a local port to a tailnet host via SOCKS5 — no Tailscale installation required on other containers.

Licensed under the MIT license — see [LICENSE](LICENSE).

## How it works

1. `tailscaled` starts in userspace mode, exposing a SOCKS5 proxy on `localhost:1055`
2. The container authenticates to your tailnet using `TS_AUTHKEY`
3. `socat` listens on `TS_BIND_ADDR:LISTEN_PORT` (default `0.0.0.0`) and forwards connections to `TS_DEST_HOST:TS_DEST_PORT` through the SOCKS5 proxy

Other containers on the same network can then reach the tailnet service by connecting to this proxy container's exposed port.

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `TS_AUTHKEY` | _(empty)_ | Tailscale auth key for authenticating to your tailnet. If unset, assumes an existing session in the state directory. |
| `TS_DEST_HOST` | _(required)_ | Hostname or Tailscale MagicDNS name of the tailnet service to proxy to. |
| `TS_DEST_PORT` | `80` | Port on the tailnet service to connect to. |
| `LISTEN_PORT` | `80` | Port to listen on inside the container (must match the published port). |
| `TS_HOSTNAME` | `ts-proxy` | Node name registered in the tailnet. Set a unique name when running several instances. |
| `TS_ACCEPT_ROUTES` | _(empty)_ | Set to `1` or `true` to accept subnet routes advertised in the tailnet. |
| `TS_BIND_ADDR` | `0.0.0.0` | Address the listener binds to inside the container. Set to a specific interface address to restrict it. |
| `TS_SOCKS5_ADDR` | `localhost:1055` | Address of the `tailscaled` SOCKS5 server. Typically does not need to be changed. |

## Container image

A pre-built image is available on GitHub Container Registry:

```sh
podman pull ghcr.io/lczerner/tailscale-proxy:latest
```

Replace `latest` with a specific version tag (e.g. `1.0.0`) for a pinned release.

## Build

```sh
podman build --format docker -t tailscaleproxy .
```

The `--format docker` flag is required: podman's default OCI image format silently drops `HEALTHCHECK`.

## Run

Create an `.env` file:

```env
TS_AUTHKEY=tskey-auth-...
TS_DEST_HOST=my-service.tailnet-name.ts.net
TS_DEST_PORT=8080
LISTEN_PORT=8080
```

Then run:

```sh
mkdir -p ./tailscale-data
podman run --env-file ./.env --rm -it \
  -p 8080:8080 \
  -v ./tailscale-data/:/var/lib/tailscale \
  localhost/tailscaleproxy
```

The `tailscale-data/` volume persists the Tailscale node state so re-authentication is not required on restart. podman does not auto-create the bind-mount source directory (docker does), hence the `mkdir -p` above.

## Security

The listener accepts unauthenticated connections from anything that can reach the published port, and every connection is tunneled into the tailnet destination — treat the port as wide open to whoever can reach it. Publish it only on trusted networks. By default the container binds to `0.0.0.0` (all interfaces); set `TS_BIND_ADDR` to restrict it, e.g. `TS_BIND_ADDR=127.0.0.1` or the address of a specific interface.

## TCP only, no keepalive tuning

This proxy forwards **TCP connections only**. `socat` listens on a TCP socket and connects through the SOCKS5 proxy — and tailscaled's userspace SOCKS5 server itself only carries TCP. UDP protocols (DNS, QUIC, game servers, syslog, etc.) cannot be proxied this way; run such workloads with a real Tailscale installation on the host instead.

Long-lived, idle TCP connections are also not kept alive deliberately: neither socat nor tailscaled's SOCKS5 path sets TCP keepalive timers here, so a connection that goes silent (no application traffic) can be dropped silently by NAT gateways, firewalls or load balancers — without an error reaching either endpoint. The tunnel itself is held open by Tailscale's own keepalives; the exposure is the leg between the client and the published port, where idle timeouts range from minutes (cloud load balancers) to hours or days (stateful firewalls), depending on the middlebox. Applications that hold idle connections open (database drivers, message brokers, SSH) should enable their own keepalive or heartbeat at the application layer; the proxy carries those transparently since they are just bytes on the TCP stream. Tuning socat/TCP keepalive options is deliberately left out to keep the container minimal — if you need it, extend the socat call in `entrypoint.sh` (e.g. `keepalive,keepidle=60,keepintvl=10` on the listen address).

## Verify it works

Once the container is running you should see output similar to:

```
[ts-proxy] Starting Tailscale in userspace mode...
[ts-proxy] Waiting for tailscaled to be ready...
[ts-proxy] Authenticating with tailnet...
[ts-proxy] Connected to tailnet.
```

Test connectivity by hitting the proxied service from the host:

```sh
curl -v http://localhost:8080/v1/models
```

A successful response from the tailnet service confirms the proxy is working end-to-end.