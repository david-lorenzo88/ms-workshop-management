#Requires -Version 7.0
<#
.SYNOPSIS
    Power Platform Developer environment provisioning via the Business Application
    Platform (BAP) API.
.DESCRIPTION
    Creates a Developer (Dataverse) environment "on behalf of" a named user, so the
    attendee - not the admin running the script - owns the environment and appears
    as its System Administrator.

    The "on behalf of" behaviour comes from the properties.usedBy block on the
    create request. Tenant-level Global and Power Platform Administrators can
    create up to three Developer environments per owner.
.LINK
    https://learn.microsoft.com/power-platform/admin/create-environment
#>

Set-StrictMode -Version Latest

$script:BapBase       = 'https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform'
$script:BapApiVersion = '2021-04-01'

# usedBy.type discriminator for a user principal in the BAP contract.
$script:UsedByTypeUser = 1

function Get-WsPowerPlatformEnvironment {
    <#
    .SYNOPSIS
        Lists Power Platform environments visible to the caller as tenant admin.
    .PARAMETER DisplayName
        Optional exact-match filter on the environment display name.
    #>
    [CmdletBinding()]
    param([string]$DisplayName)

    $uri = '{0}/scopes/admin/environments?api-version={1}' -f $script:BapBase, $script:BapApiVersion
    $environments = (Invoke-WsRestMethod -Uri $uri -Headers (Get-WsAuthHeader -Resource PowerPlatform) -Context 'powerplatform').Content.value

    if ($PSBoundParameters.ContainsKey('DisplayName') -and -not [string]::IsNullOrWhiteSpace($DisplayName)) {
        $environments = $environments | Where-Object { $_.properties.displayName -eq $DisplayName }
    }
    return $environments
}

function Wait-WsEnvironmentProvisioning {
    <#
    .SYNOPSIS
        Polls a BAP long-running operation until the environment reaches a terminal state.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OperationUri,
        [int]$TimeoutMinutes = 20,
        [int]$PollSeconds = 15
    )

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $lastState = ''

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $PollSeconds

        $poll = Invoke-WsRestMethod -Uri $OperationUri -Headers (Get-WsAuthHeader -Resource PowerPlatform) `
            -TolerateStatus @(202, 404) -Context 'powerplatform'

        if ($poll.StatusCode -eq 404) { continue }

        $content = $poll.Content
        $state = $null
        if ($null -ne $content) {
            if ($content.PSObject.Properties.Name -contains 'state' -and $null -ne $content.state) {
                $state = $content.state.id
            }
            elseif ($content.PSObject.Properties.Name -contains 'properties' -and $null -ne $content.properties) {
                $props = $content.properties
                if ($props.PSObject.Properties.Name -contains 'provisioningState') { $state = $props.provisioningState }
                elseif ($props.PSObject.Properties.Name -contains 'states') { $state = $props.states.runtime.id }
            }
        }

        if ($state -and $state -ne $lastState) {
            Write-WsLog "Provisioning state: $state" -Level Info -Context 'powerplatform'
            $lastState = $state
        }

        switch -Regex ($state) {
            '^(Succeeded|Ready|Enabled)$' { return $content }
            '^(Failed|Disabled)$'         { throw "Environment provisioning ended in state '$state'." }
        }

        # A plain 200 with an environment name and no in-flight state means we are done.
        if ($poll.StatusCode -eq 200 -and $null -ne $content -and
            $content.PSObject.Properties.Name -contains 'name' -and -not $state) {
            return $content
        }
    }
    throw "Environment provisioning did not complete within $TimeoutMinutes minutes. It may still finish - check the Power Platform admin center."
}

function New-WsDeveloperEnvironment {
    <#
    .SYNOPSIS
        Creates a Power Platform Developer environment owned by the specified user.
    .PARAMETER OwnerObjectId
        Entra ID object ID of the attendee who will own the environment.
    .PARAMETER Location
        BAP region name, for example europe, unitedstates, uksouth, australia.
    .OUTPUTS
        PSCustomObject with Environment, Created and EnvironmentName.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][string]$OwnerObjectId,
        [Parameter(Mandatory)][string]$TenantId,
        [string]$Location = 'europe',
        [string]$CurrencyCode = 'EUR',
        [int]$BaseLanguage = 1033,
        [string]$Description,
        [switch]$Wait,
        [int]$TimeoutMinutes = 20
    )

    $existing = Get-WsPowerPlatformEnvironment -DisplayName $DisplayName | Select-Object -First 1
    if ($null -ne $existing) {
        Write-WsLog "Environment '$DisplayName' already exists ($($existing.name)) - skipping creation." -Level Warn -Context 'powerplatform'
        return [pscustomobject]@{ Environment = $existing; Created = $false; EnvironmentName = $existing.name }
    }

    if (-not $PSCmdlet.ShouldProcess($DisplayName, "Create Developer environment for $OwnerObjectId in $Location")) {
        return [pscustomobject]@{ Environment = $null; Created = $false; EnvironmentName = $null }
    }

    $properties = @{
        displayName               = $DisplayName
        environmentSku            = 'Developer'
        databaseType              = 'CommonDataService'
        # usedBy transfers ownership to the attendee instead of the calling admin.
        usedBy                    = @{
            id       = $OwnerObjectId
            type     = $script:UsedByTypeUser
            tenantID = $TenantId
        }
        linkedEnvironmentMetadata = @{
            baseLanguage = $BaseLanguage
            currency     = @{ code = $CurrencyCode }
            templates    = @()
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($Description)) { $properties.description = $Description }

    $uri = '{0}/environments?api-version={1}&retainOnProvisionFailure=false' -f $script:BapBase, $script:BapApiVersion

    $response = Invoke-WsRestMethod -Uri $uri -Method POST -Headers (Get-WsAuthHeader -Resource PowerPlatform) `
        -Body @{ location = $Location; properties = $properties } -TolerateStatus @(403) -Context 'powerplatform'

    if ($response.StatusCode -eq 403) {
        throw @"
Power Platform refused the request (HTTP 403).

Most common causes:
  * The service principal has not been registered as a Power Platform admin application.
    Register it with: PUT $script:BapBase/adminApplications/<clientId>?api-version=2020-10-01
  * The tenant setting that governs Developer environment creation blocks it.
    In the Power Platform admin center, check Settings > Features > "Developer environment assignments".
  * The signed-in identity lacks the Global Administrator or Power Platform Administrator role.

Service response: $(ConvertTo-WsRedactedString $response.RawBody)
"@
    }

    $environment = $response.Content
    $environmentName = if ($null -ne $environment -and $environment.PSObject.Properties.Name -contains 'name') { $environment.name } else { $null }
    Write-WsLog "Developer environment requested: $DisplayName" -Level Success -Context 'powerplatform'

    if ($Wait) {
        # A 202 carries the operation URI to poll; a 201 is already complete.
        $operationUri = $null
        foreach ($header in @('Location', 'Operation-Location', 'Azure-AsyncOperation')) {
            if ($response.Headers.ContainsKey($header)) {
                $operationUri = ($response.Headers[$header] | Select-Object -First 1)
                break
            }
        }

        if ($operationUri) {
            Write-WsLog 'Waiting for Dataverse provisioning to finish...' -Level Info -Context 'powerplatform'
            $final = Wait-WsEnvironmentProvisioning -OperationUri $operationUri -TimeoutMinutes $TimeoutMinutes
            if ($null -ne $final) {
                $environment = $final
                if ($final.PSObject.Properties.Name -contains 'name') { $environmentName = $final.name }
            }
            Write-WsLog "Developer environment ready: $DisplayName" -Level Success -Context 'powerplatform'
        }
        else {
            Write-WsLog 'No operation URI returned; treating the environment as provisioned.' -Level Debug -Context 'powerplatform'
        }
    }

    return [pscustomobject]@{ Environment = $environment; Created = $true; EnvironmentName = $environmentName }
}

Export-ModuleMember -Function Get-WsPowerPlatformEnvironment, New-WsDeveloperEnvironment, Wait-WsEnvironmentProvisioning
