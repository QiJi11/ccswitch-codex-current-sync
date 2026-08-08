[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) "ccswitch-direct-activation-$PID-$([guid]::NewGuid().ToString('N'))"
$ccSwitchRoot = Join-Path $fixtureRoot '.cc-switch'
$codexHome = Join-Path $fixtureRoot '.codex'
$settingsPath = Join-Path $ccSwitchRoot 'settings.json'
$databasePath = Join-Path $ccSwitchRoot 'cc-switch.db'
$configPath = Join-Path $codexHome 'config.toml'
$backupPath = Join-Path $fixtureRoot 'config-before.toml'
$activationScript = 'C:\Users\tianh\.codex\bin\activate-ccswitch-direct-provider.py'
$providerId = 'fixture-provider'

function Assert-True {
    param([bool]$Condition, [string]$Because)
    if (-not $Condition) { throw "Assertion failed: $Because" }
}

try {
    [IO.Directory]::CreateDirectory($ccSwitchRoot) | Out-Null
    [IO.Directory]::CreateDirectory($codexHome) | Out-Null
    [IO.File]::WriteAllText(
        $settingsPath,
        ('{"currentProviderCodex":"' + $providerId + '"}'),
        [Text.UTF8Encoding]::new($false)
    )

    $env:PYTHONUTF8 = '1'
    @'
import json
import sqlite3
import sys
from pathlib import Path

db_path = Path(sys.argv[1])
provider_id = sys.argv[2]
provider_config = '''model_provider = "custom"
model = "gpt-5.6-luna"
model_reasoning_effort = "max"
service_tier = "fast"

[model_providers.custom]
name = "Fixture provider"
base_url = "https://fixture.example/v1"
wire_api = "responses"
requires_openai_auth = false
'''
payload = {
    "config": provider_config,
    "auth": {"OPENAI_API_KEY": "fixture-secret"},
}
connection = sqlite3.connect(db_path)
connection.execute(
    "create table providers (id text primary key, app_type text, is_current integer, settings_config text)"
)
connection.execute(
    "insert into providers values (?, 'codex', 1, ?)",
    (provider_id, json.dumps(payload, separators=(",", ":"))),
)
connection.execute(
    "create table proxy_config (app_type text, enabled integer, proxy_enabled integer, live_takeover_active integer)"
)
connection.execute("insert into proxy_config values ('codex', 1, 1, 1)")
connection.commit()
connection.close()
'@ | python - $databasePath $providerId
    Assert-True ($LASTEXITCODE -eq 0) 'Unable to create the provider fixture database.'

    $malformedConfig = @'
approval_policy = "never"

[features]
remote_plugin = false

[features.multi_agent_v2]
enabled = true
'@
    [IO.File]::WriteAllText($configPath, $malformedConfig, [Text.UTF8Encoding]::new($false))

    $activationOutput = @(
        & python $activationScript `
            --ccswitch-root $ccSwitchRoot `
            --codex-root $codexHome `
            --provider-id $providerId `
            --backup $backupPath
    )
    Assert-True ($LASTEXITCODE -eq 0) 'Activation must repair a config without a provider table.'
    Assert-True ((Get-Content -LiteralPath $backupPath -Raw) -eq $malformedConfig) `
        'Activation must preserve an exact rollback copy of the malformed config.'

    $configCheck = @'
import json
import sys
import tomllib

config = tomllib.loads(open(sys.argv[1], encoding="utf-8").read())
provider = config["model_providers"]["custom"]
print(json.dumps({
    "model": config["model"],
    "model_provider": config["model_provider"],
    "base_url": provider["base_url"],
    "multi_agent_enabled": config["features"]["multi_agent_v2"]["enabled"],
    "has_secret": "fixture-secret" in open(sys.argv[1], encoding="utf-8").read(),
}, separators=(",", ":")))
'@
    $summary = ($configCheck | python - $configPath | ConvertFrom-Json)
    Assert-True ($LASTEXITCODE -eq 0) 'Repaired config must remain valid TOML.'
    Assert-True ($summary.model_provider -eq 'custom') 'Repaired config must select the custom provider.'
    Assert-True ($summary.model -eq 'gpt-5.6-luna') 'Repaired config must preserve the provider model.'
    Assert-True ($summary.base_url -eq 'https://fixture.example/v1') 'Repaired config must preserve the provider endpoint.'
    Assert-True (-not [bool]$summary.multi_agent_enabled) 'Third-party activation must disable multi-agent v2.'
    Assert-True ([bool]$summary.has_secret) 'The repaired provider table must retain its API credential for actual requests.'
    Assert-True (($activationOutput -join "`n") -notlike '*fixture-secret*') 'Activation output must not expose provider auth.'

    Write-Output '[PASS] direct provider activation repairs a missing provider table'
} finally {
    if (Test-Path -LiteralPath $fixtureRoot) {
        $resolvedRoot = [IO.Path]::GetFullPath($fixtureRoot)
        $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if ($resolvedRoot.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Leaf $resolvedRoot) -like 'ccswitch-direct-activation-*') {
            Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
        }
    }
}
