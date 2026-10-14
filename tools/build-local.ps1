# Public-source build: compiler outputs only, never an approved/signed installation ZIP.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$GameRoot,
    [Parameter(Mandatory=$true)][string]$BepInExRoot,
    [string]$DotnetRoot = (Join-Path $env:ProgramFiles 'dotnet'),
    [string]$OutputDirectory,
    [switch]$SkipArchive,
    [string]$SigningCertificateThumbprint,
    [string]$TimestampServer
)
$ErrorActionPreference='Stop'
if (!$IsWindows -or ![Environment]::Is64BitProcess -or $PSVersionTable.PSVersion.Major -lt 7) {
    # Do not build Windows-only IL2CPP artifacts on another runtime.
    throw 'PowerShell 7 x64 on Windows is required.'
}
$srcRoot=[IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$game=[IO.Path]::GetFullPath($GameRoot)
$loader=[IO.Path]::GetFullPath($BepInExRoot)
$dotnetRootPath=[IO.Path]::GetFullPath($DotnetRoot)
$dotnet=Join-Path $dotnetRootPath 'dotnet.exe'
$sdkDirectory=Join-Path $dotnetRootPath 'sdk'
if (!(Test-Path -LiteralPath $sdkDirectory -PathType Container)) {
    throw "Missing SDK directory: $sdkDirectory"
}
$sdkCandidates=@(Get-ChildItem -LiteralPath $sdkDirectory -Directory | Where-Object {
    $_.Name -match '^8\.0\.4\d{2}$' -and ([version]$_.Name -ge [version]'8.0.425') -and
    (Test-Path -LiteralPath (Join-Path $_.FullName 'Roslyn\bincore\csc.dll') -PathType Leaf)
} | Sort-Object { [version]$_.Name } -Descending)
if ($sdkCandidates.Count -eq 0) {
    throw 'Missing .NET SDK 8.0.425 or later 8.0.4xx with Roslyn compiler.'
}
$selectedSdkVersion=$sdkCandidates[0].Name
$selectedCompiler=Join-Path $sdkCandidates[0].FullName 'Roslyn\bincore\csc.dll'
foreach($required in @(
    $dotnet,
    $selectedCompiler,
    (Join-Path $game 'AstralParty_INT.exe'),
    (Join-Path $game 'BepInEx\interop\Assembly-CSharp.dll'),
    (Join-Path $loader 'BepInEx\core\BepInEx.Core.dll'),
    (Join-Path $loader 'BepInEx\core\BepInEx.Unity.IL2CPP.dll')
)) {
    if (!(Test-Path -LiteralPath $required -PathType Leaf)) {throw "Missing build prerequisite: $required"}
}
$referencePack=Join-Path $dotnetRootPath 'packs\Microsoft.NETCore.App.Ref\6.0.36'
if (!(Test-Path -LiteralPath $referencePack -PathType Container)) {
    throw "Missing .NET 6 reference pack: $referencePack. Install .NET 6 SDK/targeting pack."
}
$framework=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\mscorlib.dll'
if (!(Test-Path -LiteralPath $framework -PathType Leaf)) {throw "Missing .NET Framework x64 references: $framework"}
if (!$OutputDirectory) {
    $OutputDirectory=Join-Path $srcRoot ('local-build-'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))
}
$out=[IO.Path]::GetFullPath($OutputDirectory)
$sourcePrefix=$srcRoot.TrimEnd('\')+'\'
if ($out -eq $srcRoot -or $srcRoot.StartsWith($out.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) {
    throw 'Build output cannot replace/contain the source root.'
}
foreach ($protected in @($game,$loader)) {
    if ($out -eq $protected -or $out.StartsWith($protected.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) {
        throw 'Build output must not be inside the installed game or clean loader root.'
    }
}
if (Test-Path -LiteralPath $out) {throw 'Output already exists; choose a fresh folder.'}
New-Item -ItemType Directory -Path $out -ErrorAction Stop | Out-Null
$pluginOut=Join-Path $out 'plugin';$launcherOut=Join-Path $out 'launcher';$helperOut=Join-Path $out 'helper'
New-Item -ItemType Directory -Path $pluginOut,$launcherOut -ErrorAction Stop | Out-Null

# Keep SDK/restore writes outside the source tree so source exports remain unmodified.
$obj=(Join-Path $out 'obj')+[IO.Path]::DirectorySeparatorChar
$common=@("-p:GameRoot=$game","-p:BepInExRoot=$loader","-p:BaseIntermediateOutputPath=$obj","-p:MSBuildProjectExtensionsPath=$obj", '-p:NuGetAudit=false','-p:UseSharedCompilation=false')
$project=Join-Path $srcRoot 'src\BetterAstralParty.csproj'
$config=Join-Path $srcRoot 'offline-nuget.config'
$previousHome=$env:DOTNET_CLI_HOME;$previousTelemetry=$env:DOTNET_CLI_TELEMETRY_OPTOUT
try {
    $env:DOTNET_CLI_HOME=Join-Path $out 'dotnet-home'
    $env:DOTNET_CLI_TELEMETRY_OPTOUT='1'
    & $dotnet restore $project --configfile $config @common
    if($LASTEXITCODE -ne 0) {throw 'Plugin restore failed.'}
    & $dotnet build $project -c Release --no-restore -o $pluginOut @common
    if($LASTEXITCODE -ne 0) {throw 'Plugin build failed.'}
    & (Join-Path $PSScriptRoot 'build-launcher.ps1') -DotnetRoot $dotnetRootPath -OutputDirectory $launcherOut
    if($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne $null) {throw 'Launcher build failed.'}
    & (Join-Path $PSScriptRoot 'build-update-helper.ps1') -DotnetRoot $dotnetRootPath -OutputDirectory $helperOut
    if($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne $null) {throw 'Helper build failed.'}
} finally {
    $env:DOTNET_CLI_HOME=$previousHome;$env:DOTNET_CLI_TELEMETRY_OPTOUT=$previousTelemetry
}
$expected=@('plugin\BetterAstralParty.dll','launcher\BetterAstralParty-Launcher.exe','helper\BetterAstralParty-UpdateHelper.exe')
if ($SigningCertificateThumbprint) {
    $thumbprint=$SigningCertificateThumbprint.Replace(' ','').ToUpperInvariant()
    if ($thumbprint -cnotmatch '^[A-F0-9]{40}$') {throw 'Invalid code-signing certificate thumbprint.'}
    $cert=Get-Item -LiteralPath ("Cert:\CurrentUser\My\$thumbprint") -ErrorAction Stop
    $ekus=@($cert.EnhancedKeyUsageList | ForEach-Object { $_.ObjectId.Value })
    if (!$cert.HasPrivateKey -or $cert.NotAfter -le [DateTime]::Now -or $ekus -notcontains '1.3.6.1.5.5.7.3.3') {
        throw 'Valid code-signing certificate with private key required.'
    }
    foreach ($relative in $expected) {
        $image=Join-Path $out $relative
        $params=@{FilePath=$image;Certificate=$cert;HashAlgorithm='SHA256'}
        if ($TimestampServer) { $params.TimestampServer=$TimestampServer }
        $result=Set-AuthenticodeSignature @params
        if ($result.Status -ne 'Valid') {throw ("Authenticode signing failed: $relative / $($result.Status)")}
    }
    Write-Host 'Authenticode signed build outputs (local code-signing certificate).'
}

$artifacts=@(foreach($relative in $expected){
    $file=Join-Path $out $relative
    if(!(Test-Path -LiteralPath $file -PathType Leaf)){throw "Missing compiled output: $file"}
    $signature=Get-AuthenticodeSignature -LiteralPath $file
    [ordered]@{path=$relative.Replace('\','/');size=(Get-Item -LiteralPath $file).Length;sha256=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash;authenticodeStatus=[string]$signature.Status}
})
$manifest=[ordered]@{
    schema=1
    version='1.2.1-local-source-modified'
    inputGame=$game
    inputLoader=$loader
    sdk=$selectedSdkVersion
    artifacts=$artifacts
    containsInstaller=$false
    installerApproved=$false
    updateSignaturesCreated=$false
    notes='Source build only. Do not replace signed installation files without approved local packaging/signing.'
}
$manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $out 'local-build-manifest.json') -Encoding utf8
@'
BetterAstralParty 1.2.1 local-source build output

The DLL/EXEs are compiler results, NOT an installation or update package.
The original install/update chain verifies manifests, release approval, helper
and updater signatures. Never replace those with invented approval records.
Use the documented release pipeline with authorized signing keys for publishing.
Unsigned binaries can trigger SmartScreen/Defender reputation warnings; sign
code with an appropriate Authenticode certificate and submit false positives
with file hashes. Do not disable antivirus or grant blanket directory exclusions.
'@ | Set-Content -LiteralPath (Join-Path $out 'BUILD-NOTICE.txt') -Encoding utf8
if (!$SkipArchive) {
    $archive=$out+'.zip'
    if (Test-Path -LiteralPath $archive) {throw "Output archive already exists: $archive"}
    # Only generated compiler results / manifest, not game DLLs, interop, or credentials.
    Compress-Archive -LiteralPath $pluginOut,$launcherOut,$helperOut,(Join-Path $out 'local-build-manifest.json'),(Join-Path $out 'BUILD-NOTICE.txt') -DestinationPath $archive -CompressionLevel Optimal
    Write-Host ('LOCAL BUILD ZIP (not an installer): '+$archive)
}
Write-Host ('LOCAL BUILD COMPLETE: '+$out)
$artifacts | Format-Table -AutoSize
