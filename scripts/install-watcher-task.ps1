<#
.SYNOPSIS
    Registers (or re-registers) the ccswitch-watcher as a Windows Scheduled Task
    that starts automatically at user logon, running hidden in the background.

.DESCRIPTION
    Task name : ccswitch-codex-current-watcher
    Trigger   : At logon (current user)
    Action    : powershell.exe -NoProfile -WindowStyle Hidden -NonInteractive -File watch-ccswitch-sync.ps1
    Root      : %USERPROFILE%\.cc-switch by default; AppData root is diagnostics-only.
    Log file  : %USERPROFILE%\.prodex\logs\ccswitch-watcher.log

.PARAMETER Uninstall
    Remove the scheduled task instead of creating it.

.PARAMETER StartNow
    After registering, immediately start the task.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Uninstall,
    [switch]$StartNow,
    [string]$TaskName = 'ccswitch-codex-current-watcher'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptPath = Join-Path $PSScriptRoot 'watch-ccswitch-sync.ps1'
$FallbackTaskName = 'ccswitch-codex-current-watcher-user'

if ($Uninstall) {
    foreach ($name in @($TaskName, $FallbackTaskName) | Select-Object -Unique) {
        if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
            try {
                Unregister-ScheduledTask -TaskName $name -Confirm:$false
                Write-Host "Scheduled task '$name' removed."
            } catch {
                Write-Warning "Could not remove scheduled task '$name': $_"
            }
        } else {
            Write-Host "Task '$name' not found — nothing to remove."
        }
    }
    return
}

if (-not (Test-Path -LiteralPath $ScriptPath)) {
    throw "Watcher script not found: $ScriptPath"
}

$binDir = Join-Path $env:USERPROFILE '.prodex\bin'
New-Item -ItemType Directory -Path $binDir -Force | Out-Null
foreach ($scriptName in @('switch-codex-provider.ps1', 'materialize-ccswitch-codex-run.ps1', 'sync-ccswitch-current-codex.ps1')) {
    $source = Join-Path $PSScriptRoot $scriptName
    $target = Join-Path $binDir $scriptName
    if (-not (Test-Path -LiteralPath $source)) {
        throw "Required script not found: $source"
    }
    Copy-Item -LiteralPath $source -Destination $target -Force
}

$powerShellExe = Get-Command pwsh.exe -ErrorAction SilentlyContinue
if ($null -eq $powerShellExe) {
    $powerShellExe = Get-Command powershell.exe -ErrorAction Stop
}

$action = New-ScheduledTaskAction `
    -Execute $powerShellExe.Source `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`""

$trigger  = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit (New-TimeSpan -Seconds 0) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -MultipleInstances IgnoreNew

$registerName = $TaskName

if (Get-ScheduledTask -TaskName $registerName -ErrorAction SilentlyContinue) {
    try {
        Unregister-ScheduledTask -TaskName $registerName -Confirm:$false
    } catch {
        if ($registerName -eq $FallbackTaskName) {
            throw
        }
        Write-Warning "Could not replace '$registerName' ($_) ; using '$FallbackTaskName'."
        $registerName = $FallbackTaskName
        if (Get-ScheduledTask -TaskName $registerName -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $registerName -Confirm:$false
        }
    }
}

Register-ScheduledTask `
    -TaskName $registerName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -RunLevel Limited `
    -Description "Auto-syncs Codex provider state from the active ~/.cc-switch root when CC Switch changes." `
    | Out-Null

Write-Host "Scheduled task '$registerName' registered (runs at logon)."

if ($StartNow) {
    Start-ScheduledTask -TaskName $registerName
    Start-Sleep -Milliseconds 800
    $state = (Get-ScheduledTask -TaskName $registerName).State
    Write-Host "Task started. Current state: $state"
    Write-Host "Log: $env:USERPROFILE\.prodex\logs\ccswitch-watcher.log"
}
