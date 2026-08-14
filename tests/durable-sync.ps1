[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$repoRoot = Split-Path -Parent $PSScriptRoot
$syncScript = Join-Path $repoRoot 'scripts\sync-codex-durable-home.ps1'
$currentSyncScript = Join-Path $repoRoot 'scripts\sync-ccswitch-current-codex.ps1'
$configScript = Join-Path $repoRoot 'scripts\ccswitch_config.py'
$durableConfigScript = Join-Path $repoRoot 'scripts\codex-durable-config.ps1'
$tokenScript = Join-Path $repoRoot 'scripts\get-ccswitch-provider-token.ps1'
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) "ccswitch-durable-$PID-$([guid]::NewGuid().ToString('N'))"
$globalHome = Join-Path $fixtureRoot 'global'
$currentHome = Join-Path $fixtureRoot 'current'
$runHome = Join-Path $fixtureRoot 'run'
$failures = [System.Collections.Generic.List[string]]::new()

function Assert-True {
    param([bool]$Condition, [string]$Because)
    if (-not $Condition) { throw "Assertion failed: $Because" }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Because)
    if ($Expected -cne $Actual) {
        throw "Assertion failed: $Because. Expected '$Expected', got '$Actual'."
    }
}

function Write-File {
    param([string]$Path, [AllowEmptyString()][string]$Content)
    [IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

try {
    foreach ($directory in @($globalHome, $currentHome, $runHome)) {
        [IO.Directory]::CreateDirectory($directory) | Out-Null
    }
    Write-File -Path (Join-Path $globalHome 'AGENTS.md') -Content "global rules`n"
    Write-File -Path (Join-Path $globalHome 'agents\reviewer.toml') -Content "sandbox_mode = 'read-only'`n"
    Write-File -Path (Join-Path $globalHome 'skills\fixture\SKILL.md') -Content "fixture skill`n"
    Write-File -Path (Join-Path $globalHome 'hooks.json') -Content '{"version":1}'
    Write-File -Path (Join-Path $globalHome 'keybindings.json') -Content '{"key":"value"}'
    Write-File -Path (Join-Path $globalHome 'model-instructions.md') -Content "instructions`n"
    Write-File -Path (Join-Path $globalHome 'review.config.toml') -Content "approval_policy = 'never'`n"
    Write-File -Path (Join-Path $globalHome 'rules\default.rules') -Content "allow`n"
    Write-File -Path (Join-Path $globalHome 'prompts\review.md') -Content "review`n"

    Write-File -Path (Join-Path $currentHome 'agents\old.toml') -Content "stale`n"
    Write-File -Path (Join-Path $currentHome 'skills\old\SKILL.md') -Content "stale`n"
    Write-File -Path (Join-Path $currentHome 'stale-managed.txt') -Content "unmanaged`n"
    Write-File -Path (Join-Path $currentHome 'old.config.toml') -Content "stale = true`n"
    Write-File -Path (Join-Path $currentHome 'sessions\keep.jsonl') -Content "{}`n"
    Write-File -Path (Join-Path $currentHome 'cache\keep.bin') -Content "runtime`n"
    Write-File -Path (Join-Path $currentHome '.ccswitch-managed-durable.json') `
        -Content '{"schemaVersion":1,"mode":"Current","paths":["sessions"]}'

    $unsafeManifestFailed = $false
    try {
        $null = & $syncScript -TargetHome $currentHome -Mode Current -GlobalCodexHome $globalHome -CheckOnly -NoExit -Json
    } catch {
        $unsafeManifestFailed = $true
    }
    Assert-True $unsafeManifestFailed 'runtime paths in the durable manifest must fail closed'
    Assert-True (Test-Path -LiteralPath (Join-Path $currentHome 'sessions\keep.jsonl')) 'unsafe manifest validation must preserve session data'
    Write-File -Path (Join-Path $currentHome '.ccswitch-managed-durable.json') -Content '{"schemaVersion":1,"mode":"Current","paths":["old.config.toml"]}'

    $beforeRuntime = (Get-FileHash -LiteralPath (Join-Path $currentHome 'sessions\keep.jsonl') -Algorithm SHA256).Hash
    $checkOutput = & $syncScript -TargetHome $currentHome -Mode Current -GlobalCodexHome $globalHome -CheckOnly -NoExit -Json
    $check = ($checkOutput | Out-String).Trim() | ConvertFrom-Json
    Assert-True ([bool]$check.changed) 'check-only must report durable drift'
    Assert-True (Test-Path -LiteralPath (Join-Path $currentHome 'stale-managed.txt')) 'check-only must not remove stale files'

    $null = & $syncScript -TargetHome $currentHome -Mode Current -GlobalCodexHome $globalHome -Json
    foreach ($name in @('agents', 'skills')) {
        $entry = Get-Item -LiteralPath (Join-Path $currentHome $name) -Force
        Assert-True (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) `
            "current $name must be a junction"
    }
    Assert-True (Test-Path -LiteralPath (Join-Path $currentHome 'stale-managed.txt')) 'unsupported manifest paths must remain unmanaged'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $currentHome 'old.config.toml'))) `
        'unmanifested stale secondary config must be removed'
    Assert-Equal $beforeRuntime ((Get-FileHash -LiteralPath (Join-Path $currentHome 'sessions\keep.jsonl') -Algorithm SHA256).Hash) `
        'session data must remain unchanged'
    Assert-True (Test-Path -LiteralPath (Join-Path $currentHome 'cache\keep.bin')) 'cache data must remain unmanaged'
    Assert-Equal 'instructions' ((Get-Content -LiteralPath (Join-Path $currentHome 'model-instructions.md') -Raw).Trim()) `
        'durable file must sync from global home'

    New-Item -ItemType Junction -Path (Join-Path $runHome 'agents') -Target (Join-Path $globalHome 'agents') | Out-Null
    Write-File -Path (Join-Path $runHome 'skills\old\SKILL.md') -Content "stale`n"
    $null = & $syncScript -TargetHome $runHome -Mode Run -GlobalCodexHome $globalHome -Json
    foreach ($name in @('agents', 'skills')) {
        $entry = Get-Item -LiteralPath (Join-Path $runHome $name) -Force
        Assert-True (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) `
            "run $name must be a private copy"
    }
    Assert-True (Test-Path -LiteralPath (Join-Path $runHome 'skills\fixture\SKILL.md')) `
        'run must receive every global skill'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $runHome 'skills\old'))) `
        'run sync must remove stale skills'

    $nestedTarget = Join-Path $fixtureRoot 'nested-target'
    Write-File -Path (Join-Path $nestedTarget 'escape.txt') -Content "escape`n"
    New-Item -ItemType Junction -Path (Join-Path $globalHome 'agents\nested-link') -Target $nestedTarget | Out-Null
    $nestedReparseFailed = $false
    try {
        $null = & $syncScript -TargetHome $runHome -Mode Run -GlobalCodexHome $globalHome -CheckOnly -NoExit -Json
    } catch {
        $nestedReparseFailed = $true
    }
    Assert-True $nestedReparseFailed 'run durable sync must reject nested reparse points'
    [IO.Directory]::Delete((Join-Path $globalHome 'agents\nested-link'))

    $agentsReal = Join-Path $globalHome 'agents-real'
    Move-Item -LiteralPath (Join-Path $globalHome 'agents') -Destination $agentsReal
    New-Item -ItemType Junction -Path (Join-Path $globalHome 'agents') -Target $agentsReal | Out-Null
    $rootReparseFailed = $false
    try {
        $null = & $syncScript -TargetHome $runHome -Mode Run -GlobalCodexHome $globalHome -CheckOnly -NoExit -Json
    } catch { $rootReparseFailed = $true }
    Assert-True $rootReparseFailed 'run durable sync must reject a reparse-point source root'
    [IO.Directory]::Delete((Join-Path $globalHome 'agents'))
    Move-Item -LiteralPath $agentsReal -Destination (Join-Path $globalHome 'agents')

    $globalConfigPath = Join-Path $fixtureRoot 'global-config.toml'
    $providerConfigPath = Join-Path $fixtureRoot 'provider-config.toml'
    $selectionConfigPath = Join-Path $fixtureRoot 'selection-config.toml'
    $mergedConfigPath = Join-Path $fixtureRoot 'merged-config.toml'
    $fixtureSecret = 'FIXTURE_DURABLE_SECRET_0123456789'
    Write-File -Path $globalConfigPath -Content @"
approval_policy = "never"
model = "global-model"

[features]
shell_snapshot = true

[mcp_servers.fixture]
command = "fixture-command"
"@
    Write-File -Path $providerConfigPath -Content @"
model = "provider-model"
model_reasoning_effort = "medium"
model_provider = "provider-a"

[model_providers.provider-a]
name = "Provider A"
base_url = "https://provider.invalid/v1"
wire_api = "responses"
requires_openai_auth = false
experimental_bearer_token = "$fixtureSecret"
"@
    Write-File -Path $selectionConfigPath -Content @"
model = "historical-model"
model_reasoning_effort = "ultra"
model_provider = "provider-a"

[model_providers.provider-a]
name = "Provider A"
base_url = "https://provider.invalid/v1"
wire_api = "responses"
"@
    $pythonArguments = @(
        $configScript, 'merge',
        '--global-config', $globalConfigPath,
        '--provider-config', $providerConfigPath,
        '--selection-config', $selectionConfigPath,
        '--provider-id', 'provider-a',
        '--powershell-exe', (Get-Command pwsh).Source,
        '--helper-script', $tokenScript,
        '--output', $mergedConfigPath
    )
    & (Get-Command python).Source @pythonArguments
    Assert-Equal 0 $LASTEXITCODE 'durable config merge must succeed'
    $verifyPython = Join-Path $fixtureRoot 'verify.py'
    $verifyCode = @'
import sys
import tomllib
from pathlib import Path

document = tomllib.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
provider = document["model_providers"]["provider-a"]
assert document["model"] == "historical-model"
assert document["model_reasoning_effort"] == "ultra"
assert document["approval_policy"] == "never"
assert document["features"]["shell_snapshot"] is True
assert document["mcp_servers"]["fixture"]["command"] == "fixture-command"
assert provider["base_url"] == "https://provider.invalid/v1"
assert "experimental_bearer_token" not in provider
assert "requires_openai_auth" not in provider
assert provider["auth"]["args"][-1] == "provider-a"
'@
    Write-File -Path $verifyPython -Content $verifyCode
    & (Get-Command python).Source $verifyPython $mergedConfigPath
    Assert-Equal 0 $LASTEXITCODE 'merged config semantics must verify'
    Assert-True ((Get-Content -LiteralPath $mergedConfigPath -Raw) -notlike "*$fixtureSecret*") `
        'merged config must not contain plaintext credential'

    Write-File -Path $selectionConfigPath -Content @"
model_provider = "provider-a"

[model_providers.provider-a]
name = "Provider A"
base_url = "https://provider.invalid/v1"
wire_api = "responses"
"@
    & (Get-Command python).Source @pythonArguments
    Assert-Equal 0 $LASTEXITCODE 'provider-default config merge must succeed'
    $defaultVerifyCode = @'
import sys
import tomllib
from pathlib import Path

document = tomllib.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert "model" not in document
assert "model_reasoning_effort" not in document
'@
    Write-File -Path $verifyPython -Content $defaultVerifyCode
    & (Get-Command python).Source $verifyPython $mergedConfigPath
    Assert-Equal 0 $LASTEXITCODE 'provider-default merge must not inherit the global model'

    Write-File -Path $selectionConfigPath -Content @"
model = "official-model"
model_reasoning_effort = "high"
"@
    . $durableConfigScript
    $officialMerged = Get-CcSwitchDurableConfig `
        -ProviderConfigText (Get-Content -LiteralPath $providerConfigPath -Raw) `
        -SelectionConfigText (Get-Content -LiteralPath $selectionConfigPath -Raw) `
        -ProviderId 'codex-official' `
        -GlobalConfigPath $globalConfigPath `
        -OfficialProvider
    Write-File -Path $mergedConfigPath -Content $officialMerged
    $officialVerifyCode = @'
import sys
import tomllib
from pathlib import Path

document = tomllib.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert document["model"] == "official-model"
assert document["model_reasoning_effort"] == "high"
assert document["approval_policy"] == "never"
assert document["features"]["shell_snapshot"] is True
assert document["mcp_servers"]["fixture"]["command"] == "fixture-command"
assert "model_provider" not in document
assert "model_providers" not in document
'@
    Write-File -Path $verifyPython -Content $officialVerifyCode
    & (Get-Command python).Source $verifyPython $mergedConfigPath
    Assert-Equal 0 $LASTEXITCODE 'official merge must preserve global durable settings without custom auth'

    $currentSyncUser = Join-Path $fixtureRoot 'current-sync-user'
    $currentSyncGlobal = Join-Path $currentSyncUser '.codex'
    $currentSyncRoot = Join-Path $currentSyncUser '.cc-switch'
    $currentSyncHome = Join-Path $currentSyncUser '.prodex\manual-homes\ccswitch-current'
    foreach ($directory in @($currentSyncGlobal, $currentSyncRoot, $currentSyncHome)) {
        [IO.Directory]::CreateDirectory($directory) | Out-Null
    }
    Write-File -Path (Join-Path $currentSyncGlobal 'config.toml') -Content (Get-Content -LiteralPath $globalConfigPath -Raw)
    Write-File -Path (Join-Path $currentSyncGlobal 'AGENTS.md') -Content "fixture rules`n"
    Write-File -Path (Join-Path $currentSyncGlobal 'agents\reviewer.toml') -Content "sandbox_mode = 'read-only'`n"
    Write-File -Path (Join-Path $currentSyncGlobal 'skills\fixture\SKILL.md') -Content "fixture skill`n"
    Write-File -Path (Join-Path $currentSyncGlobal 'browser-client-trust.json') -Content '{"schemaVersion":1,"trustedBrowserClientSha256":["0000000000000000000000000000000000000000000000000000000000000000"]}'
    Write-File -Path (Join-Path $currentSyncRoot 'settings.json') -Content '{"currentProviderCodex":"provider-a"}'
    $currentSyncDatabasePython = Join-Path $fixtureRoot 'current_sync_database.py'
    $currentSyncDatabaseCode = @'
import json
import sqlite3
import sys

database, provider_config = sys.argv[1:3]
settings = json.dumps({"config": open(provider_config, encoding="utf-8").read(), "auth": {}}, separators=(",", ":"))
with sqlite3.connect(database) as connection:
    connection.execute("create table providers (id text primary key,name text,website_url text,app_type text,category text,sort_index integer,is_current integer,settings_config text)")
    connection.execute("insert into providers values ('provider-a','Provider A',null,'codex',null,1,1,?)", (settings,))
'@
    Write-File -Path $currentSyncDatabasePython -Content $currentSyncDatabaseCode
    & (Get-Command python).Source $currentSyncDatabasePython (Join-Path $currentSyncRoot 'cc-switch.db') $providerConfigPath
    Assert-Equal 0 $LASTEXITCODE 'current sync fixture database must be created'
    $previousUserProfile = $env:USERPROFILE
    try {
        $env:USERPROFILE = $currentSyncUser
        $null = & $currentSyncScript -CcSwitchRoot $currentSyncRoot -CodexHome $currentSyncHome -CheckOnly -Quiet
    } finally {
        $env:USERPROFILE = $previousUserProfile
    }

    Write-Output '[PASS] durable config and managed-home sync fixture'
} catch {
    $failures.Add("$($_)`n$($_.ScriptStackTrace)") | Out-Null
    Write-Error -ErrorRecord $_ -ErrorAction Continue
} finally {
    if (Test-Path -LiteralPath $fixtureRoot) {
        $resolved = [IO.Path]::GetFullPath($fixtureRoot)
        $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if ($resolved.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Leaf $resolved) -like 'ccswitch-durable-*') {
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }
}

if ($failures.Count -gt 0) {
    throw "Durable sync fixture failures: $($failures -join ' | ')"
}
