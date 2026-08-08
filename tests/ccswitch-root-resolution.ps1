[CmdletBinding()]
param(
    [string]$ScriptPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\resolve-ccswitch-root.ps1')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. $ScriptPath

$fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ccswitch-root-$PID-$([guid]::NewGuid().ToString('N'))"
try {
    $userRoot = Join-Path $fixtureRoot 'user'
    $appDataRoot = Join-Path $userRoot 'AppData\Roaming'
    $desktopRoot = Join-Path $appDataRoot 'com.ccswitch.desktop'
    $legacyRoot = Join-Path $userRoot '.cc-switch'
    foreach ($root in @($desktopRoot, $legacyRoot)) {
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $root 'settings.json') -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $root 'cc-switch.db') -Force | Out-Null
    }

    $resolved = Resolve-CcSwitchRoot -UserRoot $userRoot -AppDataRoot $appDataRoot
    if (-not [string]::Equals($resolved, $desktopRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Desktop CC Switch root was not preferred over the legacy root.'
    }
    $explicit = Resolve-CcSwitchRoot -ExplicitRoot $legacyRoot -UserRoot $userRoot -AppDataRoot $appDataRoot
    if (-not [string]::Equals($explicit, $legacyRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Explicit CC Switch root did not take precedence.'
    }
    Write-Output 'PASS CC Switch root resolution'
} finally {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}
