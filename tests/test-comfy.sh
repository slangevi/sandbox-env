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
# Anchored on the "container:" line, not on the bare value. comfy-status also
# prints the config-file PATH (".../sandbox/comfyui.env") and, when the
# container is not running, a warning naming it — so an unanchored grep for
# "from-file" or "comfyui" is satisfied by output that has nothing to do with
# which container was actually resolved. With COMFY_DEFAULT_CONTAINER set to
# a wrong value these three used to keep passing.
check_output "container read from config file" "container:    from-file" \
    env XDG_CONFIG_HOME="$CFG_HOME" COMFYUI_CONTAINER="" "$SANDBOX" comfy-status
check_output "env var beats the config file" "container:    from-env" \
    env XDG_CONFIG_HOME="$CFG_HOME" COMFYUI_CONTAINER="from-env" "$SANDBOX" comfy-status
check_output "default container when nothing is set" "container:    comfyui" \
    env XDG_CONFIG_HOME="$TMP/empty" COMFYUI_CONTAINER="" "$SANDBOX" comfy-status

echo "-- argument wiring --"
# A project whose feature list includes comfyui, pointed at a container that
# does not exist, proves the warn-and-continue path. The shimmed project
# below, pointed at a fake but well-formed container, proves the wiring.
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

# A stand-in for `docker`, so _comfy_discover can succeed without a GPU, a
# live ComfyUI, or even a real container. Every answer is overridable through
# the environment so one shim serves both the positive wiring assertions
# below and the malformed-address refusal further down.
SHIM="$TMP/shim"
mkdir -p "$SHIM"
cat > "$SHIM/docker" <<'SHIMEOF'
#!/bin/bash
net="${SHIM_NETWORK:-comfy-net}"
ip="${SHIM_IP:-172.28.0.9}"
workdir="${SHIM_WORKDIR:-<no value>}"
ports="${SHIM_PORTS:-}"
[ -n "$ports" ] || ports='{}'
health="${SHIM_HEALTH:-none}"
case "$1" in
    image)
        echo "fake-image-id"
        exit 0
        ;;
    inspect)
        fmt="$3"
        case "$fmt" in
            *State.Running*)             echo "true" ;;
            *NetworkSettings.Networks*)
                printf '{"%s":{"IPAddress":"%s"}}\n' "$net" "$ip" ;;
            *Config.Labels*)             echo "$workdir" ;;
            *NetworkSettings.Ports*)     echo "$ports" ;;
            *State.Health*)              echo "$health" ;;
            *) echo "" ;;
        esac
        exit 0
        ;;
esac
exit 1
SHIMEOF
chmod +x "$SHIM/docker"

# Wired: a running container on one network, with a dotted-quad address, a
# compose working_dir whose workflows/ subdirectory exists, and a published
# port. Everything _comfy_discover needs to succeed.
run_wired() {
    (cd "$PROJ" && XDG_CONFIG_HOME="$TMP/empty" SANDBOX_DRY_RUN=1 \
        COMFYUI_CONTAINER="shimmed" PATH="$SHIM:$PATH" \
        SHIM_NETWORK="comfy-net" SHIM_IP="172.28.0.9" \
        SHIM_WORKDIR="$TMP" SHIM_PORTS='{"8188/tcp":[{"HostPort":"1"}]}' \
        "$SANDBOX" "$@")
}

# The four lines in _build_docker_args that ARE the feature. Without these
# positive assertions the whole suite stayed green with all four deleted:
# every other check here exercises a refusal, a warning, or a path where
# ComfyUI is deliberately absent.
check_output "the container joins ComfyUI's network" \
    "--network comfy-net" run_wired comfy status
check_output "COMFYUI_URL reaches the container" \
    "COMFYUI_URL=http://shimmed:8188" run_wired comfy status
check_output "the workflow directory is mounted read-only" \
    ":/opt/comfy-workflows:ro" run_wired comfy status
check_output "COMFY_WORKFLOWS points at that mount" \
    "COMFY_WORKFLOWS=/opt/comfy-workflows" run_wired comfy status
check_output "the discovered address reaches the firewall" \
    "SANDBOX_COMFYUI_IP=172.28.0.9" run_wired comfy status

echo "-- firewall input validation (R13) --"
# _build_docker_args passes COMFY_IP straight into init-firewall.sh's
# allowed-domains ipset as an IP literal (SANDBOX_COMFYUI_IP). Real `docker
# inspect` output is always a well-formed dotted-quad, so a malformed value
# can't be produced through a live container — the shim above makes
# `_comfy_discover` see a network whose IPAddress is "0.0.0.0/0" (a CIDR
# that would defeat strict mode's default-DROP policy if it ever reached the
# ipset), and this proves _build_docker_args's guard refuses to forward it.
run_shimmed() {
    (cd "$PROJ" && XDG_CONFIG_HOME="$TMP/empty" SANDBOX_DRY_RUN=1 \
        COMFYUI_CONTAINER="shimmed" PATH="$SHIM:$PATH" \
        SHIM_NETWORK="bridge" SHIM_IP="0.0.0.0/0" \
        "$SANDBOX" "$@")
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
