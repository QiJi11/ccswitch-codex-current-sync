[CmdletBinding()]
param(
    [switch]$Quiet,
    [string]$CcSwitchRoot = "",
    # Test/diagnostic override for the provider database; never changes CC Switch state.
    [string]$SourceDb = "",
    [string]$ProdexScript = "",
    [ValidateSet('direct', 'prodex')]
    [string]$LaunchMode = 'prodex'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'resolve-ccswitch-root.ps1')

$UserRoot = if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
    [Environment]::GetFolderPath('UserProfile')
} else {
    [System.IO.Path]::GetFullPath($env:USERPROFILE)
}
if ([string]::IsNullOrWhiteSpace($UserRoot)) {
    throw 'Unable to resolve the user profile directory.'
}

$CcSwitchRoot = Resolve-CcSwitchRoot -ExplicitRoot $CcSwitchRoot -UserRoot $UserRoot -AppDataRoot $env:APPDATA
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
$CurrentAgentsRoot = Join-Path $CurrentHome 'agents'
$CurrentSkillsRoot = Join-Path $CurrentHome 'skills'
$GlobalSkillsRoot = Join-Path $GlobalCodexRoot 'skills'
$GlobalConfigPath = Join-Path $GlobalCodexRoot 'config.toml'
$GlobalHooksPath = Join-Path $GlobalCodexRoot 'hooks.json'

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
    param(
        [Parameter(Mandatory = $true)][string]$CodexHomePath,
        [Parameter(Mandatory = $true)][byte[]]$HooksConfigBytes
    )

    $agentsSource = Join-Path $CurrentHome 'AGENTS.md'
    if (-not (Test-Path -LiteralPath $agentsSource)) { throw "Missing current AGENTS.md: $agentsSource" }
    Copy-Item -LiteralPath $agentsSource -Destination (Join-Path $CodexHomePath 'AGENTS.md') -Force

    [IO.File]::WriteAllBytes((Join-Path $CodexHomePath 'hooks.json'), $HooksConfigBytes)

    $reviewerAgentsTarget = Join-Path $CodexHomePath 'agents'
    New-Item -ItemType Directory -Path $reviewerAgentsTarget -Force | Out-Null
    foreach ($reviewerAgent in @('skeptic-reviewer.toml', 'verifier.toml')) {
        $reviewerAgentSource = Join-Path $CurrentAgentsRoot $reviewerAgent
        if (-not (Test-Path -LiteralPath $reviewerAgentSource -PathType Leaf)) {
            throw "Missing current reviewer agent: $reviewerAgentSource"
        }
        Copy-Item -LiteralPath $reviewerAgentSource -Destination (Join-Path $reviewerAgentsTarget $reviewerAgent) -Force
    }

    $skillsTarget = Join-Path $CodexHomePath 'skills'
    New-Item -ItemType Directory -Path $skillsTarget -Force | Out-Null

    foreach ($skill in @('.system', 'documents', 'presentations', 'spreadsheets')) {
        if (Test-Path -LiteralPath (Join-Path $CurrentSkillsRoot $skill)) {
            Add-SkillEntry -TargetRoot $skillsTarget -Name $skill -SourceRoot $CurrentSkillsRoot
        } else {
            Add-SkillEntry -TargetRoot $skillsTarget -Name $skill -SourceRoot $GlobalSkillsRoot
        }
    }

    foreach ($skill in @('accuracy-gate', 'antigravity-collaborator', 'prompt-sensei', 'clean-code-guard', 'docs-guard', 'test-guard', 'pict-test-designer', 'multi-agent-review')) {
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
import re
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
    hooks_document = json.loads((root / "hooks.json").read_text(encoding="utf-8"))

    if not isinstance(auth, dict):
        raise RuntimeError("auth.json must contain a JSON object.")
    if metadata.get("schemaVersion") != 2:
        raise RuntimeError("run-provider.json schemaVersion must be 2.")
    if metadata.get("launchMode") not in ("direct", "prodex"):
        raise RuntimeError("run-provider.json launchMode must be direct or prodex.")
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
    configured_mcp_names = sorted(parsed_config.get("mcp_servers", {}).keys())
    if metadata.get("mcpServerNames") != configured_mcp_names:
        raise RuntimeError("run-provider.json mcpServerNames does not match config.toml.")
    event_key_map = {
        "SessionStart": "session_start",
        "UserPromptSubmit": "user_prompt_submit",
        "Stop": "stop",
        "PreCompact": "pre_compact",
    }
    hook_states = parsed_config.get("hooks", {}).get("state", {})
    expected_hook_trust = metadata.get("hookTrustByKey")
    if not isinstance(expected_hook_trust, dict):
        raise RuntimeError("run-provider.json hookTrustByKey must be an object.")
    for event_name, matcher_groups in hooks_document.get("hooks", {}).items():
        if event_name not in event_key_map:
            continue
        for group_index, matcher_group in enumerate(matcher_groups):
            for hook_index, hook in enumerate(matcher_group.get("hooks", [])):
                if hook.get("type") != "command":
                    continue
                hook_key = f"{event_key_map[event_name]}:{group_index}:{hook_index}"
                state_key = f"{(final_home / 'hooks.json').resolve()}:{hook_key}"
                trusted_hash = hook_states.get(state_key, {}).get("trusted_hash")
                if trusted_hash != expected_hook_trust.get(hook_key):
                    raise RuntimeError(f"Run-local hook trust does not match its global source for {hook_key}.")
                if not re.fullmatch(r"sha256:[0-9A-Fa-f]{64}", trusted_hash):
                    raise RuntimeError(f"Invalid run-local hook trust for {hook_key}.")
    if not (root / "AGENTS.md").is_file() or not (root / "hooks.json").is_file() or not (root / "skills").is_dir():
        raise RuntimeError("The staged Codex home is missing AGENTS.md or skills.")
    if not (root / "skills" / "multi-agent-review" / "SKILL.md").is_file():
        raise RuntimeError("The staged Codex home is missing multi-agent-review.")
    for reviewer_name in ("skeptic-reviewer", "verifier"):
        reviewer_path = root / "agents" / f"{reviewer_name}.toml"
        reviewer_config = tomllib.loads(reviewer_path.read_text(encoding="utf-8"))
        if reviewer_config.get("sandbox_mode") != "read-only":
            raise RuntimeError(f"{reviewer_name} must request a read-only sandbox.")
        if reviewer_config.get("model_reasoning_effort") != "high":
            raise RuntimeError(f"{reviewer_name} must use high reasoning effort.")
        reviewer_instructions = reviewer_config.get("developer_instructions", "")
        if "read-only sandbox setting as a request" not in reviewer_instructions:
            raise RuntimeError(f"{reviewer_name} must document that the runtime may not enforce the sandbox request.")
        required_reviewer_prohibitions = (
            "Do not edit files or change external state.",
            "Do not commit, create or switch branches, modify refs, add labels/comments, or send external messages.",
            "Do not spawn subagents.",
        )
        if any(fragment not in reviewer_instructions for fragment in required_reviewer_prohibitions):
            raise RuntimeError(f"{reviewer_name} must include the complete no-write reviewer contract.")
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

function Get-ShortSha256Text {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text
    )

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Text)
        $digest = $sha256.ComputeHash($bytes)
    } finally {
        $sha256.Dispose()
    }
    return ([System.BitConverter]::ToString($digest) -replace '-', '').ToLowerInvariant().Substring(0, 16)
}

function Get-ConfiguredHookKeys {
    param(
        [Parameter(Mandatory = $true)]
        [string]$HooksConfigText
    )

    $hooksDocument = $HooksConfigText | ConvertFrom-Json
    if ($null -eq $hooksDocument.hooks) {
        throw "Hooks configuration has no 'hooks' object."
    }

    $eventKeyMap = @{
        SessionStart = 'session_start'
        UserPromptSubmit = 'user_prompt_submit'
        Stop = 'stop'
        PreCompact = 'pre_compact'
    }
    $hookKeys = [Collections.Generic.List[string]]::new()
    foreach ($eventProperty in $hooksDocument.hooks.PSObject.Properties) {
        if (-not $eventKeyMap.ContainsKey($eventProperty.Name)) {
            continue
        }

        $eventKey = $eventKeyMap[$eventProperty.Name]
        $matcherGroups = @($eventProperty.Value)
        for ($groupIndex = 0; $groupIndex -lt $matcherGroups.Count; $groupIndex++) {
            $groupHooks = @($matcherGroups[$groupIndex].hooks)
            for ($hookIndex = 0; $hookIndex -lt $groupHooks.Count; $hookIndex++) {
                if ([string]$groupHooks[$hookIndex].type -eq 'command') {
                    $hookKeys.Add(("{0}:{1}:{2}" -f $eventKey, $groupIndex, $hookIndex))
                }
            }
        }
    }

    return @($hookKeys)
}

function Get-TrustedHookHashMap {
    param(
        [Parameter(Mandatory = $true)][string]$ConfigText,
        [Parameter(Mandatory = $true)][string]$SourceHookPath,
        [Parameter(Mandatory = $true)][string[]]$HookKeys
    )

    $python = (Get-Command python -ErrorAction Stop).Source
    $pythonCode = @'
import json
import re
import sys
import tomllib
from pathlib import Path

config = tomllib.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
source_path = str(Path(sys.argv[2]).resolve())
hook_keys = json.loads(Path(sys.argv[3]).read_text(encoding="utf-8"))
states = config.get("hooks", {}).get("state", {})
if not isinstance(states, dict):
    raise RuntimeError("Global hooks.state must be a TOML table.")

folded_states = {}
for state_key, state_value in states.items():
    folded_key = str(state_key).casefold()
    if folded_key in folded_states and folded_states[folded_key] != state_value:
        raise RuntimeError("Global hook trust contains conflicting case variants.")
    folded_states[folded_key] = state_value

hashes = {}
for hook_key in hook_keys:
    state_key = f"{source_path}:{hook_key}".casefold()
    state = folded_states.get(state_key)
    trusted_hash = state.get("trusted_hash") if isinstance(state, dict) else None
    if not isinstance(trusted_hash, str) or not re.fullmatch(
        r"sha256:[0-9A-Fa-f]{64}", trusted_hash
    ):
        raise RuntimeError(f"Missing valid global hook trust for {hook_key}.")
    hashes[hook_key] = trusted_hash

print(json.dumps({"ok": True, "hashes": hashes}, ensure_ascii=True))
'@
    $tempRoot = [System.IO.Path]::GetTempPath()
    $suffix = "$PID-$([guid]::NewGuid().ToString('N'))"
    $tempPythonPath = Join-Path $tempRoot "ccswitch-hook-trust-$suffix.py"
    $tempConfigPath = Join-Path $tempRoot "ccswitch-hook-trust-$suffix.toml"
    $tempKeysPath = Join-Path $tempRoot "ccswitch-hook-trust-$suffix.json"
    try {
        Write-Utf8NoBom -Path $tempPythonPath -Content $pythonCode
        Write-Utf8NoBom -Path $tempConfigPath -Content $ConfigText
        Write-Utf8NoBom -Path $tempKeysPath -Content (($HookKeys | ConvertTo-Json -Compress) + "`n")
        $output = & $python $tempPythonPath $tempConfigPath $SourceHookPath $tempKeysPath
        if ($LASTEXITCODE -ne 0) { throw "Global hook trust parsing failed with exit code $LASTEXITCODE." }
        $result = (($output | Out-String).Trim() | ConvertFrom-Json)
        if (-not [bool]$result.ok) { throw 'Global hook trust parsing failed.' }
        $hashMap = @{}
        foreach ($property in $result.hashes.PSObject.Properties) {
            $hashMap[$property.Name] = [string]$property.Value
        }
        return $hashMap
    } finally {
        Remove-Item -LiteralPath $tempPythonPath, $tempConfigPath, $tempKeysPath -Force -ErrorAction SilentlyContinue
    }
}

function Merge-GlobalMcpConfig {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ProviderConfigText,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$GlobalConfigText
    )

    $python = (Get-Command python -ErrorAction Stop).Source
    $pythonCode = @'
import copy
import json
import sys
import tomllib
from pathlib import Path

def parse_config(text, label):
    try:
        return tomllib.loads(text)
    except Exception as exc:
        raise RuntimeError(f"{label} is not valid TOML.") from exc

def table_root(line):
    stripped = line.strip()
    if not stripped.startswith("["):
        return None
    try:
        parsed = tomllib.loads(stripped + "\n")
    except Exception:
        return None
    if len(parsed) != 1:
        return None
    return next(iter(parsed))

def split_table_blocks(text):
    blocks = []
    current_lines = []
    current_root = None
    for line in text.splitlines(keepends=True):
        root = table_root(line)
        if root is not None:
            if current_lines:
                blocks.append((current_root, current_lines))
            current_lines = [line]
            current_root = root
        else:
            current_lines.append(line)
    if current_lines:
        blocks.append((current_root, current_lines))
    return blocks

provider_text = Path(sys.argv[1]).read_text(encoding="utf-8")
global_text = Path(sys.argv[2]).read_text(encoding="utf-8")
provider_config = parse_config(provider_text, "Provider config")
global_config = parse_config(global_text, "Global Codex config")

global_mcp = global_config.get("mcp_servers", {})
if not isinstance(global_mcp, dict):
    raise RuntimeError("Global mcp_servers must be a TOML table.")
if any(not isinstance(value, dict) for value in global_mcp.values()):
    raise RuntimeError("Every global MCP server must be a TOML table.")

provider_blocks = split_table_blocks(provider_text)
provider_without_mcp = "".join(
    "".join(lines) for root, lines in provider_blocks if root != "mcp_servers"
)
provider_base = copy.deepcopy(provider_config)
provider_base.pop("mcp_servers", None)
if parse_config(provider_without_mcp, "Provider config without MCP") != provider_base:
    raise RuntimeError("Could not remove the provider mcp_servers subtree without changing other settings.")

if global_mcp:
    global_blocks = split_table_blocks(global_text)
    global_mcp_text = "".join(
        "".join(lines) for root, lines in global_blocks if root == "mcp_servers"
    ).strip()
    if not global_mcp_text:
        raise RuntimeError("Global mcp_servers uses an unsupported inline or dotted-key layout.")
    extracted = parse_config(global_mcp_text, "Extracted global MCP config").get("mcp_servers")
    if extracted != global_mcp:
        raise RuntimeError("Extracted global MCP config does not match the parsed mcp_servers subtree.")
    merged_text = provider_without_mcp.rstrip() + "\n\n" + global_mcp_text + "\n"
else:
    merged_text = provider_without_mcp.rstrip() + "\n"

merged_config = parse_config(merged_text, "Merged Codex config")
merged_base = copy.deepcopy(merged_config)
merged_result_mcp = merged_base.pop("mcp_servers", {})
if merged_base != provider_base:
    raise RuntimeError("MCP merge changed provider settings outside mcp_servers.")
if merged_result_mcp != global_mcp:
    raise RuntimeError("Merged mcp_servers does not match the global Codex config.")

print(json.dumps({
    "ok": True,
    "config": merged_text,
    "serverNames": sorted(global_mcp.keys()),
}, ensure_ascii=True))
'@
    $tempRoot = [System.IO.Path]::GetTempPath()
    $suffix = "$PID-$([guid]::NewGuid().ToString('N'))"
    $tempPythonPath = Join-Path $tempRoot "ccswitch-mcp-merge-$suffix.py"
    $tempProviderPath = Join-Path $tempRoot "ccswitch-mcp-provider-$suffix.toml"
    $tempGlobalPath = Join-Path $tempRoot "ccswitch-mcp-global-$suffix.toml"
    try {
        Write-Utf8NoBom -Path $tempPythonPath -Content $pythonCode
        Write-Utf8NoBom -Path $tempProviderPath -Content $ProviderConfigText
        Write-Utf8NoBom -Path $tempGlobalPath -Content $GlobalConfigText
        $output = & $python $tempPythonPath $tempProviderPath $tempGlobalPath
        if ($LASTEXITCODE -ne 0) { throw "Global MCP merge failed with exit code $LASTEXITCODE." }
        $mergeResponse = (($output | Out-String).Trim() | ConvertFrom-Json)
        if (-not [bool]$mergeResponse.ok) { throw 'Global MCP merge failed.' }
        return [pscustomobject]@{
            ConfigText = [string]$mergeResponse.config
            ServerNames = @($mergeResponse.serverNames)
        }
    } finally {
        Remove-Item -LiteralPath $tempPythonPath, $tempProviderPath, $tempGlobalPath -Force -ErrorAction SilentlyContinue
    }
}

function Add-RunHomeHookTrustState {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ConfigText,
        [Parameter(Mandatory = $true)][string]$HookPath,
        [Parameter(Mandatory = $true)][string[]]$HookKeys,
        [Parameter(Mandatory = $true)][hashtable]$TrustedHashes
    )

    # Codex keys hook trust by the concrete hooks.json path. Each provider run gets
    # a fresh CODEX_HOME, so carry the already-reviewed hashes to that run-local path.
    $ConfigText = $ConfigText -replace "`r`n", "`n"
    $normalizedHookPath = [System.IO.Path]::GetFullPath($HookPath)

    foreach ($hookKey in $HookKeys) {
        $trustedHash = [string]$TrustedHashes[$hookKey]
        $block = "[hooks.state.'{0}:{1}']`ntrusted_hash = `"{2}`"`n" -f `
            $normalizedHookPath,
            $hookKey,
            $trustedHash
        $ConfigText = $ConfigText.TrimEnd() + "`n`n" + $block
    }

    return $ConfigText
}

function Get-StableGlobalConfigAndHookSnapshot {
    $deadline = [DateTime]::UtcNow.AddSeconds(3)
    $lastProblem = 'No global hook snapshot attempt completed.'
    do {
        try {
            $hooksBytesBefore = [IO.File]::ReadAllBytes($GlobalHooksPath)
            $configText = Get-TextFileContent -Path $GlobalConfigPath
            $hooksBytesAfter = [IO.File]::ReadAllBytes($GlobalHooksPath)
            $beforeHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($hooksBytesBefore))
            $afterHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($hooksBytesAfter))
            if ($beforeHash -ne $afterHash) {
                $lastProblem = 'Global hooks.json changed while its trust snapshot was read.'
                continue
            }
            $hooksText = [Text.UTF8Encoding]::new($false, $true).GetString($hooksBytesBefore).TrimStart([char]0xFEFF)
            $hookKeys = @(Get-ConfiguredHookKeys -HooksConfigText $hooksText)
            $trustedHashes = Get-TrustedHookHashMap `
                -ConfigText $configText `
                -SourceHookPath $GlobalHooksPath `
                -HookKeys $hookKeys
            return [pscustomobject]@{
                HooksConfigBytes = $hooksBytesBefore
                GlobalConfigText = $configText
                HookKeys = $hookKeys
                TrustedHashes = $trustedHashes
            }
        } catch {
            $lastProblem = $_.Exception.Message
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Unable to capture a stable global hook trust snapshot within 3 seconds. Last error: $lastProblem"
}

function Set-ResilientStreamSettings {
    param(
        [Parameter(Mandatory = $true)][string]$ConfigText
    )

    # Keep the transport tolerant of slow third-party Responses relays without
    # changing provider URLs, authentication, or the selected model.
    $updated = [regex]::Replace(
        $ConfigText,
        '(?m)^((?:["'']?stream_max_retries["'']?)[ \t]*=[ \t]*)\d+',
        '${1}10'
    )
    return [regex]::Replace(
        $updated,
        '(?m)^((?:["'']?stream_idle_timeout_ms["'']?)[ \t]*=[ \t]*)\d+',
        '${1}300000'
    )
}

$hookSnapshot = Get-StableGlobalConfigAndHookSnapshot
$details = Get-StableCcSwitchSnapshot
$safeProviderId = ConvertTo-SafeName -Value ([string]$details.provider.id)
$runStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$runSuffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
$profileName = "ccswitch-run-$runStamp-$($safeProviderId.Substring(0, [Math]::Min(8, $safeProviderId.Length)))-$runSuffix"
$codexHome = Join-Path $RunHomesRoot $profileName
$runProdexHome = Join-Path $codexHome '.prodex-runtime'
$runHooksPath = Join-Path $codexHome 'hooks.json'
$stagingName = ".ccswitch-staging-$profileName-$([guid]::NewGuid().ToString('N'))"
$stagingHome = Join-Path $RunHomesRoot $stagingName

# MCP registrations are user-local runtime settings. Keep the live global
# subtree authoritative instead of reviving a stale copy from the provider DB.
$mcpMerge = Merge-GlobalMcpConfig `
    -ProviderConfigText ([string]$details.config) `
    -GlobalConfigText ([string]$hookSnapshot.GlobalConfigText)
$details.config = [string]$mcpMerge.ConfigText
$details.config = Set-ResilientStreamSettings -ConfigText ([string]$details.config)
$details.config = Add-RunHomeHookTrustState `
    -ConfigText ([string]$details.config) `
    -HookPath $runHooksPath `
    -HookKeys $hookSnapshot.HookKeys `
    -TrustedHashes $hookSnapshot.TrustedHashes
$details.configSha256 = Get-ShortSha256Text -Text ([string]$details.config)

$metadata = [pscustomobject]@{
    schemaVersion = 2
    profileName = $profileName
    codexHome = $codexHome
    prodexHome = $runProdexHome
    providerId = $details.provider.id
    providerName = $details.provider.name
    ccSwitchRoot = $CcSwitchRoot
    baseUrl = $details.provider.baseUrl
    baseHost = $details.provider.baseHost
    endpointHost = $details.provider.endpointHost
    configSha256 = $details.configSha256
    authSha256 = $details.authSha256
    model = $details.model
    modelReasoningEffort = $details.modelReasoningEffort
    mcpServerNames = @($mcpMerge.ServerNames)
    hookTrustByKey = $hookSnapshot.TrustedHashes
    launchMode = $LaunchMode
    materializedAt = (Get-Date).ToString('o')
}

New-Item -ItemType Directory -Path $RunHomesRoot -Force | Out-Null
$published = $false
$runtimeReady = $false
try {
    New-Item -ItemType Directory -Path $stagingHome -ErrorAction Stop | Out-Null
    Write-Utf8NoBom -Path (Join-Path $stagingHome 'config.toml') -Content ([string]$details.config)
    Write-Utf8NoBom -Path (Join-Path $stagingHome 'auth.json') -Content ([string]$details.authJson)
    Initialize-CodexHomeRulesAndSkills `
        -CodexHomePath $stagingHome `
        -HooksConfigBytes $hookSnapshot.HooksConfigBytes
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

    if ($LaunchMode -eq 'prodex') {
        Register-ProdexProfile `
            -ProfileName $profileName `
            -CodexHome $codexHome `
            -RunProdexHome $runProdexHome
    } else {
        New-Item -ItemType Directory -Path $runProdexHome -ErrorAction Stop | Out-Null
    }
    $runtimeReady = $true
} catch {
    if (-not $published) {
        Remove-OwnedRunDirectory -Path $stagingHome -ExpectedName $stagingName
    } elseif (-not $runtimeReady) {
        Remove-OwnedRunDirectory -Path $codexHome -ExpectedName $profileName
    }
    throw
}

Write-Info ("materialized mode={0} profile={1} home={2} provider={3} id={4} base_url={5}" -f `
    $LaunchMode, $profileName, $codexHome, $details.provider.name, $details.provider.id, $details.provider.baseUrl)

$metadata | ConvertTo-Json -Depth 8 -Compress
