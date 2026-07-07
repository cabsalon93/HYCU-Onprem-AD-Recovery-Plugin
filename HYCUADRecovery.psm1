<#
================================================================================
 HYCU AD Recovery Tool - PowerShell engine
 Granular Active Directory object recovery workflow on top of a HYCU backup of a
 domain controller.

 Pipeline:
   1. Acquisition  : retrieve the NTDS folder from a HYCU backup
                     (ntds.dit + edb*.log + edb.chk journals) and, optionally, SYSVOL.
   2. Preparation  : ESE "soft recovery" (esentutl) to make the database mountable
                     even if the backup is crash-consistent (dirty shutdown).
   3. Mount        : dsamain.exe exposes the offline database as an LDAP server.
   4. Comparison   : LDAP diff between the snapshot and production AD
                     (deleted objects + modified attributes + memberships).
   5. Restore      : AD Recycle Bin -> else recreation -> attributes -> backlinks,
                     or LDIF export (re-import via ldifde), + SYSVOL/GPO restore.
   6. Safety       : -WhatIf everywhere, LDIF "undo" backup of the live state before
                     any write, full logging.

 DISCLAIMER
   Independent tool, NOT affiliated with HYCU or Microsoft, and NOT supported by
   those vendors. Active Directory is a sensitive database: test in a lab /
   outside production first. You remain responsible for any data loss.
================================================================================
#>

#requires -Version 5.1

# ----------------------------------------------------------------------------
# Global configuration (editable via Set-HYCUADConfig)
# ----------------------------------------------------------------------------
# Base folder for staging: the program's own folder when known. $PSScriptRoot is EMPTY when the tool is
# compiled to a single self-contained .exe (module code inlined), so fall back to a per-user writable
# location instead of letting Join-Path throw on an empty base.
$__hycuBase = if ($PSScriptRoot) { $PSScriptRoot } elseif ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { $env:TEMP }
$script:HYCUADConfig = [ordered]@{
    LdapPort        = 41389                                   # Local LDAP port for dsamain (first port tried; shifts up if busy)
    LogDirectory    = (Join-Path $env:APPDATA 'HYCU\ADRecoveryTool\logs')
    # Staging (the local working copy of ntds.dit) lives next to the program, under its own folder.
    StagingRoot     = (Join-Path $__hycuBase 'HYCU\ADRecoveryTool\staging')
    StagingKeepLast = 3                                       # Auto-clean: number of most recent staging folders to keep
    StagingMaxAgeDays = 0                                     # Auto-clean: also drop folders older than N days (0 = age ignored, count rule only)
    StagingAutoClean= $true                                  # Prune old staging folders when a new restore creates one
    ProfileDirectory= (Join-Path $env:APPDATA 'HYCU\ADRecoveryTool\profiles')
    DsamainPath     = "$env:SystemRoot\System32\dsamain.exe"
    EsentutlPath    = "$env:SystemRoot\System32\esentutl.exe"
    LdifdePath      = "$env:SystemRoot\System32\ldifde.exe"
    AutoHardRepair  = $true                                   # auto last-resort esentutl /p when soft+lossy recovery fail (offline copy only; safe for read-only mount)
    EsentutlRepairTimeoutSeconds = 180                        # hard cap (s) on a single esentutl /p run so a stuck confirmation prompt can never hang the tool (the real repair takes seconds)
    DescriptionRestoreMode = 'Append'                         # restoring 'description' on a modified object: 'Append' = keep the live value and add the backup value (never lose live notes); 'Replace' = overwrite with the backup value
    RestoreSidHistory = $true                                 # on RECREATION of a fully-deleted object, best-effort set the OLD objectSid as sIDHistory on the new object so access granted to the old SID follows it. Needs elevated rights; AD often blocks adding a SAME-DOMAIN SID as history (by design), so failure is logged and non-fatal.
    AllowNonAdmin   = $false                                  # /allowNonAdminAccess on dsamain
    DsamainResidueScope = 'All'                               # residue cleanup: 'All' = stop EVERY leftover dsamain.exe (it is only ever this tool, never a live DC) so the default port is reused; 'Matched' = only ones tied to our port/staging (use if you run a second, unrelated dsamain mount concurrently)
    # --- HYCU integration (REST client, see HYCUClient.psm1) --------------------
    HycuServer        = ''                                    # HYCU controller FQDN/IP
    HycuPort          = 8443                                  # Default REST port
    HycuApiVersion    = 'v1.0'                                # /rest/<version>/
    HycuAuthMode      = 'Basic'                               # 'Basic' or 'Token'
    HycuTokenHeader   = 'Authorization'                       # Header for Token mode
    HycuTokenScheme   = 'Bearer'                              # Token prefix (empty = raw)
    HycuSkipCertCheck = $true                                 # Accept self-signed certificates (the norm for HYCU controllers)
    HycuTransport     = 'Auto'                                # HTTP transport: 'Auto' (curl.exe if present), 'Curl', 'DotNet'
    HycuTargetShare   = ''                                    # Share where HYCU drops the file-level restore
    ShareCleanup      = $true                                 # Delete the NTDS/SYSVOL files HYCU restored to the target share once copied locally
    # REST call template for the file-level restore (-UseApiRestore mode, best-effort).
    # Empty by default: until it is set, the share handoff is used.
    HycuRestoreFilesUriTemplate = ''                          # e.g. '{base}/vms/{vmUuid}/restorePoints/{rpUuid}/restore:files'
    # Attributes never rewritten on recreation (system / operational / links handled separately)
    ProtectedAttributes = @(
        'objectGUID','objectSid','objectCategory','distinguishedName','name','cn',
        'whenCreated','whenChanged','uSNCreated','uSNChanged','instanceType',
        'pwdLastSet','lastLogon','lastLogonTimestamp','lastLogoff','badPasswordTime',
        'badPwdCount','logonCount','dSCorePropagationData','replPropertyMetaData',
        'canonicalName','allowedAttributes','allowedAttributesEffective',
        'sDRightsEffective','msDS-User-Account-Control-Computed','primaryGroupToken',
        'memberOf','member','isCriticalSystemObject','systemFlags','nTSecurityDescriptor',
        'objectClass','structuralObjectClass',
        'sAMAccountType','sIDHistory',   # SAM-owned: New-AD* rejects them ("owned by the Security Accounts
                                         # Manager"). sIDHistory is set separately AFTER creation (RestoreSidHistory).
        'adspath'   # ADSI-injected constructed property (not a real writable attribute); leaking it into
                    # New-AD* -OtherAttributes fails with "attribute or value does not exist (adspath)"
    )
}

function Set-HYCUADConfig {
    <#
    .SYNOPSIS  Updates the tool's global configuration.
    .EXAMPLE   Set-HYCUADConfig -LdapPort 60000 -AllowNonAdmin $true
    .EXAMPLE   Set-HYCUADConfig -HycuServer 'hycu.corp.local' -HycuSkipCertCheck $true -HycuTargetShare '\\nas\HYCU_Restore'
    #>
    [CmdletBinding()]
    param(
        [int]$LdapPort,
        [string]$LogDirectory,
        [string]$StagingRoot,
        [int]$StagingKeepLast,
        [int]$StagingMaxAgeDays,
        [bool]$StagingAutoClean,
        [bool]$AutoHardRepair,
        [int]$EsentutlRepairTimeoutSeconds,
        [ValidateSet('Append','Replace')][string]$DescriptionRestoreMode,
        [bool]$RestoreSidHistory,
        [string]$ProfileDirectory,
        [bool]$AllowNonAdmin,
        [ValidateSet('All','Matched')][string]$DsamainResidueScope,
        [string]$HycuServer,
        [int]$HycuPort,
        [string]$HycuApiVersion,
        [ValidateSet('Basic','Token')][string]$HycuAuthMode,
        [string]$HycuTokenHeader,
        [string]$HycuTokenScheme,
        [bool]$HycuSkipCertCheck,
        [ValidateSet('Auto','Curl','DotNet')][string]$HycuTransport,
        [string]$HycuTargetShare,
        [bool]$ShareCleanup,
        [string]$HycuRestoreFilesUriTemplate
    )
    foreach ($k in 'LdapPort','LogDirectory','StagingRoot','StagingKeepLast','StagingMaxAgeDays','StagingAutoClean','AutoHardRepair',
                   'EsentutlRepairTimeoutSeconds','DescriptionRestoreMode','RestoreSidHistory','ProfileDirectory','AllowNonAdmin','DsamainResidueScope',
                   'HycuServer','HycuPort','HycuApiVersion','HycuAuthMode','HycuTokenHeader',
                   'HycuTokenScheme','HycuSkipCertCheck','HycuTransport','HycuTargetShare','ShareCleanup','HycuRestoreFilesUriTemplate') {
        if ($PSBoundParameters.ContainsKey($k)) { $script:HYCUADConfig[$k] = $PSBoundParameters[$k] }
    }
    $script:HYCUADConfig
}

function Get-HYCUADConfig { $script:HYCUADConfig }

# ----------------------------------------------------------------------------
# Logging
# ----------------------------------------------------------------------------
function Set-HYCULogSink {
    <#
    .SYNOPSIS
      Registers a callback that Write-HYCULog forwards each (message, level) to (e.g. so the GUI can
      surface engine progress live). Pass $null to unregister. The sink runs in the caller's runspace.
    #>
    param([scriptblock]$Sink)
    $script:HYCULogSink = $Sink
}

function Write-HYCULog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','SUCCESS','DEBUG')][string]$Level = 'INFO'
    )
    if ($null -eq $Message) { $Message = '' }
    $dir = $script:HYCUADConfig.LogDirectory
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $logFile = Join-Path $dir ("ADRecovery_{0:yyyyMMdd}.log" -f (Get-Date))
    $line = "{0:yyyy-MM-dd HH:mm:ss}  [{1,-7}]  {2}" -f (Get-Date), $Level, $Message
    Add-Content -Path $logFile -Value $line -Encoding UTF8

    $color = switch ($Level) {
        'ERROR'   { 'Red' }    'WARN'    { 'Yellow' }
        'SUCCESS' { 'Green' }  'DEBUG'   { 'DarkGray' } default { 'Gray' }
    }
    Write-Host $line -ForegroundColor $color

    # Forward to a registered sink (the GUI uses this to show engine progress live). Best-effort.
    if ($script:HYCULogSink) { try { & $script:HYCULogSink $Message $Level } catch {} }
}

# ----------------------------------------------------------------------------
# Prerequisite checks
# ----------------------------------------------------------------------------
function Test-HYCUADPrerequisite {
    <#
    .SYNOPSIS  Checks elevation, native Microsoft tools and the ActiveDirectory module.
    .OUTPUTS   [bool] $true if everything is OK.
    #>
    [CmdletBinding()]
    param([switch]$RequireLiveAD)
    $ok = $true

    # Elevation
    $isAdmin = ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
    if (-not $isAdmin) { Write-HYCULog "The console must be launched as administrator." 'ERROR'; $ok = $false }

    # Native tools. dsamain.exe is server-only, so its remediation differs on a client SKU.
    $isServer = $false
    try { $isServer = ((Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).ProductType -ne 1) } catch {}
    foreach ($tool in 'DsamainPath','EsentutlPath','LdifdePath') {
        $p = $script:HYCUADConfig[$tool]
        if (-not (Test-Path $p)) {
            $name = Split-Path $p -Leaf
            if ($name -eq 'dsamain.exe' -and -not $isServer) {
                Write-HYCULog ("$name not found. It is a Windows Server tool (AD DS / AD LDS role) and is " +
                    "NOT available on Windows client editions - run the mount/compare/restore steps on a " +
                    "Windows Server or a domain controller.") 'ERROR'
            } elseif ($name -eq 'dsamain.exe') {
                Write-HYCULog "$name not found. Install the AD DS tools: Install-WindowsFeature RSAT-AD-Tools." 'ERROR'
            } else {
                Write-HYCULog "$name not found. Install the AD DS tools (RSAT)." 'ERROR'
            }
            $ok = $false
        }
    }

    # ActiveDirectory module (used for production writes: Recycle Bin, Set-AD..., groups)
    if ($RequireLiveAD) {
        if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
            Write-HYCULog "ActiveDirectory PowerShell module missing (RSAT-AD-PowerShell)." 'WARN'
        } else {
            Import-Module ActiveDirectory -ErrorAction SilentlyContinue
        }
    }
    if ($ok) { Write-HYCULog "Prerequisites validated." 'SUCCESS' }
    return $ok
}

function Get-HYCUADPrerequisite {
    <#
    .SYNOPSIS
      Silent prerequisite check (no logging): native tools, ActiveDirectory module, elevation.
    .OUTPUTS
      An object { Ok, IsAdmin, IsServerOS, Dsamain, Esentutl, Ldifde, AdModule, Missing[],
                  InstallCommand, DsamainRequiresServer, Guidance }.
    .NOTES
      dsamain.exe ships ONLY with the Windows Server AD DS / AD LDS role. Installing RSAT on a
      Windows *client* (Win10/11) provides ldifde + the AD module but NEVER dsamain.exe, so on a
      client the install command is suppressed for dsamain and Guidance points the operator to a
      Windows Server / domain controller instead.
    #>
    [CmdletBinding()]
    param()
    $cfg = $script:HYCUADConfig
    $dsamain  = Test-Path $cfg.DsamainPath
    $esentutl = Test-Path $cfg.EsentutlPath
    $ldifde   = Test-Path $cfg.LdifdePath
    $adModule = [bool](Get-Module -ListAvailable -Name ActiveDirectory -ErrorAction SilentlyContinue)
    $isAdmin  = ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)

    # ProductType: 1 = Workstation/client, 2 = Domain Controller, 3 = Server. dsamain is only
    # available on 2/3 (server SKUs); a client SKU cannot provide it through any RSAT package.
    $isServer = $false
    try { $isServer = ((Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).ProductType -ne 1) } catch {}

    $missing = New-Object System.Collections.Generic.List[string]
    if (-not $dsamain)  { $missing.Add('dsamain.exe (AD DS Database Mounting Tool)') }
    if (-not $esentutl) { $missing.Add('esentutl.exe') }
    if (-not $ldifde)   { $missing.Add('ldifde.exe') }
    if (-not $adModule) { $missing.Add('ActiveDirectory PowerShell module (RSAT-AD-PowerShell)') }

    # Which missing items can actually be installed ON THIS machine via RSAT? ldifde + the AD
    # module always; dsamain ONLY on a server SKU. esentutl is a built-in OS file (not RSAT).
    $rsatInstallable = @()
    if ((-not $dsamain) -and $isServer) { $rsatInstallable += 'dsamain' }
    if (-not $ldifde)   { $rsatInstallable += 'ldifde' }
    if (-not $adModule) { $rsatInstallable += 'admodule' }

    # OS-appropriate install command - only emitted when something it provides is actually missing.
    # On a server, RSAT-AD-Tools includes dsamain.exe; on a client the capability does NOT.
    $installCmd = if ($rsatInstallable.Count -eq 0) {
        ''
    } elseif ($isServer) {
        'Install-WindowsFeature RSAT-AD-Tools'
    } else {
        'Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0'
    }

    # dsamain missing on a client SKU: RSAT cannot fix it - tell the operator to use a server.
    $dsamainNeedsServer = (-not $dsamain) -and (-not $isServer)
    $guidance = if ($dsamainNeedsServer) {
        'dsamain.exe ships only with the Windows Server AD DS / AD LDS role and is NOT available on Windows client editions - installing RSAT on this client will not provide it. Run the mount/compare/restore steps on a Windows Server or a domain controller (where dsamain.exe is already present, or installable with: Install-WindowsFeature RSAT-AD-Tools).'
    } else { '' }

    [pscustomobject]@{
        Ok                    = ($missing.Count -eq 0)
        IsAdmin               = $isAdmin
        IsServerOS            = $isServer
        Dsamain               = $dsamain
        Esentutl              = $esentutl
        Ldifde                = $ldifde
        AdModule              = $adModule
        Missing               = $missing.ToArray()
        InstallCommand        = $installCmd
        DsamainRequiresServer = $dsamainNeedsServer
        Guidance              = $guidance
    }
}

# ----------------------------------------------------------------------------
# 1. ACQUISITION from HYCU
# ----------------------------------------------------------------------------
function Clear-HYCUADStaging {
    <#
    .SYNOPSIS
      Prunes old local staging folders (the working copies of ntds.dit).

    .DESCRIPTION
      Each restore drops a copy of the NTDS database (potentially several GB) under the
      staging root, named 'flr_<stamp>' (file-level restore via HYCU REST) or 'snap_<stamp>'
      (a copy made from an already-mounted source). Over time these pile up. This keeps the
      most recent -KeepLast folders and removes the rest. If -MaxAgeDays is set (> 0), only
      folders older than that cutoff are eligible for removal (the -KeepLast newest are always
      kept regardless of age). Honors -WhatIf.

    .EXAMPLE
      Clear-HYCUADStaging -KeepLast 3
    .EXAMPLE
      Clear-HYCUADStaging -KeepLast 2 -MaxAgeDays 7 -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$StagingRoot = $script:HYCUADConfig.StagingRoot,
        [int]$KeepLast       = $script:HYCUADConfig.StagingKeepLast,
        [int]$MaxAgeDays     = $script:HYCUADConfig.StagingMaxAgeDays
    )

    if ($KeepLast -lt 0) { $KeepLast = 0 }
    if (-not $StagingRoot -or -not (Test-Path $StagingRoot)) { return @() }

    # Only ever touch our own staging folders (flr_* / snap_*) - never anything else.
    $folders = @(Get-ChildItem -Path $StagingRoot -Directory -ErrorAction SilentlyContinue |
                 Where-Object { $_.Name -match '^(flr|snap)_' } |
                 Sort-Object LastWriteTime -Descending)
    if ($folders.Count -le $KeepLast) { return @() }

    # Everything beyond the newest -KeepLast is a candidate for removal.
    $candidates = $folders | Select-Object -Skip $KeepLast
    if ($MaxAgeDays -gt 0) {
        $cutoff = (Get-Date).AddDays(-$MaxAgeDays)
        $candidates = $candidates | Where-Object { $_.LastWriteTime -lt $cutoff }
    }

    $removed = @()
    foreach ($f in $candidates) {
        if ($PSCmdlet.ShouldProcess($f.FullName, "Remove old staging folder")) {
            try {
                Remove-Item -LiteralPath $f.FullName -Recurse -Force -ErrorAction Stop
                Write-HYCULog "Removed old staging folder: $($f.Name)"
                $removed += $f.FullName
            } catch {
                # A folder still in use (e.g. mounted by dsamain) just stays; never abort cleanup.
                Write-HYCULog "Could not remove staging folder '$($f.Name)': $_" 'WARN'
            }
        }
    }
    return $removed
}

function Get-HYCUADStagedDatabase {
    <#
    .SYNOPSIS
      Makes the NTDS folder from a HYCU backup available.

    .DESCRIPTION
      -SourcePath : you have ALREADY restored/mounted the C:\Windows\NTDS folder via
                    HYCU (ntds.dit + edb*.log + edb.chk) - the recommended, most
                    reliable, version-independent method.

      For API-driven retrieval, use the HYCUClient module (Connect-HYCUController +
      Start-HYCUFileLevelRestore), then pass the returned folder to -SourcePath.

      The content is copied to a clean staging folder and returned.

    .EXAMPLE
      Get-HYCUADStagedDatabase -SourcePath 'R:\HYCU_Restore\DC01\Windows\NTDS'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,
        [string]$SysvolSourcePath
    )

    # Prune older staging folders before adding a new one (keeps the disk from filling with
    # multi-GB NTDS copies). Best-effort: a cleanup failure must never block a restore.
    if ($script:HYCUADConfig.StagingAutoClean) {
        try { Clear-HYCUADStaging | Out-Null } catch { Write-HYCULog "Staging auto-clean skipped: $_" 'WARN' }
    }

    $stamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
    $stage   = Join-Path $script:HYCUADConfig.StagingRoot "snap_$stamp"
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    Write-HYCULog "Staging folder: $stage"

    if (-not (Test-Path $SourcePath)) { throw "NTDS source not found: $SourcePath" }
    $dit = Get-ChildItem -Path $SourcePath -Filter 'ntds.dit' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $dit) { throw "No ntds.dit found in $SourcePath" }

    # Copy the database AND the journals (required for soft recovery)
    Get-ChildItem -Path $SourcePath -File |
        Where-Object { $_.Name -match '^(ntds\.dit|edb.*\.log|edb\.chk|edbres.*\.jrs|temp\.edb)$' } |
        ForEach-Object {
            Copy-Item $_.FullName -Destination $stage -Force
            Write-HYCULog "Copied: $($_.Name) ($([math]::Round($_.Length/1MB,1)) MB)"
        }

    if ($SysvolSourcePath -and (Test-Path $SysvolSourcePath)) {
        $sysvolDst = Join-Path $stage 'SYSVOL'
        Copy-Item $SysvolSourcePath -Destination $sysvolDst -Recurse -Force
        Write-HYCULog "SYSVOL copied to $sysvolDst"
    }

    [pscustomobject]@{
        StagePath  = $stage
        DitPath    = (Join-Path $stage 'ntds.dit')
        SysvolPath = (Join-Path $stage 'SYSVOL')
        CreatedAt  = Get-Date
    }
}

# ----------------------------------------------------------------------------
# 2. PREPARATION: database state and ESE soft recovery
# ----------------------------------------------------------------------------
function Test-HYCUADDatabaseState {
    <#
    .SYNOPSIS  Reads the ESE header (esentutl /mh): 'Clean Shutdown' or 'Dirty Shutdown'.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DitPath)
    if (-not (Test-Path $DitPath)) { throw "Database not found: $DitPath" }
    $out = & $script:HYCUADConfig.EsentutlPath /mh $DitPath 2>&1 | Out-String
    $clean = $out -match 'State:\s*Clean Shutdown'
    # The header lists the log generation(s) recovery needs to reach a clean state, e.g. "Log Required: 12345-12347".
    $logReq = if ($out -match 'Log Required:\s*([^\r\n]+)') { $matches[1].Trim() } else { '' }
    [pscustomobject]@{
        Path        = $DitPath
        IsClean     = [bool]$clean
        StateText   = if ($clean) { 'Clean Shutdown' } elseif ($out -match 'Dirty Shutdown') { 'Dirty Shutdown' } else { 'Unknown' }
        LogRequired = $logReq
        RawHeader   = $out
    }
}

function Invoke-HYCUEsentutlRepair {
    <#
    .SYNOPSIS  Runs 'esentutl /p' (hard repair), auto-clicking its warning dialog. Returns $true if it exited cleanly.
    .DESCRIPTION
      esentutl /p pops a "You should only run Repair... Do you wish to proceed?" warning (a #32770 dialog)
      and blocks. This launches the repair hidden and, while it runs, clicks OK/Yes on that dialog so the
      repair is non-interactive. A SHORT hard timeout guarantees it cannot spin: esentutl /p finishes the
      real repair in seconds, so a long wait means the prompt was not auto-answered on this host.
      NOTE: do NOT redirect stdin here - doing so changes esentutl's behaviour and the warning dialog the
      clicker relies on never appears, leaving /p blocked. Output is captured; stdin is left alone.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DitPath,
        [int]$TimeoutSeconds = 0    # 0 => read EsentutlRepairTimeoutSeconds from config at CALL time
    )
    if ($TimeoutSeconds -le 0) {
        $TimeoutSeconds = [int]$script:HYCUADConfig.EsentutlRepairTimeoutSeconds
        if ($TimeoutSeconds -le 0) { $TimeoutSeconds = 180 }
    }

    if (-not ('HYCU.DlgKiller' -as [type])) {
        try {
            Add-Type -Namespace HYCU -Name DlgKiller -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern System.IntPtr FindWindowEx(System.IntPtr parent, System.IntPtr child, string cls, string title);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(System.IntPtr hWnd, out int procId);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr hWnd, int cmd);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool PostMessage(System.IntPtr hWnd, uint msg, System.IntPtr wParam, System.IntPtr lParam);
'@
        } catch { Write-HYCULog "Dialog auto-dismiss unavailable: $($_.Exception.Message)" 'DEBUG' }
    }
    $api = ('HYCU.DlgKiller' -as [type])

    $logDir = $script:HYCUADConfig.LogDirectory
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    Get-ChildItem -Path $logDir -Filter 'esentutl_*' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-1) } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
    $out = Join-Path $logDir "esentutl_$stamp.out.log"
    $err = Join-Path $logDir "esentutl_$stamp.err.log"

    Write-HYCULog "Running hard repair: esentutl /p (auto-confirming its dialog; up to $TimeoutSeconds s)..." 'WARN'
    $exitedClean = $false; $confirmed = $false
    # WorkingDirectory = the database folder: esentutl /p writes its integrity scratch file
    # (ntds.INTEG.RAW) into the CURRENT directory - without this it lands next to the executable.
    $dbFolder = Split-Path -Parent $DitPath
    $proc = Start-Process -FilePath $script:HYCUADConfig.EsentutlPath -ArgumentList @('/p', "`"$DitPath`"", '/8') `
                          -WorkingDirectory $dbFolder `
                          -PassThru -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError $err
    try { $proc.EnableRaisingEvents = $true } catch {}
    try {
        $WM_COMMAND = [uint32]0x0111; $IDOK = [IntPtr]1; $IDYES = [IntPtr]6; $SW_HIDE = 0
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        while (-not $proc.HasExited) {
            if ($api) {
                $h = [HYCU.DlgKiller]::FindWindowEx([IntPtr]::Zero, [IntPtr]::Zero, '#32770', $null)
                while ($h -ne [IntPtr]::Zero) {
                    $owner = 0; [void][HYCU.DlgKiller]::GetWindowThreadProcessId($h, [ref]$owner)
                    if ($owner -eq $proc.Id) {
                        [void][HYCU.DlgKiller]::PostMessage($h, $WM_COMMAND, $IDOK,  [IntPtr]::Zero)
                        [void][HYCU.DlgKiller]::PostMessage($h, $WM_COMMAND, $IDYES, [IntPtr]::Zero)
                        [void][HYCU.DlgKiller]::ShowWindow($h, $SW_HIDE)
                        if (-not $confirmed) { Write-HYCULog "Auto-confirmed the esentutl repair dialog." 'DEBUG'; $confirmed = $true }
                    }
                    $h = [HYCU.DlgKiller]::FindWindowEx([IntPtr]::Zero, $h, '#32770', $null)
                }
            }
            if ((Get-Date) -gt $deadline) {
                Write-HYCULog "esentutl /p did not finish within $TimeoutSeconds s - terminating it (its confirmation could not be auto-answered on this host)." 'ERROR'
                try { if (-not $proc.HasExited) { $proc.Kill() } } catch {}
                break
            }
            Start-Sleep -Milliseconds 200
        }
        if ($proc.HasExited) { try { $exitedClean = ($proc.ExitCode -eq 0) } catch { $exitedClean = $false } }
        Start-Sleep -Milliseconds 100
        # Surface whatever esentutl /p printed (INFO, so it shows in the GUI) - this reveals how the
        # confirmation appears on this host (a console 'Y/N' line vs a separate GUI dialog with no stdout).
        foreach ($f in @($out, $err)) {
            $c = Get-Content -LiteralPath $f -Raw -ErrorAction SilentlyContinue
            if ($c) { foreach ($l in ($c -split "`r?`n")) { if ($l.Trim()) { Write-HYCULog "esentutl: $($l.Trim())" 'INFO' } } }
        }
    } finally {
        try { $proc.Dispose() } catch {}
        Remove-Item -LiteralPath $out, $err -Force -ErrorAction SilentlyContinue
        # The repair's integrity scratch file (*.INTEG.RAW) is useless once esentutl exits - drop it.
        # Also sweep the process's current directory, where earlier versions let it land.
        foreach ($d in @($dbFolder, (Get-Location).Path) | Sort-Object -Unique) {
            Get-ChildItem -Path $d -Filter '*.INTEG.RAW' -File -ErrorAction SilentlyContinue |
                ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
        }
    }
    return $exitedClean
}

function Repair-HYCUADDatabase {
    <#
    .SYNOPSIS
      Makes the database mountable: soft recovery (log replay) then, optionally,
      hard repair (/p) as a last resort.
    .DESCRIPTION
      A backup of a running DC yields a 'Dirty' database that needs ESE recovery. Escalation:
        1. soft recovery  - esentutl /r edb /i /8      (replay the journals)
        2. lossy recovery - esentutl /r edb /i /8 /a   (when the current/required logs are missing;
                                                        accepts loss of un-recoverable transactions)
        3. hard repair    - esentutl /p                (destructive, only with -AllowHardRepair/AutoHardRepair)
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$DitPath,
        [switch]$AllowHardRepair
    )
    $folder = Split-Path $DitPath -Parent
    $state  = Test-HYCUADDatabaseState -DitPath $DitPath
    Write-HYCULog "Database state: $($state.StateText)"
    if ($state.IsClean) { Write-HYCULog "Database already clean, no repair needed." 'SUCCESS'; return $true }

    # Diagnostic (shown before any repair): the log generation(s) the ntds.dit header needs vs. the
    # transaction files actually present. If a required log is missing, soft+lossy recovery cannot finish
    # and a hard repair (/p) is used; if the required logs ARE present but /p still runs, the log/ntds.dit
    # signatures likely don't match (files captured at different moments). Lets the operator see the real cause.
    try {
        $present = @(Get-ChildItem -LiteralPath $folder -File -ErrorAction SilentlyContinue |
                     Where-Object { $_.Name -match '^(edb.*\.log|edb\.chk)$' } |
                     Select-Object -ExpandProperty Name | Sort-Object)
        Write-HYCULog "Recovery diagnostic - Log Required (ntds.dit header): $(if ($state.LogRequired) { $state.LogRequired } else { '(not reported)' })." 'INFO'
        Write-HYCULog "Recovery diagnostic - transaction files present: $(if ($present) { $present -join ', ' } else { 'NONE - no edb*.log/edb.chk, so soft recovery has nothing to replay' })." 'INFO'
        Write-HYCULog "Recovery diagnostic - if a required log is missing here, re-pull the backup WITH edb*.log + edb.chk (they must match ntds.dit); if they are present but /p still runs, the log/ntds.dit signatures do not match (different snapshot moments)." 'INFO'
    } catch {}

    if ($PSCmdlet.ShouldProcess($DitPath, "ESE soft recovery (esentutl /r)")) {
        Push-Location $folder
        try {
            # AD log base name = 'edb'; /8 = 8 KB page size (AD's ESE).
            Write-HYCULog "Soft recovery: esentutl /r edb /i /8 ..."
            & $script:HYCUADConfig.EsentutlPath /r edb /i /8 2>&1 | ForEach-Object { Write-HYCULog $_ 'DEBUG' }
            $state = Test-HYCUADDatabaseState -DitPath $DitPath
            # If the current/required logs are missing, plain replay can't finish (ESE reports a
            # "lossy recovery option"). /a accepts the loss of the un-recoverable transactions and
            # usually yields a clean, mountable database - far less invasive than a hard repair (/p).
            if (-not $state.IsClean) {
                Write-HYCULog "Soft recovery incomplete; retrying with lossy recovery: esentutl /r edb /i /8 /a ..." 'WARN'
                & $script:HYCUADConfig.EsentutlPath /r edb /i /8 /a 2>&1 | ForEach-Object { Write-HYCULog $_ 'DEBUG' }
            }
        } finally { Pop-Location }

        $state = Test-HYCUADDatabaseState -DitPath $DitPath
        if ($state.IsClean) { Write-HYCULog "Recovery succeeded: database 'Clean'." 'SUCCESS'; return $true }
    }

    # Hard repair is the automatic last resort (config AutoHardRepair, default on) - it only repairs the
    # OFFLINE staged copy (never production). SAFETY: the AUTO path fires only on a CONFIRMED 'Dirty Shutdown'
    # - never on 'Unknown' (e.g. if esentutl /mh output could not be parsed), so a database mis-detected as
    # not-clean is never destructively repaired. -AllowHardRepair forces it regardless (explicit operator opt-in).
    $confirmedDirty = ($state.StateText -eq 'Dirty Shutdown')
    if (-not $state.IsClean -and -not $confirmedDirty -and -not $AllowHardRepair) {
        Write-HYCULog "Database state is '$($state.StateText)' (not a confirmed 'Dirty Shutdown'); skipping the destructive hard repair (esentutl /p) to avoid repairing a possibly-clean database. Force it with -AllowHardRepair if you are sure." 'WARN'
    }
    if (-not $state.IsClean -and ($AllowHardRepair -or ($script:HYCUADConfig.AutoHardRepair -and $confirmedDirty))) {
        if ($PSCmdlet.ShouldProcess($DitPath, "DESTRUCTIVE hard repair (esentutl /p)")) {
            Write-HYCULog "Soft and lossy recovery did not clean the database; applying hard repair (esentutl /p) as a last resort - the offline copy may lose the most recent uncommitted changes." 'WARN'
            Invoke-HYCUEsentutlRepair -DitPath $DitPath
            $state = Test-HYCUADDatabaseState -DitPath $DitPath
            if ($state.IsClean) {
                # After a hard repair the transaction logs + checkpoint are STALE - they still reference
                # the pre-repair database, so dsamain would replay them and fail with JET -1216
                # (attached-database mismatch). The repaired database is self-consistent, so remove them;
                # dsamain then mounts it directly with no recovery.
                Get-ChildItem -Path $folder -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -match '^(edb.*\.log|edb\.chk|edb.*\.jrs|temp\.edb)$' } |
                    ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
                Write-HYCULog "Hard repair complete; removed the now-stale transaction logs/checkpoint." 'WARN'
            }
        }
    }

    if ($state.IsClean) { return $true }
    Write-HYCULog "The database remains '$($state.StateText)'. dsamain may refuse to mount it." 'ERROR'
    return $false
}

# ----------------------------------------------------------------------------
# 3. MOUNT / DISMOUNT via dsamain
# ----------------------------------------------------------------------------
function Get-DsamainFailureMessage {
    <#
    .SYNOPSIS  Builds an actionable error when dsamain exits before the LDAP port opens.
    .DESCRIPTION
      Surfaces dsamain's own captured output (the only reliable clue to the cause) and lists the
      common root causes, the foremost being a Windows version mismatch (dsamain can only mount a
      database from its own OS version or older).
    #>
    [CmdletBinding()]
    param([int]$ExitCode, [string]$Output, [int]$Port)
    $codeText = if ($ExitCode -lt 0) { 'exit code unavailable' } else { "code $ExitCode" }
    $m = "dsamain exited ($codeText) before the LDAP port $Port opened."
    if ($Output) { $m += "`n--- dsamain output ---`n$Output`n----------------------" }
    else         { $m += " It produced no output - it may have failed to start at all." }

    # Tailor the guidance to what dsamain actually reported, instead of always blaming a version mismatch.
    $portBusy = $Output -match '10048' -or $Output -match 'already in use' -or $Output -match 'failed to open a UDP port'
    $initFail = $Output -match '\b8431\b' -or ($Output -match 'attached a database' -and $Output -match 'stopped the instance')

    if ($portBusy) {
        $m += "`nMOST LIKELY CAUSE: the LDAP port $Port is already in use (TCP or UDP) - usually a leftover" +
              "`ndsamain.exe from a previous attempt (dsamain needs the port on BOTH TCP and UDP). The database" +
              "`nmounted up to this point, so this is NOT a database problem. Fix: close any other dsamain.exe" +
              "`n('taskkill /im dsamain.exe /f') then retry, or pick another port (Set-HYCUADConfig -LdapPort <n>)."
    } elseif ($initFail) {
        $m += "`nMOST LIKELY CAUSE: AD DS could not START on the database (it attached, then stopped). The" +
              "`ndatabase is not fully consistent for AD - usually an esentutl /p repair that did not run to" +
              "`ncompletion. Re-run the repair so it finishes (the header must read 'Clean Shutdown' via" +
              "`n'esentutl /mh `"<ntds.dit>`"'), or re-pull the backup."
    } else {
        $m += "`nCommon causes:" +
              "`n  1. The LDAP port $Port is in use (TCP or UDP) - close leftover dsamain.exe, or set another port." +
              "`n  2. The database is still 'Dirty' (run recovery/repair first) or the edb*.log journals are missing." +
              "`n  3. VERSION: dsamain can only mount a database from its OWN Windows Server version or OLDER" +
              "`n     (a newer DC's ntds.dit on an older host is refused)." +
              "`n  4. Insufficient rights - run elevated (and optionally Set-HYCUADConfig -AllowNonAdmin `$true)."
    }
    return $m
}

function Test-HYCUPortFree {
    <#  .SYNOPSIS  $true only if the port is free on BOTH TCP and UDP (any interface).
        .DESCRIPTION
          dsamain binds the LDAP port on TCP (LDAP) AND UDP (CLDAP) for exclusive use, so a port that is
          free on TCP but held on UDP (e.g. by a leftover dsamain) makes it fail with error 10048 ("only
          one usage of each socket address..."). Both must be checked, or the tool hands dsamain a port
          it cannot bind and the mount fails for a non-database reason.  #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Port)
    try {
        # Authoritative: enumerate every active TCP listener AND UDP endpoint (all interfaces).
        $props = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()
        $tcp = @($props.GetActiveTcpListeners()  | Where-Object { $_.Port -eq $Port }).Count
        $udp = @($props.GetActiveUdpListeners()   | Where-Object { $_.Port -eq $Port }).Count
        return (($tcp + $udp) -eq 0)
    } catch {
        # Fallback: try to bind both a TCP listener and a UDP socket on the port.
        $ok = $true; $l = $null; $u = $null
        try { $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Any, $Port); $l.Start() }
        catch { $ok = $false } finally { if ($l) { try { $l.Stop() } catch {} } }
        if ($ok) {
            try { $u = New-Object System.Net.Sockets.UdpClient($Port) }
            catch { $ok = $false } finally { if ($u) { try { $u.Close() } catch {} } }
        }
        return $ok
    }
}

function Mount-HYCUADSnapshot {
    <#
    .SYNOPSIS  Mounts the offline database as a local LDAP server (dsamain.exe).
    .DESCRIPTION
      Clears any of our residual dsamain, then tries to mount on $Port; if the port is in use or
      dsamain fails to come up for a NON-database reason (e.g. the port is held by something else),
      it automatically shifts to the next port and RETRIES. A database problem (dirty/mismatch/
      corrupt) is surfaced immediately - another port would not help.
    .OUTPUTS   Session object { Process, Port, BaseDN, DitPath, Server, OutLog, ErrLog }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DitPath,
        [int]$Port = $script:HYCUADConfig.LdapPort,
        [int]$TimeoutSeconds = 60
    )
    if (-not (Test-Path $DitPath)) { throw "Database not found: $DitPath" }
    [void](Stop-HYCUADMountResidue -Port $Port -Confirm:$false)

    $requestedPort = $Port; $lastErr = $null; $dbErrRetries = 0
    for ($attempt = 0; $attempt -lt 12; $attempt++) {
        # Shift up to a genuinely free port (TCP+UDP, all interfaces) before this attempt.
        $g = 0
        while ((-not (Test-HYCUPortFree -Port $Port)) -and $g -lt 50) {
            Write-HYCULog "LDAP port $Port is in use (TCP or UDP); trying $($Port + 1)..." 'WARN'; $Port++; $g++
        }
        try {
            return (Invoke-HYCUADdsamainMount -DitPath $DitPath -Port $Port -TimeoutSeconds $TimeoutSeconds)
        } catch {
            $lastErr = "$_"
            if ($script:HYCULastMountDbError) {
                # A database error (e.g. JET -550 Dirty Shutdown) USUALLY means another port won't help -
                # but it can ALSO be a leftover dsamain still holding the database from a prior attempt,
                # in which case a different port + a residue purge succeeds (observed live: -550 on one
                # port, clean mount on the next). So clear residue and retry a FEW times before giving up;
                # a genuinely dirty database keeps failing and we stop quickly.
                $dbErrRetries++
                if ($dbErrRetries -gt 3) { throw $lastErr }
                Write-HYCULog "dsamain reported a database error on port $Port (attempt $($attempt + 1)) - often stale dsamain working logs (JET -1216), not a busy port; each retry clears the DS<port> working dir. Retrying ($dbErrRetries/3)..." 'WARN'
                [void](Stop-HYCUADMountResidue -Port $Port -Confirm:$false)
                Start-Sleep -Milliseconds 500
                $Port++
                continue
            }
            Write-HYCULog "dsamain did not come up on port $Port (attempt $($attempt + 1)); retrying on the next port..." 'WARN'
            $Port++
        }
    }
    throw ("dsamain could not be started after $($Port - $requestedPort) port attempt(s) from $requestedPort. Last error:`n$lastErr")
}

function Invoke-HYCUADdsamainMount {
    # One mount attempt on a specific port: launch dsamain, wait for the LDAP port, read RootDSE and
    # return the session. Throws (via Get-DsamainFailureMessage) on failure and sets the module flag
    # $script:HYCULastMountDbError so the caller can decide whether retrying on another port is useful.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DitPath, [Parameter(Mandatory)][int]$Port, [int]$TimeoutSeconds = 60)
    $script:HYCULastMountDbError = $false

    $dsamainArgs = @('/dbpath', "`"$DitPath`"", '/ldapport', $Port, '/allowUpgrade')
    if ($script:HYCUADConfig.AllowNonAdmin) { $dsamainArgs += '/allowNonAdminAccess' }

    Write-HYCULog "Mounting: dsamain $($dsamainArgs -join ' ')"

    # Capture dsamain's stdout/stderr to files. When dsamain exits early (the usual failure mode) its
    # own message is one clue to the cause - and its RICHEST diagnostics go to the Windows
    # 'Directory Service' event log, which we also read, since the console output is often terse.
    $logDir = $script:HYCUADConfig.LogDirectory
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    # Best-effort prune of old dsamain capture logs (only failed mounts leave them behind).
    try {
        Get-ChildItem -Path $logDir -Filter 'dsamain_*.log' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } catch {}
    $stamp   = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
    $outFile = Join-Path $logDir "dsamain_$stamp.out.log"
    $errFile = Join-Path $logDir "dsamain_$stamp.err.log"

    # dsamain keeps its per-instance recovery logs in %TEMP%\DS<port>. A LEFTOVER DS<port>\edb.log from a
    # previous run references a now-repaired/deleted ntds.dit, so dsamain's recovery fails with JET -1216
    # ("attached database mismatch / database was moved or renamed") - which looks like, but is NOT, a
    # busy-port problem (netstat shows the port free). Clear this working directory so dsamain starts clean
    # and attaches the (already consistent) database directly.
    foreach ($root in (@($env:TEMP, $env:TMP, [System.IO.Path]::GetTempPath(), (Join-Path ([string]$env:LOCALAPPDATA) 'Temp')) | Where-Object { $_ } | Select-Object -Unique)) {
        try { Remove-Item -LiteralPath (Join-Path $root "DS$Port") -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    }

    $mountStart = Get-Date     # for filtering Directory Service events raised by this mount attempt
    $proc = Start-Process -FilePath $script:HYCUADConfig.DsamainPath -ArgumentList $dsamainArgs `
                          -PassThru -WindowStyle Hidden `
                          -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    # Start-Process -PassThru does not reliably expose ExitCode after the process ends unless the
    # object is told to watch for the exit; without this $proc.ExitCode comes back blank.
    try { $proc.EnableRaisingEvents = $true }
    catch { Write-HYCULog "Could not set EnableRaisingEvents; dsamain exit code may be unavailable: $($_.Exception.Message)" 'DEBUG' }

    $readDsamainOutput = {
        $parts = @()
        foreach ($f in @($errFile, $outFile)) {
            $c = (Get-Content -LiteralPath $f -Raw -ErrorAction SilentlyContinue)
            if ($c -and $c.Trim()) { $parts += $c.Trim() }
        }
        ($parts -join "`n").Trim()
    }
    $readDsamainEvents = {
        try {
            $evs = Get-WinEvent -FilterHashtable @{ LogName = 'Directory Service'; StartTime = $mountStart } -MaxEvents 15 -ErrorAction Stop
            ($evs | Sort-Object TimeCreated | ForEach-Object {
                $first = ($_.Message -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
                '[{0} {1}] {2}' -f $_.TimeCreated.ToString('HH:mm:ss'), $_.LevelDisplayName, $first
            }) -join "`n"
        } catch { '' }
    }
    $logDsamain = { param($text) if ($text) { foreach ($l in ($text -split "`r?`n")) { Write-HYCULog "dsamain: $l" 'DEBUG' } } }

    # Shared failure path: gather console output + Directory Service events, log them, throw an
    # actionable message. $ExitCode < 0 means "unavailable". Throwing from here propagates out of Mount.
    $failDsamain = {
        param([int]$ExitCode, [string]$Extra)
        $out = & $readDsamainOutput
        $evt = & $readDsamainEvents
        & $logDsamain $out
        # Is this a DATABASE failure (dirty/mismatch/corrupt)? Decide from the RAW dsamain output/events
        # only (NOT the appended cause list, which always mentions every cause). DB errors must NOT be
        # retried on another port; a port/listener problem (no JET code) should be.
        $raw = (@($out, $evt) | Where-Object { $_ }) -join "`n"
        $script:HYCULastMountDbError = [bool]($raw -match '(\-550|\-1216|\-1206|JET_err|Dirty Shutdown)')
        $combined = @($out,
                      $(if ($evt) { "--- Directory Service event log ---`n$evt" }),
                      $Extra) | Where-Object { $_ }
        throw (Get-DsamainFailureMessage -ExitCode $ExitCode -Output ($combined -join "`n") -Port $Port)
    }
    $exitCodeOf = { if ($null -eq $proc.ExitCode) { -1 } else { [int]$proc.ExitCode } }

    # Wait for the LDAP port to become available
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds); $ready = $false
    while ((Get-Date) -lt $deadline) {
        if ($proc.HasExited) {
            Start-Sleep -Milliseconds 250            # let the OS flush the redirected files / events
            & $failDsamain (& $exitCodeOf) $null
        }
        $tcp = $null
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $tcp.Connect('localhost', $Port); $ready = $true; break
        } catch { Start-Sleep -Milliseconds 750 }
        finally { if ($tcp) { $tcp.Dispose() } }   # else a socket leaks on every failed probe
    }
    if (-not $ready) {
        try { $proc.Kill(); $proc.WaitForExit(2000) | Out-Null } catch {}
        Start-Sleep -Milliseconds 250
        & $failDsamain (& $exitCodeOf) "The LDAP port did not open within $TimeoutSeconds s; dsamain was terminated."
    }

    # The port answered - but make sure it is OUR dsamain, not a foreign listener already on this port
    # (a stale dsamain / an AD LDS instance), which would otherwise make us read an unrelated directory.
    if ($proc.HasExited) {
        Start-Sleep -Milliseconds 250
        & $failDsamain (& $exitCodeOf) $null
    }

    # Read the default naming context (RootDSE). Dispose the DirectoryEntry (LDAP/COM handle) in finally.
    $rootDse = New-Object System.DirectoryServices.DirectoryEntry("LDAP://localhost:$Port/RootDSE")
    try { $baseDN = [string]$rootDse.Properties['defaultNamingContext'].Value }
    finally { try { $rootDse.Dispose() } catch {} }
    if ([string]::IsNullOrWhiteSpace($baseDN)) {
        try { $proc.Kill() } catch {}
        & $failDsamain -1 "RootDSE on localhost:$Port returned no naming context - the port is likely held by another service, not this dsamain instance."
    }

    Write-HYCULog "Snapshot mounted on LDAP localhost:$Port (NC=$baseDN)." 'SUCCESS'
    [pscustomobject]@{
        Process = $proc
        Port    = $Port
        BaseDN  = $baseDN
        DitPath = $DitPath
        Server  = "localhost:$Port"
        OutLog  = $outFile
        ErrLog  = $errFile
    }
}

function Dismount-HYCUADSnapshot {
    <#
    .SYNOPSIS  Cleanly stops the dsamain instance.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Session)
    if ($Session.Process -and -not $Session.Process.HasExited) {
        # dsamain is a windowless console app (CloseMainWindow is a no-op for it), so terminate directly.
        try { $Session.Process.Kill(); $Session.Process.WaitForExit(5000) | Out-Null } catch {}
        Write-HYCULog "Snapshot dismounted (port $($Session.Port))." 'SUCCESS'
    }
    # A clean dismount means the capture files were never needed (only failures read them) - tidy up.
    foreach ($f in @($Session.OutLog, $Session.ErrLog)) {
        if ($f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    }
    [void](Stop-HYCUADMountResidue -Port $Session.Port -Confirm:$false)
}

function Get-HYCUPortOwnerPid {
    <#  .SYNOPSIS  Returns the PID(s) that currently hold a port on TCP or UDP (empty if none).
        .DESCRIPTION
          Uses Get-NetTCPConnection / Get-NetUDPEndpoint (present on Server 2012 R2+); falls back to
          parsing 'netstat -ano'. This identifies a port holder WITHOUT reading its command line, so it
          finds a leftover dsamain even when WMI cannot read Win32_Process.CommandLine.  #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Port)
    $pids = New-Object System.Collections.Generic.List[int]
    try { foreach ($c in @(Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue)) { if ($c.OwningProcess) { [void]$pids.Add([int]$c.OwningProcess) } } } catch {}
    try { foreach ($e in @(Get-NetUDPEndpoint   -LocalPort $Port -ErrorAction SilentlyContinue)) { if ($e.OwningProcess) { [void]$pids.Add([int]$e.OwningProcess) } } } catch {}
    if ($pids.Count -eq 0) {
        # Fallback for hosts without the NetTCPIP cmdlets: parse netstat. Match the LOCAL address column
        # (second field) ending in ':<port>' so a foreign-address port number is not mistaken for ours.
        try {
            foreach ($line in (netstat -ano 2>$null)) {
                $f = @(($line -split '\s+') | Where-Object { $_ })
                if ($f.Count -ge 4 -and ($f[0] -eq 'TCP' -or $f[0] -eq 'UDP') -and $f[1] -match ":$Port$") {
                    $procId = $f[-1]; if ($procId -match '^\d+$') { [void]$pids.Add([int]$procId) }
                }
            }
        } catch {}
    }
    return ($pids | Select-Object -Unique)
}

function Stop-HYCUADMountResidue {
    <#
    .SYNOPSIS
      Kills leftover dsamain instances spawned by this tool (residue from failed / abandoned mounts).
    .DESCRIPTION
      dsamain is ONLY ever the AD snapshot-mounting tool - a live domain controller runs as
      lsass / the NTDS service, never as dsamain.exe - so cleaning up dsamain is safe even on a DC.
      This stops: (1) explicitly tracked PIDs; (2) dsamain whose command line references THIS tool's
      LDAP port or staging folder; (3) WHATEVER dsamain currently HOLDS the target port (by PID from the
      TCP/UDP tables) - robust even when the command line cannot be read; (4) with DsamainResidueScope='All'
      (default), EVERY remaining dsamain.exe - so a previous session's leftover never blocks the default
      port and it is reused instead of drifting to 41390, 41391... Best-effort; honors -WhatIf.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [int]$Port = $script:HYCUADConfig.LdapPort,
        [int[]]$ProcessId
    )
    $killed = New-Object System.Collections.Generic.List[int]

    # 1. Explicitly tracked PIDs (definitely ours).
    foreach ($trackedId in @($ProcessId)) {
        if (-not $trackedId) { continue }
        $p = Get-Process -Id $trackedId -ErrorAction SilentlyContinue
        if ($p -and -not $p.HasExited -and $PSCmdlet.ShouldProcess("PID $trackedId", "Stop residual mount process")) {
            try { $p.Kill(); $p.WaitForExit(3000) | Out-Null; $killed.Add([int]$trackedId) } catch {}
        }
    }

    # 2. dsamain instances launched by this tool (command line references our LDAP port or staging).
    $stagingRoot = [string]$script:HYCUADConfig.StagingRoot
    foreach ($c in @(Get-CimInstance Win32_Process -Filter "Name='dsamain.exe'" -ErrorAction SilentlyContinue)) {
        if ($killed.Contains([int]$c.ProcessId)) { continue }
        $cmd  = [string]$c.CommandLine
        $mine = ($cmd -match "/ldapport\s+$Port(\s|$)") -or ($stagingRoot -and ($cmd -like "*$stagingRoot*"))
        if ($mine -and $PSCmdlet.ShouldProcess("dsamain PID $($c.ProcessId)", "Stop residual dsamain")) {
            try { Stop-Process -Id ([int]$c.ProcessId) -Force -ErrorAction Stop; $killed.Add([int]$c.ProcessId) } catch {}
        }
    }

    # 3. Whatever actually HOLDS the target port (TCP or UDP) - by PID, so it works even when the command
    #    line is unreadable. If that holder is a dsamain, stop it; this frees a port a leftover dsamain
    #    keeps bound (the cause of a port that "stays stuck until reboot").
    foreach ($holderPid in @(Get-HYCUPortOwnerPid -Port $Port)) {
        if ($killed.Contains([int]$holderPid)) { continue }
        $p = Get-Process -Id $holderPid -ErrorAction SilentlyContinue
        if ($p -and $p.ProcessName -eq 'dsamain' -and $PSCmdlet.ShouldProcess("dsamain PID $holderPid (holds port $Port)", "Stop residual dsamain")) {
            try { Stop-Process -Id ([int]$holderPid) -Force -ErrorAction Stop; $killed.Add([int]$holderPid) } catch {}
        }
    }

    # 4. Default ('All'): stop EVERY remaining dsamain.exe. Safe because dsamain.exe is exclusively this
    #    tool's mount process (a live DC runs as lsass/NTDS, never dsamain.exe). This guarantees a previous
    #    session's leftover cannot keep the default port bound, so the tool reuses 41389 next time instead
    #    of drifting up. Set DsamainResidueScope='Matched' to keep an unrelated concurrent dsamain alive.
    if ($script:HYCUADConfig.DsamainResidueScope -ne 'Matched') {
        foreach ($p in @(Get-Process -Name dsamain -ErrorAction SilentlyContinue)) {
            if ($killed.Contains([int]$p.Id)) { continue }
            if ($PSCmdlet.ShouldProcess("dsamain PID $($p.Id) (all-residue cleanup)", "Stop residual dsamain")) {
                try { Stop-Process -Id ([int]$p.Id) -Force -ErrorAction Stop; $killed.Add([int]$p.Id) } catch {}
            }
        }
        # Every dsamain is now stopped, so their per-instance working dirs (%TEMP%\DS<port>) are all stale.
        # Remove them ALL: a leftover DS<port>\edb.log makes the NEXT dsamain fail with JET -1216. Fully
        # automatic (this runs at every mount / dismount / exit) so the operator never cleans %TEMP% by hand.
        foreach ($root in (@($env:TEMP, $env:TMP, [System.IO.Path]::GetTempPath(), (Join-Path ([string]$env:LOCALAPPDATA) 'Temp')) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique)) {
            try {
                Get-ChildItem -LiteralPath $root -Directory -Filter 'DS*' -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -match '^DS\d+$' } |
                    ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
            } catch {}
        }
    }

    if ($killed.Count -gt 0) { Write-HYCULog "Cleaned up $($killed.Count) residual dsamain process(es): $($killed -join ', ')." 'SUCCESS' }
    return $killed.ToArray()
}

# Convenience orchestrator: acquisition + preparation + mount
function Connect-HYCUADSnapshot {
    <#
    .SYNOPSIS  Acquires (HYCU), prepares (esentutl) and mounts (dsamain) in one step.
    .EXAMPLE   $s = Connect-HYCUADSnapshot -SourcePath 'R:\Restore\DC01\Windows\NTDS'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [string]$SysvolSourcePath,
        [int]$Port = $script:HYCUADConfig.LdapPort,
        [switch]$AllowHardRepair
    )
    [void](Test-HYCUADPrerequisite)
    $staged = Get-HYCUADStagedDatabase -SourcePath $SourcePath -SysvolSourcePath $SysvolSourcePath
    # Stop here if the database is still 'Dirty' after recovery - mounting it would only yield a cryptic
    # dsamain JET -550 (JET_errDatabaseDirtyShutdown). Surface an actionable error instead.
    $clean = Repair-HYCUADDatabase -DitPath $staged.DitPath -AllowHardRepair:$AllowHardRepair -Confirm:$false
    if (-not $clean) {
        $hardTried = $AllowHardRepair -or $script:HYCUADConfig.AutoHardRepair
        throw ("The database could not be brought to a clean state for mounting (it stays 'Dirty'). " +
               $(if ($hardTried) {
                     "Soft recovery, lossy recovery (/a) AND hard repair (esentutl /p) were all attempted and " +
                     "failed - the ntds.dit is likely too damaged to mount, or the wrong file was restored. " +
                     "Re-pull the backup, or run 'esentutl /p `"$($staged.DitPath)`"' manually to inspect."
                 } else {
                     "Automatic hard repair is disabled (Set-HYCUADConfig -AutoHardRepair `$true to enable it)."
                 }))
    }
    $session = Mount-HYCUADSnapshot -DitPath $staged.DitPath -Port $Port
    $session | Add-Member -NotePropertyName SysvolPath -NotePropertyValue $staged.SysvolPath -PassThru
}

# ----------------------------------------------------------------------------
# LDAP helpers (raw reads via System.DirectoryServices)
#   -> required on the snapshot side because dsamain does not provide ADWS,
#      so the ActiveDirectory cmdlets cannot connect to it reliably.
# ----------------------------------------------------------------------------
function Get-LdapEntries {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Server,   # 'localhost:41389' or a live DC
        [Parameter(Mandatory)][string]$BaseDN,
        [string]$Filter = '(objectClass=*)',
        [ValidateSet('Base','OneLevel','Subtree')][string]$Scope = 'Subtree',
        [string[]]$Properties,
        [System.Management.Automation.PSCredential]$Credential,
        [switch]$IncludeDeleted
    )
    $path = "LDAP://$Server/$BaseDN"
    if ($Credential) {
        $root = New-Object System.DirectoryServices.DirectoryEntry($path, $Credential.UserName, $Credential.GetNetworkCredential().Password)
    } else {
        $root = New-Object System.DirectoryServices.DirectoryEntry($path)
    }
    $searcher = New-Object System.DirectoryServices.DirectorySearcher($root)
    $searcher.Filter   = $Filter
    $searcher.PageSize = 1000
    $searcher.SearchScope = $Scope
    if ($Properties) {
        $Properties | ForEach-Object { [void]$searcher.PropertiesToLoad.Add($_) }
    } else {
        # No explicit property list: request ALL (non-constructed) attributes with the LDAP wildcard.
        # Without this the server returns only its DEFAULT attribute set, which omits some attributes
        # for certain object classes (e.g. 'description' on a computer) - so the comparison silently
        # missed those changes. '*' guarantees the same full set for every object class, snapshot+live.
        [void]$searcher.PropertiesToLoad.Add('*')
    }
    if ($IncludeDeleted) { $searcher.Tombstone = $true }

    $results = New-Object System.Collections.Generic.List[object]
    $found = $searcher.FindAll()
    try {
        foreach ($res in $found) {
            $h = [ordered]@{}
            foreach ($propName in $res.Properties.PropertyNames) {
                $vals = $res.Properties[$propName]
                # Direct assignment (NOT `= if (...) { $vals[0] }`): routing a single byte[] value through
                # an if-expression's output stream ENUMERATES it into an Object[] of bytes, which then
                # corrupts binary attributes on restore. Direct assignment preserves the byte[].
                if ($vals.Count -eq 1) { $h[$propName] = $vals[0] } else { $h[$propName] = @($vals) }
            }
            $results.Add([pscustomobject]$h)
        }
    } finally {
        # SearchResultCollection holds unmanaged resources: dispose it explicitly.
        $found.Dispose(); $searcher.Dispose(); $root.Dispose()
    }
    return $results.ToArray()
}

# ----------------------------------------------------------------------------
# Diff helper: compares two "attribute bags" (pscustomobject) in memory.
#   Centralizes the comparison logic used by both the bulk comparison
#   (Compare-HYCUADObjects) and the single-object diff (Get-HYCUADObjectDiff),
#   which avoids re-querying LDAP object by object (the N+1 problem).
# ----------------------------------------------------------------------------
$script:HYCUADDiffIgnore = @('whenChanged','uSNChanged','dSCorePropagationData','lastLogon',
    'lastLogonTimestamp','badPasswordTime','badPwdCount','logonCount','replPropertyMetaData',
    'objectGUID','uSNCreated','adspath')

function ConvertTo-HYCUCanonicalValue {
    # Canonical, order-insensitive string for comparing an attribute value. A byte[] is rendered as
    # hex (NOT enumerated/sorted into individual bytes, which masked real differences and produced
    # garbage diff strings); multi-valued attributes are canonicalized element-wise then sorted.
    param($Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [byte[]]) { return [System.BitConverter]::ToString($Value) }
    $items = @($Value) | ForEach-Object { if ($_ -is [byte[]]) { [System.BitConverter]::ToString($_) } else { [string]$_ } }
    return (($items | Sort-Object) -join ' | ')
}

function Compare-HYCUADAttributeBag {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Snapshot,
        [pscustomobject]$Live
    )
    $names = @($Snapshot.PSObject.Properties.Name)
    if ($Live) { $names += @($Live.PSObject.Properties.Name) }
    $names = $names | Sort-Object -Unique

    $result = New-Object System.Collections.Generic.List[object]
    foreach ($n in $names) {
        if ($script:HYCUADDiffIgnore -contains $n) { continue }
        # Direct assignment (NOT `= if (...) { $x }`) - the if-expression's output stream would enumerate
        # a byte[] into individual bytes, defeating the binary-safe canonicalization below.
        $sv = $null; if ($Snapshot.PSObject.Properties[$n]) { $sv = $Snapshot.$n }
        $lv = $null; if ($Live -and $Live.PSObject.Properties[$n]) { $lv = $Live.$n }
        $svS = ConvertTo-HYCUCanonicalValue $sv
        $lvS = ConvertTo-HYCUCanonicalValue $lv
        if ($svS -ne $lvS) {
            $change = if ($null -eq $Live -or -not $Live.PSObject.Properties[$n]) { 'AddedSinceSnapshot/MissingLive' }
                      elseif ($null -eq $sv) { 'AddedLive' } else { 'Modified' }
            $result.Add([pscustomobject]@{
                Attribute     = $n
                SnapshotValue = $svS
                LiveValue     = $lvS
                Change        = $change
            })
        }
    }
    # Leading comma: keep the ARRAY shape even for a single diff. Without it PowerShell unrolls a
    # 1-element array to a scalar PSCustomObject, whose .Count is $null on PS 5.1 - which made
    # callers classify single-attribute changes as 'Unchanged'.
    return ,$result.ToArray()
}

# ----------------------------------------------------------------------------
# 4. COMPARISON snapshot <-> production
# ----------------------------------------------------------------------------
function Compare-HYCUADObjects {
    <#
    .SYNOPSIS
      Compares the snapshot objects with production AD.

    .DESCRIPTION
      Classifies each object: 'Deleted'  (present in the snapshot, absent in production),
                              'Modified' (present on both sides, attributes differ),
                              'Unchanged'.
      Matching is by objectGUID (stable, independent of the DN).

    .OUTPUTS  A list of diff objects usable by the UI or the restore functions.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [string]$LiveServer,                                  # live DC; default = current domain
        [string]$SearchBase,                                  # default = snapshot NC
        [string]$LdapFilter = '(|(objectClass=user)(objectClass=group)(objectClass=computer)(objectClass=organizationalUnit)(objectClass=groupPolicyContainer))',
        [ValidateSet('Deleted','Modified','Unchanged','All')][string[]]$Include = @('Deleted','Modified'),
        [System.Management.Automation.PSCredential]$LiveCredential
    )
    $base = if ($SearchBase) { $SearchBase } else { $Session.BaseDN }
    if (-not $LiveServer) { $LiveServer = ([ADSI]"LDAP://RootDSE").dnsHostName }
    Write-HYCULog "Comparison snapshot ($($Session.Server)) <-> live ($LiveServer), base=$base"

    # Load ALL attributes on both sides in a single query each (no property filter):
    # the comparison is then done entirely in memory. This removes the N+1 problem
    # (previously: 2 Base LDAP queries per common object).
    $snap = @(Get-LdapEntries -Server $Session.Server -BaseDN $base -Filter $LdapFilter)
    $live = @()
    try { $live = @(Get-LdapEntries -Server $LiveServer -BaseDN $base -Filter $LdapFilter -Credential $LiveCredential) }
    catch { Write-HYCULog "Could not read production ($LiveServer): $_" 'ERROR' }
    Write-HYCULog ("Read {0} snapshot object(s) and {1} production object(s) for the scan." -f $snap.Count, $live.Count)
    if ($snap.Count -eq 0) { Write-HYCULog "The snapshot returned 0 objects for filter '$LdapFilter' under $base - the scan cannot find changes." 'WARN' }
    if ($live.Count -eq 0) { Write-HYCULog "Production returned 0 objects - every snapshot object will be reported as Deleted; check the production DC / credentials / base ($base)." 'WARN' }

    # Index live objects by GUID
    $liveByGuid = @{}
    foreach ($o in $live) {
        try { $guidKey = (New-Object Guid (,[byte[]]$o.objectGUID)).ToString() } catch { continue }
        $liveByGuid[$guidKey] = $o
    }

    $diffs = New-Object System.Collections.Generic.List[object]
    foreach ($s in $snap) {
        $guid = $null
        try { $guid = (New-Object Guid (,[byte[]]$s.objectGUID)).ToString() } catch { continue }
        $dn   = [string]$s.distinguishedName
        $name = [string]$s.name
        $sCls = (@($s.objectClass) | Select-Object -Last 1)
        # Show a GPO by its friendly displayName rather than its {GUID} cn.
        if ($sCls -eq 'groupPolicyContainer' -and $s.PSObject.Properties['displayName'] -and [string]$s.displayName) { $name = [string]$s.displayName }

        if (-not $liveByGuid.ContainsKey($guid)) {
            $status = 'Deleted'
            $attrDiffs = @()
        } else {
            # In-memory diff from the two already-loaded attribute bags (no LDAP query here).
            $attrDiffs = @(Compare-HYCUADAttributeBag -Snapshot $s -Live $liveByGuid[$guid])
            $status = if ($attrDiffs.Count -gt 0) { 'Modified' } else { 'Unchanged' }
        }

        if ($Include -contains 'All' -or $Include -contains $status) {
            $diffs.Add([pscustomobject]@{
                Name             = $name
                ObjectClass      = $sCls
                SamAccountName   = [string]$s.sAMAccountName
                DistinguishedName= $dn
                ObjectGUID       = $guid
                Status           = $status
                AttributeDiffs   = $attrDiffs
                ChangedCount     = $attrDiffs.Count
            })
        }
    }
    Write-HYCULog ("Comparison finished: {0} object(s) retained." -f $diffs.Count) 'SUCCESS'
    return $diffs.ToArray()
}

function Get-HYCUADSubtreeChanges {
    <#
    .SYNOPSIS
      Lists everything Deleted/Modified under ONE container/OU, ordered parents-first.
    .DESCRIPTION
      Scoped wrapper around Compare-HYCUADObjects for whole-subtree recovery ("the OU Sales was
      deleted"): scans only the given base, keeps Deleted/Modified, and sorts by DN depth so a bulk
      restore recreates parents (the OU) before their children. Feed the result to
      Invoke-HYCUADBulkRestore (or the GUI cart) as-is. Read-only.
    .EXAMPLE
      $items = Get-HYCUADSubtreeChanges -Session $s -BaseDN 'OU=Sales,DC=corp,DC=local' -LiveServer dc01
      Invoke-HYCUADBulkRestore -Session $s -Items $items -LiveServer dc01 -WhatIf
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [Parameter(Mandatory)][string]$BaseDN,
        [string]$LiveServer,
        [System.Management.Automation.PSCredential]$LiveCredential
    )
    $p = @{ Session = $Session; SearchBase = $BaseDN; Include = @('Deleted','Modified') }
    if ($LiveServer)     { $p['LiveServer']     = $LiveServer }
    if ($LiveCredential) { $p['LiveCredential'] = $LiveCredential }
    $diffs = @(Compare-HYCUADObjects @p)
    # Parents first: shorter DNs (fewer RDN components) restore before their children.
    $sorted = @($diffs | Sort-Object -Property @{ Expression = { @($_.DistinguishedName -split '(?<!\\),').Count } })
    Write-HYCULog ("Subtree scan of {0}: {1} change(s), ordered parents-first." -f $BaseDN, $sorted.Count)
    return $sorted
}

function Compare-HYCUADSnapshots {
    <#
    .SYNOPSIS
      Compares TWO mounted snapshots (e.g. two restore points) - "when did this change?".
    .DESCRIPTION
      Both sessions come from Connect-HYCUADSnapshot (each ntds.dit is mounted on its own dsamain
      port). Objects are matched by objectGUID and classified from the REFERENCE (older) snapshot's
      perspective: 'OnlyInReference' (existed then, gone in the difference snapshot), 'Modified'
      (attributes differ - AttributeDiffs lists them), 'OnlyInDifference' (created since), 'Unchanged'.
    .EXAMPLE
      $a = Connect-HYCUADSnapshot -SourcePath $ntdsOld ; $b = Connect-HYCUADSnapshot -SourcePath $ntdsNew
      Compare-HYCUADSnapshots -ReferenceSession $a -DifferenceSession $b
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$ReferenceSession,
        [Parameter(Mandatory)][pscustomobject]$DifferenceSession,
        [string]$LdapFilter = '(|(objectClass=user)(objectClass=group)(objectClass=computer)(objectClass=organizationalUnit)(objectClass=groupPolicyContainer))',
        [ValidateSet('OnlyInReference','OnlyInDifference','Modified','Unchanged','All')][string[]]$Include = @('OnlyInReference','OnlyInDifference','Modified')
    )
    $refObjs  = @(Get-LdapEntries -Server $ReferenceSession.Server  -BaseDN $ReferenceSession.BaseDN  -Filter $LdapFilter)
    $diffObjs = @(Get-LdapEntries -Server $DifferenceSession.Server -BaseDN $DifferenceSession.BaseDN -Filter $LdapFilter)
    Write-HYCULog ("Snapshot compare: {0} object(s) in the reference, {1} in the difference." -f $refObjs.Count, $diffObjs.Count)

    $byGuid = @{}
    foreach ($o in $diffObjs) {
        try { $byGuid[(New-Object Guid (,[byte[]]$o.objectGUID)).ToString()] = $o } catch { continue }
    }
    $rows = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($r in $refObjs) {
        $guid = $null
        try { $guid = (New-Object Guid (,[byte[]]$r.objectGUID)).ToString() } catch { continue }
        $seen[$guid] = $true
        if (-not $byGuid.ContainsKey($guid)) { $status = 'OnlyInReference'; $attrDiffs = @() }
        else {
            $attrDiffs = @(Compare-HYCUADAttributeBag -Snapshot $r -Live $byGuid[$guid])
            $status = if ($attrDiffs.Count -gt 0) { 'Modified' } else { 'Unchanged' }
        }
        if ($Include -contains 'All' -or $Include -contains $status) {
            $rows.Add([pscustomobject]@{
                Name = [string]$r.name; ObjectClass = (@($r.objectClass) | Select-Object -Last 1)
                DistinguishedName = [string]$r.distinguishedName; ObjectGUID = $guid
                Status = $status; AttributeDiffs = @($attrDiffs); ChangedCount = @($attrDiffs).Count
            })
        }
    }
    if ($Include -contains 'All' -or $Include -contains 'OnlyInDifference') {
        foreach ($kv in $byGuid.GetEnumerator()) {
            if ($seen.ContainsKey($kv.Key)) { continue }
            $o = $kv.Value
            $rows.Add([pscustomobject]@{
                Name = [string]$o.name; ObjectClass = (@($o.objectClass) | Select-Object -Last 1)
                DistinguishedName = [string]$o.distinguishedName; ObjectGUID = $kv.Key
                Status = 'OnlyInDifference'; AttributeDiffs = @(); ChangedCount = 0
            })
        }
    }
    Write-HYCULog ("Snapshot compare finished: {0} row(s) retained." -f $rows.Count) 'SUCCESS'
    return $rows.ToArray()
}

function Get-HYCUADObjectDiff {
    <#
    .SYNOPSIS  Attribute-by-attribute diff of one object between snapshot and production.
    .OUTPUTS   A list of { Attribute, SnapshotValue, LiveValue, Change }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [string]$LiveServer,
        [Parameter(Mandatory)][string]$SnapshotDN,
        [string]$LiveDN,
        [System.Management.Automation.PSCredential]$LiveCredential
    )
    if (-not $LiveServer) { $LiveServer = ([ADSI]"LDAP://RootDSE").dnsHostName }
    if (-not $LiveDN) { $LiveDN = $SnapshotDN }

    $snap = Get-LdapEntries -Server $Session.Server -BaseDN $SnapshotDN -Scope Base | Select-Object -First 1
    $live = Get-LdapEntries -Server $LiveServer -BaseDN $LiveDN -Scope Base -Credential $LiveCredential | Select-Object -First 1
    if (-not $snap) { return @() }
    return (Compare-HYCUADAttributeBag -Snapshot $snap -Live $live)
}

# ----------------------------------------------------------------------------
# Browse helpers: navigate the mounted database like dsa.msc (tree + attributes).
# ----------------------------------------------------------------------------
$script:HYCUADContainerClasses = @('domainDNS','organizationalUnit','container','builtinDomain',
    'lostAndFound','msDS-QuotaContainer','configuration','dMD','rIDManager','dfsConfiguration')

function ConvertTo-HYCUADReadableValue {
    # Renders an LDAP attribute value for display (decodes the common binary attributes).
    param([string]$Name, $Value)
    (@($Value) | ForEach-Object {
        if ($_ -is [byte[]]) {
            switch ($Name) {
                'objectGUID' { try { (New-Object Guid (,[byte[]]$_)).ToString() } catch { '<guid>' } }
                'objectSid'  { try { (New-Object System.Security.Principal.SecurityIdentifier($_,0)).Value } catch { '<sid>' } }
                default      { '<binary ' + $_.Length + ' bytes>' }
            }
        } else { [string]$_ }
    }) -join ' | '
}

function Get-HYCUADChildNodes {
    <#
    .SYNOPSIS  Lists the immediate children of a container in the mounted snapshot (for a lazy tree).
    .OUTPUTS   { Name, ObjectClass, DistinguishedName, SamAccountName, IsContainer } sorted dsa.msc-style.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Session, [Parameter(Mandatory)][string]$BaseDN)
    $entries = Get-LdapEntries -Server $Session.Server -BaseDN $BaseDN -Scope OneLevel `
                 -Properties @('name','objectClass','distinguishedName','sAMAccountName','displayName')
    $nodes = foreach ($e in $entries) {
        $cls = (@($e.objectClass) | Select-Object -Last 1)
        $dn  = [string]$e.distinguishedName
        $nm  = [string]$e.name
        if (-not $nm -and $dn) { $nm = (($dn -split '(?<!\\),')[0] -replace '^[A-Za-z]+=','') }
        # A Group Policy object is named by its {GUID} (unreadable) - show its friendly displayName
        # instead; the GUID stays in the DN, which the restore uses.
        if ($cls -eq 'groupPolicyContainer' -and [string]$e.displayName) { $nm = [string]$e.displayName }
        [pscustomobject]@{
            Name              = $nm
            ObjectClass       = $cls
            DistinguishedName = $dn
            SamAccountName    = [string]$e.sAMAccountName
            IsContainer       = [bool]($script:HYCUADContainerClasses -contains $cls)
        }
    }
    @($nodes | Sort-Object @{ Expression = { -not $_.IsContainer } }, Name)
}

function Get-HYCUADObjectAttributes {
    <#
    .SYNOPSIS  Returns all attributes of one snapshot object as display rows (for the browse panel).
    .OUTPUTS   { Attribute, SnapshotValue, ProductionValue='' } sorted by attribute name.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Session, [Parameter(Mandatory)][string]$DistinguishedName)
    $o = Get-LdapEntries -Server $Session.Server -BaseDN $DistinguishedName -Scope Base | Select-Object -First 1
    if (-not $o) { return @() }
    $rows = foreach ($p in $o.PSObject.Properties) {
        if ($p.Name -eq 'adspath') { continue }
        [pscustomobject]@{
            Attribute       = $p.Name
            SnapshotValue   = (ConvertTo-HYCUADReadableValue -Name $p.Name -Value $p.Value)
            ProductionValue = ''
            Diff            = ''        # so the grid's 4th column + IsChanged RowStyle bind cleanly in browse mode
            IsChanged       = $false
        }
    }
    @($rows | Sort-Object Attribute)
}

function Get-HYCUADObjectComparison {
    <#
    .SYNOPSIS
      Compares ONE snapshot object (by DN) with production and returns a restore-compatible item -
      same shape as Compare-HYCUADObjects, so it can be added to the cart / restored directly.
    .NOTES  Live match is by DN (a moved object would read as 'Deleted'); the bulk scan matches by GUID.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [Parameter(Mandatory)][string]$DistinguishedName,
        [string]$LiveServer,
        [System.Management.Automation.PSCredential]$LiveCredential
    )
    if (-not $LiveServer) { $LiveServer = ([ADSI]"LDAP://RootDSE").dnsHostName }
    $snap = Get-LdapEntries -Server $Session.Server -BaseDN $DistinguishedName -Scope Base | Select-Object -First 1
    if (-not $snap) { return $null }
    $live = $null
    try { $live = Get-LdapEntries -Server $LiveServer -BaseDN $DistinguishedName -Scope Base -Credential $LiveCredential | Select-Object -First 1 } catch { $live = $null }

    $attrDiffs = Compare-HYCUADAttributeBag -Snapshot $snap -Live $live
    $status = if (-not $live) { 'Deleted' } elseif ($attrDiffs.Count -gt 0) { 'Modified' } else { 'Unchanged' }
    [pscustomobject]@{
        Name              = [string]$snap.name
        ObjectClass       = (@($snap.objectClass) | Select-Object -Last 1)
        SamAccountName    = [string]$snap.sAMAccountName
        DistinguishedName = $DistinguishedName
        ObjectGUID        = (ConvertTo-HYCUADReadableValue -Name 'objectGUID' -Value $snap.objectGUID)
        Status            = $status
        AttributeDiffs    = $attrDiffs
        ChangedCount      = $attrDiffs.Count
    }
}

function Get-HYCUADObjectComparisonRows {
    <#
    .SYNOPSIS
      Full side-by-side comparison of ONE object: EVERY attribute with its snapshot and production
      value, the changed ones flagged (using the proven Compare-HYCUADAttributeBag logic for the flag).
    .OUTPUTS
      { Exists, Status, ChangedCount, Rows[{Attribute,SnapshotValue,ProductionValue,Diff,IsChanged}], Item }
      where Item is restore-compatible (same shape as Compare-HYCUADObjects).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [Parameter(Mandatory)][string]$DistinguishedName,
        [string]$LiveServer,
        [System.Management.Automation.PSCredential]$LiveCredential
    )
    if (-not $LiveServer) { $LiveServer = ([ADSI]"LDAP://RootDSE").dnsHostName }
    $snap = Get-LdapEntries -Server $Session.Server -BaseDN $DistinguishedName -Scope Base | Select-Object -First 1
    if (-not $snap) { return $null }
    $live = $null
    try { $live = Get-LdapEntries -Server $LiveServer -BaseDN $DistinguishedName -Scope Base -Credential $LiveCredential | Select-Object -First 1 } catch { $live = $null }

    # Authoritative change set (sorted multi-value aware, operational attributes ignored).
    $diffBag = @(Compare-HYCUADAttributeBag -Snapshot $snap -Live $live)
    $diffMap = @{}; foreach ($d in $diffBag) { $diffMap[$d.Attribute] = $d.Change }

    $names = @($snap.PSObject.Properties.Name)
    if ($live) { $names += @($live.PSObject.Properties.Name) }
    $names = @($names | Where-Object { $_ -ne 'adspath' } | Sort-Object -Unique)

    $rows = foreach ($n in $names) {
        $sv = if ($snap.PSObject.Properties[$n]) { ConvertTo-HYCUADReadableValue -Name $n -Value $snap.$n } else { '' }
        $lv = if ($live -and $live.PSObject.Properties[$n]) { ConvertTo-HYCUADReadableValue -Name $n -Value $live.$n } else { '' }
        $changed = $diffMap.ContainsKey($n)
        $tag = if (-not $changed) { '' } else {
            switch ($diffMap[$n]) {
                'AddedLive'                       { 'added in prod' }
                'AddedSinceSnapshot/MissingLive'  { 'only in snapshot' }
                default                           { 'changed' }
            }
        }
        [pscustomobject]@{ Attribute = $n; SnapshotValue = $sv; ProductionValue = $lv; Diff = $tag; IsChanged = [bool]$changed }
    }
    $status = if (-not $live) { 'Deleted' } elseif ($diffBag.Count -gt 0) { 'Modified' } else { 'Unchanged' }
    [pscustomobject]@{
        Exists       = [bool]$live
        Status       = $status
        ChangedCount = $diffBag.Count
        Rows         = @($rows)
        Item         = [pscustomobject]@{
            Name              = [string]$snap.name
            ObjectClass       = (@($snap.objectClass) | Select-Object -Last 1)
            SamAccountName    = [string]$snap.sAMAccountName
            DistinguishedName = $DistinguishedName
            ObjectGUID        = (ConvertTo-HYCUADReadableValue -Name 'objectGUID' -Value $snap.objectGUID)
            Status            = $status
            AttributeDiffs    = $diffBag
            ChangedCount      = $diffBag.Count
        }
    }
}

# ----------------------------------------------------------------------------
# Safety: "undo" backup of the live state before a write
# ----------------------------------------------------------------------------
function Backup-HYCUADLiveObject {
    <#
    .SYNOPSIS  Exports the current LIVE state of an object to LDIF (undo file).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistinguishedName,
        [string]$LiveServer
    )
    $dir = Join-Path $script:HYCUADConfig.LogDirectory 'undo'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $safe = ($DistinguishedName -replace '[\\/:*?"<>|,= ]','_')
    $file = Join-Path $dir ("undo_{0}_{1:yyyyMMdd_HHmmss}.ldif" -f $safe.Substring(0,[Math]::Min(40,$safe.Length)), (Get-Date))
    $serverArg = if ($LiveServer) { @('-s', $LiveServer) } else { @() }
    & $script:HYCUADConfig.LdifdePath -f $file -d $DistinguishedName -p base @serverArg 2>&1 |
        ForEach-Object { Write-HYCULog $_ 'DEBUG' }
    $exit = $LASTEXITCODE
    # Only claim an undo exists if ldifde actually succeeded AND produced a non-empty file. Otherwise the
    # "rollback" would be a false promise before a production write (CLAUDE.md 8).
    if ($exit -eq 0 -and (Test-Path -LiteralPath $file) -and ((Get-Item -LiteralPath $file).Length -gt 0)) {
        Write-HYCULog "Undo backup written: $file" 'SUCCESS'
        return $file
    }
    Write-HYCULog "Undo LDIF backup FAILED for ${DistinguishedName} (ldifde exit $exit) - no reliable rollback file was produced; proceeding without an undo." 'WARN'
    return $null
}

# ----------------------------------------------------------------------------
# 5a. ATTRIBUTE restore
# ----------------------------------------------------------------------------
function Restore-HYCUADAttribute {
    <#
    .SYNOPSIS
      Restores one or more attributes of an existing object to their snapshot value.
    .DESCRIPTION
      Ideal for reverting a malicious change (phone number, UAC, addition to a
      privileged group, etc.). Automatic undo backup, -WhatIf support.
    .EXAMPLE
      Restore-HYCUADAttribute -Session $s -DistinguishedName $dn -Attribute telephoneNumber,description
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [Parameter(Mandatory)][string]$DistinguishedName,
        [Parameter(Mandatory)][string[]]$Attribute,
        [string]$LiveServer
    )
    Import-Module ActiveDirectory -ErrorAction Stop
    if (-not $LiveServer) { try { $LiveServer = [string]([ADSI]"LDAP://RootDSE").dnsHostName } catch {} }
    $snap = Get-LdapEntries -Server $Session.Server -BaseDN $DistinguishedName -Scope Base | Select-Object -First 1
    if (-not $snap) { throw "Object absent from the snapshot: $DistinguishedName" }

    foreach ($attr in $Attribute) {
        $value = if ($snap.PSObject.Properties[$attr]) { $snap.$attr } else { $null }
        $target = "{0} :: {1}" -f $DistinguishedName, $attr
        $valLabel = ConvertTo-HYCUADReadableValue -Name $attr -Value $value   # readable (byte[] -> hex/text, not 'System.Byte[]')
        if ($PSCmdlet.ShouldProcess($target, "Restore the snapshot value ('$valLabel')")) {
            Backup-HYCUADLiveObject -DistinguishedName $DistinguishedName -LiveServer $LiveServer | Out-Null
            try {
                if ($attr -eq 'description' -and $script:HYCUADConfig.DescriptionRestoreMode -ne 'Replace') {
                    # Operator request: in Append mode NEVER overwrite OR clear a live 'description' - it
                    # may hold notes added after the backup. Keep the live value and APPEND the backup
                    # value to it (skipping if already there, or if the backup had none). A recreated
                    # object has no live value, so this is simply the backup value. Handled before the
                    # null/clear branch on purpose, so a live description is preserved even when the backup
                    # had none. Set DescriptionRestoreMode='Replace' for the old overwrite behaviour.
                    $snapText = if ($null -eq $value) { '' } else { [string]$value }
                    $liveText = ''
                    try { $liveText = [string]((Get-ADObject -Identity $DistinguishedName -Properties description -Server $LiveServer -ErrorAction Stop).description) } catch {}
                    $newText  = if (-not $snapText)              { $liveText }
                                elseif (-not $liveText)          { $snapText }
                                elseif ($liveText -eq $snapText) { $liveText }
                                elseif ($liveText.Contains($snapText)) { $liveText }   # already appended
                                else { "$liveText | [backup] $snapText" }
                    if ($newText -ne $liveText) {
                        Set-ADObject -Identity $DistinguishedName -Replace @{ description = @($newText) } -Server $LiveServer -ErrorAction Stop
                        Write-HYCULog "Attribute 'description': live value kept, backup value appended (not overwritten) on $DistinguishedName." 'SUCCESS'
                    } else {
                        Write-HYCULog "Attribute 'description': left as-is (live already covers the backup value) on $DistinguishedName." 'INFO'
                    }
                } elseif ($null -eq $value) {
                    Set-ADObject -Identity $DistinguishedName -Clear $attr -Server $LiveServer -ErrorAction Stop
                    Write-HYCULog "Attribute '$attr' cleared (absent from snapshot) on $DistinguishedName." 'SUCCESS'
                } else {
                    # Keep a byte[] as ONE value; @() would split it into individual bytes.
                    $set = if ($value -is [byte[]]) { $value } else { @($value) }
                    Set-ADObject -Identity $DistinguishedName -Replace @{ $attr = $set } -Server $LiveServer -ErrorAction Stop
                    Write-HYCULog "Attribute '$attr' restored on $DistinguishedName." 'SUCCESS'
                }
            } catch { Write-HYCULog "Failed to restore '$attr': $_" 'ERROR' }
        }
    }
}

# ----------------------------------------------------------------------------
# 5b. GROUP MEMBERSHIP restore (backlinks)
# ----------------------------------------------------------------------------
function Update-HYCUADGroupMembership {
    <#
    .SYNOPSIS
      Realigns an object's group memberships to the snapshot state.
    .DESCRIPTION
      This is the "hard" part: 'memberOf' is a backlink attribute, so we act on the
      groups (the 'member' attribute, the forward-link). Adds the missing groups and,
      optionally, removes the groups added since (useful against a privilege
      escalation). -RemoveExtra removes the extra group memberships.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [Parameter(Mandatory)][string]$DistinguishedName,
        [string]$LiveDistinguishedName,     # live DN if it differs from the snapshot DN (e.g. restored into another OU)
        [switch]$RemoveExtra,
        [string]$LiveServer
    )
    Import-Module ActiveDirectory -ErrorAction Stop
    if (-not $LiveServer) { try { $LiveServer = [string]([ADSI]"LDAP://RootDSE").dnsHostName } catch {} }
    if (-not $LiveDistinguishedName) { $LiveDistinguishedName = $DistinguishedName }
    $snap = Get-LdapEntries -Server $Session.Server -BaseDN $DistinguishedName -Scope Base -Properties 'memberOf' | Select-Object -First 1
    $snapGroups = @($snap.memberOf)
    $liveObj = Get-ADObject -Identity $LiveDistinguishedName -Properties memberOf -Server $LiveServer
    $liveGroups = @($liveObj.memberOf)

    $toAdd    = $snapGroups | Where-Object { $_ -and ($liveGroups -notcontains $_) }
    $toRemove = $liveGroups | Where-Object { $_ -and ($snapGroups -notcontains $_) }

    foreach ($g in $toAdd) {
        if ($PSCmdlet.ShouldProcess($g, "Add $LiveDistinguishedName as a member")) {
            try { Add-ADGroupMember -Identity $g -Members $LiveDistinguishedName -Server $LiveServer -ErrorAction Stop
                  Write-HYCULog "Added to group: $g" 'SUCCESS' }
            catch { Write-HYCULog "Failed to add to group ${g}: $_" 'ERROR' }
        }
    }
    if ($RemoveExtra) {
        foreach ($g in $toRemove) {
            if ($PSCmdlet.ShouldProcess($g, "Remove $LiveDistinguishedName (absent from snapshot)")) {
                try { Remove-ADGroupMember -Identity $g -Members $LiveDistinguishedName -Server $LiveServer -Confirm:$false -ErrorAction Stop
                      Write-HYCULog "Removed from group: $g" 'SUCCESS' }
                catch { Write-HYCULog "Failed to remove from group ${g}: $_" 'ERROR' }
            }
        }
    } elseif ($toRemove) {
        Write-HYCULog ("{0} group(s) added since the snapshot are NOT removed (use -RemoveExtra)." -f @($toRemove).Count) 'WARN'
    }
}

# ----------------------------------------------------------------------------
# 5b-bis. AD RECYCLE BIN listing (READ-ONLY)
# ----------------------------------------------------------------------------
function Get-HYCUADRecycleBinObject {
    <#
    .SYNOPSIS
      Lists objects currently in the AD Recycle Bin (deleted but still reanimable). READ-ONLY.
    .DESCRIPTION
      Queries live Active Directory for deleted objects that Restore-ADObject could reanimate with the
      SID, password and linked attributes preserved. Lets an operator answer "is it still recoverable
      from the Recycle Bin?" in seconds, WITHOUT mounting a backup. Requires the ActiveDirectory module
      (RSAT) and the AD Recycle Bin optional feature enabled in the forest. Writes nothing.
    .OUTPUTS
      [pscustomobject] { Name, ObjectClass, LastKnownParent, Deleted, DistinguishedName, ObjectGUID }
    #>
    [CmdletBinding()]
    param(
        [string]$Server,
        [string]$Filter = '',                                   # optional name / sAMAccountName / last-RDN substring
        [System.Management.Automation.PSCredential]$Credential,
        [int]$MaxResults = 500
    )
    Import-Module ActiveDirectory -ErrorAction Stop
    if (-not $Server) { try { $Server = [string]([ADSI]"LDAP://RootDSE").dnsHostName } catch {} }
    $common = @{
        IncludeDeletedObjects = $true
        Properties            = @('lastKnownParent','msDS-LastKnownRDN','whenChanged','sAMAccountName','objectClass')
    }
    if ($Server)     { $common['Server']     = $Server }
    if ($Credential) { $common['Credential'] = $Credential }
    # A deleted object's 'name' carries a \0ADEL:<guid> suffix, so match on the last-known RDN / SAM instead.
    if ($Filter) {
        $esc = $Filter -replace '\\','\5c' -replace '\*','\2a' -replace '\(','\28' -replace '\)','\29'
        $common['LDAPFilter'] = "(&(isDeleted=TRUE)(|(msDS-LastKnownRDN=*$esc*)(sAMAccountName=*$esc*)))"
    } else {
        $common['LDAPFilter'] = '(isDeleted=TRUE)'
    }
    $res = @(Get-ADObject @common | Where-Object { $_.Deleted } | Select-Object -First $MaxResults)
    foreach ($o in $res) {
        $rdn = [string]$o.'msDS-LastKnownRDN'
        $nm  = if ($rdn) { $rdn } else { ([string]$o.Name) -replace '\\0ADEL:.*$','' }
        [pscustomobject]@{
            Name              = $nm
            ObjectClass       = (@($o.objectClass) | Select-Object -Last 1)
            LastKnownParent   = [string]$o.lastKnownParent
            Deleted           = $o.whenChanged
            DistinguishedName = [string]$o.DistinguishedName
            ObjectGUID        = [string]$o.ObjectGUID
        }
    }
}

# ----------------------------------------------------------------------------
# 5c. DELETED OBJECT restore
# ----------------------------------------------------------------------------
function Restore-HYCUADObject {
    <#
    .SYNOPSIS
      Restores a deleted object, favoring maximum fidelity.

    .DESCRIPTION
      Cascading strategy:
        1) AD RECYCLE BIN: if the object is still a tombstone in production and the
           AD Recycle Bin is enabled, Restore-ADObject reanimates it PRESERVING the SID,
           the password and the linked attributes. This is the best option.
        2) RECREATION from the snapshot: otherwise the object is recreated from the
           snapshot attributes (New-ADUser/New-ADComputer/New-ADGroup/New-ADObject),
           then the group memberships are reapplied.
           /!\ Limitation: a recreated object gets a NEW SID. As a best-effort bridge, the
               original SID is set as sIDHistory on the new object (RestoreSidHistory config,
               on by default) so old-SID access can follow - but this needs elevated rights
               and AD often blocks same-domain sIDHistory, so it may not take (see README).

    .EXAMPLE
      Restore-HYCUADObject -Session $s -DistinguishedName $dn
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [Parameter(Mandatory)][string]$DistinguishedName,
        [string]$LiveServer,
        [string]$TargetParentDN,     # optional: restore under THIS container/OU instead of the original parent
        [switch]$SkipRecycleBin
    )
    Import-Module ActiveDirectory -ErrorAction Stop
    if (-not $LiveServer) { try { $LiveServer = [string]([ADSI]"LDAP://RootDSE").dnsHostName } catch {} }
    $snap = Get-LdapEntries -Server $Session.Server -BaseDN $DistinguishedName -Scope Base | Select-Object -First 1
    if (-not $snap) { throw "Object absent from the snapshot: $DistinguishedName" }
    $guid = (New-Object Guid (,[byte[]]$snap.objectGUID)).ToString()
    $classes = @($snap.objectClass)
    $leafClass = $classes | Select-Object -Last 1
    # Where the object will actually live in production: its snapshot DN, or the redirected one.
    $rdn    = ($DistinguishedName -split '(?<!\\),',2)[0]
    $liveDN = if ($TargetParentDN) { "$rdn,$TargetParentDN" } else { $DistinguishedName }

    # --- Attempt 1: AD Recycle Bin ---
    if (-not $SkipRecycleBin) {
        try {
            # Look up by GUID via -Identity (reliable) rather than a -Filter string comparison on the binary
            # objectGUID; -Identity accepts the GUID and returns nothing (suppressed) if the object is gone.
            $deleted = Get-ADObject -Identity $guid -IncludeDeletedObjects -Server $LiveServer -ErrorAction SilentlyContinue
            if ($deleted -and $deleted.Deleted) {
                $reanimateLabel = if ($TargetParentDN) { "Reanimate via the AD Recycle Bin into $TargetParentDN (SID preserved)" }
                                  else { "Reanimate via the AD Recycle Bin (SID preserved)" }
                if ($PSCmdlet.ShouldProcess($DistinguishedName, $reanimateLabel)) {
                    $rp = @{}; if ($TargetParentDN) { $rp['TargetPath'] = $TargetParentDN }
                    Restore-ADObject -Identity $deleted.ObjectGUID -Server $LiveServer @rp -ErrorAction Stop
                    Write-HYCULog "Object reanimated from the AD Recycle Bin (SID preserved): $liveDN" 'SUCCESS'
                    # Realign the groups (the Recycle Bin restores the links, but we verify)
                    Update-HYCUADGroupMembership -Session $Session -DistinguishedName $DistinguishedName -LiveDistinguishedName $liveDN -LiveServer $LiveServer -Confirm:$false
                    return
                } else { return }
            }
        } catch { Write-HYCULog "AD Recycle Bin unavailable or object purged: $_" 'DEBUG' }
    }

    # --- Attempt 2: recreation from the snapshot ---
    Write-HYCULog "Recreation from the snapshot (new SID) for $DistinguishedName$(if ($TargetParentDN) { " into $TargetParentDN" })." 'WARN'
    $parentDN = if ($TargetParentDN) { $TargetParentDN } else { ($DistinguishedName -split '(?<!\\),',2)[1] }
    $cn = ([string]$snap.name)

    # Build the attribute set (excluding protected attributes/links)
    $otherAttrs = @{}
    foreach ($p in $snap.PSObject.Properties) {
        if ($script:HYCUADConfig.ProtectedAttributes -contains $p.Name) { continue }
        if ($null -ne $p.Value -and "$($p.Value)" -ne '') {
            $otherAttrs[$p.Name] = if ($p.Value -is [byte[]]) { $p.Value } else { @($p.Value) }   # keep byte[] whole
        }
    }
    # Remove attributes already carried by dedicated parameters (avoids "parameter specified more than once")
    foreach ($k in 'sAMAccountName','userPrincipalName','userAccountControl','groupType','name','cn','displayNamePrintable') {
        if ($otherAttrs.Contains($k)) { $otherAttrs.Remove($k) }
    }
    if ($PSCmdlet.ShouldProcess($DistinguishedName, "Recreate the object of class '$leafClass'")) {
        try {
            # 1) Create the object with ONLY its identity/dedicated attributes. Everything else is applied
            #    afterward (step 2), so that a single directory-rejected attribute (e.g. primaryGroupID -
            #    which needs the account to be a group member first - or any other system-owned value) cannot
            #    block the whole recreation.
            switch -Regex ($leafClass) {
                'user' {
                    $sam = [string]$snap.sAMAccountName
                    $upn = [string]$snap.userPrincipalName
                    $np = @{}; if ($upn) { $np['UserPrincipalName'] = $upn }
                    New-ADUser -Name $cn -SamAccountName $sam -Path $parentDN -Enabled $false -Server $LiveServer @np -ErrorAction Stop
                    Write-HYCULog "User recreated (disabled, re-enroll/reset the password): $sam" 'SUCCESS'
                }
                'computer' {
                    $sam = [string]$snap.sAMAccountName
                    New-ADComputer -Name $cn -SamAccountName $sam -Path $parentDN -Enabled $false -Server $LiveServer -ErrorAction Stop
                    Write-HYCULog "Computer recreated (re-join to the domain): $sam" 'SUCCESS'
                }
                'group' {
                    $sam = [string]$snap.sAMAccountName
                    $gt = 0; try { $gt = [int64]([string]$snap.groupType) } catch {}
                    $scope    = if ($gt -band 8) { 'Universal' } elseif ($gt -band 4) { 'DomainLocal' } else { 'Global' }
                    $category = if ($gt -band 2147483648) { 'Security' } else { 'Distribution' }
                    New-ADGroup -Name $cn -SamAccountName $sam -GroupScope $scope -GroupCategory $category -Path $parentDN -Server $LiveServer -ErrorAction Stop
                    Write-HYCULog "Group recreated ($scope/$category): $sam" 'SUCCESS'
                }
                'organizationalUnit' {
                    New-ADOrganizationalUnit -Name $cn -Path $parentDN -Server $LiveServer -ProtectedFromAccidentalDeletion $false -ErrorAction Stop
                    Write-HYCULog "OU recreated: $cn" 'SUCCESS'
                }
                default {
                    New-ADObject -Name $cn -Type $leafClass -Path $parentDN -Server $LiveServer -ErrorAction Stop
                    Write-HYCULog "Object ($leafClass) recreated: $cn" 'SUCCESS'
                }
            }
            # 2) Apply the remaining snapshot attributes. Try them all in one call; if the directory rejects
            #    the batch (one bad attribute fails the whole call), fall back to per-attribute so ONLY the
            #    offending one(s) are skipped and logged - the object keeps every attribute AD accepts. This
            #    ends the "one system-owned attribute aborts the whole recreation" problem.
            if ($otherAttrs.Count -gt 0) {
                try { Set-ADObject -Identity $liveDN -Server $LiveServer -Replace $otherAttrs -ErrorAction Stop }
                catch {
                    $skipped = @()
                    foreach ($k in @($otherAttrs.Keys)) {
                        try { Set-ADObject -Identity $liveDN -Server $LiveServer -Replace @{ $k = $otherAttrs[$k] } -ErrorAction Stop }
                        catch { $skipped += $k }
                    }
                    if ($skipped) { Write-HYCULog "Recreated ${cn}, but these attribute(s) were rejected by the directory and skipped: $($skipped -join ', ')." 'WARN' }
                }
            }
            # Best-effort: carry the ORIGINAL objectSid into sIDHistory on the recreated object, so access
            # (ACLs, group scoping) granted to the old SID keeps resolving. This needs elevated rights, and
            # AD generally BLOCKS adding a SAME-DOMAIN SID as history (by design) - so it is attempted and,
            # on failure, logged as a non-fatal WARN (the object is still recreated). Disable with
            # Set-HYCUADConfig -RestoreSidHistory $false.
            if ($script:HYCUADConfig.RestoreSidHistory -and ($leafClass -match 'user|computer|group|inetOrgPerson') `
                    -and $snap.PSObject.Properties['objectSid'] -and $snap.objectSid) {
                $oldSidBytes = [byte[]]$snap.objectSid
                $oldSid      = New-Object System.Security.Principal.SecurityIdentifier($oldSidBytes, 0)
                $sidDone = $false; $sidErr = ''
                # The AD provider expects a SecurityIdentifier for the SID-syntax sIDHistory; try that first,
                # then the raw bytes as a fallback (some builds accept the octet form).
                try { Set-ADObject -Identity $liveDN -Server $LiveServer -Add @{ sIDHistory = $oldSid } -ErrorAction Stop; $sidDone = $true }
                catch {
                    $sidErr = $_.Exception.Message
                    try { Set-ADObject -Identity $liveDN -Server $LiveServer -Add @{ sIDHistory = $oldSidBytes } -ErrorAction Stop; $sidDone = $true }
                    catch { $sidErr = $_.Exception.Message }
                }
                if ($sidDone) {
                    Write-HYCULog "sIDHistory set to the original SID ($($oldSid.Value)) on ${liveDN}: access granted to the old SID will follow." 'SUCCESS'
                } else {
                    Write-HYCULog "sIDHistory NOT set on ${liveDN} ($sidErr). This is EXPECTED for a SAME-DOMAIN restore: AD blocks adding a SID from the same domain as sIDHistory (by design) and there is no supported live way around it. To keep the original SID, restore from the AD Recycle Bin BEFORE the object is purged (done automatically when possible) or do an authoritative DC restore. Group memberships are re-applied regardless." 'WARN'
                }
            }
            # Reapply the group memberships
            if ($leafClass -match 'user|computer|group') {
                Update-HYCUADGroupMembership -Session $Session -DistinguishedName $DistinguishedName -LiveDistinguishedName $liveDN -LiveServer $LiveServer -Confirm:$false
            }
        } catch { Write-HYCULog "Failed to recreate ${DistinguishedName}: $_" 'ERROR'; throw }   # re-throw so the bulk restore records this object as failed (not silently 'finished')
    }
}

function Reset-HYCUADRecreatedAccount {
    <#
    .SYNOPSIS
      Post-recreation assistant: sets a fresh random password, forces a change at next logon,
      and enables the account - for each recreated (disabled) user.
    .DESCRIPTION
      Recreated users come back DISABLED with no usable password (by design). This finishes the job
      in one pass. Passwords are generated with a crypto RNG (16 chars, upper/lower/digit/symbol
      guaranteed) and returned IN THE RESULT ONLY so the operator can hand them over - they are
      NEVER written to the log or any report. Honors -WhatIf/-Confirm (ConfirmImpact High).
    .OUTPUTS
      [pscustomobject] { Identity, Ok, Message, Password } - Password is $null on failure/simulation.
    .EXAMPLE
      Reset-HYCUADRecreatedAccount -Identity 'CN=J Smith,OU=Users,DC=corp,DC=local' -Server dc01 -Confirm:$false
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
    param(
        [Parameter(Mandatory)][string[]]$Identity,     # DN(s) or sAMAccountName(s) of recreated users
        [string]$Server,
        [switch]$NoEnable                               # reset the password but leave the account disabled
    )
    Import-Module ActiveDirectory -ErrorAction Stop
    if (-not $Server) { try { $Server = [string]([ADSI]"LDAP://RootDSE").dnsHostName } catch {} }

    # Crypto-random password: 16 chars, at least one of each class, unambiguous charset.
    $newPassword = {
        $upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ'; $lower = 'abcdefghjkmnpqrstuvwxyz'
        $digit = '23456789'; $symbol = '!#%+=?@'
        $all   = $upper + $lower + $digit + $symbol
        $rng   = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        try {
            $pick = { param($set) $b = New-Object byte[] 4; $rng.GetBytes($b); $set[[BitConverter]::ToUInt32($b,0) % $set.Length] }
            $chars = @((& $pick $upper), (& $pick $lower), (& $pick $digit), (& $pick $symbol))
            while ($chars.Count -lt 16) { $chars += (& $pick $all) }
            # Shuffle so the guaranteed classes are not always in the same positions.
            -join ($chars | Sort-Object { $b = New-Object byte[] 4; $rng.GetBytes($b); [BitConverter]::ToUInt32($b,0) })
        } finally { $rng.Dispose() }
    }

    foreach ($id in $Identity) {
        $ok = $true; $msg = 'password reset' + $(if (-not $NoEnable) { ' + account enabled' }); $plain = $null
        try {
            if ($PSCmdlet.ShouldProcess($id, "Reset the password (random, change at next logon)$(if (-not $NoEnable) { ' and ENABLE the account' })")) {
                $plain = & $newPassword
                $sec   = ConvertTo-SecureString $plain -AsPlainText -Force
                Set-ADAccountPassword -Identity $id -Reset -NewPassword $sec -Server $Server -ErrorAction Stop
                Set-ADUser -Identity $id -ChangePasswordAtLogon $true -Server $Server -ErrorAction Stop
                if (-not $NoEnable) { Enable-ADAccount -Identity $id -Server $Server -ErrorAction Stop }
                # Deliberately NOT logging the password (CLAUDE.md par.6) - it exists only in the returned object.
                Write-HYCULog "Account ${id}: password reset (change at next logon)$(if (-not $NoEnable) { ', enabled' })." 'SUCCESS'
            } else { $ok = $true; $msg = 'skipped (simulation)'; $plain = $null }
        } catch {
            $ok = $false; $msg = $_.Exception.Message; $plain = $null
            Write-HYCULog "Account ${id}: post-recreation reset failed: $_" 'ERROR'
        }
        [pscustomobject]@{ Identity = $id; Ok = $ok; Message = $msg; Password = $plain }
    }
}

# ----------------------------------------------------------------------------
# 5d. LDIF EXPORT / IMPORT
# ----------------------------------------------------------------------------
function Export-HYCUADObjectToLdif {
    <#
    .SYNOPSIS  Exports an object (or a subtree) from the snapshot to an LDIF file.
    .DESCRIPTION  Produces an LDIF re-importable elsewhere via 'ldifde -i'.
    .EXAMPLE  Export-HYCUADObjectToLdif -Session $s -DistinguishedName $dn -Path C:\reco\user.ldif
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [Parameter(Mandatory)][string]$DistinguishedName,
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('Base','Subtree')][string]$Scope = 'Base'
    )
    $port = $Session.Port
    $scopeArg = if ($Scope -eq 'Subtree') { 'subtree' } else { 'base' }
    Write-HYCULog "LDIF export of $DistinguishedName -> $Path"
    & $script:HYCUADConfig.LdifdePath -f $Path -s localhost -t $port -d $DistinguishedName -p $scopeArg 2>&1 |
        ForEach-Object { Write-HYCULog $_ 'DEBUG' }
    if (Test-Path $Path) { Write-HYCULog "LDIF generated: $Path" 'SUCCESS'; return $Path }
    Write-HYCULog "Failed to generate the LDIF." 'ERROR'
}

function Import-HYCUADLdif {
    <#
    .SYNOPSIS  Imports an LDIF into production AD (ldifde -i), with logging.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$LiveServer,
        [switch]$IgnoreErrors
    )
    if (-not (Test-Path $Path)) { throw "LDIF file not found: $Path" }
    $logDir = Join-Path $script:HYCUADConfig.LogDirectory 'ldifde'
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $serverArg = if ($LiveServer) { @('-s', $LiveServer) } else { @() }
    $k = if ($IgnoreErrors) { @('-k') } else { @() }

    if ($PSCmdlet.ShouldProcess($Path, "Import into production AD")) {
        & $script:HYCUADConfig.LdifdePath -i -f $Path -j $logDir @serverArg @k 2>&1 |
            ForEach-Object { Write-HYCULog $_ 'DEBUG' }
        Write-HYCULog "LDIF import finished (logs: $logDir)." 'SUCCESS'
    }
}

# ----------------------------------------------------------------------------
# 5e. SYSVOL / GPO restore (file content, outside ntds.dit)
# ----------------------------------------------------------------------------
function Restore-HYCUADSysvolItem {
    <#
    .SYNOPSIS
      Restores a GPO's file content from the snapshot's SYSVOL.
    .DESCRIPTION
      The ntds.dit contains the GPO object (gPLink, versions) but NOT the policy
      content (Registry.pol files, scripts, ADMX...) which lives in SYSVOL.
      This function copies the Policies {GUID} folder from the SYSVOL restored by
      HYCU to the production SYSVOL.
    .EXAMPLE
      Restore-HYCUADSysvolItem -Session $s -PolicyGuid '{31B2F340-016D-11D2-945F-00C04FB984F9}' -Domain corp.local
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [Parameter(Mandatory)][string]$PolicyGuid,
        [Parameter(Mandatory)][string]$Domain,
        [string]$TargetSysvolPath
    )
    if (-not $Session.SysvolPath -or -not (Test-Path $Session.SysvolPath)) {
        throw "SYSVOL not available in the snapshot (re-run acquisition with -SysvolSourcePath)."
    }
    $src = Get-ChildItem -Path $Session.SysvolPath -Recurse -Directory -Filter $PolicyGuid -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $src) { throw "GPO $PolicyGuid not found in the snapshot's SYSVOL." }

    if (-not $TargetSysvolPath) { $TargetSysvolPath = "\\$Domain\SYSVOL\$Domain\Policies\$PolicyGuid" }
    if ($PSCmdlet.ShouldProcess($TargetSysvolPath, "Restore GPO content from $($src.FullName)")) {
        # Create the target Policies\{GUID} folder if the GPO was fully deleted (its SYSVOL folder is gone),
        # else Copy-Item fails. Copy per-child with -LiteralPath (safe against '[' ']' in paths); -Force
        # overwrites files present in both. Note: this restores the snapshot's content; it does NOT
        # mirror-delete files added in production since the snapshot.
        if (-not (Test-Path -LiteralPath $TargetSysvolPath)) { New-Item -ItemType Directory -Path $TargetSysvolPath -Force | Out-Null }
        Get-ChildItem -LiteralPath $src.FullName -Force | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $TargetSysvolPath -Recurse -Force
        }
        Write-HYCULog "GPO content $PolicyGuid restored to $TargetSysvolPath." 'SUCCESS'
    }
}

function Read-HYCUADRegistryPol {
    <#
    .SYNOPSIS
      Parses a Group Policy Registry.pol file (PReg format) into readable entries. READ-ONLY.
    .OUTPUTS
      [pscustomobject] { Key, ValueName, Type, TypeName, Data } per registry entry.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 8 -or [System.Text.Encoding]::ASCII.GetString($bytes, 0, 4) -ne 'PReg') {
        throw "'$Path' is not a Registry.pol file (missing PReg signature)."
    }
    $typeNames = @{ 1='REG_SZ'; 2='REG_EXPAND_SZ'; 3='REG_BINARY'; 4='REG_DWORD'; 7='REG_MULTI_SZ'; 11='REG_QWORD' }
    # Entries are [key;value;type;size;data] - brackets/semicolons as UTF-16LE chars, key/value are
    # null-terminated UTF-16LE strings, type/size are raw 4-byte little-endian DWORDs.
    $readString = {
        param([ref]$i)
        $start = $i.Value; $chars = New-Object System.Text.StringBuilder
        while ($i.Value + 1 -lt $bytes.Length) {
            $c = [BitConverter]::ToUInt16($bytes, $i.Value); $i.Value += 2
            if ($c -eq 0) { break }                             # null terminator
            if ($c -eq 0x3B -and $chars.Length -eq 0 -and $i.Value -eq $start + 2) { $i.Value -= 2; break }
            [void]$chars.Append([char]$c)
        }
        # Skip the field separator ';' if present.
        if ($i.Value + 1 -lt $bytes.Length -and [BitConverter]::ToUInt16($bytes, $i.Value) -eq 0x3B) { $i.Value += 2 }
        $chars.ToString()
    }
    $i = 8   # skip 'PReg' + version
    while ($i + 1 -lt $bytes.Length) {
        if ([BitConverter]::ToUInt16($bytes, $i) -ne 0x5B) { $i += 2; continue }   # find '['
        $i += 2
        $key  = & $readString ([ref]$i)
        $val  = & $readString ([ref]$i)
        if ($i + 4 -gt $bytes.Length) { break }
        $type = [BitConverter]::ToUInt32($bytes, $i); $i += 4
        if ([BitConverter]::ToUInt16($bytes, $i) -eq 0x3B) { $i += 2 }
        if ($i + 4 -gt $bytes.Length) { break }
        $size = [BitConverter]::ToUInt32($bytes, $i); $i += 4
        if ([BitConverter]::ToUInt16($bytes, $i) -eq 0x3B) { $i += 2 }
        if ($i + $size -gt $bytes.Length) { break }
        $data = New-Object byte[] $size
        if ($size -gt 0) { [Array]::Copy($bytes, $i, $data, 0, $size) }
        $i += $size
        if ($i + 1 -lt $bytes.Length -and [BitConverter]::ToUInt16($bytes, $i) -eq 0x5D) { $i += 2 }  # ']'
        $readable = switch ([int]$type) {
            1       { [System.Text.Encoding]::Unicode.GetString($data).TrimEnd([char]0) }
            2       { [System.Text.Encoding]::Unicode.GetString($data).TrimEnd([char]0) }
            7       { ([System.Text.Encoding]::Unicode.GetString($data).TrimEnd([char]0) -split [char]0) -join ' | ' }
            4       { if ($size -ge 4) { [BitConverter]::ToUInt32($data, 0) } else { 0 } }
            11      { if ($size -ge 8) { [BitConverter]::ToUInt64($data, 0) } else { 0 } }
            default { if ($size) { [BitConverter]::ToString($data) } else { '' } }
        }
        [pscustomobject]@{
            Key = $key; ValueName = $val; Type = [int]$type
            TypeName = $(if ($typeNames.Contains([int]$type)) { $typeNames[[int]$type] } else { "type $type" })
            Data = $readable
        }
    }
}

function Compare-HYCUADGpoContent {
    <#
    .SYNOPSIS
      Diffs the FILE content of a GPO between the snapshot's SYSVOL and production. READ-ONLY.
    .DESCRIPTION
      The AD compare only sees the groupPolicyContainer object; the actual settings live in SYSVOL.
      This parses the Machine/User Registry.pol on both sides (setting-level diff) and compares the
      other policy files by size (scripts, ADMX, GptTmpl.inf...). Provide either two {GUID} folder
      paths, or a mounted -Session + -PolicyGuid + -Domain to resolve them automatically.
    .OUTPUTS
      [pscustomobject] { Kind, Item, Detail, Status } - Status: OnlyInSnapshot / OnlyInProduction / Different.
    .EXAMPLE
      Compare-HYCUADGpoContent -Session $s -PolicyGuid '{31B2F340-016D-11D2-945F-00C04FB984F9}' -Domain corp.local
    #>
    [CmdletBinding()]
    param(
        [pscustomobject]$Session,
        [string]$PolicyGuid,
        [string]$Domain,
        [string]$SnapshotPolicyPath,     # {GUID} folder in the snapshot SYSVOL (overrides Session lookup)
        [string]$ProductionPolicyPath    # {GUID} folder in production (overrides \\domain\SYSVOL lookup)
    )
    if (-not $SnapshotPolicyPath) {
        if (-not ($Session -and $Session.SysvolPath -and $PolicyGuid)) { throw "Provide -SnapshotPolicyPath, or -Session (with SYSVOL) + -PolicyGuid." }
        $src = Get-ChildItem -Path $Session.SysvolPath -Recurse -Directory -Filter $PolicyGuid -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $src) { throw "GPO $PolicyGuid not found in the snapshot's SYSVOL." }
        $SnapshotPolicyPath = $src.FullName
    }
    if (-not $ProductionPolicyPath) {
        if (-not ($PolicyGuid -and $Domain)) { throw "Provide -ProductionPolicyPath, or -PolicyGuid + -Domain." }
        $ProductionPolicyPath = "\\$Domain\SYSVOL\$Domain\Policies\$PolicyGuid"
    }
    $rows = New-Object System.Collections.Generic.List[object]

    # 1) Setting-level diff of Machine\ and User\ Registry.pol.
    foreach ($side in 'Machine','User') {
        $sp = Join-Path $SnapshotPolicyPath   (Join-Path $side 'Registry.pol')
        $pp = Join-Path $ProductionPolicyPath (Join-Path $side 'Registry.pol')
        $se = if (Test-Path -LiteralPath $sp) { @(Read-HYCUADRegistryPol -Path $sp) } else { @() }
        $pe = if (Test-Path -LiteralPath $pp) { @(Read-HYCUADRegistryPol -Path $pp) } else { @() }
        $sIdx = @{}; foreach ($e in $se) { $sIdx["$($e.Key)|$($e.ValueName)"] = $e }
        $pIdx = @{}; foreach ($e in $pe) { $pIdx["$($e.Key)|$($e.ValueName)"] = $e }
        foreach ($k in $sIdx.Keys) {
            $item = "$side\$($sIdx[$k].Key)\$($sIdx[$k].ValueName)"
            if (-not $pIdx.Contains($k)) {
                $rows.Add([pscustomobject]@{ Kind='Setting'; Item=$item; Detail="snapshot: $($sIdx[$k].Data) ($($sIdx[$k].TypeName))"; Status='OnlyInSnapshot' })
            } elseif ("$($sIdx[$k].Data)" -ne "$($pIdx[$k].Data)") {
                $rows.Add([pscustomobject]@{ Kind='Setting'; Item=$item; Detail="snapshot: $($sIdx[$k].Data)  ->  production: $($pIdx[$k].Data)"; Status='Different' })
            }
        }
        foreach ($k in $pIdx.Keys) {
            if (-not $sIdx.Contains($k)) {
                $rows.Add([pscustomobject]@{ Kind='Setting'; Item="$side\$($pIdx[$k].Key)\$($pIdx[$k].ValueName)"; Detail="production: $($pIdx[$k].Data) ($($pIdx[$k].TypeName))"; Status='OnlyInProduction' })
            }
        }
    }

    # 2) File-level diff of everything else (scripts, GptTmpl.inf, ADMX...), by relative path + size.
    $list = {
        param($root)
        $m = @{}
        if (Test-Path -LiteralPath $root) {
            foreach ($f in @(Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue)) {
                $rel = $f.FullName.Substring($root.Length).TrimStart('\')
                if ($rel -notmatch '(?i)Registry\.pol$') { $m[$rel] = $f.Length }
            }
        }
        $m
    }
    $sf = & $list $SnapshotPolicyPath
    $pf = & $list $ProductionPolicyPath
    foreach ($k in $sf.Keys) {
        if (-not $pf.Contains($k))        { $rows.Add([pscustomobject]@{ Kind='File'; Item=$k; Detail="$($sf[$k]) bytes in the snapshot"; Status='OnlyInSnapshot' }) }
        elseif ($sf[$k] -ne $pf[$k])      { $rows.Add([pscustomobject]@{ Kind='File'; Item=$k; Detail="snapshot: $($sf[$k]) bytes  ->  production: $($pf[$k]) bytes"; Status='Different' }) }
    }
    foreach ($k in $pf.Keys) {
        if (-not $sf.Contains($k))        { $rows.Add([pscustomobject]@{ Kind='File'; Item=$k; Detail="$($pf[$k]) bytes in production"; Status='OnlyInProduction' }) }
    }
    Write-HYCULog ("GPO content compare: {0} difference(s)." -f $rows.Count)
    return $rows.ToArray()
}

# ----------------------------------------------------------------------------
# Bulk restore ("cart")
# ----------------------------------------------------------------------------
function Invoke-HYCUADBulkRestore {
    <#
    .SYNOPSIS  Processes a list of diff objects (the "cart") in one pass.
    .EXAMPLE
      $cart = $diffs | Where-Object Status -in 'Deleted','Modified'
      Invoke-HYCUADBulkRestore -Session $s -Items $cart -LiveServer dc01.corp.local
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [Parameter(Mandatory)][pscustomobject[]]$Items,
        [string]$LiveServer,
        [string]$TargetParentDN,     # optional: restore DELETED objects under this container/OU (quarantine / collision avoidance)
        [switch]$RemoveExtraGroups
    )
    $results = New-Object System.Collections.Generic.List[object]
    $tp = @{}; if ($TargetParentDN) { $tp['TargetParentDN'] = $TargetParentDN }
    $n = 0
    foreach ($it in $Items) {
        $n++
        Write-HYCULog "[$n/$($Items.Count)] $($it.Status): $($it.DistinguishedName)"
        $ok = $true; $msg = 'OK'
        try {
            switch ($it.Status) {
                'Deleted'  { Restore-HYCUADObject -Session $Session -DistinguishedName $it.DistinguishedName -LiveServer $LiveServer @tp -Confirm:$false | Out-Null
                             $msg = if ($TargetParentDN) { "restored into $TargetParentDN" } else { 'restored (reanimated from the Recycle Bin, or recreated)' } }
                'Modified' {
                    $attrs = @($it.AttributeDiffs | Where-Object { $_.Attribute -notin 'member','memberOf' } | Select-Object -Expand Attribute)
                    if ($attrs) { Restore-HYCUADAttribute -Session $Session -DistinguishedName $it.DistinguishedName -Attribute $attrs -LiveServer $LiveServer -Confirm:$false | Out-Null }
                    $syncedGroups = ($it.AttributeDiffs.Attribute -contains 'memberOf' -or $it.AttributeDiffs.Attribute -contains 'member')
                    if ($syncedGroups) {
                        Update-HYCUADGroupMembership -Session $Session -DistinguishedName $it.DistinguishedName -RemoveExtra:$RemoveExtraGroups -LiveServer $LiveServer -Confirm:$false | Out-Null
                    }
                    $msg = "updated ($(@($attrs).Count) attribute(s)$(if ($syncedGroups) { ' + group membership' } else { '' }))"
                }
                default { Write-HYCULog "Skipped (status $($it.Status))." 'DEBUG'; $msg = "skipped (status $($it.Status))" }
            }
            # A Group Policy object lives in TWO places: the AD object (restored above) AND its policy
            # files in SYSVOL (Registry.pol, scripts, ADMX...). Restoring the AD object alone leaves an
            # empty/stale GPO, so whenever a groupPolicyContainer is restored, also copy its {GUID} folder
            # from the snapshot SYSVOL back to production. Detected by the well-known GPO DN shape.
            if ($it.DistinguishedName -match '^CN=(\{[0-9A-Fa-f-]+\}),CN=Policies,CN=System,') {
                $gpoGuid = $matches[1]
                $gpoDom  = (@($it.DistinguishedName -split '(?<!\\),' | Where-Object { $_ -match '^DC=' }) -replace '^DC=','') -join '.'
                if ($Session.SysvolPath -and (Test-Path $Session.SysvolPath)) {
                    Restore-HYCUADSysvolItem -Session $Session -PolicyGuid $gpoGuid -Domain $gpoDom -Confirm:$false | Out-Null
                } else {
                    Write-HYCULog "GPO ${gpoGuid}: AD object restored, but SYSVOL was not captured with the snapshot - its policy files (Registry.pol, scripts...) were NOT restored. Re-run the retrieval with SYSVOL included." 'WARN'
                }
            }
        } catch { $ok = $false; $msg = "$($_.Exception.Message)"; Write-HYCULog "Error on $($it.DistinguishedName): $_" 'ERROR' }
        $results.Add([pscustomobject]@{ DistinguishedName = $it.DistinguishedName; Status = $it.Status; Ok = $ok; Message = $msg })
    }
    $succeeded = @($results | Where-Object Ok).Count
    $failed    = @($results | Where-Object { -not $_.Ok }).Count
    Write-HYCULog "Bulk restore finished: $succeeded succeeded, $failed failed (of $($Items.Count))." $(if ($failed) { 'WARN' } else { 'SUCCESS' })
    # NB: $results.ToArray(), not @($results) - wrapping a generic List in @() inside a [pscustomobject]
    # literal throws "the argument types do not match".
    [pscustomobject]@{ Total = $Items.Count; Succeeded = $succeeded; Failed = $failed; Details = $results.ToArray() }
}

function Export-HYCUADRestoreReport {
    <#
    .SYNOPSIS
      Writes a branded, standalone HTML report of a restore operation (audit / compliance trail).
    .DESCRIPTION
      Takes the object returned by Invoke-HYCUADBulkRestore ({Total,Succeeded,Failed,Details}) plus
      context (source snapshot, live server, simulation flag) and produces a timestamped, self-contained
      .html file (no external assets - HYCU-purple styling is inline). Best-effort: returns the path
      written, or $null on failure (never throws to the caller, so it can't break a completed restore).
    .OUTPUTS
      [string] full path of the report, or $null.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Result,      # from Invoke-HYCUADBulkRestore
        [string]$SnapshotSource = '',
        [string]$LiveServer = '',
        [bool]$Simulation = $false,
        [string]$Directory
    )
    try {
        if (-not $Directory) {
            $base = if ($script:HYCULogFile) { Split-Path -Parent $script:HYCULogFile }
                    else { Join-Path $env:ProgramData 'HYCU\ADRecoveryTool' }
            $Directory = Join-Path $base 'reports'
        }
        if (-not (Test-Path -LiteralPath $Directory)) { New-Item -ItemType Directory -Path $Directory -Force | Out-Null }
        $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $path  = Join-Path $Directory "HYCU_AD_restore_$stamp.html"

        # Minimal, dependency-free HTML escaper (System.Web is not guaranteed to be loaded).
        $esc = {
            param($s)
            ([string]$s).Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;')
        }
        $now      = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $operator = "$env:USERDOMAIN\$env:USERNAME"
        $host_    = $env:COMPUTERNAME
        $modeTxt  = if ($Simulation) { 'SIMULATION (-WhatIf, no changes written)' } else { 'LIVE restore (changes written to Active Directory)' }
        $modeCol  = if ($Simulation) { '#B45309' } else { '#15803D' }

        $rows = New-Object System.Text.StringBuilder
        foreach ($d in @($Result.Details)) {
            $ok    = [bool]$d.Ok
            $badge = if ($ok) { '<span class="ok">OK</span>' } else { '<span class="ko">FAILED</span>' }
            $rowc  = if ($ok) { '' } else { ' class="rowko"' }
            [void]$rows.AppendLine("      <tr$rowc><td>$badge</td><td>$(& $esc $d.Status)</td><td class='dn'>$(& $esc $d.DistinguishedName)</td><td>$(& $esc $d.Message)</td></tr>")
        }
        if (@($Result.Details).Count -eq 0) {
            [void]$rows.AppendLine("      <tr><td colspan='4' class='empty'>No objects were processed.</td></tr>")
        }

        $html = @"
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><title>HYCU AD Recovery - restore report $stamp</title>
<style>
 body{font-family:Segoe UI,Arial,sans-serif;margin:0;background:#F4F2FB;color:#1B0C33}
 .wrap{max-width:1100px;margin:0 auto;padding:24px}
 header{background:#43128E;color:#fff;border-radius:8px;padding:18px 22px;display:flex;align-items:center;gap:14px}
 header .logo{width:34px;height:34px;background:#5B18C0;border-radius:8px;display:flex;align-items:center;justify-content:center;font-weight:700;color:#fff}
 header h1{font-size:18px;margin:0;font-weight:600}
 header .sub{opacity:.8;font-size:12px;margin-top:2px}
 .mode{display:inline-block;color:#fff;border-radius:4px;padding:3px 10px;font-size:12px;font-weight:600;background:$modeCol}
 .cards{display:flex;gap:12px;margin:18px 0}
 .card{flex:1;background:#fff;border:1px solid #E3DEF5;border-radius:8px;padding:14px 16px}
 .card .n{font-size:26px;font-weight:700}
 .card.tot .n{color:#5B18C0}.card.ok .n{color:#15803D}.card.ko .n{color:#B91C1C}
 .card .l{font-size:12px;color:#6B6392;text-transform:uppercase;letter-spacing:.04em}
 table{width:100%;border-collapse:collapse;background:#fff;border:1px solid #E3DEF5;border-radius:8px;overflow:hidden}
 th{background:#EEEAFA;text-align:left;padding:8px 10px;font-size:12px;color:#43128E}
 td{padding:7px 10px;border-top:1px solid #EFECFA;font-size:13px;vertical-align:top}
 td.dn{font-family:Consolas,monospace;font-size:12px;color:#3E2480;word-break:break-all}
 tr.rowko td{background:#FEF2F2}
 .ok{color:#15803D;font-weight:700}.ko{color:#B91C1C;font-weight:700}
 .empty{color:#8B80C9;text-align:center;font-style:italic}
 .meta{background:#fff;border:1px solid #E3DEF5;border-radius:8px;padding:12px 16px;margin:18px 0;font-size:13px}
 .meta div{margin:3px 0}.meta b{display:inline-block;width:150px;color:#6B6392}
 footer{margin:18px 0;font-size:11px;color:#8B80C9;text-align:center}
</style></head><body><div class="wrap">
 <header><div class="logo">H</div><div>
   <h1>HYCU AD Recovery Tool - Restore Report</h1>
   <div class="sub">Active Directory object restore &bull; generated $now</div></div></header>
 <p style="margin:16px 0 4px"><span class="mode">$modeTxt</span></p>
 <div class="cards">
   <div class="card tot"><div class="n">$($Result.Total)</div><div class="l">Objects processed</div></div>
   <div class="card ok"><div class="n">$($Result.Succeeded)</div><div class="l">Succeeded</div></div>
   <div class="card ko"><div class="n">$($Result.Failed)</div><div class="l">Failed</div></div>
 </div>
 <div class="meta">
   <div><b>Operation</b> $modeTxt</div>
   <div><b>Date / time</b> $now</div>
   <div><b>Operator</b> $(& $esc $operator)</div>
   <div><b>Workstation</b> $(& $esc $host_)</div>
   <div><b>Snapshot source</b> $(& $esc $(if ($SnapshotSource) { $SnapshotSource } else { '(not specified)' }))</div>
   <div><b>Live directory</b> $(& $esc $(if ($LiveServer) { $LiveServer } else { '(default / current domain)' }))</div>
 </div>
 <table><thead><tr><th style="width:70px">Result</th><th style="width:110px">Type</th><th>Distinguished name</th><th>Details</th></tr></thead>
 <tbody>
$($rows.ToString())
 </tbody></table>
 <footer>Provided as-is, without warranty or engagement from HYCU. This report is a local audit record; do not email it if it contains sensitive directory data.</footer>
</div></body></html>
"@
        [System.IO.File]::WriteAllText($path, $html, (New-Object System.Text.UTF8Encoding($false)))
        Write-HYCULog "Restore report written: $path" 'INFO'
        return $path
    } catch {
        Write-HYCULog "Could not write the restore report: $_" 'WARN'
        return $null
    }
}

function Get-HYCUADReportDirectory {
    # Shared resolution for all HTML reports: next to the run log, else ProgramData.
    param([string]$Directory)
    if (-not $Directory) {
        $base = if ($script:HYCULogFile) { Split-Path -Parent $script:HYCULogFile }
                else { Join-Path $env:ProgramData 'HYCU\ADRecoveryTool' }
        $Directory = Join-Path $base 'reports'
    }
    if (-not (Test-Path -LiteralPath $Directory)) { New-Item -ItemType Directory -Path $Directory -Force | Out-Null }
    $Directory
}

function Test-HYCUADSnapshotHealth {
    <#
    .SYNOPSIS
      Restorability check of a retrieved AD database: is this backup actually usable?
    .DESCRIPTION
      Takes an NTDS folder already retrieved from a backup (Start-HYCUFileLevelRestore output, or any
      staged copy) and PROVES it is restorable: esentutl state check, real dsamain mount, object
      counts over LDAP, then dismount. Writes a PASS/FAIL HTML report. Read-only for production AD -
      nothing is written to the directory. Schedule it (with the retrieval) to continuously verify
      that AD backups are usable BEFORE the day they are needed - see the README recipe.
    .OUTPUTS
      [pscustomobject] { Ok, StateText, Users, Computers, Groups, OUs, Total, ReportPath, Error }
    .EXAMPLE
      $ntds = Start-HYCUFileLevelRestore -Session $h -Vm $vm -RestorePoint $rp -TargetUnc \\nas\stage ...
      Test-HYCUADSnapshotHealth -SourcePath $ntds
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourcePath,      # folder containing ntds.dit (+ edb logs)
        [string]$ReportDirectory,
        [string]$BackupLabel = ''                        # free text shown in the report (VM, restore point date...)
    )
    $result = [ordered]@{ Ok = $false; StateText = ''; Users = 0; Computers = 0; Groups = 0; OUs = 0; Total = 0; ReportPath = $null; Error = $null }
    $session = $null
    try {
        $dit = Join-Path $SourcePath 'ntds.dit'
        if (-not (Test-Path -LiteralPath $dit)) { throw "ntds.dit not found under $SourcePath." }
        $state = Test-HYCUADDatabaseState -DitPath $dit
        $result.StateText = [string]$state.StateText
        Write-HYCULog "Restorability check: database state = $($state.StateText)."
        $session = Connect-HYCUADSnapshot -SourcePath $SourcePath
        foreach ($c in @(@{K='Users';F='(&(objectClass=user)(!(objectClass=computer)))'}, @{K='Computers';F='(objectClass=computer)'},
                         @{K='Groups';F='(objectClass=group)'}, @{K='OUs';F='(objectClass=organizationalUnit)'})) {
            $result[$c.K] = @(Get-LdapEntries -Server $session.Server -BaseDN $session.BaseDN -Filter $c.F -Properties @('name')).Count
        }
        $result.Total = $result.Users + $result.Computers + $result.Groups + $result.OUs
        if ($result.Total -le 0) { throw "The database mounted but returned 0 objects - not usable." }
        $result.Ok = $true
        Write-HYCULog ("Restorability check PASSED: {0} users, {1} computers, {2} groups, {3} OUs readable." -f $result.Users, $result.Computers, $result.Groups, $result.OUs) 'SUCCESS'
    } catch {
        $result.Error = $_.Exception.Message
        Write-HYCULog "Restorability check FAILED: $_" 'ERROR'
    } finally {
        if ($session) { try { Dismount-HYCUADSnapshot -Session $session } catch {} }
    }
    # PASS/FAIL report (best-effort).
    try {
        $dir   = Get-HYCUADReportDirectory -Directory $ReportDirectory
        $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $path  = Join-Path $dir "HYCU_AD_restorability_$stamp.html"
        $now   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $badge = if ($result.Ok) { '<span style="background:#15803D;color:#fff;padding:4px 14px;border-radius:4px;font-weight:700">PASS - this backup is restorable</span>' }
                 else            { '<span style="background:#B91C1C;color:#fff;padding:4px 14px;border-radius:4px;font-weight:700">FAIL - this backup did NOT mount</span>' }
        $esc = { param($s) ([string]$s).Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;') }
        $html = @"
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><title>AD backup restorability - $stamp</title>
<style>body{font-family:Segoe UI,Arial,sans-serif;background:#F4F2FB;color:#1B0C33;margin:0}
.wrap{max-width:820px;margin:0 auto;padding:24px}
header{background:#43128E;color:#fff;border-radius:8px;padding:16px 20px}h1{font-size:17px;margin:0}
table{width:100%;border-collapse:collapse;background:#fff;border:1px solid #E3DEF5;margin-top:16px}
td,th{padding:8px 10px;border-top:1px solid #EFECFA;text-align:left;font-size:13px}th{background:#EEEAFA;color:#43128E}
footer{margin:16px 0;font-size:11px;color:#8B80C9;text-align:center}</style></head><body><div class="wrap">
<header><h1>HYCU AD Recovery Tool - Backup restorability check</h1></header>
<p style="margin:18px 0">$badge</p>
<table>
<tr><th>Checked at</th><td>$now</td></tr>
<tr><th>Backup</th><td>$(& $esc $(if ($BackupLabel) { $BackupLabel } else { $SourcePath }))</td></tr>
<tr><th>Database state</th><td>$(& $esc $result.StateText)</td></tr>
<tr><th>Users readable</th><td>$($result.Users)</td></tr>
<tr><th>Computers readable</th><td>$($result.Computers)</td></tr>
<tr><th>Groups readable</th><td>$($result.Groups)</td></tr>
<tr><th>OUs readable</th><td>$($result.OUs)</td></tr>
$(if ($result.Error) { "<tr><th>Error</th><td>$(& $esc $result.Error)</td></tr>" })
</table>
<footer>Generated by the HYCU AD Recovery Tool. A PASS means the database was actually mounted and read - not just that a backup file exists.</footer>
</div></body></html>
"@
        [System.IO.File]::WriteAllText($path, $html, (New-Object System.Text.UTF8Encoding($false)))
        $result.ReportPath = $path
        Write-HYCULog "Restorability report written: $path"
    } catch { Write-HYCULog "Could not write the restorability report: $_" 'WARN' }
    [pscustomobject]$result
}

function Export-HYCUADDriftReport {
    <#
    .SYNOPSIS
      Drift report: what changed in production AD since the (mounted) backup - as a standalone HTML file.
    .DESCRIPTION
      Runs the proven snapshot<->production comparison and renders the Deleted/Modified objects into a
      branded HTML report. Schedule it after a nightly retrieval to get a morning drift digest - see
      the README recipe. Read-only.
    .OUTPUTS  [string] the report path.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [string]$LiveServer,
        [string]$SearchBase,
        [string]$ReportDirectory,
        [System.Management.Automation.PSCredential]$LiveCredential
    )
    $p = @{ Session = $Session; Include = @('Deleted','Modified') }
    if ($LiveServer)     { $p['LiveServer']     = $LiveServer }
    if ($SearchBase)     { $p['SearchBase']     = $SearchBase }
    if ($LiveCredential) { $p['LiveCredential'] = $LiveCredential }
    $diffs = @(Compare-HYCUADObjects @p)
    $deleted  = @($diffs | Where-Object { $_.Status -eq 'Deleted' })
    $modified = @($diffs | Where-Object { $_.Status -eq 'Modified' })

    $dir   = Get-HYCUADReportDirectory -Directory $ReportDirectory
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $path  = Join-Path $dir "HYCU_AD_drift_$stamp.html"
    $now   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $esc   = { param($s) ([string]$s).Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;') }
    $rows  = New-Object System.Text.StringBuilder
    foreach ($d in ($deleted + $modified)) {
        $chg = if ($d.Status -eq 'Modified') { (@($d.AttributeDiffs | Select-Object -First 8 | ForEach-Object { $_.Attribute }) -join ', ') + $(if (@($d.AttributeDiffs).Count -gt 8) { ', ...' }) } else { 'object absent from production' }
        $col = if ($d.Status -eq 'Deleted') { '#B91C1C' } else { '#B45309' }
        [void]$rows.AppendLine("<tr><td style='color:$col;font-weight:700'>$($d.Status)</td><td>$(& $esc $d.Name)</td><td>$(& $esc $d.ObjectClass)</td><td style='font-family:Consolas,monospace;font-size:12px'>$(& $esc $d.DistinguishedName)</td><td>$(& $esc $chg)</td></tr>")
    }
    if (-not ($deleted.Count + $modified.Count)) { [void]$rows.AppendLine("<tr><td colspan='5' style='text-align:center;color:#15803D;font-weight:600'>No drift - production matches the backup.</td></tr>") }
    $html = @"
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><title>AD drift report - $stamp</title>
<style>body{font-family:Segoe UI,Arial,sans-serif;background:#F4F2FB;color:#1B0C33;margin:0}
.wrap{max-width:1100px;margin:0 auto;padding:24px}
header{background:#43128E;color:#fff;border-radius:8px;padding:16px 20px}h1{font-size:17px;margin:0}
.cards{display:flex;gap:12px;margin:16px 0}.card{flex:1;background:#fff;border:1px solid #E3DEF5;border-radius:8px;padding:12px 16px}
.card b{font-size:24px;display:block}.card span{font-size:12px;color:#6B6392;text-transform:uppercase}
table{width:100%;border-collapse:collapse;background:#fff;border:1px solid #E3DEF5}
td,th{padding:7px 10px;border-top:1px solid #EFECFA;text-align:left;font-size:13px;vertical-align:top}th{background:#EEEAFA;color:#43128E}
footer{margin:16px 0;font-size:11px;color:#8B80C9;text-align:center}</style></head><body><div class="wrap">
<header><h1>HYCU AD Recovery Tool - Drift report (production vs backup)</h1></header>
<div class="cards">
 <div class="card"><b style="color:#B91C1C">$($deleted.Count)</b><span>Deleted since the backup</span></div>
 <div class="card"><b style="color:#B45309">$($modified.Count)</b><span>Modified since the backup</span></div>
 <div class="card"><b style="color:#5B18C0">$now</b><span>Generated</span></div>
</div>
<table><thead><tr><th>Status</th><th>Name</th><th>Class</th><th>Distinguished name</th><th>Changed attributes</th></tr></thead><tbody>
$($rows.ToString())
</tbody></table>
<footer>Generated by the HYCU AD Recovery Tool. Deleted/Modified are relative to the mounted backup; use the GUI or Invoke-HYCUADBulkRestore to roll changes back.</footer>
</div></body></html>
"@
    [System.IO.File]::WriteAllText($path, $html, (New-Object System.Text.UTF8Encoding($false)))
    Write-HYCULog "Drift report written: $path ($($deleted.Count) deleted, $($modified.Count) modified)." 'SUCCESS'
    return $path
}

# ----------------------------------------------------------------------------
# NB: exported functions are driven by the manifest (HYCUADRecovery.psd1,
# FunctionsToExport key). We do NOT call Export-ModuleMember here: in a root
# module, that call would override the exports of the nested modules (HYCUClient,
# HYCUSecrets). The manifest filters the whole set of functions (root + nested).
# For use outside the manifest (direct .psm1 import), everything stays accessible.
