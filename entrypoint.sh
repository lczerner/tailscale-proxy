#!/usr/bin/env bash
set -euo pipefail

if [ -z "${TS_DEST_HOST}" ]; then
  echo "[ts-proxy] TS_DEST_HOST is required but not set, exiting."
  exit 1
fi

echo "[ts-proxy] Starting Tailscale in userspace mode..."

# Start tailscaled with userspace networking
tailscaled \
  --tun=userspace-networking \
  --socks5-server="${TS_SOCKS5_ADDR}" \
  --statedir=/var/lib/tailscale \
  &

TAILSCALED_PID=$!

# Wait for the socket to be ready. If Tailscale wasn't
# authenticated before, this will never succeed. That's ok
# at most we will wait 10 seconds before proceeding to the authentication step.
echo "[ts-proxy] Waiting for tailscaled to be ready..."
for i in $(seq 1 10); do
  tailscale status &>/dev/null && break
  sleep 1
done

# Authenticate
if [ -n "${TS_AUTHKEY}" ]; then
  echo "[ts-proxy] Authenticating with tailnet..."
  tailscale up --accept-routes --authkey="${TS_AUTHKEY}" --hostname="ts-proxy"
else
  echo "[ts-proxy] No TS_AUTHKEY set – assuming state dir has existing session"
  tailscale up --accept-routes
fi

echo "[ts-proxy] Connected to tailnet."
tailscale status

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
