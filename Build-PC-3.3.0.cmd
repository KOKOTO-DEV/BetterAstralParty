@echo off
setlocal
cd /d "%~dp0"
py -B tools\oneclick-package.py --compile --compatibility-review "%~dp0compatibility-reviews\pc-3.3.0-local.json" --output "%~dp0..\BetterAstralParty-1.2.1-PC-3.3.0-Local.zip" %*
if errorlevel 1 exit /b 1
endlocal
