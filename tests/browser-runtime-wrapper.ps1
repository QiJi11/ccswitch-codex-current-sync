[CmdletBinding()]
param(
    [string]$OverlayScript = (Join-Path $PSScriptRoot '..\scripts\browser-trust-overlay.ps1')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Get-WrapperTemporaryFiles {
    @(
        Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) `
            -File -Filter "browser-trust-*-$PID-*.toml" -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty FullName
    )
}

function Write-Utf8File {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )
    $parent = Split-Path -Parent $Path
    [System.IO.Directory]::CreateDirectory($parent) | Out-Null
    [System.IO.File]::WriteAllText(
        $Path,
        $Content,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$JsonDocument
    )
    Write-Utf8File -Path $Path -Content ($JsonDocument | ConvertTo-Json -Depth 8)
}

function New-RuntimeMarketplaceFixture {
    param(
        [Parameter(Mandatory = $true)][string]$PackageRoot,
        [Parameter(Mandatory = $true)][string]$Version
    )

    $bundlePath = Join-Path $PackageRoot 'app\resources\plugins\openai-bundled'
    $plugins = @()
    $clientHashes = @{}
    foreach ($pluginFixture in @(
        [pscustomobject]@{
            Name = 'browser'
            ClientName = 'browser-client.mjs'
            ClientContent = 'trusted browser client fixture'
        },
        [pscustomobject]@{
            Name = 'computer-use'
            ClientName = 'computer-use-client.mjs'
            ClientContent = 'trusted computer use client fixture'
        }
    )) {
        $pluginRoot = Join-Path $bundlePath "plugins\$($pluginFixture.Name)"
        Write-JsonFile `
            -Path (Join-Path $pluginRoot '.codex-plugin\plugin.json') `
            -JsonDocument ([ordered]@{ name = $pluginFixture.Name; version = $Version })
        $clientPath = Join-Path $pluginRoot "scripts\$($pluginFixture.ClientName)"
        Write-Utf8File -Path $clientPath -Content $pluginFixture.ClientContent
        $clientHashes[$pluginFixture.Name] = (Get-FileHash -Algorithm SHA256 -LiteralPath $clientPath).Hash.ToLowerInvariant()
        $plugins += [ordered]@{
            name = $pluginFixture.Name
            source = [ordered]@{
                source = 'local'
                path = "./plugins/$($pluginFixture.Name)"
            }
        }
    }
    Write-JsonFile `
        -Path (Join-Path $bundlePath '.agents\plugins\marketplace.json') `
        -JsonDocument ([ordered]@{ name = 'openai-bundled'; plugins = $plugins })
    $resourcesPath = Join-Path $PackageRoot 'app\resources'
    $runtimeRoot = Join-Path $resourcesPath 'cua_node'
    Write-JsonFile `
        -Path (Join-Path $runtimeRoot 'manifest.json') `
        -JsonDocument ([ordered]@{
            node_repl_path = 'bin/node_repl.exe'
            node_path = 'bin/node.exe'
            node_modules = 'bin/node_modules'
        })
    Write-Utf8File -Path (Join-Path $runtimeRoot 'bin\node_repl.exe') -Content 'store node_repl'
    Write-Utf8File -Path (Join-Path $runtimeRoot 'bin\node.exe') -Content 'store node'
    New-Item -ItemType Directory -Path (Join-Path $runtimeRoot 'bin\node_modules') -Force | Out-Null
    Write-Utf8File -Path (Join-Path $resourcesPath 'codex.exe') -Content 'store codex'
    $cacheRoot = Join-Path (Split-Path -Parent $PackageRoot) 'App Runtime Cache [user]\OpenAI\Codex'
    $cachedRuntimeRoot = Join-Path $cacheRoot 'runtimes\cua_node\runtime-version'
    New-Item -ItemType Directory -Path (Join-Path $cachedRuntimeRoot 'bin\node_modules') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $runtimeRoot 'manifest.json') `
        -Destination (Join-Path $cachedRuntimeRoot 'manifest.json')
    Copy-Item -LiteralPath (Join-Path $runtimeRoot 'bin\node_repl.exe') `
        -Destination (Join-Path $cachedRuntimeRoot 'bin\node_repl.exe')
    Copy-Item -LiteralPath (Join-Path $runtimeRoot 'bin\node.exe') `
        -Destination (Join-Path $cachedRuntimeRoot 'bin\node.exe')
    $cachedCodexPath = Join-Path $cacheRoot 'bin\codex-version\codex.exe'
    New-Item -ItemType Directory -Path (Split-Path -Parent $cachedCodexPath) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $resourcesPath 'codex.exe') -Destination $cachedCodexPath
    return [pscustomobject]@{
        BundlePath = [System.IO.Path]::GetFullPath($bundlePath)
        BrowserHash = $clientHashes.browser
        ComputerUseHash = $clientHashes.'computer-use'
        CacheRoot = [System.IO.Path]::GetFullPath($cacheRoot)
        NodeReplPath = [System.IO.Path]::GetFullPath((Join-Path $cachedRuntimeRoot 'bin\node_repl.exe'))
        NodePath = [System.IO.Path]::GetFullPath((Join-Path $cachedRuntimeRoot 'bin\node.exe'))
        NodeModulesPath = [System.IO.Path]::GetFullPath((Join-Path $cachedRuntimeRoot 'bin\node_modules'))
        CodexPath = [System.IO.Path]::GetFullPath($cachedCodexPath)
    }
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) "browser runtime wrapper [$PID] $([guid]::NewGuid().ToString('N'))"
$trustPath = Join-Path $testRoot 'trust.json'
$runtimePath = Join-Path $testRoot 'runtime [current].toml'
$cliRuntimePath = Join-Path $testRoot 'runtime [cli only].toml'
$missingPath = Join-Path $testRoot 'missing [runtime].toml'
$packageRoot = Join-Path $testRoot 'Store Package [signed]'
$temporaryFilesBefore = @(Get-WrapperTemporaryFiles)

try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    [System.IO.File]::WriteAllText(
        $trustPath,
        '{"schemaVersion":1,"trustedBrowserClientSha256":["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]}',
        [System.Text.UTF8Encoding]::new($false)
    )
    $runtimeVersion = '26.0.0'
    $fixture = New-RuntimeMarketplaceFixture `
        -PackageRoot $packageRoot `
        -Version $runtimeVersion
    $runtimeNodeRepl = $fixture.NodeReplPath.Replace('\', '\\')
    $runtimeNode = $fixture.NodePath.Replace('\', '\\')
    $runtimeNodeModules = $fixture.NodeModulesPath.Replace('\', '\\')
    $runtimeCodex = $fixture.CodexPath.Replace('\', '\\')
    $runtimeConfig = @"
[mcp_servers.node_repl]
command = "$runtimeNodeRepl"
args = []

[mcp_servers.node_repl.env]
NODE_REPL_TRUSTED_BROWSER_CLIENT_SHA256S = "$($fixture.BrowserHash),$($fixture.ComputerUseHash)"
BROWSER_USE_CODEX_APP_VERSION = "$runtimeVersion"
NODE_REPL_NODE_PATH = "$runtimeNode"
NODE_REPL_NODE_MODULE_DIRS = "$runtimeNodeModules"
CODEX_CLI_PATH = "$runtimeCodex"
SKY_CUA_NATIVE_PIPE = "1"
SKY_CUA_NATIVE_PIPE_DIRECTORY = "\\\\.\\pipe\\codex-computer-use-12345678-1234-1234-1234-123456789abc"

[plugins."browser@openai-bundled"]
enabled = true

[plugins."computer-use@openai-bundled"]
enabled = true
"@
    [System.IO.File]::WriteAllText(
        $runtimePath,
        $runtimeConfig,
        [System.Text.UTF8Encoding]::new($false)
    )

    . ([System.IO.Path]::GetFullPath($OverlayScript))
    $script:BrowserTrustFilePath = $trustPath
    $script:OpenAICodexRuntimeCacheRoot = $fixture.CacheRoot
    $script:PackageQueryResult = @(
        [pscustomobject]@{
            Name = 'OpenAI.Codex'
            PublisherId = '2p2nqsd0c76g0'
            SignatureKind = 'Store'
            Status = 'Ok'
            InstallLocation = $packageRoot
            IsFramework = $false
        }
    )
    $script:OpenAICodexAppxPackageQuery = { @($script:PackageQueryResult) }
    $providerConfig = @'
model = "provider-model"
model_provider = "custom"

[model_providers.custom]
name = "Provider"
base_url = "https://provider.invalid/v1"
'@
    $overlay = Get-BrowserTrustOverlay `
        -ConfigText $providerConfig `
        -RuntimeSourcePath $runtimePath
    Assert-True `
        -Condition ($overlay.ConfigText -match '(?m)^\[mcp_servers\.node_repl\]$') `
        -Message 'wrapper did not merge node_repl from a path containing spaces and brackets'
    Assert-True `
        -Condition ($overlay.ConfigText -match '(?m)^model\s*=\s*"provider-model"$') `
        -Message 'wrapper changed provider routing'
    $tomlBundlePath = $fixture.BundlePath.Replace('\', '\\')
    Assert-True `
        -Condition ($overlay.ConfigText.Contains($tomlBundlePath)) `
        -Message 'wrapper did not pass the Store bundle path as one argument'

    $script:PackageQueryResult[0].SignatureKind = 'Developer'
    $nonStorePackageFailed = $false
    try {
        $null = Get-BrowserTrustOverlay `
            -ConfigText $providerConfig `
            -RuntimeSourcePath $runtimePath 2>&1
    } catch {
        $nonStorePackageFailed = $_.Exception.Message -eq 'Browser trust overlay failed with exit code 1.'
    }
    Assert-True `
        -Condition $nonStorePackageFailed `
        -Message 'non-Store package metadata did not fail closed'
    $script:PackageQueryResult[0].SignatureKind = 'Store'

    $officialPackage = $script:PackageQueryResult[0]
    $script:PackageQueryResult = @($officialPackage, $officialPackage.PSObject.Copy())
    $duplicatePackageFailed = $false
    try {
        $null = Get-BrowserTrustOverlay `
            -ConfigText $providerConfig `
            -RuntimeSourcePath $runtimePath 2>&1
    } catch {
        $duplicatePackageFailed = $_.Exception.Message -eq 'Browser trust overlay failed with exit code 1.'
    }
    Assert-True `
        -Condition $duplicatePackageFailed `
        -Message 'duplicate Store packages did not fail closed'
    $script:PackageQueryResult = @($officialPackage)

    [System.IO.File]::WriteAllText(
        $cliRuntimePath,
        'model = "global-model"',
        [System.Text.UTF8Encoding]::new($false)
    )
    $script:PackageQueryResult = @()
    $cliOverlay = Get-BrowserTrustOverlay `
        -ConfigText $providerConfig `
        -RuntimeSourcePath $cliRuntimePath
    Assert-True `
        -Condition ($cliOverlay.ConfigText -eq $providerConfig) `
        -Message 'missing Store package changed the pure CLI fallback'
    $script:PackageQueryResult = @($officialPackage)

    $missingPathFailed = $false
    try {
        $null = Get-BrowserTrustOverlay `
            -ConfigText $providerConfig `
            -RuntimeSourcePath $missingPath
    } catch {
        $missingPathFailed = $_.Exception.Message -like 'Browser runtime config is missing:*'
    }
    Assert-True -Condition $missingPathFailed -Message 'missing runtime path did not fail clearly'

    [System.IO.File]::WriteAllText(
        $runtimePath,
        'invalid = [',
        [System.Text.UTF8Encoding]::new($false)
    )
    $invalidRuntimeFailed = $false
    try {
        $null = Get-BrowserTrustOverlay `
            -ConfigText $providerConfig `
            -RuntimeSourcePath $runtimePath 2>&1
    } catch {
        $invalidRuntimeFailed = $_.Exception.Message -eq 'Browser trust overlay failed with exit code 1.'
    }
    Assert-True -Condition $invalidRuntimeFailed -Message 'invalid runtime did not propagate failure'

    $temporaryFilesAfter = @(Get-WrapperTemporaryFiles)
    $leakedTemporaryFiles = @(
        $temporaryFilesAfter | Where-Object { $temporaryFilesBefore -notcontains $_ }
    )
    Assert-True -Condition ($leakedTemporaryFiles.Count -eq 0) -Message 'wrapper leaked temporary TOML files'
    Write-Output '[PASS] Browser runtime PowerShell wrapper fixture'
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
