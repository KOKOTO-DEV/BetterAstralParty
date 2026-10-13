param(
    [Parameter(Mandatory)][string]$InspectorPath,
    [Parameter(Mandatory)][ValidatePattern('^[A-F0-9]{64}$')][string]$InspectorSha256,
    [switch]$UseHostBackupNamespace
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'install-backup.ps1')
    $splitBudget=Get-InstallVolumeBudget 'K:\game' 'C:\backup' 123 456
    if($splitBudget.Count -ne 2 -or $splitBudget['K:\'] -ne (16MB+123) -or $splitBudget['C:\'] -ne (16MB+456)){throw 'Different-volume budget includes unrelated copies.'}
    $sameBudget=Get-InstallVolumeBudget 'c:\game' 'C:\backup' 123 456
    if($sameBudget.Count -ne 1 -or $sameBudget['C:\'] -ne (16MB+579)){throw 'Same-volume copies are not combined.'}
# Isolated harness only: explicitly pin the reviewed build, never run its entry point
# or manufacture an installable bundle/catalog in the development tree.
$inspectorBytes=[IO.File]::ReadAllBytes([IO.Path]::GetFullPath($InspectorPath))
$sha=[Security.Cryptography.SHA256]::Create()
try { $actualInspectorHash=[BitConverter]::ToString($sha.ComputeHash($inspectorBytes)).Replace('-','') } finally { $sha.Dispose() }
if ($actualInspectorHash -cne $InspectorSha256) { throw 'Reviewed inspector build hash mismatch.' }
$inspector=[Reflection.Assembly]::Load($inspectorBytes)
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('bap-transaction-' + [guid]::NewGuid().ToString('N'))
$savedLocal = $env:LOCALAPPDATA
$fixtureBundle=$null
function Get-BapInstallVerifier($Bundle) {
    if (!$script:fixtureBundle -or ![object]::ReferenceEquals($Bundle,$script:fixtureBundle) -or
        $Bundle.GameRoot -cne (Join-Path $script:scratch '한글 game [test]')) { throw 'External inspector is confined to this fixture.' }
    return $script:inspector
}
try {
    if(!$UseHostBackupNamespace){$env:LOCALAPPDATA = Join-Path $scratch 'Local'}
    $game = Join-Path $scratch '한글 game [test]'
    $null = New-Item -ItemType Directory -Force -Path $game
    $state=$inspector.GetType('SteamLauncher').GetMethod('ReadInstallerState',[Reflection.BindingFlags]'Public,Static').Invoke($null,@([string]$game))
    if ($state -cnotmatch '\ABetterAstralParty.InstallerState/v1\nroot=([A-F0-9]{8}:[A-F0-9]{16})\nversion=\nwater-sha=\n\z') { throw 'Unexpected empty fixture root state.' }
    $fixtureBundle=@{GameRoot=$game;RootIdentity=$Matches[1]}
    $old = Join-Path $game 'old.dll'; $new = Join-Path $game 'new.dll'; $user = Join-Path $game 'user.cfg'
    $targets=@($old,$new)
    [IO.File]::WriteAllText($old, 'old'); [IO.File]::WriteAllText($user, 'preserve')
    $journal = Start-InstallTransaction $game @($old, $new) 1024
    [IO.File]::WriteAllText($old, 'partial'); [IO.File]::WriteAllText($new, 'new')
    try { Restore-InstallTransaction $game; throw 'Expected missing authority rejection' }
    catch { if ($_.Exception.Message -notlike '*Approved incoming inspector*') { throw } }
    $current=@{};foreach($path in $targets){$current[$path]=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash}
    Restore-InstallTransaction $game -ExpectedCurrent $current -AllowedTargets $targets -ExpectedJournalHash (Get-FileHash -LiteralPath $journal -Algorithm SHA256).Hash -VerifiedBundle $fixtureBundle
    if ([IO.File]::ReadAllText($old) -ne 'old' -or (Test-Path -LiteralPath $new) -or [IO.File]::ReadAllText($user) -ne 'preserve') { throw 'Rollback lost data' }
    # Pending journal is durable across calls and blocks another writer.
    $null = Start-InstallTransaction $game @($old, $new) 1024
    try { $null = Start-InstallTransaction $game @($old) 0; throw 'Expected pending rejection' }
    catch { if ($_.Exception.Message -notlike '*Unfinished installation*') { throw } }
    Restore-InstallTransaction $game -AllowedTargets $targets -ExpectedJournalHash (Get-FileHash -LiteralPath $journal -Algorithm SHA256).Hash -VerifiedBundle $fixtureBundle
    $handle = [IO.File]::Open($old, 'Open', 'Read', 'None')
    try {
        try { $null = Start-InstallTransaction $game @($old) 0; throw 'Expected lock rejection' }
        catch { if ($_.Exception.Message -eq 'Expected lock rejection') { throw } }
    } finally { $handle.Dispose() }
    if (Test-Path -LiteralPath $journal) { throw 'Preflight wrote journal' }
    $completedJournal=Start-InstallTransaction $game @($old) 1024
    $completedState=Get-Content -LiteralPath $completedJournal -Raw -Encoding UTF8 | ConvertFrom-Json
    $completedHash=(Get-FileHash -LiteralPath $completedJournal -Algorithm SHA256).Hash
    Complete-InstallTransaction $game -AllowedTargets @($old) -VerifiedBundle $fixtureBundle
    $retired=Join-Path $completedState.BackupDir 'completed.json'
    if((Test-Path -LiteralPath $completedJournal) -or !(Test-Path -LiteralPath $retired) -or
        (Get-FileHash -LiteralPath $retired -Algorithm SHA256).Hash -cne $completedHash -or
        [IO.File]::ReadAllText($old) -cne 'old'){throw 'Completion did not preserve journal bytes and installed target.'}
    (Get-Item -LiteralPath $old).IsReadOnly = $true
    try {
        try { Test-InstallWritable @($old); throw 'Expected access rejection' }
        catch { if ($_.Exception.Message -eq 'Expected access rejection') { throw } }
    } finally { (Get-Item -LiteralPath $old).IsReadOnly = $false }
    try { $null = Start-InstallTransaction $game @((Join-Path $scratch 'outside.dll')) 0; throw 'Expected unsafe path rejection' }
    catch { if ($_.Exception.Message -notlike '*outside game directory*') { throw } }
    try { $null = Start-InstallTransaction $game @($old) ([long]::MaxValue / 2); throw 'Expected disk rejection' }
    catch { if ($_.Exception.Message -notlike '*Not enough free space*') { throw } }
    $null = Start-InstallTransaction $game @($old) 1024
    $state = Get-Content -LiteralPath $journal -Raw -Encoding UTF8 | ConvertFrom-Json
    [IO.File]::WriteAllText($state.Entries[0].Backup, 'damaged')
    try { Restore-InstallTransaction $game -AllowedTargets @($old) -ExpectedJournalHash (Get-FileHash -LiteralPath $journal -Algorithm SHA256).Hash -VerifiedBundle $fixtureBundle; throw 'Expected damaged backup rejection' }
    catch { if ($_.Exception.Message -notlike '*backup missing or damaged*') { throw } }
    if ([IO.File]::ReadAllText($old) -ne 'old') { throw 'Damaged backup altered game' }
    Write-Host 'PASS: native retained-handle rollback, explicit authority/targets/journal, durable journal, lock/read-only/disk/path preflight, backup integrity, Korean/space/bracket paths, unrelated settings preserved.'
    Write-Output ('Inspector SHA-256: '+$actualInspectorHash)
    foreach($source in @('test-install-transaction.ps1','install-backup.ps1')) { Write-Output ($source+' SHA-256: '+(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $source) -Algorithm SHA256).Hash) }
    if($UseHostBackupNamespace){Write-Output ('Isolated host-namespace backups retained: '+(Split-Path -Parent $journal))}
} finally {
    $env:LOCALAPPDATA = $savedLocal
    $resolved = [IO.Path]::GetFullPath($scratch)
    if ((Split-Path $resolved -Parent) -ne [IO.Path]::GetTempPath().TrimEnd('\') -or (Split-Path $resolved -Leaf) -notlike 'bap-transaction-*') { throw 'Unsafe cleanup path' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
