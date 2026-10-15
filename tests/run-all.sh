#!/usr/bin/env bash
#
# tests/run-all.sh — run every regression suite in this repository.
#
# The suites are hermetic: they use sandboxed runtime directories, a fake
# `gcloud`, a fake JVM and a fake `xdpyinfo`. They require no live GCP
# resources, no Burp Suite, no API credentials and no external targets.
#
# Usage:
#   tests/run-all.sh

set -uo pipefail

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SUITE_DIR/.." && pwd)"

SUITES=(
    "$REPO_ROOT/tests/test-vnc-launcher.sh"
    "$REPO_ROOT/tests/test-start-burp.sh"
    "$REPO_ROOT/scripts/test-launchers.sh"
)

failed=0

for suite in "${SUITES[@]}"; do
    printf '\n########################################################\n'
    printf '# %s\n' "${suite#"$REPO_ROOT"/}"
    printf '########################################################\n'
    if bash "$suite"; then
        :
    else
        failed=$((failed + 1))
    fi
done

printf '\n########################################################\n'
if [ "$failed" -eq 0 ]; then
    printf '# ALL SUITES PASSED\n'
    printf '########################################################\n'
    exit 0
fi
printf '# %d SUITE(S) FAILED\n' "$failed"
printf '########################################################\n'
exit 1