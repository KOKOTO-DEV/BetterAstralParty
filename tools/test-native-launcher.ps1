param([string]$DotnetRoot)
$ErrorActionPreference='Stop'
$taskRoot=[IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$review=Join-Path $taskRoot 'focus-tests/native-launcher'
$artifactRoot=Join-Path $taskRoot 'artifacts'
if(Get-Process AstralParty_INT,AstralParty_CN -ErrorAction SilentlyContinue){throw 'A named game process is already running; inert fixture was not started.'}
$run=Join-Path $artifactRoot ('nl-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
if(!(Test-Path -LiteralPath $artifactRoot -PathType Container)-or(Test-Path -LiteralPath $run)){throw 'Fresh isolated artifact root required.'}
$null=New-Item -ItemType Directory -Path $run
if(!$DotnetRoot){$DotnetRoot=Join-Path $taskRoot '.dotnet'}
$dotnet=Join-Path $DotnetRoot 'dotnet.exe'
$sdk=@(Get-ChildItem -LiteralPath (Join-Path $DotnetRoot 'sdk') -Directory | Where-Object {Test-Path -LiteralPath (Join-Path $_.FullName 'Roslyn/bincore/csc.dll')} | Sort-Object {[version]$_.Name} -Descending | Select-Object -First 1)
if($sdk.Count -ne 1){throw 'Local Roslyn compiler required.'}
$compiler=Join-Path $sdk[0].FullName 'Roslyn/bincore/csc.dll'
$framework=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'
$identity=& (Join-Path $PSScriptRoot 'build-executable-identity.ps1') -OutputDirectory $run -Role Launcher
$version=[regex]::Match([IO.File]::ReadAllText((Join-Path $taskRoot 'src/Plugin.cs')),'public const string Version = "([^"]+)"').Groups[1].Value
$boundary=Join-Path $run 'FixtureBoundary.cs'
[IO.File]::WriteAllText($boundary,('internal static class FixtureBoundary { internal const string Root = @"'+($run+[IO.Path]::DirectorySeparatorChar).Replace('"','""')+'"; internal const string Version="'+$version+'"; }'))
$source=@((Join-Path $taskRoot 'tools\SteamLauncher.cs'),(Join-Path $taskRoot 'tools\InstallHelperBootstrap.cs'))
$source+=@(Get-ChildItem -LiteralPath (Join-Path $taskRoot 'updater') -Filter '*.cs' -File | Where-Object {$_.Name -notin @('UpdateHelperProgram.cs','ProductionUpdateKeys.cs')} | Sort-Object Name | ForEach-Object FullName)
$source+=@(Get-ChildItem -LiteralPath (Join-Path $taskRoot 'src\Observability') -Filter '*.cs' -File | Sort-Object Name | ForEach-Object FullName)
$source+=Join-Path $taskRoot 'diagnostics\MinimalDiagnosticProjection.cs'
$source+=@($identity,$boundary,(Join-Path $review 'FixtureEntry.cs'))
$leases=[Collections.Generic.List[IO.FileStream]]::new()
$prior=@{}
foreach($name in @('DOTNET_GENERATE_ASPNET_CERTIFICATE','DOTNET_CLI_HOME','DOTNET_SKIP_FIRST_TIME_EXPERIENCE','DOTNET_CLI_TELEMETRY_OPTOUT')){$prior[$name]=[Environment]::GetEnvironmentVariable($name,'Process')}
$results=[Collections.Generic.List[object]]::new()
function Assert([bool]$Valid,[string]$Name){if(!$Valid){throw ('FAIL: '+$Name)};$results.Add(@{name=$Name;passed=$true})}
function Start-Inert([string]$Path,[string]$Arguments='',[hashtable]$Extra=@{}){
    if(![IO.Path]::GetFullPath($Path).StartsWith($run+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Only fresh artifact fixture executables may start.'}
    $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=$Path;$info.Arguments=$Arguments;$info.WorkingDirectory=Split-Path -Parent $Path;$info.UseShellExecute=$false;$info.CreateNoWindow=$true
    foreach($name in @('BAP_UPDATER_LAUNCHER_PID','BAP_UPDATER_LAUNCHER_CREATION','BAP_UPDATER_LAUNCHER_SESSION','BAP_COMPATIBILITY_CHECKED')){$null=$info.Environment.Remove($name)}
    $info.Environment['SteamAppId']='fixture-app';$info.Environment['SteamGameId']='fixture-game';$info.Environment['SteamOverlayGameId']='fixture-overlay';$info.Environment['PSModulePath']='fixture-parent-module'
    foreach($name in $Extra.Keys){$info.Environment[$name]=$Extra[$name]}
    return [Diagnostics.Process]::Start($info)
}
function Wait-Inert($Process){if(!$Process.WaitForExit(30000)){throw 'Inert process timeout; no termination attempted.'};$code=$Process.ExitCode;$Process.Dispose();return $code}
function Wait-File([string]$Path){$due=[DateTime]::UtcNow.AddSeconds(10);while(!(Test-Path -LiteralPath $Path)){if([DateTime]::UtcNow -ge $due){throw ('Missing inert observation: '+$Path)};Start-Sleep -Milliseconds 30}}
function New-Case([string]$Name,[string]$Behavior='ok'){
    $case=Join-Path $run $Name;$null=New-Item -ItemType Directory -Path $case
    Copy-Item -LiteralPath (Join-Path $run 'compiled\BetterAstralParty-Launcher.exe') -Destination (Join-Path $case 'BetterAstralParty-Launcher.exe')
    Copy-Item -LiteralPath (Join-Path $run 'compiled\AstralParty_INT.exe') -Destination (Join-Path $case 'AstralParty_INT.exe')
    foreach($name in @('fixture-helper.descriptor','fixture-helper.signature','fixture-helper.image')){Copy-Item -LiteralPath (Join-Path $run $name) -Destination (Join-Path $case $name)}
    Copy-Item -LiteralPath (Join-Path $taskRoot 'tools\BetterAstralParty-Steam.ps1') -Destination (Join-Path $case 'BetterAstralParty-Steam.ps1')
    if($Behavior -ceq 'parser') {[IO.File]::WriteAllText((Join-Path $case 'check-compatibility.ps1'),'param([string]$GameRoot) if (')}
    else {Copy-Item -LiteralPath (Join-Path $review 'FixtureChecker.ps1') -Destination (Join-Path $case 'check-compatibility.ps1')}
    [IO.File]::WriteAllText((Join-Path $case 'checker-behavior'),$Behavior)
    [IO.File]::WriteAllText((Join-Path $case 'doorstop_config.ini'),"[General]`r`nenabled=false`r`ncustom=fixture`r`n")
    Assert ((Wait-Inert (Start-Inert (Join-Path $case 'BetterAstralParty-Launcher.exe') '--setup')) -eq 0) ($Name+' authenticated inert setup')
    return $case
}
function Outcome([string]$Case){$lines=[IO.File]::ReadAllLines((Join-Path $Case 'host-result'));return @{Code=[int]$lines[0];Details=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($lines[1]));Parent=$lines[2]}}
function Start-Shim([string]$Case,[hashtable]$Extra=@{}){
    $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe';$info.WorkingDirectory=$Case;$info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.Arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+(Join-Path $Case 'BetterAstralParty-Steam.ps1')+'"'
    foreach($name in @('BAP_UPDATER_LAUNCHER_PID','BAP_UPDATER_LAUNCHER_CREATION','BAP_UPDATER_LAUNCHER_SESSION')){$null=$info.Environment.Remove($name)}
    $info.Environment['SteamGameId']='fixture-game';foreach($name in $Extra.Keys){$info.Environment[$name]=$Extra[$name]}
    return [Diagnostics.Process]::Start($info)
}
try {
    $env:DOTNET_GENERATE_ASPNET_CERTIFICATE='false';$env:DOTNET_CLI_HOME=Join-Path $run 'dotnet-home';$env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1';$env:DOTNET_CLI_TELEMETRY_OPTOUT='1'
    $inputs=$source+@((Join-Path $review 'InertGame.cs'),(Join-Path $review 'FixtureChecker.ps1'),$PSCommandPath,(Join-Path $taskRoot 'tools/BetterAstralParty-Steam.ps1'),(Join-Path $taskRoot 'tools/build-executable-identity.ps1'),(Join-Path $taskRoot 'src/Plugin.cs'),(Join-Path $taskRoot 'updater/ProductionUpdateKeys.cs'))
    $records=@(foreach($path in $inputs){$lease=[IO.File]::Open($path,'Open','Read','Read');$leases.Add($lease);@{path=$path;sha256=(Get-FileHash -InputStream $lease).Hash;bytes=$lease.Length}})
    # Only the isolated fixture replaces public pins; no operational private key is opened.
    $fixturePins=Join-Path $run 'FixturePublicPins.cs'
    $fixtureKey=[Security.Cryptography.RSA]::Create(3072)
    try{
        $public=$fixtureKey.ExportParameters($false)
        [IO.File]::WriteAllText($fixturePins,('namespace BetterAstralParty.Updating { internal static class ProductionUpdateKeys { internal static TrustedUpdateKey[] Read() { return new[] { new TrustedUpdateKey("native-launch-fixture", new System.Security.Cryptography.RSAParameters { Modulus=System.Convert.FromBase64String("'+[Convert]::ToBase64String($public.Modulus)+'"), Exponent=new byte[]{1,0,1} }) }; } } }'))
        $image=[byte[]]::new(512);$image[0]=77;$image[1]=90;[BitConverter]::GetBytes([int]128).CopyTo($image,60);$image[128]=80;$image[129]=69;[BitConverter]::GetBytes([uint16]0x8664).CopyTo($image,132)
        [IO.File]::WriteAllBytes((Join-Path $run 'fixture-helper.image'),$image)
        $helperHash=(Get-FileHash -LiteralPath (Join-Path $run 'fixture-helper.image') -Algorithm SHA256).Hash
        $descriptor=[Text.Encoding]::ASCII.GetBytes("BetterAstralParty.HelperDelivery/v3`nrepository=TSM701/BetterAstralParty`nversion=$version`nplatform=windows-x64-int`nimage=BetterAstralParty-UpdateHelper.exe`nbytes=512`nsha256=$helperHash`nupdate-protocol=3`n")
        $signature=$fixtureKey.SignData($descriptor,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pss)
        [IO.File]::WriteAllBytes((Join-Path $run 'fixture-helper.descriptor'),$descriptor)
        [IO.File]::WriteAllText((Join-Path $run 'fixture-helper.signature'),("BetterAstralParty.UpdateSignature/v1`nkey-id=native-launch-fixture`nsignature="+[Convert]::ToBase64String($signature)+"`n"),[Text.Encoding]::ASCII)
    }finally{$fixtureKey.Dispose()}
    $compiled=Join-Path $run 'compiled';$null=New-Item -ItemType Directory -Path $compiled
    $common=@('/nologo','/noconfig','/nostdlib+','/langversion:latest','/nullable:enable','/define:NETFRAMEWORK','/warnaserror+','/deterministic+','/platform:x64')
    foreach($ref in @('mscorlib.dll','System.dll','System.Core.dll','System.Security.dll','System.Windows.Forms.dll','System.Net.Http.dll','System.IO.Compression.dll','System.IO.Compression.FileSystem.dll')){$common+='/reference:'+(Join-Path $framework $ref)}
    $arguments=$common+@('/target:winexe','/main:FixtureEntry',('/out:'+(Join-Path $compiled 'BetterAstralParty-Launcher.exe')))+$source+@($fixturePins)
    & $dotnet $compiler @arguments;if($LASTEXITCODE -ne 0){throw 'Actual production closure fixture compilation failed.'}
    & $dotnet $compiler @common '/target:winexe' '/main:InertGame' ('/out:'+(Join-Path $compiled 'AstralParty_INT.exe')) (Join-Path $review 'InertGame.cs') $boundary;if($LASTEXITCODE -ne 0){throw 'Inert game compilation failed.'}
    $metadata=[Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $compiled 'BetterAstralParty-Launcher.exe'))
    Assert ($metadata.ProductName -ceq 'BetterAstralParty' -and $metadata.FileDescription -ceq 'BetterAstralParty native launch host') 'native executable identity'
    Assert ($metadata.ProductVersion -ceq $version) 'native metadata follows canonical version'
    $resourceCase=New-Case 'resources';Assert ((Wait-Inert (Start-Inert (Join-Path $resourceCase 'BetterAstralParty-Launcher.exe') '--resources')) -eq 0 -and [IO.File]::ReadAllText((Join-Path $resourceCase 'resource-result')) -ceq 'NoLegacyHelperOrEmbeddedPE') 'compiled launcher has no embedded helper or PE resources'
    $records|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $run 'source-records.json') -Encoding utf8
    $case=New-Case 'success';[IO.File]::WriteAllText((Join-Path $case 'hold'),'inert wait')
    $hostProcess=Start-Inert (Join-Path $case 'BetterAstralParty-Launcher.exe');Wait-File (Join-Path $case 'game-ready')
    Assert (!$hostProcess.HasExited) 'native host remains alive with inert game'
    Assert ((Wait-Inert (Start-Inert (Join-Path $case 'BetterAstralParty-Launcher.exe') '--probe')) -eq 0) 'lock probe returned'
    Assert ([IO.File]::ReadAllText((Join-Path $case 'probe-result')) -ceq 'FileBusy') 'same launch lease held through game lifetime'
    $game=[IO.File]::ReadAllText((Join-Path $case 'game-ready'));$hostIdentity=[IO.File]::ReadAllLines((Join-Path $case 'host-identity'))
    foreach($name in @('SteamAppId','SteamGameId','SteamOverlayGameId')){Assert ($game.Contains($name+'=2622000')) ('game-only '+$name)}
    Assert ($game.Contains('Args=--doorstop-enabled|true|--bap-compatibility-checked') -and $game.Contains('BAP_COMPATIBILITY_CHECKED=1')) 'same one-shot game flags'
    foreach($pair in @(@('BAP_UPDATER_LAUNCHER_PID',$hostIdentity[0]),@('BAP_UPDATER_LAUNCHER_CREATION',$hostIdentity[1]),@('BAP_UPDATER_LAUNCHER_SESSION',$hostIdentity[2]))){Assert ($game.Contains($pair[0]+'='+$pair[1])) ('native identity '+$pair[0])}
    $checker=[IO.File]::ReadAllText((Join-Path $case 'checker-observation'))
    Assert ($checker.Contains('Console=0') -and $checker.Contains('SteamAppId=fixture-app') -and $checker.Contains('SteamGameId=fixture-game') -and $checker.Contains('SteamOverlayGameId=fixture-overlay') -and $checker.Contains('LauncherPid=')) 'compatibility child isolated and windowless'
    Assert (@([IO.File]::ReadAllLines((Join-Path $case 'checker-observation')) | Where-Object {$_ -ceq 'LauncherPid='}).Count -eq 1) 'compatibility child receives no injected launcher identity'
    Assert ([IO.File]::ReadAllText((Join-Path $case 'doorstop_config.ini')) -ceq "[General]`r`nenabled=true `r`ncustom=fixture`r`n") 'successful compatibility enables only loader bytes'
    $backups=@(Get-ChildItem -LiteralPath (Join-Path $case 'BepInEx\config') -Filter 'BetterAstralParty.loader-before-*.bak' -File)
    Assert ($backups.Count -eq 1 -and [IO.File]::ReadAllText($backups[0].FullName) -ceq "[General]`r`nenabled=false`r`ncustom=fixture`r`n") 'loader preserves exact original recovery backup'
    [IO.File]::WriteAllText((Join-Path $case 'release'),'finish inert game');Assert ((Wait-Inert $hostProcess) -eq 0) 'native success exit'
    Assert ((Outcome $case).Parent -ceq 'ParentUnchanged') 'native parent environment unchanged'
    Assert ((Wait-Inert (Start-Inert (Join-Path $case 'BetterAstralParty-Launcher.exe') '--probe')) -eq 0) 'released lock probe returned'
    Assert ([IO.File]::ReadAllText((Join-Path $case 'probe-result')) -ceq 'Available') 'launch lease released after game exit'
    foreach($behavior in @('reject','parser')){
        $case=New-Case $behavior $behavior;$code=Wait-Inert (Start-Inert (Join-Path $case 'BetterAstralParty-Launcher.exe'));$outcome=Outcome $case
        Assert ($code -ne 0 -and $outcome.Details.Contains('phase=Compatibility')) ($behavior+' attributed compatibility failure')
        Assert (!(Test-Path -LiteralPath (Join-Path $case 'game-ready')) -and [IO.File]::ReadAllText((Join-Path $case 'doorstop_config.ini')).Contains('enabled=false')) ($behavior+' no game start or loader enable')
    }
    foreach($ownedPath in @('BepInEx\plugins\BetterAstralParty\BetterAstralParty.dll','check-compatibility.ps1')){
        $name=if($ownedPath.EndsWith('.dll')){'changed-plugin'}else{'changed-checker'}
        $case=New-Case $name;[IO.File]::AppendAllText((Join-Path $case $ownedPath),'inert changed owned bytes')
        Assert ((Wait-Inert (Start-Inert (Join-Path $case 'BetterAstralParty-Launcher.exe'))) -eq 1 -and (Outcome $case).Details.Contains('phase=UpdateGate')) ($name+' is rejected at the owned-file gate')
        Assert (!(Test-Path -LiteralPath (Join-Path $case 'game-ready')) -and !(Test-Path -LiteralPath (Join-Path $case 'checker-observation')) -and [IO.File]::ReadAllText((Join-Path $case 'doorstop_config.ini')).Contains('enabled=false')) ($name+' cannot start checker/game or change shared loader')
    }
    $case=New-Case 'flood' 'flood';Assert ((Wait-Inert (Start-Inert (Join-Path $case 'BetterAstralParty-Launcher.exe'))) -eq 0) 'large checker stdout and stderr drain without deadlock'
    $case=New-Case 'crash';[IO.File]::WriteAllText((Join-Path $case 'game-exit-code'),'7');Assert ((Wait-Inert (Start-Inert (Join-Path $case 'BetterAstralParty-Launcher.exe'))) -eq 7 -and (Outcome $case).Details.Contains('phase=GameExit')) 'inert crash exit and GameExit phase preserved'
    $case=New-Case 'startfailure';[IO.File]::WriteAllText((Join-Path $case 'AstralParty_INT.exe'),'inert invalid image');Assert ((Wait-Inert (Start-Inert (Join-Path $case 'BetterAstralParty-Launcher.exe'))) -eq 1 -and (Outcome $case).Details.Contains('phase=GameStart')) 'invalid inert image attributed to GameStart'
    $busy=Join-Path $run 'busy-sibling';$null=New-Item -ItemType Directory -Path $busy;Copy-Item -LiteralPath (Join-Path $compiled 'AstralParty_INT.exe') -Destination (Join-Path $busy 'AstralParty_INT.exe');[IO.File]::WriteAllText((Join-Path $busy 'hold'),'inert wait')
    $busyProcess=Start-Inert (Join-Path $busy 'AstralParty_INT.exe');Wait-File (Join-Path $busy 'game-ready');$case=New-Case 'busy';Assert ((Wait-Inert (Start-Inert (Join-Path $case 'BetterAstralParty-Launcher.exe'))) -eq 1 -and (Outcome $case).Details.Contains('phase=SteamContext') -and !(Test-Path -LiteralPath (Join-Path $case 'checker-observation'))) 'inert sibling game refuses before compatibility';[IO.File]::WriteAllText((Join-Path $busy 'release'),'finish inert sibling');Assert ((Wait-Inert $busyProcess) -eq 0) 'inert sibling exits normally'
    $case=New-Case 'shim-unsupported';Assert ((Wait-Inert (Start-Shim $case)) -eq 1 -and !(Test-Path -LiteralPath (Join-Path $case 'game-ready')) -and !(Test-Path -LiteralPath (Join-Path $case 'host-result'))) 'legacy PowerShell route is rejected without starting native host or game'
    $case=New-Case 'shim-exit';[IO.File]::WriteAllText((Join-Path $case 'game-exit-code'),'7');Assert ((Wait-Inert (Start-Shim $case)) -eq 1 -and !(Test-Path -LiteralPath (Join-Path $case 'game-ready'))) 'legacy route never starts the configured game on rejection'
    $case=New-Case 'shim-parent';Assert ((Wait-Inert (Start-Shim $case @{BAP_UPDATER_LAUNCHER_PID='1'})) -eq 1 -and !(Test-Path -LiteralPath (Join-Path $case 'host-result'))) 'legacy parent marker rejects before native spawn'
    $case=Join-Path $run 'shim-old';$null=New-Item -ItemType Directory -Path $case;Copy-Item -LiteralPath (Join-Path $compiled 'AstralParty_INT.exe') -Destination (Join-Path $case 'BetterAstralParty-Launcher.exe');Copy-Item -LiteralPath (Join-Path $taskRoot 'tools\BetterAstralParty-Steam.ps1') -Destination (Join-Path $case 'BetterAstralParty-Steam.ps1')
    Assert ((Wait-Inert (Start-Shim $case)) -eq 1 -and !(Test-Path -LiteralPath (Join-Path $case 'game-ready'))) 'old default metadata rejected without executing inert old host'
    foreach($row in $records){Assert ((Get-FileHash -LiteralPath $row.path).Hash -ceq $row.sha256) 'production compile source remained unchanged'}
    @{schema=1;status='Passed';run=$run;checks=$results;sourceManifestSha256=(Get-FileHash -LiteralPath (Join-Path $run 'source-records.json')).Hash;fixtureLauncherSha256=(Get-FileHash -LiteralPath (Join-Path $compiled 'BetterAstralParty-Launcher.exe')).Hash;actualProductionMainExecuted=$false;realGameSteamOrPrivateKeysUsed=$false}|ConvertTo-Json -Depth 7|Set-Content -LiteralPath (Join-Path $run 'result.json') -Encoding utf8
    Write-Output ('PASS '+$results.Count+' assertions: '+(Join-Path $run 'result.json'))
} catch {
    @{schema=1;status='Failed';run=$run;error=$_.Exception.ToString();checks=$results}|ConvertTo-Json -Depth 7|Set-Content -LiteralPath (Join-Path $run 'result.json') -Encoding utf8
    throw
} finally {foreach($lease in $leases){$lease.Dispose()};foreach($name in $prior.Keys){[Environment]::SetEnvironmentVariable($name,$prior[$name],'Process')}}

