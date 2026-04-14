# Local LLM Coding with Claude Code and Ollama

Run Claude Code fully offline — no API key, no cloud calls, no data leaving your machine. This guide walks you through setting up a sandbox project that uses a local Ollama model as the AI backend.

## Prerequisites

- sandbox-env cloned and on your `$PATH` (`cli/sandbox` aliased as `sandbox`)
- Base image built: `sandbox build-base`
- Docker running with enough RAM for your chosen model (8 GB free is a reasonable minimum for a 7B model; 16 GB+ for anything larger)

## 1. Create sandbox.yaml

In your project directory, create a `sandbox.yaml`. Include the `ollama` feature. If you also want the `llm` CLI for quick one-off prompts, add `python` and `llm` as well:

```yaml
name: my-project

features:
  - ollama      # required for local models
  - python      # required if you want llm
  - llm         # Simon Willison's llm CLI with Ollama plugin

mounts:
  - host: .
    container: /workspace

firewall: strict   # default — Ollama runs inside the container, no outbound calls needed
```

The `ollama` feature installs the Ollama server inside the container and registers a service marker so it starts automatically on container launch.

## 2. Build the project image

```bash
sandbox build
```

This bakes Ollama (and optionally the `llm` CLI) into your project image. You only need to do this once, or after changing `sandbox.yaml`.

## 3. Pull models

Models are downloaded to a shared Docker volume (`sandbox-ollama-models`) that all your sandbox projects can access. Pull once, use everywhere.

```bash
sandbox models pull qwen2.5-coder:7b
```

**Recommended models for coding:**

| Model | Pull tag | Notes |
|---|---|---|
| Qwen 2.5 Coder 7B | `qwen2.5-coder:7b` | Strong coding, fast, fits in 8 GB RAM |
| Qwen 2.5 Coder 14B | `qwen2.5-coder:14b` | Better reasoning, needs ~12 GB RAM |
| Gemma 3 12B | `gemma3:12b` | Google's general-purpose model, good at instruction following |
| CodeLlama 13B | `codellama:13b` | Meta's code-focused model |
| Llama 3.2 3B | `llama3.2:3b` | Very fast, fits in 4 GB, good for quick tasks |
| DeepSeek Coder V2 | `deepseek-coder-v2:16b` | Excellent at code; needs 16 GB+ RAM |

**Context window requirement:** Claude Code requires at least 64k context. All models listed above support this. If you try a model from elsewhere, verify it exposes a context length of 64k or more — otherwise Claude Code will refuse to start. You can check available models and their context sizes at [ollama.com/search](https://ollama.com/search?c=cloud).

Pull multiple models at once:

```bash
sandbox models pull qwen2.5-coder:7b gemma3:12b
```

## 4. Launch Claude Code with a local model

From your project directory (where `sandbox.yaml` lives):

```bash
sandbox claude-local qwen2.5-coder:7b
```

This starts the sandbox container, launches Ollama inside it, and connects Claude Code to it via Ollama's Anthropic-compatible API endpoint. No API key is used — the `ANTHROPIC_AUTH_TOKEN` is set to a placeholder value and `ANTHROPIC_BASE_URL` points to `localhost:11434` inside the container.

Once inside, Claude Code works exactly as it does with the Anthropic API: file editing, terminal commands, MCP tools, all of it — just powered by your local model.

## 5. Comparing models

The fastest way to compare models is to open separate terminal tabs, each running a different one against the same project:

```bash
# Tab 1
sandbox claude-local qwen2.5-coder:7b

# Tab 2 (if the container from tab 1 is already running, this execs into it with a different model)
sandbox claude-local gemma3:12b
```

If the container is already running (from tab 1), `claude-local` execs into it rather than starting a new one, so both sessions share the same container state and workspace. To test models in complete isolation, stop the container first (`sandbox stop`) before launching with a different model.

Practical comparison tips:

- Give each model the same task ("refactor this function", "add tests for this module") and compare output quality and speed.
- Smaller models (3B–7B) are noticeably faster for simple completions; larger models (13B+) handle complex multi-file reasoning better.
- If a model feels slow, try a quantized variant: `qwen2.5-coder:7b-q4_K_M` uses less memory and is faster on CPU.

## 6. Managing models with `sandbox ollama`

`sandbox ollama` runs any Ollama command inside your sandbox container. Use it to inspect and manage the model library:

```bash
# List locally stored models (same as sandbox models list)
sandbox ollama list

# Check which model is running
sandbox ollama ps

# Pull a model (equivalent to sandbox models pull)
sandbox ollama pull codellama:13b

# Remove a model to free disk space
sandbox ollama rm codellama:13b
```

The `sandbox models` subcommands are a thin convenience wrapper around `sandbox ollama`. For anything not covered by `models pull / list / rm`, reach for `sandbox ollama` directly.

## 7. Quick prompts with `sandbox llm`

If you added `python` and `llm` to your `sandbox.yaml`, you can send one-off prompts to a local model without entering an interactive Claude Code session:

```bash
# Prompt a local Ollama model
sandbox llm -m ollama/qwen2.5-coder:7b "What does this function do?"

# Pipe file contents in
sandbox exec bash -c 'cat /workspace/main.py | llm -m ollama/qwen2.5-coder:7b "Review this code"'

# Compare a local model against Claude (when you have an API key set up too)
sandbox llm -m claude-3-5-sonnet "Explain this error"
sandbox llm -m ollama/gemma3:12b "Explain this error"
```

The `llm` CLI is useful for scripting and quick experiments — pipe in a file, get a response, pipe it somewhere else. It is not a replacement for `claude-local`, which gives you the full interactive Claude Code experience.

## 8. Storage and cleanup

Models are stored in a single shared Docker volume (`sandbox-ollama-models`), separate from your project volumes. Every project with the `ollama` feature draws from this shared pool — pull a model once and all your projects can use it.

```bash
# See what is downloaded and how much space it uses
sandbox models list
docker system df -v | grep sandbox-ollama-models

# Remove a specific model you no longer need
sandbox models rm codellama:13b

# Wipe all downloaded models and reclaim the disk space
sandbox clean-models
```

`sandbox clean` removes your project's image and volumes but does **not** touch the shared models volume. Your downloaded models survive project rebuilds. Only `sandbox clean-models` removes them.

## Summary

| Goal | Command |
|---|---|
| Pull a model | `sandbox models pull qwen2.5-coder:7b` |
| Launch Claude Code offline | `sandbox claude-local qwen2.5-coder:7b` |
| List downloaded models | `sandbox models list` |
| Quick prompt via llm CLI | `sandbox llm -m ollama/qwen2.5-coder:7b "..."` |
| Run any Ollama command | `sandbox ollama <cmd>` |
| Free up model disk space | `sandbox clean-models` |

The key selling point is simple: fully offline AI-assisted coding, no API costs, no data leaving your machine.
