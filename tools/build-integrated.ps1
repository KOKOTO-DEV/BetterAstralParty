# The original BetterAstralParty install/update/signing pipeline only.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OriginalRelease,
    [Parameter(Mandatory)][string]$UpstreamArchive,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_-]{1,50}$')][string]$Stage,
    [string]$BuildDirectory,
    [string]$GameRoot,
    [string]$BepInExRoot,
    [string]$DotnetRoot = 'C:\Program Files\dotnet',
    [ValidateSet('Release','LocalInstall')][string]$Scope='Release',
    [string]$SignedInputDirectory,
    [string]$SignedInputManifestSha256,
    [string]$ApprovalRecord,
    [string]$ApprovalSha256
)
$ErrorActionPreference='Stop'
if(!$IsWindows -or ![Environment]::Is64BitProcess -or $PSVersionTable.PSVersion.Major -lt 7){throw 'Windows PowerShell 7 x64 is required.'}
$project=Split-Path -Parent $PSScriptRoot
$py=Get-Command py.exe -ErrorAction SilentlyContinue
if($py){$exe=$py.Source;$pyArgs=@('-3')}
else{
    $python=Get-Command python.exe -ErrorAction SilentlyContinue
    if(!$python){throw 'Python 3 required for source/release inventory checks.'}
    $exe=$python.Source;$pyArgs=@()
}
if(!$BuildDirectory){
    if(!$GameRoot -or !$BepInExRoot){throw 'Provide -BuildDirectory or both -GameRoot and -BepInExRoot.'}
    $BuildDirectory=Join-Path $project ('artifacts/integrated-build-'+$Stage)
    Write-Host "Building original-protocol plugin, launcher and helper: $BuildDirectory"
    & (Join-Path $PSScriptRoot 'build-local.ps1') -GameRoot $GameRoot -BepInExRoot $BepInExRoot -DotnetRoot $DotnetRoot -OutputDirectory $BuildDirectory -SkipArchive
    if(!$?){throw 'Compilation failed; no installation was attempted.'}
}
$inputScript=Join-Path $PSScriptRoot 'prepare-integrated-input.py'
$stageBase=Join-Path $project ('artifacts/automatic-update-development/'+$Stage)
Write-Host 'Checking base 1.2.1 installation ZIP contents, compiler manifest and clean loader...'
& $exe @pyArgs $inputScript --build $BuildDirectory --release $OriginalRelease --upstream $UpstreamArchive --stage $Stage
if($LASTEXITCODE -ne 0){throw 'Authentic original-package input staging failed; nothing was installed.'}
$input=Join-Path $stageBase 'inputs'
$inputManifest=Join-Path $input 'input-manifest.json'
$inputSha=(Get-FileHash -LiteralPath $inputManifest -Algorithm SHA256).Hash
$output=Join-Path $stageBase 'original-installer-output'
$toPackage=$input
$toHash=$inputSha
if($SignedInputDirectory -or $SignedInputManifestSha256 -or $ApprovalRecord -or $ApprovalSha256){
    if(!$SignedInputDirectory -or !$SignedInputManifestSha256 -or !$ApprovalRecord -or !$ApprovalSha256){
        throw 'Verified signed inputs AND exact external approval record/hash required. No unsigned approval fallback.'
    }
    $toPackage=[IO.Path]::GetFullPath($SignedInputDirectory)
    $toHash=$SignedInputManifestSha256.ToUpperInvariant()
}
Write-Host 'Invoking the original GA packaging and verification tool (not the LocalDev installer)...'
$params=@{InputDirectory=$toPackage;InputManifestSha256=$toHash;OutputDirectory=$output;Scope=$Scope}
if($ApprovalRecord){$params.ApprovalRecord=$ApprovalRecord;$params.ApprovalSha256=$ApprovalSha256.ToUpperInvariant()}
& (Join-Path $PSScriptRoot 'package-ga.ps1') @params
if(!$?){throw 'Original GA packaging failed.'}
$state=Get-Content -LiteralPath (Join-Path $output 'candidate-state.json') -Raw -Encoding UTF8|ConvertFrom-Json
$zip=Join-Path $output $state.wholeZip
if($state.installableRelease -eq $true -and $state.catalogRegistered -eq $true -and $state.updateProofVerified -eq $true -and $state.helperSignatureVerified -eq $true){
    Write-Host "INSTALLABLE ORIGINAL FORMAT (approved and signature-verified): $zip" -ForegroundColor Green
}else{
    Write-Warning ('REVIEW CANDIDATE ONLY: '+$zip)
    Write-Warning 'Cannot install this candidate. It lacks verified signing and external approval. Consult docs/INTEGRATED-RELEASE.md.'
}
