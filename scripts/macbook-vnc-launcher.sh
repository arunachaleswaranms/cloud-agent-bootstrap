#!/usr/bin/env bash
#
# macbook-vnc-launcher.sh — reconnect to the agent VM's XFCE desktop from macOS.
#
# Establishes a single-hop Google Cloud IAP SSH tunnel with VNC port
# forwarding, then opens macOS Screen Sharing to the local endpoint.
#
# Prerequisites (on the Mac):
# - Google Cloud SDK (gcloud) authenticated
# - macOS Screen Sharing (built-in)
#
# Configuration (edit these or export before running):
#   GCP_PROJECT         GCP project ID
#   GCP_ZONE            VM zone (e.g. us-central1-a)
#   GCP_INSTANCE        VM instance name
#   LOCAL_VNC_PORT      local port for VNC forward (default 5901)
#   VNC_RUNTIME_DIR     private per-user runtime dir for the PID file
#                        (default: ~/.local/state/vnc-tunnel)
#   TUNNEL_READY_TIMEOUT seconds to wait for the forward (default 30)
#
# Usage:
#   scripts/macbook-vnc-launcher.sh            # start tunnel + open Screen Sharing
#   scripts/macbook-vnc-launcher.sh --stop     # stop tunnel (only processes we own)
#   scripts/macbook-vnc-launcher.sh --status   # check tunnel status
#
# Process-safety contract:
#   * The PID file lives in a private, 0700, per-user runtime directory — never
#     a shared path such as /tmp.
#   * A PID is only ever signalled after we verify (a) it is alive, (b) it is
#     owned by the current user, (c) its full command line still matches the
#     tunnel signature, and (d) its process start time still matches the value
#     recorded at launch. Check (d) defeats PID reuse.
#   * Only descendants of the recorded tunnel PID are signalled, and each is
#     re-verified by ownership before being touched.
#   * Every other gcloud/ssh/Screen Sharing session on the machine is left alone.
#   * SSH host-key verification is preserved (no StrictHostKeyChecking=no).
#
# NOTE: This script targets macOS. Shell syntax and the process-management
# logic are covered by automated tests on Linux, but macOS-specific behavior
# (Screen Sharing, gcloud IAP transport) is NOT VERIFIED in CI.

set -euo pipefail
umask 077

GCP_PROJECT="${GCP_PROJECT:-}"
GCP_ZONE="${GCP_ZONE:-}"
GCP_INSTANCE="${GCP_INSTANCE:-}"
LOCAL_VNC_PORT="${LOCAL_VNC_PORT:-5901}"
TUNNEL_READY_TIMEOUT="${TUNNEL_READY_TIMEOUT:-30}"
VNC_RUNTIME_DIR="${VNC_RUNTIME_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/vnc-tunnel}"
TUNNEL_PID_FILE="$VNC_RUNTIME_DIR/tunnel.pid"
REMOTE_VNC_HOST="127.0.0.1"
REMOTE_VNC_PORT="5901"

log()  { echo "[+] $*"; }
warn() { echo "[!] $*" >&2; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

# State used by the exit trap to clean up a tunnel we launched but never
# successfully handed over to the user.
LAUNCHED_PID=""
LAUNCHED_START_TIME=""
STARTUP_COMPLETE="0"

# --- Portable helpers ----------------------------------------------------------

# Owner UID of a path. GNU stat uses -c, BSD/macOS stat uses -f.
_path_owner_uid() {
    stat -c '%u' "$1" 2>/dev/null || stat -f '%u' "$1" 2>/dev/null || echo ""
}

_uid() { id -u; }

_proc_alive() {
    kill -0 "$1" 2>/dev/null || return 1
    # A zombie still answers kill -0, but it is not a running tunnel. Without
    # this check a crashed tunnel would spin until the readiness timeout.
    local state
    state="$(ps -p "$1" -o state= 2>/dev/null | tr -d '[:space:]')"
    [ "$state" = "Z" ] && return 1
    return 0
}

_proc_uid() {
    ps -p "$1" -o uid= 2>/dev/null | tr -d '[:space:]' || true
}

# Full command line of a PID (BSD and procps both accept `command=`).
# Returns an empty string, never a failure, when the PID is gone.
_proc_cmdline() {
    ps -p "$1" -o command= 2>/dev/null || true
}

# Process start time. Combined with the PID this forms an identity token that
# changes when the PID is recycled by the kernel.
_proc_start_time() {
    ps -p "$1" -o lstart= 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' || true
}

_is_uint() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

# Split a "<pid> <start time>" record. The start time itself contains spaces,
# so it must be taken as the remainder of the string rather than by positional
# parameters.
_record_pid()     { printf '%s\n' "${1%% *}"; }
_record_start()   { printf '%s\n' "${1#* }"; }

# Case-based substring test. Deliberately avoids `echo | grep -q`, which can
# race with SIGPIPE under `set -o pipefail` and yield a false negative.
_contains() {
    local haystack="$1" needle="$2"
    [ -n "$needle" ] || return 1
    case "$haystack" in
        *"$needle"*) return 0 ;;
    esac
    return 1
}

# --- Port probing --------------------------------------------------------------
# macOS ships nc; CI and other environments may not. Fall back so the readiness
# check works everywhere.
port_open() {
    local host="$1" port="$2"
    if command -v nc >/dev/null 2>&1; then
        nc -z "$host" "$port" >/dev/null 2>&1 && return 0
        return 1
    fi
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$host" "$port" <<'PY' >/dev/null 2>&1
import socket, sys
s = socket.socket()
s.settimeout(1)
try:
    s.connect((sys.argv[1], int(sys.argv[2])))
except OSError:
    sys.exit(1)
finally:
    s.close()
sys.exit(0)
PY
        return $?
    fi
    (exec 3<>"/dev/tcp/$host/$port") >/dev/null 2>&1 && return 0
    return 1
}

# --- Process tree --------------------------------------------------------------
# "pid ppid" snapshot; used to walk descendants portably (no pgrep -P).
_ps_table() {
    ps -A -o pid=,ppid= 2>/dev/null |
        awk 'NF == 2 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ { print $1 " " $2 }' || true
}

# Print every descendant PID of $1, one per line, excluding $1 itself.
_descendant_pids() {
    local root="$1"
    local table frontier pid child kids all seen
    table="$(_ps_table)"
    frontier="$root"
    all=""
    seen=" "
    while [ -n "$frontier" ]; do
        kids=""
        for pid in $frontier; do
            # shellcheck disable=SC2046  # word splitting is intentional here
            for child in $(printf '%s\n' "$table" | awk -v p="$pid" '$2 == p { print $1 }'); do
                case "$seen" in
                    *" $child "*) continue ;;
                esac
                seen="$seen$child "
                kids="$kids$child "
                all="$all$child "
            done
        done
        frontier="$kids"
    done
    printf '%s\n' "$all" | tr ' ' '\n' | sed '/^$/d'
}

# --- Runtime directory ---------------------------------------------------------
ensure_runtime_dir() {
    if [ -L "$VNC_RUNTIME_DIR" ]; then
        die "Runtime directory is a symlink; refusing to use it: $VNC_RUNTIME_DIR"
    fi
    if [ -e "$VNC_RUNTIME_DIR" ] && [ ! -d "$VNC_RUNTIME_DIR" ]; then
        die "Runtime path exists and is not a directory: $VNC_RUNTIME_DIR"
    fi
    if [ ! -d "$VNC_RUNTIME_DIR" ]; then
        mkdir -p "$VNC_RUNTIME_DIR" ||
            die "Could not create runtime directory: $VNC_RUNTIME_DIR"
    fi
    local owner
    owner="$(_path_owner_uid "$VNC_RUNTIME_DIR")"
    if [ -z "$owner" ] || [ "$owner" != "$(_uid)" ]; then
        die "Runtime directory is not owned by the current user: $VNC_RUNTIME_DIR"
    fi
    chmod 700 "$VNC_RUNTIME_DIR" ||
        die "Could not restrict permissions on: $VNC_RUNTIME_DIR"
    if [ -e "$TUNNEL_PID_FILE" ] && [ ! -O "$TUNNEL_PID_FILE" ]; then
        die "PID file is not owned by the current user: $TUNNEL_PID_FILE"
    fi
}

_write_pid_file() {
    local pid="$1" start_time="$2"
    local tmp
    tmp="$TUNNEL_PID_FILE.tmp.$$"
    ( umask 077; printf '%s\n%s\n' "$pid" "$start_time" > "$tmp" )
    chmod 600 "$tmp"
    mv -f "$tmp" "$TUNNEL_PID_FILE"
}

# --- Identity verification -----------------------------------------------------

# True when $1 is the tunnel process we launched.
# Fails closed: without a configured GCP_INSTANCE nothing can match.
is_our_tunnel() {
    local pid="$1"
    local expect_start="${2:-}"

    _is_uint "$pid" || return 1
    [ "$pid" -gt 1 ] || return 1
    _proc_alive "$pid" || return 1

    # Ownership: never signal another user's process.
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

    # Command-line signature. gcloud compute ssh <instance> ... or the ssh it
    # spawns for the IAP forward.
    [ -n "$GCP_INSTANCE" ] || return 1
    local cmdline
    cmdline="$(_proc_cmdline "$pid")"
    [ -n "$cmdline" ] || return 1
    _contains "$cmdline" "$GCP_INSTANCE" || return 1
    if _contains "$cmdline" "gcloud" || _contains "$cmdline" "iap-tunnel"; then
        return 0
    fi
    if _contains "$cmdline" "ssh" && _contains "$cmdline" "-L"; then
        return 0
    fi
    return 1
}

# True when $1 is a live process owned by us that we are allowed to signal as
# part of this tunnel's tree. Callers must only pass PIDs already proven to be
# descendants of the verified tunnel root.
_owned_live_process() {
    local pid="$1"
    _is_uint "$pid" || return 1
    [ "$pid" -gt 1 ] || return 1
    [ "$pid" != "$$" ] || return 1
    _proc_alive "$pid" || return 1
    local owner
    owner="$(_proc_uid "$pid")"
    [ -n "$owner" ] || return 1
    [ "$owner" = "$(_uid)" ] || return 1
    [ -n "$(_proc_cmdline "$pid")" ] || return 1
    return 0
}

# Signal $2, but only after re-verifying identity immediately beforehand.
_verified_signal() {
    local pid="$1" sig="$2" expect_start="${3:-}"
    if ! is_our_tunnel "$pid" "$expect_start"; then
        warn "Refusing to signal PID $pid — identity check failed"
        return 1
    fi
    kill "-$sig" "$pid" 2>/dev/null || return 1
    return 0
}

# Terminate the tunnel and its owned children: children first, then the root.
terminate_tunnel() {
    local pid="$1" expect_start="${2:-}"
    local descendants child

    if ! is_our_tunnel "$pid" "$expect_start"; then
        warn "PID $pid is not the tunnel this script launched; not signalling it"
        return 1
    fi

    # Snapshot descendants before we start killing, so the tree is fixed.
    descendants="$(_descendant_pids "$pid")"

    for child in $descendants; do
        if _owned_live_process "$child"; then
            kill -TERM "$child" 2>/dev/null || true
        fi
    done

    _verified_signal "$pid" TERM "$expect_start" || true

    local i=0
    while [ "$i" -lt 10 ]; do
        _proc_alive "$pid" || break
        i=$((i + 1))
        sleep 1
    done

    if _proc_alive "$pid"; then
        warn "Tunnel did not exit on SIGTERM; escalating to SIGKILL"
        for child in $descendants; do
            if _owned_live_process "$child"; then
                kill -KILL "$child" 2>/dev/null || true
            fi
        done
        # Re-verify identity immediately before the unconditional signal.
        _verified_signal "$pid" KILL "$expect_start" || true
    fi
    return 0
}

# --- PID file ------------------------------------------------------------------
# Echoes "<pid> <start_time>" for a live, owned tunnel; cleans up stale files.
tunnel_pid() {
    [ -f "$TUNNEL_PID_FILE" ] || return 1

    local pid start_time
    pid="$(sed -n '1p' "$TUNNEL_PID_FILE" 2>/dev/null || true)"
    start_time="$(sed -n '2p' "$TUNNEL_PID_FILE" 2>/dev/null || true)"

    if _is_uint "$pid" && is_our_tunnel "$pid" "$start_time"; then
        printf '%s %s\n' "$pid" "$start_time"
        return 0
    fi

    if [ -z "$pid" ]; then
        warn "PID file is empty or malformed; removing it"
    elif ! _is_uint "$pid"; then
        warn "PID file is empty or malformed; removing it"
    elif ! _proc_alive "$pid"; then
        warn "Stale PID file (PID $pid no longer exists); removing it"
    elif [ -n "$start_time" ] && [ "$(_proc_start_time "$pid")" != "$start_time" ]; then
        warn "PID reuse detected: PID $pid is live but is not the recorded process; removing PID file"
    else
        warn "PID $pid does not match our tunnel signature; leaving it alone"
    fi
    rm -f "$TUNNEL_PID_FILE"
    return 1
}

# --- Cleanup on interruption ---------------------------------------------------
_on_exit() {
    local rc=$?
    if [ "$STARTUP_COMPLETE" -eq 0 ] && [ -n "$LAUNCHED_PID" ]; then
        warn "Cleaning up tunnel started by this invocation (PID $LAUNCHED_PID)"
        terminate_tunnel "$LAUNCHED_PID" "$LAUNCHED_START_TIME" || true
        rm -f "$TUNNEL_PID_FILE"
    fi
    exit "$rc"
}

trap _on_exit EXIT
trap 'warn "Interrupted"; exit 130' INT
trap 'warn "Terminated"; exit 143' TERM

# --- Commands ------------------------------------------------------------------

cmd_status() {
    local entry pid start_time
    if entry="$(tunnel_pid)"; then
        pid="$(_record_pid "$entry")"
        start_time="$(_record_start "$entry")"
        log "IAP tunnel is running (PID $pid)"
        log "  Instance:       ${GCP_INSTANCE}"
        log "  Local VNC port: 127.0.0.1:${LOCAL_VNC_PORT}"
        log "  Runtime dir:    ${VNC_RUNTIME_DIR}"
        if port_open 127.0.0.1 "$LOCAL_VNC_PORT"; then
            log "  Port ${LOCAL_VNC_PORT}: accepting connections"
        else
            warn "  Port ${LOCAL_VNC_PORT}: not yet accepting connections"
        fi
        return 0
    fi
    log "No active IAP tunnel found"
    return 1
}

cmd_stop() {
    local entry pid start_time
    if ! entry="$(tunnel_pid)"; then
        log "No active tunnel to stop"
        return 0
    fi
    pid="$(_record_pid "$entry")"
    start_time="$(_record_start "$entry")"

    log "Stopping IAP tunnel (PID $pid)..."
    if terminate_tunnel "$pid" "$start_time"; then
        rm -f "$TUNNEL_PID_FILE"
        log "Tunnel stopped"
    else
        warn "Tunnel was not terminated; PID file retained for inspection"
        return 1
    fi
    # Deliberately does NOT quit Screen Sharing — it may be an active session.
}

cmd_start() {
    [ -n "$GCP_PROJECT" ]  || die "GCP_PROJECT is not set"
    [ -n "$GCP_ZONE" ]     || die "GCP_ZONE is not set"
    [ -n "$GCP_INSTANCE" ] || die "GCP_INSTANCE is not set"
    command -v gcloud >/dev/null 2>&1 ||
        die "gcloud CLI not found. Install Google Cloud SDK first."

    ensure_runtime_dir

    if tunnel_pid >/dev/null; then
        log "IAP tunnel already running — reusing it"
        cmd_status || true
        open_screen_sharing || true
        return 0
    fi

    log "Opening IAP SSH tunnel to ${GCP_INSTANCE} (${GCP_PROJECT}/${GCP_ZONE})..."
    log "  Local VNC forward: 127.0.0.1:${LOCAL_VNC_PORT} -> ${REMOTE_VNC_HOST}:${REMOTE_VNC_PORT}"
    log "  Runtime dir: $VNC_RUNTIME_DIR"

    # Single-hop IAP tunnel with VNC port forwarding.
    # The forward is pinned to 127.0.0.1 so it is never exposed on any
    # external interface. SSH host-key verification is preserved.
    gcloud compute ssh "${GCP_INSTANCE}" \
        --project="${GCP_PROJECT}" \
        --zone="${GCP_ZONE}" \
        --tunnel-through-iap \
        --ssh-flag="-N" \
        --ssh-flag="-L 127.0.0.1:${LOCAL_VNC_PORT}:${REMOTE_VNC_HOST}:${REMOTE_VNC_PORT}" \
        --ssh-flag="-o ServerAliveInterval=30" \
        --ssh-flag="-o ServerAliveCountMax=3" \
        --ssh-flag="-o ExitOnForwardFailure=yes" \
        >"$VNC_RUNTIME_DIR/tunnel.log" 2>&1 &

    LAUNCHED_PID=$!
    LAUNCHED_START_TIME="$(_proc_start_time "$LAUNCHED_PID")"
    _write_pid_file "$LAUNCHED_PID" "$LAUNCHED_START_TIME"
    log "IAP tunnel started (PID $LAUNCHED_PID)"

    local waited=0
    local ready=0
    while [ "$waited" -lt "$TUNNEL_READY_TIMEOUT" ]; do
        if ! _proc_alive "$LAUNCHED_PID"; then
            break
        fi
        if port_open 127.0.0.1 "$LOCAL_VNC_PORT"; then
            ready=1
            break
        fi
        sleep 1
        waited=$((waited + 1))
    done

    if [ "$ready" -ne 1 ]; then
        local reason
        if _proc_alive "$LAUNCHED_PID"; then
            reason="VNC forward did not become ready within ${TUNNEL_READY_TIMEOUT}s. Verify TigerVNC is running on the VM."
        else
            reason="Tunnel process exited during startup. Check gcloud auth and IAP permissions."
        fi
        # Reap the child only if it has already exited; `wait` on a live child
        # would block forever.
        if ! _proc_alive "$LAUNCHED_PID"; then
            wait "$LAUNCHED_PID" 2>/dev/null || true
        fi
        # _on_exit performs the cleanup for us.
        die "$reason"
    fi

    STARTUP_COMPLETE=1
    log "VNC forward ready on 127.0.0.1:${LOCAL_VNC_PORT}"
    open_screen_sharing || true
    log "Done. Screen Sharing should prompt for the VNC password."
    log "To stop: $0 --stop"
}

# Never let a failure to launch the GUI client abort the launcher: the tunnel
# is already established at this point. Always returns 0.
open_screen_sharing() {
    local url="vnc://127.0.0.1:${LOCAL_VNC_PORT}"
    if command -v open >/dev/null 2>&1; then
        log "Opening Screen Sharing..."
        if open "$url" >/dev/null 2>&1; then
            return 0
        fi
        warn "Could not launch Screen Sharing automatically; open ${url} manually"
        return 0
    fi
    log "macOS 'open' not available; connect manually to ${url}"
    return 0
}

case "${1:-start}" in
    start)        cmd_start ;;
    stop|--stop)  cmd_stop ;;
    status|--status) cmd_status ;;
    -h|--help|help)
        grep '^#' "$0" | sed 's/^# \{0,1\}//'
        ;;
    *)
        die "Unknown option: $1 (use: start | stop | status)"
        ;;
esac