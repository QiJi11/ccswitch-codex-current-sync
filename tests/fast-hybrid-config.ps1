[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Condition {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) "fast-hybrid-config-$PID-$([guid]::NewGuid().ToString('N'))"
try {
    $codexHome = Join-Path $fixtureRoot 'codex home'
    New-Item -ItemType Directory -Path $codexHome -Force | Out-Null
    $configPath = Join-Path $codexHome 'config.toml'
    $authPath = Join-Path $fixtureRoot 'fresh-auth.json'
    $catalogPath = Join-Path $codexHome 'catalog.json'
    $tokenPath = Join-Path $fixtureRoot 'proxy.token'
    [System.IO.File]::WriteAllText(
        $configPath,
        "model = `"old-model`"`n[model_providers.custom]`nbase_url = `"https://old.example/v1`"`n[features]`nfast_mode = false`n[unrelated]`nkeep = true`n",
        [System.Text.UTF8Encoding]::new($false)
    )
    [System.IO.File]::WriteAllText(
        $authPath,
        '{"auth_mode":"chatgpt","tokens":{"access_token":"fixture-token"}}',
        [System.Text.UTF8Encoding]::new($false)
    )
    [System.IO.File]::WriteAllText($catalogPath, '{"models":[]}', [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($tokenPath, ('1' * 64), [System.Text.Encoding]::ASCII)

    $scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\enable-codex-fast-hybrid.ps1'
    $output = & $scriptPath -ChatGptAuthPath $authPath -CodexHome $codexHome -ModelCatalogPath $catalogPath -ProxyTokenPath $tokenPath -Port 17896 | ConvertFrom-Json
    $updatedConfig = Get-Content -Raw -LiteralPath $configPath
    $updatedAuth = Get-Content -Raw -LiteralPath (Join-Path $codexHome 'auth.json') | ConvertFrom-Json

    Assert-Condition $output.Configured 'The hybrid config script did not report success.'
    Assert-Condition ($updatedConfig -match 'model = "gpt-5\.6-sol"') 'The target model was not written.'
    Assert-Condition ($updatedConfig -match 'base_url = "http://127\.0\.0\.1:17896"') 'The loopback endpoint was not written.'
    Assert-Condition ($updatedConfig -match 'service_tier = "priority"') 'The priority service tier was not written.'
    Assert-Condition ($updatedConfig -match '(?ms)\[features\].*?fast_mode = true') 'Fast mode was not enabled.'
    Assert-Condition ($updatedConfig -match 'X-Codex-Fast-Proxy-Token') 'The local proxy token header was not written.'
    Assert-Condition ($updatedConfig -match '(?ms)\[unrelated\].*?keep = true') 'Unrelated config was not preserved.'
    Assert-Condition ($updatedAuth.auth_mode -eq 'chatgpt') 'The fresh ChatGPT auth was not installed.'
    Assert-Condition (Test-Path -LiteralPath (Join-Path $output.BackupDirectory 'config.toml')) 'The original config was not backed up.'
    $null = @'
import sys
import tomllib

with open(sys.argv[1], "rb") as stream:
    tomllib.load(stream)
'@ | python - $configPath
    Assert-Condition ($LASTEXITCODE -eq 0) 'The generated config is not valid TOML.'
    Write-Output 'PASS fast hybrid config'
} finally {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}
