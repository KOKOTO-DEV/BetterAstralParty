[CmdletBinding()]
param([string]$DotnetRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$artifactRoot = Join-Path $projectRoot 'artifacts'
$stageRoot = Join-Path $artifactRoot ('ahu-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
if (-not $stageRoot.StartsWith($artifactRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $stageRoot)) { throw 'Fresh isolated artifact root required.' }
$sources = @('focus-tests/automatic-helper-upgrade/AutomaticHelperUpgradeFixture.csproj', 'focus-tests/automatic-helper-upgrade/Program.cs', 'tools/test-automatic-helper-upgrade.ps1')
$sources += @(foreach ($folder in @('updater', 'src/Observability')) {
    Get-ChildItem -LiteralPath (Join-Path $projectRoot $folder) -File -Filter '*.cs' | Where-Object { $_.Name -ne 'UpdateHelperProgram.cs' } | ForEach-Object { $_.FullName.Substring($projectRoot.Length + 1).Replace('\', '/') }
})
$sourceHashes = @{}
foreach ($source in $sources) { $sourceHashes[$source] = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $projectRoot $source)).Hash }
if (-not $DotnetRoot) { $DotnetRoot = Join-Path $projectRoot '.dotnet' }
$dotnet = Join-Path $DotnetRoot 'dotnet.exe'
$project = Join-Path $projectRoot 'focus-tests/automatic-helper-upgrade/AutomaticHelperUpgradeFixture.csproj'
$obj = (Join-Path $stageRoot 'obj/').Replace('\', '/')
$bin = Join-Path $stageRoot 'bin'
$common = @("-p:BaseIntermediateOutputPath=$obj", "-p:MSBuildProjectExtensionsPath=$obj", '-p:UseSharedCompilation=false', '-p:NuGetAudit=false')
& $dotnet restore $project --configfile (Join-Path $projectRoot 'NuGet.Config') @common
if ($LASTEXITCODE -ne 0) { throw 'Automatic helper fixture restore failed.' }
& $dotnet build $project --no-restore -c Release -o $bin @common
if ($LASTEXITCODE -ne 0) { throw 'Automatic helper fixture compile failed.' }
$output = @(& $dotnet (Join-Path $bin 'AutomaticHelperUpgradeFixture.dll') (Join-Path $stageRoot 'f') $artifactRoot)
$code = $LASTEXITCODE
$output | ForEach-Object { Write-Host $_ }
[IO.File]::WriteAllLines((Join-Path $stageRoot 'fixture-output.log'), [string[]]$output, [Text.UTF8Encoding]::new($false))
if ($code -ne 0) { throw 'Automatic helper fixture failed; all isolated evidence retained.' }
$result = $output[-1] | ConvertFrom-Json
if (-not $result.Passed -or -not $result.NoGameOrSteamExecution -or -not $result.EphemeralFixtureKeyOnly) { throw 'Fixture result contract failed.' }
foreach ($source in $sources) { if ((Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $projectRoot $source)).Hash -ne $sourceHashes[$source]) { throw "Tested source changed: $source" } }
$record = [pscustomobject]@{ Passed = $true; OutputDirectory = $stageRoot; Assertions = $result.Assertions; Cases = @($result.Cases).Count; Runtime = $result.Runtime; SourceSha256 = $sourceHashes; FixtureOutputSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $stageRoot 'fixture-output.log')).Hash }
$json = $record | ConvertTo-Json -Depth 4
[IO.File]::WriteAllText((Join-Path $stageRoot 'verification.json'), $json, [Text.UTF8Encoding]::new($false))
$json
