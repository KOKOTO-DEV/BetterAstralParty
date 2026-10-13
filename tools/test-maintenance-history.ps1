[CmdletBinding()]
param([string]$DotnetRoot, [string]$SignedProofRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$env:DOTNET_GENERATE_ASPNET_CERTIFICATE = 'false'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$projectRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$artifactRoot = Join-Path $projectRoot 'artifacts'
$ephemeralProof = -not $SignedProofRoot
$stageRoot = Join-Path $artifactRoot ('mhi-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
if (-not $stageRoot.StartsWith($artifactRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $stageRoot)) { throw 'Fresh isolated artifact root required.' }
$null=[IO.Directory]::CreateDirectory($stageRoot)
$fixtureTrustSource=$null
if($ephemeralProof){
    $SignedProofRoot=Join-Path $stageRoot 'proof';$null=[IO.Directory]::CreateDirectory($SignedProofRoot)
    $fixtureTrustSource=Join-Path $stageRoot 'FixturePublicPins.cs'
    $fixtureKey=[Security.Cryptography.RSA]::Create(3072)
    try{
        $public=$fixtureKey.ExportParameters($false)
        [IO.File]::WriteAllText($fixtureTrustSource,('namespace BetterAstralParty.Updating { internal static class ProductionUpdateKeys { internal static TrustedUpdateKey[] Read() { return new[] { new TrustedUpdateKey("history-remote-fixture", new System.Security.Cryptography.RSAParameters { Modulus=System.Convert.FromBase64String("'+[Convert]::ToBase64String($public.Modulus)+'"), Exponent=new byte[]{1,0,1} }) }; } } }'))
        $rows=@('BetterAstralParty.UpdateDescriptor/v3','repository=TSM701/BetterAstralParty','version=1.2.2','channel=Stable','platform=windows-x64-int','release-id=1','asset-id=2','asset-name=BetterAstralParty-1.2.2-update.zip','zip-bytes=1',('zip-sha256='+('A'*64)),'file-count=8','purpose=release/Stable','repository-id=1410226758','settings-schema=1')
        $owned=@('AstralParty-Vanilla.cmd','BepInEx/plugins/BetterAstralParty/BetterAstralParty.dll','BetterAstralParty-Launcher.exe','BetterAstralParty-Mod.cmd','BetterAstralParty-Steam.ps1','BetterAstralParty.compatibility.json','check-compatibility.ps1','steam-shortcut.ps1')
        foreach($path in $owned){$rows+=('file='+$path+"`t1`t"+('A'*64))}
        $descriptor=[Text.Encoding]::ASCII.GetBytes(($rows -join "`n")+"`n")
        $signature=$fixtureKey.SignData($descriptor,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pss)
        [IO.File]::WriteAllBytes((Join-Path $SignedProofRoot 'update.descriptor'),$descriptor)
        [IO.File]::WriteAllText((Join-Path $SignedProofRoot 'update.signature'),("BetterAstralParty.UpdateSignature/v1`nkey-id=history-remote-fixture`nsignature="+[Convert]::ToBase64String($signature)+"`n"),[Text.Encoding]::ASCII)
    }finally{$fixtureKey.Dispose()}
}
$SignedProofRoot=[IO.Path]::GetFullPath($SignedProofRoot)
if(-not $SignedProofRoot.StartsWith($projectRoot+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Readonly signed proof must belong to this selected project.'}
$proofHashes=@{}
foreach($name in @('update.descriptor','update.signature')){$proofHashes[$name]=(Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $SignedProofRoot $name)).Hash}
$sources = @('focus-tests/maintenance-history/MaintenanceHistoryFixture.csproj', 'focus-tests/maintenance-history/HistoryInventoryFixture.cs', 'tools/test-maintenance-history.ps1')
$sources += @(foreach ($folder in @('updater', 'src/Observability')) {
    Get-ChildItem -LiteralPath (Join-Path $projectRoot $folder) -File -Filter '*.cs' | Where-Object { $_.Name -ne 'UpdateHelperProgram.cs' } | ForEach-Object { $_.FullName.Substring($projectRoot.Length + 1).Replace('\', '/') }
})
$sourceHashes = @{}
foreach ($source in $sources) { $sourceHashes[$source] = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $projectRoot $source)).Hash }
if (-not $DotnetRoot) { $DotnetRoot = Join-Path $projectRoot '.dotnet' }
$dotnet = Join-Path $DotnetRoot 'dotnet.exe'
$project = Join-Path $projectRoot 'focus-tests/maintenance-history/MaintenanceHistoryFixture.csproj'
$obj = (Join-Path $stageRoot 'obj/').Replace('\', '/')
$bin = Join-Path $stageRoot 'bin'
$common = @("-p:BaseIntermediateOutputPath=$obj", "-p:MSBuildProjectExtensionsPath=$obj", '-p:UseSharedCompilation=false', '-p:NuGetAudit=false')
if($fixtureTrustSource){$common+=("-p:FixtureTrustSource=$fixtureTrustSource")}
& $dotnet restore $project --configfile (Join-Path $projectRoot 'NuGet.Config') @common
if ($LASTEXITCODE -ne 0) { throw 'Maintenance history fixture restore failed.' }
& $dotnet build $project --no-restore -c Release -o $bin @common
if ($LASTEXITCODE -ne 0) { throw 'Maintenance history fixture compile failed.' }
$output = @(& $dotnet (Join-Path $bin 'MaintenanceHistoryFixture.dll') (Join-Path $stageRoot 'f') $artifactRoot $SignedProofRoot)
$code = $LASTEXITCODE
$output | ForEach-Object { Write-Host $_ }
[IO.File]::WriteAllLines((Join-Path $stageRoot 'fixture-output.log'), [string[]]$output, [Text.UTF8Encoding]::new($false))
if($code -ne 0 -or $output.Count -eq 0){throw 'Maintenance history fixture failed; isolated output retained before result parsing.'}
$result = $output[-1] | ConvertFrom-Json
if (-not $result.NoGameOrSteamExecution -or -not $result.NoNetworkRequests -or -not $result.EphemeralFixtureKeyOnly -or -not $result.StructuralInventoryNotSignedUpdateExecution) { throw 'Fixture isolation contract failed.' }
foreach ($source in $sources) { if ((Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $projectRoot $source)).Hash -ne $sourceHashes[$source]) { throw "Tested source changed: $source" } }
foreach ($name in @('update.descriptor', 'update.signature')) { if ((Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $SignedProofRoot $name)).Hash -ne $proofHashes[$name]) { throw "Readonly public proof changed: $name" } }
$record = [pscustomobject]@{ Passed = $result.Passed; OutputDirectory = $stageRoot; Assertions = $result.Assertions; Cases = @($result.Cases).Count; ExitCode = $code; Runtime = $result.Runtime; SourceSha256 = $sourceHashes; PublicSignedProof = $proofHashes; EphemeralRemoteProof=$ephemeralProof; FixtureOutputSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $stageRoot 'fixture-output.log')).Hash }
$json = $record | ConvertTo-Json -Depth 4
[IO.File]::WriteAllText((Join-Path $stageRoot 'verification.json'), $json, [Text.UTF8Encoding]::new($false))
$json
if ($code -ne 0 -or -not $result.Passed) { throw 'Maintenance history regression fixture failed; isolated red-test evidence retained.' }
