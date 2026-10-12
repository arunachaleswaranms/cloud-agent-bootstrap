#!/usr/bin/env bash
#
# Install Go 1.22 (idempotent). Ubuntu 24.04's golang-go provides 1.22.2,
# the validated version for this repo.
set -euo pipefail

GO_MINOR=1.22

have=0
if command -v go >/dev/null 2>&1; then
    v="$(go version 2>/dev/null || true)"
    case "$v" in *"go${GO_MINOR}."*) have=1;; esac
fi

if [ "$have" = 1 ]; then
    echo "[+] Go ${GO_MINOR}.x already installed"
else
    echo "[+] Installing Go (distro package, provides ${GO_MINOR}.x)"
    sudo apt update
    sudo apt install -y golang-go
fi

go version
go env GOPATH
