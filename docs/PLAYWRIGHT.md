# Playwright Chromium

## Local Playwright MCP installation

Playwright MCP is installed locally at:

```
~/tools/playwright/
├── node_modules/.bin/playwright-mcp   # MCP server executable
├── browser-profile/                    # Isolated Chromium profile
├── isolated-home/                      # Isolated $HOME for MCP subprocess
├── start-mcp.sh                        # Launcher script
├── setup-burp-https.sh                 # HTTPS setup script
├── burp-ca.der                         # Burp CA (DER format)
└── burp-ca.pem                         # Burp CA (PEM format)
```

The globally installed Playwright package provides the `playwright` CLI;
the MCP server is invoked from the local `node_modules`.

## Chromium installation

```bash
playwright install --with-deps chromium
```

Chromium binaries are cached at `~/.cache/ms-playwright/`.

## Headless execution

The MCP server runs Chromium in headless mode. The launcher
(`start-mcp.sh`) passes `--headless` to `playwright-mcp`.

## Burp proxy routing

The launcher configures Chromium to route all HTTP/HTTPS traffic through
Burp:

```
--proxy-server "http://127.0.0.1:8080"
```

This ensures all browser traffic is intercepted and visible in Burp.

## Isolated browser profile

Chromium uses a dedicated profile at `~/tools/playwright/browser-profile/`.
This profile is separate from any system Chrome/Chromium profile and
does not contain personal data, cookies, or session state.

The MCP subprocess runs with an isolated `HOME`:

```
HOME=~/tools/playwright/isolated-home
```

This prevents the browser from reading `~/.config`, `~/.cache`, or other
user state outside the designated directories.

## start-mcp.sh launcher

The launcher is at `~/tools/playwright/start-mcp.sh`. It:

1. Sets isolated `HOME`, `XDG_CONFIG_HOME`, `XDG_CACHE_HOME`.
2. Points `PLAYWRIGHT_BROWSERS_PATH` to the shared cache.
3. Creates the browser profile directory.
4. Launches `playwright-mcp` with `--headless`, `--browser chromium`,
   `--user-data-dir`, and `--proxy-server`.

> The launcher references the exact locally installed executable.
> It does **not** dynamically download `@latest` on every startup.

## OpenCode MCP configuration

In `~/.config/opencode/opencode.jsonc`:

```json
{
  "mcp": {
    "playwright": {
      "type": "local",
      "command": ["/home/YOUR_USER/tools/playwright/start-mcp.sh"],
      "enabled": true,
      "timeout": 60000
    }
  }
}
```

The `timeout` is set to 60 seconds to account for Chromium startup time.

## Verifying Playwright MCP

```bash
opencode mcp list
# Should show: ✓ playwright connected
```

Test navigation:

1. Open an OpenCode session.
2. Ask the agent to navigate to `http://127.0.0.1:8000/`.
3. Verify the page loads and traffic appears in Burp proxy history.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `playwright-mcp: command not found` | Node modules missing | `cd ~/tools/playwright && npm install` |
| Chromium fails to launch | Missing OS deps | `playwright install --with-deps chromium` |
| Browser not using Burp proxy | Launcher not used | Verify `start-mcp.sh` is the MCP command |
| SSL certificate errors | Burp CA not trusted | See [HTTPS_INTERCEPTION.md](HTTPS_INTERCEPTION.md) |
| Profile corruption | Stale state | `rm -rf ~/tools/playwright/browser-profile/` |
