$ErrorActionPreference = 'Stop'
$file = Join-Path $PSScriptRoot 'steam-shortcut.ps1'
# Function loading must not resolve accounts, inspect processes or touch Steam files.
& {
    function Get-ItemProperty { throw 'Dot-source unexpectedly read registry' }
    function Get-Process { throw 'Dot-source unexpectedly inspected processes' }
    function Test-Path { throw 'Dot-source unexpectedly inspected files' }
    $ErrorActionPreference='Continue'
    . $file -SteamRoot '' -GameRoot ''
    if ($ErrorActionPreference -cne 'Continue') { throw 'Shared Steam import changed caller error handling' }
    if (!(Get-Command Assert-BapSteamStopped -CommandType Function)) { throw 'Shared Steam guards were not imported' }
    $GameRoot='selected game'; $SteamRoot='selected steam'; $AccountId=17; $Mode='caller mode'
    . (Join-Path $PSScriptRoot 'steam-session.ps1')
    if ($ErrorActionPreference -cne 'Continue') { throw 'Shared Steam session import changed caller error handling' }
    if ($GameRoot -cne 'selected game' -or $SteamRoot -cne 'selected steam' -or $AccountId -ne 17 -or $Mode -cne 'caller mode') { throw 'Shared Steam import changed caller selections' }
}
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($function in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([scriptblock]::Create($function.Extent.Text))
}
$fixture = [ordered]@{shortcuts=[ordered]@{
    '0'=[ordered]@{appid=[uint32]4294967290; AppName='Existing game'; exe='"C:\Other Game\game.exe"'; tags=[ordered]@{'0'='Favorites'}}
}}
$original = ConvertTo-ShortcutBytes $fixture
$parsed = Read-Shortcuts $original
$roundtrip = ConvertTo-ShortcutBytes $parsed
if ([Convert]::ToBase64String($original) -ne [Convert]::ToBase64String($roundtrip)) { throw 'Existing shortcut bytes changed' }
$parsed.shortcuts['1'] = [ordered]@{appid=[uint32]2147483649; AppName='Astral Party - Mod'}
$after = Read-Shortcuts (ConvertTo-ShortcutBytes $parsed)
if ($after.shortcuts['0'].exe -ne $fixture.shortcuts['0'].exe -or $after.shortcuts.Count -ne 2) { throw 'Existing entry lost' }
foreach ($bad in @([byte[]]@(0,115,0,7,0,8,8), [byte[]]@(0,115,0))) {
    $rejected = $false
    try { $null = Read-Shortcuts $bad } catch { $rejected = $true }
    if (!$rejected) { throw 'Unsupported/truncated file accepted' }
}
Write-Host 'Steam shortcuts: byte-preserving roundtrip, existing entry preservation, unknown/truncated format rejection passed.'
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('bap-account-' + [guid]::NewGuid().ToString('N'))
try {
    $null = [IO.Directory]::CreateDirectory((Join-Path $scratch 'userdata/1/config'))
    $null = [IO.Directory]::CreateDirectory((Join-Path $scratch 'config'))
    $absentDrive = [char[]](65..90) | Where-Object { !(Test-Path -LiteralPath ("${_}:\") -PathType Container) } | Select-Object -First 1
    if (!$absentDrive) { throw 'Fixture requires an unavailable drive' }
    try { $null = Resolve-SteamAccount "${absentDrive}:\MissingSteam" 1 1 ''; throw 'Expected missing Steam root refusal' }
    catch { if ($_.Exception.Message -notlike '*Steam installation directory unavailable*') { throw } }
    if ((Resolve-SteamAccount $scratch 0 0 '').AccountId -ne 1) { throw 'Single local profile fallback' }
    $null = [IO.Directory]::CreateDirectory((Join-Path $scratch 'userdata/2/config'))
    function Must-Reject([scriptblock]$Action) {
        $failed = $false; try { $null = & $Action } catch { $failed = $true }
        if (!$failed) { throw 'Ambiguous/invalid account accepted' }
    }
    Must-Reject { Resolve-SteamAccount $scratch 0 0 '' }
    Must-Reject { Resolve-SteamAccount $scratch 3 0 '' }
    if ((Resolve-SteamAccount $scratch 2 1 '').AccountId -ne 2) { throw 'Explicit profile priority' }
    if ((Resolve-SteamAccount $scratch 0 1 '').AccountId -ne 1) { throw 'Registry priority' }
    $metadata = Join-Path $scratch 'config/loginusers.vdf'
    [IO.File]::WriteAllText($metadata, '"users" { "76561197960265729" { "AccountName" "first" } "76561197960265730" { "AccountName" "second" } }')
    if ((Resolve-SteamAccount $scratch 0 0 'second').AccountId -ne 2) { throw 'Auto-login cross-check fallback' }
    Must-Reject { Resolve-SteamAccount $scratch 0 0 'absent' }
    [IO.File]::WriteAllText($metadata, '"users" { "76561197960265729" { "AccountName" "first" "MostRecent" "1" } "76561197960265730" { "AccountName" "second" } }')
    if ((Resolve-SteamAccount $scratch 0 0 '').AccountId -ne 1) { throw 'MostRecent fallback' }
    Must-Reject { Resolve-SteamAccount $scratch 0 0 'second' }
    [IO.File]::WriteAllText($metadata, '"users" { "76561197960265729" { "MostRecent" "1" } "76561197960265730" { "MostRecent" "1" } }')
    Must-Reject { Resolve-SteamAccount $scratch 0 0 '' }
    [IO.File]::WriteAllText($metadata, '"users" { "76561197960265729" { "MostRecent" "1" "MostRecent" "0" } }')
    Must-Reject { Resolve-SteamAccount $scratch 0 0 '' }
    [IO.File]::WriteAllText($metadata, '"users" { "76561197960265731" { "MostRecent" "1" } }')
    Must-Reject { Resolve-SteamAccount $scratch 0 0 '' }
    [IO.File]::WriteAllText($metadata, 'malformed')
    Must-Reject { Resolve-SteamAccount $scratch 0 0 '' }
    Write-Host 'Steam account resolution: registry zero/missing, explicit selection, saved auto-login, recent, missing directory and ambiguity checks passed.'
    $game = Join-Path $scratch 'game'
    $null = [IO.Directory]::CreateDirectory($game)
    $vdf = Join-Path $scratch 'userdata/1/config/shortcuts.vdf'
    $removeFixture = Read-Shortcuts $original
    $removeFixture.shortcuts['1'] = [ordered]@{appid=[uint32]2147483649; AppName='Astral Party - Mod'; exe=('"' + (Join-Path $game 'BetterAstralParty-Launcher.exe') + '"'); LaunchOptions=''}
    $removeFixture.shortcuts['2'] = [ordered]@{appid=[uint32]2147483650; AppName='Astral Party - Mod'; exe='"C:\Other\BetterAstralParty-Launcher.exe"'; LaunchOptions=''}
    [IO.File]::WriteAllBytes($vdf, (ConvertTo-ShortcutBytes $removeFixture))
    function Get-ItemProperty { param($Path,$ErrorAction); [pscustomobject]@{ActiveUser=0; AutoLoginUser=''} }
    function Get-Process { param($Name,$ErrorAction) }
    $before = (Get-FileHash -LiteralPath $vdf).Hash
    if (!(& $file -Mode PlanRemove -GameRoot $game -SteamRoot $scratch -AccountId 1) -or
        (Get-FileHash -LiteralPath $vdf).Hash -ne $before) { throw 'Removal preview modified shortcuts' }
    function Get-Process { param($Name,$ErrorAction); [pscustomobject]@{Id=10;ProcessName='steam';Path=(Join-Path $scratch 'steam.exe');SessionId=[Diagnostics.Process]::GetCurrentProcess().SessionId;StartTime=[datetime]'2026-01-01';HasExited=$false} }
    Must-Reject { & $file -Mode Remove -GameRoot $game -SteamRoot $scratch -AccountId 1 }
    if ((Get-FileHash -LiteralPath $vdf).Hash -ne $before) { throw 'Running Steam removal changed shortcuts' }
    function Get-Process { param($Name,$ErrorAction); [pscustomobject]@{Id=11;ProcessName='steam';Path=$null;SessionId=[Diagnostics.Process]::GetCurrentProcess().SessionId;StartTime=[datetime]'2026-01-01';HasExited=$false} }
    try { & $file -Mode Remove -GameRoot $game -SteamRoot $scratch -AccountId 1; throw 'Expected unknown ownership refusal' }
    catch {
        $context=$_.Exception.Data['BapSteamDiagnostic'] | ConvertFrom-Json
        if ($context.reason -ne 'SteamOwnershipUnknown' -or $context.phase -ne 'ShortcutPreflight') { throw }
    }
    if ((Get-FileHash -LiteralPath $vdf).Hash -ne $before) { throw 'Unknown ownership removal changed shortcuts' }
    function Get-Process { param($Name,$ErrorAction); [pscustomobject]@{Id=12;ProcessName='steam';Path='C:\unrelated\steam.exe';SessionId=[Diagnostics.Process]::GetCurrentProcess().SessionId;StartTime=[datetime]'2026-01-01';HasExited=$false} }
    $installedShortcut=Join-Path $game 'steam-shortcut.ps1'
    Copy-Item -LiteralPath $file -Destination $installedShortcut
    if (Test-Path -LiteralPath (Join-Path $game 'steam-session.ps1')) { throw 'Standalone installed guard fixture accidentally has package helper' }
    $removed = & $installedShortcut -Mode Remove -GameRoot $game -SteamRoot $scratch -AccountId 1
    $remaining = Read-Shortcuts ([IO.File]::ReadAllBytes($vdf))
    if ($remaining.shortcuts.Count -ne 2 -or $remaining.shortcuts['0'].exe -ne $fixture.shortcuts['0'].exe -or
        $remaining.shortcuts['2'].appid -ne [uint32]2147483650 -or
        (Get-FileHash -LiteralPath $removed.Backup).Hash -ne $before) { throw 'Selective shortcut removal/backup failed' }
    if (& $file -Mode PlanRemove -GameRoot $game -SteamRoot $scratch -AccountId 1) { throw 'Removed shortcut still detected' }
    & $file -Mode Remove -GameRoot $game -SteamRoot $scratch -AccountId 1
    # A selected client appearing after staging must not replace userdata or its backup.
    [IO.File]::WriteAllBytes($vdf, (ConvertTo-ShortcutBytes $removeFixture))
    $before=(Get-FileHash -LiteralPath $vdf).Hash
    $commitProbe=@{Reads=0}
    function Get-Process { param($Name,$ErrorAction)
        $commitProbe.Reads++
        if ($commitProbe.Reads -gt 1) { [pscustomobject]@{Id=13;ProcessName='steam';Path=(Join-Path $scratch 'steam.exe');SessionId=[Diagnostics.Process]::GetCurrentProcess().SessionId;StartTime=[datetime]'2026-01-01';HasExited=$false} }
    }
    try { & $file -Mode Remove -GameRoot $game -SteamRoot $scratch -AccountId 1; throw 'Expected commit Steam refusal' }
    catch {
        $context=$_.Exception.Data['BapSteamDiagnostic'] | ConvertFrom-Json
        if ($context.reason -ne 'SteamRunning' -or $context.phase -ne 'ShortcutCommit') { throw }
    }
    if ((Get-FileHash -LiteralPath $vdf).Hash -ne $before) { throw 'Steam appeared at commit; userdata changed' }
    Write-Host 'PASS: exact-path shortcut removal, same-name foreign shortcut preserved, backup, preview, scoped running/unknown rejection, other-root Steam acceptance, late-client commit guard and repeat removal.'
} finally {
    if (![IO.Path]::GetFullPath($scratch).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture cleanup' }
    Remove-Item -LiteralPath $scratch -Recurse -Force
}
