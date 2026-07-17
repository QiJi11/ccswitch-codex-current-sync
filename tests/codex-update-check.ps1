[CmdletBinding()]
param(
    [string]$CheckScript = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($CheckScript)) {
    $CheckScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\check-codex-update.ps1'
}

function Assert-Condition {
    param([bool]$Condition, [string]$Message)

    if (-not $Condition) { throw $Message }
}

function Write-TestCache {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][datetimeoffset]$CheckedAt
    )

    $value = [ordered]@{
        schemaVersion = 1
        package = '@openai/codex'
        latestVersion = $Version
        checkedAt = $CheckedAt.ToString('o')
        source = 'npm-registry'
    }
    [IO.File]::WriteAllText(
        $Path,
        (($value | ConvertTo-Json -Depth 4) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )
}

function Get-FreeTcpPort {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        return ([Net.IPEndPoint]$listener.LocalEndpoint).Port
    } finally {
        $listener.Stop()
    }
}

function Start-RegistryFixture {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Version
    )

    $pythonPath = (Get-Command python -ErrorAction Stop).Source
    $serverScriptPath = Join-Path $Root 'registry-fixture.py'
    $standardOutputPath = Join-Path $Root 'registry-fixture.stdout.log'
    $standardErrorPath = Join-Path $Root 'registry-fixture.stderr.log'
    $port = Get-FreeTcpPort
    $serverSource = @'
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

version = sys.argv[2]


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/latest":
            self.send_error(404)
            return
        body = json.dumps({"name": "@openai/codex", "version": version}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format, *_args):
        return


ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
'@
    [IO.File]::WriteAllText($serverScriptPath, $serverSource, [Text.UTF8Encoding]::new($false))
    $pythonArguments = @('-u', $serverScriptPath, [string]$port, $Version)
    $serverProcess = Start-Process `
        -FilePath $pythonPath `
        -ArgumentList $pythonArguments `
        -PassThru `
        -WindowStyle Hidden `
        -RedirectStandardOutput $standardOutputPath `
        -RedirectStandardError $standardErrorPath
    $registryUri = "http://127.0.0.1:$port/latest"

    for ($attempt = 0; $attempt -lt 50; $attempt++) {
        if ($serverProcess.HasExited) {
            throw "Registry fixture exited with code $($serverProcess.ExitCode)."
        }
        try {
            $response = Invoke-RestMethod -Uri $registryUri -TimeoutSec 1
            if ([string]$response.version -eq $Version) {
                return [pscustomobject]@{
                    Process = $serverProcess
                    Uri = $registryUri
                }
            }
        } catch [Net.Http.HttpRequestException] {
        } catch [Net.WebException] {
        }
        Start-Sleep -Milliseconds 100
    }

    Stop-Process -Id $serverProcess.Id -Force -ErrorAction SilentlyContinue
    $serverProcess.WaitForExit()
    throw 'Registry fixture did not become ready.'
}

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("codex-update-check-{0}" -f [guid]::NewGuid().ToString('N'))
$registryFixture = $null
try {
    [IO.Directory]::CreateDirectory($temporaryRoot) | Out-Null
    $cachePath = Join-Path $temporaryRoot 'cache.json'
    Write-TestCache -Path $cachePath -Version '0.144.4' -CheckedAt ([datetimeoffset]::UtcNow)

    $available = (& $CheckScript -CurrentVersion '0.144.3' -CachePath $cachePath -Json | Out-String) | ConvertFrom-Json
    Assert-Condition ($available.status -eq 'update_available') 'A newer cached version was not reported.'
    Assert-Condition ($available.latestVersion -eq '0.144.4') 'The cached latest version changed.'

    $current = (& $CheckScript -CurrentVersion '0.144.4' -CachePath $cachePath -Json | Out-String) | ConvertFrom-Json
    Assert-Condition ($current.status -eq 'current') 'An equal version was incorrectly reported as an update.'

    $newerLocal = (& $CheckScript -CurrentVersion '0.145.0' -CachePath $cachePath -Json | Out-String) | ConvertFrom-Json
    Assert-Condition ($newerLocal.status -eq 'current') 'The checker offered a downgrade.'

    Write-TestCache -Path $cachePath -Version '0.144.4' -CheckedAt ([datetimeoffset]::UtcNow.AddDays(-2))
    $stale = (& $CheckScript -CurrentVersion '0.144.3' -CachePath $cachePath `
        -RegistryUri 'http://127.0.0.1:1/unavailable' -TimeoutSec 1 -Json | Out-String) | ConvertFrom-Json
    Assert-Condition ($stale.status -eq 'update_available') 'A stale cache was not used when the registry failed.'
    Assert-Condition ([bool]$stale.usedStaleCache) 'The stale-cache fallback was not disclosed.'

    # Regression: 2026-07-18 existing caches failed refresh when File.Replace received a null backup path.
    $registryFixture = Start-RegistryFixture -Root $temporaryRoot -Version '0.144.5'
    $refreshed = (& $CheckScript -CurrentVersion '0.144.3' -CachePath $cachePath `
        -RegistryUri $registryFixture.Uri -ForceRefresh -Json | Out-String) | ConvertFrom-Json
    $refreshedCache = Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json
    Assert-Condition ($refreshed.status -eq 'update_available') `
        'Refreshing an existing cache did not report the newer registry version.'
    Assert-Condition ($refreshed.latestVersion -eq '0.144.5') `
        'The refreshed result did not contain the registry version.'
    Assert-Condition ($refreshedCache.latestVersion -eq '0.144.5') `
        'The existing cache file was not atomically replaced.'

    Write-TestCache -Path $cachePath -Version '0.144.4' -CheckedAt ([datetimeoffset]::UtcNow)
    $human = (& $CheckScript -CurrentVersion '0.144.3' -CachePath $cachePath 6>&1 | Out-String)
    Assert-Condition ($human.Contains('[Codex update]') -and $human.Contains('0.144.4')) `
        'The human update notice was not emitted.'
    Assert-Condition ($human.Contains('do not run npm update')) `
        'The notice did not warn against an unreviewed floating update.'

    Write-Output 'PASS Codex npm update fallback and cache behavior'
} finally {
    if ($null -ne $registryFixture -and -not $registryFixture.Process.HasExited) {
        Stop-Process -Id $registryFixture.Process.Id -Force
        $registryFixture.Process.WaitForExit()
    }
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
}
