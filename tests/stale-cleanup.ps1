[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$repoRoot = Split-Path -Parent $PSScriptRoot
$cleanupScript = Join-Path $repoRoot 'scripts\remove-stale-ccswitch-data.ps1'
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) "ccswitch-stale-$PID-$([guid]::NewGuid().ToString('N'))"
$userRoot = Join-Path $fixtureRoot 'user'
$ccRoot = Join-Path $userRoot '.cc-switch'
$globalHome = Join-Path $userRoot '.codex'
$prodexRoot = Join-Path $userRoot '.prodex'
$currentHome = Join-Path $prodexRoot 'manual-homes\ccswitch-current'
$runHomes = Join-Path $prodexRoot 'manual-homes\ccswitch-runs'
$failures = [System.Collections.Generic.List[string]]::new()
$activeProcess = $null

function Assert-True {
    param([bool]$Condition, [string]$Because)
    if (-not $Condition) { throw "Assertion failed: $Because" }
}

function Write-File {
    param([string]$Path, [AllowEmptyString()][string]$Content)
    [IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

try {
    foreach ($directory in @(
        (Join-Path $ccRoot 'backups\ccswitch-fixture-20260718'),
        $globalHome,
        $currentHome,
        (Join-Path $runHomes 'ccswitch-run-keep\sessions'),
        (Join-Path $runHomes '.ccswitch-staging-orphan')
    )) {
        [IO.Directory]::CreateDirectory($directory) | Out-Null
    }
    Write-File -Path (Join-Path $ccRoot 'backups\cc-switch.db.bak-fixture') -Content 'legacy'
    Write-File -Path (Join-Path $ccRoot 'backups\ccswitch-fixture-20260718\legacy.db') -Content 'legacy'
    (Get-Item -LiteralPath (Join-Path $ccRoot 'backups\cc-switch.db.bak-fixture')).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-2)
    (Get-Item -LiteralPath (Join-Path $ccRoot 'backups\ccswitch-fixture-20260718')).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-2)
    Write-File -Path (Join-Path $currentHome 'config.toml.bak-old') -Content 'old'
    Write-File -Path (Join-Path $currentHome 'auth.json.bak-old') -Content 'old'
    Write-File -Path (Join-Path $currentHome 'config.toml') -Content 'model = "fixture"'
    Write-File -Path (Join-Path $currentHome 'auth.json') -Content '{}'
    Write-File -Path (Join-Path $runHomes 'ccswitch-run-keep\sessions\rollout.jsonl') -Content '{}'
    Write-File -Path (Join-Path $runHomes '.ccswitch-staging-orphan\config.toml') -Content 'staging'
    (Get-Item -LiteralPath (Join-Path $runHomes '.ccswitch-staging-orphan')).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-2)
    Write-File -Path (Join-Path $globalHome 'config.toml') -Content 'model = "fixture"'
    Write-File -Path (Join-Path $ccRoot 'settings.json') -Content '{"currentProviderCodex":"codex-official"}'

    $database = Join-Path $ccRoot 'cc-switch.db'
    $databasePython = Join-Path $fixtureRoot 'database.py'
    $databaseCode = @'
import json
import sqlite3
import sys

settings = json.dumps(
    {
        "config": 'model = "fixture"\n',
        "auth": {"auth_mode": "chatgpt", "tokens": {"access_token": "OFFICIAL_FIXTURE"}},
    },
    separators=(",", ":"),
)
with sqlite3.connect(sys.argv[1]) as connection:
    connection.execute(
        "create table providers (id text primary key,name text,category text,is_current integer,settings_config text,app_type text,sort_index integer)"
    )
    connection.execute(
        "insert into providers values ('codex-official','Official','official',1,?,'codex',1)",
        (settings,),
    )
'@
    Write-File -Path $databasePython -Content $databaseCode
    & (Get-Command python).Source $databasePython $database
    Assert-True ($LASTEXITCODE -eq 0) 'cleanup fixture database must be created'

    $originalUserProfile = $env:USERPROFILE
    try {
        $env:USERPROFILE = $userRoot
        $outsideTarget = Join-Path $fixtureRoot 'outside-target'
        [IO.Directory]::CreateDirectory($outsideTarget) | Out-Null
        $unsafeLink = Join-Path $ccRoot 'backups\ccswitch-fixture-20260718\outside-link'
        New-Item -ItemType Junction -Path $unsafeLink -Target $outsideTarget | Out-Null
        $reparseError = $null
        try { $null = & $cleanupScript -CcSwitchRoot $ccRoot -ProdexRoot $prodexRoot -Json } catch { $reparseError = $_ }
        Assert-True ($null -ne $reparseError) 'cleanup must reject a candidate containing a nested reparse point'
        Remove-Item -LiteralPath $unsafeLink -Force
        (Get-Item -LiteralPath (Join-Path $ccRoot 'backups\ccswitch-fixture-20260718')).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-2)

        $recoverableStaging = Join-Path $runHomes '.ccswitch-staging-recoverable'
        Write-File -Path (Join-Path $recoverableStaging 'sessions\rollout.jsonl') -Content '{}'
        (Get-Item -LiteralPath $recoverableStaging).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-2)
        $recoverableError = $null
        try {
            $null = & $cleanupScript -CcSwitchRoot $ccRoot -ProdexRoot $prodexRoot -Json
        } catch { $recoverableError = $_ }
        Assert-True ($null -ne $recoverableError) 'cleanup must reject staging that contains recoverable state'
        Assert-True (Test-Path -LiteralPath (Join-Path $recoverableStaging 'sessions\rollout.jsonl')) 'recoverable staging must remain untouched'
        Remove-Item -LiteralPath $recoverableStaging -Recurse -Force

        $previewJson = & $cleanupScript -CcSwitchRoot $ccRoot -ProdexRoot $prodexRoot -Json
        $preview = ($previewJson | Out-String).Trim() | ConvertFrom-Json
        Assert-True ($preview.mode -eq 'preview' -and [int]$preview.deletedCount -eq 0) `
            'cleanup must default to preview'
        Assert-True ([int]$preview.candidateCount -eq 5) 'preview must include backups, current copies, and orphan staging'
        Assert-True (Test-Path -LiteralPath (Join-Path $ccRoot 'backups\cc-switch.db.bak-fixture')) 'preview must not delete backups'

        $holdScript = Join-Path $runHomes '.ccswitch-staging-orphan\hold.ps1'
        Write-File -Path $holdScript -Content 'Start-Sleep -Seconds 60'
        (Get-Item -LiteralPath (Join-Path $runHomes '.ccswitch-staging-orphan')).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-2)
        $activeProcess = Start-Process `
            -FilePath (Get-Command pwsh).Source `
            -ArgumentList @('-NoProfile', '-File', $holdScript) `
            -PassThru `
            -WindowStyle Hidden
        Start-Sleep -Milliseconds 300
        $activeError = $null
        try {
            $null = & $cleanupScript -CcSwitchRoot $ccRoot -ProdexRoot $prodexRoot -Apply -Confirm:$false -Json
        } catch { $activeError = $_ }
        Assert-True ($null -ne $activeError) 'cleanup must stop before deletion when any candidate is active'
        Assert-True (Test-Path -LiteralPath (Join-Path $ccRoot 'backups\cc-switch.db.bak-fixture')) `
            'active-process rejection must happen before deleting earlier candidates'
        Stop-Process -Id $activeProcess.Id -Force
        $activeProcess = $null

        $applyJson = & $cleanupScript `
            -CcSwitchRoot $ccRoot `
            -ProdexRoot $prodexRoot `
            -Apply `
            -Confirm:$false `
            -Json
        $apply = ($applyJson | Out-String).Trim() | ConvertFrom-Json
        Assert-True ([int]$apply.deletedCount -eq 5) 'apply must delete every verified stale candidate'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $ccRoot 'backups\cc-switch.db.bak-fixture'))) 'legacy backup must be deleted'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $currentHome 'config.toml.bak-old'))) 'old current config must be deleted'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $runHomes '.ccswitch-staging-orphan'))) 'orphan staging must be deleted'
        Assert-True (Test-Path -LiteralPath (Join-Path $runHomes 'ccswitch-run-keep\sessions\rollout.jsonl')) `
            'recoverable run must never be deleted'
        Assert-True ([int]$apply.runHomesDeleted -eq 0) 'cleanup report must confirm no run homes were deleted'
    } finally {
        $env:USERPROFILE = $originalUserProfile
    }

    Write-Output '[PASS] stale cleanup preview/apply and run preservation fixture'
} catch {
    $failures.Add("$($_)`n$($_.ScriptStackTrace)") | Out-Null
    Write-Error -ErrorRecord $_ -ErrorAction Continue
} finally {
    if ($null -ne $activeProcess -and -not $activeProcess.HasExited) {
        Stop-Process -Id $activeProcess.Id -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $fixtureRoot) {
        $resolved = [IO.Path]::GetFullPath($fixtureRoot)
        $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if ($resolved.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Leaf $resolved) -like 'ccswitch-stale-*') {
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }
}

if ($failures.Count -gt 0) {
    throw "Stale cleanup fixture failures: $($failures -join ' | ')"
}
