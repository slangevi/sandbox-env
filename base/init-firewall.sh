#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

echo "=== Sandbox Firewall Init (strict mode) ==="

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
echo "Fetching GitHub IP ranges..."
gh_ranges=$(curl -sf https://api.github.com/meta)
if [ -n "$gh_ranges" ] && echo "$gh_ranges" | jq -e '.web and .api and .git' >/dev/null 2>&1; then
    while read -r cidr; do
        ipset add allowed-domains "$cidr" 2>/dev/null || true
    done < <(echo "$gh_ranges" | jq -r '(.web + .api + .git)[]' | aggregate -q 2>/dev/null || echo "$gh_ranges" | jq -r '(.web + .api + .git)[]')
    echo "GitHub IPs added."
else
    echo "WARNING: Could not fetch GitHub IPs. GitHub access may not work."
fi

# 7. Resolve domains from base config + feature configs + project domains
collect_domains() {
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
}

while read -r domain; do
    [ -z "$domain" ] && continue
    echo "Resolving $domain..."
    ips=$(dig +noall +answer A "$domain" 2>/dev/null | awk '$4 == "A" {print $5}')
    if [ -z "$ips" ]; then
        echo "WARNING: Could not resolve $domain"
        continue
    fi
    while read -r ip; do
        ipset add allowed-domains "$ip" 2>/dev/null || true
    done <<< "$ips"
done < <(collect_domains | sort -u)

# 8. Allow host gateway (for Docker host communication)
HOST_IP=$(ip route | grep default | awk '{print $3}')
if [ -n "$HOST_IP" ]; then
    echo "Allowing host gateway: $HOST_IP"
    iptables -A INPUT -s "$HOST_IP" -j ACCEPT
    iptables -A OUTPUT -d "$HOST_IP" -j ACCEPT
fi

# 8b. Replace broad DNS rule with restricted resolver-only rule
# Detect the actual DNS resolver (127.0.0.11 on Linux Docker, varies on Docker Desktop)
DNS_RESOLVER=$(awk '/^nameserver/ {print $2; exit}' /etc/resolv.conf)
if [ -z "$DNS_RESOLVER" ]; then
    DNS_RESOLVER="127.0.0.11"
fi
echo "Restricting DNS to resolver: $DNS_RESOLVER"
iptables -D OUTPUT -p udp --dport 53 -j ACCEPT
iptables -D INPUT -p udp --sport 53 -j ACCEPT
iptables -A OUTPUT -p udp --dport 53 -d "$DNS_RESOLVER" -j ACCEPT
iptables -A INPUT -p udp --sport 53 -s "$DNS_RESOLVER" -j ACCEPT

# 8c. SSH restricted to allowed domains only (applied after ipset is populated)
iptables -A OUTPUT -p tcp --dport 22 -m set --match-set allowed-domains dst -j ACCEPT
iptables -A INPUT -p tcp --sport 22 -m state --state ESTABLISHED -j ACCEPT

# 9. Set default policies
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# 9b. Block all IPv6 traffic (firewall only manages IPv4)
if command -v ip6tables &>/dev/null; then
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

# Verify an allowed domain is reachable (use -o /dev/null without -f since API returns 401 without auth)
if ! curl --connect-timeout 10 -so /dev/null https://api.anthropic.com 2>/dev/null; then
    echo "WARNING: Firewall may be too restrictive — could not reach api.anthropic.com"
fi
