# Shows the Windows "Open" dialog on top of mpv and writes the chosen files (one per line, UTF-8)
# to $Out. Nothing is written when the dialog is cancelled. Closes by itself if mpv ($MpvPid) exits.
param([string]$Out, [string]$Dir, [int]$MpvPid = 0)

Add-Type -AssemblyName System.Windows.Forms, System.Drawing

$exts = 'mkv mp4 m4v avi mov wmv webm flv ts m2ts mts mpg mpeg vob ogv 3gp rmvb ' +
        'mp3 flac m4a aac opus ogg oga wav wma ape alac mka ' +
        'png jpg jpeg webp gif bmp tif tiff avif jxl ' +
        'iso m3u m3u8 pls cue'
$pattern = ($exts -split ' ' | ForEach-Object { "*.$_" }) -join ';'

# An invisible, always-on-top owner keeps the dialog above mpv, even in fullscreen.
$owner = New-Object System.Windows.Forms.Form -Property @{
    TopMost = $true; ShowInTaskbar = $false; Opacity = 0
    FormBorderStyle = 'None'; StartPosition = 'CenterScreen'; Size = New-Object System.Drawing.Size(1, 1)
}
$owner.Show()
$owner.Activate()

$dialog = New-Object System.Windows.Forms.OpenFileDialog -Property @{
    Title = 'Open'; Multiselect = $true; Filter = "Media files|$pattern|All files|*.*"
}
if ($Dir -and (Test-Path -LiteralPath $Dir)) { $dialog.InitialDirectory = $Dir }

# Don't outlive mpv: a background thread waits for mpv to exit and then ends this process,
# which closes the dialog (a timer can't, as the dialog blocks this thread).
if ($MpvPid) {
    $watch = [PowerShell]::Create().AddScript({
        param($id)
        try { (Get-Process -Id $id -ErrorAction Stop).WaitForExit() } catch { }
        [Environment]::Exit(0)
    }).AddArgument($MpvPid)
    $null = $watch.BeginInvoke()
}

$picked = $dialog.ShowDialog($owner) -eq [System.Windows.Forms.DialogResult]::OK
$owner.Close()
if ($picked) {
    [IO.File]::WriteAllText($Out, ($dialog.FileNames -join "`n"), (New-Object Text.UTF8Encoding($false)))
}
