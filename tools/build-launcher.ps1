param([string]$OutputDirectory,[string]$DotnetRoot)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$dotnetRootPath = if ($DotnetRoot) { [IO.Path]::GetFullPath($DotnetRoot) } else { Join-Path $root '.dotnet' }
$artifactDir = if ($OutputDirectory) { [IO.Path]::GetFullPath($OutputDirectory) } else { Join-Path $root 'artifacts' }
$null = New-Item -ItemType Directory -Force -Path $artifactDir
$dotnet = Join-Path $dotnetRootPath 'dotnet.exe'
$sdk = @(Get-ChildItem -LiteralPath (Join-Path $dotnetRootPath 'sdk') -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'Roslyn/bincore/csc.dll') } | Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1)
if ($sdk.Count -ne 1) { throw '현대 C# 컴파일러가 필요합니다. / Local Roslyn compiler required.' }
$compiler = Join-Path $sdk[0].FullName 'Roslyn/bincore/csc.dll'
$framework = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319'
$references = @('mscorlib.dll','System.dll','System.Core.dll','System.Security.dll','System.Windows.Forms.dll','System.Net.Http.dll','System.IO.Compression.dll','System.IO.Compression.FileSystem.dll')
$arguments = @('/nologo','/noconfig','/nostdlib+','/langversion:latest','/nullable:enable','/define:NETFRAMEWORK','/warnaserror+','/deterministic+',('/pathmap:'+$root+'=/src/BetterAstralParty'),'/target:winexe','/platform:x64','/main:SteamLauncher',('/out:' + (Join-Path $artifactDir 'BetterAstralParty-Launcher.exe')))
foreach ($name in $references) {
    $reference = Join-Path $framework $name
    if (!(Test-Path -LiteralPath $reference -PathType Leaf)) { throw "Framework reference missing: $name" }
    $arguments += '/reference:' + $reference
}
$arguments += Join-Path $PSScriptRoot 'SteamLauncher.cs'
$arguments += Join-Path $PSScriptRoot 'InstallHelperBootstrap.cs'
$arguments += @(Get-ChildItem -LiteralPath (Join-Path $root 'updater') -Filter '*.cs' -File | Where-Object Name -ne 'UpdateHelperProgram.cs' | Sort-Object Name | ForEach-Object FullName)
$arguments += @(Get-ChildItem -LiteralPath (Join-Path $root 'src/Observability') -Filter '*.cs' -File | Sort-Object Name | ForEach-Object FullName)
$arguments += Join-Path $root 'diagnostics/MinimalDiagnosticProjection.cs'
$bootstrapLeases=[Collections.Generic.List[IO.FileStream]]::new()
try {
    $manifest=[IO.File]::Open((Join-Path $root 'helper-delivery.json'),'Open','Read','Read');$bootstrapLeases.Add($manifest)
    $reader=[IO.StreamReader]::new($manifest,[Text.UTF8Encoding]::new($false,$true),$true,4096,$true)
    try {$delivery=$reader.ReadToEnd()|ConvertFrom-Json} finally {$reader.Dispose()}
    if($delivery.schema -ne 1 -or @($delivery.files).Count -ne 3 -or (@($delivery.files.resource|Sort-Object) -join '|') -cne 'descriptor|image|signature'){throw 'Invalid helper bootstrap manifest.'}
    foreach($row in $delivery.files){
        if($row.path -cnotmatch '\Ahelper-bootstrap/current/(?:image\.exe|descriptor|signature)\z' -or $row.sha256 -cnotmatch '\A[A-F0-9]{64}\z'){throw 'Invalid helper bootstrap input.'}
        $path=Join-Path $root $row.path;$lease=[IO.File]::Open($path,'Open','Read','Read');$bootstrapLeases.Add($lease)
        if($lease.Length -lt 1 -or $lease.Length -gt 8MB -or (Get-FileHash -InputStream $lease -Algorithm SHA256).Hash -cne $row.sha256){throw 'Changed helper bootstrap input.'}
        $arguments+=('/resource:'+$path+',BetterAstralParty.HelperBootstrap.'+$row.resource)
    }
    & $dotnet $compiler @arguments
    if ($LASTEXITCODE -ne 0) { throw '런처와 업데이트 안전 검사 빌드에 실패했습니다. / Could not build launcher and updater safety components.' }
} finally {foreach($lease in $bootstrapLeases){$lease.Dispose()}}
