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
$methods = @(foreach ($name in @('GuardModLaunch', 'GuardModLaunchVerified', 'GuardMaintenance', 'EnableSharedLoader')) {
    $pattern = if ($name -eq 'GuardMaintenance') { '(?m)^    public static IDisposable GuardMaintenance\([^\r\n]+\r?$' } else { '(?ms)^    public static (?:IDisposable|void) ' + $name + '\([^\r\n]+\r?\n.*?^    \}' }
    $match = [regex]::Match($launcher, $pattern)
    if (-not $match.Success) { throw "Exact launcher bridge extraction failed: $name" }
    $match.Value
})
$verified = $methods[1]
if ($methods[0] -notmatch 'return GuardModLaunchVerified\(root,null\);' -or
    $verified -notmatch '(?s)return new BetterAstralParty\.Updating\.UpdateLaunchGate\.Lease\(root, fence => \{.*launcher\.Hash\(\)!=snapshotHash.*AutomaticHelperUpgrade\.Ensure\(fence,assembly\);.*\}\);') {
    throw 'Mod launch must verify the captured launcher and run helper upgrade under the retained beforeCheck lease.'
}
$gate = Get-Content -LiteralPath (Join-Path $projectRoot 'updater/UpdateLaunchGate.cs') -Raw
if ($gate -notmatch '(?s)_lock=_fence\.OpenFile\("BetterAstralParty.update.lock",true\).*beforeCheck\?\.Invoke\(_fence\);\s*Check\(_fence\);') {
    throw 'Helper upgrade must run after acquiring the operation lock and before pending-state checking.'
}
$bridge = Join-Path $stageRoot 'LauncherBridge.cs'
$null = [IO.Directory]::CreateDirectory($stageRoot)
[IO.File]::WriteAllText($bridge, "using System; using System.IO; public static class SteamLauncher {`n" + ($methods -join "`n") + "`n}", [Text.UTF8Encoding]::new($false))
$tokens = $null; $parseErrors = $null
$launchAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $projectRoot 'tools/BetterAstralParty-Steam.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Launch script syntax invalid.' }
function Get-OneNode($type, $pattern) {
    $nodes = @($launchAst.FindAll({ param($node) $node -is $type -and $node.Extent.Text -match $pattern }, $true))
    if ($nodes.Count -ne 1) { throw "Launch ordering node must be unique: $pattern" }
    $nodes[0]
}
$acquire = Get-OneNode ([Management.Automation.Language.AssignmentStatementAst]) '^\$updateLaunchLease = \$guardMethod\.Invoke'
$capture = Get-OneNode ([Management.Automation.Language.AssignmentStatementAst]) '^\$launchBytes = \[IO.File\]::ReadAllBytes'
$hash = Get-OneNode ([Management.Automation.Language.AssignmentStatementAst]) '^\$launchHash = \[BitConverter\]::ToString\(\$snapshotHasher\.ComputeHash\(\$launchBytes\)\)\.Replace'
$load = Get-OneNode ([Management.Automation.Language.AssignmentStatementAst]) '^\$launchAssembly = \[Reflection.Assembly\]::Load\(\$launchBytes\)$'
$method = Get-OneNode ([Management.Automation.Language.AssignmentStatementAst]) '^\$guardMethod = .*GetMethod\(''GuardModLaunchVerified'''
if ($acquire.Extent.Text -ne '$updateLaunchLease = $guardMethod.Invoke($null, @($PSScriptRoot,$launchHash))' -or
    -not ($capture.Extent.EndOffset -lt $hash.Extent.StartOffset -and $hash.Extent.EndOffset -lt $load.Extent.StartOffset -and
        $load.Extent.EndOffset -lt $method.Extent.StartOffset -and $method.Extent.EndOffset -lt $acquire.Extent.StartOffset)) {
    throw 'Mod launch must pass the SHA256 of the exact loaded byte snapshot to the verified guard.'
}
$checkGate = Get-OneNode ([Management.Automation.Language.IfStatementAst]) '^if \(\$check\.ExitCode -ne 0\)'
$arguments = Get-OneNode ([Management.Automation.Language.AssignmentStatementAst]) '^\$enableArguments = \[object\[\]\]@\(\$PSScriptRoot, \$updateLaunchLease\)$'
$enable = Get-OneNode ([Management.Automation.Language.AssignmentStatementAst]) '^\$null = \$enableLoader\.Invoke\(\$null, \$enableArguments\)$'
$start = Get-OneNode ([Management.Automation.Language.AssignmentStatementAst]) '^\$game = Start-Process '
$dispose = Get-OneNode ([Management.Automation.Language.InvokeMemberExpressionAst]) '^\$updateLaunchLease\.Dispose\(\)$'
if ($checkGate.FindAll({ param($node) $node -is [Management.Automation.Language.ThrowStatementAst] }, $true).Count -ne 1 -or
    -not ($acquire.Extent.StartOffset -lt $checkGate.Extent.StartOffset -and $checkGate.Extent.EndOffset -lt $arguments.Extent.StartOffset -and
        $arguments.Extent.EndOffset -lt $enable.Extent.StartOffset -and $enable.Extent.EndOffset -lt $start.Extent.StartOffset -and $start.Extent.EndOffset -lt $dispose.Extent.StartOffset)) {
    throw 'Launch must acquire lease, pass compatibility, enable with same lease, launch, and finally dispose in order.'
}
$outerTry = Get-OneNode ([Management.Automation.Language.TryStatementAst]) '(?s)^try \{.*\$updateLaunchLease\.Dispose\(\)'
if (-not $outerTry.Finally -or $dispose.Extent.StartOffset -lt $outerTry.Finally.Extent.StartOffset -or $dispose.Extent.EndOffset -gt $outerTry.Finally.Extent.EndOffset) { throw 'Launch lease disposal must be in outer finally.' }
Write-Host 'PASS actual launch wiring: exact snapshot hash, locked helper migration before pending check, compatibility before enable, same retained lease, enable before game launch, finally disposal.'
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
