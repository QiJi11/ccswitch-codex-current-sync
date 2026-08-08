[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Condition {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) "fast-hybrid-provider-$PID-$([guid]::NewGuid().ToString('N'))"
try {
    $ccSwitchRoot = Join-Path $fixtureRoot 'cc switch'
    $backupRoot = Join-Path $fixtureRoot 'backups'
    New-Item -ItemType Directory -Path $ccSwitchRoot -Force | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $ccSwitchRoot 'settings.json'),
        '{"currentProviderCodex":"provider-1"}',
        [System.Text.UTF8Encoding]::new($false)
    )
    $providerConfig = 'model_provider = "custom"' + "`n" +
        'model = "gpt-5.5"' + "`n" +
        '[model_providers.custom]' + "`n" +
        'base_url = "https://example.test/v1"' + "`n" +
        'wire_api = "responses"' + "`n" +
        'requires_openai_auth = true' + "`n"
    $providerSettings = [ordered]@{
        config = $providerConfig
        auth = [ordered]@{ auth_mode = 'apikey'; OPENAI_API_KEY = 'fixture-provider-key' }
    } | ConvertTo-Json -Depth 10 -Compress
    $databasePath = Join-Path $ccSwitchRoot 'cc-switch.db'
    $null = @'
import sqlite3
import sys

connection = sqlite3.connect(sys.argv[1])
connection.execute("create table providers (id text, app_type text, name text, is_current integer, settings_config text)")
connection.execute("insert into providers values ('provider-1', 'codex', 'Fixture provider', 1, ?)", (sys.argv[2],))
connection.commit()
connection.close()
'@ | python - $databasePath $providerSettings
    Assert-Condition ($LASTEXITCODE -eq 0) 'The provider fixture database was not created.'

    $authPath = Join-Path $fixtureRoot 'chatgpt-auth.json'
    $catalogPath = Join-Path $fixtureRoot 'catalog.json'
    $tokenPath = Join-Path $fixtureRoot 'proxy.token'
    [System.IO.File]::WriteAllText($authPath, '{"auth_mode":"chatgpt","tokens":{"access_token":"fixture-token"}}', [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($catalogPath, '{"models":[]}', [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($tokenPath, ('1' * 64), [System.Text.Encoding]::ASCII)
    $scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\persist-codex-fast-hybrid-provider.ps1'
    $output = & $scriptPath -ChatGptAuthPath $authPath -CcSwitchRoot $ccSwitchRoot -ModelCatalogPath $catalogPath -ProxyTokenPath $tokenPath -BackupRoot $backupRoot -Port 17896 | ConvertFrom-Json

    $verification = @'
import json
import sqlite3
import sys
import tomllib

with sqlite3.connect(sys.argv[1]) as connection:
    settings = json.loads(connection.execute("select settings_config from providers where id='provider-1'").fetchone()[0])
config = tomllib.loads(settings["config"])
print(json.dumps({
    "authMode": settings["auth"]["auth_mode"],
    "apiKey": settings["auth"]["OPENAI_API_KEY"],
    "upstream": settings["_codexFastProxyUpstreamBaseUrl"],
    "baseUrl": config["model_providers"]["custom"]["base_url"],
    "model": config["model"],
    "serviceTier": config["service_tier"],
}))
'@ | python - $databasePath | ConvertFrom-Json
    Assert-Condition $output.Persisted 'The provider update did not report success.'
    Assert-Condition ($verification.authMode -eq 'chatgpt') 'ChatGPT auth mode was not persisted.'
    Assert-Condition ($verification.apiKey -eq 'fixture-provider-key') 'The provider API key was not retained.'
    Assert-Condition ($verification.upstream -eq 'https://example.test/v1') 'The HTTPS upstream was not retained.'
    Assert-Condition ($verification.baseUrl -eq 'http://127.0.0.1:17896') 'The provider config was not pointed at loopback.'
    Assert-Condition ($verification.model -eq 'gpt-5.6-sol') 'The provider model was not updated.'
    Assert-Condition ($verification.serviceTier -eq 'priority') 'The provider service tier was not updated.'
    Assert-Condition (Test-Path -LiteralPath (Join-Path $output.BackupDirectory 'cc-switch.db')) 'The provider database was not backed up.'
    Write-Output 'PASS fast hybrid provider'
} finally {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}
