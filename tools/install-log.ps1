function Convert-BapSteamFailureDiagnostic([string]$Value) {
    if ([Text.Encoding]::UTF8.GetByteCount($Value) -gt 16384) { throw 'context-limit' }
    $jsonOptions=@{ErrorAction='Stop'}
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $jsonOptions.DateKind='String' }
    $data = $Value | ConvertFrom-Json @jsonOptions
    $keys = @('schema','reason','phase','utc','observedCount','omittedCount','processes')
    if (@($data.PSObject.Properties).Count -ne $keys.Count -or @($data.PSObject.Properties.Name | Where-Object { $_ -cnotin $keys }).Count) { throw 'context-fields' }
    $reasons = @('ProcessObservationUnavailable','SteamOwnershipUnknown','SteamOtherSession','SteamRunning','ProcessListChanged','ProcessIdentityChanged','ProcessTerminationFailed','ConsentCancelled','ConsentUnavailable')
    $phases = @('ShutdownObservation','ShutdownConsent','ShutdownRecheck','ProcessIdentity','ProcessTermination','ShutdownCompletion','InstallPreflight','UninstallPreflight','ShortcutPreflight','ShortcutCommit','ShortcutRollback','Resume')
    foreach ($key in @('schema','observedCount','omittedCount')) {
        if (($data.$key -isnot [int] -and $data.$key -isnot [long]) -or $data.$key -lt 0 -or $data.$key -gt [int]::MaxValue) { throw 'context-number' }
    }
    if ($data.schema -ne 1 -or $data.reason -cnotin $reasons -or $data.phase -cnotin $phases -or
        $data.utc -isnot [string] -or $data.utc -cnotmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}Z$') { throw 'context-header' }
    $null = [DateTime]::ParseExact($data.utc, 'o', [Globalization.CultureInfo]::InvariantCulture)
    if ($data.processes -isnot [array] -or $data.processes.Count -gt 48 -or $data.observedCount -ne $data.processes.Count + $data.omittedCount) { throw 'context-process-limit' }
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add(('SteamDiagnostic: schema=1; reason={0}; phase={1}; utc={2}; observedCount={3}; omittedCount={4}' -f $data.reason,$data.phase,$data.utc,$data.observedCount,$data.omittedCount))
    $index=0
    foreach ($process in $data.processes) {
        $keys = @('pid','sessionMatch','pathAvailable','pathMatch','startAvailable','startedUtc')
        if (@($process.PSObject.Properties).Count -ne $keys.Count -or @($process.PSObject.Properties.Name | Where-Object { $_ -cnotin $keys }).Count -or
            ($process.pid -isnot [int] -and $process.pid -isnot [long]) -or $process.pid -le 0 -or $process.pid -gt [int]::MaxValue) { throw 'context-process-fields' }
        foreach ($key in @('pathAvailable','startAvailable')) { if ($process.$key -isnot [bool]) { throw 'context-process-bool' } }
        foreach ($key in @('sessionMatch','pathMatch')) { if ($null -ne $process.$key -and $process.$key -isnot [bool]) { throw 'context-process-nullable-bool' } }
        if ($process.startAvailable) {
            if ($process.startedUtc -isnot [string] -or $process.startedUtc -cnotmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}Z$') { throw 'context-process-time' }
            $null = [DateTime]::ParseExact($process.startedUtc, 'o', [Globalization.CultureInfo]::InvariantCulture)
        } elseif ($null -ne $process.startedUtc) { throw 'context-process-time-unavailable' }
        $session=if($null -eq $process.sessionMatch){'unknown'}else{$process.sessionMatch.ToString().ToLowerInvariant()}
        $path=if($null -eq $process.pathMatch){'unknown'}else{$process.pathMatch.ToString().ToLowerInvariant()}
        $start=if($null -eq $process.startedUtc){'unknown'}else{$process.startedUtc}
        $lines.Add(('SteamProcess: index={0}; pid={1}; sessionMatch={2}; pathAvailable={3}; pathMatch={4}; startAvailable={5}; startedUtc={6}' -f (++$index),$process.pid,$session,$process.pathAvailable.ToString().ToLowerInvariant(),$path,$process.startAvailable.ToString().ToLowerInvariant(),$start))
    }
    return $lines.ToArray()
}

function Write-InstallFailure($Failure, [string]$Stage, [string]$PackageRoot, [string]$GameRoot, [string]$Operation = 'Installation') {
    # No transcript, registry dump, Steam account ID or environment dump.
    try {
    $chain=[Collections.Generic.List[Exception]]::new(); $current=$Failure.Exception; $steam=$null
    while ($current -and $chain.Count -lt 8) {
        $chain.Add($current)
        $originStage=$current.Data['BapInstallStage']
        if ($originStage -is [string] -and $originStage.Length -le 160 -and $originStage -notmatch '[\r\n]') { $Stage=$originStage }
        if ($null -eq $steam -and $current.Data.Contains('BapSteamDiagnostic')) { $steam=$current.Data['BapSteamDiagnostic'] }
        $current=$current.InnerException
    }
    $run=if($env:BAP_INSTALL_RUN -cmatch '^[0-9a-f]{32}$'){$env:BAP_INSTALL_RUN}else{[guid]::NewGuid().ToString('N')}
    $version=if($env:BAP_INSTALL_VERSION -match '^[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}(?:-[A-Za-z0-9.-]{1,64})?$'){$env:BAP_INSTALL_VERSION}else{'unknown'}
    $details=[Collections.Generic.List[string]]::new(); $textTruncated=$false
    $bounded=@{}
    foreach($field in @{Message=[string]$Failure.Exception.Message; Stack=[string]$Failure.ScriptStackTrace; Package=[string]$PackageRoot; Game=[string]$GameRoot; Stage=[string]$Stage; ErrorId=[string]$Failure.FullyQualifiedErrorId}.GetEnumerator()) {
        $value=$field.Value
        if($value.Length -gt 8192){$value=$value.Substring(0,8192);$textTruncated=$true}
        $bounded[$field.Key]=$value
    }
    foreach ($part in @('Message','StackTrace')) {
        foreach($exception in $chain) {
            $value=[string]$exception.$part
            if($value.Length -gt 8192){$value=$value.Substring(0,8192);$textTruncated=$true}
            $details.Add(('Exception: depth={0}; type={1}; HResult={2}; {3}: {4}' -f $chain.IndexOf($exception),$exception.GetType().FullName,('0x{0:X8}' -f $exception.HResult),$part,$value))
        }
    }
    $steamStatus='not-observed'
    if ($null -ne $steam) {
        try {
            if ($steam -isnot [string]) { throw 'context-type' }
            $details.AddRange([string[]]@(Convert-BapSteamFailureDiagnostic $steam)); $steamStatus='included'
        } catch { $steamStatus=if($steam -is [string] -and [Text.Encoding]::UTF8.GetByteCount($steam) -gt 16384){'context-limit'}else{'invalid-context'} }
    }
    $location=if($Failure.InvocationInfo){[string]$Failure.InvocationInfo.ScriptName+':'+$Failure.InvocationInfo.ScriptLineNumber}else{'unknown'}
    if($location.Length -gt 8192){$location=$location.Substring(0,8192);$textTruncated=$true}
    $details.Add(('DiagnosticCoverage: exceptionDepth={0}; exceptionChainOmitted={1}; textTruncated={2}; steamContext={3}' -f $chain.Count,([bool]$current).ToString().ToLowerInvariant(),$textTruncated.ToString().ToLowerInvariant(),$steamStatus))
    $text = @(
        "BetterAstralParty $Operation failure"
        "Time: $([DateTimeOffset]::Now.ToString('o'))"
        "Run: $run"
        "Version: $version"
        'Code: BAP-INSTALL-FAILED'
        "Stage: $($bounded.Stage)"
        "PowerShell: $($PSVersionTable.PSVersion)"
        "Package: $($bounded.Package)"
        "Game: $($bounded.Game)"
        "ErrorType: $($Failure.Exception.GetType().FullName)"
        "HResult: $('0x{0:X8}' -f $Failure.Exception.HResult)"
        "ErrorId: $($bounded.ErrorId)"
        "Message: $($bounded.Message)"
        "Location: $location"
        "Stack: $($bounded.Stack)"
        ($details -join [Environment]::NewLine)
    ) -join [Environment]::NewLine
    if($text.Length -gt 196608){$text=$text.Substring(0,196608)+[Environment]::NewLine+'DiagnosticCoverage: log-text-limit'}
    $text += [Environment]::NewLine
    if ($env:USERPROFILE) {
        $text = [regex]::Replace($text, [regex]::Escape($env:USERPROFILE), '%USERPROFILE%', 'IgnoreCase')
        $text = [regex]::Replace($text, [regex]::Escape($env:USERPROFILE.Replace('\', '/')), '%USERPROFILE%', 'IgnoreCase')
    }
    $name = 'BetterAstralParty-InstallError-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.log'
    foreach ($directory in @((Join-Path $env:LOCALAPPDATA 'BetterAstralParty/Logs'), (Join-Path ([IO.Path]::GetTempPath()) 'BetterAstralParty'))) {
        try {
            New-Item -ItemType Directory -Force -Path $directory -ErrorAction Stop | Out-Null
            $path = Join-Path $directory $name
            [IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($true))
            Write-Host "$Operation failed. Debug log: $path"
            return $path
        } catch { } # Logging failure must never replace the original installation error.
    }
    Write-Host 'Could not save the installation log. Please capture the console error.'
    } catch { Write-Host 'Could not save the installation log. Please capture the console error.' }
}
