#!/usr/bin/env pwsh
#Requires -Version 7.0
# NOTE: the shebang makes this directly executable (./src/<script>.ps1) on macOS
# and Linux. The cost is that Get-Help falls back to auto-generated syntax for
# .SYNOPSIS, because comment-based help must be the very first thing in a file.
# .DESCRIPTION, .PARAMETER and .EXAMPLE still render. Do not remove the shebang
# to 'fix' the synopsis - being runnable matters more.
<#
.SYNOPSIS
    Pre-flight check for the workshop provisioning toolkit. Changes nothing.

.DESCRIPTION
    Exercises every API the provisioning run depends on and reports exactly which
    ones work, so permission and licensing problems surface before workshop day
    rather than halfway through creating accounts.

    Also prints the two things you need in order to fill in the configuration:
    your verified domains (for the attendee UPNs) and the SKU part numbers you
    actually own, with remaining seat counts.

    This script is strictly read-only.

.PARAMETER AttendeeCount
    How many attendees you plan to provision. Seat availability is checked
    against this number.

.EXAMPLE
    ./src/Test-WorkshopSetup.ps1 -AttendeeCount 10 -AuthMode DeviceCode

.EXAMPLE
    ./src/Test-WorkshopSetup.ps1 -TenantId <guid> -ClientId <guid> -AuthMode DeviceCode -AttendeeCount 10

    Runs without a config file, for the very first check after registering the app.
#>

[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..' 'config' 'workshop.config.json'),
    [string]$TenantId,
    [string]$ClientId,
    [ValidateSet('ClientSecret', 'DeviceCode', 'InteractiveBrowser')][string]$AuthMode,
    [int]$AttendeeCount = 10,
    [ValidateSet('Debug', 'Info', 'Warn', 'Error')][string]$LogLevel = 'Warn'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

foreach ($module in 'WorkshopCommon', 'WorkshopAuth', 'WorkshopEntra', 'WorkshopPowerPlatform', 'WorkshopBusinessCentral') {
    Import-Module (Join-Path $PSScriptRoot 'modules' "$module.psm1") -Force -DisableNameChecking
}
Set-WsLogLevel -Level $LogLevel

$checks = [System.Collections.Generic.List[object]]::new()

function Add-Check {
    param(
        [Parameter(Mandatory)][string]$Area,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('PASS', 'FAIL', 'WARN', 'SKIP')][string]$Status,
        [string]$Detail,
        [string]$Remedy
    )
    $checks.Add([pscustomobject]@{ Area = $Area; Check = $Name; Status = $Status; Detail = $Detail; Remedy = $Remedy })

    $colour = switch ($Status) { 'PASS' { 'Green' } 'FAIL' { 'Red' } 'WARN' { 'Yellow' } default { 'DarkGray' } }
    Write-Host ('  {0,-5} ' -f $Status) -NoNewline -ForegroundColor $colour
    Write-Host ('{0,-22} {1}' -f $Name, $Detail)
}

function Invoke-Check {
    <#  Runs a probe, turning any failure into a FAIL row rather than aborting. #>
    param(
        [Parameter(Mandatory)][string]$Area,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Probe,
        [string]$Remedy
    )
    try {
        $detail = & $Probe
        Add-Check -Area $Area -Name $Name -Status 'PASS' -Detail ([string]$detail)
        return $true
    }
    catch {
        $message = $_.Exception.Message -replace '\s+', ' '
        if ($message.Length -gt 200) { $message = $message.Substring(0, 200) + '...' }
        Add-Check -Area $Area -Name $Name -Status 'FAIL' -Detail $message -Remedy $Remedy
        return $false
    }
}

# --- configuration -------------------------------------------------------------

Write-Host ''
Write-WsLog 'Workshop setup pre-flight (read-only)' -Level Step
Write-Host ''

$config = $null
if (Test-Path -LiteralPath $ConfigPath) {
    try { $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json -Depth 20 }
    catch { Write-WsLog "Config file is not valid JSON: $($_.Exception.Message)" -Level Error }
}

function Cfg {
    param([string]$Path, $Default = $null)
    $current = $config
    foreach ($segment in ($Path -split '\.')) {
        if ($null -eq $current) { return $Default }
        $property = $current.PSObject.Properties[$segment]
        if ($null -eq $property) { return $Default }
        $current = $property.Value
    }
    if ($null -eq $current) { return $Default }
    if ($current -is [string] -and [string]::IsNullOrWhiteSpace($current)) { return $Default }
    return $current
}

$effectiveTenant = if ($TenantId) { $TenantId } else { Cfg 'tenantId' }
$effectiveClient = if ($ClientId) { $ClientId } else { Cfg 'clientId' }
$effectiveMode   = if ($AuthMode) { $AuthMode } else { Cfg 'authMode' 'DeviceCode' }

if (-not $effectiveTenant -or -not $effectiveClient) {
    throw 'Need a tenantId and clientId: pass -TenantId/-ClientId, or fill them into the config file.'
}

$secret = $null
if ($effectiveMode -eq 'ClientSecret') {
    $secret = Resolve-WsSecret -Value (Cfg 'clientSecret') -Name 'clientSecret'
    if (-not $secret) { throw 'authMode is ClientSecret but no secret resolved. Set WORKSHOP_CLIENT_SECRET, or use -AuthMode DeviceCode.' }
}

Initialize-WsAuth -TenantId $effectiveTenant -ClientId $effectiveClient -ClientSecret $secret -Mode $effectiveMode | Out-Null
Write-Host "Tenant $effectiveTenant | client $effectiveClient | auth $effectiveMode" -ForegroundColor DarkGray
Write-Host ''

# --- Microsoft Graph -----------------------------------------------------------

Write-Host 'Microsoft Graph (users and licences)' -ForegroundColor Cyan

$graphOk = Invoke-Check -Area 'Graph' -Name 'Token' -Remedy 'Check the app registration and that admin consent was granted.' -Probe {
    $null = Get-WsToken -Resource Graph
    $account = Get-WsSignedInAccount
    if ($account) { "acting as $account" } else { 'token acquired' }
}

if ($graphOk) {
    Invoke-Check -Area 'Graph' -Name 'Tenant identity' -Remedy 'Grant Organization.Read.All.' -Probe {
        $info = Get-WsTenantInfo
        "$($info.DisplayName) (country $($info.Country))"
    } | Out-Null

    Invoke-Check -Area 'Graph' -Name 'Verified domains' -Remedy 'Grant Domain.Read.All or Directory.Read.All.' -Probe {
        $script:domains = Get-WsTenantDomain -VerifiedOnly
        ($script:domains | ForEach-Object { $_.Name }) -join ', '
    } | Out-Null

    Invoke-Check -Area 'Graph' -Name 'Subscribed SKUs' -Remedy 'Grant Organization.Read.All.' -Probe {
        $script:skus = Get-WsSubscribedSku
        "$(@($script:skus).Count) SKU(s) in tenant"
    } | Out-Null

    # Do the configured licences exist, and are there enough seats?
    $wanted = @(Cfg 'licenses.skuPartNumbers' @())
    if (-not $wanted -or $wanted.Count -eq 0) {
        Add-Check -Area 'Graph' -Name 'Configured licences' -Status 'WARN' `
            -Detail 'no licences configured' -Remedy 'Set licenses.skuPartNumbers in the config.'
    }
    elseif (Get-Variable -Name skus -Scope Script -ErrorAction SilentlyContinue) {
        foreach ($part in $wanted) {
            $sku = $script:skus | Where-Object { $_.SkuPartNumber -eq $part } | Select-Object -First 1
            if ($null -eq $sku) {
                Add-Check -Area 'Graph' -Name "SKU $part" -Status 'FAIL' -Detail 'not present in this tenant' `
                    -Remedy 'Use a SKU part number from the table below, or buy/trial the licence.'
            }
            elseif ($sku.Available -lt $AttendeeCount) {
                Add-Check -Area 'Graph' -Name "SKU $part" -Status 'WARN' `
                    -Detail "$($sku.Available) seat(s) free, need $AttendeeCount" `
                    -Remedy 'Buy more seats, or reduce the roster.'
            }
            else {
                Add-Check -Area 'Graph' -Name "SKU $part" -Status 'PASS' -Detail "$($sku.Available) seat(s) free"
            }
        }
    }

    $usageLocation = Cfg 'user.usageLocation'
    if ($usageLocation) {
        Add-Check -Area 'Graph' -Name 'usageLocation' -Status 'PASS' -Detail $usageLocation
    }
    else {
        Add-Check -Area 'Graph' -Name 'usageLocation' -Status 'FAIL' -Detail 'not set' `
            -Remedy 'Set user.usageLocation (e.g. ES). Entra refuses licence assignment without it.'
    }
}

# --- Power Platform ------------------------------------------------------------

Write-Host ''
Write-Host 'Power Platform (Developer environments)' -ForegroundColor Cyan

$bapOk = Invoke-Check -Area 'PowerPlatform' -Name 'Token' -Remedy 'Add delegated Power Platform API access, or sign in as a Power Platform Administrator.' -Probe {
    $null = Get-WsToken -Resource PowerPlatform
    'token acquired'
}

if ($bapOk) {
    Invoke-Check -Area 'PowerPlatform' -Name 'List environments' -Remedy @'
Under delegated auth you must be Global or Power Platform Administrator.
Under app-only auth the service principal must be registered with:
  New-PowerAppManagementApp -ApplicationId <client-id>
'@ -Probe {
        $environments = @(Get-WsPowerPlatformEnvironment)
        $developer = @($environments | Where-Object { $_.properties.environmentSku -eq 'Developer' })
        "$($environments.Count) environment(s), $($developer.Count) Developer"
    } | Out-Null
}

# --- Business Central ----------------------------------------------------------

Write-Host ''
Write-Host 'Business Central' -ForegroundColor Cyan

$bcEnvName = Cfg 'businessCentral.environmentName'
$bcEnabled = [bool](Cfg 'businessCentral.enabled' $true)

if (-not $bcEnabled) {
    Add-Check -Area 'BusinessCentral' -Name 'Step' -Status 'SKIP' -Detail 'disabled in config'
}
elseif (-not $bcEnvName) {
    Add-Check -Area 'BusinessCentral' -Name 'Environment name' -Status 'FAIL' -Detail 'not set' `
        -Remedy 'Set businessCentral.environmentName to your BC environment.'
}
else {
    $bcOk = Invoke-Check -Area 'BusinessCentral' -Name 'Token' -Remedy 'Grant the Dynamics 365 Business Central API permissions.' -Probe {
        $null = Get-WsToken -Resource BusinessCentral
        'token acquired'
    }

    $environment = $null
    if ($bcOk) {
        Invoke-Check -Area 'BusinessCentral' -Name 'Environment' -Remedy @'
Under delegated auth you need the Dynamics 365 Administrator or Global Administrator role.
Under app-only auth, authorise the app in the BC admin center under
"Authorized Microsoft Entra apps".
'@ -Probe {
            $script:environment = Get-WsBcEnvironment -EnvironmentName $bcEnvName
            if ($null -eq $script:environment) { throw "Environment '$bcEnvName' not found." }
            "$($script:environment.name): type $($script:environment.type), status $($script:environment.status)"
        } | Out-Null

        $company = $null
        $companyOk = Invoke-Check -Area 'BusinessCentral' -Name 'Companies' -Remedy @'
The automation API runs as a Business Central USER, not just a tenant admin.
Under delegated auth the signed-in admin needs a BC licence and access to this
environment. Under app-only auth, assign the app the D365 AUTOMATION and
EXTEN. MGT. - ADMIN permission sets on the Microsoft Entra Applications page.
'@ -Probe {
            $companies = @(Get-WsBcCompany -EnvironmentName $bcEnvName)
            if ($companies.Count -eq 0) { throw 'No companies returned.' }
            $script:company = $companies | Select-Object -First 1
            ($companies | ForEach-Object { $_.displayName }) -join ', '
        }

        if ($companyOk) {
            Invoke-Check -Area 'BusinessCentral' -Name 'Permission sets' -Remedy 'Confirm the environment has the standard permission sets.' -Probe {
                $sets = @(Get-WsBcPermissionSet -EnvironmentName $bcEnvName -CompanyId $script:company.id)
                $wanted = @(Cfg 'businessCentral.permissionSets' @('D365 FULL ACCESS'))
                if ([bool](Cfg 'businessCentral.grantMcpAdmin' $false)) { $wanted += 'MCP - ADMIN' }

                $missing = @($wanted | Where-Object { $_ -notin @($sets | ForEach-Object { $_.id }) })
                if ($missing.Count -gt 0) { throw "Missing from environment: $($missing -join ', ')" }
                "$($wanted -join ', ') present ($($sets.Count) sets total)"
            } | Out-Null

            # Confirm the configured company name actually matches one that exists.
            $configuredCompany = Cfg 'businessCentral.companyName'
            if ($configuredCompany) {
                $match = @(Get-WsBcCompany -EnvironmentName $bcEnvName -CompanyName $configuredCompany)
                if ($match.Count -gt 0) {
                    Add-Check -Area 'BusinessCentral' -Name 'Configured company' -Status 'PASS' -Detail $configuredCompany
                }
                else {
                    Add-Check -Area 'BusinessCentral' -Name 'Configured company' -Status 'FAIL' `
                        -Detail "'$configuredCompany' not found" -Remedy 'Use one of the company names listed above.'
                }
            }
        }
    }
}

# --- reference tables ----------------------------------------------------------

if (Get-Variable -Name domains -Scope Script -ErrorAction SilentlyContinue) {
    Write-Host ''
    Write-Host 'Verified domains - use one of these for attendee UPNs' -ForegroundColor Cyan
    $script:domains | Sort-Object { -not $_.IsDefault }, Name |
        Format-Table Name, IsDefault, IsInitial -AutoSize | Out-String -Width 200 | Write-Host
}

if (Get-Variable -Name skus -Scope Script -ErrorAction SilentlyContinue) {
    Write-Host 'Licences in this tenant - use SkuPartNumber in the config' -ForegroundColor Cyan
    $script:skus | Where-Object { $_.Enabled -gt 0 } | Sort-Object SkuPartNumber |
        Format-Table SkuPartNumber, Enabled, Consumed, Available -AutoSize | Out-String -Width 200 | Write-Host
}

# --- verdict -------------------------------------------------------------------

$failures = @($checks | Where-Object { $_.Status -eq 'FAIL' })
$warnings = @($checks | Where-Object { $_.Status -eq 'WARN' })

# The verdict is the point of this script, so it bypasses the log level filter.
Write-Host ''
if ($failures.Count -eq 0 -and $warnings.Count -eq 0) {
    Write-Host 'READY TO PROVISION' -ForegroundColor Green
}
elseif ($failures.Count -eq 0) {
    Write-Host "USABLE, with $($warnings.Count) warning(s):" -ForegroundColor Yellow
    foreach ($w in $warnings) { Write-Host "  - $($w.Check): $($w.Detail)`n    $($w.Remedy)" -ForegroundColor Yellow }
}
else {
    Write-Host "NOT READY - $($failures.Count) blocking problem(s):" -ForegroundColor Red
    foreach ($f in $failures) {
        Write-Host "  - $($f.Area)/$($f.Check): $($f.Detail)" -ForegroundColor Red
        if ($f.Remedy) { foreach ($line in ($f.Remedy -split "`n")) { Write-Host "    $line" -ForegroundColor DarkGray } }
    }
}
Write-Host ''
$checks
