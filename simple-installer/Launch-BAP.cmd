@echo off
setlocal DisableDelayedExpansion
cd /d "%~dp0"
if not exist "AstralParty_INT.exe" (echo This launcher must be in the Astral Party INT game folder.& pause& exit /b 1)
if not exist "BetterAstralParty.simple-install.txt" (echo Local BAP installation receipt missing.& pause& exit /b 1)
if not exist "BepInEx\plugins\BetterAstralParty\BetterAstralParty.dll" (echo BAP plugin not installed.& pause& exit /b 1)
if not exist "BetterAstralParty.Setup.exe" (echo Local BAP launch checker is missing. Reinstall this package.& pause& exit /b 1)
"%~dp0BetterAstralParty.Setup.exe" launch "%~dp0"
set "RET=%ERRORLEVEL%"
if not "%RET%"=="0" (echo BetterAstralParty launch check failed. No compatibility gate was bypassed.& pause)
exit /b %RET%
