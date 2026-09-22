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

count_output_tokens() {
    local pattern="$1"; shift
    "$@" 2>&1 | tr ' ' '\n' | grep -c -- "$pattern"
}

# Exactly one, not "at least one": cmd_comfy adds a fallback /workspace mount
# for projects whose mounts: suppressed the default one, and a second copy
# here would be a duplicate mount point docker refuses outright.
check_output "the default-mount project gets exactly one /workspace mount" \
    "^1\$" count_output_tokens ':/workspace$' run_wired comfy status

echo "-- unjoinable network modes --"
# `network_mode: host` is a common GPU-container setup, and `docker inspect`
# reports it as ONE network named "host" — indistinguishable to a plain count
# from a real user-defined network. Joining it would hand the sandbox the
# HOST's network stack together with the NET_ADMIN/NET_RAW this CLI already
# grants, and init-firewall.sh would then run `iptables -F` and
# `iptables -P OUTPUT DROP` against the host itself.
run_hostnet() {
    (cd "$PROJ" && XDG_CONFIG_HOME="$TMP/empty" SANDBOX_DRY_RUN=1 \
        COMFYUI_CONTAINER="shimmed" PATH="$SHIM:$PATH" \
        SHIM_NETWORK="host" SHIM_IP="" "$SANDBOX" "$@")
}
check_output "network mode 'host' is refused by name" \
    "network mode 'host'" run_hostnet comfy status
check_output "...and the warning names the host.docker.internal remedy" \
    "COMFYUI_URL=http://host.docker.internal:8188" run_hostnet comfy status
check_not_output "...and no --network ever reaches docker run" \
    "\-\-network" run_hostnet comfy status
check_output "...while the sandbox still launches" "sandbox-comfy-test:latest" run_hostnet comfy status

run_nonenet() {
    (cd "$PROJ" && XDG_CONFIG_HOME="$TMP/empty" SANDBOX_DRY_RUN=1 \
        COMFYUI_CONTAINER="shimmed" PATH="$SHIM:$PATH" \
        SHIM_NETWORK="none" SHIM_IP="" "$SANDBOX" "$@")
}
check_output "network mode 'none' is refused too" "network mode 'none'" run_nonenet comfy status
check_not_output "...with no --network either" "\-\-network" run_nonenet comfy status

run_containernet() {
    (cd "$PROJ" && XDG_CONFIG_HOME="$TMP/empty" SANDBOX_DRY_RUN=1 \
        COMFYUI_CONTAINER="shimmed" PATH="$SHIM:$PATH" \
        SHIM_NETWORK="container:abc123" SHIM_IP="" "$SANDBOX" "$@")
}
check_output "so is a container: network mode" "network mode 'container:abc123'" \
    run_containernet comfy status
check_not_output "...with no --network either" "\-\-network" run_containernet comfy status

# The remedy the refusal names has to actually work, or it is just an excuse.
# Mirrors _apply_spark_backend: the URL plus the --add-host that makes the
# name resolve, and deliberately still no --network.
CFG_HG="$TMP/config-hostgw"
mkdir -p "$CFG_HG/sandbox"
printf 'COMFYUI_URL=http://host.docker.internal:8188\n' > "$CFG_HG/sandbox/comfyui.env"
chmod 600 "$CFG_HG/sandbox/comfyui.env"
run_hostnet_override() {
    (cd "$PROJ" && XDG_CONFIG_HOME="$CFG_HG" SANDBOX_DRY_RUN=1 \
        COMFYUI_CONTAINER="shimmed" COMFYUI_URL="" PATH="$SHIM:$PATH" \
        SHIM_NETWORK="host" SHIM_IP="" "$SANDBOX" "$@")
}
check_output "the host-gateway override maps host.docker.internal" \
    "\-\-add-host host.docker.internal:host-gateway" run_hostnet_override comfy status
# Anchored on the `-e ` that makes it an ENV VAR in the argv: the refusal's
# own warning names the identical URL as the remedy to set, so an unanchored
# grep for it passed with the whole host-gateway fallback deleted.
check_output "...and still passes COMFYUI_URL into the container" \
    "\-e COMFYUI_URL=http://host.docker.internal:8188" run_hostnet_override comfy status
check_not_output "...and still attaches no network" "\-\-network" run_hostnet_override comfy status

echo "-- network override validation --"
# An override naming a network the container is not on used to yield an empty
# IPAddress and a silent skip, leaving every later `comfy` call to fail with a
# bare "unreachable" that named neither the override nor the mistake.
run_wrongnet() {
    (cd "$PROJ" && XDG_CONFIG_HOME="$TMP/empty" SANDBOX_DRY_RUN=1 \
        COMFYUI_CONTAINER="shimmed" COMFYUI_NETWORK="not-a-network" PATH="$SHIM:$PATH" \
        SHIM_NETWORK="comfy-net" SHIM_IP="172.28.0.9" "$SANDBOX" "$@")
}
check_output "an override naming a network the container is not on is refused" \
    "is not one of the networks" run_wrongnet comfy status
check_output "...and the message names the networks it IS on" \
    "comfy-net" run_wrongnet comfy status
check_not_output "...and nothing is attached" "\-\-network" run_wrongnet comfy status

echo "-- default bridge has no DNS --"
# Docker's embedded DNS resolves container names on user-defined networks
# only. A ComfyUI started with a plain `docker run` lands on `bridge`, where
# http://<container-name>:8188 never resolves from inside the sandbox.
run_bridge() {
    (cd "$PROJ" && XDG_CONFIG_HOME="$TMP/empty" SANDBOX_DRY_RUN=1 \
        COMFYUI_CONTAINER="shimmed" PATH="$SHIM:$PATH" \
        SHIM_NETWORK="bridge" SHIM_IP="172.17.0.4" "$SANDBOX" "$@")
}
check_output "on bridge the URL is built from the container's IP" \
    "COMFYUI_URL=http://172.17.0.4:8188" run_bridge comfy status
check_not_output "...never from the container name bridge cannot resolve" \
    "COMFYUI_URL=http://shimmed" run_bridge comfy status

echo "-- refused workflow directory --"
# validate_mount refuses by calling `exit 1` with a message blaming
# $CONFIG_FILE, so a compose project whose workflows/ resolves somewhere
# sensitive used to kill every launch for the project. The symlink is how a
# real compose checkout reaches a system directory; validate_mount resolves it
# before matching, so this lands on the /etc prefix rule.
mkdir -p "$TMP/compose-refused"
ln -sfn /etc "$TMP/compose-refused/workflows"
run_refusedwf() {
    (cd "$PROJ" && XDG_CONFIG_HOME="$TMP/empty" SANDBOX_DRY_RUN=1 \
        COMFYUI_CONTAINER="shimmed" PATH="$SHIM:$PATH" \
        SHIM_NETWORK="comfy-net" SHIM_IP="172.28.0.9" \
        SHIM_WORKDIR="$TMP/compose-refused" "$SANDBOX" "$@")
}
check_output "a refused workflow directory warns instead of exiting" \
    "refused by the mount validator" run_refusedwf comfy status
check_output "...naming COMFYUI_WORKFLOWS as the remedy" \
    "COMFYUI_WORKFLOWS" run_refusedwf comfy status
check_not_output "...and emits no workflow mount" \
    "/opt/comfy-workflows" run_refusedwf comfy status
check_output "...and the launch continues anyway" \
    "\-\-network comfy-net" run_refusedwf comfy status

echo "-- outputs survive a project with mounts: --"
# _build_docker_args adds the default $(pwd):/workspace mount only when the
# project defines NO mounts:. `comfy` writes ./comfy-out inside the container
# and prints host-looking paths for it, so without a /workspace the whole run
# used to land in the image and --rm deleted it, exit 0, no warning.
MPROJ="$TMP/mproj"
mkdir -p "$MPROJ/data"
cat > "$MPROJ/sandbox.yaml" <<'EOF'
name: comfy-mounts-test
features:
  - comfyui
firewall: open
mounts:
  - host: ./data
    container: /data
EOF
run_mounts() {
    (cd "$MPROJ" && XDG_CONFIG_HOME="$TMP/empty" SANDBOX_DRY_RUN=1 \
        COMFYUI_CONTAINER="shimmed" PATH="$SHIM:$PATH" \
        SHIM_NETWORK="comfy-net" SHIM_IP="172.28.0.9" "$SANDBOX" "$@")
}
check_output "a project with mounts: still gets its cwd at /workspace" \
    "$MPROJ:/workspace" run_mounts comfy status
check_output "...and its own mounts are untouched" "$MPROJ/data:/data" run_mounts comfy status
check_output "...with sandbox.yaml still overlaid read-only" \
    "$MPROJ/sandbox.yaml:/workspace/sandbox.yaml:ro" run_mounts comfy status

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
