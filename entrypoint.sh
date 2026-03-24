#!/bin/bash
# entrypoint.sh
#
# Starts Tailscale in userspace-networking mode (no /dev/net/tun or NET_ADMIN
# required), joins the tailnet, proxies inbound traffic to the app via
# `tailscale serve`, runs DB migrations, then starts Lightdash.
#
# Required env vars:
#   TAILSCALE_AUTH_KEY  — Tailscale auth key (use ephemeral pre-auth keys for containers)
#   TAILSCALE_HOSTNAME  — Device name shown in Tailscale admin (default: lightdash)
#   SITE_URL            — Must be set to https://<hostname>.<tailnet>.ts.net
#
# Optional env vars:
#   TAILSCALE_SERVE_PORT — Local port the app listens on (default: 8080)
#   TAILSCALE_TAGS       — Space-separated ACL tag list, e.g. "tag:server tag:prod"

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
    --socket="${TS_SOCKET}" \
    &

# ---- Wait for tailscaled to become ready (up to 60 s) ----
# `tailscale status` exits non-zero when in NeedsLogin state, so we check
# the output text instead of the exit code to detect a responding daemon.
echo "Waiting for tailscaled..."
for i in $(seq 1 60); do
    TS_OUT=$(tailscale --socket="${TS_SOCKET}" status 2>&1 || true)
    if echo "${TS_OUT}" | grep -qiE "NeedsLogin|Running|Stopped|Logged out"; then
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

# ---- Proxy inbound tailnet traffic to the local app ----
tailscale \
    --socket="${TS_SOCKET}" \
    serve \
    --bg \
    "http://localhost:${TAILSCALE_SERVE_PORT}"

echo "tailscale serve active: https://${TAILSCALE_HOSTNAME}.<tailnet>.ts.net -> localhost:${TAILSCALE_SERVE_PORT}"

# ---- Run database migrations ----
pnpm -F backend migrate-production

# ---- Start the application ----
exec "$@"
