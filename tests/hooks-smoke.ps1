[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$userRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
$hooksPath = Join-Path $userRoot '.codex\hooks.json'
$promptSenseiPath = Join-Path $userRoot '.codex\skills\prompt-sensei\dist\scripts\session-start.js'
$continuityPath = Join-Path $userRoot '.codex\skills\continuity-memory\scripts\continuity-hook.ps1'
$pythonFirstPath = Join-Path $userRoot '.codex\bin\codex-python-first-hook.ps1'
$rulesSourcePath = Join-Path $userRoot 'AGENTS.md'
$rulesGlobalPath = Join-Path $userRoot '.codex\AGENTS.md'
$currentHomePath = Join-Path $userRoot '.prodex\manual-homes\ccswitch-current'
$rulesCurrentPath = Join-Path $currentHomePath 'AGENTS.md'
$hooksGlobalPath = Join-Path $userRoot '.codex\hooks.json'
$hooksCurrentPath = Join-Path $currentHomePath 'hooks.json'

function Assert-Condition {
    param([bool]$Condition, [string]$Message)

    if (-not $Condition) { throw $Message }
}

function Invoke-Hook {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$InputJson,
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$AllowEmptyOutput,
        [switch]$ReturnOutput
    )

    $output = @($InputJson | & $Executable @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    Assert-Condition ($exitCode -eq 0) "$Name exited with code $exitCode."
    $text = ($output | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        Assert-Condition $AllowEmptyOutput "$Name returned empty output."
    } else {
        $null = $text | ConvertFrom-Json -ErrorAction Stop
    }
    $result = [ordered]@{ name = $Name; exitCode = $exitCode; outputLength = $text.Length }
    if ($ReturnOutput) { $result.output = $text }
    [pscustomobject]$result
}

$hooks = Get-Content -LiteralPath $hooksPath -Raw | ConvertFrom-Json
$requiredMirrorPaths = @($rulesSourcePath, $rulesGlobalPath, $rulesCurrentPath, $hooksGlobalPath, $hooksCurrentPath)
foreach ($path in $requiredMirrorPaths) {
    Assert-Condition (Test-Path -LiteralPath $path -PathType Leaf) "Required global mirror file is missing: $path"
}
$rulesSourceHash = (Get-FileHash -LiteralPath $rulesSourcePath -Algorithm SHA256).Hash
$rulesGlobalHash = (Get-FileHash -LiteralPath $rulesGlobalPath -Algorithm SHA256).Hash
$rulesCurrentHash = (Get-FileHash -LiteralPath $rulesCurrentPath -Algorithm SHA256).Hash
$hooksGlobalHash = (Get-FileHash -LiteralPath $hooksGlobalPath -Algorithm SHA256).Hash
$hooksCurrentHash = (Get-FileHash -LiteralPath $hooksCurrentPath -Algorithm SHA256).Hash
Assert-Condition ($rulesSourceHash -eq $rulesGlobalHash -and $rulesGlobalHash -eq $rulesCurrentHash) `
    'AGENTS.md source, global copy, and current-home mirror differ.'
Assert-Condition ($hooksGlobalHash -eq $hooksCurrentHash) `
    'Global and current-home hooks.json mirrors differ.'
$sessionCommands = @($hooks.hooks.SessionStart.hooks.command)
$userPromptCommands = @($hooks.hooks.UserPromptSubmit.hooks.command)
$preCompactCommands = @($hooks.hooks.PreCompact.hooks.command)
Assert-Condition ($sessionCommands.Count -eq 2) 'SessionStart must contain exactly two command hooks.'
$normalizedSessionCommands = @($sessionCommands | ForEach-Object { ([string]$_).Replace('\\', '\') })
Assert-Condition (@($normalizedSessionCommands | Where-Object { $_ -like "*$promptSenseiPath*" }).Count -eq 1) `
    'Prompt Sensei SessionStart command is missing or duplicated.'
$continuityCommand = [string]$normalizedSessionCommands[1]
$pwshSeparatorIndex = $continuityCommand.IndexOf(' -NoProfile', [StringComparison]::Ordinal)
Assert-Condition ($pwshSeparatorIndex -gt 0) 'Continuity SessionStart command has no pwsh argument boundary.'
$configuredPowerShellPath = $continuityCommand.Substring(0, $pwshSeparatorIndex)
Assert-Condition ([IO.Path]::IsPathFullyQualified($configuredPowerShellPath)) `
    'Continuity SessionStart command does not use an absolute pwsh path.'
Assert-Condition (Test-Path -LiteralPath $configuredPowerShellPath -PathType Leaf) `
    'Continuity SessionStart pwsh executable does not exist.'
Assert-Condition ([IO.Path]::GetFileName($configuredPowerShellPath) -eq 'pwsh.exe') `
    'Continuity SessionStart command does not use pwsh.exe.'
Assert-Condition ($continuityCommand -like "*$continuityPath*") `
    'Continuity SessionStart script path is missing.'
Assert-Condition ($userPromptCommands.Count -eq 2) 'UserPromptSubmit must contain exactly two command hooks.'
$normalizedUserPromptCommands = @($userPromptCommands | ForEach-Object { ([string]$_).Replace('\\', '\') })
Assert-Condition (@($normalizedUserPromptCommands | Where-Object { $_ -like '*observe.js*--hash-only*' }).Count -eq 1) `
    'Prompt Sensei UserPromptSubmit command is missing or duplicated.'
Assert-Condition (@($normalizedUserPromptCommands | Where-Object { $_ -like "*$pythonFirstPath*" }).Count -eq 1) `
    'Python-first UserPromptSubmit command is missing or duplicated.'
Assert-Condition (Test-Path -LiteralPath $pythonFirstPath -PathType Leaf) `
    'Python-first hook script does not exist.'
Assert-Condition ($preCompactCommands.Count -eq 1) 'PreCompact must contain exactly one command hook.'

$sessionInput = [ordered]@{
    hook_event_name = 'SessionStart'
    source = 'startup'
    cwd = (Get-Location).ProviderPath
    session_id = 'hooks-smoke'
} | ConvertTo-Json -Compress
$preCompactInput = [ordered]@{
    hook_event_name = 'PreCompact'
    source = 'manual'
    cwd = (Get-Location).ProviderPath
    session_id = 'hooks-smoke'
} | ConvertTo-Json -Compress
$complexPromptInput = [ordered]@{
    hook_event_name = 'UserPromptSubmit'
    prompt = '解析 JSON 文件并统计所有对象节点。'
    cwd = (Get-Location).ProviderPath
    session_id = 'hooks-smoke'
} | ConvertTo-Json -Compress
$simplePromptInput = [ordered]@{
    hook_event_name = 'UserPromptSubmit'
    prompt = '查看 Python 版本。'
    cwd = (Get-Location).ProviderPath
    session_id = 'hooks-smoke'
} | ConvertTo-Json -Compress
$englishRecursivePromptInput = [ordered]@{
    hook_event_name = 'UserPromptSubmit'
    prompt = 'Recursively scan a directory and count files.'
    cwd = (Get-Location).ProviderPath
    session_id = 'hooks-smoke'
} | ConvertTo-Json -Compress
$englishAnalyzePromptInput = [ordered]@{
    hook_event_name = 'UserPromptSubmit'
    prompt = 'Analyze YAML file and extract its records.'
    cwd = (Get-Location).ProviderPath
    session_id = 'hooks-smoke'
} | ConvertTo-Json -Compress
$englishComplexPromptCases = @(
    [pscustomobject]@{
        Name = 'python-first-english-recursive-prompt'
        InputJson = $englishRecursivePromptInput
        ErrorMessage = 'Python-first hook did not emit context for an English recursive scan prompt.'
    }
    [pscustomobject]@{
        Name = 'python-first-english-analyze-prompt'
        InputJson = $englishAnalyzePromptInput
        ErrorMessage = 'Python-first hook did not emit context for an English structured-file analysis prompt.'
    }
)

$pythonFirstCommand = [string](@($normalizedUserPromptCommands | Where-Object { $_ -like "*$pythonFirstPath*" })[0])
$complexHookResult = Invoke-Hook -Name 'python-first-complex-prompt' -InputJson $complexPromptInput `
    -Executable $env:ComSpec -Arguments @('/d', '/s', '/c', $pythonFirstCommand) -ReturnOutput
$complexHookJson = $complexHookResult.output | ConvertFrom-Json
Assert-Condition ([string]$complexHookJson.hookSpecificOutput.additionalContext -like '*Python-first*') `
    'Python-first hook did not emit context for a complex structured-file prompt.'
Assert-Condition ([string]$complexHookJson.hookSpecificOutput.additionalContext -like '*Python as the first processing command*') `
    'Python-first hook omitted the first-command constraint.'
Assert-Condition ([string]$complexHookJson.hookSpecificOutput.additionalContext -like '*PowerShell only for simple system commands*') `
    'Python-first hook omitted the simple-command PowerShell constraint.'
Assert-Condition ([string]$complexHookJson.hookSpecificOutput.additionalContext -like '*switch to Python*') `
    'Python-first hook omitted the PowerShell-failure fallback constraint.'
$englishComplexHookResults = @(
    foreach ($case in $englishComplexPromptCases) {
        $hookResult = Invoke-Hook -Name $case.Name -InputJson $case.InputJson `
            -Executable $env:ComSpec -Arguments @('/d', '/s', '/c', $pythonFirstCommand) -ReturnOutput
        Assert-Condition (-not [string]::IsNullOrWhiteSpace([string]$hookResult.output)) $case.ErrorMessage
        $hookResult
    }
)
$simpleHookResult = Invoke-Hook -Name 'python-first-simple-prompt' -InputJson $simplePromptInput `
    -Executable $env:ComSpec -Arguments @('/d', '/s', '/c', $pythonFirstCommand) -AllowEmptyOutput -ReturnOutput
Assert-Condition ([string]::IsNullOrWhiteSpace([string]$simpleHookResult.output)) `
    'Python-first hook incorrectly emitted context for a simple prompt.'
$emptyHookResult = Invoke-Hook -Name 'python-first-empty-input' -InputJson '' `
    -Executable $env:ComSpec -Arguments @('/d', '/s', '/c', $pythonFirstCommand) -AllowEmptyOutput -ReturnOutput
Assert-Condition ([string]::IsNullOrWhiteSpace([string]$emptyHookResult.output)) `
    'Python-first hook did not remain non-blocking for empty input.'
$badJsonHookResult = Invoke-Hook -Name 'python-first-bad-json' -InputJson '{not-json' `
    -Executable $env:ComSpec -Arguments @('/d', '/s', '/c', $pythonFirstCommand) -AllowEmptyOutput -ReturnOutput
Assert-Condition ([string]::IsNullOrWhiteSpace([string]$badJsonHookResult.output)) `
    'Python-first hook did not remain non-blocking for malformed JSON.'

$results = @(
    $complexHookResult | Select-Object name, exitCode, outputLength
    $englishComplexHookResults | Select-Object name, exitCode, outputLength
    $simpleHookResult | Select-Object name, exitCode, outputLength
    $emptyHookResult | Select-Object name, exitCode, outputLength
    $badJsonHookResult | Select-Object name, exitCode, outputLength
    Invoke-Hook -Name 'prompt-sensei-session-start' -InputJson $sessionInput `
        -Executable $env:ComSpec -Arguments @('/d', '/s', '/c', [string]$sessionCommands[0])
    Invoke-Hook -Name 'continuity-session-start' -InputJson $sessionInput `
        -Executable $env:ComSpec -Arguments @('/d', '/s', '/c', [string]$sessionCommands[1]) -AllowEmptyOutput
    Invoke-Hook -Name 'continuity-pre-compact' -InputJson $preCompactInput `
        -Executable $env:ComSpec -Arguments @('/d', '/s', '/c', [string]$preCompactCommands[0]) -AllowEmptyOutput
)
$results | ConvertTo-Json -Depth 4
