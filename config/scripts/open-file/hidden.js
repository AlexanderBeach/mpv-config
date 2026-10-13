// Runs dialog.ps1 with PowerShell's console hidden and waits for it.
// Arguments: <dialog.ps1> <result file> <mpv process id> [<initial folder>]
var args = WScript.Arguments;
var shell = new ActiveXObject("WScript.Shell");
var cmd = 'powershell.exe -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File "' + args(0) +
          '" -Out "' + args(1) + '" -MpvPid ' + args(2) + ' -Dir "' + (args.length > 3 ? args(3) : "") + '"';
WScript.Quit(shell.Run(cmd, 0, true));
