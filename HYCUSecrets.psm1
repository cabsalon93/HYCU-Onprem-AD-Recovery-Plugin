<#
================================================================================
 HYCU AD Recovery Tool - Connection profiles & secrets
 --------------------------------------------------------------------------------
 Persists HYCU connection profiles (URL, auth mode, secret) so credentials do not
 have to be retyped every session.

 SECURITY: secrets (Basic password, API token) are stored via Export-Clixml, which
 encrypts SecureString / PSCredential with DPAPI (a key tied to the current Windows
 user and machine). No secret is written in clear text on disk, and a profile file
 can only be decrypted by the same user on the same machine.
================================================================================
#>
#requires -Version 5.1

# Standalone logging: delegate to the engine's Write-HYCULog if present, else Write-*.
# (Private functions from another nested module are not visible here.)
function Write-HYCUProfileLog {
    param([Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$Message,
          [ValidateSet('INFO','WARN','ERROR','SUCCESS','DEBUG')][string]$Level = 'INFO')
    if (Get-Command -Name Write-HYCULog -ErrorAction SilentlyContinue) {
        Write-HYCULog -Message $Message -Level $Level
    } else {
        switch ($Level) {
            'ERROR'  { Write-Host $Message -ForegroundColor Red }
            'WARN'   { Write-Host $Message -ForegroundColor Yellow }
            'SUCCESS'{ Write-Host $Message -ForegroundColor Green }
            'DEBUG'  { Write-Verbose $Message }
            default  { Write-Host $Message }
        }
    }
}

function Get-HYCUADProfileDirectory {
    $dir = if (Get-Command Get-HYCUADConfig -ErrorAction SilentlyContinue) { (Get-HYCUADConfig).ProfileDirectory } else { $null }
    # Fall back to the per-user default if the engine returned an empty ProfileDirectory (else New-Item '' fails).
    if ([string]::IsNullOrWhiteSpace($dir)) { $dir = Join-Path $env:APPDATA 'HYCU\ADRecoveryTool\profiles' }
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return $dir
}

function Save-HYCUADProfile {
    <#
    .SYNOPSIS  Saves (DPAPI-encrypted) a HYCU connection profile.
    .EXAMPLE
      Save-HYCUADProfile -Name prod -Server hycu.corp.local -Credential (Get-Credential) `
                         -SkipCertCheck -TargetShare '\\nas\HYCU_Restore\DC01'
    .EXAMPLE
      $tok = Read-Host -AsSecureString 'API token'
      Save-HYCUADProfile -Name prod -Server hycu.corp.local -ApiToken $tok
    #>
    [CmdletBinding(DefaultParameterSetName='Basic')]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Server,
        [int]$Port = 8443,
        [string]$ApiVersion = 'v1.0',

        [Parameter(ParameterSetName='Basic')]
        [System.Management.Automation.PSCredential]$Credential,

        [Parameter(ParameterSetName='Token')]
        [System.Security.SecureString]$ApiToken,
        [Parameter(ParameterSetName='Token')][string]$TokenHeader = 'Authorization',
        [Parameter(ParameterSetName='Token')][string]$TokenScheme = 'Bearer',

        [switch]$SkipCertCheck,
        [string]$TargetShare,

        # Restore destination (SMB share HYCU writes the file-level restore to)
        [string]$RestoreTargetServer,
        [string]$RestoreTargetShare,
        [string]$RestoreTargetDomain,
        [string]$RestoreTargetUsername,
        [System.Security.SecureString]$RestoreTargetPassword
    )
    $authMode = if ($PSCmdlet.ParameterSetName -eq 'Token') { 'Token' } else { 'Basic' }
    if ($authMode -eq 'Basic' -and -not $Credential) { $Credential = Get-Credential -Message "HYCU credentials for '$Name'" }
    if ($authMode -eq 'Token' -and -not $ApiToken)   { $ApiToken   = Read-Host -AsSecureString "HYCU API token for '$Name'" }

    # Don't persist a profile with a missing secret (Get-Credential cancelled -> $null; empty Read-Host
    # -> a zero-length SecureString, which is non-null so a plain -not check would miss it).
    if ($authMode -eq 'Basic' -and -not $Credential) { throw "No credential provided; profile '$Name' was not saved." }
    if ($authMode -eq 'Token' -and ($null -eq $ApiToken -or $ApiToken.Length -eq 0)) { throw "No API token provided; profile '$Name' was not saved." }

    $prof = [pscustomobject]@{
        Name          = $Name
        Server        = $Server
        Port          = $Port
        ApiVersion    = $ApiVersion
        AuthMode      = $authMode
        SkipCertCheck = [bool]$SkipCertCheck
        TargetShare   = $TargetShare
        TokenHeader   = $TokenHeader
        TokenScheme   = $TokenScheme
        Credential    = $Credential          # DPAPI-encrypted by Export-Clixml
        ApiToken      = $ApiToken             # DPAPI-encrypted by Export-Clixml
        RestoreTargetServer   = $RestoreTargetServer
        RestoreTargetShare    = $RestoreTargetShare
        RestoreTargetDomain   = $RestoreTargetDomain
        RestoreTargetUsername = $RestoreTargetUsername
        RestoreTargetPassword = $RestoreTargetPassword   # DPAPI-encrypted by Export-Clixml
    }
    $file = Join-Path (Get-HYCUADProfileDirectory) ("{0}.xml" -f ($Name -replace '[\\/:*?"<>|]','_'))
    $prof | Export-Clixml -Path $file -Force
    Write-HYCUProfileLog "HYCU profile '$Name' saved (secret DPAPI-encrypted): $file" 'SUCCESS'
    return $file
}

function Get-HYCUADProfile {
    <#
    .SYNOPSIS  Reads a HYCU profile (or lists them all), and can open the connection.
    .EXAMPLE   Get-HYCUADProfile                       # lists the names
    .EXAMPLE   $h = Get-HYCUADProfile -Name prod -Connect
    #>
    [CmdletBinding()]
    param(
        [string]$Name,
        [switch]$Connect
    )
    $dir = Get-HYCUADProfileDirectory
    if (-not $Name) {
        # Per-file try/catch so one corrupt/partial/non-profile .xml does not abort the whole listing;
        # drop nameless/null entries.
        return @(Get-ChildItem -Path $dir -Filter '*.xml' -File -ErrorAction SilentlyContinue |
                 ForEach-Object {
                     try { ($_ | Import-Clixml).Name }
                     catch { Write-HYCUProfileLog "Skipping unreadable profile file: $($_.FullName) - $($_.Exception.Message)" 'WARN'; $null }
                 } | Where-Object { $_ })
    }
    $file = Join-Path $dir ("{0}.xml" -f ($Name -replace '[\\/:*?"<>|]','_'))
    if (-not (Test-Path $file)) { throw "HYCU profile not found: $Name ($file)" }
    # A profile is DPAPI-encrypted for the user+machine that created it. If it was copied from another
    # user/machine (or is corrupt), Import-Clixml/decryption fails - surface a clear, actionable message.
    try { $prof = Import-Clixml -Path $file }
    catch { throw "HYCU profile '$Name' could not be read ($file): $($_.Exception.Message). If it was created by a different user or on a different machine, its DPAPI-encrypted secret cannot be decrypted here - recreate the profile on this account/machine." }

    if (-not $Connect) { return $prof }

    if (-not (Get-Command Connect-HYCUController -ErrorAction SilentlyContinue)) {
        throw "Connect-HYCUController unavailable (HYCUClient module not loaded)."
    }
    $p = @{
        Server     = $prof.Server
        Port       = $prof.Port
        ApiVersion = $prof.ApiVersion
    }
    if ($prof.SkipCertCheck) { $p['SkipCertificateCheck'] = $true }
    if ($prof.AuthMode -eq 'Token') {
        $p['AuthMode']    = 'Token'
        $p['ApiToken']    = $prof.ApiToken
        $p['TokenHeader'] = $prof.TokenHeader
        $p['TokenScheme'] = $prof.TokenScheme
    } else {
        $p['Credential'] = $prof.Credential
    }
    return Connect-HYCUController @p
}

function Remove-HYCUADProfile {
    <#
    .SYNOPSIS  Removes a saved HYCU profile.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='Medium')]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Name)
    $file = Join-Path (Get-HYCUADProfileDirectory) ("{0}.xml" -f ($Name -replace '[\\/:*?"<>|]','_'))
    if (-not (Test-Path $file)) { Write-HYCUProfileLog "Profile '$Name' does not exist." 'WARN'; return }
    if ($PSCmdlet.ShouldProcess($Name, "Remove HYCU profile")) {
        Remove-Item $file -Force
        Write-HYCUProfileLog "HYCU profile '$Name' removed." 'SUCCESS'
    }
}

Export-ModuleMember -Function Save-HYCUADProfile, Get-HYCUADProfile, Remove-HYCUADProfile
