$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'find-game.ps1')
. (Join-Path $PSScriptRoot 'install-log.ps1')
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('bap-discovery-' + [guid]::NewGuid().ToString('N'))
$savedLocal = $env:LOCALAPPDATA
$passed = $false
New-Item -ItemType Directory -Path $scratch | Out-Null
function MakeGame([string]$path) {
    New-Item -ItemType Directory -Force -Path $path | Out-Null
    [IO.File]::WriteAllText((Join-Path $path 'AstralParty_INT.exe'), 'fixture, not executable')
}
try {
    $env:LOCALAPPDATA = Join-Path $scratch 'Local'
    $steam = Join-Path $scratch 'Steam'
    $game = Join-Path $steam 'steamapps/common/Astral Party/8vJXnINT'
    MakeGame $game
    $vdf = Join-Path $steam 'steamapps/libraryfolders.vdf'
    [IO.File]::WriteAllText($vdf, ('"path" "' + $steam.Replace('\', '\\') + '"'))
    $package = Join-Path $scratch 'Desktop/Beta'
    $absentDrive = [char[]](65..90) | Where-Object { !(Test-Path -LiteralPath ("${_}:\") -PathType Container) } | Select-Object -First 1
    if (!$absentDrive) { throw 'Fixture requires an unavailable drive' }
    $absentLibrary = "${absentDrive}:\BapMissingLibrary"
    $missingLibrary = Join-Path $scratch 'Disconnected Library'
    [IO.File]::WriteAllText($vdf, ('"path" "' + $absentLibrary.Replace('\', '\\') + '" "path" "' +
        $steam.Replace('\', '\\') + '" "path" "' + $missingLibrary.Replace('\', '\\') + '" "path" "' +
        $absentLibrary.Replace('\', '\\') + '"'))
    if (Resolve-IntGameDirectory $absentLibrary) { throw 'Unavailable-drive game input accepted' }
    if (@(Find-IntGameDirectories $absentLibrary $absentLibrary).Count) { throw 'Unavailable-drive inputs produced a candidate' }
    if (@(Find-IntGameDirectories $absentLibrary (Join-Path $game 'Beta')).Count -ne 1) { throw 'Unavailable Steam drive blocked nearby discovery' }
    # Reproduces registry forward slash + VDF backslash duplicate candidates.
    $found = @(Find-IntGameDirectories $steam.Replace('\', '/') $package)
    if ($found.Count -ne 1 -or $found[0] -ne $game) { throw 'Slash-normalized unique detection failed' }
    $found = @(Find-IntGameDirectories ($steam.ToUpper() + '\') $game)
    if ($found.Count -ne 1) { throw 'Case/trailing slash/package duplicates failed' }
    if ((Resolve-IntGameDirectory ('"' + (Split-Path $game -Parent) + '"')) -ne $game) { throw 'Quoted parent input failed' }
    $other = Join-Path $scratch 'Library 2'
    $otherGame = Join-Path $other 'steamapps/common/Custom Astral/8vJXnINT'
    MakeGame $otherGame
    [IO.File]::WriteAllText((Join-Path $other 'steamapps/appmanifest_2622000.acf'), '"installdir" "Custom Astral"')
    [IO.File]::AppendAllText($vdf, (' "path" "' + $other.Replace('\', '\\') + '"'))
    $found = @(Find-IntGameDirectories $steam $package)
    if ($found.Count -ne 2 -or $found -notcontains $otherGame) { throw 'Multiple library/manifest discovery failed' }
    $missing = Join-Path $scratch 'MissingSteam'
    if (@(Find-IntGameDirectories $missing $package).Count -ne 0) { throw 'Missing game must not produce a candidate' }
    if (@(Find-IntGameDirectories $missing (Join-Path $game 'Beta')).Count -ne 1) { throw 'Nearby package discovery failed' }
    $cn = Join-Path $scratch 'CN'
    New-Item -ItemType Directory -Path $cn | Out-Null
    [IO.File]::WriteAllText((Join-Path $cn 'AstralParty_CN.exe'), 'fixture')
    if (Resolve-IntGameDirectory $cn) { throw 'CN accepted as INT' }
    $unicodeLibrary = Join-Path $scratch ([string][char]0xAC00 + ' library [2]')
    $unicodeName = [string][char]0xB098 + ' game'
    $unicodeGame = Join-Path $unicodeLibrary ('steamapps/common/' + $unicodeName + '/8vJXnINT')
    MakeGame $unicodeGame
    foreach ($bom in @($false, $true)) {
        $encoding = [Text.UTF8Encoding]::new($bom)
        [IO.File]::WriteAllText($vdf, ('"path" "' + $unicodeLibrary.Replace('\', '\\') + '"'), $encoding)
        [IO.File]::WriteAllText((Join-Path $unicodeLibrary 'steamapps/appmanifest_2622000.acf'), ('"installdir" "' + $unicodeName + '"'), $encoding)
        $found = @(Find-IntGameDirectories $steam $package)
        if ($found.Count -ne 2 -or $found -notcontains $unicodeGame) { throw ('UTF8 Unicode metadata discovery failed; BOM=' + $bom) }
    }
    $blocked = [IO.File]::Open($vdf, 'Open', 'ReadWrite', 'None')
    try {
        $found = @(Find-IntGameDirectories $steam $package)
        if ($found.Count -ne 1 -or $found[0] -ne $game) { throw 'Unreadable metadata blocked another valid installation' }
    } finally { $blocked.Dispose() }
    $logs = @(Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA 'BetterAstralParty/Logs') -File -Filter 'BetterAstralParty-InstallError-*.log')
    if ($logs.Count -ne 1) { throw 'Metadata read failure was not recorded once in the existing collected log scope' }
    $text = Get-Content -LiteralPath $logs[0].FullName -Raw -Encoding UTF8
    if ($text -notmatch 'Code: BAP-INSTALL-WAITING' -or $text -notmatch 'Stage: INT discovery metadata read: LibraryFolders' -or
        $text -notmatch 'DiagnosticCoverage:' -or $text.Contains($env:USERPROFILE) -or $text.Contains('"installdir"')) {
        throw 'Discovery diagnostic reason, bounded coverage or privacy changed'
    }
    $passed = $true
    Write-Output 'PASS: unavailable drives/libraries, slash/case duplicates, package location, manifest, multiple/missing installs, quoted parent and CN rejection.'
    Write-Output 'PASS: Unicode UTF8 metadata with/without BOM; sharing-denied metadata retains discovery and emits bounded/redacted collector-compatible evidence.'
} finally {
    $env:LOCALAPPDATA = $savedLocal
    $resolved = [IO.Path]::GetFullPath($scratch)
    if ((Split-Path $resolved -Parent) -ne [IO.Path]::GetTempPath().TrimEnd('\') -or
        (Split-Path $resolved -Leaf) -notlike 'bap-discovery-*') { throw 'Unsafe fixture cleanup' }
    if ($passed) { Remove-Item -LiteralPath $resolved -Recurse -Force }
    else { Write-Host ('Fixture evidence retained: ' + $resolved) }
}
