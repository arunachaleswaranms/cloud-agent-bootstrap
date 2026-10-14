#!/usr/bin/env bash
#
# start-burp.sh — idempotent Burp Suite launcher for the cloud agent VM.
#
# - Detects an existing Burp instance (avoids duplicates)
# - Verifies Java runtime and XFCE display :1
# - Starts Burp in the background with logs in a private runtime directory
# - Returns a useful error if a prerequisite is missing
#
# Usage:
#   scripts/start-burp.sh            # start Burp (or report already running)
#   scripts/start-burp.sh --status   # check status only, do not launch
#   scripts/start-burp.sh --stop     # stop the running instance
#
# Environment overrides:
#   BURP_JAR       path to burpsuite_desktop_v*.jar
#   BURP_JAVA      path to java binary (default: prefer Java 25)
#   BURP_DISPLAY   X display to use (default: :1)
#   BURP_XMX       heap size (default: 3g)
#   BURP_LOG_DIR   runtime log directory (default: ~/.local/state/burp)

set -euo pipefail

BURP_HOME="${BURP_HOME:-$HOME/tools/burp}"
BURP_JAR="${BURP_JAR:-$BURP_HOME/burpsuite_desktop_v2026.9.1.jar}"
BURP_DISPLAY="${BURP_DISPLAY:-:1}"
BURP_XMX="${BURP_XMX:-3g}"
BURP_LOG_DIR="${BURP_LOG_DIR:-$HOME/.local/state/burp}"
BURP_PID_FILE="$BURP_LOG_DIR/burp.pid"

log()  { echo "[+] $*"; }
warn() { echo "[!] $*" >&2; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

# --- 1. Resolve Java (prefer verified Java 25) --------------------------------
resolve_java() {
    if [ -n "${BURP_JAVA:-}" ] && [ -x "${BURP_JAVA:-}" ]; then
        echo "$BURP_JAVA"
        return 0
    fi
    # Prefer Java 25 (validated runtime)
    for candidate in \
        /usr/lib/jvm/java-25-openjdk-amd64/bin/java \
        "$(command -v java 2>/dev/null || true)"
    do
        if [ -n "$candidate" ] && [ -x "$candidate" ]; then
            local ver
            ver="$("$candidate" -version 2>&1 | head -1 | sed 's/.*version "\([^"]*\)".*/\1/')"
            case "$ver" in
                25.*) echo "$candidate"; return 0 ;;
            esac
        fi
    done
    # Fall back to any available Java
    if command -v java >/dev/null 2>&1; then
        command -v java
        return 0
    fi
    return 1
}

# --- 2. Verify a PID is actually our Burp process -----------------------------
is_our_burp() {
    local pid="$1"
    kill -0 "$pid" 2>/dev/null || return 1
    # Verify the process command line matches our Burp JAR
    local cmdline
    cmdline="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    [ -n "$cmdline" ] || return 1
    # Check that the JAR path in the process matches our configured JAR
    echo "$cmdline" | grep -qF "$BURP_JAR" && return 0
    # Also accept the generic pattern for the versioned JAR
    echo "$cmdline" | grep -q "burpsuite_desktop_v.*\.jar" && return 0
    return 1
}

# --- 3. Check for existing instance -------------------------------------------
existing_pid() {
    # Check PID file first
    if [ -f "$BURP_PID_FILE" ]; then
        local pid
        pid="$(cat "$BURP_PID_FILE" 2>/dev/null || true)"
        if [ -n "$pid" ] && is_our_burp "$pid"; then
            echo "$pid"
            return 0
        fi
        # Stale PID file — the process isn't our Burp (or doesn't exist)
        # Do NOT kill it; just clean up our own bookkeeping
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            warn "PID file references PID $pid but it is not our Burp process — ignoring"
        fi
        rm -f "$BURP_PID_FILE"
    fi
    # Fallback: scan process table for the Burp jar
    local found
    found="$(pgrep -f "burpsuite_desktop_v.*\.jar" 2>/dev/null | head -1 || true)"
    if [ -n "$found" ]; then
        echo "$found"
        return 0
    fi
    return 1
}

# --- 4. Verify prerequisites --------------------------------------------------
check_prereqs() {
    local missing=0

    if [ ! -f "$BURP_JAR" ]; then
        warn "Burp JAR not found: $BURP_JAR"
        missing=1
    fi

    local java_bin
    if ! java_bin="$(resolve_java)"; then
        warn "Java runtime not found. Install OpenJDK 25: sudo apt install openjdk-25-jre"
        missing=1
    else
        local jver
        jver="$("$java_bin" -version 2>&1 | head -1)"
        local ver_num
        ver_num="$(echo "$jver" | sed 's/.*version "\([^"]*\)".*/\1/' | cut -d. -f1)"
        if [ "$ver_num" -ge 17 ] 2>/dev/null; then
            log "Java: $jver"
            BURP_JAVA="$java_bin"
        else
            warn "Java $ver_num too old; Burp requires Java 17+ (validated: 25)"
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

# --- 5. Status command --------------------------------------------------------
cmd_status() {
    local pid
    if pid="$(existing_pid)"; then
        log "Burp is running (PID $pid)"
        log "  JAR:    $BURP_JAR"
        log "  Log:    $BURP_LOG_DIR/burp.log"
        log "  Proxy:  127.0.0.1:8080"
        log "  MCP:    127.0.0.1:9876 (official) / 127.0.0.1:9877 (extended)"
        return 0
    else
        warn "Burp is not running"
        return 1
    fi
}

# --- 6. Stop command ----------------------------------------------------------
cmd_stop() {
    local pid
    if ! pid="$(existing_pid)"; then
        warn "No running Burp instance found"
        return 0
    fi

    # Extra safety: verify one more time before killing
    if ! is_our_burp "$pid"; then
        die "Refusing to kill PID $pid — process identity mismatch"
    fi

    log "Stopping Burp (PID $pid)..."
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 15); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
    done
    if kill -0 "$pid" 2>/dev/null; then
        warn "Burp did not exit gracefully; sending SIGKILL"
        kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$BURP_PID_FILE"
    log "Burp stopped"
}

# --- 7. Start command ---------------------------------------------------------
cmd_start() {
    local pid
    if pid="$(existing_pid)"; then
        log "Burp is already running (PID $pid) — not starting a duplicate"
        cmd_status
        return 0
    fi

    check_prereqs

    mkdir -p "$BURP_LOG_DIR"
    chmod 700 "$BURP_LOG_DIR"

    local logfile="$BURP_LOG_DIR/burp.log"
    log "Starting Burp Suite..."
    log "  JAR:    $BURP_JAR"
    log "  Java:   $BURP_JAVA"
    log "  Heap:   $BURP_XMX"
    log "  Display: $BURP_DISPLAY"
    log "  Log:    $logfile"

    DISPLAY="$BURP_DISPLAY" \
    nohup "$BURP_JAVA" -Xmx"$BURP_XMX" -jar "$BURP_JAR" \
        >"$logfile" 2>&1 &

    local new_pid=$!
    echo "$new_pid" > "$BURP_PID_FILE"
    chmod 600 "$BURP_PID_FILE"

    log "Burp launched (PID $new_pid). Waiting for proxy port 8080..."

    local waited=0
    while [ "$waited" -lt 60 ]; do
        if ! kill -0 "$new_pid" 2>/dev/null; then
            # Process died — clean up PID file and report
            rm -f "$BURP_PID_FILE"
            die "Burp process exited during startup. Check log: $logfile"
        fi
        if ss -tlnH 2>/dev/null | grep -qE "(127\.0\.0\.1|\[::ffff:127\.0\.0\.1\]):8080\b"; then
            log "Burp proxy is listening on 127.0.0.1:8080"
            log "Burp is ready. Connect via VNC (display :1) or IAP SSH tunnel."
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done

    warn "Burp started but port 8080 not detected within 60s"
    warn "Check log: $logfile"
    return 1
}

# --- Main ---------------------------------------------------------------------
case "${1:-start}" in
    start)      cmd_start  ;;
    status|--status) cmd_status ;;
    stop|--stop)     cmd_stop   ;;
    -h|--help|help)
        grep '^#' "$0" | sed 's/^# \{0,1\}//'
        ;;
    *)
        die "Unknown option: $1 (use: start | status | stop)"
        ;;
esac
