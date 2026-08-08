[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$RunHome,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$CcSwitchRoot,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$AllowedRunHomesRoot,

    [Parameter(Mandatory = $true)]
    [int]$ParentProcessId,

    [long]$ParentProcessStartTimeUtcTicks = 0,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$StopFile,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$StateFile,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ReadyFile,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$PersistenceLog,

    [string]$PersistScript = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

if ([string]::IsNullOrWhiteSpace($PersistScript)) {
    $userRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    $PersistScript = Join-Path $userRoot '.prodex\bin\persist-run-model.ps1'
}

$pythonCommand = Get-Command python -ErrorAction SilentlyContinue
if ($null -eq $pythonCommand) {
    $pythonCommand = Get-Command python3 -ErrorAction SilentlyContinue
}
if ($null -eq $pythonCommand) {
    throw 'Python 3.11 or newer is required to watch run model settings.'
}

function Get-SafeText {
    param([AllowNull()][object]$Text)

    $safe = ([string]$Text) -replace '[\x00-\x1f\x7f]', '?'
    if ($safe.Length -gt 200) {
        return $safe.Substring(0, 197) + '...'
    }
    return $safe
}

function Write-PersistenceEvent {
    param(
        [Parameter(Mandatory = $true)][string]$Level,
        [Parameter(Mandatory = $true)][string]$Status,
        [AllowNull()][string]$ErrorCode,
        [AllowNull()][object]$ExitCode,
        [AllowNull()][string]$Message
    )

    try {
        [IO.Directory]::CreateDirectory((Split-Path -Parent $PersistenceLog)) | Out-Null
        $record = [ordered]@{
            timestamp = (Get-Date).ToString('o')
            level = $Level
            source = 'watcher'
            run = Split-Path -Leaf $RunHome
            status = $Status
            errorCode = if ([string]::IsNullOrWhiteSpace($ErrorCode)) { $null } else { Get-SafeText $ErrorCode }
            exitCode = $ExitCode
            message = if ([string]::IsNullOrWhiteSpace($Message)) { $null } else { Get-SafeText $Message }
        }
        $line = $record | ConvertTo-Json -Depth 4 -Compress
        [IO.File]::AppendAllText($PersistenceLog, $line + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    } catch [IO.IOException] {
        [Console]::Error.WriteLine("Model persistence log write failed: $($_.Exception.Message)")
    } catch [UnauthorizedAccessException] {
        [Console]::Error.WriteLine("Model persistence log write failed: $($_.Exception.Message)")
    }
}

function Test-ParentProcessAlive {
    try {
        $parent = Get-Process -Id $ParentProcessId -ErrorAction Stop
        if ($parent.HasExited) {
            return $false
        }
        if ($ParentProcessStartTimeUtcTicks -gt 0) {
            $actualStartTime = $parent.StartTime.ToUniversalTime().Ticks
            if ($actualStartTime -ne $ParentProcessStartTimeUtcTicks) {
                return $false
            }
        }
        return $true
    } catch [ArgumentException] {
        return $false
    } catch [InvalidOperationException] {
        return $false
    } catch [ComponentModel.Win32Exception] {
        return $false
    }
}

function Get-ConfigFingerprint {
    $configPath = Join-Path $RunHome 'config.toml'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        return $null
    }

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return -join ($sha256.ComputeHash([IO.File]::ReadAllBytes($configPath)) |
            ForEach-Object { $_.ToString('x2') })
    } catch [IO.IOException] {
        return $null
    } catch [UnauthorizedAccessException] {
        return $null
    } finally {
        $sha256.Dispose()
    }
}

function Read-RunModelSettings {
    $configPath = Join-Path $RunHome 'config.toml'
    $python = @'
import json
import pathlib
import sys
import tomllib

data = tomllib.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8-sig"))
model = data.get("model")
effort = data.get("model_reasoning_effort")
if model is not None and (not isinstance(model, str) or not model.strip()):
    raise ValueError("invalid model")
if effort is not None and (not isinstance(effort, str) or not effort.strip()):
    raise ValueError("invalid model_reasoning_effort")
print(json.dumps({"model": model, "model_reasoning_effort": effort}, separators=(",", ":")))
'@
    $output = & $pythonCommand.Source -c $python $configPath
    if ($LASTEXITCODE -ne 0) {
        throw 'Run config model settings could not be parsed.'
    }
    return ($output | ConvertFrom-Json)
}

function Test-SettingEqual {
    param(
        [AllowNull()][object]$Left,
        [AllowNull()][object]$Right
    )

    if ($null -eq $Left -or $null -eq $Right) {
        return $null -eq $Left -and $null -eq $Right
    }
    return [string]::Equals([string]$Left, [string]$Right, [StringComparison]::Ordinal)
}

function Write-WatcherState {
    param(
        [Parameter(Mandatory = $true)]$PendingFields,
        [Parameter(Mandatory = $true)]$ObservedSettings
    )

    $state = [ordered]@{
        schemaVersion = 1
        pendingFields = @($PendingFields | Sort-Object)
        observed = [ordered]@{
            model = $ObservedSettings.model
            modelReasoningEffort = $ObservedSettings.model_reasoning_effort
        }
    }
    $temporaryPath = "$StateFile.tmp-$PID"
    [IO.File]::WriteAllText(
        $temporaryPath,
        (($state | ConvertTo-Json -Depth 5) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )
    Move-Item -LiteralPath $temporaryPath -Destination $StateFile -Force
}

function Add-PendingFieldsFromState {
    param([Parameter(Mandatory = $true)]$PendingFields)

    if (-not (Test-Path -LiteralPath $StateFile -PathType Leaf)) {
        return
    }
    try {
        $state = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
        if ($state.schemaVersion -ne 1) {
            throw 'Unsupported watcher state schema.'
        }
        foreach ($field in @($state.pendingFields)) {
            if ([string]$field -notin @('model', 'model_reasoning_effort')) {
                throw 'Watcher state contains an unsupported changed field.'
            }
            $null = $PendingFields.Add([string]$field)
        }
    } catch {
        Write-PersistenceEvent -Level 'error' -Status 'state_invalid' `
            -ErrorCode 'invalid_watcher_state' -ExitCode $null -Message $_.Exception.Message
    }
}

function Get-PowerShellExecutable {
    $name = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
    $path = Join-Path $PSHOME $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Current PowerShell executable was not found: $path"
    }
    return [IO.Path]::GetFullPath($path)
}

function Find-PersistenceResult {
    param([AllowEmptyCollection()][object[]]$Output)

    for ($index = $Output.Count - 1; $index -ge 0; $index--) {
        $text = [string]$Output[$index]
        if ([string]::IsNullOrWhiteSpace($text)) {
            continue
        }
        try {
            $candidate = $text | ConvertFrom-Json -ErrorAction Stop
            if ($candidate.PSObject.Properties.Name -contains 'ok') {
                return $candidate
            }
        } catch {
        }
    }
    return $null
}

function Invoke-ModelPersistence {
    param([Parameter(Mandatory = $true)][string[]]$ChangedFields)

    if (-not (Test-Path -LiteralPath $PersistScript -PathType Leaf)) {
        Write-PersistenceEvent -Level 'error' -Status 'failed' -ErrorCode 'persist_script_missing' `
            -ExitCode $null -Message 'The persistence script is missing.'
        return [pscustomobject]@{ Success = $false; Transient = $false }
    }

    $arguments = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $PersistScript,
        '-RunHome', $RunHome,
        '-ExitOrder', ([string][DateTime]::UtcNow.Ticks),
        '-CcSwitchRoot', $CcSwitchRoot,
        '-AllowedRunHomesRoot', $AllowedRunHomesRoot,
        '-Json'
    )
    if ($ChangedFields.Count -gt 0) {
        $arguments += @('-ChangedFieldsCsv', ($ChangedFields -join ','))
    }

    $previousPreference = $ErrorActionPreference
    $global:LASTEXITCODE = 0
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& (Get-PowerShellExecutable) @arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }

    $result = Find-PersistenceResult -Output $output
    if ($null -ne $result -and [bool]$result.ok -and $exitCode -in @($null, 0)) {
        Write-PersistenceEvent -Level 'info' -Status ([string]$result.status) -ErrorCode $null `
            -ExitCode 0 -Message ([string]$result.message)
        return [pscustomobject]@{ Success = $true; Transient = $false }
    }

    $errorCode = if ($null -ne $result) { [string]$result.errorCode } else { 'missing_result' }
    $message = if ($null -ne $result) { [string]$result.message } else { 'Persistence returned no JSON result.' }
    Write-PersistenceEvent -Level 'error' -Status 'failed' -ErrorCode $errorCode `
        -ExitCode $exitCode -Message $message
    return [pscustomobject]@{
        Success = $false
        Transient = $errorCode -eq 'database_busy'
    }
}

function Invoke-PendingPersistenceWithRetry {
    param(
        [Parameter(Mandatory = $true)]$PendingFields,
        [Parameter(Mandatory = $true)]$ObservedSettings
    )

    if ($PendingFields.Count -eq 0) {
        return $true
    }

    foreach ($delay in @(0, 250, 500, 1000)) {
        if ($delay -gt 0) {
            Start-Sleep -Milliseconds $delay
        }
        $persistence = Invoke-ModelPersistence -ChangedFields @($PendingFields)
        if ($persistence.Success) {
            $PendingFields.Clear()
            Write-WatcherState -PendingFields $PendingFields -ObservedSettings $ObservedSettings
            return $true
        }
        if (-not $persistence.Transient) {
            return $false
        }
    }
    return $false
}

$pendingFields = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$lastFingerprint = Get-ConfigFingerprint
$lastObserved = Read-RunModelSettings
Add-PendingFieldsFromState -PendingFields $pendingFields
Write-WatcherState -PendingFields $pendingFields -ObservedSettings $lastObserved
[IO.File]::WriteAllText($ReadyFile, 'ready', [Text.UTF8Encoding]::new($false))
$stopRequested = $false

try {
    $null = Invoke-PendingPersistenceWithRetry `
        -PendingFields $pendingFields `
        -ObservedSettings $lastObserved

    while (Test-ParentProcessAlive) {
        if (Test-Path -LiteralPath $StopFile -PathType Leaf) {
            $stopRequested = $true
            break
        }

        Start-Sleep -Milliseconds 100
        $currentFingerprint = Get-ConfigFingerprint
        if ($null -eq $currentFingerprint -or $currentFingerprint -eq $lastFingerprint) {
            continue
        }

        Start-Sleep -Milliseconds 75
        $stableFingerprint = Get-ConfigFingerprint
        if ($null -eq $stableFingerprint -or $stableFingerprint -ne $currentFingerprint) {
            continue
        }

        try {
            $currentSettings = Read-RunModelSettings
        } catch {
            Write-PersistenceEvent -Level 'error' -Status 'parse_failed' -ErrorCode 'invalid_run_config' `
                -ExitCode $null -Message $_.Exception.Message
            continue
        }

        if (-not (Test-SettingEqual -Left $lastObserved.model -Right $currentSettings.model)) {
            $null = $pendingFields.Add('model')
        }
        if (-not (Test-SettingEqual `
            -Left $lastObserved.model_reasoning_effort `
            -Right $currentSettings.model_reasoning_effort)) {
            $null = $pendingFields.Add('model_reasoning_effort')
        }

        $lastObserved = $currentSettings
        $lastFingerprint = $stableFingerprint
        Write-WatcherState -PendingFields $pendingFields -ObservedSettings $lastObserved

        $null = Invoke-PendingPersistenceWithRetry `
            -PendingFields $pendingFields `
            -ObservedSettings $lastObserved
    }
} finally {
    if (-not $stopRequested -and $pendingFields.Count -gt 0) {
        $null = Invoke-PendingPersistenceWithRetry `
            -PendingFields $pendingFields `
            -ObservedSettings $lastObserved
    }
    Remove-Item -LiteralPath $ReadyFile -Force -ErrorAction SilentlyContinue
}
