#!/usr/bin/env bash
#
# OPTIONAL: security/recon tooling for AUTHORIZED bug-bounty / VDP testing
# only, against targets you have written permission to test.
# Requires Go 1.22+ (run bash bootstrap.sh first).
#
# Usage: INSTALL_SECURITY_TOOLS=1 bash scripts/install-security-tools.sh
set -euo pipefail

if [ "${INSTALL_SECURITY_TOOLS:-0}" != "1" ]; then
    echo "[!] Security tools are opt-in: authorized bug-bounty/VDP testing only."
    echo "    Re-run with: INSTALL_SECURITY_TOOLS=1 bash $0"
    exit 0
fi

command -v go >/dev/null 2>&1 || {
    echo "[-] Go 1.22+ is required; run: bash bootstrap.sh" >&2
    exit 1
}

GOBIN="$(go env GOPATH)/bin"

TOOLS=(
    "github.com/ffuf/ffuf/v2@v2.1.0"
    "github.com/projectdiscovery/httpx/cmd/httpx@v1.6.10"
    "github.com/projectdiscovery/nuclei/v3/cmd/nuclei@v3.3.9"
    "github.com/projectdiscovery/subfinder/v2/cmd/subfinder@v2.6.7"
)

for pkg in "${TOOLS[@]}"; do
    name="${pkg##*/}"
    if command -v "$name" >/dev/null 2>&1; then
        echo "[+] $name already installed"
        continue
    fi
    echo "[+] Installing $name ($pkg)"
    go install "$pkg"
done

echo "[+] Updating Nuclei templates"
if command -v nuclei >/dev/null 2>&1; then
    nuclei -update-templates || \
        echo "[!] Could not update Nuclei templates; run 'nuclei -update-templates' later."
fi

echo "[+] Done. Tools installed to: $GOBIN"
echo "[!] Ensure $GOBIN is in your PATH."
