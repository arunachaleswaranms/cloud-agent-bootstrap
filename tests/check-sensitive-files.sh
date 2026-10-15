#!/usr/bin/env bash
#
# tests/check-sensitive-files.sh — guard against committing secrets, Burp
# binaries, CA material, browser sessions, captured traffic or vendored
# third-party repositories.
#
# Two layers:
#   1. Sensitive-path check over every git-tracked file.
#   2. Secret-value check over the text content of tracked files.
#
# This is a lightweight, self-contained guard. It is NOT a vulnerability
# scanner and does not attempt to find vulnerabilities in dependencies.
#
# Usage: tests/check-sensitive-files.sh
# Exit:  0 = clean, 1 = findings

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

# The scanner necessarily contains the very patterns it looks for.
SELF="tests/check-sensitive-files.sh"

failures=0
finding() {
    printf '  [FAIL] %s\n' "$1"
    failures=$((failures + 1))
}

echo "== Sensitive paths =="

# Anything matching these must never be tracked.
path_patterns='^tools/burp/|^tools/burp-mcp-extended/|(^|/)\.BurpSuite/|burp.*\.jar$|burp-ca\.(pem|der|cer|crt)$|burp_?licen[sc]e|\.lic$|^browser-profile/|(^|/)browser-data/|\.playwright-mcp/|playwright/\.auth/|(^|/)cookies?\.json$|\.netrc$|\.pcap(ng)?$|\.har$|(^|/)(id_rsa|id_ed25519|id_ecdsa|id_dsa)\b|\.(pem|key|p12|pfx|ppk)$|cert[89]\.db$|key[34]\.db$|(^|/)node_modules/|(^|/)vendor/|(^|/)third-party/|(^|/)\.gcloud/|(^|/)\.aws/|(^|/)secrets?/|(^|/)credentials?/|(^|/)evidence/|(^|/)burp-transfer/|burpsuite_project/|\.session\.json$'

tracked="$(git ls-files)"

if [ -z "$tracked" ]; then
    echo "  [FAIL] no tracked files found — is this a git repository?"
    exit 1
fi

while IFS= read -r f; do
    [ -n "$f" ] || continue
    if printf '%s\n' "$f" | grep -Eq "$path_patterns"; then
        finding "sensitive path is tracked: $f"
    fi
done <<EOF
$tracked
EOF

# Nested third-party git repositories (a vendored repo would not appear in
# `git ls-files`, so also check the working tree).
nested="$(find . -mindepth 2 -name .git -not -path './.git/*' 2>/dev/null)"
if [ -n "$nested" ]; then
    finding "nested git repository present in the working tree:"
    printf '%s\n' "$nested" | sed 's/^/        /'
fi

echo "== Secret values =="

# High-confidence credential shapes. These are matched against tracked files
# with the scanner's own source excluded.
secret_patterns='BEGIN (RSA |EC |DSA |OPENSSH |PGP )?PRIVATE KEY|AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{30,}|gho_[A-Za-z0-9]{30,}|ghu_[A-Za-z0-9]{30,}|ghs_[A-Za-z0-9]{30,}|ghr_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{50,}|AIza[0-9A-Za-z_-]{35}|xox[abprs]-[0-9A-Za-z-]{10,}|sk-[A-Za-z0-9]{32,}|glpat-[A-Za-z0-9_-]{20,}'

# Same-shaped placeholder values are fine; they are documented as examples.
placeholder_pattern='YOUR_[A-Z_]*|<[A-Z_]+>|example|EXAMPLE|placeholder|REDACTED|xxxx|\.\.\.|\*\*\*'

while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ "$f" = "$SELF" ] && continue
    [ -f "$f" ] || continue
    # Skip binaries.
    if ! grep -Iq . "$f" 2>/dev/null; then
        continue
    fi
    matches="$(grep -nEo "$secret_patterns" "$f" 2>/dev/null || true)"
    [ -n "$matches" ] || continue
    while IFS= read -r m; do
        [ -n "$m" ] || continue
        if printf '%s\n' "$m" | grep -Eq "$placeholder_pattern"; then
            continue
        fi
        # Report file and line only — never echo the matched secret value.
        line_no="${m%%:*}"
        finding "possible secret in $f (line $line_no)"
    done <<EOF
$matches
EOF
done <<EOF
$tracked
EOF

echo "== Placeholder safety =="
# config/secrets.env.example must not contain real-looking values.
if [ -f config/secrets.env.example ]; then
    bad_lines="$(grep -nE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=.+' config/secrets.env.example || true)"
    if [ -n "$bad_lines" ]; then
        while IFS= read -r l; do
            [ -n "$l" ] || continue
            if ! printf '%s\n' "$l" | grep -Eq "$placeholder_pattern"; then
                finding "config/secrets.env.example line ${l%%:*} has a non-placeholder value"
            fi
        done <<EOF
$bad_lines
EOF
    fi
fi

echo
if [ "$failures" -eq 0 ]; then
    echo "check-sensitive-files: clean (0 findings)"
    exit 0
fi
echo "check-sensitive-files: ${failures} finding(s)"
exit 1