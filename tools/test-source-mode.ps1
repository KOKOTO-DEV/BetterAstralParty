$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$tokens=$null;$errors=$null
$buildAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'build.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors-join [char]10)}
$sourceAssignments=@($buildAst.FindAll({param($node)$node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -ceq '$sourcePaths'},$true))
if($sourceAssignments.Count -lt 4){throw 'Build input enumeration missing.'}
foreach($statement in $sourceAssignments){. ([scriptblock]::Create($statement.Extent.Text))}
foreach($name in @('diagnostics/DiagnosticBundle.cs','Directory.Build.props','global.json','tools/steam-session.ps1','tools/steam-shortcut.ps1','tools/test-steam-session.ps1','tools/test-steam-shortcut.ps1','tools/test-steam-observation.ps1','tools/test-uninstall-steam-boundary.ps1','tools/test-install-log.ps1','tools/test-install-safety.ps1','diagnostics-tests/Test-FailureContext.ps1')){
    if($name -cnotin $sourcePaths){throw ('Build input is not recorded: '+$name)}
}
foreach($name in @('helper-delivery.json','helper-bootstrap/current/image.exe','helper-bootstrap/current/descriptor','helper-bootstrap/current/signature')){
    if($name -cin $sourcePaths){throw ('Legacy embedded bootstrap remains a build input: '+$name)}
}
[xml]$pluginProject=[IO.File]::ReadAllText((Join-Path $root 'src/BetterAstralParty.csproj'))
foreach($include in $pluginProject.SelectNodes('/Project/ItemGroup/Compile[@Include]')){
    $path=[IO.Path]::GetFullPath((Join-Path (Join-Path $root 'src') $include.Include))
    if(!$path.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase) -or $path.Substring($root.Length+1).Replace('\','/') -cnotin $sourcePaths){throw ('Linked compilation input is not recorded: '+$include.Include)}
}
foreach($name in @('Install.cmd','Uninstall.cmd')){
    $text=[IO.File]::ReadAllText((Join-Path $root $name))
    $guard=[regex]::Match($text,'(?s)\A@echo off\r?\nsetlocal DisableDelayedExpansion\r?\nif exist "%~dp0package-manifest.json" goto packaged\r?\n.*?\r?\n:packaged\r?\n')
    $operation=if($name-eq'Install.cmd'){'Install'}else{'Uninstall'}
    if(!$guard.Success-or!$guard.Value.Contains(('tools\development-maintenance.ps1" -Operation '+$operation+' %*'))){throw "Pinned development dispatcher missing: $name"}
    if($guard.Value-notmatch'set "BAP_EXIT=%errorlevel%"\r?\npause\r?\nexit /b %BAP_EXIT%' -or $guard.Value-match'(?im)^\s*call\s'){throw "Development result must pause and preserve the exact exit code without CALL: $name"}
    if($name-eq'Install.cmd'-and$guard.Length-gt$text.IndexOf('BAP_BOOTLOG')){throw 'Development gate must precede bootstrap logging.'}
}
$tokens=$null;$errors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'uninstall.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors-join [char]10)}
$guards=@($ast.FindAll({param($node)$node-is[System.Management.Automation.Language.IfStatementAst]-and$node.Extent.Text.Contains('BAP-SOURCE-DEVELOPMENT')},$true))
if($guards.Count-ne1){throw 'Expected exactly one uninstall source guard.'}
$firstDot=@($ast.FindAll({param($node)$node-is[System.Management.Automation.Language.CommandAst]-and$node.InvocationOperator-eq[System.Management.Automation.Language.TokenKind]::Dot},$true))|Select-Object -First 1
if($guards[0].Extent.StartOffset-gt$firstDot.Extent.StartOffset){throw 'Uninstall guard must precede imports.'}
$sourceGuard=[scriptblock]::Create($guards[0].Extent.Text)
foreach($present in @($false,$true)){
    $script:sourceManifestPresent=$present
    function Test-Path { param($LiteralPath,$PathType) return $script:sourceManifestPresent }
    $rejected=$false
    try { & $sourceGuard } catch {if(!$_.Exception.Message.Contains('BAP-SOURCE-DEVELOPMENT')){throw};$rejected=$true}
    finally {Remove-Item Function:Test-Path}
    if($rejected-eq$present){throw 'Source-mode guard regression.'}
}
$ast=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'development-maintenance.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors-join [char]10)}
$dispatch=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'development-maintenance.ps1'))
$pointerDefinition=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Read-BapDevelopmentMaintenancePointer'},$true))
if($pointerDefinition.Count -ne 1 -or !$dispatch.Contains("'artifacts/development-maintenance.json'") -or !$dispatch.Contains('$pointerLease=[IO.File]::Open($pointerPath,''Open'',''Read'',''Read'')') -or !$dispatch.Contains('if ($pointerLease) { $pointerLease.Dispose() }') -or $dispatch -match '1\.0\.0-rc\.[0-9]+'){throw 'Developer maintenance must hold a fixed version-neutral pointer, never select loose builds.'}
$policyAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'install-policy.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors-join [char]10)}
foreach($functionName in @('Read-BapInstallJson','Get-BapInstallVersion','Compare-BapInstallVersion')){
    $definition=@($policyAst.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName},$true))
    if($definition.Count -ne 1){throw 'Shared pointer validation function missing.'}
    . ([scriptblock]::Create($definition[0].Extent.Text))
}
. ([scriptblock]::Create($pointerDefinition[0].Extent.Text))
$prepareAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'prepare-local-install.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors-join [char]10)}
$prepareScope=@($prepareAst.ParamBlock.Parameters|Where-Object {$_.Name.VariablePath.UserPath -ceq 'Scope'})
if($prepareScope.Count -ne 1 -or $prepareScope[0].DefaultValue.Extent.Text -cne "'LocalInstall'" -or !$prepareScope[0].Extent.Text.Contains("[ValidateSet('LocalInstall','Release')]")){throw 'Preparation must default to local scope and require an explicit release scope.'}
$prepareGates=@()
foreach($prefix in @('if((Compare-BapInstallVersion $targetVersion ',"if(`$Scope -eq 'LocalInstall' -and (`$version ","if(`$Scope -eq 'Release' -and `$version ")){
    $matches=@($prepareAst.FindAll({param($node)$node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text.StartsWith($prefix,[StringComparison]::Ordinal)},$true))
    if($matches.Count -ne 1){throw ('Expected one preparation version guard: '+$prefix)}
    $prepareGates+=@($matches[0])
}
if($prepareGates[0].Extent.StartOffset -ge $prepareGates[1].Extent.StartOffset -or $prepareGates[1].Extent.StartOffset -ge $prepareGates[2].Extent.StartOffset){throw 'Baseline validation must precede preparation scope validation.'}
$prepareVersionGuards=@($prepareGates|ForEach-Object {[scriptblock]::Create($_.Extent.Text)})
$pointer=@{version='1.2.1-rc.1.local.1'}
foreach($case in @(@('LocalInstall','1.2.1-rc.1.local.2',$true),@('LocalInstall','1.2.1-rc.1.local.2+build.1',$true),@('LocalInstall','1.2.1-rc.1.local.1',$false),@('LocalInstall','1.2.1-rc.1.local.0',$false),@('LocalInstall','1.2.1',$false),@('LocalInstall','1.2.1-rc.2',$false),@('LocalInstall','1.3.0-rc.1.local.1',$true),@('LocalInstall','1.2.0-rc.1.local.2',$false),@('Release','1.2.1',$true),@('Release','1.2.1+build.1',$true),@('Release','2.0.0',$true),@('Release','1.2.1-rc.2',$true),@('Release','1.2.1-rc.1.local.1',$false),@('Release','1.2.1-rc.1.local.2',$false),@('Release','1.2.0',$false),@('Release','0.9.0',$false))){
    $Scope=$case[0];$version=$case[1];$targetVersion=Get-BapInstallVersion $version;$accepted=$true
    try{foreach($guard in $prepareVersionGuards){& $guard}}catch{
        if($_.Exception.Message -notin @('New 1.2.1 baseline or later required.','Distinct increasing local prerelease required.','Local prereleases cannot be remote release inputs.')){throw}
        $accepted=$false
    }
    if($accepted -ne $case[2]){throw ('Preparation version-scope regression: '+$Scope+' '+$version)}
}
$prepareReadme=@($prepareAst.FindAll({param($node)$node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text.StartsWith("if(`$Scope -eq 'LocalInstall' -and `$name -eq 'README.md')",[StringComparison]::Ordinal)},$true))
if($prepareReadme.Count -ne 1){throw 'Local README notice must not enter release preparation.'}
$selector=@($prepareAst.FindAll({param($node)$node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -ceq '$source' -and $node.Extent.Text.StartsWith('$source=if($replacements.ContainsKey($name))')},$true))
if($selector.Count -ne 1){throw 'Expected one canonical package source selector.'}
$selectSource=[scriptblock]::Create($selector[0].Extent.Text)
$replacements=@{};$build='fixture-build';$base='fixture-base';$project=$root
foreach($case in @(@('install.cmd','Install.cmd'),@('INSTALL.CMD','Install.cmd'),@('uninstall.cmd','Uninstall.cmd'),@('Uninstall.cmd','Uninstall.cmd'),@('tools/find-game.ps1','tools/find-game.ps1'))){
    $name=$case[0];. $selectSource
    if($source -cne $case[1]){throw ('Canonical current package source regression: '+$name)}
}
$script:pointerTargets=@()
function Assert-InstallTarget {param($GameRoot,$Target)
    $script:pointerTargets+=@($Target)
    if($Target.Contains('\linked\')){throw 'Inert linked target rejected.'}
}
function Read-SourcePointerFixture([byte[]]$Bytes){
    $stream=[IO.MemoryStream]::new($Bytes,$false)
    try{return Read-BapDevelopmentMaintenancePointer $root $stream}finally{$stream.Dispose()}
}
try{
    $validPointer=[ordered]@{schema=1;version='1.0.0-rc.6';packagePath='artifacts/automatic-update-development/reviewed/final/payload';manifestSha256=('A'*64)}
    foreach($version in @('1.0.0-rc.6','1.0.0','1.2.3-beta.4+build.7','2.0.0')){
        foreach($path in @('artifacts/automatic-update-development/reviewed/final/payload','releases/reviewed/payload')){
            $validPointer.version=$version;$validPointer.packagePath=$path;$script:pointerTargets=@()
            $pointer=Read-SourcePointerFixture ([Text.Encoding]::UTF8.GetBytes(($validPointer|ConvertTo-Json -Compress)))
            if($pointer.Version -cne $version -or $pointer.ManifestSha256 -cne ('A'*64) -or $pointer.PackageRoot -cne [IO.Path]::GetFullPath((Join-Path $root $path)) -or $script:pointerTargets.Count -ne 1 -or $script:pointerTargets[0] -cne $pointer.PackageRoot){throw 'Version-neutral pointer or linked-path guard regression.'}
        }
    }
    $badJson=@('null','[]','{"schema":1,','{"schema":1,"schema":1,"version":"1.0.0","packagePath":"releases/x","manifestSha256":"'+('A'*64)+'"}')
    foreach($override in @(@{schema=2},@{schema='1'},@{version='01.0.0'},@{version='1.0.0-rc.01'},@{version=1},@{manifestSha256=('a'*64)},@{manifestSha256=('A'*63)},@{extra='unexpected'})){
        $row=[ordered]@{schema=1;version='1.0.0-rc.6';packagePath='releases/reviewed/payload';manifestSha256=('A'*64)}
        foreach($name in $override.Keys){$row[$name]=$override[$name]}
        $badJson+=($row|ConvertTo-Json -Compress)
    }
    foreach($path in @('artifacts/loose-build','releases','/releases/x','C:/releases/x','releases/../x','releases/x//y','releases/x/CON','releases/x.','releases/ x','releases/x::$DATA','releases\x','releases/linked/payload',('releases/'+('x'*512)))){
        $row=[ordered]@{schema=1;version='1.0.0';packagePath=$path;manifestSha256=('A'*64)}
        $badJson+=($row|ConvertTo-Json -Compress)
    }
    $badJson+='{"schema":1,"version":"1.0.0","packagePath":"releases/x"}'
    $badJson+='{"Schema":1,"version":"1.0.0","packagePath":"releases/x","manifestSha256":"'+('A'*64)+'"}'
    foreach($json in $badJson){
        $rejected=$false
        try{$null=Read-SourcePointerFixture ([Text.Encoding]::UTF8.GetBytes($json))}catch{$rejected=$true}
        if(!$rejected){throw 'Malformed or out-of-scope pointer accepted.'}
    }
    foreach($bytes in @([byte[]]@(),[byte[]]@(255,254),[Text.Encoding]::UTF8.GetBytes((' '*4097)))){
        $rejected=$false
        try{$null=Read-SourcePointerFixture $bytes}catch{$rejected=$true}
        if(!$rejected){throw 'Pointer encoding/size bound regression.'}
    }
}finally{
    foreach($functionName in @('Assert-InstallTarget','Read-SourcePointerFixture','Read-BapDevelopmentMaintenancePointer','Read-BapInstallJson','Get-BapInstallVersion')){Remove-Item ('Function:'+ $functionName)}
}
$manifestGate=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text.StartsWith('if ((Get-FileHash -InputStream $manifestLease')},$true))
$versionGate=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text.StartsWith('if ($bundle.Version.Text -cne $pointer.Version)')},$true))
$openBundle=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Open-BapInstallBundle'},$true))
$readPointer=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Read-BapDevelopmentMaintenancePointer'},$true))
if($manifestGate.Count -ne 1 -or $versionGate.Count -ne 1 -or $openBundle.Count -ne 1 -or $readPointer.Count -ne 1 -or $readPointer[0].Extent.StartOffset -ge $manifestGate[0].Extent.StartOffset -or $manifestGate[0].Extent.StartOffset -ge $openBundle[0].Extent.StartOffset -or $openBundle[0].Extent.StartOffset -ge $versionGate[0].Extent.StartOffset){throw 'Pointer/hash/complete bundle/version validation order changed.'}
$manifestCheck=[scriptblock]::Create($manifestGate[0].Extent.Text)
$versionCheck=[scriptblock]::Create($versionGate[0].Extent.Text)
foreach($match in @($false,$true)){
    $manifestLease=[IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes('inert manifest'),$false)
    try{
        $actual=(Get-FileHash -InputStream $manifestLease -Algorithm SHA256).Hash;$manifestLease.Position=0
        $pointer=@{ManifestSha256=$(if($match){$actual}else{'0'*64});Version='1.0.0-rc.6'}
        $rejected=$false;try{&$manifestCheck}catch{$rejected=$true}
        if($rejected -eq $match){throw 'Exact manifest pin regression.'}
        $bundle=@{Version=@{Text=$(if($match){$pointer.Version}else{'1.0.0'})}}
        $rejected=$false;try{&$versionCheck}catch{$rejected=$true}
        if($rejected -eq $match){throw 'Exact pointer/package version regression.'}
    }finally{$manifestLease.Dispose()}
}
$installGate=@($ast.FindAll({param($node)$node-is[Management.Automation.Language.IfStatementAst]-and$node.Extent.Text.StartsWith("if (`$Operation -eq 'Install') {")-and$node.Extent.Text.Contains('Assert-BapInstallTransition $bundle')},$true))
$checkOnly=@($ast.FindAll({param($node)$node-is[Management.Automation.Language.IfStatementAst]-and$node.Extent.Text.Contains('Check only; no maintenance executed.')},$true))
$entry=@($ast.FindAll({param($node)$node-is[Management.Automation.Language.CommandAst]-and$node.InvocationOperator-eq[Management.Automation.Language.TokenKind]::Ampersand},$true))
if($installGate.Count-ne1-or$checkOnly.Count-ne1-or$entry.Count-ne1-or$installGate[0].Extent.StartOffset-ge$checkOnly[0].Extent.StartOffset-or$checkOnly[0].Extent.StartOffset-ge$entry[0].Extent.StartOffset){throw 'Install downgrade and CheckOnly gates must precede the package entry.'}
$pendingGuard=$dispatch.IndexOf("if (Test-Path -LiteralPath (Join-Path `$GameRoot 'BetterAstralParty.reinstall-v3.pending'))")
if($pendingGuard-lt0-or$pendingGuard-ge$installGate[0].Extent.StartOffset){throw 'Pending generation must block every operation before normal/fresh dispatch.'}
# Exercise the actual operation split without opening a game or executing maintenance.
$gate=[scriptblock]::Create($installGate[0].Extent.Text)
foreach($Operation in @('Install','Uninstall')){
    $script:transitionCalls=0
    function Get-BapCleanReinstallPlan {param($Bundle)return $null}
    function Assert-BapInstallTransition {param($Bundle)$script:transitionCalls++;throw 'Downgrade blocked.'}
    $rejected=$false
    try{&$gate}catch{if($_.Exception.Message-ne'Downgrade blocked.'){throw};$rejected=$true}
    finally{Remove-Item Function:Assert-BapInstallTransition;Remove-Item Function:Get-BapCleanReinstallPlan}
    if(($Operation-eq'Install')-ne$rejected-or$script:transitionCalls-ne$(if($Operation-eq'Install'){1}else{0})){throw 'Install floor must not block removal of a newer version.'}
}
$install=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'install.ps1'),[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw ($errors -join [char]10) }
$fresh=@($install.FindAll({param($node)$node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text.StartsWith('if ($reinstallPlan) {')},$true))
$observe=@($install.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Assert-BapWholeBridge'},$true))
if ($fresh.Count -ne 1 -or $observe.Count -ne 1 -or $fresh[0].Extent.EndOffset -ge $observe[0].Extent.StartOffset) { throw 'Fresh whole observation must follow completed history retirement.' }
$freshGate=[scriptblock]::Create($fresh[0].Extent.Text)
foreach ($mode in @('Existing','Declined','Fresh','UpdateOnly','Recovery')) {
    $reinstallPlan=if($mode -eq 'Existing'){$null}else{@{Version='7.2.0'}}
    $installBundle=@{Version=@{Text='1.0.0-rc.5'}};$installLock=[object]::new()
    $UpdateOnly=$mode -eq 'UpdateOnly';$RecoveryPlan=if($mode -eq 'Recovery'){'explicit-plan'}else{''}
    $script:retireCalls=0;$script:promptCalls=0
    function Read-Host {param($Prompt)$script:promptCalls++;if($mode -eq 'Declined'){return 'n'};return 'y'}
    function Write-Host {param($Object)}
    function Move-BapReinstallHistory {param($Bundle,$Plan,$HeldBackupLock)
        if (![object]::ReferenceEquals($HeldBackupLock,$installLock)) { throw 'Installer must reuse its existing backup lock.' }
        $script:retireCalls++
    }
    $rejected=$false
    try { &$freshGate } catch {
        if ($_.Exception.Message -notin @('Reinstall cancelled; history retained.','Clean reinstall requires normal installation, not UpdateOnly or recovery.')) { throw }
        $rejected=$true
    } finally {Remove-Item Function:Read-Host;Remove-Item Function:Write-Host;Remove-Item Function:Move-BapReinstallHistory}
    if ($rejected -ne ($mode -in @('Declined','UpdateOnly','Recovery')) -or $script:retireCalls -ne $(if($mode -eq 'Fresh'){1}else{0}) -or $script:promptCalls -ne $(if($mode -in @('Fresh','Declined')){1}else{0})) { throw "Ordinary installer generation guard regression: $mode" }
}
$reinstall=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'install-reinstall.ps1'),[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw ($errors -join [char]10) }
$absence=@($reinstall.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Assert-BapReinstallAbsent'},$true))
if ($absence.Count -ne 1) { throw 'Expected one shared reinstall absence check.' }
$legacyJournalGuard=@($absence[0].FindAll({param($node)$node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Get-InstallJournalPath'},$true))
if ($legacyJournalGuard.Count) { throw 'An ordinary installer journal must not by itself block clean-reinstall preflight.' }
$move=@($reinstall.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Move-BapReinstallHistory'},$true))
if ($move.Count -ne 1) { throw 'Expected one shared reinstall mover.' }
$body=$move[0].Body.Extent.Text
$directoryPin=$body.IndexOf('$api.Directory.Invoke(')
$revalidate=$body.IndexOf('$current=Get-BapCleanReinstallPlan ')
$backupPins=$body.IndexOf('foreach ($path in $Plan.Pins.Keys)')
$gamePins=$body.IndexOf('$file=$api.Open.Invoke($gameFence,')
$waterOpen=$body.IndexOf('$water=$api.Open.Invoke(')
if ($directoryPin -lt 0 -or $revalidate -le $directoryPin -or $backupPins -le $revalidate -or $gamePins -le $backupPins -or $waterOpen -le $gamePins -or [regex]::Matches($body,[regex]::Escape('$current=Get-BapCleanReinstallPlan ')).Count -ne 1) { throw 'Pin work directories before validation, then exclusively lease evidence; never reopen leased files.' }
$fixtureAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'test-clean-reinstall.ps1'),[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw ($errors -join [char]10) }
$fixtureText=$fixtureAst.Extent.Text
$protectionGate=@($fixtureAst.EndBlock.Statements | Where-Object {$_ -is [Management.Automation.Language.PipelineAst] -and $_.Extent.Text -ceq 'Assert-FixtureProtection'})
$fixtureImport=@($fixtureAst.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst] -and $node.InvocationOperator -eq [Management.Automation.Language.TokenKind]::Dot},$true)) | Select-Object -First 1
$fixtureTry=@($fixtureAst.EndBlock.Statements | Where-Object {$_ -is [Management.Automation.Language.TryStatementAst]})
if ($protectionGate.Count -ne 1 -or !$fixtureImport -or $fixtureTry.Count -ne 1 -or $protectionGate[0].Extent.EndOffset -ge $fixtureTry[0].Extent.StartOffset -or $fixtureTry[0].Extent.StartOffset -ge $fixtureImport.Extent.StartOffset) { throw 'Fixture protection must fail closed before imports and changes.' }
if (!$fixtureText.Contains('$sourceLeases.Add([IO.File]::Open(') -or !$fixtureTry[0].Finally.Extent.Text.Contains('$lease.Dispose()')) { throw 'Fixture code inputs must remain leased until finalization.' }
foreach ($name in @('install-policy.ps1','install-reinstall.ps1')) {
    if (!$fixtureText.Contains("'$name'")) { throw 'Fixture imported source lease is missing.' }
}
if ($fixtureAst.ParamBlock -or $fixtureText -match 'Add-Type|Assembly\]::Load|scriptblock\]::Create|\$env:|::Delete\(|::Write|::Copy\(|::CreateDirectory|Move-BapReinstallHistory|Get-BapCleanReinstallPlan') { throw 'History fixture must not load binaries, mutate files/environment or run maintenance.' }
$allowedFixtureCommands=@('Get-MpComputerStatus','Where-Object','Join-Path','Assert-FixtureProtection','Test-BapRemovedHistory','ConvertTo-Json','Write-Host')
foreach ($command in $fixtureAst.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst]},$true)) {
    if ($command.InvocationOperator -eq [Management.Automation.Language.TokenKind]::Dot) {
        if ($command.Extent.Text -cnotin @('. (Join-Path $PSScriptRoot ''install-policy.ps1'')','. (Join-Path $PSScriptRoot ''install-reinstall.ps1'')')) { throw 'Fixture import must be a fixed reviewed source path.' }
    } elseif ($command.InvocationOperator -eq [Management.Automation.Language.TokenKind]::Ampersand -or $command.GetCommandName() -cnotin $allowedFixtureCommands) { throw 'Unexpected executable fixture command.' }
}
if (!$fixtureText.Contains('Native signature/fence/journal/rename, installation, game and automatic updates are NOT tested.')) { throw 'Reduced in-memory test scope must remain explicit.' }
Write-Host 'PASS: version-neutral pinned development pointer, installer generation/consent/lock ordering and fixture safety structure; no installer or CMD executed.'
