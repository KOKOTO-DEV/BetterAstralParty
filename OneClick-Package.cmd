@echo off
setlocal DisableDelayedExpansion
cd /d "%~dp0"
echo BetterAstralParty - Simple Offline Installer Packager
echo Existing compiled export and original 1.2.1 installer are auto-detected when unique.
echo No admin permissions or security exclusions are requested.
where py.exe >nul 2>nul
if not errorlevel 1 (
  py -3 "%~dp0tools\oneclick-package.py" %*
) else (
  where python.exe >nul 2>nul
  if errorlevel 1 (echo Python 3 required. & set "RET=1" & goto end)
  python "%~dp0tools\oneclick-package.py" %*
)
set "RET=%ERRORLEVEL%"
:end
if not "%RET%"=="0" echo Packaging failed. No game files changed.
pause
exit /b %RET%
