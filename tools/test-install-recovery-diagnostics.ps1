[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$checks=0
function Check([bool]$Passed,[string]$Name) { if(!$Passed){throw $Name}; $script:checks++ }
foreach($name in @('install-policy.ps1','install-helper.ps1','install-log.ps1')) {
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $name),[ref]$tokens,[ref]$errors)
    Check ($errors.Count -eq 0) ($name+': syntax')
    Check (@($ast.EndBlock.Statements | Where-Object {$_ -isnot [Management.Automation.Language.FunctionDefinitionAst]}).Count -eq 0) ($name+': function-only import')
    . (Join-Path $PSScriptRoot $name)
}
Add-Type -TypeDefinition @'
using System;
public static class SteamLauncher {
    public static string Reason;
    public static int HistoryCalls;
    public static string ValidateWholeBridge(string root,string package,string version) {
        var failure=new InvalidOperationException("Update safety: RecoveryRequired");
        if(Reason!=null)failure.Data["BapRecoveryReason"]=Reason;
        throw failure;
    }
    public static string ReadInstallerState(string root) {
        var failure=new InvalidOperationException("Update safety: RecoveryRequired");
        failure.Data["BapRecoveryReason"]="HighWaterInvalid";throw failure;
    }
    // Inert frontend boundary only; signed native history authentication has separate fixtures.
    public static void ValidateInstalledHistory(string root) {
        HistoryCalls++;var failure=new InvalidOperationException("Update safety: RecoveryRequired");
        failure.Data["BapRecoveryReason"]="HighWaterUnbound";throw failure;
    }
}
namespace BetterAstralParty.Updating {
    internal enum ApplyFailure { UnsafePath, RecoveryRequired }
    internal sealed class ApplySafetyException : Exception {
        internal readonly ApplyFailure Failure=ApplyFailure.RecoveryRequired;
        internal readonly int NativeError=32;
        public ApplySafetyException() : base("Update safety: RecoveryRequired") { }
    }
    public static class FixtureFailure {
        public static Exception Create(string reason) {
            var error=new ApplySafetyException();error.Data["BapRecoveryReason"]=reason;return error;
        }
    }
}
'@
function Get-BapInstallVerifier { return [SteamLauncher].Assembly }
$bundle=@{GameRoot='fixture-root';PackageRoot='fixture-package';Version=@{Text='1.1.3-rc.3.local.5'}}
foreach($reason in @('OwnedPluginMissing','UpdateOperationPending','HighWaterProofMissing',$null,"invalid`nprivate-text")) {
    [SteamLauncher]::Reason=$reason
    try { $null=Invoke-BapWholeBridge $bundle 'ValidateWholeBridge'; throw 'Expected refusal' }
    catch {
        $message=$_.Exception.Message
        Check ($message.Contains('Whole migration blocked (ValidateWholeBridge)')) 'Exact failed API retained'
        Check ($message.Contains('Update safety: RecoveryRequired')) 'Original failure retained'
        Check ($message.Contains('Create-Diagnostics.cmd')) 'Single diagnostics entry point supplied'
        if($reason -and $reason -notmatch '[\r\n]'){Check ($message.Contains('['+$reason+']')) 'Typed blocker retained'}
        else {Check (!$message.Contains('private-text')) 'Unrecognized detail excluded'}
        $cause=$_.Exception; $seen=$false
        for($depth=0;$cause -and $depth -lt 8;$depth++) {
            if([string]$cause.Data['BapRecoveryReason'] -ceq [string]$reason -and $cause.Message -ceq 'Update safety: RecoveryRequired'){$seen=$true}
            $cause=$cause.InnerException
        }
        Check $seen 'Native cause and typed Data survive the human-readable wrapper'
    }
}
$artifactRoot=Join-Path (Split-Path -Parent $PSScriptRoot) 'artifacts'
$scratch=Join-Path $artifactRoot ('install-diagnostics-'+[guid]::NewGuid().ToString('N'))
Check (!(Test-Path -LiteralPath $scratch)) 'Fresh isolated test output'
$priorLocal=[Environment]::GetEnvironmentVariable('LOCALAPPDATA','Process')
try {
    $env:LOCALAPPDATA=$scratch
    $fixtureFailure=[InvalidOperationException]::new('Inert test; installer is never run')
    $fixtureFailure.Data['BapInstallStage']='Whole helper recovery'
    $record=[Management.Automation.ErrorRecord]::new($fixtureFailure,'Fixture',[Management.Automation.ErrorCategory]::InvalidOperation,$null)
    $path=Write-InstallFailure $record 'Installer startup / parsing' 'fixture-package' 'fixture-root'
    Check ($path.StartsWith($scratch+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) 'Only scratch log written'
    $text=Get-Content -LiteralPath $path -Raw
    Check ($text.Contains('Stage: Whole helper recovery')) 'Child failure stage preserved in outer log'
    Check (!$text.Contains('Stage: Installer startup / parsing')) 'Misleading wrapper stage excluded'
    $tokens=$null;$errors=$null
    $uninstall=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'uninstall.ps1'),[ref]$tokens,[ref]$errors)
    $hooks=@($uninstall.FindAll({param($node) $node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text.StartsWith('if ($receipt) {') -and $node.Extent.Text.Contains('ValidateInstalledHistory')},$true))
    Check ($errors.Count -eq 0 -and $hooks.Count -eq 1) 'One installed-history hook'
    $backups=@($uninstall.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Start-InstallTransaction'},$true))
    Check ($backups.Count -eq 1 -and $hooks[0].Extent.EndOffset -lt $backups[0].Extent.StartOffset) 'History validation precedes backup/owned mutation'
    $receipt=$null;$externalBundle=$bundle;$GameRoot=$bundle.GameRoot
    & ([scriptblock]::Create($hooks[0].Extent.Text))
    Check ([SteamLauncher]::HistoryCalls -eq 0) 'Missing receipt/shortcut-only flow skips history API'
    $receipt=@{schema=1}
    try {& ([scriptblock]::Create($hooks[0].Extent.Text));throw 'Expected history refusal'}
    catch {
        $path=Write-InstallFailure $_ 'Uninstall history validation' 'fixture-package' 'fixture-root'
        $text=Get-Content -LiteralPath $path -Raw -Encoding UTF8
        Check ([SteamLauncher]::HistoryCalls -eq 1 -and $text.Contains('recoveryReason=HighWaterUnbound')) 'Uninstall wrapper preserves original history refusal'
    }
    try {Get-BapInstallState $bundle;throw 'Expected state refusal'}
    catch {
        $path=Write-InstallFailure $_ 'Installed state lookup' 'fixture-package' 'fixture-root'
        $text=Get-Content -LiteralPath $path -Raw -Encoding UTF8
        Check ($text.Contains('recoveryReason=HighWaterInvalid')) 'State lookup wrapper retains the native high-water reason'
    }
    foreach($reason in @('HighWaterProofMissing','credentialTokenMustNotBeLogged')) {
        $cause=[BetterAstralParty.Updating.FixtureFailure]::Create($reason)
        $wrapper=[InvalidOperationException]::new('Inert preserved native failure',$cause)
        $record=[Management.Automation.ErrorRecord]::new($wrapper,'Fixture',[Management.Automation.ErrorCategory]::InvalidOperation,$null)
        $path=Write-InstallFailure $record 'Whole validation' 'fixture-package' 'fixture-root'
        $text=Get-Content -LiteralPath $path -Raw -Encoding UTF8
        Check ($text.Contains('applyCode=1; nativeCode=32')) 'Typed enum/native codes retained through the wrapper'
        if($reason -eq 'HighWaterProofMissing'){Check ($text.Contains('recoveryReason=HighWaterProofMissing')) 'Known fixed recovery reason retained'}
        else {Check (!$text.Contains($reason)) 'Unlisted exception Data is not exported'}
    }
} finally { [Environment]::SetEnvironmentVariable('LOCALAPPDATA',$priorLocal,'Process') }
[ordered]@{Status='passed';Checks=$checks;Scope='Inert reflection refusal and scratch logging only';InstallationPerformed=$false}|ConvertTo-Json
