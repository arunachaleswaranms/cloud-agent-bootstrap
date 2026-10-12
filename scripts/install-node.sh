#!/usr/bin/env bash
#
# Install Node.js 22 LTS via NodeSource (idempotent).
set -euo pipefail

NODE_MAJOR=22

need=1
if command -v node >/dev/null 2>&1; then
    current="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
    [ "$current" = "$NODE_MAJOR" ] && need=0
fi

if [ "$need" = 1 ]; then
    echo "[+] Installing Node.js ${NODE_MAJOR}.x"
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | sudo -E bash -
    sudo apt install -y nodejs
else
    echo "[+] Node.js ${NODE_MAJOR}.x already installed"
fi

node --version
npm --version
