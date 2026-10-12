#!/usr/bin/env bash
#
# Install Tailscale (idempotent). Authentication is a manual
# post-bootstrap step: sudo tailscale up
set -euo pipefail

if command -v tailscale >/dev/null 2>&1; then
    echo "[+] Tailscale already installed"
    tailscale version | head -n1
else
    curl -fsSL https://tailscale.com/install.sh | sh
fi

echo
echo "[!] Authenticate manually (requires your Tailscale account):"
echo "    sudo tailscale up"
