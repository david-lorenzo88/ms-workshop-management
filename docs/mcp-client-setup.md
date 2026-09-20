# Connecting an attendee to the Business Central MCP server

The Business Central MCP server lets AI clients read and act on Business Central
data. Every request runs **as the signed-in user, with that user's permissions**,
so an attendee provisioned by this toolkit (`D365 FULL ACCESS`) already has the
data access they need. Nothing extra is required to *use* MCP.

| | |
|---|---|
| MCP endpoint | `https://mcp.businesscentral.dynamics.com` |
| Auth | OAuth 2.0 authorization code + PKCE, via Microsoft Entra ID |
| Default access | **Read-only** across all published API pages |

---

## 1. Register an app for the MCP host

Microsoft's own hosts (VS Code with GitHub Copilot, Copilot Studio) use a
preregistered application and need no setup.

Everything else — Claude Code, ChatGPT, MCP Inspector — needs its own Entra app,
because Entra ID does not support Dynamic Client Registration. One registration can
serve the whole workshop.

1. Entra admin center → **App registrations** → **New registration**.
2. **Authentication** → add the host's redirect URI. Claude Code uses
   `http://localhost:<port>/callback`, e.g. `http://localhost:33418/callback`.
   The port must match the client configuration.
3. **API permissions** → **Microsoft APIs** → **Dynamics 365 Business Central** →
   **Delegated permissions** → `Financials.ReadWrite.All`.
4. Copy the **Application (client) ID** into `businessCentral.mcp.clientId` in the
   workshop config.

> `Financials.ReadWrite.All` is the *delegated* ceiling. What an attendee can
> actually do is still bounded by their Business Central permission sets and by the
> MCP Server configuration. The narrowest of the three wins.

---

## 2. Hand each attendee their configuration

Every run writes `output/mcp-<alias>.json` per attendee, already filled in:

```json
{
  "mcpServers": {
    "businesscentral": {
      "type": "http",
      "url": "https://mcp.businesscentral.dynamics.com",
      "headers": {
        "TenantId": "<tenant-id>",
        "EnvironmentName": "SANDBOX-WORKSHOP",
        "Company": "CRONUS USA, Inc.",
        "ConfigurationName": "WorkshopConfig"
      },
      "oauth": {
        "clientId": "<mcp-app-client-id>",
        "callbackPort": 33418
      }
    }
  }
}
```

Set `businessCentral.mcp.clientKind` to `CopilotCli` to emit the GitHub Copilot CLI
shape (`oauthClientId` / `oauthRedirectPort` / `oauthPublicClient`) instead.

Starting the connection opens a browser for the attendee to sign in. From then on
the session acts as them.

### Header notes

- `ConfigurationName` is optional. Omit it to use the environment's default
  MCP behaviour.
- If `Company` or `ConfigurationName` contain non-ASCII characters (`ø`, `æ`, `å`),
  they must be base64-wrapped as `=?base64?<value>?=`. The toolkit does this
  automatically — `ConvertTo-WsBcHeaderValue` handles it.

---

## 3. Optional: an MCP Server configuration in Business Central

Without a configuration, attendees get read-only access to all published API pages.
That is often exactly right for a workshop.

To allow writes, someone with `MCP - ADMIN` creates a configuration in Business
Central (search for *Model Context Protocol (MCP) Server Configurations*), adds API
pages as tools, and enables **Unblock Edit Tools** plus the per-page
`Allow Create` / `Allow Modify` / `Allow Delete` / `Allow Bound Actions` flags.

Useful switches on that page:

| Setting | Effect |
|---|---|
| **Dynamic Tool Mode** | Tools are discovered at runtime. Needed when you expose many API pages — Copilot Studio caps at 70 tools. |
| **Discover Additional Objects** | Read-only access to API pages not explicitly listed. Requires Dynamic Tool Mode. |
| **Unblock Edit Tools** | Master switch for create/modify/delete. Off means every tool is read-only regardless of the per-page flags. |

Configurations export and import as JSON, so you can build one once and import it
into each workshop environment.

To let attendees author their own configurations, set
`businessCentral.grantMcpAdmin: true`, which adds the `MCP - ADMIN` permission set.
That grants MCP configuration authority — it is **not** Business Central system
administration, and it does not imply `SUPER`.

---

## Troubleshooting

| Symptom | Cause |
|---|---|
| Sign-in loops or redirect mismatch | Redirect URI / port in Entra does not match `callbackPort` |
| Connects, but no tools appear | No active MCP Server configuration, and Discover Additional Objects is off |
| Reads work, writes fail | **Unblock Edit Tools** off, or the per-page flag is not set |
| `401` after sign-in | The attendee has no Business Central licence, or has not been synced into the environment |
| Sees nothing at all | Attendee lacks a data permission set — re-run `-Steps BusinessCentral` |

## References

- [MCP in Business Central overview](https://learn.microsoft.com/dynamics365/business-central/dev-itpro/ai/mcp-overview)
- [Configure Business Central MCP Server](https://learn.microsoft.com/dynamics365/business-central/dev-itpro/ai/configure-mcp-server)
- [Connect non-Microsoft MCP hosts](https://learn.microsoft.com/dynamics365/business-central/dev-itpro/ai/use-mcp-server-non-microsoft)
