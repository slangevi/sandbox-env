# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Project Is

A Docker sandbox for running Claude Code in isolated containers. Two-stage build: a base image (`sandbox-base:latest` from `base/Dockerfile`) and per-project images (`sandbox-<name>:latest` generated from `templates/Dockerfile.project.tmpl`). Orchestrated by a single bash CLI at `cli/sandbox` (~1000 lines).

## Build and Test Commands

```bash
# Build the base Docker image (required before anything else)
cli/sandbox build-base

# Run all tests (each is independent, run from repo root)
tests/test-base.sh           # Base image tools verification
tests/test-cli.sh             # CLI happy-path commands
tests/test-cli-errors.sh      # Error handling and input validation
tests/test-run-modes.sh       # Run modes, exec, readonly mounts
tests/test-volumes.sh          # Volume lifecycle, persistence, cleanup
tests/test-git-config.sh       # Git config from sandbox.yaml
tests/test-headless.sh         # Headless mode and output capture
tests/test-commands.sh         # Convenience commands (claude, ollama, llm, models)
tests/test-yaml-validation.sh  # YAML parsing and validation
tests/test-integration.sh     # End-to-end: build base + project, verify tools

# Test a single feature script in isolation
tests/test-feature.sh python "python --version" "pip --version"

# Syntax check the CLI without running it
bash -n cli/sandbox

# Test firewall (requires Docker NET_ADMIN capability, may be slow)
tests/test-firewall.sh
```

Tests require Docker running. Each test builds/runs/cleans its own containers. `test-integration.sh` is the slowest (~2-3 min, builds python+llm features).

## Architecture

**`cli/sandbox`** — The entire CLI is one bash script. Key internal structure:

- **Shared helpers** (used by multiple commands):
  - `_build_docker_args "$name"` — Builds the global `DOCKER_ARGS` array with volumes, mounts, env vars, git config, firewall, allowed_domains, resource limits. Used by `cmd_run`, `cmd_claude`, `cmd_remote`, `cmd_claude_local`, `cmd_remote_local`.
  - `_read_claude_config` — Sets global `CLAUDE_EXTRA_ARGS` array and `SKIP_PERMISSIONS_FLAG` string from `sandbox.yaml`. Used by same commands.
  - `config_get` / `config_get_default` — YAML reading via Mike Farah's yq v4 (NOT jq-syntax yq).

- **Input validation**: `validate_name`, `validate_feature`, `validate_package`, `validate_model` — regex checks called before any value is used in Docker/filesystem operations.

- **Security layers in the CLI**: env var blocklist (blocks PATH, NODE_OPTIONS, ANTHROPIC_*, proxy vars, etc.), git config key whitelist (only 10 safe keys), `claude.args` blocks `--dangerously-skip-permissions`.

**`base/entrypoint.sh`** — Runs as root on container start. Does: firewall init (if strict), Ollama service start (if installed), persistent volume symlinks (history, gitconfig, .config, .local, npm prefix), git config from SANDBOX_GIT_* env vars, then `exec gosu node "$@"` to drop privileges.

**`base/init-firewall.sh`** — iptables strict-mode setup. Temporarily allows broad DNS for domain resolution during init, then restricts to Docker resolver only. Blocks IPv6. Restricts SSH to ipset destinations. Verifies both blocking and allowing work.

**`templates/Dockerfile.project.tmpl`** — Template with `%%FEATURES%%`, `%%PACKAGES%%`, `%%SETUP%%` placeholders. The CLI reads this, replaces placeholders with generated Dockerfile instructions, writes to a temp dir, and builds.

**`features/*.sh`** — Each is a self-contained install script that runs as root during `docker build`. Convention: `set -euo pipefail`, clean apt lists, optionally write firewall domains to `/etc/sandbox/firewall.d/<name>.conf`. The `llm` feature depends on `python` (checks at runtime). The `ollama` feature writes a marker file at `/etc/sandbox/services/ollama` that the entrypoint checks.

## Key Design Decisions

- **Strict firewall is the default.** All `config_get_default '.firewall' 'strict'` calls default to strict.
- **No sudo in containers.** The entrypoint runs as root and drops to `node` via `gosu`. No sudo package installed.
- **Per-project auth via Docker named volumes** (`sandbox-<name>-claude`), not host `~/.claude` mounts. Each project gets isolated auth.
- **Shared Ollama models** via `sandbox-ollama-models` volume — mounted only when `ollama` is in the features list.
- **The `_build_docker_args` helper is the single source of truth** for Docker run arguments. `cmd_run` and all convenience commands use it. If you add a new volume or env var, add it there.

## When Modifying the CLI

- After any change: `bash -n cli/sandbox` to syntax-check, then `cd tests/fixtures && ../../cli/sandbox build && ../../cli/sandbox run -- echo "works" && ../../cli/sandbox clean`.
- The global arrays `DOCKER_ARGS`, `CLAUDE_EXTRA_ARGS`, and `SKIP_PERMISSIONS_FLAG` are set by helpers and consumed by callers. Don't declare them as `local`.
- yq on this system is Mike Farah's yq v4. Syntax differs from jq-based yq. Use `yq -r '.key'` not `yq -r '.key // empty'`.
- The dispatch `case` statement does `shift` before calling commands that accept args (`claude`, `claude-local`, `remote`, `remote-local`, `ollama`, `llm`, `run`, `build`). Two exceptions: `exec` and `models` receive full `"$@"` and handle the shift internally.

## When Adding a Feature Script

Create `features/<name>.sh` following the contract: `set -euo pipefail`, install non-interactively, `rm -rf /var/lib/apt/lists/*`, optionally write `/etc/sandbox/firewall.d/<name>.conf`. Test with: `tests/test-feature.sh <name> "<verify-command>"`.

For features that need a background service (like Ollama), write a marker to `/etc/sandbox/services/<name>` and add startup logic in `base/entrypoint.sh`.
