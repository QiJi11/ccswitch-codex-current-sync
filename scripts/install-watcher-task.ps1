<#[
.SYNOPSIS
    Retains the historical watcher task name for uninstall only.
#>
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$StartNow,
    [string]$TaskName = 'ccswitch-codex-current-watcher'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$fallbackTaskName = 'ccswitch-codex-current-watcher-user'
if (-not $Uninstall) {
    throw 'Legacy Codex watcher installation is disabled; use the direct provider switch from the CC Switch UI.'
}

foreach ($name in @($TaskName, $fallbackTaskName) | Select-Object -Unique) {
    $task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    if ($null -ne $task) {
        Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction Stop
        Write-Host "Scheduled task '$name' removed."
    }
}
