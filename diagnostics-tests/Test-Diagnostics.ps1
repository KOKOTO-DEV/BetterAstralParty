param([string]$Scratch = '')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [Text.Encoding]::UTF8
if (!$Scratch) { $Scratch = Join-Path ([IO.Path]::GetTempPath()) ('bap-diag-fixture-' + [guid]::NewGuid().ToString('N').Substring(0,8)) }
if (Test-Path -LiteralPath $Scratch) { throw 'Fixture must use a new directory' }
$null = [IO.Directory]::CreateDirectory($Scratch)
$source = Join-Path (Split-Path -Parent $PSScriptRoot) 'diagnostics/DiagnosticBundle.cs'
$projection=Join-Path (Split-Path -Parent $PSScriptRoot) 'diagnostics/MinimalDiagnosticProjection.cs'
if ($PSVersionTable.PSVersion.Major -lt 6) { Add-Type -Path @($source,$projection) -ReferencedAssemblies 'System.dll','System.Core.dll','System.IO.Compression.dll','System.IO.Compression.FileSystem.dll' }
else { Add-Type -Path @($source,$projection) }
Add-Type -AssemblyName System.IO.Compression.FileSystem
$script:Cases = [Collections.Generic.List[string]]::new()
function Assert([bool]$Ok,[string]$Name) { if (!$Ok) { throw "FAIL: $Name" }; $script:Cases.Add($Name) }
function Put([string]$Path,[string]$Text) { $null=[IO.Directory]::CreateDirectory((Split-Path -Parent $Path)); [IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false)) }
function Roots([string]$Name) {
    $root=Join-Path $Scratch $Name
    $g=Join-Path $root 'g'; Put (Join-Path $g 'AstralParty_INT.exe') 'inert fixture, never executed'
    $null=[IO.Directory]::CreateDirectory((Join-Path $g 'AstralParty_INT_Data'))
    foreach($n in @('local','fallback','unity')){$null=[IO.Directory]::CreateDirectory((Join-Path $root $n))}
    return @{game=$g;local=(Join-Path $root 'local');fallback=(Join-Path $root 'fallback');unity=(Join-Path $root 'unity');hub=(Join-Path $root 'hub');hub2=(Join-Path $root 'hub2')}
}
function Collect($r,[string]$GameOverride='') {
    $g=if($GameOverride){$GameOverride}else{$r.game}
    return [BetterAstralParty.Diagnostics.DiagnosticBundle]::Collect($g,$r.local,$r.fallback,$r.unity,$r.hub,$r.hub2,'7.0')
}
function Inspect($b) {
    $z=[IO.Compression.ZipFile]::OpenRead($b.ArchivePath)
    try {
        $all='';$names=@();$logs=0L;$summary=$null;$catalog=$null;$catalogText='';$recovery=$null;$recoveryText=''
        foreach($e in $z.Entries){
            $names+=$e.FullName
            $reader=[IO.StreamReader]::new($e.Open(),[Text.Encoding]::UTF8);try{$s=$reader.ReadToEnd()}finally{$reader.Dispose()}
            $all+=$s
            if($e.FullName -eq 'summary.json'){$summary=$s|ConvertFrom-Json}
            if($e.FullName -eq 'catalog-inventory.json'){$catalog=$s|ConvertFrom-Json;$catalogText=$s}
            if($e.FullName -eq 'recovery-inventory.json'){$recovery=$s|ConvertFrom-Json;$recoveryText=$s}
            if($e.FullName.StartsWith('logs/')){$logs+=$e.Length; if($e.Length -gt 524288){throw 'Per-file bound exceeded'}}
        }
        return @{all=$all;names=$names;summary=$summary;logBytes=$logs;catalog=$catalog;catalogText=$catalogText;recovery=$recovery;recoveryText=$recoveryText}
    } finally {$z.Dispose()}
}
$r=Roots 'privacy';$p=Join-Path $r.game 'BepInEx/BetterAstralParty-Diagnostics/current.log'
$fake=@'
2026-10-04T10:00:00Z | phase=3
Authorization: Bearer FAKE_BEARER_NEVER_VALID
  FAKE_CONTINUED_SECRET
2026-10-04T10:00:01Z | performance frames=42
access_token = FAKE_ACCESS_NEVER_VALID
2026-10-04T10:00:02Z | refresh_token = FAKE_REFRESH_NEVER_VALID
2026-10-04T10:00:03Z | Cookie: FAKE_COOKIE_NEVER_VALID
2026-10-04T10:00:04Z | signature = FAKE_SIGNATURE_NEVER_VALID
2026-10-04T10:00:05Z | client_secret = FAKE_CLIENT_SECRET_NEVER_VALID
2026-10-04T10:00:06Z | nickname=FAKE_NICKNAME
2026-10-04T10:00:07Z | userId=FAKE_ACCOUNT
2026-10-04T10:00:08Z | C:\Users\FAKE_PERSON\Some Folder\private.log
2026-10-04T10:00:09Z | https://fake.invalid/?access_token=FAKE_URL_SECRET
2026-10-04T10:00:10Z | fake_person@example.invalid 192.0.2.23 76561198000000000
2026-10-04T10:00:11Z | 12345678-1234-1234-1234-123456789abc
-----BEGIN PRIVATE KEY-----
FAKE_KEY_MATERIAL
2026-10-04T10:00:12Z | FAKE_KEY_CONTINUATION
-----END PRIVATE KEY-----
2026-10-04T10:00:13Z | fightStep=9
'@
Put $p ($fake+"`n"); $before=(Get-FileHash -LiteralPath $p).Hash
Put (Join-Path $r.game 'BepInEx/config/kr.betterastralparty.mod.cfg') 'FORBIDDEN_CONFIGURATION'
Put (Join-Path $r.game 'crash.dmp') 'FORBIDDEN_MEMORY'
Put (Join-Path $r.local 'credential-store.json') 'FORBIDDEN_CREDENTIAL_STORE'
Put (Join-Path $r.local 'arbitrary.log') 'FORBIDDEN_ARBITRARY_LOG'
Put (Join-Path $r.local ('Launch-'+('a'*32)+'.log')) "BAP-LAUNCH-FAILED`npassword=FAKE_PASSWORD`n"
Put (Join-Path $r.unity 'Player.log') "[Info : Unity] Startup fixture`nusername=FAKE_USERNAME"
$b=Collect $r; $i=Inspect $b
Assert ($b.Included -eq 2 -and @($i.summary.files|Where-Object {$_.source -eq 'unity/player' -and $_.status -eq 'metadata-only'}).Count -eq 1) 'mod/launcher projected; Unity content metadata only'
foreach($marker in @('FAKE_BEARER','FAKE_CONTINUED','FAKE_ACCESS','FAKE_REFRESH','FAKE_COOKIE','FAKE_SIGNATURE','FAKE_CLIENT_SECRET','FAKE_NICKNAME','FAKE_ACCOUNT','FAKE_PERSON','FAKE_URL_SECRET','fake_person@','192.0.2.23','76561198000000000','12345678-1234-1234-1234-123456789abc','FAKE_KEY','FAKE_PASSWORD','FAKE_USERNAME','FORBIDDEN_')){Assert (!$i.all.Contains($marker)) ('no export: '+$marker)}
Assert ($i.all.Contains('public-phase; phase=3') -and $i.all.Contains('fightStep=9')) 'useful allowed public state survives'
Assert ($i.summary.environment.hostVersion -eq '7.0' -and $i.summary.environment.gameRootValidated) 'safe environment summary'
Assert (!$i.all.Contains($Scratch) -and !$i.all.Contains($r.game)) 'no source absolute paths in ZIP'
Assert (@($i.summary.missingOrOmitted).Count -gt 0) 'missing sources explained'
Assert (@($i.names | Where-Object {$_ -match '\.\.|:|^/|\\'}).Count -eq 0) 'ZIP names contain no path traversal'
Assert ((Get-FileHash -LiteralPath $p).Hash -eq $before) 'source log hash preserved'
Assert (@(Get-ChildItem -LiteralPath $r.hub -Filter '*.partial').Count -eq 0) 'committed ZIP leaves no raw or partial file'
$b2=Collect $r; Assert ($b2.ArchivePath -ne $b.ArchivePath -and (Test-Path -LiteralPath $b.ArchivePath)) 'new archive never overwrites old archive'
Assert (@(Get-ChildItem -LiteralPath $r.hub -Filter '*.partial').Count -eq 0) 'existing guide failure cleans up partial by handle'
$fenceType=[BetterAstralParty.Diagnostics.DiagnosticBundle].GetNestedType('Fence',[Reflection.BindingFlags]'NonPublic')
$constructor=$fenceType.GetConstructors([Reflection.BindingFlags]'Instance,NonPublic')[0]
$args1=[object[]]::new(1);$args1[0]=[string]$r.game
$fence=$constructor.Invoke($args1)
$args3=[object[]]::new(3);$args3[0]='BepInEx/BetterAstralParty-Diagnostics/current.log';$args3[1]=$false;$args3[2]=$false
$held=$fenceType.GetMethod('Open',[Reflection.BindingFlags]'Instance,NonPublic').Invoke($fence,$args3)
try {
    Move-Item -LiteralPath $p -Destination ($p+'.rotation')
    Assert (Test-Path -LiteralPath ($p+'.rotation')) 'source handle permits file rename rotation without stopping writer'
    $from=[IO.Path]::GetFullPath((Join-Path $r.game 'BepInEx'));$to=[IO.Path]::GetFullPath((Join-Path $r.game 'BepInEx.moved'))
    $boundary=[IO.Path]::GetFullPath($Scratch).TrimEnd('\')+'\'
    if(!$from.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -or !$to.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase)){throw 'Fixture move escaped scratch'}
    $blocked=$false;try{[IO.Directory]::Move($from,$to)}catch{$blocked=$true}
    Assert $blocked 'ancestor handle blocks directory identity replacement during source read'
}finally{$held.Dispose();$fence.Dispose()}
Move-Item -LiteralPath ($p+'.rotation') -Destination $p

$r=Roots 'locked';$p=Join-Path $r.game 'BepInEx/BetterAstralParty-Diagnostics/current.log';Put $p "phase=3`n"
$lock=[IO.File]::Open($p,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try {$i=Inspect (Collect $r);Assert (@($i.summary.files|Where-Object {$_.source -eq 'game/diagnostics-current' -and $_.status -eq 'locked-or-unreadable'}).Count -eq 1) 'exclusive lock recorded without failing archive'} finally {$lock.Dispose()}
$writer=[IO.File]::Open($p,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite)
try {$b=Collect $r;Assert ($b.Included -eq 1) 'shared running writer stays open during collection'} finally {$writer.Dispose()}
Move-Item -LiteralPath $p -Destination ($p+'.moved');Assert (Test-Path -LiteralPath ($p+'.moved')) 'collector releases every source handle'

$r=Roots 'times';$p=Join-Path $r.game 'BepInEx/BetterAstralParty-Diagnostics/current.log';Put $p 'safe old fixture';[IO.File]::SetLastWriteTimeUtc($p,[DateTime]::UtcNow.AddDays(-8))
$p2=Join-Path $r.game 'BepInEx/BetterAstralParty-Diagnostics/previous.log';Put $p2 'safe future fixture';[IO.File]::SetLastWriteTimeUtc($p2,[DateTime]::UtcNow.AddDays(2))
$i=Inspect (Collect $r);Assert ($i.all.Contains('older-than-7-days') -and $i.all.Contains('invalid-future-time') -and !$i.all.Contains('safe old fixture')) 'old and future logs skipped'

$r=Roots 'input-limit';$p=Join-Path $r.game 'BepInEx/BetterAstralParty-Diagnostics/current.log';Put $p ('x'*2097153)
$i=Inspect (Collect $r);Assert ($i.all.Contains('input-file-limit') -and !$i.all.Contains(('x'*100))) 'oversize file skipped instead of leaking tail fragments'
$p2=Join-Path $r.game 'BepInEx/BetterAstralParty-Diagnostics/previous.log';[IO.File]::WriteAllBytes($p2,[byte[]](0,255,254,0))
$i=Inspect (Collect $r);Assert ($i.all.Contains('invalid-text')) 'invalid binary log excluded'

$r=Roots 'output-limit';$p=Join-Path $r.game 'BepInEx/BetterAstralParty-Diagnostics/current.log';Put $p (('performance frames=5; ui_avg_ms=4'+"`n")*50000)
$i=Inspect (Collect $r);Assert ($i.logBytes -le 524288 -and @($i.summary.files|Where-Object {$_.truncated}).Count -eq 1) 'sanitized per-file bound and truncation flag'

$r=Roots 'long-line';Put (Join-Path $r.game 'BepInEx/BetterAstralParty-Diagnostics/current.log') (('L'*17000)+"`nFAKE_LONG_CONTINUATION`n2026-10-04T10:00:00Z | fightStep=5`n")
$i=Inspect (Collect $r);Assert (!$i.all.Contains('FAKE_LONG_CONTINUATION') -and $i.all.Contains('fightStep=5')) 'long line and continuation omitted with boundary recovery'

$r=Roots 'recent-count';for($n=0;$n -lt 12;$n++){Put (Join-Path $r.local ('Launch-'+$n.ToString('x32')+'.log')) "BAP-LAUNCH-FAILED`n"}
$b=Collect $r;$i=Inspect $b;Assert ($b.Included -eq 8 -and $i.all.Contains('recent-file-limit')) 'directory recent-count cap'

$r=Roots 'raw-budget';for($n=0;$n -lt 8;$n++){Put (Join-Path $r.local ('Launch-'+$n.ToString('x32')+'.log')) (('public sample n=5'+"`n")*65000)}
for($n=0;$n -lt 8;$n++){Put (Join-Path $r.fallback ('Launch-'+$n.ToString('x32')+'.log')) (('public sample n=5'+"`n")*65000)}
$b=Collect $r;$i=Inspect $b;Assert ($i.logBytes -le 4194304 -and $i.all.Contains('bundle-limit') -and $b.Included -lt 16) 'input/output total budgets bounded'

$r=Roots 'scan-bound';for($n=0;$n -lt 513;$n++){Put (Join-Path $r.local ($n.ToString('D4')+'.txt')) 'FAKE_EXCLUDED_SENTINEL'}
$i=Inspect (Collect $r);Assert ($i.all.Contains('directory-scan-limit') -and !$i.all.Contains('FAKE_EXCLUDED_SENTINEL')) 'bounded nonrecursive directory enumeration'

$r=Roots 'invalid-root';$i=Inspect (Collect $r ($r.game+'\..\g'));Assert (!$i.summary.environment.gameRootValidated -and $i.all.Contains('unsafe-or-unreadable')) 'parent traversal game root rejected'
$i=Inspect (Collect $r '\\fake.invalid\share\game');Assert (!$i.summary.environment.gameRootValidated) 'UNC and remote roots rejected without access'
$i=Inspect (Collect $r ($r.game+':stream'));Assert (!$i.summary.environment.gameRootValidated) 'alternate data stream root rejected'
$i=Inspect (Collect $r ($r.game+'.'));Assert (!$i.summary.environment.gameRootValidated) 'trailing-dot alias rejected'

$r=Roots 'hardlink';$outside=Join-Path $Scratch 'outside-synthetic.log';Put $outside 'FORBIDDEN_OUTSIDE_HARDLINK';$link=Join-Path $r.game 'BetterAstralParty-LaunchError.log'
$null=New-Item -ItemType HardLink -Path $link -Target $outside
$i=Inspect (Collect $r);Assert (!$i.all.Contains('FORBIDDEN_OUTSIDE_HARDLINK') -and $i.all.Contains('unsafe-or-denied')) 'hardlink outside allowlist root rejected'

$r=Roots 'junction';$outside=Join-Path $Scratch 'outside-junction';Put (Join-Path $outside 'LogOutput.log') 'FORBIDDEN_JUNCTION'
$null=New-Item -ItemType Junction -Path (Join-Path $r.game 'BepInEx') -Target $outside
$i=Inspect (Collect $r);Assert (!$i.all.Contains('FORBIDDEN_JUNCTION') -and $i.all.Contains('unsafe-or-denied')) 'junction ancestor escape rejected'

$r=Roots 'hub-junction';$outside=Join-Path $Scratch 'outside-hub';$null=[IO.Directory]::CreateDirectory($outside)
$null=New-Item -ItemType Junction -Path $r.hub -Target $outside
$b=Collect $r;Assert ($b.ArchivePath.StartsWith($r.hub2+'\') -and @(Get-ChildItem -LiteralPath $outside).Count -eq 0) 'unsafe output root falls back without writing outside'

$r=Roots 'write-failure';Put $r.hub 'occupied';Put $r.hub2 'occupied';$failed=$false
try{$null=Collect $r}catch{$failed=$true}
Assert $failed 'both output roots unavailable reports failure'
Assert ([IO.File]::ReadAllText($r.hub) -eq 'occupied' -and [IO.File]::ReadAllText($r.hub2) -eq 'occupied') 'failed collection preserves existing files'

$r=Roots 'missing-game';$i=Inspect ([BetterAstralParty.Diagnostics.DiagnosticBundle]::Collect('', $r.local,$r.fallback,$r.unity,$r.hub,$r.hub2,'PRIVATE_INVALID_HOST'))
Assert (!$i.summary.environment.gameRootValidated -and $i.summary.environment.hostVersion -eq 'unknown' -and !$i.all.Contains('PRIVATE_INVALID_HOST')) 'startup failure still makes safe install-only diagnostic ZIP'
$r=Roots 'file-count';foreach($path in @('BepInEx/BetterAstralParty-Diagnostics/current.log','BepInEx/BetterAstralParty-Diagnostics/previous.log','BepInEx/BetterAstralParty-Diagnostics/combat-mismatch.log','BepInEx/BetterAstralParty-Diagnostics/combat-mismatch-previous.log')){Put (Join-Path $r.game $path) "phase=3`n"}
Put (Join-Path $r.game 'BetterAstralParty-Compatibility.log') "Allowed: True`n";Put (Join-Path $r.game 'BetterAstralParty-LaunchError.log') "BAP-LAUNCH-FAILED`n";Put (Join-Path $r.game 'BepInEx/LogOutput.log') 'raw never read'
foreach($dir in @($r.local,$r.fallback)){for($n=0;$n -lt 8;$n++){Put (Join-Path $dir ('Launch-'+$n.ToString('x32')+'.log')) "BAP-LAUNCH-FAILED`n"}}
Put (Join-Path $r.unity 'Player.log') 'safe Unity';Put (Join-Path $r.unity 'Player-prev.log') 'safe previous'
$b=Collect $r;$i=Inspect $b;Assert ($b.Included -eq 22 -and @($i.summary.files|Where-Object {$_.status -eq 'metadata-only'}).Count -eq 3 -and $b.Included -le 24) 'content count bounded with loader/Unity metadata-only sources'
$r=Roots 'unicode';$p=Join-Path $r.game 'BepInEx/BetterAstralParty-Diagnostics/current.log';Put $p '';[IO.File]::WriteAllText($p,"2026-10-04T10:00:00Z | phase=8`n토큰=FAKE_KOREAN_KEY`n",[Text.Encoding]::Unicode)
$i=Inspect (Collect $r);Assert ($i.all.Contains('public-phase; phase=8') -and !$i.all.Contains('FAKE_KOREAN_KEY') -and $i.all.Contains('로컬 진단')) 'UTF-16 log and bilingual guide preserve glyphs with Korean sensitive keys filtered'
$r=Roots 'more-secrets';Put (Join-Path $r.game 'BepInEx/BetterAstralParty-Diagnostics/current.log') "[Error] ghp_FAKE_GITHUB_NEVER_VALID`n[Error] github_pat_FAKE_NEVER_VALID`n[Error] eyJFAKE.eyJFAKE.signatureFAKE`n[Error] 2001:db8::1`n[Error] /home/fake_person/private/file`n[Error] account:`nFAKE_MULTILINE_ACCOUNT`n"
$i=Inspect (Collect $r);Assert (!$i.all.Contains('FAKE_') -and !$i.all.Contains('2001:db8') -and !$i.all.Contains('/home/fake_person')) 'GitHub/JWT/IPv6/Unix paths and multiline account values filtered'
$r=Roots 'private-game-data';$p=Join-Path $r.game 'BepInEx/BetterAstralParty-Diagnostics/current.log'
$gameData=@'
2026-10-04T10:00:00Z | cardEffect.123456=native; min=FAKE_PRIVATE_CARD; max=8
2026-10-04T10:00:01Z | cardCounter available=True; selfKoPrevented=0.5
2026-10-04T10:00:02Z | koMinimum.content=card={FAKE_CARD_EFFECT_STRUCT}; input={FAKE_PREVIEW}
latest koMinimum.content=card={FAKE_ARCHIVED_HAND}
2026-10-04T10:00:03Z | hand={FAKE_HAND_IDS}
2026-10-04T10:00:04Z | combat.actor.attacker=heroId=123456
2026-10-04T10:00:05Z | chat=FAKE_CHAT_TEXT
2026-10-04T10:00:06Z | unknown=FAKE_UNKNOWN_RAW
FAKE_ERROR_STACK_CONTINUATION
2026-10-04T10:00:07Z | performance frames=42; unrelated=FAKE_UNKNOWN_FIELD
2026-10-04T10:00:08Z | combat=abcdef123456-1; damage.result before=20; predictedDamage=7; expectedHP=13; observedHP=13; hpMismatch=False; modifiers={FAKE_UNKNOWN_MODIFIERS}
2026-10-04T10:00:09Z | error.ModUi=System.NullReferenceException
 at FAKE_PRIVATE_METHOD C:\Users\FAKE_ACCOUNT\private.cs:22
2026-10-04T10:00:10Z | performance frames=FAKE_MALFORMED_NUMBER
'@
Put $p ($gameData+"`n");Put (Join-Path $r.game 'BepInEx/BetterAstralParty-Diagnostics/combat-mismatch.log') ($gameData+"`n")
Put (Join-Path $r.game 'BepInEx/LogOutput.log') "[Info] FAKE_OTHER_MOD FAKE_CHAT_UNLABELLED`n"
Put (Join-Path $r.unity 'Player.log') "FAKE_UNLABELLED_NICK_AND_CHAT`n"
$i=Inspect (Collect $r);Assert (!$i.all.Contains('FAKE_') -and !$i.all.Contains('123456') -and !$i.all.Contains('cardEffect') -and !$i.all.Contains('koMinimum.content')) 'legacy card/hand/chat/unknown payload and multiline stack excluded from current and mismatch'
Assert ($i.all.Contains('public-hp-result; before=20') -and $i.all.Contains('expectedHP=13') -and $i.all.Contains('managed-error; type=System.NullReferenceException')) 'public HP comparison and error type projection retained'
Assert (@($i.summary.files|Where-Object {$_.droppedLines -gt 0 -and $_.projectedRecords -gt 0}).Count -eq 2) 'dropped/projection counts cover legacy and archive'
Assert (@($i.summary.files|Where-Object {$_.status -eq 'metadata-only'}).Count -eq 2) 'engine and other mod free text never read or exported'
Assert (@($i.summary.files|Where-Object {$_.status -eq 'metadata-only' -and $_.readBytes -ne 0}).Count -eq 0) 'engine/Unity metadata sources read zero content bytes'
$r=Roots 'installer-details';$name='BetterAstralParty-InstallError-20261004-100000-1234abcd.log'
$errorText=@'
Code: BAP-INSTALL-FAILED
Version: 1.1.1-rc.1.local.3
ErrorType: System.IO.FileLoadException
Stage: Compatibility validation
Message: Could not load file or assembly 'C:\Users\FAKE_PERSON\Some Folder\Mono.Cecil.dll'. Operation is not supported. HRESULT: 0x80131515
Message: Could not load 'Mono.Cecil, Version=4.0.0.0, Culture=neutral'.
HResult: 0x80131515
Location: E:\Some Game Folder\tools\install.ps1:104
Stack: at Install, E:\Some Game Folder\tools\install.ps1: line 104
Exception: System.IO.FileLoadException: assembly load failed
 ---> System.NotSupportedException: blocked assembly
   at System.Reflection.Assembly.LoadFrom(String assemblyFile)
Authorization: Bearer FAKE_DETAIL_TOKEN
 FAKE_DETAIL_CONTINUATION
Message: Retry with a fully extracted package.
Game: E:\Steam\userdata\76561198000000000
Package: %USERPROFILE%\Downloads\FAKE_PRIVATE Folder\BetterAstralParty
Message: Directory not found: 'C:\Users\Alice\FAKE_DIRECTORY Private Folder'
Location: C:\Users\Alice\bank_statement.json
Message: Detached signature verification failed.
ExpectedSha256: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
'@
Put (Join-Path $r.local $name) $errorText
Put (Join-Path $r.local ('Bootstrap-'+('b'*32)+'.log')) "BAP-BOOTSTRAP-FAILED`nRun: $('b'*32)`nSystem.IO.FileLoadException: Mono.Cecil.dll 0x80131515"
Put (Join-Path $r.game 'BetterAstralParty-Compatibility.log') "Allowed: False`nChanged [catalog]: downloaded catalog inventory`nMissing [loader]: BepInEx/core/BepInEx.dll`nCheck failed: catalog_3.2.0.json`n"
$i=Inspect (Collect $r)
Assert ($i.all.Contains('Mono.Cecil.dll') -and $i.all.Contains('0x80131515') -and $i.all.Contains('System.NotSupportedException') -and $i.all.Contains('Assembly.LoadFrom') -and $i.all.Contains('install.ps1:104')) 'complete error context preserves DLL HRESULT exception chain and stack locations'
Assert ($i.all.Contains('Retry with a fully extracted package') -and $i.all.Contains('Changed [catalog]: downloaded catalog inventory') -and $i.all.Contains('BepInEx/core/BepInEx.dll') -and $i.all.Contains('catalog_3.2.0.json')) 'error messages and all compatibility issue keys retained'
Assert (!$i.all.Contains('FAKE_') -and !$i.all.Contains('userdata') -and !$i.all.Contains(('b'*32)) -and !$i.all.Contains('Some Game Folder') -and !$i.all.Contains('bank_statement')) 'detailed error secrets spaced directories personal filenames and run identities masked'
Assert ($i.all.Contains('Version=4.0.0.0') -and $i.all.Contains('Detached signature verification failed') -and $i.all.Contains(('A'*64))) 'assembly versions signature failure text and explicit SHA256 evidence retained'
Assert ($i.all.Contains('BAP-BOOTSTRAP-FAILED') -and @($i.summary.files|Where-Object {$_.contentKind -eq 'redacted-error-text' -and $_.status -eq 'included'}).Count -eq 3) 'bootstrap files included and detailed content mode declared'
$r=Roots 'error-privacy';Put (Join-Path $r.local ('Launch-'+('c'*32)+'.log')) "BAP-LAUNCH-FAILED`nException: DLL load failed from /home/FAKE_UNIX/tools/test.dll`nMessage: contact fake_person@example.invalid 192.0.2.23 2001:db8::1`nLocation: C:\Users\FAKE_QUOTED\A Folder\test.cs:22`nMessage: https://example.invalid/path?unlabelled=FAKE_QUERY`n-----BEGIN PRIVATE KEY-----`nFAKE_PRIVATE_KEY`n-----END PRIVATE KEY-----`nFAKE_KEY_CONTINUATION`nHResult: 0x80070005`n"
$i=Inspect (Collect $r);Assert (!$i.all.Contains('FAKE_') -and !$i.all.Contains('fake_person@') -and !$i.all.Contains('192.0.2.23') -and !$i.all.Contains('2001:db8') -and $i.all.Contains('test.dll') -and $i.all.Contains('test.cs:22') -and $i.all.Contains('0x80070005')) 'detailed errors mask Unix Windows URL email IP and multiline key values'
$r=Roots 'partial-record';Put (Join-Path $r.game 'BepInEx/BetterAstralParty-Diagnostics/current.log') 'performance frames=42'
$i=Inspect (Collect $r);Assert (!$i.all.Contains('frames=42') -and @($i.summary.files|Where-Object {$_.droppedLines -gt 0}).Count -eq 1) 'unfinished final line never accepted as structured record'
$r=Roots 'output-total';foreach($dir in @($r.local,$r.fallback)){for($n=0;$n -lt 8;$n++){Put (Join-Path $dir ('Launch-'+$n.ToString('x32')+'.log')) (('Code: BAP-INSTALL-FAILED'+"`n")*30000)}}
$i=Inspect (Collect $r);Assert ($i.logBytes -le 4194304 -and $i.logBytes -gt 4194000 -and @($i.summary.files|Where-Object {$_.truncated -or $_.status -eq 'output-limit'}).Count -gt 0) 'actual aggregate projection output reaches bound without exceeding it'
$r=Roots 'version-provenance';$b=[BetterAstralParty.Diagnostics.DiagnosticBundle]::Collect($r.game,$r.local,$r.fallback,$r.unity,$r.hub,$r.hub2,'6.0','1.0.0-rc.2');$i=Inspect $b
Assert ($i.summary.environment.pluginVersion -eq '1.0.0-rc.2' -and $i.summary.environment.pluginVersionSource -eq 'running-plugin' -and $i.summary.environment.pluginFileProductVersion -eq 'unknown') 'running plugin constant has explicit provenance distinct from file product version'
$b=[BetterAstralParty.Diagnostics.DiagnosticBundle]::Collect($r.game,$r.local,$r.fallback,$r.unity,$r.hub,$r.hub2,'6.0','FAKE_INVALID_VERSION');$i=Inspect $b
Assert ($i.summary.environment.pluginVersion -eq 'unknown' -and !$i.all.Contains('FAKE_INVALID_VERSION')) 'unrecognised plugin version never exported'

$r=Roots 'catalog-missing';$i=Inspect (Collect $r)
Assert ($i.catalog.status -eq 'missing' -and @($i.catalog.files).Count -eq 0) 'missing catalog cache recorded without failing logs'
Assert ($i.summary.catalogInventory.contentKind -eq 'filename-size-sha256-only' -and !$i.catalog.contentsIncluded -and !$i.summary.catalogInventory.logQuotaShared) 'catalog metadata declared separately from unchanged log quota'
$b=[BetterAstralParty.Diagnostics.DiagnosticBundle]::Collect($r.game,$r.local,$r.fallback,'',$r.hub,$r.hub2,'7.0');$i=Inspect $b
Assert ($i.catalog.status -eq 'not-selected') 'no Unity root never selects a default or arbitrary catalog cache'

$r=Roots 'catalog-metadata';$cache=Join-Path $r.unity 'com.unity.addressables'
$catalogNames=@('catalog_3.2.0.json','catalog_3.1.0.hash','catalog_3.1.0.json','Catalog_유니코드.hash','CATALOG Current.JSON')
foreach($name in $catalogNames){Put (Join-Path $cache $name) ('FORBIDDEN_RAW_CATALOG_'+$name)}
[IO.File]::SetLastWriteTimeUtc((Join-Path $cache 'catalog_3.1.0.json'),[DateTime]::UtcNow.AddDays(-30))
Put (Join-Path $cache 'preferences.json') 'FORBIDDEN_CACHE_PREFERENCES'
Put (Join-Path $cache 'catalog_3.2.0.json.bak') 'FORBIDDEN_BACKUP'
Put (Join-Path $cache '__data') 'FORBIDDEN_PUBLIC_PAYLOAD_NOT_SELECTED'
Put (Join-Path $cache 'nested/catalog_hidden.json') 'FORBIDDEN_NESTED_CATALOG'
Put (Join-Path $r.unity 'catalog_outside.json') 'FORBIDDEN_OUTSIDE_CATALOG'
$before=@{};foreach($name in $catalogNames){$before[$name]=(Get-FileHash -LiteralPath (Join-Path $cache $name)).Hash}
$b=Collect $r;$i=Inspect $b
Assert ($i.catalog.status -eq 'complete' -and @($i.catalog.files).Count -eq 5 -and $i.catalog.matchedEntries -eq 5) 'current and old top-level JSON/hash filenames plus Unicode spaces and case both inventoried'
Assert ((@($i.catalog.files|ForEach-Object {$_.filename}) -join '|') -eq 'CATALOG Current.JSON|Catalog_유니코드.hash|catalog_3.1.0.hash|catalog_3.1.0.json|catalog_3.2.0.json') 'catalog inventory uses deterministic ordinal order and preserves original spelling'
foreach($file in $i.catalog.files){Assert ($file.status -eq 'hashed' -and $file.sha256 -eq $before[$file.filename] -and $file.sizeBytes -eq (Get-Item -LiteralPath (Join-Path $cache $file.filename)).Length) ('exact size/SHA without raw content: '+$file.filename)}
Assert (!$i.all.Contains('FORBIDDEN_') -and !$i.all.Contains($cache) -and @($i.names|Where-Object {$_ -match '^catalog[^-]'}).Count -eq 0) 'catalog secrets other files nested payloads and absolute paths never exported'
Assert ($b.Included -eq 0 -and $i.summary.limits.inputFileBytes -eq 2097152 -and $i.summary.limits.inputTotalBytes -eq 8388608) 'catalog inventory does not change log counts or input budgets'
$j=Inspect (Collect $r);Assert ($j.catalogText -eq $i.catalogText) 'unchanged catalog metadata serializes identically in a later ZIP'
foreach($name in $before.Keys){Assert ((Get-FileHash -LiteralPath (Join-Path $cache $name)).Hash -eq $before[$name]) ('catalog source preserved: '+$name)}
$quoted=[BetterAstralParty.Diagnostics.DiagnosticBundle].GetMethod('Quote',[Reflection.BindingFlags]'Static,NonPublic').Invoke($null,[object[]]@("catalog_`t`b`f.hash"))
$parsedQuote=('{"name":'+$quoted+'}')|ConvertFrom-Json
Assert ($parsedQuote.name -eq "catalog_`t`b`f.hash") 'JSON string encoding preserves filename characters without invalid control bytes'

function Sized([string]$Path,[long]$Length) {
    $null=[IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try{$stream.SetLength($Length)}finally{$stream.Dispose()}
}
$r=Roots 'catalog-large';$cache=Join-Path $r.unity 'com.unity.addressables';$p=Join-Path $cache 'catalog_9MiB.json';Sized $p (9*1024*1024)
$before=(Get-FileHash -LiteralPath $p).Hash;$i=Inspect (Collect $r);$file=$i.catalog.files[0]
Assert ($file.sizeBytes -eq 9437184 -and $file.status -eq 'hashed' -and $file.sha256 -eq $before -and $i.catalog.hashReservedBytes -eq 9437184) '9 MiB catalog streams SHA beyond 2 MiB log limit without exporting contents'
Assert ((Get-FileHash -LiteralPath $p).Hash -eq $before) 'large catalog source unchanged'

$r=Roots 'catalog-budget';$cache=Join-Path $r.unity 'com.unity.addressables'
foreach($name in @('catalog_a.json','catalog_b.json','catalog_c.json')){Sized (Join-Path $cache $name) (32*1024*1024)}
Sized (Join-Path $cache 'catalog_d.json') (32*1024*1024+1)
$i=Inspect (Collect $r)
Assert (@($i.catalog.files|Where-Object {$_.status -eq 'hashed'}).Count -eq 2 -and $i.catalog.hashReservedBytes -eq 67108864) 'catalog hash budget stops after exactly 64 MiB'
Assert ($i.catalog.files[2].filename -eq 'catalog_c.json' -and $i.catalog.files[2].sizeBytes -eq 33554432 -and $null -eq $i.catalog.files[2].sha256 -and $i.catalog.files[2].status -eq 'hash-budget-limit') 'hash-budget omission preserves catalog filename and size, not a partial hash'
Assert ($i.catalog.files[3].filename -eq 'catalog_d.json' -and $i.catalog.files[3].sizeBytes -eq 33554433 -and $null -eq $i.catalog.files[3].sha256 -and $i.catalog.files[3].status -eq 'file-size-limit') 'oversize catalog preserves filename/size and explicit reason with no digest'

$r=Roots 'catalog-count';$cache=Join-Path $r.unity 'com.unity.addressables'
for($n=0;$n -lt 65;$n++){Put (Join-Path $cache ('catalog_'+$n.ToString('D3')+'.hash')) ''}
$i=Inspect (Collect $r)
Assert (@($i.catalog.files).Count -eq 64 -and $i.catalog.matchedEntries -eq 65 -and $i.catalog.fileLimitOmitted -eq 1 -and $i.catalog.files[63].filename -eq 'catalog_063.hash') 'catalog count bound retains first 64 sorted names and omitted count'
Assert ($i.catalog.hashReservedBytes -eq 0 -and $i.catalog.files[0].sha256 -eq 'E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855') 'empty catalog hashes are valid and consume zero byte budget'
$r=Roots 'catalog-scan';$cache=Join-Path $r.unity 'com.unity.addressables'
for($n=0;$n -lt 513;$n++){Put (Join-Path $cache ($n.ToString('D4')+'.txt')) 'FORBIDDEN_SCAN'}
$i=Inspect (Collect $r)
Assert ($i.catalog.status -eq 'directory-scan-limit' -and $i.catalog.scannedEntries -eq 512 -and @($i.catalog.files).Count -eq 0 -and !$i.all.Contains('FORBIDDEN_SCAN')) 'catalog enumeration stops at 512 top-level entries and reports incomplete inventory'

$r=Roots 'catalog-links';$cache=Join-Path $r.unity 'com.unity.addressables';$null=[IO.Directory]::CreateDirectory($cache)
$outside=Join-Path $Scratch 'catalog-link-target.json';Put $outside 'FORBIDDEN_LINK_CONTENT'
$null=New-Item -ItemType HardLink -Path (Join-Path $cache 'catalog_hard.json') -Target $outside
$outsideDir=Join-Path $Scratch 'catalog-link-directory';$null=[IO.Directory]::CreateDirectory($outsideDir);Put (Join-Path $outsideDir 'catalog_private.json') 'FORBIDDEN_LINK_DIRECTORY'
$null=New-Item -ItemType Junction -Path (Join-Path $cache 'catalog_directory.json') -Target $outsideDir
$i=Inspect (Collect $r)
Assert (@($i.catalog.files|Where-Object {$_.status -eq 'unsafe-or-denied' -and $null -eq $_.sha256}).Count -eq 2 -and !$i.all.Contains('FORBIDDEN_')) 'hardlinks and matching directory links are refused without hashing outside bytes'
$r=Roots 'catalog-root-link';$null=New-Item -ItemType Junction -Path (Join-Path $r.unity 'com.unity.addressables') -Target $outsideDir
$i=Inspect (Collect $r);Assert ($i.catalog.status -eq 'unsafe-or-unreadable' -and @($i.catalog.files).Count -eq 0) 'linked catalog root rejected before enumeration'
$r=Roots 'catalog-locked';$cache=Join-Path $r.unity 'com.unity.addressables';$p=Join-Path $cache 'catalog_locked.json';Put $p 'FORBIDDEN_LOCKED_CATALOG'
$lock=[IO.File]::Open($p,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try {
    $i=Inspect (Collect $r)
    Assert ($i.catalog.files[0].filename -eq 'catalog_locked.json' -and $i.catalog.files[0].status -eq 'locked-or-unreadable' -and $null -eq $i.catalog.files[0].sha256 -and $i.catalog.hashReservedBytes -eq 0) 'locked catalog name and fixed reason retained without reading or hashing'
}finally{$lock.Dispose()}

$r=Roots 'catalog-change';$cache=Join-Path $r.unity 'com.unity.addressables';$p=Join-Path $cache 'catalog_change.json';Put $p 'synthetic stable bytes'
$args1[0]=[string]$cache;$fence=$constructor.Invoke($args1);$args3[0]='catalog_change.json';$args3[1]=$false;$args3[2]=$true
$held=$fenceType.GetMethod('Open',[Reflection.BindingFlags]'Instance,NonPublic').Invoke($fence,$args3)
try {
    $blocked=$false;try{[IO.File]::Move($p,$p+'.moved')}catch{$blocked=$true}
    Assert $blocked 'catalog retained handle pins filename while hashing unlike rotating log handles'
    $writer=[IO.File]::Open($p,[IO.FileMode]::Append,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite)
    try{$writer.WriteByte(33);$writer.Flush()}finally{$writer.Dispose()}
    $digest=[BetterAstralParty.Diagnostics.DiagnosticBundle].GetMethod('CatalogHash',[Reflection.BindingFlags]'Static,NonPublic').Invoke($null,[object[]]@($held))
    Assert ($null -eq $digest) 'size changed after catalog open cannot produce a valid digest'
} finally {$held.Dispose();$fence.Dispose()}
$args1[0]=[string]$cache;$fence=$constructor.Invoke($args1);$held=$fenceType.GetMethod('Open',[Reflection.BindingFlags]'Instance,NonPublic').Invoke($fence,$args3)
try {
    [IO.File]::SetLastWriteTimeUtc($p,[DateTime]::UtcNow.AddDays(-1))
    $digest=[BetterAstralParty.Diagnostics.DiagnosticBundle].GetMethod('CatalogHash',[Reflection.BindingFlags]'Static,NonPublic').Invoke($null,[object[]]@($held))
    Assert ($null -eq $digest) 'same-size catalog modification timestamp change suppresses the digest'
} finally {$held.Dispose();$fence.Dispose()}
$i=Inspect (Collect $r);Assert ($i.catalog.files[0].status -eq 'hashed') 'later stable catalog snapshot can hash without retrying a failed snapshot in the same collection'

function RecoveryFile($i,[string]$Name) { return @($i.recovery.files | Where-Object { $_.source -eq $Name })[0] }
$r=Roots 'recovery-markerless';$markerless=Join-Path $Scratch 'remnants';$null=[IO.Directory]::CreateDirectory($markerless)
$r.local=Join-Path $Scratch 'state/BetterAstralParty/Logs';$null=[IO.Directory]::CreateDirectory($r.local)
Put (Join-Path $markerless 'BetterAstralParty.install.json') 'FORBIDDEN_RAW_RECEIPT'
Put (Join-Path $markerless 'BetterAstralParty.update.version') 'FORBIDDEN_RAW_HIGH_WATER'
Put (Join-Path $markerless 'BetterAstralParty.update.operation') 'FORBIDDEN_RAW_OPERATION'
Put (Join-Path $markerless 'BetterAstralParty-LaunchError.log') ('2026-10-11T01:00:00Z | System.IO.FileNotFoundException: Assembly Example.Safe.dll missing'+[Environment]::NewLine)
Put (Join-Path $markerless 'BepInEx/BetterAstralParty-Diagnostics/current.log') ('2026-10-11T01:00:00Z | phase=7'+[Environment]::NewLine+'Authorization: Bearer FORBIDDEN_RAW_RUNTIME'+[Environment]::NewLine)
$minimal=[ordered]@{schema='bap.minimal-diagnostic/v1';process_session=('9'*32);sequence=1;utc=[DateTimeOffset]::UtcNow.ToString('O');elapsed_ms=0;mod_version='1.1.2';build_id='unknown';runtime_version='6.0';kind='Stage';feature='Helper';phase='Recovery';outcome='Begin';code='None';ui_action='Unknown';error_site='None';error_type='None';operation='-';related_operation='-';target_version='unknown';update_state='RecoveryRequired';count=0;secondary_count=0;native_code=0;validation_code=0;apply_code=0}
Put (Join-Path $markerless 'BepInEx/BetterAstralParty-Diagnostics/minimal-v1/helper/events-current.jsonl') (($minimal|ConvertTo-Json -Compress)+[Environment]::NewLine+'{"secret":"FORBIDDEN_RAW_MINIMAL"}'+[Environment]::NewLine)
$workId='a'*32;$tempId='b'*32;$work=Join-Path $markerless ('bap-helperauto-'+$workId)
Put (Join-Path $work 'plan') 'FORBIDDEN_RAW_PLAN';Put (Join-Path $work ('committed-pending-'+$tempId)) 'FORBIDDEN_RAW_ATOMIC'
Put (Join-Path $work 'unrelated-secret.json') 'FORBIDDEN_ARBITRARY_FILE'
Put (Join-Path $markerless 'BepInEx/config/kr.betterastralparty.mod.cfg') 'FORBIDDEN_FULL_CONFIG'
$credential=Join-Path $r.local 'credential-store.json';Put $credential 'FORBIDDEN_CREDENTIAL_STORE'
$secretLock=[IO.File]::Open($credential,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
$sha=[Security.Cryptography.SHA256]::Create()
try{$key=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($markerless).TrimEnd('\').ToLowerInvariant()))).Replace('-','')}finally{$sha.Dispose()}
$backup=Join-Path (Split-Path -Parent $r.local) ('Backups/'+$key)
Put (Join-Path $backup 'pending.json') 'FORBIDDEN_RAW_INSTALL_PENDING'
Put (Join-Path $backup (($tempId)+'/completed.json')) 'FORBIDDEN_RAW_COMPLETED'
Put (Join-Path $backup (($tempId)+'/0.bin')) 'FORBIDDEN_BACKUP_PAYLOAD'
Put (Join-Path (Split-Path -Parent $backup) (('c'*64)+'/pending.json')) 'FORBIDDEN_UNRELATED_ROOT'
$receipt=Join-Path $markerless 'BetterAstralParty.install.json';$before=(Get-FileHash -LiteralPath $receipt).Hash
try{$i=Inspect (Collect $r $markerless)}finally{$secretLock.Dispose()}
Assert (!$i.summary.environment.gameRootValidated -and !$i.recovery.gameMarkersValidated -and !$i.recovery.installationVerified -and !$i.recovery.recoveryAuthenticated) 'markerless fixed-file inventory never upgrades game or recovery validation'
Assert ((RecoveryFile $i 'game/BetterAstralParty.install.json').sha256 -eq $before -and (RecoveryFile $i 'game/BetterAstralParty-Launcher.exe').present -eq $false) 'markerless receipt hash and missing owned files recorded exactly'
Assert ((RecoveryFile $i 'game/BetterAstralParty.update.version').present -eq $true -and @($i.recovery.files | Where-Object { $_.source -match 'highwater' }).Count -eq 0) 'actual update.version contract recorded without invented highwater filename'
Assert (@($i.recovery.observations | Where-Object {$_.code -eq 'work-marker-observed' -and $_.potentialBlocker -eq $true}).Count -eq 1) 'intent-only work observed as potential blocker without parsing journal'
Assert (@($i.recovery.observations | Where-Object {$_.code -eq 'unpublished-marker-observed' -and $_.potentialBlocker -eq $true}).Count -eq 1) 'atomic unpublished marker observed with bundle-local alias'
Assert ((RecoveryFile $i 'installer-backups/pending.json').present -eq $true -and @($i.recovery.files | Where-Object {$_.source -match '/completed.json$'}).Count -eq 1) 'only exact selected-root hash backup pending and completed markers included'
Assert (!$i.recoveryText.Contains($workId) -and !$i.recoveryText.Contains($tempId) -and !$i.recoveryText.Contains($key) -and !$i.recoveryText.Contains($Scratch) -and !$i.recoveryText.Contains('FORBIDDEN')) 'raw journals absolute roots GUIDs backup keys configuration and payload excluded'
Assert (!$i.all.Contains('FORBIDDEN') -and $i.names -contains 'logs/game-launch-error.log' -and $i.all.Contains('Example.Safe.dll')) 'markerless owned launcher error retained sanitized while credential store stays unopened'
Assert (@($i.summary.files | Where-Object {$_.source -eq 'game/minimal-helper-current' -and $_.projectedRecords -eq 1}).Count -eq 1 -and $i.names -contains 'logs/game-diagnostics-current.log' -and $i.all.Contains('public-phase; phase=7') -and !$i.all.Contains('FORBIDDEN_RAW_')) 'markerless owned runtime and minimal helper logs retain typed projection only'
Assert ((Get-FileHash -LiteralPath $receipt).Hash -eq $before -and (Test-Path -LiteralPath (Join-Path $backup 'pending.json'))) 'diagnostic inventory does not modify receipt or recovery evidence'
Put (Join-Path $work 'committed') 'not authenticated terminal bytes';$i=Inspect (Collect $r $markerless)
Assert (@($i.recovery.observations | Where-Object {$_.code -eq 'work-marker-observed' -and $_.potentialBlocker -eq $false}).Count -eq 1 -and !$i.recovery.recoveryAuthenticated) 'terminal marker presence is observation only not authenticated completion'
$r=Roots 'recovery-work-contracts';$n=0
foreach($kind in @('helper','helperbridge','helperauto','wholeintent','txn','stage')){
    $dir=Join-Path $r.game ('bap-'+$kind+'-'+(++$n).ToString('x32'));$null=[IO.Directory]::CreateDirectory($dir)
    Put (Join-Path $dir $(if($kind -eq 'stage'){'handoff.ticket'}else{'plan'})) 'FORBIDDEN_TYPED_MARKER'
    if($kind -eq 'wholeintent'){Put (Join-Path $dir 'cancelled') 'synthetic'}
    if($kind -eq 'txn'){Put (Join-Path $dir 'rolled-back') 'synthetic';Put (Join-Path $dir 'commit-intent') 'synthetic'}
    if($kind -eq 'stage'){Put (Join-Path $dir 'helper.attempt') 'FORBIDDEN_ATTEMPT_BINDING';Put (Join-Path $dir 'helper.recovery') 'FORBIDDEN_RECOVERY_BINDING'}
}
Put (Join-Path $r.game 'bap-txn-not-a-native-name/plan') 'FORBIDDEN_NON_CONTRACT'
Put (Join-Path $r.game ('BetterAstralParty.reinstall.completed-'+('d'*32))) 'FORBIDDEN_REINSTALL_GENERATION'
Put (Join-Path $r.game ('BetterAstralParty.update.version.uninstalled-'+('e'*32))) 'FORBIDDEN_ARCHIVED_WATER'
Put (Join-Path $r.game ('bap-transition-'+('f'*32))) 'FORBIDDEN_TRANSITION'
$i=Inspect (Collect $r)
Assert (@($i.recovery.observations | Where-Object {$_.code -eq 'work-marker-observed'}).Count -eq 6 -and @($i.recovery.observations | Where-Object {$_.code -eq 'work-marker-observed' -and $_.potentialBlocker -eq $false}).Count -eq 2) 'native work kind cancellation and rollback marker coverage'
Assert (@($i.recovery.files | Where-Object {$_.source -match '/helper.(attempt|recovery)$' -and $_.present -eq $true -and $_.status -eq 'hashed'}).Count -eq 2 -and !$i.recoveryText.Contains('FORBIDDEN_')) 'actual helper attempt and recovery binding markers inventoried without raw contents'
Assert (@($i.recovery.files | Where-Object {$_.source -match 'reinstall-completed|archived-version|game/transition/'}).Count -eq 3 -and !$i.recoveryText.Contains('not-a-native-name') -and !$i.recoveryText.Contains('FORBIDDEN')) 'generation history metadata masked and non-contract objects excluded'
$r=Roots 'recovery-linked';$outside=Join-Path $Scratch 'recovery-outside';Put (Join-Path $outside 'plan') 'FORBIDDEN_LINK_TARGET'
$linked=Join-Path $r.game ('bap-helperauto-'+('1'*32));$null=New-Item -ItemType Junction -Path $linked -Target $outside
$hard=Join-Path $r.game 'BetterAstralParty.install.json';$null=New-Item -ItemType HardLink -Path $hard -Target (Join-Path $outside 'plan')
$locked=Join-Path $r.game 'BetterAstralParty.update.version';Put $locked 'FORBIDDEN_LOCKED_WATER';$held=[IO.File]::Open($locked,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try{$i=Inspect (Collect $r)}finally{$held.Dispose()}
Assert ((RecoveryFile $i 'game/BetterAstralParty.install.json').status -eq 'unsafe-or-denied' -and $null -eq (RecoveryFile $i 'game/BetterAstralParty.install.json').sha256) 'hard-linked recovery file refused without digest'
Assert ((RecoveryFile $i 'game/BetterAstralParty.update.version').status -eq 'locked-or-unreadable' -and $null -eq (RecoveryFile $i 'game/BetterAstralParty.update.version').present) 'busy recovery file is unknown rather than absent'
Assert (@($i.recovery.roots | Where-Object {$_.source -match '^game/helperauto/' -and $_.status -eq 'unsafe-or-unreadable'}).Count -eq 1 -and !$i.recoveryText.Contains('FORBIDDEN')) 'linked work directory refused without traversing target'
$r=Roots 'recovery-budgets'
foreach($name in @('AstralParty-Vanilla.cmd','BetterAstralParty-Launcher.exe')){$p=Join-Path $r.game $name;$f=[IO.File]::Open($p,[IO.FileMode]::CreateNew);try{$f.SetLength(33554432)}finally{$f.Dispose()}}
Put (Join-Path $r.game 'BetterAstralParty.install.json') 'small receipt'
$i=Inspect (Collect $r)
Assert ($i.recovery.hashReservedBytes -eq 67108864 -and (RecoveryFile $i 'game/BetterAstralParty.install.json').status -eq 'hash-budget-limit') 'recovery hashing has independent bounded total budget'
$p=Join-Path $r.game 'BetterAstralParty-Launcher.exe';$f=[IO.File]::Open($p,[IO.FileMode]::Open);try{$f.SetLength(67108865)}finally{$f.Dispose()}
$i=Inspect (Collect $r)
Assert ((RecoveryFile $i 'game/BetterAstralParty-Launcher.exe').status -eq 'file-size-limit' -and $null -eq (RecoveryFile $i 'game/BetterAstralParty-Launcher.exe').sha256) 'oversized owned file metadata retained without reading beyond file limit'
$r=Roots 'recovery-directory-limit'
for($n=0;$n -lt 65;$n++){$null=[IO.Directory]::CreateDirectory((Join-Path $r.game ('bap-wholeintent-'+$n.ToString('x32'))))}
$i=Inspect (Collect $r);$limits=@($i.recovery.roots | Where-Object {$_.source -eq 'game/work-directories'})[0]
Assert ($limits.matchedEntries -eq 65 -and $limits.limitOmitted -eq 1 -and @($i.recovery.observations | Where-Object {$_.code -eq 'work-marker-observed'}).Count -eq 64) 'recovery matching directories capped at 64'
$r=Roots 'recovery-scan-limit';for($n=0;$n -lt 513;$n++){Put (Join-Path $r.game ('unrelated-'+$n)) 'private unused'}
$i=Inspect (Collect $r);$limits=@($i.recovery.roots | Where-Object {$_.source -eq 'game/work-directories'})[0]
Assert ($limits.scannedEntries -eq 512 -and $limits.status -eq 'directory-scan-limit' -and !$i.recoveryText.Contains('unrelated-')) 'recovery top-level enumeration bounded and unrelated names omitted'
$entrypoint=Join-Path (Split-Path -Parent $PSScriptRoot) 'tools/diagnostics.ps1'
$tokens=$null;$parseErrors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($entrypoint,[ref]$tokens,[ref]$parseErrors)
Assert (@($parseErrors).Count -eq 0) 'diagnostics entrypoint parses'
$resolver=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Resolve-DiagnosticsGameRoot'},$true)
. ([scriptblock]::Create($resolver.Extent.Text))
$parent=Join-Path $Scratch 'adjacent/Astral Party';$int=Join-Path $parent '8vJXnINT';Put (Join-Path $int 'AstralParty_INT.exe') 'inert';$null=[IO.Directory]::CreateDirectory((Join-Path $int 'AstralParty_INT_Data'))
Assert ((Resolve-DiagnosticsGameRoot $parent $r.game) -eq $int) 'explicit Steam game parent resolves exact INT child'
Assert ((Resolve-DiagnosticsGameRoot '' (Join-Path $parent 'BetterAstralParty')) -eq $int) 'package adjacent known sibling INT discovery'
$selected=Join-Path $Scratch 'missing-markers-parent';$candidate=Join-Path $selected '8vJXnINT';$null=[IO.Directory]::CreateDirectory($candidate)
Assert ((Resolve-DiagnosticsGameRoot $selected $r.game) -eq $candidate -and (Resolve-DiagnosticsGameRoot '' (Join-Path $selected 'BetterAstralParty')) -eq $candidate) 'known markerless INT remains metadata candidate without being validated'
$unknown=Join-Path $Scratch 'no-automatic-root';$null=[IO.Directory]::CreateDirectory($unknown)
Assert ((Resolve-DiagnosticsGameRoot '' $unknown) -eq '' -and (Resolve-DiagnosticsGameRoot $unknown $r.game) -eq $unknown) 'no recursive discovery and explicit invalid selection preserved for fenced metadata only'

$report=[ordered]@{runtime=$PSVersionTable.PSVersion.ToString();passed=$script:Cases.Count;cases=@($script:Cases);scratch=$Scratch;collectorSha256=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash;fixtureSha256=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash;entrypointSha256=(Get-FileHash -LiteralPath $entrypoint -Algorithm SHA256).Hash;realLogsRead=$false;realGameRun=$false;upload=$false}
$report|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $Scratch 'test-results.json') -Encoding UTF8
Write-Output ($report|ConvertTo-Json -Depth 5)
