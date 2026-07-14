# HYCU AD Recovery Tool

Granular recovery of **on-premises Active Directory** objects from a **HYCU** backup of a
domain controller. It relies **only on native Microsoft mechanisms** — the only HYCU-specific
part is retrieving the `ntds.dit` file from a backup.

> ⚠️ **Disclaimer** — Independent project, **not affiliated with or supported by** HYCU or
> Microsoft. Active Directory is a sensitive database: **test in a lab / outside production
> first**. You remain responsible for any data loss. Keep **simulation mode (`-WhatIf`)**
> enabled for your first runs.

---

## Launch the tool

Two ways to start it — **both run exactly the same tool**. Pick whichever your environment prefers:

**① Double-click `HYCUADRecovery.exe`**
A single self-contained file (everything is embedded). Copy it anywhere and run it — nothing else
needed. The simplest option.

**② Double-click `Run-HYCUADRecovery.cmd`**
Starts the tool through the Windows PowerShell that ships with Windows. Use this if the `.exe` does
not start on your workstation. This method needs the module files next to it — keep
`Run-HYCUADRecovery.cmd` in the **same folder** as `HYCUADRecovery.psd1` / `.psm1`,
`HYCUClient.psm1`, `HYCUSecrets.psm1` and `Start-HYCUADRecoveryGUI.ps1`.

> Run it on a **domain member with the AD DS tools (RSAT / `dsamain`)** present — see
> [Prerequisites](#2-prerequisites). Keep **Simulation mode (`-WhatIf`)** enabled for your first runs.

---

## 1. How it works

```
 HYCU backup of the DC                            PRODUCTION Active Directory
   (app-consistent VM)                                   (live DC)
          │                                                  ▲
          │ 1. Granular file restore                         │ 4. LDAP diff
          │    C:\Windows\NTDS (+ SYSVOL)                     │    (deleted objects,
          ▼                                                   │     modified attributes,
   Local staging folder                                       │     memberships)
   ntds.dit + edb*.log                                        │
          │                                                  │
          │ 2. esentutl /r  (soft recovery: mountable DB)     │
          ▼                                                  │
   "Clean Shutdown" database                                 │
          │                                                  │
          │ 3. dsamain.exe /dbpath … /ldapport 41389          │
          ▼                                                  │
   Local LDAP server for the snapshot  ───────────────────────┘
          │
          │ 5. Restore:  AD Recycle Bin → recreate → attributes → backlinks
          │              or LDIF export (ldifde) + SYSVOL/GPO restore
          ▼
   Objects restored in production
```

The heavy lifting is done by native tooling: `dsamain.exe` (Active Directory Database Mounting
Tool), LDAP comparison queries and `ldifde`. This tool orchestrates them and adds the comparison
logic, group backlink handling, the AD Recycle Bin, SYSVOL and the safety guards.

---

## 2. Prerequisites

Install on **a domain member**, not necessarily a DC. Note: the **mount / compare / restore** phase
requires `dsamain.exe`, a **Windows Server**-only tool — so that phase must run on a Windows Server or
a domain controller (a Windows 10/11 client can drive the HYCU file retrieval but cannot mount the
database). The tool detects this at startup and tells you exactly what is missing for your OS.

- **Windows** with the **RSAT / AD DS tools**, including:
  - `dsamain.exe` — the *Active Directory Database Mounting Tool*. **It ships only with Windows
    Server** (the AD DS or AD LDS role, or `RSAT-AD-Tools` on Server) and is **already present on a
    domain controller**. ⚠️ It is **NOT available on Windows 10/11 client editions** — installing
    RSAT on a client provides `ldifde` and the AD module but **not** `dsamain.exe`. Run the
    **mount / compare / restore** steps on a Windows Server or a domain controller.
  - The **ActiveDirectory** PowerShell module (`RSAT-AD-PowerShell`).
  - `esentutl.exe` and `ldifde.exe` (built into Windows).
- **PowerShell 5.1+** (the WPF GUI requires Windows PowerShell 5.1).
- Console launched **as administrator**, with an account holding the AD write rights needed for
  the production restore phase (typically *Domain Admins*, or an equivalent delegation).
- (Recommended) **AD Recycle Bin enabled** in the forest — see §6.
- For the HYCU integration: **network access** to the HYCU controller (REST port `8443` by default,
  **plus SMB/TCP 445** to read the file-level mount share) and **credentials** (Basic account or API
  token/key). No HYCU console access is required for the operator.

Feature installation (Windows Server example):

```powershell
Install-WindowsFeature RSAT-AD-Tools, RSAT-AD-PowerShell
# The "AD DS Snapshot/Database Mounting Tool" feature ships with RSAT-AD-Tools.
```

---

## 3. Package contents

| File | Role |
|---|---|
| `HYCUADRecovery.exe` | **Standalone launcher** — double-click to run (self-contained). |
| `Run-HYCUADRecovery.cmd` | **Alternative launcher** — starts the tool via Windows PowerShell. |
| `HYCUADRecovery.psd1` | **Module manifest** (v2.0.0) — import this one. |
| `HYCUADRecovery.psm1` | AD PowerShell engine (mount, compare, restore). |
| `HYCUClient.psm1` | **HYCU REST client** (connect, VMs, restore points, file-level restore). |
| `HYCUSecrets.psm1` | **Connection profiles** — save and reuse connection settings. |
| `Start-HYCUADRecoveryGUI.ps1` | WPF interface: **guided wizard + dashboard**. |
| `Examples.ps1` | Command-line usage examples (full walkthrough). |
| `Tests/` | Pester tests (`Invoke-Pester .\Tests`). |
| `README.md` / `CHANGELOG.md` | Documentation. |

> **Import** the manifest — `Import-Module .\HYCUADRecovery.psd1`. It loads the AD engine, the
> HYCU client and the profile management in one go.

---

## 4. HYCU integration — retrieving `ntds.dit`

The tool needs the DC's `C:\Windows\NTDS` folder (at least `ntds.dit` **and** the `edb*.log` /
`edb.chk` journals), and optionally `C:\Windows\SYSVOL` for GPOs. Two approaches:

### Approach A (simple) — HYCU file restore, then point at it
1. In HYCU, run a **granular file restore** (or *instant mount* / *file-level recovery*) of the
   backed-up DC, at the desired restore point.
2. Restore `C:\Windows\NTDS\` (and `C:\Windows\SYSVOL\`) to an accessible share/volume,
   e.g. `R:\HYCU_Restore\DC01\Windows\NTDS`.
3. Point the tool at it:
   ```powershell
   $session = Connect-HYCUADSnapshot -SourcePath 'R:\HYCU_Restore\DC01\Windows\NTDS'
   ```

### Approach B (recommended) — fully automated from this tool, no HYCU console
`HYCUClient.psm1` drives the **entire** retrieval through the HYCU REST API. The operator does
**everything from this tool** and needs **no access to the HYCU console**:

```powershell
# Auth (Basic or API token). Self-signed certificates are accepted by default.
$hycu = Connect-HYCUController -Server 'hycu.corp.local' -AuthMode Token -ApiToken $secureToken

# List only Active Directory domain controllers (HYCU 'ACTIVE_DIRECTORY' applications),
# each resolved to its linked VM:
$dc = Get-HYCUADApplication -Session $hycu | Select-Object -First 1
$rp = Get-HYCURestorePoint  -Session $hycu -VmUuid $dc.Uuid |
      Sort-Object Timestamp -Descending | Select-Object -First 1     # prefer 'Application' consistent

# Mounts the backup in HYCU, copies the NTDS database locally over the file-level mount
# share, then unmounts - automatically:
$ntds = Start-HYCUFileLevelRestore -Session $hycu -Vm $dc -RestorePoint $rp
$session = Connect-HYCUADSnapshot -SourcePath $ntds
```

**How `Start-HYCUFileLevelRestore` works** (HYCU file-level mount API):
1. `POST /vms/{vmUuid}/backups/{backupUuid}/mount` — mount the backup (tracked as a job).
2. `GET  /vms/{vmUuid}/backups/{backupUuid}/mount` — read the **SMB share** exposed by the
   controller (`shareUsername`, `sharePassword`, `mountPointMap` UNC paths).
3. The tool reads `ntds.dit` (+ journals, + optional SYSVOL) straight from that share and copies
   them to a local folder.
4. `DELETE /vms/{vmUuid}/backups/{backupUuid}/mount` — unmount (always, even on error).

> The host running the tool must reach the HYCU mount share over **SMB (TCP 445)**.

**Endpoints used**: `GET /applications`, `GET /vms`, `GET /vms/{uuid}/backups`,
`POST|GET|DELETE /vms/{uuid}/backups/{uuid}/mount`, `GET /jobs/{uuid}`.
**Authentication**: Bearer token on recent controllers; Basic on others (configurable via `-AuthMode`).
**Certificates**: self-signed controllers are the norm, so certificate validation is **skipped by
default** (`HycuSkipCertCheck=$true`). Set `Set-HYCUADConfig -HycuSkipCertCheck $false` to enforce it.
**Transport**: the client uses **`curl.exe`** by default (reliable TLS where Windows PowerShell 5.1's
.NET stack can fail the handshake); secrets go through a temporary curl config file, not the command
line. Override with `Set-HYCUADConfig -HycuTransport Auto|Curl|DotNet`.

**Profiles & secrets** — save connections without retyping credentials:

```powershell
Save-HYCUADProfile -Name prod -Server 'hycu.corp.local' -Credential (Get-Credential)
$hycu = Get-HYCUADProfile -Name prod -Connect
```

Secrets (Basic password, API token) are **DPAPI-encrypted** (`Export-Clixml`): not decryptable
by another user or on another machine, never written in clear text.

> 💡 **Application consistency** — An **application-consistent** HYCU backup of the DC generally
> yields a `ntds.dit` that is already clean (*Clean Shutdown*). If the backup is crash-consistent,
> the module automatically runs an ESE *soft recovery* (`esentutl /r`) to make it mountable.

---

## 5. Usage

To start the tool, see [Launch the tool](#launch-the-tool) at the top of this README (the standalone
`.exe` or `Run-HYCUADRecovery.cmd`). You can also run the GUI script directly:
```powershell
powershell -ExecutionPolicy Bypass -STA -File .\Start-HYCUADRecoveryGUI.ps1
```

The interface has **two modes** (it stays responsive: long operations run in the background):

**"Wizard" tab** — guided 7-step workflow:
1. **Connect to HYCU** (or "I already have an NTDS folder" to skip HYCU) — profiles can be saved.
2. **AD controller + restore point** — list only the Active Directory domain controllers (HYCU
   `ACTIVE_DIRECTORY` applications) and their backups (app/crash consistency).
3. **Restore destination** — the SMB share HYCU writes the file-level restore to (saved with the
   connection profile).
4. **Retrieve NTDS** — one click: the tool mounts the backup in HYCU, restores the files to the
   destination share, copies the NTDS database locally and unmounts. Fully automatic, no HYCU
   console needed.
5. **Mount + compare** — `esentutl` → `dsamain` → LDAP diff against production (X deleted / Y modified).
6. **Selection** — object tree + search + **List GPOs** + **attribute-by-attribute diff** + **cart**.
7. **Restore** — simulation (`-WhatIf`) enabled by default, "remove added groups" option.

**"Advanced / Dashboard" tab** — everything on one screen for expert operators: mount, compare,
grids, cart, LDIF export, restore selection/cart, dismount.

> Keep **Simulation mode** enabled while you validate behavior.

### Command line
See `Examples.ps1`. In short:
```powershell
Import-Module .\HYCUADRecovery.psd1
$s = Connect-HYCUADSnapshot -SourcePath 'R:\HYCU_Restore\DC01\Windows\NTDS'
$diffs = Compare-HYCUADObjects -Session $s -LiveServer 'dc01.corp.local' -Include Deleted,Modified

# Revert an attribute change
Restore-HYCUADAttribute -Session $s -DistinguishedName $dn -Attribute telephoneNumber -WhatIf
# Restore a deleted object (AD Recycle Bin -> else recreation)
Restore-HYCUADObject -Session $s -DistinguishedName $dn -WhatIf
# Dismount
Dismount-HYCUADSnapshot -Session $s
```

---

## 6. Covered recovery scenarios

| Scenario | Function | Note |
|---|---|---|
| **Deleted** object (recent, tombstone) | `Restore-HYCUADObject` | Via **AD Recycle Bin** → **SID preserved** (max fidelity). |
| **Deleted** object (purged / no Recycle Bin) | `Restore-HYCUADObject` | **Recreation** from the snapshot → **new SID** (see §7). |
| **Modified attribute** (phone, UAC, mail, SPN…) | `Restore-HYCUADAttribute` | Restores the snapshot value, automatic undo LDIF. |
| **Privilege escalation** (group addition) | `Update-HYCUADGroupMembership` | `-RemoveExtra` to remove added groups. |
| **Group memberships** (backlinks) | `Update-HYCUADGroupMembership` | Acts on the groups' `member` attribute. |
| **LDIF export / import** | `Export-HYCUADObjectToLdif` / `Import-HYCUADLdif` | Re-import via `ldifde`. |
| **GPO / SYSVOL content** | `Restore-HYCUADSysvolItem` | Restores policy files (outside `ntds.dit`). |
| **Bulk restore** | `Invoke-HYCUADBulkRestore` | Processes a whole "cart" of objects. |

---

## 7. Important limitations (read before production)

- **SID on recreation** — A **purged** object (outside the Recycle Bin) that is recreated gets a
  **new SID**. ACLs and memberships based on the old SID are **not** preserved. → Enable the
  **AD Recycle Bin** to preserve the SID, or use a native authoritative restore for critical cases.
- **Passwords / secrets** — A recreation creates a **disabled** account; password must be reset and
  the machine re-joined. The AD Recycle Bin, by contrast, preserves the secret.
- **SYSVOL ≠ ntds.dit** — GPO content (Registry.pol, scripts, ADMX) lives in SYSVOL. Remember to
  **also** restore SYSVOL (`-SysvolSourcePath`) for a complete GPO recovery.
- **Crash-consistent database** — If soft recovery fails, `Repair-HYCUADDatabase -AllowHardRepair`
  attempts an `esentutl /p` (**destructive**, last resort).
- **dsamain and ADWS** — `dsamain` exposes **LDAP only** (no ADWS); that is why the module reads
  the snapshot over **raw LDAP** (`System.DirectoryServices`) and reserves the `ActiveDirectory`
  module for production writes.
- **Referential consistency** — Restoring a user without its groups (or vice versa) can leave
  inconsistent links; prefer **bulk** restore of a coherent scope.
- **Full forest recovery** — This tool targets **object recovery** (granular). A full **forest/DC**
  recovery after ransomware remains a dedicated process (DC rebuild, FSMO seizing, metadata cleanup).

---

## 8. Logging and undo

- Logs: `%APPDATA%\HYCU\ADRecoveryTool\logs\` (one file per day).
- **Automatic undo**: before any write, the object's *live* state is exported to LDIF in
  `…\logs\undo\`. If needed, re-import that file with `Import-HYCUADLdif` to roll back.
- `ldifde` logs: `…\logs\ldifde\`.
- **Staging auto-clean**: each restore drops a local copy of the database (`ntds.dit` + journals,
  several GB) under the staging folder (`flr_*` / `snap_*`). The tool keeps the **3** most recent and
  removes older ones automatically before each new restore. Tune or disable it with
  `Set-HYCUADConfig -StagingKeepLast <n> -StagingMaxAgeDays <days> -StagingAutoClean $false`, or prune
  on demand with `Clear-HYCUADStaging` (supports `-WhatIf`). A folder still mounted by `dsamain` is
  skipped, so unmount the snapshot (`Dismount-HYCUADSnapshot`) before it can be cleaned.
- **Share cleanup**: after the database has been copied locally, the tool deletes the files HYCU
  restored to your target share (the NTDS and, if included, SYSVOL folders), then removes the empty
  parent folders it created — **never the share root, and never a folder that still holds your own
  data**. On by default; disable globally with `Set-HYCUADConfig -ShareCleanup $false` or per run with
  `Start-HYCUFileLevelRestore -CleanupShare $false`. The local copy is always kept regardless.

---

## 9. Scripted / scheduled scenarios (CLI)

Everything the GUI does is exported by the module, so the recurring checks can run headless from
Task Scheduler. Import the module first:

```powershell
Import-Module C:\Tools\HYCUADRecovery\HYCUADRecovery.psd1 -Force
```

**A. Scheduled backup restorability test** — proves the latest AD backup actually mounts and reads
(the check that matters *before* the day you need it). Writes a PASS/FAIL HTML report under
`…\logs\reports\`:

```powershell
$p   = Get-HYCUADProfile -Name prod                              # DPAPI profile saved from the GUI
$h   = Connect-HYCUController -Server $p.Server -AuthMode Token -ApiToken $p.ApiToken
Invoke-HYCUADRestorabilityTest -Session $h -VmName DC01 -TargetUnc '\\nas\Restore' `
    -TargetUsername svc_restore -TargetPassword $p.RestoreTargetPassword -Confirm:$false
Disconnect-HYCUController -Session $h
```

Register it (weekly example):

```powershell
schtasks /Create /TN "HYCU AD restorability" /SC WEEKLY /D SUN /ST 06:00 `
    /TR "powershell -NoProfile -ExecutionPolicy Bypass -File C:\Tools\HYCUADRecovery\RestorabilityCheck.ps1"
```

**B. Drift report** — what changed in production since the backup (HTML digest):

```powershell
$s = Connect-HYCUADSnapshot -SourcePath 'D:\staging\flr_20260707_060000\NTDS'
Export-HYCUADDriftReport -Session $s -LiveServer dc01.corp.local
Dismount-HYCUADSnapshot -Session $s
```

**C. Compare two restore points** — "when did this attribute change?":

```powershell
$old = Connect-HYCUADSnapshot -SourcePath D:\staging\flr_monday\NTDS
$new = Connect-HYCUADSnapshot -SourcePath D:\staging\flr_friday\NTDS
Compare-HYCUADSnapshots -ReferenceSession $old -DifferenceSession $new |
    Format-Table Status, Name, DistinguishedName -AutoSize
Dismount-HYCUADSnapshot -Session $old; Dismount-HYCUADSnapshot -Session $new
```

**D. Whole-OU (subtree) restore** — parents first, simulation by default:

```powershell
$items = Get-HYCUADSubtreeChanges -Session $s -BaseDN 'OU=Sales,DC=corp,DC=local' -LiveServer dc01
Invoke-HYCUADBulkRestore -Session $s -Items $items -LiveServer dc01 -WhatIf     # then rerun without -WhatIf
```

**E. GPO content diff** — settings (Registry.pol) and files, snapshot vs production:

```powershell
Compare-HYCUADGpoContent -Session $s -PolicyGuid '{31B2F340-016D-11D2-945F-00C04FB984F9}' -Domain corp.local |
    Format-Table Kind, Status, Item, Detail -AutoSize
```

**F. Post-recreation assistant** — reset + enable the accounts a restore had to recreate:

```powershell
Reset-HYCUADRecreatedAccount -Identity jsmith, mjones -Server dc01     # prompts; passwords returned once, never logged
```

---

## 10. Quick troubleshooting

| Symptom | Hint |
|---|---|
| `dsamain stopped (code …)` | The error now includes **dsamain's own output** (also saved to `…\logs\dsamain_*.log`). Most common cause: a **version mismatch** — dsamain mounts only a database from its own Windows Server version or **older**, so a newer DC's `ntds.dit` cannot be mounted on an older host (run on a host ≥ the DC's OS). Also: *Dirty* database → `Repair-HYCUADDatabase`; missing `edb*.log` journals; or insufficient rights. |
| `LDAP port did not respond` | Port already in use → change `-Port`; local firewall. |
| LDAP connection to the snapshot refused | Enable `Set-HYCUADConfig -AllowNonAdmin $true` (adds `/allowNonAdminAccess`). |
| `New-ADUser: Access denied` | Account without AD write rights, or protected OU. |
| No "Deleted" objects detected | Matching is by `objectGUID`; check the same domain/NC on both sides. |
| HYCU REST connection / TLS handshake fails (*"underlying connection was closed… on a send"*) | The client raises **TLS 1.2** automatically before each call, which fixes the common **Windows Server 2012 R2** case. It prefers **`curl.exe`** when present (Windows 10/11, Server 2019+) but **2012 R2 ships without curl**, so it uses native .NET there. If a handshake still fails, the controller may need a cipher the old host lacks — run the connection from a newer host (curl is then used automatically). Force the transport with `Set-HYCUADConfig -HycuTransport Curl|DotNet|Auto`. |

---

## 11. License / liability

Provided "as is", without warranty. Check compliance with your internal policies and your
vendors' terms before any production use.
