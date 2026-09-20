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

    # No ValidateSet: it binds before a comma-joined string can be split.
    # Validated by Resolve-WsListArgument below, which accepts both forms.
    [string[]]$Steps = @('User', 'License', 'PowerPlatform', 'BusinessCentral'),

    [ValidateSet('ClientSecret', 'DeviceCode', 'InteractiveBrowser')][string]$AuthMode,
    # Obtain these resources' tokens via the Azure CLI instead of the app
    # registration. Power Platform environment creation needs this.
    [string[]]$UseAzureCliFor = @(),
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

# No @() wrapper: Resolve-WsListArgument already returns the array intact via
# the comma operator, and wrapping again would nest it one level deeper.
$Steps = Resolve-WsListArgument -Value $Steps -Name 'Steps' `
    -Allowed @('User', 'License', 'PowerPlatform', 'BusinessCentral')
$UseAzureCliFor = Resolve-WsListArgument -Value $UseAzureCliFor -Name 'UseAzureCliFor' `
    -Allowed @('Graph', 'PowerPlatform', 'BusinessCentral')
if ($Steps.Count -eq 0) { throw 'No steps selected. Omit -Steps to run all of them.' }

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

function Invoke-AttendeeStep {
    <#
    .SYNOPSIS
        Runs one phase's work for one attendee, recording a failure against that
        attendee instead of aborting the phase for the rest of the roster.
    #>
    param(
        [Parameter(Mandatory)]$Item,
        [Parameter(Mandatory)][scriptblock]$Action
    )

    if ($Item.Failed) { return }
    try { & $Action }
    catch {
        $message = $_.Exception.Message
        $Item.Record.Errors.Add($message)
        $Item.Failed = $true
        Write-WsLog "Failed for $($Item.Upn): $message" -Level Error
        if ($StopOnError) { throw }
    }
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
}

# --- provisioning, one phase at a time ------------------------------------------
# Phases run across the whole roster before moving on. Licences have to land for
# everyone before a Business Central sync is worth starting, and the sync wait
# then happens once for the cohort rather than once per attendee - which is the
# difference between a couple of minutes and the timeout multiplied by ten.

$stepNames = @('User', 'License', 'PowerPlatform', 'BusinessCentral')
$items = [System.Collections.Generic.List[object]]::new()

foreach ($attendee in $attendees) {
    $upn = ([string]$attendee.UserPrincipalName).Trim()
    if ([string]::IsNullOrWhiteSpace($upn)) {
        Write-WsLog 'Skipping a CSV row with an empty UserPrincipalName.' -Level Warn
        continue
    }

    $items.Add([pscustomobject]@{
            Upn       = $upn
            Attendee  = $attendee
            EntraUser = $null
            Failed    = $false
            Record    = [ordered]@{
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
        })
}

# ---- Phase 1: Entra ID users ---------------------------------------------------

Write-Host ''
Write-WsLog "Phase 1/4  Microsoft 365 accounts ($($items.Count))" -Level Step

foreach ($item in $items) {
    Invoke-AttendeeStep -Item $item -Action {
        if ('User' -in $Steps) {
            $createParams = @{
                UserPrincipalName             = $item.Upn
                DisplayName                   = if ($item.Record.DisplayName) { $item.Record.DisplayName } else { ($item.Upn -split '@')[0] }
                UsageLocation                 = Get-Setting $config 'user.usageLocation' 'US'
                PasswordLength                = [int](Get-Setting $config 'user.passwordLength' 20)
                ForceChangePasswordNextSignIn = [bool](Get-Setting $config 'user.forceChangePasswordNextSignIn' $true)
            }
            foreach ($optional in 'GivenName', 'Surname', 'JobTitle', 'Department') {
                $value = Get-RowValue -Row $item.Attendee -Name $optional
                if ($null -ne $value) { $createParams[$optional] = $value }
            }

            $created = New-WsEntraUser @createParams -WhatIf:$isWhatIf
            $item.EntraUser = $created.User
            $item.Record.Password = $created.Password
            $item.Record.Steps.User = if ($created.Created) { 'Created' } elseif ($created.User) { 'AlreadyExists' } else { 'WhatIf' }
        }
        else {
            $item.EntraUser = Get-WsEntraUser -UserPrincipalName $item.Upn
        }

        if ($null -ne $item.EntraUser) { $item.Record.ObjectId = $item.EntraUser.id }
        elseif (-not $isWhatIf) {
            throw "User '$($item.Upn)' does not exist. Include the 'User' step to create it."
        }
    }
}

# Without a real user object the later phases have nothing to act on.
# Invoking a scriptblock sends its result through the pipeline, which unrolls
# arrays - so every call site wraps it in @() to keep .Count usable.
$live = { @($items | Where-Object { -not $_.Failed -and $null -ne $_.EntraUser }) }

if ($isWhatIf -and @(& $live).Count -eq 0) {
    Write-WsLog 'Remaining phases need real user objects; skipped under -WhatIf.' -Level Info
}

# ---- Phase 2: licences ---------------------------------------------------------

if ('License' -in $Steps -and @(& $live).Count -gt 0) {
    Write-Host ''
    Write-WsLog "Phase 2/4  Licences ($(@(& $live).Count))" -Level Step

    foreach ($item in @(& $live)) {
        Invoke-AttendeeStep -Item $item -Action {
            $rowLicenses = Get-RowValue -Row $item.Attendee -Name 'Licenses'
            $skus = @(if ($null -ne $rowLicenses) {
                    ($rowLicenses -split ';').Trim() | Where-Object { $_ }
                }
                else {
                    Get-Setting $config 'licenses.skuPartNumbers' @()
                })

            if ($skus.Count -eq 0) {
                Write-WsLog 'No licence SKUs configured - skipping licence assignment.' -Level Warn -Context 'entra'
                $item.Record.Steps.License = 'NoSkusConfigured'
                return
            }

            $licenseResult = Set-WsUserLicense -UserId $item.EntraUser.id -SkuPartNumber $skus `
                -IgnoreMissingSku:([bool](Get-Setting $config 'licenses.ignoreMissingSku' $false)) `
                -WhatIf:$isWhatIf

            $item.Record.Licenses = (@($licenseResult.Assigned) + @($licenseResult.AlreadyHeld)) -join ';'
            $item.Record.Steps.License = if ($licenseResult.Assigned.Count -gt 0) { "Assigned: $($licenseResult.Assigned -join ', ')" }
            elseif ($licenseResult.AlreadyHeld.Count -gt 0) { 'AlreadyLicensed' }
            else { 'NothingAssigned' }

            foreach ($exhausted in $licenseResult.NoSeatsLeft) { $item.Record.Errors.Add("No seats left for SKU $exhausted") }
        }
    }
}

# ---- Phase 3: Power Platform Developer environments ----------------------------

if ('PowerPlatform' -in $Steps -and [bool](Get-Setting $config 'powerPlatform.enabled' $true) -and @(& $live).Count -gt 0) {
    Write-Host ''
    Write-WsLog "Phase 3/4  Power Platform environments ($(@(& $live).Count))" -Level Step

    foreach ($item in @(& $live)) {
        Invoke-AttendeeStep -Item $item -Action {
            $template = Get-Setting $config 'powerPlatform.displayNameTemplate' 'DEV - {DisplayName}'
            $envDisplayName = Expand-Template -Template $template -Values @{
                DisplayName       = $item.Record.DisplayName
                UserPrincipalName = $item.Upn
                Alias             = ($item.Upn -split '@')[0]
                GivenName         = Get-RowValue -Row $item.Attendee -Name 'GivenName'
                Surname           = Get-RowValue -Row $item.Attendee -Name 'Surname'
            }

            $envResult = New-WsDeveloperEnvironment `
                -DisplayName   $envDisplayName `
                -OwnerObjectId $item.EntraUser.id `
                -TenantId      $resolvedTenantId `
                -Location      (Get-Setting $config 'powerPlatform.location' 'europe') `
                -MacroRegion   (Get-Setting $config 'powerPlatform.macroRegion') `
                -CurrencyCode  (Get-Setting $config 'powerPlatform.currencyCode' 'EUR') `
                -BaseLanguage  ([int](Get-Setting $config 'powerPlatform.baseLanguage' 1033)) `
                -Wait:([bool](Get-Setting $config 'powerPlatform.waitForProvisioning' $false)) `
                -TimeoutMinutes ([int](Get-Setting $config 'powerPlatform.timeoutMinutes' 20)) `
                -WhatIf:$isWhatIf

            $item.Record.DevEnvironment   = $envDisplayName
            $item.Record.DevEnvironmentId = $envResult.EnvironmentName
            $item.Record.Steps.PowerPlatform = if ($envResult.Created) { 'Created' } else { 'AlreadyExists' }
        }
    }
}

# ---- Phase 4: Business Central --------------------------------------------------

if ($bcEnabled -and @(& $live).Count -gt 0) {
    Write-Host ''
    Write-WsLog "Phase 4/4  Business Central ($(@(& $live).Count))" -Level Step

    # Start the sync now, with every licence already assigned, so one pass picks
    # up the whole roster.
    $bcSyncStarted = Sync-WsBcUsersFromEntra -EnvironmentName $bcEnvironment -CompanyId $bcCompany.id -WhatIf:$isWhatIf

    $waitMinutes = if ($bcSyncStarted) { [int](Get-Setting $config 'businessCentral.waitForUserSyncMinutes' 10) } else { 0 }
    $cohort = Wait-WsBcUserCohort -EnvironmentName $bcEnvironment -CompanyId $bcCompany.id `
        -UserPrincipalName @(& $live | ForEach-Object { $_.Upn }) `
        -TimeoutMinutes $waitMinutes `
        -PollSeconds ([int](Get-Setting $config 'businessCentral.userSyncPollSeconds' 20))

    $permissionSets = @(Get-Setting $config 'businessCentral.permissionSets' @('D365 FULL ACCESS'))
    if ([bool](Get-Setting $config 'businessCentral.grantMcpAdmin' $false)) {
        # Lets the attendee author MCP Server configurations themselves. This is
        # MCP configuration authority, not Business Central administration.
        $permissionSets += 'MCP - ADMIN'
    }
    $assignToAll = [bool](Get-Setting $config 'businessCentral.assignToAllCompanies' $true)

    foreach ($item in @(& $live)) {
        Invoke-AttendeeStep -Item $item -Action {
            $bcUser = $cohort.Map[$item.Upn.ToLowerInvariant()]

            if ($null -eq $bcUser) {
                $item.Record.Steps.BusinessCentral = 'UserNotSynced'
                $reason = if (-not $bcSyncStarted) {
                    "User is not in Business Central '$bcEnvironment', and no automatic sync is running. In Business Central go to Users > 'Update users from Microsoft 365', then re-run with -Steps BusinessCentral."
                }
                else {
                    "User has not appeared in Business Central '$bcEnvironment' yet. Run Users > 'Update users from Microsoft 365' in Business Central, then re-run with -Steps BusinessCentral."
                }
                $item.Record.Errors.Add($reason)
            }
            else {
                $grantParams = @{
                    EnvironmentName          = $bcEnvironment
                    CompanyId                = $bcCompany.id
                    UserSecurityId           = $bcUser.userSecurityId
                    PermissionSet            = $permissionSets
                    AllowAdminPermissionSets = [bool](Get-Setting $config 'businessCentral.allowAdminPermissionSets' $false)
                }
                if (-not $assignToAll) { $grantParams.Company = $bcCompany.name }

                $grant = Grant-WsBcPermission @grantParams -WhatIf:$isWhatIf
                $item.Record.BcPermissionSets = (@($grant.Granted) + @($grant.AlreadyHeld)) -join ';'
                $item.Record.Steps.BusinessCentral = if ($grant.Granted.Count -gt 0) { "Granted: $($grant.Granted -join ', ')" } else { 'AlreadyGranted' }

                foreach ($missing in $grant.Unavailable) { $item.Record.Errors.Add("Permission set not available in environment: $missing") }
            }

            if ([bool](Get-Setting $config 'businessCentral.mcp.emitClientConfig' $true)) {
                $mcp = New-WsBcMcpClientConfig `
                    -TenantId          $resolvedTenantId `
                    -EnvironmentName   $bcEnvironment `
                    -CompanyName       $bcCompanyLabel `
                    -ConfigurationName (Get-Setting $config 'businessCentral.mcp.configurationName') `
                    -McpClientId       (Get-Setting $config 'businessCentral.mcp.clientId') `
                    -CallbackPort      ([int](Get-Setting $config 'businessCentral.mcp.callbackPort' 33418)) `
                    -ClientKind        (Get-Setting $config 'businessCentral.mcp.clientKind' 'ClaudeCode')

                $mcpPath = Join-Path $outputDir ('mcp-{0}.json' -f (($item.Upn -split '@')[0] -replace '[^A-Za-z0-9._-]', '_'))
                $mcp.Config | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $mcpPath -Encoding utf8
                if (-not $isWhatIf) { Write-WsLog "MCP client config written to $mcpPath" -Level Success -Context 'bc' }
            }
        }
    }

    if ($cohort.Missing.Count -gt 0) {
        Write-Host ''
        Write-WsLog "$($cohort.Missing.Count) of $(@(& $live).Count) user(s) are not in Business Central yet." -Level Warn -Context 'bc'
        Write-WsLog "In Business Central: Users > 'Update users from Microsoft 365', then re-run with -Steps BusinessCentral" -Level Warn -Context 'bc'
    }
}

$report = [System.Collections.Generic.List[object]]::new()
foreach ($item in $items) { $report.Add([pscustomobject]$item.Record) }

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
