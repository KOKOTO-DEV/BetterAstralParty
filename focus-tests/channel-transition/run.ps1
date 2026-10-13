param([Parameter(Mandatory)][string]$DotnetRoot,[Parameter(Mandatory)][string]$BepInExRoot,[Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
$testRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$testOutput=[IO.Path]::GetFullPath($OutputDirectory)
if (!$testOutput.StartsWith((Join-Path $testRoot 'artifacts')+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $testOutput)) { throw 'Fresh artifact-only fixture output required.' }
$null=[IO.Directory]::CreateDirectory($testOutput)
$env:DOTNET_CLI_HOME=Join-Path $testOutput 'dotnet-home'
$env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1'; $env:DOTNET_CLI_TELEMETRY_OPTOUT='1'
$env:DOTNET_GENERATE_ASPNET_CERTIFICATE='false'; $env:DOTNET_ADD_GLOBAL_TOOLS_TO_PATH='false'; $env:DOTNET_CLI_UI_LANGUAGE='en'
$testDotnet=Join-Path ([IO.Path]::GetFullPath($DotnetRoot)) 'dotnet.exe'
$testProject=Join-Path $PSScriptRoot 'ChannelTransitionTests.csproj'
$testProperties=@('-p:NuGetAudit=false',"-p:BepInExRoot=$([IO.Path]::GetFullPath($BepInExRoot))","-p:BaseIntermediateOutputPath=$testOutput/obj/","-p:NuGetPackages=$testOutput/packages")
& $testDotnet restore $testProject --configfile (Join-Path $PSScriptRoot 'offline-nuget.config') @testProperties
if ($LASTEXITCODE) { throw 'Offline transition fixture restore failed.' }
& $testDotnet build $testProject -c Release --no-restore -o (Join-Path $testOutput 'products') @testProperties
if ($LASTEXITCODE) { throw 'Transition fixture build failed.' }
& $testDotnet (Join-Path $testOutput 'products/ChannelTransitionTests.dll') $testOutput
if ($LASTEXITCODE) { throw 'Transition fixture failed; outputs preserved.' }
