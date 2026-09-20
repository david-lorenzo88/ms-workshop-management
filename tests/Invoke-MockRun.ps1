#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
    Offline end-to-end exercise of New-WorkshopUser.ps1 against a mocked Microsoft API.
.DESCRIPTION
    Replaces Invoke-WsRestMethod with an in-memory router that serves canned
    Graph / BAP / Business Central responses and records every request. This
    verifies orchestration, idempotency and reporting without a live tenant.
    Run it with: pwsh -File tests/Invoke-MockRun.ps1
#>

param([switch]$SecondPass)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
foreach ($module in 'WorkshopCommon', 'WorkshopAuth', 'WorkshopEntra', 'WorkshopPowerPlatform', 'WorkshopBusinessCentral') {
    Import-Module (Join-Path $root 'src' 'modules' "$module.psm1") -Force -DisableNameChecking
}

$global:MockState = @{
    Requests     = [System.Collections.Generic.List[object]]::new()
    Users        = @{}
    Environments = [System.Collections.Generic.List[object]]::new()
    BcUsers      = @{}
    BcPerms      = @{}
    Licenses     = @{}
    BlankCompanyDisplayName = $false
    SyncBoundToCollectionOnly = $false
}

# Pre-seed Business Central with the synced users so the wait loop resolves.
$global:MockState.BcUsers['anna.smith@contoso.onmicrosoft.com'] = @{ userSecurityId = 'bc000001-0000-0000-0000-000000000001'; userName = 'anna.smith@contoso.onmicrosoft.com'; displayName = 'Anna Smith'; state = 'Enabled' }
$global:MockState.BcUsers['ben.jones@contoso.onmicrosoft.com']  = @{ userSecurityId = 'bc000002-0000-0000-0000-000000000002'; userName = 'BEN.JONES@CONTOSO.ONMICROSOFT.COM'; displayName = 'Ben Jones'; state = 'Enabled' }
# carla is deliberately absent: exercises the "not synced yet" branch.

<#
    The mock shadows Invoke-WebRequest rather than Invoke-WsRestMethod, for two
    reasons: the script under test re-imports its modules with -Force (which would
    discard a mock placed over a module-exported function), and intercepting at the
    HTTP layer keeps the real request building, status handling and JSON parsing in
    the code path under test. Functions outrank cmdlets in PowerShell command
    resolution, so this definition wins over the built-in.
#>
function global:Invoke-WebRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [string]$Method = 'GET',
        [hashtable]$Headers = @{},
        [object]$Body,
        [string]$ContentType,
        [int]$TimeoutSec,
        [switch]$SkipHttpErrorCheck,
        [int]$MaximumRedirection
    )

    $parsedBody = $null
    if ($Body -is [string] -and $Body.TrimStart().StartsWith('{')) {
        try { $parsedBody = $Body | ConvertFrom-Json -Depth 30 } catch { $parsedBody = $Body }
    }
    elseif ($null -ne $Body) { $parsedBody = $Body }

    $global:MockState.Requests.Add([pscustomobject]@{ Method = $Method; Uri = $Uri; Body = $parsedBody })

    function reply($status, $content) {
        [pscustomobject]@{
            StatusCode = $status
            Content    = if ($null -eq $content) { '' } else { ($content | ConvertTo-Json -Depth 20 -Compress) }
            Headers    = @{}
        }
    }

    switch -Regex ($Uri) {

        # ---- token endpoint ----
        'oauth2/v2\.0/devicecode' {
            return reply 200 @{ device_code = 'mock-device-code'; user_code = 'MOCK123'
                verification_uri = 'https://microsoft.com/devicelogin'; interval = 1; expires_in = 900 }
        }
        'oauth2/v2\.0/token' { return reply 200 @{ access_token = 'mock.token.value'; refresh_token = 'mock-refresh'; expires_in = 3600 } }

        # ---- Microsoft Graph ----
        '/v1\.0/organization' {
            return reply 200 @{ value = @(@{ id = 'a664f2f7-ece9-47bd-a471-32a0806ed142'; displayName = 'Contoso Workshop'; countryLetterCode = 'ES' }) }
        }
        '/v1\.0/domains' {
            return reply 200 @{ value = @(
                    @{ id = 'contoso.onmicrosoft.com'; isVerified = $true; isDefault = $true; isInitial = $true }
                    @{ id = 'contoso.com'; isVerified = $true; isDefault = $false; isInitial = $false }
                    @{ id = 'pending.example'; isVerified = $false; isDefault = $false; isInitial = $false }
                ) }
        }
        '/v1\.0/subscribedSkus' {
            return reply 200 @{ value = @(
                    @{ skuId = 'sku-bc-premium'; skuPartNumber = 'DYN365_BUSCENTRAL_PREMIUM'; prepaidUnits = @{ enabled = 25 }; consumedUnits = 3; capabilityStatus = 'Enabled' }
                    @{ skuId = 'sku-pa-dev'; skuPartNumber = 'POWERAPPS_DEV'; prepaidUnits = @{ enabled = 10000 }; consumedUnits = 5; capabilityStatus = 'Enabled' }
                    @{ skuId = 'sku-exhausted'; skuPartNumber = 'POWER_BI_PRO'; prepaidUnits = @{ enabled = 2 }; consumedUnits = 2; capabilityStatus = 'Enabled' }
                ) }
        }
        '/v1\.0/users/([^/?]+)/licenseDetails' {
            $id = $Matches[1]
            $held = if ($global:MockState.Licenses.ContainsKey($id)) { $global:MockState.Licenses[$id] } else { @() }
            return reply 200 @{ value = @($held | ForEach-Object { @{ skuId = $_ } }) }
        }
        '/v1\.0/users/([^/?]+)/assignLicense' {
            $id = $Matches[1]
            if (-not $global:MockState.Licenses.ContainsKey($id)) { $global:MockState.Licenses[$id] = @() }
            foreach ($add in $parsedBody.addLicenses) { $global:MockState.Licenses[$id] += $add.skuId }
            return reply 200 @{ id = $id }
        }
        '/v1\.0/users/([^/?]+)\?\$select' {
            $upn = [uri]::UnescapeDataString($Matches[1])
            if ($global:MockState.Users.ContainsKey($upn)) { return reply 200 $global:MockState.Users[$upn] }
            return reply 404 @{ error = @{ code = 'Request_ResourceNotFound' } }
        }
        '/v1\.0/users$' {
            if ($Method -ne 'POST') { return reply 200 @{ value = @() } }
            $upn = $parsedBody.userPrincipalName
            $user = @{
                id                = ('aad-' + ([guid]::NewGuid().ToString('N').Substring(0, 8)))
                userPrincipalName = $upn
                displayName       = $parsedBody.displayName
                accountEnabled    = $true
                usageLocation     = $parsedBody.usageLocation
            }
            $global:MockState.Users[$upn] = $user
            return reply 201 $user
        }

        # ---- Power Platform (BAP) ----
        'scopes/admin/environments' { return reply 200 @{ value = @($global:MockState.Environments) } }
        'BusinessAppPlatform/environments\?api-version' {
            if ($Method -ne 'POST') { return reply 200 @{ value = @() } }
            $env = @{
                name       = ('env-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
                properties = @{
                    displayName       = $parsedBody.properties.displayName
                    environmentSku    = $parsedBody.properties.environmentSku
                    usedBy            = $parsedBody.properties.usedBy
                    provisioningState = 'Succeeded'
                }
            }
            $global:MockState.Environments.Add([pscustomobject]$env)
            return reply 201 $env
        }

        # ---- Business Central: admin center ----
        '/admin/v2\.\d+/applications/[^/]+/environments/([^/?]+)' {
            return reply 200 @{ name = [uri]::UnescapeDataString($Matches[1]); type = 'Sandbox'; status = 'Active'; countryCode = 'ES' }
        }

        # ---- Business Central: automation API ----
        'automation/v2\.0/companies$' {
            # Real Business Central companies sometimes have an empty displayName.
            $display = if ($global:MockState.BlankCompanyDisplayName) { '' } else { 'CRONUS USA, Inc.' }
            return reply 200 @{ value = @(@{ id = 'c0000001-0000-0000-0000-00000000000c'; name = 'CRONUS'; displayName = $display }) }
        }
        # Bound to a single user entity: .../users({id})/Microsoft.NAV.<action>.
        # The collection form 404s on the real service.
        'users\([^)]+\)/Microsoft\.NAV\.getNewUsersFromOffice365' {
            if ($global:MockState.SyncBoundToCollectionOnly) { return reply 404 @{ error = @{ code = 'NotFound' } } }
            return reply 204 $null
        }
        'users/Microsoft\.NAV\.getNewUsersFromOffice365' { return reply 404 @{ error = @{ code = 'NotFound' } } }
        'companies\([^)]+\)/users$' { return reply 200 @{ value = @($global:MockState.BcUsers.Values) } }
        'companies\([^)]+\)/permissionSets' {
            return reply 200 @{ value = @(
                    @{ id = 'D365 FULL ACCESS'; displayName = 'Dyn. 365 Full Access'; scope = 'System' }
                    @{ id = 'D365 BASIC'; displayName = 'Dyn. 365 Basic'; scope = 'System' }
                    @{ id = 'MCP - ADMIN'; displayName = 'MCP Administrator'; scope = 'System' }
                    @{ id = 'SUPER'; displayName = 'Super'; scope = 'System' }
                ) }
        }
        'users\(([^)]+)\)/userPermissions' {
            $sid = $Matches[1]
            if ($Method -eq 'POST') {
                if (-not $global:MockState.BcPerms.ContainsKey($sid)) { $global:MockState.BcPerms[$sid] = @() }
                $global:MockState.BcPerms[$sid] += $parsedBody.roleId
                return reply 201 @{ roleId = $parsedBody.roleId; userSecurityId = $sid; scope = 'System' }
            }
            $existing = if ($global:MockState.BcPerms.ContainsKey($sid)) { $global:MockState.BcPerms[$sid] } else { @() }
            return reply 200 @{ value = @($existing | ForEach-Object { @{ roleId = $_; userSecurityId = $sid } }) }
        }
    }

    throw "MOCK: no route for $Method $Uri"
}

# --- run -----------------------------------------------------------------------

# Self-contained: build a throwaway config and output directory so the suite runs
# with a bare `pwsh -File tests/Invoke-MockRun.ps1`.
$workDir = Join-Path ([System.IO.Path]::GetTempPath()) ("ws-mock-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $workDir -Force | Out-Null
$env:MOCK_OUT = Join-Path $workDir 'out'
New-Item -ItemType Directory -Path $env:MOCK_OUT -Force | Out-Null
$env:WORKSHOP_CLIENT_SECRET = 'mock-secret'

$configPath = Join-Path $workDir 'workshop.config.json'
$config = Get-Content -LiteralPath (Join-Path $root 'config' 'workshop.config.example.json') -Raw | ConvertFrom-Json
$config.tenantId                                = 'aaaa1111-2222-3333-4444-555566667777'
$config.businessCentral.waitForUserSyncMinutes  = 1
$config.businessCentral.userSyncPollSeconds     = 1
$config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $configPath -Encoding utf8

$script = Join-Path $root 'src' 'New-WorkshopUser.ps1'
Write-Host "Working directory: $workDir" -ForegroundColor DarkGray

Write-Host "`n########## PASS 0: -WhatIf must not mutate anything ##########`n" -ForegroundColor Magenta
& $script -ConfigPath $configPath -UserPrincipalName 'dryrun@contoso.onmicrosoft.com' -DisplayName 'Dry Run' `
    -OutputDirectory $env:MOCK_OUT -LogLevel Warn -WhatIf 3>$null | Out-Null

# Preference variables do not cross module boundaries, so -WhatIf reaching the
# module functions is easy to break. This guards that regression.
$whatIfMutations = @($global:MockState.Requests | Where-Object {
        $_.Method -in 'POST', 'PATCH', 'PUT', 'DELETE' -and $_.Uri -notmatch 'oauth2'
    })
$whatIfFiles = @(Get-ChildItem -Path $env:MOCK_OUT -File -ErrorAction SilentlyContinue)
$global:MockState.Requests.Clear()

Write-Host "`n########## PASS 1: fresh provisioning ##########`n" -ForegroundColor Magenta
$pass1 = & $script -ConfigPath $configPath -Csv (Join-Path $root 'data' 'attendees.example.csv') `
    -OutputDirectory $env:MOCK_OUT -LogLevel Info

Write-Host "`n########## PASS 2: re-run (idempotency) ##########`n" -ForegroundColor Magenta
$pass2 = & $script -ConfigPath $configPath -Csv (Join-Path $root 'data' 'attendees.example.csv') `
    -OutputDirectory $env:MOCK_OUT -LogLevel Info

Write-Host "`n########## PASS 3: CSV with only the required columns ##########`n" -ForegroundColor Magenta
# Set-StrictMode makes a missing optional column a terminating error, so a
# two-column roster is a genuine regression risk.
$minimalCsv = Join-Path $env:MOCK_OUT 'minimal.csv'
"UserPrincipalName,DisplayName`nminimal.user@contoso.onmicrosoft.com,Minimal User" |
    Set-Content -LiteralPath $minimalCsv -Encoding utf8

$pass3 = & $script -ConfigPath $configPath -Csv $minimalCsv -OutputDirectory $env:MOCK_OUT -LogLevel Warn

Write-Host "`n########## PASS 4: pre-flight checker ##########`n" -ForegroundColor Magenta
$preflightOut = & (Join-Path $root 'src' 'Test-WorkshopSetup.ps1') -ConfigPath $configPath -AttendeeCount 10 6>&1 |
    Tee-Object -Variable preflightConsole
$preflight = @($preflightOut | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties.Name -contains 'Status' })
$preflightText = ($preflightConsole | Out-String -Width 200)

Write-Host "`n########## PASS 5: single-element config and blank company name ##########`n" -ForegroundColor Magenta
# One configured SKU and one attendee: a single-element array assigned out of an
# if-block unrolls to a scalar, and .Count on a String throws under StrictMode.
# This crashed every attendee in a real run until it was fixed.
$singleConfig = Join-Path $workDir 'single.json'
$sc = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
$sc.licenses.skuPartNumbers = @('DYN365_BUSCENTRAL_PREMIUM')
# Empty companyName means "use whichever company exists", which is what a real
# config looks like when the company name is not known up front.
$sc.businessCentral.companyName = ''
$sc | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $singleConfig -Encoding utf8

$singleCsv = Join-Path $env:MOCK_OUT 'single.csv'
"UserPrincipalName,DisplayName`nanna.smith@contoso.onmicrosoft.com,Anna Smith" |
    Set-Content -LiteralPath $singleCsv -Encoding utf8

$global:MockState.BlankCompanyDisplayName = $true
$pass5 = & $script -ConfigPath $singleConfig -Csv $singleCsv -OutputDirectory $env:MOCK_OUT -LogLevel Warn
$global:MockState.BlankCompanyDisplayName = $false

# --- assertions ------------------------------------------------------------------

Write-Host "`n########## ASSERTIONS ##########`n" -ForegroundColor Magenta
$failures = [System.Collections.Generic.List[string]]::new()
function Assert($condition, $label) {
    if ($condition) { Write-Host "  PASS  $label" -ForegroundColor Green }
    else { Write-Host "  FAIL  $label" -ForegroundColor Red; $script:failures.Add($label) }
}

Assert ($whatIfMutations.Count -eq 0) "-WhatIf issued no mutating API calls (saw $($whatIfMutations.Count))"
Assert ($whatIfFiles.Count -eq 0) "-WhatIf wrote no files (saw $($whatIfFiles.Count))"
Assert ($pass1.Count -eq 3) 'pass 1 processed 3 attendees'
Assert (@($pass1 | Where-Object { $_.Steps.User -eq 'Created' }).Count -eq 3) 'pass 1 created 3 Entra users'
Assert (@($pass2 | Where-Object { $_.Steps.User -eq 'AlreadyExists' }).Count -eq 3) 'pass 2 detected all users already exist'
Assert (@($pass2 | Where-Object { $_.Steps.License -eq 'AlreadyLicensed' }).Count -eq 3) 'pass 2 skipped already-assigned licences'
Assert (@($pass2 | Where-Object { $_.Steps.PowerPlatform -eq 'AlreadyExists' }).Count -eq 3) 'pass 2 reused existing dev environments'

$anna = $pass1 | Where-Object { $_.UserPrincipalName -like 'anna*' }
Assert ($anna.Steps.BusinessCentral -like 'Granted*D365 FULL ACCESS*') 'anna granted D365 FULL ACCESS'
Assert ($null -ne $anna.Password -and $anna.Password.Length -ge 20) 'anna received a generated password'

$ben = $pass1 | Where-Object { $_.UserPrincipalName -like 'ben*' }
Assert ($ben.Steps.BusinessCentral -like 'Granted*') 'ben matched BC user case-insensitively'

$carla = $pass1 | Where-Object { $_.UserPrincipalName -like 'carla*' }
Assert ($carla.Steps.BusinessCentral -eq 'UserNotSynced') 'carla correctly reported as not yet synced in BC'
Assert ($carla.Errors.Count -gt 0) 'carla carries an actionable error message'

# No SUPER must ever be requested.
$permPosts = $global:MockState.Requests | Where-Object { $_.Method -eq 'POST' -and $_.Uri -match 'userPermissions' }
Assert (@($permPosts | Where-Object { $_.Body.roleId -eq 'SUPER' }).Count -eq 0) 'SUPER was never assigned'
Assert (@($permPosts).Count -eq 2) 'exactly 2 permission assignments (carla skipped)'

# Dev environments must be created on behalf of the attendee, not the admin.
# Scoped to the three roster attendees so later passes cannot skew the counts.
$rosterEnvNames = @('DEV - Anna Smith', 'DEV - Ben Jones', 'DEV - Carla Ruiz')
$envPosts = @($global:MockState.Requests | Where-Object {
        $_.Method -eq 'POST' -and $_.Uri -match 'BusinessAppPlatform/environments\?' -and
        $_.Body.properties.displayName -in $rosterEnvNames
    })
Assert ($envPosts.Count -eq 3) '3 developer environments requested for the roster'
Assert (@($envPosts | Where-Object { $_.Body.properties.environmentSku -eq 'Developer' }).Count -eq 3) 'all environments use the Developer SKU'
Assert (@($envPosts | Where-Object { $_.Body.properties.usedBy.id -like 'aad-*' -and $_.Body.properties.usedBy.type -eq 1 }).Count -eq 3) 'all environments carry usedBy (on behalf of attendee)'

# Ben's per-row licence override must win over the config default.
$benId = ($global:MockState.Users['ben.jones@contoso.onmicrosoft.com']).id
Assert ($global:MockState.Licenses[$benId] -contains 'sku-bc-premium') 'ben got the CSV-specified licences'

# MCP configs land on disk for the users that reached the BC step.
$mcpFiles = @(Get-ChildItem -Path $env:MOCK_OUT -Filter 'mcp-*.json' |
    Where-Object { $_.Name -in 'mcp-anna.smith.json', 'mcp-ben.jones.json', 'mcp-carla.ruiz.json' })
Assert ($mcpFiles.Count -eq 3) 'MCP client configs emitted for the roster'
$annaMcp = Get-Content (Join-Path $env:MOCK_OUT 'mcp-anna.smith.json') -Raw | ConvertFrom-Json
Assert ($annaMcp.mcpServers.businesscentral.url -eq 'https://mcp.businesscentral.dynamics.com') 'MCP config points at the BC MCP endpoint'
Assert ($annaMcp.mcpServers.businesscentral.headers.EnvironmentName -eq 'SANDBOX-WORKSHOP') 'MCP config carries EnvironmentName header'

# The summary table must render even with no console attached (width -1).
$summaryText = $pass1 | Select-Object UserPrincipalName,
@{ Name = 'User'; Expression = { $_.Steps.User } } | Format-Table -AutoSize | Out-String -Width 400
Assert ($summaryText -match 'anna\.smith') 'summary table renders without a console'

# Guardrail: administrative permission sets must be refused by default.
$guardError = $null
try {
    Grant-WsBcPermission -EnvironmentName 'SANDBOX-WORKSHOP' `
        -CompanyId 'c0000001-0000-0000-0000-00000000000c' `
        -UserSecurityId 'bc000001-0000-0000-0000-000000000001' `
        -PermissionSet @('SUPER') -ErrorAction Stop | Out-Null
}
catch { $guardError = $_.Exception.Message }
Assert ($null -ne $guardError -and $guardError -match 'Refusing to assign administrative') 'SUPER is refused by default'

$forced = Grant-WsBcPermission -EnvironmentName 'SANDBOX-WORKSHOP' `
    -CompanyId 'c0000001-0000-0000-0000-00000000000c' `
    -UserSecurityId 'bc000009-0000-0000-0000-000000000009' `
    -PermissionSet @('SUPER') -AllowAdminPermissionSets
Assert ($forced.Granted -contains 'SUPER') 'SUPER is allowed with the explicit opt-in'

# A permission set that does not exist in the environment is reported, not fatal.
$bogus = Grant-WsBcPermission -EnvironmentName 'SANDBOX-WORKSHOP' `
    -CompanyId 'c0000001-0000-0000-0000-00000000000c' `
    -UserSecurityId 'bc000001-0000-0000-0000-000000000001' `
    -PermissionSet @('NOT A REAL SET')
Assert ($bogus.Unavailable -contains 'NOT A REAL SET') 'unknown permission set is reported as unavailable'

Assert ($pass3.Count -eq 1 -and $pass3[0].Steps.User -eq 'Created') 'minimal 2-column CSV provisions without error'
Assert ((@($pass3[0].Errors) -join ' | ') -notmatch 'cannot be found on this object') 'minimal CSV does not trip StrictMode on absent columns'
$minimalEnv = @($global:MockState.Requests | Where-Object {
        $_.Method -eq 'POST' -and $_.Uri -match 'BusinessAppPlatform/environments\?' -and
        $_.Body.properties.displayName -eq 'DEV - Minimal User'
    })
Assert ($minimalEnv.Count -eq 1) 'minimal CSV still templates the environment name'

# A disabled step must not block the verdict - it did, before this was fixed.
$ppOffConfig = Join-Path $workDir 'pp-off.json'
$ppOff = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
$ppOff.powerPlatform.enabled = $false
$ppOff | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $ppOffConfig -Encoding utf8
$ppOffResult = & (Join-Path $root 'src' 'Test-WorkshopSetup.ps1') -ConfigPath $ppOffConfig -AttendeeCount 10 6>$null
$ppRows = @($ppOffResult | Where-Object { $_.Area -eq 'PowerPlatform' })
Assert ($ppRows.Count -eq 1 -and $ppRows[0].Status -eq 'SKIP') 'disabled Power Platform step is skipped, not probed'
Assert (@($ppOffResult | Where-Object { $_.Status -eq 'FAIL' }).Count -eq 0) 'disabling a step does not leave blocking failures'

# The Microsoft 365 -> Business Central sync action is bound to a single user
# entity. Posting to the collection (.../users/Microsoft.NAV.<action>) returns
# 404 on the real service, which silently cost a ten-minute wait per attendee.
$global:MockState.Requests.Clear()
Initialize-WsAuth -TenantId '11111111-1111-1111-1111-111111111111' `
    -ClientId '22222222-2222-2222-2222-222222222222' -Mode DeviceCode | Out-Null
$syncStarted = Sync-WsBcUsersFromEntra -EnvironmentName 'SANDBOX-WORKSHOP' `
    -CompanyId 'c0000001-0000-0000-0000-00000000000c'

$syncPosts = @($global:MockState.Requests | Where-Object {
        $_.Method -eq 'POST' -and $_.Uri -match 'getNewUsersFromOffice365'
    })
Assert ($syncStarted -eq $true) 'user sync reports success against the user-bound route'
Assert ($syncPosts.Count -ge 1) 'a sync action was actually posted'
Assert (@($syncPosts | Where-Object { $_.Uri -match 'users\([^)]+\)/Microsoft\.NAV\.' }).Count -ge 1) 'sync is bound to a user entity'
Assert (@($syncPosts | Where-Object { $_.Uri -match 'users/Microsoft\.NAV\.' }).Count -eq 0) 'sync never uses the collection route that 404s'

$pf = { param($name) @($preflight | Where-Object { $_.Check -eq $name }) | Select-Object -First 1 }
Assert ((& $pf 'Token').Status -eq 'PASS') 'pre-flight acquires a Graph token'
Assert ((& $pf 'Verified domains').Detail -match 'contoso\.onmicrosoft\.com') 'pre-flight lists verified domains only'
Assert ((& $pf 'Verified domains').Detail -notmatch 'pending\.example') 'pre-flight excludes unverified domains'
Assert ((& $pf 'Environment').Status -eq 'PASS') 'pre-flight resolves the BC environment'
Assert ((& $pf 'Permission sets').Status -eq 'PASS') 'pre-flight confirms D365 FULL ACCESS exists'
Assert ((& $pf 'SKU DYN365_BUSCENTRAL_PREMIUM').Status -in 'PASS', 'WARN') 'pre-flight checks seat availability per SKU'
Assert (@($preflight | Where-Object { $_.Status -eq 'FAIL' }).Count -eq 0) 'pre-flight reports no blocking problems against a healthy tenant'
Assert ($preflightText -match 'READY TO PROVISION') 'pre-flight verdict prints even at the default log level'

Assert (@($pass5).Count -eq 1) 'single-attendee CSV yields one result'
Assert ($pass5[0].Errors.Count -eq 0) "single SKU + single attendee runs clean (errors: $($pass5[0].Errors -join '; '))"
Assert ((@($pass5[0].Errors) -join ' | ') -notmatch "property 'Count' cannot be found") 'no StrictMode Count failure on a one-element SKU list'
Assert ($pass5[0].Steps.License -match 'DYN365_BUSCENTRAL_PREMIUM' -or $pass5[0].Steps.License -eq 'AlreadyLicensed') 'the single configured SKU was actually processed'

# A blank displayName must fall back to the technical name, or the MCP Company
# header would be empty and the connection would fail.
$annaMcp2 = Get-Content (Join-Path $env:MOCK_OUT 'mcp-anna.smith.json') -Raw | ConvertFrom-Json
Assert ($annaMcp2.mcpServers.businesscentral.headers.Company -eq 'CRONUS') "blank company displayName falls back to name (got '$($annaMcp2.mcpServers.businesscentral.headers.Company)')"

Write-Host ''
if ($failures.Count -gt 0) {
    Write-Host "$($failures.Count) ASSERTION(S) FAILED" -ForegroundColor Red
    Write-Host "Artifacts left for inspection in $workDir" -ForegroundColor DarkGray
    exit 1
}
Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host 'ALL ASSERTIONS PASSED' -ForegroundColor Green
