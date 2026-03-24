# tailscale-proxy

A lightweight container that bridges a [Tailscale](https://tailscale.com/) tailnet service to the local container network. It runs `tailscaled` in userspace networking mode and uses `socat` to forward a local port to a tailnet host via SOCKS5 — no Tailscale installation required on other containers.

## How it works

1. `tailscaled` starts in userspace mode, exposing a SOCKS5 proxy on `localhost:1055`
2. The container authenticates to your tailnet using `TS_AUTHKEY`
3. `socat` listens on `0.0.0.0:LISTEN_PORT` and forwards connections to `TS_DEST_HOST:TS_DEST_PORT` through the SOCKS5 proxy

Other containers on the same network can then reach the tailnet service by connecting to this proxy container's exposed port.

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `TS_AUTHKEY` | _(empty)_ | Tailscale auth key for authenticating to your tailnet. If unset, assumes an existing session in the state directory. |
| `TS_DEST_HOST` | _(required)_ | Hostname or Tailscale MagicDNS name of the tailnet service to proxy to. |
| `TS_DEST_PORT` | `80` | Port on the tailnet service to connect to. |
| `LISTEN_PORT` | `80` | Port to listen on inside the container (must match the published port). |
| `TS_SOCKS5_ADDR` | `localhost:1055` | Address of the `tailscaled` SOCKS5 server. Typically does not need to be changed. |

## Build

```sh
podman build -t tailscaleproxy .
```

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
podman run --env-file ./.env --rm -it \
  -p 8080:8080 \
  -v ./tailscale-data/:/var/lib/tailscale \
  localhost/tailscaleproxy
```

The `tailscale-data/` volume persists the Tailscale node state so re-authentication is not required on restart.

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