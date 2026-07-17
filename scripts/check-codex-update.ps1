[CmdletBinding()]
param(
    [string]$CurrentVersion = '',
    [string]$CachePath = '',
    [string]$RegistryUri = 'https://registry.npmjs.org/@openai%2Fcodex/latest',
    [ValidateRange(1, 168)]
    [int]$MaxCacheAgeHours = 6,
    [ValidateRange(1, 30)]
    [int]$TimeoutSec = 4,
    [switch]$ForceRefresh,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-ComparableVersion {
    param([Parameter(Mandatory = $true)][string]$VersionText)

    if ($VersionText -notmatch '^(?<major>0|[1-9]\d*)\.(?<minor>0|[1-9]\d*)\.(?<patch>0|[1-9]\d*)(?:[-+][0-9A-Za-z.-]+)?$') {
        throw "Unsupported semantic version: $VersionText"
    }
    return [version]("{0}.{1}.{2}" -f $matches.major, $matches.minor, $matches.patch)
}

function Get-ValidatedCache {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        $validatedCache = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([int]$validatedCache.schemaVersion -ne 1 -or [string]$validatedCache.package -ne '@openai/codex') { return $null }
        $null = ConvertTo-ComparableVersion -VersionText ([string]$validatedCache.latestVersion)
        $null = [datetimeoffset]::Parse(
            [string]$validatedCache.checkedAt,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        )
        return $validatedCache
    } catch {
        # Invalid cross-process cache content is safely equivalent to a missing cache.
        return $null
    }
}

function Test-CacheFresh {
    param(
        [AllowNull()]$Cache,
        [Parameter(Mandatory = $true)][timespan]$MaxAge
    )

    if ($null -eq $Cache) { return $false }
    $checkedAt = [datetimeoffset]::Parse(
        [string]$Cache.checkedAt,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind
    )
    $age = [datetimeoffset]::UtcNow - $checkedAt.ToUniversalTime()
    return $age -ge [timespan]::Zero -and $age -le $MaxAge
}

function Write-CacheAtomically {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$CacheDocument
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        [IO.Directory]::CreateDirectory($parent) | Out-Null
    }
    $temporaryPath = "$Path.tmp-$PID-$([guid]::NewGuid().ToString('N'))"
    $backupPath = "$Path.bak-$PID-$([guid]::NewGuid().ToString('N'))"
    try {
        [IO.File]::WriteAllText(
            $temporaryPath,
            (($CacheDocument | ConvertTo-Json -Depth 5) + [Environment]::NewLine),
            [Text.UTF8Encoding]::new($false)
        )
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            [IO.File]::Replace($temporaryPath, $Path, $backupPath)
        } else {
            [IO.File]::Move($temporaryPath, $Path)
        }
    } finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-CurrentCodexVersion {
    param([AllowEmptyString()][string]$ExplicitVersion)

    if (-not [string]::IsNullOrWhiteSpace($ExplicitVersion)) { return $ExplicitVersion.Trim() }
    $metadataPath = Join-Path $env:USERPROFILE '.codex\bin\codex-focusfixed-current.json'
    if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) { return '' }
    $metadata = Get-Content -LiteralPath $metadataPath -Raw -Encoding UTF8 | ConvertFrom-Json
    return ([string]$metadata.codexVersion).Trim()
}

function Get-NpmVersionCache {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][int]$RequestTimeoutSec
    )

    $registryResponse = Invoke-RestMethod -Uri $Uri -TimeoutSec $RequestTimeoutSec -Headers @{
        'Accept' = 'application/json'
        'User-Agent' = 'Codex-Update-Check'
    }
    if ([string]$registryResponse.name -ne '@openai/codex') {
        throw 'The npm registry response described an unexpected package.'
    }
    $latestVersion = ([string]$registryResponse.version).Trim()
    $null = ConvertTo-ComparableVersion -VersionText $latestVersion
    return [ordered]@{
        schemaVersion = 1
        package = '@openai/codex'
        latestVersion = $latestVersion
        checkedAt = [datetimeoffset]::UtcNow.ToString('o')
        source = 'npm-registry'
    }
}

function New-CheckOutcome {
    param([Parameter(Mandatory = $true)][hashtable]$OutcomeFields)

    $outcome = [ordered]@{
        status = 'unavailable'
        currentVersion = ''
        latestVersion = ''
        source = ''
        usedStaleCache = $false
        errorCode = ''
    }
    foreach ($fieldName in $OutcomeFields.Keys) {
        if (-not $outcome.Contains($fieldName)) { throw "Unknown check outcome field: $fieldName" }
        $outcome[$fieldName] = $OutcomeFields[$fieldName]
    }
    return [pscustomobject]$outcome
}

if ([string]::IsNullOrWhiteSpace($CachePath)) {
    $CachePath = Join-Path $env:USERPROFILE '.codex\codex-update-check.json'
} else {
    $CachePath = [IO.Path]::GetFullPath($CachePath)
}

$checkOutcome = $null
try {
    $installedVersion = Get-CurrentCodexVersion -ExplicitVersion $CurrentVersion
    if ([string]::IsNullOrWhiteSpace($installedVersion)) {
        $checkOutcome = New-CheckOutcome -OutcomeFields @{ errorCode = 'current_version_missing' }
    } else {
        $installedComparable = ConvertTo-ComparableVersion -VersionText $installedVersion
        $maxAge = [timespan]::FromHours($MaxCacheAgeHours)
        $versionCache = Get-ValidatedCache -Path $CachePath
        $usedStaleCache = $false

        if ($ForceRefresh -or -not (Test-CacheFresh -Cache $versionCache -MaxAge $maxAge)) {
            $mutex = [Threading.Mutex]::new($false, 'Local\CodexNpmUpdateCheck')
            $ownsMutex = $false
            try {
                try {
                    $ownsMutex = $mutex.WaitOne(1500)
                } catch [Threading.AbandonedMutexException] {
                    $ownsMutex = $true
                }
                if ($ownsMutex) {
                    $versionCache = Get-ValidatedCache -Path $CachePath
                    if ($ForceRefresh -or -not (Test-CacheFresh -Cache $versionCache -MaxAge $maxAge)) {
                        $fetchedVersionCache = $null
                        try {
                            $fetchedVersionCache = Get-NpmVersionCache -Uri $RegistryUri -RequestTimeoutSec $TimeoutSec
                        } catch {
                            # Network failures can recover from a previously validated cache without blocking launch.
                            if ($null -eq $versionCache) { throw }
                            $usedStaleCache = $true
                        }
                        if ($null -ne $fetchedVersionCache) {
                            $versionCache = $fetchedVersionCache
                            try {
                                Write-CacheAtomically -Path $CachePath -CacheDocument $versionCache
                            } catch [IO.IOException] {
                                Write-Verbose "Codex update cache could not be written: $($_.Exception.Message)"
                            } catch [UnauthorizedAccessException] {
                                Write-Verbose "Codex update cache could not be written: $($_.Exception.Message)"
                            }
                        }
                    }
                } elseif ($null -ne $versionCache) {
                    $usedStaleCache = $true
                }
            } finally {
                if ($ownsMutex) { $mutex.ReleaseMutex() }
                $mutex.Dispose()
            }
        }

        if ($null -eq $versionCache) {
            $checkOutcome = New-CheckOutcome -OutcomeFields @{
                currentVersion = $installedVersion
                errorCode = 'registry_unavailable'
            }
        } else {
            $latestVersion = [string]$versionCache.latestVersion
            $latestComparable = ConvertTo-ComparableVersion -VersionText $latestVersion
            $versionStatus = if ($latestComparable -gt $installedComparable) { 'update_available' } else { 'current' }
            $versionSource = if ($usedStaleCache) { 'cache-stale' } else { [string]$versionCache.source }
            $checkOutcome = New-CheckOutcome -OutcomeFields @{
                status = $versionStatus
                currentVersion = $installedVersion
                latestVersion = $latestVersion
                source = $versionSource
                usedStaleCache = $usedStaleCache
            }
        }
    }
} catch {
    # Malformed cross-process metadata disables only this optional notice; the launcher continues normally.
    Write-Verbose "Codex update check unavailable: $($_.Exception.Message)"
    $checkOutcome = New-CheckOutcome -OutcomeFields @{
        currentVersion = $CurrentVersion
        errorCode = 'check_failed'
    }
}

if ($Json) {
    $checkOutcome | ConvertTo-Json -Depth 4
} elseif ($checkOutcome.status -eq 'update_available') {
    Write-Host ("[Codex update] {0} available; current {1}." -f `
        $checkOutcome.latestVersion, $checkOutcome.currentVersion) `
        -ForegroundColor Yellow
    Write-Host ("Verify and install exactly {0}; do not run npm update." -f `
        $checkOutcome.latestVersion) -ForegroundColor Yellow
}

exit 0
