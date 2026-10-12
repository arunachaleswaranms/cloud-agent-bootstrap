# GCP setup

Target VM (validated): **e2-standard-2** (2 vCPU / 8 GiB RAM), Ubuntu 24.04
LTS x86_64 image, >= 50 GiB boot disk, 4 GiB swap (created by bootstrap).

## 1. Create the VM

```bash
gcloud compute instances create agent-vm \
  --zone=<zone> \
  --machine-type=e2-standard-2 \
  --image-family=ubuntu-2404-lts-amd64 \
  --image-project=ubuntu-os-cloud \
  --boot-disk-size=50GB \
  --boot-disk-type=pd-balanced \
  --tags=agent-vm
```

Add `--no-address` if you want no ephemeral public IP at all (Tailscale /
IAP only).

## 2. SSH access — never 0.0.0.0/0

> **WARNING: never create a firewall rule allowing `0.0.0.0/0` on TCP/22.**
> The agent VM must not be reachable from the public internet over SSH.
> Reopening public SSH is the single largest avoidable exposure on this
> machine. Keep it disabled permanently.

Remote access, in order of preference:

1. **Tailscale — the normal remote-access path.** After bootstrap, run
   `sudo bash scripts/install-tailscale.sh` (it ends with a manual
   `sudo tailscale up`), then SSH over the tailnet address or use
   `tailscale ssh agent-vm`. No inbound firewall rules are needed.
2. **GCP IAP TCP forwarding** — `gcloud compute ssh --tunnel-through-iap
   agent-vm`. IAP's source range is **`35.235.240.0/20` (TCP/22)**. If any
   sshd ingress rule exists, restrict it to exactly this range:

   ```bash
   gcloud compute firewall-rules create allow-ssh-iap \
     --direction=INGRESS \
     --action=ALLOW \
     --rules=tcp:22 \
     --source-ranges=35.235.240.0/20 \
     --target-tags=agent-vm
   ```

   (The VM must carry `--tags=agent-vm` for the rule to apply.)

## 3. SSH keys: metadata-managed, not authorized_keys

With **OS Login disabled** (the default for this setup), prefer
**GCP metadata-managed SSH keys** over manually editing
`~/.ssh/authorized_keys`:

```bash
# Per-instance key
gcloud compute instances add-metadata agent-vm \
  --metadata ssh-keys="arunachaleswaran:ssh-ed25519 AAAA... comment"

# Or project-wide
gcloud compute project-info add-metadata \
  --metadata ssh-keys="arunachaleswaran:ssh-ed25519 AAAA... comment"
```

Then connect with `gcloud compute ssh --tunnel-through-iap agent-vm`.

Why metadata keys instead of hand-editing `authorized_keys`:

- They survive VM recreate/repair flows and are auditable in one place.
- Deleting the key from metadata revokes access immediately.
- The guest agent refreshes metadata keys periodically; manual
  `authorized_keys` edits can be overwritten or conflict with that
  propagation.

If you must log in interactively (serial console), use a temporary
metadata key and remove it afterwards.

## 4. Swap

The Ubuntu 24.04 image ships without swap. `bootstrap.sh` creates an
idempotent 4 GiB file swap via `scripts/setup-swap.sh`, persisted in
`/etc/fstab`. Re-run that script any time swap is missing.

## 5. After bootstrap

```bash
gh auth login                     # GitHub authentication (manual)
sudo tailscale up                 # Tailscale authentication (manual)
opencode auth login               # OpenCode authentication (manual)
bash scripts/health-check.sh      # verify the machine
```

GitHub auth, Tailscale auth, and OpenCode auth are intentionally manual
post-bootstrap steps — they require interactive credentials and must not
be scripted or committed.
