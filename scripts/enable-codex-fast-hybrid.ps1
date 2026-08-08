[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ChatGptAuthPath,
    [string]$CodexHome = (Join-Path $env:USERPROFILE '.codex'),
    [string]$ModelCatalogPath = (Join-Path $env:USERPROFILE '.codex\provider-gpt-5.6-model-catalog.json'),
    [string]$ProxyTokenPath = (Join-Path $env:USERPROFILE '.prodex\run\codex-fast-auth-proxy.token'),
    [ValidateRange(1024, 65535)]
    [int]$Port = 17896
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Set-RootConfigValue {
    param([string[]]$Lines, [string]$Key, [string]$Value)
    $updatedLines = [System.Collections.Generic.List[string]]::new()
    $updatedLines.AddRange($Lines)
    $sectionIndex = $updatedLines.Count
    for ($index = 0; $index -lt $updatedLines.Count; $index++) {
        if ($updatedLines[$index].TrimStart().StartsWith('[')) { $sectionIndex = $index; break }
    }
    for ($index = 0; $index -lt $sectionIndex; $index++) {
        if ($updatedLines[$index] -match "^\s*$([regex]::Escape($Key))\s*=") {
            $updatedLines[$index] = "$Key = $Value"
            return [string[]]$updatedLines.ToArray()
        }
    }
    $updatedLines.Insert($sectionIndex, "$Key = $Value")
    return [string[]]$updatedLines.ToArray()
}

function Set-SectionConfigValue {
    param([string[]]$Lines, [string]$Section, [string]$Key, [string]$Value)
    $sectionHeader = "[$Section]"
    $updatedLines = [System.Collections.Generic.List[string]]::new()
    $updatedLines.AddRange($Lines)
    $sectionIndex = -1
    for ($index = 0; $index -lt $updatedLines.Count; $index++) {
        if ($updatedLines[$index].Trim() -eq $sectionHeader) { $sectionIndex = $index; break }
    }
    if ($sectionIndex -lt 0) {
        if ($updatedLines.Count -gt 0 -and $updatedLines[$updatedLines.Count - 1] -ne '') {
            $updatedLines.Add('')
        }
        $updatedLines.Add($sectionHeader)
        $updatedLines.Add("$Key = $Value")
        return [string[]]$updatedLines.ToArray()
    }
    $nextSection = $updatedLines.Count
    for ($index = $sectionIndex + 1; $index -lt $updatedLines.Count; $index++) {
        if ($updatedLines[$index].TrimStart().StartsWith('[')) { $nextSection = $index; break }
        if ($updatedLines[$index] -match "^\s*$([regex]::Escape($Key))\s*=") {
            $updatedLines[$index] = "$Key = $Value"
            return [string[]]$updatedLines.ToArray()
        }
    }
    $updatedLines.Insert($nextSection, "$Key = $Value")
    return [string[]]$updatedLines.ToArray()
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Content)
    $temporaryPath = "$Path.tmp-$PID-$([guid]::NewGuid().ToString('N'))"
    [System.IO.File]::WriteAllText($temporaryPath, $Content, [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
}

$codexHome = [System.IO.Path]::GetFullPath($CodexHome)
$configPath = Join-Path $codexHome 'config.toml'
$authPath = Join-Path $codexHome 'auth.json'
$chatGptAuthPath = [System.IO.Path]::GetFullPath($ChatGptAuthPath)
$modelCatalogPath = [System.IO.Path]::GetFullPath($ModelCatalogPath)
$proxyTokenPath = [System.IO.Path]::GetFullPath($ProxyTokenPath)
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { throw "Missing Codex config: $configPath" }
if (-not (Test-Path -LiteralPath $chatGptAuthPath -PathType Leaf)) { throw "Missing ChatGPT auth: $chatGptAuthPath" }
if (-not (Test-Path -LiteralPath $modelCatalogPath -PathType Leaf)) { throw "Missing model catalog: $modelCatalogPath" }
if (-not (Test-Path -LiteralPath $proxyTokenPath -PathType Leaf)) { throw "Missing proxy token: $proxyTokenPath" }

$chatGptAuth = Get-Content -Raw -LiteralPath $chatGptAuthPath | ConvertFrom-Json
if ($chatGptAuth.auth_mode -ne 'chatgpt' -or -not $chatGptAuth.tokens.access_token) {
    throw 'The supplied auth file is not a valid ChatGPT login.'
}
$proxyToken = (Get-Content -Raw -LiteralPath $proxyTokenPath).Trim()
if ($proxyToken -notmatch '^[0-9a-f]{64}$') { throw 'The local proxy token is malformed.' }

$lines = [System.Collections.Generic.List[string]]::new()
$lines.AddRange([string[]](Get-Content -LiteralPath $configPath))
$updated = [string[]]$lines.ToArray()
$catalogLiteral = "'" + $modelCatalogPath.Replace("'", "''") + "'"
$updated = Set-RootConfigValue $updated 'model_catalog_json' $catalogLiteral
$updated = Set-RootConfigValue $updated 'model_provider' '"custom"'
$updated = Set-RootConfigValue $updated 'model' '"gpt-5.6-sol"'
$updated = Set-RootConfigValue $updated 'model_reasoning_effort' '"high"'
$updated = Set-RootConfigValue $updated 'service_tier' '"priority"'
$updated = Set-SectionConfigValue $updated 'model_providers.custom' 'name' '"CC Switch Fast proxy"'
$updated = Set-SectionConfigValue $updated 'model_providers.custom' 'base_url' "`"http://127.0.0.1:$Port`""
$updated = Set-SectionConfigValue $updated 'model_providers.custom' 'wire_api' '"responses"'
$updated = Set-SectionConfigValue $updated 'model_providers.custom' 'requires_openai_auth' 'true'
$updated = Set-SectionConfigValue $updated 'model_providers.custom' 'http_headers' "{ `"X-Codex-Fast-Proxy-Token`" = `"$proxyToken`" }"
$updated = Set-SectionConfigValue $updated 'features' 'fast_mode' 'true'
$updated = Set-SectionConfigValue $updated 'app' 'default-service-tier' '"priority"'

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupDirectory = Join-Path $codexHome "backups\fast-hybrid-$stamp"
New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
Copy-Item -LiteralPath $configPath -Destination (Join-Path $backupDirectory 'config.toml')
if (Test-Path -LiteralPath $authPath) {
    Copy-Item -LiteralPath $authPath -Destination (Join-Path $backupDirectory 'auth.json')
}

Write-Utf8NoBom -Path $configPath -Content (($updated -join "`n") + "`n")
Write-Utf8NoBom -Path $authPath -Content (($chatGptAuth | ConvertTo-Json -Depth 20) + "`n")

[pscustomobject]@{
    Configured = $true
    BackupDirectory = $backupDirectory
    Model = 'gpt-5.6-sol'
    ServiceTier = 'priority'
    ProxyBaseUrl = "http://127.0.0.1:$Port"
    AuthMode = 'chatgpt'
} | ConvertTo-Json -Compress
