param([string]$EvidencePath)
$ErrorActionPreference='Stop'
$scratch=Join-Path ([IO.Path]::GetTempPath()) ('bap-uninstall-steam-'+[guid]::NewGuid().ToString('N'))
$package=Join-Path $scratch 'package'; $game=Join-Path $scratch 'game'; $steam=Join-Path $scratch 'Steam';$alternateSteam=Join-Path $scratch 'OtherSteam'
$savedModulePath=$env:PSModulePath
$probe=@{Processes=@();Answers=@();Stops=0;Starts=0;Transactions=0;Restores=0;PathPlans=0;CommitFailure=$false;ClientAfterRemove=$false;Failure=$null;Logged=@();RegistryRoot=$steam;RegistryAccount=1;SwitchRegistryOnConsent=$false;SwitchAccountOnResolution=$false;ShortcutCalls=@()}
$checks=[Collections.Generic.List[object]]::new()
# The native boundary is intentionally inert here; native held-object behavior has its own scratch fixture.
Add-Type @'
using System;
using System.IO;
using System.Collections.Generic;
using System.Security.Cryptography;
public static class SteamLauncher {
    public static string FixtureRoot, FixtureJournalRoot;
    public static FixtureRemovalLease LastLease;
    public static int RemovalCalls;
    // No receipt exists in this Steam-only fixture. Never fake successful signed history.
    public static void ValidateInstalledHistory(string root) {
        throw new InvalidOperationException("Receiptless Steam fixture must not claim installed history.");
    }
    public static IDisposable BeginOwnedRemoval(string root,string journalRoot,string journalHash,string[] targets,string rootIdentity,bool allowLoader) {
        if(root!=FixtureRoot || journalRoot!=FixtureJournalRoot || rootIdentity!="fixture-root" || targets==null || targets.Length==0 || allowLoader)
            throw new InvalidOperationException("Native removal fixture escaped its selected boundary.");
        using(var sha=SHA256.Create()) {
            var hash=BitConverter.ToString(sha.ComputeHash(File.ReadAllBytes(Path.Combine(journalRoot,"pending.json")))).Replace("-","");
            if(hash!=journalHash)throw new InvalidOperationException("Fixture journal changed.");
        }
        LastLease=new FixtureRemovalLease(root,targets);RemovalCalls++;return LastLease;
    }
}
public sealed class FixtureRemovalLease : IDisposable {
    readonly string root; readonly HashSet<string> allowed;
    public bool Disposed;
    public FixtureRemovalLease(string selected,string[] targets) {
        root=selected;allowed=new HashSet<string>(targets,StringComparer.Ordinal);
        foreach(var target in targets)
            if(Path.GetFullPath(target)!=target || !target.StartsWith(root+"\\",StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Fixture target escaped root.");
    }
    public void Remove(string target) {
        if(Disposed || !allowed.Remove(target))throw new InvalidOperationException("Unexpected fixture removal.");
        File.Delete(target);
    }
    public void WriteLoader(string target,string text) { throw new InvalidOperationException("Shared loader is not part of this fixture."); }
    public void Dispose() { Disposed=true; }
}
'@

function Put([string]$Path,[string]$Text) { $null=[IO.Directory]::CreateDirectory((Split-Path -Parent $Path));[IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($true)) }
function Check([string]$Name,[bool]$Passed) { $checks.Add([pscustomobject]@{case=$Name;passed=$Passed});if(!$Passed){throw ('Failed: '+$Name)} }
function FakeSteam([int]$Id,[string]$Path) {
    $item=[pscustomobject]@{Id=$Id;ProcessName='steam';Path=$Path;SessionId=[Diagnostics.Process]::GetCurrentProcess().SessionId;StartTime=[datetime]'2026-01-01T00:00:00Z';HasExited=$false}
    $item|Add-Member ScriptMethod WaitForExit {param($Milliseconds);$true};return $item
}
function Get-Process {param($Name,$Id,$ErrorAction)
    if($Id){return @($probe.Processes|Where-Object Id -eq $Id)}
    if($Name){return @($probe.Processes|Where-Object ProcessName -in $Name)}
    return $probe.Processes
}
function Get-ItemProperty {param($Path,$ErrorAction);[pscustomobject]@{SteamPath=$probe.RegistryRoot;ActiveUser=$probe.RegistryAccount;AutoLoginUser=''}}
function Stop-Process {param($InputObject,[switch]$Force,$ErrorAction);if(!$Force){throw 'Unexpected nonforce kill'};$probe.Stops++;$probe.Processes=@($probe.Processes|Where-Object Id -ne $InputObject.Id)}
function Start-Process {param($FilePath,$WindowStyle)
    if($FilePath -ne (Join-Path $steam 'steam.exe') -or $WindowStyle -ne 'Hidden'){throw 'Unexpected fixture restart'}
    $probe.Starts++;$probe.Processes=@(FakeSteam 100 $FilePath)
}
function Read-Host {if(!$probe.Answers.Count){throw 'Unexpected fixture prompt'};$answer=$probe.Answers[0];$probe.Answers=@($probe.Answers|Select-Object -Skip 1);if($probe.SwitchRegistryOnConsent){$probe.RegistryRoot=$alternateSteam};return $answer}
function Reset {
    [SteamLauncher]::LastLease=$null;[SteamLauncher]::RemovalCalls=0
    Put $config 'owned setting';Put $shortcut 'registered';Put $alternateShortcut 'unrelated shortcut';Put $loader 'enabled=true';Put $otherMod 'another mod'
    $probe.Processes=@();$probe.Answers=@();$probe.Stops=0;$probe.Starts=0;$probe.Transactions=0;$probe.Restores=0;$probe.PathPlans=0;$probe.CommitFailure=$false;$probe.ClientAfterRemove=$false;$probe.Failure=$null;$probe.Logged=@()
    $probe.RegistryRoot=$steam;$probe.RegistryAccount=1;$probe.SwitchRegistryOnConsent=$false;$probe.SwitchAccountOnResolution=$false;$probe.ShortcutCalls=@()
    if(Test-Path -LiteralPath $journal){Remove-Item -LiteralPath $journal}
}
function Refuse([string]$Reason) {
    try{& $uninstall -GameRoot $game -AccountId 1 -Confirm:$false;throw 'Expected refusal'}
    catch{
        if($_.Exception.Message -eq 'Expected refusal'){throw}
        if($Reason){$context=$_.Exception.Data['BapSteamDiagnostic']|ConvertFrom-Json;Check ('uninstall reason '+$Reason) ($context.reason -eq $Reason)}
    }
}
try {
    foreach($name in @('uninstall.ps1','find-game.ps1','steam-session.ps1')) {
        $target=Join-Path $package ('tools/'+$name);$null=[IO.Directory]::CreateDirectory((Split-Path -Parent $target));Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $target
    }
    Put (Join-Path $package 'package-manifest.json') 'inert fixture; signed bundle APIs substituted'
    Put (Join-Path $game 'AstralParty_INT.exe') 'inert executable'
    Put (Join-Path $steam 'steam.exe') 'inert client'
    $config=Join-Path $game 'BepInEx/config/kr.betterastralparty.mod.cfg'
    $loader=Join-Path $game 'doorstop_config.ini';$otherMod=Join-Path $game 'BepInEx/plugins/other.dll'
    $shortcut=Join-Path $steam 'userdata/1/config/shortcuts.vdf'
    $alternateShortcut=Join-Path $alternateSteam 'userdata/1/config/shortcuts.vdf'
    $journal=Join-Path $scratch 'transaction/pending.json'
    [SteamLauncher]::FixtureRoot=$game;[SteamLauncher]::FixtureJournalRoot=Split-Path -Parent $journal
    $uninstall=Join-Path $package 'tools/uninstall.ps1'
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'steam-shortcut.ps1'),[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'Shared guard parse failure'}
    $names=@('Get-BapProcessObservation','Get-BapProcessFact','Get-BapSteamStatus','New-BapSteamFailure','Assert-BapSteamStopped')
    $defs=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in $names},$false))
    if($defs.Count -ne $names.Count){throw 'Shared guard closure changed'}
    $text='param([Alias(''Mode'')]$BapShortcutMode,[Alias(''SteamRoot'')]$BapShortcutSteamRoot,[Alias(''GameRoot'')]$BapShortcutGameRoot,[Alias(''AccountId'')]$BapShortcutAccountId)' + "`r`n" + (($defs|ForEach-Object {$_.Extent.Text}) -join "`r`n") + "`r`n" + @'
if($MyInvocation.InvocationName -eq '.'){return}
if($BapShortcutGameRoot -ne $game){throw 'Shortcut fixture escaped selected game'}
if($BapShortcutSteamRoot -ne $steam){throw 'Shortcut fixture escaped initially selected Steam root'}
$probe.ShortcutCalls+=@{Mode=$BapShortcutMode;Root=$BapShortcutSteamRoot;Account=$BapShortcutAccountId}
if($BapShortcutMode -ne 'ResolveAccount' -and $BapShortcutAccountId -ne 1){throw 'Shortcut fixture escaped initially selected account'}
switch($BapShortcutMode){
    'PlanRemove' {return ([IO.File]::ReadAllText($shortcut) -eq 'registered')}
    'ResolveAccount' {$selected=$probe.RegistryAccount;if($probe.SwitchAccountOnResolution){$probe.RegistryAccount=2};return $selected}
    'Remove' {
        Assert-BapSteamStopped $steam 'ShortcutPreflight'
        $backup=$shortcut+'.'+[guid]::NewGuid().ToString('N')+'.bak';[IO.File]::Copy($shortcut,$backup,$false)
        [IO.File]::WriteAllText($shortcut,'removed')
        if($probe.ClientAfterRemove){$probe.Processes=@(FakeSteam 200 (Join-Path $steam 'steam.exe'))}
        return [pscustomobject]@{Path=$shortcut;Backup=$backup;Hash=(Get-FileHash -LiteralPath $shortcut).Hash;Artwork=@()}
    }
    default {throw 'Unexpected fixture shortcut mode'}
}
'@
    Put (Join-Path $package 'tools/steam-shortcut.ps1') $text
    Put (Join-Path $package 'tools/install-policy.ps1') @'
function Open-BapInstallBundle([string]$PackageRoot,[string]$GameRoot) {if($PackageRoot -ne $package -or $GameRoot -ne $game){throw 'Bundle fixture escaped'};return @{GameRoot=$game;RootIdentity='fixture-root';Expected=@{};Leases=@()}}
function Get-BapInstallVerifier($Bundle) {if($Bundle.GameRoot -ne $game){throw 'Verifier fixture escaped'};return [SteamLauncher].Assembly}
function Assert-BapInstallRoot($Bundle) {if($Bundle.GameRoot -ne $game){throw 'Bundle fixture escaped'}}
# Inert pure-preflight substitute only; actual native path limits have separate pinned-inspector checks.
function Assert-BapMaintenancePathPlan($Bundle,[string[]]$Targets) {
    if($Bundle.GameRoot -ne $game){throw 'Path-plan fixture escaped selected game'}
    foreach($target in $Targets){if(![IO.Path]::GetFullPath($target).StartsWith($game+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Path-plan target escaped selected game'}}
    $probe.PathPlans++
}
'@
    Put (Join-Path $package 'tools/install-helper.ps1') @'
function Start-BapInstallerDiagnostics($Bundle) {return $null}
function Write-BapInstallerStage {param($Bundle,$Phase,$Outcome)}
function Write-BapInstallerError {param($Bundle,$Phase,$Failure);$probe.Failure=$Failure}
'@
    Put (Join-Path $package 'tools/install-log.ps1') @'
function Write-InstallFailure {param($Failure,$Stage,$PackageRoot,$GameRoot,$Operation);$probe.Failure=$Failure.Exception;$probe.Logged+=$Failure.Exception}
'@
    Put (Join-Path $package 'tools/install-backup.ps1') @'
function Assert-InstallTarget([string]$Root,[string]$Path) {if($Root -ne $game -or ![IO.Path]::GetFullPath($Path).StartsWith($game+'',[StringComparison]::OrdinalIgnoreCase)){throw 'Target fixture escaped selected root'}}
function Enter-BapUpdateMaintenance {param($GameRoot,[switch]$ReadOnly,$VerifiedBundle);if($GameRoot -ne $game){throw 'Maintenance fixture escaped'};return [IO.MemoryStream]::new()}
function Get-InstallJournalPath {param($GameRoot);if($GameRoot -ne $game){throw 'Journal fixture escaped'};return $journal}
function Start-InstallTransaction {param($GameRoot,$Targets,$Bytes)
    $probe.Transactions++;$backup=Join-Path $scratch ('backups/'+[guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($backup)
    $entries=@();foreach($target in $Targets){Assert-InstallTarget $GameRoot $target;$saved=Join-Path $backup ([guid]::NewGuid().ToString('N'));[IO.File]::Copy($target,$saved,$false);$entries+=[pscustomobject]@{Target=$target;Hash=(Get-FileHash -LiteralPath $target).Hash;Existed=$true;Backup=$saved}}
    Put $journal (@{BackupDir=$backup;Entries=$entries}|ConvertTo-Json -Depth 5);return $journal
}
function Complete-InstallTransaction {param($GameRoot,$AllowedTargets,$VerifiedBundle);if($probe.CommitFailure){throw 'Fixture commit failure'};Remove-Item -LiteralPath $journal}
function Restore-InstallTransaction {param($GameRoot,$ExpectedCurrent,$AllowedTargets,$VerifiedBundle)
    $probe.Restores++;if([SteamLauncher]::LastLease -and ![SteamLauncher]::LastLease.Disposed){throw 'Removal lease was not released before rollback'};$state=Get-Content -Raw -LiteralPath $journal|ConvertFrom-Json
    foreach($entry in $state.Entries){Assert-InstallTarget $GameRoot $entry.Target;if(Test-Path -LiteralPath $entry.Target){throw 'Fixture rollback must not overwrite newly appeared file'};[IO.File]::Copy($entry.Backup,$entry.Target,$false)}
    Remove-Item -LiteralPath $journal
}
'@
    Reset
    & $uninstall -GameRoot $game -AccountId 1 -WhatIf
    Check 'WhatIf plans paths but never enters native removal or writes backup/shortcut' ($probe.PathPlans -eq 1 -and [SteamLauncher]::RemovalCalls -eq 0 -and $probe.Transactions -eq 0 -and [IO.File]::ReadAllText($config) -eq 'owned setting' -and [IO.File]::ReadAllText($shortcut) -eq 'registered')
    Reset;$probe.Processes=@(FakeSteam 90 'C:\unrelated\steam.exe')
    & $uninstall -GameRoot $game -AccountId 1 -Confirm:$false
    Check 'native removal disposed before completed journal' ([SteamLauncher]::LastLease.Disposed)
    Check 'other-root client does not block current uninstaller' (!(Test-Path -LiteralPath $config) -and [IO.File]::ReadAllText($shortcut) -eq 'removed' -and !$probe.Stops -and !$probe.Starts)
    Check 'default uninstall preserves shared loader and other mod' ([IO.File]::ReadAllText($loader) -eq 'enabled=true' -and [IO.File]::ReadAllText($otherMod) -eq 'another mod')
    Reset;$unknown=FakeSteam 91 ''; $unknown.Path=$null;$probe.Processes=@($unknown);$probe.Answers=@('')
    Refuse 'SteamOwnershipUnknown'
    Check 'unknown owner cancels before file transaction or userdata mutation' ($probe.Transactions -eq 0 -and [IO.File]::ReadAllText($config) -eq 'owned setting' -and [IO.File]::ReadAllText($shortcut) -eq 'registered')
    Reset;$probe.Processes=@(FakeSteam 92 (Join-Path $steam 'steam.exe'));$probe.Answers=@('y')
    & $uninstall -GameRoot $game -AccountId 1 -Confirm:$false
    Check 'owned force close requires consent and resumes only client after removal' ($probe.Stops -eq 1 -and $probe.Starts -eq 1 -and !(Test-Path -LiteralPath $config))
    Reset;$probe.Processes=@(FakeSteam 93 (Join-Path $steam 'steam.exe'));$probe.Answers=@('y');$probe.SwitchRegistryOnConsent=$true;$probe.SwitchAccountOnResolution=$true
    & $uninstall -GameRoot $game -Confirm:$false
    Check 'registry changes keep planning removal and restart on initial root and account' ($probe.RegistryRoot -eq $alternateSteam -and $probe.RegistryAccount -eq 2 -and ($probe.ShortcutCalls.Mode -join ',') -eq 'ResolveAccount,PlanRemove,PlanRemove,Remove' -and @($probe.ShortcutCalls|Where-Object {$_.Root -ne $steam -or ($_.Mode -ne 'ResolveAccount' -and $_.Account -ne 1)}).Count -eq 0 -and [IO.File]::ReadAllText($shortcut) -eq 'removed' -and [IO.File]::ReadAllText($alternateShortcut) -eq 'unrelated shortcut' -and $probe.Stops -eq 1 -and $probe.Starts -eq 1)
    Reset;$probe.Processes=@(FakeSteam 94 (Join-Path $steam 'steam.exe'));$probe.Answers=@('y');$probe.SwitchRegistryOnConsent=$true;$probe.CommitFailure=$true
    Refuse ''
    Check 'registry change during consent preserves original-root rollback and unrelated userdata' ($probe.RegistryRoot -eq $alternateSteam -and $probe.Restores -eq 1 -and [IO.File]::ReadAllText($config) -eq 'owned setting' -and [IO.File]::ReadAllText($shortcut) -eq 'registered' -and [IO.File]::ReadAllText($alternateShortcut) -eq 'unrelated shortcut' -and $probe.Starts -eq 1)
    Reset;$probe.CommitFailure=$true
    Refuse ''
    Check 'offline rollback restores exact shortcut and owned configuration' ($probe.Restores -eq 1 -and [IO.File]::ReadAllText($config) -eq 'owned setting' -and [IO.File]::ReadAllText($shortcut) -eq 'registered')
    Reset;$probe.CommitFailure=$true;$probe.ClientAfterRemove=$true
    Refuse ''
    Check 'client appearing after removal blocks userdata rollback overwrite' ($probe.Restores -eq 1 -and [IO.File]::ReadAllText($config) -eq 'owned setting' -and [IO.File]::ReadAllText($shortcut) -eq 'removed' -and !$probe.Stops)
    Check 'blocked rollback retains exact original shortcut backup' (@(Get-ChildItem -LiteralPath (Split-Path -Parent $shortcut) -Filter '*.bak'|Where-Object {[IO.File]::ReadAllText($_.FullName) -eq 'registered'}).Count -ge 1)
    $rollbackContexts=@($probe.Logged | Where-Object {$_.Data.Contains('BapSteamDiagnostic')} | ForEach-Object {$_.Data['BapSteamDiagnostic']|ConvertFrom-Json})
    Check 'blocked rollback records its Steam guard while retaining primary error' ($rollbackContexts.Count -eq 1 -and $rollbackContexts[0].phase -eq 'ShortcutRollback' -and $rollbackContexts[0].reason -eq 'SteamRunning' -and $probe.Failure.Message -eq 'Fixture commit failure')
    $result=[ordered]@{runtime=$PSVersionTable.PSVersion.ToString();passed=$checks.Count;failed=0;cases=@($checks);realSteamOrGameTouched=$false; signedMaintenanceAndTransactions='inert substitutes';uninstallSha256=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'uninstall.ps1')).Hash;guardSha256=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'steam-shortcut.ps1')).Hash}
    if($EvidencePath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($EvidencePath),($result|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))}
    $result|ConvertTo-Json -Depth 5
} finally {
    $env:PSModulePath=$savedModulePath
    $resolved=[IO.Path]::GetFullPath($scratch)
    if((Split-Path $resolved -Parent) -ne [IO.Path]::GetTempPath().TrimEnd('\') -or (Split-Path $resolved -Leaf) -notlike 'bap-uninstall-steam-*'){throw 'Unsafe fixture cleanup'}
    if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}

