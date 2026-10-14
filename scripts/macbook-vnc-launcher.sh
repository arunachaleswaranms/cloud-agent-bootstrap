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
#   GCP_PROJECT       GCP project ID
#   GCP_ZONE          VM zone (e.g. us-central1-a)
#   GCP_INSTANCE      VM instance name
#   LOCAL_VNC_PORT    local port for VNC forward (default 5901)
#
# Usage:
#   scripts/macbook-vnc-launcher.sh            # start tunnel + open Screen Sharing
#   scripts/macbook-vnc-launcher.sh --stop     # stop tunnel (only processes we own)
#   scripts/macbook-vnc-launcher.sh --status   # check tunnel status
#
# NOTE: This script targets macOS. Shell syntax is validated on Ubuntu,
# but macOS-specific behavior (Screen Sharing, osascript) is unverified
# unless actually tested on macOS.

set -euo pipefail

GCP_PROJECT="${GCP_PROJECT:-}"
GCP_ZONE="${GCP_ZONE:-}"
GCP_INSTANCE="${GCP_INSTANCE:-}"
LOCAL_VNC_PORT="${LOCAL_VNC_PORT:-5901}"
TUNNEL_PID_FILE="${TUNNEL_PID_FILE:-/tmp/macbook-vnc-tunnel.pid}"

log()  { echo "[+] $*"; }
warn() { echo "[!] $*" >&2; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

# --- Check if tunnel is already running (owned by this script) ---------------
tunnel_pid() {
    if [ -f "$TUNNEL_PID_FILE" ]; then
        local pid
        pid="$(cat "$TUNNEL_PID_FILE" 2>/dev/null || true)"
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            # Verify it's actually our gcloud tunnel, not a recycled PID
            if ps -p "$pid" -o command= 2>/dev/null | grep -q "gcloud.*ssh.*${GCP_INSTANCE:-__none__}"; then
                echo "$pid"
                return 0
            fi
        fi
        # Stale PID file — clean it up
        rm -f "$TUNNEL_PID_FILE"
    fi
    return 1
}

# --- Status command -----------------------------------------------------------
cmd_status() {
    local pid
    if pid="$(tunnel_pid)"; then
        log "IAP tunnel is running (PID $pid)"
        log "  Instance: ${GCP_INSTANCE}"
        log "  Local VNC port: ${LOCAL_VNC_PORT}"
        if nc -z localhost "$LOCAL_VNC_PORT" 2>/dev/null; then
            log "  Port ${LOCAL_VNC_PORT}: accepting connections"
        else
            warn "  Port ${LOCAL_VNC_PORT}: not yet accepting connections"
        fi
        return 0
    else
        log "No active IAP tunnel found"
        return 1
    fi
}

# --- Stop command -------------------------------------------------------------
cmd_stop() {
    local pid
    if pid="$(tunnel_pid)"; then
        log "Stopping IAP tunnel (PID $pid)..."
        kill "$pid" 2>/dev/null || true
        for _ in $(seq 1 10); do
            kill -0 "$pid" 2>/dev/null || break
            sleep 1
        done
        if kill -0 "$pid" 2>/dev/null; then
            warn "Tunnel did not exit gracefully; sending SIGKILL"
            kill -9 "$pid" 2>/dev/null || true
        fi
        rm -f "$TUNNEL_PID_FILE"
        log "Tunnel stopped"
    else
        log "No active tunnel to stop"
    fi
    # Do NOT quit Screen Sharing — it may be a user's active session
}

# --- Start command ------------------------------------------------------------
cmd_start() {
    [ -n "$GCP_PROJECT" ]  || die "GCP_PROJECT is not set"
    [ -n "$GCP_ZONE" ]     || die "GCP_ZONE is not set"
    [ -n "$GCP_INSTANCE" ] || die "GCP_INSTANCE is not set"

    command -v gcloud >/dev/null 2>&1 || die "gcloud CLI not found. Install Google Cloud SDK first."

    # Check for existing tunnel
    local existing
    if existing="$(tunnel_pid)"; then
        log "IAP tunnel already running (PID $existing) — reusing"
        cmd_status
        # Still open Screen Sharing in case it was closed
        log "Opening Screen Sharing..."
        open "vnc://localhost:${LOCAL_VNC_PORT}"
        return 0
    fi

    log "Opening IAP SSH tunnel to ${GCP_INSTANCE} (${GCP_PROJECT}/${GCP_ZONE})..."
    log "  Local VNC port: ${LOCAL_VNC_PORT}"

    # Single-hop IAP tunnel with VNC port forwarding
    # gcloud compute ssh binds -L to localhost by default
    # SSH identity verification is preserved (no StrictHostKeyChecking=no)
    gcloud compute ssh "${GCP_INSTANCE}" \
        --project="${GCP_PROJECT}" \
        --zone="${GCP_ZONE}" \
        --tunnel-through-iap \
        --ssh-flag="-N" \
        --ssh-flag=-L"${LOCAL_VNC_PORT}:127.0.0.1:5901" \
        --ssh-flag="-o ServerAliveInterval=30" \
        --ssh-flag="-o ServerAliveCountMax=3" \
        --ssh-flag="-o ExitOnForwardFailure=yes" \
        &

    local tunnel_pid=$!
    echo "$tunnel_pid" > "$TUNNEL_PID_FILE"
    chmod 600 "$TUNNEL_PID_FILE"
    log "IAP tunnel started (PID $tunnel_pid)"

    # Wait for the local VNC port to accept connections
    local waited=0
    while [ "$waited" -lt 30 ]; do
        if ! kill -0 "$tunnel_pid" 2>/dev/null; then
            rm -f "$TUNNEL_PID_FILE"
            die "Tunnel process exited during startup. Check gcloud auth and IAP permissions."
        fi
        if nc -z localhost "$LOCAL_VNC_PORT" 2>/dev/null; then
            break
        fi
        sleep 1
        waited=$((waited + 1))
    done

    if ! nc -z localhost "$LOCAL_VNC_PORT" 2>/dev/null; then
        rm -f "$TUNNEL_PID_FILE"
        die "VNC forward did not become ready within 30s. Verify TigerVNC is running on the VM."
    fi

    log "VNC forward is ready on localhost:${LOCAL_VNC_PORT}"

    # Open macOS Screen Sharing only after the forward is ready
    log "Opening Screen Sharing..."
    open "vnc://localhost:${LOCAL_VNC_PORT}"

    log "Done. Screen Sharing should prompt for the VNC password."
    log "To stop: $0 --stop"
}

case "${1:-start}" in
    start)  cmd_start ;;
    stop)   cmd_stop  ;;
    status) cmd_status ;;
    -h|--help|help)
        grep '^#' "$0" | sed 's/^# \{0,1\}//'
        ;;
    *)
        die "Unknown option: $1 (use: start | stop | status)"
        ;;
esac
