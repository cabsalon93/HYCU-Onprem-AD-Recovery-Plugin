@echo off
rem ============================================================================
rem  Run-HYCUADRecovery.cmd - Start the HYCU AD Recovery Tool without the .exe.
rem
rem  Launches the GUI through the trusted, Microsoft-signed Windows PowerShell,
rem  so endpoint protection that blocks unsigned executables is not involved.
rem  The GUI hides its own console; only the HYCU window is shown.
rem
rem  REQUIREMENT: keep this file in the SAME folder as the module files
rem  (HYCUADRecovery.psd1/.psm1, HYCUClient.psm1, HYCUSecrets.psm1) and
rem  Start-HYCUADRecoveryGUI.ps1. Then just double-click this file.
rem ============================================================================
setlocal
set "HYCU_PROGRAM_DIR=%~dp0"
set "HYCU_MODULE_DIR=%~dp0"
set "PSExecutionPolicyPreference=Bypass"
start "" powershell.exe -NoProfile -NoLogo -File "%~dp0Start-HYCUADRecoveryGUI.ps1"
endlocal
