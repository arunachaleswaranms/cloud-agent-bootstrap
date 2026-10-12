#!/usr/bin/env bash
#
# cloud-agent-bootstrap: one-shot, idempotent provisioning.
# Supported baseline: Ubuntu 24.04 LTS x86_64 (GCP e2-standard-2).
# Safe to re-run on an existing machine.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_DIR="$HOME/.config/agent"
SECRETS_FILE="$SECRETS_DIR/secrets.env"

log()  { echo "[+] $*"; }
warn() { echo "[!] $*" >&2; }

if [ "$(id -u)" -eq 0 ]; then
    warn "Run as a normal user with sudo, not as root."
    exit 1
fi

# --- 1. OS baseline guard ---------------------------------------------------
if [ -r /etc/os-release ]; then . /etc/os-release; fi
if [ "${ID:-}" != "ubuntu" ] || [ "${VERSION_ID:-}" != "24.04" ]; then
    warn "Unsupported OS: ${PRETTY_NAME:-unknown}. Supported baseline: Ubuntu 24.04 LTS x86_64."
    warn "Do NOT release-upgrade this VM to Ubuntu 26.04; rebuild it from an Ubuntu 24.04 image instead."
    exit 1
fi
log "OS baseline OK: ${PRETTY_NAME:-Ubuntu 24.04 LTS}"

# --- 2. Base packages --------------------------------------------------------
log "Updating apt"
sudo apt update

log "Installing base packages"
sudo xargs -a "$REPO_DIR/packages/apt.txt" apt install -y

# --- 3. Swap ------------------------------------------------------------------
log "Ensuring 4 GB swap"
bash "$REPO_DIR/scripts/setup-swap.sh"

# --- 4. Toolchains --------------------------------------------------------------
log "Installing Docker"
bash "$REPO_DIR/scripts/install-docker.sh"

log "Installing Node.js 22"
bash "$REPO_DIR/scripts/install-node.sh"

log "Installing Go 1.22"
bash "$REPO_DIR/scripts/install-go.sh"

log "Installing GitHub CLI"
bash "$REPO_DIR/scripts/install-gh.sh"

log "Installing OpenCode (pinned 1.18.35)"
bash "$REPO_DIR/scripts/install-opencode.sh"

log "Installing Playwright + Chromium"
bash "$REPO_DIR/scripts/install-playwright.sh"

if [ "${INSTALL_SECURITY_TOOLS:-0}" = "1" ]; then
    log "Installing optional security tools"
    bash "$REPO_DIR/scripts/install-security-tools.sh"
else
    warn "Skipping optional security tools. Re-run with INSTALL_SECURITY_TOOLS=1 to install (authorized bug-bounty/VDP testing only)."
fi

# --- 5. tmux config --------------------------------------------------------------
if [ -f "$HOME/.tmux.conf" ] && ! grep -q "cloud-agent-bootstrap" "$HOME/.tmux.conf" 2>/dev/null; then
    log "Backing up existing ~/.tmux.conf"
    cp -a "$HOME/.tmux.conf" "$HOME/.tmux.conf.bak.$(date +%Y%m%d%H%M%S)"
fi
log "Installing tmux config"
install -m 0644 "$REPO_DIR/config/tmux.conf" "$HOME/.tmux.conf"

# --- 6. Workspace directories -----------------------------------------------------
log "Creating workspace directories"
mkdir -p "$HOME/workspace"/{bugbounty,cve-research,tools,reports,logs}

# --- 7. Secrets directory -----------------------------------------------------------
log "Preparing secrets directory"
mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"
if [ ! -f "$SECRETS_FILE" ]; then
    cp "$REPO_DIR/config/secrets.env.example" "$SECRETS_FILE"
    log "Created $SECRETS_FILE from template"
fi
chmod 600 "$SECRETS_FILE"

cat <<'EOF'

[+] Bootstrap complete.

Manual post-bootstrap steps (interactive credentials cannot be scripted):
  1. Log out and back in once (Docker group membership).
  2. gh auth login                          # GitHub authentication
  3. sudo bash scripts/install-tailscale.sh # then: sudo tailscale up
  4. opencode auth login                    # OpenCode authentication
  5. Populate ~/.config/agent/secrets.env (mode 600) and source it in your shell.

Remote access:
  - Preferred: Tailscale (or GCP IAP TCP forwarding).
  - NEVER open SSH to 0.0.0.0/0. See docs/GCP_SETUP.md.

Verify anytime with:
  bash scripts/health-check.sh
EOF
