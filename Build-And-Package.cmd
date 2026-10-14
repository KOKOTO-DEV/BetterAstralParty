@echo off
setlocal DisableDelayedExpansion
cd /d "%~dp0"
echo BetterAstralParty R6 - ONE CLICK SOURCE BUILD + SIMPLE OFFLINE INSTALLER
 echo Uses only original validated release loader, plugin source and Windows .NET compilers.
echo Auto-detects Steam INT game folder and original release when possible.
where py.exe >nul 2>nul
if not errorlevel 1 (
  py -3 "%~dp0tools\oneclick-package.py" --compile %*
) else (
  where python.exe >nul 2>nul
  if errorlevel 1 (echo Python 3 required. & set "RET=1" & goto end)
  python "%~dp0tools\oneclick-package.py" --compile %*
)
set "RET=%ERRORLEVEL%"
:end
if not "%RET%"=="0" echo Build or packaging failed. No game files changed.
pause
exit /b %RET%
