#!/bin/bash
# features/go.sh — Install Go development environment
set -euo pipefail

echo "=== Installing Go feature ==="

GO_VERSION="1.22.5"
ARCH=$(dpkg --print-architecture)
if [ "$ARCH" = "amd64" ]; then GO_ARCH="amd64"; else GO_ARCH="arm64"; fi

curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${GO_ARCH}.tar.gz" \
    | tar -C /usr/local -xz

# Make Go available system-wide
echo 'export PATH="/usr/local/go/bin:$HOME/go/bin:$PATH"' >> /etc/profile.d/go.sh
echo 'export GOPATH="$HOME/go"' >> /etc/profile.d/go.sh

# Source for this session
export PATH="/usr/local/go/bin:$PATH"
export GOPATH="/tmp/go-setup"

# Install golangci-lint — pinned version
GOLANGCI_LINT_VERSION="v2.1.0"
curl -sSfL https://raw.githubusercontent.com/golangci/golangci-lint/HEAD/install.sh \
    | sh -s -- -b /usr/local/bin "${GOLANGCI_LINT_VERSION}"

# Clean up
rm -rf "$GOPATH"

# Firewall domains
mkdir -p /etc/sandbox/firewall.d
cat > /etc/sandbox/firewall.d/go.conf <<'EOF'
go.dev
dl.google.com
proxy.golang.org
sum.golang.org
storage.googleapis.com
EOF

echo "=== Go feature installed ==="
