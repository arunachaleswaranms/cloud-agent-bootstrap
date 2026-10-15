#!/usr/bin/env bash
#
# start-burp.sh — idempotent Burp Suite launcher for the cloud agent VM.
#
# - Detects an existing Burp instance without scanning for arbitrary processes
# - Verifies Java runtime and XFCE display :1
# - Starts Burp in the background with logs in a private runtime directory
# - Returns a useful error if a prerequisite is missing
#
# Process-safety contract:
#   * A Burp process is identified by the EXACT configured JAR path plus a
#     uid match. There is no generic `pgrep -f` matching and no regex on
#     `burpsuite_desktop_v*.jar`.
#   * Unrelated Java processes — other JVMs, other apps, a different Burp
#     build — are never matched and therefore never signalled.
#   * Ownership is re-verified immediately before every termination signal,
#     so a PID recycled between check and kill is not hit.
#   * Stale PID files are removed but never acted on.
#   * Burp's own proxy/MCP settings (127.0.0.1:8080, 9876, 9877) are not touched.
#
# Usage:
#   scripts/start-burp.sh            # start Burp (or report already running)
#   scripts/start-burp.sh --status   # check status only, do not launch
#   scripts/start-burp.sh --stop     # stop the running instance
#
# Environment overrides:
#   BURP_JAR            path to burpsuite_desktop_v*.jar
#   BURP_JAVA           path to java binary (default: prefer Java 25)
#   BURP_DISPLAY        X display to use (default: :1)
#   BURP_XMX            heap size (default: 3g)
#   BURP_LOG_DIR        runtime log directory (default: ~/.local/state/burp)
#   BURP_READY_TIMEOUT  seconds to wait for the proxy port (default 60)

set -euo pipefail
umask 077

BURP_HOME="${BURP_HOME:-$HOME/tools/burp}"
BURP_JAR="${BURP_JAR:-$BURP_HOME/burpsuite_desktop_v2026.9.1.jar}"
BURP_DISPLAY="${BURP_DISPLAY:-:1}"
BURP_XMX="${BURP_XMX:-3g}"
BURP_LOG_DIR="${BURP_LOG_DIR:-$HOME/.local/state/burp}"
BURP_READY_TIMEOUT="${BURP_READY_TIMEOUT:-60}"
BURP_PID_FILE="$BURP_LOG_DIR/burp.pid"
BURP_PROXY_PORT="${BURP_PROXY_PORT:-8080}"

log()  { echo "[+] $*"; }
warn() { echo "[!] $*" >&2; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

LAUNCHED_PID=""

# --- Portable helpers ----------------------------------------------------------

_path_owner_uid() {
    stat -c '%u' "$1" 2>/dev/null || stat -f '%u' "$1" 2>/dev/null || echo ""
}

_uid() { id -u; }

_proc_alive() { kill -0 "$1" 2>/dev/null; }

_proc_uid() { ps -p "$1" -o uid= 2>/dev/null | tr -d '[:space:]' || true; }

_proc_cmdline() { ps -p "$1" -o command= 2>/dev/null || true; }

_proc_start_time() {
    ps -p "$1" -o lstart= 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' || true
}

_is_uint() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

# Split a "<pid> <start time>" record. The start time contains spaces, so it
# must be taken as the remainder of the string, not via positional parameters.
_record_pid()   { printf '%s\n' "${1%% *}"; }
_record_start() { printf '%s\n' "${1#* }"; }

_contains() {
    local haystack="$1" needle="$2"
    [ -n "$needle" ] || return 1
    case "$haystack" in
        *"$needle"*) return 0 ;;
    esac
    return 1
}

# --- 1. Resolve Java (prefer the validated Java 25 runtime) --------------------
resolve_java() {
    if [ -n "${BURP_JAVA:-}" ] && [ -x "${BURP_JAVA:-}" ]; then
        printf '%s\n' "$BURP_JAVA"
        return 0
    fi
    local candidate ver
    for candidate in \
        /usr/lib/jvm/java-25-openjdk-amd64/bin/java \
        "$(command -v java 2>/dev/null || true)"
    do
        if [ -n "$candidate" ] && [ -x "$candidate" ]; then
            ver="$("$candidate" -version 2>&1 | head -1 |
                sed 's/.*version "\([^"]*\)".*/\1/')"
            case "$ver" in
                25.*) printf '%s\n' "$candidate"; return 0 ;;
            esac
        fi
    done
    if command -v java >/dev/null 2>&1; then
        command -v java
        return 0
    fi
    return 1
}

# --- 2. Process identity -------------------------------------------------------
# True when the command line contains $BURP_JAR as a complete argument token.
# Requiring a whole token means /opt/burpsuite_desktop_v2026.9.1.jar does not
# match a configured /home/me/burpsuite_desktop_v2026.9.1.jar.
_cmdline_has_jar_token() {
    local cmdline="$1" jar="$2" tok
    _contains "$cmdline" "$jar" || return 1
    # shellcheck disable=SC2086  # word splitting is intentional here
    for tok in $cmdline; do
        if [ "$tok" = "$jar" ]; then
            return 0
        fi
    done
    return 1
}

# True when $1 is the Burp instance for the exact configured JAR.
is_our_burp() {
    local pid="$1"
    local expect_start="${2:-}"

    _is_uint "$pid" || return 1
    [ "$pid" -gt 1 ] || return 1
    _proc_alive "$pid" || return 1

    # Ownership — never consider another user's process.
    local owner
    owner="$(_proc_uid "$pid")"
    [ -n "$owner" ] || return 1
    [ "$owner" = "$(_uid)" ] || return 1

    # Start-time match defeats PID reuse.
    if [ -n "$expect_start" ]; then
        local actual_start
        actual_start="$(_proc_start_time "$pid")"
        [ "$actual_start" = "$expect_start" ] || return 1
    fi

    [ -n "$BURP_JAR" ] || return 1
    local cmdline
    cmdline="$(_proc_cmdline "$pid")"
    [ -n "$cmdline" ] || return 1
    _cmdline_has_jar_token "$cmdline" "$BURP_JAR" || return 1

    # Must be a JVM, not an editor that happens to mention the path.
    _contains "$cmdline" "java" || return 1
    return 0
}

# Re-verify identity, then signal. Returns non-zero if the guard tripped.
_verified_signal() {
    local pid="$1" sig="$2" expect_start="${3:-}"
    if ! is_our_burp "$pid" "$expect_start"; then
        warn "Refusing to signal PID $pid — identity re-check failed"
        return 1
    fi
    kill "-$sig" "$pid" 2>/dev/null || return 1
    return 0
}

# --- 3. Locate the running instance -------------------------------------------
# Exact-JAR scan. This is deliberately NOT `pgrep -f burpsuite_desktop_v.*\.jar`:
# it matches one literal path, and every candidate is then uid- and
# token-verified by is_our_burp. Unrelated JVMs and other Burp builds never match.
_scan_our_burp_pids() {
    local pid cmdline found="" jar
    jar="$BURP_JAR"
    # Cheap literal pre-filter first; only real candidates pay for the
    # uid / token / start-time verification inside is_our_burp.
    while read -r pid cmdline; do
        [ -n "$pid" ] || continue
        case "$cmdline" in
            *"$jar"*) ;;
            *) continue ;;
        esac
        if is_our_burp "$pid"; then
            found="$found $pid"
        fi
    done <<EOF
$(ps -A -o pid=,command= 2>/dev/null)
EOF
    printf '%s\n' "$found" | tr ' ' '\n' | sed '/^$/d'
}

# Echoes "<pid> <start_time>" for the running Burp, or fails.
existing_pid() {
    local pid start_time

    if [ -f "$BURP_PID_FILE" ]; then
        pid="$(sed -n '1p' "$BURP_PID_FILE" 2>/dev/null || true)"
        start_time="$(sed -n '2p' "$BURP_PID_FILE" 2>/dev/null || true)"
        if _is_uint "$pid" && is_our_burp "$pid" "$start_time"; then
            printf '%s %s\n' "$pid" "$start_time"
            return 0
        fi
        if [ -z "$pid" ] || ! _is_uint "$pid"; then
            warn "PID file empty or malformed; removing it"
        elif ! _proc_alive "$pid"; then
            warn "Stale PID file (PID $pid no longer exists); removing it"
        elif [ -n "$start_time" ] && [ "$(_proc_start_time "$pid")" != "$start_time" ]; then
            warn "PID reuse detected: PID $pid is live but is not the recorded process; removing PID file"
        elif ! is_our_burp "$pid"; then
            warn "PID $pid is not Burp for $BURP_JAR; leaving that process alone"
        else
            warn "PID $pid failed start-time verification; treating as stale"
        fi
        # Bookkeeping cleanup only. We never signal a PID we did not verify.
        rm -f "$BURP_PID_FILE"
    fi

    # Fall back to the exact-JAR scan so a lost PID file cannot cause a
    # duplicate instance.
    local candidate
    for candidate in $(_scan_our_burp_pids); do
        printf '%s %s\n' "$candidate" "$(_proc_start_time "$candidate")"
        return 0
    done
    return 1
}

# --- 4. Prerequisites ----------------------------------------------------------
check_prereqs() {
    local missing=0 java_bin jver ver_num

    if [ ! -f "$BURP_JAR" ]; then
        warn "Burp JAR not found: $BURP_JAR"
        missing=1
    fi

    if ! java_bin="$(resolve_java)"; then
        warn "Java runtime not found. Install OpenJDK 25: sudo apt install openjdk-25-jre"
        missing=1
    else
        jver="$("$java_bin" -version 2>&1 | head -1)"
        ver_num="$(printf '%s\n' "$jver" | sed 's/.*version "\([^"]*\)".*/\1/' | cut -d. -f1)"
        if [ -n "$ver_num" ] && [ "$ver_num" -ge 17 ] 2>/dev/null; then
            log "Java: $jver"
            BURP_JAVA="$java_bin"
        else
            warn "Java ${ver_num:-unknown} too old; Burp requires Java 17+ (validated: 25)"
            missing=1
        fi
    fi

    if ! DISPLAY="$BURP_DISPLAY" xdpyinfo >/dev/null 2>&1; then
        warn "X display $BURP_DISPLAY not reachable (is TigerVNC running?)"
        missing=1
    else
        log "X display $BURP_DISPLAY: OK"
    fi

    [ "$missing" -eq 0 ] || die "Prerequisite check failed. Fix the warnings above and retry."
}

# --- 5. Status -----------------------------------------------------------------
cmd_status() {
    local entry pid start_time
    if entry="$(existing_pid)"; then
        pid="$(_record_pid "$entry")"
        start_time="$(_record_start "$entry")"
        log "Burp is running (PID $pid)"
        log "  JAR:      $BURP_JAR"
        log "  Started:  ${start_time:-unknown}"
        log "  Log:      $BURP_LOG_DIR/burp.log"
        log "  Proxy:    127.0.0.1:${BURP_PROXY_PORT}"
        log "  MCP:      127.0.0.1:9876 (official) / 127.0.0.1:9877 (extended)"
        return 0
    fi
    warn "Burp is not running"
    return 1
}

# --- 6. Stop -------------------------------------------------------------------
cmd_stop() {
    local entry pid start_time i
    if ! entry="$(existing_pid)"; then
        log "No running Burp instance found"
        return 0
    fi
    pid="$(_record_pid "$entry")"
    start_time="$(_record_start "$entry")"

    log "Stopping Burp (PID $pid)..."
    if ! _verified_signal "$pid" TERM "$start_time"; then
        die "Refusing to stop PID $pid — process identity mismatch"
    fi

    i=0
    while [ "$i" -lt 15 ]; do
        _proc_alive "$pid" || break
        i=$((i + 1))
        sleep 1
    done

    if _proc_alive "$pid"; then
        warn "Burp did not exit on SIGTERM; escalating to SIGKILL"
        # Identity is re-verified inside _verified_signal, so a PID recycled
        # during the grace period is not hit.
        if ! _verified_signal "$pid" KILL "$start_time"; then
            warn "PID $pid no longer verified; not sending SIGKILL"
            rm -f "$BURP_PID_FILE"
            return 1
        fi
        i=0
        while [ "$i" -lt 5 ]; do
            _proc_alive "$pid" || break
            i=$((i + 1))
            sleep 1
        done
    fi

    rm -f "$BURP_PID_FILE"
    log "Burp stopped"
    return 0
}

# --- 7. Start ------------------------------------------------------------------
_port_listening() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -tlnH 2>/dev/null |
            awk -v p=":${port}\$" '$4 ~ p { found = 1 } END { exit(found ? 0 : 1) }'
        return $?
    fi
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$port" <<'PY' >/dev/null 2>&1
import socket, sys
port = int(sys.argv[1])
for family, addr in ((socket.AF_INET, "127.0.0.1"), (socket.AF_INET6, "::1")):
    s = socket.socket(family, socket.SOCK_STREAM)
    s.settimeout(1)
    try:
        s.connect((addr, port))
    except OSError:
        continue
    finally:
        s.close()
    sys.exit(0)
sys.exit(1)
PY
        return $?
    fi
    return 1
}

_on_exit() {
    local rc=$?
    if [ -n "$LAUNCHED_PID" ] && is_our_burp "$LAUNCHED_PID"; then
        warn "Cleaning up Burp instance started by this invocation (PID $LAUNCHED_PID)"
        _verified_signal "$LAUNCHED_PID" TERM || true
        rm -f "$BURP_PID_FILE"
    fi
    exit "$rc"
}

cmd_start() {
    local entry pid start_time

    if entry="$(existing_pid)"; then
        pid="$(_record_pid "$entry")"
        log "Burp is already running (PID $pid) — not starting a duplicate"
        cmd_status || true
        return 0
    fi

    check_prereqs

    if [ -L "$BURP_LOG_DIR" ] || { [ -e "$BURP_LOG_DIR" ] && [ ! -d "$BURP_LOG_DIR" ]; }; then
        die "BURP_LOG_DIR is not a usable directory: $BURP_LOG_DIR"
    fi
    mkdir -p "$BURP_LOG_DIR" || die "Could not create $BURP_LOG_DIR"
    local dir_owner
    dir_owner="$(_path_owner_uid "$BURP_LOG_DIR")"
    if [ -z "$dir_owner" ] || [ "$dir_owner" != "$(_uid)" ]; then
        die "BURP_LOG_DIR is not owned by the current user: $BURP_LOG_DIR"
    fi
    chmod 700 "$BURP_LOG_DIR" || die "Could not restrict permissions on $BURP_LOG_DIR"

    local logfile="$BURP_LOG_DIR/burp.log"
    log "Starting Burp Suite..."
    log "  JAR:     $BURP_JAR"
    log "  Java:    $BURP_JAVA"
    log "  Heap:    $BURP_XMX"
    log "  Display: $BURP_DISPLAY"
    log "  Log:     $logfile"

    DISPLAY="$BURP_DISPLAY" \
    nohup "$BURP_JAVA" -Xmx"$BURP_XMX" -jar "$BURP_JAR" \
        >"$logfile" 2>&1 &

    LAUNCHED_PID=$!
    {
        umask 077
        printf '%s\n%s\n' "$LAUNCHED_PID" "$(_proc_start_time "$LAUNCHED_PID")" \
            >"$BURP_PID_FILE.tmp.$$"
    }
    chmod 600 "$BURP_PID_FILE.tmp.$$"
    mv -f "$BURP_PID_FILE.tmp.$$" "$BURP_PID_FILE"

    # From here on the exit trap cleans up anything we started but could not
    # hand over successfully.
    trap _on_exit EXIT
    trap 'warn "Interrupted"; exit 130' INT
    trap 'warn "Terminated"; exit 143' TERM

    log "Burp launched (PID $LAUNCHED_PID). Waiting for proxy port ${BURP_PROXY_PORT}..."

    local waited=0
    while [ "$waited" -lt "$BURP_READY_TIMEOUT" ]; do
        if ! _proc_alive "$LAUNCHED_PID"; then
            die "Burp process exited during startup. Check log: $logfile"
        fi
        if _port_listening "$BURP_PROXY_PORT"; then
            LAUNCHED_PID=""
            log "Burp proxy is listening on 127.0.0.1:${BURP_PROXY_PORT}"
            log "Burp is ready. Connect via VNC (display :1) or IAP SSH tunnel."
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done

    die "Burp started but port ${BURP_PROXY_PORT} was not detected within ${BURP_READY_TIMEOUT}s. Check log: $logfile"
}

# --- Main ----------------------------------------------------------------------
case "${1:-start}" in
    start)         cmd_start ;;
    status|--status) cmd_status ;;
    stop|--stop)   cmd_stop ;;
    -h|--help|help)
        grep '^#' "$0" | sed 's/^# \{0,1\}//'
        ;;
    *)
        die "Unknown option: $1 (use: start | status | stop)"
        ;;
esac