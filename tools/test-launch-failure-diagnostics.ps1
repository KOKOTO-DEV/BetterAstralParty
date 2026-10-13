param([Parameter(Mandatory)][string]$InspectorPath,[Parameter(Mandatory)][string]$InspectorSha256)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$base=Split-Path -Parent $PSScriptRoot
$inspector=[IO.Path]::GetFullPath($InspectorPath)
if($InspectorSha256 -cnotmatch '\A[A-F0-9]{64}\z'){throw 'Exact approved inspector SHA-256 required'}
$pin=[IO.File]::Open($inspector,'Open','Read','Read')
$scratch=Join-Path ([IO.Path]::GetTempPath()) ('bap-launch-diagnostics-'+[guid]::NewGuid().ToString('N'))
$savedLog=$null;$savedLogHash=$null;$link=$null
$checks=[Collections.Generic.List[string]]::new()
function Check([bool]$Value,[string]$Name){if(!$Value){throw ('FAIL: '+$Name)};$checks.Add($Name)}
function Put([string]$Path,[string]$Text){$null=[IO.Directory]::CreateDirectory((Split-Path -Parent $Path));[IO.File]::WriteAllText($Path,$Text)}
function Inspect($Bundle){
    $zip=[IO.Compression.ZipFile]::OpenRead($Bundle.ArchivePath)
    try{
        $all='';$inventory=$null;$summary=$null
        foreach($entry in $zip.Entries){$reader=[IO.StreamReader]::new($entry.Open());try{$text=$reader.ReadToEnd()}finally{$reader.Dispose()};$all+=$text;if($entry.FullName -eq 'recovery-inventory.json'){$inventory=$text|ConvertFrom-Json};if($entry.FullName -eq 'summary.json'){$summary=$text|ConvertFrom-Json}}
        return @{All=$all;Inventory=$inventory;Summary=$summary}
    }finally{$zip.Dispose()}
}
function Collect([string]$Game,[string]$Logs,[string]$Name){return [BetterAstralParty.Diagnostics.DiagnosticBundle]::Collect($Game,$Logs,'','',(Join-Path $scratch ($Name+'/hub')),(Join-Path $scratch ($Name+'/hub2')),$PSVersionTable.PSVersion.ToString())}
try {
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$actual=[BitConverter]::ToString($sha.ComputeHash($pin)).Replace('-','')}finally{$sha.Dispose()}
    if($actual -cne $InspectorSha256){throw 'Inspector changed or was not approved'}
    $pin.Position=0;$bytes=[byte[]]::new([int]$pin.Length);$used=0
    while($used -lt $bytes.Length){$n=$pin.Read($bytes,$used,$bytes.Length-$used);if(!$n){throw 'Short inspector snapshot'};$used+=$n}
    $type=[Reflection.Assembly]::Load($bytes).GetType('SteamLauncher')
    $nativeFailure=$type.GetMethod('LaunchFailure',[Reflection.BindingFlags]'Static,NonPublic')
    if(!$nativeFailure){throw 'Native launch failure formatter missing'}
    $capture=$type.GetMethod('CaptureLaunchContext',[Reflection.BindingFlags]'Static,NonPublic')
    $save=$type.GetMethod('SaveFailure',[Reflection.BindingFlags]'Static,NonPublic')
    if(!$capture -or !$save -or $capture.ReturnType -ne [string] -or $save.GetParameters().Count -ne 1){throw 'Current launch diagnostic APIs required'}
    Check ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'SteamLauncher.cs')).Contains('SaveFailure(CaptureLaunchContext(root) + error.ToString())')) 'current parent catch records launch context'
    $sources=@((Join-Path $base 'diagnostics/DiagnosticBundle.cs'),(Join-Path $base 'diagnostics/MinimalDiagnosticProjection.cs'))
    if($PSVersionTable.PSVersion.Major -lt 6){Add-Type -Path $sources -ReferencedAssemblies 'System.dll','System.Core.dll','System.IO.Compression.dll','System.IO.Compression.FileSystem.dll'}else{Add-Type -Path $sources}
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $null=[IO.Directory]::CreateDirectory($scratch)
    $game=Join-Path $scratch 'game';$null=[IO.Directory]::CreateDirectory($game)
    foreach($name in @('AstralParty_INT.exe','BetterAstralParty-Steam.ps1','check-compatibility.ps1','BetterAstralParty-Launcher.exe')){Put (Join-Path $game $name) 'inert fixture; never executed'}
    $context=[string]$capture.Invoke($null,@([string]$game))
    Check ($context.Contains('LaunchRoot: source=LauncherDirectory; state=Directory; hresult=0x00000000')) 'actual Framework inspector observes supplied root'
    Check ([regex]::Matches($context,'state=File; hresult=0x00000000').Count -eq 4) 'actual Framework inspector observes four fixed files'
    [IO.File]::Delete((Join-Path $game 'AstralParty_INT.exe'))
    $context=[string]$capture.Invoke($null,@([string]$game))
    Check ($context.Contains('kind=GameExecutable; state=Missing; hresult=0x80070002')) 'missing game file is observed, not guessed denied'
    [IO.File]::Delete((Join-Path $game 'BetterAstralParty-Steam.ps1'))
    $null=[IO.Directory]::CreateDirectory((Join-Path $game 'BetterAstralParty-Steam.ps1'))
    $context=[string]$capture.Invoke($null,@([string]$game))
    Check ($context.Contains('kind=EntryScript; state=Directory; hresult=0x00000000')) 'wrong entry type is distinct from missing'
    [IO.Directory]::Delete((Join-Path $game 'BetterAstralParty-Steam.ps1'))
    $target=Join-Path $scratch 'linked-target';$null=[IO.Directory]::CreateDirectory($target)
    $link=Join-Path $game 'BetterAstralParty-Steam.ps1'
    $null=New-Item -ItemType Junction -Path $link -Target $target
    $context=[string]$capture.Invoke($null,@([string]$game))
    Check ($context.Contains('kind=EntryScript; state=Linked; hresult=0x00000000')) 'linked entry is reported without following or executing it'
    [IO.Directory]::Delete($link);$link=$null
    Put (Join-Path $game 'BetterAstralParty-Steam.ps1') 'inert fixture'
    $stale=Join-Path $scratch 'stale-root';$null=[IO.Directory]::CreateDirectory($stale)
    $staleContext=[string]$capture.Invoke($null,@([string]$stale))
    Check ([regex]::Matches($staleContext,'LaunchFile:').Count -eq 4 -and [regex]::Matches($staleContext,'state=Missing;').Count -eq 4) 'stale supplied root has four missing observations, no inferred cause'
    $absentContext=[string]$capture.Invoke($null,@([string](Join-Path $scratch 'absent')))
    Check ($absentContext.Contains('LaunchRoot: source=LauncherDirectory; state=Missing;')) 'nonexistent supplied root remains observable'
    $invalidContext=[string]$capture.Invoke($null,@([string][char]0))
    Check ($invalidContext.Contains('state=Invalid;')) 'invalid root does not replace original failure'

    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'BetterAstralParty-Steam.ps1'),[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'Current entry script parse failed'}
    $tries=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.TryStatementAst] -and $n.CatchClauses.Count -eq 1},$false))
    $catch=@($tries|Where-Object {$_.CatchClauses[0].Body.Extent.Text.Contains('LaunchFailure: schema=1;')})
    if($catch.Count -ne 1){throw 'Expected one current launch failure catch'}
    $body=$catch[0].CatchClauses[0].Body.Extent.Text
    $exits=@($catch[0].CatchClauses[0].Body.FindAll({param($n)$n -is [Management.Automation.Language.ExitStatementAst]},$false))
    if($exits.Count -ne 1 -or $exits[0].Extent.Text -ne 'exit 1'){throw 'Unexpected catch exit contract'}
    # Only the real catch is executed, minus its terminal exit; no Main/Run/Steam/game/checker body is invoked.
    $catchOnly=[scriptblock]::Create($body.Substring(1,$body.Length-2).Replace($exits[0].Extent.Text,''))
    $phases=''
    foreach($launchStage in @('SteamContext','LauncherSnapshot','UpdateGate','Compatibility','SharedLoader','GameStart','GameExit')){
        $writer=[IO.StringWriter]::new();$priorError=[Console]::Error
        try{[Console]::SetError($writer);try{throw [IO.FileNotFoundException]::new('Inert missing file')}catch{. $catchOnly}}finally{[Console]::SetError($priorError)}
        $text=$writer.ToString();$writer.Dispose()
        Check ($text.Contains('LaunchFailure: schema=1; phase='+$launchStage+'; errorType=System.IO.FileNotFoundException; hresult=0x80070002')) ('current entry catch phase: '+$launchStage)
        $phases+=$text
    }
    foreach($phase in @('SteamContext','UpdateGate','Compatibility','SharedLoader','GameStart','GameExit')){
        $text=[string]$nativeFailure.Invoke($null,@($phase,[IO.FileNotFoundException]::new('Inert missing file')))
        Check ($text.Contains('LaunchFailure: schema=1; phase='+$phase+'; errorType=System.IO.FileNotFoundException; hresult=0x80070002')) ('native failure phase: '+$phase)
        $phases+=$text
    }
    $context=[string]$capture.Invoke($null,@([string]$game))
    $profile=[Environment]::GetFolderPath('UserProfile')
    $savedLog=[string]$save.Invoke($null,@($context+$phases+"`r`nFixture profile: "+$profile))
    if(!$savedLog -or (Split-Path -Leaf $savedLog) -cnotmatch '\ALaunch-[a-f0-9]{32}\.log\z'){throw 'Unexpected new fixture log path'}
    $savedLogHash=(Get-FileHash -LiteralPath $savedLog -Algorithm SHA256).Hash
    $localText=[IO.File]::ReadAllText($savedLog)
    Check ($localText.Contains('BAP-LAUNCH-FAILED') -and $localText.Contains('LaunchFile: kind=GameExecutable; state=Missing;') -and (!$profile -or !$localText.Contains($profile))) 'actual SaveFailure writes typed context and masks profile'
    $logs=Join-Path $scratch 'logs';$null=[IO.Directory]::CreateDirectory($logs)
    [IO.File]::Copy($savedLog,(Join-Path $logs (Split-Path -Leaf $savedLog)))
    $i=Inspect (Collect $game $logs 'written')
    Check ($i.All.Contains('kind=GameExecutable; state=Missing;') -and $i.All.Contains('phase=GameStart; errorType=System.IO.FileNotFoundException; hresult=0x80070002')) 'actual inspector SaveFailure and current entry catch reach current ZIP'
    Check (!$i.All.Contains($scratch) -and (!$profile -or !$i.All.Contains($profile))) 'ZIP masks original source paths'
    Put (Join-Path $logs ('Launch-'+('b'*32)+'.log')) "BAP-LAUNCH-FAILED`r`nLaunchFile: kind=GameExecutable; state=Missing; hresult=0x80070002; token=FAKE_PRIVATE_SECRET`r`nLaunchFailure: schema=1; phase=GuessedDefenderCause; errorType=Unknown; hresult=0x00000000`r`n"
    $i=Inspect (Collect $game $logs 'malformed')
    Check (!$i.All.Contains('FAKE_PRIVATE_SECRET') -and !$i.All.Contains('GuessedDefenderCause') -and $i.All.Contains('invalid-failure-context')) 'unknown typed fields and invented causes omitted'
    $noLauncher=Join-Path $scratch 'no-launcher-no-log';$null=[IO.Directory]::CreateDirectory($noLauncher)
    Put (Join-Path $noLauncher 'BetterAstralParty-Steam.ps1') 'inert';Put (Join-Path $noLauncher 'check-compatibility.ps1') 'inert'
    $empty=Join-Path $scratch 'empty-logs';$null=[IO.Directory]::CreateDirectory($empty)
    $i=Inspect (Collect $noLauncher $empty 'no-launch-log')
    Check ($i.Inventory.observedAt -ceq 'collection-time' -and !$i.Inventory.historyReconstructed -and @($i.Inventory.expectedLaunchFiles).Count -eq 4) 'missing launcher uses bounded collection snapshot, not reconstructed history'
    foreach($name in @('AstralParty_INT.exe','BetterAstralParty-Launcher.exe')){
        $file=@($i.Inventory.files|Where-Object {$_.source -ceq ('game/'+$name)})
        Check ($file.Count -eq 1 -and $file[0].present -ceq $false -and $file[0].status -ceq 'missing' -and $file[0].hresult -cmatch '\A0x[A-F0-9]{8}\z') ('collection-only missing file: '+$name)
    }
    Check (!$i.Summary.environment.gameRootValidated -and $i.All.Contains('no-matching-files')) 'missing game markers and absent launch history remain explicit'
    Write-Host ('PASS: current launch diagnostics '+$checks.Count+' assertions; PowerShell '+$PSVersionTable.PSVersion+'; inspector '+$InspectorSha256+'; no Main/Run/game/Steam/process start.')
} finally {
    if($savedLog){
        $savedParent=[IO.Path]::GetFullPath((Split-Path -Parent $savedLog))
        $allowed=@([IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'BetterAstralParty/Logs')),[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) 'BetterAstralParty')))
        if($savedParent -notin $allowed -or (Split-Path -Leaf $savedLog) -cnotmatch '\ALaunch-[a-f0-9]{32}\.log\z'){throw 'Unsafe generated log cleanup'}
        if(Test-Path -LiteralPath $savedLog){if(!$savedLogHash -or (Get-FileHash -LiteralPath $savedLog -Algorithm SHA256).Hash -cne $savedLogHash){throw 'Generated fixture log changed; preserved'};Remove-Item -LiteralPath $savedLog}
    }
    $pin.Dispose()
    if($link -and (Test-Path -LiteralPath $link)){[IO.Directory]::Delete($link)}
    $resolved=[IO.Path]::GetFullPath($scratch)
    if((Split-Path -Parent $resolved) -ne [IO.Path]::GetTempPath().TrimEnd('\') -or (Split-Path -Leaf $resolved) -notlike 'bap-launch-diagnostics-*'){throw 'Unsafe fixture cleanup'}
    if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
