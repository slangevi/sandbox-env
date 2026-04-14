#!/bin/bash
# features/aws.sh — Install AWS CLI v2
set -euo pipefail

echo "=== Installing AWS feature ==="

apt-get update && apt-get install -y --no-install-recommends \
    groff \
    && rm -rf /var/lib/apt/lists/*

ARCH=$(dpkg --print-architecture)
if [ "$ARCH" = "amd64" ]; then AWS_ARCH="x86_64"; else AWS_ARCH="aarch64"; fi

# Pin AWS CLI version for reproducible builds
AWS_CLI_VERSION="2.27.30"
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${AWS_ARCH}-${AWS_CLI_VERSION}.zip" -o /tmp/awscliv2.zip
cd /tmp && unzip -q awscliv2.zip
/tmp/aws/install
rm -rf /tmp/aws /tmp/awscliv2.zip

# Firewall domains
mkdir -p /etc/sandbox/firewall.d
cat > /etc/sandbox/firewall.d/aws.conf <<'EOF'
awscli.amazonaws.com
sts.amazonaws.com
s3.amazonaws.com
EOF

echo "=== AWS feature installed ==="
