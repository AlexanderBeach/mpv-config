@echo off
rem Double-click to update mpv. Options (see mpv-update.ps1): -CheckOnly, -Rollback, -Force, -Variant, -MpvDir
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0mpv-update.ps1" %*
