# Entra ID app registration and tenant setup

The toolkit talks to three APIs. Each needs its own grant, and Power Platform and
Business Central both need a registration step *outside* the Azure portal that is
easy to miss.

---

## 1. Register the application

[Entra admin center](https://entra.microsoft.com/) → **Applications** → **App registrations** → **New registration**.

| Setting | Value |
|---|---|
| Name | `Workshop Provisioning` |
| Supported account types | Accounts in this organizational directory only |
| Redirect URI | Leave empty for `ClientSecret` mode. For `DeviceCode` mode see step 5. |

Copy the **Application (client) ID** and **Directory (tenant) ID**.

Add a client secret under **Certificates & secrets**, and keep it out of the repo:

```powershell
$env:WORKSHOP_CLIENT_SECRET = '<secret>'
```

The config file then references it indirectly:

```json
"clientSecret": "env:WORKSHOP_CLIENT_SECRET"
```

---

## 2. Microsoft Graph permissions (user creation + licensing)

**API permissions** → **Add a permission** → **Microsoft Graph** → **Application permissions**:

| Permission | Needed for |
|---|---|
| `User.ReadWrite.All` | Create users, assign licences |
| `Organization.Read.All` | Read the tenant's subscribed SKUs |

Then **Grant admin consent**.

---

## 3. Business Central permissions

### 3a. API permissions in Entra

**Add a permission** → **APIs my organization uses** → **Dynamics 365 Business Central** → **Application permissions**:

| Permission | Needed for |
|---|---|
| `AdminCenter.ReadWrite.All` | Admin Center API — look up the environment |
| `Automation.ReadWrite.All` | Automation API — users, companies, permission sets |

Grant admin consent.

### 3b. Authorise the app inside Business Central

App permissions alone are not enough — Business Central keeps its own allow-list.

1. In Business Central, search for **Microsoft Entra Applications** and open it.
2. **New**, paste the **Client ID**, give it a description, set **State** to *Enabled*.
3. Assign these permission sets to the application:
   - `D365 AUTOMATION`
   - `EXTEN. MGT. - ADMIN`
4. Grant consent if you did not already do so in the Azure portal.

> Applications **cannot** be assigned `SUPER`. That is by design, and it is why the
> Business Central user-synchronisation action does not work under app-only
> authentication — see [DeviceCode mode](#5-devicecode-mode-optional).

### 3c. Authorise the app in the Business Central admin center

[Business Central admin center](https://businesscentral.dynamics.com/admin) →
**Authorized Microsoft Entra apps** → add the Client ID → grant consent.

Granting consent here needs a role that can manage app registrations, such as
**Cloud Application Administrator**. The **Dynamics 365 Administrator** role alone
is *not* sufficient for the consent step.

---

## 4. Power Platform registration (Developer environments)

The BAP API does not use Entra API permissions. The service principal must instead
be registered as a **Power Platform admin application**. This is the step people
most often miss; without it, environment creation returns `403`.

Run this once, signed in as a Global or Power Platform Administrator:

```powershell
# Requires: Install-Module Microsoft.PowerApps.Administration.PowerShell
Add-PowerAppsAccount
New-PowerAppManagementApp -ApplicationId <client-id>
```

Equivalent raw call, if you prefer no modules — note this needs a *user* token
for `https://api.bap.microsoft.com`, not an app-only one:

```
PUT https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/adminApplications/<client-id>?api-version=2020-10-01
```

Also confirm the tenant allows Developer environment creation:
[Power Platform admin center](https://admin.powerplatform.microsoft.com/) →
**Settings** → **Features** → Developer environment assignments.

---

## 5. DeviceCode mode — the shortcut

> **First check whether device code flow is even allowed.** Since July 2026 new
> Microsoft Entra tenants block it as part of security defaults, and security
> defaults admit no exclusions — not for an application, not for a user. A
> blocked attempt authenticates successfully and is then refused the token
> (`AADSTS530035`), with the sign-in log naming **Security Defaults** as the
> failing policy. Look under **Entra ID > Overview > Properties > Manage
> security defaults**. If they are on, use `-AuthMode ClientSecret` and complete
> steps 3b, 3c and 4 above.
>
> **If device code flow is available, steps 3b, 3c and 4 above do not apply.**
> Delegated calls are authorised by the signed-in administrator's own roles, so
> there is no service principal to register with Power Platform and no app to
> authorise inside Business Central. You also never handle a client secret.
>
> The catch: for the Business Central step the signing-in admin must be a
> **licensed BC user in the target environment with rights to manage users** —
> the automation API runs as a Business Central user, not merely as a tenant
> admin. Run `./src/Test-WorkshopSetup.ps1` to confirm before workshop day.

Use `-AuthMode DeviceCode` when you want Business Central to synchronise users on
demand rather than waiting for its periodic sync.

Configure the app registration as a public client:

1. **Authentication** → **Add a platform** → **Mobile and desktop applications**.
2. Tick `https://login.microsoftonline.com/common/oauth2/nativeclient`.
3. **Allow public client flows** → **Yes**.
4. Add **delegated** permissions mirroring the application permissions above
   (Graph `User.ReadWrite.All`, `Organization.Read.All`; Business Central
   `AdminCenter.ReadWrite.All`, `Automation.ReadWrite.All`).

Sign in as a **Global Administrator**, or as **Dynamics 365 Administrator** plus
**Power Platform Administrator**. You are prompted once; the refresh token is then
redeemed silently for the other APIs.

---

## 6. A separate app for MCP hosts

Attendees connecting Claude Code, ChatGPT or another non-Microsoft MCP host need
their *own* app registration — a public client with a delegated Business Central
permission. Do **not** reuse the provisioning app above.

See [mcp-client-setup.md](mcp-client-setup.md).

---

## Verifying the setup

```powershell
Import-Module ./src/modules/WorkshopCommon.psm1, ./src/modules/WorkshopAuth.psm1, `
              ./src/modules/WorkshopEntra.psm1, ./src/modules/WorkshopPowerPlatform.psm1, `
              ./src/modules/WorkshopBusinessCentral.psm1

Initialize-WsAuth -TenantId <tenant> -ClientId <client> -ClientSecret $env:WORKSHOP_CLIENT_SECRET

Get-WsSubscribedSku | Format-Table                       # Graph works
Get-WsPowerPlatformEnvironment | Select-Object name       # BAP works
Get-WsBcEnvironment -EnvironmentName <env>                # BC admin API works
```

| Symptom | Likely cause |
|---|---|
| `403` creating an environment | Step 4 not done, or the tenant feature setting blocks it |
| `401` on Business Central calls | Step 3b or 3c not done |
| Licence assignment fails | `user.usageLocation` missing, or no seats left |
| BC user never appears | Sync lag — re-run `-Steps BusinessCentral`, or use `-AuthMode DeviceCode` |
