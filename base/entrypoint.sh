#!/bin/bash
set -euo pipefail

# Apply firewall if strict mode is requested via env var
if [ "${SANDBOX_FIREWALL:-open}" = "strict" ]; then
    echo "Initializing strict firewall..."
    sudo /usr/local/bin/init-firewall.sh
fi

# Start Ollama if installed and the marker file exists
if [ -f /etc/sandbox/services/ollama ]; then
    echo "Starting Ollama server..."
    ollama serve &>/tmp/ollama.log &
    # Wait briefly for Ollama to be ready
    for i in $(seq 1 10); do
        if curl -sf http://localhost:11434/api/tags &>/dev/null; then
            echo "Ollama ready."
            break
        fi
        sleep 1
    done
    if ! curl -sf http://localhost:11434/api/tags &>/dev/null; then
        echo "WARNING: Ollama did not become ready within 10 seconds. Check /tmp/ollama.log"
    fi
fi

# Execute the provided command (zsh for interactive, claude for headless)
exec "$@"
