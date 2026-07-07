<#
 Pester tests (Pester 3.4-compatible) for the HYCU REST client.
 The module is imported standalone to isolate its scope (mocks -ModuleName HYCUClient).
 Run: Invoke-Pester -Path .\Tests
#>
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here '..\HYCUClient.psm1') -Force

Describe 'Connect-HYCUController (auth header)' {

    It 'builds a correct Basic header (base64 of user:pwd)' {
        $cred = New-Object System.Management.Automation.PSCredential('alice', (ConvertTo-SecureString 'p@ss' -AsPlainText -Force))
        $s = Connect-HYCUController -Server 'hycu.local' -Port 8443 -ApiVersion 'v1.0' -Credential $cred -NoValidate
        $s.BaseUri | Should Be 'https://hycu.local:8443/rest/v1.0'
        $s.Headers['Authorization'] | Should Match '^Basic '
        $b64 = $s.Headers['Authorization'].Substring(6)
        [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64)) | Should Be 'alice:p@ss'
    }

    It 'builds a token header with the Bearer scheme' {
        $tok = ConvertTo-SecureString 'abc123' -AsPlainText -Force
        $s = Connect-HYCUController -Server 'h' -AuthMode Token -ApiToken $tok -NoValidate
        $s.Headers['Authorization'] | Should Be 'Bearer abc123'
    }

    It 'infers Token mode when only -ApiToken is provided' {
        $tok = ConvertTo-SecureString 'zzz' -AsPlainText -Force
        $s = Connect-HYCUController -Server 'h' -ApiToken $tok -NoValidate
        $s.AuthMode | Should Be 'Token'
    }

    It 'composes a base URL with custom port and version' {
        $cred = New-Object System.Management.Automation.PSCredential('u', (ConvertTo-SecureString 'p' -AsPlainText -Force))
        $s = Connect-HYCUController -Server 'h' -Port 9443 -ApiVersion 'v2.0' -Credential $cred -NoValidate
        $s.BaseUri | Should Be 'https://h:9443/rest/v2.0'
    }
}

Describe 'Get-HYCUAllPages (pagination)' {

    It 'aggregates several pages up to totalEntityCount' {
        Mock -ModuleName HYCUClient Invoke-HYCURest {
            $page = [int]$Query['pageNumber']
            if ($page -eq 1) {
                [pscustomobject]@{ metadata = [pscustomobject]@{ totalEntityCount = 3 }; entities = @([pscustomobject]@{ id = 1 }, [pscustomobject]@{ id = 2 }) }
            } else {
                [pscustomobject]@{ metadata = [pscustomobject]@{ totalEntityCount = 3 }; entities = @([pscustomobject]@{ id = 3 }) }
            }
        }
        $sess = [pscustomobject]@{ BaseUri = 'x'; Headers = @{}; SkipCert = $false }
        $r = @(Get-HYCUAllPages -Session $sess -Path 'vms' -PageSize 2)
        $r.Count | Should Be 3
        Assert-MockCalled -ModuleName HYCUClient Invoke-HYCURest -Times 2
    }

    It 'stops on an empty page' {
        Mock -ModuleName HYCUClient Invoke-HYCURest {
            [pscustomobject]@{ metadata = [pscustomobject]@{ totalEntityCount = 99 }; entities = @() }
        }
        $sess = [pscustomobject]@{ BaseUri = 'x'; Headers = @{} }
        $r = @(Get-HYCUAllPages -Session $sess -Path 'vms')
        $r.Count | Should Be 0
    }
}

Describe 'Get-HYCUProtectedVM (filtering and projection)' {

    It 'keeps only PROTECTED VMs and projects the fields' {
        Mock -ModuleName HYCUClient Get-HYCUAllPages {
            @(
                [pscustomobject]@{ vmName = 'DC01'; uuid = 'u1'; status = 'PROTECTED'; operatingSystem = 'Windows' },
                [pscustomobject]@{ vmName = 'WEB01'; uuid = 'u2'; status = 'UNPROTECTED' }
            )
        }
        $sess = [pscustomobject]@{ BaseUri = 'x'; Headers = @{} }
        $vms = @(Get-HYCUProtectedVM -Session $sess)
        $vms.Count | Should Be 1
        $vms[0].Name | Should Be 'DC01'
        $vms[0].Uuid | Should Be 'u1'
    }

    It 'includes unprotected VMs with -IncludeUnprotected' {
        Mock -ModuleName HYCUClient Get-HYCUAllPages {
            @(
                [pscustomobject]@{ vmName = 'DC01'; uuid = 'u1'; status = 'PROTECTED' },
                [pscustomobject]@{ vmName = 'WEB01'; uuid = 'u2'; status = 'UNPROTECTED' }
            )
        }
        $sess = [pscustomobject]@{ BaseUri = 'x'; Headers = @{} }
        (@(Get-HYCUProtectedVM -Session $sess -IncludeUnprotected)).Count | Should Be 2
    }
}

Describe 'Get-HYCUADApplication (AD controllers only)' {

    It 'keeps only ACTIVE_DIRECTORY apps and maps the linked VM' {
        Mock -ModuleName HYCUClient Get-HYCUAllPages {
            @(
                [pscustomobject]@{ name = 'dc.ct';  applicationType = 'ACTIVE_DIRECTORY'; typeDisplayName = 'MS Active Directory'; vmName = 'DCVM01'; vmUuid = 'vm-1'; status = 'PROTECTED'; uuid = 'app-1' },
                [pscustomobject]@{ name = 'sql.ct'; applicationType = 'MS_SQL_SERVER';     vmName = 'SQLVM'; vmUuid = 'vm-2'; status = 'PROTECTED'; uuid = 'app-2' }
            )
        }
        $sess = [pscustomobject]@{ BaseUri = 'x'; Headers = @{} }
        $apps = @(Get-HYCUADApplication -Session $sess)
        $apps.Count | Should Be 1
        $apps[0].Name | Should Be 'DCVM01'        # linked VM (domain controller)
        $apps[0].Uuid | Should Be 'vm-1'          # VM uuid -> used for restore points
        $apps[0].Application | Should Be 'dc.ct'
    }

    It 'returns all application types with -AllTypes' {
        Mock -ModuleName HYCUClient Get-HYCUAllPages {
            @(
                [pscustomobject]@{ name = 'dc.ct';  applicationType = 'ACTIVE_DIRECTORY'; vmName = 'DCVM01'; vmUuid = 'vm-1' },
                [pscustomobject]@{ name = 'sql.ct'; applicationType = 'MS_SQL_SERVER';     vmName = 'SQLVM'; vmUuid = 'vm-2' }
            )
        }
        $sess = [pscustomobject]@{ BaseUri = 'x'; Headers = @{} }
        (@(Get-HYCUADApplication -Session $sess -AllTypes)).Count | Should Be 2
    }
}

Describe 'Get-HYCURestorePoint (consistency)' {

    It 'classifies application vs crash consistency' {
        Mock -ModuleName HYCUClient Get-HYCUAllPages {
            @(
                [pscustomobject]@{ uuid = 'r1'; restorePointInMillis = 1; appBackup = $true },
                [pscustomobject]@{ uuid = 'r2'; restorePointInMillis = 2; appBackup = $false }
            )
        }
        $sess = [pscustomobject]@{ BaseUri = 'x'; Headers = @{} }
        $rps = @(Get-HYCURestorePoint -Session $sess -VmUuid 'u1')
        ($rps | Where-Object { $_.Uuid -eq 'r1' }).Consistency | Should Be 'Application'
        ($rps | Where-Object { $_.Uuid -eq 'r2' }).Consistency | Should Be 'Crash'
    }
}

Describe 'Mount-HYCUBackup (mount UUID from job report)' {

    It 'resolves the mount UUID by parsing the job report' {
        Mock -ModuleName HYCUClient Invoke-HYCURest {
            if ($Method -eq 'POST')                { [pscustomobject]@{ entities = @('job-1') } }
            elseif ($Path -eq 'jobs/job-1/report') { [pscustomobject]@{ entities = @('Mounting snapshot... Mount UUID: mnt-123 ... done') } }
            else                                   { [pscustomobject]@{ entities = @() } }
        }
        $sess = [pscustomobject]@{ BaseUri = 'x'; Headers = @{} }
        $m = Mount-HYCUBackup -Session $sess -VmUuid 'vm1' -BackupUuid 'bk1' -TimeoutSeconds 30
        $m.MountUuid | Should Be 'mnt-123'
        $m.JobUuid | Should Be 'job-1'
    }
}

Describe 'Invoke-HYCURestoreItems (restore to SMB share)' {

    It 'posts the supported FLR payload (vmUuid, isSharedLocation, restoreItemType)' {
        Mock -ModuleName HYCUClient Wait-HYCUJob { }
        Mock -ModuleName HYCUClient Invoke-HYCURest { [pscustomobject]@{ entities = @([pscustomobject]@{ uuid = 'job-9' }) } }
        $sess = [pscustomobject]@{ BaseUri = 'x'; Headers = @{} }
        # -Password is a SecureString end-to-end; the body assertion below proves it materializes
        # as plain text ONLY inside the REST body (the one place the HYCU API requires it).
        Invoke-HYCURestoreItems -Session $sess -MountUuid 'mu' -SelectedItems @('/C/Windows/NTDS') `
            -VmUuid 'vm-1' -TargetPath '\\nas\share' -Username 'svc' `
            -Password (ConvertTo-SecureString 'pw' -AsPlainText -Force) | Out-Null
        Assert-MockCalled -ModuleName HYCUClient Invoke-HYCURest -Times 1 -ParameterFilter {
            $Body.restoreTargetPath -eq '\\nas\share' -and
            $Body.vmUuid -eq 'vm-1' -and $Body.username -eq 'svc' -and $Body.password -eq 'pw' -and
            ($Body.selectedItems -contains '/C/Windows/NTDS') -and
            $Body.isSharedLocation -eq $true -and $Body.sharedType -eq 'SMB' -and $Body.restoreItemType -eq 'FILESYSTEM'
        }
    }
}

Describe 'Wait-HYCURestoredNtds (ntds.dit detection)' {

    It 'returns the folder containing ntds.dit once stable' {
        $tmp = Join-Path $env:TEMP ('hycu_test_' + [guid]::NewGuid().ToString('N'))
        $sub = Join-Path $tmp 'Windows\NTDS'
        New-Item -ItemType Directory -Path $sub -Force | Out-Null
        Set-Content -Path (Join-Path $sub 'ntds.dit') -Value 'stable-content'
        Set-Content -Path (Join-Path $sub 'edb.log') -Value 'journal'
        try {
            $folder = Wait-HYCURestoredNtds -Path $tmp -StableSeconds 1 -PollSeconds 1 -TimeoutSeconds 20
            # $env:TEMP may be a short (8.3) path; compare in a normalized way.
            (Split-Path $folder -Leaf) | Should Be 'NTDS'
            (Test-Path (Join-Path $folder 'ntds.dit')) | Should Be $true
            (Get-Item $folder).FullName | Should Be (Get-Item $sub).FullName
        } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'throws if ntds.dit does not appear before the timeout' {
        $tmp = Join-Path $env:TEMP ('hycu_test_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try { { Wait-HYCURestoredNtds -Path $tmp -TimeoutSeconds 2 -PollSeconds 1 } | Should Throw }
        finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Set-HYCUTls12 (older .NET TLS default)' {
    It 'adds TLS 1.2 to the allowed protocols on Windows PowerShell (no-op on PS7+)' {
        $orig = [Net.ServicePointManager]::SecurityProtocol
        try {
            # Simulate an old default (TLS 1.0 only), as on Server 2012 R2.
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls
            InModuleScope HYCUClient { Set-HYCUTls12 }
            $now = [Net.ServicePointManager]::SecurityProtocol
            if ($PSVersionTable.PSVersion.Major -lt 6) {
                [int]($now -band [Net.SecurityProtocolType]::Tls12) | Should Not Be 0
            } else {
                $now | Should Be ([Net.SecurityProtocolType]::Tls)   # function is a no-op on PS7+
            }
        } finally { [Net.ServicePointManager]::SecurityProtocol = $orig }
    }
}

Describe 'Remove-HYCURestoredShareFiles (share cleanup)' {

    # Builds a fake "share" rooted at $tmp with the given relative NTDS/SYSVOL layout.
    function New-FakeShare {
        param([string]$NtdsRel, [string]$SysvolRel)
        $tmp  = Join-Path $env:TEMP ('hycu_share_' + [guid]::NewGuid().ToString('N'))
        $ntds = Join-Path $tmp $NtdsRel
        New-Item -ItemType Directory -Path $ntds -Force | Out-Null
        Set-Content -Path (Join-Path $ntds 'ntds.dit') -Value 'db'
        $sysvol = ''
        if ($SysvolRel) {
            $sysvol = Join-Path $tmp $SysvolRel
            New-Item -ItemType Directory -Path $sysvol -Force | Out-Null
            Set-Content -Path (Join-Path $sysvol 'policy.txt') -Value 'gpo'
        }
        [pscustomobject]@{ Root = $tmp; Ntds = $ntds; Sysvol = $sysvol }
    }

    It 'removes NTDS + SYSVOL and prunes empty parents up to (not including) the share root' {
        $s = New-FakeShare -NtdsRel 'C\Windows\NTDS' -SysvolRel 'C\Windows\SYSVOL'
        try {
            Remove-HYCURestoredShareFiles -NtdsFolder $s.Ntds -SysvolFolder $s.Sysvol -ShareRoot $s.Root | Out-Null
            (Test-Path $s.Ntds)   | Should Be $false
            (Test-Path $s.Sysvol) | Should Be $false
            (Test-Path (Join-Path $s.Root 'C\Windows')) | Should Be $false   # empty parents pruned
            (Test-Path (Join-Path $s.Root 'C'))         | Should Be $false
            (Test-Path $s.Root)   | Should Be $true                          # share root never removed
        } finally { Remove-Item $s.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'stops pruning at a parent that holds pre-existing operator data' {
        $s = New-FakeShare -NtdsRel 'Windows\NTDS' -SysvolRel 'Windows\SYSVOL'
        $keep = Join-Path $s.Root 'Windows\operator.txt'
        Set-Content -Path $keep -Value 'do-not-delete'
        try {
            Remove-HYCURestoredShareFiles -NtdsFolder $s.Ntds -SysvolFolder $s.Sysvol -ShareRoot $s.Root | Out-Null
            (Test-Path $s.Ntds) | Should Be $false
            (Test-Path (Join-Path $s.Root 'Windows')) | Should Be $true      # not pruned (still has operator.txt)
            (Test-Path $keep)   | Should Be $true
        } finally { Remove-Item $s.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'only removes what it was told (an unrelated sibling blocks the prune)' {
        $s = New-FakeShare -NtdsRel 'C\Windows\NTDS'   # no SYSVOL passed to the function
        $sibling = Join-Path $s.Root 'C\Windows\SYSVOL'
        New-Item -ItemType Directory -Path $sibling -Force | Out-Null
        Set-Content -Path (Join-Path $sibling 'untouched.txt') -Value 'x'
        try {
            Remove-HYCURestoredShareFiles -NtdsFolder $s.Ntds -ShareRoot $s.Root | Out-Null
            (Test-Path $s.Ntds)  | Should Be $false
            (Test-Path $sibling) | Should Be $true                           # never asked to delete it
            (Test-Path (Join-Path $s.Root 'C\Windows')) | Should Be $true    # prune blocked by the sibling
        } finally { Remove-Item $s.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'honors -WhatIf (no deletion)' {
        $s = New-FakeShare -NtdsRel 'C\Windows\NTDS' -SysvolRel 'C\Windows\SYSVOL'
        try {
            Remove-HYCURestoredShareFiles -NtdsFolder $s.Ntds -SysvolFolder $s.Sysvol -ShareRoot $s.Root -WhatIf | Out-Null
            (Test-Path $s.Ntds)   | Should Be $true
            (Test-Path $s.Sysvol) | Should Be $true
        } finally { Remove-Item $s.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'never deletes the share root itself (leaf == root is refused)' {
        $s = New-FakeShare -NtdsRel 'C\Windows\NTDS'        # ntds.dit lives under the root
        Set-Content -Path (Join-Path $s.Root 'ntds.dit') -Value 'db'   # also a stray copy at root
        try {
            # Pass the share root AS the NTDS folder - the safety guard must refuse it.
            $removed = @(Remove-HYCURestoredShareFiles -NtdsFolder $s.Root -ShareRoot $s.Root)
            $removed.Count | Should Be 0
            (Test-Path $s.Root) | Should Be $true
            (Test-Path (Join-Path $s.Root 'ntds.dit')) | Should Be $true
        } finally { Remove-Item $s.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
