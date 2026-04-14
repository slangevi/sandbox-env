#!/bin/bash
# tests/test-commands.sh — Test convenience commands error paths
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="$SCRIPT_DIR/cli/sandbox"
FIXTURES="$SCRIPT_DIR/tests/fixtures"
PASS=0
FAIL=0

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

echo "=== Convenience Command Tests ==="

cd "$FIXTURES"

# -- claude command --
# Without image: should fail
TEST_TMPDIR=$(mktemp -d)
cat > "$TEST_TMPDIR/sandbox.yaml" <<'EOF'
name: no-image-test
firewall: open
EOF
check_fails "claude fails without image" bash -c "cd $TEST_TMPDIR && $SANDBOX claude"
rm -rf "$TEST_TMPDIR"

# -- claude-local command --
cd "$FIXTURES"
"$SANDBOX" build 2>/dev/null

# Without model arg: should fail
check_fails "claude-local fails without model" bash -c "cd $FIXTURES && $SANDBOX claude-local"

# Without ollama feature: should fail (test-project has no ollama)
check_output "claude-local requires ollama feature" "ollama feature is required" bash -c "cd $FIXTURES && $SANDBOX claude-local qwen3.5"

# -- remote-local command --
check_fails "remote-local fails without model" bash -c "cd $FIXTURES && $SANDBOX remote-local"

# -- ollama command (no running container) --
check_output "ollama fails without running container" "No running sandbox" bash -c "cd $FIXTURES && $SANDBOX ollama list"

# -- llm command (no running container) --
check_output "llm fails without running container" "No running sandbox" bash -c "cd $FIXTURES && $SANDBOX llm test"

# -- models command --
check_output "models shows help" "Usage:" "$SANDBOX" models
check_fails "models pull without name" "$SANDBOX" models pull
check_fails "models rm without name" "$SANDBOX" models rm

# -- models with invalid name --
check_fails "models pull invalid name" "$SANDBOX" models pull '"; rm -rf /'

# -- clean-models when no volume --
check "clean-models when no volume" "$SANDBOX" clean-models

# Clean up
"$SANDBOX" clean 2>/dev/null

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
