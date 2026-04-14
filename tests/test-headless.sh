#!/bin/bash
# tests/test-headless.sh — Test headless mode and output capture
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="$SCRIPT_DIR/cli/sandbox"
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
        echo "  FAIL: $desc (expected '$expected')"
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

echo "=== Headless Mode Tests ==="

# Create a temp project
TEST_TMPDIR=$(mktemp -d)
trap "rm -rf $TEST_TMPDIR" EXIT

cat > "$TEST_TMPDIR/sandbox.yaml" <<'EOF'
name: headless-test
firewall: open
EOF

cd "$TEST_TMPDIR"
"$SANDBOX" build 2>/dev/null

# Test: headless without prompt fails
check_fails "headless without prompt fails" "$SANDBOX" run --headless

# Test: passthrough command works (not headless, just a command)
check_output "passthrough command" "hello-from-sandbox" "$SANDBOX" run -- echo "hello-from-sandbox"

# Test: log directory is created for headless runs
# We can't actually run claude -p in tests, but we can test the log dir creation
# by checking that the logs command works after the directory exists
LOG_DIR="$HOME/.sandbox/logs/headless-test"
mkdir -p "$LOG_DIR"
echo "test log output" > "$LOG_DIR/20260413-120000.log"
check_output "logs command shows output" "test log output" "$SANDBOX" logs
rm -rf "$LOG_DIR"

# Test: logs command fails when no logs exist
check_fails "logs fails when no logs" "$SANDBOX" logs

# Test: mode from config
cat > "$TEST_TMPDIR/sandbox.yaml" <<'EOF'
name: headless-test
claude:
  mode: headless
firewall: open
EOF

"$SANDBOX" build 2>/dev/null

# With mode: headless in config, running without prompt should still fail
check_fails "config headless without prompt fails" "$SANDBOX" run

# Clean up
"$SANDBOX" clean 2>/dev/null

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
