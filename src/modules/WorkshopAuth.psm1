#Requires -Version 7.0
<#
.SYNOPSIS
    Microsoft Entra ID token acquisition for the workshop provisioning toolkit.
.DESCRIPTION
    Supports two authentication modes against three different APIs:

      * ClientSecret - OAuth 2.0 client credentials (app-only, unattended).
      * DeviceCode   - OAuth 2.0 device authorization grant (delegated).

    Tokens are cached per resource. In DeviceCode mode the user signs in once and
    the resulting refresh token is redeemed silently for each additional resource,
    so a full run prompts at most one interactive sign-in.

    No external modules are required - everything is plain REST against the
    Microsoft identity platform v2.0 endpoints.
.LINK
    https://learn.microsoft.com/entra/identity-platform/v2-oauth2-client-creds-grant-flow
    https://learn.microsoft.com/entra/identity-platform/v2-oauth2-device-code
#>

Set-StrictMode -Version Latest

$script:Resources = @{
    Graph           = 'https://graph.microsoft.com'
    PowerPlatform   = 'https://api.bap.microsoft.com'
    BusinessCentral = 'https://api.businesscentral.dynamics.com'
}

$script:Auth = $null

function Initialize-WsAuth {
    <#
    .SYNOPSIS
        Configures the authentication context for subsequent Get-WsToken calls.
    .PARAMETER Mode
        ClientSecret for unattended app-only runs; DeviceCode when a step needs to
        act as a signed-in administrator (Business Central user synchronisation
        does not support app-only authentication).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId,
        [string]$ClientSecret,
        [ValidateSet('ClientSecret', 'DeviceCode')][string]$Mode = 'ClientSecret',
        [string]$AuthorityHost = 'https://login.microsoftonline.com'
    )

    if ($Mode -eq 'ClientSecret' -and [string]::IsNullOrWhiteSpace($ClientSecret)) {
        throw 'ClientSecret mode requires -ClientSecret. Set it via the WORKSHOP_CLIENT_SECRET environment variable, or switch to -AuthMode DeviceCode.'
    }

    $script:Auth = [pscustomobject]@{
        TenantId     = $TenantId
        ClientId     = $ClientId
        ClientSecret = $ClientSecret
        Mode         = $Mode
        TokenUri     = "$AuthorityHost/$TenantId/oauth2/v2.0/token"
        DeviceUri    = "$AuthorityHost/$TenantId/oauth2/v2.0/devicecode"
        Cache        = @{}
        RefreshToken = $null
        Account      = $null
    }

    Write-WsLog "Auth context ready (tenant $TenantId, mode $Mode)" -Level Debug -Context 'auth'
    return $script:Auth
}

function Assert-WsAuthInitialized {
    if ($null -eq $script:Auth) { throw 'Authentication is not initialised. Call Initialize-WsAuth first.' }
}

function ConvertTo-WsFormBody {
    param([Parameter(Mandatory)][hashtable]$Fields)
    $pairs = foreach ($key in $Fields.Keys) {
        if ($null -eq $Fields[$key]) { continue }
        '{0}={1}' -f [uri]::EscapeDataString($key), [uri]::EscapeDataString([string]$Fields[$key])
    }
    return ($pairs -join '&')
}

function Get-WsResourceUri {
    param([Parameter(Mandatory)][ValidateSet('Graph', 'PowerPlatform', 'BusinessCentral')][string]$Resource)
    return $script:Resources[$Resource]
}

function Request-WsClientCredentialsToken {
    param([Parameter(Mandatory)][string]$Scope)

    $body = ConvertTo-WsFormBody @{
        client_id     = $script:Auth.ClientId
        client_secret = $script:Auth.ClientSecret
        scope         = $Scope
        grant_type    = 'client_credentials'
    }
    $result = Invoke-WsRestMethod -Uri $script:Auth.TokenUri -Method POST -Body $body `
        -ContentType 'application/x-www-form-urlencoded' -Context 'auth'
    return $result.Content
}

function Request-WsRefreshedToken {
    param([Parameter(Mandatory)][string]$Scope)

    if ([string]::IsNullOrWhiteSpace($script:Auth.RefreshToken)) { return $null }

    $body = ConvertTo-WsFormBody @{
        client_id     = $script:Auth.ClientId
        scope         = $Scope
        grant_type    = 'refresh_token'
        refresh_token = $script:Auth.RefreshToken
    }
    $result = Invoke-WsRestMethod -Uri $script:Auth.TokenUri -Method POST -Body $body `
        -ContentType 'application/x-www-form-urlencoded' -TolerateStatus @(400, 401) -Context 'auth'

    if (-not $result.Success) {
        Write-WsLog 'Cached refresh token was rejected; a new sign-in is required.' -Level Debug -Context 'auth'
        $script:Auth.RefreshToken = $null
        return $null
    }
    if ($result.Content.PSObject.Properties.Name -contains 'refresh_token') {
        $script:Auth.RefreshToken = $result.Content.refresh_token
    }
    return $result.Content
}

function Request-WsDeviceCodeToken {
    param([Parameter(Mandatory)][string]$Scope)

    $body = ConvertTo-WsFormBody @{ client_id = $script:Auth.ClientId; scope = $Scope }
    $device = (Invoke-WsRestMethod -Uri $script:Auth.DeviceUri -Method POST -Body $body `
            -ContentType 'application/x-www-form-urlencoded' -Context 'auth').Content

    Write-Host ''
    Write-Host '  ------------------------------------------------------------------' -ForegroundColor Cyan
    Write-Host '   Sign-in required' -ForegroundColor Cyan
    Write-Host "   Open  : $($device.verification_uri)" -ForegroundColor White
    Write-Host "   Code  : $($device.user_code)" -ForegroundColor Yellow
    Write-Host '   Sign in as a Global Administrator or Dynamics 365 Administrator.' -ForegroundColor DarkGray
    Write-Host '  ------------------------------------------------------------------' -ForegroundColor Cyan
    Write-Host ''

    $interval = [int]$device.interval
    if ($interval -le 0) { $interval = 5 }
    $deadline = (Get-Date).AddSeconds([int]$device.expires_in)

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $interval

        $pollBody = ConvertTo-WsFormBody @{
            grant_type  = 'urn:ietf:params:oauth:grant-type:device_code'
            client_id   = $script:Auth.ClientId
            device_code = $device.device_code
        }
        $poll = Invoke-WsRestMethod -Uri $script:Auth.TokenUri -Method POST -Body $pollBody `
            -ContentType 'application/x-www-form-urlencoded' -TolerateStatus @(400, 401) -Context 'auth'

        if ($poll.Success) {
            if ($poll.Content.PSObject.Properties.Name -contains 'refresh_token') {
                $script:Auth.RefreshToken = $poll.Content.refresh_token
            }
            Write-WsLog 'Sign-in complete.' -Level Success -Context 'auth'
            return $poll.Content
        }

        switch ($poll.Content.error) {
            'authorization_pending' { continue }
            'slow_down'             { $interval += 5; continue }
            'expired_token'         { throw 'Device code expired before sign-in completed. Re-run the script.' }
            'authorization_declined'{ throw 'Sign-in was declined by the user.' }
            default                 { throw "Device code sign-in failed: $($poll.Content.error) - $($poll.Content.error_description)" }
        }
    }
    throw 'Device code sign-in timed out.'
}

function Get-WsToken {
    <#
    .SYNOPSIS
        Returns a valid access token for the requested API, using the cache when possible.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Graph', 'PowerPlatform', 'BusinessCentral')][string]$Resource,
        [switch]$ForceRefresh
    )

    Assert-WsAuthInitialized
    $cached = $script:Auth.Cache[$Resource]
    # Renew a little early so a token cannot expire mid-request.
    if (-not $ForceRefresh -and $null -ne $cached -and $cached.ExpiresOn -gt (Get-Date).AddMinutes(5)) {
        return $cached.AccessToken
    }

    $scope = '{0}/.default' -f (Get-WsResourceUri -Resource $Resource)

    $token = if ($script:Auth.Mode -eq 'ClientSecret') {
        Request-WsClientCredentialsToken -Scope $scope
    }
    else {
        # Try the silent path first so only the first resource prompts.
        $silent = Request-WsRefreshedToken -Scope $scope
        if ($null -ne $silent) { $silent } else { Request-WsDeviceCodeToken -Scope $scope }
    }

    $expiresIn = if ($token.PSObject.Properties.Name -contains 'expires_in') { [int]$token.expires_in } else { 3600 }
    $script:Auth.Cache[$Resource] = [pscustomobject]@{
        AccessToken = $token.access_token
        ExpiresOn   = (Get-Date).AddSeconds($expiresIn)
    }

    if ($null -eq $script:Auth.Account -and $token.PSObject.Properties.Name -contains 'id_token') {
        $script:Auth.Account = Get-WsTokenClaim -Token $token.access_token -Claim 'upn'
    }

    Write-WsLog "Acquired $Resource token (valid ${expiresIn}s)" -Level Debug -Context 'auth'
    return $token.access_token
}

function Get-WsAuthHeader {
    <#
    .SYNOPSIS
        Convenience wrapper returning a ready-to-use Authorization header hashtable.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('Graph', 'PowerPlatform', 'BusinessCentral')][string]$Resource)
    return @{ Authorization = "Bearer $(Get-WsToken -Resource $Resource)" }
}

function Get-WsTokenClaim {
    <#
    .SYNOPSIS
        Reads a single claim out of a JWT payload (no signature validation - this is
        only used for operator-facing diagnostics such as "who am I signed in as").
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)][string]$Claim)

    $parts = $Token -split '\.'
    if ($parts.Count -lt 2) { return $null }

    $payload = $parts[1].Replace('-', '+').Replace('_', '/')
    switch ($payload.Length % 4) { 2 { $payload += '==' } 3 { $payload += '=' } }

    try {
        $json = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
        if ($json.PSObject.Properties.Name -contains $Claim) { return $json.$Claim }
    }
    catch { return $null }
    return $null
}

function Get-WsAuthMode {
    Assert-WsAuthInitialized
    return $script:Auth.Mode
}

Export-ModuleMember -Function Initialize-WsAuth, Get-WsToken, Get-WsAuthHeader, Get-WsTokenClaim,
    Get-WsResourceUri, Get-WsAuthMode
