$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'steam-session.ps1')
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('bap-force-' + [guid]::NewGuid().ToString('N'))
$probe = @{Processes=@(); Killed=@(); Starts=0; Answer='y'; FailId=0; Change=$false}
function New-FakeProcess($Id,$Name,$Path,$Session) {
    $p = [pscustomobject]@{Id=$Id; ProcessName=$Name; Path=$Path; SessionId=$Session; StartTime=[datetime]::new(2026,1,1); HasExited=$false}
    $p | Add-Member ScriptMethod WaitForExit { param($Milliseconds); return $true }
    return $p
}
function Get-Process { param($Name,$Id,$ErrorAction)
    if ($Name) { return @($probe.Processes | Where-Object ProcessName -in $Name) }
    if ($Id) { return @($probe.Processes | Where-Object Id -eq $Id) }
    return $probe.Processes
}
function Stop-Process { param($InputObject,[switch]$Force,$ErrorAction)
    if ($probe.ExitAtStop) { $InputObject.HasExited=$true; throw 'fixture already exited' }
    if (!$Force -or $InputObject.Id -eq $probe.FailId) { throw 'fixture kill failure' }
    $probe.Killed += $InputObject.Id
    $probe.Processes = @($probe.Processes | Where-Object Id -ne $InputObject.Id)
}
function Start-Process { param($FilePath,$WindowStyle)
    if ($FilePath -ne (Join-Path $scratch 'steam.exe') -or $WindowStyle -ne 'Hidden') { throw 'Unexpected restart' }
    $probe.Starts++
    $probe.Processes += $client
}
function Read-Host {
    if ($probe.Answer -eq 'throw') { throw 'noninteractive' }
    if ($probe.Change) { $probe.Processes += (New-FakeProcess 108 'newgame' (Join-Path $scratch 'steamapps/common/Game/new.exe') $session) }
    return $probe.Answer
}
try {
    $null = [IO.Directory]::CreateDirectory((Join-Path $scratch 'steamapps'))
    [IO.File]::WriteAllText((Join-Path $scratch 'steam.exe'), 'inert')
    [IO.File]::WriteAllText((Join-Path $scratch 'steamapps/appmanifest_1.acf'), '"installdir" "Game"')
    $absentDrive = [char[]](65..90) | Where-Object { !(Test-Path -LiteralPath ("${_}:\") -PathType Container) } | Select-Object -First 1
    if (!$absentDrive) { throw 'Fixture requires an unavailable drive' }
    $vdf = Join-Path $scratch 'steamapps/libraryfolders.vdf'
    $missingLibraries = '"path" "' + "${absentDrive}:\BapMissingLibrary" + '" "path" "' + (Join-Path $scratch 'MissingLibrary') + '"'
    [IO.File]::WriteAllText($vdf, $missingLibraries)
    $session = [Diagnostics.Process]::GetCurrentProcess().SessionId
    $client = New-FakeProcess 101 'steam' (Join-Path $scratch 'steam.exe') $session
    $game = New-FakeProcess 102 'game' (Join-Path $scratch 'steamapps/common/Game/game.exe') $session
    $helper = New-FakeProcess 103 'steamwebhelper' (Join-Path $scratch 'bin/steamwebhelper.exe') $session
    $other = New-FakeProcess 104 'browser' 'C:\unrelated\browser.exe' $session
    $sibling = New-FakeProcess 105 'game2' (Join-Path $scratch 'steamapps/common/Game2/game.exe') $session
    $foreignSession = New-FakeProcess 106 'game' $game.Path ($session + 1)
    $fakeSteam = New-FakeProcess 107 'steam' 'C:\unrelated\steam.exe' $session
    $probe.Processes=@($client,$game,$helper,$other,$sibling,$foreignSession,$fakeSteam)
    $targets = @(Get-BapSteamTargets $scratch)
    if (($targets.Id | Sort-Object) -join ',' -ne '101,102,103') { throw 'Path/session scope failed' }
    [IO.File]::WriteAllText($vdf, '"path" "relative-library"')
    try { $null = @(Get-BapSteamTargets $scratch); throw 'Expected relative-library refusal' }
    catch { if ($_.Exception.Message -notlike '*Invalid Steam library path*') { throw } }
    [IO.File]::WriteAllText($vdf, $missingLibraries)
    $badManifest = Join-Path $scratch 'steamapps/appmanifest_bad.acf'
    [IO.File]::WriteAllText($badManifest, '"installdir" "../other"')
    try { $null = @(Get-BapSteamTargets $scratch); throw 'Expected malformed-manifest refusal' }
    catch { if ($_.Exception.Message -notlike '*Invalid Steam app directory*') { throw } }
    Remove-Item -LiteralPath $badManifest
    Write-Host 'PASS: unavailable libraries skipped; relative libraries and malformed app paths still rejected.'
    foreach ($answer in @('', 'n', 'bad', 'throw')) {
        $probe.Answer=$answer; $state=@{Restart=$false}
        try { Stop-BapSteam $scratch $state; throw 'Expected consent cancellation' }
        catch { if ($_.Exception.Message -notmatch 'Cancelled;|requires interactive consent') { throw } }
        if ($probe.Killed.Count -or $state.Restart) { throw 'Killed before consent' }
    }
    $probe.Answer='Y'; $probe.Change=$true
    try { Stop-BapSteam $scratch $state; throw 'Expected changed-list refusal' }
    catch { if ($_.Exception.Message -notlike '*Process list changed*') { throw } }
    if ($probe.Killed.Count) { throw 'Changed list killed' }
    $probe.Change=$false
    $probe.Processes=@($client,$game,$helper,$other,$sibling,$foreignSession)
    $stale=$targets | Where-Object Id -eq 102
    $game.StartTime=$game.StartTime.AddSeconds(1)
    try { Stop-BapVerifiedProcess $stale; throw 'Expected PID-reuse refusal' }
    catch { if ($_.Exception.Message -notlike '*identity changed*') { throw } }
    $state=@{Restart=$false}
    Stop-BapSteam $scratch $state
    if (($probe.Killed | Sort-Object) -join ',' -ne '101,102,103') { throw 'Wrong termination set' }
    if (($probe.Processes.Id | Sort-Object) -join ',' -ne '104,105,106') { throw 'Unrelated process killed' }
    Resume-BapSteam $state
    Resume-BapSteam $state
    if ($probe.Starts -ne 1) { throw 'Restart was missing/duplicated' }
    $probe.Processes=@($client,$game); $probe.FailId=102; $state=@{Restart=$false}
    try { Stop-BapSteam $scratch $state; throw 'Expected partial kill failure' }
    catch { if ($_.Exception.Message -ne 'fixture kill failure') { throw } }
    finally { Resume-BapSteam $state }
    if ($probe.Starts -ne 2 -or !$state.Restart) { throw 'Partial failure did not restore Steam' }
    $probe.Processes=@(); $state=@{Restart=$false}
    Stop-BapSteam $scratch $state
    Resume-BapSteam $state
    if ($probe.Starts -ne 2) { throw 'Originally closed Steam started' }
    # Selected installation only: Astral Party and its launcher, no Steam/library-wide shutdown.
    $gameRoot = Join-Path $scratch 'steamapps/common/Game'
    $astral = New-FakeProcess 201 'AstralParty_INT' (Join-Path $gameRoot 'AstralParty_INT.exe') $session
    $launcher = New-FakeProcess 202 'BetterAstralParty-Launcher' (Join-Path $gameRoot 'BetterAstralParty-Launcher.exe') $session
    $different = New-FakeProcess 203 'AstralParty_INT' 'C:\other\AstralParty_INT.exe' $session
    $probe.Processes=@($client,$astral,$launcher,$different,$other); $probe.Killed=@(); $probe.FailId=0
    $probe.Answer='n'
    try { Stop-BapGame $gameRoot; throw 'Expected Astral cancellation' }
    catch { if ($_.Exception.Message -notlike '*Cancelled;*') { throw } }
    if ($probe.Killed.Count) { throw 'Astral stopped without consent' }
    $probe.Answer='Y'
    Stop-BapGame $gameRoot
    if (($probe.Killed -join ',') -ne '202,201') { throw 'Astral/launcher closure order or scope failed' }
    if (($probe.Processes.Id | Sort-Object) -join ',' -ne '101,104,203' -or $probe.Starts -ne 2) { throw 'Game-only cleanup touched Steam/other apps' }
    $probe.Killed=@()
    $race = New-FakeProcess 301 'steamwebhelper' 'C:\fixture\steamwebhelper.exe' $session
    $target = [pscustomobject]@{Id=301; Path=$race.Path; Started=$race.StartTime; Session=$session}
    $probe.Processes=@($race)
    $race.HasExited=$true; $race.Path=$null
    Stop-BapVerifiedProcess $target
    $race.HasExited=$false
    try { Stop-BapVerifiedProcess $target; throw 'Expected live missing-path refusal' }
    catch { if ($_.Exception.Message -notlike '*PathAvailable=False*') { throw } }
    $race | Add-Member ScriptProperty Path { $this.HasExited=$true; return $null } -Force
    Stop-BapVerifiedProcess $target
    $race = New-FakeProcess 301 'steamwebhelper' $target.Path $session
    $probe.Processes=@($race); $probe.ExitAtStop=$true
    Stop-BapVerifiedProcess $target
    $probe.ExitAtStop=$false
    if ($probe.Killed.Count) { throw 'Exit races must not kill another process' }
    Write-Host 'PASS: confirmed exit before/during identity read and at termination; live unknown identity still blocked.'
    Write-Host 'PASS: explicit consent, cancel/noninteractive, exact game/client paths, sibling/other-session isolation, changed list, PID reuse, force exit, restart and partial failure (inert process substitutes only).'
} finally {
    $resolved = [IO.Path]::GetFullPath($scratch)
    if ((Split-Path $resolved -Parent) -ne [IO.Path]::GetTempPath().TrimEnd('\') -or (Split-Path $resolved -Leaf) -notlike 'bap-force-*') { throw 'Unsafe fixture cleanup' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
