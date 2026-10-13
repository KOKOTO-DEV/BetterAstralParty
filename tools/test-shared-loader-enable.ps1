[CmdletBinding()]
param([string]$DotnetRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$artifactRoot = Join-Path $projectRoot 'artifacts'
$stageRoot = Join-Path $artifactRoot ('sle-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
if (-not $stageRoot.StartsWith($artifactRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $stageRoot)) {
    throw 'A new isolated artifact directory is required.'
}
$sources = @('focus-tests/shared-loader-enable/SharedLoaderEnableFixture.csproj', 'focus-tests/shared-loader-enable/RuntimeFixture.cs', 'tools/SteamLauncher.cs', 'tools/BetterAstralParty-Steam.ps1', 'tools/test-shared-loader-enable.ps1')
$sources += @(foreach ($folder in @('updater', 'src/Observability')) {
    Get-ChildItem -LiteralPath (Join-Path $projectRoot $folder) -File -Filter '*.cs' |
        Where-Object { $_.Name -ne 'UpdateHelperProgram.cs' } |
        ForEach-Object { $_.FullName.Substring($projectRoot.Length + 1).Replace('\', '/') }
})
$sourceHashes = @{}
foreach ($source in $sources) { $sourceHashes[$source] = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $projectRoot $source)).Hash }
if (-not $DotnetRoot) { $DotnetRoot = Join-Path $projectRoot '.dotnet' }
$dotnet = Join-Path $DotnetRoot 'dotnet.exe'
$project = Join-Path $projectRoot 'focus-tests/shared-loader-enable/SharedLoaderEnableFixture.csproj'
$obj = (Join-Path $stageRoot 'obj/').Replace('\', '/')
$bin = Join-Path $stageRoot 'bin'
$launcher = Get-Content -LiteralPath (Join-Path $projectRoot 'tools/SteamLauncher.cs') -Raw
$methods = @(foreach ($name in @('GuardMaintenance', 'EnableSharedLoader')) {
    $pattern = if ($name -eq 'GuardMaintenance') { '(?m)^    public static IDisposable GuardMaintenance\([^\r\n]+\r?$' } else { '(?ms)^    public static (?:IDisposable|void) ' + $name + '\([^\r\n]+\r?\n.*?^    \}' }
    $match = [regex]::Match($launcher, $pattern)
    if (-not $match.Success) { throw "Exact launcher bridge extraction failed: $name" }
    $match.Value
})
$verified = [regex]::Match($launcher, '(?ms)^    public static IDisposable GuardModLaunchVerified\([^\r\n]+\r?\n.*?^    \}').Value
if ($verified -notmatch '(?s)return new BetterAstralParty\.Updating\.UpdateLaunchGate\.Lease\(root, fence => \{.*launcher\.Hash\(\)!=snapshotHash.*InstallReceipt\.Parse.*installed\.Channels\.Root!=fence\.RootIdentity\.Text.*file\.Hash\(\)!=installed\.Files\[path\].*metadata\.UpdateProtocol!=3.*HelperDelivery\.Fingerprint\(fence,BetterAstralParty\.Updating\.UpdateTrust\.Production\(\),3\).*\}\);' -or $verified -match 'AutomaticHelperUpgrade\.Ensure|GetManifestResource') {
    throw 'Mod launch must require an intact baseline receipt, owned8 and protocol3 helper under its retained lease; no embedded migration.'
}
$gate = Get-Content -LiteralPath (Join-Path $projectRoot 'updater/UpdateLaunchGate.cs') -Raw
if ($gate -notmatch '(?s)_lock=_fence\.OpenFile\("BetterAstralParty.update.lock",true\).*beforeCheck\?\.Invoke\(_fence\);\s*Check\(_fence\);') {
    throw 'Installed validation must run after acquiring the operation lock and before pending-state checking.'
}
$bridge = Join-Path $stageRoot 'LauncherBridge.cs'
$null = [IO.Directory]::CreateDirectory($stageRoot)
[IO.File]::WriteAllText($bridge, "using System; using System.IO; public static class SteamLauncher {`n" + ($methods -join "`n") + "`n}", [Text.UTF8Encoding]::new($false))
$tokens = $null; $parseErrors = $null
$launchAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $projectRoot 'tools/BetterAstralParty-Steam.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Launch script syntax invalid.' }
$entry = $launchAst.Extent.Text
if ($entry -match 'ReadAllBytes|Assembly\]::Load|Start-Process|BAP_UPDATER_LAUNCHER_PID' -or $entry -notmatch 'PowerShell launch routing is unsupported' -or $entry -notmatch 'exit 1') {
    throw 'Legacy PowerShell routing must refuse rather than loading or forwarding an old executable.'
}
$run = [regex]::Match($launcher, '(?ms)^    internal static int Run\(.*?^    \}').Value
$previousOffset = -1
foreach ($step in @('using (var guardedLaunch = GuardModLaunchVerified(root, null))',
    'Process.Start(checkStart)', 'if (check.ExitCode != 0)', 'return check.ExitCode;',
    'EnableSharedLoader(root, guardedLaunch);', 'Process.Start(start)', 'game.WaitForExit();', 'return game.ExitCode;')) {
    $offset = $run.IndexOf($step, [StringComparison]::Ordinal)
    if ($offset -le $previousOffset) { throw "Native launch ordering changed: $step" }
    $previousOffset = $offset
}
if ($run -match 'BetterAstralParty-Steam\.ps1|Assembly\.Load' -or
    $run -notmatch 'catch \(Exception error\) \{ details = LaunchFailure\(phase, error\); return 1; \}') {
    throw 'Native host must retain its lease through game exit and report failures without executable reloading.'
}
Write-Host 'PASS launch wiring: native baseline receipt/owned8/helper validation before pending check, compatibility before enable, retained lease through game exit, legacy script rejected.'
$common = @("-p:BaseIntermediateOutputPath=$obj", "-p:MSBuildProjectExtensionsPath=$obj", "-p:LauncherBridgeSource=$bridge", '-p:UseSharedCompilation=false', '-p:NuGetAudit=false')
& $dotnet restore $project --configfile (Join-Path $projectRoot 'NuGet.Config') @common
if ($LASTEXITCODE -ne 0) { throw 'Shared-loader enable fixture restore failed.' }
& $dotnet build $project --no-restore -c Release -o $bin @common
if ($LASTEXITCODE -ne 0) { throw 'Shared-loader enable fixture build failed.' }
& $dotnet (Join-Path $bin 'SharedLoaderEnableFixture.dll') (Join-Path $stageRoot 'fixtures') $artifactRoot
if ($LASTEXITCODE -ne 0) { throw 'Shared-loader enable fixture failed; isolated evidence retained.' }
foreach ($source in $sources) {
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $projectRoot $source)).Hash -ne $sourceHashes[$source]) { throw "Tested source changed during execution: $source" }
}
[pscustomobject]@{ Passed = $true; OutputDirectory = $stageRoot; SourceSha256 = $sourceHashes } | ConvertTo-Json -Depth 3 -Compress
