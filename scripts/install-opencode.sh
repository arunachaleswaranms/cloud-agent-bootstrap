#!/usr/bin/env bash
#
# Install OpenCode, pinned to the validated version (idempotent).
set -euo pipefail

OPENCODE_VERSION="${OPENCODE_VERSION:-1.18.35}"

if command -v opencode >/dev/null 2>&1; then
    installed="$(opencode --version 2>/dev/null || true)"
    if [ "$installed" = "$OPENCODE_VERSION" ]; then
        echo "[+] OpenCode ${OPENCODE_VERSION} already installed"
        exit 0
    fi
    echo "[+] OpenCode ${installed:-unknown} found; switching to pinned ${OPENCODE_VERSION}"
fi

sudo npm install -g "opencode-ai@${OPENCODE_VERSION}"

opencode --version
