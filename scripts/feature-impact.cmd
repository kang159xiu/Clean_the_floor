@echo off
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0feature-impact.ps1" %*
exit /b %ERRORLEVEL%
