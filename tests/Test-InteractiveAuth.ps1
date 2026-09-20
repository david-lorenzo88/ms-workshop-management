#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
    Exercises the interactive-browser (authorization code + PKCE) flow offline.
.DESCRIPTION
    Runs the real flow in a child process with the token endpoint mocked, then
    plays the part of the browser: reads the authorize URL the flow prints,
    and calls the loopback redirect back with a code. Verifies the listener,
    the state guard, and the code-for-token exchange.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root    = Split-Path -Parent $PSScriptRoot
$workDir = Join-Path ([System.IO.Path]::GetTempPath()) ("ws-auth-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $workDir -Force | Out-Null

$failures = [System.Collections.Generic.List[string]]::new()
function Assert($condition, $label) {
    if ($condition) { Write-Host "  PASS  $label" -ForegroundColor Green }
    else { Write-Host "  FAIL  $label" -ForegroundColor Red; $script:failures.Add($label) }
}

function Invoke-FlowScenario {
    <#  Runs the flow in a child process and drives the callback. #>
    param(
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][scriptblock]$BuildCallback,  # receives the parsed state
        [string]$Label
    )

    $outFile = Join-Path $workDir "$Label.out"
    $resFile = Join-Path $workDir "$Label.result"
    $child = Join-Path $workDir "$Label.ps1"

    @"
Set-StrictMode -Version Latest
Import-Module '$root/src/modules/WorkshopCommon.psm1' -Force
Import-Module '$root/src/modules/WorkshopAuth.psm1' -Force

# Mock only the token exchange; the listener and browser handoff stay real.
function global:Invoke-WebRequest {
    [CmdletBinding()]
    param([string]`$Uri, [string]`$Method, [hashtable]`$Headers, [object]`$Body,
          [string]`$ContentType, [int]`$TimeoutSec, [switch]`$SkipHttpErrorCheck, [int]`$MaximumRedirection)
    `$payload = @{ access_token = 'mock-access-token'; refresh_token = 'mock-refresh'; expires_in = 3600 } | ConvertTo-Json -Compress
    [pscustomobject]@{ StatusCode = 200; Content = `$payload; Headers = @{} }
}

Initialize-WsAuth -TenantId '11111111-1111-1111-1111-111111111111' ``
                  -ClientId '22222222-2222-2222-2222-222222222222' ``
                  -Mode InteractiveBrowser -RedirectPort $Port | Out-Null
try {
    `$m = Get-Module WorkshopAuth
    `$t = & `$m { Request-WsInteractiveBrowserToken -Scope 'https://graph.microsoft.com/.default' }
    "OK:" + `$t.access_token | Set-Content '$resFile'
}
catch { "ERR:" + `$_.Exception.Message | Set-Content '$resFile' }
"@ | Set-Content -LiteralPath $child -Encoding utf8

    $proc = Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-File', $child) `
        -RedirectStandardOutput $outFile -PassThru -NoNewWindow

    # Wait for the flow to print the authorize URL, then act as the browser.
    $state = $null
    $deadline = (Get-Date).AddSeconds(45)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 400
        if (-not (Test-Path $outFile)) { continue }
        $text = Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue
        if ($text -and $text -match 'state=([a-f0-9]{32})') { $state = $Matches[1]; break }
    }
    if (-not $state) { $proc | Stop-Process -Force -ErrorAction SilentlyContinue; return [pscustomobject]@{ Result = 'NO_URL'; Body = $null } }

    $callback = & $BuildCallback $state $Port
    $body = try { (Invoke-WebRequest -Uri $callback -TimeoutSec 20 -SkipHttpErrorCheck).Content } catch { "REQUEST_FAILED: $($_.Exception.Message)" }

    $proc | Wait-Process -Timeout 30 -ErrorAction SilentlyContinue
    $result = if (Test-Path $resFile) { Get-Content -LiteralPath $resFile -Raw } else { 'NO_RESULT' }
    return [pscustomobject]@{ Result = $result.Trim(); Body = $body; Url = $callback }
}

Write-Host "`n########## interactive browser auth flow ##########`n" -ForegroundColor Magenta

Write-Host 'Scenario 1: happy path' -ForegroundColor Cyan
$happy = Invoke-FlowScenario -Port 8411 -Label 'happy' -BuildCallback {
    param($state, $port) "http://localhost:$port/?code=FAKE_AUTH_CODE&state=$state"
}
Assert ($happy.Result -eq 'OK:mock-access-token') "authorization code exchanged for a token (got '$($happy.Result)')"
Assert ($happy.Body -match 'Signed in') 'browser gets a success page'

Write-Host "`nScenario 2: state mismatch (CSRF guard)" -ForegroundColor Cyan
$csrf = Invoke-FlowScenario -Port 8412 -Label 'csrf' -BuildCallback {
    param($state, $port) "http://localhost:$port/?code=FAKE&state=deadbeefdeadbeefdeadbeefdeadbeef"
}
Assert ($csrf.Result -like 'ERR:*State mismatch*') "mismatched state is rejected (got '$($csrf.Result)')"

Write-Host "`nScenario 3: identity provider returns an error" -ForegroundColor Cyan
$denied = Invoke-FlowScenario -Port 8413 -Label 'denied' -BuildCallback {
    param($state, $port) "http://localhost:$port/?error=access_denied&error_description=AADSTS530035%3A%20blocked&state=$state"
}
Assert ($denied.Result -like '*AADSTS530035*') 'AADSTS error from the redirect is surfaced with guidance'
Assert ($denied.Body -match 'Sign-in failed') 'browser gets a failure page'

Write-Host ''
Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
if ($failures.Count -gt 0) { Write-Host "$($failures.Count) FAILED" -ForegroundColor Red; exit 1 }
Write-Host 'INTERACTIVE AUTH TESTS PASSED' -ForegroundColor Green
