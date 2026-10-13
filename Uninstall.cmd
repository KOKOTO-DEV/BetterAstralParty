@echo off
setlocal DisableDelayedExpansion
if exist "%~dp0package-manifest.json" goto packaged
chcp 65001 >nul
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\development-maintenance.ps1" -Operation Uninstall %*
set "BAP_EXIT=%errorlevel%"
pause
exit /b %BAP_EXIT%
:packaged
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\uninstall.ps1" %*
set "BAP_EXIT=%errorlevel%"
if not "%BAP_EXIT%"=="0" (
    echo Uninstall failed. Keep the error and backup path shown above.
    pause
    exit /b %BAP_EXIT%
)
pause
exit /b 0
