[CmdletBinding()]
param([string]$DotnetRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$projectRoot=[IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$stage=Join-Path $projectRoot ('artifacts/hbn-'+[guid]::NewGuid().ToString('N').Substring(0,8))
if(Test-Path -LiteralPath $stage){throw 'Fresh isolated artifact path required'}
$null=[IO.Directory]::CreateDirectory($stage)
if(!$DotnetRoot){$DotnetRoot=Join-Path $projectRoot '.dotnet'}
$dotnet=Join-Path $DotnetRoot 'dotnet.exe'
$csc=Join-Path $DotnetRoot 'sdk/8.0.425/Roslyn/bincore/csc.dll'
$framework=Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319'
$sources=@('tools/test-history-binding.ps1','focus-tests/history-binding/HistoryBindingFixture.csproj','focus-tests/history-binding/HistoryBindingFixture.cs','focus-tests/history-binding/MetadataPlugin.cs','updater-safety-tests/InertProcess.cs','updater-safety-tests/CompatibilityFixtureData.cs','diagnostics/DiagnosticBundle.cs','diagnostics/MinimalDiagnosticProjection.cs')
$sources+=@(foreach($folder in @('updater','src/Observability')){Get-ChildItem -LiteralPath (Join-Path $projectRoot $folder) -File -Filter '*.cs'|Where-Object {$_.Name -ne 'UpdateHelperProgram.cs'}|ForEach-Object {$_.FullName.Substring($projectRoot.Length+1).Replace('\','/')}})
$pins=@{};foreach($source in $sources){$pins[$source]=(Get-FileHash -LiteralPath (Join-Path $projectRoot $source) -Algorithm SHA256).Hash}
$prior=@{};foreach($name in @('DOTNET_GENERATE_ASPNET_CERTIFICATE','DOTNET_CLI_TELEMETRY_OPTOUT','DOTNET_SKIP_FIRST_TIME_EXPERIENCE','DOTNET_CLI_HOME','NUGET_PACKAGES')){$prior[$name]=[Environment]::GetEnvironmentVariable($name,'Process')}
function Step([string]$Name,[string[]]$Arguments){& $dotnet @Arguments *> (Join-Path $stage ($Name+'.log'));if($LASTEXITCODE -ne 0){throw ($Name+' failed; retain isolated log: '+$stage)}}
try{
    $env:DOTNET_GENERATE_ASPNET_CERTIFICATE='false';$env:DOTNET_CLI_TELEMETRY_OPTOUT='1';$env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1';$env:DOTNET_CLI_HOME=Join-Path $stage 'dotnet-home';$env:NUGET_PACKAGES=Join-Path $stage 'packages'
    $bin=Join-Path $stage 'bin';$null=[IO.Directory]::CreateDirectory($bin)
    $compile=@($csc,'/nologo','/noconfig','/nostdlib+','/langversion:latest','/platform:x64','/deterministic+',('/reference:'+(Join-Path $framework 'mscorlib.dll')),('/reference:'+(Join-Path $framework 'System.dll')))
    $template=[IO.File]::ReadAllText((Join-Path $projectRoot 'focus-tests/history-binding/MetadataPlugin.cs'))
    if(([regex]::Matches($template,'"1\.2\.1"')).Count -ne 1){throw 'Exact inert metadata substitution required'}
    $images=@();foreach($version in @('1.2.1','1.2.2-rc.1','1.2.3','1.2.4','1.2.5')){
        $metadata=Join-Path $stage ('metadata-'+$version+'.cs');[IO.File]::WriteAllText($metadata,$template.Replace('"1.2.1"','"'+$version+'"'))
        $image=Join-Path $bin ('metadata-'+$version+'.dll');Step ('metadata-'+$version) ($compile+@('/target:library',('/out:'+$image),$metadata));$images+=@($image)
    }
    $inert=Join-Path $bin 'InertProcess.exe';Step 'inert' ($compile+@('/target:exe','/main:InertProcess',('/out:'+$inert),(Join-Path $projectRoot 'updater-safety-tests/InertProcess.cs')))
    $obj=(Join-Path $stage 'obj/') -replace '\\','/'
    $common=@("-p:BaseIntermediateOutputPath=$obj","-p:MSBuildProjectExtensionsPath=$obj",'-p:UseSharedCompilation=false','-p:NuGetAudit=false')
    $project=Join-Path $projectRoot 'focus-tests/history-binding/HistoryBindingFixture.csproj'
    Step 'restore' (@('restore',$project,'--configfile',(Join-Path $projectRoot 'NuGet.Config'))+$common)
    Step 'build' (@('build',$project,'--no-restore','-c','Release','-o',$bin)+$common)
    & $dotnet (Join-Path $bin 'HistoryBindingFixture.dll') (Join-Path $stage 'f') $inert @images *> (Join-Path $stage 'fixture.log')
    $exit=$LASTEXITCODE;$output=Get-Content -LiteralPath (Join-Path $stage 'fixture.log');$output|ForEach-Object {Write-Host $_}
    if($output.Count -eq 0){throw 'Native fixture produced no result'}
    $result=$output[-1]|ConvertFrom-Json
    $unchanged=$true;foreach($source in $sources){if((Get-FileHash -LiteralPath (Join-Path $projectRoot $source) -Algorithm SHA256).Hash -cne $pins[$source]){$unchanged=$false}}
    $report=[ordered]@{passed=($exit -eq 0 -and $result.passed -and $unchanged);sourceUnchanged=$unchanged;exitCode=$exit;scratch=$stage;sourceSha256=$pins;result=$result;productionPrivateKeyOpened=$false;actualGameSteamOrProductMainExecuted=$false;remoteOrDistributionWrites=$false}
    $json=$report|ConvertTo-Json -Depth 8;[IO.File]::WriteAllText((Join-Path $stage 'test-results.json'),$json,[Text.UTF8Encoding]::new($false));$json
    if(!$report.passed){throw ('Native history binding fixture failed; evidence retained: '+$stage)}
}finally{foreach($name in $prior.Keys){[Environment]::SetEnvironmentVariable($name,$prior[$name],'Process')}}
