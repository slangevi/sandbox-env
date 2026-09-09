#!/bin/bash
# tests/test-spark.sh — sparkyard backend: config, preflight, argument wiring
# Uses a local stub gateway; never requires a live sparkyard stack.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="$SCRIPT_DIR/cli/sandbox"
PASS=0
FAIL=0

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

check_output() {
    local desc="$1" expected="$2"; shift 2
    local output
    output=$("$@" 2>&1) || true
    if echo "$output" | grep -q -- "$expected"; then
        echo "  PASS: $desc"; PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (expected '$expected')"
        echo "        got: $output"
        FAIL=$((FAIL + 1))
    fi
}

check_not_output() {
    local desc="$1" unexpected="$2"; shift 2
    local output
    output=$("$@" 2>&1) || true
    if echo "$output" | grep -q -- "$unexpected"; then
        echo "  FAIL: $desc (found forbidden '$unexpected')"
        FAIL=$((FAIL + 1))
    else
        echo "  PASS: $desc"; PASS=$((PASS + 1))
    fi
}

# check_not_output alone passes whenever the command dies early for ANY
# reason — a command that errors out before ever reaching the masking logic
# would trivially satisfy "the secret isn't in the output" without the
# masking code having run at all. Pair every check_not_output on a
# success path with a check_status proving the path actually completed.
check_status() {
    local desc="$1" expected="$2"; shift 2
    local status=0
    "$@" >/dev/null 2>&1 || status=$?
    if [ "$status" -eq "$expected" ]; then
        echo "  PASS: $desc"; PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (expected exit $expected, got $status)"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== sparkyard Backend Tests ==="

# ── Config loading ───────────────────────────────────────────────────
echo "-- config loading --"

EMPTY_HOME="$TMP/empty"
mkdir -p "$EMPTY_HOME"
check_output "fails with no key configured" "No LiteLLM master key" \
    env XDG_CONFIG_HOME="$EMPTY_HOME" LITELLM_MASTER_KEY="" SPARKYARD_URL="" \
    "$SANDBOX" spark-status

CFG_HOME="$TMP/config"
mkdir -p "$CFG_HOME/sandbox"
CFG="$CFG_HOME/sandbox/sparkyard.env"
cat > "$CFG" <<'EOF'
SPARKYARD_URL=http://example.invalid:9999
LITELLM_MASTER_KEY=sk-from-file-secret
SPARKYARD_MODEL=model-from-file
EOF
chmod 600 "$CFG"

check_output "url read from config file" "http://example.invalid:9999" \
    env XDG_CONFIG_HOME="$CFG_HOME" LITELLM_MASTER_KEY="" SPARKYARD_URL="" \
    "$SANDBOX" spark-status

check_output "default model read from config file" "model-from-file" \
    env XDG_CONFIG_HOME="$CFG_HOME" LITELLM_MASTER_KEY="" SPARKYARD_URL="" \
    "$SANDBOX" spark-status

check_output "env var overrides config file url" "http://override.invalid:1234" \
    env XDG_CONFIG_HOME="$CFG_HOME" LITELLM_MASTER_KEY="" \
    SPARKYARD_URL="http://override.invalid:1234" \
    "$SANDBOX" spark-status

check_not_output "key is never printed in full" "sk-from-file-secret" \
    env XDG_CONFIG_HOME="$CFG_HOME" LITELLM_MASTER_KEY="" SPARKYARD_URL="" \
    "$SANDBOX" spark-status

check_status "spark-status exits 0 with a configured key (masking path actually ran)" 0 \
    env XDG_CONFIG_HOME="$CFG_HOME" LITELLM_MASTER_KEY="" SPARKYARD_URL="" \
    "$SANDBOX" spark-status

# A key below the 12-char threshold must be replaced by the placeholder, not
# partially revealed. Grep the key's first 4 characters: the pre-fix code
# printed them verbatim as "zqxj...", so this assertion fails against the old
# code and passes only with the guard in place.
check_not_output "sub-threshold key is not partially revealed" "zqxj" \
    env XDG_CONFIG_HOME="$EMPTY_HOME" LITELLM_MASTER_KEY="zqxjwvut" SPARKYARD_URL="" \
    "$SANDBOX" spark-status

check_status "spark-status exits 0 with a sub-threshold key (masking path actually ran)" 0 \
    env XDG_CONFIG_HOME="$EMPTY_HOME" LITELLM_MASTER_KEY="zqxjwvut" SPARKYARD_URL="" \
    "$SANDBOX" spark-status

chmod 644 "$CFG"
check_output "warns when config file is world-readable" "group/world-readable" \
    env XDG_CONFIG_HOME="$CFG_HOME" LITELLM_MASTER_KEY="" SPARKYARD_URL="" \
    "$SANDBOX" spark-status
chmod 600 "$CFG"

# `export KEY=value` (the shape secrets.env uses) must not be silently
# ignored, and a trailing-space value (easy to introduce copying out of
# secrets.env) must not ride along verbatim into a 401 with no hint.
CFG_EXPORT_HOME="$TMP/config-export"
mkdir -p "$CFG_EXPORT_HOME/sandbox"
CFG_EXPORT="$CFG_EXPORT_HOME/sandbox/sparkyard.env"
cat > "$CFG_EXPORT" <<'EOF'
export SPARKYARD_URL=http://export-prefix.invalid:7777
LITELLM_MASTER_KEY=sk-export-test
EOF
chmod 600 "$CFG_EXPORT"

check_output "accepts an 'export' prefix on a config value" "http://export-prefix.invalid:7777" \
    env XDG_CONFIG_HOME="$CFG_EXPORT_HOME" LITELLM_MASTER_KEY="" SPARKYARD_URL="" \
    "$SANDBOX" spark-status

CFG_WS_HOME="$TMP/config-ws"
mkdir -p "$CFG_WS_HOME/sandbox"
CFG_WS="$CFG_WS_HOME/sandbox/sparkyard.env"
printf 'LITELLM_MASTER_KEY=sk-ws-test\nSPARKYARD_MODEL=model-with-space   \n' > "$CFG_WS"
chmod 600 "$CFG_WS"

# Anchored on end-of-line: a trailing space left un-trimmed would still
# contain "model-with-space" as a substring, so only the "$" anchor makes
# this assertion genuinely fail against the un-trimmed value.
check_output "trims trailing whitespace from a config value" "default model: model-with-space$" \
    env XDG_CONFIG_HOME="$CFG_WS_HOME" LITELLM_MASTER_KEY="" SPARKYARD_URL="" \
    "$SANDBOX" spark-status

CFG_QWS_HOME="$TMP/config-qws"
mkdir -p "$CFG_QWS_HOME/sandbox"
CFG_QWS="$CFG_QWS_HOME/sandbox/sparkyard.env"
# A trailing space AFTER the closing quote: if whitespace-trimming ran AFTER
# quote-stripping (the pre-fix order), the trailing quote is no longer the
# last character when the strip happens, so it survives embedded in the
# value — inflating a 13-char key to 14. Trimming first (F7) yields the
# correct 13-char value with the quotes fully gone.
printf 'LITELLM_MASTER_KEY="sk-abcdefghij" \n' > "$CFG_QWS"
chmod 600 "$CFG_QWS"

check_output "quoted value with trailing space is fully unquoted" "(13 chars)" \
    env XDG_CONFIG_HOME="$CFG_QWS_HOME" LITELLM_MASTER_KEY="" SPARKYARD_URL="" \
    "$SANDBOX" spark-status

# ── Preflight ────────────────────────────────────────────────────────
echo "-- preflight --"

cat > "$TMP/stub.py" <<'PY'
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

MODELS = {"data": [{"id": "qwen3-coder-next"}, {"id": "gemma-4-26b"}, {"id": "default-model"}]}

# Canned OpenAI-shaped completion. Loopback-only (bound to 127.0.0.1 below),
# used for a one-off manual end-to-end proof that the real `llm` binary, in a
# real container, through the real --spark mount, resolves a model id and
# gets a reply back — not exercised by the automated dry-run assertions,
# which never invoke the actual llm binary.
CHAT_COMPLETION = {
    "id": "chatcmpl-stub",
    "object": "chat.completion",
    "model": "qwen3-coder-next",
    "choices": [
        {
            "index": 0,
            "message": {"role": "assistant", "content": "SPARKYARD_STUB_REPLY_OK"},
            "finish_reason": "stop",
        }
    ],
    "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
}


# /health/liveliness is intentionally unauthenticated (matches the real
# gateway), but /v1/models checks the key so test-spark.sh can exercise the
# 401-rejection path (F2) without a live sparkyard stack.
VALID_KEYS = {"sk-test", "sk-dry-secret"}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health/liveliness":
            body = b'{"status":"healthy"}'
        elif self.path == "/v1/models":
            if self.headers.get("x-api-key") not in VALID_KEYS:
                body = b'{"error":"invalid api key"}'
                self.send_response(401)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            body = json.dumps(MODELS).encode()
        else:
            self.send_response(404)
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if self.path == "/v1/chat/completions":
            length = int(self.headers.get("Content-Length", 0))
            self.rfile.read(length)  # drain the request body
            body = json.dumps(CHAT_COMPLETION).encode()
        else:
            self.send_response(404)
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
PY

PORT=18400
python3 "$TMP/stub.py" "$PORT" &
STUB_PID=$!
trap 'kill "$STUB_PID" 2>/dev/null || true; docker rm -f sandbox-spark-argtest >/dev/null 2>&1 || true; docker image rm -f sandbox-spark-argtest:latest >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT

for _ in $(seq 1 50); do
    curl -sf "http://127.0.0.1:$PORT/health/liveliness" >/dev/null 2>&1 && break
    sleep 0.1
done

if ! curl -sf "http://127.0.0.1:$PORT/health/liveliness" >/dev/null 2>&1; then
    echo "  ERROR: stub gateway failed to start on port $PORT (port in use?)"
    exit 1
fi

STUB_ENV=(env XDG_CONFIG_HOME="$EMPTY_HOME" LITELLM_MASTER_KEY="sk-test"
          SPARKYARD_URL="http://127.0.0.1:$PORT")

check_output "preflight accepts a served model" "is available" \
    "${STUB_ENV[@]}" "$SANDBOX" spark-status qwen3-coder-next

check_output "preflight rejects an unknown model" "is not served by sparkyard" \
    "${STUB_ENV[@]}" "$SANDBOX" spark-status no-such-model

check_output "preflight lists available models on a miss" "qwen3-coder-next" \
    "${STUB_ENV[@]}" "$SANDBOX" spark-status no-such-model

check_output "preflight warns about cold start" "several minutes" \
    "${STUB_ENV[@]}" "$SANDBOX" spark-status qwen3-coder-next

# host.docker.internal does not resolve on the host; preflight must rewrite it
# to localhost. Without the rewrite this call fails even though the stub is up.
check_output "host.docker.internal is rewritten for host-side checks" "is available" \
    env XDG_CONFIG_HOME="$EMPTY_HOME" LITELLM_MASTER_KEY="sk-test" \
    SPARKYARD_URL="http://host.docker.internal:$PORT" \
    "$SANDBOX" spark-status qwen3-coder-next

check_output "unreachable gateway is reported clearly" "gateway unreachable" \
    env XDG_CONFIG_HOME="$EMPTY_HOME" LITELLM_MASTER_KEY="sk-test" \
    SPARKYARD_URL="http://127.0.0.1:1" \
    "$SANDBOX" spark-status qwen3-coder-next

# F2: a wrong key passes the unauthenticated /health/liveliness check, then
# 401s at /v1/models. Before the fix that was swallowed by `|| true` and
# reported as a generic "couldn't list models" warning; it must now be a
# clear, fatal key-rejection error instead.
check_output "wrong master key is reported as a rejection, not a warning" \
    "Gateway rejected the master key" \
    env XDG_CONFIG_HOME="$EMPTY_HOME" LITELLM_MASTER_KEY="sk-totally-wrong" \
    SPARKYARD_URL="http://127.0.0.1:$PORT" \
    "$SANDBOX" spark-status qwen3-coder-next

check_status "wrong master key exits non-zero" 1 \
    env XDG_CONFIG_HOME="$EMPTY_HOME" LITELLM_MASTER_KEY="sk-totally-wrong" \
    SPARKYARD_URL="http://127.0.0.1:$PORT" \
    "$SANDBOX" spark-status qwen3-coder-next

# A container left running by an interrupted prior run of this same script
# would otherwise poison this whole section: cmd_claude_spark would take the
# attach branch instead of starting a new container, and every llm --spark
# assertion below would hit the "already running" refusal path — confusing
# failures with no clue why. CI is always fresh, so this only ever fires
# locally. Also removed in the EXIT trap above, for a clean exit mid-run.
docker rm -f sandbox-spark-argtest >/dev/null 2>&1 || true

# ── Argument wiring (dry-run) ────────────────────────────────────────
echo "-- argument wiring --"

if ! docker image inspect sandbox-base:latest >/dev/null 2>&1; then
    echo "  ERROR: these tests need sandbox-base:latest. Run: cli/sandbox build-base"
    exit 1
fi

PROJ="$TMP/proj"
mkdir -p "$PROJ"
cat > "$PROJ/sandbox.yaml" <<'EOF'
name: spark-argtest
firewall: open
EOF

# Dry-run short-circuits before Docker executes, but the image-existence guard
# still runs (and the firewall guard below runs even earlier), so tag a
# stand-in from the base image up front.
docker image tag sandbox-base:latest sandbox-spark-argtest:latest >/dev/null 2>&1

# ── Firewall guard (F1) ──────────────────────────────────────────────
echo "-- firewall guard --"

# This fixture's firewall: open is exactly the config _spark_guard_firewall
# now refuses on. Prove the refusal fires by default (no override) BEFORE
# the rest of this section starts setting SPARKYARD_ALLOW_UNSAFE_FIREWALL=1
# in every other env below — otherwise a regression that made the guard a
# no-op would go undetected for the rest of this file.
run_no_override() {
    (cd "$PROJ" && env XDG_CONFIG_HOME="$EMPTY_HOME" LITELLM_MASTER_KEY="sk-dry-secret" \
        SPARKYARD_URL="http://127.0.0.1:$PORT" SANDBOX_DRY_RUN=1 "$SANDBOX" "$@")
}

check_output "claude-spark refuses on a weakened firewall without the override" \
    "weakens egress control" run_no_override claude-spark qwen3-coder-next
check_status "claude-spark exits non-zero on the firewall refusal" 1 \
    run_no_override claude-spark qwen3-coder-next
check_not_output "claude-spark's firewall refusal does not still print docker args" \
    "ANTHROPIC_BASE_URL" run_no_override claude-spark qwen3-coder-next

check_output "claude-spark mentions the override env var" \
    "SPARKYARD_ALLOW_UNSAFE_FIREWALL=1" run_no_override claude-spark qwen3-coder-next

# From here on, every dry-run test in this file needs the escape hatch: the
# fixture project uses firewall: open, and F1 makes that a hard refusal
# without it.
DRY_ENV=(env XDG_CONFIG_HOME="$EMPTY_HOME" LITELLM_MASTER_KEY="sk-dry-secret"
         SPARKYARD_URL="http://127.0.0.1:$PORT" SANDBOX_DRY_RUN=1
         SPARKYARD_ALLOW_UNSAFE_FIREWALL=1)

run_dry() { (cd "$PROJ" && "${DRY_ENV[@]}" "$SANDBOX" "$@"); }

check_output "the override lets claude-spark proceed" "ANTHROPIC_BASE_URL=http://127.0.0.1:$PORT" \
    run_dry claude-spark qwen3-coder-next

# Identical to DRY_ENV/run_dry, but with SPARKYARD_MODEL configured — used to
# prove a configured default model still applies when a flag is present (I1).
DRY_ENV_MODEL=(env XDG_CONFIG_HOME="$EMPTY_HOME" LITELLM_MASTER_KEY="sk-dry-secret"
         SPARKYARD_URL="http://127.0.0.1:$PORT" SANDBOX_DRY_RUN=1
         SPARKYARD_ALLOW_UNSAFE_FIREWALL=1
         SPARKYARD_MODEL=default-model)

run_dry_model() { (cd "$PROJ" && "${DRY_ENV_MODEL[@]}" "$SANDBOX" "$@"); }

# An unreachable gateway (SPARKYARD_URL pointed at a port nothing listens on)
# to prove _spark_preflight is actually wired into each entry point (T2):
# deleting the preflight call from cmd_claude_spark, cmd_remote_spark, or
# cmd_run today leaves every dry-run assertion above passing regardless.
UNREACHABLE_ENV=(env XDG_CONFIG_HOME="$EMPTY_HOME" LITELLM_MASTER_KEY="sk-dry-secret"
         SPARKYARD_URL="http://127.0.0.1:1" SANDBOX_DRY_RUN=1
         SPARKYARD_ALLOW_UNSAFE_FIREWALL=1)

run_unreachable() { (cd "$PROJ" && "${UNREACHABLE_ENV[@]}" "$SANDBOX" "$@"); }

check_output "dry-run sets ANTHROPIC_BASE_URL" "ANTHROPIC_BASE_URL=http://127.0.0.1:$PORT" \
    run_dry claude-spark qwen3-coder-next

check_output "dry-run adds the host-gateway alias" "host.docker.internal:host-gateway" \
    run_dry claude-spark qwen3-coder-next

check_output "dry-run passes the model to claude" "--model qwen3-coder-next" \
    run_dry claude-spark qwen3-coder-next

# Trailing space matters: it proves the value is EMPTY, not merely present.
check_output "dry-run blanks ANTHROPIC_API_KEY" "ANTHROPIC_API_KEY= " \
    run_dry claude-spark qwen3-coder-next

check_output "dry-run passes a masked auth token" "ANTHROPIC_AUTH_TOKEN=***" \
    run_dry claude-spark qwen3-coder-next

check_not_output "dry-run masks the master key" "sk-dry-secret" \
    run_dry claude-spark qwen3-coder-next

check_status "claude-spark dry-run exits 0 (masking path actually ran)" 0 \
    run_dry claude-spark qwen3-coder-next

# No test previously covered _spark_preflight actually being wired into this
# command — deleting the call from cmd_claude_spark would still pass every
# assertion above. An unreachable gateway forces the preflight's own error
# message to surface, proving it's on the call path (T2).
check_output "claude-spark calls preflight (unreachable gateway surfaces)" \
    "gateway unreachable" run_unreachable claude-spark qwen3-coder-next

# A project with no built image: these two assertions must still produce a
# validation error, which is only true if argument validation runs BEFORE the
# image-existence guard. With the ordering reversed they would report
# "Project image not found" instead, so this genuinely pins the ordering.
PROJ_NOIMG="$TMP/proj-noimg"
mkdir -p "$PROJ_NOIMG"
cat > "$PROJ_NOIMG/sandbox.yaml" <<'EOF'
name: spark-noimg
firewall: open
EOF

run_dry_noimg() { (cd "$PROJ_NOIMG" && "${DRY_ENV[@]}" "$SANDBOX" "$@"); }

check_output "claude-spark requires a model" "Usage: sandbox claude-spark" \
    run_dry_noimg claude-spark

check_output "claude-spark rejects an invalid model name" "Invalid model name" \
    run_dry_noimg claude-spark 'bad;name'

# ── run --spark ──────────────────────────────────────────────────────
echo "-- run --spark --"

check_output "run --spark wires the backend" "ANTHROPIC_BASE_URL=http://127.0.0.1:$PORT" \
    run_dry run --headless --spark qwen3-coder-next -- "hello"

check_output "run --spark passes the model" "--model qwen3-coder-next" \
    run_dry run --headless --spark qwen3-coder-next -- "hello"

check_output "run --spark keeps the headless prompt" "-p hello" \
    run_dry run --headless --spark qwen3-coder-next -- "hello"

check_output "run --spark requires a model name" "--spark requires a model" \
    run_dry run --headless --spark

check_output "run --spark requires --headless" "requires --headless" \
    run_dry run --spark qwen3-coder-next

check_output "run --spark rejects a flag as its model" "requires a model name" \
    run_dry run --headless --spark -- "hello"

# T2: prove _spark_preflight is actually wired into cmd_run's --spark block.
check_output "run --spark calls preflight (unreachable gateway surfaces)" \
    "gateway unreachable" run_unreachable run --headless --spark qwen3-coder-next -- "hello"

# ── run --claude-arg (per-run Claude args for the Matrix bridge) ─────
echo "-- run --claude-arg --"

check_output "run --claude-arg passes values through, in order, after --model and before -p" \
    "--model qwen3-coder-next --session-id abc-123 --output-format json -p hello" \
    run_dry run --headless --spark qwen3-coder-next \
        --claude-arg --session-id --claude-arg abc-123 --claude-arg --output-format --claude-arg json -- "hello"

check_status "run --claude-arg with safe flags exits 0" 0 \
    run_dry run --headless --spark qwen3-coder-next --claude-arg --session-id --claude-arg abc -- "hello"

check_not_output "--session-id is known-safe (no warning)" "Unrecognized claude.args" \
    run_dry run --headless --spark qwen3-coder-next --claude-arg --session-id --claude-arg abc -- "hello"

check_not_output "--output-format is known-safe (no warning)" "Unrecognized claude.args" \
    run_dry run --headless --spark qwen3-coder-next --claude-arg --output-format --claude-arg json -- "hello"

check_output "run --claude-arg blocks a trust-changing flag" "Blocked claude.args value" \
    run_dry run --headless --spark qwen3-coder-next --claude-arg --permission-mode --claude-arg bypassPermissions -- "hello"

check_output "the block names the flag's source" "in --claude-arg" \
    run_dry run --headless --spark qwen3-coder-next --claude-arg --permission-mode --claude-arg bypassPermissions -- "hello"

check_status "a blocked --claude-arg halts" 1 \
    run_dry run --headless --spark qwen3-coder-next --claude-arg --permission-mode --claude-arg bypassPermissions -- "hello"

check_output "an unknown --claude-arg flag is warned about, not blocked" "Unrecognized claude.args value" \
    run_dry run --headless --spark qwen3-coder-next --claude-arg --frobnicate -- "hello"

check_output "run --claude-arg requires a value" "requires a value" \
    run_dry run --headless --spark qwen3-coder-next --claude-arg

check_output "run --claude-arg requires --headless" "require --headless" \
    run_dry run --claude-arg --verbose -- "hello"

# ── remote-spark ─────────────────────────────────────────────────────
echo "-- remote-spark --"

check_output "remote-spark wires the backend" "ANTHROPIC_BASE_URL=http://127.0.0.1:$PORT" \
    run_dry remote-spark qwen3-coder-next

check_output "remote-spark sets ANTHROPIC_MODEL" "ANTHROPIC_MODEL=qwen3-coder-next" \
    run_dry remote-spark qwen3-coder-next

check_output "remote-spark starts remote-control" "remote-control" \
    run_dry remote-spark qwen3-coder-next

# remote-control needs real claude.ai auth for session management, so unlike
# claude-spark this command must NOT blank the API key.
check_not_output "remote-spark does not blank ANTHROPIC_API_KEY" "ANTHROPIC_API_KEY=" \
    run_dry remote-spark qwen3-coder-next

check_status "remote-spark dry-run exits 0 (ANTHROPIC_API_KEY assertion path actually ran)" 0 \
    run_dry remote-spark qwen3-coder-next

# T2: prove _spark_preflight is actually wired into cmd_remote_spark.
check_output "remote-spark calls preflight (unreachable gateway surfaces)" \
    "gateway unreachable" run_unreachable remote-spark qwen3-coder-next

check_output "remote-spark --name requires a value" "requires a session name" \
    run_dry remote-spark qwen3-coder-next --name

check_output "remote-spark --spawn requires a value" "requires a mode" \
    run_dry remote-spark qwen3-coder-next --spawn

# ── SPARKYARD_MODEL fallback with a flag present (I1) ────────────────
# $1 must NOT be consumed as the model name when it looks like a flag —
# otherwise a configured SPARKYARD_MODEL default and flag pass-through
# (e.g. `--continue`, `--name`) are mutually exclusive. Regression test for
# the bug already fixed in `run --spark` (commit 1dc4f15) but never
# back-ported to claude-spark / remote-spark.
echo "-- SPARKYARD_MODEL fallback with a flag present --"

check_output "claude-spark falls back to SPARKYARD_MODEL with a flag present" "--model default-model" \
    run_dry_model claude-spark --continue

check_output "remote-spark falls back to SPARKYARD_MODEL with a flag present" "ANTHROPIC_MODEL=default-model" \
    run_dry_model remote-spark --name foo

# ── llm --spark ──────────────────────────────────────────────────────
echo "-- llm --spark --"

# llm 0.24 has no generic OpenAI-compatible passthrough: get_model() resolves
# -m NAME against registered model ids/aliases only, NEVER model_name, so
# --spark registers one extra-openai-models.yaml entry per model the gateway
# actually serves (queried from /v1/models — the stub answers with
# qwen3-coder-next and gemma-4-26b). The registry is generated on the HOST
# (so it can't be trusted to be node-uid-readable on every host — CI runs as
# uid 1001) and is bind-mounted READ-ONLY at a neutral path, then copied at
# container start into a directory the container itself creates and owns;
# LLM_USER_PATH points llm at that container-owned copy, not the mount —
# llm's own default ~/.config/io.datasette.llm collides with entrypoint.sh's
# persistent-volume symlink (`rm -rf /home/node/.config && ln -sfn ...`) and
# aborts container startup with "Device or resource busy" if anything is
# bind-mounted there.
check_output "llm --spark mounts the sparkyard-llm registry read-only" ":/tmp/sparkyard-llm:ro" \
    run_dry llm --spark -m qwen3-coder-next "hello"

check_output "llm --spark sets LLM_USER_PATH to the container-owned copy" "LLM_USER_PATH=/home/node/.sparkyard-llm" \
    run_dry llm --spark -m qwen3-coder-next "hello"

check_output "llm --spark adds the host-gateway alias" "host.docker.internal:host-gateway" \
    run_dry llm --spark -m qwen3-coder-next "hello"

check_output "llm --spark passes a masked OPENAI_API_KEY" "OPENAI_API_KEY=***" \
    run_dry llm --spark -m qwen3-coder-next "hello"

check_not_output "llm --spark masks the master key" "sk-dry-secret" \
    run_dry llm --spark -m qwen3-coder-next "hello"

check_status "llm --spark dry-run exits 0 (masking path actually ran)" 0 \
    run_dry llm --spark -m qwen3-coder-next "hello"

# The registry is bind-mounted read-only, so the container's own `mkdir -p
# ~/.sparkyard-llm && cp ... && llm "$@"` prefix is what actually makes it
# usable regardless of host uid (see the comment above cmd_llm's --spark
# block). No other assertion in this file pins that prefix's presence, so
# deleting it would leave every other test green while breaking `llm --spark`
# at runtime.
check_output "llm --spark copies the registry into a container-owned dir before exec" \
    "cp /tmp/sparkyard-llm/extra-openai-models.yaml" \
    run_dry llm --spark -m qwen3-coder-next "hello"

# The already-running (docker exec) branch can't mount a new directory into a
# live container, so --spark must refuse cleanly there rather than silently
# running with a model registry llm can never see. Simulate "already running"
# with a throwaway container under the same name the dry-run tests use — no
# stub-gateway dependency needed, since the refusal fires before any
# /v1/models call. (No defensive removal needed here: it already ran before
# "-- argument wiring --" above, and nothing since has created this container.)
docker run -d --rm --name sandbox-spark-argtest --entrypoint sleep sandbox-spark-argtest:latest infinity >/dev/null 2>&1

check_output "llm --spark refuses to attach to an already-running container" "Run 'sandbox stop' first" \
    run_dry llm --spark -m qwen3-coder-next "hello"

docker rm -f sandbox-spark-argtest >/dev/null 2>&1 || true

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
