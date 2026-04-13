#!/bin/bash
# tests/test-base.sh — Verify base image tools and configuration
set -euo pipefail

IMAGE="sandbox-base:latest"
PASS=0
FAIL=0

check() {
    local desc="$1"
    shift
    if docker run --rm "$IMAGE" "$@" &>/dev/null; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== Base Image Tests ==="

check "node is installed"     node --version
check "npm is installed"      npm --version
check "claude is installed"   claude --version
check "git is installed"      git --version
check "zsh is installed"      zsh --version
check "jq is installed"       jq --version
check "fzf is installed"      fzf --version
check "gh is installed"       gh --version
check "curl is installed"     curl --version
check "delta is installed"    delta --version
check "nano is installed"     nano --version
check "vim is installed"      vim --version

# Check user is node
check "runs as node user" bash -c '[ "$(whoami)" = "node" ]'
# Check workspace exists
check "/workspace exists" bash -c '[ -d /workspace ]'
# Check sudo works
check "sudo not available (security)" bash -c '! command -v sudo'

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
