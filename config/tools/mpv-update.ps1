<#
.SYNOPSIS
    Updates a Windows build of mpv in place, keeping the previous version for rollback.

.DESCRIPTION
    Finds mpv (or uses -MpvDir) and compares it with the latest release of a Windows build feed
    on GitHub. When a newer build is out, it:
      1. downloads it and checks it against the SHA-256 that GitHub publishes,
      2. unpacks it to a temporary folder and test-plays a short pattern with your own mpv
         settings, so a build that cannot play on this PC is never installed,
      3. moves the current version into "<mpv folder>\previous-version" and installs the new one.
    -Rollback swaps the previous version back in (run it again to undo the rollback).
    Administrator rights are requested only for the final file swap, and only when the mpv
    folder is not writable (for example under Program Files).

.PARAMETER MpvDir
    Folder containing mpv.exe. Default: found automatically (this script's folder, PATH, the
    location recorded by "mpv --register", or the usual install folders).
.PARAMETER Repo
    GitHub repository that publishes the builds. Default: zhongfly/mpv-winbuild.
    shinchiro/mpv-winbuild-cmake uses the same file naming and works too.
.PARAMETER Variant
    Build flavour: x86_64, x86_64-v3 (CPUs with AVX2) or aarch64. Default: matches this PC.
.PARAMETER CheckOnly
    Only report whether an update is available.
.PARAMETER Rollback
    Restore the version that the last update replaced.
.PARAMETER Force
    Reinstall even when already up to date.
.PARAMETER Archive
    Install from a local build archive (.7z) instead of downloading.
.PARAMETER WaitForPid
    Wait for this process (a running mpv) to exit before installing.
.PARAMETER Reopen
    Start mpv again when finished, opening -ReopenFile if given.
.PARAMETER ReopenFile
    File to open when mpv is started again.
.PARAMETER NoPause
    Don't wait for Enter before closing.
.PARAMETER Install
    Install mpv into -MpvDir when it isn't there yet (a fresh install, used by the setup wizard).

.EXAMPLE
    .\mpv-update.ps1
.EXAMPLE
    .\mpv-update.ps1 -CheckOnly
.EXAMPLE
    .\mpv-update.ps1 -Rollback
.EXAMPLE
    .\mpv-update.ps1 -Variant x86_64-v3 -MpvDir 'D:\Apps\mpv'
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$MpvDir,
    [string]$Repo = 'zhongfly/mpv-winbuild',
    [ValidateSet('', 'x86_64', 'x86_64-v3', 'aarch64')][string]$Variant = '',
    [switch]$CheckOnly,
    [switch]$Rollback,
    [switch]$Force,
    [string]$Archive,
    [int]$WaitForPid = 0,
    [switch]$Reopen,
    [string]$ReopenFile,
    [switch]$NoPause,
    [switch]$Install,
    # Internal: set when the script relaunches itself with administrator rights.
    [string]$InstallFrom,
    [switch]$Elevated
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$UserAgent = 'mpv-update-script'
$BackupName = 'previous-version'

#region Helpers ----------------------------------------------------------------------------------

function Write-Step([string]$Text) { Write-Host "-> $Text" -ForegroundColor Cyan }

function Exit-Script([int]$Code, [string]$Message) {
    if ($Message) { Write-Host $Message -ForegroundColor $(if ($Code -eq 0) { 'Green' } else { 'Red' }) }
    # Started from mpv (which closed for the update): if it failed, open the current mpv again.
    if ($Code -ne 0 -and $Reopen -and -not $Elevated -and $MpvDir -and (Test-Path -LiteralPath (Join-Path $MpvDir 'mpv.exe'))) { Start-Mpv }
    # Windows opened for us (by mpv, or the elevated helper) close by themselves on success,
    # but stay open to show an error.
    $interactive = $Host.Name -eq 'ConsoleHost' -and [Environment]::UserInteractive -and -not $NoPause
    if ($interactive -and $Code -ne 0) {
        Read-Host 'Press Enter to close' | Out-Null
    } elseif ($interactive -and $Reopen) {
        Write-Host 'This window closes in a few seconds.'
        Start-Sleep -Seconds 4
    } elseif ($interactive -and -not $Elevated) {
        Read-Host 'Press Enter to close' | Out-Null
    }
    exit $Code
}

# Quotes arguments the way Windows programs (and mpv) split their command line.
function ConvertTo-CommandLine([string[]]$Arguments) {
    ($Arguments | ForEach-Object {
        if ($_ -ne '' -and $_ -notmatch '[\s"]') { $_ }
        else { '"' + (($_ -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"' }
    }) -join ' '
}

# Opens mpv again, with the file that was playing when the update started.
function Start-Mpv {
    $exe = Join-Path $MpvDir 'mpv.exe'
    if ($ReopenFile) { Start-Process -FilePath $exe -ArgumentList (ConvertTo-CommandLine @($ReopenFile)) }
    else { Start-Process -FilePath $exe }
}

function Find-MpvDir {
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($MpvDir) {
        $candidates.Add($MpvDir)
    } else {
        # Started from mpv without -MpvDir: the waiting process, if it is still there, says which mpv.
        if ($WaitForPid) {
            $running = Get-Process -Id $WaitForPid -ErrorAction SilentlyContinue
            if ($running -and $running.Path) { $candidates.Add((Split-Path $running.Path)) }
        }
        $candidates.Add($PSScriptRoot)
        # tools\ inside a portable_config folder next to mpv.exe
        $candidates.Add((Split-Path (Split-Path $PSScriptRoot)))
        $onPath = Get-Command mpv.exe -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($onPath) { $candidates.Add((Split-Path $onPath.Source)) }
        foreach ($key in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\mpv',
                         'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\mpv') {
            $location = (Get-ItemProperty $key -ErrorAction SilentlyContinue).InstallLocation
            if ($location) { $candidates.Add($location) }
        }
        $candidates.Add((Join-Path $env:LOCALAPPDATA 'Programs\mpv'))   # the setup wizard's default
        $candidates.Add((Join-Path $env:ProgramFiles 'mpv'))
    }
    foreach ($dir in $candidates) {
        if ($dir -and (Test-Path -LiteralPath (Join-Path $dir 'mpv.exe'))) { return (Resolve-Path -LiteralPath $dir).Path }
    }
    return $null
}

# "mpv v0.41.0-123-gabcdef012 ..." -> @{ Line = ...; Hash = 'abcdef012' }
function Get-MpvVersion([string]$Dir) {
    $exe = Join-Path $Dir 'mpv.com'
    if (-not (Test-Path -LiteralPath $exe)) { $exe = Join-Path $Dir 'mpv.exe' }
    if (-not (Test-Path -LiteralPath $exe)) { return @{ Line = '(not installed)'; Hash = '' } }
    $line = (& $exe --no-config --version 2>$null | Out-String).Trim() -split "`r?`n" | Select-Object -First 1
    $line = $line -replace '\s+Copyright.*$', ''
    $hash = if ($line -match '-g([0-9a-f]{7,})') { $Matches[1] } else { '' }
    return @{ Line = $line; Hash = $hash }
}

function Test-SameBuild([string]$A, [string]$B) {
    if (-not $A -or -not $B) { return $false }
    $n = [Math]::Min($A.Length, $B.Length)
    return $A.Substring(0, $n) -eq $B.Substring(0, $n)
}

function Test-Writable([string]$Dir) {
    try {
        $probe = Join-Path $Dir ('.write-test-' + [guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($probe, '')
        Remove-Item -LiteralPath $probe -Force
        return $true
    } catch { return $false }
}

# Unpacks a .7z build with the tar that comes with Windows 10 and 11, or with 7-Zip if tar can't.
# Returns $true when mpv.exe came out.
function Expand-Build([string]$ArchivePath, [string]$Destination) {
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $tar = Join-Path $env:WINDIR 'System32\tar.exe'
    if (Test-Path -LiteralPath $tar) {
        & $tar -xf $ArchivePath -C $Destination 2>$null
        if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath (Join-Path $Destination 'mpv.exe'))) { return $true }
    }
    $sevenZip = Get-Command 7z.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
    if (-not $sevenZip) {
        foreach ($key in 'HKLM:\SOFTWARE\7-Zip', 'HKCU:\SOFTWARE\7-Zip') {
            $dir = (Get-ItemProperty $key -ErrorAction SilentlyContinue).Path
            if ($dir -and (Test-Path -LiteralPath (Join-Path $dir '7z.exe'))) { $sevenZip = Join-Path $dir '7z.exe'; break }
        }
    }
    if ($sevenZip) {
        & $sevenZip x $ArchivePath "-o$Destination" -y | Out-Null
        return ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath (Join-Path $Destination 'mpv.exe')))
    }
    return $false
}

function Wait-MpvClosed([string]$Dir) {
    if ($WaitForPid) {
        $process = Get-Process -Id $WaitForPid -ErrorAction SilentlyContinue
        if ($process) {
            Write-Step 'Waiting for mpv to close'
            $null = $process.WaitForExit(60000)
        }
    }
    for ($i = 0; $i -lt 30; $i++) {
        $running = Get-Process mpv -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -and (Split-Path $_.Path) -eq $Dir }
        if (-not $running) { return }
        Start-Sleep -Milliseconds 500
    }
    Exit-Script 1 'mpv is still running. Close it and run the update again.'
}

# Plays a short test pattern with the given build and the user's own settings (scripts off).
# Returns $null on success, or why it failed.
function Test-Build([string]$Dir, [string]$WorkDir) {
    $log = Join-Path $WorkDir 'test-playback.log'
    $mpvArgs = @(
        '--load-scripts=no', '--osc=no', '--idle=no', '--keep-open=no', '--pause=no', '--resume-playback=no',
        '--save-position-on-quit=no', '--fullscreen=no', '--window-maximized=no', '--loop-file=no',
        '--loop-playlist=no', '--ao=null', '--frames=48', '--geometry=320x180', '--focus-on=never',
        '--title=mpv update check', "--log-file=$log", 'av://lavfi:testsrc2=s=640x360:r=24:d=5')
    $portable = Join-Path $MpvDir 'portable_config'
    if (Test-Path -LiteralPath $portable) { $mpvArgs = @("--config-dir=$portable") + $mpvArgs }

    $process = Start-Process -FilePath (Join-Path $Dir 'mpv.exe') -ArgumentList (ConvertTo-CommandLine $mpvArgs) -PassThru
    if (-not $process.WaitForExit(30000)) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        return 'the test playback did not finish within 30 seconds'
    }
    if ($process.ExitCode -ne 0) { return "the test playback exited with code $($process.ExitCode)" }
    if (Test-Path -LiteralPath $log) {
        $problems = Select-String -LiteralPath $log -Pattern '\]\[f\]\[|\]\[e\]\[(vo|vd)|DEVICE_LOST' | Select-Object -First 3
        if ($problems) { return 'the test playback reported errors:' + "`n  " + (($problems | ForEach-Object { $_.Line }) -join "`n  ") }
    }
    return $null
}

# Runs this script again with administrator rights for the given extra arguments.
function Invoke-Elevated([string[]]$ExtraArgs) {
    Write-Step 'The mpv folder needs administrator rights; Windows will ask for permission'
    $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-MpvDir', $MpvDir, '-Elevated') + $ExtraArgs
    if ($Install) { $psArgs += '-Install' }
    try {
        $process = Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -PassThru -ArgumentList (ConvertTo-CommandLine $psArgs)
    } catch {
        Exit-Script 1 'Administrator permission was not given, so nothing was changed.'
    }
    return $process.ExitCode
}

#endregion
#region Install and rollback (these run with administrator rights when needed) ------------------

function Install-Staged([string]$Stage) {
    if (-not (Test-Path -LiteralPath $MpvDir)) { New-Item -ItemType Directory -Path $MpvDir | Out-Null }
    $backup = Join-Path $MpvDir $BackupName
    $before = Get-MpvVersion $MpvDir
    if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Recurse -Force }
    New-Item -ItemType Directory -Path $backup | Out-Null
    $items = Get-ChildItem -LiteralPath $Stage -Force
    $moved = New-Object System.Collections.Generic.List[string]    # old items now in the backup
    $placed = New-Object System.Collections.Generic.List[string]   # new items now in the mpv folder
    try {
        foreach ($item in $items) {
            $target = Join-Path $MpvDir $item.Name
            if (Test-Path -LiteralPath $target) {
                Move-Item -LiteralPath $target -Destination $backup
                $moved.Add($item.Name)
            }
        }
        foreach ($item in $items) {
            Move-Item -LiteralPath $item.FullName -Destination $MpvDir
            $placed.Add($item.Name)
        }
    } catch {
        # Put the old version back as it was. Each step on its own, so one locked file can't stop the rest.
        foreach ($name in $placed) { try { Remove-Item -LiteralPath (Join-Path $MpvDir $name) -Recurse -Force } catch { } }
        foreach ($name in $moved) { try { Move-Item -LiteralPath (Join-Path $backup $name) -Destination $MpvDir } catch { } }
        throw
    }
    if ($moved.Count -eq 0) {
        Remove-Item -LiteralPath $backup -Recurse -Force   # fresh install: nothing to keep
    } else {
        Set-Content -LiteralPath (Join-Path $backup 'version.txt') -Value $before.Line -Encoding ASCII
    }
}

function Invoke-Swap {
    $backup = Join-Path $MpvDir $BackupName
    $current = Get-MpvVersion $MpvDir
    $swap = Join-Path $MpvDir ('rollback-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $swap | Out-Null
    $aside = New-Object System.Collections.Generic.List[string]   # current items moved out of the way
    $back = New-Object System.Collections.Generic.List[string]    # previous items moved in
    try {
        foreach ($item in Get-ChildItem -LiteralPath $backup -Force | Where-Object { $_.Name -ne 'version.txt' }) {
            $target = Join-Path $MpvDir $item.Name
            if (Test-Path -LiteralPath $target) { Move-Item -LiteralPath $target -Destination $swap; $aside.Add($item.Name) }
            Move-Item -LiteralPath $item.FullName -Destination $MpvDir
            $back.Add($item.Name)
        }
    } catch {
        foreach ($name in $back) { try { Move-Item -LiteralPath (Join-Path $MpvDir $name) -Destination $backup } catch { } }
        foreach ($name in $aside) { try { Move-Item -LiteralPath (Join-Path $swap $name) -Destination $MpvDir } catch { } }
        try { Remove-Item -LiteralPath $swap -Recurse -Force } catch { }
        throw
    }
    Set-Content -LiteralPath (Join-Path $swap 'version.txt') -Value $current.Line -Encoding ASCII
    Remove-Item -LiteralPath $backup -Recurse -Force
    Rename-Item -LiteralPath $swap -NewName $BackupName
}

#endregion
#region Main -------------------------------------------------------------------------------------

if ($Install) {
    if (-not $MpvDir) { Exit-Script 1 '-Install needs -MpvDir "<folder to install mpv in>".' }
    $MpvDir = [IO.Path]::GetFullPath($MpvDir)
    # Created now if allowed; otherwise the elevated install step creates it.
    try { New-Item -ItemType Directory -Force -Path $MpvDir -ErrorAction Stop | Out-Null } catch { }
} else {
    $MpvDir = Find-MpvDir
    if (-not $MpvDir) {
        Exit-Script 1 ('Could not find mpv.exe. Use Tools > Update mpv... inside mpv, or run' +
                       "`n  update-mpv.cmd -MpvDir `"<the folder that contains mpv.exe>`"")
    }
}

# Elevated helper: only swaps files.
if ($Elevated) {
    try {
        if ($InstallFrom) { Install-Staged $InstallFrom } elseif ($Rollback) { Invoke-Swap }
        Exit-Script 0
    } catch {
        Exit-Script 1 "Failed: $($_.Exception.Message)"
    }
}

function Complete([string]$Message) {
    $registered = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\mpv' -ErrorAction SilentlyContinue
    if ($registered -and $registered.InstallLocation -and
        (Resolve-Path -LiteralPath $registered.InstallLocation -ErrorAction SilentlyContinue).Path -eq $MpvDir) {
        Write-Step 'Updating the Windows registration (file associations)'
        & (Join-Path $MpvDir 'mpv.com') --no-config --register | Out-Null
    }
    if ($Reopen) { Start-Mpv }
    Exit-Script 0 $Message
}

$installed = Get-MpvVersion $MpvDir
Write-Host "mpv folder:  $MpvDir"
Write-Host "Installed:   $($installed.Line)"

if ($Rollback) {
    $backup = Join-Path $MpvDir $BackupName
    if (-not (Test-Path -LiteralPath (Join-Path $backup 'mpv.exe'))) { Exit-Script 1 'There is no previous version to roll back to.' }
    $previous = (Get-Content -LiteralPath (Join-Path $backup 'version.txt') -ErrorAction SilentlyContinue | Select-Object -First 1)
    Write-Host "Previous:    $previous"
    Wait-MpvClosed $MpvDir
    if (Test-Writable $MpvDir) { Invoke-Swap } elseif ((Invoke-Elevated @('-Rollback')) -ne 0) { Exit-Script 1 'Rollback failed; nothing was changed.' }
    Complete "Rolled back to: $((Get-MpvVersion $MpvDir).Line)"
}

if (-not $Variant) { $Variant = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'aarch64' } else { 'x86_64' } }
$work = Join-Path ([IO.Path]::GetTempPath()) ('mpv-update-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null

try {
    if ($Archive) {
        $archivePath = (Resolve-Path -LiteralPath $Archive).Path
        $newHash = if ((Split-Path $archivePath -Leaf) -match '-git-([0-9a-f]+)\.7z$') { $Matches[1] } else { '' }
        $label = Split-Path $archivePath -Leaf
        $digest = $null
    } else {
        Write-Step "Checking $Repo for the latest $Variant build"
        $release = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest" -Headers @{ 'User-Agent' = $UserAgent }
        $pattern = '^mpv-' + [regex]::Escape($Variant) + '-\d{8}-git-([0-9a-f]+)\.7z$'
        $asset = $release.assets | Where-Object { $_.name -match $pattern } | Select-Object -First 1
        if (-not $asset) { Exit-Script 1 "The latest release of $Repo has no $Variant build." }
        $null = $asset.name -match $pattern
        $newHash = $Matches[1]
        $label = $asset.name
        $digest = if ($asset.PSObject.Properties['digest'] -and $asset.digest -match '^sha256:([0-9a-f]{64})$') { $Matches[1] } else { $null }
        Write-Host "Latest:      $($release.tag_name) ($([Math]::Round($asset.size / 1MB, 1)) MB)"

        $upToDate = Test-SameBuild $installed.Hash $newHash
        if ($CheckOnly) { Exit-Script 0 $(if ($upToDate) { 'mpv is up to date.' } else { 'An update is available.' }) }
        if ($upToDate -and -not $Force) { Complete 'mpv is already up to date.' }

        Write-Step "Downloading $label"
        $archivePath = Join-Path $work $asset.name
        Invoke-WebRequest $asset.browser_download_url -OutFile $archivePath -UserAgent $UserAgent -UseBasicParsing
    }

    if ($digest) {
        $actual = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $digest) { Exit-Script 1 'The download does not match the checksum GitHub published; nothing was changed.' }
        Write-Step 'Checksum verified'
    } elseif (-not $Archive -and -not $Force) {
        Exit-Script 1 ('GitHub published no checksum for this build, so it cannot be verified; nothing was changed.' +
                       "`nRun with -Force to install it anyway.")
    }

    Write-Step 'Unpacking'
    $stage = Join-Path $work 'build'
    if (-not (Expand-Build $archivePath $stage)) {
        Exit-Script 1 'The archive could not be unpacked (it needs Windows 10 or newer, or 7-Zip) or has no mpv.exe; nothing was changed.'
    }

    Write-Step 'Test-playing with the new build (a small window opens for a moment)'
    $problem = Test-Build $stage $work
    if ($problem) {
        Exit-Script 1 ("The new build failed its test on this PC, so it was not installed: $problem" +
                       "`nYour current mpv is unchanged.")
    }

    Wait-MpvClosed $MpvDir
    if (Test-Path -LiteralPath (Join-Path $MpvDir 'mpv.exe')) { Write-Step 'Installing (the current version is kept in "previous-version")' }
    else { Write-Step "Installing into $MpvDir" }
    if (Test-Writable $MpvDir) {
        Install-Staged $stage
    } elseif ((Invoke-Elevated @('-InstallFrom', $stage)) -ne 0) {
        Exit-Script 1 'Installing failed; your current mpv is unchanged.'
    }

    $now = Get-MpvVersion $MpvDir
    if ($newHash -and -not (Test-SameBuild $now.Hash $newHash)) {
        Exit-Script 1 "The installed mpv reports $($now.Line), not the new build. Run with -Rollback to restore the previous version."
    }
    if ($installed.Hash) { Complete "Updated to: $($now.Line)`nIf anything misbehaves, run this script with -Rollback." }
    Complete "Installed: $($now.Line)"
} catch {
    # e.g. no internet connection, or GitHub's limit on anonymous requests
    Exit-Script 1 "Failed: $($_.Exception.Message)`nYour current mpv is unchanged."
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

#endregion
