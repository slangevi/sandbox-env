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

echo "-- option and pair parsing --"
# `${pair%%=*}` and `${pair#*=}` BOTH return the whole string when there is no
# '=', so `--set prompt` used to set the parameter "prompt" to the literal
# string "prompt" and report success.
# Every refusal check below carries an explicit --out under $TMP even though
# it must never download anything: the default is ./comfy-out, so when one of
# these guards regresses (exactly the case a neutering check reproduces) the
# suite writes into the repo working tree instead of its own scratch dir.
check_output "--set without '=' is refused" "expects key=value" \
    "$COMFY" run minimal-txt2img --out "$TMP/nope" --set prompt
check_status "...and exits 1" 1 "$COMFY" run minimal-txt2img --out "$TMP/nope" --set prompt
# Against the stub's recorded body: with the guard gone this submitted a graph
# whose prompt node held the literal string "prompt", which no grep of the
# command's own output would ever show.
rm -f "$TMP/last-prompt.json"
"$COMFY" run minimal-txt2img --out "$TMP/nope" --set prompt --no-wait >/dev/null 2>&1
check_status "...and submits nothing at all" 1 test -e "$TMP/last-prompt.json"
# An option in final position expanded "$2" under `set -u` into a raw bash
# abort. A usage message is the point; "unbound variable" is the regression.
check_output "--set as the final argument gives a usage message" "--set needs a value" \
    "$COMFY" run minimal-txt2img --out "$TMP/nope" --set
check_not_output "...not a bash unbound-variable error" "unbound variable" \
    "$COMFY" run minimal-txt2img --out "$TMP/nope" --set
check_status "...exiting 1" 1 "$COMFY" run minimal-txt2img --out "$TMP/nope" --set
check_output "--out as the final argument gives a usage message" "--out needs a value" \
    "$COMFY" run minimal-txt2img --out
check_output "txt2img's --prompt is guarded the same way" "--prompt needs a value" \
    "$COMFY" txt2img --out "$TMP/nope" --prompt
check_not_output "...with no bash abort either" "unbound variable" \
    "$COMFY" txt2img --out "$TMP/nope" --prompt
check_output "fetch's --out is guarded too" "--out needs a value" \
    "$COMFY" fetch stub-prompt-1 --out
check_output "upload's --name is guarded too" "--name needs a value" \
    "$COMFY" upload "$SCRIPT_DIR/tests/fixtures/comfy-stub.py" --name
check_output "job's --timeout is guarded too" "--timeout needs a value" \
    "$COMFY" job stub-prompt-1 --timeout

echo "-- integer precision --"
# jq 1.6 stores numbers as IEEE doubles: 18446744073709551615 becomes
# 18446744073709552000 on the way into the graph, so ComfyUI rendered a
# different seed than --json reported.
rm -f "$TMP/last-prompt.json"
check_output "a 2^64-1 seed is refused, naming the limit" "9007199254740992" \
    "$COMFY" run minimal-txt2img --out "$TMP/nope" --set prompt=x --set seed=18446744073709551615
check_status "...and exits 1" 1 \
    "$COMFY" run minimal-txt2img --out "$TMP/nope" --set prompt=x --set seed=18446744073709551615
# Against the stub's recorded body, not the command's own output: the rounded
# value only ever appears in what was SUBMITTED, so grepping stdout/stderr for
# it passed with the whole guard deleted.
check_status "...and nothing is submitted at all" 1 test -e "$TMP/last-prompt.json"
"$COMFY" run minimal-txt2img --out "$TMP/nope" --set prompt=x --set seed=9007199254740991 \
    --no-wait >/dev/null 2>&1
# Asserted against the RAW submitted body, not jq's reading of it: a rounded
# value would still compare equal through a second double conversion.
check_status "2^53-1 is accepted and reaches ComfyUI unrounded" 0 \
    grep -q '9007199254740991' "$TMP/last-prompt.json"
check_status "...and no rounded neighbour was submitted" 1 \
    grep -q '9007199254740992' "$TMP/last-prompt.json"

echo "-- manifest default of false --"
# jq's `//` treats `false` as absent, so `.default // empty` dropped a bool
# parameter defaulting to false and the graph kept its own `true`.
"$COMFY" run bool-default --out "$TMP/nope" --no-wait >/dev/null 2>&1
check_output "a manifest default of false is applied over a graph true" "^false\$" \
    jq -r '.prompt["1"].inputs.flag' "$TMP/last-prompt.json"
check_output "...as a real JSON boolean, not a string" "^boolean\$" \
    jq -r '.prompt["1"].inputs.flag | type' "$TMP/last-prompt.json"

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

# These three run while the stub is still in pending_forever mode, so a
# regression in require_numeric_timeout would poll until something kills it.
# Bounded with `timeout 10` — exactly as the `job --wait` pair near the end of
# this file is — so the regression net reports a failure instead of BEING the
# hang: unwrapped, neutering require_numeric_timeout wedged this suite with no
# output at all until the harness killed it at 120s, which in CI hangs the job.
check_output "non-numeric timeout is refused" "must be a non-negative integer" \
    timeout 10 "$COMFY" run minimal-txt2img --set prompt=x --timeout abc
check_status "non-numeric timeout exits 1, not a hang" 1 \
    timeout 10 "$COMFY" run minimal-txt2img --set prompt=x --timeout abc
check_status "non-numeric COMFY_JOB_TIMEOUT exits 1, not a hang" 1 \
    timeout 10 env COMFY_JOB_TIMEOUT=abc "$COMFY" run minimal-txt2img --set prompt=x

check_status "run against unreachable ComfyUI exits 2, not 1" 2 \
    env COMFYUI_URL="http://127.0.0.1:1" "$COMFY" run minimal-txt2img --set prompt=x

# The stub is still in pending_forever mode here, which is exactly the case
# --no-wait exists for: a job that will not finish inside any --timeout the
# caller would sit through. A waiting run exits 4 after its timeout (above);
# --no-wait must come straight back with the id instead. `timeout 10` so a
# regression fails loudly rather than wedging the suite.
check_status "--no-wait returns immediately on a job that never finishes" 0 \
    timeout 10 "$COMFY" run minimal-txt2img --set prompt=x --no-wait --out "$TMP/outnw-pending"
check_output "...and still reports the prompt id" "stub-prompt-1" \
    timeout 10 "$COMFY" run minimal-txt2img --set prompt=x --no-wait --out "$TMP/outnw-pending"
# --timeout is inert under --no-wait but must still be validated, so one
# spelling of the command can't quietly accept what the other refuses.
check_status "--no-wait still refuses a non-numeric --timeout" 1 \
    timeout 10 "$COMFY" run minimal-txt2img --set prompt=x --no-wait --timeout abc

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
# fetch used to read `.[$id].outputs // {}` with no status check at all, so a
# failed job downloaded nothing and exited 0 — indistinguishable from a
# successful render that happened to save no files.
check_output "fetch of a failed job surfaces the execution error" "KSampler" \
    "$COMFY" fetch stub-prompt-1 --out "$TMP/ferr"
check_status "...and exits 3, not 0" 3 "$COMFY" fetch stub-prompt-1 --out "$TMP/ferr"

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

kill "$STUB_PID" 2>/dev/null; wait "$STUB_PID" 2>/dev/null
python3 "$SCRIPT_DIR/tests/fixtures/comfy-stub.py" "$PORT" "$TMP" &
STUB_PID=$!
for _ in $(seq 1 50); do
    curl -sf "$COMFYUI_URL/system_stats" >/dev/null 2>&1 && break
    sleep 0.1
done

echo "-- workflows listing --"
check_output "workflows lists the fixture"   "minimal-txt2img" "$COMFY" workflows
check_output "workflows shows description"   "Minimal SD1.5"   "$COMFY" workflows
check_output "workflows shows params"        "prompt"          "$COMFY" workflows
check_not_output "workflows hides manifest files" "params.json" "$COMFY" workflows

echo "-- txt2img --"
"$COMFY" txt2img --prompt "a green pear" --out "$TMP/t1" >/dev/null 2>&1
check_output "txt2img sets the prompt node" "a green pear" \
    jq -r '.prompt["6"].inputs.text' "$TMP/last-prompt.json"
check_output "txt2img seed is a number" "number" \
    jq -r '.prompt["3"].inputs.seed | type' "$TMP/last-prompt.json"
"$COMFY" txt2img --prompt p --width 768 --steps 12 --out "$TMP/t2" >/dev/null 2>&1
check_output "txt2img passes width through" "768" \
    jq -r '.prompt["5"].inputs.width' "$TMP/last-prompt.json"
check_output "txt2img passes steps through" "12" \
    jq -r '.prompt["3"].inputs.steps' "$TMP/last-prompt.json"
check_status "txt2img succeeds" 0 "$COMFY" txt2img --prompt p --out "$TMP/t3"
check_output "txt2img non-numeric timeout is refused" "must be a non-negative integer" \
    "$COMFY" txt2img --prompt p --timeout abc --out "$TMP/tbad"
check_status "txt2img non-numeric timeout exits 1, not a hang" 1 \
    "$COMFY" txt2img --prompt p --timeout abc --out "$TMP/tbad"

echo "-- video with no tagged workflow --"
# A workflows dir holding only the txt2img fixture, so the missing-tag path
# stays testable now that a video fixture exists in the main fixtures dir.
mkdir -p "$TMP/wf-novideo" && cp "$COMFY_WORKFLOWS"/minimal-txt2img.* "$TMP/wf-novideo/"
check_output "video explains the missing tag" "no workflow tagged 'video'" \
    env COMFY_WORKFLOWS="$TMP/wf-novideo" "$COMFY" video --prompt p --out "$TMP/v1"
check_status "video exits 1 when untagged" 1 \
    env COMFY_WORKFLOWS="$TMP/wf-novideo" "$COMFY" video --prompt p --out "$TMP/v1"

echo "-- job and fetch --"
check_output "job reports status"   "success" "$COMFY" job stub-prompt-1
check_status "job succeeds"         0         "$COMFY" job stub-prompt-1
"$COMFY" fetch stub-prompt-1 --out "$TMP/f1" >/dev/null 2>&1
check_output "fetch writes outputs" "ComfyUI_00001_.png" ls "$TMP/f1"
check_output "fetch sanitizes filenames too" "escape.png" ls "$TMP/f1"
# job --wait shares wait_for_job's poll loop with `comfy run`: a non-numeric
# --timeout must be refused up front, not poll forever. Bounded with `timeout
# 10` so a regression fails this suite loudly instead of wedging it.
check_output "job --wait non-numeric timeout is refused" "must be a non-negative integer" \
    timeout 10 "$COMFY" job stub-prompt-1 --wait --timeout abc
check_status "job --wait non-numeric timeout exits 1, not a hang" 1 \
    timeout 10 "$COMFY" job stub-prompt-1 --wait --timeout abc

echo "-- fetch refuses what it cannot fetch --"
# A history with no entry for the id iterated zero rows and returned 0: an
# agent that runs `run --no-wait` and fetches straight afterwards got an empty
# directory, no output, and every reason to think the render produced no files.
check_output "fetch of an unknown id says so" "no such job" \
    "$COMFY" fetch does-not-exist --out "$TMP/fbad"
check_status "...and exits 1" 1 "$COMFY" fetch does-not-exist --out "$TMP/fbad"
check_status "...and creates no output directory to be mistaken for a result" 1 \
    test -e "$TMP/fbad"
# Still queued: the job is real, just not finished. Different message, and the
# hint has to be the command that actually waits.
curl -sS -X POST -d '{"pending":["queued-only"]}' "$COMFYUI_URL/_stub/queue" >/dev/null
check_output "fetch of a still-queued job points at job --wait" \
    "comfy job queued-only --wait" "$COMFY" fetch queued-only --out "$TMP/fq"
check_status "...and exits 1" 1 "$COMFY" fetch queued-only --out "$TMP/fq"
check_status "...and creates no output directory either" 1 test -e "$TMP/fq"
curl -sS -X POST -d '{"pending":[]}' "$COMFYUI_URL/_stub/queue" >/dev/null
check_status "a finished job still fetches" 0 \
    "$COMFY" fetch stub-prompt-1 --out "$TMP/fok"
check_output "...and still writes its outputs" "ComfyUI_00001_.png" ls "$TMP/fok"

echo "-- no-wait, then job and fetch --"
# The submit / collect-later path the spec's command table calls for, and the
# reason `comfy job` and `comfy fetch` exist as separate commands at all.
NW_OUT="$TMP/outnw"
"$COMFY" run minimal-txt2img --set prompt=x --no-wait --out "$NW_OUT" \
    >"$TMP/nowait.out" 2>"$TMP/nowait.err"
check_output "--no-wait prints the prompt id, and only that, on stdout" \
    "^stub-prompt-1\$" cat "$TMP/nowait.out"
check_output "...with the follow-up hint on stderr instead" \
    "comfy fetch stub-prompt-1" cat "$TMP/nowait.err"
check_status "...and downloads nothing (the output directory is never created)" 1 \
    test -e "$NW_OUT"
check_status "--no-wait exits 0" 0 \
    "$COMFY" run minimal-txt2img --set prompt=x --no-wait --out "$TMP/outnw2"
check_output "--no-wait --json reports status submitted" '"status": "submitted"' \
    "$COMFY" run minimal-txt2img --set prompt=x --no-wait --json
check_output "--no-wait --json carries the prompt id" '"prompt_id": "stub-prompt-1"' \
    "$COMFY" run minimal-txt2img --set prompt=x --no-wait --json
check_output "--no-wait --json carries the resolved seed as a number" '"seed": 99' \
    "$COMFY" run minimal-txt2img --set prompt=x --set seed=99 --no-wait --json
# The round trip that follows a --no-wait submission.
check_output "job picks the submitted id up afterwards" "stub-prompt-1 success" \
    "$COMFY" job stub-prompt-1
"$COMFY" fetch stub-prompt-1 --out "$TMP/nwfetch" >/dev/null 2>&1
check_output "fetch then retrieves its outputs" "ComfyUI_00001_.png" ls "$TMP/nwfetch"
check_status "fetch after --no-wait exits 0" 0 \
    "$COMFY" fetch stub-prompt-1 --out "$TMP/nwfetch2"

echo "-- upload and cancel --"
echo "fake" > "$TMP/in.png"
check_output "upload reports the stored name" "uploaded.png" "$COMFY" upload "$TMP/in.png"
check_status "upload succeeds"  0 "$COMFY" upload "$TMP/in.png"
check_output "upload rejects a missing file" "no such file" "$COMFY" upload "$TMP/nope.png"
# --name lands in a curl -F multipart field ("image=@file;filename=$name"):
# a ';' or '=' in it would alter curl's own field parsing, not just the
# remote filename. Not shell or JSON injection, but still agent-controlled
# input that must be validated.
check_output "upload rejects a hostile --name" "must not contain" \
    "$COMFY" upload "$TMP/in.png" --name 'evil.png;filename=hack.sh'
check_status "upload rejects a hostile --name exits 1" 1 \
    "$COMFY" upload "$TMP/in.png" --name 'evil.png;filename=hack.sh'
# The file path lands in the same field, so it gets the same guard — otherwise
# the --name check above reads as stronger protection than it actually is.
#
# The hostile character MUST sit in a directory component, never the basename:
# `name` defaults to `basename -- "$file"`, so a basename like
# "in;filename=hack.sh.png" trips the --name guard above and produces the same
# "must not contain" message and exit 1 whether or not the $file guard exists
# at all. (That was the first version of these two checks, and deleting the
# whole `case "$file"` block left them both green.) A clean basename under a
# hostile directory can only be caught by the $file guard — and the expected
# text is the $file guard's own wording, not the shared prefix.
mkdir -p "$TMP/ev;il" "$TMP/ev=il"
cp "$TMP/in.png" "$TMP/ev;il/clean.png"
cp "$TMP/in.png" "$TMP/ev=il/clean.png"
check_output "upload rejects a ';' in a directory component of the path" \
    "the file path must not contain" "$COMFY" upload "$TMP/ev;il/clean.png"
check_status "...and exits 1" 1 "$COMFY" upload "$TMP/ev;il/clean.png"
check_output "upload rejects an '=' in a directory component of the path" \
    "the file path must not contain" "$COMFY" upload "$TMP/ev=il/clean.png"
check_status "...and exits 1 too" 1 "$COMFY" upload "$TMP/ev=il/clean.png"
check_status "cancel succeeds" 0 "$COMFY" cancel

echo "-- cancel targets the job it was given --"
# /interrupt takes no id: it stops whatever is executing. Issuing it
# unconditionally meant `comfy cancel B`, with A on the GPU and B merely
# queued, killed A and let B start — reported as "interrupted".
curl -sS -X POST -d '{"running":"running-job","pending":["queued-job"]}' \
    "$COMFYUI_URL/_stub/queue" >/dev/null
rm -f "$TMP/interrupts" "$TMP/last-queue-post.json"
check_output "cancelling a queued job reports a dequeue, not an interrupt" \
    "removed queued-job from the queue" "$COMFY" cancel queued-job
check_status "...and the running job was never interrupted" 1 test -e "$TMP/interrupts"
check_status "...while the queue delete did name the queued job" 0 \
    jq -e '.delete[0] == "queued-job"' "$TMP/last-queue-post.json"
rm -f "$TMP/interrupts"
check_output "cancelling the RUNNING job does interrupt it" \
    "interrupted running-job" "$COMFY" cancel running-job
check_status "...and an interrupt really was issued" 0 test -e "$TMP/interrupts"
rm -f "$TMP/interrupts"
check_output "cancel with no id interrupts whatever is running" \
    "interrupted running-job" "$COMFY" cancel
check_status "...issuing an interrupt" 0 test -e "$TMP/interrupts"
curl -sS -X POST -d '{"running":"","pending":[]}' "$COMFYUI_URL/_stub/queue" >/dev/null

echo "-- edit --"
"$COMFY" edit --image already-uploaded.png --prompt "make it a pear" --out "$TMP/e1" >/dev/null 2>&1
check_output "edit passes an uploaded name through to the LoadImage node" "already-uploaded.png" \
    jq -r '.prompt["10"].inputs.image' "$TMP/last-prompt.json"
check_output "edit sets the prompt node" "make it a pear" \
    jq -r '.prompt["6"].inputs.text' "$TMP/last-prompt.json"
echo "fake-png" > "$TMP/local-photo.png"
rm -f "$TMP/last-upload.raw"
"$COMFY" edit --image "$TMP/local-photo.png" --prompt p --out "$TMP/e2" >/dev/null 2>&1
check_output "edit auto-uploads a local file and uses the STORED name" "uploaded.png" \
    jq -r '.prompt["10"].inputs.image' "$TMP/last-prompt.json"
check_output "...and the upload carried the local file's name" 'filename="local-photo.png"' \
    cat "$TMP/last-upload.raw"
check_status "edit succeeds" 0 "$COMFY" edit --image "$TMP/local-photo.png" --prompt p --out "$TMP/e3"
check_output "edit requires --image" "'image' is required" "$COMFY" edit --prompt p --out "$TMP/e4"
check_status "edit without --image exits 1" 1 "$COMFY" edit --prompt p --out "$TMP/e4"
check_output "edit's --image is guarded" "--image needs a value" "$COMFY" edit --prompt p --image
check_output "edit explains a missing tag" "no workflow tagged 'edit'" \
    env COMFY_WORKFLOWS="$TMP/wf-novideo" "$COMFY" edit --image x.png --prompt p --out "$TMP/e5"

echo "-- video flags --"
"$COMFY" video --prompt "waves" --duration 3 --fps 12 --frames 37 --out "$TMP/vf1" >/dev/null 2>&1
check_output "video --duration reaches its param" "^3$" jq -r '.prompt["13"].inputs.value' "$TMP/last-prompt.json"
check_output "video --fps reaches its param" "^12$" jq -r '.prompt["12"].inputs.value' "$TMP/last-prompt.json"
check_output "video --frames reaches its param" "^37$" jq -r '.prompt["11"].inputs.length' "$TMP/last-prompt.json"
check_output "video params are JSON numbers" "number" jq -r '.prompt["13"].inputs.value | type' "$TMP/last-prompt.json"
check_status "video succeeds" 0 "$COMFY" video --prompt p --out "$TMP/vf2"
check_output "video --duration is guarded" "--duration needs a value" "$COMFY" video --prompt p --duration
check_output "video --fps is guarded" "--fps needs a value" "$COMFY" video --prompt p --fps
check_output "txt2img rejects --duration on a workflow without it" "unknown parameter 'duration'" \
    "$COMFY" txt2img --prompt p --duration 3 --out "$TMP/vf3"

echo "-- --workflow picks a non-default workflow --"
"$COMFY" video --prompt p --out "$TMP/wa0" >/dev/null 2>&1
check_output "video without --workflow still uses the default" "^video/video-fixture$" \
    jq -r '.prompt["9"].inputs.filename_prefix' "$TMP/last-prompt.json"
"$COMFY" video --workflow video-alt --prompt "waves" --duration 3 --out "$TMP/wa1" >/dev/null 2>&1
check_output "video --workflow runs the named workflow" "^video/video-alt$" \
    jq -r '.prompt["9"].inputs.filename_prefix' "$TMP/last-prompt.json"
check_output "...with the other flags still mapped onto its params" "^3$" \
    jq -r '.prompt["13"].inputs.value' "$TMP/last-prompt.json"
check_output "--workflow is order-independent" "^video/video-alt$" \
    sh -c '"$1" video --prompt p --workflow video-alt --out "$2" >/dev/null 2>&1; jq -r ".prompt[\"9\"].inputs.filename_prefix" "$3"' _ "$COMFY" "$TMP/wa2" "$TMP/last-prompt.json"
rm -f "$TMP/last-prompt.json"
check_output "a workflow without the wrapper's tag is refused" "not tagged 'video'" \
    "$COMFY" video --workflow minimal-txt2img --prompt p --out "$TMP/wa3"
check_status "...exiting 1" 1 "$COMFY" video --workflow minimal-txt2img --prompt p --out "$TMP/wa3"
check_output "...and the refusal lists the video workflows" "video-alt" \
    "$COMFY" video --workflow minimal-txt2img --prompt p --out "$TMP/wa3"
check_status "...and submits nothing" 1 test -e "$TMP/last-prompt.json"
check_output "an unknown --workflow lists the choices" "video-fixture" \
    "$COMFY" video --workflow nosuch --prompt p --out "$TMP/wa4"
check_status "...exiting 1" 1 "$COMFY" video --workflow nosuch --prompt p --out "$TMP/wa4"
# comfy video is on the approval gate's allowlist and comfy run is not, so
# --workflow must never reach a file outside the shared library: a workflow
# the agent wrote itself (with a manifest claiming the tag) would otherwise
# run ungated.
mkdir -p "$TMP/rogue" && cp "$COMFY_WORKFLOWS"/video-alt.json "$COMFY_WORKFLOWS"/video-alt.params.json "$TMP/rogue/"
check_output "--workflow refuses a path" "library name" \
    "$COMFY" video --workflow "$TMP/rogue/video-alt.json" --prompt p --out "$TMP/wa5"
check_status "...exiting 1" 1 "$COMFY" video --workflow "$TMP/rogue/video-alt" --prompt p --out "$TMP/wa5"
check_status "...including a relative escape" 1 \
    "$COMFY" video --workflow ../video-alt --prompt p --out "$TMP/wa5"
check_status "...and nothing was submitted" 1 test -e "$TMP/last-prompt.json"
check_output "--workflow is guarded" "--workflow needs a value" "$COMFY" video --prompt p --workflow
check_output "txt2img accepts --workflow too" "^a pear$" \
    sh -c '"$1" txt2img --workflow minimal-txt2img --prompt "a pear" --out "$2" >/dev/null 2>&1; jq -r ".prompt[\"6\"].inputs.text" "$3"' _ "$COMFY" "$TMP/wa6" "$TMP/last-prompt.json"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
