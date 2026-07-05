[CmdletBinding()]
param(
    [string]$CcSwitchRoot = (Join-Path $env:USERPROFILE '.cc-switch'),
    [string]$CodexHome = '',
    [switch]$CheckOnly,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($CodexHome)) {
    $prodexCurrent = Join-Path $env:USERPROFILE '.prodex\manual-homes\ccswitch-current'
    if (Test-Path -LiteralPath $prodexCurrent) {
        $CodexHome = $prodexCurrent
    } else {
        $CodexHome = Join-Path $env:USERPROFILE '.codex'
    }
}

$SettingsPath = Join-Path $CcSwitchRoot 'settings.json'
$DbPath = Join-Path $CcSwitchRoot 'cc-switch.db'
$ConfigPath = Join-Path $CodexHome 'config.toml'
$AuthPath = Join-Path $CodexHome 'auth.json'

function Write-SyncInfo {
    param([Parameter(Mandatory = $true)][string]$Message)
    if (-not $Quiet) {
        Write-Output $Message
    }
}

function Get-TextFileContent {
    param([Parameter(Mandatory = $true)][string]$Path)
    $reader = [System.IO.StreamReader]::new($Path, [System.Text.UTF8Encoding]::new($false), $true)
    try {
        return $reader.ReadToEnd()
    } finally {
        $reader.Dispose()
    }
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )

    $tempPath = "$Path.tmp-$PID-$([guid]::NewGuid().ToString('N'))"
    try {
        [System.IO.File]::WriteAllText($tempPath, $Content, [System.Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $tempPath -Destination $Path -Force
    } finally {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
    }
}

function New-BackupPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Stamp
    )

    $candidate = "$Path.bak-$Stamp"
    $index = 1
    while (Test-Path -LiteralPath $candidate) {
        $candidate = "$Path.bak-$Stamp-$index"
        $index++
    }
    return $candidate
}

function Sync-TextFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$DesiredContent,
        [Parameter(Mandatory = $true)][string]$Stamp
    )

    if (Test-Path -LiteralPath $Path) {
        $existing = Get-TextFileContent -Path $Path
        if ([string]::Equals($existing, $DesiredContent, [StringComparison]::Ordinal)) {
            return [pscustomobject]@{ Path = $Path; Changed = $false; BackupPath = $null }
        }

        $backupPath = New-BackupPath -Path $Path -Stamp $Stamp
        if (-not $CheckOnly) {
            Copy-Item -LiteralPath $Path -Destination $backupPath -Force
        }
    } else {
        $backupPath = $null
    }

    if (-not $CheckOnly) {
        Write-Utf8NoBom -Path $Path -Content $DesiredContent
        $written = Get-TextFileContent -Path $Path
        if (-not [string]::Equals($written, $DesiredContent, [StringComparison]::Ordinal)) {
            throw "Failed to verify synced file content: $Path"
        }
    }

    return [pscustomobject]@{ Path = $Path; Changed = $true; BackupPath = $backupPath }
}

if (-not (Test-Path -LiteralPath $SettingsPath)) {
    throw "Missing cc-switch settings: $SettingsPath"
}
if (-not (Test-Path -LiteralPath $DbPath)) {
    throw "Missing cc-switch DB: $DbPath"
}

$settings = Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json
if (-not $settings.PSObject.Properties['currentProviderCodex']) {
    throw 'cc-switch settings do not define currentProviderCodex.'
}

$currentProviderId = [string]$settings.currentProviderCodex
if ([string]::IsNullOrWhiteSpace($currentProviderId)) {
    throw 'cc-switch currentProviderCodex is empty.'
}

$pythonCommand = Get-Command python -ErrorAction SilentlyContinue
if ($null -eq $pythonCommand) {
    throw 'Python is required to read the cc-switch SQLite DB, but python was not found on PATH.'
}

$pythonCode = @'
import hashlib
import json
import re
import sqlite3
import sys
from pathlib import Path
from urllib.parse import urlparse


def sha_text(value):
    if value is None:
        value = ""
    if not isinstance(value, str):
        value = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(value.encode("utf-8")).hexdigest()[:16]


def config_base_url(config_text):
    if not config_text:
        return None
    for line in str(config_text).splitlines():
        stripped = line.strip()
        if stripped.startswith("base_url"):
            raw = stripped.split("=", 1)[1].strip()
            if len(raw) >= 2 and raw[0] in ("'", '"') and raw[-1] == raw[0]:
                raw = raw[1:-1]
            return raw
    return None


def public_provider(row):
    settings_config = {}
    try:
        settings_config = json.loads(row["settings_config"] or "{}")
    except Exception:
        settings_config = {}
    base_url = config_base_url(settings_config.get("config"))
    return {
        "id": row["id"],
        "name": row["name"],
        "baseUrl": base_url,
        "baseHost": urlparse(base_url).netloc if base_url else None,
    }


def fail(message, **extra):
    result = {"ok": False, "message": message}
    result.update(extra)
    print(json.dumps(result, ensure_ascii=False))
    raise SystemExit(0)


db_path = sys.argv[1]
provider_id = sys.argv[2]
db_uri = "file:" + Path(db_path).as_posix() + "?mode=ro"

con = sqlite3.connect(db_uri, uri=True)
con.row_factory = sqlite3.Row
cur = con.cursor()

active_rows = cur.execute(
    "select id, name, settings_config from providers where app_type='codex' and is_current=1 order by name"
).fetchall()
if len(active_rows) != 1 or active_rows[0]["id"] != provider_id:
    fail(
        "cc-switch settings currentProviderCodex does not match providers.is_current for Codex.",
        requestedProviderId=provider_id,
        currentProviders=[public_provider(row) for row in active_rows],
    )

row = cur.execute(
    "select id, name, website_url, settings_config from providers where app_type='codex' and id=?",
    (provider_id,),
).fetchone()
if row is None:
    fail("Codex provider was not found in cc-switch DB.", requestedProviderId=provider_id)

try:
    settings_config = json.loads(row["settings_config"] or "{}")
except Exception as exc:
    fail("Codex provider settings_config is not valid JSON.", requestedProviderId=provider_id, parseError=str(exc))

config_text = settings_config.get("config")
if not isinstance(config_text, str) or not config_text.strip():
    fail("Codex provider has no string settings_config.config.", requestedProviderId=provider_id)

auth = settings_config.get("auth") or {}
auth_json = json.dumps(auth, ensure_ascii=False, indent=2) + "\n"
base_url = config_base_url(config_text)

result = {
    "ok": True,
    "provider": {
        "id": row["id"],
        "name": row["name"],
        "websiteUrl": row["website_url"],
        "baseUrl": base_url,
        "baseHost": urlparse(base_url).netloc if base_url else None,
    },
    "config": config_text,
    "authJson": auth_json,
    "configSha256": sha_text(config_text),
    "authSha256": sha_text(auth),
}
print(json.dumps(result, ensure_ascii=False))
con.close()
'@

$tempPythonPath = Join-Path ([System.IO.Path]::GetTempPath()) "sync-ccswitch-current-codex-$PID-$([guid]::NewGuid().ToString('N')).py"
try {
    [System.IO.File]::WriteAllText($tempPythonPath, $pythonCode, [System.Text.UTF8Encoding]::new($false))
    $queryOutput = & $pythonCommand.Source $tempPythonPath $DbPath $currentProviderId
    if ($LASTEXITCODE -ne 0) {
        throw "cc-switch provider query failed with exit code $LASTEXITCODE."
    }
} finally {
    Remove-Item -LiteralPath $tempPythonPath -Force -ErrorAction SilentlyContinue
}

$queryJson = ($queryOutput | Out-String).Trim()
if ([string]::IsNullOrWhiteSpace($queryJson)) {
    throw 'cc-switch provider query returned no data.'
}

$details = $queryJson | ConvertFrom-Json
if (-not [bool]$details.ok) {
    $message = [string]$details.message
    if ($details.PSObject.Properties['currentProviders']) {
        $providers = @($details.currentProviders | ForEach-Object {
            '{0} id={1} base_url={2}' -f $_.name, $_.id, $_.baseUrl
        })
        $message = "$message currentProviders=[$($providers -join '; ')] requestedProviderId=$currentProviderId"
    }
    throw $message
}

if (-not $CheckOnly) {
    New-Item -ItemType Directory -Path $CodexHome -Force | Out-Null
}
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

$configResult = Sync-TextFile -Path $ConfigPath -DesiredContent ([string]$details.config) -Stamp $stamp
$authResult = Sync-TextFile -Path $AuthPath -DesiredContent ([string]$details.authJson) -Stamp $stamp

Write-SyncInfo ("ccswitch-current provider={0} id={1} base_url={2} config_sha256={3} auth_sha256={4}" -f `
    $details.provider.name, $details.provider.id, $details.provider.baseUrl, $details.configSha256, $details.authSha256)

foreach ($result in @($configResult, $authResult)) {
    $leaf = Split-Path -Leaf $result.Path
    if ($result.Changed) {
        $action = if ($CheckOnly) { 'would update' } else { 'updated' }
        if ($null -eq $result.BackupPath) {
            Write-SyncInfo ("{0} {1} backup=<none-existing-file>" -f $leaf, $action)
        } else {
            Write-SyncInfo ("{0} {1} backup={2}" -f $leaf, $action, $result.BackupPath)
        }
    } else {
        Write-SyncInfo ("{0} unchanged" -f $leaf)
    }
}
