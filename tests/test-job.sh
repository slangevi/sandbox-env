#!/bin/bash
# tests/test-job.sh — `sandbox job`: argument validation, naming, exit codes,
# already-running refusal, stop isolation, strict firewall in a job.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="$SCRIPT_DIR/cli/sandbox"
PASS=0
FAIL=0
TMP=$(mktemp -d)
cleanup() {
    docker rm -f sandbox-job-test-t sandbox-job-test-slow sandbox-job-strict-t >/dev/null 2>&1 || true
    docker image rm sandbox-job-test:latest sandbox-job-strict:latest >/dev/null 2>&1 || true
    # _build_docker_args creates the projects' named volumes on first use.
    docker volume ls -q | grep -E '^sandbox-job-(test|strict)-' | xargs -r docker volume rm >/dev/null 2>&1 || true
    rm -rf "$TMP"
}
trap cleanup EXIT

check_output() {
    local desc="$1" expected="$2"; shift 2
    local output
    output=$("$@" 2>&1) || true
    if echo "$output" | grep -q -- "$expected"; then
        echo "  PASS: $desc"; PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (expected '$expected')"; echo "        got: $output"
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
        echo "  FAIL: $desc (expected exit $expected, got $status)"; FAIL=$((FAIL + 1))
    fi
}

echo "=== sandbox job Tests ==="

if ! docker image inspect sandbox-base:latest >/dev/null 2>&1; then
    echo "  ERROR: these tests need sandbox-base:latest. Run: cli/sandbox build-base"
    exit 1
fi

PROJ="$TMP/proj"
mkdir -p "$PROJ"
cat > "$PROJ/sandbox.yaml" <<'EOF'
name: job-test
firewall: open
EOF
# A stand-in project image: the entrypoint and tools are the base image's.
docker image tag sandbox-base:latest sandbox-job-test:latest >/dev/null 2>&1
job() { (cd "$PROJ" && "$SANDBOX" job "$@"); }
dry() { (cd "$PROJ" && SANDBOX_DRY_RUN=1 "$SANDBOX" job "$@"); }

echo "-- validation --"
check_output "no suffix is a usage error" "Usage: sandbox job" job
check_status "...exit 1" 1 job
check_output "suffix 'headless' is reserved" "reserved" job headless -- true
check_output "invalid suffix refused" "Invalid job name" job 'Bad;Name' -- true
check_output "missing command refused" "requires a command" job t
check_output "missing command after -- refused" "requires a command" job t --
check_output "--env without = refused" "--env expects KEY=VALUE" job t --env FOO -- true
check_output "--env PATH refused" "is not allowed" job t --env PATH=/x -- true
check_output "unknown flag refused" "Unknown option" job t --bogus -- true
check_output "--spark without model refused" "--spark requires a model name" job t --spark

echo "-- dry run --"
check_output "container is sandbox-<name>-<suffix>" "--name sandbox-job-test-t " dry t -- echo hi
check_output "image is the project image" "sandbox-job-test:latest echo hi" dry t -- echo hi
check_output "--env reaches docker" "-e FOO=bar" dry t --env FOO=bar -- echo hi
check_output "flags after -- belong to the command" "sandbox-job-test:latest python3 -m x --env Y" \
    dry t -- python3 -m x --env Y
dry_out=$(dry t -- echo hi 2>&1 || true)
# Also require the docker argv itself: an error message has no " -it " either.
if echo "$dry_out" | grep -q -- " -it " || ! echo "$dry_out" | grep -q -- "--name sandbox-job-test-t "; then
    echo "  FAIL: job must not allocate a TTY"; FAIL=$((FAIL + 1))
else
    echo "  PASS: no TTY"; PASS=$((PASS + 1))
fi

echo "-- real runs --"
check_output "stdout passes through" "job-ok" job t -- echo job-ok
check_status "exit code passes through" 7 job t -- bash -c 'exit 7'
check_status "exit 0 on success" 0 job t -- true

echo "-- already running --"
(cd "$PROJ" && "$SANDBOX" job slow -- sleep 60) >/dev/null 2>&1 &
for _ in $(seq 1 30); do
    [ "$(docker container inspect --format '{{.State.Running}}' sandbox-job-test-slow 2>/dev/null)" = "true" ] && break
    sleep 1
done
check_output "a running job is refused" "already running" job slow -- true
check_status "...with exit 75" 75 job slow -- true

echo "-- stop leaves jobs alone --"
(cd "$PROJ" && "$SANDBOX" stop) >/dev/null 2>&1 || true
if [ "$(docker container inspect --format '{{.State.Running}}' sandbox-job-test-slow 2>/dev/null)" = "true" ]; then
    echo "  PASS: sandbox stop did not stop the job"; PASS=$((PASS + 1))
else
    echo "  FAIL: sandbox stop stopped the job container"; FAIL=$((FAIL + 1))
fi
docker rm -f sandbox-job-test-slow >/dev/null 2>&1 || true
wait || true

echo "-- strict firewall applies to jobs --"
PROJ_STRICT="$TMP/proj-strict"
mkdir -p "$PROJ_STRICT"
cat > "$PROJ_STRICT/sandbox.yaml" <<'EOF'
name: job-strict
firewall: strict
EOF
docker image tag sandbox-base:latest sandbox-job-strict:latest >/dev/null 2>&1
sjob() { (cd "$PROJ_STRICT" && "$SANDBOX" job "$@"); }
check_status "strict job cannot reach a non-allowed host" 7 \
    sjob t -- bash -c 'curl --connect-timeout 5 -sf https://example.com >/dev/null && exit 0 || exit 7'
check_status "strict job reaches an allowlisted host" 0 \
    sjob t -- bash -c 'curl --connect-timeout 10 -sf https://api.github.com >/dev/null'

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
