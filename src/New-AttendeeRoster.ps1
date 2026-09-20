#!/usr/bin/env pwsh
#Requires -Version 7.0
# NOTE: the shebang makes this directly executable (./src/<script>.ps1) on macOS
# and Linux. The cost is that Get-Help falls back to auto-generated syntax for
# .SYNOPSIS, because comment-based help must be the very first thing in a file.
# .DESCRIPTION, .PARAMETER and .EXAMPLE still render. Do not remove the shebang
# to 'fix' the synopsis - being runnable matters more.
<#
.SYNOPSIS
    Generates an attendee CSV for New-WorkshopUser.ps1.

.DESCRIPTION
    Builds a numbered roster (user1, user2, ...) for a workshop, in the column
    format New-WorkshopUser.ps1 expects.

.PARAMETER Domain
    The verified domain for the user principal names, for example
    contoso.onmicrosoft.com. List your verified domains in the Microsoft 365
    admin center under Settings > Domains.

.PARAMETER Count
    How many attendees to generate.

.PARAMETER Prefix
    Name stem. 'user' produces user1 ... userN.

.PARAMETER StartAt
    First index. Use this to extend an existing roster without renumbering it.

.EXAMPLE
    ./src/New-AttendeeRoster.ps1 -Domain contoso.onmicrosoft.com -Count 10 -OutFile data/workshop-users.csv

.EXAMPLE
    ./src/New-AttendeeRoster.ps1 -Domain contoso.onmicrosoft.com -Count 5 -StartAt 11 -OutFile data/extra.csv

    Adds user11 ... user15 for late sign-ups.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$')][string]$Domain,
    [ValidateRange(1, 500)][int]$Count = 10,
    [ValidatePattern('^[A-Za-z][A-Za-z0-9._-]*$')][string]$Prefix = 'user',
    [ValidateRange(1, 10000)][int]$StartAt = 1,
    [string]$DisplayNameTemplate = 'Workshop User {0}',
    [string]$Department = 'Workshop',
    [string]$JobTitle = 'Attendee',
    [string[]]$Licenses,
    [Parameter(Mandatory)][string]$OutFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$licenseCell = if ($Licenses) { $Licenses -join ';' } else { '' }

$rows = foreach ($i in $StartAt..($StartAt + $Count - 1)) {
    [pscustomobject][ordered]@{
        UserPrincipalName = '{0}{1}@{2}' -f $Prefix, $i, $Domain
        DisplayName       = $DisplayNameTemplate -f $i
        GivenName         = 'Workshop'
        Surname           = "User $i"
        JobTitle          = $JobTitle
        Department        = $Department
        Licenses          = $licenseCell
    }
}

$directory = Split-Path -Parent $OutFile
if ($directory -and -not (Test-Path -LiteralPath $directory)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
}

$rows | Export-Csv -LiteralPath $OutFile -NoTypeInformation -Encoding utf8

Write-Host "Wrote $($rows.Count) attendee(s) to $OutFile" -ForegroundColor Green
$rows | Select-Object UserPrincipalName, DisplayName | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
