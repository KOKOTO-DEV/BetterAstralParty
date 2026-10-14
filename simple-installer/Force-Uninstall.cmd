@echo off
setlocal DisableDelayedExpansion
cd /d "%~dp0"
"%~dp0BetterAstralParty.Setup.exe" force-uninstall %*
set "RET=%ERRORLEVEL%"
if not "%RET%"=="0" echo Force uninstall was not fully completed. Read the error above.
pause
exit /b %RET%
