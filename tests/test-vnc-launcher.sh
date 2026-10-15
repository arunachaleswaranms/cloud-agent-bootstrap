#!/usr/bin/env bash
#
# tests/test-vnc-launcher.sh — regression tests for scripts/macbook-vnc-launcher.sh
#
# Covers: private runtime directory, secure PID file, 127.0.0.1-only bind,
#        process cleanup (parent + children), stale PID files, wrong process
#        identity, PID reuse, startup timeout, startup failure, repeated
#        execution, and isolation from unrelated SSH/gcloud sessions.
#
# Fully hermetic: a fake `gcloud` stands in for the real one, and no macOS-only
# behaviour (Screen Sharing / IAP transport) is exercised.

set -uo pipefail

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SUITE_DIR/.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SUITE_DIR/lib/harness.sh"

LAUNCHER="$REPO_ROOT/scripts/macbook-vnc-launcher.sh"

trap sandbox_cleanup EXIT

make_fake_gcloud() {
    # $1 = destination path, $2 = "bind" | "nobind" | "exitfail"
    local dest="$1" mode="$2"
    cat > "$dest" <<'FAKE'
#!/usr/bin/env bash
# Fake gcloud for regression tests: emulates `gcloud compute ssh <vm> ...`.
: "${FAKE_GCLOUD_ARGV_FILE:?}"
printf '%s\n' "$@" > "$FAKE_GCLOUD_ARGV_FILE"

case "${FAKE_GCLOUD_MODE:-bind}" in
    exitfail)
        echo "ERROR: (gcloud) could not fetch credentials" >&2
        exit 1
        ;;
    bind)
        python3 -c '
import socket, sys, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1])))
s.listen(5)
time.sleep(600)
' "$FAKE_GCLOUD_PORT" &
        binder=$!
        # Stand-in for the ssh process gcloud spawns for the IAP forward.
        sleep 600 &
        child=$!
        cleanup() { kill "$binder" "$child" 2>/dev/null || true; }
        trap cleanup EXIT INT TERM
        wait
        ;;
    nobind)
        sleep 600 &
        child=$!
        cleanup() { kill "$child" 2>/dev/null || true; }
        trap cleanup EXIT INT TERM
        wait
        ;;
esac
FAKE
    chmod 755 "$dest"
}

setup_env() {
    local mode="${1:-bind}"
    sandbox_new
    VNC_PORT="$(free_port)"
    export FAKE_GCLOUD_MODE="$mode"
    export FAKE_GCLOUD_PORT="$VNC_PORT"
    export FAKE_GCLOUD_ARGV_FILE="$SANDBOX/gcloud-argv.txt"
    make_fake_gcloud "$SANDBOX/bin/gcloud" "$mode"

    export GCP_PROJECT="test-project"
    export GCP_ZONE="us-central1-a"
    export GCP_INSTANCE="agent-vm-test"
    export LOCAL_VNC_PORT="$VNC_PORT"
    export VNC_RUNTIME_DIR="$SANDBOX/state/vnc-tunnel"
    export TUNNEL_READY_TIMEOUT="6"
    export PATH="$SANDBOX/bin:$PATH"
    PID_FILE="$VNC_RUNTIME_DIR/tunnel.pid"
}

tunnel_pid() {
    sed -n '1p' "$PID_FILE" 2>/dev/null || true
}

tunnel_start_time() {
    sed -n '2p' "$PID_FILE" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
section "Static safety properties"

setup_env bind

launcher_src="$(cat "$LAUNCHER")"
launcher_code="$(grep -v '^[[:space:]]*#' "$LAUNCHER")"

assert_not_contains "no shared /tmp PID path is used" \
    "$launcher_src" "/tmp/macbook-vnc-tunnel.pid"
assert_not_contains "no generic pgrep -f process scan" \
    "$launcher_src" "pgrep -f"
assert_contains "runtime dir defaults under the user state directory" \
    "$launcher_src" '.local/state'
# shellcheck disable=SC2016  # literal script text, no expansion intended
assert_contains "local forward is pinned to 127.0.0.1" \
    "$launcher_src" '-L 127.0.0.1:${LOCAL_VNC_PORT}'
assert_not_contains "SSH host-key checking is not disabled" \
    "$launcher_code" "StrictHostKeyChecking=no"

# ---------------------------------------------------------------------------
section "Startup and runtime state"

out="$(bash "$LAUNCHER" start 2>&1)"
rc=$?
if [ "$rc" -eq 0 ]; then
    pass "start succeeds with a reachable forward"
else
    fail "start succeeds with a reachable forward" "rc=$rc; launcher output: ${out:-<empty>}"
fi
assert_file_exists "PID file is created in the private runtime dir" "$PID_FILE"
assert_mode "runtime directory is 0700" "$VNC_RUNTIME_DIR" "700"
assert_mode "PID file is 0600" "$PID_FILE" "600"
assert_eq "PID file records a two-line identity token" \
    "$(wc -l < "$PID_FILE" | tr -d ' ')" "2"

TPID="$(tunnel_pid)"
TSTART="$(tunnel_start_time)"
assert_alive "recorded tunnel process is alive" "$TPID"
assert_eq "recorded start time matches the live process" \
    "$TSTART" "$(proc_start_time "$TPID")"

out="$(bash "$LAUNCHER" --status 2>&1)"
assert_contains "status reports the tunnel as running" "$out" "IAP tunnel is running"
assert_contains "status reports the loopback bind address" "$out" "127.0.0.1:${VNC_PORT}"

# ---------------------------------------------------------------------------
section "Forward is bound to loopback only"

argv="$(cat "$SANDBOX/gcloud-argv.txt")"
assert_contains "ssh -L forward is explicitly bound to 127.0.0.1" \
    "$argv" "-L 127.0.0.1:${VNC_PORT}:127.0.0.1:5901"
assert_contains "IAP tunnelling is preserved" "$argv" "--tunnel-through-iap"

# ---------------------------------------------------------------------------
section "Child process tracking and cleanup"

children_before="$(pgrep -P "$TPID" 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')"
assert_cmd_ok "tunnel has at least one tracked child process" \
    test -n "$children_before"

# An unrelated SSH-looking session must survive our teardown.
make_fake_gcloud "$SANDBOX/bin/unrelated-ssh" bind
export FAKE_GCLOUD_ARGV_FILE="$SANDBOX/unrelated-argv.txt"
FAKE_GCLOUD_PORT="$(free_port)"
export FAKE_GCLOUD_PORT
spawn "$SANDBOX/bin/unrelated-ssh" compute ssh some-other-vm
UNRELATED="$LAST_PID"
sleep 1
assert_alive "unrelated ssh session is running" "$UNRELATED"

out="$(bash "$LAUNCHER" --stop 2>&1)"
assert_eq "stop succeeds" "$?" "0"
assert_dead "tunnel process is terminated" "$TPID"
for c in $children_before; do
    assert_dead "tunnel child $c is terminated" "$c"
done
assert_file_absent "PID file is removed after a clean stop" "$PID_FILE"
assert_alive "unrelated ssh session is left untouched" "$UNRELATED"

kill -KILL "$UNRELATED" 2>/dev/null || true

# ---------------------------------------------------------------------------
section "Stale PID files and wrong process identity"

setup_env bind

# (a) stale PID file pointing at a dead process
bash "$LAUNCHER" --stop >/dev/null 2>&1 || true
mkdir -p "$VNC_RUNTIME_DIR"
printf '%s\n%s\n' "999999" "Mon Jan  1 00:00:00 2024" > "$PID_FILE"
out="$(bash "$LAUNCHER" --status 2>&1)"
assert_contains "stale PID file is reported" "$out" "Stale PID file"
assert_file_absent "stale PID file is cleaned up" "$PID_FILE"

# (b) PID file pointing at a live but unrelated process with a valid start time
spawn sleep 600
VICTIM="$LAST_PID"
mkdir -p "$VNC_RUNTIME_DIR"
printf '%s\n%s\n' "$VICTIM" "$(proc_start_time "$VICTIM")" > "$PID_FILE"
out="$(bash "$LAUNCHER" --stop 2>&1)"
assert_alive "live process with a non-matching identity is NOT killed" "$VICTIM"
assert_contains "identity mismatch is reported" "$out" "does not match our tunnel signature"
assert_file_absent "bogus PID file is removed" "$PID_FILE"
kill -KILL "$VICTIM" 2>/dev/null || true

# (c) PID reuse: correct PID, wrong start time
spawn sleep 600
VICTIM="$LAST_PID"
mkdir -p "$VNC_RUNTIME_DIR"
printf '%s\n%s\n' "$VICTIM" "Mon Jan  1 00:00:00 2024" > "$PID_FILE"
out="$(bash "$LAUNCHER" --status 2>&1)"
assert_alive "recycled PID is NOT killed (start-time mismatch)" "$VICTIM"
assert_contains "PID reuse is reported explicitly" "$out" "PID reuse detected"
kill -KILL "$VICTIM" 2>/dev/null || true

# (d) identity check fails closed without GCP_INSTANCE
mkdir -p "$VNC_RUNTIME_DIR"
printf '%s\n%s\n' "1" "Mon Jan  1 00:00:00 2024" > "$PID_FILE"
out="$(GCP_INSTANCE="" bash "$LAUNCHER" --status 2>&1)"
assert_contains "identity check fails closed without GCP_INSTANCE" \
    "$out" "No active IAP tunnel found"
assert_file_absent "PID 1 reference is discarded without any signal" "$PID_FILE"

# ---------------------------------------------------------------------------
section "Startup timeout and failure cleanup"

# (a) timeout: forward never becomes ready
setup_env nobind
out="$(bash "$LAUNCHER" start 2>&1)"
rc=$?
assert_eq "start fails when the forward never opens" "$rc" "1"
assert_contains "timeout is reported clearly" "$out" "did not become ready within"
assert_file_absent "PID file is removed after a startup timeout" "$PID_FILE"
assert_eq "no tunnel process is left behind after a timeout" \
    "$(count_procs_with "$SANDBOX/bin/gcloud")" "0"

# (b) immediate failure: gcloud exits before the forward is ready
setup_env exitfail
out="$(bash "$LAUNCHER" start 2>&1)"
assert_contains "startup crash is reported clearly" "$out" "exited during startup"
assert_file_absent "PID file is removed after a startup crash" "$PID_FILE"
assert_eq "no tunnel process is left behind after a crash" \
    "$(count_procs_with "$SANDBOX/bin/gcloud")" "0"

# ---------------------------------------------------------------------------
section "Repeated execution"

setup_env bind
bash "$LAUNCHER" start >/dev/null 2>&1
FIRST_PID="$(tunnel_pid)"
bash "$LAUNCHER" start >/dev/null 2>&1
SECOND_PID="$(tunnel_pid)"
assert_eq "a second start reuses the existing tunnel" "$SECOND_PID" "$FIRST_PID"
assert_eq "exactly one tunnel process exists" \
    "$(count_procs_with "$SANDBOX/bin/gcloud")" "1"

bash "$LAUNCHER" --stop >/dev/null 2>&1
assert_dead "the single tunnel process is stopped" "$FIRST_PID"

# stop is idempotent
assert_cmd_ok "stop on an already-stopped tunnel succeeds" \
    bash "$LAUNCHER" --stop
assert_cmd_ok "a fresh start after stop succeeds again" bash "$LAUNCHER" start
bash "$LAUNCHER" --stop >/dev/null 2>&1

# ---------------------------------------------------------------------------
section "A failing GUI client does not abort the launcher"

# Some environments provide an `open` binary that rejects vnc:// URLs. A
# non-zero exit from it must not be treated as a launcher failure.
setup_env bind
printf '#!/bin/sh\nexit 3\n' > "$SANDBOX/bin/open"
chmod 755 "$SANDBOX/bin/open"

out="$(bash "$LAUNCHER" start 2>&1)"
rc=$?
assert_eq "start still succeeds when the GUI client fails" "$rc" "0"
assert_contains "the GUI failure is reported as a warning" \
    "$out" "Could not launch Screen Sharing automatically"
assert_contains "the tunnel is left running for the user" "$out" "VNC forward ready"
bash "$LAUNCHER" --stop >/dev/null 2>&1

# ---------------------------------------------------------------------------
print_summary "macbook-vnc-launcher"