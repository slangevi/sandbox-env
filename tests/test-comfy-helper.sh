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

echo "-- workflow validation --"
check_output "UI export rejected by name" "looks like a ComfyUI UI export" \
    "$COMFY" run "$COMFY_WORKFLOWS/ui-export.json"
check_status "UI export exits 1" 1 "$COMFY" run "$COMFY_WORKFLOWS/ui-export.json"
check_output "unknown workflow lists options" "minimal-txt2img" \
    "$COMFY" run no-such-workflow

echo "-- overrides --"
OUT="$TMP/out1"
"$COMFY" run minimal-txt2img --set prompt="a blue cat" --set seed=99 --out "$OUT" >/dev/null 2>&1
check_output "manifest param reaches its node path" "a blue cat" \
    jq -r '.prompt["6"].inputs.text' "$TMP/last-prompt.json"
check_output "int param is a JSON number, not a string" "number" \
    jq -r '.prompt["3"].inputs.seed | type' "$TMP/last-prompt.json"
check_output "placeholder resolves to first installed model" "v1-5-pruned-emaonly-fp16.safetensors" \
    jq -r '.prompt["4"].inputs.ckpt_name' "$TMP/last-prompt.json"

"$COMFY" run minimal-txt2img --set prompt=x --set 5.inputs.width=768 --out "$TMP/out2" >/dev/null 2>&1
check_output "raw node path override applies" "768" \
    jq -r '.prompt["5"].inputs.width' "$TMP/last-prompt.json"

check_output "unknown param names the alternatives" "prompt" \
    "$COMFY" run minimal-txt2img --set nosuchparam=1
check_status "unknown param exits 1" 1 "$COMFY" run minimal-txt2img --set nosuchparam=1
check_output "non-integer for int param is refused" "must be an integer" \
    "$COMFY" run minimal-txt2img --set prompt=x --set seed=abc
check_output "uninstalled model lists what is installed" "v1-5-pruned-emaonly-fp16" \
    "$COMFY" run minimal-txt2img --set prompt=x --set checkpoint=nope.safetensors
check_status "uninstalled model exits 1" 1 \
    "$COMFY" run minimal-txt2img --set prompt=x --set checkpoint=nope.safetensors

echo "-- outputs --"
# Nested two levels under $TMP so the stub's "../../escape.png" traversal
# target, if it ever escaped, resolves to exactly $TMP/escape.png below —
# the same path the assertion checks. (A shallower nesting would let a
# traversal escape somewhere the assertion never looks, proving nothing.)
OUT3="$TMP/deep/out3"
"$COMFY" run minimal-txt2img --set prompt=x --out "$OUT3" >/dev/null 2>&1
check_output "output file written" "ComfyUI_00001_.png" ls "$OUT3"
check_output "traversing filename reduced to a basename" "escape.png" ls "$OUT3"
check_status "nothing escaped the output directory" 1 test -e "$TMP/escape.png"

echo "-- json output --"
check_output "json carries prompt_id" "stub-prompt-1" \
    "$COMFY" run minimal-txt2img --set prompt=x --out "$TMP/out4" --json
check_output "json carries the resolved seed as a number" '"seed": 99' \
    "$COMFY" run minimal-txt2img --set prompt=x --set seed=99 --out "$TMP/out5" --json
check_output "json lists written files" "ComfyUI_00001_.png" \
    "$COMFY" run minimal-txt2img --set prompt=x --out "$TMP/out6" --json

echo "-- raw node path parity with manifest names --"
check_not_output "raw path satisfies a required manifest param" "is required" \
    "$COMFY" run minimal-txt2img --set 6.inputs.text=hi --out "$TMP/outreq"
check_status "raw path satisfying a required param exits 0" 0 \
    "$COMFY" run minimal-txt2img --set 6.inputs.text=hi --out "$TMP/outreq2"
check_output "raw node path seed reaches the json seed field" '"seed": 777' \
    "$COMFY" run minimal-txt2img --set prompt=x --set 3.inputs.seed=777 --out "$TMP/outseed" --json

echo "-- failure paths --"
curl -sS -X POST "$COMFYUI_URL/_stub/pending" >/dev/null
check_output "timeout names the fetch escape hatch" "comfy fetch" \
    "$COMFY" run minimal-txt2img --set prompt=x --out "$TMP/out7" --timeout 2
# Interrupt mid-poll: the job id must survive into the message.
( "$COMFY" run minimal-txt2img --set prompt=x --out "$TMP/outint" --timeout 60 >/dev/null 2>"$TMP/int.err" &
  RUNPID=$!; sleep 3; kill -INT "$RUNPID" 2>/dev/null; wait "$RUNPID" 2>/dev/null ) || true
check_output "interrupt names the actual prompt id" "comfy fetch stub-prompt-1" cat "$TMP/int.err"
check_status "timeout exits 4" 4 \
    "$COMFY" run minimal-txt2img --set prompt=x --out "$TMP/out8" --timeout 2

check_output "non-numeric timeout is refused" "must be a non-negative integer" \
    "$COMFY" run minimal-txt2img --set prompt=x --timeout abc
check_status "non-numeric timeout exits 1, not a hang" 1 \
    "$COMFY" run minimal-txt2img --set prompt=x --timeout abc
check_status "non-numeric COMFY_JOB_TIMEOUT exits 1, not a hang" 1 \
    env COMFY_JOB_TIMEOUT=abc "$COMFY" run minimal-txt2img --set prompt=x

check_status "run against unreachable ComfyUI exits 2, not 1" 2 \
    env COMFYUI_URL="http://127.0.0.1:1" "$COMFY" run minimal-txt2img --set prompt=x

# Restart the stub so the pending flag clears, then drive the error path.
kill "$STUB_PID" 2>/dev/null; wait "$STUB_PID" 2>/dev/null
python3 "$SCRIPT_DIR/tests/fixtures/comfy-stub.py" "$PORT" "$TMP" &
STUB_PID=$!
for _ in $(seq 1 50); do
    curl -sf "$COMFYUI_URL/system_stats" >/dev/null 2>&1 && break
    sleep 0.1
done
curl -sS -X POST "$COMFYUI_URL/_stub/fail-exec" >/dev/null
check_output "execution error names the node" "KSampler" \
    "$COMFY" run minimal-txt2img --set prompt=x --out "$TMP/out9"
check_status "execution error exits 3" 3 \
    "$COMFY" run minimal-txt2img --set prompt=x --out "$TMP/out10"

echo "-- injection safety --"
# Every value crosses into JSON via jq --arg / --argjson, never a shell
# eval or hand-built string, so this should round-trip byte-identical and
# execute nothing — regardless of what it looks like to a shell.
HOSTILE='a "q" \ $(touch injected-X) `id`'
rm -f "$SCRIPT_DIR/injected-X" "./injected-X" 2>/dev/null
"$COMFY" run minimal-txt2img --set prompt="$HOSTILE" --out "$TMP/outhostile" >/dev/null 2>&1
check_status "hostile prompt round-trips byte-identical" 0 \
    jq -e --arg want "$HOSTILE" '.prompt["6"].inputs.text == $want' "$TMP/last-prompt.json"
check_status "hostile prompt's command substitution never executed" 1 \
    test -e "$SCRIPT_DIR/injected-X"
check_status "hostile prompt's command substitution never executed in cwd" 1 \
    test -e "./injected-X"
rm -f "$SCRIPT_DIR/injected-X" "./injected-X" 2>/dev/null

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
