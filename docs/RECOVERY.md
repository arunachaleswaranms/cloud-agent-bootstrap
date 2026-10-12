# Recovery runbook

Nothing on the VM is stateful except `~/.config/agent/secrets.env` and
your `~/workspace/` research. Everything else is reproducible from this
repository.

## Backup (do this once, keep outside git)

```bash
tar czf agent-backup-$(date +%F).tar.gz \
  -C "$HOME" .config/agent/secrets.env workspace
gpg -c agent-backup-*.tar.gz   # or age / veracrypt
```

Store the encrypted archive outside this repository.

## Lost / destroyed VM

1. Recreate the VM per [docs/GCP_SETUP.md](GCP_SETUP.md) (Ubuntu 24.04,
   e2-standard-2, no public SSH).
2. `bash bootstrap.sh`.
3. Restore `secrets.env` from backup (mode 600).
4. Re-authenticate manually: `gh auth login`, `sudo tailscale up`,
   `opencode auth login`.
5. `bash scripts/health-check.sh`.

## Component recovery

| Symptom | Fix |
| --- | --- |
| Swap missing | `bash scripts/setup-swap.sh` |
| `docker: permission denied` | Log out/in once, or `newgrp docker` |
| `gh` not logged in | `gh auth login` |
| Tailscale not connected | `sudo tailscale up` |
| OpenCode auth expired | `opencode auth login` |
| Chromium missing | `playwright install --with-deps chromium` |
| Full re-provision | Re-run `bash bootstrap.sh` (idempotent) |

## Credential rotation

If a credential leaks (it should not — nothing here is committed):

1. Revoke it at the provider (GitHub: Settings -> Developer settings ->
   Personal access tokens).
2. Re-run the relevant manual auth step.
3. Rotate GCP metadata SSH keys with `gcloud compute instances
   remove-metadata` / `add-metadata` (or the project-level
   `project-info` equivalents).
4. Re-register the Tailscale node: `sudo tailscale up --reset`.
