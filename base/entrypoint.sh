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

# Set up persistent home volume symlinks
# The volume at /home/node/.persistent survives container restarts.
# We symlink dotfiles into it so history, git config, etc. persist.
PERSISTENT="/home/node/.persistent"
if [ -d "$PERSISTENT" ]; then
    # Ensure ownership (volume may be fresh)
    chown node:node "$PERSISTENT"

    # Shell history
    mkdir -p "$PERSISTENT/zsh"
    chown node:node "$PERSISTENT/zsh"
    ln -sf "$PERSISTENT/zsh/.zsh_history" /home/node/.zsh_history

    # Git config — always symlink so git config --global writes persist
    if [ ! -f "$PERSISTENT/.gitconfig" ]; then
        # Preserve any existing gitconfig from the image, or create empty
        if [ -f /home/node/.gitconfig ]; then
            cp /home/node/.gitconfig "$PERSISTENT/.gitconfig"
        else
            touch "$PERSISTENT/.gitconfig"
        fi
    fi
    chown node:node "$PERSISTENT/.gitconfig"
    ln -sf "$PERSISTENT/.gitconfig" /home/node/.gitconfig

    # General config directory (for tools that use ~/.config)
    mkdir -p "$PERSISTENT/config"
    chown node:node "$PERSISTENT/config"
    # Only link if ~/.config doesn't already have content from features
    if [ ! -d /home/node/.config ] || [ -z "$(ls -A /home/node/.config 2>/dev/null)" ]; then
        ln -sfn "$PERSISTENT/config" /home/node/.config
    fi
fi

# Ensure cache dir ownership (volume may be fresh)
if [ -d /home/node/.cache ]; then
    chown node:node /home/node/.cache
fi

# Ensure ollama dir ownership (shared volume may be fresh)
if [ -d /home/node/.ollama ]; then
    chown node:node /home/node/.ollama
fi

# Drop privileges and execute the user's command as the node user
exec gosu node "$@"
