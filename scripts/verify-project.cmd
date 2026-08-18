@echo off
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0verify-project.ps1" %*
exit /b %ERRORLEVEL%
