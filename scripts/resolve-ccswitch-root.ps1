function Resolve-CcSwitchRoot {
    param(
        [AllowEmptyString()][string]$ExplicitRoot = '',
        [Parameter(Mandatory = $true)][string]$UserRoot,
        [AllowEmptyString()][string]$AppDataRoot = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitRoot)) {
        return [System.IO.Path]::GetFullPath($ExplicitRoot)
    }
    if ([string]::IsNullOrWhiteSpace($AppDataRoot)) {
        $AppDataRoot = [Environment]::GetFolderPath('ApplicationData')
    }
    $candidates = @(
        (Join-Path $AppDataRoot 'com.ccswitch.desktop')
        (Join-Path $UserRoot '.cc-switch')
    )
    $matches = @($candidates | Where-Object { Test-CcSwitchRootCandidate -Root $_ })
    if ($matches.Count -ne 1) {
        throw "Expected exactly one active CC Switch data root; found $($matches.Count)."
    }
    return [System.IO.Path]::GetFullPath($matches[0])
}

function Test-CcSwitchRootCandidate {
    param(
        [Parameter(Mandatory = $true)][string]$Root
    )

    $settingsPath = Join-Path $Root 'settings.json'
    $databasePath = Join-Path $Root 'cc-switch.db'
    if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $databasePath -PathType Leaf)) {
        return $false
    }
    try {
        $settings = Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json
        $currentProvider = [string]$settings.currentProviderCodex
        $databaseLength = (Get-Item -LiteralPath $databasePath).Length
        return (-not [string]::IsNullOrWhiteSpace($currentProvider)) -and $databaseLength -gt 0
    } catch {
        return $false
    }
}

function Get-CcSwitchRootMutexIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$Root
    )

    $normalizedRoot = [System.IO.Path]::GetFullPath($Root)
    $rootPath = [System.IO.Path]::GetPathRoot($normalizedRoot)
    if (-not [string]::Equals($normalizedRoot, $rootPath, [StringComparison]::OrdinalIgnoreCase)) {
        $normalizedRoot = $normalizedRoot.TrimEnd([char[]]@('\', '/'))
    }
    return $normalizedRoot.ToLowerInvariant()
}

function Get-CcSwitchRootMutexName {
    param(
        [Parameter(Mandatory = $true)][string]$Root
    )

    $identity = Get-CcSwitchRootMutexIdentity -Root $Root
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = ([System.BitConverter]::ToString(
            $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($identity))
        )).Replace('-', '')
    } finally {
        $sha256.Dispose()
    }
    return "Local\ccswitch-codex-root-operation-$hash"
}
