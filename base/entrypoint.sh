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
    OLLAMA_MODELS=/home/node/.ollama/models ollama serve &>/tmp/ollama.log &
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
    # Merge: copy feature-installed config into persistent volume (without overwriting existing)
    if [ -d /home/node/.config ] && [ -n "$(ls -A /home/node/.config 2>/dev/null)" ]; then
        cp -rn /home/node/.config/. "$PERSISTENT/config/" 2>/dev/null || true
    fi
    # Remove the original and symlink to persistent volume
    rm -rf /home/node/.config
    ln -sfn "$PERSISTENT/config" /home/node/.config

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

# Ensure volume ownership (volumes may be fresh, owned by root)
if [ -d /home/node/.claude ]; then
    chown node:node /home/node/.claude

    # Claude Code stores .claude.json in the home dir (not inside .claude/).
    # With --rm containers, it gets lost each restart. Symlink it into the
    # volume so it persists, and restore from backup if needed.
    if [ ! -f /home/node/.claude/.claude.json ] && [ -d /home/node/.claude/backups ]; then
        # Restore from most recent backup
        local_backup=$(ls -t /home/node/.claude/backups/.claude.json.backup.* 2>/dev/null | head -1)
        if [ -n "$local_backup" ]; then
            cp "$local_backup" /home/node/.claude/.claude.json
            chown node:node /home/node/.claude/.claude.json
        fi
    fi
    # Symlink so Claude Code reads/writes through the volume
    ln -sf /home/node/.claude/.claude.json /home/node/.claude.json
    chown -h node:node /home/node/.claude.json
fi
if [ -d /home/node/.cache ]; then
    chown node:node /home/node/.cache
fi

# Ensure ollama dir ownership (shared volume may be fresh)
if [ -d /home/node/.ollama ]; then
    chown node:node /home/node/.ollama
fi

# Apply git config from SANDBOX_GIT_* env vars (set by CLI from sandbox.yaml)
while IFS='=' read -r var val; do
    [ -z "$var" ] && continue
    local_key="${var#SANDBOX_GIT_}"
    local_key=$(echo "$local_key" | tr '[:upper:]' '[:lower:]' | sed 's/__/./g')
    # Whitelist safe keys — defense in depth (CLI also whitelists)
    # Keys are lowercased by the tr above, so match lowercase here
    case "$local_key" in
        user.name|user.email|init.defaultbranch|core.autocrlf|core.eol|push.default|pull.rebase|commit.gpgsign|tag.gpgsign|merge.ff)
            gosu node git config --global "$local_key" "$val"
            ;;
        *)
            echo "WARNING: Blocked git config key '$local_key' in entrypoint"
            ;;
    esac
done < <(env | grep '^SANDBOX_GIT_' | sort)

# Drop privileges and execute the user's command as the node user
exec gosu node "$@"
