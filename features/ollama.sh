#!/bin/bash
# features/ollama.sh — Install Ollama server for local LLM inference
set -euo pipefail

echo "=== Installing Ollama feature ==="

# Ensure zstd is available (required by the Ollama installer)
apt-get update -qq && apt-get install -y --no-install-recommends zstd

# Install Ollama binary
curl -fsSL https://ollama.com/install.sh | sh

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
