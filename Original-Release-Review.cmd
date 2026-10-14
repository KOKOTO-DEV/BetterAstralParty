@echo off
setlocal DisableDelayedExpansion
chcp 65001 >nul
set "BAP_PWSH="
if defined ProgramW6432 if exist "%ProgramW6432%\PowerShell\7\pwsh.exe" set "BAP_PWSH=%ProgramW6432%\PowerShell\7\pwsh.exe"
if not defined BAP_PWSH if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "BAP_PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not defined BAP_PWSH for /f "delims=" %%P in ('where pwsh.exe 2^>nul') do if not defined BAP_PWSH set "BAP_PWSH=%%P"
if not defined BAP_PWSH (
 echo PowerShell 7 x64 required.
 pause
 exit /b 1
)
echo BetterAstralParty ORIGINAL 1.2.1 installer integrated build
 echo This produces an UNAPPROVED candidate without authorized signing inputs.
 echo No installation or Steam modification is performed here.
set /p "BASE=Original complete 1.2.1 installer folder (has package-manifest.json): "
set /p "LOADERZIP=Clean BepInEx 788 upstream ZIP file: "
set /p "EXISTING=Existing compiled export folder (leave blank to build now): "
set /p "STAGE=New stage label (example: integrated01): "
if "%BASE%"=="" exit /b 1
if "%LOADERZIP%"=="" exit /b 1
if "%STAGE%"=="" exit /b 1
if "%EXISTING%"=="" goto compile
"%BAP_PWSH%" -NoProfile -File "%~dp0tools\build-integrated.ps1" -OriginalRelease "%BASE%" -UpstreamArchive "%LOADERZIP%" -Stage "%STAGE%" -BuildDirectory "%EXISTING%"
goto finished
:compile
set /p "GAME=INT game root (8vJXnINT): "
set /p "LOADER=Extracted clean BepInEx 788 root: "
if "%GAME%"=="" exit /b 1
if "%LOADER%"=="" exit /b 1
"%BAP_PWSH%" -NoProfile -File "%~dp0tools\build-integrated.ps1" -OriginalRelease "%BASE%" -UpstreamArchive "%LOADERZIP%" -Stage "%STAGE%" -GameRoot "%GAME%" -BepInExRoot "%LOADER%"
:finished
set "RET=%ERRORLEVEL%"
if not "%RET%"=="0" echo Integrated pipeline failed. No game files were changed.
pause
exit /b %RET%
