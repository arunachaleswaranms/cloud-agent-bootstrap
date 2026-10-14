# Official Burp MCP

The official Burp MCP server is the **MCP Server** Burp Suite extension
(BApp) by PortSwigger. It connects to OpenCode over HTTP.

## Endpoint

```
http://127.0.0.1:9876
```

Bound to localhost only. Never expose publicly.

## Extension details

- **BApp UUID**: `9952290f04ed4f628e624d0aa9dccebc`
- **Version**: 1.3.0
- **Author**: PortSwigger
- **JAR**: `burp-mcp-all.jar`
- **Supports**: Burp Suite Community and Professional

## Extension installation

1. Start Burp Suite (`scripts/start-burp.sh`).
2. In Burp, go to **Extensions > BApp Store**.
3. Find **MCP Server** and click **Install**.
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

The MCP Server BApp is installed per-user in `~/.BurpSuite/bapps/`. It
persists across Burp restarts. After a VM rebuild, reinstall the BApp
from the BApp Store.

Configuration (if any) is stored in `~/.BurpSuite/ConfigLibrary/`. Back
up outside Git.

## Available tools

The official Burp MCP provides these capabilities (not exhaustive):

- **Proxy history**: Access and filter intercepted HTTP/WebSocket traffic
- **HTTP requests**: Send HTTP/1.1 and HTTP/2 requests from AI clients
- **Repeater**: Create Repeater tabs and send requests to Intruder
- **Configuration**: Export and modify project and user configuration
- **Proxy control**: Control proxy intercept, task execution engine, message editor
- **Encoding**: URL, Base64, and random string utilities
- **Organizer**: Interact with Organizer entries
- **Collaborator**: Generate and poll payloads (Professional only)

> **Note**: The `burp_target` tool with `action=get_scope` is provided by
> the **Extended Burp MCP** (third-party), not the official MCP.
> See [BURP_MCP_EXTENDED.md](BURP_MCP_EXTENDED.md) for details.

## Read-only functionality tests

After connecting, verify the MCP tools work:

1. **Proxy history read** (read-only): request a list of recently
   intercepted requests.

2. **Configuration read** (read-only): request the current project
   configuration.

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

3. Call a tool like `burp_proxy_history` (or any available tool) to verify
   the connection works.

4. If the inspector works but OpenCode does not, the issue is in the
   OpenCode MCP client configuration, not the Burp extension.

### Known OpenCode tool-input parsing issue

In some OpenCode sessions, the model generates tool-call input that the
MCP client fails to parse. Symptoms:

- Tool calls return errors even with valid JSON.
- The tool appears connected but every call fails with a validation error.

**Workaround**: Use the MCP Inspector (above) to verify the tool works
independently. If it does, rephrase the tool-call arguments or restart
the OpenCode session. This is an OpenCode/MCP-client issue, not a Burp
extension issue.
