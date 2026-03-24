#!/bin/bash
# entrypoint.sh
#
# Joins this container to the Tailscale network, runs DB migrations,
# then starts Lightdash. Access the app via Tailscale MagicDNS:
#   http://<TAILSCALE_HOSTNAME>:8080
#
# Required env vars:
#   TAILSCALE_AUTH_KEY  — ephemeral pre-authorized key (tskey-auth-...)
#   TAILSCALE_HOSTNAME  — device name in Tailscale admin (default: lightdash)
#
# Optional env vars:
#   TAILSCALE_TAGS      — space-separated ACL tag list, e.g. "tag:server tag:prod"

set -e

if [ -z "${TAILSCALE_AUTH_KEY}" ]; then
    echo "ERROR: TAILSCALE_AUTH_KEY is required" >&2
    exit 1
fi

TAILSCALE_HOSTNAME="${TAILSCALE_HOSTNAME:-lightdash}"
TS_SOCKET="/var/run/tailscale/tailscaled.sock"

# ---- Start tailscaled in userspace mode ----
tailscaled \
    --tun=userspace-networking \
    --state=/var/lib/tailscale/tailscaled.state \
    --socket="${TS_SOCKET}" \
    2>/dev/null &

# ---- Wait for tailscaled to become ready (up to 60 s) ----
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
echo "Access Lightdash at: http://${TAILSCALE_HOSTNAME}:8080 (on your tailnet)"

# ---- Run database migrations ----
pnpm -F backend migrate-production

# ---- Start the application ----
exec "$@"
