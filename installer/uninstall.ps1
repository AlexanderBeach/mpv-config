<#
.SYNOPSIS
    Removes what the mpv config setup installed: just the config (mpv stays), or mpv and
    everything that came with it. Double-click Uninstall.cmd next to mpv.exe.

.DESCRIPTION
    Uses the record the setup kept in %LOCALAPPDATA%\mpv\install-manifest.json.
      Config only:  removes the config (and the yt-dlp inside it), puts back the config you had
                    before (if the setup backed one up), and the subtitle fonts it installed.
      Everything:   also unregisters mpv, removes its shortcuts and the "Play with mpv" folder
                    menu, and deletes the mpv folder.
    Backups of earlier configs are never deleted. Administrator rights are only requested when
    mpv lives in a protected folder such as Program Files.

.PARAMETER Silent
    Uninstall without the window, using the options below (default: config only).
.PARAMETER Everything
    Remove mpv and everything with it, not just the config.
.PARAMETER KeepFonts
    Keep the subtitle fonts the setup installed.
.PARAMETER DeleteSavedData
    Also delete what mpv remembers: resume positions, volume and the subtitle style (and, with -Everything, mpv's cache).
#>
[CmdletBinding()]
param(
    [switch]$Silent,
    [switch]$Everything,
    [switch]$KeepFonts,
    [switch]$DeleteSavedData,
    # Internal: the copy in the temp folder that does the work, so the mpv folder can be deleted.
    [string]$MpvDir
)

$ErrorActionPreference = 'Stop'
$StateDir = Join-Path $env:LOCALAPPDATA 'mpv'
$ManifestPath = Join-Path $StateDir 'install-manifest.json'
$SavedData = 'resume-prompt.json', 'saved-state.json', 'sub-style.json', 'updater-last-check', 'ytdlp-last-update'

# Work from a copy in the temp folder: this script lives in the folder it may delete.
if (-not $MpvDir) {
    $copy = Join-Path ([IO.Path]::GetTempPath()) ('mpv-uninstall-' + [guid]::NewGuid().ToString('N') + '.ps1')
    Copy-Item -LiteralPath $PSCommandPath -Destination $copy
    $relaunch = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', "`"$copy`"", '-MpvDir', "`"$PSScriptRoot`"")
    if ($Silent) { $relaunch += '-Silent' }
    if ($Everything) { $relaunch += '-Everything' }
    if ($KeepFonts) { $relaunch += '-KeepFonts' }
    if ($DeleteSavedData) { $relaunch += '-DeleteSavedData' }
    if ($Silent) {
        $p = Start-Process powershell.exe -ArgumentList $relaunch -NoNewWindow -PassThru -Wait
        exit $p.ExitCode
    }
    Start-Process powershell.exe -ArgumentList $relaunch -WindowStyle Hidden
    exit 0
}

$script:LogSink = $null
function Write-Log([string]$Text) {
    if ($null -ne $script:LogSink) { $script:LogSink.AppendText($Text + "`r`n") } else { Write-Host $Text }
}

function Test-Writable([string]$Dir) {
    try {
        $probe = Join-Path $Dir ('.write-test-' + [guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($probe, '')
        Remove-Item -LiteralPath $probe -Force
        return $true
    } catch { return $false }
}

# -EncodedCommand needs no quoting, so paths with spaces or quotes are safe.
function Invoke-AsAdmin([string]$Command) {
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Command))
    $p = Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -PassThru -Wait -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded)
    if ($p.ExitCode -ne 0) { throw "the administrator step failed (exit code $($p.ExitCode))" }
}

function Remove-Path([string]$Path) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return }
    if (Test-Writable (Split-Path $Path)) { Remove-Item -LiteralPath $Path -Recurse -Force }
    else {
        Write-Log '  (protected folder: Windows asks for permission)'
        Invoke-AsAdmin "Remove-Item -LiteralPath '$($Path -replace "'", "''")' -Recurse -Force"
    }
}

Add-Type -Namespace MpvSetup -Name Fonts -MemberDefinition @'
[DllImport("gdi32.dll", CharSet = CharSet.Unicode)] public static extern bool RemoveFontResource(string file);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam, uint flags, uint timeout, out IntPtr result);
[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
'@

function Read-Manifest {
    $m = $null
    if (Test-Path -LiteralPath $ManifestPath) { $m = Get-Content -Raw -LiteralPath $ManifestPath | ConvertFrom-Json }
    $config = if ($m -and $m.ConfigDir) { $m.ConfigDir }
              elseif (Test-Path -LiteralPath (Join-Path $MpvDir 'portable_config')) { Join-Path $MpvDir 'portable_config' }
              else { Join-Path $env:APPDATA 'mpv' }
    return @{
        ConfigDir = $config; BackupDir = $(if ($m) { $m.BackupDir }); Fonts = @($(if ($m -and $m.Fonts) { $m.Fonts }))
        Shortcuts = @($(if ($m -and $m.Shortcuts) { $m.Shortcuts })); FolderMenu = [bool]($m -and $m.FolderMenu)
    }
}

function Invoke-Uninstall([hashtable]$Info, [bool]$All, [bool]$Fonts, [bool]$Data) {
    try {
        if (Get-Process mpv -ErrorAction SilentlyContinue) { throw 'mpv is running. Close it and try again.' }
        $exe = Join-Path $MpvDir 'mpv.exe'

        if (Test-Path -LiteralPath $Info.ConfigDir) {
            Write-Log "Removing the config: $($Info.ConfigDir)"
            Remove-Path $Info.ConfigDir
        }
        if ($Info.BackupDir -and (Test-Path -LiteralPath $Info.BackupDir)) {
            if ($All) { Write-Log "Your earlier config is kept in $($Info.BackupDir)" }
            else {
                Write-Log "Putting back your earlier config from $($Info.BackupDir)"
                Move-Item -LiteralPath $Info.BackupDir -Destination $Info.ConfigDir
            }
        }

        if ($Fonts -and $Info.Fonts.Count) {
            Write-Log 'Removing the subtitle fonts the setup installed'
            foreach ($f in $Info.Fonts) {
                while ([MpvSetup.Fonts]::RemoveFontResource($f.File)) { }
                Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts' -Name $f.Value -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $f.File -Force -ErrorAction SilentlyContinue
            }
            $r = [IntPtr]::Zero
            [void][MpvSetup.Fonts]::SendMessageTimeout([IntPtr]0xffff, 0x001D, [IntPtr]::Zero, [IntPtr]::Zero, 2, 1000, [ref]$r)
        }

        if ($All) {
            # Only when Windows' registration is this mpv's (another mpv may be registered instead).
            $registered = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\mpv' -ErrorAction SilentlyContinue).InstallLocation
            if ((Test-Path -LiteralPath $exe) -and $registered -and
                (Resolve-Path -LiteralPath $registered -ErrorAction SilentlyContinue).Path -eq (Resolve-Path -LiteralPath $MpvDir).Path) {
                Write-Log 'Removing mpv from Windows (file types, Default apps, Installed apps)'
                & (Join-Path $MpvDir 'mpv.com') --no-config --unregister | Out-Null
            }
            $links = @($Info.Shortcuts) + @(
                (Join-Path ([Environment]::GetFolderPath('Programs')) 'mpv.lnk'),
                (Join-Path ([Environment]::GetFolderPath('Desktop')) 'mpv.lnk'))
            foreach ($link in $links | Select-Object -Unique) {
                if (-not (Test-Path -LiteralPath $link)) { continue }
                $target = (New-Object -ComObject WScript.Shell).CreateShortcut($link).TargetPath
                if ($Info.Shortcuts -contains $link -or $target -eq $exe) { Write-Log "Removing the shortcut $link"; Remove-Item -LiteralPath $link -Force }
            }
            if (Test-Path 'HKCU:\Software\Classes\Directory\shell\mpv.play') {
                Write-Log 'Removing "Play with mpv" from the folder menu'
                Remove-Item -Path 'HKCU:\Software\Classes\Directory\shell\mpv.play' -Recurse -Force
            }
            Write-Log "Deleting mpv: $MpvDir"
            Remove-Path $MpvDir
            if ($Data) { Write-Log "Deleting mpv's saved data and cache: $StateDir"; Remove-Path $StateDir }
        } else {
            if ($Data) {
                Write-Log 'Deleting the saved resume positions, volume and subtitle style'
                foreach ($f in $SavedData) { Remove-Item -LiteralPath (Join-Path $StateDir $f) -Force -ErrorAction SilentlyContinue }
            }
            Write-Log 'Removing the uninstaller (mpv stays)'
            foreach ($f in 'Uninstall.cmd', 'uninstall.ps1') { Remove-Path (Join-Path $MpvDir $f) }
        }
        Remove-Item -LiteralPath $ManifestPath -Force -ErrorAction SilentlyContinue
        Write-Log 'Done.'
        return $true
    } catch {
        Write-Log "Stopped: $($_.Exception.Message)"
        return $false
    } finally {
        if ($PSCommandPath -like "$([IO.Path]::GetTempPath())*") { Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue }
    }
}

$info = Read-Manifest

if ($Silent) {
    $ok = Invoke-Uninstall $info $Everything.IsPresent (-not $KeepFonts) $DeleteSavedData.IsPresent
    exit $(if ($ok) { 0 } else { 1 })
}

# The window: the same look as the setup window.
$ThemeXaml = @'
  <SolidColorBrush x:Key="Surface" Color="#1A1A1A"/>
  <SolidColorBrush x:Key="Card" Color="#202020"/>
  <SolidColorBrush x:Key="Stroke" Color="#2E2E2E"/>
  <SolidColorBrush x:Key="Line" Color="#2A2A2A"/>
  <SolidColorBrush x:Key="Text" Color="#EDEDED"/>
  <SolidColorBrush x:Key="Dim" Color="#A3A3A3"/>
  <SolidColorBrush x:Key="Accent" Color="#9CC9FF"/>
  <SolidColorBrush x:Key="AccentHover" Color="#B5D7FF"/>
  <SolidColorBrush x:Key="AccentPressed" Color="#86B8F0"/>
  <SolidColorBrush x:Key="SelBg" Color="#1E2733"/>
  <SolidColorBrush x:Key="OnAccent" Color="#141414"/>
  <SolidColorBrush x:Key="Good" Color="#4CD485"/>
  <SolidColorBrush x:Key="Bad" Color="#FF5416"/>
  <FontFamily x:Key="Icons">Segoe Fluent Icons, Segoe MDL2 Assets</FontFamily>
  <FontFamily x:Key="Display">Segoe UI Variable Display, Segoe UI</FontFamily>

  <DrawingImage x:Key="AppIcon">
    <DrawingImage.Drawing>
      <DrawingGroup>
        <GeometryDrawing Brush="#9CC9FF" Geometry="M7,0 H25 A7,7 0 0 1 32,7 V25 A7,7 0 0 1 25,32 H7 A7,7 0 0 1 0,25 V7 A7,7 0 0 1 7,0 Z"/>
        <GeometryDrawing Brush="#141414" Geometry="M12.5,9.5 L22.5,16 L12.5,22.5 Z"/>
      </DrawingGroup>
    </DrawingImage.Drawing>
  </DrawingImage>

  <Style x:Key="Glyph" TargetType="TextBlock">
    <Setter Property="FontFamily" Value="{StaticResource Icons}"/>
    <Setter Property="FontSize" Value="17"/>
    <Setter Property="VerticalAlignment" Value="Center"/>
  </Style>
  <Style x:Key="Note" TargetType="TextBlock">
    <Setter Property="Foreground" Value="{StaticResource Dim}"/>
    <Setter Property="FontSize" Value="12.5"/>
    <Setter Property="TextWrapping" Value="Wrap"/>
  </Style>
  <!-- One framed list holding several rows, split by thin lines -->
  <Style x:Key="Group" TargetType="Border">
    <Setter Property="Background" Value="{StaticResource Card}"/>
    <Setter Property="BorderBrush" Value="{StaticResource Stroke}"/>
    <Setter Property="BorderThickness" Value="1"/>
    <Setter Property="CornerRadius" Value="8"/>
  </Style>
  <Style x:Key="Divider" TargetType="Border">
    <Setter Property="Height" Value="1"/>
    <Setter Property="Background" Value="{StaticResource Line}"/>
  </Style>

  <Style x:Key="ButtonBase" TargetType="Button">
    <Setter Property="Height" Value="34"/>
    <Setter Property="MinWidth" Value="100"/>
    <Setter Property="Padding" Value="16,0"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="Foreground" Value="{StaticResource Text}"/>
    <Setter Property="Background" Value="#222222"/>
    <Setter Property="BorderBrush" Value="#3C3C3C"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="6" Padding="{TemplateBinding Padding}">
            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource Text}"/></Trigger>
            <Trigger Property="IsEnabled" Value="False">
              <Setter TargetName="Bd" Property="Background" Value="#1C1C1C"/>
              <Setter TargetName="Bd" Property="BorderBrush" Value="#282828"/>
              <Setter Property="Foreground" Value="#626262"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
    <Style.Triggers>
      <Trigger Property="IsMouseOver" Value="True"><Setter Property="BorderBrush" Value="{StaticResource Accent}"/></Trigger>
      <Trigger Property="IsPressed" Value="True"><Setter Property="Background" Value="{StaticResource SelBg}"/></Trigger>
    </Style.Triggers>
  </Style>
  <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource ButtonBase}">
    <Setter Property="Foreground" Value="{StaticResource OnAccent}"/>
    <Setter Property="Background" Value="{StaticResource Accent}"/>
    <Setter Property="BorderBrush" Value="{StaticResource Accent}"/>
    <Setter Property="FontWeight" Value="SemiBold"/>
    <Style.Triggers>
      <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="{StaticResource AccentHover}"/><Setter Property="BorderBrush" Value="{StaticResource AccentHover}"/></Trigger>
      <Trigger Property="IsPressed" Value="True"><Setter Property="Background" Value="{StaticResource AccentPressed}"/></Trigger>
    </Style.Triggers>
  </Style>
  <Style x:Key="Danger" TargetType="Button" BasedOn="{StaticResource Primary}">
    <Setter Property="Background" Value="{StaticResource Bad}"/>
    <Setter Property="BorderBrush" Value="{StaticResource Bad}"/>
    <Style.Triggers>
      <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#FF7442"/><Setter Property="BorderBrush" Value="#FF7442"/></Trigger>
    </Style.Triggers>
  </Style>
  <Style x:Key="Subtle" TargetType="Button" BasedOn="{StaticResource ButtonBase}">
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="BorderBrush" Value="Transparent"/>
    <Setter Property="MinWidth" Value="0"/>
    <Setter Property="Foreground" Value="{StaticResource Dim}"/>
  </Style>

  <Style x:Key="Check" TargetType="CheckBox">
    <Setter Property="Foreground" Value="{StaticResource Text}"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="CheckBox">
          <StackPanel Orientation="Horizontal" Background="Transparent">
            <Border x:Name="Box" Width="19" Height="19" CornerRadius="4" BorderThickness="1" BorderBrush="#8C8C8C" Background="#1A1A1A">
              <TextBlock x:Name="Mark" Text="&#xE73E;" FontFamily="{StaticResource Icons}" FontSize="11" Foreground="{StaticResource OnAccent}"
                         HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed"/>
            </Border>
            <ContentPresenter Margin="9,0,0,0" VerticalAlignment="Center"/>
          </StackPanel>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Box" Property="BorderBrush" Value="{StaticResource Text}"/></Trigger>
            <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Box" Property="BorderBrush" Value="{StaticResource Accent}"/></Trigger>
            <Trigger Property="IsChecked" Value="True">
              <Setter TargetName="Box" Property="Background" Value="{StaticResource Accent}"/>
              <Setter TargetName="Box" Property="BorderBrush" Value="{StaticResource Accent}"/>
              <Setter TargetName="Mark" Property="Visibility" Value="Visible"/>
            </Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <Style x:Key="RadioRow" TargetType="RadioButton">
    <Setter Property="Foreground" Value="{StaticResource Text}"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="RadioButton">
          <Border Background="Transparent" Padding="16,12">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition/></Grid.ColumnDefinitions>
              <Grid Width="19" Height="19" VerticalAlignment="Top" Margin="0,1,12,0">
                <Ellipse x:Name="Ring" Stroke="#8C8C8C" StrokeThickness="1" Fill="#1A1A1A"/>
                <Ellipse x:Name="Dot" Width="8" Height="8" Fill="{StaticResource OnAccent}" Visibility="Collapsed"/>
              </Grid>
              <ContentPresenter Grid.Column="1"/>
            </Grid>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Ring" Property="Stroke" Value="{StaticResource Text}"/></Trigger>
            <Trigger Property="IsChecked" Value="True">
              <Setter TargetName="Ring" Property="Fill" Value="{StaticResource Accent}"/>
              <Setter TargetName="Ring" Property="Stroke" Value="{StaticResource Accent}"/>
              <Setter TargetName="Dot" Property="Visibility" Value="Visible"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
'@

$UninstallXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Uninstall mpv config" Width="640" Height="580" ResizeMode="CanMinimize" WindowStartupLocation="CenterScreen"
        Background="#141414" Foreground="#EDEDED" FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="14"
        UseLayoutRounding="True" SnapsToDevicePixels="True" TextOptions.TextFormattingMode="Display">
  <Window.Resources>THEME</Window.Resources>
  <Border Margin="12" Background="{StaticResource Surface}" BorderBrush="#242424" BorderThickness="1" CornerRadius="12">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>
      <StackPanel Orientation="Horizontal" Margin="28,22,28,16">
        <Image x:Name="TitleImage" Source="{StaticResource AppIcon}" Width="32" Height="32" VerticalAlignment="Center" Margin="0,0,14,0"/>
        <TextBlock x:Name="TitleIcon" Style="{StaticResource Glyph}" FontSize="24" Margin="0,2,12,0" Visibility="Collapsed"/>
        <StackPanel>
          <TextBlock x:Name="PageTitle" Text="Uninstall" FontFamily="{StaticResource Display}" FontSize="24" FontWeight="SemiBold"/>
          <TextBlock x:Name="PageSubtitle" Text="Choose what to remove" Foreground="{StaticResource Dim}"/>
        </StackPanel>
      </StackPanel>
      <Border Grid.Row="1" Style="{StaticResource Divider}"/>
      <Grid Grid.Row="2" Margin="28,20,28,0">
        <StackPanel x:Name="Choices">
          <Border Style="{StaticResource Group}" Margin="0,0,0,18">
            <StackPanel>
              <RadioButton x:Name="RbConfig" GroupName="What" Style="{StaticResource RadioRow}" IsChecked="True" AutomationProperties.Name="Remove just this config">
                <StackPanel><TextBlock Text="Remove just this config" FontWeight="SemiBold"/><TextBlock Text="mpv stays" Style="{StaticResource Note}" Foreground="{StaticResource Accent}"/>
                  <TextBlock x:Name="ConfigNote" Style="{StaticResource Note}" Margin="0,2,0,0"/></StackPanel>
              </RadioButton>
              <Border Style="{StaticResource Divider}"/>
              <RadioButton x:Name="RbAll" GroupName="What" Style="{StaticResource RadioRow}" AutomationProperties.Name="Remove mpv and everything with it">
                <StackPanel><TextBlock Text="Remove mpv and everything with it" FontWeight="SemiBold"/>
                  <TextBlock x:Name="AllNote" Style="{StaticResource Note}" Margin="0,2,0,0"/></StackPanel>
              </RadioButton>
            </StackPanel>
          </Border>
          <CheckBox x:Name="CbFonts" Style="{StaticResource Check}" Content="Also remove the subtitle fonts the setup installed" IsChecked="True" Margin="2,0,0,12"/>
          <CheckBox x:Name="CbData" Style="{StaticResource Check}" Content="Also delete saved resume positions, volume and subtitle style" Margin="2,0,0,0"/>
        </StackPanel>
        <Border x:Name="LogCard" Style="{StaticResource Group}" Padding="14,10" Visibility="Collapsed">
          <TextBox x:Name="Log" IsReadOnly="True" Background="Transparent" BorderThickness="0" Foreground="#C8C8C8" TextWrapping="Wrap"
                   FontFamily="Cascadia Mono, Consolas" FontSize="12" VerticalScrollBarVisibility="Hidden" AutomationProperties.Name="Uninstall log"/>
        </Border>
      </Grid>
      <Border x:Name="Problem" Grid.Row="3" Margin="28,12,28,0" Padding="14,10" CornerRadius="8" Background="#2E1A14" BorderBrush="#5A2A1A" BorderThickness="1" Visibility="Collapsed">
        <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition/></Grid.ColumnDefinitions>
          <TextBlock Style="{StaticResource Glyph}" Text="&#xE7BA;" FontSize="16" Foreground="{StaticResource Bad}" Margin="0,0,10,0"/>
          <TextBlock x:Name="ProblemText" Grid.Column="1" TextWrapping="Wrap" VerticalAlignment="Center"/>
        </Grid>
      </Border>
      <Border Grid.Row="4" Style="{StaticResource Divider}" Margin="0,16,0,0"/>
      <Grid Grid.Row="5" Margin="20,12,20,14">
        <Button x:Name="BtnCancel" Content="Cancel" Style="{StaticResource Subtle}" HorizontalAlignment="Left"/>
        <Button x:Name="BtnGo" Content="Uninstall" Style="{StaticResource Primary}" HorizontalAlignment="Right" IsDefault="True"/>
      </Grid>
    </Grid>
  </Border>
</Window>
'@

[void][MpvSetup.Fonts]::SetProcessDPIAware()   # sharp text on scaled displays
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$window = [Windows.Markup.XamlReader]::Parse($UninstallXaml.Replace('THEME', $ThemeXaml))
$window.Icon = $window.FindResource('AppIcon')
$window.Add_SourceInitialized({
    $hwnd = (New-Object Windows.Interop.WindowInteropHelper $window).Handle
    $on = 1; [void][MpvSetup.Fonts]::DwmSetWindowAttribute($hwnd, 20, [ref]$on, 4)                  # dark title bar
    $color = 0x00141414; [void][MpvSetup.Fonts]::DwmSetWindowAttribute($hwnd, 35, [ref]$color, 4)   # same color as the window (Windows 11)
})
$ui = @{}
foreach ($name in 'TitleImage', 'TitleIcon', 'PageTitle', 'PageSubtitle', 'Choices', 'RbConfig', 'RbAll', 'ConfigNote', 'AllNote', 'CbFonts', 'CbData',
                  'LogCard', 'Log', 'Problem', 'ProblemText', 'BtnCancel', 'BtnGo') { $ui[$name] = $window.FindName($name) }

$restore = $info.BackupDir -and (Test-Path -LiteralPath $info.BackupDir)
$ui.ConfigNote.Text = "Removes $($info.ConfigDir)" + $(if ($restore) { ' and puts back the config you had before.' } else { '.' })
$ui.AllNote.Text = "Also deletes $MpvDir, and removes mpv's shortcuts, file types and folder menu."
if (-not $info.Fonts.Count) { $ui.CbFonts.IsChecked = $false; $ui.CbFonts.Visibility = 'Collapsed' }
$state = @{ Confirmed = $false; Done = $false }

$update = {
    $ui.CbData.Content = if ($ui.RbAll.IsChecked) { "Also delete mpv's saved data and cache" } else { 'Also delete saved resume positions, volume and subtitle style' }
    $ui.BtnGo.Content = if ($ui.RbAll.IsChecked) { 'Remove everything' } else { 'Uninstall' }
    $ui.BtnGo.Style = $window.FindResource($(if ($ui.RbAll.IsChecked) { 'Danger' } else { 'Primary' }))
    $state.Confirmed = $false; $ui.Problem.Visibility = 'Collapsed'
}
$ui.RbConfig.Add_Checked($update); $ui.RbAll.Add_Checked($update)

# Log lines go into the window; the dispatcher call lets it redraw between steps.
$script:LogSink = New-Object PSObject | Add-Member -MemberType ScriptMethod -Name AppendText -PassThru -Value {
    param($text)
    $ui.Log.AppendText($text); $ui.Log.ScrollToEnd()
    $window.Dispatcher.Invoke([Action]{ }, [Windows.Threading.DispatcherPriority]::Background)
}

$ui.BtnGo.Add_Click({
    if ($state.Done) { $window.Close(); return }
    if ($ui.RbAll.IsChecked -and -not $state.Confirmed) {
        $ui.ProblemText.Text = "This deletes $MpvDir and everything in it. Click Remove everything again to go ahead."
        $ui.Problem.Visibility = 'Visible'; $state.Confirmed = $true; return
    }
    $ui.Problem.Visibility = 'Collapsed'
    $ui.Choices.Visibility = 'Collapsed'; $ui.LogCard.Visibility = 'Visible'
    $ui.BtnGo.IsEnabled = $false; $ui.BtnCancel.Visibility = 'Hidden'
    $ui.PageTitle.Text = 'Removing'; $ui.PageSubtitle.Text = 'One moment'
    $ok = Invoke-Uninstall $info ([bool]$ui.RbAll.IsChecked) ([bool]$ui.CbFonts.IsChecked) ([bool]$ui.CbData.IsChecked)
    $state.Done = $true
    $ui.TitleImage.Visibility = 'Collapsed'; $ui.TitleIcon.Visibility = 'Visible'
    $ui.TitleIcon.Text = [string][char]$(if ($ok) { 0xE930 } else { 0xE783 })
    $ui.TitleIcon.Foreground = $window.FindResource($(if ($ok) { 'Good' } else { 'Bad' }))
    $ui.PageTitle.Text = if ($ok) { 'Uninstalled' } else { 'Uninstall stopped' }
    $ui.PageSubtitle.Text = if ($ok) { 'Everything you chose was removed' } else { 'See the log for what happened' }
    $ui.BtnGo.Style = $window.FindResource('Primary'); $ui.BtnGo.Content = 'Close'; $ui.BtnGo.IsEnabled = $true
})
$ui.BtnCancel.Add_Click({ $window.Close() })
[void]$window.ShowDialog()
