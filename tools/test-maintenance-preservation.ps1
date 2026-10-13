param([string]$EvidencePath)
$ErrorActionPreference='Stop'
# Production AST and inert scratch files only; no installer, Steam, helper or game is executed.
$scratch=Join-Path ([IO.Path]::GetTempPath()) ('bap-maintenance-preservation-'+[guid]::NewGuid().ToString('N'))
$checks=[Collections.Generic.List[object]]::new();$sourceHashes=@{}
function Check([string]$Name,[bool]$Value) { $checks.Add([pscustomobject]@{case=$Name;passed=$Value});if(!$Value){throw ('Failed: '+$Name)} }
function Parse([string]$Name) {
    $path=Join-Path $PSScriptRoot $Name;$sourceHashes[$Name]=(Get-FileHash -LiteralPath $path).Hash
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw ('Source parse failure: '+$Name)};return $ast
}
function Part($Ast,[type]$Type,[string]$Start,[string]$Contains='') {
    $matches=@($Ast.FindAll({param($node)$node -is $Type -and $node.Extent.Text.StartsWith($Start) -and $node.Extent.Text.Contains($Contains)},$true))
    if($matches.Count -ne 1){throw ('Missing or ambiguous source block: '+$Start)};return $matches[0].Extent.Text
}
function Put([string]$Path,[string]$Text) { $null=[IO.Directory]::CreateDirectory((Split-Path -Parent $Path));[IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false)) }
function Hash([string]$Path) { return (Get-FileHash -LiteralPath $Path).Hash }
function Snapshot([string]$Root) { return ((Get-ChildItem -LiteralPath $Root -Recurse -File|Sort-Object FullName|ForEach-Object {$_.FullName+'='+(Hash $_.FullName)}) -join "`n") }
Add-Type @'
public static class SteamLauncher {
    public static string HelperPair;
    public static string CheckOwnedHelper(string root) { return HelperPair; }
    // Authentication is covered by native fixtures; this fixture only tests the planner.
    public static void ValidateInstalledReceipt(byte[] bytes) { }
}
'@
try {
    $uninstall=Parse 'uninstall.ps1';$reinstall=Parse 'install-reinstall.ps1';$backup=Parse 'install-backup.ps1'
    . ([scriptblock]::Create((Part $backup ([Management.Automation.Language.FunctionDefinitionAst]) 'function Assert-InstallTarget(')))
    . ([scriptblock]::Create((Part $backup ([Management.Automation.Language.FunctionDefinitionAst]) 'function Read-InstallRecoveryJournal(')))
    . ([scriptblock]::Create((Part $reinstall ([Management.Automation.Language.FunctionDefinitionAst]) 'function Get-BapCleanReinstallPlan(')))
    $game=Join-Path $scratch 'inventory/game';$backupRoot=Join-Path $scratch 'inventory/backups'
    $null=[IO.Directory]::CreateDirectory($game)
    $probe=@{GateCalls=0;Selected='';ExpectedGame=$game;ExpectedBackup=$backupRoot}
    function Assert-BapInstallRoot($Bundle) { if($Bundle.GameRoot -cne $probe.ExpectedGame){throw 'Fixture game root escaped'};return @{WaterHash=('A'*64)} }
    function Assert-BapReinstallAbsent($Bundle) { if($Bundle.GameRoot -cne $probe.ExpectedGame){throw 'Fixture game root escaped'} }
    function Enter-BapUpdateMaintenance {param($GameRoot,[switch]$ReadOnly,$VerifiedBundle);if(!$ReadOnly -or $GameRoot -cne $probe.ExpectedGame){throw 'Unexpected maintenance mutation'} }
    function Assert-BapHelperBootstrap($Bundle) { if($Bundle.GameRoot -cne $probe.ExpectedGame){throw 'Fixture bootstrap root escaped'} }
    function Get-InstallJournalPath([string]$GameRoot) { if($GameRoot -cne $probe.ExpectedGame){throw 'Fixture journal root escaped'};return (Join-Path $probe.ExpectedBackup 'pending.json') }
    $actualReader=(Get-Command Read-InstallRecoveryJournal).ScriptBlock
    function Read-InstallRecoveryJournal {
        param($GameRoot,$AllowedTargets,$ExpectedJournalHash,$CompletedBackupId)
        if($GameRoot -cne $probe.ExpectedGame){throw 'Exact proof gate root escaped'}
        foreach($target in $AllowedTargets){Assert-InstallTarget $GameRoot $target}
        $probe.GateCalls++;$probe.Selected=$CompletedBackupId
        throw 'Fixture exact completed-journal proof gate reached.'
    }
    $latest=''
    for($i=0;$i -lt 513;$i++){
        $id=('{0:x32}' -f $i);$path=Join-Path (Join-Path $backupRoot $id) 'completed.json';Put $path 'inert completed inventory'
        [IO.File]::SetLastWriteTimeUtc($path,([datetime]'2026-01-01T00:00:00Z').AddSeconds($i));$latest=$id
    }
    $before=Snapshot $scratch
    try { Get-BapCleanReinstallPlan @{GameRoot=$game;Expected=@{'BepInEx/plugins/BetterAstralParty/BetterAstralParty.dll'=('B'*64)}};throw 'Expected exact proof gate' }
    catch { if($_.Exception.Message -cne 'Fixture exact completed-journal proof gate reached.'){throw} }
    Check '>512 completed backups reach existing exact journal proof validation' ($probe.GateCalls -eq 1 -and $probe.Selected -ceq $latest)
    Check 'completed inventory discovery is read-only' ((Snapshot $scratch) -ceq $before)
    . ([scriptblock]::Create('function Read-InstallRecoveryJournal {'+$actualReader.ToString()+'}'))
    function Read-BapInstallJson([byte[]]$Bytes) { return ([Text.Encoding]::UTF8.GetString($Bytes)|ConvertFrom-Json) }
    $badId=[guid]::NewGuid().ToString('N');$badDir=Join-Path $backupRoot $badId
    $outside=Join-Path $scratch 'inventory/game-sibling/outside.keep';Put $outside 'unrelated alias escape must stay'
    $entry=@{Target=$outside;Existed=$false;Backup=(Join-Path $badDir '0.bin');Hash=$null}
    Put (Join-Path $badDir 'completed.json') (@{GameRoot=$game;BackupDir=$badDir;Entries=@($entry)}|ConvertTo-Json -Depth 5)
    $outsideHash=Hash $outside
    try { Read-InstallRecoveryJournal $game -AllowedTargets @($outside) -CompletedBackupId $badId;throw 'Expected outside-root rejection' }
    catch { if($_.Exception.Message -notlike 'Target outside game directory:*'){throw} }
    Check 'exact completed journal rejects sibling-prefix root escape' ((Hash $outside) -ceq $outsideHash)
    $alias=Join-Path $game '../game-sibling/outside.keep'
    try { Assert-InstallTarget $game $alias;throw 'Expected alias rejection' }
    catch { if($_.Exception.Message -notlike 'Target outside game directory:*'){throw} }
    Check 'canonicalized traversal alias cannot escape selected root' ((Hash $outside) -ceq $outsideHash)
    $whatIfId=[guid]::NewGuid().ToString('N');$whatIfDir=Join-Path $backupRoot $whatIfId
    $whatIfTarget=Join-Path $game 'whatif-owned.keep';$whatIfBackup=Join-Path $whatIfDir '0.bin'
    Put $whatIfTarget 'inert owned bytes';Put $whatIfBackup 'inert owned bytes'
    $whatIfEntry=@{Target=$whatIfTarget;Existed=$true;Backup=$whatIfBackup;Hash=(Hash $whatIfBackup)}
    $whatIfJournal=Join-Path $whatIfDir 'completed.json'
    Put $whatIfJournal (@{GameRoot=$game;BackupDir=$whatIfDir;Entries=@($whatIfEntry)}|ConvertTo-Json -Depth 5)
    $whatIfHash=Hash $whatIfJournal;$whatIfBefore=Snapshot $scratch
    $whatIfReader=[scriptblock]::Create('[CmdletBinding(SupportsShouldProcess=$true)] param($Game,$Allowed,$Expected,$Id) Read-InstallRecoveryJournal $Game $Allowed $Expected $Id')
    $whatIfResult=& $whatIfReader $game @($whatIfTarget) $whatIfHash $whatIfId -WhatIf
    Check 'WhatIf still computes exact completed journal and backup hashes' ($whatIfResult.JournalSha256 -ceq $whatIfHash -and $whatIfResult.State.Entries[0].Hash -ceq $whatIfEntry.Hash)
    Check 'WhatIf journal validation preserves all scratch bytes' ((Snapshot $scratch) -ceq $whatIfBefore)
    $allow=Part $uninstall ([Management.Automation.Language.AssignmentStatementAst]) '$files = @('
    $read=Part $uninstall ([Management.Automation.Language.IfStatementAst]) 'if (Test-Path -LiteralPath $receiptPath'
    $helper=Part $uninstall ([Management.Automation.Language.IfStatementAst]) 'if ((Test-Path -LiteralPath $helperPath)' 'CheckOwnedHelper'
    $ownership=Part $uninstall ([Management.Automation.Language.ForEachStatementAst]) 'foreach ($file in $files)'
    $keep=Part $uninstall ([Management.Automation.Language.IfStatementAst]) 'if($keptReceiptFile)' '$plannedHashes.Remove($path)'
    $receiptTarget=Part $uninstall ([Management.Automation.Language.IfStatementAst]) 'if ($receipt -and !$keptReceiptFile)'
    $confirm=Part $uninstall ([Management.Automation.Language.IfStatementAst]) 'if (!$PSCmdlet.ShouldProcess('
    $hashFunction=Part $uninstall ([Management.Automation.Language.FunctionDefinitionAst]) 'function Get-UninstallHash('
    $program=@'
[CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High')]
param($GameRoot,$FixtureRoot,$Expected,$Probe)
$externalBundle=@{Expected=$Expected;GameRoot=$GameRoot};$root=Join-Path $FixtureRoot 'no-package'
$receiptPath=Join-Path $GameRoot 'BetterAstralParty.install.json'
$helperPath=Join-Path $GameRoot 'BetterAstralParty-UpdateHelper.exe';$helperReceipt=Join-Path $GameRoot 'BetterAstralParty.helper.receipt'
$receipt=$null;$hashes=@{};$targets=@();$missingOwned=@();$plannedHashes=@{};$keptReceiptFile=$false
function Read-BapInstallFile([string]$Path) { Assert-InstallTarget $GameRoot $Path;return ,([IO.File]::ReadAllBytes($Path)) }
function Get-BapInstallVerifier($Bundle) { if($Bundle.GameRoot -cne $GameRoot){throw 'Verifier root escaped'};return [SteamLauncher].Assembly }
'@
    $program+="`n"+(($hashFunction,$allow,$read,$helper,$ownership,$keep,$receiptTarget) -join "`n")
    $program+="`n`$Probe.Targets=@(`$targets);`$Probe.Planned=@{};foreach(`$key in `$plannedHashes.Keys){`$Probe.Planned[`$key]=`$plannedHashes[`$key]};`$Probe.KeptReceipt=`$keptReceiptFile`n"+$confirm+"`n`$Probe.Confirmed=`$true"
    $planner=[scriptblock]::Create($program)
    $files=@();. ([scriptblock]::Create($allow));$owned=@($files|Where-Object {$_.Source})
    if($owned.Count -ne 8){throw 'Fixed owned inventory changed'}
    foreach($mode in @('changed-owned-valid-helper','unverified-helper','intact-valid-helper')){
        $case=Join-Path $scratch $mode;$selectedGame=Join-Path $case 'game';$entries=@();$expected=@{}
        foreach($file in $owned){
            $target=Join-Path $selectedGame $file.Path;Put $target ('owned '+$file.Path)
            $expected[$file.Path]=Hash $target;$entries+=@{path=$file.Path;sha256=(Hash $target)}
        }
        $dll=Join-Path $selectedGame $owned[0].Path
        if($mode -eq 'changed-owned-valid-helper'){Put $dll 'user-modified DLL preserve'}
        $config=Join-Path $selectedGame 'BepInEx/config/kr.betterastralparty.mod.cfg';Put $config 'owned settings'
        $foreign=Join-Path $selectedGame 'BepInEx/plugins/OtherMod.dll';Put $foreign 'other mod keep'
        $receiptPath=Join-Path $selectedGame 'BetterAstralParty.install.json';Put $receiptPath (@{schema=1;baseline='1.2.1';channelState='inert planner boundary substitute';owner='kr.betterastralparty.mod';loaderBefore=$false;files=$entries}|ConvertTo-Json -Depth 5)
        $image=Join-Path $selectedGame 'BetterAstralParty-UpdateHelper.exe';$helperReceipt=Join-Path $selectedGame 'BetterAstralParty.helper.receipt'
        Put $image 'inert helper';Put $helperReceipt 'inert helper receipt'
        [SteamLauncher]::HelperPair=if($mode -eq 'unverified-helper'){$null}else{(Hash $image)+':'+(Hash $helperReceipt)}
        $planProbe=@{Targets=@();Planned=@{};KeptReceipt=$false;Confirmed=$false};$before=Snapshot $selectedGame
        $null=& $planner $selectedGame $case $expected $planProbe -WhatIf
        Check ($mode+' WhatIf stops before confirmation without mutation') (!$planProbe.Confirmed -and (Snapshot $selectedGame) -ceq $before)
        if($mode -ne 'intact-valid-helper'){
            Check ($mode+' preserves helper pair and receipt') ($planProbe.KeptReceipt -and $image -notin $planProbe.Targets -and $helperReceipt -notin $planProbe.Targets -and $receiptPath -notin $planProbe.Targets -and !$planProbe.Planned.ContainsKey($image) -and !$planProbe.Planned.ContainsKey($helperReceipt))
            Check ($mode+' still scopes other confirmed-owned removals') ($config -in $planProbe.Targets -and (Join-Path $selectedGame 'BetterAstralParty-Mod.cmd') -in $planProbe.Targets -and $foreign -notin $planProbe.Targets)
        } else {
            Check 'intact installation still includes verified helper pair and receipt' (!$planProbe.KeptReceipt -and $image -in $planProbe.Targets -and $helperReceipt -in $planProbe.Targets -and $receiptPath -in $planProbe.Targets)
        }
        if($mode -eq 'changed-owned-valid-helper'){Check 'changed DLL itself remains out of scoped removal' ($dll -notin $planProbe.Targets)}
        $null=& $planner $selectedGame $case $expected $planProbe -Confirm:$false
        Check ($mode+' normal planning does not perform filesystem mutation') ($planProbe.Confirmed -and (Snapshot $selectedGame) -ceq $before)
    }
    $result=[ordered]@{runtime=$PSVersionTable.PSVersion.ToString();passed=$checks.Count;failed=0;cases=@($checks);sourceSha256=$sourceHashes;scope='source AST, native read-only path checks and inert scratch files only; signed verification/native removal/Steam integration not claimed';realSteamOrGameTouched=$false}
    if($EvidencePath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($EvidencePath),($result|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))}
    $result|ConvertTo-Json -Depth 5
} finally {
    $resolved=[IO.Path]::GetFullPath($scratch)
    if((Split-Path $resolved -Parent) -ne [IO.Path]::GetTempPath().TrimEnd('\') -or (Split-Path $resolved -Leaf) -notlike 'bap-maintenance-preservation-*'){throw 'Unsafe fixture cleanup'}
    if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}

