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
    $script:BapSteamProcessObserver=$null
    $nullSession=Process 41 $selected.Path;$nullSession.SessionId=$null;$probe.Processes=@($nullSession)
    Check 'null session is unavailable, not another session' ((Get-BapSteamStatus $scratch).State -eq 'Unknown')
    $once=Process 42 $selected.Path;$probe.PathReads=0;$probe.SelectedPath=$selected.Path
    $once|Add-Member ScriptProperty Path {$probe.PathReads++;if($probe.PathReads -ne 1){throw 'Path read twice'};return $probe.SelectedPath} -Force
    $probe.Processes=@($once)
    Check 'managed path is captured exactly once' ((Get-BapSteamStatus $scratch).State -eq 'Running' -and $probe.PathReads -eq 1)
    Add-Type -TypeDefinition @'
using System;
public sealed class BapSteamObservationFixtureError : Exception { public readonly int NativeError; public BapSteamObservationFixtureError(int code) { NativeError=code; } }
public static class BapSteamObservationFixture {
    public static object[] Result; public static int Calls, ExpectedPid, Error;
    public static object[] Read(int pid) { Calls++; if(pid!=ExpectedPid)throw new Exception("Unexpected PID");if(Error!=0)throw new BapSteamObservationFixtureError(Error);return Result; }
}
'@
    $script:BapSteamProcessObserver=[BapSteamObservationFixture].GetMethod('Read')
    $fallback=Process 43 $selected.Path;$fallback.Path=$null;$fallback.SessionId=$null;$fallback.StartTime=$null
    $probe.Processes=@($fallback);[BapSteamObservationFixture]::ExpectedPid=43
    [BapSteamObservationFixture]::Result=[object[]]@($false,$selected.Path,[long]$selected.StartTime.ToFileTime(),[uint32]$session)
    $native=Get-BapSteamStatus $scratch
    Check 'native snapshot resolves unavailable path session and creation' ($native.State -eq 'Running' -and $native.Facts[0].querySource -eq 'Native' -and $native.Facts[0].nativeError -eq 0)
    $target=[pscustomobject]@{Id=43;Path=$selected.Path;Started=$selected.StartTime;Session=$session}
    $killedBefore=$probe.Killed.Count
    Stop-BapVerifiedProcess $target
    Check 'final identity check shares native fallback before inert stop' ($probe.Killed.Count -eq $killedBefore+1 -and $probe.Killed[-1] -eq 43)
    $probe.Processes=@($fallback)
    [BapSteamObservationFixture]::Result=[object[]]@($false,$foreign.Path,[long]$selected.StartTime.ToFileTime(),[uint32]($session+1))
    Check 'native foreign root is excluded despite managed metadata missing' ((Get-BapSteamStatus $scratch).State -eq 'Stopped')
    [BapSteamObservationFixture]::Result=[object[]]@($false,$selected.Path,[long]$selected.StartTime.ToFileTime(),[uint32]($session+1))
    Check 'native same root different session remains protected' ((Get-BapSteamStatus $scratch).State -eq 'OtherSession')
    [BapSteamObservationFixture]::Error=5
    $unavailable=Get-BapSteamStatus $scratch
    Check 'native access failure preserves unknown and diagnostic cause' ($unavailable.State -eq 'Unknown' -and $unavailable.Facts[0].nativeError -eq 5 -and $unavailable.Facts[0].querySource -eq 'Unavailable')
    [BapSteamObservationFixture]::Error=0
    [BapSteamObservationFixture]::Result=[object[]]@($true,'',[long]0,[uint32]0)
    Check 'native confirmed exit is not a live unknown candidate' ((Get-BapSteamStatus $scratch).State -eq 'Stopped')
    [BapSteamObservationFixture]::Result=[object[]]@($false,$selected.Path,[long]$selected.StartTime.ToFileTime(),[uint32]$session)
    [BapSteamObservationFixture]::Error=87
    $notConfirmed=Get-BapSteamStatus $scratch
    Check 'native invalid PID alone is not proof of exit' ($notConfirmed.State -eq 'Unknown' -and $notConfirmed.Facts[0].nativeError -eq 87 -and !$notConfirmed.Facts[0].confirmedExit)
    [BapSteamObservationFixture]::Error=0
    $script:BapSteamProcessObserver=$null
    foreach($childName in @('steamwebhelper','steamerrorreporter','steamerrorreporter64')){
        $child=Process 51 (Join-Path $scratch ($childName+'.exe'));$child.ProcessName=$childName
        $closedClient=Process 52 $selected.Path;$closedClient.HasExited=$true;$closedClient.Path=$null
        $probe.Processes=@($closedClient,$child)
        $remaining=Get-BapSteamStatus $scratch
        Check ('surviving '+$childName+' still protects selected Steam after client exit') ($remaining.State -eq 'Running' -and $remaining.Targets.Count -eq 1 -and $remaining.Targets[0].Id -eq 51)
        $killedBefore=$probe.Killed.Count;$probe.Answers=@('r');$probe.Restart=$false;$probe.ExitAfterPoll=0
        $state=@{Restart=$false};Stop-BapSteam $scratch $state
        Check ('normal exit and recheck of '+$childName+' needs no force or restart') ((Get-BapSteamStatus $scratch).State -eq 'Stopped' -and $probe.Killed.Count -eq $killedBefore -and !$state.Restart)
        $child.Path=$null;$child.SessionId=$null;$probe.Processes=@($child);$probe.Answers=@('r')
        Check ('unavailable live '+$childName+' is pending rather than stopped') ((Get-BapSteamStatus $scratch).State -eq 'Unknown')
        Stop-BapSteam $scratch @{Restart=$false}
        Check ('unavailable '+$childName+' resolves only on fresh stopped recheck') ((Get-BapSteamStatus $scratch).State -eq 'Stopped' -and $probe.Killed.Count -eq $killedBefore)
    }
    $webChild=Process 53 (Join-Path $scratch 'steamwebhelper.exe');$webChild.ProcessName='steamwebhelper'
    $reportChild=Process 54 (Join-Path $scratch 'steamerrorreporter.exe');$reportChild.ProcessName='steamerrorreporter'
    $foreignService=Process 55 '' 0;$foreignService.Path=$null;$foreignService.ProcessName='SteamService'
    $probe.Processes=@($webChild,$reportChild,$foreignService);$probe.Answers=@('y')
    $state=@{Restart=$false};$beforeChildren=$probe.Killed.Count
    Stop-BapSteam $scratch $state
    Check 'inert child-only consent never creates a false client restart' (!$state.Restart -and $probe.Killed.Count -eq $beforeChildren+2 -and 55 -notin $probe.Killed)
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
