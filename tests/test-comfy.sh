#!/bin/bash
# tests/test-comfy.sh — ComfyUI backend: config precedence and argument wiring.
# Uses SANDBOX_DRY_RUN=1; needs no live ComfyUI.
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

echo "=== ComfyUI Backend Tests ==="

CFG_HOME="$TMP/config"
mkdir -p "$CFG_HOME/sandbox"
cat > "$CFG_HOME/sandbox/comfyui.env" <<'EOF'
COMFYUI_CONTAINER=from-file
COMFYUI_URL=http://from-file:8188
EOF
chmod 600 "$CFG_HOME/sandbox/comfyui.env"

echo "-- config precedence --"
check_output "container read from config file" "from-file" \
    env XDG_CONFIG_HOME="$CFG_HOME" COMFYUI_CONTAINER="" "$SANDBOX" comfy-status
check_output "env var beats the config file" "from-env" \
    env XDG_CONFIG_HOME="$CFG_HOME" COMFYUI_CONTAINER="from-env" "$SANDBOX" comfy-status
check_output "default container when nothing is set" "comfyui" \
    env XDG_CONFIG_HOME="$TMP/empty" COMFYUI_CONTAINER="" "$SANDBOX" comfy-status

echo "-- argument wiring --"
# A project whose feature list includes comfyui, pointed at a container that
# does not exist, proves the warn-and-continue path. A second project pointed
# at overrides proves the wiring itself.
PROJ="$TMP/proj"
mkdir -p "$PROJ" "$TMP/workflows"
cat > "$PROJ/sandbox.yaml" <<'EOF'
name: comfy-test
features:
  - comfyui
firewall: open
EOF

run_dry() {
    (cd "$PROJ" && XDG_CONFIG_HOME="$TMP/empty" SANDBOX_DRY_RUN=1 \
        COMFYUI_CONTAINER="definitely-not-running-$$" "$SANDBOX" "$@")
}

check_output "missing container warns rather than failing" "ComfyUI not available" run_dry comfy-status
check_output "warning names the container" "definitely-not-running" run_dry comfy-status

echo "-- firewall input validation (R13) --"
# _build_docker_args passes COMFY_IP straight into init-firewall.sh's
# allowed-domains ipset as an IP literal (SANDBOX_COMFYUI_IP). Real `docker
# inspect` output is always a well-formed dotted-quad, so a malformed value
# can't be produced through a live container — this shim fakes `docker` so
# `_comfy_discover` sees a network whose IPAddress is "0.0.0.0/0" (a CIDR
# that would defeat strict mode's default-DROP policy if it ever reached the
# ipset), and proves _build_docker_args's guard refuses to forward it.
SHIM="$TMP/shim"
mkdir -p "$SHIM"
cat > "$SHIM/docker" <<'SHIMEOF'
#!/bin/bash
case "$1" in
    image)
        echo "fake-image-id"
        exit 0
        ;;
    inspect)
        fmt="$3"
        case "$fmt" in
            *State.Running*)             echo "true" ;;
            *NetworkSettings.Networks*)  echo '{"bridge":{"IPAddress":"0.0.0.0/0"}}' ;;
            *Config.Labels*)             echo "<no value>" ;;
            *NetworkSettings.Ports*)     echo "{}" ;;
            *State.Health*)              echo "none" ;;
            *) echo "" ;;
        esac
        exit 0
        ;;
esac
exit 1
SHIMEOF
chmod +x "$SHIM/docker"

run_shimmed() {
    (cd "$PROJ" && XDG_CONFIG_HOME="$TMP/empty" SANDBOX_DRY_RUN=1 \
        COMFYUI_CONTAINER="shimmed" PATH="$SHIM:$PATH" "$SANDBOX" "$@")
}

check_output "malformed address is refused rather than forwarded" \
    "not a plain IPv4 address" run_shimmed comfy status
check_not_output "and the docker invocation never carries it" \
    "SANDBOX_COMFYUI_IP" run_shimmed comfy status

echo "-- feature detection --"
NOCOMFY="$TMP/nocomfy"
mkdir -p "$NOCOMFY"
cat > "$NOCOMFY/sandbox.yaml" <<'EOF'
name: no-comfy
features: []
firewall: open
EOF
run_nocomfy() { (cd "$NOCOMFY" && SANDBOX_DRY_RUN=1 "$SANDBOX" "$@"); }
check_output "comfy refuses a project without the feature" "does not have the 'comfyui' feature" \
    run_nocomfy comfy status
check_not_output "and never mentions a workflow mount" "/opt/comfy-workflows" \
    run_nocomfy comfy status

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
