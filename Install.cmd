@echo off
setlocal DisableDelayedExpansion
if exist "%~dp0package-manifest.json" goto packaged
chcp 65001 >nul
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\development-maintenance.ps1" -Operation Install %*
set "BAP_EXIT=%errorlevel%"
pause
exit /b %BAP_EXIT%
:packaged
set "BAP_BOOTLOG=%LOCALAPPDATA%\BetterAstralParty\Logs"
if not exist "%BAP_BOOTLOG%" mkdir "%BAP_BOOTLOG%" 2>nul
if not exist "%BAP_BOOTLOG%" set "BAP_BOOTLOG=%TEMP%\BetterAstralParty"
if not exist "%BAP_BOOTLOG%" mkdir "%BAP_BOOTLOG%" 2>nul
set "BAP_BOOTLOG=%BAP_BOOTLOG%\Bootstrap-%RANDOM%-%RANDOM%.log"
>"%BAP_BOOTLOG%" echo BAP-BOOTSTRAP-START: If this is the last line, capture the console error.
if not exist "%BAP_BOOTLOG%" (
    if not exist "%TEMP%\BetterAstralParty" mkdir "%TEMP%\BetterAstralParty" 2>nul
    set "BAP_BOOTLOG=%TEMP%\BetterAstralParty\Bootstrap-%RANDOM%-%RANDOM%.log"
)
if not exist "%BAP_BOOTLOG%" >"%BAP_BOOTLOG%" echo BAP-BOOTSTRAP-START: Capture console errors if detailed logs are unavailable.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\install-bootstrap.ps1" %*
set "BAP_EXIT=%errorlevel%"
if not "%BAP_EXIT%"=="0" (
    >>"%BAP_BOOTLOG%" echo BAP-BOOTSTRAP-FAILED: PowerShell or installer did not complete. See the console and detailed logs.
    echo Bootstrap log: "%BAP_BOOTLOG%"
    echo Installation was not completed. See the error above.
    pause
    exit /b %BAP_EXIT%
)
>>"%BAP_BOOTLOG%" echo BAP-BOOTSTRAP-OK
pause
exit /b 0
