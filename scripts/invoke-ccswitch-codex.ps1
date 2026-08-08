Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'resolve-ccswitch-root.ps1')

$UserRoot = if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
    [Environment]::GetFolderPath('UserProfile')
} else {
    [IO.Path]::GetFullPath($env:USERPROFILE)
}
$ProdexRoot = Join-Path $UserRoot '.prodex'
$RunHomesRoot = Join-Path $ProdexRoot 'manual-homes\ccswitch-runs'
$MaterializeScript = Join-Path $ProdexRoot 'bin\materialize-ccswitch-codex-run.ps1'
$PersistScript = Join-Path $ProdexRoot 'bin\persist-run-model.ps1'
$RunModelWatcherScript = Join-Path $ProdexRoot 'bin\watch-run-model.ps1'
$ProdexPowerShellScript = Join-Path $env:APPDATA 'npm\prodex.ps1'
$ProdexCommand = Join-Path $env:APPDATA 'npm\prodex.cmd'
$PersistenceLog = Join-Path $ProdexRoot 'logs\ccswitch-event-launcher.log'
$CodexUpdateCheckScript = Join-Path $UserRoot '.codex\bin\check-codex-update.ps1'
$TrustedWorkspaceRoot = Join-Path $UserRoot 'Documents\Codex-Contexts'
$CodexArguments = @($args)
$StaticLaunchEnvironmentNames = @('PRODEX_CODEX_BIN', 'PRODEX_HOME', 'CODEX_HOME')
$ActiveCcSwitchRoot = $null

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

function Get-CodexLaunchMode {
    $configuredMode = [Environment]::GetEnvironmentVariable('CCSWITCH_CODEX_LAUNCH_MODE', 'Process')
    if ([string]::IsNullOrWhiteSpace($configuredMode)) { return 'direct' }

    $normalizedMode = $configuredMode.Trim().ToLowerInvariant()
    if ($normalizedMode -notin @('direct', 'prodex')) {
        throw "CCSWITCH_CODEX_LAUNCH_MODE must be 'direct' or 'prodex'."
    }
    return $normalizedMode
}

function Get-FocusFixedCodexBin {
    $binRoot = Join-Path $UserRoot '.codex\bin'
    $pointerPath = Join-Path $binRoot 'codex-focusfixed-current.txt'
    $metadataPath = Join-Path $binRoot 'codex-focusfixed-current.json'
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
    if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
        throw "Missing Codex focus-fixed metadata: $metadataPath"
    }

    $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
    $metadataPathValue = [IO.Path]::GetFullPath([string]$metadata.patchedExe)
    if (-not [string]::Equals($resolvedPath, $metadataPathValue, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Codex focus-fixed pointer and metadata disagree. Run the focus patch updater."
    }
    if ([int]$metadata.enableAfter -ne 0 -or [int]$metadata.disableAfter -lt 1) {
        throw "Codex focus-fixed metadata does not describe a verified focus patch."
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

function Test-CodexNativeDiagnosticRequest {
    param([object[]]$Arguments)

    return $Arguments.Count -eq 1 -and
        @('--version', '-V', '--help', '-h') -ccontains [string]$Arguments[0]
}

function Test-CodexExplicitSandboxRequest {
    param([object[]]$Arguments)

    $compactSandboxArguments = @('-sread-only', '-sworkspace-write', '-sdanger-full-access')
    foreach ($rawArgument in $Arguments) {
        $argument = [string]$rawArgument
        if ($argument -ceq '--') { break }
        if ($argument -ceq '--sandbox' -or $argument -ceq '-s') {
            return $true
        }
        if ($argument.StartsWith('--sandbox=', [StringComparison]::Ordinal) -or
            $argument.StartsWith('-s=', [StringComparison]::Ordinal) -or
            $compactSandboxArguments -ccontains $argument) {
            return $true
        }
    }
    return $false
}

function Test-CodexBypassRequest {
    param([object[]]$Arguments)

    foreach ($rawArgument in $Arguments) {
        $argument = [string]$rawArgument
        if ($argument -ceq '--') { break }
        if ($argument -ceq '--dangerously-bypass-approvals-and-sandbox') {
            return $true
        }
    }
    return $false
}

function Test-CodexUpdateNoticeRequest {
    param([object[]]$Arguments)

    $nonInteractiveCommands = @(
        'exec', 'e', 'review', 'apply', 'a', 'login', 'logout', 'mcp', 'features',
        'doctor', 'update', 'sandbox', 'completion', 'auth', 'app-server',
        'mcp-server', 'exec-server', 'cloud'
    )
    return @($Arguments | Where-Object { $nonInteractiveCommands -ccontains [string]$_ }).Count -eq 0
}

function Write-CodexUpdateNotice {
    if (-not (Test-Path -LiteralPath $CodexUpdateCheckScript -PathType Leaf)) { return }
    try {
        & $CodexUpdateCheckScript
    } catch {
        # Version checks must never block or contaminate a Codex launch.
        Write-Verbose "Codex update check failed; continuing launch: $($_.Exception.Message)"
    }
}

function Find-CodexWorkingRootArgument {
    param([object[]]$Arguments)

    $workingRoot = $null
    for ($index = 0; $index -lt $Arguments.Count; $index++) {
        $argument = [string]$Arguments[$index]
        if ($argument -eq '--') { break }

        if ($argument -eq '--cd' -or $argument -ceq '-C') {
            if ($index + 1 -ge $Arguments.Count) { return '' }
            $workingRoot = [string]$Arguments[$index + 1]
            $index++
            continue
        }
        if ($argument.StartsWith('--cd=', [StringComparison]::Ordinal)) {
            $workingRoot = $argument.Substring('--cd='.Length)
        }
    }
    return $workingRoot
}

function Resolve-CodexWorkingRoot {
    param([object[]]$Arguments)

    $workingRoot = Find-CodexWorkingRootArgument -Arguments $Arguments
    if ($null -eq $workingRoot) {
        $workingRoot = (Get-Location).ProviderPath
    }
    if ([string]::IsNullOrWhiteSpace($workingRoot)) { return $null }

    try {
        if (-not [IO.Path]::IsPathRooted($workingRoot)) {
            $workingRoot = Join-Path (Get-Location).ProviderPath $workingRoot
        }
        return [IO.Path]::GetFullPath($workingRoot).TrimEnd('\')
    } catch {
        # Invalid -C values still belong to Codex; failed resolution only disables auto-trust.
        return $null
    }
}

function New-TrustedProjectConfigOverride {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    $normalizedRoot = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\').ToLowerInvariant()
    return "projects={ '$normalizedRoot' = { trust_level = 'trusted' } }"
}

function Add-TrustedWorkspaceOverride {
    param([object[]]$Arguments)

    $workingRoot = Resolve-CodexWorkingRoot -Arguments $Arguments
    if ([string]::IsNullOrWhiteSpace($workingRoot)) { return @($Arguments) }

    $trustedRoot = [IO.Path]::GetFullPath($TrustedWorkspaceRoot).TrimEnd('\')
    if (-not [string]::Equals($workingRoot, $trustedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        return @($Arguments)
    }

    $override = New-TrustedProjectConfigOverride -ProjectRoot $trustedRoot
    return @('-c', $override) + @($Arguments)
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
    param(
        [Parameter(Mandatory = $true)][string]$LaunchMode,
        [Parameter(Mandatory = $true)][string]$CcSwitchRoot
    )

    if (-not (Test-Path -LiteralPath $MaterializeScript -PathType Leaf)) {
        throw "Missing cc-switch materialize script: $MaterializeScript"
    }

    $global:LASTEXITCODE = 0
    $materializeOutput = @(& $MaterializeScript -Quiet -LaunchMode $LaunchMode -CcSwitchRoot $CcSwitchRoot)
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
    param(
        [Parameter(Mandatory = $true)]$Snapshot,
        [Parameter(Mandatory = $true)][string]$LaunchMode
    )

    $provider = Get-SafeConsoleText -Text $Snapshot.providerName
    $model = if ([string]::IsNullOrWhiteSpace([string]$Snapshot.model)) {
        '<provider-default>'
    } else {
        Get-SafeConsoleText -Text $Snapshot.model
    }
    $effort = Get-SafeConsoleText -Text $Snapshot.modelReasoningEffort
    Write-Host ("[cc-switch] mode={0} provider={1} model={2} reasoning={3}" -f $LaunchMode, $provider, $model, $effort)
}

function Write-PersistenceEvent {
    param(
        [Parameter(Mandatory = $true)][string]$Level,
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$RunHome,
        [Parameter(Mandatory = $true)][string]$Status,
        [AllowNull()][string]$ErrorCode,
        [AllowNull()][object]$ExitCode,
        [AllowNull()][string]$Message
    )

    try {
        $logDirectory = Split-Path -Parent $PersistenceLog
        [IO.Directory]::CreateDirectory($logDirectory) | Out-Null
        $record = [ordered]@{
            timestamp = (Get-Date).ToString('o')
            level = $Level
            source = $Source
            run = Split-Path -Leaf $RunHome
            status = $Status
            errorCode = if ([string]::IsNullOrWhiteSpace($ErrorCode)) { $null } else { Get-SafeConsoleText $ErrorCode }
            exitCode = $ExitCode
            message = if ([string]::IsNullOrWhiteSpace($Message)) { $null } else { Get-SafeConsoleText $Message }
        }
        $logLine = $record | ConvertTo-Json -Depth 4 -Compress
        [IO.File]::AppendAllText($PersistenceLog, $logLine + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    } catch [System.IO.IOException] {
        Write-Warning "Could not write persistence failure log: $PersistenceLog"
    } catch [System.UnauthorizedAccessException] {
        Write-Warning "Could not write persistence failure log: $PersistenceLog"
    }
}

function Write-PersistenceFailure {
    param(
        [Parameter(Mandatory = $true)][string]$RunHome,
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Reason,
        [AllowNull()][string]$ErrorCode = $null,
        [AllowNull()][object]$ExitCode = $null
    )

    $warningText = "Model persistence failed ($Reason) for run '$RunHome'."
    Write-Warning $warningText
    Write-PersistenceEvent -Level 'error' -Source $Source -RunHome $RunHome -Status 'failed' `
        -ErrorCode $ErrorCode -ExitCode $ExitCode -Message $warningText
}

function Find-PersistenceResult {
    param([AllowEmptyCollection()][object[]]$Output)

    for ($index = $Output.Count - 1; $index -ge 0; $index--) {
        $text = [string]$Output[$index]
        if ([string]::IsNullOrWhiteSpace($text)) {
            continue
        }
        try {
            $candidate = $text | ConvertFrom-Json -ErrorAction Stop
            if ($candidate.PSObject.Properties.Name -contains 'ok') {
                return $candidate
            }
        } catch {
        }
    }
    return $null
}

function Invoke-RunModelPersistence {
    param(
        [Parameter(Mandatory = $true)][string]$RunHome,
        [Parameter(Mandatory = $true)][long]$ExitOrder,
        [Parameter(Mandatory = $true)][string]$CcSwitchRoot,
        [string]$Source = 'final',
        [string[]]$ChangedFields = @()
    )

    if (-not (Test-Path -LiteralPath $PersistScript -PathType Leaf)) {
        Write-PersistenceFailure -RunHome $RunHome -Source $Source -Reason 'persist script is missing' `
            -ErrorCode 'persist_script_missing'
        return $false
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
        $arguments = @(
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', $PersistScript,
            '-RunHome', $RunHome,
            '-ExitOrder', ([string]$ExitOrder),
            '-CcSwitchRoot', $CcSwitchRoot,
            '-AllowedRunHomesRoot', $RunHomesRoot,
            '-Json'
        )
        if ($ChangedFields.Count -gt 0) {
            $arguments += @('-ChangedFieldsCsv', ($ChangedFields -join ','))
        }

        $previousPreference = $ErrorActionPreference
        $global:LASTEXITCODE = 0
        try {
            $ErrorActionPreference = 'Continue'
            $output = @(& $powerShellExecutable @arguments 2>&1)
            $persistenceExitCode = Get-LastExitCode
        } finally {
            $ErrorActionPreference = $previousPreference
        }
        $result = Find-PersistenceResult -Output $output
        if ($null -ne $result -and [bool]$result.ok -and
            $persistenceExitCode -in @($null, 0)) {
            Write-PersistenceEvent -Level 'info' -Source $Source -RunHome $RunHome `
                -Status ([string]$result.status) -ErrorCode $null -ExitCode 0 `
                -Message ([string]$result.message)
            return $true
        }

        $errorCode = if ($null -ne $result) { [string]$result.errorCode } else { 'missing_result' }
        $message = if ($null -ne $result) { [string]$result.message } else { 'Persistence returned no JSON result.' }
        Write-PersistenceFailure -RunHome $RunHome -Source $Source `
            -Reason $message -ErrorCode $errorCode -ExitCode $persistenceExitCode
        return $false
    } catch {
        $exceptionType = $_.Exception.GetType().Name
        $exceptionMessage = Get-SafeConsoleText -Text $_.Exception.Message
        Write-PersistenceFailure -RunHome $RunHome -Source $Source `
            -Reason ("{0}: {1}" -f $exceptionType, $exceptionMessage) `
            -ErrorCode 'launcher_exception'
        return $false
    }
}

function Get-RunModelStatePath {
    param([Parameter(Mandatory = $true)][string]$RunHome)

    return Join-Path $RunHome '.ccswitch-model-persist-state.json'
}

function Get-PendingChangedFields {
    param([Parameter(Mandatory = $true)][string]$StateFile)

    if (-not (Test-Path -LiteralPath $StateFile -PathType Leaf)) {
        return @()
    }
    try {
        $state = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
        if ($state.schemaVersion -ne 1) {
            throw 'Unsupported watcher state schema.'
        }
        $fields = @($state.pendingFields)
        foreach ($field in $fields) {
            if ([string]$field -notin @('model', 'model_reasoning_effort')) {
                throw 'Watcher state contains an unsupported changed field.'
            }
        }
        return [string[]]$fields
    } catch {
        Write-PersistenceFailure -RunHome (Split-Path -Parent $StateFile) -Source 'final' `
            -Reason 'watcher state is invalid' -ErrorCode 'invalid_watcher_state'
        return @()
    }
}

function Get-LauncherPowerShellExecutable {
    $name = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
    $path = Join-Path $PSHOME $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Current PowerShell executable was not found: $path"
    }
    return [IO.Path]::GetFullPath($path)
}

function Start-RunModelWatcher {
    param(
        [Parameter(Mandatory = $true)][string]$RunHome,
        [Parameter(Mandatory = $true)][string]$CcSwitchRoot
    )

    if (-not (Test-Path -LiteralPath $RunModelWatcherScript -PathType Leaf)) {
        Write-PersistenceFailure -RunHome $RunHome -Source 'watcher' `
            -Reason 'watcher script is missing' -ErrorCode 'watcher_script_missing'
        return $null
    }

    $stopFile = Join-Path $RunHome ('.ccswitch-model-watch-stop-{0}-{1}.signal' -f `
        $PID, [guid]::NewGuid().ToString('N'))
    $readyFile = Join-Path $RunHome ('.ccswitch-model-watch-ready-{0}-{1}.signal' -f `
        $PID, [guid]::NewGuid().ToString('N'))
    $stateFile = Get-RunModelStatePath -RunHome $RunHome
    try {
        $parentStartTime = (Get-Process -Id $PID -ErrorAction Stop).StartTime.ToUniversalTime().Ticks
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = Get-LauncherPowerShellExecutable
        $startInfo.WorkingDirectory = $UserRoot
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        foreach ($argument in @(
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', $RunModelWatcherScript,
            '-RunHome', $RunHome,
            '-CcSwitchRoot', $CcSwitchRoot,
            '-AllowedRunHomesRoot', $RunHomesRoot,
            '-ParentProcessId', ([string]$PID),
            '-ParentProcessStartTimeUtcTicks', ([string]$parentStartTime),
            '-StopFile', $stopFile,
            '-StateFile', $stateFile,
            '-ReadyFile', $readyFile,
            '-PersistenceLog', $PersistenceLog,
            '-PersistScript', $PersistScript
        )) {
            $null = $startInfo.ArgumentList.Add([string]$argument)
        }
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        if (-not $process.Start()) {
            $process.Dispose()
            throw 'The model watcher process did not start.'
        }
        $ready = $false
        for ($attempt = 0; $attempt -lt 40; $attempt++) {
            if (Test-Path -LiteralPath $readyFile -PathType Leaf) {
                $ready = $true
                break
            }
            if ($process.HasExited) {
                break
            }
            Start-Sleep -Milliseconds 50
        }
        if (-not $ready) {
            if (-not $process.HasExited) {
                $process.Kill($true)
                $null = $process.WaitForExit(2000)
            }
            $process.Dispose()
            throw 'The model watcher did not become ready.'
        }
        return [pscustomobject]@{
            Process = $process
            StopFile = $stopFile
            ReadyFile = $readyFile
            StateFile = $stateFile
        }
    } catch {
        Remove-Item -LiteralPath $stopFile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $readyFile -Force -ErrorAction SilentlyContinue
        Write-PersistenceFailure -RunHome $RunHome -Source 'watcher' `
            -Reason $_.Exception.Message -ErrorCode 'watcher_start_failed'
        return $null
    }
}

function Stop-RunModelWatcher {
    param([AllowNull()]$Watcher)

    if ($null -eq $Watcher) {
        return
    }
    try {
        if (-not $Watcher.Process.HasExited) {
            [IO.File]::WriteAllText([string]$Watcher.StopFile, 'stop', [Text.UTF8Encoding]::new($false))
            if (-not $Watcher.Process.WaitForExit(5000)) {
                $Watcher.Process.Kill($true)
                $null = $Watcher.Process.WaitForExit(2000)
            }
        }
    } catch {
        Write-PersistenceFailure -RunHome (Split-Path -Parent ([string]$Watcher.StateFile)) `
            -Source 'watcher' -Reason $_.Exception.Message -ErrorCode 'watcher_stop_failed'
    } finally {
        $Watcher.Process.Dispose()
        Remove-Item -LiteralPath ([string]$Watcher.StopFile) -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath ([string]$Watcher.ReadyFile) -Force -ErrorAction SilentlyContinue
    }
}

function Get-SnapshotCcSwitchRoot {
    param(
        [Parameter(Mandatory = $true)]$Snapshot,
        [AllowNull()][string]$FallbackRoot
    )

    if ($Snapshot.PSObject.Properties['ccSwitchRoot'] -and
        -not [string]::IsNullOrWhiteSpace([string]$Snapshot.ccSwitchRoot)) {
        try {
            $snapshotRoot = [string]$Snapshot.ccSwitchRoot
            if ($snapshotRoot -match '^(?:[A-Za-z]:[\\/]|\\\\)') {
                return [IO.Path]::GetFullPath($snapshotRoot)
            }
        } catch [ArgumentException] {
        } catch [NotSupportedException] {
        } catch [System.Security.SecurityException] {
        }
    }
    if ([string]::IsNullOrWhiteSpace($FallbackRoot)) {
        return $null
    }
    try {
        if ($FallbackRoot -match '^(?:[A-Za-z]:[\\/]|\\\\)') {
            return [IO.Path]::GetFullPath($FallbackRoot)
        }
        return $null
    } catch [ArgumentException] {
        return $null
    } catch [NotSupportedException] {
        return $null
    } catch [System.Security.SecurityException] {
        return $null
    }
}

function Get-ProcessEnvironmentSnapshot {
    param([Parameter(Mandatory = $true)][string[]]$Names)

    $snapshot = @{}
    foreach ($name in $Names) {
        $snapshot[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    }
    return $snapshot
}

function Restore-ProcessEnvironment {
    param([Parameter(Mandatory = $true)][hashtable]$Snapshot)

    foreach ($name in $Snapshot.Keys) {
        if ($null -eq $Snapshot[$name]) {
            Remove-ProcessEnvironmentVariable -Name $name
        } else {
            [Environment]::SetEnvironmentVariable($name, $Snapshot[$name], 'Process')
        }
    }
}

function Remove-ProcessEnvironmentVariable {
    param([Parameter(Mandatory = $true)][string]$Name)

    $path = "Env:$Name"
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force
    }
}

function Get-LaunchEnvironmentNames {
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $StaticLaunchEnvironmentNames) {
        $null = $names.Add($name)
    }
    foreach ($name in [Environment]::GetEnvironmentVariables('Process').Keys) {
        if ([string]$name -like 'OPENAI_*') {
            $null = $names.Add([string]$name)
        }
    }
    return [string[]]@($names | ForEach-Object { [string]$_ })
}

function Clear-ProcessEnvironment {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Names)

    foreach ($name in $Names) {
        Remove-ProcessEnvironmentVariable -Name $name
    }
}

function Clear-OpenAiProcessEnvironment {
    foreach ($name in [Environment]::GetEnvironmentVariables('Process').Keys) {
        if ([string]$name -like 'OPENAI_*') {
            Remove-ProcessEnvironmentVariable -Name ([string]$name)
        }
    }
}

$launchEnvironmentNames = @(Get-LaunchEnvironmentNames)
$launchEnvironment = Get-ProcessEnvironmentSnapshot -Names $launchEnvironmentNames
$materializedSnapshot = $null
$codexExitCode = 1
$launchOutcomeHandled = $false
$exitOrder = [long]0
$runModelWatcher = $null
$persistenceRoot = $null

try {
    Disable-CodexFocusReporting
    $focusFixedCodexBin = Get-FocusFixedCodexBin
    $launchMode = Get-CodexLaunchMode
    if (Test-CodexNativeDiagnosticRequest -Arguments $CodexArguments) {
        $global:LASTEXITCODE = 0
        & $focusFixedCodexBin @CodexArguments
        $lastExitCode = Get-LastExitCode
        $codexExitCode = if ($null -eq $lastExitCode) { 0 } else { [int]$lastExitCode }
        $launchOutcomeHandled = $true
    } else {
        if (Test-CodexUpdateNoticeRequest -Arguments $CodexArguments) {
            Write-CodexUpdateNotice
        }
        $env:PRODEX_CODEX_BIN = $focusFixedCodexBin
        # Materialization belongs to the user-level Prodex root, not an inherited run-scoped home.
        $env:PRODEX_HOME = $ProdexRoot

        $historicalSessionRequest = Get-HistoricalSessionRequest -Arguments $CodexArguments
        $materializedSnapshot = if ($null -eq $historicalSessionRequest) {
            $ActiveCcSwitchRoot = Resolve-CcSwitchRoot -UserRoot $UserRoot -AppDataRoot $env:APPDATA
            Get-MaterializedSnapshot -LaunchMode $launchMode -CcSwitchRoot $ActiveCcSwitchRoot
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
        Write-LaunchSummary -Snapshot $materializedSnapshot -LaunchMode $launchMode
        $persistenceRoot = Get-SnapshotCcSwitchRoot `
            -Snapshot $materializedSnapshot -FallbackRoot $ActiveCcSwitchRoot
        if (-not [string]::IsNullOrWhiteSpace([string]$persistenceRoot)) {
            $runModelWatcher = Start-RunModelWatcher `
                -RunHome ([string]$materializedSnapshot.codexHome) `
                -CcSwitchRoot $persistenceRoot
        }

        $launchArguments = @(Get-CodexLaunchArguments -Arguments $CodexArguments)
        $launchArguments = @(Add-TrustedWorkspaceOverride -Arguments $launchArguments)
        $explicitSandboxRequested = Test-CodexExplicitSandboxRequest -Arguments $launchArguments
        $bypassRequested = Test-CodexBypassRequest -Arguments $launchArguments
        if ($explicitSandboxRequested -and $bypassRequested) {
            throw 'Conflicting Codex safety options: an explicit sandbox cannot be combined with --dangerously-bypass-approvals-and-sandbox.'
        }
        $global:LASTEXITCODE = 0
        Clear-OpenAiProcessEnvironment
        Remove-ProcessEnvironmentVariable -Name 'CODEX_HOME'
        if ($launchMode -eq 'direct') {
            $env:CODEX_HOME = [string]$materializedSnapshot.codexHome
            Clear-ProcessEnvironment -Names @('PRODEX_CODEX_BIN', 'PRODEX_HOME')
            if ($explicitSandboxRequested -or $bypassRequested) {
                & $focusFixedCodexBin @launchArguments
            } else {
                & $focusFixedCodexBin --dangerously-bypass-approvals-and-sandbox @launchArguments
            }
        } else {
            $prodexLauncher = Get-ProdexLauncher
            $env:PRODEX_HOME = [string]$materializedSnapshot.prodexHome
            $previousErrorActionPreference = $ErrorActionPreference
            try {
                # Prodex emits update notices on stderr; the run outcome is governed by its exit code.
                $ErrorActionPreference = 'Continue'
                $prodexArguments = @('run', '--profile', [string]$materializedSnapshot.profileName, '--no-auto-rotate')
                if (-not $explicitSandboxRequested -and -not $bypassRequested) {
                    $prodexArguments += '--full-access'
                }
                $prodexArguments += $launchArguments
                & $prodexLauncher @prodexArguments
            } finally {
                $ErrorActionPreference = $previousErrorActionPreference
            }
        }
        $exitOrder = [DateTime]::UtcNow.Ticks
        $lastExitCode = Get-LastExitCode
        $codexExitCode = if ($null -eq $lastExitCode) { 0 } else { [int]$lastExitCode }
        $launchOutcomeHandled = $true
    }
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
    Stop-RunModelWatcher -Watcher $runModelWatcher
    Restore-ProcessEnvironment -Snapshot $launchEnvironment
    if ($null -ne $materializedSnapshot) {
        if ($exitOrder -le 0) {
            $exitOrder = [DateTime]::UtcNow.Ticks
        }
        if ([string]::IsNullOrWhiteSpace([string]$persistenceRoot)) {
            $persistenceRoot = Get-SnapshotCcSwitchRoot `
                -Snapshot $materializedSnapshot -FallbackRoot $ActiveCcSwitchRoot
        }
        if ([string]::IsNullOrWhiteSpace([string]$persistenceRoot)) {
            Write-PersistenceFailure -RunHome ([string]$materializedSnapshot.codexHome) `
                -Source 'final' -Reason 'provider data root is missing or invalid' `
                -ErrorCode 'invalid_provider_root'
        } else {
            $stateFile = Get-RunModelStatePath -RunHome ([string]$materializedSnapshot.codexHome)
            $pendingFields = @(Get-PendingChangedFields -StateFile $stateFile)
            $persistenceArguments = @{
                RunHome = [string]$materializedSnapshot.codexHome
                ExitOrder = $exitOrder
                CcSwitchRoot = $persistenceRoot
                Source = 'final'
            }
            if ($pendingFields.Count -gt 0) {
                $persistenceArguments.ChangedFields = [string[]]$pendingFields
            }
            $persistenceSucceeded = Invoke-RunModelPersistence @persistenceArguments
            if ($persistenceSucceeded) {
                Remove-Item -LiteralPath $stateFile -Force -ErrorAction SilentlyContinue
            }
        }
    }
    Disable-CodexFocusReporting
    if (-not $launchOutcomeHandled) {
        # PipelineStoppedException bypasses catch blocks in some hosts, but finally still runs.
        exit 130
    }
}

exit $codexExitCode
