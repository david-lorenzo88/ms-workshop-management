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
        [ValidateSet('ClientSecret', 'DeviceCode', 'InteractiveBrowser')][string]$Mode = 'ClientSecret',
        [string]$AuthorityHost = 'https://login.microsoftonline.com',
        [hashtable]$ScopeOverride,
        [int]$RedirectPort = 8400
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
        AuthorizeUri = "$AuthorityHost/$TenantId/oauth2/v2.0/authorize"
        RedirectUri  = "http://localhost:$RedirectPort/"
        Cache        = @{}
        RefreshToken = $null
        Account      = $null
        # Optional per-resource scope overrides, for tenants where the
        # '{resource}/.default' form is not what the app registration expects.
        ScopeOverride = $ScopeOverride
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
            default {
                $description = if ($poll.Content.PSObject.Properties.Name -contains 'error_description') { $poll.Content.error_description } else { '' }
                throw (Get-WsAuthFailureMessage -ErrorCode $poll.Content.error -Description $description)
            }
        }
    }
    throw 'Device code sign-in timed out.'
}

function New-WsPkcePair {
    <#
    .SYNOPSIS
        Generates an RFC 7636 PKCE verifier and its S256 challenge.
    #>
    $bytes = [byte[]]::new(32)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)

    # base64url: no padding, - and _ instead of + and /
    $toBase64Url = { param($raw) [Convert]::ToBase64String($raw).TrimEnd('=').Replace('+', '-').Replace('/', '_') }

    $verifier = & $toBase64Url $bytes
    $hash     = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::ASCII.GetBytes($verifier))

    return [pscustomobject]@{ Verifier = $verifier; Challenge = (& $toBase64Url $hash) }
}

function Open-WsBrowser {
    <#
    .SYNOPSIS
        Opens a URL in the platform's default browser. Returns $false if it could
        not, so the caller can fall back to printing the URL.
    #>
    param([Parameter(Mandatory)][string]$Url)
    try {
        if ($IsMacOS)      { & open $Url }
        elseif ($IsLinux)  { & xdg-open $Url 2>$null }
        else               { Start-Process $Url | Out-Null }
        return $true
    }
    catch { return $false }
}

function Request-WsInteractiveBrowserToken {
    <#
    .SYNOPSIS
        OAuth 2.0 authorization code flow with PKCE, over a loopback redirect.
    .DESCRIPTION
        Unlike the device code grant, this is an ordinary interactive browser
        sign-in. Security defaults block device code flow outright but are
        perfectly happy with this, including the MFA they require - so this is
        the delegated flow that works on a tenant with security defaults on.

        No client secret is involved: the app registration is a public client and
        PKCE binds the authorization code to this process.
    #>
    param([Parameter(Mandatory)][string]$Scope)

    $pkce  = New-WsPkcePair
    $state = [guid]::NewGuid().ToString('N')

    $query = ConvertTo-WsFormBody @{
        client_id             = $script:Auth.ClientId
        response_type         = 'code'
        redirect_uri          = $script:Auth.RedirectUri
        response_mode         = 'query'
        scope                 = $Scope
        state                 = $state
        code_challenge        = $pkce.Challenge
        code_challenge_method = 'S256'
        prompt                = 'select_account'
    }
    $authorizeUrl = '{0}?{1}' -f $script:Auth.AuthorizeUri, $query

    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add($script:Auth.RedirectUri)
    try { $listener.Start() }
    catch {
        throw "Could not listen on $($script:Auth.RedirectUri): $($_.Exception.Message)`nAnother process may be using that port. Pass a different -RedirectPort and register the matching redirect URI on the app."
    }

    try {
        Write-Host ''
        Write-Host '  ------------------------------------------------------------------' -ForegroundColor Cyan
        Write-Host '   Sign in to continue' -ForegroundColor Cyan
        if (Open-WsBrowser -Url $authorizeUrl) {
            Write-Host '   A browser window has been opened.' -ForegroundColor White
        }
        else {
            Write-Host '   Open this URL in your browser:' -ForegroundColor White
        }
        Write-Host "   $authorizeUrl" -ForegroundColor DarkGray
        Write-Host '   Sign in as a Global Administrator.' -ForegroundColor DarkGray
        Write-Host '  ------------------------------------------------------------------' -ForegroundColor Cyan
        Write-Host ''

        # Wait for the browser redirect, but never hang the script forever.
        $contextTask = $listener.GetContextAsync()
        if (-not $contextTask.Wait([timespan]::FromMinutes(5))) {
            throw 'Timed out after 5 minutes waiting for the browser sign-in to complete.'
        }
        $context = $contextTask.Result
        $request = $context.Request

        $code          = $request.QueryString['code']
        $returnedState = $request.QueryString['state']
        $authError     = $request.QueryString['error']
        $errorDetail   = $request.QueryString['error_description']

        $ok = [string]::IsNullOrEmpty($authError) -and -not [string]::IsNullOrEmpty($code)
        $body = if ($ok) {
            '<h2>Signed in</h2><p>You can close this tab and return to the terminal.</p>'
        }
        else {
            "<h2>Sign-in failed</h2><p>$([System.Net.WebUtility]::HtmlEncode(($errorDetail ?? $authError)))</p>"
        }

        $html  = "<!doctype html><html><head><meta charset='utf-8'><title>Workshop provisioning</title></head><body style='font-family:system-ui,sans-serif;max-width:32rem;margin:4rem auto;padding:0 1rem'>$body</body></html>"
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($html)
        $context.Response.ContentType     = 'text/html; charset=utf-8'
        $context.Response.ContentLength64 = $bytes.Length
        $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        $context.Response.OutputStream.Close()

        if (-not [string]::IsNullOrEmpty($authError)) {
            throw (Get-WsAuthFailureMessage -ErrorCode $authError -Description $errorDetail)
        }
        if ([string]::IsNullOrEmpty($code)) { throw 'The browser redirect carried no authorization code.' }
        # Guards against a redirect that did not originate from this request.
        if ($returnedState -ne $state) { throw 'State mismatch on the authorization response; aborting.' }
    }
    finally {
        $listener.Stop()
        $listener.Close()
    }

    $tokenBody = ConvertTo-WsFormBody @{
        client_id     = $script:Auth.ClientId
        grant_type    = 'authorization_code'
        code          = $code
        redirect_uri  = $script:Auth.RedirectUri
        code_verifier = $pkce.Verifier
    }
    $result = Invoke-WsRestMethod -Uri $script:Auth.TokenUri -Method POST -Body $tokenBody `
        -ContentType 'application/x-www-form-urlencoded' -TolerateStatus @(400, 401) -Context 'auth'

    if (-not $result.Success) {
        $desc = if ($result.Content.PSObject.Properties.Name -contains 'error_description') { $result.Content.error_description } else { '' }
        throw (Get-WsAuthFailureMessage -ErrorCode $result.Content.error -Description $desc)
    }

    if ($result.Content.PSObject.Properties.Name -contains 'refresh_token') {
        $script:Auth.RefreshToken = $result.Content.refresh_token
    }
    Write-WsLog 'Sign-in complete.' -Level Success -Context 'auth'
    return $result.Content
}

function Get-WsAuthFailureMessage {
    <#
    .SYNOPSIS
        Turns an Entra ID sign-in failure into an explanation and a way forward.
    .DESCRIPTION
        Conditional Access and security defaults both authenticate the user
        successfully and then refuse the token, which is confusing on its own.
        This names the control responsible and states what actually resolves it.
    #>
    [CmdletBinding()]
    param([string]$ErrorCode, [string]$Description)

    # Longest alternatives first: 53003 would otherwise shadow 530034/530035.
    if ($Description -match 'AADSTS(530035|530034|53000|53001|53002|53003|50158)') {
        $code = $Matches[1]
        $meaning = switch ($code) {
            '53000'  { 'a policy requires a compliant or hybrid-joined device' }
            '53001'  { 'a policy requires a domain-joined device' }
            '53002'  { 'a policy requires an approved client application' }
            '530035' { 'a policy requires an Intune app protection policy, or security defaults blocked the flow' }
            '530034' { 'a policy requires remediation before access' }
            '50158'  { 'an external security challenge was not satisfied' }
            default  { 'a Conditional Access policy blocked token issuance' }
        }
        return @"
Sign-in succeeded but the token was refused (AADSTS$code):
$meaning.

Find what blocked it:
  Microsoft Entra admin center > Monitoring > Sign-in logs, open this attempt,
  and read the Policy name on the Conditional Access tab.

If the policy is "Security Defaults":
  Security defaults block the device code grant outright, and they are all or
  nothing - no application, user or group can be excluded. Use
  -AuthMode InteractiveBrowser, which is an ordinary browser sign-in that
  security defaults permit (and which satisfies their MFA requirement).

If it is a named Conditional Access policy:
  Exclude this application - Conditional Access > the policy > Target
  resources > Exclude. Device- and app-based grant controls can never be
  satisfied by a device code sign-in, so an exclusion is the only fix that
  keeps this flow.

Alternatively, -AuthMode ClientSecret avoids user sign-in entirely, at the cost
of the extra setup in docs/app-registration.md (steps 3b, 3c and 4).

Service response: $Description
"@
    }

    if ($ErrorCode -eq 'access_denied') {
        return "Sign-in was declined, or an administrator has not consented to the requested permissions.`nService response: $Description"
    }
    return "Sign-in failed: $ErrorCode - $Description"
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
    if ($null -ne $script:Auth.ScopeOverride -and $script:Auth.ScopeOverride.ContainsKey($Resource)) {
        $scope = $script:Auth.ScopeOverride[$Resource]
    }

    $token = if ($script:Auth.Mode -eq 'ClientSecret') {
        Request-WsClientCredentialsToken -Scope $scope
    }
    else {
        # Try the silent path first so only the first resource prompts.
        $silent = Request-WsRefreshedToken -Scope $scope
        if ($null -ne $silent) { $silent }
        elseif ($script:Auth.Mode -eq 'InteractiveBrowser') { Request-WsInteractiveBrowserToken -Scope $scope }
        else { Request-WsDeviceCodeToken -Scope $scope }
    }

    $expiresIn = if ($token.PSObject.Properties.Name -contains 'expires_in') { [int]$token.expires_in } else { 3600 }
    $script:Auth.Cache[$Resource] = [pscustomobject]@{
        AccessToken = $token.access_token
        ExpiresOn   = (Get-Date).AddSeconds($expiresIn)
    }

    # Record and announce the effective identity once. Creating accounts as the
    # wrong administrator is expensive to undo, so make it visible up front.
    if ($null -eq $script:Auth.Account) {
        foreach ($claim in 'upn', 'unique_name', 'preferred_username', 'app_displayname', 'appid') {
            $value = Get-WsTokenClaim -Token $token.access_token -Claim $claim
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                $script:Auth.Account = $value
                Write-WsLog "Acting as: $value" -Level Success -Context 'auth'
                break
            }
        }
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

function Get-WsSignedInAccount {
    <#
    .SYNOPSIS
        Returns the identity tokens are currently being issued for, once one has
        been acquired.
    #>
    Assert-WsAuthInitialized
    return $script:Auth.Account
}

Export-ModuleMember -Function Initialize-WsAuth, Get-WsToken, Get-WsAuthHeader, Get-WsTokenClaim,
    Get-WsResourceUri, Get-WsAuthMode, Get-WsSignedInAccount, New-WsPkcePair, Get-WsAuthFailureMessage
