# Claude Code Sandbox

A Docker sandbox for running Claude Code in isolated, per-project customizable containers. Each project declares its tools, languages, and configuration in a `sandbox.yaml` file.

## Prerequisites

**macOS:**
```bash
brew install --cask docker   # or install Docker Desktop from docker.com
brew install yq
```

**Linux (Debian/Ubuntu):**
```bash
# Docker
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER  # then log out and back in

# yq
sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_$(dpkg --print-architecture)
sudo chmod +x /usr/local/bin/yq
```

## Quick Start

### One-time setup

```bash
# Clone the sandbox-env repo
git clone https://github.com/slangevi/sandbox-env.git ~/sandbox-env

# Build the base image (takes a few minutes the first time)
~/sandbox-env/cli/sandbox build-base

# Optional: add an alias for convenience
echo 'alias sandbox="~/sandbox-env/cli/sandbox"' >> ~/.zshrc
source ~/.zshrc
```

### Per-project setup

```bash
cd ~/my-code-project

# Generate a sandbox config (creates sandbox.yaml)
sandbox init

# Edit sandbox.yaml — add features, packages, git config, etc.

# Build your project image
sandbox build

# Authenticate Claude Code for this project (once)
sandbox login

# Launch Claude Code
sandbox claude
```

Your project files are mounted at `/workspace` inside the container. Edits Claude makes are immediately visible on your host. The only file added to your project is `sandbox.yaml` — commit it for your team or add it to `.gitignore`.

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

The following keys are supported: `user.name`, `user.email`, `init.defaultBranch`, `core.autocrlf`, `core.eol`, `push.default`, `pull.rebase`, `commit.gpgsign`, `tag.gpgsign`, `merge.ff`. These are applied on every container start. Other keys are blocked for security (some git config keys allow command execution).

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
sandbox llm [args]          Run the llm CLI in the sandbox
sandbox login               Authenticate Claude Code for this project
sandbox start               Start the sandbox in the background
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

### Background mode

Start the sandbox once, then run commands instantly without container startup overhead:

```bash
sandbox start                        # starts in background
sandbox llm "Summarize this code"    # fast — exec into running container
sandbox llm "Explain this error"     # fast again
sandbox claude                       # launch Claude Code in the same container
sandbox shell                        # open a shell
sandbox stop                         # when done
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

Run Claude Code non-interactively with a prompt. Output is captured to a log file:

```bash
# Pass the prompt after --
sandbox run --headless -- "Refactor the auth module to use JWT"

# View the output
sandbox logs
```

You can also set `mode: headless` in `sandbox.yaml` so you don't need the `--headless` flag, but you still pass the prompt after `--`:

```yaml
claude:
  mode: headless
```

```bash
sandbox run -- "Fix the failing tests"
```

Output is saved to `~/.sandbox/logs/<name>/` with timestamps.

### Autonomous mode

For fully unattended operation, combine headless mode with `skip_permissions` and a timeout:

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

```bash
sandbox run -- "Refactor the auth module to use JWT"
```

This auto-adds `--dangerously-skip-permissions` to Claude Code while the strict firewall constrains network access. The timeout kills the run after 30 minutes. The sandbox warns if you enable skip_permissions without a strict firewall.

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

With a running sandbox (`sandbox run` or `sandbox claude`):

```bash
# One-off prompt
sandbox llm "Summarize this code"

# With a specific model
sandbox llm -m claude-3.5-sonnet "Explain this error"

# Using local Ollama models
sandbox llm -m ollama/llama3.2 "What does this function do?"

# Pipe input (via sandbox exec for stdin support)
sandbox exec bash -c 'cat /workspace/main.py | llm "Review this code"'
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

# Test volume lifecycle, persistence, cleanup
tests/test-volumes.sh

# Test git config from sandbox.yaml
tests/test-git-config.sh

# Test headless mode and output capture
tests/test-headless.sh

# Test convenience commands (claude, ollama, llm, models)
tests/test-commands.sh

# Test YAML parsing and validation
tests/test-yaml-validation.sh

# Test firewall (requires NET_ADMIN capability)
tests/test-firewall.sh

# Full end-to-end test
tests/test-integration.sh
```

## HOWTOs

Step-by-step guides for common use cases:

- [Python Development](docs/howto/python-development.md) — Set up a sandbox for Python projects with pip, venv, testing, and linting
- [Local LLM Coding](docs/howto/local-llm-coding.md) — Use Ollama models to power Claude Code fully offline, no API key needed
- [Agentic Automation](docs/howto/agentic-automation.md) — Run Claude Code autonomously with strict firewall, timeouts, and resource limits
- [Multi-Model Workflow](docs/howto/multi-model-workflow.md) — Combine Claude API for complex tasks with free local models for quick work
- [Full-Stack Web Development](docs/howto/fullstack-web-development.md) — Python + Node.js sandbox with databases and custom setup
- [Remote Pair Programming](docs/howto/remote-pair-programming.md) — Control Claude Code from any browser or phone via remote control
