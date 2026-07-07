<#
 Pester tests (Pester 3.4-compatible - ships with Windows) for the AD engine.
 Run: Invoke-Pester -Path .\Tests
#>
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here '..\HYCUADRecovery.psm1') -Force

Describe 'Compare-HYCUADAttributeBag' {

    It 'returns no difference for identical bags' {
        $a = [pscustomobject]@{ name='x'; description='d'; mail='a@b' }
        $b = [pscustomobject]@{ name='x'; description='d'; mail='a@b' }
        (Compare-HYCUADAttributeBag -Snapshot $a -Live $b).Count | Should Be 0
    }

    It 'detects a modified attribute' {
        $a = [pscustomobject]@{ description='old' }
        $b = [pscustomobject]@{ description='new' }
        $d = @(Compare-HYCUADAttributeBag -Snapshot $a -Live $b)
        $d.Count | Should Be 1
        $d[0].Attribute | Should Be 'description'
        $d[0].Change | Should Be 'Modified'
    }

    It 'flags an attribute present only in the snapshot' {
        $a = [pscustomobject]@{ description='x'; extra='y' }
        $b = [pscustomobject]@{ description='x' }
        $d = @(Compare-HYCUADAttributeBag -Snapshot $a -Live $b)
        ($d | Where-Object { $_.Attribute -eq 'extra' }).Change | Should Be 'AddedSinceSnapshot/MissingLive'
    }

    It 'flags an attribute added on the production side' {
        $a = [pscustomobject]@{ description='x' }
        $b = [pscustomobject]@{ description='x'; telephoneNumber='123' }
        $d = @(Compare-HYCUADAttributeBag -Snapshot $a -Live $b)
        ($d | Where-Object { $_.Attribute -eq 'telephoneNumber' }).Change | Should Be 'AddedLive'
    }

    It 'ignores operational attributes (whenChanged, uSNChanged...)' {
        $a = [pscustomobject]@{ whenChanged='1'; uSNChanged='5' }
        $b = [pscustomobject]@{ whenChanged='2'; uSNChanged='9' }
        (Compare-HYCUADAttributeBag -Snapshot $a -Live $b).Count | Should Be 0
    }

    It 'is insensitive to multi-valued ordering' {
        $a = [pscustomobject]@{ member=@('b','a','c') }
        $b = [pscustomobject]@{ member=@('a','c','b') }
        (Compare-HYCUADAttributeBag -Snapshot $a -Live $b).Count | Should Be 0
    }

    It 'handles a deleted object (no Live) without error' {
        $a = [pscustomobject]@{ description='x'; mail='a@b' }
        $d = @(Compare-HYCUADAttributeBag -Snapshot $a -Live $null)
        ($d | ForEach-Object { $_.Change } | Sort-Object -Unique) | Should Be 'AddedSinceSnapshot/MissingLive'
    }
}

Describe 'ConvertTo-HYCUCanonicalValue (binary-safe compare)' {
    It 'renders a byte[] as hex, not enumerated/sorted bytes' {
        ConvertTo-HYCUCanonicalValue ([byte[]](1,5,2)) | Should Be '01-05-02'
    }
    It 'distinguishes byte arrays that are byte-permutations of each other' {
        (ConvertTo-HYCUCanonicalValue ([byte[]](1,2,3))) | Should Not Be (ConvertTo-HYCUCanonicalValue ([byte[]](3,2,1)))
    }
    It 'stays order-insensitive for genuine multi-valued string attributes' {
        (ConvertTo-HYCUCanonicalValue @('b','a','c')) | Should Be (ConvertTo-HYCUCanonicalValue @('c','a','b'))
    }
    It 'returns empty string for null' { ConvertTo-HYCUCanonicalValue $null | Should Be '' }
}

Describe 'Compare-HYCUADAttributeBag (binary attributes)' {
    It 'flags a real byte[] difference (changed objectSid)' {
        $a = [pscustomobject]@{ objectSid = [byte[]](1,2,3,4) }
        $b = [pscustomobject]@{ objectSid = [byte[]](1,2,3,9) }
        @(Compare-HYCUADAttributeBag -Snapshot $a -Live $b | Where-Object { $_.Attribute -eq 'objectSid' }).Count | Should Be 1
    }
    It 'does NOT mask a byte-permutation as unchanged' {
        $a = [pscustomobject]@{ nTSecurityDescriptor = [byte[]](1,2,3) }
        $b = [pscustomobject]@{ nTSecurityDescriptor = [byte[]](3,2,1) }
        @(Compare-HYCUADAttributeBag -Snapshot $a -Live $b).Count | Should Be 1
    }
}

Describe 'Restore logic (documented expressions)' {

    It 'extracts the parent DN honoring escaped commas' {
        $dn = 'CN=Doe\, John,OU=Users,DC=corp,DC=local'
        $parent = ($dn -split '(?<!\\),',2)[1]
        $parent | Should Be 'OU=Users,DC=corp,DC=local'
    }

    It 'maps groupType to scope/category' {
        function Convert-GroupType([int64]$gt) {
            $scope = if ($gt -band 8) { 'Universal' } elseif ($gt -band 4) { 'DomainLocal' } else { 'Global' }
            $category = if ($gt -band 2147483648) { 'Security' } else { 'Distribution' }
            "$scope/$category"
        }
        Convert-GroupType ([int64]2147483650) | Should Be 'Global/Security'       # 0x80000002
        Convert-GroupType ([int64]2147483652) | Should Be 'DomainLocal/Security'  # 0x80000004
        Convert-GroupType ([int64]2147483656) | Should Be 'Universal/Security'    # 0x80000008
        Convert-GroupType ([int64]8)          | Should Be 'Universal/Distribution'
    }
}

Describe 'Clear-HYCUADStaging' {

    # Build a throwaway staging root with dated flr_/snap_ folders we can prune.
    # -Count uses default day spacing (i-Count); -AgeDays overrides with explicit ages
    # (index 0 = oldest). Names are ordered so a later index is always the newer folder.
    function New-StagingRoot {
        param([int]$Count = 5, [double[]]$AgeDays)
        if ($AgeDays) { $Count = $AgeDays.Count }
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ("hycuStagingTest_" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $base = Get-Date
        for ($i = 0; $i -lt $Count; $i++) {
            $prefix = if ($i % 2 -eq 0) { 'flr' } else { 'snap' }
            $d = New-Item -ItemType Directory -Path (Join-Path $root ("{0}_{1:D3}" -f $prefix, $i)) -Force
            # i=0 oldest ... i=Count-1 newest
            $age = if ($AgeDays) { $AgeDays[$i] } else { $Count - $i }
            $d.LastWriteTime = $base.AddDays(-$age)
        }
        # A stray folder that must never be touched.
        New-Item -ItemType Directory -Path (Join-Path $root 'keepme') -Force | Out-Null
        return $root
    }

    It 'keeps the N most recent staging folders and removes the rest' {
        $root = New-StagingRoot -Count 5
        try {
            $removed = @(Clear-HYCUADStaging -StagingRoot $root -KeepLast 2)
            $removed.Count | Should Be 3
            $left = @(Get-ChildItem -Path $root -Directory | Where-Object { $_.Name -match '^(flr|snap)_' })
            $left.Count | Should Be 2
            # The two newest (highest index) survive.
            ($left.Name | Sort-Object) -join ',' | Should Be 'flr_004,snap_003'
        } finally { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'never removes non-staging folders' {
        $root = New-StagingRoot -Count 4
        try {
            Clear-HYCUADStaging -StagingRoot $root -KeepLast 0 | Out-Null
            (Test-Path (Join-Path $root 'keepme')) | Should Be $true
        } finally { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'with -MaxAgeDays only removes folders older than the cutoff (beyond KeepLast)' {
        # ages oldest->newest: 6, 5, 2, 0.5 days. Off-boundary so the cutoff is unambiguous.
        $root = New-StagingRoot -AgeDays @(6, 5, 2, 0.5)
        try {
            # Keep 1 newest (0.5d); among {2d, 5d, 6d} only those older than 3 days go (5d, 6d).
            $removed = @(Clear-HYCUADStaging -StagingRoot $root -KeepLast 1 -MaxAgeDays 3)
            $removed.Count | Should Be 2
        } finally { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'honors -WhatIf (no deletion)' {
        $root = New-StagingRoot -Count 4
        try {
            Clear-HYCUADStaging -StagingRoot $root -KeepLast 0 -WhatIf | Out-Null
            $left = @(Get-ChildItem -Path $root -Directory | Where-Object { $_.Name -match '^(flr|snap)_' })
            $left.Count | Should Be 4
        } finally { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'is a no-op when folder count is within KeepLast' {
        $root = New-StagingRoot -Count 2
        try {
            @(Clear-HYCUADStaging -StagingRoot $root -KeepLast 3).Count | Should Be 0
        } finally { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Set-HYCUADConfig (HYCU fields)' {
    It 'exposes and updates the new HYCU fields' {
        $orig = Get-HYCUADConfig
        $savedServer = $orig.HycuServer; $savedPort = $orig.HycuPort; $savedSkip = $orig.HycuSkipCertCheck
        try {
            $cfg = Set-HYCUADConfig -HycuServer 'hycu.test' -HycuPort 9443 -HycuSkipCertCheck $true
            $cfg.HycuServer | Should Be 'hycu.test'
            $cfg.HycuPort | Should Be 9443
            $cfg.HycuSkipCertCheck | Should Be $true
        } finally {
            Set-HYCUADConfig -HycuServer $savedServer -HycuPort $savedPort -HycuSkipCertCheck $savedSkip | Out-Null
        }
    }

    It 'exposes and updates the staging auto-clean fields' {
        $orig = Get-HYCUADConfig
        $savedKeep = $orig.StagingKeepLast; $savedAuto = $orig.StagingAutoClean; $savedAge = $orig.StagingMaxAgeDays
        try {
            $cfg = Set-HYCUADConfig -StagingKeepLast 5 -StagingAutoClean $false -StagingMaxAgeDays 14
            $cfg.StagingKeepLast | Should Be 5
            $cfg.StagingAutoClean | Should Be $false
            $cfg.StagingMaxAgeDays | Should Be 14
        } finally {
            Set-HYCUADConfig -StagingKeepLast $savedKeep -StagingAutoClean $savedAuto -StagingMaxAgeDays $savedAge | Out-Null
        }
    }
}

Describe 'Get-DsamainFailureMessage' {
    It 'surfaces the exit code, port, captured dsamain output and version-mismatch guidance' {
        $m = Get-DsamainFailureMessage -ExitCode 0 -Output 'Error 0x57: the database is from a newer version' -Port 51389
        $m | Should Match 'code 0'
        $m | Should Match '51389'
        $m | Should Match 'newer version'
        $m | Should Match 'VERSION'
    }
    It 'leads with the port-in-use cause when dsamain reports error 10048' {
        $m = Get-DsamainFailureMessage -ExitCode 0 -Output 'failed to open a UDP port ... 10048 Only one usage of each socket address' -Port 51389
        $m | Should Match 'already in use'
        $m | Should Match 'dsamain.exe'
    }
    It 'detects the AD-init failure (8431) where the database attached then stopped' {
        $m = Get-DsamainFailureMessage -ExitCode 0 -Output 'attached a database (1, x.dit) ... Failure code: 8431 ... stopped the instance' -Port 51389
        $m | Should Match 'could not START'
    }
    It 'notes explicitly when dsamain produced no output' {
        $m = Get-DsamainFailureMessage -ExitCode 0 -Output '' -Port 51389
        $m | Should Match 'no output'
    }
    It 'renders "exit code unavailable" for the negative sentinel' {
        $m = Get-DsamainFailureMessage -ExitCode -1 -Output 'x' -Port 51389
        $m | Should Match 'exit code unavailable'
        $m | Should Not Match 'code -1'
    }
}

Describe 'Connect-HYCUADSnapshot (dirty-database guard)' {
    It 'throws an actionable error and does NOT mount when the database stays dirty' {
        Mock -ModuleName HYCUADRecovery Test-HYCUADPrerequisite { $true }
        Mock -ModuleName HYCUADRecovery Get-HYCUADStagedDatabase { [pscustomobject]@{ DitPath = 'X:\ntds.dit'; SysvolPath = $null } }
        Mock -ModuleName HYCUADRecovery Repair-HYCUADDatabase { $false }   # still dirty after recovery
        Mock -ModuleName HYCUADRecovery Mount-HYCUADSnapshot { throw 'SHOULD NOT REACH MOUNT' }
        { Connect-HYCUADSnapshot -SourcePath 'Y:\NTDS' } | Should Throw 'clean state'
        Assert-MockCalled -ModuleName HYCUADRecovery Mount-HYCUADSnapshot -Times 0
    }
    It 'mentions enabling hard repair when it was not allowed' {
        Mock -ModuleName HYCUADRecovery Test-HYCUADPrerequisite { $true }
        Mock -ModuleName HYCUADRecovery Get-HYCUADStagedDatabase { [pscustomobject]@{ DitPath = 'X:\ntds.dit' } }
        Mock -ModuleName HYCUADRecovery Repair-HYCUADDatabase { $false }
        $err = $null
        try { Connect-HYCUADSnapshot -SourcePath 'Y:\NTDS' } catch { $err = "$_" }
        $err | Should Match 'hard repair'
    }
    It 'proceeds to mount when the database is clean' {
        Mock -ModuleName HYCUADRecovery Test-HYCUADPrerequisite { $true }
        Mock -ModuleName HYCUADRecovery Get-HYCUADStagedDatabase { [pscustomobject]@{ DitPath = 'X:\ntds.dit'; SysvolPath = 'X:\SYSVOL' } }
        Mock -ModuleName HYCUADRecovery Repair-HYCUADDatabase { $true }
        Mock -ModuleName HYCUADRecovery Mount-HYCUADSnapshot { [pscustomobject]@{ Port = 51389 } }
        $s = Connect-HYCUADSnapshot -SourcePath 'Y:\NTDS'
        $s.Port | Should Be 51389
        Assert-MockCalled -ModuleName HYCUADRecovery Mount-HYCUADSnapshot -Times 1
    }
}

Describe 'Set-HYCULogSink (engine log forwarding)' {
    It 'forwards each message + level to the sink, and stops after unregister' {
        $global:HYCUSinkCap = New-Object System.Collections.Generic.List[string]
        Set-HYCULogSink { param($m, $l) $global:HYCUSinkCap.Add("$l|$m") }
        try {
            Write-HYCULog 'hello world' 'WARN'
            Write-HYCULog 'second line' 'INFO'
        } finally { Set-HYCULogSink $null }
        Write-HYCULog 'after-unregister' 'INFO'     # must NOT be captured
        $joined = ($global:HYCUSinkCap -join ';')
        $joined | Should Match 'WARN\|hello world'
        $joined | Should Match 'INFO\|second line'
        $joined | Should Not Match 'after-unregister'
        Remove-Variable -Scope Global HYCUSinkCap -ErrorAction SilentlyContinue
    }
}

Describe 'Mount-HYCUADSnapshot (LDAP port retry)' {
    It 'shifts to the next port and retries when dsamain fails for a non-database reason' {
        InModuleScope HYCUADRecovery {
            Mock Test-Path { $true }
            Mock Test-HYCUPortFree { $true }
            Mock Stop-HYCUADMountResidue { @() }
            Mock Invoke-HYCUADdsamainMount {
                if ($Port -lt 41391) { $script:HYCULastMountDbError = $false; throw "port $Port problem" }
                [pscustomobject]@{ Port = $Port; Server = "localhost:$Port" }
            }
            $s = Mount-HYCUADSnapshot -DitPath 'X:\ntds.dit'
            $s.Port | Should Be 41391
            Assert-MockCalled Invoke-HYCUADdsamainMount -Times 3   # 41389, 41390, 41391
        }
    }
    It 'retries a database failure a few times (residue purge) then surfaces it if it persists' {
        InModuleScope HYCUADRecovery {
            Mock Test-Path { $true }
            Mock Test-HYCUPortFree { $true }
            Mock Stop-HYCUADMountResidue { @() }
            Mock Start-Sleep {}
            Mock Invoke-HYCUADdsamainMount { $script:HYCULastMountDbError = $true; throw "dsamain exited - JET -550 Dirty Shutdown" }
            { Mount-HYCUADSnapshot -DitPath 'X:\ntds.dit' } | Should Throw 'Dirty Shutdown'
            Assert-MockCalled Invoke-HYCUADdsamainMount -Times 4   # initial + 3 residue-purge retries
        }
    }
    It 'recovers when a database error clears after a residue purge (mounts on a later port)' {
        InModuleScope HYCUADRecovery {
            Mock Test-Path { $true }
            Mock Test-HYCUPortFree { $true }
            Mock Stop-HYCUADMountResidue { @() }
            Mock Start-Sleep {}
            # -550 on the first ports (a leftover dsamain held the DB), clean mount once it is purged.
            Mock Invoke-HYCUADdsamainMount {
                if ($Port -lt 41391) { $script:HYCULastMountDbError = $true; throw "JET -550 Dirty Shutdown" }
                $script:HYCULastMountDbError = $false
                [pscustomobject]@{ Port = $Port; Server = "localhost:$Port" }
            }
            $s = Mount-HYCUADSnapshot -DitPath 'X:\ntds.dit'
            $s.Port | Should Be 41391
        }
    }
}

Describe 'Stop-HYCUADMountResidue (residual dsamain cleanup)' {
    It 'returns nothing when no dsamain is running' {
        Mock -ModuleName HYCUADRecovery Get-CimInstance { @() }
        Mock -ModuleName HYCUADRecovery Get-HYCUPortOwnerPid { @() }
        Mock -ModuleName HYCUADRecovery Get-Process { @() }
        Mock -ModuleName HYCUADRecovery Stop-Process { }
        @(Stop-HYCUADMountResidue -Port 51389 -Confirm:$false).Count | Should Be 0
    }
    It "in 'Matched' scope stops only dsamain matching our port/staging, never an unrelated one" {
        $staging = (Get-HYCUADConfig).StagingRoot
        Set-HYCUADConfig -DsamainResidueScope Matched | Out-Null
        try {
            Mock -ModuleName HYCUADRecovery Get-CimInstance {
                @(
                    [pscustomobject]@{ ProcessId = 100; CommandLine = "dsamain.exe /dbpath `"$staging\snap_x\ntds.dit`" /ldapport 51389 /allowUpgrade" },
                    [pscustomobject]@{ ProcessId = 200; CommandLine = 'dsamain.exe /dbpath "D:\unrelated\ntds.dit" /ldapport 60000' },
                    [pscustomobject]@{ ProcessId = 300; CommandLine = $null }
                )
            }
            Mock -ModuleName HYCUADRecovery Get-HYCUPortOwnerPid { @() }
            Mock -ModuleName HYCUADRecovery Stop-Process { }
            $killed = Stop-HYCUADMountResidue -Port 51389 -Confirm:$false
            ($killed -contains 100) | Should Be $true
            ($killed -contains 200) | Should Be $false
            Assert-MockCalled -ModuleName HYCUADRecovery Stop-Process -Times 1 -ParameterFilter { $Id -eq 100 }
            Assert-MockCalled -ModuleName HYCUADRecovery Stop-Process -Times 0 -ParameterFilter { $Id -eq 200 }
        } finally { Set-HYCUADConfig -DsamainResidueScope All | Out-Null }
    }
    It "in 'All' scope (default) stops every leftover dsamain so the default port is reused" {
        Mock -ModuleName HYCUADRecovery Get-CimInstance { @() }                 # no command-line matches
        Mock -ModuleName HYCUADRecovery Get-HYCUPortOwnerPid { @() }            # nothing on the target port
        Mock -ModuleName HYCUADRecovery Get-Process { @([pscustomobject]@{ Id = 777 }) } -ParameterFilter { $Name -eq 'dsamain' }
        Mock -ModuleName HYCUADRecovery Stop-Process { }
        $killed = Stop-HYCUADMountResidue -Port 41389 -Confirm:$false
        ($killed -contains 777) | Should Be $true
        Assert-MockCalled -ModuleName HYCUADRecovery Stop-Process -Times 1 -ParameterFilter { $Id -eq 777 }
    }
}

Describe 'Get-HYCUADPrerequisite (OS-aware dsamain)' {

    $realFile = Join-Path $env:SystemRoot 'System32\cmd.exe'                       # always present
    $nope     = Join-Path $env:TEMP ('hycu_missing_' + [guid]::NewGuid().ToString('N') + '.exe')

    # Drives tool presence via the live config and OS type via a mock; restores the config after.
    function Invoke-PrereqWith {
        param([int]$ProductType, [string]$DsamainPath, [string]$EsentutlPath, [string]$LdifdePath)
        # Capture ProductType into the mock body via GetNewClosure (a plain { ... $ProductType ... }
        # block would not resolve this local in Pester's mock scope; [scriptblock]::Create breaks
        # Pester 3.4's Test-IsClosure - GetNewClosure keeps a valid session state AND bakes the value).
        $cim = { [pscustomobject]@{ ProductType = $ProductType } }.GetNewClosure()
        Mock -ModuleName HYCUADRecovery Get-CimInstance $cim
        Mock -ModuleName HYCUADRecovery Get-Module      { 'ActiveDirectory' }      # AD module "available"
        $cfg  = Get-HYCUADConfig
        $save = @($cfg.DsamainPath, $cfg.EsentutlPath, $cfg.LdifdePath)
        try {
            $cfg.DsamainPath = $DsamainPath; $cfg.EsentutlPath = $EsentutlPath; $cfg.LdifdePath = $LdifdePath
            return Get-HYCUADPrerequisite
        } finally {
            $cfg.DsamainPath = $save[0]; $cfg.EsentutlPath = $save[1]; $cfg.LdifdePath = $save[2]
        }
    }

    It 'on a CLIENT with dsamain missing: no RSAT command, points to a server' {
        $r = Invoke-PrereqWith -ProductType 1 -DsamainPath $nope -EsentutlPath $realFile -LdifdePath $realFile
        $r.Ok                    | Should Be $false
        $r.IsServerOS            | Should Be $false
        $r.DsamainRequiresServer | Should Be $true
        $r.InstallCommand        | Should Be ''                    # the RSAT capability would NOT provide dsamain
        $r.Guidance              | Should Match 'Windows Server'
    }

    It 'on a SERVER with dsamain missing: suggests Install-WindowsFeature RSAT-AD-Tools' {
        $r = Invoke-PrereqWith -ProductType 3 -DsamainPath $nope -EsentutlPath $realFile -LdifdePath $realFile
        $r.IsServerOS            | Should Be $true
        $r.DsamainRequiresServer | Should Be $false
        $r.InstallCommand        | Should Be 'Install-WindowsFeature RSAT-AD-Tools'
        $r.Guidance              | Should Be ''
    }

    It 'on a CLIENT with only ldifde missing: the RSAT capability IS the right fix' {
        $r = Invoke-PrereqWith -ProductType 1 -DsamainPath $realFile -EsentutlPath $realFile -LdifdePath $nope
        $r.DsamainRequiresServer | Should Be $false
        $r.InstallCommand        | Should Be 'Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0'
        $r.Guidance              | Should Be ''
        ($r.Missing -join ';')   | Should Match 'ldifde'
    }

    It 'all tools present: Ok with no command and no guidance' {
        $r = Invoke-PrereqWith -ProductType 1 -DsamainPath $realFile -EsentutlPath $realFile -LdifdePath $realFile
        $r.Ok             | Should Be $true
        $r.InstallCommand | Should Be ''
        $r.Guidance       | Should Be ''
    }
}

Describe 'Restore-HYCUADObject (recreation - sIDHistory bridge)' {
    $dn = 'CN=Test user01,OU=X,DC=corp,DC=local'
    $session = [pscustomobject]@{ Server = 'localhost:41389'; BaseDN = 'DC=corp,DC=local' }
    $mockUserSnapshot = {
        $sid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-21-111-222-333-1105')
        $sb = New-Object byte[] $sid.BinaryLength; $sid.GetBinaryForm($sb, 0)
        [pscustomobject]@{
            objectGUID        = ([guid]'11112222-3333-4444-5555-666677778888').ToByteArray()
            objectSid         = $sb
            objectClass       = @('top','person','organizationalPerson','user')
            name              = 'Test user01'
            sAMAccountName    = 'tuser01'
            userPrincipalName = 'tuser01@corp.local'
            distinguishedName = 'CN=Test user01,OU=X,DC=corp,DC=local'
            description       = 'apresbackup'
            displayName       = 'Test user01'
            adspath           = 'LDAP://CN=Test user01,OU=X,DC=corp,DC=local'   # ADSI-injected; must NOT reach New-AD*
        }
    }

    It 'sets sIDHistory to the original SID when RestoreSidHistory is ON (fully-deleted -> recreation)' {
        Mock -ModuleName HYCUADRecovery Import-Module { }
        Mock -ModuleName HYCUADRecovery Get-ADObject { $null }                 # not in the Recycle Bin -> recreation
        Mock -ModuleName HYCUADRecovery New-ADUser { }
        Mock -ModuleName HYCUADRecovery Update-HYCUADGroupMembership { }
        Mock -ModuleName HYCUADRecovery Set-ADObject { }
        Mock -ModuleName HYCUADRecovery Get-LdapEntries $mockUserSnapshot
        Set-HYCUADConfig -RestoreSidHistory $true | Out-Null
        Restore-HYCUADObject -Session $session -DistinguishedName $dn -LiveServer 'dc.corp.local' -Confirm:$false
        Assert-MockCalled -ModuleName HYCUADRecovery New-ADUser   -Times 1 -Exactly -Scope It
        # Attributes are applied via Set-ADObject -Replace; adspath (ADSI-injected) must NOT be among them.
        Assert-MockCalled -ModuleName HYCUADRecovery Set-ADObject -Times 1 -Exactly -Scope It -ParameterFilter { $Replace -and -not $Replace.ContainsKey('adspath') }
        Assert-MockCalled -ModuleName HYCUADRecovery Set-ADObject -Times 1 -Exactly -Scope It -ParameterFilter { $Add -and $Add.ContainsKey('sIDHistory') }
    }

    It 'does NOT touch sIDHistory when RestoreSidHistory is OFF' {
        Mock -ModuleName HYCUADRecovery Import-Module { }
        Mock -ModuleName HYCUADRecovery Get-ADObject { $null }
        Mock -ModuleName HYCUADRecovery New-ADUser { }
        Mock -ModuleName HYCUADRecovery Update-HYCUADGroupMembership { }
        Mock -ModuleName HYCUADRecovery Set-ADObject { }
        Mock -ModuleName HYCUADRecovery Get-LdapEntries $mockUserSnapshot
        Set-HYCUADConfig -RestoreSidHistory $false | Out-Null
        Restore-HYCUADObject -Session $session -DistinguishedName $dn -LiveServer 'dc.corp.local' -Confirm:$false
        Assert-MockCalled -ModuleName HYCUADRecovery New-ADUser   -Times 1 -Exactly -Scope It
        # Set-ADObject is used to apply attributes, but there must be NO sIDHistory write when it is off.
        Assert-MockCalled -ModuleName HYCUADRecovery Set-ADObject -Times 0 -Exactly -Scope It -ParameterFilter { $Add -and $Add.ContainsKey('sIDHistory') }
        Set-HYCUADConfig -RestoreSidHistory $true | Out-Null   # restore default for any later tests
    }

    It 'recreates the object even when one attribute is rejected (per-attribute fallback skips it)' {
        Mock -ModuleName HYCUADRecovery Import-Module { }
        Mock -ModuleName HYCUADRecovery Get-ADObject { $null }
        Mock -ModuleName HYCUADRecovery New-ADUser { }
        Mock -ModuleName HYCUADRecovery Update-HYCUADGroupMembership { }
        # Batch -Replace (>1 attr) is rejected; on the per-attribute retry, only primaryGroupID fails.
        Mock -ModuleName HYCUADRecovery Set-ADObject {
            if ($Replace -and $Replace.Count -gt 1) { throw 'batch rejected' }
            if ($Replace -and $Replace.ContainsKey('primaryGroupID')) { throw 'not a member of the specified group' }
        }
        Mock -ModuleName HYCUADRecovery Get-LdapEntries {
            [pscustomobject]@{
                objectGUID        = ([guid]'11112222-3333-4444-5555-666677778888').ToByteArray()
                objectClass       = @('top','person','organizationalPerson','user')
                name              = 'Test user01'; sAMAccountName = 'tuser01'; userPrincipalName = 'tuser01@corp.local'
                distinguishedName = 'CN=Test user01,OU=X,DC=corp,DC=local'
                description       = 'apresbackup'
                primaryGroupID    = '513'
            }
        }
        Set-HYCUADConfig -RestoreSidHistory $false | Out-Null
        { Restore-HYCUADObject -Session $session -DistinguishedName $dn -LiveServer 'dc.corp.local' -Confirm:$false } | Should Not Throw
        Assert-MockCalled -ModuleName HYCUADRecovery New-ADUser -Times 1 -Exactly -Scope It
        Set-HYCUADConfig -RestoreSidHistory $true | Out-Null
    }
}

Describe 'Invoke-HYCUADBulkRestore (per-object result summary)' {
    $session = [pscustomobject]@{ Server = 'localhost:41389'; BaseDN = 'DC=corp,DC=local'; SysvolPath = $null }
    It 'reports each object as succeeded or failed (a throw is recorded, not silently finished)' {
        Mock -ModuleName HYCUADRecovery Restore-HYCUADObject {
            if ($DistinguishedName -match 'batchexe') { throw 'Access to the attribute is not permitted because the attribute is owned by the SAM' }
        }
        Mock -ModuleName HYCUADRecovery Restore-HYCUADAttribute { }
        Mock -ModuleName HYCUADRecovery Update-HYCUADGroupMembership { }
        $items = @(
            [pscustomobject]@{ DistinguishedName = 'CN=good,OU=X,DC=corp,DC=local';     Status = 'Deleted'; AttributeDiffs = @() },
            [pscustomobject]@{ DistinguishedName = 'CN=batchexe,OU=X,DC=corp,DC=local'; Status = 'Deleted'; AttributeDiffs = @() }
        )
        $r = Invoke-HYCUADBulkRestore -Session $session -Items $items -Confirm:$false
        $r.Total     | Should Be 2
        $r.Succeeded | Should Be 1
        $r.Failed    | Should Be 1
        (@($r.Details | Where-Object { -not $_.Ok })[0].DistinguishedName) | Should Match 'batchexe'
    }
}

Describe 'Restore-HYCUADAttribute (append / clear / byte[])' {
    $dn = 'CN=u,OU=X,DC=corp,DC=local'
    $session = [pscustomobject]@{ Server = 'localhost:41389'; BaseDN = 'DC=corp,DC=local' }

    It 'APPENDS the backup description to the live value (never overwrites)' {
        Mock -ModuleName HYCUADRecovery Import-Module { }
        Mock -ModuleName HYCUADRecovery Backup-HYCUADLiveObject { 'undo.ldif' }
        Mock -ModuleName HYCUADRecovery Get-ADObject { [pscustomobject]@{ description = 'live note' } }
        Mock -ModuleName HYCUADRecovery Set-ADObject { }
        Mock -ModuleName HYCUADRecovery Get-LdapEntries { [pscustomobject]@{ description = 'backup note' } }
        Set-HYCUADConfig -DescriptionRestoreMode Append | Out-Null
        Restore-HYCUADAttribute -Session $session -DistinguishedName $dn -Attribute description -LiveServer 'dc' -Confirm:$false
        Assert-MockCalled -ModuleName HYCUADRecovery Set-ADObject -Times 1 -Exactly -Scope It -ParameterFilter {
            $Replace -and $Replace.ContainsKey('description') -and ("$($Replace['description'])" -like '*live note*') -and ("$($Replace['description'])" -like '*backup note*')
        }
    }

    It 'CLEARS an attribute that is absent from the snapshot' {
        Mock -ModuleName HYCUADRecovery Import-Module { }
        Mock -ModuleName HYCUADRecovery Backup-HYCUADLiveObject { 'undo.ldif' }
        Mock -ModuleName HYCUADRecovery Set-ADObject { }
        Mock -ModuleName HYCUADRecovery Get-LdapEntries { [pscustomobject]@{ name = 'u' } }   # no 'info' attribute
        Restore-HYCUADAttribute -Session $session -DistinguishedName $dn -Attribute info -LiveServer 'dc' -Confirm:$false
        Assert-MockCalled -ModuleName HYCUADRecovery Set-ADObject -Times 1 -Exactly -Scope It -ParameterFilter { $Clear -contains 'info' }
    }

    It 'restores a byte[] attribute as ONE value (not split into individual bytes)' {
        Mock -ModuleName HYCUADRecovery Import-Module { }
        Mock -ModuleName HYCUADRecovery Backup-HYCUADLiveObject { 'undo.ldif' }
        Mock -ModuleName HYCUADRecovery Set-ADObject { }
        Mock -ModuleName HYCUADRecovery Get-LdapEntries { [pscustomobject]@{ thumbnailPhoto = [byte[]](1,2,3,4,5) } }
        Restore-HYCUADAttribute -Session $session -DistinguishedName $dn -Attribute thumbnailPhoto -LiveServer 'dc' -Confirm:$false
        Assert-MockCalled -ModuleName HYCUADRecovery Set-ADObject -Times 1 -Exactly -Scope It -ParameterFilter {
            $Replace -and $Replace.ContainsKey('thumbnailPhoto') -and ($Replace['thumbnailPhoto'].Count -eq 5)
        }
    }
}

Describe 'Compare-HYCUADObjects (GUID matching + classification)' {
    $session = [pscustomobject]@{ Server = 'snaphost'; BaseDN = 'DC=corp,DC=local' }

    It 'reports snapshot-only objects as Deleted and attribute changes as Modified' {
        Mock -ModuleName HYCUADRecovery Get-LdapEntries {
            @(
                [pscustomobject]@{ objectGUID = ([guid]'aaaaaaaa-0000-0000-0000-000000000001').ToByteArray(); distinguishedName = 'CN=a,DC=corp,DC=local'; name = 'a'; objectClass = @('user'); description = 'snap-a' },
                [pscustomobject]@{ objectGUID = ([guid]'bbbbbbbb-0000-0000-0000-000000000002').ToByteArray(); distinguishedName = 'CN=b,DC=corp,DC=local'; name = 'b'; objectClass = @('user'); description = 'snap-b' }
            )
        } -ParameterFilter { $Server -eq 'snaphost' }
        Mock -ModuleName HYCUADRecovery Get-LdapEntries {
            @(
                [pscustomobject]@{ objectGUID = ([guid]'aaaaaaaa-0000-0000-0000-000000000001').ToByteArray(); distinguishedName = 'CN=a,DC=corp,DC=local'; name = 'a'; objectClass = @('user'); description = 'live-a-DIFFERENT' }
            )
        } -ParameterFilter { $Server -eq 'livehost' }
        $r = @(Compare-HYCUADObjects -Session $session -LiveServer 'livehost' -Include All)
        $r.Count | Should Be 2
        # 'b' exists only in the snapshot -> Deleted; 'a' differs by ONE attribute -> Modified.
        # (Single-attribute changes are the regression case: the attribute bag used to unroll to a
        # scalar whose .Count was $null on PS 5.1, silently classifying the object as Unchanged.)
        (@($r | Where-Object { $_.Status -eq 'Deleted' }).Name)  | Should Be 'b'
        (@($r | Where-Object { $_.Status -eq 'Modified' }).Name) | Should Be 'a'
        (@($r | Where-Object { $_.Status -eq 'Modified' })[0].ChangedCount) | Should Be 1
    }
}

Describe 'Module manifest' {
    It 'is a valid manifest' {
        $manifest = Join-Path $here '..\HYCUADRecovery.psd1'
        (Test-ModuleManifest -Path $manifest -ErrorAction Stop) | Should Not BeNullOrEmpty
    }
}

Describe 'HYCU profiles (DPAPI save / get / remove round-trip)' {
    BeforeEach {
        Import-Module (Join-Path $here '..\HYCUSecrets.psm1') -Force
        $script:origProfDir = (Get-HYCUADConfig).ProfileDirectory
        $script:tmpProfiles = Join-Path ([IO.Path]::GetTempPath()) ("hycuProfTest_" + [guid]::NewGuid().ToString('N'))
        Set-HYCUADConfig -ProfileDirectory $script:tmpProfiles | Out-Null
    }
    AfterEach {
        if ($script:origProfDir) { Set-HYCUADConfig -ProfileDirectory $script:origProfDir | Out-Null }
        if ($script:tmpProfiles -and (Test-Path $script:tmpProfiles)) { Remove-Item $script:tmpProfiles -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'round-trips a token profile (encrypted secret decrypts on this user/machine)' {
        $tok = ConvertTo-SecureString 'super-secret-token' -AsPlainText -Force
        Save-HYCUADProfile -Name 'ut' -Server 'hycu.ut.local' -ApiToken $tok | Out-Null
        (@(Get-HYCUADProfile) -contains 'ut') | Should Be $true
        $p = Get-HYCUADProfile -Name 'ut'
        $p.Server   | Should Be 'hycu.ut.local'
        $p.AuthMode | Should Be 'Token'
        (New-Object System.Management.Automation.PSCredential('x', $p.ApiToken)).GetNetworkCredential().Password | Should Be 'super-secret-token'
        Remove-HYCUADProfile -Name 'ut' -Confirm:$false
        (@(Get-HYCUADProfile) -contains 'ut') | Should Be $false
    }
    It 'refuses to save a profile with an empty token' {
        { Save-HYCUADProfile -Name 'empty' -Server 's' -ApiToken (New-Object System.Security.SecureString) } | Should Throw
    }
}

Describe 'Export-HYCUADRestoreReport (audit HTML report)' {
    BeforeEach {
        $script:tmpRep = Join-Path ([IO.Path]::GetTempPath()) ("hycuRepTest_" + [guid]::NewGuid().ToString('N'))
    }
    AfterEach {
        if ($script:tmpRep -and (Test-Path $script:tmpRep)) { Remove-Item $script:tmpRep -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'writes a standalone HTML file summarizing the result and per-object rows' {
        $result = [pscustomobject]@{
            Total = 2; Succeeded = 1; Failed = 1
            Details = @(
                [pscustomobject]@{ DistinguishedName = 'CN=Ok User,OU=X,DC=corp,DC=local';  Status = 'Deleted';  Ok = $true;  Message = 'recreated' },
                [pscustomobject]@{ DistinguishedName = 'CN=Bad User,OU=X,DC=corp,DC=local'; Status = 'Modified'; Ok = $false; Message = 'access denied' }
            )
        }
        $path = Export-HYCUADRestoreReport -Result $result -SnapshotSource 'C:\stage\NTDS' -LiveServer 'dc01' -Directory $script:tmpRep
        $path | Should Not BeNullOrEmpty
        Test-Path $path | Should Be $true
        $html = Get-Content -LiteralPath $path -Raw
        $html | Should Match '<!DOCTYPE html>'
        $html | Should Match 'Bad User'          # the failed object appears
        $html | Should Match 'access denied'
        ($html -match 'ompany|HYCU AD Recovery') | Should Be $true
    }
    It 'HTML-encodes values so a crafted DN cannot inject markup' {
        $result = [pscustomobject]@{
            Total = 1; Succeeded = 1; Failed = 0
            Details = @([pscustomobject]@{ DistinguishedName = 'CN=<script>alert(1)</script>,DC=x'; Status = 'Deleted'; Ok = $true; Message = 'ok' })
        }
        $path = Export-HYCUADRestoreReport -Result $result -Directory $script:tmpRep
        $html = Get-Content -LiteralPath $path -Raw
        $html | Should Match '&lt;script&gt;'                    # encoded
        ($html -match '<script>alert\(1\)</script>') | Should Be $false   # NOT injected raw
    }
    It 'labels a simulation report distinctly from a live one' {
        $result = [pscustomobject]@{ Total = 0; Succeeded = 0; Failed = 0; Details = @() }
        $path = Export-HYCUADRestoreReport -Result $result -Simulation $true -Directory $script:tmpRep
        (Get-Content -LiteralPath $path -Raw) | Should Match 'SIMULATION'
    }
}

Describe 'Get-HYCUADRecycleBinObject (read-only recycle bin listing)' {
    It 'maps deleted objects, prefers msDS-LastKnownRDN, and drops non-deleted rows' {
        Mock -ModuleName HYCUADRecovery Import-Module { }
        Mock -ModuleName HYCUADRecovery Get-ADObject {
            @(
              [pscustomobject]@{ Name='Foo'; 'msDS-LastKnownRDN'='Foo'; lastKnownParent='OU=X,DC=corp,DC=local'; whenChanged='2026-01-01'; objectClass=@('top','person','user');  DistinguishedName='CN=Foo\0ADEL:1,CN=Deleted Objects,DC=corp,DC=local'; ObjectGUID='11111111'; Deleted=$true },
              [pscustomobject]@{ Name='Grp'; 'msDS-LastKnownRDN'='Grp'; lastKnownParent='OU=Y';                 whenChanged='2026-02-02'; objectClass=@('top','group');          DistinguishedName='CN=Grp\0ADEL:2,CN=Deleted Objects,DC=corp,DC=local'; ObjectGUID='22222222'; Deleted=$true },
              [pscustomobject]@{ Name='Live'; 'msDS-LastKnownRDN'='Live'; lastKnownParent='OU=Z';               whenChanged='2026-03-03'; objectClass=@('user');                  DistinguishedName='CN=Live,OU=Z,DC=corp,DC=local'; ObjectGUID='33333333'; Deleted=$false }
            )
        }
        $r = @(Get-HYCUADRecycleBinObject -Server 'dc01')
        $r.Count          | Should Be 2            # the non-deleted row is dropped
        $r[0].Name        | Should Be 'Foo'
        $r[0].ObjectClass | Should Be 'user'       # leaf class
        $r[1].ObjectClass | Should Be 'group'
    }
    It 'builds an isDeleted LDAP filter and adds the search term when filtering' {
        Mock -ModuleName HYCUADRecovery Import-Module { }
        Mock -ModuleName HYCUADRecovery Get-ADObject { @() }
        Get-HYCUADRecycleBinObject -Server 'dc01' -Filter 'jsmith' | Out-Null
        Assert-MockCalled -ModuleName HYCUADRecovery Get-ADObject -Times 1 -Exactly -ParameterFilter {
            $IncludeDeletedObjects -and $LDAPFilter -match 'isDeleted=TRUE' -and $LDAPFilter -match 'jsmith'
        }
    }
}

Describe 'Restore-HYCUADObject -TargetParentDN (restore into another OU)' {
    $dn = 'CN=Test user01,OU=X,DC=corp,DC=local'
    $quarantine = 'OU=Quarantine,DC=corp,DC=local'
    $session = [pscustomobject]@{ Server = 'localhost:41389'; BaseDN = 'DC=corp,DC=local' }
    $mockSnap = {
        [pscustomobject]@{
            objectGUID = ([guid]'11112222-3333-4444-5555-666677778888').ToByteArray()
            objectClass = @('top','person','organizationalPerson','user')
            name = 'Test user01'; sAMAccountName = 'tuser01'; userPrincipalName = 'tuser01@corp.local'
            distinguishedName = 'CN=Test user01,OU=X,DC=corp,DC=local'; description = 'd'
        }
    }
    It 'recreates the object UNDER the target OU and realigns groups on the redirected DN' {
        Mock -ModuleName HYCUADRecovery Import-Module { }
        Mock -ModuleName HYCUADRecovery Get-ADObject { $null }     # purged -> recreation path
        Mock -ModuleName HYCUADRecovery New-ADUser { }
        Mock -ModuleName HYCUADRecovery Set-ADObject { }
        Mock -ModuleName HYCUADRecovery Update-HYCUADGroupMembership { }
        Mock -ModuleName HYCUADRecovery Get-LdapEntries $mockSnap
        Set-HYCUADConfig -RestoreSidHistory $false | Out-Null
        Restore-HYCUADObject -Session $session -DistinguishedName $dn -LiveServer 'dc' -TargetParentDN $quarantine -Confirm:$false
        Set-HYCUADConfig -RestoreSidHistory $true | Out-Null
        Assert-MockCalled -ModuleName HYCUADRecovery New-ADUser -Times 1 -Exactly -Scope It -ParameterFilter { $Path -eq 'OU=Quarantine,DC=corp,DC=local' }
        Assert-MockCalled -ModuleName HYCUADRecovery Set-ADObject -Times 1 -Exactly -Scope It -ParameterFilter { ([string]$Identity) -eq 'CN=Test user01,OU=Quarantine,DC=corp,DC=local' }
        Assert-MockCalled -ModuleName HYCUADRecovery Update-HYCUADGroupMembership -Times 1 -Exactly -Scope It -ParameterFilter { $LiveDistinguishedName -eq 'CN=Test user01,OU=Quarantine,DC=corp,DC=local' }
    }
    It 'reanimates from the Recycle Bin with -TargetPath when the tombstone still exists' {
        Mock -ModuleName HYCUADRecovery Import-Module { }
        Mock -ModuleName HYCUADRecovery Get-ADObject { [pscustomobject]@{ Deleted = $true; ObjectGUID = [guid]'11112222-3333-4444-5555-666677778888' } }
        Mock -ModuleName HYCUADRecovery Restore-ADObject { }
        Mock -ModuleName HYCUADRecovery Update-HYCUADGroupMembership { }
        Mock -ModuleName HYCUADRecovery Get-LdapEntries $mockSnap
        Restore-HYCUADObject -Session $session -DistinguishedName $dn -LiveServer 'dc' -TargetParentDN $quarantine -Confirm:$false
        Assert-MockCalled -ModuleName HYCUADRecovery Restore-ADObject -Times 1 -Exactly -Scope It -ParameterFilter { $TargetPath -eq 'OU=Quarantine,DC=corp,DC=local' }
    }
    It 'forwards -TargetParentDN from the bulk restore to each Deleted item' {
        Mock -ModuleName HYCUADRecovery Restore-HYCUADObject { }
        $items = @([pscustomobject]@{ DistinguishedName = $dn; Status = 'Deleted'; AttributeDiffs = @() })
        Invoke-HYCUADBulkRestore -Session $session -Items $items -LiveServer 'dc' -TargetParentDN $quarantine -Confirm:$false | Out-Null
        Assert-MockCalled -ModuleName HYCUADRecovery Restore-HYCUADObject -Times 1 -Exactly -Scope It -ParameterFilter { $TargetParentDN -eq 'OU=Quarantine,DC=corp,DC=local' }
    }
}

Describe 'Get-HYCUADSubtreeChanges (subtree scan, parents first)' {
    It 'scopes the scan to the base DN and orders results parents-first' {
        Mock -ModuleName HYCUADRecovery Compare-HYCUADObjects {
            @(
              [pscustomobject]@{ Name='u1'; DistinguishedName='CN=u1,OU=Inner,OU=Sales,DC=corp,DC=local'; Status='Deleted' },
              [pscustomobject]@{ Name='Sales'; DistinguishedName='OU=Sales,DC=corp,DC=local'; Status='Deleted' },
              [pscustomobject]@{ Name='Inner'; DistinguishedName='OU=Inner,OU=Sales,DC=corp,DC=local'; Status='Deleted' }
            )
        }
        $session = [pscustomobject]@{ Server = 'localhost:41389'; BaseDN = 'DC=corp,DC=local' }
        $r = @(Get-HYCUADSubtreeChanges -Session $session -BaseDN 'OU=Sales,DC=corp,DC=local' -LiveServer 'dc')
        $r.Count   | Should Be 3
        $r[0].Name | Should Be 'Sales'    # 2 RDNs
        $r[1].Name | Should Be 'Inner'    # 3 RDNs
        $r[2].Name | Should Be 'u1'       # 4 RDNs
        Assert-MockCalled -ModuleName HYCUADRecovery Compare-HYCUADObjects -Times 1 -Exactly -Scope It -ParameterFilter { $SearchBase -eq 'OU=Sales,DC=corp,DC=local' }
    }
}

Describe 'Compare-HYCUADSnapshots (two restore points)' {
    It 'classifies OnlyInReference / Modified / OnlyInDifference by GUID' {
        # GUIDs are INLINED in the mock: a module-scoped mock scriptblock cannot see test-scope variables.
        Mock -ModuleName HYCUADRecovery Get-LdapEntries {
            if ($Server -eq 'refhost') {
                @(
                  [pscustomobject]@{ objectGUID = ([guid]'aaaaaaaa-0000-0000-0000-000000000001').ToByteArray(); name='a'; objectClass=@('user'); distinguishedName='CN=a,DC=x'; description='old' },
                  [pscustomobject]@{ objectGUID = ([guid]'bbbbbbbb-0000-0000-0000-000000000002').ToByteArray(); name='b'; objectClass=@('user'); distinguishedName='CN=b,DC=x' }
                )
            } else {
                @(
                  [pscustomobject]@{ objectGUID = ([guid]'aaaaaaaa-0000-0000-0000-000000000001').ToByteArray(); name='a'; objectClass=@('user'); distinguishedName='CN=a,DC=x'; description='new' },
                  [pscustomobject]@{ objectGUID = ([guid]'cccccccc-0000-0000-0000-000000000003').ToByteArray(); name='c'; objectClass=@('user'); distinguishedName='CN=c,DC=x' }
                )
            }
        }
        $sa = [pscustomobject]@{ Server = 'refhost';  BaseDN = 'DC=x' }
        $sb = [pscustomobject]@{ Server = 'diffhost'; BaseDN = 'DC=x' }
        $r = @(Compare-HYCUADSnapshots -ReferenceSession $sa -DifferenceSession $sb)
        (@($r | Where-Object { $_.Status -eq 'Modified' }).Name)         | Should Be 'a'
        (@($r | Where-Object { $_.Status -eq 'OnlyInReference' }).Name)  | Should Be 'b'
        (@($r | Where-Object { $_.Status -eq 'OnlyInDifference' }).Name) | Should Be 'c'
        (@($r | Where-Object { $_.Name -eq 'a' })[0].AttributeDiffs | Where-Object { $_.Attribute -eq 'description' }) | Should Not BeNullOrEmpty
    }
}

Describe 'Read-HYCUADRegistryPol / Compare-HYCUADGpoContent (GPO content diff)' {
    # Builds a valid PReg (Registry.pol) byte stream: [key;value;type;size;data] in UTF-16LE.
    $newPol = {
        param($entries)
        $ms = New-Object System.IO.MemoryStream
        $bw = New-Object System.IO.BinaryWriter $ms
        $bw.Write([System.Text.Encoding]::ASCII.GetBytes('PReg')); $bw.Write([uint32]1)
        $u = [System.Text.Encoding]::Unicode
        foreach ($e in $entries) {
            $bw.Write($u.GetBytes('['))
            $bw.Write($u.GetBytes([string]$e.Key));   $bw.Write([uint16]0); $bw.Write($u.GetBytes(';'))
            $bw.Write($u.GetBytes([string]$e.Value)); $bw.Write([uint16]0); $bw.Write($u.GetBytes(';'))
            $bw.Write([uint32]$e.Type); $bw.Write($u.GetBytes(';'))
            $bw.Write([uint32]([byte[]]$e.Data).Length); $bw.Write($u.GetBytes(';'))
            $bw.Write([byte[]]$e.Data); $bw.Write($u.GetBytes(']'))
        }
        $bw.Flush(); ,$ms.ToArray()
    }
    BeforeEach {
        $script:tmpGpo = Join-Path ([IO.Path]::GetTempPath()) ("hycuGpoTest_" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:tmpGpo -Force | Out-Null
    }
    AfterEach { if ($script:tmpGpo -and (Test-Path $script:tmpGpo)) { Remove-Item $script:tmpGpo -Recurse -Force -ErrorAction SilentlyContinue } }

    It 'parses REG_DWORD and REG_SZ entries from a Registry.pol' {
        $pol = Join-Path $script:tmpGpo 'Registry.pol'
        $bytes = & $newPol @(
            @{ Key='Software\Policies\T'; Value='EnableX'; Type=4; Data=[BitConverter]::GetBytes([uint32]1) },
            @{ Key='Software\Policies\T'; Value='Server';  Type=1; Data=([System.Text.Encoding]::Unicode.GetBytes("srv1`0")) }
        )
        [System.IO.File]::WriteAllBytes($pol, $bytes)
        $e = @(Read-HYCUADRegistryPol -Path $pol)
        $e.Count | Should Be 2
        $e[0].ValueName | Should Be 'EnableX'
        $e[0].TypeName  | Should Be 'REG_DWORD'
        [string]$e[0].Data | Should Be '1'
        $e[1].TypeName  | Should Be 'REG_SZ'
        [string]$e[1].Data | Should Be 'srv1'
    }
    It 'diffs settings and files between two GPO folders' {
        $snap = Join-Path $script:tmpGpo 'snap'; $prod = Join-Path $script:tmpGpo 'prod'
        New-Item -ItemType Directory -Path (Join-Path $snap 'Machine') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $prod 'Machine\Scripts') -Force | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $snap 'Machine\Registry.pol'), (& $newPol @(
            @{ Key='K'; Value='A'; Type=4; Data=[BitConverter]::GetBytes([uint32]1) },
            @{ Key='K'; Value='B'; Type=4; Data=[BitConverter]::GetBytes([uint32]7) }
        )))
        [System.IO.File]::WriteAllBytes((Join-Path $prod 'Machine\Registry.pol'), (& $newPol @(
            @{ Key='K'; Value='A'; Type=4; Data=[BitConverter]::GetBytes([uint32]2) }
        )))
        Set-Content -Path (Join-Path $prod 'Machine\Scripts\foo.cmd') -Value 'echo x'
        $r = @(Compare-HYCUADGpoContent -SnapshotPolicyPath $snap -ProductionPolicyPath $prod)
        # NB: [0].Item, not .Item - on an array, '.Item' resolves to the IList indexer, not member enumeration.
        (@($r | Where-Object { $_.Kind -eq 'Setting' -and $_.Status -eq 'Different' })[0].Item)      | Should Be 'Machine\K\A'
        (@($r | Where-Object { $_.Kind -eq 'Setting' -and $_.Status -eq 'OnlyInSnapshot' })[0].Item) | Should Be 'Machine\K\B'
        (@($r | Where-Object { $_.Kind -eq 'File' })[0].Status) | Should Be 'OnlyInProduction'
    }
}

Describe 'Reset-HYCUADRecreatedAccount (post-recreation assistant)' {
    It 'resets the password, forces change at logon, enables - and returns the password WITHOUT logging it' {
        Mock -ModuleName HYCUADRecovery Import-Module { }
        Mock -ModuleName HYCUADRecovery Set-ADAccountPassword { }
        Mock -ModuleName HYCUADRecovery Set-ADUser { }
        Mock -ModuleName HYCUADRecovery Enable-ADAccount { }
        $r = @(Reset-HYCUADRecreatedAccount -Identity 'CN=u,OU=X,DC=corp,DC=local' -Server 'dc' -Confirm:$false)
        $r.Count | Should Be 1
        $r[0].Ok | Should Be $true
        $r[0].Password.Length | Should Be 16
        ($r[0].Password -cmatch '[A-Z]' -and $r[0].Password -cmatch '[a-z]' -and $r[0].Password -match '[0-9]' -and $r[0].Password -match '[!#%+=?@]') | Should Be $true
        Assert-MockCalled -ModuleName HYCUADRecovery Set-ADAccountPassword -Times 1 -Exactly -Scope It -ParameterFilter { $Reset -and $NewPassword }
        Assert-MockCalled -ModuleName HYCUADRecovery Set-ADUser -Times 1 -Exactly -Scope It -ParameterFilter { $ChangePasswordAtLogon -eq $true }
        Assert-MockCalled -ModuleName HYCUADRecovery Enable-ADAccount -Times 1 -Exactly -Scope It
    }
    It 'leaves the account disabled with -NoEnable' {
        Mock -ModuleName HYCUADRecovery Import-Module { }
        Mock -ModuleName HYCUADRecovery Set-ADAccountPassword { }
        Mock -ModuleName HYCUADRecovery Set-ADUser { }
        Mock -ModuleName HYCUADRecovery Enable-ADAccount { }
        Reset-HYCUADRecreatedAccount -Identity 'CN=u,OU=X,DC=corp,DC=local' -Server 'dc' -NoEnable -Confirm:$false | Out-Null
        Assert-MockCalled -ModuleName HYCUADRecovery Enable-ADAccount -Times 0 -Exactly -Scope It
    }
    It 'writes nothing in simulation (-WhatIf) and returns no password' {
        Mock -ModuleName HYCUADRecovery Import-Module { }
        Mock -ModuleName HYCUADRecovery Set-ADAccountPassword { }
        Mock -ModuleName HYCUADRecovery Set-ADUser { }
        Mock -ModuleName HYCUADRecovery Enable-ADAccount { }
        $r = @(Reset-HYCUADRecreatedAccount -Identity 'CN=u,OU=X,DC=corp,DC=local' -Server 'dc' -WhatIf)
        $r[0].Password | Should BeNullOrEmpty
        Assert-MockCalled -ModuleName HYCUADRecovery Set-ADAccountPassword -Times 0 -Exactly -Scope It
    }
}

Describe 'Test-HYCUADSnapshotHealth (restorability check)' {
    BeforeEach {
        $script:tmpHl = Join-Path ([IO.Path]::GetTempPath()) ("hycuHealthTest_" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:tmpHl -Force | Out-Null
    }
    AfterEach { if ($script:tmpHl -and (Test-Path $script:tmpHl)) { Remove-Item $script:tmpHl -Recurse -Force -ErrorAction SilentlyContinue } }

    It 'passes when the database mounts and objects are readable, and writes a PASS report' {
        Set-Content -Path (Join-Path $script:tmpHl 'ntds.dit') -Value 'x'
        Mock -ModuleName HYCUADRecovery Test-HYCUADDatabaseState { [pscustomobject]@{ StateText = 'Clean Shutdown'; IsClean = $true } }
        Mock -ModuleName HYCUADRecovery Connect-HYCUADSnapshot { [pscustomobject]@{ Server = 'localhost:41389'; BaseDN = 'DC=corp,DC=local' } }
        Mock -ModuleName HYCUADRecovery Get-LdapEntries { @([pscustomobject]@{ name = 'x' }) }
        Mock -ModuleName HYCUADRecovery Dismount-HYCUADSnapshot { }
        $r = Test-HYCUADSnapshotHealth -SourcePath $script:tmpHl -ReportDirectory (Join-Path $script:tmpHl 'rep')
        $r.Ok    | Should Be $true
        $r.Total | Should Be 4
        Test-Path $r.ReportPath | Should Be $true
        (Get-Content -LiteralPath $r.ReportPath -Raw) | Should Match 'PASS'
        Assert-MockCalled -ModuleName HYCUADRecovery Dismount-HYCUADSnapshot -Times 1 -Exactly -Scope It
    }
    It 'fails cleanly (with a FAIL report) when ntds.dit is missing' {
        $r = Test-HYCUADSnapshotHealth -SourcePath $script:tmpHl -ReportDirectory (Join-Path $script:tmpHl 'rep')
        $r.Ok | Should Be $false
        (Get-Content -LiteralPath $r.ReportPath -Raw) | Should Match 'FAIL'
    }
}

Describe 'Export-HYCUADDriftReport (drift HTML)' {
    BeforeEach {
        $script:tmpDr = Join-Path ([IO.Path]::GetTempPath()) ("hycuDriftTest_" + [guid]::NewGuid().ToString('N'))
    }
    AfterEach { if ($script:tmpDr -and (Test-Path $script:tmpDr)) { Remove-Item $script:tmpDr -Recurse -Force -ErrorAction SilentlyContinue } }
    It 'renders deleted and modified objects with their changed attributes' {
        Mock -ModuleName HYCUADRecovery Compare-HYCUADObjects {
            @(
              [pscustomobject]@{ Name='gone';   ObjectClass='user'; DistinguishedName='CN=gone,DC=x';   Status='Deleted';  AttributeDiffs=@();                                              ChangedCount=0 },
              [pscustomobject]@{ Name='moved';  ObjectClass='user'; DistinguishedName='CN=moved,DC=x';  Status='Modified'; AttributeDiffs=@([pscustomobject]@{ Attribute='description' }); ChangedCount=1 }
            )
        }
        $session = [pscustomobject]@{ Server = 'localhost:41389'; BaseDN = 'DC=x' }
        $path = Export-HYCUADDriftReport -Session $session -LiveServer 'dc' -ReportDirectory $script:tmpDr
        Test-Path $path | Should Be $true
        $html = Get-Content -LiteralPath $path -Raw
        $html | Should Match 'gone'
        $html | Should Match 'description'
        $html | Should Match 'Deleted since the backup'
    }
}
