#!/usr/bin/env pwsh
#Requires -Version 7.0
# NOTE: the shebang makes this directly executable (./src/<script>.ps1) on macOS
# and Linux. The cost is that Get-Help falls back to auto-generated syntax for
# .SYNOPSIS, because comment-based help must be the very first thing in a file.
# .DESCRIPTION, .PARAMETER and .EXAMPLE still render. Do not remove the shebang
# to 'fix' the synopsis - being runnable matters more.
<#
.SYNOPSIS
    Provisions workshop attendees across Microsoft 365, Power Platform and Business Central.

.DESCRIPTION
    Runs four idempotent steps for one attendee or a CSV of attendees:

      1. User            - creates the Microsoft 365 / Entra ID account.
      2. License         - assigns the licences the workshop needs.
      3. PowerPlatform   - creates a Developer environment owned by the attendee.
      4. BusinessCentral - grants full data access (D365 FULL ACCESS) without
                           Business Central administration, so the attendee can
                           drive the Business Central MCP server as themselves.

    Every step checks current state first, so re-running after a partial failure
    only does the work that is still outstanding. Supports -WhatIf throughout.

.PARAMETER ConfigPath
    Path to the workshop configuration JSON. Defaults to config/workshop.config.json.

.PARAMETER Csv
    Path to a CSV of attendees. Required columns: UserPrincipalName, DisplayName.
    Optional columns: GivenName, Surname, JobTitle, Department, Licenses
    (semicolon-separated SKU part numbers overriding the configured defaults).

.PARAMETER Steps
    Subset of steps to run. Defaults to all four.

.PARAMETER AuthMode
    ClientSecret for unattended runs, DeviceCode to act as a signed-in admin.
    Business Central user synchronisation only works under DeviceCode.

.EXAMPLE
    ./src/New-WorkshopUser.ps1 -UserPrincipalName anna@contoso.com -DisplayName 'Anna Smith' -WhatIf

    Shows everything that would happen for a single attendee without changing anything.

.EXAMPLE
    ./src/New-WorkshopUser.ps1 -Csv data/attendees.csv -AuthMode DeviceCode

    Provisions a whole workshop roster, signing in interactively once.

.EXAMPLE
    ./src/New-WorkshopUser.ps1 -Csv data/attendees.csv -Steps BusinessCentral

    Re-runs only the Business Central permission step for everyone.

.NOTES
    Generated passwords are written to the output directory, which is gitignored.
    Treat those files as secrets: distribute them over a secure channel and delete
    them once the workshop is done.
#>

[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Single')]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..' 'config' 'workshop.config.json'),

    [Parameter(Mandatory, ParameterSetName = 'Single')]
    [ValidatePattern('^[^@\s]+@[^@\s]+\.[^@\s]+$')]
    [string]$UserPrincipalName,

    [Parameter(ParameterSetName = 'Single')][string]$DisplayName,
    [Parameter(ParameterSetName = 'Single')][string]$GivenName,
    [Parameter(ParameterSetName = 'Single')][string]$Surname,
    [Parameter(ParameterSetName = 'Single')][string]$JobTitle,
    [Parameter(ParameterSetName = 'Single')][string]$Department,

    [Parameter(Mandatory, ParameterSetName = 'Bulk')][string]$Csv,

    [ValidateSet('User', 'License', 'PowerPlatform', 'BusinessCentral')]
    [string[]]$Steps = @('User', 'License', 'PowerPlatform', 'BusinessCentral'),

    [ValidateSet('ClientSecret', 'DeviceCode', 'InteractiveBrowser')][string]$AuthMode,
    # Obtain these resources' tokens via the Azure CLI instead of the app
    # registration. Power Platform environment creation needs this.
    [ValidateSet('Graph', 'PowerPlatform', 'BusinessCentral')][string[]]$UseAzureCliFor = @(),
    [string]$TenantId,
    [string]$ClientId,
    [string]$OutputDirectory,
    [ValidateSet('Debug', 'Info', 'Warn', 'Error')][string]$LogLevel = 'Info',
    [switch]$StopOnError
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

foreach ($module in 'WorkshopCommon', 'WorkshopAuth', 'WorkshopEntra', 'WorkshopPowerPlatform', 'WorkshopBusinessCentral') {
    Import-Module (Join-Path $PSScriptRoot 'modules' "$module.psm1") -Force -DisableNameChecking
}
Set-WsLogLevel -Level $LogLevel

# Preference variables do not cross module boundaries: a module function runs in
# its own session state, so -WhatIf on this script does NOT reach the ShouldProcess
# checks inside the Workshop* modules. Every mutating call below therefore passes
# -WhatIf:$isWhatIf explicitly. Without this, a dry run would create real users.
$isWhatIf = [bool]$WhatIfPreference

#region helpers -------------------------------------------------------------

function Get-Setting {
    <#
    .SYNOPSIS
        Safely reads a dotted path out of the configuration object, with a default.
    #>
    param([AllowNull()]$Object, [Parameter(Mandatory)][string]$Path, $Default = $null)

    $current = $Object
    foreach ($segment in ($Path -split '\.')) {
        if ($null -eq $current) { return $Default }
        if ($current -is [System.Collections.IDictionary]) {
            if (-not $current.Contains($segment)) { return $Default }
            $current = $current[$segment]
        }
        else {
            $property = $current.PSObject.Properties[$segment]
            if ($null -eq $property) { return $Default }
            $current = $property.Value
        }
    }
    if ($null -eq $current) { return $Default }
    if ($current -is [string] -and [string]::IsNullOrWhiteSpace($current)) { return $Default }
    return $current
}

function Expand-Template {
    <#
    .SYNOPSIS
        Expands {Placeholder} tokens in a template using an attendee's fields.
    #>
    param([Parameter(Mandatory)][string]$Template, [Parameter(Mandatory)][hashtable]$Values)

    $expanded = $Template
    foreach ($key in $Values.Keys) {
        $expanded = $expanded -replace ('\{' + [regex]::Escape($key) + '\}'), [string]$Values[$key]
    }
    return $expanded
}

function Get-RowValue {
    <#
    .SYNOPSIS
        Reads an optional column from an attendee row, returning $null when the
        column is absent or blank.
    .NOTES
        Set-StrictMode throws on access to a property that does not exist, and a
        CSV carrying only the two required columns legitimately has no GivenName,
        Surname, JobTitle, Department or Licenses column at all.
    #>
    param([AllowNull()]$Row, [Parameter(Mandatory)][string]$Name)

    if ($null -eq $Row) { return $null }
    $property = $Row.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    $value = $property.Value
    if ($value -is [string] -and [string]::IsNullOrWhiteSpace($value)) { return $null }
    return $value
}

function New-StepResult {
    param([Parameter(Mandatory)][string[]]$Names)
    $result = [ordered]@{}
    foreach ($name in $Names) { $result[$name] = 'Skipped' }
    return $result
}

#endregion ------------------------------------------------------------------

Write-Host ''
Write-WsLog 'Workshop attendee provisioning' -Level Step
Write-Host ''

# --- configuration -------------------------------------------------------------

$overrides = @{}
if ($TenantId) { $overrides.tenantId = $TenantId }
if ($ClientId) { $overrides.clientId = $ClientId }
if ($AuthMode) { $overrides.authMode = $AuthMode }

$config = Get-WsConfig -Path $ConfigPath -Override $overrides

$resolvedTenantId = Get-Setting $config 'tenantId'
$resolvedClientId = Get-Setting $config 'clientId'
$resolvedAuthMode = Get-Setting $config 'authMode' 'ClientSecret'

if (-not $resolvedTenantId) { throw "tenantId is missing from '$ConfigPath' (or pass -TenantId)." }
if (-not $resolvedClientId) { throw "clientId is missing from '$ConfigPath' (or pass -ClientId)." }

$clientSecret = $null
if ($resolvedAuthMode -eq 'ClientSecret') {
    $clientSecret = Resolve-WsSecret -Value (Get-Setting $config 'clientSecret') -Name 'clientSecret'
    if (-not $clientSecret) {
        throw "authMode is ClientSecret but no clientSecret was resolved. Set clientSecret in the config (for example 'env:WORKSHOP_CLIENT_SECRET') or use -AuthMode DeviceCode."
    }
}

Initialize-WsAuth -TenantId $resolvedTenantId -ClientId $resolvedClientId -ClientSecret $clientSecret `
    -Mode $resolvedAuthMode -AzureCliResources $UseAzureCliFor | Out-Null
Write-WsLog "Tenant $resolvedTenantId | auth $resolvedAuthMode | steps: $($Steps -join ', ')" -Level Info

$outputDir = if ($OutputDirectory) { $OutputDirectory } else { Get-Setting $config 'output.directory' (Join-Path $PSScriptRoot '..' 'output') }
if (-not (Test-Path -LiteralPath $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }

# --- attendee roster -----------------------------------------------------------

# @() for the same reason: a one-row CSV, or single-attendee mode, would
# otherwise leave $attendees a bare object and $attendees.Count would throw.
$attendees = @(if ($PSCmdlet.ParameterSetName -eq 'Bulk') {
    if (-not (Test-Path -LiteralPath $Csv)) { throw "Attendee CSV not found: $Csv" }
    $rows = Import-Csv -LiteralPath $Csv
    if (-not $rows) { throw "Attendee CSV '$Csv' contains no rows." }

    $missing = @('UserPrincipalName', 'DisplayName') | Where-Object { $_ -notin $rows[0].PSObject.Properties.Name }
    if ($missing) { throw "Attendee CSV is missing required column(s): $($missing -join ', ')." }
    $rows
}
else {
    @([pscustomobject]@{
            UserPrincipalName = $UserPrincipalName
            DisplayName       = if ($DisplayName) { $DisplayName } else { ($UserPrincipalName -split '@')[0] }
            GivenName         = $GivenName
            Surname           = $Surname
            JobTitle          = $JobTitle
            Department        = $Department
        })
})

Write-WsLog "$($attendees.Count) attendee(s) to process" -Level Info

# --- shared Business Central context -------------------------------------------

$bcEnabled     = ('BusinessCentral' -in $Steps) -and [bool](Get-Setting $config 'businessCentral.enabled' $true)
$bcEnvironment = Get-Setting $config 'businessCentral.environmentName'
$bcCompany     = $null

if ($bcEnabled) {
    if (-not $bcEnvironment) { throw 'businessCentral.environmentName is required when the BusinessCentral step is enabled.' }

    $environment = Get-WsBcEnvironment -EnvironmentName $bcEnvironment `
        -ApplicationFamily (Get-Setting $config 'businessCentral.applicationFamily' 'BusinessCentral')
    if ($null -eq $environment) {
        throw "Business Central environment '$bcEnvironment' was not found. Check the name in the Business Central admin center, and that the app is authorised there."
    }
    Write-WsLog "Business Central environment '$bcEnvironment' (type $($environment.type), status $($environment.status))" -Level Info -Context 'bc'

    $companyName = Get-Setting $config 'businessCentral.companyName'
    $companies   = @(Get-WsBcCompany -EnvironmentName $bcEnvironment -CompanyName $companyName)
    $bcCompany   = $companies | Select-Object -First 1

    if ($null -eq $bcCompany) {
        $hint = if ($companyName) { "Company '$companyName' was not found in '$bcEnvironment'." } else { "No companies found in '$bcEnvironment'." }
        throw "$hint Check businessCentral.companyName in the config."
    }
    # Business Central companies may have an empty displayName; the technical
    # name is what the MCP Company header needs in that case.
    $bcCompanyLabel = if (-not [string]::IsNullOrWhiteSpace($bcCompany.displayName)) { $bcCompany.displayName }
    elseif (-not [string]::IsNullOrWhiteSpace($bcCompany.name)) { $bcCompany.name }
    else { $null }

    if ($null -eq $bcCompanyLabel) {
        throw "Company $($bcCompany.id) in '$bcEnvironment' has neither a display name nor a name; the MCP Company header cannot be built."
    }
    Write-WsLog "Using company '$bcCompanyLabel' ($($bcCompany.id))" -Level Info -Context 'bc'

    # Kick the Microsoft 365 -> Business Central user sync once for the whole run
    # rather than once per attendee: it is a tenant-wide operation.
    Sync-WsBcUsersFromEntra -EnvironmentName $bcEnvironment -CompanyId $bcCompany.id -WhatIf:$isWhatIf | Out-Null
}

# Once the sync has failed to deliver one attendee within the timeout, it will not
# deliver the rest either. Fall back to a single lookup each so a large roster does
# not spend the full timeout per person.
$bcSyncTimedOut = $false

# --- provisioning loop ---------------------------------------------------------

$report = [System.Collections.Generic.List[object]]::new()
$stepNames = @('User', 'License', 'PowerPlatform', 'BusinessCentral')

foreach ($attendee in $attendees) {
    $upn = ([string]$attendee.UserPrincipalName).Trim()
    if ([string]::IsNullOrWhiteSpace($upn)) {
        Write-WsLog 'Skipping a CSV row with an empty UserPrincipalName.' -Level Warn
        continue
    }

    Write-Host ''
    Write-WsLog "=== $upn ===" -Level Step

    $record = [ordered]@{
        UserPrincipalName = $upn
        DisplayName       = (Get-RowValue -Row $attendee -Name 'DisplayName')
        ObjectId          = $null
        Password          = $null
        Licenses          = $null
        DevEnvironment    = $null
        DevEnvironmentId  = $null
        BcPermissionSets  = $null
        Steps             = New-StepResult -Names $stepNames
        Errors            = [System.Collections.Generic.List[string]]::new()
    }

    try {
        # ---- Step 1: Entra ID user -------------------------------------------
        $entraUser = $null

        if ('User' -in $Steps) {
            $createParams = @{
                UserPrincipalName             = $upn
                DisplayName                   = if ($record.DisplayName) { $record.DisplayName } else { ($upn -split '@')[0] }
                UsageLocation                 = Get-Setting $config 'user.usageLocation' 'US'
                PasswordLength                = [int](Get-Setting $config 'user.passwordLength' 20)
                ForceChangePasswordNextSignIn = [bool](Get-Setting $config 'user.forceChangePasswordNextSignIn' $true)
            }
            foreach ($optional in 'GivenName', 'Surname', 'JobTitle', 'Department') {
                $value = Get-RowValue -Row $attendee -Name $optional
                if ($null -ne $value) { $createParams[$optional] = $value }
            }

            $created = New-WsEntraUser @createParams -WhatIf:$isWhatIf
            $entraUser = $created.User
            $record.Password = $created.Password
            $record.Steps.User = if ($created.Created) { 'Created' } elseif ($entraUser) { 'AlreadyExists' } else { 'WhatIf' }
        }
        else {
            $entraUser = Get-WsEntraUser -UserPrincipalName $upn
        }

        if ($null -ne $entraUser) { $record.ObjectId = $entraUser.id }

        # Without an object ID (a genuine -WhatIf run, or a user that does not
        # exist) the remaining steps have nothing to act on.
        if ($null -eq $entraUser) {
            if ($WhatIfPreference) {
                Write-WsLog 'Remaining steps need a real user object; skipped under -WhatIf.' -Level Info
            }
            else {
                throw "User '$upn' does not exist. Include the 'User' step to create it."
            }
            $report.Add([pscustomobject]$record)
            continue
        }

        # ---- Step 2: licences -------------------------------------------------
        if ('License' -in $Steps) {
            $rowLicenses = Get-RowValue -Row $attendee -Name 'Licenses'
            # @() wraps the WHOLE if-statement: assigning a single-element array
            # out of an if-block unrolls it to a scalar, and .Count on a String
            # throws under StrictMode. One configured SKU used to crash here.
            $skus = @(if ($null -ne $rowLicenses) {
                    ($rowLicenses -split ';').Trim() | Where-Object { $_ }
                }
                else {
                    Get-Setting $config 'licenses.skuPartNumbers' @()
                })

            if (-not $skus -or $skus.Count -eq 0) {
                Write-WsLog 'No licence SKUs configured - skipping licence assignment.' -Level Warn -Context 'entra'
                $record.Steps.License = 'NoSkusConfigured'
            }
            else {
                $licenseResult = Set-WsUserLicense -UserId $entraUser.id -SkuPartNumber $skus `
                    -IgnoreMissingSku:([bool](Get-Setting $config 'licenses.ignoreMissingSku' $false)) `
                    -WhatIf:$isWhatIf

                $record.Licenses = (@($licenseResult.Assigned) + @($licenseResult.AlreadyHeld)) -join ';'
                $record.Steps.License = if ($licenseResult.Assigned.Count -gt 0) { "Assigned: $($licenseResult.Assigned -join ', ')" }
                elseif ($licenseResult.AlreadyHeld.Count -gt 0) { 'AlreadyLicensed' }
                else { 'NothingAssigned' }

                foreach ($exhausted in $licenseResult.NoSeatsLeft) { $record.Errors.Add("No seats left for SKU $exhausted") }
            }
        }

        # ---- Step 3: Power Platform Developer environment ---------------------
        if ('PowerPlatform' -in $Steps -and [bool](Get-Setting $config 'powerPlatform.enabled' $true)) {
            $template = Get-Setting $config 'powerPlatform.displayNameTemplate' 'DEV - {DisplayName}'
            $envDisplayName = Expand-Template -Template $template -Values @{
                DisplayName       = $record.DisplayName
                UserPrincipalName = $upn
                Alias             = ($upn -split '@')[0]
                GivenName         = Get-RowValue -Row $attendee -Name 'GivenName'
                Surname           = Get-RowValue -Row $attendee -Name 'Surname'
            }

            $envResult = New-WsDeveloperEnvironment `
                -DisplayName   $envDisplayName `
                -OwnerObjectId $entraUser.id `
                -TenantId      $resolvedTenantId `
                -Location      (Get-Setting $config 'powerPlatform.location' 'europe') `
                -CurrencyCode  (Get-Setting $config 'powerPlatform.currencyCode' 'EUR') `
                -BaseLanguage  ([int](Get-Setting $config 'powerPlatform.baseLanguage' 1033)) `
                -Wait:([bool](Get-Setting $config 'powerPlatform.waitForProvisioning' $false)) `
                -TimeoutMinutes ([int](Get-Setting $config 'powerPlatform.timeoutMinutes' 20)) `
                -WhatIf:$isWhatIf

            $record.DevEnvironment   = $envDisplayName
            $record.DevEnvironmentId = $envResult.EnvironmentName
            $record.Steps.PowerPlatform = if ($envResult.Created) { 'Created' } else { 'AlreadyExists' }
        }

        # ---- Step 4: Business Central permissions -----------------------------
        if ($bcEnabled) {
            $permissionSets = @(Get-Setting $config 'businessCentral.permissionSets' @('D365 FULL ACCESS'))
            if ([bool](Get-Setting $config 'businessCentral.grantMcpAdmin' $false)) {
                # Lets the attendee author MCP Server configurations themselves.
                # This is MCP configuration rights, not Business Central administration.
                $permissionSets += 'MCP - ADMIN'
            }

            $waitMinutes = if ($bcSyncTimedOut) { 0 } else { [int](Get-Setting $config 'businessCentral.waitForUserSyncMinutes' 10) }
            $bcUser = Wait-WsBcUser -EnvironmentName $bcEnvironment -CompanyId $bcCompany.id `
                -UserPrincipalName $upn -TimeoutMinutes $waitMinutes `
                -PollSeconds ([int](Get-Setting $config 'businessCentral.userSyncPollSeconds' 20))

            if ($null -eq $bcUser) {
                $bcSyncTimedOut = $true
                $record.Steps.BusinessCentral = 'UserNotSynced'
                $record.Errors.Add("User has not appeared in Business Central '$bcEnvironment' yet. Licences can take a few minutes to flow through. Re-run with -Steps BusinessCentral once they do.")
                Write-WsLog "Business Central has not picked up $upn yet - re-run -Steps BusinessCentral later." -Level Warn -Context 'bc'
            }
            else {
                $assignToAll = [bool](Get-Setting $config 'businessCentral.assignToAllCompanies' $true)
                $grantParams = @{
                    EnvironmentName          = $bcEnvironment
                    CompanyId                = $bcCompany.id
                    UserSecurityId           = $bcUser.userSecurityId
                    PermissionSet            = $permissionSets
                    AllowAdminPermissionSets = [bool](Get-Setting $config 'businessCentral.allowAdminPermissionSets' $false)
                }
                if (-not $assignToAll) { $grantParams.Company = $bcCompany.name }

                $grant = Grant-WsBcPermission @grantParams -WhatIf:$isWhatIf
                $record.BcPermissionSets = (@($grant.Granted) + @($grant.AlreadyHeld)) -join ';'
                $record.Steps.BusinessCentral = if ($grant.Granted.Count -gt 0) { "Granted: $($grant.Granted -join ', ')" } else { 'AlreadyGranted' }

                foreach ($missing in $grant.Unavailable) { $record.Errors.Add("Permission set not available in environment: $missing") }
            }

            # Emit the attendee's MCP client configuration.
            if ([bool](Get-Setting $config 'businessCentral.mcp.emitClientConfig' $true)) {
                $mcp = New-WsBcMcpClientConfig `
                    -TenantId          $resolvedTenantId `
                    -EnvironmentName   $bcEnvironment `
                    -CompanyName       $bcCompanyLabel `
                    -ConfigurationName (Get-Setting $config 'businessCentral.mcp.configurationName') `
                    -McpClientId       (Get-Setting $config 'businessCentral.mcp.clientId') `
                    -CallbackPort      ([int](Get-Setting $config 'businessCentral.mcp.callbackPort' 33418)) `
                    -ClientKind        (Get-Setting $config 'businessCentral.mcp.clientKind' 'ClaudeCode')

                $mcpPath = Join-Path $outputDir ('mcp-{0}.json' -f (($upn -split '@')[0] -replace '[^A-Za-z0-9._-]', '_'))
                $mcp.Config | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $mcpPath -Encoding utf8
                if (-not $isWhatIf) { Write-WsLog "MCP client config written to $mcpPath" -Level Success -Context 'bc' }
            }
        }
    }
    catch {
        $message = $_.Exception.Message
        $record.Errors.Add($message)
        Write-WsLog "Failed for ${upn}: $message" -Level Error
        if ($StopOnError) { $report.Add([pscustomobject]$record); break }
    }

    $report.Add([pscustomobject]$record)
}

# --- reporting ------------------------------------------------------------------

$stamp      = Get-Date -Format 'yyyyMMdd-HHmmss'
$jsonPath   = Join-Path $outputDir "workshop-run-$stamp.json"
$csvPath    = Join-Path $outputDir "workshop-run-$stamp.credentials.csv"

$report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $jsonPath -Encoding utf8

$report | Select-Object UserPrincipalName, DisplayName, Password, Licenses, DevEnvironment, BcPermissionSets,
@{ Name = 'Status'; Expression = { ($_.Steps.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '; ' } },
@{ Name = 'Errors'; Expression = { $_.Errors -join ' | ' } } |
Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding utf8

Write-Host ''
Write-WsLog 'Summary' -Level Step
# Out-String needs an explicit -Width: when there is no real console (CI, a
# scheduled task, redirected output) the host reports a width of -1 and the
# rendered table comes back empty.
$report | Select-Object UserPrincipalName,
@{ Name = 'User'; Expression = { $_.Steps.User } },
@{ Name = 'License'; Expression = { $_.Steps.License } },
@{ Name = 'PowerPlatform'; Expression = { $_.Steps.PowerPlatform } },
@{ Name = 'BusinessCentral'; Expression = { $_.Steps.BusinessCentral } } |
Format-Table -AutoSize | Out-String -Width 400 | Write-Host

$failed = @($report | Where-Object { $_.Errors.Count -gt 0 })
Write-WsLog "Run report : $jsonPath" -Level Info
Write-WsLog "Credentials: $csvPath  (contains passwords - distribute securely, then delete)" -Level Warn

if ($failed.Count -gt 0) {
    Write-WsLog "$($failed.Count) of $($report.Count) attendee(s) reported problems:" -Level Warn
    foreach ($item in $failed) { foreach ($problem in $item.Errors) { Write-WsLog "  $($item.UserPrincipalName): $problem" -Level Warn } }
}
else {
    Write-WsLog "All $($report.Count) attendee(s) processed without errors." -Level Success
}
Write-Host ''

$report
