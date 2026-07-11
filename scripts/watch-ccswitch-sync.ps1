<#
.SYNOPSIS
    Background watcher: auto-syncs ccswitch-current when CC Switch provider changes.
.DESCRIPTION
    Watches the active ~/.cc-switch root by default. The desktop AppData CC Switch
    root is legacy/stale in this environment and is only watched when explicitly
    requested.
#>
[CmdletBinding()]
param(
    [string[]]$CcSwitchRoot = @(),
    [string]$LogPath = (Join-Path $env:USERPROFILE '.prodex\logs\ccswitch-watcher.log'),
    [string]$SwitchScript = (Join-Path $env:USERPROFILE '.prodex\bin\switch-codex-provider.ps1'),
    [int]$DebounceMsec = 800,
    [int]$PollMsec = 2000,
    [switch]$IncludeDesktopRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

function Get-FullPathIfPossible {
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        return [System.IO.Path]::GetFullPath($Path)
    } catch {
        return $Path
    }
}

function Get-DefaultCcSwitchRoots {
    $roots = New-Object System.Collections.Generic.List[string]
    $legacyRoot = Join-Path $env:USERPROFILE '.cc-switch'
    $desktopRoot = if ([string]::IsNullOrWhiteSpace($env:APPDATA)) {
        ''
    } else {
        Join-Path $env:APPDATA 'com.ccswitch.desktop'
    }

    $candidates = New-Object System.Collections.Generic.List[string]
    $candidates.Add($legacyRoot) | Out-Null
    if ($IncludeDesktopRoot) {
        $candidates.Add($desktopRoot) | Out-Null
    }

    foreach ($candidate in @($candidates.ToArray())) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }
        $full = Get-FullPathIfPossible -Path $candidate
        if ($roots -notcontains $full) {
            $roots.Add($full) | Out-Null
        }
    }
    return @($roots.ToArray())
}

function Resolve-WatchedRoots {
    $rawRoots = if (@($CcSwitchRoot).Count -gt 0) { @($CcSwitchRoot) } else { Get-DefaultCcSwitchRoots }
    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($root in $rawRoots) {
        if ([string]::IsNullOrWhiteSpace($root)) {
            continue
        }
        $full = Get-FullPathIfPossible -Path $root
        $settings = Join-Path $full 'settings.json'
        $db = Join-Path $full 'cc-switch.db'
        if ((Test-Path -LiteralPath $settings) -and (Test-Path -LiteralPath $db) -and ($roots -notcontains $full)) {
            $roots.Add($full) | Out-Null
        }
    }
    return @($roots.ToArray())
}

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')

    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    if ($Level -eq 'ERROR') {
        Write-Error $Message
    } else {
        Write-Host $line
    }
}

function Get-TextFileContent {
    param([Parameter(Mandatory = $true)][string]$Path)

    $reader = [System.IO.StreamReader]::new($Path, [System.Text.UTF8Encoding]::new($false), $true)
    try {
        return $reader.ReadToEnd()
    } finally {
        $reader.Dispose()
    }
}

function Get-SettingsCurrentProviderCodex {
    param([Parameter(Mandatory = $true)][string]$Root)

    $settingsFile = Join-Path $Root 'settings.json'
    if (-not (Test-Path -LiteralPath $settingsFile)) {
        return ''
    }

    for ($attempt = 1; $attempt -le 10; $attempt++) {
        try {
            $settings = Get-TextFileContent -Path $settingsFile | ConvertFrom-Json
            if ($settings.PSObject.Properties['currentProviderCodex']) {
                return [string]$settings.currentProviderCodex
            }
            return ''
        } catch {
            Start-Sleep -Milliseconds 150
        }
    }

    throw "Failed to read currentProviderCodex from $settingsFile after retries."
}

function Get-DbCurrentProviderCodex {
    param([Parameter(Mandatory = $true)][string]$Root)

    $dbPath = Join-Path $Root 'cc-switch.db'
    if (-not (Test-Path -LiteralPath $dbPath)) {
        return ''
    }

    $pythonCommand = Get-Command python -ErrorAction SilentlyContinue
    if ($null -eq $pythonCommand) {
        throw 'Python is required for cc-switch SQLite access, but python was not found on PATH.'
    }

    $tempPythonPath = Join-Path ([System.IO.Path]::GetTempPath()) "ccswitch-watcher-db-current-$PID-$([guid]::NewGuid().ToString('N')).py"
    $pythonCode = @'
import sqlite3
import sys
from pathlib import Path

db_path = Path(sys.argv[1])
con = sqlite3.connect("file:" + db_path.as_posix() + "?mode=ro", uri=True)
con.row_factory = sqlite3.Row
rows = con.execute("select id from providers where app_type='codex' and is_current=1 order by name").fetchall()
print(rows[0]["id"] if len(rows) == 1 else "")
con.close()
'@

    try {
        [System.IO.File]::WriteAllText($tempPythonPath, $pythonCode, [System.Text.UTF8Encoding]::new($false))
        $output = & $pythonCommand.Source $tempPythonPath $dbPath 2>$null
        if ($LASTEXITCODE -ne 0) {
            return ''
        }
        return (($output | Out-String).Trim())
    } finally {
        Remove-Item -LiteralPath $tempPythonPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-CurrentProviderCodex {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [ValidateSet('auto', 'settings', 'db')][string]$PreferredSource = 'auto'
    )

    $settingsId = Get-SettingsCurrentProviderCodex -Root $Root
    $dbId = Get-DbCurrentProviderCodex -Root $Root

    if ($PreferredSource -eq 'db' -and -not [string]::IsNullOrWhiteSpace($dbId)) {
        return $dbId
    }
    if ($PreferredSource -eq 'settings' -and -not [string]::IsNullOrWhiteSpace($settingsId)) {
        return $settingsId
    }
    if (-not [string]::IsNullOrWhiteSpace($dbId) -and $dbId -ne $settingsId) {
        return $dbId
    }
    if (-not [string]::IsNullOrWhiteSpace($settingsId)) {
        return $settingsId
    }
    return $dbId
}

function Get-RootChangeStamp {
    param([Parameter(Mandatory = $true)][string]$Root)

    $parts = @()
    foreach ($leaf in @('settings.json', 'cc-switch.db')) {
        $path = Join-Path $Root $leaf
        if (Test-Path -LiteralPath $path) {
            $parts += ('{0}:{1}' -f $leaf, (Get-Item -LiteralPath $path).LastWriteTimeUtc.Ticks)
        } else {
            $parts += ('{0}:missing' -f $leaf)
        }
    }
    return ($parts -join '|')
}

function Invoke-SwitchForCurrentProvider {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Trigger,
        [ValidateSet('auto', 'settings', 'db')][string]$PreferredSource = 'auto',
        [switch]$Force
    )

    try {
        $providerId = Get-CurrentProviderCodex -Root $Root -PreferredSource $PreferredSource
        if ([string]::IsNullOrWhiteSpace($providerId)) {
            Write-Log "No current Codex provider found for $Root; skipping." -Level 'ERROR'
            return
        }

        $lastProviderId = if ($script:lastProviderIds.ContainsKey($Root)) {
            [string]$script:lastProviderIds[$Root]
        } else {
            ''
        }
        if (-not $Force -and $providerId -eq $lastProviderId) {
            return
        }

        Write-Log "current provider changed by ${Trigger}: root=$Root $lastProviderId -> $providerId; running switch flow..."
        $output = & $SwitchScript -Provider $providerId -CcSwitchRoot $Root -SkipIfConsistent -Json 2>&1
        $outText = ($output | Out-String).Trim()
        try {
            $switchResult = $outText | ConvertFrom-Json
            if (-not [bool]$switchResult.ok) {
                throw [string]$switchResult.message
            }
            $script:lastProviderIds[$Root] = $providerId
            Write-Log ("switch OK: skipped={0} provider={1} id={2} base_url={3} root={4} profile={5}" -f `
                $switchResult.skipped, $switchResult.provider.name, $switchResult.provider.id, $switchResult.baseUrl, $switchResult.ccSwitchRoot, $switchResult.materializedProfile)
        } catch {
            Write-Log "switch returned unparseable/failed output: $outText" -Level 'ERROR'
        }
    } catch {
        Write-Log "switch FAILED root=$Root trigger=${Trigger}: $_" -Level 'ERROR'
    }
}

$watchRoots = Resolve-WatchedRoots
if (@($watchRoots).Count -eq 0) {
    throw 'No valid CC Switch roots found to watch.'
}

$mutexName = 'Global\ccswitch-codex-current-watcher'
$createdNew = $false
$script:instanceMutex = [System.Threading.Mutex]::new($true, $mutexName, [ref]$createdNew)
if (-not $createdNew) {
    $script:instanceMutex.Dispose()
    exit 0
}

$logDir = Split-Path $LogPath
if (-not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}
if (-not (Test-Path -LiteralPath $SwitchScript)) {
    Write-Log "Switch script not found: $SwitchScript" -Level 'ERROR'
    exit 1
}

$script:lastProviderIds = [hashtable]::Synchronized(@{})
$script:lastRootStamps = [hashtable]::Synchronized(@{})
$script:pendingRoots = [hashtable]::Synchronized(@{})
$script:lastPollTime = [DateTime]::UtcNow
$watchers = New-Object System.Collections.Generic.List[object]
$subscriptions = New-Object System.Collections.Generic.List[object]

Write-Log "ccswitch-watcher started. Roots: $($watchRoots -join ' | ')"
if (-not $IncludeDesktopRoot -and @($CcSwitchRoot).Count -eq 0) {
    Write-Log "Desktop AppData CC Switch root is not watched by default; pass -IncludeDesktopRoot or -CcSwitchRoot explicitly for diagnostics."
}
foreach ($root in $watchRoots) {
    $current = Get-CurrentProviderCodex -Root $root -PreferredSource 'auto'
    $script:lastProviderIds[$root] = $current
    $script:lastRootStamps[$root] = Get-RootChangeStamp -Root $root
    Write-Log "Initial current provider root=$root id=$current"
}

try {
    foreach ($root in $watchRoots) {
        $watcher = [System.IO.FileSystemWatcher]::new()
        $watcher.Path = $root
        $watcher.Filter = '*'
        $watcher.NotifyFilter = [System.IO.NotifyFilters]::LastWrite -bor [System.IO.NotifyFilters]::FileName -bor [System.IO.NotifyFilters]::Size
        $watcher.IncludeSubdirectories = $false
        $watcher.EnableRaisingEvents = $true

        $onChange = {
            $name = [System.IO.Path]::GetFileName($Event.SourceEventArgs.FullPath)
            if ($name -notin @('settings.json', 'cc-switch.db')) {
                return
            }

            $preferred = if ($name -eq 'cc-switch.db') { 'db' } else { 'settings' }
            $script:pendingRoots[$Event.MessageData.Root] = [pscustomobject]@{
                at              = [DateTime]::UtcNow
                preferredSource = $preferred
                file            = $name
            }
        }

        $messageData = [pscustomobject]@{ Root = $root }
        $subscriptions.Add((Register-ObjectEvent -InputObject $watcher -EventName 'Changed' -Action $onChange -MessageData $messageData)) | Out-Null
        $subscriptions.Add((Register-ObjectEvent -InputObject $watcher -EventName 'Created' -Action $onChange -MessageData $messageData)) | Out-Null
        $subscriptions.Add((Register-ObjectEvent -InputObject $watcher -EventName 'Renamed' -Action $onChange -MessageData $messageData)) | Out-Null
        $watchers.Add($watcher) | Out-Null
        Write-Log "Watching root=$root"
    }

    Write-Log "Watcher active. Debounce=${DebounceMsec}ms Poll=${PollMsec}ms."

    while ($true) {
        Start-Sleep -Milliseconds 300
        $nowUtc = [DateTime]::UtcNow

        foreach ($root in @($script:pendingRoots.Keys)) {
            $pending = $script:pendingRoots[$root]
            $elapsed = ($nowUtc - [DateTime]$pending.at).TotalMilliseconds
            if ($elapsed -ge $DebounceMsec) {
                $script:pendingRoots.Remove($root)
                Invoke-SwitchForCurrentProvider -Root $root -Trigger "file event $($pending.file)" -PreferredSource ([string]$pending.preferredSource)
            }
        }

        if (($nowUtc - $script:lastPollTime).TotalMilliseconds -ge $PollMsec) {
            $script:lastPollTime = $nowUtc
            foreach ($root in $watchRoots) {
                $currentStamp = Get-RootChangeStamp -Root $root
                $lastStamp = if ($script:lastRootStamps.ContainsKey($root)) { [string]$script:lastRootStamps[$root] } else { '' }
                if ($currentStamp -ne $lastStamp) {
                    $script:lastRootStamps[$root] = $currentStamp
                    Invoke-SwitchForCurrentProvider -Root $root -Trigger 'poll' -PreferredSource 'auto'
                }
            }
        }
    }
} finally {
    foreach ($subscription in @($subscriptions.ToArray())) {
        Unregister-Event -SourceIdentifier $subscription.Name -ErrorAction SilentlyContinue
    }
    foreach ($watcher in @($watchers.ToArray())) {
        $watcher.Dispose()
    }
    Write-Log "ccswitch-watcher stopped."
}
