#!/usr/bin/env bash
#
# Install Playwright (pinned) + Chromium with OS dependencies (idempotent).
set -euo pipefail

PLAYWRIGHT_VERSION="${PLAYWRIGHT_VERSION:-1.64.0}"

installed=""
if command -v playwright >/dev/null 2>&1; then
    installed="$(playwright --version 2>/dev/null || true)"
    installed="${installed#Version }"
fi

if [ "$installed" != "$PLAYWRIGHT_VERSION" ]; then
    echo "[+] Installing Playwright ${PLAYWRIGHT_VERSION}"
    npm install -g "playwright@${PLAYWRIGHT_VERSION}"
else
    echo "[+] Playwright ${PLAYWRIGHT_VERSION} already installed"
fi

echo "[+] Ensuring Chromium and OS dependencies"
playwright install --with-deps chromium

playwright --version
