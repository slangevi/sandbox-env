# Claude Code Sandbox

A Docker sandbox for running Claude Code in isolated, per-project customizable containers. Each project declares its tools, languages, and configuration in a `sandbox.yaml` file.

## Prerequisites

**macOS:**
```bash
brew install --cask docker   # or install Docker Desktop from docker.com
brew install yq
# curl ships with macOS
```

**Linux (Debian/Ubuntu):**
```bash
# Docker
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER  # then log out and back in

# yq
sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_$(dpkg --print-architecture)
sudo chmod +x /usr/local/bin/yq

# curl (only if not already installed)
sudo apt-get install -y curl
```

`curl` is required by the sparkyard backend commands (`claude-spark`,
`remote-spark`, `run --spark`, `llm --spark`, `spark-status`) to reach the
gateway.

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

### Mount safety

`sandbox.yaml` is committed and travels with a repo, so `mounts:` entries are
validated before the container starts. (The default `$(pwd):/workspace` mount
used when `mounts:` is omitted is not part of this — it's chosen by whoever
runs the command, not supplied by the config.) A bare `host:` name (e.g.
`host: cache`) is a Docker **named volume**, not a host path, and takes a
different path entirely: none of the host-path validation below applies to
it, because Docker manages the volume itself and it cannot expose any host
file no matter what name it's given.

- **The Docker socket is always refused, with no override.** This is a
  containment check, not just an identity check: mounting the socket's parent
  directory (e.g. `/var/run`) is refused too, because it hands the container
  the same socket at a different path. A directory that merely contains a file
  named `docker.sock` for any other reason is refused the same way — mount a
  subdirectory instead. The socket's location is discovered from `DOCKER_HOST`
  (defaulting to `/var/run/docker.sock`) — see the known limitation below for
  daemons selected via `docker context`.
- **A `..` path component that can't be resolved is always refused, with no
  override.** Docker cleans such paths up lexically when it builds the mount,
  so an unresolved traversal like `/nope/../etc` would otherwise reach the
  host's real `/etc` past every check below.
- **Credential and system paths are refused unless
  `SANDBOX_ALLOW_UNSAFE_MOUNTS=1` is set**, matched by prefix (the path itself
  or anything beneath it): `~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.kube`,
  `~/.config/gcloud`, `~/.docker`, `~/.claude`, `~/.claude.json`,
  `~/.colima`, `~/.orbstack`, `~/.lima`, `/etc`, `/usr`, `/boot`, `/proc`,
  `/sys`, `/run`, `/var/run`, `/root`, `/var/lib/docker`. `/run` and
  `/var/run` are genuinely part of this overridable tier like every other
  entry here, but in practice the override rarely gets a chance to apply to
  them: on almost every system one of the two either is, or contains, the
  Docker socket, and the no-override socket check above runs first and
  refuses a path that is or contains the socket regardless of tier —
  `SANDBOX_ALLOW_UNSAFE_MOUNTS=1` only ever reaches these two entries on a
  system where neither happens to hold the socket.
- **`$HOME`, `/`, and `/home` are refused unless overridden**, matched
  exactly rather than by prefix (prefix-matching `$HOME` would also catch the
  everyday `$(pwd):/workspace` mount for any project living under it, and
  prefix-matching `/home` would catch almost every mount on Linux).

Paths are resolved before matching, and the mount itself is built from that
resolved path, so `../../.ssh` is caught too.

Three things worth knowing that the checks above do **not** cover:

- The no-override socket guarantee holds only for the daemon named by
  `DOCKER_HOST`. If your daemon is selected via `docker context` instead
  (common for rootless Docker at `/run/user/<uid>/docker.sock`, and for
  Rancher Desktop's `~/.rd`), `DOCKER_HOST` is unset, discovery falls back to
  `/var/run/docker.sock`, and the real socket is covered only by the
  *overridable* tier above — or, for `~/.rd`, not listed at all. Export
  `DOCKER_HOST` if you want the no-override guarantee on such a setup.
  (Colima, OrbStack and Lima homes are on the overridable list by name.)

- `host: /var` is allowed. On a system where `/var/run` is a real directory
  rather than a symlink to `/run`, that would expose the Docker socket the
  same way `/var/run` does directly; it also exposes `/var/lib/docker`
  regardless. `/var` isn't on the refusal list because macOS's `mktemp`
  returns paths under `/var/folders/...`, and refusing `/var` outright would
  break ordinary temp-dir mounts on a supported platform.
- `host: /` under an explicit `SANDBOX_ALLOW_UNSAFE_MOUNTS=1` still reaches
  the real Docker socket — just nested under the mount's container path
  (e.g. `<container-path>/run/docker.sock`) instead of at a path this checks
  directly. The no-override socket rule only catches a mount that is or
  directly contains the socket, not one that reaches it transitively through
  an allowed root.

### Config tamper protection

`sandbox.yaml`/`sandbox.yml` is committed and travels with the repo, but the
project root is bind-mounted **read-write** so the agent can work on it — which
means the agent can also edit its own config. Left unchecked, that closes a
loop: a prompt-injected agent edits `sandbox.yaml` (say, turning on
`skip_permissions` or loosening the firewall), and the operator's *next*
`sandbox run` picks up whatever the agent wrote, starting an escalated
container without the operator choosing that.

To close it, the resolved config file is overlaid with a read-only file-level
bind mount inside the container — over the default `/workspace` mount and
over every custom `mounts:` entry that exposes it (a config reachable through
several mounts gets an overlay on each; a named volume, which exposes no host
files, never does). A mount whose *own* source is the config file itself
skips the overlay too, but isn't left writable either: that mount is instead
forced read-only directly, the moment its resolved source is seen to match
the config's own resolved path — the operator's explicit choice of mount is
honoured, it just can never be a way to write to the config. Docker sorts
bind destinations by depth, so this file-level mount always wins over the
enclosing directory mount:

- Writes fail (`:ro`).
- `rm` and rename-over fail with `EBUSY` — a bind mountpoint cannot be
  unlinked.
- Reads still work, so the agent can see its own config and *propose* changes
  in conversation; only the operator, on the host, can actually apply them.

`SANDBOX_ALLOW_WRITABLE_CONFIG=1` is a runner-side escape hatch that skips the
overlay entirely, for a project where the operator genuinely wants the agent
editing its own config. Like `SANDBOX_ALLOW_UNSAFE_MOUNTS`, it's an
environment variable the runner sets, never a `sandbox.yaml` key — the config
must not be able to unprotect itself.

This still leaves one gap the overlay alone can't close: `find_config`
prefers `sandbox.yaml` over `sandbox.yml`, so an agent that can't edit a
protected `sandbox.yml` could just *create* a new `sandbox.yaml` next to it
through the writable workspace mount, silently winning precedence on the
operator's next run. If both files exist, the CLI refuses outright and tells
the operator to inspect whichever one they didn't create themselves.

### claude.args safety

Flags that would change Claude Code's trust, permissions, or credential
routing are refused: `--dangerously-skip-permissions`,
`--allow-dangerously-skip-permissions`, `--no-sandbox`, `--permission-mode`,
`--settings`, `--setting-sources`, `--mcp-config`, `--plugin-dir`,
`--plugin-url`, `--agents`, `--agent`, `--add-dir`, `--allowedTools`,
`--allowed-tools`, `--tools`, `--system-prompt`, `--append-system-prompt`,
`--bare`, `--betas`. Both `--flag value` and
`--flag=value` spellings are caught. This is a hard error, not a silent drop —
dropping a flag that takes a value would leave that value behind as a bare
argument, still passed to `claude`. Use `claude.skip_permissions: true`
instead of `--dangerously-skip-permissions`/`--no-sandbox`. Unrecognized
flags are allowed, with a warning.

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
sandbox run [--headless] [--spark <model>] [-- <cmd>]  Run the container, a command, headless Claude, or a spark-backed headless run
sandbox claude              Launch Claude Code (Anthropic API)
sandbox claude-local <model> Launch Claude Code with a local Ollama model
sandbox claude-spark <model> Launch Claude Code against the sparkyard gateway
sandbox remote              Remote control via claude.ai/code (Anthropic API)
sandbox remote-local <model> Remote control with a local Ollama model
sandbox remote-spark <model> Remote control backed by the sparkyard gateway
sandbox ollama <cmd>        Run Ollama commands in the sandbox
sandbox llm [--spark] [args] Run the llm CLI in the sandbox, or against sparkyard with --spark
sandbox spark-status [model] Show sparkyard backend config (and check a model)
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
sandbox llm -m llama3.2 "Summarize this code"  # fast
sandbox llm -m llama3.2 "Explain this error"   # fast again
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
├── base/                  # Base image (node:24-slim + Claude Code + tools)
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

The `llm` CLI requires a model to be specified. Use `-m` to pick one, or set a default:

```bash
# Use a local Ollama model (free)
sandbox llm -m llama3.2 "Summarize this code"

# Use Claude via API (requires llm API key setup)
sandbox llm -m claude-3.5-sonnet "Explain this error"

# Set a default model so you don't need -m every time
sandbox exec bash -lc 'llm models default llama3.2'

# Now just:
sandbox llm "What does this function do?"

# Pipe input (via sandbox exec for stdin support)
sandbox exec bash -c 'cat /workspace/main.py | llm -m llama3.2 "Review this code"'
```

The default model persists across container restarts (stored in the persistent home volume).

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
- [GPU-Backed Coding with sparkyard](docs/howto/sparkyard-gb10.md) — Route Claude Code to a sparkyard gateway for GPU-backed local models on a DGX Spark
- [Agentic Automation](docs/howto/agentic-automation.md) — Run Claude Code autonomously with strict firewall, timeouts, and resource limits
- [Multi-Model Workflow](docs/howto/multi-model-workflow.md) — Combine Claude API for complex tasks with free local models for quick work
- [Full-Stack Web Development](docs/howto/fullstack-web-development.md) — Python + Node.js sandbox with databases and custom setup
- [Remote Pair Programming](docs/howto/remote-pair-programming.md) — Control Claude Code from any browser or phone via remote control
