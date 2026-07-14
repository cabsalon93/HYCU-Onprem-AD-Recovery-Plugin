<#
================================================================================
 HYCU AD Recovery Tool - Graphical interface (WPF) v2
 --------------------------------------------------------------------------------
 Guided wizard workflow (single path):
   1) Connect to HYCU   2) VM + restore point   3) Restore destination
   4) Retrieve NTDS     5) Mount + compare      6) Selection   7) Restore

 Responsiveness: long operations (HYCU connect, file-level restore, dsamain mount,
 comparison, bulk restore) run in a dedicated runspace; a DispatcherTimer drains the
 progress queue -> the UI never freezes.

 Branding: HYCU purple theme with the official HYCU logomark, embedded as a vector
 (converted from HYCU_Logomark_White_RGB.svg) so no external image file is required.

 Run in an ELEVATED PowerShell console:
     powershell -ExecutionPolicy Bypass -STA -File .\Start-HYCUADRecoveryGUI.ps1
================================================================================
#>
#requires -Version 5.1

# WPF requires a single-threaded apartment (STA). If this was launched in MTA - e.g. with PowerShell 7
# (pwsh defaults to MTA) or 'powershell' without -STA - ShowDialog() fails and the window never appears
# ("nothing happens"). Relaunch ourselves in STA with the same host, then exit this MTA instance.
if (-not $env:HYCU_GUI_NOSHOW -and
    [System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
    $hostExe = try { (Get-Process -Id $PID).Path } catch { $null }
    if (-not $hostExe) { $hostExe = 'powershell.exe' }
    $self = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
    Start-Process -FilePath $hostExe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-STA','-File',$self)
    return
}

# When started by the native launcher exe (HYCU_PROGRAM_DIR set), the trusted powershell.exe is spawned
# with a normal console window (deliberately NOT with -WindowStyle Hidden, which endpoint-protection
# engines flag). Hide that console ourselves now, from inside the script, so only the WPF window shows.
if ($env:HYCU_PROGRAM_DIR -and -not $env:HYCU_GUI_NOSHOW) {
    try {
        Add-Type -Namespace HYCU -Name Con -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
'@ -ErrorAction Stop
        $h = [HYCU.Con]::GetConsoleWindow()
        if ($h -ne [System.IntPtr]::Zero) { [void][HYCU.Con]::ShowWindow($h, 0) }   # 0 = SW_HIDE
    } catch {}
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# NB: when compiled to an .exe (PS2EXE) $MyInvocation.MyCommand.Path is $null, and Split-Path -Parent $null
# throws a TERMINATING error - so guard it (an unguarded throw here killed the exe before it could start).
# The single-file build self-extracts the module files to a temp dir and sets $env:HYCU_MODULE_DIR; use it
# first so BOTH this session AND the async worker runspaces Import-Module from a real .psd1 on disk.
$here = if ($env:HYCU_MODULE_DIR -and (Test-Path (Join-Path $env:HYCU_MODULE_DIR 'HYCUADRecovery.psd1'))) { $env:HYCU_MODULE_DIR }
        elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path } else { $null }
# Resolve the module files relative to the running executable's own folder (they ship next to the exe).
# Only trust the exe folder if the manifest is actually there, so a normal .ps1 run is unaffected.
if (-not $here -or -not (Test-Path (Join-Path $here 'HYCUADRecovery.psd1'))) {
    try {
        $exeDir = [System.IO.Path]::GetDirectoryName([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
        if ($exeDir -and (Test-Path (Join-Path $exeDir 'HYCUADRecovery.psd1'))) { $here = $exeDir }
    } catch {}
    if (-not $here) { $here = (Get-Location).Path }
}
$script:ModulePath = Join-Path $here 'HYCUADRecovery.psd1'
Import-Module $script:ModulePath -Force

# ----------------------------------------------------------------------------
# Product identity - SINGLE source of truth (used by the About box and the log header).
# Version is a build timestamp (YYYYMMDDHHMM); bump it on every new build. The .psd1 manifest
# keeps its own SemVer (PowerShell requires a System.Version there, not a 12-digit stamp).
# ----------------------------------------------------------------------------
$script:HYCUAppVersion    = '202607141315'
$script:HYCUProductName   = 'HYCU AD Recovery Tool'
$script:HYCUProductKind   = 'Plugin for HYCU Enterprise Cloud'
$script:HYCUProductNotice = 'This is a free plugin, provided as-is without any warranty or engagement from HYCU.'

# Folder the program runs from: the launcher exe's folder (HYCU_PROGRAM_DIR, set by the native
# launcher before it spawns powershell.exe), the script's folder as a .ps1, or the .exe's folder
# when the host process is the exe itself.
function Get-HYCUProgramDir {
    if ($env:HYCU_PROGRAM_DIR -and (Test-Path $env:HYCU_PROGRAM_DIR)) { return $env:HYCU_PROGRAM_DIR }
    try {
        $main = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        if ($main -and ([System.IO.Path]::GetFileName($main)) -notmatch '(?i)^(powershell(_ise)?|pwsh)\.exe$') {
            return [System.IO.Path]::GetDirectoryName($main)
        }
    } catch {}
    if ($here) { return $here }
    if ($PSScriptRoot) { return $PSScriptRoot }
    return (Get-Location).Path
}

# Open a fresh per-run log file next to the program (Logs\ subfolder). Each run gets its own
# timestamped file (they sort chronologically); older runs are pruned to the newest 30. If the
# program folder is not writable (e.g. Program Files without rights), fall back to %LOCALAPPDATA%.
function Initialize-HYCULogFile {
    $stamp = '{0:yyyyMMdd_HHmmss}' -f (Get-Date)
    $candidates = @(
        (Join-Path (Get-HYCUProgramDir) 'Logs'),
        (Join-Path ([string]$env:LOCALAPPDATA) 'HYCU\ADRecoveryTool\Logs')
    ) | Where-Object { $_ }
    foreach ($dir in $candidates) {
        try {
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
            $path   = Join-Path $dir "HYCUADRecovery_$stamp.log"
            $header = @(
                '================================================================================',
                " $script:HYCUProductName",
                " $script:HYCUProductKind",
                " Version : $script:HYCUAppVersion",
                (" Run     : {0:yyyy-MM-dd HH:mm:ss}  |  {1}\{2}  |  host {3}" -f (Get-Date), $env:USERDOMAIN, $env:USERNAME, $env:COMPUTERNAME),
                '================================================================================',
                ''
            ) -join "`r`n"
            [System.IO.File]::AppendAllText($path, $header, [System.Text.Encoding]::UTF8)   # also probes writability
            $script:HYCULogFile = $path
            try {
                Get-ChildItem -LiteralPath $dir -Filter 'HYCUADRecovery_*.log' -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending | Select-Object -Skip 30 |
                    ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
            } catch {}
            return
        } catch { continue }
    }
    $script:HYCULogFile = $null   # file logging unavailable; the UI still runs
}
Initialize-HYCULogFile

# Shared state between the UI thread and the worker runspaces.
$sync = [hashtable]::Synchronized(@{})
$sync.Queue         = New-Object System.Collections.Concurrent.ConcurrentQueue[string]
$sync.Busy          = $false
$sync.Done          = $true
$sync.Session       = $null     # AD snapshot session (dsamain)
$sync.HycuSession   = $null     # HYCU REST session
$sync.Diffs         = @()
$sync.Cart          = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))   # thread-safe: mutated from dialog closures
$sync.SelectedVM    = $null
$sync.SelectedRP    = $null
$sync.NtdsPath      = $null
$sync.LoadedProfile = ''        # name of the profile loaded in the form
$sync.LoadedCred    = $null     # PSCredential from a loaded profile (DPAPI-decrypted, in memory)
$sync.LoadedToken   = $null     # SecureString API token from a loaded profile
$sync.LoadedTgtPass = $null     # SecureString restore-target password from a loaded profile

# ----------------------------------------------------------------------------
# XAML  (HYCU purple theme)
# ----------------------------------------------------------------------------
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="HYCU AD Recovery Tool" Width="1100" Height="720"
        MinWidth="800" MinHeight="560" ResizeMode="CanResize"
        WindowStartupLocation="CenterScreen" Background="#FFF3F2FF">
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Background" Value="#FF721EF2"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Padding" Value="10,6"/>
      <Setter Property="Margin" Value="4"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style TargetType="Label"><Setter Property="Foreground" Value="#FF1B0C33"/></Style>
    <Style TargetType="TextBlock"><Setter Property="Foreground" Value="#FF1B0C33"/></Style>
    <!-- Explicit CheckBox / RadioButton templates: the default WPF indicators use system theme
         brushes that are invisible on this dark theme (and especially on Windows Server 2012). These
         draw the box/circle and the checked state ourselves so the state is always clearly visible. -->
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="#FF1B0C33"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal" Background="Transparent">
              <Border x:Name="Box" Width="16" Height="16" CornerRadius="3" BorderThickness="1.5"
                      BorderBrush="#FF5B18C0" Background="#FFFFFFFF" VerticalAlignment="Center">
                <TextBlock x:Name="Check" Text="&#x2714;" FontSize="11" FontWeight="Bold" Foreground="White"
                           HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed"/>
              </Border>
              <ContentPresenter Margin="6,0,0,0" VerticalAlignment="Center" TextBlock.Foreground="{TemplateBinding Foreground}"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Check" Property="Visibility" Value="Visible"/>
                <Setter TargetName="Box" Property="Background" Value="#FF721EF2"/>
                <Setter TargetName="Box" Property="BorderBrush" Value="#FF721EF2"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Box" Property="BorderBrush" Value="#FF7D5EFF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="RadioButton">
      <Setter Property="Foreground" Value="#FF1B0C33"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <StackPanel Orientation="Horizontal" Background="Transparent">
              <Grid Width="16" Height="16" VerticalAlignment="Center">
                <Ellipse x:Name="Outer" Stroke="#FF5B18C0" StrokeThickness="1.5" Fill="#FFFFFFFF"/>
                <Ellipse x:Name="Dot" Width="8" Height="8" Fill="#FF7D5EFF" Visibility="Collapsed"/>
              </Grid>
              <ContentPresenter Margin="6,0,0,0" VerticalAlignment="Center" TextBlock.Foreground="{TemplateBinding Foreground}"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Dot" Property="Visibility" Value="Visible"/>
                <Setter TargetName="Outer" Property="Stroke" Value="#FF7D5EFF"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Outer" Property="Stroke" Value="#FF7D5EFF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="TextBox"><Setter Property="Padding" Value="4"/><Setter Property="Margin" Value="2"/></Style>
    <!-- ComboBox dropdown items: the default popup is light, but the dark theme's implicit TextBlock
         foreground makes the item text light - i.e. light-on-light and unreadable (Server 2012 / Aero).
         Give each item a dark HYCU background (purple highlight/selection) so the light text is always
         legible. The ComboBoxes stay editable (type a profile name), so we template only the items. -->
    <Style TargetType="ComboBoxItem">
      <Setter Property="Foreground" Value="#FF1B0C33"/>
      <Setter Property="Background" Value="#FFFFFFFF"/>
      <Setter Property="Padding" Value="8,4"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBoxItem">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}" SnapsToDevicePixels="True">
              <ContentPresenter TextBlock.Foreground="{TemplateBinding Foreground}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsHighlighted" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#FFE2E0FD"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#FFD0CEFB"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="DG" TargetType="DataGrid">
      <Setter Property="AutoGenerateColumns" Value="False"/>
      <Setter Property="IsReadOnly" Value="True"/>
      <Setter Property="Background" Value="#FFFFFFFF"/>
      <Setter Property="Foreground" Value="#FF1B0C33"/>
      <Setter Property="GridLinesVisibility" Value="Horizontal"/>
      <Setter Property="RowBackground" Value="#FFFFFFFF"/>
      <Setter Property="AlternatingRowBackground" Value="#FFF3F2FF"/>
      <Setter Property="HeadersVisibility" Value="Column"/>
    </Style>
    <!-- Column headers. The default WPF DataGridColumnHeader is a light Aero gradient; combined with
         the grid's white Foreground the header titles were white-on-light and unreadable. Give them a
         dark HYCU-purple background with light, semibold text for strong contrast on every grid. -->
    <Style TargetType="DataGridColumnHeader">
      <Setter Property="Background" Value="#FF43128E"/>
      <Setter Property="Foreground" Value="#FFF3F2FF"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="8,5"/>
      <Setter Property="BorderBrush" Value="#FFD0CEFB"/>
      <Setter Property="BorderThickness" Value="0,0,1,1"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
    <!-- Tree (mounted-database browser): light text on the dark panel. -->
    <Style TargetType="TreeView">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Foreground" Value="#FF1B0C33"/>
    </Style>
    <!-- Custom TreeViewItem template: the default (system) selection highlight is light and leaves the
         selected node unreadable on the dark panel. This gives selection a HYCU-purple background with
         light text, and a simple rotating arrow expander. -->
    <Style TargetType="TreeViewItem">
      <Setter Property="Foreground" Value="#FF1B0C33"/>
      <Setter Property="Padding" Value="3,2"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TreeViewItem">
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="16"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
              </Grid.RowDefinitions>
              <ToggleButton x:Name="Expander" Grid.Row="0" Grid.Column="0" ClickMode="Press" Focusable="False"
                            IsChecked="{Binding IsExpanded, RelativeSource={RelativeSource TemplatedParent}}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Border Background="Transparent" Width="16" Height="16">
                      <Path x:Name="Arrow" Data="M 5 3 L 9 7 L 5 11 Z" Fill="#FF5B18C0"
                            HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </Border>
                    <ControlTemplate.Triggers>
                      <Trigger Property="IsChecked" Value="True">
                        <Setter TargetName="Arrow" Property="Data" Value="M 3 5 L 11 5 L 7 10 Z"/>
                        <Setter TargetName="Arrow" Property="Fill" Value="#FF43128E"/>
                      </Trigger>
                    </ControlTemplate.Triggers>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <Border x:Name="Bd" Grid.Row="0" Grid.Column="1" Background="{TemplateBinding Background}"
                      Padding="{TemplateBinding Padding}" CornerRadius="3" SnapsToDevicePixels="True">
                <ContentPresenter x:Name="PART_Header" ContentSource="Header" HorizontalAlignment="Left"/>
              </Border>
              <ItemsPresenter x:Name="ItemsHost" Grid.Row="1" Grid.Column="1"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsExpanded" Value="False"><Setter TargetName="ItemsHost" Property="Visibility" Value="Collapsed"/></Trigger>
              <Trigger Property="HasItems" Value="False"><Setter TargetName="Expander" Property="Visibility" Value="Hidden"/></Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#FFB8B4FC"/>
                <Setter Property="Foreground" Value="#FF1B0C33"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid Margin="10">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- Header with logo area -->
    <Border Grid.Row="0" Background="#FF43128E" CornerRadius="6" Padding="10" Margin="0,0,0,8">
      <DockPanel LastChildFill="True">
        <Button x:Name="BtnAbout" DockPanel.Dock="Right" Content="About" Width="84" Height="30"
                VerticalAlignment="Center" Background="#FF5B18C0" Foreground="White" BorderThickness="0"/>
        <Button x:Name="BtnViewLog" DockPanel.Dock="Right" Content="View log" Width="84" Height="30" Margin="0,0,8,0"
                VerticalAlignment="Center" Background="#FF5B18C0" Foreground="White" BorderThickness="0"
                ToolTip="Open the current run's log file"/>
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <!-- Official HYCU logomark (vectorized from HYCU_Logomark_White_RGB.svg) -->
          <Viewbox Height="38" Margin="0,0,12,0" VerticalAlignment="Center">
            <Canvas Width="1253.98" Height="1080">
              <Path Fill="White" Data="F1 M624.09,888.71h133.67c160.41,0,290.59-130.18,290.59-290.59c0-89.5-40.68-169.7-103.45-223.17L738,816.64 L628.74,707.38l51.14-109.26H519.47l-33.71,74.39c-11.62,25.57-17.44,52.31-17.44,75.55C468.33,827.1,527.61,888.71,624.09,888.71 M309.09,705.06l206.9-441.7l109.26,109.26L574.1,481.88h160.41l33.71-74.39c11.62-25.57,17.44-52.31,17.44-75.55c0-79.04-59.28-140.65-155.76-140.65H496.23c-160.41,0-290.59,130.18-290.59,290.59C205.64,571.38,246.32,651.59,309.09,705.06 M1013.15,830.59c-16.05,0-29.06,13.01-29.06,29.06c0,16.05,13.01,29.06,29.06,29.06c16.05,0,29.06-13.01,29.06-29.06C1042.21,843.6,1029.2,830.59,1013.15,830.59z M1013.15,882.9c-12.84,0-23.25-10.41-23.25-23.25c0-12.84,10.41-23.25,23.25-23.25c12.84,0,23.25,10.41,23.25,23.25C1036.39,872.49,1025.99,882.9,1013.15,882.9z M1020.27,861.73c3.38-1.29,5.74-4,5.74-8.14c0-6.14-5.21-9.48-11.43-9.48h-12.33v30.25h7.12v-11.34h4.32l6.23,11.34h7.87L1020.27,861.73z M1013.86,857.99h-4.5v-8.76h4.5c3.02,0,5.07,1.78,5.07,4.45C1018.93,856.39,1016.89,857.99,1013.86,857.99z"/>
            </Canvas>
          </Viewbox>
          <TextBlock Text="HYCU AD Recovery Tool" FontSize="18" FontWeight="Bold" Foreground="White" VerticalAlignment="Center"/>
          <TextBlock Text="  -  granular Active Directory object recovery" Foreground="#FFD0CEFB" VerticalAlignment="Center"/>
        </StackPanel>
      </DockPanel>
    </Border>

    <!-- Wizard: single guided workflow -->
    <Grid Grid.Row="1" Margin="6">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="220"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>

          <!-- Stepper -->
          <Border Grid.Column="0" Background="#FFFFFFFF" CornerRadius="6" Padding="10" Margin="0,0,8,0">
            <StackPanel>
              <TextBlock Text="STEPS" FontWeight="Bold" Foreground="#FF5B18C0" Margin="0,0,0,10"/>
              <TextBlock x:Name="N1" Text="1. Connect to HYCU" Margin="0,6" FontSize="13"/>
              <TextBlock x:Name="N2" Text="2. AD controller + restore point" Margin="0,6" FontSize="13"/>
              <TextBlock x:Name="N3" Text="3. Restore destination" Margin="0,6" FontSize="13"/>
              <TextBlock x:Name="N4" Text="4. Retrieve NTDS" Margin="0,6" FontSize="13"/>
              <TextBlock x:Name="N5" Text="5. Mount + compare" Margin="0,6" FontSize="13"/>
              <TextBlock x:Name="N6" Text="6. Selection" Margin="0,6" FontSize="13"/>
              <TextBlock x:Name="N7" Text="7. Restore" Margin="0,6" FontSize="13"/>
            </StackPanel>
          </Border>

          <!-- Step content -->
          <Grid Grid.Column="1">
            <Grid.RowDefinitions>
              <RowDefinition Height="*"/>
              <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <Border Grid.Row="0" Background="#FFFFFFFF" CornerRadius="6" Padding="14">
              <Grid>
                <!-- STEP 1 -->
                <StackPanel x:Name="WizStep1">
                  <TextBlock Text="Step 1 - Connect to the HYCU controller" FontSize="15" FontWeight="Bold" Margin="0,0,0,10"/>
                  <RadioButton x:Name="RadioConnectHycu" Content="Connect to HYCU (recommended)" IsChecked="True" Margin="0,2"/>
                  <RadioButton x:Name="RadioUseFolder" Content="I already have a restored NTDS folder (skip HYCU)" Margin="0,2"/>
                  <Grid x:Name="HycuPanel" Margin="0,8,0,0">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="160"/></Grid.ColumnDefinitions>
                    <Grid.RowDefinitions>
                      <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                      <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>
                    <Label Grid.Row="0" Grid.Column="0" Content="Controller:"/>
                    <TextBox x:Name="W1_Server" Grid.Row="0" Grid.Column="1"/>
                    <Label Grid.Row="0" Grid.Column="2" Content="Port:" Margin="8,0,0,0"/>
                    <TextBox x:Name="W1_Port" Grid.Row="0" Grid.Column="3" Text="8443"/>
                    <Label Grid.Row="1" Grid.Column="0" Content="API version:"/>
                    <TextBox x:Name="W1_ApiVersion" Grid.Row="1" Grid.Column="1" Text="v1.0" HorizontalAlignment="Left" Width="120"/>
                    <StackPanel Grid.Row="2" Grid.Column="0" Grid.ColumnSpan="4" Orientation="Horizontal" Margin="0,6,0,0">
                      <Label Content="Auth:"/>
                      <RadioButton x:Name="W1_AuthBasic" Content="Basic" IsChecked="True" Margin="4,0" VerticalAlignment="Center"/>
                      <RadioButton x:Name="W1_AuthToken" Content="API token" Margin="8,0" VerticalAlignment="Center"/>
                    </StackPanel>
                    <!-- Basic auth fields (shown only when 'Basic' is selected) -->
                    <Grid x:Name="W1_BasicFields" Grid.Row="3" Grid.Column="0" Grid.ColumnSpan="4">
                      <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="160"/></Grid.ColumnDefinitions>
                      <Label Grid.Column="0" Content="Username:"/>
                      <TextBox x:Name="W1_User" Grid.Column="1"/>
                      <Label Grid.Column="2" Content="Password:" Margin="8,0,0,0"/>
                      <PasswordBox x:Name="W1_Pass" Grid.Column="3" Margin="2"/>
                    </Grid>
                    <!-- API token field (shown only when 'API token' is selected) -->
                    <Grid x:Name="W1_TokenFields" Grid.Row="4" Grid.Column="0" Grid.ColumnSpan="4" Visibility="Collapsed">
                      <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                      <Label Grid.Column="0" Content="API token:"/>
                      <PasswordBox x:Name="W1_Token" Grid.Column="1" Margin="2"/>
                    </Grid>
                  </Grid>
                  <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
                    <Label Content="Profile:"/>
                    <ComboBox x:Name="W1_Profiles" Width="160" Margin="2" IsEditable="True"/>
                    <Button x:Name="W1_BtnLoadProfile" Content="Load"/>
                    <Button x:Name="W1_BtnSaveProfile" Content="Save profile"/>
                  </StackPanel>
                  <TextBlock Foreground="#FF5B18C0" TextWrapping="Wrap" Margin="0,8,0,0"
                     Text="Click Next to connect: the HYCU connection is validated automatically, and you only advance if it succeeds."/>
                  <Border x:Name="FolderPanel" Margin="0,12,0,0" Visibility="Collapsed">
                    <StackPanel>
                      <Label Content="Already-restored NTDS folder (containing ntds.dit + edb*.log):"/>
                      <TextBox x:Name="W1_NtdsManual" Text="R:\HYCU_Restore\DC01\Windows\NTDS"/>
                    </StackPanel>
                  </Border>
                </StackPanel>

                <!-- STEP 2 -->
                <Grid x:Name="WizStep2" Visibility="Collapsed">
                  <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                  <TextBlock Grid.Row="0" Text="Step 2 - AD domain controller and restore point" FontSize="15" FontWeight="Bold" Margin="0,0,0,8"/>
                  <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,0,0,6">
                    <Label Content="Filter:"/>
                    <TextBox x:Name="W2_Filter" Width="200"/>
                    <Button x:Name="W2_BtnListVMs" Content="List AD domain controllers" Width="210"/>
                  </StackPanel>
                  <DataGrid x:Name="W2_GridVMs" Grid.Row="2" Style="{StaticResource DG}">
                    <DataGrid.Columns>
                      <DataGridTextColumn Header="Domain controller" Binding="{Binding Name}" Width="*"/>
                      <DataGridTextColumn Header="Application" Binding="{Binding Application}" Width="140"/>
                      <DataGridTextColumn Header="Version" Binding="{Binding Version}" Width="230"/>
                      <DataGridTextColumn Header="Status" Binding="{Binding Status}" Width="100"/>
                    </DataGrid.Columns>
                  </DataGrid>
                  <TextBlock Grid.Row="3" Text="Restore points (select one):" Margin="0,8,0,4" Foreground="#FF5B18C0"/>
                  <DataGrid x:Name="W2_GridRPs" Grid.Row="4" Style="{StaticResource DG}">
                    <DataGrid.Columns>
                      <DataGridTextColumn Header="Date" Binding="{Binding Timestamp}" Width="200"/>
                      <DataGridTextColumn Header="Consistency" Binding="{Binding Consistency}" Width="120"/>
                      <DataGridTextColumn Header="Target" Binding="{Binding Tier}" Width="120"/>
                      <DataGridTextColumn Header="Uuid" Binding="{Binding Uuid}" Width="*"/>
                    </DataGrid.Columns>
                  </DataGrid>
                  <Border Grid.Row="5" Background="#FFE2E0FD" CornerRadius="4" Padding="8" Margin="0,8,0,0">
                    <TextBlock x:Name="W2_Selection" Foreground="#FF5B18C0" TextWrapping="Wrap"
                       Text="Select a domain controller, then a restore point. Prefer an 'Application'-consistent point (cleaner ntds.dit)."/>
                  </Border>
                </Grid>

                <!-- STEP 3 - Restore destination -->
                <StackPanel x:Name="WizDest" Visibility="Collapsed">
                  <TextBlock Text="Step 3 - Restore destination (where HYCU writes the files)" FontSize="15" FontWeight="Bold" Margin="0,0,0,8"/>
                  <Border Background="#FFE2E0FD" CornerRadius="4" Padding="10" Margin="0,0,0,10">
                    <TextBlock TextWrapping="Wrap" Foreground="#FF697077"
                       Text="The next step restores C:\Windows\NTDS to an SMB share via HYCU, then reads ntds.dit back from it. Give the server (name/IP) and share name of a share that BOTH this machine and the HYCU controller can reach over SMB. The tool restores to \\server\share. Enter it manually, or load a saved profile."/>
                  </Border>
                  <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
                    <Label Content="Profile:"/>
                    <ComboBox x:Name="WD_Profiles" Width="160" Margin="2" IsEditable="True"/>
                    <Button x:Name="WD_BtnLoad" Content="Load"/>
                    <Button x:Name="WD_BtnSave" Content="Save profile"/>
                  </StackPanel>
                  <Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="220"/></Grid.ColumnDefinitions>
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                    <Label Grid.Row="0" Grid.Column="0" Content="Server (name/IP):"/>
                    <TextBox x:Name="WD_Server" Grid.Row="0" Grid.Column="1"/>
                    <Label Grid.Row="0" Grid.Column="2" Content="Share name:" Margin="8,0,0,0"/>
                    <TextBox x:Name="WD_Share" Grid.Row="0" Grid.Column="3"/>
                    <Label Grid.Row="1" Grid.Column="0" Content="Username:"/>
                    <TextBox x:Name="WD_User" Grid.Row="1" Grid.Column="1"/>
                    <Label Grid.Row="1" Grid.Column="2" Content="Domain:" Margin="8,0,0,0"/>
                    <TextBox x:Name="WD_Domain" Grid.Row="1" Grid.Column="3"/>
                    <Label Grid.Row="2" Grid.Column="0" Content="Password:"/>
                    <PasswordBox x:Name="WD_Pass" Grid.Row="2" Grid.Column="1" Margin="2"/>
                  </Grid>
                  <TextBlock Margin="0,8,0,0" Foreground="#FF697077" TextWrapping="Wrap"
                     Text="These can be saved with the connection profile (step 1, 'Save profile') and loaded together next time."/>
                </StackPanel>

                <!-- STEP 4 - Retrieve NTDS -->
                <StackPanel x:Name="WizStep3" Visibility="Collapsed">
                  <TextBlock Text="Step 4 - Retrieve the NTDS database from HYCU" FontSize="15" FontWeight="Bold" Margin="0,0,0,8"/>
                  <Border Background="#FFE2E0FD" CornerRadius="4" Padding="10" Margin="0,0,0,10">
                    <StackPanel>
                      <TextBlock x:Name="W3_Selected" Foreground="#FF5B18C0" FontWeight="SemiBold" TextWrapping="Wrap"/>
                      <TextBlock Margin="0,4,0,0" TextWrapping="Wrap" Foreground="#FF697077"
                         Text="Fully automatic - no HYCU console needed. The tool mounts this backup in HYCU, restores C:\Windows\NTDS to the destination share from step 3, reads ntds.dit back locally, then unmounts."/>
                    </StackPanel>
                  </Border>
                  <TextBlock Foreground="#FF697077" TextWrapping="Wrap" Margin="0,4,0,0"
                     Text="SYSVOL is copied automatically too, so Group Policy content (Registry.pol, scripts, ADMX...) can be restored with its GPO."/>
                  <TextBlock Foreground="#FF5B18C0" TextWrapping="Wrap" Margin="0,10,0,0"
                     Text="Click Next to retrieve the database from HYCU (mount -> copy -> unmount, automatic). It runs once; going Back then Next again will not repeat it."/>
                  <Label Content="Retrieved NTDS folder:" Margin="0,6,0,0"/>
                  <TextBox x:Name="W3_NtdsResult" IsReadOnly="True"/>
                </StackPanel>

                <!-- STEP 5 - Mount + compare -->
                <StackPanel x:Name="WizStep4" Visibility="Collapsed">
                  <TextBlock Text="Step 5 - Mount and compare" FontSize="15" FontWeight="Bold" Margin="0,0,0,8"/>
                  <Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                    <Label Grid.Row="0" Grid.Column="0" Content="NTDS folder:"/>
                    <TextBox x:Name="W4_Ntds" Grid.Row="0" Grid.Column="1"/>
                    <Label Grid.Row="1" Grid.Column="0" Content="SYSVOL (optional):"/>
                    <TextBox x:Name="W4_Sysvol" Grid.Row="1" Grid.Column="1"/>
                    <Label Grid.Row="2" Grid.Column="0" Content="LDAP port:"/>
                    <TextBox x:Name="W4_Port" Grid.Row="2" Grid.Column="1" Text="41389" HorizontalAlignment="Left" Width="120"/>
                    <Label Grid.Row="3" Grid.Column="0" Content="Production DC (optional):"/>
                    <TextBox x:Name="W4_LiveDC" Grid.Row="3" Grid.Column="1"
                             ToolTip="Leave empty to auto-detect this machine's domain controller. Set it only to compare against a specific production DC."/>
                  </Grid>
                  <TextBlock Foreground="#FF697077" TextWrapping="Wrap" Margin="0,6,0,0"
                     Text="Production DC is optional: leave it empty to auto-detect this machine's domain controller for the comparison."/>
                  <TextBlock Foreground="#FF697077" TextWrapping="Wrap" Margin="0,8,0,0"
                     Text="A dirty database is recovered automatically (log replay, then a last-resort esentutl /p on the offline copy if needed)."/>
                  <TextBlock Foreground="#FF5B18C0" TextWrapping="Wrap" Margin="0,8,0,0"
                     Text="Click Next to mount the snapshot and compare it with production."/>
                  <TextBlock x:Name="W4_Summary" Margin="0,4,0,0" Foreground="#FF5B18C0" TextWrapping="Wrap"/>
                </StackPanel>

                <!-- STEP 6 - Selection -->
                <Grid x:Name="WizStep5" Visibility="Collapsed">
                  <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                  <TextBlock Grid.Row="0" Text="Step 6 - Selection: browse the mounted database and compare" FontSize="15" FontWeight="Bold" Margin="0,0,0,8"/>
                  <!-- WrapPanel so the toolbar buttons flow onto a second line on a narrow window instead of
                       being clipped (e.g. "View cart" was cut off at the right edge). -->
                  <WrapPanel Grid.Row="1" Orientation="Horizontal" Margin="0,0,0,6">
                    <TextBox x:Name="W5_Search" Width="150" VerticalAlignment="Center" Margin="0,0,6,4"
                             ToolTip="Find an object by name / displayName / sAMAccountName (Enter to search)"/>
                    <Button x:Name="W5_BtnFind" Content="Find" Width="60" Margin="0,0,6,4"/>
                    <Button x:Name="W5_BtnReload" Content="Reload tree" Width="100" Margin="0,0,6,4"/>
                    <Button x:Name="W5_BtnCompare" Content="Compare with production" Background="#FF7D5EFF" Width="190" Margin="0,0,6,4"/>
                    <Button x:Name="W5_BtnScan" Content="Scan all changes" Width="140" Margin="0,0,6,4"/>
                    <Button x:Name="W5_BtnRecycle" Content="Recycle Bin" Width="110" Margin="0,0,6,4"
                            ToolTip="List objects still in the AD Recycle Bin (reanimable with SID preserved) - read-only"/>
                    <Button x:Name="W5_BtnListGpo" Content="List GPOs" Width="100" Margin="0,0,6,4"
                            ToolTip="List every Group Policy object in the snapshot by its friendly name - select one to compare with production or add to the restore cart"/>
                    <Button x:Name="W5_BtnAddCart" Content="Add to cart" Background="#FF721EF2" Width="110" Margin="0,0,6,4"/>
                    <Button x:Name="W5_BtnAddAttrs" Content="Add selected attrs" Background="#FF721EF2" Width="140" Margin="0,0,6,4"
                            ToolTip="Cherry-pick: after 'Compare with production', select rows in the attribute grid and add ONLY those attributes to the cart"/>
                    <Button x:Name="W5_BtnAddSubtree" Content="Add subtree" Background="#FF721EF2" Width="110" Margin="0,0,6,4"
                            ToolTip="Scan the selected container/OU and add every Deleted/Modified object under it to the cart (parents first)"/>
                    <Button x:Name="W5_BtnExport" Content="Export LDIF" Background="#FF5B18C0" Width="120" Margin="0,0,6,4"/>
                    <Button x:Name="W5_BtnViewCart" Content="View cart" Background="#FF5B18C0" Width="100" Margin="0,0,6,4"/>
                    <Label x:Name="W5_LblCart" Content="Cart: 0" Foreground="#FF5B18C0" VerticalAlignment="Center" Margin="8,0,0,4"/>
                  </WrapPanel>
                  <Grid Grid.Row="2">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="2*"/><ColumnDefinition Width="5"/><ColumnDefinition Width="3*"/></Grid.ColumnDefinitions>
                    <Border Grid.Column="0" Background="#FFFFFFFF" CornerRadius="4">
                      <TreeView x:Name="W5_Tree"/>
                    </Border>
                    <GridSplitter Grid.Column="1" Width="5" HorizontalAlignment="Stretch" Background="#FFD0CEFB"/>
                    <Grid Grid.Column="2">
                      <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                      <TextBlock x:Name="W5_NodeLabel" Grid.Row="0" Foreground="#FF5B18C0" TextWrapping="Wrap" Margin="2,0,2,4"
                                 Text="Select an object in the tree to see its attributes; 'Compare with production' shows the differences."/>
                      <DataGrid x:Name="W5_Attrs" Grid.Row="1" Style="{StaticResource DG}">
                        <DataGrid.RowStyle>
                          <Style TargetType="DataGridRow">
                            <Style.Triggers>
                              <!-- Colour each changed row by the KIND of change (green = recoverable value
                                   only in the backup; amber = value differs; red = extra in production). -->
                              <DataTrigger Binding="{Binding Diff}" Value="only in snapshot">
                                <Setter Property="Background" Value="#FFDCFCE7"/>
                                <Setter Property="Foreground" Value="#FF14532D"/>
                              </DataTrigger>
                              <DataTrigger Binding="{Binding Diff}" Value="changed">
                                <Setter Property="Background" Value="#FFFEF3C7"/>
                                <Setter Property="Foreground" Value="#FF78350F"/>
                              </DataTrigger>
                              <DataTrigger Binding="{Binding Diff}" Value="added in prod">
                                <Setter Property="Background" Value="#FFFEE2E2"/>
                                <Setter Property="Foreground" Value="#FF7F1D1D"/>
                              </DataTrigger>
                            </Style.Triggers>
                          </Style>
                        </DataGrid.RowStyle>
                        <DataGrid.Columns>
                          <DataGridTextColumn Header="Attribute" Binding="{Binding Attribute}" Width="170"/>
                          <DataGridTextColumn Header="Snapshot value" Binding="{Binding SnapshotValue}" Width="*"/>
                          <DataGridTextColumn Header="Production value" Binding="{Binding ProductionValue}" Width="*"/>
                          <DataGridTextColumn Header="&#x0394;" Binding="{Binding Diff}" Width="110"/>
                        </DataGrid.Columns>
                      </DataGrid>
                    </Grid>
                  </Grid>
                </Grid>

                <!-- STEP 7 - Restore -->
                <StackPanel x:Name="WizStep6" Visibility="Collapsed">
                  <TextBlock Text="Step 7 - Restore" FontSize="15" FontWeight="Bold" Margin="0,0,0,8"/>
                  <RadioButton x:Name="W6_RadioCart" Content="Restore the cart" IsChecked="True" Margin="0,2"/>
                  <RadioButton x:Name="W6_RadioSel" Content="Restore the object currently selected in the tree" Margin="0,2"/>
                  <CheckBox x:Name="W6_ChkWhatIf" Content="Simulation mode (-WhatIf) - no writes" Foreground="#FF5B18C0" IsChecked="True" Margin="0,8,0,2"/>
                  <CheckBox x:Name="W6_ChkRemoveExtra" Content="Also remove groups added since the snapshot" Foreground="#FFB91C1C" Margin="0,2"/>
                  <DockPanel LastChildFill="True" Margin="0,8,0,0">
                    <TextBlock DockPanel.Dock="Left" Text="Restore deleted objects into (optional):" Foreground="#FF5B18C0" VerticalAlignment="Center" Margin="0,0,8,0"/>
                    <TextBox x:Name="W6_TargetOU" MaxWidth="520" HorizontalAlignment="Left" MinWidth="320"
                             ToolTip="Leave empty to restore in place. Otherwise the DN of a container/OU (e.g. OU=Quarantine,DC=corp,DC=local) - deleted objects are reanimated/recreated THERE instead of their original location."/>
                  </DockPanel>
                  <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
                    <Button x:Name="W6_BtnRestore" Content="Restore" Background="#FF721EF2" Width="160"/>
                    <Button x:Name="W6_BtnViewCart" Content="View cart (0)" Background="#FF5B18C0" Width="150"/>
                    <Button x:Name="W6_BtnPostReset" Content="Reset + enable recreated users" Background="#FF5B18C0" Width="220" IsEnabled="False"
                            ToolTip="After a real restore: set a fresh random password (change at next logon) and enable each recreated user account"/>
                    <Button x:Name="W6_BtnDismount" Content="Dismount snapshot" Background="#FFEF4444" Width="180"/>
                  </StackPanel>
                  <TextBlock TextWrapping="Wrap" Margin="0,10,0,0" Foreground="#FF697077"
                     Text="An LDIF 'undo' backup of the current state is created before any write (logs\undo folder). Keep simulation enabled for a first pass."/>
                </StackPanel>
              </Grid>
            </Border>

            <!-- Navigation -->
            <Grid Grid.Row="1" Margin="0,8,0,0">
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <ProgressBar x:Name="WizProgress" Grid.Column="0" Height="6" IsIndeterminate="False" Visibility="Hidden" VerticalAlignment="Center" Margin="0,0,12,0" Foreground="#FF7D5EFF"/>
              <StackPanel Grid.Column="1" Orientation="Horizontal">
                <Button x:Name="BtnWizBack" Content="&#9664; Back" Width="120" IsEnabled="False"/>
                <Button x:Name="BtnWizNext" Content="Next &#9654;" Width="120"/>
              </StackPanel>
            </Grid>
          </Grid>
        </Grid>

    <!-- Status bar (the detailed log now streams to a per-run file next to the program) -->
    <Grid Grid.Row="2" Margin="0,6,0,0">
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="220"/></Grid.ColumnDefinitions>
      <TextBlock x:Name="LblStatus" Grid.Column="0" Text="Ready." Foreground="#FF5B18C0" VerticalAlignment="Center"/>
      <ProgressBar x:Name="MainProgress" Grid.Column="1" Height="10" IsIndeterminate="False" Visibility="Hidden" Foreground="#FF7D5EFF"/>
    </Grid>

    <!-- Busy overlay: shown during long async operations (spinner + phase + elapsed + last log line). -->
    <Grid x:Name="BusyOverlay" Grid.Row="0" Grid.RowSpan="3" Background="#CCF3F2FF" Visibility="Collapsed" Panel.ZIndex="100">
      <Border Background="#FFFFFFFF" BorderBrush="#FF7D5EFF" BorderThickness="1" CornerRadius="10" Padding="36,28"
              HorizontalAlignment="Center" VerticalAlignment="Center">
        <StackPanel HorizontalAlignment="Center">
          <Grid Width="46" Height="46" HorizontalAlignment="Center">
            <Ellipse Width="46" Height="46" Stroke="#FFD0CEFB" StrokeThickness="5"/>
            <Path Width="46" Height="46" Stretch="None" Stroke="#FF721EF2" StrokeThickness="5"
                  StrokeStartLineCap="Round" StrokeEndLineCap="Round" Data="M 23 2 A 21 21 0 0 1 44 23"
                  RenderTransformOrigin="0.5,0.5">
              <Path.RenderTransform><RotateTransform x:Name="BusySpinnerRotate" Angle="0"/></Path.RenderTransform>
            </Path>
          </Grid>
          <TextBlock x:Name="BusyPhase" Foreground="#FF1B0C33" FontSize="16" FontWeight="SemiBold" HorizontalAlignment="Center" Margin="0,16,0,0" Text="Working..."/>
          <TextBlock x:Name="BusyElapsed" Foreground="#FF5B18C0" HorizontalAlignment="Center" Margin="0,4,0,0" Text="0:00"/>
          <TextBlock x:Name="BusyDetail" Foreground="#FF697077" HorizontalAlignment="Center" MaxWidth="460" TextWrapping="Wrap" TextAlignment="Center" Margin="0,10,0,0"/>
        </StackPanel>
      </Border>
    </Grid>
  </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$win = [Windows.Markup.XamlReader]::Load($reader)

# Start at ~80% of the screen's work area so the window does NOT fill a small (e.g. 1024x768 RDP) desktop;
# it stays resizable and maximizable from there, and never starts smaller than the usable minimum or
# larger than the screen. Falls back to the XAML size if the screen metrics are unavailable.
try {
    $wa = [System.Windows.SystemParameters]::WorkArea
    if ($wa.Width -gt 0 -and $wa.Height -gt 0) {
        $w = [Math]::Max([double]$win.MinWidth,  [Math]::Round($wa.Width  * 0.8))
        $h = [Math]::Max([double]$win.MinHeight, [Math]::Round($wa.Height * 0.8))
        $win.Width  = [Math]::Min($w, $wa.Width)
        $win.Height = [Math]::Min($h, $wa.Height)
    }
} catch {}

# Control accessor by name.
function C([string]$n) { $win.FindName($n) }

# Give the window (title bar / taskbar / Alt+Tab) the HYCU logo, rendered at runtime from the official
# logomark onto a HYCU-purple badge. Done in code (not a file) so it also works in the single-file .exe,
# which ships no side files. The .exe's own file icon is set separately at build time (Make-Icon.ps1 / -iconFile).
function Set-HYCUWindowIcon($window) {
    try {
        $data = 'F1 M624.09,888.71h133.67c160.41,0,290.59-130.18,290.59-290.59c0-89.5-40.68-169.7-103.45-223.17L738,816.64 L628.74,707.38l51.14-109.26H519.47l-33.71,74.39c-11.62,25.57-17.44,52.31-17.44,75.55C468.33,827.1,527.61,888.71,624.09,888.71 M309.09,705.06l206.9-441.7l109.26,109.26L574.1,481.88h160.41l33.71-74.39c11.62-25.57,17.44-52.31,17.44-75.55c0-79.04-59.28-140.65-155.76-140.65H496.23c-160.41,0-290.59,130.18-290.59,290.59C205.64,571.38,246.32,651.59,309.09,705.06 M1013.15,830.59c-16.05,0-29.06,13.01-29.06,29.06c0,16.05,13.01,29.06,29.06,29.06c16.05,0,29.06-13.01,29.06-29.06C1042.21,843.6,1029.2,830.59,1013.15,830.59z M1013.15,882.9c-12.84,0-23.25-10.41-23.25-23.25c0-12.84,10.41-23.25,23.25-23.25c12.84,0,23.25,10.41,23.25,23.25C1036.39,872.49,1025.99,882.9,1013.15,882.9z M1020.27,861.73c3.38-1.29,5.74-4,5.74-8.14c0-6.14-5.21-9.48-11.43-9.48h-12.33v30.25h7.12v-11.34h4.32l6.23,11.34h7.87L1020.27,861.73z M1013.86,857.99h-4.5v-8.76h4.5c3.02,0,5.07,1.78,5.07,4.45C1018.93,856.39,1016.89,857.99,1013.86,857.99z'
        $geo = [System.Windows.Media.Geometry]::Parse($data)
        $vbW = 1253.98; $vbH = 1080.0; $size = 64
        $dv = New-Object System.Windows.Media.DrawingVisual
        $dc = $dv.RenderOpen()
        $dc.DrawRoundedRectangle((New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0x5B,0x18,0xC0))), $null, (New-Object System.Windows.Rect 0,0,$size,$size), 12, 12)
        $pad = [double]$size * 0.20; $avail = $size - 2*$pad; $scale = [Math]::Min($avail/$vbW, $avail/$vbH)
        $dc.PushTransform((New-Object System.Windows.Media.TranslateTransform (($size-$vbW*$scale)/2), (($size-$vbH*$scale)/2)))
        $dc.PushTransform((New-Object System.Windows.Media.ScaleTransform $scale, $scale))
        $dc.DrawGeometry(([System.Windows.Media.Brushes]::White), $null, $geo)
        $dc.Pop(); $dc.Pop(); $dc.Close()
        $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap $size, $size, 96, 96, ([System.Windows.Media.PixelFormats]::Pbgra32)
        $rtb.Render($dv); $rtb.Freeze()
        $window.Icon = $rtb
    } catch {}
}
Set-HYCUWindowIcon $win

# ----------------------------------------------------------------------------
# Log + state (UI thread only)
# ----------------------------------------------------------------------------
function UILog($msg, $level = 'INFO') {
    # The detailed log now streams to a per-run file next to the program (see Initialize-HYCULogFile);
    # the wizard shows live progress through the busy overlay + status bar instead of a scrolling panel.
    if ($script:HYCULogFile) {
        $line = "{0:yyyy-MM-dd HH:mm:ss} [{1,-7}] {2}`r`n" -f (Get-Date), $level, $msg
        try { [System.IO.File]::AppendAllText($script:HYCULogFile, $line, [System.Text.Encoding]::UTF8) } catch {}
    }
    # Surface problems in the UI as well: file-only logging made validation warnings ("Select a
    # restore point.") and failures invisible - Next appeared dead. UILog runs on the UI thread only.
    if ($level -eq 'WARN' -or $level -eq 'ERROR') {
        try { (C 'LblStatus').Text = "[$level] $msg" } catch {}
    }
}
# Drains one queue line to the log. The log sink encodes the engine level as a "LEVEL<TAB>message"
# prefix so WARN/ERROR/SUCCESS render with their real level (not a confusing "[INFO] [WARN] ..."). Plain
# strings (the generic $Report enqueuer) have no prefix and default to INFO.
function Write-UIQueueLine($line) {
    if ($line -match "^(INFO|WARN|ERROR|SUCCESS|DEBUG)`t([\s\S]*)$") { UILog $matches[2] $matches[1] }
    else { UILog $line }
}
function Set-UIBusy([bool]$busy, [string]$text) {
    (C 'MainProgress').IsIndeterminate = $busy
    (C 'MainProgress').Visibility = if ($busy) { 'Visible' } else { 'Hidden' }
    (C 'WizProgress').IsIndeterminate = $busy
    (C 'WizProgress').Visibility = if ($busy) { 'Visible' } else { 'Hidden' }
    (C 'LblStatus').Text = $text
    (C 'BtnWizNext').IsEnabled = -not $busy
    (C 'BtnWizBack').IsEnabled = (-not $busy) -and ($script:WizCurrent -gt 1)
    # Busy overlay (spinner + phase + elapsed): a long operation never looks frozen.
    $ov = C 'BusyOverlay'
    if ($ov) {
        (C 'BusyPhase').Text = $text
        $rot = C 'BusySpinnerRotate'
        if ($busy) {
            (C 'BusyDetail').Text = ''
            $ov.Visibility = 'Visible'
            $an = New-Object System.Windows.Media.Animation.DoubleAnimation
            $an.From = 0.0; $an.To = 360.0
            $an.Duration = New-Object System.Windows.Duration([TimeSpan]::FromSeconds(1.1))
            $an.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
            try { $rot.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $an) } catch {}
        } else {
            $ov.Visibility = 'Collapsed'
            try { $rot.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $null) } catch {}
        }
    }
}

# ----------------------------------------------------------------------------
# Async runner: runspace + DispatcherTimer (the UI does not freeze)
#   -Work : scriptblock run in the worker. Signature param($In,$Report).
#           Uses ONLY $In, $Report, $sync and the module functions.
#   -OnComplete : scriptblock run on the UI thread with the result.
# ----------------------------------------------------------------------------
function Start-UIAsync {
    param(
        [Parameter(Mandatory)][scriptblock]$Work,
        [hashtable]$In = @{},
        [scriptblock]$OnComplete = {},
        [string]$BusyText = 'Working...'
    )
    if ($sync.Busy) { UILog 'An operation is already running, please wait.' 'WARN'; return }
    $sync.Busy = $true; $sync.Done = $false; $sync.Result = $null; $sync.Error = $null
    $sync.BusyStart = Get-Date
    Set-UIBusy $true $BusyText
    UILog $BusyText

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'ReuseThread'; $rs.Open()
    $rs.SessionStateProxy.SetVariable('sync', $sync)
    $rs.SessionStateProxy.SetVariable('ModulePath', $script:ModulePath)
    $rs.SessionStateProxy.SetVariable('In', $In)
    $rs.SessionStateProxy.SetVariable('WorkText', $Work.ToString())

    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript({
        # Import-Module is INSIDE the try so a load failure surfaces as $sync.Error and still hits the
        # finally (setting Done) - otherwise a failed import left Done=$false and the UI span forever
        # ("in progress", clock ticking). Single-file exe: $ModulePath points to the self-extracted temp copy.
        try {
            Import-Module $ModulePath -Force -ErrorAction Stop
            $Report = [scriptblock]::Create('param($m) $sync.Queue.Enqueue([string]$m)')
            # Surface engine progress (Write-HYCULog) live in the UI: forward every non-DEBUG line to the
            # same queue the DispatcherTimer drains, so long steps (mount + compare) show what is happening.
            if (Get-Command Set-HYCULogSink -ErrorAction SilentlyContinue) {
                Set-HYCULogSink ([scriptblock]::Create("param(`$m,`$lvl) if (`$lvl -ne 'DEBUG') { `$sync.Queue.Enqueue(`$lvl + [char]9 + [string]`$m) }"))
            }
            $work = [scriptblock]::Create($WorkText)
            $sync.Result = & $work $In $Report
        } catch {
            $sync.Error = ($_ | Out-String)
        } finally {
            $sync.Done = $true
        }
    })
    # Async state must live on $sync: a $script:-qualified variable does NOT resolve inside a WPF
    # event handler (the DispatcherTimer Tick), whereas the unqualified synchronized $sync does.
    $sync.AsyncPS = $ps
    $sync.AsyncOnComplete = $OnComplete
    $sync.AsyncHandle = $ps.BeginInvoke()

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(150)
    $timer.Add_Tick({
        $m = $null; $last = $null
        while ($sync.Queue.TryDequeue([ref]$m)) { Write-UIQueueLine $m; $last = $m }
        # Overlay live feedback: last log line as the sub-step, and the running elapsed time.
        if ($last) { $bd = C 'BusyDetail'; if ($bd) { $bd.Text = ($last -replace "^(INFO|WARN|ERROR|SUCCESS|DEBUG)`t", '') } }
        if ($sync.BusyStart) { $el = (Get-Date) - $sync.BusyStart; $be = C 'BusyElapsed'; if ($be) { $be.Text = ('{0}:{1:00}' -f [int][math]::Floor($el.TotalMinutes), $el.Seconds) } }
        if ($sync.Done) {
            while ($sync.Queue.TryDequeue([ref]$m)) { Write-UIQueueLine $m }   # final flush: worker enqueues before setting Done
            try { $sync.AsyncTimer.Stop() } catch {}
            try { $sync.AsyncPS.EndInvoke($sync.AsyncHandle) } catch {}
            # Dispose the runspace and the PowerShell as SEPARATE steps: if Close() throws, Dispose() must
            # still run (a single combined line would leak the runspace/thread on a Close failure).
            $rs = $null; try { $rs = $sync.AsyncPS.Runspace } catch {}
            try { $sync.AsyncPS.Dispose() } catch {}
            try { if ($rs) { $rs.Close(); $rs.Dispose() } } catch {}
            $sync.AsyncPS = $null; $sync.AsyncTimer = $null   # release the closures (which retain $sync/$win)
            $sync.Busy = $false
            Set-UIBusy $false 'Ready.'
            if ($sync.Error) {
                UILog "ERROR: $($sync.Error)" 'ERROR'
                # A failed operation must be unmissable: without this the overlay just vanished and the
                # status bar read "Ready." - an operator could believe a restore/scan actually ran.
                try { [System.Windows.MessageBox]::Show("The operation failed:`n`n$($sync.Error)", 'Operation failed', 'OK', 'Error') | Out-Null } catch {}
            }
            else {
                try { & $sync.AsyncOnComplete $sync.Result } catch { UILog "ERROR (post-processing): $_" 'ERROR' }
            }
        }
    })
    $sync.AsyncTimer = $timer
    $timer.Start()
}

# ----------------------------------------------------------------------------
# Shared actions (wizard)
# ----------------------------------------------------------------------------
function Invoke-MountCompare($Ntds, $Sysvol, $Port, $Live, $AllowHardRepair, [scriptblock]$OnDone) {
    if ([string]::IsNullOrWhiteSpace($Ntds)) {
        UILog 'Provide the NTDS folder.' 'WARN'
        [System.Windows.MessageBox]::Show('No NTDS folder to mount. Retrieve it from HYCU first (step 4).', 'Missing information', 'OK', 'Warning') | Out-Null
        return
    }
    # Stash the per-call callback on $sync: the -OnComplete block runs later, on the UI thread, OUTSIDE
    # this function's scope, so a function-local $OnDone would be $null there (not a closure). $sync resolves.
    $sync.MountOnDone = $OnDone
    Start-UIAsync -BusyText 'Mounting the snapshot and comparing...' -In @{ Ntds = $Ntds; Sysvol = $Sysvol; Port = [int]$Port; Live = $Live; HardRepair = [bool]$AllowHardRepair } -Work {
        param($In, $Report)
        # Failures are CAUGHT and returned (not thrown) so OnComplete always runs and can show the error.
        try {
            if ($sync.Session) { try { Dismount-HYCUADSnapshot -Session $sync.Session } catch {} ; $sync.Session = $null }
            $sysParam = @{}; if ($In.Sysvol) { $sysParam['SysvolSourcePath'] = $In.Sysvol }
            $s = Connect-HYCUADSnapshot -SourcePath $In.Ntds -Port $In.Port -AllowHardRepair:$In.HardRepair @sysParam
            $sync.Session = $s
            & $Report "Snapshot mounted on $($s.Server). Comparing..."
            $liveParam = @{}; if ($In.Live) { $liveParam['LiveServer'] = $In.Live }
            $d = Compare-HYCUADObjects -Session $s -Include All @liveParam
            $del = @($d | Where-Object { $_.Status -eq 'Deleted' }).Count
            $mod = @($d | Where-Object { $_.Status -eq 'Modified' }).Count
            & $Report "Comparison: $del deleted, $mod modified."
            # Return the diffs; the UI thread assigns $sync.Diffs in OnComplete (never write a UI-read
            # collection from the worker thread).
            [pscustomobject]@{ Ok = $true; Deleted = $del; Modified = $mod; Total = @($d).Count; Diffs = @($d) }
        } catch {
            $sync.Session = $null
            [pscustomobject]@{ Ok = $false; Error = $_.Exception.Message }
        }
    } -OnComplete {
        param($r)
        $cb = $sync.MountOnDone; $sync.MountOnDone = $null
        if ($r -and $r.Ok -and $sync.Session) {
            $sync.Diffs = @($r.Diffs)
            (C 'W4_Summary').Text = "Mounted. $($r.Deleted) deleted, $($r.Modified) modified out of $($r.Total)."
            UILog "Analysis complete: $($r.Deleted) deleted, $($r.Modified) modified." 'SUCCESS'
            (C 'LblStatus').Text = 'Snapshot mounted and compared.'
            if ($cb) { & $cb $r }
        } else {
            $msg = if ($r -and $r.Error) { $r.Error } else { 'Unknown error.' }
            UILog "Mount / compare failed: $msg" 'ERROR'
            (C 'LblStatus').Text = 'Mount failed - staying on this step.'
            [System.Windows.MessageBox]::Show("Could not mount and compare the snapshot:`n`n$msg`n`nFix the details and click Next again.", 'Mount failed', 'OK', 'Error') | Out-Null
        }
    }
}

function Invoke-RestoreItems($Items, [bool]$WhatIf, [bool]$RemoveExtra, $Live, $TargetOU) {
    $items = @($Items)
    if ($items.Count -eq 0) { UILog 'Nothing to restore (empty selection / cart).' 'WARN'; return }
    $TargetOU = ([string]$TargetOU).Trim()
    if ($TargetOU -and $TargetOU -notmatch '^(OU|CN)=[^,]+,') {
        UILog "Target OU '$TargetOU' does not look like a container DN (e.g. OU=Quarantine,DC=corp,DC=local)." 'WARN'
        [System.Windows.MessageBox]::Show("The redirect target must be a container/OU distinguished name, e.g.:`n`nOU=Quarantine,DC=corp,DC=local", 'Invalid target OU', 'OK', 'Warning') | Out-Null
        return
    }
    $mode = if ($WhatIf) { 'SIMULATION (no writes)' } else { 'REAL WRITE to production AD' }
    # Extra warning shown ONLY when the batch actually contains fully-deleted objects (Status = Deleted),
    # which are the ones that may be RECREATED with a new identity. Nothing shown for attribute-only restores.
    $deletedCount = @($items | Where-Object { $_.Status -eq 'Deleted' }).Count
    $warn = ''
    if ($deletedCount -gt 0) {
        $warn = "`n`n$deletedCount of these object(s) are fully deleted. If one is no longer in the AD Recycle Bin it is RECREATED from the backup, which means:" +
                "`n  - a NEW SID (the tool sets the old SID as sIDHistory on a best-effort basis, if your rights allow)," +
                "`n  - user/computer accounts come back DISABLED with no password (reset / domain re-join needed)."
    }
    if ($TargetOU -and $deletedCount -gt 0) { $warn += "`n`nDeleted objects will be restored INTO: $TargetOU (not their original location)." }
    $r = [System.Windows.MessageBox]::Show("Restore $($items.Count) object(s)?`n`nMode: $mode$warn", 'Confirmation', 'YesNo', 'Warning')
    if ($r -ne 'Yes') { UILog 'Restore cancelled.' 'WARN'; return }
    # Remember which USER objects are being fully restored: after a real run, the post-recreation
    # assistant (reset password + enable) proposes exactly these accounts. REAL runs only: a
    # simulation must not overwrite the target list of the last real restore (clicking the
    # still-enabled "Reset + enable" button would then act on accounts that were never restored).
    if (-not $WhatIf) {
        $sync.LastRestoreUsers = @($items | Where-Object { $_.Status -eq 'Deleted' -and $_.ObjectClass -match 'user|inetOrgPerson' -and $_.ObjectClass -notmatch 'computer' } | ForEach-Object {
            [pscustomobject]@{ Name = $_.Name; SamAccountName = [string]$_.SamAccountName; DistinguishedName = $_.DistinguishedName }
        })
        $sync.LastRestoreTargetOU = $TargetOU
    }
    # Simulation: build a plan of what a REAL run would do, shown as a popup at the end (Status is known
    # up-front from the compare, so no writes are needed to describe it).
    $sync.RestoreWhatIf = $WhatIf; $sync.RestorePlanText = $null
    if ($WhatIf) {
        $mods = @($items | Where-Object { $_.Status -eq 'Modified' }).Count
        $lines = @($items | Select-Object -First 25 | ForEach-Object {
            $nm = (($_.DistinguishedName -split '(?<!\\),')[0] -replace '^[A-Za-z]+=','')
            switch ($_.Status) {
                'Deleted'  { "  - RESTORE (reanimate from the Recycle Bin if present, else recreate with a new SID): $nm" }
                'Modified' { "  - UPDATE $(@($_.AttributeDiffs).Count) attribute(s): $nm" }
                default    { "  - $($_.Status): $nm" }
            }
        })
        $more = if ($items.Count -gt 25) { "`n  ... and $($items.Count - 25) more" } else { '' }
        $sync.RestorePlanText = "SIMULATION - nothing was written to production AD.`n`n" +
            "In a REAL restore, these $($items.Count) object(s) would be applied " +
            "($deletedCount fully-deleted -> restored, $mods modified -> attributes updated):`n`n" +
            ($lines -join "`n") + $more
    }
    # Extract serializable data (DN + status + attributes) for the worker.
    $payload = $items | ForEach-Object {
        [pscustomobject]@{
            DistinguishedName = $_.DistinguishedName
            Status            = $_.Status
            AttributeDiffs    = @($_.AttributeDiffs | ForEach-Object { [pscustomobject]@{ Attribute = $_.Attribute } })
        }
    }
    Start-UIAsync -BusyText "Restoring ($mode)..." -In @{ Items = @($payload); WhatIf = $WhatIf; RemoveExtra = $RemoveExtra; Live = $Live; TargetOU = $TargetOU } -Work {
        param($In, $Report)
        if (-not $sync.Session) { throw 'No snapshot mounted.' }
        $liveParam = @{}; if ($In.Live) { $liveParam['LiveServer'] = $In.Live }
        if ($In.TargetOU) { $liveParam['TargetParentDN'] = $In.TargetOU }
        $res = Invoke-HYCUADBulkRestore -Session $sync.Session -Items $In.Items -RemoveExtraGroups:$In.RemoveExtra -WhatIf:$In.WhatIf @liveParam
        & $Report "Restore finished ($($In.Items.Count) item(s))."
        $res
    } -OnComplete {
        param($r)
        UILog 'Restore operation finished.' 'SUCCESS'
        if ($sync.RestoreWhatIf) {
            # Simulation: show the plan of what a real run would do.
            if ($sync.RestorePlanText) { [System.Windows.MessageBox]::Show($sync.RestorePlanText, 'Simulation result - what would be restored', 'OK', 'Information') | Out-Null }
        } elseif ($r) {
            # Real restore: a per-object result summary, so the outcome is visible without opening the log.
            # Keep the result for the post-recreation assistant (reset + enable recreated users).
            $sync.LastRestoreResult = $r
            $okDeleted = @($r.Details | Where-Object { $_.Ok -and $_.Status -eq 'Deleted' } | ForEach-Object { $_.DistinguishedName })
            $sync.LastRestoreUsers = @($sync.LastRestoreUsers | Where-Object { $okDeleted -contains $_.DistinguishedName })
            $pr = C 'W6_BtnPostReset'; if ($pr) { $pr.IsEnabled = (@($sync.LastRestoreUsers).Count -gt 0) }
            $failed = @($r.Details | Where-Object { -not $_.Ok })
            $head = "Restore finished: $($r.Succeeded) succeeded, $($r.Failed) failed (of $($r.Total))."
            # Write an audit/compliance HTML report and offer to open it (best-effort - never blocks the result).
            $report = $null
            try { $report = Export-HYCUADRestoreReport -Result $r -SnapshotSource ([string]$sync.NtdsPath) -LiveServer ([string](C 'W4_LiveDC').Text) -Simulation:$false } catch {}
            if ($report) { UILog "Restore report saved: $report" 'SUCCESS' }
            $reportLine = if ($report) { "`n`nAn audit report was saved to:`n$report`n`nOpen it now?" } else { '' }
            $btns = if ($report) { 'YesNo' } else { 'OK' }
            if ($failed.Count) {
                $lines = @($failed | Select-Object -First 20 | ForEach-Object {
                    $nm = (($_.DistinguishedName -split '(?<!\\),')[0] -replace '^[A-Za-z]+=','')
                    "  - $nm : $($_.Message)"
                })
                $more = if ($failed.Count -gt 20) { "`n  ... and $($failed.Count - 20) more" } else { '' }
                $ans = [System.Windows.MessageBox]::Show("$head`n`nFailed:`n$($lines -join "`n")$more$reportLine", 'Restore result', $btns, 'Warning')
            } else {
                $ans = [System.Windows.MessageBox]::Show("$head`n`nAll objects were restored successfully.$reportLine", 'Restore result', $btns, 'Information')
            }
            if ($report -and $ans -eq 'Yes') { try { Invoke-Item -LiteralPath $report } catch { UILog "Could not open the report: $_" 'WARN' } }
        }
        $sync.RestoreWhatIf = $false; $sync.RestorePlanText = $null
    }
}

function Invoke-ExportLdif($Item) {
    if (-not $Item) { UILog 'Select an object to export.' 'WARN'; return }
    if (-not $sync.Session) { UILog 'No snapshot mounted.' 'WARN'; return }
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Filter = 'LDIF (*.ldif)|*.ldif'; $dlg.FileName = "$($Item.Name).ldif"
    if (-not $dlg.ShowDialog()) { return }
    Start-UIAsync -BusyText 'Exporting LDIF...' -In @{ DN = $Item.DistinguishedName; Path = $dlg.FileName } -Work {
        param($In, $Report)
        Export-HYCUADObjectToLdif -Session $sync.Session -DistinguishedName $In.DN -Path $In.Path -Scope Subtree
        & $Report "LDIF exported: $($In.Path)"
        'done'
    } -OnComplete { param($r) UILog 'LDIF export finished.' 'SUCCESS' }
}

# Step 6 - mounted-database tree (dsa.msc-style, lazy loaded one level at a time).
$script:W5TreeDummy = 'Loading...'
function New-W5TreeItem($node) {
    $ti = New-Object System.Windows.Controls.TreeViewItem
    $ti.Header = "$($node.Name)   [$($node.ObjectClass)]"
    $ti.Tag    = $node.DistinguishedName
    if ($node.IsContainer) { [void]$ti.Items.Add($script:W5TreeDummy) }   # placeholder -> shows the expand arrow
    $ti
}
function Expand-W5Node($item) {
    if ($sync.Busy) { return }   # don't query $sync.Session (LDAP) while an async op owns it
    if (-not $item -or -not $item.Tag) { return }
    if ($item.Items.Count -eq 1 -and ($item.Items[0] -is [string])) {     # not loaded yet
        $item.Items.Clear()
        try {
            foreach ($c in @(Get-HYCUADChildNodes -Session $sync.Session -BaseDN ([string]$item.Tag))) {
                [void]$item.Items.Add((New-W5TreeItem $c))
            }
        } catch { UILog "Tree expand failed for $($item.Tag): $_" 'WARN' }
    }
}
function Load-W5Tree {
    $tree = C 'W5_Tree'; $tree.Items.Clear(); (C 'W5_Attrs').ItemsSource = $null
    if (-not $sync.Session) { (C 'W5_NodeLabel').Text = 'Mount a database first (step 5).'; return }
    try {
        $base = [string]$sync.Session.BaseDN
        $r = Get-LdapEntries -Server $sync.Session.Server -BaseDN $base -Scope Base -Properties @('name','objectClass','distinguishedName') | Select-Object -First 1
        $rootName = if ($r -and $r.name) { [string]$r.name } else { $base }
        $rootCls  = if ($r) { (@($r.objectClass) | Select-Object -Last 1) } else { 'domainDNS' }
        $ti = New-W5TreeItem ([pscustomobject]@{ Name=$rootName; ObjectClass=$rootCls; DistinguishedName=$base; IsContainer=$true })
        [void]$tree.Items.Add($ti)
        Expand-W5Node $ti          # load the first level now
        $ti.IsExpanded = $true
        (C 'W5_NodeLabel').Text = "Mounted database: $base"
        UILog "Database tree loaded (root: $base)."
    } catch { UILog "Could not load the database tree: $_" 'ERROR' }
}
function Update-CartLabels {
    $n = $sync.Cart.Count
    (C 'W5_LblCart').Content = "Cart: $n"
    $vc = C 'W6_BtnViewCart'; if ($vc) { $vc.Content = "View cart ($n)" }
    # Reflect the cart size on the Restore button when 'Restore the cart' is the chosen mode.
    $br = C 'W6_BtnRestore'
    if ($br) {
        $cartMode = $true
        $rc = C 'W6_RadioCart'; if ($rc -and $rc.IsChecked -ne $null) { $cartMode = [bool]$rc.IsChecked }
        $br.Content = if ($cartMode) { "Restore ($n)" } else { 'Restore' }
    }
}

# Cart contents viewer: list what will be restored, remove items or clear the cart before restoring.
function Show-CartDialog {
    [xml]$cx = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Restore cart" Height="480" Width="820"
        WindowStartupLocation="CenterScreen" Background="#FFF3F2FF">
  <Grid Margin="12">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <TextBlock Grid.Row="0" x:Name="CT_Info" Foreground="#FF1B0C33" TextWrapping="Wrap" Margin="0,0,0,8"/>
    <ListView Grid.Row="1" x:Name="CT_Grid" Background="#FFFFFFFF" Foreground="#FF1B0C33" BorderBrush="#FFD0CEFB" SelectionMode="Extended">
      <!-- Force light cell text: on Server 2012 R2 / .NET 4.5 the GridViewRowPresenter does not reliably
           inherit the row Foreground, leaving the row unreadable (dark on dark). This makes it explicit. -->
      <ListView.Resources>
        <Style TargetType="TextBlock"><Setter Property="Foreground" Value="#FF1B0C33"/></Style>
      </ListView.Resources>
      <ListView.ItemContainerStyle>
        <Style TargetType="ListViewItem">
          <Setter Property="Foreground" Value="#FF1B0C33"/>
          <Setter Property="Background" Value="Transparent"/>
          <Setter Property="Template">
            <Setter.Value>
              <ControlTemplate TargetType="ListViewItem">
                <Border x:Name="Bd" Background="{TemplateBinding Background}" Padding="2,3" SnapsToDevicePixels="True" TextElement.Foreground="{TemplateBinding Foreground}">
                  <GridViewRowPresenter Content="{TemplateBinding Content}" Columns="{TemplateBinding GridView.ColumnCollection}"/>
                </Border>
                <ControlTemplate.Triggers>
                  <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="#FFD0CEFB"/></Trigger>
                  <Trigger Property="IsSelected" Value="True"><Setter TargetName="Bd" Property="Background" Value="#FFB8B4FC"/></Trigger>
                </ControlTemplate.Triggers>
              </ControlTemplate>
            </Setter.Value>
          </Setter>
        </Style>
      </ListView.ItemContainerStyle>
      <ListView.View>
        <GridView>
          <GridViewColumn Header="Status" DisplayMemberBinding="{Binding Status}" Width="90"/>
          <GridViewColumn Header="Name" DisplayMemberBinding="{Binding Name}" Width="170"/>
          <GridViewColumn Header="Class" DisplayMemberBinding="{Binding ObjectClass}" Width="110"/>
          <GridViewColumn Header="Attr." DisplayMemberBinding="{Binding ChangedCount}" Width="55"/>
          <GridViewColumn Header="DN" DisplayMemberBinding="{Binding DistinguishedName}" Width="380"/>
        </GridView>
      </ListView.View>
    </ListView>
    <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,10,0,0">
      <Button x:Name="CT_Remove" Content="Remove selected" Background="#FFEF4444" Foreground="White" BorderThickness="0" Padding="10,6" Margin="4"/>
      <Button x:Name="CT_Clear" Content="Clear cart" Background="#FF5B18C0" Foreground="White" BorderThickness="0" Padding="10,6" Margin="4"/>
      <Button x:Name="CT_Close" Content="Close" Background="#FF721EF2" Foreground="White" BorderThickness="0" Padding="10,6" Margin="4"/>
    </StackPanel>
  </Grid>
</Window>
"@
    $w = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $cx))
    $grid = $w.FindName('CT_Grid'); $info = $w.FindName('CT_Info')
    if (-not $grid -or -not $info) { UILog 'Cart view: could not locate its controls (CT_Grid/CT_Info).' 'ERROR'; return }
    # Repaint reads the live cart every time (member access on the synchronized hashtable is always current).
    # A fresh snapshot array is bound each pass; ItemsSource is reset to $null first so the ListView drops its
    # old view before rebinding (defensive - avoids a stale/empty view lingering after an in-place change).
    $repaint = {
        $rows = @($sync.Cart)
        $grid.ItemsSource = $null
        $grid.ItemsSource = $rows
        $info.Text = "$($rows.Count) item(s) in the cart - these will be restored."
    }.GetNewClosure()
    UILog "Opening cart view ($($sync.Cart.Count) item(s) currently in the cart)." 'INFO'
    & $repaint
    $w.FindName('CT_Remove').Add_Click({ foreach ($it in @($grid.SelectedItems)) { $sync.Cart.Remove($it) }; & $repaint; Update-CartLabels; UILog "Cart: $($sync.Cart.Count) item(s)." }.GetNewClosure())
    $w.FindName('CT_Clear').Add_Click({ $sync.Cart.Clear(); & $repaint; Update-CartLabels; UILog 'Cart cleared.' }.GetNewClosure())
    $w.FindName('CT_Close').Add_Click({ $w.Close() }.GetNewClosure())
    if ($win) { try { $w.Owner = $win } catch {} }   # show on top of (not behind) the main window
    $w.ShowDialog() | Out-Null
}

# Search results: pick an object to inspect (compare) or add several to the cart.
function Show-SearchDialog($results, $term) {
    [xml]$sx = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Search results" Height="480" Width="820"
        WindowStartupLocation="CenterScreen" Background="#FFF3F2FF">
  <Grid Margin="12">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <TextBlock Grid.Row="0" x:Name="SR_Info" Foreground="#FF1B0C33" TextWrapping="Wrap" Margin="0,0,0,8"/>
    <ListView Grid.Row="1" x:Name="SR_Grid" Background="#FFFFFFFF" Foreground="#FF1B0C33" BorderBrush="#FFD0CEFB" SelectionMode="Extended">
      <ListView.Resources>
        <Style TargetType="TextBlock"><Setter Property="Foreground" Value="#FF1B0C33"/></Style>
      </ListView.Resources>
      <ListView.ItemContainerStyle>
        <Style TargetType="ListViewItem">
          <Setter Property="Foreground" Value="#FF1B0C33"/>
          <Setter Property="Background" Value="Transparent"/>
          <Setter Property="Template">
            <Setter.Value>
              <ControlTemplate TargetType="ListViewItem">
                <Border x:Name="Bd" Background="{TemplateBinding Background}" Padding="2,3" SnapsToDevicePixels="True" TextElement.Foreground="{TemplateBinding Foreground}">
                  <GridViewRowPresenter Content="{TemplateBinding Content}" Columns="{TemplateBinding GridView.ColumnCollection}"/>
                </Border>
                <ControlTemplate.Triggers>
                  <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="#FFD0CEFB"/></Trigger>
                  <Trigger Property="IsSelected" Value="True"><Setter TargetName="Bd" Property="Background" Value="#FFB8B4FC"/></Trigger>
                </ControlTemplate.Triggers>
              </ControlTemplate>
            </Setter.Value>
          </Setter>
        </Style>
      </ListView.ItemContainerStyle>
      <ListView.View>
        <GridView>
          <GridViewColumn Header="Name" DisplayMemberBinding="{Binding Name}" Width="220"/>
          <GridViewColumn Header="Class" DisplayMemberBinding="{Binding ObjectClass}" Width="150"/>
          <GridViewColumn Header="DN" DisplayMemberBinding="{Binding DistinguishedName}" Width="400"/>
        </GridView>
      </ListView.View>
    </ListView>
    <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,10,0,0">
      <Button x:Name="SR_Go" Content="Go to / compare" Background="#FF7D5EFF" Foreground="White" BorderThickness="0" Padding="10,6" Margin="4"/>
      <Button x:Name="SR_AddCart" Content="Add selected to cart" Background="#FF721EF2" Foreground="White" BorderThickness="0" Padding="10,6" Margin="4"/>
      <Button x:Name="SR_Close" Content="Close" Background="#FF5B18C0" Foreground="White" BorderThickness="0" Padding="10,6" Margin="4"/>
    </StackPanel>
  </Grid>
</Window>
"@
    $w = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $sx))
    $grid = $w.FindName('SR_Grid'); $grid.ItemsSource = @($results)
    $w.FindName('SR_Info').Text = "$(@($results).Count) match(es) for '$term'. Double-click (or 'Go to') to inspect one; select rows + 'Add selected to cart' to queue them for restore."
    $go = {
        $sel = @($grid.SelectedItems); if (-not $sel.Count) { $sel = @($grid.Items) | Select-Object -First 1 }
        if ($sel -and $sel[0]) { $sync.SelectedNodeDN = [string]$sel[0].DistinguishedName; $w.Close(); Invoke-W5Compare }
    }.GetNewClosure()
    $w.FindName('SR_Go').Add_Click($go)
    $grid.Add_MouseDoubleClick($go)
    $w.FindName('SR_AddCart').Add_Click({
        foreach ($it in @($grid.SelectedItems)) {
            try {
                $item = Get-HYCUADObjectComparison -Session $sync.Session -DistinguishedName $it.DistinguishedName -LiveServer (C 'W4_LiveDC').Text
                if ($item -and -not ($sync.Cart | Where-Object { $_.DistinguishedName -eq $item.DistinguishedName })) { [void]$sync.Cart.Add($item) }
            } catch { UILog "Add to cart failed for $($it.DistinguishedName): $_" 'ERROR' }
        }
        Update-CartLabels; UILog "Cart: $($sync.Cart.Count) item(s)."
    }.GetNewClosure())
    $w.FindName('SR_Close').Add_Click({ $w.Close() }.GetNewClosure())
    if ($win) { try { $w.Owner = $win } catch {} }
    $w.ShowDialog() | Out-Null
}

# ----------------------------------------------------------------------------
# Wizard navigation
# ----------------------------------------------------------------------------
$script:WizCurrent = 1
$script:SkipHycu   = $false
# Ordered wizard panels (index = display step). Inserting the destination step keeps the
# existing control prefixes (W3_=retrieve, W4_=mount, ...) unchanged.
$script:WizPanels = @('WizStep1','WizStep2','WizDest','WizStep3','WizStep4','WizStep5','WizStep6')
$script:WizLast   = $script:WizPanels.Count        # 7
# Friendly step indices (1-based) for the panels we branch on:
$script:IdxDest     = 3   # WizDest
$script:IdxRetrieve = 4   # WizStep3
$script:IdxMount    = 5   # WizStep4
$script:IdxSelect   = 6   # WizStep5

function Update-Stepper($n) {
    # Cache each step's original caption once, so we can prefix a check mark on completed steps.
    if (-not $script:StepText) {
        $script:StepText = @{}
        1..$script:WizLast | ForEach-Object { $script:StepText[$_] = (C "N$_").Text }
    }
    1..$script:WizLast | ForEach-Object {
        $t = C "N$_"; $orig = $script:StepText[$_]
        if     ($_ -lt $n) { $t.Text = [char]0x2714 + ' ' + $orig; $t.Foreground = '#FF15803D'; $t.FontWeight = 'Normal' }  # done
        elseif ($_ -eq $n) { $t.Text = $orig;                      $t.Foreground = '#FF43128E'; $t.FontWeight = 'Bold'   }  # current
        else               { $t.Text = $orig;                      $t.Foreground = '#FF697077'; $t.FontWeight = 'Normal' }  # upcoming (dimmed)
    }
}
function Show-WizStep($n) {
    for ($k = 1; $k -le $script:WizLast; $k++) {
        (C $script:WizPanels[$k-1]).Visibility = if ($k -eq $n) { 'Visible' } else { 'Collapsed' }
    }
    $script:WizCurrent = $n
    (C 'BtnWizBack').IsEnabled = ($n -gt 1) -and (-not $sync.Busy)
    (C 'BtnWizNext').Content = if ($n -eq $script:WizLast) { 'Finish' } else { [char]0x25B6 + ' Next' }
    Update-Stepper $n
}
function Step-Valid($n) {
    switch ($script:WizPanels[$n-1]) {
        'WizStep1' { if ($script:SkipHycu) { if ([string]::IsNullOrWhiteSpace((C 'W1_NtdsManual').Text)) { UILog 'Provide the NTDS folder.' 'WARN'; return $false } }
                     else { if (-not $sync.HycuSession) { UILog 'Validate the HYCU connection first (or choose "already-restored folder").' 'WARN'; return $false } } ; return $true }
        'WizStep2' { if (-not $sync.SelectedRP) { UILog 'Select a restore point.' 'WARN'; return $false } ; return $true }
        'WizDest'  { $srv = ([string](C 'WD_Server').Text).Trim(); $shr = ([string](C 'WD_Share').Text).Trim()
                     if ([string]::IsNullOrWhiteSpace($srv)) { UILog 'Provide the destination server (name or IP).' 'WARN'; return $false }
                     if ($srv.TrimStart('\') -notmatch '^[A-Za-z0-9._-]+$') { UILog "Server '$srv' is not a valid name/IP (no spaces, backslashes or ';' - e.g. 10.169.28.161)." 'WARN'; return $false }
                     if ([string]::IsNullOrWhiteSpace($shr)) { UILog 'Provide the share name.' 'WARN'; return $false }
                     return $true }
        'WizStep3' { if (-not $sync.NtdsPath) { UILog 'Retrieve the files from HYCU first.' 'WARN'; return $false } ; return $true }
        'WizStep4' { if (-not $sync.Session) { UILog 'Mount and compare first.' 'WARN'; return $false } ; return $true }
        default    { return $true }
    }
}
function Get-TargetUnc {
    # Builds \\server\share from the step-3 fields (tolerant of stray backslashes).
    $srv = ([string](C 'WD_Server').Text).Trim().TrimStart('\')
    $shr = ([string](C 'WD_Share').Text).Trim().Trim('\')
    if (-not $srv -or -not $shr) { return '' }
    return "\\$srv\$shr"
}
function Update-Step3Summary {
    # Show the chosen VM + restore point at the top of the retrieve step.
    if ($sync.SelectedVM -and $sync.SelectedRP) {
        (C 'W3_Selected').Text = "VM: $($sync.SelectedVM.Name)    -    restore point: $($sync.SelectedRP.Timestamp)  [$($sync.SelectedRP.Consistency)]"
    }
}

function Next-WizStep {
    $n = $script:WizCurrent
    # Step 1 in HYCU mode: the connection IS the validation. If not connected yet, connect now and advance
    # only if it succeeds (Invoke-HycuConnect re-calls Next-WizStep on success, when HycuSession is set);
    # on failure it stays here and shows the error. No separate Validate button.
    if ($script:WizPanels[$n-1] -eq 'WizStep1' -and -not $script:SkipHycu -and -not $sync.HycuSession) {
        Invoke-HycuConnect { Next-WizStep }
        return
    }
    # Step 4 (Retrieve NTDS): Next fetches the database from HYCU once, then advances. If it is already
    # retrieved (the user went Back then Next), $sync.NtdsPath is set -> skip the fetch and just advance.
    if ($script:WizPanels[$n-1] -eq 'WizStep3' -and -not $sync.NtdsPath) {
        Invoke-RetrieveNtds { Next-WizStep }
        return
    }
    # Step 5 (Mount + compare): Next mounts + compares once, then advances. Already mounted -> just advance.
    if ($script:WizPanels[$n-1] -eq 'WizStep4' -and -not $sync.Session) {
        Invoke-MountCompare (C 'W4_Ntds').Text (C 'W4_Sysvol').Text (C 'W4_Port').Text (C 'W4_LiveDC').Text $false { Next-WizStep }
        return
    }
    if (-not (Step-Valid $n)) { return }
    if ($n -eq $script:WizLast) {
        # Finish = wrap up: dismount the snapshot (frees the LDAP port), clear the now-stale cart, and
        # return to step 1 for another recovery. Production is not touched by this.
        $r = [System.Windows.MessageBox]::Show(
            "Finish this recovery?`n`nThe snapshot will be dismounted (LDAP port freed) and the wizard returns to the start. Your production AD is NOT affected.",
            'Finish', 'YesNo', 'Question')
        if ($r -ne 'Yes') { return }
        if ($sync.Session) { try { Dismount-HYCUADSnapshot -Session $sync.Session } catch {} ; $sync.Session = $null }
        try { Stop-HYCUADMountResidue -Confirm:$false | Out-Null } catch {}
        $sync.Diffs = @(); $sync.Cart.Clear(); Update-CartLabels
        # Clear EVERYTHING tied to this recovery: leaving NtdsPath set made the next run skip the
        # HYCU retrieve at step 4 and silently mount the PREVIOUS backup's database. Same for the
        # selection state and the post-reset target list.
        $sync.NtdsPath = $null; $sync.SelectedVM = $null; $sync.SelectedRP = $null
        $sync.SelectedNodeDN = $null; $sync.SelectedDiff = $null; $sync.LastRestoreUsers = @()
        try { (C 'W2_GridRPs').ItemsSource = $null; (C 'W2_Selection').Text = '' } catch {}
        try { (C 'W5_Tree').Items.Clear(); (C 'W5_Attrs').ItemsSource = $null; (C 'W5_NodeLabel').Text = '' } catch {}
        try { $pr = C 'W6_BtnPostReset'; if ($pr) { $pr.IsEnabled = $false } } catch {}
        UILog 'Finished: snapshot dismounted, LDAP port freed, cart cleared. Ready for a new recovery.' 'SUCCESS'
        Show-WizStep 1
        return
    }
    $target = if ($script:WizPanels[$n-1] -eq 'WizStep1' -and $script:SkipHycu) {
                  $sync.NtdsPath = (C 'W1_NtdsManual').Text; (C 'W4_Ntds').Text = $sync.NtdsPath; $script:IdxMount
              } else { $n + 1 }
    if ($target -eq $script:IdxRetrieve) { Update-Step3Summary }
    if ($target -eq $script:IdxSelect)   { Load-W5Tree }
    Show-WizStep $target
}
function Back-WizStep {
    $n = $script:WizCurrent
    $target = if ($script:WizPanels[$n-1] -eq 'WizStep4' -and $script:SkipHycu) { 1 }
              else { [Math]::Max(1, $n - 1) }
    Show-WizStep $target
}

# ----------------------------------------------------------------------------
# Handlers - Step 1 (HYCU connection / profiles)
# ----------------------------------------------------------------------------
# Switching source mode invalidates any previously retrieved database (the other mode's path).
(C 'RadioConnectHycu').Add_Checked({ $script:SkipHycu = $false; $sync.NtdsPath = $null; (C 'HycuPanel').Visibility = 'Visible'; (C 'FolderPanel').Visibility = 'Collapsed' })
(C 'RadioUseFolder').Add_Checked({ $script:SkipHycu = $true;  $sync.NtdsPath = $null; (C 'HycuPanel').Visibility = 'Collapsed'; (C 'FolderPanel').Visibility = 'Visible' })

# Auth mode toggle: Basic -> only username/password ; API token -> only the token field
(C 'W1_AuthBasic').Add_Checked({ (C 'W1_BasicFields').Visibility = 'Visible';   (C 'W1_TokenFields').Visibility = 'Collapsed' })
(C 'W1_AuthToken').Add_Checked({ (C 'W1_BasicFields').Visibility = 'Collapsed'; (C 'W1_TokenFields').Visibility = 'Visible' })

function Load-ProfileList {
    try {
        $names = @(Get-HYCUADProfile)
        (C 'W1_Profiles').ItemsSource = $names
        (C 'WD_Profiles').ItemsSource = $names
    } catch { UILog "Could not read profiles: $_" 'DEBUG' }
}

# Save the whole profile (connection + restore destination) from the form fields.
function Save-HycuProfile($name) {
    try {
        if ([string]::IsNullOrWhiteSpace($name)) { UILog 'Provide a profile name.' 'WARN'; return }
        $isToken = [bool](C 'W1_AuthToken').IsChecked
        $fromProfile = ($sync.LoadedProfile -and $sync.LoadedProfile -eq $name)
        $common = @{ Name = $name; Server = (C 'W1_Server').Text; Port = [int](C 'W1_Port').Text;
                     ApiVersion = (C 'W1_ApiVersion').Text;
                     RestoreTargetServer = (C 'WD_Server').Text; RestoreTargetShare = (C 'WD_Share').Text;
                     RestoreTargetDomain = (C 'WD_Domain').Text; RestoreTargetUsername = (C 'WD_User').Text }
        # Read the boxes as SecureString (SecurePassword) - the plain text never materializes here.
        # An empty box gives a zero-length SecureString, so test .Length, not truthiness.
        $wdSec  = (C 'WD_Pass').SecurePassword
        $tgtPass = if ($wdSec.Length -gt 0) { $wdSec }
                   elseif ($fromProfile -and $sync.LoadedTgtPass) { $sync.LoadedTgtPass } else { $null }
        if ($tgtPass) { $common['RestoreTargetPassword'] = $tgtPass }
        if ($isToken) {
            $tokSec = (C 'W1_Token').SecurePassword
            $tok = if ($tokSec.Length -gt 0) { $tokSec }
                   elseif ($fromProfile -and $sync.LoadedToken) { $sync.LoadedToken } else { $null }
            if (-not $tok) { UILog 'Enter the API token before saving.' 'WARN'; return }
            Save-HYCUADProfile @common -ApiToken $tok | Out-Null
        } else {
            $pwSec = (C 'W1_Pass').SecurePassword
            $cred = if ($pwSec.Length -gt 0) {
                        New-Object System.Management.Automation.PSCredential((C 'W1_User').Text, $pwSec)
                    } elseif ($fromProfile -and $sync.LoadedCred) { $sync.LoadedCred } else { $null }
            if (-not $cred) { UILog 'Enter the password before saving.' 'WARN'; return }
            Save-HYCUADProfile @common -Credential $cred | Out-Null
        }
        $sync.LoadedProfile = $name
        if ($isToken) { $sync.LoadedToken = $tok; $sync.LoadedCred = $null }
        else { $sync.LoadedCred = $cred; $sync.LoadedToken = $null }
        $sync.LoadedTgtPass = $tgtPass
        UILog "Profile '$name' saved (secret DPAPI-encrypted)." 'SUCCESS'
        Load-ProfileList
    } catch { UILog "Failed to save profile: $_" 'ERROR' }
}

# Load the whole profile (connection + restore destination) into the form fields.
function Load-HycuProfile($name) {
    try {
        if ([string]::IsNullOrWhiteSpace($name)) { UILog 'Choose a profile.' 'WARN'; return }
        $p = Get-HYCUADProfile -Name $name
        (C 'W1_Server').Text = $p.Server; (C 'W1_Port').Text = $p.Port
        (C 'W1_ApiVersion').Text = $p.ApiVersion
        if ($p.AuthMode -eq 'Token') { (C 'W1_AuthToken').IsChecked = $true } else { (C 'W1_AuthBasic').IsChecked = $true; if ($p.Credential) { (C 'W1_User').Text = $p.Credential.UserName } }
        $sync.LoadedProfile = $name
        $sync.LoadedCred    = $p.Credential
        $sync.LoadedToken   = $p.ApiToken
        (C 'W1_Pass').Password = ''; (C 'W1_Token').Password = ''
        (C 'WD_Server').Text = [string]$p.RestoreTargetServer
        (C 'WD_Share').Text  = [string]$p.RestoreTargetShare
        (C 'WD_Domain').Text = [string]$p.RestoreTargetDomain
        (C 'WD_User').Text   = [string]$p.RestoreTargetUsername
        (C 'WD_Pass').Password = ''
        $sync.LoadedTgtPass  = $p.RestoreTargetPassword
        (C 'W1_Profiles').Text = $name; (C 'WD_Profiles').Text = $name
        $hasSecret = [bool]($p.Credential -or $p.ApiToken)
        UILog ("Profile '$name' loaded." + $(if ($hasSecret) { " Stored secret will be used - just click Next." } else { " No stored secret - enter it." })) 'INFO'
    } catch { UILog "Failed to load profile: $_" 'ERROR' }
}

(C 'W1_BtnSaveProfile').Add_Click({ Save-HycuProfile ([string](C 'W1_Profiles').Text) })
(C 'W1_BtnLoadProfile').Add_Click({ Load-HycuProfile ([string](C 'W1_Profiles').Text) })
# Step 3 mirrors step 1: load (or save) the same profile, populating the destination fields.
(C 'WD_BtnLoad').Add_Click({ Load-HycuProfile ([string](C 'WD_Profiles').Text) })
(C 'WD_BtnSave').Add_Click({ Save-HycuProfile ([string](C 'WD_Profiles').Text) })

# Validate the HYCU connection (async). On success runs $OnSuccess (e.g. advance the wizard); on failure it
# stays put and shows a clear error dialog - the connection IS the step-1 validation (no separate button).
function Invoke-HycuConnect([scriptblock]$OnSuccess) {
    $in = @{
        Server = (C 'W1_Server').Text; Port = [int](C 'W1_Port').Text; ApiVersion = (C 'W1_ApiVersion').Text
        AuthMode = if ([bool](C 'W1_AuthToken').IsChecked) { 'Token' } else { 'Basic' }
        # SecurePassword (SecureString), never .Password: the plain text must not transit through $In/$sync.
        User = (C 'W1_User').Text; Pass = (C 'W1_Pass').SecurePassword; Token = (C 'W1_Token').SecurePassword
        ProfileName = [string](C 'W1_Profiles').Text
    }
    if ([string]::IsNullOrWhiteSpace($in.Server)) {
        UILog 'Provide the HYCU controller.' 'WARN'
        [System.Windows.MessageBox]::Show('Provide the HYCU controller (name or IP) before continuing.', 'Missing information', 'OK', 'Warning') | Out-Null
        return
    }
    $sync.ConnectOnSuccess = $OnSuccess   # stashed on $sync: the OnComplete block runs deferred, outside this scope
    Start-UIAsync -BusyText 'Connecting to the HYCU controller...' -In $in -Work {
        param($In, $Report)
        # Certificate validation is skipped by default (self-signed controllers are the norm).
        # Secret precedence: a value typed in the form wins; otherwise the stored secret from the loaded
        # profile (DPAPI-decrypted, in memory). Failures are CAUGHT and returned (not thrown) so OnComplete
        # always runs and can show the error - a throw would only reach the generic file log.
        try {
            $fromProfile = ($sync.LoadedProfile -and $sync.LoadedProfile -eq $In.ProfileName)
            # $In.Pass / $In.Token are SecureString (PasswordBox.SecurePassword); an empty box gives a
            # zero-length SecureString, so test .Length, not truthiness.
            if ($In.AuthMode -eq 'Token') {
                $tok = if ($In.Token -and $In.Token.Length -gt 0) { $In.Token }
                       elseif ($fromProfile -and $sync.LoadedToken) { $sync.LoadedToken }
                       else { $null }
                if (-not $tok) { throw "No API token. Type it, or load a profile that has one saved." }
                $s = Connect-HYCUController -Server $In.Server -Port $In.Port -ApiVersion $In.ApiVersion -AuthMode Token -ApiToken $tok
            } else {
                $cred = if ($In.Pass -and $In.Pass.Length -gt 0) {
                            New-Object System.Management.Automation.PSCredential($In.User, $In.Pass)
                        } elseif ($fromProfile -and $sync.LoadedCred) { $sync.LoadedCred }
                        else { $null }
                if (-not $cred) { throw "No password. Type it, or load a profile that has one saved." }
                $s = Connect-HYCUController -Server $In.Server -Port $In.Port -ApiVersion $In.ApiVersion -Credential $cred
            }
            $sync.HycuSession = $s
            [pscustomobject]@{ Ok = $true }
        } catch {
            $sync.HycuSession = $null
            [pscustomobject]@{ Ok = $false; Error = $_.Exception.Message }
        }
    } -OnComplete {
        param($r)
        $cb = $sync.ConnectOnSuccess; $sync.ConnectOnSuccess = $null
        if ($r -and $r.Ok -and $sync.HycuSession) {
            UILog 'HYCU connection established.' 'SUCCESS'
            (C 'LblStatus').Text = 'HYCU connection established.'
            if ($cb) { & $cb }
        } else {
            $msg = if ($r -and $r.Error) { $r.Error } else { 'Unknown error.' }
            UILog "HYCU connection failed: $msg" 'ERROR'
            (C 'LblStatus').Text = 'HYCU connection failed - staying on step 1.'
            [System.Windows.MessageBox]::Show("Could not connect to the HYCU controller:`n`n$msg`n`nFix the details and click Next again.", 'Connection failed', 'OK', 'Error') | Out-Null
        }
    }
}

# Changing any connection detail invalidates a previously-validated session, so Next re-validates with the
# new values instead of advancing on a stale connection.
$clearHycuSession = { $sync.HycuSession = $null }
foreach ($f in 'W1_Server','W1_Port','W1_ApiVersion','W1_User') { (C $f).Add_TextChanged($clearHycuSession) }
(C 'W1_Pass').Add_PasswordChanged($clearHycuSession)
(C 'W1_Token').Add_PasswordChanged($clearHycuSession)
(C 'W1_AuthBasic').Add_Checked($clearHycuSession)
(C 'W1_AuthToken').Add_Checked($clearHycuSession)

# ----------------------------------------------------------------------------
# Handlers - Step 2 (VM + restore points)
# ----------------------------------------------------------------------------
(C 'W2_BtnListVMs').Add_Click({
    if (-not $sync.HycuSession) { UILog 'Connect to HYCU first (step 1).' 'WARN'; return }
    Start-UIAsync -BusyText 'Fetching AD domain controllers...' -In @{ Filter = (C 'W2_Filter').Text } -Work {
        param($In, $Report)
        # AD recovery only cares about domain controllers: list HYCU 'ACTIVE_DIRECTORY'
        # applications (each resolved to its linked VM) instead of every protected VM.
        if ($In.Filter) { Get-HYCUADApplication -Session $sync.HycuSession -Name $In.Filter }
        else { Get-HYCUADApplication -Session $sync.HycuSession }
    } -OnComplete {
        param($r)
        (C 'W2_GridVMs').ItemsSource = @($r)
        UILog "$(@($r).Count) AD domain controller(s) found." 'SUCCESS'
    }
})
(C 'W2_GridVMs').Add_SelectionChanged({
    $vm = (C 'W2_GridVMs').SelectedItem; if (-not $vm) { return }
    # Busy check BEFORE mutating state: assigning SelectedVM and then having Start-UIAsync refuse
    # would pair VM B with the restore-point list (and NtdsPath) of VM A.
    if ($sync.Busy) { UILog 'An operation is running; re-select the controller when it finishes.' 'WARN'; return }
    $sync.SelectedVM = $vm
    $sync.SelectedRP = $null
    $sync.NtdsPath   = $null   # a different controller invalidates any previously retrieved database
    Start-UIAsync -BusyText "Restore points for $($vm.Name)..." -In @{ Uuid = $vm.Uuid } -Work {
        param($In, $Report)
        Get-HYCURestorePoint -Session $sync.HycuSession -VmUuid $In.Uuid | Sort-Object Timestamp -Descending
    } -OnComplete {
        param($r)
        (C 'W2_GridRPs').ItemsSource = @($r)
        UILog "$(@($r).Count) restore point(s)." 'INFO'
    }
})
(C 'W2_GridRPs').Add_SelectionChanged({
    $rp = (C 'W2_GridRPs').SelectedItem; $sync.SelectedRP = $rp
    if ($rp) {
        # A (re)selected restore point must be retrieved anew - otherwise step 4 would silently
        # reuse the NTDS files of the PREVIOUS restore point.
        $sync.NtdsPath = $null
    }
    if ($rp -and $sync.SelectedVM) {
        (C 'W2_Selection').Text = "Selected: $($sync.SelectedVM.Name)  -  restore point $($rp.Timestamp) [$($rp.Consistency)].  Click 'Next' to set the restore destination (step 3)."
    }
})

# ----------------------------------------------------------------------------
# Handlers - Step 4 (file-level restore + watching)
# ----------------------------------------------------------------------------
# Retrieve the NTDS database from HYCU (async). On success sets $sync.NtdsPath and runs $OnSuccess (advance
# the wizard); on failure it stays and shows a clear error dialog. The retrieve IS the step-4 action (no
# separate button): Next runs it once - a set $sync.NtdsPath means going Back then Next won't repeat it.
function Invoke-RetrieveNtds([scriptblock]$OnSuccess) {
    $unc = Get-TargetUnc
    $missing = if (-not $sync.HycuSession) { 'Connect to HYCU first (step 1).' }
               elseif (-not $sync.SelectedVM -or -not $sync.SelectedRP) { 'Select a domain controller and a restore point (step 2).' }
               elseif ([string]::IsNullOrWhiteSpace($unc)) { 'Provide the destination server and share (step 3).' }
               else { $null }
    if ($missing) { UILog $missing 'WARN'; [System.Windows.MessageBox]::Show($missing, 'Missing information', 'OK', 'Warning') | Out-Null; return }
    $in = @{
        IncludeSysvol = $true    # always copy SYSVOL so GPO content can be restored (no checkbox)
        # SecurePassword (SecureString), never .Password: the plain text must not transit through $In/$sync.
        Unc = $unc; Domain = (C 'WD_Domain').Text; User = (C 'WD_User').Text; Pass = (C 'WD_Pass').SecurePassword
        ProfileName = [string](C 'W1_Profiles').Text
    }
    $sync.RetrieveOnSuccess = $OnSuccess
    Start-UIAsync -BusyText 'Retrieving NTDS from HYCU (mount -> restore to share -> read -> unmount)...' -In $in -Work {
        param($In, $Report)
        # Failures are CAUGHT and returned (not thrown) so OnComplete always runs and can show the error.
        try {
            # Restore-target password (SecureString end-to-end): a typed value wins; else the loaded
            # profile's stored one. It is never decrypted here - the REST layer materializes it only
            # inside the request body, at the last moment.
            $pass = if ($In.Pass -and $In.Pass.Length -gt 0) { $In.Pass }
                    elseif ($sync.LoadedTgtPass -and $sync.LoadedProfile -eq $In.ProfileName) { $sync.LoadedTgtPass }
                    else { $null }
            # No -OnProgress here: every line this emits is already logged (Write-HYCUClientLog -> Write-HYCULog),
            # and the registered log sink forwards it to the UI queue. Passing $Report too would enqueue each
            # line a SECOND time (the cause of the duplicated log lines).
            $path = Start-HYCUFileLevelRestore -Session $sync.HycuSession -Vm $sync.SelectedVM -RestorePoint $sync.SelectedRP `
                -TargetUnc $In.Unc -TargetDomain $In.Domain -TargetUsername $In.User -TargetPassword $pass `
                -IncludeSysvol:$In.IncludeSysvol -Confirm:$false
            [pscustomobject]@{ Ok = $true; Path = $path }
        } catch {
            [pscustomobject]@{ Ok = $false; Error = $_.Exception.Message }
        }
    } -OnComplete {
        param($r)
        $cb = $sync.RetrieveOnSuccess; $sync.RetrieveOnSuccess = $null
        if ($r -and $r.Ok -and $r.Path) {
            $sync.NtdsPath = $r.Path
            (C 'W3_NtdsResult').Text = $r.Path
            (C 'W4_Ntds').Text = $r.Path
            $sysvol = Join-Path (Split-Path $r.Path -Parent) 'SYSVOL'
            if (Test-Path $sysvol) { (C 'W4_Sysvol').Text = $sysvol }
            UILog "NTDS retrieved: $($r.Path)." 'SUCCESS'
            (C 'LblStatus').Text = 'NTDS retrieved.'
            if ($cb) { & $cb }
        } else {
            $msg = if ($r -and $r.Error) { $r.Error } else { 'Unknown error.' }
            UILog "NTDS retrieval failed: $msg" 'ERROR'
            (C 'LblStatus').Text = 'NTDS retrieval failed - staying on this step.'
            [System.Windows.MessageBox]::Show("Could not retrieve the NTDS files from HYCU:`n`n$msg`n`nFix the details and click Next again.", 'Retrieval failed', 'OK', 'Error') | Out-Null
        }
    }
}
# (Step 5 mount is driven by Next too - see Next-WizStep, which calls Invoke-MountCompare.)

# Results of a full "Scan all changes": a list of the deleted/modified objects, addable to the cart.
function Show-ChangesDialog {
    $changes = @($sync.Diffs | Where-Object { $_.Status -eq 'Deleted' -or $_.Status -eq 'Modified' })
    [xml]$cx = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Changes vs production" Height="520" Width="860"
        WindowStartupLocation="CenterScreen" Background="#FFF3F2FF">
  <Grid Margin="12">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <TextBlock Grid.Row="0" x:Name="CD_Info" Foreground="#FF1B0C33" TextWrapping="Wrap" Margin="0,0,0,8"/>
    <DockPanel Grid.Row="1" LastChildFill="True" Margin="0,0,0,8">
      <TextBlock DockPanel.Dock="Left" Text="Filter:" Foreground="#FF5B18C0" VerticalAlignment="Center" Margin="0,0,8,0"/>
      <TextBox x:Name="CD_Filter" Background="#FFFFFFFF" Foreground="#FF1B0C33" BorderBrush="#FFD0CEFB" CaretBrush="#FF1B0C33" Padding="4,2"
               ToolTip="Type to filter by name, type or DN"/>
    </DockPanel>
    <ListView Grid.Row="2" x:Name="CD_Grid" Background="#FFFFFFFF" Foreground="#FF1B0C33" BorderBrush="#FFD0CEFB" SelectionMode="Extended">
      <ListView.Resources>
        <Style TargetType="TextBlock"><Setter Property="Foreground" Value="#FF1B0C33"/></Style>
      </ListView.Resources>
      <ListView.ItemContainerStyle>
        <Style TargetType="ListViewItem">
          <Setter Property="Foreground" Value="#FF1B0C33"/>
          <Setter Property="Background" Value="Transparent"/>
          <Setter Property="Template">
            <Setter.Value>
              <ControlTemplate TargetType="ListViewItem">
                <Border x:Name="Bd" Background="{TemplateBinding Background}" Padding="2,3" SnapsToDevicePixels="True" TextElement.Foreground="{TemplateBinding Foreground}">
                  <GridViewRowPresenter Content="{TemplateBinding Content}" Columns="{TemplateBinding GridView.ColumnCollection}"/>
                </Border>
                <ControlTemplate.Triggers>
                  <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="#FFD0CEFB"/></Trigger>
                  <Trigger Property="IsSelected" Value="True"><Setter TargetName="Bd" Property="Background" Value="#FFB8B4FC"/></Trigger>
                </ControlTemplate.Triggers>
              </ControlTemplate>
            </Setter.Value>
          </Setter>
        </Style>
      </ListView.ItemContainerStyle>
      <ListView.View>
        <GridView>
          <GridViewColumn Header="Status" DisplayMemberBinding="{Binding Status}" Width="90"/>
          <GridViewColumn Header="Name" DisplayMemberBinding="{Binding Name}" Width="160"/>
          <GridViewColumn Header="Class" DisplayMemberBinding="{Binding ObjectClass}" Width="110"/>
          <GridViewColumn Header="Attr." DisplayMemberBinding="{Binding ChangedCount}" Width="55"/>
          <GridViewColumn Header="DN" DisplayMemberBinding="{Binding DistinguishedName}" Width="420"/>
        </GridView>
      </ListView.View>
    </ListView>
    <StackPanel Grid.Row="3" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,10,0,0">
      <Button x:Name="CD_AddCart" Content="Add selected to cart" Background="#FF721EF2" Foreground="White" BorderThickness="0" Padding="10,6" Margin="4"/>
      <Button x:Name="CD_Close" Content="Close" Background="#FF5B18C0" Foreground="White" BorderThickness="0" Padding="10,6" Margin="4"/>
    </StackPanel>
  </Grid>
</Window>
"@
    $w = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $cx))
    $grid = $w.FindName('CD_Grid'); $grid.ItemsSource = $changes
    $info = $w.FindName('CD_Info')
    $info.Text = "$($changes.Count) changed object(s) vs production. Select rows, click 'Add selected to cart', then restore them in the Restore step."
    # Live filter: narrow the list by name / type / status / DN as the user types.
    $flt = $w.FindName('CD_Filter')
    $flt.Add_TextChanged({
        $term = ([string]$flt.Text).Trim()
        if ([string]::IsNullOrEmpty($term)) { $shown = $changes }
        else {
            $shown = @($changes | Where-Object {
                ("$($_.Name) $($_.ObjectClass) $($_.Status) $($_.DistinguishedName)") -match [regex]::Escape($term)
            })
        }
        $grid.ItemsSource = $shown
        $info.Text = "$(@($shown).Count) of $($changes.Count) changed object(s) shown. Select rows, click 'Add selected to cart', then restore them in the Restore step."
    }.GetNewClosure())
    $add = $w.FindName('CD_AddCart')
    $add.Add_Click({
        foreach ($it in @($grid.SelectedItems)) { if (-not ($sync.Cart | Where-Object { $_.DistinguishedName -eq $it.DistinguishedName })) { [void]$sync.Cart.Add($it) } }
        Update-CartLabels; UILog "Cart: $($sync.Cart.Count) item(s)."
    }.GetNewClosure())
    $w.FindName('CD_Close').Add_Click({ $w.Close() }.GetNewClosure())
    if ($win) { try { $w.Owner = $win } catch {} }
    $w.ShowDialog() | Out-Null
}

# Read-only viewer for the live AD Recycle Bin (objects still reanimable, SID preserved).
function Show-RecycleBinDialog($items) {
    $items = @($items)
    [xml]$rx = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="AD Recycle Bin (reanimable objects)" Height="500" Width="880"
        WindowStartupLocation="CenterScreen" Background="#FFF3F2FF">
  <Grid Margin="12">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <TextBlock Grid.Row="0" x:Name="RB_Info" Foreground="#FF1B0C33" TextWrapping="Wrap" Margin="0,0,0,8"/>
    <DockPanel Grid.Row="1" LastChildFill="True" Margin="0,0,0,8">
      <TextBlock DockPanel.Dock="Left" Text="Filter:" Foreground="#FF5B18C0" VerticalAlignment="Center" Margin="0,0,8,0"/>
      <TextBox x:Name="RB_Filter" Background="#FFFFFFFF" Foreground="#FF1B0C33" BorderBrush="#FFD0CEFB" CaretBrush="#FF1B0C33" Padding="4,2"
               ToolTip="Type to filter by name, type or last-known parent"/>
    </DockPanel>
    <ListView Grid.Row="2" x:Name="RB_Grid" Background="#FFFFFFFF" Foreground="#FF1B0C33" BorderBrush="#FFD0CEFB">
      <ListView.View>
        <GridView>
          <GridViewColumn Header="Name" DisplayMemberBinding="{Binding Name}" Width="180"/>
          <GridViewColumn Header="Class" DisplayMemberBinding="{Binding ObjectClass}" Width="110"/>
          <GridViewColumn Header="Deleted" DisplayMemberBinding="{Binding Deleted}" Width="140"/>
          <GridViewColumn Header="Last-known parent" DisplayMemberBinding="{Binding LastKnownParent}" Width="400"/>
        </GridView>
      </ListView.View>
    </ListView>
    <StackPanel Grid.Row="3" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,10,0,0">
      <Button x:Name="RB_Close" Content="Close" Background="#FF5B18C0" Foreground="White" BorderThickness="0" Padding="10,6" Margin="4"/>
    </StackPanel>
  </Grid>
</Window>
"@
    $w = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $rx))
    $grid = $w.FindName('RB_Grid'); $grid.ItemsSource = $items
    $info = $w.FindName('RB_Info')
    $note = "$($items.Count) object(s) in the AD Recycle Bin - each is reanimable with its SID preserved (restore it from the Restore step). Read-only view."
    $info.Text = $note
    $flt = $w.FindName('RB_Filter')
    $flt.Add_TextChanged({
        $term = ([string]$flt.Text).Trim()
        if ([string]::IsNullOrEmpty($term)) { $shown = $items }
        else { $shown = @($items | Where-Object { ("$($_.Name) $($_.ObjectClass) $($_.LastKnownParent)") -match [regex]::Escape($term) }) }
        $grid.ItemsSource = $shown
        $info.Text = "$(@($shown).Count) of $($items.Count) shown. $note"
    }.GetNewClosure())
    $w.FindName('RB_Close').Add_Click({ $w.Close() }.GetNewClosure())
    if ($win) { try { $w.Owner = $win } catch {} }
    $w.ShowDialog() | Out-Null
}

# Results of the post-recreation assistant. The generated passwords appear ONLY here (never in the
# log, the report, or the saved UI state) - the operator must hand them over now.
function Show-PostResetDialog($results) {
    $results = @($results)
    [xml]$px = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Recreated accounts - new passwords (shown once)" Height="440" Width="760"
        WindowStartupLocation="CenterScreen" Background="#FFF3F2FF">
  <Grid Margin="12">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <TextBlock Grid.Row="0" Foreground="#FFB91C1C" FontWeight="SemiBold" TextWrapping="Wrap" Margin="0,0,0,8"
               Text="Hand these passwords over NOW: they are displayed once, are not logged, and each user must change theirs at next logon."/>
    <ListView Grid.Row="1" x:Name="PR_Grid" Background="#FFFFFFFF" Foreground="#FF1B0C33" BorderBrush="#FFD0CEFB">
      <ListView.View>
        <GridView>
          <GridViewColumn Header="Account" DisplayMemberBinding="{Binding Identity}" Width="300"/>
          <GridViewColumn Header="Result" DisplayMemberBinding="{Binding Message}" Width="220"/>
          <GridViewColumn Header="New password" DisplayMemberBinding="{Binding Password}" Width="180"/>
        </GridView>
      </ListView.View>
    </ListView>
    <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,10,0,0">
      <Button x:Name="PR_Copy" Content="Copy to clipboard" Background="#FF721EF2" Foreground="White" BorderThickness="0" Padding="10,6" Margin="4"
              ToolTip="Copies account + password pairs; clear your clipboard after handing them over"/>
      <Button x:Name="PR_Close" Content="Close" Background="#FF5B18C0" Foreground="White" BorderThickness="0" Padding="10,6" Margin="4"/>
    </StackPanel>
  </Grid>
</Window>
"@
    $w = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $px))
    $w.FindName('PR_Grid').ItemsSource = $results
    $w.FindName('PR_Copy').Add_Click({
        try {
            $txt = ($results | Where-Object { $_.Password } | ForEach-Object { "$($_.Identity)`t$($_.Password)" }) -join "`r`n"
            [System.Windows.Clipboard]::SetText($txt)
        } catch {}
    }.GetNewClosure())
    $w.FindName('PR_Close').Add_Click({ $w.Close() }.GetNewClosure())
    if ($win) { try { $w.Owner = $win } catch {} }
    $w.ShowDialog() | Out-Null
    $ok = @($results | Where-Object { $_.Ok }).Count
    UILog "Post-recreation assistant: $ok of $($results.Count) account(s) reset and enabled (passwords displayed once, not logged)." 'SUCCESS'
}

# Query the live AD Recycle Bin off the UI thread (read-only), then show the viewer.
function Invoke-W5RecycleBin {
    if ($sync.Busy) { UILog 'An operation is running; please wait.' 'WARN'; return }
    $live = ([string](C 'W4_LiveDC').Text).Trim()
    Start-UIAsync -BusyText 'Reading the AD Recycle Bin...' -In @{ Live = $live } -Work {
        param($In, $Report)
        try {
            $p = @{}; if ($In.Live) { $p['Server'] = $In.Live }
            $objs = @(Get-HYCUADRecycleBinObject @p)
            & $Report "AD Recycle Bin: $($objs.Count) reanimable object(s)."
            [pscustomobject]@{ Ok = $true; Items = $objs }
        } catch {
            [pscustomobject]@{ Ok = $false; Error = $_.Exception.Message }
        }
    } -OnComplete {
        param($r)
        if ($r -and $r.Ok) {
            if (@($r.Items).Count -eq 0) { UILog 'AD Recycle Bin: no reanimable objects (or the feature is not enabled).' 'INFO' }
            Show-RecycleBinDialog @($r.Items)
        } else {
            $msg = if ($r -and $r.Error) { $r.Error } else { 'Unknown error.' }
            UILog "Could not read the AD Recycle Bin: $msg" 'ERROR'
            [System.Windows.MessageBox]::Show("Could not read the AD Recycle Bin:`n`n$msg`n`nThis needs the ActiveDirectory RSAT module and the AD Recycle Bin feature enabled in the forest.", 'AD Recycle Bin', 'OK', 'Warning') | Out-Null
        }
    }
}

# ----------------------------------------------------------------------------
# Handlers - Step 6 (selection)
# ----------------------------------------------------------------------------
(C 'W5_BtnReload').Add_Click({ Load-W5Tree })
(C 'W5_BtnRecycle').Add_Click({ try { Invoke-W5RecycleBin } catch { UILog "Recycle Bin view failed: $_" 'ERROR' } })

# List every Group Policy object in the snapshot by its friendly name, so GPOs can be found and
# restored without hunting for the unreadable {GUID} nodes under CN=Policies,CN=System. The results
# reuse the search dialog: select a GPO to compare it with production or add it to the restore cart
# (its SYSVOL content - Registry.pol, scripts, ADMX - is copied on restore, see Get-GpoRestorePathNote).
function Invoke-W5ListGpos {
    if ($sync.Busy) { UILog 'An operation is running; please wait.' 'WARN'; return }   # the worker owns $sync.Session (LDAP)
    if (-not $sync.Session) { UILog 'Mount a database first (step 5).' 'WARN'; return }
    try {
        $res = @(Get-LdapEntries -Server $sync.Session.Server -BaseDN $sync.Session.BaseDN -Scope Subtree `
                    -Filter '(objectClass=groupPolicyContainer)' `
                    -Properties @('name','displayName','objectClass','distinguishedName','gPCFileSysPath'))
        $items = foreach ($e in $res) {
            $nm = if ([string]$e.displayName) { [string]$e.displayName } else { [string]$e.name }
            [pscustomobject]@{ Name = $nm; ObjectClass = 'groupPolicyContainer'; DistinguishedName = [string]$e.distinguishedName }
        }
        $items = @($items | Sort-Object Name)
        UILog "List GPOs: $(@($items).Count) Group Policy object(s) in the snapshot."
        if (@($items).Count -eq 0) { UILog 'No Group Policy objects found in the snapshot.' 'INFO'; return }
        Show-SearchDialog @($items) 'Group Policy objects'
    } catch { UILog "List GPOs failed: $_" 'ERROR' }
}
(C 'W5_BtnListGpo').Add_Click({ Invoke-W5ListGpos })

# Lazy expansion: load a node's children the first time it is expanded.
(C 'W5_Tree').AddHandler(
    [System.Windows.Controls.TreeViewItem]::ExpandedEvent,
    [System.Windows.RoutedEventHandler]{ param($s, $e) Expand-W5Node $e.OriginalSource }
)
# For a Group Policy object, a human-readable note showing WHERE its content is restored (SYSVOL).
function Get-GpoRestorePathNote($dn) {
    if ($dn -match '^CN=(\{[0-9A-Fa-f-]+\}),CN=Policies,CN=System,') {
        $guid = $matches[1]
        $dom  = (@($dn -split '(?<!\\),' | Where-Object { $_ -match '^DC=' }) -replace '^DC=','') -join '.'
        return "`r`nGroup Policy - on restore, its content is copied to:  \\$dom\SYSVOL\$dom\Policies\$guid"
    }
    return ''
}
# Selecting a node shows its attributes (browse mode).
(C 'W5_Tree').Add_SelectedItemChanged({
    if ($sync.Busy) { return }   # don't hit $sync.Session (LDAP) while an async op owns it
    $it = (C 'W5_Tree').SelectedItem
    if ($it -and $it.Tag) {
        $sync.SelectedNodeDN = [string]$it.Tag
        (C 'W5_NodeLabel').Text = "$($sync.SelectedNodeDN)$(Get-GpoRestorePathNote $sync.SelectedNodeDN)"
        try { (C 'W5_Attrs').ItemsSource = @(Get-HYCUADObjectAttributes -Session $sync.Session -DistinguishedName $sync.SelectedNodeDN) }
        catch { UILog "Could not read attributes for $($sync.SelectedNodeDN): $_" 'WARN' }
    }
})
# Compare the selected object with production (show only the differences). Shared by the button, a
# double-click on the tree, and the search dialog.
function Invoke-W5Compare {
    if ($sync.Busy) { UILog 'An operation is running; please wait before comparing.' 'WARN'; return }
    if (-not $sync.SelectedNodeDN) { UILog 'Select an object in the tree first.' 'WARN'; return }
    try {
        $cmp = Get-HYCUADObjectComparisonRows -Session $sync.Session -DistinguishedName $sync.SelectedNodeDN -LiveServer (C 'W4_LiveDC').Text
        if (-not $cmp) { UILog 'Object not found in the snapshot.' 'WARN'; return }
        $sync.SelectedDiff = $cmp.Item
        (C 'W5_Attrs').ItemsSource = @($cmp.Rows)         # ALL attributes, changed ones highlighted
        $existsTxt = if ($cmp.Exists) { 'present in production' } else { 'ABSENT in production (would be recreated on restore)' }
        (C 'W5_NodeLabel').Text = "$($sync.SelectedNodeDN)   ->   $($cmp.Status), $($cmp.ChangedCount) change(s) - $existsTxt$(Get-GpoRestorePathNote $sync.SelectedNodeDN)"
        UILog "Compared $($sync.SelectedNodeDN): $($cmp.Status), $($cmp.ChangedCount) attribute change(s) - $existsTxt." 'SUCCESS'
    } catch { UILog "Compare failed: $_" 'ERROR' }
}
(C 'W5_BtnCompare').Add_Click({ Invoke-W5Compare })
# Double-click a node = compare it (fewer clicks).
(C 'W5_Tree').Add_MouseDoubleClick({ if ($sync.SelectedNodeDN) { Invoke-W5Compare } })
# Find an object by name and act on it from a results list.
function Invoke-W5Search {
    # Busy guard: the overlay blocks the mouse but NOT the keyboard - Enter in the search box would
    # run an LDAP query against $sync.Session while a worker owns it.
    if ($sync.Busy) { UILog 'An operation is running; please wait.' 'WARN'; return }
    if (-not $sync.Session) { UILog 'Mount a database first (step 5).' 'WARN'; return }
    $term = ([string](C 'W5_Search').Text).Trim()
    if (-not $term) { UILog 'Type something to search for.' 'WARN'; return }
    try {
        $esc = $term -replace '\\','\5c' -replace '\*','\2a' -replace '\(','\28' -replace '\)','\29'
        $filter = "(|(name=*$esc*)(displayName=*$esc*)(sAMAccountName=*$esc*))"
        $res = @(Get-LdapEntries -Server $sync.Session.Server -BaseDN $sync.Session.BaseDN -Scope Subtree -Filter $filter `
                    -Properties @('name','displayName','objectClass','distinguishedName','sAMAccountName') | Select-Object -First 300)
        $items = foreach ($e in $res) {
            $cls = (@($e.objectClass) | Select-Object -Last 1)
            $nm  = [string]$e.name
            if ($cls -eq 'groupPolicyContainer' -and [string]$e.displayName) { $nm = [string]$e.displayName }
            [pscustomobject]@{ Name = $nm; ObjectClass = $cls; DistinguishedName = [string]$e.distinguishedName }
        }
        UILog "Search '$term': $(@($items).Count) match(es)."
        Show-SearchDialog @($items) $term
    } catch { UILog "Search failed: $_" 'ERROR' }
}
(C 'W5_BtnFind').Add_Click({ Invoke-W5Search })
(C 'W5_Search').Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { Invoke-W5Search } })
# Add the selected object (with its computed diff) to the restore cart.
(C 'W5_BtnAddCart').Add_Click({
    if ($sync.Busy) { UILog 'An operation is running; please wait.' 'WARN'; return }
    if (-not $sync.SelectedNodeDN) { UILog 'Select an object in the tree first.' 'WARN'; return }
    try {
        $item = Get-HYCUADObjectComparison -Session $sync.Session -DistinguishedName $sync.SelectedNodeDN -LiveServer (C 'W4_LiveDC').Text
        if ($item) {
            if (-not ($sync.Cart | Where-Object { $_.DistinguishedName -eq $item.DistinguishedName })) { [void]$sync.Cart.Add($item) }
            Update-CartLabels; UILog "Added to cart: $($item.Name) [$($item.Status)]. Cart: $($sync.Cart.Count) item(s)."
        }
    } catch { UILog "Add to cart failed: $_" 'ERROR' }
})
# Cherry-pick: add ONLY the attributes selected in the compare grid to the cart (not the whole diff).
(C 'W5_BtnAddAttrs').Add_Click({
    if ($sync.Busy) { UILog 'An operation is running; please wait.' 'WARN'; return }
    if (-not $sync.SelectedDiff) { UILog "Run 'Compare with production' first, then select the attribute rows to restore." 'WARN'; return }
    try {
        $sel = @((C 'W5_Attrs').SelectedItems | Where-Object { $_.IsChanged } | ForEach-Object { $_.Attribute })
        if ($sel.Count -eq 0) { UILog 'Select at least one CHANGED attribute row in the grid (coloured rows).' 'WARN'; return }
        $src = $sync.SelectedDiff
        if ($src.Status -eq 'Deleted') { UILog 'This object is fully deleted - attribute cherry-pick only applies to Modified objects (use Add to cart).' 'WARN'; return }
        $picked = @($src.AttributeDiffs | Where-Object { $sel -contains $_.Attribute })
        $item = [pscustomobject]@{
            Name = $src.Name; ObjectClass = $src.ObjectClass; SamAccountName = $src.SamAccountName
            DistinguishedName = $src.DistinguishedName; ObjectGUID = $src.ObjectGUID
            Status = 'Modified'; AttributeDiffs = $picked; ChangedCount = @($picked).Count
        }
        # Replace any previous cart entry for the same object (the newest pick wins).
        $old = @($sync.Cart | Where-Object { $_.DistinguishedName -eq $item.DistinguishedName })
        foreach ($o in $old) { $sync.Cart.Remove($o) }
        [void]$sync.Cart.Add($item)
        Update-CartLabels
        UILog "Added to cart: $($item.Name) - ONLY $(@($picked).Count) attribute(s): $(($sel | Select-Object -First 6) -join ', ')$(if ($sel.Count -gt 6) { ', ...' })." 'SUCCESS'
    } catch { UILog "Add selected attributes failed: $_" 'ERROR' }
})
# Whole-subtree recovery: scan the selected container/OU and cart every change under it, parents first.
(C 'W5_BtnAddSubtree').Add_Click({
    if ($sync.Busy) { UILog 'An operation is running; please wait.' 'WARN'; return }
    if (-not $sync.SelectedNodeDN) { UILog 'Select a container/OU in the tree first.' 'WARN'; return }
    $base = $sync.SelectedNodeDN
    Start-UIAsync -BusyText "Scanning the subtree of $base..." -In @{ Base = $base; Live = (C 'W4_LiveDC').Text } -Work {
        param($In, $Report)
        $p = @{}; if ($In.Live) { $p['LiveServer'] = $In.Live }
        $items = @(Get-HYCUADSubtreeChanges -Session $sync.Session -BaseDN $In.Base @p)
        & $Report "Subtree scan: $($items.Count) change(s) found."
        [pscustomobject]@{ Items = $items; Base = $In.Base }
    } -OnComplete {
        param($r)
        if (-not $r) { return }
        $added = 0
        foreach ($it in @($r.Items)) {
            if (-not ($sync.Cart | Where-Object { $_.DistinguishedName -eq $it.DistinguishedName })) { [void]$sync.Cart.Add($it); $added++ }
        }
        Update-CartLabels
        if (@($r.Items).Count -eq 0) { UILog "Subtree of $($r.Base): no differences with production." 'SUCCESS' }
        else { UILog "Subtree of $($r.Base): $added object(s) added to the cart (parents first - restore recreates the OU before its children)." 'SUCCESS' }
    }
})
(C 'W5_BtnExport').Add_Click({
    if (-not $sync.SelectedNodeDN) { UILog 'Select an object in the tree first.' 'WARN'; return }
    $nm = (($sync.SelectedNodeDN -split '(?<!\\),')[0] -replace '^[A-Za-z]+=','')
    Invoke-ExportLdif ([pscustomobject]@{ Name = $nm; DistinguishedName = $sync.SelectedNodeDN })
})
# Scan the whole database for deleted/modified objects (async) and list them.
(C 'W5_BtnScan').Add_Click({
    Start-UIAsync -BusyText 'Scanning the whole database for changes (snapshot vs production)...' -In @{ Live = (C 'W4_LiveDC').Text } -Work {
        param($In, $Report)
        if (-not $sync.Session) { throw 'No snapshot mounted.' }
        $lp = @{}; if ($In.Live) { $lp['LiveServer'] = $In.Live }
        $d = Compare-HYCUADObjects -Session $sync.Session -Include All @lp
        # Return the diffs; $sync.Diffs is assigned on the UI thread in OnComplete (not from the worker).
        [pscustomobject]@{ Deleted = @($d | Where-Object { $_.Status -eq 'Deleted' }).Count; Modified = @($d | Where-Object { $_.Status -eq 'Modified' }).Count; Diffs = @($d) }
    } -OnComplete {
        param($r)
        if ($r) {
            $sync.Diffs = @($r.Diffs)
            if (($r.Deleted + $r.Modified) -eq 0) { UILog 'Scan complete: NO differences - the mounted database matches production.' 'SUCCESS' }
            else { UILog "Scan complete: $($r.Deleted) deleted, $($r.Modified) modified." 'SUCCESS'; Show-ChangesDialog }
        }
    }
})
(C 'W5_BtnViewCart').Add_Click({ try { Show-CartDialog } catch { UILog "View cart failed: $_" 'ERROR' } })

# ----------------------------------------------------------------------------
# Handlers - Step 7 (restore)
# ----------------------------------------------------------------------------
# Toggling the restore mode re-labels the Restore button (shows the cart count in cart mode).
(C 'W6_RadioCart').Add_Checked({ try { Update-CartLabels } catch {} })
(C 'W6_RadioSel').Add_Checked({ try { Update-CartLabels } catch {} })
(C 'W6_BtnViewCart').Add_Click({ try { Show-CartDialog } catch { UILog "View cart failed: $_" 'ERROR' } })
(C 'W6_BtnRestore').Add_Click({
    # Guard: after a dismount, $sync.Session is $null - the selected-object path would call the
    # engine with a null session (unhandled exception in a dispatcher handler = window crash).
    if (-not $sync.Session) { UILog 'No snapshot mounted - mount a database first (step 5).' 'WARN'; return }
    try {
        $items = if ([bool](C 'W6_RadioCart').IsChecked) { @($sync.Cart) }
                 elseif ($sync.SelectedNodeDN) { @(Get-HYCUADObjectComparison -Session $sync.Session -DistinguishedName $sync.SelectedNodeDN -LiveServer (C 'W4_LiveDC').Text) | Where-Object { $_ } }
                 else { @() }
    } catch { UILog "Could not prepare the restore selection: $_" 'ERROR'; return }
    Invoke-RestoreItems $items ([bool](C 'W6_ChkWhatIf').IsChecked) ([bool](C 'W6_ChkRemoveExtra').IsChecked) (C 'W4_LiveDC').Text ((C 'W6_TargetOU').Text)
})
# Post-recreation assistant: reset a fresh random password (+change at next logon) and enable each
# user account that the LAST real restore fully recreated. Passwords are shown ONCE - never logged.
(C 'W6_BtnPostReset').Add_Click({
    if ($sync.Busy) { UILog 'An operation is running; please wait.' 'WARN'; return }
    $users = @($sync.LastRestoreUsers)
    if ($users.Count -eq 0) { UILog 'No recreated user accounts from the last restore.' 'INFO'; return }
    $names = ($users | Select-Object -First 15 | ForEach-Object { "  - $($_.Name) ($($_.SamAccountName))" }) -join "`n"
    $more = if ($users.Count -gt 15) { "`n  ... and $($users.Count - 15) more" } else { '' }
    # Honor the step's Simulation checkbox like every other production write (CLAUDE.md: -WhatIf is
    # the default for anything that writes to production AD).
    $simulate = [bool](C 'W6_ChkWhatIf').IsChecked
    $modeLine = if ($simulate) { "`n`nMode: SIMULATION (-WhatIf) - nothing will be written; untick 'Simulation mode' to apply." } else { '' }
    $ans = [System.Windows.MessageBox]::Show(
        "Reset the password (random, must change at next logon) and ENABLE these $($users.Count) recreated account(s)?`n`n$names$more`n`nThe new passwords are displayed ONCE and are not logged.$modeLine",
        'Post-recreation assistant', 'YesNo', 'Warning')
    if ($ans -ne 'Yes') { return }
    # Identify by sAMAccountName (stable even when the restore was redirected to another OU).
    $ids = @($users | ForEach-Object { if ($_.SamAccountName) { $_.SamAccountName } else { $_.DistinguishedName } })
    # Stash on $sync: a plain local would not resolve inside OnComplete (it runs later, from the
    # DispatcherTimer tick scope - PowerShell scriptblocks are dynamically scoped, not closures).
    $sync.PostResetWhatIf = $simulate
    Start-UIAsync -BusyText 'Resetting and enabling the recreated accounts...' -In @{ Ids = $ids; Live = (C 'W4_LiveDC').Text; WhatIf = $simulate } -Work {
        param($In, $Report)
        $p = @{}; if ($In.Live) { $p['Server'] = $In.Live }
        $res = @(Reset-HYCUADRecreatedAccount -Identity $In.Ids @p -WhatIf:$In.WhatIf -Confirm:$false)
        & $Report "Post-recreation reset finished ($(@($res).Count) account(s))."
        ,$res
    } -OnComplete {
        param($r)
        if (@($r).Count) { Show-PostResetDialog @($r) }
        elseif ($sync.PostResetWhatIf) { UILog 'Simulation: no account was reset or enabled (untick Simulation mode to apply).' 'INFO' }
    }
})
(C 'W6_BtnDismount').Add_Click({
    if ($sync.Busy) { UILog 'An operation is running; wait for it to finish before dismounting.' 'WARN'; return }
    try {
        if ($sync.Session) { Dismount-HYCUADSnapshot -Session $sync.Session; $sync.Session = $null; UILog 'Snapshot dismounted.' 'SUCCESS' }
        else { Stop-HYCUADMountResidue -Confirm:$false | Out-Null; UILog 'Cleaned up any residual mount processes.' 'SUCCESS' }
    } catch { UILog "Dismount failed: $_" 'ERROR' }
    # Clear the selection state tied to the (now gone) mounted database, so no handler can use a
    # stale DN / diff against a null session.
    $sync.SelectedNodeDN = $null; $sync.SelectedDiff = $null; $sync.Diffs = @()
    try { (C 'W5_Tree').Items.Clear(); (C 'W5_Attrs').ItemsSource = $null; (C 'W5_NodeLabel').Text = 'Snapshot dismounted - mount a database to browse again (step 5).' } catch {}
})

# ----------------------------------------------------------------------------
# Navigation
# ----------------------------------------------------------------------------
(C 'BtnWizNext').Add_Click({ Next-WizStep })
(C 'BtnWizBack').Add_Click({ Back-WizStep })
# Keyboard navigation: Esc = Back, Enter = Next. Enter is NOT hijacked while typing in the tree search
# box (it runs its own search) or in a multi-line field.
$win.Add_PreviewKeyDown({
    param($s, $e)
    if ($e.Key -eq 'Escape') { if ((C 'BtnWizBack').IsEnabled) { Back-WizStep; $e.Handled = $true } ; return }
    if ($e.Key -eq 'Return') {
        $fe = [System.Windows.Input.Keyboard]::FocusedElement
        if ($fe -eq (C 'W5_Search')) { return }
        if ($fe -is [System.Windows.Controls.TextBox] -and $fe.AcceptsReturn) { return }
        if ((C 'BtnWizNext').IsEnabled) { Next-WizStep; $e.Handled = $true }
    }
})

# ----------------------------------------------------------------------------
# Remember the last session (window size/position, last profile + destination). Non-secret UI state only.
# ----------------------------------------------------------------------------
function Get-UIStatePath {
    $dir = try { (Get-HYCUADConfig).ProfileDirectory } catch { Join-Path $env:APPDATA 'HYCU\ADRecoveryTool' }
    if (-not (Test-Path $dir)) { try { New-Item -ItemType Directory -Path $dir -Force | Out-Null } catch {} }
    Join-Path $dir 'ui-state.json'
}
function Save-UIState {
    try {
        if ($win.WindowState -eq 'Maximized') { $rb = $win.RestoreBounds; $W=$rb.Width; $H=$rb.Height; $L=$rb.Left; $T=$rb.Top; $max=$true }
        else { $W=$win.ActualWidth; $H=$win.ActualHeight; $L=$win.Left; $T=$win.Top; $max=$false }
        $st = [ordered]@{
            Width=[int]$W; Height=[int]$H; Left=[int]$L; Top=[int]$T; Maximized=$max
            Profile=[string](C 'W1_Profiles').Text
            DestServer=[string](C 'WD_Server').Text; DestShare=[string](C 'WD_Share').Text
            DestDomain=[string](C 'WD_Domain').Text; DestUser=[string](C 'WD_User').Text
        }
        $st | ConvertTo-Json | Set-Content -LiteralPath (Get-UIStatePath) -Encoding UTF8
    } catch {}
}
function Restore-UIState {
    try {
        $p = Get-UIStatePath; if (-not (Test-Path $p)) { return }
        $st = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
        $wa = [System.Windows.SystemParameters]::WorkArea
        if ([double]$st.Width -ge $win.MinWidth -and [double]$st.Height -ge $win.MinHeight) {
            $win.Width  = [Math]::Min([double]$st.Width,  $wa.Width)
            $win.Height = [Math]::Min([double]$st.Height, $wa.Height)
        }
        # Only restore an on-screen position (a saved off-screen spot could hide the window).
        if ($null -ne $st.Left -and $st.Left -ge $wa.Left -and $st.Top -ge $wa.Top -and $st.Left -lt ($wa.Right-80) -and $st.Top -lt ($wa.Bottom-80)) {
            $win.WindowStartupLocation = 'Manual'; $win.Left = [double]$st.Left; $win.Top = [double]$st.Top
        }
        if ($st.Maximized) { $win.WindowState = 'Maximized' }
        if ($st.Profile)    { (C 'W1_Profiles').Text = [string]$st.Profile; $wd = C 'WD_Profiles'; if ($wd) { $wd.Text = [string]$st.Profile } }
        if ($st.DestServer) { (C 'WD_Server').Text = [string]$st.DestServer }
        if ($st.DestShare)  { (C 'WD_Share').Text  = [string]$st.DestShare }
        if ($st.DestDomain) { (C 'WD_Domain').Text = [string]$st.DestDomain }
        if ($st.DestUser)   { (C 'WD_User').Text   = [string]$st.DestUser }
    } catch {}
}

# ----------------------------------------------------------------------------
# Close: clean dismount + remember the session
# ----------------------------------------------------------------------------
$win.Add_Closing({
    # If an async op is still running, stop its timer + pipeline first, so the DispatcherTimer Tick does
    # not fire on a Dispatcher that is shutting down (which would throw) and the worker stops touching
    # $sync.Session before it is dismounted below.
    if ($sync.Busy) {
        try { if ($sync.AsyncTimer) { $sync.AsyncTimer.Stop() } } catch {}
        try { if ($sync.AsyncPS)    { $sync.AsyncPS.Stop() } } catch {}
        $sync.Busy = $false
    }
    Save-UIState   # Closing fires while the window still has its bounds/state
})
$win.Add_Closed({
    if ($sync.Session) { try { Dismount-HYCUADSnapshot -Session $sync.Session } catch {} ; $sync.Session = $null }
    try { Stop-HYCUADMountResidue -Confirm:$false | Out-Null } catch {}   # kill any orphaned dsamain on exit
    if ($sync.HycuSession) { try { Disconnect-HYCUController -Session $sync.HycuSession } catch {} }   # restore TLS validation
})

# About box: product identity + build version (timestamp) + the active log-file path. All text comes
# from the $script:HYCU* constants so there is a single source of truth.
function Show-AboutDialog {
    [xml]$ax = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="About" SizeToContent="Height" Width="500" ResizeMode="NoResize"
        WindowStartupLocation="CenterScreen" Background="#FFF3F2FF">
  <StackPanel Margin="24">
    <Viewbox Height="54" HorizontalAlignment="Left" Margin="0,0,0,14">
      <Canvas Width="1253.98" Height="1080">
        <Path Fill="#FF43128E" Data="F1 M624.09,888.71h133.67c160.41,0,290.59-130.18,290.59-290.59c0-89.5-40.68-169.7-103.45-223.17L738,816.64 L628.74,707.38l51.14-109.26H519.47l-33.71,74.39c-11.62,25.57-17.44,52.31-17.44,75.55C468.33,827.1,527.61,888.71,624.09,888.71 M309.09,705.06l206.9-441.7l109.26,109.26L574.1,481.88h160.41l33.71-74.39c11.62-25.57,17.44-52.31,17.44-75.55c0-79.04-59.28-140.65-155.76-140.65H496.23c-160.41,0-290.59,130.18-290.59,290.59C205.64,571.38,246.32,651.59,309.09,705.06 M1013.15,830.59c-16.05,0-29.06,13.01-29.06,29.06c0,16.05,13.01,29.06,29.06,29.06c16.05,0,29.06-13.01,29.06-29.06C1042.21,843.6,1029.2,830.59,1013.15,830.59z M1013.15,882.9c-12.84,0-23.25-10.41-23.25-23.25c0-12.84,10.41-23.25,23.25-23.25c12.84,0,23.25,10.41,23.25,23.25C1036.39,872.49,1025.99,882.9,1013.15,882.9z M1020.27,861.73c3.38-1.29,5.74-4,5.74-8.14c0-6.14-5.21-9.48-11.43-9.48h-12.33v30.25h7.12v-11.34h4.32l6.23,11.34h7.87L1020.27,861.73z M1013.86,857.99h-4.5v-8.76h4.5c3.02,0,5.07,1.78,5.07,4.45C1018.93,856.39,1016.89,857.99,1013.86,857.99z"/>
      </Canvas>
    </Viewbox>
    <TextBlock x:Name="AB_Name" FontSize="20" FontWeight="Bold" Foreground="#FF1B0C33"/>
    <TextBlock x:Name="AB_Kind" Foreground="#FF5B18C0" Margin="0,2,0,4"/>
    <TextBlock x:Name="AB_Notice" Foreground="#FF697077" FontStyle="Italic" TextWrapping="Wrap" Margin="0,0,0,16"/>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
      <TextBlock Grid.Row="0" Grid.Column="0" Text="Version:" Foreground="#FF697077" Margin="0,0,12,6"/>
      <TextBlock Grid.Row="0" Grid.Column="1" x:Name="AB_Version" Foreground="#FF1B0C33" Margin="0,0,0,6"/>
      <TextBlock Grid.Row="1" Grid.Column="0" Text="Log file:" Foreground="#FF697077" Margin="0,0,12,0" VerticalAlignment="Top"/>
      <TextBox   Grid.Row="1" Grid.Column="1" x:Name="AB_Log" IsReadOnly="True" BorderThickness="0"
                 Background="Transparent" Foreground="#FF1B0C33" TextWrapping="Wrap"/>
    </Grid>
    <Button x:Name="AB_Close" Content="Close" Width="90" Height="30" HorizontalAlignment="Right"
            Margin="0,20,0,0" Background="#FF721EF2" Foreground="White" BorderThickness="0"/>
  </StackPanel>
</Window>
"@
    $w = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $ax))
    $w.FindName('AB_Name').Text    = $script:HYCUProductName
    $w.FindName('AB_Kind').Text    = $script:HYCUProductKind
    $w.FindName('AB_Notice').Text  = $script:HYCUProductNotice
    $w.FindName('AB_Version').Text = $script:HYCUAppVersion
    $w.FindName('AB_Log').Text     = if ($script:HYCULogFile) { $script:HYCULogFile } else { '(file logging unavailable - check folder permissions)' }
    $w.FindName('AB_Close').Add_Click({ $w.Close() }.GetNewClosure())
    if ($win) { try { $w.Owner = $win } catch {} }
    $w.ShowDialog() | Out-Null
}
(C 'BtnAbout').Add_Click({ try { Show-AboutDialog } catch { UILog "About dialog failed: $_" 'ERROR' } })
(C 'BtnViewLog').Add_Click({
    try {
        if ($script:HYCULogFile -and (Test-Path -LiteralPath $script:HYCULogFile)) { Invoke-Item -LiteralPath $script:HYCULogFile }
        else { [System.Windows.MessageBox]::Show('No log file for this run (file logging unavailable - check folder permissions).', 'View log', 'OK', 'Information') | Out-Null }
    } catch { UILog "Could not open the log: $_" 'WARN' }
})

# Prerequisite dialog: lists the missing tools and the exact, copyable install command.
function Show-PrereqInstallDialog([string[]]$Missing, [string]$Command, [string]$Guidance) {
    [xml]$px = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Prerequisites to install" SizeToContent="Height" Width="560"
        WindowStartupLocation="CenterScreen" ResizeMode="NoResize" Background="#FFF3F2FF">
  <StackPanel Margin="16">
    <TextBlock Text="Tools required to mount and restore Active Directory are missing on this machine:"
               Foreground="#FF1B0C33" TextWrapping="Wrap"/>
    <TextBlock x:Name="PD_Missing" Foreground="#FF3D7A70" TextWrapping="Wrap" Margin="0,6,0,0"/>
    <Border x:Name="PD_GuidanceBox" Background="#FFFFFFFF" Padding="10" Margin="0,10,0,0" CornerRadius="4">
      <TextBlock x:Name="PD_Guidance" Foreground="#FF3D7A70" TextWrapping="Wrap"/>
    </Border>
    <TextBlock x:Name="PD_CmdLabel" Text="Run this in an ELEVATED PowerShell to install them:" Foreground="#FF1B0C33" Margin="0,10,0,4"/>
    <TextBox x:Name="PD_Cmd" IsReadOnly="True" TextWrapping="Wrap" FontFamily="Consolas"
             Background="#FFE2E0FD" Foreground="#FF43128E" Padding="6" BorderThickness="0"/>
    <TextBlock Text="(The HYCU file retrieval works without them; only mount / compare / restore need them.)"
               Foreground="#FF697077" TextWrapping="Wrap" Margin="0,8,0,0"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0">
      <Button x:Name="PD_Copy" Content="Copy command" Background="#FF721EF2" Foreground="White" BorderThickness="0" Padding="10,6" Margin="4"/>
      <Button x:Name="PD_Close" Content="Close" Background="#FF5B18C0" Foreground="White" BorderThickness="0" Padding="10,6" Margin="4"/>
    </StackPanel>
  </StackPanel>
</Window>
"@
    $collapsed = [System.Windows.Visibility]::Collapsed
    $w = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $px))
    $w.FindName('PD_Missing').Text = (($Missing | ForEach-Object { "- $_" }) -join "`n")

    # Server-only-tool guidance (e.g. dsamain on a client SKU): show it when present, else hide the box.
    if ($Guidance) { $w.FindName('PD_Guidance').Text = $Guidance }
    else           { $w.FindName('PD_GuidanceBox').Visibility = $collapsed }

    # Only show the command box + Copy button when there is a command that actually helps here.
    if ($Command) {
        $w.FindName('PD_Cmd').Text = $Command
        $copy = $w.FindName('PD_Copy')
        $copy.Add_Click({ try { [System.Windows.Clipboard]::SetText($Command); $copy.Content = 'Copied!' } catch {} }.GetNewClosure())
    } else {
        $w.FindName('PD_CmdLabel').Visibility = $collapsed
        $w.FindName('PD_Cmd').Visibility      = $collapsed
        $w.FindName('PD_Copy').Visibility      = $collapsed
    }
    $w.FindName('PD_Close').Add_Click({ $w.Close() }.GetNewClosure())
    $w.ShowDialog() | Out-Null
}

# ----------------------------------------------------------------------------
# Initialization
# ----------------------------------------------------------------------------
Show-WizStep 1
Load-ProfileList
try { $cfg = Get-HYCUADConfig; if ($cfg.HycuServer) { (C 'W1_Server').Text = $cfg.HycuServer } } catch {}
Restore-UIState   # window size/position + last profile + destination from the previous session

# Silent prerequisite check (native AD DS tools / module / elevation). Quiet when all present;
# only surfaces a warning + an install invitation when something is missing.
$script:Prereq = $null
try { $script:Prereq = Get-HYCUADPrerequisite } catch {}
if ($script:Prereq) {
    if (-not $script:Prereq.Ok) {
        if ($script:Prereq.InstallCommand) {
            UILog ("Missing tools: {0}. Install (elevated): {1}" -f ($script:Prereq.Missing -join '; '), $script:Prereq.InstallCommand) 'WARN'
        } else {
            UILog ("Missing tools: {0}." -f ($script:Prereq.Missing -join '; ')) 'WARN'
        }
        if ($script:Prereq.Guidance) { UILog $script:Prereq.Guidance 'WARN' }
    }
    if (-not $script:Prereq.IsAdmin) { UILog "Not running as administrator - mounting (dsamain) and AD writes may fail. Relaunch elevated." 'WARN' }
}

UILog "$script:HYCUProductName ($script:HYCUProductKind) - version $script:HYCUAppVersion started." 'INFO'
UILog "Ready. Follow the 7 wizard steps."
UILog "Tip: keep 'Simulation mode' enabled for a safe first pass."

# HYCU_GUI_NOSHOW=1 loads the interface without showing it (headless validation/CI).
if (-not $env:HYCU_GUI_NOSHOW) {
    try {
        # The prereq dialog runs only when tools are missing (i.e. on a client, never on a healthy
        # server). Isolate it so a failure here can NEVER stop the main window from appearing - the
        # missing tools are already listed in the log above.
        if ($script:Prereq -and -not $script:Prereq.Ok) {
            try { Show-PrereqInstallDialog $script:Prereq.Missing $script:Prereq.InstallCommand $script:Prereq.Guidance }
            catch { try { Write-HYCULog "Could not show the prerequisites dialog: $_" 'WARN' } catch {} }
        }
        $win.ShowDialog() | Out-Null
    } catch {
        # Never fail silently ("nothing happens"): record and surface why the window did not appear.
        $msg = "The HYCU AD Recovery window could not be displayed: $($_.Exception.Message)"
        try { Write-HYCULog $msg 'ERROR' } catch {}
        Write-Host $msg -ForegroundColor Red
        try { [System.Windows.MessageBox]::Show($msg, 'HYCU AD Recovery - startup error', 'OK', 'Error') | Out-Null } catch {}
    }
} else {
    Write-Host "VALIDATION OK: window built ($($win.GetType().Name)), current step = $script:WizCurrent, controls resolved."
}
