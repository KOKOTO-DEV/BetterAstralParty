param(
    [string]$GameRoot = $PSScriptRoot,
    [string]$CacheRoot = (Join-Path $env:USERPROFILE 'AppData/LocalLow/feimo/AstralParty_INT/com.unity.addressables'),
    [string]$Manifest = (Join-Path $PSScriptRoot 'BetterAstralParty.compatibility.json'),
    [string]$LoaderRoot,
    [switch]$CheckOnly
)
$ErrorActionPreference = 'Stop'

function Test-BapCatalogInventory([string[]]$Expected,[string[]]$Actual) {
    if($Expected.Count -gt 128 -or $Actual.Count -gt 512){return $false}
    $required=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $present=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($name in $Expected){if(!$required.Add($name)){return $false}}
    foreach($name in $Actual){if(!$present.Add($name)){return $false}}
    if(!$required.IsSubsetOf($present)){return $false}
    $extra=@($Actual|Where-Object {!$required.Contains($_)})
    if(!$extra.Count){return $true}
    $pattern='\Acatalog_((?:0|[1-9][0-9]{0,8})\.(?:0|[1-9][0-9]{0,8})\.(?:0|[1-9][0-9]{0,8}))\.(?:json|hash)\z'
    if($Expected.Count -ne 2 -or $Expected[0] -cnotmatch $pattern){return $false}
    $active=[version]$Matches[1];$stem='catalog_'+$active
    if(!$required.Contains($stem+'.json') -or !$required.Contains($stem+'.hash')){return $false}
    # Retain old, unselected caches; current pair hashes remain mandatory above.
    foreach($name in $extra){if($name -cnotmatch $pattern -or ([version]$Matches[1]).CompareTo($active) -ge 0){return $false}}
    return $true
}

function Test-BapResourceCatalogInventory([string[]]$Expected,[string[]]$Actual) {
    if($Expected.Count -ne 2 -or $Actual.Count -gt 512){return $false}
    $pattern='\Acatalog_((?:0|[1-9][0-9]{0,8})\.(?:0|[1-9][0-9]{0,8})\.(?:0|[1-9][0-9]{0,8}))\.(?:json|hash)\z'
    if($Expected[0] -cnotmatch $pattern){return $false}
    $baseline=[version]$Matches[1]
    $stem='catalog_'+$baseline
    if($Expected -cnotcontains ($stem+'.json') -or $Expected -cnotcontains ($stem+'.hash') -or
        (@($Expected|Sort-Object -Unique).Count -ne 2)){return $false}
    $present=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($name in $Actual){
        if($name -cnotmatch $pattern -or !$present.Add($name)){return $false}
    }
    foreach($name in $Actual){
        $null=($name -cmatch $pattern)
        $version=[version]$Matches[1]
        if($version.CompareTo($baseline) -ge 0){
            $base='catalog_'+$version
            if($present.Contains($base+'.json') -and $present.Contains($base+'.hash')){return $true}
        }
    }
    return $false
}

function Test-ContentShape([string]$Path,[string]$Key) {
    $size=(Get-Item -LiteralPath $Path).Length
    if($Key -in @('game/AstralParty_INT_Data/data.unity3d','game/AstralParty_INT_Data/StreamingAssets/aa/catalog.bundle')) {
        $stream=[IO.File]::OpenRead($Path)
        try {
            $header=New-Object byte[] 8
            return ($stream.Length -ge 32 -and $stream.Read($header,0,8) -eq 8 -and
                [Text.Encoding]::ASCII.GetString($header) -eq "UnityFS`0")
        } finally {$stream.Dispose()}
    }
    if($Key -match '\.json\z') {
        if($size -le 0 -or $size -gt 64MB){return $false}
        try {$value=Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
             return ($null -ne $value -and $value -is [PSCustomObject]) }
        catch {return $false}
    }
    if($Key -match '\.hash\z') {
        if($size -le 0 -or $size -gt 4096){return $false}
        $value=(Get-Content -LiteralPath $Path -Raw).Trim()
        return ($value.Length -gt 0 -and $value -notmatch '[\x00-\x1F\x7F]')
    }
    return $false
}

function Get-CompatibilityReport {
    $issues = [Collections.Generic.List[string]]::new()
    $warnings = [Collections.Generic.List[string]]::new()
    try {
        $baseline = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
        if ($baseline.schema -ne 1 -or @($baseline.files).Count -lt 5) { throw 'Invalid or empty compatibility manifest' }
        $seen = @{}
        foreach ($entry in $baseline.files) {
            if ($entry.root -notin @('game', 'cache') -or [IO.Path]::IsPathRooted($entry.path) -or
                $entry.path -match '(^|[\\/])\.\.([\\/]|$)' -or $entry.path -match ':' -or
                $entry.sha256 -notmatch '^[A-Fa-f0-9]{64}$') { throw 'Invalid manifest entry' }
            $key = $entry.root + '/' + $entry.path
            if ($seen.ContainsKey($key)) { throw 'Duplicate manifest entry' }
            $seen[$key] = $true
            $root = if ($entry.root -eq 'game') { $GameRoot } else { $CacheRoot }
            $path = Join-Path $root $entry.path
            if ($LoaderRoot -and !(Test-Path -LiteralPath (Join-Path $GameRoot 'doorstop_config.ini')) -and
                !(Test-Path -LiteralPath $path) -and $entry.root -eq 'game' -and
                ($entry.path -eq 'winhttp.dll' -or $entry.path -match '^BepInEx/core/[^/\\]+\.dll$')) {
                $path = Join-Path $LoaderRoot $entry.path
            }
            $mutable=$key -in @('game/AstralParty_INT_Data/data.unity3d',
                'game/AstralParty_INT_Data/StreamingAssets/aa/settings.json',
                'game/AstralParty_INT_Data/StreamingAssets/aa/catalog.bundle') -or
                ($entry.root -eq 'cache' -and $entry.path -cmatch '^catalog_[0-9]+\.[0-9]+\.[0-9]+\.(json|hash)$')
            if (!(Test-Path -LiteralPath $path -PathType Leaf)) {
                if ($entry.root -ne 'cache') {$issues.Add("Missing [$($entry.kind)]: $key")}
                continue
            }
            $same=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -eq $entry.sha256
            if (($mutable -and !$same) -or $key -eq 'game/AstralParty_INT_Data/data.unity3d') {
                if (!(Test-ContentShape $path $key)) {$issues.Add("Malformed resource: $key")}
            }
            if (!$same) {
                if ($mutable) {$warnings.Add("Content changed; runtime guards remain enabled: $key")}
                else {$issues.Add("Changed [$($entry.kind)]: $key")}
            }
        }
        foreach ($required in @('game/AstralParty_INT.exe','game/GameAssembly.dll','game/UnityPlayer.dll',
            'game/winhttp.dll','game/AstralParty_INT_Data/il2cpp_data/Metadata/global-metadata.dat',
            'game/AstralParty_INT_Data/StreamingAssets/aa/settings.json',
            'game/AstralParty_INT_Data/StreamingAssets/aa/catalog.bundle',
            'game/AstralParty_INT_Data/data.unity3d')) {
            if (!$seen.ContainsKey($required)) { throw "Missing required manifest entry: $required" }
        }
        $catalogs = @(Get-ChildItem -LiteralPath $CacheRoot -File -ErrorAction Stop |
            Where-Object { $_.Name -match '^catalog.*\.(json|hash)$' } | ForEach-Object Name | Sort-Object)
        if (!(Test-BapResourceCatalogInventory @($baseline.cacheCatalogs) $catalogs)) {
            $issues.Add("Invalid or incomplete active Addressables catalog pair")
        } else {
            # Check the newest complete cache pair even when not included in the old review.
            $pattern='^catalog_((?:0|[1-9][0-9]{0,8})\.(?:0|[1-9][0-9]{0,8})\.(?:0|[1-9][0-9]{0,8}))\.(json|hash)$'
            $versions=@(foreach($name in $catalogs){if($name -cmatch $pattern){[version]$Matches[1]}}) | Sort-Object -Unique -Descending
            foreach($v in $versions){
                $stem='catalog_'+$v
                if($catalogs -ccontains ($stem+'.json') -and $catalogs -ccontains ($stem+'.hash')){
                    foreach($suffix in @('.json','.hash')){
                        $key='cache/'+$stem+$suffix
                        if(!(Test-ContentShape (Join-Path $CacheRoot ($stem+$suffix)) $key)){$issues.Add("Malformed active catalog: $key")}
                    }
                    if($stem -ne ('catalog_'+([version](($baseline.cacheCatalogs[0] -replace '^catalog_([0-9.]+)\.(json|hash)$','$1'))))) {
                        $warnings.Add("Newer content catalog: $stem")
                    }
                    break
                }
            }
        }

    } catch { $issues.Add("Check failed: $($_.Exception.Message)") }
    [pscustomobject]@{ Allowed = ($issues.Count -eq 0); Issues = @($issues.ToArray()); Warnings = @($warnings.ToArray()) }
}

$report = Get-CompatibilityReport
if ($CheckOnly) { return $report }
$lines = @("BetterAstralParty compatibility check: $(Get-Date -Format o)", "Allowed: $($report.Allowed)") + $report.Issues
$lines += @($report.Warnings | ForEach-Object { "Warning: $_" })
try { $lines | Set-Content -LiteralPath (Join-Path $GameRoot 'BetterAstralParty-Compatibility.log') -Encoding UTF8 }
catch { Write-Warning 'Could not save compatibility log.' }
foreach ($warning in $report.Warnings) { Write-Warning $warning }
if (!$report.Allowed) {
    $lines | ForEach-Object { Write-Host $_ }
    Write-Host 'Mod launch blocked. No game files were changed.'
    Write-Host 'Use AstralParty-Vanilla.cmd, or install a mod build reviewed for this game/translation version.'
    exit 2
}
exit 0
