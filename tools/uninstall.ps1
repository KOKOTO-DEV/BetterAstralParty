[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')]
param([string]$GameRoot, [ValidateSet('Keep','Recorded','Enabled','Disabled')][string]$RestoreLoader = 'Keep', [uint32]$AccountId = 0)
$ErrorActionPreference = 'Stop'
$env:PSModulePath = Join-Path $PSHOME 'Modules'
$root = Split-Path -Parent $PSScriptRoot
if (!(Test-Path -LiteralPath (Join-Path $root 'package-manifest.json') -PathType Leaf)) {
    throw 'BAP-SOURCE-DEVELOPMENT: 개발 소스에서 제거할 수 없습니다. 검증된 전체 ZIP을 사용하세요. / Use a verified whole ZIP; see docs/BUILD.md.'
}
. (Join-Path $PSScriptRoot 'find-game.ps1')
. (Join-Path $PSScriptRoot 'install-backup.ps1')
. (Join-Path $PSScriptRoot 'install-log.ps1')
. (Join-Path $PSScriptRoot 'install-helper.ps1')
. (Join-Path $PSScriptRoot 'steam-session.ps1')
$steamSession = @{ Restart=$false }
$updaterMaintenance = $null
$lock = $null; $transaction = $null; $receipt = $null; $removedShortcut = $null; $removalLease = $null
$rollbackExpected = @{}
$externalBundle = $null; $diagnosticOwner=$null; $diagnosticPhase='Uninstall'
function Get-UninstallHash([string]$Path) {
    # InputStream avoids PS 5.1's path pipeline inheriting -WhatIf and returning no hash.
    $stream = [IO.File]::OpenRead($Path)
    try { return (Get-FileHash -InputStream $stream -Algorithm SHA256).Hash }
    finally { $stream.Dispose() }
}
try {
    $steamRoot = (Get-ItemProperty 'HKCU:/Software/Valve/Steam' -ErrorAction SilentlyContinue).SteamPath
    if (!$GameRoot) {
        $candidates = @(if ($steamRoot) { Find-IntGameDirectories $steamRoot $root } else { Resolve-IntGameDirectory (Split-Path -Parent $root) })
        if ($candidates.Count -eq 1) { $GameRoot = $candidates[0] }
        else {
            $candidates | ForEach-Object { Write-Host $_ }
            $GameRoot = Read-Host 'INT 게임 폴더 경로 / INT game folder (blank cancels)'
        }
    }
    $GameRoot = Resolve-IntGameDirectory $GameRoot
    if (!$GameRoot) { throw 'INT 게임 경로를 확인하세요. / INT game folder not found; nothing removed.' }
    # Finish interactive preparation before reading file hashes or beginning a transaction.
    if (!$AccountId) {
        $AccountId = & (Join-Path $PSScriptRoot 'steam-shortcut.ps1') -Mode ResolveAccount -GameRoot $GameRoot -SteamRoot $steamRoot
    }
    $removeShortcut = & (Join-Path $PSScriptRoot 'steam-shortcut.ps1') -Mode PlanRemove -GameRoot $GameRoot -SteamRoot $steamRoot -AccountId $AccountId
    $installedLauncher = Join-Path $GameRoot 'BetterAstralParty-Launcher.exe'
    . (Join-Path $PSScriptRoot 'install-policy.ps1')
    $externalBundle = Open-BapInstallBundle -PackageRoot $root -GameRoot $GameRoot
    $receiptPath = Join-Path $GameRoot 'BetterAstralParty.install.json'
    Assert-InstallTarget $GameRoot $receiptPath
    $hashes = @{}
    if (Test-Path -LiteralPath $receiptPath -PathType Leaf) {
        try {
            $receiptBytes=Read-BapInstallFile $receiptPath
            $receipt = Read-BapInstallJson $receiptBytes
            $names = @($receipt.PSObject.Properties.Name)
            if (($receipt.schema -isnot [int] -and $receipt.schema -isnot [long]) -or $receipt.schema -ne 1 -or
                $receipt.owner -isnot [string] -or $receipt.owner -cne 'kr.betterastralparty.mod' -or
                $receipt.baseline -cne '1.2.1' -or $names.Count -ne 6 -or @('schema','baseline','channelState','owner','loaderBefore','files' | Where-Object { $names -cnotcontains $_ }).Count -or
                ($null -ne $receipt.loaderBefore -and $receipt.loaderBefore -isnot [bool]) -or
                $receipt.files -isnot [Array] -or $receipt.files.Count -gt 8) { throw 'Invalid installation receipt shape' }
            $validator=(Get-BapInstallVerifier $externalBundle).GetType('SteamLauncher').GetMethod('ValidateInstalledReceipt',[Reflection.BindingFlags]'Public,Static')
            if(!$validator){throw 'Channel receipt validator required'}
            $validatorArguments=[object[]]::new(1);$validatorArguments[0]=[byte[]]$receiptBytes;$null=$validator.Invoke($null,$validatorArguments)
            foreach ($entry in $receipt.files) {
                if (@($entry.PSObject.Properties).Count -ne 2 -or $entry.path -isnot [string] -or
                    !($externalBundle.Expected.Keys -ccontains $entry.path) -or $hashes.ContainsKey($entry.path) -or
                    $entry.sha256 -isnot [string] -or $entry.sha256 -cnotmatch '\A[A-F0-9]{64}\z') { throw 'Invalid installation receipt entry' }
                $hashes[$entry.path] = $entry.sha256
            }
        } catch { throw [InvalidOperationException]::new(('새 1.2.1 기준판 설치만 제거할 수 있습니다. 이전 설치는 이전 패키지로 제거하세요. / Only the new 1.2.1 baseline is supported; use the previous package to uninstall older installations. '+$_.Exception.GetBaseException().Message), $_.Exception) }
    }
    elseif (@($externalBundle.Expected.Keys | Where-Object { Test-Path -LiteralPath (Join-Path $GameRoot $_) }).Count) { throw '설치 기록이 없거나 이전 설치가 남아 있습니다. 파일을 보존합니다. / Missing baseline receipt or previous installation retained.' }
    if (!$WhatIfPreference) { Stop-BapGame $GameRoot }
    $declaredLauncherHash = $hashes['BetterAstralParty-Launcher.exe']
    if ($declaredLauncherHash -and (Test-Path -LiteralPath $installedLauncher -PathType Leaf) -and (Get-UninstallHash $installedLauncher) -cne $declaredLauncherHash) {
        throw '런처가 설치 기록과 다릅니다. 검토된 복구가 필요합니다. / Modified installed launcher; reviewed recovery required before removal.'
    }
    if (!$declaredLauncherHash -and (Test-Path -LiteralPath $installedLauncher -PathType Leaf) -and (Get-UninstallHash $installedLauncher) -cne $externalBundle.Expected['BetterAstralParty-Launcher.exe']) {
        throw '출처를 확인할 수 없는 런처를 보존하고 중단합니다. / Unrecognized installed launcher retained; recovery review required.'
    }
    $updaterMaintenance = Enter-BapUpdateMaintenance $GameRoot -ReadOnly:$WhatIfPreference -VerifiedBundle $externalBundle
    $null = Assert-BapInstallRoot $externalBundle
    if ($receipt) {
        $historyValidator=(Get-BapInstallVerifier $externalBundle).GetType('SteamLauncher').GetMethod('ValidateInstalledHistory',[Reflection.BindingFlags]'Public,Static')
        if(!$historyValidator){throw '현재 설치 이력 검사기가 필요합니다. 최신 전체 설치 묶음을 사용하세요. / Current complete package with installed history validation is required.'}
        try {$null=$historyValidator.Invoke($null,[object[]]@([string]$GameRoot))}
        catch {throw [InvalidOperationException]::new(('설치·채널 이력 검증에 실패했습니다. 파일과 백업을 보존하세요. / Installed channel/history validation failed; retain files and backups. '+$_.Exception.GetBaseException().Message), $_.Exception)}
    }
    # Fixed allowlist; never recursively remove a plugin directory or trust receipt paths.
    $files = @(
        @{ Path='BepInEx/plugins/BetterAstralParty/BetterAstralParty.dll'; Source='artifacts/BetterAstralParty.dll'; Assembly='BetterAstralParty' }
        @{ Path='BetterAstralParty-Launcher.exe'; Source='artifacts/BetterAstralParty-Launcher.exe'; Assembly='BetterAstralParty-Launcher' }
        @{ Path='BetterAstralParty.compatibility.json'; Source='artifacts/BetterAstralParty.compatibility.json' }
        foreach ($name in @('BetterAstralParty-Mod.cmd','AstralParty-Vanilla.cmd','check-compatibility.ps1','BetterAstralParty-Steam.ps1','steam-shortcut.ps1')) {
            @{ Path=$name; Source="tools/$name" }
        }
        foreach ($name in @('BepInEx/config/kr.betterastralparty.mod.cfg','BepInEx/BetterAstralParty-Diagnostics/current.log',
            'BepInEx/BetterAstralParty-Diagnostics/previous.log','BepInEx/BetterAstralParty-Diagnostics/combat-mismatch.log',
            'BepInEx/BetterAstralParty-Diagnostics/combat-mismatch-previous.log','BetterAstralParty-Compatibility.log','BetterAstralParty-LaunchError.log')) {
            @{ Path=$name; Exclusive=$true }
        }
    )
    $targets = @(); $missingOwned = @(); $plannedHashes = @{}; $keptReceiptFile = $false
    $helperPath = Join-Path $GameRoot 'BetterAstralParty-UpdateHelper.exe'
    $helperReceipt = Join-Path $GameRoot 'BetterAstralParty.helper.receipt'
    if ((Test-Path -LiteralPath $helperPath) -or (Test-Path -LiteralPath $helperReceipt)) {
        Assert-InstallTarget $GameRoot $helperPath
        Assert-InstallTarget $GameRoot $helperReceipt
        $helperHash = $null
        $gateAssembly = Get-BapInstallVerifier $externalBundle
        $helperMethod = $gateAssembly.GetType('SteamLauncher').GetMethod('CheckOwnedHelper', [Reflection.BindingFlags]'Public,Static')
        if ($helperMethod) { $helperHash = $helperMethod.Invoke($null, @([string]$GameRoot)) }
        if ($helperHash -is [string] -and $helperHash -cmatch '\A([A-F0-9]{64}):([A-F0-9]{64})\z' -and (Test-Path -LiteralPath $helperPath -PathType Leaf) -and (Test-Path -LiteralPath $helperReceipt -PathType Leaf)) {
            $verifiedImage = $Matches[1]; $verifiedReceipt = $Matches[2]
            if ((Get-UninstallHash $helperPath) -ceq $verifiedImage -and (Get-UninstallHash $helperReceipt) -ceq $verifiedReceipt) {
                $targets += @($helperPath,$helperReceipt)
                $plannedHashes[$helperPath] = $verifiedImage; $plannedHashes[$helperReceipt] = $verifiedReceipt
            } else { throw '검증 후 helper 파일이 바뀌었습니다. 제거하지 않고 중단합니다. / Helper changed after verification.' }
        } else { $keptReceiptFile=$true; Write-Warning 'helper의 소유를 확인할 수 없어 파일·기록을 보존합니다. / Unverified update helper and receipt retained.' }
    }
    foreach ($file in $files) {
        $path = Join-Path $GameRoot $file.Path
        Assert-InstallTarget $GameRoot $path
        if (!(Test-Path -LiteralPath $path)) {
            if ($hashes.ContainsKey($file.Path)) { $missingOwned += $path; $plannedHashes[$path] = $null }
            continue
        }
        if (!(Test-Path -LiteralPath $path -PathType Leaf)) { throw "Expected a file: $path" }
        $hash = Get-UninstallHash $path
        $owned = $file.Exclusive -or ($hashes.ContainsKey($file.Path) -and $hashes[$file.Path] -eq $hash)
        # A current receipt takes precedence over an older package and assembly name.
        if (!$owned -and !$receipt -and $file.Source -and (Test-Path -LiteralPath (Join-Path $root $file.Source) -PathType Leaf)) {
            $owned = (Get-UninstallHash (Join-Path $root $file.Source)) -eq $hash
        }
        if ($owned) { $targets += $path; $plannedHashes[$path] = $hash }
        else {
            if ($receipt) { $keptReceiptFile = $true }
            Write-Warning "보존: 소유 확인 불가 또는 변경된 파일 / Kept unknown or modified file: $path"
        }
    }
    if($keptReceiptFile) {
        # Keep the verified helper provenance with a retained installation receipt for later reviewed repair.
        foreach($path in @($helperPath,$helperReceipt)) {
            $targets=@($targets|Where-Object {$_ -cne $path})
            $plannedHashes.Remove($path)
        }
    }
    if ($missingOwned.Count -and !$keptReceiptFile) {
        $validate=(Get-BapInstallVerifier $externalBundle).GetType('SteamLauncher').GetMethod('ValidatePartialRemovalWithPackage',[Reflection.BindingFlags]'Public,Static')
        if(!$validate){throw 'Current partial-removal validation API required.'}
        $null=$validate.Invoke($null,[object[]]@([string]$GameRoot,[string]$externalBundle.PackageRoot,[string]$externalBundle.Version.Text))
    }
    if ($receipt -and !$keptReceiptFile) { $targets += $receiptPath; $plannedHashes[$receiptPath] = Get-UninstallHash $receiptPath }
    elseif ($keptReceiptFile) { Write-Warning '소유권이 불확실하거나 수정된 파일과 설치 기록을 보존합니다. / Unknown or modified files and their receipt are retained.' }
    if (!$targets.Count -and !$removeShortcut) { Write-Host '제거할 확인된 파일·바로가기가 없습니다. / No verified mod files or shortcut to remove.'; return }
    $loaderPath = Join-Path $GameRoot 'doorstop_config.ini'
    Assert-InstallTarget $GameRoot $loaderPath
    $loaderText = $null; $loaderUpdated = $null
    if ($RestoreLoader -ne 'Keep' -and $targets.Count -and (Test-Path -LiteralPath $loaderPath -PathType Leaf)) {
        $loaderText = [IO.File]::ReadAllText($loaderPath)
        $enabled = [regex]::Matches($loaderText, '(?m)^enabled\s*=\s*(true|false)\s*$')
        if ($enabled.Count -gt 1) { throw 'Ambiguous loader configuration; nothing removed.' }
        if ($enabled.Count -eq 1) {
            $restore = if ($RestoreLoader -eq 'Recorded') {
                # Explicit legacy restoration only; ordinary removal never rewrites shared settings.
                if ($enabled[0].Groups[1].Value -eq 'true') { $true } else { $receipt.loaderBefore }
            } else { $RestoreLoader -eq 'Enabled' }
            if ($restore -isnot [bool]) {
                Write-Host '설치 전 로더 상태 기록이 없습니다. / Original loader state was not recorded.'
                if ($WhatIfPreference) {
                    Write-Host '실제 제거 시 로더 활성화/비활성화를 선택해야 합니다. / Actual removal requires an explicit loader choice.'
                } else {
                    Write-Host '1: 다른 BepInEx 모드 실행 유지 (로더 켜기, 권장) / Keep other BepInEx mods running (enable loader, recommended)'
                    Write-Host '2: 모든 BepInEx 모드 실행 끄기 / Disable all BepInEx mods'
                    try { $choice = Read-Host '1 / 2 선택, Enter는 취소 / Choose 1 / 2, Enter cancels' }
                    catch { throw 'Interactive selection unavailable. Specify -RestoreLoader Enabled or Disabled. Nothing removed.' }
                    if ($choice -notin @('1','2')) {
                        Write-Host '취소했습니다. 아무것도 변경하지 않았습니다. / Cancelled; nothing changed.'
                        return
                    }
                    $restore = $choice -eq '1'
                }
            }
            if ($restore -is [bool]) {
                $loaderUpdated = [regex]::Replace($loaderText, '(?m)^enabled\s*=\s*(true|false)\s*$', ('enabled=' + $restore.ToString().ToLowerInvariant()))
            }
        }
    }
    $backupTargets = @($targets)+@($missingOwned)
    if ($loaderUpdated -ne $null) { $backupTargets += $loaderPath; $plannedHashes[$loaderPath] = Get-UninstallHash $loaderPath }
    Assert-BapMaintenancePathPlan $externalBundle $backupTargets
    Write-Host "제거 대상 / Files to remove ($GameRoot):"
    $targets | ForEach-Object { Write-Host "  $_" }
    if ($loaderUpdated -ne $null) { Write-Host "Restore loader enabled=$restore (other settings preserved)" }
    if ($removeShortcut) { Write-Host 'Remove the matching Astral Party - Mod shortcut only; keep all other Steam entries.' }
    Write-Host '전용 설정·로그도 백업 후 제거합니다. 공용 로더·다른 모드는 유지합니다. / Includes mod settings/logs; shared loader and other mods stay.'
    if (!$PSCmdlet.ShouldProcess($GameRoot, 'BetterAstralParty 파일 백업 및 제거 / Back up and remove listed BetterAstralParty files')) { return }
    $diagnosticOwner=Start-BapInstallerDiagnostics $externalBundle
    Write-BapInstallerStage $externalBundle 'Uninstall' 'Begin'
    $journal = Get-InstallJournalPath $GameRoot
    $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $journal))
    $lock = [IO.File]::Open(($journal + '.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    if (Test-Path -LiteralPath $journal) { throw "미완료 복구를 먼저 해결하세요. / Pending recovery: $journal" }
    if ($removeShortcut) {
        Stop-BapSteam $steamRoot $steamSession
        # Re-read after Steam flushes its file, keeping the selected account pinned.
        $removeShortcut = & (Join-Path $PSScriptRoot 'steam-shortcut.ps1') -Mode PlanRemove -GameRoot $GameRoot -SteamRoot $steamRoot -AccountId $AccountId
    }
    if (@(Get-BapGameTargets $GameRoot).Count) { throw 'Game/launcher started; removal cancelled.' }
    if ($removeShortcut) { Assert-BapSteamStopped $steamRoot 'UninstallPreflight' }
    $transaction = Start-InstallTransaction $GameRoot $backupTargets 0
    $state = Get-Content -LiteralPath $transaction -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Host "복구용 백업 / Recovery backup: $($state.BackupDir)"
    foreach ($entry in $state.Entries) {
        if ($entry.Hash -ne $plannedHashes[$entry.Target]) { throw "File changed since confirmation preview: $($entry.Target)" }
    }
    $nativeRemoval=(Get-BapInstallVerifier $externalBundle).GetType('SteamLauncher').GetMethod('BeginOwnedRemoval',[Reflection.BindingFlags]'Public,Static')
    if(!$nativeRemoval -or ![IDisposable].IsAssignableFrom($nativeRemoval.ReturnType)){throw 'Held-object removal API required; use a current complete package.'}
    $removalArguments=[object[]]::new(6)
    $removalArguments[0]=[string]$GameRoot;$removalArguments[1]=[string](Split-Path -Parent $transaction)
    $removalArguments[2]=[string](Get-UninstallHash $transaction);$removalArguments[3]=[string[]]$backupTargets
    $removalArguments[4]=[string]$externalBundle.RootIdentity;$removalArguments[5]=[bool]($loaderUpdated -ne $null)
    $removalLease=$nativeRemoval.Invoke($null,$removalArguments)
    foreach ($entry in $state.Entries) {
        if (!$entry.Existed) {
            $rollbackExpected[$entry.Target]=$null
            $removalLease.Remove([string]$entry.Target)
            continue
        }
        if ($entry.Target -eq $loaderPath) {
            $sha = [Security.Cryptography.SHA256]::Create()
            try { $rollbackExpected[$loaderPath] = [BitConverter]::ToString($sha.ComputeHash([Text.UTF8Encoding]::new($false).GetBytes($loaderUpdated))).Replace('-', '') }
            finally { $sha.Dispose() }
            $removalLease.WriteLoader([string]$loaderPath,[string]$loaderUpdated)
        } else { $rollbackExpected[$entry.Target] = $null; $removalLease.Remove([string]$entry.Target) }
    }
    if ($removeShortcut) {
        $removedShortcut = & (Join-Path $PSScriptRoot 'steam-shortcut.ps1') -Mode Remove -GameRoot $GameRoot -SteamRoot $steamRoot -AccountId $AccountId
    }
    $removalLease.Dispose();$removalLease=$null
    Complete-InstallTransaction $GameRoot -AllowedTargets $backupTargets -VerifiedBundle $externalBundle
    $transaction = $null
    Write-BapInstallerStage $externalBundle 'Uninstall' 'Completed'
    foreach ($relative in @('BepInEx/plugins/BetterAstralParty','BepInEx/BetterAstralParty-Diagnostics')) {
        $dir = Join-Path $GameRoot $relative
        Assert-InstallTarget $GameRoot $dir
        if ((Test-Path -LiteralPath $dir -PathType Container) -and @(Get-ChildItem -LiteralPath $dir -Force).Count -eq 0) {
            try { [IO.Directory]::Delete($dir, $false) } catch { Write-Warning "Empty folder retained: $dir" }
        }
    }
    if ($keptReceiptFile -or !$receipt) {
        Write-Host '확인된 파일 제거를 마쳤습니다. 미확인·변경 파일과 기록은 남아 있습니다. / Verified files removed; unknown or modified files and evidence remain.'
    } else {
        Write-Host '제거 완료. 모드 파일·바로가기를 정리했습니다. 공용 로더 설정과 다른 모드는 유지합니다. / Removed mod files and shortcut; shared loader settings and other mods preserved.'
    }
} catch {
    $failure = $_
    if($removalLease){$removalLease.Dispose();$removalLease=$null}
    Write-BapInstallerError $externalBundle $diagnosticPhase $_.Exception
    if ($removedShortcut) {
        try {
        Assert-BapSteamStopped $steamRoot 'ShortcutRollback'
        if ((Get-UninstallHash $removedShortcut.Path) -eq $removedShortcut.Hash) {
            [IO.File]::Copy($removedShortcut.Backup, $removedShortcut.Path, $true)
            foreach ($art in $removedShortcut.Artwork) {
                if (!(Test-Path -LiteralPath $art.Path) -and (Get-UninstallHash $art.Backup) -eq $art.Hash) {
                    [IO.File]::Copy($art.Backup, $art.Path, $false)
                } else { Write-Warning "Steam artwork recovery needs review; backup: $($art.Backup)" }
            }
        } else { Write-Warning "Steam shortcut recovery needs manual review; backup: $($removedShortcut.Backup)" }
        } catch {
            Write-BapInstallerError $externalBundle 'Rollback' $_.Exception
            $null = Write-InstallFailure $_ 'Steam shortcut rollback deferred; retain backup' $root $GameRoot -Operation 'Uninstall'
            Write-Warning "Steam shortcut recovery failed; backup: $($removedShortcut.Backup)"
        }
    }
    if ($transaction) {
        try { Write-BapInstallerStage $externalBundle 'Rollback' 'Begin';Restore-InstallTransaction $GameRoot -ExpectedCurrent $rollbackExpected -AllowedTargets $backupTargets -VerifiedBundle $externalBundle;Write-BapInstallerStage $externalBundle 'Rollback' 'Completed' }
        catch { Write-Warning "복구 미완료: 백업을 보관하세요. / Recovery incomplete; retain $transaction. $($_.Exception.Message)" }
    }
    $null = Write-InstallFailure $failure 'Uninstall' $root $GameRoot -Operation 'Uninstall'
    throw $failure
} finally {
    if($removalLease){$removalLease.Dispose()}
    if($diagnosticOwner){$diagnosticOwner.Dispose()}
    if ($lock) { $lock.Dispose() }
    if ($updaterMaintenance) { $updaterMaintenance.Dispose() }
    if ($externalBundle) { foreach ($lease in $externalBundle.Leases) { $lease.Dispose() } }
    Resume-BapSteam $steamSession
}
