[CmdletBinding()]
param(
    [switch]$Quiet,
    [string]$CcSwitchRoot = "",
    # Test/diagnostic override for the provider database; never changes CC Switch state.
    [string]$SourceDb = "",
    [string]$ProdexScript = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$UserRoot = if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
    [Environment]::GetFolderPath('UserProfile')
} else {
    [System.IO.Path]::GetFullPath($env:USERPROFILE)
}
if ([string]::IsNullOrWhiteSpace($UserRoot)) {
    throw 'Unable to resolve the user profile directory.'
}

if ([string]::IsNullOrWhiteSpace($CcSwitchRoot)) {
    $CcSwitchRoot = Join-Path $UserRoot '.cc-switch'
} else {
    $CcSwitchRoot = [System.IO.Path]::GetFullPath($CcSwitchRoot)
}
$ProdexRoot = if ([string]::IsNullOrWhiteSpace($env:PRODEX_HOME)) {
    Join-Path $UserRoot '.prodex'
} else {
    [System.IO.Path]::GetFullPath($env:PRODEX_HOME)
}
$GlobalCodexRoot = Join-Path $UserRoot '.codex'
$SettingsPath = Join-Path $CcSwitchRoot 'settings.json'
$DbPath = Join-Path $CcSwitchRoot 'cc-switch.db'
if (-not [string]::IsNullOrWhiteSpace($SourceDb)) {
    if (-not $Quiet) { Write-Output "[materialize] SourceDb override: $SourceDb" }
    $DbPath = [System.IO.Path]::GetFullPath($SourceDb)
}
if ([string]::IsNullOrWhiteSpace($ProdexScript)) {
    $ProdexScript = Join-Path $env:APPDATA 'npm\prodex.ps1'
} else {
    $ProdexScript = [System.IO.Path]::GetFullPath($ProdexScript)
}
$RunHomesRoot = Join-Path $ProdexRoot 'manual-homes\ccswitch-runs'
$CurrentHome = Join-Path $ProdexRoot 'manual-homes\ccswitch-current'
$CurrentSkillsRoot = Join-Path $CurrentHome 'skills'
$GlobalSkillsRoot = Join-Path $GlobalCodexRoot 'skills'

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
    if (-not (Test-Path -LiteralPath $SettingsPath)) {
        throw "Missing cc-switch settings: $SettingsPath"
    }
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

function Invoke-CcSwitchCurrentProviderQuery {
    if (-not (Test-Path -LiteralPath $DbPath)) { throw "Missing cc-switch DB: $DbPath" }
    $python = (Get-Command python -ErrorAction Stop).Source
    $pythonCode = @'
import hashlib
import json
import sqlite3
import sys
from pathlib import Path
from urllib.parse import urlparse

try:
    import tomllib
except ImportError:
    tomllib = None

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

db_path = sys.argv[1]
con = None
try:
    uri = Path(db_path).resolve().as_uri() + "?mode=ro"
    con = sqlite3.connect(uri, uri=True, timeout=0.25, isolation_level=None)
    con.row_factory = sqlite3.Row
    con.execute("pragma query_only=on")
    con.execute("pragma busy_timeout=250")
    con.execute("begin")
    cur = con.cursor()

    rows = cur.execute(
        "select id, name, website_url, category, sort_index, is_current, settings_config "
        "from providers where app_type='codex' and is_current=1"
    ).fetchall()
    if len(rows) != 1:
        raise RuntimeError(f"Expected exactly one current Codex provider; found {len(rows)}.")
    row = rows[0]
    provider_id = row["id"]

    try:
        settings_config = json.loads(row["settings_config"] or "{}")
    except Exception as exc:
        raise RuntimeError("Current Codex provider settings_config is not valid JSON.") from exc

    config_text = settings_config.get("config")
    if not isinstance(config_text, str) or not config_text.strip():
        raise RuntimeError("Current Codex provider has no string settings_config.config.")

    auth = settings_config.get("auth") or {}
    if not isinstance(auth, dict):
        raise RuntimeError("Current Codex provider settings_config.auth is not an object.")

    if tomllib is None:
        raise RuntimeError("Python 3.11 or newer is required to validate Codex TOML.")
    try:
        parsed_config = tomllib.loads(config_text)
    except Exception as exc:
        raise RuntimeError("Current Codex provider config is not valid TOML.") from exc

    model = parsed_config.get("model")
    effort = parsed_config.get("model_reasoning_effort")
    if model is not None and (not isinstance(model, str) or not model.strip()):
        raise RuntimeError("Current Codex provider config has an invalid top-level model.")
    if effort is not None and (not isinstance(effort, str) or not effort.strip()):
        raise RuntimeError(
            "Current Codex provider config has an invalid top-level model_reasoning_effort."
        )

    base_url = config_base_url(config_text)
    endpoints = cur.execute(
        "select url from provider_endpoints where app_type='codex' and provider_id=? order by id",
        (provider_id,),
    ).fetchall()
    first_url = endpoints[0]["url"] if endpoints else None

    result = {
        "ok": True,
        "provider": {
            "id": provider_id,
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
        "model": model,
        "modelReasoningEffort": effort,
    }
except Exception as exc:
    result = {"ok": False, "message": str(exc)}
finally:
    if con is not None:
        try:
            con.rollback()
        except sqlite3.Error:
            pass
        con.close()

print(json.dumps(result, ensure_ascii=True))
'@

    $tempPythonPath = Join-Path ([System.IO.Path]::GetTempPath()) "ccswitch-codex-provider-$PID-$([guid]::NewGuid().ToString('N')).py"
    try {
        Write-Utf8NoBom -Path $tempPythonPath -Content $pythonCode
        $output = & $python $tempPythonPath $DbPath
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

function Get-StableCcSwitchSnapshot {
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $delayMilliseconds = 50
    $lastProblem = 'No snapshot attempt completed.'

    do {
        try {
            $settingsProviderBefore = Get-CurrentProviderId
            $details = Invoke-CcSwitchCurrentProviderQuery
            $settingsProviderAfter = Get-CurrentProviderId
            $databaseProvider = [string]$details.provider.id

            if (($settingsProviderBefore -eq $databaseProvider) -and
                ($databaseProvider -eq $settingsProviderAfter)) {
                return $details
            }

            $lastProblem = "Provider selection was not stable (settings-before=$settingsProviderBefore, database=$databaseProvider, settings-after=$settingsProviderAfter)."
        } catch {
            $lastProblem = $_.Exception.Message
        }

        $remainingMilliseconds = 3000 - [int]$stopwatch.ElapsedMilliseconds
        if ($remainingMilliseconds -le 0) { break }
        Start-Sleep -Milliseconds ([Math]::Min($delayMilliseconds, $remainingMilliseconds))
        $delayMilliseconds = [Math]::Min(500, $delayMilliseconds * 2)
    } while ($stopwatch.ElapsedMilliseconds -lt 3000)

    throw "Unable to capture a stable cc-switch Codex provider snapshot within 3 seconds. Last error: $lastProblem"
}

function Invoke-ProdexProfileRegistration {
    param(
        [Parameter(Mandatory = $true)][string]$ProfileName,
        [Parameter(Mandatory = $true)][string]$CodexHome
    )

    if (-not (Test-Path -LiteralPath $ProdexScript -PathType Leaf)) {
        throw "Missing Prodex launcher: $ProdexScript"
    }

    $powerShellExecutable = if ($PSVersionTable.PSEdition -eq 'Core') {
        Join-Path $PSHOME 'pwsh.exe'
    } else {
        Join-Path $PSHOME 'powershell.exe'
    }
    $registration = Start-Process -FilePath $powerShellExecutable `
        -ArgumentList @(
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', $ProdexScript, 'profile', 'add', $ProfileName,
            '--codex-home', $CodexHome
        ) `
        -WindowStyle Hidden -Wait -PassThru
    if ($registration.ExitCode -ne 0) {
        throw "Prodex profile registration failed with exit code $($registration.ExitCode)."
    }
}

function Register-ProdexProfile {
    param(
        [Parameter(Mandatory = $true)][string]$ProfileName,
        [Parameter(Mandatory = $true)][string]$CodexHome,
        [Parameter(Mandatory = $true)][string]$RunProdexHome
    )

    $previousProdexHome = [Environment]::GetEnvironmentVariable('PRODEX_HOME', 'Process')
    try {
        $env:PRODEX_HOME = $RunProdexHome
        Invoke-ProdexProfileRegistration -ProfileName $ProfileName -CodexHome $CodexHome
    } finally {
        if ($null -eq $previousProdexHome) {
            Remove-Item Env:\PRODEX_HOME -ErrorAction SilentlyContinue
        } else {
            $env:PRODEX_HOME = $previousProdexHome
        }
    }
}

function Add-SkillEntry {
    param(
        [Parameter(Mandatory = $true)][string]$TargetRoot,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$SourceRoot
    )

    $source = Join-Path $SourceRoot $Name
    if (-not (Test-Path -LiteralPath $source)) {
        Write-Info "skill source missing, skipped: $source"
        return
    }

    New-Item -ItemType Directory -Path $TargetRoot -Force | Out-Null
    $target = Join-Path $TargetRoot $Name
    if (Test-Path -LiteralPath $target) {
        return
    }

    try {
        New-Item -ItemType Junction -Path $target -Target $source -ErrorAction Stop | Out-Null
    } catch {
        Copy-Item -LiteralPath $source -Destination $target -Recurse -Force
    }
}

function Initialize-CodexHomeRulesAndSkills {
    param([Parameter(Mandatory = $true)][string]$CodexHomePath)

    $agentsSource = Join-Path $CurrentHome 'AGENTS.md'
    if (-not (Test-Path -LiteralPath $agentsSource)) { throw "Missing current AGENTS.md: $agentsSource" }
    Copy-Item -LiteralPath $agentsSource -Destination (Join-Path $CodexHomePath 'AGENTS.md') -Force

    $skillsTarget = Join-Path $CodexHomePath 'skills'
    New-Item -ItemType Directory -Path $skillsTarget -Force | Out-Null

    foreach ($skill in @('.system', 'documents', 'presentations', 'spreadsheets')) {
        if (Test-Path -LiteralPath (Join-Path $CurrentSkillsRoot $skill)) {
            Add-SkillEntry -TargetRoot $skillsTarget -Name $skill -SourceRoot $CurrentSkillsRoot
        } else {
            Add-SkillEntry -TargetRoot $skillsTarget -Name $skill -SourceRoot $GlobalSkillsRoot
        }
    }

    foreach ($skill in @('accuracy-gate', 'prompt-sensei', 'clean-code-guard', 'docs-guard', 'test-guard', 'pict-test-designer')) {
        Add-SkillEntry -TargetRoot $skillsTarget -Name $skill -SourceRoot $GlobalSkillsRoot
    }
}

function Get-VerifiedRunChildPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedName
    )

    $runRoot = [System.IO.Path]::GetFullPath($RunHomesRoot).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $parent = [System.IO.Directory]::GetParent($fullPath)
    if (($null -eq $parent) -or
        (-not [string]::Equals($parent.FullName.TrimEnd('\', '/'), $runRoot, [System.StringComparison]::OrdinalIgnoreCase)) -or
        (-not [string]::Equals([System.IO.Path]::GetFileName($fullPath), $ExpectedName, [System.StringComparison]::Ordinal))) {
        throw "Refusing to operate on a path outside the owned run root: $fullPath"
    }
    return $fullPath
}

function Remove-OwnedRunDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedName
    )

    $verifiedPath = Get-VerifiedRunChildPath -Path $Path -ExpectedName $ExpectedName
    if (Test-Path -LiteralPath $verifiedPath) {
        if (-not (Test-Path -LiteralPath $verifiedPath -PathType Container)) {
            throw "Refusing to recursively remove a non-directory run path: $verifiedPath"
        }
        Remove-Item -LiteralPath $verifiedPath -Recurse -Force
    }
}

function Test-StagedCodexHome {
    param(
        [Parameter(Mandatory = $true)][string]$StagingHome,
        [Parameter(Mandatory = $true)][string]$FinalHome,
        [Parameter(Mandatory = $true)][string]$ProviderId,
        [Parameter(Mandatory = $true)][string]$ConfigSha256,
        [Parameter(Mandatory = $true)][string]$AuthSha256
    )

    $python = (Get-Command python -ErrorAction Stop).Source
    $pythonCode = @'
import hashlib
import json
import sys
import tomllib
from pathlib import Path

def sha_text(value):
    if value is None:
        value = ""
    if not isinstance(value, str):
        value = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(value.encode("utf-8")).hexdigest()[:16]

root = Path(sys.argv[1])
final_home = Path(sys.argv[2])
provider_id = sys.argv[3]
expected_config_hash = sys.argv[4]
expected_auth_hash = sys.argv[5]

try:
    config_text = (root / "config.toml").read_text(encoding="utf-8")
    parsed_config = tomllib.loads(config_text)
    auth = json.loads((root / "auth.json").read_text(encoding="utf-8"))
    metadata = json.loads((root / "run-provider.json").read_text(encoding="utf-8"))

    if not isinstance(auth, dict):
        raise RuntimeError("auth.json must contain a JSON object.")
    if metadata.get("schemaVersion") != 2:
        raise RuntimeError("run-provider.json schemaVersion must be 2.")
    if metadata.get("providerId") != provider_id:
        raise RuntimeError("run-provider.json providerId does not match the DB snapshot.")
    if Path(metadata.get("codexHome", "")).resolve() != final_home.resolve():
        raise RuntimeError("run-provider.json codexHome does not match the final run home.")
    if Path(metadata.get("prodexHome", "")).resolve() != (final_home / ".prodex-runtime").resolve():
        raise RuntimeError("run-provider.json prodexHome does not match the private Prodex home.")
    if sha_text(config_text) != expected_config_hash or metadata.get("configSha256") != expected_config_hash:
        raise RuntimeError("config.toml hash validation failed.")
    if sha_text(auth) != expected_auth_hash or metadata.get("authSha256") != expected_auth_hash:
        raise RuntimeError("auth.json hash validation failed.")
    if metadata.get("model") != parsed_config.get("model"):
        raise RuntimeError("run-provider.json model does not match config.toml.")
    if metadata.get("modelReasoningEffort") != parsed_config.get("model_reasoning_effort"):
        raise RuntimeError("run-provider.json modelReasoningEffort does not match config.toml.")
    if not (root / "AGENTS.md").is_file() or not (root / "skills").is_dir():
        raise RuntimeError("The staged Codex home is missing AGENTS.md or skills.")
except Exception as exc:
    print(json.dumps({"ok": False, "message": str(exc)}, ensure_ascii=True))
else:
    print(json.dumps({"ok": True}, ensure_ascii=True))
'@

    $tempPythonPath = Join-Path ([System.IO.Path]::GetTempPath()) "ccswitch-codex-validate-$PID-$([guid]::NewGuid().ToString('N')).py"
    try {
        Write-Utf8NoBom -Path $tempPythonPath -Content $pythonCode
        $output = & $python $tempPythonPath $StagingHome $FinalHome $ProviderId $ConfigSha256 $AuthSha256
        if ($LASTEXITCODE -ne 0) { throw "Staged Codex home validation failed with exit code $LASTEXITCODE." }
        $json = ($output | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($json)) { throw 'Staged Codex home validation returned no data.' }
        $result = $json | ConvertFrom-Json
        if (-not [bool]$result.ok) { throw [string]$result.message }
    } finally {
        Remove-Item -LiteralPath $tempPythonPath -Force -ErrorAction SilentlyContinue
    }
}

$details = Get-StableCcSwitchSnapshot
$safeProviderId = ConvertTo-SafeName -Value ([string]$details.provider.id)
$runStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$runSuffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
$profileName = "ccswitch-run-$runStamp-$($safeProviderId.Substring(0, [Math]::Min(8, $safeProviderId.Length)))-$runSuffix"
$codexHome = Join-Path $RunHomesRoot $profileName
$runProdexHome = Join-Path $codexHome '.prodex-runtime'
$stagingName = ".ccswitch-staging-$profileName-$([guid]::NewGuid().ToString('N'))"
$stagingHome = Join-Path $RunHomesRoot $stagingName

$metadata = [pscustomobject]@{
    schemaVersion = 2
    profileName = $profileName
    codexHome = $codexHome
    prodexHome = $runProdexHome
    providerId = $details.provider.id
    providerName = $details.provider.name
    baseUrl = $details.provider.baseUrl
    baseHost = $details.provider.baseHost
    endpointHost = $details.provider.endpointHost
    configSha256 = $details.configSha256
    authSha256 = $details.authSha256
    model = $details.model
    modelReasoningEffort = $details.modelReasoningEffort
    materializedAt = (Get-Date).ToString('o')
}

New-Item -ItemType Directory -Path $RunHomesRoot -Force | Out-Null
$published = $false
$registered = $false
try {
    New-Item -ItemType Directory -Path $stagingHome -ErrorAction Stop | Out-Null
    Write-Utf8NoBom -Path (Join-Path $stagingHome 'config.toml') -Content ([string]$details.config)
    Write-Utf8NoBom -Path (Join-Path $stagingHome 'auth.json') -Content ([string]$details.authJson)
    Initialize-CodexHomeRulesAndSkills -CodexHomePath $stagingHome
    Write-Utf8NoBom -Path (Join-Path $stagingHome 'run-provider.json') -Content (($metadata | ConvertTo-Json -Depth 8) + "`n")
    Test-StagedCodexHome `
        -StagingHome $stagingHome `
        -FinalHome $codexHome `
        -ProviderId ([string]$details.provider.id) `
        -ConfigSha256 ([string]$details.configSha256) `
        -AuthSha256 ([string]$details.authSha256)

    $verifiedStagingHome = Get-VerifiedRunChildPath -Path $stagingHome -ExpectedName $stagingName
    $verifiedCodexHome = Get-VerifiedRunChildPath -Path $codexHome -ExpectedName $profileName
    if (Test-Path -LiteralPath $verifiedCodexHome) { throw "Final run home already exists: $verifiedCodexHome" }
    [System.IO.Directory]::Move($verifiedStagingHome, $verifiedCodexHome)
    $published = $true

    Register-ProdexProfile `
        -ProfileName $profileName `
        -CodexHome $codexHome `
        -RunProdexHome $runProdexHome
    $registered = $true
} catch {
    if (-not $published) {
        Remove-OwnedRunDirectory -Path $stagingHome -ExpectedName $stagingName
    } elseif (-not $registered) {
        Remove-OwnedRunDirectory -Path $codexHome -ExpectedName $profileName
    }
    throw
}

Write-Info ("materialized profile={0} home={1} provider={2} id={3} base_url={4}" -f `
    $profileName, $codexHome, $details.provider.name, $details.provider.id, $details.provider.baseUrl)

$metadata | ConvertTo-Json -Depth 8 -Compress
