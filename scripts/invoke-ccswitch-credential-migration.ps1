[CmdletBinding()]
param(
    [string]$CcSwitchRoot = '',
    [string]$GlobalCodexHome = (Join-Path $env:USERPROFILE '.codex'),
    [string]$ProdexRoot = (Join-Path $env:USERPROFILE '.prodex'),
    [switch]$Apply,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
. (Join-Path $PSScriptRoot 'resolve-ccswitch-root.ps1')
. (Join-Path $PSScriptRoot 'ccswitch-credential-vault.ps1')
. (Join-Path $PSScriptRoot 'powershell-host.ps1')

function Assert-CcSwitchStopped {
    $active = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessName -in @('cc-switch', 'ccswitch')
    })
    if ($active.Count -gt 0) {
        $processIds = ($active.Id | Sort-Object) -join ', '
        throw "CC Switch must be closed before credential migration. Active PID(s): $processIds"
    }
}

function Assert-VaultCredentialTree {
    Assert-CcSwitchCredentialAcl -VaultRoot $vaultRoot -CredentialPath $vaultRoot
    foreach ($entry in @(Get-ChildItem -LiteralPath $vaultRoot -Recurse -Force -ErrorAction Stop)) {
        Assert-CcSwitchCredentialAcl -VaultRoot $vaultRoot -CredentialPath $entry.FullName
    }
}

function Invoke-MigrationCore {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [AllowNull()][string]$RollbackRoot
    )

    $python = (Get-Command python -ErrorAction Stop).Source
    $powershell = Get-CurrentPowerShellExecutable
    $arguments = @(
        (Join-Path $PSScriptRoot 'ccswitch_credential_migration.py'),
        $Command,
        '--database', (Join-Path $resolvedCcSwitchRoot 'cc-switch.db'),
        '--global-config', (Join-Path $resolvedGlobalCodexHome 'config.toml'),
        '--vault-root', $vaultRoot,
        '--helper-script', (Join-Path $PSScriptRoot 'get-ccswitch-provider-token.ps1'),
        '--powershell-exe', $powershell,
        '--current-home', (Join-Path $resolvedProdexRoot 'manual-homes\ccswitch-current'),
        '--run-homes', (Join-Path $resolvedProdexRoot 'manual-homes\ccswitch-runs'),
        '--scan-root', $resolvedGlobalCodexHome,
        '--scan-root', (Join-Path $resolvedProdexRoot 'logs'),
        '--scan-root', (Join-Path $resolvedProdexRoot 'manual-homes\ccswitch-current'),
        '--scan-root', (Join-Path $resolvedProdexRoot 'manual-homes\ccswitch-runs')
    )
    if (-not [string]::IsNullOrWhiteSpace($RollbackRoot)) {
        $arguments += @('--rollback-root', $RollbackRoot)
    }
    $output = @(& $python @arguments)
    if ($LASTEXITCODE -ne 0) {
        throw "Credential migration core failed with exit code $LASTEXITCODE."
    }
    return (($output | Out-String).Trim() | ConvertFrom-Json)
}

$resolvedCcSwitchRoot = Resolve-CcSwitchRoot `
    -ExplicitRoot $CcSwitchRoot `
    -UserRoot $env:USERPROFILE `
    -AppDataRoot $env:APPDATA
$resolvedGlobalCodexHome = [System.IO.Path]::GetFullPath($GlobalCodexHome)
$resolvedProdexRoot = [System.IO.Path]::GetFullPath($ProdexRoot)
$vaultRoot = Join-Path $resolvedProdexRoot 'credentials\ccswitch-codex'
$mutex = [System.Threading.Mutex]::new($false, 'Local\CcSwitchCodexCredentialMigration-v1')
$lockHeld = $false

try {
    $lockHeld = $mutex.WaitOne(0)
    if (-not $lockHeld) {
        throw 'Another CC Switch credential migration is already running.'
    }
    if ($Apply) {
        Assert-CcSwitchStopped
        Set-CcSwitchCredentialVaultAcl -VaultRoot $vaultRoot
        Assert-VaultCredentialTree
        $rollbackParent = Join-Path $vaultRoot 'rollbacks'
        [System.IO.Directory]::CreateDirectory($rollbackParent) | Out-Null
        $rollbackRoot = Join-Path $rollbackParent ("{0}-{1}" -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'), $PID)
        $report = Invoke-MigrationCore -Command apply -RollbackRoot $rollbackRoot
        Assert-VaultCredentialTree
    } else {
        if (Test-Path -LiteralPath $vaultRoot -PathType Container) {
            Assert-VaultCredentialTree
        }
        $report = Invoke-MigrationCore -Command audit -RollbackRoot $null
    }
} finally {
    if ($lockHeld) {
        $mutex.ReleaseMutex()
    }
    $mutex.Dispose()
}

if ($Json) {
    $report | ConvertTo-Json -Depth 8 -Compress
} else {
    $report
}
