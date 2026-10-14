@echo off
setlocal DisableDelayedExpansion
cd /d "%~dp0"
"%~dp0BetterAstralParty.Setup.exe" install %*
set "RET=%ERRORLEVEL%"
if not "%RET%"=="0" (echo Installation stopped without success.)
pause
exit /b %RET%
