@echo off
rem A preflight release, from a double-click: release-preflight.ps1 says what it does. Arguments pass through
rem (release-preflight.cmd -LocalOnly).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0release-preflight.ps1" %*
echo.
pause
