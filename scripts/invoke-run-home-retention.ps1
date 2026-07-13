[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$RunHomesRoot = (Join-Path $env:USERPROFILE '.prodex\manual-homes\ccswitch-runs'),
    [ValidateRange(1, 3650)]
    [int]$MinimumAgeDays = 30,
    [switch]$Apply,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

function Get-NormalizedPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    $fileSystemRoot = [IO.Path]::GetPathRoot($fullPath)
    if ([string]::Equals($fullPath, $fileSystemRoot, [StringComparison]::OrdinalIgnoreCase)) {
        return $fileSystemRoot
    }
    return $fullPath.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
}

function Assert-NoReparsePointInPath {
    param([Parameter(Mandatory = $true)][IO.DirectoryInfo]$Directory)

    $currentDirectory = $Directory
    while ($null -ne $currentDirectory) {
        if (($currentDirectory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Run homes root path must not contain a reparse point: $($currentDirectory.FullName)"
        }
        $currentDirectory = $currentDirectory.Parent
    }
}

function Assert-SafeRunHomesRootPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $rootItem = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($rootItem -isnot [IO.DirectoryInfo]) {
        throw "Run homes root is not a directory: $Path"
    }
    Assert-NoReparsePointInPath -Directory $rootItem
}

function Assert-SafeRunHomeItem {
    param(
        [Parameter(Mandatory = $true)][IO.FileSystemInfo]$Item,
        [Parameter(Mandatory = $true)][string]$NormalizedRoot
    )

    if ($Item -isnot [IO.DirectoryInfo]) {
        throw "Run home is not a directory: $($Item.FullName)"
    }
    if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Run home must not be a reparse point: $($Item.FullName)"
    }
    $parentPath = Get-NormalizedPath -Path $Item.Parent.FullName
    if (-not [string]::Equals($parentPath, $NormalizedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Run home is no longer a direct child of the retention root: $($Item.FullName)"
    }
}

function Get-StableFileId {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fsutilPath = Join-Path $env:SystemRoot 'System32\fsutil.exe'
    if (-not (Test-Path -LiteralPath $fsutilPath -PathType Leaf -ErrorAction Stop)) {
        throw "System fsutil.exe was not found: $fsutilPath"
    }
    $global:LASTEXITCODE = 0
    $queryOutput = @(& $fsutilPath file queryfileid $Path 2>&1)
    $queryExitCode = $LASTEXITCODE
    $fileIdMatch = [regex]::Match(($queryOutput -join "`n"), '0x[0-9a-fA-F]{16,32}')
    if ($queryExitCode -ne 0 -or -not $fileIdMatch.Success) {
        throw "Unable to verify the stable file ID for: $Path"
    }
    return $fileIdMatch.Value.ToLowerInvariant()
}

function Assert-StableFileId {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedFileId
    )

    $currentFileId = Get-StableFileId -Path $Path
    if ($currentFileId -ne $ExpectedFileId) {
        throw "Filesystem identity changed during retention: $Path"
    }
}

function Get-ActiveCommandLines {
    $processes = @(Get-CimInstance Win32_Process -ErrorAction Stop)
    if ($processes.Count -eq 0) {
        throw 'Process enumeration returned no results; retention cannot prove that run homes are inactive.'
    }
    return @($processes |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.CommandLine) } |
        ForEach-Object { [string]$_.CommandLine })
}

function Get-RunHomeDescendants {
    param([Parameter(Mandatory = $true)][IO.DirectoryInfo]$Directory)

    return @(Get-ChildItem -LiteralPath $Directory.FullName -Recurse -Force -ErrorAction Stop)
}

function Get-LatestWriteTimeUtc {
    param(
        [Parameter(Mandatory = $true)][IO.DirectoryInfo]$Directory,
        [Parameter(Mandatory = $true)][IO.FileSystemInfo[]]$Descendants
    )

    $latest = $Directory.LastWriteTimeUtc
    foreach ($item in $Descendants) {
        if ($item.LastWriteTimeUtc -gt $latest) {
            $latest = $item.LastWriteTimeUtc
        }
    }
    return $latest
}

function Get-ProtectedContentStatus {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][IO.FileSystemInfo[]]$Descendants
    )

    $sessionsRoot = Join-Path $Path 'sessions'
    $hasSessionData = Test-Path -LiteralPath $sessionsRoot -PathType Container -ErrorAction Stop
    $sessionPrefix = if ($hasSessionData) { (Get-NormalizedPath -Path $sessionsRoot) + [IO.Path]::DirectorySeparatorChar } else { $null }
    $hasRolloutSession = $false
    $hasHistoryData = $false
    $hasStateDatabase = $false
    $hasNestedReparsePoint = $false

    foreach ($entry in $Descendants) {
        if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            $hasNestedReparsePoint = $true
        }
        if ($entry -isnot [IO.FileInfo]) { continue }
        if ($entry.Name -ieq 'history.jsonl') { $hasHistoryData = $true }
        if ($entry.Name -like 'state_*.sqlite*') { $hasStateDatabase = $true }
        if ($hasSessionData -and $entry.Name -like 'rollout-*.jsonl' -and
            $entry.FullName.StartsWith($sessionPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            $hasRolloutSession = $true
        }
    }

    return [pscustomobject]@{
        hasSessionData       = $hasSessionData
        hasRolloutSession    = $hasRolloutSession
        hasHistoryData       = $hasHistoryData
        hasStateDatabase     = $hasStateDatabase
        hasNestedReparsePoint = $hasNestedReparsePoint
    }
}

function Get-RunHomeDecision {
    param(
        [Parameter(Mandatory = $true)][IO.DirectoryInfo]$Directory,
        [Parameter(Mandatory = $true)][string]$NormalizedRoot,
        [Parameter(Mandatory = $true)][datetime]$CutoffUtc,
        [Parameter(Mandatory = $true)][string[]]$ActiveCommandLines
    )

    $path = Get-NormalizedPath -Path $Directory.FullName
    $reasons = [System.Collections.Generic.List[string]]::new()
    $expectedParent = Get-NormalizedPath -Path $NormalizedRoot
    $actualParent = Get-NormalizedPath -Path $Directory.Parent.FullName

    if (-not [string]::Equals($actualParent, $expectedParent, [StringComparison]::OrdinalIgnoreCase)) {
        $reasons.Add('not_direct_child')
    }
    if ($Directory.Name -notlike 'ccswitch-run-*') {
        $reasons.Add('name_mismatch')
    }
    $isReparsePoint = ($Directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
    if ($isReparsePoint) {
        $reasons.Add('reparse_point')
    }

    $descendants = @()
    $protectedContent = $null
    if ($isReparsePoint) {
        $latestWriteUtc = $Directory.LastWriteTimeUtc
    }
    else {
        $descendants = @(Get-RunHomeDescendants -Directory $Directory)
        $latestWriteUtc = Get-LatestWriteTimeUtc -Directory $Directory -Descendants $descendants
        $protectedContent = Get-ProtectedContentStatus -Path $path -Descendants $descendants
    }
    if ($latestWriteUtc -gt $CutoffUtc) {
        $reasons.Add('recent')
    }

    $hasSessionData = $null -ne $protectedContent -and [bool]$protectedContent.hasSessionData
    $hasRolloutSession = $null -ne $protectedContent -and [bool]$protectedContent.hasRolloutSession
    $hasHistoryData = $null -ne $protectedContent -and [bool]$protectedContent.hasHistoryData
    $hasStateDatabase = $null -ne $protectedContent -and [bool]$protectedContent.hasStateDatabase
    $hasNestedReparsePoint = $null -ne $protectedContent -and [bool]$protectedContent.hasNestedReparsePoint
    if ($hasSessionData) {
        $reasons.Add('session_data')
    }
    if ($hasRolloutSession) {
        $reasons.Add('rollout_session')
    }
    if ($hasHistoryData) {
        $reasons.Add('history_data')
    }
    if ($hasStateDatabase) {
        $reasons.Add('state_database')
    }
    if ($hasNestedReparsePoint) {
        $reasons.Add('nested_reparse_point')
    }

    $profileName = $null
    $metadataPath = Join-Path $path 'run-provider.json'
    if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
        $reasons.Add('metadata_missing')
    }
    else {
        try {
            $metadata = Get-Content -LiteralPath $metadataPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $profileName = [string]$metadata.profileName
            if ([string]::IsNullOrWhiteSpace($profileName)) {
                $reasons.Add('metadata_invalid')
            }
        }
        catch {
            $reasons.Add('metadata_invalid')
        }
    }

    $activeReference = @($ActiveCommandLines | Where-Object {
        $_.IndexOf($path, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or (
            -not [string]::IsNullOrWhiteSpace($profileName) -and
            $_.IndexOf($profileName, [StringComparison]::OrdinalIgnoreCase) -ge 0
        )
    }).Count -gt 0
    if ($activeReference) {
        $reasons.Add('active_process')
    }

    return [pscustomobject]@{
        name              = $Directory.Name
        path              = $path
        latestWriteUtc    = $latestWriteUtc.ToString('o')
        ageDays           = [math]::Floor(([datetime]::UtcNow - $latestWriteUtc).TotalDays)
        hasSessionData    = $hasSessionData
        hasRolloutSession = $hasRolloutSession
        hasHistoryData    = $hasHistoryData
        hasStateDatabase  = $hasStateDatabase
        activeReference   = $activeReference
        profileName       = $profileName
        eligible          = $reasons.Count -eq 0
        reasons           = @($reasons)
    }
}

$normalizedRoot = Get-NormalizedPath -Path $RunHomesRoot
$fileSystemRoot = [IO.Path]::GetPathRoot($normalizedRoot)
if ([string]::Equals($normalizedRoot, $fileSystemRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Run homes root must not be a filesystem root: $normalizedRoot"
}
if (-not (Test-Path -LiteralPath $normalizedRoot -PathType Container -ErrorAction Stop)) {
    throw "Run homes root does not exist: $normalizedRoot"
}
Assert-SafeRunHomesRootPath -Path $normalizedRoot
$rootFileId = if ($Apply) { Get-StableFileId -Path $normalizedRoot } else { $null }

$cutoffUtc = [datetime]::UtcNow.AddDays(-$MinimumAgeDays)
$activeCommandLines = @(Get-ActiveCommandLines)
$candidates = @(Get-ChildItem -LiteralPath $normalizedRoot -Directory -Force -ErrorAction Stop | Where-Object { $_.Name -like 'ccswitch-run-*' })
$retentionDecisions = [System.Collections.Generic.List[object]]::new()
$deletedCount = 0

foreach ($candidate in $candidates) {
    $decision = Get-RunHomeDecision -Directory $candidate -NormalizedRoot $normalizedRoot -CutoffUtc $cutoffUtc -ActiveCommandLines $activeCommandLines
    $action = if ($decision.eligible) { 'preview-delete' } else { 'keep' }

    if ($Apply -and $decision.eligible) {
        if ($PSCmdlet.ShouldProcess($decision.path, 'Delete retained Codex run home')) {
            Assert-SafeRunHomesRootPath -Path $normalizedRoot
            Assert-StableFileId -Path $normalizedRoot -ExpectedFileId $rootFileId
            $freshItem = Get-Item -LiteralPath $decision.path -Force -ErrorAction Stop
            $freshDecision = Get-RunHomeDecision -Directory $freshItem -NormalizedRoot $normalizedRoot -CutoffUtc $cutoffUtc -ActiveCommandLines @(Get-ActiveCommandLines)
            if ($freshDecision.eligible) {
                Assert-SafeRunHomesRootPath -Path $normalizedRoot
                Assert-StableFileId -Path $normalizedRoot -ExpectedFileId $rootFileId
                $finalItem = Get-Item -LiteralPath $freshDecision.path -Force -ErrorAction Stop
                Assert-SafeRunHomeItem -Item $finalItem -NormalizedRoot $normalizedRoot
                $finalItemFileId = Get-StableFileId -Path $finalItem.FullName
                $finalDecision = Get-RunHomeDecision -Directory $finalItem -NormalizedRoot $normalizedRoot -CutoffUtc $cutoffUtc -ActiveCommandLines @(Get-ActiveCommandLines)
                $decision = $finalDecision
                if ($finalDecision.eligible) {
                    Assert-SafeRunHomesRootPath -Path $normalizedRoot
                    Assert-StableFileId -Path $normalizedRoot -ExpectedFileId $rootFileId
                    $deleteItem = Get-Item -LiteralPath $finalDecision.path -Force -ErrorAction Stop
                    Assert-SafeRunHomeItem -Item $deleteItem -NormalizedRoot $normalizedRoot
                    Assert-StableFileId -Path $deleteItem.FullName -ExpectedFileId $finalItemFileId
                    Remove-Item -LiteralPath $finalDecision.path -Recurse -Force -ErrorAction Stop
                    $action = 'deleted'
                    $deletedCount += 1
                }
                else {
                    $action = 'keep'
                }
            }
            else {
                $decision = $freshDecision
                $action = 'keep'
            }
        }
        else {
            $action = 'keep'
        }
    }

    $retentionDecisions.Add([pscustomobject]@{
        name              = $decision.name
        path              = $decision.path
        latestWriteUtc    = $decision.latestWriteUtc
        ageDays           = $decision.ageDays
        hasSessionData    = $decision.hasSessionData
        hasRolloutSession = $decision.hasRolloutSession
        hasHistoryData    = $decision.hasHistoryData
        hasStateDatabase  = $decision.hasStateDatabase
        activeReference   = $decision.activeReference
        profileName       = $decision.profileName
        eligible          = $decision.eligible
        action            = $action
        reasons           = @($decision.reasons)
    })
}

$result = [pscustomobject]@{
    mode              = if ($Apply) { 'apply' } else { 'preview' }
    root              = $normalizedRoot
    minimumAgeDays    = $MinimumAgeDays
    cutoffUtc         = $cutoffUtc.ToString('o')
    candidateCount    = $candidates.Count
    eligibleCount     = @($retentionDecisions | Where-Object { $_.eligible }).Count
    deletedCount      = $deletedCount
    sessionDataCount  = @($retentionDecisions | Where-Object { $_.hasSessionData }).Count
    rolloutSessionCount = @($retentionDecisions | Where-Object { $_.hasRolloutSession }).Count
    historyDataCount  = @($retentionDecisions | Where-Object { $_.hasHistoryData }).Count
    stateDatabaseCount = @($retentionDecisions | Where-Object { $_.hasStateDatabase }).Count
    activeReferenceCount = @($retentionDecisions | Where-Object { $_.activeReference }).Count
    items             = @($retentionDecisions)
}

if ($Json) {
    $result | ConvertTo-Json -Depth 8
    return
}

Write-Output ("mode={0} root={1} candidates={2} eligible={3} deleted={4}" -f `
    $result.mode, $result.root, $result.candidateCount, $result.eligibleCount, $result.deletedCount)
$retentionDecisions | Select-Object name, ageDays, eligible, action, @{Name = 'reasons'; Expression = { $_.reasons -join ',' } } | Format-Table -AutoSize
