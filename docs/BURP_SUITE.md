# Burp Suite

## Installation

Burp Suite Community is installed from the official PortSwigger distribution at:

```
~/tools/burp/burpsuite_desktop_v2026.9.1.jar
```

> **Do not commit the JAR, Burp loader, license files, or any activation
> utilities to Git.** These are proprietary. `.gitignore` covers them.

To reinstall on a fresh VM:

1. Download the latest Burp Suite Community JAR from PortSwigger.
2. Place it at `~/tools/burp/burpsuite_desktop_v<version>.jar`.
3. Update `BURP_JAR` in `scripts/start-burp.sh` or set the environment variable.

## Java runtime

Burp Suite 2026.9.1 requires **OpenJDK 17 or later**. The validated runtime is:

```
OpenJDK 25.0.4.1 (openjdk-25-jre-headless)
```

Install on Ubuntu 24.04:

```bash
sudo apt install openjdk-25-jre-headless
```

Verify:

```bash
java -version
```

> Burp logs a warning if the JAR requires a later Java version than the
> one used to launch it. Check `~/.local/state/burp/burp.log` after startup.

## Starting Burp on XFCE display :1

Use the idempotent launcher:

```bash
bash scripts/start-burp.sh
```

The script:

1. Checks for an existing Burp process (avoids duplicates).
2. Verifies Java and X display `:1`.
3. Starts Burp in the background with `-Xmx3g`.
4. Writes logs to `~/.local/state/burp/burp.log` (mode 700 directory).
5. Waits for proxy port `127.0.0.1:8080` to become available.

Options:

```bash
scripts/start-burp.sh           # start (or report already running)
scripts/start-burp.sh --status  # status only
scripts/start-burp.sh --stop    # stop the running instance
```

Environment overrides: `BURP_JAR`, `BURP_JAVA`, `BURP_DISPLAY`, `BURP_XMX`, `BURP_LOG_DIR`.

## Running independently of browser SSH

Burp runs on the VM's XFCE display `:1` and does not depend on any SSH
session. You can:

- Connect via VNC (see [VNC_REMOTE_ACCESS.md](VNC_REMOTE_ACCESS.md)).
- Use `gcloud compute ssh --tunnel-through-iap` for CLI access only.
- Start/stop Burp via `scripts/start-burp.sh` over SSH; the GUI persists
  on the VNC display after disconnect.

## Avoiding duplicate Burp processes

`scripts/start-burp.sh` checks for an existing instance via:

1. PID file at `~/.local/state/burp/burp.pid`.
2. Process table scan for `burpsuite_desktop_v*.jar`.

If Burp is already running, the script reports the existing PID and exits
without launching a second instance.

## Handling Burp restarts

```bash
scripts/start-burp.sh --stop
scripts/start-burp.sh
```

Or simply:

```bash
scripts/start-burp.sh   # detects running instance, reports status
```

To restart after a crash:

```bash
scripts/start-burp.sh --stop   # clean up stale PID
scripts/start-burp.sh         # fresh start
```

## Restoring installed extensions

Burp extensions are stored in `~/.BurpSuite/bapps/`. After a VM rebuild:

1. Start Burp.
2. Go to **Extensions > Installed**.
3. Re-install the **Official Burp MCP** BApp (see [BURP_MCP.md](BURP_MCP.md)).
4. Re-install the **Extended Burp MCP** Java extension (see
   [BURP_MCP_EXTENDED.md](BURP_MCP_EXTENDED.md)).

Extension configurations (target scope, project settings) live in
`~/.BurpSuite/ConfigLibrary` and `~/.BurpSuite/UserConfig.json`. Back these
up outside Git if needed.

## Checking extension loading errors

After starting Burp, check the log:

```bash
tail -100 ~/.local/state/burp/burp.log
```

Common errors:

- **"requires a later version of Java"**: Upgrade OpenJDK.
- **"extension could not be loaded"**: Re-install the BApp; verify
  compatibility with the Burp version.
- **Port 8080 already in use**: Another Burp instance is running; use
  `scripts/start-burp.sh --status`.

Verify MCP connectivity:

```bash
curl -s http://127.0.0.1:9876/health   # Official Burp MCP
opencode mcp list                       # All configured MCPs
```
