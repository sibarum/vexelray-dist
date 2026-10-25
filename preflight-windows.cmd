@echo off
rem A preflight of Windows alone, from a double-click: built, started and installed on this computer, with no Linux
rem VM and nothing published (release-preflight.ps1 -WindowsOnly). Arguments pass through (preflight-windows.cmd -SkipBuild).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0release-preflight.ps1" -WindowsOnly %*
echo.
pause
