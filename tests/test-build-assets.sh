#!/bin/bash
# tests/test-build-assets.sh — cmd_build stages feature asset directories
# Uses SANDBOX_DRY_RUN=1 and a synthetic SANDBOX_ROOT; never calls Docker.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="$SCRIPT_DIR/cli/sandbox"
PASS=0
FAIL=0

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

check_output() {
    local desc="$1" expected="$2"; shift 2
    local output
    output=$("$@" 2>&1) || true
    if echo "$output" | grep -q -- "$expected"; then
        echo "  PASS: $desc"; PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (expected '$expected')"
        echo "        got: $output"
        FAIL=$((FAIL + 1))
    fi
}

check_not_output() {
    local desc="$1" unexpected="$2"; shift 2
    local output
    output=$("$@" 2>&1) || true
    if echo "$output" | grep -q -- "$unexpected"; then
        echo "  FAIL: $desc (found forbidden '$unexpected')"
        FAIL=$((FAIL + 1))
    else
        echo "  PASS: $desc"; PASS=$((PASS + 1))
    fi
}

echo "=== Feature Asset Staging Tests ==="

# A synthetic repo root: two features, one with assets and one without.
ROOT="$TMP/root"
mkdir -p "$ROOT/features/withassets.d" "$ROOT/templates"
cp "$SCRIPT_DIR/templates/Dockerfile.project.tmpl" "$ROOT/templates/"
echo 'echo hi' > "$ROOT/features/withassets.sh"
echo 'echo plain' > "$ROOT/features/plain.sh"
echo 'echo asset' > "$ROOT/features/withassets.d/tool"

PROJ="$TMP/proj"
mkdir -p "$PROJ"
cat > "$PROJ/sandbox.yaml" <<'EOF'
name: asset-test
features:
  - withassets
  - plain
EOF

run_build() { (cd "$PROJ" && SANDBOX_ROOT="$ROOT" SANDBOX_DRY_RUN=1 "$SANDBOX" build); }

check_output "asset dir is COPYed"        "COPY withassets.d/ /tmp/withassets.d/" run_build
check_output "asset file is staged"       "withassets.d/tool"                     run_build
check_output "feature script still COPYed" "COPY withassets.sh /tmp/withassets.sh" run_build
check_output "assets removed after run"   "rm -rf /tmp/withassets.sh /tmp/withassets.d" run_build
check_not_output "no asset dir invented for plain feature" "COPY plain.d/" run_build

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
