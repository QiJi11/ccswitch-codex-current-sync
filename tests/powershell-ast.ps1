[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$repoRoot = Split-Path -Parent $PSScriptRoot
$paths = @(
    Get-ChildItem -LiteralPath (Join-Path $repoRoot 'scripts') -Recurse -File -Filter '*.ps1'
    Get-ChildItem -LiteralPath (Join-Path $repoRoot 'tests') -Recurse -File -Filter '*.ps1'
)
$failures = [System.Collections.Generic.List[string]]::new()
foreach ($path in $paths) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $path.FullName,
        [ref]$tokens,
        [ref]$errors
    ) | Out-Null
    foreach ($parseError in @($errors)) {
        $failures.Add("$($path.FullName): $parseError") | Out-Null
    }
}

if ($failures.Count -gt 0) {
    throw "PowerShell AST failures: $($failures -join ' | ')"
}
Write-Output "[PASS] PowerShell AST files=$($paths.Count)"
