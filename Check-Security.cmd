@echo off
setlocal DisableDelayedExpansion
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -File "%~dp0tools\check-security.ps1" -Folder "%~dp0"
set "BAP_EXIT=%errorlevel%"
pause
exit /b %BAP_EXIT%
