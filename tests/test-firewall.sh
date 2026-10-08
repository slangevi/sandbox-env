#!/bin/bash
# tests/test-firewall.sh — Verify strict firewall blocks/allows correctly
set -euo pipefail

IMAGE="${IMAGE:-sandbox-base:latest}"
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

# allowed_domains entries may be IPv4 literals or CIDRs (a LAN host like a
# NAS has no public DNS name, and mDNS/.local names do not resolve inside
# the container). They must land in the ipset directly, without `dig`.
# 1.1.1.1 / 1.0.0.1 are Cloudflare resolvers with valid TLS certs for
# their bare IPs, so https://<ip> is a clean reachability probe.
echo "-- IP literals and CIDRs in allowed domains --"
check_ip_allowed() {
    local target="$1" entry="$2"
    if docker run --rm --cap-add NET_ADMIN --cap-add NET_RAW \
        -e SANDBOX_FIREWALL=strict \
        -e "SANDBOX_ALLOWED_DOMAINS=${entry}" \
        "$IMAGE" bash -c "curl --connect-timeout 10 -sf https://${target} >/dev/null 2>&1"; then
        echo "  PASS: ${target} is allowed via entry '${entry}'"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: ${target} should be allowed via entry '${entry}' but is blocked"
        FAIL=$((FAIL + 1))
    fi
}
check_blocked "1.1.1.1"                       # control: not allowed by default
check_ip_allowed "1.1.1.1" "1.1.1.1"          # bare IPv4 literal
check_ip_allowed "1.0.0.1" "1.0.0.0/24"       # CIDR
check_ip_allowed "1.1.1.1" "example.org,1.1.1.1"  # mixed with a domain

# The sparkyard backend depends on init-firewall.sh step 8 allowing the host
# gateway. Pin it so a future firewall edit cannot silently break it.
echo "-- host gateway allowed (sparkyard backend dependency) --"
GW_RULE=$(docker run --rm --cap-add=NET_ADMIN --cap-add=NET_RAW \
    -e SANDBOX_FIREWALL=strict \
    --entrypoint bash "$IMAGE" -c \
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

echo "-- ComfyUI address --"
# A CLI-derived address reaches the ipset through the same IP-literal path
# allowed_domains entries use. Use ipset test which runs as root via --entrypoint.
if docker run --rm --cap-add NET_ADMIN --cap-add NET_RAW \
    -e SANDBOX_FIREWALL=strict \
    -e SANDBOX_COMFYUI_IP=172.20.0.2 \
    --entrypoint bash "$IMAGE" -c \
    '/usr/local/bin/init-firewall.sh >/dev/null 2>&1 && ipset test allowed-domains 172.20.0.2' 2>/dev/null; then
    echo "  PASS: SANDBOX_COMFYUI_IP reaches the ipset"
    PASS=$((PASS + 1))
else
    echo "  FAIL: SANDBOX_COMFYUI_IP missing from the ipset"
    FAIL=$((FAIL + 1))
fi

# Allowed domains stay current: dnsmasq is the container's resolver and adds
# every address it serves for an allowed name to the set (CDN-hosted APIs
# rotate their edge addresses within minutes; a set filled once goes stale).
echo "-- DNS refresh (dnsmasq fills the allowed set) --"
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
DNS_C="sandbox-fwtest-dns-$$"
docker run -d --name "$DNS_C" --cap-add NET_ADMIN --cap-add NET_RAW \
    -e SANDBOX_FIREWALL=strict "$IMAGE" sleep 300 >/dev/null
for _ in $(seq 1 60); do
    docker logs "$DNS_C" 2>&1 | grep -q "Firewall active" && break
    sleep 1
done
if [ "$(docker exec "$DNS_C" head -1 /etc/resolv.conf 2>/dev/null)" = "nameserver 127.0.0.1" ] \
    && docker exec "$DNS_C" pgrep -x dnsmasq >/dev/null; then
    pass "dnsmasq runs and is the container's resolver"
else
    fail "dnsmasq is not the container's resolver"
fi
UPSTREAM=$(docker exec "$DNS_C" awk -F= '/^server=/{print $2}' /run/sandbox-dnsmasq.conf 2>/dev/null) || UPSTREAM=""
if [ -n "$UPSTREAM" ] && [ -n "$(docker exec -u node "$DNS_C" dig +short +time=3 api.anthropic.com 2>/dev/null)" ] \
    && ! docker exec -u node "$DNS_C" dig +short +time=2 +tries=1 "@$UPSTREAM" api.anthropic.com 2>/dev/null \
        | grep -qE '^[0-9.]+$'; then
    pass "node resolves through dnsmasq and cannot ask the upstream resolver ($UPSTREAM) directly"
else
    fail "node can bypass dnsmasq, or cannot resolve through it"
fi
IP=$(docker exec -u node "$DNS_C" dig +short api.anthropic.com 2>/dev/null | grep -E '^[0-9.]+$' | head -1) || IP=""
docker exec "$DNS_C" ipset del allowed-domains "$IP" 2>/dev/null || true
docker exec "$DNS_C" pkill -HUP dnsmasq || true      # clear its cache: the next lookup goes upstream
if [ -n "$IP" ] && ! docker exec "$DNS_C" ipset test allowed-domains "$IP" 2>/dev/null \
    && docker exec -u node "$DNS_C" curl --connect-timeout 10 -so /dev/null https://api.anthropic.com \
    && docker exec "$DNS_C" ipset test allowed-domains "$IP" 2>/dev/null; then
    pass "an address missing from the set comes back on the next lookup ($IP)"
else
    fail "a lookup did not put $IP back in the allowed set"
fi
docker rm -f "$DNS_C" >/dev/null 2>&1

echo "-- DNS refresh unavailable: still strict --"
FB_OUT=$(docker run --rm --cap-add NET_ADMIN --cap-add NET_RAW -e SANDBOX_FIREWALL=strict \
    -v /dev/null:/usr/sbin/dnsmasq:ro "$IMAGE" \
    bash -c 'head -1 /etc/resolv.conf; curl --connect-timeout 5 -sf https://example.com >/dev/null 2>&1 && echo REACHED' 2>&1) || true
if echo "$FB_OUT" | grep -q "DNS-refresh unavailable" && ! echo "$FB_OUT" | grep -q "nameserver 127.0.0.1" \
    && ! echo "$FB_OUT" | grep -q REACHED; then
    pass "without dnsmasq: warning, resolv.conf untouched, example.com still blocked"
else
    fail "the fallback without dnsmasq is not strict: $FB_OUT"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
