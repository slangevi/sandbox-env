#!/bin/bash
# features/ollama.sh — Install Ollama server for local LLM inference
set -euo pipefail

echo "=== Installing Ollama feature ==="

# Install Ollama binary — pinned version, direct download (no curl|sh)
OLLAMA_VERSION="0.9.0"
curl -fsSL "https://github.com/ollama/ollama/releases/download/v${OLLAMA_VERSION}/ollama-linux-$(dpkg --print-architecture)" \
    -o /usr/local/bin/ollama
chmod +x /usr/local/bin/ollama

# Create model storage directory (expected to be mounted from host)
mkdir -p /home/node/.ollama/models
chown -R node:node /home/node/.ollama

# Set default host
echo 'export OLLAMA_HOST=localhost:11434' >> /etc/profile.d/ollama.sh

# Create service marker so entrypoint.sh starts Ollama
mkdir -p /etc/sandbox/services
touch /etc/sandbox/services/ollama

# No firewall domains needed — Ollama runs locally inside the container
# Model downloads happen before strict firewall is applied, or with firewall: open

echo "=== Ollama feature installed ==="
