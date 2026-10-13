@echo off
rem Opens the setup window for this mpv config.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0installer\install.ps1"
