#
# HYCU AD Recovery Tool module manifest
#
@{
    RootModule        = 'HYCUADRecovery.psm1'
    ModuleVersion     = '2.0.0'
    GUID              = 'c629f5e5-81a6-4a6d-ba1c-6c952db339aa'
    Author            = 'HYCU AD Recovery Tool (independent project)'
    CompanyName       = 'Independent - not affiliated with HYCU or Microsoft'
    Copyright         = 'Provided "as is", without warranty.'
    Description       = 'Granular recovery of on-premises Active Directory objects from a HYCU backup: HYCU REST integration (VM / restore-point browsing + file-level restore handoff), dsamain mount of ntds.dit, LDAP snapshot/production comparison, restore (AD Recycle Bin, recreation, attributes, backlinks, LDIF, SYSVOL).'

    PowerShellVersion = '5.1'

    # Nested modules: HYCU REST client + profiles/secrets management.
    NestedModules     = @('HYCUClient.psm1', 'HYCUSecrets.psm1')

    FunctionsToExport = @(
        # --- AD engine (HYCUADRecovery.psm1) ---
        'Set-HYCUADConfig', 'Get-HYCUADConfig', 'Write-HYCULog', 'Set-HYCULogSink', 'Test-HYCUADPrerequisite', 'Get-HYCUADPrerequisite',
        'Clear-HYCUADStaging', 'Get-HYCUADStagedDatabase', 'Test-HYCUADDatabaseState', 'Repair-HYCUADDatabase',
        'Mount-HYCUADSnapshot', 'Dismount-HYCUADSnapshot', 'Stop-HYCUADMountResidue', 'Connect-HYCUADSnapshot',
        'Get-LdapEntries', 'Compare-HYCUADObjects', 'Compare-HYCUADAttributeBag', 'Get-HYCUADObjectDiff',
        'Get-HYCUADChildNodes', 'Get-HYCUADObjectAttributes', 'Get-HYCUADObjectComparison', 'Get-HYCUADObjectComparisonRows',
        'Backup-HYCUADLiveObject', 'Restore-HYCUADAttribute', 'Update-HYCUADGroupMembership',
        'Restore-HYCUADObject', 'Export-HYCUADObjectToLdif', 'Import-HYCUADLdif',
        'Restore-HYCUADSysvolItem', 'Invoke-HYCUADBulkRestore', 'Export-HYCUADRestoreReport',
        'Get-HYCUADRecycleBinObject', 'Get-HYCUADSubtreeChanges', 'Compare-HYCUADSnapshots',
        'Reset-HYCUADRecreatedAccount', 'Read-HYCUADRegistryPol', 'Compare-HYCUADGpoContent',
        'Test-HYCUADSnapshotHealth', 'Export-HYCUADDriftReport',
        # --- HYCU REST client (HYCUClient.psm1) ---
        'Connect-HYCUController', 'Disconnect-HYCUController', 'Invoke-HYCURest', 'Get-HYCUAllPages',
        'Get-HYCUProtectedVM', 'Get-HYCUADApplication', 'Get-HYCURestorePoint', 'Get-HYCUJob', 'Wait-HYCUJob',
        'Wait-HYCURestoredNtds', 'Mount-HYCUBackup', 'Dismount-HYCUBackup', 'Invoke-HYCURestoreItems',
        'Remove-HYCURestoredShareFiles', 'Start-HYCUFileLevelRestore', 'Invoke-HYCUADRestorabilityTest',
        # --- Profiles & secrets (HYCUSecrets.psm1) ---
        'Save-HYCUADProfile', 'Get-HYCUADProfile', 'Remove-HYCUADProfile'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags         = @('ActiveDirectory', 'HYCU', 'Backup', 'Recovery', 'dsamain', 'AD-Object-Recovery')
            ReleaseNotes = 'v2.0.0: HYCU REST integration (browsing + file-level restore handoff), DPAPI profiles/secrets, module manifest, N+1 LDAP removal. See CHANGELOG.md.'
        }
    }
}
