param(
    [Parameter(Mandatory)][string]$InspectorPath,
    [Parameter(Mandatory)][ValidatePattern('^[A-F0-9]{64}$')][string]$InspectorSha256
)
$ErrorActionPreference = 'Stop'
$inspectorBytes=[IO.File]::ReadAllBytes([IO.Path]::GetFullPath($InspectorPath))
$sha=[Security.Cryptography.SHA256]::Create()
try {$actualInspectorHash=[BitConverter]::ToString($sha.ComputeHash($inspectorBytes)).Replace('-','')} finally {$sha.Dispose()}
if($actualInspectorHash -cne $InspectorSha256){throw 'Reviewed inspector build hash mismatch.'}
$fixtureInspector=[Reflection.Assembly]::Load($inspectorBytes)
# Only ordinary recovery delegates to the pinned production inspector; signed whole/helper APIs are inert.
Add-Type -TypeDefinition @'
using System;
using System.Reflection;
public sealed class BapSafetyVerifier {
    public Type GetType(string name) { if(name!="SteamLauncher")throw new Exception("Unexpected fixture verifier type");return typeof(BapSafetyApi); }
}
public static class BapSafetyApi {
    public static Assembly Inspector;
    public static string GameRoot;
    public static bool FailCommit;
    public static readonly string HelperHash=new string('A',64);
    public static IDisposable BeginInstallerDiagnostics(string game,string version) { return new System.IO.MemoryStream(); }
    public static void RecordInstallerStage(string phase,string outcome) { }
    public static void RecordInstallerFailure(string phase,Exception error) { }
    public static string CheckOwnedHelper(string game) { if(game!=GameRoot)throw new Exception("External fixture root");return HelperHash+":inert"; }
    public static void RestoreOrdinaryInstall(string game,string backups,string journal,string[] targets,string current,bool complete,string root) {
        if(game!=GameRoot)throw new Exception("External fixture recovery root");
        if(complete && FailCommit)throw new Exception("Fixture update failure");
        if(new System.Collections.Generic.HashSet<string>(targets,StringComparer.OrdinalIgnoreCase).Count!=targets.Length)throw new Exception("Duplicate production recovery target");
        Inspector.GetType("SteamLauncher").GetMethod("RestoreOrdinaryInstall",BindingFlags.Public|BindingFlags.Static)
            .Invoke(null,new object[]{game,backups,journal,targets,current,complete,root});
    }
}
'@
[BapSafetyApi]::Inspector=$fixtureInspector
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('bap-safety-' + [guid]::NewGuid().ToString('N'))
$savedLocal = $env:LOCALAPPDATA
$passed=$false
$tokens=$null; $parseErrors=$null
$shortcutAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'steam-shortcut.ps1'),[ref]$tokens,[ref]$parseErrors)
if ($parseErrors.Count) { throw 'Shared Steam guard fixture parse failed.' }
$guardNames=@('Get-BapSteamStatus','New-BapSteamFailure','Assert-BapSteamStopped')
$guardDefinitions=@($shortcutAst.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in $guardNames},$false))
if ($guardDefinitions.Count -ne 3) { throw 'Shared Steam guard fixture closure changed.' }
$fixtureGuardSource=($guardDefinitions | ForEach-Object { $_.Extent.Text }) -join "`r`n"
function Write-Fixture([string]$Path, [string]$Text) {
    $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    if ((Split-Path -Leaf $Path) -eq 'steam-shortcut.ps1') {
        $body=[regex]::Replace($Text,'\Aparam\([^)]*\);?\s*','')
        $Text='param([Alias(''Mode'')]$BapShortcutMode,[Alias(''GameRoot'')]$BapShortcutGameRoot,[Alias(''SteamRoot'')]$BapShortcutSteamRoot,[Alias(''AccountId'')]$BapShortcutAccountId)' + "`r`n" + $fixtureGuardSource + "`r`n" + 'if ($MyInvocation.InvocationName -eq ''.'') { return }; $Mode=$BapShortcutMode; $GameRoot=$BapShortcutGameRoot; $SteamRoot=$BapShortcutSteamRoot; $AccountId=$BapShortcutAccountId' + "`r`n" + $body
    }
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($true))
}
try {
    $env:LOCALAPPDATA = Join-Path $scratch 'Local'
    $package = Join-Path $scratch 'package'
    $game = Join-Path $scratch 'game'
    $fixtureSteam = Join-Path $scratch 'Steam'
    $null = [IO.Directory]::CreateDirectory((Join-Path $fixtureSteam 'userdata/1/config'))
    Write-Fixture (Join-Path $game 'AstralParty_INT.exe') 'not an executable'
    Write-Fixture (Join-Path $game 'BepInEx/config/kr.betterastralparty.mod.cfg') 'user setting'
    [BapSafetyApi]::GameRoot=$game
    $state=$fixtureInspector.GetType('SteamLauncher').GetMethod('ReadInstallerState',[Reflection.BindingFlags]'Public,Static').Invoke($null,@([string]$game))
    if($state -cnotmatch '\ABetterAstralParty.InstallerState/v1\nroot=([A-F0-9]{8}:[A-F0-9]{16})\nversion=\nwater-sha=\n\z'){throw 'Unexpected empty fixture root state.'}
    $fixtureRootIdentity=$Matches[1]
    foreach ($file in @('install.ps1','install-backup.ps1','install-log.ps1','install-policy.ps1','install-helper.ps1','install-reinstall.ps1','steam-session.ps1','find-game.ps1','set-loader-mode.ps1','install-bootstrap.ps1')) {
        $null = [IO.Directory]::CreateDirectory((Join-Path $package 'tools'))
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination (Join-Path $package "tools/$file")
    }
    foreach ($file in @('BetterAstralParty.dll','BetterAstralParty-Launcher.exe','BetterAstralParty.compatibility.json')) { Write-Fixture (Join-Path $package "artifacts/$file") 'fixture' }
    foreach ($file in @('BetterAstralParty-Mod.cmd','AstralParty-Vanilla.cmd','BetterAstralParty-Steam.ps1')) { Write-Fixture (Join-Path $package "tools/$file") '# fixture' }
    Write-Fixture (Join-Path $package 'tools/check-compatibility.ps1') 'param($GameRoot,$Manifest,$LoaderRoot,[switch]$CheckOnly); [pscustomobject]@{Allowed=$true; Warnings=@()}'
    Write-Fixture (Join-Path $package '.deps/bepinex/doorstop_config.ini') "[General]`r`nenabled=true`r`n"
    Write-Fixture (Join-Path $package 'tools/set-loader-mode.ps1') 'throw "Installer must not rewrite shared loader settings"'
    Write-Fixture (Join-Path $package '.deps/bepinex/winhttp.dll') 'loader'
    Write-Fixture (Join-Path $package 'tools/steam-shortcut.ps1') 'param($Mode); if ($Mode -eq "ResolveAccount") { return 1 }; if ($Mode -eq "PlanRegister") { return $true }; throw "Fixture registration failure"'
    $policyPath=Join-Path $package 'tools/install-policy.ps1'
    Write-Fixture $policyPath ([IO.File]::ReadAllText($policyPath)+@'

function Assert-BapInstallRoot($Bundle) {
    if($Bundle.PackageRoot -cne $package -or $Bundle.GameRoot -cnotin @($game,$emptyGame)){throw 'Bundle escaped isolated fixture.'}
    return $Bundle.RootIdentity
}
function Open-BapInstallBundle([string]$PackageRoot,[string]$GameRoot,[string]$RecoveryPlan) {
    $bundle=@{PackageRoot=$PackageRoot;GameRoot=$GameRoot;Version=@{Text='0.15.0'};RootIdentity=$fixtureRootIdentity;Expected=@{};SourceHashes=@{};Observed=@{};Leases=@()}
    $null=Assert-BapInstallRoot $bundle
    foreach($file in Microsoft.PowerShell.Management\Get-ChildItem -LiteralPath $PackageRoot -Recurse -File){$bundle.SourceHashes[$file.FullName.Substring($PackageRoot.Length+1).Replace('\','/')]=(Get-FileHash -LiteralPath $file.FullName).Hash}
    foreach($path in @('BepInEx/plugins/BetterAstralParty/BetterAstralParty.dll','BetterAstralParty-Launcher.exe','BetterAstralParty.compatibility.json','BetterAstralParty-Mod.cmd','AstralParty-Vanilla.cmd','check-compatibility.ps1','BetterAstralParty-Steam.ps1','steam-shortcut.ps1')){
        $source=if($path -ceq 'BepInEx/plugins/BetterAstralParty/BetterAstralParty.dll'){'artifacts/BetterAstralParty.dll'}elseif($path -in @('BetterAstralParty-Launcher.exe','BetterAstralParty.compatibility.json')){'artifacts/'+$path}else{'tools/'+$path}
        $bundle.Expected[$path]=$bundle.SourceHashes[$source]
        $target=Join-Path $GameRoot $path
        $bundle.Observed[$path]=if(Test-Path -LiteralPath $target -PathType Leaf){(Get-FileHash -LiteralPath $target).Hash}else{$null}
    }
    $bundle.SourceHashes['helper-bootstrap/BetterAstralParty-UpdateHelper.exe']=[BapSafetyApi]::HelperHash
    return $bundle
}
function Get-BapInstallVerifier($Bundle) {$null=Assert-BapInstallRoot $Bundle;return [BapSafetyVerifier]::new()}
function Assert-BapInstallTransition($Bundle,[switch]$ConfirmRecovery) {$null=Assert-BapInstallRoot $Bundle}
'@)
    $helperPath=Join-Path $package 'tools/install-helper.ps1'
    Write-Fixture $helperPath ([IO.File]::ReadAllText($helperPath)+@'

function Assert-BapHelperBootstrap($Bundle) {$null=Assert-BapInstallRoot $Bundle}
function Assert-BapWholeBridge($Bundle) {$null=Assert-BapInstallRoot $Bundle;$Bundle.WholeObservation='inert whole observation'}
function Invoke-BapWholeBridge($Bundle,[string]$Method,[string[]]$Additional=@()) {
    $null=Assert-BapInstallRoot $Bundle
    switch($Method){
        'RecoverWholeHelper' {return}
        'InstallWholeHelper' {return}
        'BeginWholeInstall' {return [IO.MemoryStream]::new()}
        'GuardWholeRecovery' {return [IO.MemoryStream]::new()}
        'PrepareWholeReceipt' {
            if($Additional.Count -ne 2 -or $Additional[0] -cne $Bundle.WholeObservation){throw 'Invalid inert receipt request.'}
            $baseline=switch($Additional[1]){'true' {$true};'false' {$false};'null' {$null};default {throw 'Invalid inert loader baseline.'}}
            return (@{schema=1;owner='kr.betterastralparty.mod';loaderBefore=$baseline;files=@($Bundle.Expected.Keys|ForEach-Object {@{path=$_;sha256=$Bundle.Expected[$_]}})}|ConvertTo-Json -Depth 5 -Compress)
        }
        default {throw ('Unexpected signed whole API in fixture: '+$Method)}
    }
}
'@)
    $reinstallPath=Join-Path $package 'tools/install-reinstall.ps1'
    Write-Fixture $reinstallPath ([IO.File]::ReadAllText($reinstallPath)+"`nfunction Get-BapCleanReinstallPlan(`$Bundle) {`$null=Assert-BapInstallRoot `$Bundle}`n")
    function Get-Process { param($Name, $ErrorAction) }
    function Get-ItemProperty { param($Path); [pscustomobject]@{SteamPath=$fixtureSteam; ActiveUser=1} }
    # Real installer / filesystem, fake compatibility + Steam entry only. No real Steam or game process.
    try { & (Join-Path $package 'tools/install.ps1') -GameRoot $game; throw 'Expected registration failure' }
    catch { if ($_.Exception.Message -notlike '*Fixture registration failure*') { throw } }
    if ((Test-Path -LiteralPath (Join-Path $game 'winhttp.dll')) -or
        (Test-Path -LiteralPath (Join-Path $game 'BetterAstralParty-Launcher.exe'))) { throw 'Fresh rollback left installed files' }
    Write-Fixture (Join-Path $package 'tools/steam-shortcut.ps1') 'param($Mode); if ($Mode -eq "ResolveAccount") { return 1 }; if ($Mode -eq "PlanRegister") { return $true } # successful fake registration'
    & (Join-Path $package 'tools/install.ps1') -GameRoot $game
    if ((Get-Content -LiteralPath (Join-Path $game 'doorstop_config.ini') -Raw) -notmatch 'enabled=true') { throw 'Shared loader ON default failed' }
    $dll = Join-Path $game 'BepInEx/plugins/BetterAstralParty/BetterAstralParty.dll'
    $before = (Get-FileHash -LiteralPath $dll).Hash
    Write-Fixture (Join-Path $package 'artifacts/BetterAstralParty.dll') 'updated'
    Write-Fixture (Join-Path $package 'tools/steam-shortcut.ps1') 'param($Mode); if ($Mode -eq "ResolveAccount") { return 1 }; if ($Mode -eq "PlanRegister") { return $true }; throw "Fixture registration failure"'
    try { & (Join-Path $package 'tools/install.ps1') -GameRoot $game; throw 'Expected update failure' }
    catch { if ($_.Exception.Message -notlike '*Fixture registration failure*') { throw } }
    if ((Get-FileHash -LiteralPath $dll).Hash -ne $before -or
        (Get-Content -LiteralPath (Join-Path $game 'BepInEx/config/kr.betterastralparty.mod.cfg') -Raw).Trim() -ne 'user setting') { throw 'Update rollback/settings failed' }
    Write-Fixture (Join-Path $package 'tools/steam-shortcut.ps1') 'param($Mode); if ($Mode -eq "ResolveAccount") { return 1 }; if ($Mode -eq "PlanRegister") { return $true } # successful fake registration'
    $loaderSettings = Join-Path $game 'BepInEx/config/BepInEx.cfg'
    $loaderText = "[Logging]`r`n`tUnityLogListening`t= `tTRUE`t`r`n`r`nOther = keep`r`n"
    Write-Fixture $loaderSettings $loaderText
    & (Join-Path $package 'tools/install.ps1') -GameRoot $game
    if ([IO.File]::ReadAllText($loaderSettings) -cne $loaderText.Replace('TRUE','false')) { throw 'Loader setting edit changed surrounding content' }
    $loaderSettingsHash = (Get-FileHash -LiteralPath $loaderSettings).Hash
    & (Join-Path $package 'tools/install.ps1') -GameRoot $game
    if ((Get-FileHash -LiteralPath $loaderSettings).Hash -ne $loaderSettingsHash) { throw 'Repeated install rewrote an already disabled loader setting' }

    # Required shortcut write: stop/restart automatically, restoring files before restarting after failure.
    Write-Fixture (Join-Path $fixtureSteam 'steam.exe') 'inert'
    $steamProbe = @{Running=$true; Stops=0; Starts=0}
    $sessionHelper = Join-Path $package 'tools/steam-session.ps1'
    Write-Fixture $sessionHelper ([IO.File]::ReadAllText($sessionHelper) + @'

function Get-BapSteamTargets { if ($steamProbe.Running) { [pscustomobject]@{Id=10; Path='fixture'; Started=1; Name='steam'; Client=$true} } }
function Get-BapSteamStatus { [pscustomobject]@{State=$(if($steamProbe.Running){'Running'}else{'Stopped'});Facts=@()} }
function Stop-BapVerifiedProcess { $steamProbe.Stops++; $steamProbe.Running=$false }
'@)
    $preRestartHash = (Get-FileHash -LiteralPath $dll).Hash
    Write-Fixture (Join-Path $package 'artifacts/BetterAstralParty.dll') 'restart rollback fixture'
    Write-Fixture (Join-Path $package 'tools/steam-shortcut.ps1') 'param($Mode); if ($Mode -eq "ResolveAccount") { return 1 }; if ($Mode -eq "PlanRegister") { return $true }; throw "Fixture registration failure"'
    function Get-Process { param($Name,$ErrorAction); if ('steam' -in $Name -and $steamProbe.Running) { 'steam' } }
    function Get-ChildItem { param($Path,$LiteralPath,[switch]$Force,$ErrorAction)
        if ($Path -eq 'HKCU:/Software/Valve/Steam/Apps') { return }
        Microsoft.PowerShell.Management\Get-ChildItem @PSBoundParameters
    }
    function Read-Host { return 'y' }
    function Start-Process { param($FilePath,$ArgumentList,$WindowStyle)
        if ($FilePath -ne (Join-Path $fixtureSteam 'steam.exe') -or $WindowStyle -ne 'Hidden') { throw 'Unsafe Steam launch' }
        if ($ArgumentList -eq '-shutdown') { $steamProbe.Stops++; $steamProbe.Running=$false }
        else {
            if ((Get-FileHash -LiteralPath $dll).Hash -ne $preRestartHash) { throw 'Steam restarted before rollback' }
            $steamProbe.Starts++; $steamProbe.Running=$true
        }
    }
    try { & (Join-Path $package 'tools/install.ps1') -GameRoot $game; throw 'Expected registration rollback' }
    catch { if ($_.Exception.Message -notlike '*Fixture registration failure*') { throw } }
    if ($steamProbe.Starts -ne 1 -or $steamProbe.Stops -ne 1) { throw 'Installer Steam lifecycle failed' }
    Remove-Item Function:/Read-Host,Function:/Get-ChildItem
    # Ordinary Install.cmd update with an existing shortcut must not stop Steam, even if another app runs.
    Write-Fixture (Join-Path $package 'tools/steam-shortcut.ps1') 'param($Mode); if ($Mode -eq "ResolveAccount") { return 1 }; if ($Mode -eq "PlanRegister") { return $false }; throw "Unexpected shortcut write"'
    function Get-Process { param($Name,$ErrorAction); if ('steam' -in $Name) { throw 'No-op shortcut must not query running Steam' } }
    function Start-Process { throw 'Unexpected Steam shutdown' }
    & (Join-Path $package 'tools/install.ps1') -GameRoot $game
    # Update-only must never query Steam, register shortcuts or manage any process.
    function Get-ItemProperty { throw 'Unexpected Steam registry access' }
    function Start-Process { throw 'Unexpected process start/Steam shutdown' }
    function Get-Process {
        param($Name, $ErrorAction)
        if ($Name -contains 'steam') { throw 'Unexpected Steam process query' }
        if ($Name -contains 'AstralParty_INT') {
            return [pscustomobject]@{Id=20;ProcessName='AstralParty_INT';Path=(Join-Path $game 'AstralParty_INT.exe');StartTime=[datetime]'2026-01-01';SessionId=[Diagnostics.Process]::GetCurrentProcess().SessionId;HasExited=$false}
        }
    }
    function Read-Host { return '' }
    Write-Fixture (Join-Path $package 'tools/steam-shortcut.ps1') 'throw "Unexpected Steam shortcut call"'
    Write-Fixture (Join-Path $package 'artifacts/BetterAstralParty.dll') 'update-only'
    try { & (Join-Path $package 'tools/install.ps1') -GameRoot $game -UpdateOnly; throw 'Expected running game rejection' }
    catch { if ($_.Exception.Message -notlike '*Cancelled; nothing stopped*') { throw } }
    Remove-Item Function:/Read-Host
    function Get-Process {
        param($Name, $ErrorAction)
        if ($Name -contains 'steam') { throw 'Unexpected Steam process query' }
    }
    $emptyGame = Join-Path $scratch 'not-installed'
    Write-Fixture (Join-Path $emptyGame 'AstralParty_INT.exe') 'not an executable'
    try { & (Join-Path $package 'tools/install.ps1') -GameRoot $emptyGame -UpdateOnly; throw 'Expected missing installation rejection' }
    catch { if ($_.Exception.Message -notlike '*requires an existing installation*') { throw } }
    $beforeUpdate = (Get-FileHash -LiteralPath $dll).Hash
    [BapSafetyApi]::FailCommit=$true
    try { & (Join-Path $package 'tools/install.ps1') -GameRoot $game -UpdateOnly; throw 'Expected update rollback' }
    catch { if ($_.Exception.Message -notlike '*Fixture update failure*') { throw } }
    finally { [BapSafetyApi]::FailCommit=$false }
    if ((Get-FileHash -LiteralPath $dll).Hash -ne $beforeUpdate) { throw 'UpdateOnly rollback failed' }
    # Already OFF, with BOM/LF/blank lines: updates must not rewrite or re-encode it.
    Write-Fixture $loaderSettings "[Logging]`nUnityLogListening = false`n`nOther = keep`n"
    $loaderSettingsHash = (Get-FileHash -LiteralPath $loaderSettings).Hash
    & (Join-Path $package 'tools/install.ps1') -GameRoot $game -UpdateOnly
    if ((Get-FileHash -LiteralPath $loaderSettings).Hash -ne $loaderSettingsHash) { throw 'UpdateOnly changed OFF loader configuration bytes' }
    if ((Get-FileHash -LiteralPath $dll).Hash -ne (Get-FileHash -LiteralPath (Join-Path $package 'artifacts/BetterAstralParty.dll')).Hash -or
        (Get-Content -LiteralPath (Join-Path $game 'BepInEx/config/kr.betterastralparty.mod.cfg') -Raw).Trim() -ne 'user setting') { throw 'UpdateOnly file/settings mismatch' }
    $receipt = Get-Content -LiteralPath (Join-Path $game 'BetterAstralParty.install.json') -Raw | ConvertFrom-Json
    if ($receipt.loaderBefore -isnot [bool] -or $receipt.loaderBefore) { throw 'Fresh loader baseline was lost during updates' }
    foreach ($entry in $receipt.files) {
        if ((Get-FileHash -LiteralPath (Join-Path $game $entry.path)).Hash -ne $entry.sha256) { throw 'UpdateOnly receipt mismatch' }
    }
    # Another mod may be installed before or after BAP; current loader bytes are never ours.
    $doorstop = Join-Path $game 'doorstop_config.ini'
    $foreignMod = Join-Path $game 'BepInEx/plugins/OtherMod.dll'
    Write-Fixture $foreignMod 'Other mod, do not overwrite'
    $foreignHash = (Get-FileHash -LiteralPath $foreignMod).Hash
    foreach ($enabled in @('true','false')) {
        Write-Fixture $doorstop "[General]`nenabled=$enabled`ncustom=keep`n"
        $doorstopHash = (Get-FileHash -LiteralPath $doorstop).Hash
        & (Join-Path $package 'tools/install.ps1') -GameRoot $game -UpdateOnly
        if ((Get-FileHash -LiteralPath $doorstop).Hash -cne $doorstopHash -or
            (Get-FileHash -LiteralPath $foreignMod).Hash -cne $foreignHash -or
            (Get-Content -LiteralPath (Join-Path $game 'BetterAstralParty.install.json') -Raw | ConvertFrom-Json).loaderBefore) {
            throw 'Update overwrote current shared loader/other mod or first baseline.'
        }
    }
    Write-Host 'PASS: UpdateOnly skips all Steam calls; rejects running game/missing install; rollback, user/loader settings, idempotent configuration and receipt hashes verified.'

    # Test the actual bootstrap in PS 5.1, replacing ONLY its installer with an inert script.
    Write-Fixture (Join-Path $package 'tools/install.ps1') "Write-Host 'fixture installer reached'"
    function Save-FixtureManifest {
        $files = @(Get-ChildItem -LiteralPath $package -Recurse -File | Where-Object Name -ne 'package-manifest.json')
        $inventory = @{version='0.15.0'; kind='whole'; files=@($files | ForEach-Object { @{path=$_.FullName.Substring($package.Length+1).Replace('\','/'); sha256=(Get-FileHash -LiteralPath $_.FullName).Hash} })}
        Write-Fixture (Join-Path $package 'package-manifest.json') ($inventory | ConvertTo-Json -Depth 5)
    }
    function Invoke-Bootstrap([int]$Expected, [string]$Contains) {
        $result = & "$env:WINDIR/System32/WindowsPowerShell/v1.0/powershell.exe" -NoProfile -ExecutionPolicy Bypass -File (Join-Path $package 'tools/install-bootstrap.ps1') 2>&1 | Out-String
        if ($LASTEXITCODE -ne $Expected -or !$result.Contains($Contains)) { throw "Bootstrap failed expectation: $result" }
    }
    Save-FixtureManifest
    Invoke-Bootstrap 0 'fixture installer reached'
    Write-Fixture (Join-Path $package 'artifacts/BetterAstralParty.dll') 'damaged'
    Invoke-Bootstrap 1 'Missing or damaged package file'
    Write-Fixture (Join-Path $package 'tools/install.ps1') 'if ('
    Save-FixtureManifest
    Invoke-Bootstrap 1 'Debug log:'
    Remove-Item -LiteralPath (Join-Path $package 'tools/install-log.ps1')
    Invoke-Bootstrap 1 'Debug log:'
    $logFiles = @(Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA 'BetterAstralParty/Logs') -File)
    if ($logFiles.Count -lt 5) { throw 'Expected failure logs missing' }
    Write-Host 'PASS: production installer fresh/update rollback, settings, re-run, vanilla default; bootstrap success, hash rejection, parser failure and missing helper logs (Steam/compatibility fixture).'
    Write-Host 'Not tested: signed incoming bundle/helper/whole migration, channel transition or clean reinstall. Their contracts are inert; ordinary rollback uses the pinned production inspector.'
    Write-Host ('Inspector SHA-256: '+$actualInspectorHash)
    $passed=$true
} finally {
    $env:LOCALAPPDATA = $savedLocal
    $resolved = [IO.Path]::GetFullPath($scratch)
    if ((Split-Path $resolved -Parent) -ne [IO.Path]::GetTempPath().TrimEnd('\') -or (Split-Path $resolved -Leaf) -notlike 'bap-safety-*') { throw 'Unsafe cleanup path' }
    if ($passed -and (Test-Path -LiteralPath $resolved)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
    elseif (!$passed) { Write-Warning ('Failed safety fixture preserved: '+$resolved) }
}
