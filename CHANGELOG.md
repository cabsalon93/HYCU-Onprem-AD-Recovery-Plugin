# Changelog

All notable changes to **HYCU AD Recovery Tool**.

## [Unreleased]

### Fixed (2026-07-14 - "Mount failed: Index operation failed" regression)
- **Step 5 "Mount and compare" (and the single-object "Compare with production") threw
  `Index operation failed; the array index evaluated to null` on real data.** Two causes, both from the
  attribute-diff array shape:
  - The new "Modified breakdown" diagnostic indexed a hashtable with each diff's `.Attribute`. It is now
    rewritten to flatten defensively and use `Group-Object` (no hashtable/array indexing), and the whole
    diagnostic is wrapped in try/catch so an informational log can never break the comparison.
  - **Root cause:** several call sites wrapped `Compare-HYCUADAttributeBag` in `@()`. That function
    already returns a leading-comma array (shape-preserving for a single diff), so `@()` re-nested a
    MULTI-attribute result into a 1-element array-of-array. Consequences on any object with more than one
    changed attribute: `ChangedCount` reported **1** instead of the real number, and iterating the diffs
    yielded the inner array (whose `.Attribute` is an `Object[]`), which threw during the breakdown, the
    side-by-side rows, and the attribute cart. Fixed at every call site (`Compare-HYCUADObjects`,
    `Compare-HYCUADSnapshots`, `Get-HYCUADObjectDiff`, `Get-HYCUADObjectComparison[Rows]`) by assigning
    the bag directly and wrapping stored copies/counts with `@()`. A regression test now covers an object
    with four changed attributes (previous mocks only exercised a single attribute, which hid the bug).

### Fixed (2026-07-14 - full code review pass)
A complete review of the four modules surfaced and fixed the following (validated: parse, manifest,
Pester 91/91 on Windows PowerShell 5.1 AND PowerShell 7, GUI headless load, single-file exe rebuilt):

**Recovery engine**
- **Deleted GPO recreation used the wrong branch**: the class dispatch matched by substring, so a
  `groupPolicyContainer` fell into the *group* branch (`New-ADGroup` with an empty SamAccountName -
  guaranteed failure) instead of the generic object recreation. Exact-match dispatch now.
- **A failed production read no longer yields an "all Deleted" scan**: the comparison aborts with an
  actionable error instead of continuing against an empty live set (which could have fed a mass
  recreation of objects that still exist).
- **A failed Recycle Bin reanimation no longer silently degrades to recreation**: when a reanimable
  tombstone exists (SID + password preserved) but `Restore-ADObject` fails (e.g. the parent OU is
  missing), the restore now stops with the real cause instead of quietly recreating with a NEW SID.
- **Attribute/membership failures now surface**: per-attribute and per-group errors used to be logged
  and swallowed, so the bulk summary and the audit HTML report said "OK" even when nothing was
  written. They are collected and propagated; the item is recorded as failed.
- **Moved/renamed objects can now be restored**: writes address the live object by its objectGUID
  (the snapshot DN of a moved object no longer resolves); system-owned attributes
  (distinguishedName/name/cn/objectClass) are skipped with a warning instead of failing every time.
- **`Import-HYCUADLdif` checks the ldifde exit code** (failures were logged as SUCCESS).
- **GPO SYSVOL files are no longer touched for skipped items**: the SYSVOL copy now runs only for
  Deleted/Modified GPOs (an Unchanged GPO could previously have its production policy files overwritten).
- Also: append-mode `description` restore refuses to proceed when the live read fails (a failed read
  must not cause the overwrite Append mode promises to prevent); `Test-HYCUADPrerequisite -RequireLiveAD`
  now fails when the ActiveDirectory module is missing; Registry.pol parser bounds checks; single-element
  diff arrays no longer unroll on PS 5.1 (`Get-HYCUADObjectDiff`); clearer dsamain port-retry message;
  dual-mount guidance (`Compare-HYCUADSnapshots` needs `DsamainResidueScope='Matched'`).

**HYCU REST client**
- **`Invoke-HYCUADRestorabilityTest` was unusable**: it called `Get-HYCURestorePoint` with a parameter
  that does not exist and sorted on properties the output never had (arbitrary restore point).
  It now selects the genuinely latest restore point.
- **A failed HYCU restore job now surfaces immediately** instead of being swallowed and followed by a
  30-minute wait for files that would never arrive (e.g. wrong share credentials).
- **The ntds.dit watcher can no longer latch onto stale data**: files already on the share before the
  restore are recorded and ignored unless overwritten - previously an old ntds.dit (leftover or the
  operator's own copy) could be "retrieved" as current data and then DELETED by the share cleanup.
- **The stability wait fails cleanly** when the copy never stabilizes before the timeout (a torn,
  still-being-written database can no longer be copied), and a vanished file is no longer mistaken
  for a stable one.
- **Pagination no longer truncates** when the controller clamps the requested page size (the reported
  total is now trusted over page fill).
- **Mount failures are detected fast**: the mount-report poll checks the job state and fails with the
  real error instead of polling for 10 minutes.
- Also: curl output is decoded as UTF-8 (accents in VM names/job messages were garbled on PS 5.1).

**Profiles / GUI**
- **A finished recovery fully resets the wizard**: NtdsPath / VM / restore-point / selection state are
  cleared on Finish, when another restore point or controller is picked, and when the source mode
  changes - previously a second recovery could silently reuse the PREVIOUS backup's NTDS files.
- **Failures are visible**: worker errors now raise an error dialog (the UI used to just return to
  "Ready."), and validation warnings appear in the status bar instead of only in the log file.
- **Post-recreation assistant hardened**: it honors the Simulation (-WhatIf) checkbox, and a simulated
  restore no longer overwrites the list of accounts the last REAL restore recreated (clicking
  "Reset + enable" could have acted on accounts that were never restored).
- Also: Restore button guards against a dismounted session (previously a crash path); dismount clears
  the stale tree/selection; the tree search and GPO list respect the busy state (keyboard could race
  the worker's LDAP session); unreadable profile files are named in the warning.

### Fixed (2026-07-14)
- **Wizard step titles were off by one**: when the "Restore destination" step was inserted, the centre
  panel titles were never renumbered - the panel after it still said "Step 3", so the left column
  ("6. Selection") and the centre title ("Step 5") disagreed from there on. Panel titles, log
  messages and tooltips now match the 7-step nav (1 Connect, 2 Controller + restore point,
  3 Restore destination, 4 Retrieve NTDS, 5 Mount + compare, 6 Selection, 7 Restore); README updated.
- **Test suite portability**: the two `Should Throw` assertions (empty-token profile,
  `Wait-HYCURestoredNtds` timeout) failed when Pester 3.4 ran under PowerShell 7 (its `Should Throw`
  predates PS Core and missed the exception there) while the functions behaved correctly. Rewritten
  with an explicit try/catch so the suite is green on both Windows PowerShell 5.1 and PowerShell 7
  (91/91 on each).

### Added (2026-07-14)
- **"List GPOs" button on the Selection step**: lists every Group Policy object in the snapshot by its
  friendly display name (instead of the raw `{GUID}` nodes under `CN=Policies,CN=System`), with the
  usual actions - go to / compare with production, or add straight to the restore cart (SYSVOL content
  is restored with the GPO).

### Changed (design)
- **Light professional theme - the neon look is gone.** The dark near-black background with glowing
  violet accents is replaced by a light HYCU-branded theme: Ghost/white surfaces, dark text, purple
  reserved for the header band, buttons and accents (same official HYCU palette, same hues as the HTML
  restore report). Includes: light selection/hover states in every list and the tree, pastel (not neon)
  colour-coding in the compare view, a dark-green check mark on completed wizard steps, a light busy
  overlay, and dialogs (cart, search, changes, Recycle Bin, About, prerequisites) restyled to match.

### Fixed
- **Stray `ntds.INTEG.RAW` next to the executable**: `esentutl /p` (hard repair) writes its integrity
  scratch file into the process's CURRENT directory - i.e. beside the exe. The repair now runs with
  the database folder as its working directory and the scratch file is removed once esentutl exits.
  An existing `ntds.INTEG.RAW` from an earlier run can be deleted safely.
- **Single-attribute changes were reported as "Unchanged"**: when exactly ONE attribute differed,
  PowerShell 5.1 unrolled the diff array to a scalar whose `.Count` was `$null`, so the scan
  (`Compare-HYCUADObjects`) silently classified the object as unchanged and it never appeared in
  "Scan all changes". Fixed at the source (`Compare-HYCUADAttributeBag` keeps its array shape) and
  guarded at every call site; a regression test now pins the single-attribute case.

### Added (functions)
- **Attribute cherry-pick**: after "Compare with production", select specific rows in the attribute
  grid and click "Add selected attrs" - the cart entry restores ONLY those attributes.
- **Restore into another OU**: an optional target container on the Restore step (and
  `-TargetParentDN` on `Restore-HYCUADObject`/`Invoke-HYCUADBulkRestore`); deleted objects are
  reanimated (Recycle Bin `-TargetPath`) or recreated under that OU - quarantine / collision-safe.
- **Whole-subtree restore**: "Add subtree" scans the selected container/OU
  (`Get-HYCUADSubtreeChanges`) and carts every Deleted/Modified object under it, parents first, so a
  bulk restore recreates the OU before its children.
- **Post-recreation assistant**: "Reset + enable recreated users" after a real restore (and
  `Reset-HYCUADRecreatedAccount`): crypto-random password, change-at-next-logon, account enabled;
  passwords are displayed once and never logged.
- **Backup restorability test**: `Test-HYCUADSnapshotHealth` (esentutl state + real dsamain mount +
  LDAP object counts + PASS/FAIL HTML report) and `Invoke-HYCUADRestorabilityTest` (latest restore
  point -> retrieve -> verify, schedulable) - proves the AD backup is usable before the day it is needed.
- **Drift report**: `Export-HYCUADDriftReport` renders the production-vs-backup comparison as a
  standalone HTML digest (schedulable).
- **Compare two restore points**: `Compare-HYCUADSnapshots` diffs two mounted snapshots by objectGUID
  (OnlyInReference / Modified / OnlyInDifference) - "when did this change?".
- **GPO content diff**: `Read-HYCUADRegistryPol` (PReg parser) and `Compare-HYCUADGpoContent` diff a
  GPO's actual SYSVOL content (Registry.pol settings + files) between snapshot and production.
- **Scripted/scheduled recipes**: new README section with ready-to-schedule CLI examples
  (restorability check, drift report, snapshot compare, subtree restore, GPO diff, post-recreation).
- **AD Recycle Bin browser** (read-only): a "Recycle Bin" button on the selection step lists objects
  still in the live AD Recycle Bin (reanimable with their SID/password/links preserved), with a live
  filter - answering "is it still recoverable without a backup?" in seconds. New public function
  `Get-HYCUADRecycleBinObject` (writes nothing; needs RSAT + the AD Recycle Bin feature enabled).

### Added (usability + audit)
- **Restore report (HTML)**: after a live restore, the tool writes a branded, standalone HTML audit
  report (operator, workstation, date, source snapshot, live DC, and a per-object OK/FAILED table) next
  to the run log under `reports\`, and offers to open it. `Export-HYCUADRestoreReport` is a public
  function; all values are HTML-encoded (a crafted DN cannot inject markup).
- **View log** button in the header - opens the current run's log file (no more hunting in Explorer).
- **Wizard progress ticks**: completed steps show a green check mark, the current step is highlighted,
  upcoming steps are dimmed.
- **Restore button shows the cart size** ("Restore (3)") in cart mode; the count updates live.
- **Compare view is colour-coded** by change kind: green = value present only in the backup (recoverable),
  amber = value differs, red = value exists only in production (a restore would revert it).
- **Filter box in "Scan all changes"**: type to narrow the change list by name, type, status or DN.

### Hardening (code-review pass)
- **Safer offline repair**: the destructive `esentutl /p` now runs automatically only on a *confirmed*
  "Dirty Shutdown" - never on an "Unknown" (unparsed) state - so a possibly-clean database is never
  hard-repaired. Force with `-AllowHardRepair`.
- **Restore integrity**: the undo LDIF is only reported when `ldifde` truly succeeded (else a clear warning);
  SYSVOL restore creates the target folder if the GPO was fully deleted and copies literal-path-safe;
  Recycle-Bin lookup is by `-Identity` GUID (not a `-Filter` string).
- **HYCU client robustness**: pagination no longer truncates when the controller omits `totalEntityCount`
  (stops on a non-full page; caps are logged, not silent); a non-JSON 200 response is reported clearly;
  job polling is null-safe.
- **Profiles**: a profile that cannot be decrypted (different user/machine, or corrupt) now gives a clear,
  actionable message instead of a cryptic late failure.
- **GUI robustness**: diffs are handed back to the UI thread instead of being written from the worker;
  synchronous actions (dismount/compare/select/add-to-cart/expand) are guarded while an async op runs; the
  worker runspace is disposed even if `Close()` throws; closing during an async op stops the timer/pipeline
  first; the cart is a synchronized collection.
- **Rename**: `Sync-HYCUADGroupMembership` -> `Update-HYCUADGroupMembership` (approved verb; no import warning).
- **Tests**: added coverage for `Restore-HYCUADAttribute` (append/clear/byte[]), `Compare-HYCUADObjects`
  (GUID matching), the profiles module, and manifest validity. Suite now 73 tests.

### Added
- **Restore result summary**: after a REAL restore, a popup reports how many objects **succeeded / failed**
  (of the total) and lists each failure with its reason - so the outcome is visible without opening the log.
  The engine (`Invoke-HYCUADBulkRestore`) now returns a per-object result; a failed object is recorded (not
  silently reported as "finished").
- **Recovery diagnostic in the log**: when the staged database is Dirty, the log now shows the **`Log Required`**
  range from the `ntds.dit` header and the **transaction files present** (`edb*.log` / `edb.chk`), plus a note.
  This makes it obvious why a hard repair (`/p`) is needed - a required log missing (re-pull the backup with
  the logs + checkpoint) vs. logs present but signatures mismatched (files captured at different moments).

### Changed
- **sIDHistory write hardened + clearer message**: the original SID is now offered to `sIDHistory` as a
  `SecurityIdentifier` first (raw bytes as fallback). When it cannot be set, the log explains this is
  **expected for a same-domain restore** (AD blocks adding a same-domain SID as history by design) and points
  to the real SID-preserving paths (Recycle Bin before purge, or an authoritative DC restore).
- **Recreation is now resilient to rejected attributes**: a deleted object is recreated with its identity
  first, then its other attributes are applied - all at once, and if the directory rejects the batch, each is
  retried individually so only the offending attribute(s) are skipped (and logged). One system-owned/
  unsettable attribute (e.g. `primaryGroupID`, which needs group membership first) no longer aborts the whole
  recreation - the object comes back with every attribute AD accepts.

### Fixed
- **Recreation failed with "...owned by the Security Accounts Manager (SAM)"**: `sAMAccountType` (and
  `sIDHistory`) leaked into the recreation attribute set; both are now in `ProtectedAttributes` (`sIDHistory`
  is applied separately). Combined with the resilient application above, deleted security principals recreate
  instead of failing on a single attribute.
- **Recreation failed with "attribute or value does not exist (adspath)"**: the ADSI-injected `adspath`
  property leaked into the recreation attribute set and `New-AD*` rejected it. `adspath` is now in
  `ProtectedAttributes` (filtered everywhere), so deleted objects recreate cleanly.

### Changed (UX)
- **Simulation now reports what it would do**: after a `-WhatIf` (simulation) restore, a popup lists what a
  real run would apply - per object (deleted → restore/recreate, modified → N attributes) with counts.
- **Step 2: the restore-point column "Tier" is renamed "Target"**.

### Added
- **sIDHistory bridge on recreation**: when a fully-deleted object is RECREATED from the backup (because it
  is no longer in the AD Recycle Bin), the tool now sets the object's **original SID as `sIDHistory`** on the
  new object (best-effort) so access granted to the old SID keeps resolving. This needs elevated rights and
  AD generally blocks adding a **same-domain** SID as history, so the write is attempted and, on failure,
  logged as a non-fatal warning (the object is still recreated). Toggle with
  `Set-HYCUADConfig -RestoreSidHistory $false` (on by default).
- **Recreation warning shown only when relevant**: the restore confirmation now adds a heads-up (new SID,
  disabled account, password/re-join needed, sIDHistory best-effort) **only when the batch actually contains
  fully-deleted objects** - attribute-only restores get the plain confirmation, no noise.

### Fixed
- **Minimal objects failed to recreate**: `New-AD*` rejects an empty `-OtherAttributes`, so an object whose
  only attributes were identity/dedicated ones threw during recreation. `-OtherAttributes` is now passed only
  when there is something to set.

### Fixed (UI)
- **"Production DC" is marked optional** on the mount step: the label now reads "Production DC (optional)",
  with a tooltip and hint explaining that leaving it empty auto-detects this machine's domain controller for
  the comparison (set it only to compare against a specific DC).
- **Step 5 toolbar no longer clips "View cart"**: the browse toolbar is a WrapPanel now, so its buttons flow
  onto a second line on a narrow window instead of the last one being cut off.
- **Tree selection is readable**: the mounted-database tree gave selected nodes the light system highlight
  (light text on a light background - unreadable). Selected nodes now use a HYCU-purple highlight with light
  text, via a custom TreeViewItem template (with a simple rotating-arrow expander).

### Changed (UX)
- **Action buttons folded into Next - one button drives each step**: the wizard no longer has separate
  "Validate" (step 1), "Retrieve files from HYCU" (step 4) and "Mount + Compare" (step 5) buttons. Clicking
  **Next** now performs that step's action and only advances **if it succeeds**; on failure it stays put and
  shows a clear error dialog (with the reason).
  - *Step 1*: Next connects to the HYCU controller. Changing any connection field
    (controller/port/API version/user/password/token/auth mode) invalidates a prior validation so Next
    re-connects with the new values.
  - *Step 4*: Next retrieves the database from HYCU **once** - going Back then Next again does not repeat it
    (it is skipped when the database is already retrieved).
  - *Step 5*: Next mounts the snapshot and compares with production **once** (skipped if already mounted),
    then advances to Selection.

### Fixed
- **Single-file exe hung on "Connecting to the HYCU controller"** (clock ticking forever): the async worker
  runspace did `Import-Module <path>` for the engine, but the single-file exe ships no `.psd1` on disk, so
  the import threw *before* the worker's `try/finally` and `$sync.Done` was never set - the UI spun forever.
  Two fixes: (1) the single-file build now **self-extracts** the embedded module files to a temp folder and
  points `$env:HYCU_MODULE_DIR` at it, so the GUI and every worker runspace `Import-Module` a real `.psd1`;
  (2) the worker's `Import-Module` moved inside the `try/finally`, so any future load failure surfaces as an
  error instead of an infinite "in progress". (The multi-file exe and `.ps1` were unaffected.)

### Branding
- **HYCU application icon**: the window (title bar / taskbar / Alt+Tab) and the compiled `.exe` now carry a
  HYCU icon - the official white logomark on a HYCU-purple rounded badge. The window icon is rendered at
  runtime from the embedded vector (so it works in the single-file exe with no side files); the exe file
  icon is a multi-resolution `assets\HYCU.ico` (16-256 px) generated by `Make-Icon.ps1` and embedded at
  build time. Run `Make-Icon.ps1` once (or after changing the logo) to (re)generate the `.ico`.

### Changed (UX)
- **Auto-advance after a successful mount**: when *Mount + Compare* succeeds, the wizard now moves straight
  to *Selection* (the tree is loaded) - no manual "Next" click needed.

### Fixed
- **Restore-cart / changes / search rows unreadable on Server 2012 R2**: the `GridViewRowPresenter` did not
  reliably inherit the row foreground on .NET 4.5 (dark text on dark background). Each list now sets an
  explicit light `TextBlock` style so rows are always legible.

### Build
- **Single-file `.exe`**: `Build-SingleExe.ps1` inlines the 3 modules + the GUI into one script and compiles
  it to a single self-contained `dist\HYCUADRecovery.exe` (~0.29 MB) - no side files at all (no module
  files, no examples, no repo/tooling files). `Build-Exe.ps1` (portable folder: exe + module files) remains
  as an alternative. Prerequisite: `Install-Module ps2exe -Scope CurrentUser`.
- **Fixed a single-file startup crash**: the engine's default `StagingRoot` used `$PSScriptRoot`, which is
  empty when the code is inlined into one exe, so `Join-Path` threw at startup. It now falls back to a
  per-user writable location; the module-based path is unchanged.
- **Standalone Windows `.exe`**: `Build-Exe.ps1` compiles the WPF GUI with **PS2EXE** (`-STA -noConsole`)
  to `dist\HYCUADRecovery.exe` and ships the module files (`*.psd1`/`*.psm1`) next to it - a portable
  package that runs with no install (the exe resolves its modules from its own folder). Prerequisite:
  `Install-Module ps2exe -Scope CurrentUser`. To require elevation on launch (recommended for production -
  dsamain + AD writes need admin), add `-requireAdmin` to the `Invoke-ps2exe` call.
- **Fixed exe startup crash**: under PS2EXE `$MyInvocation.MyCommand.Path` is `$null`, so
  `Split-Path -Parent $null` threw a terminating error and the exe died before it started (a hidden
  error dialog under `-noConsole`). The path is now guarded and falls back to the executable's own folder.

### Added
- **About box**: an "About" button in the header opens a branded dialog showing the product name
  (**HYCU AD Recovery Tool**), that it is a **Plugin for HYCU Enterprise Cloud**, a notice that it is a
  **free plugin provided as-is without any warranty or engagement from HYCU**, the build **version**
  (a `YYYYMMDDHHMM` timestamp, e.g. `202607011252`, bumped on every build) and the path of the current
  run's log file.
- **Per-run log file**: the detailed log now streams to `Logs\HYCUADRecovery_<timestamp>.log` next to the
  program (a new file each run; the newest 30 are kept, older ones pruned). Each file starts with a header
  (product, version, run time, domain\user, host). If the program folder is not writable, it falls back to
  `%LOCALAPPDATA%\HYCU\ADRecoveryTool\Logs`. Works both as a `.ps1` and as a PS2EXE `.exe`.

### Removed
- **The bottom log panel is gone**: now that mount/compare/restore show live progress through the busy
  overlay (spinner + phase + elapsed + current sub-step) and the status bar, the scrolling log panel was
  redundant on screen. All that detail is preserved in the per-run log file above; the wizard reclaims the
  freed space.

### Fixed
- **Cart view hardened**: the "View cart" dialog now snapshots the cart into a fresh array each paint,
  resets `ItemsSource` before rebinding, and guards against missing controls. The restore engine and
  cart display live in different files - `HYCUADRecovery.psm1` (engine) and
  `Start-HYCUADRecoveryGUI.ps1` (GUI). If the cart showed `0 item(s)` while the log said items were
  added, the running GUI/`.exe` predated this file: redeploy `Start-HYCUADRecoveryGUI.ps1` (or rebuild
  the `.exe`). The current paint logic is verified to display the true count (tested headless with the
  full styled ListView).

### Changed
- **Hard repair is now an automatic last resort (no checkbox)**: a dirty database is recovered
  automatically - soft recovery → lossy recovery (`/a`) → `esentutl /p` - without the operator ticking
  anything. The "Allow hard repair" checkboxes were removed. It only ever repairs the OFFLINE staged
  copy (never production), so it is safe for an offline read-only mount; disable with
  `Set-HYCUADConfig -AutoHardRepair $false` if you prefer to be asked.

### Added (UX / fluidity)
- **Busy overlay during long operations**: retrieve / mount / compare / recovery now show a full-window
  overlay with a spinner, the current phase, a live elapsed timer and the latest sub-step - so a long
  step never looks frozen.
- **Find an object by name**: a search box above the tree finds objects by name / displayName /
  sAMAccountName and lists the matches; double-click (or "Go to") to inspect one, or select several and
  "Add to cart". Double-clicking a tree node also compares it directly.
- **Keyboard navigation**: Enter = Next, Esc = Back throughout the wizard (Enter is not hijacked while
  typing in the search box or a multi-line field).
- **Remembers your last session**: window size/position, the last profile and the destination
  (server/share/domain/user) are restored on the next launch.

### Changed
- **Removed the "Advanced / Dashboard" tab** - the tool is now a single guided wizard (the dashboard only
  duplicated the mount/compare/restore for a pre-existing NTDS folder and caused confusion). The tab strip
  is gone too, so it opens straight into the wizard.
- **SYSVOL is now always copied** (the "Also copy SYSVOL" checkbox is gone) so Group Policy content can
  always be restored with its GPO.
- **"Finish" now does something**: it dismounts the snapshot (freeing the LDAP port), clears the stale
  cart and returns to step 1 for a new recovery (after a confirmation). Production is not affected.
- **GPO restore restores the policy content too** (see Fixed) - restoring a GPO now brings back its SYSVOL
  files automatically, not just the empty AD object.
- **GPOs show their name (displayName), not the `{GUID}`** - in the tree and the "scan all changes" (GPOs
  are now included in the scan). Selecting/comparing a GPO also shows where its content restores to
  (`\\<domain>\SYSVOL\<domain>\Policies\{GUID}`).
- **"Scan all changes" / cart selected rows are readable** (see Fixed).
- **Default LDAP port is now 41389** (was 51389) - engine config `LdapPort`, both GUI port fields, and the
  docs. Still shifts up automatically if the port is busy, and overridable with `Set-HYCUADConfig -LdapPort`.
- **Window no longer fills a small screen**: the main window was a fixed 1240×820 (larger than a 1024×768
  RDP desktop, so it spilled off-screen). It now opens at **~80% of the screen work area** (e.g. ~819×592
  on 1024×768), is **resizable and maximizable**, never starts larger than the screen, and keeps a usable
  minimum (800×560). On bigger screens it scales to 80% too.

### Fixed
- **dsamain JET -1216 (looked like a "port stuck" problem, wasn't)**: `netstat` showed the ports free, yet
  dsamain failed and the tool kept shifting ports. Root cause: dsamain keeps per-instance recovery logs in
  `%TEMP%\DS<port>`, and a leftover `DS<port>\edb.log` from a previous run references a now-repaired/deleted
  `ntds.dit`, so dsamain's recovery aborts with **-1216** ("attached database mismatch / database moved or
  renamed"). The tool now clears these working dirs **fully automatically** - the specific `%TEMP%\DS<port>`
  before every mount attempt, AND a sweep of **all** stale `DS<port>` dirs inside the residue cleanup that
  runs at every mount / dismount / exit. So dsamain always starts clean and the operator NEVER has to delete
  `%TEMP%\DS*` by hand. The retry message no longer mislabels this as a busy port. (Also confirmed:
  `esentutl /p` now auto-confirms and completes - repair+defrag in ~90 s.)
- **Default port drifted up each session (41390, 41391…) - leftover dsamain not cleaned**: a previous
  session's dsamain kept the default port, so the next mount shifted up instead of reusing 41389. The
  residue cleanup now stops **every** leftover `dsamain.exe` by default (`DsamainResidueScope='All'` -
  safe, since dsamain.exe is only ever this tool, never a live DC), so the default port is reused. Set
  `Set-HYCUADConfig -DsamainResidueScope Matched` if you deliberately run a second, unrelated dsamain mount.
- **Port "stuck until reboot" - leftover dsamain now reliably stopped**: the residue cleanup identified
  dsamain by its command line, which silently fails when WMI cannot read the command line - so a leftover
  dsamain kept the LDAP port bound until the server was rebooted. The cleanup now ALSO finds and stops the
  process that actually **holds the target port** (by PID, from the TCP/UDP tables - `Get-NetTCPConnection`/
  `Get-NetUDPEndpoint`, with a `netstat` fallback), if it is a dsamain. So a mount on a "stuck" port frees
  it automatically. (To free every port by hand without rebooting: `taskkill /im dsamain.exe /f` - safe,
  dsamain.exe is only ever this tool; a live DC runs as lsass/NTDS, never dsamain.)
- **dsamain `-550` on one port now retries instead of aborting**: a JET `-550` (Dirty Shutdown) was
  treated as fatal ("another port won't help"), but it can also be a leftover dsamain still holding the
  database - in which case a residue purge + a different port mounts cleanly (observed live: `-550` on
  51389, clean mount on 41389). The mount now purges residue and retries up to 3 times on a database
  error before giving up; a genuinely dirty database still fails fast.
- **dsamain mount could fail on a free-looking port (error 10048)**: dsamain binds the LDAP port on **TCP
  and UDP** (LDAP + CLDAP), but the port-free check only tested TCP - so a port held on UDP (typically a
  leftover dsamain) was handed to dsamain, which then failed with *"only one usage of each socket address"*.
  The check now requires the port free on **both TCP and UDP**, so the retry loop skips it. The dsamain
  failure message now reads dsamain's actual output and names the real cause (port-in-use → close leftover
  `dsamain.exe`; DB attached-then-stopped/8431 → repair didn't finish) instead of always blaming a version
  mismatch. *(Confirmed on the live box: a clean database mounts fine - the earlier 8431 was a half-finished
  repair, never a version problem; host and DC are both Server 2012 R2.)*
- **Comparison missed `description` (and other attributes) on computers**: the LDAP query requested no
  explicit property list, so the server returned only its default attribute set - which omits `description`
  for some object classes (e.g. computer), so a changed computer description showed as "Unchanged". The
  query now requests all attributes (`*`), so every object class is compared in full (snapshot + live).
- **Restore no longer overwrites a live `description`**: restoring a *modified* object used to replace the
  whole `description` with the backup value, wiping notes added after the backup. It now **appends** the
  backup value to the live one (de-duplicated) and never clears it - configurable via
  `Set-HYCUADConfig -DescriptionRestoreMode Append|Replace` (default `Append`).

### Changed ("nothing happens", though it launched fine on the
  Server): two causes, both handled. (1) WPF needs an **STA** thread - if started in MTA (PowerShell 7
  `pwsh`, or `powershell` without `-STA`) `ShowDialog()` silently failed; the script now detects MTA and
  **relaunches itself in STA**. (2) On a client the server-only tools are missing, so the prerequisites
  dialog ran *before* the main window - if it failed, the main window never showed; that dialog is now
  isolated (it can never block the main window) and any startup failure is surfaced (log + message box)
  instead of failing silently.
- **"View cart" / "Changes" pop-ups crashed on Windows Server 2012 R2** (`ShowDialog` → *"Value cannot
  be null. Parameter name: key"*): a WPF `DataGrid` inside a runtime-loaded secondary window throws under
  the Aero theme / .NET 4.5 on 2012 R2. Both pop-ups now use a `ListView`/`GridView` (rock-solid on every
  .NET) instead of a `DataGrid`. They also set their `Owner` to the main window (so they open on top, not
  behind), and the View-cart buttons surface any error to the log.
- **Profile drop-down was unreadable** (light text on the default light pop-up): the profile `ComboBox`
  items now render as light text on a dark HYCU-purple background (purple highlight/selection), so every
  saved profile is legible. The boxes stay editable, so you can still type a new name to save a profile.
- **Automatic hard repair hung forever on Server 2012 R2**: `esentutl /p` waits for a confirmation
  ("Do you wish to proceed?") that the auto-dismiss never answered (it only clicked *OK*, never *Yes*,
  and there was no timeout), so the tool spun with no progress. It now answers the prompt on **every**
  channel - feeds `Y` on stdin (console prompt) and posts both *OK* and *Yes* to the dialog - and a hard
  timeout (`Set-HYCUADConfig -EsentutlRepairTimeoutSeconds`, default 1200 s) guarantees it can never hang;
  on timeout it stops `esentutl` and tells you to run `esentutl /p "<ntds.dit>" /8` by hand. Added an
  **idle watchdog**: if `esentutl /p` makes no CPU/output progress for 90 s (its prompt could not be
  auto-answered on this host), the tool stops it and re-checks the database instead of sitting out the
  full timeout - so a stuck prompt now costs ~90 s, not 20 minutes. (`esentutl /p` usually finishes the
  real repair in seconds; a long idle is the prompt, not the repair.)
- **dsamain attached the database then stopped (failure 8431) even after a clean repair**: a hard-repaired
  (`/p`) database is consistent for ESE - so dsamain *attaches* it - but AD DS often still won't *start*
  on it. Microsoft's repair workflow finishes with an **offline defragment** (`esentutl /d`) that rebuilds
  the database into the structure AD DS expects. The repair escalation now runs `/d` automatically after a
  successful `/p` (recovery → `/p` → `/d` → mount). Verified with the operator that this was **not** a
  Windows-version mismatch (host and source DC are both Server 2012 R2).
- **Restored files were left on the share** ("Skipped (not under share root)"): the cleanup compared a
  UNC path against the `HYCUTGT:\` PSDrive root (different namespaces), so it never matched. It now uses
  the share's UNC root, so the multi-GB NTDS/SYSVOL restore is removed from the share after the local copy.
- **Every progress line was logged twice** in the GUI: the file-level-restore progress reached the log
  both through the engine log **sink** and through a redundant `-OnProgress` callback. Dropped the
  redundant callback. Engine `WARN`/`ERROR`/`SUCCESS` lines now also show their real level/colour in the
  GUI log (previously rendered as `[INFO] [WARN] …`).

### Fixed (code review pass)
- **Infinite loop / thread hang on empty curl output**: the curl response trailing-blank trimmer used a
  `0..($Count-2)` slice that becomes `0..-1` (= {0,-1}) for a single blank line, re-growing the array
  forever and spinning the worker at 100% CPU. Guarded with `Count -gt 1` + an explicit single-element
  case.
- **Binary attributes corrupted on restore / masked in compare**: `Get-LdapEntries` stored a single
  value via an `if`-expression, which enumerates a `byte[]` into individual bytes; on restore those were
  written back as many one-byte values (corruption), and in compare they were sorted into meaningless
  tokens (real differences masked, e.g. a `byte[]` permutation read as "unchanged"). Fixed at the source
  (direct assignment preserves `byte[]`), the compare now canonicalizes binary as hex
  (`ConvertTo-HYCUCanonicalValue`), and the restore paths keep a `byte[]` whole.
- **Mount-step UI callback never fired**: `Invoke-MountCompare`'s `$OnDone` was referenced from the
  deferred `-OnComplete` block, which runs later outside the function scope (not a closure) so it was
  `$null` - the dashboard grid stayed empty and the summary was lost after a successful compare. The
  callback is now stashed on `$sync`.
- **Restore-to-share crash when a username was given without a password** (`PSCredential` empty-string
  throw): now requires both, else maps the share unauthenticated.
- **Profiles**: a cancelled credential / empty token prompt no longer saves an unusable profile (it
  throws); the profile *list* no longer aborts on one corrupt/partial `.xml` and skips nameless entries.
- **Resource leaks**: the esentutl repair process, the RootDSE `DirectoryEntry`, and the per-probe
  `TcpClient` in the mount wait loop are now disposed.
- **Browse grid bindings**: the Step-5 attribute rows now carry `Diff`/`IsChanged` so the Δ column and
  highlight bind cleanly before Compare. Async teardown drains the log queue one last time so the final
  progress line is not dropped.
- **LDAP port now genuinely retries on the next port**: the previous free-port check only tested a
  *loopback* bind, so a port held on another interface looked free and the mount failed without
  shifting. `Test-HYCUPortFree` now enumerates **every active TCP listener** (all interfaces), and
  `Mount-HYCUADSnapshot` **retries the mount on the next port** when dsamain fails for a non-database
  reason (the dsamain launch was extracted to `Invoke-HYCUADdsamainMount`; a genuine database failure -
  JET -550/-1216/-1206/Dirty - is surfaced immediately, since another port would not help).
- **"Scan all changes" is now diagnosable**: it logs how many objects it read on each side
  ("Read N snapshot object(s) and M production object(s)") and warns explicitly if the snapshot or the
  production read returned 0 (production-read errors are now caught and logged instead of failing the
  scan silently), so a "detects nothing" result can be told apart from a read/permission problem.
- **You can review the cart before restoring**: new **View cart** button (browse step and restore
  step) opens a window listing the cart contents (status, name, class, DN); items can be removed or the
  cart cleared before restoring.
- **Checkboxes / radio buttons were invisible when selected (Windows Server 2012)**: the default WPF
  indicators use system theme brushes that vanish on the dark theme, so a ticked box / chosen radio
  looked the same as an empty one. They now use explicit templates (a drawn box with a white check, a
  ring with a filled dot in HYCU purple) so the state is always clearly visible on every OS.
- **LDAP port already in use no longer fails the mount**: if `51389` (or the configured port) is held
  by another listener, `Mount-HYCUADSnapshot` now **automatically shifts to the next free port**
  (`Test-HYCUPortFree`, up to +20) instead of erroring; the session records the actual port used.
- **"Compare with production" now shows the full picture**: it previously listed only the *differing*
  attributes (and replaced the attribute view), which looked like attributes were missing. It now shows
  **every attribute side by side** (snapshot vs production) with the changed ones **highlighted** and a
  Δ marker, and states clearly whether the object is present or absent in production (new engine helper
  `Get-HYCUADObjectComparisonRows`).

### Changed
- **Step 5 is now a database browser (no more blank screen)**: previously the "Mount + compare" step
  only listed *deleted/modified* objects, so when nothing had changed it showed an empty grid that
  looked like a failed mount. It is now a **dsa.msc-style tree** of the mounted database (always
  populated, lazy-loaded one level at a time) with the selected object's attributes on the right.
  **Compare with production** shows the differences for the selected object; **Scan all changes** still
  finds every deleted/modified object across the database and lists them in a pop-up you can add to the
  cart. **Add to cart** / **Export LDIF** work on the selected tree object. New engine helpers
  `Get-HYCUADChildNodes`, `Get-HYCUADObjectAttributes`, `Get-HYCUADObjectComparison`. (The Advanced /
  Dashboard tab keeps its bulk-diff grid.)

### Added
- **Live progress during long steps (mount + compare, restore, …)**: the engine's `Write-HYCULog`
  output now surfaces in the GUI log in real time, so the long "Mounting the snapshot and comparing…"
  step no longer sits silent. A registered sink (`Set-HYCULogSink`) forwards every non-DEBUG line to the
  UI queue the DispatcherTimer drains; the operator sees milestones as they happen — *Database state:
  Dirty Shutdown* → *Soft recovery…* → *Recovery succeeded* → *Mounting: dsamain…* → *Snapshot mounted on
  LDAP…* → *Comparison finished: N object(s)*. Raw `esentutl`/`ldifde` DEBUG output stays out of the UI
  (still written in full to `%APPDATA%\HYCU\ADRecoveryTool\logs\`); the per-file staging copy lines are
  now shown too.
- **Automatic cleanup of residual `dsamain` processes**: failed or abandoned mounts used to leave
  orphaned `dsamain.exe` instances that the operator had to kill by hand in Task Manager. New
  `Stop-HYCUADMountResidue` stops only the dsamain instances spawned by this tool (matched by its LDAP
  port or staging folder in the command line - safe even on a DC, where the live directory runs as
  lsass, never dsamain). It runs **before every mount** (clearing leftovers and freeing the LDAP port),
  on **Dismount**, and on **GUI exit**. Verified end-to-end against a real process.

### Fixed
- **Hard repair left the database unmountable (JET -1216)**: after `esentutl /p`, the old transaction
  logs/checkpoint still referenced the pre-repair database, so dsamain replayed them and failed with
  **JET -1216 (JET_errAttachedDatabaseMismatch)**. `Repair-HYCUADDatabase` now **deletes the stale
  `edb*.log` / `edb.chk` / `edb*.jrs` / `temp.edb`** after a successful hard repair - the self-consistent
  database then mounts directly with no recovery. Also: `esentutl /p` pops a GUI "Warning… Do you wish to
  proceed?" MessageBox with no flag to suppress it; the repair is now run detached and that dialog is
  **auto-hidden and auto-confirmed** (`Invoke-HYCUEsentutlRepair`), so the hard-repair path is silent and
  non-interactive.
- **Dirty-database recovery (the real "code 0" cause)**: a backup of a running DC yields a *Dirty
  Shutdown* `ntds.dit`; when the current/required ESE journals are missing, plain log replay cannot
  finish and dsamain refuses to mount with **JET `-550` (JET_errDatabaseDirtyShutdown)** — surfaced
  by the new diagnostics as the "code 0" failure. `Repair-HYCUADDatabase` now escalates: soft recovery
  (`esentutl /r edb /i /8`) → **lossy recovery (`/a`)** when logs are missing (accepts loss of
  un-recoverable transactions; far less invasive than a hard repair) → optional hard repair
  (`esentutl /p`). `Connect-HYCUADSnapshot` no longer mounts a still-dirty database — it **stops with a
  clear, actionable error** instead of the cryptic `-550`. A new **"Allow hard repair"** checkbox on the
  Mount step (wizard + dashboard) enables the `/p` last resort when even lossy recovery is not enough.

- **`dsamain stopped (code 0)` was undiagnosable**: the mount launched `dsamain` with a hidden window and
  no output capture, so the real reason was lost and the exit code was unreliable. `Mount-HYCUADSnapshot`
  now redirects `dsamain` stdout/stderr to log files, sets `EnableRaisingEvents` (so the exit code is
  correct), **also reads the Windows `Directory Service` event log** (where dsamain writes its richest
  NTDS/JET diagnostics), and on failure surfaces all of that plus the common causes via
  `Get-DsamainFailureMessage` (version mismatch, *Dirty* database / missing journals, port in use,
  rights). Additional hardening from review: a successful LDAP port no longer false-positives on a
  **foreign listener already on the port** (re-checks the process and that RootDSE returns a naming
  context, else reports "port in use"); the timeout path routes through the same actionable message; an
  unavailable exit code shows *"exit code unavailable"* instead of a misleading *code 0*; the redirect
  logs are pruned (>7 days) and removed on clean dismount; and dismount no longer pays a fixed 2 s delay.
- **GUI now uses the official HYCU brand palette**: the theme was rebuilt on HYCU's documented purple
  ladder (HP0 `#1B0C33` … HP2 *HYCU Purple* `#43128E` … HP4 *Solid Purple* `#721EF2` … HP11 `#F3F2FF`,
  source: hycu.com/company/brand) instead of the generic `#7C3AED` violet. Top band & grid headers use
  HYCU Purple, primary buttons use Solid Purple (matching the website CTAs), with on-brand lavender
  accents and text. Verified by rendering the window to a bitmap.
- **Prerequisite dialog used a harsh yellow**: the missing-tools list and the guidance box were amber
  `#FFFCD34D`; replaced with a muted teal `#FF86B3AC` (the "Modified" compare-legend amber too), pairing
  with the red "Deleted" marker. Calmer, still high-contrast on the dark theme.
- **Unreadable DataGrid column headers**: the grids set a white foreground, but the default WPF
  `DataGridColumnHeader` is a light Aero gradient — so the column titles (Status, Name, Attribute,
  Snapshot value, …) on the compare/cart grids were white-on-light and illegible. Added a
  `DataGridColumnHeader` style (dark HYCU-purple background `#FF3B1E78` + light semibold text)
  applied to every grid. Verified by rendering the grid to a bitmap.
- **OS-aware prerequisite guidance for `dsamain.exe`**: `dsamain.exe` ships only with the Windows
  Server AD DS / AD LDS role and is **not** available on Windows 10/11 client editions — but the
  prerequisite check used to tell client users to run `Add-WindowsCapability ... Rsat.ActiveDirectory.
  DS-LDS.Tools`, which installs `ldifde` and the AD module but never `dsamain.exe`, leaving them
  stuck. `Get-HYCUADPrerequisite` now reports `IsServerOS`, `DsamainRequiresServer` and a `Guidance`
  string, and **suppresses the misleading RSAT command** when the only fix is to use a server: on a
  client it points the operator to a Windows Server / domain controller; on a server it suggests
  `Install-WindowsFeature RSAT-AD-Tools` (which does include `dsamain.exe`). The GUI prerequisite
  dialog and the startup log now surface this guidance, and `Test-HYCUADPrerequisite` gives the same
  OS-aware message.

### Added
- **Share cleanup after local copy**: once `Start-HYCUFileLevelRestore` has copied the database
  locally, it deletes the NTDS (and, if restored, SYSVOL) files HYCU dropped on the operator's
  target share, so the multi-GB restore data does not linger there. New helper
  `Remove-HYCURestoredShareFiles` removes only the restored leaf folders, then prunes the now-empty
  parent folders **up to but never including the share root** — a non-empty parent stops the prune,
  so pre-existing operator data on the share is never touched. On by default (config `ShareCleanup`,
  or per call `Start-HYCUFileLevelRestore -CleanupShare $false`); best-effort (a cleanup failure
  never discards the local copy) and honors `-WhatIf`.
- **Staging auto-clean**: `Clear-HYCUADStaging` prunes old local working copies of `ntds.dit`
  (the multi-GB `flr_*` / `snap_*` folders under the staging root), keeping the most recent
  `StagingKeepLast` (default **3**) and optionally dropping any older than `StagingMaxAgeDays`
  (default **0** = age ignored, count rule only). It runs automatically before each new restore
  creates a staging folder (`Get-HYCUADStagedDatabase`, `Start-HYCUFileLevelRestore`), gated by
  `StagingAutoClean` (default **on**). Best-effort: a folder still in use (e.g. mounted by
  `dsamain`) is left in place and never aborts the restore. Honors `-WhatIf`; only ever touches
  `flr_*` / `snap_*` folders. Tunable via `Set-HYCUADConfig -StagingKeepLast / -StagingMaxAgeDays
  / -StagingAutoClean`.

## [2.0.0] - 2026-06

### Added
- **HYCU REST client** (`HYCUClient.psm1`): `Connect-HYCUController` (**Basic** or **API token**
  auth), `Get-HYCUProtectedVM`, `Get-HYCURestorePoint`
  (with **application/crash consistency** type), `Get-HYCUJob` / `Wait-HYCUJob`, `Wait-HYCURestoredNtds`
  (target-share watching) and `Start-HYCUFileLevelRestore` (file handoff orchestration, plus an
  optional best-effort REST trigger).
- **Connection profiles** (`HYCUSecrets.psm1`): `Save-HYCUADProfile` / `Get-HYCUADProfile` /
  `Remove-HYCUADProfile` - save and reuse connection settings between sessions.
- **Module manifest** `HYCUADRecovery.psd1` (v2.0.0) bundling the AD engine + HYCU client + profiles.
- **Redesigned GUI**: **Wizard** tab (guided 6-step workflow) + **Advanced / Dashboard** tab. Long
  operations run in the background (runspace + DispatcherTimer) — **the UI no longer freezes**.
  Persistent log + status bar + progress bars. HYCU purple theme with the official HYCU logomark
  embedded as a WPF vector (converted from `HYCU_Logomark_White_RGB.svg`, no external image file).
- **Pester tests** (`Tests/`): auth header, pagination, VM filtering, restore-point consistency,
  `ntds.dit` detection, attribute diff, `groupType` mapping, DN parsing.
- **Fully automated file-level restore, no HYCU console** (`Mount-HYCUBackup`, `Find-HYCUNtdsVolume`,
  `Invoke-HYCURestoreItems`, `Dismount-HYCUBackup`, rewritten `Start-HYCUFileLevelRestore`). Verified
  against a live controller: the backup is mounted (`POST /vms/{uuid}/backups/{uuid}/mount`, resolved
  via `GET /mounts`), the NTDS folder is located by **browse** (`/C/Windows/NTDS`), then **restored to
  a UNC share the operator provides** (`POST /mounts/{uuid}/restoreitems` with the target UNC +
  credentials) — because the controller does not expose a readable SMB share for the mount. The tool
  reads `ntds.dit` back from that UNC, then unmounts. New wizard **step 3 "Restore destination"**
  (UNC / domain / username / password, entered manually or loaded with the profile); the wizard now
  has 7 steps. Profiles persist the restore target. Aligned with a working production FLR
  script: the mount UUID is read from the job report (`GET /jobs/{jobUuid}/report` -> `Mount UUID:`),
  and the restore payload uses `vmUuid` + `isSharedLocation` + `restoreItemType=FILESYSTEM` (the keys
  HYCU actually requires - the previous `sharedLocation`/missing-vmUuid payload returned HTTP 500).
- `Get-HYCUADApplication`: lists HYCU **applications**, filtered to **Active Directory** domain
  controllers (`ACTIVE_DIRECTORY`) by default, each resolved to its linked VM. The GUI step 2 now
  lists **only AD domain controllers** instead of every protected VM. Restore-point timestamps are
  rendered as local dates (epoch conversion).
- HYCU configuration fields in `Set-HYCUADConfig` (server, port, API version, auth mode, target
  share, restore endpoint template).
- `CLAUDE.md`, `memory.md`, `CHANGELOG.md`, `.gitignore`.

### Changed / Fixed
- **HTTP transport via `curl.exe`** (default `Auto`): the client prefers `curl.exe` for reliable
  connections against some controllers, falling back to the .NET path. Configurable via
  `Set-HYCUADConfig -HycuTransport Auto|Curl|DotNet`. **Verified end-to-end against a live controller.**
- `Compare-HYCUADObjects`: removed the **N+1 LDAP problem** — comparison is now done entirely **in
  memory** (two queries instead of 2×N), via the shared `Compare-HYCUADAttributeBag` helper.
- `Get-LdapEntries`: the `SearchResultCollection` is now disposed explicitly.
- `Mount-HYCUADSnapshot`: renamed the `$args` variable (a PowerShell automatic variable).
- PowerShell files re-encoded as **UTF-8 with BOM** (correct accent reading by Windows PowerShell 5.1).
- *(Bug found by tests)* `Get-HYCUProtectedVM`: filter `-eq 'PROTECTED'` instead of `-match 'PROTECTED'`
  (which wrongly matched `UNPROTECTED`).
- HYCU REST field mapping aligned with a live controller (e.g. `restorePointInMillis`, `appBackup`,
  `primaryTargetName`, `completitionPct`, `taskExitMessage`), kept tolerant across versions.

## [1.0.0]
- Initial version: AD engine (`dsamain` mount, LDAP diff by `objectGUID`, restore via AD Recycle Bin /
  recreation / attributes / backlinks / LDIF / SYSVOL), single-screen GUI, HYCU API skeleton.
