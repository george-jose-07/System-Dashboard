@echo off
rem Starts System Dashboard as a hidden, detached PowerShell process.
rem If a copy is already running it just shows that copy instead.
start "" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0SystemDashboard.ps1"
exit /b 0