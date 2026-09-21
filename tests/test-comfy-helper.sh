#!/bin/bash
# tests/test-comfy-helper.sh — the comfy helper against a stub ComfyUI.
# Requires host python3. Never requires Docker or a live ComfyUI.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMFY="$SCRIPT_DIR/features/comfyui.d/comfy"
PASS=0
FAIL=0

command -v python3 >/dev/null || { echo "SKIP: host python3 required"; exit 0; }

TMP=$(mktemp -d)
STUB_PID=""
cleanup() { [ -n "$STUB_PID" ] && kill "$STUB_PID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

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
    if ! echo "$output" | grep -q -- "$unexpected"; then
        echo "  PASS: $desc"; PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (should not contain '$unexpected')"
        echo "        got: $output"
        FAIL=$((FAIL + 1))
    fi
}

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

# Pick a free port, start the stub, wait for it to answer.
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
python3 "$SCRIPT_DIR/tests/fixtures/comfy-stub.py" "$PORT" "$TMP" &
STUB_PID=$!
for _ in $(seq 1 50); do
    curl -sf "http://127.0.0.1:$PORT/system_stats" >/dev/null 2>&1 && break
    sleep 0.1
done

export COMFYUI_URL="http://127.0.0.1:$PORT"
export COMFY_WORKFLOWS="$SCRIPT_DIR/tests/fixtures/comfy-workflows"

echo "=== comfy Helper Tests ==="

echo "-- status and models --"
check_output "status reports version"   "0.33.1"     "$COMFY" status
check_output "status reports device"    "stub cuda"  "$COMFY" status
check_status "status succeeds"          0            "$COMFY" status
check_output "models lists checkpoints" "v1-5-pruned-emaonly-fp16.safetensors" "$COMFY" models
check_output "models groups by folder"  "checkpoints" "$COMFY" models
check_output "models can select folder" "vae-ft-mse"  "$COMFY" models vae
check_not_output "empty folders omitted" "loras" "$COMFY" models

echo "-- not wired in --"
check_output "unset URL explains itself" "not wired into this sandbox" \
    env -u COMFYUI_URL "$COMFY" status
check_status "unset URL exits 1" 1 env -u COMFYUI_URL "$COMFY" status

echo "-- unreachable --"
check_status "unreachable exits 2" 2 \
    env COMFYUI_URL="http://127.0.0.1:1" "$COMFY" status

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
