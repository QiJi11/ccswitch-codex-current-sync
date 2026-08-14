[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)][string]$RollbackRoot,
    [string]$CcSwitchRoot = '',
    [string]$GlobalCodexHome = (Join-Path $env:USERPROFILE '.codex'),
    [string]$ProdexRoot = (Join-Path $env:USERPROFILE '.prodex'),
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
. (Join-Path $PSScriptRoot 'resolve-ccswitch-root.ps1')
. (Join-Path $PSScriptRoot 'powershell-host.ps1')
. (Join-Path $PSScriptRoot 'ccswitch-credential-vault.ps1')

function Assert-NoRollbackReparseAncestor {
    param(
        [Parameter(Mandatory = $true)][string]$VaultRoot,
        [Parameter(Mandatory = $true)][string]$RollbackRoot
    )

    $current = $RollbackRoot
    while ($true) {
        $entry = Get-Item -LiteralPath $current -Force
        if (($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Rollback path must not contain a reparse point: $current"
        }
        if ([string]::Equals($current, $VaultRoot, [StringComparison]::OrdinalIgnoreCase)) {
            return
        }
        $parent = [System.IO.Path]::GetDirectoryName($current)
        if ([string]::IsNullOrWhiteSpace($parent) -or [string]::Equals($parent, $current, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Rollback path does not descend from the credential vault.'
        }
        $current = $parent.TrimEnd('\', '/')
    }
}

function Assert-CcSwitchStoppedForRoot {
    param([Parameter(Mandatory = $true)][string]$TargetRoot)

    $activeRoot = Resolve-CcSwitchRoot `
        -UserRoot ([Environment]::GetFolderPath('UserProfile')) `
        -AppDataRoot ([Environment]::GetFolderPath('ApplicationData'))
    if (-not [string]::Equals($activeRoot, $TargetRoot, [StringComparison]::OrdinalIgnoreCase)) {
        return
    }
    $active = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessName -in @('cc-switch', 'ccswitch')
    })
    if ($active.Count -gt 0) {
        throw 'CC Switch must be closed before restoring its database.'
    }
}

$resolvedCcSwitchRoot = Resolve-CcSwitchRoot `
    -ExplicitRoot $CcSwitchRoot `
    -UserRoot $env:USERPROFILE `
    -AppDataRoot $env:APPDATA
Assert-CcSwitchStoppedForRoot -TargetRoot $resolvedCcSwitchRoot
$database = Join-Path $resolvedCcSwitchRoot 'cc-switch.db'
$resolvedRollbackRoot = [System.IO.Path]::GetFullPath($RollbackRoot)
$resolvedProdexRoot = [System.IO.Path]::GetFullPath($ProdexRoot)
$vaultRoot = [System.IO.Path]::GetFullPath((Join-Path $resolvedProdexRoot 'credentials\ccswitch-codex'))
$vaultPrefix = $vaultRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
if (-not $resolvedRollbackRoot.StartsWith($vaultPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Rollback package must be inside the CC Switch credential vault.'
}
Assert-NoRollbackReparseAncestor -VaultRoot $vaultRoot -RollbackRoot $resolvedRollbackRoot
Assert-CcSwitchCredentialAcl -VaultRoot $vaultRoot -CredentialPath $resolvedRollbackRoot
foreach ($rollbackEntry in @(Get-ChildItem -LiteralPath $resolvedRollbackRoot -Recurse -Force -ErrorAction Stop)) {
    Assert-CcSwitchCredentialAcl -VaultRoot $vaultRoot -CredentialPath $rollbackEntry.FullName
}
if (-not $PSCmdlet.ShouldProcess($database, "Restore encrypted rollback $resolvedRollbackRoot")) {
    return
}

$python = (Get-Command python -ErrorAction Stop).Source
$powershell = Get-CurrentPowerShellExecutable
$arguments = @(
    (Join-Path $PSScriptRoot 'ccswitch_credential_migration.py'),
    'restore',
    '--database', $database,
    '--global-config', (Join-Path $GlobalCodexHome 'config.toml'),
    '--vault-root', $vaultRoot,
    '--rollback-root', $resolvedRollbackRoot,
    '--helper-script', (Join-Path $PSScriptRoot 'get-ccswitch-provider-token.ps1'),
    '--powershell-exe', $powershell,
    '--current-home', (Join-Path $resolvedProdexRoot 'manual-homes\ccswitch-current'),
    '--run-homes', (Join-Path $resolvedProdexRoot 'manual-homes\ccswitch-runs')
)
$mutex = [System.Threading.Mutex]::new($false, 'Local\CcSwitchCodexCredentialMigration-v1')
$lockHeld = $false
try {
    $lockHeld = $mutex.WaitOne(0)
    if (-not $lockHeld) {
        throw 'Another CC Switch credential migration or rollback is already running.'
    }
    $output = @(& $python @arguments)
    if ($LASTEXITCODE -ne 0) {
        throw "Credential rollback failed with exit code $LASTEXITCODE."
    }
} finally {
    if ($lockHeld) {
        $mutex.ReleaseMutex()
    }
    $mutex.Dispose()
}
$report = (($output | Out-String).Trim() | ConvertFrom-Json)
if ($Json) {
    $report | ConvertTo-Json -Compress
} else {
    $report
}
