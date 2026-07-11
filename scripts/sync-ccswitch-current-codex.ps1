[CmdletBinding()]
param(
    [string]$CcSwitchRoot = (Join-Path $env:USERPROFILE '.cc-switch'),
    [string[]]$CodexHome = @(),
    [switch]$CheckOnly,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$prodexRoot = if ([string]::IsNullOrWhiteSpace($env:PRODEX_HOME)) {
    Join-Path $env:USERPROFILE '.prodex'
} else {
    [System.IO.Path]::GetFullPath($env:PRODEX_HOME)
}
$CodexHomes = @($CodexHome | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
if ($CodexHomes.Count -eq 0) {
    $prodexCurrent = Join-Path $prodexRoot 'manual-homes\ccswitch-current'
    if (Test-Path -LiteralPath $prodexCurrent) {
        $CodexHomes = @($prodexCurrent)
    } else {
        $CodexHomes = @(Join-Path $env:USERPROFILE '.codex')
    }
}

$SettingsPath = Join-Path $CcSwitchRoot 'settings.json'
$DbPath = Join-Path $CcSwitchRoot 'cc-switch.db'

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

function Get-CurrentProviderId {
    $settings = Get-TextFileContent -Path $SettingsPath | ConvertFrom-Json
    if (-not $settings.PSObject.Properties['currentProviderCodex']) {
        throw 'cc-switch settings do not define currentProviderCodex.'
    }
    $providerId = [string]$settings.currentProviderCodex
    if ([string]::IsNullOrWhiteSpace($providerId)) {
        throw 'cc-switch currentProviderCodex is empty.'
    }
    return $providerId
}

function Get-DatabaseCurrentProviderId {
    $pythonCode = @'
import json
import sqlite3
import sys
from pathlib import Path

uri = Path(sys.argv[1]).resolve().as_uri() + "?mode=ro"
connection = sqlite3.connect(uri, uri=True, isolation_level=None)
try:
    connection.execute("pragma query_only=on")
    connection.execute("begin")
    rows = connection.execute(
        "select id from providers where app_type='codex' and is_current=1 order by id"
    ).fetchall()
    print(json.dumps({"ids": [row[0] for row in rows]}, ensure_ascii=True))
finally:
    connection.close()
'@
    $global:LASTEXITCODE = 0
    $output = @(& $pythonCommand.Source -c $pythonCode $DbPath)
    if ($LASTEXITCODE -ne 0) {
        throw "cc-switch current-provider verification failed with exit code $LASTEXITCODE."
    }
    $result = (($output | Out-String).Trim()) | ConvertFrom-Json
    $ids = @($result.ids)
    if ($ids.Count -ne 1) {
        throw "Expected exactly one current Codex provider during mirror verification; found $($ids.Count)."
    }
    return [string]$ids[0]
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

$currentProviderId = Get-CurrentProviderId

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
    write_result(result)
    raise SystemExit(0)


db_path = sys.argv[1]
provider_id = sys.argv[2]
output_path = sys.argv[3]
db_uri = "file:" + Path(db_path).as_posix() + "?mode=ro"

con = sqlite3.connect(db_uri, uri=True, isolation_level=None)
con.row_factory = sqlite3.Row
con.execute("pragma query_only=on")
con.execute("begin")
cur = con.cursor()


def write_result(result):
    Path(output_path).write_text(json.dumps(result, ensure_ascii=False), encoding="utf-8")

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
write_result(result)
con.close()
'@

$tempPythonPath = Join-Path ([System.IO.Path]::GetTempPath()) "sync-ccswitch-current-codex-$PID-$([guid]::NewGuid().ToString('N')).py"
$tempQueryOutputPath = Join-Path ([System.IO.Path]::GetTempPath()) "sync-ccswitch-current-codex-$PID-$([guid]::NewGuid().ToString('N')).json"
$previousPythonIoEncoding = $env:PYTHONIOENCODING
$previousPythonUtf8 = $env:PYTHONUTF8
try {
    [System.IO.File]::WriteAllText($tempPythonPath, $pythonCode, [System.Text.UTF8Encoding]::new($false))
    $env:PYTHONIOENCODING = 'utf-8'
    $env:PYTHONUTF8 = '1'
    & $pythonCommand.Source $tempPythonPath $DbPath $currentProviderId $tempQueryOutputPath
    if ($LASTEXITCODE -ne 0) {
        throw "cc-switch provider query failed with exit code $LASTEXITCODE."
    }
    if (-not (Test-Path -LiteralPath $tempQueryOutputPath)) {
        throw 'cc-switch provider query did not write its output.'
    }
    $queryJson = Get-TextFileContent -Path $tempQueryOutputPath
} finally {
    if ($null -eq $previousPythonIoEncoding) {
        Remove-Item Env:\PYTHONIOENCODING -ErrorAction SilentlyContinue
    } else {
        $env:PYTHONIOENCODING = $previousPythonIoEncoding
    }
    if ($null -eq $previousPythonUtf8) {
        Remove-Item Env:\PYTHONUTF8 -ErrorAction SilentlyContinue
    } else {
        $env:PYTHONUTF8 = $previousPythonUtf8
    }
    Remove-Item -LiteralPath $tempPythonPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tempQueryOutputPath -Force -ErrorAction SilentlyContinue
}

$queryJson = $queryJson.Trim()
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

$currentProviderAfter = Get-CurrentProviderId
if (-not [string]::Equals($currentProviderId, $currentProviderAfter, [StringComparison]::Ordinal)) {
    throw 'cc-switch provider selection changed while capturing the mirror snapshot.'
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
foreach ($targetHome in $CodexHomes) {
    if (-not $CheckOnly) {
        New-Item -ItemType Directory -Path $targetHome -Force | Out-Null
    }
    $configResult = Sync-TextFile `
        -Path (Join-Path $targetHome 'config.toml') `
        -DesiredContent ([string]$details.config) `
        -Stamp $stamp
    $authResult = Sync-TextFile `
        -Path (Join-Path $targetHome 'auth.json') `
        -DesiredContent ([string]$details.authJson) `
        -Stamp $stamp

    Write-SyncInfo ("ccswitch-current home={0} provider={1} id={2} config_sha256={3} auth_sha256={4}" -f `
        $targetHome, $details.provider.name, $details.provider.id, $details.configSha256, $details.authSha256)

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
}

$currentProviderFinal = Get-CurrentProviderId
$databaseProviderFinal = Get-DatabaseCurrentProviderId
if ((-not [string]::Equals([string]$details.provider.id, $currentProviderFinal, [StringComparison]::Ordinal)) -or
    (-not [string]::Equals([string]$details.provider.id, $databaseProviderFinal, [StringComparison]::Ordinal))) {
    throw 'cc-switch provider selection changed while updating the current-provider mirrors.'
}
