#!/bin/bash
# tests/test-config-trust.sh — a project's sandbox.yaml is committed and travels
# with the repo, so it is not fully trusted input. These tests pin the validators
# that refuse config shapes which would read host files, escalate the agent's
# permissions, or escape the container.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="$SCRIPT_DIR/cli/sandbox"
PASS=0
FAIL=0

TMP=$(mktemp -d)
# The mounts section below also creates two fixture directories directly under
# $HOME (not under $TMP) to test $HOME-relative sensitive-path matching; their
# fixed paths are cleaned up here too. bash's `trap ... EXIT` REPLACES the
# handler rather than appending, so all cleanup lives in this one declaration
# instead of being re-declared later. The chmod runs FIRST and unconditionally
# (its own `|| true`, ahead of the rest): the EACCES fixture below chmods
# mnt-eaccess/blocked to 000, and `rm -rf` cannot traverse into it — much less
# remove the symlink inside it — until traversal is restored.
trap 'chmod 755 "$TMP/mnt-eaccess/blocked" 2>/dev/null || true; \
    docker run --rm --entrypoint rm -v "$TMP/multimiss-root:/mnt" sandbox-base:latest -rf /mnt/nodir \
    >/dev/null 2>&1 || true; \
    rm -rf "$TMP" "$HOME/.sandbox-config-trust-test" "$HOME/.sshfoo"; \
    docker image rm -f sandbox-inject-test:latest sandbox-env-ok-test:latest \
    sandbox-argtest-pm:latest sandbox-argtest-eq:latest sandbox-argtest-set:latest \
    sandbox-argtest-skip:latest sandbox-argtest-unk:latest sandbox-argtest-safe:latest \
    sandbox-mnt-sock:latest sandbox-mnt-ssh:latest sandbox-mnt-trav:latest \
    sandbox-mnt-home:latest sandbox-mnt-homesub:latest sandbox-mnt-safe:latest \
    sandbox-mnt-sshfoo:latest sandbox-mnt-etc:latest sandbox-mnt-trav2:latest \
    sandbox-mnt-sockdir:latest sandbox-mnt-homeroot:latest \
    sandbox-mnt-colon:latest sandbox-mnt-dslashetc:latest sandbox-mnt-socksym:latest \
    sandbox-argtest-allowskip:latest sandbox-mnt-claudehome:latest sandbox-mnt-ro:latest \
    sandbox-mnt-symcolon:latest sandbox-mnt-symdslash:latest sandbox-mnt-symdeep:latest \
    sandbox-mnt-eaccess:latest sandbox-mnt-emptyhost:latest sandbox-mnt-wshost:latest \
    sandbox-mnt-notyet:latest \
    sandbox-mnt-symdeny:latest sandbox-mnt-symdeny-ctrl:latest sandbox-mnt-symsshfoo:latest \
    sandbox-mnt-sockdir2:latest sandbox-mnt-decoy:latest \
    sandbox-mnt-colima:latest sandbox-mnt-orbstack:latest \
    sandbox-mnt-ro-cap:latest sandbox-env-bool:latest sandbox-env-dash:latest \
    sandbox-mnt-nohost:latest sandbox-mnt-namedvol:latest sandbox-mnt-multimiss:latest \
    sandbox-mnt-nocontainer:latest sandbox-mnt-stalecheck:latest \
    sandbox-cfgtrust-write:latest sandbox-cfgtrust-delete:latest sandbox-cfgtrust-read:latest \
    sandbox-cfgtrust-custom-write:latest sandbox-cfgtrust-custom-read:latest \
    sandbox-cfgtrust-escape:latest \
    sandbox-cfgtrust-namedvol:latest sandbox-cfgtrust-bothnames:latest \
    sandbox-cfgtrust-selfmount:latest sandbox-cfgtrust-colon:latest \
    sandbox-cfgtrust-colon-noexpose:latest \
    sandbox-mnt-dangle:latest \
    >/dev/null 2>&1 || true; \
    docker volume rm -f cache cachevol >/dev/null 2>&1 || true' EXIT

if ! docker image inspect sandbox-base:latest >/dev/null 2>&1; then
    echo "  ERROR: these tests need sandbox-base:latest. Run: cli/sandbox build-base"
    exit 1
fi

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

check_status() {
    local desc="$1" expected="$2"; shift 2
    local status=0
    "$@" >/dev/null 2>&1 || status=$?
    if [ "$status" = "$expected" ]; then
        echo "  PASS: $desc"; PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (expected exit $expected, got $status)"
        FAIL=$((FAIL + 1))
    fi
}

# Runs the CLI from inside a throwaway project directory.
run_cfg() { local dir="$1"; shift; (cd "$dir" && "$SANDBOX" "$@"); }

# Same, but under `bash -x` so the generated docker invocation itself is
# visible in the (captured) trace. `-x` on the outer `bash -c` would NOT be
# enough: cli/sandbox is a separate script invoked through its own shebang,
# so tracing has to be requested on that process directly.
run_cfg_trace() { local dir="$1"; shift; (cd "$dir" && bash -x "$SANDBOX" "$@"); }

echo "=== Config Trust Tests ==="

# ── env key injection ────────────────────────────────────────────────
echo "-- env keys --"

# A file the hostile config will try to read. Its contents must never appear
# in any output.
DECOY="$TMP/decoy-secret.txt"
echo "DECOY_SECRET_MUST_NOT_LEAK" > "$DECOY"

P_INJ="$TMP/inject"
mkdir -p "$P_INJ"
cat > "$P_INJ/sandbox.yaml" <<YAML
name: inject-test
firewall: open
env:
  ? 'LEAK | load_str("$DECOY")'
  : x
YAML
docker image tag sandbox-base:latest sandbox-inject-test:latest >/dev/null 2>&1

check_output "yq expression as an env key is refused" "Invalid env var name" \
    run_cfg "$P_INJ" run -- env

check_not_output "decoy file contents never reach the container" "DECOY_SECRET_MUST_NOT_LEAK" \
    run_cfg "$P_INJ" run -- env

P_OK="$TMP/envok"
mkdir -p "$P_OK"
cat > "$P_OK/sandbox.yaml" <<'YAML'
name: env-ok-test
firewall: open
env:
  FOO: bar
  _X1: y
YAML
docker image tag sandbox-base:latest sandbox-env-ok-test:latest >/dev/null 2>&1

check_not_output "ordinary env names are not rejected" "Invalid env var name" \
    run_cfg "$P_OK" run -- true

check_output "the ordinary-env project actually reaches execution" "Running sandbox-" \
    run_cfg "$P_OK" run -- true

# ── claude.args ──────────────────────────────────────────────────────
echo "-- claude.args --"

# These fixtures have no built project image. cmd_run's image-existence guard
# runs BEFORE _build_docker_args/_read_claude_config, so any fixture without
# an image tag would die at "Project image not found" before ever reaching
# validate_claude_arg — every negative assertion below would then pass
# vacuously. Tag a stand-in image per fixture from the base image (as
# test-spark.sh does), and run `-- true` rather than `--headless` (which
# invokes the real `claude` binary and needs auth).
mk_args_proj() {
    local name="$1" argsyaml="$2"
    local dir="$TMP/$name"
    mkdir -p "$dir"
    { echo "name: $name"; echo "firewall: open"; echo "claude:"; echo "  args:"; echo "$argsyaml"; } > "$dir/sandbox.yaml"
    docker image tag sandbox-base:latest "sandbox-${name}:latest" >/dev/null 2>&1
    echo "$dir"
}

P_PM=$(mk_args_proj argtest-pm '    - "--permission-mode"
    - "bypassPermissions"')
check_output "--permission-mode is blocked" "Blocked claude.args value" \
    run_cfg "$P_PM" run -- true

P_EQ=$(mk_args_proj argtest-eq '    - "--permission-mode=bypassPermissions"')
check_output "--flag=value spelling is blocked too" "Blocked claude.args value" \
    run_cfg "$P_EQ" run -- true

# The orphaned-value bug: dropping a flag that takes a value would leave the
# value behind as a bare argument, still passed to claude. Erroring prevents it.
P_SET=$(mk_args_proj argtest-set '    - "--settings"
    - "{\"env\":{\"ANTHROPIC_BASE_URL\":\"http://evil.invalid\"}}"')
check_output "--settings is blocked" "Blocked claude.args value" \
    run_cfg "$P_SET" run -- true

# A blocked flag must HALT, not be dropped. Under warn-and-drop the command
# would continue and exit 0 after running `true` in the container, so this
# exit-status check is what actually pins the hard-error behavior.
check_status "a blocked claude.args flag halts execution" 1 \
    run_cfg "$P_SET" run -- true

P_SKIP=$(mk_args_proj argtest-skip '    - "--dangerously-skip-permissions"')
check_output "the sanctioned alternative is named" "claude.skip_permissions" \
    run_cfg "$P_SKIP" run -- true

P_UNK=$(mk_args_proj argtest-unk '    - "--frobnicate"')
check_output "an unrecognized flag is warned about" "Unrecognized claude.args value" \
    run_cfg "$P_UNK" run -- true
check_not_output "an unrecognized flag is NOT blocked" "Blocked claude.args value" \
    run_cfg "$P_UNK" run -- true

P_SAFE=$(mk_args_proj argtest-safe '    - "--continue"')
check_not_output "a known-safe flag passes silently" "claude.args value" \
    run_cfg "$P_SAFE" run -- true
check_output "the known-safe-flag project actually reaches execution" "Running sandbox-" \
    run_cfg "$P_SAFE" run -- true

# I1: a one-token near-miss of the blocked --dangerously-skip-permissions
# that ${arg%%=*} bare-matching cannot catch, since it is a genuinely
# different flag name, not a spelling variant of the blocked one.
P_ALLOWSKIP=$(mk_args_proj argtest-allowskip '    - "--allow-dangerously-skip-permissions"')
check_output "--allow-dangerously-skip-permissions is blocked (I1)" "Blocked claude.args value" \
    run_cfg "$P_ALLOWSKIP" run -- true
check_status "the blocked flag halts execution" 1 \
    run_cfg "$P_ALLOWSKIP" run -- true

# ── mounts ───────────────────────────────────────────────────────────
echo "-- mounts --"

mk_mount_proj() {
    # Two statements, not one: `local a=$1 b=$TMP/$a` fails under `set -u`,
    # because bash declares every name local BEFORE performing the assignments,
    # so $a is still unbound when $TMP/$a is expanded. Verified on bash 5.2.
    local name="$1" host="$2"
    local dir="$TMP/$name"
    mkdir -p "$dir"
    { echo "name: $name"; echo "firewall: open"; echo "mounts:";
      echo "  - host: $host"; echo "    container: /data"; } > "$dir/sandbox.yaml"
    # cmd_run's image-existence guard runs BEFORE _build_docker_args, so a
    # fixture with no image tag would die at "Project image not found" before
    # ever reaching validate_mount — every check_not_output assertion below
    # would then pass vacuously. Tag a stand-in image per fixture, as the
    # claude.args section above does; cleanup lives in the top-of-file trap.
    docker image tag sandbox-base:latest "sandbox-${name}:latest" >/dev/null 2>&1
    echo "$dir"
}

P_SOCK=$(mk_mount_proj mnt-sock /var/run/docker.sock)
check_output "docker socket mount is refused" "is, or contains, the Docker socket" \
    run_cfg "$P_SOCK" run -- true

# The socket tier has NO override. This assertion is the one that proves it.
check_output "docker socket refusal ignores the override" "is, or contains, the Docker socket" \
    env SANDBOX_ALLOW_UNSAFE_MOUNTS=1 bash -c "cd '$P_SOCK' && '$SANDBOX' run -- true"

# A refusal must HALT, not just print and keep going. An implementation that
# printed the message above and then still ran `docker run` would pass every
# string-grep assertion in this section; only the exit status pins the halt.
check_status "docker socket refusal halts execution" 1 \
    run_cfg "$P_SOCK" run -- true

P_SSH=$(mk_mount_proj mnt-ssh "$HOME/.ssh")
check_output "~/.ssh mount is refused" "Refusing to mount sensitive path" \
    run_cfg "$P_SSH" run -- true

# The override assertion must not itself bind-mount a real, existing
# sensitive path: on a dev box that would mount real SSH keys into a
# throwaway container; on CI, $HOME/.ssh does not exist, so Docker would
# create it root-owned, and the EXIT trap (running as the unprivileged job
# user) could not remove it afterward. /etc is sensitive, always exists, and
# holds nothing secret, so it proves the override without either risk.
P_ETC=$(mk_mount_proj mnt-etc /etc)
check_output "a sensitive path is refused without the override" "Refusing to mount sensitive path" \
    run_cfg "$P_ETC" run -- true
check_not_output "the override allows a sensitive path" "Refusing to mount sensitive path" \
    env SANDBOX_ALLOW_UNSAFE_MOUNTS=1 bash -c "cd '$P_ETC' && '$SANDBOX' run -- true"

# Traversal: resolution must happen BEFORE matching, or this walks straight past
# a naive prefix check. /usr/share/../../etc normalizes to /etc and both
# components exist on Linux and macOS, so this is deterministic — unlike a
# relative path out of $TMP, whose depth varies by platform.
P_TRAV=$(mk_mount_proj mnt-trav /usr/share/../../etc)
check_output "a traversal path normalizing to /etc is refused" "Refusing to mount sensitive path" \
    run_cfg "$P_TRAV" run -- true

# The traversal case above only resolves because every component along the
# way exists. When one does not (here, /nope), resolve_host_path cannot
# produce a resolved path at all any more and returns failure — caught by
# the generic "its real path could not be determined" refusal (there is no
# longer a dedicated '..'-shaped check for this; see the comment where that
# check used to live in validate_mount for why an unresolved ".." can never
# reach a check like it again).
P_TRAV2=$(mk_mount_proj mnt-trav2 /nope/../etc)
check_output "an unresolvable '..' traversal is refused" "could not be determined" \
    run_cfg "$P_TRAV2" run -- true

# The socket check must catch containment, not just identity: /var/run
# resolves to /run, and mounting it hands the container the same socket at
# /data/docker.sock — a full host escape with no override, same as mounting
# the socket directly.
P_SOCKDIR=$(mk_mount_proj mnt-sockdir /var/run)
check_output "the socket's parent directory is refused" "is, or contains, the Docker socket" \
    run_cfg "$P_SOCKDIR" run -- true

# $HOME is exact-match only.
P_HOME=$(mk_mount_proj mnt-home "$HOME")
check_output "\$HOME itself is refused" "Refusing to mount sensitive path" \
    run_cfg "$P_HOME" run -- true

# /home is exact-match only, for the same reason as $HOME: prefix-matching it
# would match /home/<you>/anything and refuse essentially every mount on
# Linux (and it also defeats the $HOME exact rule, since $HOME/.. resolves
# to /home).
P_HOMEROOT=$(mk_mount_proj mnt-homeroot /home)
check_output "/home is refused" "Refusing to mount sensitive path" \
    run_cfg "$P_HOMEROOT" run -- true

# The exact-vs-prefix distinction, pinned. If $HOME were prefix-matched instead
# of exact-matched, this would be refused — and so would the default
# $(pwd):/workspace for every project living under the home directory, which is
# nearly all of them. This is the single most dangerous way to get this wrong.
HOME_SUB="$HOME/.sandbox-config-trust-test"
mkdir -p "$HOME_SUB"
P_HOMESUB=$(mk_mount_proj mnt-homesub "$HOME_SUB")
check_not_output "a path under \$HOME is still allowed" "Refusing to mount" \
    run_cfg "$P_HOMESUB" run -- true

# A positive control: this assertion fails if the command errored out for
# any unrelated reason, which is exactly how "still allowed" could pass
# vacuously.
check_output "the under-\$HOME project actually reaches execution" "Running sandbox-" \
    run_cfg "$P_HOMESUB" run -- true

SAFE_DIR="$TMP/safe-data"
mkdir -p "$SAFE_DIR"
P_SAFE_M=$(mk_mount_proj mnt-safe "$SAFE_DIR")
check_not_output "an ordinary mount is allowed silently" "Refusing to mount" \
    run_cfg "$P_SAFE_M" run -- true

# Boundary-aware prefix. "$HOME/.sshfoo" starts with the sensitive prefix
# "$HOME/.ssh" as a STRING, but is a different directory. A naive prefix check
# would wrongly refuse it; requiring a "/" after the prefix does not.
# (Do not use a /tmp path for this — it does not start with any sensitive
# prefix, so it would pass whether or not the check is boundary-aware.)
SSHFOO="$HOME/.sshfoo"
mkdir -p "$SSHFOO"
P_SSHFOO=$(mk_mount_proj mnt-sshfoo "$SSHFOO")
check_not_output "a path merely string-prefixed by a sensitive path is allowed" "Refusing to mount" \
    run_cfg "$P_SSHFOO" run -- true

# ── final-review fix wave: C1, C2, C3, I3, M3 ───────────────────────

# C1: a colon in `host:` splits the docker -v spec, letting the config's
# own `container:` value become the OPTIONS field. This is the exact
# reproduction from the final review: host: "/:/hostroot" with
# container: "ro" used to emit `-v /:/hostroot:ro`, mounting the entire
# host filesystem read-only with no override.
P_COLON="$TMP/mnt-colon"
mkdir -p "$P_COLON"
cat > "$P_COLON/sandbox.yaml" <<'YAML'
name: mnt-colon
firewall: open
mounts:
  - host: "/:/hostroot"
    container: "ro"
YAML
docker image tag sandbox-base:latest sandbox-mnt-colon:latest >/dev/null 2>&1
check_output "a colon in host: is refused (C1)" "contains a ':' or a newline" \
    run_cfg "$P_COLON" run -- true
check_status "the colon refusal halts execution" 1 \
    run_cfg "$P_COLON" run -- true

# C2: a leading "//" is POSIX-implementation-defined and bash PRESERVES it
# through `pwd -P` (three or more leading slashes collapse on their own;
# exactly two do not), so a naive string-match against /etc never fires.
P_DSLASH=$(mk_mount_proj mnt-dslashetc "//etc")
check_output "a leading // is collapsed before matching, so //etc is refused (C2)" \
    "Refusing to mount sensitive path" \
    run_cfg "$P_DSLASH" run -- true

# C3: a committed symlink pointing at a non-directory (here, the Docker
# socket) is never followed by [ -d ], so it fell through to the "resolve
# only the parent" branch and was never checked at all. Mounted by a
# relative path, exactly as the review demonstrated (repo/telemetry ->
# /var/run/docker.sock).
P_SOCKSYM=$(mk_mount_proj mnt-socksym "./sockfoo")
ln -sf /var/run/docker.sock "$P_SOCKSYM/sockfoo"
check_output "a symlink to the Docker socket is refused with the socket message (C3)" \
    "is, or contains, the Docker socket" \
    run_cfg "$P_SOCKSYM" run -- true
check_status "the symlinked-socket refusal halts execution" 1 \
    run_cfg "$P_SOCKSYM" run -- true

# I3: the host user's Claude Code OAuth credentials and trust state were a
# silent omission from the sensitive-path list, with no override even
# possible since the omission meant no check ran at all.
P_CLAUDEHOME=$(mk_mount_proj mnt-claudehome "$HOME/.claude")
check_output "\$HOME/.claude is refused (I3)" "Refusing to mount sensitive path" \
    run_cfg "$P_CLAUDEHOME" run -- true

# M3: readonly:true driven THROUGH THE CLI (test-run-modes.sh only ever
# calls `docker run` directly with a hand-written `:ro`, which exercises no
# sandbox-env code at all). This asserts the actual generated docker
# invocation carries the trailing ":ro" that _build_docker_args is
# responsible for appending.
RO_DIR="$TMP/ro-data"
mkdir -p "$RO_DIR"
RO_RESOLVED="$(cd "$RO_DIR" && pwd -P)"
P_RO="$TMP/mnt-ro"
mkdir -p "$P_RO"
cat > "$P_RO/sandbox.yaml" <<YAML
name: mnt-ro
firewall: open
mounts:
  - host: $RO_DIR
    container: /data
    readonly: true
YAML
docker image tag sandbox-base:latest sandbox-mnt-ro:latest >/dev/null 2>&1
check_output "readonly:true reaches the docker invocation as a trailing :ro (M3)" \
    "${RO_RESOLVED}:/data:ro" \
    run_cfg_trace "$P_RO" run -- true

# ── corrective round: C1/C2 re-opened via a symlink target, C3's hop cap ──
#
# The first fix wave checked $raw for a ':'/newline BEFORE resolution, and
# collapsed a leading "//" on resolve_host_path's INPUT before its symlink
# loop ran. A symlink's TARGET is resolved fully inside resolve_host_path,
# AFTER both of those checks — so a plain, characterless relative path like
# "./evil" sailed through the $raw checks, then the symlink loop handed back
# a resolved string containing a ':' or a leading "//" that nothing
# rechecked. These three assertions exercise exactly that: the config value
# itself is always an unremarkable relative path; only the symlink it points
# through carries the dangerous string.

# A symlink whose TARGET contains a ':' — the same C1 exploit, but reached
# through a symlink instead of spelled directly in host:. The $raw value
# ("./evil") has no colon at all; only the resolved target does. The target
# must actually EXIST for this to reach the check being tested: resolve_host_path
# only ever hands back a successfully-resolved path from `pwd -P` on a
# directory it could `cd` into, and a colon is a perfectly legal character in
# a real Unix directory name — Docker's -v grammar just cannot represent one.
# (A target that does NOT exist, like a bare "/:/hostroot", is caught earlier
# now — by the fail-closed resolver check itself, not this recheck — which is
# exactly the class fix; that path is exercised by mnt-trav2 above.)
P_SYMCOLON=$(mk_mount_proj mnt-symcolon "./evil")
mkdir -p "$P_SYMCOLON/host:root"
ln -sf "$P_SYMCOLON/host:root" "$P_SYMCOLON/evil"
check_output "a symlink whose target contains ':' is refused" \
    "resolved path contains a ':' or a newline" \
    run_cfg "$P_SYMCOLON" run -- true
check_status "the symlink-colon refusal halts execution" 1 \
    run_cfg "$P_SYMCOLON" run -- true

# A symlink whose TARGET begins "//" — the same C2 exploit, reached through
# a symlink. Resolves to the sensitive /etc entry once the output-side "//"
# collapse runs, so this is refused as a sensitive-path match, not a
# not-yet-resolved string.
P_SYMDSLASH=$(mk_mount_proj mnt-symdslash "./evil")
ln -sf "//etc" "$P_SYMDSLASH/evil"
check_output "a symlink whose target begins // is refused" \
    "Refusing to mount sensitive path" \
    run_cfg "$P_SYMDSLASH" run -- true

# A symlink chain longer than the 40-hop cap. Fixture builds l0 (a real
# symlink to the Docker socket) through l45 (46 links total, well past the
# cap), then mounts ./l45. Before this round's fix, resolve_host_path's loop
# stopped mid-chain at hop 40 and returned the still-unresolved intermediate
# path with NO warning at all (worse: [-e] then silently followed the
# remaining links when deciding whether to print the "does not exist"
# warning, so even that fallback was suppressed) — Docker would then resolve
# the rest of the chain itself at mount time. Now validate_mount refuses
# outright whenever resolve_host_path hands back a path that is still a
# symlink.
P_SYMDEEP=$(mk_mount_proj mnt-symdeep "./l45")
ln -sf /var/run/docker.sock "$P_SYMDEEP/l0"
for _n in $(seq 1 45); do ln -sf "l$((_n - 1))" "$P_SYMDEEP/l$_n"; done
check_output "a symlink chain past the hop cap is refused" \
    "symlink chain too deep to resolve" \
    run_cfg "$P_SYMDEEP" run -- true
check_status "the deep-chain refusal halts execution" 1 \
    run_cfg "$P_SYMDEEP" run -- true

# ── structural fix: resolve_host_path fails closed instead of fail-open ──
#
# Round 5's diagnosis: resolve_host_path could not report failure at all, so
# "I could not resolve this path" was indistinguishable from "this is a
# plain, safe path" — every branch that could not fully resolve a path used
# to fall back to the caller's RAW string, which then carried none of the
# shapes the checks above look for (no ':', no "..", no "//") and sailed
# through every one of them. These four assertions pin the fix: a resolver
# failure channel, checked with `if ! path=$(resolve_host_path ...)`.
echo "-- resolve_host_path fail-closed (structural fix) --"

# Bypass 1 (CRITICAL): a symlink whose PARENT directory is unreadable
# (chmod 000). The symlink's own lstat needs search permission on that
# parent, so it cannot even be detected as a symlink — resolution falls
# straight to the dirname+basename branch, where `cd` into the chmod-000
# parent also fails. Verified live before this fix: this exact shape mounted
# a symlink to $HOME/.ssh read-write, readable and writable from the
# container, with the CLI printing a false "does not exist" warning about a
# path that does exist. Built entirely inside $TMP per the task's own
# instruction (git cannot ship mode 000, but tar/zip preserve directory
# modes, so this is a realistic delivery); chmod 755 is restored in the
# top-of-file EXIT trap, since `rm -rf` cannot otherwise remove it afterward.
P_EACCESS=$(mk_mount_proj mnt-eaccess "./blocked/s")
mkdir -p "$P_EACCESS/blocked"
ln -sf "$HOME/.ssh" "$P_EACCESS/blocked/s"
chmod 000 "$P_EACCESS/blocked"
check_output "a symlink behind an unreadable (chmod 000) parent is refused (Bypass 1, CRITICAL)" \
    "its real path could not be determined" \
    run_cfg "$P_EACCESS" run -- true
check_status "the EACCES refusal halts execution" 1 \
    run_cfg "$P_EACCESS" run -- true

# Bypass 2 (HIGH): host: "" resolves to CWD plus a trailing "/" (dirname ""
# is ".", basename "" is empty), and mount_sensitive_exact's plain `=`
# compare then lets "$HOME/" slip past an exact match on "$HOME" — from a
# project checked out AT $HOME (a dotfiles repo), this mounted the entire
# home directory read-write. Refused outright now, before resolution ever
# runs.
P_EMPTYHOST="$TMP/mnt-emptyhost"
mkdir -p "$P_EMPTYHOST"
cat > "$P_EMPTYHOST/sandbox.yaml" <<'YAML'
name: mnt-emptyhost
firewall: open
mounts:
  - host: ""
    container: /data
YAML
docker image tag sandbox-base:latest sandbox-mnt-emptyhost:latest >/dev/null 2>&1
check_output "an empty host: is refused (Bypass 2)" \
    "empty or whitespace-only" \
    run_cfg "$P_EMPTYHOST" run -- true
check_status "the empty-host refusal halts execution" 1 \
    run_cfg "$P_EMPTYHOST" run -- true

# The same gap, spelled with whitespace instead of nothing: dirname/basename
# do not treat "   " as blank, so this must be its own check, not covered by
# a bare `-z "$raw"` test.
P_WSHOST="$TMP/mnt-wshost"
mkdir -p "$P_WSHOST"
cat > "$P_WSHOST/sandbox.yaml" <<'YAML'
name: mnt-wshost
firewall: open
mounts:
  - host: "   "
    container: /data
YAML
docker image tag sandbox-base:latest sandbox-mnt-wshost:latest >/dev/null 2>&1
check_output "a whitespace-only host: is refused (Bypass 2)" \
    "empty or whitespace-only" \
    run_cfg "$P_WSHOST" run -- true
check_status "the whitespace-host refusal halts execution" 1 \
    run_cfg "$P_WSHOST" run -- true

# The control: a fix that refuses everything unresolvable is not a fix. This
# path's LEAF does not exist yet, but its PARENT does and is fully readable —
# resolve_host_path must still resolve the parent, reattach the leaf, and
# succeed, exactly as it always has for a brand-new output path.
NOTYET_PARENT="$TMP/notyet-parent"
mkdir -p "$NOTYET_PARENT"
P_NOTYET="$TMP/mnt-notyet"
mkdir -p "$P_NOTYET"
cat > "$P_NOTYET/sandbox.yaml" <<YAML
name: mnt-notyet
firewall: open
mounts:
  - host: $NOTYET_PARENT/brandnew
    container: /data
YAML
docker image tag sandbox-base:latest sandbox-mnt-notyet:latest >/dev/null 2>&1
# This check MUST run before any other invocation of this same fixture:
# `docker run -v` auto-creates a missing host source, so the very act of
# running it once makes the leaf exist — a later check reusing this fixture
# would then observe an already-existing path and stop proving anything
# about the "does not exist yet" case at all.
check_output "a not-yet-existing path under a readable parent still gets the existing 'does not exist' warning (control)" \
    "does not exist; Docker will create it root-owned" \
    run_cfg "$P_NOTYET" run -- true
check_not_output "...and is not refused" \
    "Refusing mount" \
    run_cfg "$P_NOTYET" run -- true
check_output "...and the project actually reaches execution" \
    "Running sandbox-" \
    run_cfg "$P_NOTYET" run -- true

# ── canonicalized deny policy: symlinked entries + ancestor-aware socket ──
#
# Round 6 found the complementary half of Round 5's structural fix:
# resolve_host_path canonicalizes the mount being checked, but the deny
# lists themselves were always compared as raw, unresolved literals — so
# wherever resolving a deny entry changed it, that entry was DEAD, and the
# depth-1-only Docker socket containment check missed any daemon socket
# nested two or more directories deep (Colima, OrbStack, Lima). Both are
# fixed by the same mechanism: canonicalize the policy, then compare
# canonical-to-canonical.
echo "-- canonicalized deny policy (Round 6 fix) --"

# Bypass 6 (CRITICAL): an ordinary stow/chezmoi/yadm dotfiles layout symlinks
# $HOME/.ssh elsewhere. Before this fix, mount_sensitive_prefixes' literal
# "$HOME/.ssh" entry was compared UNRESOLVED, so it could never equal the
# fully-resolved mount path (somewhere under dotfiles/ssh) — the deny entry
# was dead, and the sensitive path was reachable by its literal name. Built
# entirely under a throwaway HOME inside $TMP.
FAKEHOME="$TMP/fakehome"
mkdir -p "$FAKEHOME/dotfiles/ssh"
ln -s "$FAKEHOME/dotfiles/ssh" "$FAKEHOME/.ssh"
P_SYMDENY="$TMP/mnt-symdeny"
mkdir -p "$P_SYMDENY"
cat > "$P_SYMDENY/sandbox.yaml" <<YAML
name: mnt-symdeny
firewall: open
mounts:
  - host: $FAKEHOME/.ssh
    container: /data
YAML
docker image tag sandbox-base:latest sandbox-mnt-symdeny:latest >/dev/null 2>&1
check_output "a symlinked \$HOME/.ssh (stow/chezmoi/yadm dotfiles layout) is refused (Bypass 6, CRITICAL)" \
    "Refusing to mount sensitive path" \
    env HOME="$FAKEHOME" bash -c "cd '$P_SYMDENY' && '$SANDBOX' run -- true"
check_status "the symlinked-deny-entry refusal halts execution" 1 \
    env HOME="$FAKEHOME" bash -c "cd '$P_SYMDENY' && '$SANDBOX' run -- true"

# Control: the identical config with a NON-symlinked \$HOME/.ssh must still
# be refused — proving it is the symlink specifically that used to matter,
# not something else about this fixture.
FAKEHOME2="$TMP/fakehome-plain"
mkdir -p "$FAKEHOME2/.ssh"
P_SYMDENY_CTRL="$TMP/mnt-symdeny-ctrl"
mkdir -p "$P_SYMDENY_CTRL"
cat > "$P_SYMDENY_CTRL/sandbox.yaml" <<YAML
name: mnt-symdeny-ctrl
firewall: open
mounts:
  - host: $FAKEHOME2/.ssh
    container: /data
YAML
docker image tag sandbox-base:latest sandbox-mnt-symdeny-ctrl:latest >/dev/null 2>&1
check_output "the control (non-symlinked \$HOME/.ssh) is refused the same way" \
    "Refusing to mount sensitive path" \
    env HOME="$FAKEHOME2" bash -c "cd '$P_SYMDENY_CTRL' && '$SANDBOX' run -- true"

# Isolates JUST the trailing-slash variable against the SAME non-symlinked
# fixture used in the control immediately above (same mount, same HOME
# value except for the slash): the resolved deny entry and the resolved
# mount path must still meet whatever shape HOME itself is spelled in (the
# bug write-up calls out an automounted/NFS home and a trailing-slash HOME
# as the same class of gap). Deliberately reuses P_SYMDENY_CTRL rather than
# the symlinked P_SYMDENY fixture above, so this varies exactly one thing.
check_output "the same non-symlinked fixture is refused with a trailing slash on HOME too" \
    "Refusing to mount sensitive path" \
    env HOME="$FAKEHOME2/" bash -c "cd '$P_SYMDENY_CTRL' && '$SANDBOX' run -- true"

# Control, not over-broad: a sibling merely string-prefixed by the symlinked
# entry's name must still be allowed once both sides are resolved — this is
# the same boundary-awareness the mnt-sshfoo case above pins, repeated here
# because the deny entry on this path is now a RESOLVED value, not the raw
# literal, and boundary-awareness must survive that.
P_SYMSSHFOO="$TMP/mnt-symsshfoo"
mkdir -p "$FAKEHOME/.sshfoo"
mkdir -p "$P_SYMSSHFOO"
cat > "$P_SYMSSHFOO/sandbox.yaml" <<YAML
name: mnt-symsshfoo
firewall: open
mounts:
  - host: $FAKEHOME/.sshfoo
    container: /data
YAML
docker image tag sandbox-base:latest sandbox-mnt-symsshfoo:latest >/dev/null 2>&1
check_not_output "a sibling merely named similarly is still allowed (control)" \
    "Refusing to mount" \
    env HOME="$FAKEHOME" bash -c "cd '$P_SYMSSHFOO' && '$SANDBOX' run -- true"
check_output "...and the sibling project actually reaches execution" \
    "Running sandbox-" \
    env HOME="$FAKEHOME" bash -c "cd '$P_SYMSSHFOO' && '$SANDBOX' run -- true"

# Bypass 7 (CRITICAL): Colima (~/.colima/default/docker.sock), OrbStack
# (~/.orbstack/run/docker.sock), and Lima (~/.lima/<vm>/sock/docker.sock)
# all nest their socket two or three directories below a path a project
# might otherwise mount, and the old check "[ -e "$path/docker.sock" ]" only
# ever looked one level down. A real second daemon is not needed to prove
# the VALIDATOR's own logic — it is a pure bash path comparison against
# _docker_socket_path that never dials anything. Only "docker image ls -q",
# the CLI's own pre-flight image-existence check, needs to keep working
# under the fake DOCKER_HOST this fixture sets; a tiny `docker` shim placed
# ahead of it on PATH answers that one query truthfully and forwards
# anything else — never reached, since the mount is expected to be refused
# before "docker run" — to the real binary.
mkdir -p "$TMP/sockdir/run"
: > "$TMP/sockdir/run/docker.sock"
P_SOCKDIR2="$TMP/mnt-sockdir2"
mkdir -p "$P_SOCKDIR2"
cat > "$P_SOCKDIR2/sandbox.yaml" <<YAML
name: mnt-sockdir2
firewall: open
mounts:
  - host: $TMP/sockdir
    container: /data
YAML
docker image tag sandbox-base:latest sandbox-mnt-sockdir2:latest >/dev/null 2>&1
REAL_DOCKER=$(command -v docker)
mkdir -p "$TMP/binstub"
cat > "$TMP/binstub/docker" <<EOF
#!/bin/bash
if [ "\$1" = "image" ] && [ "\$2" = "ls" ]; then
    echo "deadbeefcafe0000"
    exit 0
fi
exec "$REAL_DOCKER" "\$@"
EOF
chmod +x "$TMP/binstub/docker"

check_output "a socket nested two levels deep (Colima/OrbStack/Lima layout) is refused (Bypass 7, CRITICAL)" \
    "is, or contains, the Docker socket" \
    env PATH="$TMP/binstub:$PATH" DOCKER_HOST="unix://$TMP/sockdir/run/docker.sock" \
        bash -c "cd '$P_SOCKDIR2' && '$SANDBOX' run -- true"
check_status "the depth-2 socket refusal halts execution" 1 \
    env PATH="$TMP/binstub:$PATH" DOCKER_HOST="unix://$TMP/sockdir/run/docker.sock" \
        bash -c "cd '$P_SOCKDIR2' && '$SANDBOX' run -- true"

# The kept depth-1 + basename check still pulls its own weight: a genuinely
# unrelated file named docker.sock (not a symlink to, and not nested under,
# the socket _docker_socket_path actually resolves to) is NOT an ancestor
# match, so only the older check catches it. Uses the default DOCKER_HOST
# (unset), so no shim is needed here.
P_DECOY="$TMP/mnt-decoy"
mkdir -p "$TMP/decoydir"
echo "not a real socket" > "$TMP/decoydir/docker.sock"
mkdir -p "$P_DECOY"
cat > "$P_DECOY/sandbox.yaml" <<YAML
name: mnt-decoy
firewall: open
mounts:
  - host: $TMP/decoydir
    container: /data
YAML
docker image tag sandbox-base:latest sandbox-mnt-decoy:latest >/dev/null 2>&1
check_output "an unrelated decoy docker.sock is still refused by the depth-1 check" \
    "is, or contains, the Docker socket" \
    run_cfg "$P_DECOY" run -- true

# Context-configured Docker sockets (HIGH, closing-review finding): Colima
# and OrbStack are at least as commonly selected via `docker context use …`
# as via an exported DOCKER_HOST — that command writes to
# ~/.docker/config.json, which docker reads instead, leaving DOCKER_HOST
# unset. _docker_socket_path's ancestor check only ever looks at
# DOCKER_HOST, so with it unset the real socket is invisible to that check
# no matter how deep the ancestor walk goes. These fixtures explicitly
# unset DOCKER_HOST and rely entirely on the new $HOME/.colima /
# $HOME/.orbstack entries in mount_sensitive_prefixes, which deny by NAME
# and so do not depend on how (or whether) the active socket is discovered.
FAKEHOME3="$TMP/fakehome-colima"
mkdir -p "$FAKEHOME3/.colima/default"
: > "$FAKEHOME3/.colima/default/docker.sock"
P_COLIMA="$TMP/mnt-colima"
mkdir -p "$P_COLIMA"
cat > "$P_COLIMA/sandbox.yaml" <<'YAML'
name: mnt-colima
firewall: open
mounts:
  - host: "~/.colima"
    container: /data
YAML
docker image tag sandbox-base:latest sandbox-mnt-colima:latest >/dev/null 2>&1
check_output "~/.colima is refused with DOCKER_HOST unset (context-configured Colima)" \
    "Refusing to mount sensitive path" \
    env -u DOCKER_HOST HOME="$FAKEHOME3" bash -c "cd '$P_COLIMA' && '$SANDBOX' run -- true"
check_status "the ~/.colima refusal halts execution" 1 \
    env -u DOCKER_HOST HOME="$FAKEHOME3" bash -c "cd '$P_COLIMA' && '$SANDBOX' run -- true"

FAKEHOME4="$TMP/fakehome-orbstack"
mkdir -p "$FAKEHOME4/.orbstack/run"
: > "$FAKEHOME4/.orbstack/run/docker.sock"
P_ORBSTACK="$TMP/mnt-orbstack"
mkdir -p "$P_ORBSTACK"
cat > "$P_ORBSTACK/sandbox.yaml" <<'YAML'
name: mnt-orbstack
firewall: open
mounts:
  - host: "~/.orbstack"
    container: /data
YAML
docker image tag sandbox-base:latest sandbox-mnt-orbstack:latest >/dev/null 2>&1
check_output "~/.orbstack is refused with DOCKER_HOST unset (context-configured OrbStack)" \
    "Refusing to mount sensitive path" \
    env -u DOCKER_HOST HOME="$FAKEHOME4" bash -c "cd '$P_ORBSTACK' && '$SANDBOX' run -- true"
check_status "the ~/.orbstack refusal halts execution" 1 \
    env -u DOCKER_HOST HOME="$FAKEHOME4" bash -c "cd '$P_ORBSTACK' && '$SANDBOX' run -- true"

echo ""

# ── regression-fix batch: R1-R4 (operator-facing regressions) ──────────
#
# Found by a post-hoc review of this branch. All four are operator-facing
# regressions against main, not new security holes: main's behavior for each
# is restored here. The two deliberate, owner-approved relaxations (widened
# env-key regex; named-volume branch skipping host-path validation) are
# called out at their own assertions below.
echo "-- regression fixes (R1-R4) --"

# R1: yq v4 preserves the source spelling, so `readonly: True` (capital T,
# also `yes`/`on` etc.) failed the old `[ "$flag" = "true" ]` string compare
# and silently dropped :ro — a requested read-only mount became read-write.
RO_CAP_DIR="$TMP/ro-data-cap"
mkdir -p "$RO_CAP_DIR"
RO_CAP_RESOLVED="$(cd "$RO_CAP_DIR" && pwd -P)"
P_RO_CAP="$TMP/mnt-ro-cap"
mkdir -p "$P_RO_CAP"
cat > "$P_RO_CAP/sandbox.yaml" <<YAML
name: mnt-ro-cap
firewall: open
mounts:
  - host: $RO_CAP_DIR
    container: /data
    readonly: True
YAML
docker image tag sandbox-base:latest sandbox-mnt-ro-cap:latest >/dev/null 2>&1
check_output "readonly: True (yq-preserved capitalization) still produces a trailing :ro (R1)" \
    "${RO_CAP_RESOLVED}:/data:ro" \
    run_cfg_trace "$P_RO_CAP" run -- true

# R2a: yq's `//` treats boolean false as falsy, so `env: {X: false}` used to
# export X= (empty) instead of X=false, unlike main.
P_ENVBOOL="$TMP/env-bool"
mkdir -p "$P_ENVBOOL"
cat > "$P_ENVBOOL/sandbox.yaml" <<'YAML'
name: env-bool
firewall: open
env:
  TELEMETRY: false
YAML
docker image tag sandbox-base:latest sandbox-env-bool:latest >/dev/null 2>&1
check_output "env: {X: false} exports X=false, not X= (R2a)" \
    "TELEMETRY=false" \
    run_cfg "$P_ENVBOOL" run -- env

# R2b: validate_env_key's regex used to hard-reject keys with '-' or '.',
# which docker's `-e KEY=VAL` accepts and which worked on main. Widening the
# regex is deliberate and owner-approved (see the comment on validate_env_key
# itself for why it stays safe): the key only ever reaches yq via `strenv`
# (data, never expression text), and neither '.' nor '-' can split a docker
# `-e KEY=VAL` argument or start an option.
P_ENVDASH="$TMP/env-dash"
mkdir -p "$P_ENVDASH"
cat > "$P_ENVDASH/sandbox.yaml" <<'YAML'
name: env-dash
firewall: open
env:
  my-app.debug: "1"
YAML
docker image tag sandbox-base:latest sandbox-env-dash:latest >/dev/null 2>&1
check_not_output "a dash/dot env key is no longer rejected (R2b, deliberate relaxation)" \
    "Invalid env var name" \
    run_cfg "$P_ENVDASH" run -- true
check_output "...and the dash/dot-key project actually reaches execution" \
    "Running sandbox-" \
    run_cfg "$P_ENVDASH" run -- true

# Control: the widened regex must NOT reopen the yq-expression injection this
# branch's own env-key check exists to stop. The key contains spaces, a pipe,
# quotes, and parens — none of which the widened class (letters, digits, '_',
# '.', '-') admits — so this must still be refused exactly as before.
check_output "a yq-expression env key is STILL refused after the regex widening (R2 control)" \
    "Invalid env var name" \
    run_cfg "$P_INJ" run -- env

# R3a: a missing `host:` key used to yield the literal string "null" from yq,
# which resolved against CWD and bind-mounted a root-owned $CWD/null.
P_NOHOST="$TMP/mnt-nohost"
mkdir -p "$P_NOHOST"
cat > "$P_NOHOST/sandbox.yaml" <<'YAML'
name: mnt-nohost
firewall: open
mounts:
  - container: /data
YAML
docker image tag sandbox-base:latest sandbox-mnt-nohost:latest >/dev/null 2>&1
check_output "a mount with no host: is refused with a clear message (R3a)" \
    "missing host:/container:" \
    run_cfg "$P_NOHOST" run -- true
check_status "the missing-host refusal halts execution" 1 \
    run_cfg "$P_NOHOST" run -- true

# The same check covers a missing container: too (the fix's error message
# names both keys).
P_NOCONTAINER="$TMP/mnt-nocontainer"
mkdir -p "$P_NOCONTAINER"
cat > "$P_NOCONTAINER/sandbox.yaml" <<YAML
name: mnt-nocontainer
firewall: open
mounts:
  - host: $TMP/safe-data
YAML
docker image tag sandbox-base:latest sandbox-mnt-nocontainer:latest >/dev/null 2>&1
check_output "a mount with no container: is refused with a clear message" \
    "missing host:/container:" \
    run_cfg "$P_NOCONTAINER" run -- true

# R3b: a bare name (host: cache) is a Docker NAMED VOLUME on main, not a host
# path — resolving it against CWD instead silently orphans persisted data (a
# fresh, root-owned ./cache bind mount takes its place). The named-volume
# branch is the other deliberate, owner-approved relaxation: Docker manages a
# named volume, it cannot reach host files, so host-path validation does not
# apply to it. The spec's load-bearing trap: the fixed code must build the
# spec from the volume NAME, never from VALIDATED_MOUNT_PATH (which would
# hold a stale value from a previous loop iteration).
P_NAMEDVOL="$TMP/mnt-namedvol"
mkdir -p "$P_NAMEDVOL"
cat > "$P_NAMEDVOL/sandbox.yaml" <<'YAML'
name: mnt-namedvol
firewall: open
mounts:
  - host: cache
    container: /data
YAML
docker image tag sandbox-base:latest sandbox-mnt-namedvol:latest >/dev/null 2>&1
# Note: matched with a preceding space/no-slash so this can't pass vacuously
# against the pre-fix bug's CWD-relative bind spec (".../mnt-namedvol/cache:/data"),
# which also ends in the substring "cache:/data" but has a '/' immediately before it.
check_output "a bare host: name reaches the docker invocation as a named volume, verbatim (R3b)" \
    "[[:space:]]cache:/data" \
    run_cfg_trace "$P_NAMEDVOL" run -- true
check_not_output "...and it is NOT a CWD-relative bind-mount path ending the same way" \
    "/cache:/data" \
    run_cfg_trace "$P_NAMEDVOL" run -- true
if [ -e "$P_NAMEDVOL/cache" ]; then
    echo "  FAIL: no ./cache directory is created next to sandbox.yaml (R3b)"
    FAIL=$((FAIL + 1))
else
    echo "  PASS: no ./cache directory is created next to sandbox.yaml (R3b)"
    PASS=$((PASS + 1))
fi

# R3 control: the named-volume branch's stale-VALIDATED_MOUNT_PATH trap,
# pinned directly. A mount immediately BEFORE this one validates a real path
# (SAFE_DIR, from the mnt-safe fixture above) and sets VALIDATED_MOUNT_PATH
# to it; if the named-volume branch on this second mount ever consumed that
# stale global instead of the volume name, this mount would come out as
# SAFE_DIR's resolved path, not "cachevol". Two mounts, in this exact order.
P_STALECHECK="$TMP/mnt-stalecheck"
mkdir -p "$P_STALECHECK"
cat > "$P_STALECHECK/sandbox.yaml" <<YAML
name: mnt-stalecheck
firewall: open
mounts:
  - host: $SAFE_DIR
    container: /first
  - host: cachevol
    container: /second
YAML
docker image tag sandbox-base:latest sandbox-mnt-stalecheck:latest >/dev/null 2>&1
# Same word-boundary care as the R3b check above: a pre-fix CWD-relative bind
# spec for this mount would ALSO end in the substring "cachevol:/second".
check_output "the second mount uses its OWN name, not the first mount's resolved path (R3 stale-value trap)" \
    "[[:space:]]cachevol:/second" \
    run_cfg_trace "$P_STALECHECK" run -- true
check_not_output "...and it is NOT a CWD-relative bind-mount path ending the same way" \
    "/cachevol:/second" \
    run_cfg_trace "$P_STALECHECK" run -- true
check_not_output "...and never leaks the prior mount's resolved path onto the second spec" \
    "${SAFE_DIR}:/second" \
    run_cfg_trace "$P_STALECHECK" run -- true

# R4: a path missing more than one level (Docker auto-creates every missing
# component on main) used to hard-fail with "a parent directory is not
# readable or traversable" — a wrong diagnosis; the path simply doesn't
# exist yet, and its nearest existing ancestor (here, $TMP/multimiss-root)
# is perfectly readable.
MULTIMISS_ROOT="$TMP/multimiss-root"
mkdir -p "$MULTIMISS_ROOT"
MULTIMISS_RESOLVED="$(cd "$MULTIMISS_ROOT" && pwd -P)"
P_MULTIMISS="$TMP/mnt-multimiss"
mkdir -p "$P_MULTIMISS"
cat > "$P_MULTIMISS/sandbox.yaml" <<YAML
name: mnt-multimiss
firewall: open
mounts:
  - host: $MULTIMISS_ROOT/nodir/a/b
    container: /data
YAML
docker image tag sandbox-base:latest sandbox-mnt-multimiss:latest >/dev/null 2>&1
check_output "a path missing 2+ levels under a readable ancestor is allowed (R4)" \
    "does not exist; Docker will create it root-owned" \
    run_cfg "$P_MULTIMISS" run -- true
check_not_output "...and is not refused as unresolvable" \
    "could not be determined" \
    run_cfg "$P_MULTIMISS" run -- true
check_output "...and the traced spec shows the fully constructed absolute path" \
    "${MULTIMISS_RESOLVED}/nodir/a/b:/data" \
    run_cfg_trace "$P_MULTIMISS" run -- true

# R4's second half: validate_mount's failure message used to conflate "does
# not exist" with "exists but is not readable/traversable" under one
# generic diagnosis. Now that the missing-ancestor case succeeds instead of
# failing, the one remaining failure message can and must be accurate: pin
# the corrected wording directly against the pre-existing EACCES fixture
# (P_EACCESS, defined above) rather than just its unchanged first line. The
# wording itself was widened again in a later review round to also cover the
# unresolvable-".." and non-directory/dangling-symlink failure modes, which
# this same generic message now has to describe accurately too.
check_output "the EACCES failure states the accurate diagnosis, not the old misdiagnosis (R4 wording fix)" \
    "may be unreadable, contain an unresolvable" \
    run_cfg "$P_EACCESS" run -- true

# ── final review fix wave: dangling symlink in the ancestor walk ───────
#
# Finding 1: the ancestor walk's old check order was `[ -e "$anc" ] && [ !
# -d "$anc" ]` before `[ -d "$anc" ]`. `-e` FOLLOWS symlinks, so it is FALSE
# for a symlink whose target does not exist — a dangling symlink component
# slipped past both checks and fell through to the "doesn't exist yet,
# reattach as literal text" branch, resolving "successfully" to a path like
# ".../hop/data" where "hop" is actually a broken symlink, not a real
# directory. At b1ca9d6 (before the ancestor walk existed) the same shape
# was refused outright. Docker itself follows symlinks at mount time and
# auto-creates a missing target as a real directory, so this could silently
# escape through wherever the dangling symlink actually points once Docker
# resolves it — none of the checks above ever see that real target. Fixed by
# checking `-L` (true for a dangling symlink even though `-e` is false for
# one) and moving the directory check first.
P_DANGLE=$(mk_mount_proj mnt-dangle "./hop/data")
ln -sf "$TMP/mnt-dangle-nonexistent-target" "$P_DANGLE/hop"
check_output "a dangling symlink component in the mount path is refused" \
    "non-directory or dangling-symlink component" \
    run_cfg "$P_DANGLE" run -- true
check_status "the dangling-symlink refusal halts execution" 1 \
    run_cfg "$P_DANGLE" run -- true

# The two other shapes the finding requires to keep working (a multi-level
# missing path under a real dir still resolving — R4; an unresolvable ".."
# still refusing) are pinned by the pre-existing mnt-multimiss and
# mnt-trav2 assertions above; not re-asserted here to avoid re-running
# those fixtures a second time (docker auto-creates a missing bind source
# the first time it's actually mounted, which would make a second
# "does not exist yet" assertion against the same fixture observe an
# already-existing path and stop proving anything, per that section's own
# comment).

echo ""

# ── config tamper protection ────────────────────────────────────────
#
# sandbox.yaml/.yml is committed and travels with the repo, so a
# prompt-injected agent that can WRITE it (through the read-write workspace
# mount) can plant an escalated config for the operator's next run. These
# tests pin the read-only file-bind overlay in _build_docker_args (writes
# refused, delete/rename-over refused with EBUSY, reads still work), the
# runner-side escape hatch, and the sandbox.yaml/sandbox.yml precedence guard
# in find_config. Real container runs, not dry-run traces — the :ro write
# failure and the EBUSY on unlink are kernel behavior a trace cannot prove.
echo "-- config tamper protection --"

mk_cfgtrust_proj() {
    local name="$1"
    local dir="$TMP/$name"
    mkdir -p "$dir"
    { echo "name: $name"; echo "firewall: open"; } > "$dir/sandbox.yaml"
    docker image tag sandbox-base:latest "sandbox-${name}:latest" >/dev/null 2>&1
    echo "$dir"
}

# Tests 1-3: default mount (no mounts: key) — the config sits at $(pwd),
# bind-mounted whole at /workspace, so the overlay should land specifically
# at /workspace/sandbox.yaml. Three INDEPENDENT fixtures, deliberately not
# shared: a successful write (the pre-fix vulnerability itself) corrupts the
# fixture's YAML with a bare trailing "x", which would then make find_config's
# own YAML-validity check fail on a later reuse of the same file for an
# unrelated reason, masking whatever the delete/read checks are meant to prove.

# 1. Write refused. The base image's /bin/sh is dash, which reports a
# redirection-open failure with exit 2 (distinct from an ordinary command's
# own exit status) — confirmed empirically against this image before relying
# on the exact code here.
P_CFGWRITE=$(mk_cfgtrust_proj cfgtrust-write)
# Throwaway fixture — world-writable so the refusal below is provably the
# :ro overlay, not an incidental uid/permission mismatch (CI's ubuntu-latest
# runner is uid 1001, the container's node user is uid 1000; verified live
# that a uid-mismatched file can surface EACCES instead of EROFS while
# STILL exiting 2 either way, which would silently stop proving :ro at all).
chmod 666 "$P_CFGWRITE/sandbox.yaml"
CFGWRITE_BEFORE=$(cat "$P_CFGWRITE/sandbox.yaml")
check_status "in-container write to sandbox.yaml is refused (default mount)" 2 \
    run_cfg "$P_CFGWRITE" run -- sh -c 'echo x >> /workspace/sandbox.yaml'
CFGWRITE_AFTER=$(cat "$P_CFGWRITE/sandbox.yaml")
if [ "$CFGWRITE_BEFORE" = "$CFGWRITE_AFTER" ]; then
    echo "  PASS: host sandbox.yaml is byte-for-byte unchanged after the refused write"
    PASS=$((PASS + 1))
else
    echo "  FAIL: host sandbox.yaml changed after the refused write"
    echo "        before: $CFGWRITE_BEFORE"
    echo "        after:  $CFGWRITE_AFTER"
    FAIL=$((FAIL + 1))
fi

# 2. Delete refused. A bind mountpoint cannot be unlinked; GNU coreutils rm
# reports this as "Device or resource busy" (EBUSY) with exit 1.
P_CFGDELETE=$(mk_cfgtrust_proj cfgtrust-delete)
# Throwaway fixture — the DIRECTORY (not the file) must be world-writable:
# unlink() permission is governed by the parent directory, not the target
# file's own mode, so a uid-mismatched directory (CI's uid 1001 runner vs
# the container's uid-1000 node) makes rm fail with EACCES on the directory
# before ever reaching the mountpoint — masking the EBUSY the overlay is
# meant to prove instead of merely coinciding with it. Verified live.
chmod 777 "$P_CFGDELETE"
check_status "in-container delete of sandbox.yaml is refused (default mount)" 1 \
    run_cfg "$P_CFGDELETE" run -- sh -c 'rm /workspace/sandbox.yaml'
if [ -f "$P_CFGDELETE/sandbox.yaml" ]; then
    echo "  PASS: host sandbox.yaml still exists after the refused delete"
    PASS=$((PASS + 1))
else
    echo "  FAIL: host sandbox.yaml is gone after the refused delete"
    FAIL=$((FAIL + 1))
fi

# 3. Reads still work — only writes/deletes are cut off. The agent can see
# the config and PROPOSE changes; only the operator, on the host, can apply
# them.
P_CFGREAD=$(mk_cfgtrust_proj cfgtrust-read)
check_status "reading sandbox.yaml through the overlay still works (default mount)" 0 \
    run_cfg "$P_CFGREAD" run -- sh -c 'grep -q "^name:" /workspace/sandbox.yaml'

# 4. Custom mount followed: mounts: [{host: ., container: /app}] — the
# config's enclosing directory is bind-mounted at /app, so the overlay must
# land at /app/sandbox.yaml, not just the default /workspace path. Two
# independent fixtures again, for the same reason as tests 1-3 above: a
# successful pre-fix write would corrupt the YAML that the read/trace checks
# depend on.
mk_cfgtrust_custom_proj() {
    local name="$1"
    local dir="$TMP/$name"
    mkdir -p "$dir"
    { echo "name: $name"; echo "firewall: open"; echo "mounts:";
      echo "  - host: ."; echo "    container: /app"; } > "$dir/sandbox.yaml"
    docker image tag sandbox-base:latest "sandbox-${name}:latest" >/dev/null 2>&1
    echo "$dir"
}
P_CFGCUSTOM_W=$(mk_cfgtrust_custom_proj cfgtrust-custom-write)
# Throwaway fixture — world-writable for the same reason as P_CFGWRITE
# above: the refusal must be provably the :ro overlay, not an incidental
# uid mismatch between the CI runner (uid 1001) and the container's node
# user (uid 1000).
chmod 666 "$P_CFGCUSTOM_W/sandbox.yaml"
check_status "in-container write through a custom mount is refused (custom mount)" 2 \
    run_cfg "$P_CFGCUSTOM_W" run -- sh -c 'echo x >> /app/sandbox.yaml'

P_CFGCUSTOM_R=$(mk_cfgtrust_custom_proj cfgtrust-custom-read)
check_status "reading through the custom mount's overlay still works" 0 \
    run_cfg "$P_CFGCUSTOM_R" run -- sh -c 'grep -q "^name:" /app/sandbox.yaml'
check_output "the overlay targets the custom mount's own destination" \
    ":/app/sandbox.yaml:ro" \
    run_cfg_trace "$P_CFGCUSTOM_R" run -- true

# 5. Escape hatch: SANDBOX_ALLOW_WRITABLE_CONFIG=1 skips the overlay
# entirely, with a warning. A fixture copy only — never the repo's own files.
P_CFGESCAPE=$(mk_cfgtrust_proj cfgtrust-escape)
chmod 666 "$P_CFGESCAPE/sandbox.yaml"   # throwaway fixture — CI runs uid 1001, container node is 1000
check_output "the escape hatch prints its warning" \
    "SANDBOX_ALLOW_WRITABLE_CONFIG=1" \
    env SANDBOX_ALLOW_WRITABLE_CONFIG=1 bash -c "cd '$P_CFGESCAPE' && '$SANDBOX' run -- true"
check_status "the escape hatch actually allows the write to succeed" 0 \
    env SANDBOX_ALLOW_WRITABLE_CONFIG=1 bash -c "cd '$P_CFGESCAPE' && '$SANDBOX' run -- sh -c 'echo x >> /workspace/sandbox.yaml'"
check_output "...and it is the fixture's own host file that changed" \
    "x" \
    cat "$P_CFGESCAPE/sandbox.yaml"

# 6. Precedence guard: both sandbox.yaml and sandbox.yml present must refuse
# outright — closing the filename-precedence hole the overlay alone can't
# (an agent that cannot edit a protected sandbox.yml could otherwise just
# create a sandbox.yaml, which silently wins precedence next run).
P_CFGBOTH="$TMP/cfgtrust-bothnames"
mkdir -p "$P_CFGBOTH"
echo "name: cfgtrust-bothnames" > "$P_CFGBOTH/sandbox.yaml"
echo "name: cfgtrust-bothnames-alt" > "$P_CFGBOTH/sandbox.yml"
# Tagged so a pre-fix run reaches an actual container launch (silently using
# sandbox.yaml, the precedence hole itself) instead of stopping early at an
# unrelated "Project image not found" — which would otherwise mask the hole
# this test exists to demonstrate.
docker image tag sandbox-base:latest sandbox-cfgtrust-bothnames:latest >/dev/null 2>&1
check_output "both sandbox.yaml and sandbox.yml present is refused" \
    "Both sandbox.yaml and sandbox.yml exist" \
    run_cfg "$P_CFGBOTH" run -- true
check_status "the both-files refusal halts execution" 1 \
    run_cfg "$P_CFGBOTH" run -- true

# 7. Named-volume mounts get no overlay: a bare host: name is a Docker named
# volume, which exposes no host files at all. Guards against the overlay
# logic misfiring on the R3 named-volume branch — it must not treat the
# volume name as a directory to search for an ancestor match.
P_CFGNAMEDVOL="$TMP/cfgtrust-namedvol"
mkdir -p "$P_CFGNAMEDVOL"
cat > "$P_CFGNAMEDVOL/sandbox.yaml" <<'YAML'
name: cfgtrust-namedvol
firewall: open
mounts:
  - host: cachevol
    container: /data
YAML
docker image tag sandbox-base:latest sandbox-cfgtrust-namedvol:latest >/dev/null 2>&1
check_output "the named-volume mount itself still reaches docker unmodified" \
    "[[:space:]]cachevol:/data[[:space:]]" \
    run_cfg_trace "$P_CFGNAMEDVOL" run -- true
check_not_output "no config overlay is added when only a named volume is mounted" \
    "sandbox.yaml.*:ro" \
    run_cfg_trace "$P_CFGNAMEDVOL" run -- true
check_output "...and the command still executes successfully" \
    "Running sandbox-" \
    run_cfg "$P_CFGNAMEDVOL" run -- true

# 8. Finding 2 (final review): a mount whose SOURCE is the config file
# itself must not get a read-write bind. The overlay loop above deliberately
# skips a file-source mount (see its own comment) rather than double-mounting
# the same destination — but the MOUNTS loop that actually built this bind
# used to leave it with whatever readonly: the operator wrote for THIS
# mount (commonly unset, i.e. read-write). That let one such mount defeat
# the whole protection: verified live before the fix, a write through
# /escape/cfg.yaml changed the host config. The mounts loop now forces this
# exact shape read-only itself, the moment it sees the mount's own resolved
# source equal the config's own resolved path.
P_CFGSELFMOUNT="$TMP/cfgtrust-selfmount"
mkdir -p "$P_CFGSELFMOUNT"
cat > "$P_CFGSELFMOUNT/sandbox.yaml" <<'YAML'
name: cfgtrust-selfmount
firewall: open
mounts:
  - host: ./sandbox.yaml
    container: /escape/cfg.yaml
YAML
docker image tag sandbox-base:latest sandbox-cfgtrust-selfmount:latest >/dev/null 2>&1
# Throwaway fixture — world-writable so the write-refusal check below (this
# mount is forced read-only by the mounts loop, not the overlay loop) is
# provably that :ro, not an incidental uid mismatch between the CI runner
# (uid 1001) and the container's node user (uid 1000).
chmod 666 "$P_CFGSELFMOUNT/sandbox.yaml"
check_output "a mount whose source is the config file itself is forced read-only" \
    ":/escape/cfg.yaml:ro" \
    run_cfg_trace "$P_CFGSELFMOUNT" run -- true
CFGSELFMOUNT_BEFORE=$(cat "$P_CFGSELFMOUNT/sandbox.yaml")
check_status "an in-container write through that mount is refused" 2 \
    run_cfg "$P_CFGSELFMOUNT" run -- sh -c 'echo x >> /escape/cfg.yaml'
CFGSELFMOUNT_AFTER=$(cat "$P_CFGSELFMOUNT/sandbox.yaml")
if [ "$CFGSELFMOUNT_BEFORE" = "$CFGSELFMOUNT_AFTER" ]; then
    echo "  PASS: host sandbox.yaml is unchanged after the refused write through the self-mount"
    PASS=$((PASS + 1))
else
    echo "  FAIL: host sandbox.yaml changed after the refused write through the self-mount"
    echo "        before: $CFGSELFMOUNT_BEFORE"
    echo "        after:  $CFGSELFMOUNT_AFTER"
    FAIL=$((FAIL + 1))
fi

# 9. Finding 3 (final review): a config reached through an ancestor mount
# whose own RESOLVED directory contains a ':' must be refused cleanly, not
# left to reach docker's own opaque "too many colons" error. The mount's
# OWN host: value has no colon anywhere (validate_mount never sees one and
# validates it fine); only a deeper path component — the directory the
# config actually lives in, beneath the mounted ancestor — does.
P_CFGCOLONPARENT="$TMP/cfgtrust-colon-parent"
P_CFGCOLON="$P_CFGCOLONPARENT/weird:dir"
mkdir -p "$P_CFGCOLON"
cat > "$P_CFGCOLON/sandbox.yaml" <<YAML
name: cfgtrust-colon
firewall: open
mounts:
  - host: $P_CFGCOLONPARENT
    container: /app
YAML
docker image tag sandbox-base:latest sandbox-cfgtrust-colon:latest >/dev/null 2>&1
check_output "a config path containing ':' reached via an ancestor mount is refused cleanly" \
    "resolved path contains a ':' or a newline" \
    run_cfg "$P_CFGCOLON" run -- true
check_status "...and halts before ever reaching a docker invocation" 1 \
    run_cfg "$P_CFGCOLON" run -- true

# 10. Finding 3, round 2 (final review): the colon/newline guard must fire
# ONLY at the point an overlay is actually about to be emitted, never
# unconditionally for every invocation. A project simply CHECKED OUT under a
# colon-containing path, whose custom mounts: never expose the config at
# all, ran fine at e053569 and must keep running fine now — refusing it
# would be scope creep unconnected to anything the project configured. This
# fixture's config lives in a colon-containing directory (so $cfg_abs itself
# contains a colon), but its one mount points at a completely unrelated
# directory with no ancestor relationship to the config at all, so no
# overlay is ever computed and the guard's code path never runs.
P_CFGCOLONPARENT2="$TMP/cfgtrust-colon-noexpose-parent"
P_CFGCOLONNOEXPOSE="$P_CFGCOLONPARENT2/weird:dir2"
mkdir -p "$P_CFGCOLONNOEXPOSE"
CFGCOLON_UNRELATED="$TMP/cfgtrust-colon-unrelated"
mkdir -p "$CFGCOLON_UNRELATED"
cat > "$P_CFGCOLONNOEXPOSE/sandbox.yaml" <<YAML
name: cfgtrust-colon-noexpose
firewall: open
mounts:
  - host: $CFGCOLON_UNRELATED
    container: /data
YAML
docker image tag sandbox-base:latest sandbox-cfgtrust-colon-noexpose:latest >/dev/null 2>&1
check_output "a colon-path checkout whose mounts never expose the config runs fine (no scope creep)" \
    "Running sandbox-" \
    run_cfg "$P_CFGCOLONNOEXPOSE" run -- true
check_not_output "...and no refusal fires" \
    "Refusing to protect" \
    run_cfg "$P_CFGCOLONNOEXPOSE" run -- true
check_output "...and the unrelated mount itself still reaches docker" \
    "${CFGCOLON_UNRELATED}:/data" \
    run_cfg_trace "$P_CFGCOLONNOEXPOSE" run -- true
check_not_output "...and no config overlay is added at all" \
    "sandbox.yaml.*:ro" \
    run_cfg_trace "$P_CFGCOLONNOEXPOSE" run -- true

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
