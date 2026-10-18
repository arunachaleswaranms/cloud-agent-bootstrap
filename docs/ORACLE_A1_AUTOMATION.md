# Oracle A1 Always Free capacity automation (Hyderabad)

**Status: code and tests only. Nothing is installed or enabled by this repository.**
The existing GCP Ubuntu 24.04 x86_64 VM is the poller host; the target is an
ARM64 `VM.Standard.A1.Flex` instance in the tenancy's **home region**,
`ap-hyderabad-1`. This module is independent of OpenCode/Burp/MCP and does not
change `bootstrap.sh`.

## Architecture / state transitions

```text
GCP Ubuntu VM -- user systemd timer (5min + jitter)
       |
       v
  local filesystem lock + config and two-factor opt-in
       |
       +-- dry run / disabled ------------------------> NO WRITES
       |
       +-- state=done or halt ------------------------> NO WRITES
       |
       +-- state=pending --> OCI GetInstance ----------> verify RUNNING;
       |                                                 then mark done and alert
       |
       +-- read OCI ListInstances in target compartment
              |
              +-- target exists --> track it, don't create another
              +-- other A1 exists --> halt for quota review
              +-- preflight failure --> halt; notify
              +-- no matching instance
                     |
                     +-- OCI LaunchInstance, A1 only, no SDK retry
                            +-- out-of-host-capacity -> retry next timer
                            +-- OCI 429 -> cooldown 30 min
                            +-- success -> record OCID as pending
                            +-- everything else / ambiguous -> halt
```

Systemd user timer runs **one attempt per activation**, not a tight polling
loop. The lock prevents concurrency. `state.json` tracks accepted launches and
stops duplicates, including after restart. On an ambiguous timeout the script
**halts** until an operator reconciles OCI state. Ordinary capacity rejections
are retried. Status is verified as `RUNNING` on a subsequent timer cycle.
Optional Telegram notification is sent on `RUNNING` or fatal halt.

> Credit: approach inspired by
> [alexpua/oci-arm-catcher](https://github.com/alexpua/oci-arm-catcher).
> This implementation is independently written, scoped to one region, and
> intentionally handles ambiguous errors and quota failures more strictly.

## Billing and access safeguards

- Oracle's June 2026 [Always Free page](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm)
  documents **1,500 A1 OCPU-hours and 9,000 GB-hours per month**; for Always
  Free tenancies this is equivalent to **2 OCPU / 12 GB**. The code refuses
  configurations larger than these, but **does not prove that all other
  compartments or concurrent workloads are within quota**.
- Before opting in, verify Hyderabad is the tenancy home region; calculate
  existing A1 usage across **all compartments**; review boot volume size
  and total Always Free block-volume allowance. Check current account pricing
  and service limits in OCI. Set `OCI_ACK_ACCOUNT_QUOTA=true` only after this.
- Use a dedicated least-privilege OCI API user/group restricted to a dedicated
  compartment, with only necessary instance/image/network permissions. Oracle
  `LaunchInstance` requires `manage instances` plus `read instance-images`,
  `use vnics`, `use subnets`, and sometimes `use network-security-groups` /
  other related permissions. Review
  [Oracle IAM policy reference](https://docs.oracle.com/en-us/iaas/Content/Identity/Reference/corepolicyreference.htm).
- OCI credentials (`~/.oci/config`, API private key) are **never** committed.
  Keep private key mode `0600`, config mode `0600` and environment file mode `0600`.
- Default `OCI_ASSIGN_PUBLIC_IP=false`. To obtain a public IP, configure a
  restricted NSG / security list and SSH management path **before** opting in.
  Never expose SSH to `0.0.0.0/0`.
- Never use GitHub Actions or ChatGPT task reminders to run the cloud write.
  The poller runs under your own GCP VM identity and explicit Oracle account.

## One-time prerequisites (manual, interactive)

1. Install official OCI CLI on GCP Ubuntu under the normal `msapredator` user
   (follow Oracle's pinned, verified installer guidance, not a pipe-to-shell
   untrusted bootstrap), and confirm `command -v oci`.
2. In Oracle console create an API signing key for a **dedicated, scoped** IAM
   user, and configure it locally with `oci setup config`; verify
   `oci --region ap-hyderabad-1 iam region list` works. Do not paste the
   private key, fingerprints or Telegram bot token into chat or GitHub.
3. Using the Oracle console or read-only OCI CLI commands, identify the
   tenancy home region, compartment OCID, availability domain (typically
   one in Hyderabad), **ARM-compatible Ubuntu image** OCID, subnet OCID,
   and the SSH public key file. Set up the subnet/NSG and routing ahead of
   time. Confirm `oci --region ap-hyderabad-1 compute instance list
   --compartment-id <OCID> --all` succeeds.
4. Clone this repo at `~/cloud-agent-bootstrap` (or edit `ExecStart` in the
   service unit to match its real location), and fill in the local config:

   ```bash
   mkdir -p ~/.config
   cp ~/cloud-agent-bootstrap/config/oracle/a1-catcher.env.example \
      ~/.config/oracle-a1-catcher.env
   chmod 600 ~/.config/oracle-a1-catcher.env
   nano ~/.config/oracle-a1-catcher.env
   ```

   **Note:** Replace `OCI_SSH_PUBLIC_KEY_FILE` with an actual **absolute path**.
   The `%h` specifier is only valid inside systemd unit files, not inside
   EnvironmentFile values.

## Local validation and hermetic tests

Use a shell to load the environment safely (local trusted config only):

```bash
set -a
. ~/.config/oracle-a1-catcher.env
set +a
python3 ~/cloud-agent-bootstrap/scripts/oracle/a1_catcher.py
python3 -m unittest discover -s ~/cloud-agent-bootstrap/tests \
  -p 'test_oracle_a1_catcher.py' -v
```

Dry run validates configuration only; it never contacts OCI or creates a VM.
Review OCIDs, shape-compatible image, region, account-wide quota, network
security and IAM permissions before the first live attempt.

## Enable timer after review (not automatically)

`OCI_ENABLE_LAUNCH=true` and `OCI_ACK_ACCOUNT_QUOTA=true` are **both** required.
Leave both at `false` until preflight review is complete.

```bash
mkdir -p ~/.config/systemd/user
cp ~/cloud-agent-bootstrap/systemd/oracle-a1-catcher.* \
   ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now oracle-a1-catcher.timer
systemctl --user list-timers oracle-a1-catcher.timer
journalctl --user -u oracle-a1-catcher.service -n 60 --no-pager
```

For user services to continue after logout/reboot, an administrator must
explicitly enable user lingering: `sudo loginctl enable-linger msapredator`.
This does **not** start the automation by itself; enabling the timer does.

## Stop, reconcile and recover

```bash
systemctl --user disable --now oracle-a1-catcher.timer
journalctl --user -u oracle-a1-catcher.service -n 100 --no-pager
cat ~/.local/state/oci-a1-catcher/state.json
```

If status is `done` or `halt`, the timer will not launch more instances.
Before resetting state, **manually list instances in OCI** across relevant
compartments and reconcile any accepted launch. Never blindly delete
`state.json`, particularly after a timeout or permission failure.

If capacity does not appear for days, that is normal. There is no guaranteed
capacity or reservation from this automation. The GCP VM must remain active.
