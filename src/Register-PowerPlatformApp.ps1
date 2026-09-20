#!/usr/bin/env pwsh
#Requires -Version 7.0
# NOTE: the shebang makes this directly executable (./src/<script>.ps1) on macOS
# and Linux. The cost is that Get-Help falls back to auto-generated syntax for
# .SYNOPSIS, because comment-based help must be the very first thing in a file.
# .DESCRIPTION, .PARAMETER and .EXAMPLE still render. Do not remove the shebang
# to 'fix' the synopsis - being runnable matters more.
<#
.SYNOPSIS
    Registers an application as a Power Platform management application.

.DESCRIPTION
    The cross-platform replacement for New-PowerAppManagementApp. The
    Microsoft.PowerApps.Administration.PowerShell module depends on .NET
    Framework and does not run on macOS or Linux at all, so this performs the
    same registration with a single REST call against the BAP API.

    This is only needed for app-only (-AuthMode ClientSecret) provisioning runs.
    Under delegated authentication the BAP API honours the signed-in
    administrator's own role, and no registration is required.

    You must sign in as a Global Administrator or Power Platform Administrator.

.PARAMETER ApplicationId
    Client ID of the application to register.

.EXAMPLE
    ./src/Register-PowerPlatformApp.ps1 -ApplicationId de8df5f5-7c48-4966-bce1-549452e0f9a8 -TenantId <guid> -ClientId <signin-app-id>

.EXAMPLE
    ./src/Register-PowerPlatformApp.ps1 -ApplicationId <guid> -List

    Lists the management applications already registered in the tenant.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$ApplicationId,
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..' 'config' 'workshop.config.json'),
    [string]$TenantId,
    [string]$ClientId,
    [ValidateSet('InteractiveBrowser', 'DeviceCode')][string]$AuthMode = 'InteractiveBrowser',
    [int]$RedirectPort = 8400,
    [switch]$List
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

foreach ($module in 'WorkshopCommon', 'WorkshopAuth') {
    Import-Module (Join-Path $PSScriptRoot 'modules' "$module.psm1") -Force -DisableNameChecking
}

$BapBase    = 'https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform'
$ApiVersion = '2020-10-01'

# Registration is a tenant-level admin action performed as a user, so only the
# delegated flows apply here - a client secret cannot register itself.
$config = $null
if (Test-Path -LiteralPath $ConfigPath) {
    try { $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json -Depth 20 } catch { }
}
if (-not $TenantId -and $config -and $config.PSObject.Properties['tenantId']) { $TenantId = $config.tenantId }
if (-not $ClientId -and $config -and $config.PSObject.Properties['clientId']) { $ClientId = $config.clientId }

if (-not $TenantId -or -not $ClientId) {
    throw 'Need -TenantId and -ClientId (the app you sign in WITH; it may be the same app you are registering).'
}

Initialize-WsAuth -TenantId $TenantId -ClientId $ClientId -Mode $AuthMode -RedirectPort $RedirectPort | Out-Null

if ($List) {
    $uri = '{0}/adminApplications?api-version={1}' -f $BapBase, $ApiVersion
    $apps = (Invoke-WsRestMethod -Uri $uri -Headers (Get-WsAuthHeader -Resource PowerPlatform) -Context 'powerplatform').Content
    Write-WsLog 'Registered management applications:' -Level Step
    if ($apps.PSObject.Properties.Name -contains 'value') { $apps.value } else { $apps }
    return
}

$uri = '{0}/adminApplications/{1}?api-version={2}' -f $BapBase, [uri]::EscapeDataString($ApplicationId), $ApiVersion

if (-not $PSCmdlet.ShouldProcess($ApplicationId, 'Register as a Power Platform management application')) { return }

$response = Invoke-WsRestMethod -Uri $uri -Method PUT -Headers (Get-WsAuthHeader -Resource PowerPlatform) `
    -Body @{} -TolerateStatus @(400, 401, 403) -Context 'powerplatform'

if (-not $response.Success) {
    throw @"
Registration failed (HTTP $($response.StatusCode)).

  401/403 - the signed-in account is not a Global Administrator or Power
            Platform Administrator, or the sign-in app lacks delegated access
            to the Power Platform API.
  400     - the application ID does not exist in this tenant. Register the app
            in Microsoft Entra ID first.

Service response: $(ConvertTo-WsRedactedString $response.RawBody)
"@
}

Write-WsLog "Registered $ApplicationId as a Power Platform management application." -Level Success
$response.Content
