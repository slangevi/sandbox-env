#!/bin/bash
# tests/test-entrypoint.sh — Test entrypoint behavior inside containers
#
# Starts a container via the CLI, then verifies everything the entrypoint sets up:
# user identity, PATH, volumes, symlinks, permissions, git config, ollama, persistence.
#
# Because `docker exec` does not inherit the entrypoint's environment or run through
# the entrypoint, these tests use `docker exec -u node ... bash -lc '...'` to simulate
# a login shell as the node user — which sources /etc/profile.d/*.sh (where the
# entrypoint writes persistent PATH and env vars).
#
# Requires: Docker running, base image built, ~3-5 minutes (builds python+ollama+llm).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="$SCRIPT_DIR/cli/sandbox"
PASS=0
FAIL=0

check_output() {
    local desc="$1"
    local expected="$2"
    shift 2
    local output
    output=$("$@" 2>&1) || true
    if echo "$output" | grep -q "$expected"; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (expected '$expected')"
        echo "        got: $(echo "$output" | head -3)"
        FAIL=$((FAIL + 1))
    fi
}

check() {
    local desc="$1"
    shift
    if "$@" &>/dev/null 2>&1; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        FAIL=$((FAIL + 1))
    fi
}

check_fails() {
    local desc="$1"
    shift
    if "$@" &>/dev/null 2>&1; then
        echo "  FAIL: $desc (expected failure)"
        FAIL=$((FAIL + 1))
    else
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    fi
}

# Helper: exec as node user with login shell (simulates real tool usage)
exec_node() {
    local container="$1"
    shift
    docker exec -u node "$container" bash -lc "$*"
}

# Helper: exec as root (what `sandbox exec` actually does)
exec_root() {
    local container="$1"
    shift
    docker exec "$container" "$@"
}

# ── Setup ───────────────────────────────────────────────────────────
echo "=== Entrypoint Tests ==="

TEST_TMPDIR=$(mktemp -d)
CONTAINER_NAME="sandbox-entrypoint-test"
cleanup() {
    cd "$TEST_TMPDIR"
    "$SANDBOX" stop 2>/dev/null || true
    "$SANDBOX" clean 2>/dev/null || true
    rm -rf "$TEST_TMPDIR"
}
trap cleanup EXIT

cat > "$TEST_TMPDIR/sandbox.yaml" <<'EOF'
name: entrypoint-test
features:
  - python
  - ollama
  - llm
git:
  user.name: Test Author
  user.email: test@sandbox.dev
  init.defaultBranch: main
mounts:
  - host: .
    container: /workspace
firewall: open
EOF

cd "$TEST_TMPDIR"

echo "Building project image (python + ollama + llm)..."
"$SANDBOX" build 2>&1 | tail -3

echo "Starting container..."
"$SANDBOX" start 2>&1 | tail -2

# Give the entrypoint time to finish setup (ollama startup, symlinks, etc.)
sleep 5

# ── User identity ───────────────────────────────────────────────────
echo ""
echo "--- User identity ---"

# The entrypoint drops to node via gosu, so PID 1 runs as node.
# However, `docker exec` defaults to root (Dockerfile has no USER directive).
# Tests that need to verify node-user behavior explicitly use exec_node.
check_output "PID 1 runs as node" "node" \
    exec_root "$CONTAINER_NAME" bash -c 'ps -o user= -p 1 | tr -d " "'
check_output "exec as node: whoami" "node" \
    exec_node "$CONTAINER_NAME" whoami
check_output "exec as node: HOME is /home/node" "/home/node" \
    exec_node "$CONTAINER_NAME" 'echo $HOME'

# ── PATH checks ─────────────────────────────────────────────────────
echo ""
echo "--- PATH (login shell as node) ---"

# These are set by /etc/profile.d/sandbox-persistent.sh (written by entrypoint)
check_output "PATH includes ~/.local/bin" "/home/node/.local/bin" \
    exec_node "$CONTAINER_NAME" 'echo $PATH'
check_output "PATH includes npm-global/bin" "npm-global/bin" \
    exec_node "$CONTAINER_NAME" 'echo $PATH'

# Also verify PATH works via the CLI's exec (which runs as root but bash -lc sources profile.d)
check_output "CLI exec PATH includes .local/bin" "/home/node/.local/bin" \
    "$SANDBOX" exec bash -lc 'echo $PATH'

# ── Tool availability ───────────────────────────────────────────────
echo ""
echo "--- Tools on PATH ---"

# llm is installed via pipx into ~/.local/bin — requires PATH to include it.
# This would have caught the "llm command not found" bug.
check "llm is on PATH (node login)" \
    exec_node "$CONTAINER_NAME" 'which llm'
check "pipx is on PATH" \
    exec_node "$CONTAINER_NAME" 'which pipx'
check "pip is on PATH" \
    exec_root "$CONTAINER_NAME" which pip
check "python is on PATH" \
    exec_root "$CONTAINER_NAME" which python

# ── Git config ──────────────────────────────────────────────────────
echo ""
echo "--- Git config ---"

# Git config is written to node user's ~/.gitconfig (via gosu node git config --global)
check_output "user.name applied (node)" "Test Author" \
    exec_node "$CONTAINER_NAME" 'git config --global user.name'
check_output "user.email applied (node)" "test@sandbox.dev" \
    exec_node "$CONTAINER_NAME" 'git config --global user.email'
check_output "init.defaultBranch applied (node)" "main" \
    exec_node "$CONTAINER_NAME" 'git config --global init.defaultBranch'

# ── Git config persistence across restarts ──────────────────────────
echo ""
echo "--- Git config persistence ---"

exec_node "$CONTAINER_NAME" 'git config --global push.default simple' 2>/dev/null
"$SANDBOX" stop 2>/dev/null
"$SANDBOX" start 2>/dev/null
sleep 5
check_output "git config persists across restart" "simple" \
    exec_node "$CONTAINER_NAME" 'git config --global push.default'

# ── Dangerous git keys blocked ──────────────────────────────────────
echo ""
echo "--- Dangerous git keys ---"
# core.fsmonitor should NOT be set — the entrypoint whitelist blocks it
check_fails "core.fsmonitor not set" \
    exec_node "$CONTAINER_NAME" 'git config --global core.fsmonitor'

# ── Volume permissions ──────────────────────────────────────────────
echo ""
echo "--- Volume permissions ---"

# These directories are Docker volumes. The entrypoint chowns them to node.
# This would have caught ".claude volume owned by root" bug.
check "~/.claude writable by node" \
    exec_node "$CONTAINER_NAME" 'touch /home/node/.claude/test-write'
check "~/.cache writable by node" \
    exec_node "$CONTAINER_NAME" 'touch /home/node/.cache/test-write'
check "~/.persistent writable by node" \
    exec_node "$CONTAINER_NAME" 'touch /home/node/.persistent/test-write'

# Verify ownership is node:node
check_output "~/.claude owned by node" "node" \
    exec_root "$CONTAINER_NAME" bash -c 'stat -c %U /home/node/.claude'
check_output "~/.cache owned by node" "node" \
    exec_root "$CONTAINER_NAME" bash -c 'stat -c %U /home/node/.cache'
check_output "~/.persistent owned by node" "node" \
    exec_root "$CONTAINER_NAME" bash -c 'stat -c %U /home/node/.persistent'

# ── Symlinks ────────────────────────────────────────────────────────
echo ""
echo "--- Symlinks ---"

# .claude.json should be symlinked into the .claude volume for persistence
# This would have caught ".claude.json not persisted across restarts" bug.
check_output ".claude.json symlinked to volume" "/home/node/.claude/.claude.json" \
    exec_root "$CONTAINER_NAME" readlink /home/node/.claude.json

check_output ".zsh_history symlinked to persistent" ".persistent" \
    exec_root "$CONTAINER_NAME" readlink /home/node/.zsh_history

check_output ".gitconfig symlinked to persistent" ".persistent" \
    exec_root "$CONTAINER_NAME" readlink /home/node/.gitconfig

check_output ".config symlinked to persistent/config" "/home/node/.persistent/config" \
    exec_root "$CONTAINER_NAME" readlink /home/node/.config

check_output ".local symlinked to persistent/local" "/home/node/.persistent/local" \
    exec_root "$CONTAINER_NAME" readlink /home/node/.local

# ── Ollama ──────────────────────────────────────────────────────────
echo ""
echo "--- Ollama ---"

# Ollama server should be running (started by entrypoint because marker file exists)
check "Ollama server is running" \
    exec_root "$CONTAINER_NAME" curl -sf http://localhost:11434/api/tags

# OLLAMA_MODELS is only exported within the entrypoint process (for the server).
# It is NOT available to `docker exec` (which starts a fresh process).
# The ollama feature writes OLLAMA_HOST to /etc/profile.d/ollama.sh, but does NOT
# write OLLAMA_MODELS there. Verify the server itself has the right models path.
check_output "OLLAMA_HOST set via profile.d" "localhost:11434" \
    exec_node "$CONTAINER_NAME" 'echo $OLLAMA_HOST'

# Verify the ollama models directory exists and is owned by node
check_output "ollama models dir owned by node" "node" \
    exec_root "$CONTAINER_NAME" bash -c 'stat -c %U /home/node/.ollama'

# ── NPM global prefix ──────────────────────────────────────────────
echo ""
echo "--- NPM global prefix ---"

check_output "NPM_CONFIG_PREFIX set" ".persistent/npm-global" \
    exec_node "$CONTAINER_NAME" 'echo $NPM_CONFIG_PREFIX'

# ── npm global install persistence ──────────────────────────────────
echo ""
echo "--- npm global install persistence ---"

exec_node "$CONTAINER_NAME" 'npm install -g is-odd@3.0.1' 2>/dev/null
check "npm global package installed" \
    exec_node "$CONTAINER_NAME" 'npm list -g is-odd 2>/dev/null | grep -q is-odd'

# Stop and start to test persistence
"$SANDBOX" stop 2>/dev/null
"$SANDBOX" start 2>/dev/null
sleep 5
check "npm global package persists across restart" \
    exec_node "$CONTAINER_NAME" 'npm list -g is-odd 2>/dev/null | grep -q is-odd'

# ── zshrc sources profile.d ─────────────────────────────────────────
echo ""
echo "--- zshrc profile.d sourcing ---"
# zsh -lc is a non-interactive login shell and does NOT source .zshrc (zsh behavior).
# zsh -ilc is an interactive login shell and DOES source .zshrc.
# The container's default shell is zsh (interactive), so users get the PATH via .zshrc.
check_output "zsh interactive login has .local/bin in PATH" "/home/node/.local/bin" \
    docker exec -u node "$CONTAINER_NAME" zsh -ilc 'echo $PATH'

# ── Summary ─────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
