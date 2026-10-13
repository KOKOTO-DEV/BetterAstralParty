param([switch]$Release,[string]$OutputDirectory,[string]$GameRoot,[string]$BepInExRoot)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$dotnet=Join-Path $root '.dotnet/dotnet.exe'
if(!$OutputDirectory){$OutputDirectory=Join-Path $root ('artifacts/development-build-'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'-'+[Guid]::NewGuid().ToString('N').Substring(0,8))}
$output=[IO.Path]::GetFullPath($OutputDirectory)
$artifactRoot=[IO.Path]::GetFullPath((Join-Path $root 'artifacts'))+[IO.Path]::DirectorySeparatorChar
if(!$output.StartsWith($artifactRoot,[StringComparison]::OrdinalIgnoreCase)-or(Test-Path -LiteralPath $output)){throw 'Fresh output under artifacts required.'}
if(!$GameRoot){$GameRoot=Join-Path (Split-Path -Parent $root) '8vJXnINT'}
if(!$BepInExRoot){$BepInExRoot=Join-Path $root '.deps/bepinex'}
$configuration=if($Release){'Release'}else{'Debug'}
$null=[IO.Directory]::CreateDirectory($output)
$names=@('DOTNET_CLI_HOME','DOTNET_SKIP_FIRST_TIME_EXPERIENCE','DOTNET_CLI_TELEMETRY_OPTOUT','NUGET_PACKAGES','DOTNET_GENERATE_ASPNET_CERTIFICATE')
$previous=@{}
foreach($name in $names){$previous[$name]=[Environment]::GetEnvironmentVariable($name,'Process')}
$sourceLeases=[Collections.Generic.List[IO.FileStream]]::new()
function Invoke-BapBuildCheck([string]$Path,[string[]]$Arguments=@()) {
    & (Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source -NoProfile -NonInteractive -File (Join-Path $root $Path) @Arguments
    if($LASTEXITCODE -ne 0){throw ('Build check failed: '+$Path)}
}
try {
    $sourcePaths=@(foreach($folder in @('src','updater')){Get-ChildItem -LiteralPath (Join-Path $root $folder) -Recurse -File | Where-Object {$_.Extension -in @('.cs','.csproj') -and $_.FullName -notmatch '[\\/](obj|bin)[\\/]'} | ForEach-Object {$_.FullName.Substring($root.Length+1).Replace('\','/')}})
    $sourcePaths+=@('NuGet.Config','Directory.Build.props','global.json','tools/SteamLauncher.cs','tools/BetterAstralParty-Steam.ps1','tools/InstallHelperBootstrap.cs','diagnostics/DiagnosticBundle.cs','diagnostics/MinimalDiagnosticProjection.cs','tools/build.ps1','tools/build-launcher.ps1','tools/build-update-helper.ps1','tools/test-source-mode.ps1','tools/test-settings-input.ps1','tools/test-settings-scroll.ps1','tools/test-shared-loader.ps1','tools/test-shared-loader-enable.ps1','focus-tests/shared-loader-enable/SharedLoaderEnableFixture.csproj','focus-tests/shared-loader-enable/RuntimeFixture.cs','tools/install.ps1','tools/uninstall.ps1')
    $sourcePaths = $sourcePaths + @('tools/test-automatic-helper-upgrade.ps1','focus-tests/automatic-helper-upgrade/AutomaticHelperUpgradeFixture.csproj','focus-tests/automatic-helper-upgrade/Program.cs','tools/install-policy.ps1','tools/install-reinstall.ps1','tools/install-backup.ps1','tools/check-compatibility.ps1','tools/test-install-bundle-missing.ps1','tools/test-catalog-compatibility.ps1','focus-tests/catalog-compatibility/CatalogCompatibilityFixture.csproj','focus-tests/catalog-compatibility/Program.cs','focus-tests/catalog-compatibility/Compare-PowerShell.ps1')
    $sourcePaths = $sourcePaths + @('tools/install-helper.ps1','tools/install-bootstrap.ps1','tools/install-log.ps1','tools/diagnostics.ps1','tools/test-install-recovery-diagnostics.ps1','diagnostics-tests/Test-Diagnostics.ps1','diagnostics-tests/BetterAstralParty.Diagnostics.Fixture.csproj','diagnostics-tests/Program.cs','diagnostics-tests/FencedStoreFixture.cs','diagnostics-tests/RuntimeHealthFixture.cs','tools/test-whole-channel-transition.ps1','focus-tests/whole-channel-transition/Program.cs','focus-tests/whole-channel-transition/WholeChannelTransitionFixture.csproj')
    $sourcePaths = $sourcePaths + @('tools/steam-session.ps1','tools/steam-shortcut.ps1','tools/test-steam-session.ps1','tools/test-steam-shortcut.ps1','tools/test-steam-observation.ps1','tools/test-uninstall-steam-boundary.ps1','tools/test-install-log.ps1','tools/test-install-safety.ps1','diagnostics-tests/Test-FailureContext.ps1')
    $sourcePaths = $sourcePaths + @('tools/test-install-transaction.ps1','tools/test-uninstall-updated-receipt.ps1','tools/test-maintenance-history.ps1','focus-tests/maintenance-history/MaintenanceHistoryFixture.csproj','focus-tests/maintenance-history/HistoryInventoryFixture.cs')
    $sourcePaths = $sourcePaths + @('tools/test-maintenance-preservation.ps1','tools/test-launch-failure-diagnostics.ps1')
    $sourcePaths = $sourcePaths + @('Install.cmd','Uninstall.cmd','tools/find-game.ps1','tools/test-find-game.ps1','tools/test-maintenance-frontends.ps1','tools/test-maintenance-paths.ps1','tools/test-channel-transition.ps1','tools/test-update-notification-ui.ps1','focus-tests/channel-transition/ChannelTransitionTests.csproj','focus-tests/channel-transition/Program.cs','focus-tests/channel-transition/run.ps1','focus-tests/channel-transition/offline-nuget.config','focus-tests/update-notification/PopupFixtures.csproj','focus-tests/update-notification/NativeFixture.cs','focus-tests/update-notification/Program.cs','focus-tests/update-notification/run.ps1','diagnostics-tests/Prepare-UiFixture.py','diagnostics-tests/UiStubs.cs','diagnostics-tests/UiFixture.cs')
    $sourcePaths = $sourcePaths + @('tools/test-history-binding.ps1','focus-tests/history-binding/HistoryBindingFixture.csproj','focus-tests/history-binding/HistoryBindingFixture.cs','focus-tests/history-binding/MetadataPlugin.cs','updater-safety-tests/InertProcess.cs','updater-safety-tests/CompatibilityFixtureData.cs')
    $sourcePaths += 'focus-tests/update-notification/ChannelDiagnosticsFixture.cs'
    $sourcePaths = $sourcePaths + @('tools/test-staging.ps1','updater-safety-tests/BetterAstralParty.StagingTests.csproj','updater-safety-tests/StagingFixture.cs')
    $sourcePaths = $sourcePaths + @('tools/DevelopmentPackageFiles.cs','tools/GaPackageContract.cs','tools/SignLocalInstall.cs','tools/sign-local-install.ps1','tools/prepare-local-install.ps1','tools/prepare-local-signed-inputs.ps1','tools/ga-package-policy.ps1','tools/package-ga.ps1','tools/build-executable-identity.ps1')
    $sourcePaths = $sourcePaths + @('tools/test-native-launcher.ps1','focus-tests/native-launcher/FixtureEntry.cs','focus-tests/native-launcher/InertGame.cs','focus-tests/native-launcher/FixtureChecker.ps1','tools/test-steam-context.ps1','tools/test-windowless-launcher.ps1','tools/test-compatibility.ps1','tools/test-launchers.ps1')
    $sourcePaths += @(Get-ChildItem -LiteralPath (Join-Path $root 'self-test') -File | Where-Object {$_.Extension -in @('.cs','.csproj')} | ForEach-Object {$_.FullName.Substring($root.Length+1).Replace('\','/')})
    $sourceRecords=@(foreach($relative in @($sourcePaths|Sort-Object -Unique)){
        $lease=[IO.File]::Open((Join-Path $root $relative),'Open','Read','Read');$sourceLeases.Add($lease)
        @{path=$relative;bytes=$lease.Length;sha256=(Get-FileHash -InputStream $lease -Algorithm SHA256).Hash}
    })
    $sourceRecords|ConvertTo-Json -Depth 4|Set-Content -LiteralPath (Join-Path $output 'build-source.json') -Encoding utf8
    $env:DOTNET_CLI_HOME=Join-Path $output 'dotnet-home'
    $env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1'
    $env:DOTNET_CLI_TELEMETRY_OPTOUT='1'
    $env:DOTNET_GENERATE_ASPNET_CERTIFICATE='false'
    $env:NUGET_PACKAGES=Join-Path $output 'packages'
    $project=Join-Path $root 'src/BetterAstralParty.csproj'
    $obj=(Join-Path $output 'plugin-obj')+[IO.Path]::DirectorySeparatorChar
    $common=@("-p:GameRoot=$GameRoot","-p:BepInExRoot=$BepInExRoot","-p:BaseIntermediateOutputPath=$obj","-p:MSBuildProjectExtensionsPath=$obj",'-p:UseSharedCompilation=false','-p:NuGetAudit=false','-p:CheckEolTargetFramework=false')
    & $dotnet restore $project --configfile (Join-Path $root 'NuGet.Config') @common
    if($LASTEXITCODE -ne 0){throw 'Plugin restore failed.'}
    & $dotnet build $project -c $configuration --no-restore -o (Join-Path $output 'plugin') @common
    if($LASTEXITCODE -ne 0){throw 'Plugin build failed.'}
    & (Join-Path $PSScriptRoot 'build-launcher.ps1') -DotnetRoot (Join-Path $root '.dotnet') -OutputDirectory (Join-Path $output 'launcher')
    & (Join-Path $PSScriptRoot 'build-update-helper.ps1') -DotnetRoot (Join-Path $root '.dotnet') -OutputDirectory (Join-Path $output 'helper')
    foreach($check in @('tools/test-source-mode.ps1','tools/test-settings-input.ps1','tools/test-settings-scroll.ps1','tools/test-shared-loader.ps1','tools/test-install-bundle-missing.ps1','tools/test-install-recovery-diagnostics.ps1','diagnostics-tests/Test-Diagnostics.ps1','diagnostics-tests/Test-FailureContext.ps1','tools/test-steam-session.ps1','tools/test-steam-shortcut.ps1','tools/test-steam-observation.ps1','tools/test-uninstall-steam-boundary.ps1','tools/test-install-log.ps1')){Invoke-BapBuildCheck $check}
    foreach($check in @('tools/test-shared-loader-enable.ps1','tools/test-automatic-helper-upgrade.ps1','tools/test-catalog-compatibility.ps1','tools/test-native-launcher.ps1','tools/test-maintenance-history.ps1')){Invoke-BapBuildCheck $check @('-DotnetRoot',(Join-Path $root '.dotnet'))}
    $selfProject=Join-Path $root 'self-test/BetterAstralParty.SelfTest.csproj'
    $selfObj=(Join-Path $output 'selftest-obj')+[IO.Path]::DirectorySeparatorChar
    $selfCommon=@("-p:BaseIntermediateOutputPath=$selfObj","-p:MSBuildProjectExtensionsPath=$selfObj",'-p:UseSharedCompilation=false','-p:NuGetAudit=false')
    & $dotnet restore $selfProject --configfile (Join-Path $root 'NuGet.Config') @selfCommon
    if($LASTEXITCODE -ne 0){throw 'Update self-test restore failed.'}
    & $dotnet build $selfProject -c Release --no-restore -o (Join-Path $output 'selftest') @selfCommon
    if($LASTEXITCODE -ne 0){throw 'Update self-test build failed.'}
    & $dotnet (Join-Path $output 'selftest/BetterAstralParty.SelfTest.dll') --release-updates-only
    if($LASTEXITCODE -ne 0){throw 'Update/readiness self-test failed.'}
    $inspector=Join-Path $output 'launcher/BetterAstralParty-Launcher.exe'
    foreach($check in @('tools/test-maintenance-preservation.ps1','tools/test-uninstall-updated-receipt.ps1')){Invoke-BapBuildCheck $check}
    foreach($check in @('tools/test-launch-failure-diagnostics.ps1','tools/test-install-safety.ps1','tools/test-install-transaction.ps1')){Invoke-BapBuildCheck $check @('-InspectorPath',$inspector,'-InspectorSha256',(Get-FileHash -LiteralPath $inspector -Algorithm SHA256).Hash)}
    foreach($check in @('tools/test-find-game.ps1','tools/test-maintenance-frontends.ps1')){Invoke-BapBuildCheck $check}
    Invoke-BapBuildCheck 'tools/test-update-notification-ui.ps1' @('-PluginPath',(Join-Path $output 'plugin/BetterAstralParty.dll'))
    Invoke-BapBuildCheck 'tools/test-maintenance-paths.ps1' @('-InspectorPath',$inspector,'-InspectorSha256',(Get-FileHash -LiteralPath $inspector -Algorithm SHA256).Hash)
    Invoke-BapBuildCheck 'tools/test-channel-transition.ps1' @('-DotnetRoot',(Join-Path $root '.dotnet'),'-BepInExRoot',$BepInExRoot)
    Invoke-BapBuildCheck 'tools/test-history-binding.ps1' @('-DotnetRoot',(Join-Path $root '.dotnet'))
    Invoke-BapBuildCheck 'tools/test-staging.ps1' @('-DotnetRoot',(Join-Path $root '.dotnet'))
    $files=@('plugin/BetterAstralParty.dll','launcher/BetterAstralParty-Launcher.exe','helper/BetterAstralParty-UpdateHelper.exe')
    $records=@(foreach($relative in $files){$path=Join-Path $output $relative;@{path=$relative;bytes=(Get-Item -LiteralPath $path).Length;sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash}})
    @{schema=1;configuration=$configuration;sourceManifestSha256=(Get-FileHash -LiteralPath (Join-Path $output 'build-source.json') -Algorithm SHA256).Hash;checks=@('source-mode','settings-input','settings-scroll','shared-loader','shared-loader-enable','automatic-helper-upgrade','install-bundle-missing','catalog-compatibility','install-recovery-diagnostics','diagnostics-bundle','failure-context','steam-session','steam-shortcut','steam-observation','uninstall-steam-boundary','install-log','native-launcher','maintenance-history','release-updates-and-readiness','launch-failure-diagnostics','maintenance-preservation','uninstall-updated-receipt','install-safety','install-transaction','find-game','maintenance-frontends','maintenance-paths','channel-transition','update-notification-ui','history-binding','staging');files=$records;installationPerformed=$false;releaseCreated=$false}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $output 'build-result.json') -Encoding utf8
    Write-Host "Development build and selected checks completed: $output"
} finally {
    foreach($lease in $sourceLeases){$lease.Dispose()}
    foreach($name in $names){[Environment]::SetEnvironmentVariable($name,$previous[$name],'Process')}
}
