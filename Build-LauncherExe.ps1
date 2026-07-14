<#
================================================================================
 Build-LauncherExe.ps1 - Package the HYCU AD Recovery Tool as ONE native .exe
 that launches the trusted Windows PowerShell (compiled with csc.exe - NOT PS2EXE).
--------------------------------------------------------------------------------
 WHY THIS DESIGN: some endpoint-protection software is stricter with unsigned
 executables, so this build keeps the exe as ordinary and transparent as possible:
   1) It is a plain hand-written .NET assembly (not a script-to-exe wrapper).
   2) It does NOT host the PowerShell engine itself.
   3) It simply launches the Microsoft-signed powershell.exe with benign arguments
      (-NoProfile -File, a normal window, no -ExecutionPolicy flag). The execution
      policy is passed through the inherited PSExecutionPolicyPreference environment
      variable, and the GUI script hides its own console window once running.
 The 4 module files + the GUI script are embedded as managed resources, extracted
 at startup under %LOCALAPPDATA%\HYCU\ADRecoveryTool\app\<build>. HYCU_MODULE_DIR
 points the GUI + its worker runspaces at the extracted psd1; HYCU_PROGRAM_DIR
 keeps logs/staging next to the real exe.

 Prerequisite:  none (csc.exe + Windows PowerShell 5.1 ship with Windows)
 Build:         powershell -NoProfile -ExecutionPolicy Bypass -File .\Build-LauncherExe.ps1
 Output:        .\dist\HYCUADRecovery.exe   (one file, nothing else)
================================================================================
#>
[CmdletBinding()]
param(
    [string]$OutDir,
    # Code signing (optional, recommended so the exe runs without an "unknown publisher" prompt on
    # workstations with strict endpoint protection). Provide ONE of:
    #   -SignThumbprint <thumb>  a code-signing cert already in Cert:\CurrentUser\My or LocalMachine\My
    #   -SignPfx <path>          a .pfx file (prompts for -SignPfxPassword if omitted)
    [string]$SignThumbprint,
    [string]$SignPfx,
    [System.Security.SecureString]$SignPfxPassword,
    [string]$TimestampUrl = 'http://timestamp.digicert.com'
)
$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
if (-not $root) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $root) { $root = (Get-Location).Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'dist' }

$entry   = Join-Path $root 'Start-HYCUADRecoveryGUI.ps1'
$exePath = Join-Path $OutDir 'HYCUADRecovery.exe'
$embed   = @('HYCUADRecovery.psd1', 'HYCUADRecovery.psm1', 'HYCUClient.psm1', 'HYCUSecrets.psm1', 'Start-HYCUADRecoveryGUI.ps1')

# Build stamp (names the extraction folder so different builds do not collide) + file version.
$stamp = '0'
$mm = Select-String -Path $entry -Pattern "HYCUAppVersion\s*=\s*'(\d+)'" | Select-Object -First 1
if ($mm) { $stamp = $mm.Matches[0].Groups[1].Value }
$mod = Import-PowerShellDataFile (Join-Path $root 'HYCUADRecovery.psd1')
$fileVersion = ([version]$mod.ModuleVersion).ToString() + '.0'

# csc.exe from the .NET Framework (present on every supported Windows; no SDK needed).
$csc = @(
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $csc) { throw 'csc.exe not found (.NET Framework 4.x is required to build).' }

$cs = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;

[assembly: AssemblyTitle("HYCU AD Recovery Tool")]
[assembly: AssemblyProduct("HYCU AD Recovery Tool")]
[assembly: AssemblyDescription("Plugin for HYCU Enterprise Cloud (build __STAMP__)")]
[assembly: AssemblyCompany("Independent - not affiliated with HYCU or Microsoft")]
[assembly: AssemblyCopyright("Provided as-is, without warranty or engagement from HYCU.")]
[assembly: AssemblyVersion("__FILEVER__")]
[assembly: AssemblyFileVersion("__FILEVER__")]

namespace HYCU.ADRecovery
{
    internal static class Launcher
    {
        private static readonly string[] Files = new string[]
        {
            "HYCUADRecovery.psd1",
            "HYCUADRecovery.psm1",
            "HYCUClient.psm1",
            "HYCUSecrets.psm1",
            "Start-HYCUADRecoveryGUI.ps1"
        };

        [STAThread]
        private static int Main()
        {
            try
            {
                // 1) Extract the embedded module files + GUI script to a per-build app folder.
                //    (Re)write only when missing or the size differs - tolerant of concurrent runs.
                string appDir = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    @"HYCU\ADRecoveryTool\app\__STAMP__");
                Directory.CreateDirectory(appDir);

                Assembly asm = Assembly.GetExecutingAssembly();
                foreach (string name in Files)
                {
                    string dest = Path.Combine(appDir, name);
                    using (Stream s = asm.GetManifestResourceStream(name))
                    {
                        if (s == null) throw new InvalidOperationException("Embedded resource missing: " + name);
                        byte[] buf = new byte[(int)s.Length];
                        int off = 0;
                        while (off < buf.Length) { int r = s.Read(buf, off, buf.Length - off); if (r <= 0) break; off += r; }
                        if (off != buf.Length) throw new IOException("Short read on embedded resource: " + name);
                        if (!File.Exists(dest) || new FileInfo(dest).Length != buf.Length) File.WriteAllBytes(dest, buf);
                    }
                }

                // 2) Launch the Microsoft-signed Windows PowerShell with BENIGN arguments only.
                //    No -ExecutionPolicy flag (passed via the inherited PSExecutionPolicyPreference
                //    env var), no hidden window (-WindowStyle is deliberately omitted; the GUI script
                //    hides its own console). HYCU_MODULE_DIR resolves the modules; HYCU_PROGRAM_DIR
                //    keeps logs/staging next to this exe.
                string exeDir = AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\');
                string psExe = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.System),
                    @"WindowsPowerShell\v1.0\powershell.exe");
                string script = Path.Combine(appDir, "Start-HYCUADRecoveryGUI.ps1");

                ProcessStartInfo psi = new ProcessStartInfo();
                psi.FileName = psExe;
                psi.Arguments = "-NoProfile -NoLogo -File \"" + script + "\"";
                psi.UseShellExecute = false;
                psi.WorkingDirectory = exeDir;
                psi.EnvironmentVariables["HYCU_MODULE_DIR"] = appDir;
                psi.EnvironmentVariables["HYCU_PROGRAM_DIR"] = exeDir;
                psi.EnvironmentVariables["PSExecutionPolicyPreference"] = "Bypass";

                using (Process p = Process.Start(psi))
                {
                    p.WaitForExit();
                    return p.ExitCode;
                }
            }
            catch (Exception ex)
            {
                try
                {
                    System.Windows.Forms.MessageBox.Show(
                        "HYCU AD Recovery Tool could not start:\r\n\r\n" + ex.Message,
                        "HYCU AD Recovery Tool",
                        System.Windows.Forms.MessageBoxButtons.OK,
                        System.Windows.Forms.MessageBoxIcon.Error);
                }
                catch { }
                return 1;
            }
        }
    }
}
'@
$cs = $cs.Replace('__STAMP__', $stamp).Replace('__FILEVER__', $fileVersion)

if (Test-Path $OutDir) { Remove-Item $OutDir -Recurse -Force }
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$csFile = Join-Path $OutDir '_launcher.cs'
[System.IO.File]::WriteAllText($csFile, $cs, (New-Object System.Text.UTF8Encoding($true)))

$icon = Join-Path $root 'assets\HYCU.ico'
$cscArgs = @('/nologo', '/target:winexe', '/platform:anycpu', '/optimize+',
             '/reference:System.Windows.Forms.dll',
             "/out:$exePath")
if (Test-Path $icon) { $cscArgs += "/win32icon:$icon"; Write-Host "Exe icon : $icon" }
foreach ($f in $embed) { $cscArgs += ('/resource:{0},{1}' -f (Join-Path $root $f), $f) }
$cscArgs += $csFile

Write-Host "Compiling native launcher exe: $exePath  (stamp $stamp, file version $fileVersion)"
try {
    & $csc @cscArgs
    if ($LASTEXITCODE -ne 0) { throw "csc.exe failed (exit $LASTEXITCODE)." }
} finally {
    Remove-Item $csFile -Force -ErrorAction SilentlyContinue
}
if (-not (Test-Path $exePath)) { throw "Build failed: $exePath was not produced." }

# --- Optional Authenticode signing ------------------------------------------------
# An exe signed by a trusted publisher certificate runs without an "unknown publisher" prompt and is
# treated as trusted by endpoint protection. Sign with your organisation's code-signing certificate.
$signCert = $null
if ($SignThumbprint) {
    $signCert = @(Get-ChildItem Cert:\CurrentUser\My, Cert:\LocalMachine\My -CodeSigningCert -ErrorAction SilentlyContinue |
                  Where-Object { $_.Thumbprint -eq ($SignThumbprint -replace '\s','') }) | Select-Object -First 1
    if (-not $signCert) { throw "No code-signing certificate with thumbprint '$SignThumbprint' in CurrentUser\My or LocalMachine\My." }
} elseif ($SignPfx) {
    if (-not (Test-Path $SignPfx)) { throw "PFX not found: $SignPfx" }
    if (-not $SignPfxPassword) { $SignPfxPassword = Read-Host -AsSecureString "Password for $SignPfx" }
    $signCert = Get-PfxCertificate -FilePath $SignPfx -Password $SignPfxPassword
}
if ($signCert) {
    Write-Host "Signing with: $($signCert.Subject) [$($signCert.Thumbprint)]"
    # Try WITH a trusted timestamp first (so the signature stays valid after the cert expires); if the
    # timestamp server is unreachable, fall back to signing WITHOUT a timestamp rather than failing the
    # whole build. A self-signed cert shows 'UnknownError' until it is trusted on the machine - that is
    # expected and not a signing failure, so we accept it too.
    $sig = $null
    try { $sig = Set-AuthenticodeSignature -FilePath $exePath -Certificate $signCert -HashAlgorithm SHA256 -TimestampServer $TimestampUrl -ErrorAction Stop }
    catch { Write-Host "  Timestamp step failed ($($_.Exception.Message)); signing WITHOUT a timestamp." }
    if (-not $sig -or $sig.Status -notin 'Valid','UnknownError') {
        $sig = Set-AuthenticodeSignature -FilePath $exePath -Certificate $signCert -HashAlgorithm SHA256 -ErrorAction Stop
    }
    Write-Host "Signature: $($sig.Status) (Valid = the signing cert is trusted on this machine)."
} else {
    Write-Host "NOT SIGNED - provide -SignThumbprint or -SignPfx to sign with your code-signing certificate"
    Write-Host "            (an unsigned exe shows an 'unknown publisher' prompt on strict workstations)."
}

$size = [math]::Round((Get-Item $exePath).Length / 1KB, 1)
Write-Host ""
Write-Host "NATIVE LAUNCHER BUILD OK: $exePath ($size KB) - this one file is the whole tool."
Get-ChildItem $OutDir | Select-Object Name, @{n='KB';e={[math]::Round($_.Length/1KB,1)}} | Format-Table -AutoSize
