#!/bin/bash
# entrypoint.sh
#
# Joins this container to the Tailscale network, sets up HTTPS via tailscale serve,
# runs DB migrations, then starts Lightdash.
#
# Access the app at: https://<TAILSCALE_HOSTNAME>.<tailnet>.ts.net
#
# Required env vars:
#   TAILSCALE_AUTH_KEY  — ephemeral pre-authorized key (tskey-auth-...)
#   TAILSCALE_HOSTNAME  — device name in Tailscale admin (default: lightdash)
#
# Optional env vars:
#   TAILSCALE_SERVE_PORT — local port the app listens on (default: 8080)
#   TAILSCALE_TAGS       — space-separated ACL tag list, e.g. "tag:server tag:prod"

set -e

if [ -z "${TAILSCALE_AUTH_KEY}" ]; then
    echo "ERROR: TAILSCALE_AUTH_KEY is required" >&2
    exit 1
fi

TAILSCALE_HOSTNAME="${TAILSCALE_HOSTNAME:-lightdash}"
TAILSCALE_SERVE_PORT="${TAILSCALE_SERVE_PORT:-8080}"
TS_SOCKET="/var/run/tailscale/tailscaled.sock"

# ---- Start tailscaled in userspace mode ----
tailscaled \
    --tun=userspace-networking \
    --state=/var/lib/tailscale/tailscaled.state \
    --socket="${TS_SOCKET}" &

# ---- Wait for the socket file to appear (up to 60 s) ----
# Checking for the socket file is more reliable than parsing `tailscale status`
# output, which varies depending on auth state.
echo "Waiting for tailscaled..."
for i in $(seq 1 60); do
    if [ -S "${TS_SOCKET}" ]; then
        echo "tailscaled is ready"
        break
    fi
    if [ "${i}" -eq 60 ]; then
        echo "ERROR: tailscaled failed to start within 60 seconds" >&2
        exit 1
    fi
    sleep 1
done

# ---- Build optional --advertise-tags argument ----
TS_TAGS_ARG=""
if [ -n "${TAILSCALE_TAGS}" ]; then
    TS_TAGS_CSV=$(echo "${TAILSCALE_TAGS}" | tr ' ' ',')
    TS_TAGS_ARG="--advertise-tags=${TS_TAGS_CSV}"
fi

# ---- Join the tailnet ----
tailscale \
    --socket="${TS_SOCKET}" \
    up \
    --authkey="${TAILSCALE_AUTH_KEY}" \
    --hostname="${TAILSCALE_HOSTNAME}" \
    --accept-routes \
    --accept-dns=false \
    ${TS_TAGS_ARG}

echo "Joined tailnet as ${TAILSCALE_HOSTNAME}"

# ---- Set up HTTPS via tailscale serve ----
# Tailscale automatically provisions a TLS cert for <hostname>.<tailnet>.ts.net
# timeout 15 prevents this from blocking the entrypoint if something goes wrong
timeout 15 tailscale \
    --socket="${TS_SOCKET}" \
    serve \
    --bg \
    "http://localhost:${TAILSCALE_SERVE_PORT}" \
    && echo "HTTPS enabled: https://${TAILSCALE_HOSTNAME}.tailad4ebd.ts.net" \
    || echo "Warning: tailscale serve setup failed, continuing on HTTP"

# ---- Run database migrations ----
pnpm -F backend migrate-production

# ---- Start the application ----
exec "$@"
