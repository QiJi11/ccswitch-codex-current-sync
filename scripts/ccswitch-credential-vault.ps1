Add-Type -AssemblyName System.Security -ErrorAction Stop

function Get-Sha256Hex {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return -join ($sha256.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') })
    } finally {
        $sha256.Dispose()
    }
}

function Get-CcSwitchCredentialPath {
    param(
        [Parameter(Mandatory = $true)][string]$VaultRoot,
        [Parameter(Mandatory = $true)][string]$ProviderId
    )

    if ([string]::IsNullOrWhiteSpace($ProviderId)) {
        throw 'ProviderId must not be empty.'
    }
    $providerBytes = [System.Text.Encoding]::UTF8.GetBytes($ProviderId)
    $fileName = "$(Get-Sha256Hex -Bytes $providerBytes).dpapi"
    $root = [System.IO.Path]::GetFullPath($VaultRoot)
    $path = [System.IO.Path]::GetFullPath((Join-Path $root $fileName))
    $prefix = $root.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if (-not $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Resolved credential path escapes the vault root.'
    }
    return $path
}

function Get-CcSwitchCredentialEntropy {
    param([Parameter(Mandatory = $true)][string]$ProviderId)

    $entropyText = "ccswitch-codex:$ProviderId"
    $entropyBytes = [System.Text.Encoding]::UTF8.GetBytes($entropyText)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return $sha256.ComputeHash($entropyBytes)
    } finally {
        $sha256.Dispose()
    }
}

function Get-AllowedCredentialSids {
    $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    return @($currentSid, 'S-1-5-18', 'S-1-5-32-544')
}

function Assert-CcSwitchCredentialOwnerSid {
    param(
        [Parameter(Mandatory = $true)][string]$OwnerSid,
        [Parameter(Mandatory = $true)][string[]]$AllowedSids
    )

    if ($AllowedSids -notcontains $OwnerSid) {
        throw "Credential ACL owner is not allowed: $OwnerSid"
    }
}

function Set-CcSwitchCredentialVaultAcl {
    param([Parameter(Mandatory = $true)][string]$VaultRoot)

    $root = [System.IO.Path]::GetFullPath($VaultRoot)
    [System.IO.Directory]::CreateDirectory($root) | Out-Null
    $rootEntry = Get-Item -LiteralPath $root -Force
    if (($rootEntry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Credential vault must not be a reparse point: $root"
    }
    $security = [System.Security.AccessControl.DirectorySecurity]::new()
    $security.SetAccessRuleProtection($true, $false)
    $security.SetOwner([System.Security.Principal.SecurityIdentifier]::new((Get-AllowedCredentialSids)[0]))
    foreach ($sidText in (Get-AllowedCredentialSids)) {
        $sid = [System.Security.Principal.SecurityIdentifier]::new($sidText)
        $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
            $sid,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Allow
        )
        $security.AddAccessRule($rule) | Out-Null
    }
    Set-Acl -LiteralPath $root -AclObject $security
}

function Assert-CcSwitchCredentialAcl {
    param(
        [Parameter(Mandatory = $true)][string]$VaultRoot,
        [Parameter(Mandatory = $true)][string]$CredentialPath
    )

    $allowed = @(Get-AllowedCredentialSids)
    foreach ($path in @($VaultRoot, $CredentialPath)) {
        if (-not (Test-Path -LiteralPath $path)) {
            throw "Credential ACL target does not exist: $path"
        }
        $entry = Get-Item -LiteralPath $path -Force
        if (($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Credential ACL target must not be a reparse point: $path"
        }
        $acl = Get-Acl -LiteralPath $path
        $ownerSid = $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
        Assert-CcSwitchCredentialOwnerSid -OwnerSid $ownerSid -AllowedSids $allowed
        if ($path -eq $VaultRoot -and -not $acl.AreAccessRulesProtected) {
            throw 'Credential vault must disable inherited ACL entries.'
        }
        $rules = $acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])
        foreach ($rule in $rules) {
            $sid = $rule.IdentityReference.Value
            if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow -or
                $allowed -notcontains $sid) {
                throw "Credential ACL contains a disallowed rule for SID $sid."
            }
        }
        $currentSid = $allowed[0]
        $currentRules = @($rules | Where-Object { $_.IdentityReference.Value -eq $currentSid })
        if ($currentRules.Count -eq 0) {
            throw 'Credential ACL does not grant access to the current user.'
        }
    }
}
