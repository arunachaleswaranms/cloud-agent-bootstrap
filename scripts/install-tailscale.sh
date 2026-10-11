#!/usr/bin/env bash
set -euo pipefail

curl -fsSL https://tailscale.com/install.sh | sh

echo
echo "[+] Starting Tailscale authentication"
sudo tailscale up

tailscale status
