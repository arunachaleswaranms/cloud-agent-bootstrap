#!/usr/bin/env bash
#
# tests/lib/harness.sh — shared helpers for the launcher regression suites.
#
# Provides assertion helpers, per-suite sandboxes, free-port allocation and
# stray-process cleanup. Every suite must run fully hermetic: no real gcloud,
# no real Java launch, no writes outside the sandbox.

T_RUN=0
T_PASSED=0
T_FAILED=0
T_FAILED_NAMES=""

SANDBOX=""
STRAY_PIDS=""
LAST_PID=""

# --- Reporting -----------------------------------------------------------------

pass() {
    T_RUN=$((T_RUN + 1))
    T_PASSED=$((T_PASSED + 1))
    printf '  [PASS] %s\n' "$1"
}

fail() {
    T_RUN=$((T_RUN + 1))
    T_FAILED=$((T_FAILED + 1))
    T_FAILED_NAMES="${T_FAILED_NAMES}    - ${1}
"
    printf '  [FAIL] %s\n' "$1"
    if [ $# -gt 1 ]; then
        printf '         %s\n' "$2"
    fi
}

skip() {
    printf '  [SKIP] %s\n' "$1"
}

section() { printf '\n== %s ==\n' "$1"; }

# --- Assertions ----------------------------------------------------------------

assert_cmd_ok() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        pass "$desc"
    else
        fail "$desc" "expected success from: $*"
    fi
}

assert_cmd_fails() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        fail "$desc" "expected failure from: $*"
    else
        pass "$desc"
    fi
}

assert_eq() {
    local desc="$1" actual="$2" expected="$3"
    if [ "$actual" = "$expected" ]; then
        pass "$desc"
    else
        fail "$desc" "expected '$expected', got '$actual'"
    fi
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    case "$haystack" in
        *"$needle"*) pass "$desc" ;;
        *) fail "$desc" "output did not contain: $needle" ;;
    esac
}

assert_not_contains() {
    local desc="$1" haystack="$2" needle="$3"
    case "$haystack" in
        *"$needle"*) fail "$desc" "output unexpectedly contained: $needle" ;;
        *) pass "$desc" ;;
    esac
}

assert_alive() {
    local desc="$1" pid="$2"
    if kill -0 "$pid" 2>/dev/null; then
        pass "$desc"
    else
        fail "$desc" "PID $pid is not running"
    fi
}

assert_dead() {
    local desc="$1" pid="$2" i=0
    while [ "$i" -lt 30 ]; do
        kill -0 "$pid" 2>/dev/null || { pass "$desc"; return 0; }
        sleep 0.2
        i=$((i + 1))
    done
    fail "$desc" "PID $pid is still running"
}

assert_file_exists() {
    local desc="$1" path="$2"
    if [ -f "$path" ]; then
        pass "$desc"
    else
        fail "$desc" "missing file: $path"
    fi
}

assert_file_absent() {
    local desc="$1" path="$2"
    if [ ! -e "$path" ]; then
        pass "$desc"
    else
        fail "$desc" "file should not exist: $path"
    fi
}

# Permission assertion in octal, e.g. assert_mode "desc" /path 700
assert_mode() {
    local desc="$1" path="$2" expected="$3" actual
    actual="$(stat -c '%a' "$path" 2>/dev/null || stat -f '%Lp' "$path" 2>/dev/null || echo '?')"
    if [ "$actual" = "$expected" ]; then
        pass "$desc"
    else
        fail "$desc" "expected mode $expected, got $actual for $path"
    fi
}

# --- Sandbox -------------------------------------------------------------------

sandbox_new() {
    SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/launcher-test.XXXXXXXX")"
    chmod 700 "$SANDBOX"
    mkdir -p "$SANDBOX/bin" "$SANDBOX/state" "$SANDBOX/burp"
}

# Register a process to be force-killed when the suite ends.
track_pid() { STRAY_PIDS="${STRAY_PIDS} $1"; }

kill_strays() {
    local pid
    for pid in $STRAY_PIDS; do
        kill -KILL "$pid" 2>/dev/null || true
    done
    STRAY_PIDS=""
}

sandbox_cleanup() {
    kill_strays
    if [ -n "$SANDBOX" ]; then
        rm -rf "$SANDBOX"
    fi
    SANDBOX=""
}

# Start a long-lived background process, register it for cleanup.
# Result is returned in the global LAST_PID.
spawn() {
    "$@" &
    LAST_PID=$!
    STRAY_PIDS="${STRAY_PIDS} ${LAST_PID}"
}

proc_start_time() {
    ps -p "$1" -o lstart= 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# Count running processes whose command line contains a literal string.
# The needle is passed through the environment rather than `awk -v`, otherwise
# the awk process matches its own command line in the ps snapshot.
count_procs_with() {
    export PROBE="$1"
    if [ "${HARNESS_DEBUG:-0}" = "1" ]; then
        echo "    [debug] processes matching '$1':" >&2
        ps -A -o pid=,ppid=,stat=,args= 2>/dev/null |
            awk 'BEGIN { n = ENVIRON["PROBE"] } index($0, n) { print "      " $0 }' >&2
    fi
    ps -A -o pid=,command= 2>/dev/null |
        awk 'BEGIN { n = ENVIRON["PROBE"] } index($0, n) { c++ } END { print c + 0 }'
}

# Find PIDs whose command line contains a literal string (one per line).
pids_with() {
    export PROBE="$1"
    ps -A -o pid=,command= 2>/dev/null |
        awk 'BEGIN { n = ENVIRON["PROBE"] } index($0, n) { print $1 }'
}

free_port() {
    python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

port_open() {
    python3 - "$1" <<'PY' >/dev/null 2>&1
import socket, sys
s = socket.socket()
s.settimeout(1)
try:
    s.connect(("127.0.0.1", int(sys.argv[1])))
except OSError:
    sys.exit(1)
finally:
    s.close()
sys.exit(0)
PY
}

wait_for_port() {
    local port="$1" i=0
    while [ "$i" -lt 40 ]; do
        port_open "$port" && return 0
        sleep 0.25
        i=$((i + 1))
    done
    return 1
}

# --- Summary -------------------------------------------------------------------

print_summary() {
    printf '\n%s: %d run, %d passed, %d failed\n' \
        "${1:-suite}" "$T_RUN" "$T_PASSED" "$T_FAILED"
    if [ "$T_FAILED" -gt 0 ]; then
        printf 'Failures:%s\n' "$T_FAILED_NAMES"
        return 1
    fi
    return 0
}