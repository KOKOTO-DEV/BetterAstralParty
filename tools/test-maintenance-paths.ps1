param([Parameter(Mandatory)][string]$InspectorPath,[Parameter(Mandatory)][ValidatePattern('^[A-F0-9]{64}$')][string]$InspectorSha256)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if((Get-FileHash -LiteralPath $InspectorPath).Hash -cne $InspectorSha256){throw 'Pinned inspector hash mismatch'}
$inspector=[Reflection.Assembly]::Load([IO.File]::ReadAllBytes($InspectorPath))
. (Join-Path $PSScriptRoot 'install-backup.ps1')
. (Join-Path $PSScriptRoot 'install-policy.ps1')
function Get-BapInstallVerifier($Bundle){return $inspector}
$scratch=Join-Path ([IO.Path]::GetTempPath()) ('bp-'+[guid]::NewGuid().ToString('N').Substring(0,8))
$null=[IO.Directory]::CreateDirectory($scratch)
$savedLocal=$env:LOCALAPPDATA;$passed=$false;$checks=0
try {
    $env:LOCALAPPDATA=Join-Path $scratch 'Local'
    $game=Join-Path $scratch 'game [1]';$package=Join-Path $scratch 'package'
    $null=[IO.Directory]::CreateDirectory($game);$null=[IO.Directory]::CreateDirectory($package)
    $bundle=@{GameRoot=$game;PackageRoot=$package;Expected=@{'BepInEx/plugins/BetterAstralParty/BetterAstralParty.dll'='inert'}}
    $before=@(Get-ChildItem -LiteralPath $scratch -Recurse -Force).Count
    Assert-BapMaintenancePathPlan $bundle
    if(@(Get-ChildItem -LiteralPath $scratch -Recurse -Force).Count -ne $before){throw 'Read-only planning created files/directories'};$checks++
    $atLimit='C:\'+('x' * 237);Assert-BapMaintenancePath $atLimit 'Target';$checks++
    try {Assert-BapMaintenancePath ($atLimit+'x') 'Target';throw 'Long path accepted'}
    catch [IO.PathTooLongException] {if(!$_.Exception.Message.Contains('length=241; limit=240')){throw};$checks++}
    $env:LOCALAPPDATA=Join-Path $scratch ('deep-profile-'+('p'*100))
    try {Assert-BapMaintenancePathPlan $bundle;throw 'Deep backup path accepted'}
    catch [IO.PathTooLongException] {if(!$_.Exception.Message.Contains('kind=BackupJournal')){throw};$checks++}
    $env:LOCALAPPDATA=Join-Path $scratch 'Local'
    $longTarget=Join-Path $game ('nested/'+('t'*180)+'/owned.dll')
    try {Assert-BapMaintenancePathPlan $bundle @($longTarget);throw 'Long planned target accepted'}
    catch [IO.PathTooLongException] {$checks++}
    $bundle.GameRoot=Join-Path $scratch ('g'*125)
    try {Assert-BapMaintenancePathPlan $bundle;throw 'Long future native work path accepted'}
    catch {if($_.Exception.GetBaseException().Data['BapRecoveryReason'] -cne 'MaintenancePathTooLong'){throw};$checks++}
    if(@(Get-ChildItem -LiteralPath $scratch -Recurse -Force).Count -ne $before){throw 'Rejected planning changed fixture files'};$checks++
    $passed=$true
    [ordered]@{status='passed';checks=$checks;inspectorSha256=$InspectorSha256;scope='Pure path planning only; no install/removal/lock creation';installationPerformed=$false}|ConvertTo-Json
} finally {
    $env:LOCALAPPDATA=$savedLocal
    $full=[IO.Path]::GetFullPath($scratch)
    if((Split-Path $full -Parent) -cne [IO.Path]::GetTempPath().TrimEnd('\') -or (Split-Path $full -Leaf) -cnotmatch '^bp-[a-f0-9]{8}$'){throw 'Unsafe fixture cleanup'}
    if($passed){Remove-Item -LiteralPath $full -Recurse -Force}else{Write-Host ('Evidence retained: '+$full)}
}
