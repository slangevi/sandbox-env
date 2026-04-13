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

    # ~/.local for tools that store data/binaries here (pipx, etc.)
    mkdir -p "$PERSISTENT/local"
    chown node:node "$PERSISTENT/local"
    ln -sfn "$PERSISTENT/local" /home/node/.local

    # npm global prefix — persists globally installed packages (MCP servers, etc.)
    mkdir -p "$PERSISTENT/npm-global"
    chown node:node "$PERSISTENT/npm-global"
    # Write env vars to a profile script so all shells pick them up
    cat > /etc/profile.d/sandbox-persistent.sh <<PROFILE
export NPM_CONFIG_PREFIX="$PERSISTENT/npm-global"
export PATH="$PERSISTENT/npm-global/bin:\$PATH"
PROFILE
fi

# Ensure cache dir ownership (volume may be fresh)
if [ -d /home/node/.cache ]; then
    chown node:node /home/node/.cache
fi

# Ensure ollama dir ownership (shared volume may be fresh)
if [ -d /home/node/.ollama ]; then
    chown node:node /home/node/.ollama
fi

# Apply git config from SANDBOX_GIT_* env vars (set by CLI from sandbox.yaml)
# Format: SANDBOX_GIT_<KEY>=<VALUE> where KEY uses __ for dots
# e.g. SANDBOX_GIT_USER__NAME="Your Name" -> git config --global user.name "Your Name"
while IFS='=' read -r var val; do
    [ -z "$var" ] && continue
    # Strip SANDBOX_GIT_ prefix, lowercase, replace __ with .
    local_key="${var#SANDBOX_GIT_}"
    local_key=$(echo "$local_key" | tr '[:upper:]' '[:lower:]' | sed 's/__/./g')
    gosu node git config --global "$local_key" "$val"
done < <(env | grep '^SANDBOX_GIT_' | sort)

# Drop privileges and execute the user's command as the node user
exec gosu node "$@"
