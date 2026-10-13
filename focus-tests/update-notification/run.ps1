param(
    [Parameter(Mandatory)][string]$DotnetRoot,
    [Parameter(Mandatory)][string]$BepInExRoot,
    [Parameter(Mandatory)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
$dotnet = Join-Path ([IO.Path]::GetFullPath($DotnetRoot)) 'dotnet.exe'
$loader = [IO.Path]::GetFullPath($BepInExRoot)
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $output) { throw 'Fresh fixture output directory required.' }
$null = [IO.Directory]::CreateDirectory($output)
$env:DOTNET_CLI_HOME = Join-Path $output 'dotnet-home'
$env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_GENERATE_ASPNET_CERTIFICATE = 'false'
$env:DOTNET_ADD_GLOBAL_TOOLS_TO_PATH = 'false'
$env:DOTNET_CLI_UI_LANGUAGE = 'en'
$project = Join-Path $PSScriptRoot 'PopupFixtures.csproj'
$properties = @("-p:BepInExRoot=$loader", "-p:BaseIntermediateOutputPath=$output/obj/", "-p:NuGetPackages=$output/packages", '-p:NuGetAudit=false')
& $dotnet restore $project --configfile (Join-Path $PSScriptRoot 'offline-nuget.config') @properties
if ($LASTEXITCODE) { throw "Fixture restore failed $LASTEXITCODE" }
$products = Join-Path $output 'products'
& $dotnet build $project -c Release --no-restore -o $products @properties
if ($LASTEXITCODE) { throw "Fixture build failed $LASTEXITCODE" }
& $dotnet (Join-Path $products 'PopupFixtures.dll')
if ($LASTEXITCODE) { throw "Fixture failed $LASTEXITCODE" }
