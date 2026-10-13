@echo off
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\diagnostics.ps1" -Action Collect
set "BAP_DIAGNOSTICS_EXIT=%ERRORLEVEL%"
pause
exit /b %BAP_DIAGNOSTICS_EXIT%
