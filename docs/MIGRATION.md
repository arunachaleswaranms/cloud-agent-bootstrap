# Migration guide

Use this when moving the agent to a new VM, or importing an existing
machine's state into this bootstrap.

## On the old machine

Back up the following **outside git** — never commit these:

- `~/.config/agent/secrets.env` (mode 600)
- `~/.tmux.conf` if customized
- `~/.config/opencode/` (auth + config) if present
- `~/.config/gh/hosts.yml` (GitHub CLI login)
- `~/workspace/` research artifacts
- Tailscale state (`/var/lib/tailscale/`) — or simply re-authenticate on
  the new VM

Recommended: encrypt the archive (e.g. `gpg -c` or `age`) and store it
outside this repository.

## On the new machine (Ubuntu 24.04 LTS x86_64)

```bash
git clone <this-repo> ~/cloud-agent-bootstrap
cd ~/cloud-agent-bootstrap
bash bootstrap.sh
```

Then restore secrets and re-authenticate:

```bash
chmod 600 ~/.config/agent/secrets.env
gh auth login                     # manual
sudo bash scripts/install-tailscale.sh && sudo tailscale up   # manual
opencode auth login               # manual
bash scripts/health-check.sh
```

## Notes

- Do **not** release-upgrade the old VM to migrate it. Rebuild on
  Ubuntu 24.04 and migrate the data.
- GCP metadata SSH keys are per-VM: add the new key on the new VM
  instead of copying key files; rotate rather than reuse.
- Security tools (`INSTALL_SECURITY_TOOLS=1`) are not migrated;
  reinstall them on the target.
- Tailscale: re-running `sudo tailscale up` on the new VM registers a
  new node; remove the old node from the Tailscale admin console.
