# Multi-Model Workflow: Claude Code + Local Ollama Models

Use the right model for each task. Claude Code via the Anthropic API is powerful but costs money per token. Local Ollama models are free and fast, but less capable. This guide shows how to run both from the same sandbox and switch between them deliberately.

**The pattern:** Claude Code does the hard work (architecture decisions, complex refactoring, debugging). The `llm` CLI does the cheap work (summarization, commit messages, quick explanations). You pay for intelligence where it matters and run locally everywhere else.

---

## 1. Prerequisites

- Docker running locally
- An Anthropic API key (for Claude Code and `llm -m claude-*` calls)
- The sandbox base image built: `sandbox build-base`
- `sandbox` aliased or available on your PATH

If you haven't built the base image yet:

```bash
sandbox build-base
```

---

## 2. Creating sandbox.yaml

Create a `sandbox.yaml` in your project directory. You need three features: `python` (required by `llm`), `llm` (Simon Willison's `llm` CLI), and `ollama` (local inference server).

```yaml
name: my-project

features:
  - python
  - llm
  - ollama

mounts:
  - host: .
    container: /workspace

firewall: strict

git:
  user.name: Your Name
  user.email: you@example.com

claude:
  mode: interactive
```

**Feature order matters:** `python` must come before `llm` — `llm` checks for Python at build time and will fail if it isn't present.

**Firewall note:** `firewall: strict` is the default and is recommended. The base firewall whitelist already includes `api.anthropic.com`, so Claude Code and `llm` API calls work without adding it to `allowed_domains`. Ollama runs entirely inside the container and needs no external access. Only add domains to `allowed_domains` for services not already whitelisted (your own APIs, etc.).

---

## 3. Building the Image, Pulling Models, and Authenticating

### Build the project image

```bash
sandbox build
```

This generates a Dockerfile from the template, installs Python + pipx, the `llm` CLI with the `llm-anthropic` and `llm-ollama` plugins, and the Ollama server. The build takes a few minutes the first time.

### Pull local models

Models are stored in a shared Docker volume (`sandbox-ollama-models`) that persists across rebuilds and is available to all projects with the `ollama` feature. Pull models before running the sandbox:

```bash
# A fast, small model good for routine tasks
sandbox models pull llama3.2

# A code-focused model
sandbox models pull codellama

# See what's available
sandbox models list
```

Pulling happens outside the sandbox using the official Ollama image. It can be slow for large models — `llama3.2` is ~2 GB, `codellama` is ~4 GB.

### Authenticate Claude Code

Claude Code stores auth per-project in a named Docker volume (`sandbox-my-project-claude`). Run login once:

```bash
sandbox login
```

This opens the Claude Code browser-based login flow. Your credentials persist in the volume across container restarts.

### Set the Anthropic API key for `llm`

The `llm` CLI needs its own API key configuration. Run this once to store it in the sandbox's persistent home volume:

```bash
sandbox llm keys set anthropic
# Paste your ANTHROPIC_API_KEY when prompted
```

---

## 4. Using Claude Code for Heavy Lifting

`sandbox claude` launches Claude Code in the sandbox container. Use it for tasks where reasoning quality matters: understanding unfamiliar codebases, designing systems, complex refactoring, and debugging subtle bugs.

### Interactive session

```bash
sandbox claude
```

Opens a full Claude Code session. Your `/workspace` is mounted from the current directory. Claude can read, write, and run code.

### Pass a starting prompt

```bash
sandbox claude -p "Refactor the authentication module to use JWT tokens instead of sessions. The current code is in src/auth/. Keep backward compatibility."
```

### Headless mode (non-interactive, scriptable)

```bash
sandbox run --headless -- "Review the changes in src/ and identify any security issues introduced in the last refactor."
```

Headless output is saved to `~/.sandbox/logs/<name>/` and printed to stdout. Check previous runs with `sandbox logs`.

### What to use Claude Code for

- Designing a new module or API from scratch
- Refactoring across multiple files
- Debugging a subtle logic error or race condition
- Understanding code you didn't write
- Generating tests for complex business logic
- Code review before a PR

---

## 5. Using `sandbox llm` for Quick Tasks

`sandbox llm` runs the `llm` CLI inside the container. It's a single command — no interactive session, no waiting for a UI. Pipe text in, get text out.

The `llm` CLI passes arguments directly to the tool, so any `llm` flags work:

```bash
# Use a local Ollama model (free)
sandbox llm -m ollama/llama3.2 "What does a Python context manager do?"

# Pass text via stdin
git diff HEAD~1 | sandbox llm -m ollama/llama3.2 -s "Summarize these changes in plain English"

# Use Claude via API (higher quality)
sandbox llm -m claude-3.5-sonnet "Write a Python function that validates an email address"

# Set a default model so you don't need -m every time
sandbox exec bash -lc 'llm models default ollama/llama3.2'
sandbox llm "What does a Python context manager do?"   # uses default
```

### What to use `sandbox llm` for

- Quick questions that don't need file access
- Summarizing text, diffs, or logs
- Generating commit messages
- Explaining a function or snippet
- One-off transformations (reformat, translate, rewrite tone)

---

## 6. Choosing Between Local and API Models

`sandbox llm` supports two classes of models:

**Local Ollama models (free):** The `llm-ollama` plugin is pre-installed. Use `ollama/<model-name>` where the model name matches what you pulled.

```bash
sandbox llm -m ollama/llama3.2 "Summarize this function"
sandbox llm -m ollama/codellama "Explain what this SQL query does"
```

**Anthropic API models (paid, higher quality):**

```bash
sandbox llm -m claude-3.5-sonnet "Review this function for bugs"
sandbox llm -m claude-3-haiku "Generate a docstring for this function"
```

### When to use local models

- Summarization of text you already understand
- Generating commit messages from a diff
- Reformatting or paraphrasing
- Quick questions with well-known answers
- High-volume tasks where cost adds up

### When to use API models

- You need the answer to be correct, not just plausible
- The task requires reasoning across multiple pieces of information
- Code generation that will go into production
- Anything where a wrong answer has real consequences

### Default model

With no `-m` flag, `llm` uses whichever model is configured as default. To set the default to a local model for cost-free operation:

```bash
sandbox llm models default ollama/llama3.2
```

To set it back to an API model:

```bash
sandbox llm models default claude-3-haiku
```

---

## 7. Example Workflow: Refactor, Summarize, Commit

This is the core pattern — use Claude Code for the hard part, then use local models for the wrap-up.

### Step 1: Claude Code does the refactoring

```bash
sandbox claude
```

Inside the session, ask Claude to refactor a module. It reads the files, makes changes, runs tests. When done, exit the session.

### Step 2: Summarize what changed

```bash
git diff HEAD | sandbox llm -m ollama/llama3.2 -s "Summarize these code changes in 3-5 bullet points. Be specific about what was changed and why."
```

The diff goes in via stdin, the summary comes out. No API cost.

### Step 3: Generate a commit message

```bash
git diff --staged | sandbox llm -m ollama/llama3.2 -s "Write a git commit message for these changes. Use the conventional commits format (type: description). Keep the subject line under 72 characters."
```

Review the output, adjust if needed, then commit.

### Step 4: If the commit message needs to be better

Use a higher-quality model for the commit message when the change is significant:

```bash
git diff --staged | sandbox llm -m claude-3-haiku -s "Write a git commit message for these changes. Conventional commits format. Subject under 72 chars. Add a body paragraph explaining the motivation."
```

Haiku is cheap and much more capable than local models for language tasks.

---

## 8. Interactive Chat with Local Models

`sandbox ollama run <model>` drops you into an interactive Ollama chat session inside the container. Useful for exploratory conversations with a local model without any API cost.

```bash
sandbox ollama run llama3.2
```

You get a `>>> ` prompt. Type your questions, get answers. Exit with `/bye` or Ctrl+D.

```bash
sandbox ollama run codellama
>>> Explain the difference between a mutex and a semaphore
```

This is also useful for verifying that a model is working correctly after pulling it.

To run a non-interactive one-shot query through Ollama directly (rather than via `llm`):

```bash
echo "What is a monoid?" | sandbox ollama run llama3.2
```

---

## 9. Cost Awareness

### What costs money

- `sandbox claude` calls routed to Anthropic's API
- `sandbox llm -m claude-*` calls
- `sandbox llm` with no `-m` flag if the default model is an API model
- `sandbox run --headless` uses Claude Code, which calls the API

### What is free

- `sandbox llm -m ollama/<model>` — runs entirely in the container
- `sandbox ollama run <model>` — runs entirely in the container
- `sandbox claude-local <model>` — routes Claude Code's LLM calls to local Ollama instead of Anthropic

### `sandbox claude-local`: Claude Code UI, local model

`claude-local` is a middle option: you get the full Claude Code interactive experience (file editing, shell execution, tool use) but the underlying LLM calls go to a local Ollama model instead of Anthropic's API.

```bash
sandbox claude-local llama3.2
```

This is free but the model quality is lower. Good for exploration and learning, not recommended for production code changes where correctness matters.

### Rough cost guidelines

| Task | Recommended model | Cost |
|------|-------------------|------|
| Architecture decision | `sandbox claude` (claude-sonnet) | ~$0.01–0.10 |
| Complex refactor | `sandbox claude` | ~$0.05–0.50 |
| Code review | `sandbox llm -m claude-3.5-sonnet` | ~$0.01–0.05 |
| Commit message | `sandbox llm -m ollama/llama3.2` | Free |
| Diff summary | `sandbox llm -m ollama/llama3.2` | Free |
| Quick question | `sandbox llm -m ollama/llama3.2` | Free |
| Log analysis | `sandbox llm -m ollama/codellama` | Free |

These are rough estimates. Actual costs depend on context length and model pricing. Check [anthropic.com/pricing](https://anthropic.com/pricing) for current rates.

### Keep local models lean

Large models use significant RAM. `llama3.2` (3B parameters) is a good default for text tasks — fast, small, good enough for summarization and commit messages. `codellama` is better for code explanation. Pull the smallest model that does the job.

```bash
sandbox models list   # see what you have
sandbox models rm codellama   # remove a model you don't use
```

---

## Quick Reference

```bash
# Setup
sandbox build-base                          # once, globally
sandbox build                               # once per project (or after changing sandbox.yaml)
sandbox login                               # once per project
sandbox llm keys set anthropic              # once per project
sandbox models pull llama3.2               # once, shared across projects

# Claude Code (API, full power)
sandbox claude                              # interactive session
sandbox claude -p "do X"            # with a starting prompt
sandbox run --headless -- "do X"           # non-interactive, logged

# llm CLI (quick tasks)
sandbox llm -m ollama/llama3.2 "question"  # local, free
sandbox llm -m claude-3.5-sonnet "question" # API, quality

# Local Ollama
sandbox ollama run llama3.2                # interactive chat
sandbox models pull codellama              # pull a new model
sandbox models list                        # list pulled models

# Claude Code with local model (free, lower quality)
sandbox claude-local llama3.2

# Cleanup
sandbox stop                               # stop running container
sandbox clean                              # remove image + volumes
sandbox clean-models                       # remove all pulled models
```
