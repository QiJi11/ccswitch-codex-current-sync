#!/usr/bin/env pwsh
$launcher = Join-Path $env:USERPROFILE '.prodex\bin\invoke-ccswitch-codex.ps1'
if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) {
    Write-Error "Missing cc-switch Codex launcher: $launcher"
    exit 1
}

& $launcher @args
exit $LASTEXITCODE
