#!/bin/bash
# tests/test-firewall.sh — Verify strict firewall blocks/allows correctly
set -euo pipefail

IMAGE="sandbox-base:latest"
PASS=0
FAIL=0

echo "=== Firewall Tests (strict mode) ==="

check_blocked() {
    local domain="$1"
    if docker run --rm --cap-add NET_ADMIN --cap-add NET_RAW \
        -e SANDBOX_FIREWALL=strict \
        "$IMAGE" bash -c "curl --connect-timeout 5 -sf https://${domain} >/dev/null 2>&1"; then
        echo "  FAIL: $domain should be blocked but is reachable"
        FAIL=$((FAIL + 1))
    else
        echo "  PASS: $domain is blocked"
        PASS=$((PASS + 1))
    fi
}

check_allowed() {
    local domain="$1"
    if docker run --rm --cap-add NET_ADMIN --cap-add NET_RAW \
        -e SANDBOX_FIREWALL=strict \
        "$IMAGE" bash -c "curl --connect-timeout 10 -sf https://${domain} >/dev/null 2>&1"; then
        echo "  PASS: $domain is allowed"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $domain should be allowed but is blocked"
        FAIL=$((FAIL + 1))
    fi
}

check_blocked "example.com"
check_blocked "httpbin.org"
check_allowed "api.github.com"
check_allowed "registry.npmjs.org"

# The sparkyard backend depends on init-firewall.sh step 8 allowing the host
# gateway. Pin it so a future firewall edit cannot silently break it.
echo "-- host gateway allowed (sparkyard backend dependency) --"
GW_RULE=$(docker run --rm --cap-add=NET_ADMIN --cap-add=NET_RAW \
    -e SANDBOX_FIREWALL=strict \
    --entrypoint bash sandbox-base:latest -c \
    '/usr/local/bin/init-firewall.sh >/dev/null 2>&1; iptables -S OUTPUT' 2>/dev/null) || true

# Accepts either the current unscoped rule or a future port/protocol-scoped
# narrowing of it (e.g. `-p tcp --dport 14000`) — pinned loosely enough to
# still catch outright removal of the host-gateway allowance without
# resisting a deliberate hardening of it.
if echo "$GW_RULE" | grep -qE '^-A OUTPUT -d [0-9.]+/32( .*)? -j ACCEPT'; then
    echo "  PASS: strict firewall allows the host gateway"
    PASS=$((PASS + 1))
else
    echo "  FAIL: strict firewall no longer allows the host gateway"
    FAIL=$((FAIL + 1))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
