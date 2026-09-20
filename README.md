# MS Workshop Management

PowerShell tooling to onboard workshop attendees across Microsoft 365, Power Platform
and Dynamics 365 Business Central in one pass.

For each attendee the toolkit:

1. **Creates the Microsoft 365 / Entra ID user** with a strong generated password.
2. **Assigns the licences** the workshop needs.
3. **Creates a Power Platform Developer environment _owned by that attendee_** — not by
   the admin running the script.
4. **Grants Business Central permissions**: full access to all data, and *no*
   Business Central administration, so attendees can drive the
   [Business Central MCP server](https://learn.microsoft.com/dynamics365/business-central/dev-itpro/ai/mcp-overview)
   as themselves.

It also writes each attendee a ready-to-paste MCP client configuration.

---

## Requirements

- **PowerShell 7.0+** (`pwsh`). Works on Windows, macOS and Linux.
- No external PowerShell modules — everything is plain REST against documented endpoints.
- An Entra ID app registration, plus tenant roles. See [docs/app-registration.md](docs/app-registration.md).

---

## Quick start

```powershell
# 1. Configure
cp config/workshop.config.example.json config/workshop.config.json
#    edit tenantId, clientId, licences, environment names...

# 2. Supply the client secret out-of-band (never in the config file)
$env:WORKSHOP_CLIENT_SECRET = '<secret>'

# 3. Dry run first - this changes nothing
./src/New-WorkshopUser.ps1 -Csv data/attendees.csv -WhatIf

# 4. Provision for real
./src/New-WorkshopUser.ps1 -Csv data/attendees.csv
```

### Single attendee

```powershell
./src/New-WorkshopUser.ps1 -UserPrincipalName anna@contoso.com -DisplayName 'Anna Smith'
```

### Re-run only one step

Every step is idempotent, so re-running is safe. Business Central licences can take a
few minutes to reach the environment, so this is the common follow-up:

```powershell
./src/New-WorkshopUser.ps1 -Csv data/attendees.csv -Steps BusinessCentral
```

### Generating a numbered roster

For a workshop with numbered accounts, generate the CSV rather than typing it:

```powershell
./src/New-AttendeeRoster.ps1 -Domain contoso.onmicrosoft.com -Count 10 -OutFile data/workshop-users.csv
# -> user1@... through user10@...
```

`-Prefix` changes the stem, and `-StartAt` extends an existing roster without
renumbering it (`-Count 5 -StartAt 11` adds user11 ... user15).

### Attendee CSV

`UserPrincipalName` and `DisplayName` are required; the rest are optional.
`Licenses` (semicolon-separated SKU part numbers) overrides the configured default
for that row.

```csv
UserPrincipalName,DisplayName,GivenName,Surname,JobTitle,Department,Licenses
anna.smith@contoso.com,Anna Smith,Anna,Smith,Consultant,Workshop,
ben.jones@contoso.com,Ben Jones,Ben,Jones,Developer,Workshop,DYN365_BUSCENTRAL_PREMIUM;POWERAPPS_DEV
```

---

## Authentication modes

| Mode | Flag | Use when |
|---|---|---|
| `ClientSecret` | default | Unattended runs. App-only, no prompts. |
| `DeviceCode` | `-AuthMode DeviceCode` | You need Business Central to synchronise users on demand. |

**Why DeviceCode matters:** Business Central's "get new users from Microsoft 365"
action is [not supported under service-to-service authentication](https://learn.microsoft.com/dynamics365/business-central/dev-itpro/administration/itpro-introduction-to-automation-apis)
— it requires `SUPER` in every company, which cannot be granted to an application
identity. Under `ClientSecret` the script skips the sync and waits for Business
Central's own periodic synchronisation (or the attendee's first sign-in) instead.
You will see a warning saying exactly that.

---

## The Business Central permission model

The requirement is *full data access, no admin rights*. That maps to a specific
permission set:

| Permission set | Data access | BC administration | Used here |
|---|---|---|---|
| `D365 FULL ACCESS` | Full, within the user's licence | **No** | **Default** |
| `SUPER` | Full | Yes — system setup, user management | Blocked |
| `SECURITY`, `D365 SECURITY` | — | Yes — user/permission management | Blocked |

`Grant-WsBcPermission` **refuses** to assign `SUPER`, `SUPER (DATA)`, `SECURITY` or
`D365 SECURITY` and tells you why. Override deliberately with
`businessCentral.allowAdminPermissionSets: true` if you really want BC administrators.

### MCP and permissions

The Business Central MCP server executes every request **under the signed-in user's
own identity and permissions**. So `D365 FULL ACCESS` is precisely what an
MCP-using attendee needs — no extra grant is required to *use* MCP.

`MCP - ADMIN` is only needed to **author** MCP Server configurations (the
*Model Context Protocol (MCP) Server Configurations* page). If your attendees build
their own configurations during the workshop, set
`businessCentral.grantMcpAdmin: true`. That is MCP configuration authority, not
Business Central system administration.

> By default the MCP server exposes **read-only** access to all published API pages.
> Write operations only exist where an admin has enabled them per API page in an
> MCP Server configuration. Attendee permissions and the MCP configuration both
> apply — the narrower of the two wins.

See [docs/mcp-client-setup.md](docs/mcp-client-setup.md) for connecting Claude Code,
VS Code or Copilot Studio.

---

## Power Platform Developer environments

The environment is created with `environmentSku: "Developer"` and a `usedBy` block
naming the attendee, which is what makes the attendee — rather than the admin
running the script — the owner and System Administrator.

Constraints worth knowing:

- An admin can create **up to 3** Developer environments per owner.
- The tenant setting governing Developer environment creation must permit it
  (Power Platform admin center → **Settings** → **Features**). If it does not, the
  script surfaces the 403 with the exact causes to check.
- Provisioning Dataverse takes a few minutes. Set
  `powerPlatform.waitForProvisioning: true` to block until it finishes; leave it
  `false` to fire-and-forget across a large roster.

---

## Output

Each run writes to `output/` (gitignored):

| File | Contents |
|---|---|
| `workshop-run-<timestamp>.json` | Full structured result per attendee. |
| `workshop-run-<timestamp>.credentials.csv` | **Passwords.** Distribute securely, then delete. |
| `mcp-<alias>.json` | That attendee's MCP client configuration. |

> Generated passwords are only ever returned for accounts this script creates. For a
> user that already exists the password column is empty — Entra ID never discloses
> existing passwords.

---

## Configuration reference

See [config/workshop.config.example.json](config/workshop.config.example.json). Notable keys:

| Key | Meaning |
|---|---|
| `clientSecret` | Literal value, or `env:NAME` to read from an environment variable. |
| `user.usageLocation` | Two-letter country code. **Required before any licence can be assigned.** |
| `licenses.skuPartNumbers` | SKU part numbers as shown in the admin center. |
| `licenses.ignoreMissingSku` | `true` warns and continues when a SKU is absent; `false` fails fast. |
| `powerPlatform.displayNameTemplate` | Supports `{DisplayName}`, `{Alias}`, `{GivenName}`, `{Surname}`, `{UserPrincipalName}`. |
| `businessCentral.permissionSets` | Defaults to `["D365 FULL ACCESS"]`. |
| `businessCentral.assignToAllCompanies` | `true` assigns tenant-wide; `false` scopes to the configured company. |
| `businessCentral.grantMcpAdmin` | Adds `MCP - ADMIN` so attendees can author MCP configurations. |
| `businessCentral.waitForUserSyncMinutes` | How long to wait for a licensed user to appear in BC. |

To discover the SKU part numbers you actually own:

```powershell
Import-Module ./src/modules/WorkshopCommon.psm1, ./src/modules/WorkshopAuth.psm1, ./src/modules/WorkshopEntra.psm1
Initialize-WsAuth -TenantId <tenant> -ClientId <client> -ClientSecret $env:WORKSHOP_CLIENT_SECRET
Get-WsSubscribedSku | Sort-Object SkuPartNumber | Format-Table
```

---

## Tests

`tests/Invoke-MockRun.ps1` runs the whole orchestrator offline against a mocked
Microsoft API. It shadows `Invoke-WebRequest`, so the real request building, retry,
status handling and JSON parsing all stay in the code path under test.

```powershell
pwsh -File tests/Invoke-MockRun.ps1
```

It asserts, among other things, that `-WhatIf` issues zero mutating calls, that
re-running is idempotent, that `SUPER` is never assigned, and that every Developer
environment carries `usedBy`.

---

## Safety notes

- `-WhatIf` is supported end to end and is genuinely inert. Use it first.
- Client secrets are read from the environment, never stored in the repo. Bearer
  tokens and secrets are redacted from all logged error bodies.
- `output/`, real config files and non-example CSVs are gitignored.
