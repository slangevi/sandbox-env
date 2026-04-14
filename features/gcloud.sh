#!/bin/bash
# features/gcloud.sh — Install Google Cloud SDK
set -euo pipefail

echo "=== Installing gcloud feature ==="

apt-get update && apt-get install -y --no-install-recommends \
    apt-transport-https \
    && rm -rf /var/lib/apt/lists/*

# Add Google Cloud apt repo
curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
    | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
    | tee /etc/apt/sources.list.d/google-cloud-sdk.list > /dev/null

# gcloud version is managed by Google's apt repo — pinned upstream
# To pin a specific version: apt-get install google-cloud-cli=VERSION
apt-get update && apt-get install -y --no-install-recommends \
    google-cloud-cli \
    google-cloud-cli-gke-gcloud-auth-plugin \
    && rm -rf /var/lib/apt/lists/*

# Firewall domains
mkdir -p /etc/sandbox/firewall.d
cat > /etc/sandbox/firewall.d/gcloud.conf <<'EOF'
packages.cloud.google.com
dl.google.com
oauth2.googleapis.com
storage.googleapis.com
cloudresourcemanager.googleapis.com
compute.googleapis.com
container.googleapis.com
EOF

echo "=== gcloud feature installed ==="
