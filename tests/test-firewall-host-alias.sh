#!/bin/bash
# tests/test-firewall-host-alias.sh — The strict firewall must let the sandbox reach
# the Docker host at the address `host.docker.internal` resolves to, not only at
# the default route's gateway.
#
# The spark backend adds `--add-host host.docker.internal:host-gateway` and points
# ANTHROPIC_BASE_URL at that alias. Docker resolves host-gateway to the default
# bridge's gateway (172.17.0.1). A sandbox that joined another network — every
# `features: [comfyui]` project joins the ComfyUI compose network — has a
# different default route, so a firewall that allows only the route's gateway
# rejects the alias and every model request fails with "connection refused".
# Both addresses are this host. Needs Docker with NET_ADMIN and host python3.
set -euo pipefail

IMAGE="sandbox-base:latest"
PASS=0
FAIL=0

echo "=== Firewall: host alias on a non-default network ==="

command -v python3 >/dev/null || { echo "SKIP: host python3 required for the stub listener"; exit 0; }

NET="sandbox-fw-alias-$$"
DIR=$(mktemp -d)
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("0.0.0.0", 0)); print(s.getsockname()[1])')
python3 -m http.server "$PORT" --bind 0.0.0.0 --directory "$DIR" >/dev/null 2>&1 &
SRV=$!
cleanup() {
    kill "$SRV" 2>/dev/null || true
    docker network rm "$NET" >/dev/null 2>&1 || true
    rm -rf "$DIR"
}
trap cleanup EXIT
docker network create "$NET" >/dev/null
sleep 1

probe() {   # probe <label> [docker run args...]
    local label="$1"; shift
    if docker run --rm --cap-add NET_ADMIN --cap-add NET_RAW "$@" \
        --add-host host.docker.internal:host-gateway \
        -e SANDBOX_FIREWALL=strict \
        "$IMAGE" bash -c "curl --connect-timeout 5 -sf http://host.docker.internal:${PORT}/ >/dev/null 2>&1"; then
        echo "  PASS: host.docker.internal reachable from $label"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: host.docker.internal blocked from $label"
        FAIL=$((FAIL + 1))
    fi
}

# Control: on the default bridge the alias and the route's gateway coincide.
probe "the default network"
# The case that matters: a joined network, as with features: [comfyui].
probe "a non-default network ($NET)" --network "$NET"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
