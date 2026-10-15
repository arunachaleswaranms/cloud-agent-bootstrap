#!/usr/bin/env bash
#
# tests/test-start-burp.sh — regression tests for scripts/start-burp.sh
#
# Covers: exact-JAR process identity, ownership checks, stale PID files,
#        PID reuse, unrelated Java processes, duplicate startup prevention,
#        safe stop, prerequisite handling and Java 25 preference.
#
# Fully hermetic: a fake `java` and a fake `xdpyinfo` stand in for the real
# ones, the JAR is a sandbox placeholder, and BURP_LOG_DIR is sandboxed. The
# suite never touches a real Burp installation, its runtime directory, or a
# live Burp process.

set -uo pipefail

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SUITE_DIR/.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SUITE_DIR/lib/harness.sh"

SCRIPT="$REPO_ROOT/scripts/start-burp.sh"

trap sandbox_cleanup EXIT

write_fake_java() {
    local dest="$1"
    cat > "$dest" <<'FAKE'
#!/usr/bin/env bash
# Fake JVM for regression tests.
if [ "${1:-}" = "-version" ]; then
    echo 'openjdk version "25.0.1" 2025-01-21' >&2
    exit 0
fi
# Stand in for Burp's proxy listener, but only for the configured JAR so that
# unrelated JVMs spawned by the tests do not contend for the port.
listener=""
for a in "$@"; do
    case "$a" in
        */burpsuite_desktop_v9999.9.9.jar)
            python3 -c '
import socket, sys, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1])))
s.listen(5)
time.sleep(600)
' "$FAKE_PROXY_PORT" &
            listener=$!
            ;;
    esac
done
sleep 600 &
child=$!
cleanup() { [ -n "$listener" ] && kill "$listener" 2>/dev/null; kill "$child" 2>/dev/null || true; }
trap cleanup EXIT INT TERM
wait
FAKE
    chmod 755 "$dest"
}

write_fake_xdpyinfo() {
    cat > "$1" <<'FAKE'
#!/usr/bin/env bash
[ "${FAKE_XDPYINFO_FAIL:-0}" = "1" ] && exit 1
exit 0
FAKE
    chmod 755 "$1"
}

setup_env() {
    sandbox_new
    export FAKE_PROXY_PORT
    FAKE_PROXY_PORT="$(free_port)"
    export FAKE_XDPYINFO_FAIL="${FAKE_XDPYINFO_FAIL:-0}"

    export BURP_JAR="$SANDBOX/burp/burpsuite_desktop_v9999.9.9.jar"
    : > "$BURP_JAR"
    export BURP_JAVA="$SANDBOX/bin/fakejava"
    write_fake_java "$BURP_JAVA"
    write_fake_xdpyinfo "$SANDBOX/bin/xdpyinfo"
    export PATH="$SANDBOX/bin:$PATH"

    export BURP_LOG_DIR="$SANDBOX/state/burp"
    export BURP_PROXY_PORT="$FAKE_PROXY_PORT"
    export BURP_READY_TIMEOUT="8"
    export BURP_DISPLAY=":99"
    PID_FILE="$BURP_LOG_DIR/burp.pid"
}

burp_pid()  { sed -n '1p' "$PID_FILE" 2>/dev/null || true; }
burp_start() { sed -n '2p' "$PID_FILE" 2>/dev/null || true; }

# ---------------------------------------------------------------------------
section "Static safety properties"

setup_env
script_src="$(cat "$SCRIPT")"
script_code="$(grep -v '^[[:space:]]*#' "$SCRIPT")"

assert_not_contains "no generic pgrep -f matching" "$script_code" "pgrep -f"
assert_not_contains "no loose versioned-jar regex" "$script_code" "burpsuite_desktop_v.*"
assert_not_contains "no shared /tmp PID path" "$script_src" "/tmp/burp.pid"
assert_contains "default proxy port is 8080" "$script_code" 'BURP_PROXY_PORT:-8080'
assert_contains "validated Java 25 runtime is preferred" \
    "$script_code" "java-25-openjdk-amd64"

# ---------------------------------------------------------------------------
section "Startup and runtime state"

out="$(bash "$SCRIPT" start 2>&1)"
rc=$?
assert_eq "start succeeds" "$rc" "0"
assert_file_exists "PID file is created" "$PID_FILE"
assert_mode "runtime directory is 0700" "$BURP_LOG_DIR" "700"
assert_mode "PID file is 0600" "$PID_FILE" "600"
assert_eq "PID file records a two-line identity token" \
    "$(wc -l < "$PID_FILE" | tr -d ' ')" "2"

BPID="$(burp_pid)"
assert_alive "Burp process is running" "$BPID"
assert_eq "recorded start time matches the live process" \
    "$(burp_start)" "$(proc_start_time "$BPID")"

out="$(bash "$SCRIPT" --status 2>&1)"
assert_contains "status reports Burp as running" "$out" "Burp is running"
assert_contains "status preserves the official MCP port" "$out" "127.0.0.1:9876"
assert_contains "status preserves the extended MCP port" "$out" "127.0.0.1:9877"

# ---------------------------------------------------------------------------
section "Duplicate startup is prevented"

out="$(bash "$SCRIPT" start 2>&1)"
assert_contains "a second start reports the existing instance" \
    "$out" "not starting a duplicate"
assert_eq "the recorded PID is unchanged" "$(burp_pid)" "$BPID"
assert_eq "exactly one Burp JVM exists" \
    "$(count_procs_with "$SANDBOX/bin/fakejava")" "1"

# ---------------------------------------------------------------------------
section "Unrelated Java processes are never matched or signalled"

# A JVM running a completely different application.
spawn "$SANDBOX/bin/fakejava" -Xmx1g -jar /opt/some-other-app.jar
OTHER="$LAST_PID"
sleep 1
assert_alive "unrelated JVM is running" "$OTHER"

out="$(bash "$SCRIPT" --status 2>&1)"
assert_contains "status reports our instance, not the unrelated JVM" "$out" "$BPID"
assert_alive "unrelated JVM survives a status check" "$OTHER"

bash "$SCRIPT" --stop >/dev/null 2>&1
assert_dead "our Burp is stopped" "$BPID"
assert_alive "unrelated JVM is NOT signalled by stop" "$OTHER"
kill -KILL "$OTHER" 2>/dev/null || true

# ---------------------------------------------------------------------------
section "Wrong JAR is not matched"

setup_env
OTHER_JAR="$SANDBOX/burp/burpsuite_desktop_v1111.1.1.jar"
: > "$OTHER_JAR"
spawn "$SANDBOX/bin/fakejava" -Xmx3g -jar "$OTHER_JAR"
OTHER_PID="$LAST_PID"
sleep 1

out="$(bash "$SCRIPT" --status 2>&1)"
assert_contains "status does not adopt a different Burp build" \
    "$out" "Burp is not running"
assert_alive "different-jar JVM survives the status check" "$OTHER_PID"

bash "$SCRIPT" --stop >/dev/null 2>&1
assert_alive "stop does not touch a different Burp build" "$OTHER_PID"
kill -KILL "$OTHER_PID" 2>/dev/null || true

# A path that merely *contains* our configured JAR must not match either.
setup_env
mkdir -p "$SANDBOX/prefix"
PREFIX_JAR="$SANDBOX/prefix/${BURP_JAR##*/}"
: > "$PREFIX_JAR"
spawn "$SANDBOX/bin/fakejava" -Xmx3g -jar "$PREFIX_JAR"
PREFIX_PID="$LAST_PID"
sleep 1
out="$(bash "$SCRIPT" --status 2>&1)"
assert_contains "a longer path sharing the JAR filename is not matched" \
    "$out" "Burp is not running"
assert_alive "prefixed-path JVM survives" "$PREFIX_PID"
kill -KILL "$PREFIX_PID" 2>/dev/null || true

# ---------------------------------------------------------------------------
section "Stale PID files and PID reuse"

setup_env
bash "$SCRIPT" start >/dev/null 2>&1
BPID="$(burp_pid)"
bash "$SCRIPT" --stop >/dev/null 2>&1

# (a) PID file pointing at a dead process
mkdir -p "$BURP_LOG_DIR"
printf '%s\n%s\n' "999999" "Mon Jan  1 00:00:00 2024" > "$PID_FILE"
out="$(bash "$SCRIPT" --status 2>&1)"
assert_contains "stale PID file is reported" "$out" "Stale PID file"
assert_file_absent "stale PID file is cleaned up" "$PID_FILE"

# (b) PID file pointing at a live unrelated process, correct start time
spawn "$SANDBOX/bin/fakejava" -Xmx1g -jar /opt/other-app.jar
VICTIM="$LAST_PID"
sleep 1
mkdir -p "$BURP_LOG_DIR"
printf '%s\n%s\n' "$VICTIM" "$(proc_start_time "$VICTIM")" > "$PID_FILE"
out="$(bash "$SCRIPT" --stop 2>&1)"
assert_alive "live process with a non-matching identity is NOT killed" "$VICTIM"
assert_contains "identity mismatch is reported" "$out" "not Burp for"
assert_file_absent "bogus PID file is removed" "$PID_FILE"
kill -KILL "$VICTIM" 2>/dev/null || true

# (c) PID reuse: correct PID, wrong start time
bash "$SCRIPT" start >/dev/null 2>&1
BPID="$(burp_pid)"
mkdir -p "$BURP_LOG_DIR"
printf '%s\n%s\n' "$BPID" "Mon Jan  1 00:00:00 2024" > "$PID_FILE"
out="$(bash "$SCRIPT" --status 2>&1)"
assert_contains "PID reuse is reported explicitly" "$out" "PID reuse detected"
kill -KILL "$BPID" 2>/dev/null || true
assert_eq "no Burp JVM is left behind" \
    "$(count_procs_with "$SANDBOX/bin/fakejava")" "0"

# ---------------------------------------------------------------------------
section "Safe stop behaviour"

setup_env
bash "$SCRIPT" start >/dev/null 2>&1
BPID="$(burp_pid)"
out="$(bash "$SCRIPT" --stop 2>&1)"
assert_contains "stop reports success" "$out" "Burp stopped"
assert_dead "Burp process is terminated" "$BPID"
assert_file_absent "PID file is removed after stop" "$PID_FILE"

out="$(bash "$SCRIPT" --stop 2>&1)"
assert_eq "stop on an already-stopped instance succeeds" "$?" "0"
assert_contains "stop on a stopped instance is explicit" \
    "$out" "No running Burp instance found"

# ---------------------------------------------------------------------------
section "Prerequisite handling"

setup_env
rm -f "$BURP_JAR"
out="$(bash "$SCRIPT" start 2>&1)"
rc=$?
assert_eq "start fails when the JAR is missing" "$rc" "1"
assert_contains "missing JAR produces a clear message" "$out" "Burp JAR not found"
assert_eq "no JVM is launched when prerequisites fail" \
    "$(count_procs_with "$SANDBOX/bin/fakejava")" "0"

setup_env
FAKE_XDPYINFO_FAIL=1 out="$(bash "$SCRIPT" start 2>&1)"
assert_contains "unreachable display produces a clear message" \
    "$out" "X display :99 not reachable"
assert_eq "no JVM is launched when the display is down" \
    "$(count_procs_with "$SANDBOX/bin/fakejava")" "0"

# ---------------------------------------------------------------------------
section "Java runtime selection"

setup_env
out="$(bash "$SCRIPT" start 2>&1)"
assert_contains "the configured Java 25 runtime is reported" "$out" "version \"25.0.1\""
bash "$SCRIPT" --stop >/dev/null 2>&1

# ---------------------------------------------------------------------------
section "CLI contract"

setup_env
out="$(bash "$SCRIPT" --help 2>&1)"
assert_contains "help documents usage" "$out" "idempotent Burp Suite launcher"
assert_cmd_fails "an unknown option is rejected" bash "$SCRIPT" --bogus-option

# ---------------------------------------------------------------------------
print_summary "start-burp"