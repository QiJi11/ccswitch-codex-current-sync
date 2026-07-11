Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$UserRoot = if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
    [Environment]::GetFolderPath('UserProfile')
} else {
    [IO.Path]::GetFullPath($env:USERPROFILE)
}
$ProdexRoot = Join-Path $UserRoot '.prodex'
$RunHomesRoot = Join-Path $ProdexRoot 'manual-homes\ccswitch-runs'
$MaterializeScript = Join-Path $ProdexRoot 'bin\materialize-ccswitch-codex-run.ps1'
$PersistScript = Join-Path $ProdexRoot 'bin\persist-run-model.ps1'
$ProdexPowerShellScript = Join-Path $env:APPDATA 'npm\prodex.ps1'
$ProdexCommand = Join-Path $env:APPDATA 'npm\prodex.cmd'
$PersistenceLog = Join-Path $ProdexRoot 'logs\ccswitch-event-launcher.log'
$CodexArguments = @($args)

function Disable-CodexFocusReporting {
    if ([Console]::IsOutputRedirected) {
        return
    }

    try {
        $escape = [char]27
        [Console]::Write("${escape}[?1004l")
        [Console]::Out.Flush()
    } catch [System.IO.IOException] {
    } catch [System.InvalidOperationException] {
    }
}

function Get-LastExitCode {
    $exitCodeVariable = Get-Variable -Name LASTEXITCODE -ErrorAction SilentlyContinue
    if ($null -eq $exitCodeVariable) {
        return $null
    }
    return $exitCodeVariable.Value
}

function Get-FocusFixedCodexBin {
    $binRoot = Join-Path $UserRoot '.codex\bin'
    $pointerPath = Join-Path $binRoot 'codex-focusfixed-current.txt'
    if (-not (Test-Path -LiteralPath $pointerPath -PathType Leaf)) {
        throw "Missing Codex focus-fixed pointer: $pointerPath"
    }

    $candidatePath = (Get-Content -LiteralPath $pointerPath -Raw).Trim()
    if ([string]::IsNullOrWhiteSpace($candidatePath)) {
        throw "Codex focus-fixed pointer is empty: $pointerPath"
    }

    $resolvedPath = [IO.Path]::GetFullPath($candidatePath)
    $allowedPrefix = [IO.Path]::GetFullPath($binRoot).TrimEnd('\') + '\'
    if (-not $resolvedPath.StartsWith($allowedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Codex focus-fixed pointer escapes its allowed directory."
    }
    if (-not [string]::Equals([IO.Path]::GetExtension($resolvedPath), '.exe', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Codex focus-fixed pointer must reference an exe."
    }
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        throw "Codex focus-fixed binary does not exist: $resolvedPath"
    }
    return $resolvedPath
}

function Get-CodexLaunchArguments {
    param([object[]]$Arguments)

    $defaultWorkingRoot = Join-Path $UserRoot 'Documents\Codex-Contexts'
    $currentRoot = (Get-Location).ProviderPath
    if ([string]::IsNullOrWhiteSpace($currentRoot) -or -not (Test-Path -LiteralPath $defaultWorkingRoot)) {
        return @($Arguments)
    }

    $normalizedCurrent = [IO.Path]::GetFullPath($currentRoot).TrimEnd('\')
    $normalizedUser = [IO.Path]::GetFullPath($UserRoot).TrimEnd('\')
    if (-not [string]::Equals($normalizedCurrent, $normalizedUser, [StringComparison]::OrdinalIgnoreCase)) {
        return @($Arguments)
    }

    $managementCommands = @(
        'exec', 'e', 'login', 'logout', 'mcp', 'features', 'doctor', 'resume',
        'fork', 'apply', 'a', 'update', 'sandbox', 'completion', 'auth',
        'app-server', 'mcp-server', 'exec-server', 'cloud', 'review'
    )
    $diagnosticFlags = @('--dry-run', '--version', '-V', '--help', '-h')
    $firstCommand = $null
    foreach ($argument in @($Arguments)) {
        $argumentText = [string]$argument
        if ($diagnosticFlags -contains $argumentText) {
            return @($Arguments)
        }
        if ($argumentText -eq '--cd' -or $argumentText -ceq '-C' -or $argumentText.StartsWith('--cd=')) {
            return @($Arguments)
        }
        if ($null -eq $firstCommand -and -not $argumentText.StartsWith('-')) {
            $firstCommand = $argumentText
        }
    }

    if ($null -ne $firstCommand -and $managementCommands -contains $firstCommand) {
        return @($Arguments)
    }
    return @('--cd', $defaultWorkingRoot) + @($Arguments)
}

function Get-ProdexLauncher {
    if (Test-Path -LiteralPath $ProdexCommand -PathType Leaf) {
        return $ProdexCommand
    }
    if (Test-Path -LiteralPath $ProdexPowerShellScript -PathType Leaf) {
        return $ProdexPowerShellScript
    }
    throw "Missing Prodex launcher under: $(Split-Path -Parent $ProdexPowerShellScript)"
}

function Get-HistoricalSessionRequest {
    param([object[]]$Arguments)

    $sessionCommandIndex = -1
    for ($index = 0; $index -lt $Arguments.Count; $index++) {
        if ([string]$Arguments[$index] -in @('resume', 'fork')) {
            $sessionCommandIndex = $index
            break
        }
    }
    if ($sessionCommandIndex -lt 0) { return $null }

    $uuidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    $sessionId = $null
    for ($index = $sessionCommandIndex + 1; $index -lt $Arguments.Count; $index++) {
        $candidate = [string]$Arguments[$index]
        if ($candidate -match $uuidPattern) {
            $sessionId = $candidate.ToLowerInvariant()
            break
        }
    }
    return [pscustomobject]@{
        command = [string]$Arguments[$sessionCommandIndex]
        commandIndex = $sessionCommandIndex
        sessionId = $sessionId
        useLatest = @($Arguments) -contains '--last'
        diagnostic = @($Arguments | Where-Object { [string]$_ -in @('--help', '-h', '--version', '-V') }).Count -gt 0
    }
}

function Assert-ValidRunSnapshot {
    param(
        [Parameter(Mandatory = $true)]$Snapshot,
        [string]$ExpectedRunHome = ''
    )

    $requiredProperties = @(
        'profileName', 'codexHome', 'prodexHome', 'providerId',
        'providerName', 'model', 'modelReasoningEffort'
    )
    foreach ($propertyName in $requiredProperties) {
        if ($Snapshot.PSObject.Properties.Name -notcontains $propertyName) {
            throw "cc-switch run metadata is missing '$propertyName'."
        }
    }
    foreach ($propertyName in @('profileName', 'codexHome', 'prodexHome', 'providerId', 'providerName')) {
        if ([string]::IsNullOrWhiteSpace([string]$Snapshot.$propertyName)) {
            throw "cc-switch run metadata has an empty '$propertyName'."
        }
    }

    $codexHome = [IO.Path]::GetFullPath([string]$Snapshot.codexHome)
    $prodexHome = [IO.Path]::GetFullPath([string]$Snapshot.prodexHome)
    if (-not [string]::IsNullOrWhiteSpace($ExpectedRunHome)) {
        $expectedCodexHome = [IO.Path]::GetFullPath($ExpectedRunHome)
        $expectedProdexHome = [IO.Path]::GetFullPath((Join-Path $expectedCodexHome '.prodex-runtime'))
        if (-not [string]::Equals($codexHome, $expectedCodexHome, [StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals($prodexHome, $expectedProdexHome, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Historical session metadata references a different run home.'
        }
    }
    if (-not (Test-Path -LiteralPath $codexHome -PathType Container)) {
        throw 'cc-switch run metadata references a missing run home.'
    }
    if (-not (Test-Path -LiteralPath $prodexHome -PathType Container)) {
        throw 'cc-switch run metadata references a missing private Prodex home.'
    }
    return $Snapshot
}

function Get-RecoverableSessionCandidates {
    param([AllowNull()][string]$SessionId)

    if (-not (Test-Path -LiteralPath $RunHomesRoot -PathType Container)) {
        throw 'No cc-switch run homes exist for session recovery.'
    }

    $sessionCandidates = [Collections.Generic.List[object]]::new()
    $uuidAtEndPattern = '(?i)([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$'
    foreach ($runDirectory in Get-ChildItem -LiteralPath $RunHomesRoot -Directory -Force) {
        $sessionsRoot = Join-Path $runDirectory.FullName 'sessions'
        if (-not (Test-Path -LiteralPath $sessionsRoot -PathType Container)) { continue }

        $metadataPath = Join-Path $runDirectory.FullName 'run-provider.json'
        if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) { continue }
        try {
            $snapshot = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
            $snapshot = Assert-ValidRunSnapshot -Snapshot $snapshot -ExpectedRunHome $runDirectory.FullName
        } catch {
            continue
        }

        $sessionFiles = if ([string]::IsNullOrWhiteSpace($SessionId)) {
            Get-ChildItem -LiteralPath $sessionsRoot -Recurse -File -Filter '*.jsonl' -ErrorAction SilentlyContinue
        } else {
            Get-ChildItem -LiteralPath $sessionsRoot -Recurse -File -Filter "*-$SessionId.jsonl" -ErrorAction SilentlyContinue |
                Where-Object { $_.BaseName.EndsWith("-$SessionId", [StringComparison]::OrdinalIgnoreCase) }
        }
        foreach ($sessionFile in @($sessionFiles)) {
            $idMatch = [regex]::Match($sessionFile.BaseName, $uuidAtEndPattern)
            if (-not $idMatch.Success) { continue }
            $sessionCandidates.Add([pscustomobject]@{
                runHome = $runDirectory.FullName
                sessionId = $idMatch.Groups[1].Value.ToLowerInvariant()
                sessionWriteTimeUtc = $sessionFile.LastWriteTimeUtc
                snapshot = $snapshot
            }) | Out-Null
        }
    }
    return @($sessionCandidates)
}

function Get-HistoricalSessionSnapshot {
    param([AllowNull()][string]$SessionId)

    $sessionCandidates = @(Get-RecoverableSessionCandidates -SessionId $SessionId)
    if ($sessionCandidates.Count -eq 0) {
        if ([string]::IsNullOrWhiteSpace($SessionId)) {
            throw 'No recoverable cc-switch sessions were found.'
        }
        throw "No recoverable cc-switch session found with ID $SessionId."
    }

    $selectedSession = @($sessionCandidates | Sort-Object sessionWriteTimeUtc -Descending | Select-Object -First 1)[0]
    return $selectedSession.snapshot
}

function Select-HistoricalSessionCandidate {
    $sessionCandidates = @(
        Get-RecoverableSessionCandidates -SessionId $null |
            Sort-Object sessionWriteTimeUtc -Descending
    )
    if ($sessionCandidates.Count -eq 0) {
        throw 'No recoverable cc-switch sessions were found.'
    }

    Write-Host 'Recoverable Codex sessions:'
    for ($index = 0; $index -lt $sessionCandidates.Count; $index++) {
        $candidate = $sessionCandidates[$index]
        $provider = Get-SafeConsoleText -Text $candidate.snapshot.providerName
        $timestamp = ([DateTime]$candidate.sessionWriteTimeUtc).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')
        Write-Host ("[{0}] {1}  {2}  {3}" -f ($index + 1), $timestamp, $provider, $candidate.sessionId)
    }

    while ($true) {
        [Console]::Write("Select session [1-$($sessionCandidates.Count)] or q: ")
        $selection = [Console]::ReadLine()
        if ($null -eq $selection) {
            throw 'Session selection requires interactive input; use resume --last or an explicit UUID.'
        }
        if ($selection.Trim() -eq 'q') {
            throw [OperationCanceledException]::new('Session selection was canceled.')
        }
        $selectedNumber = 0
        if ([int]::TryParse($selection.Trim(), [ref]$selectedNumber) -and
            $selectedNumber -ge 1 -and $selectedNumber -le $sessionCandidates.Count) {
            return $sessionCandidates[$selectedNumber - 1]
        }
    }
}

function Add-SessionIdToArguments {
    param(
        [object[]]$Arguments,
        [Parameter(Mandatory = $true)][int]$CommandIndex,
        [Parameter(Mandatory = $true)][string]$SessionId
    )

    $updatedArguments = [Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $Arguments.Count; $index++) {
        $updatedArguments.Add($Arguments[$index]) | Out-Null
        if ($index -eq $CommandIndex) {
            $updatedArguments.Add($SessionId) | Out-Null
        }
    }
    return @($updatedArguments)
}

function Get-MaterializedSnapshot {
    if (-not (Test-Path -LiteralPath $MaterializeScript -PathType Leaf)) {
        throw "Missing cc-switch materialize script: $MaterializeScript"
    }

    $global:LASTEXITCODE = 0
    $materializeOutput = @(& $MaterializeScript -Quiet)
    $materializeExitCode = Get-LastExitCode
    if ($materializeExitCode -notin @($null, 0)) {
        throw "cc-switch materialize failed with exit code $materializeExitCode."
    }

    $jsonLine = @($materializeOutput | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Last 1)
    if ($jsonLine.Count -ne 1) {
        throw 'cc-switch materialize returned no JSON metadata.'
    }
    try {
        $snapshot = $jsonLine[0] | ConvertFrom-Json
    } catch [System.ArgumentException] {
        throw 'cc-switch materialize returned invalid JSON metadata.'
    }

    return Assert-ValidRunSnapshot -Snapshot $snapshot
}

function Get-SafeConsoleText {
    param([AllowNull()][object]$Text)

    $safeText = ([string]$Text) -replace '[\x00-\x1f\x7f]', '?'
    if ($safeText.Length -gt 160) {
        return $safeText.Substring(0, 157) + '...'
    }
    return $safeText
}

function Write-LaunchSummary {
    param([Parameter(Mandatory = $true)]$Snapshot)

    $provider = Get-SafeConsoleText -Text $Snapshot.providerName
    $model = if ([string]::IsNullOrWhiteSpace([string]$Snapshot.model)) {
        '<provider-default>'
    } else {
        Get-SafeConsoleText -Text $Snapshot.model
    }
    $effort = Get-SafeConsoleText -Text $Snapshot.modelReasoningEffort
    Write-Host ("[cc-switch] provider={0} model={1} reasoning={2}" -f $provider, $model, $effort)
}

function Write-PersistenceFailure {
    param(
        [Parameter(Mandatory = $true)][string]$RunHome,
        [Parameter(Mandatory = $true)][string]$Reason
    )

    $warningText = "Model persistence failed for run '$RunHome' ($Reason)."
    Write-Warning $warningText
    try {
        $logDirectory = Split-Path -Parent $PersistenceLog
        [IO.Directory]::CreateDirectory($logDirectory) | Out-Null
        $logLine = "[{0}] WARN {1}" -f (Get-Date).ToString('o'), $warningText
        [IO.File]::AppendAllText($PersistenceLog, $logLine + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    } catch [System.IO.IOException] {
        Write-Warning "Could not write persistence failure log: $PersistenceLog"
    } catch [System.UnauthorizedAccessException] {
        Write-Warning "Could not write persistence failure log: $PersistenceLog"
    }
}

function Invoke-RunModelPersistence {
    param(
        [Parameter(Mandatory = $true)][string]$RunHome,
        [Parameter(Mandatory = $true)][long]$ExitOrder
    )

    if (-not (Test-Path -LiteralPath $PersistScript -PathType Leaf)) {
        Write-PersistenceFailure -RunHome $RunHome -Reason 'persist script is missing'
        return
    }

    try {
        $powerShellExecutable = if ($PSVersionTable.PSEdition -eq 'Core') {
            Join-Path $PSHOME 'pwsh.exe'
        } else {
            Join-Path $PSHOME 'powershell.exe'
        }
        if (-not (Test-Path -LiteralPath $powerShellExecutable -PathType Leaf)) {
            throw "Current PowerShell executable was not found: $powerShellExecutable"
        }
        & $powerShellExecutable -NoProfile -NonInteractive -ExecutionPolicy Bypass `
            -File $PersistScript -RunHome $RunHome -ExitOrder $ExitOrder `
            -AllowedRunHomesRoot $RunHomesRoot -Json *> $null
        $persistenceExitCode = Get-LastExitCode
        if ($persistenceExitCode -notin @($null, 0)) {
            Write-PersistenceFailure -RunHome $RunHome -Reason "exit code $persistenceExitCode"
        }
    } catch {
        $exceptionType = $_.Exception.GetType().Name
        $exceptionMessage = Get-SafeConsoleText -Text $_.Exception.Message
        Write-PersistenceFailure -RunHome $RunHome -Reason ("{0}: {1}" -f $exceptionType, $exceptionMessage)
    }
}

function Restore-ProcessEnvironment {
    param(
        [AllowNull()][string]$PreviousProdexCodexBin,
        [AllowNull()][string]$PreviousProdexHome
    )

    if ($null -eq $PreviousProdexCodexBin) {
        Remove-Item -LiteralPath 'Env:\PRODEX_CODEX_BIN' -ErrorAction SilentlyContinue
    } else {
        $env:PRODEX_CODEX_BIN = $PreviousProdexCodexBin
    }
    if ($null -eq $PreviousProdexHome) {
        Remove-Item -LiteralPath 'Env:\PRODEX_HOME' -ErrorAction SilentlyContinue
    } else {
        $env:PRODEX_HOME = $PreviousProdexHome
    }
}

$previousProdexCodexBin = [Environment]::GetEnvironmentVariable('PRODEX_CODEX_BIN', 'Process')
$previousProdexHome = [Environment]::GetEnvironmentVariable('PRODEX_HOME', 'Process')
$materializedSnapshot = $null
$codexExitCode = 1
$launchOutcomeHandled = $false
$exitOrder = [long]0

try {
    Disable-CodexFocusReporting
    $focusFixedCodexBin = Get-FocusFixedCodexBin
    $env:PRODEX_CODEX_BIN = $focusFixedCodexBin
    # Materialization belongs to the user-level Prodex root, not an inherited run-scoped home.
    $env:PRODEX_HOME = $ProdexRoot
    $prodexLauncher = Get-ProdexLauncher

    $historicalSessionRequest = Get-HistoricalSessionRequest -Arguments $CodexArguments
    $materializedSnapshot = if ($null -eq $historicalSessionRequest) {
        Get-MaterializedSnapshot
    } elseif ($null -ne $historicalSessionRequest.sessionId -or
        [bool]$historicalSessionRequest.useLatest -or
        [bool]$historicalSessionRequest.diagnostic) {
        Get-HistoricalSessionSnapshot -SessionId $historicalSessionRequest.sessionId
    } else {
        $selectedSession = Select-HistoricalSessionCandidate
        $CodexArguments = @(Add-SessionIdToArguments `
            -Arguments $CodexArguments `
            -CommandIndex ([int]$historicalSessionRequest.commandIndex) `
            -SessionId ([string]$selectedSession.sessionId))
        $selectedSession.snapshot
    }
    Write-LaunchSummary -Snapshot $materializedSnapshot
    $launchArguments = @(Get-CodexLaunchArguments -Arguments $CodexArguments)
    $env:PRODEX_HOME = [string]$materializedSnapshot.prodexHome
    $global:LASTEXITCODE = 0
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        # Prodex emits update notices on stderr; the run outcome is governed by its exit code.
        $ErrorActionPreference = 'Continue'
        & $prodexLauncher run --profile ([string]$materializedSnapshot.profileName) `
            --no-auto-rotate --full-access @launchArguments
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    $exitOrder = [DateTime]::UtcNow.Ticks
    $lastExitCode = Get-LastExitCode
    $codexExitCode = if ($null -eq $lastExitCode) { 0 } else { [int]$lastExitCode }
    $launchOutcomeHandled = $true
} catch [System.Management.Automation.PipelineStoppedException] {
    $exitOrder = [DateTime]::UtcNow.Ticks
    $lastExitCode = Get-LastExitCode
    $codexExitCode = if ($lastExitCode -notin @($null, 0)) { [int]$lastExitCode } else { 130 }
    $launchOutcomeHandled = $true
} catch [OperationCanceledException] {
    $exitOrder = [DateTime]::UtcNow.Ticks
    $codexExitCode = 130
    $launchOutcomeHandled = $true
} catch {
    $exitOrder = [DateTime]::UtcNow.Ticks
    Write-Error -ErrorRecord $_ -ErrorAction Continue
    $codexExitCode = 1
    $launchOutcomeHandled = $true
} finally {
    Restore-ProcessEnvironment `
        -PreviousProdexCodexBin $previousProdexCodexBin `
        -PreviousProdexHome $previousProdexHome
    if ($null -ne $materializedSnapshot) {
        if ($exitOrder -le 0) {
            $exitOrder = [DateTime]::UtcNow.Ticks
        }
        Invoke-RunModelPersistence -RunHome ([string]$materializedSnapshot.codexHome) -ExitOrder $exitOrder
    }
    Disable-CodexFocusReporting
    if (-not $launchOutcomeHandled) {
        # PipelineStoppedException bypasses catch blocks in some hosts, but finally still runs.
        exit 130
    }
}

exit $codexExitCode
