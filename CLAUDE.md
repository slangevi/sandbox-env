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
tests/test-spark.sh            # sparkyard gateway backend: config, preflight, dry-run argument wiring
tests/test-yaml-validation.sh  # YAML parsing and validation
tests/test-config-trust.sh     # Config-trust validators: env key injection, claude.args blocklist, mount safety
tests/test-cli-integration.sh  # Every CLI command end-to-end (start, exec, stop lifecycle)
tests/test-entrypoint.sh       # Entrypoint: PATH, volumes, permissions, services (slow)
tests/test-integration.sh     # End-to-end: build base + project, verify tools

# Test a single feature script in isolation
tests/test-feature.sh python "python --version" "pip --version"

# Syntax check the CLI without running it
bash -n cli/sandbox

# Test firewall (requires Docker NET_ADMIN capability, may be slow)
tests/test-firewall.sh
```

Tests require Docker running. Each test builds/runs/cleans its own containers. `test-integration.sh` is the slowest (~2-3 min, builds python+llm features). `tests/test-spark.sh` additionally requires host `python3` — it's the only test that runs a local stub gateway (`http.server`) instead of the real sparkyard stack.

## Architecture

**`cli/sandbox`** — The entire CLI is one bash script. Key internal structure:

- **Shared helpers** (used by multiple commands):
  - `_build_docker_args "$name" [container]` — Builds the global `DOCKER_ARGS` array with volumes, mounts, env vars, git config, firewall, allowed_domains, resource limits. Used by `cmd_run`, `cmd_start`, `cmd_claude`, `cmd_remote`, `cmd_claude_local`, `cmd_remote_local`, `cmd_claude_spark`, `cmd_remote_spark`, `cmd_llm`, `cmd_ollama`.
  - `_read_claude_config` — Sets global `CLAUDE_EXTRA_ARGS` array and `SKIP_PERMISSIONS_FLAG` string from `sandbox.yaml`. Used by every command that passes args to `claude`: `cmd_run`, `cmd_remote`, `cmd_claude`, `cmd_claude_local`, `cmd_remote_local`, `cmd_claude_spark`, `cmd_remote_spark`. Not `cmd_ollama`/`cmd_llm`/`cmd_start`, which call `_build_docker_args` but never invoke the `claude` binary.
  - `config_get` / `config_get_default` — YAML reading via Mike Farah's yq v4 (NOT jq-syntax yq).
  - `_load_spark_env` / `_apply_spark_backend` / `_spark_preflight` / `_spark_host_url` / `_spark_run` — sparkyard gateway backend, used by `cmd_spark_status`, `cmd_claude_spark`, `cmd_remote_spark`, and the `--spark` paths of `cmd_run` and `cmd_llm`. `_load_spark_env` reads (never `source`s) `${XDG_CONFIG_HOME:-$HOME/.config}/sandbox/sparkyard.env` for `SPARKYARD_URL` / `LITELLM_MASTER_KEY` / `SPARKYARD_MODEL`; a real env var of the same name always wins over the file. `_spark_host_url` rewrites `host.docker.internal` to `localhost` because that alias only resolves inside the container, not on the host doing the preflight check. `_spark_preflight` checks gateway reachability and that a given model is actually served before anything launches. `SANDBOX_DRY_RUN=1` makes `_spark_run` print the `docker` argv it would execute (master key masked) instead of running it — this is how `tests/test-spark.sh` asserts argument wiring without Docker; the preflight check still runs first, dry-run or not.

- **Input validation**: `validate_name`, `validate_feature`, `validate_package`, `validate_model` — regex checks called before any value is used in Docker/filesystem operations.

- **Security layers in the CLI**: env var blocklist (blocks PATH, NODE_OPTIONS,
  ANTHROPIC_*, proxy vars, etc.), git config key whitelist (only 10 safe keys),
  and a config-trust section holding three validators — `validate_env_key`
  (env names must be identifier-shaped — letters/digits/`_`, plus `.`/`-`
  after the first character — so a YAML key cannot be evaluated as a yq
  expression; the lookup also uses `strenv`), `validate_claude_arg` (refuses
  privilege- and credential-affecting flags as a hard error, warns on unknown
  ones), and `validate_mount` (always refuses the Docker socket; refuses
  credential and system paths unless `SANDBOX_ALLOW_UNSAFE_MOUNTS=1`).
  They are called from `_build_docker_args` and `_read_claude_config`. Every
  container-launching command already calls `_build_docker_args`; every
  command that passes args to `claude` already calls `_read_claude_config` —
  so a new command in either category cannot forget to validate.
- **Container names**: `_build_docker_args <name> [container]` names the
  container `sandbox-<name>` unless told otherwise; `cmd_run`'s headless path
  passes `sandbox-<name>-headless` so a headless run (e.g. one started by the
  Matrix bridge) can coexist with the interactive container and be stopped
  without touching it. Volumes are always the project's. `cmd_stop` stops both
  names.
- **Config tamper protection**: `_build_docker_args` overlays the resolved
  `sandbox.yaml`/`.yml` with a read-only file bind over every container path
  that exposes it (default `/workspace` mount and each ancestor-matching
  `mounts:` entry; never a named volume), so a prompt-injected agent cannot
  edit, delete, or replace the config that governs the operator's next run —
  reads still work. `SANDBOX_ALLOW_WRITABLE_CONFIG=1` is the runner-side
  escape hatch (never a config key). `find_config` separately refuses when
  both `sandbox.yaml` and `sandbox.yml` exist, closing the precedence hole the
  overlay alone can't (an agent creating a new `sandbox.yaml` next to a
  protected `sandbox.yml`).
- **`cmd_trust`** writes `.projects["/workspace"].hasTrustDialogAccepted = true`
  into `.claude.json` in the project's Claude volume by running `jq` inside
  `sandbox-base:latest` with the volume mounted (the host may not have `jq`).
  Idempotent. Headless callers (the Matrix bridge) run it after `sandbox build`.

**`base/entrypoint.sh`** — Runs as root on container start. Does: firewall init (if strict), Ollama service start (if installed), persistent volume symlinks (history, gitconfig, .config, .local, npm prefix), git config from SANDBOX_GIT_* env vars, then `exec gosu node "$@"` to drop privileges.

**`base/init-firewall.sh`** — iptables strict-mode setup. Temporarily allows broad DNS for domain resolution during init, then restricts to Docker resolver only. Allowed-domain entries that are IPv4 literals or CIDRs skip `dig` and go straight into the ipset (the CLI's `allowed_domains` regex admits both). Blocks IPv6. Restricts SSH to ipset destinations. Verifies both blocking and allowing work.

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
- The dispatch `case` statement does `shift` before calling commands that accept args (`claude`, `claude-local`, `claude-spark`, `remote`, `remote-local`, `remote-spark`, `ollama`, `llm`, `run`, `build`, `spark-status`). Two exceptions: `exec` and `models` receive full `"$@"` and handle the shift internally.

## When Adding a Feature Script

Create `features/<name>.sh` following the contract: `set -euo pipefail`, install non-interactively, `rm -rf /var/lib/apt/lists/*`, optionally write `/etc/sandbox/firewall.d/<name>.conf`. Test with: `tests/test-feature.sh <name> "<verify-command>"`.

For features that need a background service (like Ollama), write a marker to `/etc/sandbox/services/<name>` and add startup logic in `base/entrypoint.sh`.
