#!/usr/bin/env bash
#
# Post-bootstrap health check for the agent VM.
# Exits 0 when no FAILs remain; warnings do not block.
set -uo pipefail

PASS=0; WARN=0; FAIL=0
ok()   { echo "  [OK]   $*"; PASS=$((PASS + 1)); }
warn() { echo "  [WARN] $*"; WARN=$((WARN + 1)); }
fail() { echo "  [FAIL] $*"; FAIL=$((FAIL + 1)); }
info() { echo "  [INFO] $*"; }

echo "== OS =="
if [ -r /etc/os-release ]; then . /etc/os-release; fi
if [ "${ID:-}" = "ubuntu" ] && [ "${VERSION_ID:-}" = "24.04" ]; then
    ok "OS: ${PRETTY_NAME:-Ubuntu 24.04 LTS}"
else
    warn "OS: ${PRETTY_NAME:-unknown} (supported baseline: Ubuntu 24.04 LTS)"
fi

arch="$(uname -m)"
if [ "$arch" = "x86_64" ]; then ok "Architecture: $arch"; else warn "Architecture: $arch (validated: x86_64)"; fi

mem_kb="$(awk '/^MemTotal:/{print $2}' /proc/meminfo)"
mem_gib=$(( (mem_kb + 524288) / 1048576 ))
if [ "$mem_gib" -ge 8 ]; then ok "Memory: ~${mem_gib} GiB"
elif [ "$mem_gib" -ge 4 ]; then warn "Memory: ~${mem_gib} GiB (recommended: 8 GiB)"
else warn "Memory: ~${mem_gib} GiB (too low)"; fi

swap_kb="$(awk '/^SwapTotal:/{print $2}' /proc/meminfo)"
swap_gib=$(( (swap_kb + 524288) / 1048576 ))
# A 4 GiB swapfile reports 4194300 kB (4 KiB swap header); allow 16 MiB slack.
if [ "$swap_kb" -ge $((4 * 1024 * 1024 - 16384)) ]; then ok "Swap: ~${swap_gib} GiB"
else fail "Swap: ~${swap_gib} GiB (expected >= 4 GiB; run scripts/setup-swap.sh)"; fi
if grep -q '/swapfile' /etc/fstab 2>/dev/null; then ok "Swap persisted in /etc/fstab"
else warn "Swap not in /etc/fstab"; fi

echo "== Docker =="
if command -v docker >/dev/null 2>&1; then
    ok "Docker: $(docker --version 2>/dev/null)"
    if docker info >/dev/null 2>&1; then ok "Docker daemon: reachable"
    else warn "Docker daemon not reachable (log out/in once after usermod)"; fi
    if docker compose version >/dev/null 2>&1; then ok "Docker compose plugin: installed"
    else warn "Docker compose plugin missing"; fi
else warn "Docker not installed (run: bash bootstrap.sh)"; fi

echo "== Toolchains =="
if command -v node >/dev/null 2>&1; then
    v="$(node --version 2>/dev/null)"
    case "$v" in v22.*) ok "Node.js: $v";; *) warn "Node.js: $v (validated: 22.x)";; esac
else warn "Node.js not installed"; fi
command -v npm >/dev/null 2>&1 && ok "npm: $(npm --version 2>/dev/null)" || warn "npm not installed"

if command -v go >/dev/null 2>&1; then
    v="$(go version 2>/dev/null)"
    case "$v" in *go1.22.*) ok "Go: $v";; *) warn "Go: $v (validated: go1.22.2)";; esac
else warn "Go not installed"; fi

if command -v gh >/dev/null 2>&1; then
    ok "GitHub CLI: $(gh --version 2>/dev/null | head -n1)"
    if gh auth status >/dev/null 2>&1; then ok "GitHub CLI: authenticated"
    else warn "GitHub CLI: not authenticated (run: gh auth login)"; fi
else warn "GitHub CLI not installed (run: bash scripts/install-gh.sh)"; fi

if command -v opencode >/dev/null 2>&1; then
    v="$(opencode --version 2>/dev/null)"
    if [ "$v" = "1.18.35" ]; then ok "OpenCode: $v (pinned)"
    else fail "OpenCode: $v (pinned: 1.18.35)"; fi
else warn "OpenCode not installed (run: bash scripts/install-opencode.sh)"; fi

command -v tmux >/dev/null 2>&1 && ok "tmux: $(tmux -V 2>/dev/null)" || warn "tmux not installed"

if command -v playwright >/dev/null 2>&1; then
    ok "Playwright: $(playwright --version 2>/dev/null)"
    if compgen -G "$HOME/.cache/ms-playwright/chromium-*" >/dev/null 2>&1; then
        ok "Chromium: installed"
    else warn "Chromium not installed (run: playwright install --with-deps chromium)"; fi
else warn "Playwright not installed (run: bash scripts/install-playwright.sh)"; fi

echo "== Tailscale =="
if command -v tailscale >/dev/null 2>&1; then
    if tailscale status >/dev/null 2>&1; then ok "Tailscale: connected"
    else warn "Tailscale: not connected (run: sudo tailscale up)"; fi
else info "Tailscale not installed (optional; run: sudo bash scripts/install-tailscale.sh)"; fi

echo "== Java / Burp Suite =="
if command -v java >/dev/null 2>&1; then
    jver="$(java -version 2>&1 | head -1 | sed 's/.*version "\([^"]*\)".*/\1/')"
    case "$jver" in 25.*) ok "Java: OpenJDK $jver";; *) warn "Java: $jver (validated: OpenJDK 25)";; esac
else
    warn "Java not installed (run: sudo apt install openjdk-25-jre)"
fi

BURP_JAR="${BURP_JAR:-$HOME/tools/burp/burpsuite_desktop_v2026.9.1.jar}"
if [ -f "$BURP_JAR" ]; then
    if pgrep -f "burpsuite_desktop_v.*\.jar" >/dev/null 2>&1; then
        ok "Burp Suite: running"
    else
        warn "Burp Suite: installed but not running (start with: bash scripts/start-burp.sh)"
    fi
else
    warn "Burp Suite: not installed at $BURP_JAR"
fi

echo "== VNC / XFCE =="
if pgrep -x Xtigervnc >/dev/null 2>&1; then
    vnc_disp="$(pgrep -a Xtigervnc 2>/dev/null | grep -oP ':\d+' | head -1)"
    ok "TigerVNC: running (display ${vnc_disp:-unknown})"
else
    warn "TigerVNC: not running (start with: vncserver :1 -localhost yes)"
fi

if [ -n "${DISPLAY:-}" ] || [ -f "$HOME/.Xauthority" ]; then
    if DISPLAY=:1 xdpyinfo >/dev/null 2>&1; then
        ok "XFCE display :1: reachable"
    else
        warn "XFCE display :1: not reachable"
    fi
else
    info "No X display configured"
fi

echo "== Network ports =="
for port_check in 8080 9876 9877; do
    # Match 127.0.0.1:PORT, [::ffff:127.0.0.1]:PORT, and [::1]:PORT
    if ss -tlnH 2>/dev/null | grep -qE "(127\.0\.0\.1|\[::ffff:127\.0\.0\.1\]|\[::1\]):?${port_check}\b"; then
        ok "Port ${port_check}: listening (localhost)"
    elif ss -tlnH 2>/dev/null | grep -qE ":${port_check}\b"; then
        warn "Port ${port_check}: listening on non-loopback interface"
    else
        warn "Port ${port_check}: not listening"
    fi
done

echo "== MCP connections =="
if command -v opencode >/dev/null 2>&1; then
    mcp_output="$(opencode mcp list 2>/dev/null || true)"
    if [ -n "$mcp_output" ]; then
        for mcp_name in "Burp" "Burp_extended" "playwright"; do
            if echo "$mcp_output" | grep -q "✓.*${mcp_name}"; then
                ok "MCP ${mcp_name}: connected"
            else
                fail "MCP ${mcp_name}: not connected"
            fi
        done
    else
        warn "opencode mcp list: no output"
    fi
else
    info "opencode not installed; MCP check skipped"
fi

echo "== HTTPS interception =="
NSS_DB="$HOME/tools/playwright/isolated-home/.pki/nssdb/cert9.db"
BURP_CA_PEM="$HOME/tools/playwright/burp-ca.pem"

if [ -f "$NSS_DB" ]; then
    ok "Isolated NSS trust store: present"
else
    warn "Isolated NSS trust store: not found ($NSS_DB)"
fi

if [ -f "$BURP_CA_PEM" ]; then
    if openssl x509 -in "$BURP_CA_PEM" -noout 2>/dev/null; then
        ok "Burp CA PEM: valid"
    else
        warn "Burp CA PEM: invalid or corrupted"
    fi
else
    warn "Burp CA PEM: not found ($BURP_CA_PEM)"
fi

# Read-only HTTPS proxy verification against approved benign endpoint
if command -v curl >/dev/null 2>&1 && [ -f "$BURP_CA_PEM" ]; then
    https_code="$(curl -s --noproxy "" \
        --proxy http://127.0.0.1:8080 \
        --cacert "$BURP_CA_PEM" \
        --max-time 15 \
        -o /dev/null -w '%{http_code}' \
        https://example.com/ 2>/dev/null || echo "000")"
    if [ "$https_code" = "200" ] || [ "$https_code" = "301" ] || [ "$https_code" = "302" ]; then
        ok "HTTPS via Burp proxy: verified (HTTP $https_code)"
    else
        fail "HTTPS via Burp proxy: failed (HTTP $https_code)"
    fi
else
    info "curl or Burp CA not available; HTTPS check skipped"
fi

echo "== Security posture =="
if command -v ss >/dev/null 2>&1; then
    exposed="$(ss -tlnH 'sport = :22' 2>/dev/null | awk '{print $4}' | grep -Ec '^(0\.0\.0\.0|\*):22$' || true)"
    if [ "${exposed:-0}" -gt 0 ]; then
        warn "SSH is listening on 0.0.0.0:22 - never expose SSH publicly; restrict to IAP 35.235.240.0/20 or a tailnet"
    else
        ok "SSH not listening on 0.0.0.0:22"
    fi

    # Check MCP ports are NOT exposed publicly
    for mcp_port in 8080 9876 9877 5901; do
        public="$(ss -tlnH "sport = :${mcp_port}" 2>/dev/null | grep -v '127.0.0.1' | grep -vc '\[::1\]' || true)"
        if [ "$public" -gt 0 ]; then
            warn "Port ${mcp_port}: exposed on non-loopback interface"
        else
            ok "Port ${mcp_port}: loopback-only"
        fi
    done
else
    info "ss not available; SSH exposure check skipped"
fi

echo
echo "Summary: ${PASS} ok, ${WARN} warnings, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
