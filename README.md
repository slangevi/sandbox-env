# Claude Code Sandbox

A Docker sandbox for running Claude Code in isolated, per-project customizable containers. Each project declares its tools, languages, and configuration in a `sandbox.yaml` file.

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/)
- [yq](https://github.com/mikefarah/yq) (YAML processor) — `brew install yq`

## Quick Start

```bash
# 1. Build the base image (once)
./cli/sandbox build-base

# 2. Go to your project directory
cd ~/my-project

# 3. Generate a starter config
~/path/to/sandbox-env/cli/sandbox init

# 4. Edit sandbox.yaml — add features, packages, etc.

# 5. Build your project image
~/path/to/sandbox-env/cli/sandbox build

# 6. Authenticate Claude Code for this project
~/path/to/sandbox-env/cli/sandbox login

# 7. Launch Claude Code
~/path/to/sandbox-env/cli/sandbox claude
```

This launches Claude Code directly inside the sandbox. Your project files are mounted at `/workspace`.

## Configuration

Each project gets a `sandbox.yaml` at its root:

```yaml
name: my-project

features:
  - python
  - llm

packages:
  - ripgrep
  - tree

env:
  PROJECT_TYPE: coding

git:
  user.name: Your Name
  user.email: you@example.com

mounts:
  - host: .
    container: /workspace
  - host: ~/shared-data
    container: /data
    readonly: true

firewall: strict
# allowed_domains:
#   - api.example.com

# setup: ./scripts/custom-setup.sh

claude:
  mode: interactive
  # skip_permissions: false
  # timeout: 30m
  # args: []

# resources:
#   memory: 4g
#   cpus: 2
```

All fields except `name` are optional. Defaults: no features, no extra packages, mount `.` to `/workspace`, firewall strict, interactive mode.

### Git configuration

Set git identity per project in `sandbox.yaml`:

```yaml
git:
  user.name: Your Name
  user.email: you@example.com
  init.defaultBranch: main
```

Any `git config --global` key works. These are applied on every container start, so commits inside the sandbox always have the correct author.

### Custom setup script

For anything the YAML can't express, point to a setup script:

```yaml
setup: ./scripts/custom-setup.sh
```

The script runs as root during `sandbox build`, after features and packages are installed. Use it for custom system configuration, additional tool installs, or project-specific setup.

### Resource limits

Constrain container resources:

```yaml
resources:
  memory: 4g
  cpus: 2
```

These map directly to Docker's `--memory` and `--cpus` flags.

## Features

Composable install scripts in `features/`. Add them to your `sandbox.yaml` to include in your project image.

| Feature | What it installs |
|---|---|
| `python` | Python 3, pip, venv, dev headers, pipx |
| `node-extra` | pnpm, yarn, tsx, npm-check-updates |
| `rust` | Rust stable via rustup, cargo, cargo-watch, cargo-edit |
| `go` | Go 1.22, golangci-lint |
| `aws` | AWS CLI v2 |
| `gcloud` | Google Cloud SDK, GKE auth plugin |
| `glab` | GitLab CLI |
| `ollama` | Ollama server (runs inside the container) |
| `llm` | Simon Willison's llm CLI with Claude and Ollama plugins (requires `python`) |

### Adding a feature

Drop a script in `features/`. It must:

1. Start with `set -euo pipefail`
2. Install non-interactively
3. Clean up after itself (`rm -rf /var/lib/apt/lists/*`)
4. Optionally write firewall domains to `/etc/sandbox/firewall.d/<name>.conf`

## CLI Commands

```
sandbox build-base          Build the base image (once, or to update)
sandbox build [--no-cache]  Build project image from sandbox.yaml
sandbox run [--headless] [-- <cmd>]  Run the container, a command, or headless Claude
sandbox claude              Launch Claude Code (Anthropic API)
sandbox claude-local <model> Launch Claude Code with a local Ollama model
sandbox remote              Remote control via claude.ai/code (Anthropic API)
sandbox remote-local <model> Remote control with a local Ollama model
sandbox ollama <cmd>        Run Ollama commands in the sandbox
sandbox login               Authenticate Claude Code for this project
sandbox exec <cmd>          Run a command in a running container
sandbox shell               Open a shell in a running container
sandbox stop                Stop the running container
sandbox status              Show running sandbox containers
sandbox logs                Show output from the last headless run
sandbox models <cmd>        Manage Ollama models (pull, list, rm)
sandbox clean               Remove project image and all project volumes
sandbox clean-models        Remove shared Ollama models volume
sandbox init                Generate a starter sandbox.yaml
```

### Running Claude Code

```bash
# Launch Claude Code directly
sandbox claude

# With a one-off prompt
sandbox claude -p "Refactor the auth module"

# If a sandbox is already running, attaches to it
# If not, starts a new container with Claude Code
```

### Local models (Ollama-powered Claude Code)

Run Claude Code using a local Ollama model instead of the Anthropic API — fully offline, no API key needed:

```bash
# Pull a model first
sandbox models pull qwen3.5

# Launch Claude Code with the local model
sandbox claude-local qwen3.5

# Or with remote control
sandbox remote-local qwen3.5
```

This uses Ollama's Anthropic-compatible API. The `ollama` feature must be in your `sandbox.yaml`. Models need at least 64k context — see [recommended models](https://ollama.com/search?c=cloud).

### Remote control

Control Claude Code inside the sandbox from any browser or the Claude mobile app:

```bash
sandbox remote
```

This starts Claude Code in remote control server mode. It displays a session URL — open it at [claude.ai/code](https://claude.ai/code) or scan the QR code with the Claude app. No ports are exposed; all communication goes through the Anthropic API over outbound HTTPS.

Options:

```bash
sandbox remote --name "My Project"     # Custom session name
sandbox remote --spawn worktree        # Each connection gets its own git worktree
```

Works with strict firewall since it only needs outbound HTTPS to `api.anthropic.com` (already whitelisted).

### Headless mode

Run Claude Code non-interactively with output capture:

```bash
sandbox run --headless -- "Refactor the auth module to use JWT"
```

Output is automatically saved to `~/.sandbox/logs/<name>/`. View it with:

```bash
sandbox logs
```

### Autonomous mode

For fully unattended operation with `--dangerously-skip-permissions`, use strict firewall + skip_permissions together:

```yaml
firewall: strict
claude:
  mode: headless
  skip_permissions: true
  timeout: 30m

resources:
  memory: 4g
  cpus: 2
```

This auto-adds `--dangerously-skip-permissions` to Claude Code while the strict firewall constrains network access. The sandbox warns if you enable skip_permissions without a strict firewall.

## Authentication

Each project has its own isolated Claude Code authentication, stored in a Docker named volume (`sandbox-<name>-claude`). Authenticate after building:

```bash
sandbox login
```

This runs `claude login` inside the container. The session persists in the volume across container restarts and rebuilds. Different projects can use different accounts.

## Persistent State

Each project gets isolated Docker volumes for state that should survive container restarts:

| Volume | What persists |
|---|---|
| `sandbox-<name>-claude` | Claude Code auth, config, plugins |
| `sandbox-<name>-home` | Shell history, `.gitconfig`, `.config/`, `~/.local/`, npm global packages (MCP servers) |
| `sandbox-<name>-cache` | pip, npm, cargo caches (faster installs) |
| `sandbox-ollama-models` | Ollama models (**shared** across all projects) |

Globally installed npm packages (including MCP servers installed via `npm install -g`) persist across container restarts via a redirected npm prefix in the home volume.

`sandbox clean` removes per-project volumes. `sandbox clean-models` removes the shared Ollama models volume.

## Firewall

Two modes controlled by the `firewall` field in `sandbox.yaml`:

**`strict`** (default) — Default-deny iptables policy. Only whitelisted domains are reachable:
- Claude API, npm, GitHub, GitLab (always allowed)
- Feature-specific domains (e.g., PyPI when `python` is installed)
- Custom domains via `allowed_domains` in your config

```yaml
firewall: strict
allowed_domains:
  - api.example.com
  - internal.mycompany.com
```

**`open`** — No network restrictions. Use when you need unrestricted access (e.g., installing packages from arbitrary sources). Set `firewall: open` in your sandbox.yaml.

### Security hardening

In strict mode, the firewall:
- Blocks all IPv6 traffic
- Restricts DNS to the Docker resolver only (prevents DNS tunneling)
- Restricts SSH to whitelisted destinations only
- Narrows host network access to the gateway IP only
- Verifies both blocking and allowing work at startup

The container runs as root only during startup (for firewall init), then drops to the `node` user permanently via `gosu`. There is no sudo available inside the container.

## Architecture

```
sandbox-env/
├── base/                  # Base image (node:20-slim + Claude Code + tools)
│   ├── Dockerfile
│   ├── entrypoint.sh
│   ├── init-firewall.sh
│   └── firewall-domains.conf
├── features/              # Composable install scripts
├── cli/sandbox            # CLI script
├── templates/             # Dockerfile template for project images
└── tests/                 # Test harness
```

**Two-stage build:**

1. **Base image** (`sandbox-base:latest`) — Built once. Node.js 20, Claude Code, git, zsh, fzf, jq, gh, and firewall infrastructure.
2. **Project image** (`sandbox-<name>:latest`) — Built per-project. Layers features and packages on top of the base.

## Ollama

Manage models with the `sandbox models` command — no need to configure mounts manually:

```bash
sandbox models pull llama3.2       # Download a model
sandbox models pull codellama      # Download another
sandbox models list                # Show downloaded models
sandbox models rm tinyllama        # Remove a model
```

Models are stored in a shared Docker volume (`sandbox-ollama-models`) and available to all projects with the `ollama` feature. Pull once, use everywhere.

To use Ollama in a project:

```yaml
features:
  - ollama
```

Ollama starts automatically when the container launches. Use the convenience command:

```bash
# Start a sandbox, then chat with a model
sandbox run
sandbox ollama run llama3.2

# Or run a one-off prompt
sandbox ollama run llama3.2 "Explain this code"
```

## LLM CLI

The `llm` feature installs [Simon Willison's llm](https://llm.datasette.io/) with Claude and Ollama plugins pre-configured.

```yaml
features:
  - python    # required
  - llm
  - ollama    # optional, for local models
```

Run prompts from outside the container:

```bash
# One-off prompt
sandbox run -- llm "Summarize this code"

# With a specific model
sandbox run -- llm -m claude-3.5-sonnet "Explain this error"

# Using local Ollama models
sandbox run -- llm -m ollama/llama3.2 "What does this function do?"

# Pipe input
sandbox run -- bash -c 'cat /workspace/main.py | llm "Review this code"'
```

Or in a running container:

```bash
sandbox exec llm "Your prompt"
sandbox exec llm -m ollama/llama3.2 "Your prompt"
```

## Testing

```bash
# Test base image
tests/test-base.sh

# Test a specific feature
tests/test-feature.sh python "python --version" "pip --version"

# Test CLI commands
tests/test-cli.sh

# Test CLI error handling and input validation
tests/test-cli-errors.sh

# Test run modes, exec, readonly mounts
tests/test-run-modes.sh

# Test firewall (requires NET_ADMIN capability)
tests/test-firewall.sh

# Full end-to-end test
tests/test-integration.sh
```
