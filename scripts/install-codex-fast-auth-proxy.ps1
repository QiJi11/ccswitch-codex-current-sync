[CmdletBinding()]
param(
    [string]$CcSwitchRoot = '',
    [ValidateRange(1024, 65535)]
    [int]$Port = 17896,
    [switch]$Uninstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'resolve-ccswitch-root.ps1')

$userRoot = [System.IO.Path]::GetFullPath($env:USERPROFILE)
$ccSwitchRoot = Resolve-CcSwitchRoot -ExplicitRoot $CcSwitchRoot -UserRoot $userRoot -AppDataRoot $env:APPDATA
$binDirectory = Join-Path $userRoot '.prodex\bin'
$runDirectory = Join-Path $userRoot '.prodex\run'
$installedProxy = Join-Path $binDirectory 'codex-fast-auth-proxy.py'
$pidFile = Join-Path $runDirectory 'codex-fast-auth-proxy.pid'
$tokenFile = Join-Path $runDirectory 'codex-fast-auth-proxy.token'
$runKeyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$runValueName = 'CodexFastAuthProxy'

function Stop-InstalledProxy {
    if (-not (Test-Path -LiteralPath $pidFile -PathType Leaf)) {
        return
    }
    $proxyPid = 0
    if (-not [int]::TryParse((Get-Content -Raw -LiteralPath $pidFile), [ref]$proxyPid)) {
        throw "Invalid proxy PID file: $pidFile"
    }
    $process = Get-CimInstance Win32_Process -Filter "ProcessId = $proxyPid" -ErrorAction SilentlyContinue
    if ($null -ne $process -and -not [string]::IsNullOrWhiteSpace([string]$process.CommandLine) -and
        [string]$process.CommandLine -like "*$installedProxy*") {
        Stop-Process -Id $proxyPid -Force
    }
    Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
}

if ($Uninstall) {
    Stop-InstalledProxy
    Remove-ItemProperty -Path $runKeyPath -Name $runValueName -ErrorAction SilentlyContinue
    Write-Output 'Codex fast auth proxy startup entry removed.'
    return
}

$pythonw = (Get-Command pythonw.exe -ErrorAction Stop).Source

New-Item -ItemType Directory -Path $binDirectory, $runDirectory -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'codex-fast-auth-proxy.py') -Destination $installedProxy -Force
if (-not (Test-Path -LiteralPath $tokenFile -PathType Leaf)) {
    $tokenBytes = [byte[]]::new(32)
    [Security.Cryptography.RandomNumberGenerator]::Fill($tokenBytes)
    $token = [Convert]::ToHexString($tokenBytes).ToLowerInvariant()
    [System.IO.File]::WriteAllText($tokenFile, $token, [System.Text.Encoding]::ASCII)
}
Stop-InstalledProxy

$arguments = @(
    $installedProxy
    '--ccswitch-root'
    $ccSwitchRoot
    '--token-file'
    $tokenFile
    '--host'
    '127.0.0.1'
    '--port'
    [string]$Port
    '--pid-file'
    $pidFile
)
$quotedArguments = $arguments | ForEach-Object { '"' + [string]$_ + '"' }
$startupCommand = '"' + $pythonw + '" ' + ($quotedArguments -join ' ')
New-Item -Path $runKeyPath -Force | Out-Null
Set-ItemProperty -Path $runKeyPath -Name $runValueName -Value $startupCommand
Start-Process -FilePath $pythonw -ArgumentList ($quotedArguments -join ' ') -WindowStyle Hidden

$healthUrl = "http://127.0.0.1:$Port/health"
for ($attempt = 1; $attempt -le 20; $attempt++) {
    Start-Sleep -Milliseconds 250
    try {
        $health = Invoke-RestMethod -Uri $healthUrl -TimeoutSec 2
        if ($health.status -eq 'ok') {
            [pscustomobject]@{
                Installed = $true
                Port = $Port
                ProviderId = $health.providerId
                UpstreamHost = $health.upstreamHost
                Startup = $runValueName
                TokenFile = $tokenFile
            } | ConvertTo-Json -Compress
            return
        }
    } catch [System.Net.WebException] {
        if ($attempt -eq 20) {
            throw
        }
    } catch [System.Net.Http.HttpRequestException] {
        if ($attempt -eq 20) {
            throw
        }
    }
}
throw 'Codex fast auth proxy did not become healthy.'
