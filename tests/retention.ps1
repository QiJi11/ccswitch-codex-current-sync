[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'scripts\invoke-run-home-retention.ps1'
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) "ccswitch-retention-$PID-$([guid]::NewGuid().ToString('N'))"
$runRoot = Join-Path $fixtureRoot 'ccswitch-runs'
$outsideRoot = Join-Path $fixtureRoot 'outside'
$activeProcess = $null
$failures = [System.Collections.Generic.List[string]]::new()

function Assert-True {
    param([bool]$Condition, [string]$Because)
    if (-not $Condition) { throw "Assertion failed: $Because" }
}

function Set-FixtureAge {
    param([string]$Path, [int]$AgeDays)

    $stamp = [datetime]::UtcNow.AddDays(-$AgeDays)
    Get-ChildItem -LiteralPath $Path -Recurse -Force | ForEach-Object { $_.LastWriteTimeUtc = $stamp }
    (Get-Item -LiteralPath $Path).LastWriteTimeUtc = $stamp
}

function New-FixtureRunHome {
    param([string]$Name, [int]$AgeDays, [switch]$WithSession, [string]$Root = $runRoot)
    $path = Join-Path $Root $Name
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    'fixture' | Set-Content -LiteralPath (Join-Path $path 'config.toml') -Encoding utf8
    @{ profileName = "profile-$Name" } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $path 'run-provider.json') -Encoding utf8
    if ($WithSession) {
        $sessions = Join-Path $path 'sessions\2026\01\01'
        New-Item -ItemType Directory -Path $sessions -Force | Out-Null
        '{}' | Set-Content -LiteralPath (Join-Path $sessions 'rollout-fixture.jsonl') -Encoding utf8
    }
    Set-FixtureAge -Path $path -AgeDays $AgeDays
    return $path
}

function Add-FixtureFile {
    param([string]$RunHome, [string]$RelativePath, [int]$AgeDays)

    $filePath = Join-Path $RunHome $RelativePath
    New-Item -ItemType Directory -Path (Split-Path -Parent $filePath) -Force | Out-Null
    '{}' | Set-Content -LiteralPath $filePath -Encoding utf8
    Set-FixtureAge -Path $RunHome -AgeDays $AgeDays
}

function Get-ResultItem {
    param([object]$Result, [string]$Name)
    $matches = @($Result.items | Where-Object { $_.name -eq $Name })
    if ($matches.Count -ne 1) {
        throw "Expected one result item named '$Name', found $($matches.Count)."
    }
    return $matches[0]
}

try {
    New-Item -ItemType Directory -Path $runRoot, $outsideRoot -Force | Out-Null
    $eligible = New-FixtureRunHome -Name 'ccswitch-run-old-empty' -AgeDays 45
    $recent = New-FixtureRunHome -Name 'ccswitch-run-recent' -AgeDays 2
    $session = New-FixtureRunHome -Name 'ccswitch-run-old-session' -AgeDays 45 -WithSession
    $otherSession = New-FixtureRunHome -Name 'ccswitch-run-old-other-session' -AgeDays 45
    Add-FixtureFile -RunHome $otherSession -RelativePath 'sessions\fixture\session-metadata.json' -AgeDays 45
    $history = New-FixtureRunHome -Name 'ccswitch-run-old-history' -AgeDays 45
    Add-FixtureFile -RunHome $history -RelativePath 'history.jsonl' -AgeDays 45
    $stateDatabase = New-FixtureRunHome -Name 'ccswitch-run-old-state' -AgeDays 45
    Add-FixtureFile -RunHome $stateDatabase -RelativePath 'state_1.sqlite' -AgeDays 45
    $active = New-FixtureRunHome -Name 'ccswitch-run-old-active' -AgeDays 45
    $holdScript = Join-Path $active 'hold.ps1'
    'Start-Sleep -Seconds 60' | Set-Content -LiteralPath $holdScript -Encoding utf8
    $oldStamp = [datetime]::UtcNow.AddDays(-45)
    (Get-Item -LiteralPath $holdScript).LastWriteTimeUtc = $oldStamp
    (Get-Item -LiteralPath $active).LastWriteTimeUtc = $oldStamp
    New-FixtureRunHome -Name 'other-old-directory' -AgeDays 45 | Out-Null
    $nestedParent = New-FixtureRunHome -Name 'ccswitch-run-nested-parent' -AgeDays 2
    New-Item -ItemType Directory -Path (Join-Path $nestedParent 'ccswitch-run-old-nested') -Force | Out-Null
    $nestedReparse = New-FixtureRunHome -Name 'ccswitch-run-old-nested-reparse' -AgeDays 45
    $nestedReparseTarget = Join-Path $outsideRoot 'nested-reparse-target'
    New-Item -ItemType Directory -Path $nestedReparseTarget -Force | Out-Null
    New-Item -ItemType Junction -Path (Join-Path $nestedReparse 'linked-content') -Target $nestedReparseTarget | Out-Null
    $escapeTarget = New-FixtureRunHome -Name 'outside-target' -AgeDays 45
    Move-Item -LiteralPath $escapeTarget -Destination $outsideRoot
    New-Item -ItemType Junction -Path (Join-Path $runRoot 'ccswitch-run-escape') -Target (Join-Path $outsideRoot 'outside-target') | Out-Null

    $rootLinkTarget = Join-Path $outsideRoot 'root-link-target'
    New-Item -ItemType Directory -Path $rootLinkTarget -Force | Out-Null
    $rootLinkCandidate = New-FixtureRunHome -Name 'ccswitch-run-root-link-target' -AgeDays 45 -Root $rootLinkTarget
    $rootJunction = Join-Path $fixtureRoot 'ccswitch-runs-link'
    New-Item -ItemType Junction -Path $rootJunction -Target $rootLinkTarget | Out-Null

    $ancestorTarget = Join-Path $outsideRoot 'ancestor-target'
    $ancestorRunRoot = Join-Path $ancestorTarget 'ccswitch-runs'
    New-Item -ItemType Directory -Path $ancestorRunRoot -Force | Out-Null
    $ancestorLinkCandidate = New-FixtureRunHome -Name 'ccswitch-run-ancestor-link-target' -AgeDays 45 -Root $ancestorRunRoot
    $ancestorJunction = Join-Path $fixtureRoot 'ancestor-link'
    New-Item -ItemType Junction -Path $ancestorJunction -Target $ancestorTarget | Out-Null
    $linkedAncestorRunRoot = Join-Path $ancestorJunction 'ccswitch-runs'

    $pwsh = (Get-Command pwsh -ErrorAction Stop).Source
    $activeProcess = Start-Process -FilePath $pwsh -ArgumentList @('-NoProfile', '-File', $holdScript) -PassThru -WindowStyle Hidden
    Start-Sleep -Milliseconds 500

    $rootError = $null
    try {
        $null = & $scriptPath -RunHomesRoot ([IO.Path]::GetPathRoot($fixtureRoot)) -Json 2>&1
    }
    catch {
        $rootError = $_
    }
    Assert-True ($null -ne $rootError -and [string]$rootError -like '*filesystem root*') `
        'a filesystem root must be rejected before enumeration'

    $rootJunctionError = $null
    try {
        $null = & $scriptPath -RunHomesRoot $rootJunction -Apply -Confirm:$false -Json 2>&1
    }
    catch {
        $rootJunctionError = $_
    }
    Assert-True ($null -ne $rootJunctionError -and [string]$rootJunctionError -like '*reparse point*') `
        'a reparse-point run homes root must be rejected'
    Assert-True (Test-Path -LiteralPath $rootLinkCandidate) 'a rejected root junction must not delete its target'

    $ancestorJunctionError = $null
    try {
        $null = & $scriptPath -RunHomesRoot $linkedAncestorRunRoot -Apply -Confirm:$false -Json 2>&1
    }
    catch {
        $ancestorJunctionError = $_
    }
    Assert-True ($null -ne $ancestorJunctionError -and [string]$ancestorJunctionError -like '*reparse point*') `
        'a reparse point in the run homes root ancestry must be rejected'
    Assert-True (Test-Path -LiteralPath $ancestorLinkCandidate) 'a rejected ancestor junction must not delete its target'

    foreach ($swapScanNumber in @(2, 3)) {
        $swapContainer = Join-Path $fixtureRoot "swap-container-$swapScanNumber"
        $swapRunRoot = Join-Path $swapContainer 'ccswitch-runs'
        $swapOutsideRoot = Join-Path $outsideRoot "swap-target-$swapScanNumber"
        New-Item -ItemType Directory -Path $swapRunRoot, $swapOutsideRoot -Force | Out-Null
        $swapCandidate = New-FixtureRunHome -Name 'ccswitch-run-swap-target' -AgeDays 45 -Root $swapRunRoot
        $outsideSwapCandidate = New-FixtureRunHome -Name 'ccswitch-run-swap-target' -AgeDays 45 -Root $swapOutsideRoot
        $swapBackup = Join-Path $swapContainer 'ccswitch-runs-original'
        $scanCounter = [ref]0
        $swapError = & {
            function Get-CimInstance {
                [CmdletBinding()]
                param([Parameter(Position = 0)][string]$ClassName)
                $scanCounter.Value += 1
                if ($scanCounter.Value -eq $swapScanNumber) {
                    Move-Item -LiteralPath $swapRunRoot -Destination $swapBackup
                    New-Item -ItemType Junction -Path $swapRunRoot -Target $swapOutsideRoot | Out-Null
                }
                CimCmdlets\Get-CimInstance @PSBoundParameters
            }
            try {
                $null = & $scriptPath -RunHomesRoot $swapRunRoot -MinimumAgeDays 30 -Apply -Confirm:$false -Json
                return $null
            }
            catch { return $_ }
        }
        Assert-True ($null -ne $swapError -and [string]$swapError -like '*reparse point*') `
            "a root swapped to a junction during scan $swapScanNumber must abort before deletion"
        Assert-True (Test-Path -LiteralPath $outsideSwapCandidate) `
            "a scan-$swapScanNumber root-swap target must not be deleted"
        Assert-True (Test-Path -LiteralPath (Join-Path $swapBackup (Split-Path -Leaf $swapCandidate))) `
            "the originally scanned candidate must remain after scan-$swapScanNumber root swap"
    }

    foreach ($candidateSwapKind in @('junction', 'normal')) {
        $candidateSwapRoot = Join-Path $fixtureRoot "candidate-swap-$candidateSwapKind"
        $candidateSwapOutsideRoot = Join-Path $outsideRoot "candidate-swap-$candidateSwapKind"
        New-Item -ItemType Directory -Path $candidateSwapRoot, $candidateSwapOutsideRoot -Force | Out-Null
        $originalCandidate = New-FixtureRunHome -Name 'ccswitch-run-candidate-swap' -AgeDays 45 -Root $candidateSwapRoot
        $replacementCandidate = New-FixtureRunHome -Name 'ccswitch-run-candidate-swap' -AgeDays 45 -Root $candidateSwapOutsideRoot
        $candidateSwapBackup = Join-Path $candidateSwapRoot 'original-candidate'
        $candidateScanCounter = [ref]0
        $candidateSwapError = & {
            function Get-CimInstance {
                [CmdletBinding()]
                param([Parameter(Position = 0)][string]$ClassName)
                $candidateScanCounter.Value += 1
                if ($candidateScanCounter.Value -eq 3) {
                    Move-Item -LiteralPath $originalCandidate -Destination $candidateSwapBackup
                    if ($candidateSwapKind -eq 'junction') {
                        New-Item -ItemType Junction -Path $originalCandidate -Target $replacementCandidate | Out-Null
                    }
                    else {
                        Move-Item -LiteralPath $replacementCandidate -Destination $originalCandidate
                    }
                }
                CimCmdlets\Get-CimInstance @PSBoundParameters
            }
            try {
                $null = & $scriptPath -RunHomesRoot $candidateSwapRoot -MinimumAgeDays 30 -Apply -Confirm:$false -Json
                return $null
            }
            catch { return $_ }
        }
        $expectedSwapError = if ($candidateSwapKind -eq 'junction') { '*reparse point*' } else { '*identity changed*' }
        Assert-True ($null -ne $candidateSwapError -and [string]$candidateSwapError -like $expectedSwapError) `
            "a scan-3 $candidateSwapKind candidate swap must abort before deletion"
        Assert-True (Test-Path -LiteralPath $originalCandidate) `
            "the $candidateSwapKind replacement must not be deleted"
        Assert-True (Test-Path -LiteralPath $candidateSwapBackup) `
            "the originally scanned candidate must remain after a $candidateSwapKind swap"
        if ($candidateSwapKind -eq 'junction') {
            Assert-True (Test-Path -LiteralPath $replacementCandidate) 'the junction target must remain after candidate swap'
        }
    }

    $processScanError = & {
        function Get-CimInstance {
            [CmdletBinding()]
            param([Parameter(Position = 0)][string]$ClassName)
            throw 'fixture process scan failure'
        }
        try {
            $null = & $scriptPath -RunHomesRoot $runRoot -MinimumAgeDays 30 -Json
            return $null
        }
        catch { return $_ }
    }
    Assert-True ($null -ne $processScanError -and [string]$processScanError -like '*fixture process scan failure*') `
        'a failed process scan must abort retention'
    Assert-True (Test-Path -LiteralPath $eligible) 'a failed process scan must not delete an eligible fixture'

    $fileScanError = & {
        function Get-ChildItem {
            [CmdletBinding()]
            param(
                [string[]]$LiteralPath,
                [switch]$Recurse,
                [switch]$Force,
                [switch]$Directory,
                [switch]$File,
                [string]$Filter
            )
            if ($Recurse -and $LiteralPath.Count -eq 1 -and $LiteralPath[0] -eq $eligible) {
                throw 'fixture file scan failure'
            }
            Microsoft.PowerShell.Management\Get-ChildItem @PSBoundParameters
        }
        try {
            $null = & $scriptPath -RunHomesRoot $runRoot -MinimumAgeDays 30 -Json
            return $null
        }
        catch { return $_ }
    }
    Assert-True ($null -ne $fileScanError -and [string]$fileScanError -like '*fixture file scan failure*') `
        'a failed descendant scan must abort retention'
    Assert-True (Test-Path -LiteralPath $eligible) 'a failed descendant scan must not delete an eligible fixture'

    $preview = (& $scriptPath -RunHomesRoot $runRoot -MinimumAgeDays 30 -Json) | ConvertFrom-Json
    Assert-True ($preview.mode -eq 'preview' -and $preview.deletedCount -eq 0) 'default mode must be preview and delete nothing'
    Assert-True ((Get-ResultItem $preview 'ccswitch-run-old-empty').eligible) 'old empty direct run home must be eligible'
    Assert-True ((Get-ResultItem $preview 'ccswitch-run-recent').reasons -contains 'recent') 'recent run home must be kept'
    Assert-True ((Get-ResultItem $preview 'ccswitch-run-old-session').reasons -contains 'rollout_session') 'run home with rollout session must be kept'
    Assert-True ((Get-ResultItem $preview 'ccswitch-run-old-other-session').reasons -contains 'session_data') 'all session data must be kept'
    Assert-True ((Get-ResultItem $preview 'ccswitch-run-old-history').reasons -contains 'history_data') 'history.jsonl must be kept'
    Assert-True ((Get-ResultItem $preview 'ccswitch-run-old-state').reasons -contains 'state_database') 'state databases must be kept'
    Assert-True ((Get-ResultItem $preview 'ccswitch-run-old-active').reasons -contains 'active_process') 'active process reference must be kept'
    Assert-True ((Get-ResultItem $preview 'ccswitch-run-escape').reasons -contains 'reparse_point') 'junction must never be eligible'
    Assert-True ((Get-ResultItem $preview 'ccswitch-run-old-nested-reparse').reasons -contains 'nested_reparse_point') 'a run home containing a junction must be kept'
    Assert-True (@($preview.items | Where-Object name -eq 'other-old-directory').Count -eq 0) 'non-run directory must not be a candidate'
    Assert-True (Test-Path -LiteralPath $eligible) 'preview must not delete eligible fixture'

    $apply = (& $scriptPath -RunHomesRoot $runRoot -MinimumAgeDays 30 -Apply -Confirm:$false -Json) | ConvertFrom-Json
    Assert-True ($apply.deletedCount -eq 1) 'apply must delete only the single eligible fixture'
    Assert-True (-not (Test-Path -LiteralPath $eligible)) 'eligible fixture must be deleted in apply mode'
    Assert-True (Test-Path -LiteralPath $recent) 'recent fixture must remain'
    Assert-True (Test-Path -LiteralPath $session) 'session fixture must remain'
    Assert-True (Test-Path -LiteralPath $otherSession) 'non-rollout session fixture must remain'
    Assert-True (Test-Path -LiteralPath $history) 'history fixture must remain'
    Assert-True (Test-Path -LiteralPath $stateDatabase) 'state database fixture must remain'
    Assert-True (Test-Path -LiteralPath $active) 'active fixture must remain'
    Assert-True (Test-Path -LiteralPath $nestedReparse) 'nested reparse fixture must remain'

    Write-Output '[PASS] retention preview/apply fixture matrix'
}
catch {
    $failures.Add([string]$_) | Out-Null
    Write-Error -ErrorRecord $_ -ErrorAction Continue
}
finally {
    if ($activeProcess -and -not $activeProcess.HasExited) {
        Stop-Process -Id $activeProcess.Id -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $fixtureRoot) {
        $resolved = [IO.Path]::GetFullPath($fixtureRoot)
        $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if ($resolved.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like 'ccswitch-retention-*') {
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }
}

if ($failures.Count -gt 0) {
    throw "Retention fixture failures: $($failures -join ' | ')"
}
