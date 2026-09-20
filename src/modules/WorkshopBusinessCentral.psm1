#Requires -Version 7.0
<#
.SYNOPSIS
    Business Central environment lookup, user synchronisation, permission-set
    assignment and MCP client configuration.
.DESCRIPTION
    Grants a workshop attendee full access to Business Central *data* without
    granting Business Central *administration*. The default permission set is
    D365 FULL ACCESS, which covers the whole application within the user's licence
    but excludes the system administration that SUPER confers.

    The Business Central MCP server executes every request under the signed-in
    user's own identity and permissions, so data-level permission sets are exactly
    what an MCP-using attendee needs.
.LINK
    https://learn.microsoft.com/dynamics365/business-central/dev-itpro/administration/itpro-introduction-to-automation-apis
    https://learn.microsoft.com/dynamics365/business-central/dev-itpro/ai/mcp-overview
#>

Set-StrictMode -Version Latest

$script:BcApiBase       = 'https://api.businesscentral.dynamics.com'
$script:BcAdminVersion  = 'v2.29'
$script:McpEndpoint     = 'https://mcp.businesscentral.dynamics.com'

# Permission sets that confer Business Central administration. Assigning any of
# these contradicts the "full data access, no admin" goal, so they are refused
# unless the caller explicitly opts in with -AllowAdminPermissionSets.
$script:AdminPermissionSets = @('SUPER', 'SUPER (DATA)', 'SECURITY', 'D365 SECURITY')

function Get-WsBcAutomationBase {
    param([Parameter(Mandatory)][string]$EnvironmentName)
    return '{0}/v2.0/{1}/api/microsoft/automation/v2.0' -f $script:BcApiBase, [uri]::EscapeDataString($EnvironmentName)
}

function Get-WsBcEnvironment {
    <#
    .SYNOPSIS
        Returns a Business Central environment from the Admin Center API, or $null.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EnvironmentName,
        [string]$ApplicationFamily = 'BusinessCentral'
    )

    $uri = '{0}/admin/{1}/applications/{2}/environments/{3}' -f `
        $script:BcApiBase, $script:BcAdminVersion, $ApplicationFamily, [uri]::EscapeDataString($EnvironmentName)

    $result = Invoke-WsRestMethod -Uri $uri -Headers (Get-WsAuthHeader -Resource BusinessCentral) `
        -TolerateStatus @(404) -Context 'bc'

    if ($result.StatusCode -eq 404) { return $null }
    return $result.Content
}

function Get-WsBcCompany {
    <#
    .SYNOPSIS
        Lists companies in a Business Central environment.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EnvironmentName,
        [string]$CompanyName
    )

    $uri = '{0}/companies' -f (Get-WsBcAutomationBase -EnvironmentName $EnvironmentName)
    $companies = (Invoke-WsRestMethod -Uri $uri -Headers (Get-WsAuthHeader -Resource BusinessCentral) -Context 'bc').Content.value

    if (-not [string]::IsNullOrWhiteSpace($CompanyName)) {
        $companies = $companies | Where-Object { $_.name -eq $CompanyName -or $_.displayName -eq $CompanyName }
    }
    return $companies
}

function Get-WsBcUser {
    <#
    .SYNOPSIS
        Finds a Business Central user by UPN, matching on user name or contact email.
    .NOTES
        Filtering happens client-side: the automation API exposes the sign-in name
        under different properties depending on how the user was provisioned, and a
        workshop tenant has few enough users that listing them is cheap.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EnvironmentName,
        [Parameter(Mandatory)][string]$CompanyId,
        [Parameter(Mandatory)][string]$UserPrincipalName
    )

    $uri = '{0}/companies({1})/users' -f (Get-WsBcAutomationBase -EnvironmentName $EnvironmentName), $CompanyId
    $users = (Invoke-WsRestMethod -Uri $uri -Headers (Get-WsAuthHeader -Resource BusinessCentral) -Context 'bc').Content.value

    $needle = $UserPrincipalName.Trim()
    return $users | Where-Object {
        $candidates = @()
        foreach ($property in @('userName', 'contactEmail', 'authenticationEmail', 'displayName')) {
            if ($_.PSObject.Properties.Name -contains $property -and -not [string]::IsNullOrWhiteSpace($_.$property)) {
                $candidates += $_.$property
            }
        }
        $candidates | Where-Object { $_ -ieq $needle }
    } | Select-Object -First 1
}

function Sync-WsBcUsersFromEntra {
    <#
    .SYNOPSIS
        Triggers Business Central's "Update users from Microsoft 365" synchronisation.
    .NOTES
        getNewUsersFromOffice365 is not supported with service-to-service tokens:
        it requires SUPER in every company, which cannot be granted to an
        application identity. Under app-only auth this is a no-op and the caller
        falls back to waiting for the periodic sync or the user's first sign-in.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$EnvironmentName,
        [Parameter(Mandatory)][string]$CompanyId
    )

    if ((Get-WsAuthMode) -eq 'ClientSecret') {
        Write-WsLog 'Skipping user sync: getNewUsersFromOffice365 does not support app-only authentication. Re-run with -AuthMode DeviceCode to force a sync.' -Level Warn -Context 'bc'
        return $false
    }

    if (-not $PSCmdlet.ShouldProcess($EnvironmentName, 'Synchronise users from Microsoft 365')) { return $false }

    $uri = '{0}/companies({1})/users/Microsoft.NAV.getNewUsersFromOffice365Async' -f `
        (Get-WsBcAutomationBase -EnvironmentName $EnvironmentName), $CompanyId

    $result = Invoke-WsRestMethod -Uri $uri -Method POST -Headers (Get-WsAuthHeader -Resource BusinessCentral) `
        -Body @{} -TolerateStatus @(400, 403, 404) -Context 'bc'

    if (-not $result.Success) {
        Write-WsLog "User sync request returned HTTP $($result.StatusCode); continuing without it." -Level Warn -Context 'bc'
        return $false
    }

    Write-WsLog 'User synchronisation from Microsoft 365 started.' -Level Success -Context 'bc'
    return $true
}

function Wait-WsBcUser {
    <#
    .SYNOPSIS
        Waits for a licensed Entra user to appear in Business Central.
    .DESCRIPTION
        A freshly licensed user is not visible to Business Central until the tenant
        synchronises. This polls, optionally kicking off a sync first.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EnvironmentName,
        [Parameter(Mandatory)][string]$CompanyId,
        [Parameter(Mandatory)][string]$UserPrincipalName,
        [int]$TimeoutMinutes = 10,
        [int]$PollSeconds = 20,
        [switch]$TriggerSync
    )

    if ($TriggerSync) {
        Sync-WsBcUsersFromEntra -EnvironmentName $EnvironmentName -CompanyId $CompanyId | Out-Null
    }

    $deadline    = (Get-Date).AddMinutes($TimeoutMinutes)
    $lastNotice  = [datetime]::MinValue

    while ($true) {
        $user = Get-WsBcUser -EnvironmentName $EnvironmentName -CompanyId $CompanyId -UserPrincipalName $UserPrincipalName
        if ($null -ne $user) { return $user }

        if ((Get-Date) -ge $deadline) { return $null }

        # Report at most once a minute: a long wait should not bury the log.
        if (((Get-Date) - $lastNotice).TotalSeconds -ge 60) {
            $remaining = [int]([math]::Max(0, ($deadline - (Get-Date)).TotalMinutes))
            Write-WsLog "Waiting for $UserPrincipalName to appear in Business Central (up to ${remaining} more min)..." -Level Info -Context 'bc'
            $lastNotice = Get-Date
        }
        Start-Sleep -Seconds $PollSeconds
    }
}

function Get-WsBcPermissionSet {
    <#
    .SYNOPSIS
        Lists permission sets available in a Business Central environment.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EnvironmentName,
        [Parameter(Mandatory)][string]$CompanyId
    )

    $uri = '{0}/companies({1})/permissionSets' -f (Get-WsBcAutomationBase -EnvironmentName $EnvironmentName), $CompanyId
    return (Invoke-WsRestMethod -Uri $uri -Headers (Get-WsAuthHeader -Resource BusinessCentral) -Context 'bc').Content.value
}

function Grant-WsBcPermission {
    <#
    .SYNOPSIS
        Assigns permission sets to a Business Central user, refusing admin-grade sets by default.
    .PARAMETER PermissionSet
        Permission set IDs (roleIds), for example D365 FULL ACCESS.
    .PARAMETER Company
        Optional company name. Omit to assign across all companies.
    .OUTPUTS
        PSCustomObject with Granted, AlreadyHeld and Unavailable collections.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$EnvironmentName,
        [Parameter(Mandatory)][string]$CompanyId,
        [Parameter(Mandatory)][string]$UserSecurityId,
        [Parameter(Mandatory)][string[]]$PermissionSet,
        [string]$Company,
        [switch]$AllowAdminPermissionSets
    )

    $requested = @($PermissionSet | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)

    if (-not $AllowAdminPermissionSets) {
        $blocked = $requested | Where-Object { $script:AdminPermissionSets -contains $_.ToUpperInvariant() }
        if ($blocked) {
            throw @"
Refusing to assign administrative permission set(s): $($blocked -join ', ').

These grant Business Central system administration, not just data access. The
workshop default, D365 FULL ACCESS, already gives full access to all data within
the user's licence without administrative rights.

Pass -AllowAdminPermissionSets (or set businessCentral.allowAdminPermissionSets
in the config file) if you genuinely intend to make attendees BC administrators.
"@
        }
    }

    $automationBase = Get-WsBcAutomationBase -EnvironmentName $EnvironmentName
    $available      = Get-WsBcPermissionSet -EnvironmentName $EnvironmentName -CompanyId $CompanyId
    $availableIds   = @($available | ForEach-Object { $_.id })

    $currentUri = '{0}/companies({1})/users({2})/userPermissions' -f $automationBase, $CompanyId, $UserSecurityId
    $current    = (Invoke-WsRestMethod -Uri $currentUri -Headers (Get-WsAuthHeader -Resource BusinessCentral) -Context 'bc').Content.value
    $currentIds = @($current | ForEach-Object { $_.roleId })

    $outcome = [pscustomobject]@{
        Granted     = [System.Collections.Generic.List[string]]::new()
        AlreadyHeld = [System.Collections.Generic.List[string]]::new()
        Unavailable = [System.Collections.Generic.List[string]]::new()
    }

    foreach ($roleId in $requested) {
        if ($availableIds.Count -gt 0 -and $roleId -notin $availableIds) {
            $outcome.Unavailable.Add($roleId)
            Write-WsLog "Permission set '$roleId' does not exist in environment '$EnvironmentName' - skipping." -Level Warn -Context 'bc'
            continue
        }

        if ($roleId -in $currentIds) {
            $outcome.AlreadyHeld.Add($roleId)
            Write-WsLog "Permission set already assigned: $roleId" -Level Debug -Context 'bc'
            continue
        }

        if (-not $PSCmdlet.ShouldProcess($UserSecurityId, "Assign permission set $roleId")) { continue }

        $body = @{ roleId = $roleId }
        if (-not [string]::IsNullOrWhiteSpace($Company)) { $body.company = $Company }

        Invoke-WsRestMethod -Uri $currentUri -Method POST -Headers (Get-WsAuthHeader -Resource BusinessCentral) `
            -Body $body -Context 'bc' | Out-Null

        $outcome.Granted.Add($roleId)
        Write-WsLog "Assigned permission set: $roleId" -Level Success -Context 'bc'
    }

    return $outcome
}

function New-WsBcMcpClientConfig {
    <#
    .SYNOPSIS
        Builds the MCP client configuration an attendee needs to reach the
        Business Central MCP server.
    .PARAMETER McpClientId
        Application (client) ID of the Entra app registered for MCP hosts, with the
        Dynamics 365 Business Central delegated permission Financials.ReadWrite.All
        and the host's redirect URI (for example http://localhost:33418/callback).
    .PARAMETER Host
        Which client's configuration shape to emit.
    .OUTPUTS
        PSCustomObject with Endpoint, Headers and Config (a ready-to-paste object).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$EnvironmentName,
        [Parameter(Mandatory)][string]$CompanyName,
        [string]$ConfigurationName,
        [string]$McpClientId,
        [int]$CallbackPort = 33418,
        [ValidateSet('ClaudeCode', 'CopilotCli')][string]$ClientKind = 'ClaudeCode',
        [string]$ServerKey = 'businesscentral'
    )

    # Non-ASCII company or configuration names must be base64-wrapped for the headers.
    $headers = [ordered]@{
        TenantId        = $TenantId
        EnvironmentName = $EnvironmentName
        Company         = ConvertTo-WsBcHeaderValue -Value $CompanyName
    }
    if (-not [string]::IsNullOrWhiteSpace($ConfigurationName)) {
        $headers.ConfigurationName = ConvertTo-WsBcHeaderValue -Value $ConfigurationName
    }

    $server = [ordered]@{
        type    = 'http'
        url     = $script:McpEndpoint
        headers = $headers
    }

    if (-not [string]::IsNullOrWhiteSpace($McpClientId)) {
        if ($ClientKind -eq 'ClaudeCode') {
            $server.oauth = [ordered]@{ clientId = $McpClientId; callbackPort = $CallbackPort }
        }
        else {
            $server.tools             = @('*')
            $server.oauthClientId     = $McpClientId
            $server.oauthRedirectPort = "$CallbackPort"
            $server.oauthPublicClient = $true
        }
    }

    return [pscustomobject]@{
        Endpoint = $script:McpEndpoint
        Headers  = $headers
        Config   = [ordered]@{ mcpServers = [ordered]@{ $ServerKey = $server } }
    }
}

Export-ModuleMember -Function Get-WsBcEnvironment, Get-WsBcCompany, Get-WsBcUser, Sync-WsBcUsersFromEntra,
    Wait-WsBcUser, Get-WsBcPermissionSet, Grant-WsBcPermission, New-WsBcMcpClientConfig, Get-WsBcAutomationBase
