param([string]$Scratch='')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$base=Split-Path -Parent $PSScriptRoot
. (Join-Path $base 'tools/install-log.ps1')
$sources=@((Join-Path $base 'diagnostics/DiagnosticBundle.cs'),(Join-Path $base 'diagnostics/MinimalDiagnosticProjection.cs'))
if($PSVersionTable.PSVersion.Major -lt 6){Add-Type -Path $sources -ReferencedAssemblies 'System.dll','System.Core.dll','System.IO.Compression.dll','System.IO.Compression.FileSystem.dll'}else{Add-Type -Path $sources}
Add-Type -AssemblyName System.IO.Compression.FileSystem
if(!$Scratch){$Scratch=Join-Path $base ('artifacts/failure-context-'+[guid]::NewGuid().ToString('N'))}
if(Test-Path -LiteralPath $Scratch){throw 'Fresh isolated output required'}
$null=[IO.Directory]::CreateDirectory($Scratch)
$cases=[Collections.Generic.List[string]]::new()
function Check([bool]$Value,[string]$Name){if(!$Value){throw ('FAIL: '+$Name)};$cases.Add($Name)}
function Root([string]$Name){$r=Join-Path $Scratch $Name;$null=[IO.Directory]::CreateDirectory($r);return $r}
function Collect([string]$Root,[string]$GameRoot=''){return [BetterAstralParty.Diagnostics.DiagnosticBundle]::Collect($GameRoot,$Root,'','',(Join-Path $Root 'hub'),(Join-Path $Root 'hub2'),'7.0')}
function Inspect($Bundle){
    $zip=[IO.Compression.ZipFile]::OpenRead($Bundle.ArchivePath)
    try{
        $all='';$summary=$null
        foreach($entry in $zip.Entries){$reader=[IO.StreamReader]::new($entry.Open());try{$text=$reader.ReadToEnd()}finally{$reader.Dispose()};$all+=$text;if($entry.FullName -eq 'summary.json'){$summary=$text|ConvertFrom-Json}}
        return @{all=$all;summary=$summary}
    }finally{$zip.Dispose()}
}
function Record($Context,[int]$Depth=1,[string]$Message='Inert ownership refusal'){
    $ex=[InvalidOperationException]::new($Message)
    if($null -ne $Context){$ex.Data['BapSteamDiagnostic']=$Context}
    $ex.Data['BapInstallStage']='Steam shortcut planning'
    for($n=1;$n -lt $Depth;$n++){$ex=[InvalidOperationException]::new('Wrapper failure',$ex)}
    return [Management.Automation.ErrorRecord]::new($ex,'InertFixture',[Management.Automation.ErrorCategory]::InvalidOperation,$null)
}
function Capture-ProductionFailure {
    function Get-Process { [pscustomobject]@{ProcessName='steam';Id=4321;SessionId=[Diagnostics.Process]::GetCurrentProcess().SessionId;Path=$null;StartTime=[DateTime]::UtcNow;HasExited=$false} }
    try { Assert-BapSteamStopped 'C:\inert-steam-fixture' 'InstallPreflight'; throw 'Expected production Steam refusal' }
    catch { return $_ }
}
$prior=@{LOCALAPPDATA=$env:LOCALAPPDATA;BAP_INSTALL_RUN=$env:BAP_INSTALL_RUN;BAP_INSTALL_VERSION=$env:BAP_INSTALL_VERSION}
try{
    $env:BAP_INSTALL_RUN='12345678123412341234123456789abc';$env:BAP_INSTALL_VERSION='1.1.4'
    $ctx=[ordered]@{schema=1;reason='SteamOwnershipUnknown';phase='ShutdownObservation';utc='2026-10-11T19:00:00.0000000Z';observedCount=2;omittedCount=0;processes=@(
        [ordered]@{pid=12345;sessionMatch=$true;pathAvailable=$false;pathMatch=$null;startAvailable=$false;startedUtc=$null},
        [ordered]@{pid=12346;sessionMatch=$false;pathAvailable=$true;pathMatch=$false;startAvailable=$true;startedUtc='2026-10-11T18:00:00.0000000Z'}
    )}
    $root=Root 'valid';$env:LOCALAPPDATA=$root;$failure=Record ($ctx|ConvertTo-Json -Depth 5 -Compress) 3
    $log=Write-InstallFailure $failure 'Bootstrap' 'fixture-package' 'fixture-game'
    $text=[IO.File]::ReadAllText($log)
    Check ($text.Contains('Stage: Steam shortcut planning') -and $text.Contains('SteamDiagnostic: schema=1; reason=SteamOwnershipUnknown')) 'nested original stage and Steam reason recorded at failure time'
    Check ($text.Contains('sessionMatch=true; pathAvailable=false; pathMatch=unknown; startAvailable=false; startedUtc=unknown') -and $text.Contains('startedUtc=2026-10-11T18:00:00.0000000Z')) 'unknown process facts distinct from false and observed time'
    Check ($text.Contains('exceptionDepth=3; exceptionChainOmitted=false; textTruncated=false; steamContext=included')) 'source records diagnostic coverage'
    $logs=Split-Path -Parent $log
    $null=Write-InstallFailure $failure 'Outer' 'fixture-package' 'fixture-game'
    [IO.File]::WriteAllText((Join-Path $logs ('Bootstrap-'+$env:BAP_INSTALL_RUN+'.log')),('BAP-BOOTSTRAP-FAILED'+[Environment]::NewLine+'Run: '+$env:BAP_INSTALL_RUN+[Environment]::NewLine))
    $game=Join-Path $root 'g';$events=Join-Path $game 'BepInEx/BetterAstralParty-Diagnostics/minimal-v1/installer'
    $null=[IO.Directory]::CreateDirectory($events)
    $minimal=[ordered]@{schema='bap.minimal-diagnostic/v1';process_session=('9'*32);sequence=1;utc=[DateTimeOffset]::UtcNow.ToString('O');elapsed_ms=0;mod_version='1.1.4';build_id='unknown';runtime_version='6.0';kind='Stage';feature='Installer';phase='Configuration';outcome='Failed';code='Prerequisite';ui_action='Unknown';error_site='None';error_type='None';operation=$env:BAP_INSTALL_RUN;related_operation='-';target_version='unknown';update_state='Unknown';count=0;secondary_count=0;native_code=0;validation_code=0;apply_code=0}
    [IO.File]::WriteAllText((Join-Path $events 'events-current.jsonl'),(($minimal|ConvertTo-Json -Compress)+[Environment]::NewLine))
    $bundle=Collect $logs $game;$i=Inspect $bundle
    Check ($i.all.Contains('SteamOwnershipUnknown') -and $i.all.Contains('pid=12345') -and $i.all.Contains('pathMatch=unknown') -and $i.all.Contains('exceptionDepth=3')) 'production failure writer to actual ZIP preserves bounded process decision facts'
    Check (!$i.all.Contains($env:BAP_INSTALL_RUN) -and !$i.all.Contains($Scratch)) 'raw operation and absolute sources omitted'
    $aliases=@($i.summary.files|Where-Object {$_.status -eq 'included'}|ForEach-Object {$_.operationAliases}|Select-Object -Unique)
    Check ($aliases.Count -eq 1 -and $aliases[0] -match '^[0-9a-f]{32}$') 'duplicate installer and bootstrap errors share one ZIP-local operation alias'
    Check ($i.all.Contains('"operation":"'+$aliases[0]+'"')) 'failure Run alias matches minimal-v1 installer operation alias'
    Check (@($i.summary.files|Where-Object {$_.sourceKind -eq 'bootstrap-error'}).Count -eq 1 -and @($i.summary.files|Where-Object {$_.sourceKind -eq 'installer-uninstaller-error'}).Count -eq 2) 'fixed source provenance survives redaction'
    $i2=Inspect (Collect $logs);$aliases2=@($i2.summary.files|Where-Object {$_.status -eq 'included'}|ForEach-Object {$_.operationAliases}|Select-Object -Unique)
    Check ($aliases2[0] -ne $aliases[0]) 'new ZIP never reuses aliases'

    foreach($kind in @('unknown-field','invalid-time','wrong-type','oversize')){
        $root=Root $kind;$env:LOCALAPPDATA=$root
        $value=if($kind -eq 'oversize'){'FAKE_PRIVATE_SECRET'+('x'*16384)}else{$ctx|ConvertTo-Json -Depth 5 -Compress}
        if($kind -eq 'unknown-field'){$value=$value.Replace('"schema":1','"token":"FAKE_PRIVATE_SECRET","schema":1')}
        if($kind -eq 'invalid-time'){$value=$value.Replace('2026-10-11T19:00:00.0000000Z','2026-99-99T19:00:00.0000000Z')}
        if($kind -eq 'wrong-type'){$value=$value.Replace('"pathAvailable":false','"pathAvailable":"FAKE_PRIVATE_SECRET"')}
        $log=Write-InstallFailure (Record $value) 'Fixture' 'fixture-package' ''
        $raw=[IO.File]::ReadAllText($log);$i=Inspect (Collect (Split-Path -Parent $log))
        Check (!$raw.Contains('FAKE_PRIVATE') -and !$i.all.Contains('FAKE_PRIVATE') -and $i.all.Contains('steamContext='+$(if($kind -eq 'oversize'){'context-limit'}else{'invalid-context'}))) ('invalid context omitted and fixed reason exported: '+$kind)
    }
    $root=Root 'chain-limit';$env:LOCALAPPDATA=$root
    $log=Write-InstallFailure (Record ($ctx|ConvertTo-Json -Depth 5 -Compress) 10 ('x'*20000)) 'Fixture' 'fixture-package' ''
    $i=Inspect (Collect (Split-Path -Parent $log))
    Check ($i.all.Contains('exceptionDepth=8; exceptionChainOmitted=true') -and !$i.all.Contains('SteamDiagnostic:')) 'exception chain limit reported without reconstructing unobserved context'
    $log=Write-InstallFailure (Record $null 1 ('x'*20000)) 'Fixture' 'fixture-package' ''
    $text=[IO.File]::ReadAllText($log)
    Check ($text.Length -lt 40000 -and $text.Contains('textTruncated=true')) 'huge exception fields bounded and truncation explicit'

    $root=Root 'forged';$name=Join-Path $root 'BetterAstralParty-InstallError-20261012-010000-1234abcd.log'
    [IO.File]::WriteAllText($name,('SteamDiagnostic: schema=1; token=FAKE_PRIVATE_SECRET'+[Environment]::NewLine+' FAKE_PRIVATE_CONTINUATION'+[Environment]::NewLine+'Code: BAP-INSTALL-FAILED'+[Environment]::NewLine))
    $i=Inspect (Collect $root)
    Check (!$i.all.Contains('FAKE_PRIVATE') -and @($i.summary.files|Where-Object {$_.projectionRejections.PSObject.Properties['invalid-failure-context']}).Count -eq 1) 'forged fixed-context line and continuation omitted with counted reason'
    $root=Root 'secret';$name=Join-Path $root 'BetterAstralParty-InstallError-20261012-010000-1234abcd.log'
    [IO.File]::WriteAllText($name,('-----BEGIN PRIVATE KEY-----'+[Environment]::NewLine+'SteamDiagnostic: schema=1; token=FAKE_PRIVATE_SECRET'+[Environment]::NewLine+'-----END PRIVATE KEY-----'+[Environment]::NewLine+'Code: BAP-INSTALL-FAILED'+[Environment]::NewLine))
    $i=Inspect (Collect $root);Check (!$i.all.Contains('FAKE_PRIVATE') -and $i.all.Contains('BAP-INSTALL-FAILED')) 'private key block cannot inject context'
    . (Join-Path $base 'tools/steam-shortcut.ps1') -SteamRoot '' -GameRoot ''
    $root=Root 'production-throw';$env:LOCALAPPDATA=$root;$failure=Capture-ProductionFailure
    Check ($failure.Exception.Data.Contains('BapSteamDiagnostic')) 'actual production ownership guard attaches cause observations'
    $log=Write-InstallFailure $failure 'Steam shortcut planning' 'fixture-package' ''
    $i=Inspect (Collect (Split-Path -Parent $log))
    Check ($i.all.Contains('reason=SteamOwnershipUnknown; phase=InstallPreflight') -and $i.all.Contains('pid=4321; sessionMatch=true; pathAvailable=false; pathMatch=unknown; startAvailable=true') -and $i.all.Contains('steamContext=included')) 'actual production throw to logger to ZIP keeps unknown ownership decision without real Steam'
    $null=Write-InstallFailure $null 'Fixture' '' ''
    Check ($true) 'logger construction failure does not throw over original failure'
}finally{foreach($name in $prior.Keys){[Environment]::SetEnvironmentVariable($name,$prior[$name],'Process')}}
$report=[ordered]@{runtime=$PSVersionTable.PSVersion.ToString();passed=$cases.Count;cases=@($cases);scratch=$Scratch;sourceHashes=@($sources+(Join-Path $base 'tools/install-log.ps1')|ForEach-Object {[ordered]@{file=[IO.Path]::GetFileName($_);sha256=(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash}});realLogsRead=$false;processesStopped=$false;installationPerformed=$false;upload=$false}
$report|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $Scratch 'test-results.json') -Encoding UTF8
$report|ConvertTo-Json -Depth 6
