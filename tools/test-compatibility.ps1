$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fixture = Join-Path $root ('artifacts/compatibility-tests/' + [guid]::NewGuid().ToString('N'))
$cache = Join-Path $fixture 'cache'
New-Item -ItemType Directory -Path $cache -Force | Out-Null
$manifest = Join-Path $fixture 'baseline.json'
$paths = @('AstralParty_INT.exe','GameAssembly.dll','UnityPlayer.dll','winhttp.dll',
    'AstralParty_INT_Data/StreamingAssets/aa/catalog.bundle', 'AstralParty_INT_Data/data.unity3d')
$entries = @()
$resourcePath = 'AstralParty_INT_Data/data.unity3d'
$resourceOriginal = "UnityFS`0" + ('fixture-only' * 4)
foreach ($path in $paths) {
    $full = Join-Path $fixture $path
    New-Item -ItemType Directory -Path (Split-Path -Parent $full) -Force | Out-Null
    [IO.File]::WriteAllText($full, $(if ($path -eq $resourcePath) { $resourceOriginal } else { 'fixture-only' }))
    $entries += @{ root='game'; path=$path; kind='fixture'; sha256=(Get-FileHash $full).Hash }
}
$baseline = @{ schema=1; files=$entries; cacheCatalogs=@() }
$baseline | ConvertTo-Json -Depth 5 | Set-Content $manifest -Encoding UTF8
function Expect($allowed, $label) {
    $report = & (Join-Path $PSScriptRoot 'check-compatibility.ps1') -GameRoot $fixture -CacheRoot $cache -Manifest $manifest -CheckOnly
    if ($report.Allowed -ne $allowed) { throw "$label failed: $($report | ConvertTo-Json -Compress)" }
}
Expect $true 'unchanged'
foreach ($path in $paths) {
    $full = Join-Path $fixture $path
    [IO.File]::WriteAllText($full, 'changed')
    Expect $false ('changed ' + $path)
    [IO.File]::WriteAllText($full, $(if ($path -eq $resourcePath) { $resourceOriginal } else { 'fixture-only' }))
}
$resourceFile = Join-Path $fixture $resourcePath
[IO.File]::WriteAllText($resourceFile, "UnityFS`0" + ('font-change' * 4))
Expect $true 'resource-only changes are advisory'
$report = & (Join-Path $PSScriptRoot 'check-compatibility.ps1') -GameRoot $fixture -CacheRoot $cache -Manifest $manifest -CheckOnly
if ($report.Warnings.Count -ne 1) { throw 'Resource change warning missing' }
Move-Item -LiteralPath $resourceFile -Destination (Join-Path $fixture 'resource-backup')
Expect $false 'missing resource'
Move-Item -LiteralPath (Join-Path $fixture 'resource-backup') -Destination $resourceFile
[IO.File]::WriteAllText($resourceFile, '')
Expect $false 'empty resource'
[IO.File]::WriteAllText($resourceFile, $resourceOriginal)
# A misleading kind must never downgrade executable hash checks.
$baseline.files[1].kind = 'resources-review-required'
$baseline | ConvertTo-Json -Depth 5 | Set-Content $manifest -Encoding UTF8
[IO.File]::WriteAllText((Join-Path $fixture 'GameAssembly.dll'), 'changed')
Expect $false 'code disguised as resource'
[IO.File]::WriteAllText((Join-Path $fixture 'GameAssembly.dll'), 'fixture-only')
Move-Item -LiteralPath (Join-Path $fixture 'GameAssembly.dll') -Destination (Join-Path $fixture 'missing.dll')
Expect $false 'missing native code'
Move-Item -LiteralPath (Join-Path $fixture 'missing.dll') -Destination (Join-Path $fixture 'GameAssembly.dll')
[IO.File]::WriteAllText((Join-Path $cache 'catalog_new.hash'), 'new-version')
Expect $false 'new downloaded catalog'
Move-Item -LiteralPath (Join-Path $cache 'catalog_new.hash') -Destination (Join-Path $fixture 'catalog_new.hash')
Expect $true 'restored'
# Fresh install checks may use only missing bundled loader files.
$loader = Join-Path $fixture 'bundled-loader'
New-Item -ItemType Directory -Path $loader | Out-Null
Move-Item -LiteralPath (Join-Path $fixture 'winhttp.dll') -Destination $loader
function ExpectLoader($allowed, $label) {
    $report = & (Join-Path $PSScriptRoot 'check-compatibility.ps1') -GameRoot $fixture -CacheRoot $cache -Manifest $manifest -LoaderRoot $loader -CheckOnly
    if ($report.Allowed -ne $allowed) { throw "$label failed" }
}
Expect $false 'runtime cannot use bundled loader'
ExpectLoader $true 'fresh bundled loader'
[IO.File]::WriteAllText((Join-Path $loader 'winhttp.dll'), 'wrong-loader')
ExpectLoader $false 'bundled loader hash enforced'
[IO.File]::WriteAllText((Join-Path $loader 'winhttp.dll'), 'fixture-only')
[IO.File]::WriteAllText((Join-Path $fixture 'winhttp.dll'), 'existing-wrong-loader')
ExpectLoader $false 'existing mismatch never replaced'
Move-Item -LiteralPath (Join-Path $fixture 'winhttp.dll') -Destination (Join-Path $fixture 'wrong-loader.dll')
[IO.File]::WriteAllText((Join-Path $fixture 'doorstop_config.ini'), 'installed')
ExpectLoader $false 'partial existing installation blocked'
Move-Item -LiteralPath (Join-Path $fixture 'doorstop_config.ini') -Destination (Join-Path $fixture 'saved-doorstop.ini')
Move-Item -LiteralPath (Join-Path $fixture 'GameAssembly.dll') -Destination (Join-Path $loader 'GameAssembly.dll')
ExpectLoader $false 'game assets never substituted'
Move-Item -LiteralPath (Join-Path $loader 'GameAssembly.dll') -Destination $fixture
Move-Item -LiteralPath (Join-Path $loader 'winhttp.dll') -Destination $fixture
Expect $true 'restored after fresh-install checks'
$baseline.files[0].path = '../outside.exe'
$baseline | ConvertTo-Json -Depth 5 | Set-Content $manifest -Encoding UTF8
Expect $false 'path escape'
[IO.File]::WriteAllText($manifest, '{invalid')
Expect $false 'corrupt manifest'
$launcher = Get-Content (Join-Path $PSScriptRoot 'SteamLauncher.cs') -Raw
if ($launcher.IndexOf('check-compatibility.ps1') -gt $launcher.IndexOf('--doorstop-enabled true') -or
    !$launcher.Contains('if (check.ExitCode != 0)') -or !$launcher.Contains('check.WaitForExit()') -or !$launcher.Contains('start.EnvironmentVariables["BAP_COMPATIBILITY_CHECKED"]')) {
    throw 'Preloader gate missing'
}
$plugin = Get-Content (Join-Path $root 'src/Plugin.cs') -Raw
if ($plugin.Contains('.PatchAll()') -or !$plugin.Contains('harmony.UnpatchSelf()') -or
    !$plugin.Contains('BAP_COMPATIBILITY_CHECKED')) { throw 'Patch isolation or direct-launch gate missing' }
$runtime = Get-Content (Join-Path $root 'src/RuntimeObject.cs') -Raw
foreach ($guard in @('CheckArgument(IL2CPP.il2cpp_method_get_param', 'CheckValue<T>(Class)',
    'il2cpp_type_is_byref', 'il2cpp_class_is_assignable_from', 'il2cpp_class_value_size')) {
    if (!$runtime.Contains($guard)) { throw "Native call guard missing: $guard" }
}
Write-Host 'Compatibility: resource-only change warns; malformed/missing resources, code/engine/catalog changes and invalid manifests block; isolated fixtures only.'
