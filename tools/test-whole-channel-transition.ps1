[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$StablePackageRoot,
    [Parameter(Mandatory)][string]$StableManifestSha256,
    [Parameter(Mandatory)][string]$BetaPackageRoot,
    [Parameter(Mandatory)][string]$BetaManifestSha256,
    [string]$UpdateZipPath,
    [string]$UpdateZipSha256,
    [string]$CompatibilityGameRoot,
    [string]$CompatibilityCacheRoot,
    [string]$DotnetRoot
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$env:DOTNET_GENERATE_ASPNET_CERTIFICATE='false'
$projectRoot=[IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$artifactRoot=Join-Path $projectRoot 'artifacts'
$buildRoot=Join-Path $artifactRoot ('wct-build-'+[Guid]::NewGuid().ToString('N'))
$scratch=Join-Path $artifactRoot ('wct-'+[Guid]::NewGuid().ToString('N'))
$archiveScratch=Join-Path $artifactRoot ('wct-'+[Guid]::NewGuid().ToString('N'))
foreach($path in @($buildRoot,$scratch,$archiveScratch)){
    if((Split-Path -Parent $path) -cne $artifactRoot -or (Test-Path -LiteralPath $path)){throw 'Fresh direct artifact output required.'}
}
$leases=[Collections.Generic.List[IDisposable]]::new()
$pins=@{}
function Read-Held([string]$Path,[string]$Expected=''){
    $file=[IO.File]::Open($Path,'Open','Read','Read');$leases.Add($file)
    $hash=(Get-FileHash -InputStream $file -Algorithm SHA256).Hash
    if($Expected -and $hash -cne $Expected){throw ('Pinned input changed: '+$Path)}
    $pins[$Path]=$hash;$file.Position=0
    $bytes=[byte[]]::new([int]$file.Length);$offset=0
    while($offset -lt $bytes.Length){$count=$file.Read($bytes,$offset,$bytes.Length-$offset);if($count -le 0){throw 'Truncated input.'};$offset+=$count}
    return ,$bytes
}
function Read-Ast([string]$Path){
    $bytes=Read-Held $Path;$tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput([Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xFEFF),[ref]$tokens,[ref]$errors)
    if($errors.Count){throw ('Invalid source syntax: '+$Path)};return $ast
}
function Part($Ast,[type]$Type,[string]$Start){
    $nodes=@($Ast.FindAll({param($node)$node -is $Type -and $node.Extent.Text.StartsWith($Start,[StringComparison]::Ordinal)},$true))
    if($nodes.Count -ne 1){throw ('Missing/ambiguous source block: '+$Start)};return $nodes[0]
}
try{
    $packages=@(
        @{Path=[IO.Path]::GetFullPath($StablePackageRoot);Hash=$StableManifestSha256;Channel='Stable';Version=$null},
        @{Path=[IO.Path]::GetFullPath($BetaPackageRoot);Hash=$BetaManifestSha256;Channel='Beta';Version=$null}
    )
    foreach($package in $packages){
        if($package.Hash -cnotmatch '\A[A-F0-9]{64}\z'){throw 'Exact uppercase manifest SHA-256 required.'}
        $bytes=Read-Held (Join-Path $package.Path 'package-manifest.json') $package.Hash
        $manifest=[Text.Encoding]::UTF8.GetString($bytes)|ConvertFrom-Json
        if($package.Version -and $manifest.version -cne $package.Version){throw 'Package version mismatch.'}
        if([version]($manifest.version -split '-')[0] -lt [version]'1.2.1'){throw 'A new-baseline complete package is required; previous installers are not a supported seed.'}
        $package.Version=$manifest.version
        $required=@('artifacts/BetterAstralParty.dll','artifacts/BetterAstralParty-Launcher.exe','artifacts/BetterAstralParty.compatibility.json',
            'tools/AstralParty-Vanilla.cmd','tools/BetterAstralParty-Mod.cmd','tools/BetterAstralParty-Steam.ps1','tools/check-compatibility.ps1','tools/steam-shortcut.ps1',
            'update-proof/update.descriptor','update-proof/update.signature','helper-bootstrap/helper.descriptor','helper-bootstrap/helper.signature','helper-bootstrap/BetterAstralParty-UpdateHelper.exe')
        foreach($relative in $required){
            $row=@($manifest.files|Where-Object {$_.path -ceq $relative})
            if($row.Count -ne 1 -or $row[0].sha256 -cnotmatch '\A[A-F0-9]{64}\z'){throw ('Missing pinned package input: '+$relative)}
            $null=Read-Held (Join-Path $package.Path $relative) $row[0].sha256
        }
    }
    $automaticArguments=@()
    if($UpdateZipPath -or $UpdateZipSha256 -or $CompatibilityGameRoot -or $CompatibilityCacheRoot){
        if(!$UpdateZipPath -or $UpdateZipSha256 -cnotmatch '\A[A-F0-9]{64}\z' -or !$CompatibilityGameRoot -or !$CompatibilityCacheRoot){throw 'Automatic scratch checks require exact ZIP SHA-256 and explicit public game/cache roots.'}
        $UpdateZipPath=[IO.Path]::GetFullPath($UpdateZipPath)
        $null=Read-Held $UpdateZipPath $UpdateZipSha256
        $automaticArguments=@($UpdateZipPath,[IO.Path]::GetFullPath($CompatibilityGameRoot),[IO.Path]::GetFullPath($CompatibilityCacheRoot))
    }
    $sources=@('focus-tests/whole-channel-transition/WholeChannelTransitionFixture.csproj','focus-tests/whole-channel-transition/Program.cs','tools/test-whole-channel-transition.ps1')
    foreach($folder in @('updater','src/Observability')){
        $sources+=@(Get-ChildItem -LiteralPath (Join-Path $projectRoot $folder) -File -Filter '*.cs' |
            Where-Object {$_.Name -ne 'UpdateHelperProgram.cs'}|ForEach-Object {$_.FullName.Substring($projectRoot.Length+1).Replace('\','/')})
    }
    foreach($source in $sources){$null=Read-Held (Join-Path $projectRoot $source)}
    $uninstall=Read-Ast (Join-Path $PSScriptRoot 'uninstall.ps1')
    $blocks=@(
        (Part $uninstall ([Management.Automation.Language.AssignmentStatementAst]) '$files = @('),
        (Part $uninstall ([Management.Automation.Language.AssignmentStatementAst]) '$missingOwned = @()'),
        (Part $uninstall ([Management.Automation.Language.IfStatementAst]) 'if (Test-Path -LiteralPath $receiptPath'),
        (Part $uninstall ([Management.Automation.Language.ForEachStatementAst]) 'foreach ($file in $files)'),
        (Part $uninstall ([Management.Automation.Language.IfStatementAst]) 'if ($missingOwned.Count -and !$keptReceiptFile)'),
        (Part $uninstall ([Management.Automation.Language.IfStatementAst]) 'if ($receipt -and !$keptReceiptFile)')
    )
    $backupTargets=Part $uninstall ([Management.Automation.Language.AssignmentStatementAst]) '$backupTargets = @($targets)'
    $absentEntry=Part $uninstall ([Management.Automation.Language.IfStatementAst]) 'if (!$entry.Existed)'
    $absentGuard=[scriptblock]::Create('param($Memory,$Entries) function Test-Path {param($LiteralPath) return $Memory.ContainsKey($LiteralPath)} '+
        '$removalLease=[pscustomobject]@{Memory=$Memory}; $removalLease|Add-Member -MemberType ScriptMethod -Name Remove -Value {param([string]$Target) '+
        'if($this.Memory.ContainsKey($Target)){throw "File appeared during uninstall; retained"}}; '+
        '$rollbackExpected=@{}; foreach($entry in $Entries) {'+$absentEntry.Extent.Text+'}; return $rollbackExpected')
    $policy=Read-Ast (Join-Path $PSScriptRoot 'install-policy.ps1')
    $sameVersion=Part $policy ([Management.Automation.Language.IfStatementAst]) 'if((Compare-BapInstallVersion $Bundle.Version $current) -eq 0'
    $sameVersionGuard=[scriptblock]::Create('param($Bundle,$current,$samePayload) '+$sameVersion.Extent.Text)
    foreach($name in @('install-policy.ps1','install-backup.ps1','install-helper.ps1','install-reinstall.ps1')){
        $ast=Read-Ast (Join-Path $PSScriptRoot $name)
        if(@($ast.EndBlock.Statements|Where-Object {$_ -isnot [Management.Automation.Language.FunctionDefinitionAst]}).Count){throw 'Predicate imports must be function definitions only.'}
        . ([scriptblock]::Create($ast.Extent.Text))
    }
    # These exact ownership blocks run in a virtual filesystem: no remover/installer/Steam call is included.
    $program=@'
param($Memory,$Verifier,$ReceiptBytes)
# The packaged uninstaller runs without strict mode; match it only inside this virtual planner.
Set-StrictMode -Off
$GameRoot='C:\bap-virtual-whole-channel\game';$root='C:\bap-virtual-whole-channel\old-package'
$receiptPath=Join-Path $GameRoot 'BetterAstralParty.install.json'
$externalBundle=@{Expected=$Memory.Expected};$receipt=$null;$hashes=@{};$targets=@();$plannedHashes=@{};$keptReceiptFile=$false
function Assert-InstallTarget($Game,$Target){if(!$Target.StartsWith($Game+'\',[StringComparison]::Ordinal)){throw 'Virtual boundary violation.'}}
function Test-Path{param($LiteralPath,$PathType)return $Memory.Hashes.ContainsKey($LiteralPath)}
function Get-UninstallHash($Path){if(!$Memory.Hashes.ContainsKey($Path)){throw 'Unexpected virtual read.'};return $Memory.Hashes[$Path]}
function Read-BapInstallFile($Path){if($Path -cne $receiptPath){throw 'Unexpected virtual bytes.'};return ,$ReceiptBytes}
function Read-BapInstallJson([byte[]]$Bytes){return ([Text.Encoding]::UTF8.GetString($Bytes)|ConvertFrom-Json)}
function Get-BapInstallVerifier{return $Verifier}
function Write-Warning{param($Message)}
'@
    $program+=[char]10+(($blocks|ForEach-Object {$_.Extent.Text})-join [char]10)+[char]10+$backupTargets.Extent.Text+[char]10+'return @{Targets=@($targets);Missing=@($missingOwned);BackupTargets=@($backupTargets);Hashes=$plannedHashes;Accepted=($null -ne $receipt)}'+[char]10
    $planner=[scriptblock]::Create($program)
    # The virtual partial-removal gate records invocation; signed/native checks remain in Program.cs.
    Add-Type -TypeDefinition @'
using System;
using System.Reflection;
public sealed class BapWholeVirtualAssembly {
    public Assembly Native; public bool PartialAllowed = true; public int PartialCalls;
    public BapWholeVirtualAssembly(Assembly native) { Native = native; }
    public BapWholeVirtualType GetType(string name) { if(name != "SteamLauncher") throw new Exception("Unexpected virtual type"); return new BapWholeVirtualType(this); }
}
public sealed class BapWholeVirtualType {
    readonly BapWholeVirtualAssembly owner;
    public BapWholeVirtualType(BapWholeVirtualAssembly value) { owner = value; }
    public BapWholeVirtualMethod GetMethod(string name, BindingFlags flags) {
        // This planner deliberately simulates the frozen older package inspector.
        // New signed/native package-aware checks stay covered by the native fixture.
        if(name == "ValidatePartialRemovalWithPackage") return null;
        if(name != "ValidateInstalledReceipt" && name != "ValidatePartialRemoval") throw new Exception("Unexpected virtual method");
        return new BapWholeVirtualMethod(owner, name);
    }
}
public sealed class BapWholeVirtualMethod {
    readonly BapWholeVirtualAssembly owner; readonly string name;
    public BapWholeVirtualMethod(BapWholeVirtualAssembly value, string method) { owner = value; name = method; }
    public object Invoke(object target, object[] args) {
        if(name == "ValidateInstalledReceipt") return owner.Native.GetType("SteamLauncher").GetMethod(name, BindingFlags.Public | BindingFlags.Static).Invoke(target, args);
        owner.PartialCalls++;
        if(args.Length != 1 || (string)args[0] != @"C:\bap-virtual-whole-channel\game" || !owner.PartialAllowed) throw new Exception("Virtual partial-removal refusal");
        return null;
    }
}
'@
    if(!$DotnetRoot){$DotnetRoot=Join-Path $projectRoot '.dotnet'}
    $dotnet=Join-Path $DotnetRoot 'dotnet.exe';$project=Join-Path $projectRoot 'focus-tests/whole-channel-transition/WholeChannelTransitionFixture.csproj'
    $common=@("-p:BaseIntermediateOutputPath=$buildRoot/obj/","-p:MSBuildProjectExtensionsPath=$buildRoot/obj/",'-p:UseSharedCompilation=false','-p:NuGetAudit=false')
    & $dotnet restore $project --configfile (Join-Path $projectRoot 'NuGet.Config') @common
    if($LASTEXITCODE -ne 0){throw 'Whole-channel fixture restore failed.'}
    & $dotnet build $project --no-restore -c Release -o (Join-Path $buildRoot 'bin') @common
    if($LASTEXITCODE -ne 0){throw 'Whole-channel fixture build failed.'}
    & $dotnet (Join-Path $buildRoot 'bin/WholeChannelTransitionFixture.dll') $scratch $artifactRoot $packages[0].Path $packages[1].Path @automaticArguments
    if($LASTEXITCODE -ne 0){throw 'Signed whole/native fixture failed; scratch evidence retained.'}
    & $dotnet (Join-Path $buildRoot 'bin/WholeChannelTransitionFixture.dll') $archiveScratch $artifactRoot $packages[0].Path $packages[1].Path 'archive-only'
    if($LASTEXITCODE -ne 0){throw 'Terminal archive/native fixture failed; scratch evidence retained.'}
    # Assembly.Load does not run Main. Native maintenance calls below are limited to the new scratch root.
    $verifier=[Reflection.Assembly]::Load([byte[]](Read-Held (Join-Path $packages[1].Path 'artifacts/BetterAstralParty-Launcher.exe')))
    $virtualVerifier=[BapWholeVirtualAssembly]::new($verifier)
    $repositories=@{Stable=[long]1410226758;Beta=[long]1401226962}
    $checks=0
    $proofs=@(Get-ChildItem -LiteralPath $scratch -File -Filter '*-proof.json')
    if($proofs.Count -ne 5){throw 'Every committed/recovered case must have receipt proof.'}
    foreach($file in $proofs){
        $proof=Get-Content -LiteralPath $file.FullName -Raw|ConvertFrom-Json
        $receipt=[Text.Encoding]::ASCII.GetBytes($proof.Receipt)
        $state=@{RootIdentity=$proof.Root;HighestVersion=$packages[0].Version}
        if(!(Test-BapRemovedHistory $proof.Channel $proof.Water $state $proof.PluginVersion $repositories $null)){throw 'Cross-channel receipt cannot bind preserved Stable watermark.'};$checks++
        $memory=@{Hashes=@{};Expected=@{}}
        foreach($entry in (($proof.Receipt|ConvertFrom-Json).files)){
            $memory.Hashes[(Join-Path 'C:\bap-virtual-whole-channel\game' $entry.path)]=$entry.sha256
            $memory.Expected[$entry.path]='A'*64
        }
        $memory.Hashes['C:\bap-virtual-whole-channel\game\BetterAstralParty.install.json']='B'*64
        $memory.Hashes['C:\bap-virtual-whole-channel\game\BepInEx\config\kr.betterastralparty.mod.cfg']='C'*64
        $memory.Hashes['C:\bap-virtual-whole-channel\game\BepInEx\plugins\OtherMod.dll']='D'*64
        $memory.Hashes['C:\bap-virtual-whole-channel\game\doorstop_config.ini']='E'*64
        $before=$memory|ConvertTo-Json -Depth 6 -Compress
        $plan=& $planner $memory $virtualVerifier $receipt
        if(!$plan.Accepted -or $plan.Targets.Count -ne 10 -or
            @($plan.Targets|Where-Object {$_ -like '*OtherMod.dll' -or $_ -like '*doorstop_config.ini'}).Count){throw 'Current cross-channel receipt ownership plan mismatch.'};$checks++
        if(($memory|ConvertTo-Json -Depth 6 -Compress) -cne $before){throw 'Virtual ownership planner mutated its inputs.'};$checks++
    }
    $virtualRoot='C:\bap-virtual-whole-channel\game'
    $pluginRelative='BepInEx/plugins/BetterAstralParty/BetterAstralParty.dll'
    $missing=@($memory.Expected.Keys|Where-Object {$_ -cne $pluginRelative})
    if($missing.Count -ne 7){throw 'Known absent non-plugin set must contain exactly seven files.'}
    $partial=@{Hashes=$memory.Hashes.Clone();Expected=$memory.Expected.Clone()}
    foreach($name in $missing){$partial.Hashes.Remove((Join-Path $virtualRoot $name))}
    $before=$partial|ConvertTo-Json -Depth 6 -Compress
    $virtualVerifier.PartialCalls=0
    $plan=& $planner $partial $virtualVerifier $receipt
    if(!$plan.Accepted -or $plan.Missing.Count -ne 7 -or $plan.Targets.Count -ne 3 -or $plan.BackupTargets.Count -ne 10 -or $virtualVerifier.PartialCalls -ne 1){throw 'Absent known owned set was not retained in the removal backup plan.'};$checks++
    foreach($name in $missing){if(!$plan.Hashes.ContainsKey((Join-Path $virtualRoot $name)) -or $null -ne $plan.Hashes[(Join-Path $virtualRoot $name)]){throw 'Absent owned target must retain a null planned hash.'};$checks++}
    if(($partial|ConvertTo-Json -Depth 6 -Compress) -cne $before){throw 'Partial planner mutated its inputs.'};$checks++
    $virtualVerifier.PartialAllowed=$false
    $refused=$false;try{$null=& $planner $partial $virtualVerifier $receipt}catch{$refused=$_.Exception.GetBaseException().Message -like '*Virtual partial-removal refusal*'}
    if(!$refused){throw 'Production partial-removal clause ignored validator refusal.'};$checks++
    $virtualVerifier.PartialAllowed=$true
    $changedPath=Join-Path $virtualRoot $missing[0];$partial.Hashes[$changedPath]='F'*64
    $before=$partial|ConvertTo-Json -Depth 6 -Compress;$virtualVerifier.PartialCalls=0
    $plan=& $planner $partial $virtualVerifier $receipt
    if(@($plan.Targets|Where-Object {$_ -ceq $changedPath -or $_ -ceq (Join-Path $virtualRoot 'BetterAstralParty.install.json')}).Count -or $virtualVerifier.PartialCalls -ne 0 -or ($partial|ConvertTo-Json -Depth 6 -Compress) -cne $before){throw 'Changed present owned file/receipt must be retained, not removed.'};$checks++
    $absentPath=Join-Path $virtualRoot $missing[1];$entry=@{Target=$absentPath;Existed=$false}
    $virtualFiles=@{};$rollback=& $absentGuard $virtualFiles @($entry)
    if(!$rollback.ContainsKey($absentPath) -or $null -ne $rollback[$absentPath]){throw 'Absent uninstall entry must be recorded without deletion.'};$checks++
    $virtualFiles[$absentPath]='new file retained';$before=$virtualFiles|ConvertTo-Json -Compress
    $refused=$false;try{$null=& $absentGuard $virtualFiles @($entry)}catch{$refused=$_.Exception.GetBaseException().Message -like '*File appeared during uninstall; retained*'}
    if(!$refused -or ($virtualFiles|ConvertTo-Json -Compress) -cne $before){throw 'Creation race must refuse and preserve the new file.'};$checks++
    $sameBundle=@{Version=(Get-BapInstallVersion $packages[1].Version)}
    $null=& $sameVersionGuard $sameBundle $sameBundle.Version $true;$checks++
    $refused=$false;try{$null=& $sameVersionGuard $sameBundle $sameBundle.Version $false}catch{$refused=$_.Exception.GetBaseException().Message -like '*Different build at the same version*'}
    if(!$refused){throw 'Same-version repair must not accept a different receipt payload.'};$checks++
    $partialProofPath=Join-Path $scratch 'bounded-partial-removal.json'
    $partialProof=Get-Content -LiteralPath $partialProofPath -Raw|ConvertFrom-Json
    if($partialProof.GameRoot -cne (Join-Path $scratch 'repair-all-nonplugin') -or $partialProof.BackupRoot -cne (Join-Path $scratch 'partial-removal-backups') -or $partialProof.BackupId -cnotmatch '\A[0-9a-f]{32}\z' -or $partialProof.Missing.Count -ne 7){throw 'Native partial-removal evidence must bind the exact new scratch paths.'}
    $scratchChecks=& {
        param($Proof,$Package)
        $selectedRoot=$Proof.GameRoot;$selectedBackup=$Proof.BackupRoot
        function Get-InstallJournalPath([string]$GameRoot){if($GameRoot -cne $selectedRoot){throw 'Non-scratch backup access rejected.'};return Join-Path $selectedBackup 'pending.json'}
        function Get-BapGameTargets([string]$GameRoot){if($GameRoot -cne $selectedRoot){throw 'Non-scratch process query rejected.'};return @()}
        function Get-Process{param($Name,$ErrorAction)if($Name -cne 'BetterAstralParty-UpdateHelper'){throw 'Unexpected process query.'};return @()}
        $bundle=$null;$count=0
        try{
            $bundle=Open-BapInstallBundle $Package.Path $selectedRoot
            if($bundle.ManifestSha256 -cne $Package.Hash -or $bundle.RootIdentity -cne $Proof.Root){throw 'Scratch bundle/root identity mismatch.'}
            $allowed=@(@($bundle.Expected.Keys)+@('BetterAstralParty.install.json','BetterAstralParty-UpdateHelper.exe','BetterAstralParty.helper.receipt','BepInEx/config/kr.betterastralparty.mod.cfg')|ForEach-Object {Join-Path $selectedRoot $_})
            $journal=Read-InstallRecoveryJournal $selectedRoot -AllowedTargets $allowed -ExpectedJournalHash $Proof.JournalSha256 -CompletedBackupId $Proof.BackupId
            $absentRows=@($journal.State.Entries|Where-Object {!$_.Existed})
            if($absentRows.Count -ne 7 -or @($absentRows|Where-Object {$_.Target -ceq (Join-Path $selectedRoot 'BepInEx/plugins/BetterAstralParty/BetterAstralParty.dll')}).Count){throw 'Actual removal journal lost the known absent non-plugin set.'};$count++
            $plan=Get-BapCleanReinstallPlan $bundle
            if(!$plan -or $plan.BackupId -cne $Proof.BackupId -or $plan.ProofHash -cne $Proof.JournalSha256 -or $plan.RootIdentity -cne $Proof.Root -or $plan.Version -cne $packages[0].Version){throw 'Actual clean-reinstall plan failed to bind retained Stable history.'};$count++
            foreach($row in $absentRows){if($plan.Pins.ContainsKey($row.Backup) -or (Test-Path -LiteralPath $row.Backup)){throw 'Absent backup must not be created or pinned.'};$count++}
            # Only the validated journal return value is substituted to exercise the core-row predicate.
            $badJournal=$journal|ConvertTo-Json -Depth 8|ConvertFrom-Json
            $pluginRow=@($badJournal.State.Entries|Where-Object {$_.Target -ceq (Join-Path $selectedRoot 'BepInEx/plugins/BetterAstralParty/BetterAstralParty.dll')})[0]
            $pluginRow.Existed=$false;$pluginRow.Hash=$null
            $coreRefused=& {
                function Read-InstallRecoveryJournal{return $badJournal}
                try{$null=Get-BapCleanReinstallPlan $bundle;return $false}catch{
                    $reason=$_.Exception.GetBaseException().Message
                    return $reason -ceq 'Missing former plugin requires signed installed-proof support; use a current complete package.' -or
                        $reason -ceq 'Unexpected recovery backup retained.'
                }
            }
            if(!$coreRefused){throw 'Frozen old inspector must refuse missing-core recovery without signed installed-proof support.'};$count++
            $backupHashes=@{};foreach($file in Get-ChildItem -LiteralPath $selectedBackup -File -Recurse){$backupHashes[$file.FullName]=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash}
            $gameHashes=@{};foreach($file in Get-ChildItem -LiteralPath $selectedRoot -File -Recurse){$gameHashes[$file.FullName]=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash}
            foreach($property in $Proof.Preserved.PSObject.Properties){if($gameHashes[(Join-Path $selectedRoot $property.Name)] -cne $property.Value){throw 'Shared/other-mod scratch file changed before history retirement.'};$count++}
            $waterPath=Join-Path $selectedRoot 'BetterAstralParty.update-v3.version';$waterBytes=[IO.File]::ReadAllBytes($waterPath)
            if([Text.Encoding]::ASCII.GetString($waterBytes) -cne ($Proof.Water -join "`n")){throw 'Native retained watermark bytes mismatch.'}
            $lock=Join-Path $selectedBackup 'pending.json.lock'
            Assert-InstallTarget $selectedBackup $lock
            $stream=[IO.File]::Open($lock,'CreateNew','Write','None');try{$stream.Flush($true)}finally{$stream.Dispose()}
            Move-BapReinstallHistory $bundle $plan $null
            if((Test-Path -LiteralPath $waterPath) -or (Test-Path -LiteralPath (Join-Path $selectedRoot 'BetterAstralParty.reinstall-v3.pending'))){throw 'Scratch history retirement left active watermark/intent.'};$count++
            $archives=@(Get-ChildItem -LiteralPath $selectedRoot -File -Filter 'BetterAstralParty.update-v3.version.uninstalled-*')
            $records=@(Get-ChildItem -LiteralPath $selectedRoot -File -Filter 'BetterAstralParty.reinstall-v3.completed-*')
            if($archives.Count -ne 1 -or $records.Count -ne 1 -or (Get-FileHash -LiteralPath $archives[0].FullName -Algorithm SHA256).Hash -cne $plan.WaterHash){throw 'Scratch retired history not preserved exactly.'};$count++
            $record=Get-Content -LiteralPath $records[0].FullName -Raw|ConvertFrom-Json
            if($record.schema -ne 1 -or $record.purpose -cne 'clean-reinstall-generation' -or $record.root -cne $Proof.Root -or $record.fromVersion -cne $plan.Version -or $record.toVersion -cne $Package.Version -or $record.packageManifestSha256 -cne $Package.Hash -or $record.backupId -cne $Proof.BackupId -or $record.proofSha256 -cne $Proof.JournalSha256 -or $record.waterSha256 -cne $plan.WaterHash -or $record.archive -cne $archives[0].Name){throw 'Scratch generation record binding mismatch.'};$count++
            $api=Get-BapReinstallFenceApi $bundle;$fence=$api.Constructor.Invoke([object[]]@([string]$selectedRoot,$null));$held=$null
            try{$held=$api.Open.Invoke($fence,[object[]]@([string]$archives[0].Name,$false,$false));if($api.RootText.GetValue($api.Identity.GetValue($held),$null) -cne $Proof.WaterIdentity){throw 'Watermark object identity changed during retirement.'};$count++}finally{if($held){$held.Dispose()};$fence.Dispose()}
            foreach($path in $backupHashes.Keys){if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $backupHashes[$path]){throw 'Removal backup/journal changed during history retirement.'};$count++}
            if(@(Get-ChildItem -LiteralPath $selectedBackup -File -Recurse).Count -ne $backupHashes.Count+1 -or !(Test-Path -LiteralPath $lock -PathType Leaf)){throw 'History retirement changed the backup inventory beyond its scratch lock.'};$count++
            foreach($path in $gameHashes.Keys){if($path -ceq $waterPath){continue};if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $gameHashes[$path]){throw 'Shared/unknown/helper-history scratch file changed during retirement.'};$count++}
            $after=@(Get-ChildItem -LiteralPath $selectedRoot -File -Recurse)
            if($after.Count -ne $gameHashes.Count+1 -or @($after|Where-Object {!$gameHashes.ContainsKey($_.FullName) -and $_.FullName -cne $archives[0].FullName -and $_.FullName -cne $records[0].FullName}).Count){throw 'History retirement created an unexpected scratch file.'};$count++
            return $count
        }finally{if($bundle){for($i=$bundle.Leases.Count-1;$i -ge 0;$i--){$bundle.Leases[$i].Dispose()}}}
    } $partialProof $packages[1]
    $checks+=$scratchChecks
    foreach($path in $pins.Keys){
        if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $pins[$path]){throw ('Input changed during fixture: '+$path)}
    }
    $result=[ordered]@{Passed=$true;Scratch=$scratch;Build=$buildRoot;StableManifestSha256=$StableManifestSha256;BetaManifestSha256=$BetaManifestSha256;
        AutomaticUpdateZipSha256=$UpdateZipSha256;
        PredicateAssertions=$checks;Native=(Get-Content -LiteralPath (Join-Path $scratch 'native-results.json') -Raw|ConvertFrom-Json);
        ArchiveNative=(Get-Content -LiteralPath (Join-Path $archiveScratch 'native-results.json') -Raw|ConvertFrom-Json);InputSha256=$pins;
        Scope='Signed/native scratch whole migration and optional automatic Apply/recovery; exact production virtual removal clauses with a frozen old inspector and inert absent-removal lease, actual completed removal journal/clean-reinstall validation and held-handle history retirement only in the new scratch root. Old-inspector missing-core proof rejection substitutes only the already validated journal result. Automatic checks copy only signed public game/loader/catalog compatibility inputs. No real installation/removal, Steam/game execution, production private key or network.'}
    $json=$result|ConvertTo-Json -Depth 7
    [IO.File]::WriteAllText((Join-Path $buildRoot 'verification.json'),$json,[Text.UTF8Encoding]::new($false))
    $json
}finally{
    for($index=$leases.Count-1;$index -ge 0;$index--){$leases[$index].Dispose()}
}
