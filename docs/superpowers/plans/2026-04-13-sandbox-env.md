# Sandbox Environment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a reusable Docker sandbox for running Claude Code in isolated, per-project customizable containers.

**Architecture:** Two-stage Docker build (base image + project layer) orchestrated by a `sandbox` bash CLI. Feature scripts provide composable language/tool installs. Configurable iptables firewall for strict network isolation.

**Tech Stack:** Docker, bash, iptables/ipset, YAML (parsed with `yq` in the CLI)

**Spec:** `docs/superpowers/specs/2026-04-13-sandbox-env-design.md`

---

## File Structure

```
sandbox-env/
├── base/
│   ├── Dockerfile              # Base image: node:20-slim + Claude Code + core tools
│   ├── entrypoint.sh           # Container startup: firewall, services, shell/headless
│   ├── init-firewall.sh        # iptables strict-mode setup
│   └── firewall-domains.conf   # Base domain whitelist (one domain per line)
├── features/
│   ├── python.sh               # Python 3.12 + pip + venv + pipx
│   ├── node-extra.sh           # pnpm, yarn, tsx, npm-check-updates
│   ├── rust.sh                 # Rust via rustup + cargo tools
│   ├── go.sh                   # Go 1.22 + golangci-lint
│   ├── aws.sh                  # AWS CLI v2
│   ├── gcloud.sh               # Google Cloud SDK
│   ├── ollama.sh               # Ollama server binary
│   └── llm.sh                  # Simon Willison's llm CLI + plugins
├── cli/
│   └── sandbox                 # Main CLI script (bash, ~300 lines)
├── templates/
│   └── Dockerfile.project.tmpl # Template for per-project Dockerfiles
├── tests/
│   ├── test-base.sh            # Verify base image tools and user config
│   ├── test-feature.sh         # Generic feature test harness
│   ├── test-firewall.sh        # Verify strict mode blocks/allows correctly
│   ├── test-cli.sh             # Verify CLI commands parse config and run
│   └── fixtures/
│       └── sandbox.yaml        # Test fixture config
└── .gitignore
```

---

### Task 1: Base Dockerfile and Entrypoint

**Files:**
- Create: `base/Dockerfile`
- Create: `base/entrypoint.sh`
- Create: `.gitignore`

- [ ] **Step 1: Create `.gitignore`**

```gitignore
.superpowers/
*.tmp
.DS_Store
```

- [ ] **Step 2: Write the base Dockerfile**

```dockerfile
FROM node:20-slim

ARG CLAUDE_CODE_VERSION=latest
ARG DEBIAN_FRONTEND=noninteractive
ARG TZ=UTC

# Core system packages
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    wget \
    unzip \
    less \
    sudo \
    fzf \
    zsh \
    man-db \
    procps \
    gnupg2 \
    jq \
    nano \
    vim \
    iproute2 \
    dnsutils \
    iptables \
    ipset \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# aggregate tool for CIDR aggregation (used by firewall)
RUN apt-get update && apt-get install -y --no-install-recommends aggregate \
    && rm -rf /var/lib/apt/lists/* \
    || echo "aggregate not available, skipping"

# GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && apt-get update && apt-get install -y gh \
    && rm -rf /var/lib/apt/lists/*

# git-delta for better diffs
RUN ARCH=$(dpkg --print-architecture) && \
    if [ "$ARCH" = "amd64" ]; then DELTA_ARCH="x86_64"; else DELTA_ARCH="aarch64"; fi && \
    curl -fsSL "https://github.com/dandavison/delta/releases/download/0.18.2/delta-0.18.2-${DELTA_ARCH}-unknown-linux-gnu.tar.gz" \
    | tar xz -C /tmp && \
    mv /tmp/delta-*/delta /usr/local/bin/ && \
    rm -rf /tmp/delta-*

# Claude Code CLI
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

# Configure non-root user (node user already exists in node image)
RUN echo "node ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/node \
    && chmod 0440 /etc/sudoers.d/node

# Create directories
RUN mkdir -p /workspace /etc/sandbox/firewall.d /commandhistory \
    && chown node:node /workspace /commandhistory

# Zsh setup with basic productivity config
RUN chsh -s /bin/zsh node
COPY --chown=node:node base/zshrc /home/node/.zshrc

# Firewall and entrypoint scripts
COPY base/firewall-domains.conf /etc/sandbox/firewall-domains.conf
COPY base/init-firewall.sh /usr/local/bin/init-firewall.sh
RUN chmod +x /usr/local/bin/init-firewall.sh
COPY base/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Environment
ENV DEVCONTAINER=true \
    SHELL=/bin/zsh \
    EDITOR=nano \
    VISUAL=nano

USER node
WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/bin/zsh"]
```

- [ ] **Step 3: Write the entrypoint script**

```bash
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
fi

# Execute the provided command (zsh for interactive, claude for headless)
exec "$@"
```

- [ ] **Step 4: Create a minimal zshrc**

```zsh
# sandbox zsh config
export HISTFILE=/commandhistory/.zsh_history
export HISTSIZE=10000
export SAVEHIST=10000
setopt SHARE_HISTORY
setopt HIST_IGNORE_DUPS

# fzf keybindings
[ -f /usr/share/doc/fzf/examples/key-bindings.zsh ] && source /usr/share/doc/fzf/examples/key-bindings.zsh
[ -f /usr/share/doc/fzf/examples/completion.zsh ] && source /usr/share/doc/fzf/examples/completion.zsh

# git-delta config
export GIT_PAGER="delta --dark"

# prompt
PROMPT='%F{cyan}sandbox%f:%F{yellow}%~%f %# '
```

- [ ] **Step 5: Build the base image and verify it starts**

Run:
```bash
docker build -f base/Dockerfile -t sandbox-base:latest .
docker run --rm sandbox-base:latest echo "hello from sandbox"
```
Expected: Image builds successfully. Container prints "hello from sandbox" and exits.

- [ ] **Step 6: Commit**

```bash
git add base/Dockerfile base/entrypoint.sh base/zshrc .gitignore
git commit -m "feat: add base Dockerfile and entrypoint"
```

---

### Task 2: Firewall Scripts

**Files:**
- Create: `base/firewall-domains.conf`
- Create: `base/init-firewall.sh`

- [ ] **Step 1: Write the base domain whitelist**

```conf
# base/firewall-domains.conf
# Base domains always allowed in strict firewall mode.
# One domain per line. Lines starting with # are comments.

# Claude Code
api.anthropic.com
statsig.anthropic.com
statsig.com
sentry.io

# npm registry
registry.npmjs.org

# GitHub (IPs resolved dynamically via /meta API)
# github.com and api.github.com are handled specially in init-firewall.sh

# GitLab
gitlab.com
registry.gitlab.com
```

- [ ] **Step 2: Write the firewall init script**

```bash
#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

echo "=== Sandbox Firewall Init (strict mode) ==="

# 1. Preserve Docker DNS rules
DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)

# 2. Flush existing rules
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true

# 3. Restore Docker DNS
if [ -n "$DOCKER_DNS_RULES" ]; then
    echo "Restoring Docker DNS rules..."
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
else
    echo "No Docker DNS rules to restore."
fi

# 4. Allow DNS, SSH, localhost
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A INPUT -p udp --sport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -p tcp --sport 22 -m state --state ESTABLISHED -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# 5. Create ipset
ipset create allowed-domains hash:net

# 6. GitHub IPs via /meta API
echo "Fetching GitHub IP ranges..."
gh_ranges=$(curl -sf https://api.github.com/meta)
if [ -n "$gh_ranges" ] && echo "$gh_ranges" | jq -e '.web and .api and .git' >/dev/null 2>&1; then
    while read -r cidr; do
        ipset add allowed-domains "$cidr" 2>/dev/null || true
    done < <(echo "$gh_ranges" | jq -r '(.web + .api + .git)[]' | aggregate -q 2>/dev/null || echo "$gh_ranges" | jq -r '(.web + .api + .git)[]')
    echo "GitHub IPs added."
else
    echo "WARNING: Could not fetch GitHub IPs. GitHub access may not work."
fi

# 7. Resolve domains from base config + feature configs + project domains
collect_domains() {
    # Base domains
    if [ -f /etc/sandbox/firewall-domains.conf ]; then
        grep -v '^#' /etc/sandbox/firewall-domains.conf | grep -v '^$'
    fi
    # Feature domains
    if [ -d /etc/sandbox/firewall.d ]; then
        for conf in /etc/sandbox/firewall.d/*.conf; do
            [ -f "$conf" ] && grep -v '^#' "$conf" | grep -v '^$'
        done
    fi
    # Project domains (passed via env var as comma-separated list)
    if [ -n "${SANDBOX_ALLOWED_DOMAINS:-}" ]; then
        echo "$SANDBOX_ALLOWED_DOMAINS" | tr ',' '\n'
    fi
}

while read -r domain; do
    [ -z "$domain" ] && continue
    echo "Resolving $domain..."
    ips=$(dig +noall +answer A "$domain" 2>/dev/null | awk '$4 == "A" {print $5}')
    if [ -z "$ips" ]; then
        echo "WARNING: Could not resolve $domain"
        continue
    fi
    while read -r ip; do
        ipset add allowed-domains "$ip" 2>/dev/null || true
    done <<< "$ips"
done < <(collect_domains | sort -u)

# 8. Allow host network (for Docker host communication)
HOST_IP=$(ip route | grep default | cut -d" " -f3)
if [ -n "$HOST_IP" ]; then
    HOST_NETWORK=$(echo "$HOST_IP" | sed "s/\.[0-9]*$/.0\/24/")
    echo "Allowing host network: $HOST_NETWORK"
    iptables -A INPUT -s "$HOST_NETWORK" -j ACCEPT
    iptables -A OUTPUT -d "$HOST_NETWORK" -j ACCEPT
fi

# 9. Set default policies
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# 10. Allow established + ipset destinations
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT

# 11. Reject everything else with immediate feedback
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

# 12. Verify
echo "Verifying firewall..."
if curl --connect-timeout 5 -sf https://example.com >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed — reached example.com"
    exit 1
fi
echo "Firewall active. Blocked domains are unreachable."
```

- [ ] **Step 3: Rebuild base image (now includes firewall scripts)**

Run:
```bash
docker build -f base/Dockerfile -t sandbox-base:latest .
```
Expected: Builds successfully.

- [ ] **Step 4: Test firewall in strict mode**

Run:
```bash
docker run --rm --cap-add NET_ADMIN --cap-add NET_RAW \
    -e SANDBOX_FIREWALL=strict \
    sandbox-base:latest \
    bash -c "curl --connect-timeout 5 -sf https://example.com && echo 'FAIL: reached example.com' || echo 'PASS: example.com blocked'"
```
Expected: Prints "PASS: example.com blocked"

- [ ] **Step 5: Commit**

```bash
git add base/firewall-domains.conf base/init-firewall.sh
git commit -m "feat: add firewall scripts with strict mode domain whitelist"
```

---

### Task 3: Project Dockerfile Template

**Files:**
- Create: `templates/Dockerfile.project.tmpl`

This is the template that the CLI uses to generate per-project Dockerfiles.

- [ ] **Step 1: Write the template**

The template uses simple `%%PLACEHOLDER%%` markers that the CLI replaces with generated content.

```dockerfile
# Auto-generated by sandbox CLI — do not edit manually
FROM sandbox-base:latest

USER root

# Feature scripts
%%FEATURES%%

# Additional apt packages
%%PACKAGES%%

# Custom setup script
%%SETUP%%

# Create firewall.d directory marker for features
RUN mkdir -p /etc/sandbox/firewall.d /etc/sandbox/services

USER node
WORKDIR /workspace
```

- [ ] **Step 2: Commit**

```bash
git add templates/Dockerfile.project.tmpl
git commit -m "feat: add project Dockerfile template"
```

---

### Task 4: CLI — Core and `build-base` Command

**Files:**
- Create: `cli/sandbox`

The CLI is a bash script. We build it incrementally — this task covers the scaffold, YAML parsing helper, and `build-base`.

- [ ] **Step 1: Write the CLI scaffold with `build-base`**

```bash
#!/bin/bash
set -euo pipefail

# Resolve the sandbox-env repo root (where this script lives)
SANDBOX_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()   { echo -e "${GREEN}[sandbox]${NC} $*"; }
warn()  { echo -e "${YELLOW}[sandbox]${NC} $*"; }
error() { echo -e "${RED}[sandbox]${NC} $*" >&2; }

# Check for required tools
require_tool() {
    if ! command -v "$1" &>/dev/null; then
        error "Required tool '$1' not found. Please install it."
        exit 1
    fi
}

require_tool docker
require_tool yq

# ── YAML config helpers ──────────────────────────────────────────────

CONFIG_FILE=""

find_config() {
    if [ -f "${1:-sandbox.yaml}" ]; then
        CONFIG_FILE="${1:-sandbox.yaml}"
    elif [ -f "sandbox.yml" ]; then
        CONFIG_FILE="sandbox.yml"
    else
        error "No sandbox.yaml found in current directory."
        exit 1
    fi
}

config_get() {
    yq -r "$1 // empty" "$CONFIG_FILE"
}

config_get_default() {
    local query="$1"
    local default="$2"
    local val
    val=$(yq -r "$query // empty" "$CONFIG_FILE")
    echo "${val:-$default}"
}

project_name() {
    config_get '.name'
}

# ── Commands ─────────────────────────────────────────────────────────

cmd_build_base() {
    log "Building base image..."
    docker build \
        -f "$SANDBOX_ROOT/base/Dockerfile" \
        -t sandbox-base:latest \
        "$SANDBOX_ROOT"
    log "Base image built: sandbox-base:latest"
}

cmd_help() {
    cat <<'USAGE'
Usage: sandbox <command> [options]

Commands:
  build-base          Build the base sandbox image
  build               Build project image from sandbox.yaml
  run [--headless]    Run the sandbox container
  shell               Open a shell in the running sandbox
  stop                Stop the running sandbox
  clean               Remove the project image
  init                Generate a starter sandbox.yaml

Options:
  -h, --help          Show this help message
USAGE
}

# ── Main ─────────────────────────────────────────────────────────────

case "${1:-help}" in
    build-base)   cmd_build_base ;;
    help|-h|--help) cmd_help ;;
    *)
        error "Unknown command: $1"
        cmd_help
        exit 1
        ;;
esac
```

- [ ] **Step 2: Make it executable and test help output**

Run:
```bash
chmod +x cli/sandbox
cli/sandbox help
```
Expected: Prints the usage message listing all commands.

- [ ] **Step 3: Test `build-base` builds the image**

Run:
```bash
cli/sandbox build-base
docker images sandbox-base:latest --format '{{.Repository}}:{{.Tag}}'
```
Expected: Prints `sandbox-base:latest`

- [ ] **Step 4: Commit**

```bash
git add cli/sandbox
git commit -m "feat: add sandbox CLI scaffold with build-base command"
```

---

### Task 5: CLI — `build` Command

**Files:**
- Modify: `cli/sandbox`

- [ ] **Step 1: Add the `build` command to the CLI**

Add this function before `cmd_help`:

```bash
cmd_build() {
    find_config
    local name
    name=$(project_name)
    if [ -z "$name" ]; then
        error "sandbox.yaml must have a 'name' field."
        exit 1
    fi

    log "Building project image: sandbox-${name}:latest"

    # Generate Dockerfile from template
    local tmpdir
    tmpdir=$(mktemp -d)
    trap "rm -rf $tmpdir" EXIT

    local dockerfile="$tmpdir/Dockerfile"
    local features_block=""
    local packages_block=""
    local setup_block=""

    # Features
    while IFS= read -r feature; do
        [ -z "$feature" ] && continue
        local script="$SANDBOX_ROOT/features/${feature}.sh"
        if [ ! -f "$script" ]; then
            error "Feature script not found: $script"
            exit 1
        fi
        cp "$script" "$tmpdir/${feature}.sh"
        features_block="${features_block}COPY ${feature}.sh /tmp/${feature}.sh
RUN chmod +x /tmp/${feature}.sh && /tmp/${feature}.sh && rm /tmp/${feature}.sh
"
    done < <(config_get '.features[]')

    # Packages
    local packages=""
    while IFS= read -r pkg; do
        [ -z "$pkg" ] && continue
        packages="${packages} ${pkg}"
    done < <(config_get '.packages[]')
    if [ -n "$packages" ]; then
        packages_block="RUN apt-get update && apt-get install -y --no-install-recommends${packages} && rm -rf /var/lib/apt/lists/*"
    fi

    # Custom setup script
    local setup_path
    setup_path=$(config_get '.setup')
    if [ -n "$setup_path" ]; then
        if [ ! -f "$setup_path" ]; then
            error "Setup script not found: $setup_path"
            exit 1
        fi
        cp "$setup_path" "$tmpdir/custom-setup.sh"
        setup_block="COPY custom-setup.sh /tmp/custom-setup.sh
RUN chmod +x /tmp/custom-setup.sh && /tmp/custom-setup.sh && rm /tmp/custom-setup.sh"
    fi

    # Generate Dockerfile from template
    sed \
        -e "s|%%FEATURES%%|${features_block}|" \
        -e "s|%%PACKAGES%%|${packages_block}|" \
        -e "s|%%SETUP%%|${setup_block}|" \
        "$SANDBOX_ROOT/templates/Dockerfile.project.tmpl" > "$dockerfile"

    # Build
    docker build \
        -f "$dockerfile" \
        -t "sandbox-${name}:latest" \
        "$tmpdir"

    log "Project image built: sandbox-${name}:latest"
}
```

Update the case statement to include the new command:

```bash
case "${1:-help}" in
    build-base)   cmd_build_base ;;
    build)        cmd_build ;;
    help|-h|--help) cmd_help ;;
    *)
        error "Unknown command: $1"
        cmd_help
        exit 1
        ;;
esac
```

- [ ] **Step 2: Create a test fixture sandbox.yaml**

Create `tests/fixtures/sandbox.yaml`:

```yaml
name: test-project
features: []
packages:
  - tree
```

- [ ] **Step 3: Test `build` with the fixture**

Run:
```bash
cd tests/fixtures && ../../cli/sandbox build
docker images sandbox-test-project:latest --format '{{.Repository}}:{{.Tag}}'
```
Expected: Prints `sandbox-test-project:latest`

- [ ] **Step 4: Clean up test image and commit**

Run:
```bash
docker rmi sandbox-test-project:latest
```

```bash
git add cli/sandbox tests/fixtures/sandbox.yaml
git commit -m "feat: add sandbox build command with YAML-driven Dockerfile generation"
```

---

### Task 6: CLI — `run` Command

**Files:**
- Modify: `cli/sandbox`

- [ ] **Step 1: Add the `run` command**

Add this function before `cmd_help`:

```bash
cmd_run() {
    find_config
    local name
    name=$(project_name)

    # Check image exists
    if ! docker image inspect "sandbox-${name}:latest" &>/dev/null; then
        error "Project image not found. Run 'sandbox build' first."
        exit 1
    fi

    # Parse --headless flag
    local mode
    mode=$(config_get_default '.claude.mode' 'interactive')
    local claude_args=()
    local passthrough_args=()
    local parsing_passthrough=false

    shift # remove 'run' from args
    while [ $# -gt 0 ]; do
        if [ "$1" = "--" ]; then
            parsing_passthrough=true
            shift
            continue
        fi
        if $parsing_passthrough; then
            passthrough_args+=("$1")
        elif [ "$1" = "--headless" ]; then
            mode="headless"
        fi
        shift
    done

    # Build docker run args
    local docker_args=(
        "--name" "sandbox-${name}"
        "--rm"
        "--hostname" "sandbox"
    )

    # Mounts: always mount ~/.claude for auth
    docker_args+=("-v" "${HOME}/.claude:/home/node/.claude")

    # Mounts from config (default: current dir -> /workspace)
    local has_mounts=false
    while IFS= read -r mount_line; do
        [ -z "$mount_line" ] && continue
        has_mounts=true
        local host_path container_path readonly_flag
        host_path=$(echo "$mount_line" | yq -r '.host')
        container_path=$(echo "$mount_line" | yq -r '.container')
        readonly_flag=$(echo "$mount_line" | yq -r '.readonly // false')

        # Expand ~ in host path
        host_path="${host_path/#\~/$HOME}"
        # Resolve relative paths
        if [[ "$host_path" == .* ]]; then
            host_path="$(cd "$(dirname "$CONFIG_FILE")" && cd "$(dirname "$host_path")" && pwd)/$(basename "$host_path")"
        fi

        local mount_spec="${host_path}:${container_path}"
        if [ "$readonly_flag" = "true" ]; then
            mount_spec="${mount_spec}:ro"
        fi
        docker_args+=("-v" "$mount_spec")
    done < <(config_get '.mounts[]' | yq -c '.')

    # Default mount if none specified
    if ! $has_mounts; then
        docker_args+=("-v" "$(pwd):/workspace")
    fi

    # Environment variables
    while IFS= read -r key; do
        [ -z "$key" ] && continue
        local val
        val=$(config_get ".env.${key}")
        docker_args+=("-e" "${key}=${val}")
    done < <(config_get '.env | keys[]')

    # Firewall mode
    local firewall
    firewall=$(config_get_default '.firewall' 'open')
    docker_args+=("-e" "SANDBOX_FIREWALL=${firewall}")

    if [ "$firewall" = "strict" ]; then
        docker_args+=("--cap-add" "NET_ADMIN" "--cap-add" "NET_RAW")

        # Pass allowed_domains as comma-separated env var
        local domains=""
        while IFS= read -r domain; do
            [ -z "$domain" ] && continue
            domains="${domains:+${domains},}${domain}"
        done < <(config_get '.allowed_domains[]')
        if [ -n "$domains" ]; then
            docker_args+=("-e" "SANDBOX_ALLOWED_DOMAINS=${domains}")
        fi
    fi

    # Run
    if [ "$mode" = "headless" ]; then
        log "Running sandbox-${name} in headless mode..."
        docker run "${docker_args[@]}" \
            "sandbox-${name}:latest" \
            claude -p "${passthrough_args[*]:-}"
    else
        log "Running sandbox-${name} interactively..."
        docker run -it "${docker_args[@]}" \
            "sandbox-${name}:latest"
    fi
}
```

Update the case statement:

```bash
case "${1:-help}" in
    build-base)   cmd_build_base ;;
    build)        cmd_build ;;
    run)          cmd_run "$@" ;;
    help|-h|--help) cmd_help ;;
    *)
        error "Unknown command: $1"
        cmd_help
        exit 1
        ;;
esac
```

- [ ] **Step 2: Test `run` starts and exits cleanly**

Run:
```bash
cd tests/fixtures && ../../cli/sandbox build
cd tests/fixtures && ../../cli/sandbox run -- echo "sandbox running"
```
Expected: Prints "sandbox running" and exits. (The entrypoint passes through to `exec "$@"` which runs echo.)

Note: This won't drop into zsh because we're passing a command. Interactive mode (no args after `--`) would open zsh.

- [ ] **Step 3: Commit**

```bash
git add cli/sandbox
git commit -m "feat: add sandbox run command with mounts, env, and firewall config"
```

---

### Task 7: CLI — `shell`, `stop`, `clean`, `init` Commands

**Files:**
- Modify: `cli/sandbox`

- [ ] **Step 1: Add remaining commands**

Add these functions before `cmd_help`:

```bash
cmd_shell() {
    find_config
    local name
    name=$(project_name)
    log "Opening shell in sandbox-${name}..."
    docker exec -it "sandbox-${name}" /bin/zsh
}

cmd_stop() {
    find_config
    local name
    name=$(project_name)
    log "Stopping sandbox-${name}..."
    docker stop "sandbox-${name}" 2>/dev/null || true
    log "Stopped."
}

cmd_clean() {
    find_config
    local name
    name=$(project_name)
    log "Removing image sandbox-${name}:latest..."
    docker rmi "sandbox-${name}:latest" 2>/dev/null || true
    log "Cleaned."
}

cmd_init() {
    if [ -f sandbox.yaml ] || [ -f sandbox.yml ]; then
        error "sandbox.yaml already exists in this directory."
        exit 1
    fi

    local name
    name=$(basename "$(pwd)")

    cat > sandbox.yaml <<YAML
name: ${name}

features: []
  # - python
  # - node-extra
  # - rust
  # - go
  # - aws
  # - gcloud
  # - ollama
  # - llm

packages: []
  # - ripgrep
  # - tree

env: {}

mounts:
  - host: .
    container: /workspace

firewall: open
# allowed_domains:
#   - api.example.com

# setup: ./scripts/custom-setup.sh

claude:
  mode: interactive
  args: []
YAML

    log "Created sandbox.yaml for '${name}'"
    log "Edit it to add features and packages, then run: sandbox build"
}
```

Update the case statement:

```bash
case "${1:-help}" in
    build-base)     cmd_build_base ;;
    build)          cmd_build ;;
    run)            cmd_run "$@" ;;
    shell)          cmd_shell ;;
    stop)           cmd_stop ;;
    clean)          cmd_clean ;;
    init)           cmd_init ;;
    help|-h|--help) cmd_help ;;
    *)
        error "Unknown command: $1"
        cmd_help
        exit 1
        ;;
esac
```

- [ ] **Step 2: Test `init` generates a config file**

Run:
```bash
mkdir -p /tmp/test-sandbox-init && cd /tmp/test-sandbox-init
/path/to/cli/sandbox init
cat sandbox.yaml
rm -rf /tmp/test-sandbox-init
```
Expected: Prints a valid sandbox.yaml with name set to `test-sandbox-init`.

- [ ] **Step 3: Test `clean` removes the test image**

Run:
```bash
cd tests/fixtures && ../../cli/sandbox build
../../cli/sandbox clean
docker images sandbox-test-project:latest --format '{{.Repository}}:{{.Tag}}'
```
Expected: No output (image removed).

- [ ] **Step 4: Commit**

```bash
git add cli/sandbox
git commit -m "feat: add shell, stop, clean, and init commands to sandbox CLI"
```

---

### Task 8: Feature — `python`

**Files:**
- Create: `features/python.sh`

- [ ] **Step 1: Write the feature script**

```bash
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
```

- [ ] **Step 2: Test it installs correctly in the base image**

Run:
```bash
docker run --rm sandbox-base:latest bash -c "python3 --version" 2>&1 | grep -q "not found" && echo "PASS: python not in base" || echo "FAIL: python already in base"
```

Then:
```bash
docker build -t sandbox-python-test -f - . <<'DOCKER'
FROM sandbox-base:latest
USER root
COPY features/python.sh /tmp/python.sh
RUN chmod +x /tmp/python.sh && /tmp/python.sh
USER node
DOCKER

docker run --rm sandbox-python-test python --version
docker run --rm sandbox-python-test pip --version
docker run --rm sandbox-python-test bash -c "cat /etc/sandbox/firewall.d/python.conf"
```
Expected: Python 3.x version printed. pip version printed. Firewall conf lists pypi.org and files.pythonhosted.org.

- [ ] **Step 3: Clean up test image and commit**

```bash
docker rmi sandbox-python-test
git add features/python.sh
git commit -m "feat: add python feature script"
```

---

### Task 9: Feature — `node-extra`

**Files:**
- Create: `features/node-extra.sh`

- [ ] **Step 1: Write the feature script**

```bash
#!/bin/bash
# features/node-extra.sh — Install additional Node.js tooling
set -euo pipefail

echo "=== Installing node-extra feature ==="

# pnpm
npm install -g pnpm

# yarn
npm install -g yarn

# tsx (run TypeScript directly)
npm install -g tsx

# npm-check-updates
npm install -g npm-check-updates

echo "=== node-extra feature installed ==="
```

- [ ] **Step 2: Test it installs correctly**

Run:
```bash
docker build -t sandbox-node-extra-test -f - . <<'DOCKER'
FROM sandbox-base:latest
USER root
COPY features/node-extra.sh /tmp/node-extra.sh
RUN chmod +x /tmp/node-extra.sh && /tmp/node-extra.sh
USER node
DOCKER

docker run --rm sandbox-node-extra-test pnpm --version
docker run --rm sandbox-node-extra-test yarn --version
docker run --rm sandbox-node-extra-test tsx --version
docker run --rm sandbox-node-extra-test ncu --version
```
Expected: All four print version numbers.

- [ ] **Step 3: Clean up and commit**

```bash
docker rmi sandbox-node-extra-test
git add features/node-extra.sh
git commit -m "feat: add node-extra feature script"
```

---

### Task 10: Feature — `rust`

**Files:**
- Create: `features/rust.sh`

- [ ] **Step 1: Write the feature script**

```bash
#!/bin/bash
# features/rust.sh — Install Rust development environment
set -euo pipefail

echo "=== Installing Rust feature ==="

export RUSTUP_HOME=/usr/local/rustup
export CARGO_HOME=/usr/local/cargo

# Install rustup and stable toolchain
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
    sh -s -- -y --default-toolchain stable --profile minimal

# Make cargo/rustup available to all users
chmod -R a+rw "$RUSTUP_HOME" "$CARGO_HOME"
echo 'export RUSTUP_HOME=/usr/local/rustup' >> /etc/profile.d/rust.sh
echo 'export CARGO_HOME=/usr/local/cargo' >> /etc/profile.d/rust.sh
echo 'export PATH="$CARGO_HOME/bin:$PATH"' >> /etc/profile.d/rust.sh

# Source for this session
export PATH="$CARGO_HOME/bin:$PATH"

# Install cargo tools
cargo install cargo-watch cargo-edit

# Firewall domains
mkdir -p /etc/sandbox/firewall.d
cat > /etc/sandbox/firewall.d/rust.conf <<'EOF'
static.rust-lang.org
crates.io
static.crates.io
EOF

echo "=== Rust feature installed ==="
```

- [ ] **Step 2: Test it installs correctly**

Run:
```bash
docker build -t sandbox-rust-test -f - . <<'DOCKER'
FROM sandbox-base:latest
USER root
COPY features/rust.sh /tmp/rust.sh
RUN chmod +x /tmp/rust.sh && /tmp/rust.sh
USER node
ENV PATH="/usr/local/cargo/bin:$PATH"
DOCKER

docker run --rm sandbox-rust-test rustc --version
docker run --rm sandbox-rust-test cargo --version
```
Expected: Rust and cargo version numbers printed.

- [ ] **Step 3: Clean up and commit**

```bash
docker rmi sandbox-rust-test
git add features/rust.sh
git commit -m "feat: add rust feature script"
```

---

### Task 11: Feature — `go`

**Files:**
- Create: `features/go.sh`

- [ ] **Step 1: Write the feature script**

```bash
#!/bin/bash
# features/go.sh — Install Go development environment
set -euo pipefail

echo "=== Installing Go feature ==="

GO_VERSION="1.22.5"
ARCH=$(dpkg --print-architecture)
if [ "$ARCH" = "amd64" ]; then GO_ARCH="amd64"; else GO_ARCH="arm64"; fi

curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${GO_ARCH}.tar.gz" \
    | tar -C /usr/local -xz

# Make Go available system-wide
echo 'export PATH="/usr/local/go/bin:$HOME/go/bin:$PATH"' >> /etc/profile.d/go.sh
echo 'export GOPATH="$HOME/go"' >> /etc/profile.d/go.sh

# Source for this session
export PATH="/usr/local/go/bin:$PATH"
export GOPATH="/tmp/go-setup"

# Install golangci-lint
curl -sSfL https://raw.githubusercontent.com/golangci/golangci-lint/master/install.sh \
    | sh -s -- -b /usr/local/bin

# Clean up
rm -rf "$GOPATH"

# Firewall domains
mkdir -p /etc/sandbox/firewall.d
cat > /etc/sandbox/firewall.d/go.conf <<'EOF'
go.dev
dl.google.com
proxy.golang.org
sum.golang.org
storage.googleapis.com
EOF

echo "=== Go feature installed ==="
```

- [ ] **Step 2: Test it installs correctly**

Run:
```bash
docker build -t sandbox-go-test -f - . <<'DOCKER'
FROM sandbox-base:latest
USER root
COPY features/go.sh /tmp/go.sh
RUN chmod +x /tmp/go.sh && /tmp/go.sh
USER node
ENV PATH="/usr/local/go/bin:$HOME/go/bin:$PATH"
DOCKER

docker run --rm sandbox-go-test go version
docker run --rm sandbox-go-test golangci-lint --version
```
Expected: Go 1.22.x and golangci-lint version printed.

- [ ] **Step 3: Clean up and commit**

```bash
docker rmi sandbox-go-test
git add features/go.sh
git commit -m "feat: add go feature script"
```

---

### Task 12: Feature — `aws`

**Files:**
- Create: `features/aws.sh`

- [ ] **Step 1: Write the feature script**

```bash
#!/bin/bash
# features/aws.sh — Install AWS CLI v2
set -euo pipefail

echo "=== Installing AWS feature ==="

apt-get update && apt-get install -y --no-install-recommends \
    groff \
    && rm -rf /var/lib/apt/lists/*

ARCH=$(dpkg --print-architecture)
if [ "$ARCH" = "amd64" ]; then AWS_ARCH="x86_64"; else AWS_ARCH="aarch64"; fi

curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${AWS_ARCH}.zip" -o /tmp/awscliv2.zip
cd /tmp && unzip -q awscliv2.zip
/tmp/aws/install
rm -rf /tmp/aws /tmp/awscliv2.zip

# Firewall domains
mkdir -p /etc/sandbox/firewall.d
cat > /etc/sandbox/firewall.d/aws.conf <<'EOF'
awscli.amazonaws.com
sts.amazonaws.com
s3.amazonaws.com
EOF

echo "=== AWS feature installed ==="
```

- [ ] **Step 2: Test it installs correctly**

Run:
```bash
docker build -t sandbox-aws-test -f - . <<'DOCKER'
FROM sandbox-base:latest
USER root
COPY features/aws.sh /tmp/aws.sh
RUN chmod +x /tmp/aws.sh && /tmp/aws.sh
USER node
DOCKER

docker run --rm sandbox-aws-test aws --version
```
Expected: Prints `aws-cli/2.x.x ...`

- [ ] **Step 3: Clean up and commit**

```bash
docker rmi sandbox-aws-test
git add features/aws.sh
git commit -m "feat: add aws feature script"
```

---

### Task 13: Feature — `gcloud`

**Files:**
- Create: `features/gcloud.sh`

- [ ] **Step 1: Write the feature script**

```bash
#!/bin/bash
# features/gcloud.sh — Install Google Cloud SDK
set -euo pipefail

echo "=== Installing gcloud feature ==="

apt-get update && apt-get install -y --no-install-recommends \
    apt-transport-https \
    && rm -rf /var/lib/apt/lists/*

# Add Google Cloud apt repo
curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
    | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
    | tee /etc/apt/sources.list.d/google-cloud-sdk.list > /dev/null

apt-get update && apt-get install -y --no-install-recommends \
    google-cloud-cli \
    google-cloud-cli-gke-gcloud-auth-plugin \
    && rm -rf /var/lib/apt/lists/*

# Firewall domains
mkdir -p /etc/sandbox/firewall.d
cat > /etc/sandbox/firewall.d/gcloud.conf <<'EOF'
packages.cloud.google.com
dl.google.com
oauth2.googleapis.com
storage.googleapis.com
cloudresourcemanager.googleapis.com
compute.googleapis.com
container.googleapis.com
EOF

echo "=== gcloud feature installed ==="
```

- [ ] **Step 2: Test it installs correctly**

Run:
```bash
docker build -t sandbox-gcloud-test -f - . <<'DOCKER'
FROM sandbox-base:latest
USER root
COPY features/gcloud.sh /tmp/gcloud.sh
RUN chmod +x /tmp/gcloud.sh && /tmp/gcloud.sh
USER node
DOCKER

docker run --rm sandbox-gcloud-test gcloud version
```
Expected: Prints Google Cloud SDK version info.

- [ ] **Step 3: Clean up and commit**

```bash
docker rmi sandbox-gcloud-test
git add features/gcloud.sh
git commit -m "feat: add gcloud feature script"
```

---

### Task 14: Feature — `ollama`

**Files:**
- Create: `features/ollama.sh`

- [ ] **Step 1: Write the feature script**

```bash
#!/bin/bash
# features/ollama.sh — Install Ollama server for local LLM inference
set -euo pipefail

echo "=== Installing Ollama feature ==="

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
```

- [ ] **Step 2: Test it installs correctly**

Run:
```bash
docker build -t sandbox-ollama-test -f - . <<'DOCKER'
FROM sandbox-base:latest
USER root
COPY features/ollama.sh /tmp/ollama.sh
RUN chmod +x /tmp/ollama.sh && /tmp/ollama.sh
USER node
DOCKER

docker run --rm sandbox-ollama-test ollama --version
docker run --rm sandbox-ollama-test bash -c "test -f /etc/sandbox/services/ollama && echo 'PASS: service marker exists'"
```
Expected: Ollama version printed. "PASS: service marker exists" printed.

- [ ] **Step 3: Clean up and commit**

```bash
docker rmi sandbox-ollama-test
git add features/ollama.sh
git commit -m "feat: add ollama feature script"
```

---

### Task 15: Feature — `llm`

**Files:**
- Create: `features/llm.sh`

- [ ] **Step 1: Write the feature script**

```bash
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
```

- [ ] **Step 2: Test it installs correctly (requires python feature first)**

Run:
```bash
docker build -t sandbox-llm-test -f - . <<'DOCKER'
FROM sandbox-base:latest
USER root
COPY features/python.sh /tmp/python.sh
RUN chmod +x /tmp/python.sh && /tmp/python.sh
COPY features/llm.sh /tmp/llm.sh
RUN chmod +x /tmp/llm.sh && /tmp/llm.sh
USER node
DOCKER

docker run --rm sandbox-llm-test llm --version
docker run --rm sandbox-llm-test llm plugins
```
Expected: llm version printed. Plugin list includes `llm-claude-3` and `llm-ollama`.

- [ ] **Step 3: Test it fails gracefully without Python**

Run:
```bash
docker build -t sandbox-llm-nopython-test -f - . <<'DOCKER'
FROM sandbox-base:latest
USER root
COPY features/llm.sh /tmp/llm.sh
RUN chmod +x /tmp/llm.sh && /tmp/llm.sh
USER node
DOCKER
```
Expected: Build fails with "ERROR: llm feature requires the python feature."

- [ ] **Step 4: Clean up and commit**

```bash
docker rmi sandbox-llm-test 2>/dev/null; docker rmi sandbox-llm-nopython-test 2>/dev/null
git add features/llm.sh
git commit -m "feat: add llm feature script with claude and ollama plugins"
```

---

### Task 16: Test Harness

**Files:**
- Create: `tests/test-base.sh`
- Create: `tests/test-feature.sh`
- Create: `tests/test-firewall.sh`
- Create: `tests/test-cli.sh`

- [ ] **Step 1: Write the base image test**

```bash
#!/bin/bash
# tests/test-base.sh — Verify base image tools and configuration
set -euo pipefail

IMAGE="sandbox-base:latest"
PASS=0
FAIL=0

check() {
    local desc="$1"
    shift
    if docker run --rm "$IMAGE" "$@" &>/dev/null; then
        echo "  PASS: $desc"
        ((PASS++))
    else
        echo "  FAIL: $desc"
        ((FAIL++))
    fi
}

echo "=== Base Image Tests ==="

check "node is installed"     node --version
check "npm is installed"      npm --version
check "claude is installed"   claude --version
check "git is installed"      git --version
check "zsh is installed"      zsh --version
check "jq is installed"       jq --version
check "fzf is installed"      fzf --version
check "gh is installed"       gh --version
check "curl is installed"     curl --version
check "delta is installed"    delta --version
check "nano is installed"     nano --version
check "vim is installed"      vim --version

# Check user is node
check "runs as node user" bash -c '[ "$(whoami)" = "node" ]'
# Check workspace exists
check "/workspace exists" bash -c '[ -d /workspace ]'
# Check sudo works
check "sudo works" sudo echo "ok"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
```

- [ ] **Step 2: Write the feature test harness**

```bash
#!/bin/bash
# tests/test-feature.sh — Test a single feature script in isolation
# Usage: tests/test-feature.sh <feature-name> <check-command> [<check-command>...]
# Example: tests/test-feature.sh python "python --version" "pip --version"
set -euo pipefail

FEATURE="$1"
shift
CHECKS=("$@")

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "=== Testing feature: $FEATURE ==="

# Build test image
TAG="sandbox-feature-test-${FEATURE}"
docker build -t "$TAG" -f - "$SCRIPT_DIR" <<DOCKER
FROM sandbox-base:latest
USER root
COPY features/${FEATURE}.sh /tmp/${FEATURE}.sh
RUN chmod +x /tmp/${FEATURE}.sh && /tmp/${FEATURE}.sh
USER node
DOCKER

PASS=0
FAIL=0
for cmd in "${CHECKS[@]}"; do
    if docker run --rm "$TAG" bash -lc "$cmd" &>/dev/null; then
        echo "  PASS: $cmd"
        ((PASS++))
    else
        echo "  FAIL: $cmd"
        ((FAIL++))
    fi
done

# Clean up
docker rmi "$TAG" &>/dev/null

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
```

- [ ] **Step 3: Write the firewall test**

```bash
#!/bin/bash
# tests/test-firewall.sh — Verify strict firewall blocks/allows correctly
set -euo pipefail

IMAGE="sandbox-base:latest"
PASS=0
FAIL=0

echo "=== Firewall Tests (strict mode) ==="

check_blocked() {
    local domain="$1"
    if docker run --rm --cap-add NET_ADMIN --cap-add NET_RAW \
        -e SANDBOX_FIREWALL=strict \
        "$IMAGE" bash -c "curl --connect-timeout 5 -sf https://${domain} >/dev/null 2>&1"; then
        echo "  FAIL: $domain should be blocked but is reachable"
        ((FAIL++))
    else
        echo "  PASS: $domain is blocked"
        ((PASS++))
    fi
}

check_allowed() {
    local domain="$1"
    if docker run --rm --cap-add NET_ADMIN --cap-add NET_RAW \
        -e SANDBOX_FIREWALL=strict \
        "$IMAGE" bash -c "curl --connect-timeout 10 -sf https://${domain} >/dev/null 2>&1"; then
        echo "  PASS: $domain is allowed"
        ((PASS++))
    else
        echo "  FAIL: $domain should be allowed but is blocked"
        ((FAIL++))
    fi
}

check_blocked "example.com"
check_blocked "httpbin.org"
check_allowed "api.github.com"
check_allowed "registry.npmjs.org"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
```

- [ ] **Step 4: Write the CLI test**

```bash
#!/bin/bash
# tests/test-cli.sh — Verify CLI commands work correctly
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="$SCRIPT_DIR/cli/sandbox"
FIXTURES="$SCRIPT_DIR/tests/fixtures"
PASS=0
FAIL=0

check() {
    local desc="$1"
    shift
    if "$@" &>/dev/null; then
        echo "  PASS: $desc"
        ((PASS++))
    else
        echo "  FAIL: $desc"
        ((FAIL++))
    fi
}

echo "=== CLI Tests ==="

# help
check "help command works" "$SANDBOX" help

# init
TMPDIR=$(mktemp -d)
check "init creates sandbox.yaml" bash -c "cd $TMPDIR && $SANDBOX init && test -f sandbox.yaml"
rm -rf "$TMPDIR"

# build (using fixture)
check "build creates project image" bash -c "cd $FIXTURES && $SANDBOX build"
check "project image exists" docker image inspect sandbox-test-project:latest

# clean
check "clean removes project image" bash -c "cd $FIXTURES && $SANDBOX clean"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
```

- [ ] **Step 5: Make all test scripts executable and run them**

Run:
```bash
chmod +x tests/test-base.sh tests/test-feature.sh tests/test-firewall.sh tests/test-cli.sh
tests/test-base.sh
tests/test-cli.sh
```
Expected: All checks pass.

- [ ] **Step 6: Commit**

```bash
git add tests/
git commit -m "feat: add test harness for base image, features, firewall, and CLI"
```

---

### Task 17: Integration Test — End to End

**Files:**
- Create: `tests/test-integration.sh`
- Create: `tests/fixtures/sandbox-full.yaml`

- [ ] **Step 1: Create a full-featured test config**

```yaml
# tests/fixtures/sandbox-full.yaml
name: integration-test

features:
  - python
  - llm

packages:
  - tree
  - ripgrep

env:
  TEST_VAR: hello

mounts:
  - host: .
    container: /workspace

firewall: open

claude:
  mode: interactive
  args: []
```

- [ ] **Step 2: Write the integration test**

```bash
#!/bin/bash
# tests/test-integration.sh — End-to-end test: build base, build project, run container
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="$SCRIPT_DIR/cli/sandbox"
FIXTURES="$SCRIPT_DIR/tests/fixtures"
PASS=0
FAIL=0

check() {
    local desc="$1"
    shift
    if "$@" 2>&1; then
        echo "  PASS: $desc"
        ((PASS++))
    else
        echo "  FAIL: $desc"
        ((FAIL++))
    fi
}

echo "=== Integration Test ==="

# Step 1: Build base
echo "Building base image..."
"$SANDBOX" build-base

# Step 2: Build project with python + llm features
echo "Building project image..."
cd "$FIXTURES"
CONFIG_FILE="sandbox-full.yaml" check "build full project" bash -c "cd $FIXTURES && $SANDBOX build"

# Step 3: Verify tools are available in the container
IMAGE="sandbox-integration-test:latest"

check "python available"  docker run --rm "$IMAGE" python --version
check "pip available"     docker run --rm "$IMAGE" pip --version
check "llm available"     docker run --rm "$IMAGE" bash -lc "llm --version"
check "tree available"    docker run --rm "$IMAGE" tree --version
check "rg available"      docker run --rm "$IMAGE" rg --version
check "claude available"  docker run --rm "$IMAGE" claude --version
check "env var set"       docker run --rm "$IMAGE" bash -c '[ "$TEST_VAR" = "hello" ]'

# Step 4: Clean up
docker rmi "$IMAGE" 2>/dev/null || true

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
```

- [ ] **Step 3: Run the integration test**

Run:
```bash
chmod +x tests/test-integration.sh
tests/test-integration.sh
```
Expected: All checks pass — base builds, project builds with python+llm+packages, all tools available in container.

- [ ] **Step 4: Commit**

```bash
git add tests/test-integration.sh tests/fixtures/sandbox-full.yaml
git commit -m "feat: add end-to-end integration test"
```

---

## Task Dependency Summary

```
Task 1 (Base Dockerfile)
  └─> Task 2 (Firewall)
  └─> Task 3 (Template)
  └─> Task 4 (CLI core + build-base)
        └─> Task 5 (CLI build)
              └─> Task 6 (CLI run)
                    └─> Task 7 (CLI shell/stop/clean/init)
  └─> Tasks 8-13 (Features: python, node-extra, rust, go, aws, gcloud) — PARALLEL, independent
  └─> Task 14 (Feature: ollama) — independent
  └─> Task 15 (Feature: llm) — depends on Task 8 (python)
  └─> Task 16 (Test harness) — depends on Tasks 1-7
  └─> Task 17 (Integration test) — depends on all above
```

Tasks 8-14 can all run in parallel after Task 1 is complete. Task 15 depends on Task 8. Tasks 2, 3, and 4 can run in parallel after Task 1. Tasks 5-7 are sequential. Task 16 can start after Task 7. Task 17 runs last.
