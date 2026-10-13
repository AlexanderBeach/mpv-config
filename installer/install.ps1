<#
.SYNOPSIS
    Sets up this mpv config on Windows. Double-click Install.cmd for the setup window, or run this
    script with -Silent and the options below.

.DESCRIPTION
    The setup window, or -Silent:
      - moves an existing mpv config to a backup folder next to it, and installs this one,
      - applies your choices (quality preset, languages, subtitle font, which features to include),
      - optionally installs mpv, the subtitle font, yt-dlp for web videos, shortcuts, a "Play with
        mpv" folder menu, and registers mpv as a media player,
      - puts an uninstaller (Uninstall.cmd) next to mpv.exe.
    Everything is for the current Windows user. Administrator rights are only requested when mpv
    lives in a protected folder such as Program Files.

.PARAMETER Silent
    Install without the setup window, using the options below. Defaults: preset high, English
    subtitles, every feature, update check on, nothing optional.
.PARAMETER MpvDir
    Folder that contains mpv.exe, or where to install it with -InstallMpv.
    Default: the mpv that is found, or %LOCALAPPDATA%\Programs\mpv.
.PARAMETER InstallMpv
    Download and install the latest mpv build if mpv isn't found.
.PARAMETER MpvArchive
    Install mpv from a build archive (.7z) you already have instead of downloading one.
.PARAMETER Preset
    Picture quality: ultra, high (default) or light.
.PARAMETER SubtitleLanguages
    Preferred subtitle languages, e.g. "eng,en" (default) or "deu,de". Empty for none.
.PARAMETER AudioLanguages
    Preferred audio languages, e.g. "jpn,ja". Empty (default): the file's default track.
.PARAMETER Without
    Features to leave out: thumbnails, effects, resume, modernz.
.PARAMETER SubtitleFont
    firago (default), atkinson, segoe, calibri, verdana or arial.
.PARAMETER Fonts
    Download and install the subtitle font if Windows doesn't have it (FiraGO, Atkinson Hyperlegible).
.PARAMETER DefaultPlayer
    Register mpv as a media player for your Windows user (then pick it under Default apps).
.PARAMETER StartMenuShortcut
    Add a Start menu shortcut to mpv.
.PARAMETER DesktopShortcut
    Add a desktop shortcut to mpv.
.PARAMETER FolderMenu
    Add "Play with mpv" to the right-click menu of folders.
.PARAMETER WebVideos
    Download yt-dlp into the config folder, so links from YouTube and other sites play.
.PARAMETER NoUpdateCheck
    Don't check for mpv updates once a day.

.EXAMPLE
    .\install.ps1 -Silent -InstallMpv -Fonts -WebVideos -StartMenuShortcut -Preset ultra
#>
[CmdletBinding()]
param(
    [switch]$Silent,
    [string]$MpvDir,
    [switch]$InstallMpv,
    [string]$MpvArchive,
    [ValidateSet('ultra', 'high', 'light')][string]$Preset = 'high',
    [string]$SubtitleLanguages = 'eng,en',
    [string]$AudioLanguages = '',
    [ValidateSet('thumbnails', 'effects', 'resume', 'modernz')][string[]]$Without = @(),
    [ValidateSet('firago', 'atkinson', 'segoe', 'calibri', 'verdana', 'arial')][string]$SubtitleFont = 'firago',
    [switch]$Fonts,
    [switch]$DefaultPlayer,
    [switch]$StartMenuShortcut,
    [switch]$DesktopShortcut,
    [switch]$FolderMenu,
    [switch]$WebVideos,
    [switch]$NoUpdateCheck
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$RepoConfig = Join-Path (Split-Path $PSScriptRoot) 'config'
$ManifestPath = Join-Path $env:LOCALAPPDATA 'mpv\install-manifest.json'
$DefaultMpvDir = Join-Path $env:LOCALAPPDATA 'Programs\mpv'
$FontsKey = 'Software\Microsoft\Windows NT\CurrentVersion\Fonts'
$UserAgent = 'mpv-config-installer'

# Subtitle font choices. Size is set per font so each comes out about as wide as the others; the
# fonts Windows doesn't include (both SIL Open Font License) are downloaded from their published files.
$SubtitleFonts = [ordered]@{
    firago   = @{ Name = 'FiraGO Book'; Label = 'FiraGO'; Size = 37; Files = @(
        @{ Name = 'FiraGO-Book.ttf'; Value = 'FiraGO Book (TrueType)'
           Url = 'https://raw.githubusercontent.com/bBoxType/FiraGO/master/Fonts/FiraGO_TTF_1001/Roman/FiraGO-Book.ttf'
           Sha256 = '4c132d5290477709da7fee51f2494d9d13157024e5011d665ebe73489416f894' },
        @{ Name = 'FiraGO-BookItalic.ttf'; Value = 'FiraGO Book Italic (TrueType)'
           Url = 'https://raw.githubusercontent.com/bBoxType/FiraGO/master/Fonts/FiraGO_TTF_1001/Italic/FiraGO-BookItalic.ttf'
           Sha256 = 'd1acf0bfba04de8a35888f402bbe029b3c412b2a52ea4da27bf498bc5973fc05' }) }
    atkinson = @{ Name = 'Atkinson Hyperlegible'; Label = 'Atkinson Hyperlegible'; Size = 39; Files = @(
        @{ Name = 'AtkinsonHyperlegible-Regular.ttf'; Value = 'Atkinson Hyperlegible Regular (TrueType)'
           Url = 'https://raw.githubusercontent.com/google/fonts/1b22086d13bdbbf5ec63d01a39a49246e4ac355f/ofl/atkinsonhyperlegible/AtkinsonHyperlegible-Regular.ttf'
           Sha256 = '7fb917c89019896d0b52ee84b7cbb3304c18cb90b19a62f5e32712bd23e97669' },
        @{ Name = 'AtkinsonHyperlegible-Italic.ttf'; Value = 'Atkinson Hyperlegible Italic (TrueType)'
           Url = 'https://raw.githubusercontent.com/google/fonts/1b22086d13bdbbf5ec63d01a39a49246e4ac355f/ofl/atkinsonhyperlegible/AtkinsonHyperlegible-Italic.ttf'
           Sha256 = '021beda4d3c6edfc78872e436d74009f9a1bcb294331908fe5747c61d3dcc514' }) }
    segoe    = @{ Name = 'Segoe UI'; Label = 'Segoe UI'; Size = 41; Files = @() }
    calibri  = @{ Name = 'Calibri'; Label = 'Calibri'; Size = 41; Files = @() }
    verdana  = @{ Name = 'Verdana'; Label = 'Verdana'; Size = 33; Files = @() }
    arial    = @{ Name = 'Arial'; Label = 'Arial'; Size = 34; Files = @() }
}

# Files left out per feature (paths inside config\). Leaving out ModernZ also leaves out the
# thumbnails, which mpv's built-in controller can't show.
$FeatureFiles = @{
    thumbnails = @('scripts\thumbfast.lua', 'script-opts\thumbfast.conf')
    effects    = @('scripts\video-effects', 'script-opts\video_effects.conf')
    resume     = @('scripts\resume-prompt.lua')
    modernz    = @('scripts\modernz.lua', 'script-opts\modernz.conf', 'fonts\modernz-icons.ttf')
}

#region Helpers -----------------------------------------------------------------------------------

# Where log lines go: the console when silent, the setup window's log otherwise.
$script:LogSink = $null
function Write-Log([string]$Text) {
    if ($null -ne $script:LogSink) { [void]$script:LogSink.Add($Text) } else { Write-Host $Text }   # (an empty list counts as false)
}

function Find-Mpv {
    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($key in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\mpv',
                     'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\mpv') {
        $location = (Get-ItemProperty $key -ErrorAction SilentlyContinue).InstallLocation
        if ($location) { $candidates.Add($location) }
    }
    $onPath = Get-Command mpv.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($onPath) { $candidates.Add((Split-Path $onPath.Source)) }
    $candidates.Add($DefaultMpvDir)
    $candidates.Add((Join-Path $env:ProgramFiles 'mpv'))
    $candidates.Add((Join-Path $env:USERPROFILE 'scoop\apps\mpv\current'))
    foreach ($dir in $candidates) {
        if ($dir -and (Test-Path -LiteralPath (Join-Path $dir 'mpv.exe'))) { return (Resolve-Path -LiteralPath $dir).Path }
    }
    return $null
}

function Get-MpvVersion([string]$Dir) {
    $exe = Join-Path $Dir 'mpv.com'
    if (-not (Test-Path -LiteralPath $exe)) { return '' }
    $line = (& $exe --no-config --version 2>$null | Select-Object -First 1)
    return ($line -replace '\s+Copyright.*$', '').Trim()
}

# mpv uses portable_config next to mpv.exe instead of %APPDATA%\mpv when that folder exists.
function Get-ConfigDir([string]$Mpv) {
    if ($Mpv -and (Test-Path -LiteralPath (Join-Path $Mpv 'portable_config'))) { return (Join-Path $Mpv 'portable_config') }
    return (Join-Path $env:APPDATA 'mpv')
}

function Test-FontInstalled([string]$FontName) {
    foreach ($root in 'HKLM:', 'HKCU:') {
        $names = (Get-Item "$root\$FontsKey" -ErrorAction SilentlyContinue).GetValueNames()
        if ($names | Where-Object { $_ -like "$FontName (*" -or $_ -like "$FontName Regular (*" }) { return $true }
    }
    return $false
}

function Test-Writable([string]$Dir) {
    try {
        $probe = Join-Path $Dir ('.write-test-' + [guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($probe, '')
        Remove-Item -LiteralPath $probe -Force
        return $true
    } catch { return $false }
}

function Test-Languages([string]$List) {
    return ($List -eq '' -or $List -match '^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})?(,[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})?)*$')
}

function Get-File([string]$Url, [string]$OutFile) {
    Invoke-WebRequest $Url -OutFile $OutFile -UserAgent $UserAgent -UseBasicParsing
}

function Quote([string]$Text) { "'" + ($Text -replace "'", "''") + "'" }

# A PowerShell command line for -EncodedCommand, which needs no quoting at all.
function ConvertTo-Encoded([string]$Command) { [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Command)) }

# Runs a PowerShell script in its own hidden process and passes its output to the log.
function Invoke-Child([string]$Script, [string[]]$Arguments) {
    $out = [IO.Path]::GetTempFileName()
    $command = "& $(Quote $Script) $(($Arguments | ForEach-Object { if ($_ -like '-*') { $_ } else { Quote $_ } }) -join ' ') *> $(Quote $out); exit `$LASTEXITCODE"
    $p = Start-Process powershell.exe -WindowStyle Hidden -PassThru -Wait -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', (ConvertTo-Encoded $command))
    Get-Content -LiteralPath $out -ErrorAction SilentlyContinue | ForEach-Object { if ($_.Trim()) { Write-Log "    $_" } }
    Remove-Item -LiteralPath $out -ErrorAction SilentlyContinue
    return $p.ExitCode
}

# Runs a short PowerShell command with administrator rights (Windows asks first).
function Invoke-AsAdmin([string]$Command) {
    $p = Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -PassThru -Wait -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', (ConvertTo-Encoded $Command))
    if ($p.ExitCode -ne 0) { throw "the administrator step failed (exit code $($p.ExitCode))" }
}

function New-Shortcut([string]$Path, [string]$Target) {
    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut($Path)
    $link.TargetPath = $Target
    $link.WorkingDirectory = Split-Path $Target
    $link.Description = 'mpv media player'
    $link.Save()
}

if (-not ('MpvSetup.Native' -as [type])) {   # loaded once per process (the setup window loads this script twice)
    Add-Type -Namespace MpvSetup -Name Native -MemberDefinition @'
[DllImport("gdi32.dll", CharSet = CharSet.Unicode)] public static extern int AddFontResource(string file);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam, uint flags, uint timeout, out IntPtr result);
[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
'@
}

#endregion
#region Install steps -------------------------------------------------------------------------------

# "slang=eng,en      # comment" with a new setting, keeping the comment where it was.
function Set-Setting([string]$Line, [string]$Setting) {
    if ($Line -match '^(\S+)(\s+)(#.*)$') {
        $column = $Matches[1].Length + $Matches[2].Length
        return $(if ($Setting.Length -lt $column) { $Setting.PadRight($column) } else { "$Setting " }) + $Matches[3]
    }
    return $Setting
}

# Edits the installed mpv.conf line by line: quality preset, languages, subtitle font, built-in controls.
function Set-ConfigChoices([string]$ConfigDir, [hashtable]$Plan) {
    $path = Join-Path $ConfigDir 'mpv.conf'
    $lines = [IO.File]::ReadAllLines($path)
    $useOsc = $Plan.Without -contains 'modernz'
    $font = $SubtitleFonts[$Plan.SubFont]
    for ($i = 0; $i -lt $lines.Length; $i++) {
        $line = $lines[$i]
        if ($line -match '^profile=high(\s|$)') { $lines[$i] = Set-Setting $line "profile=$($Plan.Preset)" }
        elseif ($line -match '^sub-font=') { $lines[$i] = $line -replace '^sub-font=[^,]*', "sub-font=$($font.Name) ($($font.Size) regular)" }
        elseif ($line -match '^slang=') { $lines[$i] = Set-Setting $line $(if ($Plan.SubLangs) { "slang=$($Plan.SubLangs)" } else { '#slang=' }) }
        elseif ($line -match '^#alang=' -and $Plan.AudioLangs) { $lines[$i] = Set-Setting $line "alang=$($Plan.AudioLangs)" }
        elseif ($useOsc -and $line -match '^osc=no\b') { $lines[$i] = Set-Setting $line 'osc=yes' }
        elseif ($useOsc -and $line -match '^osd-bar=no\b') { $lines[$i] = Set-Setting $line 'osd-bar=yes' }
    }
    [IO.File]::WriteAllLines($path, $lines, (New-Object Text.UTF8Encoding $false))

    $updater = Join-Path $ConfigDir 'script-opts\updater.conf'
    if (-not $Plan.UpdateCheck -and (Test-Path -LiteralPath $updater)) {
        $text = [IO.File]::ReadAllText($updater) -replace '(?m)^check=yes', 'check=no'
        [IO.File]::WriteAllText($updater, $text, (New-Object Text.UTF8Encoding $false))
    }
}

function Install-Config([hashtable]$Plan, [hashtable]$Manifest) {
    $config = $Plan.ConfigDir
    if ((Test-Path -LiteralPath $config) -and (Get-ChildItem -LiteralPath $config -Force | Select-Object -First 1)) {
        $backup = "$config-backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Write-Log "Backing up your current mpv config to $backup"
        Move-Item -LiteralPath $config -Destination $backup
        $Manifest.BackupDir = $backup
    }
    Write-Log "Installing the config into $config"
    $skip = @()
    $without = @($Plan.Without)
    if ($without -contains 'modernz') { $without += 'thumbnails' }
    foreach ($feature in $without | Select-Object -Unique) { $skip += $FeatureFiles[$feature] }
    try {
        New-Item -ItemType Directory -Force -Path $config | Out-Null
        foreach ($item in Get-ChildItem -LiteralPath $RepoConfig -Recurse -Force -File) {
            $relative = $item.FullName.Substring($RepoConfig.Length + 1)
            if ($skip | Where-Object { $relative -eq $_ -or $relative.StartsWith("$_\") }) { continue }
            $target = Join-Path $config $relative
            New-Item -ItemType Directory -Force -Path (Split-Path $target) | Out-Null
            Copy-Item -LiteralPath $item.FullName -Destination $target
        }
        # Files from a downloaded zip are marked as coming from the internet; the config's own
        # helper scripts (the Open dialog) must run without a security prompt.
        Get-ChildItem -LiteralPath $config -Recurse -File | Unblock-File
        Set-ConfigChoices $config $Plan
    } catch {
        # Never leave a half-installed config: put the backup back.
        Remove-Item -LiteralPath $config -Recurse -Force -ErrorAction SilentlyContinue
        if ($Manifest.BackupDir) { Move-Item -LiteralPath $Manifest.BackupDir -Destination $config; $Manifest.BackupDir = $null }
        throw
    }
    $Manifest.ConfigDir = $config
}

function Install-Mpv([hashtable]$Plan, [hashtable]$Manifest) {
    Write-Log "Installing mpv into $($Plan.MpvDir) (the updater downloads, checks and test-plays the latest build)"
    $updaterArgs = @('-Install', '-MpvDir', $Plan.MpvDir, '-NoPause')
    if ($Plan.MpvArchive) { $updaterArgs += @('-Archive', $Plan.MpvArchive) }
    $code = Invoke-Child (Join-Path $Plan.ConfigDir 'tools\mpv-update.ps1') $updaterArgs
    if ($code -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $Plan.MpvDir 'mpv.exe'))) { throw 'installing mpv failed (see the lines above)' }
    $Manifest.MpvInstalled = $true
}

function Install-Fonts([hashtable]$Plan, [hashtable]$Manifest) {
    $choice = $SubtitleFonts[$Plan.SubFont]
    if (-not $choice.Files -or (Test-FontInstalled $choice.Name)) { Write-Log "Subtitle font: $($choice.Name) is already installed"; return }
    Write-Log "Installing the subtitle font $($choice.Name) (for your Windows user)"
    $dir = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    if (-not (Test-Path "HKCU:\$FontsKey")) { New-Item -Force "HKCU:\$FontsKey" | Out-Null }
    $Manifest.Fonts = @()
    foreach ($font in $choice.Files) {
        $temp = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N') + '.ttf')
        try {
            Get-File $font.Url $temp
            if ((Get-FileHash -LiteralPath $temp -Algorithm SHA256).Hash.ToLowerInvariant() -ne $font.Sha256) {
                throw "$($font.Name) does not match its published checksum"
            }
            $target = Join-Path $dir $font.Name
            Copy-Item -LiteralPath $temp -Destination $target -Force
            New-ItemProperty -Path "HKCU:\$FontsKey" -Name $font.Value -Value $target -PropertyType String -Force | Out-Null
            [void][MpvSetup.Native]::AddFontResource($target)
            $Manifest.Fonts += @{ File = $target; Value = $font.Value }
        } finally {
            Remove-Item -LiteralPath $temp -ErrorAction SilentlyContinue
        }
    }
    $r = [IntPtr]::Zero
    [void][MpvSetup.Native]::SendMessageTimeout([IntPtr]0xffff, 0x001D, [IntPtr]::Zero, [IntPtr]::Zero, 2, 1000, [ref]$r)   # WM_FONTCHANGE
}

# yt-dlp goes into the config folder, where mpv looks for it first; scripts\ytdlp-update.lua keeps it current.
function Install-YtDlp([hashtable]$Plan, [hashtable]$Manifest) {
    $onPath = Get-Command yt-dlp.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($onPath) { Write-Log "Web videos: using the yt-dlp already installed at $($onPath.Source)"; return }
    Write-Log 'Installing yt-dlp for web videos'
    $release = Invoke-RestMethod 'https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest' -Headers @{ 'User-Agent' = $UserAgent }
    $name = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -and ($release.assets.name -contains 'yt-dlp_arm64.exe')) { 'yt-dlp_arm64.exe' } else { 'yt-dlp.exe' }
    $asset = $release.assets | Where-Object { $_.name -eq $name } | Select-Object -First 1
    $sums = $release.assets | Where-Object { $_.name -eq 'SHA2-256SUMS' } | Select-Object -First 1
    if (-not $asset -or -not $sums) { throw "the latest yt-dlp release has no $name or checksum list" }
    $target = Join-Path $Plan.ConfigDir 'yt-dlp.exe'
    $temp = "$target.download"
    $sumsFile = "$target.sums"
    try {
        Get-File $asset.browser_download_url $temp
        Get-File $sums.browser_download_url $sumsFile
        $expected = Get-Content -LiteralPath $sumsFile | ForEach-Object {
            if ($_ -match "^([0-9a-f]{64})\s+\*?$([regex]::Escape($name))\s*$") { $Matches[1] } } | Select-Object -First 1
        if (-not $expected -or (Get-FileHash -LiteralPath $temp -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected) {
            throw 'the yt-dlp download does not match its published checksum'
        }
        Move-Item -LiteralPath $temp -Destination $target -Force
    } finally {
        Remove-Item -LiteralPath $temp, $sumsFile -ErrorAction SilentlyContinue
    }
    $Manifest.YtDlp = $target
}

function Register-Player([hashtable]$Plan, [hashtable]$Manifest) {
    Write-Log 'Registering mpv as a media player for your Windows user'
    & (Join-Path $Plan.MpvDir 'mpv.com') --no-config --register | Out-Null
    $Manifest.Registered = $true
}

function Add-Shortcuts([hashtable]$Plan, [hashtable]$Manifest) {
    $exe = Join-Path $Plan.MpvDir 'mpv.exe'
    $Manifest.Shortcuts = @()
    $paths = @()
    if ($Plan.StartMenu) { $paths += Join-Path ([Environment]::GetFolderPath('Programs')) 'mpv.lnk' }
    if ($Plan.Desktop) { $paths += Join-Path ([Environment]::GetFolderPath('Desktop')) 'mpv.lnk' }
    foreach ($path in $paths) {
        if (Test-Path -LiteralPath $path) {
            $existing = (New-Object -ComObject WScript.Shell).CreateShortcut($path).TargetPath
            if ($existing -eq $exe) { Write-Log "Shortcut already there: $path"; continue }
        }
        Write-Log "Adding a shortcut: $path"
        New-Shortcut $path $exe
        $Manifest.Shortcuts += $path
    }
}

function Add-FolderMenu([hashtable]$Plan, [hashtable]$Manifest) {
    Write-Log 'Adding "Play with mpv" to the right-click menu of folders'
    $exe = Join-Path $Plan.MpvDir 'mpv.exe'
    $key = 'HKCU:\Software\Classes\Directory\shell\mpv.play'
    New-Item -Force -Path "$key\command" | Out-Null
    Set-ItemProperty -Path $key -Name '(default)' -Value 'Play with mpv'
    Set-ItemProperty -Path $key -Name 'Icon' -Value "`"$exe`",0"
    Set-ItemProperty -Path "$key\command" -Name '(default)' -Value "`"$exe`" `"%V`""
    $Manifest.FolderMenu = $true
}

# Uninstall.cmd + uninstall.ps1 next to mpv.exe (with administrator rights if that folder needs them).
function Install-Uninstaller([hashtable]$Plan, [hashtable]$Manifest) {
    Write-Log "Putting the uninstaller next to mpv.exe ($($Plan.MpvDir)\Uninstall.cmd)"
    $files = 'Uninstall.cmd', 'uninstall.ps1'
    if (Test-Writable $Plan.MpvDir) {
        foreach ($f in $files) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $f) -Destination $Plan.MpvDir -Force }
    } else {
        Write-Log '  (mpv is in a protected folder, so Windows asks for permission)'
        Invoke-AsAdmin (($files | ForEach-Object { "Copy-Item -LiteralPath $(Quote (Join-Path $PSScriptRoot $_)) -Destination $(Quote $Plan.MpvDir) -Force" }) -join '; ')
    }
    Get-ChildItem -LiteralPath $Plan.MpvDir -Filter '*ninstall*' | Unblock-File -ErrorAction SilentlyContinue
    $Manifest.Uninstaller = Join-Path $Plan.MpvDir 'Uninstall.cmd'
}

function Save-Manifest([hashtable]$Manifest) {
    New-Item -ItemType Directory -Force -Path (Split-Path $ManifestPath) | Out-Null
    $Manifest.Saved = (Get-Date).ToString('s')
    [IO.File]::WriteAllText($ManifestPath, ($Manifest | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding $false))
}

# Runs every chosen step in order. Returns $true when everything worked.
function Invoke-Install([hashtable]$Plan) {
    $manifest = @{ MpvDir = $Plan.MpvDir; ConfigDir = $null; BackupDir = $null; MpvInstalled = $false; Fonts = @()
                   Shortcuts = @(); FolderMenu = $false; Registered = $false; YtDlp = $null; Uninstaller = $null }
    try {
        if (-not (Test-Languages $Plan.SubLangs)) { throw "the subtitle languages '$($Plan.SubLangs)' aren't language codes like eng,en" }
        if (-not (Test-Languages $Plan.AudioLangs)) { throw "the audio languages '$($Plan.AudioLangs)' aren't language codes like jpn,ja" }
        if (Get-Process mpv -ErrorAction SilentlyContinue) { throw 'mpv is running. Close it and try again.' }
        Install-Config $Plan $manifest
        Save-Manifest $manifest
        $haveMpv = Test-Path -LiteralPath (Join-Path $Plan.MpvDir 'mpv.exe')
        if (-not $haveMpv -and $Plan.InstallMpv) { Install-Mpv $Plan $manifest; $haveMpv = $true }
        if (-not $haveMpv) { Write-Log "mpv isn't installed yet: the config is ready for when it is." }
        if ($Plan.Fonts) { Install-Fonts $Plan $manifest }
        if ($Plan.WebVideos) { Install-YtDlp $Plan $manifest }
        if ($haveMpv) {
            if ($Plan.DefaultPlayer) { Register-Player $Plan $manifest }
            if ($Plan.StartMenu -or $Plan.Desktop) { Add-Shortcuts $Plan $manifest }
            if ($Plan.FolderMenu) { Add-FolderMenu $Plan $manifest }
            Install-Uninstaller $Plan $manifest
        }
        Save-Manifest $manifest
        Write-Log 'Done.'
        return $true
    } catch {
        Save-Manifest $manifest
        Write-Log "Stopped: $($_.Exception.Message)"
        return $false
    }
}

function New-Plan {
    $found = Find-Mpv
    $mpv = if ($MpvDir) { [IO.Path]::GetFullPath($MpvDir) } elseif ($found) { $found } else { $DefaultMpvDir }
    return @{
        MpvDir = $mpv; MpvFound = [bool]$found; ConfigDir = Get-ConfigDir $mpv
        InstallMpv = [bool]$InstallMpv; MpvArchive = $MpvArchive
        Preset = $Preset; SubLangs = $SubtitleLanguages.Trim(); AudioLangs = $AudioLanguages.Trim(); Without = @($Without)
        SubFont = $SubtitleFont
        Fonts = [bool]$Fonts; DefaultPlayer = [bool]$DefaultPlayer; StartMenu = [bool]$StartMenuShortcut
        Desktop = [bool]$DesktopShortcut; FolderMenu = [bool]$FolderMenu; WebVideos = [bool]$WebVideos
        UpdateCheck = -not $NoUpdateCheck
    }
}

#endregion
#region Setup window ------------------------------------------------------------------------------

# Colors and shapes of the setup window (uninstall.ps1 has the same): a near-black background, soft
# light-blue accent, rounded cards with thin outlines.
$ThemeXaml = @'
  <SolidColorBrush x:Key="Surface" Color="#1A1A1A"/>
  <SolidColorBrush x:Key="Card" Color="#202020"/>
  <SolidColorBrush x:Key="Stroke" Color="#2E2E2E"/>
  <SolidColorBrush x:Key="StrokeStrong" Color="#474747"/>
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
  <Style x:Key="FormLabel" TargetType="TextBlock">
    <Setter Property="HorizontalAlignment" Value="Right"/>
    <Setter Property="VerticalAlignment" Value="Top"/>
    <Setter Property="Foreground" Value="{StaticResource Dim}"/>
    <Setter Property="Margin" Value="0,7,16,0"/>
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
  <!-- A small label on a picture -->
  <Style x:Key="Caption" TargetType="Border">
    <Setter Property="HorizontalAlignment" Value="Left"/>
    <Setter Property="VerticalAlignment" Value="Top"/>
    <Setter Property="Margin" Value="7"/>
    <Setter Property="Padding" Value="7,2,7,3"/>
    <Setter Property="CornerRadius" Value="4"/>
    <Setter Property="Background" Value="#E0141414"/>
    <Setter Property="TextElement.FontSize" Value="11.5"/>
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
  <Style x:Key="Subtle" TargetType="Button" BasedOn="{StaticResource ButtonBase}">
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="BorderBrush" Value="Transparent"/>
    <Setter Property="MinWidth" Value="0"/>
    <Setter Property="Foreground" Value="{StaticResource Dim}"/>
  </Style>

  <!-- A row in a Group with a switch on the right -->
  <Style x:Key="ToggleRow" TargetType="CheckBox">
    <Setter Property="Foreground" Value="{StaticResource Text}"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="CheckBox">
          <Border Background="Transparent" Padding="16,10">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <ContentPresenter VerticalAlignment="Center"/>
              <Grid Grid.Column="1" Margin="16,0,0,0" VerticalAlignment="Center">
                <Border x:Name="Track" Width="38" Height="20" CornerRadius="10" BorderThickness="1" BorderBrush="#8C8C8C" Background="Transparent"/>
                <Ellipse x:Name="Knob" Width="12" Height="12" Fill="#CFCFCF" HorizontalAlignment="Left" Margin="4,0,0,0"/>
              </Grid>
            </Grid>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Track" Property="BorderBrush" Value="{StaticResource Text}"/></Trigger>
            <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Track" Property="BorderBrush" Value="{StaticResource Accent}"/></Trigger>
            <Trigger Property="IsChecked" Value="True">
              <Setter TargetName="Track" Property="Background" Value="{StaticResource Accent}"/>
              <Setter TargetName="Track" Property="BorderBrush" Value="{StaticResource Accent}"/>
              <Setter TargetName="Knob" Property="Fill" Value="{StaticResource OnAccent}"/>
              <Setter TargetName="Knob" Property="HorizontalAlignment" Value="Right"/>
              <Setter TargetName="Knob" Property="Margin" Value="0,0,4,0"/>
            </Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.5"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
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

  <!-- One option of a segmented control (radio buttons sharing a frame) -->
  <Style x:Key="Segment" TargetType="RadioButton">
    <Setter Property="Foreground" Value="{StaticResource Text}"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="Height" Value="30"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="RadioButton">
          <Border x:Name="Seg" Background="Transparent" CornerRadius="5" Margin="2">
            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Seg" Property="Background" Value="#2A2A2A"/></Trigger>
            <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Seg" Property="Background" Value="#2A2A2A"/></Trigger>
            <Trigger Property="IsChecked" Value="True">
              <Setter TargetName="Seg" Property="Background" Value="{StaticResource Accent}"/>
              <Setter Property="Foreground" Value="{StaticResource OnAccent}"/>
              <Setter Property="FontWeight" Value="SemiBold"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <!-- A choice drawn as a framed button; the chosen one is tinted -->
  <Style x:Key="Chip" TargetType="RadioButton">
    <Setter Property="Foreground" Value="{StaticResource Text}"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="Height" Value="40"/>
    <Setter Property="Margin" Value="0,0,8,8"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="RadioButton">
          <Border x:Name="Bd" Background="{StaticResource Card}" BorderBrush="{StaticResource Stroke}" BorderThickness="1" CornerRadius="7">
            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource StrokeStrong}"/></Trigger>
            <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource Text}"/></Trigger>
            <Trigger Property="IsChecked" Value="True">
              <Setter TargetName="Bd" Property="Background" Value="{StaticResource SelBg}"/>
              <Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource Accent}"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <Style x:Key="Field" TargetType="TextBox">
    <Setter Property="Foreground" Value="{StaticResource Text}"/>
    <Setter Property="CaretBrush" Value="{StaticResource Text}"/>
    <Setter Property="SelectionBrush" Value="{StaticResource Accent}"/>
    <Setter Property="Height" Value="34"/>
    <Setter Property="Padding" Value="9,0"/>
    <Setter Property="VerticalContentAlignment" Value="Center"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="TextBox">
          <Grid>
            <Border x:Name="Bd" Background="#1C1C1C" BorderBrush="{StaticResource StrokeStrong}" BorderThickness="1" CornerRadius="6"/>
            <Border x:Name="Line" BorderBrush="{StaticResource Accent}" BorderThickness="0,0,0,2" CornerRadius="0,0,6,6" Visibility="Collapsed"/>
            <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}" VerticalAlignment="Center"/>
          </Grid>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="#5C5C5C"/></Trigger>
            <Trigger Property="IsKeyboardFocused" Value="True">
              <Setter TargetName="Line" Property="Visibility" Value="Visible"/>
              <Setter TargetName="Bd" Property="Background" Value="#171717"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
'@

# The setup window: a step rail on the left, and the current page on a rounded surface.
$WizardXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="mpv config setup" Width="900" Height="660" ResizeMode="CanMinimize" WindowStartupLocation="CenterScreen"
        Background="#141414" Foreground="#EDEDED" FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="14"
        UseLayoutRounding="True" SnapsToDevicePixels="True" TextOptions.TextFormattingMode="Display">
  <Window.Resources>THEME</Window.Resources>
  <Grid>
    <Grid.ColumnDefinitions><ColumnDefinition Width="228"/><ColumnDefinition/></Grid.ColumnDefinitions>

    <StackPanel Margin="16,24,14,24">
      <StackPanel Orientation="Horizontal" Margin="8,0,0,0">
        <Image Source="{StaticResource AppIcon}" Width="32" Height="32"/>
        <TextBlock Text="mpv setup" FontFamily="{StaticResource Display}" FontSize="17" FontWeight="SemiBold" VerticalAlignment="Center" Margin="12,0,0,0"/>
      </StackPanel>
      <StackPanel x:Name="Steps" Margin="0,30,0,0"/>
    </StackPanel>

    <Border Grid.Column="1" Margin="0,12,12,12" Background="{StaticResource Surface}" BorderBrush="#242424" BorderThickness="1" CornerRadius="12">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <StackPanel Margin="32,22,32,16">
          <StackPanel Orientation="Horizontal">
            <TextBlock x:Name="TitleIcon" Style="{StaticResource Glyph}" FontSize="22" Margin="0,2,10,0" Visibility="Collapsed"/>
            <TextBlock x:Name="PageTitle" FontFamily="{StaticResource Display}" FontSize="24" FontWeight="SemiBold"/>
          </StackPanel>
          <TextBlock x:Name="PageSubtitle" Foreground="{StaticResource Dim}" Margin="0,2,0,0"/>
        </StackPanel>
        <Border Grid.Row="1" Style="{StaticResource Divider}"/>

        <Grid Grid.Row="2" Margin="32,20,32,0">
          <!-- 1: welcome -->
          <StackPanel x:Name="Page0">
            <TextBlock TextWrapping="Wrap" Margin="0,0,0,16" LineHeight="21"
                       Text="This sets up mpv with a live video effects panel, modern controls with seekbar thumbnails, a shorter right-click menu and YouTube-style keys."/>
            <Border Style="{StaticResource Group}">
              <StackPanel>
                <Grid Margin="16,12"><Grid.ColumnDefinitions><ColumnDefinition Width="34"/><ColumnDefinition/></Grid.ColumnDefinitions>
                  <TextBlock Style="{StaticResource Glyph}" Text="&#xE714;" Foreground="{StaticResource Accent}" VerticalAlignment="Top" Margin="0,1,0,0"/>
                  <StackPanel Grid.Column="1"><TextBlock x:Name="WelcomeMpv" FontWeight="SemiBold"/><TextBlock x:Name="WelcomeMpvNote" Style="{StaticResource Note}"/></StackPanel>
                </Grid>
                <Border Style="{StaticResource Divider}"/>
                <Grid Margin="16,12"><Grid.ColumnDefinitions><ColumnDefinition Width="34"/><ColumnDefinition/></Grid.ColumnDefinitions>
                  <TextBlock Style="{StaticResource Glyph}" Text="&#xE81C;" Foreground="{StaticResource Accent}" VerticalAlignment="Top" Margin="0,1,0,0"/>
                  <StackPanel Grid.Column="1"><TextBlock x:Name="WelcomeConfig" FontWeight="SemiBold"/><TextBlock x:Name="WelcomeConfigNote" Style="{StaticResource Note}"/></StackPanel>
                </Grid>
                <Border Style="{StaticResource Divider}"/>
                <Grid Margin="16,12"><Grid.ColumnDefinitions><ColumnDefinition Width="34"/><ColumnDefinition/></Grid.ColumnDefinitions>
                  <TextBlock Style="{StaticResource Glyph}" Text="&#xE74D;" Foreground="{StaticResource Accent}" VerticalAlignment="Top" Margin="0,1,0,0"/>
                  <StackPanel Grid.Column="1"><TextBlock Text="Uninstaller" FontWeight="SemiBold"/>
                    <TextBlock Style="{StaticResource Note}" Text="Uninstall.cmd, next to mpv.exe, removes this config, or mpv and everything with it."/></StackPanel>
                </Grid>
              </StackPanel>
            </Border>
          </StackPanel>

          <!-- 2: mpv -->
          <StackPanel x:Name="Page1" Visibility="Collapsed">
            <StackPanel x:Name="MpvFoundPanel">
              <Border Style="{StaticResource Group}">
                <Grid Margin="16,12">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="34"/><ColumnDefinition Width="80"/><ColumnDefinition/></Grid.ColumnDefinitions>
                  <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                  <TextBlock Grid.RowSpan="2" Style="{StaticResource Glyph}" Text="&#xE930;" Foreground="{StaticResource Good}" VerticalAlignment="Top" Margin="0,1,0,0"/>
                  <TextBlock Grid.Column="1" Text="Folder" Foreground="{StaticResource Dim}"/>
                  <TextBlock x:Name="MpvFoundPath" Grid.Column="2"/>
                  <TextBlock Grid.Row="1" Grid.Column="1" Text="Version" Foreground="{StaticResource Dim}" Margin="0,4,0,0"/>
                  <TextBlock x:Name="MpvFoundVersion" Grid.Row="1" Grid.Column="2" Margin="0,4,0,0"/>
                </Grid>
              </Border>
              <TextBlock Style="{StaticResource Note}" Margin="2,10,0,0"
                         Text="Keep it current with Tools &gt; Update mpv in the right-click menu. The right-click menu of this config needs a development build of mpv newer than 0.41.0."/>
            </StackPanel>
            <StackPanel x:Name="MpvMissingPanel">
              <Border Style="{StaticResource Group}">
                <CheckBox x:Name="CbInstallMpv" Style="{StaticResource ToggleRow}" IsChecked="True" AutomationProperties.Name="Download and install mpv">
                  <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="34"/><ColumnDefinition/></Grid.ColumnDefinitions>
                    <TextBlock Style="{StaticResource Glyph}" Text="&#xE896;" Foreground="{StaticResource Accent}"/>
                    <StackPanel Grid.Column="1"><TextBlock Text="Download and install mpv" FontWeight="SemiBold"/>
                      <TextBlock Style="{StaticResource Note}" Text="From github.com/zhongfly/mpv-winbuild; checked against its published checksum and test-played first."/></StackPanel>
                  </Grid>
                </CheckBox>
              </Border>
              <Grid Margin="0,18,0,0">
                <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <TextBlock Text="Location" Style="{StaticResource FormLabel}" Margin="0,7,14,0"/>
                <TextBox x:Name="TbMpvDir" Grid.Column="1" Style="{StaticResource Field}" AutomationProperties.Name="Install location"/>
                <Button x:Name="BtnBrowse" Grid.Column="2" Content="Browse..." Style="{StaticResource ButtonBase}" Margin="8,0,0,0"/>
              </Grid>
              <TextBlock Style="{StaticResource Note}" Margin="72,8,0,0" Text="A folder in your user profile needs no administrator rights."/>
            </StackPanel>
          </StackPanel>

          <!-- 3: extras, one framed list -->
          <Border x:Name="Page2" Style="{StaticResource Group}" VerticalAlignment="Top" Visibility="Collapsed">
            <StackPanel>
              <CheckBox x:Name="CbWeb" Style="{StaticResource ToggleRow}" IsChecked="True" AutomationProperties.Name="Play web videos">
                <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="34"/><ColumnDefinition/></Grid.ColumnDefinitions>
                  <TextBlock Style="{StaticResource Glyph}" Text="&#xE774;" Foreground="{StaticResource Accent}"/>
                  <StackPanel Grid.Column="1"><TextBlock Text="Web videos" FontWeight="SemiBold"/><TextBlock Style="{StaticResource Note}" Text="Installs yt-dlp, so links from YouTube and other sites play."/></StackPanel>
                </Grid>
              </CheckBox>
              <Border Style="{StaticResource Divider}"/>
              <CheckBox x:Name="CbDefault" Style="{StaticResource ToggleRow}" AutomationProperties.Name="Make mpv the default player">
                <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="34"/><ColumnDefinition/></Grid.ColumnDefinitions>
                  <TextBlock Style="{StaticResource Glyph}" Text="&#xE8A5;" Foreground="{StaticResource Accent}"/>
                  <StackPanel Grid.Column="1"><TextBlock Text="Default player" FontWeight="SemiBold"/><TextBlock Style="{StaticResource Note}" Text="Use mpv for video and audio files (you confirm in Windows' Default apps)."/></StackPanel>
                </Grid>
              </CheckBox>
              <Border Style="{StaticResource Divider}"/>
              <Grid Margin="16,10">
                <Grid.ColumnDefinitions><ColumnDefinition Width="34"/><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <TextBlock Style="{StaticResource Glyph}" Text="&#xE71B;" Foreground="{StaticResource Accent}"/>
                <StackPanel Grid.Column="1"><TextBlock Text="Shortcuts" FontWeight="SemiBold"/><TextBlock Style="{StaticResource Note}" Text="Where to put a shortcut to mpv."/></StackPanel>
                <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
                  <CheckBox x:Name="CbStart" Style="{StaticResource Check}" Content="Start menu" IsChecked="True" Margin="0,0,18,0"/>
                  <CheckBox x:Name="CbDesktop" Style="{StaticResource Check}" Content="Desktop"/>
                </StackPanel>
              </Grid>
              <Border Style="{StaticResource Divider}"/>
              <CheckBox x:Name="CbFolder" Style="{StaticResource ToggleRow}" IsChecked="True" AutomationProperties.Name="Play with mpv for folders">
                <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="34"/><ColumnDefinition/></Grid.ColumnDefinitions>
                  <TextBlock Style="{StaticResource Glyph}" Text="&#xE8B7;" Foreground="{StaticResource Accent}"/>
                  <StackPanel Grid.Column="1"><TextBlock Text="Folder menu" FontWeight="SemiBold"/><TextBlock Style="{StaticResource Note}" Text="Adds &quot;Play with mpv&quot; to the right-click menu of folders."/></StackPanel>
                </Grid>
              </CheckBox>
              <Border Style="{StaticResource Divider}"/>
              <CheckBox x:Name="CbUpdates" Style="{StaticResource ToggleRow}" IsChecked="True" AutomationProperties.Name="Check for mpv updates once a day">
                <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="34"/><ColumnDefinition/></Grid.ColumnDefinitions>
                  <TextBlock Style="{StaticResource Glyph}" Text="&#xE895;" Foreground="{StaticResource Accent}"/>
                  <StackPanel Grid.Column="1"><TextBlock Text="Update check" FontWeight="SemiBold"/><TextBlock Style="{StaticResource Note}" Text="Looks for a newer mpv once a day while mpv is open."/></StackPanel>
                </Grid>
              </CheckBox>
            </StackPanel>
          </Border>

          <!-- 4: preferences, as a form -->
          <Grid x:Name="Page3" Visibility="Collapsed">
            <Grid.ColumnDefinitions><ColumnDefinition Width="132"/><ColumnDefinition/></Grid.ColumnDefinitions>
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
            <TextBlock Text="Picture quality" Style="{StaticResource FormLabel}"/>
            <StackPanel Grid.Column="1" Margin="0,0,0,20">
              <Border Background="{StaticResource Card}" BorderBrush="{StaticResource Stroke}" BorderThickness="1" CornerRadius="7" Padding="1" HorizontalAlignment="Left" Width="330">
                <UniformGrid Columns="3">
                  <RadioButton x:Name="RbUltra" GroupName="Preset" Style="{StaticResource Segment}" Content="Ultra" AutomationProperties.Name="Ultra"/>
                  <RadioButton x:Name="RbHigh" GroupName="Preset" Style="{StaticResource Segment}" Content="High" AutomationProperties.Name="High"/>
                  <RadioButton x:Name="RbLight" GroupName="Preset" Style="{StaticResource Segment}" Content="Light" AutomationProperties.Name="Light"/>
                </UniformGrid>
              </Border>
              <UniformGrid Columns="3" Width="330" HorizontalAlignment="Left" Margin="0,4,0,0">
                <TextBlock/>
                <TextBlock Text="Recommended" Foreground="{StaticResource Accent}" FontSize="11.5" HorizontalAlignment="Center"/>
                <TextBlock/>
              </UniformGrid>
              <TextBlock x:Name="PresetNote" Style="{StaticResource Note}" Margin="2,8,0,0" MinHeight="34"/>
            </StackPanel>
            <TextBlock Grid.Row="1" Text="Subtitles" Style="{StaticResource FormLabel}"/>
            <TextBox x:Name="TbSubs" Grid.Row="1" Grid.Column="1" Style="{StaticResource Field}" Width="260" HorizontalAlignment="Left" Margin="0,0,0,10" AutomationProperties.Name="Subtitle languages"/>
            <TextBlock Grid.Row="2" Text="Audio" Style="{StaticResource FormLabel}"/>
            <StackPanel Grid.Row="2" Grid.Column="1">
              <TextBox x:Name="TbAudio" Style="{StaticResource Field}" Width="260" HorizontalAlignment="Left" AutomationProperties.Name="Audio languages"/>
              <TextBlock Style="{StaticResource Note}" Margin="2,6,0,0" Text="Language codes in order, e.g. eng,en or jpn,ja. Empty audio plays the file's default track."/>
            </StackPanel>
          </Grid>

          <!-- 5: subtitle font (choices and pictures are added in code) -->
          <StackPanel x:Name="Page4" Visibility="Collapsed">
            <UniformGrid x:Name="FontChoices" Columns="3" Margin="0,0,-8,10"/>
            <Border Height="70" CornerRadius="8"><Border.Background><ImageBrush x:Name="FontPreview" Stretch="UniformToFill"/></Border.Background></Border>
            <TextBlock x:Name="FontNote" Style="{StaticResource Note}" Margin="2,10,0,0"/>
          </StackPanel>

          <!-- 6: features, each picture shows it on or off -->
          <UniformGrid x:Name="Page5" Columns="2" VerticalAlignment="Top" Margin="0,0,-12,0" Visibility="Collapsed">
            <Border Style="{StaticResource Group}" Padding="9" Margin="0,0,12,12">
              <StackPanel>
                <Grid><Border x:Name="PicModernz" Height="140" CornerRadius="5"/>
                  <Border Style="{StaticResource Caption}"><TextBlock x:Name="CapModernz"/></Border></Grid>
                <CheckBox x:Name="CbModernz" Style="{StaticResource Check}" Content="Modern controls" IsChecked="True" Margin="2,9,0,0"/>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Group}" Padding="9" Margin="0,0,12,12">
              <StackPanel>
                <Grid><Border x:Name="PicThumbs" Height="140" CornerRadius="5"/>
                  <Border Style="{StaticResource Caption}"><TextBlock x:Name="CapThumbs"/></Border></Grid>
                <CheckBox x:Name="CbThumbs" Style="{StaticResource Check}" Content="Seekbar thumbnails" IsChecked="True" Margin="2,9,0,0"/>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Group}" Padding="9" Margin="0,0,12,0">
              <StackPanel>
                <Grid><Border x:Name="PicEffects" Height="140" CornerRadius="5"/>
                  <Border Style="{StaticResource Caption}" VerticalAlignment="Bottom"><TextBlock x:Name="CapEffects"/></Border></Grid>
                <CheckBox x:Name="CbEffects" Style="{StaticResource Check}" Content="Video effects panel" IsChecked="True" Margin="2,9,0,0"/>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Group}" Padding="9" Margin="0,0,12,0">
              <StackPanel>
                <Grid><Border x:Name="PicResume" Height="140" CornerRadius="5"/>
                  <Border Style="{StaticResource Caption}" VerticalAlignment="Bottom" HorizontalAlignment="Right"><TextBlock x:Name="CapResume"/></Border></Grid>
                <CheckBox x:Name="CbResume" Style="{StaticResource Check}" Content="Resume prompt" IsChecked="True" Margin="2,9,0,0"/>
              </StackPanel>
            </Border>
          </UniformGrid>

          <!-- 7: summary -->
          <StackPanel x:Name="Page6" Visibility="Collapsed">
            <Border Style="{StaticResource Group}" Padding="18,14"><StackPanel x:Name="Summary"/></Border>
          </StackPanel>

          <!-- 8: installing -->
          <Grid x:Name="Page7" Visibility="Collapsed">
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
            <ProgressBar x:Name="Progress" Height="4" IsIndeterminate="True" Foreground="{StaticResource Accent}" Background="#262626" BorderThickness="0"/>
            <Border Grid.Row="1" Style="{StaticResource Group}" Margin="0,16,0,0" Padding="14,10">
              <TextBox x:Name="Log" IsReadOnly="True" Background="Transparent" BorderThickness="0" Foreground="#C8C8C8" TextWrapping="Wrap"
                       FontFamily="Cascadia Mono, Consolas" FontSize="12" VerticalScrollBarVisibility="Hidden" AutomationProperties.Name="Install log"/>
            </Border>
            <CheckBox x:Name="CbOpen" Grid.Row="2" Style="{StaticResource Check}" Content="Open mpv now" IsChecked="True" Margin="2,14,0,0" Visibility="Collapsed"/>
          </Grid>
        </Grid>

        <Border x:Name="Problem" Grid.Row="3" Margin="32,12,32,0" Padding="14,10" CornerRadius="8" Background="#2E1A14" BorderBrush="#5A2A1A" BorderThickness="1" Visibility="Collapsed">
          <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition/></Grid.ColumnDefinitions>
            <TextBlock Style="{StaticResource Glyph}" Text="&#xE783;" FontSize="16" Foreground="{StaticResource Bad}" Margin="0,0,10,0"/>
            <TextBlock x:Name="ProblemText" Grid.Column="1" TextWrapping="Wrap" VerticalAlignment="Center"/>
          </Grid>
        </Border>
        <Border Grid.Row="4" Style="{StaticResource Divider}" Margin="0,16,0,0"/>
        <Grid Grid.Row="5" Margin="24,12,24,14">
          <Button x:Name="BtnCancel" Content="Cancel" Style="{StaticResource Subtle}" HorizontalAlignment="Left"/>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="BtnBack" Content="Back" Style="{StaticResource ButtonBase}" Margin="0,0,8,0"/>
            <Button x:Name="BtnNext" Content="Next" Style="{StaticResource Primary}" IsDefault="True"/>
          </StackPanel>
        </Grid>
      </Grid>
    </Border>
  </Grid>
</Window>
'@

# Loads a window from XAML with the theme, its icon, and a dark title bar matching its background.
function New-ThemedWindow([string]$Xaml) {
    [void][MpvSetup.Native]::SetProcessDPIAware()   # sharp text on scaled displays
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing
    $window = [Windows.Markup.XamlReader]::Parse($Xaml.Replace('THEME', $ThemeXaml))
    $window.Add_SourceInitialized({
        $hwnd = (New-Object Windows.Interop.WindowInteropHelper $window).Handle
        $on = 1; [void][MpvSetup.Native]::DwmSetWindowAttribute($hwnd, 20, [ref]$on, 4)        # dark title bar
        $color = 0x00141414; [void][MpvSetup.Native]::DwmSetWindowAttribute($hwnd, 35, [ref]$color, 4)   # same color as the window (Windows 11)
    }.GetNewClosure())
    $window.Icon = $window.FindResource('AppIcon')

    return $window
}

function Show-Wizard {
    $plan = New-Plan
    $existingConfig = (Test-Path -LiteralPath $plan.ConfigDir) -and (Get-ChildItem -LiteralPath $plan.ConfigDir -Force | Select-Object -First 1)
    $window = New-ThemedWindow $WizardXaml
    $ui = @{}
    foreach ($name in 'Steps', 'TitleIcon', 'PageTitle', 'PageSubtitle', 'Page0', 'Page1', 'Page2', 'Page3', 'Page4', 'Page5', 'Page6', 'Page7',
                      'WelcomeMpv', 'WelcomeMpvNote', 'WelcomeConfig', 'WelcomeConfigNote', 'MpvFoundPanel', 'MpvFoundPath', 'MpvFoundVersion',
                      'MpvMissingPanel', 'CbInstallMpv', 'TbMpvDir', 'BtnBrowse', 'CbWeb', 'CbDefault',
                      'CbStart', 'CbDesktop', 'CbFolder', 'CbUpdates', 'RbUltra', 'RbHigh', 'RbLight', 'TbSubs', 'TbAudio', 'PresetNote',
                      'FontChoices', 'FontPreview', 'FontNote', 'CbModernz', 'CbThumbs', 'CbEffects', 'CbResume',
                      'PicModernz', 'PicThumbs', 'PicEffects', 'PicResume', 'CapModernz', 'CapThumbs', 'CapEffects', 'CapResume',
                      'Summary', 'Progress', 'Log', 'CbOpen', 'Problem', 'ProblemText', 'BtnCancel', 'BtnBack', 'BtnNext') {
        $ui[$name] = $window.FindName($name)
    }
    $brush = { param($key) $window.FindResource($key) }
    $picture = { param($name)   # a preview picture from installer\previews
        $path = Join-Path $PSScriptRoot "previews\$name.jpg"
        if (-not (Test-Path -LiteralPath $path)) { return $null }
        $image = New-Object Windows.Media.Imaging.BitmapImage
        $image.BeginInit(); $image.CacheOption = 'OnLoad'; $image.UriSource = [Uri]$path; $image.EndInit()
        return $image
    }

    # Step rail
    $stepNames = 'Welcome', 'mpv', 'Extras', 'Preferences', 'Subtitles', 'Features', 'Install'
    $stepItems = foreach ($name in $stepNames) {
        $row = New-Object Windows.Controls.Grid -Property @{ Height = 38 }
        $pill = New-Object Windows.Controls.Grid   # the current step: a tinted row with an accent bar
        [void]$pill.Children.Add((New-Object Windows.Controls.Border -Property @{ CornerRadius = 6; Background = (& $brush 'SelBg') }))
        [void]$pill.Children.Add((New-Object Windows.Controls.Border -Property @{ Width = 3; Height = 16; CornerRadius = 1.5; HorizontalAlignment = 'Left'; Margin = '6,0,0,0'; Background = (& $brush 'Accent') }))
        $label = New-Object Windows.Controls.TextBlock -Property @{ Text = $name; Margin = '20,0,0,0'; VerticalAlignment = 'Center' }
        $check = New-Object Windows.Controls.TextBlock -Property @{ Text = [string][char]0xE73E; FontFamily = (& $brush 'Icons'); FontSize = 12
                                                                   HorizontalAlignment = 'Right'; VerticalAlignment = 'Center'; Margin = '0,0,12,0'; Foreground = (& $brush 'Good') }
        [void]$row.Children.Add($pill); [void]$row.Children.Add($label); [void]$row.Children.Add($check)
        [void]$ui.Steps.Children.Add($row)
        @{ Pill = $pill; Label = $label; Check = $check }
    }

    # Page contents that depend on this PC
    if ($plan.MpvFound) {
        $ui.WelcomeMpv.Text = 'mpv is installed'
        $ui.WelcomeMpvNote.Text = "$($plan.MpvDir)  -  $(Get-MpvVersion $plan.MpvDir)"
        $ui.MpvFoundPath.Text = $plan.MpvDir
        $ui.MpvFoundVersion.Text = Get-MpvVersion $plan.MpvDir
        $ui.MpvMissingPanel.Visibility = 'Collapsed'
    } else {
        $ui.WelcomeMpv.Text = "mpv isn't installed yet"
        $ui.WelcomeMpvNote.Text = 'The next page can download and install it.'
        $ui.MpvFoundPanel.Visibility = 'Collapsed'
        $ui.TbMpvDir.Text = $plan.MpvDir
    }
    if ($existingConfig) {
        $ui.WelcomeConfig.Text = 'Your current config is kept'
        $ui.WelcomeConfigNote.Text = "$($plan.ConfigDir) is moved to a backup folder next to it, so you can go back to it."
    } else {
        $ui.WelcomeConfig.Text = 'Where it goes'
        $ui.WelcomeConfigNote.Text = $plan.ConfigDir
    }

    # Subtitles: one button per font, each label drawn in its own font when it's installed
    $fontNotes = @{
        firago   = 'FiraGO: clear and compact. The default.'
        atkinson = 'Atkinson Hyperlegible: made for low vision, with letters that are hard to mix up.'
        segoe    = "Segoe UI: Windows' own interface font."
        calibri  = 'Calibri: soft and rounded.'
        verdana  = 'Verdana: wide and open, made for screens.'
        arial    = 'Arial: plain and familiar.' }
    foreach ($key in $SubtitleFonts.Keys) {
        $font = $SubtitleFonts[$key]
        $chip = New-Object Windows.Controls.RadioButton -Property @{ Content = $font.Label; Tag = $key; GroupName = 'Font'; Style = (& $brush 'Chip')
                                                                    FontFamily = New-Object Windows.Media.FontFamily "$($font.Name), Segoe UI"; FontSize = 15 }
        $chip.Add_Checked({
            param($sender)
            $key = $sender.Tag; $font = $SubtitleFonts[$key]
            $plan.SubFont = $key
            $ui.FontPreview.ImageSource = & $picture "font-$key"
            $source = if (-not $font.Files) { 'Comes with Windows.' } elseif (Test-FontInstalled $font.Name) { 'Already installed.' }
                      else { 'Free (SIL Open Font License); downloaded from its official repository and installed for your Windows user.' }
            $ui.FontNote.Text = "$($fontNotes[$key]) $source"
        })
        [void]$ui.FontChoices.Children.Add($chip)
        if ($key -eq $plan.SubFont) { $chip.IsChecked = $true }
    }

    # Features: ModernZ and thumbnails show the alternative when off; the others fade out
    $features = @(
        @{ Check = 'CbModernz'; Pic = 'PicModernz'; Cap = 'CapModernz'; On = 'modernz-on'; Off = 'modernz-off'; OnText = 'ModernZ'; OffText = "mpv's own controls" },
        @{ Check = 'CbThumbs'; Pic = 'PicThumbs'; Cap = 'CapThumbs'; On = 'thumbs-on'; Off = 'thumbs-off'; OnText = 'A preview while you point at the seekbar'; OffText = 'Only the time' },
        @{ Check = 'CbEffects'; Pic = 'PicEffects'; Cap = 'CapEffects'; On = 'effects'; OnText = 'Ctrl+E or the right-click menu'; OffText = 'Left out' },
        @{ Check = 'CbResume'; Pic = 'PicResume'; Cap = 'CapResume'; On = 'resume'; OnText = 'When you open a video again'; OffText = 'Videos start from the beginning' })
    $showFeatures = {
        $ui.CbThumbs.IsEnabled = [bool]$ui.CbModernz.IsChecked   # mpv's own controls can't show thumbnails
        if (-not $ui.CbModernz.IsChecked) { $ui.CbThumbs.IsChecked = $false }
        foreach ($f in $features) {
            $on = [bool]$ui[$f.Check].IsChecked
            $name = if ($on -or -not $f.Off) { $f.On } else { $f.Off }
            $ui[$f.Pic].Background = New-Object Windows.Media.ImageBrush -Property @{ ImageSource = (& $picture "feature-$name"); Stretch = 'UniformToFill' }
            $ui[$f.Pic].Opacity = $(if ($on -or $f.Off) { 1 } else { 0.35 })
            $ui[$f.Cap].Text = if ($on) { $f.OnText } else { $f.OffText }
        }
        if (-not $ui.CbModernz.IsChecked) { $ui.CapThumbs.Text = 'Needs the modern controls' }
    }
    foreach ($f in $features) { $ui[$f.Check].Add_Checked({ & $showFeatures }); $ui[$f.Check].Add_Unchecked({ & $showFeatures }) }
    & $showFeatures

    $presetNotes = @{
        RbUltra = 'The most accurate rendering, plus debanding, motion smoothing and HDR peak detection. Needs a strong graphics card.'
        RbHigh  = 'Accurate, with nothing added that changes the look of the video. The default.'
        RbLight = 'The fastest settings, for older PCs and laptops on battery.' }
    foreach ($rb in 'RbUltra', 'RbHigh', 'RbLight') { $ui[$rb].Add_Checked({ param($sender) $ui.PresetNote.Text = $presetNotes[$sender.Name] }) }
    switch ($plan.Preset) { 'ultra' { $ui.RbUltra.IsChecked = $true } 'light' { $ui.RbLight.IsChecked = $true } default { $ui.RbHigh.IsChecked = $true } }
    $ui.TbSubs.Text = $plan.SubLangs
    $ui.TbAudio.Text = $plan.AudioLangs
    $ui.BtnBrowse.Add_Click({
        $dialog = New-Object Windows.Forms.FolderBrowserDialog -Property @{ Description = 'Folder for mpv'; SelectedPath = $ui.TbMpvDir.Text }
        $owner = New-Object Windows.Forms.NativeWindow
        $owner.AssignHandle((New-Object Windows.Interop.WindowInteropHelper $window).Handle)
        if ($dialog.ShowDialog($owner) -eq 'OK') { $ui.TbMpvDir.Text = Join-Path $dialog.SelectedPath 'mpv' }
        $owner.ReleaseHandle()
    })

    $titles = @(
        @('Set up mpv', 'Choose what to install'),
        @('mpv', $(if ($plan.MpvFound) { 'Already installed' } else { 'The player itself' })),
        @('Extras', 'Optional additions'),
        @('Preferences', 'You can change all of these later in mpv.conf'),
        @('Subtitles', 'Font for subtitles'),
        @('Features', 'Uncheck any you don''t want'),
        @('Ready to install', 'Check your choices, then click Install'),
        @('Installing', 'This can take a minute'))
    $pages = $ui.Page0, $ui.Page1, $ui.Page2, $ui.Page3, $ui.Page4, $ui.Page5, $ui.Page6, $ui.Page7
    $summaryPage = 6; $installPage = 7
    $state = @{ Page = 0; Done = $false; Ok = $false }

    $showProblem = { param($text) $ui.ProblemText.Text = $text; $ui.Problem.Visibility = $(if ($text) { 'Visible' } else { 'Collapsed' }) }

    $show = {
        for ($i = 0; $i -lt $pages.Count; $i++) { $pages[$i].Visibility = $(if ($i -eq $state.Page) { 'Visible' } else { 'Collapsed' }) }
        $ui.PageTitle.Text = $titles[$state.Page][0]; $ui.PageSubtitle.Text = $titles[$state.Page][1]
        $current = [Math]::Min($state.Page, $summaryPage)   # the last step covers the summary and the install
        for ($i = 0; $i -lt $stepItems.Count; $i++) {
            $stepItems[$i].Pill.Visibility = $(if ($i -eq $current) { 'Visible' } else { 'Hidden' })
            $stepItems[$i].Label.Foreground = $(if ($i -eq $current) { & $brush 'Text' } else { & $brush 'Dim' })
            $stepItems[$i].Label.FontWeight = $(if ($i -eq $current) { 'SemiBold' } else { 'Normal' })
            $stepItems[$i].Check.Visibility = $(if ($i -lt $current -or ($i -eq $summaryPage -and $state.Done -and $state.Ok)) { 'Visible' } else { 'Hidden' })
        }
        $ui.BtnBack.IsEnabled = $state.Page -gt 0 -and $state.Page -lt $installPage
        $ui.BtnNext.Content = if ($state.Page -eq $summaryPage) { 'Install' } elseif ($state.Page -eq $installPage) { 'Finish' } else { 'Next' }
        $ui.BtnNext.IsEnabled = $state.Page -lt $installPage -or $state.Done
        $ui.BtnCancel.Visibility = $(if ($state.Page -lt $installPage) { 'Visible' } else { 'Hidden' })
    }

    $collect = {
        $plan.InstallMpv = (-not $plan.MpvFound) -and [bool]$ui.CbInstallMpv.IsChecked
        if (-not $plan.MpvFound -and $ui.TbMpvDir.Text.Trim()) {
            $plan.MpvDir = [IO.Path]::GetFullPath($ui.TbMpvDir.Text.Trim()); $plan.ConfigDir = Get-ConfigDir $plan.MpvDir
        }
        $font = $SubtitleFonts[$plan.SubFont]
        $plan.Fonts = $font.Files -and -not (Test-FontInstalled $font.Name)
        $plan.WebVideos = [bool]$ui.CbWeb.IsChecked; $plan.DefaultPlayer = [bool]$ui.CbDefault.IsChecked
        $plan.StartMenu = [bool]$ui.CbStart.IsChecked; $plan.Desktop = [bool]$ui.CbDesktop.IsChecked
        $plan.FolderMenu = [bool]$ui.CbFolder.IsChecked; $plan.UpdateCheck = [bool]$ui.CbUpdates.IsChecked
        $plan.Preset = if ($ui.RbUltra.IsChecked) { 'ultra' } elseif ($ui.RbLight.IsChecked) { 'light' } else { 'high' }
        $plan.SubLangs = $ui.TbSubs.Text.Trim(); $plan.AudioLangs = $ui.TbAudio.Text.Trim()
        $plan.Without = @()
        if (-not $ui.CbModernz.IsChecked) { $plan.Without += 'modernz' }
        if (-not $ui.CbThumbs.IsChecked) { $plan.Without += 'thumbnails' }
        if (-not $ui.CbEffects.IsChecked) { $plan.Without += 'effects' }
        if (-not $ui.CbResume.IsChecked) { $plan.Without += 'resume' }
    }

    $describe = {
        $lines = @()
        $haveMpv = Test-Path -LiteralPath (Join-Path $plan.MpvDir 'mpv.exe')
        if (-not $haveMpv -and $plan.InstallMpv) { $lines += "Install mpv into $($plan.MpvDir)" }
        elseif (-not $haveMpv) { $lines += 'mpv is not installed (the config will be ready for it)' }
        if ($existingConfig) { $lines += "Back up your current config ($($plan.ConfigDir))" }
        $lines += "Install this config into $($plan.ConfigDir)"
        $lines += "Picture quality: $($plan.Preset)"
        $lines += "Subtitle languages: $(if ($plan.SubLangs) { $plan.SubLangs } else { 'none' });  audio: $(if ($plan.AudioLangs) { $plan.AudioLangs } else { 'the file''s default' })"
        $lines += "Subtitle font: $($SubtitleFonts[$plan.SubFont].Name)$(if ($plan.Fonts) { ' (download and install it)' })"
        $featureNames = @{ modernz = 'modern controls'; thumbnails = 'seekbar thumbnails'; effects = 'video effects panel'; resume = 'resume prompt' }
        if ($plan.Without.Count) { $lines += "Leave out: $(($plan.Without | ForEach-Object { $featureNames[$_] }) -join ', ')" }
        if ($plan.WebVideos) { $lines += 'Install yt-dlp for web videos' }
        if ($plan.DefaultPlayer) { $lines += 'Register mpv as a media player and open Default apps' }
        $shortcuts = @(); if ($plan.StartMenu) { $shortcuts += 'Start menu' }; if ($plan.Desktop) { $shortcuts += 'desktop' }
        if ($shortcuts) { $lines += "Shortcuts: $($shortcuts -join ' and ')" }
        if ($plan.FolderMenu) { $lines += '"Play with mpv" for folders' }
        $lines += "Daily update check: $(if ($plan.UpdateCheck) { 'on' } else { 'off' })"
        $lines += 'Uninstaller next to mpv.exe'
        $ui.Summary.Children.Clear()
        foreach ($line in $lines) {
            $row = New-Object Windows.Controls.Grid -Property @{ Margin = '0,0,0,7' }
            [void]$row.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width = 22 }))
            [void]$row.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition))
            $dot = New-Object Windows.Shapes.Ellipse -Property @{ Width = 6; Height = 6; Fill = (& $brush 'Accent'); VerticalAlignment = 'Top'; Margin = '0,8,0,0'; HorizontalAlignment = 'Left' }
            $text = New-Object Windows.Controls.TextBlock -Property @{ Text = $line; TextWrapping = 'Wrap' }
            [Windows.Controls.Grid]::SetColumn($text, 1)
            [void]$row.Children.Add($dot); [void]$row.Children.Add($text)
            [void]$ui.Summary.Children.Add($row)
        }
    }

    # The install runs in a background runspace (so the window stays responsive) that loads this
    # same script; its log lines come back through a synchronized list read by a timer.
    $start = {
        $state.Sync = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList))
        $state.Worker = [PowerShell]::Create()
        [void]$state.Worker.AddScript({
            param($ScriptPath, $Plan, $Sync)
            . $ScriptPath
            $script:LogSink = $Sync
            Invoke-Install $Plan
        }).AddArgument($PSCommandPath).AddArgument($plan).AddArgument($state.Sync)
        $state.Handle = $state.Worker.BeginInvoke()
        $state.Timer = New-Object Windows.Threading.DispatcherTimer -Property @{ Interval = [TimeSpan]::FromMilliseconds(150) }
        $state.Timer.Add_Tick({
            $sync = $state.Sync
            while ($sync.Count) { $ui.Log.AppendText($sync[0] + "`r`n"); $sync.RemoveAt(0); $ui.Log.ScrollToEnd() }
            if ($state.Handle.IsCompleted) {
                $state.Timer.Stop()
                $result = $state.Worker.EndInvoke($state.Handle)
                while ($sync.Count) { $ui.Log.AppendText($sync[0] + "`r`n"); $sync.RemoveAt(0) }
                $ui.Log.ScrollToEnd()
                $state.Ok = [bool]($result | Select-Object -Last 1)
                $state.Done = $true
                & $show
                $ui.Progress.IsIndeterminate = $false; $ui.Progress.Value = 100
                $ui.Progress.Foreground = $(if ($state.Ok) { & $brush 'Good' } else { & $brush 'Bad' })
                $ui.TitleIcon.Text = [string][char]$(if ($state.Ok) { 0xE930 } else { 0xE783 })
                $ui.TitleIcon.Foreground = $(if ($state.Ok) { & $brush 'Good' } else { & $brush 'Bad' })
                $ui.TitleIcon.Visibility = 'Visible'
                $ui.PageTitle.Text = if ($state.Ok) { 'Done' } else { 'Setup stopped' }
                $ui.PageSubtitle.Text = if ($state.Ok) {
                    if ($plan.DefaultPlayer) { 'Click Finish, then choose mpv on the Default apps page that opens' } else { 'mpv is ready to use' }
                } else { 'Nothing else was changed after the step that failed; see the log' }
                $ui.CbOpen.Visibility = $(if ($state.Ok -and (Test-Path -LiteralPath (Join-Path $plan.MpvDir 'mpv.exe'))) { 'Visible' } else { 'Collapsed' })
            }
        })
        $state.Timer.Start()
    }

    $ui.BtnNext.Add_Click({
        & $showProblem ''
        if ($state.Page -eq $installPage) {
            if ($state.Ok -and $ui.CbOpen.Visibility -eq 'Visible' -and $ui.CbOpen.IsChecked) { Start-Process (Join-Path $plan.MpvDir 'mpv.exe') }
            if ($state.Ok -and $plan.DefaultPlayer) {
                try { Start-Process 'ms-settings:defaultapps?registeredAppUser=mpv' } catch { Start-Process 'ms-settings:defaultapps' }
            }
            $window.Close(); return
        }
        & $collect
        if ($state.Page -eq 3 -and -not ((Test-Languages $plan.SubLangs) -and (Test-Languages $plan.AudioLangs))) {
            & $showProblem 'Languages must be codes separated by commas, for example eng,en or jpn,ja.'
            return
        }
        if ($state.Page -eq $summaryPage) {
            if (Get-Process mpv -ErrorAction SilentlyContinue) { & $showProblem 'mpv is running. Close it, then click Install again.'; return }
            $state.Page = $installPage; & $show; & $start; return
        }
        $state.Page++
        if ($state.Page -eq $summaryPage) { & $describe }
        & $show
    })
    $ui.BtnBack.Add_Click({ & $showProblem ''; $state.Page--; & $show })
    $ui.BtnCancel.Add_Click({ $window.Close() })
    $window.Add_Closing({ param($s, $e) if ($state.Page -eq $installPage -and -not $state.Done) { $e.Cancel = $true } })

    & $show
    [void]$window.ShowDialog()
}

#endregion

# Loaded with ". install.ps1" (the setup window's background worker, or tests): define only.
if ($MyInvocation.InvocationName -eq '.') { return }

if ($Silent) {
    $ok = Invoke-Install (New-Plan)
    exit $(if ($ok) { 0 } else { 1 })
}
Show-Wizard
