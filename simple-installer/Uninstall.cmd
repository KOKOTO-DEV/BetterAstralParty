@echo off
setlocal DisableDelayedExpansion
cd /d "%~dp0"
"%~dp0BetterAstralParty.Setup.exe" uninstall %*
set "RET=%ERRORLEVEL%"
pause
exit /b %RET%
