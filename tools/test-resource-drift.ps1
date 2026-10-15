# Synthetic, isolated checks for the rolling content policy. Does not read or write any game.
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$work=Join-Path ([IO.Path]::GetTempPath()) ('BapResourceDrift-'+[guid]::NewGuid().ToString('N'))
$cache=Join-Path $work 'cache'
New-Item -ItemType Directory -Path $cache -Force | Out-Null
$manifest=Join-Path $work 'review.json'
$gameFiles=@(
  'AstralParty_INT.exe','GameAssembly.dll','UnityPlayer.dll','winhttp.dll',
  'AstralParty_INT_Data/il2cpp_data/Metadata/global-metadata.dat',
  'AstralParty_INT_Data/StreamingAssets/aa/settings.json',
  'AstralParty_INT_Data/StreamingAssets/aa/catalog.bundle',
  'AstralParty_INT_Data/data.unity3d'
)
$pair=@('catalog_3.3.0.hash','catalog_3.3.0.json')
$entries=@()
foreach($item in $gameFiles) {
    $path=Join-Path $work $item
    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    $bytes=if($item -match '(data\.unity3d|catalog\.bundle)$') {
        $b=New-Object byte[] 64
        [Text.Encoding]::ASCII.GetBytes("UnityFS`0").CopyTo($b,0)
        $b
    } elseif($item -match 'settings\.json$') {
        [Text.Encoding]::UTF8.GetBytes('{"m_CatalogLocations":[]}')
    } else {[Text.Encoding]::UTF8.GetBytes('synthetic runtime baseline')}
    [IO.File]::WriteAllBytes($path,$bytes)
    $entries+=@{root='game';path=$item;kind='fixture';sha256=(Get-FileHash $path -Algorithm SHA256).Hash}
}
foreach($name in $pair) {
    $path=Join-Path $cache $name
    $body=if($name.EndsWith('.json')) {'{"m_LocatorId":"fixture"}'} else {'0123456789abcdef0123456789abcdef'}
    [IO.File]::WriteAllText($path,$body)
    $entries+=@{root='cache';path=$name;kind='fixture';sha256=(Get-FileHash $path -Algorithm SHA256).Hash}
}
@{schema=1;files=$entries;cacheCatalogs=$pair} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifest -Encoding UTF8
function Expect([bool]$expected,[string]$label) {
    $report = & (Join-Path $PSScriptRoot 'check-compatibility.ps1') -GameRoot $work -CacheRoot $cache -Manifest $manifest -CheckOnly
    if($report.Allowed -ne $expected){throw "$label failed: $($report|ConvertTo-Json -Compress)"}
    Write-Host ('PASS: '+$label)
}
try {
    Expect $true 'baseline accepted'
    $setting=Join-Path $work 'AstralParty_INT_Data/StreamingAssets/aa/settings.json'
    [IO.File]::WriteAllText($setting,'{"m_CatalogLocations":["content-only"]}')
    Expect $true 'valid settings drift warns, not blocks'
    [IO.File]::WriteAllText((Join-Path $cache 'catalog_3.3.0.json'),'{"m_LocatorId":"updated"}')
    Expect $true 'valid same-version catalog drift warns'
    foreach($name in @('catalog_3.3.1.json','catalog_3.3.1.hash')) {
        $body=if($name.EndsWith('.json')){'{"m_LocatorId":"new"}'}else{'0123456789abcdef0123456789abcdef'}
        [IO.File]::WriteAllText((Join-Path $cache $name),$body)
    }
    Expect $true 'new complete catalog pair accepted'
    foreach($name in $pair){Remove-Item -LiteralPath (Join-Path $cache $name)}
    Expect $true 'superseded cache baseline not required'
    [IO.File]::WriteAllText((Join-Path $work 'GameAssembly.dll'),'changed engine')
    Expect $false 'native code change blocks'
    [IO.File]::WriteAllText((Join-Path $cache 'catalog_3.3.1.json'),'not json')
    Expect $false 'malformed active catalog blocks'
    Write-Host 'Synthetic resource-drift policy checks PASS.'
} finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
