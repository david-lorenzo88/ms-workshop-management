#!/usr/bin/env pwsh
#Requires -Version 7.0
# NOTE: the shebang makes this directly executable (./src/<script>.ps1) on macOS
# and Linux. The cost is that Get-Help falls back to auto-generated syntax for
# .SYNOPSIS, because comment-based help must be the very first thing in a file.
# .DESCRIPTION, .PARAMETER and .EXAMPLE still render. Do not remove the shebang
# to 'fix' the synopsis - being runnable matters more.
<#
.SYNOPSIS
    Produces the attendee email and password list to hand out.

.DESCRIPTION
    Two modes:

      default   Assembles the list from previous run reports in the output
                directory. Instant and changes nothing, but only covers accounts
                this toolkit created, since Entra never discloses an existing
                password.

      -Reset    Sets a fresh password on every account in the roster and prints
                those. Definitive: it works regardless of what earlier runs
                recorded, and by default the attendee is NOT forced to change
                the password at first sign-in, which is what you want for a
                workshop.

.EXAMPLE
    pwsh ./src/Export-WorkshopCredentials.ps1 -Csv data/workshop-users.csv

.EXAMPLE
    pwsh ./src/Export-WorkshopCredentials.ps1 -Csv data/workshop-users.csv -Reset -AuthMode InteractiveBrowser
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..' 'config' 'workshop.config.json'),
    [string]$Csv,
    [string]$OutputDirectory,
    [switch]$Reset,
    [switch]$ForceChangeAtFirstSignIn,
    [ValidateRange(12, 128)][int]$PasswordLength = 16,
    [string]$TenantId,
    [string]$ClientId,
    [ValidateSet('ClientSecret', 'DeviceCode', 'InteractiveBrowser')][string]$AuthMode,
    [string]$OutFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

foreach ($module in 'WorkshopCommon', 'WorkshopAuth', 'WorkshopEntra') {
    Import-Module (Join-Path $PSScriptRoot 'modules' "$module.psm1") -Force -DisableNameChecking
}
Set-WsLogLevel -Level Info

$config = $null
if (Test-Path -LiteralPath $ConfigPath) {
    try { $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json -Depth 20 } catch { }
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

$outputDir = if ($OutputDirectory) { $OutputDirectory } else { Cfg 'output.directory' (Join-Path $PSScriptRoot '..' 'output') }
if (-not (Test-Path -LiteralPath $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }

# --- who are we producing credentials for? --------------------------------------

$roster = [System.Collections.Generic.List[string]]::new()
if ($Csv) {
    if (-not (Test-Path -LiteralPath $Csv)) { throw "Attendee CSV not found: $Csv" }
    foreach ($row in (Import-Csv -LiteralPath $Csv)) {
        $upn = ([string]$row.UserPrincipalName).Trim()
        if ($upn) { $roster.Add($upn) }
    }
}

$results = [System.Collections.Generic.List[object]]::new()

if ($Reset) {
    if ($roster.Count -eq 0) { throw 'Pass -Csv so I know whose passwords to reset.' }

    $tenant = if ($TenantId) { $TenantId } else { Cfg 'tenantId' }
    $client = if ($ClientId) { $ClientId } else { Cfg 'clientId' }
    $mode = if ($AuthMode) { $AuthMode } else { Cfg 'authMode' 'InteractiveBrowser' }
    if (-not $tenant -or -not $client) { throw 'Need tenantId and clientId (from the config, or -TenantId/-ClientId).' }

    $secret = $null
    if ($mode -eq 'ClientSecret') { $secret = Resolve-WsSecret -Value (Cfg 'clientSecret') -Name 'clientSecret' }
    Initialize-WsAuth -TenantId $tenant -ClientId $client -ClientSecret $secret -Mode $mode | Out-Null

    Write-WsLog "Resetting passwords for $($roster.Count) account(s)" -Level Step
    foreach ($upn in $roster) {
        try {
            # Not $reset: PowerShell variable names are case-insensitive, so that
            # would assign to the [switch]$Reset parameter, whose declared type
            # rejects the returned object.
            $outcome = Set-WsUserPassword -UserPrincipalName $upn -PasswordLength $PasswordLength `
                -ForceChangePasswordNextSignIn ([bool]$ForceChangeAtFirstSignIn) -WhatIf:$WhatIfPreference
            $results.Add([pscustomobject]@{ Email = $upn; Password = $outcome.Password; Status = if ($outcome.Reset) { 'Reset' } else { 'WhatIf' } })
            if ($outcome.Reset) { Write-WsLog "Reset $upn" -Level Success -Context 'entra' }
        }
        catch {
            $results.Add([pscustomobject]@{ Email = $upn; Password = $null; Status = "Failed: $($_.Exception.Message)" })
            Write-WsLog "Could not reset ${upn}: $($_.Exception.Message)" -Level Error -Context 'entra'
        }
    }
}
else {
    # Assemble from previous run reports: the newest recorded password wins.
    $reports = @(Get-ChildItem -Path $outputDir -Filter 'workshop-run-*.json' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime)
    if ($reports.Count -eq 0) {
        throw "No run reports found in '$outputDir'. Use -Reset to set fresh passwords instead."
    }

    $seen = [ordered]@{}
    foreach ($report in $reports) {
        $rows = @()
        try { $rows = @(Get-Content -LiteralPath $report.FullName -Raw | ConvertFrom-Json -Depth 20) } catch { continue }
        foreach ($row in $rows) {
            if ($null -eq $row -or -not $row.PSObject.Properties['UserPrincipalName']) { continue }
            $upn = [string]$row.UserPrincipalName
            $password = if ($row.PSObject.Properties['Password']) { [string]$row.Password } else { '' }
            if (-not [string]::IsNullOrWhiteSpace($password)) { $seen[$upn] = $password }
            elseif (-not $seen.Contains($upn)) { $seen[$upn] = $null }
        }
    }

    $wanted = if ($roster.Count -gt 0) { $roster } else { @($seen.Keys) }
    foreach ($upn in $wanted) {
        $password = if ($seen.Contains($upn)) { $seen[$upn] } else { $null }
        $results.Add([pscustomobject]@{
                Email    = $upn
                Password = $password
                Status   = if ($password) { 'FromRunReport' } else { 'NoPasswordRecorded' }
            })
    }
    Write-WsLog "Assembled from $($reports.Count) run report(s) in $outputDir" -Level Info
}

# --- output ---------------------------------------------------------------------

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$target = if ($OutFile) { $OutFile } else { Join-Path $outputDir "attendee-credentials-$stamp.csv" }

$results | Export-Csv -LiteralPath $target -NoTypeInformation -Encoding utf8

Write-Host ''
$results | Format-Table Email, Password, Status -AutoSize | Out-String -Width 400 | Write-Host

$missing = @($results | Where-Object { [string]::IsNullOrWhiteSpace($_.Password) })
Write-WsLog "Written to $target" -Level Success
if ($missing.Count -gt 0) {
    Write-WsLog "$($missing.Count) account(s) have no password. Entra cannot disclose an existing one - re-run with -Reset to set fresh ones." -Level Warn
}
Write-WsLog 'This file contains passwords. Distribute securely, then delete it.' -Level Warn
Write-Host ''
