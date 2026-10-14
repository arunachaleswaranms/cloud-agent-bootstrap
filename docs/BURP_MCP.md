# Official Burp MCP

The official Burp MCP server is exposed by the **Burp MCP** Burp Suite
extension (BApp) and connects to OpenCode over HTTP.

## Endpoint

```
http://127.0.0.1:9876
```

Bound to localhost only. Never expose publicly.

## Extension installation

1. Start Burp Suite (`scripts/start-burp.sh`).
2. In Burp, go to **Extensions > BApp Store**.
3. Find **Burp MCP** and click **Install**.
4. After installation, the extension starts automatically with Burp.

The BApp is installed at:

```
~/.BurpSuite/bapps/9952290f04ed4f628e624d0aa9dccebc/burp-mcp-all.jar
```

## Connection to OpenCode

The OpenCode configuration (`~/.config/opencode/opencode.jsonc`) includes:

```json
{
  "mcp": {
    "Burp": {
      "type": "remote",
      "url": "http://127.0.0.1:9876"
    }
  }
}
```

Restart OpenCode after adding this configuration. Verify:

```bash
opencode mcp list
# Should show: ✓ Burp connected
```

## Extension persistence

The Burp MCP BApp is installed per-user in `~/.BurpSuite/bapps/`. It
persists across Burp restarts. After a VM rebuild, reinstall the BApp
from the BApp Store.

Configuration (if any) is stored in `~/.BurpSuite/ConfigLibrary/`. Back
up outside Git.

## Read-only functionality tests

After connecting, verify the MCP tools work:

1. **Target scope check** (read-only):

   ```json
   {
     "action": "get_scope",
     "url": "http://127.0.0.1:8000/"
   }
   ```

   This performs a URL membership check against Burp's configured scope.
   It requires a valid URL.

2. **Proxy history read** (read-only): request a list of recently
   intercepted requests.

3. **Site map read** (read-only): request the current site map.

These operations do not modify Burp state or send traffic to targets.

## Troubleshooting disconnected MCP sessions

| Symptom | Cause | Fix |
| --- | --- | --- |
| `opencode mcp list` shows Burp as disconnected | Burp not running | `scripts/start-burp.sh` |
| Connection refused on port 9876 | Extension not loaded | Re-install BApp; check `~/.local/state/burp/burp.log` |
| Tools timeout | Burp GUI busy or unresponsive | Restart Burp; check VNC display |
| Scope returns empty | No target scope configured | Add target in Burp **Target > Scope** |
| Tools work but return stale data | Proxy not intercepting | Verify browser proxy is `127.0.0.1:8080` |

### MCP Inspector verification

If tool calls fail or return unexpected results:

1. Open a terminal and run:

   ```bash
   npx @modelcontextprotocol/inspector
   ```

2. Configure the inspector to connect to `http://127.0.0.1:9876`.

3. Call `burp_target` with `action=get_scope` and a valid test URL.

4. If the inspector works but OpenCode does not, the issue is in the
   OpenCode MCP client configuration, not the Burp extension.

### Known OpenCode tool-input parsing issue

In some OpenCode sessions, the model generates tool-call input that the
MCP client fails to parse for the `burp_target` tool. Symptoms:

- `get_scope` returns an error even with valid JSON.
- The tool appears connected but every call fails with a validation error.

**Workaround**: Use the MCP Inspector (above) to verify the tool works
independently. If it does, rephrase the tool-call arguments or restart
the OpenCode session. This is an OpenCode/MCP-client issue, not a Burp
extension issue.
