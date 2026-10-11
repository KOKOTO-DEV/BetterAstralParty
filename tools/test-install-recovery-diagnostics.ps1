[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$checks=0
function Check([bool]$Passed,[string]$Name) { if(!$Passed){throw $Name}; $script:checks++ }
foreach($name in @('install-helper.ps1','install-log.ps1')) {
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
    public static string ValidateWholeBridge(string root,string package,string version) {
        var failure=new InvalidOperationException("Update safety: RecoveryRequired");
        if(Reason!=null)failure.Data["BapRecoveryReason"]=Reason;
        throw failure;
    }
}
'@
function Get-BapInstallVerifier { return [SteamLauncher].Assembly }
$bundle=@{GameRoot='fixture-root';PackageRoot='fixture-package';Version=@{Text='1.1.3-rc.3.local.5'}}
foreach($reason in @('OwnedPluginMissing','UpdateOperationPending',$null,"invalid`nprivate-text")) {
    [SteamLauncher]::Reason=$reason
    try { $null=Invoke-BapWholeBridge $bundle 'ValidateWholeBridge'; throw 'Expected refusal' }
    catch {
        $message=$_.Exception.Message
        Check ($message.Contains('Whole migration blocked (ValidateWholeBridge)')) 'Exact failed API retained'
        Check ($message.Contains('Update safety: RecoveryRequired')) 'Original failure retained'
        Check ($message.Contains('Create-Diagnostics.cmd')) 'Single diagnostics entry point supplied'
        if($reason -and $reason -notmatch '[\r\n]'){Check ($message.Contains('['+$reason+']')) 'Typed blocker retained'}
        else {Check (!$message.Contains('private-text')) 'Unrecognized detail excluded'}
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
} finally { [Environment]::SetEnvironmentVariable('LOCALAPPDATA',$priorLocal,'Process') }
[ordered]@{Status='passed';Checks=$checks;Scope='Inert reflection refusal and scratch logging only';InstallationPerformed=$false}|ConvertTo-Json
