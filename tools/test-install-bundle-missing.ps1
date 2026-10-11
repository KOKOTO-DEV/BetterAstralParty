[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$projectRoot=[IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$artifactRoot=Join-Path $projectRoot 'artifacts'
$scratch=Join-Path $artifactRoot ('bundle-missing-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
if(!(Test-Path -LiteralPath $artifactRoot -PathType Container) -or (Test-Path -LiteralPath $scratch) -or !$scratch.StartsWith($artifactRoot+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Fresh isolated artifact directory required.'}
$sources=@('tools/install-policy.ps1','tools/install-backup.ps1','tools/test-install-bundle-missing.ps1')
$sourceHashes=@{}
foreach($source in $sources){$sourceHashes[$source]=(Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $projectRoot $source)).Hash}
function Read-FixtureAst([string]$Path){
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw "Production script syntax invalid: $Path"}
    return $ast
}
function Get-FixtureFunction($Ast,[string]$Name){
    $nodes=@($Ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $Name},$true))
    if($nodes.Count -ne 1){throw "Production function must be unique: $Name"}
    return $nodes[0].Extent.Text
}
$policy=Read-FixtureAst (Join-Path $projectRoot 'tools/install-policy.ps1')
$backup=Read-FixtureAst (Join-Path $projectRoot 'tools/install-backup.ps1')
$definitions=@(foreach($name in @('Read-BapInstallJson','Get-BapInstallHash','Read-BapInstallFile','Get-BapInstallVersion','Open-BapInstallBundle')){Get-FixtureFunction $policy $name})
$definitions+=Get-FixtureFunction $backup 'Assert-InstallTarget'
. ([scriptblock]::Create($definitions -join "`n"))
# These calls are beyond the inventory boundary under test; reaching them is a failure.
function Read-BapInstallMetadata {throw 'Fixture reached metadata loading unexpectedly.'}
function Get-BapInstallState {throw 'Fixture reached installed validation unexpectedly.'}
function Assert-BapWholeUpdateProtocol {throw 'Fixture reached protocol validation unexpectedly.'}
$null=[IO.Directory]::CreateDirectory($scratch)
$game=Join-Path $scratch 'game'
$null=[IO.Directory]::CreateDirectory($game)
[IO.File]::WriteAllBytes((Join-Path $game 'installed-state.keep'),[Text.Encoding]::UTF8.GetBytes('Installed state must remain exact.'))
[IO.File]::WriteAllBytes((Join-Path $game 'OtherMod.keep'),[Text.Encoding]::UTF8.GetBytes('Other mod must remain exact.'))
function Snapshot-FixtureGame {
    $snapshot=@{}
    foreach($file in Get-ChildItem -LiteralPath $game -File -Recurse){$snapshot[$file.FullName]=(Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash}
    return $snapshot
}
$before=Snapshot-FixtureGame
$assertions=0;$results=@()
foreach($mode in @('missing-launcher','missing-directory','changed-present-hash')){
    $package=Join-Path $scratch $mode
    $null=[IO.Directory]::CreateDirectory($package)
    $good=Join-Path $package 'first.keep'
    $bytes=[Text.Encoding]::ASCII.GetBytes('Inert package fixture; never execute.')
    [IO.File]::WriteAllBytes($good,$bytes)
    $launcher=Join-Path $package 'artifacts/BetterAstralParty-Launcher.exe'
    if($mode -ne 'missing-directory'){$null=[IO.Directory]::CreateDirectory((Split-Path -Parent $launcher))}
    if($mode -eq 'changed-present-hash'){[IO.File]::WriteAllBytes($launcher,$bytes)}
    $inventory=@(@{path='first.keep';bytes=$bytes.Length;sha256=(Get-BapInstallHash $bytes)},@{path='artifacts/BetterAstralParty-Launcher.exe';bytes=$bytes.Length;sha256=('0'*64)})
    foreach($i in 1..8){$inventory+=@{path="later-$i.keep";bytes=0;sha256=('0'*64)}}
    $manifest=Join-Path $package 'package-manifest.json'
    [IO.File]::WriteAllText($manifest,(@{schema=1;version='1.1.2';kind='inert-diagnostic-fixture';files=$inventory}|ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
    $failure=$null
    try{$bundle=Open-BapInstallBundle -PackageRoot $package -GameRoot $game;foreach($lease in $bundle.Leases){$lease.Dispose()};throw 'Incomplete package unexpectedly accepted.'}
    catch{$failure=$_.Exception.GetBaseException().Message}
    if($mode -eq 'changed-present-hash'){
        if($failure -notmatch 'Package hash mismatch' -or $failure -match 'BAP-PACKAGE-INCOMPLETE'){throw 'Present changed bytes must retain the hash-mismatch error.'}
    }elseif($failure -notmatch 'BAP-PACKAGE-INCOMPLETE' -or $failure -notmatch 'artifacts/BetterAstralParty-Launcher.exe' -or !$failure.Contains([string]::Concat([char]0xC804,[char]0xCCB4,' ZIP')) -or $failure -notmatch 'complete ZIP'){
        throw "Missing package diagnostic incomplete: $failure"
    }
    $assertions++
    foreach($path in @($manifest,$good)){
        $handle=[IO.File]::Open($path,'Open','ReadWrite','None')
        $handle.Dispose();$assertions++
    }
    $after=Snapshot-FixtureGame
    if($before.Count -ne $after.Count){throw 'Package rejection changed installed inventory.'}
    $assertions++
    foreach($path in $before.Keys){if(!$after.ContainsKey($path) -or $after[$path] -cne $before[$path]){throw 'Package rejection changed installed bytes.'};$assertions++}
    $results+=[pscustomobject]@{Case=$mode;Passed=$true;Error=$failure;LeasesReleased=$true;InstalledWrites=$false}
}
foreach($source in $sources){if((Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $projectRoot $source)).Hash -cne $sourceHashes[$source]){throw "Tested source changed: $source"}}
$record=[pscustomobject]@{Passed=$true;Assertions=$assertions;OutputDirectory=$scratch;PowerShell=$PSVersionTable.PSVersion.ToString();Cases=$results;SourceSha256=$sourceHashes;NoExecutableOrSteamOrGameExecution=$true}
$json=$record|ConvertTo-Json -Depth 5
[IO.File]::WriteAllText((Join-Path $scratch 'verification.json'),$json,[Text.UTF8Encoding]::new($false))
$json
