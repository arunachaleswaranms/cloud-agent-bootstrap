# cloud-agent-bootstrap

Reproducible provisioning for a cloud-based security-research agent VM.

Supported baseline: **Ubuntu 24.04 LTS (noble) x86_64**, validated on GCP
`e2-standard-2` (2 vCPU / 8 GiB RAM, 4 GiB swap).

> Do **not** release-upgrade this VM or this repo's baseline to Ubuntu
> 26.04. If a newer baseline is required, rebuild the VM from a new image
> and re-validate this repository.

## Validated runtime

| Component | Version |
| --- | --- |
| Ubuntu | 24.04 LTS x86_64 |
| GCP machine | e2-standard-2 (2 vCPU, 8 GiB RAM) |
| Swap | 4 GiB file swap |
| Docker | 29.9.0 / Compose plugin 5.6.0 |
| Node.js | 22.23.3 / npm 10.9.9 |
| Go | 1.22.2 |
| GitHub CLI | distro `gh` (noble) |
| OpenCode | 1.18.35 (pinned) |
| Burp Suite | Community 2026.9.1 |
| Java | OpenJDK 25.0.4.1 |
| Burp proxy | 127.0.0.1:8080 |
| Official Burp MCP | 127.0.0.1:9876 |
| Extended Burp MCP | v3.3.0 (gRPC 127.0.0.1:9877) |
| Playwright | 1.64.0 (Chromium, headless) |
| Browser proxy | 127.0.0.1:8080 (Burp) |
| Burp CA | Isolated NSS trust store |
| Desktop | XFCE + TigerVNC, display :1 |
| Remote GUI | Google Cloud IAP SSH tunnel from MacBook |
| Session persistence | tmux |

## Quick start

```bash
git clone <this-repo> ~/cloud-agent-bootstrap
cd ~/cloud-agent-bootstrap
bash bootstrap.sh
```

`bootstrap.sh` is idempotent and installs: base apt packages, 4 GiB swap,
Docker, Node.js 22, Go 1.22, GitHub CLI, OpenCode (pinned 1.18.35),
Playwright + Chromium, a tmux config, workspace directories, and a secure
secrets directory (`~/.config/agent/secrets.env`, mode 600).

Optional security tools (nuclei, httpx, subfinder, ffuf) require an opt-in:

```bash
INSTALL_SECURITY_TOOLS=1 bash bootstrap.sh
# or later:
INSTALL_SECURITY_TOOLS=1 bash scripts/install-security-tools.sh
```

> Security tooling in this repo is for **authorized bug-bounty / VDP
> testing only**, against assets you have written permission to test.

## Manual post-bootstrap steps

These require interactive credentials and cannot be scripted safely:

1. Log out and back in once (Docker group membership).
2. `gh auth login` — GitHub authentication (manual).
3. `sudo bash scripts/install-tailscale.sh`, then `sudo tailscale up` —
   Tailscale authentication (manual). Tailscale is the normal
   remote-access path.
4. `opencode auth login` — OpenCode authentication (manual).
5. Populate `~/.config/agent/secrets.env` and `source` it in your shell.

## Remote access

- **Preferred:** Tailscale (or GCP IAP TCP forwarding).
- **Never** open SSH to `0.0.0.0/0`. See [docs/GCP_SETUP.md](docs/GCP_SETUP.md).
- If sshd runs, restrict ingress to the GCP IAP range `35.235.240.0/20`
  (TCP/22).
- Prefer GCP metadata-managed SSH keys over hand-editing
  `~/.ssh/authorized_keys`.

## Repository layout

```
bootstrap.sh                  one-shot, idempotent provisioning
scripts/                      individual installer + operational scripts
  start-burp.sh               idempotent Burp launcher
  macbook-vnc-launcher.sh     IAP tunnel + Screen Sharing from macOS
  health-check.sh             read-only infrastructure health check
config/                       tmux.conf, opencode.example.json, secrets.env.example
packages/                     apt.txt, npm.txt, go-tools.txt inventories
docs/
  GCP_SETUP.md                GCP VM creation and IAP access
  MIGRATION.md                Migrating to a new VM
  RECOVERY.md                 Recovery runbook
  BURP_SUITE.md               Burp Suite setup and operation
  BURP_MCP.md                 Official Burp MCP (port 9876)
  BURP_MCP_EXTENDED.md        Extended Burp MCP v3.3.0 (port 9877)
  PLAYWRIGHT.md               Playwright Chromium MCP
  HTTPS_INTERCEPTION.md       Burp CA, NSS trust, HTTPS verification
  VNC_REMOTE_ACCESS.md        TigerVNC, IAP tunnel, MacBook launcher
  AI_SECURITY_ROADMAP.md      Future assessment workflow
```

## MCP integrations

Three MCP servers are configured in OpenCode:

1. **Official Burp MCP** — remote HTTP at `http://127.0.0.1:9876`
2. **Extended Burp MCP** — local stdio via `~/.local/bin/burp-mcp serve`
3. **Playwright MCP** — local launcher at `~/tools/playwright/start-mcp.sh`

See [config/opencode.example.json](config/opencode.example.json) for a
sanitized template.

## Verification

```bash
bash scripts/health-check.sh
```

## Secrets policy

This repository never stores real API keys, GitHub tokens, SSH private
keys, cookies, browser sessions, OpenCode auth, Tailscale credentials, or
cloud credentials. Templates end in `.example`. `.gitignore` covers common
credential patterns; review `git diff` before committing.
