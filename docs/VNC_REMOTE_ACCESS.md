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

## Google Cloud IAP SSH port forwarding

From the MacBook, create an IAP tunnel:

```bash
gcloud compute ssh agent-vm \
  --project=<project> \
  --zone=<zone> \
  --tunnel-through-iap \
  --ssh-flag="-L 2222:localhost:22" \
  --ssh-flag="-N"
```

This forwards local port 2222 to the VM's SSH port through IAP.

Then forward VNC through the tunnel:

```bash
ssh -p 2222 -L 5901:localhost:5901 agent-vm@localhost -N
```

Or use the provided launcher script (see below).

## Reconnecting after MacBook sleep or restart

1. Verify the VM is reachable:

   ```bash
   gcloud compute instances describe agent-vm --format='value(status)'
   ```

2. Re-establish the IAP tunnel (it may have dropped):

   ```bash
   scripts/macbook-vnc-launcher.sh
   ```

3. Open Screen Sharing:

   ```
   vnc://localhost:5901
   ```

## Opening macOS Screen Sharing

From the terminal:

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
export GCP_INSTANCE="agent-vm"
scripts/macbook-vnc-launcher.sh
```

To stop the tunnels:

```bash
scripts/macbook-vnc-launcher.sh --stop
```

## Diagnosing IAP, SSH, and VNC failures

### IAP tunnel fails

| Symptom | Cause | Fix |
| --- | --- | --- |
| `PERMISSION_DENIED` | IAP API not enabled | `gcloud services enable iap.googleapis.com` |
| `not authorized` | Missing IAP role | Add `roles/iap.tunnelResourceAccessor` |
| Tunnel drops | Idle timeout | Use `ServerAliveInterval=30` |

### SSH fails

| Symptom | Cause | Fix |
| --- | --- | --- |
| `Connection refused` | sshd not running | `sudo systemctl start ssh` |
| `Host key verification failed` | VM recreated | Remove old key from `~/.ssh/known_hosts` |
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
