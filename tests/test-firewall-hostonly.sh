#!/bin/bash
# tests/test-firewall-hostonly.sh — The hostonly firewall profile: no names
# resolved or allowed (NXDOMAIN for every name), and only SANDBOX_HOST_PORTS
# (default 18080,18081) open on the Docker host.
# Needs Docker with NET_ADMIN and host python3 (throwaway listeners on the
# docker0 gateway, ports 18080 and 14001; nothing else is touched).
# 14001 is the "closed by default, opened by SANDBOX_HOST_PORTS" port; it is
# chosen to avoid 14000, a port commonly in use on development hosts.
set -euo pipefail

IMAGE="${IMAGE:-sandbox-base:latest}"
HOST_GW="${HOST_GW:-172.17.0.1}"
PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== Firewall Tests (hostonly profile) ==="

command -v python3 >/dev/null || { echo "SKIP: host python3 required for the listeners"; exit 0; }

DIR=$(mktemp -d)
PIDS=()
THROWAWAY="sandbox-fwtest-hostonly-feature-$$"
NET="sandbox-fwtest-hostonly-net-$$"
cleanup() {
    docker rmi -f "$THROWAWAY" >/dev/null 2>&1 || true
    docker network rm "$NET" >/dev/null 2>&1 || true
    for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done
    rm -rf "$DIR"
}
trap cleanup EXIT
for port in 18080 14001; do
    python3 -m http.server "$port" --bind "$HOST_GW" --directory "$DIR" >/dev/null 2>&1 &
    PIDS+=($!)
done
sleep 1

# run_hostonly <extra docker args...> -- <shell command>; exit status is the command's
run_hostonly() {
    local args=()
    while [ "$1" != "--" ]; do args+=("$1"); shift; done
    shift
    docker run --rm --cap-add NET_ADMIN --cap-add NET_RAW \
        --add-host host.docker.internal:host-gateway \
        -e SANDBOX_FIREWALL=hostonly "${args[@]}" "$IMAGE" bash -c "$1"
}

check_blocked() {   # check_blocked <url> [docker args...]
    local url="$1"; shift
    if run_hostonly "$@" -- "curl --connect-timeout 5 -s -o /dev/null $url" >/dev/null 2>&1; then
        fail "$url should be blocked but is reachable"
    else
        pass "$url is blocked"
    fi
}
check_reachable() {   # check_reachable <url> <label> [docker args...]
    local url="$1" label="$2"; shift 2
    # any HTTP answer counts: the port may be held by this test's listener or by a real
    # service already running on the host (a proxy on 18080, say)
    if run_hostonly "$@" -- "test \"\$(curl --connect-timeout 5 -s -o /dev/null -w '%{http_code}' $url)\" != 000" >/dev/null 2>&1; then
        pass "$label"
    else
        fail "$label"
    fi
}

echo "-- required blocks --"
check_blocked "https://api.anthropic.com"
check_blocked "https://github.com"
check_blocked "https://api.github.com"
check_blocked "https://pypi.org"
check_blocked "${LAN_URL:-http://192.168.1.1}"   # a LAN host (override with LAN_URL)
check_blocked "https://example.com"
check_blocked "https://gitlab.com"
check_blocked "https://registry.gitlab.com"
check_blocked "https://registry.npmjs.org"
check_blocked "https://statsig.com"
check_blocked "https://sentry.io"
check_blocked "https://storage.googleapis.com"
check_blocked "https://claude.ai"
if run_hostonly -- 'timeout 8 bash -c "exec 3<>/dev/tcp/gitlab.com/22" 2>/dev/null' >/dev/null 2>&1; then
    fail "SSH to gitlab.com:22 is reachable"
else
    pass "SSH to gitlab.com:22 is blocked"
fi

echo "-- an unlisted name returns NXDOMAIN (dnsmasq stays) --"
OUT=$(run_hostonly -- 'dig +time=3 +tries=1 nonexistent-hostonly-test.example.net 2>&1' 2>&1) || true
if echo "$OUT" | grep -q "status: NXDOMAIN"; then
    pass "unlisted name -> NXDOMAIN"
else
    fail "unlisted name did not return NXDOMAIN: $(echo "$OUT" | grep -E 'status|timed out' | head -2 | tr '\n' ' ')"
fi
OUT=$(run_hostonly -- 'dig +time=3 +tries=1 api.anthropic.com 2>&1' 2>&1) || true
if echo "$OUT" | grep -q "status: NXDOMAIN"; then
    pass "api.anthropic.com -> NXDOMAIN"
else
    fail "api.anthropic.com still resolves"
fi

echo "-- only the hostonly host ports are open on the Docker host --"
check_reachable "http://host.docker.internal:18080/" "host port 18080 reachable (default)"
check_blocked "http://host.docker.internal:14001/"
check_reachable "http://host.docker.internal:14001/" "host port 14001 reachable with SANDBOX_HOST_PORTS=14001" \
    -e SANDBOX_HOST_PORTS=14001
check_blocked "http://host.docker.internal:18080/" -e SANDBOX_HOST_PORTS=14001

echo "-- the host alias comes from /etc/hosts only --"
OUT=$(docker run --rm --cap-add NET_ADMIN --cap-add NET_RAW --add-host host.docker.internal:192.0.2.10 \
    -e SANDBOX_FIREWALL=hostonly "$IMAGE" true 2>&1) || true
if echo "$OUT" | grep -q "Allowing host alias host.docker.internal: 192.0.2.10"; then
    pass "alias taken from /etc/hosts"
else
    fail "alias in /etc/hosts not allowed"
fi
OUT=$(docker run --rm --cap-add NET_ADMIN --cap-add NET_RAW -e SANDBOX_FIREWALL=hostonly "$IMAGE" true 2>&1) || true
if echo "$OUT" | grep -q "host alias"; then
    fail "an alias was allowed without an /etc/hosts entry"
else
    pass "no /etc/hosts entry: no alias allowed"
fi

echo "-- feature domain lists are ignored --"
BDIR=$(mktemp -d)
printf 'FROM %s\nUSER root\nRUN mkdir -p /etc/sandbox/firewall.d && echo pypi.org > /etc/sandbox/firewall.d/python.conf\n' "$IMAGE" > "$BDIR/Dockerfile"
docker build -q -t "$THROWAWAY" "$BDIR" >/dev/null
rm -rf "$BDIR"
if docker run --rm --cap-add NET_ADMIN --cap-add NET_RAW -e SANDBOX_FIREWALL=strict "$THROWAWAY" \
    bash -c 'curl --connect-timeout 10 -sf -o /dev/null https://pypi.org' >/dev/null 2>&1; then
    pass "control: pypi.org is reachable under strict with the feature list"
else
    fail "control: pypi.org should be reachable under strict with the feature list"
fi
if docker run --rm --cap-add NET_ADMIN --cap-add NET_RAW -e SANDBOX_FIREWALL=hostonly "$THROWAWAY" \
    bash -c 'curl --connect-timeout 5 -s -o /dev/null https://pypi.org' >/dev/null 2>&1; then
    fail "pypi.org reachable under hostonly via a feature list"
else
    pass "pypi.org blocked under hostonly despite the feature list"
fi

echo "-- DNS lockdown: no direct query to the Docker resolver --"
UPSTREAM=$(docker run --rm --entrypoint awk "$IMAGE" '/^nameserver/{print $2; exit}' /etc/resolv.conf)
docker network create "$NET" >/dev/null
for target in "default network:$UPSTREAM:" "user-defined network:127.0.0.11:--network $NET"; do
    label=${target%%:*}; rest=${target#*:}; ip=${rest%%:*}; netarg=${rest#*:}
    # shellcheck disable=SC2086
    OUT=$(run_hostonly $netarg -- "dig @$ip +time=2 +tries=1 +short api.anthropic.com 2>&1; dig @$ip +time=2 +tries=1 +short +tcp api.anthropic.com 2>&1" 2>&1) || true
    if echo "$OUT" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        fail "a direct query to $ip answered on the $label"
    else
        pass "direct query to the Docker resolver $ip is blocked on the $label"
    fi
done

echo "-- fail closed --"
expect_exit() {   # expect_exit <label> [docker args...]
    local label="$1"; shift
    if docker run --rm --cap-add NET_ADMIN --cap-add NET_RAW "$@" "$IMAGE" true >/dev/null 2>&1; then
        fail "$label: the container started"
    else
        pass "$label: the container exits non-zero"
    fi
}
expect_exit "SANDBOX_ALLOWED_DOMAINS=github.com" -e SANDBOX_FIREWALL=hostonly -e SANDBOX_ALLOWED_DOMAINS=github.com
expect_exit "SANDBOX_COMFYUI_IP=172.20.0.2" -e SANDBOX_FIREWALL=hostonly -e SANDBOX_COMFYUI_IP=172.20.0.2
expect_exit "SANDBOX_HOST_PORTS=abc" -e SANDBOX_FIREWALL=hostonly -e SANDBOX_HOST_PORTS=abc
expect_exit "SANDBOX_HOST_PORTS=99999" -e SANDBOX_FIREWALL=hostonly -e SANDBOX_HOST_PORTS=99999
expect_exit "SANDBOX_HOST_PORTS=0" -e SANDBOX_FIREWALL=hostonly -e SANDBOX_HOST_PORTS=0
expect_exit "16 ports in SANDBOX_HOST_PORTS" -e SANDBOX_FIREWALL=hostonly -e SANDBOX_HOST_PORTS=1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16
expect_exit "SANDBOX_FIREWALL=fatcory (typo)" -e SANDBOX_FIREWALL=fatcory
if docker run --rm -e SANDBOX_FIREWALL=open "$IMAGE" true >/dev/null 2>&1 \
    && docker run --rm "$IMAGE" true >/dev/null 2>&1 \
    && docker run --rm -e SANDBOX_FIREWALL= "$IMAGE" true >/dev/null 2>&1; then
    pass "open, unset and empty SANDBOX_FIREWALL still start (no firewall)"
else
    fail "open/unset/empty SANDBOX_FIREWALL no longer starts"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
