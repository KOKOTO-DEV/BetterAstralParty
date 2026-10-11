param([string]$EvidencePath)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'steam-session.ps1')
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('bap-steam-observation-' + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory((Join-Path $scratch 'steamapps'))
[IO.File]::WriteAllText((Join-Path $scratch 'steam.exe'), 'inert')
$session = [Diagnostics.Process]::GetCurrentProcess().SessionId
$probe = @{Processes=@(); Killed=@(); Answers=@(); Reads=0; Sleeps=0; ExitAfterPoll=0; Change=$false; Restart=$false; FailObserve=$false}
$checks = [Collections.Generic.List[object]]::new()
function Check([string]$Name, [bool]$Passed) { $checks.Add([pscustomobject]@{case=$Name;passed=$Passed}); if (!$Passed) { throw ('Failed: ' + $Name) } }
function Process([int]$Id, [string]$Path, [int]$Session = $session) {
    $item = [pscustomobject]@{Id=$Id; ProcessName='steam'; Path=$Path; SessionId=$Session; StartTime=[datetime]'2026-01-01T00:00:00Z'; HasExited=$false}
    $item | Add-Member ScriptMethod WaitForExit { param($Milliseconds); $true }
    return $item
}
function Get-Process { param($Name,$Id,$ErrorAction)
    if ($probe.FailObserve) { throw 'fixture enumeration unavailable' }
    if ($Id) { return @($probe.Processes | Where-Object Id -eq $Id) }
    if ($Name) { return @($probe.Processes | Where-Object ProcessName -in $Name) }
    return $probe.Processes
}
function Stop-Process { param($InputObject,[switch]$Force,$ErrorAction)
    if (!$Force) { throw 'Expected explicit force flag' }
    $probe.Killed += $InputObject.Id
    $probe.Processes = @($probe.Processes | Where-Object Id -ne $InputObject.Id)
    if ($probe.ExitAfterPoll) { $probe.Processes = @($helper) }
    if ($probe.Restart) { $probe.Processes = @($restarted) }
}
function Start-Sleep { param($Milliseconds)
    if ($Milliseconds -ne 100) { throw 'Unbounded or unexpected poll' }
    $probe.Sleeps++
    if ($probe.ExitAfterPoll -and $probe.Sleeps -ge $probe.ExitAfterPoll) { $probe.Processes=@() }
}
function Read-Host {
    $probe.Reads++
    if (!$probe.Answers.Count) { throw 'Unexpected prompt or noninteractive input' }
    $answer = $probe.Answers[0]
    $probe.Answers = @($probe.Answers | Select-Object -Skip 1)
    if ($answer -eq 'r') { $probe.Processes=@() }
    if ($probe.Change) { $probe.Processes += (Process 12 (Join-Path $scratch 'steam.exe')) }
    return $answer
}
function Start-Process { throw 'Real process start forbidden in observation fixture' }
function Failure([scriptblock]$Action, [string]$Reason) {
    try { & $Action; throw 'Expected refusal' }
    catch {
        if ($_.Exception.Message -eq 'Expected refusal') { throw }
        $json = $_.Exception.Data['BapSteamDiagnostic']
        if ($json -isnot [string]) { throw 'Missing Steam diagnostic context' }
        $data = $json | ConvertFrom-Json
        Check ('failure reason ' + $Reason) ($data.schema -eq 1 -and $data.reason -ceq $Reason)
        Check ('bounded private context ' + $Reason) ([Text.Encoding]::UTF8.GetByteCount($json) -le 16384 -and !$json.Contains($scratch) -and $json -notmatch 'CommandLine|Account|Environment|SteamRoot')
        return $data
    }
}
try {
    $selected = Process 10 (Join-Path $scratch 'steam.exe')
    $foreign = Process 20 'C:\unrelated\steam.exe'
    $stale = Process 19 ''; $stale.Path=$null; $stale.HasExited=$true; $probe.Processes=@($stale)
    Assert-BapSteamStopped $scratch
    Check 'stale exited observation does not create unknown ownership' ((Get-BapSteamStatus $scratch).State -eq 'Stopped')
    $race = Process 18 ''; $race | Add-Member ScriptProperty Path { $this.HasExited=$true; return $null } -Force
    $probe.Processes=@($race)
    Assert-BapSteamStopped $scratch
    Check 'exit during identity read does not become ownership failure' ((Get-BapSteamStatus $scratch).State -eq 'Stopped')
    $probe.Processes=@($foreign)
    Stop-BapSteam $scratch @{Restart=$false}
    Assert-BapSteamStopped $scratch 'InstallPreflight'
    Check 'known other-root client is neither killed nor a false restart' (!$probe.Killed.Count -and !$probe.Reads)
    $probe.Processes=@(Process 21 $foreign.Path ($session + 1))
    Assert-BapSteamStopped $scratch 'ShortcutCommit'
    Check 'known other-root other-session client does not block selected userdata' ((Get-BapSteamStatus $scratch).State -eq 'Stopped')
    $probe.Processes=@(Process 22 $selected.Path ($session + 1)); $probe.Answers=@('')
    $null = Failure { Stop-BapSteam $scratch @{Restart=$false} } 'SteamOtherSession'
    Check 'same-root other-session protects shared userdata and is never killed' (!$probe.Killed.Count)
    $unknown = Process 23 ''; $unknown.Path=$null; $probe.Processes=@($unknown); $probe.Answers=@('')
    $data = Failure { Stop-BapSteam $scratch @{Restart=$false} } 'SteamOwnershipUnknown'
    Check 'missing path is explicit unknown, not a restart' ($null -eq $data.processes[0].pathMatch -and !$data.processes[0].pathAvailable)
    $inaccessible = Process 25 $selected.Path; $inaccessible | Add-Member ScriptProperty Path { throw 'fixture access denied' } -Force
    $probe.Processes=@($inaccessible)
    $null = Failure { Assert-BapSteamStopped $scratch 'ShortcutCommit' } 'SteamOwnershipUnknown'
    $probe.Processes=@($unknown)
    $probe.Answers=@('r')
    Stop-BapSteam $scratch @{Restart=$false}
    Check 'unknown ownership can recover by normal exit and recheck without force' (!$probe.Killed.Count)
    $probe.Processes=@($selected); $probe.Answers=@('r')
    Stop-BapSteam $scratch @{Restart=$false}
    Check 'verified running client offers normal exit and recheck' (!$probe.Killed.Count)
    $probe.Processes=@($selected); $probe.Answers=@('')
    $null = Failure { Stop-BapSteam $scratch @{Restart=$false} } 'ConsentCancelled'
    $probe.Processes=@($selected); $probe.Answers=@()
    $null = Failure { Stop-BapSteam $scratch @{Restart=$false} } 'ConsentUnavailable'
    $probe.Processes=@($selected); $probe.Answers=@('y'); $probe.Change=$true
    $null = Failure { Stop-BapSteam $scratch @{Restart=$false} } 'ProcessListChanged'
    Check 'changed approved list stops before killing' (!$probe.Killed.Count)
    $probe.Change=$false; $probe.Processes=@($selected); $probe.Answers=@('y'); $probe.Sleeps=0
    $helper = Process 24 (Join-Path $scratch 'steamwebhelper.exe'); $helper.ProcessName='steamwebhelper'; $probe.ExitAfterPoll=3
    $state=@{Restart=$false}; Stop-BapSteam $scratch $state
    Check 'bounded completion wait tolerates child exit delay' ($probe.Sleeps -eq 3 -and $state.Restart -and ($probe.Killed -join ',') -eq '10')
    $probe.ExitAfterPoll=0; $probe.Processes=@($selected); $probe.Answers=@('y'); $probe.Sleeps=0; $probe.Restart=$true
    $restarted = Process 30 $selected.Path
    $data = Failure { Stop-BapSteam $scratch @{Restart=$false} } 'SteamRunning'
    Check 'new client is recorded but never killed on old consent' ($data.processes[0].pid -eq 30 -and 30 -notin $probe.Killed -and $probe.Sleeps -eq 20)
    $probe.Restart=$false; $probe.Processes=@($selected)
    $target=[pscustomobject]@{Id=10;Path=$selected.Path;Started=$selected.StartTime;Session=$session}
    $selected.StartTime=$selected.StartTime.AddSeconds(1)
    $null = Failure { Stop-BapVerifiedProcess $target } 'ProcessIdentityChanged'
    $probe.FailObserve=$true
    $null = Failure { Assert-BapSteamStopped $scratch } 'ProcessObservationUnavailable'
    $probe.FailObserve=$false
    $rows = 1..80 | ForEach-Object { [pscustomobject]@{pid=$_;sessionMatch=$true;pathAvailable=$true;pathMatch=$false;startAvailable=$false;startedUtc=$null} }
    $bounded=(New-BapSteamFailure 'inert' 'SteamRunning' 'InstallPreflight' ([pscustomobject]@{Facts=$rows})).Data['BapSteamDiagnostic'] | ConvertFrom-Json
    Check 'context quota reports every omitted row' ($bounded.processes.Count -eq 48 -and $bounded.observedCount -eq 80 -and $bounded.omittedCount -eq 32)
    $files=@('steam-session.ps1','steam-shortcut.ps1','install.ps1','uninstall.ps1','test-steam-observation.ps1')
    $inputs=@($files | ForEach-Object { $path=Join-Path $PSScriptRoot $_; [pscustomobject]@{file=$_;sha256=(Get-FileHash -LiteralPath $path).Hash} })
    $result=[ordered]@{runtime=$PSVersionTable.PSVersion.ToString();passed=$checks.Count;failed=0;cases=@($checks);inputs=$inputs;realSteamOrGameTouched=$false}
    if ($EvidencePath) { [IO.File]::WriteAllText([IO.Path]::GetFullPath($EvidencePath),($result | ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false)) }
    $result | ConvertTo-Json -Depth 6
} finally {
    $resolved=[IO.Path]::GetFullPath($scratch)
    if ((Split-Path $resolved -Parent) -ne [IO.Path]::GetTempPath().TrimEnd('\') -or (Split-Path $resolved -Leaf) -notlike 'bap-steam-observation-*') { throw 'Unsafe fixture cleanup' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
