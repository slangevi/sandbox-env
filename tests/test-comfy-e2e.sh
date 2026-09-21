#!/bin/bash
# tests/test-comfy-e2e.sh — one real generation through a live ComfyUI.
# Skips cleanly when ComfyUI is down or no checkpoint is installed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="$SCRIPT_DIR/cli/sandbox"
CONTAINER="${COMFYUI_CONTAINER:-comfyui}"

echo "=== ComfyUI End-to-End Test ==="

# `sandbox comfy-status` is designed to warn, never fail, when ComfyUI is
# down (a sandbox with the comfyui feature must still start) — so its exit
# code is always 0 and cannot be used as the skip gate here. Check the
# container's actual running state directly instead.
RUNNING=$(docker inspect --format '{{.State.Running}}' "$CONTAINER" 2>/dev/null) || RUNNING=""
if [ "$RUNNING" != "true" ]; then
    echo "SKIP: container '$CONTAINER' is not running."
    exit 0
fi

HOST_PORT=$(docker inspect --format '{{json .NetworkSettings.Ports}}' "$CONTAINER" 2>/dev/null \
    | yq -p json -r '.["8188/tcp"][0].HostPort // ""' 2>/dev/null) || HOST_PORT=""
if [ -z "$HOST_PORT" ]; then
    echo "SKIP: '$CONTAINER' publishes no host port for 8188/tcp."
    exit 0
fi

if ! curl -sf --connect-timeout 5 --max-time 10 "http://127.0.0.1:${HOST_PORT}/system_stats" >/dev/null 2>&1; then
    echo "SKIP: ComfyUI did not answer at http://127.0.0.1:${HOST_PORT}/system_stats"
    exit 0
fi

CKPT=$(curl -sf --connect-timeout 5 --max-time 10 "http://127.0.0.1:${HOST_PORT}/models/checkpoints" 2>/dev/null \
    | yq -p json -r '.[0] // ""') || CKPT=""
if [ -z "$CKPT" ]; then
    echo "SKIP: no checkpoint installed. In the comfyui repo:"
    echo "  make fetch-model URL=<safetensors-url> DEST=checkpoints"
    exit 0
fi
echo "  using checkpoint: $CKPT"

# Diagnostic assertion, not a skip gate: now that we know from the outside
# ComfyUI is up, cmd_comfy_status must agree, or something about discovery
# (network, address, workflow dir) is broken and the run below would be
# testing a false premise.
STATUS_OUT=$("$SANDBOX" comfy-status 2>&1) || true
if ! grep -q "url:" <<<"$STATUS_OUT"; then
    echo "FAIL: 'sandbox comfy-status' did not report a discovered url even though $CONTAINER is up:"
    echo "$STATUS_OUT"
    exit 1
fi

TMP=$(mktemp -d)
trap 'cd "$SCRIPT_DIR" && rm -rf "$TMP"' EXIT

mkdir -p "$TMP/proj"
cat > "$TMP/proj/sandbox.yaml" <<'EOF'
name: comfy-e2e
features:
  - comfyui
firewall: strict
EOF

cd "$TMP/proj"
BUILD_LOG="$TMP/build.log"
if ! "$SANDBOX" build >"$BUILD_LOG" 2>&1; then
    echo "FAIL: build failed"
    tail -n 40 "$BUILD_LOG"
    exit 1
fi

OUT="$TMP/proj/comfy-out"
# OUT must not already contain a PNG before generation runs, so a leftover
# file from elsewhere can't be mistaken for this run's output.
if ls "$OUT"/*.png >/dev/null 2>&1; then
    echo "FAIL: $OUT already contains a PNG before generation ran — test setup is not clean."
    exit 1
fi

GEN_LOG="$TMP/txt2img.log"
if ! "$SANDBOX" comfy txt2img --prompt "a red apple on a wooden table" \
        --steps 4 --width 256 --height 256 --out /workspace/comfy-out >"$GEN_LOG" 2>&1; then
    echo "FAIL: generation failed"
    cat "$GEN_LOG"
    "$SANDBOX" clean >/dev/null 2>&1 || true
    exit 1
fi

STATUS=1
if ls "$OUT"/*.png >/dev/null 2>&1; then
    PNG=$(ls "$OUT"/*.png | head -1)
    SIZE=$(stat -c%s "$PNG" 2>/dev/null || stat -f%z "$PNG" 2>/dev/null || echo 0)
    if [ "${SIZE:-0}" -gt 0 ]; then
        echo "  PASS: image generated at $PNG ($SIZE bytes)"
        STATUS=0
    else
        echo "  FAIL: $PNG exists but is empty"
    fi
else
    echo "  FAIL: no PNG written to $OUT"
    cat "$GEN_LOG"
fi

"$SANDBOX" clean >/dev/null 2>&1 || true
exit "$STATUS"
