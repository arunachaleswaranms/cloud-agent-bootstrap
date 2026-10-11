#!/usr/bin/env bash
set -euo pipefail

echo "[+] Updating Ubuntu"
sudo apt update
sudo apt upgrade -y

echo "[+] Installing base packages"
sudo xargs -a packages/apt.txt apt install -y

echo "[+] Installing Docker"
bash scripts/install-docker.sh

echo "[+] Installing Node.js"
bash scripts/install-node.sh

echo "[+] Installing Go"
bash scripts/install-go.sh

echo "[+] Installing OpenCode"
bash scripts/install-opencode.sh

echo "[+] Creating workspace"
mkdir -p "$HOME/workspace"/{bugbounty,cve-research,tools,reports,logs}
mkdir -p "$HOME/.config/agent"
chmod 700 "$HOME/.config/agent"

touch "$HOME/.config/agent/secrets.env"
chmod 600 "$HOME/.config/agent/secrets.env"

echo
echo "[+] Bootstrap complete"
echo "[!] Run scripts/install-tailscale.sh separately to authenticate Tailscale."
