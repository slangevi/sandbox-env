#!/bin/bash
set -euo pipefail

# This script runs as root. It initializes services, then drops to the node user.

# Apply firewall if strict mode is requested
if [ "${SANDBOX_FIREWALL:-open}" = "strict" ]; then
    echo "Initializing strict firewall..."
    /usr/local/bin/init-firewall.sh
fi

# Start Ollama if installed and the marker file exists
if [ -f /etc/sandbox/services/ollama ]; then
    echo "Starting Ollama server..."
    ollama serve &>/tmp/ollama.log &
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

# Drop privileges and execute the user's command as the node user
exec gosu node "$@"
