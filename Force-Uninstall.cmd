@echo off
setlocal DisableDelayedExpansion
chcp 65001 >nul
if not exist "%~dp0tools\force-uninstall.ps1" (
  echo Missing tools\force-uninstall.ps1
  exit /b 1
)
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -File "%~dp0tools\force-uninstall.ps1" %*
set "BAP_EXIT=%errorlevel%"
if not "%BAP_EXIT%"=="0" echo Force uninstall did not fully complete. Read the errors above.
pause
exit /b %BAP_EXIT%
