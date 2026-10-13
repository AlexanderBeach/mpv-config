@echo off
rem Removes this mpv config, or mpv and everything the setup added. A window asks which first.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0uninstall.ps1"
