#!/usr/bin/env bash
#
# Idempotent 4 GB swap setup.
# - If $SWAP_FILE swap is already active, does nothing.
# - If the file exists but is inactive, activates it.
# - Otherwise creates it, enables it, and persists it in /etc/fstab.
set -euo pipefail

SWAP_FILE="${SWAP_FILE:-/swapfile}"
SWAP_SIZE="${SWAP_SIZE:-4G}"

swap_active() {
    [ -r /proc/swaps ] || return 1
    awk -v f="$SWAP_FILE" '$1 == f { found = 1 } END { exit !found }' /proc/swaps
}

if swap_active; then
    echo "[+] Swap already active: $SWAP_FILE"
elif [ -f "$SWAP_FILE" ]; then
    echo "[!] $SWAP_FILE exists but is not active; activating it"
    sudo chmod 600 "$SWAP_FILE"
    sudo mkswap "$SWAP_FILE" >/dev/null
    sudo swapon "$SWAP_FILE"
else
    echo "[+] Creating ${SWAP_SIZE} swap file at $SWAP_FILE"
    sudo fallocate -l "$SWAP_SIZE" "$SWAP_FILE"
    sudo chmod 600 "$SWAP_FILE"
    sudo mkswap "$SWAP_FILE" >/dev/null
    sudo swapon "$SWAP_FILE"
fi

if ! grep -qxF "$SWAP_FILE none swap sw 0 0" /etc/fstab 2>/dev/null; then
    echo "[+] Persisting swap in /etc/fstab"
    echo "$SWAP_FILE none swap sw 0 0" | sudo tee -a /etc/fstab >/dev/null
fi

echo
swapon --show
free -h
