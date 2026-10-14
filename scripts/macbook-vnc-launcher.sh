#!/usr/bin/env bash
#
# macbook-vnc-launcher.sh — reconnect to the agent VM's XFCE desktop from macOS.
#
# Establishes a Google Cloud IAP SSH tunnel, then opens macOS Screen Sharing
# to the local VNC endpoint. Re-runnable: kills any stale tunnel first.
#
# Prerequisites (on the Mac):
# - Google Cloud SDK (gcloud) authenticated
# - macOS Screen Sharing (built-in)
#
# Configuration (edit these or export before running):
#   GCP_PROJECT       GCP project ID
#   GCP_ZONE          VM zone (e.g. us-central1-a)
#   GCP_INSTANCE      VM instance name
#   VNC_DISPLAY       remote X display (default :1 -> port 5901)
#   LOCAL_SSH_PORT    local port for the IAP tunnel (default 2222)
#
# Usage:
#   scripts/macbook-vnc-launcher.sh [--stop]

set -euo pipefail

GCP_PROJECT="${GCP_PROJECT:-}"
GCP_ZONE="${GCP_ZONE:-}"
GCP_INSTANCE="${GCP_INSTANCE:-}"
VNC_DISPLAY="${VNC_DISPLAY:-:1}"
LOCAL_SSH_PORT="${LOCAL_SSH_PORT:-2222}"
LOCAL_VNC_PORT="${LOCAL_VNC_PORT:-5901}"

# Derive VNC port from display (:1 -> 5901)
VNC_PORT_REMOTE="590${VNC_DISPLAY#:}"

log()  { echo "[+] $*"; }
warn() { echo "[!] $*" >&2; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

cmd_stop() {
    local pids
    pids="$(pgrep -f "ssh.*tunnel-through-iap.*${GCP_INSTANCE:-__none__}" 2>/dev/null || true)"
    if [ -n "$pids" ]; then
        log "Stopping IAP tunnel (PID $pids)"
        # shellcheck disable=SC2086
        kill $pids 2>/dev/null || true
    else
        log "No active IAP tunnel found"
    fi
    # Also close any local Screen Sharing VNC connection
    osascript -e 'tell application "Screen Sharing" to quit' 2>/dev/null || true
}

cmd_start() {
    [ -n "$GCP_PROJECT" ]    || die "GCP_PROJECT is not set"
    [ -n "$GCP_ZONE" ]       || die "GCP_ZONE is not set"
    [ -n "$GCP_INSTANCE" ]   || die "GCP_INSTANCE is not set"

    command -v gcloud >/dev/null 2>&1 || die "gcloud CLI not found. Install Google Cloud SDK first."

    # Kill any stale tunnel
    cmd_stop

    log "Opening IAP SSH tunnel to ${GCP_INSTANCE} (${GCP_PROJECT}/${GCP_ZONE})..."
    log "  Local SSH port:  ${LOCAL_SSH_PORT}"
    log "  Remote VNC port: ${VNC_PORT_REMOTE} (display ${VNC_DISPLAY})"

    # Start IAP tunnel in background
    gcloud compute ssh "${GCP_INSTANCE}" \
        --project="${GCP_PROJECT}" \
        --zone="${GCP_ZONE}" \
        --tunnel-through-iap \
        --ssh-flag="-L ${LOCAL_SSH_PORT}:localhost:22" \
        --ssh-flag="-N" \
        --ssh-flag="-o ServerAliveInterval=30" \
        --ssh-flag="-o ServerAliveCountMax=3" \
        --ssh-flag="-o ExitOnForwardFailure=yes" \
        &

    local tunnel_pid=$!
    log "IAP tunnel started (PID $tunnel_pid)"

    # Wait for the local SSH port to accept connections
    local waited=0
    while [ "$waited" -lt 30 ]; do
        if nc -z localhost "$LOCAL_SSH_PORT" 2>/dev/null; then
            break
        fi
        sleep 1
        waited=$((waited + 1))
    done

    if ! nc -z localhost "$LOCAL_SSH_PORT" 2>/dev/null; then
        die "IAP tunnel did not become ready within 30s. Check gcloud auth and IAP permissions."
    fi

    log "IAP tunnel is ready"

    # Forward VNC through the SSH tunnel (second hop)
    log "Forwarding VNC port ${VNC_PORT_REMOTE}..."
    ssh -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -p "$LOCAL_SSH_PORT" \
        -L "${LOCAL_VNC_PORT}:localhost:${VNC_PORT_REMOTE}" \
        -N \
        -o ServerAliveInterval=30 \
        -o ExitOnForwardFailure=yes \
        "${GCP_INSTANCE}"@localhost \
        &

    local vnc_tunnel_pid=$!
    log "VNC tunnel started (PID $vnc_tunnel_pid)"

    # Wait for local VNC port
    waited=0
    while [ "$waited" -lt 15 ]; do
        if nc -z localhost "$LOCAL_VNC_PORT" 2>/dev/null; then
            break
        fi
        sleep 1
        waited=$((waited + 1))
    done

    if ! nc -z localhost "$LOCAL_VNC_PORT" 2>/dev/null; then
        die "VNC tunnel did not become ready. Verify TigerVNC is running on the VM (display ${VNC_DISPLAY})."
    fi

    log "VNC tunnel is ready on localhost:${LOCAL_VNC_PORT}"

    # Open macOS Screen Sharing
    log "Opening Screen Sharing..."
    open "vnc://localhost:${LOCAL_VNC_PORT}"

    log "Done. Screen Sharing should prompt for the VNC password."
    log "To stop: $0 --stop"
}

case "${1:-start}" in
    start) cmd_start ;;
    stop)  cmd_stop  ;;
    -h|--help|help)
        grep '^#' "$0" | sed 's/^# \{0,1\}//'
        ;;
    *)
        die "Unknown option: $1 (use: start | stop)"
        ;;
esac
