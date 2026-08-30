# GPU-Backed Coding on a DGX Spark with sparkyard

If you're running sandbox-env on an NVIDIA DGX Spark (or any box where GPU
inference already lives behind a [sparkyard](https://github.com/slangevi/sparkyard)
gateway), point Claude Code at that gateway instead of the in-container
`ollama` feature. This guide covers the `claude-spark`, `remote-spark`,
`run --spark`, `llm --spark`, and `spark-status` commands, and the real
limitations you'll hit using them.

## Why not the ollama feature on this machine

- sandbox-env has no GPU plumbing: there is no `--gpus`, no NVIDIA container
  runtime, and no CUDA reference anywhere in `cli/sandbox`, `base/Dockerfile`,
  `templates/`, or `features/ollama.sh`.
- So the in-container `ollama` feature runs CPU-only. On a DGX Spark it also
  competes for the same 128 GB of unified memory that sparkyard's `launch.py`
  crash-guard exists to protect.
- sparkyard already serves every model behind one LiteLLM gateway. The spark
  backend routes Claude Code (or the `llm` CLI) to that gateway instead of
  starting a second, CPU-bound model server inside the sandbox.

## Prerequisites

- A running sparkyard stack (`sparkyard start`), with its LiteLLM gateway
  reachable — default `http://host.docker.internal:14000`.
- The sandbox-env base image built: `sandbox build-base`.
- A project image built from your `sandbox.yaml`: `sandbox build`. For
  `claude-spark`, `remote-spark`, and `run --spark`, the spark backend needs
  nothing added to `features:` — Claude Code ships in the base image and the
  model runs outside the container, behind the gateway. `llm --spark` is the
  exception: it still needs the `python` and `llm` features, same as plain
  `sandbox llm` — see the `llm --spark` section below.
- No firewall changes needed **if the gateway runs on this same Docker
  host, on Linux**: `firewall: strict` (the default) already permits
  traffic to the Docker host gateway IP, which is what
  `host.docker.internal` resolves to inside the container. A gateway on a
  different machine (e.g. `SPARKYARD_URL=http://dgx.local:14000`) is a
  different story: `init-firewall.sh` only opens egress to the container's
  own default-route gateway, so under `firewall: strict` a LAN host is
  dropped unless you add it to `allowed_domains` in `sandbox.yaml`. Note that
  doing so is itself an `allowed_domains` entry, which the Firewall
  requirement section below refuses by default — see there for the
  `SPARKYARD_ALLOW_UNSAFE_FIREWALL=1` override you'll need on top of this.

## Firewall requirement

Every spark command that actually launches a container (`claude-spark`,
`remote-spark`, `run --spark`, `llm --spark`) refuses to run unless the
project's `sandbox.yaml` has `firewall: strict` and no `allowed_domains`
entries. The sparkyard master key is a LiteLLM gateway **ADMIN**
credential — it can mint new API keys and read every request log — so
shipping it into a sandbox with weakened egress control (an open firewall,
or an allowed domain an attacker could influence) is refused by default:

```
[sandbox] This project's sandbox.yaml weakens egress control (firewall: open).
[sandbox] The sparkyard master key is a gateway ADMIN credential; refusing to inject it.
[sandbox] Override with SPARKYARD_ALLOW_UNSAFE_FIREWALL=1 if this project is trusted.
```

If you understand the risk and trust the project, override it:

```bash
SPARKYARD_ALLOW_UNSAFE_FIREWALL=1 sandbox claude-spark qwen3-coder-next
```

## One-time setup

The spark backend is configured once, machine-wide (not per-project), in a
config file the CLI parses but never `source`s:

```bash
mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}/sandbox"
cat > "${XDG_CONFIG_HOME:-$HOME/.config}/sandbox/sparkyard.env" <<'EOF'
SPARKYARD_URL=http://host.docker.internal:14000
LITELLM_MASTER_KEY=<the LITELLM_MASTER_KEY value from sparkyard's secrets.env>
SPARKYARD_MODEL=qwen3-coder-next
EOF
chmod 600 "${XDG_CONFIG_HOME:-$HOME/.config}/sandbox/sparkyard.env"
```

Only `LITELLM_MASTER_KEY` is required — `SPARKYARD_URL` defaults to
`http://host.docker.internal:14000` and `SPARKYARD_MODEL` just lets you omit
`<model>` from `claude-spark` / `remote-spark`. Each value can also come from
a real environment variable of the same name, which always wins over the
file. The CLI warns (but doesn't refuse) if the file is group- or
world-readable — `chmod 600` it.

## Verify the wiring

```bash
sandbox spark-status                     # config only — works from any directory
sandbox spark-status qwen3-coder-next    # + gateway reachability and model check
```

With no model argument, `spark-status` just prints the resolved URL, a
masked key, and the default model — it doesn't need a `sandbox.yaml` or a
reachable gateway. Give it a model name and it also checks the gateway is up
and that the model is actually served, printing the list of available
models if it isn't.

`SANDBOX_DRY_RUN=1` works the same way on `claude-spark`, `remote-spark`,
`run --spark`, and `llm --spark`: it prints the `docker` invocation (master
key masked) instead of launching. It's a dry run of the container launch
only — the gateway still has to be reachable, since each of these commands
checks that before it ever gets to the dry-run branch (`claude-spark` /
`remote-spark` / `run --spark` also validate the named model is actually
served; `llm --spark` only checks that the gateway answers, since it doesn't
know which model you'll pass to `-m` until `llm` itself parses it).

## Interactive coding

From your project directory (where `sandbox.yaml` lives):

```bash
sandbox claude-spark qwen3-coder-next
```

This starts (or attaches to) the sandbox container and launches Claude Code
with `ANTHROPIC_BASE_URL` pointed at the gateway and `ANTHROPIC_AUTH_TOKEN`
set to your LiteLLM master key — no Anthropic API key or `sandbox login`
needed. Requires a project image already built (`sandbox build`). If a
container for this project is already running, `claude-spark` execs into it
instead of starting a new one, same as `claude-local`.

If you omitted `SPARKYARD_MODEL` in the config file, the model name is
required: `sandbox claude-spark <model>`.

## The headless fleet pattern

```bash
sandbox run --headless --spark qwen3-coder-next -- "review src/ for bugs"
```

`--spark` is only valid together with `--headless` — using it on an
interactive `run` is a hard error that points you at `claude-spark` instead.
Unlike `claude-spark`/`remote-spark`, `run --spark` always needs an explicit
`<model>`; it does not fall back to `SPARKYARD_MODEL`.

Keep every parallel headless agent on **one** model. llama-swap (sparkyard's
router) serializes model swaps, so agents running different models queue
behind each other's load time instead of running concurrently. To keep
several models resident at once, add a `groups:` entry to sparkyard's own
`models.yaml` (see sparkyard's docs) — that's a sparkyard-side setting, not
something sandbox-env controls.

## Quick prompts with `llm --spark`

The `llm` binary isn't in the base image — it's installed by the `llm`
feature, which itself requires the `python` feature (`python` must come
*before* `llm` in `features:`, or the build fails with "llm feature requires
the python feature"). Add both to your `sandbox.yaml` before building:

```yaml
features:
  - python      # required by llm
  - llm
```

```bash
sandbox build
sandbox llm --spark -m qwen3-coder-next "What does this function do?"
```

`--spark` must be the first argument to `llm`. Three things about this path
are easy to get wrong:

- **It only works on a fresh container.** If a sandbox for this project is
  already running, `llm --spark` refuses with an error telling you to run
  `sandbox stop` first — the gateway's model registry has to be mounted when
  the container starts, and `docker exec` can't add a mount after the fact.
  Plain `sandbox llm` (without `--spark`) still execs into a running
  container as usual.
- **Nothing persists between invocations.** Each `--spark` run relocates
  `llm`'s entire user directory (`LLM_USER_PATH`) to a throwaway temp dir, so
  `llm logs` history, `keys.json`, templates, and aliases do not carry over
  from one `sandbox llm --spark` call to the next, and are entirely separate
  from a non-spark `sandbox llm`'s state.
- **Model names are whatever the gateway calls them.** At invocation time the
  CLI queries the gateway's `/v1/models` and registers each one under its
  real id, so `-m <model>` must match a name sparkyard actually serves — check
  with `sandbox spark-status <model>` first if you're not sure.

## Remote control (unverified)

```bash
sandbox remote-spark qwen3-coder-next
```

This starts Claude Code's remote-control server with inference routed to the
gateway, while keeping your real `claude.ai` authentication for the session
handshake — remote control still needs that to register the session at all.
**Nobody has confirmed this combination actually works.** It's unverified
whether Claude Code's remote-control tolerates a redirected inference base
URL while authenticating sessions through claude.ai; the command prints a
warning to that effect every time it runs. Treat it as experimental: if the
session fails to register, that's a real finding to report, not something to
silently work around.

## Cold starts

The first request after sparkyard swaps in a model can take minutes — a 35B
model was measured at over five minutes to load. That's normal loading time,
not a hung request. `spark-status <model>` prints a reminder of this whenever
the model check succeeds.

## Limitations

- **The master key is visible in `docker inspect`.** It's passed via `-e`,
  the same way the existing `claude-local` passes its (placeholder) token.
  Don't treat the sandbox container as a secret boundary for this key. The
  key also appears in host process arguments (`ps` / `/proc/<pid>/cmdline`)
  while a spark command runs, so it's visible to other local users on a
  shared machine, not just to whoever can reach the Docker socket.
- **`llm --spark` state doesn't persist** and **can't attach to a running
  container** — see above.
- **`remote-spark` is unverified** against a live stack — see above.
- **Open models are weaker than Claude at long agentic loops.** Prefer
  `sandbox claude` (the real Anthropic API) for work where correctness
  matters most; reach for the spark backend when GPU-local, no-API-cost
  iteration is what you need.

## Summary

| Goal | Command |
|---|---|
| Check the backend config | `sandbox spark-status` |
| Check a model is served | `sandbox spark-status qwen3-coder-next` |
| Interactive Claude Code | `sandbox claude-spark qwen3-coder-next` |
| Headless agent run | `sandbox run --headless --spark qwen3-coder-next -- "..."` |
| One-off prompt via `llm` | `sandbox llm --spark -m qwen3-coder-next "..."` |
| Remote control (unverified) | `sandbox remote-spark qwen3-coder-next` |

The key trade-off: no per-container GPU, no CPU-bound `ollama`, no second
copy of the model — just Claude Code (or `llm`) routed to the GPU-backed
gateway sparkyard already runs.
