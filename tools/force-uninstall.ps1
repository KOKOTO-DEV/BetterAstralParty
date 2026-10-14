# Deliberately separate from the verified/transactional standard uninstaller.
# Windows PowerShell 5.1 compatible. No receipt/installer needed, no ACL or AV bypass.
[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')]
param(
    [string]$GameRoot,
    [switch]$KeepLocalData,
    [switch]$RemoveSteamShortcut
)
$ErrorActionPreference='Stop'
$env:PSModulePath=Join-Path $PSHOME 'Modules'
$sourceRoot=Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'find-game.ps1')

function Assert-BapNoReparse([string]$Path) {
    $full=[IO.Path]::GetFullPath($Path)
    $current=$full
    while ($current -and (Test-Path -LiteralPath $current)) {
        $item=Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw ('Junction or symlink encountered; refusing recursive deletion: '+$item.FullName)
        }
        $parent=[IO.Directory]::GetParent($current)
        if ($null -eq $parent -or $parent.FullName -eq $current) {break}
        $current=$parent.FullName
    }
}
function Assert-BapSafeTree([string]$Path) {
    Assert-BapNoReparse $Path
    if (Test-Path -LiteralPath $Path -PathType Container) {
        foreach ($child in @(Get-ChildItem -LiteralPath $Path -Force -Recurse -ErrorAction Stop)) {
            if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw ('Junction or symlink inside deletion target: '+$child.FullName)
            }
        }
    }
}
function Assert-BapInside([string]$Base,[string]$Path) {
    $prefix=[IO.Path]::GetFullPath($Base).TrimEnd('\')+'\'
    $full=[IO.Path]::GetFullPath($Path)
    if (!$full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) {throw ('Unsafe target path: '+$full)}
    Assert-BapSafeTree $full
}
if (!$GameRoot) {
    $GameRoot=Read-Host 'Astral Party INT game directory (blank cancels)'
    if (!$GameRoot) {throw 'Cancelled; no files changed.'}
}
$resolved=Resolve-IntGameDirectory $GameRoot
if (!$resolved) {throw 'INT game directory not found (AstralParty_INT.exe required). Nothing removed.'}
$GameRoot=$resolved
Assert-BapNoReparse $GameRoot
if ([IO.Path]::GetFileName($GameRoot) -cne '8vJXnINT') {
    throw 'Expected INT game root named 8vJXnINT. Nothing removed.'
}
$running=@(Get-Process -Name AstralParty_INT,AstralParty_CN,BetterAstralParty-Launcher,BetterAstralParty-UpdateHelper -ErrorAction SilentlyContinue)
if ($running.Count) {
    throw ('Close the game, launcher and updater normally before cleanup: '+($running.ProcessName -join ', '))
}

# Fixed mod-specific allowlist only. No untrusted receipt or wildcards from external input.
$files=@(
    'BetterAstralParty.install.json',
    'BetterAstralParty-Launcher.exe',
    'BetterAstralParty-UpdateHelper.exe',
    'BetterAstralParty.helper.receipt',
    'BetterAstralParty.compatibility.json',
    'BetterAstralParty-Mod.cmd',
    'AstralParty-Vanilla.cmd',
    'BetterAstralParty-Steam.ps1',
    'check-compatibility.ps1',
    'steam-shortcut.ps1',
    'BetterAstralParty.update-v3.version',
    'BetterAstralParty.update.lock',
    'BetterAstralParty.reinstall-v3.pending',
    'BetterAstralParty-Compatibility.log',
    'BetterAstralParty-LaunchError.log',
    'BepInEx\config\kr.betterastralparty.mod.cfg'
)
$directories=@('BepInEx\plugins\BetterAstralParty','BepInEx\BetterAstralParty-Diagnostics')
$targets=New-Object 'System.Collections.Generic.List[string]'
foreach ($relative in $files + $directories) {
    $full=Join-Path $GameRoot $relative
    Assert-BapInside $GameRoot $full
    if (Test-Path -LiteralPath $full) {$targets.Add($full)}
}
foreach ($item in @(Get-ChildItem -LiteralPath $GameRoot -File -Force -ErrorAction Stop)) {
    if ($item.Name -match '^BetterAstralParty\.(?:reinstall-v3\.completed-|update-v3\.version\.uninstalled-)[A-Za-z0-9_-]{1,100}$') {
        Assert-BapInside $GameRoot $item.FullName
        $targets.Add($item.FullName)
    }
}
$localRoot=Join-Path $env:LOCALAPPDATA 'BetterAstralParty'
if (!$KeepLocalData -and (Test-Path -LiteralPath $localRoot)) {
    if ([IO.Path]::GetFileName($localRoot) -cne 'BetterAstralParty') {throw 'Unexpected user data path.'}
    Assert-BapInside $env:LOCALAPPDATA $localRoot
    $targets.Add($localRoot)
}
$shortcutPlanned=$false
$steamRoot=$null
$accountId=[uint32]0
if ($RemoveSteamShortcut) {
    $steamRoot=(Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
    if (!$steamRoot) {throw 'Steam registry installation missing; cannot safely select shortcut.'}
    $accountId=& (Join-Path $PSScriptRoot 'steam-shortcut.ps1') -Mode ResolveAccount -GameRoot $GameRoot -SteamRoot $steamRoot
    $shortcutPlanned=[bool](& (Join-Path $PSScriptRoot 'steam-shortcut.ps1') -Mode PlanRemove -GameRoot $GameRoot -SteamRoot $steamRoot -AccountId $accountId)
    if ($shortcutPlanned -and (Get-Process steam -ErrorAction SilentlyContinue)) {
        throw 'Close Steam normally to remove its shortcut; no files changed.'
    }
}
Write-Host '--- BetterAstralParty FORCE uninstall preview ---'
Write-Host "Game: $GameRoot"
foreach ($target in $targets) {Write-Host "  DELETE: $target"}
if ($shortcutPlanned) {Write-Host '  REMOVE: Matching Astral Party - Mod Steam shortcut (backed up by shortcut helper)' }
Write-Host 'PRESERVED: AstralParty_INT.exe, game assets, shared BepInEx loader/core, other plugins, Steam installation.'
if ($KeepLocalData) {Write-Host 'PRESERVED: BetterAstralParty LocalAppData logs, backups and settings (-KeepLocalData)' }
else {Write-Warning 'LocalAppData\BetterAstralParty including recovery BACKUPS, LOGS and settings will be permanently deleted.'}
if (!$RemoveSteamShortcut) {Write-Host 'Steam shortcut is preserved; pass -RemoveSteamShortcut to remove a matching owned entry.'}
if (!$targets.Count -and !$shortcutPlanned) {Write-Host 'Nothing to remove.';return}
if ($WhatIfPreference) {Write-Host 'Dry-run only; nothing changed.';return}
$confirmation=Read-Host 'Type ERASE BETTERASTRALPARTY to permanently remove all listed files'
if ($confirmation -cne 'ERASE BETTERASTRALPARTY') {throw 'Confirmation did not match. Nothing changed.'}
if (!$PSCmdlet.ShouldProcess($GameRoot,'Permanently remove the listed BetterAstralParty-owned files (no rollback)')) {return}
$running=@(Get-Process -Name AstralParty_INT,AstralParty_CN,BetterAstralParty-Launcher,BetterAstralParty-UpdateHelper -ErrorAction SilentlyContinue)
if ($running.Count) {throw 'A game or mod process started; nothing changed.'}
foreach ($target in $targets) {Assert-BapSafeTree $target}
if ($shortcutPlanned) {
    # Remove the exact installed Steam shortcut before deleting its launcher files.
    $null=& (Join-Path $PSScriptRoot 'steam-shortcut.ps1') -Mode Remove -GameRoot $GameRoot -SteamRoot $steamRoot -AccountId $accountId
}
$failures=New-Object 'System.Collections.Generic.List[string]'
foreach ($target in $targets) {
    try {
        if (Test-Path -LiteralPath $target) {
            Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop
            Write-Host ('DELETED: '+$target)
        }
    } catch {
        $failures.Add(($target+' :: '+$_.Exception.Message))
        Write-Warning ('Unable to delete; not bypassing ACL/antivirus/file lock: '+$target)
    }
}
if ($failures.Count) {
    foreach ($failure in $failures) {Write-Host ('FAILED: '+$failure)}
    throw ('Partial cleanup: '+$failures.Count+' path(s) could not be removed. Nothing outside the allowlist was touched.')
}
Write-Host 'Force uninstall finished. Original game and shared BepInEx files were retained.'
