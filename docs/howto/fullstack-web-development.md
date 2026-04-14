# Full-Stack Web Development with sandbox-env

This guide walks through setting up a complete full-stack development environment
inside a sandbox container — FastAPI backend, React/TypeScript frontend, PostgreSQL
client, Redis tools, and everything Claude Code needs to work across both halves of
the stack. Nothing runs on your host machine; all tools, runtimes, and dependencies
live inside the image.

## Prerequisites

- Docker Desktop (or Docker Engine) running on your host
- `sandbox` CLI installed and on your PATH (symlink `cli/sandbox` from the repo)
- `yq` v4 (Mike Farah's, not the jq-compatible one): `brew install yq`
- A Claude Code account for authentication

Build the base image once, before anything else:

```bash
sandbox build-base
```

This only needs to be repeated when the base image itself changes.

---

## Project layout

```
my-app/
├── sandbox.yaml          # Sandbox configuration
├── scripts/
│   └── sandbox-setup.sh  # Custom build-time setup script
├── backend/              # FastAPI application
│   ├── pyproject.toml
│   └── src/
└── frontend/             # React + TypeScript application
    ├── package.json
    └── src/
```

---

## sandbox.yaml

Create `sandbox.yaml` in the root of your project:

```yaml
name: my-app

# Python gives you python3, pip, pipx, and python3-venv.
# node-extra adds pnpm, yarn, tsx, and npm-check-updates on top of
# the Node 20 already in the base image.
features:
  - python
  - node-extra

# Extra apt packages installed at image build time.
# postgresql-client gives you psql, pg_dump, etc.
# redis-tools gives you redis-cli.
packages:
  - postgresql-client
  - redis-tools
  - curl
  - jq

# Environment variables available inside the container.
# Do not put secrets here — they go into your .env files inside /workspace.
env:
  NODE_ENV: development
  PYTHONDONTWRITEBYTECODE: "1"
  PYTHONUNBUFFERED: "1"

# Git identity inside the container.
git:
  user.name: Your Name
  user.email: you@example.com
  init.defaultBranch: main

# Mounts map host paths into the container.
# The project root is the primary workspace.
# Additional mounts are shown in the "Multiple mounts" section below.
mounts:
  - host: .
    container: /workspace

# Strict firewall is the default and recommended setting.
# List every external domain your app needs to reach during development.
firewall: strict
allowed_domains:
  - pypi.org
  - files.pythonhosted.org
  - registry.npmjs.org
  - api.stripe.com          # example: payment provider
  - api.sendgrid.com        # example: email provider
  - fonts.googleapis.com    # example: Google Fonts CDN

# Custom setup script runs as root at image build time, after features
# and packages. Use it for project-specific tooling.
setup: ./scripts/sandbox-setup.sh

claude:
  mode: interactive
  skip_permissions: true   # Firewall strict + skip_permissions is the safe combo

# Resource limits keep dev servers from consuming your whole machine.
resources:
  memory: 6g
  cpus: 4
```

---

## Custom setup script

`scripts/sandbox-setup.sh` runs as root during `docker build`. It installs
project-level tools that do not belong in a reusable feature script.

```bash
#!/bin/bash
# scripts/sandbox-setup.sh
# Runs as root during `sandbox build`. Install project-specific tooling here.
set -euo pipefail

echo "=== Installing project-specific tools ==="

# --- Poetry (Python dependency management) ---
# pipx is installed by the python feature, but its bin dir is not yet on
# PATH during image build (PATH is set at container start via /etc/profile.d).
# Call pipx directly from the known location.
PIPX=/usr/local/bin/pipx
$PIPX install poetry==1.8.3

# Make poetry available to the node user.
# pipx installs into /root/.local/bin by default at build time.
# Copy the shim so it is on the system PATH.
cp /root/.local/bin/poetry /usr/local/bin/poetry

# --- Node global tools for the frontend ---
npm install -g @biomejs/biome@1
npm install -g vite@6
npm cache clean --force

# --- Database migration tool (standalone binary) ---
# Example: golang-migrate. Download the Linux amd64 binary directly.
MIGRATE_VERSION="4.18.1"
curl -fsSL \
    "https://github.com/golang-migrate/migrate/releases/download/v${MIGRATE_VERSION}/migrate.linux-amd64.tar.gz" \
    | tar -xz -C /usr/local/bin migrate

chmod +x /usr/local/bin/migrate

echo "=== Project tools installed ==="
```

Make it executable before your first build:

```bash
chmod +x scripts/sandbox-setup.sh
```

---

## Building the project image

```bash
# From your project root (where sandbox.yaml lives):
sandbox build
```

The CLI reads `sandbox.yaml`, generates a Dockerfile from the template, and runs
`docker build`. The resulting image is tagged `sandbox-my-app:latest`.

Rebuild after changing `sandbox.yaml`, adding a feature, or modifying the setup
script. Pass `--no-cache` to force a full rebuild:

```bash
sandbox build --no-cache
```

---

## Authenticating Claude Code

Authentication is stored in a per-project Docker volume (`sandbox-my-app-claude`),
not on your host filesystem. Run login once:

```bash
sandbox login
```

Follow the browser flow. Your credentials survive container restarts because they
live in the named volume, not in the ephemeral container layer.

---

## Launching Claude Code

```bash
sandbox claude
```

This starts the container and drops you into Claude Code's interactive TUI. The
`/workspace` directory inside the container is your project root on the host.

If the container is already running (e.g., you launched a dev server in it), the
command attaches to the running container instead of starting a new one:

```bash
# Second terminal — attaches to the already-running sandbox
sandbox claude
```

---

## Working inside the sandbox

Claude Code runs as the `node` user. Your project root is at `/workspace`.

### Installing Python dependencies (backend)

```bash
# In the Claude Code terminal or via `sandbox exec`:
cd /workspace/backend
poetry install
```

Poetry creates a virtualenv inside the project directory by default. If you want
the venv at a known path:

```bash
poetry config virtualenvs.in-project true
poetry install
# venv is now at /workspace/backend/.venv
```

### Installing Node dependencies (frontend)

```bash
cd /workspace/frontend
pnpm install
```

### Running dev servers

Start the backend from inside the container:

```bash
cd /workspace/backend
poetry run uvicorn src.main:app --host 0.0.0.0 --port 8000 --reload
```

Start the frontend:

```bash
cd /workspace/frontend
pnpm dev --host 0.0.0.0 --port 5173
```

Both bind to `0.0.0.0` so Docker can expose the ports if needed. To expose them
to your host, add port mappings. The sandbox CLI does not manage port forwarding
directly — use `docker run -p` flags via the `env` section's port publishing, or
run the container manually after building. For most Claude Code workflows this is
not required; Claude interacts with the servers over localhost inside the container.

### Database connections

The sandbox container is isolated — it does not have a database server running
inside it by default. Connect to external databases or a separate Docker service:

```bash
# Connect to a PostgreSQL instance running elsewhere on Docker's bridge network
psql postgresql://user:pass@host.docker.internal:5432/mydb
```

Or add your database URL to `env` in `sandbox.yaml`:

```yaml
env:
  DATABASE_URL: postgresql://user:pass@host.docker.internal:5432/mydb
  REDIS_URL: redis://host.docker.internal:6379/0
```

Then inside the container:

```bash
psql "$DATABASE_URL"
redis-cli -u "$REDIS_URL" ping
```

### Running database migrations

```bash
# Alembic (Python)
cd /workspace/backend
poetry run alembic upgrade head

# golang-migrate (installed by the setup script)
migrate -path /workspace/migrations -database "$DATABASE_URL" up
```

### Running tests

Backend:

```bash
cd /workspace/backend
poetry run pytest -v
# Or with coverage:
poetry run pytest --cov=src --cov-report=term-missing
```

Frontend:

```bash
cd /workspace/frontend
pnpm test            # Vitest
pnpm test:e2e        # Playwright (if configured)
```

Type-check and lint:

```bash
cd /workspace/frontend
pnpm tsc --noEmit
pnpm biome check src/
```

---

## Using `sandbox exec`

While the sandbox container is running, `sandbox exec` runs a one-off command
without attaching interactively. Useful for CI-style checks from a second terminal
on your host:

```bash
# Run the backend test suite
sandbox exec poetry run pytest /workspace/backend -v

# Check database connectivity
sandbox exec psql "$DATABASE_URL" -c "SELECT version();"

# Tail backend logs written to a file inside the container
sandbox exec tail -f /workspace/backend/app.log

# Run a database migration
sandbox exec migrate -path /workspace/migrations -database "$DATABASE_URL" up 1

# List installed Python packages
sandbox exec poetry run pip list
```

Note: `sandbox exec` requires the container to be running (`sandbox run` or
`sandbox claude` must have been called first in another terminal).

---

## Multiple mounts

The `mounts` list in `sandbox.yaml` supports any number of host paths. Use this
to bring shared libraries, reference datasets, or credentials into the container
without baking them into the image.

```yaml
mounts:
  # Primary project workspace
  - host: .
    container: /workspace

  # Shared internal Python library used by multiple projects
  - host: ~/code/shared/mycompany-core
    container: /opt/mycompany-core
    readonly: false       # writable so Claude can edit it

  # Large reference dataset — readonly to prevent accidental writes
  - host: ~/data/reference-datasets/geolocation
    container: /data/geolocation
    readonly: true

  # SSL certificates for local HTTPS (readonly — never modify certs)
  - host: ~/certs/local
    container: /etc/ssl/local
    readonly: true
```

Paths starting with `~` expand to your home directory. Paths starting with `.`
are resolved relative to the directory containing `sandbox.yaml`.

After changing mounts, stop the container and restart it — mounts are applied at
container start, not dynamically:

```bash
sandbox stop
sandbox claude
```

---

## Tips

### Resource limits for dev servers

FastAPI's `--reload` and Vite's HMR (hot module replacement) are file-system
intensive. Without limits, they can consume significant CPU and memory. The
`resources` section in `sandbox.yaml` sets hard limits:

```yaml
resources:
  memory: 6g    # Docker format: 512m, 2g, 6g
  cpus: 4       # Fractional values work: 0.5, 1.5, 4
```

If you notice the container being OOM-killed during large builds (e.g., `pnpm install`
on a monorepo), increase `memory`. If the host feels unresponsive during builds,
reduce `cpus`.

### Readonly mounts for reference data

Large datasets, seed files, and reference corpora should always be mounted
readonly. This prevents Claude from accidentally modifying source data and avoids
unnecessary Docker layer writes:

```yaml
mounts:
  - host: ~/data/seeds
    container: /workspace/data/seeds
    readonly: true
```

Inside the container, writes to `/workspace/data/seeds` raise a permission error,
making misuse immediately visible.

### Firewall `allowed_domains` for external APIs

The strict firewall blocks all outbound traffic by default. Add every domain your
application needs to contact during development. Be specific — avoid adding
wildcard-style entries like entire CDNs when only one subdomain is needed:

```yaml
firewall: strict
allowed_domains:
  # Python and Node package registries (needed for install steps)
  - pypi.org
  - files.pythonhosted.org
  - registry.npmjs.org

  # Your application's external API dependencies
  - api.openai.com
  - api.stripe.com
  - api.sendgrid.com
  - hooks.slack.com

  # OAuth providers (if your app authenticates with them)
  - accounts.google.com
  - github.com
```

The firewall applies to the running container, not the image build. Package
installation during `sandbox build` runs outside the firewall context and always
has full network access.

### Keeping the container alive for multiple sessions

By default, `sandbox claude` exits when Claude Code exits. To keep the container
alive for multiple `sandbox exec` calls, use `sandbox run` with a long-running
command:

```bash
# Start the container with a shell, leave it running in the background
sandbox run -- sleep infinity
```

Then use `sandbox claude` (which detects the running container and attaches) and
`sandbox exec` freely until you call `sandbox stop`.

### Persisted state across restarts

The following survive container restarts automatically (stored in named Docker
volumes):

- Claude Code authentication and project state (`sandbox-my-app-claude`)
- Shell history, `.gitconfig`, `~/.config`, `~/.local` (`sandbox-my-app-home`)
- npm global installs, e.g. MCP servers you install from within Claude (`sandbox-my-app-home`)
- pip/pnpm caches (`sandbox-my-app-cache`)

Poetry virtualenvs live in `/workspace` (on your host mount) and persist
naturally. Node `node_modules` are also inside `/workspace` and persist.

To wipe everything and start fresh:

```bash
sandbox clean    # removes image + all three named volumes for this project
sandbox build    # rebuild from scratch
sandbox login    # re-authenticate
```
