[CmdletBinding()]
param(
    [string]$CcSwitchRoot = '',
    [string[]]$CodexHome = @(),
    [switch]$CheckOnly,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
. (Join-Path $PSScriptRoot 'resolve-ccswitch-root.ps1')

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

$CcSwitchRoot = Resolve-CcSwitchRoot -ExplicitRoot $CcSwitchRoot -UserRoot $env:USERPROFILE -AppDataRoot $env:APPDATA

$SettingsPath = Join-Path $CcSwitchRoot 'settings.json'
$DbPath = Join-Path $CcSwitchRoot 'cc-switch.db'
$GlobalConfigPath = Join-Path $env:USERPROFILE '.codex\config.toml'
$GlobalHooksPath = Join-Path $env:USERPROFILE '.codex\hooks.json'
$syncMutex = [System.Threading.Mutex]::new(
    $false,
    (Get-CcSwitchRootMutexName -Root $CcSwitchRoot)
)
$syncLockTaken = $false
$syncChanges = [System.Collections.Generic.List[object]]::new()

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

function Assert-GlobalSourcesUnchanged {
    param(
        [Parameter(Mandatory = $true)][string]$ExpectedConfigContent,
        [Parameter(Mandatory = $true)][string]$ExpectedHooksContent
    )

    $currentConfigContent = Get-TextFileContent -Path $GlobalConfigPath
    $currentHooksContent = Get-TextFileContent -Path $GlobalHooksPath
    if (-not [string]::Equals($currentConfigContent, $ExpectedConfigContent, [StringComparison]::Ordinal) -or
        -not [string]::Equals($currentHooksContent, $ExpectedHooksContent, [StringComparison]::Ordinal)) {
        throw 'Global Codex config or hooks changed while capturing the mirror snapshot.'
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

function Restore-SyncChanges {
    param(
        [Parameter(Mandatory = $true)][object[]]$Changes
    )

    for ($index = $Changes.Count - 1; $index -ge 0; $index--) {
        $change = $Changes[$index]
        if (-not [bool]$change.Changed) {
            continue
        }
        if ($null -ne $change.BackupPath -and (Test-Path -LiteralPath $change.BackupPath -PathType Leaf)) {
            Move-Item -LiteralPath $change.BackupPath -Destination $change.Path -Force
        } elseif ($null -eq $change.BackupPath -and (Test-Path -LiteralPath $change.Path -PathType Leaf)) {
            Remove-Item -LiteralPath $change.Path -Force
        }
    }
}

try {
    try {
        $syncLockTaken = $syncMutex.WaitOne([TimeSpan]::FromMinutes(2))
    } catch [System.Threading.AbandonedMutexException] {
        $syncLockTaken = $true
    }
    if (-not $syncLockTaken) {
        throw 'Timed out waiting for another Codex mirror synchronization operation.'
    }

    if (-not (Test-Path -LiteralPath $SettingsPath)) {
        throw "Missing cc-switch settings: $SettingsPath"
    }
    if (-not (Test-Path -LiteralPath $DbPath)) {
        throw "Missing cc-switch DB: $DbPath"
    }
    if (-not (Test-Path -LiteralPath $GlobalConfigPath -PathType Leaf)) {
        throw "Missing global Codex configuration: $GlobalConfigPath"
    }
    if (-not (Test-Path -LiteralPath $GlobalHooksPath -PathType Leaf)) {
        throw "Missing global hooks configuration: $GlobalHooksPath"
    }
    $globalConfigContent = Get-TextFileContent -Path $GlobalConfigPath
    $globalHooksContent = Get-TextFileContent -Path $GlobalHooksPath
    Assert-GlobalSourcesUnchanged `
        -ExpectedConfigContent $globalConfigContent `
        -ExpectedHooksContent $globalHooksContent

    $currentProviderId = Get-CurrentProviderId

    $pythonCommand = Get-Command python -ErrorAction SilentlyContinue
    if ($null -eq $pythonCommand) {
        throw 'Python is required to read the cc-switch SQLite DB, but python was not found on PATH.'
    }

    $pythonCode = @'
import copy
import hashlib
import json
import re
import sqlite3
import sys
import tomllib
from pathlib import Path
from urllib.parse import urlparse


EVENT_KEY_MAP = {
    "SessionStart": "session_start",
    "UserPromptSubmit": "user_prompt_submit",
    "Stop": "stop",
    "PreCompact": "pre_compact",
}


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


def load_global_hook_groups(hooks_content):
    try:
        hooks_document = json.loads(hooks_content)
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise RuntimeError("Global hooks.json snapshot is invalid JSON.") from exc
    hook_groups = hooks_document.get("hooks")
    if not isinstance(hook_groups, dict):
        raise RuntimeError("Global hooks.json has no valid hooks object.")
    return hook_groups


def collect_command_hook_keys(hook_groups):
    expected_keys = []
    for event_name, entries in hook_groups.items():
        event_key = EVENT_KEY_MAP.get(event_name)
        if event_key is None or not isinstance(entries, list):
            raise RuntimeError("Global hooks.json has an invalid event hook list.")
        for entry_index, entry in enumerate(entries):
            if not isinstance(entry, dict) or not isinstance(entry.get("hooks"), list):
                raise RuntimeError("Global hooks.json has an invalid hook entry.")
            for hook_index, hook in enumerate(entry["hooks"]):
                if not isinstance(hook, dict):
                    raise RuntimeError("Global hooks.json has an invalid hook command entry.")
                if hook.get("type") == "command":
                    expected_keys.append(f"{event_key}:{entry_index}:{hook_index}")
    return expected_keys


def hook_state_header_regex(state_key):
    quoted_keys = []
    for ensure_ascii in (False, True):
        quoted_key = re.escape(json.dumps(state_key, ensure_ascii=ensure_ascii))
        if quoted_key not in quoted_keys:
            quoted_keys.append(quoted_key)
    quoted_key = rf"(?:{'|'.join(quoted_keys)})"
    single_quoted_key = re.escape(state_key).replace(r"\'", r"'")
    key_forms = rf"(?:{quoted_key}|'{single_quoted_key}')"
    return (
        r"(?:\[hooks\.state\." + key_forms + r"\]"
        r'|\[hooks\.state\.' + quoted_key + r"\]"
        r'|\["hooks"\."state"\.' + key_forms + r"\])"
    )


def hook_state_block_pattern(state_key):
    return re.compile(
        r"(?ms)^"
        + hook_state_header_regex(state_key)
        + r"[ \t]*(?:#[^\r\n]*)?\r?\n(?:trusted_hash|\"trusted_hash\")\s*=\s*\"[^\"]+\"\r?\n?"
    )


def validate_hook_state_entry(global_text, hook_state, hooks_path, hook_key):
    state_key = f"{hooks_path}:{hook_key}"
    header_pattern = re.compile(
        r"(?m)^" + hook_state_header_regex(state_key) + r"[ \t]*(?:#[^\r\n]*)?(?:\r?\n|$)"
    )
    if len(header_pattern.findall(global_text)) != 1:
        raise RuntimeError(
            f"Global Codex config is missing or duplicates trust for command hook {hook_key}."
        )
    trust_entry = hook_state.get(state_key)
    trusted_hash = trust_entry.get("trusted_hash") if isinstance(trust_entry, dict) else None
    if (
        not isinstance(trusted_hash, str)
        or re.fullmatch(r"sha256:[0-9a-fA-F]{64}", trusted_hash) is None
    ):
        raise RuntimeError(f"Global Codex config has malformed trust for command hook {hook_key}.")
    return state_key, trust_entry


def validate_global_hook_trust(global_text, hooks_content, hooks_path):
    global_config = parse_toml_config(global_text, "Global Codex config")
    hooks_config = global_config.get("hooks")
    hook_state = hooks_config.get("state") if isinstance(hooks_config, dict) else None
    if not isinstance(hook_state, dict):
        raise RuntimeError("Global Codex config has no valid hooks.state table.")

    expected_keys = collect_command_hook_keys(load_global_hook_groups(hooks_content))
    if len(expected_keys) != len(set(expected_keys)):
        raise RuntimeError("Global hooks.json contains duplicate command hook indexes.")

    validated_state = {}
    for hook_key in expected_keys:
        state_key, trust_entry = validate_hook_state_entry(
            global_text, hook_state, hooks_path, hook_key
        )
        validated_state[state_key] = trust_entry
    return validated_state


def validate_merged_hook_trust(config_text, validated_state):
    merged_config = parse_toml_config(config_text, "Merged provider hook trust")
    merged_hooks = merged_config.get("hooks")
    merged_state = merged_hooks.get("state") if isinstance(merged_hooks, dict) else None
    if not isinstance(merged_state, dict):
        raise RuntimeError("Merged provider config has no valid hooks.state table.")
    for state_key, expected_entry in validated_state.items():
        if merged_state.get(state_key) != expected_entry:
            raise RuntimeError(f"Provider config did not receive trust for command hook {state_key}.")


def merge_global_hook_trust(config_text, global_text, hooks_content, hooks_path):
    validated_state = validate_global_hook_trust(global_text, hooks_content, hooks_path)
    for state_key, trust_entry in validated_state.items():
        normalized_block = (
            f'["hooks"."state".{json.dumps(state_key, ensure_ascii=True)}]\n'
            f'trusted_hash = "{trust_entry["trusted_hash"]}"'
        )
        existing_block = hook_state_block_pattern(state_key)
        matches = list(existing_block.finditer(config_text))
        if matches:
            rewritten = []
            cursor = 0
            for index, match in enumerate(matches):
                rewritten.append(config_text[cursor:match.start()])
                if index == 0:
                    rewritten.append(normalized_block + "\n")
                cursor = match.end()
            rewritten.append(config_text[cursor:])
            config_text = "".join(rewritten)
        else:
            config_text = config_text.rstrip("\r\n") + "\n\n" + normalized_block + "\n"

    validate_merged_hook_trust(config_text, validated_state)
    return config_text


def parse_toml_config(config_text, label):
    try:
        return tomllib.loads(config_text)
    except tomllib.TOMLDecodeError as exc:
        raise RuntimeError(f"{label} is not valid TOML.") from exc


def table_root(line):
    stripped = line.strip()
    if not stripped.startswith("["):
        return None
    try:
        parsed = tomllib.loads(stripped + "\n")
    except tomllib.TOMLDecodeError:
        return None
    if len(parsed) != 1:
        return None
    return next(iter(parsed))


def split_table_blocks(config_text):
    blocks = []
    current_lines = []
    current_root = None
    for line in config_text.splitlines(keepends=True):
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


def extract_global_mcp_text(global_text, global_mcp):
    global_mcp_text = "".join(
        "".join(lines)
        for root, lines in split_table_blocks(global_text)
        if root == "mcp_servers"
    ).strip()
    if not global_mcp_text:
        raise RuntimeError("Global mcp_servers uses an unsupported inline or dotted-key layout.")

    extracted_mcp = parse_toml_config(
        global_mcp_text,
        "Extracted global MCP config",
    ).get("mcp_servers")
    if extracted_mcp != global_mcp:
        raise RuntimeError("Extracted global MCP config does not match the parsed MCP table.")
    return global_mcp_text


def validate_mcp_merge(merged_text, provider_base, global_mcp):
    merged_config = parse_toml_config(merged_text, "Merged Codex config")
    merged_base = copy.deepcopy(merged_config)
    merged_result_mcp = merged_base.pop("mcp_servers", {})
    if merged_base != provider_base:
        raise RuntimeError("MCP merge changed provider settings outside mcp_servers.")
    if merged_result_mcp != global_mcp:
        raise RuntimeError("Merged mcp_servers does not match the global Codex config.")


def merge_global_mcp(config_text, global_text):
    provider_config = parse_toml_config(config_text, "Provider config")
    global_config = parse_toml_config(global_text, "Global Codex config")
    global_mcp = global_config.get("mcp_servers", {})
    if not isinstance(global_mcp, dict):
        raise RuntimeError("Global mcp_servers must be a TOML table.")
    if any(not isinstance(value, dict) for value in global_mcp.values()):
        raise RuntimeError("Every global MCP server must be a TOML table.")

    provider_blocks = split_table_blocks(config_text)
    provider_without_mcp = "".join(
        "".join(lines) for root, lines in provider_blocks if root != "mcp_servers"
    )
    provider_base = copy.deepcopy(provider_config)
    provider_base.pop("mcp_servers", None)
    if parse_toml_config(provider_without_mcp, "Provider config without MCP") != provider_base:
        raise RuntimeError("Could not remove the provider mcp_servers subtree safely.")

    if not global_mcp:
        return provider_without_mcp.rstrip() + "\n"

    global_mcp_text = extract_global_mcp_text(global_text, global_mcp)
    merged_text = provider_without_mcp.rstrip() + "\n\n" + global_mcp_text + "\n"
    validate_mcp_merge(merged_text, provider_base, global_mcp)
    return merged_text


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
global_config_path = sys.argv[4]
global_hooks_snapshot_path = sys.argv[5]
global_hooks_path = sys.argv[6]
global_text = Path(global_config_path).read_text(encoding="utf-8")
global_hooks_text = Path(global_hooks_snapshot_path).read_text(encoding="utf-8")
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
config_text = merge_global_hook_trust(config_text, global_text, global_hooks_text, global_hooks_path)
config_text = merge_global_mcp(config_text, global_text)

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
$tempGlobalConfigPath = Join-Path ([System.IO.Path]::GetTempPath()) "sync-ccswitch-current-codex-$PID-$([guid]::NewGuid().ToString('N')).toml"
$tempGlobalHooksPath = Join-Path ([System.IO.Path]::GetTempPath()) "sync-ccswitch-current-codex-$PID-$([guid]::NewGuid().ToString('N')).json"
$previousPythonIoEncoding = $env:PYTHONIOENCODING
$previousPythonUtf8 = $env:PYTHONUTF8
try {
    [System.IO.File]::WriteAllText($tempPythonPath, $pythonCode, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($tempGlobalConfigPath, $globalConfigContent, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($tempGlobalHooksPath, $globalHooksContent, [System.Text.UTF8Encoding]::new($false))
    Assert-GlobalSourcesUnchanged `
        -ExpectedConfigContent $globalConfigContent `
        -ExpectedHooksContent $globalHooksContent
    $env:PYTHONIOENCODING = 'utf-8'
    $env:PYTHONUTF8 = '1'
    & $pythonCommand.Source $tempPythonPath $DbPath $currentProviderId $tempQueryOutputPath $tempGlobalConfigPath $tempGlobalHooksPath $GlobalHooksPath
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
    Remove-Item -LiteralPath $tempGlobalConfigPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tempGlobalHooksPath -Force -ErrorAction SilentlyContinue
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
Assert-GlobalSourcesUnchanged `
    -ExpectedConfigContent $globalConfigContent `
    -ExpectedHooksContent $globalHooksContent

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
foreach ($targetHome in $CodexHomes) {
    Assert-GlobalSourcesUnchanged `
        -ExpectedConfigContent $globalConfigContent `
        -ExpectedHooksContent $globalHooksContent
    if (-not $CheckOnly) {
        New-Item -ItemType Directory -Path $targetHome -Force | Out-Null
    }
    $configResult = Sync-TextFile `
        -Path (Join-Path $targetHome 'config.toml') `
        -DesiredContent ([string]$details.config) `
        -Stamp $stamp
    $syncChanges.Add($configResult)
    $authResult = Sync-TextFile `
        -Path (Join-Path $targetHome 'auth.json') `
        -DesiredContent ([string]$details.authJson) `
        -Stamp $stamp
    $syncChanges.Add($authResult)
    $hooksResult = Sync-TextFile `
        -Path (Join-Path $targetHome 'hooks.json') `
        -DesiredContent $globalHooksContent `
        -Stamp $stamp
    $syncChanges.Add($hooksResult)

    Write-SyncInfo ("ccswitch-current home={0} provider={1} id={2} config_sha256={3} auth_sha256={4}" -f `
        $targetHome, $details.provider.name, $details.provider.id, $details.configSha256, $details.authSha256)

    foreach ($result in @($configResult, $authResult, $hooksResult)) {
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
} catch {
    $syncFailure = $_
    if (-not $CheckOnly) {
        try {
            Restore-SyncChanges -Changes $syncChanges
        } catch {
            throw "Mirror synchronization failed and rollback failed: $($_.Exception.Message)"
        }
    }
    throw $syncFailure
} finally {
    if ($syncLockTaken) {
        $syncMutex.ReleaseMutex()
    }
    $syncMutex.Dispose()
}
