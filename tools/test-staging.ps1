param([string]$DotnetRoot)
$ErrorActionPreference='Stop'
$project=Split-Path -Parent $PSScriptRoot
if(!$DotnetRoot){$DotnetRoot=Join-Path $project '.dotnet'}
$dotnet=Join-Path $DotnetRoot 'dotnet.exe'
$stage=Join-Path $project ('artifacts/automatic-update-development/staging-'+[guid]::NewGuid().ToString('N').Substring(0,8))
if(Test-Path -LiteralPath $stage){throw 'Fresh staging fixture required.'}
$null=[IO.Directory]::CreateDirectory($stage)
$names=@('DOTNET_CLI_HOME','DOTNET_GENERATE_ASPNET_CERTIFICATE','DOTNET_CLI_TELEMETRY_OPTOUT','DOTNET_SKIP_FIRST_TIME_EXPERIENCE')
$prior=@{};foreach($name in $names){$prior[$name]=[Environment]::GetEnvironmentVariable($name,'Process')}
Push-Location $project
try {
    $env:DOTNET_CLI_HOME=Join-Path $stage 'dotnet-home';$env:DOTNET_GENERATE_ASPNET_CERTIFICATE='false';$env:DOTNET_CLI_TELEMETRY_OPTOUT='1';$env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1'
    $obj=(Join-Path $stage 'obj')+[IO.Path]::DirectorySeparatorChar
    & $dotnet build (Join-Path $project 'updater-safety-tests/BetterAstralParty.StagingTests.csproj') --configuration Release --configfile (Join-Path $project 'NuGet.Config') -o (Join-Path $stage 'bin') "-p:BaseIntermediateOutputPath=$obj" "-p:MSBuildProjectExtensionsPath=$obj" -p:UseSharedCompilation=false -p:NuGetAudit=false *> (Join-Path $stage 'build.log')
    if($LASTEXITCODE -ne 0){throw ('Staging fixture build failed: '+$stage)}
    & $dotnet (Join-Path $stage 'bin/BetterAstralParty.StagingTests.dll') (Join-Path $stage 'fixtures') *> (Join-Path $stage 'test.log')
    $exitCode=$LASTEXITCODE;Get-Content -LiteralPath (Join-Path $stage 'test.log')|ForEach-Object {Write-Host $_}
    if($exitCode -ne 0){throw ('Staging fixture failed: '+$stage)}
} finally {
    Pop-Location
    foreach($name in $names){[Environment]::SetEnvironmentVariable($name,$prior[$name],'Process')}
}
