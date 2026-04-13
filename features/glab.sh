#!/bin/bash
# features/glab.sh — Install GitLab CLI (glab)
set -euo pipefail

echo "=== Installing glab feature ==="

ARCH=$(dpkg --print-architecture)
GLAB_VERSION="1.92.1"

curl -fsSL "https://gitlab.com/gitlab-org/cli/-/releases/v${GLAB_VERSION}/downloads/glab_${GLAB_VERSION}_linux_${ARCH}.deb" \
    -o /tmp/glab.deb
dpkg -i /tmp/glab.deb
rm /tmp/glab.deb

# Firewall domains
mkdir -p /etc/sandbox/firewall.d
cat > /etc/sandbox/firewall.d/glab.conf <<'EOF'
gitlab.com
registry.gitlab.com
EOF

echo "=== glab feature installed ==="
