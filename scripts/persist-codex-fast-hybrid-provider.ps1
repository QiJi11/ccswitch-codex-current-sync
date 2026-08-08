[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ChatGptAuthPath,
    [string]$CcSwitchRoot = '',
    [string]$ModelCatalogPath = (Join-Path $env:USERPROFILE '.codex\provider-gpt-5.6-model-catalog.json'),
    [string]$ProxyTokenPath = (Join-Path $env:USERPROFILE '.prodex\run\codex-fast-auth-proxy.token'),
    [string]$BackupRoot = (Join-Path $env:USERPROFILE '.codex\backups'),
    [ValidateRange(1024, 65535)]
    [int]$Port = 17896
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'resolve-ccswitch-root.ps1')

function Write-Utf8NoBom {
    param([string]$Path, [string]$Content)
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

$userRoot = [System.IO.Path]::GetFullPath($env:USERPROFILE)
$ccSwitchRoot = Resolve-CcSwitchRoot -ExplicitRoot $CcSwitchRoot -UserRoot $userRoot -AppDataRoot $env:APPDATA
$settingsPath = Join-Path $ccSwitchRoot 'settings.json'
$databasePath = Join-Path $ccSwitchRoot 'cc-switch.db'
$chatGptAuthPath = [System.IO.Path]::GetFullPath($ChatGptAuthPath)
$modelCatalogPath = [System.IO.Path]::GetFullPath($ModelCatalogPath)
$backupRoot = [System.IO.Path]::GetFullPath($BackupRoot)
$python = (Get-Command python -ErrorAction Stop).Source
$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) "persist-fast-hybrid-$PID-$([guid]::NewGuid().ToString('N'))"

try {
    New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
    $snapshotPath = Join-Path $temporaryRoot 'snapshot.json'
    $snapshotScript = @'
import json
import sqlite3
import sys
import tomllib
from pathlib import Path

settings_path, database_path, output_path = map(Path, sys.argv[1:4])
provider_id = json.loads(settings_path.read_text(encoding="utf-8"))["currentProviderCodex"]
database_uri = database_path.resolve().as_uri() + "?mode=ro"
with sqlite3.connect(database_uri, uri=True) as connection:
    current_ids = connection.execute(
        "select id from providers where app_type='codex' and is_current=1"
    ).fetchall()
    row = connection.execute(
        "select name, settings_config from providers where app_type='codex' and id=?",
        (provider_id,),
    ).fetchone()
if current_ids != [(provider_id,)] or row is None:
    raise SystemExit("CC Switch settings and database current provider disagree.")
settings_config = json.loads(row[1])
provider_config = tomllib.loads(settings_config["config"])
provider_name = provider_config["model_provider"]
upstream = settings_config.get("_codexFastProxyUpstreamBaseUrl")
if upstream is None:
    upstream = provider_config["model_providers"][provider_name]["base_url"]
auth = settings_config.get("auth") or {}
api_key = auth.get("OPENAI_API_KEY")
if not isinstance(api_key, str) or not api_key:
    raise SystemExit("Current provider API key is missing.")
snapshot = {
    "providerId": provider_id,
    "providerName": row[0],
    "settingsConfigRaw": row[1],
    "settingsConfig": settings_config,
    "upstreamBaseUrl": upstream,
    "apiKey": api_key,
}
output_path.write_text(json.dumps(snapshot, ensure_ascii=False), encoding="utf-8")
'@
    $snapshotScript | & $python - $settingsPath $databasePath $snapshotPath
    if ($LASTEXITCODE -ne 0) { throw 'Failed to snapshot the current CC Switch provider.' }
    $snapshot = Get-Content -Raw -LiteralPath $snapshotPath | ConvertFrom-Json

    $temporaryCodexHome = Join-Path $temporaryRoot 'codex-home'
    New-Item -ItemType Directory -Path $temporaryCodexHome | Out-Null
    Write-Utf8NoBom -Path (Join-Path $temporaryCodexHome 'config.toml') -Content ([string]$snapshot.settingsConfig.config)
    Write-Utf8NoBom -Path (Join-Path $temporaryCodexHome 'auth.json') -Content (($snapshot.settingsConfig.auth | ConvertTo-Json -Depth 20) + "`n")
    & (Join-Path $PSScriptRoot 'enable-codex-fast-hybrid.ps1') `
        -ChatGptAuthPath $chatGptAuthPath `
        -CodexHome $temporaryCodexHome `
        -ModelCatalogPath $modelCatalogPath `
        -ProxyTokenPath $ProxyTokenPath `
        -Port $Port | Out-Null

    $desiredAuth = Get-Content -Raw -LiteralPath (Join-Path $temporaryCodexHome 'auth.json') | ConvertFrom-Json
    $desiredAuth | Add-Member -NotePropertyName OPENAI_API_KEY -NotePropertyValue ([string]$snapshot.apiKey) -Force
    $desiredSettings = $snapshot.settingsConfig
    $desiredSettings.config = Get-Content -Raw -LiteralPath (Join-Path $temporaryCodexHome 'config.toml')
    $desiredSettings.auth = $desiredAuth
    $desiredSettings | Add-Member -NotePropertyName '_codexFastProxyUpstreamBaseUrl' -NotePropertyValue ([string]$snapshot.upstreamBaseUrl) -Force
    $desiredSettings | Add-Member -NotePropertyName '_codexFastProxySchemaVersion' -NotePropertyValue 1 -Force
    $desiredSettingsPath = Join-Path $temporaryRoot 'desired-settings.json'
    Write-Utf8NoBom -Path $desiredSettingsPath -Content (($desiredSettings | ConvertTo-Json -Depth 30 -Compress) + "`n")

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupDirectory = Join-Path $backupRoot "fast-hybrid-provider-$stamp"
    New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
    Copy-Item -LiteralPath $settingsPath -Destination (Join-Path $backupDirectory 'settings.json')
    $databaseBackupPath = Join-Path $backupDirectory 'cc-switch.db'
    $updateScript = @'
import sqlite3
import sys
from pathlib import Path

database_path = Path(sys.argv[1])
provider_id = sys.argv[2]
expected_raw = Path(sys.argv[3]).read_text(encoding="utf-8")
desired_raw = Path(sys.argv[4]).read_text(encoding="utf-8").strip()
backup_path = Path(sys.argv[5])
with sqlite3.connect(database_path, timeout=15) as source, sqlite3.connect(backup_path) as backup:
    source.backup(backup)
with sqlite3.connect(database_path, timeout=15, isolation_level=None) as connection:
    connection.execute("begin immediate")
    current_ids = connection.execute(
        "select id from providers where app_type='codex' and is_current=1"
    ).fetchall()
    row = connection.execute(
        "select settings_config from providers where app_type='codex' and id=?",
        (provider_id,),
    ).fetchone()
    if current_ids != [(provider_id,)] or row is None or row[0] != expected_raw:
        connection.rollback()
        raise SystemExit("Current provider changed before the hybrid update could commit.")
    connection.execute(
        "update providers set settings_config=? where app_type='codex' and id=?",
        (desired_raw, provider_id),
    )
    verified = connection.execute(
        "select settings_config from providers where app_type='codex' and id=?",
        (provider_id,),
    ).fetchone()
    if verified != (desired_raw,):
        connection.rollback()
        raise SystemExit("Provider hybrid update verification failed.")
    connection.commit()
'@
    $expectedPath = Join-Path $temporaryRoot 'expected-settings.json'
    Write-Utf8NoBom -Path $expectedPath -Content ([string]$snapshot.settingsConfigRaw)
    $updateScript | & $python - $databasePath $snapshot.providerId $expectedPath $desiredSettingsPath $databaseBackupPath
    if ($LASTEXITCODE -ne 0) { throw 'Failed to persist the hybrid provider settings.' }

    [pscustomobject]@{
        Persisted = $true
        ProviderId = $snapshot.providerId
        ProviderName = $snapshot.providerName
        UpstreamHost = ([uri]$snapshot.upstreamBaseUrl).Host
        BackupDirectory = $backupDirectory
    } | ConvertTo-Json -Compress
} finally {
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
}
