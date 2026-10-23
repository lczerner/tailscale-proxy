#!/usr/bin/env bash
set -euo pipefail

if [ -z "${TS_DEST_HOST:-}" ]; then
  echo "[ts-proxy] TS_DEST_HOST is required but not set, exiting."
  exit 1
fi

TS_HOSTNAME="${TS_HOSTNAME:-ts-proxy}"
TS_BIND_ADDR="${TS_BIND_ADDR:-0.0.0.0}"
TS_SOCKS5_ADDR="${TS_SOCKS5_ADDR:-localhost:1055}"
LISTEN_PORT="${LISTEN_PORT:-80}"
TS_DEST_PORT="${TS_DEST_PORT:-80}"

# Reject non-numeric or out-of-range ports here rather than letting
# socat fail later with a parser error in the middle of the address.
# The regex is length-bounded so absurdly long digit strings cannot
# overflow the integer comparisons below into "integer expression
# expected" noise and a false pass.
for port in "$LISTEN_PORT" "$TS_DEST_PORT"; do
  if ! [[ "$port" =~ ^[0-9]{1,5}$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
    echo "[ts-proxy] Invalid port number: '$port' (must be 1-65535), exiting."
    exit 1
  fi
done

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
  [ -n "${AUTHKEY_FILE:-}" ] && rm -f "$AUTHKEY_FILE"
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

# Fail fast if the daemon itself died instead of stumbling into a
# confusing "tailscale up" error below.
if ! kill -0 "$TAILSCALED_PID" 2>/dev/null; then
  echo "[ts-proxy] tailscaled exited during startup, exiting."
  exit 1
fi

up_args=(--hostname="${TS_HOSTNAME}")
if [ "${TS_ACCEPT_ROUTES:-}" = "1" ] || [ "${TS_ACCEPT_ROUTES:-}" = "true" ]; then
  echo "[ts-proxy] Accepting tailnet subnet routes (TS_ACCEPT_ROUTES)."
  up_args+=(--accept-routes)
fi

# Run "tailscale up" in the background so a termination signal during
# authentication is handled immediately instead of being deferred until
# the command returns.
if [ -n "${TS_AUTHKEY:-}" ]; then
  # Hand the key to "tailscale up" via a file ("--authkey=file:..."):
  # passing it as an argument would expose it in "ps" output for as long
  # as authentication runs. Prefer /run, then TMPDIR; the persistent
  # state dir is last so a hard kill cannot leave the key on the volume.
  # The key is created 0600 directly via umask - never briefly wider.
  AUTHKEY_FILE=""
  for cand in "/run/ts-authkey" "${TMPDIR:-/tmp}/ts-authkey.$$" "/var/lib/tailscale/.ts-authkey"; do
    # The redirection is tried in a subshell so bash's "Permission denied"
    # message for a failed redirect does not reach the container log.
    if ( umask 077 && printf '%s' "$TS_AUTHKEY" > "$cand" ) 2>/dev/null; then
      AUTHKEY_FILE="$cand"
      break
    fi
  done
  if [ -z "$AUTHKEY_FILE" ]; then
    echo "[ts-proxy] Could not write the auth key to a temporary file, exiting." >&2
    exit 1
  fi
  echo "[ts-proxy] Authenticating with tailnet..."
  tailscale up "${up_args[@]}" --authkey="file:${AUTHKEY_FILE}" &
  UP_PID=$!
else
  echo "[ts-proxy] No TS_AUTHKEY set – using existing session from state dir if present."
  # With no auth key an interactive login prompt would block forever; give
  # an existing session a minute to come up, then fail with instructions.
  timeout 60 tailscale up "${up_args[@]}" &
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
  rm -f "${AUTHKEY_FILE:-}"
  exit 1
fi

# The key file is only needed while authentication runs.
[ -n "${AUTHKEY_FILE:-}" ] && rm -f "$AUTHKEY_FILE"

echo "[ts-proxy] Connected to tailnet."
tailscale status || true

# Forward the listen address to the tailnet service via SOCKS5
echo "[ts-proxy] Forwarding ${TS_BIND_ADDR}:${LISTEN_PORT} -> ${TS_DEST_HOST}:${TS_DEST_PORT} via SOCKS5..."
socat --experimental \
  "TCP-LISTEN:${LISTEN_PORT},bind=${TS_BIND_ADDR},reuseaddr,fork" \
  "SOCKS5-CONNECT:${TS_SOCKS5_ADDR}:${TS_DEST_HOST}:${TS_DEST_PORT}" \
  &

SOCAT_PID=$!

# Keep container alive; exit with the failed child's code if either dies
EXIT_CODE=0
wait -n "$TAILSCALED_PID" "$SOCAT_PID" || EXIT_CODE=$?

if ! kill -0 "$TAILSCALED_PID" 2>/dev/null; then
  echo "[ts-proxy] tailscaled exited with code ${EXIT_CODE}, shutting down."
elif ! kill -0 "$SOCAT_PID" 2>/dev/null; then
  echo "[ts-proxy] socat exited with code ${EXIT_CODE}, shutting down."
fi

# Stop the surviving child for a clean shutdown.
if [ -n "$SOCAT_PID" ]; then
  kill -TERM "$SOCAT_PID" 2>/dev/null || true
fi
if [ -n "$TAILSCALED_PID" ]; then
  kill -TERM "$TAILSCALED_PID" 2>/dev/null || true
fi
wait 2>/dev/null || true

exit "${EXIT_CODE}"
