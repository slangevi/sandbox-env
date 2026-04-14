# Remote Pair Programming with Claude Code

The sandbox supports Claude Code's remote control feature, which lets you start a session on your desktop and then connect to it from any device — your phone, a tablet, or another computer — without exposing any ports or setting up SSH.

The selling point: kick off a long-running task on your workstation, leave it running in a Docker container with a strict firewall, and check in from wherever you are.

---

## Prerequisites

- **Claude Pro or Max subscription.** Remote control is part of Claude Code and requires an active subscription. It uses the same Anthropic account you authenticate with during `sandbox login`.
- **Docker** running on the host machine where the sandbox will run.
- The sandbox base image built: `sandbox build-base` (one-time setup).

---

## 1. Create a sandbox.yaml for Your Project

If you don't have one yet, run `sandbox init` in your project directory:

```bash
cd ~/projects/my-app
sandbox init
```

That creates a starter `sandbox.yaml`. Edit it to suit your project:

```yaml
name: my-app

features:
  - python        # add any features you need

packages:
  - ripgrep
  - tree

mounts:
  - host: .
    container: /workspace

firewall: strict  # the default — keeps the container locked down

claude:
  mode: interactive
```

The `name` field is required for all `sandbox` commands and becomes the Docker image and volume name prefix.

---

## 2. Build the Project Image

```bash
sandbox build
```

This builds `sandbox-my-app:latest` from your `sandbox.yaml`. You only need to rebuild when you change `features`, `packages`, or `setup`.

---

## 3. Authenticate Claude Code

Auth is stored in a per-project Docker named volume (`sandbox-my-app-claude`), separate from your host `~/.claude`. This keeps each project's credentials isolated.

```bash
sandbox login
```

Follow the prompts — it opens the standard Claude Code OAuth flow in your terminal. When it finishes, the credentials are saved in the volume and will be reused every time you start the sandbox.

---

## 4. Start Remote Control

From your project directory, run:

```bash
sandbox remote
```

Claude Code starts inside the container and begins advertising a remote control session. You'll see output like:

```
[sandbox] Starting Claude Code remote control for sandbox-my-app...
[sandbox] Connect via claude.ai/code or the Claude mobile app

  Scan the QR code or visit:
  https://claude.ai/code?session=abc123...

  Waiting for connection...
```

The terminal stays attached; leave it running. The container keeps going until you stop it.

---

## 5. Connect from claude.ai/code

On any computer with a browser:

1. Open **https://claude.ai/code**
2. Look for the **Remote** or **Connect to session** option.
3. Paste the URL shown in your terminal, or scan the QR code if your device has a camera.
4. You're now looking at the same Claude Code session running in the container.

---

## 6. Connect from the Claude Mobile App

On iOS or Android:

1. Open the **Claude** app and sign in with the same account.
2. Navigate to **Claude Code** in the app.
3. Tap **Connect to remote session** (or similar — the UI matches the app version).
4. Scan the QR code displayed in your terminal, or paste the session URL.

You now have a full Claude Code interface on your phone, interacting with the session running on your workstation.

---

## 7. Using Remote Control

Once connected, it behaves exactly like a local Claude Code session:

- Type messages, review diffs, approve or reject tool calls.
- Claude Code is running on the host machine with access to your mounted workspace (`/workspace` in the container, mapped to `.` on the host).
- All file reads and writes happen on the host's filesystem through the mount — nothing is lost when you disconnect and reconnect.
- You can disconnect and reconnect without interrupting Claude's work. If Claude is in the middle of a task, it keeps going.

---

## 8. Use Cases

**Check progress from your phone.**
Start a large refactor or test suite fix on your desktop. Let Claude work. An hour later, pick up your phone, connect, and see where things stand — approve the next step or just read the summary.

**Review Claude's work from a different computer.**
You're at a different machine (a colleague's laptop, a work computer). Open the browser, connect to the session, and review what Claude has done. No need to clone the repo or set anything up on that machine.

**Pair program from a tablet while traveling.**
Bring an iPad instead of a laptop. Start the sandbox on a cloud VM or home server before you leave, then connect from the tablet at a coffee shop. The strict firewall means the container only talks to allowed domains — you're not opening the box to the internet.

---

## 9. Named Sessions

By default the session name is the project name from `sandbox.yaml`. You can override it with `--name` to make the connection URL more recognizable or to distinguish multiple simultaneous sessions:

```bash
sandbox remote --name "my-app: auth refactor"
```

The name appears in the claude.ai/code session list, which helps when you have more than one project running remotely.

---

## 10. Remote Control with a Local Model

If you've added the `ollama` feature and pulled a model, you can run remote control with local inference:

```yaml
# sandbox.yaml
features:
  - ollama
```

```bash
sandbox models pull qwen2.5-coder:7b
sandbox remote-local qwen2.5-coder:7b
```

This starts remote control the same way, but LLM inference calls are routed to the Ollama instance running inside the container rather than to Anthropic's API. **You still need a valid Anthropic account** — remote control session management goes through Anthropic's infrastructure regardless of where inference runs. Only the model calls are local.

Use `--name` here too if you want a distinct session label:

```bash
sandbox remote-local qwen2.5-coder:7b --name "my-app: local session"
```

---

## 11. Security

- **No open ports.** Remote control works by having the container maintain an outbound HTTPS connection to Anthropic's API. No inbound ports are exposed on your host or in the container.
- **Strict firewall compatible.** With `firewall: strict` in `sandbox.yaml`, the container's iptables rules allow only whitelisted domains. The Anthropic API endpoint is in the default allowlist, so remote control works out of the box even in strict mode.
- **All traffic goes through Anthropic's API over HTTPS.** Your connection from a browser or phone never reaches your host directly — it goes through Anthropic's servers, which relay it to the container's outbound session. End-to-end encryption is provided by TLS.
- **Per-project auth volumes.** Claude Code credentials are stored in `sandbox-my-app-claude`, a Docker named volume. They don't live on your host filesystem and aren't shared between projects.

---

## 12. Tips and Limitations

**Session timeout.** If the network connection between the container and Anthropic's servers is interrupted for roughly 10 minutes, the remote control session expires. The container itself keeps running, but you'll need to stop it and run `sandbox remote` again to get a new session URL.

**One session at a time.** Each `sandbox remote` invocation starts one remote control session. If you run it again while the first is still alive, you'll get a second session on a second container instance. To avoid confusion, `sandbox stop` the first before starting another.

**The container stays running between connects.** You can disconnect your browser or phone and reconnect later without losing state. Claude's working memory and any in-progress tool calls persist as long as the container is running.

**Stopping the session.** Press `Ctrl-C` in the terminal where you ran `sandbox remote`, or run `sandbox stop` from another terminal in the same project directory. This stops the container cleanly.
