$script:BrowserTrustOverlayPythonPath = Join-Path $PSScriptRoot 'apply-browser-trust-overlay.py'
$script:BrowserTrustFilePath = Join-Path $env:USERPROFILE '.codex\browser-client-trust.json'

function Get-OpenAICodexRuntimeCacheRoot {
    $localAppData = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::LocalApplicationData
    )
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        $localAppData = $env:LOCALAPPDATA
    }
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        $localAppData = Join-Path $env:USERPROFILE 'AppData\Local'
    }
    return Join-Path $localAppData 'OpenAI\Codex'
}

$script:OpenAICodexRuntimeCacheRoot = Get-OpenAICodexRuntimeCacheRoot
$script:OpenAICodexAppxPackageQuery = {
    @(Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction Stop)
}

function Test-OpenAICodexStorePackage {
    param([Parameter(Mandatory = $true)]$Package)

    return (
        [string]$Package.Name -ceq 'OpenAI.Codex' -and
        [string]$Package.PublisherId -ceq '2p2nqsd0c76g0' -and
        [string]$Package.SignatureKind -ceq 'Store' -and
        [string]$Package.Status -ceq 'Ok' -and
        -not [bool]$Package.IsFramework
    )
}

function Get-OpenAICodexRuntimeMarketplaceSource {
    try {
        $packages = @(& $script:OpenAICodexAppxPackageQuery)
    } catch {
        # A failed package query provides no trusted source; strict runtime merges fail later.
        return $null
    }
    if (
        $packages.Count -ne 1 -or
        -not (Test-OpenAICodexStorePackage -Package $packages[0])
    ) {
        return $null
    }

    $package = $packages[0]
    $installLocation = [string]$package.InstallLocation
    if ([string]::IsNullOrWhiteSpace($installLocation)) {
        return $null
    }
    try {
        $bundlePath = [System.IO.Path]::GetFullPath(
            (Join-Path $installLocation 'app\resources\plugins\openai-bundled')
        )
    } catch {
        return $null
    }
    if (-not (Test-Path -LiteralPath $bundlePath -PathType Container)) {
        return $null
    }
    return $bundlePath
}

function Get-BrowserTrustOverlay {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ConfigText,
        [string]$RuntimeSourcePath = ''
    )

    $pythonCommand = Get-Command python -ErrorAction Stop
    $nonce = "$PID-$([guid]::NewGuid().ToString('N'))"
    $inputPath = Join-Path ([System.IO.Path]::GetTempPath()) "browser-trust-input-$nonce.toml"
    $outputPath = Join-Path ([System.IO.Path]::GetTempPath()) "browser-trust-output-$nonce.toml"
    try {
        [System.IO.File]::WriteAllText($inputPath, $ConfigText, [System.Text.UTF8Encoding]::new($false))
        $pythonArguments = @(
            $script:BrowserTrustOverlayPythonPath,
            '--trust-file', $script:BrowserTrustFilePath,
            '--input', $inputPath,
            '--output', $outputPath
        )
        if (-not [string]::IsNullOrWhiteSpace($RuntimeSourcePath)) {
            if (-not (Test-Path -LiteralPath $RuntimeSourcePath -PathType Leaf)) {
                throw "Browser runtime config is missing: $RuntimeSourcePath"
            }
            $resolvedRuntimeSource = [System.IO.Path]::GetFullPath($RuntimeSourcePath)
            $pythonArguments += @(
                '--runtime-source', $resolvedRuntimeSource,
                '--require-compatible-runtime-bundle',
                '--runtime-cache-source', $script:OpenAICodexRuntimeCacheRoot
            )
            $runtimeMarketplaceSource = Get-OpenAICodexRuntimeMarketplaceSource
            if (-not [string]::IsNullOrWhiteSpace($runtimeMarketplaceSource)) {
                $pythonArguments += @(
                    '--runtime-marketplace-source', $runtimeMarketplaceSource
                )
            }
        }
        & $pythonCommand.Source @pythonArguments
        if ($LASTEXITCODE -ne 0) {
            throw "Browser trust overlay failed with exit code $LASTEXITCODE."
        }
        $overlaidConfig = [System.IO.File]::ReadAllText($outputPath, [System.Text.Encoding]::UTF8)
        $configBytes = [System.Text.Encoding]::UTF8.GetBytes($overlaidConfig)
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        $configHash = -join ($sha256.ComputeHash($configBytes) | ForEach-Object { $_.ToString('x2') })
        return [pscustomobject]@{
            ConfigText = $overlaidConfig
            ConfigSha256 = $configHash.Substring(0, 16)
        }
    } finally {
        Remove-Item -LiteralPath $inputPath, $outputPath -Force -ErrorAction SilentlyContinue
    }
}
