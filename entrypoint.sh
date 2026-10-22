#!/usr/bin/env bash
set -euo pipefail

if [ -z "${TS_DEST_HOST:-}" ]; then
  echo "[ts-proxy] TS_DEST_HOST is required but not set, exiting."
  exit 1
fi

TS_SOCKS5_ADDR="${TS_SOCKS5_ADDR:-localhost:1055}"
LISTEN_PORT="${LISTEN_PORT:-80}"
TS_DEST_PORT="${TS_DEST_PORT:-80}"

TAILSCALED_PID=""
SOCAT_PID=""
UP_PID=""

# shellcheck disable=SC2317  # invoked via trap
shutdown() {
  echo "[ts-proxy] Termination signal received, shutting down..."
  trap - TERM INT
  if [ -n "$SOCAT_PID" ]; then
    kill -TERM "$SOCAT_PID" 2>/dev/null || true
  fi
  if [ -n "$TAILSCALED_PID" ]; then
    kill -TERM "$TAILSCALED_PID" 2>/dev/null || true
  fi
  if [ -n "$UP_PID" ]; then
    kill -TERM "$UP_PID" 2>/dev/null || true
  fi
  # Bound the wait so a child that ignores SIGTERM cannot hang shutdown;
  # the container runtime's kill timer stays the last resort.
  for _ in {1..50}; do
    kill -0 "$SOCAT_PID" 2>/dev/null || \
      kill -0 "$TAILSCALED_PID" 2>/dev/null || \
      kill -0 "$UP_PID" 2>/dev/null || break
    sleep 0.1
  done
  echo "[ts-proxy] Shutdown complete."
  exit 0
}
trap shutdown TERM INT

echo "[ts-proxy] Starting Tailscale in userspace mode..."

# Start tailscaled with userspace networking
tailscaled \
  --tun=userspace-networking \
  --socks5-server="${TS_SOCKS5_ADDR}" \
  --statedir=/var/lib/tailscale \
  &

TAILSCALED_PID=$!

# Wait for the tailscaled local API socket to answer. "tailscale status"
# fails while the backend is in NeedsLogin, so look for the daemon to
# respond with JSON at all - authentication is not required to get here.
echo "[ts-proxy] Waiting for tailscaled to be ready..."
for _ in {1..10}; do
  # Read the whole payload before matching: "grep -q" could otherwise
  # SIGPIPE tailscale mid-write and read the match as a failure.
  status_out="$(tailscale status --json 2>/dev/null || true)"
  if grep -q '"BackendState"' <<<"$status_out"; then
    echo "[ts-proxy] tailscaled is ready."
    break
  fi
  sleep 1
done

# Run "tailscale up" in the background so a termination signal during
# authentication is handled immediately instead of being deferred until
# the command returns.
if [ -n "${TS_AUTHKEY:-}" ]; then
  echo "[ts-proxy] Authenticating with tailnet..."
  tailscale up --accept-routes --authkey="${TS_AUTHKEY}" --hostname="ts-proxy" &
  UP_PID=$!
else
  echo "[ts-proxy] No TS_AUTHKEY set – using existing session from state dir if present."
  # With no auth key an interactive login prompt would block forever; give
  # an existing session a minute to come up, then fail with instructions.
  timeout 60 tailscale up --accept-routes &
  UP_PID=$!
fi

if ! wait "$UP_PID"; then
  echo "[ts-proxy] Failed to connect to tailnet." >&2
  if [ -z "${TS_AUTHKEY:-}" ]; then
    echo "[ts-proxy] No usable Tailscale session in the state dir and TS_AUTHKEY is not set." >&2
    echo "[ts-proxy] Set TS_AUTHKEY to authenticate this container." >&2
  else
    echo "[ts-proxy] Check TS_AUTHKEY: is it valid, unexpired and reusable?" >&2
  fi
  exit 1
fi

echo "[ts-proxy] Connected to tailnet."
tailscale status || true

# Forward 0.0.0.0:LISTEN_PORT to tailnet service via SOCKS5
socat --experimental \
  TCP-LISTEN:${LISTEN_PORT},bind=0.0.0.0,reuseaddr,fork \
  SOCKS5-CONNECT:${TS_SOCKS5_ADDR}:${TS_DEST_HOST}:${TS_DEST_PORT} \
  &

SOCAT_PID=$!

# Keep container alive; exit if either process dies
wait -n $TAILSCALED_PID $SOCAT_PID
EXIT_CODE=$?
echo "[ts-proxy] A child process exited with code ${EXIT_CODE}, shutting down."
exit ${EXIT_CODE}
