param([string]$DotnetRoot,[string]$BepInExRoot,[string]$OutputDirectory)
$ErrorActionPreference='Stop'
$testRoot=Split-Path -Parent $PSScriptRoot
if(!$DotnetRoot){$DotnetRoot=Join-Path $testRoot '.dotnet'}
if(!$BepInExRoot){$BepInExRoot=Join-Path $testRoot '.deps/bepinex'}
if(!$OutputDirectory){$OutputDirectory=Join-Path $testRoot ('artifacts/channel-transition-'+[guid]::NewGuid().ToString('N'))}
$testOutput=[IO.Path]::GetFullPath($OutputDirectory)
if(!$testOutput.StartsWith((Join-Path $testRoot 'artifacts')+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)-or(Test-Path -LiteralPath $testOutput)){throw 'Fresh artifact-only test output required.'}
& (Join-Path $testRoot 'focus-tests/channel-transition/run.ps1') -DotnetRoot $DotnetRoot -BepInExRoot $BepInExRoot -OutputDirectory (Join-Path $testOutput 'policy')
& (Join-Path $testRoot 'focus-tests/update-notification/run.ps1') -DotnetRoot $DotnetRoot -BepInExRoot $BepInExRoot -OutputDirectory (Join-Path $testOutput 'popup')
Write-Host 'PASS: symmetric explicit transition policy/coordinator and native-popup source fixtures. No live endpoint, operational key, game, Steam or installation.'
