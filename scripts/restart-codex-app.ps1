[CmdletBinding()]
param(
    [switch]$Apply,
    [int]$WaitSeconds = 20
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

function Get-ProcessSnapshot {
    @(Get-CimInstance Win32_Process | Where-Object {
        $_.ProcessId -and $_.ExecutablePath
    } | ForEach-Object {
        [pscustomobject]@{
            Pid = [int]$_.ProcessId
            ParentPid = [int]$_.ParentProcessId
            Name = [string]$_.Name
            ExecutablePath = [string]$_.ExecutablePath
            CommandLine = [string]$_.CommandLine
        }
    })
}

function Resolve-AllowedAppProcess {
    param([Parameter(Mandatory = $true)][object]$Process)

    $path = [IO.Path]::GetFullPath([string]$Process.ExecutablePath)
    if ([IO.Path]::GetFileName($path) -ine 'ChatGPT.exe') {
        return $null
    }
    $normalized = $path.Replace('/', '\')
    $isOfficial = $normalized -match '^C:\\Program Files\\WindowsApps\\OpenAI\.Codex_[^\\]+\\app\\ChatGPT\.exe$'
    $isWrapper = $normalized -match ('^' + [regex]::Escape([Environment]::GetFolderPath('UserProfile')) +
        '\\AppData\\Local\\OpenAI\\Codex-Wrapper\\versions\\[^\\]+\\app\\ChatGPT\.exe$')
    if (-not ($isOfficial -or $isWrapper)) {
        return $null
    }
    return [pscustomobject]@{
        Pid = [int]$Process.Pid
        ParentPid = [int]$Process.ParentPid
        ExecutablePath = $path
        Kind = if ($isOfficial) { 'official' } else { 'wrapper' }
    }
}

function Get-AppRoots {
    param([Parameter(Mandatory = $true)][object[]]$Snapshot)

    $allowed = @(
        $Snapshot |
            ForEach-Object { Resolve-AllowedAppProcess -Process $_ } |
            Where-Object { $null -ne $_ }
    )
    $byPid = @{}
    foreach ($process in $Snapshot) {
        $byPid[[int]$process.Pid] = $process
    }
    @(
        $allowed | Where-Object {
            $parent = $byPid[[int]$_.ParentPid]
            $null -eq $parent -or
            [IO.Path]::GetFileName([string]$parent.ExecutablePath) -ine 'ChatGPT.exe'
        } | Sort-Object Kind,Pid
    )
}

function Get-DescendantPids {
    param(
        [Parameter(Mandatory = $true)][object[]]$Snapshot,
        [Parameter(Mandatory = $true)][int]$RootPid,
        [int[]]$ExcludePids = @()
    )

    $children = @{}
    foreach ($process in $Snapshot) {
        $parent = [int]$process.ParentPid
        if (-not $children.ContainsKey($parent)) {
            $children[$parent] = [System.Collections.Generic.List[int]]::new()
        }
        $children[$parent].Add([int]$process.Pid)
    }
    $result = [System.Collections.Generic.List[int]]::new()
    $queue = [System.Collections.Generic.Queue[int]]::new()
    $queue.Enqueue($RootPid)
    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        if ($current -ne $RootPid -and $ExcludePids -notcontains $current) {
            $result.Add($current)
        }
        if ($children.ContainsKey($current)) {
            foreach ($child in $children[$current]) {
                $queue.Enqueue($child)
            }
        }
    }
    @($result | Sort-Object -Descending)
}

function Get-ProcessChainPids {
    param(
        [Parameter(Mandatory = $true)][object[]]$Snapshot,
        [Parameter(Mandatory = $true)][int]$ProcessId
    )

    $byPid = @{}
    foreach ($process in $Snapshot) {
        $byPid[[int]$process.Pid] = $process
    }
    $chain = [System.Collections.Generic.List[int]]::new()
    $current = $ProcessId
    while ($byPid.ContainsKey($current)) {
        $chain.Add($current)
        $current = [int]$byPid[$current].ParentPid
    }
    @($chain)
}

function Wait-ForAppRoots {
    param(
        [Parameter(Mandatory = $true)][string[]]$ExecutablePaths,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $snapshot = Get-ProcessSnapshot
        $found = @(
            $snapshot |
                Where-Object {
                    $candidate = [IO.Path]::GetFullPath([string]$_.ExecutablePath)
                    $ExecutablePaths -contains $candidate
                } |
                Select-Object -ExpandProperty Pid
        )
        if ($found.Count -ge $ExecutablePaths.Count) {
            return @($found)
        }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    return @($found)
}

$snapshot = Get-ProcessSnapshot
$roots = Get-AppRoots -Snapshot $snapshot
$report = [ordered]@{
    ok = $true
    mode = if ($Apply) { 'apply' } else { 'preview' }
    roots = @($roots | ForEach-Object {
        [ordered]@{
            pid = $_.Pid
            kind = $_.Kind
            executablePath = $_.ExecutablePath
            descendants = @(Get-DescendantPids -Snapshot $snapshot -RootPid $_.Pid)
        }
    })
    stopped = @()
    started = @()
    restartRequired = $false
}

if ($roots.Count -eq 0) {
    $report.ok = $false
    $report.restartRequired = $true
    $report.error = 'No validated Codex App root process was found.'
    $report | ConvertTo-Json -Depth 8
    exit 2
}

if ($Apply) {
    foreach ($root in $roots) {
        $protected = @(
            Get-ProcessChainPids -Snapshot $snapshot -ProcessId $PID |
                Where-Object { $_ -ne $root.Pid }
        )
        $descendants = @(
            Get-DescendantPids -Snapshot $snapshot -RootPid $root.Pid -ExcludePids $protected
        )
        foreach ($processId in $descendants + @([int]$root.Pid)) {
            $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
            if ($null -ne $process) {
                Stop-Process -Id $processId -Force -ErrorAction Stop
                $report.stopped += $processId
            }
        }
    }
    $paths = @($roots | Select-Object -ExpandProperty ExecutablePath -Unique)
    foreach ($path in $paths) {
        Start-Process -FilePath $path -WindowStyle Normal | Out-Null
    }
    $started = @(Wait-ForAppRoots -ExecutablePaths $paths -TimeoutSeconds $WaitSeconds)
    $report.started = $started
    $report.restartRequired = $started.Count -lt $paths.Count
    if ($report.restartRequired) {
        $report.ok = $false
        $report.error = 'Codex App restart did not produce all validated roots before timeout.'
    }
}

$report | ConvertTo-Json -Depth 8
if (-not $report.ok) { exit 3 }
