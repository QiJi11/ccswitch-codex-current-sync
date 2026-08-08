[CmdletBinding()]
param(
    [string]$CheckScript = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'scripts\check-codex-update.ps1')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("codex-update-check-{0}" -f [guid]::NewGuid().ToString('N'))
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

    Write-TestCache -Path $cachePath -Version '0.144.4' -CheckedAt ([datetimeoffset]::UtcNow)
    $human = (& $CheckScript -CurrentVersion '0.144.3' -CachePath $cachePath 6>&1 | Out-String)
    Assert-Condition ($human.Contains('[Codex update]') -and $human.Contains('0.144.4')) `
        'The human update notice was not emitted.'

    Write-Output 'PASS Codex npm update fallback and cache behavior'
} finally {
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
}
