# VNC and GCP Remote Access

## Starting and verifying TigerVNC

TigerVNC provides the XFCE desktop on display `:1`.

Start the VNC server:

```bash
vncserver :1 -localhost yes -geometry 1280x800 -depth 24
```

The `-localhost yes` flag ensures VNC only listens on `127.0.0.1:5901`.
Never remove this flag.

Verify:

```bash
ss -tlnp | grep 5901
# Should show: 127.0.0.1:5901
```

Check the desktop is running:

```bash
DISPLAY=:1 xdpyinfo | head -3
```

## XFCE display :1

The XFCE desktop runs on display `:1`. To start it manually:

```bash
DISPLAY=:1 startxfce4 &
```

The desktop persists across SSH disconnects. Attach with VNC or use
`DISPLAY=:1` for GUI applications.

## VNC port 5901 bound to localhost

TigerVNC binds to `127.0.0.1:5901` when started with `-localhost yes`.
Verify:

```bash
ss -tlnp | grep 5901
```

If port 5901 is not bound:

```bash
vncserver :1 -localhost yes
```

## Google Cloud IAP SSH tunnel (single-hop)

From the MacBook, the `scripts/macbook-vnc-launcher.sh` script creates a
single-hop IAP tunnel that forwards the remote VNC port directly:

```bash
gcloud compute ssh <instance> \
  --project=<project> \
  --zone=<zone> \
  --tunnel-through-iap \
  --ssh-flag="-N" \
  --ssh-flag=-L"5901:127.0.0.1:5901" \
  --ssh-flag="-o ServerAliveInterval=30" \
  --ssh-flag="-o ServerAliveCountMax=3" \
  --ssh-flag="-o ExitOnForwardFailure=yes"
```

This forwards local port 5901 to the VM's VNC port through IAP in a
single SSH connection. No second SSH hop is needed.

The tunnel binds to localhost only. SSH identity verification is
preserved (no `StrictHostKeyChecking=no`).

## Reconnecting after MacBook sleep or restart

1. Verify the VM is reachable:

   ```bash
   gcloud compute instances describe <instance> --format='value(status)'
   ```

2. Re-establish the IAP tunnel (it may have dropped):

   ```bash
   scripts/macbook-vnc-launcher.sh
   ```

3. Open Screen Sharing (the launcher does this automatically after the
   forward is ready).

## Opening macOS Screen Sharing

The launcher opens Screen Sharing automatically after the tunnel is
ready. To open manually:

```bash
open "vnc://localhost:5901"
```

Or use **Finder > Go > Connect to Server** and enter:

```
vnc://localhost:5901
```

Enter the VNC password when prompted.

## MacBook launcher script

A reusable launcher is provided at `scripts/macbook-vnc-launcher.sh`.

Configure by editing the variables at the top of the script or exporting
them:

```bash
export GCP_PROJECT="your-project"
export GCP_ZONE="us-central1-a"
export GCP_INSTANCE="cloud-agent"
scripts/macbook-vnc-launcher.sh
```

The launcher:

1. Checks for an existing tunnel (avoids duplicates).
2. Creates the IAP tunnel with VNC port forwarding.
3. Waits for the local port to accept connections.
4. Opens Screen Sharing only after the forward is ready.
5. Tracks its PID in `/tmp/macbook-vnc-tunnel.pid`.

To stop the tunnel:

```bash
scripts/macbook-vnc-launcher.sh --stop
```

The stop command terminates only the tunnel process identified by the
tracked PID. It does not terminate unrelated SSH or Screen Sharing
sessions.

> **Note**: This script targets macOS. Shell syntax is validated on
> Ubuntu, but macOS-specific behavior (Screen Sharing, osascript) is
> unverified unless actually tested on macOS.

## Diagnosing IAP, SSH, and VNC failures

### IAP tunnel fails

| Symptom | Cause | Fix |
| --- | --- | --- |
| `PERMISSION_DENIED` | IAP API not enabled | `gcloud services enable iap.googleapis.com` |
| `not authorized` | Missing IAP role | Add `roles/iap.tunnelResourceAccessor` |
| Tunnel drops | Idle timeout | Use `ServerAliveInterval=30` |
| `Host key verification failed` | VM recreated | Remove old key from `~/.ssh/known_hosts` |

### SSH fails

| Symptom | Cause | Fix |
| --- | --- | --- |
| `Connection refused` | sshd not running | `sudo systemctl start ssh` |
| `Permission denied (publickey)` | Key not in metadata | Add key via `gcloud compute instances add-metadata` |

### VNC fails

| Symptom | Cause | Fix |
| --- | --- | --- |
| `Connection refused` on 5901 | VNC not running | `vncserver :1 -localhost yes` |
| `Authentication failed` | Wrong password | Reset: `vncpasswd` |
| Black screen | XFCE not started | `DISPLAY=:1 startxfce4 &` |
| VNC works but Burp GUI not visible | Burp not started | `scripts/start-burp.sh` |

### Firewall rules

Ensure no public ingress on VNC or MCP ports:

```bash
gcloud compute firewall-rules list --filter="name~agent"
```

Only the IAP SSH rule (`35.235.240.0/20` on TCP/22) should exist.
