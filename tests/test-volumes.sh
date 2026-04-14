#!/bin/bash
# tests/test-volumes.sh — Test volume creation, persistence, and cleanup
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="$SCRIPT_DIR/cli/sandbox"
FIXTURES="$SCRIPT_DIR/tests/fixtures"
PASS=0
FAIL=0

check() {
    local desc="$1"
    shift
    if "$@" &>/dev/null 2>&1; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        FAIL=$((FAIL + 1))
    fi
}

check_output() {
    local desc="$1"
    local expected="$2"
    shift 2
    local output
    output=$("$@" 2>&1) || true
    if echo "$output" | grep -q "$expected"; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (expected '$expected' in output)"
        FAIL=$((FAIL + 1))
    fi
}

check_fails() {
    local desc="$1"
    shift
    if "$@" &>/dev/null 2>&1; then
        echo "  FAIL: $desc (expected failure, got success)"
        FAIL=$((FAIL + 1))
    else
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    fi
}

echo "=== Volume Lifecycle Tests ==="

cd "$FIXTURES"
"$SANDBOX" build 2>/dev/null

# Test: Running creates all 3 per-project volumes
"$SANDBOX" run -- echo "creating volumes" 2>/dev/null
check "claude volume created" docker volume inspect sandbox-test-project-claude
check "home volume created" docker volume inspect sandbox-test-project-home
check "cache volume created" docker volume inspect sandbox-test-project-cache

# Test: Data persists across runs
"$SANDBOX" run -- bash -c 'echo "persist-test" > /home/node/.cache/test-persist' 2>/dev/null
check_output "cache data persists" "persist-test" bash -c "cd $FIXTURES && $SANDBOX run -- cat /home/node/.cache/test-persist"

# Test: Clean removes all per-project volumes
"$SANDBOX" clean 2>/dev/null
check_fails "claude volume removed" docker volume inspect sandbox-test-project-claude
check_fails "home volume removed" docker volume inspect sandbox-test-project-home
check_fails "cache volume removed" docker volume inspect sandbox-test-project-cache

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
