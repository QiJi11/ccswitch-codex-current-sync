[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TargetHome,
    [ValidateSet('Current', 'Run')][string]$Mode,
    [string]$GlobalCodexHome = (Join-Path $env:USERPROFILE '.codex'),
    [switch]$CheckOnly,
    [switch]$NoExit,
    [switch]$Quiet,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$targetRoot = [System.IO.Path]::GetFullPath($TargetHome)
$globalRoot = [System.IO.Path]::GetFullPath($GlobalCodexHome)
$manifestPath = Join-Path $targetRoot '.ccswitch-managed-durable.json'
$changes = [System.Collections.Generic.List[object]]::new()
$desiredPaths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$managedDirectoryNames = @('agents', 'skills', 'rules', 'prompts')
$managedFileNames = @('AGENTS.md', 'hooks.json', 'keybindings.json', 'model-instructions.md')

function Get-VerifiedTargetPath {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    $path = [System.IO.Path]::GetFullPath((Join-Path $targetRoot $RelativePath))
    $prefix = $targetRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if (-not $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Managed path escapes target home: $RelativePath"
    }
    return $path
}

function Get-PathDigest {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return $null
    }
    $entries = @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force | Sort-Object FullName)
    $builder = [System.Text.StringBuilder]::new()
    foreach ($entry in $entries) {
        $relative = $entry.FullName.Substring($Path.TrimEnd('\').Length).TrimStart('\')
        $hash = (Get-FileHash -LiteralPath $entry.FullName -Algorithm SHA256).Hash
        $null = $builder.Append($relative).Append("`0").Append($hash).Append("`n")
    }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($builder.ToString())
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return -join ($sha256.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') })
    } finally {
        $sha256.Dispose()
    }
}

function Add-Change {
    param([string]$RelativePath, [string]$Action)
    $changes.Add([pscustomobject]@{ path = $RelativePath; action = $Action }) | Out-Null
}

function Get-ShortSiblingPath {
    param([string]$TargetPath, [string]$Prefix)

    $parent = Split-Path -Parent $TargetPath
    do {
        $randomName = [IO.Path]::GetRandomFileName().Replace('.', '')
        $candidate = Join-Path $parent "$Prefix-$PID-$randomName"
    } while (Test-Path -LiteralPath $candidate)
    return $candidate
}

function Remove-ManagedTarget {
    param([Parameter(Mandatory = $true)][string]$Path)

    $entry = Get-Item -LiteralPath $Path -Force
    if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        if ($entry.PSIsContainer) {
            [IO.Directory]::Delete($Path)
        } else {
            [IO.File]::Delete($Path)
        }
    } else {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
}

function Assert-NoReparsePoints {
    param([Parameter(Mandatory = $true)][string]$RootPath)

    $rootEntry = Get-Item -LiteralPath $RootPath -Force
    if (($rootEntry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Run durable source contains a reparse point: $RootPath"
    }
    $pending = [System.Collections.Generic.Stack[string]]::new()
    $pending.Push([System.IO.Path]::GetFullPath($RootPath))
    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        foreach ($entry in @(Get-ChildItem -LiteralPath $current -Force)) {
            if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Run durable source contains a reparse point: $($entry.FullName)"
            }
            if ($entry.PSIsContainer) {
                $pending.Push($entry.FullName)
            }
        }
    }
}

function Assert-ManagedDurableRelativePath {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    if ([string]::IsNullOrWhiteSpace($RelativePath) -or
        $RelativePath.Contains('/') -or $RelativePath.Contains('\')) {
        throw "Managed durable manifest contains an invalid path: $RelativePath"
    }
    $isManagedName = $managedDirectoryNames -contains $RelativePath -or
        $managedFileNames -contains $RelativePath -or
        ($RelativePath -like '*.config.toml' -and $RelativePath -ne 'config.toml')
    if (-not $isManagedName) {
        throw "Managed durable manifest contains an unsupported path: $RelativePath"
    }
}

function Sync-ManagedFile {
    param([string]$SourcePath, [string]$RelativePath)

    $sourceEntry = Get-Item -LiteralPath $SourcePath -Force
    if (($sourceEntry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Managed durable file must not be a reparse point: $SourcePath"
    }
    $desiredPaths.Add($RelativePath) | Out-Null
    $targetPath = Get-VerifiedTargetPath -RelativePath $RelativePath
    $matches = (Get-PathDigest -Path $SourcePath) -eq (Get-PathDigest -Path $targetPath)
    if ($matches) { return }
    Add-Change -RelativePath $RelativePath -Action 'update-file'
    if ($CheckOnly) { return }
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $targetPath)) | Out-Null
    $temporaryPath = Get-ShortSiblingPath -TargetPath $targetPath -Prefix '.ccs-f'
    try {
        Copy-Item -LiteralPath $SourcePath -Destination $temporaryPath -Force
        $sourceAfterCopy = Get-Item -LiteralPath $SourcePath -Force
        if (($sourceAfterCopy.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Managed durable file became a reparse point during copy: $SourcePath"
        }
        Move-Item -LiteralPath $temporaryPath -Destination $targetPath -Force
    } finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }
}

function Sync-ManagedDirectory {
    param([string]$SourcePath, [string]$RelativePath)

    if ($Mode -eq 'Run') {
        Assert-NoReparsePoints -RootPath $SourcePath
    }
    $desiredPaths.Add($RelativePath) | Out-Null
    $targetPath = Get-VerifiedTargetPath -RelativePath $RelativePath
    $targetIsRealDirectory = $false
    if (Test-Path -LiteralPath $targetPath -PathType Container) {
        $targetEntry = Get-Item -LiteralPath $targetPath -Force
        $targetIsRealDirectory = ($targetEntry.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0
    }
    if ($targetIsRealDirectory -and
        (Get-PathDigest -Path $SourcePath) -eq (Get-PathDigest -Path $targetPath)) { return }
    Add-Change -RelativePath $RelativePath -Action 'replace-directory'
    if ($CheckOnly) { return }
    $stagingPath = Get-ShortSiblingPath -TargetPath $targetPath -Prefix '.ccs-d'
    $retiredPath = Get-ShortSiblingPath -TargetPath $targetPath -Prefix '.ccs-r'
    try {
        [System.IO.Directory]::CreateDirectory($stagingPath) | Out-Null
        foreach ($sourceEntry in @(Get-ChildItem -LiteralPath $SourcePath -Force)) {
            Copy-Item -LiteralPath $sourceEntry.FullName -Destination $stagingPath -Recurse -Force
        }
        if ($Mode -eq 'Run') {
            Assert-NoReparsePoints -RootPath $stagingPath
        }
        if (Test-Path -LiteralPath $targetPath) {
            Move-Item -LiteralPath $targetPath -Destination $retiredPath
        }
        try {
            Move-Item -LiteralPath $stagingPath -Destination $targetPath
        } catch {
            if (Test-Path -LiteralPath $retiredPath) {
                Move-Item -LiteralPath $retiredPath -Destination $targetPath
            }
            throw
        }
        if (Test-Path -LiteralPath $retiredPath) {
            Remove-ManagedTarget -Path $retiredPath
        }
    } finally {
        Remove-Item -LiteralPath $stagingPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Sync-ManagedJunction {
    param([string]$SourcePath, [string]$RelativePath)

    $desiredPaths.Add($RelativePath) | Out-Null
    $targetPath = Get-VerifiedTargetPath -RelativePath $RelativePath
    $isExpected = $false
    if (Test-Path -LiteralPath $targetPath) {
        $entry = Get-Item -LiteralPath $targetPath -Force
        if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            $resolvedTarget = [System.IO.Path]::GetFullPath([string]$entry.Target)
            $isExpected = [string]::Equals(
                $resolvedTarget,
                [System.IO.Path]::GetFullPath($SourcePath),
                [StringComparison]::OrdinalIgnoreCase
            )
        }
    }
    if ($isExpected) { return }
    Add-Change -RelativePath $RelativePath -Action 'replace-junction'
    if ($CheckOnly) { return }
    $retiredPath = Get-ShortSiblingPath -TargetPath $targetPath -Prefix '.ccs-j'
    if (Test-Path -LiteralPath $targetPath) {
        Move-Item -LiteralPath $targetPath -Destination $retiredPath
    }
    try {
        New-Item -ItemType Junction -Path $targetPath -Target $SourcePath | Out-Null
    } catch {
        if (Test-Path -LiteralPath $retiredPath) {
            Move-Item -LiteralPath $retiredPath -Destination $targetPath
        }
        throw
    }
    if (Test-Path -LiteralPath $retiredPath) {
        Remove-ManagedTarget -Path $retiredPath
    }
}

function Remove-StaleManagedPaths {
    $managedCandidates = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($relativePath in @('hooks.json', 'keybindings.json', 'model-instructions.md', 'rules', 'prompts')) {
        $managedCandidates.Add($relativePath) | Out-Null
    }
    foreach ($configFile in @(Get-ChildItem -LiteralPath $targetRoot -File -Filter '*.config.toml' -ErrorAction SilentlyContinue)) {
        $managedCandidates.Add($configFile.Name) | Out-Null
    }
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        if ([int]$manifest.schemaVersion -ne 1 -or
            -not [string]::Equals([string]$manifest.mode, $Mode, [StringComparison]::Ordinal)) {
            throw 'Managed durable manifest schema or mode is invalid.'
        }
        foreach ($relativePath in @($manifest.paths)) {
            Assert-ManagedDurableRelativePath -RelativePath ([string]$relativePath)
            $managedCandidates.Add([string]$relativePath) | Out-Null
        }
    }
    foreach ($relativePath in $managedCandidates) {
        if ($desiredPaths.Contains([string]$relativePath)) { continue }
        $targetPath = Get-VerifiedTargetPath -RelativePath ([string]$relativePath)
        if (-not (Test-Path -LiteralPath $targetPath)) { continue }
        Add-Change -RelativePath ([string]$relativePath) -Action 'remove-stale'
        if (-not $CheckOnly) {
            Remove-ManagedTarget -Path $targetPath
        }
    }
}

if (-not $CheckOnly) {
    [System.IO.Directory]::CreateDirectory($targetRoot) | Out-Null
}

$agentsPath = Join-Path $globalRoot 'agents'
$skillsPath = Join-Path $globalRoot 'skills'
$agentsFile = Join-Path $globalRoot 'AGENTS.md'
foreach ($required in @($agentsPath, $skillsPath, $agentsFile)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Missing global durable source: $required"
    }
}

Sync-ManagedFile -SourcePath $agentsFile -RelativePath 'AGENTS.md'
if ($Mode -eq 'Current') {
    Sync-ManagedJunction -SourcePath $agentsPath -RelativePath 'agents'
    Sync-ManagedJunction -SourcePath $skillsPath -RelativePath 'skills'
} else {
    Sync-ManagedDirectory -SourcePath $agentsPath -RelativePath 'agents'
    Sync-ManagedDirectory -SourcePath $skillsPath -RelativePath 'skills'
}

foreach ($fileName in @('hooks.json', 'keybindings.json', 'model-instructions.md')) {
    $sourcePath = Join-Path $globalRoot $fileName
    if (Test-Path -LiteralPath $sourcePath -PathType Leaf) {
        Sync-ManagedFile -SourcePath $sourcePath -RelativePath $fileName
    }
}
foreach ($sourcePath in @(Get-ChildItem -LiteralPath $globalRoot -File -Filter '*.config.toml' -ErrorAction SilentlyContinue)) {
    Sync-ManagedFile -SourcePath $sourcePath.FullName -RelativePath $sourcePath.Name
}
foreach ($directoryName in @('rules', 'prompts')) {
    $sourcePath = Join-Path $globalRoot $directoryName
    if (Test-Path -LiteralPath $sourcePath -PathType Container) {
        Sync-ManagedDirectory -SourcePath $sourcePath -RelativePath $directoryName
    }
}

Remove-StaleManagedPaths
$manifest = [ordered]@{
    schemaVersion = 1
    mode = $Mode
    paths = @($desiredPaths | Sort-Object)
}
$manifestJson = ($manifest | ConvertTo-Json -Depth 4) + "`n"
$existingManifest = if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
    [System.IO.File]::ReadAllText($manifestPath, [System.Text.Encoding]::UTF8)
} else {
    $null
}
if (-not [string]::Equals($existingManifest, $manifestJson, [StringComparison]::Ordinal)) {
    Add-Change -RelativePath '.ccswitch-managed-durable.json' -Action 'update-manifest'
}
if (-not $CheckOnly -and
    -not [string]::Equals($existingManifest, $manifestJson, [StringComparison]::Ordinal)) {
    $temporaryManifest = Get-ShortSiblingPath -TargetPath $manifestPath -Prefix '.ccs-m'
    try {
        [System.IO.File]::WriteAllText($temporaryManifest, $manifestJson, [System.Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporaryManifest -Destination $manifestPath -Force
    } finally {
        Remove-Item -LiteralPath $temporaryManifest -Force -ErrorAction SilentlyContinue
    }
}

$report = [pscustomobject]@{
    ok = $true
    mode = $(if ($CheckOnly) { 'check' } else { 'applied' })
    targetHome = $targetRoot
    changed = $changes.Count -gt 0
    changes = @($changes)
}
if ($Json) {
    $report | ConvertTo-Json -Depth 6 -Compress
} elseif (-not $Quiet) {
    $report
}
if ($CheckOnly -and -not $NoExit -and $changes.Count -gt 0) {
    exit 2
}
