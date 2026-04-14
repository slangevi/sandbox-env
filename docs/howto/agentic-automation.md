# Agentic Automation: Running Claude Code Autonomously in a Sandbox

This guide covers running Claude Code as a fully autonomous agent — no human in the loop, no permission prompts — while keeping it safely contained inside a Docker sandbox with a strict firewall. The key principle: **give Claude the keys to the car, but put the car inside a locked garage.**

---

## 1. Prerequisites

Before you begin:

- Docker is running (`docker info` returns without error)
- The base sandbox image is built: `sandbox build-base`
- The `sandbox` CLI is on your PATH (or use `cli/sandbox` from the repo root)
- You have an Anthropic API key and have authenticated once with `sandbox login` (see section 3)
- On macOS, install GNU coreutils for timeout enforcement: `brew install coreutils`

Verify your setup:

```bash
bash -n cli/sandbox     # syntax-check the CLI
sandbox status          # should return without error
```

---

## 2. Creating `sandbox.yaml` for Headless Autonomous Runs

Drop a `sandbox.yaml` in your project directory. The following is a complete configuration for agentic automation:

```yaml
name: my-project

# Mount your project code into the container as read-write workspace
mounts:
  - host: .
    container: /workspace

# Features to include in the image
features:
  - python          # if your project is Python
  # - node-extra    # if your project is Node/TypeScript

# Extra system packages
packages:
  - ripgrep
  - jq

# Environment variables passed into the container
env:
  PYTHONDONTWRITEBYTECODE: "1"

# Firewall: strict is the default and is required for safe skip_permissions use.
# Only traffic to explicitly listed domains (plus GitHub and api.anthropic.com)
# is allowed. Everything else is blocked at the iptables level.
firewall: strict

# Domains Claude needs to reach for this project. GitHub and api.anthropic.com
# are always allowed when firewall is strict — only add extras here.
allowed_domains:
  - pypi.org            # only if Claude needs to install packages at runtime
  - api.openai.com      # only if the task calls an external API

# Claude Code configuration
claude:
  # headless mode: Claude runs non-interactively, takes a -p prompt argument,
  # and exits when the task is done. No TUI, no permission prompts.
  mode: headless

  # skip_permissions: bypasses all "may I?" prompts. Safe here because the
  # firewall prevents Claude from reaching arbitrary network resources, and
  # the container has no access to your host filesystem beyond the explicit mounts.
  skip_permissions: true

  # timeout: kill the run if it exceeds this duration. Prevents runaway agents.
  # Format: 30s, 10m, 1h
  timeout: 30m

# Resource limits: prevent a runaway task from starving your machine.
resources:
  memory: 4g      # Docker hard memory cap
  cpus: 2         # CPU core limit
```

### What each safety setting does

| Setting | Why it matters |
|---|---|
| `firewall: strict` | Blocks all outbound traffic except GitHub, `api.anthropic.com`, and your `allowed_domains`. Claude cannot phone home to arbitrary servers or exfiltrate code. |
| `skip_permissions: true` | Removes per-action confirmations so the agent runs unattended. The CLI will warn you if you set this without `firewall: strict`. |
| `timeout: 30m` | Enforced by `gtimeout`/`timeout` on the host. The container is killed after the limit regardless of what Claude is doing. |
| `resources.memory` / `resources.cpus` | Docker hard limits. A multi-file refactor that balloons in scope cannot OOM your machine or peg all CPUs. |

### Choosing `allowed_domains`

Start with an empty `allowed_domains` list. GitHub and `api.anthropic.com` are always permitted in strict mode (the firewall init resolves GitHub's IP ranges at startup). Add domains only when the task genuinely requires them:

- Refactoring or writing tests: no extra domains needed
- Fetching data from an external API: add that API's hostname
- Installing Python packages at runtime: add `pypi.org` and `files.pythonhosted.org`

Every domain you add is a hole in the firewall. Keep the list minimal.

---

## 3. Building and Authenticating

**Build the project image** (re-run after changing `features` or `packages`):

```bash
sandbox build
```

**Authenticate Claude Code** for this project. Each project gets its own isolated Docker volume for Claude credentials — this is a one-time step per project:

```bash
sandbox login
```

This opens an interactive container where you log in with your Anthropic account. Credentials are stored in the Docker volume `sandbox-<name>-claude` and are never written to your host filesystem.

Verify authentication persists:

```bash
sandbox claude --version
# or
sandbox run -- claude --version
```

---

## 4. Running Headless Tasks

The `run --headless` subcommand is the entry point for agentic automation. Pass your prompt after `--`:

```bash
sandbox run --headless -- "your prompt here"
```

Claude reads the prompt via `-p`, runs to completion without any interaction, and exits. Output is streamed to the terminal and simultaneously saved to `~/.sandbox/logs/<name>/<timestamp>.log`.

The container is removed after each run (`--rm`). The Claude volume persists across runs so credentials and conversation history are maintained.

**With an explicit timeout override** (CLI flag overrides `sandbox.yaml` for one-off runs is not currently supported — set it in `sandbox.yaml` before running):

```bash
# Adjust timeout in sandbox.yaml, then:
sandbox run --headless -- "refactor src/auth/ to use async/await"
```

**Non-interactive mode without skip_permissions** (Claude will still ask for confirmations via stdin, which will EOF immediately — use skip_permissions for true headless runs):

```bash
# Not recommended for automation — use skip_permissions: true
sandbox run --headless -- "read README.md and summarize it"
```

---

## 5. Viewing Output with `sandbox logs`

The most recent run's output is always available via:

```bash
sandbox logs
```

This prints the log from `~/.sandbox/logs/<name>/` — the most recent `.log` file by timestamp. Each headless run creates a new timestamped file, so previous runs are preserved.

To view all runs for a project:

```bash
ls ~/.sandbox/logs/<name>/
```

To follow a long-running task in a second terminal while it runs:

```bash
tail -f ~/.sandbox/logs/<name>/$(ls -t ~/.sandbox/logs/<name>/ | head -1)
```

---

## 6. Example Use Cases

### Refactor a module to use async/await

```bash
# sandbox.yaml: no extra allowed_domains needed
sandbox run --headless -- "
Refactor src/data_fetcher.py to use async/await throughout.
The module currently uses requests; replace it with httpx in async mode.
Update all callers in src/ that import data_fetcher.
Run the existing tests after refactoring and fix any failures.
Write a brief summary of changes to CHANGES.md.
"
```

### Add comprehensive test coverage

```bash
sandbox run --headless -- "
Analyze src/auth/ and write comprehensive pytest tests covering:
- Happy path for login, logout, token refresh
- Edge cases: expired tokens, invalid credentials, network errors
- At least 80% line coverage as reported by pytest-cov

Place tests in tests/auth/. Use existing test fixtures in tests/conftest.py.
Run pytest at the end and confirm all tests pass.
"
```

### Review TODO comments and create GitHub issues

For this task, Claude needs to call the GitHub API. Add `github.com` and `api.github.com` to `allowed_domains` (GitHub IPs are already in the firewall's ipset, but the domain entry ensures DNS resolution works for the API endpoint):

```yaml
allowed_domains:
  - api.github.com
```

Then set a `GITHUB_TOKEN` in your environment and pass it through:

```yaml
env:
  GITHUB_TOKEN: "${GITHUB_TOKEN}"    # passed from host env at runtime
```

```bash
GITHUB_TOKEN="$(gh auth token)" sandbox run --headless -- "
Find every TODO comment in src/ and tests/.
For each one, create a GitHub issue in the repo at /workspace using gh CLI.
Title the issue with the TODO text. Include file path and line number in the body.
Label each issue 'tech-debt'.
Print a summary of issues created when done.
"
```

---

## 7. Chaining Multiple Headless Runs

For complex workflows, chain independent runs sequentially. Each run starts fresh with the same filesystem state — because the workspace mount persists on your host, changes from one run are visible to the next:

```bash
#!/bin/bash
set -euo pipefail

PROJECT_DIR="/path/to/your/project"
cd "$PROJECT_DIR"

echo "=== Step 1: Add type annotations ==="
sandbox run --headless -- "
Add type annotations to all functions in src/ that are missing them.
Use mypy to verify. Fix any mypy errors introduced.
"

echo "=== Step 2: Generate tests ==="
sandbox run --headless -- "
Write pytest tests for any functions in src/ that have no corresponding test.
Focus on the functions modified in the most recent git commit.
Run pytest and confirm tests pass.
"

echo "=== Step 3: Update documentation ==="
sandbox run --headless -- "
Update the docstrings in src/ to reflect the type annotations added.
Regenerate docs/api.md from the updated docstrings using pdoc.
"

echo "=== All steps complete. Reviewing logs... ==="
sandbox logs
```

**Important**: each run is independent — Claude does not have memory of previous runs unless you write context to a file in `/workspace` and instruct Claude to read it. For multi-step tasks that share context, write an intermediate summary:

```bash
sandbox run --headless -- "
Analyze src/auth/ for security issues. Write your findings to /workspace/security-audit.txt.
"

sandbox run --headless -- "
Read /workspace/security-audit.txt. Fix the issues listed there. 
After fixing, delete security-audit.txt.
"
```

---

## 8. Safety: What the Firewall Blocks and Why skip_permissions Is Safe Here

### What strict mode blocks

The strict firewall uses `iptables` with a default-deny policy. When a container starts, the firewall:

1. Resolves GitHub's published IP ranges (from `api.github.com/meta`) and adds them to an ipset
2. Resolves any `allowed_domains` you specified and adds their IPs
3. Always permits `api.anthropic.com` (required for Claude to function)
4. Restricts DNS to Docker's internal resolver only (no custom DNS servers)
5. Drops all IPv6 traffic
6. Blocks all outbound connections not matching the ipset

**What Claude cannot do in strict mode:**

- Download arbitrary packages or scripts from the internet (beyond explicitly allowed domains)
- Connect to third-party services, webhooks, or data-exfiltration endpoints
- Reach your corporate intranet or other Docker containers not explicitly reachable
- Use an alternative DNS server to resolve blocked domains

**What Claude can do:**

- Read and write files in `/workspace` (your mounted project)
- Call the Anthropic API (required for Claude to operate)
- Access GitHub (for `git push`, `gh` CLI, etc.)
- Access any domain in your `allowed_domains` list

### Why skip_permissions is safe in this context

Outside a sandbox, `--dangerously-skip-permissions` is risky because Claude can run arbitrary commands against your real system, access your full home directory, and make network requests to anything. Inside the sandbox:

- **Filesystem blast radius is limited**: Claude can only touch `/workspace` and its own home directory inside the container. Your host `~/.ssh`, `~/.aws`, and other sensitive directories are not mounted.
- **Network blast radius is limited**: the firewall enforces strict allowlisting at the kernel level. Even if Claude writes and executes a script that tries to `curl` an arbitrary URL, the kernel drops the packet.
- **No sudo**: the container runs as the `node` user. There is no `sudo` installed. Claude cannot escape the firewall by modifying iptables rules.
- **Container is ephemeral**: the container is destroyed after each run (`--rm`). Any damage is contained to the current run's filesystem state.

The CLI enforces one additional check: if you set `skip_permissions: true` without `firewall: strict`, it prints a warning. This is intentional — the two settings are designed to be used together.

---

## 9. Tips

### Choosing timeout values

- **Code refactors on a medium codebase** (10–50 files): `20m`
- **Test generation**: `30m`
- **Multi-file analysis + issue creation**: `45m`
- **Large codebase exploration**: `1h`

If a run times out, `sandbox logs` will show where Claude stopped. You can refine the prompt to scope the task more narrowly, or increase the timeout.

On macOS, timeout enforcement requires `brew install coreutils`. Without it, the CLI warns and runs without a timeout.

### Checking results

After a headless run:

```bash
# View Claude's full output
sandbox logs

# Check what files changed in your workspace
git diff --stat

# Verify tests still pass (if Claude was supposed to keep them green)
cd /path/to/your/project && pytest

# Review the actual diff before committing anything
git diff
```

Never blindly commit the results of a headless run. Review the diff, run your test suite, and use your judgment. Claude is a powerful tool, not an infallible one.

### Resource limit guidance

| Workload | Memory | CPUs |
|---|---|---|
| Small scripts, single-file tasks | `2g` | `1` |
| Medium codebase refactors | `4g` | `2` |
| Large codebases, test generation | `8g` | `4` |
| Unconstrained (use with care) | _(omit)_ | _(omit)_ |

Memory limits are hard caps — Docker will OOM-kill the container if it exceeds the limit. If you see `Killed` in the logs mid-task, increase the memory limit.

### Keeping the image current

If you add new features or packages to `sandbox.yaml`, rebuild before the next headless run:

```bash
sandbox build
# credentials in the Claude volume are unaffected by rebuilds
sandbox run --headless -- "..."
```

### Debugging a failed run

If a headless run fails or produces unexpected output:

1. Check `sandbox logs` for the full trace including any error messages from Claude
2. Temporarily switch to `mode: interactive` in `sandbox.yaml` and run `sandbox claude` to explore the container state manually
3. Use `sandbox run -- bash` (without `--headless`) to open a shell and inspect `/workspace`
4. Switch back to `mode: headless` when ready to re-run autonomously
