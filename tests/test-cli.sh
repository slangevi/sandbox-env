#!/bin/bash
# tests/test-cli.sh — Verify CLI commands work correctly
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="$SCRIPT_DIR/cli/sandbox"
FIXTURES="$SCRIPT_DIR/tests/fixtures"
PASS=0
FAIL=0

check() {
    local desc="$1"
    shift
    if "$@" &>/dev/null; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== CLI Tests ==="

# help
check "help command works" "$SANDBOX" help

# init
TEST_TMPDIR=$(mktemp -d)
check "init creates sandbox.yaml" bash -c "cd $TEST_TMPDIR && $SANDBOX init && test -f sandbox.yaml"
rm -rf "$TEST_TMPDIR"

# build (using fixture)
check "build creates project image" bash -c "cd $FIXTURES && $SANDBOX build"
check "project image exists" docker image inspect sandbox-test-project:latest

# clean
check "clean removes project image" bash -c "cd $FIXTURES && $SANDBOX clean"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
