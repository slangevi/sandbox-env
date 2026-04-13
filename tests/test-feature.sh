#!/bin/bash
# tests/test-feature.sh — Test a single feature script in isolation
# Usage: tests/test-feature.sh <feature-name> <check-command> [<check-command>...]
# Example: tests/test-feature.sh python "python --version" "pip --version"
set -euo pipefail

FEATURE="$1"
shift
CHECKS=("$@")

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "=== Testing feature: $FEATURE ==="

# Build test image
TAG="sandbox-feature-test-${FEATURE}"
docker build -t "$TAG" -f - "$SCRIPT_DIR" <<DOCKER
FROM sandbox-base:latest
USER root
COPY features/${FEATURE}.sh /tmp/${FEATURE}.sh
RUN chmod +x /tmp/${FEATURE}.sh && /tmp/${FEATURE}.sh
USER node
DOCKER

PASS=0
FAIL=0
for cmd in "${CHECKS[@]}"; do
    if docker run --rm "$TAG" bash -lc "$cmd" &>/dev/null; then
        echo "  PASS: $cmd"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $cmd"
        FAIL=$((FAIL + 1))
    fi
done

# Clean up
docker rmi "$TAG" &>/dev/null

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
