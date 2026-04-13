#!/bin/bash
# tests/test-integration.sh — End-to-end test: build base, build project, run container
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="$SCRIPT_DIR/cli/sandbox"
FIXTURES="$SCRIPT_DIR/tests/fixtures"
PASS=0
FAIL=0

check() {
    local desc="$1"
    shift
    if "$@" 2>&1; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== Integration Test ==="

# Step 1: Build base (should already exist, but verify)
echo "Building base image..."
"$SANDBOX" build-base

# Step 2: Build project with python + llm features
echo "Building project image..."
cd "$FIXTURES"

# The sandbox CLI looks for sandbox.yaml by default, but we want sandbox-full.yaml
# Copy it temporarily
cp sandbox-full.yaml sandbox-integration.yaml

# We need to use the sandbox-full.yaml — rename temporarily
ORIG_YAML=""
if [ -f sandbox.yaml ]; then
    ORIG_YAML=$(mktemp)
    cp sandbox.yaml "$ORIG_YAML"
fi
cp sandbox-full.yaml sandbox.yaml

check "build full project" "$SANDBOX" build

# Restore original sandbox.yaml
if [ -n "$ORIG_YAML" ]; then
    cp "$ORIG_YAML" sandbox.yaml
    rm "$ORIG_YAML"
else
    rm sandbox.yaml
fi
rm -f sandbox-integration.yaml

# Step 3: Verify tools are available in the container
IMAGE="sandbox-integration-test:latest"

check "python available"  docker run --rm "$IMAGE" python --version
check "pip available"     docker run --rm "$IMAGE" pip --version
check "llm available"     docker run --rm "$IMAGE" bash -lc "llm --version"
check "tree available"    docker run --rm "$IMAGE" tree --version
check "rg available"      docker run --rm "$IMAGE" rg --version
check "claude available"  docker run --rm "$IMAGE" claude --version
check "env var set"       docker run --rm -e TEST_VAR=hello "$IMAGE" bash -c '[ "$TEST_VAR" = "hello" ]'

# Step 4: Clean up
docker rmi "$IMAGE" 2>/dev/null || true

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
