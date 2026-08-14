function Get-CurrentPowerShellExecutable {
    $executableName = if ($PSVersionTable.PSEdition -eq 'Core') {
        'pwsh.exe'
    } else {
        'powershell.exe'
    }
    $executablePath = Join-Path $PSHOME $executableName
    if (-not (Test-Path -LiteralPath $executablePath -PathType Leaf)) {
        throw "Current PowerShell executable was not found: $executablePath"
    }
    return [System.IO.Path]::GetFullPath($executablePath)
}
