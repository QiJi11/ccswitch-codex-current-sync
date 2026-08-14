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

    [string]$PersistScript = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($PersistScript)) {
    $userRoot = if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        [Environment]::GetFolderPath('UserProfile')
    } else {
        [IO.Path]::GetFullPath($env:USERPROFILE)
    }
    $PersistScript = Join-Path $userRoot '.prodex\bin\persist-run-model.ps1'
}

function Test-ParentProcessAlive {
    try {
        $parent = Get-Process -Id $ParentProcessId -ErrorAction Stop
        if ($parent.HasExited) {
            return $false
        }
        if ($ParentProcessStartTimeUtcTicks -gt 0) {
            try {
                $actualStartTimeUtcTicks = $parent.StartTime.ToUniversalTime().Ticks
            } catch {
                return $false
            }
            if ($actualStartTimeUtcTicks -ne $ParentProcessStartTimeUtcTicks) {
                return $false
            }
        }
        return $true
    } catch {
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
        $bytes = [IO.File]::ReadAllBytes($configPath)
        return -join ($sha256.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') })
    } catch {
        return $null
    } finally {
        $sha256.Dispose()
    }
}

function Get-PowerShellExecutable {
    $executableName = if ($PSVersionTable.PSEdition -eq 'Core') {
        'pwsh.exe'
    } else {
        'powershell.exe'
    }
    $executablePath = Join-Path $PSHOME $executableName
    if (-not (Test-Path -LiteralPath $executablePath -PathType Leaf)) {
        throw "Current PowerShell executable was not found: $executablePath"
    }
    return [IO.Path]::GetFullPath($executablePath)
}

function Invoke-ModelPersistence {
    if (-not (Test-Path -LiteralPath $PersistScript -PathType Leaf)) {
        Write-Verbose "Model persistence script is missing: $PersistScript"
        return
    }

    try {
        $powerShellExecutable = Get-PowerShellExecutable
        $global:LASTEXITCODE = 0
        & $powerShellExecutable -NoProfile -NonInteractive -ExecutionPolicy Bypass `
            -File $PersistScript `
            -RunHome $RunHome `
            -CcSwitchRoot $CcSwitchRoot `
            -AllowedRunHomesRoot $AllowedRunHomesRoot `
            -ExitOrder ([DateTime]::UtcNow.Ticks) `
            -Json *> $null
        $exitCode = $LASTEXITCODE
        if ($exitCode -notin @($null, 0)) {
            throw "Model persistence returned exit code $exitCode."
        }
    } catch {
        # The launcher performs a final persistence attempt after stopping this watcher.
        Write-Verbose ("Live model persistence failed: {0}" -f $_.Exception.Message)
    }
}

$lastFingerprint = Get-ConfigFingerprint
while (Test-ParentProcessAlive) {
    if (Test-Path -LiteralPath $StopFile -PathType Leaf) {
        break
    }

    Start-Sleep -Milliseconds 250
    if (-not (Test-ParentProcessAlive)) {
        break
    }
    if (Test-Path -LiteralPath $StopFile -PathType Leaf) {
        break
    }

    $currentFingerprint = Get-ConfigFingerprint
    if ($null -eq $currentFingerprint -or $currentFingerprint -eq $lastFingerprint) {
        continue
    }

    # Codex may replace config.toml in more than one filesystem operation.
    Start-Sleep -Milliseconds 150
    $stableFingerprint = Get-ConfigFingerprint
    if ($null -eq $stableFingerprint -or $stableFingerprint -ne $currentFingerprint) {
        continue
    }

    $lastFingerprint = $stableFingerprint
    Invoke-ModelPersistence
}
