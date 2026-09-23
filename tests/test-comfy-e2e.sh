#!/bin/bash
# tests/test-comfy-e2e.sh — one real generation through a live ComfyUI.
# Skips cleanly when ComfyUI is down or no checkpoint is installed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="$SCRIPT_DIR/cli/sandbox"

# Mirrors cli/sandbox's own COMFY_DEFAULT_PORT constant: there is no
# COMFYUI_PORT override anywhere in the CLI — _comfy_discover always looks
# up "${COMFY_DEFAULT_PORT}/tcp" in the container's published ports for the
# host-side preflight, regardless of any COMFYUI_URL override (that only
# changes the container-to-container URL). Named here, rather than a bare
# "8188" literal, so this test doesn't silently drift from the CLI if that
# constant ever changes.
COMFY_DEFAULT_PORT=8188

echo "=== ComfyUI End-to-End Test ==="

# Derive the container name the same way the CLI actually resolves it
# (COMFYUI_CONTAINER env var, else ~/.config/sandbox/comfyui.env, else
# "comfyui") by reading it straight off `sandbox comfy-status`'s own
# output, rather than re-implementing that precedence here and risking it
# drifting out of sync — a prior version of this test only checked the env
# var, so a user who set COMFYUI_CONTAINER only in the config file got a
# silent, wrong-container SKIP instead of testing anything.
STATUS_OUT=$("$SANDBOX" comfy-status 2>&1) || true
CONTAINER=$(sed -n 's/^[[:space:]]*container:[[:space:]]*//p' <<<"$STATUS_OUT" | head -1)
if [ -z "$CONTAINER" ]; then
    echo "FAIL: could not parse a container name from 'sandbox comfy-status':"
    echo "$STATUS_OUT"
    exit 1
fi

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
    | yq -p json -r ".[\"${COMFY_DEFAULT_PORT}/tcp\"][0].HostPort // \"\"" 2>/dev/null) || HOST_PORT=""
if [ -z "$HOST_PORT" ]; then
    echo "SKIP: '$CONTAINER' publishes no host port for ${COMFY_DEFAULT_PORT}/tcp."
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

# Diagnostic assertion, not a skip gate: now that we know from the outside
# ComfyUI is up, cmd_comfy_status must agree, or something about discovery
# (network, address, workflow dir) is broken and the run below would be
# testing a false premise.
if ! grep -q "url:" <<<"$STATUS_OUT"; then
    echo "FAIL: 'sandbox comfy-status' did not report a discovered url even though $CONTAINER is up:"
    echo "$STATUS_OUT"
    "$SANDBOX" clean >/dev/null 2>&1 || true
    exit 1
fi

BUILD_LOG="$TMP/build.log"
if ! "$SANDBOX" build >"$BUILD_LOG" 2>&1; then
    echo "FAIL: build failed"
    tail -n 40 "$BUILD_LOG"
    "$SANDBOX" clean >/dev/null 2>&1 || true
    exit 1
fi

OUT="$TMP/proj/comfy-out"
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
    # Non-empty isn't proof of a real image — the download-race bug this
    # test caught wrote a non-empty *error body* under the image's name
    # before fetch_view checked the HTTP status. Check the actual PNG magic
    # bytes (89 50 4E 47 0D 0A 1A 0A) and the IHDR width/height match what
    # was requested, not just that curl wrote something non-empty.
    MAGIC=$(head -c 8 "$PNG" 2>/dev/null | od -An -tx1 | tr -d ' \n')
    WIDTH_HEX=$(dd if="$PNG" bs=1 skip=16 count=4 2>/dev/null | od -An -tx1 | tr -d ' \n')
    HEIGHT_HEX=$(dd if="$PNG" bs=1 skip=20 count=4 2>/dev/null | od -An -tx1 | tr -d ' \n')
    WIDTH=$((16#${WIDTH_HEX:-0}))
    HEIGHT=$((16#${HEIGHT_HEX:-0}))
    if [ "${SIZE:-0}" -gt 0 ] && [ "$MAGIC" = "89504e470d0a1a0a" ] \
            && [ "$WIDTH" = "256" ] && [ "$HEIGHT" = "256" ]; then
        echo "  PASS: image generated at $PNG ($SIZE bytes, valid PNG signature, ${WIDTH}x${HEIGHT})"
        STATUS=0
    elif [ "${SIZE:-0}" -gt 0 ] && [ "$MAGIC" = "89504e470d0a1a0a" ]; then
        echo "  FAIL: $PNG is a valid PNG but ${WIDTH}x${HEIGHT}, not the requested 256x256"
    elif [ "${SIZE:-0}" -gt 0 ]; then
        echo "  FAIL: $PNG is $SIZE bytes but is not a valid PNG (magic: $MAGIC)"
    else
        echo "  FAIL: $PNG exists but is empty"
    fi
else
    echo "  FAIL: no PNG written to $OUT"
    cat "$GEN_LOG"
fi

"$SANDBOX" clean >/dev/null 2>&1 || true
exit "$STATUS"
