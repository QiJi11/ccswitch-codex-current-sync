[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'scripts\get-ccswitch-provider-config-migration.ps1'
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) "ccswitch-provider-preview-$PID-$([guid]::NewGuid().ToString('N'))"
$ccSwitchRoot = Join-Path $fixtureRoot '.cc-switch'
$codexHome = Join-Path $fixtureRoot '.codex'
$dbPath = Join-Path $ccSwitchRoot 'cc-switch.db'
$settingsPath = Join-Path $ccSwitchRoot 'settings.json'
$liveConfigPath = Join-Path $codexHome 'config.toml'

function Assert-True {
    param([bool]$Condition, [string]$Because)
    if (-not $Condition) { throw "Assertion failed: $Because" }
}

function Get-Sha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

try {
    [IO.Directory]::CreateDirectory($ccSwitchRoot) | Out-Null
    [IO.Directory]::CreateDirectory($codexHome) | Out-Null
    $env:PYTHONUTF8 = '1'
    @'
import json
import sqlite3
import sys
from pathlib import Path

db_path = Path(sys.argv[1])
connection = sqlite3.connect(db_path)
connection.execute(
    "create table providers (id text primary key, name text, app_type text, is_current integer, settings_config text)"
)
configs = {
    "current": '''model = "fixture"
ask_for_approval = "never" # preserve value comment

[features]
goals = true
js_repl = false # removed compatibility flag
''',
    "conflict": '''ask_for_approval = "on-request"
approval_policy = "never"

[features]
fast_mode = true
''',
    "js-only": '''model = "fixture-js"

[features] # comment remains
js_repl = true
goals = false
''',
    "clean": '''approval_policy = "on-request"

[features]
goals = true
''',
}
for index, (provider_id, config) in enumerate(configs.items()):
    payload = {
        "config": config,
        "auth": {"OPENAI_API_KEY": "SECRET_SHOULD_NOT_LEAK"},
        "fixtureMarker": provider_id,
    }
    connection.execute(
        "insert into providers values (?, ?, 'codex', ?, ?)",
        (provider_id, f"Provider {provider_id}", int(index == 0), json.dumps(payload, separators=(",", ":"))),
    )
connection.commit()
connection.close()
'@ | python - $dbPath
    if ($LASTEXITCODE -ne 0) { throw 'Unable to create the provider config fixture database.' }

    [IO.File]::WriteAllText(
        $settingsPath,
        '{"currentProviderCodex":"current"}',
        [Text.UTF8Encoding]::new($false)
    )
    $currentConfig = @'
model = "fixture"
ask_for_approval = "never" # preserve value comment

[features]
goals = true
js_repl = false # removed compatibility flag
'@
    [IO.File]::WriteAllText($liveConfigPath, $currentConfig + "`n", [Text.UTF8Encoding]::new($false))

    $hashesBefore = @{
        database = Get-Sha256 $dbPath
        settings = Get-Sha256 $settingsPath
        live = Get-Sha256 $liveConfigPath
    }
    $jsonOutput = @(& $scriptPath -CcSwitchRoot $ccSwitchRoot -CodexHome $codexHome -Json)
    $preview = $jsonOutput | ConvertFrom-Json

    Assert-True ([bool]$preview.ok) 'the migration preview must succeed'
    Assert-True ($preview.mode -eq 'preview') 'the tool must expose preview-only mode'
    Assert-True ($preview.providerCount -eq 4) 'all fixture providers must be inspected'
    Assert-True ($preview.affectedProviderCount -eq 3) 'only providers with legacy keys must be listed'
    Assert-True ($preview.legacyApprovalCount -eq 2) 'legacy approval keys must be counted once per provider'
    Assert-True ($preview.removedJsReplCount -eq 2) 'removed js_repl keys must be counted once per provider'
    Assert-True ([bool]$preview.liveConfigMatchesCurrentProvider) 'the fixture live mirror must match the current provider'
    Assert-True (-not [bool]$preview.databaseChanged -and -not [bool]$preview.filesChanged) 'preview must report no writes'
    Assert-True (($jsonOutput -join "`n") -notlike '*SECRET_SHOULD_NOT_LEAK*') 'preview output must not expose provider auth'

    $currentItem = @($preview.items | Where-Object providerId -eq 'current')
    $conflictItem = @($preview.items | Where-Object providerId -eq 'conflict')
    $jsOnlyItem = @($preview.items | Where-Object providerId -eq 'js-only')
    Assert-True ($currentItem.Count -eq 1 -and $currentItem[0].changes -contains 'rename_ask_for_approval') `
        'legacy-only approval must preview a rename'
    Assert-True ($conflictItem.Count -eq 1 -and $conflictItem[0].changes -contains 'remove_ask_for_approval') `
        'an existing official approval key must win over the legacy key'
    Assert-True ($jsOnlyItem.Count -eq 1 -and $jsOnlyItem[0].changes -contains 'remove_features_js_repl') `
        'a js_repl-only provider must preview removal'

    Assert-True ((Get-Sha256 $dbPath) -eq $hashesBefore.database) 'preview must not change the database'
    Assert-True ((Get-Sha256 $settingsPath) -eq $hashesBefore.settings) 'preview must not change settings.json'
    Assert-True ((Get-Sha256 $liveConfigPath) -eq $hashesBefore.live) 'preview must not change the live mirror'

    [IO.File]::WriteAllText($settingsPath, '{"currentProviderCodex":"clean"}', [Text.UTF8Encoding]::new($false))
    $caught = $null
    try {
        $null = & $scriptPath -CcSwitchRoot $ccSwitchRoot -CodexHome $codexHome -Json 2>&1
    } catch {
        $caught = $_
    }
    Assert-True ($null -ne $caught) 'a settings/database current-provider mismatch must fail closed'
    Assert-True ((Get-Sha256 $dbPath) -eq $hashesBefore.database) 'failed preview must leave the database unchanged'

    Write-Output '[PASS] provider config migration preview fixture'
} finally {
    if (Test-Path -LiteralPath $fixtureRoot) {
        $resolved = [IO.Path]::GetFullPath($fixtureRoot)
        $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Leaf $resolved) -like 'ccswitch-provider-preview-*') {
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }
}
