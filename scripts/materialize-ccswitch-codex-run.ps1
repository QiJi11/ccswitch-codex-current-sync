[CmdletBinding()]
param(
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$UserRoot = [Environment]::GetFolderPath('UserProfile')
if ([string]::IsNullOrWhiteSpace($UserRoot)) {
    throw 'Unable to resolve the user profile directory.'
}

$CcSwitchRoot = Join-Path $UserRoot '.cc-switch'
$ProdexRoot = Join-Path $UserRoot '.prodex'
$SettingsPath = Join-Path $CcSwitchRoot 'settings.json'
$DbPath = Join-Path $CcSwitchRoot 'cc-switch.db'
$ProdexStatePath = Join-Path $ProdexRoot 'state.json'
$RunHomesRoot = Join-Path $ProdexRoot 'manual-homes\ccswitch-runs'

function ConvertTo-SafeName {
    param([Parameter(Mandatory = $true)][string]$Value)

    $safe = $Value -replace '[^A-Za-z0-9_.-]', '-'
    $safe = $safe.Trim('-')
    if ([string]::IsNullOrWhiteSpace($safe)) {
        return 'provider'
    }
    return $safe
}

function Write-Info {
    param([Parameter(Mandatory = $true)][string]$Message)
    if (-not $Quiet) {
        Write-Output $Message
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

function Get-CurrentProviderId {
    if (-not (Test-Path -LiteralPath $SettingsPath)) {
        throw "Missing cc-switch settings: $SettingsPath"
    }
    $settings = Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json
    if (-not $settings.PSObject.Properties['currentProviderCodex']) {
        throw 'cc-switch settings do not define currentProviderCodex.'
    }
    $providerId = [string]$settings.currentProviderCodex
    if ([string]::IsNullOrWhiteSpace($providerId)) {
        throw 'cc-switch currentProviderCodex is empty.'
    }
    return $providerId
}

function Invoke-CcSwitchProviderQuery {
    param([Parameter(Mandatory = $true)][string]$RequestedProviderId)

    if (-not (Test-Path -LiteralPath $DbPath)) { throw "Missing cc-switch DB: $DbPath" }
    $python = (Get-Command python -ErrorAction Stop).Source
    $pythonCode = @'
import hashlib
import json
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

def fail(message, **extra):
    result = {"ok": False, "message": message}
    result.update(extra)
    print(json.dumps(result, ensure_ascii=False))
    raise SystemExit(0)

db_path = sys.argv[1]
provider_id = sys.argv[2]
con = sqlite3.connect("file:" + Path(db_path).as_posix() + "?mode=ro", uri=True)
con.row_factory = sqlite3.Row
cur = con.cursor()

row = cur.execute(
    "select id, name, website_url, category, sort_index, is_current, settings_config "
    "from providers where app_type='codex' and id=?",
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
if not isinstance(auth, dict):
    fail("Codex provider settings_config.auth is not an object.", requestedProviderId=provider_id)

base_url = config_base_url(config_text)
endpoints = cur.execute(
    "select url from provider_endpoints where app_type='codex' and provider_id=? order by id",
    (provider_id,),
).fetchall()
first_url = endpoints[0]["url"] if endpoints else None

result = {
    "ok": True,
    "provider": {
        "id": row["id"],
        "name": row["name"],
        "category": row["category"],
        "sortIndex": row["sort_index"],
        "isCurrent": bool(row["is_current"]),
        "websiteUrl": row["website_url"],
        "endpointHost": urlparse(first_url).netloc if first_url else None,
        "baseUrl": base_url,
        "baseHost": urlparse(base_url).netloc if base_url else None,
    },
    "config": config_text,
    "authJson": json.dumps(auth, ensure_ascii=False, indent=2) + "\n",
    "configSha256": sha_text(config_text),
    "authSha256": sha_text(auth),
}
print(json.dumps(result, ensure_ascii=False))
con.close()
'@

    $tempPythonPath = Join-Path ([System.IO.Path]::GetTempPath()) "ccswitch-codex-provider-$PID-$([guid]::NewGuid().ToString('N')).py"
    try {
        Write-Utf8NoBom -Path $tempPythonPath -Content $pythonCode
        $output = & $python $tempPythonPath $DbPath $RequestedProviderId
        if ($LASTEXITCODE -ne 0) { throw "cc-switch provider query failed with exit code $LASTEXITCODE." }
        $json = ($output | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($json)) { throw 'cc-switch provider query returned no data.' }
        $details = $json | ConvertFrom-Json
        if (-not [bool]$details.ok) { throw [string]$details.message }
        return $details
    } finally {
        Remove-Item -LiteralPath $tempPythonPath -Force -ErrorAction SilentlyContinue
    }
}

function Register-ProdexProfile {
    param(
        [Parameter(Mandatory = $true)][string]$ProfileName,
        [Parameter(Mandatory = $true)][string]$CodexHome
    )

    if (-not (Test-Path -LiteralPath $ProdexStatePath)) { throw "Missing Prodex state: $ProdexStatePath" }
    $state = Get-Content -LiteralPath $ProdexStatePath -Raw | ConvertFrom-Json
    if (-not $state.PSObject.Properties['profiles']) {
        $state | Add-Member -NotePropertyName 'profiles' -NotePropertyValue ([pscustomobject]@{})
    }
    if (-not $state.PSObject.Properties['last_run_selected_at']) {
        $state | Add-Member -NotePropertyName 'last_run_selected_at' -NotePropertyValue ([pscustomobject]@{})
    }

    $profileValue = [pscustomobject]@{
        codex_home = $CodexHome
        managed = $false
        email = $null
        provider = [pscustomobject]@{ provider_kind = 'openai' }
    }

    $backup = "$ProdexStatePath.ccswitch-run-bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item -LiteralPath $ProdexStatePath -Destination $backup -Force
    $state.profiles | Add-Member -NotePropertyName $ProfileName -NotePropertyValue $profileValue -Force
    $state.last_run_selected_at | Add-Member -NotePropertyName $ProfileName -NotePropertyValue ([DateTimeOffset]::Now.ToUnixTimeSeconds()) -Force
    $state | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $ProdexStatePath -Encoding utf8
    return $backup
}

$providerId = Get-CurrentProviderId
$details = Invoke-CcSwitchProviderQuery -RequestedProviderId $providerId
$safeProviderId = ConvertTo-SafeName -Value ([string]$details.provider.id)
$runStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$runSuffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
$profileName = "ccswitch-run-$runStamp-$($safeProviderId.Substring(0, [Math]::Min(8, $safeProviderId.Length)))-$runSuffix"
$codexHome = Join-Path $RunHomesRoot $profileName

New-Item -ItemType Directory -Path $codexHome -Force | Out-Null
Write-Utf8NoBom -Path (Join-Path $codexHome 'config.toml') -Content ([string]$details.config)
Write-Utf8NoBom -Path (Join-Path $codexHome 'auth.json') -Content ([string]$details.authJson)

$skillsSource = Join-Path $CcSwitchRoot 'skills'
if (-not (Test-Path -LiteralPath $skillsSource)) {
    $skillsSource = Join-Path $UserRoot '.codex\skills'
}
$skillsTarget = Join-Path $codexHome 'skills'
if ((Test-Path -LiteralPath $skillsSource) -and -not (Test-Path -LiteralPath $skillsTarget)) {
    try {
        New-Item -ItemType Junction -Path $skillsTarget -Target $skillsSource -ErrorAction Stop | Out-Null
    } catch {
        New-Item -ItemType Directory -Path $skillsTarget -Force | Out-Null
    }
}

$metadata = [pscustomobject]@{
    profileName = $profileName
    codexHome = $codexHome
    providerId = $details.provider.id
    providerName = $details.provider.name
    baseUrl = $details.provider.baseUrl
    baseHost = $details.provider.baseHost
    endpointHost = $details.provider.endpointHost
    configSha256 = $details.configSha256
    authSha256 = $details.authSha256
    materializedAt = (Get-Date).ToString('o')
}
$metadata | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $codexHome 'run-provider.json') -Encoding utf8
$stateBackup = Register-ProdexProfile -ProfileName $profileName -CodexHome $codexHome

Write-Info ("materialized profile={0} home={1} provider={2} id={3} base_url={4} state_backup={5}" -f `
    $profileName, $codexHome, $details.provider.name, $details.provider.id, $details.provider.baseUrl, $stateBackup)

$metadata | ConvertTo-Json -Depth 8 -Compress
