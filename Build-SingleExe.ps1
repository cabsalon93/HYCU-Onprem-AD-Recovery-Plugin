<#
================================================================================
 Build-SingleExe.ps1 - Package the HYCU AD Recovery Tool as ONE self-contained .exe.
--------------------------------------------------------------------------------
 The exe EMBEDS the module files (HYCUClient, HYCUSecrets, HYCUADRecovery + manifest)
 as data. At startup a small bootstrap extracts them to a per-build temp folder and
 points $env:HYCU_MODULE_DIR at it, so the GUI *and* the async worker runspaces both
 Import-Module a real .psd1 on disk - exactly like the multi-file build, but shipped
 as a SINGLE file. (Inlining the module code instead would starve the worker runspace
 of the engine functions and hang "Connecting to the HYCU controller" forever.)

 Only the 4 files that make up the running tool are embedded:
   HYCUClient.psm1, HYCUSecrets.psm1, HYCUADRecovery.psm1, HYCUADRecovery.psd1
 (Examples.ps1, CLAUDE.md, memory.md, .git, .claude, Tests, docs are NOT included.)

 Prerequisite (once):  Install-Module ps2exe -Scope CurrentUser
 Build:                powershell -NoProfile -ExecutionPolicy Bypass -File .\Build-SingleExe.ps1
 Output:               .\dist\HYCUADRecovery.exe   (one file, nothing else)

 To require elevation on launch (recommended for production), add -requireAdmin below.
================================================================================
#>
[CmdletBinding()]
param(
    [string]$OutDir
)
$ErrorActionPreference = 'Stop'
Import-Module ps2exe -ErrorAction Stop

$root = $PSScriptRoot
if (-not $root) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $root) { $root = (Get-Location).Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'dist' }

$entry   = Join-Path $root 'Start-HYCUADRecoveryGUI.ps1'
$exePath = Join-Path $OutDir 'HYCUADRecovery.exe'
$embed   = @('HYCUADRecovery.psd1', 'HYCUADRecovery.psm1', 'HYCUClient.psm1', 'HYCUSecrets.psm1')

# Build stamp (also used to name the extraction folder so different builds don't collide).
$stamp = '0'
$mm = Select-String -Path $entry -Pattern "HYCUAppVersion\s*=\s*'(\d+)'" | Select-Object -First 1
if ($mm) { $stamp = $mm.Matches[0].Groups[1].Value }

# --- Assemble the combined script: self-extract bootstrap + the GUI ---------------
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('#requires -Version 5.1')
[void]$sb.AppendLine('# ===== single-file bootstrap: extract the embedded module files, then run the GUI =====')
[void]$sb.AppendLine('$__mods = [ordered]@{')
foreach ($f in $embed) {
    $bytes = [System.IO.File]::ReadAllBytes((Join-Path $root $f))
    $b64   = [Convert]::ToBase64String($bytes, [Base64FormattingOptions]::InsertLineBreaks)
    [void]$sb.AppendLine("  '$f' = @'")
    [void]$sb.AppendLine($b64)
    [void]$sb.AppendLine("'@")
}
[void]$sb.AppendLine('}')
[void]$sb.AppendLine("`$__dir = Join-Path ([System.IO.Path]::GetTempPath()) 'HYCUADRecovery_$stamp'")
[void]$sb.AppendLine('if (-not (Test-Path $__dir)) { New-Item -ItemType Directory -Path $__dir -Force | Out-Null }')
[void]$sb.AppendLine('$__ok = $true')
[void]$sb.AppendLine('foreach ($__k in $__mods.Keys) {')
[void]$sb.AppendLine('  $__p = Join-Path $__dir $__k')
[void]$sb.AppendLine('  $__bytes = [Convert]::FromBase64String(($__mods[$__k] -replace "\s",""))')
[void]$sb.AppendLine('  # (Re)write only if missing or the size differs - tolerant of a stale/partial/concurrent extraction.')
[void]$sb.AppendLine('  try { if (-not (Test-Path $__p) -or (Get-Item $__p).Length -ne $__bytes.Length) { [System.IO.File]::WriteAllBytes($__p, $__bytes) } } catch {}')
[void]$sb.AppendLine('  if (-not (Test-Path $__p) -or (Get-Item $__p).Length -ne $__bytes.Length) { $__ok = $false }')
[void]$sb.AppendLine('}')
[void]$sb.AppendLine('# Only advertise the module dir if ALL files verified; otherwise fail loudly (a silent env var')
[void]$sb.AppendLine('# on an incomplete extraction would make the worker runspace hang importing a missing/partial module).')
[void]$sb.AppendLine('if ($__ok) { $env:HYCU_MODULE_DIR = $__dir }')
[void]$sb.AppendLine('else { throw "HYCU AD Recovery Tool could not unpack its modules to ''$__dir'' - check TEMP folder space/permissions and retry." }')
[void]$sb.AppendLine('')

# GUI body (strip its #requires; keep everything else - it Import-Modules from $env:HYCU_MODULE_DIR).
[void]$sb.AppendLine('# ===== Start-HYCUADRecoveryGUI.ps1 =====')
foreach ($l in ((Get-Content -LiteralPath $entry) | Where-Object { $_ -notmatch '^\s*#[Rr]equires' })) { [void]$sb.AppendLine($l) }

if (Test-Path $OutDir) { Remove-Item $OutDir -Recurse -Force }
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$combined = Join-Path $OutDir '_combined.ps1'
[System.IO.File]::WriteAllText($combined, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))

$perr = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($combined, [ref]$null, [ref]$perr)
if ($perr) { Write-Host "COMBINED PARSE ERRORS:"; $perr | ForEach-Object { Write-Host "  $($_.Extent.StartLineNumber): $($_.Message)" }; throw 'Combined script does not parse.' }
Write-Host "Combined script parses OK ($([math]::Round((Get-Item $combined).Length/1KB)) KB)."

$mod = Import-PowerShellDataFile (Join-Path $root 'HYCUADRecovery.psd1')
$fileVersion = ([version]$mod.ModuleVersion).ToString() + '.0'
$icon = Join-Path $root 'assets\HYCU.ico'
$iconArgs = @{}
if (Test-Path $icon) { $iconArgs['iconFile'] = $icon; Write-Host "Exe icon : $icon" }
else { Write-Host "No exe icon (assets\HYCU.ico missing - run Make-Icon.ps1 to generate it)." }

Write-Host "Compiling single-file exe: $exePath  (stamp $stamp, file version $fileVersion)"
try {
    Invoke-ps2exe -inputFile $combined -outputFile $exePath `
        -STA -noConsole @iconArgs `
        -title       'HYCU AD Recovery Tool' `
        -product     'HYCU AD Recovery Tool' `
        -description "Plugin for HYCU Enterprise Cloud (build $stamp)" `
        -company     'Independent - not affiliated with HYCU or Microsoft' `
        -copyright   'Provided as-is, without warranty or engagement from HYCU.' `
        -version     $fileVersion
} finally {
    # Always delete the combined script (it embeds the whole source as base64) - even if PS2EXE throws.
    Remove-Item $combined -Force -ErrorAction SilentlyContinue
}
if (-not (Test-Path $exePath)) { throw "Build failed: $exePath was not produced (see the PS2EXE output above)." }
$size = [math]::Round((Get-Item $exePath).Length / 1MB, 2)
Write-Host ""
Write-Host "SINGLE-FILE BUILD OK: $exePath ($size MB) - this one file is the whole tool."
Get-ChildItem $OutDir | Select-Object Name, @{n='KB';e={[math]::Round($_.Length/1KB,1)}} | Format-Table -AutoSize
