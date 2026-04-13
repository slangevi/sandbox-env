# Claude Code Sandbox Environment — Design Spec

**Date:** 2026-04-13
**Status:** Draft

## Purpose

A reusable, general-purpose Docker sandbox for running Claude Code in an isolated environment. Each project that uses the sandbox can customize its own set of tools, language runtimes, and configuration. Supports coding projects, general-purpose agentic automation, and future use cases.

## Architecture: Two-Stage Build

The system uses a two-stage Docker image architecture orchestrated by a `sandbox` CLI.

### Stage 1: Base Image (`sandbox-base:latest`)

Built once from `base/Dockerfile`. Contains:

- **Base:** `node:20-slim` (Debian-based, provides Node.js for Claude Code)
- **Claude Code CLI:** Installed globally via npm
- **Core tools:** git, zsh (with Powerlevel10k), fzf, jq, gh (GitHub CLI), nano, vim, git-delta, curl, wget, unzip, gnupg2, sudo, less, procps, man-db, iproute2, dnsutils, aggregate
- **Firewall infrastructure:** iptables, ipset (for strict mode)
- **Non-root user:** `node` user with sudo, workspace at `/workspace`
- **Shell:** zsh as default shell with productivity config

### Stage 2: Project Image (`sandbox-<name>:latest`)

Built per-project from a generated Dockerfile that inherits `FROM sandbox-base:latest`. Applies:

- Feature scripts declared in `sandbox.yaml`
- Additional apt packages
- Custom setup script (if specified)

### Runtime

The container is launched with configuration from `sandbox.yaml`:

- Bind mounts (project files, custom mounts)
- `~/.claude` mounted from host (OAuth session authentication)
- Environment variables injected
- Firewall mode applied (open or strict)
- Interactive (zsh shell) or headless (`claude -p "..."`) mode

## Authentication

Claude Code authenticates via **OAuth session mounted from the host**. The user runs `claude login` on their host machine, then the sandbox mounts `~/.claude` into the container at runtime. The container inherits the active session — no API keys or token management required.

Mount: `~/.claude` -> `/home/node/.claude` (read-write, since Claude Code may refresh tokens and write config)

## Project Configuration: `sandbox.yaml`

Each project declares its sandbox configuration in a `sandbox.yaml` file at its root.

```yaml
# sandbox.yaml — project sandbox configuration
name: my-project                  # Required. Used for image tagging.

# Feature scripts to install (from features/ directory)
features:
  - python
  - node-extra

# Additional apt packages beyond what features provide
packages:
  - ripgrep
  - tree
  - postgresql-client

# Environment variables set in the container
env:
  PROJECT_TYPE: coding
  PYTHONDONTWRITEBYTECODE: "1"

# Filesystem mounts
mounts:
  - host: .
    container: /workspace
  - host: ~/shared-data
    container: /data
    readonly: true

# Network security
firewall: open                    # 'open' or 'strict'
allowed_domains:                  # only used when firewall: strict
  - api.example.com

# Optional custom setup script (runs at end of build)
setup: ./scripts/custom-setup.sh

# Claude Code run mode defaults
claude:
  mode: interactive               # 'interactive' or 'headless'
  args: []                        # extra args passed to claude
```

**All fields except `name` are optional.** Defaults:

| Field | Default |
|---|---|
| `features` | `[]` (none) |
| `packages` | `[]` (none) |
| `env` | `{}` (none) |
| `mounts` | `[{host: ".", container: "/workspace"}]` |
| `firewall` | `open` |
| `allowed_domains` | `[]` |
| `setup` | none |
| `claude.mode` | `interactive` |
| `claude.args` | `[]` |

## CLI: `sandbox` Command

A bash script at `cli/sandbox` that orchestrates Docker operations.

### Commands

**`sandbox build-base`**
Builds the base image from `base/Dockerfile` and tags as `sandbox-base:latest`.

**`sandbox build`**
Reads `sandbox.yaml` from the current directory. Generates a temporary Dockerfile from `templates/Dockerfile.project.tmpl`:
1. `FROM sandbox-base:latest`
2. Copies and runs each feature script in order
3. Installs additional apt packages
4. Copies and runs custom setup script (if specified)
5. Builds and tags as `sandbox-<name>:latest`

**`sandbox run [--headless] [-- <claude-args>]`**
Launches the container from the project image with:
- Bind mounts from `sandbox.yaml` (plus `~/.claude` always mounted)
- Environment variables from `sandbox.yaml`
- `NET_ADMIN` + `NET_RAW` capabilities if `firewall: strict`
- Firewall initialization on startup if strict mode
- Interactive: drops into zsh shell. Headless: runs `claude -p` with args.
- Container name: `sandbox-<name>`

**`sandbox shell`**
`docker exec -it sandbox-<name> /bin/zsh` — open a second terminal into a running container.

**`sandbox stop`**
Stops and removes the running `sandbox-<name>` container.

**`sandbox clean`**
Removes the `sandbox-<name>:latest` image.

**`sandbox init`**
Generates a starter `sandbox.yaml` in the current directory with the project name derived from the directory name and sensible defaults.

## Feature Scripts

Self-contained install scripts in `features/`. Each follows a strict contract:

### Contract

1. Starts with `set -euo pipefail`
2. Installs via apt or official installers — no untrusted `curl | bash`
3. Cleans up after itself (`rm -rf /var/lib/apt/lists/*`, temp files)
4. Idempotent — safe to run twice
5. Non-interactive — no user prompts
6. May drop a file in `/etc/sandbox/firewall.d/<feature>.conf` listing required domains (one per line) for strict firewall mode

### Starter Features

**`python`**
- Python 3.12, pip, venv, dev headers
- `pipx` for global CLI tools
- Symlinks `python` -> `python3`
- Firewall domains: `pypi.org`, `files.pythonhosted.org`

**`node-extra`**
- pnpm, yarn
- `tsx` for running TypeScript directly
- `npm-check-updates`
- Firewall domains: none beyond base (npm registry already in base)

**`rust`**
- Rust stable via rustup (installed for non-root user)
- cargo, `cargo-watch`, `cargo-edit`
- `CARGO_HOME` and `RUSTUP_HOME` configured
- Firewall domains: `static.rust-lang.org`, `crates.io`, `static.crates.io`

**`go`**
- Go 1.22 via official tarball
- `GOPATH` configured, added to `PATH`
- `golangci-lint`
- Firewall domains: `go.dev`, `proxy.golang.org`, `sum.golang.org`, `storage.googleapis.com`

**`aws`**
- AWS CLI v2 via official installer
- `aws-shell` for interactive use
- Firewall domains: `*.amazonaws.com` (resolved at firewall init time)

**`gcloud`**
- Google Cloud SDK via apt repo
- `gke-gcloud-auth-plugin`
- Firewall domains: `*.googleapis.com`, `packages.cloud.google.com`, `dl.google.com`

**`ollama`**
- Ollama server binary via official install script
- Configured to start as a background service on container entry (via entrypoint script), not at build time
- `OLLAMA_HOST` defaults to `localhost:11434`
- Model storage: expects a host mount for `/home/node/.ollama/models` to persist models across container rebuilds (configured in `sandbox.yaml` mounts)
- Does not pre-pull any models — user pulls what they need at runtime

**`llm`**
- Simon Willison's `llm` CLI installed via pipx
- Requires `python` feature (script checks and fails with clear error if Python is not available)
- Pre-installs plugins: `llm-claude-3`, `llm-ollama`
- Firewall domains: none beyond what `python` and other features provide

## Firewall

### Open Mode (`firewall: open`)

No network restrictions. Container can reach any host. Default mode for interactive development.

### Strict Mode (`firewall: strict`)

Default-deny iptables policy initialized at container startup via `init-firewall.sh`.

**Base whitelist (always allowed):**
- `api.anthropic.com` — Claude API
- `statsig.anthropic.com`, `statsig.com` — Claude Code telemetry
- `sentry.io` — Claude Code error reporting
- `registry.npmjs.org` — npm packages
- `github.com`, `api.github.com` — GitHub (full IP range via `/meta` API)
- `gitlab.com`, `registry.gitlab.com` — GitLab + container registry

**Feature domains:** Each installed feature may contribute domains via `/etc/sandbox/firewall.d/<feature>.conf`.

**Project domains:** `allowed_domains` in `sandbox.yaml` adds project-specific domains.

**Firewall initialization order:**
1. Preserve Docker DNS rules
2. Flush existing rules
3. Allow DNS (UDP 53), SSH (TCP 22), localhost
4. Build ipset from: base whitelist + feature domains + project domains
5. Resolve all domains to IPs and add to ipset
6. Set default policy to DROP
7. Allow established connections
8. Allow traffic to ipset destinations
9. REJECT all other outbound traffic
10. Verify by testing a blocked domain and an allowed domain

**Requirements:** `NET_ADMIN` and `NET_RAW` Docker capabilities, added automatically by `sandbox run` when strict mode is detected.

## Repository Structure

```
sandbox-env/
├── base/
│   ├── Dockerfile              # Base image definition
│   ├── init-firewall.sh        # Firewall initialization script
│   ├── firewall-domains.conf   # Base whitelist domains
│   └── entrypoint.sh           # Container entrypoint (starts services, applies firewall)
├── features/
│   ├── python.sh
│   ├── node-extra.sh
│   ├── rust.sh
│   ├── go.sh
│   ├── aws.sh
│   ├── gcloud.sh
│   ├── ollama.sh
│   └── llm.sh
├── cli/
│   └── sandbox                 # Main CLI script (bash)
├── templates/
│   └── Dockerfile.project.tmpl # Template for generating project Dockerfiles
└── docs/
    └── superpowers/
        └── specs/
            └── 2026-04-13-sandbox-env-design.md  # This file
```

## Entrypoint Behavior

The base image uses a custom `entrypoint.sh` that runs at container start:

1. If `firewall: strict` — run `init-firewall.sh` (requires root via sudo)
2. Start any background services (e.g., Ollama if installed and configured)
3. If interactive mode — exec into zsh
4. If headless mode — exec `claude` with provided args

## Testing Strategy

- **Feature scripts:** Each tested individually by building a minimal image with just that feature and verifying the tool is available and functional.
- **Firewall:** Strict mode tested by verifying blocked domains are unreachable and allowed domains are reachable.
- **CLI:** Tested with a sample `sandbox.yaml` that exercises all config options.
- **Integration:** End-to-end test that builds base, builds a project with multiple features, runs the container, and verifies Claude Code works.
