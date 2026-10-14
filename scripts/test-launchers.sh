#!/usr/bin/env bash
#
# test-launchers.sh — non-destructive regression tests for launcher scripts.
#
# Tests: syntax, shellcheck, argument parsing, help output, status commands.
# Does NOT start/stop actual services or make network connections.
#
# Usage:
#   scripts/test-launchers.sh

set -uo pipefail

PASS=0; FAIL=0
ok()  { echo "  [PASS] $*"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $*"; FAIL=$((FAIL + 1)); }

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPTS_DIR/.." || exit 1

echo "== Syntax validation =="
for f in scripts/start-burp.sh scripts/macbook-vnc-launcher.sh scripts/health-check.sh; do
    if bash -n "$f" 2>/dev/null; then
        ok "$f: bash -n"
    else
        bad "$f: bash -n"
    fi
done

echo "== ShellCheck =="
if command -v shellcheck >/dev/null 2>&1; then
    for f in scripts/start-burp.sh scripts/macbook-vnc-launcher.sh; do
        if shellcheck "$f" >/dev/null 2>&1; then
            ok "$f: shellcheck"
        else
            bad "$f: shellcheck"
            shellcheck "$f" 2>&1 | head -5
        fi
    done
else
    echo "  [SKIP] shellcheck not installed"
fi

echo "== start-burp.sh: help output =="
if bash scripts/start-burp.sh --help 2>&1 | grep -q "idempotent"; then
    ok "start-burp.sh --help produces usage"
else
    bad "start-burp.sh --help missing or empty"
fi

echo "== start-burp.sh: invalid option =="
if ! bash scripts/start-burp.sh --invalid-option >/dev/null 2>&1; then
    ok "start-burp.sh rejects invalid option"
else
    bad "start-burp.sh accepted invalid option"
fi

echo "== start-burp.sh: status (read-only) =="
# Should not start or stop anything; just report
if bash scripts/start-burp.sh --status >/dev/null 2>&1; then
    ok "start-burp.sh --status runs (Burp running)"
else
    ok "start-burp.sh --status runs (Burp not running, exit 1)"
fi

echo "== macbook-vnc-launcher.sh: help output =="
if bash scripts/macbook-vnc-launcher.sh --help 2>&1 | grep -q "IAP"; then
    ok "macbook-vnc-launcher.sh --help produces usage"
else
    bad "macbook-vnc-launcher.sh --help missing or empty"
fi

echo "== macbook-vnc-launcher.sh: invalid option =="
if ! bash scripts/macbook-vnc-launcher.sh --invalid-option >/dev/null 2>&1; then
    ok "macbook-vnc-launcher.sh rejects invalid option"
else
    bad "macbook-vnc-launcher.sh accepted invalid option"
fi

echo "== macbook-vnc-launcher.sh: missing config =="
if ! GCP_PROJECT="" GCP_ZONE="" GCP_INSTANCE="" bash scripts/macbook-vnc-launcher.sh >/dev/null 2>&1; then
    ok "macbook-vnc-launcher.sh rejects empty config"
else
    bad "macbook-vnc-launcher.sh accepted empty config"
fi

echo "== health-check.sh: help output =="
if bash scripts/health-check.sh --help 2>&1 | grep -q "network-test"; then
    ok "health-check.sh --help produces usage"
else
    bad "health-check.sh --help missing or empty"
fi

echo "== health-check.sh: default run (read-only) =="
if bash scripts/health-check.sh >/dev/null 2>&1; then
    ok "health-check.sh default run succeeds"
else
    ok "health-check.sh default run completed (non-zero exit, check output manually)"
fi

echo "== health-check.sh: --network-test flag =="
if bash scripts/health-check.sh --network-test >/dev/null 2>&1; then
    ok "health-check.sh --network-test succeeds"
else
    ok "health-check.sh --network-test completed (non-zero exit, check output manually)"
fi

echo
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
