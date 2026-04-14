# Python Development with the Sandbox

This guide walks through setting up and using the sandbox for a Python project from scratch. We'll use a realistic example — a small FastAPI web service — but the same steps apply to any Python codebase: data pipelines, CLI tools, scripts, whatever you're working on.

## Prerequisites

You need:
- sandbox-env cloned and the base image built
- The `sandbox` alias set up
- Docker running

If you haven't done those yet, follow the [Quick Start in the README](../../README.md#quick-start). Come back when `sandbox build-base` has finished.

## The example project

We'll work with a project called `price-api` — a FastAPI service that fetches product prices from a database. The structure looks like this:

```
price-api/
├── src/
│   └── price_api/
│       ├── __init__.py
│       ├── main.py
│       ├── models.py
│       └── db.py
├── tests/
│   ├── conftest.py
│   └── test_prices.py
├── pyproject.toml
└── sandbox.yaml      ← we'll create this
```

## Step 1: Create sandbox.yaml

In your project root, create `sandbox.yaml`. Here's a solid starting point for a Python project:

```yaml
name: price-api

features:
  - python

packages:
  - curl
  - httpie

git:
  user.name: Your Name
  user.email: you@example.com
  init.defaultBranch: main

firewall: strict

claude:
  mode: interactive
```

A few notes:
- `features: [python]` installs Python 3, pip, venv, dev headers, and pipx. It also whitelists PyPI (`pypi.org` and `files.pythonhosted.org`) through the strict firewall automatically.
- `packages` are regular apt packages installed on top. `curl` and `httpie` are handy for testing API endpoints from a shell.
- The `git` block sets your identity inside the container. Without this, commits will fail with "Please tell me who you are."
- `firewall: strict` is the default, but being explicit is good practice. It means only whitelisted domains (Claude API, GitHub, PyPI, npm) are reachable.

If your project calls external APIs during development or tests, add them to `allowed_domains`:

```yaml
firewall: strict
allowed_domains:
  - api.stripe.com
  - mycompany.internal.com
```

## Step 2: Build the project image

From your project root (where `sandbox.yaml` lives):

```bash
sandbox build
```

This generates a Dockerfile from the template, layers Python on top of the base image, and tags it `sandbox-price-api:latest`. It takes 30-60 seconds the first time. Subsequent builds are faster because Docker caches the layers.

If you add or change features or packages later, re-run `sandbox build`. You don't need to rebuild when you edit Python code — your project directory is mounted live into the container.

## Step 3: Authenticate Claude Code

Each project has its own isolated auth volume. Authenticate once:

```bash
sandbox login
```

This drops you into a temporary container running `claude login`. Follow the browser flow. When it finishes, your session is saved in the `sandbox-price-api-claude` Docker volume and persists across all future container runs for this project.

You only need to do this once per project. Running `sandbox clean` removes the auth volume, so you'd need to re-authenticate after that.

## Step 4: Launch Claude Code

```bash
sandbox claude
```

Claude Code starts up inside the container with `/workspace` pointed at your project root. Everything you see in your editor is also visible to Claude — it can read, edit, and create files directly.

If a container is already running for this project (say, from a previous terminal), `sandbox claude` attaches to it rather than starting a new one.

### One-off prompts

Skip the interactive session and give Claude a single task:

```bash
sandbox claude -p "Add input validation to the /prices endpoint and write tests for it"
```

This is useful for quick targeted tasks where you don't need back-and-forth.

## Step 5: Set up your Python environment

Once inside Claude Code (or in a shell via `sandbox run`), your typical Python workflow works as expected.

### Install dependencies with pip

```bash
# From a shell inside the sandbox
sandbox run -- pip install -r requirements.txt

# Or if using pyproject.toml with pip-installable extras
sandbox run -- pip install -e ".[dev]"
```

The pip cache is stored in the `sandbox-price-api-cache` volume, so packages you install survive container restarts without re-downloading. This makes subsequent installs fast.

### Use a virtual environment

The `python` feature includes `python3-venv`. If your project uses a venv (common with tools like Poetry or if you want strict isolation from system Python):

```bash
sandbox run -- python -m venv /workspace/.venv
sandbox run -- /workspace/.venv/bin/pip install -r requirements.txt
```

Then in your subsequent commands or via Claude, reference `/workspace/.venv/bin/python` directly. If you want the venv active automatically, add it to your setup script.

### Install linters and formatters

You can install Python tools system-wide (they'll persist in the cache volume) or ask Claude to handle it:

```bash
sandbox run -- pip install black mypy pytest pytest-asyncio httpx
```

Or put them in `pyproject.toml` or `requirements-dev.txt` and install via the above.

## Step 6: Common workflows

### Running tests

```bash
# Run the full test suite
sandbox run -- pytest

# Run a specific test file
sandbox run -- pytest tests/test_prices.py -v

# Run tests matching a name pattern
sandbox run -- pytest -k "test_price_lookup" -v

# Stop on first failure
sandbox run -- pytest -x

# With coverage
sandbox run -- pytest --cov=src/price_api --cov-report=term-missing
```

If tests are failing, Claude is right there to help debug. Just describe what you're seeing or paste the output.

### Running the development server

FastAPI (or Flask, Django, etc.) works the same way:

```bash
sandbox run -- uvicorn src.price_api.main:app --reload --host 0.0.0.0 --port 8000
```

To reach it from your host machine, expose the port. The cleanest way is to add a port mapping in `sandbox.yaml` via a custom setup, or run it manually with `docker run -p 8000:8000`. For quick testing, you can also hit the API from inside the container using `httpie`:

```bash
sandbox exec http GET localhost:8000/prices/42
```

`sandbox exec` runs a command in the already-running container, so you can have the server running in one terminal and test from another.

### Type checking with mypy

```bash
sandbox run -- mypy src/price_api --strict
```

### Formatting with black

```bash
sandbox run -- black src/ tests/
```

### Checking for import issues or common bugs

```bash
sandbox run -- python -c "from price_api.main import app; print('import OK')"
```

### Opening a shell

Sometimes you want to poke around directly:

```bash
sandbox run -- bash
```

This drops you into a bash shell in the container as the `node` user. Your project is at `/workspace`. From there you can run Python interactively, inspect the filesystem, check environment variables, etc.

If you already have the container running (e.g. Claude Code is open in another terminal):

```bash
sandbox shell
```

This opens a shell in the already-running container.

## Step 7: Useful patterns

### Letting Claude run tests autonomously

For longer refactoring sessions, enable `skip_permissions` so Claude doesn't need to ask before running commands. Pair it with a timeout so it doesn't run forever:

```yaml
claude:
  mode: interactive
  skip_permissions: true
  timeout: 30m
```

The strict firewall is still active, so Claude can reach PyPI, GitHub, and the Claude API, but nothing else.

### Headless mode for CI-style runs

Run a one-off task without sitting in front of it:

```bash
sandbox run --headless -- "Run the test suite and fix any failing tests. Use pytest for discovery."
```

Output is captured to `~/.sandbox/logs/price-api/<timestamp>.log`. View the last run with:

```bash
sandbox logs
```

This is handy for kicking off a longer task (refactoring, test writing) and coming back to the result.

### Persisting pip packages across rebuilds

The `sandbox-price-api-cache` volume holds `~/.cache/pip`. This means pip packages you install don't need to re-download when the container is restarted.

However, if you run `sandbox build` to rebuild the image (e.g. after changing features), the cache volume is not cleared — pip still benefits from the cached wheels.

If you run `sandbox clean`, it removes all project volumes including the cache. You'll be starting fresh.

### Sharing a read-only data directory

If you have datasets or fixtures outside the project root:

```yaml
mounts:
  - host: .
    container: /workspace
  - host: ~/datasets/prices
    container: /data/prices
    readonly: true
```

Claude and your tests can then read from `/data/prices` without being able to modify the originals.

### Using pip-tools for reproducible installs

If your project uses `pip-tools` (`pip-compile`), the workflow is:

```bash
# Compile requirements.txt from requirements.in
sandbox run -- pip-compile requirements.in

# Install the locked dependencies
sandbox run -- pip-sync requirements.txt
```

### Environment variables for dev settings

Pass non-secret configuration through `sandbox.yaml`:

```yaml
env:
  DATABASE_URL: postgresql://localhost/prices_dev
  LOG_LEVEL: debug
  ENVIRONMENT: development
```

These show up as regular environment variables inside the container. Don't put secrets here — `sandbox.yaml` is meant to be committed to the repo.

## Troubleshooting

**"No module named X" inside the container but it's in requirements.txt**
The package was probably installed in a different container run that didn't persist it. Either add it to your pyproject.toml/requirements.txt and run `pip install -e .` so it's installed at the project level, or make sure you're always installing into the same location that's on `PYTHONPATH`.

**Tests pass locally but fail inside the sandbox**
Check if the tests depend on external services (databases, APIs). The strict firewall blocks outbound connections by default. If your tests call an external API, add it to `allowed_domains`, or use mocks.

**pip is slow on the first run after `sandbox build`**
The cache volume persists across container restarts but is empty after the first `sandbox build`. Let the first install finish — subsequent runs will be fast.

**"Permission denied" when writing files**
The container runs as the `node` user. Your project files (mounted from the host) need to be writable by that user. On macOS with Docker Desktop this usually works transparently. If you hit permission issues, check the file ownership on the host.

**Claude can't reach a PyPI package**
This shouldn't happen since `pypi.org` and `files.pythonhosted.org` are automatically whitelisted by the `python` feature. If you're installing from a private index or a git URL, add those domains to `allowed_domains` or switch to `firewall: open` temporarily.

**"sandbox.yaml must have a 'name' field"**
You ran `sandbox build` or `sandbox claude` from the wrong directory, or forgot to add `name:` to your sandbox.yaml. The file needs to be in the current directory and must have a name.
