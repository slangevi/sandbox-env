#!/bin/bash
# features/python.sh — Install Python development environment
set -euo pipefail

echo "=== Installing Python feature ==="

apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    python3-pip \
    python3-venv \
    python3-dev \
    && rm -rf /var/lib/apt/lists/*

# Symlink python -> python3
ln -sf /usr/bin/python3 /usr/bin/python

# Upgrade pip and install pipx
python3 -m pip install --break-system-packages --upgrade pip
python3 -m pip install --break-system-packages pipx
python3 -m pipx ensurepath

# Firewall domains
mkdir -p /etc/sandbox/firewall.d
cat > /etc/sandbox/firewall.d/python.conf <<'EOF'
pypi.org
files.pythonhosted.org
EOF

echo "=== Python feature installed ==="
