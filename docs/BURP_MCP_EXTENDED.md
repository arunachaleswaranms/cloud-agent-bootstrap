# Extended Burp MCP (v3.3.0)

Third-party Extended Burp MCP provides additional Burp Suite tools beyond
the official MCP, including enhanced site map analysis, content search,
and scan orchestration.

## Source repository

- **Repository**: https://github.com/bitbytelabio/burp-mcp
- **Pinned release**: v3.3.0
- **License**: MIT (third-party; review independently)

> **Supply-chain notice**: This is a third-party project. Review the
> source independently before use. Pin to the verified release and verify
> checksums. The project is community-maintained and may have
> unpatched vulnerabilities or breaking changes between releases.

## Architecture

Extended Burp MCP has two components:

1. **Rust MCP server** (`burp-mcp-linux-x86_64`): Runs as a local stdio
   process, spawns and manages the Java extension inside Burp, and
   exposes tools to OpenCode.
2. **Java Burp extension** (`burp-mcp.jar`): Loaded by Burp Suite;
   provides a gRPC endpoint on `127.0.0.1:9877`.

```
OpenCode <--stdio--> burp-mcp (Rust) <--gRPC 127.0.0.1:9877--> Burp Suite
```

## Installation

### Rust MCP server

```bash
mkdir -p ~/tools/burp-mcp-extended
cd ~/tools/burp-mcp-extended
# Download from https://github.com/bitbytelabio/burp-mcp/releases/tag/v3.3.0
wget https://github.com/bitbytelabio/burp-mcp/releases/download/v3.3.0/burp-mcp-linux-x86_64
chmod +x burp-mcp-linux-x86_64
```

### Checksum verification

```bash
sha256sum burp-mcp-linux-x86_64
```

Expected (v3.3.0):

```
6a5e1f8d22d9d0098fcfd7d4ca571b1c6b961689f7ed192a0c8f0fc3c0215cdc  burp-mcp-linux-x86_64
```

Also verify `burp-mcp.jar`:

```bash
sha256sum burp-mcp.jar
```

Expected:

```
7b4461ebcf6bf43bbd445b2d8cc9942bbe70ea6cd94e6e32f7ac20c49c393de  burp-mcp.jar
```

### Java Burp extension

1. Start Burp Suite.
2. Go to **Extensions > Installed > Add**.
3. Select `~/tools/burp-mcp-extended/burp-mcp.jar`.
4. The extension starts a gRPC listener on `127.0.0.1:9877`.

### Symlink into PATH

```bash
ln -sf ~/tools/burp-mcp-extended/burp-mcp-linux-x86_64 ~/.local/bin/burp-mcp
```

## OpenCode configuration

In `~/.config/opencode/opencode.jsonc`:

```json
{
  "mcp": {
    "Burp_extended": {
      "type": "local",
      "command": ["/home/YOUR_USER/.local/bin/burp-mcp", "serve"],
      "enabled": true,
      "timeout": 30000
    }
  }
}
```

The `serve` command starts the stdio MCP transport. It requires Burp to
be running with the Java extension loaded.

## Target scope behavior

The `burp_target` tool performs **URL membership checks** against Burp's
configured target scope.

### get_scope

Requires a valid URL. Without a URL, the tool cannot perform a
meaningful membership check.

```json
{
  "action": "get_scope",
  "url": "http://127.0.0.1:8000/"
}
```

### add_scope

Adds a URL to Burp's target scope:

```json
{
  "action": "add_scope",
  "url": "http://target.example.com/"
}
```

### remove_scope

Removes a URL from Burp's target scope:

```json
{
  "action": "remove_scope",
  "url": "http://target.example.com/"
}
```

### info

Returns information about the current Burp session and MCP server state.

### sitemap

Returns the current Burp site map (discovered URLs and their response
metadata).

## Known OpenCode model-generated tool-input parsing problem

In some OpenCode sessions, the model generates tool-call arguments that
the MCP client fails to parse for Extended Burp MCP tools. This is a
known issue with how OpenCode serializes certain tool inputs.

**Verification procedure**:

1. Confirm MCP is connected:

   ```bash
   opencode mcp list
   # Should show: ✓ Burp_extended connected
   ```

2. If tool calls fail, use MCP Inspector to verify the tool works:

   ```bash
   npx @modelcontextprotocol/inspector
   ```

3. Configure Inspector to launch the stdio command:

   ```
   /home/YOUR_USER/.local/bin/burp-mcp serve
   ```

4. Call `burp_target` with `action=get_scope` and a valid test URL.

5. If Inspector works but OpenCode does not, restart the OpenCode
   session. The issue is in the MCP client layer, not the Burp
   extension or Rust server.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `burp-mcp: command not found` | Not in PATH | `ln -sf` to `~/.local/bin/` |
| gRPC port 9877 not listening | Java extension not loaded | Re-add `burp-mcp.jar` in Burp |
| Tool timeout | Burp busy or extension crashed | Restart Burp; re-add extension |
| `serve` exits immediately | Burp not running | Start Burp first |
| Checksum mismatch | Corrupted download | Re-download from pinned release |

## Maintenance and supply-chain risks

- **Community-maintained**: The project is maintained by a single
  organization. There is no SLA or security audit.
- **Pinning required**: Always pin to a specific release and verify
  checksums. Do not use `@latest`.
- **No automatic updates**: Updates are manual. Review changelogs before
  applying.
- **Dependency risk**: The Rust binary is statically linked; the Java
  extension depends on Burp's internal APIs, which may break across Burp
  versions.
- **Source review**: For high-assurance environments, review the
  source at https://github.com/bitbytelabio/burp-mcp before deployment.
