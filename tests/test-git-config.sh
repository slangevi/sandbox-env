#!/bin/bash
# tests/test-git-config.sh — Test git config from sandbox.yaml
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="$SCRIPT_DIR/cli/sandbox"
PASS=0
FAIL=0

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
        echo "  FAIL: $desc (expected '$expected', got '$output')"
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

echo "=== Git Config Tests ==="

# Create a temp project with git config
TEST_TMPDIR=$(mktemp -d)
trap "rm -rf $TEST_TMPDIR" EXIT

cat > "$TEST_TMPDIR/sandbox.yaml" <<'EOF'
name: git-config-test
git:
  user.name: Test Author
  user.email: test@sandbox.dev
  init.defaultBranch: main
firewall: open
EOF

cd "$TEST_TMPDIR"
"$SANDBOX" build 2>/dev/null

# Test: git config values are applied
check_output "user.name applied" "Test Author" "$SANDBOX" run -- git config --global user.name
check_output "user.email applied" "test@sandbox.dev" "$SANDBOX" run -- git config --global user.email
check_output "init.defaultBranch applied" "main" "$SANDBOX" run -- git config --global init.defaultBranch

# Test: git config persists across runs (via persistent volume)
"$SANDBOX" run -- git config --global push.default simple 2>/dev/null
check_output "manual git config persists" "simple" "$SANDBOX" run -- git config --global push.default

# Clean up
"$SANDBOX" clean 2>/dev/null

# Test: dangerous git keys are blocked
cat > "$TEST_TMPDIR/sandbox.yaml" <<'EOF'
name: git-dangerous-test
git:
  user.name: Safe Name
  core.fsmonitor: "!evil-command"
firewall: open
EOF

"$SANDBOX" build 2>/dev/null

# user.name should work, core.fsmonitor should be blocked (check warning output)
local_output=$("$SANDBOX" run -- git config --global user.name 2>&1) || true
if echo "$local_output" | grep -q "Safe Name"; then
    echo "  PASS: safe key applied despite dangerous key in config"
    PASS=$((PASS + 1))
else
    echo "  FAIL: safe key not applied"
    FAIL=$((FAIL + 1))
fi

# core.fsmonitor should NOT be set
check_fails "dangerous key blocked" bash -c "cd $TEST_TMPDIR && $SANDBOX run -- git config --global core.fsmonitor"

"$SANDBOX" clean 2>/dev/null

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
