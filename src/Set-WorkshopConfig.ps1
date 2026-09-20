#!/usr/bin/env pwsh
#Requires -Version 7.0
# NOTE: the shebang makes this directly executable (./src/<script>.ps1) on macOS
# and Linux. The cost is that Get-Help falls back to auto-generated syntax for
# .SYNOPSIS, because comment-based help must be the very first thing in a file.
# .DESCRIPTION, .PARAMETER and .EXAMPLE still render. Do not remove the shebang
# to 'fix' the synopsis - being runnable matters more.
<#
.SYNOPSIS
    Updates config/workshop.config.json without hand-editing JSON.

.DESCRIPTION
    Sets only the values you pass and leaves everything else alone, so it is safe
    to run repeatedly. Creates the file from the example first if it does not
    exist yet, and prints what changed.

.EXAMPLE
    ./src/Set-WorkshopConfig.ps1 -Licenses PROJECT_MADEIRA_PREVIEW_IW_SKU -EnvironmentName Production -DisablePowerPlatform

.EXAMPLE
    ./src/Set-WorkshopConfig.ps1 -Show

    Prints the current settings without changing anything.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..' 'config' 'workshop.config.json'),
    [string]$TenantId,
    [string]$ClientId,
    [ValidateSet('ClientSecret', 'DeviceCode', 'InteractiveBrowser')][string]$AuthMode,
    [ValidatePattern('^[A-Za-z]{2}$')][string]$UsageLocation,
    [string[]]$Licenses,
    [string]$EnvironmentName,
    [AllowEmptyString()][string]$CompanyName,
    [string[]]$PermissionSets,
    [string]$PowerPlatformLocation,
    [switch]$DisablePowerPlatform,
    [switch]$EnablePowerPlatform,
    [switch]$DisableBusinessCentral,
    [switch]$EnableBusinessCentral,
    [switch]$GrantMcpAdmin,
    [switch]$Show
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'modules' 'WorkshopCommon.psm1') -Force -DisableNameChecking

if ($DisablePowerPlatform -and $EnablePowerPlatform) { throw 'Pass only one of -DisablePowerPlatform / -EnablePowerPlatform.' }
if ($DisableBusinessCentral -and $EnableBusinessCentral) { throw 'Pass only one of -DisableBusinessCentral / -EnableBusinessCentral.' }

# Seed from the example on first use so there is always something to edit.
if (-not (Test-Path -LiteralPath $ConfigPath)) {
    $example = Join-Path $PSScriptRoot '..' 'config' 'workshop.config.example.json'
    if (-not (Test-Path -LiteralPath $example)) { throw "Neither $ConfigPath nor the example config exists." }
    Copy-Item -LiteralPath $example -Destination $ConfigPath
    Write-WsLog "Created $ConfigPath from the example." -Level Success
}

$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json -Depth 20

function Get-Current {
    param([Parameter(Mandatory)][string]$Path)
    $current = $config
    foreach ($segment in ($Path -split '\.')) {
        if ($null -eq $current) { return $null }
        $property = $current.PSObject.Properties[$segment]
        if ($null -eq $property) { return $null }
        $current = $property.Value
    }
    return $current
}

function Set-Value {
    param([Parameter(Mandatory)][string]$Path, [AllowNull()][AllowEmptyString()]$Value)

    $segments = $Path -split '\.'
    $parent = $config
    foreach ($segment in $segments[0..($segments.Count - 2)]) {
        if ($null -eq $parent.PSObject.Properties[$segment]) {
            $parent | Add-Member -NotePropertyName $segment -NotePropertyValue ([pscustomobject]@{}) -Force
        }
        $parent = $parent.$segment
    }

    $leaf = $segments[-1]
    $before = if ($null -ne $parent.PSObject.Properties[$leaf]) { $parent.$leaf } else { $null }
    $parent | Add-Member -NotePropertyName $leaf -NotePropertyValue $Value -Force

    $render = { param($v) if ($null -eq $v) { '(unset)' } elseif ($v -is [array]) { '[' + ($v -join ', ') + ']' } elseif ($v -is [string] -and $v -eq '') { '(empty)' } else { [string]$v } }
    $script:changes.Add([pscustomobject]@{ Setting = $Path; From = (& $render $before); To = (& $render $Value) })
}

$changes = [System.Collections.Generic.List[object]]::new()

if ($PSBoundParameters.ContainsKey('TenantId'))              { Set-Value 'tenantId' $TenantId }
if ($PSBoundParameters.ContainsKey('ClientId'))              { Set-Value 'clientId' $ClientId }
if ($PSBoundParameters.ContainsKey('AuthMode'))              { Set-Value 'authMode' $AuthMode }
if ($PSBoundParameters.ContainsKey('UsageLocation'))         { Set-Value 'user.usageLocation' $UsageLocation }
if ($PSBoundParameters.ContainsKey('Licenses'))              { Set-Value 'licenses.skuPartNumbers' @($Licenses) }
if ($PSBoundParameters.ContainsKey('EnvironmentName'))       { Set-Value 'businessCentral.environmentName' $EnvironmentName }
if ($PSBoundParameters.ContainsKey('CompanyName'))           { Set-Value 'businessCentral.companyName' $CompanyName }
if ($PSBoundParameters.ContainsKey('PermissionSets'))        { Set-Value 'businessCentral.permissionSets' @($PermissionSets) }
if ($PSBoundParameters.ContainsKey('PowerPlatformLocation')) { Set-Value 'powerPlatform.location' $PowerPlatformLocation }
if ($DisablePowerPlatform)   { Set-Value 'powerPlatform.enabled' $false }
if ($EnablePowerPlatform)    { Set-Value 'powerPlatform.enabled' $true }
if ($DisableBusinessCentral) { Set-Value 'businessCentral.enabled' $false }
if ($EnableBusinessCentral)  { Set-Value 'businessCentral.enabled' $true }
if ($GrantMcpAdmin)          { Set-Value 'businessCentral.grantMcpAdmin' $true }

if ($changes.Count -gt 0) {
    if ($PSCmdlet.ShouldProcess($ConfigPath, "Apply $($changes.Count) change(s)")) {
        $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $ConfigPath -Encoding utf8
        Write-WsLog "Updated $ConfigPath" -Level Success
        $changes | Format-Table Setting, From, To -AutoSize | Out-String -Width 200 | Write-Host
    }
}
elseif (-not $Show) {
    Write-WsLog 'Nothing to change. Pass -Show to print the current settings.' -Level Warn
}

if ($Show -or $changes.Count -gt 0) {
    Write-Host 'Current settings' -ForegroundColor Cyan
    [pscustomobject][ordered]@{
        tenantId          = Get-Current 'tenantId'
        clientId          = Get-Current 'clientId'
        authMode          = Get-Current 'authMode'
        usageLocation     = Get-Current 'user.usageLocation'
        licences          = (@(Get-Current 'licenses.skuPartNumbers') -join ', ')
        powerPlatform     = Get-Current 'powerPlatform.enabled'
        bcEnabled         = Get-Current 'businessCentral.enabled'
        bcEnvironment     = Get-Current 'businessCentral.environmentName'
        bcCompany         = Get-Current 'businessCentral.companyName'
        bcPermissionSets  = (@(Get-Current 'businessCentral.permissionSets') -join ', ')
    } | Format-List | Out-String -Width 200 | Write-Host
}
