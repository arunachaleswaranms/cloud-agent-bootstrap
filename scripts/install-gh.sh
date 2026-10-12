#!/usr/bin/env bash
#
# Install the GitHub CLI (idempotent). Authentication is a manual
# post-bootstrap step: gh auth login
set -euo pipefail

if command -v gh >/dev/null 2>&1; then
    echo "[+] GitHub CLI already installed"
    gh --version | head -n1
else
    echo "[+] Installing GitHub CLI"
    sudo apt update
    sudo apt install -y gh
    gh --version | head -n1
fi

echo "[!] Authenticate manually: gh auth login"
