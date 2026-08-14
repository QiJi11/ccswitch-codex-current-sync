[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ProviderId,
    [string]$VaultRoot = (Join-Path $env:USERPROFILE '.prodex\credentials\ccswitch-codex')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ccswitch-credential-vault.ps1')

$vault = [System.IO.Path]::GetFullPath($VaultRoot)
$credentialPath = Get-CcSwitchCredentialPath -VaultRoot $vault -ProviderId $ProviderId
Assert-CcSwitchCredentialAcl -VaultRoot $vault -CredentialPath $credentialPath

$payload = [System.IO.File]::ReadAllBytes($credentialPath)
$header = [System.Text.Encoding]::ASCII.GetBytes("CCSWITCH-DPAPI-1`0")
if ($payload.Length -le $header.Length) {
    throw 'Credential file is empty or truncated.'
}
for ($index = 0; $index -lt $header.Length; $index += 1) {
    if ($payload[$index] -ne $header[$index]) {
        throw 'Credential file has an invalid header.'
    }
}

$encrypted = [byte[]]::new($payload.Length - $header.Length)
[System.Array]::Copy($payload, $header.Length, $encrypted, 0, $encrypted.Length)
$entropy = Get-CcSwitchCredentialEntropy -ProviderId $ProviderId
$plaintext = $null
try {
    $plaintext = [System.Security.Cryptography.ProtectedData]::Unprotect(
        $encrypted,
        $entropy,
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    $token = [System.Text.Encoding]::UTF8.GetString($plaintext)
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw 'Credential decrypts to an empty token.'
    }
    [Console]::Out.Write($token)
} finally {
    if ($null -ne $plaintext) {
        [System.Array]::Clear($plaintext, 0, $plaintext.Length)
    }
    [System.Array]::Clear($encrypted, 0, $encrypted.Length)
    [System.Array]::Clear($payload, 0, $payload.Length)
}
