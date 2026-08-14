[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string]$CcSwitchRoot = '',
    [string]$ProdexRoot = (Join-Path $env:USERPROFILE '.prodex'),
    [switch]$Apply,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
. (Join-Path $PSScriptRoot 'resolve-ccswitch-root.ps1')

function Assert-SafeCleanupRoot {
    param([Parameter(Mandatory = $true)][string]$Path)

    $resolved = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    if ([string]::IsNullOrWhiteSpace($resolved) -or $resolved -eq [System.IO.Path]::GetPathRoot($resolved)) {
        throw "Refusing unsafe cleanup root: $resolved"
    }
    if (Test-Path -LiteralPath $resolved) {
        $entry = Get-Item -LiteralPath $resolved -Force
        if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Cleanup root must not be a reparse point: $resolved"
        }
    }
    return $resolved
}

function Get-VerifiedChild {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $rootPath = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $childPath = [System.IO.Path]::GetFullPath($Path)
    $prefix = $rootPath + [System.IO.Path]::DirectorySeparatorChar
    if (-not $childPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Cleanup candidate escapes its root: $childPath"
    }
    return $childPath
}

function Get-TreeSize {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        return [long](Get-Item -LiteralPath $Path -Force).Length
    }
    $size = [long]0
    foreach ($file in @(Get-ChildItem -LiteralPath $Path -File -Recurse -Force -ErrorAction Stop)) {
        $size += [long]$file.Length
    }
    return $size
}

function Assert-NotActiveProcessPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $needle = [System.IO.Path]::GetFullPath($Path)
    foreach ($process in @(Get-CimInstance Win32_Process -ErrorAction Stop)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$process.CommandLine) -and
            ([string]$process.CommandLine).IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            throw "Cleanup candidate is referenced by active PID $($process.ProcessId): $needle"
        }
    }
}

function Add-Candidate {
    param(
        [System.Collections.Generic.List[object]]$Candidates,
        [string]$Root,
        [string]$Path,
        [string]$Reason
    )

    $verified = Get-VerifiedChild -Root $Root -Path $Path
    if (-not (Test-Path -LiteralPath $verified)) { return }
    $entry = Get-Item -LiteralPath $verified -Force
    if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Cleanup candidate must not be a reparse point: $verified"
    }
    if ($entry.PSIsContainer) {
        $nestedReparsePoints = @(Get-ChildItem -LiteralPath $verified -Recurse -Force -ErrorAction Stop | Where-Object {
            ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
        })
        if ($nestedReparsePoints.Count -gt 0) {
            throw "Cleanup candidate contains a nested reparse point: $verified"
        }
    }
    $Candidates.Add([pscustomobject]@{
        path = $verified
        reason = $Reason
        bytes = Get-TreeSize -Path $verified
        lastWriteUtcTicks = $entry.LastWriteTimeUtc.Ticks
        attributes = [int64]$entry.Attributes
    }) | Out-Null
}

function Assert-NoRecoverableCleanupState {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return }
    $recoverable = @(Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction Stop | Where-Object {
        $_.Name -eq 'sessions' -or $_.Name -eq 'history.jsonl' -or $_.Name -like 'state_*.sqlite*'
    })
    if ($recoverable.Count -gt 0) {
        throw "Cleanup candidate contains recoverable state: $Path"
    }
}

function Test-LegacyBackupEntry {
    param([Parameter(Mandatory = $true)][System.IO.FileSystemInfo]$Entry)

    if ($Entry.LastWriteTimeUtc -ge [DateTime]::UtcNow.AddDays(-1)) { return $false }
    if (-not $Entry.PSIsContainer) {
        return $Entry.Name -like 'cc-switch.db.bak-*' -or
            $Entry.Name -like 'db_backup_*.db' -or
            $Entry.Name -like 'settings.json.bak-*'
    }
    return $Entry.Name -like 'browser-acceptance-*' -or
        $Entry.Name -like 'ccswitch-*' -or
        $Entry.Name -like 'codex-*' -or
        $Entry.Name -like 'portable-handoff-*'
}

function Assert-MigrationComplete {
    $auditJson = & (Join-Path $PSScriptRoot 'invoke-ccswitch-credential-migration.ps1') `
        -CcSwitchRoot $resolvedCcSwitchRoot `
        -ProdexRoot $resolvedProdexRoot `
        -Json
    $audit = ($auditJson | Out-String).Trim() | ConvertFrom-Json
    if (-not [bool]$audit.ok -or [int]$audit.plaintextProviderCount -ne 0 -or
        [int]$audit.knownTokenOccurrenceCount -ne 0 -or @($audit.issues).Count -ne 0 -or
        [int]$audit.commandBackedProviderCount -ne [int]$audit.thirdPartyProviderCount -or
        [int]$audit.globalCommandBackedProviderCount -ne [int]$audit.globalCustomCredentialCount) {
        throw 'Credential migration audit is not clean; stale data cleanup is blocked.'
    }
}

function Assert-CcSwitchStoppedForRoot {
    $osUserRoot = [Environment]::GetFolderPath('UserProfile')
    $osAppDataRoot = [Environment]::GetFolderPath('ApplicationData')
    $activeRoot = Resolve-CcSwitchRoot -UserRoot $osUserRoot -AppDataRoot $osAppDataRoot
    if (-not [string]::Equals($activeRoot, $resolvedCcSwitchRoot, [StringComparison]::OrdinalIgnoreCase)) {
        return
    }
    $active = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessName -in @('cc-switch', 'ccswitch')
    })
    if ($active.Count -gt 0) {
        throw 'CC Switch must be closed before deleting its legacy backups.'
    }
}

$resolvedCcSwitchRoot = Resolve-CcSwitchRoot `
    -ExplicitRoot $CcSwitchRoot `
    -UserRoot $env:USERPROFILE `
    -AppDataRoot $env:APPDATA
$resolvedProdexRoot = Assert-SafeCleanupRoot -Path $ProdexRoot
$backupRoot = Assert-SafeCleanupRoot -Path (Join-Path $resolvedCcSwitchRoot 'backups')
$currentHome = Assert-SafeCleanupRoot -Path (Join-Path $resolvedProdexRoot 'manual-homes\ccswitch-current')
$runHomes = Assert-SafeCleanupRoot -Path (Join-Path $resolvedProdexRoot 'manual-homes\ccswitch-runs')
$candidates = [System.Collections.Generic.List[object]]::new()

if (Test-Path -LiteralPath $backupRoot -PathType Container) {
    foreach ($entry in @(Get-ChildItem -LiteralPath $backupRoot -Force | Where-Object { Test-LegacyBackupEntry -Entry $_ })) {
        Assert-NoRecoverableCleanupState -Path $entry.FullName
        Add-Candidate -Candidates $candidates -Root $backupRoot -Path $entry.FullName -Reason 'legacy-ccswitch-backup'
    }
}
if (Test-Path -LiteralPath $currentHome -PathType Container) {
    foreach ($entry in @(Get-ChildItem -LiteralPath $currentHome -Force | Where-Object {
        $_.Name -like 'config.toml.bak-*' -or $_.Name -like 'auth.json.bak-*'
    })) {
        Add-Candidate -Candidates $candidates -Root $currentHome -Path $entry.FullName -Reason 'stale-current-copy'
    }
}
if (Test-Path -LiteralPath $runHomes -PathType Container) {
    $cutoff = [DateTime]::UtcNow.AddDays(-1)
    foreach ($entry in @(Get-ChildItem -LiteralPath $runHomes -Directory -Force -Filter '.ccswitch-staging-*')) {
        if ($entry.LastWriteTimeUtc -lt $cutoff) {
            Assert-NoRecoverableCleanupState -Path $entry.FullName
            Add-Candidate -Candidates $candidates -Root $runHomes -Path $entry.FullName -Reason 'orphan-staging'
        }
    }
}

$deletedCount = 0
if ($Apply) {
    Assert-CcSwitchStoppedForRoot
    Assert-MigrationComplete
    foreach ($candidate in $candidates) {
        Assert-NotActiveProcessPath -Path $candidate.path
        $currentEntry = Get-Item -LiteralPath $candidate.path -Force
        if ([int64]$currentEntry.Attributes -ne [int64]$candidate.attributes -or
            $currentEntry.LastWriteTimeUtc.Ticks -ne [int64]$candidate.lastWriteUtcTicks) {
            throw "Cleanup candidate changed after preview: $($candidate.path)"
        }
        Assert-NoRecoverableCleanupState -Path $candidate.path
    }
    foreach ($candidate in $candidates) {
        if ($PSCmdlet.ShouldProcess($candidate.path, "Delete $($candidate.reason)")) {
            Remove-Item -LiteralPath $candidate.path -Recurse -Force
            if (Test-Path -LiteralPath $candidate.path) {
                throw "Cleanup verification failed: $($candidate.path)"
            }
            $deletedCount += 1
        }
    }
}

$report = [pscustomobject]@{
    ok = $true
    mode = $(if ($Apply) { 'applied' } else { 'preview' })
    candidateCount = $candidates.Count
    candidateBytes = [long](($candidates | Measure-Object -Property bytes -Sum).Sum)
    deletedCount = $deletedCount
    items = @($candidates)
    runHomesDeleted = 0
}
if ($Json) {
    $report | ConvertTo-Json -Depth 5 -Compress
} else {
    $report
}
