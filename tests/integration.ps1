[CmdletBinding()]
param(
    [switch]$KeepTemp
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script:MaterializeSource = Join-Path $script:RepoRoot 'scripts\materialize-ccswitch-codex-run.ps1'
$script:PersistSource = Join-Path $script:RepoRoot 'scripts\persist-run-model.ps1'
$script:SyncSource = Join-Path $script:RepoRoot 'scripts\sync-ccswitch-current-codex.ps1'
$script:WatcherSource = Join-Path $script:RepoRoot 'scripts\watch-run-model.ps1'
$script:LauncherSource = Join-Path $script:RepoRoot 'scripts\invoke-ccswitch-codex.ps1'
$script:RootResolverSource = Join-Path $script:RepoRoot 'scripts\resolve-ccswitch-root.ps1'
$script:Python = (Get-Command python -ErrorAction Stop).Source
$script:Pwsh = (Get-Command pwsh -ErrorAction Stop).Source
$script:SuiteRoot = Join-Path ([IO.Path]::GetTempPath()) ("ccsi-{0}" -f [guid]::NewGuid().ToString('N').Substring(0, 8))
$script:CaseCounter = 0
$script:Results = [Collections.Generic.List[object]]::new()
$script:ShellSkips = [Collections.Generic.List[string]]::new()
$script:OriginalAppData = [Environment]::GetEnvironmentVariable('APPDATA', 'Process')
$script:OriginalEnvironment = @{
    USERPROFILE = [Environment]::GetEnvironmentVariable('USERPROFILE', 'Process')
    APPDATA = $script:OriginalAppData
    HOME = [Environment]::GetEnvironmentVariable('HOME', 'Process')
    PRODEX_HOME = [Environment]::GetEnvironmentVariable('PRODEX_HOME', 'Process')
    PRODEX_SHARED_CODEX_HOME = [Environment]::GetEnvironmentVariable('PRODEX_SHARED_CODEX_HOME', 'Process')
    PRODEX_CODEX_BIN = [Environment]::GetEnvironmentVariable('PRODEX_CODEX_BIN', 'Process')
    CCSWITCH_CODEX_LAUNCH_MODE = [Environment]::GetEnvironmentVariable('CCSWITCH_CODEX_LAUNCH_MODE', 'Process')
}
$script:ProdexScript = Join-Path $script:OriginalAppData 'npm\prodex.ps1'
$script:CodexBinary = $script:OriginalEnvironment.PRODEX_CODEX_BIN
if ([string]::IsNullOrWhiteSpace($script:CodexBinary)) {
    $pointerPath = Join-Path $script:OriginalEnvironment.USERPROFILE '.codex\bin\codex-focusfixed-current.txt'
    if (Test-Path -LiteralPath $pointerPath -PathType Leaf) {
        $script:CodexBinary = (Get-Content -LiteralPath $pointerPath -Raw).Trim()
    }
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        [IO.Directory]::CreateDirectory($parent) | Out-Null
    }
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

function Format-TestValue {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return '<null>' }
    try {
        return ($Value | ConvertTo-Json -Depth 8 -Compress)
    } catch {
        return [string]$Value
    }
}

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Because
    )

    if (-not $Condition) {
        throw "Assertion failed: $Because"
    }
}

function Assert-Equal {
    param(
        [AllowNull()][object]$Expected,
        [AllowNull()][object]$Actual,
        [Parameter(Mandatory = $true)][string]$Because
    )

    if (-not [object]::Equals($Expected, $Actual)) {
        throw ("Assertion failed: {0}. Expected={1}; Actual={2}" -f `
            $Because, (Format-TestValue $Expected), (Format-TestValue $Actual))
    }
}

function Assert-SequenceEqual {
    param(
        [AllowEmptyCollection()][object[]]$Expected,
        [AllowEmptyCollection()][object[]]$Actual,
        [Parameter(Mandatory = $true)][string]$Because
    )

    $expectedJson = @($Expected) | ConvertTo-Json -Compress
    $actualJson = @($Actual) | ConvertTo-Json -Compress
    if (-not [string]::Equals($expectedJson, $actualJson, [StringComparison]::Ordinal)) {
        throw "Assertion failed: $Because. Expected=$expectedJson; Actual=$actualJson"
    }
}

function Invoke-TestCase {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Body
    )

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    try {
        & $Body
        $stopwatch.Stop()
        $script:Results.Add([pscustomobject]@{
            Name = $Name
            Status = 'PASS'
            DurationMs = $stopwatch.ElapsedMilliseconds
            Error = $null
        })
        Write-Host ("[PASS] {0} ({1} ms)" -f $Name, $stopwatch.ElapsedMilliseconds)
    } catch {
        $stopwatch.Stop()
        $script:Results.Add([pscustomobject]@{
            Name = $Name
            Status = 'FAIL'
            DurationMs = $stopwatch.ElapsedMilliseconds
            Error = $_.ToString()
        })
        Write-Host ("[FAIL] {0} ({1} ms)`n{2}" -f $Name, $stopwatch.ElapsedMilliseconds, $_.ToString()) -ForegroundColor Red
    }
}

function Set-CaseEnvironment {
    param([Parameter(Mandatory = $true)]$Case)

    $env:USERPROFILE = $Case.UserRoot
    $env:APPDATA = $Case.AppData
    $env:HOME = $Case.UserRoot
    $env:PRODEX_HOME = $Case.ProdexRoot
    $env:PRODEX_SHARED_CODEX_HOME = $Case.SharedCodexHome
    $env:PRODEX_CODEX_BIN = $script:CodexBinary
    $env:CCSWITCH_CODEX_LAUNCH_MODE = 'prodex'
}

function Restore-OriginalEnvironment {
    foreach ($name in $script:OriginalEnvironment.Keys) {
        $value = $script:OriginalEnvironment[$name]
        if ($null -eq $value) {
            Remove-Item -LiteralPath "Env:\$name" -ErrorAction SilentlyContinue
        } else {
            [Environment]::SetEnvironmentVariable($name, $value, 'Process')
        }
    }
}

function New-FixtureHelper {
    $helperPath = Join-Path $script:SuiteRoot 'support\fixture_db.py'
    $helperCode = @'
import json
import sqlite3
import sys
import tomllib
from pathlib import Path


def provider_settings(provider_id, model, effort):
    config = (
        f'model = "{model}"\n'
        f'model_reasoning_effort = "{effort}"\n'
        f'model_provider = "{provider_id}"\n'
        '\n'
        f'[model_providers.{provider_id}]\n'
        f'name = "Fixture {provider_id}"\n'
        f'base_url = "https://{provider_id}.invalid/v1"\n'
        'wire_api = "responses"\n'
        'requires_openai_auth = true\n'
    )
    return json.dumps(
        {
            "config": config,
            "auth": {
                "OPENAI_API_KEY": f"TEST_TOKEN_{provider_id.upper().replace('-', '_')}",
            },
            "fixtureMarker": provider_id,
        },
        ensure_ascii=True,
        separators=(",", ":"),
    )


def connect(path):
    connection = sqlite3.connect(path, timeout=2.0, isolation_level=None)
    connection.row_factory = sqlite3.Row
    return connection


action = sys.argv[1]
db_path = Path(sys.argv[2]).resolve()

if action == "create":
    db_path.parent.mkdir(parents=True, exist_ok=True)
    connection = connect(db_path)
    try:
        connection.executescript(
            """
            create table providers (
                id text primary key,
                name text not null,
                website_url text,
                app_type text not null,
                category text,
                sort_index integer,
                is_current integer not null,
                settings_config text not null
            );
            create table provider_endpoints (
                id integer primary key autoincrement,
                provider_id text not null,
                app_type text not null,
                url text not null
            );
            """
        )
        providers = (
            ("provider-a", "Provider A", "model-a", "high", 1, 10),
            ("provider-b", "Provider B", "model-b", "medium", 0, 20),
        )
        for provider_id, name, model, effort, current, sort_index in providers:
            connection.execute(
                "insert into providers values (?, ?, ?, 'codex', 'fixture', ?, ?, ?)",
                (
                    provider_id,
                    name,
                    f"https://{provider_id}.invalid",
                    sort_index,
                    current,
                    provider_settings(provider_id, model, effort),
                ),
            )
            connection.execute(
                "insert into provider_endpoints(provider_id, app_type, url) values (?, 'codex', ?)",
                (provider_id, f"https://{provider_id}.invalid/v1"),
            )
    finally:
        connection.close()
elif action == "switch":
    provider_id = sys.argv[3]
    connection = connect(db_path)
    try:
        connection.execute("begin immediate")
        connection.execute("update providers set is_current=0 where app_type='codex'")
        cursor = connection.execute(
            "update providers set is_current=1 where app_type='codex' and id=?",
            (provider_id,),
        )
        if cursor.rowcount != 1:
            raise RuntimeError(f"provider not found: {provider_id}")
        connection.execute("commit")
    except Exception:
        if connection.in_transaction:
            connection.execute("rollback")
        raise
    finally:
        connection.close()
elif action == "delete":
    provider_id = sys.argv[3]
    connection = connect(db_path)
    try:
        connection.execute("delete from providers where app_type='codex' and id=?", (provider_id,))
    finally:
        connection.close()
elif action == "remove-model":
    provider_id = sys.argv[3]
    connection = connect(db_path)
    try:
        row = connection.execute(
            "select settings_config from providers where app_type='codex' and id=?",
            (provider_id,),
        ).fetchone()
        if row is None:
            raise RuntimeError(f"provider not found: {provider_id}")
        settings = json.loads(row["settings_config"])
        lines = settings["config"].splitlines(keepends=True)
        retained = [line for line in lines if not line.startswith("model =")]
        if len(retained) != len(lines) - 1:
            raise RuntimeError("expected exactly one top-level model assignment")
        settings["config"] = "".join(retained)
        connection.execute(
            "update providers set settings_config=? where app_type='codex' and id=?",
            (json.dumps(settings, ensure_ascii=True, separators=(",", ":")), provider_id),
        )
    finally:
        connection.close()
elif action == "add-quoted-hook-trust":
    provider_id = sys.argv[3]
    hooks_path = sys.argv[4]
    connection = connect(db_path)
    try:
        row = connection.execute(
            "select settings_config from providers where app_type='codex' and id=?",
            (provider_id,),
        ).fetchone()
        if row is None:
            raise RuntimeError(f"provider not found: {provider_id}")
        settings = json.loads(row["settings_config"])
        hook_keys = [
            "session_start:0:0",
            "session_start:1:0",
            "user_prompt_submit:0:0",
            "stop:0:0",
            "pre_compact:0:0",
        ]
        config_lines = [settings["config"].rstrip(), "", '["hooks"]', '["hooks"."state"]']
        for hook_key in hook_keys:
            state_key = f"{hooks_path}:{hook_key}"
            config_lines.extend(
                [
                    f'[hooks.state.{json.dumps(state_key, ensure_ascii=False)}] # 测试 trust',
                    f'"trusted_hash" = "sha256:{"a" * 64}"',
                ]
            )
        config_lines.extend(
            [
                '[hooks.state."X测试"] # Unicode key fixture',
                'trusted_hash = "sha256:' + ('a' * 64) + '"',
            ]
        )
        settings["config"] = "\n".join(config_lines) + "\n"
        connection.execute(
            "update providers set settings_config=? where app_type='codex' and id=?",
            (json.dumps(settings, ensure_ascii=True, separators=(",", ":")), provider_id),
        )
    finally:
        connection.close()
elif action in ("add-single-quoted-hook-trust", "add-mixed-quoted-hook-trust"):
    provider_id = sys.argv[3]
    hooks_path = sys.argv[4]
    connection = connect(db_path)
    try:
        row = connection.execute(
            "select settings_config from providers where app_type='codex' and id=?",
            (provider_id,),
        ).fetchone()
        if row is None:
            raise RuntimeError(f"provider not found: {provider_id}")
        settings = json.loads(row["settings_config"])
        hook_keys = [
            "session_start:0:0",
            "session_start:1:0",
            "user_prompt_submit:0:0",
            "stop:0:0",
            "pre_compact:0:0",
        ]
        config_lines = [settings["config"].rstrip(), "", "[hooks.state]"]
        for index, hook_key in enumerate(hook_keys):
            state_key = f"{hooks_path}:{hook_key}"
            config_lines.extend(
                [
                    f"[hooks.state.'{state_key}']",
                    f"trusted_hash = \"sha256:{'a' * 64}\"",
                ]
            )
            if action == "add-mixed-quoted-hook-trust" and index == 0:
                config_lines.extend(
                    [
                        f'["hooks"."state".{json.dumps(state_key, ensure_ascii=True)}]',
                        f'trusted_hash = "sha256:{"a" * 64}"',
                    ]
                )
        settings["config"] = "\n".join(config_lines) + "\n"
        connection.execute(
            "update providers set settings_config=? where app_type='codex' and id=?",
            (json.dumps(settings, ensure_ascii=True, separators=(",", ":")), provider_id),
        )
    finally:
        connection.close()
elif action == "replace-config":
    provider_id = sys.argv[3]
    config_path = Path(sys.argv[4]).resolve()
    config = config_path.read_text(encoding="utf-8")
    connection = connect(db_path)
    try:
        row = connection.execute(
            "select settings_config from providers where app_type='codex' and id=?",
            (provider_id,),
        ).fetchone()
        if row is None:
            raise RuntimeError(f"provider not found: {provider_id}")
        settings = json.loads(row["settings_config"])
        settings["config"] = config
        connection.execute(
            "update providers set settings_config=? where app_type='codex' and id=?",
            (json.dumps(settings, ensure_ascii=True, separators=(",", ":")), provider_id),
        )
    finally:
        connection.close()
elif action == "read":
    connection = connect(db_path)
    try:
        rows = connection.execute(
            "select id, is_current, settings_config from providers where app_type='codex' order by id"
        ).fetchall()
        result = []
        for row in rows:
            settings = json.loads(row["settings_config"])
            parsed = tomllib.loads(settings["config"])
            result.append(
                {
                    "id": row["id"],
                    "isCurrent": bool(row["is_current"]),
                    "settingsRaw": row["settings_config"],
                    "model": parsed.get("model"),
                    "effort": parsed.get("model_reasoning_effort"),
                }
            )
        print(json.dumps(result, ensure_ascii=True, separators=(",", ":")))
    finally:
        connection.close()
else:
    raise RuntimeError(f"unknown action: {action}")
'@
    Write-Utf8NoBom -Path $helperPath -Content $helperCode
    return $helperPath
}

function New-LockHelper {
    $helperPath = Join-Path $script:SuiteRoot 'support\hold_db_lock.py'
    $helperCode = @'
import sqlite3
import sys
import time
from pathlib import Path

db_path = sys.argv[1]
signal_path = Path(sys.argv[2])
seconds = float(sys.argv[3])
connection = sqlite3.connect(db_path, timeout=0.2, isolation_level=None)
try:
    connection.execute("begin exclusive")
    signal_path.write_text("locked", encoding="ascii")
    time.sleep(seconds)
    connection.execute("rollback")
finally:
    connection.close()
'@
    Write-Utf8NoBom -Path $helperPath -Content $helperCode
    return $helperPath
}

function New-MirrorLockHelper {
    $helperPath = Join-Path $script:SuiteRoot 'support\hold_mirror_lock.ps1'
    $helperCode = @'
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$CcSwitchRoot,
    [Parameter(Mandatory = $true)][string]$SignalPath,
    [int]$HoldMilliseconds = 5000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$normalizedMutexRoot = [IO.Path]::GetFullPath($CcSwitchRoot)
$rootPath = [IO.Path]::GetPathRoot($normalizedMutexRoot)
if (-not [string]::Equals($normalizedMutexRoot, $rootPath, [StringComparison]::OrdinalIgnoreCase)) {
    $normalizedMutexRoot = $normalizedMutexRoot.TrimEnd([char[]]@('\', '/'))
}
$mutexIdentity = $normalizedMutexRoot.ToLowerInvariant()
$sha256 = [Security.Cryptography.SHA256]::Create()
try {
    $mutexHash = ([BitConverter]::ToString(
        $sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($mutexIdentity))
    )).Replace('-', '')
} finally {
    $sha256.Dispose()
}
$mutex = [Threading.Mutex]::new($false, "Local\ccswitch-codex-root-operation-$mutexHash")
$lockTaken = $false
try {
    try {
        $lockTaken = $mutex.WaitOne([TimeSpan]::FromSeconds(10))
    } catch [Threading.AbandonedMutexException] {
        $lockTaken = $true
    }
    if (-not $lockTaken) {
        throw 'fixture could not acquire the mirror sync mutex'
    }
    [IO.File]::WriteAllText($SignalPath, 'locked')
    Start-Sleep -Milliseconds $HoldMilliseconds
} finally {
    if ($lockTaken) {
        $mutex.ReleaseMutex()
    }
    $mutex.Dispose()
}
'@
    Write-Utf8NoBom -Path $helperPath -Content $helperCode
    return $helperPath
}

function New-MaterializeRunHelper {
    $helperPath = Join-Path $script:SuiteRoot 'support\materialize_then_version.ps1'
    $helperCode = @'
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$MaterializeScript,
    [Parameter(Mandatory = $true)][string]$CcSwitchRoot,
    [Parameter(Mandatory = $true)][string]$ProdexScript
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    $materializeOutput = @(& $MaterializeScript `
        -Quiet `
        -CcSwitchRoot $CcSwitchRoot `
        -ProdexScript $ProdexScript)
    $metadataLine = @($materializeOutput |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
        Select-Object -Last 1)
    if ($metadataLine.Count -ne 1) {
        throw 'Materialize did not return one metadata line.'
    }
    $snapshot = $metadataLine[0] | ConvertFrom-Json

    $env:PRODEX_HOME = [string]$snapshot.prodexHome
    $global:LASTEXITCODE = 0
    $versionOutput = @(& $ProdexScript `
        run `
        --profile ([string]$snapshot.profileName) `
        --no-auto-rotate `
        --full-access `
        --version 2>&1)
    $versionExitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }

    [pscustomobject]@{
        profileName = $snapshot.profileName
        codexHome = $snapshot.codexHome
        prodexHome = $snapshot.prodexHome
        providerId = $snapshot.providerId
        model = $snapshot.model
        versionExitCode = $versionExitCode
        versionOutput = (($versionOutput | Out-String).Trim())
    } | ConvertTo-Json -Depth 6 -Compress
    exit $versionExitCode
} catch {
    Write-Error -ErrorRecord $_ -ErrorAction Continue
    exit 1
}
'@
    Write-Utf8NoBom -Path $helperPath -Content $helperCode
    return $helperPath
}

function Invoke-FixtureDb {
    param(
        [Parameter(Mandatory = $true)][string]$Action,
        [Parameter(Mandatory = $true)][string]$DbPath,
        [string[]]$AdditionalArguments = @()
    )

    $output = @(& $script:Python $script:FixtureHelper $Action $DbPath @AdditionalArguments)
    if ($LASTEXITCODE -ne 0) {
        throw "Fixture database helper failed for action '$Action' with exit code $LASTEXITCODE."
    }
    return (($output | Out-String).Trim())
}

function Set-CcSwitchSettings {
    param(
        [Parameter(Mandatory = $true)]$Case,
        [Parameter(Mandatory = $true)][string]$ProviderId
    )

    $settings = [ordered]@{
        currentProviderCodex = $ProviderId
        fixture = $true
    }
    Write-Utf8NoBom -Path (Join-Path $Case.CcSwitchRoot 'settings.json') `
        -Content (($settings | ConvertTo-Json -Depth 4) + "`n")
}

function Set-CurrentProvider {
    param(
        [Parameter(Mandatory = $true)]$Case,
        [Parameter(Mandatory = $true)][string]$ProviderId
    )

    Invoke-FixtureDb -Action switch -DbPath $Case.DbPath -AdditionalArguments @($ProviderId) | Out-Null
    Set-CcSwitchSettings -Case $Case -ProviderId $ProviderId
}

function New-TestCase {
    param([Parameter(Mandatory = $true)][string]$Name)

    $script:CaseCounter++
    $root = Join-Path $script:SuiteRoot ("c\{0:D2}-{1}" -f $script:CaseCounter, [guid]::NewGuid().ToString('N').Substring(0, 4))
    $userRoot = Join-Path $root 'user'
    $appData = Join-Path $userRoot 'AppData\Roaming'
    $prodexRoot = Join-Path $userRoot '.prodex'
    $currentHome = Join-Path $prodexRoot 'manual-homes\ccswitch-current'
    $reviewerAgentsRoot = Join-Path $currentHome 'agents'
    $runHomesRoot = Join-Path $prodexRoot 'manual-homes\ccswitch-runs'
    $sharedCodexHome = Join-Path $root 'shared-codex'
    $ccSwitchRoot = Join-Path $userRoot '.cc-switch'
    $globalCodexRoot = Join-Path $userRoot '.codex'
    $reviewSkillRoot = Join-Path $userRoot '.codex\skills\multi-agent-review'

    foreach ($directory in @(
        $appData,
        (Join-Path $currentHome 'skills'),
        $reviewerAgentsRoot,
        (Split-Path -Parent $runHomesRoot),
        $reviewSkillRoot,
        $globalCodexRoot,
        $sharedCodexHome,
        $ccSwitchRoot
    )) {
        [IO.Directory]::CreateDirectory($directory) | Out-Null
    }
    $fixtureAgents = "# Fixture rules`n使用桌面或浏览器自动化时，只控制普通窗口化目标；目标处于全屏、无边框全屏或最大化时立即停止并请用户切换到普通窗口，不主动进入、保持或切换到这些显示状态，也不主动最大化窗口。`n自动化输入前必须重新确认唯一目标窗口、窗口边界和普通窗口状态。`n从 codex-focusfixed-current.txt 解析并直接调用 .exe，禁止经过 codex wrapper。`n"
    $fixtureReviewSkill = "---`nname: multi-agent-review`ndescription: Fixture review skill.`n---`nResolve codex-focusfixed-current.txt and invoke the verified .exe directly with --sandbox read-only --disable hooks --disable plugins; reject bypass and full-access.`n"
    $fixtureHooks = @'
{
  "hooks": {
    "SessionStart": [
      {"hooks": [{"type": "command", "command": "fixture-session-start-0"}]},
      {"hooks": [{"type": "command", "command": "fixture-session-start-1"}]}
    ],
    "UserPromptSubmit": [
      {"hooks": [{"type": "command", "command": "fixture-user-prompt"}]}
    ],
    "Stop": [
      {"hooks": [{"type": "command", "command": "fixture-stop"}]}
    ],
    "PreCompact": [
      {"hooks": [{"type": "command", "command": "fixture-pre-compact"}]}
    ]
  }
}
'@
    $globalHooksPath = Join-Path $globalCodexRoot 'hooks.json'
    $fixtureHookKeys = @(
        'session_start:0:0',
        'session_start:1:0',
        'user_prompt_submit:0:0',
        'stop:0:0',
        'pre_compact:0:0'
    )
    $fixtureConfigLines = [Collections.Generic.List[string]]::new()
    $fixtureConfigLines.Add('["hooks"]')
    $fixtureConfigLines.Add('["hooks"."state"]')
    foreach ($hookKey in $fixtureHookKeys) {
        $fixtureConfigLines.Add("[hooks.state.'$globalHooksPath`:$hookKey']")
        $fixtureConfigLines.Add("trusted_hash = `"sha256:$('a' * 64)`"")
    }
    $fixtureConfig = ($fixtureConfigLines -join "`n") + "`n"
    Write-Utf8NoBom -Path (Join-Path $currentHome 'AGENTS.md') -Content $fixtureAgents
    Write-Utf8NoBom -Path (Join-Path $reviewSkillRoot 'SKILL.md') -Content $fixtureReviewSkill
    Write-Utf8NoBom -Path $globalHooksPath -Content $fixtureHooks
    Write-Utf8NoBom -Path (Join-Path $globalCodexRoot 'config.toml') -Content $fixtureConfig
    foreach ($reviewerAgent in @('skeptic-reviewer', 'verifier')) {
        $reviewerConfig = "name = `"$reviewerAgent`"`nmodel_reasoning_effort = `"high`"`nsandbox_mode = `"read-only`"`ndeveloper_instructions = `"Fixture reviewer. Treat this profile's read-only sandbox setting as a request that the runtime may inherit or ignore. Do not edit files or change external state. Do not commit, create or switch branches, modify refs, add labels/comments, or send external messages. Do not spawn subagents.`"`n"
        Write-Utf8NoBom -Path (Join-Path $reviewerAgentsRoot "$reviewerAgent.toml") -Content $reviewerConfig
    }
    $case = [pscustomobject]@{
        Name = $Name
        Root = $root
        UserRoot = $userRoot
        AppData = $appData
        ProdexRoot = $prodexRoot
        CurrentHome = $currentHome
        GlobalCodexHome = $globalCodexRoot
        SharedCodexHome = $sharedCodexHome
        RunHomesRoot = $runHomesRoot
        CcSwitchRoot = $ccSwitchRoot
        ReviewerAgentsRoot = $reviewerAgentsRoot
        DbPath = Join-Path $ccSwitchRoot 'cc-switch.db'
        StatePath = Join-Path $prodexRoot 'state.json'
    }
    Invoke-FixtureDb -Action create -DbPath $case.DbPath | Out-Null
    Set-CcSwitchSettings -Case $case -ProviderId 'provider-a'
    Set-CaseEnvironment -Case $case
    return $case
}

function Get-RunDirectories {
    param([Parameter(Mandatory = $true)]$Case)

    if (-not (Test-Path -LiteralPath $Case.RunHomesRoot -PathType Container)) {
        return @()
    }
    return @(Get-ChildItem -LiteralPath $Case.RunHomesRoot -Directory -Force |
        Select-Object -ExpandProperty FullName |
        Sort-Object)
}

function Get-ProdexState {
    param([Parameter(Mandatory = $true)][string]$ProdexHome)
    return (Get-Content -LiteralPath (Join-Path $ProdexHome 'state.json') -Raw | ConvertFrom-Json)
}

function Get-OptionalFileContent {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return '<absent>'
    }
    return Get-Content -LiteralPath $Path -Raw
}

function Get-ProviderState {
    param(
        [Parameter(Mandatory = $true)]$Case,
        [Parameter(Mandatory = $true)][string]$ProviderId
    )

    $providers = Invoke-FixtureDb -Action read -DbPath $Case.DbPath | ConvertFrom-Json
    $matches = @($providers | Where-Object { $_.id -eq $ProviderId })
    Assert-Equal -Expected 1 -Actual $matches.Count -Because "provider '$ProviderId' must exist exactly once"
    return $matches[0]
}

function Set-ProviderConfig {
    param(
        [Parameter(Mandatory = $true)]$Case,
        [Parameter(Mandatory = $true)][string]$ProviderId,
        [Parameter(Mandatory = $true)][string]$Config
    )

    $configPath = Join-Path $Case.Root ("provider-config-{0}-{1}.toml" -f $ProviderId, [guid]::NewGuid().ToString('N'))
    Write-Utf8NoBom -Path $configPath -Content $Config
    try {
        Invoke-FixtureDb -Action replace-config `
            -DbPath $Case.DbPath `
            -AdditionalArguments @($ProviderId, $configPath) | Out-Null
    } finally {
        Remove-Item -LiteralPath $configPath -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-Materialize {
    param(
        [Parameter(Mandatory = $true)]$Case,
        [ValidateSet('direct', 'prodex')][string]$LaunchMode = 'prodex'
    )

    Set-CaseEnvironment -Case $Case
    $output = @(& $script:MaterializeSource `
        -Quiet `
        -CcSwitchRoot $Case.CcSwitchRoot `
        -ProdexScript $script:ProdexScript `
        -LaunchMode $LaunchMode)
    $jsonLine = @($output | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Last 1)
    Assert-Equal -Expected 1 -Actual $jsonLine.Count -Because 'materialize must return one final JSON metadata line'
    return ($jsonLine[0] | ConvertFrom-Json)
}

function Assert-MaterializeFailsClosed {
    param(
        [Parameter(Mandatory = $true)]$Case,
        [string]$ExpectedMessagePattern = '*Unable to capture a stable*'
    )

    Set-CaseEnvironment -Case $Case
    $stateBefore = Get-OptionalFileContent -Path $Case.StatePath
    $runHomesBefore = @(Get-RunDirectories -Case $Case)
    $caught = $null
    try {
        $null = & $script:MaterializeSource `
            -Quiet `
            -CcSwitchRoot $Case.CcSwitchRoot `
            -ProdexScript $script:ProdexScript
    } catch {
        $caught = $_
    }
    Assert-True -Condition ($null -ne $caught) -Because 'an unstable or unavailable provider snapshot must fail'
    Assert-True -Condition ($caught.Exception.Message -like $ExpectedMessagePattern) `
        -Because "failure must match the expected closed boundary: $ExpectedMessagePattern"
    Assert-Equal -Expected $stateBefore -Actual (Get-OptionalFileContent -Path $Case.StatePath) `
        -Because 'failed materialize must not mutate Prodex state'
    Assert-SequenceEqual -Expected $runHomesBefore -Actual @(Get-RunDirectories -Case $Case) `
        -Because 'failed materialize must not publish a run home'
}

function Set-RunModel {
    param(
        [Parameter(Mandatory = $true)][string]$RunHome,
        [Parameter(Mandatory = $true)][string]$Model,
        [Parameter(Mandatory = $true)][string]$Effort
    )

    $configPath = Join-Path $RunHome 'config.toml'
    $config = Get-Content -LiteralPath $configPath -Raw
    Assert-Equal -Expected 1 -Actual ([regex]::Matches($config, '(?m)^model\s*=.*$')).Count `
        -Because 'fixture run config must have one top-level model assignment'
    Assert-Equal -Expected 1 -Actual ([regex]::Matches($config, '(?m)^model_reasoning_effort\s*=.*$')).Count `
        -Because 'fixture run config must have one top-level effort assignment'
    $config = [regex]::Replace($config, '(?m)^model\s*=.*$', ('model = "{0}"' -f $Model))
    $config = [regex]::Replace($config, '(?m)^model_reasoning_effort\s*=.*$', ('model_reasoning_effort = "{0}"' -f $Effort))
    Write-Utf8NoBom -Path $configPath -Content $config
}

function Set-RunEffort {
    param(
        [Parameter(Mandatory = $true)][string]$RunHome,
        [Parameter(Mandatory = $true)][string]$Effort
    )

    $configPath = Join-Path $RunHome 'config.toml'
    $config = Get-Content -LiteralPath $configPath -Raw
    Assert-Equal -Expected 1 -Actual ([regex]::Matches($config, '(?m)^model_reasoning_effort\s*=.*$')).Count `
        -Because 'fixture run config must have one top-level effort assignment'
    $config = [regex]::Replace(
        $config,
        '(?m)^model_reasoning_effort\s*=.*$',
        ('model_reasoning_effort = "{0}"' -f $Effort)
    )
    Write-Utf8NoBom -Path $configPath -Content $config
}

function Add-RunModel {
    param(
        [Parameter(Mandatory = $true)][string]$RunHome,
        [Parameter(Mandatory = $true)][string]$Model
    )

    $configPath = Join-Path $RunHome 'config.toml'
    $config = Get-Content -LiteralPath $configPath -Raw
    Assert-Equal -Expected 0 -Actual ([regex]::Matches($config, '(?m)^model\s*=.*$')).Count `
        -Because 'the provider-default fixture must not already have a model assignment'
    Write-Utf8NoBom -Path $configPath -Content ((('model = "{0}"' -f $Model) + "`n") + $config)
}

function Remove-RunModel {
    param([Parameter(Mandatory = $true)][string]$RunHome)

    $configPath = Join-Path $RunHome 'config.toml'
    $config = Get-Content -LiteralPath $configPath -Raw
    Assert-Equal -Expected 1 -Actual ([regex]::Matches($config, '(?m)^model\s*=.*(?:\r?\n)?')).Count `
        -Because 'the fixture must have one model assignment to remove'
    $updated = [regex]::Replace($config, '(?m)^model\s*=.*(?:\r?\n)?', '')
    Write-Utf8NoBom -Path $configPath -Content $updated
}

function Invoke-Persist {
    param(
        [Parameter(Mandatory = $true)]$Case,
        [Parameter(Mandatory = $true)][string]$RunHome,
        [Nullable[long]]$ExitOrder = $null,
        [string[]]$ChangedFields = @(),
        [string]$SyncScript = ''
    )

    Set-CaseEnvironment -Case $Case
    if ([string]::IsNullOrWhiteSpace($SyncScript)) {
        $SyncScript = Join-Path $Case.Root 'not-used-sync.ps1'
    }
    $persistArguments = @{
        RunHome = $RunHome
        CcSwitchRoot = $Case.CcSwitchRoot
        AllowedRunHomesRoot = $Case.RunHomesRoot
        SyncScript = $SyncScript
        Json = $true
    }
    if ($null -ne $ExitOrder) {
        $persistArguments.ExitOrder = [long]$ExitOrder
    }
    if ($ChangedFields.Count -gt 0) {
        $persistArguments.ChangedFieldsCsv = $ChangedFields -join ','
    }
    $output = @(& $script:PersistSource @persistArguments)
    $jsonLine = @($output | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Last 1)
    Assert-Equal -Expected 1 -Actual $jsonLine.Count -Because 'persist must return one final JSON result line'
    return ($jsonLine[0] | ConvertFrom-Json)
}

function Wait-ForCondition {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Condition,
        [Parameter(Mandatory = $true)][string]$Because,
        [int]$TimeoutMilliseconds = 10000
    )

    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (& $Condition) {
            return
        }
        Start-Sleep -Milliseconds 100
    }
    throw "Timed out waiting because $Because"
}

function Start-CapturedProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [hashtable]$Environment = @{},
        [AllowNull()][string]$StandardInput = $null
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.RedirectStandardInput = $null -ne $StandardInput
    foreach ($argument in $Arguments) {
        $startInfo.ArgumentList.Add($argument)
    }
    foreach ($entry in $Environment.GetEnumerator()) {
        $startInfo.Environment[[string]$entry.Key] = [string]$entry.Value
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw "Unable to start process: $FilePath"
    }
    if ($null -ne $StandardInput) {
        $process.StandardInput.Write($StandardInput)
        $process.StandardInput.Close()
    }
    return [pscustomobject]@{
        Process = $process
        StandardOutput = $process.StandardOutput.ReadToEndAsync()
        StandardError = $process.StandardError.ReadToEndAsync()
    }
}

function Complete-CapturedProcess {
    param(
        [Parameter(Mandatory = $true)]$Handle,
        [int]$TimeoutMilliseconds = 60000
    )

    if (-not $Handle.Process.WaitForExit($TimeoutMilliseconds)) {
        $Handle.Process.Kill($true)
        $Handle.Process.WaitForExit()
        throw "Process timed out: $($Handle.Process.StartInfo.FileName)"
    }
    $result = [pscustomobject]@{
        ExitCode = $Handle.Process.ExitCode
        StandardOutput = $Handle.StandardOutput.GetAwaiter().GetResult()
        StandardError = $Handle.StandardError.GetAwaiter().GetResult()
    }
    $Handle.Process.Dispose()
    return $result
}

function Stop-CapturedProcess {
    param([AllowNull()]$Handle)

    if ($null -eq $Handle) { return }
    try {
        if (-not $Handle.Process.HasExited) {
            $Handle.Process.Kill($true)
            $Handle.Process.WaitForExit()
        }
    } finally {
        $Handle.Process.Dispose()
    }
}

function ConvertTo-GitBashPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path).Replace('\', '/')
    if ($fullPath -match '^([A-Za-z]):/(.*)$') {
        return ('/{0}/{1}' -f $matches[1].ToLowerInvariant(), $matches[2])
    }
    return $fullPath
}

function Get-ExpectedTrustedProjectOverride {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    $normalizedRoot = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\').ToLowerInvariant()
    return "projects={ '$normalizedRoot' = { trust_level = 'trusted' } }"
}

function New-LauncherFixture {
    $case = New-TestCase -Name 'launcher'
    $binRoot = Join-Path $case.ProdexRoot 'bin'
    $runHome = Join-Path $case.RunHomesRoot 'launcher-run'
    $historicalSessionId = '019f4af6-a117-7390-8db9-4acba1728e96'
    $historicalRunHome = Join-Path $case.RunHomesRoot 'historical-run'
    $historicalProdexHome = Join-Path $historicalRunHome '.prodex-runtime'
    $codexBinRoot = Join-Path $case.UserRoot '.codex\bin'
    $fixedBinary = Join-Path $codexBinRoot 'codex-focusfixed-fixture.exe'
    $launcherPath = Join-Path $binRoot 'invoke-ccswitch-codex.ps1'
    $materializePath = Join-Path $binRoot 'materialize-ccswitch-codex-run.ps1'
    $persistPath = Join-Path $binRoot 'persist-run-model.ps1'
    $watcherPath = Join-Path $binRoot 'watch-run-model.ps1'
    $rootResolverPath = Join-Path $binRoot 'resolve-ccswitch-root.ps1'
    $updateCheckPath = Join-Path $codexBinRoot 'check-codex-update.ps1'
    $prodexPath = Join-Path $case.AppData 'npm\prodex.ps1'

    foreach ($directory in @(
        $binRoot,
        $runHome,
        $historicalProdexHome,
        (Join-Path $historicalRunHome 'sessions\2026\07\10'),
        $codexBinRoot,
        (Join-Path $case.UserRoot 'Documents\Codex-Contexts')
    )) {
        [IO.Directory]::CreateDirectory($directory) | Out-Null
    }
    Copy-Item -LiteralPath $script:LauncherSource -Destination $launcherPath -Force
    Copy-Item -LiteralPath $script:WatcherSource -Destination $watcherPath -Force
    Copy-Item -LiteralPath $script:RootResolverSource -Destination $rootResolverPath -Force
    Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\curl.exe') -Destination $fixedBinary -Force
    Write-Utf8NoBom -Path (Join-Path $codexBinRoot 'codex-focusfixed-current.txt') -Content $fixedBinary
    $fixedMetadata = [ordered]@{
        schemaVersion = 2
        patchedExe = $fixedBinary
        sha256 = (Get-FileHash -LiteralPath $fixedBinary -Algorithm SHA256).Hash
        enableAfter = 0
        disableAfter = 2
    }
    Write-Utf8NoBom -Path (Join-Path $codexBinRoot 'codex-focusfixed-current.json') `
        -Content (($fixedMetadata | ConvertTo-Json -Depth 4) + "`n")

$fakeMaterialize = @'
[CmdletBinding()]
param(
    [switch]$Quiet,
    [string]$CcSwitchRoot = '',
    [ValidateSet('direct', 'prodex')][string]$LaunchMode = 'prodex'
)
[IO.File]::WriteAllText($env:FAKE_MATERIALIZE_LOG, $env:PRODEX_HOME)
$privateProdexHome = Join-Path $env:FAKE_RUN_HOME '.prodex-runtime'
[IO.Directory]::CreateDirectory($privateProdexHome) | Out-Null
[IO.File]::WriteAllText(
    (Join-Path $env:FAKE_RUN_HOME 'config.toml'),
    "model_reasoning_effort = `"ultra`"`n",
    [Text.UTF8Encoding]::new($false)
)
[pscustomobject]@{
    schemaVersion = 2
    profileName = 'fixture-profile'
    codexHome = $env:FAKE_RUN_HOME
    prodexHome = $privateProdexHome
    providerId = 'provider-a'
    providerName = 'Provider A'
    ccSwitchRoot = $CcSwitchRoot
    model = $null
    modelReasoningEffort = 'ultra'
    launchMode = $LaunchMode
} | ConvertTo-Json -Compress
'@
    $fakePersist = @'
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RunHome,
    [long]$ExitOrder,
    [string]$CcSwitchRoot,
    [string]$AllowedRunHomesRoot,
    [string]$ChangedFieldsCsv,
    [switch]$Json
)
[IO.File]::AppendAllText($env:FAKE_PERSIST_LOG, $RunHome + [Environment]::NewLine)
[IO.File]::WriteAllText($env:FAKE_PERSIST_ARGS_LOG, ([ordered]@{
    runHome = $RunHome
    allowedRunHomesRoot = $AllowedRunHomesRoot
} | ConvertTo-Json -Compress))
if ($env:FAKE_PERSIST_FAIL -eq '1') {
    '{"ok":false,"status":"failed","errorCode":"fixture_failure","message":"fixture persist failure"}'
    exit 2
}
if ($Json) {
    '{"ok":true,"status":"skipped"}'
}
'@
    $fakeProdex = @'
$payload = [ordered]@{
    arguments = @($args)
    codexBin = $env:PRODEX_CODEX_BIN
    prodexHome = $env:PRODEX_HOME
    codexHome = $env:CODEX_HOME
    openAiEnvironment = @(
        [Environment]::GetEnvironmentVariables('Process').Keys |
            Where-Object { [string]$_ -like 'OPENAI_*' } |
            Sort-Object
    )
    workingDirectory = (Get-Location).ProviderPath
}
[IO.File]::WriteAllText(
    $env:FAKE_PRODEX_LOG,
    (($payload | ConvertTo-Json -Depth 5 -Compress) + [Environment]::NewLine),
    [Text.UTF8Encoding]::new($false)
)
if ($env:FAKE_PRODEX_STOP -eq '1') {
    throw [Management.Automation.PipelineStoppedException]::new()
}
$exitCode = [int]$env:FAKE_CODEX_EXIT
& $env:ComSpec /d /c "exit $exitCode"
'@
    Write-Utf8NoBom -Path $materializePath -Content $fakeMaterialize
    Write-Utf8NoBom -Path $persistPath -Content $fakePersist
    Write-Utf8NoBom -Path $prodexPath -Content $fakeProdex
    $historicalMetadata = [ordered]@{
        schemaVersion = 2
        profileName = 'historical-profile'
        codexHome = $historicalRunHome
        prodexHome = $historicalProdexHome
        providerId = 'provider-history'
        providerName = 'Historical Provider'
        ccSwitchRoot = $case.CcSwitchRoot
        model = 'historical-model'
        modelReasoningEffort = 'high'
    }
    Write-Utf8NoBom -Path (Join-Path $historicalRunHome 'run-provider.json') `
        -Content (($historicalMetadata | ConvertTo-Json -Depth 5) + "`n")
    Write-Utf8NoBom -Path (Join-Path $historicalProdexHome 'state.json') -Content '{}'
    Write-Utf8NoBom `
        -Path (Join-Path $historicalRunHome "sessions\2026\07\10\rollout-2026-07-10T15-38-24-$historicalSessionId.jsonl") `
        -Content '{}'

    $case | Add-Member -NotePropertyName LauncherPath -NotePropertyValue $launcherPath
    $case | Add-Member -NotePropertyName RunHome -NotePropertyValue $runHome
    $case | Add-Member -NotePropertyName HistoricalRunHome -NotePropertyValue $historicalRunHome
    $case | Add-Member -NotePropertyName HistoricalProdexHome -NotePropertyValue $historicalProdexHome
    $case | Add-Member -NotePropertyName HistoricalSessionId -NotePropertyValue $historicalSessionId
    $case | Add-Member -NotePropertyName FixedBinary -NotePropertyValue $fixedBinary
    $case | Add-Member -NotePropertyName UpdateCheckPath -NotePropertyValue $updateCheckPath
    return $case
}

function Install-FakeProdexCommand {
    param([Parameter(Mandatory = $true)]$Case)

    $npmRoot = Join-Path $Case.AppData 'npm'
    $backendPath = Join-Path $npmRoot 'prodex-cmd-backend.ps1'
    $commandPath = Join-Path $npmRoot 'prodex.cmd'
    $backend = @'
$payload = [ordered]@{
    arguments = @($args)
    codexBin = $env:PRODEX_CODEX_BIN
    prodexHome = $env:PRODEX_HOME
    workingDirectory = (Get-Location).ProviderPath
}
[IO.File]::WriteAllText(
    $env:FAKE_PRODEX_LOG,
    (($payload | ConvertTo-Json -Depth 5 -Compress) + [Environment]::NewLine),
    [Text.UTF8Encoding]::new($false)
)
exit ([int]$env:FAKE_CODEX_EXIT)
'@
    $command = @'
@echo off
echo [ Update Available ] ==================================== 1>&2
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0prodex-cmd-backend.ps1" %*
exit /b %ERRORLEVEL%
'@
    Write-Utf8NoBom -Path $backendPath -Content $backend
    Write-Utf8NoBom -Path $commandPath -Content $command
}

function Get-LauncherEnvironment {
    param(
        [Parameter(Mandatory = $true)]$Case,
        [Parameter(Mandatory = $true)][string]$ProdexLog,
        [Parameter(Mandatory = $true)][string]$PersistLog,
        [bool]$PersistFails = $false,
        [bool]$ProdexStops = $false
    )

    return @{
        USERPROFILE = $Case.UserRoot
        HOME = $Case.UserRoot
        APPDATA = $Case.AppData
        PRODEX_HOME = $Case.ProdexRoot
        PRODEX_SHARED_CODEX_HOME = $Case.SharedCodexHome
        PRODEX_CODEX_BIN = $script:CodexBinary
        CCSWITCH_CODEX_LAUNCH_MODE = 'prodex'
        FAKE_RUN_HOME = $Case.RunHome
        FAKE_MATERIALIZE_LOG = $ProdexLog + '.materialize-home.txt'
        FAKE_PRODEX_LOG = $ProdexLog
        FAKE_PERSIST_LOG = $PersistLog
        FAKE_PERSIST_ARGS_LOG = $PersistLog + '.args.json'
        FAKE_PERSIST_FAIL = if ($PersistFails) { '1' } else { '0' }
        FAKE_PRODEX_STOP = if ($ProdexStops) { '1' } else { '0' }
        FAKE_CODEX_EXIT = '37'
    }
}

function Get-LaunchSurfaceVariants {
    param([Parameter(Mandatory = $true)]$Case)

    $variants = [Collections.Generic.List[object]]::new()
    $variants.Add([pscustomobject]@{
        Name = 'PowerShell 7 launcher'
        FilePath = $script:Pwsh
        Arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Case.LauncherPath)
    })
    $variants.Add([pscustomobject]@{
        Name = 'PowerShell 7 shim'
        FilePath = $script:Pwsh
        Arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $script:RepoRoot 'scripts\shims\codex.ps1'))
    })

    $windowsPowerShell = Get-Command powershell.exe -ErrorAction SilentlyContinue
    if ($null -eq $windowsPowerShell) {
        $script:ShellSkips.Add('Windows PowerShell 5.1: powershell.exe not found')
    } else {
        $variants.Add([pscustomobject]@{
            Name = 'Windows PowerShell 5.1 launcher'
            FilePath = $windowsPowerShell.Source
            Arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Case.LauncherPath)
        })
    }

    $cmd = Get-Command cmd.exe -ErrorAction SilentlyContinue
    if ($null -eq $cmd) {
        $script:ShellSkips.Add('CMD shim: cmd.exe not found')
    } else {
        $variants.Add([pscustomobject]@{
            Name = 'CMD shim'
            FilePath = $cmd.Source
            Arguments = @('/D', '/S', '/C', (Join-Path $script:RepoRoot 'scripts\shims\codex.cmd'))
        })
    }

    $gitBashCandidates = @(
        (Join-Path $env:ProgramFiles 'Git\bin\bash.exe'),
        (Join-Path $env:ProgramFiles 'Git\usr\bin\bash.exe')
    )
    $gitBash = @($gitBashCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1)
    if ($gitBash.Count -eq 0) {
        $script:ShellSkips.Add('Git Bash shim: Git for Windows bash.exe not found')
    } else {
        $variants.Add([pscustomobject]@{
            Name = 'Git Bash shim'
            FilePath = $gitBash[0]
            Arguments = @('--noprofile', '--norc', (ConvertTo-GitBashPath (Join-Path $script:RepoRoot 'scripts\shims\codex')))
        })
    }
    return @($variants)
}

function Remove-SuiteRoot {
    if (-not (Test-Path -LiteralPath $script:SuiteRoot)) { return }

    $resolvedRoot = [IO.Path]::GetFullPath($script:SuiteRoot).TrimEnd('\', '/')
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
    $expectedPrefix = $tempRoot + [IO.Path]::DirectorySeparatorChar
    if (-not $resolvedRoot.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        -not ([IO.Path]::GetFileName($resolvedRoot)).StartsWith('ccsi-', [StringComparison]::Ordinal)) {
        throw "Refusing to remove unexpected suite path: $resolvedRoot"
    }
    Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
}

[IO.Directory]::CreateDirectory($script:SuiteRoot) | Out-Null
Assert-True -Condition (Test-Path -LiteralPath $script:ProdexScript -PathType Leaf) `
    -Because "the installed Prodex launcher must exist at '$script:ProdexScript'"
Assert-True -Condition (
    -not [string]::IsNullOrWhiteSpace($script:CodexBinary) -and
    (Test-Path -LiteralPath $script:CodexBinary -PathType Leaf)
) -Because 'a fixed Codex executable must exist for the real Prodex version-chain test'
$script:FixtureHelper = New-FixtureHelper
$script:LockHelper = New-LockHelper
$script:MirrorLockHelper = New-MirrorLockHelper
$script:MaterializeRunHelper = New-MaterializeRunHelper

try {
    Invoke-TestCase -Name 'materialize_A_then_B_keeps_each_snapshot_isolated' -Body {
        $case = New-TestCase -Name 'materialize-isolation'
        $snapshotA = Invoke-Materialize -Case $case
        $configAPath = Join-Path $snapshotA.codexHome 'config.toml'
        $authAPath = Join-Path $snapshotA.codexHome 'auth.json'
        $configABefore = Get-Content -LiteralPath $configAPath -Raw
        $authABefore = Get-Content -LiteralPath $authAPath -Raw
        Assert-True -Condition ($configABefore -like '*base_url = "https://provider-a.invalid/v1"*') `
            -Because 'provider A URL must come from provider A settings'
        Assert-True -Condition ($authABefore -like '*TEST_TOKEN_PROVIDER_A*') `
            -Because 'provider A key must come from provider A settings'

        Set-CurrentProvider -Case $case -ProviderId 'provider-b'
        $snapshotB = Invoke-Materialize -Case $case
        $configBPath = Join-Path $snapshotB.codexHome 'config.toml'
        $authBPath = Join-Path $snapshotB.codexHome 'auth.json'

        Assert-Equal -Expected 'provider-a' -Actual ([string]$snapshotA.providerId) -Because 'the first run must bind provider A'
        Assert-Equal -Expected 'provider-b' -Actual ([string]$snapshotB.providerId) -Because 'the second run must bind provider B'
        Assert-Equal -Expected 'model-a' -Actual ([string]$snapshotA.model) -Because 'provider A model must be captured'
        Assert-Equal -Expected 'model-b' -Actual ([string]$snapshotB.model) -Because 'provider B model must be captured'
        Assert-Equal -Expected $configABefore -Actual (Get-Content -LiteralPath $configAPath -Raw) `
            -Because 'switching to B must not rewrite A config'
        Assert-Equal -Expected $authABefore -Actual (Get-Content -LiteralPath $authAPath -Raw) `
            -Because 'switching to B must not rewrite A auth'
        Assert-True -Condition ((Get-Content -LiteralPath $configBPath -Raw) -like '*base_url = "https://provider-b.invalid/v1"*') `
            -Because 'provider B URL must come from provider B settings'
        Assert-True -Condition ((Get-Content -LiteralPath $authBPath -Raw) -like '*TEST_TOKEN_PROVIDER_B*') `
            -Because 'provider B key must come from provider B settings'
        Assert-True -Condition ((Get-Content -LiteralPath $authBPath -Raw) -notlike '*TEST_TOKEN_PROVIDER_A*') `
            -Because 'provider B snapshot must not inherit provider A key'
    }

    Invoke-TestCase -Name 'resolver_fails_closed_when_multiple_roots_are_valid' -Body {
        $case = New-TestCase -Name 'multiple-ccswitch-roots'
        $secondRoot = Join-Path $case.AppData 'com.ccswitch.desktop'
        [IO.Directory]::CreateDirectory($secondRoot) | Out-Null
        Copy-Item -LiteralPath (Join-Path $case.CcSwitchRoot 'settings.json') `
            -Destination (Join-Path $secondRoot 'settings.json') -Force
        Copy-Item -LiteralPath $case.DbPath `
            -Destination (Join-Path $secondRoot 'cc-switch.db') -Force

        . $script:RootResolverSource
        $caught = $null
        try {
            Resolve-CcSwitchRoot `
                -UserRoot $case.UserRoot `
                -AppDataRoot $case.AppData | Out-Null
        } catch {
            $caught = $_
        }

        Assert-True -Condition ($null -ne $caught) `
            -Because 'default root resolution must fail closed when two valid roots exist'
        Assert-True -Condition ($caught.Exception.Message -like '*found 2*') `
            -Because 'the resolver error must identify the ambiguous root count'
    }

    # Regression for the 2026-08-02 incident where generated run homes lost global MCP servers.
    Invoke-TestCase -Name 'global_mcp_servers_survive_materialization_20260802_regression' -Body {
        $case = New-TestCase -Name 'global-mcp-materialization'
        $globalConfigPath = Join-Path $case.UserRoot '.codex\config.toml'
        $globalConfig = Get-Content -Raw -LiteralPath $globalConfigPath
        $globalConfig += @'

[mcp_servers.memory]
command = "fixture-node"
args = ["fixture-memory.mjs"]

[mcp_servers.memory.env]
MEMORY_DB_PATH = "fixture-memory.sqlite"
'@
        Write-Utf8NoBom -Path $globalConfigPath -Content $globalConfig

        $snapshot = Invoke-Materialize -Case $case -LaunchMode direct
        $materializedConfig = Get-Content -Raw -LiteralPath (Join-Path $snapshot.codexHome 'config.toml')
        $materializedMetadata = Get-Content -Raw -LiteralPath (Join-Path $snapshot.codexHome 'run-provider.json') | ConvertFrom-Json

        Assert-True -Condition ($materializedConfig.Contains('[mcp_servers.memory]')) `
            -Because 'the generated run home must preserve the global memory MCP table'
        Assert-True -Condition ($materializedConfig -like '*MEMORY_DB_PATH = "fixture-memory.sqlite"*') `
            -Because 'the generated run home must preserve the memory MCP environment'
        Assert-SequenceEqual -Expected @('memory') -Actual @($materializedMetadata.mcpServerNames) `
            -Because 'run metadata must record the exact materialized MCP server set'
        Assert-True -Condition ($materializedConfig -like '*model = "model-a"*') `
            -Because 'MCP merging must not replace the provider-owned model'
    }

    # Regression for the 2026-08-02 mirror-sync incident where model persistence
    # overwrote the global MCP overlay with provider-only configuration.
    Invoke-TestCase -Name 'global_mcp_servers_survive_model_persistence_mirror_sync_20260802_regression' -Body {
        $case = New-TestCase -Name 'global-mcp-mirror-sync'
        $globalConfigPath = Join-Path $case.GlobalCodexHome 'config.toml'
        $globalConfig = Get-Content -Raw -LiteralPath $globalConfigPath
        $globalConfig += @'

[mcp_servers.memory]
command = "fixture-node"
args = ["fixture-memory.mjs"]

[mcp_servers.memory.env]
MEMORY_DB_PATH = "fixture-memory.sqlite"
'@
        Write-Utf8NoBom -Path $globalConfigPath -Content $globalConfig

        $snapshot = Invoke-Materialize -Case $case -LaunchMode direct
        Set-RunModel -RunHome $snapshot.codexHome -Model 'model-after-mirror' -Effort 'ultra'
        $persistence = Invoke-Persist `
            -Case $case `
            -RunHome $snapshot.codexHome `
            -SyncScript $script:SyncSource

        Assert-Equal -Expected 'updated' -Actual ([string]$persistence.status) `
            -Because 'model persistence must update the provider before mirror synchronization'
        Assert-Equal -Expected 'synced' -Actual ([string]$persistence.mirrors.globalCodex) `
            -Because 'model persistence must report the global Codex mirror as synchronized'
        Assert-Equal -Expected 'synced' -Actual ([string]$persistence.mirrors.ccswitchCurrent) `
            -Because 'model persistence must report the current CC Switch mirror as synchronized'

        foreach ($codexHome in @($case.GlobalCodexHome, $case.CurrentHome)) {
            $syncedConfig = Get-Content -Raw -LiteralPath (Join-Path $codexHome 'config.toml')
            Assert-True -Condition ($syncedConfig.Contains('[mcp_servers.memory]')) `
                -Because "mirror sync must preserve the global memory MCP in $codexHome"
            Assert-True -Condition ($syncedConfig.Contains('MEMORY_DB_PATH = "fixture-memory.sqlite"')) `
                -Because "mirror sync must preserve the memory database path in $codexHome"
            Assert-True -Condition ($syncedConfig.Contains('model = "model-after-mirror"')) `
                -Because "mirror sync must retain the current provider model in $codexHome"
        }

        $providerState = Get-ProviderState -Case $case -ProviderId 'provider-a'
        $providerSettings = $providerState.settingsRaw | ConvertFrom-Json
        Assert-True -Condition (-not ([string]$providerSettings.config).Contains('[mcp_servers.memory]')) `
            -Because 'the provider-owned configuration must not absorb the global MCP overlay'

        $nextSnapshot = Invoke-Materialize -Case $case -LaunchMode direct
        $nextConfig = Get-Content -Raw -LiteralPath (Join-Path $nextSnapshot.codexHome 'config.toml')
        Assert-True -Condition ($nextConfig.Contains('[mcp_servers.memory]')) `
            -Because 'a later run must retain the MCP after model persistence and mirror sync'
    }

    # Regression for the 2026-08-02 fail-open path where a missing hook trust
    # entry was silently omitted from the provider mirror.
    Invoke-TestCase -Name 'mirror_sync_fails_when_command_hook_trust_is_missing_20260802_regression' -Body {
        $case = New-TestCase -Name 'missing-command-hook-trust'
        $globalConfigPath = Join-Path $case.GlobalCodexHome 'config.toml'
        $globalHooksPath = Join-Path $case.GlobalCodexHome 'hooks.json'
        $before = Get-Content -Raw -LiteralPath $globalConfigPath
        $trustKey = '{0}:pre_compact:0:0' -f $globalHooksPath
        $trustPattern = "(?m)^\[hooks\.state\.'" +
            [regex]::Escape($trustKey) +
            "'\][ \t]*\r?\ntrusted_hash\s*=\s*""[^""]+""\r?\n?"
        $trustRegex = [regex]::new($trustPattern)
        $after = $trustRegex.Replace($before, '', 1)
        Assert-True -Condition ($after -ne $before) `
            -Because 'the fixture must remove exactly one command-hook trust entry'
        Write-Utf8NoBom -Path $globalConfigPath -Content $after

        Set-CaseEnvironment -Case $case
        $caught = $null
        try {
            $null = @(& $script:SyncSource `
                -CcSwitchRoot $case.CcSwitchRoot `
                -CodexHome @($case.GlobalCodexHome) `
                -CheckOnly `
                -Quiet)
        } catch {
            $caught = $_
        }

        Assert-True -Condition ($null -ne $caught) `
            -Because 'mirror sync must fail closed when a command hook has no trust entry'
        Assert-Equal -Expected $after -Actual (Get-Content -Raw -LiteralPath $globalConfigPath) `
            -Because 'a failed trust validation must not rewrite the global config'
    }

    # Regression for provider configs that serialize equivalent TOML tables with quoted keys.
    Invoke-TestCase -Name 'mirror_sync_accepts_quoted_provider_hook_state_tables_20260802_regression' -Body {
        $case = New-TestCase -Name 'quoted-provider-hook-state'
        $globalHooksPath = Join-Path $case.GlobalCodexHome 'hooks.json'
        $globalConfigPath = Join-Path $case.GlobalCodexHome 'config.toml'
        $globalConfigBefore = Get-Content -Raw -LiteralPath $globalConfigPath
        Invoke-FixtureDb -Action add-quoted-hook-trust `
            -DbPath $case.DbPath `
            -AdditionalArguments @('provider-a', $globalHooksPath) | Out-Null

        Set-CaseEnvironment -Case $case
        $caught = $null
        try {
            $null = @(& $script:SyncSource `
                -CcSwitchRoot $case.CcSwitchRoot `
                -CodexHome @($case.CurrentHome) `
                -CheckOnly `
                -Quiet)
        } catch {
            $caught = $_
        }

        Assert-True -Condition ($null -eq $caught) `
            -Because 'mirror sync must accept semantically equivalent quoted provider hook tables'
        Assert-Equal -Expected $globalConfigBefore -Actual (Get-Content -Raw -LiteralPath $globalConfigPath) `
            -Because 'a check-only quoted-table sync must not rewrite the global config'
        Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $case.CurrentHome 'config.toml'))) `
            -Because 'a check-only quoted-table sync must not create the target config'
    }

    Invoke-TestCase -Name 'mirror_sync_normalizes_single_quoted_provider_hook_state_tables' -Body {
        $case = New-TestCase -Name 'single-quoted-provider-hook-state'
        $globalHooksPath = Join-Path $case.GlobalCodexHome 'hooks.json'
        Invoke-FixtureDb -Action add-single-quoted-hook-trust `
            -DbPath $case.DbPath `
            -AdditionalArguments @('provider-a', $globalHooksPath) | Out-Null

        Set-CaseEnvironment -Case $case
        $caught = $null
        try {
            $null = @(& $script:SyncSource `
                -CcSwitchRoot $case.CcSwitchRoot `
                -CodexHome @($case.CurrentHome) `
                -CheckOnly `
                -Quiet)
        } catch {
            $caught = $_
        }

        Assert-True -Condition ($null -eq $caught) `
            -Because 'mirror sync must accept single-quoted provider hook tables'
    }

    Invoke-TestCase -Name 'mirror_sync_deduplicates_mixed_provider_hook_state_tables' -Body {
        $case = New-TestCase -Name 'mixed-provider-hook-state'
        $globalHooksPath = Join-Path $case.GlobalCodexHome 'hooks.json'
        Invoke-FixtureDb -Action add-mixed-quoted-hook-trust `
            -DbPath $case.DbPath `
            -AdditionalArguments @('provider-a', $globalHooksPath) | Out-Null

        Set-CaseEnvironment -Case $case
        $caught = $null
        try {
            $null = @(& $script:SyncSource `
                -CcSwitchRoot $case.CcSwitchRoot `
                -CodexHome @($case.CurrentHome) `
                -CheckOnly `
                -Quiet)
        } catch {
            $caught = $_
        }

        Assert-True -Condition ($null -eq $caught) `
            -Because 'equivalent mixed hook tables must normalize without duplicate TOML keys'
    }

    Invoke-TestCase -Name 'mirror_sync_fails_when_global_sources_change_during_capture_20260802_regression' -Body {
        $case = New-TestCase -Name 'unstable-global-sources'
        Set-CaseEnvironment -Case $case
        $shimRoot = Join-Path $case.Root 'python-shim'
        [IO.Directory]::CreateDirectory($shimRoot) | Out-Null
        $shimPath = Join-Path $shimRoot 'python.cmd'
        $markerPath = Join-Path $case.Root 'python-shim-ran.marker'
        $globalConfigPath = Join-Path $case.GlobalCodexHome 'config.toml'
        $shimContent = @"
@echo off
if not exist "$markerPath" (
  type nul > "$markerPath"
  echo # fixture-source-change>>"$globalConfigPath"
)
"$script:Python" %*
exit /b %ERRORLEVEL%
"@
        Write-Utf8NoBom -Path $shimPath -Content $shimContent
        $pathBefore = $env:PATH
        $env:PATH = "$shimRoot;$pathBefore"
        $caught = $null
        try {
            $null = @(& $script:SyncSource `
                -CcSwitchRoot $case.CcSwitchRoot `
                -CodexHome @($case.CurrentHome) `
                -Quiet)
        } catch {
            $caught = $_
        } finally {
            $env:PATH = $pathBefore
        }

        Assert-True -Condition ($null -ne $caught) `
            -Because 'mirror sync must fail closed when global sources change after snapshot capture'
        Assert-True -Condition ((Get-Content -Raw -LiteralPath $globalConfigPath).Contains('# fixture-source-change')) `
            -Because 'the fixture must mutate the global source between snapshot capture and provider query'
        Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $case.CurrentHome 'config.toml'))) `
            -Because 'source drift must be rejected before any mirror target is written'
    }

    Invoke-TestCase -Name 'mirror_sync_rolls_back_when_global_sources_change_after_target_write' -Body {
        $case = New-TestCase -Name 'late-global-source-drift'
        Set-CaseEnvironment -Case $case
        $globalConfigPath = Join-Path $case.GlobalCodexHome 'config.toml'
        $targetHomes = @(1..80 | ForEach-Object {
            Join-Path $case.Root ('late-target-{0:D3}' -f $_)
        })
        $targetConfigPath = Join-Path $targetHomes[0] 'config.toml'
        $signalPath = Join-Path $case.Root 'late-source-change.signal'
        $watcherPath = Join-Path $case.Root 'mutate-after-target-write.ps1'
        $watcherCode = @'
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TargetConfigPath,
    [Parameter(Mandatory = $true)][string]$GlobalConfigPath,
    [Parameter(Mandatory = $true)][string]$SignalPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$deadline = [DateTime]::UtcNow.AddSeconds(15)
while ([DateTime]::UtcNow -lt $deadline) {
    if (Test-Path -LiteralPath $TargetConfigPath -PathType Leaf) {
        [IO.File]::AppendAllText(
            $GlobalConfigPath,
            "`n# fixture-late-source-change`n",
            [Text.UTF8Encoding]::new($false)
        )
        [IO.File]::WriteAllText($SignalPath, 'changed', [Text.UTF8Encoding]::new($false))
        exit 0
    }
    Start-Sleep -Milliseconds 10
}
exit 1
'@
        Write-Utf8NoBom -Path $watcherPath -Content $watcherCode
        $watcherHandle = Start-CapturedProcess `
            -FilePath $script:Pwsh `
            -Arguments @(
                '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                '-File', $watcherPath,
                '-TargetConfigPath', $targetConfigPath,
                '-GlobalConfigPath', $globalConfigPath,
                '-SignalPath', $signalPath
            ) `
            -WorkingDirectory $case.Root
        $caught = $null
        try {
            try {
                $null = @(& $script:SyncSource `
                    -CcSwitchRoot $case.CcSwitchRoot `
                    -CodexHome $targetHomes `
                    -Quiet)
            } catch {
                $caught = $_
            }
            $watcherResult = Complete-CapturedProcess -Handle $watcherHandle -TimeoutMilliseconds 20000
            $watcherHandle = $null

            Assert-True -Condition ($null -ne $caught) `
                -Because 'mirror sync must fail when global sources change after a target write'
            Assert-Equal -Expected 0 -Actual $watcherResult.ExitCode `
                -Because 'the fixture must mutate the source after the first target write'
            Assert-True -Condition ((Get-Content -Raw -LiteralPath $globalConfigPath).Contains('# fixture-late-source-change')) `
                -Because 'the fixture must change the global source after target writing begins'
            Assert-True -Condition (-not (Test-Path -LiteralPath $targetConfigPath -PathType Leaf)) `
                -Because 'late source drift must roll back the newly written target config'
            Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $case.CurrentHome 'auth.json') -PathType Leaf)) `
                -Because 'late source drift must roll back the newly written target auth'
            Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $case.CurrentHome 'hooks.json') -PathType Leaf)) `
                -Because 'late source drift must roll back the newly written target hooks'
        } finally {
            Stop-CapturedProcess -Handle $watcherHandle
        }
    }

    Invoke-TestCase -Name 'direct_materialization_skips_prodex_profile_registration' -Body {
        $case = New-TestCase -Name 'direct-materialize'
        $snapshot = Invoke-Materialize -Case $case -LaunchMode direct

        Assert-Equal -Expected 'direct' -Actual ([string]$snapshot.launchMode) `
            -Because 'direct materialization must record its launch mode'
        Assert-True -Condition (Test-Path -LiteralPath $snapshot.codexHome -PathType Container) `
            -Because 'direct materialization must publish the Codex home'
        Assert-True -Condition (Test-Path -LiteralPath $snapshot.prodexHome -PathType Container) `
            -Because 'direct materialization must preserve the persistence-compatible runtime path'
        Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $snapshot.prodexHome 'state.json'))) `
            -Because 'direct materialization must not register a Prodex profile'
        Assert-True -Condition (Test-Path -LiteralPath (Join-Path $snapshot.codexHome 'skills\multi-agent-review\SKILL.md') -PathType Leaf) `
            -Because 'direct materialization must include the multi-agent review skill'
        $materializedConfig = Get-Content -Raw -LiteralPath (Join-Path $snapshot.codexHome 'config.toml')
        $materializedHooksPath = Join-Path $snapshot.codexHome 'hooks.json'
        $localTrustPattern = "(?m)^\[hooks\.state\.'" +
            [regex]::Escape($materializedHooksPath) +
            ":[^']+'\]$"
        Assert-Equal -Expected 5 -Actual ([regex]::Matches($materializedConfig, $localTrustPattern).Count) `
            -Because 'every command hook must receive one run-local trusted hash'
        $materializedMetadata = Get-Content -Raw -LiteralPath (Join-Path $snapshot.codexHome 'run-provider.json') | ConvertFrom-Json
        Assert-Equal -Expected 5 -Actual @($materializedMetadata.hookTrustByKey.PSObject.Properties).Count `
            -Because 'metadata must preserve the exact global trust map used by staged validation'
        Assert-Equal -Expected (Get-Content -Raw -LiteralPath (Join-Path $case.UserRoot '.codex\hooks.json')) `
            -Actual (Get-Content -Raw -LiteralPath $materializedHooksPath) `
            -Because 'materialization must publish the exact hooks snapshot used for trust derivation'
        $materializedAgents = Get-Content -Raw -LiteralPath (Join-Path $snapshot.codexHome 'AGENTS.md')
        $materializedReviewSkill = Get-Content -Raw -LiteralPath (Join-Path $snapshot.codexHome 'skills\multi-agent-review\SKILL.md')
        Assert-True -Condition ($materializedAgents -like '*只控制普通窗口化目标*') `
            -Because 'direct materialization must preserve the windowed-only desktop automation rule'
        Assert-True -Condition ($materializedAgents -like '*全屏、无边框全屏或最大化时立即停止并请用户切换到普通窗口*') `
            -Because 'direct materialization must stop on every prohibited display state'
        Assert-True -Condition ($materializedAgents -like '*不主动最大化窗口*') `
            -Because 'direct materialization must forbid maximizing the automation target'
        Assert-True -Condition ($materializedAgents -like '*自动化输入前必须重新确认唯一目标窗口、窗口边界和普通窗口状态*') `
            -Because 'direct materialization must require a fresh window-state check before input'
        Assert-True -Condition ($materializedAgents -like '*禁止经过 codex wrapper*') `
            -Because 'direct materialization must preserve the direct-executable reviewer rule'
        Assert-True -Condition ($materializedReviewSkill -like '*--sandbox read-only --disable hooks --disable plugins*') `
            -Because 'direct materialization must preserve the enforced reviewer CLI arguments'
        Assert-True -Condition ($materializedReviewSkill -like '*reject bypass and full-access*') `
            -Because 'direct materialization must preserve the wrapper-bypass prohibition'
        foreach ($reviewerAgent in @('skeptic-reviewer', 'verifier')) {
            $reviewerConfigPath = Join-Path $snapshot.codexHome "agents\$reviewerAgent.toml"
            $reviewerConfig = Get-Content -Raw -LiteralPath $reviewerConfigPath
            Assert-True -Condition ($reviewerConfig -like '*sandbox_mode = "read-only"*') `
                -Because "$reviewerAgent must retain the read-only sandbox request in the materialized home"
            Assert-True -Condition ($reviewerConfig -like '*read-only sandbox setting as a request*') `
                -Because "$reviewerAgent must document that the request is not proof of runtime enforcement"
            Assert-True -Condition ($reviewerConfig -like '*Do not edit files or change external state.*') `
                -Because "$reviewerAgent must forbid file edits and external state changes in the materialized home"
            Assert-True -Condition ($reviewerConfig -like '*Do not commit, create or switch branches, modify refs, add labels/comments, or send external messages.*') `
                -Because "$reviewerAgent must preserve the complete Git and external-action prohibition"
            Assert-True -Condition ($reviewerConfig -like '*Do not spawn subagents.*') `
                -Because "$reviewerAgent must forbid nested subagents in the materialized home"
            Assert-True -Condition ($reviewerConfig -like '*model_reasoning_effort = "high"*') `
                -Because "$reviewerAgent must use high reasoning in the materialized home"
        }
    }

    Invoke-TestCase -Name 'missing_global_hook_trust_fails_closed' -Body {
        $case = New-TestCase -Name 'missing-hook-trust'
        $globalConfigPath = Join-Path $case.UserRoot '.codex\config.toml'
        $globalConfig = Get-Content -Raw -LiteralPath $globalConfigPath
        $globalConfig = [regex]::Replace(
            $globalConfig,
            "(?ms)^\[hooks\.state\.'[^']+:pre_compact:0:0'\]\r?\ntrusted_hash\s*=\s*`"[^`"]+`"\r?\n?",
            '',
            1
        )
        Write-Utf8NoBom -Path $globalConfigPath -Content $globalConfig

        Assert-MaterializeFailsClosed `
            -Case $case `
            -ExpectedMessagePattern '*Unable to capture a stable global hook trust snapshot*'
    }

    Invoke-TestCase -Name 'incomplete_reviewer_contract_fails_closed' -Body {
        $case = New-TestCase -Name 'incomplete-reviewer-contract'
        $incompleteConfig = "name = `"skeptic-reviewer`"`nmodel_reasoning_effort = `"high`"`nsandbox_mode = `"read-only`"`ndeveloper_instructions = `"Treat this profile's read-only sandbox setting as a request. Do not commit, create or switch branches. Do not spawn subagents.`"`n"
        Write-Utf8NoBom -Path (Join-Path $case.ReviewerAgentsRoot 'skeptic-reviewer.toml') -Content $incompleteConfig

        Assert-MaterializeFailsClosed `
            -Case $case `
            -ExpectedMessagePattern '*skeptic-reviewer must include the complete no-write reviewer contract*'
    }

    Invoke-TestCase -Name 'settings_database_mismatch_fails_closed' -Body {
        $case = New-TestCase -Name 'mismatch'
        Invoke-FixtureDb -Action switch -DbPath $case.DbPath -AdditionalArguments @('provider-b') | Out-Null
        Assert-MaterializeFailsClosed -Case $case
    }

    Invoke-TestCase -Name 'partially_written_settings_json_fails_closed' -Body {
        $case = New-TestCase -Name 'partial-settings'
        Write-Utf8NoBom -Path (Join-Path $case.CcSwitchRoot 'settings.json') `
            -Content '{"currentProviderCodex":'
        Assert-MaterializeFailsClosed -Case $case
    }

    Invoke-TestCase -Name 'deleted_selected_provider_fails_closed' -Body {
        $case = New-TestCase -Name 'deleted-provider'
        Invoke-FixtureDb -Action delete -DbPath $case.DbPath -AdditionalArguments @('provider-a') | Out-Null
        Assert-MaterializeFailsClosed -Case $case
    }

    Invoke-TestCase -Name 'database_exclusive_lock_fails_closed' -Body {
        $case = New-TestCase -Name 'database-busy'
        $signalPath = Join-Path $case.Root 'database-locked.signal'
        $lockHandle = $null
        try {
            $lockHandle = Start-CapturedProcess `
                -FilePath $script:Python `
                -Arguments @($script:LockHelper, $case.DbPath, $signalPath, '5') `
                -WorkingDirectory $case.Root
            $deadline = [DateTime]::UtcNow.AddSeconds(2)
            while (-not (Test-Path -LiteralPath $signalPath) -and [DateTime]::UtcNow -lt $deadline) {
                if ($lockHandle.Process.HasExited) { break }
                Start-Sleep -Milliseconds 25
            }
            Assert-True -Condition (Test-Path -LiteralPath $signalPath) -Because 'the fixture must hold an exclusive SQLite lock'
            Assert-MaterializeFailsClosed -Case $case
            $lockResult = Complete-CapturedProcess -Handle $lockHandle -TimeoutMilliseconds 10000
            $lockHandle = $null
            Assert-Equal -Expected 0 -Actual $lockResult.ExitCode -Because 'the SQLite lock holder must complete normally'
        } finally {
            Stop-CapturedProcess -Handle $lockHandle
        }
    }

    Invoke-TestCase -Name 'mirror_sync_waits_for_same_root_named_mutex_20260802_regression' -Body {
        $case = New-TestCase -Name 'mirror-sync-mutex'
        Set-CaseEnvironment -Case $case
        $signalPath = Join-Path $case.Root 'mirror-locked.signal'
        $mutexVariantRoot = '{0}\' -f $case.CcSwitchRoot
        $lockHandle = $null
        $syncHandle = $null
        try {
            $lockHandle = Start-CapturedProcess `
                -FilePath $script:Pwsh `
                -Arguments @(
                    '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                    '-File', $script:MirrorLockHelper,
                    '-CcSwitchRoot', $mutexVariantRoot,
                    '-SignalPath', $signalPath,
                    '-HoldMilliseconds', '5000'
                ) `
                -WorkingDirectory $case.Root
            Wait-ForCondition -Because 'the fixture must hold the mirror synchronization mutex' -Condition {
                (Test-Path -LiteralPath $signalPath -PathType Leaf) -and
                (-not $lockHandle.Process.HasExited)
            }

            $syncHandle = Start-CapturedProcess `
                -FilePath $script:Pwsh `
                -Arguments @(
                    '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                    '-File', $script:SyncSource,
                    '-CcSwitchRoot', $case.CcSwitchRoot,
                    '-CodexHome', $case.GlobalCodexHome,
                    '-CheckOnly',
                    '-Quiet'
                ) `
                -WorkingDirectory $case.Root
            Start-Sleep -Milliseconds 2000
            Assert-True -Condition (-not $syncHandle.Process.HasExited) `
                -Because 'mirror sync must wait while another process holds the same-root mutex'

            $lockResult = Complete-CapturedProcess -Handle $lockHandle -TimeoutMilliseconds 10000
            $lockHandle = $null
            Assert-Equal -Expected 0 -Actual $lockResult.ExitCode `
                -Because 'the mirror mutex holder must release cleanly'

            $syncResult = Complete-CapturedProcess -Handle $syncHandle -TimeoutMilliseconds 15000
            $syncHandle = $null
            Assert-Equal -Expected 0 -Actual $syncResult.ExitCode `
                -Because 'mirror sync must succeed after the same-root mutex is released'
        } finally {
            Stop-CapturedProcess -Handle $syncHandle
            Stop-CapturedProcess -Handle $lockHandle
        }
    }

    Invoke-TestCase -Name 'model_persistence_holds_same_root_mutex_through_mirror_sync' -Body {
        $case = New-TestCase -Name 'persist-mirror-mutex'
        $snapshot = Invoke-Materialize -Case $case -LaunchMode direct
        Set-RunModel -RunHome $snapshot.codexHome -Model 'model-mutex' -Effort 'ultra'

        $signalPath = Join-Path $case.Root 'persist-mirror-mutex.signal'
        $probePath = Join-Path $case.Root 'probe-mirror-mutex.ps1'
        $fakeSyncPath = Join-Path $case.Root 'fake-sync-mutex-probe.ps1'
        $probeCode = @'
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$CcSwitchRoot,
    [Parameter(Mandatory = $true)][string]$SignalPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. 'RESOLVER_PATH'
$mutex = [Threading.Mutex]::new($false, (Get-CcSwitchRootMutexName -Root $CcSwitchRoot))
$acquired = $false
try {
    try {
        $acquired = $mutex.WaitOne([TimeSpan]::FromMilliseconds(250))
    } catch [Threading.AbandonedMutexException] {
        $acquired = $true
    }
    [IO.File]::WriteAllText($SignalPath, ([string]$acquired).ToLowerInvariant())
    if ($acquired) {
        $mutex.ReleaseMutex()
        exit 1
    }
    exit 0
} finally {
    $mutex.Dispose()
}
'@
        $probeCode = $probeCode.Replace('RESOLVER_PATH', $script:RootResolverSource.Replace("'", "''"))
        Write-Utf8NoBom -Path $probePath -Content $probeCode
        $fakeSyncCode = @'
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$CcSwitchRoot,
    [string[]]$CodexHome = @(),
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$probe = Start-Process `
    -FilePath 'PWSH_PATH' `
    -ArgumentList @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', 'PROBE_PATH',
        '-CcSwitchRoot', $CcSwitchRoot,
        '-SignalPath', 'SIGNAL_PATH'
    ) `
    -WorkingDirectory (Split-Path -Parent 'PROBE_PATH') `
    -NoNewWindow `
    -Wait `
    -PassThru
        exit $probe.ExitCode
'@
        $fakeSyncCode = $fakeSyncCode.Replace('PWSH_PATH', $script:Pwsh.Replace("'", "''"))
        $fakeSyncCode = $fakeSyncCode.Replace('PROBE_PATH', $probePath.Replace("'", "''"))
        $fakeSyncCode = $fakeSyncCode.Replace('SIGNAL_PATH', $signalPath.Replace("'", "''"))
        Write-Utf8NoBom -Path $fakeSyncPath -Content $fakeSyncCode

        $persistence = Invoke-Persist `
            -Case $case `
            -RunHome $snapshot.codexHome `
            -SyncScript $fakeSyncPath
        $persistenceDiagnostics = Format-TestValue $persistence

        Assert-Equal -Expected 'synced' -Actual ([string]$persistence.mirrors.globalCodex) `
            -Because "persistence must keep the shared root mutex while invoking mirror sync; result=$persistenceDiagnostics"
        Assert-Equal -Expected 'synced' -Actual ([string]$persistence.mirrors.ccswitchCurrent) `
            -Because 'persistence must report both mirrors synced under the shared mutex'
        Assert-Equal -Expected 'false' -Actual ((Get-Content -Raw -LiteralPath $signalPath).Trim()) `
            -Because 'a mirror sync child must observe the persistence operation holding the same root mutex'
    }

    Invoke-TestCase -Name 'ten_parallel_materializations_keep_private_states_isolated' -Body {
        $case = New-TestCase -Name 'parallel-materialize'
        Set-CaseEnvironment -Case $case
        $handles = [Collections.Generic.List[object]]::new()
        try {
            for ($index = 0; $index -lt 10; $index++) {
                $handles.Add((Start-CapturedProcess `
                    -FilePath $script:Pwsh `
                    -Arguments @(
                        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:MaterializeSource,
                        '-Quiet', '-CcSwitchRoot', $case.CcSwitchRoot,
                        '-ProdexScript', $script:ProdexScript
                    ) `
                    -WorkingDirectory $case.Root `
                    -Environment @{
                        USERPROFILE = $case.UserRoot
                        HOME = $case.UserRoot
                        APPDATA = $case.AppData
                        PRODEX_HOME = $case.ProdexRoot
                        PRODEX_SHARED_CODEX_HOME = $case.SharedCodexHome
                        PRODEX_CODEX_BIN = $script:CodexBinary
                    }))
            }

            $snapshots = [Collections.Generic.List[object]]::new()
            foreach ($handle in @($handles)) {
                $result = Complete-CapturedProcess -Handle $handle -TimeoutMilliseconds 90000
                $handle.Process = $null
                Assert-Equal -Expected 0 -Actual $result.ExitCode `
                    -Because "parallel materialize must succeed; stderr=$($result.StandardError)"
                $line = @($result.StandardOutput -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 1)
                Assert-Equal -Expected 1 -Actual $line.Count -Because 'each materialize process must emit metadata'
                $snapshots.Add(($line[0] | ConvertFrom-Json))
            }
            $handles.Clear()

            Assert-True -Condition (-not (Test-Path -LiteralPath $case.StatePath -PathType Leaf)) `
                -Because 'run registration must not write the shared Prodex state'
            $privateHomes = @($snapshots | ForEach-Object { [string]$_.prodexHome })
            Assert-Equal -Expected 10 -Actual @($privateHomes | Select-Object -Unique).Count `
                -Because 'every materialized run must own a unique private Prodex home'
            foreach ($snapshot in $snapshots) {
                Assert-True -Condition (Test-Path -LiteralPath ([string]$snapshot.codexHome) -PathType Container) `
                    -Because 'every emitted run home must be published'
                Assert-Equal -Expected (Join-Path ([string]$snapshot.codexHome) '.prodex-runtime') `
                    -Actual ([string]$snapshot.prodexHome) `
                    -Because 'private Prodex home must be located inside its run home'
                $state = Get-ProdexState -ProdexHome ([string]$snapshot.prodexHome)
                $profileNames = @($state.profiles.PSObject.Properties.Name)
                Assert-SequenceEqual -Expected @([string]$snapshot.profileName) -Actual $profileNames `
                    -Because 'private Prodex state must contain only its own profile'
                Assert-True -Condition (Test-Path -LiteralPath (Join-Path ([string]$snapshot.prodexHome) 'state.json.lock') -PathType Leaf) `
                    -Because 'private profile registration must use the official Prodex state lock'
                $profile = $state.profiles.PSObject.Properties[[string]$snapshot.profileName].Value
                Assert-Equal -Expected ([string]$snapshot.codexHome) -Actual ([string]$profile.codex_home) `
                    -Because 'private profile must reference its own run home'
            }
            Assert-Equal -Expected 0 -Actual @(Get-ChildItem -LiteralPath $case.RunHomesRoot -Directory -Filter '.ccswitch-staging-*' -Force).Count `
                -Because 'successful concurrent publication must leave no staging directories'
        } finally {
            foreach ($handle in @($handles)) {
                if ($null -ne $handle.Process) { Stop-CapturedProcess -Handle $handle }
            }
        }
    }

    Invoke-TestCase -Name 'parallel_private_prodex_version_runs_keep_states_isolated' -Body {
        for ($round = 0; $round -lt 5; $round++) {
            $case = New-TestCase -Name "materialize-run-round-$round"
            $expectedProvider = if (($round % 2) -eq 0) { 'provider-a' } else { 'provider-b' }
            $expectedModel = if ($expectedProvider -eq 'provider-a') { 'model-a' } else { 'model-b' }
            if ($expectedProvider -eq 'provider-b') {
                Set-CurrentProvider -Case $case -ProviderId $expectedProvider
            }
            Set-CaseEnvironment -Case $case

            $handles = [Collections.Generic.List[object]]::new()
            try {
                for ($index = 0; $index -lt 4; $index++) {
                    $handles.Add((Start-CapturedProcess `
                        -FilePath $script:Pwsh `
                        -Arguments @(
                            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:MaterializeRunHelper,
                            '-MaterializeScript', $script:MaterializeSource,
                            '-CcSwitchRoot', $case.CcSwitchRoot,
                            '-ProdexScript', $script:ProdexScript
                        ) `
                        -WorkingDirectory $case.Root `
                        -Environment @{
                            USERPROFILE = $case.UserRoot
                            HOME = $case.UserRoot
                            APPDATA = $case.AppData
                            PRODEX_HOME = $case.ProdexRoot
                            PRODEX_SHARED_CODEX_HOME = $case.SharedCodexHome
                            PRODEX_CODEX_BIN = $script:CodexBinary
                        }))
                }

                $records = [Collections.Generic.List[object]]::new()
                foreach ($handle in @($handles)) {
                    $processResult = Complete-CapturedProcess -Handle $handle -TimeoutMilliseconds 90000
                    $handle.Process = $null
                    Assert-Equal -Expected 0 -Actual $processResult.ExitCode `
                        -Because ("round {0} materialize/version process must succeed; stdout={1}; stderr={2}" -f `
                            $round, $processResult.StandardOutput, $processResult.StandardError)
                    $line = @($processResult.StandardOutput -split '\r?\n' |
                        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                        Select-Object -Last 1)
                    Assert-Equal -Expected 1 -Actual $line.Count `
                        -Because "round $round process must emit one final JSON record"
                    $record = $line[0] | ConvertFrom-Json
                    Assert-Equal -Expected 0 -Actual ([int]$record.versionExitCode) `
                        -Because "round $round private Prodex version run must return zero"
                    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace([string]$record.versionOutput)) `
                        -Because "round $round real Codex version output must not be empty"
                    $records.Add($record)
                }
                $handles.Clear()

                Assert-True -Condition (-not (Test-Path -LiteralPath $case.StatePath -PathType Leaf)) `
                    -Because "round $round must not write shared Prodex state"
                $privateHomes = @($records | ForEach-Object { [string]$_.prodexHome })
                Assert-Equal -Expected 4 -Actual @($privateHomes | Select-Object -Unique).Count `
                    -Because "round $round every real run must use a unique private Prodex home"

                foreach ($record in $records) {
                    $state = Get-ProdexState -ProdexHome ([string]$record.prodexHome)
                    $profileNames = @($state.profiles.PSObject.Properties.Name)
                    $selectedNames = @($state.last_run_selected_at.PSObject.Properties.Name)
                    Assert-SequenceEqual -Expected @([string]$record.profileName) -Actual $profileNames `
                        -Because "round $round private state must contain only its emitted profile"
                    Assert-True -Condition ($selectedNames -contains [string]$record.profileName) `
                        -Because "round $round real private run must record its profile selection"
                    Assert-True -Condition (Test-Path -LiteralPath (Join-Path ([string]$record.prodexHome) 'state.json.lock') -PathType Leaf) `
                        -Because "round $round private run must use the official Prodex state lock"
                    Assert-Equal -Expected (Join-Path ([string]$record.codexHome) '.prodex-runtime') `
                        -Actual ([string]$record.prodexHome) `
                        -Because "round $round private Prodex home must belong to its run home"
                    Assert-Equal -Expected $expectedProvider -Actual ([string]$record.providerId) `
                        -Because "round $round snapshot must remain bound to the selected provider"
                    Assert-Equal -Expected $expectedModel -Actual ([string]$record.model) `
                        -Because "round $round snapshot must retain the selected provider model"
                    $metadata = Get-Content -LiteralPath (Join-Path ([string]$record.codexHome) 'run-provider.json') -Raw | ConvertFrom-Json
                    $config = Get-Content -LiteralPath (Join-Path ([string]$record.codexHome) 'config.toml') -Raw
                    Assert-Equal -Expected $expectedProvider -Actual ([string]$metadata.providerId) `
                        -Because "round $round published metadata must match the selected provider"
                    Assert-True -Condition ($config -like "*model = `"$expectedModel`"*") `
                        -Because "round $round published config must match the selected provider model"
                }
            } finally {
                foreach ($handle in @($handles)) {
                    if ($null -ne $handle.Process) { Stop-CapturedProcess -Handle $handle }
                }
            }
        }
    }

    Invoke-TestCase -Name 'persisting_A_while_B_is_current_does_not_change_B' -Body {
        $case = New-TestCase -Name 'persist-a-current-b'
        $snapshotA = Invoke-Materialize -Case $case
        Set-CurrentProvider -Case $case -ProviderId 'provider-b'
        $providerBBefore = Get-ProviderState -Case $case -ProviderId 'provider-b'
        Set-RunModel -RunHome $snapshotA.codexHome -Model 'model-a-window' -Effort 'ultra'

        $result = Invoke-Persist -Case $case -RunHome $snapshotA.codexHome
        $providerAAfter = Get-ProviderState -Case $case -ProviderId 'provider-a'
        $providerBAfter = Get-ProviderState -Case $case -ProviderId 'provider-b'

        Assert-Equal -Expected 'updated' -Actual ([string]$result.status) -Because 'A run model change must persist to A'
        Assert-Equal -Expected 'model-a-window' -Actual ([string]$providerAAfter.model) -Because 'provider A must receive its run model'
        Assert-Equal -Expected $providerBBefore.settingsRaw -Actual $providerBAfter.settingsRaw -Because 'provider B settings must remain byte-for-byte unchanged'
        Assert-True -Condition ([bool]$providerBAfter.isCurrent) -Because 'provider B must remain the current UI provider'
        Assert-True -Condition (-not [bool]$result.syncEligible) -Because 'persisting non-current A must not sync live mirrors'
    }

    Invoke-TestCase -Name 'unchanged_old_run_does_not_roll_back_newer_provider_model' -Body {
        $case = New-TestCase -Name 'persist-no-rollback'
        $oldRun = Invoke-Materialize -Case $case
        $changedRun = Invoke-Materialize -Case $case
        Set-CurrentProvider -Case $case -ProviderId 'provider-b'
        Set-RunModel -RunHome $changedRun.codexHome -Model 'model-a-newer' -Effort 'ultra'

        $changedResult = Invoke-Persist -Case $case -RunHome $changedRun.codexHome
        $oldResult = Invoke-Persist -Case $case -RunHome $oldRun.codexHome
        $providerA = Get-ProviderState -Case $case -ProviderId 'provider-a'

        Assert-Equal -Expected 'updated' -Actual ([string]$changedResult.status) -Because 'the changed run must update its provider'
        Assert-Equal -Expected 'skipped' -Actual ([string]$oldResult.status) -Because 'an unchanged old run must skip persistence'
        Assert-Equal -Expected 'model-a-newer' -Actual ([string]$providerA.model) -Because 'the skipped old run must not restore its baseline'
    }

    Invoke-TestCase -Name 'same_provider_last_exit_wins' -Body {
        $case = New-TestCase -Name 'persist-last-exit'
        $firstRun = Invoke-Materialize -Case $case
        $lastRun = Invoke-Materialize -Case $case
        Set-CurrentProvider -Case $case -ProviderId 'provider-b'
        Set-RunModel -RunHome $firstRun.codexHome -Model 'model-first-exit' -Effort 'high'
        Set-RunModel -RunHome $lastRun.codexHome -Model 'model-last-exit' -Effort 'ultra'

        $firstResult = Invoke-Persist -Case $case -RunHome $firstRun.codexHome
        $lastResult = Invoke-Persist -Case $case -RunHome $lastRun.codexHome
        $providerA = Get-ProviderState -Case $case -ProviderId 'provider-a'

        Assert-Equal -Expected 'updated' -Actual ([string]$firstResult.status) -Because 'the first changed run must persist'
        Assert-Equal -Expected 'updated' -Actual ([string]$lastResult.status) -Because 'the later changed run must persist'
        Assert-Equal -Expected 'model-last-exit' -Actual ([string]$providerA.model) -Because 'the last exiting run must own the final model'
        Assert-Equal -Expected 'ultra' -Actual ([string]$providerA.effort) -Because 'the last exiting run must own the final effort'
    }

    Invoke-TestCase -Name 'explicit_dirty_field_persists_model_returned_to_launch_baseline' -Body {
        $case = New-TestCase -Name 'persist-return-to-baseline'
        $snapshot = Invoke-Materialize -Case $case
        Set-CurrentProvider -Case $case -ProviderId 'provider-b'

        Set-RunModel -RunHome $snapshot.codexHome -Model 'model-temporary' -Effort $snapshot.modelReasoningEffort
        $temporaryResult = Invoke-Persist -Case $case -RunHome $snapshot.codexHome -ChangedFields @('model')
        Assert-Equal -Expected 'updated' -Actual ([string]$temporaryResult.status) `
            -Because 'the temporary model must first persist'

        Set-RunModel -RunHome $snapshot.codexHome -Model $snapshot.model -Effort $snapshot.modelReasoningEffort
        $restoredResult = Invoke-Persist -Case $case -RunHome $snapshot.codexHome -ChangedFields @('model')
        $providerA = Get-ProviderState -Case $case -ProviderId 'provider-a'

        Assert-SequenceEqual -Expected @('model') -Actual @($restoredResult.changedFields) `
            -Because 'an explicitly dirty model must remain changed even after returning to the launch baseline'
        Assert-Equal -Expected $snapshot.model -Actual ([string]$providerA.model) `
            -Because 'A to B to A must persist the final A selection'
    }

    Invoke-TestCase -Name 'quoted_top_level_model_keys_persist_through_multiline_boundaries' -Body {
        $case = New-TestCase -Name 'persist-quoted-keys'
        $snapshot = Invoke-Materialize -Case $case
        Set-CurrentProvider -Case $case -ProviderId 'provider-b'

        $providerConfig = @'
note = """
[example]
model = "fake-model-inside-string"
"""
quote_run = """""""
literal_note = '''
[literal-example]
model = "fake-literal-inside-string"
'''
servers = [
  ["array-example"]
]
"model"   =   """model-a"""   # keep model comment
'model_reasoning_effort' = 'high' # keep effort comment
model_provider = "provider-a"

[model_providers."provider-a]x"]
name = "Provider A"
base_url = "https://provider-a.invalid/v1"
wire_api = "responses"
requires_openai_auth = true
'@
        Set-ProviderConfig -Case $case -ProviderId 'provider-a' -Config $providerConfig
        Set-RunModel -RunHome $snapshot.codexHome -Model 'quoted-model' -Effort 'ultra'

        $result = Invoke-Persist -Case $case -RunHome $snapshot.codexHome
        $providerA = Get-ProviderState -Case $case -ProviderId 'provider-a'
        $providerSettings = $providerA.settingsRaw | ConvertFrom-Json
        $updatedConfig = [string]$providerSettings.config

        Assert-Equal -Expected 'updated' -Actual ([string]$result.status) `
            -Because 'quoted top-level keys must persist through multiline strings and arrays'
        Assert-Equal -Expected 'quoted-model' -Actual ([string]$providerA.model) `
            -Because 'the quoted model key must be parsed and persisted in provider settings'
        Assert-Equal -Expected 'ultra' -Actual ([string]$providerA.effort) `
            -Because 'the quoted effort key must be parsed and persisted in provider settings'
        Assert-True -Condition ($updatedConfig.Contains('"model"   =   """quoted-model"""   # keep model comment')) `
            -Because 'model key spacing, triple-quote style, and inline comment must remain intact'
        Assert-True -Condition ($updatedConfig.Contains("'model_reasoning_effort' = 'ultra' # keep effort comment")) `
            -Because 'literal key quoting and inline comment must remain intact'
        Assert-True -Condition ($updatedConfig.Contains('model = "fake-model-inside-string"')) `
            -Because 'fake assignments inside a multiline string must not be rewritten or counted'
        Assert-True -Condition ($updatedConfig.Contains('model = "fake-literal-inside-string"')) `
            -Because 'fake assignments inside a literal multiline string must not be rewritten or counted'
        Assert-True -Condition ($updatedConfig.Contains('[model_providers."provider-a]x"]')) `
            -Because 'a quoted table key containing a closing bracket must remain a table boundary'
    }

    Invoke-TestCase -Name 'invalid_legacy_root_is_ignored_when_resolving_canonical_root_20260715' -Body {
        $case = New-TestCase -Name 'legacy-root-mirror-boundary'
        $snapshot = Invoke-Materialize -Case $case
        Set-RunEffort -RunHome $snapshot.codexHome -Effort 'ultra'
        $desktopRoot = Join-Path $case.AppData 'com.ccswitch.desktop'
        [IO.Directory]::CreateDirectory($desktopRoot) | Out-Null
        Write-Utf8NoBom -Path (Join-Path $desktopRoot 'settings.json') -Content '{}'
        Write-Utf8NoBom -Path (Join-Path $desktopRoot 'cc-switch.db') -Content ''
        $syncMarker = Join-Path $case.Root 'legacy-sync-invoked.txt'
        $syncScript = Join-Path $case.Root 'legacy-sync.ps1'
        Write-Utf8NoBom -Path $syncScript -Content "[IO.File]::WriteAllText('$syncMarker', 'called')"

        $output = @(& $script:PersistSource `
            -RunHome $snapshot.codexHome `
            -CcSwitchRoot $case.CcSwitchRoot `
            -AllowedRunHomesRoot $case.RunHomesRoot `
            -SyncScript $syncScript `
            -Json)
        $persistence = $output[-1] | ConvertFrom-Json
        $provider = Get-ProviderState -Case $case -ProviderId 'provider-a'

        Assert-Equal -Expected 'updated' -Actual ([string]$persistence.status) `
            -Because 'the legacy provider must still receive its run-scoped model change'
        Assert-Equal -Expected 'ultra' -Actual ([string]$provider.effort) `
            -Because 'suppressing shared mirrors must not suppress provider persistence'
        Assert-Equal -Expected 'synced' -Actual ([string]$persistence.mirrors.globalCodex) `
            -Because 'an invalid legacy root must not displace the valid canonical root'
        Assert-True -Condition (Test-Path -LiteralPath $syncMarker) `
            -Because 'the valid canonical root must still invoke shared mirror synchronization'
    }

    Invoke-TestCase -Name 'older_exit_order_is_superseded_deterministically' -Body {
        $case = New-TestCase -Name 'persist-exit-order'
        $earlyRun = Invoke-Materialize -Case $case
        $lateRun = Invoke-Materialize -Case $case
        Set-CurrentProvider -Case $case -ProviderId 'provider-b'
        Set-RunModel -RunHome $earlyRun.codexHome -Model 'model-exit-order-100' -Effort 'high'
        Set-RunModel -RunHome $lateRun.codexHome -Model 'model-exit-order-200' -Effort 'high'

        $lateResult = Invoke-Persist -Case $case -RunHome $lateRun.codexHome -ExitOrder 200
        $earlyResult = Invoke-Persist -Case $case -RunHome $earlyRun.codexHome -ExitOrder 100
        $providerA = Get-ProviderState -Case $case -ProviderId 'provider-a'

        Assert-Equal -Expected 'updated' -Actual ([string]$lateResult.status) `
            -Because 'the highest exit order must persist normally'
        Assert-Equal -Expected 'superseded' -Actual ([string]$earlyResult.status) `
            -Because 'an older exit order must be rejected deterministically'
        Assert-Equal -Expected 'model-exit-order-200' -Actual ([string]$providerA.model) `
            -Because 'a superseded older run must not overwrite the later model'
    }

    Invoke-TestCase -Name 'effort_only_exit_preserves_model_updated_by_another_window' -Body {
        $case = New-TestCase -Name 'effort-preserves-model'
        $modelRun = Invoke-Materialize -Case $case
        $effortRun = Invoke-Materialize -Case $case
        Set-CurrentProvider -Case $case -ProviderId 'provider-b'
        Set-RunModel -RunHome $modelRun.codexHome -Model 'model-from-other-window' -Effort 'high'
        Set-RunEffort -RunHome $effortRun.codexHome -Effort 'ultra'

        $modelResult = Invoke-Persist -Case $case -RunHome $modelRun.codexHome
        $effortResult = Invoke-Persist -Case $case -RunHome $effortRun.codexHome
        $providerA = Get-ProviderState -Case $case -ProviderId 'provider-a'

        Assert-SequenceEqual -Expected @('model') -Actual @($modelResult.changedFields) `
            -Because 'the first window must publish only its model change'
        Assert-SequenceEqual -Expected @('model_reasoning_effort') -Actual @($effortResult.changedFields) `
            -Because 'the second window must publish only its effort change'
        Assert-Equal -Expected 'model-from-other-window' -Actual ([string]$providerA.model) `
            -Because 'an unchanged stale model must not roll back another window model'
        Assert-Equal -Expected 'ultra' -Actual ([string]$providerA.effort) `
            -Because 'the effort-only window must persist its changed effort'
    }

    Invoke-TestCase -Name 'provider_default_model_allows_effort_only_persistence' -Body {
        $case = New-TestCase -Name 'default-model-effort'
        Invoke-FixtureDb -Action remove-model -DbPath $case.DbPath -AdditionalArguments @('provider-a') | Out-Null
        $snapshot = Invoke-Materialize -Case $case
        Set-CurrentProvider -Case $case -ProviderId 'provider-b'
        $providerBBefore = Get-ProviderState -Case $case -ProviderId 'provider-b'
        Set-RunEffort -RunHome $snapshot.codexHome -Effort 'ultra'

        $result = Invoke-Persist -Case $case -RunHome $snapshot.codexHome
        $providerAAfter = Get-ProviderState -Case $case -ProviderId 'provider-a'
        $providerBAfter = Get-ProviderState -Case $case -ProviderId 'provider-b'

        Assert-True -Condition ($null -eq $snapshot.model) -Because 'the run must start from the provider default model'
        Assert-SequenceEqual -Expected @('model_reasoning_effort') -Actual @($result.changedFields) `
            -Because 'only the reasoning effort may be marked changed'
        Assert-True -Condition ($null -eq $providerAAfter.model) `
            -Because 'effort-only persistence must keep the provider model absent'
        Assert-Equal -Expected 'ultra' -Actual ([string]$providerAAfter.effort) `
            -Because 'effort-only persistence must update provider A effort'
        Assert-Equal -Expected $providerBBefore.settingsRaw -Actual $providerBAfter.settingsRaw `
            -Because 'effort-only persistence for A must not mutate current provider B'
    }

    Invoke-TestCase -Name 'provider_default_model_skips_until_run_selects_a_model' -Body {
        $case = New-TestCase -Name 'provider-default-model'
        Invoke-FixtureDb -Action remove-model -DbPath $case.DbPath -AdditionalArguments @('provider-a') | Out-Null
        $snapshot = Invoke-Materialize -Case $case

        Assert-True -Condition ($null -eq $snapshot.model) -Because 'a provider without a top-level model must materialize with a null baseline'
        $unchangedResult = Invoke-Persist -Case $case -RunHome $snapshot.codexHome
        Assert-Equal -Expected 'skipped' -Actual ([string]$unchangedResult.status) `
            -Because 'an unchanged provider-default run must not write a model'
        Assert-True -Condition ($null -eq (Get-ProviderState -Case $case -ProviderId 'provider-a').model) `
            -Because 'skip must preserve the provider default model behavior'

        Set-CurrentProvider -Case $case -ProviderId 'provider-b'
        $providerBBefore = Get-ProviderState -Case $case -ProviderId 'provider-b'
        Add-RunModel -RunHome $snapshot.codexHome -Model 'model-selected-in-run'
        $changedResult = Invoke-Persist -Case $case -RunHome $snapshot.codexHome
        $providerAAfter = Get-ProviderState -Case $case -ProviderId 'provider-a'
        $providerBAfter = Get-ProviderState -Case $case -ProviderId 'provider-b'

        Assert-Equal -Expected 'updated' -Actual ([string]$changedResult.status) `
            -Because 'a model selected inside the run must persist to its provider'
        Assert-Equal -Expected 'model-selected-in-run' -Actual ([string]$providerAAfter.model) `
            -Because 'the previously absent provider model must be inserted'
        Assert-Equal -Expected $providerBBefore.settingsRaw -Actual $providerBAfter.settingsRaw `
            -Because 'adding A model must not mutate current provider B'
    }

    Invoke-TestCase -Name 'removing_existing_run_model_fails_without_database_change' -Body {
        $case = New-TestCase -Name 'remove-existing-model'
        $snapshot = Invoke-Materialize -Case $case
        Set-CurrentProvider -Case $case -ProviderId 'provider-b'
        $providerABefore = Get-ProviderState -Case $case -ProviderId 'provider-a'
        Remove-RunModel -RunHome $snapshot.codexHome
        $caught = $null
        try {
            $null = @(& $script:PersistSource `
                -RunHome $snapshot.codexHome `
                -CcSwitchRoot $case.CcSwitchRoot `
                -AllowedRunHomesRoot $case.RunHomesRoot `
                -SyncScript (Join-Path $case.Root 'not-used-sync.ps1') `
                -Json)
        } catch {
            $caught = $_
        }
        $providerAAfter = Get-ProviderState -Case $case -ProviderId 'provider-a'

        Assert-True -Condition ($null -ne $caught) -Because 'removing an existing model must fail persistence'
        Assert-True -Condition ($caught.Exception.Message -like '*unsupported_model_removal*') `
            -Because 'failure must report the unsupported model removal boundary'
        Assert-Equal -Expected $providerABefore.settingsRaw -Actual $providerAAfter.settingsRaw `
            -Because 'failed model removal must not change provider settings'
    }

    Invoke-TestCase -Name 'watcher_persists_live_model_changes_and_return_to_baseline' -Body {
        $case = New-TestCase -Name 'watcher-live-baseline'
        $snapshot = Invoke-Materialize -Case $case
        Set-CurrentProvider -Case $case -ProviderId 'provider-b'
        $stopFile = Join-Path $snapshot.codexHome 'watcher-stop.signal'
        $stateFile = Join-Path $snapshot.codexHome 'watcher-state.json'
        $readyFile = Join-Path $snapshot.codexHome 'watcher-ready.signal'
        $persistenceLog = Join-Path $case.Root 'watcher-persistence.jsonl'
        $parentStartTime = (Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks
        $handle = Start-CapturedProcess `
            -FilePath $script:Pwsh `
            -Arguments @(
                '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                '-File', $script:WatcherSource,
                '-RunHome', $snapshot.codexHome,
                '-CcSwitchRoot', $case.CcSwitchRoot,
                '-AllowedRunHomesRoot', $case.RunHomesRoot,
                '-ParentProcessId', ([string]$PID),
                '-ParentProcessStartTimeUtcTicks', ([string]$parentStartTime),
                '-StopFile', $stopFile,
                '-StateFile', $stateFile,
                '-ReadyFile', $readyFile,
                '-PersistenceLog', $persistenceLog,
                '-PersistScript', $script:PersistSource
            ) `
            -WorkingDirectory $case.Root `
            -Environment @{
                USERPROFILE = $case.UserRoot
                HOME = $case.UserRoot
                APPDATA = $case.AppData
                PRODEX_HOME = $case.ProdexRoot
            }
        try {
            Wait-ForCondition -Because 'the watcher must publish its ready signal' `
                -Condition { Test-Path -LiteralPath $readyFile -PathType Leaf }

            Set-RunModel -RunHome $snapshot.codexHome -Model 'model-watcher-temporary' `
                -Effort $snapshot.modelReasoningEffort
            Wait-ForCondition -Because 'the watcher must persist the temporary model' -Condition {
                (Get-ProviderState -Case $case -ProviderId 'provider-a').model -eq 'model-watcher-temporary'
            }

            Set-RunModel -RunHome $snapshot.codexHome -Model $snapshot.model `
                -Effort $snapshot.modelReasoningEffort
            Wait-ForCondition -Because 'the watcher must persist the final baseline model' -Condition {
                (Get-ProviderState -Case $case -ProviderId 'provider-a').model -eq $snapshot.model
            }

            [IO.File]::WriteAllText($stopFile, 'stop')
            $result = Complete-CapturedProcess -Handle $handle -TimeoutMilliseconds 10000
            $handle = $null
            Assert-Equal -Expected 0 -Actual $result.ExitCode -Because 'the watcher must stop cleanly'
            $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
            Assert-Equal -Expected 0 -Actual @($state.pendingFields).Count `
                -Because 'successful live persistence must clear pending fields'
        } finally {
            Stop-CapturedProcess -Handle $handle
        }
    }

    Invoke-TestCase -Name 'watcher_retries_pending_state_from_previous_failed_exit' -Body {
        $case = New-TestCase -Name 'watcher-recover-pending'
        $snapshot = Invoke-Materialize -Case $case
        Set-CurrentProvider -Case $case -ProviderId 'provider-b'
        Set-RunModel -RunHome $snapshot.codexHome -Model 'model-before-failed-exit' `
            -Effort $snapshot.modelReasoningEffort
        $null = Invoke-Persist -Case $case -RunHome $snapshot.codexHome -ChangedFields @('model')
        Set-RunModel -RunHome $snapshot.codexHome -Model $snapshot.model `
            -Effort $snapshot.modelReasoningEffort

        $stopFile = Join-Path $snapshot.codexHome 'watcher-recover-stop.signal'
        $stateFile = Join-Path $snapshot.codexHome 'watcher-recover-state.json'
        $readyFile = Join-Path $snapshot.codexHome 'watcher-recover-ready.signal'
        $persistenceLog = Join-Path $case.Root 'watcher-recover.jsonl'
        Write-Utf8NoBom -Path $stateFile -Content (([ordered]@{
            schemaVersion = 1
            pendingFields = @('model')
            observed = [ordered]@{
                model = $snapshot.model
                modelReasoningEffort = $snapshot.modelReasoningEffort
            }
        } | ConvertTo-Json -Depth 5) + "`n")
        $parentStartTime = (Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks
        $handle = Start-CapturedProcess `
            -FilePath $script:Pwsh `
            -Arguments @(
                '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                '-File', $script:WatcherSource,
                '-RunHome', $snapshot.codexHome,
                '-CcSwitchRoot', $case.CcSwitchRoot,
                '-AllowedRunHomesRoot', $case.RunHomesRoot,
                '-ParentProcessId', ([string]$PID),
                '-ParentProcessStartTimeUtcTicks', ([string]$parentStartTime),
                '-StopFile', $stopFile,
                '-StateFile', $stateFile,
                '-ReadyFile', $readyFile,
                '-PersistenceLog', $persistenceLog,
                '-PersistScript', $script:PersistSource
            ) `
            -WorkingDirectory $case.Root `
            -Environment @{
                USERPROFILE = $case.UserRoot
                HOME = $case.UserRoot
                APPDATA = $case.AppData
                PRODEX_HOME = $case.ProdexRoot
            }
        try {
            Wait-ForCondition -Because 'the restarted watcher must publish its ready signal' `
                -Condition { Test-Path -LiteralPath $readyFile -PathType Leaf }
            Wait-ForCondition -Because 'the restarted watcher must retry the retained pending model' -Condition {
                (Get-ProviderState -Case $case -ProviderId 'provider-a').model -eq $snapshot.model
            }
            [IO.File]::WriteAllText($stopFile, 'stop')
            $result = Complete-CapturedProcess -Handle $handle -TimeoutMilliseconds 10000
            $handle = $null
            Assert-Equal -Expected 0 -Actual $result.ExitCode `
                -Because 'the restarted watcher must stop cleanly after recovering pending state'
            $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
            Assert-Equal -Expected 0 -Actual @($state.pendingFields).Count `
                -Because 'successful recovery must clear the retained pending field'
        } finally {
            Stop-CapturedProcess -Handle $handle
        }
    }

    Invoke-TestCase -Name 'watcher_retries_transient_database_busy_failure' -Body {
        $case = New-TestCase -Name 'watcher-transient-retry'
        $snapshot = Invoke-Materialize -Case $case
        Set-CurrentProvider -Case $case -ProviderId 'provider-b'
        $wrapperPath = Join-Path $case.Root 'persist-busy-once.ps1'
        $counterPath = Join-Path $case.Root 'persist-attempt-count.txt'
        Write-Utf8NoBom -Path $wrapperPath -Content @'
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RunHome,
    [long]$ExitOrder,
    [string]$CcSwitchRoot,
    [string]$AllowedRunHomesRoot,
    [string]$ChangedFieldsCsv,
    [switch]$Json
)
$count = if (Test-Path -LiteralPath $env:FAKE_BUSY_COUNTER) {
    [int](Get-Content -LiteralPath $env:FAKE_BUSY_COUNTER -Raw)
} else {
    0
}
$count++
[IO.File]::WriteAllText($env:FAKE_BUSY_COUNTER, [string]$count)
if ($count -eq 1) {
    '{"ok":false,"status":"failed","errorCode":"database_busy","message":"fixture busy"}'
    exit 2
}
& $env:REAL_PERSIST_SCRIPT @PSBoundParameters
'@
        $stopFile = Join-Path $snapshot.codexHome 'watcher-retry-stop.signal'
        $stateFile = Join-Path $snapshot.codexHome 'watcher-retry-state.json'
        $readyFile = Join-Path $snapshot.codexHome 'watcher-retry-ready.signal'
        $persistenceLog = Join-Path $case.Root 'watcher-retry.jsonl'
        $parentStartTime = (Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks
        $handle = Start-CapturedProcess `
            -FilePath $script:Pwsh `
            -Arguments @(
                '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                '-File', $script:WatcherSource,
                '-RunHome', $snapshot.codexHome,
                '-CcSwitchRoot', $case.CcSwitchRoot,
                '-AllowedRunHomesRoot', $case.RunHomesRoot,
                '-ParentProcessId', ([string]$PID),
                '-ParentProcessStartTimeUtcTicks', ([string]$parentStartTime),
                '-StopFile', $stopFile,
                '-StateFile', $stateFile,
                '-ReadyFile', $readyFile,
                '-PersistenceLog', $persistenceLog,
                '-PersistScript', $wrapperPath
            ) `
            -WorkingDirectory $case.Root `
            -Environment @{
                USERPROFILE = $case.UserRoot
                HOME = $case.UserRoot
                APPDATA = $case.AppData
                PRODEX_HOME = $case.ProdexRoot
                FAKE_BUSY_COUNTER = $counterPath
                REAL_PERSIST_SCRIPT = $script:PersistSource
            }
        try {
            Wait-ForCondition -Because 'the retry watcher must publish its ready signal' `
                -Condition { Test-Path -LiteralPath $readyFile -PathType Leaf }
            Set-RunModel -RunHome $snapshot.codexHome -Model 'model-after-busy' `
                -Effort $snapshot.modelReasoningEffort
            Wait-ForCondition -Because 'the watcher must retry and persist after database_busy' -Condition {
                (Get-ProviderState -Case $case -ProviderId 'provider-a').model -eq 'model-after-busy'
            }

            [IO.File]::WriteAllText($stopFile, 'stop')
            $result = Complete-CapturedProcess -Handle $handle -TimeoutMilliseconds 10000
            $handle = $null
            Assert-Equal -Expected 0 -Actual $result.ExitCode -Because 'the retry watcher must stop cleanly'
            Assert-True -Condition ([int](Get-Content -LiteralPath $counterPath -Raw) -ge 2) `
                -Because 'database_busy must cause at least one retry'
            Assert-True -Condition ((Get-Content -LiteralPath $persistenceLog -Raw) -like '*"errorCode":"database_busy"*') `
                -Because 'the transient failure must be retained in structured diagnostics'
        } finally {
            Stop-CapturedProcess -Handle $handle
        }
    }

    Invoke-TestCase -Name 'launcher_defaults_to_direct_without_prodex' -Body {
        $case = New-LauncherFixture
        Set-CaseEnvironment -Case $case
        $prodexLog = Join-Path $case.Root 'prodex-direct-default.json'
        $persistLog = Join-Path $case.Root 'persist-direct-default.log'
        $environment = Get-LauncherEnvironment -Case $case -ProdexLog $prodexLog -PersistLog $persistLog
        $environment.CCSWITCH_CODEX_LAUNCH_MODE = ''
        $process = Start-CapturedProcess `
            -FilePath $script:Pwsh `
            -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $case.LauncherPath, '--probe') `
            -WorkingDirectory $case.UserRoot `
            -Environment $environment
        $launchResult = Complete-CapturedProcess -Handle $process -TimeoutMilliseconds 30000

        Assert-Equal -Expected 2 -Actual $launchResult.ExitCode `
            -Because 'the direct fixture binary must receive the Codex-only arguments'
        Assert-True -Condition ($launchResult.StandardOutput -like '*mode=direct*') `
            -Because 'the launcher summary must report direct mode'
        Assert-True -Condition (-not (Test-Path -LiteralPath $prodexLog)) `
            -Because 'default direct mode must not invoke Prodex'
        Assert-True -Condition (Test-Path -LiteralPath ($prodexLog + '.materialize-home.txt')) `
            -Because 'default direct mode must still materialize a provider snapshot'
        Assert-True -Condition (Test-Path -LiteralPath $persistLog) `
            -Because 'default direct mode must still persist run model state'
        Assert-True -Condition ($launchResult.StandardError -like '*dangerously-bypass-approvals-and-sandbox*') `
            -Because 'default direct mode must retain the existing full-access launch prefix'
    }

    Invoke-TestCase -Name 'launcher_direct_explicit_sandbox_omits_bypass' -Body {
        $case = New-LauncherFixture
        Set-CaseEnvironment -Case $case

        $directProdexLog = Join-Path $case.Root 'prodex-direct-read-only.json'
        $directPersistLog = Join-Path $case.Root 'persist-direct-read-only.log'
        $directEnvironment = Get-LauncherEnvironment `
            -Case $case -ProdexLog $directProdexLog -PersistLog $directPersistLog
        $directEnvironment.CCSWITCH_CODEX_LAUNCH_MODE = ''
        $directProcess = Start-CapturedProcess `
            -FilePath $script:Pwsh `
            -Arguments @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $case.LauncherPath,
                'exec', '--sandbox', 'read-only', '--probe'
            ) `
            -WorkingDirectory $case.UserRoot `
            -Environment $directEnvironment
        $directResult = Complete-CapturedProcess -Handle $directProcess -TimeoutMilliseconds 30000

        Assert-Equal -Expected 2 -Actual $directResult.ExitCode `
            -Because 'the direct fixture binary must receive the explicit sandbox arguments'
        Assert-True -Condition ($directResult.StandardError -like '*--sandbox*') `
            -Because 'the explicit sandbox argument must reach the direct Codex binary'
        Assert-True -Condition (-not $directResult.StandardError.Contains('--dangerously-bypass-approvals-and-sandbox')) `
            -Because 'an explicit sandbox must suppress the automatic direct-mode bypass'
    }

    Invoke-TestCase -Name 'launcher_sandbox_text_after_delimiter_keeps_default_bypass' -Body {
        $case = New-LauncherFixture
        Set-CaseEnvironment -Case $case
        $delimiterProdexLog = Join-Path $case.Root 'prodex-direct-delimiter.json'
        $delimiterPersistLog = Join-Path $case.Root 'persist-direct-delimiter.log'
        $delimiterEnvironment = Get-LauncherEnvironment `
            -Case $case -ProdexLog $delimiterProdexLog -PersistLog $delimiterPersistLog
        $delimiterEnvironment.CCSWITCH_CODEX_LAUNCH_MODE = ''
        $delimiterProcess = Start-CapturedProcess `
            -FilePath $script:Pwsh `
            -Arguments @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $case.LauncherPath,
                'exec', '--', '--sandbox', 'read-only'
            ) `
            -WorkingDirectory $case.UserRoot `
            -Environment $delimiterEnvironment
        $delimiterResult = Complete-CapturedProcess -Handle $delimiterProcess -TimeoutMilliseconds 30000

        Assert-True -Condition ($delimiterResult.StandardError -like '*dangerously-bypass-approvals-and-sandbox*') `
            -Because 'sandbox-like prompt text after -- must not change the launcher safety policy'
    }

    Invoke-TestCase -Name 'launcher_conflicting_sandbox_and_bypass_fails_closed' -Body {
        $case = New-LauncherFixture
        Set-CaseEnvironment -Case $case
        $conflictProdexLog = Join-Path $case.Root 'prodex-direct-conflict.json'
        $conflictPersistLog = Join-Path $case.Root 'persist-direct-conflict.log'
        $conflictEnvironment = Get-LauncherEnvironment `
            -Case $case -ProdexLog $conflictProdexLog -PersistLog $conflictPersistLog
        $conflictEnvironment.CCSWITCH_CODEX_LAUNCH_MODE = ''
        $conflictProcess = Start-CapturedProcess `
            -FilePath $script:Pwsh `
            -Arguments @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $case.LauncherPath,
                'exec', '--sandbox', 'read-only', '--dangerously-bypass-approvals-and-sandbox', '--probe'
            ) `
            -WorkingDirectory $case.UserRoot `
            -Environment $conflictEnvironment
        $conflictResult = Complete-CapturedProcess -Handle $conflictProcess -TimeoutMilliseconds 30000

        Assert-True -Condition ($conflictResult.ExitCode -ne 0) `
            -Because 'conflicting sandbox and bypass flags must fail closed'
        Assert-True -Condition ($conflictResult.StandardError -like '*Conflicting Codex safety options*') `
            -Because 'the conflict failure must identify the unsafe option combination'
    }

    Invoke-TestCase -Name 'launcher_prodex_explicit_sandbox_omits_full_access' -Body {
        $case = New-LauncherFixture
        Set-CaseEnvironment -Case $case
        $prodexLog = Join-Path $case.Root 'prodex-read-only.json'
        $prodexPersistLog = Join-Path $case.Root 'persist-prodex-read-only.log'
        $prodexEnvironment = Get-LauncherEnvironment -Case $case -ProdexLog $prodexLog -PersistLog $prodexPersistLog
        $prodexEnvironment.CCSWITCH_CODEX_LAUNCH_MODE = 'prodex'
        $prodexProcess = Start-CapturedProcess `
            -FilePath $script:Pwsh `
            -Arguments @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $case.LauncherPath,
                'exec', '--sandbox', 'read-only', '--probe'
            ) `
            -WorkingDirectory $case.UserRoot `
            -Environment $prodexEnvironment
        $prodexResult = Complete-CapturedProcess -Handle $prodexProcess -TimeoutMilliseconds 30000

        Assert-Equal -Expected 37 -Actual $prodexResult.ExitCode `
            -Because 'Prodex mode must preserve the downstream Codex exit code with an explicit sandbox'
        $prodexRecord = Get-Content -Raw -LiteralPath $prodexLog | ConvertFrom-Json
        Assert-SequenceEqual `
            -Expected @('run', '--profile', 'fixture-profile', '--no-auto-rotate', 'exec', '--sandbox', 'read-only', '--probe') `
            -Actual @($prodexRecord.arguments) `
            -Because 'Prodex mode must forward the explicit sandbox without adding --full-access'
    }

    Invoke-TestCase -Name 'launcher_prodex_clears_all_inherited_openai_environment' -Body {
        $case = New-LauncherFixture
        Set-CaseEnvironment -Case $case
        $prodexLog = Join-Path $case.Root 'prodex-clean-environment.json'
        $persistLog = Join-Path $case.Root 'persist-clean-environment.log'
        $environment = Get-LauncherEnvironment -Case $case -ProdexLog $prodexLog -PersistLog $persistLog
        $environment.CCSWITCH_CODEX_LAUNCH_MODE = 'prodex'
        $environment.CODEX_HOME = Join-Path $case.Root 'stale-codex-home'
        $environment.OPENAI_API_KEY = 'stale-key'
        $environment.OPENAI_BASE_URL = 'https://stale.example/v1'
        $environment.OPENAI_ORG_ID = 'stale-organization'
        $process = Start-CapturedProcess `
            -FilePath $script:Pwsh `
            -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $case.LauncherPath, '--probe') `
            -WorkingDirectory $case.UserRoot `
            -Environment $environment
        $launchResult = Complete-CapturedProcess -Handle $process -TimeoutMilliseconds 30000

        Assert-Equal -Expected 37 -Actual $launchResult.ExitCode `
            -Because 'environment isolation must preserve the downstream Codex exit code'
        $prodexRecord = Get-Content -Raw -LiteralPath $prodexLog | ConvertFrom-Json
        Assert-Equal -Expected 0 -Actual @($prodexRecord.openAiEnvironment).Count `
            -Because 'Prodex mode must remove every inherited OPENAI_* variable'
        Assert-True -Condition ([string]::IsNullOrWhiteSpace([string]$prodexRecord.codexHome)) `
            -Because 'Prodex mode must not inherit a stale CODEX_HOME'
    }

    Invoke-TestCase -Name 'launcher_rejects_focus_pointer_metadata_mismatch' -Body {
        $case = New-LauncherFixture
        Set-CaseEnvironment -Case $case
        $codexBinRoot = Split-Path -Parent $case.FixedBinary
        $mismatchedBinary = Join-Path $codexBinRoot 'codex-unpatched-fixture.exe'
        Copy-Item -LiteralPath $case.FixedBinary -Destination $mismatchedBinary -Force
        Write-Utf8NoBom -Path (Join-Path $codexBinRoot 'codex-focusfixed-current.txt') -Content $mismatchedBinary

        $prodexLog = Join-Path $case.Root 'prodex-pointer-mismatch.json'
        $persistLog = Join-Path $case.Root 'persist-pointer-mismatch.log'
        $environment = Get-LauncherEnvironment -Case $case -ProdexLog $prodexLog -PersistLog $persistLog
        $process = Start-CapturedProcess `
            -FilePath $script:Pwsh `
            -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $case.LauncherPath, '--version') `
            -WorkingDirectory $case.UserRoot `
            -Environment $environment
        $launchResult = Complete-CapturedProcess -Handle $process -TimeoutMilliseconds 30000

        Assert-True -Condition ($launchResult.ExitCode -ne 0) `
            -Because 'a pointer and metadata mismatch must fail before Codex starts'
        Assert-True -Condition ($launchResult.StandardError -like '*pointer and metadata disagree*') `
            -Because 'the failure must identify the focus patch deployment mismatch'
        Assert-True -Condition (-not (Test-Path -LiteralPath $prodexLog)) `
            -Because 'a mismatched focus binary must not reach Prodex'
        Assert-True -Condition (-not (Test-Path -LiteralPath $persistLog)) `
            -Because 'a mismatched focus binary must not run persistence'
    }

    Invoke-TestCase -Name 'interactive_launcher_uses_update_fallback_but_exec_stays_clean' -Body {
        $case = New-LauncherFixture
        Set-CaseEnvironment -Case $case
        $updateMarker = Join-Path $case.Root 'update-check-called.txt'
        Write-Utf8NoBom -Path $case.UpdateCheckPath -Content @"
[IO.File]::AppendAllText('$updateMarker', 'called' + [Environment]::NewLine)
Write-Host '[Codex update] 0.144.4 available; current 0.144.3.'
"@

        $interactiveProdexLog = Join-Path $case.Root 'prodex-update-fallback-interactive.json'
        $interactivePersistLog = Join-Path $case.Root 'persist-update-fallback-interactive.log'
        $interactiveEnvironment = Get-LauncherEnvironment `
            -Case $case -ProdexLog $interactiveProdexLog -PersistLog $interactivePersistLog
        $interactiveProcess = Start-CapturedProcess `
            -FilePath $script:Pwsh `
            -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $case.LauncherPath) `
            -WorkingDirectory $case.UserRoot `
            -Environment $interactiveEnvironment
        $interactiveResult = Complete-CapturedProcess -Handle $interactiveProcess -TimeoutMilliseconds 30000

        Assert-Equal -Expected 37 -Actual $interactiveResult.ExitCode `
            -Because 'the fallback notice must not change the Codex exit code'
        Assert-True -Condition (
            $interactiveResult.StandardOutput.Contains('[Codex update]') -and
            $interactiveResult.StandardOutput.Contains('0.144.4')
        ) `
            -Because 'an interactive launch must surface the fallback update notice'
        Assert-True -Condition (Test-Path -LiteralPath $updateMarker -PathType Leaf) `
            -Because 'an interactive launch must invoke the fallback update checker'

        Remove-Item -LiteralPath $updateMarker -Force
        $execProdexLog = Join-Path $case.Root 'prodex-update-fallback-exec.json'
        $execPersistLog = Join-Path $case.Root 'persist-update-fallback-exec.log'
        $execEnvironment = Get-LauncherEnvironment -Case $case -ProdexLog $execProdexLog -PersistLog $execPersistLog
        $execProcess = Start-CapturedProcess `
            -FilePath $script:Pwsh `
            -Arguments @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $case.LauncherPath,
                'exec', '--json', '--probe'
            ) `
            -WorkingDirectory $case.UserRoot `
            -Environment $execEnvironment
        $execResult = Complete-CapturedProcess -Handle $execProcess -TimeoutMilliseconds 30000

        Assert-Equal -Expected 37 -Actual $execResult.ExitCode `
            -Because 'suppressing the update notice must preserve the exec exit code'
        Assert-True -Condition (-not (Test-Path -LiteralPath $updateMarker)) `
            -Because 'machine-readable exec must not invoke the update checker'
        Assert-True -Condition (-not $execResult.StandardOutput.Contains('[Codex update]')) `
            -Because 'machine-readable exec output must not contain the fallback update notice'
    }

    Invoke-TestCase -Name 'launcher_surfaces_preserve_arguments_default_cwd_and_exit_code' -Body {
        $case = New-LauncherFixture
        Set-CaseEnvironment -Case $case
        $payloadArguments = @('--probe', 'two words', 'tail')
        $trustedRoot = Join-Path $case.UserRoot 'Documents\Codex-Contexts'
        $trustOverride = Get-ExpectedTrustedProjectOverride -ProjectRoot $trustedRoot
        $expectedProdexArguments = @(
            'run', '--profile', 'fixture-profile', '--no-auto-rotate', '--full-access',
            '-c', $trustOverride, '--cd', $trustedRoot
        ) + $payloadArguments

        foreach ($variant in Get-LaunchSurfaceVariants -Case $case) {
            $safeVariant = $variant.Name -replace '[^A-Za-z0-9_.-]', '-'
            $prodexLog = Join-Path $case.Root ("prodex-{0}.json" -f $safeVariant)
            $persistLog = Join-Path $case.Root ("persist-{0}.log" -f $safeVariant)
            $environment = Get-LauncherEnvironment -Case $case -ProdexLog $prodexLog -PersistLog $persistLog
            $process = Start-CapturedProcess `
                -FilePath $variant.FilePath `
                -Arguments (@($variant.Arguments) + $payloadArguments) `
                -WorkingDirectory $case.UserRoot `
                -Environment $environment
            $launchResult = Complete-CapturedProcess -Handle $process -TimeoutMilliseconds 30000

            Assert-Equal -Expected 37 -Actual $launchResult.ExitCode `
                -Because "$($variant.Name) must preserve the Codex exit code; stderr=$($launchResult.StandardError)"
            Assert-True -Condition ($launchResult.StandardOutput -like '*model=<provider-default>*') `
                -Because "$($variant.Name) must accept and report a provider-default model"
            Assert-True -Condition (Test-Path -LiteralPath $prodexLog -PathType Leaf) -Because "$($variant.Name) must reach fake Prodex"
            Assert-True -Condition (Test-Path -LiteralPath $persistLog -PathType Leaf) -Because "$($variant.Name) must invoke persistence"
            $record = Get-Content -LiteralPath $prodexLog -Raw | ConvertFrom-Json
            Assert-SequenceEqual -Expected $expectedProdexArguments -Actual @($record.arguments) `
                -Because "$($variant.Name) must preserve arguments and trust only the default workspace"
            Assert-Equal -Expected $case.FixedBinary -Actual ([string]$record.codexBin) `
                -Because "$($variant.Name) must set the focus-fixed Codex binary"
            Assert-Equal -Expected (Join-Path $case.RunHome '.prodex-runtime') -Actual ([string]$record.prodexHome) `
                -Because "$($variant.Name) must run Prodex with the snapshot-private state home"
            Assert-Equal -Expected $case.RunHome -Actual ((Get-Content -LiteralPath $persistLog -Raw).Trim()) `
                -Because "$($variant.Name) must persist the exact materialized run home"
        }
    }

    Invoke-TestCase -Name 'single_root_diagnostic_flag_bypasses_materialize_prodex_and_persist' -Body {
        $case = New-LauncherFixture
        Set-CaseEnvironment -Case $case
        $runHomesBefore = @(Get-RunDirectories -Case $case)
        $allVariants = @(Get-LaunchSurfaceVariants -Case $case)
        $directVariant = @($allVariants | Where-Object Name -eq 'PowerShell 7 launcher')[0]

        foreach ($flag in @('--version', '-V', '--help', '-h')) {
            $directHandle = Start-CapturedProcess `
                -FilePath $case.FixedBinary `
                -Arguments @($flag) `
                -WorkingDirectory $case.UserRoot
            $directResult = Complete-CapturedProcess -Handle $directHandle -TimeoutMilliseconds 30000
            $variants = if ($flag -ceq '--version') { $allVariants } else { @($directVariant) }

            foreach ($variant in $variants) {
                $safeFlag = $flag -replace '[^A-Za-z0-9_.-]', '-'
                $safeVariant = $variant.Name -replace '[^A-Za-z0-9_.-]', '-'
                $prodexLog = Join-Path $case.Root ("prodex-fast-{0}-{1}.json" -f $safeFlag, $safeVariant)
                $persistLog = Join-Path $case.Root ("persist-fast-{0}-{1}.log" -f $safeFlag, $safeVariant)
                $environment = Get-LauncherEnvironment -Case $case -ProdexLog $prodexLog -PersistLog $persistLog
                $launchHandle = Start-CapturedProcess `
                    -FilePath $variant.FilePath `
                    -Arguments (@($variant.Arguments) + $flag) `
                    -WorkingDirectory $case.UserRoot `
                    -Environment $environment
                $launchResult = Complete-CapturedProcess -Handle $launchHandle -TimeoutMilliseconds 30000

                Assert-Equal -Expected $directResult.ExitCode -Actual $launchResult.ExitCode `
                    -Because "$($variant.Name) $flag fast path must preserve the native Codex exit code"
                Assert-Equal -Expected $directResult.StandardOutput -Actual $launchResult.StandardOutput `
                    -Because "$($variant.Name) $flag fast path must preserve native Codex stdout"
                Assert-Equal -Expected $directResult.StandardError -Actual $launchResult.StandardError `
                    -Because "$($variant.Name) $flag fast path must preserve native Codex stderr"
                Assert-True -Condition (-not (Test-Path -LiteralPath $prodexLog)) `
                    -Because "$($variant.Name) $flag fast path must not launch Prodex"
                Assert-True -Condition (-not (Test-Path -LiteralPath ($prodexLog + '.materialize-home.txt'))) `
                    -Because "$($variant.Name) $flag fast path must not materialize a run home"
                Assert-True -Condition (-not (Test-Path -LiteralPath $persistLog)) `
                    -Because "$($variant.Name) $flag fast path must not invoke persistence"
            }
        }

        Assert-SequenceEqual -Expected $runHomesBefore -Actual @(Get-RunDirectories -Case $case) `
            -Because 'root diagnostic fast paths must not add run homes'
    }

    Invoke-TestCase -Name 'diagnostic_flag_with_extra_argument_still_uses_prodex' -Body {
        $case = New-LauncherFixture
        Set-CaseEnvironment -Case $case
        $prodexLog = Join-Path $case.Root 'prodex-help-with-extra.json'
        $persistLog = Join-Path $case.Root 'persist-help-with-extra.log'
        $environment = Get-LauncherEnvironment -Case $case -ProdexLog $prodexLog -PersistLog $persistLog
        $process = Start-CapturedProcess `
            -FilePath $script:Pwsh `
            -Arguments @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $case.LauncherPath,
                '--help', '--probe'
            ) `
            -WorkingDirectory $case.UserRoot `
            -Environment $environment
        $launchResult = Complete-CapturedProcess -Handle $process -TimeoutMilliseconds 30000

        Assert-Equal -Expected 37 -Actual $launchResult.ExitCode `
            -Because 'a diagnostic flag plus another argument must remain on the Prodex path'
        Assert-True -Condition (Test-Path -LiteralPath $prodexLog -PathType Leaf) `
            -Because 'the non-root diagnostic request must launch Prodex'
        Assert-True -Condition (Test-Path -LiteralPath ($prodexLog + '.materialize-home.txt') -PathType Leaf) `
            -Because 'the non-root diagnostic request must materialize a run home'
        Assert-True -Condition (Test-Path -LiteralPath $persistLog -PathType Leaf) `
            -Because 'the non-root diagnostic request must persist its run state'
    }

    Invoke-TestCase -Name 'lowercase_config_flag_does_not_suppress_default_working_directory' -Body {
        $case = New-LauncherFixture
        Set-CaseEnvironment -Case $case
        $prodexLog = Join-Path $case.Root 'prodex-lowercase-config.json'
        $persistLog = Join-Path $case.Root 'persist-lowercase-config.log'
        $environment = Get-LauncherEnvironment -Case $case -ProdexLog $prodexLog -PersistLog $persistLog
        $trustedRoot = Join-Path $case.UserRoot 'Documents\Codex-Contexts'
        $trustOverride = Get-ExpectedTrustedProjectOverride -ProjectRoot $trustedRoot
        $process = Start-CapturedProcess `
            -FilePath $script:Pwsh `
            -Arguments @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $case.LauncherPath,
                '-c', 'model_reasoning_effort="high"', '--probe'
            ) `
            -WorkingDirectory $case.UserRoot `
            -Environment $environment
        $launchResult = Complete-CapturedProcess -Handle $process -TimeoutMilliseconds 30000

        Assert-Equal -Expected 37 -Actual $launchResult.ExitCode `
            -Because 'the lowercase config flag must remain a valid Codex argument'
        $record = Get-Content -LiteralPath $prodexLog -Raw | ConvertFrom-Json
        $expectedArguments = @(
            'run', '--profile', 'fixture-profile', '--no-auto-rotate', '--full-access',
            '-c', $trustOverride, '--cd', $trustedRoot,
            '-c', 'model_reasoning_effort="high"', '--probe'
        )
        Assert-SequenceEqual -Expected $expectedArguments -Actual @($record.arguments) `
            -Because 'lowercase -c must not be treated as the case-sensitive -C working-directory flag'
    }

    Invoke-TestCase -Name 'explicit_external_working_directory_does_not_gain_trust_override' -Body {
        $case = New-LauncherFixture
        Set-CaseEnvironment -Case $case
        $externalRoot = Join-Path $case.Root 'external-project'
        [IO.Directory]::CreateDirectory($externalRoot) | Out-Null
        $prodexLog = Join-Path $case.Root 'prodex-external-cwd.json'
        $persistLog = Join-Path $case.Root 'persist-external-cwd.log'
        $environment = Get-LauncherEnvironment -Case $case -ProdexLog $prodexLog -PersistLog $persistLog
        $process = Start-CapturedProcess `
            -FilePath $script:Pwsh `
            -Arguments @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $case.LauncherPath,
                '-C', $externalRoot, '--probe'
            ) `
            -WorkingDirectory $case.UserRoot `
            -Environment $environment
        $launchResult = Complete-CapturedProcess -Handle $process -TimeoutMilliseconds 30000

        Assert-Equal -Expected 37 -Actual $launchResult.ExitCode `
            -Because 'an explicit external working directory must still launch normally'
        $record = Get-Content -LiteralPath $prodexLog -Raw | ConvertFrom-Json
        $expectedArguments = @(
            'run', '--profile', 'fixture-profile', '--no-auto-rotate', '--full-access',
            '-C', $externalRoot, '--probe'
        )
        Assert-SequenceEqual -Expected $expectedArguments -Actual @($record.arguments) `
            -Because 'only the exact trusted workspace may receive a trust override'
    }

    Invoke-TestCase -Name 'inherited_private_prodex_home_uses_user_root_for_materialize_and_persist_bounds' -Body {
        $case = New-LauncherFixture
        Set-CaseEnvironment -Case $case
        $prodexLog = Join-Path $case.Root 'prodex-inherited-private-home.json'
        $persistLog = Join-Path $case.Root 'persist-inherited-private-home.log'
        $environment = Get-LauncherEnvironment -Case $case -ProdexLog $prodexLog -PersistLog $persistLog
        $environment.PRODEX_HOME = Join-Path $case.RunHome '.prodex-runtime'
        $process = Start-CapturedProcess `
            -FilePath $script:Pwsh `
            -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $case.LauncherPath, '--probe') `
            -WorkingDirectory $case.UserRoot `
            -Environment $environment
        $launchResult = Complete-CapturedProcess -Handle $process -TimeoutMilliseconds 30000

        Assert-Equal -Expected 37 -Actual $launchResult.ExitCode `
            -Because 'an inherited run-scoped Prodex home must not break a nested launcher invocation'
        $materializeHome = Get-Content -LiteralPath ($prodexLog + '.materialize-home.txt') -Raw
        Assert-Equal -Expected $case.ProdexRoot -Actual $materializeHome `
            -Because 'materialization must resolve from the user-level Prodex root'
        $persistArguments = Get-Content -LiteralPath ($persistLog + '.args.json') -Raw | ConvertFrom-Json
        Assert-Equal -Expected $case.RunHomesRoot -Actual ([string]$persistArguments.allowedRunHomesRoot) `
            -Because 'persistence must validate the run against the user-level run-homes root'
    }

    Invoke-TestCase -Name 'prodex_update_banner_on_stderr_does_not_abort_launcher' -Body {
        $case = New-LauncherFixture
        Install-FakeProdexCommand -Case $case
        Set-CaseEnvironment -Case $case
        $prodexLog = Join-Path $case.Root 'prodex-update-banner.json'
        $persistLog = Join-Path $case.Root 'persist-update-banner.log'
        $environment = Get-LauncherEnvironment -Case $case -ProdexLog $prodexLog -PersistLog $persistLog
        $windowsPowerShell = (Get-Command powershell.exe -ErrorAction Stop).Source
        $process = Start-CapturedProcess `
            -FilePath $windowsPowerShell `
            -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $case.LauncherPath, '--probe') `
            -WorkingDirectory $case.UserRoot `
            -Environment $environment
        $launchResult = Complete-CapturedProcess -Handle $process -TimeoutMilliseconds 30000

        Assert-Equal -Expected 37 -Actual $launchResult.ExitCode `
            -Because 'the Prodex update banner on stderr must not become a terminating PowerShell error'
        Assert-True -Condition ($launchResult.StandardError.Contains('[ Update Available ]')) `
            -Because 'the fixture must exercise the stderr update-banner path through prodex.cmd'
        Assert-True -Condition (Test-Path -LiteralPath $persistLog -PathType Leaf) `
            -Because 'normal exit cleanup must still persist after the banner'
    }

    Invoke-TestCase -Name 'resume_uuid_reuses_original_run_home_and_private_prodex_state' -Body {
        $case = New-LauncherFixture
        Set-CaseEnvironment -Case $case
        $prodexLog = Join-Path $case.Root 'prodex-resume.json'
        $persistLog = Join-Path $case.Root 'persist-resume.log'
        $environment = Get-LauncherEnvironment -Case $case -ProdexLog $prodexLog -PersistLog $persistLog
        $process = Start-CapturedProcess `
            -FilePath $script:Pwsh `
            -Arguments @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $case.LauncherPath,
                'resume', $case.HistoricalSessionId, '--probe'
            ) `
            -WorkingDirectory $case.UserRoot `
            -Environment $environment
        $launchResult = Complete-CapturedProcess -Handle $process -TimeoutMilliseconds 30000

        Assert-Equal -Expected 37 -Actual $launchResult.ExitCode `
            -Because 'resuming a historical session must preserve the child exit code'
        $record = Get-Content -LiteralPath $prodexLog -Raw | ConvertFrom-Json
        Assert-Equal -Expected $case.HistoricalProdexHome -Actual ([string]$record.prodexHome) `
            -Because 'resume must use the original run private Prodex state'
        Assert-True -Condition (@($record.arguments) -contains 'historical-profile') `
            -Because 'resume must launch the profile bound to the original run home'
        Assert-Equal -Expected $case.HistoricalRunHome -Actual ((Get-Content -LiteralPath $persistLog -Raw).Trim()) `
            -Because 'resume cleanup must persist the original run home'
    }

    Invoke-TestCase -Name 'resume_uuid_does_not_require_current_provider_root' -Body {
        $case = New-LauncherFixture
        Set-CaseEnvironment -Case $case
        Remove-Item -LiteralPath (Join-Path $case.CcSwitchRoot 'settings.json'), $case.DbPath -Force
        $prodexLog = Join-Path $case.Root 'prodex-resume-without-current-root.json'
        $persistLog = Join-Path $case.Root 'persist-resume-without-current-root.log'
        $environment = Get-LauncherEnvironment -Case $case -ProdexLog $prodexLog -PersistLog $persistLog
        $process = Start-CapturedProcess `
            -FilePath $script:Pwsh `
            -Arguments @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $case.LauncherPath,
                'resume', $case.HistoricalSessionId, '--probe'
            ) `
            -WorkingDirectory $case.UserRoot `
            -Environment $environment
        $launchResult = Complete-CapturedProcess -Handle $process -TimeoutMilliseconds 30000

        Assert-Equal -Expected 37 -Actual $launchResult.ExitCode `
            -Because 'a historical resume must not require the current provider root to be discoverable'
        Assert-True -Condition (Test-Path -LiteralPath $prodexLog -PathType Leaf) `
            -Because 'historical resume must still launch its original private Prodex state'
        Assert-Equal -Expected $case.HistoricalRunHome -Actual ((Get-Content -LiteralPath $persistLog -Raw).Trim()) `
            -Because 'historical resume must persist using the root captured by the historical snapshot'
    }

    Invoke-TestCase -Name 'malformed_historical_provider_root_does_not_mask_codex_exit_code' -Body {
        $case = New-LauncherFixture
        Set-CaseEnvironment -Case $case
        $metadataPath = Join-Path $case.HistoricalRunHome 'run-provider.json'
        $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
        $metadata.ccSwitchRoot = 'relative\provider-root'
        Write-Utf8NoBom -Path $metadataPath -Content (($metadata | ConvertTo-Json -Depth 5) + "`n")
        $prodexLog = Join-Path $case.Root 'prodex-malformed-history-root.json'
        $persistLog = Join-Path $case.Root 'persist-malformed-history-root.log'
        $environment = Get-LauncherEnvironment -Case $case -ProdexLog $prodexLog -PersistLog $persistLog
        $process = Start-CapturedProcess `
            -FilePath $script:Pwsh `
            -Arguments @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $case.LauncherPath,
                'resume', $case.HistoricalSessionId, '--probe'
            ) `
            -WorkingDirectory $case.UserRoot `
            -Environment $environment
        $launchResult = Complete-CapturedProcess -Handle $process -TimeoutMilliseconds 30000

        Assert-Equal -Expected 37 -Actual $launchResult.ExitCode `
            -Because 'an invalid historical provider root must not replace the child exit code'
        Assert-True -Condition (Test-Path -LiteralPath $prodexLog -PathType Leaf) `
            -Because 'the historical process must still run before cleanup handles the malformed root'
        Assert-True -Condition (-not (Test-Path -LiteralPath $persistLog)) `
            -Because 'persistence must be skipped when its provider root is invalid'
        $launcherLog = Join-Path $case.ProdexRoot 'logs\ccswitch-event-launcher.log'
        Assert-True -Condition (Test-Path -LiteralPath $launcherLog -PathType Leaf) `
            -Because 'the invalid provider root must be recorded as a persistence failure'
        Assert-True -Condition ((Get-Content -LiteralPath $launcherLog -Raw) -like '*provider data root is missing or invalid*') `
            -Because 'the persistence warning must explain why cleanup was skipped'
    }

    Invoke-TestCase -Name 'resume_last_skips_newer_legacy_run_and_selects_latest_recoverable_session' -Body {
        $case = New-LauncherFixture
        Set-CaseEnvironment -Case $case
        $legacyRunHome = Join-Path $case.RunHomesRoot 'legacy-historical-run'
        $legacySessionsHome = Join-Path $legacyRunHome 'sessions\2026\07\09'
        [IO.Directory]::CreateDirectory($legacySessionsHome) | Out-Null
        $legacyMetadata = [ordered]@{
            profileName = 'legacy-historical-profile'
            codexHome = $legacyRunHome
            providerId = 'provider-legacy-history'
            providerName = 'Legacy Historical Provider'
        }
        Write-Utf8NoBom -Path (Join-Path $legacyRunHome 'run-provider.json') `
            -Content (($legacyMetadata | ConvertTo-Json -Depth 5) + "`n")
        $legacySessionPath = Join-Path $legacySessionsHome 'rollout-2026-07-09T10-00-00-019f45ac-59c0-7000-8000-000000000001.jsonl'
        Write-Utf8NoBom -Path $legacySessionPath -Content '{}'
        [IO.File]::SetLastWriteTimeUtc($legacySessionPath, [DateTime]::UtcNow.AddMinutes(1))

        $prodexLog = Join-Path $case.Root 'prodex-resume-last.json'
        $persistLog = Join-Path $case.Root 'persist-resume-last.log'
        $environment = Get-LauncherEnvironment -Case $case -ProdexLog $prodexLog -PersistLog $persistLog
        $process = Start-CapturedProcess `
            -FilePath $script:Pwsh `
            -Arguments @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $case.LauncherPath,
                'resume', '--last', '--probe'
            ) `
            -WorkingDirectory $case.UserRoot `
            -Environment $environment
        $launchResult = Complete-CapturedProcess -Handle $process -TimeoutMilliseconds 30000

        Assert-Equal -Expected 37 -Actual $launchResult.ExitCode `
            -Because 'resume --last must preserve the child exit code'
        $record = Get-Content -LiteralPath $prodexLog -Raw | ConvertFrom-Json
        Assert-Equal -Expected $case.HistoricalProdexHome -Actual ([string]$record.prodexHome) `
            -Because 'resume --last must skip a newer session whose legacy run cannot be validated'
        Assert-True -Condition (@($record.arguments) -contains 'historical-profile') `
            -Because 'resume --last must launch the newest recoverable session run profile'
    }

    Invoke-TestCase -Name 'resume_without_id_selects_session_across_run_homes' -Body {
        $case = New-LauncherFixture
        Set-CaseEnvironment -Case $case
        $selectedSessionId = '019f45ac-59c0-7000-8000-000000000002'
        $selectedRunHome = Join-Path $case.RunHomesRoot 'selected-historical-run'
        $selectedProdexHome = Join-Path $selectedRunHome '.prodex-runtime'
        $selectedSessionsHome = Join-Path $selectedRunHome 'sessions\2026\07\09'
        [IO.Directory]::CreateDirectory($selectedProdexHome) | Out-Null
        [IO.Directory]::CreateDirectory($selectedSessionsHome) | Out-Null
        $selectedMetadata = [ordered]@{
            schemaVersion = 2
            profileName = 'selected-historical-profile'
            codexHome = $selectedRunHome
            prodexHome = $selectedProdexHome
            providerId = 'provider-selected-history'
            providerName = 'Selected Historical Provider'
            model = 'selected-model'
            modelReasoningEffort = 'medium'
        }
        Write-Utf8NoBom -Path (Join-Path $selectedRunHome 'run-provider.json') `
            -Content (($selectedMetadata | ConvertTo-Json -Depth 5) + "`n")
        Write-Utf8NoBom -Path (Join-Path $selectedProdexHome 'state.json') -Content '{}'
        $selectedSessionPath = Join-Path $selectedSessionsHome "rollout-2026-07-09T10-00-00-$selectedSessionId.jsonl"
        Write-Utf8NoBom -Path $selectedSessionPath -Content '{}'
        [IO.File]::SetLastWriteTimeUtc($selectedSessionPath, [DateTime]::UtcNow.AddDays(-1))

        $prodexLog = Join-Path $case.Root 'prodex-resume-picker.json'
        $persistLog = Join-Path $case.Root 'persist-resume-picker.log'
        $environment = Get-LauncherEnvironment -Case $case -ProdexLog $prodexLog -PersistLog $persistLog
        $process = Start-CapturedProcess `
            -FilePath $script:Pwsh `
            -Arguments @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $case.LauncherPath,
                'resume', '--probe'
            ) `
            -WorkingDirectory $case.UserRoot `
            -Environment $environment `
            -StandardInput "2`n"
        $launchResult = Complete-CapturedProcess -Handle $process -TimeoutMilliseconds 30000

        Assert-Equal -Expected 37 -Actual $launchResult.ExitCode `
            -Because 'the cross-run session picker must preserve the child exit code'
        $record = Get-Content -LiteralPath $prodexLog -Raw | ConvertFrom-Json
        Assert-Equal -Expected $selectedProdexHome -Actual ([string]$record.prodexHome) `
            -Because 'the selected session must use its original private Prodex state'
        Assert-True -Condition (@($record.arguments) -contains 'selected-historical-profile') `
            -Because 'the selected session must use its original profile'
        Assert-True -Condition (@($record.arguments) -contains $selectedSessionId) `
            -Because 'the picker must inject the selected session UUID into the Codex arguments'
    }

    Invoke-TestCase -Name 'resume_picker_cancel_returns_130_without_launching_prodex' -Body {
        $case = New-LauncherFixture
        Set-CaseEnvironment -Case $case
        $prodexLog = Join-Path $case.Root 'prodex-resume-picker-cancel.json'
        $persistLog = Join-Path $case.Root 'persist-resume-picker-cancel.log'
        $environment = Get-LauncherEnvironment -Case $case -ProdexLog $prodexLog -PersistLog $persistLog
        $process = Start-CapturedProcess `
            -FilePath $script:Pwsh `
            -Arguments @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $case.LauncherPath,
                'resume'
            ) `
            -WorkingDirectory $case.UserRoot `
            -Environment $environment `
            -StandardInput "q`n"
        $launchResult = Complete-CapturedProcess -Handle $process -TimeoutMilliseconds 30000

        Assert-Equal -Expected 130 -Actual $launchResult.ExitCode `
            -Because 'canceling the cross-run session picker must use the conventional interrupted exit code'
        Assert-True -Condition (-not (Test-Path -LiteralPath $prodexLog)) `
            -Because 'canceling the picker must not launch Prodex'
        Assert-True -Condition (-not (Test-Path -LiteralPath $persistLog)) `
            -Because 'canceling before a run is selected must not invoke persistence'
    }

    Invoke-TestCase -Name 'persist_failure_does_not_mask_codex_exit_code' -Body {
        $case = New-LauncherFixture
        Set-CaseEnvironment -Case $case
        $prodexLog = Join-Path $case.Root 'prodex-persist-failure.json'
        $persistLog = Join-Path $case.Root 'persist-failure.log'
        $environment = Get-LauncherEnvironment -Case $case -ProdexLog $prodexLog -PersistLog $persistLog -PersistFails $true
        $process = Start-CapturedProcess `
            -FilePath $script:Pwsh `
            -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $case.LauncherPath, '--probe') `
            -WorkingDirectory $case.UserRoot `
            -Environment $environment
        $launchResult = Complete-CapturedProcess -Handle $process -TimeoutMilliseconds 30000

        Assert-Equal -Expected 37 -Actual $launchResult.ExitCode -Because 'persistence failure must not replace the Codex exit code'
        Assert-True -Condition (Test-Path -LiteralPath $persistLog -PathType Leaf) -Because 'the failing persist boundary must have been invoked'
        $launcherLog = Join-Path $case.ProdexRoot 'logs\ccswitch-event-launcher.log'
        Assert-True -Condition (Test-Path -LiteralPath $launcherLog -PathType Leaf) -Because 'persistence failure must be recorded locally'
        Assert-True -Condition ((Get-Content -LiteralPath $launcherLog -Raw) -like '*Model persistence failed*') `
            -Because 'the launcher log must describe the persistence failure without aborting Codex'
        Assert-True -Condition ((Get-Content -LiteralPath $launcherLog -Raw) -like '*"errorCode":"fixture_failure"*') `
            -Because 'the launcher log must preserve the structured persistence error code'
    }

    Invoke-TestCase -Name 'pipeline_stop_returns_130_and_still_persists' -Body {
        $case = New-LauncherFixture
        Set-CaseEnvironment -Case $case
        $prodexLog = Join-Path $case.Root 'prodex-pipeline-stop.json'
        $persistLog = Join-Path $case.Root 'persist-pipeline-stop.log'
        $environment = Get-LauncherEnvironment `
            -Case $case `
            -ProdexLog $prodexLog `
            -PersistLog $persistLog `
            -ProdexStops $true
        $process = Start-CapturedProcess `
            -FilePath $script:Pwsh `
            -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $case.LauncherPath, '--probe') `
            -WorkingDirectory $case.UserRoot `
            -Environment $environment
        $launchResult = Complete-CapturedProcess -Handle $process -TimeoutMilliseconds 30000

        Assert-Equal -Expected 130 -Actual $launchResult.ExitCode `
            -Because 'a pipeline stop without an existing nonzero exit code must return 130'
        Assert-True -Condition (Test-Path -LiteralPath $prodexLog -PathType Leaf) `
            -Because 'the pipeline-stop fixture must reach Prodex before stopping'
        Assert-True -Condition (Test-Path -LiteralPath $persistLog -PathType Leaf) `
            -Because 'launcher finally must persist after a pipeline stop'
        Assert-Equal -Expected $case.RunHome -Actual ((Get-Content -LiteralPath $persistLog -Raw).Trim()) `
            -Because 'pipeline-stop persistence must receive the materialized run home'
    }
} finally {
    Restore-OriginalEnvironment
    if ($KeepTemp) {
        Write-Host "[KEEP] $script:SuiteRoot"
    } else {
        Remove-SuiteRoot
    }
}

foreach ($skip in $script:ShellSkips) {
    Write-Host "[SKIP-SURFACE] $skip" -ForegroundColor Yellow
}

$passed = @($script:Results | Where-Object Status -eq 'PASS').Count
$failed = @($script:Results | Where-Object Status -eq 'FAIL').Count
Write-Host ("Integration summary: passed={0} failed={1} skipped_surfaces={2}" -f $passed, $failed, $script:ShellSkips.Count)

if ($failed -gt 0) {
    exit 1
}
