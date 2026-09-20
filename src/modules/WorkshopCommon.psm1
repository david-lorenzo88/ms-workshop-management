#Requires -Version 7.0
<#
.SYNOPSIS
    Shared helpers for the workshop provisioning toolkit: logging, resilient REST
    calls, secure password generation and configuration loading.
#>

Set-StrictMode -Version Latest

$script:LevelRank    = @{ Debug = 0; Info = 1; Step = 1; Success = 1; Warn = 2; Error = 3 }
$script:MinLevelRank = 1

$script:LevelStyle = @{
    Debug   = @{ Colour = 'DarkGray'; Tag = 'debug' }
    Info    = @{ Colour = 'Gray';     Tag = 'info ' }
    Step    = @{ Colour = 'Cyan';     Tag = 'step ' }
    Success = @{ Colour = 'Green';    Tag = '  ok ' }
    Warn    = @{ Colour = 'Yellow';   Tag = 'warn ' }
    Error   = @{ Colour = 'Red';      Tag = 'fail ' }
}

function Set-WsLogLevel {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('Debug', 'Info', 'Warn', 'Error')][string]$Level)
    $script:MinLevelRank = $script:LevelRank[$Level]
}

function Write-WsLog {
    <#
    .SYNOPSIS
        Writes a timestamped, levelled log line to the host.
    .NOTES
        Uses Write-Host deliberately: this is operator-facing progress output and
        must not pollute the object stream that the provisioning functions return.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Message,
        [ValidateSet('Debug', 'Info', 'Step', 'Success', 'Warn', 'Error')][string]$Level = 'Info',
        [string]$Context
    )

    if ($script:LevelRank[$Level] -lt $script:MinLevelRank) { return }

    $style  = $script:LevelStyle[$Level]
    $stamp  = (Get-Date).ToString('HH:mm:ss')
    $prefix = if ($Context) { "[$Context] " } else { '' }

    Write-Host "$stamp " -NoNewline -ForegroundColor DarkGray
    Write-Host "$($style.Tag) " -NoNewline -ForegroundColor $style.Colour

    # Only the attention-worthy levels colour the message body; Info/Debug use the
    # host's default colour, which Write-Host cannot express as an explicit $null.
    if ($Level -in 'Warn', 'Error', 'Success', 'Step') {
        Write-Host "$prefix$Message" -ForegroundColor $style.Colour
    }
    else {
        Write-Host "$prefix$Message"
    }
}

function ConvertTo-WsRedactedString {
    <#
    .SYNOPSIS
        Masks bearer tokens, secrets and passwords before anything is logged.
    #>
    [CmdletBinding()]
    param([Parameter(Position = 0)][AllowNull()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return $Text }

    $patterns = @(
        @{ Pattern = '(?i)(Bearer\s+)[A-Za-z0-9\-\._~\+\/]+=*'; Replace = '$1<redacted>' }
        @{ Pattern = '(?i)("?(?:client_secret|clientSecret|password|access_token|refresh_token|id_token)"?\s*[:=]\s*"?)[^",&\s}]+'; Replace = '$1<redacted>' }
    )
    foreach ($p in $patterns) { $Text = [regex]::Replace($Text, $p.Pattern, $p.Replace) }
    return $Text
}

function Invoke-WsRestMethod {
    <#
    .SYNOPSIS
        Invoke-WebRequest wrapper with retry/backoff, throttling support and
        structured error reporting.
    .DESCRIPTION
        Retries on 408/429/5xx and on transient transport failures, honouring the
        Retry-After header when the service supplies one. Returns a result object
        rather than throwing on expected non-success codes so callers can branch
        on StatusCode (for example, treating 404 as "does not exist yet").
    .OUTPUTS
        PSCustomObject with StatusCode, Content (parsed JSON or raw string),
        Headers, Success and RawBody.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [ValidateSet('GET', 'POST', 'PATCH', 'PUT', 'DELETE')][string]$Method = 'GET',
        [hashtable]$Headers = @{},
        [object]$Body,
        [string]$ContentType = 'application/json',
        [int]$MaxRetries = 5,
        [int]$TimeoutSec = 120,
        # Status codes that are expected and must not raise. Anything else that is
        # not 2xx causes a terminating error with the service's own message.
        [int[]]$TolerateStatus = @(),
        [string]$Context
    )

    $requestHeaders = @{}
    foreach ($key in $Headers.Keys) { $requestHeaders[$key] = $Headers[$key] }

    $payload = $null
    if ($null -ne $Body) {
        $payload = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 20 -Compress }
    }

    $attempt = 0
    while ($true) {
        $attempt++
        $response  = $null
        $transient = $null

        try {
            $splat = @{
                Uri                = $Uri
                Method             = $Method
                Headers            = $requestHeaders
                TimeoutSec         = $TimeoutSec
                SkipHttpErrorCheck = $true
                ErrorAction        = 'Stop'
                MaximumRedirection = 5
            }
            if ($null -ne $payload) {
                $splat.Body        = $payload
                $splat.ContentType = $ContentType
            }
            Write-WsLog "$Method $Uri" -Level Debug -Context $Context
            $response = Invoke-WebRequest @splat
        }
        catch {
            # Transport-level failure (DNS, TLS, reset). Worth retrying.
            $transient = $_
        }

        if ($null -ne $response) {
            $status = [int]$response.StatusCode
            $raw    = $response.Content

            if ($status -ge 200 -and $status -lt 300) {
                $parsed = $null
                if (-not [string]::IsNullOrWhiteSpace($raw)) {
                    try { $parsed = $raw | ConvertFrom-Json -Depth 30 } catch { $parsed = $raw }
                }
                return [pscustomobject]@{
                    StatusCode = $status
                    Content    = $parsed
                    Headers    = $response.Headers
                    Success    = $true
                    RawBody    = $raw
                }
            }

            if ($status -in $TolerateStatus) {
                $parsed = $null
                if (-not [string]::IsNullOrWhiteSpace($raw)) {
                    try { $parsed = $raw | ConvertFrom-Json -Depth 30 } catch { $parsed = $raw }
                }
                return [pscustomobject]@{
                    StatusCode = $status
                    Content    = $parsed
                    Headers    = $response.Headers
                    Success    = $false
                    RawBody    = $raw
                }
            }

            $retryable = $status -in @(408, 429, 500, 502, 503, 504)
            if (-not $retryable -or $attempt -gt $MaxRetries) {
                $detail = ConvertTo-WsRedactedString $raw
                if ($detail.Length -gt 1500) { $detail = $detail.Substring(0, 1500) + ' ...(truncated)' }
                throw "HTTP $status from $Method $Uri`n$detail"
            }

            # Honour Retry-After when present, otherwise exponential backoff.
            $delay = [math]::Min([math]::Pow(2, $attempt), 60)
            if ($response.Headers.ContainsKey('Retry-After')) {
                $hinted = 0
                if ([int]::TryParse(($response.Headers['Retry-After'] | Select-Object -First 1), [ref]$hinted) -and $hinted -gt 0) {
                    $delay = [math]::Min($hinted, 120)
                }
            }
            Write-WsLog "HTTP $status - retrying in ${delay}s (attempt $attempt/$MaxRetries)" -Level Warn -Context $Context
            Start-Sleep -Seconds $delay
            continue
        }

        # Parameter-binding and URI-format faults are programming errors: retrying
        # them just stalls the run for a minute before failing anyway.
        $fatalTypes = @(
            'System.Management.Automation.ParameterBindingException',
            'System.UriFormatException',
            'System.ArgumentException'
        )
        if ($transient.Exception.GetType().FullName -in $fatalTypes) {
            throw "Request could not be issued: $Method $Uri`n$($transient.Exception.Message)"
        }

        if ($attempt -gt $MaxRetries) {
            throw "Request failed after $MaxRetries retries: $Method $Uri`n$($transient.Exception.Message)"
        }
        $delay = [math]::Min([math]::Pow(2, $attempt), 60)
        Write-WsLog "Transport error - retrying in ${delay}s (attempt $attempt/$MaxRetries): $($transient.Exception.Message)" -Level Warn -Context $Context
        Start-Sleep -Seconds $delay
    }
}

function New-WsPassword {
    <#
    .SYNOPSIS
        Generates a cryptographically secure password that satisfies the default
        Entra ID complexity rules.
    .DESCRIPTION
        Guarantees at least one character from each required class, then fills the
        remainder from the combined alphabet and shuffles using a CSPRNG. Ambiguous
        glyphs (O/0, l/1/I) are excluded so passwords survive being read aloud or
        retyped at a workshop.
    #>
    [CmdletBinding()]
    param([ValidateRange(12, 128)][int]$Length = 20)

    $upper   = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $lower   = 'abcdefghijkmnopqrstuvwxyz'
    $digits  = '23456789'
    $special = '!@#$%^&*-_=+?'
    $all     = $upper + $lower + $digits + $special

    # RandomNumberGenerator.GetInt32 is uniform and unbiased, unlike % on a raw byte.
    $pick  = { param($set) $set[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32(0, $set.Length)] }
    $chars = [System.Collections.Generic.List[char]]::new()

    foreach ($set in @($upper, $lower, $digits, $special)) { $chars.Add((& $pick $set)) }
    while ($chars.Count -lt $Length) { $chars.Add((& $pick $all)) }

    # Fisher-Yates shuffle so the guaranteed characters are not always in front.
    for ($i = $chars.Count - 1; $i -gt 0; $i--) {
        $j = [System.Security.Cryptography.RandomNumberGenerator]::GetInt32(0, $i + 1)
        ($chars[$i], $chars[$j]) = ($chars[$j], $chars[$i])
    }
    return -join $chars
}

function ConvertTo-WsMailNickname {
    <#
    .SYNOPSIS
        Derives a valid Entra ID mailNickname from a user principal name.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$UserPrincipalName)

    $local = ($UserPrincipalName -split '@')[0]
    $clean = ($local -replace '[^A-Za-z0-9._-]', '').Trim('.', '_', '-')
    if ([string]::IsNullOrWhiteSpace($clean)) { $clean = 'user' + [guid]::NewGuid().ToString('N').Substring(0, 8) }
    if ($clean.Length -gt 64) { $clean = $clean.Substring(0, 64) }
    return $clean
}

function ConvertTo-WsBcHeaderValue {
    <#
    .SYNOPSIS
        Encodes a Business Central MCP header value, applying the RFC 2047 style
        base64 wrapper that the MCP server requires for non-ASCII values.
    .LINK
        https://learn.microsoft.com/dynamics365/business-central/dev-itpro/ai/mcp-overview
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    if ([string]::IsNullOrEmpty($Value)) { return $Value }
    $isAscii = -not ($Value.ToCharArray() | Where-Object { [int]$_ -gt 127 })
    if ($isAscii) { return $Value }

    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Value))
    return "=?base64?${encoded}?="
}

function Get-WsConfig {
    <#
    .SYNOPSIS
        Loads the workshop configuration file and layers explicit overrides on top.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$Override = @{}
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Configuration file not found: $Path. Copy config/workshop.config.example.json and fill it in."
    }

    $raw = Get-Content -LiteralPath $Path -Raw
    try { $config = $raw | ConvertFrom-Json -Depth 20 }
    catch { throw "Configuration file '$Path' is not valid JSON: $($_.Exception.Message)" }

    foreach ($key in $Override.Keys) {
        $value = $Override[$key]
        if ($null -eq $value -or ($value -is [string] -and [string]::IsNullOrWhiteSpace($value))) { continue }
        $config | Add-Member -NotePropertyName $key -NotePropertyValue $value -Force
    }
    return $config
}

function Resolve-WsSecret {
    <#
    .SYNOPSIS
        Resolves a secret from a literal value or an "env:NAME" indirection.
    .DESCRIPTION
        Keeps client secrets out of the configuration file: the config stores
        "env:WORKSHOP_CLIENT_SECRET" and the value comes from the environment.
    #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Value, [string]$Name = 'secret')

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    if ($Value -notlike 'env:*') { return $Value }

    $envName  = $Value.Substring(4).Trim()
    $resolved = [Environment]::GetEnvironmentVariable($envName)
    if ([string]::IsNullOrWhiteSpace($resolved)) {
        throw "Environment variable '$envName' (referenced for $Name) is not set."
    }
    return $resolved
}

Export-ModuleMember -Function Set-WsLogLevel, Write-WsLog, Invoke-WsRestMethod, New-WsPassword,
    ConvertTo-WsMailNickname, ConvertTo-WsBcHeaderValue, Get-WsConfig, Resolve-WsSecret,
    ConvertTo-WsRedactedString
