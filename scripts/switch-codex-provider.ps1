[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Provider,

    [string]$CcSwitchRoot = '',
    [string]$MaterializeScript = (Join-Path $env:USERPROFILE '.prodex\bin\materialize-ccswitch-codex-run.ps1'),
    [string]$SyncScript = (Join-Path $env:USERPROFILE '.prodex\bin\sync-ccswitch-current-codex.ps1'),
    [string]$CurrentHome = (Join-Path $env:USERPROFILE '.prodex\manual-homes\ccswitch-current'),
    [switch]$DryRun,
    [switch]$Json,
    [switch]$NoRollback,
    [switch]$SkipIfConsistent
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$UserRoot = [Environment]::GetFolderPath('UserProfile')
$LegacyCcSwitchRoot = Join-Path $UserRoot '.cc-switch'
$ExplicitCcSwitchRoot = -not [string]::IsNullOrWhiteSpace($CcSwitchRoot)
$DbPath = $null
$SettingsPath = $null
$BackupDir = $null
$ProdexRoot = Join-Path $env:USERPROFILE '.prodex'
$SwitchStatePath = Join-Path $ProdexRoot 'codex-provider-switch-state.json'
$ConfigPath = Join-Path $CurrentHome 'config.toml'

function Get-FullPathIfPossible {
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        return [System.IO.Path]::GetFullPath($Path)
    } catch {
        return $Path
    }
}

function Get-CandidateCcSwitchRoots {
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($ExplicitCcSwitchRoot) {
        $candidates.Add((Get-FullPathIfPossible -Path $CcSwitchRoot)) | Out-Null
    } else {
        $full = Get-FullPathIfPossible -Path $LegacyCcSwitchRoot
        if ($candidates -notcontains $full) {
            $candidates.Add($full) | Out-Null
        }
    }

    return @($candidates.ToArray())
}

function Set-ActiveCcSwitchRoot {
    param([Parameter(Mandatory = $true)][string]$Root)

    $script:CcSwitchRoot = Get-FullPathIfPossible -Path $Root
    $script:DbPath = Join-Path $script:CcSwitchRoot 'cc-switch.db'
    $script:SettingsPath = Join-Path $script:CcSwitchRoot 'settings.json'
    $script:BackupDir = Join-Path $script:CcSwitchRoot 'backups'
}

Set-ActiveCcSwitchRoot -Root ($(if ($ExplicitCcSwitchRoot) { $CcSwitchRoot } else { $LegacyCcSwitchRoot }))

function Write-SwitchInfo {
    param([Parameter(Mandatory = $true)][string]$Message)
    if (-not $Json) {
        Write-Output $Message
    }
}

function Get-TextFileContent {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

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

    $parent = Split-Path -Parent $Path
    if ($parent) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $tempPath = "$Path.tmp-$PID-$([guid]::NewGuid().ToString('N'))"
    try {
        [System.IO.File]::WriteAllText($tempPath, $Content, [System.Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $tempPath -Destination $Path -Force
    } finally {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-ConfigBaseUrl {
    param([AllowNull()][string]$ConfigText)

    if ([string]::IsNullOrWhiteSpace($ConfigText)) {
        return $null
    }

    foreach ($line in $ConfigText -split "`r?`n") {
        if ($line -match '^\s*base_url\s*=\s*["'']([^"'']+)["'']') {
            return $Matches[1]
        }
    }

    return $null
}

function New-UniqueBackupPath {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string]$Leaf
    )

    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    $candidate = Join-Path $Directory $Leaf
    $index = 1
    while (Test-Path -LiteralPath $candidate) {
        $candidate = Join-Path $Directory ("{0}-{1}" -f $Leaf, $index)
        $index++
    }
    return $candidate
}

function Invoke-PythonJson {
    param(
        [Parameter(Mandatory = $true)][string]$PythonCode,
        [AllowEmptyCollection()][string[]]$Arguments = @()
    )

    $pythonCommand = Get-Command python -ErrorAction SilentlyContinue
    if ($null -eq $pythonCommand) {
        throw 'Python is required for cc-switch SQLite access, but python was not found on PATH.'
    }

    $tempPythonPath = Join-Path ([System.IO.Path]::GetTempPath()) "switch-codex-provider-$PID-$([guid]::NewGuid().ToString('N')).py"
    $tempOutputPath = Join-Path ([System.IO.Path]::GetTempPath()) "switch-codex-provider-$PID-$([guid]::NewGuid().ToString('N')).json"
    $previousPythonIoEncoding = $env:PYTHONIOENCODING
    $previousPythonUtf8 = $env:PYTHONUTF8

    try {
        [System.IO.File]::WriteAllText($tempPythonPath, $PythonCode, [System.Text.UTF8Encoding]::new($false))
        $env:PYTHONIOENCODING = 'utf-8'
        $env:PYTHONUTF8 = '1'
        & $pythonCommand.Source $tempPythonPath $tempOutputPath @Arguments
        if ($LASTEXITCODE -ne 0) {
            throw "Python helper failed with exit code $LASTEXITCODE."
        }
        if (-not (Test-Path -LiteralPath $tempOutputPath)) {
            throw 'Python helper did not write JSON output.'
        }
        $json = Get-TextFileContent -Path $tempOutputPath
        if ([string]::IsNullOrWhiteSpace($json)) {
            throw 'Python helper returned empty JSON.'
        }
        return $json | ConvertFrom-Json
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
        Remove-Item -LiteralPath $tempOutputPath -Force -ErrorAction SilentlyContinue
    }
}

$providerPython = @'
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
    if not isinstance(config_text, str):
        return None
    for line in config_text.splitlines():
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
    config_text = settings_config.get("config")
    auth = settings_config.get("auth") if isinstance(settings_config, dict) else {}
    base_url = config_base_url(config_text)
    return {
        "id": row["id"],
        "shortId": row["id"][:8],
        "name": row["name"],
        "isCurrent": bool(row["is_current"]),
        "sortIndex": row["sort_index"],
        "category": row["category"],
        "baseUrl": base_url,
        "baseHost": urlparse(base_url).netloc if base_url else None,
        "configSha16": sha_text(config_text or ""),
        "authSha16": sha_text(auth or {}),
    }

def write_result(value):
    Path(sys.argv[1]).write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")

mode = sys.argv[2]
db_path = Path(sys.argv[3])
provider_arg = sys.argv[4]
backup_path = Path(sys.argv[5]) if len(sys.argv) > 5 and sys.argv[5] else None
previous_provider_id = sys.argv[6] if len(sys.argv) > 6 else ""

result = {"ok": False, "message": ""}
try:
    if not db_path.exists():
        raise RuntimeError(f"Missing cc-switch DB: {db_path}")
    con = sqlite3.connect(db_path)
    con.row_factory = sqlite3.Row
    con.execute("pragma busy_timeout=5000")
    rows = con.execute(
        "select id, name, website_url, category, sort_index, is_current, settings_config "
        "from providers where app_type='codex' order by sort_index is null, sort_index, name"
    ).fetchall()
    providers = [public_provider(row) for row in rows]
    currents = [item for item in providers if item["isCurrent"]]

    if mode == "resolve":
        needle = provider_arg.casefold()
        exact_id = [item for item in providers if item["id"] == provider_arg]
        id_prefix = [item for item in providers if item["id"].casefold().startswith(needle)]
        exact_name = [item for item in providers if item["name"].casefold() == needle]
        name_contains = [item for item in providers if needle in item["name"].casefold()]

        candidates = exact_id or id_prefix or exact_name or name_contains
        deduped = []
        seen = set()
        for item in candidates:
            if item["id"] not in seen:
                deduped.append(item)
                seen.add(item["id"])

        if len(deduped) == 0:
            result = {"ok": False, "message": f"No Codex provider matched: {provider_arg}", "candidates": []}
        elif len(deduped) > 1:
            result = {"ok": False, "message": f"Provider match is ambiguous: {provider_arg}", "candidates": deduped}
        else:
            target = deduped[0]
            row = next(row for row in rows if row["id"] == target["id"])
            settings_config = json.loads(row["settings_config"] or "{}")
            config_text = settings_config.get("config")
            if not isinstance(config_text, str) or not config_text.strip():
                raise RuntimeError(f"Codex provider has no string settings_config.config: {target['id']}")
            auth = settings_config.get("auth") or {}
            if not isinstance(auth, dict):
                raise RuntimeError(f"Codex provider settings_config.auth is not an object: {target['id']}")
            result = {
                "ok": True,
                "provider": target,
                "previousCurrentProviderIds": [item["id"] for item in currents],
                "providers": providers,
            }

    elif mode == "switch":
        target_id = provider_arg
        target = next((item for item in providers if item["id"] == target_id), None)
        if target is None:
            raise RuntimeError(f"Codex provider not found: {target_id}")
        if backup_path is None:
            raise RuntimeError("backup_path is required for switch mode")
        backup_path.parent.mkdir(parents=True, exist_ok=True)
        backup_con = sqlite3.connect(backup_path)
        try:
            con.backup(backup_con)
        finally:
            backup_con.close()

        con.execute("begin immediate")
        con.execute("update providers set is_current=0 where app_type='codex'")
        updated = con.execute(
            "update providers set is_current=1 where app_type='codex' and id=?",
            (target_id,),
        ).rowcount
        if updated != 1:
            con.rollback()
            raise RuntimeError(f"Expected to update one Codex provider, updated {updated}")
        check = con.execute(
            "select id from providers where app_type='codex' and is_current=1"
        ).fetchall()
        if len(check) != 1 or check[0]["id"] != target_id:
            con.rollback()
            raise RuntimeError("Failed to verify providers.is_current after update")
        con.commit()
        result = {"ok": True, "provider": target, "backupPath": str(backup_path), "message": "provider switched"}

    elif mode == "rollback":
        if not previous_provider_id:
            raise RuntimeError("previous_provider_id is required for rollback mode")
        con.execute("begin immediate")
        con.execute("update providers set is_current=0 where app_type='codex'")
        updated = con.execute(
            "update providers set is_current=1 where app_type='codex' and id=?",
            (previous_provider_id,),
        ).rowcount
        if updated != 1:
            con.rollback()
            raise RuntimeError(f"Expected to restore one Codex provider, updated {updated}")
        con.commit()
        result = {"ok": True, "restoredProviderId": previous_provider_id, "message": "provider rolled back"}

    elif mode == "state":
        result = {
            "ok": True,
            "currentProviderIds": [item["id"] for item in currents],
            "currentProvider": currents[0] if len(currents) == 1 else None,
            "providers": providers,
        }

    else:
        raise RuntimeError(f"Unsupported mode: {mode}")

    con.close()
except Exception as exc:
    result = {"ok": False, "message": str(exc)}

write_result(result)
'@

function Resolve-Provider {
    param([Parameter(Mandatory = $true)][string]$ProviderText)

    $resolved = Invoke-PythonJson -PythonCode $providerPython -Arguments @('resolve', $DbPath, $ProviderText, '', '')
    if (-not [bool]$resolved.ok) {
        $message = [string]$resolved.message
        if ($resolved.PSObject.Properties['candidates'] -and @($resolved.candidates).Count -gt 0) {
            $items = @($resolved.candidates | Select-Object -First 12 | ForEach-Object {
                '{0} id={1} base_url={2}' -f $_.name, $_.id, $_.baseUrl
            })
            $message = "$message candidates=[$($items -join '; ')]"
        }
        throw $message
    }
    return $resolved
}

function Get-DbState {
    $state = Invoke-PythonJson -PythonCode $providerPython -Arguments @('state', $DbPath, '', '', '')
    if (-not [bool]$state.ok) {
        throw [string]$state.message
    }
    return $state
}

function Set-DbCurrentProvider {
    param(
        [Parameter(Mandatory = $true)][string]$ProviderId,
        [Parameter(Mandatory = $true)][string]$BackupPath
    )

    $switched = Invoke-PythonJson -PythonCode $providerPython -Arguments @('switch', $DbPath, $ProviderId, $BackupPath, '')
    if (-not [bool]$switched.ok) {
        throw [string]$switched.message
    }
    return $switched
}

function Restore-DbCurrentProvider {
    param([Parameter(Mandatory = $true)][string]$ProviderId)

    $rolledBack = Invoke-PythonJson -PythonCode $providerPython -Arguments @('rollback', $DbPath, '', '', $ProviderId)
    if (-not [bool]$rolledBack.ok) {
        throw [string]$rolledBack.message
    }
    return $rolledBack
}

function Resolve-ProviderForRequest {
    param([Parameter(Mandatory = $true)][string]$ProviderText)

    $attempts = New-Object System.Collections.Generic.List[object]
    foreach ($root in (Get-CandidateCcSwitchRoots)) {
        Set-ActiveCcSwitchRoot -Root $root
        if (-not (Test-Path -LiteralPath $DbPath) -or -not (Test-Path -LiteralPath $SettingsPath)) {
            $attempts.Add([pscustomobject]@{
                ok       = $false
                root     = $CcSwitchRoot
                resolved = $null
                message  = "Missing cc-switch DB or settings under $CcSwitchRoot"
            }) | Out-Null
            continue
        }

        try {
            $resolved = Resolve-Provider -ProviderText $ProviderText
            $attempts.Add([pscustomobject]@{
                ok       = $true
                root     = $CcSwitchRoot
                resolved = $resolved
                message  = ''
            }) | Out-Null
        } catch {
            $attempts.Add([pscustomobject]@{
                ok       = $false
                root     = $CcSwitchRoot
                resolved = $null
                message  = [string]$_
            }) | Out-Null
        }

        if ($ExplicitCcSwitchRoot) {
            break
        }
    }

    $matches = @($attempts.ToArray() | Where-Object { $_.ok })
    if ($matches.Count -eq 0) {
        $details = @($attempts.ToArray() | ForEach-Object { '{0}: {1}' -f $_.root, $_.message })
        throw "No Codex provider matched '$ProviderText' in known CC Switch roots. $($details -join ' | ')"
    }

    $chosen = $matches[0]
    Set-ActiveCcSwitchRoot -Root ([string]$chosen.root)
    return $chosen.resolved
}

function Sync-MirrorRootCurrentProvider {
    param([Parameter(Mandatory = $true)][string]$ProviderId)

    $primaryRoot = $CcSwitchRoot
    $results = New-Object System.Collections.Generic.List[object]
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

    foreach ($root in (Get-CandidateCcSwitchRoots)) {
        $normalized = Get-FullPathIfPossible -Path $root
        if ([string]::Equals($normalized, $primaryRoot, [StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        try {
            Set-ActiveCcSwitchRoot -Root $normalized
            if (-not (Test-Path -LiteralPath $DbPath) -or -not (Test-Path -LiteralPath $SettingsPath)) {
                $results.Add([pscustomobject]@{
                    root    = $CcSwitchRoot
                    status  = 'skipped'
                    message = 'missing DB or settings'
                }) | Out-Null
                continue
            }

            $state = Get-DbState
            $matching = @($state.providers | Where-Object { [string]$_.id -eq $ProviderId })
            if ($matching.Count -ne 1) {
                $results.Add([pscustomobject]@{
                    root    = $CcSwitchRoot
                    status  = 'skipped'
                    message = 'provider id not present'
                }) | Out-Null
                continue
            }

            if (Test-DbSettingsConsistent -ProviderDetails $matching[0]) {
                $results.Add([pscustomobject]@{
                    root    = $CcSwitchRoot
                    status  = 'unchanged'
                    message = 'already selected'
                }) | Out-Null
                continue
            }

            $dbBackupPath = New-UniqueBackupPath -Directory $BackupDir -Leaf "cc-switch.db.bak-mirror-$stamp"
            $settingsBackupPath = New-UniqueBackupPath -Directory $BackupDir -Leaf "settings.json.bak-mirror-$stamp"
            Set-DbCurrentProvider -ProviderId $ProviderId -BackupPath $dbBackupPath | Out-Null
            Set-SettingsCurrentProvider -ProviderId $ProviderId -BackupPath $settingsBackupPath
            $results.Add([pscustomobject]@{
                root               = $CcSwitchRoot
                status             = 'updated'
                message            = 'mirrored current provider'
                dbBackupPath       = $dbBackupPath
                settingsBackupPath = $settingsBackupPath
            }) | Out-Null
        } catch {
            $results.Add([pscustomobject]@{
                root    = $CcSwitchRoot
                status  = 'failed'
                message = [string]$_
            }) | Out-Null
        }
    }

    Set-ActiveCcSwitchRoot -Root $primaryRoot
    return @($results.ToArray())
}

function Get-SettingsCurrentProvider {
    if (-not (Test-Path -LiteralPath $SettingsPath)) {
        throw "Missing cc-switch settings: $SettingsPath"
    }
    $settings = Get-TextFileContent -Path $SettingsPath | ConvertFrom-Json
    if (-not $settings.PSObject.Properties['currentProviderCodex']) {
        return $null
    }
    return [string]$settings.currentProviderCodex
}

function Set-SettingsCurrentProvider {
    param(
        [Parameter(Mandatory = $true)][string]$ProviderId,
        [Parameter(Mandatory = $true)][string]$BackupPath
    )

    if (-not (Test-Path -LiteralPath $SettingsPath)) {
        throw "Missing cc-switch settings: $SettingsPath"
    }

    Copy-Item -LiteralPath $SettingsPath -Destination $BackupPath -Force
    $settings = Get-TextFileContent -Path $SettingsPath | ConvertFrom-Json
    if (-not $settings.PSObject.Properties['currentProviderCodex']) {
        $settings | Add-Member -NotePropertyName 'currentProviderCodex' -NotePropertyValue $ProviderId
    } else {
        $settings.currentProviderCodex = $ProviderId
    }
    $jsonText = $settings | ConvertTo-Json -Depth 30
    Write-Utf8NoBom -Path $SettingsPath -Content ($jsonText + "`n")
}

function Test-DbSettingsConsistent {
    param([Parameter(Mandatory = $true)]$ProviderDetails)

    $dbState = Get-DbState
    $currentIds = @($dbState.currentProviderIds | ForEach-Object { [string]$_ })
    if ($currentIds.Count -ne 1 -or $currentIds[0] -ne [string]$ProviderDetails.id) {
        return $false
    }

    $settingsId = Get-SettingsCurrentProvider
    return ($settingsId -eq [string]$ProviderDetails.id)
}

function Test-ProviderConsistent {
    param([Parameter(Mandatory = $true)]$ProviderDetails)

    if (-not (Test-DbSettingsConsistent -ProviderDetails $ProviderDetails)) {
        return $false
    }

    $currentBaseUrl = Get-ConfigBaseUrl -ConfigText (Get-TextFileContent -Path $ConfigPath)
    if ($currentBaseUrl -ne [string]$ProviderDetails.baseUrl) {
        return $false
    }

    return $true
}

function Invoke-Materialize {
    if (-not (Test-Path -LiteralPath $MaterializeScript)) {
        throw "Missing materialize script: $MaterializeScript"
    }
    $output = @(& $MaterializeScript -CcSwitchRoot $CcSwitchRoot -Quiet 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0) {
        throw "materialize failed with exit code $LASTEXITCODE`: $($output -join ' | ')"
    }
    $lastLine = @($output | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 1)
    if ($lastLine.Count -eq 0) {
        throw 'materialize returned no JSON metadata.'
    }
    try {
        return [pscustomobject]@{
            Metadata = ($lastLine[0] | ConvertFrom-Json)
            Output = @($output)
        }
    } catch {
        throw "materialize returned non-JSON metadata: $($lastLine[0])"
    }
}

function Invoke-CurrentSync {
    if (-not (Test-Path -LiteralPath $SyncScript)) {
        throw "Missing sync script: $SyncScript"
    }
    $output = @(& $SyncScript -CcSwitchRoot $CcSwitchRoot -CodexHome $CurrentHome -Quiet 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0) {
        throw "sync failed with exit code $LASTEXITCODE`: $($output -join ' | ')"
    }
    return @($output)
}

function Write-SwitchState {
    param(
        [Parameter(Mandatory = $true)]$ProviderDetails,
        [AllowNull()]$Materialized,
        [AllowNull()][string]$DbBackupPath,
        [AllowNull()][string]$SettingsBackupPath
    )

    $state = [pscustomobject]@{
        processedProviderId = $ProviderDetails.id
        providerName = $ProviderDetails.name
        baseUrl = $ProviderDetails.baseUrl
        baseHost = $ProviderDetails.baseHost
        ccSwitchRoot = $CcSwitchRoot
        dbPath = $DbPath
        settingsPath = $SettingsPath
        dbBackupPath = $DbBackupPath
        settingsBackupPath = $SettingsBackupPath
        materializedProfile = if ($null -ne $Materialized) { $Materialized.profileName } else { $null }
        materializedHome = if ($null -ne $Materialized) { $Materialized.codexHome } else { $null }
        switchedAt = (Get-Date).ToString('o')
    }
    Write-Utf8NoBom -Path $SwitchStatePath -Content (($state | ConvertTo-Json -Depth 8) + "`n")
}

$mutexName = 'Global\switch-codex-provider'
$createdNew = $false
$mutex = [System.Threading.Mutex]::new($false, $mutexName, [ref]$createdNew)
$hasMutex = $false

$result = [ordered]@{
    ok = $false
    dryRun = [bool]$DryRun
    skipped = $false
    provider = $null
    ccSwitchRoot = $null
    dbPath = $null
    settingsPath = $null
    previousCurrentProviderIds = @()
    previousSettingsProviderId = $null
    dbBackupPath = $null
    settingsBackupPath = $null
    mirrors = @()
    materializedProfile = $null
    materializedHome = $null
    baseUrl = $null
    syncOutput = @()
    rollback = $null
    message = ''
}

try {
    $hasMutex = $mutex.WaitOne([TimeSpan]::FromSeconds(90))
    if (-not $hasMutex) {
        throw 'Timed out waiting for another switch-codex-provider run to finish.'
    }

    $resolved = Resolve-ProviderForRequest -ProviderText $Provider
    $target = $resolved.provider
    $result.provider = $target
    $result.ccSwitchRoot = $CcSwitchRoot
    $result.dbPath = $DbPath
    $result.settingsPath = $SettingsPath
    $result.previousCurrentProviderIds = @($resolved.previousCurrentProviderIds | ForEach-Object { [string]$_ })
    $result.previousSettingsProviderId = Get-SettingsCurrentProvider
    $result.baseUrl = [string]$target.baseUrl

    $selectionAlreadyConsistent = Test-DbSettingsConsistent -ProviderDetails $target
    $dbBackupPath = $null
    $settingsBackupPath = $null

    if ($DryRun) {
        $result.ok = $true
        $result.message = 'dry-run ok'
        Write-SwitchInfo ("dry-run provider={0} id={1} base_url={2} root={3}" -f $target.name, $target.id, $target.baseUrl, $CcSwitchRoot)
        return
    }

    if ($SkipIfConsistent -and $selectionAlreadyConsistent) {
        $result.skipped = $true
        Write-SwitchInfo ("selection already consistent provider={0} id={1} root={2}; refreshing materialize/sync" -f $target.name, $target.id, $CcSwitchRoot)
    } else {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $dbBackupPath = New-UniqueBackupPath -Directory $BackupDir -Leaf "cc-switch.db.bak-switch-$stamp"
        $settingsBackupPath = New-UniqueBackupPath -Directory $BackupDir -Leaf "settings.json.bak-switch-$stamp"
        $result.dbBackupPath = $dbBackupPath
        $result.settingsBackupPath = $settingsBackupPath

        Set-DbCurrentProvider -ProviderId ([string]$target.id) -BackupPath $dbBackupPath | Out-Null
        Set-SettingsCurrentProvider -ProviderId ([string]$target.id) -BackupPath $settingsBackupPath
        Write-SwitchInfo ("selected provider={0} id={1} root={2}" -f $target.name, $target.id, $CcSwitchRoot)
    }

    $result.mirrors = @(Sync-MirrorRootCurrentProvider -ProviderId ([string]$target.id))

    $materialize = Invoke-Materialize
    $result.materializedProfile = [string]$materialize.Metadata.profileName
    $result.materializedHome = [string]$materialize.Metadata.codexHome

    $syncOutput = @(Invoke-CurrentSync)
    $result.syncOutput = @($syncOutput)

    if (-not (Test-ProviderConsistent -ProviderDetails $target)) {
        throw 'Post-switch verification failed: DB, settings.json, or ccswitch-current base_url is inconsistent.'
    }

    Write-SwitchState -ProviderDetails $target -Materialized $materialize.Metadata -DbBackupPath $dbBackupPath -SettingsBackupPath $settingsBackupPath
    $result.ok = $true
    $result.message = 'provider switched'

    Write-SwitchInfo ("materialized profile={0} home={1}" -f $result.materializedProfile, $result.materializedHome)
    Write-SwitchInfo ("ccswitch-current base_url={0}" -f $target.baseUrl)
    Write-SwitchInfo ("ok provider={0} id={1} base_url={2} root={3}" -f $target.name, $target.id, $target.baseUrl, $CcSwitchRoot)
} catch {
    $errorMessage = [string]$_
    $result.message = $errorMessage

    $shouldRollback = (-not $DryRun) -and (-not $NoRollback) -and ($null -ne $result.provider) -and
        (-not [string]::IsNullOrWhiteSpace([string]$result.previousSettingsProviderId))

    if ($shouldRollback) {
        $rollbackInfo = [ordered]@{
            attempted = $true
            ok = $false
            providerId = [string]$result.previousSettingsProviderId
            message = ''
        }
        try {
            Restore-DbCurrentProvider -ProviderId ([string]$result.previousSettingsProviderId) | Out-Null
            if ($result.settingsBackupPath -and (Test-Path -LiteralPath $result.settingsBackupPath)) {
                Copy-Item -LiteralPath $result.settingsBackupPath -Destination $SettingsPath -Force
            } else {
                Set-SettingsCurrentProvider -ProviderId ([string]$result.previousSettingsProviderId) -BackupPath (New-UniqueBackupPath -Directory $BackupDir -Leaf "settings.json.bak-rollback-$(Get-Date -Format 'yyyyMMdd-HHmmss')") | Out-Null
            }
            try {
                Invoke-CurrentSync | Out-Null
            } catch {
                $rollbackInfo.message = "provider restored, but current-home sync failed: $_"
            }
            if ([string]::IsNullOrWhiteSpace([string]$rollbackInfo.message)) {
                $rollbackInfo.message = 'provider restored'
            }
            $rollbackInfo.ok = $true
        } catch {
            $rollbackInfo.message = [string]$_
        }
        $result.rollback = [pscustomobject]$rollbackInfo
    }

    if ($Json) {
        $result | ConvertTo-Json -Depth 12
    }
    throw $errorMessage
} finally {
    if ($Json -and [bool]$result.ok) {
        $result | ConvertTo-Json -Depth 12
    }
    if ($hasMutex) {
        $mutex.ReleaseMutex()
    }
    $mutex.Dispose()
}
