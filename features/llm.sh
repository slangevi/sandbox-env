#!/bin/bash
# features/llm.sh — Install Simon Willison's llm CLI tool
set -euo pipefail

echo "=== Installing llm feature ==="

# Check Python is available (depends on python feature)
if ! command -v python3 &>/dev/null; then
    echo "ERROR: llm feature requires the python feature. Add 'python' before 'llm' in your sandbox.yaml features list."
    exit 1
fi

# Check pipx is available
if ! command -v pipx &>/dev/null; then
    echo "ERROR: pipx not found. The python feature should install it."
    exit 1
fi

# Install llm via pipx (as node user for correct PATH)
su - node -c "pipx install llm"

# Install plugins
su - node -c "pipx inject llm llm-claude-3"
su - node -c "pipx inject llm llm-ollama"

# No additional firewall domains — uses python's pypi.org (already in python.conf)

echo "=== llm feature installed ==="
