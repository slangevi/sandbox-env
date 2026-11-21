#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# SANDBOX_FIREWALL=strict (default here) or hostonly. The hostonly profile is
# strict with no domain list at all: no names are resolved or allowed (no
# GitHub, registries, code hosts, Anthropic or telemetry), only the Docker host
# (reached through /etc/hosts) on SANDBOX_HOST_PORTS, dnsmasq answers NXDOMAIN
# for every name, and port 22 is not opened. It fails closed: any problem
# exits non-zero rather than leaving a weaker firewall.
HOSTONLY=false
[ "${SANDBOX_FIREWALL:-strict}" = "hostonly" ] && HOSTONLY=true

if $HOSTONLY; then
    echo "=== Sandbox Firewall Init (hostonly profile) ==="
else
    echo "=== Sandbox Firewall Init (strict mode) ==="
fi

if $HOSTONLY; then
    # Caller-supplied allow lists would bypass the "no names" rule.
    if [ -n "${SANDBOX_ALLOWED_DOMAINS:-}" ] || [ -n "${SANDBOX_COMFYUI_IP:-}" ]; then
        echo "ERROR: hostonly profile accepts no SANDBOX_ALLOWED_DOMAINS or SANDBOX_COMFYUI_IP"
        exit 1
    fi
    HOST_PORTS="${SANDBOX_HOST_PORTS:-18080,18081}"
    IFS=, read -r -a _ports <<< "$HOST_PORTS"
    if [ "${#_ports[@]}" -lt 1 ] || [ "${#_ports[@]}" -gt 15 ]; then
        echo "ERROR: SANDBOX_HOST_PORTS must list 1 to 15 ports, got '$HOST_PORTS'"
        exit 1
    fi
    for _p in "${_ports[@]}"; do
        if ! [[ "$_p" =~ ^[0-9]{1,5}$ ]] || [ "$((10#$_p))" -lt 1 ] || [ "$((10#$_p))" -gt 65535 ]; then
            echo "ERROR: SANDBOX_HOST_PORTS entry '$_p' is not a port from 1 to 65535 (list: '$HOST_PORTS')"
            exit 1
        fi
    done
    # IPv6 is only blocked by ip6tables; without it the profile cannot hold.
    if ! command -v ip6tables >/dev/null 2>&1; then
        echo "ERROR: ip6tables is missing; the hostonly profile cannot block IPv6"
        exit 1
    fi
fi

# 1. Preserve Docker DNS rules
DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)

# 2. Flush existing rules
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true

# 3. Restore Docker DNS
if [ -n "$DOCKER_DNS_RULES" ]; then
    echo "Restoring Docker DNS rules..."
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
else
    echo "No Docker DNS rules to restore."
fi

# 4. Temporarily allow DNS to any destination (needed for domain resolution during init)
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A INPUT -p udp --sport 53 -j ACCEPT

# 4b. Allow localhost
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# 5. Create ipset
ipset create allowed-domains hash:net

# 6. GitHub IPs via /meta API
if ! $HOSTONLY; then
echo "Fetching GitHub IP ranges..."
# `|| gh_ranges=""` is load-bearing under `set -e`: curl -sf exits non-zero on
# any transient GitHub failure (5xx, rate limit, DNS hiccup), which would abort
# this whole script and leave the container with no firewall at all — and would
# make the WARNING branch below unreachable, though that branch is the author's
# own statement that warn-and-continue is the intent. `sandbox comfy` starts a
# fresh strict container per invocation, so without this a GitHub blip breaks
# every image generation, not just a session start.
gh_ranges=$(curl -sf https://api.github.com/meta) || gh_ranges=""
if [ -n "$gh_ranges" ] && echo "$gh_ranges" | jq -e '.web and .api and .git' >/dev/null 2>&1; then
    while read -r cidr; do
        ipset add allowed-domains "$cidr" 2>/dev/null || true
    done < <(echo "$gh_ranges" | jq -r '(.web + .api + .git)[]' | aggregate -q 2>/dev/null || echo "$gh_ranges" | jq -r '(.web + .api + .git)[]')
    echo "GitHub IPs added."
else
    echo "WARNING: Could not fetch GitHub IPs. GitHub access may not work."
fi
fi

# 7. Resolve domains from base config + feature configs + project domains
collect_domains() {
    # hostonly: no domain list is read at all.
    $HOSTONLY && return 0
    # Base domains
    if [ -f /etc/sandbox/firewall-domains.conf ]; then
        grep -v '^#' /etc/sandbox/firewall-domains.conf | grep -v '^$'
    fi
    # Feature domains
    if [ -d /etc/sandbox/firewall.d ]; then
        for conf in /etc/sandbox/firewall.d/*.conf; do
            [ -f "$conf" ] && grep -v '^#' "$conf" | grep -v '^$'
        done
    fi
    # Project domains (passed via env var as comma-separated list)
    if [ -n "${SANDBOX_ALLOWED_DOMAINS:-}" ]; then
        echo "$SANDBOX_ALLOWED_DOMAINS" | tr ',' '\n'
    fi
    # The ComfyUI container's address, derived by the CLI from a running
    # container — deliberately separate from SANDBOX_ALLOWED_DOMAINS, which
    # is user-supplied. An IPv4 literal, so the loop below adds it to the
    # ipset directly with nothing for dig to resolve.
    if [ -n "${SANDBOX_COMFYUI_IP:-}" ]; then
        echo "$SANDBOX_COMFYUI_IP"
    fi
}

# 7a. DNS refresh. A CDN-hosted allowed domain answers with rotating edge
# addresses, so a set filled once at start goes stale within minutes. dnsmasq
# becomes the container's only resolver and puts every address it hands out
# for an allowed name into the set before the application sees the answer
# (`ipset=`; it matches a name and its subdomains). Entries are only added.
# If dnsmasq is missing, will not start, or does not fill the set, init falls
# back to resolving once — still strict, just without the refresh.
DNS_RESOLVER=$(awk '/^nameserver/ {print $2; exit}' /etc/resolv.conf)
if [ -z "$DNS_RESOLVER" ]; then
    DNS_RESOLVER="127.0.0.11"
fi
IP_LITERAL='^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$'
DNS_REFRESH=false
DNSMASQ_CONF=/run/sandbox-dnsmasq.conf
DNSMASQ_PID=/run/sandbox-dnsmasq.pid
# A name admits every name under it (dnsmasq's ipset= matches subdomains), so a
# single-label entry such as `org` would open a whole TLD: it is skipped (the
# CLI refuses it too).
NAMES=$(collect_domains | sort -u | grep -v -E "$IP_LITERAL" | grep -F . || true)
stop_dnsmasq() {
    [ -f "$DNSMASQ_PID" ] && kill "$(cat "$DNSMASQ_PID")" 2>/dev/null || true
    rm -f "$DNSMASQ_PID"
    DNS_REFRESH=false
}
# dnsmasq listens on 127.0.0.1; an upstream on that same address would be
# itself (and the loopback REJECT below would cut programs off from 127.0.0.1).
if $HOSTONLY; then
    # hostonly: dnsmasq always runs, with no upstream and address=/#/, so every
    # name (not in /etc/hosts) answers NXDOMAIN. Failure to start is fatal.
    if ! command -v dnsmasq >/dev/null 2>&1 || ! id dnsmasq >/dev/null 2>&1; then
        echo "ERROR: hostonly profile needs dnsmasq and its user"
        exit 1
    fi
    {
        echo "listen-address=127.0.0.1"
        echo "bind-interfaces"
        echo "port=53"
        echo "no-resolv"
        echo "address=/#/"
        echo "user=dnsmasq"
        echo "pid-file=$DNSMASQ_PID"
    } > "$DNSMASQ_CONF"
    chmod 644 "$DNSMASQ_CONF"
    if ! dnsmasq --conf-file="$DNSMASQ_CONF" 2>/tmp/sandbox-dnsmasq.err; then
        echo "ERROR: dnsmasq did not start"
        cat /tmp/sandbox-dnsmasq.err
        exit 1
    fi
    DNS_REFRESH=true
    echo "Host-only DNS: dnsmasq on 127.0.0.1 answers NXDOMAIN for every name."
elif [ -n "$NAMES" ] && [ "$DNS_RESOLVER" != "127.0.0.1" ] \
    && command -v dnsmasq >/dev/null 2>&1 && id dnsmasq >/dev/null 2>&1; then
    {
        echo "listen-address=127.0.0.1"
        echo "bind-interfaces"
        echo "port=53"
        echo "no-resolv"
        echo "server=$DNS_RESOLVER"
        echo "user=dnsmasq"
        echo "pid-file=$DNSMASQ_PID"
        echo "cache-size=1000"
        echo "ipset=/$(echo "$NAMES" | paste -sd/)/allowed-domains"
    } > "$DNSMASQ_CONF"
    chmod 644 "$DNSMASQ_CONF"
    if dnsmasq --conf-file="$DNSMASQ_CONF" 2>/tmp/sandbox-dnsmasq.err; then
        DNS_REFRESH=true
        echo "DNS refresh: dnsmasq on 127.0.0.1 fills the allowed set as names resolve."
    fi
fi

VERIFIED=0
resolve_allowed() {
    while read -r domain; do
        [ -z "$domain" ] && continue
        # IPv4 literals and CIDRs (a LAN host such as a NAS, which has no public
        # DNS name and whose mDNS .local name does not resolve in here) go into
        # the set directly — there is nothing for dig to resolve.
        if [[ "$domain" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$ ]]; then
            echo "Allowing IP literal $domain"
            ipset -exist add allowed-domains "$domain" 2>/dev/null \
                || echo "WARNING: Could not add $domain to the allowed set"
            continue
        fi
        if [[ "$domain" != *.* ]]; then
            echo "WARNING: allowed entry '$domain' is not a dotted name; skipped (it would admit every name under it)"
            continue
        fi
        echo "Resolving $domain..."
        if $DNS_REFRESH; then
            # Through dnsmasq: it fills the set itself. Checking that it did is
            # what proves the refresh works, not merely that dnsmasq runs.
            # A name that does not answer (timeout, refused) is a warning, not
            # an abort: dig exits non-zero and pipefail would end init here.
            ips=$(dig @127.0.0.1 +time=3 +tries=2 +noall +answer A "$domain" 2>/dev/null | awk '$4 == "A" {print $5}') || ips=""
            while read -r ip; do
                [ -z "$ip" ] && continue
                if ipset test allowed-domains "$ip" 2>/dev/null; then
                    VERIFIED=$((VERIFIED + 1))
                else
                    echo "WARNING: dnsmasq did not add $ip ($domain) to the allowed set"
                    stop_dnsmasq
                    ipset add allowed-domains "$ip" 2>/dev/null || true
                fi
            done <<< "$ips"
        fi
        if ! $DNS_REFRESH; then
            ips=$(dig +noall +answer A "$domain" 2>/dev/null | awk '$4 == "A" {print $5}') || ips=""
            while read -r ip; do
                [ -n "$ip" ] && ipset add allowed-domains "$ip" 2>/dev/null || true
            done <<< "$ips"
        fi
        if [ -z "$ips" ]; then
            echo "WARNING: Could not resolve $domain"
        fi
    done < <(collect_domains | sort -u)
}
resolve_allowed
if ! $HOSTONLY && $DNS_REFRESH && [ "$VERIFIED" -eq 0 ]; then
    # dnsmasq runs but answered nothing it could prove was added: not the
    # resolver. Resolve once, directly.
    echo "WARNING: dnsmasq answered no allowed name"
    stop_dnsmasq
    resolve_allowed
fi
if [ -n "$NAMES" ] && ! $DNS_REFRESH; then
    echo "WARNING: DNS-refresh unavailable; allowed domains resolved once"
    [ -s /tmp/sandbox-dnsmasq.err ] && sed 's/^/  dnsmasq: /' /tmp/sandbox-dnsmasq.err
fi

# 8. Allow the Docker host: at the default route's gateway, and at the address
# `host.docker.internal` resolves to when the CLI added that alias (the spark
# backend points ANTHROPIC_BASE_URL at it). The two differ once the sandbox has
# joined a non-default network — every features: [comfyui] project joins the
# ComfyUI compose network — because Docker's host-gateway is always the default
# bridge's gateway while the route's gateway is the joined network's. Both are
# this host; allowing only the route's gateway rejected every model request
# from a comfyui project with "connection refused".
# hostonly: only SANDBOX_HOST_PORTS (default 18080,18081: a credential proxy
# and a package registry proxy) are open on the host, not every port.
allow_host() {   # allow_host <ipv4> <label>
    [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 0
    if $HOSTONLY; then
        echo "Allowing $2: $1 (tcp ports $HOST_PORTS)"
        iptables -A OUTPUT -p tcp -d "$1" -m multiport --dports "$HOST_PORTS" -j ACCEPT
        return 0
    fi
    echo "Allowing $2: $1"
    iptables -A INPUT -s "$1" -j ACCEPT
    iptables -A OUTPUT -d "$1" -j ACCEPT
}
HOST_IP=$(ip route | grep default | awk '{print $3}')
if $HOSTONLY; then
    # hostonly: the alias only from /etc/hosts (docker's --add-host). getent would fall back
    # to DNS, which is still open at this point, and an upstream answer must never decide
    # which address gets the host ports.
    ALIAS_IP=$(awk '$1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { for (i = 2; i <= NF; i++)
        if ($i == "host.docker.internal") { print $1; exit } }' /etc/hosts 2>/dev/null || true)
else
    ALIAS_IP=$(getent ahostsv4 host.docker.internal 2>/dev/null | awk '{print $1; exit}' || true)
fi
allow_host "$HOST_IP" "host gateway"
if [ -n "$ALIAS_IP" ] && [ "$ALIAS_IP" != "$HOST_IP" ]; then
    allow_host "$ALIAS_IP" "host alias host.docker.internal"
fi

# 8b. Replace broad DNS rule with restricted resolver-only rule
# (DNS_RESOLVER was detected in 7a: 127.0.0.11 on a user-defined Docker
# network, the host's resolver on the default bridge, varies on Docker Desktop.)
iptables -D OUTPUT -p udp --dport 53 -j ACCEPT
iptables -D INPUT -p udp --sport 53 -j ACCEPT
if $HOSTONLY; then
    # DNS is dnsmasq on 127.0.0.1 only (loopback is already accepted); nothing
    # may reach any upstream, including Docker's embedded resolver on loopback.
    echo "Restricting DNS to dnsmasq on 127.0.0.1 (no upstream)"
    if [[ "$DNS_RESOLVER" == 127.* && "$DNS_RESOLVER" != "127.0.0.1" ]]; then
        iptables -I OUTPUT 1 -d "$DNS_RESOLVER" -j REJECT
    fi
    iptables -I OUTPUT 1 -d 127.0.0.11 -j REJECT
    { echo "nameserver 127.0.0.1"; grep -E '^(search|options)' /etc/resolv.conf || true; } > /tmp/resolv.conf.new
    cat /tmp/resolv.conf.new > /etc/resolv.conf
    rm -f /tmp/resolv.conf.new
elif $DNS_REFRESH; then
    # Only dnsmasq may ask the upstream resolver; everything else asks dnsmasq
    # on 127.0.0.1, so no process can resolve an address that skips the set.
    echo "Restricting DNS to dnsmasq -> $DNS_RESOLVER"
    iptables -A OUTPUT -p udp --dport 53 -d "$DNS_RESOLVER" -m owner --uid-owner dnsmasq -j ACCEPT
    iptables -A OUTPUT -p tcp --dport 53 -d "$DNS_RESOLVER" -m owner --uid-owner dnsmasq -j ACCEPT
    iptables -A INPUT -p udp --sport 53 -s "$DNS_RESOLVER" -j ACCEPT
    if [[ "$DNS_RESOLVER" == 127.* ]]; then
        # Docker's embedded resolver is on loopback (DNAT to a random port), so
        # the loopback ACCEPT above would let anyone reach it: refuse it to all
        # but dnsmasq, ahead of that rule.
        iptables -I OUTPUT 1 -d "$DNS_RESOLVER" -m owner ! --uid-owner dnsmasq -j REJECT
    fi
    { echo "nameserver 127.0.0.1"; grep -E '^(search|options)' /etc/resolv.conf || true; } > /tmp/resolv.conf.new
    cat /tmp/resolv.conf.new > /etc/resolv.conf
    rm -f /tmp/resolv.conf.new
else
    echo "Restricting DNS to resolver: $DNS_RESOLVER"
    iptables -A OUTPUT -p udp --dport 53 -d "$DNS_RESOLVER" -j ACCEPT
    iptables -A INPUT -p udp --sport 53 -s "$DNS_RESOLVER" -j ACCEPT
fi

# 8c. SSH restricted to allowed domains only (applied after ipset is populated)
# (hostonly: port 22 is not opened)
if ! $HOSTONLY; then
    iptables -A OUTPUT -p tcp --dport 22 -m set --match-set allowed-domains dst -j ACCEPT
    iptables -A INPUT -p tcp --sport 22 -m state --state ESTABLISHED -j ACCEPT
fi

# 9. Set default policies
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# 9b. Block all IPv6 traffic (firewall only manages IPv4)
if command -v ip6tables &>/dev/null; then   # hostonly: checked at the top
    ip6tables -P INPUT DROP
    ip6tables -P FORWARD DROP
    ip6tables -P OUTPUT DROP
    ip6tables -A INPUT -i lo -j ACCEPT
    ip6tables -A OUTPUT -o lo -j ACCEPT
fi

# 10. Allow established + ipset destinations
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT

# 11. Reject everything else with immediate feedback
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

# 12. Verify
echo "Verifying firewall..."
if curl --connect-timeout 5 -sf https://example.com >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed — reached example.com"
    exit 1
fi
echo "Firewall active. Blocked domains are unreachable."

if $HOSTONLY; then
    # An unlisted name must be NXDOMAIN, or the resolver is not what we set up.
    if ! dig @127.0.0.1 +time=3 +tries=1 hostonly-nxdomain-probe.invalid 2>/dev/null | grep -q "status: NXDOMAIN"; then
        echo "ERROR: hostonly DNS check failed: an unlisted name did not return NXDOMAIN"
        exit 1
    fi
    # Reachability of the host ports (nothing may be listening yet: warn only).
    if ! curl --connect-timeout 5 -so /dev/null http://host.docker.internal:18080 2>/dev/null; then
        echo "WARNING: could not reach host.docker.internal:18080 (nothing listening, or the alias is missing)"
    fi
    exit 0
fi

# Verify an allowed domain is reachable (use -o /dev/null without -f since API returns 401 without auth)
if ! curl --connect-timeout 10 -so /dev/null https://api.anthropic.com 2>/dev/null; then
    echo "WARNING: Firewall may be too restrictive — could not reach api.anthropic.com"
fi
