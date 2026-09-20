#Requires -Version 7.0
<#
.SYNOPSIS
    Microsoft 365 / Entra ID user provisioning and licence assignment via Microsoft Graph.
.LINK
    https://learn.microsoft.com/graph/api/user-post-users
    https://learn.microsoft.com/graph/api/user-assignlicense
#>

Set-StrictMode -Version Latest

$script:GraphBase = 'https://graph.microsoft.com/v1.0'

function Get-WsEntraUser {
    <#
    .SYNOPSIS
        Returns the Entra ID user for a UPN, or $null when the account does not exist.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$UserPrincipalName)

    $uri = '{0}/users/{1}?$select=id,userPrincipalName,displayName,accountEnabled,usageLocation,mail,givenName,surname' -f `
        $script:GraphBase, [uri]::EscapeDataString($UserPrincipalName)

    $result = Invoke-WsRestMethod -Uri $uri -Headers (Get-WsAuthHeader -Resource Graph) `
        -TolerateStatus @(404) -Context 'entra'

    if ($result.StatusCode -eq 404) { return $null }
    return $result.Content
}

function New-WsEntraUser {
    <#
    .SYNOPSIS
        Creates a Microsoft 365 user, or returns the existing account if the UPN is taken.
    .DESCRIPTION
        UsageLocation is set at creation time because Entra ID refuses licence
        assignment for users without one.
    .OUTPUTS
        PSCustomObject with User, Password (only for newly created accounts) and Created.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$UserPrincipalName,
        [Parameter(Mandatory)][string]$DisplayName,
        [string]$GivenName,
        [string]$Surname,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z]{2}$')][string]$UsageLocation,
        [string]$Password,
        [ValidateRange(12, 128)][int]$PasswordLength = 20,
        [bool]$ForceChangePasswordNextSignIn = $true,
        [string]$JobTitle,
        [string]$Department
    )

    $existing = Get-WsEntraUser -UserPrincipalName $UserPrincipalName
    if ($null -ne $existing) {
        Write-WsLog "User already exists: $UserPrincipalName" -Level Warn -Context 'entra'

        # An account created outside this script may be missing usageLocation,
        # which would make every later licence assignment fail.
        if ([string]::IsNullOrWhiteSpace($existing.usageLocation)) {
            if ($PSCmdlet.ShouldProcess($UserPrincipalName, "Set usageLocation to $UsageLocation")) {
                Invoke-WsRestMethod -Uri ('{0}/users/{1}' -f $script:GraphBase, $existing.id) -Method PATCH `
                    -Headers (Get-WsAuthHeader -Resource Graph) -Body @{ usageLocation = $UsageLocation } -Context 'entra' | Out-Null
                Write-WsLog "Backfilled usageLocation=$UsageLocation" -Level Success -Context 'entra'
                $existing = Get-WsEntraUser -UserPrincipalName $UserPrincipalName
            }
        }
        return [pscustomobject]@{ User = $existing; Password = $null; Created = $false }
    }

    if (-not $PSCmdlet.ShouldProcess($UserPrincipalName, 'Create Entra ID user')) {
        return [pscustomobject]@{ User = $null; Password = $null; Created = $false }
    }

    $effectivePassword = if ([string]::IsNullOrWhiteSpace($Password)) { New-WsPassword -Length $PasswordLength } else { $Password }

    $body = @{
        accountEnabled    = $true
        displayName       = $DisplayName
        mailNickname      = ConvertTo-WsMailNickname -UserPrincipalName $UserPrincipalName
        userPrincipalName = $UserPrincipalName
        usageLocation     = $UsageLocation
        passwordProfile   = @{
            password                      = $effectivePassword
            forceChangePasswordNextSignIn = $ForceChangePasswordNextSignIn
        }
    }
    foreach ($pair in @{ givenName = $GivenName; surname = $Surname; jobTitle = $JobTitle; department = $Department }.GetEnumerator()) {
        if (-not [string]::IsNullOrWhiteSpace($pair.Value)) { $body[$pair.Key] = $pair.Value }
    }

    $created = (Invoke-WsRestMethod -Uri "$script:GraphBase/users" -Method POST `
            -Headers (Get-WsAuthHeader -Resource Graph) -Body $body -Context 'entra').Content

    Write-WsLog "Created user $UserPrincipalName ($($created.id))" -Level Success -Context 'entra'
    return [pscustomobject]@{ User = $created; Password = $effectivePassword; Created = $true }
}

function Get-WsSubscribedSku {
    <#
    .SYNOPSIS
        Returns the tenant's subscribed SKUs with available-seat counts.
    #>
    [CmdletBinding()]
    param()

    $skus = (Invoke-WsRestMethod -Uri "$script:GraphBase/subscribedSkus" `
            -Headers (Get-WsAuthHeader -Resource Graph) -Context 'entra').Content.value

    return $skus | ForEach-Object {
        [pscustomobject]@{
            SkuId         = $_.skuId
            SkuPartNumber = $_.skuPartNumber
            Enabled       = $_.prepaidUnits.enabled
            Consumed      = $_.consumedUnits
            Available     = [math]::Max(0, $_.prepaidUnits.enabled - $_.consumedUnits)
            Status        = $_.capabilityStatus
        }
    }
}

function Set-WsUserLicense {
    <#
    .SYNOPSIS
        Assigns licences to a user by SKU part number, skipping any already assigned.
    .PARAMETER SkuPartNumber
        Friendly SKU identifiers as shown in the Microsoft 365 admin center, for
        example DYN365_BUSCENTRAL_PREMIUM or POWER_BI_STANDARD.
    .OUTPUTS
        PSCustomObject describing assigned, already-present, unavailable and exhausted SKUs.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$UserId,
        [Parameter(Mandatory)][string[]]$SkuPartNumber,
        [switch]$IgnoreMissingSku
    )

    $result = [pscustomobject]@{
        Assigned      = [System.Collections.Generic.List[string]]::new()
        AlreadyHeld   = [System.Collections.Generic.List[string]]::new()
        NotInTenant   = [System.Collections.Generic.List[string]]::new()
        NoSeatsLeft   = [System.Collections.Generic.List[string]]::new()
    }

    $tenantSkus = Get-WsSubscribedSku
    $held = (Invoke-WsRestMethod -Uri ('{0}/users/{1}/licenseDetails' -f $script:GraphBase, $UserId) `
            -Headers (Get-WsAuthHeader -Resource Graph) -Context 'entra').Content.value
    $heldSkuIds = @($held | ForEach-Object { $_.skuId })

    $toAdd = [System.Collections.Generic.List[hashtable]]::new()

    foreach ($part in ($SkuPartNumber | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
        $sku = $tenantSkus | Where-Object { $_.SkuPartNumber -eq $part } | Select-Object -First 1

        if ($null -eq $sku) {
            $result.NotInTenant.Add($part)
            $message = "SKU '$part' is not present in this tenant."
            if ($IgnoreMissingSku) { Write-WsLog $message -Level Warn -Context 'entra'; continue }
            throw "$message Run 'Get-WsSubscribedSku' to list the SKU part numbers you actually own, or pass -IgnoreMissingSku."
        }

        if ($sku.SkuId -in $heldSkuIds) {
            $result.AlreadyHeld.Add($part)
            Write-WsLog "Licence already assigned: $part" -Level Debug -Context 'entra'
            continue
        }

        if ($sku.Available -le 0) {
            $result.NoSeatsLeft.Add($part)
            Write-WsLog "No seats left for '$part' ($($sku.Consumed)/$($sku.Enabled) consumed) - skipping." -Level Warn -Context 'entra'
            continue
        }

        $toAdd.Add(@{ skuId = $sku.SkuId; disabledPlans = @() })
        $result.Assigned.Add($part)
    }

    if ($toAdd.Count -eq 0) {
        Write-WsLog 'No new licences to assign.' -Level Debug -Context 'entra'
        return $result
    }

    if ($PSCmdlet.ShouldProcess($UserId, "Assign licences: $($result.Assigned -join ', ')")) {
        Invoke-WsRestMethod -Uri ('{0}/users/{1}/assignLicense' -f $script:GraphBase, $UserId) -Method POST `
            -Headers (Get-WsAuthHeader -Resource Graph) `
            -Body @{ addLicenses = @($toAdd); removeLicenses = @() } -Context 'entra' | Out-Null
        Write-WsLog "Assigned licences: $($result.Assigned -join ', ')" -Level Success -Context 'entra'
    }

    return $result
}

function Get-WsTenantDomain {
    <#
    .SYNOPSIS
        Lists the tenant's domains, flagging which are verified and which is default.
    .DESCRIPTION
        User principal names must use a verified domain, so this is the first thing
        to check when building a roster.
    #>
    [CmdletBinding()]
    param([switch]$VerifiedOnly)

    $domains = (Invoke-WsRestMethod -Uri "$script:GraphBase/domains" `
            -Headers (Get-WsAuthHeader -Resource Graph) -Context 'entra').Content.value

    $result = $domains | ForEach-Object {
        [pscustomobject]@{
            Name        = $_.id
            IsVerified  = $_.isVerified
            IsDefault   = $_.isDefault
            IsInitial   = $_.isInitial
        }
    }
    if ($VerifiedOnly) { $result = $result | Where-Object { $_.IsVerified } }
    return $result
}

function Get-WsTenantInfo {
    <#
    .SYNOPSIS
        Returns the tenant's display name and default country, for confirming you
        are pointed at the right tenant before provisioning.
    #>
    [CmdletBinding()]
    param()

    $org = (Invoke-WsRestMethod -Uri "$script:GraphBase/organization" `
            -Headers (Get-WsAuthHeader -Resource Graph) -Context 'entra').Content.value |
        Select-Object -First 1

    return [pscustomobject]@{
        Id          = $org.id
        DisplayName = $org.displayName
        Country     = $org.countryLetterCode
    }
}

Export-ModuleMember -Function Get-WsEntraUser, New-WsEntraUser, Get-WsSubscribedSku, Set-WsUserLicense,
    Get-WsTenantDomain, Get-WsTenantInfo
