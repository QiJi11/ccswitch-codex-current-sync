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
    $matches = @($candidates | Where-Object {
        (Test-Path -LiteralPath (Join-Path $_ 'settings.json') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $_ 'cc-switch.db') -PathType Leaf)
    } | Select-Object -First 1)
    if ($matches.Count -ne 1) {
        throw 'Unable to locate an active CC Switch data root.'
    }
    return [System.IO.Path]::GetFullPath($matches[0])
}
