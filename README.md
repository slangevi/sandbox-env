# Claude Code Sandbox

A Docker sandbox for running Claude Code in isolated, per-project customizable containers. Each project declares its tools, languages, and configuration in a `sandbox.yaml` file.

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/)
- [yq](https://github.com/mikefarah/yq) (YAML processor) — `brew install yq`
- Claude Code authenticated on your host — `claude login`

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

# 6. Run it
~/path/to/sandbox-env/cli/sandbox run
```

You'll land in a zsh shell inside the container with Claude Code available. Your project files are mounted at `/workspace`.

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

mounts:
  - host: .
    container: /workspace
  - host: ~/shared-data
    container: /data
    readonly: true

firewall: open

claude:
  mode: interactive
  args: []
```

All fields except `name` are optional. Defaults: no features, no extra packages, mount `.` to `/workspace`, firewall open, interactive mode.

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
sandbox build               Build project image from sandbox.yaml
sandbox run [--headless]    Run the container (interactive or headless)
sandbox shell               Open another shell in a running container
sandbox stop                Stop the running container
sandbox clean               Remove the project image
sandbox init                Generate a starter sandbox.yaml
```

### Headless mode

Run Claude Code non-interactively:

```bash
sandbox run --headless -- "Refactor the auth module to use JWT"
```

## Authentication

The sandbox mounts your host `~/.claude` directory into the container. Authenticate on your host first:

```bash
claude login
```

The container picks up the session automatically.

## Firewall

Two modes controlled by the `firewall` field in `sandbox.yaml`:

**`open`** (default) — No network restrictions.

**`strict`** — Default-deny iptables policy. Only whitelisted domains are reachable:
- Claude API, npm, GitHub, GitLab (always allowed)
- Feature-specific domains (e.g., PyPI when `python` is installed)
- Custom domains via `allowed_domains` in your config

```yaml
firewall: strict
allowed_domains:
  - api.example.com
  - internal.mycompany.com
```

Strict mode is recommended when running with `claude --dangerously-skip-permissions`.

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

To run local LLMs inside the sandbox:

```yaml
features:
  - ollama

mounts:
  - host: .
    container: /workspace
  - host: ~/.ollama/models
    container: /home/node/.ollama/models
```

Ollama starts automatically when the container launches. Mount `~/.ollama/models` from your host to persist downloaded models across container rebuilds.

```bash
# Inside the container
ollama pull llama3.2
ollama run llama3.2 "Explain this code"
```

## Testing

```bash
# Test base image
tests/test-base.sh

# Test a specific feature
tests/test-feature.sh python "python --version" "pip --version"

# Test CLI commands
tests/test-cli.sh

# Test firewall (requires NET_ADMIN capability)
tests/test-firewall.sh

# Full end-to-end test
tests/test-integration.sh
```
