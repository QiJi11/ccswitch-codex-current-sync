[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Uninstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$MarkerStart = '# >>> ccswitch-codex-event-launcher >>>'
$MarkerEnd = '# <<< ccswitch-codex-event-launcher <<<'
$UserRoot = if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
    [Environment]::GetFolderPath('UserProfile')
} else {
    [IO.Path]::GetFullPath($env:USERPROFILE)
}
$ProdexRoot = Join-Path $UserRoot '.prodex'
$BinDirectory = Join-Path $ProdexRoot 'bin'
$ShimDirectory = Join-Path $ProdexRoot 'shims'
$WatcherTaskNames = @('ccswitch-codex-current-watcher', 'ccswitch-codex-current-watcher-user')

function Write-InstallAction {
    param([Parameter(Mandatory = $true)][string]$Message)

    $prefix = if ($DryRun) { '[dry-run] ' } else { '' }
    Write-Host ($prefix + $Message)
}

function Get-ProfilePaths {
    $documentsRoot = Join-Path $UserRoot 'Documents'
    return @(
        Join-Path $documentsRoot 'PowerShell\Microsoft.PowerShell_profile.ps1'
        Join-Path $documentsRoot 'WindowsPowerShell\Microsoft.PowerShell_profile.ps1'
    ) | Select-Object -Unique
}

function Get-ProfileFileState {
    param([Parameter(Mandatory = $true)][string]$ProfilePath)

    if (-not (Test-Path -LiteralPath $ProfilePath -PathType Leaf)) {
        return [pscustomobject]@{
            Content = ''
            Encoding = [Text.UTF8Encoding]::new($true, $true)
            Exists = $false
        }
    }

    $bytes = [IO.File]::ReadAllBytes($ProfilePath)
    $encoding = $null
    $preambleLength = 0
    if ($bytes.Length -ge 4 -and $bytes[0] -eq 0x00 -and $bytes[1] -eq 0x00 -and
        $bytes[2] -eq 0xFE -and $bytes[3] -eq 0xFF) {
        $encoding = [Text.UTF32Encoding]::new($true, $true, $true)
        $preambleLength = 4
    } elseif ($bytes.Length -ge 4 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE -and
        $bytes[2] -eq 0x00 -and $bytes[3] -eq 0x00) {
        $encoding = [Text.UTF32Encoding]::new($false, $true, $true)
        $preambleLength = 4
    } elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $encoding = [Text.UTF8Encoding]::new($true, $true)
        $preambleLength = 3
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $encoding = [Text.UnicodeEncoding]::new($true, $true, $true)
        $preambleLength = 2
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $encoding = [Text.UnicodeEncoding]::new($false, $true, $true)
        $preambleLength = 2
    } else {
        $strictUtf8 = [Text.UTF8Encoding]::new($false, $true)
        try {
            $content = $strictUtf8.GetString($bytes)
            $hasNonAscii = @($bytes | Where-Object { $_ -ge 0x80 }).Count -gt 0
            return [pscustomobject]@{
                Content = $content
                # Windows PowerShell 5.1 needs a BOM to decode non-ASCII UTF-8 reliably.
                Encoding = [Text.UTF8Encoding]::new($hasNonAscii, $true)
                Exists = $true
            }
        } catch [Text.DecoderFallbackException] {
            $ansiCodePage = [Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage
            $encoding = [Text.Encoding]::GetEncoding($ansiCodePage)
        }
    }

    return [pscustomobject]@{
        Content = $encoding.GetString($bytes, $preambleLength, $bytes.Length - $preambleLength)
        Encoding = $encoding
        Exists = $true
    }
}

function Get-ProfileNewLine {
    param([AllowEmptyString()][string]$Content)

    if ($Content.Contains("`r`n")) {
        return "`r`n"
    }
    return "`n"
}

function Get-ProfileMarkerPattern {
    $startPattern = [regex]::Escape($MarkerStart)
    $endPattern = [regex]::Escape($MarkerEnd)
    return "(?ms)^$startPattern\r?\n.*?^$endPattern(?:\r?\n)?"
}

function Get-ProfileWithoutManagedBlock {
    param([AllowEmptyString()][string]$Content)

    $markerPattern = Get-ProfileMarkerPattern
    return [regex]::Replace($Content, $markerPattern, '').TrimEnd([char[]]"`r`n")
}

function Get-ManagedProfileBlock {
    param([Parameter(Mandatory = $true)][string]$NewLine)

    $blockLines = @(
        $MarkerStart
        'function global:codex {'
        "    & (Join-Path `$env:USERPROFILE '.prodex\bin\invoke-ccswitch-codex.ps1') @args"
        '}'
        $MarkerEnd
    )
    return $blockLines -join $NewLine
}

function Get-InstalledProfileContent {
    param([AllowEmptyString()][string]$CurrentContent)

    $newLine = Get-ProfileNewLine -Content $CurrentContent
    $unmanagedContent = Get-ProfileWithoutManagedBlock -Content $CurrentContent
    $managedBlock = Get-ManagedProfileBlock -NewLine $newLine
    if ([string]::IsNullOrEmpty($unmanagedContent)) {
        return $managedBlock + $newLine
    }
    return $unmanagedContent + $newLine + $newLine + $managedBlock + $newLine
}

function Assert-ValidPowerShell {
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][string]$TargetPath
    )

    $tokens = $null
    $parseErrors = $null
    [Management.Automation.Language.Parser]::ParseInput($Content, [ref]$tokens, [ref]$parseErrors) | Out-Null
    if (@($parseErrors).Count -gt 0) {
        $firstError = $parseErrors[0].Message
        throw "Refusing to write invalid PowerShell profile '$TargetPath': $firstError"
    }
}

function Backup-Profile {
    param([Parameter(Mandatory = $true)][string]$ProfilePath)

    if (-not (Test-Path -LiteralPath $ProfilePath -PathType Leaf)) {
        return
    }
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
    $backupPath = "$ProfilePath.bak-ccswitch-event-launcher-$timestamp"
    Write-InstallAction "Backup profile: $backupPath"
    if (-not $DryRun) {
        Copy-Item -LiteralPath $ProfilePath -Destination $backupPath
    }
}

function Set-ProfileContent {
    param(
        [Parameter(Mandatory = $true)][string]$ProfilePath,
        [Parameter(Mandatory = $true)]$CurrentState,
        [AllowEmptyString()][string]$DesiredContent
    )

    if ([string]::Equals([string]$CurrentState.Content, $DesiredContent, [StringComparison]::Ordinal)) {
        return
    }

    Assert-ValidPowerShell -Content $DesiredContent -TargetPath $ProfilePath
    Backup-Profile -ProfilePath $ProfilePath
    Write-InstallAction "Update profile: $ProfilePath"
    if (-not $DryRun) {
        $profileDirectory = Split-Path -Parent $ProfilePath
        [IO.Directory]::CreateDirectory($profileDirectory) | Out-Null
        $tempPath = Join-Path $profileDirectory (".{0}.ccswitch-tmp-{1}" -f
            (Split-Path -Leaf $ProfilePath), [guid]::NewGuid().ToString('N'))
        $replaceBackupPath = "$tempPath.replace-backup"
        try {
            [IO.File]::WriteAllText($tempPath, $DesiredContent, $CurrentState.Encoding)
            if ([bool]$CurrentState.Exists) {
                [IO.File]::Replace($tempPath, $ProfilePath, $replaceBackupPath, $true)
            } else {
                [IO.File]::Move($tempPath, $ProfilePath)
            }
        } finally {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $replaceBackupPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Install-ProfileMarkers {
    foreach ($profilePath in Get-ProfilePaths) {
        $currentState = Get-ProfileFileState -ProfilePath $profilePath
        $desiredContent = Get-InstalledProfileContent -CurrentContent ([string]$currentState.Content)
        Set-ProfileContent -ProfilePath $profilePath -CurrentState $currentState -DesiredContent $desiredContent
    }
}

function Uninstall-ProfileMarkers {
    foreach ($profilePath in Get-ProfilePaths) {
        if (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) {
            continue
        }
        $currentState = Get-ProfileFileState -ProfilePath $profilePath
        $desiredContent = Get-ProfileWithoutManagedBlock -Content ([string]$currentState.Content)
        if (-not [string]::IsNullOrEmpty($desiredContent)) {
            $desiredContent += Get-ProfileNewLine -Content ([string]$currentState.Content)
        }
        Set-ProfileContent -ProfilePath $profilePath -CurrentState $currentState -DesiredContent $desiredContent
    }
}

function Get-PathKey {
    param([Parameter(Mandatory = $true)][string]$PathEntry)

    $expandedPath = [Environment]::ExpandEnvironmentVariables($PathEntry.Trim().Trim('"'))
    try {
        return [IO.Path]::GetFullPath($expandedPath).TrimEnd([char[]]'\/').ToUpperInvariant()
    } catch [System.ArgumentException] {
        return $expandedPath.TrimEnd([char[]]'\/').ToUpperInvariant()
    } catch [System.NotSupportedException] {
        return $expandedPath.TrimEnd([char[]]'\/').ToUpperInvariant()
    }
}

function Get-InstalledUserPath {
    param([AllowEmptyString()][string]$CurrentUserPath)

    $shimKey = Get-PathKey -PathEntry $ShimDirectory
    $npmKey = Get-PathKey -PathEntry (Join-Path $env:APPDATA 'npm')
    $pathEntries = @($CurrentUserPath -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $retainedEntries = @($pathEntries | Where-Object { (Get-PathKey -PathEntry $_) -ne $shimKey })
    $npmIndex = -1
    for ($index = 0; $index -lt $retainedEntries.Count; $index++) {
        if ((Get-PathKey -PathEntry $retainedEntries[$index]) -eq $npmKey) {
            $npmIndex = $index
            break
        }
    }
    if ($npmIndex -lt 0) {
        return (@($ShimDirectory) + $retainedEntries) -join ';'
    }
    if ($npmIndex -eq 0) {
        return (@($ShimDirectory) + $retainedEntries) -join ';'
    }
    return @($retainedEntries[0..($npmIndex - 1)] + $ShimDirectory + $retainedEntries[$npmIndex..($retainedEntries.Count - 1)]) -join ';'
}

function Get-UninstalledUserPath {
    param([AllowEmptyString()][string]$CurrentUserPath)

    $shimKey = Get-PathKey -PathEntry $ShimDirectory
    $retainedEntries = @($CurrentUserPath -split ';' | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_) -and (Get-PathKey -PathEntry $_) -ne $shimKey
    })
    return $retainedEntries -join ';'
}

function Set-ManagedUserPath {
    $currentUserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($null -eq $currentUserPath) {
        $currentUserPath = ''
    }
    $desiredUserPath = if ($Uninstall) {
        Get-UninstalledUserPath -CurrentUserPath $currentUserPath
    } else {
        Get-InstalledUserPath -CurrentUserPath $currentUserPath
    }
    if ([string]::Equals($currentUserPath, $desiredUserPath, [StringComparison]::OrdinalIgnoreCase)) {
        return
    }
    Write-InstallAction 'Update user PATH.'
    if (-not $DryRun) {
        [Environment]::SetEnvironmentVariable('Path', $desiredUserPath, 'User')
    }
}

function Test-FilesEqual {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )

    if (-not (Test-Path -LiteralPath $DestinationPath -PathType Leaf)) {
        return $false
    }
    return (Get-FileHash -LiteralPath $SourcePath -Algorithm SHA256).Hash -eq
        (Get-FileHash -LiteralPath $DestinationPath -Algorithm SHA256).Hash
}

function Copy-ManagedFile {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )

    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
        throw "Required installer source is missing: $SourcePath"
    }
    if (Test-FilesEqual -SourcePath $SourcePath -DestinationPath $DestinationPath) {
        return
    }
    Write-InstallAction "Deploy: $DestinationPath"
    if (-not $DryRun) {
        [IO.Directory]::CreateDirectory((Split-Path -Parent $DestinationPath)) | Out-Null
        Copy-Item -LiteralPath $SourcePath -Destination $DestinationPath -Force
    }
}

function Install-LauncherFiles {
    foreach ($scriptName in @(
        'invoke-ccswitch-codex.ps1'
        'materialize-ccswitch-codex-run.ps1'
        'persist-run-model.ps1'
        'sync-ccswitch-current-codex.ps1'
    )) {
        Copy-ManagedFile -SourcePath (Join-Path $PSScriptRoot $scriptName) -DestinationPath (Join-Path $BinDirectory $scriptName)
    }
    foreach ($shimName in @('codex.ps1', 'codex.cmd', 'codex')) {
        Copy-ManagedFile -SourcePath (Join-Path $PSScriptRoot "shims\$shimName") -DestinationPath (Join-Path $ShimDirectory $shimName)
    }
}

function Uninstall-Shims {
    foreach ($shimName in @('codex.ps1', 'codex.cmd', 'codex')) {
        $shimPath = Join-Path $ShimDirectory $shimName
        if (-not (Test-Path -LiteralPath $shimPath -PathType Leaf)) {
            continue
        }
        Write-InstallAction "Remove shim: $shimPath"
        if (-not $DryRun) {
            Remove-Item -LiteralPath $shimPath -Force
        }
    }
    if ((Test-Path -LiteralPath $ShimDirectory -PathType Container) -and
        @(Get-ChildItem -LiteralPath $ShimDirectory -Force).Count -eq 0) {
        Write-InstallAction "Remove empty shim directory: $ShimDirectory"
        if (-not $DryRun) {
            Remove-Item -LiteralPath $ShimDirectory -Force
        }
    }
}

function Get-WatcherTask {
    param([Parameter(Mandatory = $true)][string]$TaskName)

    try {
        return Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    } catch {
        if ($_.FullyQualifiedErrorId -like 'CmdletizationQuery_NotFound_TaskName,*') {
            return $null
        }
        throw
    }
}

function Remove-WatcherTasks {
    $scheduledTaskCommand = Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue
    if ($null -eq $scheduledTaskCommand) {
        Write-Warning 'ScheduledTasks module is unavailable; watcher task state was not changed.'
        return
    }
    foreach ($taskName in $WatcherTaskNames) {
        $watcherTask = Get-WatcherTask -TaskName $taskName
        if ($null -eq $watcherTask) {
            continue
        }
        Write-InstallAction "Unregister watcher task: $taskName"
        if (-not $DryRun) {
            try {
                Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
            } catch [Microsoft.Management.Infrastructure.CimException] {
                $remainingTask = Get-WatcherTask -TaskName $taskName
                $accessDenied = $_.FullyQualifiedErrorId -like 'HRESULT 0x80070005,*'
                if ($accessDenied -and $null -ne $remainingTask -and
                    [string]$remainingTask.State -eq 'Disabled') {
                    Write-Warning "Watcher task '$taskName' could not be removed, but it is disabled."
                    continue
                }
                throw
            }
        }
    }
}

if ($Uninstall) {
    Uninstall-Shims
    Uninstall-ProfileMarkers
} else {
    Install-LauncherFiles
    Install-ProfileMarkers
}
Set-ManagedUserPath
Remove-WatcherTasks

Write-InstallAction 'Event launcher configuration complete. Open a new terminal before resolving codex from PATH.'
