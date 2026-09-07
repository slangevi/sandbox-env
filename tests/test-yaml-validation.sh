#!/bin/bash
# tests/test-yaml-validation.sh — Test YAML parsing and validation
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="$SCRIPT_DIR/cli/sandbox"
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

echo "=== YAML Validation Tests ==="

TEST_TMPDIR=$(mktemp -d)
trap "rm -rf $TEST_TMPDIR" EXIT

# Test: invalid YAML (mixed sequence/mapping in same block)
cat > "$TEST_TMPDIR/sandbox.yaml" <<'EOF'
name: bad-yaml
features:
  - python
  key: value
  - ollama
EOF
check_output "invalid structure caught" "Invalid YAML" bash -c "cd $TEST_TMPDIR && $SANDBOX build"

# Test: completely broken YAML
cat > "$TEST_TMPDIR/sandbox.yaml" <<'EOF'
name: [this is: "broken
features: python
EOF
check_output "broken YAML caught" "Invalid YAML" bash -c "cd $TEST_TMPDIR && $SANDBOX build"

# Test: empty file
echo "" > "$TEST_TMPDIR/sandbox.yaml"
check_fails "empty YAML fails" bash -c "cd $TEST_TMPDIR && $SANDBOX build"

# Test: valid YAML with no features (should work)
cat > "$TEST_TMPDIR/sandbox.yaml" <<'EOF'
name: minimal-test
firewall: open
EOF
check "minimal YAML builds" bash -c "cd $TEST_TMPDIR && $SANDBOX build"
docker rmi sandbox-minimal-test:latest 2>/dev/null || true

# Test: allowed_domains accepts IPv4 literals and CIDRs alongside domains.
# The check lives in _build_docker_args, which only `run` exercises, so
# this needs a project image (features-free, so it builds in seconds).
cat > "$TEST_TMPDIR/sandbox.yaml" <<'EOF'
name: cidr-test
firewall: strict
allowed_domains:
  - 10.0.4.23
  - 10.0.4.0/24
  - example.org
EOF
check "allowed_domains with IP literal and CIDR builds" bash -c "cd $TEST_TMPDIR && $SANDBOX build"
cidr_out=$(cd "$TEST_TMPDIR" && "$SANDBOX" run -- true 2>&1) || true
if echo "$cidr_out" | grep -q "Invalid domain"; then
    echo "  FAIL: CIDR in allowed_domains rejected: $(echo "$cidr_out" | grep 'Invalid domain' | head -1)"
    FAIL=$((FAIL + 1))
else
    echo "  PASS: CIDR in allowed_domains accepted"
    PASS=$((PASS + 1))
fi
docker rmi sandbox-cidr-test:latest 2>/dev/null || true

# Test: a malformed CIDR prefix is still rejected
cat > "$TEST_TMPDIR/sandbox.yaml" <<'EOF'
name: badcidr-test
firewall: strict
allowed_domains:
  - 10.0.4.0/33
EOF
check "bad CIDR config builds (validation is at run time)" bash -c "cd $TEST_TMPDIR && $SANDBOX build"
check_output "malformed CIDR rejected" "Invalid domain" bash -c "cd $TEST_TMPDIR && $SANDBOX run -- true"
docker rmi sandbox-badcidr-test:latest 2>/dev/null || true

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
