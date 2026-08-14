[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$repoRoot = Split-Path -Parent $PSScriptRoot
$migrationScript = Join-Path $repoRoot 'scripts\ccswitch_credential_migration.py'
$auditScript = Join-Path $repoRoot 'scripts\audit-codex-provider-auth.py'
$wrapperScript = Join-Path $repoRoot 'scripts\invoke-ccswitch-credential-migration.ps1'
$restoreScript = Join-Path $repoRoot 'scripts\restore-ccswitch-credential-rollback.ps1'
$tokenScript = Join-Path $repoRoot 'scripts\get-ccswitch-provider-token.ps1'
$cleanupScript = Join-Path $repoRoot 'scripts\remove-stale-ccswitch-data.ps1'
$vaultFunctions = Join-Path $repoRoot 'scripts\ccswitch-credential-vault.ps1'
$powershellHostFunctions = Join-Path $repoRoot 'scripts\powershell-host.ps1'
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) "ccswitch-credential-$PID-$([guid]::NewGuid().ToString('N'))"
$userRoot = Join-Path $fixtureRoot 'user'
$ccRoot = Join-Path $userRoot '.cc-switch'
$globalHome = Join-Path $userRoot '.codex'
$prodexRoot = Join-Path $userRoot '.prodex'
$currentHome = Join-Path $prodexRoot 'manual-homes\ccswitch-current'
$runHomes = Join-Path $prodexRoot 'manual-homes\ccswitch-runs'
$runHome = Join-Path $runHomes 'ccswitch-run-fixture'
$missingConfigRunHome = Join-Path $runHomes 'ccswitch-run-missing-config'
$officialRunHome = Join-Path $runHomes 'ccswitch-run-official'
$vaultRoot = Join-Path $prodexRoot 'credentials\ccswitch-codex'
$rollbackRoot = Join-Path $vaultRoot 'rollbacks\fixture'
$fileCompensationRollbackRoot = Join-Path $vaultRoot 'rollbacks\file-compensation'
$databaseCompensationRollbackRoot = Join-Path $vaultRoot 'rollbacks\database-compensation'
$database = Join-Path $ccRoot 'cc-switch.db'
$secretAlpha = 'FIXTURE_SECRET_ALPHA_0123456789'
$secretBeta = 'FIXTURE_SECRET_BETA_0123456789'
$secretGlobal = 'FIXTURE_SECRET_GLOBAL_0123456789'
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

function Write-Utf8NoBom {
    param([string]$Path, [AllowEmptyString()][string]$Content)
    [IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

function Get-Hash {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

try {
    [IO.Directory]::CreateDirectory($ccRoot) | Out-Null
    [IO.Directory]::CreateDirectory($globalHome) | Out-Null
    [IO.Directory]::CreateDirectory($currentHome) | Out-Null
    [IO.Directory]::CreateDirectory($runHome) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $missingConfigRunHome 'sessions')) | Out-Null
    [IO.Directory]::CreateDirectory($officialRunHome) | Out-Null
    . $vaultFunctions
    . $powershellHostFunctions

    $fixturePython = Join-Path $fixtureRoot 'create_fixture.py'
    $fixtureCode = @'
import json
import sqlite3
import sys
from pathlib import Path

database = Path(sys.argv[1])
alpha, beta = sys.argv[2:4]

def third_party(provider_id, token, bearer=True):
    provider = (
        f'model = "model-{provider_id}"\n'
        'model_reasoning_effort = "high"\n'
        f'model_provider = "{provider_id}"\n\n'
        f'[model_providers.{provider_id}]\n'
        f'name = "Fixture {provider_id}"\n'
        f'base_url = "https://{provider_id}.invalid/v1"\n'
        'wire_api = "responses"\n'
        'requires_openai_auth = false\n'
    )
    if bearer:
        provider += f'experimental_bearer_token = {json.dumps(token)}\n'
    return json.dumps(
        {"config": provider, "auth": {"auth_mode": "apikey", "OPENAI_API_KEY": token}},
        separators=(",", ":"),
    )

official_settings = json.dumps(
    {
        "config": 'model = "gpt-official"\nmodel_reasoning_effort = "high"\n',
        "auth": {"auth_mode": "chatgpt", "tokens": {"access_token": "OFFICIAL_FIXTURE_TOKEN"}},
    },
    separators=(",", ":"),
)
with sqlite3.connect(database) as connection:
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
        """
    )
    connection.execute(
        "insert into providers values ('provider-a','Provider A',null,'codex',null,1,1,?)",
        (third_party("provider-a", alpha),),
    )
    connection.execute(
        "insert into providers values ('provider-b','Provider B',null,'codex',null,2,0,?)",
        (third_party("provider-b", beta, False),),
    )
    connection.execute(
        "insert into providers values ('codex-official','OpenAI Official',null,'codex','official',3,0,?)",
        (official_settings,),
    )
'@
    Write-Utf8NoBom -Path $fixturePython -Content $fixtureCode
    & (Get-Command python).Source $fixturePython $database $secretAlpha $secretBeta
    Assert-Equal 0 $LASTEXITCODE 'fixture database creation must succeed'

    $providerConfig = @"
model = "model-provider-a"
model_reasoning_effort = "high"
model_provider = "provider-a"

[model_providers.provider-a]
name = "Fixture provider-a"
base_url = "https://provider-a.invalid/v1"
wire_api = "responses"
requires_openai_auth = false
experimental_bearer_token = "$secretAlpha"
"@
    $globalConfig = @"
approval_policy = "never"
# historical leak: $secretAlpha
model = "global-model"
model_provider = "global-proxy"

[features]
shell_snapshot = true

[model_providers.global-proxy]
name = "Global fixture"
base_url = "https://global.invalid/v1"
wire_api = "responses"
experimental_bearer_token = "$secretGlobal"
"@
    Write-Utf8NoBom -Path (Join-Path $globalHome 'config.toml') -Content $globalConfig
    Write-Utf8NoBom -Path (Join-Path $globalHome 'auth.json') -Content '{"auth_mode":"chatgpt","tokens":{"access_token":"OFFICIAL_GLOBAL_FIXTURE"}}'
    Write-Utf8NoBom -Path (Join-Path $ccRoot 'settings.json') -Content '{"currentProviderCodex":"provider-a"}'
    Write-Utf8NoBom -Path (Join-Path $currentHome 'config.toml') -Content $providerConfig
    Write-Utf8NoBom -Path (Join-Path $currentHome 'auth.json') -Content ("{`"OPENAI_API_KEY`":`"$secretAlpha`"}")
    Write-Utf8NoBom -Path (Join-Path $runHome 'config.toml') -Content $providerConfig
    Write-Utf8NoBom -Path (Join-Path $runHome 'auth.json') -Content ("{`"OPENAI_API_KEY`":`"$secretAlpha`"}")
    Write-Utf8NoBom -Path (Join-Path $runHome 'run-provider.json') -Content '{"providerId":"provider-a","configSha256":"old","authSha256":"old"}'
    Write-Utf8NoBom -Path (Join-Path $runHome 'history.jsonl') -Content ("{`"message`":`"$secretAlpha`"}`n")
    Write-Utf8NoBom -Path (Join-Path $officialRunHome 'config.toml') -Content "model = 'gpt-official'`nmodel_reasoning_effort = 'high'`n"
    Write-Utf8NoBom -Path (Join-Path $officialRunHome 'auth.json') -Content '{"auth_mode":"chatgpt","tokens":{"access_token":"OFFICIAL_RUN_FIXTURE"}}'
    Write-Utf8NoBom -Path (Join-Path $officialRunHome 'run-provider.json') -Content '{"providerId":"codex-official","configSha256":"official-old","authSha256":"official-old"}'
    Write-Utf8NoBom -Path (Join-Path $missingConfigRunHome 'run-provider.json') -Content '{"providerId":"provider-b","model":"historical-model","modelReasoningEffort":"medium"}'
    Write-Utf8NoBom -Path (Join-Path $missingConfigRunHome 'sessions\rollout.jsonl') -Content '{"recoverable":true}'
    $officialRunConfigBefore = Get-Hash -Path (Join-Path $officialRunHome 'config.toml')
    $officialRunAuthBefore = Get-Hash -Path (Join-Path $officialRunHome 'auth.json')

    $beforeDatabase = Get-Hash -Path $database
    $beforeGlobal = Get-Hash -Path (Join-Path $globalHome 'config.toml')
    $auditJson = & $wrapperScript `
        -CcSwitchRoot $ccRoot `
        -GlobalCodexHome $globalHome `
        -ProdexRoot $prodexRoot `
        -Json
    $audit = ($auditJson | Out-String).Trim() | ConvertFrom-Json
    Assert-True ([bool]$audit.ok) 'dry-run audit must succeed'
    Assert-Equal 2 ([int]$audit.plaintextProviderCount) 'dry-run must detect both plaintext providers'
    Assert-Equal $beforeDatabase (Get-Hash -Path $database) 'dry-run must not change the database'
    Assert-Equal $beforeGlobal (Get-Hash -Path (Join-Path $globalHome 'config.toml')) 'dry-run must not change global config'

    $globalAuthPath = Join-Path $globalHome 'auth.json'
    $globalAuthBefore = Get-Hash -Path $globalAuthPath
    $collisionAuth = @{ auth_mode = 'chatgpt'; tokens = @{ access_token = $secretAlpha } } | ConvertTo-Json -Compress
    Write-Utf8NoBom -Path $globalAuthPath -Content $collisionAuth
    $collisionAuditJson = & $wrapperScript -CcSwitchRoot $ccRoot -GlobalCodexHome $globalHome -ProdexRoot $prodexRoot -Json
    $collisionAudit = ($collisionAuditJson | Out-String).Trim() | ConvertFrom-Json
    Assert-True (-not [bool]$collisionAudit.ok) 'third-party tokens in official authentication must fail before migration writes'
    Assert-Equal $beforeDatabase (Get-Hash -Path $database) 'official token collision audit must not change the database'
    Assert-Equal $beforeGlobal (Get-Hash -Path (Join-Path $globalHome 'config.toml')) 'official token collision audit must not change global config'
    Write-Utf8NoBom -Path $globalAuthPath -Content '{"auth_mode":"chatgpt","tokens":{"access_token":"OFFICIAL_GLOBAL_FIXTURE"}}'
    Assert-Equal $globalAuthBefore (Get-Hash -Path $globalAuthPath) 'official authentication fixture must be restored exactly'

    $reservedGlobalConfig = $globalConfig + [Environment]::NewLine + '[model_providers.openai]' + [Environment]::NewLine + 'experimental_bearer_token = "' + $secretAlpha + '"' + [Environment]::NewLine
    Write-Utf8NoBom -Path (Join-Path $globalHome 'config.toml') -Content $reservedGlobalConfig
    $reservedAuditJson = & $wrapperScript -CcSwitchRoot $ccRoot -GlobalCodexHome $globalHome -ProdexRoot $prodexRoot -Json
    $reservedAudit = ($reservedAuditJson | Out-String).Trim() | ConvertFrom-Json
    Assert-True (-not [bool]$reservedAudit.ok) 'reserved global provider credentials must fail audit'
    Write-Utf8NoBom -Path (Join-Path $globalHome 'config.toml') -Content $globalConfig

    $conflictPython = Join-Path $fixtureRoot 'conflict.py'
    $conflictCode = @'
import json
import sqlite3
import sys

database, token, replacement = sys.argv[1:4]
with sqlite3.connect(database) as connection:
    row = connection.execute("select settings_config from providers where id='provider-a'").fetchone()
    settings = json.loads(row[0])
    settings["config"] = settings["config"].replace(token, replacement)
    connection.execute("update providers set settings_config=? where id='provider-a'", (json.dumps(settings, separators=(",", ":")),))
'@
    Write-Utf8NoBom -Path $conflictPython -Content $conflictCode
    & (Get-Command python).Source $conflictPython $database $secretAlpha 'FIXTURE_CONFLICT_BEARER'
    $conflictAuditJson = & $wrapperScript -CcSwitchRoot $ccRoot -GlobalCodexHome $globalHome -ProdexRoot $prodexRoot -Json
    $conflictAudit = ($conflictAuditJson | Out-String).Trim() | ConvertFrom-Json
    Assert-True (-not [bool]$conflictAudit.ok) 'conflicting provider credential sources must fail audit'
    & (Get-Command python).Source $conflictPython $database 'FIXTURE_CONFLICT_BEARER' $secretAlpha

    $officialMutationPython = Join-Path $fixtureRoot 'official_mutation.py'
    $officialMutationCode = @'
import json
import sqlite3
import sys

database, command, backup_path, token = sys.argv[1:5]
with sqlite3.connect(database) as connection:
    if command == "inject":
        original = connection.execute("select settings_config from providers where id='codex-official'").fetchone()[0]
        open(backup_path, "w", encoding="utf-8").write(original)
        settings = json.loads(original)
        settings["config"] += (
            'model_provider = "custom-official"\n'
            '[model_providers.custom-official]\n'
            'base_url = "https://official.invalid/v1"\n'
            f'experimental_bearer_token = "{token}"\n'
        )
        connection.execute(
            "update providers set settings_config=? where id='codex-official'",
            (json.dumps(settings, separators=(",", ":")),),
        )
    else:
        original = open(backup_path, encoding="utf-8").read()
        connection.execute("update providers set settings_config=? where id='codex-official'", (original,))
'@
    $officialBackupPath = Join-Path $fixtureRoot 'official-settings.json'
    Write-Utf8NoBom -Path $officialMutationPython -Content $officialMutationCode
    & (Get-Command python).Source $officialMutationPython $database inject $officialBackupPath $secretAlpha
    Assert-Equal 0 $LASTEXITCODE 'official provider mutation must be created'
    $officialRouteAuditJson = & $wrapperScript -CcSwitchRoot $ccRoot -GlobalCodexHome $globalHome -ProdexRoot $prodexRoot -Json
    $officialRouteAudit = ($officialRouteAuditJson | Out-String).Trim() | ConvertFrom-Json
    Assert-True (-not [bool]$officialRouteAudit.ok) 'an official category with custom routing or API-key auth must fail audit'
    & (Get-Command python).Source $officialMutationPython $database restore $officialBackupPath $secretAlpha
    Assert-Equal 0 $LASTEXITCODE 'official provider fixture must be restored'

    & (Get-Command python).Source -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute('update providers set is_current=1 where id=?',('provider-b',)); c.commit()" $database
    $multipleCurrentJson = & $wrapperScript -CcSwitchRoot $ccRoot -GlobalCodexHome $globalHome -ProdexRoot $prodexRoot -Json
    $multipleCurrentAudit = ($multipleCurrentJson | Out-String).Trim() | ConvertFrom-Json
    Assert-True (-not [bool]$multipleCurrentAudit.ok) 'multiple current providers must fail migration audit'
    & (Get-Command python).Source -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute('update providers set is_current=0 where id=?',('provider-b',)); c.commit()" $database
    Write-Utf8NoBom -Path (Join-Path $ccRoot 'settings.json') -Content '{"currentProviderCodex":"provider-b"}'
    $mismatchedSettingsJson = & $wrapperScript -CcSwitchRoot $ccRoot -GlobalCodexHome $globalHome -ProdexRoot $prodexRoot -Json
    $mismatchedSettingsAudit = ($mismatchedSettingsJson | Out-String).Trim() | ConvertFrom-Json
    Assert-True (-not [bool]$mismatchedSettingsAudit.ok) 'settings and database provider disagreement must fail migration audit'
    Write-Utf8NoBom -Path (Join-Path $ccRoot 'settings.json') -Content '{"currentProviderCodex":"provider-a"}'

    $unreadableLog = Join-Path $currentHome 'unreadable.log'
    Write-Utf8NoBom -Path $unreadableLog -Content $secretAlpha
    $unreadableAcl = Get-Acl -LiteralPath $unreadableLog
    $blockedAcl = Get-Acl -LiteralPath $unreadableLog
    $denyRead = [System.Security.AccessControl.FileSystemAccessRule]::new(
        [System.Security.Principal.WindowsIdentity]::GetCurrent().User,
        [System.Security.AccessControl.FileSystemRights]::ReadData,
        [System.Security.AccessControl.AccessControlType]::Deny
    )
    $blockedAcl.AddAccessRule($denyRead) | Out-Null
    Set-Acl -LiteralPath $unreadableLog -AclObject $blockedAcl
    try {
        $unreadableAuditJson = & $wrapperScript -CcSwitchRoot $ccRoot -GlobalCodexHome $globalHome -ProdexRoot $prodexRoot -Json
        $unreadableAudit = ($unreadableAuditJson | Out-String).Trim() | ConvertFrom-Json
        Assert-True (-not [bool]$unreadableAudit.ok) 'an unreadable managed text file must fail audit'
    } finally {
        Set-Acl -LiteralPath $unreadableLog -AclObject $unreadableAcl
        Remove-Item -LiteralPath $unreadableLog -Force
    }

    Set-CcSwitchCredentialVaultAcl -VaultRoot $vaultRoot
    $ownerError = $null
    try {
        Assert-CcSwitchCredentialOwnerSid -OwnerSid 'S-1-1-0' -AllowedSids (Get-AllowedCredentialSids)
    } catch { $ownerError = $_ }
    Assert-True ($null -ne $ownerError) 'a disallowed vault owner SID must fail closed'
    $officialBefore = & (Get-Command python).Source -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); print(c.execute('select settings_config from providers where id=?',('codex-official',)).fetchone()[0])" $database
    $powershell = Get-CurrentPowerShellExecutable
    $baseApplyArguments = @(
        $migrationScript, 'apply',
        '--database', $database,
        '--global-config', (Join-Path $globalHome 'config.toml'),
        '--vault-root', $vaultRoot,
        '--helper-script', $tokenScript,
        '--powershell-exe', $powershell,
        '--current-home', $currentHome,
        '--run-homes', $runHomes,
        '--scan-root', $globalHome,
        '--scan-root', $currentHome,
        '--scan-root', $runHomes
    )
    $readOnlyLeak = Join-Path $currentHome 'read-only-leak.log'
    $backupLeak = Join-Path $currentHome 'auth.json.bak-fixture'
    $extensionlessLeak = Join-Path $currentHome 'credential-leak'
    Write-Utf8NoBom -Path $backupLeak -Content $secretAlpha
    Write-Utf8NoBom -Path $extensionlessLeak -Content $secretBeta
    Write-Utf8NoBom -Path $readOnlyLeak -Content $secretAlpha
    (Get-Item -LiteralPath $readOnlyLeak).IsReadOnly = $true
    $databaseBeforeFailure = Get-Hash -Path $database
    $currentConfigBeforeFailure = Get-Hash -Path (Join-Path $currentHome 'config.toml')
    $runConfigBeforeFailure = Get-Hash -Path (Join-Path $runHome 'config.toml')
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $fileFailureOutput = @(& (Get-Command python).Source @baseApplyArguments '--rollback-root' $fileCompensationRollbackRoot 2>&1) | Out-String
        $fileFailureExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    Assert-True ($fileFailureExitCode -ne 0) 'a redaction write failure must fail migration'
    Assert-True ($fileFailureOutput -notlike "*$secretAlpha*" -and $fileFailureOutput -notlike "*$secretBeta*") 'file-stage failure output must not contain a credential'
    Assert-Equal $databaseBeforeFailure (Get-Hash -Path $database) 'file-stage failure must leave the database unchanged'
    Assert-Equal $beforeGlobal (Get-Hash -Path (Join-Path $globalHome 'config.toml')) 'file-stage failure must restore global config'
    Assert-Equal $currentConfigBeforeFailure (Get-Hash -Path (Join-Path $currentHome 'config.toml')) 'file-stage failure must restore current config'
    Assert-Equal $runConfigBeforeFailure (Get-Hash -Path (Join-Path $runHome 'config.toml')) 'file-stage failure must restore run config'
    Assert-Equal 0 @(Get-ChildItem -LiteralPath $vaultRoot -File -Filter '*.dpapi').Count 'file-stage failure must restore the original vault file set'
    (Get-Item -LiteralPath $readOnlyLeak).IsReadOnly = $false
    Remove-Item -LiteralPath $readOnlyLeak -Force

    $triggerPython = Join-Path $fixtureRoot 'trigger.py'
    $triggerCode = @'
import sqlite3
import sys

database, command = sys.argv[1:3]
with sqlite3.connect(database) as connection:
    if command == "create":
        connection.execute(
            "create trigger migration_post_commit_failure after update of settings_config on providers "
            "begin update providers set is_current=1 where id='provider-b'; end"
        )
    else:
        connection.execute("drop trigger migration_post_commit_failure")
'@
    Write-Utf8NoBom -Path $triggerPython -Content $triggerCode
    & (Get-Command python).Source $triggerPython $database create
    Assert-Equal 0 $LASTEXITCODE 'post-commit failure trigger must be created'
    try {
        $ErrorActionPreference = 'Continue'
        $databaseFailureOutput = @(& (Get-Command python).Source @baseApplyArguments '--rollback-root' $databaseCompensationRollbackRoot 2>&1) | Out-String
        $databaseFailureExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    Assert-True ($databaseFailureExitCode -ne 0) 'post-commit audit failure must fail migration'
    Assert-True ($databaseFailureOutput -notlike "*$secretAlpha*" -and $databaseFailureOutput -notlike "*$secretBeta*") 'database compensation failure output must not contain a credential'
    $compensatedAuditJson = & $wrapperScript -CcSwitchRoot $ccRoot -GlobalCodexHome $globalHome -ProdexRoot $prodexRoot -Json
    $compensatedAudit = ($compensatedAuditJson | Out-String).Trim() | ConvertFrom-Json
    Assert-True ([bool]$compensatedAudit.ok) 'post-commit failure must restore an auditable pre-migration state'
    Assert-Equal 2 ([int]$compensatedAudit.plaintextProviderCount) 'database compensation must restore plaintext provider records'
    Assert-Equal $beforeGlobal (Get-Hash -Path (Join-Path $globalHome 'config.toml')) 'database compensation must restore global config'
    & (Get-Command python).Source $triggerPython $database drop
    Assert-Equal 0 $LASTEXITCODE 'post-commit failure trigger must be removed'

    $applyArguments = @($baseApplyArguments + @('--rollback-root', $rollbackRoot))
    $applyJson = @(& (Get-Command python).Source @applyArguments) | Out-String
    Assert-Equal 0 $LASTEXITCODE 'fixture migration must succeed'
    Assert-True ($applyJson -notlike "*$secretAlpha*" -and $applyJson -notlike "*$secretBeta*" -and $applyJson -notlike "*$secretGlobal*") `
        'migration output must not contain a credential'
    $applied = $applyJson.Trim() | ConvertFrom-Json
    Assert-Equal 'applied' ([string]$applied.mode) 'migration must report applied mode'
    Assert-True (Test-Path -LiteralPath (Join-Path $missingConfigRunHome 'config.toml')) 'a historical run without config must be reconstructed from metadata'
    Assert-True ((Get-Content -LiteralPath (Join-Path $missingConfigRunHome 'config.toml') -Raw) -like '*historical-model*') 'reconstructed run config must retain its historical model selection'
    Assert-True (Test-Path -LiteralPath (Join-Path $missingConfigRunHome 'sessions\rollout.jsonl')) 'reconstructing a run config must preserve recoverable session data'
    Assert-True ((Get-Content -LiteralPath $backupLeak -Raw) -notlike "*$secretAlpha*") 'backup-suffixed text files must be redacted'
    Assert-True ((Get-Content -LiteralPath $extensionlessLeak -Raw) -notlike "*$secretBeta*") 'extensionless text files must be redacted'

    $tokenOutput = & $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass `
        -File $tokenScript -ProviderId 'provider-a' -VaultRoot $vaultRoot
    Assert-Equal $secretAlpha ([string]$tokenOutput) 'DPAPI helper must round-trip the provider token'
    $globalTokenOutput = & $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass `
        -File $tokenScript -ProviderId 'global:global-proxy' -VaultRoot $vaultRoot
    Assert-Equal $secretGlobal ([string]$globalTokenOutput) 'DPAPI helper must round-trip the global provider token'

    $credentialPath = Get-CcSwitchCredentialPath -VaultRoot $vaultRoot -ProviderId 'provider-a'
    $aclGrantArguments = @($credentialPath, '/grant', '*S-1-1-0:(R)')
    & icacls.exe @aclGrantArguments | Out-Null
    $aclError = $null
    try {
        $null = & $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass `
            -File $tokenScript -ProviderId 'provider-a' -VaultRoot $vaultRoot 2>&1
        if ($LASTEXITCODE -ne 0) { $aclError = 'helper exited nonzero' }
    } catch { $aclError = $_ }
    Assert-True ($null -ne $aclError) 'a disallowed ACL entry must fail closed'
    $aclRemoveArguments = @($credentialPath, '/remove:g', '*S-1-1-0')
    & icacls.exe @aclRemoveArguments | Out-Null

    $emptyCredentialPath = Get-CcSwitchCredentialPath -VaultRoot $vaultRoot -ProviderId 'empty-fixture'
    $emptyCipher = [System.Security.Cryptography.ProtectedData]::Protect(
        [Text.Encoding]::UTF8.GetBytes(''),
        (Get-CcSwitchCredentialEntropy -ProviderId 'empty-fixture'),
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    $header = [Text.Encoding]::ASCII.GetBytes("CCSWITCH-DPAPI-1`0")
    $emptyPayload = [byte[]]::new($header.Length + $emptyCipher.Length)
    [Array]::Copy($header, 0, $emptyPayload, 0, $header.Length)
    [Array]::Copy($emptyCipher, 0, $emptyPayload, $header.Length, $emptyCipher.Length)
    [IO.File]::WriteAllBytes($emptyCredentialPath, $emptyPayload)
    $emptyError = $null
    try {
        $null = & $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass `
            -File $tokenScript -ProviderId 'empty-fixture' -VaultRoot $vaultRoot 2>&1
        if ($LASTEXITCODE -ne 0) { $emptyError = 'helper exited nonzero' }
    } catch { $emptyError = $_ }
    Assert-True ($null -ne $emptyError) 'an empty DPAPI token must fail closed'
    Remove-Item -LiteralPath $emptyCredentialPath -Force

    $officialAfter = & (Get-Command python).Source -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); print(c.execute('select settings_config from providers where id=?',('codex-official',)).fetchone()[0])" $database
    Assert-Equal ([string]$officialBefore) ([string]$officialAfter) 'official provider authentication must remain byte-identical'
    Assert-Equal $officialRunConfigBefore (Get-Hash -Path (Join-Path $officialRunHome 'config.toml')) 'official run config must remain byte-identical'
    Assert-Equal $officialRunAuthBefore (Get-Hash -Path (Join-Path $officialRunHome 'auth.json')) 'official run auth must remain byte-identical'
    $officialRunMetadata = Get-Content -LiteralPath (Join-Path $officialRunHome 'run-provider.json') -Raw | ConvertFrom-Json
    Assert-Equal 'official' ([string]$officialRunMetadata.providerCategory) 'official run metadata must record its authentication category'
    Assert-True ((Get-Content -LiteralPath (Join-Path $globalHome 'config.toml') -Raw) -notlike "*$secretAlpha*") 'global config comments must not retain known tokens'
    Assert-Equal '{}' ((Get-Content -LiteralPath (Join-Path $runHome 'auth.json') -Raw).Trim()) 'run auth must be token-free'
    Assert-True ((Get-Content -LiteralPath (Join-Path $runHome 'config.toml') -Raw) -notlike "*$secretAlpha*") `
        'run config must not retain plaintext token'
    Assert-True ((Get-Content -LiteralPath (Join-Path $runHome 'config.toml') -Raw) -like '*[model_providers*auth]*') `
        'run config must contain command-backed auth'
    Assert-True ((Get-Content -LiteralPath (Join-Path $runHome 'history.jsonl') -Raw) -notlike "*$secretAlpha*") `
        'known tokens must be redacted from history JSONL'
    Assert-True (Test-Path -LiteralPath (Join-Path $rollbackRoot 'cc-switch.db.dpapi')) `
        'migration must create an encrypted database rollback'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $rollbackRoot 'cc-switch.db.plaintext.tmp'))) `
        'migration must remove the plaintext rollback staging file'

    $postAuditJson = & $wrapperScript `
        -CcSwitchRoot $ccRoot `
        -GlobalCodexHome $globalHome `
        -ProdexRoot $prodexRoot `
        -Json
    $postAudit = ($postAuditJson | Out-String).Trim() | ConvertFrom-Json
    Assert-True ([bool]$postAudit.ok) 'post-migration audit must succeed'
    Assert-Equal 0 ([int]$postAudit.plaintextProviderCount) 'post-migration audit must find no provider plaintext'
    Assert-Equal 2 ([int]$postAudit.commandBackedProviderCount) 'all third-party providers must use auth commands'
    Assert-Equal 1 ([int]$postAudit.globalCommandBackedProviderCount) 'all global custom providers must use auth commands'
    $compatibilityJson = @(& (Get-Command python).Source $auditScript $database) | Out-String
    Assert-True ($compatibilityJson -notlike "*$secretAlpha*" -and $compatibilityJson -notlike "*$secretBeta*") `
        'compatibility audit must not output a provider credential'
    $compatibilityAudit = $compatibilityJson.Trim() | ConvertFrom-Json
    Assert-Equal 3 ([int]$compatibilityAudit.compatibleCount) 'compatibility audit must accept command-backed providers'

    $tamperAuthPython = Join-Path $fixtureRoot 'tamper_auth.py'
$tamperAuthCode = @'
import json
import re
import sqlite3
import sys

database, command, backup_path, powershell_path = sys.argv[1:5]
with sqlite3.connect(database) as connection:
    if command == "tamper":
        original = connection.execute("select settings_config from providers where id='provider-a'").fetchone()[0]
        open(backup_path, "w", encoding="utf-8").write(original)
        settings = json.loads(original)
        settings["config"] = re.sub(
            r'^"command"\s*=.*$',
            'command = "C:/unmanaged.exe"',
            settings["config"],
            count=1,
            flags=re.MULTILINE,
        )
        connection.execute("update providers set settings_config=? where id='provider-a'", (json.dumps(settings, separators=(",", ":")),))
    else:
        original = open(backup_path, encoding="utf-8").read()
        connection.execute("update providers set settings_config=? where id='provider-a'", (original,))
'@
    $tamperAuthBackup = Join-Path $fixtureRoot 'provider-a-command.json'
    Write-Utf8NoBom -Path $tamperAuthPython -Content $tamperAuthCode
    & (Get-Command python).Source $tamperAuthPython $database tamper $tamperAuthBackup $powershell
    Assert-Equal 0 $LASTEXITCODE 'command auth tamper fixture must be created'
    $tamperedAuditJson = & $wrapperScript -CcSwitchRoot $ccRoot -GlobalCodexHome $globalHome -ProdexRoot $prodexRoot -Json
    $tamperedAudit = ($tamperedAuditJson | Out-String).Trim() | ConvertFrom-Json
    Assert-True (-not [bool]$tamperedAudit.ok) ("audit must reject non-canonical command authentication: {0}" -f ($tamperedAudit | ConvertTo-Json -Compress))
    & (Get-Command python).Source $tamperAuthPython $database restore $tamperAuthBackup $powershell
    Assert-Equal 0 $LASTEXITCODE 'command auth fixture must be restored'

    $cleanupBackup = Join-Path $ccRoot 'backups\legacy.db'
    $reintroducedLeak = Join-Path $prodexRoot 'logs\reintroduced.log'
    Write-Utf8NoBom -Path $cleanupBackup -Content 'legacy'
    Write-Utf8NoBom -Path $reintroducedLeak -Content $secretAlpha
    $originalUserProfile = $env:USERPROFILE
    try {
        $env:USERPROFILE = $userRoot
        $cleanupLeakError = $null
        try {
            $null = & $cleanupScript -CcSwitchRoot $ccRoot -ProdexRoot $prodexRoot -Apply -Confirm:$false -Json
        } catch { $cleanupLeakError = $_ }
        Assert-True ($null -ne $cleanupLeakError) 'cleanup must reject a reintroduced known token'
        Assert-True (Test-Path -LiteralPath $cleanupBackup) 'token rejection must happen before stale backup deletion'
        Remove-Item -LiteralPath $reintroducedLeak -Force

        $cleanupCredentialPath = Get-CcSwitchCredentialPath -VaultRoot $vaultRoot -ProviderId 'provider-a'
        $cleanupAclGrantArguments = @($cleanupCredentialPath, '/grant', '*S-1-1-0:(R)')
        & icacls.exe @cleanupAclGrantArguments | Out-Null
        $cleanupAclError = $null
        try {
            $null = & $cleanupScript -CcSwitchRoot $ccRoot -ProdexRoot $prodexRoot -Apply -Confirm:$false -Json
        } catch { $cleanupAclError = $_ }
        Assert-True ($null -ne $cleanupAclError) 'cleanup must reject a loosened credential ACL'
        Assert-True (Test-Path -LiteralPath $cleanupBackup) 'ACL rejection must happen before stale backup deletion'
        $cleanupAclRemoveArguments = @($cleanupCredentialPath, '/remove:g', '*S-1-1-0')
        & icacls.exe @cleanupAclRemoveArguments | Out-Null
    } finally {
        $env:USERPROFILE = $originalUserProfile
    }

    $credentialFile = Get-CcSwitchCredentialPath -VaultRoot $vaultRoot -ProviderId 'provider-a'
    $originalCredential = [IO.File]::ReadAllBytes($credentialFile)
    $corrupted = [byte[]]$originalCredential.Clone()
    $corrupted[$corrupted.Length - 1] = $corrupted[$corrupted.Length - 1] -bxor 1
    [IO.File]::WriteAllBytes($credentialFile, $corrupted)
    $corruptionError = $null
    try {
        $null = & $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass `
            -File $tokenScript -ProviderId 'provider-a' -VaultRoot $vaultRoot 2>&1
        if ($LASTEXITCODE -ne 0) { $corruptionError = 'helper exited nonzero' }
    } catch { $corruptionError = $_ }
    Assert-True ($null -ne $corruptionError) 'corrupt DPAPI ciphertext must fail closed'
    [IO.File]::WriteAllBytes($credentialFile, $originalCredential)

    $manifestPath = Join-Path $rollbackRoot 'manifest.json'
    $manifestOriginal = Get-Content -LiteralPath $manifestPath -Raw
    $manifestTraversal = $manifestOriginal | ConvertFrom-Json
    $manifestTraversal.databaseFile = '..\outside.dpapi'
    Write-Utf8NoBom -Path $manifestPath -Content ($manifestTraversal | ConvertTo-Json -Depth 4)
    $manifestError = $null
    try {
        $null = & $restoreScript -RollbackRoot $rollbackRoot -CcSwitchRoot $ccRoot -GlobalCodexHome $globalHome -ProdexRoot $prodexRoot -Confirm:$false -Json 2>&1
    } catch { $manifestError = $_ }
    Assert-True ($null -ne $manifestError) 'rollback manifest traversal must fail closed'
    Assert-True ($manifestError.ToString() -notlike "*$secretAlpha*" -and $manifestError.ToString() -notlike "*$secretBeta*") 'rollback manifest failure must not expose a credential'
    Write-Utf8NoBom -Path $manifestPath -Content $manifestOriginal

    [IO.Directory]::CreateDirectory("$database-wal") | Out-Null
    $restoreCaptureError = $null
    try {
        $null = & $restoreScript -RollbackRoot $rollbackRoot -CcSwitchRoot $ccRoot -GlobalCodexHome $globalHome -ProdexRoot $prodexRoot -Confirm:$false -Json 2>&1
    } catch { $restoreCaptureError = $_ }
    Assert-True ($null -ne $restoreCaptureError) 'restore must fail when a database sidecar is not a file'
    Assert-True ($restoreCaptureError.ToString() -notlike "*$secretAlpha*" -and $restoreCaptureError.ToString() -notlike "*$secretBeta*") 'rollback sidecar failure must not expose a credential'
    Assert-Equal 0 @(Get-ChildItem -LiteralPath $ccRoot -File -Filter 'cc-switch.db.restore-*.tmp').Count 'failed restore capture must remove plaintext temporary databases'
    Remove-Item -LiteralPath "$database-wal" -Force

    $staleWalPython = Join-Path $fixtureRoot 'stale_wal.py'
    $staleWalCode = @'
import shutil
import sqlite3
import sys
from pathlib import Path

database = Path(sys.argv[1])
scratch = Path(sys.argv[2])
shutil.copy2(database, scratch)
with sqlite3.connect(scratch) as connection:
    connection.execute("pragma journal_mode=wal")
    connection.execute("pragma wal_autocheckpoint=0")
    connection.execute("update providers set name='STALE_WAL_REPLAY' where id='provider-a'")
    connection.commit()
    Path(str(database) + "-wal").write_bytes(Path(str(scratch) + "-wal").read_bytes())
    Path(str(database) + "-shm").write_bytes(Path(str(scratch) + "-shm").read_bytes())
'@
    $staleWalDatabase = Join-Path $fixtureRoot 'stale-wal.db'
    Write-Utf8NoBom -Path $staleWalPython -Content $staleWalCode
    & (Get-Command python).Source $staleWalPython $database $staleWalDatabase
    Assert-Equal 0 $LASTEXITCODE 'stale WAL fixture must be created'
    Assert-True (Test-Path -LiteralPath "$database-wal") 'stale WAL must exist before rollback restore'
    Assert-True (Test-Path -LiteralPath "$database-shm") 'stale SHM must exist before rollback restore'

    $restoreJson = @(& $restoreScript -RollbackRoot $rollbackRoot -CcSwitchRoot $ccRoot -GlobalCodexHome $globalHome -ProdexRoot $prodexRoot -Confirm:$false -Json) | Out-String
    Assert-True ($restoreJson -notlike "*$secretAlpha*" -and $restoreJson -notlike "*$secretBeta*") 'rollback output must not contain a credential'
    $restoredAuditJson = & $wrapperScript `
        -CcSwitchRoot $ccRoot `
        -GlobalCodexHome $globalHome `
        -ProdexRoot $prodexRoot `
        -Json
    $restoredAudit = ($restoredAuditJson | Out-String).Trim() | ConvertFrom-Json
    Assert-Equal 2 ([int]$restoredAudit.plaintextProviderCount) 'rollback must restore the original provider database'
    Assert-True (-not (Test-Path -LiteralPath "$database-wal")) 'rollback must remove stale WAL sidecars'
    Assert-True (-not (Test-Path -LiteralPath "$database-shm")) 'rollback must remove stale SHM sidecars'
    $restoredProviderName = & (Get-Command python).Source -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); print(c.execute('select name from providers where id=?',('provider-a',)).fetchone()[0])" $database
    Assert-Equal 'Provider A' ([string]$restoredProviderName) 'rollback must not replay stale WAL contents'

    Write-Output '[PASS] credential migration, DPAPI, ACL, rollback, and redaction fixture'
} catch {
    $failures.Add("$($_)`n$($_.ScriptStackTrace)") | Out-Null
    Write-Error -ErrorRecord $_ -ErrorAction Continue
} finally {
    if (Test-Path -LiteralPath $fixtureRoot) {
        $resolved = [IO.Path]::GetFullPath($fixtureRoot)
        $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if ($resolved.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Leaf $resolved) -like 'ccswitch-credential-*') {
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }
}

if ($failures.Count -gt 0) {
    throw "Credential migration fixture failures: $($failures -join ' | ')"
}
