$script:CcSwitchConfigPython = Join-Path $PSScriptRoot 'ccswitch_config.py'
$script:CcSwitchTokenHelper = Join-Path $PSScriptRoot 'get-ccswitch-provider-token.ps1'
. (Join-Path $PSScriptRoot 'powershell-host.ps1')

function Get-CcSwitchDurableConfig {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ProviderConfigText,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$SelectionConfigText,
        [Parameter(Mandatory = $true)][string]$ProviderId,
        [string]$GlobalConfigPath = (Join-Path $env:USERPROFILE '.codex\config.toml'),
        [switch]$OfficialProvider
    )

    $python = (Get-Command python -ErrorAction Stop).Source
    $powershell = Get-CurrentPowerShellExecutable
    $nonce = "$PID-$([guid]::NewGuid().ToString('N'))"
    $providerPath = Join-Path ([System.IO.Path]::GetTempPath()) "ccswitch-provider-$nonce.toml"
    $selectionPath = Join-Path ([System.IO.Path]::GetTempPath()) "ccswitch-selection-$nonce.toml"
    $outputPath = Join-Path ([System.IO.Path]::GetTempPath()) "ccswitch-merged-$nonce.toml"
    try {
        [System.IO.File]::WriteAllText($providerPath, $ProviderConfigText, [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::WriteAllText($selectionPath, $SelectionConfigText, [System.Text.UTF8Encoding]::new($false))
        $arguments = @(
            $script:CcSwitchConfigPython,
            'merge',
            '--global-config', $GlobalConfigPath,
            '--provider-config', $providerPath,
            '--selection-config', $selectionPath,
            '--provider-id', $ProviderId,
            '--powershell-exe', $powershell,
            '--helper-script', $script:CcSwitchTokenHelper,
            '--output', $outputPath
        )
        if ($OfficialProvider) { $arguments += '--official-provider' }
        & $python @arguments
        if ($LASTEXITCODE -ne 0) {
            throw "Durable Codex config merge failed with exit code $LASTEXITCODE."
        }
        return [System.IO.File]::ReadAllText($outputPath, [System.Text.Encoding]::UTF8)
    } finally {
        Remove-Item -LiteralPath $providerPath, $selectionPath, $outputPath -Force -ErrorAction SilentlyContinue
    }
}
